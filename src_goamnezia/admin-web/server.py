#!/usr/bin/env python3
"""
goAmnezia pro — локальная веб-панель (третий интерфейс к тому же ядру).

Служба нарочно слушает 127.0.0.1:1985. Администратор попадает на неё по
SSH-туннелю (`ssh -L 1985:127.0.0.1:1985 root@SERVER`) либо, в Pro-режиме, с
домена по секретному пути через nginx (docs/PANEL.md). Наружу напрямую панель
не выставляется никогда.

Панель НИЧЕГО не пишет сама: каждая мутация — вызов моста
`install.sh --action=<имя> --json --k=v` (docs/CONTRACT.md §0 п.3, §6), под тем
же замком `/run/goamnezia/config.lock`, что у SSH-меню, бота и MCP. Читать
напрямую разрешено только `config.json` (без секретов); пользователей, ключи
(только ответом `user-key`), подписку, страницы и раздачи панель получает ответом
моста или модуля ядра lib/core_read.py — тем же JSON, в этом процессе, под замком
ядра на чтение (docs/PANEL.md §5b).

Слой входа, сессий, лимитов кода и защиты от DNS-rebinding перенесён из
goTelegram Pro (admin-web/server.py, AUDIT.md §7): изменён неймспейс
(GOAMNEZIA_*, порт 1985, пути /opt/goamnezia*) и добавлен второй равноправный
вход — логин с паролем (решение владельца от 10.09.2026, docs/PANEL.md §6).
Панель ставится всегда и в любом режиме, поэтому способов входа два: код в
Telegram, когда бот настроен, и пароль — всегда.
"""

from __future__ import annotations

import base64
import gzip
import hashlib
import hmac
import importlib.util
import ipaddress
import json
import mimetypes
import os
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import threading
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


# ────────────────────────────────────────────────────────────────────────────
# Пути и окружение (CONTRACT §1). Всё переопределяется переменными, чтобы
# тесты поднимали панель во временном каталоге и не трогали /opt.
# ────────────────────────────────────────────────────────────────────────────
GOAMNEZIA_DIR = Path(os.getenv("GOAMNEZIA_DIR", "/opt/goamnezia"))
ADMIN_DIR = Path(os.getenv("GOAMNEZIA_ADMIN_DIR", "/opt/goamnezia-admin"))
STATIC_DIR = Path(os.getenv("GOAMNEZIA_ADMIN_STATIC", str(ADMIN_DIR / "static")))
CONFIG_FILE = Path(os.getenv("GOAMNEZIA_CONFIG", str(GOAMNEZIA_DIR / "config.json")))
# .env бота — единственный источник BOT_TOKEN и ALLOWED_IDS: код 2FA уходит тем
# же ботом и тем же администраторам, что и уведомления.
BOT_DIR = Path(os.getenv("GOAMNEZIA_BOT_DIR", "/opt/goamnezia-bot"))
ACTION_BIN = os.getenv("GOAMNEZIA_ACTION_BIN", str(GOAMNEZIA_DIR / "install.sh"))
# Единственный список того, что панель вправе вызывать. Имена действий в коде
# панели не хардкодятся: и валидация параметров, и таймауты, и «что
# разрушительно» берутся отсюда (CONTRACT §4.7, §5).
ACTIONS_JSON = Path(os.getenv("GOAMNEZIA_ACTIONS_JSON", str(GOAMNEZIA_DIR / "lib" / "actions.json")))
CATALOG_FILE = Path(os.getenv("GOAMNEZIA_CATALOG", str(GOAMNEZIA_DIR / "templates_catalog.json")))
CATALOG_TOOL = Path(os.getenv("GOAMNEZIA_CATALOG_TOOL", str(GOAMNEZIA_DIR / "lib" / "catalog_tool.py")))
AUDIT_LOG = Path(os.getenv("GOAMNEZIA_AUDIT_LOG", "/var/log/goamnezia-audit.log"))
# Замок ядра. Панель его НЕ берёт сама: flock на этом файле делает мост на
# каждое неreadonly-действие. Здесь путь нужен только чтобы показать его в
# «О программе» и передать мосту, если стенд переопределил каталог.
CONFIG_LOCK_FILE = Path(os.getenv("GOAMNEZIA_LOCK_DIR", "/run/goamnezia")) / "config.lock"

ADMIN_TOKEN_FILE = Path(os.getenv("GOAMNEZIA_ADMIN_TOKEN_FILE", str(ADMIN_DIR / "token")))

HOST = os.getenv("GOAMNEZIA_ADMIN_HOST", "127.0.0.1")
VERSION = "0.1.0"  # запасное значение; живое читается из config.json
ADMIN_TOKEN_HEADER = "X-GoAmnezia-Token"
ADMIN_TOKEN_PARAM = "token"
# Постоянный ключ из окружения больше не принимается (SEC50-08); имя осталось, чтобы вычищать его из окружения моста.
ADMIN_TOKEN_ENV = "GOAMNEZIA_ADMIN_TOKEN"
# Предохранитель от CSRF: без этого заголовка ни один POST не обрабатывается.
WRITE_GUARD_HEADER = "X-GoAmnezia-Admin"
# Принимаем hex / urlsafe-base64 / uuid, написанные оператором, но ничего
# такого, что искалечилось бы внутри ?token=… .
ADMIN_TOKEN_RE = re.compile(r"^[A-Za-z0-9_.~=-]{16,256}$")
# Защита от DNS-rebinding: страница с чужого origin резолвит своё имя в
# 127.0.0.1 и достала бы панель через туннель администратора. Принимаем
# только настоящие петлевые имена; nginx на домене проксирует под Host
# 127.0.0.1:1985 (lib/website.sh, _ga_site_panel_block) — и проходит.
ALLOWED_HOSTS = {"127.0.0.1", "localhost", "[::1]", "::1"}
# Ассеты без секретов остаются публичными — их тянет и сама страница входа.
# Корень и index.html — под охраной: неавторизованному нужно показать форму
# входа, иначе он видит пустую панель, которая молча получает 401 по API.
PUBLIC_STATIC_PATHS = {"/app.js", "/styles.css", "/favicon.ico"}
ACCESS_LOG = os.getenv("GOAMNEZIA_ADMIN_ACCESS_LOG", "0") == "1"

# Всё, что похоже на секрет, маскируется в логах, аудите и ответах, кроме
# ответа user-key (CONTRACT §0 п.7). Ключи — как они называются в users.json,
# .env, agents.json и ответах моста.
SECRET_KEYS = {"privkey", "psk", "secret", "token", "bot_token", "password", "hash", "initdata", "init_data",
               "key_hash", "rot_seed", "enroll_path", "enroll_code"}
# Профили, чей UDP-порт может быть 443, — по одному (PLAN §4.4); эти же имена
# для ссылок на ключи в белом списке actions.json (param_types.profile.enum).
LINE_BASE_BY_PROFILE = {"awg1": "1.5", "awg2": "2.0", "awg3": "3.1"}
# Линейка, в которой профиль правится, — семейство его ФАКТИЧЕСКОЙ линейки
# (lib/amnezia.sh ga_profile_line_base), а не то, что подразумевает имя:
# контейнер amnezia-awg2 от приложения бывает и 3.1, и после import-adopt его
# 3.x-параметры обязаны быть видны в списке. 1.0 и 1.5 — одно семейство.
LINE_FAMILY = {"1.0": "1.5", "1.5": "1.5", "2.0": "2.0", "3.1": "3.1"}
# Параметры, живущие в [Interface] сервера: их смена требует перевыпуска
# ключей (lib/amnezia.sh GA_AMN_SERVER_PARAMS). Панель предупреждает ДО вызова.
SERVER_SIDE_PARAMS = {"S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4",
                      "HeaderProtectionKey", "RandomTrailers", "DisableCookies"}
# Онлайн = рукопожатие моложе трёх минут (PLAN §5.1).
ONLINE_WINDOW = 180

# Таймауты моста по действиям (docs/BOT.md §5: бот ждёт столько же). Чтение —
# минута: status и user-list не должны висеть дольше.
BRIDGE_TIMEOUT_DEFAULT = 300
BRIDGE_TIMEOUT_READ = 60
BRIDGE_TIMEOUT_BY_ACTION = {
    "profile-install": 900, "profile-reline": 900, "backup-restore": 600, "change-mode": 600,
    "change-template": 300, "upstream-update": 900, "upstream-rollback": 900,
    "core-update": 900, "upstream-check": 120, "import-adopt": 300, "profile-subnet": 300,
    "profile-regen": 300, "site-check": 60,
    # 0.6.0, Ленивый Pro (docs/MODES_047.md, «Договор 0.6.0»): проверка — DNS и порты без изменений; сам сценарий —
    # сертификат, сайт (до трёх попыток шаблона), две линии AmneziaWG (у каждой установка до 15 минут), панель и ключи.
    "lazy-check": 120, "lazy-setup": 1800,
    # Выбор линии на UDP 443 в Pro: два профиля меняются портами — пересоздание двух контейнеров, как у смены режима.
    "pro-line": 600,
    # «Добавить сразу несколько» (до 100 человек): ключ каждому, на сотню — минута-две; запас — как у установки.
    "users-add-bulk": 900,
    # «Удалить сразу несколько» (до 100): применение к контейнерам пачками по 10 — до минуты на сотню; запас тот же.
    "users-del-bulk": 900,
    # «Перезапустить Docker» (DK-02): служба — до полутора минут, затем каждый профиль с соседями и goWARP.
    "docker-restart": 600,
    # Модуль ядра AmneziaWG (KMOD_PLAN этап Б, CONTRACT §4.7a): проверка — apt-get -s без изменений; установка — ожидание
    # apt до 10 минут, пакеты, сборка 1–3 минуты и самопроверка до 5; перевод — по одному профилю с ожиданием людей до
    # 3 минут на каждый; удаление — тот же перевод на программу и dkms remove. Зовутся в фоне (kmod_job_start).
    "kmod-check": 120, "kmod-install": 1800, "kmod-engine": 900, "kmod-remove": 900,
}
# Общий снимок частых чтений (CPU-аудит 03.10.2026): сколько секунд один сбор служит всем — Обзору,
# «Пользователям», «Трафику», карточке человека и каждой открытой вкладке. Каждый промах — полный install.sh с
# модулями и десятками jq и docker (на сервере в 1 vCPU: user-list 1,3, traffic 1,9, status 4,4 CPU-с), а
# автообновление просит то же каждые 10 с. Сроки — из передачи аудита: живые счётчики и рукопожатия — 15 с,
# состояние контейнеров — 30 с, список людей — до минуты, временные ссылки — 30 с (остаток их жизни считается
# по часам, share_payload). Адреса сервера (edge-status) — до двух минут: их счётчики пишет тик сторожа раз в две
# минуты, и новый тик сбрасывает снимок раньше срока (история адресов — в признаках). Раньше срока снимок
# сбрасывают мутация из панели (всё сразу) и смена файлов, из которых он собран, — правка из бота, SSH и таймеров
# (_snapshot_sig). Устройство — у run_action.
READ_CACHE_TTL = {"traffic": 15.0, "status": 30.0, "profiles-status": 30.0, "edge-status": 120.0,
                  "user-list": 60.0, "share-list": 30.0,
                  # Модуль ядра (карточка «Ускорение AmneziaWG» и её опрос хода раз в несколько секунд): одно чтение на
                  # все вкладки; ход, выбор и движки — в признаках файлов (_snapshot_sig), снимок сменится с ними сразу.
                  "kmod-status": 5.0}
# Живые данные в карточке человека и в списке людей (PERF-01): рукопожатия и счётчики (traffic) и адреса сервера для
# «ключа на другой адрес» (edge-status) — подсказки рядом с карточкой, а не её суть. Снимок старше срока, но не старше
# этих секунд, отдаётся сразу, а новый сбор идёт в фоне (один на ключ): на сервере в 1 vCPU traffic — 2 с, edge-status —
# 2–3 с, и карточка ждала их при каждом открытии и после каждого действия в ней. «В сети» считается от нынешнего
# времени с окном ONLINE_WINDOW (180 с), а активный пир делает новое рукопожатие раз в 120 с: снимок рукопожатий не
# старше 45 с не делает активного человека «не в сети» (120 + 45 + сбор < 180; CR-2), поэтому traffic — не дольше 45 с;
# адреса сервера (edge-status) от времени не стареют так быстро — до 10 мин. Ответ, собранный из такого снимка, несёт
# swr{since, reads} рядом с snapshot_at (snapshot_meta). «Трафик» ждёт свежий сбор, как раньше: там эти данные — суть
# экрана. GOAMNEZIA_READ_SWR=0 — без этого (и без подогрева): всегда свежий сбор, как в 1.0.9.
# Обзор и «Настройки» (PERF-03): холодный Обзор ждал три сбора моста подряд — status, traffic, edge-status, на 1 vCPU
# 3–5 с, — а плитка «Пользователи» без рукопожатий писала «0 на связи». Теперь состояние ядра (status, суть Обзора)
# отдаётся из снимка не старше 10 мин с фоновым сбором (как адреса сервера), рукопожатия и адреса Обзор не ждёт вовсе:
# нет годного снимка — сбор в фоне, в ответе pending, плитка пишет «— на связи», а страница переспрашивает через пару
# секунд (overview_payload).
READ_SWR_MAX_AGE = {"traffic": 45.0, "edge-status": 600.0, "status": 600.0}
# Здоровье служб рядом с ядром (services_health) — та же картина, что status: прежняя — до 10 мин, сбор в фоне.
SERVICES_SWR_MAX_AGE = READ_SWR_MAX_AGE["status"]
# Учёт трафика на Обзоре (сумма, сутки и месяц, карта часов) — из снимка traffic не старше 10 мин (PERF-05): счётчики
# только растут, прежний снимок для них верен, только отстаёт. «На связи» — по-прежнему только из снимка не старше
# READ_SWR_MAX_AGE["traffic"] (CR-2): старше — None и pending, новый сбор уже идёт в фоне.
TRAFFIC_TOTALS_MAX_AGE = 600.0


def read_swr_on() -> bool:
    """Отдавать ли прежний снимок с фоновым сбором (READ_SWR_MAX_AGE) — выключатель GOAMNEZIA_READ_SWR=0."""
    return os.getenv("GOAMNEZIA_READ_SWR", "1") != "0"
# Файлы ядра, по которым узнаём чужие правки (только stat: inode, mtime_ns, size; содержимое users.json читает модуль
# ядра lib/core_read.py, docs/PANEL.md §5b). Пути — те же, что у ядра (lib/common.sh), от того же GOAMNEZIA_DIR.
USERS_FILE = GOAMNEZIA_DIR / "users.json"
STATS_FILE = GOAMNEZIA_DIR / "stats.json"
STATE_DIR = GOAMNEZIA_DIR / "state"
SHARE_STATE_DIR = Path(os.getenv("GOAMNEZIA_SHARE_DIR")
                       or str(Path(os.getenv("GOAMNEZIA_LOCK_DIR", "/run/goamnezia")) / "share"))
# Модуль ядра AmneziaWG (lib/kmod.sh, CONTRACT §4.4a): выбор и итоги — state/kmod.json, ход долгого действия и кэш
# движков профилей — в /run/goamnezia. Панель их не читает — только признаки для снимка kmod-status.
KMOD_FILES = (STATE_DIR / "kmod.json",
              Path(os.getenv("GOAMNEZIA_LOCK_DIR", "/run/goamnezia")) / "kmod-progress.json",
              Path(os.getenv("GOAMNEZIA_LOCK_DIR", "/run/goamnezia")) / "kmod-engines.json")


# Часы вынесены в одну точку: тесты сессий и корзин лимитов подменяют
# server._now и проверяют истечение без реального ожидания.
def _now() -> float:
    return time.time()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


class BadRequest(ValueError):
    """Плохой запрос от клиента: отвечаем 400, а не падаем в 502."""


class ActionError(Exception):
    """Отказ на нашей стороне ДО вызова моста (валидация) — с кодом как у моста."""

    def __init__(self, code: str, message: str, status: int = 400):
        super().__init__(message)
        self.code = code
        self.status = status


def load_json(path: Path, fallback: Any = None) -> Any:
    try:
        with path.open("r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return fallback


def mask_secrets(obj: Any) -> Any:
    """Рекурсивно спрятать значения секретных ключей — для логов и аудита."""
    if isinstance(obj, dict):
        return {k: ("***" if str(k).lower() in SECRET_KEYS else mask_secrets(v)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [mask_secrets(v) for v in obj]
    return obj


def text_bytes(value: Any) -> bytes:
    """Строка из запроса → байты для сравнения с секретом или для хеша.

    hmac.compare_digest на str принимает только ASCII (иначе TypeError), а строгий encode
    падает на одиноком суррогате из JSON («\\ud800»): подтверждение «аня», такой код входа
    или подпись мини-аппа с «é» роняли маршрут в 500 с трассировкой в журнале — в том числе
    открытые маршруты входа. surrogatepass кодирует что угодно, а совпасть с настоящим
    значением (ASCII у кода и подписи, проверенное имя у подтверждения) такие байты не могут.
    """
    return str(value).encode("utf-8", "surrogatepass")


def log_text(text: str) -> str:
    """Строка для журнала без одиноких суррогатов: print такой строки сам падает, и обработчик
    запроса умирал без ответа (обрыв соединения, у nginx — 502) вместо честной ошибки."""
    return text.encode("utf-8", "backslashreplace").decode("utf-8")


# ────────────────────────────────────────────────────────────────────────────
# config.json — единственный файл ядра, который панель читает напрямую
# (CONTRACT §6). Отдаём наружу белый список полей: даже если в конфиг когда-то
# попадёт что-то новое, в браузер оно не уедет без явного решения.
# ────────────────────────────────────────────────────────────────────────────
def read_config() -> Dict[str, Any]:
    cfg = load_json(CONFIG_FILE, {}) or {}
    return cfg if isinstance(cfg, dict) else {}


def read_language(config: Optional[Dict[str, Any]] = None) -> str:
    config = config if config is not None else read_config()
    lang = str(config.get("lang") or config.get("language") or "").strip().lower()
    marker = GOAMNEZIA_DIR / ".language"
    if lang not in {"en", "ru"} and marker.exists():
        try:
            lang = marker.read_text(encoding="utf-8", errors="ignore").strip().lower()[:2]
        except OSError:
            lang = ""
    return lang if lang in {"en", "ru"} else "ru"


def detect_version(config: Optional[Dict[str, Any]] = None) -> str:
    config = config if config is not None else read_config()
    v = str(config.get("version") or "").strip()
    return v if re.fullmatch(r"[0-9][0-9A-Za-z.+-]{0,31}", v) else VERSION


def public_profile(pid: str, prof: Dict[str, Any]) -> Dict[str, Any]:
    params = prof.get("params") if isinstance(prof.get("params"), dict) else {}
    return {
        "profile": pid,
        "line": str(prof.get("line") or ""),
        "container": str(prof.get("container") or ""),
        "port": prof.get("port"),
        "subnet": str(prof.get("subnet") or ""),
        "iface": str(prof.get("iface") or ""),
        "image": str(prof.get("image") or ""),
        "image_tag": str(prof.get("image_tag") or ""),
        "image_digest": str(prof.get("image_digest") or ""),
        "preset": str(prof.get("preset") or ""),
        "mtu": str(params.get("MTU") or ""),
        # S4 — для окна MTU: пакет данных MTU + 80 + S4 больше 1500 не влезет даже в проводной путь (решение владельца
        # 08.10); у линий без S4 — пусто.
        "s4": str(params.get("S4") or "") if re.fullmatch(r"[0-9]{1,4}", str(params.get("S4") or "")) else "",
        "installed_at": str(prof.get("installed_at") or ""),
        "enabled": bool(prof.get("enabled", True)),
        # Подхвачен у приложения Amnezia (DUP-LINE-01): подпись для пользователей — «… · из приложения».
        "imported": prof.get("imported") is True,
    }


def public_config(cfg: Dict[str, Any]) -> Dict[str, Any]:
    profiles = cfg.get("profiles") if isinstance(cfg.get("profiles"), dict) else {}
    panel = cfg.get("panel") if isinstance(cfg.get("panel"), dict) else {}
    site = cfg.get("site") if isinstance(cfg.get("site"), dict) else {}
    options = cfg.get("options") if isinstance(cfg.get("options"), dict) else {}
    mcp = cfg.get("mcp") if isinstance(cfg.get("mcp"), dict) else {}
    dns = cfg.get("client_dns") if isinstance(cfg.get("client_dns"), list) else []
    return {
        "schema": cfg.get("schema"),
        "version": detect_version(cfg),
        "installed": bool(cfg.get("installed", False)),
        "mode": str(cfg.get("mode") or "lite"),
        "lang": read_language(cfg),
        "domain": str(cfg.get("domain") or ""),
        "server_ip": str(cfg.get("server_ip") or ""),
        "endpoint_host": str(cfg.get("endpoint_host") or ""),
        # Что встанет в Endpoint при пустом поле и что стоит сейчас — правило ядра (ga_export_pro_domain):
        # в режиме Pro домен сервера, иначе IP.
        "endpoint_auto": endpoint_auto(cfg),
        "endpoint_effective": str(cfg.get("endpoint_host") or "") or endpoint_auto(cfg),
        "client_dns": [str(x) for x in dns if isinstance(x, (str, int))],
        "profiles": {pid: public_profile(pid, p) for pid, p in profiles.items() if isinstance(p, dict)},
        "panel": {
            "port": panel.get("port", PORT),
            "miniapp_path": str(panel.get("miniapp_path") or ""),
            "trust_tunnel": bool(panel.get("trust_tunnel", True)),
        },
        "site": {
            "template_id": str(site.get("template_id") or ""),
            "template_source": str(site.get("template_source") or ""),
            "listen": str(site.get("listen") or "public"),
            "mcp_location": bool(site.get("mcp_location", False)),
            "panel_path": str(site.get("panel_path") or ""),
        },
        "options": {"drop_icmp": bool(options.get("drop_icmp", False)),
                    "alt_svc": bool(options.get("alt_svc", False))},
        "mcp": {"http_enabled": bool(mcp.get("http_enabled", False)),
                "http_port": mcp.get("http_port", 1986)},
    }


def _config_port() -> int:
    panel = read_config().get("panel")
    port = panel.get("port") if isinstance(panel, dict) else None
    try:
        port = int(port)
    except (TypeError, ValueError):
        return 0
    return port if 1 <= port <= 65535 else 0


# Порт: окружение (юнит) → config.json panel.port → 1985 (CONTRACT §1).
PORT = int(os.getenv("GOAMNEZIA_ADMIN_PORT") or _config_port() or 1985)


def public_panel_url(config: Optional[Dict[str, Any]] = None) -> str:
    """Адрес панели на домене — тот же, что открывает мини-апп. Пусто = не опубликована.

    Путь и домен лежат в config.json; проверку формата повторяем здесь же,
    потому что в разметку это попадает как ссылка, и мусор из конфига в ней
    оказаться не должен. Формат пути — как ga_site_panel_path_valid в
    lib/website.sh (6–64 символа, не начинается с «a-»).
    """
    cfg = config if config is not None else read_config()
    panel = cfg.get("panel") if isinstance(cfg.get("panel"), dict) else {}
    site = cfg.get("site") if isinstance(cfg.get("site"), dict) else {}
    path = str(panel.get("miniapp_path") or "").strip().strip("/")
    domain = str(cfg.get("domain") or "").strip().lower()
    if not path or not domain:
        return ""
    # Путь и домен в конфиге — ещё не опубликованная панель: локация живёт в
    # vhost сайта, и после ухода из Pro в Lite остаётся только запись. Отдавать
    # её как адрес значит показывать «опубликована» над ссылкой в чужой 404
    # (DEFECTS §1.8). Спрашиваем факт — тот же, что спрашивает ядро у miniapp-on.
    if str(cfg.get("mode") or "lite") not in ("pro", "lite_site"):
        return ""
    if str(site.get("cert") or "") != "letsencrypt":
        return ""
    # Та же длина, что в ядре и в боте: 512-битный путь занимает 90 знаков, а
    # прежний предел в 64 заставлял панель отвечать «панели на домене нет» —
    # будучи открытой ровно по этому адресу.
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{5,159}", path) or path.startswith("a-"):
        return ""
    if not re.fullmatch(r"[a-z0-9.-]{3,253}", domain):
        return ""
    return f"https://{domain}/{path}/"


_ENDPOINT_NAME_RE = re.compile(r"[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)+")


def pro_domain(config: Optional[Dict[str, Any]] = None) -> str:
    """Домен сервера в режиме Pro (AmneziaWG на UDP/443 под доменом) или пусто.

    Правило ядра — ga_export_pro_domain в lib/export.sh: режим pro, сертификат не
    самоподписанный (пустое поле старых установок — Let's Encrypt, как ga_site_cert_kind),
    имя узла строчными. Такой домен стоит в Endpoint ключей, пока поле пусто.
    """
    cfg = config if config is not None else read_config()
    site = cfg.get("site") if isinstance(cfg.get("site"), dict) else {}
    domain = str(cfg.get("domain") or "")
    if str(cfg.get("mode") or "lite") != "pro":
        return ""
    if str(site.get("cert") or "") == "selfsigned":
        return ""
    if len(domain) > 253 or re.fullmatch(r"[0-9.]+", domain) or not _ENDPOINT_NAME_RE.fullmatch(domain):
        return ""
    return domain


def endpoint_auto(config: Optional[Dict[str, Any]] = None) -> str:
    """Что встанет в Endpoint ключей при пустом поле: в режиме Pro домен сервера, иначе IP сервера."""
    cfg = config if config is not None else read_config()
    return pro_domain(cfg) or str(cfg.get("server_ip") or "")


# ────────────────────────────────────────────────────────────────────────────
# Бот: токен и администраторы из /opt/goamnezia-bot/.env
# ────────────────────────────────────────────────────────────────────────────
# Разбор .env был по голому startswith("BOT_TOKEN="): отступ перед именем или
# привычное `export BOT_TOKEN=...` — и панель молча считала, что бот не настроен.
# Повтор переменной — побеждает ПОСЛЕДНЯЯ строка, как у бота и systemd (SEC50-03): панель брала первую,
# и при двух строках ALLOWED_IDS пускала по коду не тех людей, с которыми работает бот.
def _env_value(name: str) -> str:
    try:
        raw = (BOT_DIR / ".env").read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return ""
    found = ""
    for line in raw.splitlines():
        line = line.strip()
        if line.startswith("export "):
            line = line[7:].lstrip()
        key, sep, value = line.partition("=")
        if not sep or key.strip() != name:
            continue
        found = _env_unquote(value)
    return found


def _env_unquote(value: str) -> str:
    """Значение строки .env так, как его читает python-dotenv у бота: в кавычках — до закрывающей
    кавычки, без кавычек — до комментария « # …» в конце строки.

    Комментарий после токена (`BOT_TOKEN=<токен>   # от BotFather`) бот отбрасывает, а панель брала
    строку целиком: адрес запроса к Telegram ломался, и текст ошибки urllib с ПОЛНЫМ токеном уходил
    ответом открытого /api/auth/request (находка SEC46-03)."""
    value = value.strip()
    if value[:1] in ("'", '"'):
        end = value.find(value[0], 1)
        if end > 0:
            return value[1:end].strip()
    return re.sub(r"\s+#.*$", "", value).strip()


# Токен бота — той же формы, что проверяет установщик (goamnezia-bot/install_bot.sh, TOKEN_RE).
BOT_TOKEN_RE = re.compile(r"[0-9]{6,12}:[A-Za-z0-9_-]{30,50}")
# Всё, что похоже на токен бота, в тексте ошибки заменяется меткой — и в ответе, и в журнале.
_BOT_TOKEN_LIKE_RE = re.compile(r"[0-9]{6,12}:[A-Za-z0-9_-]{20,}")


def _bot_token_from_env() -> str:
    token = _env_value("BOT_TOKEN")
    # Не той формы — как нет вовсе: такой Telegram всё равно не примет, а в адрес запроса токен идёт
    # целиком, и мусор в нём превращался в текст ошибки с самим токеном (SEC46-03).
    return token if BOT_TOKEN_RE.fullmatch(token) else ""


def _redact_token(text: Any, token: str = "") -> str:
    """Текст ошибки без токена бота: сам токен и всё, что на него похоже, — «<token>»."""
    out = str(text or "")
    if token:
        out = out.replace(token, "<token>")
    return _BOT_TOKEN_LIKE_RE.sub("<token>", out)


def _bot_admin_ids() -> set:
    ids: set = set()
    for part in re.split(r"[,\s]+", _env_value("ALLOWED_IDS")):
        if part.isdigit():
            ids.add(part)
    return ids


def bot_admins_view() -> Dict[str, Any]:
    """Список админов бота для показа: id в порядке записи и кто из них владелец.

    Владелец — OWNER_ID из .env бота: так его определяет сам бот (goamnezia-bot/bot.py),
    и так его назначает SSH-меню («Админы бота → Назначить владельца»). Панель раньше
    брала первый id из ALLOWED_IDS и после смены владельца показывала не того человека
    (найдено при составлении карты проекта 24.09.2026). Без OWNER_ID — как раньше, первый id.
    """
    ids = [p for p in re.split(r"[,\s]+", _env_value("ALLOWED_IDS")) if p.isdigit()]
    seen: List[str] = []
    for one in ids:
        if one not in seen:
            seen.append(one)
    owner = _env_value("OWNER_ID").strip()
    if not owner.isdigit():
        owner = seen[0] if seen else ""
    return {"ids": seen, "owner": owner, "managed_by": "bot"}


def tfa_available() -> bool:
    """Есть ли кому и чем слать код. Панель обязана знать это ДО показа формы,
    иначе человек упирается в кнопку, которая не сработает никогда."""
    return bool(_bot_token_from_env()) and bool(_bot_admin_ids())


MINIAPP_INITDATA_HEADER = "X-Telegram-Init-Data"
MINIAPP_MAX_AGE_SECONDS = 24 * 3600


# Почему вход из мини-аппа не состоялся (L-03, docs/DESIGN_ITERATION3_ACCEPTANCE.md): причина → машинный код
# ответа и ключ текста LOGIN_STRINGS. Подпись не подошла (подделка, чужой бот, испорченная ссылка) — прежний
# signature_invalid; подпись верна, но устарела, человек не администратор или администраторов нет вовсе — свои
# коды, чтобы экран входа сказал, что делать, а не «подпись не подошла» на всё.
MINIAPP_DENY = {
    "bad_signature": ("signature_invalid", "sig_invalid"),
    "expired": ("miniapp_expired", "sig_expired"),
    "not_admin": ("miniapp_not_admin", "sig_not_admin"),
    "no_admins": ("miniapp_not_configured", "sig_no_admins"),
    "no_token": ("miniapp_not_configured", "sig_no_token"),
}


def telegram_init_data_check(init_data: str, token: Optional[str] = None,
                             admins: Optional[set] = None) -> Tuple[Optional[str], str]:
    """(telegram user_id, "") — подпись верна и пользователь — админ; иначе (None, причина): bad_signature,
    expired, not_admin, no_admins, no_token (MINIAPP_DENY). Порядок проверок прежний: пока подпись не верна,
    про администраторов не говорим ничего.

    token и admins передаются явно только тестами (известный вектор без .env);
    в работе берутся из .env бота.
    """
    token = token if token is not None else _bot_token_from_env()
    if not token:
        return None, "no_token"
    if not init_data:
        return None, "bad_signature"
    try:
        pairs = urllib.parse.parse_qsl(init_data, keep_blank_values=True)
    except Exception:
        return None, "bad_signature"
    data = dict(pairs)
    received = data.pop("hash", "")
    if not received:
        return None, "bad_signature"
    check_string = "\n".join(f"{k}={v}" for k, v in sorted(data.items()))
    secret = hmac.new(b"WebAppData", token.encode(), hashlib.sha256).digest()
    # Байтами (text_bytes): подпись с «é» в заголовке или с суррогатом в теле — не 500, а «не подошла».
    calc = hmac.new(secret, text_bytes(check_string), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(calc.encode("ascii"), text_bytes(received)):
        return None, "bad_signature"
    # Протухшая подпись = перехваченная ссылка. Telegram кладёт auth_date всегда.
    try:
        if _now() - int(data.get("auth_date", "0")) > MINIAPP_MAX_AGE_SECONDS:
            return None, "expired"
    except Exception:
        return None, "bad_signature"
    try:
        uid = str(json.loads(data.get("user", "{}")).get("id", ""))
    except Exception:
        return None, "bad_signature"
    if not uid:
        return None, "bad_signature"
    admins = admins if admins is not None else _bot_admin_ids()
    # Пока админов нет (бот не настроен) — не пускаем никого: иначе первый
    # встречный получил бы панель.
    if not admins:
        return None, "no_admins"
    if uid not in admins:
        return None, "not_admin"
    return uid, ""


def verify_telegram_init_data(init_data: str, token: Optional[str] = None,
                              admins: Optional[set] = None) -> Optional[str]:
    """Вернуть telegram user_id, если подпись верна и пользователь — админ (причина отказа —
    telegram_init_data_check)."""
    return telegram_init_data_check(init_data, token, admins)[0]


# ════════════════════════════════════════════════════════════════════════════
# Двухфакторный вход в панель через Telegram-бота
#
# Панель на домене доступна из интернета, поэтому длинного пути мало. Схема:
#   • из мини-аппа Telegram — пускает подпись initData, код не нужен: Telegram
#     уже доказал, кто пришёл;
#   • из браузера — страница входа, код приходит в личку админу ботом, живёт
#     5 минут, одноразовый; после ввода браузер получает сессионную cookie;
#   • по SSH-туннелю — без второго фактора (см. is_local_console), а токен из
#     файла — аварийный путь на случай, если туннель проброшен не на петлю.
#
# Всё состояние в памяти процесса: рестарт панели разлогинивает всех, и это
# осознанно — так меньше поверхности, чем хранить сессии на диске.
# ════════════════════════════════════════════════════════════════════════════

TFA_CODE_TTL = 300          # код живёт 5 минут
TFA_MAX_ATTEMPTS = 5        # столько попыток на один код
TFA_REQUEST_COOLDOWN = 30   # не чаще одного кода в 30 секунд
TFA_REQUESTS_PER_HOUR = 5   # и не больше пяти в час с одного адреса
# В Pro-режиме соединение доходит до панели от nginx по петле, и адрес сокета
# у всех одинаков. Для такой общей корзины лимит должен быть выше: защиту от
# перебора несёт TFA_REQUEST_COOLDOWN (30 с между кодами), а часовой потолок
# здесь нужен лишь как страховка от долбёжки.
TFA_REQUESTS_PER_HOUR_SHARED = 30
_TFA_SHARED_IPS = {"127.0.0.1", "::1", "[::1]", "localhost", "?", ""}

# Пока панель жила только за SSH-туннелем, послабление до 30 было безобидным:
# корзину делили между собой одни администраторы. С публикацией на домене в ту
# же корзину попадает кто угодно из интернета — и получает как раз ослабленный
# лимит. Разводим корзины: публичный вход считается отдельно и по строгому
# счёту, туннельный — по прежнему. Так интернет-долбёжка не ослабляет защиту и
# заодно не запирает вход администратору, который придёт по туннелю.
#
# Публичный запрос узнаётся по X-Forwarded-Host: наружу панель отдаёт только
# location на домене, и он единственный его ставит. Корзина публичного входа —
# НА АДРЕС (`net:<адрес>`, адрес — из X-Real-IP своего nginx, см. client_ip).
# Одна корзина `net` на весь интернет была готовой атакой «отказ в обслуживании»:
# любой, кто знает домен, раз в 30 секунд выжигал общие пять кодов в час, а его
# запрос ещё и затирал код администратора в общем слоте — вход кодом вставал у
# всех. Общая `net` осталась запасной — для публичного запроса без адреса (nginx
# без X-Real-IP): там по-прежнему строгие пять в час.
TFA_BUCKET_PUBLIC = "net"
# Общий счёт кодов на все внешние корзины вместе (публичные по адресам, `net` и прямые
# непетлевые адреса): каждый код — сообщение админу в Telegram, и сто адресов не
# должны давать пятьсот сообщений в час. Он же держит перебор: каждый код — пять
# попыток на миллион вариантов. Вход паролем, по туннелю и из мини-аппа от него не
# зависит.
#
# Потолок в два уровня (SEC46-06). Прежде один общий потолок в 20 кодов выбирали
# четыре адреса по пять — и вход кодом вставал у всех остальных на час. Теперь после
# 20 кодов за час повторный код адресу не выдаётся, а ПЕРВЫЙ код часа — выдаётся:
# администратор с нового адреса код получит, даже когда несколько адресов выбрали
# свои пять. Сверх 60 кодов в час снаружи — никому: это страховка, она держит и
# сообщения админу (не больше одного в минуту в среднем), и перебор (5 × 60 догадок
# в час на миллион вариантов). Выбрать её могут только 44 адреса за час (4 × 5 + 40
# первых кодов; у IPv6 адрес — сеть /64), а не четыре.
TFA_REQUESTS_PER_HOUR_EXTERNAL = 20
TFA_REQUESTS_PER_HOUR_EXTERNAL_MAX = 60


def _addr_key(client_ip: str) -> str:
    """Ключ корзины по адресу клиента: IPv4 как есть, IPv6 — сетью /64.

    Одному клиенту провайдер выдаёт целую /64, и без свёртки каждый адрес из неё был бы
    новой чистой корзиной. Петля, «?» и мусор — пустая строка: адреса нет.
    """
    try:
        ip = ipaddress.ip_address(str(client_ip or "").strip())
    except ValueError:
        return ""
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    if ip.is_loopback or ip.is_unspecified:
        return ""
    if ip.version == 6:
        return str(ipaddress.ip_network(f"{ip}/64", strict=False))
    return str(ip)


def _tfa_bucket(client_ip: str, public: bool) -> str:
    if not public:
        return client_ip
    key = _addr_key(client_ip)
    return f"{TFA_BUCKET_PUBLIC}:{key}" if key else TFA_BUCKET_PUBLIC


# Продление — не то же самое, что вход с улицы. При сессии в 15 минут человек
# за рабочий час просит код четырежды, а публичный лимит — пять в час: без
# отдельной корзины панель заперла бы саму себя через час работы. В эту корзину
# попадают только запросы с живой или продлеваемой сессией, то есть тот, у кого
# сессии нет, до неё не дотянется.
TFA_RENEW_PER_HOUR = 12
TFA_BUCKET_RENEW = "renew"


def _tfa_hour_limit(bucket: str) -> int:
    if bucket == TFA_BUCKET_RENEW:
        return TFA_RENEW_PER_HOUR
    if bucket == TFA_BUCKET_PUBLIC or bucket.startswith(TFA_BUCKET_PUBLIC + ":"):
        return TFA_REQUESTS_PER_HOUR
    return TFA_REQUESTS_PER_HOUR_SHARED if bucket in _TFA_SHARED_IPS else TFA_REQUESTS_PER_HOUR


def _tfa_external(bucket: str) -> bool:
    """Корзина снаружи машины — под общим потолком. Продление (нужна живая сессия) и
    петля (свой туннель или локальный процесс) — не внешние."""
    return bucket != TFA_BUCKET_RENEW and bucket not in _TFA_SHARED_IPS


# Сессия короткая и продлевается кодом. Двенадцать часов означали бы, что
# забытая открытой вкладка остаётся входом в панель до конца суток — на
# опубликованной наружу панели это слишком щедро.
SESSION_TTL = int(os.getenv("GOAMNEZIA_SESSION_TTL", str(15 * 60)))
# Окно, в которое сессию ещё можно продлить кодом. За его пределами вход
# начинается заново. Данные в это окно уже НЕ отдаются: 15 минут истекли,
# и единственное, что разрешено, — доказать, что за экраном прежний человек.
SESSION_GRACE = int(os.getenv("GOAMNEZIA_SESSION_GRACE", "60"))
# Сама cookie живёт дольше сессии — и это не послабление: доступ даёт запись в
# памяти службы, а не наличие cookie, и к этому моменту запись уже удалена.
# Нужна она ради ОДНОГО: чтобы сервер узнал вернувшегося и сказал «сессия
# закончена, войдите заново», а не «нужен токен админки».
SESSION_COOKIE_SLACK = int(os.getenv("GOAMNEZIA_SESSION_COOKIE_SLACK", str(6 * 3600)))
SESSION_COOKIE = "ga_session"


def _trust_tunnel_default() -> bool:
    # Окружение (юнит, тесты) главнее config.json panel.trust_tunnel; по
    # умолчанию — доверять петле (см. is_local_console).
    env = os.getenv("GOAMNEZIA_TRUST_TUNNEL", "")
    if env in {"0", "1"}:
        return env == "1"
    panel = read_config().get("panel")
    if isinstance(panel, dict) and panel.get("trust_tunnel") is False:
        return False
    return True


# Пускать ли без второго фактора того, кто пришёл прямо на петлевой слушатель
# (то есть по SSH-туннелю). Выключатель нужен тем, кому важнее поверхность
# «любой локальный процесс, включая www-data у nginx, видит панель», чем
# удобство: с 0 возвращается прежний порядок с токеном.
TRUST_LOCAL_CONSOLE = _trust_tunnel_default()
# Билет ?s= оседает в access-log nginx и истории браузера, поэтому он одноразовый,
# короткоживущий и никогда не совпадает с самой сессией.
TICKET_TTL = 60
# Тестовый сток кодов: файл, в который дописывается код вместо отправки в
# Telegram (tests/test_admin_http.py). В юните НЕ задаётся никогда — иначе
# коды входа лягут на диск. Проверка бота при этом остаётся: без BOT_TOKEN и
# ALLOWED_IDS код не выдаётся и со стоком.
TFA_SINK = os.getenv("GOAMNEZIA_TFA_SINK", "")

_TFA_LOCK = threading.Lock()
# Код хранится ПО КОРЗИНЕ, а не одним слотом на всю панель. Единственный слот
# означал, что любой запрос кода гасит предыдущий: посторонний, знающий
# секретный путь, дёргал /api/auth/request и код администратора становился
# недействителен. Корзины разведены по происхождению ("net:<адрес>" для
# интернета, "renew" для продления, адрес для туннеля), поэтому чужой запрос
# тушит только свой собственный код. И проверяется код тоже только в своей
# корзине (tfa_verify): иначе пять чужих неверных попыток выжигали бы и код
# администратора.
_TFA_CODES: Dict[str, Dict[str, Any]] = {}
_TFA_REQUESTS: Dict[str, List[float]] = {}


def _tfa_sweep(now: float) -> None:
    """Выбросить протухшее — под _TFA_LOCK. Корзины по адресам заводятся на каждый
    новый адрес, и память обязана оставаться ограниченной: после чистки остаются
    только запросы последнего часа (внешних не больше потолка) и живые коды."""
    for b in list(_TFA_REQUESTS):
        fresh = [t for t in _TFA_REQUESTS[b] if now - t < 3600]
        if fresh:
            _TFA_REQUESTS[b] = fresh
        else:
            _TFA_REQUESTS.pop(b, None)
    for b in [b for b, s in _TFA_CODES.items() if s.get("expires", 0.0) <= now]:
        _TFA_CODES.pop(b, None)


def _tfa_owner(session_token: str) -> str:
    """Чья сессия просила код продления: отпечаток cookie, а не она сама."""
    return hashlib.sha256(("ga2fa-owner:" + session_token).encode()).hexdigest() if session_token else ""
# ThreadingHTTPServer правит _SESSIONS из разных потоков: без лока параллельный
# вход ронял GC «dictionary changed size during iteration».
_SESSION_LOCK = threading.Lock()
# tok → {"exp": момент истечения, "who": как вошёл (tunnel|code|token|tg:<id>)}.
# «who» нужен мосту для аудита (GOAMNEZIA_WHO=panel:<who>).
_SESSIONS: Dict[str, Dict[str, Any]] = {}
_TICKETS: Dict[str, float] = {}


def _tfa_hash(code: str) -> str:
    # text_bytes: код с одиноким суррогатом — неверный код и потраченная попытка, а не 500
    return hashlib.sha256(text_bytes("ga2fa:" + code)).hexdigest()


def _sessions_gc() -> None:
    # Чистим только те, у кого прошло и окно продления: удалить сессию сразу по
    # истечении значило бы, что продлевать уже нечего — состояние «renew»
    # существовать не смогло бы вовсе.
    now = _now()
    with _SESSION_LOCK:
        for tok in [t for t, s in _SESSIONS.items() if s["exp"] + SESSION_GRACE <= now]:
            _SESSIONS.pop(tok, None)


def session_state(token: str) -> Tuple[str, int]:
    """Состояние сессии и сколько секунд до следующего рубежа.

    ok    — работает, секунды до истечения;
    renew — 15 минут прошли, идут 60 секунд на продление кодом;
    dead  — окно упущено, вход заново.
    """
    if not token:
        return "dead", 0
    _sessions_gc()
    with _SESSION_LOCK:
        sess = _SESSIONS.get(token)
    if not sess:
        return "dead", 0
    # Сессия мини-аппа живёт, пока человек — администратор бота: его сняли (бот, SSH) — она гаснет сразу, а не
    # через 15 минут. Иначе снятый админ ещё четверть часа управлял панелью и мог, например, выдать себе
    # постоянный доступ агента (находка живой проверки бота, 03.10.2026). .env читается заново на каждый запрос —
    # это несколько сотен байт.
    who = str(sess.get("who") or "")
    if who.startswith("tg:") and who[3:] not in _bot_admin_ids():
        session_drop(token)
        return "dead", 0
    exp = sess["exp"]
    now = _now()
    if now < exp:
        return "ok", max(0, int(exp - now))
    if now < exp + SESSION_GRACE:
        return "renew", max(0, int(exp + SESSION_GRACE - now))
    return "dead", 0


def session_valid(token: str) -> bool:
    return session_state(token)[0] == "ok"


def session_renewable(token: str) -> bool:
    return session_state(token)[0] == "renew"


def session_who(token: str) -> str:
    with _SESSION_LOCK:
        sess = _SESSIONS.get(token)
    return str(sess.get("who") or "") if sess else ""


def session_create(who: str = "code") -> str:
    tok = secrets.token_urlsafe(32)
    with _SESSION_LOCK:
        _SESSIONS[tok] = {"exp": _now() + SESSION_TTL, "who": who}
    return tok


def session_drop(token: str) -> None:
    with _SESSION_LOCK:
        _SESSIONS.pop(token, None)


def ticket_create() -> str:
    """Одноразовый короткий пропуск для перехода со страницы входа на панель."""
    tok = secrets.token_urlsafe(32)
    now = _now()
    with _SESSION_LOCK:
        for old in [t for t, exp in _TICKETS.items() if exp <= now]:
            _TICKETS.pop(old, None)
        _TICKETS[tok] = now + TICKET_TTL
    return tok


def ticket_redeem(token: str) -> bool:
    # pop, а не get: билет виден в логах, поэтому годен строго один раз.
    if not token:
        return False
    now = _now()
    with _SESSION_LOCK:
        exp = _TICKETS.pop(token, None)
    return bool(exp and exp > now)


# username бота нужен, чтобы в отказе назвать, КУДА идти нажимать Start.
# Значение не меняется, поэтому запрашиваем один раз за жизнь процесса.
_BOT_USERNAME_CACHE: Dict[str, str] = {}


def _bot_username() -> str:
    token = _bot_token_from_env()
    if not token:
        return ""
    if token in _BOT_USERNAME_CACHE:
        return _BOT_USERNAME_CACHE[token]
    name = ""
    try:
        with urllib.request.urlopen(f"https://api.telegram.org/bot{token}/getMe", timeout=10) as resp:
            name = str((json.load(resp).get("result") or {}).get("username") or "")
    except Exception:
        name = ""
    _BOT_USERNAME_CACHE[token] = name
    return name


# Возвращает (успех, причина). Описание ошибки от Telegram нужно человеку:
# самая частая причина лечится в два касания — администратор не открывал
# бота, Telegram не даёт боту написать первым и отвечает «chat not found».
def _telegram_send(chat_id: str, text: str, html_mode: bool = False) -> Tuple[bool, str]:
    token = _bot_token_from_env()
    if not token:
        return False, "BOT_TOKEN не задан"
    try:
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{token}/sendMessage",
            data=json.dumps({"chat_id": chat_id, "text": text,
                             **({"parse_mode": "HTML"} if html_mode else {})}).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status == 200, ""
    except urllib.error.HTTPError as exc:
        desc = ""
        try:
            desc = str(json.loads(exc.read().decode("utf-8", "ignore")).get("description") or "")
        except Exception:
            desc = ""
        sys.stderr.write(_redact_token(f"2FA: Telegram отказал для {chat_id}: {exc} — {desc}", token) + "\n")
        return False, _redact_token(desc, token) or f"HTTP {exc.code}"
    except Exception as exc:
        # Причина уходит и в ответ открытого запроса кода: без токена — urllib кладёт в текст ошибки
        # адрес запроса целиком, а в нём /bot<токен>/ (находка SEC46-03).
        why = _redact_token(exc, token)
        sys.stderr.write(f"2FA: не удалось отправить код для {chat_id}: {why}\n")
        return False, why


def _deliver_code(admins: set, text: str, code: str) -> Tuple[bool, List[str]]:
    """Доставить код всем админам. Возвращает (дошло хоть кому-то, причины отказов)."""
    if TFA_SINK:
        # Тестовый сток вместо сети: строка «код» на строку файла.
        try:
            with open(TFA_SINK, "a", encoding="utf-8") as fh:
                fh.write(code + "\n")
            return True, []
        except OSError as exc:
            return False, [str(exc)]
    # any() останавливался бы на первом успехе — код получал только первый
    # админ, а второй ждал бы впустую, хотя войти имеет право. Шлём всем и
    # считаем успехом, если дошло хоть кому-то.
    sent = False
    reasons: List[str] = []
    for admin in sorted(admins):
        ok_send, why = _telegram_send(admin, text, html_mode=True)
        if ok_send:
            sent = True
        elif why:
            reasons.append(why)
    return sent, reasons


def tfa_request(client_ip: str, public: bool = False,
                renew: bool = False, session_token: str = "") -> Tuple[bool, str, str]:
    """Сгенерировать код и отправить его админам в Telegram.

    Третьим значением — КОД причины отказа, по нему выбирается ответ HTTP.
    Раньше на любую неудачу браузер получал 429 «слишком часто», хотя причиной
    могло быть «бот не установлен» или «администратор не начинал переписку»
    (DEFECTS §3.11): текст для человека был верным, а число — нет, и ни один
    внешний наблюдатель не мог отличить перебор от ненастроенного бота.

    session_token — cookie того, кто просит продление: код продления потом
    примется только из той же вкладки (см. tfa_verify).
    """
    # Отказы — AuthText (код, тексты на двух языках): коды прежние, а случаи внутри одного кода различает reason.
    admins = _bot_admin_ids()
    if not admins:
        return False, auth_text("tfa_off", "code_off_no_admins", {"reason": "no_admins"}), "tfa_off"
    if not _bot_token_from_env():
        return False, auth_text("tfa_off", "code_off_no_token", {"reason": "no_token"}), "tfa_off"
    now = _now()
    bucket = TFA_BUCKET_RENEW if renew else _tfa_bucket(client_ip, public)
    with _TFA_LOCK:
        # Выметаем протухшее до счёта: и чтобы словарь не рос вечно, и чтобы потолок
        # ниже считал только последний час.
        _tfa_sweep(now)
        hist = list(_TFA_REQUESTS.get(bucket, []))
        if hist and now - hist[-1] < TFA_REQUEST_COOLDOWN:
            wait = int(TFA_REQUEST_COOLDOWN - (now - hist[-1]))
            return (False, auth_text("too_often", "code_cooldown", {"reason": "cooldown", "seconds": wait}, n=wait),
                    "too_often")
        if len(hist) >= _tfa_hour_limit(bucket):
            return False, auth_text("too_often", "code_hour_limit", {"reason": "hour_limit"}), "too_often"
        if _tfa_external(bucket):
            spent = sum(len(h) for b, h in _TFA_REQUESTS.items() if _tfa_external(b))
            # Общий счёт выбран: повторный код адресу — нет, первый код часа — да, пока не выбрана
            # страховка (SEC46-06). Отказ — тот же net_limit: говорим, чем войти сейчас.
            if spent >= TFA_REQUESTS_PER_HOUR_EXTERNAL_MAX or (hist and spent >= TFA_REQUESTS_PER_HOUR_EXTERNAL):
                return False, auth_text("too_often", "code_net_limit", {"reason": "net_limit"}), "too_often"
        code = f"{secrets.randbelow(1000000):06d}"
        _TFA_CODES[bucket] = {"hash": _tfa_hash(code), "expires": now + TFA_CODE_TTL,
                              "attempts": 0, "sent_at": now,
                              # Код продления — той сессии, что его просила (tfa_verify)
                              "owner": _tfa_owner(session_token) if bucket == TFA_BUCKET_RENEW else ""}
        hist.append(now)
        _TFA_REQUESTS[bucket] = hist
    # Реального адреса клиента за nginx может и не быть, но САМ ФАКТ «пришли
    # из интернета, а не с вашего туннеля» — уже то, по чему видно неладное.
    if public and _addr_key(client_ip):
        # Адрес за своим nginx известен (X-Real-IP) — называем его: чужие запросы видны сразу.
        _ip_line = f"Действует 5 минут. Запрошен из интернета с адреса {client_ip} — по адресу панели на домене.\n"
    elif public:
        _ip_line = "Действует 5 минут. Запрошен из интернета — по адресу панели на домене.\n"
    elif client_ip in {"127.0.0.1", "::1", "?", ""}:
        _ip_line = "Действует 5 минут. Запрошен через SSH-туннель.\n"
    else:
        _ip_line = f"Действует 5 минут. Запрошен с адреса {client_ip}.\n"
    # <code> в Telegram — не украшение: по касанию он копируется целиком.
    text = (f"Код входа в панель goAmnezia: <code>{code}</code>\n"
            + _ip_line
            + "Если это не вы — просто не вводите его.")
    sent, reasons = _deliver_code(admins, text, code)
    if not sent:
        with _TFA_LOCK:
            _TFA_CODES.pop(bucket, None)
            # Код никому не ушёл — возвращаем квоту, причём в ТУ ЖЕ корзину,
            # на которую расход и списан; иначе лежащий бот запирал вход на час
            # без единого кода.
            hist = _TFA_REQUESTS.get(bucket)
            if hist and now in hist:
                hist.remove(now)
        # Ответ уходит неавторизованному: токена в причине не бывает ни в каком виде (SEC46-03).
        joined = _redact_token("; ".join(dict.fromkeys(reasons)), _bot_token_from_env())
        if any("chat not found" in r.lower() or "bot was blocked" in r.lower()
               or "user is deactivated" in r.lower() for r in reasons):
            uname = _bot_username()
            where = f"@{uname}" if uname else {lang: LOGIN_STRINGS[lang]["your_bot"] for lang in ("ru", "en")}
            return False, auth_text("chat_not_started", "code_chat_not_started", where=where), "chat_not_started"
        # Причину Telegram (description) не переводим: это его слова, они и нужны для разбора.
        return (False,
                auth_text("send_failed", "code_send_failed_why", why=joined) if joined
                else auth_text("send_failed", "code_send_failed"),
                "send_failed")
    return True, "код отправлен в Telegram", ""


def tfa_verify(code: str, client_ip: str = "", public: bool = False,
               session_token: str = "") -> Tuple[bool, str]:
    """Проверить код. Годятся только коды СВОИХ корзин: корзины адреса, с которого
    пришла проверка (как у запроса кода), и код продления, который просила эта же
    сессия (cookie та же, даже если окно продления уже вышло — код живёт 5 минут).

    Прежде годился любой живой код любой корзины: пять неверных догадок с чужого
    адреса списывались и с кода администратора и выжигали его, а каждый чужой
    запрос кода добавлял перебирающему ещё одну мишень.
    """
    code = (code or "").strip()
    now = _now()
    given = _tfa_hash(code)
    own = _tfa_bucket(client_ip, public)
    owner = _tfa_owner(session_token)
    with _TFA_LOCK:
        for b in [b for b, s in _TFA_CODES.items() if s.get("expires", 0.0) <= now]:
            _TFA_CODES.pop(b, None)
        # Попытка списывается с каждого своего кода (их бывает два: вход и продление), и
        # перебор так же ограничен пятью попытками.
        live = {b: s for b, s in _TFA_CODES.items() if s.get("hash") and (
            b == own or (b == TFA_BUCKET_RENEW and owner and hmac.compare_digest(owner, str(s.get("owner") or ""))))}
        # Отказы — AuthText: строка для прежних вызывающих, код и тексты на двух языках — для ответа API.
        if not live:
            return False, auth_text("code_expired", "code_expired")
        if all(s["attempts"] >= TFA_MAX_ATTEMPTS for s in live.values()):
            for b in list(live):
                _TFA_CODES.pop(b, None)
            return False, auth_text("code_too_many_attempts", "code_too_many")
        left = 0
        for b, st in live.items():
            if st["attempts"] >= TFA_MAX_ATTEMPTS:
                continue
            st["attempts"] += 1
            if hmac.compare_digest(given, st["hash"]):
                # одноразовый: гасим сразу после успеха
                _TFA_CODES.pop(b, None)
                return True, "ok"
            left = max(left, TFA_MAX_ATTEMPTS - st["attempts"])
    return False, auth_text("code_wrong", "code_wrong", {"left": max(0, left)}, n=max(0, left))


# ════════════════════════════════════════════════════════════════════════════
# Вход по логину и паролю
#
# Решение владельца от 10.09.2026: панель поднимается всегда и в любом режиме,
# а входов становится два равноправных — код в Telegram (главный, когда бот
# настроен) и логин с паролем (единственный, когда бота нет; запасной, когда
# бот есть). Прежние пути — доверие петле, подпись мини-аппа и аварийный
# токен — остаются как были.
#
# Пароль на диске не лежит НИКОГДА: в файле только логин, соль и вывод KDF.
# Файл 0600 в каталоге панели 0700 — те же правила, что у токена.
# ════════════════════════════════════════════════════════════════════════════
PASSWORD_FILE = Path(os.getenv("GOAMNEZIA_ADMIN_PASSWORD_FILE", str(ADMIN_DIR / "password.json")))
PASSWORD_LOGIN_DEFAULT = "admin"
PASSWORD_LOGIN_RE = re.compile(r"^[A-Za-z0-9._-]{1,32}$")
# Пароль выдаётся установщиком случайным, поэтому нижняя граница — не про
# «сложность из букв и цифр», а про длину: панель бывает открыта на домене, и
# короткий пароль там перебирается быстрее, чем администратор заметит.
PASSWORD_MIN_LEN = 12
PASSWORD_MAX_LEN = 200
# scrypt: 16 МБ памяти на одну проверку — перебор по словарю дороже на порядки,
# чем pbkdf2 того же времени. Запасной путь нужен сборкам Python без OpenSSL
# 1.1, где hashlib.scrypt отсутствует вовсе.
SCRYPT_N, SCRYPT_R, SCRYPT_P = 1 << 14, 8, 1
PASSWORD_DKLEN = 32
PBKDF2_ROUNDS = 200_000
# Границы параметров из файла: считаем их, а не константы, иначе смена
# умолчаний обесценила бы уже выданные пароли. Но и слепо верить файлу нельзя —
# подставленный n в миллион означал бы падение по памяти на каждой попытке.
SCRYPT_N_RANGE = (1 << 12, 1 << 17)
SCRYPT_MAXMEM = 64 * 1024 * 1024

# Пять попыток за пятнадцать минут на адрес — та же скользящая корзина, что у
# кодов (_TFA_REQUESTS), только своя: код стоит сообщения в Telegram, поэтому
# там корзина общая на весь интернет; пароль не стоит ничего, кроме нашего
# процессора, и корзина «на адрес» здесь и точнее, и не запирает вход
# администратору из-за чужого перебора.
PWD_MAX_ATTEMPTS = 5
PWD_WINDOW = 900
# Пол ответа: проверка пароля обязана занимать одинаковое время при верном и
# неверном логине. KDF считается в обоих случаях (см. _password_dummy), но
# один только KDF плавает от нагрузки — фиксированный пол убирает и это.
PASSWORD_MIN_RESPONSE = 0.35

_PWD_LOCK = threading.Lock()
_PWD_ATTEMPTS: Dict[str, List[float]] = {}


def _password_algo() -> str:
    return "scrypt" if hasattr(hashlib, "scrypt") else "pbkdf2"


def _password_derive(password: str, rec: Dict[str, Any]) -> str:
    """Вывод KDF по параметрам ИЗ ЗАПИСИ — чтобы старые пароли пережили смену умолчаний."""
    salt = bytes.fromhex(str(rec.get("salt") or ""))
    raw = password.encode("utf-8")
    if rec.get("algo") == "scrypt":
        return hashlib.scrypt(raw, salt=salt, n=int(rec.get("n") or SCRYPT_N),
                              r=int(rec.get("r") or SCRYPT_R), p=int(rec.get("p") or SCRYPT_P),
                              dklen=PASSWORD_DKLEN, maxmem=SCRYPT_MAXMEM).hex()
    return hashlib.pbkdf2_hmac("sha256", raw, salt, int(rec.get("rounds") or PBKDF2_ROUNDS),
                               dklen=PASSWORD_DKLEN).hex()


def password_record() -> Dict[str, Any]:
    """Запись из файла или пустой словарь. Читаем на каждую проверку: пароль
    меняют и установщиком снаружи, а рестарт службы ради этого не нужен."""
    rec = load_json(PASSWORD_FILE, None)
    if not isinstance(rec, dict):
        return {}
    login = str(rec.get("login") or "")
    algo = str(rec.get("algo") or "")
    salt = str(rec.get("salt") or "")
    digest = str(rec.get("hash") or "")
    if not PASSWORD_LOGIN_RE.match(login) or algo not in {"scrypt", "pbkdf2"}:
        return {}
    if not re.fullmatch(r"(?:[0-9a-f]{2}){8,64}", salt) or not re.fullmatch(r"(?:[0-9a-f]{2}){16,64}", digest):
        return {}
    out: Dict[str, Any] = {"login": login, "algo": algo, "salt": salt, "hash": digest,
                           "updated": str(rec.get("updated") or "")}
    if algo == "scrypt":
        try:
            n, r, p = int(rec.get("n") or SCRYPT_N), int(rec.get("r") or SCRYPT_R), int(rec.get("p") or SCRYPT_P)
        except (TypeError, ValueError):
            return {}
        if not (SCRYPT_N_RANGE[0] <= n <= SCRYPT_N_RANGE[1] and 1 <= r <= 32 and 1 <= p <= 16):
            return {}
        out.update({"n": n, "r": r, "p": p})
    else:
        try:
            rounds = int(rec.get("rounds") or PBKDF2_ROUNDS)
        except (TypeError, ValueError):
            return {}
        if not 10_000 <= rounds <= 5_000_000:
            return {}
        out["rounds"] = rounds
    return out


def password_configured() -> bool:
    return bool(password_record())


def password_login() -> str:
    return str(password_record().get("login") or PASSWORD_LOGIN_DEFAULT)


# Пустышка на промах: по ней KDF считается ровно так же, как по настоящей
# записи. Без неё ответ «такого логина нет» приходил бы мгновенно, а «пароль не
# подошёл» — через десятки миллисекунд KDF, и по одной этой разнице логин
# подбирался бы, не зная пароля. Одна на процесс: соль случайная, пароль к ней
# не существует, поэтому совпасть она не может ни с чем.
_PWD_DUMMY: Dict[str, Any] = {
    "login": "", "algo": _password_algo(), "salt": secrets.token_bytes(16).hex(),
    "hash": secrets.token_bytes(PASSWORD_DKLEN).hex(),
    **({"n": SCRYPT_N, "r": SCRYPT_R, "p": SCRYPT_P} if _password_algo() == "scrypt"
       else {"rounds": PBKDF2_ROUNDS}),
}


def password_set(login: str, password: str) -> Dict[str, Any]:
    """Записать логин и хеш пароля (0600). Сам пароль не сохраняется нигде."""
    login = (login or "").strip() or PASSWORD_LOGIN_DEFAULT
    if not PASSWORD_LOGIN_RE.match(login):
        raise ActionError("bad_login", "логин: 1–32 символа латиницы, цифр, точки, дефиса и подчёркивания")
    password = password or ""
    if not PASSWORD_MIN_LEN <= len(password) <= PASSWORD_MAX_LEN:
        raise ActionError("bad_password", f"пароль: от {PASSWORD_MIN_LEN} до {PASSWORD_MAX_LEN} символов")
    try:
        password.encode("utf-8")
    except UnicodeEncodeError:
        # Одинокий суррогат из JSON не кодируется, и KDF падал мимо проверок — 500 вместо отказа.
        raise ActionError("bad_password", "пароль: недопустимые символы")
    algo = _password_algo()
    rec: Dict[str, Any] = {"login": login, "algo": algo, "salt": secrets.token_bytes(16).hex(),
                           "updated": utc_now()}
    rec.update({"n": SCRYPT_N, "r": SCRYPT_R, "p": SCRYPT_P} if algo == "scrypt" else {"rounds": PBKDF2_ROUNDS})
    rec["hash"] = _password_derive(password, rec)
    try:
        PASSWORD_FILE.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(PASSWORD_FILE.parent, 0o700)
        except OSError:
            pass
        # Через временный файл с правами 0600 ДО записи: иначе между созданием
        # и chmod хеш секунду лежал бы читаемым для всех.
        tmp = PASSWORD_FILE.with_name(PASSWORD_FILE.name + ".tmp")
        fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(rec, fh, ensure_ascii=False)
            fh.write("\n")
            # Переименование атомарно по отношению к другим процессам, но не к пропаже
            # питания: без fsync ядро вправе держать и данные, и запись каталога в кэше
            # сколько угодно. На сервере без бота пароль — единственный вход с домена, и
            # пустой файл после отключения питания означал бы запертую дверь.
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, PASSWORD_FILE)
        dir_fd = os.open(str(PASSWORD_FILE.parent), os.O_RDONLY)
        try:
            os.fsync(dir_fd)       # без этого само появление файла может не пережить питание
        finally:
            os.close(dir_fd)
    except OSError as exc:
        raise ActionError("password_write_failed", f"не удалось записать {PASSWORD_FILE}: {exc}", 500)
    return {"login": login, "algo": algo, "updated": rec["updated"]}


def password_verify(login: str, password: str) -> bool:
    """Верны ли логин и пароль. Время ответа не зависит от того, что не сошлось."""
    rec = password_record()
    given = str(login or "").encode("utf-8", "ignore")
    known = str(rec.get("login") or "").encode("utf-8", "ignore")
    matched = bool(rec) and hmac.compare_digest(given, known)
    target = rec if matched else _PWD_DUMMY
    try:
        calc = _password_derive(str(password or ""), target)
    except (ValueError, MemoryError):  # pragma: no cover — битый файл или нехватка памяти
        return False
    ok = hmac.compare_digest(calc, str(target.get("hash") or ""))
    return bool(ok and matched)


def _password_pace(started: float) -> None:
    # Часы теста подменяют server._now, поэтому пол ответа считаем по
    # monotonic: он меряет настоящую длительность и не зависит от подмены.
    rest = PASSWORD_MIN_RESPONSE - (time.monotonic() - started)
    if rest > 0:
        time.sleep(rest)


def password_check(login: str, password: str) -> bool:
    started = time.monotonic()
    ok = password_verify(login, password)
    _password_pace(started)
    return ok


def _pwd_bucket(client_ip: str) -> str:
    # IPv6 — сетью /64 (_addr_key): иначе каждый адрес своей /64 был бы чистой корзиной
    return _addr_key(client_ip) or client_ip or "?"


def _pwd_wait(hist: List[float], now: float) -> int:
    return max(1, int(PWD_WINDOW - (now - hist[-PWD_MAX_ATTEMPTS])))


def _pwd_sweep(now: float, keep: str) -> None:
    """Выбросить чужие протухшие корзины, чтобы словарь не рос вечно (под _PWD_LOCK)."""
    for b in [b for b, h in _PWD_ATTEMPTS.items()
              if b != keep and not [t for t in h if now - t < PWD_WINDOW]]:
        _PWD_ATTEMPTS.pop(b, None)


def password_blocked(bucket: str) -> Tuple[bool, int]:
    """Заперт ли адрес и на сколько секунд. Окно скользящее: пятая неудача
    запирает ровно до того момента, когда первая из пяти выпадет из окна.

    Только подсмотреть — для быстрого отказа. Право на проверку пароля даёт
    password_attempt_begin: подсмотреть и потом записать — это два шага, и
    параллельные запросы проходили бы между ними все разом."""
    now = _now()
    with _PWD_LOCK:
        hist = [t for t in _PWD_ATTEMPTS.get(bucket, []) if now - t < PWD_WINDOW]
        # Пустую корзину не заводим: подсмотр идёт на каждый вход, и без пароля на сервере (до
        # password_attempt_begin с его чисткой дело не доходит) каждый новый адрес оставлял бы в
        # словаре запись навсегда.
        if hist:
            _PWD_ATTEMPTS[bucket] = hist
        else:
            _PWD_ATTEMPTS.pop(bucket, None)
        if len(hist) < PWD_MAX_ATTEMPTS:
            return False, 0
        return True, _pwd_wait(hist, now)


def password_attempt_begin(bucket: str) -> Tuple[bool, int, int]:
    """Проверить корзину и записать попытку ОДНИМ шагом под замком — ДО проверки пароля.

    Раньше было «заперт ли адрес?» → проверка пароля (KDF и пол ответа 0.35 с) →
    «записать неудачу». Пока шла проверка, корзина не менялась, и пачка
    одновременных запросов с одного адреса проходила первый шаг вся: вместо пяти
    попыток за 15 минут перебирающий получал столько, сколько успевал отправить
    за время одной проверки. Теперь место в корзине занимается сразу; удачный вход
    корзину обнуляет (password_attempts_clear), неудачный оставляет запись как есть.

    → (можно проверять, секунд до разблокировки, сколько попыток останется после этой).
    """
    now = _now()
    with _PWD_LOCK:
        hist = [t for t in _PWD_ATTEMPTS.get(bucket, []) if now - t < PWD_WINDOW]
        if len(hist) >= PWD_MAX_ATTEMPTS:
            _PWD_ATTEMPTS[bucket] = hist
            return False, _pwd_wait(hist, now), 0
        hist.append(now)
        _pwd_sweep(now, bucket)
        _PWD_ATTEMPTS[bucket] = hist
        return True, 0, max(0, PWD_MAX_ATTEMPTS - len(hist))


def password_attempt_failed(bucket: str) -> int:
    """Записать неудачу и вернуть, сколько попыток осталось до блокировки.

    Маршруты входа зовут password_attempt_begin (запись ДО проверки); здесь — запись
    задним числом для того, кто уже знает, что попытка неудачна."""
    now = _now()
    with _PWD_LOCK:
        hist = [t for t in _PWD_ATTEMPTS.get(bucket, []) if now - t < PWD_WINDOW]
        hist.append(now)
        _pwd_sweep(now, bucket)
        _PWD_ATTEMPTS[bucket] = hist
        return max(0, PWD_MAX_ATTEMPTS - len(hist))


def password_attempts_clear(bucket: str) -> None:
    with _PWD_LOCK:
        _PWD_ATTEMPTS.pop(bucket, None)


# ────────────────────────────────────────────────────────────────────────────
# Признаки происхождения запроса — чистые функции, чтобы тесты проверяли их
# без поднятого сервера. Логика — из goTelegram (AUDIT.md §7).
# ────────────────────────────────────────────────────────────────────────────
PROXY_HEADERS = ("X-Forwarded-Host", "X-Real-IP", "X-Forwarded-For", "X-Forwarded-Proto")
LOOPBACK_PEERS = {"127.0.0.1", "::1", "::ffff:127.0.0.1"}


def local_console(headers: Any, peer: str) -> bool:
    """Пришли ли ПРЯМО на петлевой слушатель, а не через nginx с домена.

    Это и есть «через localhost»: `ssh -L 1985:127.0.0.1:1985`, то есть тот,
    кто уже доказал право на сервер входом по SSH.

    Двойная проверка не для красоты:
      * ни одного заголовка обратного прокси — публичный вход отсечён;
      * реальный адрес сокета петлевой — на случай, если панель подняли не
        на 127.0.0.1 (GOAMNEZIA_ADMIN_HOST можно переопределить). Без этой
        половины панель, выставленная на внешний интерфейс напрямую, мимо
        nginx, пускала бы кого угодно без единой проверки.

    Достаточно было бы одного X-Forwarded-Host — его nginx ставит безусловно
    (lib/website.sh), клиентское значение затирается. Но тогда ВЕСЬ вход в
    панель держался бы на одной строке конфига: сотрись она при правке
    шаблона — и улица получает права туннеля молча. Поэтому смотрим на все
    заголовки, которые ставит обратный прокси. Ошибка в любую сторону здесь
    безопасна: лишний заголовок означает лишь просьбу ввести код.
    """
    for h in PROXY_HEADERS:
        if (headers.get(h) or "").strip():
            return False
    return peer in LOOPBACK_PEERS


def public_request(headers: Any) -> bool:
    """Пришли ли из интернета (по адресу панели на домене), а не по туннелю.

    Наружу панель отдаёт единственный location — по секретному пути, — и
    только он ставит X-Forwarded-Host. По нему и различаем.
    """
    return bool((headers.get("X-Forwarded-Host") or "").strip())


def host_name_only(raw: str) -> str:
    value = raw.strip().lower()
    if value.startswith("["):
        end = value.find("]")
        return value[:end + 1] if end > 0 else value
    if value.count(":") == 1:
        return value.split(":", 1)[0]
    return value


# ────────────────────────────────────────────────────────────────────────────
# Аварийный ключ (SEC50-08, решение владельца 28.09): «на домене — только пароль
# или код из бота; аварийный ключ — только формировать в SSH полной строкой».
#
# Ключ больше не постоянный и панель его не заводит. Его создаёт SSH-меню
# («Настройки → Веб-панель, админы бота, ИИ-агенты → Панель и мини-апп →
# Аварийный ключ»): ADMIN_TOKEN_FILE — одна строка, 0600, рядом token.meta
# (0600) {"created": <epoch>, "expires": <epoch>}. Панель принимает ключ,
# только если meta есть и срок не вышел, а запрос пришёл по SSH-туннелю (ни
# одного заголовка обратного прокси, петлевой адрес — правило local_console);
# с домена — отказ словами. Принятый ключ сгорает: файлы удаляются, дальше
# живёт обычная сессия. Ключ без meta (старый постоянный на обновлённом
# сервере) не принимается; постоянного ключа из окружения больше нет.
# ────────────────────────────────────────────────────────────────────────────
ADMIN_TOKEN_META = ADMIN_TOKEN_FILE.with_name(ADMIN_TOKEN_FILE.name + ".meta")
# SSH-меню выдаёт ключ на час; meta с большим сроком — это снова постоянный ключ, его не принимаем.
ADMIN_TOKEN_MAX_TTL = 24 * 3600
# Часы сервера и того, кто писал meta, одни и те же; минуты на неточность хватит.
ADMIN_TOKEN_CLOCK_SKEW = 300
_TOKEN_LOCK = threading.Lock()
# Отпечатки уже принятых ключей: не удалось стереть файл (диск, права) — второй раз ключ всё равно не войдёт.
_TOKEN_USED: set = set()


def _private_text(path: Path) -> Optional[str]:
    """Содержимое обычного файла, закрытого от группы и остальных (0600); иначе None — такому файлу не верим."""
    try:
        st = os.lstat(path)
    except OSError:
        return None
    if not stat.S_ISREG(st.st_mode) or st.st_mode & 0o077:
        return None
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None


def emergency_token_state(now: Optional[float] = None) -> Tuple[str, str]:
    """(ключ, почему нет): действующий аварийный ключ или "" и причина — no_token | no_meta | bad_meta | expired."""
    raw = _private_text(ADMIN_TOKEN_FILE)
    token = (raw or "").strip()
    if not token or not ADMIN_TOKEN_RE.fullmatch(token):
        return "", "no_token"
    meta_raw = _private_text(ADMIN_TOKEN_META)
    if meta_raw is None:
        return "", "no_meta"
    try:
        meta = json.loads(meta_raw)
    except ValueError:
        return "", "bad_meta"
    created = meta.get("created") if isinstance(meta, dict) else None
    expires = meta.get("expires") if isinstance(meta, dict) else None
    if not all(isinstance(x, int) and not isinstance(x, bool) for x in (created, expires)):
        return "", "bad_meta"
    now = _now() if now is None else now
    if expires <= now:
        return "", "expired"
    if expires <= created or expires - created > ADMIN_TOKEN_MAX_TTL or created > now + ADMIN_TOKEN_CLOCK_SKEW:
        return "", "bad_meta"
    return token, ""


def emergency_token_burn() -> None:
    """Ключ сгорел: файл ключа и его meta — прочь (без meta ключ и так не принимается)."""
    for path in (ADMIN_TOKEN_FILE, ADMIN_TOKEN_META):
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        except OSError as exc:
            print(f"[admin] cannot remove {path}: {exc}", flush=True)


def emergency_token_redeem(provided: str) -> Tuple[bool, str]:
    """Сверить присланный ключ и сжечь его — одним шагом под замком: два запроса с одним ключом войдут одним.
    Возвращает (принят, причина отказа)."""
    provided = (provided or "").strip()
    if not provided:
        return False, "no_token"
    with _TOKEN_LOCK:
        expected, why = emergency_token_state()
        if not expected:
            return False, why
        if not hmac.compare_digest(expected.encode("utf-8", "ignore"), provided.encode("utf-8", "ignore")):
            return False, "wrong"
        mark = hashlib.sha256(expected.encode("utf-8", "ignore")).hexdigest()
        if mark in _TOKEN_USED:
            return False, "used"
        _TOKEN_USED.add(mark)
        emergency_token_burn()
    return True, ""


# ════════════════════════════════════════════════════════════════════════════
# Мост к ядру: install.sh --action=<имя> --json --k=v
# ════════════════════════════════════════════════════════════════════════════
_ACTIONS_LOCK = threading.Lock()
_ACTIONS_CACHE: Dict[str, Any] = {"mtime": None, "spec": None}


def load_actions() -> Dict[str, Any]:
    """lib/actions.json с перечитыванием по mtime: обновление ядра не требует рестарта панели."""
    try:
        mtime = ACTIONS_JSON.stat().st_mtime
    except OSError:
        mtime = None
    with _ACTIONS_LOCK:
        if _ACTIONS_CACHE["spec"] is not None and _ACTIONS_CACHE["mtime"] == mtime:
            return _ACTIONS_CACHE["spec"]
        spec = load_json(ACTIONS_JSON, {}) or {}
        if not isinstance(spec, dict) or not isinstance(spec.get("actions"), dict):
            spec = {"actions": {}, "param_types": {}}
        _ACTIONS_CACHE["spec"] = spec
        _ACTIONS_CACHE["mtime"] = mtime
        return spec


def action_spec(name: str) -> Optional[Dict[str, Any]]:
    adef = load_actions().get("actions", {}).get(name)
    return adef if isinstance(adef, dict) else None


def action_is_readonly(name: str) -> bool:
    adef = action_spec(name) or {}
    return bool(adef.get("readonly", False))


def param_enum(ptype: str) -> List[str]:
    pt = load_actions().get("param_types", {}).get(ptype) or {}
    return [str(x) for x in (pt.get("enum") or [])]


# Типы параметров, у которых пустое значение — отказ, а не «оставить как есть».
# Список по типу (ref), а не по действию: новое действие с тем же параметром
# получит ту же защиту, не вспоминая о ней.
EMPTY_FORBIDDEN_PARAMS = {"profiles"}

# «Ключ на другой адрес сервера»: разовый хост в Endpoint у user-key и share-create
# (`--endpoint=<host>`: домен или IPv4 из тех, что есть у машины; за пользователем не
# сохраняется). Параметр объявляет ядро — lib/actions.json, тип `key_endpoint`, и его
# определение главнее всегда. Пока каталог ядра параметра не знает (ядро старше панели),
# панель держит ту же форму сама: без этого вход «другой адрес» отвечал бы «лишний
# параметр» ещё до моста. Разрешённый СПИСОК хостов проверяет только мост (address_not_here),
# здесь — только форма: мусор не запускает bash вовсе. Старый мост незнакомый аргумент
# отвергает сам (bad_arg), так что ключ с «не тем» адресом молча не уйдёт.
KEY_ENDPOINT_ACTIONS = ("user-key", "share-create")
KEY_ENDPOINT_PARAM = {"ref": "key_endpoint", "required": False}
PARAM_TYPE_FALLBACK: Dict[str, Dict[str, Any]] = {
    "key_endpoint": {"type": "string", "pattern": r"^[A-Za-z0-9.-]{1,253}$", "maxLength": 253},
}
# Хост из ответа моста, который панель готова показать и вписать в имя файла: та же форма.
KEY_HOST_RE = re.compile(r"^[A-Za-z0-9.-]{1,253}$")
# Имя файла .conf из ответа ядра (file_name у user-key) — та же форма, что принимают панель и бот; идёт в заголовок.
KEY_FILE_NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}\.conf$")
# Вердикты сторожа адресов (edge-status) — те же слова, что в таблице «Адреса сервера».
EDGE_VERDICTS = {"ok", "dark", "quiet", "quiet-all", "unused"}
# Состояния A-записей домена из ключей (ga_site_dns_state в lib/website.sh).
EDGE_DNS_STATES = {"ok", "partial", "elsewhere", "none", "unknown"}

# Параметры, которые мост читает из stdin, а не из argv: ключ человека у user-attach-key (ссылка
# vpn:// или текст .conf, docs/CONTRACT.md). В командной строке секрет виден в `ps` любому
# процессу, поэтому ядро помечает такой параметр в lib/actions.json полем "stdin": true и само
# отвергает его в argv. Имя панель держит и сама: секрет не должен уйти в argv ни при каком
# каталоге — ни у ядра постарше, ни при каталоге, где пометку забыли.
STDIN_PARAM_FALLBACK = {"user-attach-key": "config"}
# Предел ядра на stdin (param_types.key_material.maxLength): больше — это не ключ.
STDIN_MAX_BYTES = 64 * 1024


def stdin_param(name: str) -> str:
    """Имя параметра действия, который уходит мосту в stdin; "" — у действия такого нет."""
    adef = action_spec(name) or {}
    for pname, pdef in (adef.get("params") or {}).items():
        if isinstance(pdef, dict) and pdef.get("stdin"):
            return str(pname)
    return STDIN_PARAM_FALLBACK.get(name, "")


def stdin_payload(raw: Any) -> str:
    """Секрет для stdin моста из тела запроса: строка не длиннее предела ядра.

    Пусто — законно: ядро ответит no_config своими словами. Не строка, длиннее
    64 КБ или с нулевым байтом — отказ до моста: такого ключа не бывает, и
    запускать bash ради него незачем.
    """
    if raw is None:
        return ""
    if not isinstance(raw, str):
        raise ActionError("bad_arg", panel_strings()["config_not_string"])
    try:
        size = len(raw.encode("utf-8"))
    except UnicodeEncodeError:
        # Одинокий суррогат (\ud800) из JSON — не текст: без этой ветки encode падал мимо всех
        # проверок, и кривой ввод из интернета получал 500 вместо отказа (находка UI-5).
        raise ActionError("config_unreadable", panel_strings()["config_not_text"])
    if size > STDIN_MAX_BYTES:
        raise ActionError("config_unreadable", panel_strings()["config_too_big"])
    if "\x00" in raw:
        raise ActionError("config_unreadable", panel_strings()["config_not_text"])
    return raw


def validate_params(name: str, params: Dict[str, Any]) -> Dict[str, str]:
    """Проверить параметры по param_types ДО вызова моста; вернуть аргументы для argv.

    Правила те же, что у диспетчера (CONTRACT §4.7): отсутствующий и пустой
    аргумент — разные вещи (`--value=` у profile-set-param = «убрать»),
    missing_arg — только когда обязательный не передан вовсе. Мост проверит
    всё ещё раз; наша проверка нужна, чтобы плохой ввод не запускал bash
    вовсе и чтобы ошибка приходила без ожидания замка.
    """
    adef = action_spec(name)
    if adef is None:
        raise ActionError("unknown_action", f"неизвестное действие: {name}", 404)
    if not isinstance(params, dict):
        raise ActionError("bad_arg", "параметры должны быть объектом")
    spec = load_actions()
    types = spec.get("param_types", {})
    pspec = dict(adef.get("params") or {})
    if name in KEY_ENDPOINT_ACTIONS:
        # setdefault: объявил ядро — работает его определение, а не наше.
        pspec.setdefault("endpoint", KEY_ENDPOINT_PARAM)
    # Параметр из stdin (ключ человека) в argv не попадает ни при каком каталоге: здесь он не
    # проверяется и не принимается — тело запроса отдаёт его отдельно (stdin_payload), а в
    # параметрах он был бы «лишним», то есть отказом, а не аргументом командной строки.
    sp = stdin_param(name)
    if sp:
        pspec.pop(sp, None)
    out: Dict[str, str] = {}
    for key in params:
        if key not in pspec and key != "confirm":
            raise ActionError("bad_arg", f"лишний параметр: {key}")
    for pname, pdef in pspec.items():
        pdef = pdef if isinstance(pdef, dict) else {}
        pref = pdef.get("ref") or pname
        ptype = types.get(pref) or PARAM_TYPE_FALLBACK.get(pref) or {}
        present = pname in params and params[pname] is not None
        if not present:
            if pdef.get("required"):
                raise ActionError("missing_arg", f"не передан обязательный параметр: {pname}")
            continue
        raw = params[pname]
        if isinstance(raw, bool):
            raise ActionError("bad_arg", f"параметр {pname}: булево не принимается")
        val = str(raw).strip() if not isinstance(raw, str) else raw
        if val == "":
            if (pdef.get("ref") or pname) in EMPTY_FORBIDDEN_PARAMS:
                # Пусто законно у `value` («убрать параметр») и у `host`
                # («вернуть IP сервера»), но не у списка профилей: он приходит
                # ровно оттуда, где человек снял все галочки, и понять его как
                # «во все установленные» — молча завести ключи в линейках,
                # которых он не просил (DEFECTS §1.4). Мост отказывает тем же
                # кодом; здесь отказ приходит без ожидания замка и без запуска
                # bash — а заодно не даёт дыре открыться, если ядро подменят.
                raise ActionError("no_profiles_picked", panel_strings()["no_profiles_picked"])
            # Пусто — законное значение (default подставит мост).
            out[pname] = ""
            continue
        if ptype.get("type") == "integer":
            if not re.fullmatch(r"-?[0-9]+", val):
                raise ActionError("bad_arg", f"параметр {pname}: нужно целое число")
            iv = int(val)
            if "minimum" in ptype and iv < int(ptype["minimum"]):
                # Своё объяснение границы (below_minimum: у mtu — ниже 1280 туннель не поднимется у клиентов с IPv6)
                # — словами на языке вызова, а не общим «меньше N».
                why = ptype.get("below_minimum")
                why = why.get(call_lang() or read_language()) or why.get("ru") if isinstance(why, dict) else None
                raise ActionError("bad_arg", str(why) if why else f"параметр {pname}: меньше {ptype['minimum']}")
            if "maximum" in ptype and iv > int(ptype["maximum"]):
                raise ActionError("bad_arg", f"параметр {pname}: больше {ptype['maximum']}")
        if ptype.get("enum") and val not in [str(x) for x in ptype["enum"]]:
            raise ActionError("bad_arg", f"параметр {pname}: допустимо {', '.join(str(x) for x in ptype['enum'])}")
        if ptype.get("maxLength") and len(val) > int(ptype["maxLength"]):
            raise ActionError("bad_arg", f"параметр {pname}: длиннее {ptype['maxLength']}")
        pattern = ptype.get("pattern")
        if pattern:
            try:
                ok = re.fullmatch(pattern, val) is not None
            except re.error:
                ok = False
            if not ok:
                raise ActionError("bad_arg", f"параметр {pname}: недопустимое значение")
        # Перевод строки в аргументе — способ протащить вторую строку в
        # stdout моста; параметры такого не содержат по определению.
        if "\n" in val or "\r" in val or "\x00" in val:
            raise ActionError("bad_arg", f"параметр {pname}: недопустимые символы")
        # Одинокий суррогат не кодируется в UTF-8 и ронял бы запуск моста мимо всех проверок (UI-5).
        try:
            val.encode("utf-8")
        except UnicodeEncodeError:
            raise ActionError("bad_arg", f"параметр {pname}: недопустимые символы")
        out[pname] = val
    return out


def confirm_required(name: str) -> Optional[str]:
    """Для destructive-действий панель требует confirm = значение первого параметра.

    Тот же протокол, что у MCP (CONTRACT §5): случайный клик или чужая
    страница не смогут удалить пользователя одним запросом. Интерфейс
    получает confirm от человека вводом имени (удаление) или согласием в
    диалоге с предупреждением (параметры).
    """
    adef = action_spec(name) or {}
    if not adef.get("destructive"):
        return None
    pspec = adef.get("params") or {}
    # Своё подтверждение (users-del-bulk: число людей) — параметр confirm в каталоге: он уходит мосту, а сверяет его
    # ядро в момент исполнения; здесь — та же сверка «confirm = значение параметра», только параметр — он сам.
    if action_own_confirm(name):
        return "confirm"
    return next(iter(pspec), "")


def action_own_confirm(name: str) -> bool:
    """Объявлен ли у действия свой параметр confirm (users-del-bulk): тогда это обычный параметр моста, а не поле
    панели, и из тела запроса он не изымается."""
    return "confirm" in ((action_spec(name) or {}).get("params") or {})


def build_argv(name: str, params: Dict[str, str]) -> List[str]:
    """argv моста: подчёркивания в имени параметра → дефисы (quota_gb → --quota-gb)."""
    argv = [ACTION_BIN, f"--action={name}", "--json"]
    for k, v in params.items():
        argv.append(f"--{k.replace('_', '-')}={v}")
    return argv


def parse_bridge_output(stdout: str) -> Optional[Dict[str, Any]]:
    """Последняя строка stdout, которая разбирается как JSON-объект со status.

    Контракт (§0 п.3) гарантирует JSON только ПОСЛЕДНЕЙ строкой; всё
    остальное в stdout — нарушение, но не повод ронять вызов: идём с конца
    и берём первый же объект. Первый попавшийся JSON брать нельзя — модуль
    мог напечатать свой промежуточный объект.
    """
    for line in reversed((stdout or "").splitlines()):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if isinstance(obj, dict) and "status" in obj:
            return obj
    return None


def _kill_process_tree(proc: subprocess.Popen) -> None:
    """Убить всю группу процессов, а не только прямого потомка: bash моста
    порождает docker/jq, и осиротевшие внуки держали бы замок ядра."""
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except Exception:
        try:
            proc.terminate()
        except Exception:
            pass
    try:
        proc.wait(timeout=5)
        return
    except Exception:
        pass
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


def audit(who: str, action: str, params: Dict[str, Any], status: str, code: str = "") -> None:
    """Строка в аудит-лог ядра: время, panel, кто, действие, параметры без секретов, статус.

    Формат общий для всего продукта (CONTRACT §7.1): одна строка — один объект
    JSON. `stage` отделяет ПРОСЬБУ от СЛУЧИВШЕГОСЯ: панель пишет `call` (кто и о
    чём попросил, с параметрами и кодом ответа), ядро — `effect` (что на самом
    деле изменилось). Раньше обе записи выглядели одинаково, и одно действие
    читалось как два разных (DEFECTS §2.2).
    """
    try:
        AUDIT_LOG.parent.mkdir(parents=True, exist_ok=True)
        line = json.dumps({"ts": utc_now(), "iface": "panel", "stage": "call", "who": who,
                           "action": action, "params": mask_secrets(params),
                           "status": status, "code": code},
                          ensure_ascii=False, sort_keys=True)
        fd = os.open(str(AUDIT_LOG), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        # Аудит не должен ломать действие: нет прав на /var/log — пишем в stderr.
        sys.stderr.write(f"[admin] audit: {who} {action} {status} {code}\n")


# Видимые строки самой панели (не страницы входа): всё, что человек читает в
# ответе сервера, а не берёт из словаря app.js. RU и EN в паритете — как у
# LOGIN_STRINGS, и проверяются тем же тестом.
PANEL_STRINGS = {
    "ru": {
        "busy": "Сейчас выполняется другое действие ({a}) — повторите через минуту",
        "busy_unknown": "Сейчас выполняется другое действие — повторите через минуту",
        "no_profiles_picked": "Не отмечен ни один профиль — ключ выдавать нечему. Отметьте нужные профили.",
        "config_too_big": "Прислано больше 64 КБ — это не ключ. Нужна ссылка vpn://… или текст файла .conf.",
        "config_not_text": "Это не текст: нужна ссылка vpn://… или текст файла .conf.",
        # Отказы до моста на кривой запрос — тоже на языке панели, а не всегда по-русски (находка UI-8).
        "config_not_string": "Ключ передаётся строкой: ссылкой vpn://… или текстом файла .conf.",
        "stdin_refused": "Действие {a} не принимает данных на вход.",
        # Ускорение AmneziaWG (kmod_job_start): то же слово, что у ядра (kmod_err_busy), — ход виден в карточке.
        "kmod_busy": "Уже идёт установка или перевод модуля ядра — ход виден в карточке «Ускорение AmneziaWG». Повторите, когда закончится.",
        "kmod_bad_op": "Неизвестное действие с модулем ядра: {a}",
    },
    "en": {
        "busy": "Another action is running right now ({a}) — retry in a minute",
        "busy_unknown": "Another action is running right now — retry in a minute",
        "no_profiles_picked": "No profile is ticked — there is nothing to issue a key for. Tick the profiles you need.",
        "config_too_big": "More than 64 KB was sent — that is not a key. A vpn://… link or the text of a .conf file is needed.",
        "config_not_text": "This is not text: a vpn://… link or the text of a .conf file is needed.",
        "config_not_string": "The key is sent as a string: a vpn://… link or the text of a .conf file.",
        "stdin_refused": "Action {a} takes no input data.",
        "kmod_busy": "A kernel module installation or switch is already running — its progress is in the “AmneziaWG acceleration” card. Try again when it ends.",
        "kmod_bad_op": "Unknown kernel module action: {a}",
    },
}


def panel_strings(lang: Optional[str] = None) -> Dict[str, str]:
    lang = lang if lang in PANEL_STRINGS else (call_lang() or read_language())
    return PANEL_STRINGS.get(lang, PANEL_STRINGS["ru"])


# ── Язык ответа на один запрос (L-24) ─────────────────────────────────────────
# Интерфейс панели шлёт язык, на котором его читают, заголовком X-GoAmnezia-Lang (ru|en): админ с английской
# панелью на русском сервере получает слова моста и самой панели по-английски. Каждый запрос живёт в своём
# потоке (ThreadingHTTPServer), поэтому язык лежит в локальном для потока месте; мосту он уходит переменной
# GOAMNEZIA_CALL_LANG (docs/CONTRACT.md §4.7, «Язык ответа — на один вызов»). Нет заголовка или значение не
# ru/en — язык установки, как раньше. Страница входа и её ответы (слой входа) этим не затронуты.
CALL_LANG_HEADER = "X-GoAmnezia-Lang"
_CALL_CTX = threading.local()


def call_lang() -> str:
    """Язык интерфейса того, кто сделал этот запрос: «ru», «en» или пусто (язык установки)."""
    lang = getattr(_CALL_CTX, "lang", "")
    return lang if lang in ("ru", "en") else ""


def snapshot_lang() -> str:
    """Язык снимка частого чтения (_snapshot_key) и ответа моста на него: язык запроса, а без заголовка — язык
    установки, на котором мост такому запросу и так отвечает. Раньше запрос без заголовка (curl, скрипты проверки)
    жил на своих снимках «действие|»: после рестарта холодных, хотя страница на том же языке их уже собрала, и
    собранных второй раз (PERF-08: «холодный» Обзор по curl через 4 мин после рестарта)."""
    return call_lang() or read_language()


# Один замок на мутации из этого процесса: два администратора, нажавшие
# «Установить профиль» в одну секунду, иначе гонятся за flock моста и второй
# получает lock_timeout вместо очереди. Чтение замок не берёт.
_ACTION_LOCK = threading.Lock()
# Сколько ждать своей очереди. Ждать без предела нельзя: profile-install держит
# замок до пятнадцати минут, и второй администратор всё это время смотрел бы в
# «сервер долго не отвечает» — то есть в ответ ни о чём. Нескольких секунд
# хватает, чтобы две кнопки, нажатые подряд, честно встали в очередь, а
# длинное действие сразу получило внятный отказ «занято, повторите».
ACTION_LOCK_WAIT = float(os.getenv("GOAMNEZIA_ADMIN_LOCK_WAIT", "3"))
# Что именно держит замок — чтобы отказ называл причину, а не «занято».
_ACTION_BUSY: Dict[str, Any] = {"name": "", "started": 0.0}

# ── Общий снимок частых чтений: один сбор на всех (CPU-аудит 03.10.2026) ─────
# Чтение из READ_CACHE_TTL без параметров (_shared_read) живёт так:
#  * готовый ответ отдаётся всем, пока не истёк срок, не сменилось поколение (мутация из панели) и не сменились
#    признаки файлов, из которых он собран (_snapshot_sig: inode + mtime_ns + size), — правку из бота, SSH или
#    таймера видно при следующем же чтении, без ожидания срока; признаки снимаются ДО вызова моста, так что файл,
#    сменившийся во время сбора, сразу делает снимок несвежим;
#  * одинаковые одновременные промахи (действие + язык ответа) ждут ОДИН вызов моста (таблица _READ_FLIGHTS):
#    два одновременных traffic раньше были двумя полными сборами (замер: 3,3 CPU-с вместо 1,9);
#  * поколение — в ключе ожидания: запрос, пришедший после мутации, к сбору, начатому до неё, не присоединяется,
#    а такой сбор свой ответ в кэш не кладёт — старое чтение не перезаписывает сброшенный кэш;
#  * ошибка, таймаут или исключение сбора отпускают всех ждущих тем же ответом и освобождают запись; ошибочный
#    ответ в кэш не попадает; таблица ограничена — сверх предела чтение идёт мимо неё, как раньше;
#  * «Обновить» руками (заголовок X-GoAmnezia-Fresh) просит новый сбор, но присоединяется к уже идущему; чтение без
#    ожидания (wait=False) при этом отвечает прежним снимком, а новый собирается в фоне (PERF-08).
# Последний удачный ответ (_READ_LAST_GOOD) мутации не стирают: если новый сбор не удался по сбою транспорта или
# таймауту, экраны показывают прежнюю картину с пометкой stale (read_snapshot), а не пустоту.
_READ_CACHE_LOCK = threading.Lock()
_READ_CACHE: Dict[str, "_Snapshot"] = {}
_READ_LAST_GOOD: Dict[str, "_Snapshot"] = {}
_READ_FLIGHTS: Dict[str, "_Flight"] = {}
_READ_FLIGHTS_MAX = 32
_READ_GEN = 0
# Сколько ждущий ждёт чужой сбор сверх срока самого моста: тот кончается своим таймаутом всегда.
READ_FLIGHT_GRACE = 15.0
# Снимок моложе этого «Обновить» не пересобирает: десять нажатий подряд — один вызов моста.
READ_FRESH_MIN_AGE = 2.0
# Сколько служит прежняя картина, когда новый сбор не удался, и при каких отказах.
READ_STALE_MAX_AGE = 600.0
READ_STALE_CODES = {"timeout", "transport"}
FRESH_HEADER = "X-GoAmnezia-Fresh"


class _Snapshot:
    __slots__ = ("data", "at", "gen", "sig")

    def __init__(self, data: Dict[str, Any], at: float, gen: int, sig: Tuple[Any, ...]):
        self.data, self.at, self.gen, self.sig = data, at, gen, sig


class _Flight:
    __slots__ = ("done", "data", "at")

    def __init__(self, at: float):
        self.done = threading.Event()
        self.data: Optional[Dict[str, Any]] = None
        self.at = at


def _file_sig(path: Any) -> Optional[Tuple[int, int, int]]:
    try:
        st = os.stat(str(path))
    except OSError:
        return None
    return (st.st_ino, st.st_mtime_ns, st.st_size)


def _share_sig() -> Any:
    """Признаки раздач: каталог (раздача появилась или ушла) и в каждой — meta.json и state.json (счётчик
    скачиваний пишет сам процесс раздачи). Активных раздач не больше десятка — обход дешёвый."""
    try:
        names = sorted(e.name for e in os.scandir(str(SHARE_STATE_DIR)) if e.name.startswith("s-"))
    except OSError:
        return None
    return (_file_sig(SHARE_STATE_DIR),) + tuple(
        (n, _file_sig(SHARE_STATE_DIR / n / "meta.json"), _file_sig(SHARE_STATE_DIR / n / "state.json"))
        for n in names[:64])


def _snapshot_sig(name: str) -> Tuple[Any, ...]:
    """Признаки файлов, из которых ядро собирает ответ действия: сменились — снимок несвежий."""
    files: List[Path] = [CONFIG_FILE, USERS_FILE]
    if name == "traffic":
        files.append(STATS_FILE)
    elif name == "edge-status":
        files += [STATE_DIR / "edge_ips.csv", STATE_DIR / "edge_alerts.json", STATE_DIR / "dns.cache"]
    elif name == "kmod-status":
        # Шаг долгого действия пишется в файл хода — новый шаг виден при следующем же опросе, а не через срок снимка.
        files += list(KMOD_FILES)
    sig: Tuple[Any, ...] = tuple(_file_sig(p) for p in files)
    if name == "share-list":
        sig += (_share_sig(),)
    return sig


def _holds_secret(obj: Any, depth: int = 0) -> bool:
    """Есть ли в ответе поле с секретным именем (SECRET_KEYS). Общий снимок держит только публичные ответы: ядро
    приватных ключей и PSK в частых чтениях не отдаёт (amnezia_show, ga_users_public_filter), а если когда-нибудь
    отдаст по ошибке, такой ответ в кэш не ляжет — и дольше одного запроса в памяти панели не проживёт."""
    if depth > 32:
        return True
    if isinstance(obj, dict):
        return any(str(k).lower() in SECRET_KEYS or _holds_secret(v, depth + 1) for k, v in obj.items())
    if isinstance(obj, list):
        return any(_holds_secret(v, depth + 1) for v in obj)
    return False


def _snapshot_invalidate() -> None:
    """Мутация из панели: собранное раньше — несвежее (новое поколение); прежняя картина остаётся только запасом
    на случай сбоя следующего сбора (_READ_LAST_GOOD)."""
    global _READ_GEN
    with _READ_CACHE_LOCK:
        _READ_GEN += 1
        _READ_CACHE.clear()


def _cache_clear() -> None:
    """Полный сброс, вместе с запасом: тесты и всё, что начинает с чистого листа."""
    _snapshot_invalidate()
    with _READ_CACHE_LOCK:
        _READ_LAST_GOOD.clear()


def _note_read(name: str, at: float, stale: Optional[Dict[str, Any]] = None, how: str = "hit") -> None:
    """Запомнить на этот запрос, от какого времени данные действия, как они получены (hit — готовый снимок, join —
    чужой идущий сбор, miss — свой сбор) и не прежняя ли это картина — для snapshot_meta и заголовка
    X-GoAmnezia-Snapshot. Каждый запрос живёт в своём потоке, место — локальное для потока, как у языка."""
    reads = getattr(_CALL_CTX, "reads", None)
    if not isinstance(reads, dict):
        reads = _CALL_CTX.reads = {}
    reads[name] = {"at": at, "stale": stale, "how": how}


def call_fresh() -> bool:
    """Просил ли этот запрос свежий сбор (ручное «Обновить»)."""
    return bool(getattr(_CALL_CTX, "fresh", False))


def _snapshot_key(name: str, lang: str, argv_params: Dict[str, str]) -> str:
    """Ключ снимка: действие, язык ответа и параметры (у частых чтений панели их нет или они постоянны — brief у
    status), упорядоченные, чтобы один и тот же вызов не давал двух снимков."""
    return "|".join([name, lang] + [f"{k}={v}" for k, v in sorted(argv_params.items())])


def _collect(name: str, key: str, fkey: str, flight: Optional[_Flight], call: Any, now: float, gen: int,
             sig: Tuple[Any, ...]) -> Dict[str, Any]:
    """Сбор ведущего: вызов, удачный ответ — в снимок (если за время сбора не было мутации), ждущие отпускаются тем же
    ответом при любом исходе."""
    data: Dict[str, Any] = {"status": "error", "code": "transport", "message": "", "action": name}
    try:
        data = call()
    finally:
        keep = bridge_ok(data) and not _holds_secret(data)
        with _READ_CACHE_LOCK:
            if keep:
                snap = _Snapshot(data, now, gen, sig)
                prev = _READ_LAST_GOOD.get(key)
                if prev is None or prev.at <= now:
                    _READ_LAST_GOOD[key] = snap
                # Мутация во время сбора — ответ мог её не увидеть: в кэш не кладём.
                if _READ_GEN == gen:
                    _READ_CACHE[key] = snap
            if flight is not None and _READ_FLIGHTS.get(fkey) is flight:
                del _READ_FLIGHTS[fkey]
        if flight is not None:
            flight.data = data
            flight.done.set()
    return data


def _collect_bg(name: str, *args: Any) -> None:
    """Фоновый сбор (stale-while-revalidate): сбой — строкой в журнал без данных, ждущих отпустит _collect. Мост этого
    потока идёт с пониженным приоритетом (_bridge_exec, READ_BG_NICE): передний запрос получает процессор первым."""
    _CALL_CTX.background = True
    try:
        _collect(name, *args)
    except Exception as exc:  # noqa: BLE001 — фон не роняет панель
        sys.stderr.write(f"[admin] фоновый сбор {name}: {type(exc).__name__}\n")
    finally:
        _CALL_CTX.background = False


# Фоновые сборы (прежний снимок с новым сбором в фоне, подогрев, wait=False) — с пониженным приоритетом процессора и
# диска (PERF-04): на 1 vCPU холодный Обзор делил ядро между передним status и фоновыми traffic и edge-status (их
# запускают сам Обзор, его запрос трафика и «Настройки»), и первый кадр в браузере ждал 4,2–4,5 с вместо времени одного
# status (1,2–1,5 с). Вес планировщика (CFS): nice 0 — 1024, 10 — 110, 15 — 36, 19 — 15; передний получает ~90 % ядра
# и больше, фон идёт, когда ядро свободно. Между собой фон — по нужности: рукопожатия (traffic, «на связи» Обзора) —
# nice 10, адреса сервера (edge-status) — 19, остальное — 15. ionice — best-effort 7. GOAMNEZIA_READ_BG_NICE=0 — без
# понижения, число — один уровень для всех.
READ_BG_NICE = 15
READ_BG_NICE_BY_ACTION = {"traffic": 10, "edge-status": 19}


def bg_prefix(name: str = "") -> List[str]:
    """Начало argv фонового моста name: nice -n <уровень> [ionice -c 2 -n 7]; выключено или нет nice — пусто."""
    level = READ_BG_NICE_BY_ACTION.get(name, READ_BG_NICE)
    raw = os.getenv("GOAMNEZIA_READ_BG_NICE")
    if raw is not None and raw.strip() != "":
        try:
            level = int(raw)
        except ValueError:
            pass
    level = max(0, min(19, level))
    nice = shutil.which("nice") if level else None
    if not nice:
        return []
    out = [nice, "-n", str(level)]
    ionice = shutil.which("ionice")
    if ionice:
        out += [ionice, "-c", "2", "-n", "7"]
    return out


def _shared_read(name: str, key: str, call: Any, timeout: float, swr: float = 0.0,
                 wait: bool = True) -> Dict[str, Any]:
    """Чтение через общий снимок (см. выше); call() — сам вызов моста. Ответ — тот же объект, что у всех.

    swr > 0 (карточка и список людей, READ_SWR_MAX_AGE): снимок старше срока, но не старше swr секунд, отдаётся сразу,
    а новый сбор идёт в фоне — один на ключ (присоединяется к идущему). «Обновить» руками так не отвечает — ждёт.
    wait=False — подогрев: свежего снимка нет — сбор в фоне, ответ сразу (code pending), снимок ляжет для следующих.
    «Обновить» у чтения без ожидания (Обзор, «Настройки») начинает новый сбор и тогда, когда снимок ещё в сроке (кроме
    снимка моложе READ_FRESH_MIN_AGE), но отвечает, как без «Обновить», прежним снимком: раньше прежний снимок такому
    запросу не годился, и Обзор после «Обновить» терял трафик, «на связи» и адреса сервера до следующего ответа —
    та же «холодная» форма, что после рестарта, без всякой мутации (PERF-08)."""
    ttl = READ_CACHE_TTL[name]
    sig = _snapshot_sig(name)
    now = _now()
    fresh = call_fresh()
    flight: Optional[_Flight] = None
    leader = False
    stale: Optional[_Snapshot] = None
    background = False
    with _READ_CACHE_LOCK:
        gen = _READ_GEN
        fkey = f"{key}|{gen}"
        snap = _READ_CACHE.get(key)
        if (snap is not None and snap.gen == gen and snap.sig == sig and 0 <= now - snap.at < ttl
                and not (fresh and now - snap.at >= READ_FRESH_MIN_AGE)):
            hit: Optional[_Snapshot] = snap
        else:
            hit = None
            prev = _READ_LAST_GOOD.get(key) if (swr > 0 or not wait) and not (fresh and wait) else None
            if prev is not None and 0 <= now - prev.at <= max(swr, ttl):
                stale = prev
            if stale is not None or not wait:
                if _READ_FLIGHTS.get(fkey) is None and len(_READ_FLIGHTS) < _READ_FLIGHTS_MAX:
                    flight = _READ_FLIGHTS[fkey] = _Flight(now)
                    background = True
            else:
                flight = _READ_FLIGHTS.get(fkey)
                if flight is None and len(_READ_FLIGHTS) < _READ_FLIGHTS_MAX:
                    flight = _READ_FLIGHTS[fkey] = _Flight(now)
                    leader = True
    if hit is not None:
        _note_read(name, hit.at)
        return hit.data
    if stale is not None or not wait:
        if background:
            threading.Thread(target=_collect_bg, args=(name, key, fkey, flight, call, now, gen, sig),
                             name=f"ga-read-{name}", daemon=True).start()
        if stale is None:
            return {"status": "error", "code": "pending", "message": "", "action": name}
        _note_read(name, stale.at, how="swr")
        return stale.data
    if flight is not None and not leader:
        # Тот же сбор уже идёт — ждём его ответа, а не запускаем свой.
        if not flight.done.wait(timeout + READ_FLIGHT_GRACE) or flight.data is None:
            return {"status": "error", "code": "timeout", "message": "", "action": name, "timeout_s": timeout}
        _note_read(name, flight.at, how="join")
        return flight.data
    data = _collect(name, key, fkey, flight, call, now, gen, sig)
    _note_read(name, now, how="miss")
    return data


def _busy_answer(name: str) -> Dict[str, Any]:
    """Отказ «занято» вместо молчаливого ожидания (код как у моста: lock_timeout → 409)."""
    running = str(_ACTION_BUSY.get("name") or "")
    s = panel_strings()
    message = _fill(s["busy"], a=running) if running else s["busy_unknown"]
    seconds = int(max(0.0, _now() - float(_ACTION_BUSY.get("started") or 0.0)))
    return {"status": "error", "code": "lock_timeout", "message": message, "action": name,
            "busy_action": running, "busy_seconds": seconds}


def run_action(name: str, params: Optional[Dict[str, Any]] = None, who: str = "panel",
               timeout: Optional[int] = None, confirm: Optional[str] = None,
               use_cache: bool = True, stdin_data: Optional[str] = None,
               swr: float = 0.0, wait: bool = True) -> Dict[str, Any]:
    """Вызвать мост и вернуть его JSON. Всегда dict со status.

    Ошибки запуска и отсутствие JSON превращаются в
    {"status": "error", "code": "transport"|"timeout", …}, чтобы маршрутам не
    приходилось различать «мост ответил ошибкой» и «моста нет».

    stdin_data — секрет для stdin моста (ключ человека у user-attach-key, см.
    stdin_param): не в argv, не в аудит, не в журнал панели. Другому действию
    stdin не положен — отказ до моста.

    Чтения ядра, которые умеет lib/core_read.py (CORE_READ_ACTIONS), отвечает он, в этом же процессе, тем же JSON
    (_read_exec); мост — за всем остальным и за каждым отказом. swr и wait — у общего снимка (_shared_read).
    """
    params = params or {}
    secret_in = bool(stdin_param(name))
    if stdin_data is not None and not secret_in:
        raise ActionError("bad_arg", _fill(panel_strings()["stdin_refused"], a=name))
    if action_own_confirm(name) and params.get("confirm") in (None, ""):
        # Тот же отказ, что у остальных разрушительных без подтверждения, а не «не передан параметр»
        raise ActionError("confirm_required", "подтвердите действие: confirm — сколько пользователей удалить")
    argv_params = validate_params(name, params)
    readonly = action_is_readonly(name)
    need_confirm = confirm_required(name)
    if need_confirm is not None:
        expected = argv_params.get(need_confirm, "") if need_confirm else name
        # Байтами: compare_digest на str с «аня» бросал TypeError, и неверное подтверждение давало 500.
        if confirm is None or not hmac.compare_digest(text_bytes(confirm), text_bytes(expected)):
            raise ActionError("confirm_required",
                              f"подтвердите действие: confirm должен совпадать с {need_confirm or name}")
    lang = call_lang()
    if timeout is None:
        timeout = BRIDGE_TIMEOUT_BY_ACTION.get(name, BRIDGE_TIMEOUT_READ if readonly else BRIDGE_TIMEOUT_DEFAULT)
    argv = build_argv(name, argv_params)
    env = dict(os.environ)
    # Токену панели и стоку кодов в окружении моста делать нечего.
    for k in (ADMIN_TOKEN_ENV, "GOAMNEZIA_TFA_SINK", "BOT_TOKEN"):
        env.pop(k, None)
    env["GOAMNEZIA_WHO"] = f"panel:{who}"
    env["GOAMNEZIA_CALLER"] = "panel"
    # Язык ответа моста — язык интерфейса того, кто нажал (L-24); без него — язык установки.
    env.pop("GOAMNEZIA_CALL_LANG", None)
    if lang:
        env["GOAMNEZIA_CALL_LANG"] = lang
    if readonly and use_cache and name in READ_CACHE_TTL and stdin_data is None:
        if not read_swr_on():
            swr, wait = 0.0, True
        # Частое чтение — через общий снимок: один сбор на всех читателей. Слова ответа (message, hint) — на
        # языке запроса, поэтому у каждого языка свой снимок; у каждого набора параметров — тоже. Запрос без языка —
        # на языке установки и с её снимками (snapshot_lang, PERF-08); мосту язык снимка уходит явно, чтобы ответ
        # совпал с ключом и тогда, когда язык установки сменили посреди сбора.
        slang = snapshot_lang()
        env["GOAMNEZIA_CALL_LANG"] = slang
        return _shared_read(name, _snapshot_key(name, slang, argv_params),
                            lambda: _read_exec(name, argv_params, slang, who, argv, env, timeout, secret_in)[0],
                            float(timeout), swr=swr, wait=wait)
    lock = None if readonly else _ACTION_LOCK
    if lock is not None:
        if not lock.acquire(timeout=ACTION_LOCK_WAIT):
            result = _busy_answer(name)
            audit(who, name, audit_params(name, argv_params), "error", "lock_timeout")
            return result
        _ACTION_BUSY["name"] = name
        _ACTION_BUSY["started"] = _now()
    try:
        if readonly and stdin_data is None:
            data, ran = _read_exec(name, argv_params, lang, who, argv, env, timeout, secret_in)
        else:
            data, ran = _bridge_exec(name, argv, env, timeout, stdin_data, secret_in)
    finally:
        if lock is not None:
            _ACTION_BUSY["name"] = ""
            _ACTION_BUSY["started"] = 0.0
            lock.release()
    if not readonly:
        # Любая мутация делает снимки чтения устаревшими — экраны покажут новое состояние сразу, а не по сроку.
        # В том числе неудачная и оборванная по таймауту: она могла успеть изменить часть.
        _snapshot_invalidate()
        audit(who, name, audit_params(name, argv_params), str(data.get("status")), audit_code(name, data))
    elif ran and (action_spec(name) or {}).get("secret"):
        # Выдача ключа — в аудит без самого ключа (CONTRACT §7.1).
        audit(who, name, audit_params(name, argv_params), str(data.get("status")), audit_code(name, data))
    return data


# ── Частые чтения без моста: lib/core_read.py ядра (PERF-01, часть C) ────────
# Каждое чтение было процессом install.sh (bash, модули, словарь, десятки jq): на сервере в 1 vCPU карточка человека
# 2,3 с, ключ 3 с, адреса подписки 2,5 с. Модуль ядра отвечает на те же чтения из тех же файлов в этом процессе тем
# же JSON (сверено тестом tests/test_core_read.py) под тем же замком ядра — на чтение (flock LOCK_SH на config.lock);
# всё, в чём он не уверен (отказ, редкая ветка, правка ядра после сверки), он отдаёт мосту. Модуль лежит рядом с мостом
# (lib/ у install.sh) и перечитывается по mtime: обновление ядра не требует рестарта панели. Выключатель —
# GOAMNEZIA_CORE_READ=0 (всё через мост, как в 1.0.9); GOAMNEZIA_CORE_READ_ROOT — корень ядра для стендов, где мост —
# обёртка вокруг install.sh (macOS: bash 5 не /bin/bash).
CORE_READ_ROOT = os.getenv("GOAMNEZIA_CORE_READ_ROOT") or os.path.dirname(os.path.realpath(ACTION_BIN))
# Что умеет модуль (lib/core_read.py, ACTIONS) — только чтения; остальное и не спрашиваем.
CORE_READ_ACTIONS = ("user-list", "user-show", "user-key", "share-list", "sub-list", "sub-show", "page-list")
_CORE_READ_LOCK = threading.Lock()
_CORE_READ: Dict[str, Any] = {"sig": None, "core": None}


def core_read() -> Any:
    """CoreRead ядра или None: модуля нет (ядро старше), выключен, не загрузился."""
    if os.getenv("GOAMNEZIA_CORE_READ", "1") == "0":
        return None
    path = os.path.join(CORE_READ_ROOT, "lib", "core_read.py")
    try:
        st = os.stat(path)
    except OSError:
        return None
    sig = (st.st_ino, st.st_mtime_ns, st.st_size)
    with _CORE_READ_LOCK:
        if _CORE_READ["sig"] == sig:
            return _CORE_READ["core"]
        core = None
        try:
            spec = importlib.util.spec_from_file_location(f"ga_core_read_{st.st_ino}_{st.st_mtime_ns}", path)
            if spec is not None and spec.loader is not None:
                mod = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(mod)
                core = mod.CoreRead(CORE_READ_ROOT)
        except Exception as exc:  # noqa: BLE001 — нет быстрого пути, есть мост
            sys.stderr.write(f"[admin] core_read не загрузился ({type(exc).__name__}) — чтения через мост\n")
            core = None
        _CORE_READ["sig"], _CORE_READ["core"] = sig, core
        return core


def _read_exec(name: str, argv_params: Dict[str, str], lang: str, who: str, argv: List[str], env: Dict[str, str],
               timeout: float, secret_in: bool) -> Tuple[Dict[str, Any], bool]:
    """Чтение: ответ модуля ядра (lib/core_read.py), а если он отдал мосту — мост. (ответ, дошло ли до ответа)."""
    core = core_read() if name in CORE_READ_ACTIONS else None
    if core is not None:
        try:
            data = core.answer(name, argv_params, lang, f"panel:{who}")
        except Exception as exc:  # noqa: BLE001 — ошибка быстрого пути: отвечает мост, в журнал — только вид ошибки
            sys.stderr.write(f"[admin] core_read {name}: {type(exc).__name__} — отвечает мост\n")
            data = None
        if isinstance(data, dict):
            return data, True
    return _bridge_exec(name, argv, env, timeout, None, secret_in)


def _bridge_exec(name: str, argv: List[str], env: Dict[str, str], timeout: float,
                 stdin_data: Optional[str], secret_in: bool) -> Tuple[Dict[str, Any], bool]:
    """Один процесс моста: (ответ, дошёл ли мост до ответа). Не запустился или убит по таймауту — False. Фоновый сбор
    (_collect_bg) — с пониженным приоритетом: nice и ionice исполняют мост на своём месте (тот же pid и группа)."""
    if getattr(_CALL_CTX, "background", False):
        argv = bg_prefix(name) + list(argv)
    try:
        # stdin открыт только под секрет: остальным действиям мост не должен ждать ввода
        proc = subprocess.Popen(argv, stdin=subprocess.PIPE if stdin_data is not None else subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True, env=env)
    except (OSError, ValueError) as exc:
        return {"status": "error", "code": "transport", "message": str(exc), "action": name}, False
    try:
        out_b, err_b = proc.communicate(input=stdin_data.encode("utf-8") if stdin_data is not None else None,
                                        timeout=timeout)
    except subprocess.TimeoutExpired:
        _kill_process_tree(proc)
        # communicate() после убийства забирает остатки и закрывает трубы —
        # иначе дескрипторы pipe утекают на каждом таймауте.
        try:
            proc.communicate(timeout=5)
        except Exception:
            for stream in (proc.stdout, proc.stderr):
                try:
                    stream.close()
                except Exception:
                    pass
        sys.stderr.write(f"[admin] bridge {name}: timeout after {timeout}s\n")
        return {"status": "error", "code": "timeout", "message": "", "action": name, "timeout_s": timeout}, False
    stdout = out_b.decode("utf-8", errors="replace")
    stderr = err_b.decode("utf-8", errors="replace")
    data = parse_bridge_output(stdout)
    if data is None:
        if secret_in:
            # Мост, упавший на разборе ключа, мог напечатать его кусок — хвост вывода мимо журнала.
            sys.stderr.write(f"[admin] bridge {name}: no JSON, rc={proc.returncode} (output not logged: a key went on stdin)\n")
        else:
            sys.stderr.write(f"[admin] bridge {name}: no JSON, rc={proc.returncode}, stderr={stderr[-300:]!r}\n")
        data = {"status": "error", "code": "transport", "message": "", "action": name, "rc": str(proc.returncode)}
    return data, True


def bridge_ok(r: Dict[str, Any]) -> bool:
    return isinstance(r, dict) and r.get("status") == "success"


def read_snapshot(name: str, who: str, params: Optional[Dict[str, str]] = None, swr: float = 0.0,
                  wait: bool = True) -> Dict[str, Any]:
    """Частое чтение для экранов: run_action через общий снимок, а если новый сбор не удался по сбою транспорта
    или таймауту — прежняя удачная картина (не старше READ_STALE_MAX_AGE) с пометкой stale в snapshot_meta:
    что случилось и от какого времени данные. Пустота на месте списка, выданная за успех, хуже. Отказ по существу
    (битый users.json, замок) — как прежде, ошибкой: прятать его за старой картиной нельзя. swr — снимок старше
    срока отдаётся сразу, новый сбор — в фоне (READ_SWR_MAX_AGE, _shared_read); wait=False — годного снимка нет,
    сбор в фоне, ответ сразу с кодом pending (данные будут у следующего запроса)."""
    params = dict(params or {})
    r = run_action(name, params, who, swr=swr, wait=wait)
    if bridge_ok(r) or str(r.get("code") or "") not in READ_STALE_CODES:
        return r
    with _READ_CACHE_LOCK:
        prev = _READ_LAST_GOOD.get(_snapshot_key(name, snapshot_lang(), validate_params(name, params)))
    if prev is None or not 0 <= _now() - prev.at <= READ_STALE_MAX_AGE:
        return r
    _note_read(name, prev.at, {"code": str(r.get("code") or ""), "message": str(r.get("message") or "")}, how="stale")
    return prev.data


def read_prefetch(name: str, who: str) -> None:
    """Подогреть снимок для следующего экрана, не задерживая этот: прежней удачной картины не старше
    READ_SWR_MAX_AGE нет — сбор в фоне (один на ключ). Список людей так готовит адреса сервера для карточки.
    С GOAMNEZIA_READ_SWR=0 не греет ничего."""
    if not read_swr_on():
        return
    key = _snapshot_key(name, snapshot_lang(), {})
    with _READ_CACHE_LOCK:
        prev = _READ_LAST_GOOD.get(key)
    if prev is not None and 0 <= _now() - prev.at <= READ_SWR_MAX_AGE.get(name, READ_CACHE_TTL.get(name, 0.0)):
        return
    try:
        run_action(name, {}, who, wait=False)
    except ActionError:
        pass


def _iso_ts(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).isoformat()


def snapshot_meta(*names: str) -> Dict[str, Any]:
    """Возраст данных экрана: snapshot_at — когда собрано самое старое из прочитанного этим запросом (ISO, UTC);
    stale — если вместо нового сбора отдана прежняя картина: код, текст сбоя и since — время той картины."""
    reads = getattr(_CALL_CTX, "reads", None)
    reads = reads if isinstance(reads, dict) else {}
    seen = [reads[n] for n in names if n in reads]
    out: Dict[str, Any] = {"snapshot_at": _iso_ts(min(r["at"] for r in seen)) if seen else utc_now()}
    for r in seen:
        if r.get("stale"):
            out["stale"] = dict(r["stale"], since=_iso_ts(r["at"]))
            break
    # Прежний снимок без ожидания нового сбора (READ_SWR_MAX_AGE): какие чтения, от какого времени и сколько ему секунд
    # (age — по часам сервера: Обзор по нему решает, переспросить ли раньше обычного) — новый уже идёт.
    swr = [n for n in names if n in reads and reads[n].get("how") == "swr"]
    if swr:
        since = min(reads[n]["at"] for n in swr)
        out["swr"] = {"since": _iso_ts(since), "reads": swr, "age": int(max(0.0, _now() - since))}
    return out


# Код моста → HTTP-статус для фронтенда. Сообщение и код уходят как есть.
BRIDGE_HTTP_STATUS = {
    "bad_arg": 400, "missing_arg": 400, "confirm_required": 400, "invalid_param": 400,
    "invalid_param_value": 400, "params_invalid": 400, "invalid_subnet": 400, "invalid_mtu": 400,
    "invalid_host": 400, "invalid_format": 400, "invalid_label": 400, "invalid_scope": 400,
    "invalid_days": 400, "invalid_ips": 400, "invalid_port": 400, "invalid_agent_id": 400,
    # invalid_state — не on/off в agent-pin; already_strong — «усилить» доступ, у
    # которого токен уже есть: состояние, а не ошибка запроса.
    "invalid_state": 400, "already_strong": 409,
    "unknown_action": 404, "user_not_found": 404, "agent_not_found": 404,
    "backup_not_found": 404, "unknown_template": 404, "lock_timeout": 409, "port_busy": 409,
    "port_taken": 409, "profile_exists": 409, "subnet_overlap": 409, "not_implemented": 501,
    # Предполётная проверка портов (docs/PREFLIGHT.md §6): порт свободен, но закрыт
    # локальным файрволом — конфликт состояния, а не ошибка запроса; needs_site /
    # not_pro / no_domain — та же природа: действию нужен другой режим.
    "closed_local": 409, "needs_site": 409, "not_pro": 409, "no_domain": 409,
    # panel_disabled — miniapp-rotate на выключенной панели: менять нечего, это
    # состояние, а не ошибка запроса; без строки браузер получал бы 500.
    "panel_disabled": 409,
    # no_profiles_picked — пустой список профилей у user-add: запрос неполон,
    # и отвечать на него надо так же, как на любой неверный аргумент.
    "no_profiles_picked": 400,
    # Спринт 4: обновления из upstream и импорт. unreachable — источники
    # (GitHub/Docker Hub) недоступны с сервера: 503, повторить позже;
    # already_current / no_previous / already_managed / not_adoptable /
    # container_missing — конфликт состояния, а не ошибка запроса.
    "unreachable": 503, "already_current": 409, "no_previous": 409, "tag_not_found": 404,
    "already_managed": 409, "not_adoptable": 409, "unsupported_container": 409, "container_not_found": 404,
    "invalid_container": 400, "container_missing": 409, "conf_read_failed": 409,
    # Страница подключения и зеркало сборок (docs/CLIENTS.md §9): pages_need_domain —
    # режим без домена с настоящим сертификатом, состояние сервера; page_limit,
    # user_disabled, mirror_busy / no_space / too_big / unverified — тоже состояние;
    # mirror_fetch_failed — источник не отдал сборку, как unreachable у обновлений.
    "pages_need_domain": 409, "invalid_ttl": 400, "page_not_found": 404, "page_limit": 409,
    "user_disabled": 409, "unknown_app": 404, "not_mirrorable": 409, "mirror_busy": 409,
    "mirror_no_space": 409, "mirror_too_big": 409, "mirror_unverified": 409, "mirror_fetch_failed": 503,
    # Отказы формы аргумента у модулей страниц и зеркала — 400; нет ключа в
    # профиле или каталога — 404; служба страниц не поднялась, нет curl или
    # python3 — сервер сейчас не может, 503 (как unreachable).
    "invalid_argument": 400, "invalid_page_id": 400, "invalid_profiles": 400, "invalid_platform": 400,
    "invalid_line": 400, "invalid_toggle": 400, "invalid_name": 400, "peer_not_found": 404,
    "catalog_missing": 404, "unit_failed": 503, "no_curl": 503, "no_python": 503,
    "timeout": 504, "transport": 502,
    # Логи: «строк нет» бывает по разным причинам, и браузер обязан их различать.
    # Нечего читать — 404 (контейнера/юнита/файла нет); читать нечем или логи
    # выключены при запуске — 409 (состояние сервера); демон молчит — 503.
    "logs_no_container": 404, "logs_no_unit": 404, "logs_absent": 404,
    "logs_driver_unreadable": 409, "logs_no_docker": 409, "logs_no_journal": 409,
    "logs_docker_down": 503, "logs_read_failed": 500, "bad_component": 400,
    # Адрес сервера в ключе (разовый --endpoint у user-key/share-create, свой адрес у
    # endpoint-set): негодный IPv4 и адрес/домен, которого у машины нет, — неверный аргумент;
    # машина не видит своих адресов и закреплённый адрес пропал с машины — состояние сервера.
    # Без строки здесь отказ с понятным message ядра уходил в браузер как 500.
    "invalid_ip": 400, "address_not_here": 400, "addresses_unknown": 409, "address_gone": 409,
    # Привязка старого ключа (user-attach-key): ключ не прислан или не читается — неверный запрос;
    # ключ от другого сервера, чужой или уже лежит на сервере — конфликт с состоянием, а не форма.
    # foreign_container — отказ установки профиля: имя его контейнера занял контейнер приложения
    # Amnezia с людьми (сначала подхватить его в «Импорте»). no_private_key — выдача по ключу,
    # выданному в приложении Amnezia: состояние пира, а не сбой сервера (без строки уходил 500).
    "no_config": 400, "config_unreadable": 400, "server_mismatch": 409, "key_mismatch": 409,
    "already_has_key": 409, "foreign_container": 409, "no_private_key": 409,
    # 0.5.0, «Протоколы»: суточной проверки обновлений ещё не было (upstream-check cached=on) — нечего
    # показать, а не сбой; перезапуск всех профилей поднял не всех, профилей нет, перенос порта у людей
    # приложения без согласия, обновление с откатом, контейнер без опубликованного порта — состояние сервера;
    # Docker не отвечает — сервер сейчас не может. Без строк отказ с понятным message уходил в браузер как 500.
    "no_cached_check": 404, "restart_failed": 409, "no_profiles": 409, "adopted_keyless": 409,
    "update_failed": 409, "port_unpublished": 409, "docker_unreachable": 503,
    # «Бэкапы»: на диске не хватает места под копию — сервер сейчас не может (507, как у хранилищ); зашифрованный
    # архив восстанавливается только в SSH-меню (там спросят пароль) — состояние, а не ошибка; неверная
    # периодичность расписания — неверный аргумент.
    "low_disk": 507, "backup_encrypted_needs_ssh": 409, "bad_schedule": 400,
    # «Настройки»: недопустимый домен или путь — неверный аргумент; Let's Encrypt отказал, у шаблона нет index.html
    # или своих файлов — состояние (режим и домен остались прежними); источник шаблона не отдал его — сервер сейчас
    # не может, как unreachable.
    "invalid_domain": 400, "invalid_path": 400, "cert_failed": 409, "no_index": 409, "app_shell": 409,
    "broken_assets": 409, "download_failed": 503,
    # 0.6.0, Ленивый Pro и линия на UDP 443 (lib/modes.sh): кривое число ключей и домен-IP или непереводимая кириллица —
    # неверный аргумент; отказ проверки до изменений (домен не сюда, чужое на портах, место 2.0 занято людьми
    # приложения), подхват не удался и «линия — только в Pro» — состояние сервера, а не 500.
    "invalid_keys": 400, "domain_is_ip": 400, "idn_failed": 400,
    "dns_not_here": 409, "app_container_busy": 409, "awg2_container_busy": 409, "adopt_failed": 409, "mode_not_pro": 409,
    # Добавление людей (user-add, users-add-bulk): кривое число или префикс — неверный аргумент; имя занято, в подсети
    # профиля нет мест, случайные имена кончились — состояние сервера, а не 500.
    "invalid_count": 400, "invalid_prefix": 400, "user_exists": 409, "subnet_full": 409, "names_exhausted": 409,
    # Удаление сразу нескольких (users-del-bulk): не ровно один способ выбора — неверный запрос; число в подтверждении
    # не совпало с выбранным сейчас (список изменился), никого, больше 100, контейнер не принял первую пачку или
    # прервано до неё — состояние сервера, а не 500 (у первых трёх в ответе matched — сколько выбрано сейчас).
    "invalid_selection": 400, "confirm_mismatch": 409, "nothing_selected": 409, "too_many": 409,
    "user_del_failed": 409, "interrupted": 409,
}


# Почему не удалось выслать код входа → ответ HTTP. Держим рядом с картой кодов
# моста: правило одно и то же — число должно значить то же, что и текст.
TFA_HTTP_STATUS = {
    "too_often": 429, "tfa_off": 503, "chat_not_started": 409, "send_failed": 502,
}


def bridge_http_status(r: Dict[str, Any]) -> int:
    if bridge_ok(r):
        return 200
    return BRIDGE_HTTP_STATUS.get(str(r.get("code") or ""), 500)


# ════════════════════════════════════════════════════════════════════════════
# Данные страниц поверх действий ядра
# ════════════════════════════════════════════════════════════════════════════
def parse_iso(ts: str) -> Optional[float]:
    ts = (ts or "").strip()
    if not ts:
        return None
    try:
        dt = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        return dt.timestamp()
    except ValueError:
        pass
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.timestamp()
    except ValueError:
        return None


def user_state(rec: Dict[str, Any], now: Optional[float] = None) -> str:
    """on | off | exp | lim — как в SSH-меню и боте (пометки ● ○ ⏳ ▮)."""
    if not isinstance(rec, dict):
        return "on"
    if not rec.get("enabled", True):
        return "off"
    now = now if now is not None else _now()
    exp = parse_iso(str(rec.get("expires") or ""))
    if exp is not None and exp < now:
        return "exp"
    traffic = rec.get("traffic") or {}
    try:
        used = int(traffic.get("rx") or 0) + int(traffic.get("tx") or 0)
        quota = int(rec.get("quota_bytes") or 0)
    except (TypeError, ValueError):
        used, quota = 0, 0
    if quota > 0 and used >= quota:
        return "lim"
    return "on"


USER_MARKS = {"on": "●", "off": "○", "exp": "⏳", "lim": "▮"}


def handshakes_by_pubkey(traffic: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    """pubkey → {ts, rx, tx, endpoint} из ответа traffic (peers по профилям)."""
    out: Dict[str, Dict[str, Any]] = {}
    for prof in (traffic.get("profiles") or []):
        if not isinstance(prof, dict):
            continue
        for peer in (prof.get("peers") or []):
            if not isinstance(peer, dict) or not peer.get("pubkey"):
                continue
            try:
                ts = int(peer.get("latest_handshake_ts") or 0)
            except (TypeError, ValueError):
                ts = 0
            out[str(peer["pubkey"])] = {"ts": ts, "rx": peer.get("rx") or 0, "tx": peer.get("tx") or 0,
                                        "endpoint": str(peer.get("endpoint") or ""),
                                        "profile": str(prof.get("profile") or "")}
    return out


PROFILE_LINES = ("1.0", "1.5", "2.0", "3.1")


def profile_lines(cfg: Optional[Dict[str, Any]] = None) -> Dict[str, str]:
    """{профиль: линия} — фактическая линия профиля из config.json (поле line: его пишут установка и подхват, им же
    ядро подписывает ключ — ga_profile_line). Место профиля — только имя контейнера: приложение Amnezia держит 3.1 и
    в amnezia-awg2, и тогда 2.0 встаёт в awg3 (LZ-02). Профиля без поля line здесь нет — его подпишут по месту."""
    cfg = cfg if cfg is not None else read_config()
    profiles = cfg.get("profiles") if isinstance(cfg.get("profiles"), dict) else {}
    out: Dict[str, str] = {}
    for pid, prof in profiles.items():
        line = str(prof.get("line") or "") if isinstance(prof, dict) else ""
        if line in PROFILE_LINES:
            out[str(pid)] = line
    return out


def decorate_user(rec: Dict[str, Any], hs: Dict[str, Dict[str, Any]], now: float,
                  lines: Optional[Dict[str, str]] = None) -> Dict[str, Any]:
    """Добавить пользователю пометку, онлайн и рукопожатия по профилям (ключей здесь нет); lines — линии профилей
    (profile_lines): у каждого пира — line его профиля."""
    rec = dict(rec)
    state = user_state(rec, now)
    rec["state"] = state
    rec["mark"] = USER_MARKS.get(state, "·")
    last = 0
    peers = rec.get("peers") if isinstance(rec.get("peers"), dict) else {}
    new_peers: Dict[str, Any] = {}
    for pid, peer in peers.items():
        peer = dict(peer) if isinstance(peer, dict) else {}
        # Приватные ключи и psk мост уже вырезал (users_list); страхуемся ещё раз.
        peer.pop("privkey", None)
        peer.pop("psk", None)
        # Есть ли у сервера приватная часть ключа этого пира. У пира из
        # контейнера Amnezia (импорт установки или подхват после потери
        # настроек) её нет вовсе: сервер знает только открытый ключ клиента, и
        # ни .conf, ни vpn://, ни QR по такому пиру не собрать — мост отвечает
        # no_private_key. Мост даёт признак сам (lib/users.sh,
        # ga_users_public_filter), здесь он только приводится к bool, чтобы
        # интерфейс не гадал по отсутствию поля. Ядро постарше признака не
        # шлёт — там «ключ есть», то есть прежнее поведение панели.
        peer["has_key"] = peer.get("has_key") is not False
        # Линия пира — линия его профиля (AWG31-01): ядро её у пира не пишет, и вкладки ключей в карточке
        # подписывались по месту (awg2 → 2.0, awg3 → 3.1). На сервере, где amnezia-awg2 подхвачен из приложения
        # с 3.1, а 2.0 встала в awg3, вкладка «2.0» отдавала ключ 3.1, а «3.1» — ключ 2.0.
        if lines is not None and str(peer.get("line") or "") not in PROFILE_LINES and lines.get(str(pid)):
            peer["line"] = lines[str(pid)]
        info = hs.get(str(peer.get("pubkey") or ""))
        ts = int(info["ts"]) if info else 0
        try:
            ts = max(ts, int(peer.get("last_handshake") or 0))
        except (TypeError, ValueError):
            pass
        peer["handshake_ts"] = ts
        peer["online"] = bool(ts and now - ts < ONLINE_WINDOW)
        if info:
            peer["live_rx"] = info["rx"]
            peer["live_tx"] = info["tx"]
        last = max(last, ts)
        new_peers[str(pid)] = peer
    rec["peers"] = new_peers
    rec["profiles"] = rec.get("profiles") if isinstance(rec.get("profiles"), list) else list(new_peers)
    rec["last_handshake"] = last
    rec["online"] = bool(last and now - last < ONLINE_WINDOW)
    return rec


def service_state(unit: str) -> str:
    """active | inactive | failed | unknown — systemctl is-active; без systemd — unknown."""
    try:
        proc = subprocess.run(["systemctl", "is-active", unit], capture_output=True, text=True, timeout=4)
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    state = (proc.stdout or "").strip() or "unknown"
    return state if re.fullmatch(r"[a-z-]{1,24}", state) else "unknown"


def unit_exists(unit: str) -> bool:
    """Есть ли у systemd такой юнит (файл в /etc/systemd/system или системный)."""
    try:
        proc = subprocess.run(["systemctl", "cat", unit], capture_output=True, text=True, timeout=4)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return proc.returncode == 0


_SERVICES_CACHE: Dict[str, Any] = {"at": 0.0, "data": {}, "mode": None, "refreshing": False}
_SERVICES_LOCK = threading.Lock()
# Здоровье служб — до девяти вызовов systemctl; живёт столько же, сколько снимок status (READ_CACHE_TTL).
SERVICES_TTL = READ_CACHE_TTL["status"]


def services_health(mode: str) -> Dict[str, str]:
    """Здоровье служб рядом с ядром. Кэш — как у снимка status (полминуты), на тот же режим; картина старше срока, но
    не старше SERVICES_SWR_MAX_AGE, отдаётся сразу, а новая собирается в фоне (одна за раз, PERF-03)."""
    now = _now()
    with _SERVICES_LOCK:
        data = _SERVICES_CACHE["data"] if _SERVICES_CACHE["mode"] == mode else {}
        age = now - _SERVICES_CACHE["at"]
        if data and 0 <= age < SERVICES_TTL:
            return data
        if data and 0 <= age <= SERVICES_SWR_MAX_AGE and read_swr_on():
            if not _SERVICES_CACHE["refreshing"]:
                _SERVICES_CACHE["refreshing"] = True
                threading.Thread(target=_services_refresh_bg, args=(mode,), name="ga-services", daemon=True).start()
            return data
    return _services_collect(mode, now)


def _services_refresh_bg(mode: str) -> None:
    try:
        _services_collect(mode, _now())
    except Exception as exc:  # noqa: BLE001 — фон не роняет панель
        sys.stderr.write(f"[admin] фоновый сбор служб: {type(exc).__name__}\n")
    finally:
        with _SERVICES_LOCK:
            _SERVICES_CACHE["refreshing"] = False


def _services_collect(mode: str, now: float) -> Dict[str, str]:
    """Сам сбор: systemctl is-active по службам режима (и есть ли юниты по требованию)."""
    units = ["docker", "goamnezia-bot", "goamnezia-admin"]
    # nginx держит сайт в обоих режимах с сайтом, а не только в Pro: в lite_site
    # его отсутствие в списке скрывало упавший сайт.
    if mode in ("pro", "lite_site"):
        units.append("nginx")
    # Транспорт агентов и страницы подключения — по факту наличия юнита: их
    # ставят по требованию, и «inactive» на установке без них читалось бы как
    # поломка.
    for unit in ("goamnezia-mcp-http", "goamnezia-pages"):
        if unit_exists(unit):
            units.append(unit)
    data = {u: service_state(u) for u in units}
    # Бот ставится по желанию: на сервере без него «inactive» читалось как упавший бот —
    # «не установлена», как в SSH (находка PUI-06, 25.09.2026). Панель понимает это значение.
    if data.get("goamnezia-bot") != "active" and not unit_exists("goamnezia-bot"):
        data["goamnezia-bot"] = "not_installed"
    with _SERVICES_LOCK:
        if _SERVICES_CACHE["mode"] != mode or _SERVICES_CACHE["at"] <= now:
            _SERVICES_CACHE.update({"at": now, "data": data, "mode": mode})
    return data


def status_brief_params() -> Dict[str, str]:
    """Краткий status (brief=on — без портов, сайта и адресов в ключах людей) для частых экранов, если ядро его
    знает: Обзору и «Настройкам» этих полей не нужно, а это половина цены вызова. Ядро старше — полный, как раньше."""
    params = (action_spec("status") or {}).get("params") or {}
    return {"brief": "on"} if isinstance(params, dict) and "brief" in params else {}


def _read_note(name: str) -> Optional[Dict[str, Any]]:
    reads = getattr(_CALL_CTX, "reads", None)
    r = reads.get(name) if isinstance(reads, dict) else None
    return r if isinstance(r, dict) and "at" in r else None


def read_age(name: str) -> Optional[float]:
    """Возраст данных действия, прочитанных этим запросом (секунды от начала их сбора); не читали — None."""
    r = _read_note(name)
    return max(0.0, _now() - float(r["at"])) if r is not None else None


def read_how(name: str) -> str:
    """Как этот запрос получил данные действия (_note_read): hit, join, miss, swr (прежний снимок, новый сбор — в фоне),
    stale; не читали — пусто."""
    r = _read_note(name)
    return str(r.get("how") or "") if r is not None else ""


def handshakes_known(st: Dict[str, Any], tr: Dict[str, Any]) -> bool:
    """Прочитал ли traffic рукопожатия каждого работающего профиля, в котором есть люди (status.profiles[].peers).
    Ядро прячет сбой `awg show` в пустой список пиров профиля, и «0 на связи» по такому ответу было бы выдумкой;
    Docker не ответил (docker_unreachable) — тоже «не знаем». Нет status — судить не по чему, верим traffic."""
    if not bridge_ok(st):
        return True
    dumped = {str(p.get("profile") or ""): bool(p.get("peers")) for p in (tr.get("profiles") or []) if isinstance(p, dict)}
    for p in st.get("profiles") or []:
        if not isinstance(p, dict):
            continue
        state = str(p.get("state") or "")
        if state == "docker_unreachable":
            return False
        try:
            peers = int(p.get("peers") or 0)
        except (TypeError, ValueError):
            peers = 0
        if state == "running" and peers > 0 and not dumped.get(str(p.get("profile") or ""), False):
            return False
    return True


def overview_payload(who: str) -> Dict[str, Any]:
    # Состояние ядра — суть Обзора: прежняя картина не старше READ_SWR_MAX_AGE["status"] отдаётся сразу (сбор — в фоне,
    # ответ несёт swr), иначе ждём сбор, как раньше (PERF-03).
    st = read_snapshot("status", who, status_brief_params(), swr=READ_SWR_MAX_AGE["status"])
    cfg = read_config()
    pub = public_config(cfg)
    now = _now()
    payload: Dict[str, Any] = {
        "ok_status": bridge_ok(st),
        "status_error": None if bridge_ok(st) else {"code": st.get("code"), "message": st.get("message")},
        "version": str(st.get("version") or pub["version"]),
        "installed": bool(st.get("installed", pub["installed"])),
        "mode": str(st.get("mode") or pub["mode"]),
        "domain": str(st.get("domain") or pub["domain"]),
        "server_ip": str(st.get("server_ip") or pub["server_ip"]),
        "endpoint_host": str(st.get("endpoint_host") or pub["endpoint_host"]),
        # Вписанного в ключи IP на машине больше нет (L-01, status.endpoint_host_gone): ключи с ним не соединятся
        "endpoint_host_gone": st.get("endpoint_host_gone") is True,
        # Последний переезд на другой IP (L-06) и итог суточной проверки обновлений (L-07) — для «тревог» Обзора
        "server_ip_change": server_ip_change_payload(st.get("server_ip_change")),
        "upstream": upstream_summary_payload(st.get("upstream")),
        # Место на диске (status.disk, OPS-01) и откат неудачного обновления (status.update_rollback, OPS-02) — для
        # предупреждений Обзора (и мини-аппа, у него тот же Обзор)
        "disk": disk_payload(st.get("disk")),
        "update_rollback": update_rollback_payload(st.get("update_rollback")),
        # Пакет Docker обновлён, а служба старая (status.docker_stale, DK-02) — строка на Обзоре, пока так
        "docker_stale": docker_stale_payload(st.get("docker_stale")),
        # Модуль ядра AmneziaWG без исправлений при профиле 3.1 (status.kmod, KMOD_PLAN А3) — строка на Обзоре
        "kmod": kmod_payload(st.get("kmod")),
        # Линии на сервере (DUP-LINE-01): нет 2.0 — строка и «Переставить на 2.0»; свободные места — какой линией встанут
        "lines_check": lines_check_payload(st.get("lines_check")),
        "free_lines": free_lines_payload(st.get("free_lines")),
        # Сообщение после обновления: своя линия повторяет подхваченную 3.1, 2.0 нет — блок «Исправить» / «Позже»
        "dupline_fix": dupline_fix_payload(st.get("dupline_fix")),
        "lang": pub["lang"],
        "users_total": int(st.get("users") or 0) if str(st.get("users") or "0").isdigit() else 0,
        # Сколько людей на связи и сколько прошло через сервер: None — «не знаем» (рукопожатия ещё собираются или не
        # прочитаны), а не ноль; плитка тогда пишет «— на связи» (PERF-03).
        "users_online": None,
        "profiles": [],
        "services": services_health(str(st.get("mode") or pub["mode"])),
        "panel_url": public_panel_url(cfg),
        "traffic_total": None,
        # Плитка «Трафик» целиком — период, сумма, столбики, время снимка (traffic_kpi_payload, PNL-07); None — как у
        # traffic_total: учёт ещё собирается.
        "traffic_kpi": None,
        "generated_at": utc_now(),
    }
    # Что ещё собирается в фоне (pending): страница переспросит через пару секунд, а не через десять.
    pending: List[str] = []
    profiles = st.get("profiles") if isinstance(st.get("profiles"), list) else []
    for p in profiles:
        if not isinstance(p, dict):
            continue
        pid = str(p.get("profile") or "")
        cfgp = pub["profiles"].get(pid, {})
        payload["profiles"].append({
            "profile": pid, "container": str(p.get("container") or ""),
            "state": str(p.get("state") or "missing"), "port": p.get("port"),
            "line": str(p.get("line") or cfgp.get("line") or ""), "peers": p.get("peers") or 0,
            "image_tag": str(p.get("image_tag") or ""), "enabled": bool(p.get("enabled", True)),
            "subnet": cfgp.get("subnet", ""),
            # Пакет данных не влезает в мобильные сети из-за большого S4 (S4-FIX) — строка «Обзора» и кнопка.
            "packet_risk": packet_risk_payload(p.get("packet_risk")),
            # Ту же линию держит ещё профиль — подпись с портом; подхвачен у приложения (DUP-LINE-01).
            **profile_lines_fields(p),
        })
    # Рукопожатия и счётчики Обзор не ждёт (PERF-03): снимок не старше TRAFFIC_TOTALS_MAX_AGE — из него (сумма трафика,
    # PERF-05), иначе сбор в фоне и pending. Число «на связи» — только по свежим (не старше READ_SWR_MAX_AGE["traffic"],
    # CR-2) и прочитанным рукопожатиям (handshakes_known): снимок постарше даёт сумму с её возрастом (traffic_total_age),
    # а «на связи» — None и pending, пока идёт новый сбор; прежняя картина после сбоя сбора (stale) — тоже без «на связи».
    tr = read_snapshot("traffic", who, swr=TRAFFIC_TOTALS_MAX_AGE, wait=False)
    if bridge_ok(tr):
        hs = handshakes_by_pubkey(tr)
        online = 0
        rx = tx = 0
        for u in (tr.get("users") or []):
            if not isinstance(u, dict):
                continue
            d = decorate_user(u, hs, now)
            if d["online"]:
                online += 1
            t = u.get("traffic") or {}
            try:
                rx += int(t.get("rx") or 0)
                tx += int(t.get("tx") or 0)
            except (TypeError, ValueError):
                pass
        age = read_age("traffic")
        fresh = age is not None and age <= READ_SWR_MAX_AGE["traffic"]
        if fresh and handshakes_known(st, tr):
            payload["users_online"] = online
        elif not fresh and read_swr_on():
            pending.append("traffic")                 # «на связи» ждёт свежие рукопожатия — их сбор уже идёт
        payload["traffic_total"] = {"rx": rx, "tx": tx}
        payload["traffic_total_age"] = int(age or 0)
        note = _read_note("traffic")
        payload["traffic_kpi"] = traffic_kpi_payload(tr, payload["traffic_total"], float(note["at"]) if note else None)
    elif str(tr.get("code") or "") == "pending":
        pending.append("traffic")
    # Адреса машины (edge-status) — блок edge всегда, когда сторож ответил: шапка SSH показывает таблицу «Адреса
    # сервера» и на машине с одним адресом (адрес и его A-запись, решение владельца), и данные для неё у любого
    # интерфейса обязаны быть. Нынешний рисует таблицу от двух адресов, а при одном — только строки о беде с
    # A-записями домена из ключей (как SSH, критик 24.09 п.1). Строки и DNS — белым списком. Обзор их не ждёт: снимок
    # до 10 мин или сбор в фоне (pending), команда туннеля до тех пор — с адресом сервера (PERF-03).
    edge = run_action("edge-status", {}, who, swr=READ_SWR_MAX_AGE["edge-status"], wait=False)
    if str(edge.get("code") or "") == "pending":
        pending.append("edge-status")
    try:
        edge_count = int(edge.get("count") or 0) if bridge_ok(edge) else 0
    except (TypeError, ValueError):
        edge_count = 0
    dns = edge_dns_payload(edge.get("dns")) if bridge_ok(edge) else None
    ips = edge_ips_payload(edge)
    # Команда SSH-туннеля — с адресом, на который реально приходят (PUI-25, tunnel_host).
    payload["tunnel_host"] = tunnel_host(edge, payload["server_ip"])
    if ips or (dns and (dns.get("foreign") or dns.get("state") in ("elsewhere", "none"))):
        payload["edge"] = {"count": edge_count, "domain_endpoint": bool(edge.get("domain_endpoint")),
                           "ips": ips, "dns": dns}
    # «Обновить» (X-GoAmnezia-Fresh): трафик и адреса отданы прежним снимком, а новый сбор уже идёт (_shared_read) —
    # страница переспросит через пару секунд и покажет новый, а не ждёт обычного круга (PERF-08).
    if call_fresh():
        for act in ("traffic", "edge-status"):
            if read_how(act) == "swr" and act not in pending:
                pending.append(act)
    payload["pending"] = pending
    # Возраст данных и пометка «показана прежняя картина» (общий снимок, read_snapshot).
    payload.update(snapshot_meta("status", "traffic"))
    return payload


def users_payload(who: str) -> Dict[str, Any]:
    r = read_snapshot("user-list", who)
    if not bridge_ok(r):
        return {"users": [], "error": {"code": r.get("code"), "message": r.get("message")}}
    # Рукопожатия — подсказка «в сети» рядом со списком: прежний снимок сразу, новый — в фоне (READ_SWR_MAX_AGE).
    tr = read_snapshot("traffic", who, swr=READ_SWR_MAX_AGE["traffic"])
    hs = handshakes_by_pubkey(tr) if bridge_ok(tr) else {}
    # Адреса сервера для карточки, которую откроют из этого списка, — подогреваются в фоне (PERF-01).
    read_prefetch("edge-status", who)
    now = _now()
    lines = profile_lines()
    users = [decorate_user(u, hs, now, lines) for u in (r.get("users") or []) if isinstance(u, dict) and u.get("name")]
    # admin первым (его создаёт мастер установки), остальные по имени.
    users.sort(key=lambda u: (str(u.get("name")) != "admin", str(u.get("name")).lower()))
    return {"users": users, "online": sum(1 for u in users if u["online"]), "generated_at": utc_now(),
            **snapshot_meta("user-list", "traffic")}


def safe_key_host(value: Any) -> str:
    """Хост из ответа моста — только той формы, что панель сама пропустила бы в --endpoint."""
    host = str(value or "").strip()
    return host if KEY_HOST_RE.fullmatch(host) else ""


def _ip_or_empty(value: Any) -> str:
    try:
        return str(ipaddress.ip_address(str(value or "").strip()))
    except ValueError:
        return ""


def _word(value: Any, allowed: set) -> Optional[str]:
    """Слово из ответа моста, если оно из разрешённых; иначе None. Проверка типа — первой: список или
    объект на месте слова ронял бы `in set` в TypeError (нехешируемо) и маршрут — в 500."""
    return value if isinstance(value, str) and value in allowed else None


# Метка времени ядра (ga_now: 2026-09-27T10:00:00Z) — только такой формы, иначе пусто.
CORE_TS_RE = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
# Что стало с вписанным в ключи адресом при переезде (lib/amnezia.sh amnezia_server_ip_check)
SERVER_IP_PIN_ACTIONS = {"", "moved", "kept", "dropped"}
# Тег образа или релиза: цифры, буквы, точки, дефисы — как у ga_up_tag_safe, не длиннее 128
UPSTREAM_TAG_RE = re.compile(r"^[A-Za-z0-9._-]{0,128}$")


def _core_ts(value: Any) -> str:
    return value if isinstance(value, str) and CORE_TS_RE.fullmatch(value) else ""


def server_ip_change_payload(value: Any) -> Optional[Dict[str, Any]]:
    """Последний переезд сервера на другой IP (status.server_ip_change, L-06) для «IP изменился» на Обзоре —
    белым списком: адреса — только адреса, время — метка ядра, действие с вписанным адресом — moved | kept |
    dropped | пусто. Переездов не было (или запись испорчена) — None."""
    if not isinstance(value, dict) or not _ip_or_empty(value.get("new")):
        return None
    return {"old": _ip_or_empty(value.get("old")), "new": _ip_or_empty(value.get("new")),
            "at": _core_ts(value.get("at")), "endpoint_host": safe_key_host(value.get("endpoint_host")),
            "endpoint_host_action": _word(value.get("endpoint_host_action"), SERVER_IP_PIN_ACTIONS) or ""}


# Уровни места на диске (ga_disk_json в lib/common.sh) и этапы, на которых обновление откатывается (ga_upd_rollback
# в lib/update.sh).
DISK_LEVELS = {"ok", "low", "critical"}
UPDATE_STAGES = {"snapshot", "record", "migration", "check"}
# Версия продукта — как GOAMNEZIA_VERSION в lib/common.sh
PRODUCT_VERSION_RE = re.compile(r"^[0-9][0-9A-Za-z.+-]{0,31}$")


def _text_or_empty(value: Any, limit: int) -> str:
    """Строка из ответа моста без управляющих символов и не длиннее limit — иначе пусто."""
    return value if isinstance(value, str) and len(value) <= limit and not re.search(r"[\x00-\x1f\x7f]", value) else ""


def disk_payload(value: Any) -> Optional[Dict[str, Any]]:
    """Место на разделе каталога продукта (status.disk, OPS-01) для «мало места» на Обзоре — белым списком: числа
    в МБ и процентах, уровень ok | low | critical и пороги. df не ответил или запись испорчена — None."""
    if not isinstance(value, dict) or _word(value.get("level"), DISK_LEVELS) is None:
        return None
    out: Dict[str, Any] = {"path": _text_or_empty(value.get("path"), 256), "level": value["level"]}
    for key in ("total_mb", "used_mb", "free_mb", "used_pct", "low_mb", "critical_mb"):
        num = value.get(key)
        if isinstance(num, bool) or not isinstance(num, int) or num < 0:
            return None
        out[key] = num
    return out


# Почему служба Docker считается старой (docker_stale_probe в lib/docker.sh) и кто перезапускал её в прошлый раз.
DOCKER_STALE_REASONS = {"version", "build", "api"}
DOCKER_RESTART_BY = {"watch", "manual"}
# Версия, сборка или версия API Docker: «29.1.3», «29.1.3-0ubuntu3~24.04.2», «41ca978», «1.52»
DOCKER_VER_RE = re.compile(r"^[0-9A-Za-z][0-9A-Za-z.+~_-]{0,63}$")


def docker_stale_payload(value: Any) -> Optional[Dict[str, Any]]:
    """Пакет Docker обновлён, а служба старая (status.docker_stale, DK-02) — для строки-предупреждения на Обзоре и
    кнопки «Перезапустить Docker»: версии бинаря и демона, причина, с какого времени, прошлая попытка сторожа и раньше
    чего он сам не перезапустит — белым списком. Служба свежая (или запись испорчена) — None."""
    if not isinstance(value, dict) or _word(value.get("reason"), DOCKER_STALE_REASONS) is None:
        return None

    def ver(v: Any) -> str:
        return v if isinstance(v, str) and DOCKER_VER_RE.fullmatch(v) else ""
    out: Dict[str, Any] = {"reason": value["reason"], "since": _core_ts(value.get("since")),
                           "retry_after": _core_ts(value.get("retry_after"))}
    for key in ("binary_version", "binary_build", "daemon_version", "daemon_build", "client_api", "daemon_api",
                "binary_label", "daemon_label"):
        out[key] = ver(value.get(key))
    last = value.get("last_attempt")
    out["last_attempt"] = None
    if isinstance(last, dict) and _core_ts(last.get("at")):
        ok = last.get("ok")
        out["last_attempt"] = {"at": _core_ts(last.get("at")), "ok": ok if isinstance(ok, bool) else None,
                               "by": _word(last.get("by"), DOCKER_RESTART_BY) or "",
                               "code": last.get("code") if isinstance(last.get("code"), str)
                               and re.fullmatch(r"[a-z_]{0,40}", last.get("code")) else ""}
    return out


# Версия модуля ядра из /sys/module/amneziawg/version: «3.1.20260812», «3.1.20260906+kaskad-k31.1»
KMOD_VER_RE = re.compile(r"^[0-9A-Za-z][0-9A-Za-z.+_~-]{0,127}$")


PACKET_RISK_FIELDS = ("packet", "budget", "s4", "safe_s4", "mtu", "keyless")


def packet_risk_payload(value: Any) -> Optional[Dict[str, Any]]:
    """Риск пакета данных профиля (status.profiles[].packet_risk, S4-FIX): {packet, budget, s4, safe_s4, mtu, keyless}
    — пакет при стандартном MTU 1280 больше бюджета 1400 из-за большого S4; на карточке и «Обзоре» — предупреждение и
    кнопка «Исправить S4». Белым списком, целыми числами; ядро старше поля или запись испорчена — None."""
    if not isinstance(value, dict):
        return None
    out: Dict[str, Any] = {}
    for k in PACKET_RISK_FIELDS:
        v = value.get(k)
        if not isinstance(v, int) or isinstance(v, bool) or v < 0 or v > 100000:
            return None
        out[k] = v
    return out


# Линии на сервере (DUP-LINE-01): какие линии понимает панель и как ядро подписывает профиль.
LINE_WORDS = ("1.0", "1.5", "2.0", "3.1")
# Подпись ядра (status.profiles[].title, dupline_fix.title): «AmneziaWG 3.1 · порт 6714 · из приложения» — на языке ядра;
# панель строит свою из line/port/imported, эту только пропускает белым списком знаков.
PROFILE_TITLE_RE = re.compile(r"^AmneziaWG [0-9.]{3}[ 0-9A-Za-zА-Яа-яЁё·().,—-]{0,64}$")


# Кому что сделать после «Переставить на 2.0» (lines_check.reline.steps, dupline_fix.steps; итог profile-reline — там же
# kind): у каждого пользователя его действие (ga_amn_reline_preview, решение координатора 15.10). Слова ядра на языке
# вызова: имена пользователей (не больше 20, дальше «и ещё N») и что им делать.
RELINE_STEP_KINDS = ("users", "failed", "subscription", "nobody", "page", "key", "app")
RELINE_STEPS_MAX = 8
RELINE_STEP_TEXT_MAX = 1500


def reline_steps_payload(value: Any) -> Optional[List[Dict[str, str]]]:
    """Шаги ядра белым списком: [{kind из RELINE_STEP_KINDS, text — непустая строка не длиннее RELINE_STEP_TEXT_MAX без
    управляющих знаков}], не больше RELINE_STEPS_MAX; негодный шаг выпадает. Поля нет (ядро старше или краткий status —
    N-3) — None: «не считали» не выдаётся за «никому ничего делать»."""
    if not isinstance(value, list):
        return None
    out: List[Dict[str, str]] = []
    for st in value:
        if not isinstance(st, dict) or st.get("kind") not in RELINE_STEP_KINDS or not isinstance(st.get("text"), str):
            continue
        text = st["text"].strip()
        if not text or len(text) > RELINE_STEP_TEXT_MAX or re.search(r"[\x00-\x1f\x7f]", text):
            continue
        out.append({"kind": str(st["kind"]), "text": text})
        if len(out) >= RELINE_STEPS_MAX:
            break
    return out


def lines_check_payload(value: Any) -> Dict[str, Any]:
    """Линии на сервере (status.lines_check, DUP-LINE-01): no_20 — профили стоят, а 2.0 (и 1.x) нет: старые версии
    приложений и роутеры Keenetic не подключатся ни к одному; shared — линии, которые держат два профиля и больше;
    missing — линии пары 2.0 / 3.1, которых нет; reline — свой профиль, который можно «Переставить» на недостающую линию
    ({profile, from, line, port, title} или None). Белым списком; ядро старше поля — пустая картина (предупреждать не о
    чем). text ядра не передаём: панель говорит своими словами на языке экрана."""
    v = value if isinstance(value, dict) else {}
    shared: List[Dict[str, Any]] = []
    for e in v.get("shared") if isinstance(v.get("shared"), list) else []:
        if not isinstance(e, dict) or str(e.get("line") or "") not in LINE_WORDS:
            continue
        profs = [str(p) for p in (e.get("profiles") if isinstance(e.get("profiles"), list) else [])
                 if isinstance(p, str) and PROFILE_ID_RE.fullmatch(p)]
        shared.append({"line": str(e["line"]), "profiles": profs})
    missing = [str(m) for m in (v.get("missing") if isinstance(v.get("missing"), list) else []) if m in ("2.0", "3.1")]
    rl = v.get("reline") if isinstance(v.get("reline"), dict) else None
    reline = None
    if rl and PROFILE_ID_RE.fullmatch(str(rl.get("profile") or "")) and str(rl.get("line") or "") in ("2.0", "3.1"):
        port = rl.get("port")
        title = str(rl.get("title") or "")
        reline = {"profile": str(rl["profile"]), "from": str(rl.get("from") or "") if str(rl.get("from") or "") in LINE_WORDS else "",
                  "line": str(rl["line"]),
                  "port": port if isinstance(port, int) and not isinstance(port, bool) and 0 < port < 65536 else 0,
                  "title": title if PROFILE_TITLE_RE.fullmatch(title) else ""}
        # Кому что сделать после перестановки — окну согласия (S-1 проверки 15.10); краткий status их не несёт.
        steps = reline_steps_payload(rl.get("steps"))
        if steps is not None:
            reline["steps"] = steps
    return {"no_20": v.get("no_20") is True, "shared": shared, "missing": missing, "reline": reline}


def dupline_fix_payload(value: Any) -> Optional[Dict[str, Any]]:
    """Сообщение после обновления (status.dupline_fix, DUP-LINE-01): миграция нашла сервер, где своя линия повторяет
    подхваченную 3.1 приложения, а 2.0 нет, — {profile, from, line, port, title, users, detected_at}; на Обзоре — блок
    «Ошибка прошлых версий…» с «Исправить» (тот же поток «Переставить на 2.0») и «Позже». Белым списком; поля нет или
    запись испорчена — None. text ядра не передаём: панель говорит своими словами на языке экрана."""
    if not isinstance(value, dict) or not PROFILE_ID_RE.fullmatch(str(value.get("profile") or "")):
        return None
    line = str(value.get("line") or "")
    if line not in ("2.0", "3.1"):
        return None
    port, users = value.get("port"), value.get("users")
    title = str(value.get("title") or "")
    at = str(value.get("detected_at") or "")
    out = {"profile": str(value["profile"]), "from": str(value.get("from") or "") if str(value.get("from") or "") in LINE_WORDS else "",
           "line": line, "port": port if isinstance(port, int) and not isinstance(port, bool) and 0 < port < 65536 else 0,
           "title": title if PROFILE_TITLE_RE.fullmatch(title) else "",
           "users": users if isinstance(users, int) and not isinstance(users, bool) and 0 <= users <= 100000 else 0,
           "detected_at": at if re.fullmatch(r"[0-9T:+.Z-]{10,40}", at) else ""}
    steps = reline_steps_payload(value.get("steps"))
    if steps is not None:
        out["steps"] = steps
    return out


def reline_preview_payload(who: str, profile: str) -> Dict[str, Any]:
    """Окно согласия «Переставить на 2.0» в панели (S-1, N-3 проверки 15.10): кому что сделать после — шаги ядра из
    полного status (краткий, которым живут Обзор и «Протоколы», их не считает). Шаги этого профиля — из
    lines_check.reline, нет там — из dupline_fix; status не ответил или шагов нет — steps None (окно без списка)."""
    st = read_snapshot("status", who, {})
    steps = None
    if bridge_ok(st):
        rl = lines_check_payload(st.get("lines_check")).get("reline")
        for r in (rl, dupline_fix_payload(st.get("dupline_fix"))):
            if isinstance(r, dict) and r.get("profile") == profile and "steps" in r:
                steps = r["steps"]
                break
    return {"profile": profile, "steps": steps}


def free_lines_payload(value: Any) -> Dict[str, str]:
    """Свободные места и линия, которая встанет на каждое по «Установить» (status.free_lines, DUP-LINE-01):
    {awg3: "2.0"} — панель подписывает свободное место ею заранее. Белым списком; ядро старше поля — {}."""
    v = value if isinstance(value, dict) else {}
    return {str(k): str(l) for k, l in v.items() if PROFILE_ID_RE.fullmatch(str(k)) and l in LINE_WORDS}


def profile_lines_fields(p: Dict[str, Any]) -> Dict[str, Any]:
    """Поля профиля о линиях (status.profiles[] и profiles-status, DUP-LINE-01): line_shared — ту же линию держит ещё
    профиль (подпись с портом), imported — подхвачен у приложения Amnezia (переставлять нельзя), title — подпись ядра.
    Ядро старше полей — line_shared None: панель решит по списку профилей сама."""
    title = str(p.get("title") or "")
    return {"line_shared": p.get("line_shared") if isinstance(p.get("line_shared"), bool) else None,
            "imported": p.get("imported") is True,
            "title": title if PROFILE_TITLE_RE.fullmatch(title) else ""}


# Модуль ядра по выбору (этап Б, CONTRACT §4.7a): слова status.kmod / kmod-status, которые панель понимает.
KMOD_STATES = {"off", "ready", "on", "fallback", "failed", "unpatched", "busy"}
KMOD_ENGINES = {"kernel", "program", "unknown", "stopped"}
KMOD_WANTS = {"kernel", "program"}
KMOD_OWNERS = {"goamnezia", "kaskad", "other"}
KMOD_PROGRESS_ACTIONS = {"install", "rebuild", "engine", "remove"}
# Код причины или отказа (no_module_for_kernel, kmod_clients_lost…) и шаг хода (build, restart:awg2) — слово, не текст
KMOD_CODE_RE = re.compile(r"^[a-z0-9_:-]{1,64}$")
KMOD_KERNEL_RE = re.compile(r"^[A-Za-z0-9._+~-]{1,128}$")
# Имя пакета Debian (dkms, gcc-13, linux-headers-6.8.0-36-generic)
KMOD_PKG_RE = re.compile(r"^[a-z0-9][a-z0-9.+-]{0,127}$")


def _kmod_text(value: Any, limit: int = 400) -> str:
    """Фраза ядра (причина, ход, отказ) для экрана: управляющие символы и их соседние пробелы — одним пробелом, не
    длиннее limit."""
    if not isinstance(value, str):
        return ""
    return re.sub(r"[\s\x00-\x1f\x7f]*[\x00-\x1f\x7f][\s\x00-\x1f\x7f]*", " ", value).strip()[:limit]


def _kmod_code(value: Any) -> str:
    return value if isinstance(value, str) and KMOD_CODE_RE.fullmatch(value) else ""


def _kmod_kernel(value: Any) -> str:
    return value if isinstance(value, str) and KMOD_KERNEL_RE.fullmatch(value) else ""


def _kmod_version(value: Any) -> str:
    return value if isinstance(value, str) and KMOD_VER_RE.fullmatch(value) else ""


def _kmod_packages(value: Any) -> List[str]:
    return [p for p in (value if isinstance(value, list) else [])[:32] if isinstance(p, str) and KMOD_PKG_RE.fullmatch(p)]


def kmod_payload(value: Any) -> Optional[Dict[str, Any]]:
    """Модуль ядра AmneziaWG на хосте (status.kmod, KMOD_PLAN А3) — для строки-предупреждения на Обзоре: загружен ли,
    версия, есть ли метка набора исправлений и warn — загружен без метки, а есть профиль 3.1. С этапа Б (1.0.13) — ещё
    state, code и reason: выбран модуль, а профили работают программой (fallback), или установка на этом ядре не удалась
    (failed) — та же строка, что в шапке SSH-меню. Белым списком; ядро старше поля или запись испорчена — None."""
    if not isinstance(value, dict) or not isinstance(value.get("loaded"), bool):
        return None
    return {"loaded": value["loaded"], "version": _kmod_version(value.get("version")),
            "patched": value.get("patched") is True, "warn": value.get("warn") is True,
            "state": _word(value.get("state"), KMOD_STATES) or "", "code": _kmod_code(value.get("code")),
            "reason": _kmod_text(value.get("reason"))}


def update_rollback_payload(value: Any) -> Optional[Dict[str, Any]]:
    """Обновление не встало и откатано (status.update_rollback, OPS-02): на какую версию шли, какая вернулась, этап,
    вернулись ли код и данные, из какого архива — белым списком. Отката не было — None. Причина словами ядра (reason)
    — на языке сервера; панель говорит своими словами по этапу, reason — только запасом."""
    if not isinstance(value, dict):
        return None
    fv = value.get("failed_version")
    if not (isinstance(fv, str) and PRODUCT_VERSION_RE.fullmatch(fv)):
        return None
    v = value.get("version")
    return {"at": _core_ts(value.get("at")), "stage": _word(value.get("stage"), UPDATE_STAGES) or "",
            "reason": _text_or_empty(value.get("reason"), 300), "failed_version": fv,
            "version": v if isinstance(v, str) and PRODUCT_VERSION_RE.fullmatch(v) else "",
            "code_restored": value.get("code_restored") is True, "data_restored": value.get("data_restored") is True,
            "archive": _text_or_empty(value.get("archive"), 512)}


def upstream_summary_payload(value: Any) -> Optional[Dict[str, Any]]:
    """Итог суточной проверки обновлений (status.upstream, L-07) для «обновление» на Обзоре и значка
    «Обновления» — белым списком. Проверок ещё не было — None. Полный отчёт — /api/upstream (по кнопке)."""
    if not isinstance(value, dict):
        return None

    def tag(v: Any) -> str:
        return v if isinstance(v, str) and UPSTREAM_TAG_RE.fullmatch(v) else ""
    rel = value.get("client_release")
    profiles = []
    for p in (value.get("profiles") if isinstance(value.get("profiles"), list) else [])[:8]:
        if isinstance(p, dict) and _word(p.get("profile"), set(LINE_BASE_BY_PROFILE)):
            profiles.append({"profile": p["profile"], "current_tag": tag(p.get("current_tag")),
                             "available_tag": tag(p.get("available_tag")), "update": p.get("update") is True})
    unsupported = [u for u in (value.get("unsupported") if isinstance(value.get("unsupported"), list) else [])[:32]
                   if isinstance(u, str) and re.fullmatch(r"[A-Za-z0-9_]{1,64}", u)]
    return {"checked": _core_ts(value.get("checked")), "attempted": _core_ts(value.get("attempted")),
            "reachable": value.get("reachable") is True, "updates_available": value.get("updates_available") is True,
            "hint": str(value.get("hint") or "")[:500],
            "hint_key": _word(value.get("hint_key"), {"update", "current", "client_only", "unreachable"}) or "",
            "client_release": ({"current": tag(rel.get("current")), "latest": tag(rel.get("latest")),
                                "update": rel.get("update") is True} if isinstance(rel, dict) else None),
            "profiles": profiles, "unsupported": unsupported}


def edge_dns_payload(dns: Any) -> Optional[Dict[str, Any]]:
    """A-записи домена из ключей (edge-status .dns) для Обзора — белым списком, как key_choices:
    домен формы хоста, состояние — одно из пяти слов ga_site_dns_state, адреса — только адреса
    (не больше 16). Незнакомое состояние — null: интерфейс тогда молчит, а не гадает."""
    if not isinstance(dns, dict) or _word(dns.get("state"), EDGE_DNS_STATES) is None:
        return None

    def ips(v: Any) -> List[str]:
        return [ip for ip in (_ip_or_empty(x) for x in (v if isinstance(v, list) else [])[:16]) if ip]
    return {"domain": safe_key_host(dns.get("domain")), "state": dns["state"], "a": ips(dns.get("a")),
            "foreign": ips(dns.get("foreign")), "cloudflare": dns.get("cloudflare") is True}


# Счётчики строки «Адреса сервера» (lib/edgeips.sh ga_edge_status_json): люди, пакеты и байты за 15 мин, час, сутки.
EDGE_IP_COUNTERS = ("users", "packets_15m", "packets_1h", "packets_day", "bytes_15m", "bytes_1h", "bytes_day")


def edge_ips_payload(edge: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Строки таблицы «Адреса сервера» из edge-status — белым списком, как key_choices и dns.

    Адрес — только адрес, вердикт — слово сторожа (иначе null: интерфейс тогда пишет «тихо», а не
    чужое слово), счётчики — неотрицательные числа или null (у ядра старше 0.4.4 байтов нет — «—»),
    in_dns — булево или null, silent_since — метка времени или пусто. Не больше 32 строк.
    Прежде строки уходили в браузер как есть, любым полем, которое положит мост.
    """
    if not bridge_ok(edge) or not isinstance(edge.get("ips"), list):
        return []
    out: List[Dict[str, Any]] = []
    for e in edge["ips"][:32]:
        ip = _ip_or_empty(e.get("ip")) if isinstance(e, dict) else ""
        if not ip:
            continue
        row: Dict[str, Any] = {"ip": ip, "verdict": _word(e.get("verdict"), EDGE_VERDICTS),
                               "in_dns": e.get("in_dns") if isinstance(e.get("in_dns"), bool) else None}
        for k in EDGE_IP_COUNTERS:
            v = e.get(k)
            # jq печатает большие числа и с плавающей точкой — число принимаем любое, отдаём целым
            ok = isinstance(v, (int, float)) and not isinstance(v, bool) and v == v and 0 <= v < float("inf")
            row[k] = int(v) if ok else None
        since = str(e.get("silent_since") or "")
        row["silent_since"] = since if re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]{2,15}Z?", since) else ""
        out.append(row)
    return out


def tunnel_host(edge: Dict[str, Any], server_ip: str) -> str:
    """Адрес для команды SSH-туннеля («Как открыть панель», «О программе»).

    Обычно это server_ip из ядра. Но на машине с несколькими адресами server_ip — адрес
    ИСХОДЯЩИХ (его и видят сервисы «мой IP»), а входящие на нём у части хостингов не
    доходят вовсе: на сервере A панель печатала `root@193.233.246.207`, а SSH и клиенты
    приходят на .50 и .84 (находка PUI-25). Сторож адресов знает, куда клиенты реально
    приходят (вердикт ok), — если основной адрес не из таких, а другой из таких, команда
    берёт первый такой: входящие на нём доказаны трафиком. Без данных сторожа — server_ip.
    """
    ip = str(server_ip or "")
    # Сравнение — по разобранному адресу: IPv6 в конфиге бывает записан иначе, чем в ответе сторожа.
    main = _ip_or_empty(ip)
    rows = edge_ips_payload(edge)
    if len(rows) < 2 or any(r["ip"] == main and r["verdict"] == "ok" for r in rows):
        return ip
    return next((r["ip"] for r in rows if r["verdict"] == "ok"), ip)


def key_choices_payload(edge: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Варианты «адреса сервера в ключе» из edge-status — ровно то, что примет --endpoint.

    Белым списком полей и значений: вердикт — одним из слов сторожа (незнакомое → null,
    интерфейс тогда слова не пишет), users/in_dns — числом/булевым или null. Порядок ядра
    сохраняется (default первым, затем домены, затем IP, dark — в конце).
    """
    if not bridge_ok(edge) or not isinstance(edge.get("key_choices"), list):
        return []
    out: List[Dict[str, Any]] = []
    seen: set = set()
    for c in edge["key_choices"][:64]:
        if not isinstance(c, dict):
            continue
        host = safe_key_host(c.get("host"))
        if not host or host.lower() in seen:
            continue
        seen.add(host.lower())
        users = c.get("users")
        out.append({
            "host": host,
            "kind": "domain" if c.get("kind") == "domain" else "ip",
            "default": c.get("default") is True,
            "verdict": _word(c.get("verdict"), EDGE_VERDICTS),
            "users": users if isinstance(users, int) and not isinstance(users, bool) else None,
            "in_dns": c.get("in_dns") if isinstance(c.get("in_dns"), bool) else None,
        })
    return out


def user_card_payload(who: str, name: str) -> Tuple[int, Dict[str, Any]]:
    r = run_action("user-show", {"name": name}, who)
    if not bridge_ok(r):
        return bridge_http_status(r), {"ok": False, "error": r.get("message") or "user not found", "code": r.get("code")}
    user = r.get("user") if isinstance(r.get("user"), dict) else {}
    # Живые данные рядом с карточкой — прежний снимок сразу, новый сбор в фоне (READ_SWR_MAX_AGE, PERF-01).
    tr = read_snapshot("traffic", who, swr=READ_SWR_MAX_AGE["traffic"])
    hs = handshakes_by_pubkey(tr) if bridge_ok(tr) else {}
    card = decorate_user(user, hs, _now(), profile_lines())
    # «Ключ на другой адрес сервера»: адрес в ключах этого человека «как обычно» (с учётом
    # закреплённого за ним адреса) — из user-show (поле в корне ответа или в user{}), и
    # варианты разового адреса — из edge-status, тем же кэшем в полминуты, что у Обзора.
    # Всё кладётся в user{}: карточку браузер перерисовывает из него одного. Сбой edge-status
    # карточку не ломает — вариантов просто нет, и вход «другой адрес» не рисуется.
    card["key_host"] = safe_key_host(r.get("key_host") or user.get("key_host"))
    card["key_host_gone"] = bool(r.get("key_host_gone") is True or user.get("key_host_gone") is True)
    try:
        edge = run_action("edge-status", {}, who, swr=READ_SWR_MAX_AGE["edge-status"])
    except ActionError:
        edge = {}
    card["key_choices"] = key_choices_payload(edge)
    card["keys_host"] = safe_key_host(edge.get("keys_host")) if bridge_ok(edge) else ""
    # Возраст живых данных карточки (рукопожатия, адреса сервера): snapshot_at, а у прежнего снимка — swr или stale.
    return 200, {"ok": True, "data": {"user": card, **snapshot_meta("traffic", "edge-status")}}


PROFILE_ID_RE = re.compile(r"awg[123]")
CIDR_RE = re.compile(r"[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}")


def subnet_overlaps_payload(raw: Any) -> List[Dict[str, Any]]:
    """Пересечения подсетей профилей (SUBNET-01) из profiles-status — белым списком: профиль, подсеть, с кем, fixed
    (подсеть этому профилю не сменить — старый контейнер приложения на wg0) и выход move {profile, subnet, keyless}:
    какой профиль перенести и на какую свободную подсеть, сколько его людей с ключами из приложения."""
    out: List[Dict[str, Any]] = []
    for e in raw if isinstance(raw, list) else []:
        if not isinstance(e, dict) or not PROFILE_ID_RE.fullmatch(str(e.get("profile") or "")):
            continue
        mv = e.get("move") if isinstance(e.get("move"), dict) else {}
        move = None
        if PROFILE_ID_RE.fullmatch(str(mv.get("profile") or "")) and CIDR_RE.fullmatch(str(mv.get("subnet") or "")):
            k = mv.get("keyless")
            move = {"profile": str(mv["profile"]), "subnet": str(mv["subnet"]),
                    "keyless": k if isinstance(k, int) and not isinstance(k, bool) and k >= 0 else 0}
        sub = str(e.get("subnet") or "")
        out.append({"profile": str(e["profile"]), "subnet": sub if CIDR_RE.fullmatch(sub) else "",
                    "with": [str(w) for w in (e.get("with") if isinstance(e.get("with"), list) else [])
                             if isinstance(w, str) and PROFILE_ID_RE.fullmatch(w)],
                    "fixed": e.get("fixed") is True, "move": move})
    return out


def profiles_payload(who: str) -> Dict[str, Any]:
    r = read_snapshot("profiles-status", who)
    pub = public_config(read_config())
    available = param_enum("profile") or ["awg2", "awg3", "awg1"]
    installed: List[Dict[str, Any]] = []
    seen: set = set()
    for p in (r.get("profiles") or []) if bridge_ok(r) else []:
        if not isinstance(p, dict) or not p.get("profile"):
            continue
        pid = str(p["profile"])
        seen.add(pid)
        merged = dict(pub["profiles"].get(pid, {}))
        merged.update({k: p.get(k) for k in ("profile", "container", "state", "port", "line", "peers",
                                             "image_tag", "image_digest", "core_version", "enabled") if k in p})
        # Подсеть не сменить (подхваченный старый контейнер на wg0, SUBNET-01): окно подсети говорит это сразу.
        merged["subnet_fixed"] = p.get("subnet_fixed") is True
        # Пакет данных не влезает в мобильные сети из-за большого S4 (S4-FIX): предупреждение и «Исправить S4».
        merged["packet_risk"] = packet_risk_payload(p.get("packet_risk"))
        # Движок AmneziaWG (KMOD_PLAN Б10): engine — фактический (живым опросом контейнера), engine_want — выбранный
        # (пусто — не выбирал). Строка «Движок» на карточке; у ядра старше 1.0.13 полей нет — пусто.
        merged["engine"] = _word(p.get("engine"), KMOD_ENGINES) or ""
        merged["engine_want"] = _word(p.get("engine_want"), KMOD_WANTS) or ""
        # Ту же линию держит ещё профиль (подпись с портом), подхвачен у приложения Amnezia (DUP-LINE-01).
        merged.update(profile_lines_fields(p))
        merged["installed"] = True
        installed.append(merged)
    # Профиль есть в config.json, но контейнер не отвечает — всё равно показываем карточку.
    for pid, cfgp in pub["profiles"].items():
        if pid not in seen:
            merged = dict(cfgp)
            merged.update({"state": "missing", "peers": 0, "installed": True})
            installed.append(merged)
            seen.add(pid)
    udp443 = next((p["profile"] for p in installed if str(p.get("port")) == "443"), "")
    # Линии на сервере (DUP-LINE-01): profiles-status их не несёт — краткий status (только config.json, тот же снимок,
    # что у Обзора). Не ответил — пустая картина: карточки рисуются, предупреждения о линиях нет.
    lst = r if "lines_check" in r else read_snapshot("status", who, status_brief_params(), swr=READ_SWR_MAX_AGE["status"])
    lines_ok = bridge_ok(lst)
    return {
        "installed": installed,
        "available": [pid for pid in available],
        "not_installed": [pid for pid in available if pid not in seen],
        "udp443": udp443,
        "mode": pub["mode"],
        "presets": param_enum("preset") or ["default", "quic", "router"],
        # Пересечения подсетей и выход из них (SUBNET-01): карточки и окно подсети.
        "subnet_overlaps": subnet_overlaps_payload(r.get("subnet_overlaps")) if bridge_ok(r) else [],
        # Нет 2.0, «Переставить на 2.0» и линия свободного места по «Установить» (DUP-LINE-01).
        "lines_check": lines_check_payload(lst.get("lines_check") if lines_ok else None),
        "free_lines": free_lines_payload(lst.get("free_lines") if lines_ok else None),
        "error": None if bridge_ok(r) else {"code": r.get("code"), "message": r.get("message")},
        **snapshot_meta("profiles-status"),
    }


def param_keys_for_line(line: str) -> List[str]:
    """Ключи БАЗОВОЙ линейки профиля — как ga_amn_param_keys в lib/amnezia.sh."""
    keys = ["Jc", "Jmin", "Jmax", "S1", "S2"]
    if line in {"2.0", "3.1"}:
        keys += ["S3", "S4"]
    keys += ["H1", "H2", "H3", "H4"]
    if line in {"1.5", "2.0", "3.1"}:
        keys += ["I1", "I2", "I3", "I4", "I5"]
    if line == "3.1":
        keys += ["HeaderProtectionKey", "ContentPaddingAddition", "RekeyAfterTime", "RekeyTimeout",
                 "RejectAfterTime", "KeepaliveTimeout", "MaxHandshakeAttempts", "RandomTrailers", "DisableCookies"]
    keys += ["PersistentKeepalive", "MTU"]
    allowed = set(param_enum("param_key"))
    return [k for k in keys if not allowed or k in allowed]


def profile_params_payload(who: str, profile: str) -> Tuple[int, Dict[str, Any]]:
    r = run_action("profile-params", {"profile": profile}, who)
    if not bridge_ok(r):
        return bridge_http_status(r), {"ok": False, "error": r.get("message") or "params failed", "code": r.get("code")}
    params = r.get("params") if isinstance(r.get("params"), dict) else {}
    pub = public_config(read_config())
    cfgp = pub["profiles"].get(profile, {})
    line = str(cfgp.get("line") or "")
    base = LINE_FAMILY.get(line) or LINE_BASE_BY_PROFILE.get(profile, line)
    items = [{"key": k, "value": str(params.get(k) if params.get(k) is not None else ""),
              "scope": "server" if k in SERVER_SIDE_PARAMS else "client"} for k in param_keys_for_line(base)]
    return 200, {"ok": True, "data": {
        "profile": profile, "line": line or base, "base_line": base,
        "params": items, "subnet": cfgp.get("subnet", ""), "mtu": cfgp.get("mtu", ""),
        "preset": cfgp.get("preset", ""), "server_params": sorted(SERVER_SIDE_PARAMS),
    }}


def _stat_int(value: Any) -> int:
    """Счётчик из stats.json: неотрицательное целое; мусор и отрицательное — 0."""
    try:
        n = int(value)
    except (TypeError, ValueError):
        return 0
    return n if n > 0 else 0


def traffic_days(r: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Суточный учёт ответа traffic (до 31 суток) белым списком: дата и байты."""
    raw_days = r.get("days") if isinstance(r.get("days"), list) else []
    return [{"date": d["date"], "rx": _stat_int(d.get("rx")), "tx": _stat_int(d.get("tx"))}
            for d in raw_days if isinstance(d, dict) and isinstance(d.get("date"), str)
            and re.fullmatch(r"\d{4}-\d{2}-\d{2}", d["date"])][-31:]


def traffic_kpi_payload(r: Dict[str, Any], total: Dict[str, int], at: Optional[float]) -> Dict[str, Any]:
    """Плитка «Трафик» Обзора — правилом страницы (app.js trafficKpi): сумма суточного учёта за 30 суток; его нет —
    месяц; нет и месяца — всё, что накопили счётчики людей (total). Из того же снимка, что и /api/traffic: подпись и
    число первого кадра не меняются, когда следом приходит учёт (PNL-07: «за всё время» через 0,35 с становилось
    «за 30 дней»). days — последние 14 суток для столбиков плитки; at — время снимка (подсказка «Данные на …»)."""
    stamp = _iso_ts(at) if at is not None else ""
    days = traffic_days(r)
    if days:
        last = days[-30:]
        return {"period": "30d", "rx": sum(d["rx"] for d in last), "tx": sum(d["tx"] for d in last),
                "days": last[-14:], "at": stamp}
    month = r.get("month") if isinstance(r.get("month"), dict) else {}
    mrx, mtx = _stat_int(month.get("rx")), _stat_int(month.get("tx"))
    if mrx or mtx:
        return {"period": "month", "rx": mrx, "tx": mtx, "days": [], "at": stamp}
    return {"period": "all", "rx": int(total.get("rx") or 0), "tx": int(total.get("tx") or 0), "days": [], "at": stamp}


def traffic_payload(who: str, wait: bool = True) -> Dict[str, Any]:
    """«Трафик» ждёт свежий сбор (это суть экрана). wait=False — для Обзора (/api/traffic?wait=0, PERF-03): снимок не
    старше TRAFFIC_TOTALS_MAX_AGE (учёт — сутки, месяц, часы, PERF-05) или сразу pending, а сбор — в фоне. Рукопожатия
    в снимке старше READ_SWR_MAX_AGE["traffic"] — не «на связи»: online и у людей online — None (CR-2)."""
    if wait:
        r = read_snapshot("traffic", who)
    else:
        r = read_snapshot("traffic", who, swr=TRAFFIC_TOTALS_MAX_AGE, wait=False)
    if not bridge_ok(r):
        if str(r.get("code") or "") == "pending":
            return {"profiles": [], "users": [], "pending": True, "error": None}
        return {"profiles": [], "users": [], "error": {"code": r.get("code"), "message": r.get("message")}}
    age = read_age("traffic")
    handshakes_old = not wait and (age is None or age > READ_SWR_MAX_AGE["traffic"])
    hs = handshakes_by_pubkey(r)
    now = _now()
    lines = profile_lines()
    users = [decorate_user(u, hs, now, lines) for u in (r.get("users") or []) if isinstance(u, dict) and u.get("name")]
    users.sort(key=lambda u: (-int(u.get("last_handshake") or 0), str(u.get("name")).lower()))
    if handshakes_old:
        for u in users:
            u["online"] = None
            for peer in (u.get("peers") or {}).values():
                if isinstance(peer, dict):
                    peer["online"] = None
    # Учёт за месяц и сегодня (lib/stats.sh, таймер goamnezia-stats) — у ядра с модулем статистики; без него null.
    month = r.get("month") if isinstance(r.get("month"), dict) else {}
    today = r.get("today") if isinstance(r.get("today"), dict) else {}
    month_by = month.get("by_profile") if isinstance(month.get("by_profile"), dict) else None
    today_by = today.get("by_profile") if isinstance(today.get("by_profile"), dict) else {}
    profiles = []
    for prof in (r.get("profiles") or []):
        if not isinstance(prof, dict):
            continue
        peers = [p for p in (prof.get("peers") or []) if isinstance(p, dict)]
        rx = tx = 0
        online = 0
        for p in peers:
            try:
                rx += int(p.get("rx") or 0)
                tx += int(p.get("tx") or 0)
                ts = int(p.get("latest_handshake_ts") or 0)
            except (TypeError, ValueError):
                ts = 0
            if ts and now - ts < ONLINE_WINDOW:
                online += 1
        pid = str(prof.get("profile") or "")
        item = {"profile": pid, "peers": len(peers), "online": None if handshakes_old else online, "rx": rx, "tx": tx,
                "period": "live"}
        if month_by is not None:
            # Живые счётчики интерфейса обнуляются при перезапуске контейнера и спорили с таблицей
            # пользователей, где трафик копится между перезапусками; месяц и сегодня — тот же учёт, что у неё.
            m = month_by.get(pid) if isinstance(month_by.get(pid), dict) else {}
            d = today_by.get(pid) if isinstance(today_by.get(pid), dict) else {}
            item.update({"period": "month", "rx": _stat_int(m.get("rx")), "tx": _stat_int(m.get("tx")),
                         "today_rx": _stat_int(d.get("rx")), "today_tx": _stat_int(d.get("tx"))})
        profiles.append(item)
    # Почасовой учёт нужен карте 7×24. Раньше этот слой молча отбрасывал hours,
    # даже когда ядро уже собрало историю. Старое ядро означает пустую историю.
    raw_hours = r.get("hours") if isinstance(r.get("hours"), list) else []
    hours = [{"hour": h["hour"], "rx": _stat_int(h.get("rx")),
              "tx": _stat_int(h.get("tx")), "active": _stat_int(h.get("active"))}
             for h in raw_hours if isinstance(h, dict) and isinstance(h.get("hour"), str)
             and re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:00Z", h["hour"])]
    # Суточный учёт (до 30 суток) и итоги месяца и сегодняшнего дня с разбивкой по людям — для «Трафика за
    # 30 дней» на Обзоре и периодов 7 и 30 дней на «Трафике». Тоже белым списком: даты, байты, имена людей.
    days = traffic_days(r)

    def bucket(src: Dict[str, Any], date_key: str) -> Optional[Dict[str, Any]]:
        if not src:
            return None
        by_user = src.get("by_user") if isinstance(src.get("by_user"), dict) else {}
        people = {n: {"rx": _stat_int(v.get("rx")), "tx": _stat_int(v.get("tx"))}
                  for n, v in list(by_user.items())[:1000] if isinstance(n, str) and NAME_RE.match(n) and isinstance(v, dict)}
        date = str(src.get(date_key) or "")
        return {date_key: date if re.fullmatch(r"\d{4}-\d{2}-\d{2}", date) else "",
                "rx": _stat_int(src.get("rx")), "tx": _stat_int(src.get("tx")), "by_user": people}
    return {"profiles": profiles, "users": users, "online": None if handshakes_old else sum(1 for u in users if u["online"]),
            "hours": hours, "days": days, "month": bucket(month, "from"), "today": bucket(today, "date"),
            "online_window": ONLINE_WINDOW, "generated_at": utc_now(), **snapshot_meta("traffic")}


def backups_payload(who: str) -> Dict[str, Any]:
    r = run_action("backup-list", {}, who)
    if not bridge_ok(r):
        return {"backups": [], "error": {"code": r.get("code"), "message": r.get("message")}}
    file_re = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
    items = []
    for b in (r.get("backups") or []):
        if not isinstance(b, dict):
            continue
        name = str(b.get("name") or "")
        # Имя вне маски восстановить нельзя (pattern file в actions.json) — не рисуем кнопку.
        items.append({"name": name, "size": b.get("size") or 0, "created": str(b.get("created") or ""),
                      "restorable": bool(file_re.match(name)) and ".." not in name})
    return {"backups": items}


def logs_payload(who: str, component: str, lines: str) -> Tuple[int, Dict[str, Any]]:
    try:
        r = run_action("logs-tail", {"component": component, "lines": lines}, who, use_cache=False)
    except ActionError as exc:
        return exc.status, {"ok": False, "error": str(exc), "code": exc.code}
    if not bridge_ok(r):
        return bridge_http_status(r), {"ok": False, "error": r.get("message") or "logs failed", "code": r.get("code")}
    # tz_offset — смещение часов сервера от UTC в минутах: journalctl пишет местное время машины, а остальная панель —
    # время браузера; экран логов подписывает, по какому поясу время в строках (PNL-COS-03).
    return 200, {"ok": True, "data": {"component": component, "lines": r.get("lines"),
                                      "log": str(r.get("log") or ""), "tz_offset": server_tz_offset()}}


def server_tz_offset() -> int:
    """Смещение часов сервера от UTC сейчас, в минутах (UTC+3 → 180)."""
    return int(time.localtime().tm_gmtoff // 60)


def logs_status_payload(who: str) -> Dict[str, Any]:
    """Состояние логов рядом с самими логами: сколько занято и каков бюджет.

    Ответ моста — `areas[]{area, used_mb, budget_mb, percent}`; две последние
    строки модуля (`docker`, `free`) приходят тем же списком, поэтому разбирать
    их отдельно панели не нужно.

    Имена участков (journal, nginx, goamnezia, docker, free) — НЕ имена
    компонентов из `logs-tail`: там источники строк, здесь места на диске.
    Пока и то, и другое звалось `components`, из пяти имён этой таблицы в
    выпадающий список логов годилось одно (DEFECTS §3.9).
    """
    if action_spec("logs-status") is None:
        return {"available": False, "areas": [], "free_mb": None}
    r = run_action("logs-status", {}, who)
    if not bridge_ok(r):
        return {"available": r.get("code") != "not_implemented", "areas": [], "free_mb": None,
                "error": {"code": r.get("code"), "message": r.get("message")}}
    items = [c for c in (r.get("areas") or []) if isinstance(c, dict)]
    return {"available": True, "areas": items, "free_mb": r.get("free_mb"), "error": None}


def preflight_payload(who: str) -> Dict[str, Any]:
    """Предполётная проверка портов для страницы «Настройки».

    Без кэша и только по кнопке: проверка зовёт `ss` и `docker ps`, а результат
    меняется ровно тогда, когда кто-то поднял или погасил чужую службу, — то
    есть не сам по себе. Ответ моста отдаём как есть (`modes`), панель рисует
    по `reasons[].message` и `warnings[].message` — тем же строкам, что видит
    человек в SSH-меню.
    """
    if action_spec("preflight") is None:
        return {"available": False, "modes": None}
    r = run_action("preflight", {}, who, use_cache=False)
    if not bridge_ok(r):
        return {"available": r.get("code") != "not_implemented", "modes": None,
                "error": {"code": r.get("code"), "message": r.get("message")}}
    modes = r.get("modes") if isinstance(r.get("modes"), dict) else {}
    return {"available": True, "modes": modes,
            "lite_site_available": bool(r.get("lite_site_available")),
            "pro_available": bool(r.get("pro_available")),
            "hint": str(r.get("hint") or ""), "error": None}


# Поля раздачи, которые панель показывает в списке. Белый список, а не
# «всё, кроме секретов»: `share-list` секретной части адреса не отдаёт, но
# случись ей там появиться (`url`, `path`), список ссылок стал бы местом, где
# секрет виден любому, кто открыл страницу, — включая соседнюю вкладку в
# истории. Адрес живёт ровно в одном месте: в ответе `share-create`.
SHARE_LIST_FIELDS = ("id", "name", "profile", "format", "file_name", "port", "host", "via",
                     "size", "created", "expires", "ttl", "max_downloads", "cert",
                     "downloads", "seconds_left",
                     # Разовый адрес сервера в файле раздачи (пусто — как обычно); не секрет.
                     "endpoint")


def share_payload(who: str) -> Dict[str, Any]:
    """Блок «Временные ссылки»: активные раздачи файлов (docs/SHARE.md §3)."""
    if action_spec("share-list") is None:
        return {"available": False, "shares": [], "count": 0}
    r = read_snapshot("share-list", who)
    if not bridge_ok(r):
        return {"available": r.get("code") != "not_implemented", "shares": [], "count": 0,
                "error": {"code": r.get("code"), "message": r.get("message")}}
    meta = snapshot_meta("share-list")
    # Снимок служит до 30 с, а ссылка живёт по часам: остаток — от времени сбора до сейчас; истёкшую не показываем
    # (сама раздача к этому времени уже закрыта, а следующий сбор её и не вернёт).
    reads = getattr(_CALL_CTX, "reads", None) or {}
    age = max(0, int(_now() - reads["share-list"]["at"])) if "share-list" in reads else 0
    shares = []
    for s in (r.get("shares") or []):
        if not isinstance(s, dict):
            continue
        item = {k: s.get(k) for k in SHARE_LIST_FIELDS if k in s}
        left = item.get("seconds_left")
        if age and isinstance(left, int) and not isinstance(left, bool) and left > 0:
            item["seconds_left"] = max(0, left - age)
            if not item["seconds_left"]:
                continue
        shares.append(item)
    return {"available": True, "shares": shares, "count": len(shares), "error": None, **meta}


# ── Страница подключения и зеркало сборок (docs/CLIENTS.md §9–§10) ──────────
# Список страниц — белым списком, как раздачи: адрес с секретом живёт только в
# ответах page-create и page-url, и то по явному нажатию. Каталог приложений
# наружу уходит в объёме «что можно скачать на сервер», а не целиком.
# subscription — кто завёл подписку пользователя для этой страницы (created | exists | off, docs/SUBSCRIPTION.md):
# по нему панель ставит галочку «Перевыпустить и подписку» (B2-2/A2-4); чужое значение уходит как null.
PAGE_LIST_FIELDS = ("id", "user", "created", "expires", "forever", "visits", "last_visit", "profiles", "mirror",
                    "subscription")
PAGE_SUB_STATES = ("created", "exists", "off")
MIRROR_ITEM_FIELDS = ("app", "platform", "state", "version", "file", "size", "bytes", "sha256", "fetched", "error",
                      "message", "updated", "busy", "published", "source_url")
MIRROR_PLATFORMS = ("ios", "android", "android_tv", "windows", "macos", "linux", "router")
# Ответы с адресом страницы: к ним панель дорисовывает QR (attach_page_qr).
PAGE_URL_ACTIONS = ("page-create", "page-url")
# Карточка доступа агента с адресом (0.5.0, «QR адреса — для клиента на телефоне»): у переходника адреса нет.
AGENT_CARD_ACTIONS = ("agent-add", "agent-show", "agent-rotate", "agent-harden")
# Ответы с адресами подписки (docs/SUBSCRIPTION.md): QR главного — профиля mihomo, его сканируют FlClash и Clash Meta.
# Поле clients (выбор по клиенту) идёт в панель целиком, как urls: тот же секрет, ответ не кешируется (use_cache=False)
# и в журнал не пишется; к пунктам с qr "url" и "deeplink" панель дорисовывает qr_png_b64 (attach_sub_clients_qr).
SUB_URL_ACTIONS = ("sub-create", "sub-show", "sub-rotate")
# Ссылка «в приложение» — своя схема приложения (flclash://, incy://, wg://); javascript:, data: и прочие — не рисуем.
SUB_DEEPLINK_RE = re.compile(r"^(?!(?:javascript|data|vbscript|file|about|blob):)[a-z][a-z0-9+.-]{1,31}://\S+\Z", re.IGNORECASE)
# Короткие ссылки с 2FA через бота (договор ядра и интерфейсов — docs/SUBSCRIPTION.md): ответы short-* несут код — секрет
# того же порядка, что адрес подписки. Идут только общим маршрутом /api/action/<имя>: без общего снимка (use_cache=False,
# в READ_CACHE_TTL их нет), с Cache-Control: no-store, в журнал панели — никогда; в аудит — имя, суффикс, id запроса,
# а цель снятия бана — только если это адрес (код вместо себя — «***»).
SHORT_ACTIONS = ("short-ensure", "short-list", "short-replace-request", "short-decide", "short-status", "short-pending",
                 "short-bans", "short-unban")
# Кто попросил замену и кто решил запрос — панель: значение ставит сервер, не страница (договор: page | panel | ssh | bot).
SHORT_WHO_ACTIONS = ("short-replace-request", "short-decide")
# Итог запроса — полем status (договор): ok | wrong | denied | swapped | expired | frozen, pending — ещё ждёт.
SHORT_OUTCOMES = ("ok", "wrong", "denied", "swapped", "expired", "frozen", "pending", "waiting")


def short_params(name: str, params: Dict[str, Any]) -> Dict[str, Any]:
    """who у запроса замены и решения — всегда «panel», если ядро объявило параметр (иначе он «лишний»)."""
    if name in SHORT_WHO_ACTIONS:
        params = {k: v for k, v in params.items() if k != "who"}
        if "who" in ((action_spec(name) or {}).get("params") or {}):
            params["who"] = "panel"
    return params


def short_outcome_answer(name: str, r: Dict[str, Any]) -> bool:
    """Ответ short-decide / short-status с итогом в status (форма договора) — это ответ, а не отказ моста."""
    return name in ("short-decide", "short-status") and isinstance(r, dict) and r.get("status") in SHORT_OUTCOMES


# ── «Ждут подтверждения» без моста (PERF-02) ────────────────────────────────────
# Вкладка «Короткие ссылки» перечитывает ждущие запросы, пока открыта; мост (bash, jq и тот же python) стоил около 1,1 с
# процессора на вызов на 1 vCPU (живая проверка на 168). Читаем в этом же процессе модулем ядра lib/shortlinks.py — тем,
# что зовёт и мост: под его замком (flock subs/.short/.lock между процессами и свой RLock между потоками панели), тем же
# ShortLinks.pending() — просроченный запрос он закрывает так же, как мост (событие short_decided — боту, строка effect —
# в аудит). Наружу — только поля договора (SHORT_PENDING_FIELDS): ни кода ссылки, ни верного числа, ни ключа адреса.
# Модуля нет, он другой, замок не взят или сбой — по-прежнему мостом.
SHORT_LINKS_PY = Path(os.getenv("GOAMNEZIA_SHORTLINKS_PY", str(GOAMNEZIA_DIR / "lib" / "shortlinks.py")))
SHORT_PENDING_FIELDS = ("request", "kind", "name", "label", "suffix", "device", "ip", "geo", "options", "who", "created",
                        "expires", "left")
_SHORT_LINKS_LOCK = threading.Lock()
_SHORT_LINKS: Dict[str, Any] = {"stamp": None, "links": None}


def _short_effect_audit(action: str, details: Any) -> None:
    """Строка «effect» (CONTRACT §7.1), когда модуль ядра в процессе панели сам что-то изменил (закрыл просроченный
    запрос): тот же вид, что у моста (_cli_audit), кто — панель."""
    try:
        AUDIT_LOG.parent.mkdir(parents=True, exist_ok=True)
        line = json.dumps({"ts": utc_now(), "iface": "panel", "stage": "effect", "who": "panel", "action": str(action),
                           "details": str(details).replace("\n", " ")}, ensure_ascii=False)
        fd = os.open(str(AUDIT_LOG), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def short_links_local() -> Any:
    """ShortLinks модуля ядра в этом процессе (перезагружается, когда файл модуля сменился — обновление) или None."""
    try:
        st = SHORT_LINKS_PY.stat()
    except OSError:
        return None
    # Каталоги модуль берёт при создании (GOAMNEZIA_DIR и переменные окружения) — они тоже часть отпечатка.
    stamp = (st.st_mtime_ns, st.st_size, st.st_ino, str(SHORT_LINKS_PY), str(GOAMNEZIA_DIR),
             *(os.environ.get(k, "") for k in ("GOAMNEZIA_SUBS_DIR", "GOAMNEZIA_LOCK_DIR", "GOAMNEZIA_SHORT_CONFIRM_DIR")))
    with _SHORT_LINKS_LOCK:
        if _SHORT_LINKS["stamp"] == stamp:
            return _SHORT_LINKS["links"]
        links = None
        try:
            spec = importlib.util.spec_from_file_location("ga_shortlinks", str(SHORT_LINKS_PY))
            if spec is not None and spec.loader is not None:
                mod = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(mod)
                links = mod.ShortLinks(gdir=str(GOAMNEZIA_DIR), audit=_short_effect_audit)
                if not callable(getattr(links, "pending", None)):
                    links = None
        except Exception as exc:  # noqa: BLE001 — нет модуля в рабочем виде: читаем мостом
            sys.stderr.write(f"[admin] short links module not loaded: {exc.__class__.__name__}\n")
            links = None
        _SHORT_LINKS.update(stamp=stamp, links=links)
        return links


def short_pending_local() -> Optional[Dict[str, Any]]:
    """short-pending без моста — ответ той же формы, что у моста ({status: success, requests: […]}), или None."""
    links = short_links_local()
    if links is None:
        return None
    try:
        reqs = links.pending()
    except Exception as exc:  # noqa: BLE001 — замок не взят (ShortBusy), файл не прочитан: мост ответит своими словами
        sys.stderr.write(f"[admin] short-pending in-process failed: {exc.__class__.__name__}\n")
        return None
    if not isinstance(reqs, list):
        return None
    out = [{k: q[k] for k in SHORT_PENDING_FIELDS if k in q} for q in reqs if isinstance(q, dict)]
    return {"status": "success", "message": "ok", "requests": out}


# Параметры-ключи профиля: значение — не для журнала (KEENETIC-I1-N, N3). Тот же список — GA_AMN_SECRET_PARAMS в
# lib/amnezia.sh, SECRET_PARAMS в app.js и боте, SECRET_PROFILE_PARAMS в goamnezia-mcp/server.py. Сравнение без учёта
# регистра: в журнал попадает и вызов, который ядро отвергнет.
SECRET_PROFILE_PARAMS = frozenset({"headerprotectionkey"})


def audit_params(name: str, params: Dict[str, Any]) -> Dict[str, Any]:
    """Параметры для аудита: код короткой ссылки (цель снятия заморозки) — «***», адрес — как есть; нажатое
    администратором число у short-decide — «***» (SL-AUD-01: ответ на чужой запрос — не для журнала), deny и swap —
    как есть; значение параметра-ключа у profile-set-param (HeaderProtectionKey) — «***»."""
    if name == "profile-set-param" and str(params.get("key") or "").strip().lower() in SECRET_PROFILE_PARAMS \
            and str(params.get("value") or "") != "":
        return {**params, "value": "***"}
    if name == "short-decide" and re.fullmatch(r"[0-9]+", str(params.get("answer") or "")):
        return {**params, "answer": "***"}
    if name != "short-unban" or "target" not in params:
        return params
    target = str(params.get("target") or "")
    try:
        ipaddress.ip_network(target, strict=False)
        return params
    except ValueError:
        return {**params, "target": "***"}


# Слово отказа моста — латиница, цифры и подчёркивание (short_need_bot, sub_not_found, lock_timeout).
AUDIT_CODE_RE = re.compile(r"[a-z][a-z0-9_]{0,63}")


def audit_code(name: str, data: Any) -> str:
    """Поле code строки аудита. У действий с секретом в ответе (secret: true в каталоге — short-*, sub-*, выдача
    ключа) — только слово отказа моста, а у удачного ответа — ничего, кроме итога решения короткой ссылки (decision):
    поле code удачного short-ensure и short-list — это сам короткий код (SL-LOG-01). У остальных — как прежде."""
    if not isinstance(data, dict):
        return ""
    code = str(data.get("code") or "")
    if not (action_spec(name) or {}).get("secret"):
        return code
    if bridge_ok(data):
        decision = str(data.get("decision") or "")
        return decision if name in ("short-decide", "short-status") and decision in SHORT_OUTCOMES else ""
    if AUDIT_CODE_RE.fullmatch(code):
        return code
    return "error" if code else ""


def pages_payload(who: str, name: str = "") -> Dict[str, Any]:
    """Страницы подключения (одного пользователя или все) без адресов."""
    if action_spec("page-list") is None:
        return {"available": False, "pages": [], "count": 0, "error": None}
    params = {"name": name} if name else {}
    r = run_action("page-list", params, who, use_cache=False)
    if not bridge_ok(r):
        return {"available": r.get("code") != "not_implemented", "pages": [], "count": 0,
                "error": {"code": r.get("code"), "message": r.get("message")}}
    pages = [{k: p.get(k) for k in PAGE_LIST_FIELDS if k in p}
             for p in (r.get("pages") or []) if isinstance(p, dict)]
    for p in pages:
        if "subscription" in p and p["subscription"] not in PAGE_SUB_STATES:
            p["subscription"] = None
    return {"available": True, "pages": pages, "count": len(pages), "error": None}


def mirror_payload(who: str) -> Dict[str, Any]:
    """Копии сборок на сервере: состояние, версия, размер, занято из предела."""
    if action_spec("mirror-list") is None:
        return {"available": False, "items": [], "max_total_mb": 0, "used_mb": 0, "error": None}
    r = run_action("mirror-list", {}, who, use_cache=False)
    if not bridge_ok(r):
        return {"available": r.get("code") != "not_implemented", "items": [], "max_total_mb": 0, "used_mb": 0,
                "error": {"code": r.get("code"), "message": r.get("message")}}
    items = [{k: i.get(k) for k in MIRROR_ITEM_FIELDS if k in i}
             for i in (r.get("items") or []) if isinstance(i, dict)]
    return {"available": True, "items": items, "max_total_mb": r.get("max_total_mb") or 0,
            "used_mb": r.get("used_mb") or 0, "error": None}


def clients_payload(who: str) -> Dict[str, Any]:
    """Каталог приложений для кнопки «Скачать на сервер»: id, имя, официальность и
    платформы, которые можно зеркалить (ключи mirror.assets по договору §8)."""
    if action_spec("clients-list") is None:
        return {"available": False, "apps": [], "error": None}
    r = run_action("clients-list", {}, who)
    if not bridge_ok(r):
        return {"available": r.get("code") != "not_implemented", "apps": [],
                "error": {"code": r.get("code"), "message": r.get("message")}}
    apps = []
    for a in r.get("apps") or []:
        if not isinstance(a, dict) or not a.get("id"):
            continue
        mirror = a.get("mirror")
        assets = mirror.get("assets") if isinstance(mirror, dict) else None
        platforms = a.get("platforms") if isinstance(a.get("platforms"), dict) else {}
        apps.append({"id": str(a.get("id")), "name": str(a.get("name") or a.get("id")),
                     "official": bool(a.get("official")),
                     "platforms": [p for p in MIRROR_PLATFORMS if p in platforms],
                     "mirror_platforms": [p for p in MIRROR_PLATFORMS if isinstance(assets, dict) and p in assets]})
    return {"available": True, "checked": r.get("checked"), "apps": apps, "error": None}


def qr_png_b64(text: str) -> str:
    """PNG с QR текста через qrencode, base64; нет qrencode — пустая строка.

    Текст подаётся через stdin, а не аргументом: в argv секретный адрес был бы
    виден в `ps` любому процессу на сервере.
    """
    exe = shutil.which("qrencode")
    if not exe or not text:
        return ""
    try:
        proc = subprocess.run([exe, "-r", "/dev/stdin", "-o", "-", "-t", "PNG", "-m", "2", "-s", "6"],
                              input=text.encode("utf-8"), capture_output=True, timeout=20, check=False)
    except (OSError, subprocess.SubprocessError):
        return ""
    if proc.returncode != 0 or not proc.stdout.startswith(b"\x89PNG"):
        return ""
    return base64.b64encode(proc.stdout).decode("ascii")


def attach_page_qr(name: str, r: Dict[str, Any]) -> Dict[str, Any]:
    """К ответу page-create / page-url — QR адреса (qr_png_b64), нарисованный здесь.

    Рисовать на сервере, а не просить отдельным запросом: секретный адрес тогда
    не уезжает второй раз по сети и не попадает в строку запроса и журналы.
    """
    if name in PAGE_URL_ACTIONS and bridge_ok(r) and r.get("url"):
        r["qr_png_b64"] = qr_png_b64(str(r.get("url")))
    elif name in AGENT_CARD_ACTIONS and bridge_ok(r) and r.get("url") and r.get("mode") != "connect":
        r["qr_png_b64"] = qr_png_b64(str(r.get("url")))
    elif name in SUB_URL_ACTIONS and bridge_ok(r):
        main = next((str(u.get("url") or "") for u in (r.get("urls") or [])
                     if isinstance(u, dict) and u.get("format") == "mihomo"), "")
        if main.startswith("https://"):
            r["qr_png_b64"] = qr_png_b64(main)
        attach_sub_clients_qr(r)
    return r


def attach_sub_clients_qr(r: Dict[str, Any]) -> None:
    """Выбор по клиенту (поле clients ответов sub-*): к пункту с qr "url" — QR его адреса (только https), с qr
    "deeplink" — QR ссылки «в приложение» (её читает камера телефона), в qr_png_b64; с qr_alt "url" — второй код, QR
    адреса, в qr_alt_png_b64 (incy: камерой телефона и сканером в приложении). qr "key" панель рисует сама, путём
    карточки (/api/users/<имя>/key). Один текст у нескольких пунктов (all.yaml у FlClash и Clash Meta) — один qrencode."""
    clients = r.get("clients")
    if not isinstance(clients, list):
        return
    made: Dict[str, str] = {}

    def draw(text: str) -> str:
        if text not in made:
            made[text] = qr_png_b64(text)
        return made[text]

    for c in clients:
        items = c.get("items") if isinstance(c, dict) else None
        for it in items if isinstance(items, list) else []:
            if not isinstance(it, dict):
                continue
            url = str(it.get("url") or "")
            kind = it.get("qr")
            text = url if kind == "url" else (str(it.get("deeplink") or "") if kind == "deeplink" else "")
            if (text.startswith("https://") if kind == "url" else SUB_DEEPLINK_RE.match(text)) and draw(text):
                it["qr_png_b64"] = made[text]
            if it.get("qr_alt") == "url" and url.startswith("https://") and draw(url):
                it["qr_alt_png_b64"] = made[url]


def settings_payload(who: str) -> Dict[str, Any]:
    cfg = read_config()
    pub = public_config(cfg)
    rec = password_record()
    panel = cfg.get("panel") if isinstance(cfg.get("panel"), dict) else {}
    # Адрес в команде туннеля «О программе» — тот же, что на Обзоре (tunnel_host); edge-status
    # идёт тем же кэшем в полминуты. Сбой сторожа адресов «Настройки» не роняет.
    # Оба чтения — подсказки рядом с настройками, а «Настройки» панель спрашивает при каждом входе: они их не ждут
    # (PERF-03). Снимок не старше READ_SWR_MAX_AGE — из него, иначе сбор в фоне (тот же, что у Обзора), а в ответе
    # pending: команда туннеля до тех пор — с адресом сервера, признаков L-01 и L-06 ещё нет.
    pending: List[str] = []
    try:
        edge = run_action("edge-status", {}, who, swr=READ_SWR_MAX_AGE["edge-status"], wait=False)
    except ActionError:
        edge = {}
    # «Адрес сервера в ключах» в «Настройках» знает, что вписанного IP на машине больше нет (L-01): тот же признак,
    # что на Обзоре, из status (кэш на секунды). Сбой моста «Настройки» не роняет — тогда признака просто нет.
    try:
        st = run_action("status", status_brief_params(), who, swr=READ_SWR_MAX_AGE["status"], wait=False)
    except ActionError:
        st = {}
    for name, r in (("edge-status", edge), ("status", st)):
        if str(r.get("code") or "") == "pending":
            pending.append(name)
    return {
        "pending": pending,
        "config": pub,
        "endpoint_host_gone": bridge_ok(st) and st.get("endpoint_host_gone") is True,
        "server_ip_change": server_ip_change_payload(st.get("server_ip_change")) if bridge_ok(st) else None,
        "tunnel_host": tunnel_host(edge, str(pub.get("server_ip") or "")),
        # Состояние службы бота — здесь же: строка «Администраторы бота» различает «бот ждёт первого
        # админа» и «бота нет», а Обзор к открытию «Настроек» по прямой ссылке ещё не загружен (PUI-11).
        "bot_state": services_health(str(pub.get("mode") or "")).get("goamnezia-bot", "unknown"),
        "panel_url": public_panel_url(cfg),
        # Запись в конфиге отдельно от адреса: пустой адрес при записанном пути
        # — это не «выключено», а «включать нечего в этом режиме», и экран
        # обязан сказать именно это (DEFECTS §1.8).
        "panel_path_saved": bool(str(panel.get("miniapp_path") or "").strip()),
        "tfa": tfa_available(),
        # Администраторы бота — ТОЛЬКО просмотр, как в SSH-меню. Панель читает тот
        # же .env, из которого берёт кому слать код 2FA, поэтому список у неё уже
        # есть; прежде она про него молчала вовсе, и «кто может управлять ботом»
        # нельзя было узнать ни одним экраном, кроме самого бота. Управляет
        # списком по-прежнему бот (/invite и экран «Администраторы»): .env — его
        # файл, и правило «владелец первый, его не удаляют» живёт там же.
        "bot_admins": bot_admins_view(),
        # Наружу — только логин, срок последней смены и путь к файлу. Ни соли,
        # ни хеша: в браузере им делать нечего даже за сессией.
        "password": {"set": bool(rec), "login": str(rec.get("login") or PASSWORD_LOGIN_DEFAULT),
                     "updated": str(rec.get("updated") or ""), "file": str(PASSWORD_FILE),
                     "min_len": PASSWORD_MIN_LEN,
                     # Команду перевыпуска собирает сервер: он один знает, где
                     # лежит эталон. Фронтенд её только показывает — склейка
                     # пути из чужих полей давала бы бессмыслицу на стендах.
                     "reset_cmd": f"{GOAMNEZIA_DIR}/admin-web/install_admin.sh --reset-password"},
        "trust_tunnel": TRUST_LOCAL_CONSOLE,
        "bind": f"{HOST}:{PORT}",
        "token_file": str(ADMIN_TOKEN_FILE),
        "lock_file": str(CONFIG_LOCK_FILE),
        "action_bin": ACTION_BIN,
        "components": param_enum("component"),
        "session": {"ttl": SESSION_TTL, "grace": SESSION_GRACE},
        "who": who,
    }


def quality_payload(who: str) -> Dict[str, Any]:
    r = run_action("quality", {}, who)
    if not bridge_ok(r):
        return {"quality": None, "error": {"code": r.get("code"), "message": r.get("message")}}
    return {"quality": r.get("quality") if isinstance(r.get("quality"), dict) else {}}


def agents_payload(who: str) -> Dict[str, Any]:
    """Страница «Агенты» (PLAN §6.10): список доступов без секретов и состояние
    HTTP-транспорта (agent-list.transport = mcp-http-status). Ядро без модуля
    (not_implemented) → заглушка «в следующей версии», как раньше.

    Доступ с одноразовым ключом (mode: rolling) приходит сюда с mode, compromised
    и временем с адресом обнаруженного клона, но без отпечатка ключа: список его
    и так не отдаёт, а SECRET_KEYS страхует на случай, если отдаст."""
    if action_spec("agent-list") is None:
        return {"stub": True, "agents": [], "transport": None}
    r = run_action("agent-list", {}, who)
    if not bridge_ok(r):
        return {"stub": r.get("code") == "not_implemented", "agents": [], "transport": None,
                "error": {"code": r.get("code"), "message": r.get("message")}}
    agents = [mask_secrets(a) for a in (r.get("agents") or []) if isinstance(a, dict)]
    transport = r.get("transport") if isinstance(r.get("transport"), dict) else None
    return {"stub": False, "agents": agents, "transport": mask_secrets(transport) if transport else None}


def upstream_payload(who: str) -> Dict[str, Any]:
    """Карточка «Обновления Amnezia» на «Протоколах»: ответ upstream-check как есть.
    Сеть недоступна — мост отвечает unreachable, но с текущими версиями
    профилей: карточка рисует их и предупреждение, а не пустоту. Зовётся по
    кнопке, не автообновлением: это два запроса наружу с таймаутами до 20 с."""
    r = run_action("upstream-check", {}, who, use_cache=False)
    if not bridge_ok(r):
        return {"reachable": r.get("code") != "unreachable", "check": None,
                "profiles": r.get("profiles") if isinstance(r.get("profiles"), list) else [],
                "error": {"code": r.get("code"), "message": r.get("message")}}
    check = {k: v for k, v in r.items() if k not in ("status", "message")}
    return {"reachable": True, "check": mask_secrets(check),
            "profiles": check.get("profiles") if isinstance(check.get("profiles"), list) else [], "error": None}


def import_payload(who: str) -> Dict[str, Any]:
    """Панель «Импорт существующей установки»: import-scan (что нашлось, что
    можно подхватить). Секретов в ответе нет — модуль их не отдаёт."""
    r = run_action("import-scan", {}, who, use_cache=False)
    if not bridge_ok(r):
        return {"containers": [], "adoptable": [], "error": {"code": r.get("code"), "message": r.get("message")}}
    return {"containers": [mask_secrets(c) for c in (r.get("containers") or []) if isinstance(c, dict)],
            "adoptable": r.get("adoptable") if isinstance(r.get("adoptable"), list) else [], "error": None}


# ════════════════════════════════════════════════════════════════════════════
# Ускорение AmneziaWG: модуль ядра по выбору человека (KMOD_PLAN этап Б, CONTRACT §4.4a, §4.7a)
# ════════════════════════════════════════════════════════════════════════════
# Карточка на «Протоколах» (и в мини-аппе): состояние — kmod-status (только чтение, замка не берёт; общий снимок на 5 с
# с признаками файлов хода), проверка хоста и что поставит apt — kmod-check через POST /api/action/kmod-check.
# Изменения — долгие (установка до 15 минут, перевод — до 3 минут ожидания людей на профиль), поэтому панель зовёт их
# в фоне: POST /api/kmod/<действие> сразу отвечает, а мост идёт в потоке панели под общим замком, как остальные
# мутации. Ход — kmod-status.progress (страница опрашивает GET /api/kmod раз в несколько секунд), итог — в job до
# получаса: его видит и вкладка, открытая позже, и мини-апп, который Telegram усыпил посреди действия. Действие
# панели — цепочка шагов моста, как пункт SSH-меню «Обслуживание → Ускорение AmneziaWG»:
#   enable  — kmod-install (согласие — сам вызов), затем kmod-engine --engine=kernel;
#   program — kmod-engine --engine=program;
#   rebuild — kmod-install --rebuild=on, затем kmod-engine --engine=kernel, если выбран модуль, а профили не на нём;
#   remove  — kmod-remove (пакеты сборки удаляет человек командой из ответа).
# Все четыре рвут связь людям на 15–25 с (или ставят пакеты), поэтому confirm = имя действия — после окна согласия;
# kmod-engine и kmod-remove получают от панели свой confirm каталога (движок, имя действия). Сам продукт движок не
# меняет никогда: это делает только нажатие человека.
KMOD_OPS = ("enable", "program", "rebuild", "remove")
# Сколько итог последнего действия виден карточке.
KMOD_JOB_KEEP = 1800.0
_KMOD_JOB_LOCK = threading.Lock()
_KMOD_JOB: Dict[str, Any] = {}
KMOD_NOTE_RE = re.compile(r"^(already|no_clients|lost|not_running(:[a-z_-]{1,32})?)?$")
KMOD_LINE_RE = re.compile(r"^[0-9]\.[0-9x]{1,3}$")
# Команда удаления пакетов из ответа kmod-remove: apt remove и имена пакетов — иначе панель собирает её сама.
KMOD_APT_CMD_RE = re.compile(r"^apt(-get)? remove( [a-z0-9][a-z0-9.+-]{0,127}){1,32}$")


def _kmod_profile(value: Any) -> str:
    return value if isinstance(value, str) and PROFILE_ID_RE.fullmatch(value) else ""


def _kmod_selftest(value: Any) -> Optional[Dict[str, Any]]:
    """Самопроверка модуля (state/kmod.json .selftest): итог, ядро, метка и — у ответа kmod-install — случаи по линиям."""
    if not isinstance(value, dict):
        return None
    out: Dict[str, Any] = {"ok": value.get("ok") is True, "kernel": _kmod_kernel(value.get("kernel")),
                           "label": _kmod_version(value.get("label")), "at": _core_ts(value.get("at")),
                           "reason": _kmod_text(value.get("reason"))}
    cases = []
    for c in (value.get("cases") if isinstance(value.get("cases"), list) else [])[:16]:
        if not isinstance(c, dict) or not _kmod_profile(c.get("profile")):
            continue
        line = c.get("line")
        cases.append({"profile": c["profile"], "line": line if isinstance(line, str) and KMOD_LINE_RE.fullmatch(line) else "",
                      "client": _word(c.get("client"), KMOD_WANTS) or "", "ok": c.get("ok") is True,
                      "detail": _kmod_text(c.get("detail"), 300)})
    if cases:
        out["cases"] = cases
    return out


def kmod_status_payload(value: Any) -> Optional[Dict[str, Any]]:
    """kmod-status.kmod (ga_kmod_status_json) для карточки — белым списком: поля этапа А (kmod_payload), состояние и
    причина словами с ядром, выбор, чей модуль, движок каждого профиля, ход долгого действия, самопроверка, неудача
    последней установки и пакеты, которые ставила goAmnezia. Ядро без этапа Б (нет state) — None: карточки нет."""
    base = kmod_payload(value)
    if base is None or not base["state"]:
        return None
    profiles: Dict[str, Any] = {}
    raw = value.get("profiles") if isinstance(value.get("profiles"), dict) else {}
    for pid, e in list(raw.items())[:8]:
        if _kmod_profile(pid) and isinstance(e, dict):
            profiles[pid] = {"engine": _word(e.get("engine"), KMOD_ENGINES) or "",
                             "want": _word(e.get("want"), KMOD_WANTS) or ""}
    progress = None
    p = value.get("progress")
    if isinstance(p, dict):
        progress = {"action": _word(p.get("action"), KMOD_PROGRESS_ACTIONS) or "", "step": _kmod_code(p.get("step")),
                    "text": _kmod_text(p.get("text")), "at": _core_ts(p.get("at")), "started": _core_ts(p.get("started"))}
    failed = None
    f = value.get("failed")
    if isinstance(f, dict):
        failed = {"kernel": _kmod_kernel(f.get("kernel")), "step": _kmod_code(f.get("step")), "code": _kmod_code(f.get("code")),
                  "reason": _kmod_text(f.get("reason")), "log": _kmod_text(f.get("log"), 300), "at": _core_ts(f.get("at"))}
    selftest = _kmod_selftest(value.get("selftest"))
    if selftest is not None:
        selftest.pop("cases", None)
    base.update({"kernel": _kmod_kernel(value.get("kernel")), "want": _word(value.get("want"), KMOD_WANTS) or "",
                 "installed": value.get("installed") is True, "installed_version": _kmod_version(value.get("installed_version")),
                 "owner": _word(value.get("owner"), KMOD_OWNERS) or "", "label": _kmod_version(value.get("label")),
                 "profiles": profiles, "progress": progress, "selftest": selftest, "failed": failed,
                 "packages": _kmod_packages(value.get("packages"))})
    return base


def kmod_panel_payload(who: str) -> Dict[str, Any]:
    """GET /api/kmod: состояние модуля (kmod-status через общий снимок) и действие панели в фоне (идёт или его итог)."""
    r = run_action("kmod-status", {}, who)
    km = kmod_status_payload(r.get("kmod")) if bridge_ok(r) else None
    err = None if bridge_ok(r) else {"code": r.get("code"), "message": r.get("message")}
    return {"kmod": km, "error": err, "job": kmod_job_payload()}


def kmod_step_payload(name: str, r: Dict[str, Any]) -> Dict[str, Any]:
    """Итог шага моста для экрана — белым списком по действию (CONTRACT §4.7a): у отказа — код и слова ядра и то, что
    успело случиться (перевод с откатом несёт profiles[] и rolled_back в корне)."""
    ok = bridge_ok(r)
    out: Dict[str, Any] = {"action": name, "ok": ok, "code": "" if ok else (_kmod_code(r.get("code")) or "error"),
                           "message": _kmod_text(r.get("message"), 600)}
    if name == "kmod-install":
        out.update({"state": _word(r.get("state"), KMOD_STATES) or "", "version": _kmod_version(r.get("version")),
                    "kernel": _kmod_kernel(r.get("kernel")), "owner": _word(r.get("owner"), KMOD_OWNERS) or "",
                    "reused": r.get("reused") is True, "packages": _kmod_packages(r.get("packages")),
                    "headers_meta_skipped": "".join(_kmod_packages([r.get("headers_meta_skipped")])),
                    "selftest": _kmod_selftest(r.get("selftest")), "want": _word(r.get("want"), KMOD_WANTS) or ""})
    elif name == "kmod-engine":
        rows = []
        for x in (r.get("profiles") if isinstance(r.get("profiles"), list) else [])[:8]:
            if not isinstance(x, dict) or not _kmod_profile(x.get("profile")):
                continue
            note = x.get("note") if isinstance(x.get("note"), str) and KMOD_NOTE_RE.fullmatch(x.get("note")) else ""
            nums = {}
            for k in ("alive_before", "returned", "return_s"):
                v = x.get(k)
                nums[k] = v if isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= 100000 else None
            rows.append({"profile": x["profile"], "from": _word(x.get("from"), KMOD_ENGINES) or "",
                         "to": _word(x.get("to"), KMOD_ENGINES) or "", "restarted": x.get("restarted") is True,
                         "alive_before": nums["alive_before"] or 0, "returned": nums["returned"] or 0,
                         "return_s": nums["return_s"], "note": note})
        out.update({"engine": _word(r.get("engine"), KMOD_WANTS) or "", "want": _word(r.get("want"), KMOD_WANTS) or "",
                    "rolled_back": r.get("rolled_back") is True, "profiles": rows})
    elif name == "kmod-remove":
        pkgs = _kmod_packages(r.get("packages"))
        cmd = r.get("command")
        if not (isinstance(cmd, str) and KMOD_APT_CMD_RE.fullmatch(cmd)):
            cmd = "apt remove " + " ".join(pkgs) if pkgs else ""
        out.update({"removed": r.get("removed") is True, "kept_for_neighbour": r.get("kept_for_neighbour") is True,
                    "packages": pkgs, "command": cmd})
    return out


def kmod_job_payload() -> Optional[Dict[str, Any]]:
    """Действие панели с модулем: идёт (done=false, step — шаг моста) или его итог (steps[]) не старше получаса."""
    with _KMOD_JOB_LOCK:
        job = _KMOD_JOB.get("job")
        if not job:
            return None
        now = _now()
        if job["done"] and now - job["finished"] > KMOD_JOB_KEEP:
            return None
        end = job["finished"] if job["done"] else now
        return {"id": job["id"], "op": job["op"], "done": job["done"], "step": job["step"],
                "elapsed": int(max(0.0, end - job["started"])), "ago": int(max(0.0, now - end)) if job["done"] else 0,
                "steps": [dict(s) for s in job["steps"]]}


def _kmod_step(job: Dict[str, Any], name: str, params: Dict[str, str], confirm: Optional[str] = None) -> Dict[str, Any]:
    with _KMOD_JOB_LOCK:
        job["step"] = name
    try:
        r = run_action(name, params, job["who"], confirm=confirm, use_cache=False)
    except ActionError as exc:
        r = {"status": "error", "code": exc.code, "message": str(exc), "action": name}
    with _KMOD_JOB_LOCK:
        job["steps"].append(kmod_step_payload(name, r))
    return r


def _kmod_job_run(job: Dict[str, Any], headers_meta: str) -> None:
    """Поток действия панели: шаги моста по очереди (каждый — под общим замком панели и ядра), язык — того, кто нажал."""
    _CALL_CTX.lang = job["lang"]
    op = job["op"]
    try:
        if op == "enable":
            r = _kmod_step(job, "kmod-install", {"rebuild": "off", "headers_meta": headers_meta})
            if bridge_ok(r):
                _kmod_step(job, "kmod-engine", {"engine": "kernel"}, confirm="kernel")
        elif op == "program":
            _kmod_step(job, "kmod-engine", {"engine": "program"}, confirm="program")
        elif op == "rebuild":
            r = _kmod_step(job, "kmod-install", {"rebuild": "on", "headers_meta": "off"})
            # Выбран модуль, а профили после перезагрузки в новое ядро ушли на программу — вернуть их на модуль (как SSH).
            if bridge_ok(r) and r.get("want") == "kernel" and r.get("state") != "on":
                _kmod_step(job, "kmod-engine", {"engine": "kernel"}, confirm="kernel")
        elif op == "remove":
            _kmod_step(job, "kmod-remove", {}, confirm="kmod-remove")
    except Exception as exc:  # noqa: BLE001 — поток не роняет панель; итог — словами «сбой» с видом ошибки
        sys.stderr.write(f"[admin] kmod {op}: {type(exc).__name__}\n")
        with _KMOD_JOB_LOCK:
            job["steps"].append({"action": job["step"] or op, "ok": False, "code": "transport", "message": ""})
    finally:
        with _KMOD_JOB_LOCK:
            job["done"] = True
            job["finished"] = _now()
            job["step"] = ""
        _CALL_CTX.lang = ""
        _snapshot_invalidate()


def kmod_job_start(op: str, who: str, confirm: Any, headers_meta: Any = None) -> Tuple[int, Dict[str, Any]]:
    """POST /api/kmod/<op>: проверить и начать действие в фоне. Ответ сразу: job (идёт) или отказ — 404 незнакомое
    действие, 400 без верного confirm или с кривым headers_meta, 409 — действие панели с модулем уже идёт."""
    s = panel_strings()
    if op not in KMOD_OPS:
        return 404, {"ok": False, "error": _fill(s["kmod_bad_op"], a=op), "code": "unknown_action"}
    if confirm is None or not hmac.compare_digest(text_bytes(confirm), text_bytes(op)):
        return 400, {"ok": False, "error": f"подтвердите действие: confirm должен совпадать с {op}", "code": "confirm_required"}
    if headers_meta not in (None, "", "on", "off"):
        return 400, {"ok": False, "error": "headers_meta: on или off", "code": "bad_arg"}
    with _KMOD_JOB_LOCK:
        cur = _KMOD_JOB.get("job")
        if cur and not cur["done"]:
            return 409, {"ok": False, "error": s["kmod_busy"], "code": "kmod_busy"}
        job = {"id": secrets.token_hex(6), "op": op, "who": who, "lang": call_lang(), "started": _now(), "finished": 0.0,
               "done": False, "step": "", "steps": []}
        _KMOD_JOB["job"] = job
    th = threading.Thread(target=_kmod_job_run, args=(job, "on" if headers_meta == "on" else "off"),
                          name=f"ga-kmod-{op}", daemon=True)
    job["thread"] = th
    th.start()
    return 200, {"ok": True, "data": {"job": kmod_job_payload()}}


def actions_payload() -> Dict[str, Any]:
    """Каталог действий для фронтенда: имена, параметры, описания — без секретов.

    По нему интерфейс строит проверки ввода (те же регексы) и знает, что
    разрушительно (typed-confirm) — не дублируя список в app.js.
    """
    spec = load_actions()
    acts = {}
    for name, adef in (spec.get("actions") or {}).items():
        if not isinstance(adef, dict):
            continue
        acts[name] = {"readonly": bool(adef.get("readonly")), "destructive": bool(adef.get("destructive")),
                      "secret": bool(adef.get("secret")), "params": adef.get("params") or {},
                      "description": adef.get("description") or {}}
    types = {}
    for name, pdef in (spec.get("param_types") or {}).items():
        if isinstance(pdef, dict):
            types[name] = {k: pdef[k] for k in ("type", "pattern", "enum", "minimum", "maximum", "maxLength", "description") if k in pdef}
    return {"actions": acts, "param_types": types}


# ────────────────────────────────────────────────────────────────────────────
# Каталог шаблонов сайта — через lib/catalog_tool.py (навык site-templates-library).
# Файл ~14 МБ, грузим лениво при первом обращении к странице «Настройки → сайт».
# ────────────────────────────────────────────────────────────────────────────
_CATALOG_LOCK = threading.Lock()
_CATALOG: Any = None
_CATALOG_TRIED = False


def catalog() -> Any:
    global _CATALOG, _CATALOG_TRIED
    with _CATALOG_LOCK:
        if _CATALOG is not None or _CATALOG_TRIED:
            return _CATALOG
        _CATALOG_TRIED = True
        try:
            spec = importlib.util.spec_from_file_location("ga_catalog_tool", str(CATALOG_TOOL))
            if spec is None or spec.loader is None:
                return None
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            _CATALOG = mod.Catalog(str(CATALOG_FILE))
        except Exception as exc:
            sys.stderr.write(f"[admin] каталог шаблонов недоступен: {exc}\n")
            _CATALOG = None
        return _CATALOG


def _template_public(t: Dict[str, Any]) -> Dict[str, Any]:
    return {"id": str(t.get("id") or ""), "name": str(t.get("name") or ""),
            "description": str(t.get("description") or "")[:200], "category": str(t.get("category") or ""),
            "preview_url": str(t.get("preview_url") or ""), "license": str(t.get("license") or ""),
            "stars": t.get("stars"), "source": str(t.get("source") or "")}


def templates_payload(cat_id: str, query: str, page: int, per: int = 24) -> Dict[str, Any]:
    c = catalog()
    if c is None:
        return {"available": False, "categories": [], "items": [], "pages": 0, "page": 0, "total": 0}
    cats = [{"id": cid, "name": name, "count": n} for cid, name, n in c.categories()]
    if query:
        found = c.search(query, cat_id or None, limit=480)
        pages = max(1, (len(found) + per - 1) // per)
        page = max(0, min(page, pages - 1))
        items = found[page * per:(page + 1) * per]
        total = len(found)
    elif cat_id:
        items, pages = c.page(cat_id, page, per)
        page = max(0, min(page, pages - 1))
        total = len(c.templates(cat_id))
        items = [dict(t, category=cat_id) for t in items]
    else:
        items, pages, total = [], 0, 0
    return {"available": True, "categories": cats, "items": [_template_public(t) for t in items],
            "pages": pages, "page": page, "total": total, "query": query, "category": cat_id}


def current_template_payload() -> Dict[str, Any]:
    pub = public_config(read_config())
    tid = pub["site"]["template_id"]
    info: Dict[str, Any] = {"template_id": tid, "template_source": pub["site"]["template_source"],
                            "mode": pub["mode"], "domain": pub["domain"], "alt_svc": pub["options"]["alt_svc"],
                            "listen": pub["site"]["listen"]}
    c = catalog() if tid else None
    if c is not None:
        t = c.get(tid)
        if t:
            info["template"] = _template_public(t)
    return info


# ════════════════════════════════════════════════════════════════════════════
# Страница входа (для браузера без сессии). Язык — из config.json.
# ════════════════════════════════════════════════════════════════════════════
LOGIN_STRINGS = {
    "ru": {
        "title": "Вход", "heading": "Панель goAmnezia",
        "tab_code": "Код из Telegram", "tab_pwd": "Логин и пароль", "tab_token": "Туннель и токен", "tab_code_off": "Telegram-бот на этом сервере не настроен", "tab_pwd_off": "Пароль на этом сервере ещё не задан",
        "tfa_hint": "Код придёт в Telegram администратору. Действует 5 минут.",
        "req": "Прислать код", "go": "Войти",
        "pwd_hint": "Логин и пароль выданы при установке панели.",
        "pwd_login": "Логин", "pwd_pass": "Пароль", "pwd_go": "Войти по паролю",
        "pwd_empty": "Введите логин и пароль", "pwd_wrong": "неверный логин или пароль",
        "pwd_blocked": "слишком много попыток — вход по паролю заперт ещё на {n} мин",
        "pwd_none": "пароль на этом сервере не задан",
        "pwd_bad_current": "текущий пароль не подошёл",
        "pwd_short": "новый пароль короче {n} символов",
        "pwd_changed": "пароль изменён",
        "pwd_unset": "Пароль ещё не задан — так бывает после обновления со старой установки. Задайте его на сервере, командой ниже, и войдите заново.",
        "no_way": "Войти отсюда пока нечем: пароль не задан, а Telegram-бот не настроен. Откройте панель по SSH-туннелю и задайте пароль:",
        "tunnel_hint": "SSH-туннель — вход без кода и пароля:",
        "token_hint": "Аварийный путь — токен:", "token_then": "затем откройте",
        "entering": "Вхожу через Telegram…", "done": "Готово, входим…", "sig_fail": "подпись не подошла — введите код",
        "sending": "Отправляю…", "sent": "Код отправлен в Telegram", "fail": "не вышло",
        "six": "Нужны шесть цифр", "checking": "Проверяю…", "wrong": "неверный код",
        "bad_reply": "сервер ответил не по-человечески",
        # Отказы маршрутов входа (код, подпись мини-аппа, стража сессии) — решение владельца В4 (26.09.2026):
        # у каждого машинный код и тот же текст на обоих языках (auth_text), чтобы экран входа любого
        # интерфейса показал причину на своём языке. Тексты — прежние русские слова сервера, дословно.
        "code_off_no_admins": "вход по коду недоступен: Telegram-бот не установлен или в его настройках нет ни одного "
                              "администратора (ALLOWED_IDS). Откройте панель по SSH-туннелю — команда на странице входа.",
        "code_off_no_token": "вход по коду недоступен: у бота не задан BOT_TOKEN. Откройте панель по SSH-туннелю — "
                             "команда на странице входа.",
        "code_cooldown": "код уже отправлен, повторите через {n} с",
        "code_hour_limit": "слишком много запросов кода, попробуйте через час",
        "code_net_limit": "слишком много запросов кода из интернета за этот час — войдите по логину и паролю или через "
                          "SSH-туннель, либо повторите позже",
        "code_chat_not_started": "Telegram не доставил код: администратор не начинал переписку с ботом. Откройте {where} "
                                 "в Telegram и нажмите Start, затем запросите код заново. Бот не может написать первым — "
                                 "это правило Telegram, а не настройка сервера.",
        "your_bot": "вашего бота",
        "code_send_failed": "не удалось отправить код через бота",
        "code_send_failed_why": "не удалось отправить код через бота: {why}",
        "code_expired": "код истёк — запросите новый",
        "code_too_many": "слишком много попыток — запросите новый код",
        "code_wrong": "неверный код, осталось попыток: {n}",
        "sig_invalid": "подпись Telegram не подтверждена",
        "sig_expired": "подпись Telegram устарела — откройте панель из бота ещё раз",
        "sig_not_admin": "вы не администратор этого сервера — откройте панель из аккаунта администратора бота",
        "sig_no_admins": "у бота ещё нет администраторов — привяжите себя в SSH-меню «Telegram-бот → Администраторы → "
                         "Привязать по сообщению»",
        "sig_no_token": "бот на сервере не настроен (нет BOT_TOKEN) — войдите через SSH-туннель",
        "pwd_bad_chars": "пароль: недопустимые символы",
        "pwd_write_failed": "не удалось записать {file}: {why}",
        "sess_renew": "сессию нужно продлить кодом из бота",
        "sess_expired": "сессия закончилась — войдите заново",
        "auth_required": "нужно войти: кодом, паролем или через SSH-туннель",
        # Страница входа 0.5.0 (макет pageLogin): свои строки lg_*; отказы маршрутов — прежними ключами выше.
        "lg_h1": "Вход в панель",
        "lg_server": "Сервер {h}",
        "lg_seg_code": "Код из бота",
        "lg_seg_pwd": "Пароль",
        "lg_seg_aria": "Способ входа",
        "lg_code_intro": "Код придёт в Telegram администраторам бота. Он действует 5 минут.",
        "lg_send": "Прислать код в Telegram",
        "lg_sending": "Отправляю…",
        "lg_send_new": "Прислать новый код",
        "lg_sent_b": "Код отправлен.",
        "lg_sent_t": "Действует 5 минут. Откройте последнее сообщение бота.",
        "lg_otp_aria": "Код из шести цифр",
        "lg_signin": "Войти",
        "lg_checking": "Проверяю…",
        "lg_resend_in": "Прислать ещё раз можно через {t}",
        "lg_resend": "Прислать ещё раз",
        "lg_ok_b": "Вход выполнен.",
        "lg_ok_t": "Сессия — 15 минут, продлевается кодом из бота.",
        "lg_wrong_b": "Код не подошёл.",
        "lg_wrong_t": "Откройте последнее сообщение бота: старые коды не действуют. Осталось попыток: {n}.",
        "lg_expired_b": "Код устарел —",
        "lg_expired_t": "запросите новый.",
        "lg_toomany_b": "Слишком много неверных попыток.",
        "lg_toomany_t": "Этот код больше не действует — запросите новый.",
        "lg_nobot_b": "Бот не настроен —",
        "lg_nobot_t": "войдите по паролю или через SSH-туннель.",
        "lg_use_pwd": "Войти по паролю",
        "lg_notoken_b": "Вход по коду недоступен:",
        "lg_notoken_t": "у бота не задан токен. Войдите паролем или через SSH-туннель.",
        "lg_start_b": "Администратор ещё не нажимал Start у бота.",
        "lg_start_t": "Откройте бота в Telegram и нажмите Start, затем запросите код снова. Бот не может написать первым — это правило Telegram.",
        "lg_tg_b": "Telegram не принял сообщение —",
        "lg_tg_t": "попробуйте через минуту.",
        "lg_tg_reply": "Ответ Telegram: «{r}».",
        "lg_often_b": "Слишком часто:",
        "lg_often_t": "не больше 5 кодов в час. Попробуйте через час или войдите по паролю.",
        "lg_cool_b": "Код уже отправлен —",
        "lg_cool_t": "новый можно запросить через {t}. Откройте последнее сообщение бота.",
        "lg_net_b": "Слишком много запросов кода из интернета за этот час —",
        "lg_net_t": "войдите паролем или через SSH-туннель.",
        "lg_login": "Логин",
        "lg_pass": "Пароль",
        "lg_pwd_wrong": "Неверный логин или пароль.",
        "lg_pwd_locked_b": "Слишком много попыток:",
        "lg_pwd_locked_t": "вход по паролю с этого адреса закрыт на {n} мин. Код из бота и SSH-туннель работают.",
        "lg_pwd_unset_b": "Пароль не задан —",
        "lg_pwd_unset_t": "задайте его в SSH-меню: Настройки → Веб-панель, админы бота, ИИ-агенты → Панель и мини-апп → Пароль панели: перевыпустить. Или войдите по SSH-туннелю:",
        "lg_forgot": "Забыли пароль — задайте новый в SSH-меню: Настройки → Веб-панель, админы бота, ИИ-агенты → Панель и мини-апп → Пароль панели: перевыпустить",
        "lg_or": "или",
        "lg_howto_link": "Пароль не задан. Как задать пароль",
        "lg_howto_b": "Пароль не задан.",
        "lg_howto_t": "Откройте панель по SSH-туннелю — без кода и пароля — и задайте пароль в «Настройки → Вход в панель → Пароль панели». Или на сервере в SSH-меню: Настройки → Веб-панель, админы бота, ИИ-агенты → Панель и мини-апп → Пароль панели: перевыпустить.",
        "lg_code_later": "Вход кодом появится, когда настроите Telegram-бота.",
        "lg_noway_t": "Войти отсюда нечем",
        "lg_noway_x": "Пароль не задан, а Telegram-бот не настроен.",
        "lg_way_tun": "Откройте панель по SSH-туннелю — без кода и пароля",
        "lg_way_tun_s": "Затем в браузере: http://127.0.0.1:{p}/",
        "lg_way_pwd": "Задайте пароль",
        "lg_way_pwd_s": "В панели: «Настройки → Вход в панель → Пароль панели». После этого вход по паролю заработает и здесь. Или на сервере командой:",
        # SEC50-08 (решение владельца 28.09): аварийный ключ выдаёт только SSH-меню — на час, одной строкой с командой
        # туннеля; принимается он только через SSH-туннель и сгорает после входа. С домена — пароль или код из бота.
        "lg_way_tok": "Аварийный ключ — только через SSH-туннель",
        "lg_way_tok_s": "Создайте его в SSH-меню: Настройки → Веб-панель, админы бота, ИИ-агенты → Панель и мини-апп → "
                        "Аварийный ключ — меню напечатает команду туннеля и адрес с ключом. Ключ живёт час и сгорает "
                        "после входа; с домена не принимается.",
        "lg_tok_net_b": "Аварийный ключ работает только через SSH-туннель.",
        "lg_tok_net_t": "С домена входят паролем или кодом из бота. Ключ создаётся в SSH-меню (Настройки → Веб-панель, "
                        "админы бота, ИИ-агенты → Панель и мини-апп → Аварийный ключ) — там же команда туннеля и адрес "
                        "с ключом.",
        "lg_tok_bad_b": "Аварийный ключ не подошёл.",
        "lg_tok_bad_t": "Он живёт час и сгорает после входа. Создайте новый в SSH-меню: Настройки → Веб-панель, админы "
                        "бота, ИИ-агенты → Панель и мини-апп → Аварийный ключ.",
        "tok_net": "аварийный ключ работает только через SSH-туннель — с домена войдите паролем или кодом из бота",
        "tok_bad": "аварийный ключ не подошёл: он живёт час и сгорает после входа — создайте новый в SSH-меню",
        "lg_foot_tun": "Вход через SSH-туннель работает всегда",
        "lg_lang_aria": "Язык",
        "lg_lang_ru": "Русский",
        "lg_lang_en": "English",
        "lg_mini_wait": "Вхожу через Telegram…",
        "lg_mini_ok": "Открываю панель…",
        "lg_mini_sig_b": "Telegram не подтвердил вход —",
        "lg_mini_sig_t": "закройте мини-приложение и откройте его снова из меню бота. Или войдите кодом.",
        "lg_mini_exp_b": "Подпись Telegram устарела —",
        "lg_mini_adm_b": "Этот аккаунт Telegram не администратор бота.",
        "lg_mini_adm_t": "Войдите кодом — его пришлют администраторам. Добавить вас в администраторы может владелец бота командой /invite.",
        "lg_mini_noadm_b": "У бота ещё нет администраторов —",
        "lg_mini_noadm_t": "привяжите себя в SSH-меню: Telegram-бот → Администраторы → Привязать по сообщению.",
        "lg_mini_notok_b": "Бот на сервере не настроен —",
        "lg_mini_notok_t": "войдите по SSH-туннелю.",
        "lg_fail": "Сервер не ответил — проверьте связь и повторите.",
    },
    "en": {
        "title": "Sign in", "heading": "goAmnezia panel",
        "tab_code": "Telegram code", "tab_pwd": "Login and password", "tab_token": "Tunnel and token", "tab_code_off": "The Telegram bot is not configured on this server", "tab_pwd_off": "No password is set on this server yet",
        "tfa_hint": "A code is sent to the administrator in Telegram. Valid for 5 minutes.",
        "req": "Send code", "go": "Sign in",
        "pwd_hint": "The login and password were issued when the panel was installed.",
        "pwd_login": "Login", "pwd_pass": "Password", "pwd_go": "Sign in with a password",
        "pwd_empty": "Enter the login and the password", "pwd_wrong": "wrong login or password",
        "pwd_blocked": "too many attempts — password login is locked for another {n} min",
        "pwd_none": "no password is set on this server",
        "pwd_bad_current": "the current password does not match",
        "pwd_short": "the new password is shorter than {n} characters",
        "pwd_changed": "password changed",
        "pwd_unset": "No password is set yet — that happens after an upgrade from an older install. Set it on the server with the command below and sign in again.",
        "no_way": "There is no way in from here yet: no password is set and the Telegram bot is not configured. Open the panel over an SSH tunnel and set a password:",
        "tunnel_hint": "SSH tunnel — no code and no password needed:",
        "token_hint": "Emergency path — the token:", "token_then": "then open",
        "entering": "Signing in via Telegram…", "done": "Done, entering…", "sig_fail": "signature rejected — enter the code",
        "sending": "Sending…", "sent": "Code sent to Telegram", "fail": "failed",
        "six": "Six digits required", "checking": "Checking…", "wrong": "wrong code",
        "bad_reply": "the server replied with garbage",
        "code_off_no_admins": "sign-in by code is unavailable: the Telegram bot is not installed or has no administrators "
                              "in its settings (ALLOWED_IDS). Open the panel over an SSH tunnel — the command is on the "
                              "sign-in page.",
        "code_off_no_token": "sign-in by code is unavailable: the bot has no BOT_TOKEN. Open the panel over an SSH "
                             "tunnel — the command is on the sign-in page.",
        "code_cooldown": "a code has already been sent, retry in {n} s",
        "code_hour_limit": "too many code requests, try again in an hour",
        "code_net_limit": "too many code requests from the internet this hour — sign in with the login and password or "
                          "over an SSH tunnel, or retry later",
        "code_chat_not_started": "Telegram did not deliver the code: the administrator has never started a chat with the "
                                 "bot. Open {where} in Telegram and press Start, then request the code again. A bot "
                                 "cannot write first — that is Telegram's rule, not a server setting.",
        "your_bot": "your bot",
        "code_send_failed": "could not send the code through the bot",
        "code_send_failed_why": "could not send the code through the bot: {why}",
        "code_expired": "the code has expired — request a new one",
        "code_too_many": "too many attempts — request a new code",
        "code_wrong": "wrong code, attempts left: {n}",
        "sig_invalid": "the Telegram signature is not confirmed",
        "sig_expired": "the Telegram signature has expired — open the panel from the bot again",
        "sig_not_admin": "you are not an administrator of this server — open the panel from the bot administrator's "
                         "account",
        "sig_no_admins": "the bot has no administrators yet — bind yourself in the SSH menu «Telegram bot → "
                         "Administrators → Bind by message»",
        "sig_no_token": "the bot on the server is not configured (no BOT_TOKEN) — sign in over an SSH tunnel",
        "pwd_bad_chars": "password: characters that are not allowed",
        "pwd_write_failed": "could not write {file}: {why}",
        "sess_renew": "the session needs renewing with a code from the bot",
        "sess_expired": "the session has ended — sign in again",
        "auth_required": "sign-in required: by code, password or over an SSH tunnel",
        # Страница входа 0.5.0 (макет pageLogin): свои строки lg_*; отказы маршрутов — прежними ключами выше.
        "lg_h1": "Sign in to the panel",
        "lg_server": "Server {h}",
        "lg_seg_code": "Bot code",
        "lg_seg_pwd": "Password",
        "lg_seg_aria": "Sign-in method",
        "lg_code_intro": "The code goes to the bot admins in Telegram. It is valid for 5 minutes.",
        "lg_send": "Send a code to Telegram",
        "lg_sending": "Sending…",
        "lg_send_new": "Send a new code",
        "lg_sent_b": "Code sent.",
        "lg_sent_t": "Valid for 5 minutes. Open the bot’s latest message.",
        "lg_otp_aria": "Six-digit code",
        "lg_signin": "Sign in",
        "lg_checking": "Checking…",
        "lg_resend_in": "You can resend in {t}",
        "lg_resend": "Send again",
        "lg_ok_b": "Signed in.",
        "lg_ok_t": "The session lasts 15 minutes and renews with a bot code.",
        "lg_wrong_b": "The code did not match.",
        "lg_wrong_t": "Open the bot’s latest message: old codes do not work. Attempts left: {n}.",
        "lg_expired_b": "The code has expired —",
        "lg_expired_t": "request a new one.",
        "lg_toomany_b": "Too many wrong attempts.",
        "lg_toomany_t": "This code no longer works — request a new one.",
        "lg_nobot_b": "The bot is not configured —",
        "lg_nobot_t": "sign in with the password or over an SSH tunnel.",
        "lg_use_pwd": "Use the password",
        "lg_notoken_b": "Code sign-in is unavailable:",
        "lg_notoken_t": "the bot has no token set. Sign in with the password or over an SSH tunnel.",
        "lg_start_b": "The admin has never pressed Start in the bot.",
        "lg_start_t": "Open the bot in Telegram and press Start, then request the code again. A bot cannot write first — that is Telegram’s rule.",
        "lg_tg_b": "Telegram did not accept the message —",
        "lg_tg_t": "try again in a minute.",
        "lg_tg_reply": "Telegram replied: “{r}”.",
        "lg_often_b": "Too often:",
        "lg_often_t": "no more than 5 codes an hour. Try in an hour or sign in with the password.",
        "lg_cool_b": "A code has already been sent —",
        "lg_cool_t": "you can request a new one in {t}. Open the bot’s latest message.",
        "lg_net_b": "Too many code requests from the internet this hour —",
        "lg_net_t": "sign in with the password or over an SSH tunnel.",
        "lg_login": "Login",
        "lg_pass": "Password",
        "lg_pwd_wrong": "Wrong login or password.",
        "lg_pwd_locked_b": "Too many attempts:",
        "lg_pwd_locked_t": "password sign-in from this address is locked for {n} min. The bot code and the SSH tunnel still work.",
        "lg_pwd_unset_b": "No password is set —",
        "lg_pwd_unset_t": "set it in the SSH menu: Settings → Web panel, bot admins, AI agents → Panel and mini app → Panel password: reissue. Or sign in over the SSH tunnel:",
        "lg_forgot": "Forgot the password — set a new one in the SSH menu: Settings → Web panel, bot admins, AI agents → Panel and mini app → Panel password: reissue",
        "lg_or": "or",
        "lg_howto_link": "No password set. How to set one",
        "lg_howto_b": "No password is set.",
        "lg_howto_t": "Open the panel over an SSH tunnel — no code or password — and set a password in Settings → Panel access → Panel password. Or on the server in the SSH menu: Settings → Web panel, bot admins, AI agents → Panel and mini app → Panel password: reissue.",
        "lg_code_later": "Code sign-in appears once the Telegram bot is set up.",
        "lg_noway_t": "There is no way in from here",
        "lg_noway_x": "No password is set and the Telegram bot is not configured.",
        "lg_way_tun": "Open the panel over an SSH tunnel — no code or password",
        "lg_way_tun_s": "Then in the browser: http://127.0.0.1:{p}/",
        "lg_way_pwd": "Set a password",
        "lg_way_pwd_s": "In the panel: Settings → Panel access → Panel password. Then password sign-in works here too. Or on the server with:",
        "lg_way_tok": "Emergency key — over an SSH tunnel only",
        "lg_way_tok_s": "Create it in the SSH menu: Settings → Web panel, bot admins, AI agents → Panel and mini app → "
                        "Emergency key — the menu prints the tunnel command and the address with the key. The key lives an "
                        "hour and burns after sign-in; it is never accepted from the domain.",
        "lg_tok_net_b": "The emergency key works only over an SSH tunnel.",
        "lg_tok_net_t": "From the domain, sign in with the password or a bot code. The key is created in the SSH menu "
                        "(Settings → Web panel, bot admins, AI agents → Panel and mini app → Emergency key), which also "
                        "prints the tunnel command and the address with the key.",
        "lg_tok_bad_b": "The emergency key did not work.",
        "lg_tok_bad_t": "It lives an hour and burns after sign-in. Create a new one in the SSH menu: Settings → Web panel, "
                        "bot admins, AI agents → Panel and mini app → Emergency key.",
        "tok_net": "the emergency key works only over an SSH tunnel — from the domain, sign in with the password or a bot code",
        "tok_bad": "the emergency key did not work: it lives an hour and burns after sign-in — create a new one in the SSH menu",
        "lg_foot_tun": "Sign-in over an SSH tunnel always works",
        "lg_lang_aria": "Language",
        "lg_lang_ru": "Russian",
        "lg_lang_en": "English",
        "lg_mini_wait": "Signing in via Telegram…",
        "lg_mini_ok": "Opening the panel…",
        "lg_mini_sig_b": "Telegram did not confirm the sign-in —",
        "lg_mini_sig_t": "close the mini app and open it again from the bot menu. Or sign in with a code.",
        "lg_mini_exp_b": "The Telegram signature has expired —",
        "lg_mini_adm_b": "This Telegram account is not a bot admin.",
        "lg_mini_adm_t": "Sign in with a code — it goes to the admins. The bot owner can add you with /invite.",
        "lg_mini_noadm_b": "The bot has no admins yet —",
        "lg_mini_noadm_t": "bind yourself in the SSH menu: Telegram bot → Administrators → Bind by message.",
        "lg_mini_notok_b": "The bot on the server is not configured —",
        "lg_mini_notok_t": "sign in over the SSH tunnel.",
        "lg_fail": "The server did not answer — check the connection and retry.",
    },
}

def login_strings(lang: Optional[str] = None) -> Dict[str, str]:
    """Словарь страницы входа — он же источник ответов маршрутов входа.

    Ответы про пароль человек читает так же, как надписи на форме, поэтому и
    берутся они из одного словаря: RU и EN в паритете, ни одной строки мимо.
    """
    lang = lang if lang in LOGIN_STRINGS else read_language()
    return LOGIN_STRINGS.get(lang, LOGIN_STRINGS["ru"])


def _fill(template: str, **vars_: Any) -> str:
    for key, val in vars_.items():
        template = template.replace("{" + key + "}", str(val))
    return template


class AuthText(str):
    """Отказ маршрута входа: строка на языке панели (как прежде — её и пишут в `error`, в журнал и
    сравнивают проверки) плюс машинный код, тот же текст на обоих языках и числа для интерфейса.

    Строкой — чтобы tfa_request/tfa_verify и их вызывающие не заметили разницы; code, texts и extra
    уходят в ответ API (auth_fields). Решение владельца В4 (26.09.2026): экран входа любого интерфейса
    показывает причину на своём языке, а не на языке config.json. Логика входа от этого не меняется.
    """
    code: str = ""
    texts: Dict[str, str] = {}
    extra: Dict[str, Any] = {}


def auth_text(code: str, key: str, extra: Optional[Dict[str, Any]] = None, **vars_: Any) -> AuthText:
    """Отказ входа по ключу LOGIN_STRINGS. Подстановка — одна на оба языка или {"ru": …, "en": …}."""
    texts = {lang: _fill(LOGIN_STRINGS[lang][key],
                         **{k: (v.get(lang, "") if isinstance(v, dict) else v) for k, v in vars_.items()})
             for lang in ("ru", "en")}
    out = AuthText(texts.get(read_language(), texts["ru"]))
    out.code, out.texts, out.extra = code, texts, dict(extra or {})
    return out


def auth_fields(message: Any) -> Dict[str, Any]:
    """Поля ответа из AuthText: `code`, `texts{ru, en}` и числа (`seconds`, `left`, `reason`); иначе пусто."""
    if not isinstance(message, AuthText):
        return {}
    return {"code": message.code, "texts": dict(message.texts), **message.extra}


# raw-строка: в JS-регэкспах есть \/ — в обычной строке это DeprecationWarning, с Python 3.12 SyntaxError.
LOGIN_PAGE_HTML = r"""<!doctype html>
<html lang="__LANG__" data-hero="" data-theme="light" data-tint="neutral" data-density="detailed" data-btn="pill" data-cards="shadow" data-fs="m" data-vibrant="false" data-motion="on" data-device="desktop" data-tgc="off"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<title>__T_title__</title>
<!-- Скрипта с telegram.org здесь нет намеренно: у нашей аудитории он часто
     заблокирован, и страница десятки секунд ждала бы его. Подпись мини-аппа
     Telegram передаёт в адресе (#tgWebAppData=…) — читаем её сами. -->
<script>
 // Вход — тот же продукт, что панель: те же стили (styles.css) и тот же вид с первого кадра. Вид — копия из
 // localStorage (её пишет панель); у старой установки — прежний ключ темы goamnezia-theme. Тема «Система» следует
 // устройству (prefers-color-scheme: dark), мини-апп — цветам Telegram из адреса (tgWebAppThemeParams).
 (function(){
  var root=document.documentElement,tg=null,isTg=false,ap={};
  try{
   var h=location.hash.replace(/^#/,"");
   if(h.indexOf("tgWebAppData=")!==-1){var parts=h.split("&");for(var i=0;i<parts.length;i++){var kv=parts[i].split("=");
    if(kv[0]==="tgWebAppData"&&kv[1])sessionStorage.setItem("goamnezia-tg-init",decodeURIComponent(kv[1]));
    if(kv[0]==="tgWebAppThemeParams"&&kv[1])sessionStorage.setItem("goamnezia-tg-theme-params",decodeURIComponent(kv[1]));}}
   isTg=!!sessionStorage.getItem("goamnezia-tg-init");
   tg=JSON.parse(sessionStorage.getItem("goamnezia-tg-theme-params")||"null");
  }catch(e){}
  try{ap=JSON.parse(localStorage.getItem("goamnezia-appearance-v1")||"{}")||{};}catch(e){ap={};}
  try{if(!ap.theme){var old=localStorage.getItem("goamnezia-theme");if(old==="dark"||old==="light")ap.theme=old;}}catch(e){}
  var pick=function(v,list,d){return list.indexOf(v)!==-1?v:d;};
  var theme=pick(ap.theme,["light","dark","system"],"system");
  if(isTg){try{theme=pick(localStorage.getItem("goamnezia-tg-theme"),["light","dark","system","telegram"],"telegram");}catch(e){theme="telegram";}}
  var hex=/^#([0-9a-f]{6})$/i,useTg=theme==="telegram"&&tg&&hex.test(tg.bg_color||"");
  var th=theme;
  if(theme==="system")th=matchMedia("(prefers-color-scheme: dark)").matches?"dark":"light";
  if(theme==="telegram"){th="light";if(useTg){var n=parseInt(tg.bg_color.slice(1),16);th=((n>>16)*299+((n>>8)&255)*587+(n&255)*114)/1000<128?"dark":"light";}}
  var W="oklch(0.9911 0 0)",E="oklch(0.2103 0.0059 285.89)",hue=Math.max(0,Math.min(359,parseInt(ap.hue,10)||200));
  var AC={ga:["oklch(0.6 0.13 222)",W],blue:["oklch(0.6204 0.195 253.83)",W],sky:["oklch(0.72 0.13 228)",E],lavender:["oklch(0.6 0.19 293)",W],
   mint:["oklch(0.74 0.15 163)",E],coral:["oklch(0.64 0.19 33)",W],graphite:th==="dark"?["oklch(0.95 0 0)",E]:["oklch(0.24 0.006 286)",W],custom:["oklch(0.63 0.17 "+hue+")",W]};
  var acc=AC[ap.accent]||AC.ga;
  if(useTg&&hex.test(tg.button_color||""))acc=[tg.button_color,hex.test(tg.button_text_color||"")?tg.button_text_color:W];
  root.setAttribute("data-theme",th);
  root.setAttribute("data-tint",pick(ap.tint,["neutral","warm","cool"],"neutral"));
  root.setAttribute("data-btn",pick(ap.btn,["pill","round"],"pill"));
  root.setAttribute("data-cards",pick(ap.cards,["shadow","border","flat"],"shadow"));
  root.setAttribute("data-fs",pick(ap.fs,["s","m","l"],"m"));
  root.setAttribute("data-vibrant",ap.vibrant===true?"true":"false");
  root.setAttribute("data-motion",ap.motion===false?"off":"on");
  root.setAttribute("data-device",matchMedia("(max-width: 699.98px)").matches?"phone":"desktop");
  root.setAttribute("data-tgc",useTg?"on":"off");
  root.style.setProperty("--accent",acc[0]);
  root.style.setProperty("--accent-foreground",acc[1]);
  root.style.setProperty("--radius",Math.max(0,Math.min(16,parseInt(ap.radius,10)>=0?parseInt(ap.radius,10):8))+"px");
  if(useTg){root.style.setProperty("--tg-bg",tg.bg_color);
   root.style.setProperty("--tg-secondary-bg",hex.test(tg.secondary_bg_color||"")?tg.secondary_bg_color:tg.bg_color);
   root.style.setProperty("--tg-text",hex.test(tg.text_color||"")?tg.text_color:(th==="dark"?"#ffffff":"#000000"));
   root.style.setProperty("--tg-hint",hex.test(tg.hint_color||"")?tg.hint_color:"#8e8e93");}
  try{var l=localStorage.getItem("goamnezia-lang");if(l==="ru"||l==="en")root.setAttribute("lang",l);}catch(e){}
 }());
</script>
<link rel="stylesheet" href="./styles.css?v=0.5.0">
<style>
 /* Своё у страницы входа — только раскладка (макет pageLogin): колонка 400 px по центру, знак, карточка, подвал.
    Цвета, кнопки, поля, алерты и поле кода — общие компоненты панели из styles.css. */
 :root{--bg:var(--background)}
 :root[data-theme="dark"]{color-scheme:dark}
 :root:not([data-theme="dark"]){color-scheme:light}
 body{margin:0;background:var(--bg);color:var(--foreground);font:400 var(--fs)/1.45 var(--font);-webkit-text-size-adjust:100%}
 .lg{min-height:100vh;min-height:100dvh;display:grid;place-items:center;padding:24px 16px;box-sizing:border-box}
 .lg__col{width:min(400px,100%);display:grid;gap:20px;min-width:0}
 .lg-brand{display:flex;align-items:center;gap:12px;justify-content:center}
 .lg-brand .gx-logo{width:40px;height:40px;border-radius:12px;font-size:14px}
 .lg-brand b{font:600 17px var(--font)}
 .lg-card{display:grid;gap:18px;padding:28px 24px;min-width:0}
 [data-device="phone"] .lg-card{padding:24px 18px}
 .lg-h1{text-align:center;display:grid;gap:4px;min-width:0}
 .lg-h1 h1{margin:0;font:600 22px/28px var(--font);letter-spacing:-.01em}
 .lg-h1 span{color:var(--muted);font-size:14px;overflow-wrap:anywhere}
 .lg-pane{display:grid;gap:18px;min-width:0}
 .lg-pane[hidden]{display:none}
 .lg-foot{display:grid;gap:12px;justify-items:center;min-width:0}
 .lg-tun{display:grid;gap:6px;justify-items:center;text-align:center;color:var(--muted);font-size:13px;min-width:0;max-width:100%}
 .lg-tun code{max-width:100%;font:12.5px var(--mono);padding:6px 10px;border-radius:var(--r-sm);background:var(--default);color:var(--foreground);overflow-wrap:anywhere;user-select:all}
 .lg-link{display:flex;justify-content:center}
</style>
</head><body>
<main class="lg"><div class="lg__col">
 <div class="lg-brand"><span class="gx-logo" aria-hidden="true">GA</span><b>goAmnezia pro</b></div>
 <section class="gx-card lg-card" aria-labelledby="lgTitle">
  <div class="lg-h1"><h1 id="lgTitle" data-t="lg_h1">__T_lg_h1__</h1><span id="lgHost"></span></div>
  <div id="note" class="lg-pane" hidden></div>
  <div id="mini" class="lg-pane" hidden></div>
  <div id="tabs" hidden></div>
  <!-- Код из бота: запросить → шесть цифр → войти. -->
  <div id="tfa" style="display:none">
   <div class="lg-pane">
    <p class="gx-p gx-p--lg gx-p--center" id="codeIntro" data-t="lg_code_intro">__T_lg_code_intro__</p>
    <div id="codeMsg" class="lg-pane" hidden></div>
    <div id="otpWrap" hidden><div class="gx-otp" id="otp"><div class="gx-otp__s"></div><div class="gx-otp__s"></div><div class="gx-otp__s"></div><div class="gx-otp__s"></div><div class="gx-otp__s"></div><div class="gx-otp__s"></div>
     <input id="code" inputmode="numeric" autocomplete="one-time-code" maxlength="6" aria-label="__T_lg_otp_aria__" data-ta="lg_otp_aria"></div></div>
    <div class="gx-btns"><div class="gx-btns__row"><button id="req" type="button" class="ga-btn ga-btn--primary ga-btn--full ga-btn--wi"></button><button id="go" type="button" class="ga-btn ga-btn--primary ga-btn--full" hidden data-t="lg_signin">__T_lg_signin__</button></div></div>
    <p class="gx-p gx-p--center" id="resend" hidden></p>
   </div>
  </div>
  <!-- Логин и пароль. Имя учётной записи страница не подставляет никак: это половина пары к паролю. -->
  <div id="pwd" style="display:none">
   <div class="lg-pane">
    <label class="gx-field"><span class="gx-field__l" data-t="lg_login">__T_lg_login__</span><input id="login" class="gx-input" autocomplete="username" autocapitalize="none" spellcheck="false" placeholder="__T_lg_login__" data-tp="lg_login"></label>
    <label class="gx-field"><span class="gx-field__l" data-t="lg_pass">__T_lg_pass__</span><input id="pass" class="gx-input" type="password" autocomplete="current-password"></label>
    <div id="pwdMsg" class="lg-pane" hidden></div>
    <div class="gx-btns"><div class="gx-btns__row"><button id="pgo" type="button" class="ga-btn ga-btn--primary ga-btn--full" data-t="lg_signin">__T_lg_signin__</button></div></div>
    <p class="gx-p gx-p--center" data-t="lg_forgot">__T_lg_forgot__</p>
   </div>
  </div>
  <!-- Войти отсюда нечем: пароля нет, бот не настроен — три пути словами. -->
  <div id="help" style="display:none"></div>
  <div id="more" class="lg-pane" hidden></div>
 </section>
 <div class="lg-foot">
  <div class="lg-tun" id="tunBox"><span data-t="lg_foot_tun">__T_lg_foot_tun__</span><code id="tun">ssh -L __ADMIN_PORT__:127.0.0.1:__ADMIN_PORT__ root@__SERVER_IP__</code></div>
  <div id="langSeg"></div>
 </div>
</div></main>
<script>
const TFA_OK=__TFA_AVAILABLE__;
const PWD_SET=__PWD_SET__;
const TT=__T_ALL__;
const PORT="__ADMIN_PORT__", RESET_CMD="__RESET_CMD__";
// Отказ аварийному ключу (SEC50-08): token_net — пришёл с домена, token_bad — по туннелю, но не подошёл.
const NOTICE="__NOTICE__";
const IC={"paper-plane":"<path fill-rule=\"evenodd\" d=\"M7.29 13.904L5.25 10.75L2.096 8.71a2.4 2.4 0 0 1 .5-4.278l9.273-3.296a2.346 2.346 0 0 1 2.996 2.995L13.45 3.63a.844.844 0 0 0-1.08-1.08L3.1 5.846a.9.9 0 0 0-.19 1.604l2.78 1.799l3.279-3.28a.75.75 0 1 1 1.06 1.061L6.75 10.31l1.799 2.779a.9.9 0 0 0 1.604-.188l3.297-9.272l1.413.502l-3.296 9.273a2.4 2.4 0 0 1-4.277.5\" clip-rule=\"evenodd\"/>","circle-check":"<path fill-rule=\"evenodd\" d=\"M13.5 8a5.5 5.5 0 1 1-11 0a5.5 5.5 0 0 1 11 0M15 8A7 7 0 1 1 1 8a7 7 0 0 1 14 0m-3.9-1.55a.75.75 0 1 0-1.2-.9L7.419 8.858L6.03 7.47a.75.75 0 0 0-1.06 1.06l2 2a.75.75 0 0 0 1.13-.08z\" clip-rule=\"evenodd\"/>","triangle-exclamation":"<path fill-rule=\"evenodd\" d=\"M7.134 2.994L2.217 11.5a1 1 0 0 0 .866 1.5h9.834a1 1 0 0 0 .866-1.5L8.866 2.993a1 1 0 0 0-1.732 0m3.03-.75c-.962-1.665-3.366-1.665-4.329 0L.918 10.749c-.963 1.666.24 3.751 2.165 3.751h9.834c1.925 0 3.128-2.085 2.164-3.751zM8 5a.75.75 0 0 1 .75.75v2a.75.75 0 0 1-1.5 0v-2A.75.75 0 0 1 8 5m1 5.75a1 1 0 1 1-2 0a1 1 0 0 1 2 0\" clip-rule=\"evenodd\"/>","circle-exclamation":"<path fill-rule=\"evenodd\" d=\"M8 13.5a5.5 5.5 0 1 0 0-11a5.5 5.5 0 0 0 0 11M8 15A7 7 0 1 0 8 1a7 7 0 0 0 0 14m1-4.5a1 1 0 1 1-2 0a1 1 0 0 1 2 0M8.75 5a.75.75 0 0 0-1.5 0v2.5a.75.75 0 0 0 1.5 0z\" clip-rule=\"evenodd\"/>","circle-info":"<path fill-rule=\"evenodd\" d=\"M8 13.5a5.5 5.5 0 1 0 0-11a5.5 5.5 0 0 0 0 11M8 15A7 7 0 1 0 8 1a7 7 0 0 0 0 14m1-9.5a1 1 0 1 1-2 0a1 1 0 0 1 2 0m-.25 3a.75.75 0 0 0-1.5 0V11a.75.75 0 0 0 1.5 0z\" clip-rule=\"evenodd\"/>","clock":"<path fill-rule=\"evenodd\" d=\"M13.5 8a5.5 5.5 0 1 1-11 0a5.5 5.5 0 0 1 11 0M15 8A7 7 0 1 1 1 8a7 7 0 0 1 14 0M8.75 4.5a.75.75 0 0 0-1.5 0V8a.75.75 0 0 0 .3.6l2 1.5a.75.75 0 1 0 .9-1.2l-1.7-1.275z\" clip-rule=\"evenodd\"/>","shield-exclamation":"<path fill-rule=\"evenodd\" d=\"m3.003 4.702 4.22-2.025a1.8 1.8 0 0 1 1.554 0l4.22 2.025a.89.89 0 0 1 .503.8V6a8.55 8.55 0 0 1-3.941 7.201l-.986.631a1.06 1.06 0 0 1-1.146 0l-.986-.63A8.55 8.55 0 0 1 2.5 6v-.498c0-.341.196-.652.503-.8m3.57-3.377L2.354 3.35A2.39 2.39 0 0 0 1 5.502V6a10.05 10.05 0 0 0 4.632 8.465l.986.63a2.56 2.56 0 0 0 2.764 0l.986-.63A10.05 10.05 0 0 0 15 6v-.498c0-.918-.526-1.755-1.354-2.152l-4.22-2.025a3.3 3.3 0 0 0-2.852 0M8 4.75a.75.75 0 0 1 .75.75v2a.75.75 0 0 1-1.5 0v-2A.75.75 0 0 1 8 4.75m1 5.75a1 1 0 1 1-2 0 1 1 0 0 1 2 0\" clip-rule=\"evenodd\"/>","lock":"<path fill-rule=\"evenodd\" d=\"M10.5 6V5a2.5 2.5 0 0 0-5 0v1zM4 5v1a3 3 0 0 0-3 3v3a3 3 0 0 0 3 3h8a3 3 0 0 0 3-3V9a3 3 0 0 0-3-3V5a4 4 0 0 0-8 0m6.5 2.5H12A1.5 1.5 0 0 1 13.5 9v3a1.5 1.5 0 0 1-1.5 1.5H4A1.5 1.5 0 0 1 2.5 12V9A1.5 1.5 0 0 1 4 7.5zm-1.75 2a.75.75 0 0 0-1.5 0v2a.75.75 0 0 0 1.5 0z\" clip-rule=\"evenodd\"/>","circle-question":"<path fill-rule=\"evenodd\" d=\"M8 13.5a5.5 5.5 0 1 0 0-11 5.5 5.5 0 0 0 0 11M8 15A7 7 0 1 0 8 1a7 7 0 0 0 0 14M6.44 4.54c.43-.354.994-.565 1.56-.565 1.217 0 2.34.82 2.34 2.14 0 .377-.078.745-.298 1.1-.208.339-.513.614-.875.867-.217.153-.325.257-.379.328-.038.052-.038.07-.038.089a.75.75 0 0 1-1.5 0c0-.794.544-1.286 1.057-1.645.28-.196.4-.332.458-.426a.54.54 0 0 0 .075-.312c0-.3-.244-.641-.84-.641a1 1 0 0 0-.608.223c-.167.138-.231.287-.231.418a.75.75 0 0 1-1.5 0c0-.674.345-1.22.78-1.577M8 12a1 1 0 1 0 0-2 1 1 0 0 0 0 2\" clip-rule=\"evenodd\"/>"};
const $=(id)=>document.getElementById(id);
const TUN=$('tun').textContent;
let lang=document.documentElement.lang==='en'?'en':'ru';
const tr=(k,v)=>{let s=(TT[lang]&&TT[lang][k])||TT.ru[k]||k;for(const x in (v||{}))s=s.split('{'+x+'}').join(String(v[x]));return s;};
const h=(tag,attrs,...kids)=>{const n=document.createElement(tag);for(const k in (attrs||{})){const v=attrs[k];if(v===null||v===undefined||v===false)continue;
  if(k==='text')n.textContent=v;else if(k==='html')n.innerHTML=v;else if(k.slice(0,2)==='on')n.addEventListener(k.slice(2),v);else n.setAttribute(k,v===true?'':v);}
  kids.flat().forEach((c)=>{if(c!==null&&c!==undefined&&c!==false)n.append(c);});return n;};
const svg=(name,size)=>{const d=IC[name];if(!d)return null;const s=h('span',{class:'gi','aria-hidden':'true'});s.style.width=s.style.height=(size||16)+'px';
  s.innerHTML='<svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true" focusable="false">'+d+'</svg>';return s;};
const TONE_IC={success:'circle-check',warning:'triangle-exclamation',danger:'circle-exclamation',accent:'circle-info',default:'circle-info'};
// Алерт — тот же, что в панели (U.al): что случилось жирным, что сделать — дальше.
function al(tone,title,text,o){o=o||{};
  const n=h('div',{class:'gx-al gx-al--'+tone,role:tone==='danger'?'alert':'status'},svg(o.icon||TONE_IC[tone],18));
  const t=h('span',{class:'gx-al__text'});if(title)t.append(h('b',{text:title}),document.createTextNode(' '));if(text)t.append(document.createTextNode(text));
  const b=h('div',{class:'gx-al__body'},t);if(o.code)b.append(h('code',{class:'gx-al__code',text:o.code}));
  if(o.btns&&o.btns.length)b.append(h('div',{class:'gx-al__btns'},o.btns));n.append(b);return n;}
const btn=(label,kind,fn,o)=>{o=o||{};const b=h('button',{type:'button',class:'ga-btn ga-btn--'+kind+(o.sm?' ga-btn--sm':'')+(o.full?' ga-btn--full':'')+(o.icon&&label?' ga-btn--wi':'')});
  if(o.icon)b.append(svg(o.icon,o.sm?14:16));b.append(document.createTextNode(label));if(fn)b.addEventListener('click',fn);return b;};
const fill=(box,nodes)=>{box.replaceChildren(...nodes.filter(Boolean));box.hidden=!box.childNodes.length;};
const mmss=(s)=>{s=Math.max(0,Math.ceil(s));return Math.floor(s/60)+':'+String(s%60).padStart(2,'0');};
function tgPostEvent(type,data){try{if(window.TelegramWebviewProxy&&window.TelegramWebviewProxy.postEvent)window.TelegramWebviewProxy.postEvent(type,JSON.stringify(data||{}));
  else if(window.parent!==window)window.parent.postMessage(JSON.stringify({eventType:type,eventData:data||{}}),'https://web.telegram.org');}catch(e){}}
// Какие способы есть: оба — вкладками; только код — ниже «как задать пароль»; только пароль — строка, что код
// появится с ботом; ни одного — три пути словами (туннель, пароль, аварийный токен). Причина — всегда текстом.
const V=TFA_OK&&PWD_SET?1:(TFA_OK?2:(PWD_SET?3:4));
let tab=V===1?'tfa':(V===2?'tfa':(V===3?'pwd':'help'));
if(V===1){try{const w=localStorage.getItem('goamnezia-login-tab');if(w==='tfa'||w==='pwd')tab=w;}catch(e){}}
const cs={phase:'idle',err:null,until:0,timer:null};   // код: idle | sending | sent; err — {kind, …}
const ps={busy:false,err:null};                        // пароль
let howto=false, miniState=null;
// Страница живёт под секретным путём на домене, поэтому абсолютный '/api/...'
// уходил бы на корень домена (сайт-маскировку) и возвращал 404. Клеим путь текущей страницы.
const BASE=location.pathname.replace(/\/[^/]*$/,'').replace(/\/$/,'');
async function post(url,body){
  try{const r=await fetch(BASE+url,{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json','X-GoAmnezia-Admin':'1','X-GoAmnezia-Lang':lang},body:JSON.stringify(body||{})});
    return await r.json().catch(()=>({ok:false,error:tr('bad_reply')}));}
  catch(e){return {ok:false,code:'transport',error:tr('lg_fail')};}
}
const said=(r)=>(r&&r.texts&&(r.texts[lang]||r.texts.ru))||(r&&r.error)||tr('lg_fail');
function openTab(name){tab=name;try{if(V===1)localStorage.setItem('goamnezia-login-tab',name);}catch(e){}render();
  const f=name==='pwd'?$('login'):null;if(f&&document.documentElement.dataset.device!=='phone')f.focus();}
// ── Код из бота ──
function renderCode(){
  const sent=cs.phase==='sent', e=cs.err||{};
  const dead=e.kind==='expired'||e.kind==='toomany';
  $('codeIntro').hidden=sent&&!dead;
  const msgs=[];
  if(e.kind==='ok')msgs.push(al('success',tr('lg_ok_b'),tr('lg_ok_t')));
  else if(sent&&!e.kind)msgs.push(al('success',tr('lg_sent_b'),tr('lg_sent_t'),{icon:'paper-plane'}));
  const toPwd=V===1?[btn(tr('lg_use_pwd'),'tertiary',()=>openTab('pwd'),{sm:true})]:[];
  if(e.kind==='nobot')msgs.push(al('warning',tr('lg_nobot_b'),tr('lg_nobot_t'),{btns:toPwd}));
  if(e.kind==='notoken')msgs.push(al('warning',tr('lg_notoken_b'),tr('lg_notoken_t'),{btns:toPwd}));
  if(e.kind==='start')msgs.push(al('warning',tr('lg_start_b'),tr('lg_start_t')));
  if(e.kind==='telegram')msgs.push(al('danger',tr('lg_tg_b'),tr('lg_tg_t')+(e.reply?' '+tr('lg_tg_reply',{r:e.reply}):'')));
  if(e.kind==='often')msgs.push(al('warning',tr('lg_often_b'),tr('lg_often_t')));
  if(e.kind==='cooldown')msgs.push(al('warning',tr('lg_cool_b'),tr('lg_cool_t',{t:mmss((cs.until-Date.now())/1000)}),{icon:'clock'}));
  if(e.kind==='netlimit')msgs.push(al('warning',tr('lg_net_b'),tr('lg_net_t'),{btns:toPwd}));
  if(e.kind==='wrong')msgs.push(al('danger',tr('lg_wrong_b'),tr('lg_wrong_t',{n:e.left})));
  if(e.kind==='expired')msgs.push(al('warning',tr('lg_expired_b'),tr('lg_expired_t')));
  if(e.kind==='toomany')msgs.push(al('danger',tr('lg_toomany_b'),tr('lg_toomany_t')));
  if(e.kind==='other')msgs.push(al('danger',null,e.text));
  fill($('codeMsg'),msgs);
  $('otpWrap').hidden=!sent;
  const otp=$('otp');otp.classList.toggle('is-err',e.kind==='wrong'||e.kind==='toomany');otp.classList.toggle('is-ok',e.kind==='ok');otp.classList.toggle('is-dis',dead||e.kind==='ok');
  $('code').disabled=dead||e.kind==='ok';
  drawSlots();
  const req=$('req');
  const showReq=!sent||dead;
  req.hidden=!showReq;
  req.disabled=cs.phase==='sending';
  req.replaceChildren(cs.phase==='sending'?h('span',{class:'gx-spin gx-spin--sm','aria-hidden':'true'}):svg('paper-plane',16),
    document.createTextNode(cs.phase==='sending'?tr('lg_sending'):(dead?tr('lg_send_new'):tr('lg_send'))));
  const go=$('go');go.hidden=!sent||dead||e.kind==='ok';go.disabled=$('code').value.length!==6||cs.busy;
  go.textContent=cs.busy?tr('lg_checking'):tr('lg_signin');
  const rs=$('resend');rs.replaceChildren();
  if(sent&&!dead&&e.kind!=='ok'){const left=(cs.until-Date.now())/1000;
    if(left>0)rs.append(document.createTextNode(tr('lg_resend_in',{t:mmss(left)})));
    else rs.append(btn(tr('lg_resend'),'ghost',()=>requestCode(),{sm:true}));}
  rs.hidden=!rs.childNodes.length;
}
function drawSlots(){const v=$('code').value, s=document.querySelectorAll('#otp .gx-otp__s'), focus=document.activeElement===$('code');
  s.forEach((n,i)=>{n.textContent=v[i]||'';n.classList.toggle('is-cur',focus&&i===Math.min(v.length,5));});}
function tick(){clearInterval(cs.timer);cs.timer=setInterval(()=>{if(cs.until<=Date.now()){clearInterval(cs.timer);cs.timer=null;if(cs.err&&cs.err.kind==='cooldown')cs.err=null;}renderCode();},1000);}
async function requestCode(){
  if(cs.phase==='sending')return;
  cs.phase='sending';cs.err=null;$('code').value='';renderCode();
  const r=await post('/api/auth/request');
  if(r.ok){cs.phase='sent';cs.until=Date.now()+30000;tick();renderCode();setTimeout(()=>$('code').focus(),30);return;}
  cs.phase='idle';
  const c=r.code||'',why=r.reason||'';
  if(c==='tfa_off')cs.err={kind:why==='no_token'?'notoken':'nobot'};
  else if(c==='too_often'&&why==='cooldown'){cs.err={kind:'cooldown'};cs.until=Date.now()+(Number(r.seconds)||30)*1000;tick();}
  else if(c==='too_often'&&why==='net_limit')cs.err={kind:'netlimit'};
  else if(c==='too_often')cs.err={kind:'often'};
  else if(c==='chat_not_started')cs.err={kind:'start'};
  else if(c==='send_failed'){const s=said(r),i=s.indexOf(': ');cs.err={kind:'telegram',reply:i>0?s.slice(i+2):''};}
  else cs.err={kind:'other',text:said(r)};
  renderCode();
}
async function verifyCode(){
  const code=$('code').value;
  if(!/^[0-9]{6}$/.test(code)||cs.busy)return;
  cs.busy=true;renderCode();
  const r=await post('/api/auth/verify',{code});
  cs.busy=false;
  if(r.ok){cs.err={kind:'ok'};renderCode();location.reload();return;}
  const c=r.code||'';
  if(c==='code_wrong')cs.err={kind:'wrong',left:Number(r.left)>=0?Number(r.left):0};
  else if(c==='code_expired')cs.err={kind:'expired'};
  else if(c==='code_too_many_attempts')cs.err={kind:'toomany'};
  else cs.err={kind:'other',text:said(r)};
  if(cs.err.kind==='wrong'){$('code').value='';}
  renderCode();
}
// ── Пароль ──
function renderPwd(){
  const e=ps.err||{};const msgs=[];
  if(e.kind==='wrong')msgs.push(al('danger',tr('lg_pwd_wrong'),''));
  if(e.kind==='locked')msgs.push(al('danger',tr('lg_pwd_locked_b'),tr('lg_pwd_locked_t',{n:e.min})));
  if(e.kind==='unset')msgs.push(al('warning',tr('lg_pwd_unset_b'),tr('lg_pwd_unset_t'),{code:TUN}));
  if(e.kind==='other')msgs.push(al('danger',null,e.text));
  fill($('pwdMsg'),msgs);
  $('pass').setAttribute('aria-invalid',e.kind==='wrong'?'true':'false');
  const go=$('pgo');go.disabled=ps.busy||e.kind==='locked'||!$('login').value.trim()||!$('pass').value;
  go.textContent=ps.busy?tr('lg_checking'):tr('lg_signin');
}
async function submitPwd(){
  const login=$('login').value.trim(),password=$('pass').value;
  if(!login||!password||ps.busy||(ps.err&&ps.err.kind==='locked'))return;
  ps.busy=true;ps.err=null;renderPwd();
  const r=await post('/api/auth/password',{login,password});
  ps.busy=false;
  // Пароль не остаётся в поле после неудачи: страница входа на домене
  // открыта из интернета, и брошенная вкладка не должна его хранить.
  $('pass').value='';
  if(r.ok){location.reload();return;}
  const c=r.code||'';
  if(c==='bad_credentials')ps.err={kind:'wrong'};
  else if(c==='too_many_attempts')ps.err={kind:'locked',min:Math.max(1,Math.ceil((Number(r.seconds)||900)/60))};
  else if(c==='password_unset')ps.err={kind:'unset'};
  else ps.err={kind:'other',text:said(r)};
  renderPwd();
}
// ── Мини-апп: подпись Telegram из адреса — входим без кода ──
function tgInitData(){try{const hh=location.hash.replace(/^#/,'');for(const part of hh.split('&')){const kv=part.split('=');if(kv[0]==='tgWebAppData'&&kv[1])return decodeURIComponent(kv[1]);}
  return sessionStorage.getItem('goamnezia-tg-init')||'';}catch(e){return '';}}
function renderMini(){
  const m=miniState;const nodes=[];
  if(m==='wait')nodes.push(al('accent',tr('lg_mini_wait'),'',{icon:'paper-plane'}));
  if(m==='ok')nodes.push(al('success',tr('lg_ok_b'),tr('lg_mini_ok')));
  if(m==='bad_signature')nodes.push(al('warning',tr('lg_mini_sig_b'),tr('lg_mini_sig_t'),{icon:'shield-exclamation'}));
  if(m==='expired')nodes.push(al('warning',tr('lg_mini_exp_b'),tr('lg_mini_sig_t'),{icon:'shield-exclamation'}));
  if(m==='not_admin')nodes.push(al('warning',tr('lg_mini_adm_b'),tr('lg_mini_adm_t')));
  if(m==='no_admins')nodes.push(al('warning',tr('lg_mini_noadm_b'),tr('lg_mini_noadm_t')));
  if(m==='no_token')nodes.push(al('warning',tr('lg_mini_notok_b'),tr('lg_mini_notok_t')));
  fill($('mini'),nodes);
}
// ── Всё остальное: язык, вкладки, «войти нечем», подвал ──
function render(){
  document.documentElement.lang=lang;
  document.title=tr('title');
  document.querySelectorAll('[data-t]').forEach((n)=>{n.textContent=tr(n.dataset.t);});
  document.querySelectorAll('[data-tp]').forEach((n)=>{n.placeholder=tr(n.dataset.tp);});
  document.querySelectorAll('[data-ta]').forEach((n)=>{n.setAttribute('aria-label',tr(n.dataset.ta));});
  $('lgHost').textContent=tr('lg_server',{h:location.hostname||'127.0.0.1'});
  const tabs=$('tabs');tabs.replaceChildren();
  if(V===1){const seg=h('div',{class:'gx-seg gx-seg--full',role:'tablist','aria-label':tr('lg_seg_aria')});
    [['tfa','lg_seg_code'],['pwd','lg_seg_pwd']].forEach(([k,key])=>seg.append(h('button',{type:'button',role:'tab','aria-selected':String(tab===k),text:tr(key),onclick:()=>openTab(k)})));
    tabs.append(h('div',{class:'gx-segwrap'},seg));}
  tabs.hidden=V!==1;
  $('tfa').style.display=tab==='tfa'?'':'none';
  $('pwd').style.display=tab==='pwd'?'':'none';
  $('help').style.display=tab==='help'?'':'none';
  if(V===4){const port=PORT;
    $('help').replaceChildren(h('div',{class:'lg-pane'},
      h('div',{class:'gx-empty'},h('span',{class:'gx-empty__ic gx-empty__ic--warning'},svg('lock',24)),h('div',{class:'gx-empty__t',text:tr('lg_noway_t')}),h('div',{class:'gx-empty__x',text:tr('lg_noway_x')})),
      h('div',{class:'gx-stat'},
        statRow(tr('lg_way_tun'),tr('lg_way_tun_s',{p:port}),TUN),
        statRow(tr('lg_way_pwd'),tr('lg_way_pwd_s'),RESET_CMD),
        statRow(tr('lg_way_tok'),tr('lg_way_tok_s'),''))));}
  fill($('note'),NOTICE==='token_net'?[al('warning',tr('lg_tok_net_b'),tr('lg_tok_net_t'),{icon:'shield-exclamation'})]
    :(NOTICE==='token_bad'?[al('warning',tr('lg_tok_bad_b'),tr('lg_tok_bad_t'),{icon:'clock'})]:[]));
  const more=[];
  if(V===2){more.push(h('div',{class:'gx-divider'},h('span',{text:tr('lg_or')})));
    more.push(howto?al('accent',tr('lg_howto_b'),tr('lg_howto_t'),{icon:'circle-question',code:TUN+'\n'+RESET_CMD})
      :h('div',{class:'lg-link'},btn(tr('lg_howto_link'),'ghost',()=>{howto=true;render();},{icon:'circle-question'})));}
  if(V===3)more.push(h('p',{class:'gx-p gx-p--center',text:tr('lg_code_later')}));
  fill($('more'),more);
  $('tunBox').hidden=V===4;
  const ls=h('div',{class:'gx-seg',role:'group','aria-label':tr('lg_lang_aria')});
  [['ru','lg_lang_ru'],['en','lg_lang_en']].forEach(([k,key])=>ls.append(h('button',{type:'button','aria-pressed':String(lang===k),text:tr(key),onclick:()=>{lang=k;try{localStorage.setItem('goamnezia-lang',k);}catch(e){}render();}})));
  $('langSeg').replaceChildren(h('div',{class:'gx-segwrap'},ls));
  renderMini();renderCode();renderPwd();
}
function statRow(title,sub,code){return h('div',{class:'gx-stat__row'},h('span',{class:'gx-stat__m gx-stat__m--accent'},svg('circle-info',14)),
  h('span',{class:'gx-stat__b'},h('span',{class:'gx-stat__t',text:title}),sub?h('span',{class:'gx-stat__s',text:sub}):null,code?h('code',{class:'gx-stat__code',text:code}):null));}
$('req').addEventListener('click',()=>requestCode());
$('go').addEventListener('click',()=>verifyCode());
$('code').addEventListener('input',()=>{const c=$('code');c.value=c.value.replace(/\D/g,'').slice(0,6);if(cs.err&&cs.err.kind==='wrong')cs.err=null;renderCode();if(c.value.length===6)verifyCode();});
$('code').addEventListener('keydown',(e)=>{if(e.key==='Enter')verifyCode();});
$('code').addEventListener('focus',drawSlots);$('code').addEventListener('blur',drawSlots);
$('pgo').addEventListener('click',()=>submitPwd());
['login','pass'].forEach((id)=>{$(id).addEventListener('input',()=>{if(ps.err&&ps.err.kind!=='locked')ps.err=null;renderPwd();});
  $(id).addEventListener('keydown',(e)=>{if(e.key==='Enter')submitPwd();});});
window.addEventListener('resize',()=>{document.documentElement.setAttribute('data-device',matchMedia('(max-width: 699.98px)').matches?'phone':'desktop');});
render();
// Открыли из Telegram — подпись уже есть, спрашивать код незачем; отказ — причиной словами (L-03).
(async()=>{
  const initData=tgInitData();
  if(!initData)return;
  tgPostEvent('web_app_ready');tgPostEvent('web_app_expand');
  try{sessionStorage.setItem('goamnezia-tg-init',initData);}catch(e){}
  miniState='wait';renderMini();
  const r=await post('/api/auth/miniapp',{init_data:initData});
  if(r.ok){miniState='ok';renderMini();location.replace(BASE+'/'+(r.ticket?('?s='+encodeURIComponent(r.ticket)):''));return;}
  miniState=['bad_signature','expired','not_admin','no_admins','no_token'].indexOf(r.reason)!==-1?r.reason:'bad_signature';
  renderMini();
})();
</script></body></html>"""


def _login_server_host(public: bool) -> str:
    """Что подставить в команду туннеля вместо адреса сервера."""
    if public:
        return "SERVER_IP"
    ip = str((read_config() or {}).get("server_ip") or "").strip()
    return ip or "SERVER_IP"


LOGIN_NOTICES = ("token_net", "token_bad")


def render_login_page(lang: str, public: bool = True, notice: str = "") -> bytes:
    """Страница входа. `public` — запрос пришёл из интернета (через домен).

    Адрес сервера в команде туннеля подставляем ТОЛЬКО для запроса с самой
    машины: снаружи страница отдаёт заглушку. Иначе всякий, кто нашёл секретный
    путь, узнавал бы IP сервера — а он может стоять за чужим фронтом, и там это
    единственное, чего он не знает (DEFECTS §4.4).

    `notice` — почему не принят аварийный ключ (LOGIN_NOTICES): страница говорит это первой строкой.
    """
    strings = LOGIN_STRINGS.get(lang, LOGIN_STRINGS["ru"])
    rec = password_record()
    html = LOGIN_PAGE_HTML
    for key, val in strings.items():
        html = html.replace(f"__T_{key}__", val.replace("<", "&lt;"))
    html = (html.replace("__LANG__", lang)
            # Оба словаря — переключатель языка на самой странице меняет надписи без перезагрузки; «</» не
            # закрывает <script> ни при какой строке.
            .replace("__T_ALL__", json.dumps(LOGIN_STRINGS, ensure_ascii=False).replace("</", "<\\/"))
            .replace("__TFA_AVAILABLE__", "true" if tfa_available() else "false")
            .replace("__PWD_SET__", "true" if rec else "false")
            # Имя учётной записи страница входа не называет НИКАК: ни значением
            # поля, ни подсказкой, ни ответом на неудачный вход. Логин — половина
            # пары к паролю, и подставленный он дарил эту половину всякому, кто
            # открыл страницу: подбирать оставалось одно значение вместо двух.
            # Экономия одного поля своему человеку того не стоит — он логин знает.
            .replace("__RESET_CMD__", f"{GOAMNEZIA_DIR}/admin-web/install_admin.sh --reset-password")
            .replace("__ADMIN_PORT__", str(PORT))
            .replace("__SERVER_IP__", _login_server_host(public))
            .replace("__NOTICE__", notice if notice in LOGIN_NOTICES else ""))
    return versioned_assets(html).encode("utf-8")


# ── Статика: версия в адресе, долгий кеш и gzip (PNL-04) ─────────────────────────
# index.html и страница входа ссылались на app.js?v=0.5.0 и styles.css?v=0.5.0 при любой версии продукта, а отдавалось
# всё с no-store: 1,15 МБ app.js — на каждое открытие (живая проверка на 168, 1.0.10). Теперь в адресе — настоящая
# версия файла: версия продукта и начало sha256 содержимого (asset_version). Такой адрес браузер держит год (immutable):
# новая сборка — новый адрес, а сама страница (index.html, вход) — no-store и всегда свежая, поэтому после обновления
# панель берёт новую статику. Без версии или с чужой — no-store, как раньше. app.js, styles.css и страница уходят сжатыми
# (gzip), если клиент их принимает (Accept-Encoding), с Vary: Accept-Encoding.
STATIC_VERSIONED = ("app.js", "styles.css")
STATIC_IMMUTABLE = "public, max-age=31536000, immutable"
STATIC_GZIP_MIN = 1024
STATIC_ASSET_RE = re.compile(r"(\./(app\.js|styles\.css))\?v=[0-9A-Za-z.+_-]*")
_STATIC_FILES: Dict[str, Dict[str, Any]] = {}
_STATIC_FILES_LOCK = threading.Lock()


def static_file(path: Path) -> Optional[Dict[str, Any]]:
    """Файл статики: тело, sha256 и (лениво) сжатое тело — из памяти, пока файл не сменился (отпечаток stat)."""
    try:
        st = path.stat()
    except OSError:
        return None
    stamp = (st.st_mtime_ns, st.st_size, st.st_ino)
    with _STATIC_FILES_LOCK:
        ent = _STATIC_FILES.get(str(path))
        if ent is not None and ent["stamp"] == stamp:
            return ent
    try:
        body = path.read_bytes()
    except OSError:
        return None
    ent = {"stamp": stamp, "body": body, "sha": hashlib.sha256(body).hexdigest(), "gz": None}
    with _STATIC_FILES_LOCK:
        _STATIC_FILES[str(path)] = ent
    return ent


def asset_version(name: str) -> str:
    """Версия файла статики для адреса: «1.0.10-3f2a9c1b0d» — версия продукта и начало sha256 содержимого."""
    ent = static_file(STATIC_DIR / name)
    return f"{detect_version()}-{ent['sha'][:10] if ent else '0'}"


def versioned_assets(html: str) -> str:
    """Адреса app.js и styles.css в странице — с настоящей версией файла (?v=…), какой бы ни стояла в разметке."""
    return STATIC_ASSET_RE.sub(lambda m: f"{m.group(1)}?v={asset_version(m.group(2))}", html)


def accepts_gzip(header: Optional[str]) -> bool:
    """Accept-Encoding клиента разрешает gzip (q > 0; «*» — тоже)."""
    found = None
    for part in str(header or "").split(","):
        token, _, params = part.strip().partition(";")
        token = token.strip().lower()
        if token not in ("gzip", "*"):
            continue
        q = 1.0
        m = re.search(r"\bq\s*=\s*([^;,\s]*)", params)
        if m:
            try:
                q = float(m.group(1))
            except ValueError:
                q = 0.0                     # непонятный вес — не рискуем

        if token == "gzip":
            return q > 0
        found = q > 0
    return bool(found)


def gzip_body(body: bytes) -> bytes:
    return gzip.compress(body, compresslevel=6, mtime=0)


# ════════════════════════════════════════════════════════════════════════════
# HTTP
# ════════════════════════════════════════════════════════════════════════════
TELEGRAM_FRAME_ANCESTORS = "https://web.telegram.org https://*.telegram.org"
CONTENT_SECURITY_POLICY = (
    "default-src 'self'; "
    "base-uri 'none'; "
    "object-src 'none'; "
    f"frame-ancestors {TELEGRAM_FRAME_ANCESTORS}; "
    "form-action 'self'; "
    "img-src 'self' data:; "
    "font-src 'self'; "
    "connect-src 'self'; "
    "style-src 'self' 'unsafe-inline'; "
    # Никаких внешних источников: подпись мини-аппа читается из адреса, а не из
    # SDK с telegram.org. 'unsafe-inline' — ради двух inline-скриптов (тема до
    # первого кадра в index.html и логика страницы входа).
    "script-src 'self' 'unsafe-inline'"
)

SECURITY_HEADERS = (
    ("X-Content-Type-Options", "nosniff"),
    # X-Frame-Options не умеет списки источников и в браузерах перебивает
    # frame-ancestors — с ним мини-апп во фрейме Telegram не откроется.
    # Защиту от кликджекинга целиком несёт CSP выше.
    ("Referrer-Policy", "no-referrer"),
    ("Cross-Origin-Opener-Policy", "same-origin"),
    ("Content-Security-Policy", CONTENT_SECURITY_POLICY),
)

NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
ACTION_NAME_RE = re.compile(r"^[a-z][a-z0-9-]{1,40}$")


# ── Вид панели (шторка «Вид», handoff/README.md §3) ──────────────────────────
# Выбор владельца живёт на сервере: переживает смену браузера, и по нему же рисуются страницы
# подключения и временных ссылок (их открывают другие люди на других устройствах — служба страниц
# читает этот же файл, GOAMNEZIA_DIR/appearance.json). Только белый список: незнакомое поле или
# значение — отказ целиком, а не «запишем, что поняли». Тема «telegram» — только мини-аппа на
# устройстве, на сервер она не попадает.
APPEARANCE_FILE = Path(os.getenv("GOAMNEZIA_APPEARANCE_FILE", str(GOAMNEZIA_DIR / "appearance.json")))
APPEARANCE_ENUMS: Dict[str, Tuple[str, ...]] = {
    "theme": ("light", "dark", "system"),
    "accent": ("ga", "blue", "sky", "lavender", "mint", "coral", "graphite", "custom"),
    "tint": ("neutral", "warm", "cool"), "density": ("min", "balanced", "detailed"), "btn": ("pill", "round"),
    "cards": ("shadow", "border", "flat"), "nav": ("full", "icons", "top"), "fs": ("s", "m", "l"),
}
APPEARANCE_INTS = {"hue": (0, 359), "radius": (0, 16)}
APPEARANCE_BOOLS = ("vibrant", "motion")
APPEARANCE_DEFAULTS: Dict[str, Any] = {"theme": "system", "accent": "ga", "hue": 200, "tint": "neutral",
                                       "density": "detailed", "radius": 8, "btn": "pill", "cards": "shadow",
                                       "nav": "full", "fs": "m", "vibrant": False, "motion": True}


def appearance_clean(raw: Any) -> Optional[Dict[str, Any]]:
    """Вид из запроса или файла → полный словарь известных полей; хоть что-то не так — None."""
    if not isinstance(raw, dict) or len(raw) > 32:
        return None
    out = dict(APPEARANCE_DEFAULTS)
    for key, value in raw.items():
        if key in APPEARANCE_ENUMS:
            if value not in APPEARANCE_ENUMS[key]:
                return None
        elif key in APPEARANCE_INTS:
            lo, hi = APPEARANCE_INTS[key]
            if isinstance(value, bool) or not isinstance(value, int) or not lo <= value <= hi:
                return None
        elif key in APPEARANCE_BOOLS:
            if not isinstance(value, bool):
                return None
        else:
            return None
        out[key] = value
    return out


def appearance_read() -> Optional[Dict[str, Any]]:
    """Сохранённый вид или None (не выбирали, файла нет, файл испорчен — панель тогда в умолчаниях)."""
    try:
        data = json.loads(APPEARANCE_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return appearance_clean(data.get("appearance")) if isinstance(data, dict) else None


def appearance_write(ap: Dict[str, Any]) -> None:
    """Атомарно: временный файл → rename. 0644 — служба страниц читает его без прав панели."""
    try:
        APPEARANCE_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = APPEARANCE_FILE.with_name(APPEARANCE_FILE.name + ".tmp")
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"schema": 1, "appearance": ap, "updated": utc_now()}, fh, ensure_ascii=False)
            fh.write("\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, APPEARANCE_FILE)
    except OSError as exc:
        raise ActionError("appearance_write_failed", f"не удалось записать {APPEARANCE_FILE}: {exc}", 500)


class AdminHandler(BaseHTTPRequestHandler):
    timeout = 15
    server_version = f"goAmneziaProAdmin/{detect_version()}"
    # Заголовок сессии, если guard_request только что её завёл. Ставится в
    # ОБОИХ путях ответа: страница уходит через send_static, а первый запрос
    # данных — через send_json; пропусти мы один — cookie не появилась бы
    # ровно в половине случаев.
    _issue_session: Optional[str] = None
    _who: str = "panel"

    def log_message(self, fmt: str, *args: Any) -> None:
        # journald собирал десятки тысяч строк в сутки от автообновления.
        if ACCESS_LOG:
            print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def handle_one_request(self) -> None:
        self._security_headers_sent = False
        self._issue_session = None
        self._who = "panel"
        super().handle_one_request()

    def end_headers(self) -> None:
        if not getattr(self, "_security_headers_sent", False):
            self._security_headers_sent = True
            for name, value in SECURITY_HEADERS:
                self.send_header(name, value)
        super().end_headers()

    def _session_cookie(self, tok: str, same_site: str = "Strict", max_age: Optional[int] = None) -> str:
        """Строка Set-Cookie для сессии.

        Max-Age обязан пережить окно продления: истеки cookie ровно в 15 минут,
        браузер выбросил бы её именно тогда, когда она нужна для продления.

        Secure ставим там, где соединение и правда по TLS, то есть когда панель
        открыта с домена через nginx. Через SSH-туннель это обычный
        http://127.0.0.1: стоит пробросить туннель на другое имя — и Secure-
        cookie молча пропадает, а вход выглядит как «панель меня не запоминает».

        Исключение — SameSite=None: спецификация требует к нему Secure всегда.
        Так ходит только мини-апп, а он всегда открыт по HTTPS с домена.
        """
        secure = "; Secure" if (same_site == "None" or self.is_public_request()) else ""
        age = max_age if max_age is not None else SESSION_TTL + SESSION_GRACE + SESSION_COOKIE_SLACK
        return (f"{SESSION_COOKIE}={tok}; Path=/; Max-Age={age}; HttpOnly{secure}; SameSite={same_site}")

    def _maybe_set_session_cookie(self) -> None:
        tok = getattr(self, "_issue_session", None)
        if not tok:
            return
        self._issue_session = None
        self.send_header("Set-Cookie", self._session_cookie(tok))

    def _write_body(self, body: bytes) -> None:
        """Тело ответа — но для HEAD ни байта (RFC 9110 §9.3.2).

        Без do_HEAD базовый BaseHTTPRequestHandler отвечал на HEAD кодом 501, и
        секретный путь панели отличался от любого другого пути домена: у
        сайта-маскировки HEAD даёт 200/404, у панели — 501 со своими
        заголовками. Тому, кто перебирает пути, это готовый указатель «здесь
        панель», а весь замысел Pro в том, чтобы панель ничем не выделялась.
        Заголовки (включая Content-Length) остаются как у GET — так требует RFC.
        """
        if getattr(self, "_is_head", False):
            return
        self.wfile.write(body)

    def send_json(self, payload: Any, status: int = 200, extra_headers: Optional[List[Tuple[str, str]]] = None) -> None:
        try:
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        except UnicodeEncodeError:
            # В ответ вернулся кусок запроса с одиноким суррогатом («лишний параметр: \ud800»): в UTF-8 он не
            # кодируется, и ответа не было вовсе — обрыв соединения. Экранами \uXXXX это законный JSON.
            body = json.dumps(payload, ensure_ascii=True).encode("ascii")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self._maybe_set_session_cookie()
        for name, value in (extra_headers or []):
            self.send_header(name, value)
        # Как ответ собран (общий снимок): «traffic=hit,user-list=miss» — для замеров и разбора «почему медленно».
        reads = getattr(_CALL_CTX, "reads", None)
        if isinstance(reads, dict) and reads:
            self.send_header("X-GoAmnezia-Snapshot", ",".join(f"{k}={v.get('how', 'hit')}" for k, v in sorted(reads.items())))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self._write_body(body)

    def send_bytes(self, body: bytes, content_type: str, status: int = 200,
                   extra_headers: Optional[List[Tuple[str, str]]] = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self._maybe_set_session_cookie()
        for name, value in (extra_headers or []):
            self.send_header(name, value)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self._write_body(body)

    def send_error_json(self, status: int, message: str, code: str = "") -> None:
        payload: Dict[str, Any] = {"ok": False, "error": message}
        if code:
            payload["code"] = code
        self.send_json(payload, status)

    def send_auth_error(self, status: int, message: "AuthText", **more: Any) -> None:
        """Отказ маршрута входа: `error` на языке панели, как прежде, плюс `code` и `texts{ru, en}` (auth_fields).
        Статус и логика — прежние: меняется только состав ответа (решение владельца В4)."""
        self.send_json({"ok": False, "error": str(message), **auth_fields(message), **more}, status)

    def send_bridge(self, r: Dict[str, Any]) -> None:
        """Ответ моста → ответ панели: success → data, error → error+code."""
        if bridge_ok(r):
            self.send_json({"ok": True, "data": r})
        else:
            self.send_json({"ok": False, "error": str(r.get("message") or r.get("code") or "error"),
                            "code": str(r.get("code") or "error"), "data": r}, bridge_http_status(r))

    def read_json_body(self) -> Any:
        # Кривое тело — обычный ввод из интернета, а не сбой сервера: иначе
        # JSONDecodeError рвал соединение, и nginx отдавал наружу 502.
        length_raw = self.headers.get("Content-Length", "0") or "0"
        try:
            length = int(length_raw)
        except (TypeError, ValueError):
            raise BadRequest("bad Content-Length")
        if length > 1024 * 1024:
            raise BadRequest("request body too large")
        if length <= 0:
            return {}
        try:
            raw = self.rfile.read(length)
        except OSError:
            raise BadRequest("body read failed")
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise BadRequest("malformed JSON body")
        # Валидный JSON, но не объект (null/список/строка) ронял body.get() в 500.
        if not isinstance(data, dict):
            raise BadRequest("JSON body must be an object")
        return data

    def require_write_guard(self) -> bool:
        if self.command in {"POST", "PUT", "PATCH", "DELETE"} and self.headers.get(WRITE_GUARD_HEADER) != "1":
            self.send_error_json(403, "missing write guard")
            return False
        return True

    def host_allowed(self) -> bool:
        raw = (self.headers.get("Host") or "").strip()
        if not raw:
            # Браузеры Host шлют всегда; голый HTTP/1.0 инструмент может и не прислать.
            return True
        return host_name_only(raw) in ALLOWED_HOSTS

    def request_token(self, parsed: urllib.parse.ParseResult) -> str:
        header = (self.headers.get(ADMIN_TOKEN_HEADER) or "").strip()
        if header:
            return header
        try:
            values = urllib.parse.parse_qs(parsed.query).get(ADMIN_TOKEN_PARAM) or []
        except Exception:
            return ""
        return values[0].strip() if values else ""

    def refuse_token(self, parsed: urllib.parse.ParseResult, kind: str) -> bool:
        """Отказ аварийному ключу словами: kind — net (пришёл с домена) | bad (не подошёл: нет, истёк, сгорел).
        Браузеру — страница входа с объяснением наверху, API — 401 с кодом и текстами на двух языках."""
        if self.command == "GET" and not parsed.path.startswith("/api/"):
            self.send_login_page(notice=f"token_{kind}")
        elif kind == "net":
            self.send_auth_error(401, auth_text("token_tunnel_only", "tok_net"), state="none", seconds=0)
        else:
            self.send_auth_error(401, auth_text("token_invalid", "tok_bad"), state="none", seconds=0)
        return False

    def miniapp_ok(self) -> bool:
        """Вход из Telegram Mini App: подпись вместо токена панели."""
        raw = (self.headers.get(MINIAPP_INITDATA_HEADER) or "").strip()
        if not raw:
            return False
        uid = verify_telegram_init_data(raw)
        if uid:
            self._who = f"tg:{uid}"
            return True
        return False

    def request_session(self) -> str:
        raw = self.headers.get("Cookie") or ""
        for part in raw.split(";"):
            name, _, value = part.strip().partition("=")
            if name == SESSION_COOKIE:
                return value.strip()
        return ""

    def is_public_request(self) -> bool:
        return public_request(self.headers)

    def client_ip(self) -> str:
        """Адрес запроса. По нему ведутся корзины перебора пароля и кода входа, поэтому
        важно, ЧЕЙ это адрес.

        X-Real-IP ставит nginx директивой proxy_set_header, которая ПЕРЕЗАПИСЫВАЕТ
        присланное клиентом, — и заголовок служит доказательством ровно там, где впереди
        стоит свой nginx: на петлевом слушателе. Но панель можно поднять и не на петле
        (GOAMNEZIA_ADMIN_HOST переопределяется), и тогда заголовок целиком клиентский:
        верить ему значило бы дать стучащемуся самому выбирать себе корзину перебора —
        новую и чистую на каждый запрос, а чужие адреса запирать чужими банами. Правило
        то же, что у MCP-сервера (goamnezia-mcp/server.py, McpHttpHandler.client_ip).
        """
        peer = self.client_address[0] if self.client_address else ""
        if peer not in LOOPBACK_PEERS:
            return peer or "?"
        fwd = (self.headers.get("X-Real-IP") or "").strip()
        if fwd:
            try:
                return str(ipaddress.ip_address(fwd))
            except ValueError:
                pass                    # не адрес, а мусор: корзиной ему быть незачем
        return peer or "?"

    def is_local_console(self) -> bool:
        peer = self.client_address[0] if self.client_address else ""
        return local_console(self.headers, peer)

    def guard_request(self, parsed: urllib.parse.ParseResult) -> bool:
        if not self.host_allowed():
            self.send_error_json(403, "host not allowed")
            return False
        # Вход по коду: сами эти маршруты обязаны быть открыты, иначе войти
        # невозможно в принципе.
        # /api/auth/password открыт по той же причине, что и вход по коду: это
        # и есть вход. А /api/auth/password/change — НЕ открыт: пароль меняет
        # тот, кто уже внутри, и знание текущего пароля здесь второй рубеж, а
        # не первый.
        if parsed.path in {"/api/auth/request", "/api/auth/verify", "/api/auth/miniapp",
                           "/api/auth/password", "/api/auth/logout", "/api/session",
                           "/login", "/login.html"}:
            return True
        if self.command == "GET" and parsed.path in PUBLIC_STATIC_PATHS:
            return True
        # Билет из адреса: единственный способ открыть панель, если браузер
        # режет сторонние cookie внутри фрейма Telegram. Гасим его ДО проверки
        # cookie: билет оседает в access-log nginx, и непогашенным он оставался
        # бы там рабочим пропуском.
        if self.command == "GET" and not parsed.path.startswith("/api/"):
            _q = urllib.parse.parse_qs(parsed.query or "")
            _ticket = (_q.get("s") or [""])[0].strip()
            if _ticket and ticket_redeem(_ticket):
                self._who = "tg"
                return True
        sess = self.request_session()
        if session_valid(sess):
            self._who = session_who(sess) or "session"
            return True
        if self.miniapp_ok():
            return True
        # Аварийный ключ (SEC50-08): только по SSH-туннелю, только с meta и сроком, сгорает при входе. С домена —
        # отказ словами, даже верному ключу: на домене входят паролем или кодом из бота.
        provided = self.request_token(parsed)
        if provided:
            origin = "tunnel" if self.is_local_console() else "net"
            if origin == "net":
                audit("login", "auth-token", {"origin": origin}, "denied", "token_tunnel_only")
                return self.refuse_token(parsed, "net")
            ok, why = emergency_token_redeem(provided)
            if ok:
                audit("login", "auth-token", {"origin": origin}, "success")
                self._who = "token"
                if not session_valid(sess):
                    self._issue_session = session_create("token")
                return True
            audit("login", "auth-token", {"origin": origin}, "denied", why)
            # Туннелю, которому доверяют и без кода, негодный ключ не помеха: он и так вправе войти.
            if not TRUST_LOCAL_CONSOLE:
                return self.refuse_token(parsed, "bad")
        # Вход через localhost — без второго фактора. Право на сервер уже
        # доказано входом по SSH: туннель `ssh -L 1985:127.0.0.1:1985` не
        # построить, не имея доступа к машине, где и так лежат все ключи и
        # настройки. Требовать сверх этого код — просить доказать доказанное; при
        # ненастроенном боте это к тому же запирало бы панель совсем.
        # Публичного входа с домена это не касается: там по-прежнему нужен код.
        if TRUST_LOCAL_CONSOLE and self.is_local_console():
            self._who = "tunnel"
            # Сессию заводим только на загрузке страницы, а не на любом запросе:
            # клиент, игнорирующий cookie (curl в цикле), иначе плодил бы по
            # записи в _SESSIONS на КАЖДЫЙ запрос. Доступа это не меняет; сессия
            # нужна лишь чтобы интерфейс показывал осмысленный остаток времени.
            if (self.command == "GET" and not parsed.path.startswith("/api/")
                    and not session_valid(sess)):
                self._issue_session = session_create("tunnel")
            return True
        # Браузеру отдаём страницу входа, а не голый 401: иначе человек
        # видит пустоту и не понимает, что делать.
        if self.command == "GET" and not parsed.path.startswith("/api/"):
            self.send_login_page()
            return False
        # Причину отказа обязан различать интерфейс: «продлите» и
        # «входите заново» — разные экраны.
        # state — по-прежнему главное для интерфейса; code и texts — чтобы экран входа сказал это на своём языке.
        st, left = session_state(sess)
        if st == "renew":
            self.send_auth_error(401, auth_text("session_renew", "sess_renew"), state="renew", seconds=left)
        elif st == "dead" and sess:
            self.send_auth_error(401, auth_text("session_expired", "sess_expired"), state="expired", seconds=0)
        else:
            self.send_auth_error(401, auth_text("auth_required", "auth_required"), state="none", seconds=0)
        return False

    def send_login_page(self, notice: str = "") -> None:
        body = render_login_page(read_language(), public=self.is_public_request(), notice=notice)
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self._write_body(body)

    # ── вход и смена пароля ───────────────────────────────────────────────
    def _pwd_origin(self) -> str:
        return "net" if self.is_public_request() else "tunnel"

    def _pwd_refuse_blocked(self, wait: int, audit_action: str = "", audit_who: str = "login") -> None:
        """429 «слишком много попыток» — не быстрее обычной попытки: мгновенный отказ сам
        сообщал бы перебирающему, что он нащупал предел и пора менять адрес."""
        _password_pace(time.monotonic())
        if audit_action:
            audit(audit_who, audit_action, {"method": "password", "origin": self._pwd_origin()},
                  "denied", "too_many_attempts")
        self.send_auth_error(429, auth_text("too_many_attempts", "pwd_blocked", {"seconds": wait},
                                            n=max(1, (wait + 59) // 60)))

    def route_password_login(self) -> None:
        """Вход по логину и паролю. Открыт всегда: когда бота нет, это
        единственный вход с домена, когда есть — равноправный запасной."""
        body = self.read_json_body() or {}
        login = str(body.get("login") or "")[:64]
        password = str(body.get("password") or "")[:PASSWORD_MAX_LEN + 1]
        bucket = _pwd_bucket(self.client_ip())
        origin = self._pwd_origin()
        blocked, wait = password_blocked(bucket)
        if blocked:
            self._pwd_refuse_blocked(wait, "auth-password")
            return
        if not password_configured():
            self.send_auth_error(409, auth_text("password_unset", "pwd_none"))
            return
        # Место в корзине — до проверки и одним шагом с проверкой предела: подсмотреть выше
        # и записать после проверки значило бы пустить параллельную пачку запросов разом.
        allowed, wait, left = password_attempt_begin(bucket)
        if not allowed:
            self._pwd_refuse_blocked(wait, "auth-password")
            return
        if not password_check(login, password):
            # Ни логина, ни пароля в журнале: адрес и факт — всё, что нужно,
            # чтобы увидеть перебор, и всё, что можно оставлять на диске.
            sys.stderr.write(f"вход по паролю: неудачная попытка ({origin}, {self.client_ip()}), "
                             f"осталось попыток: {left}\n")
            audit("login", "auth-password", {"method": "password", "origin": origin, "left": left},
                  "denied", "bad_credentials")
            self.send_auth_error(401, auth_text("bad_credentials", "pwd_wrong"))
            return
        password_attempts_clear(bucket)
        sys.stderr.write(f"вход по паролю: успешный вход ({origin}, {self.client_ip()})\n")
        audit("login", "auth-password", {"method": "password", "origin": origin}, "success")
        old = self.request_session()
        if old:
            session_drop(old)
        token = session_create("password")
        self.send_json({"ok": True}, extra_headers=[("Set-Cookie", self._session_cookie(token))])

    def route_password_change(self) -> None:
        """Смена пароля из панели: маршрут за стражей, текущий пароль — второй
        рубеж. Пока пароля нет вовсе (обновление со старой установки), текущий
        спрашивать не с чего: право доказано тем, как человек сюда попал."""
        s = login_strings()
        body = self.read_json_body() or {}
        current = str(body.get("current") or "")[:PASSWORD_MAX_LEN + 1]
        new_password = str(body.get("new") or "")[:PASSWORD_MAX_LEN + 1]
        rec = password_record()
        bucket = _pwd_bucket(self.client_ip())
        if rec:
            # Та же атомарная корзина, что у входа: текущий пароль здесь перебирается так же.
            allowed, wait, left = password_attempt_begin(bucket)
            if not allowed:
                self._pwd_refuse_blocked(wait)
                return
            if not password_check(str(rec.get("login") or ""), current):
                audit(self._who, "auth-password-change", {"origin": self._pwd_origin(), "left": left},
                      "denied", "bad_credentials")
                self.send_auth_error(401, auth_text("bad_credentials", "pwd_bad_current"))
                return
            password_attempts_clear(bucket)
        if not PASSWORD_MIN_LEN <= len(new_password) <= PASSWORD_MAX_LEN:
            self.send_auth_error(400, auth_text("bad_password", "pwd_short", n=PASSWORD_MIN_LEN))
            return
        # Логин из панели не меняется: смена имени — дело установщика
        # (--login=), и путать её со сменой пароля незачем.
        login = str(rec.get("login") or "") if rec else PASSWORD_LOGIN_DEFAULT
        try:
            password_set(login, new_password)
        except ActionError as exc:
            # Тот же код и статус, что прежде давал общий предохранитель (_safe), но с текстами на двух языках.
            # Причина — в исходном исключении: пароль не кодируется (одинокий суррогат) или файл не записался.
            if exc.code == "bad_password" and isinstance(exc.__context__, UnicodeEncodeError):
                self.send_auth_error(exc.status, auth_text("bad_password", "pwd_bad_chars"))
            elif exc.code == "password_write_failed":
                self.send_auth_error(exc.status, auth_text("password_write_failed", "pwd_write_failed",
                                                           file=str(PASSWORD_FILE), why=str(exc.__context__ or "")))
            else:
                raise
            return
        audit(self._who, "auth-password-change", {"origin": self._pwd_origin()}, "success")
        sys.stderr.write(f"пароль панели изменён из интерфейса ({self._pwd_origin()})\n")
        self.send_json({"ok": True, "data": {"login": login, "message": s["pwd_changed"]}})

    # ── GET /api/… ────────────────────────────────────────────────────────
    def route_get_api(self, parsed: urllib.parse.ParseResult) -> None:
        path = parsed.path
        q = urllib.parse.parse_qs(parsed.query or "")

        def qv(name: str, default: str = "") -> str:
            return (q.get(name) or [default])[0].strip()

        who = self._who
        if path == "/api/session":
            # Клиент спрашивает про сессию сам, не дожидаясь первой неудачи:
            # иначе окно продления в 60 секунд человек замечает по сломанной
            # кнопке. Для входа через localhost сессия НЕ является пропуском —
            # отвечаем состоянием ДОСТУПА, а оно у локального клиента всегда «ok»,
            # иначе фронтенд через 15 минут закрыл бы рабочую панель окном «продлите».
            if TRUST_LOCAL_CONSOLE and self.is_local_console():
                st, left, who = "ok", SESSION_TTL, "tunnel"
            else:
                st, left = session_state(self.request_session())
                who = session_who(self.request_session()) if st == "ok" else ""
            self.send_json({"ok": True, "data": {
                "state": st, "seconds": left, "ttl": SESSION_TTL, "grace": SESSION_GRACE,
                "tfa": tfa_available(), "lang": read_language(), "version": detect_version(),
                # Есть ли пароль — интерфейс по этому решает, что показывать в
                # окне входа: форму пароля, кнопку кода или оба способа.
                "password": password_configured(),
                # who — как вошли (tunnel|code|token|tg:<id>): интерфейс по нему
                # решает, показывать ли «Выйти» (туннелю выходить некуда).
                "who": who,
            }})
            return
        if path == "/api/appearance":
            # Вид панели для шторки «Вид»: null — владелец ещё не выбирал, панель в умолчаниях.
            self.send_json({"ok": True, "data": {"appearance": appearance_read(), "defaults": APPEARANCE_DEFAULTS}})
            return
        if path == "/api/overview":
            self.send_json({"ok": True, "data": overview_payload(who)})
            return
        if path == "/api/users":
            self.send_json({"ok": True, "data": users_payload(who)})
            return
        m = re.fullmatch(r"/api/users/([^/]+)(?:/(key|conf))?", path)
        if m:
            name = urllib.parse.unquote(m.group(1))
            if not NAME_RE.match(name):
                self.send_error_json(400, "bad user name", "bad_arg")
                return
            sub = m.group(2)
            if not sub:
                status, payload = user_card_payload(who, name)
                self.send_json(payload, status)
                return
            profile = qv("profile")
            # Разовый адрес сервера в Endpoint (?endpoint=<host>): в мост уходит только
            # непустой — без него вызов байт в байт прежний. Форму проверяет validate_params
            # (тип key_endpoint), список допустимых хостов — мост: address_not_here,
            # invalid_ip, addresses_unknown приходят в браузер 4xx с его же словами.
            endpoint = qv("endpoint")
            kparams = {"name": name, "profile": profile}
            if endpoint:
                kparams["endpoint"] = endpoint
            if sub == "key":
                fmt = qv("format", "all")
                try:
                    r = run_action("user-key", dict(kparams, format=fmt), who)
                except ActionError as exc:
                    self.send_error_json(exc.status, str(exc), exc.code)
                    return
                self.send_bridge(r)
                return
            # /conf — скачивание файла: единственный ответ панели не в JSON.
            try:
                r = run_action("user-key", dict(kparams, format="conf"), who)
            except ActionError as exc:
                self.send_error_json(exc.status, str(exc), exc.code)
                return
            if not bridge_ok(r) or not r.get("conf"):
                self.send_bridge(r if not bridge_ok(r) else {"status": "error", "code": "key_failed", "message": "empty conf"})
                return
            # Имя файла — из ответа ядра (file_name, П-1): то же, что у «Скачать .conf» в панели, страницы, подписки,
            # бота и SSH (anna-2_0.conf, до .conf не длиннее 15 знаков — AmneziaWG берёт из него имя туннеля); с разовым
            # адресом — то же имя. Ядро старше поля или негодное значение — прежнее <имя>-<профиль>[-<хост>].conf.
            fname = str(r.get("file_name") or "")
            if not KEY_FILE_NAME_RE.fullmatch(fname):
                fname = f"{name}-{profile}.conf"
                # safe_key_host и у запрошенного: значение уходит в заголовок, кавычке там не место.
                host = (safe_key_host(r.get("key_host")) or safe_key_host(endpoint)) if endpoint else ""
                if host:
                    fname = f"{name}-{profile}-{host}.conf"
            self.send_bytes(str(r["conf"]).encode("utf-8"), "text/plain; charset=utf-8",
                            extra_headers=[("Content-Disposition", f'attachment; filename="{fname}"')])
            return
        if path == "/api/profiles":
            self.send_json({"ok": True, "data": profiles_payload(who)})
            return
        m = re.fullmatch(r"/api/profiles/([a-z0-9]{1,16})/reline-preview", path)
        if m:
            if not PROFILE_ID_RE.fullmatch(m.group(1)):
                self.send_error_json(400, "bad profile", "bad_arg")
                return
            self.send_json({"ok": True, "data": reline_preview_payload(who, m.group(1))})
            return
        m = re.fullmatch(r"/api/profiles/([a-z0-9]{1,16})/params", path)
        if m:
            try:
                status, payload = profile_params_payload(who, m.group(1))
            except ActionError as exc:
                status, payload = exc.status, {"ok": False, "error": str(exc), "code": exc.code}
            self.send_json(payload, status)
            return
        if path == "/api/traffic":
            # ?wait=0 — Обзор: свежий сбор не ждём (PERF-03); раздел «Трафик» — без параметра, ждёт.
            self.send_json({"ok": True, "data": traffic_payload(who, wait=qv("wait", "1") != "0")})
            return
        if path == "/api/backups":
            self.send_json({"ok": True, "data": backups_payload(who)})
            return
        if path == "/api/logs/status":
            # Размеры и бюджет — рядом с логами, а не в диагностике: решение
            # «чистить или нет» принимают, глядя на сам журнал.
            self.send_json({"ok": True, "data": logs_status_payload(who)})
            return
        if path == "/api/logs":
            status, payload = logs_payload(who, qv("component", "system"), qv("lines", "100"))
            self.send_json(payload, status)
            return
        if path == "/api/preflight":
            self.send_json({"ok": True, "data": preflight_payload(who)})
            return
        if path == "/api/share":
            # Список раздач без секретной части адреса; сам адрес возвращает
            # только POST /api/action/share-create тому, кто его попросил.
            self.send_json({"ok": True, "data": share_payload(who)})
            return
        if path == "/api/pages":
            # Страницы подключения без адресов; адрес отдаёт только POST
            # /api/action/page-create и page-url — тому, кто нажал.
            name = qv("name")
            if name and not NAME_RE.match(name):
                self.send_error_json(400, "bad user name", "bad_arg")
                return
            self.send_json({"ok": True, "data": pages_payload(who, name)})
            return
        if path == "/api/mirror":
            self.send_json({"ok": True, "data": mirror_payload(who)})
            return
        if path == "/api/clients":
            self.send_json({"ok": True, "data": clients_payload(who)})
            return
        if path == "/api/settings":
            self.send_json({"ok": True, "data": settings_payload(who)})
            return
        if path == "/api/quality":
            self.send_json({"ok": True, "data": quality_payload(who)})
            return
        if path == "/api/agents":
            self.send_json({"ok": True, "data": agents_payload(who)})
            return
        if path == "/api/upstream":
            self.send_json({"ok": True, "data": upstream_payload(who)})
            return
        if path == "/api/import":
            self.send_json({"ok": True, "data": import_payload(who)})
            return
        if path == "/api/kmod":
            # Ускорение AmneziaWG: состояние модуля и действие панели в фоне (ход или итог) — карточка на «Протоколах».
            self.send_json({"ok": True, "data": kmod_panel_payload(who)})
            return
        if path == "/api/actions":
            self.send_json({"ok": True, "data": actions_payload()})
            return
        if path == "/api/site/templates":
            cat_id = qv("cat")
            if cat_id and not re.fullmatch(r"[a-z0-9_-]{1,40}", cat_id):
                self.send_error_json(400, "bad category", "bad_arg")
                return
            query = re.sub(r"[^\w .-]", "", qv("q"))[:64]
            try:
                page = max(0, int(qv("page", "0")))
            except ValueError:
                page = 0
            self.send_json({"ok": True, "data": templates_payload(cat_id, query, page)})
            return
        if path == "/api/site/template":
            self.send_json({"ok": True, "data": current_template_payload()})
            return
        self.send_error_json(404, "unknown api route")

    # ── POST /api/… ───────────────────────────────────────────────────────
    def route_post_api(self, parsed: urllib.parse.ParseResult) -> None:
        # Предохранитель от CSRF стоит ПЕРЕД всеми ветками, включая /api/auth/*:
        # заголовок X-GoAmnezia-Admin — единственное, что отличает запрос нашего
        # фронтенда от кросс-сайтового, а POST с Content-Type: text/plain уходит
        # без префлайта. Чужая страница иначе дёргала бы /api/auth/request и
        # слала админу код от его же панели, выжигая часовую квоту.
        if not self.require_write_guard():
            return
        if parsed.path == "/api/auth/request":
            _tok = self.request_session()
            _renew = session_state(_tok)[0] in {"ok", "renew"}
            ok, message, why = tfa_request(self.client_ip(), public=self.is_public_request(),
                                           renew=_renew, session_token=_tok if _renew else "")
            # 429 значит «слишком часто» и только это. «Бот не настроен» — 503,
            # «администратор не нажимал Start» — 409, «Telegram не принял» — 502.
            # У отказа — ещё texts{ru, en} и reason/seconds (auth_fields); code — прежний why.
            self.send_json({"ok": ok, "error": None if ok else str(message),
                            "message": message if ok else None,
                            **({} if ok else auth_fields(message)),
                            "code": why or None},
                           status=200 if ok else TFA_HTTP_STATUS.get(why, 429))
            return
        if parsed.path == "/api/auth/miniapp":
            # Обычный переход по ссылке не несёт заголовков, поэтому при
            # открытии из Telegram сервер видел бы безымянного гостя и отдавал
            # форму с кодом. Здесь страница присылает подпись явно и получает
            # сессионную cookie, дальше всё как после ввода кода.
            body = self.read_json_body() or {}
            raw = str(body.get("init_data") or "").strip()
            uid, why = telegram_init_data_check(raw) if raw else (None, "bad_signature")
            if not uid:
                # Причина — машинным кодом и словами на обоих языках (L-03); reason — само слово причины.
                code, key = MINIAPP_DENY.get(why, MINIAPP_DENY["bad_signature"])
                self.send_auth_error(401, auth_text(code, key, extra={"reason": why}))
                return
            sys.stderr.write(f"2FA: успешный вход из мини-аппа, telegram_id={uid}\n")
            token = session_create(f"tg:{uid}")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            # SameSite=Strict внутри фрейма Telegram не отдаётся — для браузера
            # это сторонний контекст. Для мини-аппа кладём None+Secure, а если
            # браузер режет сторонние cookie вовсе — страница получает ещё и
            # одноразовый билет в адресе.
            self.send_header("Set-Cookie", self._session_cookie(token, same_site="None"))
            payload = json.dumps({"ok": True, "ticket": ticket_create()}).encode()
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self._write_body(payload)
            return
        if parsed.path == "/api/auth/verify":
            body = self.read_json_body() or {}
            # Код ищется только в своих корзинах: адрес этого запроса и продление этой же вкладки.
            ok, message = tfa_verify(str(body.get("code", "")), self.client_ip(),
                                     public=self.is_public_request(), session_token=self.request_session())
            # Журнал входов: и успех, и неудача — след в stderr (journald). Сам код не пишем никогда.
            origin = "из интернета" if self.is_public_request() else "по туннелю"
            if not ok:
                sys.stderr.write(f"2FA: неудачная попытка входа {origin} ({self.client_ip()}): {message}\n")
                self.send_auth_error(401, message)
                return
            sys.stderr.write(f"2FA: успешный вход по коду {origin} ({self.client_ip()})\n")
            old = self.request_session()
            if old:
                session_drop(old)
            token = session_create("code")
            self.send_json({"ok": True}, extra_headers=[("Set-Cookie", self._session_cookie(token))])
            return
        if parsed.path == "/api/auth/password":
            self.route_password_login()
            return
        if parsed.path == "/api/auth/password/change":
            self.route_password_change()
            return
        if parsed.path == "/api/auth/logout":
            tok = self.request_session()
            if tok:
                session_drop(tok)
            self.send_json({"ok": True}, extra_headers=[("Set-Cookie", self._session_cookie("", max_age=0))])
            return
        if parsed.path == "/api/appearance":
            body = self.read_json_body() or {}
            ap = appearance_clean(body.get("appearance"))
            if ap is None:
                self.send_error_json(400, "appearance: unknown field or value", "bad_appearance")
                return
            appearance_write(ap)
            audit(self._who or "panel", "appearance-set", {k: ap[k] for k in ("theme", "accent", "density")}, "ok")
            self.send_json({"ok": True, "data": {"appearance": ap}})
            return
        m = re.fullmatch(r"/api/kmod/([a-z]{2,16})", parsed.path)
        if m:
            # Ускорение AmneziaWG: действие с модулем ядра в фоне (kmod_job_start) — ответ сразу, ход — GET /api/kmod.
            body = self.read_json_body() or {}
            status, payload = kmod_job_start(m.group(1), self._who, body.get("confirm"), body.get("headers_meta"))
            self.send_json(payload, status)
            return
        m = re.fullmatch(r"/api/action/([a-z0-9-]{2,40})", parsed.path)
        if m:
            name = m.group(1)
            if not ACTION_NAME_RE.match(name) or action_spec(name) is None:
                self.send_error_json(404, f"неизвестное действие: {name}", "unknown_action")
                return
            body = self.read_json_body() or {}
            # Своё подтверждение действия (users-del-bulk: confirm — число людей) остаётся параметром моста
            confirm = body.get("confirm") if action_own_confirm(name) else body.pop("confirm", None)
            try:
                # Ключ человека (user-attach-key) вынимается из тела ДО сборки argv и уходит мосту
                # только в stdin: в аудит и журнал панели попадают имя и профиль, но не он.
                sp = stdin_param(name)
                stdin_data = stdin_payload(body.pop(sp, None)) if sp else None
                params = short_params(name, {k: v for k, v in body.items() if isinstance(k, str)})
                # «Ждут подтверждения» — без моста, модулем ядра в этом процессе (PERF-02); не вышло — мостом
                local = short_pending_local() if name == "short-pending" and not params and stdin_data is None else None
                if local is not None:
                    audit(self._who, name, {}, "success", "")
                    self.send_json({"ok": True, "data": local})
                    return
                r = run_action(name, params, self._who, confirm=None if confirm is None else str(confirm),
                               use_cache=False, stdin_data=stdin_data)
            except ActionError as exc:
                self.send_error_json(exc.status, str(exc), exc.code)
                return
            if short_outcome_answer(name, r):
                # Итог запроса короткой ссылки (ok, wrong, … и pending) — ответ, а не отказ моста (договор: полем status)
                self.send_json({"ok": True, "data": r})
                return
            self.send_bridge(attach_page_qr(name, r))
            return
        self.send_error_json(404, "unknown api route")

    # ── статика ───────────────────────────────────────────────────────────
    def send_static(self, parsed: urllib.parse.ParseResult) -> None:
        rel = parsed.path.lstrip("/") or "index.html"
        if rel.startswith("api/") or ".." in rel.split("/"):
            self.send_error(404)
            return
        try:
            base = STATIC_DIR.resolve()
            path = (base / rel).resolve()
        except (OSError, RuntimeError):
            self.send_error(404)
            return
        if path != base and not path.is_relative_to(base):
            self.send_error(404)
            return
        if path.is_dir():
            path = path / "index.html"
        if rel == "favicon.ico" and not path.exists():
            # Иконки в поставке нет; пустой ответ тише, чем 404 в консоли браузера.
            self.send_response(204)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return
        if not path.exists() or not path.is_file():
            # Никакого SPA-фолбэка на index.html: страницы ходят по #hash, а
            # неизвестный путь — это 404, не тихая выдача панели.
            self.send_error(404)
            return
        ent = static_file(path)
        if ent is None:
            self.send_error(404)
            return
        name = path.relative_to(base).as_posix()
        body = ent["body"]
        mime = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
        if mime.startswith("text/") or mime in {"application/javascript", "application/json"}:
            mime += "; charset=utf-8"
        compressible = mime.startswith(("text/", "application/javascript", "application/json", "image/svg+xml"))
        page = name == "index.html"
        if page:
            # Адреса app.js и styles.css — с настоящей версией файла: страница no-store, ассеты по ним — в кеш (PNL-04)
            body = versioned_assets(body.decode("utf-8")).encode("utf-8")
        # Версия в адресе совпала с нынешним файлом — кеш на год (immutable); без версии или с чужой — no-store
        version = (urllib.parse.parse_qs(parsed.query or "").get("v") or [""])[0]
        cache = STATIC_IMMUTABLE if name in STATIC_VERSIONED and version and version == asset_version(name) else "no-store"
        encoding = ""
        if compressible and len(body) >= STATIC_GZIP_MIN and accepts_gzip(self.headers.get("Accept-Encoding")):
            if page:
                body = gzip_body(body)
            else:
                if ent["gz"] is None:
                    ent["gz"] = gzip_body(body)
                body = ent["gz"]
            encoding = "gzip"
        self.send_response(200)
        self.send_header("Content-Type", mime)
        # Страница отдаётся своим путём, мимо send_bytes: без этого вход по
        # ?token=… не заводил бы сессию на самой странице, и cookie появлялась
        # лишь на первом запросе данных.
        self._maybe_set_session_cookie()
        self.send_header("Cache-Control", cache)
        if compressible:
            self.send_header("Vary", "Accept-Encoding")
        if encoding:
            self.send_header("Content-Encoding", encoding)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self._write_body(body)

    def _safe(self, fn, parsed) -> None:
        """Один общий предохранитель на все методы: исключение внутри маршрута
        иначе обрывало соединение, и наружу уходил 502 от nginx."""
        try:
            fn(parsed)
        except BadRequest as exc:
            self.send_error_json(400, str(exc))
        except ActionError as exc:
            self.send_error_json(exc.status, str(exc), exc.code)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception:
            # log_text: в трассировке бывает строка запроса с одиноким суррогатом, и print падал бы сам.
            print(log_text(f"[admin] необработанная ошибка на {self.command} {parsed.path}:\n"
                           + traceback.format_exc()), flush=True)
            try:
                self.send_error_json(500, "internal error")
            except Exception:
                pass

    def _guarded(self, parsed: urllib.parse.ParseResult) -> bool:
        # guard_request работает ДО _safe: его исключение рвало соединение без
        # ответа, и nginx показывал наружу 502 вместо честной ошибки.
        try:
            return self.guard_request(parsed)
        except BadRequest as exc:
            self.send_error_json(400, str(exc))
            return False
        except (BrokenPipeError, ConnectionResetError):
            return False
        except Exception:
            print(log_text(f"[admin] необработанная ошибка на {self.command} {parsed.path}:\n"
                           + traceback.format_exc()), flush=True)
            try:
                self.send_error_json(500, "internal error")
            except Exception:
                pass
            return False

    def _take_call_lang(self) -> None:
        """Язык интерфейса из заголовка — на этот запрос (L-24, call_lang); чужое значение — язык установки.
        Тем же разом — просьба о свежем сборе (ручное «Обновить», call_fresh) и чистый список прочитанного
        (snapshot_meta): поток обслуживает один запрос, но место локальное для потока — начинаем с нуля."""
        value = str(self.headers.get(CALL_LANG_HEADER) or "").strip().lower()
        _CALL_CTX.lang = value if value in ("ru", "en") else ""
        _CALL_CTX.fresh = str(self.headers.get(FRESH_HEADER) or "").strip() == "1"
        _CALL_CTX.reads = {}

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        self._take_call_lang()
        if not self._guarded(parsed):
            return
        if parsed.path.startswith("/api/"):
            self._safe(self.route_get_api, parsed)
        else:
            self._safe(self.send_static, parsed)

    def do_HEAD(self) -> None:
        # Тот же путь, что и GET, только без тела: см. _write_body. Команду
        # подменяем осознанно — вся маршрутизация и стража спрашивают
        # self.command == "GET", и без подмены HEAD на страницу входа отвечал бы
        # 401 там, где GET отдаёт 200: та же примета, что и 501 до этого.
        self._is_head = True
        self.command = "GET"
        self.do_GET()

    def do_POST(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        self._take_call_lang()
        if not self._guarded(parsed):
            return
        if parsed.path.startswith("/api/"):
            self._safe(self.route_post_api, parsed)
        else:
            self.send_error(404)


class PanelServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    # Очередь входящих соединений — как у соседних служб (страницы 64, MCP 64). По
    # умолчанию у socketserver она 5: наплыв из девяти одновременных входов (тест
    # SEC-P1) на macOS упирался в неё, лишние соединения получали сброс, и человек
    # видел «сайт недоступен» вместо честного 429.
    request_queue_size = 64


def cli_password(argv: List[str]) -> int:
    """`server.py --set-password [--login=NAME]` — пароль читается со stdin.

    Установщик на bash не считает KDF сам: правило одно и живёт здесь, иначе
    два разных куска кода расходились бы в параметрах. Пароль идёт потоком, а
    не аргументом: аргументы видны в `ps` любому пользователю машины.
    `--password-status` печатает JSON без единого секрета.
    """
    if "--password-status" in argv:
        rec = password_record()
        print(json.dumps({"set": bool(rec), "login": str(rec.get("login") or PASSWORD_LOGIN_DEFAULT),
                          "file": str(PASSWORD_FILE), "updated": str(rec.get("updated") or "")},
                         ensure_ascii=False))
        return 0
    login = PASSWORD_LOGIN_DEFAULT
    for arg in argv:
        if arg.startswith("--login="):
            login = arg.split("=", 1)[1].strip()
    password = sys.stdin.readline().rstrip("\n").rstrip("\r")
    try:
        rec = password_set(login, password)
    except ActionError as exc:
        sys.stderr.write(f"{exc}\n")
        return 2
    print(json.dumps({"ok": True, "login": rec["login"], "algo": rec["algo"], "file": str(PASSWORD_FILE)},
                     ensure_ascii=False))
    return 0


def main() -> None:
    argv = sys.argv[1:]
    if "--set-password" in argv or "--password-status" in argv:
        raise SystemExit(cli_password(argv))
    if not STATIC_DIR.exists():
        raise SystemExit(f"static dir not found: {STATIC_DIR}")
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except Exception:
        pass
    if not ACTIONS_JSON.exists():
        print(f"[admin] внимание: нет {ACTIONS_JSON} — действия недоступны до установки ядра", flush=True)
    httpd = PanelServer((HOST, PORT), AdminHandler)
    print(f"goAmnezia pro admin v{detect_version()} listening on http://{HOST}:{PORT}", flush=True)
    # Аварийный ключ панель не заводит: его выдаёт SSH-меню на час, принимается он только по туннелю и сгорает при входе.
    print(f"[admin] emergency key: {ADMIN_TOKEN_FILE} + {ADMIN_TOKEN_META.name} from the SSH menu (one-off, SSH tunnel only)", flush=True)
    print(f"[admin] SSH tunnel: ssh -L {PORT}:127.0.0.1:{PORT} root@SERVER_IP", flush=True)
    print(f"[admin] bridge: {ACTION_BIN} --action=… --json; actions: {ACTIONS_JSON}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
