#!/usr/bin/env python3
"""
goAmnezia pro — Telegram-бот: второй интерфейс к тому же ядру, что SSH-меню.

Каркас — из goTelegram Pro (python-telegram-bot v21+): safe_edit_message,
run_bot_action с разбором последней JSON-строки моста, один замок на мутации,
язык на пользователя. Администратора привязывают сообщением с подтверждением в SSH
(окно открывает SSH; одноразовый код — запасной путь установки без терминала).
Специфика продукта — пользователи с конфигурацией в каждом профиле AmneziaWG,
ключи в двух стилях (.conf + QR и ключ приложения Amnezia vpn:// + серия QR),
профили-контейнеры, уведомления из файловой очереди таймера лимитов.

Правила (docs/CONTRACT.md §6): бот НЕ пишет config.json / users.json сам —
все мутации только через мост `install.sh --action=<имя> --json --k=v`;
config.json читается лишь для отображения того, чего в ответе `status` нет
(подсеть, MTU, путь мини-аппа). Ни одной видимой строки вне lang/*.json.

Модуль импортируется без побочных эффектов: токен читается и проверяется
только в main(), python-telegram-bot нужен только для запуска — чистые
функции (разбор ответа моста, валидация, typed-confirm, пагинация) работают
и без него, чтобы tests/test_bot_features.py шли на голом python3.
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
import datetime as _dt
import fcntl
import functools
import hashlib
import hmac
import html
import importlib.util
import io
import json
import logging
import math
import os
import random
import re
import shutil
import signal
import sys
import tempfile
import time
import unicodedata
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

# ── Необязательные зависимости ───────────────────────────────────────────────
# python-dotenv: удобство для ручного запуска; юнит подаёт .env через
# EnvironmentFile, так что без библиотеки бот тоже работает.
try:
    from dotenv import load_dotenv as _load_dotenv
except ImportError:  # pragma: no cover — на сервере ставится из requirements.txt
    _load_dotenv = None

# python-telegram-bot нужен только для запуска. Без него модуль всё равно
# импортируется: тесты серии гоняют чистые функции системным python3, а
# main() честно скажет, чего не хватает, вместо трассировки ImportError.
try:
    from telegram import (
        BotCommand,
        InlineKeyboardButton,
        InlineKeyboardMarkup,
        InputFile,
        InputMediaPhoto,
        MenuButtonCommands,
        MenuButtonWebApp,
        Update,
        WebAppInfo,
    )
    from telegram.error import BadRequest, TelegramError
    from telegram.ext import (
        Application,
        CallbackQueryHandler,
        CommandHandler,
        ContextTypes,
        MessageHandler,
        filters,
    )
    PTB_AVAILABLE = True
    PTB_IMPORT_ERROR = ""

    # Ответ на нажатие кнопки, пришедшее с опозданием, — не повод бросать само действие. На сервере, где
    # api.telegram.org отвечает медленно (в РФ по IPv4 его режут), нажатие доходит позже 15 секунд, и
    # query.answer() падает «Query is too old» — раньше это обрывало обработчик ДО работы: админ не
    # назначался, ключ не выдавался (живая проверка 25.09.2026, сервер в Москве). Один перехват на все
    # 240 вызовов: опоздавший ответ молча пропускаем, остальные ошибки — как были.
    from telegram.ext import ExtBot as _ExtBot

    _orig_answer_callback_query = _ExtBot.answer_callback_query

    async def _answer_callback_query_late_ok(self, *args, **kwargs):  # type: ignore[no-untyped-def]
        try:
            return await _orig_answer_callback_query(self, *args, **kwargs)
        except BadRequest as exc:
            text = str(exc).lower()
            if "query is too old" in text or "query id is invalid" in text:
                logging.getLogger("goamnezia-bot").info("ответ на нажатие опоздал: %s", exc)
                return False
            raise

    _ExtBot.answer_callback_query = _answer_callback_query_late_ok
except ImportError as _ptb_exc:  # pragma: no cover — ветка для тестов без PTB
    PTB_AVAILABLE = False
    PTB_IMPORT_ERROR = str(_ptb_exc)

    class BadRequest(Exception):  # type: ignore[no-redef]
        """Заглушка: без PTB исключений Telegram не бывает."""

    class TelegramError(Exception):  # type: ignore[no-redef]
        """Заглушка: без PTB исключений Telegram не бывает."""

    Update = Any  # type: ignore[assignment,misc]
    ContextTypes = Any  # type: ignore[assignment,misc]

# i18n — рядом с этим файлом
_BOT_DIR_PATH = Path(__file__).resolve().parent
if str(_BOT_DIR_PATH) not in sys.path:
    sys.path.insert(0, str(_BOT_DIR_PATH))
from i18n import (  # noqa: E402 — после настройки sys.path
    SUPPORTED_LANGS,
    get_language_name,
    get_user_lang,
    set_user_lang,
    days as _days,
    t as _t,
    t_in as _t_in,
    tf as _tf,
)

# ── Логирование ──────────────────────────────────────────────────────────────
logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    level=logging.INFO,
)
logger = logging.getLogger("goamnezia-bot")
# httpx на уровне INFO печатает полный URL запроса, а в URL Bot API лежит
# ТОКЕН. Логи юнита показывает раздел «Состояние → Логи», то есть токен утекал
# бы любому админу и в каждый бэкап журнала.
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)
logging.getLogger("telegram.ext.Updater").setLevel(logging.WARNING)

# ============================================================================
# КОНФИГУРАЦИЯ
# ============================================================================
# Все пути — с переопределением через окружение (контракт §1): тесты и стенды
# подменяют каталоги, и бот обязан уехать за ними целиком.
GOAMNEZIA_DIR = os.getenv("GOAMNEZIA_DIR", "/opt/goamnezia")
GOAMNEZIA_CONFIG = os.path.join(GOAMNEZIA_DIR, "config.json")
ACTION_BIN = os.getenv("GOAMNEZIA_ACTION_BIN", os.path.join(GOAMNEZIA_DIR, "install.sh"))
ACTIONS_JSON = os.getenv("GOAMNEZIA_ACTIONS_JSON", os.path.join(GOAMNEZIA_DIR, "lib", "actions.json"))
# Каталог шаблонов сайта (~14 МБ) и переносимый помощник к нему — те же пути и
# та же переменная окружения, что у панели (admin-web/server.py).
CATALOG_FILE = os.getenv("GOAMNEZIA_CATALOG", os.path.join(GOAMNEZIA_DIR, "templates_catalog.json"))
CATALOG_TOOL = os.path.join(GOAMNEZIA_DIR, "lib", "catalog_tool.py")
BOT_DIR = os.getenv("GOAMNEZIA_BOT_DIR", "/opt/goamnezia-bot")
ENV_FILE = os.path.join(BOT_DIR, ".env")
ADMIN_CLAIMED_MARKER = os.path.join(BOT_DIR, ".admin_claimed")
# Одноразовый код первого администратора (0600, пишет install_bot.sh или сам бот при
# старте без админов): им владелец доказывает, что видит терминал сервера.
ADMIN_CLAIM_CODE_FILE = os.path.join(BOT_DIR, ".admin_claim_code")
# Привязка администратора сообщением (docs/BOT.md «Контракт привязки»): SSH открывает окно —
# пишет конец окна (epoch, секунды); бот записывает написавших в кандидаты; SSH подтверждает
# одного — пишет ALLOWED_IDS/OWNER_ID в .env и его id в .admin_confirmed, бот подхватывает и
# отвечает .admin_pairing_done (принято, id) или .admin_confirmed.rejected (не принято, почему).
ADMIN_PAIRING_UNTIL_FILE = os.path.join(BOT_DIR, ".admin_pairing_until")
ADMIN_CANDIDATES_FILE = os.path.join(BOT_DIR, ".admin_candidates.json")
ADMIN_CONFIRMED_FILE = os.path.join(BOT_DIR, ".admin_confirmed")
ADMIN_CONFIRMED_REJECTED_FILE = ADMIN_CONFIRMED_FILE + ".rejected"
ADMIN_PAIRING_DONE_FILE = os.path.join(BOT_DIR, ".admin_pairing_done")
NOTIFY_DIR = os.getenv("GOAMNEZIA_NOTIFY_DIR", "/run/goamnezia/notify")
NOTIFY_POLL_SECONDS = 30
# Короткие ссылки с 2FA через бота: запросы входа и замены ядро кладёт в свою очередь (тот же формат, что ga_notify) —
# ${LOCK_DIR:-/run/goamnezia}/short-confirm/. Человек у экрана ждёт ответа за секунду-две, поэтому её бот смотрит раз
# в секунду, а не раз в 30 с, как общую. Какие сообщения запроса у кого — в файле рядом с .env (0600).
SHORT_CONFIRM_DIR = os.getenv("GOAMNEZIA_SHORT_CONFIRM_DIR") or os.path.join(
    os.getenv("GOAMNEZIA_LOCK_DIR") or "/run/goamnezia", "short-confirm")
SHORT_CONFIRM_POLL_SECONDS = 1
SHORT_STATE_FILE = os.path.join(BOT_DIR, ".short_confirm.json")
BOT_SERVICE = "goamnezia-bot"

# Профили в порядке SSH-меню и панели (lib/common.sh PROFILE_IDS="awg3 awg2 awg1",
# admin-web PROFILE_ORDER): 3.1 → 2.0 → 1.x, как в мастере (правило владельца).
# Бот держал прежний порядок «awg2 первым» с 0.1 — и шапка, «Протоколы», карточка
# пользователя и логи шли не в том порядке, что в SSH и панели.
PROFILE_IDS = ("awg3", "awg2", "awg1")
# Минимальная версия приложения Amnezia по линейке (lib/export.sh
# ga_export_min_client) — карточка показывает её ДО выдачи ключа, когда
# ответа user-key ещё нет; при выдаче берём min_client из ответа моста.
MIN_CLIENT_BY_LINE = {"1.0": "4.0.0", "1.5": "4.8.8.3", "2.0": "4.8.12.9", "3.1": "5.0.1.5"}
# Три режима (PLAN §4.3) → ключ словаря с человеческим названием. Словарь, а не
# «mode_name_%s» % mode: значение из ответа моста не должно превращаться в ключ
# словаря, а проверка tests/check_i18n_bot.py видит все три ключа целиком.
# Название — Pro / Semi-Pro / Lite, подпись к нему — что это значит (таблица «Договор 0.6.0» в
# docs/MODES_047.md, одинаково во всех интерфейсах): «Semi-Pro — VPN и сайт». Внутренние id прежние.
MODE_NAME_KEYS = {"lite": "mode_name_lite", "lite_site": "mode_name_lite_site", "pro": "mode_name_pro"}
MODE_SUB_KEYS = {"lite": "mode_sub_lite", "lite_site": "mode_sub_lite_site", "pro": "mode_sub_pro"}
# Порядок экрана смены режима и проверки портов — как в мастере SSH 0.6.0 (docs/MODES_047.md «Порядок в
# мастере»): Pro → Semi-Pro → Lite; сценарий «Ленивый Pro» (итог — pro или lite_site) стоит над ними.
MODES = ("pro", "lite_site", "lite")
# Режимы, в которых на сервере есть сайт (а значит шаблон, Alt-Svc и проверка).
MODES_WITH_SITE = ("lite_site", "pro")
LOG_COMPONENTS = ("awg3", "awg2", "awg1", "bot", "admin", "nginx", "system", "mcp")
# Пресеты лимита и срока — числами; «Без лимита» и «Бессрочно» — отдельные кнопки (NC-08), не «0» в ряду чисел.
QUOTA_PRESETS_GB = (10, 50, 100, 200)
EXPIRY_PRESETS_DAYS = (30, 90, 180, 365)
# MTU профиля (решение владельца 08.10): 1280 — стандарт, работает везде, и минимум — ниже у клиентов с IPv6
# (AllowedIPs ::/0) туннель не поднимется вовсе (L-02б): такое число — отказ словами. На проводном интернете можно
# поднять до 1320. Кнопки: «↩️ Вернуть 1280» и 1320; своё число — сообщением. Предупреждение — только о том, что
# ломается наверняка (как ядро, awgkeys.py mtu_warnings): MTU выше 1280 и пакет данных MTU + 80 + S4 больше 1440 — на
# части хостеров и сетей скачивание встанет (L-02а).
MTU_STANDARD = 1280


def core_ver_words(user_id: int, p: dict) -> str:
    """Сборка ядра профиля словами: тег образа, а у подхваченного у приложения Amnezia (тег latest) — сборка по дайджесту
    из ядра (status.profiles[].core_version) или «не узнать» (A-8 критика 16.10: голое «latest» ничего не говорило)."""
    tag = str((p or {}).get("image_tag") or "")
    if tag != "latest":
        return tag
    cv = str((p or {}).get("core_version") or "")
    if cv and cv != "latest":
        return _tf(user_id, "pr_core_ver_app_fmt", cv)
    return _t(user_id, "pr_core_ver_app_unknown")
MTU_MIN = 1280
MTU_MAX = 1500
MTU_PRESETS = (1280, 1320)
PACKET_OVERHEAD = 80
PACKET_PATH = 1440
PRESETS = ("default", "quic", "router")
DNS_PRESETS = {
    "cf": ("1.1.1.1", "1.0.0.1"),
    "google": ("8.8.8.8", "8.8.4.4"),
    "adguard": ("94.140.14.14", "94.140.15.15"),
}

# Параметры маскировки по линейке — зеркало ga_amn_param_keys и
# GA_AMN_SERVER_PARAMS из lib/amnezia.sh: мост принимает любой ключ из enum
# actions.json и сам проверяет по правилам линейки, но показывать человеку
# кнопку «S3» у линейки 1.0, где её быть не может, — путать зря.
SERVER_PARAMS = ("S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4",
                 "HeaderProtectionKey", "RandomTrailers", "DisableCookies")
PARAM_VALUE_RE = re.compile(r"^[A-Za-z0-9+/=<>. _-]{0,512}$")


def param_keys_for_line(line: str) -> List[str]:
    """Ключи параметров, которые понимает линейка (порядок как в конфиге)."""
    keys = ["Jc", "Jmin", "Jmax", "S1", "S2"]
    if line in ("2.0", "3.1"):
        keys += ["S3", "S4"]
    keys += ["H1", "H2", "H3", "H4"]
    if line in ("1.5", "2.0", "3.1"):
        keys += ["I1", "I2", "I3", "I4", "I5"]
    if line == "3.1":
        keys += ["HeaderProtectionKey", "ContentPaddingAddition", "RekeyAfterTime",
                 "RekeyTimeout", "RejectAfterTime", "KeepaliveTimeout",
                 "MaxHandshakeAttempts", "RandomTrailers", "DisableCookies"]
    keys += ["PersistentKeepalive", "MTU"]
    return keys


def param_scope(key: str) -> str:
    """server — после смены ключи профиля надо перевыпустить; client — для новых выдач."""
    return "server" if key in SERVER_PARAMS else "client"


# Линейка СВЕЖЕЙ установки профиля (lib/amnezia.sh ga_profile_default) — запасной
# ответ, если ядро линейку не назвало. Обычно её берём из status: у профиля,
# подхваченного из приложения Amnezia, имя контейнера о линейке не говорит.
DEFAULT_LINE = {"awg1": "1.5", "awg2": "2.0", "awg3": "3.1"}
# Семейство линейки: в нём профиль правится (lib/amnezia.sh ga_profile_line_base).
# 1.0 и 1.5 — одно семейство, поэтому у профиля на 1.0 пакеты I1–I5 остаются
# доступными: добавили I1 — стало 1.5, убрали — снова 1.0.
LINE_FAMILY = {"1.0": "1.5", "1.5": "1.5", "2.0": "2.0", "3.1": "3.1"}


def line_base(profile: str, line: str) -> str:
    """Линейка, по ключам которой строится список параметров профиля."""
    return LINE_FAMILY.get(line) or DEFAULT_LINE.get(profile) or "3.1"

# ── Валидация ввода до subprocess ────────────────────────────────────────────
# Регексы совпадают с param_types в lib/actions.json: мост проверит ещё раз,
# но отказ на стороне бота даёт понятную подсказку вместо кода bad_arg.
NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
# Без управляющих символов и без обратной косой черты: подпись печатается в
# терминале root (SSH-меню, echo -e), и «\033[…» в ней была бы управляющей
# последовательностью — тот же образец, что `label` в lib/actions.json и
# ga_users_label_valid в lib/users.sh (находка SR-08).
LABEL_RE = re.compile(r"^[^\x00-\x1f\x7f\\]{1,48}$")
PORT_RE = re.compile(r"^[0-9]{1,5}$")
SUBNET_RE = re.compile(
    r"^(10\.[0-9]{1,3}\.[0-9]{1,3}\.0|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.0"
    r"|192\.168\.[0-9]{1,3}\.0)/2[0-4]$")
HOST_RE = re.compile(r"^([a-z0-9](-*[a-z0-9])*(\.[a-z0-9](-*[a-z0-9])*)+|([0-9]{1,3}\.){3}[0-9]{1,3})$")
IPV4_RE = re.compile(r"^([0-9]{1,3}\.){3}[0-9]{1,3}$")
# Одна запись белого списка адресов доступа — БУКВА В БУКВУ образец `ip_list` из
# lib/actions.json (он же ALLOW_IP_RE в goamnezia-mcp/server.py). Октеты по
# значению и без ведущего нуля, префикс 1..32 тоже без нуля. Своей разборки
# «по кусочкам» здесь больше нет: она была мягче образца, и мост отвергал то,
# что бот уже принял.
ALLOW_IP_RE = re.compile(
    r"^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"
    r"(/([1-9]|[12][0-9]|3[0-2]))?$")
FILE_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
INT_RE = re.compile(r"^[0-9]{1,7}$")
ADMIN_ID_RE = re.compile(r"^[0-9]{1,20}$")
MAX_QUOTA_GB = 100000
MAX_DAYS = 3650


def valid_name(v: str) -> bool:
    return bool(NAME_RE.match(v or ""))


def valid_label(v: str) -> bool:
    return bool(LABEL_RE.match(v or ""))


def valid_profile(v: str) -> bool:
    return v in PROFILE_IDS


def valid_port(v: str) -> bool:
    return bool(PORT_RE.match(v or "")) and 1 <= int(v) <= 65535


def valid_subnet(v: str) -> bool:
    return bool(SUBNET_RE.match(v or ""))


def valid_mtu(v: str) -> bool:
    return bool(re.match(r"^[0-9]{4}$", v or "")) and MTU_MIN <= int(v) <= MTU_MAX


def mtu_too_low(v: str) -> bool:
    """Число ниже 1280 — отказ своими словами (pr_mtu_low: туннель не поднимется у клиентов с IPv6), а не «от 1280 до 1500»."""
    return bool(re.match(r"^[0-9]{1,5}$", v or "")) and int(v) < MTU_MIN


def valid_host(v: str) -> bool:
    """Домен строчными буквами или IPv4; пустое — законное «IP сервера»."""
    return v == "" or bool(HOST_RE.match(v))


def valid_ipv4(v: str) -> bool:
    if not IPV4_RE.match(v or ""):
        return False
    return all(0 <= int(part) <= 255 for part in v.split("."))


def valid_dns(v: str) -> bool:
    """Адрес DNS для клиентов — образец `dns` из lib/actions.json: октеты без ведущих нулей."""
    return bool(ALLOW_IP_RE.match(v or "")) and "/" not in v


def valid_ip_list(v: str) -> bool:
    """Белый список адресов доступа: IPv4 или подсети через запятую; пусто — «любые».

    Проверяем ровно тем образцом, что стоит у `ip_list` в lib/actions.json, — иначе
    бот принимает ввод, который мост тут же отвергает. Прежняя разборка на части
    была мягче образца в двух местах: `203.0.113.5/` (косая черта есть, префикса
    нет) проходила, потому что пустой префикс не проверялся вовсе, а `010.0.0.1`
    проходила, потому что int("010") — это 10. Для bash тот же «010» восьмеричный,
    а для python ipaddress — ошибка разбора: один и тот же адрес у двух половин
    продукта разный. Ноль в префиксе не принимаем нарочно: `203.0.113.10/0`
    читается как «только мой адрес», а означает «любой» — опечатка в один символ
    молча снимала бы ограничение целиком.

    Пробелы сюда доезжать не должны: их снимает сам экран ввода (text.replace),
    как это делает ga_agents_ips_valid в lib/agents.sh.
    """
    if v == "":
        return True
    return all(ALLOW_IP_RE.match(entry) for entry in v.split(","))


def valid_int(v: str, maximum: int) -> bool:
    return bool(INT_RE.match(v or "")) and int(v) <= maximum


# «Без лимита» и «бессрочно» — кнопками и словами, а не числом 0 (NC-08, критик-новичок на 0.5.0): в
# SSH-меню «0» — это «назад», и одна цифра с двумя смыслами путала. Ноль по-прежнему понимается — старые
# ответы и привычка прошлых версий работают, — но экраны о нём больше не говорят. Слова — подписи кнопок
# на обоих языках и очевидные синонимы (множества, а не кортежи: это слова, а не ключи словаря).
QUOTA_UNLIMITED_WORDS = frozenset({"без лимита", "безлимит", "безлимитно", "no limit", "unlimited"})
EXPIRY_NEVER_WORDS = frozenset({"бессрочно", "без срока", "навсегда", "no end date", "never", "forever"})


def _typed_words(text: str) -> str:
    """Ответ для сравнения со словами кнопок: строчные, без кавычек и точки по краям, пробелы по одному."""
    return " ".join(str(text or "").lower().strip(" «»“”\"'.").split())


def parse_quota_gb(text: str) -> Optional[int]:
    """Лимит из сообщения: число гигабайт (0 — без лимита, как в прежних версиях) или «без лимита»; иначе None."""
    v = _typed_words(text)
    if v in QUOTA_UNLIMITED_WORDS:
        return 0
    return int(v) if valid_int(v, MAX_QUOTA_GB) else None


def parse_expiry_days(text: str) -> Optional[int]:
    """Срок из сообщения: число дней (0 — бессрочно, как в прежних версиях) или «бессрочно»; иначе None."""
    v = _typed_words(text)
    if v in EXPIRY_NEVER_WORDS:
        return 0
    return int(v) if valid_int(v, MAX_DAYS) else None


def valid_param_value(v: str) -> bool:
    return bool(PARAM_VALUE_RE.match(v if v is not None else ""))


def valid_backup_file(v: str) -> bool:
    return bool(FILE_RE.match(v or "")) and ".." not in v


def valid_admin_id(v: str) -> bool:
    return bool(ADMIN_ID_RE.match(v or "")) and int(v) > 0


# Доступы агентов к MCP по HTTP (PLAN §6.10): id доступа, уровни, состояния —
# как в lib/agents.sh и lib/actions.json (agent_id, scope).
AGENT_ID_RE = re.compile(r"^a-[a-f0-9]{4,8}$")
AGENT_SCOPES = ("read", "write", "admin")
AGENT_STATES = ("active", "disabled", "expired", "compromised")
# Вид доступа: static — постоянный токен в заголовке, rolling — одноразовый ключ
# (docs/MCP_ROTATION.md §1 в редакции §11), connect — тот же ключ, но хранит и
# вращает его переходник goamnezia-connect на машине агента (§2–§7). Умолчание
# static: rolling требует клиента, который сам хранит ключ, connect — Python 3 у агента.
AGENT_MODES = ("static", "rolling", "connect")
AGENT_PORT_MIN = 1024


def valid_agent_id(v: str) -> bool:
    return bool(AGENT_ID_RE.match(v or ""))


def valid_agent_port(v: str) -> bool:
    """Отдельный TLS-порт транспорта: непривилегированный, как у lib/agents.sh."""
    return valid_port(v) and int(v) >= AGENT_PORT_MIN


# Временная ссылка на файл (lib/share.sh, docs/SHARE.md): id раздачи и форматы.
# QR через ссылку не отдаём — владелец решил, что по ссылке едет только файл, а
# QR остаётся кнопками в этой же карточке, где его удобно сканировать.
SHARE_ID_RE = re.compile(r"^s-[a-f0-9]{4,8}$")
SHARE_FORMATS = ("conf", "vpn")
SHARE_FORMAT_KEYS = {"conf": "share_fmt_conf", "vpn": "share_fmt_vpn"}


def valid_share_id(v: str) -> bool:
    return bool(SHARE_ID_RE.match(v or ""))


def valid_share_format(v: str) -> bool:
    return v in SHARE_FORMATS


# Страница подключения и зеркало сборок (docs/CLIENTS.md §9). Регексы — те же,
# что у моста в lib/actions.json (param_types ttl, page_id, app, platform):
# срок — часы (не больше 720) или дни (не больше 365) одной буквой либо
# forever; идентификатор страницы — p-<4…8 hex>, как у раздач и доступов.
PAGE_TTL_RE = re.compile(r"^([1-9][0-9]{0,2}h|[1-9][0-9]{0,2}d|forever)$")
PAGE_TTL_MAX_HOURS = 720
PAGE_TTL_MAX_DAYS = 365
PAGE_TTL_PRESETS = ("1h", "24h", "7d", "30d", "forever")
PAGE_TTL_KEYS = {"1h": "pg_ttl_1h", "24h": "pg_ttl_24h", "7d": "pg_ttl_7d", "30d": "pg_ttl_30d", "forever": "pg_ttl_forever"}
PAGE_ID_RE = re.compile(r"^p-[a-f0-9]{4,8}$")
# Приложение каталога lib/clients.json и платформы из его записи (§2).
APP_ID_RE = re.compile(r"^[a-z0-9-]{2,32}$")
PLATFORM_IDS = ("ios", "android", "android_tv", "windows", "macos", "linux", "router")
MIRROR_STATES = ("queued", "downloading", "ready", "failed")


def valid_page_ttl(v: str) -> bool:
    v = str(v or "")
    if not PAGE_TTL_RE.match(v):
        return False
    if v == "forever":
        return True
    n = int(v[:-1])
    return n <= (PAGE_TTL_MAX_HOURS if v.endswith("h") else PAGE_TTL_MAX_DAYS)


# Свой срок страницы текстом (NC-23, критик-новичок): по-русски подсказка говорит «12 ч», «3 дн» и
# «навсегда», по-английски — «12h», «3d» и «forever». Понимаются оба написания на любом языке
# интерфейса (подсказку могли прочитать на другом), пробел между числом и единицей не мешает; мосту
# уходит всегда запись договора — 12h, 3d, forever.
PAGE_TTL_TEXT_RE = re.compile(r"^([0-9]{1,4}) ?([a-zа-я]+)\.?$")
PAGE_TTL_HOUR_UNITS = frozenset({"h", "hour", "hours", "ч", "час", "часа", "часов"})
PAGE_TTL_DAY_UNITS = frozenset({"d", "day", "days", "д", "дн", "день", "дня", "дней"})
PAGE_TTL_FOREVER_WORDS = frozenset({"forever", "навсегда", "бессрочно"})


def parse_page_ttl(text: str) -> str:
    """Срок страницы из сообщения в записи договора: «12 ч» → 12h, «3 дн» → 3d, «навсегда» → forever.
    Не срок или вне пределов (0, больше 720 часов или 365 дней) — пустая строка."""
    v = " ".join(str(text or "").lower().split())
    if v in PAGE_TTL_FOREVER_WORDS:
        return "forever"
    m = PAGE_TTL_TEXT_RE.match(v)
    if not m or m.group(2) not in PAGE_TTL_HOUR_UNITS | PAGE_TTL_DAY_UNITS:
        return ""
    ttl = "%d%s" % (int(m.group(1)), "h" if m.group(2) in PAGE_TTL_HOUR_UNITS else "d")
    return ttl if valid_page_ttl(ttl) else ""


def valid_page_id(v: str) -> bool:
    return bool(PAGE_ID_RE.match(v or ""))


def valid_app_id(v: str) -> bool:
    return bool(APP_ID_RE.match(v or ""))


def valid_platform(v: str) -> bool:
    return v in PLATFORM_IDS


def valid_mode(v: str) -> bool:
    return v in MODES


# Шаблон сайта-маскировки: id из каталога (тип template в lib/actions.json) и
# короткий ключ для callback_data — id бывает до 120 символов, а у Telegram на
# всю callback_data 64 байта (lib/catalog_tool.py Catalog.short_key).
TEMPLATE_ID_RE = re.compile(r"^[A-Za-z0-9_.-]{1,120}$")
TEMPLATE_KEY_RE = re.compile(r"^[a-f0-9]{12}$")
TEMPLATE_RANDOM = "__random__"
TEMPLATE_CATEGORY_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")


def valid_template_id(v: str) -> bool:
    return v == TEMPLATE_RANDOM or bool(TEMPLATE_ID_RE.match(v or ""))


def valid_template_key(v: str) -> bool:
    return bool(TEMPLATE_KEY_RE.match(v or ""))


def valid_template_category(v: str) -> bool:
    return bool(TEMPLATE_CATEGORY_RE.match(v or ""))


# ============================================================================
# ДОСТУП: ALLOWED_IDS, окно первого админа, маркер
# ============================================================================
ALLOWED_IDS: set = set()
# Владелец — ПЕРВЫЙ id в ALLOWED_IDS: тот, кто поставил сервер и пригласил
# остальных. Раньше список жил только множеством, порядок терялся, и любой
# приглашённый мог удалить любого другого, включая владельца: вернуть себя
# было нечем, кроме правки .env руками на сервере. Теперь порядок сохраняется
# отдельно, владелец не удаляется вовсе, а удалять других может только он.
ADMIN_ORDER: List[int] = []
_WAITING_FOR_ADMIN = False  # True, пока список пуст → ждём первого админа

# Окно привязки администратора открывает только SSH (root): мастер установки или «Telegram-бот →
# Администраторы → Привязать по сообщению» пишет в ADMIN_PAIRING_UNTIL_FILE конец окна по часам
# сервера. Бот с пустым ALLOWED_IDS раньше (goTelegram v1) ждал первого админа бессрочно — любой,
# кто первым напишет /start, получал root-контроль над сервером; потом окно открывал сам бот на
# 10 минут после КАЖДОГО старта процесса, и одноразовый код, увиденный однажды, годился в каждом
# следующем окне (SEC46-07). Теперь рестарт окна не открывает, а код живёт не дольше окна.
PAIRING_WINDOW_MAX = 3600       # конец окна дальше часа от записи файла — файл испорчен, не верим
# Кандидатов в файле не больше: записываются первые десять написавших, дальше — никто (SEC50-01).
# Раньше новые вытесняли самых давних, и поток чужих выталкивал владельца из списка и сдвигал номера в SSH.
PAIRING_MAX_CANDIDATES = 10
PAIRING_POLL_SECONDS = 2        # как часто бот смотрит, не подтвердил ли SSH привязку
PAIRING_STALE_SECONDS = 60      # хвосты закрытого окна убираются через минуту; столько же ждём .env
PAIRING_CODE_SLACK = 60         # код старше окна больше чем на минуту — код прошлого окна


def pairing_until() -> float:
    """Конец окна привязки (epoch) или 0 — окна нет, файл пуст или испорчен.

    Число дальше часа от записи файла обрезается: забытый файл с «вечным» окном не должен
    держать бот открытым для чужих навсегда.
    """
    try:
        mtime = os.stat(ADMIN_PAIRING_UNTIL_FILE).st_mtime
        raw = Path(ADMIN_PAIRING_UNTIL_FILE).read_text(encoding="utf-8").strip()
        until = float(raw.split()[0]) if raw else 0.0
    except (OSError, UnicodeDecodeError, ValueError):
        return 0.0
    if not math.isfinite(until) or until <= 0:
        return 0.0
    return min(until, mtime + PAIRING_WINDOW_MAX)


def pairing_window_open(now: Optional[float] = None) -> bool:
    return (time.time() if now is None else now) < pairing_until()


def pairing_seconds_left(now: Optional[float] = None) -> int:
    left = pairing_until() - (time.time() if now is None else now)
    return int(left) if left > 0 else 0


def _file_mtime(path: str) -> Optional[float]:
    try:
        return os.stat(path).st_mtime
    except OSError:
        return None


def _parse_admin_ids(raw: str, warn: bool = False) -> List[int]:
    """Telegram ID из строки ALLOWED_IDS (запятая, пробел или их сочетание) — в порядке записи."""
    out: List[int] = []
    for part in re.split(r"[,\s]+", raw or ""):
        part = part.strip()
        if not part:
            continue
        try:
            uid = int(part)
        except ValueError:
            if warn:
                logger.warning("Invalid ALLOWED_IDS entry: %s", part)
            continue
        if uid not in out:
            out.append(uid)
    return out


def _load_allowed_ids() -> None:
    """ALLOWED_IDS из окружения: запятая, пробел или их сочетание.

    Порядок записи сохраняем: первый id — владелец (см. ADMIN_ORDER).
    """
    global ALLOWED_IDS, _WAITING_FOR_ADMIN
    ids = _parse_admin_ids(os.getenv("ALLOWED_IDS", ""), warn=True)
    ALLOWED_IDS = set(ids)
    ADMIN_ORDER[:] = ids
    _WAITING_FOR_ADMIN = len(ALLOWED_IDS) == 0


def _env_value(raw: str) -> str:
    """Значение из строки .env так, как его читает python-dotenv: в кавычках — до закрывающей
    кавычки (хвост за ней, « # комментарий», — мимо), без кавычек — до « #»."""
    value = raw.strip()
    if value[:1] in ("'", '"'):
        end = value.find(value[0], 1)
        return value[1:end] if end > 0 else re.sub(r"\s+#.*$", "", value[1:])
    return re.sub(r"\s+#.*$", "", value)


def _read_env_values(names: Tuple[str, ...]) -> Optional[Dict[str, str]]:
    """Значения переменных из .env бота разбором строк, без source; None — файл не прочитать.

    `export` в начале строки, кавычки и комментарий — как у python-dotenv (_env_value). Повтор
    переменной — побеждает последняя, как у systemd.
    """
    try:
        text = Path(ENV_FILE).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        logger.warning("Не прочитан %s: %s", ENV_FILE, exc)
        return None
    out: Dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        key, sep, value = line.partition("=")
        key = key.strip()
        if not sep or key not in names:
            continue
        out[key] = _env_value(value)
    return out


def reload_admins_from_env() -> bool:
    """ALLOWED_IDS и OWNER_ID заново из .env — без перезапуска бота. True — список перечитан.

    Их пишет SSH, подтвердив привязку сообщением. Юнит подаёт .env через EnvironmentFile только
    при старте, а load_dotenv уже заданные переменные не перезаписывает — поэтому читаем файл сами
    и дальше разбираем тем же _load_allowed_ids, что при старте. Переменной OWNER_ID нет в файле —
    нет её и в окружении: после рестарта было бы так же. Файл не прочитать, или в нём не нашлось ни
    одного ID, когда админы есть, — всё остаётся как было: строка, испорченная правкой руками, не
    должна запереть бот от всех его админов (подтверждение привязки только добавляет админа).
    """
    values = _read_env_values(("ALLOWED_IDS", "OWNER_ID"))
    if values is None:
        return False
    if not _parse_admin_ids(values.get("ALLOWED_IDS", "")):
        if ALLOWED_IDS:
            logger.warning("ALLOWED_IDS in %s holds no Telegram id — keeping the current %d admin(s)",
                           ENV_FILE, len(ALLOWED_IDS))
        return False
    os.environ["ALLOWED_IDS"] = values["ALLOWED_IDS"]
    if "OWNER_ID" in values:
        os.environ["OWNER_ID"] = values["OWNER_ID"]
    else:
        os.environ.pop("OWNER_ID", None)
    _load_allowed_ids()
    return True


# Замок .env (SEC50-04). Писателей у .env несколько — бот (/invite, удаление админа, владелец по коду),
# SSH-меню (владелец) и установщик (создание, привязка сообщением), — и каждый читает файл, меняет строку и
# кладёт весь файл обратно: без общего замка запись одного пропадала под записью другого (админ, добавленный
# /invite, исчезал после «Назначить владельца» в ту же секунду). Все берут flock на .env.lock рядом с .env
# и держат его на всё «прочитать — изменить — записать»: здесь и в PY_ENV_ADD_ADMIN — fcntl.flock, в bash —
# flock(1). Писатели держат замок миллисекунды; занят дольше ENV_LOCK_WAIT — запись не делается (False у
# вызывающего — «не сохранено»), а не ждёт вечно посреди цикла событий.
ENV_LOCK_WAIT = 10.0


@contextlib.contextmanager
def _env_file_lock(wait: Optional[float] = None):
    wait = ENV_LOCK_WAIT if wait is None else wait
    fd = os.open(ENV_FILE + ".lock", os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        deadline = time.monotonic() + wait
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("%s.lock занят дольше %d с" % (ENV_FILE, wait))
                time.sleep(0.05)
        yield
    finally:
        os.close(fd)        # закрытие снимает замок


def _save_env_value(name: str, value: str) -> bool:
    """Записать одну переменную в .env бота (атомарно, 0600, под замком .env) и в окружение.

    Отдельно от _save_allowed_ids: владелец — не список, и переписывать его
    вместе со списком админов нельзя, иначе приглашение меняло бы владельца.
    """
    try:
        with _env_file_lock():
            path = Path(ENV_FILE)
            lines, found = [], False
            if path.exists():
                for line in path.read_text(encoding="utf-8").splitlines(True):
                    if line.strip().startswith("%s=" % name):
                        if not found:
                            lines.append("%s=%s\n" % (name, value)); found = True
                    else:
                        lines.append(line)
            if not found:
                if lines and not lines[-1].endswith("\n"):
                    lines[-1] += "\n"
                lines.append("%s=%s\n" % (name, value))
            tmp = Path("%s.tmp.%d" % (ENV_FILE, os.getpid()))
            tmp.write_text("".join(lines), encoding="utf-8")
            os.chmod(str(tmp), 0o600)
            os.replace(str(tmp), str(path))
    except OSError as exc:
        logger.error("Не записан %s в .env: %s", name, exc)
        return False
    os.environ[name] = value
    return True


def _save_allowed_ids() -> bool:
    """Записать ALLOWED_IDS в .env (атомарно, 0600) и в os.environ."""
    global _WAITING_FOR_ADMIN
    # Пишем в порядке приглашения, а не по возрастанию id: первый в строке —
    # владелец, и сортировка по номеру подменяла бы его случайным человеком
    # после каждого перезапуска бота.
    ids_str = ",".join(str(i) for i in admin_ids_ordered())
    os.environ["ALLOWED_IDS"] = ids_str
    _WAITING_FOR_ADMIN = len(ALLOWED_IDS) == 0

    if not os.path.exists(ENV_FILE):
        # без .env изменение не переживёт рестарт — вызывающий обязан сказать об этом
        return False

    tmp = "%s.tmp.%d" % (ENV_FILE, os.getpid())
    try:
        # Прочитать, изменить и записать — целиком под замком .env (SEC50-04)
        with _env_file_lock():
            with open(ENV_FILE, "r", encoding="utf-8") as f:
                lines = f.readlines()
            found = False
            new_lines = []
            for line in lines:
                if line.strip().startswith("ALLOWED_IDS="):
                    if ids_str:
                        new_lines.append("ALLOWED_IDS=%s\n" % ids_str)
                    found = True
                else:
                    new_lines.append(line)
            if not found and ids_str:
                new_lines.append("ALLOWED_IDS=%s\n" % ids_str)
            # tmp + replace: запись «на месте» при сбое усекала .env вместе с BOT_TOKEN
            with open(tmp, "w", encoding="utf-8") as f:
                f.writelines(new_lines)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, 0o600)
            os.replace(tmp, ENV_FILE)
        logger.info("ALLOWED_IDS updated in .env (%d ids)", len(ALLOWED_IDS))
        return True
    except OSError as e:
        logger.error("Failed to update .env: %s", e)
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False


def admin_ids_ordered() -> List[int]:
    """ALLOWED_IDS в порядке приглашения; не попавшие в порядок (правка .env
    руками при работающем боте) дописываются в конец по возрастанию."""
    out = [uid for uid in ADMIN_ORDER if uid in ALLOWED_IDS]
    out.extend(sorted(uid for uid in ALLOWED_IDS if uid not in out))
    return out


def owner_id() -> Optional[int]:
    """Владелец сервера. Источник правды — OWNER_ID в .env, а НЕ порядок записи.

    Порядок в ALLOWED_IDS доказательством не является: прежние версии писали этот
    список ОТСОРТИРОВАННЫМ по возрастанию id, и на любой обновлённой установке,
    где хоть раз звали /invite, «владельцем» становился приглашённый со старым
    аккаунтом. Ему не рисовались кнопки удаления, а сосед мог удалить его самого.

    Нет OWNER_ID — владелец НЕ ОПРЕДЕЛЁН, и это честнее догадки: пока его не
    назначили, никто не управляет админами. Назначает установщик при первой
    установке и экран «Настройки → Администраторы» в SSH-меню.
    """
    raw = (os.getenv("OWNER_ID") or "").strip()
    if not raw:
        return None
    try:
        own = int(raw)
    except ValueError:
        logger.warning("OWNER_ID не число: %s", raw)
        return None
    return own if own in ALLOWED_IDS else None


def is_owner(user_id: Optional[int]) -> bool:
    own = owner_id()
    return own is not None and user_id is not None and int(user_id) == own


def admin_claim_seconds_left() -> int:
    return pairing_seconds_left() if _WAITING_FOR_ADMIN else 0


def admin_claim_open() -> bool:
    """Можно ли сейчас стать первым админом по одноразовому коду: админов нет, окно открыто и код
    выдан для этого окна (admin_claim_code).

    Код — запасной путь для установок без терминала. Раньше окно для него открывал сам бот на
    10 минут после старта процесса, и каждый рестарт (ребут VPS, crash-loop) давал увиденному
    однажды коду новые 10 минут (SEC46-07). Теперь код принимается, только пока открыто окно
    привязки, которое открывает root из SSH, и только выданный вместе с этим окном.
    """
    return _WAITING_FOR_ADMIN and pairing_window_open() and bool(admin_claim_code())


# ── Одноразовый код первого администратора ───────────────────────────────────
# Запасной путь для установок без терминала (основной — привязка сообщением с подтверждением
# в SSH). Окно само по себе не защита: имя бота видно всем, и администратором становился
# ПЕРВЫЙ, кто успел написать /start. Поэтому в окне нужен ещё и код, который видит только тот,
# кто сидит у терминала: установщик печатает его на экране и кладёт в ADMIN_CLAIM_CODE_FILE
# (0600). Сам бот кода не заводит: без установщика код никому не показан, а окно без терминала
# привязывает сообщением. Код приходит командой «/start КОД» (ссылка t.me/<бот>?start=КОД) или
# отдельным сообщением и принимается, только пока открыто окно привязки.
# Ровно восемь цифр — иных кодов ни установщик, ни бот не выдают. Раньше кодом считалась
# любая строка из 8–64 латинских букв и цифр: «Hello bot» (→ hellobot), «adminadmin»
# засчитывались промахами, и владелец, написавший боту пару фраз до кода, после пятой
# оставался без ответа даже на верный код до перезапуска бота.
CLAIM_CODE_RE = re.compile(r"[0-9]{8}")
# Неверных кодов от одного человека — не больше этого числа за одно окно привязки: дальше
# он не получает ответа вовсе, и перебор 10^8 вариантов теряет смысл. Новое окно (SSH
# переписал файл окна) счёт обнуляет — pairing_sync_window.
CLAIM_MAX_FAILS = 5
_CLAIM_VERIFIED: set = set()          # кто прислал верный код (кнопка «Да» — только им)
_CLAIM_FAILS: Dict[int, int] = {}
_PAIRING_SEEN: Dict[str, Any] = {"window": None}     # какое окно бот видел последним


def pairing_sync_window() -> bool:
    """Открыто новое окно (файл окна переписан) — промахи по коду и «верные коды» прошлого окна
    забываются. True — окно новое."""
    try:
        st = os.stat(ADMIN_PAIRING_UNTIL_FILE)
    except OSError:
        return False
    wid = (st.st_ino, st.st_mtime_ns)
    if wid == _PAIRING_SEEN["window"]:
        return False
    _PAIRING_SEEN["window"] = wid
    _CLAIM_FAILS.clear()
    _CLAIM_VERIFIED.clear()
    return True


def normalize_claim_code(raw: Any) -> str:
    """Код, как его прислали: «/start 4829 1375», «4829-1375», «48291375» → «48291375».

    Пробелы (и неразрывные — их вставляет клавиатура телефона) и дефисы выкидываем:
    установщик показывает код группами по четыре, и человек перепечатывает его как
    видит. Не восемь цифр — не код: пусто (промахом такое не считается).
    Установщик разбирает getUpdates этой же логикой (install_bot.sh PY_PARSE_UPDATES).
    """
    text = str(raw or "").strip()
    m = re.match(r"^/start(?:@\w+)?(?:\s+|$)", text)
    if m:
        text = text[m.end():]
    text = re.sub(r"[\s-]", "", text)
    return text if CLAIM_CODE_RE.fullmatch(text) else ""


def admin_claim_code() -> str:
    """Код из файла, выданный для нынешнего окна; нет файла, в нём мусор или код прошлого окна — пусто.

    Код привязан к окну по времени записи: установщик пишет их рядом, в любом порядке. Код,
    записанный раньше файла окна больше чем на минуту (PAIRING_CODE_SLACK), выдан для прошлого
    окна — увиденный однажды, он не должен годиться в следующем (SEC46-07). Окна нет — код
    возвращается, но admin_claim_open его не примет: он ждёт окна от своего установщика.
    """
    try:
        raw = Path(ADMIN_CLAIM_CODE_FILE).read_text(encoding="utf-8")
        code_mtime = os.stat(ADMIN_CLAIM_CODE_FILE).st_mtime
    except (OSError, UnicodeDecodeError):
        return ""
    window_mtime = _file_mtime(ADMIN_PAIRING_UNTIL_FILE)
    if window_mtime is not None and code_mtime < window_mtime - PAIRING_CODE_SLACK:
        return ""
    return normalize_claim_code(raw)


def claim_code_matches(raw: Any) -> bool:
    """Верный ли код. Сравнение за постоянное время: по задержке ответа код не подобрать."""
    want = admin_claim_code()
    got = normalize_claim_code(raw)
    return bool(want) and bool(got) and hmac.compare_digest(got, want)


def forget_admin_claim_code() -> None:
    """Админ назначен — код больше ничего не открывает: файл и память о попытках — прочь."""
    try:
        os.unlink(ADMIN_CLAIM_CODE_FILE)
    except OSError:
        pass
    _CLAIM_VERIFIED.clear()
    _CLAIM_FAILS.clear()


# Назначение первого админа — под замком. С concurrent_updates(True) два «Да», нажатые
# в одну секунду, шли параллельно: оба проходили проверку «админа ещё нет» до того, как
# первый успевал записаться, — и админами становились оба. Замок создаётся в том цикле
# событий, где работает (в python 3.9 asyncio.Lock привязывается к циклу при создании).
_CLAIM_LOCK: Dict[str, Any] = {"loop": None, "lock": None}


def _admin_claim_lock() -> "asyncio.Lock":
    loop = asyncio.get_running_loop()
    if _CLAIM_LOCK["lock"] is None or _CLAIM_LOCK["loop"] is not loop:
        _CLAIM_LOCK["lock"] = asyncio.Lock()
        _CLAIM_LOCK["loop"] = loop
    return _CLAIM_LOCK["lock"]


# ── Привязка сообщением: кандидаты для SSH ───────────────────────────────────
# Пока окно открыто, не-админ, написавший боту, попадает в ADMIN_CANDIDATES_FILE, а SSH
# показывает список и спрашивает «Это вы?». Доверие даёт SSH-сессия: у постороннего её нет,
# поэтому «первый написавший» сам админом не станет. Имя и @username присылает Telegram, то
# есть кто угодно, а SSH печатает их в терминале root: управляющие символы (C0, DEL и C1 —
# U+009B тоже начинает escape-последовательность), разделители строк и обратная косая черта
# становятся пробелом. Кавычка и скобки — тоже: имя вида «", "id": 1} {» не собьёт даже разбор
# файла без JSON-парсера (договор требует парсер). Невидимые символы — вся категория Unicode Cf
# (знаки направления текста, U+061C, U+200B–U+200D, U+2060, U+FEFF…) и пустые буквы вроде
# хангыль-заполнителя — удаляются вовсе: имя владельца с невидимым хвостом выглядело в SSH ровно
# как настоящее (SEC50-01). SSH при показе чистит так же (install_bot.sh PY_CANDIDATES).
_PAIRING_UNSAFE_RE = re.compile(r'[\x00-\x1f\x7f-\x9f\\"{}\[\]\u2028\u2029]')
_PAIRING_INVISIBLE_RE = re.compile(r"[\u034f\u115f\u1160\u17b4\u17b5\u180b-\u180f\u2800\u3164"
                                   r"\ufe00-\ufe0f\uffa0\U000e0100-\U000e01ef]")
TG_USERNAME_RE = re.compile(r"^[A-Za-z0-9_]{1,32}$")
PAIRING_NAME_MAX = 64


def _pairing_clean(value: Any, limit: int = PAIRING_NAME_MAX) -> str:
    """Имя из Telegram для терминала root: опасное — пробелом, невидимое — прочь, до limit символов."""
    text = _PAIRING_INVISIBLE_RE.sub("", _PAIRING_UNSAFE_RE.sub(" ", str(value or "")))
    text = "".join(ch for ch in text if unicodedata.category(ch) not in ("Cc", "Cf", "Cs"))
    return " ".join(text.split())[:limit]


def pairing_candidate_record(user: Any, now: Optional[float] = None) -> Dict[str, Any]:
    """Запись кандидата: id, username (без @; не по форме Telegram — пусто), имя, время (epoch)."""
    username = str(getattr(user, "username", None) or "")
    return {
        "id": int(user.id),
        "username": username if TG_USERNAME_RE.match(username) else "",
        "first_name": _pairing_clean(getattr(user, "first_name", None)),
        "ts": int(time.time() if now is None else now),
    }


def pairing_candidates() -> List[Dict[str, Any]]:
    """Кандидаты из файла в порядке записи — по времени первого сообщения; мусор — мимо."""
    try:
        data = json.loads(Path(ADMIN_CANDIDATES_FILE).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError):
        return []
    if not isinstance(data, list):
        return []
    return [c for c in data if isinstance(c, dict) and isinstance(c.get("id"), int)
            and not isinstance(c.get("id"), bool)]


def _write_private_file(path: str, text: str) -> bool:
    """Текст в файл 0600 атомарно (tmp рядом + os.replace): SSH не прочтёт его наполовину записанным.

    Без fsync: файлы привязки живут минуты, и после сбоя питания их проще открыть заново, чем
    платить синхронной записью на диск за каждое сообщение чужого."""
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
        return True
    except OSError as exc:
        logger.error("Не записан %s: %s", path, exc)
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False


def _unlink_quiet(path: str) -> bool:
    try:
        os.unlink(path)
        return True
    except OSError:
        return False


PAIRING_NEW, PAIRING_LISTED, PAIRING_FULL = "new", "listed", "full"


def pairing_record_candidate(user: Any, now: Optional[float] = None) -> str:
    """Записать написавшего в кандидаты. PAIRING_NEW — записан сейчас, впервые в этом окне;
    PAIRING_LISTED — уже в списке; PAIRING_FULL — список заполнен, не записан; "" — не записать.

    Записываются первые PAIRING_MAX_CANDIDATES человек по времени первого сообщения — и больше
    никто (SEC50-01). Запись делается один раз и дальше не меняется: ни время, ни имя, ни место в
    списке. Раньше новое сообщение переносило запись в конец, а десятка новых вытесняла самых
    давних — поток чужих выталкивал владельца из списка и сдвигал номера, по которым он выбирает
    себя в SSH. Теперь номер в SSH стабилен, а заполненный список SSH показывает с советом отменить
    окно и открыть заново. Повторные сообщения файл не трогают вовсе: поток сообщений не
    превращается в поток записей на диск.
    """
    rec = pairing_candidate_record(user, now)
    items = pairing_candidates()
    if any(c.get("id") == rec["id"] for c in items):
        return PAIRING_LISTED
    if len(items) >= PAIRING_MAX_CANDIDATES:
        return PAIRING_FULL
    items.append(rec)
    if not _write_private_file(ADMIN_CANDIDATES_FILE, json.dumps(items, ensure_ascii=False) + "\n"):
        return ""
    return PAIRING_NEW


def pairing_forget_stale(now: Optional[float] = None) -> List[str]:
    """Хвосты закрытого окна: кандидаты и одноразовый код его окна уходят через минуту после конца.

    Кандидатов пишет только бот и только в окне — нет открытого окна (истекло или SSH его убрал),
    и через минуту список удаляется. Код — только если его окно было и закончилось, а записан он
    до конца окна: код без окна ждёт окна от своего установщика (без окна его и так не примут), а
    код, записанный после конца окна, выдан уже для следующего. Так код не переживает своё окно, и
    увиденный однажды не годится в следующем (SEC46-07). Минута — запас на гонку с SSH, который
    пишет код и окно не одной операцией. Файл окна не трогаем: SSH мог как раз открыть новое.
    Возвращает удалённые пути.
    """
    now = time.time() if now is None else now
    if pairing_window_open(now):
        return []
    until = pairing_until()          # 0 — окна нет (или файл испорчен)
    removed = []
    mtime = _file_mtime(ADMIN_CANDIDATES_FILE)
    if mtime is not None and now - max(until, mtime) > PAIRING_STALE_SECONDS \
            and _unlink_quiet(ADMIN_CANDIDATES_FILE):
        removed.append(ADMIN_CANDIDATES_FILE)
    mtime = _file_mtime(ADMIN_CLAIM_CODE_FILE)
    if until > 0 and mtime is not None and mtime <= until and now - until > PAIRING_STALE_SECONDS \
            and _unlink_quiet(ADMIN_CLAIM_CODE_FILE):
        removed.append(ADMIN_CLAIM_CODE_FILE)
    if removed:
        logger.info("Admin pairing: the window is closed, removed %s", ", ".join(removed))
    return removed


def is_user_allowed(user_id: Optional[int]) -> bool:
    """Пустой список = никого не пускать (ждём первого админа), не «всем можно»."""
    if user_id is None or _WAITING_FOR_ADMIN:
        return False
    return int(user_id) in ALLOWED_IDS


def add_admin(user_id: int) -> bool:
    first = not ALLOWED_IDS          # захват пустого бота: этот человек и есть владелец
    ALLOWED_IDS.add(int(user_id))
    if int(user_id) not in ADMIN_ORDER:
        ADMIN_ORDER.append(int(user_id))
    saved = _save_allowed_ids()
    # Владельца записываем ЯВНО и только при захвате пустого бота: у пришедшего
    # по приглашению прав владельца нет и быть не может. Если OWNER_ID уже есть,
    # не трогаем — иначе приглашение переписывало бы владельца.
    if first and not (os.getenv("OWNER_ID") or "").strip():
        saved = _save_env_value("OWNER_ID", str(int(user_id))) and saved
    logger.info("Admin added: %s", user_id)
    try:
        Path(ADMIN_CLAIMED_MARKER).parent.mkdir(parents=True, exist_ok=True)
        Path(ADMIN_CLAIMED_MARKER).write_text("1", encoding="utf-8")
    except OSError:
        pass
    return saved


def remove_admin(user_id: int) -> bool:
    ALLOWED_IDS.discard(int(user_id))
    if int(user_id) in ADMIN_ORDER:
        ADMIN_ORDER.remove(int(user_id))
    saved = _save_allowed_ids()
    logger.info("Admin removed: %s", user_id)
    return saved


_load_allowed_ids()

# ============================================================================
# МОСТ --action=: subprocess, разбор последней JSON-строки, замок
# ============================================================================
BRIDGE_TIMEOUT_DEFAULT = 300
# Долгие действия: сборка образа и pull при установке профиля, восстановление
# с пересозданием контейнеров.
BRIDGE_TIMEOUT_BY_ACTION = {
    "profile-install": 900,
    # «Переставить на 2.0» (DUP-LINE-01) — удаление и установка профиля заново: столько же, сколько установка.
    "profile-reline": 900,
    # Подъём контейнера из копии состояния: образа может не оказаться на диске — тогда pull.
    "profile-repair": 900,
    "backup-restore": 600,
    "upstream-update": 900,
    "upstream-rollback": 900,
    "core-update": 900,
    "upstream-check": 120,
    "import-adopt": 300,
    "backup-create": 300,
    # Смена режима: certbot ходит наружу, nginx пересобирается; смена шаблона —
    # клон с GitHub и развёртывание. И то и другое бывает по несколько минут.
    "change-mode": 900,
    "change-template": 900,
    # Ленивый Pro одним действием: сертификат, сайт, сборка образов двух профилей, панель, ключи.
    "lazy-setup": 1800,
    # Линия на UDP 443: пересоздание двух контейнеров (выбранная линия и та, что освобождает 443) —
    # договор 0.6.0, уточнения 28.09: 600 с.
    "pro-line": 600,
    # «Добавить сразу несколько» (до 100 человек): ключи каждому, на сотню — минута-две; запас — как у установки.
    "users-add-bulk": 900,
    # «Удалить сразу несколько» (до 100): применение к контейнерам пачками по 10 — до минуты на сотню; запас тот же.
    "users-del-bulk": 900,
    # «Перезапустить Docker» (DK-02): служба — до полутора минут, затем каждый профиль с соседями и goWARP.
    "docker-restart": 600,
    # Модуль ядра AmneziaWG (KMOD_PLAN этап Б, CONTRACT §4.7a): проверка — apt-get -s без изменений; установка — ожидание
    # apt до 10 минут, пакеты, сборка 1–3 минуты, самопроверка до 5; перевод — по профилю с ожиданием людей до 3 минут;
    # удаление — тот же перевод на программу и dkms remove. Ход — kmod-status.progress, раз в несколько секунд.
    "kmod-check": 120, "kmod-install": 1800, "kmod-engine": 900, "kmod-remove": 900,
}
# Действия без замка — совпадают с readonly: true в lib/actions.json. Список
# дублируем, а не читаем из файла при импорте: у бота на стенде может не быть
# каталога действий, а знание «что читает, что пишет» нужно ему всегда.
READONLY_ACTIONS = {
    "status", "profiles-status", "quality", "traffic", "logs-tail", "logs-status",
    "profile-params", "user-list", "user-show", "user-key", "backup-list",
    "import-scan", "upstream-check", "site-check", "miniapp-status", "preflight",
    "agent-list", "agent-show", "mcp-http-status", "share-list", "edge-status",
    # Страница подключения и зеркало сборок (docs/CLIENTS.md §9): списки читают, не пишут.
    "clients-list", "page-list", "mirror-list",
    # Ленивый Pro: проверка домена и портов — только чтение (договор 0.6.0)
    "lazy-check",
    # «Удалить сразу несколько»: кого задевает выбор — только чтение
    "users-del-bulk-preview",
    # «Удалить профиль»: чьи страницы подключения перестанут работать — только чтение (PROFILE-REMOVE-PAGES)
    "profile-remove-preview",
    # Подписка: состояние без адреса и показ адресов ещё раз — чтение (docs/SUBSCRIPTION.md)
    "sub-list", "sub-show",
    # Модуль ядра: состояние (и ход долгого действия) и проверка хоста — только чтение, замка не берут
    "kmod-status", "kmod-check",
}

# Один замок на мутации из этого процесса: два админа, нажавшие «Установить
# профиль» в одну секунду, иначе гонятся за flock моста и получают
# lock_timeout вместо очереди. Чтение (status, user-list) замок не берёт.
_BOT_ACTION_LOCK = asyncio.Lock()

# asyncio.create_task() держит задачу слабой ссылкой: без хранения её может
# собрать GC до завершения. Держим в множестве до done-callback.
_BACKGROUND_TASKS: set = set()


def spawn_task(coro) -> "asyncio.Task":
    task = asyncio.create_task(coro)
    _BACKGROUND_TASKS.add(task)
    task.add_done_callback(_BACKGROUND_TASKS.discard)
    return task


async def sh(*args: str, timeout: int = 60, env: Optional[Dict[str, str]] = None,
             input_data: Optional[bytes] = None) -> Tuple[int, str, str]:
    """Асинхронный запуск команды. Возвращает (код, stdout, stderr).

    input_data — байты в stdin процесса. Так уходит только секрет (ключ человека
    у user-attach-key): в argv его видно в `ps` любому процессу на сервере. Без
    input_data stdin закрыт, как и было: мост не должен ждать ввода с терминала.
    """
    try:
        process = await asyncio.create_subprocess_exec(
            *args,
            stdin=asyncio.subprocess.PIPE if input_data is not None else asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            start_new_session=True,
            env=env,
        )
    except (OSError, ValueError) as e:
        return (-1, "", str(e))
    try:
        stdout, stderr = await asyncio.wait_for(process.communicate(input_data), timeout=timeout)
        return (
            process.returncode if process.returncode is not None else -1,
            stdout.decode("utf-8", errors="replace"),
            stderr.decode("utf-8", errors="replace"),
        )
    except asyncio.TimeoutError:
        # Сначала мягко: SIGTERM всей группе (иначе внуки docker/jq остаются
        # сиротами и держат замок), до 5 с на уборку, потом SIGKILL. Жёсткий
        # kill посреди записи users.json оставлял бы битый файл — мост пишет
        # атомарно, но trap'ам нужно время убрать временные файлы.
        try:
            os.killpg(os.getpgid(process.pid), signal.SIGTERM)
        except Exception:  # noqa: BLE001
            try:
                process.terminate()
            except Exception:  # noqa: BLE001
                pass
        try:
            await asyncio.wait_for(process.wait(), timeout=5)
        except Exception:  # noqa: BLE001
            logger.warning("sh(): process group did not exit on SIGTERM, sending SIGKILL")
            try:
                os.killpg(os.getpgid(process.pid), signal.SIGKILL)
            except Exception:  # noqa: BLE001
                try:
                    process.kill()
                except Exception:  # noqa: BLE001
                    pass
            try:
                await process.wait()
            except Exception:  # noqa: BLE001
                pass
        return (-1, "", "timeout")


# Действия, чей ответ договор описывает формой {"ok": true, "data": {…}} (0.4.7, name-suggest): её бот
# читает наравне с обычной — и только у них. У остальных строка с ok без status (отчёт зависимостей
# deps_report_json, сверка ключей сервера) — не ответ моста: упавшее действие, успевшее напечатать
# такую, должно остаться ошибкой транспорта, а не «успехом».
BRIDGE_OK_SHAPE_ACTIONS = ("name-suggest",)


def _is_ok_shape(obj: Dict[str, Any]) -> bool:
    return (obj.get("ok") is True and isinstance(obj.get("data"), dict)) or \
        (obj.get("ok") is False and "error" in obj)


def _from_ok_shape(obj: Dict[str, Any]) -> Dict[str, Any]:
    """Ответ вида {"ok": true, "data": {…}} → обычная форма моста: status, поля data в корне.
    {"ok": false, "error": {code, message}} → status=error с кодом."""
    data = obj.get("data")
    out: Dict[str, Any] = dict(data) if isinstance(data, dict) else {}
    out.update({k: v for k, v in obj.items() if k not in ("ok", "data", "error")})
    if obj.get("ok") is True:
        out["status"] = "success"
        if isinstance(data, dict):
            out["data"] = data
        return out
    out["status"] = "error"
    err = obj.get("error")
    if isinstance(err, dict):
        out.setdefault("code", err.get("code"))
        out.setdefault("message", err.get("message"))
    elif isinstance(err, str) and err:
        out.setdefault("code", err)
    return out


def parse_bridge_output(stdout: str, ok_shape: bool = False) -> Optional[Dict[str, Any]]:
    """Последняя строка stdout, которая разбирается как JSON-объект со status.

    Контракт (§0 п.3) гарантирует JSON только ПОСЛЕДНЕЙ строкой; всё
    остальное в stdout — нарушение, но не повод ронять вызов: идём с конца
    и берём первый же объект. Первый попавшийся JSON брать нельзя — модуль
    мог напечатать свой промежуточный объект. ok_shape — у действия из
    BRIDGE_OK_SHAPE_ACTIONS ответ {"ok": …, "data"|"error": …} тоже ответ:
    он приводится к обычной форме.
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
        if ok_shape and isinstance(obj, dict) and _is_ok_shape(obj):
            return _from_ok_shape(obj)
    return None


def build_bridge_argv(action: str, params: Dict[str, Any]) -> List[str]:
    """argv моста: подчёркивания в имени параметра → дефисы (quota_gb → --quota-gb).

    None — параметр не передаём; пустая строка передаётся как --k= —
    для endpoint-set это законное «вернуть IP сервера», для
    profile-set-param — «убрать параметр».
    """
    argv = [ACTION_BIN, "--action=%s" % action, "--json"]
    for k, v in params.items():
        if v is None:
            continue
        argv.append("--%s=%s" % (k.replace("_", "-"), v))
    return argv


# Действия, которым мост читает данные из stdin, а не из argv (docs/CONTRACT.md,
# user-attach-key): ключ человека — ссылка vpn:// или текст .conf. Остальным stdin
# не нужен вовсе: случайно переданный секрет не должен уйти мосту ни одним путём.
BRIDGE_STDIN_ACTIONS = ("user-attach-key",)


async def run_bot_action(action: str, timeout: Optional[int] = None,
                         who: Optional[int] = None, stdin: Optional[str] = None,
                         who_arg: Optional[str] = None, **params: Any) -> Dict[str, Any]:
    """Вызвать `install.sh --action=<имя> --json --k=v` и вернуть его JSON.

    Всегда dict со status: ошибки запуска и отсутствие JSON превращаются в
    {"status": "error", "code": "transport"|"timeout", …}, чтобы экранам не
    приходилось различать «мост ответил ошибкой» и «моста нет».

    stdin — секрет для действий из BRIDGE_STDIN_ACTIONS: уходит в stdin моста,
    не в argv и не в лог (вывод моста у таких действий в лог тоже не пишется).

    who — кто зовёт (GOAMNEZIA_WHO для аудита); who_arg — параметр моста --who= у действий, которым он нужен в
    ответе (короткие ссылки: кто попросил замену, кто решил запрос).
    """
    if timeout is None:
        timeout = BRIDGE_TIMEOUT_BY_ACTION.get(action, BRIDGE_TIMEOUT_DEFAULT)
    secret_in = action in BRIDGE_STDIN_ACTIONS
    if stdin is not None and not secret_in:
        logger.error("bridge %s: stdin is accepted only by %s — call refused", action, ", ".join(BRIDGE_STDIN_ACTIONS))
        return {"status": "error", "code": "bad_arg", "message": "", "action": action}
    if who_arg is not None:
        params["who"] = who_arg
    argv = build_bridge_argv(action, params)
    env = dict(os.environ)
    # Токену бота в окружении моста делать нечего: install.sh его не читает, а
    # любой его дочерний процесс (docker, jq) не должен даже иметь возможность
    # напечатать его в лог.
    env.pop("BOT_TOKEN", None)
    # Кто зовёт — для аудит-лога моста (users.sh пишет ${GOAMNEZIA_WHO:-ssh}).
    env["GOAMNEZIA_WHO"] = "bot:%s" % who if who else "bot"
    env["GOAMNEZIA_CALLER"] = "bot"
    # Язык ответа моста — язык этого человека в боте, на один вызов (L-24): админ с английским на
    # русском сервере получает тексты результата по-английски. Без who — язык установки.
    if who:
        call_lang = get_user_lang(who)
        if call_lang in ("ru", "en"):
            env["GOAMNEZIA_CALL_LANG"] = call_lang
    code, stdout, stderr = await sh(*argv, timeout=timeout, env=env,
                                    input_data=stdin.encode("utf-8") if stdin is not None else None)
    data = parse_bridge_output(stdout, ok_shape=action in BRIDGE_OK_SHAPE_ACTIONS)
    if data is not None:
        if code not in (0, None) and data.get("status") == "success":
            logger.warning("bridge %s: rc=%s with status=success", action, code)
        return data
    tail = (stderr or "")[-300:]
    if stderr == "timeout":
        logger.error("bridge %s: timeout after %ss", action, timeout)
        return {"status": "error", "code": "timeout", "message": "", "action": action,
                "timeout_s": timeout}
    if secret_in:
        # Мост, упавший на разборе ключа, мог напечатать его кусок: хвосты вывода — мимо лога.
        logger.error("bridge %s: no JSON, rc=%s (output not logged: a key went on stdin)", action, code)
    elif action.startswith(SHORT_ACTION_PREFIX):
        # Ответы коротких ссылок несут код — секрет того же порядка, что адрес подписки: вывод упавшего моста мимо лога.
        logger.error("bridge %s: no JSON, rc=%s (output not logged: short link codes)", action, code)
    else:
        logger.error("bridge %s: no JSON, rc=%s, stdout=%r, stderr=%r",
                     action, code, (stdout or "")[-300:], tail)
    return {"status": "error", "code": "transport", "message": "", "action": action, "rc": str(code)}


def bridge_ok(r: Dict[str, Any]) -> bool:
    return isinstance(r, dict) and r.get("status") == "success"


# ============================================================================
# ЧИСТЫЕ ПОМОЩНИКИ: форматирование, значки, страницы, QR, typed-confirm
# ============================================================================

def human_bytes(n: Any, user_id: Optional[int] = None) -> str:
    """Байты по-человечески; единицы — из словаря (Б/КБ/МБ/ГБ)."""
    try:
        n = int(n or 0)
    except (TypeError, ValueError):
        n = 0
    units = ("unit_b", "unit_kb", "unit_mb", "unit_gb", "unit_tb")
    value = float(n)
    idx = 0
    while value >= 1024 and idx < len(units) - 1:
        value /= 1024.0
        idx += 1
    if idx == 0:
        return "%d %s" % (n, _t(user_id, units[0]))
    return "%.1f %s" % (value, _t(user_id, units[idx]))


def parse_iso(ts: str) -> Optional[_dt.datetime]:
    """ISO-8601 UTC из users.json (2026-09-08T12:00:00Z) → datetime или None."""
    ts = (ts or "").strip()
    if not ts:
        return None
    try:
        return _dt.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=_dt.timezone.utc)
    except ValueError:
        pass
    try:
        parsed = _dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=_dt.timezone.utc)
    except ValueError:
        return None


def user_state(rec: Dict[str, Any], now: Optional[_dt.datetime] = None) -> str:
    """on | off | exp | lim — как в SSH-меню (_users_render_list в install.sh)."""
    if not isinstance(rec, dict):
        return "on"
    if not rec.get("enabled", True):
        return "off"
    now = now or _dt.datetime.now(_dt.timezone.utc)
    exp = parse_iso(str(rec.get("expires") or ""))
    if exp is not None and exp < now:
        return "exp"
    traffic = rec.get("traffic") or {}
    used = int(traffic.get("rx") or 0) + int(traffic.get("tx") or 0)
    quota = int(rec.get("quota_bytes") or 0)
    if quota > 0 and used >= quota:
        return "lim"
    return "on"


USER_ICONS = {"on": "●", "off": "○", "exp": "⏳", "lim": "▮"}


def user_icon(rec: Dict[str, Any], now: Optional[_dt.datetime] = None) -> str:
    return USER_ICONS.get(user_state(rec, now), "·")


def profile_icon(state: str) -> str:
    """● работает · ↻ перезапускается · ○ остановлен · ⚠ Docker не отвечает · ✗ нет контейнера
    (как _profile_icon в SSH-меню). Это значки УСТАНОВЛЕННОГО профиля; у неустановленного
    свой — PROFILE_NOT_INSTALLED_ICON."""
    return {"running": "●", "restarting": "↻", "exited": "○",
            "docker_unreachable": "⚠"}.get(str(state or ""), "✗")


# Профиль не ставили вовсе — это не поломка, и «✗» здесь пугал: у SSH на том же
# месте легенда «✗ нет контейнера», и человек видел аварию там, где просто пусто.
PROFILE_NOT_INSTALLED_ICON = "◌"

# Состояние профиля → ключ словаря. docker_unreachable («демон Docker не
# отвечает») НЕ сводим к not_installed: на сервере с автообновлениями пакет
# docker.io обновляется без перезапуска демона, и раньше бот в этом случае
# показывал живые профили выключенными. Так же и пропавший контейнер (missing) и
# перезапуск: раньше оба читались «не установлен», и человек шёл ставить профиль
# заново — мост отвечал «уже установлен» (находка T22). У профиля из status он
# установлен всегда; всё незнакомое — «нет контейнера», как у SSH.
PROFILE_STATE_KEYS = {"running": "running", "exited": "stopped", "restarting": "state_restarting",
                      "docker_unreachable": "state_docker_unreachable"}


def profile_state_key(state: Any) -> str:
    return PROFILE_STATE_KEYS.get(str(state or ""), "state_missing")


USERS_PER_PAGE = 8


def paginate(items: List[Any], page: int, per_page: int = USERS_PER_PAGE) -> Tuple[List[Any], int, int]:
    """Срез страницы → (элементы, номер страницы, всего страниц); page зажимается в границы."""
    per_page = max(1, int(per_page))
    pages = max(1, (len(items) + per_page - 1) // per_page)
    try:
        page = int(page)
    except (TypeError, ValueError):
        page = 0
    page = max(0, min(page, pages - 1))
    return items[page * per_page:(page + 1) * per_page], page, pages


def users_sorted(users: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """admin первым (его создаёт мастер установки), остальные по имени."""
    return sorted((u for u in users if isinstance(u, dict) and u.get("name")),
                  key=lambda u: (str(u.get("name")) != "admin", str(u.get("name")).lower()))


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def decode_png_b64(value: Any) -> Optional[bytes]:
    """base64 → байты PNG; всё, что не PNG, отбрасываем (мост мог вернуть пусто)."""
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        raw = base64.b64decode(value.strip(), validate=False)
    except (ValueError, TypeError):
        return None
    if not raw.startswith(PNG_SIGNATURE):
        return None
    return raw


def write_qr_files(bundle: Dict[str, Any], directory: str) -> Tuple[Optional[str], List[str]]:
    """PNG из ответа user-key → файлы в каталоге → (путь conf.png, [пути чанков vpn]).

    Каталог создаёт вызывающий через tempfile.mkdtemp (0700) и удаляет в
    finally: в картинке .conf лежит приватный ключ, ей нечего делать в /tmp
    дольше, чем длится отправка.
    """
    conf_path = None
    vpn_paths: List[str] = []
    png = decode_png_b64(bundle.get("qr_conf_png_b64"))
    if png:
        conf_path = os.path.join(directory, "conf.png")
        with open(conf_path, "wb") as fh:
            fh.write(png)
        os.chmod(conf_path, 0o600)
    chunks = bundle.get("qr_vpn_png_b64")
    if isinstance(chunks, list):
        for idx, item in enumerate(chunks, 1):
            png = decode_png_b64(item)
            if not png:
                continue
            path = os.path.join(directory, "vpn-%02d.png" % idx)
            with open(path, "wb") as fh:
                fh.write(png)
            os.chmod(path, 0o600)
            vpn_paths.append(path)
    return conf_path, vpn_paths


class TypedConfirm:
    """Подтверждение разрушительного действия набором фразы, с TTL.

    Кнопка «Да» нажимается по инерции; фраза вида `DELETE anna` — нет. Запись
    живёт TTL секунд (по умолчанию 60): оставленный в чате вопрос не должен
    сработать через час от случайного сообщения. Хранится в памяти процесса:
    рестарт бота = отмена всех ожиданий, что для подтверждений и нужно.
    """

    def __init__(self, ttl: float = 60.0, now: Optional[Callable[[], float]] = None):
        self.ttl = float(ttl)
        self._now = now or time.monotonic
        self._pending: Dict[int, Dict[str, Any]] = {}
        # Принятая фраза: (когда, сообщение с её вопросом) — «Отмена» узнаёт свой вопрос по сообщению (RB3-1).
        self._accepted: Dict[int, Tuple[float, Any]] = {}

    def arm(self, user_id: int, kind: str, target: str, phrase: str,
            extra: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        rec = {"kind": kind, "target": target, "phrase": phrase,
               "until": self._now() + self.ttl, "extra": dict(extra or {})}
        self._pending[int(user_id)] = rec
        return rec

    def pending(self, user_id: int) -> Optional[Dict[str, Any]]:
        rec = self._pending.get(int(user_id))
        if rec is None:
            return None
        if self._now() > rec["until"]:
            self._pending.pop(int(user_id), None)
            return None
        return rec

    def check(self, user_id: int, text: str) -> Tuple[str, Optional[Dict[str, Any]]]:
        """→ ("ok", запись) | ("mismatch", запись) | ("expired", None) | ("none", None)."""
        rec = self._pending.get(int(user_id))
        if rec is None:
            return "none", None
        if self._now() > rec["until"]:
            self._pending.pop(int(user_id), None)
            return "expired", None
        # Сравнение точное после обрезки пробелов: фраза копируется из <code>.
        if (text or "").strip() == rec["phrase"]:
            self._pending.pop(int(user_id), None)
            self._accepted[int(user_id)] = (self._now(), rec.get("msg"))
            return "ok", rec
        return "mismatch", rec

    def cancel(self, user_id: int) -> None:
        self._pending.pop(int(user_id), None)

    def attach(self, user_id: int, chat_id: Any, message_id: Any) -> None:
        """Запомнить сообщение с вопросом (на нём «Отмена»): фраза принята — с него снимут кнопки (BL-1 / RB-2)."""
        rec = self._pending.get(int(user_id))
        if rec is not None and message_id is not None:
            rec["msg"] = (chat_id, message_id)

    def accepted_recently(self, user_id: int, msg: Any = None, window: float = 600.0) -> bool:
        """«Отмена» нажата на вопросе, фраза которого принята не раньше window секунд назад: она уже ничего не отменит.
        Только на том же сообщении (RB3-1): истёкший или новый вопрос по-прежнему отменяется."""
        acc = self._accepted.get(int(user_id))
        if acc is None or msg is None or acc[1] is None or tuple(acc[1]) != tuple(msg):
            return False
        rec = self._pending.get(int(user_id))
        if rec is not None and rec.get("msg") == acc[1]:
            return False        # на том же сообщении уже новый вопрос
        return self._now() - acc[0] <= window


TYPED_CONFIRM_TTL = 60
CONFIRM = TypedConfirm(ttl=TYPED_CONFIRM_TTL)


def confirm_phrase(kind: str, target: str) -> str:
    """Фраза подтверждения: глагол ЗАГЛАВНЫМИ + цель, всегда латиницей."""
    verb = {"user-del": "DELETE", "users-del-bulk": "DELETE", "profile-remove": "REMOVE", "profile-regen": "REGEN",
            "backup-restore": "RESTORE", "agent-del": "DELETE",
            "upstream-update": "UPDATE", "upstream-rollback": "ROLLBACK",
            # Ремонт контейнера на закреплённом образе: после сорвавшегося
            # обновления это второй выход наряду с восстановлением из копии.
            "core-update": "REPAIR",
            # Цель у смены шаблона — сам сайт: id шаблона бывает 120 символов,
            # и набирать его руками было бы издевательством, а не защитой.
            "change-mode": "MODE", "change-template": "TEMPLATE",
            # Ленивый Pro: цель — домен (punycode, латиницей), на который всё встанет
            "lazy-setup": "LAZY",
            # Линия на UDP 443: LINE <профиль>; подхваченный у приложения — ещё и MOVE <профиль> (ACC-2)
            "pro-line": "LINE", "pro-line-adopted": "MOVE",
            # Смена подсети профиля с людьми приложения без ключа на сервере (SUBNET-01, ACC-2): SUBNET <профиль>
            "profile-subnet-adopted": "SUBNET",
            # «Исправить S4» у подхваченного профиля с людьми приложения без ключа на сервере (S4-FIX, ACC-2): S4 <профиль>
            "profile-fix-s4-adopted": "S4",
            # «Переставить на 2.0» (DUP-LINE-01): профиль удаляется и ставится заново — RELINE <профиль>, как REMOVE
            "profile-reline": "RELINE",
            # Подписка: новый адрес вместо прежнего у всех роутеров разом и отзыв (docs/SUBSCRIPTION.md)
            "sub-rotate": "ROTATE", "sub-revoke": "REVOKE"}.get(kind, kind.upper())
    return "%s %s" % (verb, target)


# Подтверждения действий с профилем (D-5, R-3 проверки 15.10; решение координатора 15.10): отправляют порт профиля —
# его пользователь видит в подписи («AmneziaWG 3.1 · порт 6714») и карточке, а имя места (awg3) — нигде. Фраза — сам
# порт, «6714»; что подтверждается — по записи CONFIRM (kind). Цель записи и мосту — по-прежнему профиль.
PROFILE_CONFIRM_KINDS = frozenset(("profile-remove", "profile-regen", "profile-reline", "profile-subnet-adopted",
                                   "profile-fix-s4-adopted", "upstream-update", "upstream-rollback", "core-update",
                                   "pro-line", "pro-line-adopted"))


async def typed_phrase(kind: str, target: str) -> str:
    """Фраза подтверждения для CONFIRM.arm: у действий с профилем — его порт («6714»), порт неизвестен — «ГЛАГОЛ <профиль>»."""
    if kind in PROFILE_CONFIRM_KINDS and valid_profile(target):
        status = await get_status()
        port = _port_of(profile_info(status, target)) if bridge_ok(status) else 0
        if port:
            return str(port)
    return confirm_phrase(kind, target)


def confirm_type_text(user_id: Optional[int], phrase: str) -> str:
    """Что отправить для подтверждения: порт профиля — своими словами («отправьте порт профиля»), фраза — как была."""
    if phrase.isdigit():
        return _tf(user_id, "confirm_type_port_fmt", esc(phrase), TYPED_CONFIRM_TTL)
    return _tf(user_id, "confirm_type_fmt", esc(phrase), TYPED_CONFIRM_TTL)


# ── Уведомления таймера лимитов: файловая очередь ────────────────────────────

def collect_notify_events(directory: str, limit: int = 50) -> List[Dict[str, Any]]:
    """Прочитать и УДАЛИТЬ файлы событий *.json из очереди (lib/users.sh ga_users_notify).

    Один файл = одно событие = одна строка JSON; файлы .tmp.* ещё пишутся
    мостом (mktemp + mv), их не трогаем. Нечитаемый файл удаляем тоже — иначе
    он вечно всплывал бы на каждом обходе.
    """
    events: List[Dict[str, Any]] = []
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return events
    for name in names:
        if not name.endswith(".json") or name.startswith(".tmp."):
            continue
        path = os.path.join(directory, name)
        try:
            with open(path, "r", encoding="utf-8") as fh:
                raw = fh.read()
        except OSError:
            continue
        try:
            os.unlink(path)
        except OSError:
            pass
        try:
            obj = json.loads(raw.strip().splitlines()[0]) if raw.strip() else None
        except (ValueError, IndexError):
            obj = None
        if isinstance(obj, dict):
            events.append(obj)
        if len(events) >= limit:
            break
    return events


def _ntf_date(value: Any) -> str:
    """Дата в уведомлении — «01.10.2026», а не ISO «2026-10-01T00:00:00Z»; непонятное — как есть."""
    parsed = parse_iso(str(value or ""))
    return parsed.strftime("%d.%m.%Y") if parsed else str(value or "")


# Почему не вышел перезапуск Docker (DK-02, код ядра → слова бота): ответ моста docker-restart и событие сторожа
# docker_restarted несут один и тот же код.
DOCKER_RESTART_WHY = {"docker_restart_failed": "dkr_why_failed", "docker_restart_timeout": "dkr_why_timeout",
                      "docker_still_stale": "dkr_why_still_stale"}


def docker_restart_why(user_id: Optional[int], r: Dict[str, Any]) -> str:
    """Причина отказа перезапуска Docker словами: служба не перезапустилась, демон не ответил, служба осталась
    старой — или какие профили не поднялись; незнакомый код — слова ядра (или сам код)."""
    code = str(r.get("code") or "")
    if code in DOCKER_RESTART_WHY:
        return _t(user_id, DOCKER_RESTART_WHY[code])
    failed = [f.get("profile") for f in (r.get("failed") if isinstance(r.get("failed"), list) else [])
              if isinstance(f, dict) and f.get("profile")]
    if code == "restart_failed" and failed:
        return _tf(user_id, "dkr_why_profiles_fmt", html.escape(profile_names(user_id, failed)))
    return html.escape(str(r.get("reason") or r.get("message") or code or "?"))


def format_notify_event(user_id: Optional[int], ev: Dict[str, Any]) -> str:
    """Текст уведомления по событию: лимит исчерпан, срок вышел, контейнер упал."""
    event = str(ev.get("event") or "")
    name = html.escape(str(ev.get("user") or ev.get("name") or "?"))
    label = html.escape(str(ev.get("label") or ""))
    who = "%s (%s)" % (name, label) if label and label != name else name
    if event == "quota_exceeded":
        used = human_bytes(ev.get("used_bytes"), user_id)
        quota = human_bytes(ev.get("quota_bytes"), user_id)
        return _tf(user_id, "ntf_quota_fmt", who, used, quota)
    if event == "expired":
        return _tf(user_id, "ntf_expired_fmt", who, html.escape(_ntf_date(ev.get("expires"))))
    # Предупреждения ядра ДО выключения (lib/users.sh, тик лимитов): срок кончается в ближайшие дни,
    # израсходовано 80 % лимита. Продлить заранее — значит без перерыва у человека.
    if event == "expiry_soon":
        return _tf(user_id, "ntf_expiry_soon_fmt", who, html.escape(_ntf_date(ev.get("expires"))))
    if event == "quota_80":
        used = human_bytes(ev.get("used_bytes"), user_id)
        quota = human_bytes(ev.get("quota_bytes"), user_id)
        return _tf(user_id, "ntf_quota80_fmt", who, used, quota)
    if event in ("container_down", "profile_down"):
        target = html.escape(str(ev.get("container") or ev.get("profile") or "?"))
        return _tf(user_id, "ntf_container_fmt", target)
    if event == "container_restarted":
        # Сторож goamnezia-watch: контейнер был остановлен или не отвечал и его
        # подняли (ok=true) — или не смогли (ok=false, нужен человек).
        container = html.escape(str(ev.get("container") or "?"))
        profile = html.escape(profile_name(user_id, ev.get("profile")) or "?")
        if ev.get("ok") in (True, "true"):
            return _tf(user_id, "ntf_watch_restarted_fmt", container, profile)
        return _tf(user_id, "ntf_watch_failed_fmt", container, profile)
    if event == "container_missing":
        return _tf(user_id, "ntf_container_missing_fmt", html.escape(str(ev.get("container") or "?")),
                   html.escape(profile_name(user_id, ev.get("profile")) or "?"))
    if event == "docker_unreachable":
        # Сторож не смог узнать состояние контейнеров: демон Docker не отвечает.
        # Контейнеры при этом обычно живы — восстановление из бэкапа НЕ нужно.
        profiles = ev.get("profiles") if isinstance(ev.get("profiles"), list) else []
        return _tf(user_id, "ntf_docker_unreachable_fmt",
                   html.escape(", ".join(profile_name(user_id, x) for x in profiles) or "—"),
                   html.escape(str(ev.get("api_client") or "?")),
                   html.escape(str(ev.get("api_daemon") or "?")))
    if event in ("docker_stale", "docker_restarting"):
        # Пакет Docker обновлён, а служба старая (DK-02): сторож перезапустит её сам, когда к VPN никто не подключён.
        # docker_stale — люди подключены, ждём (под сообщением кнопка «Перезапустить Docker»); docker_restarting —
        # никого нет, перезапуск начался. Версии API — на случай, когда бинарь на диске не узнать.
        old = html.escape(str(ev.get("daemon_label") or ev.get("daemon_version") or ev.get("daemon_api") or "?"))
        new = html.escape(str(ev.get("binary_label") or ev.get("binary_version") or ev.get("client_api") or "?"))
        return _tf(user_id, "ntf_docker_restarting_fmt" if event == "docker_restarting" else "ntf_docker_stale_fmt",
                   new, old)
    if event == "docker_restarted":
        # Итог перезапуска сторожем: за сколько секунд и какая служба теперь — или что не вышло и как вручную.
        dur = ev.get("duration_s")
        dur = dur if isinstance(dur, int) and not isinstance(dur, bool) else "?"
        if ev.get("ok") in (True, "true"):
            done = ev.get("restarted") if isinstance(ev.get("restarted"), list) else []
            return _tf(user_id, "ntf_docker_restarted_fmt", html.escape(str(dur)),
                       html.escape(str(ev.get("daemon_after_label") or ev.get("daemon_after") or "?")),
                       html.escape(profile_names(user_id, done) or "—"))
        hours = ev.get("retry_hours")
        hours = hours if isinstance(hours, int) and not isinstance(hours, bool) else 6
        return _tf(user_id, "ntf_docker_restart_failed_fmt", docker_restart_why(user_id, ev), html.escape(str(hours)))
    if event == "agent_compromised":
        # Обнаружен клон: сервер увидел ключ, которого у настоящего агента быть уже
        # не может. Два времени и два адреса — чтобы владелец решал по фактам, а не
        # по догадке; кнопки под сообщением ставит notify_keyboard.
        agent = html.escape(str(ev.get("agent") or "?"))
        who_agent = html.escape(str(ev.get("label") or "")) or agent
        args = (agent, who_agent,
                html.escape(str(ev.get("clone_at") or "?")), html.escape(str(ev.get("clone_ip") or "?")),
                html.escape(str(ev.get("last_used") or "—")), html.escape(str(ev.get("last_ip") or "—")))
        # frozen — удалось ли ЗАМОРОЗИТЬ доступ. Сервер кладёт это в событие честно, и
        # прочитать обязаны мы: при неудаче доступ жив, клон работает дальше, и слово
        # «ЗАМОРОЖЕН» было бы ложью про единственное, что владельцу сейчас важно.
        # Поля нет вовсе (событие от прежней версии сервера) — считаем, что заморожен:
        # так вело себя прежнее сообщение, и выдумывать тревогу на пустом месте незачем.
        if ev.get("frozen") is False:
            return _tf(user_id, "ntf_agent_clone_live_fmt", *args)
        return _tf(user_id, "ntf_agent_clone_fmt", *args)
    if event in ("edge_ip_dark", "edge_ip_back"):
        # Несколько адресов сервера (docs/EDGEIPS.md): адрес замолчал при живых соседях, а вчера в
        # этот час принимал, — похоже на блокировку именно его. Тревога — одна на переход,
        # напоминание (reminder) — не чаще раза в сутки; «снова принимает» — трафик вернулся.
        ip = html.escape(str(ev.get("ip") or "?"))
        since = html.escape(str(ev.get("since") or "?").replace("T", " ").rstrip("Z"))
        if event == "edge_ip_back":
            return _tf(user_id, "ntf_edge_ip_back_fmt", ip, since)
        users = ev.get("users")
        users = users if isinstance(users, int) and not isinstance(users, bool) else "?"
        key = "ntf_edge_ip_dark_again_fmt" if ev.get("reminder") is True else "ntf_edge_ip_dark_fmt"
        return _tf(user_id, key, ip, since, html.escape(str(users)))
    if event == "agent_enrolled":
        # Переходник привязан одноразовым кодом. Свою привязку владелец узнает в тот же
        # миг, а чужая (код утёк за свои 10 минут) — повод перевыпустить доступ сразу:
        # прежняя привязка от этого перестаёт действовать (MCP_ROTATION §7).
        agent = html.escape(str(ev.get("agent") or "?"))
        who_agent = html.escape(str(ev.get("label") or "")) or agent
        storage = "ag_storage_tpm" if ev.get("storage") == "tpm" else "ag_storage_file"
        return _tf(user_id, "ntf_agent_enrolled_fmt", agent, who_agent,
                   html.escape(str(ev.get("ip") or "?")), _t(user_id, storage))
    if event == "server_clock_jump":
        # Часы сервера прыгнули: переходники промахнутся мимо плавающего пути, пока не
        # сверятся заново (§3). Это они переживут сами, а повторяющийся прыжок — сломанная
        # синхронизация времени, от которой зависят и сроки доступов.
        delta = ev.get("delta_s")
        shown = ("%+d" % delta) if isinstance(delta, int) and not isinstance(delta, bool) else "?"
        return _tf(user_id, "ntf_server_clock_jump_fmt", html.escape(shown))
    if event in ("agent_first_use", "agent_new_ip", "agent_token_failed"):
        # Доступы агентов (server.py --http): владелец должен узнать, что ключом
        # воспользовались, — и особенно что им воспользовались с чужого адреса.
        # Ни адреса доступа, ни токена в событии нет: чат не место для ключа.
        agent = html.escape(str(ev.get("agent") or "?"))
        who_agent = html.escape(str(ev.get("label") or "")) or agent
        ip = html.escape(str(ev.get("ip") or "?"))
        if event == "agent_first_use":
            return _tf(user_id, "ntf_agent_first_fmt", agent, who_agent, ip)
        if event == "agent_new_ip":
            return _tf(user_id, "ntf_agent_new_ip_fmt", agent, who_agent, ip)
        return _tf(user_id, "ntf_agent_token_fmt", agent, who_agent, ip)
    if event in ("agent_expiring", "agent_expired"):
        # Срок доступа. Истёкший доступ отвечает отказом молча, и без этой строки
        # владелец видит «агент сломался» вместо «срок вышел». Продление живёт в
        # SSH-меню (agents_extend) и не трогает ни адрес, ни токен — так и пишем,
        # чтобы человек не перевыпускал доступ и не перенастраивал клиента зря.
        agent = html.escape(str(ev.get("agent") or "?"))
        who_agent = html.escape(str(ev.get("label") or "")) or agent
        expires = html.escape(str(ev.get("expires") or "—"))
        if event == "agent_expiring":
            left = ev.get("days_left")
            return _tf(user_id, "ntf_agent_expiring_fmt", agent, who_agent,
                       html.escape(str(left if left is not None else "?")), expires)
        return _tf(user_id, "ntf_agent_expired_fmt", agent, who_agent, expires,
                   html.escape(str(ev.get("ip") or "—")))
    if event == "agent_rate_limited":
        # Предел частоты: доступ ЖИВ, отклонены лишние вызовы. Об этом сказать
        # обязательно — иначе тревога читается как «доступ заморожен», и владелец
        # идёт перевыпускать ключ вместо того, чтобы унять зациклившегося агента.
        agent = html.escape(str(ev.get("agent") or "?"))
        who_agent = html.escape(str(ev.get("label") or "")) or agent
        return _tf(user_id, "ntf_agent_rate_fmt", agent, who_agent,
                   html.escape(str(ev.get("calls") if ev.get("calls") is not None else "?")),
                   html.escape(str(ev.get("window_s") if ev.get("window_s") is not None else "?")),
                   html.escape(str(ev.get("ip") or "—")))
    if event in ("cert_expiring", "cert_unknown"):
        # Сертификат — общий корень сразу трёх вещей: сайта, панели на домене и
        # всего транспорта доступов агентов. Поэтому тревога называет не только
        # срок, но и что именно умрёт разом и куда идти чинить. Путь починки у
        # Let's Encrypt и у запасного самоподписанного разный — и строки разные:
        # у первого дело обычно в A-записи и 80-м порте, у второго домена нет вовсе.
        kind = str(ev.get("kind") or "")
        domain = html.escape(str(ev.get("domain") or ""))
        if event == "cert_unknown":
            if kind == "selfsigned" or not domain:
                return _t(user_id, "ntf_cert_unknown_ss")
            return _tf(user_id, "ntf_cert_unknown_fmt", domain)
        days = html.escape(str(ev.get("days") if ev.get("days") is not None else "?"))
        expires = html.escape(str(ev.get("expires") or "—"))
        if kind == "selfsigned" or not domain:
            return _tf(user_id, "ntf_cert_expiring_ss_fmt", days, expires)
        return _tf(user_id, "ntf_cert_expiring_fmt", domain, days, expires)
    if event == "dupline_bug":
        # Миграция при обновлении нашла ошибку прошлых версий (DUP-LINE-01): вместо 2.0 встала вторая 3.1. Кнопки —
        # «Исправить» (тот же путь «Переставить на 2.0»: что будет, фраза, итог) и «Позже» (notify_keyboard).
        return dupline_text(user_id, "ntf_dupline_fmt", ev.get("line"), ev.get("from"), ev.get("port"), ev.get("users"))
    if event == "server_ip_changed":
        # Новый адрес уже записан в config.json (lib/amnezia.sh) — тревога не про
        # «почините», а про «выданные ключи без домена больше не соединятся».
        return _tf(user_id, "ntf_server_ip_fmt", html.escape(str(ev.get("old") or "?")),
                   html.escape(str(ev.get("new") or "?")))
    if event == "backup_failed":
        # Суточный проход бэкапа не удался. Опасность не в самой неудаче, а в том,
        # что точка восстановления осталась вчерашней, а человек об этом не знает.
        return _tf(user_id, "ntf_backup_failed_fmt", html.escape(str(ev.get("code") or "?")),
                   html.escape(str(ev.get("message") or "—")))
    if event == "disk_level":
        # Место на диске сменило уровень (ядро шлёт только переход ok → low → critical и обратно, сторож раз в 2 минуты,
        # TAIL-19): те же слова, что строка на главном экране (OPS-06), а при возврате в ok — «снова достаточно».
        level = str(ev.get("level") or "")
        free, pct = _as_int(ev.get("free_mb")), _as_int(ev.get("used_pct"))
        if level == "ok":
            return _tf(user_id, "ntf_disk_ok_fmt", free, pct)
        if level == "critical":
            return "🚨 " + _tf(user_id, "dash_disk_critical_fmt", free, pct)
        # low — и незнакомый уровень от ядра новее: лучше предупредить, чем промолчать
        return "⚠️ " + _tf(user_id, "dash_disk_low_fmt", free, pct)
    if event == "netdeps_dangling":
        # Контейнеры в сети контейнера, которого больше нет (снос версией до 1.0.8, удаление руками): чьи они, не
        # записано, и ядро их не трогает (WRP-06) — текст говорит, как вернуть их руками один раз.
        names = ev.get("containers")
        if isinstance(names, str):
            names = names.split(",")
        if not isinstance(names, list):
            names = []
        return _tf(user_id, "ntf_netdeps_dangling_fmt", html.escape(", ".join(str(n) for n in names if n) or "?"))
    if event == "update_rolled_back":
        # Обновление goAmnezia не встало и откатано (lib/update.sh, находка OPS-02): что не встало, почему и какая
        # версия работает. Вернулось не всё (code_restored/data_restored = false) — отдельная тревога.
        failed = html.escape(str(ev.get("failed_version") or "?"))
        why = html.escape(str(ev.get("reason") or "?"))
        if ev.get("code_restored") is False or ev.get("data_restored") is False:
            return _tf(user_id, "ntf_update_stuck_fmt", failed, why)
        return _tf(user_id, "ntf_update_rolled_back_fmt", failed, why, html.escape(str(ev.get("version") or "?")))
    if event == "upstream_available":
        # Таймер goamnezia-upstream: раз в сутки, без автообновления — человек
        # решает сам в «Обслуживание → Обновления Amnezia».
        cur = html.escape(str(ev.get("client_release_current") or "?"))
        new = html.escape(str(ev.get("client_release_latest") or "?"))
        rows = []
        for item in (ev.get("profiles") if isinstance(ev.get("profiles"), list) else []):
            if isinstance(item, dict) and item.get("update"):
                rows.append("%s: %s → %s" % (html.escape(profile_name(user_id, item.get("profile"))),
                                             html.escape(str(item.get("current_tag") or "?")),
                                             html.escape(str(item.get("available_tag") or "?"))))
        return _tf(user_id, "ntf_upstream_fmt", cur, new, ", ".join(rows) or "—")
    if event == "short_alarm":
        # Короткие ссылки: неверных кодов со всех адресов за час больше сотни — похоже на подбор. Адреса ядро банит само,
        # под сообщением — список банов (notify_keyboard).
        return _tf(user_id, "ntf_short_alarm_fmt", _as_int(ev.get("misses_hour")))
    details = ", ".join("%s=%s" % (html.escape(str(k)), html.escape(str(v)))
                        for k, v in ev.items() if k not in ("event", "ts") and v not in ("", None))
    return _tf(user_id, "ntf_generic_fmt", html.escape(event or "?"), details)


# ── Чтение config.json только для отображения (контракт §6) ──────────────────

def read_config_display() -> Dict[str, Any]:
    """config.json без секретов — подсеть, MTU, путь мини-аппа. Только чтение."""
    try:
        with open(GOAMNEZIA_CONFIG, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def miniapp_url(status: Optional[Dict[str, Any]] = None) -> Optional[str]:
    """Адрес мини-аппа на своём домене или None: путь из status, иначе config.json."""
    status = status or {}
    domain = str(status.get("domain") or "").strip()
    path = str(status.get("miniapp_path") or (status.get("panel") or {}).get("miniapp_path") or "").strip()
    cfg = read_config_display()
    if not path:
        path = str((cfg.get("panel") or {}).get("miniapp_path") or "").strip()
        domain = domain or str(cfg.get("domain") or "").strip()
    path = path.strip("/")
    if not path or not domain:
        return None
    # Путь в конфиге — ещё не адрес. Панель на домене живёт локацией в vhost
    # сайта: ушли из Pro в Lite — vhost'а нет, а путь остался, и кнопка вела бы
    # в чужой 404 (DEFECTS §1.8). Спрашиваем факт: режим с сайтом и доверенный
    # сертификат — то же, что спрашивает ядро у miniapp-on.
    site = status.get("site") if isinstance(status.get("site"), dict) else None
    if site is None:
        site = cfg.get("site") if isinstance(cfg.get("site"), dict) else {}
    mode = str(status.get("mode") or cfg.get("mode") or "lite")
    if mode not in ("pro", "lite_site") or str(site.get("cert") or "") != "letsencrypt":
        return None
    # Длина — как в ядре (ga_site_panel_path_valid, до 160 знаков): путь панели
    # несёт 512 бит и занимает 90 знаков. Предел в 64 знака молча отвергал путь,
    # который выдал сам продукт: кнопка мини-аппа исчезала, а экран бота
    # продолжал писать «панель включена».
    if not re.fullmatch(r"[A-Za-z0-9._-]{4,160}", path) or not HOST_RE.match(domain):
        return None
    return "https://%s/%s/" % (domain, path)


def product_version(status: Optional[Dict[str, Any]] = None) -> str:
    v = str((status or {}).get("version") or "").strip()
    if v:
        return v
    return str(read_config_display().get("version") or "?")


def config_alt_svc() -> bool:
    """options.alt_svc из config.json: в status этого поля нет, а экран его показывает."""
    opts = read_config_display().get("options")
    return bool(opts.get("alt_svc")) if isinstance(opts, dict) else False


def config_lang() -> str:
    """Язык продукта (SSH-меню, панель, умолчание бота) — поле lang в config.json.

    Умолчание бота следует за ним само: i18n ставит config.json выше снимка
    GOAMNEZIA_LANG из .env (находка BOT-11) и читает его при каждом обращении.
    """
    lang = str(read_config_display().get("lang") or "").strip()
    return lang if lang in SUPPORTED_LANGS else ""


# ── Каталог шаблонов сайта ───────────────────────────────────────────────────
# 33 тысячи записей в файле на 14 МБ: списком в чат его не выложить, поэтому
# бот, как и панель, идёт через lib/catalog_tool.py — категории, страницы,
# поиск. Файл читается ЛЕНИВО (первый заход на экран шаблонов) и в отдельном
# потоке: разбор 14 МБ JSON блокирует цикл событий примерно на полсекунды, и
# без потока на это время замирал бы весь бот.
_CATALOG: Any = None
_CATALOG_TRIED = False


def _load_catalog() -> Any:
    """Объект Catalog или None, если каталога на сервере нет (Lite без сайта)."""
    global _CATALOG, _CATALOG_TRIED
    if _CATALOG is not None or _CATALOG_TRIED:
        return _CATALOG
    _CATALOG_TRIED = True
    try:
        spec = importlib.util.spec_from_file_location("ga_catalog_tool", CATALOG_TOOL)
        if spec is None or spec.loader is None:
            return None
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _CATALOG = mod.Catalog(CATALOG_FILE)
        # Пустой каталог (файла нет — Catalog это молча переживает) от рабочего
        # не отличить по объекту, а экран обязан честно сказать «каталога нет».
        if not _CATALOG.categories():
            _CATALOG = None
    except Exception as e:  # noqa: BLE001 — каталог необязателен, экран объяснит
        logger.warning("Каталог шаблонов недоступен: %s", e)
        _CATALOG = None
    return _CATALOG


async def get_catalog() -> Any:
    """Каталог из рабочего потока: разбор 14 МБ не должен вешать цикл событий."""
    return await asyncio.get_running_loop().run_in_executor(None, _load_catalog)


def template_short_key(template_id: str) -> str:
    """sha1[:12] от id — короткий ключ кнопки; карту ключ→id держим в user_data."""
    return hashlib.sha1(str(template_id).encode("utf-8")).hexdigest()[:12]


# ============================================================================
# TELEGRAM: помощники экранов, клавиатуры, ожидание ввода
# ============================================================================

def _uid(update: Optional[Update]) -> Optional[int]:
    if update is None:
        return None
    user = getattr(update, "effective_user", None)
    return user.id if user else None


def esc(value: Any) -> str:
    """html.escape для ВСЕГО динамического: имена, подписи, ответы моста, логи."""
    return html.escape(str(value if value is not None else ""), quote=False)


def note_confirm_message(user_id: Optional[int], message, markup) -> None:
    """Сообщение с кнопкой «Отмена» ожидания фразы (tc_cancel~) — это вопрос подтверждения: запомнить его у ожидания,
    чтобы снять кнопки, когда фраза принята (BL-1 / RB-2). Одно место для всех подтверждений фразой или портом."""
    if user_id is None or message is None or markup is None:
        return
    rows = getattr(markup, "inline_keyboard", None) or []
    if any(str(getattr(b, "callback_data", "") or "").startswith("tc_cancel~") for row in rows for b in row):
        CONFIRM.attach(int(user_id), getattr(message, "chat_id", None), getattr(message, "message_id", None))


async def safe_edit_message(query, text: str, reply_markup=None, parse_mode: Optional[str] = "HTML",
                            disable_web_page_preview: Optional[bool] = True) -> bool:
    """Редактировать сообщение, не падая на «не изменилось» и «уже удалено».

    Экран после фото/документа редактировать нельзя (у сообщения нет
    текста) — тогда шлём новое сообщение, а не роняем обработчик.
    """
    kwargs: Dict[str, Any] = {"reply_markup": reply_markup, "parse_mode": parse_mode}
    if disable_web_page_preview is not None:
        kwargs["disable_web_page_preview"] = disable_web_page_preview
    # Страховка для экранов со списками (страницы подключения, доступы агентов,
    # раздачи): длинный текст Telegram не примет вовсе — режем по строке, а не падаем.
    if parse_mode == "HTML" and len(text) > MESSAGE_SOFT_LIMIT:
        text = clip_lines(text)     # сама проверит видимую длину — сырая с тегами больше
    who = getattr(getattr(query, "from_user", None), "id", None)
    try:
        await query.edit_message_text(text, **kwargs)
        note_confirm_message(who, getattr(query, "message", None), reply_markup)
        return True
    except BadRequest as e:
        err = str(e).lower()
        if "message is not modified" in err:
            note_confirm_message(who, getattr(query, "message", None), reply_markup)
            return True
        if "message to edit not found" in err or "message can't be edited" in err \
                or "there is no text in the message" in err:
            logger.warning("Cannot edit message: %s", e)
            try:
                sent = await query.message.reply_text(text, **kwargs)
                note_confirm_message(who, sent, reply_markup)
                return True
            except Exception as e2:  # noqa: BLE001
                logger.warning("Cannot send replacement message: %s", e2)
                return False
        raise


def btn(text: str, data: str) -> "InlineKeyboardButton":
    """Кнопка с проверкой лимита Telegram: callback_data ≤ 64 байт."""
    if len(data.encode("utf-8")) > 64:
        # Лучше упасть в лог на этапе разработки, чем получить молчащую кнопку
        logger.error("callback_data too long (%d): %s", len(data.encode("utf-8")), data)
        data = data[:64]
    return InlineKeyboardButton(text, callback_data=data)


# Telegram обрезает подпись, которая не влезает в половинную кнопку, и
# делает это молча: «⚙️ Обслуживание» при двух кнопках в ряд превращалось в
# «⚙️ Обсл…ание». В половинную кнопку помещается около 16 символов.
MENU_PAIR_MAX_CHARS = 16


def _menu_rows(rows: list) -> list:
    """Длинную подпись — на всю ширину, короткие — по две в ряд, порядок сохраняется."""
    out: list = []
    pending = None

    def flush():
        nonlocal pending
        if pending is not None:
            out.append([pending])
            pending = None

    for row in rows:
        if len(row) != 2:
            flush()
            out.append(row)
            continue
        if all(len(b.text) <= MENU_PAIR_MAX_CHARS for b in row):
            flush()
            out.append(row)
            continue
        for b in row:
            if len(b.text) > MENU_PAIR_MAX_CHARS:
                flush()
                out.append([b])
            elif pending is None:
                pending = b
            else:
                out.append([pending, b])
                pending = None
    flush()
    return out


def kb(rows: list) -> "InlineKeyboardMarkup":
    return InlineKeyboardMarkup(_menu_rows(rows))


def _back_row(user_id: Optional[int], to: str = "menu_main") -> list:
    return [btn(_t(user_id, "btn_back"), to)]


def back_kb(user_id: Optional[int], to: str = "menu_main") -> "InlineKeyboardMarkup":
    return InlineKeyboardMarkup([_back_row(user_id, to)])


def cancel_kb(user_id: Optional[int], to: str) -> "InlineKeyboardMarkup":
    return InlineKeyboardMarkup([[btn(_t(user_id, "btn_cancel"), to)]])


def error_text(user_id: Optional[int], r: Dict[str, Any]) -> str:
    """Ошибка моста для человека: сообщение + код; коды транспорта — своим текстом."""
    code = str(r.get("code") or "")
    msg = str(r.get("message") or "")
    if code == "not_implemented":
        return _t(user_id, "err_not_implemented")
    if code == "lock_timeout":
        return _t(user_id, "err_lock_timeout")
    if code == "timeout":
        return _tf(user_id, "err_timeout_fmt", r.get("timeout_s") or "")
    if code == "transport":
        return _tf(user_id, "err_transport_fmt", esc(r.get("rc") or "?"))
    if msg:
        return _tf(user_id, "err_bridge_fmt", esc(msg), esc(code or "error"))
    return _tf(user_id, "err_bridge_fmt", _t(user_id, "err_unknown"), esc(code or "error"))


# ── «Занято»: три случая, как в продукте (дизайн 0.5.0: сцены busy, queued, busy-lock) ──
# busy — кнопка нажата, пока идёт операция самого бота: экран «Дождитесь… и повторите» + «Назад»
# (_action_busy); queued — ввод текстом или фраза приняты во время операции бота: действие встаёт за
# замком и выполнится само (_queued_notice); busy-lock — замок держит SSH, панель или агент (мост
# ответил lock_timeout): ⏳ вместо ❌ и «🔁 Повторить». Имени и длительности чужого действия бот не
# знает и не называет.

def is_lock_busy(r: Any) -> bool:
    """Мост не взял общий замок (lock_timeout): действие не выполнялось вовсе — повтор честен."""
    return isinstance(r, dict) and str(r.get("code") or "") == "lock_timeout"


def fail_text(user_id: Optional[int], r: Dict[str, Any]) -> str:
    """Отказ моста строкой экрана: «занято» — ожидание (⏳, жирным), остальное — ❌ со словами и кодом."""
    if is_lock_busy(r):
        return "<b>⏳ %s</b>" % _t(user_id, "err_lock_timeout")
    return "❌ " + error_text(user_id, r)


# ── Отказ Let's Encrypt по причине (L-26) ──
# Мост кладёт в отказ cert_failed причину словом — cert_cause: dns (Let's Encrypt не проверил домен: A-запись не
# сюда или порт 80 закрыт снаружи), net (сервер не достучался до самого Let's Encrypt), limit (лимит выдачи) — и
# срок лимита cert_retry_after («2026-09-27 10:00», UTC), если Let's Encrypt его назвал. На каждую причину — свой
# короткий текст «что случилось и что сделать», а не слова ядра; причины нет (ядро старше, отказ не Let's Encrypt) —
# как прежде, слова ядра и код.
CERT_CAUSE_KEYS = {"dns": "cert_cause_dns", "net": "cert_cause_net", "limit": "cert_cause_limit"}
CERT_RETRY_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$")


def cert_cause_text(user_id: Optional[int], r: Any) -> str:
    """Что случилось и что сделать по причине отказа Let's Encrypt (cert_cause); причина неизвестна — пусто."""
    if not isinstance(r, dict):
        return ""
    cause = str(r.get("cert_cause") or "")
    if cause not in CERT_CAUSE_KEYS:
        return ""
    after = str(r.get("cert_retry_after") or "")
    if cause == "limit" and CERT_RETRY_RE.match(after):
        return _tf(user_id, "cert_cause_limit_until_fmt", esc(after))
    return _t(user_id, CERT_CAUSE_KEYS[cause])


def cert_fail_text(user_id: Optional[int], r: Dict[str, Any], domain: str = "", kept: bool = False) -> str:
    """Отказ моста: cert_failed с известной причиной — своими словами, остальное — fail_text. kept — отказ ничего
    не поменял (change-mode откатывает сайт целиком): так и сказать."""
    cause = cert_cause_text(user_id, r) if str(r.get("code") or "") == "cert_failed" else ""
    if not cause:
        return fail_text(user_id, r)
    head = _tf(user_id, "cert_fail_title_fmt", esc(domain)) if domain else _t(user_id, "cert_fail_title")
    lines = ["❌ " + head, cause]
    if kept:
        lines.append(_t(user_id, "cert_fail_kept"))
    return "\n".join(lines)


# Кнопки, чей обработчик берёт данные из ожидания ввода, а не из callback_data: ожидание снимается до
# вызова моста, и повтор той же кнопкой ответил бы «ожидание истекло» — им «Повторить» не ставим.
FLOW_BOUND_CALLBACKS = ("pr_pok", "pr_punset", "pr_subnet_ok", "ua_done", "ub_done")


def retry_data(target: Any) -> Optional[str]:
    """callback_data нажатой кнопки — для «🔁 Повторить» после lock_timeout (мост ничего не сделал)."""
    data = getattr(target, "data", None)
    if not isinstance(data, str) or not data or data in FLOW_BOUND_CALLBACKS:
        return None
    return data


def fail_markup(user_id: Optional[int], r: Dict[str, Any], back_to: str,
                retry: Optional[str] = None) -> "InlineKeyboardMarkup":
    """Кнопки под отказом: у «занято» — «🔁 Повторить» (та же кнопка ещё раз) над «Назад»."""
    if is_lock_busy(r) and retry:
        return InlineKeyboardMarkup([[btn(_t(user_id, "btn_retry"), retry)], _back_row(user_id, back_to)])
    return back_kb(user_id, back_to)


async def show_error(query, user_id: Optional[int], r: Dict[str, Any], back_to: str = "menu_main") -> None:
    await safe_edit_message(query, fail_text(user_id, r),
                            reply_markup=fail_markup(user_id, r, back_to, retry_data(query)))


async def show_bad_input(query, user_id: Optional[int], back_to: str = "menu_main") -> None:
    """Экран «некорректный ввод» с возвратом — вместо голого `return`.

    Голый выход из обработчика в Telegram выглядит как сломанная кнопка:
    «часики» гаснут, экран не меняется, объяснения нет, и человек жмёт ещё
    раз. Поэтому каждая неудачная проверка callback_data рисует эту ошибку.
    """
    await safe_edit_message(query, "❌ " + _t(user_id, "err_bad_input"), reply_markup=back_kb(user_id, back_to))


async def _action_busy(query, user_id: Optional[int], back_to: str = "menu_main") -> bool:
    """True + экран «занято» (busy), если другое мутирующее действие бота ещё идёт."""
    if not _BOT_ACTION_LOCK.locked():
        return False
    await safe_edit_message(
        query,
        "<b>%s</b>\n\n%s" % (_t(user_id, "action_busy_title"), _t(user_id, "action_busy_body")),
        reply_markup=back_kb(user_id, back_to),
    )
    return True


async def _queued_notice(message, user_id: Optional[int]) -> None:
    """Ввод текстом или фраза приняты, пока идёт операция бота (queued): действие не отменяется, а
    ждёт замок и выполнится сразу после неё — «повторите» здесь было бы неправдой и вело к повтору."""
    if _BOT_ACTION_LOCK.locked():
        await message.reply_text(_t(user_id, "action_queued"))


async def mutate(action: str, who: Optional[int] = None, timeout: Optional[int] = None,
                 stdin: Optional[str] = None, who_arg: Optional[str] = None, **params: Any) -> Dict[str, Any]:
    """Мутирующее действие под замком процесса; после него кэш статуса устаревает.

    stdin — секрет для мостового stdin (только user-attach-key, см. run_bot_action); who_arg — параметр --who
    (короткие ссылки)."""
    async with _BOT_ACTION_LOCK:
        r = await run_bot_action(action, timeout=timeout, who=who, stdin=stdin, who_arg=who_arg, **params)
    invalidate_status()
    return r


def _callback_message_key(query) -> Tuple[int, int]:
    return (query.message.chat_id, query.message.message_id)


def _once_callback(handler):
    """Одна операция на кнопку сообщения, включая два нажатия во время запроса к Telegram.

    Замок mutate лишь ставит операции в очередь: проверка «свободен» перед await
    правки экрана позволяла двум нажатиям подряд перевыпустить только что выданный
    ключ. Резервируем кнопку до первого await, а не после удаления клавиатуры.
    """
    @functools.wraps(handler)
    async def guarded(update, context):
        query = update.callback_query
        claims = context.user_data.setdefault("callback_claims", {})
        key = _callback_message_key(query) + (str(query.data),)
        if key in claims:
            await query.answer()
            return              # не затирать результат первого нажатия экраном «занято»
        # Храним только последние кнопки, не всю историю чата; выполняемые не вытесняем.
        for old in list(claims):
            if len(claims) < 64:
                break
            if not claims[old]["running"]:
                del claims[old]
        attempt = {"started": False, "running": True}
        claims[key] = attempt
        try:
            await handler(update, context, attempt)
        finally:
            attempt["running"] = False
            if not attempt["started"]:
                # Проверка ввода, занятый замок, ошибка Telegram ДО моста: можно повторить.
                claims.pop(key, None)
    return guarded


async def _callback_mutate(attempt, action: str, **params: Any) -> Dict[str, Any]:
    # После передачи мосту таймаут/потеря ответа не доказывают отсутствие эффекта:
    # старой кнопкой повторять нельзя; следующая операция требует нового экрана.
    attempt["started"] = True
    r = await mutate(action, **params)
    if is_lock_busy(r):
        # Замок моста не взялся — действие не начиналось: «🔁 Повторить» (та же кнопка) честен.
        attempt["started"] = False
    return r


def _rearm_callback(context, query, prefix: str) -> None:
    """Новый экран подтверждения разрешает новую операцию в том же сообщении."""
    claims = context.user_data.get("callback_claims", {})
    message_key = _callback_message_key(query)
    for key in list(claims):
        if key[:2] == message_key and key[2].startswith(prefix) and not claims[key]["running"]:
            del claims[key]


# ── Кэш status: дашборд перерисовывается на каждый «Назад» ───────────────────
# status зовёт docker по каждому профилю (~1 с); держим ответ 15 с и сбрасываем
# после любой мутации, чтобы не показать старое состояние после действия.
_STATUS_CACHE: Dict[str, Any] = {"at": 0.0, "data": None, "gen": 0}
STATUS_CACHE_TTL = 15.0


def invalidate_status() -> None:
    _STATUS_CACHE["at"] = 0.0
    _STATUS_CACHE["data"] = None
    # Поколение: status, начатый ДО сброса и вернувшийся ПОСЛЕ (вызов идёт
    # около секунды, бот обслуживает нажатия параллельно), не должен лечь в
    # кэш — иначе на 15 секунд возвращалось состояние до мутации: «профиль не
    # установлен» сразу после установки, прежний порт после смены.
    _STATUS_CACHE["gen"] = int(_STATUS_CACHE.get("gen") or 0) + 1
    # Адреса в ключах (keys_host, key_choices) меняет та же мутация (смена Endpoint, режима,
    # закреплённого адреса) — кэш edge-status сбрасывается вместе со статусом.
    invalidate_edge()


async def get_status(fresh: bool = False) -> Dict[str, Any]:
    now = time.monotonic()
    if not fresh and _STATUS_CACHE["data"] is not None and now - _STATUS_CACHE["at"] < STATUS_CACHE_TTL:
        return _STATUS_CACHE["data"]
    gen = _STATUS_CACHE.get("gen")
    r = await run_bot_action("status", timeout=60)
    remember_lines(r)
    if bridge_ok(r) and _STATUS_CACHE.get("gen") == gen:
        _STATUS_CACHE["at"] = now
        _STATUS_CACHE["data"] = r
    return r


# ── Кэш edge-status: карточка пользователя и экраны «Ключ на другой адрес» ───
# Карточка решает, показывать ли кнопку «Ключ на другой адрес», а экран адресов и
# каждая кнопка выдачи находят адрес по коду заново (docs/BOT.md § 5) — без кэша
# цепочка «карточка → адрес → вид ключа» звала бы edge-status на каждом шаге.
# Экран «Адреса» (st_addr) кэш не берёт: там счётчики пакетов, им нужна свежесть.
_EDGE_CACHE: Dict[str, Any] = {"at": 0.0, "data": None, "gen": 0}
EDGE_CACHE_TTL = 30.0


def invalidate_edge() -> None:
    _EDGE_CACHE["at"] = 0.0
    _EDGE_CACHE["data"] = None
    _EDGE_CACHE["gen"] = int(_EDGE_CACHE.get("gen") or 0) + 1


async def get_edge_status(fresh: bool = False) -> Dict[str, Any]:
    now = time.monotonic()
    if not fresh and _EDGE_CACHE["data"] is not None and now - _EDGE_CACHE["at"] < EDGE_CACHE_TTL:
        return _EDGE_CACHE["data"]
    gen = _EDGE_CACHE.get("gen")
    r = await run_bot_action("edge-status", timeout=60)
    if bridge_ok(r) and _EDGE_CACHE.get("gen") == gen:
        _EDGE_CACHE["at"] = now
        _EDGE_CACHE["data"] = r
    return r


def status_profiles(status: Dict[str, Any]) -> List[Dict[str, Any]]:
    """profiles[] из status — только объекты с полем profile, в порядке PROFILE_IDS."""
    items = status.get("profiles")
    if not isinstance(items, list):
        return []
    by_id = {str(p.get("profile")): p for p in items if isinstance(p, dict) and p.get("profile")}
    return [by_id[p] for p in PROFILE_IDS if p in by_id]


def installed_profiles(status: Dict[str, Any]) -> List[str]:
    return [str(p.get("profile")) for p in status_profiles(status)]


def profile_info(status: Dict[str, Any], profile: str) -> Dict[str, Any]:
    for p in status_profiles(status):
        if str(p.get("profile")) == profile:
            return p
    return {}


# ── Названия профилей: линия и порт, без служебных id (DS2-55; DUP-LINE-01, решение владельца 15.10) ──────
# Пользователю профиль называется линией AmneziaWG и портом — «AmneziaWG 3.1 · порт 6714»; подхваченный у приложения
# Amnezia — ещё и «· из приложения»; свободное место — линией, которая на него встанет по «Установить»
# (status.free_lines): «AmneziaWG 2.0 — не установлена». На кнопках коротко: «3.1 · 6714», «3.1 · 46567 · приложение».
# Раньше две 3.1 (подхваченная у приложения на awg2 и своя на awg3) назывались одинаково, а имя места (awg2) людям ничего
# не говорит. Служебный id остаётся только в технике: callback_data, фразы подтверждения (REMOVE awg3), аргументы
# команд (/key anna awg3), имена контейнеров и файлов, журналы. Линия — фактическая, из status: у awg1 это 1.0 или 1.5.
# Экраны без status под рукой берут последнее увиденное (remember_lines): кэш status сбрасывается после каждой мутации.
_KNOWN_LINES: Dict[str, str] = {}
_KNOWN_PORTS: Dict[str, int] = {}
_KNOWN_IMPORTED: Dict[str, bool] = {}
_KNOWN_FREE: Dict[str, str] = {}


def _port_of(item: Any) -> int:
    """Порт из записи status.profiles[] (число или строка цифр), иначе 0."""
    port = item.get("port") if isinstance(item, dict) else None
    if isinstance(port, str) and port.isdigit():
        port = int(port)
    return port if isinstance(port, int) and not isinstance(port, bool) and 0 < port < 65536 else 0


def status_free_lines(status: Any) -> Dict[str, str]:
    """status.free_lines — {место: линия} свободных мест с проверенными значениями; ядро старше поля — {}."""
    fl = status.get("free_lines") if isinstance(status, dict) else None
    if not isinstance(fl, dict):
        return {}
    return {p: str(l) for p, l in fl.items() if p in PROFILE_IDS and str(l) in LINE_FAMILY}


def remember_lines(status: Any) -> None:
    """Запомнить линии, порты и «из приложения» установленных профилей и линии свободных мест из удачного status (для
    экранов и уведомлений без status). Место освободилось — его прежние линия и порт забываются."""
    if not (isinstance(status, dict) and bridge_ok(status)):
        return
    items = status_profiles(status)
    for item in items:
        pid = str(item.get("profile"))
        line = str(item.get("line") or "")
        if line:
            _KNOWN_LINES[pid] = line
        _KNOWN_FREE.pop(pid, None)
        port = _port_of(item)
        if port:
            _KNOWN_PORTS[pid] = port
        else:
            _KNOWN_PORTS.pop(pid, None)
        _KNOWN_IMPORTED[pid] = item.get("imported") is True
    if isinstance(status.get("profiles"), list):
        installed = {str(i.get("profile")) for i in items}
        free = status_free_lines(status)
        for pid in PROFILE_IDS:
            if pid in installed:
                continue
            _KNOWN_LINES.pop(pid, None)
            _KNOWN_PORTS.pop(pid, None)
            _KNOWN_IMPORTED.pop(pid, None)
            _KNOWN_FREE[pid] = free.get(pid) or DEFAULT_LINE.get(pid, "")


def _status_knows_profiles(status: Any) -> bool:
    return isinstance(status, dict) and bridge_ok(status) and isinstance(status.get("profiles"), list)


def profile_line(profile: Any, status: Optional[Dict[str, Any]] = None) -> str:
    """Линия профиля: из status (у свободного места — та, что встанет по «Установить»), иначе последняя известная,
    иначе линия свежей установки."""
    profile = str(profile or "")
    line = ""
    if isinstance(status, dict):
        line = str(profile_info(status, profile).get("line") or "") or status_free_lines(status).get(profile, "")
    return line or _KNOWN_LINES.get(profile) or _KNOWN_FREE.get(profile) or DEFAULT_LINE.get(profile, "")


def profile_facts(profile: Any, status: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """{line, port, imported, free} профиля для подписи: по status, без него — по последнему увиденному. free — место
    свободно (профиль в status не установлен); port 0 — порт неизвестен (подпись без порта)."""
    profile = str(profile or "")
    line = profile_line(profile, status)
    if _status_knows_profiles(status):
        info = profile_info(status, profile)
        if not info:
            return {"line": line, "port": 0, "imported": False, "free": True}
        return {"line": line, "port": _port_of(info), "imported": info.get("imported") is True, "free": False}
    if profile in _KNOWN_FREE and profile not in _KNOWN_LINES:
        return {"line": line, "port": 0, "imported": False, "free": True}
    return {"line": line, "port": _KNOWN_PORTS.get(profile, 0), "imported": bool(_KNOWN_IMPORTED.get(profile)),
            "free": False}


def profile_label(user_id: Optional[int], line: Any, port: Any = 0, imported: bool = False, free: bool = False) -> str:
    """Подпись по фактам: «AmneziaWG 3.1 · порт 6714», «… · из приложения», «AmneziaWG 2.0 — не установлена»."""
    line = str(line or "")
    if free:
        return _tf(user_id, "pr_label_free_fmt", line)
    port = _as_int(port)
    if not port:
        return _tf(user_id, "pr_line_name_fmt", line)
    return _tf(user_id, "pr_label_app_fmt" if imported else "pr_label_fmt", line, port)


def profile_line_name(user_id: Optional[int], profile: Any, status: Optional[Dict[str, Any]] = None) -> str:
    """Только линия — «AmneziaWG 3.1»: где порт стоит рядом и так (заголовок профиля в карточке пользователя) и где
    профиля ещё нет (установка: «Ставлю профиль AmneziaWG 2.0…»)."""
    profile = str(profile or "")
    if profile not in PROFILE_IDS:
        return profile
    return _tf(user_id, "pr_line_name_fmt", profile_line(profile, status))


def profile_title(user_id: Optional[int], profile: Any, status: Optional[Dict[str, Any]] = None) -> str:
    """Профиль для людей — «AmneziaWG 3.1 · порт 6714» (подхваченный — «… · из приложения», свободное место —
    «AmneziaWG 2.0 — не установлена»). Не профиль (чужое значение из события) — как есть."""
    profile = str(profile or "")
    if profile not in PROFILE_IDS:
        return profile
    f = profile_facts(profile, status)
    return profile_label(user_id, f["line"], f["port"], f["imported"], f["free"])


def profile_name(user_id: Optional[int], profile: Any, status: Optional[Dict[str, Any]] = None) -> str:
    """Профиль в тексте — та же подпись, что в заголовке (profile_title): без порта две 3.1 не различить."""
    return profile_title(user_id, profile, status)


def profile_title_of_line(user_id: Optional[int], profile: Any, line: Any) -> str:
    """Подпись профиля, когда линию назвал сам ответ (подписка, lines[]): линия ответа, порт и «из приложения» — по
    последнему увиденному status."""
    profile, line = str(profile or ""), str(line or "")
    if profile not in PROFILE_IDS or not line:
        return profile_title(user_id, profile)
    f = profile_facts(profile)
    same = _KNOWN_LINES.get(profile, line) == line and not f["free"]
    return profile_label(user_id, line, f["port"] if same else 0, f["imported"] and same)


def profile_names(user_id: Optional[int], profiles: Any) -> str:
    """Список профилей строкой — «AmneziaWG 3.1, AmneziaWG 2.0» в порядке 3.1 → 2.0 → 1.x."""
    items = [str(x) for x in (profiles if isinstance(profiles, (list, tuple, set)) else [])]
    ordered = [x for x in PROFILE_IDS if x in items] + [x for x in items if x not in PROFILE_IDS]
    return ", ".join(profile_name(user_id, x) for x in ordered)


def profile_short(profile: Any, status: Optional[Dict[str, Any]] = None, user_id: Optional[int] = None) -> str:
    """Профиль на кнопке рядом с действием — «3.1 · 6714 · QR .conf»: линия и порт; подхваченный у приложения — «3.1 ·
    46567 · приложение»; порт неизвестен или место свободно — одна линия."""
    f = profile_facts(profile, status)
    line = f["line"] or str(profile or "")
    if f["free"] or not f["port"]:
        return line
    if f["imported"]:
        return _tf(user_id, "pr_short_app_fmt", line, f["port"])
    return "%s · %s" % (line, f["port"])


def profile_from_arg(arg: Any, status: Optional[Dict[str, Any]] = None) -> str:
    """Профиль из аргумента команды: линия, как профиль называют экраны («/key anna 2.0»), или прежний
    служебный id («/key anna awg2») — старые привычки и заметки продолжают работать (NC-23, критик-новичок).

    Линия ищется среди фактических линий профилей (status, иначе последние увиденные); 1.0 и 1.5 — одно
    семейство, поэтому «1.5» найдёт и профиль на 1.0. Не профиль и не линия — пустая строка."""
    arg = str(arg or "").strip().lower()
    if arg in PROFILE_IDS:
        return arg
    if arg not in LINE_FAMILY:
        return ""
    for p in PROFILE_IDS:
        if profile_line(p, status) == arg:
            return p
    for p in PROFILE_IDS:
        if LINE_FAMILY.get(profile_line(p, status)) == LINE_FAMILY[arg]:
            return p
    return ""


# ── Ожидание ввода текста ────────────────────────────────────────────────────
# Один «flow» на пользователя в context.user_data: вид, шаг, накопленные
# данные, время взвода. Любая кнопка снимает ожидание (кроме кнопок самого
# flow), просроченное молча забывается — иначе через сутки первое же
# сообщение боту уходило бы как имя пользователя.
FLOW_TTL = 600


def flow_set(context, kind: str, **data: Any) -> Dict[str, Any]:
    flow = {"kind": kind, "since": time.monotonic(), "data": dict(data)}
    context.user_data["flow"] = flow
    context.user_data.pop("flow_expired", None)
    return flow


def flow_get(context) -> Optional[Dict[str, Any]]:
    flow = context.user_data.get("flow")
    if not isinstance(flow, dict):
        return None
    if time.monotonic() - float(flow.get("since") or 0) > FLOW_TTL:
        context.user_data.pop("flow", None)
        # Ответ на просроченный вопрос: «время вышло», а не «я ничего не жду» (сцена flow-expired)
        context.user_data["flow_expired"] = True
        return None
    return flow


def flow_clear(context) -> None:
    context.user_data.pop("flow", None)
    context.user_data.pop("flow_expired", None)


# Кнопки, которые продолжают flow, а не отменяют его (галочки профилей,
# быстрые значения): их префиксы роутер пропускает мимо flow_clear.
# Кнопки, которые ПРОДОЛЖАЮТ мастер: всё остальное сбрасывает его до того,
# как обработчик успеет что-то сделать. Забыть здесь новую кнопку — значит
# сделать её мёртвой: человек жмёт единственную кнопку экрана и получает
# «ожидание истекло». Так и вышло с ag_aips~ (белый список адресов): соседние
# шаги того же мастера в списке были, пропущен ровно новый. Добавляешь шаг —
# дописывай сюда. Сверку держит tests/test_bot_features.py.
FLOW_CALLBACK_PREFIXES = ("ua_", "ub_", "uq_", "ue_", "pr_pok", "pr_punset", "pr_subnet_ok", "pr_mtu_set~", "ag_scope~", "ag_days~", "ag_apin~", "ag_aips~", "ag_amode~")


# ============================================================================
# ДОСТУП: онбординг первого админа, проверка
# ============================================================================

def is_private_chat(update: Any) -> bool:
    """Апдейт из личного чата с ботом? Всё остальное бот не слышит вовсе.

    Админ управляет сервером только в личке. Добавленный в группу бот иначе
    отвечал бы там дашбордом с адресом сервера на глазах у всех, принимал фразу
    подтверждения «DELETE anna», набранную в группе, и забирал ключ из ожидающего
    шага «Привязать старый ключ». Нажатие без чата (inline-режим) — тоже не личка.
    """
    chat = getattr(update, "effective_chat", None)
    return str(getattr(chat, "type", "") or "") == "private"


# ── Ответы незнакомцам: не больше нескольких в минуту ────────────────────────
# Каждое сообщение чужого получало ответ «доступ запрещён». Поток таких сообщений
# (или нажатий) заставлял бота тратить на них лимит Telegram — около 30 сообщений в
# секунду на бота, — и ответы админам и уведомления вставали в очередь за ними.
# Теперь чужому — не больше STRANGER_REPLY_LIMIT ответов в минуту, всем чужим вместе —
# не больше STRANGER_GLOBAL_LIMIT; сверх того апдейт молча отбрасывается, и в лог о нём
# ничего не пишется (текст чужих сообщений бот не пишет в лог никогда).
# Исключение одно — первый ответ новому кандидату окна привязки (first=True): у него свой бюджет,
# не больше PAIRING_MAX_CANDIDATES ответов на окно (столько кандидатов бот и записывает). Иначе
# поток чужих, выбравший общий лимит, глушил ответ владельцу, который пишет боту по просьбе SSH
# (SEC50-01). Такой ответ в минуту человека и в общую тоже засчитывается.
STRANGER_REPLY_LIMIT = 3
STRANGER_GLOBAL_LIMIT = 30
STRANGER_WINDOW = 60.0
STRANGER_TRACK_MAX = 2048          # сколько разных чужих помнить (память не должна расти без края)
_STRANGER_HITS: Dict[int, List[float]] = {}
_STRANGER_ALL: List[float] = []


def stranger_may_reply(user_id: Optional[int], now: Optional[float] = None, first: bool = False) -> bool:
    """Можно ли ответить незнакомцу сейчас; True — ответ засчитан в его минуту.

    first — первый ответ новому кандидату окна привязки: лимиты его не держат (бюджет — сам список
    кандидатов, pairing_record_candidate), но ответ засчитывается, как любой другой."""
    now = time.monotonic() if now is None else now
    cutoff = now - STRANGER_WINDOW
    key = int(user_id or 0)
    _STRANGER_ALL[:] = [t for t in _STRANGER_ALL if t > cutoff]
    hits = [t for t in _STRANGER_HITS.get(key, []) if t > cutoff]
    if not first and (len(hits) >= STRANGER_REPLY_LIMIT or len(_STRANGER_ALL) >= STRANGER_GLOBAL_LIMIT):
        # Отказ человека в память не заносит: иначе поток с тысяч аккаунтов, упёршийся в
        # общий потолок, раздувал бы словарь пустыми записями
        if hits:
            _STRANGER_HITS[key] = hits
        else:
            _STRANGER_HITS.pop(key, None)
        return False
    hits.append(now)
    _STRANGER_HITS[key] = hits
    _STRANGER_ALL.append(now)
    if len(_STRANGER_HITS) > STRANGER_TRACK_MAX:
        # Сначала забываем тех, чья минута прошла, потом — самых давних
        for uid in [u for u, ts in _STRANGER_HITS.items() if not ts or ts[-1] <= cutoff]:
            _STRANGER_HITS.pop(uid, None)
        while len(_STRANGER_HITS) > STRANGER_TRACK_MAX:
            oldest = min(_STRANGER_HITS, key=lambda u: _STRANGER_HITS[u][-1] if _STRANGER_HITS[u] else 0.0)
            _STRANGER_HITS.pop(oldest, None)
    return True


async def require_auth(update: Update, context: ContextTypes.DEFAULT_TYPE) -> bool:
    user_id = _uid(update)
    if not is_private_chat(update):
        # Группы и каналы: ни ответа, ни записи в лог — бота там будто нет
        return False
    if is_user_allowed(user_id):
        return True
    # Чужому — один и тот же ответ в окне привязки и вне его (в окне он ещё и кандидат для SSH)
    if update.message is not None:
        await stranger_pairing_reply(update)
    return False


async def stranger_pairing_reply(update: Update, text: str = "") -> bool:
    """Личное сообщение не-админа — что угодно: команда, текст, файл, стикер. True — обработано.

    Ответ ОДИН И ТОТ ЖЕ в окне привязки и вне его (SEC50-01): «это бот частного сервера; владельцу —
    в SSH-терминал» и его Telegram ID. Раньше в окне приходило «запрос получен, окно открыто ещё N
    мин», а вне окна — «доступ запрещён» или тишина, и посторонний по разнице ответов видел, что окно
    открыто. Окно открыто — написавший ещё и записывается в кандидаты для SSH (первые
    PAIRING_MAX_CANDIDATES по времени), и первый ответ новому кандидату не зависит от общего лимита
    ответов чужим: владелец, которого SSH просит написать боту, ответ получит, сколько бы чужих ни
    писало. Остальные ответы — под лимитом (SEC-B3). Восемь цифр, пока админов нет и есть код этого
    окна (установка без терминала), — экран назначения по коду; кода нет — обычное сообщение.
    """
    user = update.effective_user
    user_id = user.id
    pairing_sync_window()
    first = False
    if pairing_window_open():
        first = pairing_record_candidate(user) == PAIRING_NEW
        if _WAITING_FOR_ADMIN and normalize_claim_code(text) and admin_claim_code():
            await _admin_claim_screen(update, text)
            return True
    if stranger_may_reply(user_id, first=first):
        # В лог — только кто, без имени и текста: их присылает сам человек
        logger.warning("Message from a stranger %s (%s)", user_id,
                       "new pairing candidate" if first else "not an administrator")
        await update.message.reply_text(_tf(user_id, "stranger_private_bot_fmt", user_id), parse_mode="HTML")
    return True


def _admin_claim_keyboard(user_id: int) -> "InlineKeyboardMarkup":
    return InlineKeyboardMarkup([[
        btn(_t(user_id, "btn_yes"), "admin_confirm_%d" % user_id),
        btn(_t(user_id, "btn_no"), "admin_cancel"),
    ]])


def _admin_claim_text(user, user_id: int) -> str:
    name = (getattr(user, "full_name", None) or getattr(user, "username", None) or str(user_id))
    return "<b>%s</b>\n\n%s\n\n%s" % (
        _tf(user_id, "waiting_admin_title", esc(name)),
        _tf(user_id, "waiting_admin_body", user_id),
        _tf(user_id, "admin_claim_window", max(1, admin_claim_seconds_left() // 60)),
    )


def _admin_claim_closed_text(user_id: Optional[int]) -> str:
    """Бот без админов и окна привязки нет: открыть его в SSH-меню (или вписать ID в .env руками).

    Перезапуск бота окно больше не открывает — раньше этот экран советовал именно его."""
    return _tf(user_id, "admin_not_set_up_fmt", user_id, esc(ENV_FILE), BOT_SERVICE)


async def _admin_claim_screen(update: Update, code: str = "") -> None:
    """Одноразовый код от человека, пока админа нет: «/start КОД» или сам код текстом.

    Запасной путь для установок без терминала — и только пока открыто окно привязки.
    Экран «Назначить вас администратором?» получает только тот, кто прислал верный
    код, — раньше его получал любой написавший /start в первые десять минут.
    """
    user = update.effective_user
    user_id = user.id
    if not admin_claim_open():
        if stranger_may_reply(user_id):
            logger.warning("Admin claim window closed; ignoring a message from user %s", user_id)
            await update.message.reply_text(_admin_claim_closed_text(user_id), parse_mode="HTML")
        return
    if _CLAIM_FAILS.get(user_id, 0) >= CLAIM_MAX_FAILS:
        return      # перебор кода: дальше этот человек ответа не получает вовсе
    if not normalize_claim_code(code):
        if stranger_may_reply(user_id):
            await update.message.reply_text(_tf(user_id, "admin_claim_need_code", esc(ADMIN_CLAIM_CODE_FILE)),
                                            parse_mode="HTML")
        return
    if not claim_code_matches(code):
        _CLAIM_FAILS[user_id] = _CLAIM_FAILS.get(user_id, 0) + 1
        # В лог — кто и который раз, но не сам присланный текст
        logger.warning("Admin claim: wrong code from user %s (%d of %d)",
                       user_id, _CLAIM_FAILS[user_id], CLAIM_MAX_FAILS)
        if stranger_may_reply(user_id):
            await update.message.reply_text(_tf(user_id, "admin_claim_bad_code", esc(ADMIN_CLAIM_CODE_FILE)),
                                            parse_mode="HTML")
        return
    # Верный код — ответ всегда, мимо счётчика незнакомцев: поток чужих сообщений не
    # должен отнимать у владельца его собственное назначение.
    _CLAIM_VERIFIED.add(user_id)
    logger.warning("Admin claim: correct code from user %s (%ss of the window left)",
                   user_id, admin_claim_seconds_left())
    await update.message.reply_text(_admin_claim_text(user, user_id),
                                    reply_markup=_admin_claim_keyboard(user_id), parse_mode="HTML")


async def cb_admin_confirm(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    uid_pressed = update.effective_user.id
    # Кнопка онбординга доступна до проверки доступа, поэтому каждый ответ чужому здесь —
    # под тем же лимитом, что у остальных: старую кнопку «Да» или присланную руками
    # callback_data можно жать тысячу раз, и бот тратил бы лимит Telegram на правку
    # сообщения в ответ на каждое нажатие (SEC-B3).
    try:
        new_admin_id = int(query.data.split("_")[-1])
    except (ValueError, IndexError):
        if not is_user_allowed(uid_pressed) and not stranger_may_reply(uid_pressed):
            return
        await query.answer()
        await safe_edit_message(query, "❌ " + _t(uid_pressed, "err_bad_input"))
        return
    # Только тот, кто нажал кнопку, может стать админом; ответ ровно один —
    # иначе show_alert не доезжает до пользователя.
    if uid_pressed != new_admin_id:
        if not stranger_may_reply(uid_pressed):
            return
        await query.answer(_t(uid_pressed, "admin_claim_not_yours"), show_alert=True)
        return
    if not _WAITING_FOR_ADMIN:
        if is_user_allowed(uid_pressed):
            # Второе нажатие того же «Да» (двойной тап) уже назначенным админом: «✅ Вы назначены»
            # и главный экран уже в чате — не затирать их строкой «администратор уже назначен».
            await query.answer()
        elif stranger_may_reply(uid_pressed):
            await query.answer()
            await safe_edit_message(query, _t(uid_pressed, "admin_already_set"))
        return
    pairing_sync_window()       # «верный код» прошлого окна в новом окне не действует
    if uid_pressed not in _CLAIM_VERIFIED:
        # Кнопка от прежней версии бота (давала права без кода) или код не присылали
        # в этом запуске: без верного кода «Да» ничего не делает.
        if not stranger_may_reply(uid_pressed):
            return
        await query.answer(_t(uid_pressed, "admin_claim_code_first"), show_alert=True)
        return
    await query.answer()
    async with _admin_claim_lock():
        # Проверка ещё раз — уже под замком: второй «Да», нажатый одновременно, видит
        # назначенного первым и уходит ни с чем, а не становится вторым админом.
        pairing_sync_window()
        if not _WAITING_FOR_ADMIN:
            outcome = "taken"
        elif not admin_claim_open():
            outcome = "closed"
        elif uid_pressed not in _CLAIM_VERIFIED:
            # Пока отвечали на нажатие, SSH открыл новое окно: код прошлого в нём не годится
            outcome = "stale"
        else:
            saved = add_admin(new_admin_id)
            forget_admin_claim_code()
            # Привязка состоялась — окно закрыто: остальным написавшим незачем слышать «вернитесь в SSH»
            for path in (ADMIN_PAIRING_UNTIL_FILE, ADMIN_CANDIDATES_FILE):
                _unlink_quiet(path)
            outcome = "claimed"
    if outcome == "taken":
        # Тот же человек нажал дважды разом — назначен первым нажатием, экран остаётся его;
        # другому — факт, что администратор уже есть.
        if not is_user_allowed(uid_pressed):
            await safe_edit_message(query, _t(uid_pressed, "admin_already_set"))
        return
    if outcome == "closed":
        await safe_edit_message(query, _admin_claim_closed_text(uid_pressed))
        return
    if outcome == "stale":
        await safe_edit_message(query, _tf(uid_pressed, "admin_claim_need_code", esc(ADMIN_CLAIM_CODE_FILE)))
        return
    logger.warning("First admin registered from Telegram: %s", new_admin_id)
    text = _tf(uid_pressed, "admin_claimed_fmt", new_admin_id)
    if not saved:
        text += "\n\n" + _t(uid_pressed, "admin_env_not_saved")
    await safe_edit_message(query, text)
    # Второй /start больше не нужен: права уже есть, рисуем главный экран
    # сразу — иначе человек остаётся перед сообщением без единой кнопки.
    await render_main(query.message, uid_pressed, edit=False)
    # Кнопка меню с панелью — и первому админу сразу, как при привязке сообщением и /invite
    await refresh_menu_button_after(context)


async def cb_admin_cancel(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """«Нет» на запрос прав: не тупик — кнопка возвращает к тому же запросу."""
    query = update.callback_query
    user_id = _uid(update)
    if user_id not in _CLAIM_VERIFIED and not is_user_allowed(user_id) and not stranger_may_reply(user_id):
        return
    await query.answer()
    await safe_edit_message(query, _t(user_id, "admin_cancelled"),
                            reply_markup=InlineKeyboardMarkup([[btn(_t(user_id, "btn_back"), "admin_again")]]))


async def cb_admin_again(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """admin_again: вернуть экран запроса прав (окно могло и закрыться)."""
    query = update.callback_query
    user = update.effective_user
    user_id = user.id
    if user_id not in _CLAIM_VERIFIED and not is_user_allowed(user_id) and not stranger_may_reply(user_id):
        return
    await query.answer()
    if not _WAITING_FOR_ADMIN:
        # Админ уже есть. Свой — просто открываем меню, чужой получает ровно
        # факт и ни одной кнопки: онбординг закрыт.
        if is_user_allowed(user_id):
            await render_main(query, user_id)
        else:
            await safe_edit_message(query, _t(user_id, "admin_already_set"))
        return
    if not admin_claim_open():
        await safe_edit_message(query, _admin_claim_closed_text(user_id))
        return
    if user_id not in _CLAIM_VERIFIED:
        # Кнопки «Да» без верного кода нет: сначала код с сервера
        await safe_edit_message(query, _tf(user_id, "admin_claim_need_code", esc(ADMIN_CLAIM_CODE_FILE)))
        return
    await safe_edit_message(query, _admin_claim_text(user, user_id), reply_markup=_admin_claim_keyboard(user_id))


# ============================================================================
# ГЛАВНЫЙ ЭКРАН — дашборд (режим, адрес, профили, пользователи)
# ============================================================================

def mode_label(user_id: Optional[int], mode: Any) -> str:
    """Режим с подписью, как в таблице договора 0.6.0: «Pro — сайт и VPN на 443», «Semi-Pro — VPN и
    сайт», «Lite — только VPN» (F-2). Так режим называют строки состояния, заголовки и подтверждения;
    незнакомый код — как есть, пусто — прочерк."""
    key = MODE_NAME_KEYS.get(str(mode or "").strip())
    if key:
        return "%s — %s" % (_t(user_id, key), _t(user_id, MODE_SUB_KEYS[str(mode).strip()]))
    return str(mode).strip() if mode else "—"


def mode_short(user_id: Optional[int], mode: Any) -> str:
    """Одно название режима — для кнопок («🔀 Перейти в Semi-Pro»): подпись стоит на экране над ними."""
    key = MODE_NAME_KEYS.get(str(mode or "").strip())
    if key:
        return _t(user_id, key)
    return str(mode).strip() if mode else "—"


def site_summary_lines(user_id: Optional[int], site: Any) -> List[str]:
    """Блок site из status для экранов бота: адрес, шаблон, сертификат.

    В Pro сертификат — Let's Encrypt со сроком; в Lite + сайт — самоподписанный,
    и вместо срока показываем отпечаток SHA-256: по нему человек и агент MCP
    убеждаются, что говорят с этим сервером (браузер такому сертификату не
    доверяет по определению). Разбор защищённый: отсутствие поля даёт прочерк.
    """
    if not isinstance(site, dict):
        return []
    lines = []
    url = str(site.get("url") or "").strip()
    if url:
        lines.append("%s <code>%s</code>" % (_t(user_id, "site_url"), esc(url)))
    template = str(site.get("template_id") or "").strip()
    lines.append("%s %s" % (_t(user_id, "site_template"),
                            ("<code>%s</code>" % esc(template)) if template else ("<i>%s</i>" % _t(user_id, "site_template_none"))))
    cert = str(site.get("cert") or "").strip()
    if cert == "selfsigned":
        lines.append("%s %s" % (_t(user_id, "site_cert"), _t(user_id, "site_cert_selfsigned")))
        fp = str(site.get("cert_fingerprint_sha256") or "").strip()
        lines.append("%s <code>%s</code>" % (_t(user_id, "site_fingerprint"), esc(fp or "—")))
    else:
        expires = str(site.get("cert_expires") or "").strip()
        days = site.get("cert_days_left")
        if expires and days is not None:
            lines.append("%s %s" % (_t(user_id, "site_cert"),
                                    _tf(user_id, "site_cert_letsencrypt_fmt", esc(expires[:10]), esc(days))))
        else:
            lines.append("%s %s" % (_t(user_id, "site_cert"), _t(user_id, "site_cert_letsencrypt_none")))
    return lines


def endpoint_gone_host(status: Any) -> str:
    """Адрес в ключах, которого на машине больше нет (status.endpoint_host_gone, L-02), или пусто.

    Мост ставит признак, когда вписанный в ключи IP с сервера пропал (переезд, снятый адрес) — ключи с
    ним не соединятся; намеренно чужой адрес (проброс) пропавшим не считается. Какой именно — поле
    endpoint_host (что вписано), без него — endpoint_effective."""
    if not isinstance(status, dict) or not bridge_ok(status) or status.get("endpoint_host_gone") is not True:
        return ""
    return str(status.get("endpoint_host") or status.get("endpoint_effective") or "?")


def dashboard_problems(user_id: Optional[int], status: Dict[str, Any], buttons: bool = True) -> Tuple[List[str], list]:
    """Что чинить прямо с главного экрана (дизайн 0.5.0, сцены start*): строки проблем и кнопки быстрого
    действия над разделами — только когда есть что чинить. Остановленный профиль — «♻️ Перезапустить 1.5»,
    пропавший контейнер — «🩹 Поднять 1.5 заново» (оба — экраны карточки профиля с вопросом), режим и
    порт разошлись — перенос порта (mode_port_fix), адрес в ключах пропал с сервера — «📍 Адрес в
    ключах», мало места на диске — «🩺 Диагностика». Docker не отвечает — только строка: чинится на
    сервере, а не из бота."""
    lines: List[str] = []
    rows: list = []
    if not bridge_ok(status):
        return lines, rows
    profiles = status_profiles(status)
    for item in profiles:
        pid = str(item.get("profile"))
        state = profile_state_key(item.get("state"))
        name = esc(profile_name(user_id, pid, status))
        short = esc(profile_short(pid, status, user_id))
        if state == "stopped":
            lines.append("⚠️ " + _tf(user_id, "dash_profile_stopped_fmt", name))
            if buttons:
                rows.append([btn(_tf(user_id, "dash_restart_btn_fmt", short), "pr_restart~%s" % pid)])
        elif state == "state_missing":
            lines.append("⚠️ " + _tf(user_id, "dash_profile_missing_fmt", name))
            if buttons:
                rows.append([btn(_tf(user_id, "dash_repair_btn_fmt", short), "pr_fix~%s" % pid)])
    if any(profile_state_key(item.get("state")) == "state_docker_unreachable" for item in profiles):
        lines.append("⚠️ " + _t(user_id, "dash_docker_unreachable"))
    # Ярлык режима и порт VPN разошлись («Pro» без профиля на 443 или
    # «Semi-Pro» с профилем на нём): шапка SSH говорит об этом вслух, мост отдаёт
    # признак в status — а бот молчал и показывал режим, которого на деле нет.
    if status.get("mode_port_mismatch") is True:
        lines.append("⚠️ " + _t(user_id, "dash_mode_port_mismatch"))
        if buttons:
            _, fix = mode_port_fix(user_id, status, str(status.get("mode") or ""))
            # «Протоколы» (профилей несколько — какой перенести, решает человек) и так стоит в разделах ниже
            rows.extend(r for r in fix if all(getattr(b, "callback_data", "") != "sec_protocols" for b in r))
    gone = endpoint_gone_host(status)
    if gone:
        lines.append("⚠️ " + _tf(user_id, "dash_endpoint_gone_fmt", esc(gone)))
        if buttons:
            rows.append([btn(_t(user_id, "dash_endpoint_btn"), "se_endpoint")])
    # Место на диске (status.disk — ga_disk_json в lib/common.sh, находка OPS-06): low — свободно меньше low_mb
    # (1024 МБ: не пройдёт обновление ядра), critical — меньше critical_mb (512 МБ: не снимется и ночная копия).
    # Раньше об этом говорила только «Диагностика». ok, null или ядро старше поля — ни строки, ни кнопки.
    # Кнопка — в «Диагностику»: удалять копии и подрезать журналы бот не умеет, текст говорит, где это делается.
    disk = status.get("disk") if isinstance(status.get("disk"), dict) else {}
    level = str(disk.get("level") or "")
    if level in ("low", "critical"):
        critical = level == "critical"
        lines.append(("🚨 " if critical else "⚠️ ") + _tf(user_id, "dash_disk_critical_fmt" if critical else "dash_disk_low_fmt",
                                                         _as_int(disk.get("free_mb")), _as_int(disk.get("used_pct"))))
        if buttons:
            rows.append([btn(_t(user_id, "mt_diag"), "mt_diag")])
    # Модуль ядра AmneziaWG на сервере без набора исправлений, а есть профиль 3.1 (status.kmod.warn, KMOD_PLAN А3).
    # Только строка: сам продукт ничего не ставит и не перезапускает, выбор и пересборка — этап Б. Ядро старше поля — молчим.
    kmod = status.get("kmod") if isinstance(status.get("kmod"), dict) else {}
    if kmod.get("warn") is True:
        lines.append("⚠️ " + _t(user_id, "dash_kmod_unpatched"))
        if buttons:
            rows.append([btn(_t(user_id, "mt_kmod"), "mt_kmod")])
    # Этап Б (1.0.13): выбран модуль, а профили работают программой (fallback — например, модуля под новое ядро нет) или
    # установка на этом ядре не удалась (failed) — та же строка, что в шапке SSH-меню, словами ядра; кнопка — к экрану
    # «⚡ Ускорение AmneziaWG» (там «Пересобрать»). Событий боту этап Б не шлёт — видно здесь.
    elif kmod.get("state") in ("fallback", "failed") and isinstance(kmod.get("reason"), str) and kmod.get("reason"):
        key = "dash_kmod_failed_fmt" if kmod.get("state") == "failed" else "dash_kmod_fallback_fmt"
        lines.append("⚠️ " + _tf(user_id, key, esc(kmod_reason(kmod.get("reason"), cap=False))))
        if buttons:
            rows.append([btn(_t(user_id, "mt_kmod"), "mt_kmod")])
    # Выданный профиль 2.0 с большим S4 (status.profiles[].packet_risk, S4-FIX): на мобильных сетях скачивание не идёт.
    # Кнопка — экран «Исправить S4» этого профиля (что будет — до вопроса). Ядро старше поля — молчим.
    for item in profiles:
        risk = packet_risk_of(item)
        if not risk:
            continue
        pid = str(item.get("profile"))
        lines.append("⚠️ " + _tf(user_id, "s4_risk_fmt", esc(profile_name(user_id, pid, status)), risk["s4"]))
        if buttons:
            rows.append([btn(_tf(user_id, "dash_s4_btn_fmt", esc(profile_short(pid, status, user_id))), "pr_s4~%s" % pid)])
    # Линии на сервере (status.lines_check, DUP-LINE-01): нет 2.0 — старые приложения и Keenetic не подключатся ни к
    # одному профилю; свой профиль повторяет чужую линию — кнопка «Переставить … на 2.0». Ядро старше поля — молчим.
    # Ошибка прошлых версий, найденная при обновлении (status.dupline_fix): своя строка и «Исправить»; строки
    # lines_check про то же не дублируем.
    dup = dupline_fix_of(status)
    if dup:
        lines.append("⚠️ " + dupline_text(user_id, "dash_dupline_fmt", dup["line"], dup["from"], dup["port"], dup["users"]))
        if buttons:
            rows.append([btn(_tf(user_id, "dash_dupline_btn_fmt", dup["line"], dup["from"]), "pr_rl~%s" % dup["profile"])])
        return lines, rows
    lines.extend(lines_check_lines(user_id, status))
    rl = lines_check_of(status)["reline"]
    if buttons and rl:
        rows.append(reline_row(user_id, rl, status))
    return lines, rows


def packet_risk_of(item: Any) -> Dict[str, Any]:
    """Риск пакета данных профиля (status.profiles[].packet_risk, S4-FIX): {packet, budget, s4, safe_s4, mtu, keyless}
    с проверенными числами — или {}: риска нет, запись испорчена или ядро старше поля."""
    risk = item.get("packet_risk") if isinstance(item, dict) else None
    if not isinstance(risk, dict):
        return {}
    out: Dict[str, Any] = {}
    for k in ("packet", "budget", "s4", "safe_s4", "mtu", "keyless"):
        v = risk.get(k)
        if not isinstance(v, int) or isinstance(v, bool) or v < 0:
            return {}
        out[k] = v
    return out


def dashboard_text(user_id: Optional[int], status: Dict[str, Any]) -> str:
    lines = ["<b>%s</b>" % _tf(user_id, "welcome_title", esc(product_version(status)))]
    lines.append(_t(user_id, "welcome_subtitle"))
    lines.append("")
    if not bridge_ok(status):
        lines.append("⚠️ " + error_text(user_id, status))
        return "\n".join(lines)
    ip = esc(status.get("server_ip") or "—")
    lines.append("%s <b>%s</b>    %s <code>%s</code>" % (
        _t(user_id, "dash_mode"), esc(mode_label(user_id, status.get("mode"))), _t(user_id, "dash_ip"), ip))
    domain = str(status.get("domain") or "")
    if domain:
        lines.append("%s <code>%s</code>" % (_t(user_id, "dash_domain"), esc(domain)))
    profiles = status_profiles(status)
    if profiles:
        parts = ["%s %s" % (profile_icon(p.get("state")), esc(profile_short(p.get("profile"), status, user_id))) for p in profiles]
        lines.append("%s %s" % (_t(user_id, "dash_profiles"), "   ".join(parts)))
    else:
        lines.append("%s <i>%s</i>" % (_t(user_id, "dash_profiles"), _t(user_id, "dash_no_profiles")))
    # Только строки: кнопки строит клавиатура главного экрана (текст не должен требовать python-telegram-bot)
    lines.extend(dashboard_problems(user_id, status, buttons=False)[0])
    lines.append("%s <b>%s</b>" % (_t(user_id, "dash_users"), esc(status.get("users") or 0)))
    if status.get("installed") is False:
        lines.append("")
        lines.append("⚠️ " + _t(user_id, "dash_not_installed"))
    lines.append("")
    lines.append(_t(user_id, "welcome_prompt"))
    return "\n".join(lines)


def get_main_menu(user_id: Optional[int], status: Optional[Dict[str, Any]] = None) -> "InlineKeyboardMarkup":
    """Разделы в порядке SSH-меню: Пользователи · Состояние · Протоколы · Обслуживание · Настройки.

    Над разделами — быстрые действия, когда есть что чинить (dashboard_problems), а сервер не ответил —
    «🔁 Повторить» (дизайн 0.5.0, сцена error): разделы при этом остаются, язык и справка моста не ждут."""
    status = status or {}
    rows = []
    if status and not bridge_ok(status):
        rows.append([btn(_t(user_id, "btn_retry"), "menu_main")])
    rows.extend(dashboard_problems(user_id, status)[1] if status else [])
    rows += [
        [btn(_t(user_id, "menu_users"), "menu_users"), btn(_t(user_id, "menu_status"), "sec_state")],
        [btn(_t(user_id, "menu_protocols"), "sec_protocols"), btn(_t(user_id, "menu_maintenance"), "sec_maint")],
        [btn(_t(user_id, "menu_settings"), "sec_settings")],
    ]
    url = miniapp_url(status)
    if url:
        rows.append([InlineKeyboardButton(_t(user_id, "menu_panel"), web_app=WebAppInfo(url=url))])
    if status.get("installed") is False:
        rows.append([btn(_t(user_id, "menu_install"), "menu_install")])
    rows.append([btn(_t(user_id, "menu_close"), "close_menu")])
    return kb(rows)


async def render_main(query_or_message, user_id: Optional[int], edit: bool = True) -> None:
    status = await get_status()
    text = dashboard_text(user_id, status)
    markup = get_main_menu(user_id, status)
    if edit:
        await safe_edit_message(query_or_message, text, reply_markup=markup)
    else:
        await query_or_message.reply_text(text, reply_markup=markup, parse_mode="HTML",
                                          disable_web_page_preview=True)


async def cb_menu_main(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    await render_main(query, _uid(update))


async def cb_close_menu(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    try:
        await query.delete_message()
    except Exception as e:  # noqa: BLE001 — сообщение могло быть уже удалено
        logger.debug("close_menu: %s", e)


def first_install_slot(status: Dict[str, Any]) -> str:
    """Место для профиля по умолчанию с экрана первой установки. Обычно awg2 (по месту встанет 2.0). Но awg2 бывает
    занят подхваченным контейнером приложения Amnezia (amnezia-awg2 с 3.1, DUP-LINE-01): тогда — свободное место, на
    которое по «Установить» встанет 2.0 (status.free_lines). Линию выбирает ядро (profile-install без line); такого места
    нет или status не ответил — awg2, как раньше (ядро ответит «уже установлен», а профиль другой линии — в «Протоколах»)."""
    installed = installed_profiles(status) if bridge_ok(status) else []
    if "awg2" not in installed:
        return "awg2"
    lines = status_free_lines(status)
    return next((p for p in ("awg3", "awg1") if p not in installed and lines.get(p) == "2.0"), "awg2")


async def cb_menu_install(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Первая установка: мастер (режим, домен, DNS) живёт в SSH; из бота ставим профиль по умолчанию — 2.0 на awg2, а
    если awg2 занят подхваченным профилем приложения, — на свободное место (first_install_slot)."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    status = await get_status()
    slot = first_install_slot(status)
    # В callback_data место — только когда это не awg2: прежняя кнопка inst_awg2~def осталась как была
    tail = "" if slot == "awg2" else "~%s" % slot
    text = "<b>%s</b>\n\n%s\n\n%s" % (
        _t(user_id, "install_title"), _tf(user_id, "install_body_fmt", esc(profile_line_name(user_id, slot, status))),
        _tf(user_id, "install_ssh_hint", "goamnezia"))
    rows = [[btn(_t(user_id, "install_btn_awg2"), "inst_awg2~def%s" % tail)]]
    # UDP/443 для VPN — признак режима «Pro»: в «Semi-Pro» мастер его не даёт, и
    # карточка профиля эту кнопку прячет (cb_pr_install). Здесь она стояла всегда — и сразу после
    # установки шапка ругалась «режим и порт VPN не совпадают» (критик 24.09, п. 7).
    if not (bridge_ok(status) and str(status.get("mode") or "") == "lite_site"):
        rows.append([btn(_tf(user_id, "install_btn_443_fmt", profile_line(slot, status)), "inst_awg2~443%s" % tail)])
    rows.append(_back_row(user_id))
    await safe_edit_message(query, text, reply_markup=kb(rows))


async def cb_install_awg2(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """inst_awg2~def|443[~<место>] — профиль по умолчанию; место — когда awg2 занят профилем приложения (DUP-LINE-01)."""
    query = update.callback_query
    user_id = _uid(update)
    parts = query.data.split("~")
    if len(parts) not in (2, 3) or parts[1] not in ("def", "443") or (len(parts) == 3 and not valid_profile(parts[2])):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    if await _action_busy(query, user_id):
        return
    port = "443" if parts[1] == "443" else None
    slot = parts[2] if len(parts) == 3 else "awg2"
    await safe_edit_message(query, "⏳ " + _tf(user_id, "pr_installing_fmt", esc(profile_line_name(user_id, slot))),
                            reply_markup=None)
    r = await mutate("profile-install", who=user_id, profile=slot, port=port, preset="default")
    if not bridge_ok(r):
        await show_error(query, user_id, r, "menu_main")
        return
    await safe_edit_message(query, "✅ " + esc(r.get("message") or _t(user_id, "done")),
                            reply_markup=back_kb(user_id, "menu_main"))


# ============================================================================
# РАЗДЕЛ 1: ПОЛЬЗОВАТЕЛИ
# ============================================================================

async def fetch_users() -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
    r = await run_bot_action("user-list", timeout=60)
    users = r.get("users") if bridge_ok(r) else None
    return r, users_sorted(users if isinstance(users, list) else [])


def users_list_text(user_id: Optional[int], users: List[Dict[str, Any]], page: int, pages: int,
                    total: Optional[int] = None) -> str:
    """users — люди этой страницы; total — сколько их всего во всём списке. «Всего» по срезу страницы врало: при 14
    людях первая страница говорила «всего: 8», вторая — «всего: 6» (живая проверка на test1, 03.10)."""
    lines = ["<b>%s</b>" % _t(user_id, "users_title")]
    if not users:
        lines.append("")
        lines.append("<i>%s</i>" % _t(user_id, "users_none"))
        return "\n".join(lines)
    lines.append(_t(user_id, "users_legend"))
    lines.append("")
    now = _dt.datetime.now(_dt.timezone.utc)
    for u in users:
        name = esc(u.get("name"))
        label = str(u.get("label") or "")
        have = set(u.get("profiles") or (u.get("peers") or {}).keys())
        # Профили — линиями в порядке 3.1 → 2.0 → 1.x, как в карточке (DS2-55), а не id по алфавиту
        profs = ", ".join(profile_short(x, None, user_id) for x in PROFILE_IDS if x in have) or "—"
        traffic = u.get("traffic") or {}
        used = human_bytes(int(traffic.get("rx") or 0) + int(traffic.get("tx") or 0), user_id)
        exp = str(u.get("expires") or "")[:10]
        tail = " · %s" % esc(exp) if exp else ""
        shown = "<code>%s</code>" % name
        if label and label != u.get("name"):
            shown += " — %s" % esc(label[:24])
        lines.append("%s %s · %s · %s%s" % (user_icon(u, now), shown, esc(profs), used, tail))
    if pages > 1:
        lines.append("")
        lines.append(_tf(user_id, "page_of_fmt", page + 1, pages, len(users) if total is None else total))
    lines.append("")
    lines.append(_t(user_id, "users_hint"))
    return "\n".join(lines)


def users_keyboard(user_id: Optional[int], users: List[Dict[str, Any]], page: int = 0) -> "InlineKeyboardMarkup":
    """Список страницами по 8: без страниц сотня пользователей упирается в лимиты Telegram."""
    chunk, page, pages = paginate(users, page, USERS_PER_PAGE)
    now = _dt.datetime.now(_dt.timezone.utc)
    rows = []
    for u in chunk:
        name = str(u.get("name"))
        rows.append([btn("%s %s" % (user_icon(u, now), name), "u_view~%s" % name)])
    if pages > 1:
        nav = []
        if page > 0:
            nav.append(btn("‹", "menu_users~%d" % (page - 1)))
        nav.append(btn("%d/%d" % (page + 1, pages), "noop"))
        if page < pages - 1:
            nav.append(btn("›", "menu_users~%d" % (page + 1)))
        rows.append(nav)
    rows.append([btn(_t(user_id, "users_btn_add"), "u_add")])
    rows.append([btn(_t(user_id, "users_btn_add_bulk"), "u_addm")])
    # «Удалить сразу несколько» — когда есть кого удалять
    if users:
        rows.append([btn(_t(user_id, "users_btn_del_bulk"), "u_delm")])
    rows.append([btn(_t(user_id, "btn_refresh"), "menu_users~%d" % page), btn(_t(user_id, "btn_back"), "menu_main")])
    return InlineKeyboardMarkup(rows)


async def cb_menu_users(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    page = 0
    if "~" in query.data:
        try:
            page = int(query.data.split("~", 1)[1])
        except ValueError:
            page = 0
    r, users = await fetch_users()
    if not bridge_ok(r):
        await show_error(query, user_id, r, "menu_main")
        return
    chunk, page, pages = paginate(users, page, USERS_PER_PAGE)
    await safe_edit_message(query, users_list_text(user_id, chunk, page, pages, len(users)),
                            reply_markup=users_keyboard(user_id, users, page))


async def _fetch_user(name: str) -> Tuple[Dict[str, Any], Optional[Dict[str, Any]]]:
    r = await run_bot_action("user-show", timeout=60, name=name)
    user = r.get("user") if bridge_ok(r) else None
    return r, user if isinstance(user, dict) else None


_KEY_FILE_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}\.conf$")


def key_file_stem(r: Dict[str, Any], name: str, profile: str, host: str = "") -> str:
    """Основа имени файла .conf — из ответа user-key (file_name, Н-2): то же имя, что у страницы, подписки, панели и SSH
    (anna-2_0), не длиннее 15 знаков — AmneziaWG берёт из него имя туннеля. Ядро старше поля — прежнее имя
    (с другим адресом — с адресом в имени)."""
    fname = str((r or {}).get("file_name") or "")
    if _KEY_FILE_RE.match(fname):
        return fname[:-len(".conf")]
    return "%s-%s-%s" % (name, profile, host) if host else "%s-%s" % (name, profile)


def peer_has_key(peer: Any) -> bool:
    """Лежит ли приватная часть ключа этого пира на сервере.

    Мост кладёт `has_key` в КАЖДЫЙ пир `user-show`/`user-list` (docs/CONTRACT.md
    § 3.2): у пользователя, подхваченного из контейнера приложения Amnezia,
    приватного ключа нет — его хранит само приложение, — и `user-key` со
    `share-create` по такому пиру гарантированно отвечают `no_private_key`.
    Признак нужен именно здесь: приватный ключ наружу не отдаётся, и отличить
    «ключ выдаётся» от «выдача заведомо откажет» больше нечем.

    Поля нет вовсе (мост старее 0.3.0) — считаем, что ключ есть: спрятать
    рабочую выдачу хуже, чем показать кнопку, которая объяснит отказ словами.
    """
    return bool(peer.get("has_key", True)) if isinstance(peer, dict) else True


def peers_with_key(user: Dict[str, Any]) -> List[str]:
    """Профили пользователя, по которым файл ещё можно выдать."""
    peers = user.get("peers") if isinstance(user.get("peers"), dict) else {}
    return [p for p in PROFILE_IDS if p in peers and peer_has_key(peers.get(p))]


def imported_profiles(user: Dict[str, Any]) -> List[str]:
    """Профили, ключ которых выдан в приложении Amnezia ещё до подхвата (`has_key: false`)."""
    peers = user.get("peers") if isinstance(user.get("peers"), dict) else {}
    return [p for p in PROFILE_IDS if p in peers and not peer_has_key(peers.get(p))]


# ── Ключ, выданный в приложении Amnezia ──────────────────────────────────────
# У такого пира на сервере только открытая часть ключа; сам ключ — у человека в
# приложении и в ссылке или файле, которые админ ему когда-то отправил. Правило
# владельца: где бы ключ ни выдавался или показывался, бот говорит одно и то же —
# где ключ, что у человека всё работает, почему отсюда его не показать, и два
# выхода: «Привязать старый ключ» (без потерь) и «Перевыпустить ключ» (старый
# сразу перестанет подключаться). Раньше экраны молчали или отвечали голым
# «ошибка no_private_key» — это тупик, а не объяснение.

def imported_rows(user_id: Optional[int], name: str, profiles: List[str]) -> list:
    """Два выхода для каждого профиля с ключом из приложения: сначала тот, что без потерь."""
    rows = []
    for profile in profiles:
        short = profile_short(profile, None, user_id)
        rows.append([btn("%s · %s" % (short, _t(user_id, "user_peer_attach_btn")), "u_att~%s~%s" % (name, profile))])
        rows.append([btn("%s · %s" % (short, _t(user_id, "user_peer_reissue_btn")), "u_reis~%s~%s" % (name, profile))])
    return rows


def imported_view(user_id: Optional[int], name: str, profiles: List[str], head: str = "",
                  command: bool = False, extra_rows: Optional[list] = None) -> Tuple[str, "InlineKeyboardMarkup"]:
    """Экран вместо выдачи, которая заведомо не выйдет: правда про каждый такой профиль и оба выхода.

    head — отказ ядра (no_private_key) целиком: его текст уже говорит, где ключ и чем его вернуть,
    и второй такой же абзац под ним был бы шумом — тогда под отказом только кнопки. command —
    экран ответа на /key: там «Назад» некуда, и последняя кнопка открывает карточку. extra_rows —
    кнопки экрана, откуда пришли (страницы пользователя), перед «Назад».
    """
    lines = [head, ""] if head else []
    lines.append("<b>%s</b>" % _tf(user_id, "key_title_fmt", esc(name),
                                   esc(", ".join(profile_name(user_id, p) for p in profiles))))
    for profile in ([] if head else profiles):
        lines.append("")
        lines.append("<i>%s</i>" % _tf(user_id, "user_peer_imported_note_fmt", esc(profile_name(user_id, profile))))
    rows = imported_rows(user_id, name, profiles) + list(extra_rows or [])
    if command:
        rows.append([btn(_t(user_id, "users_open_card"), "u_view~%s" % name)])
    else:
        rows.append(_back_row(user_id, "u_view~%s" % name))
    return "\n".join(lines), InlineKeyboardMarkup(rows)


def imported_short_lines(user_id: Optional[int], profiles: List[str]) -> List[str]:
    """Строки для экранов выбора профиля: почему такого профиля в списке нет и где выход."""
    out: List[str] = []
    for profile in profiles:
        out.append("")
        out.append("<i>%s</i>" % _tf(user_id, "user_peer_imported_short_fmt", esc(profile_name(user_id, profile))))
    return out


def user_card_text(user_id: Optional[int], user: Dict[str, Any], status: Dict[str, Any]) -> str:
    name = str(user.get("name") or "")
    label = str(user.get("label") or "").strip()
    # Без подписи (или с подписью, равной имени) — имя один раз: «👤 bot-single (bot-single)»
    # читалось как ошибка (живая проверка на test1 03.10, BOT-6). Так же, как в списке людей.
    if label and label != name:
        title = _tf(user_id, "user_card_title", esc(name), esc(label))
    else:
        title = _tf(user_id, "user_card_title_plain", esc(name))
    lines = ["<b>%s</b>" % title]
    state = user_state(user)
    state_key = {"on": "state_enabled", "off": "state_disabled", "exp": "state_expired", "lim": "state_quota"}[state]
    lines.append("%s: %s %s" % (_t(user_id, "user_state"), USER_ICONS[state], _t(user_id, state_key)))
    quota = int(user.get("quota_bytes") or 0)
    traffic = user.get("traffic") or {}
    used = int(traffic.get("rx") or 0) + int(traffic.get("tx") or 0)
    lines.append("%s: %s    %s: %s" % (
        _t(user_id, "user_quota_label"),
        human_bytes(quota, user_id) if quota else _t(user_id, "unlimited"),
        _t(user_id, "user_traffic_label"), human_bytes(used, user_id)))
    expires = str(user.get("expires") or "")
    lines.append("%s: %s" % (_t(user_id, "user_expiry_label"),
                             (esc(expires.replace("T", " ").rstrip("Z")) + " UTC") if expires else _t(user_id, "never")))
    peers = user.get("peers") if isinstance(user.get("peers"), dict) else {}
    lines.append("")
    if not peers:
        lines.append("<i>%s</i>" % _t(user_id, "user_no_peers"))
    for profile in [p for p in PROFILE_IDS if p in peers]:
        peer = peers.get(profile) or {}
        info = profile_info(status, profile)
        line = profile_line(profile, status)
        port = info.get("port") or "—"
        min_client = MIN_CLIENT_BY_LINE.get(line, "—")
        # Как в дизайне 0.5.0: линия и порт заголовком, адрес в VPN и подключение, приложение — строками
        # Порт и так в заголовке: здесь — только линия, даже когда её держат два профиля (DUP-LINE-01)
        lines.append("<b>%s</b>" % _tf(user_id, "user_peer_head_fmt", esc(profile_line_name(user_id, profile, status)), esc(port)))
        details = [_tf(user_id, "user_peer_addr_fmt", esc(peer.get("ip") or "—"))]
        if not peer.get("active", True):
            details.append(_t(user_id, "peer_inactive"))
        hs = int(peer.get("last_handshake") or 0)
        if hs > 0:
            ago = int(time.time()) - hs
            details.append(_tf(user_id, "peer_handshake_fmt", esc(_ago_text(user_id, ago))))
        else:
            details.append(_t(user_id, "peer_handshake_never"))
        lines.append("  " + " · ".join(details))
        if peer_has_key(peer):
            lines.append("  " + _tf(user_id, "user_peer_app_fmt", esc(min_client)))
        else:
            # Правду про импортированный ключ человек узнавал, только ткнув в
            # кнопку выдачи и получив no_private_key. Теперь она в карточке —
            # вместе с тем, где ключ и чем его вернуть (кнопки — на этом профиле).
            lines.append("  <i>%s</i>" % _tf(user_id, "user_peer_imported_note_fmt", esc(profile_name(user_id, profile, status))))
    return "\n".join(lines)


def _ago_text(user_id: Optional[int], seconds: int) -> str:
    seconds = max(0, int(seconds))
    if seconds < 60:
        return _tf(user_id, "ago_seconds_fmt", seconds)
    if seconds < 3600:
        return _tf(user_id, "ago_minutes_fmt", seconds // 60)
    if seconds < 86400:
        return _tf(user_id, "ago_hours_fmt", seconds // 3600)
    return _tf(user_id, "ago_days_fmt", seconds // 86400)


def user_card_keyboard(user_id: Optional[int], user: Dict[str, Any],
                       key_addr: bool = False, pin_addr: bool = False) -> "InlineKeyboardMarkup":
    """Кнопки карточки; key_addr — у сервера есть адрес, отличный от адреса в ключах этого
    пользователя (user_key_addr_offered): тогда ряд «Ключ на другой адрес»; pin_addr — у машины
    два адреса и больше или адрес уже закреплён (user_pin_offered): ряд «📍 Свой адрес за человеком»."""
    name = str(user.get("name") or "")
    peers = user.get("peers") if isinstance(user.get("peers"), dict) else {}
    rows = []
    # По каждому профилю — четыре кнопки ключа (два стиля: .conf и Amnezia).
    # Кроме пира с ключом из приложения Amnezia: у сервера только открытая часть,
    # все четыре ответили бы `no_private_key`. Вместо них — два выхода: привязать
    # старый ключ (без потерь) и перевыпуск (то же в SSH-меню).
    for profile in [p for p in PROFILE_IDS if p in peers]:
        if not peer_has_key(peers.get(profile)):
            rows.extend(imported_rows(user_id, name, [profile]))
            continue
        short = profile_short(profile, None, user_id)
        rows.append([btn("%s · %s" % (short, _t(user_id, "key_btn_qr_conf")), "u_key~%s~%s~qrconf" % (name, profile)),
                     btn("%s · %s" % (short, _t(user_id, "key_btn_conf_file")), "u_key~%s~%s~conf" % (name, profile))])
        rows.append([btn("%s · %s" % (short, _t(user_id, "key_btn_vpn")), "u_key~%s~%s~vpn" % (name, profile)),
                     btn("%s · %s" % (short, _t(user_id, "key_btn_qr_vpn")), "u_key~%s~%s~qrvpn" % (name, profile))])
    if peers_with_key(user):
        # Ссылка нужна там, где документ Telegram не годится: роутер, чужой
        # компьютер, десктоп без Telegram. Без конфигураций раздавать нечего —
        # а по импортированному пиру `share-create` отвечает тем же отказом,
        # что и выдача файлом (docs/SHARE.md § «Коды ошибок»).
        rows.append([btn(_t(user_id, "user_share"), "u_share~%s" % name)])
        # Тот же ключ с другим адресом сервера в Endpoint — разово, за пользователем
        # ничего не сохраняется. Без приватного ключа выдавать нечего, без второго
        # адреса у машины — не на что менять: тогда кнопки нет.
        if key_addr:
            rows.append([btn(_t(user_id, "key_addr_btn"), "u_kaddr~%s" % name)])
    # Свой адрес — навсегда, в отличие от разового «Ключа на другой адрес» (L-10, user-set-address)
    if pin_addr and peers:
        rows.append([btn(_t(user_id, "user_pin_btn"), "u_pin~%s" % name)])
    # Страница подключения. Ни ключ на сервере, ни включённость человека для кнопки НЕ условие:
    # раньше она пряталась, когда все ключи человека из приложения Amnezia или сам он выключен, —
    # и уже созданную страницу (живую: с пояснением вместо ключа или с «доступ приостановлен»,
    # после включения — снова с ключами) нельзя было ни увидеть, ни отозвать (UI-4, как в
    # панели). Создать новую в этих случаях нельзя — это решает экран страницы, а список и
    # отзыв доступны всегда.
    if peers:
        rows.append([btn(_t(user_id, "user_page"), "u_page~%s" % name)])
        # Подписка — постоянная ссылка для Clash и роутеров (docs/SUBSCRIPTION.md): по тем же правилам, что страница —
        # созданную раньше видно и у выключенного человека, и у человека с ключами из приложения.
        rows.append([btn(_t(user_id, "user_sub"), "u_sub~%s" % name)])
    rows.append([btn(_t(user_id, "user_set_quota"), "u_quota~%s" % name),
                 btn(_t(user_id, "user_set_expiry"), "u_exp~%s" % name)])
    enabled = bool(user.get("enabled", True))
    # В callback_data — состояние, которое человек ХОЧЕТ получить: два апдейта
    # на одну кнопку иначе выключали и тут же включали обратно.
    rows.append([btn(_t(user_id, "user_disable_item") if enabled else _t(user_id, "user_enable_item"),
                     "u_en~%s~%s" % (name, "off" if enabled else "on")),
                 btn(_t(user_id, "user_rename_item"), "u_ren~%s" % name)])
    # «Убрать профиль» рядом с «Добавить»: пара на случай, когда профиль нужно
    # именно убрать. Перевыпуск ключа импортированному пиру этой парой больше не
    # делают — он стоит своей кнопкой на самом профиле (u_reis~).
    rows.append([btn(_t(user_id, "user_add_profile"), "u_addp~%s" % name)])
    rows.append([btn(_t(user_id, "user_del_profile"), "u_delp~%s" % name)])
    rows.append([btn(_t(user_id, "user_delete_item"), "u_del~%s" % name)])
    rows.append([btn(_t(user_id, "btn_refresh"), "u_view~%s" % name), btn(_t(user_id, "btn_back"), "menu_users")])
    return InlineKeyboardMarkup(rows)


def _name_from_data(data: str, prefix: str) -> str:
    """Имя пользователя из callback_data с проверкой регекса — до любого subprocess."""
    rest = data[len(prefix):] if data.startswith(prefix) else ""
    name = rest.split("~", 1)[0]
    return name if valid_name(name) else ""


async def user_card_view(user_id: Optional[int], name: str, note: str = "") -> Tuple[str, "InlineKeyboardMarkup"]:
    """Текст и кнопки карточки (или экран «не найден» / ошибки моста с возвратом к списку).

    Отдельно от show_user_card: после привязки старого ключа карточка уходит
    НОВЫМ сообщением — ключ пришёл текстом или файлом, править там нечего.
    """
    r, user = await _fetch_user(name)
    if user is None:
        # Итог действия (note) — первой строкой и здесь: привязка старого ключа уже прошла, а
        # карточку прочитать не вышло — без этой строки человек видел одну «ошибку», решал, что
        # привязка не удалась, и шёл «Перевыпустить» — ломать рабочий ключ человека (UI-2).
        head = (note + "\n\n") if note else ""
        if r.get("code") in ("user_not_found", "invalid_name"):
            return head + "❌ " + _tf(user_id, "user_not_found_fmt", esc(name)), back_kb(user_id, "menu_users")
        return head + fail_text(user_id, r), back_kb(user_id, "menu_users")
    status = await get_status()
    text = user_card_text(user_id, user, status)
    if note:
        text = "%s\n\n%s" % (note, text)
    key_addr = await user_key_addr_offered(r, user, status)
    pin_addr = await user_pin_offered(user, status)
    return text, user_card_keyboard(user_id, user, key_addr=key_addr, pin_addr=pin_addr)


async def show_user_card(query, user_id: Optional[int], name: str, note: str = "") -> None:
    """Карточка пользователя; `note` — строка итога действия над самой карточкой.

    Тому, кто только что перевыпустил ключ, нужны сразу и результат, и кнопки
    выдачи: экран «готово» с одним «Назад» заставлял бы возвращаться руками.
    """
    text, markup = await user_card_view(user_id, name, note=note)
    await safe_edit_message(query, text, reply_markup=markup)


async def cb_user_view(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    name = _name_from_data(query.data, "u_view~")
    if not name:
        await show_bad_input(query, user_id, "menu_users")
        return
    await show_user_card(query, user_id, name)


# ── Выдача ключей: два стиля ─────────────────────────────────────────────────
KEY_FORMATS = {"qrconf": "qr-conf", "conf": "conf", "vpn": "vpn", "qrvpn": "qr-vpn"}
VPN_LINK_INLINE_MAX = 3800   # всё сообщение (подпись + ссылка) длиннее — файлом: лимит Telegram 4096
ALBUM_SIZE = 10              # жёсткий предел Telegram на медиагруппу


# ── Ключ на другой адрес сервера (edge-status key_choices, --endpoint у user-key и share-create) ──
# У машины бывает несколько внешних IPv4 (lib/edgeips.sh). Админ может РАЗОВО выдать тот же ключ
# (та же пара ключей, тот же порт профиля) с другим адресом сервера в Endpoint; за пользователем
# ничего не сохраняется — закреплённый адрес остаётся делом user-set-address. В callback_data едет
# не номер в списке, а сам адрес в коротком виде: IPv4 — 8 hex (203.0.113.11 → cb00710b), домен —
# «h» + 6 hex sha1. Обратно код переводится пересчётом по ТЕКУЩЕМУ key_choices: кнопка, нарисованная
# до смены адресов, не выдаст ключ на соседний адрес, а скажет «адреса больше нет».
KEY_ADDR_RE = re.compile(r"^(?:[0-9a-f]{8}|h[0-9a-f]{6})$")
# Отказы ядра на --endpoint: сообщение у них человеческое (у address_not_here — со списком
# допустимых адресов), показываем его без кода.
KEY_ADDR_ERRORS = ("address_not_here", "invalid_ip", "addresses_unknown")


def key_addr_code(host: Any) -> str:
    """Код адреса для callback_data; пусто — не IPv4 и не домен (такой кнопки не будет)."""
    host = str(host or "").strip().lower()
    if IPV4_RE.match(host):
        if not valid_ipv4(host) or host == "0.0.0.0":
            return ""
        return "".join("%02x" % int(part) for part in host.split("."))
    if host and HOST_RE.match(host):
        return "h" + hashlib.sha1(host.encode("utf-8")).hexdigest()[:6]
    return ""


def key_choices(edge: Optional[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """edge-status.key_choices — только адреса, которые кодируются в кнопку, без повторов; к
    каждому добавлен `code`. Порядок — как у моста (обычный первым, «замолчавшие» в конце)."""
    items = edge.get("key_choices") if isinstance(edge, dict) else None
    out: List[Dict[str, Any]] = []
    seen = set()
    for c in items if isinstance(items, list) else []:
        if not isinstance(c, dict):
            continue
        host = str(c.get("host") or "").strip()
        code = key_addr_code(host)
        if not code or code in seen:
            continue
        seen.add(code)
        out.append(dict(c, host=host, code=code))
    return out


def key_addr_find(edge: Optional[Dict[str, Any]], code: str) -> Optional[Dict[str, Any]]:
    """Вариант адреса по коду из кнопки; None — такого адреса у сервера больше нет."""
    for c in key_choices(edge):
        if c["code"] == code:
            return c
    return None


def user_key_host(user_r: Optional[Dict[str, Any]], user: Optional[Dict[str, Any]],
                  edge: Optional[Dict[str, Any]]) -> str:
    """Адрес в ключах пользователя «как обычно»: `key_host` из user-show (в карточке или в корне
    ответа), без него — общий `keys_host` из edge-status; пусто — адрес не определён."""
    for src in (user, user_r):
        host = str(src.get("key_host") or "").strip() if isinstance(src, dict) else ""
        if host:
            return host
    return str(edge.get("keys_host") or "").strip() if isinstance(edge, dict) else ""


def key_addr_alternatives(edge: Optional[Dict[str, Any]], own_host: str) -> List[Dict[str, Any]]:
    """Адреса, на которые можно выдать ключ, кроме того, что и так стоит в ключах пользователя."""
    own = (own_host or "").strip().lower()
    return [c for c in key_choices(edge) if c["host"].lower() != own]


async def user_key_addr_offered(user_r: Dict[str, Any], user: Dict[str, Any],
                                status: Optional[Dict[str, Any]]) -> bool:
    """Показывать ли в карточке «Ключ на другой адрес»: есть приватный ключ хотя бы в одном
    профиле и у сервера есть адрес, отличный от адреса в ключах этого пользователя.

    Сначала — без похода в мост: `status.key_hosts` (те же хосты, что key_choices) уже в кэше
    статуса, адрес пользователя — в user-show. Нет одного из них (ядро старее) — edge-status из кэша.
    """
    if not peers_with_key(user):
        return False
    own = user_key_host(user_r, user, None)
    hosts = status.get("key_hosts") if isinstance(status, dict) else None
    if own and isinstance(hosts, list):
        return any(key_addr_code(h) and str(h).strip().lower() != own.lower() for h in hosts)
    edge = await get_edge_status()
    if not bridge_ok(edge):
        return False
    return bool(key_addr_alternatives(edge, user_key_host(user_r, user, edge)))


async def resolve_key_addr(code: str) -> Tuple[Dict[str, Any], Optional[Dict[str, Any]]]:
    """Адрес по коду из кнопки: сначала по кэшу edge-status, промах — по свежему ответу
    (список мог смениться, пока висел экран). → (ответ edge-status, вариант или None)."""
    edge = await get_edge_status()
    choice = key_addr_find(edge, code) if bridge_ok(edge) else None
    if choice is None:
        edge = await get_edge_status(fresh=True)
        choice = key_addr_find(edge, code) if bridge_ok(edge) else None
    return edge, choice


def key_addr_label(user_id: Optional[int], choice: Dict[str, Any]) -> str:
    """Подпись кнопки адреса: домен — «(домен)», IP — с вердиктом сторожа теми же словами, что
    таблица «Адреса» (у машины с одним адресом вердикта нет — только сам адрес)."""
    host = str(choice.get("host") or "")
    if str(choice.get("kind") or "") == "domain" or not valid_ipv4(host):
        return _tf(user_id, "key_addr_domain_fmt", host)
    verdict = choice.get("verdict")
    if verdict in (None, ""):
        return host
    # У «тихих» вердиктов в словаре своя точка-разделитель — второй не нужно
    return "%s · %s" % (host, _edge_mark(user_id, verdict).lstrip("·").strip())


def key_addr_error_text(user_id: Optional[int], r: Dict[str, Any]) -> str:
    """Отказ моста: у кодов --endpoint — его сообщение как есть, у остальных — обычный error_text."""
    msg = str(r.get("message") or "").strip()
    if str(r.get("code") or "") in KEY_ADDR_ERRORS and msg:
        return esc(msg)
    return error_text(user_id, r)


def key_host_shown(r: Dict[str, Any], host: str) -> str:
    """Какой адрес назвать в подписи и в имени файла: `key_host` из ответа моста (он и стоит в
    Endpoint), иначе запрошенный. Без разового адреса — пусто: обычная выдача не меняется."""
    if not host:
        return ""
    got = str(r.get("key_host") or "").strip()
    # В имя файла — только буквы, цифры, точки и дефисы: ответ моста тоже проверяем
    if got and (valid_ipv4(got) or HOST_RE.match(got.lower())):
        return got
    return host


async def show_key_addr_screen(query, user_id: Optional[int], name: str, note: str = "") -> None:
    """Экран «Ключ на другой адрес»: какой адрес сейчас в ключах и кнопки остальных адресов."""
    r, user = await _fetch_user(name)
    if user is None:
        await show_error(query, user_id, r, "menu_users")
        return
    if not peers_with_key(user):
        # Ключи пропали, пока экран висел (перевыпуск, импорт): выдавать нечего — в карточку
        await show_user_card(query, user_id, name, note=note)
        return
    edge = await get_edge_status()
    if not bridge_ok(edge):
        await show_error(query, user_id, edge, "u_view~%s" % name)
        return
    own = user_key_host(r, user, edge)
    alts = key_addr_alternatives(edge, own)
    lines = [note, ""] if note else []
    lines.append("<b>%s</b>" % _tf(user_id, "key_addr_title_fmt", esc(user.get("label") or name)))
    lines.append("")
    lines.append(_tf(user_id, "key_addr_now_fmt", esc(own or "—")))
    if user.get("key_host_gone") is True or r.get("key_host_gone") is True:
        # Закреплённый адрес пользователя ушёл с машины: его ключи смотрят в пустоту
        lines.append("⚠️ " + esc(_t(user_id, "key_addr_gone")))
    lines.append("")
    lines.append(_t(user_id, "key_addr_pick") if alts else _t(user_id, "key_addr_none"))
    rows = []
    for c in alts:
        addr = c["code"]
        rows.append([btn(key_addr_label(user_id, c), "u_kah~%s~%s" % (name, addr))])
    rows.append(_back_row(user_id, "u_view~%s" % name))
    await safe_edit_message(query, "\n".join(lines), reply_markup=InlineKeyboardMarkup(rows))


async def show_key_addr_miss(query, user_id: Optional[int], name: str, edge: Dict[str, Any]) -> None:
    """Код адреса из кнопки не нашёлся: мост не ответил — ошибка; адреса больше нет — алерт и
    экран адресов заново (со свежим списком)."""
    if not bridge_ok(edge):
        await query.answer()
        await show_error(query, user_id, edge, "u_view~%s" % name)
        return
    gone = _t(user_id, "key_addr_gone")
    await query.answer(gone, show_alert=True)
    await show_key_addr_screen(query, user_id, name, note="⚠️ " + esc(gone))


async def cb_user_key_addr(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """u_kaddr~<name>: «Ключ на другой адрес» — выбор адреса сервера."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    name = _name_from_data(query.data, "u_kaddr~")
    if not name:
        await show_bad_input(query, user_id, "menu_users")
        return
    await show_key_addr_screen(query, user_id, name)


async def cb_user_key_addr_formats(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """u_kah~<name>~<addr>: профиль и вид ключа для выбранного адреса — те же четыре кнопки, что в
    карточке, и «Скачать файлом по ссылке», только с адресом."""
    query = update.callback_query
    user_id = _uid(update)
    parts = str(query.data).split("~")
    if len(parts) != 3 or not valid_name(parts[1]) or not KEY_ADDR_RE.match(parts[2]):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    name, addr = parts[1], parts[2]
    edge, choice = await resolve_key_addr(addr)
    if choice is None:
        await show_key_addr_miss(query, user_id, name, edge)
        return
    await query.answer()
    r, user = await _fetch_user(name)
    if user is None:
        await show_error(query, user_id, r, "menu_users")
        return
    have = peers_with_key(user)
    if not have:
        # Ключей не осталось, пока экран висел (перевыпуск, импорт): выдавать нечего — в карточку
        await show_user_card(query, user_id, name)
        return
    host = str(choice.get("host") or "")
    lines = ["<b>%s</b>" % _tf(user_id, "key_addr_title_fmt", esc(user.get("label") or name)), "",
             _tf(user_id, "key_addr_formats_fmt", esc(host))]
    if choice.get("verdict") == "dark":
        lines.append("⚠️ " + esc(_t(user_id, "key_addr_dark_warn")))
    # Профиль с ключом из приложения Amnezia кнопок здесь не получает — сказано, почему и где выход
    lines.extend(imported_short_lines(user_id, imported_profiles(user)))
    rows = []
    for profile in have:
        short = profile_short(profile, None, user_id)
        rows.append([btn("%s · %s" % (short, _t(user_id, "key_btn_qr_conf")), "u_ka~%s~%s~qrconf~%s" % (name, profile, addr)),
                     btn("%s · %s" % (short, _t(user_id, "key_btn_conf_file")), "u_ka~%s~%s~conf~%s" % (name, profile, addr))])
        rows.append([btn("%s · %s" % (short, _t(user_id, "key_btn_vpn")), "u_ka~%s~%s~vpn~%s" % (name, profile, addr)),
                     btn("%s · %s" % (short, _t(user_id, "key_btn_qr_vpn")), "u_ka~%s~%s~qrvpn~%s" % (name, profile, addr))])
        rows.append([btn("%s · %s" % (short, _t(user_id, "user_share")), "u_shf~%s~%s~%s" % (name, profile, addr))])
    rows.append(_back_row(user_id, "u_kaddr~%s" % name))
    await safe_edit_message(query, "\n".join(lines), reply_markup=InlineKeyboardMarkup(rows))


# ── Свой адрес сервера за человеком (user-set-address, L-10; SSH: «Адрес сервера в ключе») ──
# У машины несколько внешних адресов (docs/EDGEIPS.md §3.1): за человеком можно закрепить один из них —
# его новые ключи пойдут на этот адрес, и блокировка одного адреса не роняет всех. Ключи не
# перевыпускаются: меняется только адрес в Endpoint, а уже выданный конфиг смотрит на прежний — это
# говорит ответ ядра (resend_required). Пункт нужен, когда выбирать есть из чего (два адреса и больше)
# или адрес уже закреплён — иначе его не снять (как _user_address_offer в SSH).

def edge_machine_ips(edge: Optional[Dict[str, Any]]) -> List[str]:
    """Внешние IPv4 машины из edge-status (ips[].ip), без повторов, в порядке моста."""
    out: List[str] = []
    for item in ((edge or {}).get("ips") if isinstance((edge or {}).get("ips"), list) else []):
        ip = str((item or {}).get("ip") or "").strip() if isinstance(item, dict) else ""
        if valid_ipv4(ip) and ip != "0.0.0.0" and ip not in out:
            out.append(ip)
    return out


async def user_pin_offered(user: Dict[str, Any], status: Optional[Dict[str, Any]] = None) -> bool:
    """Кнопка «📍 Свой адрес за человеком» в карточке: адрес уже закреплён или у машины их два и больше.

    Сначала — без похода в мост, как у «Ключа на другой адрес»: status.key_hosts (он в кэше статуса)
    — это адреса машины и IP сервера плюс вписанный в ключи адрес; вписанный не считаем, он может быть
    чужим или пропавшим. Поля нет (ядро старее) — адреса машины из edge-status (кэш)."""
    if str(user.get("endpoint_ip") or "").strip():
        return True
    hosts = status.get("key_hosts") if isinstance(status, dict) else None
    if isinstance(hosts, list):
        manual = str(status.get("endpoint_host") or "").strip()
        ips = {h for h in (str(x or "").strip() for x in hosts)
               if valid_ipv4(h) and h != "0.0.0.0" and h != manual}
        return len(ips) >= 2
    edge = await get_edge_status()
    return bridge_ok(edge) and len(edge_machine_ips(edge)) >= 2


def pin_code_ip(code: str) -> Optional[str]:
    """Адрес из callback_data: «-» — вернуть общий (пусто), 8 hex — IPv4 (key_addr_code), иначе None."""
    if code == "-":
        return ""
    if not re.fullmatch(r"[0-9a-f]{8}", code or ""):
        return None
    return ".".join(str(int(code[i:i + 2], 16)) for i in (0, 2, 4, 6))


async def show_user_pin_screen(query, user_id: Optional[int], name: str) -> None:
    """Экран «Свой адрес за человеком» (сцена user-pin): что сейчас в ключах и адреса машины кнопками."""
    r, user = await _fetch_user(name)
    if user is None:
        await show_error(query, user_id, r, "menu_users")
        return
    edge = await get_edge_status()
    if not bridge_ok(edge):
        await show_error(query, user_id, edge, "u_view~%s" % name)
        return
    ips = edge_machine_ips(edge)
    own = str(user.get("endpoint_ip") or "").strip()
    common = str(edge.get("keys_host") or "").strip()
    lines = ["<b>%s</b>" % _tf(user_id, "user_pin_title_fmt", esc(name)), ""]
    if own and own not in ips:
        lines.append("⚠️ " + _tf(user_id, "user_pin_now_gone_fmt", esc(own)))
    elif own:
        lines.append(_tf(user_id, "user_pin_now_own_fmt", esc(own)))
    else:
        lines.append(_tf(user_id, "user_pin_now_common_fmt", esc(common or "—")))
    if edge.get("domain_endpoint") is True and common:
        # В ключах домен. Вписанный руками («Адрес сервера в ключах») побеждает свой адрес — тот запишется
        # и подействует позже; домен по умолчанию (режим с сайтом) своему адресу уступает — как в SSH.
        status = await get_status()
        manual = str(status.get("endpoint_host") or "").strip() if bridge_ok(status) else ""
        key = "user_pin_domain_fmt" if manual and not valid_ipv4(manual) else "user_pin_site_domain_fmt"
        lines.append("")
        lines.append("ℹ️ " + _tf(user_id, key, esc(common)))
    lines.append("")
    lines.append("<i>%s</i>" % (_t(user_id, "user_pin_hint") if ips else _t(user_id, "user_pin_none")))
    buttons = []
    for ip in ips:
        label = ip
        if ip == own or (not own and ip == common):
            label += " · " + _t(user_id, "user_pin_mark_now")
        addr = key_addr_code(ip)                # 8 hex: IPv4 — callback_data не длиннее 51 байта
        buttons.append(btn(label, "u_pin_set~%s~%s" % (name, addr)))
    rows = [buttons[i:i + 2] for i in range(0, len(buttons), 2)]
    if own:
        rows.append([btn(_t(user_id, "user_pin_reset_btn"), "u_pin_set~%s~-" % name)])
    rows.append(_back_row(user_id, "u_view~%s" % name))
    await safe_edit_message(query, "\n".join(lines), reply_markup=kb(rows))


async def cb_user_pin(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """u_pin~<name>: свой адрес сервера за человеком — выбор из адресов машины."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    name = _name_from_data(query.data, "u_pin~")
    if not name:
        await show_bad_input(query, user_id, "menu_users")
        return
    await show_user_pin_screen(query, user_id, name)


def user_pin_result_text(user_id: Optional[int], name: str, ip: str, r: Dict[str, Any]) -> str:
    """Итог user-set-address своими словами (язык бота, не ядра) по полям ответа: закреплён ли адрес,
    изменился ли он в самом ключе (resend_required) и не домен ли в ключах (domain_endpoint)."""
    host = str(r.get("endpoint") or "").strip()
    pinned = str(r.get("endpoint_ip") or "").strip()
    if pinned:
        head = "✅ " + _tf(user_id, "user_pin_set_fmt", esc(name), esc(pinned))
    else:
        # Вернули общий — или выбрали сам общий адрес: его ядро пишет пусто («как у всех»), а не копию
        head = "✅ " + _tf(user_id, "user_pin_common_fmt", esc(name), esc(host or ip or "—"))
    if r.get("resend_required") is True:
        return "%s\n\n⚠️ %s" % (head, _t(user_id, "user_pin_resend"))
    if r.get("domain_endpoint") is True and pinned:
        return "%s\n\nℹ️ %s" % (head, _tf(user_id, "user_pin_domain_result_fmt", esc(host or "—")))
    return "%s\n\n%s" % (head, _tf(user_id, "user_pin_same_fmt", esc(host or "—")))


async def cb_user_pin_set(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """u_pin_set~<name>~<код адреса|->: user-set-address --ip=<адрес> (пусто — вернуть общий)."""
    query = update.callback_query
    user_id = _uid(update)
    parts = str(query.data).split("~")
    ip = pin_code_ip(parts[2]) if len(parts) == 3 else None
    if len(parts) != 3 or not valid_name(parts[1]) or ip is None:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    name = parts[1]
    await query.answer()
    if await _action_busy(query, user_id, "u_pin~%s" % name):
        return
    r = await mutate("user-set-address", who=user_id, name=name, ip=ip)
    if not bridge_ok(r):
        # address_not_here / addresses_unknown / invalid_ip — словами ядра (со списком адресов сервера)
        await show_error(query, user_id, r, "u_pin~%s" % name)
        return
    logger.info("user %s: own server address %s", name, ip or "reset to common")
    await safe_edit_message(query, user_pin_result_text(user_id, name, ip, r), reply_markup=back_kb(user_id, "u_view~%s" % name))


def key_caption(user_id: Optional[int], name: str, profile: str, r: Dict[str, Any], host: str = "",
                fmt: str = "") -> str:
    """Подпись к выданному ключу. У выключенного пользователя (лимит, срок, вручную) мост помечает ключ
    disabled — первой строкой предупреждение, как в SSH-меню: без него ключ пересылали человеку, у которого он
    не подключится. host — разовый адрес сервера в Endpoint («Ключ на другой адрес»): своя строка, чтобы
    ключ с другим адресом не путали с обычным."""
    line = str(r.get("line") or "")
    min_client = str(r.get("min_client") or MIN_CLIENT_BY_LINE.get(line, "") or "—")
    if fmt in ("conf", "qrconf", "qr-conf"):
        # .conf и его QR читает AmneziaWG, а не приложение AmneziaVPN: версия AmneziaVPN здесь сбивала
        # (живая проверка 25.09.2026 — «мин. версия приложения 4.8.12.7» под файлом для AmneziaWG).
        caption = _tf(user_id, "key_caption_conf_fmt", esc(name), esc(line or profile_line(profile) or "—"))
    else:
        caption = _tf(user_id, "key_caption_fmt", esc(name), esc(line or profile_line(profile) or "—"), esc(min_client))
    if host:
        caption = "%s\n%s" % (caption, _tf(user_id, "key_caption_addr_fmt", esc(host)))
    if r.get("disabled") is True:
        caption = "%s\n%s" % (_t(user_id, "key_disabled_warn"), caption)
    return caption


async def cb_user_key(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """u_key~<name>~<profile>~<fmt>: ключ в нужном стиле отдельным сообщением, карточка остаётся.

    u_ka~<name>~<profile>~<fmt>~<addr> — тот же ключ с другим адресом сервера в Endpoint (экран
    «Ключ на другой адрес»): код адреса переводится обратно по edge-status и уходит мосту
    `--endpoint`, в имени файла и в подписи — этот адрес. Без адреса всё как было.
    """
    query = update.callback_query
    user_id = _uid(update)
    parts = query.data.split("~")
    with_addr = parts[0] == "u_ka"
    if len(parts) != (5 if with_addr else 4) or not valid_name(parts[1]) or not valid_profile(parts[2]) \
            or parts[3] not in KEY_FORMATS or (with_addr and not KEY_ADDR_RE.match(parts[4])):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    name, profile, fmt = parts[1], parts[2], KEY_FORMATS[parts[3]]
    host = ""
    if with_addr:
        edge, choice = await resolve_key_addr(parts[4])
        if choice is None:
            await show_key_addr_miss(query, user_id, name, edge)
            return
        host = str(choice.get("host") or "")
    await query.answer(_t(user_id, "key_preparing"))
    r = await run_bot_action("user-key", timeout=120, who=user_id, name=name, profile=profile, format=fmt,
                             endpoint=host or None)
    if not bridge_ok(r):
        if host and str(r.get("code") or "") in KEY_ADDR_ERRORS:
            # Адрес ушёл с машины, пока экран висел: список адресов заново, слова ядра сверху
            invalidate_edge()
            await show_key_addr_screen(query, user_id, name, note="❌ " + key_addr_error_text(user_id, r))
        elif str(r.get("code") or "") == "no_private_key":
            # Кнопка нарисована до подхвата (или ядро старше признака has_key): слова ядра целиком,
            # под ними — где ключ на самом деле и два выхода, а не тупик «ошибка».
            text, markup = imported_view(user_id, name, [profile], head=fail_text(user_id, r))
            await query.message.reply_text(text, parse_mode="HTML", reply_markup=markup)
        else:
            await query.message.reply_text("❌ " + key_addr_error_text(user_id, r), parse_mode="HTML")
        return
    shown = key_host_shown(r, host)
    caption = key_caption(user_id, name, profile, r, host=shown, fmt=fmt)
    stem = key_file_stem(r, name, profile, shown)
    message = query.message
    try:
        if fmt == "conf":
            conf = str(r.get("conf") or "")
            if not conf:
                await message.reply_text("❌ " + _t(user_id, "key_failed"))
                return
            await message.reply_document(
                document=InputFile(io.BytesIO(conf.encode("utf-8")), filename="%s.conf" % stem),
                caption="%s\n%s" % (caption, _t(user_id, "key_conf_hint")), parse_mode="HTML")
        elif fmt == "vpn":
            link = str(r.get("vpn") or "")
            if not link.startswith("vpn://"):
                await message.reply_text("❌ " + _t(user_id, "key_failed"))
                return
            # Предел — на всё сообщение, а не на одну ссылку: подпись с предупреждением
            # занимает до ~350 знаков, и ссылка на 3800 знаков давала «message is too long».
            hint = _t(user_id, "key_vpn_hint")
            if len(link) + len(caption) + len(hint) + 4 <= VPN_LINK_INLINE_MAX:
                await message.reply_text("%s\n%s\n\n<code>%s</code>" % (caption, hint, esc(link)),
                                         parse_mode="HTML", disable_web_page_preview=True)
            else:
                await message.reply_document(
                    document=InputFile(io.BytesIO(link.encode("utf-8")), filename="amnezia-%s.vpn.txt" % stem),
                    caption="%s\n%s" % (caption, _t(user_id, "key_vpn_file_hint")), parse_mode="HTML")
        else:
            # QR — во временный каталог (0700) и удаляем в finally: в картинке
            # .conf лежит приватный ключ.
            tmpdir = tempfile.mkdtemp(prefix="goamnezia-bot-qr-")
            try:
                conf_png, vpn_pngs = write_qr_files(r, tmpdir)
                if fmt == "qr-conf":
                    if not conf_png:
                        await message.reply_text("❌ " + _t(user_id, "key_failed"))
                        return
                    with open(conf_png, "rb") as fh:
                        await message.reply_photo(photo=fh, caption="%s\n%s" % (caption, _t(user_id, "key_qr_conf_hint")),
                                                  parse_mode="HTML")
                else:
                    if not vpn_pngs:
                        await message.reply_text("❌ " + _t(user_id, "key_failed"))
                        return
                    total = len(vpn_pngs)
                    if total == 1:
                        with open(vpn_pngs[0], "rb") as fh:
                            await message.reply_photo(photo=fh, caption="%s\n%s" % (caption, _t(user_id, "key_qr_vpn_hint")),
                                                      parse_mode="HTML")
                    else:
                        # Приложение сканирует серию по порядку: подпись с номером на каждом кадре.
                        for start in range(0, total, ALBUM_SIZE):
                            group = []
                            for idx in range(start, min(start + ALBUM_SIZE, total)):
                                with open(vpn_pngs[idx], "rb") as fh:
                                    data = fh.read()
                                group.append(InputMediaPhoto(media=data,
                                                             caption=_tf(user_id, "key_qr_chunk_fmt", idx + 1, total)))
                            await message.reply_media_group(media=group)
                        await message.reply_text("%s\n%s" % (caption, _tf(user_id, "key_qr_vpn_series_hint", total)),
                                                 parse_mode="HTML")
            finally:
                shutil.rmtree(tmpdir, ignore_errors=True)
    except TelegramError as e:
        logger.warning("key delivery failed: %s", e)
        await message.reply_text("❌ " + _t(user_id, "key_send_failed"))


# ── Добавление пользователя: имя → профили → лимит → срок ────────────────────
# Отдельного вопроса «отображаемое имя» нет: идентификатор и есть имя (решение
# владельца, то же в SSH-мастере, install.sh _user_add_interactive). Подпись
# правится кнопкой «✏️ Переименовать» в карточке; взятое «🎲 Случайное имя»
# приносит её с собой («Туманный Лондон» при id foggy_london).
# На каждом шаге — «⬅️ Назад»: состояние мастера лежит во flow, и ошибка на
# третьем шаге не должна отправлять человека начинать сначала.

# Шаг мастера → предыдущий шаг. profiles → name, а если экран с галочками
# пропущен (установлен один профиль), quota возвращает сразу к имени.
USER_ADD_PREV_STEP = {"profiles": "name", "quota": "profiles", "days": "quota"}


def _user_add_nav_row(user_id: Optional[int], first: bool) -> list:
    """Низ экрана мастера: «Назад» всегда, «Отмена» — кроме первого шага.

    На первом шаге «Назад» и «Отмена» вели бы в одно место (список
    пользователей), а две кнопки с одним действием — та самая церемония.
    """
    row = [btn(_t(user_id, "btn_back"), "menu_users" if first else "ua_back")]
    if not first:
        row.append(btn(_t(user_id, "btn_cancel"), "menu_users"))
    return row


# «🎲 Случайное имя» (решение владельца 27.09, docs/MODES_047.md «Имена ключей»): вариант
# «прилагательное + столица» придумывает ядро — действие name-suggest (подпись на языке
# интерфейса, id латиницей, не совпадает с уже заведёнными). Ядро старше кнопки отвечает
# unknown_action — тогда кнопку прячем до перезапуска бота (новое ядро приходит вместе с ним).
_NAME_SUGGEST: Dict[str, Any] = {"unsupported": False}
# Ответ на нажатие уходит сразу, до моста (Telegram ждёт его не дольше 15 секунд), а ждать ядро
# дольше десяти секунд человек у экрана не станет — дальше вариант приходит сбоем в сообщении.
NAME_SUGGEST_TIMEOUT = 10
# «✓ Взять» несёт id варианта в callback_data и берёт ровно то, что человек видел на экране: два
# быстрых «🎲 Ещё» могли вернуться в другом порядке, и «последний сохранённый» разошёлся бы с
# показанным. Подписи показанных вариантов мастер помнит — не больше стольких.
NAME_SUGGEST_KEEP = 10


def name_suggestion(r: Dict[str, Any]) -> Optional[Dict[str, str]]:
    """{"id", "label"} из ответа name-suggest; нет годного id — None, негодная подпись — пустая.

    Поля ищем в data (форма {"ok": true, "data": {…}}), в suggestion и в корне ответа
    (обычная форма моста); id бывает и под именем name.
    """
    if not bridge_ok(r):
        return None
    for src in (r.get("data"), r.get("suggestion"), r):
        if not isinstance(src, dict):
            continue
        ident = next((v.strip() for v in (src.get("id"), src.get("name")) if isinstance(v, str) and v.strip()), "")
        if valid_name(ident):
            label = str(src.get("label") or "").strip()
            return {"id": ident, "label": label if valid_label(label) else ""}
    return None


async def _name_suggest(user_id: Optional[int], exclude: str) -> Tuple[Dict[str, Any], Optional[Dict[str, str]]]:
    """Вариант имени от ядра: (ответ моста, {"id", "label"} или None).

    exclude — id варианта на экране: «🎲 Ещё» обязано дать другой. Ядро с name-suggest, но без
    --exclude (договор до 27.09), отвечает на него bad_arg — тогда тот же вызов без параметра.
    Выпал тот же вариант — ещё одна попытка.
    """
    lang = get_user_lang(user_id)
    skip = exclude or None
    r = await run_bot_action("name-suggest", timeout=NAME_SUGGEST_TIMEOUT, who=user_id, lang=lang, exclude=skip)
    if skip and str(r.get("code") or "") == "bad_arg":
        skip = None
        r = await run_bot_action("name-suggest", timeout=NAME_SUGGEST_TIMEOUT, who=user_id, lang=lang, exclude=skip)
    suggestion = name_suggestion(r)
    if suggestion is not None and exclude and suggestion["id"] == exclude:
        again = await run_bot_action("name-suggest", timeout=NAME_SUGGEST_TIMEOUT, who=user_id, lang=lang,
                                     exclude=skip)
        if name_suggestion(again) is not None:
            r, suggestion = again, name_suggestion(again)
    return r, suggestion


async def _user_add_name_screen(message_or_query, user_id: Optional[int], edit: bool,
                                suggestion: Optional[Dict[str, str]] = None, notice: str = "") -> None:
    """Шаг «имя»: вопрос и «🎲 Случайное имя» под ним; с предложением — оно, «✓ Взять» и «🎲 Ещё».

    Своё имя текстом принимается на этом шаге всегда, и с предложением на экране тоже. notice —
    строка над вопросом (сбой «🎲»: ответ на нажатие уже ушёл, алерт не показать).
    """
    rows = []
    if suggestion:
        ident = str(suggestion.get("id") or "")
        body = _tf(user_id, "user_name_suggested_fmt", esc(suggestion.get("label") or ident), esc(ident))
        rows.append([btn(_t(user_id, "user_name_take"), "ua_take~%s" % ident),
                     btn(_t(user_id, "user_name_again"), "ua_rnd")])
    else:
        body = _t(user_id, "user_ask_name")
        if not _NAME_SUGGEST["unsupported"]:
            rows.append([btn(_t(user_id, "user_name_random"), "ua_rnd")])
    if notice:
        body = "%s\n\n%s" % (notice, body)
    rows.append(_user_add_nav_row(user_id, first=True))
    text = "<b>%s</b>\n\n%s" % (_t(user_id, "user_add_title"), body)
    markup = InlineKeyboardMarkup(rows)
    if edit:
        await safe_edit_message(message_or_query, text, reply_markup=markup)
    else:
        await message_or_query.reply_text(text, reply_markup=markup, parse_mode="HTML")


async def cb_user_add(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    flow_set(context, "user_add", step="name")
    await _user_add_name_screen(query, user_id, edit=True)


async def cb_user_add_suggest(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """ua_rnd: «🎲 Случайное имя» и «🎲 Ещё» — вариант от ядра в том же сообщении."""
    query = update.callback_query
    user_id = _uid(update)
    flow = flow_get(context)
    if not flow or flow.get("kind") != "user_add":
        # Мастера нет (истёк, бот перезапущен) — алерт и экран с возвратом, как у ua_back
        await query.answer(_t(user_id, "flow_expired"), show_alert=True)
        await safe_edit_message(query, "❌ " + _t(user_id, "user_add_lost"), reply_markup=back_kb(user_id, "menu_users"))
        return
    if flow["data"].get("step") != "name":
        # Кнопка с экрана имени, а мастер уже дальше: выбранное имя и шаг не трогаем, мост не зовём
        await query.answer(_t(user_id, "user_name_already_chosen"), show_alert=True)
        return
    # Ответ на нажатие — сразу, до моста; сбой показывает само сообщение
    await query.answer()
    shown_now = flow["data"].get("suggest") or {}
    r, suggestion = await _name_suggest(user_id, str(shown_now.get("id") or ""))
    notice = ""
    if suggestion is None:
        code = str(r.get("code") or "") if isinstance(r, dict) else ""
        if code == "unknown_action":
            # Ядро старше кнопки: прячем её, имя человек отправит сам
            _NAME_SUGGEST["unsupported"] = True
            flow["data"].pop("suggest", None)
            notice = "⚠️ " + _t(user_id, "user_name_random_unavailable")
        else:
            # Прежний вариант (если был) остаётся на экране — сбой «🎲 Ещё» его не стирает
            notice = "❌ " + _tf(user_id, "user_name_random_failed_fmt", esc(code or "error"))
    elif flow["data"].get("step") == "name":
        flow["data"]["suggest"] = suggestion
        shown = flow["data"].setdefault("suggested", {})
        shown.pop(suggestion["id"], None)
        shown[suggestion["id"]] = suggestion["label"]
        while len(shown) > NAME_SUGGEST_KEEP:
            shown.pop(next(iter(shown)))
    # Пока ядро думало, человек мог отправить имя сам: мастер ушёл дальше — экран имени не рисуем
    if flow_get(context) is flow and flow["data"].get("step") == "name":
        await _user_add_name_screen(query, user_id, edit=True, suggestion=flow["data"].get("suggest"), notice=notice)


async def cb_user_add_take(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """ua_take~<id>: «✓ Взять» — показанный вариант: id — идентификатор, подпись — отображаемое имя."""
    query = update.callback_query
    user_id = _uid(update)
    flow = flow_get(context)
    if not flow or flow.get("kind") != "user_add":
        await query.answer(_t(user_id, "flow_expired"), show_alert=True)
        await safe_edit_message(query, "❌ " + _t(user_id, "user_add_lost"), reply_markup=back_kb(user_id, "menu_users"))
        return
    if flow["data"].get("step") != "name":
        # Имя уже выбрано (взяли вариант, отправили своё, двойной тап): не переписываем
        await query.answer(_t(user_id, "user_name_already_chosen"), show_alert=True)
        return
    name = query.data.split("~", 1)[1] if "~" in query.data else ""
    shown = flow["data"].get("suggested") or {}
    if not valid_name(name) or name not in shown:
        # Старая кнопка: этого варианта мастер не предлагал (начали заново, ввели своё имя)
        await query.answer(_t(user_id, "user_name_random_gone"), show_alert=True)
        await _user_add_name_screen(query, user_id, edit=True, suggestion=flow["data"].get("suggest"))
        return
    await query.answer()
    label = str(shown.get(name) or "")
    for key in ("suggest", "suggested"):
        flow["data"].pop(key, None)
    flow["data"]["name"] = name
    if valid_label(label):
        flow["data"]["label"] = label
    else:
        flow["data"].pop("label", None)
    await _user_add_profiles_screen(query, user_id, flow, edit=True)


async def _user_add_profiles_screen(message_or_query, user_id: Optional[int], flow: Dict[str, Any], edit: bool) -> None:
    """Экран с галочками. При ЕДИНСТВЕННОМ установленном профиле его нет вовсе:
    выбирать не из чего, а галочка — лишний экран. Об автовыборе мастер
    говорит в итоговом сообщении, чтобы человек знал, куда попал ключ."""
    status = await get_status()
    installed = installed_profiles(status)
    if len(installed) == 1:
        flow["data"]["profiles"] = list(installed)
        flow["data"]["single_profile"] = installed[0]
        await _user_add_quota_screen(message_or_query, user_id, flow, edit=edit)
        return
    flow["data"].pop("single_profile", None)
    chosen = flow["data"].setdefault("profiles", list(installed))
    flow["data"]["step"] = "profiles"
    rows = []
    for p in installed:
        mark = "☑" if p in chosen else "☐"
        rows.append([btn("%s %s" % (mark, profile_title(user_id, p)), "ua_tog~%s" % p)])
    rows.append([btn(_t(user_id, "btn_done"), "ua_done")])
    rows.append(_user_add_nav_row(user_id, first=False))
    text = "<b>%s</b>\n\n%s" % (_t(user_id, "user_add_title"), _t(user_id, "user_ask_profiles"))
    if not installed:
        text += "\n\n⚠️ " + _t(user_id, "users_no_profiles")
    if edit:
        await safe_edit_message(message_or_query, text, reply_markup=InlineKeyboardMarkup(rows))
    else:
        await message_or_query.reply_text(text, reply_markup=InlineKeyboardMarkup(rows), parse_mode="HTML")


async def _user_add_quota_screen(message_or_query, user_id: Optional[int], flow: Dict[str, Any], edit: bool) -> None:
    flow["data"]["step"] = "quota"
    text = "<b>%s</b>\n\n%s" % (_t(user_id, "user_add_title"), _t(user_id, "user_ask_quota"))
    markup = _quota_keyboard(user_id, "ua_q~", "menu_users", back_to="ua_back")
    if edit:
        await safe_edit_message(message_or_query, text, reply_markup=markup)
    else:
        await message_or_query.reply_text(text, reply_markup=markup, parse_mode="HTML")


async def _user_add_days_screen(message_or_query, user_id: Optional[int], flow: Dict[str, Any], edit: bool) -> None:
    flow["data"]["step"] = "days"
    text = "<b>%s</b>\n\n%s" % (_t(user_id, "user_add_title"), _t(user_id, "user_ask_days"))
    markup = _expiry_keyboard(user_id, "ua_d~", "menu_users", back_to="ua_back")
    if edit:
        await safe_edit_message(message_or_query, text, reply_markup=markup)
    else:
        await message_or_query.reply_text(text, reply_markup=markup, parse_mode="HTML")


async def cb_user_add_back(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """ua_back: шаг назад по мастеру, накопленные ответы остаются во flow."""
    query = update.callback_query
    user_id = _uid(update)
    flow = flow_get(context)
    if not flow or flow.get("kind") != "user_add":
        await query.answer(_t(user_id, "flow_expired"), show_alert=True)
        await safe_edit_message(query, "❌ " + _t(user_id, "user_add_lost"),
                                reply_markup=back_kb(user_id, "menu_users"))
        return
    await query.answer()
    step = USER_ADD_PREV_STEP.get(str(flow["data"].get("step") or ""), "name")
    # Экран с галочками пропущен — «назад» с лимита ведёт сразу к имени.
    if step == "profiles" and flow["data"].get("single_profile"):
        step = "name"
    if step == "name":
        flow["data"]["step"] = "name"
        await _user_add_name_screen(query, user_id, edit=True)
    elif step == "profiles":
        await _user_add_profiles_screen(query, user_id, flow, edit=True)
    else:
        await _user_add_quota_screen(query, user_id, flow, edit=True)


def _quota_keyboard(user_id: Optional[int], prefix: str, cancel_to: str,
                    back_to: Optional[str] = None) -> "InlineKeyboardMarkup":
    """Лимит: гигабайты рядом, ниже — «Без лимита» своей кнопкой (NC-08). В её callback_data 0 — договор с
    ядром (quota_gb=0) и старыми кнопками в чате; человеку этот ноль не виден."""
    rows = [[btn("%d %s" % (gb, _t(user_id, "unit_gb")), "%s%d" % (prefix, gb)) for gb in QUOTA_PRESETS_GB],
            [btn(_t(user_id, "user_quota_unlimited_btn"), "%s0" % prefix)]]
    last = [btn(_t(user_id, "btn_cancel"), cancel_to)]
    if back_to:
        last.insert(0, btn(_t(user_id, "btn_back"), back_to))
    rows.append(last)
    return InlineKeyboardMarkup(rows)


def _expiry_keyboard(user_id: Optional[int], prefix: str, cancel_to: str,
                     back_to: Optional[str] = None) -> "InlineKeyboardMarkup":
    """Срок: дни рядом, ниже — «Бессрочно» своей кнопкой (NC-08); в callback_data у неё 0, как у ядра."""
    rows = [[btn(_tf(user_id, "days_fmt", d), "%s%d" % (prefix, d)) for d in EXPIRY_PRESETS_DAYS],
            [btn(_t(user_id, "user_expiry_never_btn"), "%s0" % prefix)]]
    last = [btn(_t(user_id, "btn_cancel"), cancel_to)]
    if back_to:
        last.insert(0, btn(_t(user_id, "btn_back"), back_to))
    rows.append(last)
    return InlineKeyboardMarkup(rows)


async def cb_user_add_toggle(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    flow = flow_get(context)
    if not flow or flow.get("kind") != "user_add":
        await query.answer(_t(user_id, "flow_expired"), show_alert=True)
        return
    profile = query.data.split("~", 1)[1] if "~" in query.data else ""
    chosen = flow["data"].setdefault("profiles", [])
    if valid_profile(profile):
        if profile in chosen:
            chosen.remove(profile)
        else:
            chosen.append(profile)
    await query.answer()
    await _user_add_profiles_screen(query, user_id, flow, edit=True)


async def cb_user_add_done(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    flow = flow_get(context)
    if not flow or flow.get("kind") != "user_add":
        await query.answer(_t(user_id, "flow_expired"), show_alert=True)
        return
    if not flow["data"].get("profiles"):
        await query.answer(_t(user_id, "user_pick_one_profile"), show_alert=True)
        return
    await query.answer()
    await _user_add_quota_screen(query, user_id, flow, edit=True)


async def cb_user_add_quota(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    flow = flow_get(context)
    if not flow or flow.get("kind") != "user_add":
        await query.answer(_t(user_id, "flow_expired"), show_alert=True)
        return
    value = query.data.split("~", 1)[1] if "~" in query.data else ""
    if not valid_int(value, MAX_QUOTA_GB):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    flow["data"]["quota_gb"] = int(value)
    await _user_add_days_screen(query, user_id, flow, edit=True)


async def cb_user_add_days(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    flow = flow_get(context)
    if not flow or flow.get("kind") != "user_add":
        await query.answer(_t(user_id, "flow_expired"), show_alert=True)
        return
    value = query.data.split("~", 1)[1] if "~" in query.data else ""
    if not valid_int(value, MAX_DAYS):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    flow["data"]["days"] = int(value)
    await _user_add_finish(query, context, user_id, flow, edit=True)


async def _user_add_finish(target, context, user_id: Optional[int], flow: Dict[str, Any], edit: bool) -> None:
    data = flow["data"]
    flow_clear(context)
    name = str(data.get("name") or "")
    single = str(data.get("single_profile") or "")
    profiles = [p for p in (data.get("profiles") or []) if valid_profile(p)]
    stop = ""
    if not valid_name(name):
        # Имя потерялось (перезапуск бота, чужой callback): молчать нельзя —
        # человек остался бы перед экраном без ответа и без объяснения.
        stop = "user_add_lost"
    elif not profiles:
        # Страж на кнопке «Готово» сюда не достаёт: экраны мастер шлёт новым
        # сообщением, старые клавиатуры не гаснут, и живая кнопка прошлого
        # прогона приходит прямо в этот шаг. Поэтому отказ стоит ПЕРЕД мостом:
        # без него пустой выбор ушёл бы как «параметра нет вовсе», а это у ядра
        # значит «во все установленные линейки» — человек снял все галочки и
        # молча получил ключи везде.
        stop = "user_pick_one_profile"
    if stop:
        text = "❌ " + _t(user_id, stop)
        markup = back_kb(user_id, "menu_users")
        if edit:
            await safe_edit_message(target, text, reply_markup=markup)
        else:
            await target.reply_text(text, parse_mode="HTML", reply_markup=markup)
        return
    text = "⏳ " + _tf(user_id, "user_creating_fmt", esc(name))
    if edit:
        await safe_edit_message(target, text, reply_markup=None)
        message = target.message
    else:
        await target.reply_text(text, parse_mode="HTML")
        message = target
    # Последний шаг мастера (кнопка срока или число текстом) встаёт в очередь за замком, а не
    # отказывает: мастер пришлось бы проходить заново (queued, как у ввода текстом).
    await _queued_notice(message, user_id)
    r = await mutate("user-add", who=user_id, name=name, label=data.get("label") or None,
                     # Пустая строка, а не None: параметра нет вовсе — это
                     # «во все линейки», а пустую строку ядро отвергает само.
                     profiles=",".join(profiles),
                     quota_gb=data.get("quota_gb", 0), days=data.get("days", 0))
    if not bridge_ok(r):
        await message.reply_text(fail_text(user_id, r), parse_mode="HTML",
                                 reply_markup=back_kb(user_id, "menu_users"))
        return
    done = "✅ " + _tf(user_id, "user_added_fmt", esc(name))
    if single in PROFILE_IDS:
        # Экран с галочками пропустили — говорим, в какой профиль попал ключ.
        done += "\n" + _tf(user_id, "user_add_single_profile_fmt", esc(profile_title(user_id, single)))
    done += "\n" + _t(user_id, "user_added_hint")
    await message.reply_text(done, parse_mode="HTML", reply_markup=InlineKeyboardMarkup([
        [btn(_t(user_id, "users_open_card"), "u_view~%s" % name)],
        _back_row(user_id, "menu_users")]))


async def _user_add_text(update: Update, context: ContextTypes.DEFAULT_TYPE, flow: Dict[str, Any], text: str) -> None:
    """Текстовые шаги мастера: имя, а на шагах лимита и срока — своё число.
    Ошибка ввода ожидание НЕ снимает."""
    user_id = _uid(update)
    step = flow["data"].get("step")
    if step == "name":
        if not valid_name(text):
            await update.message.reply_text(_t(user_id, "user_bad_name"))
            return
        flow["data"]["name"] = text
        # Своё имя вместо предложенного: подпись «🎲» к нему не относится — ядро поставит label = name
        for key in ("label", "suggest", "suggested"):
            flow["data"].pop(key, None)
        await _user_add_profiles_screen(update.message, user_id, flow, edit=False)
        return
    # Шаги quota/days идут кнопками; текст на них — своё число (или слова кнопки «Без лимита» / «Бессрочно»).
    if step == "quota":
        gb = parse_quota_gb(text)
        if gb is None:
            await update.message.reply_text(_tf(user_id, "user_bad_quota_fmt", MAX_QUOTA_GB))
            return
        flow["data"]["quota_gb"] = gb
        await _user_add_days_screen(update.message, user_id, flow, edit=False)
        return
    if step == "days":
        days = parse_expiry_days(text)
        if days is None:
            await update.message.reply_text(_tf(user_id, "user_bad_days_fmt", MAX_DAYS))
            return
        flow["data"]["days"] = days
        await _user_add_finish(update.message, context, user_id, flow, edit=False)


# ── Добавить сразу несколько: сколько → имена → профили → итог ───────────────
# Просьба владельца 03.10: до 100 человек одним действием ядра (users-add-bulk) — тот же путь, что одиночное
# добавление, с одним применением к контейнерам. Имена — на выбор, как в SSH и панели (живая проверка на test1 03.10,
# BOT-7): «🎲 случайные» — «прилагательное + столица», подпись на языке этого человека в боте (как у «🎲»), или
# «✏️ с префиксом» — префикс текстом, ядро заводит office-01, office-02… с номера после уже заведённых (по нему же
# их потом удаляет «Удалить сразу несколько»). Лимита и срока нет, их ставят в карточке. Итог — одним сообщением,
# без ключей: ключи выдаются в карточке каждого. Частичный сбой ядро отдаёт success с partial — добавленные остаются.
BULK_PRESETS = (5, 10, 20, 50, 100)
BULK_MAX = 100
# Итог — одно сообщение (Telegram режет на 4096 знаках): список людей обрезается раньше, хвост — «и ещё N».
BULK_LIST_CHARS = 3000
# Префикс имён — образец каталога ядра (name_prefix); хвостовые - и _ ядро отбрасывает («office-» → office-01)
BULK_PREFIX_RE = re.compile(r"^[A-Za-z0-9_-]{1,28}$")


def parse_bulk_count(text: str) -> Optional[int]:
    """Число людей из текста: целое 1–100 (пробелы по краям — можно), иначе None."""
    value = str(text or "").strip()
    if not re.fullmatch(r"[0-9]{1,3}", value):
        return None
    n = int(value)
    return n if 1 <= n <= BULK_MAX else None


def parse_bulk_prefix(text: str) -> Optional[str]:
    """Префикс имён из текста по правилам ядра (users-add-bulk / users-del-bulk --prefix): пробелы по краям и
    хвостовые - и _ отбрасываются, остаток — латиница, цифры, _ и -, 1–28 знаков; иначе None."""
    prefix = str(text or "").strip().rstrip("-_")
    return prefix if BULK_PREFIX_RE.match(prefix) else None


def _user_bulk_lost(user_id: Optional[int]) -> Tuple[str, "InlineKeyboardMarkup"]:
    return "❌ " + _t(user_id, "user_bulk_lost"), back_kb(user_id, "menu_users")


async def _user_bulk_count_screen(message_or_query, user_id: Optional[int], edit: bool) -> None:
    """Шаг «сколько»: готовые числа кнопками, своё — текстом (1–100)."""
    rows = [[btn(str(n), "ub_n~%d" % n) for n in BULK_PRESETS], [btn(_t(user_id, "btn_back"), "menu_users")]]
    text = "<b>%s</b>\n\n%s" % (_t(user_id, "user_bulk_title"), _t(user_id, "user_bulk_ask_count"))
    if edit:
        await safe_edit_message(message_or_query, text, reply_markup=InlineKeyboardMarkup(rows))
    else:
        await message_or_query.reply_text(text, reply_markup=InlineKeyboardMarkup(rows), parse_mode="HTML")


async def cb_user_bulk(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """u_addm: «Добавить сразу несколько» — мастер с шага «сколько»."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    flow_set(context, "user_bulk", step="count")
    await _user_bulk_count_screen(query, user_id, edit=True)


async def _user_bulk_set_count(message_or_query, context, user_id: Optional[int], flow: Dict[str, Any],
                               count: int, edit: bool) -> None:
    flow["data"]["count"] = count
    await _user_bulk_names_screen(message_or_query, user_id, flow, edit=edit)


async def _user_bulk_names_screen(message_or_query, user_id: Optional[int], flow: Dict[str, Any], edit: bool) -> None:
    """Шаг «имена»: 🎲 случайные или ✏️ с префиксом (префикс — следующим сообщением)."""
    flow["data"]["step"] = "names"
    rows = [[btn(_t(user_id, "user_bulk_names_random_btn"), "ub_nm~random")],
            [btn(_t(user_id, "user_bulk_names_prefix_btn"), "ub_nm~prefix")],
            [btn(_t(user_id, "btn_back"), "ub_back"), btn(_t(user_id, "btn_cancel"), "menu_users")]]
    text = "<b>%s</b>\n\n%s" % (_t(user_id, "user_bulk_title"),
                                _tf(user_id, "user_bulk_ask_names_fmt", int(flow["data"].get("count") or 0)))
    if edit:
        await safe_edit_message(message_or_query, text, reply_markup=InlineKeyboardMarkup(rows))
    else:
        await message_or_query.reply_text(text, reply_markup=InlineKeyboardMarkup(rows), parse_mode="HTML")


async def _user_bulk_prefix_screen(query, user_id: Optional[int], flow: Dict[str, Any]) -> None:
    """Ожидание префикса текстом; «Назад» — к выбору имён."""
    flow["data"]["step"] = "prefix"
    rows = [[btn(_t(user_id, "btn_back"), "ub_names"), btn(_t(user_id, "btn_cancel"), "menu_users")]]
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "user_bulk_title"), _t(user_id, "user_bulk_ask_prefix")),
                            reply_markup=InlineKeyboardMarkup(rows))


def _user_bulk_flow(context) -> Optional[Dict[str, Any]]:
    """Мастер «сразу несколько» с уже выбранным числом — иначе None (бот перезапущен, мастер истёк)."""
    flow = flow_get(context)
    if not flow or flow.get("kind") != "user_bulk" or parse_bulk_count(str(flow["data"].get("count") or "")) is None:
        return None
    return flow


async def cb_user_bulk_names(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """ub_names: назад к выбору имён — с галочек профилей и с ожидания префикса; число и галочки остаются."""
    query = update.callback_query
    user_id = _uid(update)
    flow = _user_bulk_flow(context)
    if flow is None:
        await query.answer(_t(user_id, "flow_expired"), show_alert=True)
        text, markup = _user_bulk_lost(user_id)
        await safe_edit_message(query, text, reply_markup=markup)
        return
    await query.answer()
    await _user_bulk_names_screen(query, user_id, flow, edit=True)


async def cb_user_bulk_names_pick(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """ub_nm~<random|prefix>: случайные — сразу к профилям; префикс — ждём его текстом."""
    query = update.callback_query
    user_id = _uid(update)
    flow = _user_bulk_flow(context)
    if flow is None:
        await query.answer(_t(user_id, "flow_expired"), show_alert=True)
        text, markup = _user_bulk_lost(user_id)
        await safe_edit_message(query, text, reply_markup=markup)
        return
    how = query.data.split("~", 1)[1] if "~" in query.data else ""
    if how not in ("random", "prefix"):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    if how == "prefix":
        await _user_bulk_prefix_screen(query, user_id, flow)
    else:
        flow["data"].pop("prefix", None)
        await _user_bulk_profiles_screen(query, context, user_id, flow, edit=True)


async def cb_user_bulk_count(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """ub_n~<число>: готовое число людей."""
    query = update.callback_query
    user_id = _uid(update)
    flow = flow_get(context)
    if not flow or flow.get("kind") != "user_bulk":
        await query.answer(_t(user_id, "flow_expired"), show_alert=True)
        text, markup = _user_bulk_lost(user_id)
        await safe_edit_message(query, text, reply_markup=markup)
        return
    count = parse_bulk_count(query.data.split("~", 1)[1] if "~" in query.data else "")
    if count is None:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    await _user_bulk_set_count(query, context, user_id, flow, count, edit=True)


async def _user_bulk_profiles_screen(message_or_query, context, user_id: Optional[int], flow: Dict[str, Any],
                                     edit: bool) -> None:
    """Галочки профилей — как у одиночного добавления; один установленный профиль — экрана нет, сразу итог."""
    status = await get_status()
    installed = installed_profiles(status)
    if len(installed) == 1:
        flow["data"]["profiles"] = list(installed)
        await _user_bulk_finish(message_or_query, context, user_id, flow, edit=edit)
        return
    chosen = flow["data"].setdefault("profiles", list(installed))
    flow["data"]["step"] = "profiles"
    rows = []
    for p in installed:
        mark = "☑" if p in chosen else "☐"
        rows.append([btn("%s %s" % (mark, profile_title(user_id, p)), "ub_tog~%s" % p)])
    rows.append([btn(_tf(user_id, "user_bulk_go_fmt", int(flow["data"].get("count") or 0)), "ub_done")])
    rows.append([btn(_t(user_id, "btn_back"), "ub_names"), btn(_t(user_id, "btn_cancel"), "menu_users")])
    text = "<b>%s</b>\n\n%s\n%s" % (_t(user_id, "user_bulk_title"),
                                    _tf(user_id, "user_bulk_ask_profiles_fmt", int(flow["data"].get("count") or 0)),
                                    bulk_names_choice(user_id, flow["data"].get("prefix") or ""))
    if not installed:
        text += "\n\n⚠️ " + _t(user_id, "users_no_profiles")
    if edit:
        await safe_edit_message(message_or_query, text, reply_markup=InlineKeyboardMarkup(rows))
    else:
        await message_or_query.reply_text(text, reply_markup=InlineKeyboardMarkup(rows), parse_mode="HTML")


async def cb_user_bulk_toggle(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    flow = flow_get(context)
    if not flow or flow.get("kind") != "user_bulk":
        await query.answer(_t(user_id, "flow_expired"), show_alert=True)
        return
    profile = query.data.split("~", 1)[1] if "~" in query.data else ""
    chosen = flow["data"].setdefault("profiles", [])
    if valid_profile(profile):
        if profile in chosen:
            chosen.remove(profile)
        else:
            chosen.append(profile)
    await query.answer()
    await _user_bulk_profiles_screen(query, context, user_id, flow, edit=True)


async def cb_user_bulk_back(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """ub_back: с выбора имён — к числу; число, имена и галочки остаются во flow."""
    query = update.callback_query
    user_id = _uid(update)
    flow = flow_get(context)
    if not flow or flow.get("kind") != "user_bulk":
        await query.answer(_t(user_id, "flow_expired"), show_alert=True)
        text, markup = _user_bulk_lost(user_id)
        await safe_edit_message(query, text, reply_markup=markup)
        return
    await query.answer()
    flow["data"]["step"] = "count"
    await _user_bulk_count_screen(query, user_id, edit=True)


async def cb_user_bulk_done(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """ub_done: «Добавить N» — галочки выбраны, зовём ядро."""
    query = update.callback_query
    user_id = _uid(update)
    flow = flow_get(context)
    if not flow or flow.get("kind") != "user_bulk":
        await query.answer(_t(user_id, "flow_expired"), show_alert=True)
        return
    if not flow["data"].get("profiles"):
        await query.answer(_t(user_id, "user_pick_one_profile"), show_alert=True)
        return
    await query.answer()
    await _user_bulk_finish(query, context, user_id, flow, edit=True)


def bulk_names_choice(user_id: Optional[int], prefix: str) -> str:
    """Выбранные имена строкой — на экране галочек: «Имена: случайные…» или «Имена: office-01, office-02…»."""
    if prefix:
        return _tf(user_id, "user_bulk_names_prefix_fmt", esc(prefix), esc(prefix))
    return _t(user_id, "user_bulk_names_random")


def bulk_done_text(user_id: Optional[int], r: Dict[str, Any], profiles: List[str]) -> str:
    """Итог users-add-bulk одним сообщением: сколько и кто (подпись — имя), на ком остановилось, где ключи."""
    added = [a for a in (r.get("added") or []) if isinstance(a, dict) and valid_name(str(a.get("name") or ""))]
    lines = ["✅ " + _tf(user_id, "user_bulk_done_fmt", len(added), esc(profile_names(user_id, profiles)))]
    used = 0
    shown = 0
    for a in added:
        name = str(a.get("name"))
        label = str(a.get("label") or "")
        row = ("• %s — <code>%s</code>" % (esc(label), esc(name))) if label and label != name else "• <code>%s</code>" % esc(name)
        if used + len(row) > BULK_LIST_CHARS:
            break
        lines.append(row)
        used += len(row) + 1
        shown += 1
    if shown < len(added):
        lines.append(_tf(user_id, "user_bulk_more_fmt", len(added) - shown))
    failed = r.get("failed") if isinstance(r.get("failed"), dict) else None
    if r.get("partial") and failed:
        lines.append("")
        lines.append("⚠️ " + _tf(user_id, "user_bulk_partial_fmt", int(r.get("requested") or 0) - len(added),
                                  esc(failed.get("name") or "?"),
                                  esc(str(failed.get("message") or failed.get("code") or "").rstrip(". "))))
    lines.append("")
    lines.append(_t(user_id, "user_bulk_where_keys"))
    return "\n".join(lines)


async def _user_bulk_finish(target, context, user_id: Optional[int], flow: Dict[str, Any], edit: bool) -> None:
    data = flow["data"]
    flow_clear(context)
    count = int(data.get("count") or 0)
    profiles = [p for p in (data.get("profiles") or []) if valid_profile(p)]
    prefix = str(data.get("prefix") or "")
    stop = ""
    if not 1 <= count <= BULK_MAX or (prefix and parse_bulk_prefix(prefix) != prefix):
        stop = "user_bulk_lost"
    elif not profiles:
        # Как у одиночного: пустой выбор не уходит мосту «без параметра» — это значило бы «во все линейки»
        stop = "user_pick_one_profile"
    if stop:
        text = "❌ " + _t(user_id, stop)
        markup = back_kb(user_id, "menu_users")
        if edit:
            await safe_edit_message(target, text, reply_markup=markup)
        else:
            await target.reply_text(text, parse_mode="HTML", reply_markup=markup)
        return
    text = "⏳ " + _tf(user_id, "user_bulk_creating_fmt", count)
    if edit:
        await safe_edit_message(target, text, reply_markup=None)
        message = target.message
    else:
        await target.reply_text(text, parse_mode="HTML")
        message = target
    await _queued_notice(message, user_id)
    ordered = [p for p in PROFILE_IDS if p in profiles]
    r = await mutate("users-add-bulk", who=user_id, count=count, profiles=",".join(ordered), prefix=prefix or None,
                     lang=get_user_lang(user_id))
    if not bridge_ok(r):
        await message.reply_text(fail_text(user_id, r), parse_mode="HTML", reply_markup=back_kb(user_id, "menu_users"))
        return
    await message.reply_text(bulk_done_text(user_id, r, ordered), parse_mode="HTML",
                             reply_markup=InlineKeyboardMarkup([[btn(_t(user_id, "menu_users"), "menu_users")]]))


async def _user_bulk_text(update: Update, context: ContextTypes.DEFAULT_TYPE, flow: Dict[str, Any], text: str) -> None:
    """Своё число людей текстом на шаге «сколько», префикс имён — на шаге «префикс»; ошибка ввода ожидание не снимает."""
    user_id = _uid(update)
    step = flow["data"].get("step")
    if step == "prefix":
        prefix = parse_bulk_prefix(text)
        if prefix is None:
            await update.message.reply_text(_t(user_id, "user_bulk_bad_prefix"))
            return
        flow["data"]["prefix"] = prefix
        await _user_bulk_profiles_screen(update.message, context, user_id, flow, edit=False)
        return
    if step != "count":
        await update.message.reply_text(_t(user_id, "user_bulk_names_use_buttons" if step == "names" else "user_bulk_use_buttons"))
        return
    count = parse_bulk_count(text)
    if count is None:
        await update.message.reply_text(_tf(user_id, "user_bulk_bad_count_fmt", BULK_MAX))
        return
    await _user_bulk_set_count(update.message, context, user_id, flow, count, edit=False)


# ── Удалить сразу несколько: способ → кого именно → DELETE <число> → итог ────
# Просьба владельца 03.10, пара к «Добавить сразу несколько»: до 100 человек одним действием ядра (users-del-bulk) —
# порядок одиночного удаления, в контейнер — пачками. Способ: префикс текстом (office-01, office-02…, как их заводит
# добавление), выключенные руками, истёкшие, с исчерпанным лимитом; номерами строк и галочками удаляют SSH и панель.
# Кого задевает выбор, считает ядро (users-del-bulk-preview) — список здесь тот же, что удалит ядро. Подтверждение —
# фразой DELETE <число людей> за 60 с, как у одиночного удаления; ядро сверяет число с выбранным в момент удаления:
# список успел измениться — отказ до изменений и кнопка «Показать заново». Итог — одним сообщением, без ключей.
BULK_DEL_STATES = ("disabled", "expired", "quota")


def bulk_del_what(user_id: Optional[int], mode: str, value: str) -> str:
    """Выбор словами — в «никого не нашлось» и в заголовке списка."""
    if mode == "prefix":
        return _tf(user_id, "user_bulk_del_what_prefix_fmt", value)
    return _t(user_id, {"disabled": "user_bulk_del_what_disabled", "expired": "user_bulk_del_what_expired",
                        "quota": "user_bulk_del_what_quota"}.get(value, "user_bulk_del_what_disabled"))


def bulk_del_selection_ok(mode: str, value: str) -> bool:
    """Выбор, который бот умеет: состояние из BULK_DEL_STATES или префикс по образцу каталога ядра."""
    if mode == "state":
        return value in BULK_DEL_STATES
    return mode == "prefix" and bool(BULK_PREFIX_RE.match(value))


def bulk_names_lines(user_id: Optional[int], items: List[Tuple[str, str]]) -> List[str]:
    """Люди строками «• подпись — <code>имя</code>» до BULK_LIST_CHARS знаков, хвост — «…и ещё N»."""
    lines: List[str] = []
    used = 0
    for name, label in items:
        row = ("• %s — <code>%s</code>" % (esc(label), esc(name))) if label and label != name else "• <code>%s</code>" % esc(name)
        if used + len(row) > BULK_LIST_CHARS:
            break
        lines.append(row)
        used += len(row) + 1
    if len(lines) < len(items):
        lines.append(_tf(user_id, "user_bulk_more_fmt", len(items) - len(lines)))
    return lines


async def cb_user_bulk_del(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """u_delm: «Удалить сразу несколько» — способ выбора."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    flow_set(context, "user_bulk_del", step="how")
    rows = [[btn(_t(user_id, "user_bulk_del_by_prefix"), "ud_how~prefix")],
            [btn(_t(user_id, "user_bulk_del_by_disabled"), "ud_how~disabled")],
            [btn(_t(user_id, "user_bulk_del_by_expired"), "ud_how~expired")],
            [btn(_t(user_id, "user_bulk_del_by_quota"), "ud_how~quota")],
            _back_row(user_id, "menu_users")]
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "user_bulk_del_title"), _t(user_id, "user_bulk_del_ask_how")),
                            reply_markup=InlineKeyboardMarkup(rows))


async def cb_user_bulk_del_how(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """ud_how~<prefix|disabled|expired|quota>: префикс — ждём текстом, состояние — сразу список."""
    query = update.callback_query
    user_id = _uid(update)
    how = query.data.split("~", 1)[1] if "~" in query.data else ""
    if how == "prefix":
        await query.answer()
        flow_set(context, "user_bulk_del", step="prefix")
        await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "user_bulk_del_title"), _t(user_id, "user_bulk_del_ask_prefix")),
                                reply_markup=InlineKeyboardMarkup([_back_row(user_id, "u_delm")]))
        return
    if how not in BULK_DEL_STATES:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    await _user_bulk_del_preview(query, context, user_id, "state", how, edit=True)


async def cb_user_bulk_del_prefix(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """ud_pfx~<префикс>: список по префиксу ещё раз («Показать заново» после «список изменился»)."""
    query = update.callback_query
    user_id = _uid(update)
    prefix = query.data.split("~", 1)[1] if "~" in query.data else ""
    if not BULK_PREFIX_RE.match(prefix):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    await _user_bulk_del_preview(query, context, user_id, "prefix", prefix, edit=True)


async def _user_bulk_del_preview(target, context, user_id: Optional[int], mode: str, value: str, edit: bool) -> None:
    """Кого задевает выбор (users-del-bulk-preview) → никого / больше 100 / список и ожидание фразы DELETE <число>."""
    r = await run_bot_action("users-del-bulk-preview", timeout=60, state=value if mode == "state" else None,
                             prefix=value if mode == "prefix" else None)
    what = bulk_del_what(user_id, mode, value)
    markup = back_kb(user_id, "menu_users")
    if not bridge_ok(r):
        text = fail_text(user_id, r)
    elif int(r.get("count") or 0) == 0:
        text = "ℹ️ " + _tf(user_id, "user_bulk_del_none_fmt", esc(what))
    elif r.get("too_many"):
        text = "⚠️ " + _tf(user_id, "user_bulk_del_many_fmt", esc(what), int(r.get("count") or 0), int(r.get("max") or BULK_MAX))
    else:
        count = int(r.get("count") or 0)
        items = [(str(s.get("name")), str(s.get("label") or "")) for s in (r.get("selected") or [])
                 if isinstance(s, dict) and valid_name(str(s.get("name") or ""))]
        phrase = confirm_phrase("users-del-bulk", str(count))
        CONFIRM.arm(int(user_id), "users-del-bulk", str(count), phrase, {"mode": mode, "value": value})
        flow_clear(context)
        lines = ["<b>%s</b>" % _t(user_id, "confirm_title"), "", _tf(user_id, "user_bulk_del_preview_fmt", count, esc(what))]
        lines += bulk_names_lines(user_id, items)
        lines += ["", "⚠️ " + _t(user_id, "user_bulk_del_warn"), "", confirm_type_text(user_id, phrase)]
        text = "\n".join(lines)
        markup = InlineKeyboardMarkup([[btn(_t(user_id, "btn_cancel"), "tc_cancel~menu_users")]])
    if edit:
        await safe_edit_message(target, text, reply_markup=markup)
    else:
        note_confirm_message(user_id, await target.reply_text(text, parse_mode="HTML", reply_markup=markup), markup)


async def _user_bulk_del_text(update: Update, context: ContextTypes.DEFAULT_TYPE, flow: Dict[str, Any], text: str) -> None:
    """Префикс текстом; ошибка ввода ожидание не снимает."""
    user_id = _uid(update)
    if flow["data"].get("step") != "prefix":
        await update.message.reply_text(_t(user_id, "user_bulk_del_use_buttons"))
        return
    prefix = parse_bulk_prefix(text)
    if prefix is None:
        await update.message.reply_text(_t(user_id, "user_bulk_bad_prefix"))
        return
    await _user_bulk_del_preview(update.message, context, user_id, "prefix", prefix, edit=False)


def bulk_del_done_text(user_id: Optional[int], r: Dict[str, Any]) -> str:
    """Итог users-del-bulk одним сообщением: сколько и кто, на ком остановилось, кто оставлен выключенным."""
    deleted = [str(n) for n in (r.get("deleted") or []) if valid_name(str(n))]
    kept = [str(n) for n in (r.get("kept") or []) if valid_name(str(n))]
    lines = ["✅ " + _tf(user_id, "user_bulk_del_done_fmt", len(deleted))]
    lines += bulk_names_lines(user_id, [(n, "") for n in deleted])
    failed = r.get("failed") if isinstance(r.get("failed"), dict) else None
    if r.get("partial") and failed:
        lines.append("")
        lines.append("⚠️ " + _tf(user_id, "user_bulk_del_partial_fmt", int(r.get("requested") or 0) - len(deleted),
                                  esc(failed.get("name") or "?"),
                                  esc(str(failed.get("message") or failed.get("code") or "").rstrip(". "))))
    if kept:
        lines.append(_tf(user_id, "user_bulk_del_kept_fmt", len(kept)))
    return "\n".join(lines)


async def _user_bulk_del_run(message, user_id: Optional[int], count: str, mode: str, value: str) -> None:
    """Фраза DELETE <число> принята — удаление; список изменился — отказ ядра и «Показать заново»."""
    await message.reply_text("⏳ " + _tf(user_id, "user_bulk_del_deleting_fmt", int(count)))
    r = await mutate("users-del-bulk", who=user_id, confirm=count, state=value if mode == "state" else None,
                     prefix=value if mode == "prefix" else None)
    if bridge_ok(r):
        await message.reply_text(bulk_del_done_text(user_id, r), parse_mode="HTML",
                                 reply_markup=InlineKeyboardMarkup([[btn(_t(user_id, "menu_users"), "menu_users")]]))
        return
    rows = []
    if str(r.get("code") or "") in ("confirm_mismatch", "lock_timeout"):
        # Тот же выбор ещё раз: список мог измениться — человек увидит, кого он задевает теперь
        if mode == "state" and value in BULK_DEL_STATES:
            rows.append([btn(_t(user_id, "user_bulk_del_again"), "ud_how~%s" % value)])
        elif mode == "prefix" and BULK_PREFIX_RE.match(value):
            rows.append([btn(_t(user_id, "user_bulk_del_again"), "ud_pfx~%s" % value)])
    rows.append(_back_row(user_id, "menu_users"))
    await message.reply_text(fail_text(user_id, r), parse_mode="HTML", reply_markup=InlineKeyboardMarkup(rows))


# ── Лимит · Срок · Вкл/Выкл · Переименовать · Добавить профиль · Удалить ─────

async def cb_user_quota(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    name = _name_from_data(query.data, "u_quota~")
    if not name:
        await show_bad_input(query, user_id, "menu_users")
        return
    flow_set(context, "user_quota", name=name)
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_tf(user_id, "user_quota_title_fmt", esc(name)),
                                                        _t(user_id, "user_ask_quota")),
                            reply_markup=_quota_keyboard(user_id, "uq_set~%s~" % name, "u_view~%s" % name))


async def cb_user_quota_set(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    parts = query.data.split("~")
    if len(parts) != 3 or not valid_name(parts[1]) or not valid_int(parts[2], MAX_QUOTA_GB):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    flow_clear(context)
    if await _action_busy(query, user_id, "u_view~%s" % parts[1]):
        return
    await _apply_user_quota(query, user_id, parts[1], int(parts[2]), edit=True)


async def _apply_user_quota(target, user_id: Optional[int], name: str, gb: int, edit: bool) -> None:
    if not edit:
        await _queued_notice(target, user_id)
    r = await mutate("user-quota", who=user_id, name=name, quota_gb=gb)
    # 0 — «без лимита» (так подписана и кнопка): «Лимит: 0 ГБ» читалось как «трафика нет вовсе».
    shown = _t(user_id, "unlimited") if gb == 0 else "%d %s" % (gb, _t(user_id, "unit_gb"))
    text = ("✅ " + _tf(user_id, "user_quota_set_fmt", esc(name), shown)) if bridge_ok(r) else (fail_text(user_id, r))
    markup = fail_markup(user_id, r, "u_view~%s" % name, retry_data(target) if edit else None)
    if edit:
        await safe_edit_message(target, text, reply_markup=markup)
    else:
        await target.reply_text(text, parse_mode="HTML", reply_markup=markup)


async def cb_user_expiry(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    name = _name_from_data(query.data, "u_exp~")
    if not name:
        await show_bad_input(query, user_id, "menu_users")
        return
    flow_set(context, "user_expiry", name=name)
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_tf(user_id, "user_expiry_title_fmt", esc(name)),
                                                        _t(user_id, "user_ask_days")),
                            reply_markup=_expiry_keyboard(user_id, "ue_set~%s~" % name, "u_view~%s" % name))


async def cb_user_expiry_set(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    parts = query.data.split("~")
    if len(parts) != 3 or not valid_name(parts[1]) or not valid_int(parts[2], MAX_DAYS):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    flow_clear(context)
    if await _action_busy(query, user_id, "u_view~%s" % parts[1]):
        return
    await _apply_user_expiry(query, user_id, parts[1], int(parts[2]), edit=True)


async def _apply_user_expiry(target, user_id: Optional[int], name: str, days: int, edit: bool) -> None:
    if not edit:
        await _queued_notice(target, user_id)
    r = await mutate("user-expiry", who=user_id, name=name, days=days)
    # 0 — «бессрочно» (так подписана и кнопка): «Срок: 0 дней» читалось как «доступ уже истёк».
    shown = _t(user_id, "never") if days == 0 else _days(user_id, days)
    text = ("✅ " + _tf(user_id, "user_expiry_set_fmt", esc(name), shown)) if bridge_ok(r) else (fail_text(user_id, r))
    markup = fail_markup(user_id, r, "u_view~%s" % name, retry_data(target) if edit else None)
    if edit:
        await safe_edit_message(target, text, reply_markup=markup)
    else:
        await target.reply_text(text, parse_mode="HTML", reply_markup=markup)


async def cb_user_toggle(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    parts = query.data.split("~")
    if len(parts) != 3 or not valid_name(parts[1]) or parts[2] not in ("on", "off"):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    if await _action_busy(query, user_id, "u_view~%s" % parts[1]):
        return
    action = "user-enable" if parts[2] == "on" else "user-disable"
    r = await mutate(action, who=user_id, name=parts[1])
    if not bridge_ok(r):
        await show_error(query, user_id, r, "u_view~%s" % parts[1])
        return
    await show_user_card(query, user_id, parts[1])


async def cb_user_rename(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    name = _name_from_data(query.data, "u_ren~")
    if not name:
        await show_bad_input(query, user_id, "menu_users")
        return
    flow_set(context, "user_rename", name=name)
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_tf(user_id, "user_rename_title_fmt", esc(name)),
                                                        _t(user_id, "user_ask_new_label")),
                            reply_markup=cancel_kb(user_id, "u_view~%s" % name))


async def cb_user_add_profile(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    name = _name_from_data(query.data, "u_addp~")
    if not name:
        await show_bad_input(query, user_id, "menu_users")
        return
    r, user = await _fetch_user(name)
    if user is None:
        await show_error(query, user_id, r, "menu_users")
        return
    status = await get_status()
    have = set((user.get("peers") or {}).keys())
    candidates = [p for p in installed_profiles(status) if p not in have]
    rows = [[btn(profile_title(user_id, p, status), "u_addp_do~%s~%s" % (name, p))] for p in candidates]
    rows.append(_back_row(user_id, "u_view~%s" % name))
    text = "<b>%s</b>\n\n%s" % (_tf(user_id, "user_add_profile_title_fmt", esc(name)),
                                _t(user_id, "user_add_profile_pick") if candidates else _t(user_id, "user_add_profile_none"))
    await safe_edit_message(query, text, reply_markup=InlineKeyboardMarkup(rows))


async def cb_user_add_profile_do(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    parts = query.data.split("~")
    if len(parts) != 3 or not valid_name(parts[1]) or not valid_profile(parts[2]):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    if await _action_busy(query, user_id, "u_view~%s" % parts[1]):
        return
    r = await mutate("user-add-peer", who=user_id, name=parts[1], profile=parts[2])
    if not bridge_ok(r):
        await show_error(query, user_id, r, "u_view~%s" % parts[1])
        return
    await show_user_card(query, user_id, parts[1])


# ── Убрать профиль у пользователя ────────────────────────────────────────────
# Пара к «Добавить профиль»: у импортированного из приложения Amnezia
# пользователя приватного ключа нет, и новый .conf выдаётся только
# перевыпуском пира — убрать профиль и добавить снова (docs/CONTRACT.md §
# «no_private_key»). Действие моста разрушительное, поэтому между выбором
# профиля и выполнением стоит экран подтверждения.

async def cb_user_del_profile(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """u_delp~<name>: из какого профиля убрать конфигурацию."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    name = _name_from_data(query.data, "u_delp~")
    if not name:
        await show_bad_input(query, user_id, "menu_users")
        return
    r, user = await _fetch_user(name)
    if user is None:
        await show_error(query, user_id, r, "menu_users")
        return
    have = [p for p in PROFILE_IDS if p in (user.get("peers") or {})]
    rows = [[btn(profile_title(user_id, p), "u_delp_ask~%s~%s" % (name, p))] for p in have]
    rows.append(_back_row(user_id, "u_view~%s" % name))
    text = "<b>%s</b>\n\n%s" % (_tf(user_id, "user_del_profile_title_fmt", esc(name)),
                                _t(user_id, "user_del_profile_pick") if have else _t(user_id, "user_del_profile_none"))
    await safe_edit_message(query, text, reply_markup=InlineKeyboardMarkup(rows))


async def cb_user_del_profile_ask(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """u_delp_ask~<name>~<profile>: что именно перестанет работать."""
    query = update.callback_query
    user_id = _uid(update)
    parts = query.data.split("~")
    if len(parts) != 3 or not valid_name(parts[1]) or not valid_profile(parts[2]):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    name, profile = parts[1], parts[2]
    rows = [[btn(_t(user_id, "btn_confirm"), "u_delp_do~%s~%s" % (name, profile))],
            _back_row(user_id, "u_delp~%s" % name)]
    text = "<b>%s</b>\n\n⚠️ %s" % (
        _t(user_id, "confirm_title"),
        _tf(user_id, "user_del_profile_warn_fmt", esc(name), esc(profile_title(user_id, profile))))
    await safe_edit_message(query, text, reply_markup=InlineKeyboardMarkup(rows))


async def cb_user_del_profile_do(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    parts = query.data.split("~")
    if len(parts) != 3 or not valid_name(parts[1]) or not valid_profile(parts[2]):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    name, profile = parts[1], parts[2]
    if await _action_busy(query, user_id, "u_view~%s" % name):
        return
    r = await mutate("user-del-peer", who=user_id, name=name, profile=profile)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "u_view~%s" % name)
        return
    await safe_edit_message(
        query,
        "✅ " + _tf(user_id, "user_del_profile_done_fmt", esc(profile_title(user_id, profile)), esc(name)),
        reply_markup=back_kb(user_id, "u_view~%s" % name))


# ── Перевыпуск ключа на профиле ──────────────────────────────────────────────
# Пир, подхваченный из контейнера приложения Amnezia, приходит с `has_key:
# false`: приватной части у сервера нет. Раньше перевыпуск делался двумя
# неочевидными нажатиями — «Убрать профиль» и «Добавить профиль»; теперь это
# одна кнопка прямо на профиле, ровно как пункт `user_peer_reissue_item` в
# SSH-меню (install.sh `_user_peer_reissue`).
#
# Действие разрушительное — конфиг, который уже стоит у клиента, перестаёт
# подключаться, — поэтому между кнопкой и мостом стоит отдельный экран
# переспроса, той же манеры, что у «Убрать профиль» и удаления пользователя.
# Для ключа из приложения Amnezia переспрос говорит больше: у такого человека
# ключ живёт в приложении, и после перевыпуска он сломается сразу — а если
# ссылка или файл у админа сохранились, привязать их лучше (кнопка тут же).

async def cb_user_peer_reissue(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """u_reis~<name>~<profile>: чем придётся заплатить за новый ключ."""
    query = update.callback_query
    user_id = _uid(update)
    parts = query.data.split("~")
    if len(parts) != 3 or not valid_name(parts[1]) or not valid_profile(parts[2]):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    name, profile = parts[1], parts[2]
    r, user = await _fetch_user(name)
    if user is None:
        await show_error(query, user_id, r, "menu_users")
        return
    peers = user.get("peers") if isinstance(user.get("peers"), dict) else {}
    if profile not in peers:
        # Профиль убрали, пока экран висел: перевыпускать нечего — карточка покажет, что есть сейчас
        await show_user_card(query, user_id, name)
        return
    from_app = not peer_has_key(peers.get(profile))
    rows = [[btn(_t(user_id, "btn_confirm"), "u_reis_do~%s~%s" % (name, profile))]]
    if from_app:
        rows.append([btn(_t(user_id, "user_peer_attach_btn"), "u_att~%s~%s" % (name, profile))])
    rows.append(_back_row(user_id, "u_view~%s" % name))
    text = "<b>%s</b>\n\n⚠️ %s" % (
        _t(user_id, "confirm_title"),
        _tf(user_id, "user_peer_reissue_warn_fmt", esc(name), esc(profile_title(user_id, profile))))
    text += "\n\n" + esc(reissue_facts_text(user_id, await reissue_facts(name, profile), False))
    if from_app:
        text += "\n\n" + _t(user_id, "user_peer_reissue_imported_warn")
    await safe_edit_message(query, text, reply_markup=InlineKeyboardMarkup(rows))


async def reissue_facts(name: str, profile: str) -> Dict[str, Any]:
    """Н-4 (как B3-4 в панели): что пользователю делать после перевыпуска ключа — по фактам. pages — живые страницы с
    этим профилем, sub — подписка отдаёт ключ этого профиля, hours — через сколько часов приложения забирают её сами.
    Не ответило — None: экран скажет условно."""
    f: Dict[str, Any] = {"pages": None, "sub": None, "hours": 12, "slow": []}
    r = await run_bot_action("page-list", timeout=60, name=name)
    if bridge_ok(r):
        f["pages"] = len([p for p in page_records(r) if p.get("user") == name and profile in (p.get("profiles") or [])])
    r = await run_bot_action("sub-list", timeout=60, name=name)
    if bridge_ok(r):
        try:
            f["hours"] = int(r.get("update_interval") or 12) or 12
        except (TypeError, ValueError):
            f["hours"] = 12
        slow = r.get("update_slow")
        f["slow"] = slow if isinstance(slow, list) else []
        rec = sub_record(r, name)
        f["sub"] = bool(rec and not rec.get("disabled") and any(
            isinstance(l, dict) and l.get("profile") == profile and l.get("has_key") is not False for l in rec.get("lines") or []))
    return f


def sub_within(user_id: Optional[int], f: Dict[str, Any]) -> str:
    """A4-3/B4-4 (как subWithin в панели): через сколько приложение заберёт подписку само — совет сервера и
    приложения, которые его не слушают и обновляют реже (update_slow ответа sub-list: FlClash — раз в сутки).
    «до 12 ч» или «до 12 ч, у FlClash — до 24 ч»; приложения с одним сроком — через запятую, сначала самые долгие."""
    hours = f.get("hours") or 12
    by: Dict[int, List[str]] = {}
    for x in f.get("slow") or []:
        if not isinstance(x, dict) or not isinstance(x.get("name"), str) or not x.get("name"):
            continue
        h = x.get("hours")
        if isinstance(h, bool) or not isinstance(h, int) or h <= hours:
            continue
        by.setdefault(h, []).append(x["name"])
    if not by:
        return _tf(user_id, "reis_within_fmt", hours)
    rest = ", ".join(_tf(user_id, "reis_within_app_fmt", ", ".join(by[h]), h) for h in sorted(by, reverse=True))
    return _tf(user_id, "reis_within_slow_fmt", hours, rest)


def sub_within_now(user_id: Optional[int], status: Any) -> str:
    """R8-2 (как subWithinNow в панели): срок забора подписки без человека — окно «Исправить S4». R9-1: из поля
    subs_update свежего status ({update_interval, update_slow}, как в sub-list), а не из sub-list без имени — тот строил
    строку каждой подписки (1000 подписок — минута). Поля нет или оно не разобралось — «до 12 ч»."""
    f: Dict[str, Any] = {"hours": 12, "slow": []}
    su = status.get("subs_update") if isinstance(status, dict) else None
    if isinstance(su, dict):
        h = su.get("update_interval")
        if isinstance(h, int) and not isinstance(h, bool) and h > 0:
            f["hours"] = h
        slow = su.get("update_slow")
        f["slow"] = slow if isinstance(slow, list) else []
    return sub_within(user_id, f)


def reissue_facts_text(user_id: Optional[int], f: Dict[str, Any], done: bool) -> str:
    """Слова панели (reissueFactsText): страница — открыть заново, подписка — сама до N ч или «Обновить», ручное —
    отправить заново; ничего из этого — отправить новый ключ из карточки."""
    manual = _t(user_id, "reis_done_manual") if done else _t(user_id, "reis_manual")
    if f.get("pages") is None or f.get("sub") is None:
        return " ".join([manual, _tf(user_id, "reis_unknown_fmt", sub_within(user_id, f))])
    if not f["pages"] and not f["sub"]:
        return _t(user_id, "reis_done_only_manual") if done else _t(user_id, "reis_only_manual")
    out = []
    if f["pages"]:
        out.append(_t(user_id, "reis_done_pages") if done else _t(user_id, "reis_pages"))
    if f["sub"]:
        within = sub_within(user_id, f)
        out.append(_tf(user_id, "reis_done_sub_fmt", within) if done else _tf(user_id, "reis_sub_fmt", within))
    out.append(manual)
    return " ".join(out)


async def cb_user_peer_reissue_do(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """u_reis_do~<name>~<profile>: перевыпуск ключа ОДНИМ действием моста.

    Раньше здесь была пара «user-del-peer, потом user-add-peer». Между ними
    было окно: упал бот или оборвалась сеть — и человек оставался без доступа на
    профиль, хотя просил новый ключ. Теперь подмену делает ядро под общим
    замком и само возвращает прежний ключ, если применение сорвалось.
    """
    query = update.callback_query
    user_id = _uid(update)
    parts = query.data.split("~")
    if len(parts) != 3 or not valid_name(parts[1]) or not valid_profile(parts[2]):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    name, profile = parts[1], parts[2]
    if await _action_busy(query, user_id, "u_view~%s" % name):
        return
    title = profile_title(user_id, profile)
    facts = await reissue_facts(name, profile)
    r = await mutate("user-reissue-peer", who=user_id, name=name, profile=profile)
    if not bridge_ok(r):
        # Ядро при отказе возвращает прежний ключ, поэтому доступ у человека
        # остаётся — но если откат тоже не удался, ядро сказало об этом в своём
        # сообщении, и кнопка «Добавить профиль» тут первая именно на этот случай.
        await safe_edit_message(
            query,
            "❗️ " + _tf(user_id, "user_peer_reissue_lost_fmt", error_text(user_id, r), esc(title),
                        esc(_t(user_id, "user_add_profile"))),
            reply_markup=InlineKeyboardMarkup([[btn(_t(user_id, "user_add_profile"), "u_addp~%s" % name)],
                                               _back_row(user_id, "u_view~%s" % name)]))
        return
    # Обратно в карточку, а не на экран «готово»: новый ключ забирают кнопками
    # выдачи, которые там же и появились вместо перевыпуска.
    await show_user_card(query, user_id, name,
                         note="✅ " + _tf(user_id, "user_peer_reissued_fmt", esc(title)) + "\n"
                         + esc(reissue_facts_text(user_id, facts, True)))


# ── Привязать старый ключ (user-attach-key, docs/CONTRACT.md) ────────────────
# Второй выход для ключа из приложения Amnezia, и он без потерь: админ присылает
# ту ссылку vpn:// или файл .conf, которые когда-то отправил человеку; ядро
# проверяет, что ключ именно этого человека и этого сервера, и сохраняет его.
# У человека ничего не меняется, а кнопки выдачи в карточке начинают работать.
#
# Ключ — секрет в чистом виде, поэтому: (а) мосту он уходит только через stdin
# (в argv его видно в `ps` любому процессу); (б) в лог бота не пишется ни
# строкой — ни текст, ни вывод моста; (в) сообщение админа с ключом бот убирает
# из чата сразу, до проверки, чем бы она ни кончилась.
ATTACH_MAX_BYTES = 64 * 1024      # предел ядра на stdin user-attach-key
# Имена, под которыми ключ приезжает файлом (docs/SHARE.md «Имя файла»; так же — выгрузка из SSH
# и приложения Amnezia): .conf, .vpn, длинная ссылка самого бота .vpn.txt, QR ключа
# <имя>-<профиль>[-<хост>]-qr.png|.zip|.tar.gz и архив всего сразу <имя>-<профиль>[-<хост>].zip|.tar.gz.
# Без ожидания такой файл — ключ в переписке, мимо моста: из чата прочь (UI-1). Раньше узнавались
# только .conf и .vpn.txt, а свои же .vpn, QR и архивы раздачи оставались в истории.
KEY_FILE_RE = re.compile(r"(\.conf|\.vpn|\.vpn\.txt|-qr\.(png|zip|tar\.gz)|-awg[1-3](-[^/\\]+)?\.(zip|tar\.gz))$",
                         re.IGNORECASE)
# Отказы про сам присланный ключ (не ссылка и не .conf, другой сервер, чужой
# ключ): ожидание НЕ снимается — следующая ссылка или файл сразу уйдут на
# проверку, как у любого текстового шага с ошибкой ввода.
ATTACH_RETRY_CODES = ("no_config", "config_unreadable", "server_mismatch", "key_mismatch")
# Что прислать вместо (сцены attach-key-mismatch, attach-unreadable дизайна 0.5.0): у чужого ключа —
# ключ именно этого человека, у нечитаемого — ссылку целиком или файл; остальным — общее «другую».
ATTACH_RETRY_HINTS = {"key_mismatch": "user_peer_attach_retry_mismatch",
                      "config_unreadable": "user_peer_attach_retry_unreadable"}
# Ключ до проверки не дошёл или ответ потерян (замок занят, таймаут, мост без ответа): это
# не «ключ не тот», и сбрасывать ожидание незачем — человеку остаётся прислать его ещё раз.
ATTACH_TRANSIENT_CODES = ("lock_timeout", "timeout", "transport")


def looks_like_key(text: str) -> bool:
    """Похоже на ключ AmneziaWG: ссылка vpn:// (где угодно в тексте — её пересылают вместе с подписью,
    ядро ищет её так же) или текст .conf с [Interface] и PrivateKey."""
    low = (text or "").lower()
    return "vpn://" in low or ("[interface]" in low and "privatekey" in low)


async def cb_user_peer_attach(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """u_att~<name>~<profile>: ждать ссылку vpn:// или файл .conf старого ключа."""
    query = update.callback_query
    user_id = _uid(update)
    parts = str(query.data).split("~")
    if len(parts) != 3 or not valid_name(parts[1]) or not valid_profile(parts[2]):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    name, profile = parts[1], parts[2]
    r, user = await _fetch_user(name)
    if user is None:
        await show_error(query, user_id, r, "menu_users")
        return
    peers = user.get("peers") if isinstance(user.get("peers"), dict) else {}
    if profile not in peers or peer_has_key(peers.get(profile)):
        # Кнопка нарисована раньше: профиль убрали, или ключ уже на сервере (привязали из
        # панели, перевыпустили) — ждать нечего, карточка покажет, как есть сейчас.
        note = "ℹ️ " + _tf(user_id, "user_peer_attach_not_needed_fmt", esc(profile_name(user_id, profile))) if profile in peers else ""
        await show_user_card(query, user_id, name, note=note)
        return
    flow_set(context, "peer_attach", name=name, profile=profile)
    text = "<b>%s</b>\n\n%s\n\n<i>%s</i>" % (
        _tf(user_id, "user_peer_attach_title_fmt", esc(name), esc(profile_title(user_id, profile))),
        _tf(user_id, "user_peer_attach_prompt_fmt", esc(profile_name(user_id, profile))),
        _t(user_id, "user_peer_attach_privacy"))
    await safe_edit_message(query, text, reply_markup=cancel_kb(user_id, "u_view~%s" % name))


async def _forget_key_message(message) -> bool:
    """Убрать из чата сообщение админа с ключом. Бот вправе удалять входящие в
    личном чате; не вышло (сеть, старое сообщение) — проверка всё равно прошла.
    True — удалено."""
    try:
        await message.delete()
        return True
    except Exception as e:  # noqa: BLE001 — сообщение могли удалить руками
        logger.debug("attach: key message not deleted (%s)", type(e).__name__)
        return False


async def _drop_key_message(message, user_id: Optional[int]) -> str:
    """Убрать сообщение с ключом там, где мост его так и не увидит, — и строка об этом для ответа.

    Раньше сообщение удалялось только после проверки мостом, а на всех путях мимо моста
    (ожидание истекло или кнопку не нажимали, файл .conf «не вовремя», файл больше 64 КБ,
    не скачался, QR-картинкой) рабочий приватный ключ оставался в истории чата навсегда —
    ровно то, от чего шаг «Привязать старый ключ» обещает беречь (находка UI-1).
    """
    if await _forget_key_message(message):
        return _t(user_id, "user_peer_attach_key_removed")
    return _t(user_id, "user_peer_attach_key_left")


async def _peer_attach_submit(message, context, user_id: Optional[int], flow: Dict[str, Any], payload: str) -> None:
    """Ключ от админа → user-attach-key через stdin. Удача — карточка новым сообщением, где выдача
    уже работает; ключ не тот — слова ядра и ожидание следующей ссылки или файла; остальное — ошибка."""
    data = flow.get("data") or {}
    name, profile = str(data.get("name") or ""), str(data.get("profile") or "")
    if not valid_name(name) or not valid_profile(profile):
        flow_clear(context)
        removed = await _drop_key_message(message, user_id)
        await message.reply_text("❌ %s\n\n%s" % (_t(user_id, "err_bad_input"), removed),
                                 reply_markup=back_kb(user_id, "menu_users"))
        return
    back = "u_view~%s" % name
    payload = (payload or "").strip()
    if len(payload.encode("utf-8")) > ATTACH_MAX_BYTES:
        removed = await _drop_key_message(message, user_id)
        await message.reply_text("%s\n\n%s" % (_tf(user_id, "user_peer_attach_too_big_fmt", ATTACH_MAX_BYTES // 1024),
                                               removed), reply_markup=cancel_kb(user_id, back))
        return
    # Ключ в переписке — тот же секрет, что в файле, а текст его уже в памяти: сообщение из
    # чата прочь сразу, ДО моста, чем бы ни кончилась проверка. Вызов может ждать замок до
    # 15 минут (установка профиля), и упади бот за это время — ключ остался бы в истории (UI-1).
    deleted = await _forget_key_message(message)
    await _queued_notice(message, user_id)     # проверка встаёт за замком: повторять не нужно
    try:
        r = await mutate("user-attach-key", who=user_id, name=name, profile=profile, stdin=payload)
    finally:
        if not deleted:
            deleted = await _forget_key_message(message)      # сеть мигнула — вторая попытка
    # Обе попытки не удались — сказать прямо и в каждом ответе ниже: удалить самому. Иначе
    # ответы молчали бы о ключе в чате, а «сообщение я убрал» было бы неправдой.
    left = "" if deleted else "\n\n" + _t(user_id, "user_peer_attach_key_left")
    code = str(r.get("code") or "")
    if code in ATTACH_TRANSIENT_CODES:
        # Мост ключ не проверил (замок занят) или ответа не дождались: ожидание остаётся —
        # прислать тот же ключ ещё раз, без новых нажатий (UI-3). Если привязка всё-таки прошла,
        # повтор получит already_has_key — и карточку.
        flow["since"] = time.monotonic()
        logger.info("user %s: old key on %s not checked (%s), waiting for a resend", name, profile, code)
        removed = _t(user_id, "user_peer_attach_key_removed" if deleted else "user_peer_attach_key_left")
        await message.reply_text("❌ %s\n\n%s\n\n%s" % (error_text(user_id, r), _t(user_id, "user_peer_attach_retry_later"),
                                                     removed),
                                 parse_mode="HTML", reply_markup=cancel_kb(user_id, back))
        return
    if bridge_ok(r):
        flow_clear(context)
        logger.info("user %s: old key attached on %s", name, profile)
        # Слова ядра и есть итог («привязан, у человека ничего не изменилось»); под ними —
        # карточка, где на этом профиле уже стоят кнопки выдачи.
        done = esc(r.get("message")) if r.get("message") else _tf(user_id, "user_peer_attached_fmt", esc(name),
                                                                  esc(profile_name(user_id, profile)))
        text, markup = await user_card_view(user_id, name, note="✅ " + done + left)
        await message.reply_text(clip_lines(text), parse_mode="HTML", reply_markup=markup, disable_web_page_preview=True)
        return
    logger.info("user %s: old key on %s refused (%s)", name, profile, code or "?")
    if code in ATTACH_RETRY_CODES:
        hint = _t(user_id, ATTACH_RETRY_HINTS.get(code, "user_peer_attach_retry"))
        await message.reply_text("❌ %s\n\n%s%s" % (error_text(user_id, r), hint, left),
                                 parse_mode="HTML", reply_markup=cancel_kb(user_id, back))
        return
    flow_clear(context)
    if code == "already_has_key":
        # Ключ уже на сервере (привязали с другого экрана): итог — та же карточка с кнопками выдачи
        text, markup = await user_card_view(user_id, name, note="ℹ️ " + esc(r.get("message") or code) + left)
        await message.reply_text(clip_lines(text), parse_mode="HTML", reply_markup=markup, disable_web_page_preview=True)
        return
    await message.reply_text(fail_text(user_id, r) + left, parse_mode="HTML", reply_markup=back_kb(user_id, back))


async def _document_holds_key(doc) -> bool:
    """Файл без ожидания и с «чужим» именем — ключ ли внутри: до 64 КБ скачиваем и смотрим текст
    (.conf, сохранённый как «ключ.txt», ссылка vpn:// файлом). Больше или не скачался — не ключ."""
    size = int(getattr(doc, "file_size", 0) or 0)
    if size <= 0 or size > ATTACH_MAX_BYTES:
        return False
    try:
        raw = bytes(await (await doc.get_file()).download_as_bytearray())
    except (TelegramError, OSError) as e:
        # В лог — только вид сбоя: в адресе файла Bot API лежит токен бота
        logger.debug("file check: download failed (%s)", type(e).__name__)
        return False
    return looks_like_key(raw[:ATTACH_MAX_BYTES].decode("utf-8-sig", errors="replace"))


# Вложения, у которых ключом может быть только подпись (фильтр filters.CAPTION в register_handlers)
CAPTION_ONLY_MEDIA = ("video", "audio", "voice", "animation", "paid_media")


async def handle_other_message(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Сообщение из лички, которое бот иначе не читает (стикер, голосовое, контакт, незнакомая
    команда), и файл не-админа. Нужно оно окну привязки: SSH просит «написать боту любое
    сообщение», и стикер от владельца тоже должен сделать его кандидатом. Чужому — тот же ответ,
    что на текст, и вне окна тоже: по молчанию вне окна и ответу в окне посторонний видел, что
    окно открыто (SEC50-01). Админу — как раньше: ни ответа, ни записи."""
    message = update.message
    if message is None or not is_private_chat(update):
        return
    if is_user_allowed(_uid(update)):
        return
    await stranger_pairing_reply(update, str(getattr(message, "text", "") or ""))


async def handle_file_message(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Файл, картинка или другое вложение с подписью. Ждёт их только шаг «Привязать старый ключ»:
    файл ключа (.conf, .vpn, …) не больше 64 КБ. Остальное бот проверяет на одно — не ключ ли это
    в переписке мимо моста (UI-1): такое сообщение убирается из чата."""
    message = update.message
    if message is None or not is_private_chat(update):
        return
    user_id = _uid(update)
    if not is_user_allowed(user_id):
        await handle_other_message(update, context)   # «любое сообщение» в окне привязки — и файл тоже
        return
    # Истёкшее ожидание flow_get молча забудет — а картинка или файл, пришедшие первыми после
    # него, почти наверняка и есть ключ, который искали дольше десяти минут: без этой проверки
    # QR ключа, присланный на минуту позже, оставался в истории чата (UI-1). Смотрим ДО flow_get.
    stale = context.user_data.get("flow")
    after_attach = isinstance(stale, dict) and stale.get("kind") == "peer_attach"
    flow = flow_get(context)
    waiting = bool(flow) and flow.get("kind") == "peer_attach"
    # Ссылка vpn:// в подписи к картинке или файлу — тот же ключ в переписке
    caption = str(getattr(message, "caption", "") or "")
    key_in_caption = looks_like_key(caption)
    doc = getattr(message, "document", None)
    if doc is None and any(getattr(message, a, None) for a in CAPTION_ONLY_MEDIA):
        # Видео, аудио, голосовое с подписью: ключом здесь может быть только подпись. Пока ждём
        # ключ — она и уходит на проверку; без ожидания — из чата прочь. Без ключа в подписи бот
        # такие вложения, как и раньше, молча пропускает.
        if waiting and key_in_caption:
            await _peer_attach_submit(message, context, user_id, flow, caption)
        elif key_in_caption:
            removed = await _drop_key_message(message, user_id)
            await message.reply_text("%s\n\n%s" % (_t(user_id, "user_peer_attach_unexpected"), removed))
        return
    if doc is None:
        # Картинка: QR-код с неё бот не читает — говорим, что прислать вместо. Пока ждём ключ,
        # картинка и есть ключ (QR ссылки или .conf) — в переписке ей не место (UI-1); ссылка
        # vpn:// в подписи к ней — сам ключ: её и проверяем.
        if waiting and key_in_caption:
            await _peer_attach_submit(message, context, user_id, flow, caption)
        elif waiting:
            removed = await _drop_key_message(message, user_id)
            await message.reply_text("%s\n\n%s" % (_t(user_id, "user_peer_attach_photo"), removed))
        elif after_attach or key_in_caption:
            removed = await _drop_key_message(message, user_id)
            await message.reply_text("%s\n\n%s" % (_t(user_id, "user_peer_attach_unexpected"), removed))
        else:
            await message.reply_text(_t(user_id, "text_no_waiter"))
        return
    if not waiting:
        # Ожидание истекло или кнопку не нажимали: файл ключа молча не пропадает — говорим, откуда
        # привязывают, а сам файл убираем: мост его не увидит, а приватный ключ в истории остался бы.
        # Ключ — по имени (KEY_FILE_RE: свои .vpn, QR и архивы раздачи тоже), по подписи, по
        # содержимому до 64 КБ, а сразу после истёкшего ожидания — любой файл: Windows прячет
        # расширения, и «proba.conf» приезжает как «proba.conf.txt».
        fname = str(getattr(doc, "file_name", "") or "")
        if after_attach or key_in_caption or KEY_FILE_RE.search(fname) or await _document_holds_key(doc):
            removed = await _drop_key_message(message, user_id)
            await message.reply_text("%s\n\n%s" % (_t(user_id, "user_peer_attach_unexpected"), removed))
        else:
            await message.reply_text(_t(user_id, "text_no_waiter"))
        return
    back = "u_view~%s" % str((flow.get("data") or {}).get("name") or "")
    if int(getattr(doc, "file_size", 0) or 0) > ATTACH_MAX_BYTES:
        removed = await _drop_key_message(message, user_id)
        await message.reply_text("%s\n\n%s" % (_tf(user_id, "user_peer_attach_too_big_fmt", ATTACH_MAX_BYTES // 1024),
                                               removed), reply_markup=cancel_kb(user_id, back))
        return
    try:
        tg_file = await doc.get_file()
        raw = bytes(await tg_file.download_as_bytearray())
    except (TelegramError, OSError) as e:
        # В лог — только вид сбоя: в адресе файла Bot API лежит токен бота
        logger.warning("attach: file download failed (%s)", type(e).__name__)
        removed = await _drop_key_message(message, user_id)
        await message.reply_text("%s\n\n%s" % (_t(user_id, "user_peer_attach_download_failed"), removed),
                                 reply_markup=cancel_kb(user_id, back))
        return
    if len(raw) > ATTACH_MAX_BYTES:
        removed = await _drop_key_message(message, user_id)
        await message.reply_text("%s\n\n%s" % (_tf(user_id, "user_peer_attach_too_big_fmt", ATTACH_MAX_BYTES // 1024),
                                               removed), reply_markup=cancel_kb(user_id, back))
        return
    # utf-8-sig: .conf, сохранённый Блокнотом Windows, начинается с BOM. Нечитаемое — не наша забота:
    # ядро ответит config_unreadable своими словами, и ожидание останется.
    await _peer_attach_submit(message, context, user_id, flow, raw.decode("utf-8-sig", errors="replace"))


# ── Временная ссылка на файл конфигурации (lib/share.sh, docs/SHARE.md) ──────
# Зачем: человек с телефона не всегда может «скачать документ Telegram» туда,
# куда его ждёт клиент AmneziaWG (роутер, чужой компьютер, десктоп без
# Telegram). Раздача поднимает одноразовый HTTPS-слушатель на случайном порту,
# отдаёт файл по секретному адресу и гаснет через пять минут.
#
# Секрет: адрес РАВЕН ключу. Поэтому он (а) уходит отдельным сообщением, чтобы
# его можно было удалить, не теряя карточку; (б) без предпросмотра ссылки —
# иначе Telegram сходит по адресу сам и сожжёт одноразовую раздачу; (в) НЕ
# пишется в лог бота ни одной строкой — в лог идёт только id раздачи, как у
# показа приватного ключа в _user_key и у адресов агентов.
# QR через ссылку не отдаём: он и так есть кнопками в этой же карточке.

async def _share_delete_later(message, delay: float, share_id: str) -> None:
    """Удалить сообщение с адресом, когда раздача протухла.

    Ссылка живёт пять минут, а сообщение с ней осталось бы в чате навсегда:
    мёртвый секрет всё равно секрет, и лишний повод его переслать. Рестарт
    бота задачу теряет — раздача к тому времени всё равно закрыта мостом.
    """
    try:
        await asyncio.sleep(max(1.0, delay))
        await message.delete()
    except asyncio.CancelledError:  # noqa: PERF203 — выключение бота, не ошибка
        raise
    except Exception as e:  # noqa: BLE001 — сообщение могли удалить руками
        logger.debug("share %s: сообщение с адресом уже убрано (%s)", share_id, e)


def share_link_text(user_id: Optional[int], r: Dict[str, Any]) -> str:
    """Сообщение с адресом раздачи: сам адрес, срок, файл, отпечаток, предупреждение."""
    minutes = max(1, int(r.get("ttl") or 300) // 60)
    lines = ["<b>%s</b>" % _t(user_id, "share_link_title"), ""]
    lines.append("<code>%s</code>" % esc(r.get("url") or ""))
    lines.append("")
    lines.append(_tf(user_id, "share_link_file_fmt", esc(r.get("file_name") or "—"),
                     human_bytes(r.get("size"), user_id)))
    # Раздача с разовым адресом сервера («Ключ на другой адрес»): ядро кладёт его в `endpoint`
    endpoint = str(r.get("endpoint") or "").strip()
    if endpoint:
        lines.append(_tf(user_id, "key_caption_addr_fmt", esc(endpoint)))
    lines.append(_tf(user_id, "share_link_ttl_fmt", minutes))
    if r.get("selfsigned"):
        lines.append("")
        lines.append(_t(user_id, "share_selfsigned_warn"))
        lines.append("%s <code>%s</code>" % (_t(user_id, "share_fingerprint"), esc(r.get("fingerprint") or "—")))
    lines.append("")
    lines.append(_t(user_id, "share_link_is_key"))
    return "\n".join(lines)


async def cb_user_share(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """u_share~<name>: из какого профиля отдать файл (единственный — сразу дальше)."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    name = _name_from_data(query.data, "u_share~")
    if not name:
        await show_bad_input(query, user_id, "menu_users")
        return
    r, user = await _fetch_user(name)
    if user is None:
        await show_error(query, user_id, r, "menu_users")
        return
    if user.get("enabled") is False:
        # Выключенному ядро ссылку не создаст (user_disabled, A3-5): пира нет, файл не подключится —
        # говорим это до выбора профиля и формата, как у страницы подключения.
        await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_tf(user_id, "share_title_fmt", esc(name)),
                                                            _t(user_id, "share_user_disabled")),
                                reply_markup=back_kb(user_id, "u_view~%s" % name))
        return
    # Только те профили, по которым файл вообще можно собрать: у пира с ключом из
    # приложения Amnezia `share-create` отвечает `no_private_key`, как и выдача документом.
    have = peers_with_key(user)
    from_app = imported_profiles(user)
    if from_app and not have:
        # Отдавать нечего, но это не «ключей нет»: они у человека в приложении — правда и два выхода
        text, markup = imported_view(user_id, name, from_app)
        await safe_edit_message(query, text, reply_markup=markup)
        return
    if len(have) == 1 and not from_app:
        # Выбирать не из чего — сразу к формату, экраном того же обработчика.
        await dispatch_callback_data(update, context, "u_shf~%s~%s" % (name, have[0]))
        return
    rows = [[btn(profile_title(user_id, p), "u_shf~%s~%s" % (name, p))] for p in have]
    rows.append(_back_row(user_id, "u_view~%s" % name))
    body = _t(user_id, "share_pick_profile") if have else _t(user_id, "share_no_peers")
    # Профиль с ключом из приложения в выборе не стоит — и экран говорит почему (даже при
    # одном «своём» профиле экран выбора не пропускаем: иначе его отсутствие осталось бы загадкой).
    lines = ["<b>%s</b>" % _tf(user_id, "share_title_fmt", esc(name)), "", body] + imported_short_lines(user_id, from_app)
    await safe_edit_message(query, "\n".join(lines), reply_markup=InlineKeyboardMarkup(rows))


async def cb_user_share_format(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """u_shf~<name>~<profile>[~<addr>]: что положить в файл — .conf или ключ приложения.

    С <addr> — ветка «Ключ на другой адрес»: в файле другой адрес сервера, «Назад» ведёт к
    профилям этого адреса, а не к выбору профиля раздачи.
    """
    query = update.callback_query
    user_id = _uid(update)
    parts = str(query.data).split("~")
    if len(parts) not in (3, 4) or not valid_name(parts[1]) or not valid_profile(parts[2]) \
            or (len(parts) == 4 and not KEY_ADDR_RE.match(parts[3])):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    name, profile = parts[1], parts[2]
    addr = parts[3] if len(parts) == 4 else ""
    host = ""
    if addr:
        edge, choice = await resolve_key_addr(addr)
        if choice is None:
            await show_key_addr_miss(query, user_id, name, edge)
            return
        host = str(choice.get("host") or "")
    await query.answer()
    rows = [[btn(_t(user_id, SHARE_FORMAT_KEYS[fmt]),
                 ("u_shdo~%s~%s~%s~%s" % (name, profile, fmt, addr)) if addr else ("u_shdo~%s~%s~%s" % (name, profile, fmt)))]
            for fmt in SHARE_FORMATS]
    rows.append(_back_row(user_id, ("u_kah~%s~%s" % (name, addr)) if addr else ("u_share~%s" % name)))
    pick = _tf(user_id, "share_pick_format_fmt", esc(profile_title(user_id, profile)))
    if host:
        pick = "%s\n%s" % (_tf(user_id, "key_caption_addr_fmt", esc(host)), pick)
    text = "<b>%s</b>\n\n%s\n\n%s" % (_tf(user_id, "share_title_fmt", esc(name)), pick, _t(user_id, "share_hint"))
    if await safe_edit_message(query, text, reply_markup=InlineKeyboardMarkup(rows)):
        _rearm_callback(context, query, "u_shdo~")


@_once_callback
async def cb_user_share_do(update: Update, context: ContextTypes.DEFAULT_TYPE, attempt) -> None:
    """u_shdo~<name>~<profile>~<fmt>[~<addr>]: поднять раздачу и отдать адрес отдельным сообщением.

    С <addr> мост получает `--endpoint` (имя файла то же, что без адреса: anna-2_0.conf); отказ ядра по
    адресу возвращает к экрану адресов со словами ядра сверху.
    """
    query = update.callback_query
    user_id = _uid(update)
    parts = str(query.data).split("~")
    if len(parts) not in (4, 5) or not valid_name(parts[1]) or not valid_profile(parts[2]) \
            or not valid_share_format(parts[3]) or (len(parts) == 5 and not KEY_ADDR_RE.match(parts[4])):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    name, profile, fmt = parts[1], parts[2], parts[3]
    addr = parts[4] if len(parts) == 5 else ""
    host = ""
    back = "u_view~%s" % name
    if addr:
        edge, choice = await resolve_key_addr(addr)
        if choice is None:
            await show_key_addr_miss(query, user_id, name, edge)
            return
        host = str(choice.get("host") or "")
        back = "u_kah~%s~%s" % (name, addr)
    await query.answer()
    if await _action_busy(query, user_id, back):
        return
    await safe_edit_message(query, "⏳ " + _t(user_id, "share_creating"), reply_markup=None)
    r = await _callback_mutate(attempt, "share-create", who=user_id, name=name, profile=profile, format=fmt, endpoint=host or None)
    if not bridge_ok(r):
        if host and str(r.get("code") or "") in KEY_ADDR_ERRORS:
            await show_key_addr_screen(query, user_id, name, note="❌ " + key_addr_error_text(user_id, r))
        elif str(r.get("code") or "") == "no_private_key":
            # Профиль выбран на экране, нарисованном до подхвата: слова ядра и два выхода вместо тупика
            text, markup = imported_view(user_id, name, [profile], head=fail_text(user_id, r))
            await safe_edit_message(query, text, reply_markup=markup)
        elif str(r.get("code") or "") == "user_disabled":
            # Выключили, пока экран был открыт (или путь «ключ на другой адрес»): свои слова, без кода ядра
            await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_tf(user_id, "share_title_fmt", esc(name)),
                                                                _t(user_id, "share_user_disabled")),
                                    reply_markup=back_kb(user_id, "u_view~%s" % name))
        elif str(r.get("code") or "") == "share_limit":
            # Одновременных раздач уже предел: ядро велит снять лишние в «Активных раздачах» (T19),
            # а они в другом разделе («Обслуживание») — кнопка ведёт туда сразу, без поиска по меню.
            rows = [[btn(_t(user_id, "share_list_btn"), "sh_list")], _back_row(user_id, back)]
            await safe_edit_message(query, fail_text(user_id, r), reply_markup=InlineKeyboardMarkup(rows))
        else:
            await show_error(query, user_id, r, back)
        return
    share_id = str(r.get("id") or "")
    # В лог — только id: url и path в ответе секретные (docs/SHARE.md §6 п.4). Адрес сервера секретом не является.
    logger.info("share %s created for user %s (profile %s, format %s%s)", share_id or "?", name, profile, fmt,
                (", endpoint %s" % host) if host else "")
    ttl = max(60, int(r.get("ttl") or 300))
    rows = [[btn(_t(user_id, "share_revoke_btn"), "sh_rev~%s" % share_id)]] if valid_share_id(share_id) else []
    sent = await query.message.reply_text(share_link_text(user_id, r), parse_mode="HTML",
                                          disable_web_page_preview=True,
                                          reply_markup=InlineKeyboardMarkup(rows) if rows else None)
    if sent is not None:
        spawn_task(_share_delete_later(sent, ttl, share_id or "?"))
    await safe_edit_message(query, "✅ " + _t(user_id, "share_ready"),
                            reply_markup=back_kb(user_id, "u_view~%s" % name))


async def cb_share_revoke(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """sh_rev~<id>: снять раздачу и убрать из чата сообщение с адресом.

    sh_rev~<id>~l — та же кнопка на экране «Активные раздачи»: там сообщение —
    сам список (меню), а не адрес. Раньше оно удалялось целиком, и человек
    оставался без экрана, а сообщение с адресом в чате оставалось как было.
    """
    query = update.callback_query
    user_id = _uid(update)
    parts = str(query.data).split("~")
    sid = parts[1] if len(parts) > 1 else ""
    from_list = len(parts) == 3 and parts[2] == "l"
    if not valid_share_id(sid) or (len(parts) > 2 and not from_list):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    if await _action_busy(query, user_id, "sh_list"):
        return
    r = await mutate("share-revoke", who=user_id, id=sid)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "sh_list")
        return
    logger.info("share %s revoked", sid)
    if from_list:
        await dispatch_callback_data(update, context, "sh_list")
        return
    # Сообщение с адресом больше не нужно: секрет мёртв, а пересылать его всё
    # равно будут. Не вышло удалить (прошло 48 часов) — затираем текстом.
    try:
        await query.message.delete()
    except Exception:  # noqa: BLE001
        await safe_edit_message(query, "✅ " + _tf(user_id, "share_revoked_fmt", esc(sid)),
                                reply_markup=back_kb(user_id, "sh_list"))


def share_list_text(user_id: Optional[int], shares: List[Dict[str, Any]]) -> str:
    """Список активных раздач БЕЗ секретной части адреса (её мост и не отдаёт)."""
    lines = ["<b>%s</b>" % _t(user_id, "share_list_title"), ""]
    if not shares:
        lines.append("<i>%s</i>" % _t(user_id, "share_list_none"))
        return "\n".join(lines)
    for s in shares:
        left = max(0, int(s.get("seconds_left") or 0))
        lines.append("<code>%s</code> · %s · %s" % (esc(s.get("id") or "?"), esc(s.get("name") or "?"),
                                                    esc(s.get("file_name") or "?")))
        lines.append("   %s" % _tf(user_id, "share_list_item_fmt", left // 60 if left >= 60 else 1,
                                   esc(s.get("downloads") or 0)))
    lines.append("")
    lines.append(_t(user_id, "share_list_hint"))
    return "\n".join(lines)


async def cb_share_list(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """sh_list: активные раздачи — снять любую, пока она не истекла сама."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    r = await run_bot_action("share-list", timeout=60)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "sec_maint")
        return
    shares = [s for s in (r.get("shares") or []) if isinstance(s, dict) and valid_share_id(str(s.get("id") or ""))]
    # «~l»: кнопка стоит на экране списка — после снятия перерисовать список, а не удалять сообщение
    rows = [[btn(_tf(user_id, "share_revoke_one_fmt", str(s.get("id"))), "sh_rev~%s~l" % s.get("id"))] for s in shares]
    if len(shares) > 1:
        rows.append([btn(_t(user_id, "share_revoke_all"), "sh_revall")])
    rows.append([btn(_t(user_id, "btn_refresh"), "sh_list"), btn(_t(user_id, "btn_back"), "sec_maint")])
    await safe_edit_message(query, share_list_text(user_id, shares), reply_markup=InlineKeyboardMarkup(rows))


async def cb_share_revoke_all(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """sh_revall[_do]: снять все раздачи разом. Сперва вопрос — действие помечено
    разрушительным в actions.json, и панель его уже спрашивает; молчаливая кнопка
    рядом со списком гасила все ссылки одним промахом пальца."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    if not str(query.data).endswith("_do"):
        rows = [[btn(_t(user_id, "btn_confirm"), "sh_revall_do")], _back_row(user_id, "sh_list")]
        await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "share_revoke_all"),
                                                          _t(user_id, "share_revoke_all_confirm")),
                                reply_markup=InlineKeyboardMarkup(rows))
        return
    if await _action_busy(query, user_id, "sh_list"):
        return
    r = await mutate("share-revoke-all", who=user_id)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "sh_list")
        return
    await safe_edit_message(query, "✅ " + _tf(user_id, "share_revoke_all_done_fmt", esc(r.get("revoked") or 0)),
                            reply_markup=back_kb(user_id, "sh_list"))


# ── Страница подключения и зеркало сборок (docs/CLIENTS.md §10) ─────────────
# Всё делает ядро (page-*, mirror-*, clients-list); бот рисует экраны и задаёт
# вопросы. Адрес страницы равен ключу: он уходит отдельным сообщением (с QR,
# без превью ссылки), появляется только по явному действию — page-create и
# page-url — и не пишется в лог бота: туда идёт только id страницы.

def ts_human(ts: Any) -> str:
    """2026-09-18T18:41:07Z → «2026-09-18 18:41:07 UTC», как срок в карточке пользователя."""
    ts = str(ts or "").strip()
    return (ts.replace("T", " ").rstrip("Z") + " UTC") if ts else "—"


async def qr_png(text: str) -> Optional[bytes]:
    """PNG с QR текста через qrencode; нет его — None, и адрес идёт только текстом.

    Текст подаётся через stdin, а не аргументом: в argv он был бы виден в `ps`
    любому процессу на сервере, а здесь это секретный адрес.
    """
    exe = shutil.which("qrencode")
    if not exe or not text:
        return None
    try:
        proc = await asyncio.create_subprocess_exec(
            exe, "-r", "/dev/stdin", "-o", "-", "-t", "PNG", "-m", "2", "-s", "6",
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        out, _ = await asyncio.wait_for(proc.communicate(text.encode("utf-8")), timeout=20)
    except (OSError, ValueError, asyncio.TimeoutError):
        return None
    if proc.returncode != 0 or not out.startswith(b"\x89PNG"):
        return None
    return out


def page_state_text(user_id: Optional[int], rec: Dict[str, Any]) -> str:
    """«бессрочно» или «до <дата>» — одна мера для списка, карточки и сообщения с адресом."""
    if rec.get("forever"):
        return _t(user_id, "never")
    return _tf(user_id, "pg_until_fmt", ts_human(rec.get("expires")))


def page_records(r: Dict[str, Any]) -> List[Dict[str, Any]]:
    """pages[] из ответа page-list — только записи с id по форме: мусор в callback_data не пускаем."""
    return [p for p in (r.get("pages") or []) if isinstance(p, dict) and valid_page_id(str(p.get("id") or ""))]


def page_imported_lines(user_id: Optional[int], profiles: List[str]) -> List[str]:
    """Строки про профили страницы с ключом из приложения Amnezia: ключа там пока нет, человек
    видит пояснение, а после «Привязать старый ключ» ключ появится на той же странице сам."""
    return ["<i>%s</i>" % _tf(user_id, "pg_imported_fmt", esc(profile_name(user_id, p))) for p in profiles]


async def page_imported(rec: Dict[str, Any]) -> List[str]:
    """Профили страницы (по записи page-*), ключ которых выдан в приложении Amnezia.

    page-create сам кладёт их в `imported_profiles`. Для остального (page-url, карточка
    и список страниц) — по ТЕКУЩЕМУ user-show: страница берёт ключи у моста при каждом
    показе, и после «Привязать старый ключ» строка пропадает, пересоздавать страницу не
    нужно. Мост не ответил — строк нет: хуже сорвать выдачу адреса, чем промолчать.
    """
    profiles = [str(p) for p in (rec.get("profiles") or []) if valid_profile(str(p))]
    told = rec.get("imported_profiles")
    if isinstance(told, list):
        return [p for p in profiles if p in [str(x) for x in told]]
    owner = str(rec.get("user") or "")
    if not valid_name(owner) or not profiles:
        return []
    _, user = await _fetch_user(owner)
    if user is None:
        return []
    from_app = imported_profiles(user)
    return [p for p in profiles if p in from_app]


def page_link_text(user_id: Optional[int], r: Dict[str, Any], from_app: Optional[List[str]] = None) -> str:
    """Сообщение с адресом: адрес, срок, какие ключи на странице, предупреждение (у бессрочной — громче).

    from_app — профили страницы с ключом из приложения Amnezia: «ключи на странице: awg2, awg3»
    без оговорки обещало бы ключ, которого там пока нет."""
    forever = bool(r.get("forever"))
    lines = ["<b>%s</b>" % _tf(user_id, "pg_title_fmt", esc(r.get("user") or r.get("id") or "")), ""]
    lines.append("<code>%s</code>" % esc(r.get("url") or ""))
    lines.append("")
    if forever:
        lines.append(_t(user_id, "pg_link_forever"))
    else:
        lines.append(_tf(user_id, "pg_link_until_fmt", esc(ts_human(r.get("expires")))))
    profiles = r.get("profiles")
    if isinstance(profiles, list) and profiles:
        lines.append(_tf(user_id, "pg_link_profiles_fmt", esc(profile_names(user_id, profiles))))
    lines.extend(page_imported_lines(user_id, from_app or []))
    lines.append("")
    lines.append(_t(user_id, "pg_link_forever_warn" if forever else "pg_link_is_key"))
    # Страница отдаёт и адрес подписки (вкладка «Подписка»): отзыв страницы гасит его, только если перевыпустить и
    # подписку (B2-2/A2-4). created — подписку завела эта страница.
    sub = str(r.get("subscription") or "")
    if sub in ("created", "exists"):
        lines.append(_t(user_id, "pg_link_sub_created" if sub == "created" else "pg_link_sub_exists"))
    return "\n".join(lines)


PAGE_CAPTION_MAX = 1000   # подпись к фото в Telegram — 1024 знака


async def send_page_link(message, user_id: Optional[int], r: Dict[str, Any]) -> bool:
    """Адрес страницы отдельным сообщением: QR картинкой с подписью, без qrencode — текстом.

    Превью ссылки не бывает ни у фото, ни у текста с disable_web_page_preview:
    иначе Telegram сходил бы по адресу сам, и страница засчитала бы открытие.
    """
    text = page_link_text(user_id, r, await page_imported(r))
    pid = str(r.get("id") or "")
    markup = InlineKeyboardMarkup([[btn(_t(user_id, "pg_revoke_btn"), "pg_rev~%s" % pid)]]) if valid_page_id(pid) else None
    png = await qr_png(str(r.get("url") or ""))
    try:
        if png is not None and len(text) <= PAGE_CAPTION_MAX:
            await message.reply_photo(photo=io.BytesIO(png), caption=text, parse_mode="HTML", reply_markup=markup)
        else:
            await message.reply_text(text, parse_mode="HTML", disable_web_page_preview=True, reply_markup=markup)
            if png is not None:
                await message.reply_photo(photo=io.BytesIO(png), caption=_t(user_id, "pg_qr_hint"))
    except TelegramError as e:
        # Что делать дальше, решает вызывающий: страница уже создана, и второй
        # раз создавать её нельзя — только отправить адрес ещё раз (page-url).
        logger.warning("page %s: address delivery failed: %s", pid or "?", e)
        return False
    return True


def _page_send_failed_view(user_id: Optional[int], pid: str, back_to: str) -> Tuple[str, "InlineKeyboardMarkup"]:
    """Адрес не ушёл (сеть Telegram): вместо ✅ — «Отправить ссылку ещё раз» и «Назад»."""
    rows = []
    if valid_page_id(pid):
        rows.append([btn(_t(user_id, "pg_url_again_btn"), "pg_url~%s" % pid)])
    rows.append(_back_row(user_id, back_to))
    return "❌ " + _t(user_id, "pg_send_failed"), InlineKeyboardMarkup(rows)


def _page_id_from_data(data: str, prefix: str) -> str:
    rest = data[len(prefix):] if data.startswith(prefix) else ""
    pid = rest.split("~", 1)[0]
    return pid if valid_page_id(pid) else ""


async def _reply_or_edit(target, edit: bool, text: str, markup):
    """Экран по кнопке правится на месте, ответ на текст — новым сообщением (как _apply_user_quota).

    Возвращает отправленное сообщение (edit=False) — его можно поправить, если
    следующий шаг сорвётся; при правке экрана вернуть нечего (None).
    """
    if edit:
        await safe_edit_message(target, text, reply_markup=markup)
        return None
    return await target.reply_text(text, parse_mode="HTML", reply_markup=markup, disable_web_page_preview=True)


async def _replace_status(target, edit: bool, status_msg, text: str, markup) -> None:
    """Заменить статус («адрес следующим сообщением») на итог: экран — правкой,
    отправленное сообщение — edit_text, а если его уже не поправить — новым."""
    if edit:
        await safe_edit_message(target, text, reply_markup=markup)
        return
    try:
        await status_msg.edit_text(text, parse_mode="HTML", reply_markup=markup)
    except Exception:  # noqa: BLE001 — статус мог быть удалён или не иметь текста
        await target.reply_text(text, parse_mode="HTML", reply_markup=markup)


def _page_need_domain_view(user_id: Optional[int], name: str) -> Tuple[str, "InlineKeyboardMarkup"]:
    """Режим без домена с настоящим сертификатом: страницу открыть негде — говорим
    это словами и оставляем прежний путь, ссылку на файл (она работает везде)."""
    rows = [[btn(_t(user_id, "user_share"), "u_share~%s" % name)], _back_row(user_id, "u_view~%s" % name)]
    text = "<b>%s</b>\n\n%s" % (_tf(user_id, "pg_title_fmt", esc(name)), _t(user_id, "pg_need_domain"))
    return text, InlineKeyboardMarkup(rows)


async def cb_user_page(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """u_page~<name>: срок страницы кнопками; в Lite без сайта — сразу отказ словами."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    name = _name_from_data(query.data, "u_page~")
    if not name:
        await show_bad_input(query, user_id, "menu_users")
        return
    status = await get_status()
    # Режим без сайта известен заранее — не заставляем выбирать срок ради отказа.
    # Остальное (домен есть, а сертификат самоподписанный) решает ядро при создании.
    if bridge_ok(status) and str(status.get("mode") or "") == "lite":
        text, markup = _page_need_domain_view(user_id, name)
        await safe_edit_message(query, text, reply_markup=markup)
        return
    r, user = await _fetch_user(name)
    if user is None:
        await show_error(query, user_id, r, "menu_users")
        return
    if user.get("enabled") is False:
        # Выключенному новую страницу ядро не создаст (user_disabled) — срок не предлагаем. Но
        # созданные раньше живут («доступ приостановлен», после включения — снова ключи), и
        # снять их, кроме как отсюда, нечем (UI-4): список — всегда.
        rows = [[btn(_t(user_id, "pg_list_btn"), "pg_list~%s" % name)], _back_row(user_id, "u_view~%s" % name)]
        await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_tf(user_id, "pg_title_fmt", esc(name)),
                                                            _t(user_id, "pg_user_disabled")),
                                reply_markup=InlineKeyboardMarkup(rows))
        return
    from_app = imported_profiles(user)
    if from_app and not peers_with_key(user):
        # Все ключи человека — в приложении Amnezia: новая страница показала бы одни пояснения,
        # и создавать её не предлагаем — правда и два выхода. Но страницы, созданные раньше
        # (живые, с пояснением вместо ключа), должно быть видно и можно отозвать (UI-4).
        text, markup = imported_view(user_id, name, from_app,
                                     extra_rows=[[btn(_t(user_id, "pg_list_btn"), "pg_list~%s" % name)]])
        await safe_edit_message(query, text, reply_markup=markup)
        return
    buttons = [btn(_t(user_id, PAGE_TTL_KEYS[ttl]), "pg_ttl~%s~%s" % (name, ttl)) for ttl in PAGE_TTL_PRESETS]
    buttons.append(btn(_t(user_id, "pg_ttl_custom"), "pg_ttl~%s~custom" % name))
    rows = [buttons[0:2], buttons[2:4], buttons[4:6],
            [btn(_t(user_id, "pg_list_btn"), "pg_list~%s" % name)],
            _back_row(user_id, "u_view~%s" % name)]
    lines = ["<b>%s</b>" % _tf(user_id, "pg_title_fmt", esc(name)), "", _t(user_id, "pg_intro")]
    # Профиль с ключом из приложения попадёт на страницу пояснением, а не ключом — сказать до создания
    for line in page_imported_lines(user_id, from_app):
        lines.extend(["", line])
    await safe_edit_message(query, "\n".join(lines), reply_markup=InlineKeyboardMarkup(rows))


async def cb_page_ttl(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """pg_ttl~<name>~<срок>: пресет — создаём сразу; custom — ждём срок текстом («12 ч» / «12h», parse_page_ttl)."""
    query = update.callback_query
    user_id = _uid(update)
    parts = str(query.data).split("~")
    if len(parts) != 3 or not valid_name(parts[1]) or not (parts[2] == "custom" or valid_page_ttl(parts[2])):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    name, ttl = parts[1], parts[2]
    await query.answer()
    if ttl == "custom":
        flow_set(context, "page_ttl", name=name)
        await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_tf(user_id, "pg_title_fmt", esc(name)), _t(user_id, "pg_ask_custom")),
                                reply_markup=cancel_kb(user_id, "u_page~%s" % name))
        return
    if await _action_busy(query, user_id, "u_page~%s" % name):
        return
    await safe_edit_message(query, "⏳ " + _t(user_id, "pg_creating"), reply_markup=None)
    await _page_create(query, user_id, name, ttl, edit=True)


async def _page_create(target, user_id: Optional[int], name: str, ttl: str, edit: bool) -> None:
    """page-create → адрес отдельным сообщением; экран говорит, куда смотреть.

    target — CallbackQuery (edit=True) или Message (edit=False, ответ на текст).
    """
    if not edit:
        await _queued_notice(target, user_id)
    r = await mutate("page-create", who=user_id, name=name, ttl=ttl)
    if not bridge_ok(r):
        code = str(r.get("code") or "")
        if code == "pages_need_domain":
            text, markup = _page_need_domain_view(user_id, name)
        elif code == "user_disabled":
            # Своими словами, без глагола CLI из ответа ядра: рядом есть кнопка «Включить».
            text = "<b>%s</b>\n\n%s" % (_tf(user_id, "pg_title_fmt", esc(name)), _t(user_id, "pg_user_disabled"))
            markup = back_kb(user_id, "u_view~%s" % name)
        elif code == "no_private_key":
            # Все ключи человека — в приложении Amnezia, и ядро страницу без единого ключа не создаёт:
            # его слова целиком и два выхода по каждому такому профилю.
            _, user = await _fetch_user(name)
            from_app = imported_profiles(user) if user else []
            if from_app:
                text, markup = imported_view(user_id, name, from_app, head=fail_text(user_id, r))
            else:
                text, markup = fail_text(user_id, r), back_kb(user_id, "u_view~%s" % name)
        else:
            text = fail_text(user_id, r)
            markup = fail_markup(user_id, r, "u_page~%s" % name, retry_data(target) if edit else None)
        await _reply_or_edit(target, edit, text, markup)
        return
    # В лог — только id: адрес в ответе секретный.
    pid = str(r.get("id") or "")
    logger.info("page %s created for user %s (ttl %s)", pid or "?", name, ttl)
    message = target.message if edit else target
    # Статус — до адреса: «адрес следующим сообщением» обязан стоять выше самого
    # адреса и в ответе на текст, а не только при правке экрана.
    status_msg = await _reply_or_edit(target, edit, "✅ " + _t(user_id, "pg_ready"), back_kb(user_id, "u_view~%s" % name))
    if not await send_page_link(message, user_id, r):
        text, markup = _page_send_failed_view(user_id, pid, "u_view~%s" % name)
        await _replace_status(target, edit, status_msg, text, markup)


async def cb_page_list(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """pg_list~<name>: страницы пользователя — срок, открытия, ключи; адресов здесь нет."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    name = _name_from_data(query.data, "pg_list~")
    if not name:
        await show_bad_input(query, user_id, "menu_users")
        return
    r = await run_bot_action("page-list", timeout=60, name=name)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "u_view~%s" % name)
        return
    pages = page_records(r)
    lines = ["<b>%s</b>" % _tf(user_id, "pg_list_title_fmt", esc(name)), ""]
    if not pages:
        lines.append("<i>%s</i>" % _t(user_id, "pg_list_none"))
    for p in pages:
        lines.append(_tf(user_id, "pg_row_fmt", esc(p["id"]), esc(page_state_text(user_id, p)), esc(p.get("visits") or 0),
                         esc(profile_names(user_id, p.get("profiles")) or "—")))
    # «Ключи: awg2, awg3» у страницы, где awg2 — ключ из приложения Amnezia, обещал бы ключ,
    # которого там пока нет: одна оговорка на профиль под списком.
    on_pages = sorted({str(x) for p in pages for x in (p.get("profiles") or [])})
    for line in page_imported_lines(user_id, await page_imported({"user": name, "profiles": on_pages})):
        lines.extend(["", line])
    lines.append("")
    lines.append(_t(user_id, "pg_list_hint"))
    rows = [[btn("%s · %s" % (p["id"], page_state_text(user_id, p)), "pg_card~%s" % p["id"])] for p in pages]
    if len(pages) >= 2:
        # Все страницы человека разом (L-10); у единственной есть свой «Отозвать» в её карточке
        rows.append([btn(_t(user_id, "pg_revoke_all_btn"), "pg_revall~%s" % name)])
    rows.append([btn(_t(user_id, "user_page"), "u_page~%s" % name)])
    rows.append([btn(_t(user_id, "btn_refresh"), "pg_list~%s" % name), btn(_t(user_id, "btn_back"), "u_view~%s" % name)])
    await safe_edit_message(query, "\n".join(lines), reply_markup=InlineKeyboardMarkup(rows))


def page_card_text(user_id: Optional[int], rec: Dict[str, Any], from_app: Optional[List[str]] = None) -> str:
    lines = ["<b>%s</b>" % _tf(user_id, "pg_card_title_fmt", esc(rec.get("id"))), ""]
    lines.append(_tf(user_id, "pg_card_user_fmt", esc(rec.get("user") or "—")))
    lines.append(_tf(user_id, "pg_card_created_fmt", esc(ts_human(rec.get("created")))))
    if rec.get("forever"):
        lines.append(_t(user_id, "pg_card_forever"))
    else:
        lines.append(_tf(user_id, "pg_card_expires_fmt", esc(ts_human(rec.get("expires")))))
    lines.append(_tf(user_id, "pg_card_visits_fmt", esc(rec.get("visits") or 0), esc(ts_human(rec.get("last_visit")))))
    lines.append(_tf(user_id, "pg_card_profiles_fmt", esc(profile_names(user_id, rec.get("profiles")) or "—")))
    lines.extend(page_imported_lines(user_id, from_app or []))
    lines.append(_t(user_id, "pg_card_mirror_on" if rec.get("mirror") else "pg_card_mirror_off"))
    lines.append("")
    lines.append(_t(user_id, "pg_card_hint"))
    return "\n".join(lines)


def page_card_keyboard(user_id: Optional[int], rec: Dict[str, Any]) -> "InlineKeyboardMarkup":
    pid = str(rec.get("id") or "")
    owner = str(rec.get("user") or "")
    # Возврат — к страницам того же человека; запись без владельца ведёт в список пользователей.
    rows = [[btn(_t(user_id, "pg_url_again_btn"), "pg_url~%s" % pid)],
            [btn(_t(user_id, "pg_revoke_btn"), "pg_rev~%s" % pid)],
            [btn(_t(user_id, "btn_refresh"), "pg_card~%s" % pid),
             btn(_t(user_id, "btn_back"), "pg_list~%s" % owner if valid_name(owner) else "menu_users")]]
    return InlineKeyboardMarkup(rows)


async def _find_page(pid: str) -> Tuple[Dict[str, Any], Optional[Dict[str, Any]]]:
    """Запись страницы по id из page-list (адреса там нет — и не надо)."""
    r = await run_bot_action("page-list", timeout=60)
    if not bridge_ok(r):
        return r, None
    return r, next((p for p in page_records(r) if p.get("id") == pid), None)


async def cb_page_card(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """pg_card~<id>: карточка страницы; адрес — только по кнопке."""
    query = update.callback_query
    user_id = _uid(update)
    pid = _page_id_from_data(str(query.data), "pg_card~")
    if not pid:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    r, rec = await _find_page(pid)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "menu_users")
        return
    if rec is None:
        await safe_edit_message(query, "❌ " + _tf(user_id, "pg_not_found_fmt", esc(pid)), reply_markup=back_kb(user_id, "menu_users"))
        return
    await safe_edit_message(query, page_card_text(user_id, rec, await page_imported(rec)),
                            reply_markup=page_card_keyboard(user_id, rec))


async def cb_page_url(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """pg_url~<id>: адрес ещё раз — отдельным сообщением с QR, мимо лога."""
    query = update.callback_query
    user_id = _uid(update)
    pid = _page_id_from_data(str(query.data), "pg_url~")
    if not pid:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    if await _action_busy(query, user_id, "pg_card~%s" % pid):
        return
    r = await mutate("page-url", who=user_id, id=pid)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "pg_card~%s" % pid)
        return
    # Срока и ключей в ответе page-url нет — берём из записи списка, чтобы
    # сообщение было тем же, что при выдаче.
    _, rec = await _find_page(pid)
    merged = dict(rec or {})
    merged.update({k: v for k, v in r.items() if k in ("id", "url")})
    logger.info("page %s: address sent again", pid)
    await safe_edit_message(query, "✅ " + _t(user_id, "pg_ready"), reply_markup=back_kb(user_id, "pg_card~%s" % pid))
    if not await send_page_link(query.message, user_id, merged):
        text, markup = _page_send_failed_view(user_id, pid, "pg_card~%s" % pid)
        await safe_edit_message(query, text, reply_markup=markup)


async def _page_user_sub(name: str, psub: str) -> Tuple[bool, Optional[List[Any]]]:
    """Есть ли у пользователя подписка СЕЙЧАС (R-1) и её линии: страница отдаёт её адрес на лету, а subscription в
    записи страницы — снимок при создании (у старых страниц его нет, у «off» подписку могли завести позже). sub-list
    не ответил — по снимку, линии неизвестны (None)."""
    if valid_name(name):
        r = await run_bot_action("sub-list", timeout=60, name=name)
        if bridge_ok(r):
            rec = sub_record(r, name)
            return rec is not None, (list(rec.get("lines") or []) if rec is not None else [])
    return psub in ("created", "exists"), None


def page_revoke_key_profiles(user: Optional[Dict[str, Any]], page_profiles: Any,
                             sub_lines: Optional[List[Any]]) -> Tuple[List[str], List[str]]:
    """Чьи ключи перевыпустит отзыв страницы с --keys on — правило ядра ga_pages_revoke_key_profiles (Н-1): профили
    страницы с ключом на сервере; вместе с подпиской — ещё профили её линий с ключом на сервере, которых нет среди
    профилей страницы. Карточки нет (user-show не ответил) — профили страницы как есть."""
    peers = (user or {}).get("peers") if isinstance((user or {}).get("peers"), dict) else {}

    def keyed(p: Any) -> bool:
        if not isinstance(p, str) or not valid_name(p):
            return False
        return user is None or (p in peers and peer_has_key(peers.get(p)))
    page: List[str] = []
    for p in page_profiles if isinstance(page_profiles, list) else []:
        if keyed(p) and p not in page:
            page.append(p)
    sub: List[str] = []
    for line in sub_lines or []:
        p = line.get("profile") if isinstance(line, dict) and line.get("has_key") is True else None
        if keyed(p) and p not in page and p not in sub:
            sub.append(p)
    return page, sub


async def cb_page_revoke(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """pg_rev~<id> → вопрос; pg_rev_do~<id> → page-revoke; pg_rev_dos~<id> → page-revoke --sub on;
    pg_rev_dok~<id> / pg_rev_dosk~<id> — то же с --keys on (B3-3).

    Ссылка могла быть уже отправлена человеку, и отзыв гасит её у него в
    руках — поэтому спрашиваем, как у раздач. Страница отдавала и адрес подписки
    (B2-2/A2-4) — две кнопки: с перевыпуском подписки (первой, если подписку
    завела эта страница) и только страницу.
    """
    query = update.callback_query
    user_id = _uid(update)
    data = str(query.data)
    prefix = next((p for p in ("pg_rev_dosk~", "pg_rev_dok~", "pg_rev_dos~", "pg_rev_do~") if data.startswith(p)), "pg_rev~")
    with_sub = prefix in ("pg_rev_dosk~", "pg_rev_dos~")
    with_keys = prefix in ("pg_rev_dosk~", "pg_rev_dok~")
    do = prefix != "pg_rev~"
    pid = _page_id_from_data(data, prefix)
    if not pid:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    if not do:
        _, rec = await _find_page(pid)
        psub = str((rec or {}).get("subscription") or "")
        text = "<b>%s</b>\n\n%s" % (_t(user_id, "pg_revoke_btn"), _tf(user_id, "pg_revoke_confirm_fmt", esc(pid)))
        owner = str((rec or {}).get("user") or "")
        has_sub, sub_lines = await _page_user_sub(owner, psub)
        if has_sub:
            text += "\n\n" + _t(user_id, "pg_revoke_sub_note")
            both = [btn(_t(user_id, "pg_revoke_with_sub_btn"), "pg_rev_dos~%s" % pid)]
            only = [btn(_t(user_id, "pg_revoke_page_only_btn"), "pg_rev_do~%s" % pid)]
            rows = [both, only] if psub == "created" else [only, both]
        else:
            rows = [[btn(_t(user_id, "btn_confirm"), "pg_rev_do~%s" % pid)]]
        # B3-3: ключ, который страница уже отдала, отзыв не гасит. Открывали — сколько раз и кнопки с перевыпуском
        # ключей (последними: они отключат и устройства самого пользователя до нового ключа). Профили названы те же, что
        # перевыпустит ядро: страницы, а вместе с подпиской — и её линий (Н-1). Перевыпускать нечего — кнопок нет.
        try:
            visits = int((rec or {}).get("visits") or 0)
        except (TypeError, ValueError):
            visits = 0
        if visits > 0:
            user = None
            if valid_name(owner):
                _, user = await _fetch_user(owner)
            kpage, ksub = page_revoke_key_profiles(user, (rec or {}).get("profiles"), sub_lines if has_sub else [])
            # П-3: sub-list не ответил — линии подписки неизвестны, а ядро при sub=on keys=on перевыпустит и их ключи:
            # кнопку «с подпиской и ключами» оставляем и говорим условно (ничего не нашлось — итог скажет честно).
            sub_unknown = has_sub and sub_lines is None
            if kpage or ksub or sub_unknown:
                # Общая строка не называет профили — их называют строки ниже, по фактическому набору.
                text += "\n\n" + _tf(user_id, "pg_revoke_keys_note_fmt", visits)
                if kpage:
                    text += "\n" + _tf(user_id, "pg_revoke_keys_page_fmt", esc(profile_names(user_id, kpage)))
                if has_sub and ksub:
                    text += "\n" + _tf(user_id, "pg_revoke_keys_sub_fmt", esc(profile_names(user_id, ksub)))
                elif sub_unknown:
                    text += "\n" + _t(user_id, "pg_revoke_keys_sub_unknown")
            if has_sub and (kpage or ksub or sub_unknown):
                rows.append([btn(_t(user_id, "pg_revoke_with_sub_keys_btn"), "pg_rev_dosk~%s" % pid)])
            if kpage:
                # Н-3: при подписке — и «только страница и ключи», как в панели и SSH
                rows.append([btn(_t(user_id, "pg_revoke_page_keys_btn" if has_sub else "pg_revoke_with_keys_btn"),
                                 "pg_rev_dok~%s" % pid)])
        rows.append(_back_row(user_id, "pg_card~%s" % pid))
        await safe_edit_message(query, text, reply_markup=InlineKeyboardMarkup(rows))
        return
    if await _action_busy(query, user_id, "pg_card~%s" % pid):
        return
    # Чья страница — узнаём до отзыва: после него записи в списке уже нет,
    # а вернуться надо к страницам того же человека.
    _, rec = await _find_page(pid)
    owner = str((rec or {}).get("user") or "")
    extra = {"keys": "on"} if with_keys else {}
    r = await mutate("page-revoke", who=user_id, id=pid, sub="on" if with_sub else "off", **extra)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "pg_card~%s" % pid)
        return
    logger.info("page %s revoked (subscription reissued: %s, keys reissued: %s)", pid, bool(with_sub and r.get("sub_rotated")),
                ",".join(str(p) for p in (r.get("keys_reissued") or []) if with_keys) or "-")
    text = "✅ " + _tf(user_id, "pg_revoked_fmt", esc(pid))
    if with_sub:
        # sub_present: false — подписки уже не было, перевыпускать нечего: не отказ (R-4). Старое ядро поля не знает —
        # без перевыпуска честнее предупредить.
        if r.get("sub_rotated"):
            text += "\n" + _t(user_id, "pg_revoked_sub")
        elif r.get("sub_present") is False:
            text += "\n" + _t(user_id, "pg_revoked_sub_none")
        else:
            text += "\n" + _t(user_id, "pg_revoked_sub_failed")
    if with_keys:
        done = [str(p) for p in (r.get("keys_reissued") or []) if isinstance(p, str)]
        failed = [str(p) for p in (r.get("keys_failed") or []) if isinstance(p, str)]
        if not isinstance(r.get("keys_reissued"), list):
            failed = failed or ["?"]       # старое ядро keys не знает — ключи не перевыпущены
        if done:
            text += "\n" + _tf(user_id, "pg_revoked_keys_fmt", esc(profile_names(user_id, done)))
        if failed:
            text += "\n" + _t(user_id, "pg_revoked_keys_failed")
        elif not done:
            text += "\n" + _t(user_id, "pg_revoked_keys_none")
    await safe_edit_message(query, text,
                            reply_markup=back_kb(user_id, "pg_list~%s" % owner if valid_name(owner) else "menu_users"))


async def cb_page_revoke_all(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """pg_revall~<name> → вопрос; pg_revall_do~<name> → page-revoke-all --name (L-10, сцена pages-revoke-all).

    Все страницы человека разом — например, когда ссылки разошлись по чатам: ключи не меняются, а
    каждый выданный адрес перестаёт открываться сразу. Действие разрушительное (actions.json), поэтому
    сначала вопрос с числом страниц, как у «Снять все» временных ссылок."""
    query = update.callback_query
    user_id = _uid(update)
    data = str(query.data)
    do = data.startswith("pg_revall_do~")
    name = _name_from_data(data, "pg_revall_do~" if do else "pg_revall~")
    if not name:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    if not do:
        r = await run_bot_action("page-list", timeout=60, name=name)
        if not bridge_ok(r):
            await show_error(query, user_id, r, "pg_list~%s" % name)
            return
        count = len(page_records(r))
        if not count:
            await safe_edit_message(query, "<i>%s</i>" % _t(user_id, "pg_list_none"),
                                    reply_markup=back_kb(user_id, "pg_list~%s" % name))
            return
        rows = [[btn(_t(user_id, "pg_revoke_all_do_btn"), "pg_revall_do~%s" % name)], _back_row(user_id, "pg_list~%s" % name)]
        await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_tf(user_id, "pg_revoke_all_title_fmt", esc(name)),
                                                            _tf(user_id, "pg_revoke_all_confirm_fmt", count)),
                                reply_markup=InlineKeyboardMarkup(rows))
        return
    if await _action_busy(query, user_id, "pg_list~%s" % name):
        return
    r = await mutate("page-revoke-all", who=user_id, name=name)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "pg_list~%s" % name)
        return
    try:
        revoked = int(r.get("revoked") or 0)
    except (TypeError, ValueError):
        revoked = 0
    logger.info("pages of user %s revoked: %s", name, revoked)
    await safe_edit_message(query, "✅ " + _tf(user_id, "pg_revoke_all_done_fmt", revoked),
                            reply_markup=back_kb(user_id, "u_view~%s" % name))


# ── Подписка: постоянная ссылка для Clash и роутеров (lib/subs.sh, docs/SUBSCRIPTION.md) ────
# Всё делает ядро (sub-*); бот рисует экран и задаёт вопросы. Адреса подписки равны ключам: они уходят отдельным
# сообщением без превью ссылок (Telegram сходил бы по адресу сам) и только по явному действию — создать, «Адреса»,
# перевыпустить; в лог бота — только имя человека. Перевыпуск и отзыв — фразой ROTATE <имя> / REVOKE <имя>.

def sub_record(r: Dict[str, Any], name: str) -> Optional[Dict[str, Any]]:
    """Запись подписки человека из ответа sub-list (адресов там нет — и не надо)."""
    for rec in r.get("subs") or []:
        if isinstance(rec, dict) and rec.get("name") == name:
            return rec
    return None


def sub_state_text(user_id: Optional[int], name: str, r: Dict[str, Any], rec: Optional[Dict[str, Any]]) -> str:
    """Экран подписки: что это, есть ли она, заборы и линии за ссылкой; адреса — только по кнопке."""
    lines = ["<b>%s</b>" % _tf(user_id, "sub_title_fmt", esc(name)), "", _t(user_id, "sub_intro"), ""]
    ready = r.get("domain_ready") is not False
    if rec is None:
        lines.append(_t(user_id, "sub_none"))
        if not ready:
            lines.extend(["", _t(user_id, "sub_need_domain")])
        return "\n".join(lines)
    lines.append(_tf(user_id, "sub_since_fmt", esc(ts_human(rec.get("created")))))
    if rec.get("rotated"):
        lines.append(_tf(user_id, "sub_rotated_fmt", esc(ts_human(rec.get("rotated")))))
    if str(rec.get("fetches") or "0").isdigit() and int(rec.get("fetches") or 0) > 0 and rec.get("last_fetch"):
        last = ts_human(rec.get("last_fetch")) + (" (%s)" % rec["last_client"] if rec.get("last_client") else "")
        lines.append(_tf(user_id, "sub_fetches_fmt", esc(rec.get("fetches")), esc(last)))
    else:
        lines.append(_t(user_id, "sub_never"))
    # Н-1: перевыпуск обнуляет счёт; сколько раз забирали прежний адрес — след утечки
    if str(rec.get("prev_fetches") or "0").isdigit() and int(rec.get("prev_fetches") or 0) > 0:
        if rec.get("prev_last_fetch"):
            lines.append(_tf(user_id, "sub_prev_fetches_fmt", esc(rec.get("prev_fetches")), esc(ts_human(rec.get("prev_last_fetch")))))
        else:
            lines.append(_tf(user_id, "sub_prev_fetches_n_fmt", esc(rec.get("prev_fetches"))))
    # Подписи — как у профилей везде: «AmneziaWG 3.1 (awg2)», при двух одинаковых линиях — с портом (DUP-LINE-01);
    # голого awg2 человек не узнает
    keyed = [profile_title_of_line(user_id, l.get("profile"), l.get("line")) for l in rec.get("lines") or []
             if isinstance(l, dict) and l.get("has_key")]
    keyless = [profile_title_of_line(user_id, l.get("profile"), l.get("line")) for l in rec.get("lines") or []
               if isinstance(l, dict) and not l.get("has_key")]
    lines.append(_tf(user_id, "sub_lines_fmt", esc(", ".join(keyed) or "—")))
    if keyless:
        lines.extend(["", "<i>%s</i>" % _tf(user_id, "sub_keyless_fmt", esc(", ".join(keyless)))])
    if rec.get("disabled"):
        lines.extend(["", "<i>%s</i>" % _t(user_id, "sub_user_off")])
    if not ready:
        lines.extend(["", "<i>%s</i>" % _t(user_id, "sub_paused")])
    return "\n".join(lines)


def sub_links_text(user_id: Optional[int], r: Dict[str, Any]) -> str:
    """Сообщение с адресами по форматам: кому какой (Clash — mihomo.yaml, роутер — .conf линии, приложение Amnezia —
    vpn://), интервал обновления и предупреждение, что адрес — ключ."""
    urls = [u for u in (r.get("urls") or []) if isinstance(u, dict) and str(u.get("url") or "").startswith("https://")]
    lines = ["<b>%s</b>" % _tf(user_id, "sub_title_fmt", esc(r.get("label") or r.get("name") or "")), ""]
    if not urls:
        lines.append(_t(user_id, "sub_paused" if r.get("paused") else "sub_no_keys"))
        return "\n".join(lines)
    def by_fmt(fmt: str) -> List[Dict[str, Any]]:
        return [u for u in urls if u.get("format") == fmt]
    lines.append(_t(user_id, "sub_for_mihomo"))
    lines.extend("<code>%s</code>" % esc(u["url"]) for u in by_fmt("mihomo"))
    lines.extend(["", _t(user_id, "sub_for_conf")])
    lines.extend("AmneziaWG %s: <code>%s</code>" % (esc(u.get("line")), esc(u["url"])) for u in by_fmt("conf"))
    # Совет «для роутера — AmneziaWG 2.0» ведёт в пустоту, когда 2.0 (и 1.x) за ссылкой нет (R4, DUP-LINE-01)
    conf_lines = {str(u.get("line") or "") for u in by_fmt("conf")}
    if conf_lines and not conf_lines & {"2.0", "1.0", "1.5"}:
        lines.append("<i>%s</i>" % _t(user_id, "sub_no20_note"))
    lines.extend(["", _t(user_id, "sub_for_vpn")])
    for u in by_fmt("vpn"):
        head = "AmneziaWG %s" % esc(u.get("line")) if u.get("line") else _t(user_id, "sub_all_lines")
        lines.append("%s: <code>%s</code>" % (head, esc(u["url"])))
    lines.extend(["", _tf(user_id, "sub_update_fmt", esc(r.get("update_interval") or 12))])
    if r.get("disabled"):
        lines.append("<i>%s</i>" % _t(user_id, "sub_user_off"))
    lines.append(_t(user_id, "sub_is_key"))
    return "\n".join(lines)


async def send_sub_links(message, user_id: Optional[int], r: Dict[str, Any]) -> bool:
    """Адреса подписки отдельным сообщением без превью, следом — QR профиля mihomo (FlClash и Clash Meta for Android
    его сканируют). False — Telegram не принял сообщение: вызывающий скажет «нажмите ещё раз»."""
    try:
        await message.reply_text(sub_links_text(user_id, r), parse_mode="HTML", disable_web_page_preview=True)
        main = next((str(u.get("url") or "") for u in r.get("urls") or []
                     if isinstance(u, dict) and u.get("format") == "mihomo"), "")
        png = await qr_png(main) if main.startswith("https://") else None
        if png is not None:
            await message.reply_photo(photo=io.BytesIO(png), caption=_t(user_id, "sub_qr_caption"))
    except TelegramError as e:
        logger.warning("subscription of %s: address delivery failed: %s", r.get("name") or "?", e)
        return False
    return True


# ── Подписка по клиенту: поле clients ответов sub-create, sub-show и sub-rotate ────
# Вместо списка адресов по форматам — выбор приложения, по группам «Обновляется сам» (приложение само забирает свежий
# ключ по подписке) и «Разово» (ключ по ссылке один раз); записи с одним app — одно приложение, у него — «Формат» по
# variant (AWG Manager). Экраны выбора и приложения адресов не несут и рисуются на месте, как остальные экраны бота; у
# приложения — те же способы, что в панели (решение владельца 04.10.2026): «QR-код» (по qr и qr_alt) и «Скопировать» (по
# copy), у нескольких линий — по линии. «Короткая ссылка» (items[].short_url) зарезервирована: ядро её пока не заполняет,
# кнопки нет. Значения уходят отдельными сообщениями без превью: QR адреса или ссылки «в приложение» — картинкой (sbq~),
# то, что вставляют (адрес, команда, ключ линии), — моноширинным текстом, чтобы скопировать долгим нажатием (sbc~); QR
# ключа линии — той же выдачей ключа, что в карточке (u_key~<имя>~<профиль>~qrvpn|qrconf), ключ текстом — тем же
# действием user-key. В callback_data — имя, id записи и номер пункта, адрес берётся заново через sub-show (выдача
# пишется в аудит); в лог — только имя и id. Нет поля clients (ядро старше) — прежнее сообщение с адресами.
SUB_CLIENT_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,23}$")
SUB_CLIENT_GROUPS = ("auto", "once")
SUB_CLIENT_GROUP_KEYS = {"auto": "sub_grp_auto", "once": "sub_grp_once"}
# Ссылка «в приложение» — своя схема приложения (flclash://, incy://, wg://); javascript:, data: и прочие — никогда.
SUB_DEEPLINK_RE = re.compile(r"^(?!(?:javascript|data|vbscript|file|about|blob):)[a-z][a-z0-9+.-]{1,31}://\S+\Z",
                             re.IGNORECASE)
# Пунктов записи в callback_data — одной цифрой (линий у человека не больше четырёх).
SUB_ITEMS_MAX = 10
SUB_DESKTOP = ("windows", "macos", "linux")
# Подписи картинок QR: адрес, ссылка «в приложение» (камерой телефона) и второй код — адрес для сканера приложения.
SUB_QR_CAPTIONS = {"url": "sub_qr_url_fmt", "deeplink": "sub_qr_camera_fmt", "alt": "sub_qr_scanner_fmt"}


def sub_clients(r: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Записи ответа в порядке групп (сначала «Обновляется сам»): только с id по форме (он едет в callback_data) и
    с пунктами, у которых адрес https; мусор ответа в сообщение не попадает. Нет поля (ядро старше) — пусто."""
    raw = r.get("clients")
    if not isinstance(raw, list):
        return []
    out = []
    for grp in SUB_CLIENT_GROUPS:
        for c in raw:
            if not isinstance(c, dict) or c.get("group") != grp or not SUB_CLIENT_ID_RE.match(str(c.get("id") or "")):
                continue
            items = [it for it in c.get("items") or []
                     if isinstance(it, dict) and str(it.get("url") or "").startswith("https://")]
            if items:
                out.append(dict(c, items=items[:SUB_ITEMS_MAX]))
    return out


def sub_apps(clients: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Приложения списка: записи с одним app — одно приложение (группа — у первой записи), его форматы — эти записи."""
    apps: List[Dict[str, Any]] = []
    for c in clients:
        key = str(c.get("app") or c.get("id"))
        app = next((a for a in apps if a["key"] == key), None)
        if app is None:
            apps.append({"key": key, "group": c.get("group"), "recommended": bool(c.get("recommended")), "variants": [c]})
        else:
            app["variants"].append(c)
            app["recommended"] = app["recommended"] or bool(c.get("recommended"))
    return apps


def sub_client_name(user_id: Optional[int], c: Dict[str, Any]) -> str:
    if get_user_lang(user_id) == "en" and c.get("name_en"):
        return str(c["name_en"])
    return str(c.get("name") or c.get("id") or "")


def sub_variant_name(user_id: Optional[int], c: Dict[str, Any]) -> str:
    """Подпись формата записи (variant: строка или {ru, en}); нет — имя приложения."""
    v = c.get("variant")
    if isinstance(v, dict):
        v = v.get(get_user_lang(user_id)) or v.get("ru") or v.get("en")
    return str(v or sub_client_name(user_id, c))


def sub_platforms_text(user_id: Optional[int], platforms: Any) -> str:
    """«Android, Windows, macOS» — те же слова, что в зеркале сборок; Apple TV — своей строкой."""
    names = []
    for p in platforms if isinstance(platforms, list) else []:
        p = str(p)
        names.append(_t(user_id, "sub_platform_tvos") if p == "tvos" else platform_label(user_id, p))
    return ", ".join(names)


def sub_client_hours(c: Dict[str, Any], r: Dict[str, Any]) -> int:
    """Как часто приложение «Обновляется сам» забирает подписку: 0 часов — интервал сервера (update_interval)."""
    for v in (c.get("update_hours"), r.get("update_interval")):
        try:
            if int(v) > 0:
                return int(v)
        except (TypeError, ValueError):
            pass
    return 12


def sub_client_hint(user_id: Optional[int], c: Dict[str, Any], r: Dict[str, Any]) -> str:
    """Подсказка «как добавить» на языке человека; {minutes} — интервал обновления в минутах."""
    hint = c.get("hint") if isinstance(c.get("hint"), dict) else {}
    text = str(hint.get(get_user_lang(user_id)) or hint.get("ru") or hint.get("en") or "")
    return text.replace("{minutes}", str(sub_client_hours(c, r) * 60))


def sub_item_label(user_id: Optional[int], it: Dict[str, Any]) -> str:
    line = str(it.get("line") or "")
    return "AmneziaWG %s" % line if line else _t(user_id, "sub_all_lines_short")


def sub_line_profile(r: Dict[str, Any], line: str) -> str:
    """Профиль человека с ключом на сервере, который подписка отдаёт по этой линии (lines ответа sub-*)."""
    for row in r.get("lines") or []:
        if isinstance(row, dict) and str(row.get("line") or "") == line and row.get("has_key") is not False \
                and valid_profile(str(row.get("profile") or "")):
            return str(row["profile"])
    return ""


def sub_item_qrs(it: Dict[str, Any]) -> List[Tuple[str, str]]:
    """Что рисовать картинкой QR: [(вид, текст)] — по qr адрес (только https) или ссылку «в приложение», по qr_alt "url" —
    ещё и адрес (incy: камерой телефона и сканером в приложении); ключ — не здесь, его выдаёт кнопка ключа карточки."""
    url = str(it.get("url") or "")
    out: List[Tuple[str, str]] = []
    if it.get("qr") == "url" and url.startswith("https://"):
        out.append(("url", url))
    elif it.get("qr") == "deeplink" and SUB_DEEPLINK_RE.match(str(it.get("deeplink") or "")):
        out.append(("deeplink", str(it.get("deeplink"))))
    if out and it.get("qr_alt") == "url" and url.startswith("https://"):
        out.append(("alt", url))
    return out


def sub_qr_off(user_id: Optional[int], c: Dict[str, Any]) -> str:
    """Почему QR не нужен (qr ""): роутеру — команда; Clash на компьютере — вставить строкой; продуктам серии (у них нет
    платформ клиента) — вставляют строкой; остальным — «не для этого приложения». Слова — те же, что в панели."""
    p = [str(x) for x in c.get("platforms") or []] if isinstance(c.get("platforms"), list) else []
    if "router" in p:
        return _t(user_id, "sub_noqr_router")
    if not p:
        return _t(user_id, "sub_noqr_paste")
    if all(x in SUB_DESKTOP for x in p):
        return _t(user_id, "sub_noqr_desktop")
    return _t(user_id, "sub_noqr_app")


def sub_copy_kind(it: Dict[str, Any]) -> str:
    """Что отдаёт «Скопировать» — поле copy пункта: url — адрес, command — готовую команду, key — ключ линии в key_format
    (vpn — ключ vpn://, conf — текст .conf). Ядро без поля — команду, если она есть, иначе адрес."""
    copy = it.get("copy")
    if copy in ("url", "command"):
        return str(copy)
    if copy == "key":
        return "conf" if it.get("key_format") == "conf" else "vpn"
    return "command" if str(it.get("command") or "") else "url"


def sub_client_buttons(user_id: Optional[int], r: Dict[str, Any], c: Dict[str, Any]) -> List[List[Tuple[str, str, str]]]:
    """Ряды кнопок записи без PTB — (подпись, вид, значение): noop — заголовок линии или неактивный QR с причиной;
    sbq / sbc — QR адреса и то, что вставляют (значение — номер пункта); u_key — QR ключа линии выдачей карточки
    (значение — «профиль~qrvpn|qrconf»); sbs — короткая ссылка пункта, третьим действием своей строкой (только при
    short_available: бот настроен — 2FA есть). У нескольких линий — заголовок и ряды на каждую."""
    rows: List[List[Tuple[str, str, str]]] = []
    items = c.get("items") or []
    short = short_available(r)
    for n, it in enumerate(items[:SUB_ITEMS_MAX]):
        if len(items) > 1:
            rows.append([(_tf(user_id, "sub_line_hdr_fmt", sub_item_label(user_id, it)), "noop", "")])
        profile = sub_line_profile(r, str(it.get("line") or ""))
        if it.get("qr") == "key" and profile:
            fmt = "qrconf" if (it.get("key_format") or c.get("format")) == "conf" else "qrvpn"
            qr = (_t(user_id, "sub_btn_qr"), "u_key", "%s~%s" % (profile, fmt))
        elif sub_item_qrs(it):
            qr = (_t(user_id, "sub_btn_qr"), "sbq", str(n))
        elif it.get("qr") == "key":
            qr = (_tf(user_id, "sub_btn_qr_off_fmt", _t(user_id, "sub_noqr_nokey")), "noop", "")
        else:
            qr = (_tf(user_id, "sub_btn_qr_off_fmt", sub_qr_off(user_id, c)), "noop", "")
        rows.append([qr, (_t(user_id, "sub_btn_copy"), "sbc", str(n))])
        if short and SHORT_SUFFIX_RE.match(str(it.get("suffix") or "")):
            rows.append([(_t(user_id, "shl_btn_show"), "sbs", str(n))])
    return rows


def sub_chooser_text(user_id: Optional[int], r: Dict[str, Any], clients: List[Dict[str, Any]], head: str = "") -> str:
    """Экран выбора приложения: адресов в нём нет — только что есть в двух группах и предупреждение у выключенного."""
    lines = ["<b>%s</b>" % _tf(user_id, "sub_title_fmt", esc(r.get("label") or r.get("name") or ""))]
    if head:
        lines.extend(["", head])
    lines.extend(["", _t(user_id, "sub_pick")])
    groups = set(a.get("group") for a in sub_apps(clients))
    if "auto" in groups:
        lines.append(_t(user_id, "sub_grp_auto_note"))
    if "once" in groups:
        lines.append(_t(user_id, "sub_grp_once_note"))
    if r.get("disabled"):
        lines.extend(["", "<i>%s</i>" % _t(user_id, "sub_user_off")])
    return "\n".join(lines)


def sub_chooser_keyboard(user_id: Optional[int], name: str, clients: List[Dict[str, Any]]) -> "InlineKeyboardMarkup":
    """Приложения по группам: заголовок группы — неактивной строкой, рекомендованное — со звёздочкой, по два в ряд,
    длинное имя — во всю ширину (_menu_rows); кнопка приложения ведёт к его первой записи."""
    apps = sub_apps(clients)
    rows: list = []
    for grp in SUB_CLIENT_GROUPS:
        members = [a for a in apps if a.get("group") == grp]
        if not members:
            continue
        rows.append([btn(_t(user_id, SUB_CLIENT_GROUP_KEYS[grp]), "noop")])
        pair: list = []
        for a in members:
            cid = str(a["variants"][0].get("id"))
            label = ("⭐ " if a.get("recommended") else "") + sub_client_name(user_id, a["variants"][0])
            pair.append(btn(label, "sub_cl~%s~%s" % (name, cid)))
            if len(pair) == 2:
                rows.append(pair)
                pair = []
        if pair:
            rows.append(pair)
    rows.append(_back_row(user_id, "u_sub~%s" % name))
    return InlineKeyboardMarkup(_menu_rows(rows))


def sub_client_text(user_id: Optional[int], r: Dict[str, Any], c: Dict[str, Any]) -> str:
    """Экран записи без адресов: как обновляется и где работает, формат (у приложения с несколькими), как добавить, что
    дают кнопки, предупреждение у выключенного и что адрес — ключ."""
    who = r.get("label") or r.get("name") or ""
    mode = _tf(user_id, "sub_auto_every_fmt", sub_client_hours(c, r)) if c.get("group") == "auto" \
        else _t(user_id, "sub_once_note")
    plats = sub_platforms_text(user_id, c.get("platforms"))
    lines = ["<b>%s</b> · %s" % (esc(sub_client_name(user_id, c)), esc(who)), mode + (" · " + esc(plats) if plats else "")]
    if str(c.get("variant") or ""):
        lines.append(_tf(user_id, "sub_format_fmt", esc(sub_variant_name(user_id, c))))
    hint = sub_client_hint(user_id, c, r)
    if hint:
        lines.extend(["", _tf(user_id, "sub_howto_fmt", esc(hint))])
    lines.extend(["", _t(user_id, "sub_ways")])
    if short_available(r):
        lines.append(_t(user_id, "shl_way_note"))
    if r.get("disabled"):
        lines.extend(["", "<i>%s</i>" % _t(user_id, "sub_user_off")])
    lines.extend(["", _t(user_id, "sub_is_key")])
    return "\n".join(lines)


def sub_client_keyboard(user_id: Optional[int], name: str, r: Dict[str, Any], c: Dict[str, Any]) -> "InlineKeyboardMarkup":
    """Форматы приложения (у нескольких записей с одним app), способы по линиям (sub_client_buttons), длинная подпись —
    во всю ширину, «Назад» — к выбору приложения."""
    rows: list = []
    key = str(c.get("app") or c.get("id"))
    siblings = [v for v in sub_clients(r) if str(v.get("app") or v.get("id")) == key]
    if len(siblings) > 1:
        for v in siblings:
            cid = str(v.get("id"))
            label = ("✓ " if v.get("id") == c.get("id") else "") + sub_variant_name(user_id, v)
            rows.append([btn(label, "sub_cl~%s~%s" % (name, cid))])
    cid = str(c.get("id"))
    for spec in sub_client_buttons(user_id, r, c):
        row = []
        for label, kind, value in spec:
            if kind == "u_key":
                profile, fmt = value.split("~", 1)
                row.append(btn(label, "u_key~%s~%s~%s" % (name, profile, fmt)))
            elif kind == "sbq":
                item_no = value
                row.append(btn(label, "sbq~%s~%s~%s" % (name, cid, item_no)))
            elif kind == "sbc":
                item_no = value
                row.append(btn(label, "sbc~%s~%s~%s" % (name, cid, item_no)))
            elif kind == "sbs":
                item_no = value
                row.append(btn(label, "sbs~%s~%s~%s" % (name, cid, item_no)))
            else:
                row.append(btn(label, "noop"))
        rows.append(row)
    rows.append(_back_row(user_id, "sub_show~%s" % name))
    return InlineKeyboardMarkup(_menu_rows(rows))


def sub_value_text(user_id: Optional[int], r: Dict[str, Any], c: Dict[str, Any], it: Dict[str, Any],
                   key: Optional[Dict[str, Any]] = None) -> str:
    """Сообщение «Скопировать»: что это и для какого приложения, само значение моноширинным (долгое нажатие —
    скопировать; текст .conf — блоком), как добавить и что значение — ключ. key — ответ user-key при copy "key"."""
    app = esc(sub_client_name(user_id, c)) + (" · " + esc(sub_item_label(user_id, it)) if it.get("line") else "")
    kind = sub_copy_kind(it)
    if key is not None and kind == "conf":
        head, body = _tf(user_id, "sub_copy_conf_fmt", app), "<pre>%s</pre>" % esc(str(key.get("conf") or "").strip())
    elif key is not None:
        head, body = _tf(user_id, "sub_copy_key_fmt", app), "<code>%s</code>" % esc(key.get("vpn"))
    elif kind == "command":
        head, body = _tf(user_id, "sub_copy_cmd_fmt", app), "<code>%s</code>" % esc(it.get("command"))
    else:
        head, body = _tf(user_id, "sub_copy_url_fmt", app), "<code>%s</code>" % esc(it.get("url"))
    lines = [head, body]
    if key is not None and key.get("disabled") is True:
        lines.insert(0, _t(user_id, "key_disabled_warn"))
    hint = sub_client_hint(user_id, c, r)
    if hint:
        lines.extend(["", _tf(user_id, "sub_howto_fmt", esc(hint))])
    lines.extend(["", _t(user_id, "sub_is_key")])
    return "\n".join(lines)


# ── Короткие ссылки с 2FA через Telegram-бота (договор ядра и интерфейсов — docs/SUBSCRIPTION.md) ────
# Короткая ссылка https://<домен>/<КОД> привязана к паре «подписка + суффикс» (all.yaml, all.txt, all.vpn, awgNN.vpn,
# awgNN.conf) и работает только с 2FA через этого бота: вход по ней и замену подтверждает администратор — на экране
# устройства число, в боте 10 кнопок с числами (короткие ссылки есть, только когда бот настроен: short_available
# ответов sub-*). Код создаёт ядро при первом показе (short-ensure); бот показывает его отдельным сообщением с «↻
# Заменить» (short-replace-request: число — в чат, подтверждение — обычным запросом замены). Код — секрет того же
# порядка, что адрес подписки: в callback_data его нет (там имя и суффикс или id записи и номер пункта), в лог — только
# имя и суффикс. Запросы подтверждения (очередь short-confirm, раз в секунду) и баны — ниже и в разделе уведомлений.
SHORT_ACTION_PREFIX = "short-"
# Действия мимо замка бота (_BOT_ACTION_LOCK, через который mutate ставит в очередь операции бота): нажатое число не
# ждёт долгих операций бота — установки профиля, смены режима. short-decide в ядре — со своим замком state.json
# (lib/shortlinks.py под flock, мост — _action_own_lock в install.sh, без общего замка), гонку двух нажатий решает ядро:
# второй получает already: true; short-status и short-pending — чтения. Другим изменяющим действиям сюда нельзя
# (tests/test_bot_features.py сверяет список с _action_own_lock ядра).
BOT_UNLOCKED_ACTIONS = ("short-decide", "short-status", "short-pending")
# id запроса — в callback_data «sc~<id>~<NN|deny|swap>» (≤ 64 байт): до 48 знаков, без «~».
SHORT_REQUEST_RE = re.compile(r"^[A-Za-z0-9_-]{1,48}$")
SHORT_ANSWER_RE = re.compile(r"^(?:[1-9][0-9]|deny|swap)$")
# Суффиксы подписки, к которым бывает короткая ссылка (договор: all.yaml, all.txt, all.vpn, awgNN.vpn, awgNN.conf).
SHORT_SUFFIX_RE = re.compile(r"^(?:all\.(?:yaml|txt|vpn)|awg[0-9]{2}\.(?:vpn|conf))$")
# Итог запроса (short-decide, short-status, событие short_decided); pending — ещё ждёт ответа.
SHORT_OUTCOMES = ("ok", "wrong", "denied", "swapped", "expired", "frozen")
SHORT_WAITING = ("pending", "waiting")
SHORT_DONE_KEYS = {"ok": "shl_done_ok_fmt", "wrong": "shl_done_wrong_fmt", "denied": "shl_done_denied_fmt",
                   "swapped": "shl_done_swapped_fmt", "frozen": "shl_done_frozen_fmt"}
# Причины бана (reason ответа short-bans) словами; незнакомая — как есть.
SHORT_BAN_REASONS = {"misses": "shl_reason_misses", "guess": "shl_reason_misses", "bad_code": "shl_reason_misses",
                     "denied": "shl_reason_denied", "deny": "shl_reason_denied", "not_me": "shl_reason_denied",
                     "wrong": "shl_reason_wrong", "wrong_number": "shl_reason_wrong", "wrong_numbers": "shl_reason_wrong"}
# Ступень лестницы словами (PNL-COS-03: «ступень 1» было непонятно): (вид бана, первый раз?) → «бан на сутки (первый
# раз)», «заморозка на месяц (повторно)» и т. п. Лестница ядра: первый раз — сутки, каждый следующий — месяц.
SHORT_BAN_STEPS = {("ip", True): "shl_ban_step_ip_1", ("ip", False): "shl_ban_step_ip_n",
                   ("code", True): "shl_ban_step_code_1", ("code", False): "shl_ban_step_code_n"}
SHORT_BANS_SHOWN = 20

# Каталог действий ядра (lib/actions.json): знает ли ядро короткие ссылки и какой who принимает. Перечитывается по
# mtime — обновление ядра не требует перезапуска бота.
_CORE_ACTIONS: Dict[str, Any] = {"mtime": None, "spec": {}}


def core_actions() -> Dict[str, Any]:
    try:
        mtime = os.stat(ACTIONS_JSON).st_mtime
    except OSError:
        return {}
    if _CORE_ACTIONS["mtime"] != mtime:
        try:
            spec = json.loads(Path(ACTIONS_JSON).read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, ValueError):
            spec = {}
        _CORE_ACTIONS.update(mtime=mtime, spec=spec if isinstance(spec, dict) else {})
    return _CORE_ACTIONS["spec"]


def core_has_action(name: str) -> bool:
    actions = core_actions().get("actions")
    return isinstance(actions, dict) and isinstance(actions.get(name), dict)


def core_who_value(action: str, preferred: str, fallback: str) -> Optional[str]:
    """Значение --who для действия: preferred («bot:<id>» — какой администратор решил), если его пропускает тип
    параметра в каталоге ядра, иначе fallback («bot»); параметра who у действия нет — None (не передавать)."""
    spec = core_actions()
    adef = (spec.get("actions") or {}).get(action) if isinstance(spec.get("actions"), dict) else None
    if not isinstance(adef, dict):
        return preferred
    pdef = (adef.get("params") or {}).get("who") if isinstance(adef.get("params"), dict) else None
    if not isinstance(pdef, dict):
        return None
    types = spec.get("param_types") if isinstance(spec.get("param_types"), dict) else {}
    ptype = types.get(pdef.get("ref") or "who") or {}
    if not isinstance(ptype, dict):
        return preferred
    enum = ptype.get("enum")
    if isinstance(enum, list):
        return preferred if preferred in enum else fallback
    pattern = ptype.get("pattern")
    if isinstance(pattern, str):
        try:
            return preferred if re.fullmatch(pattern, preferred) else fallback
        except re.error:
            return fallback
    return preferred


def short_available(r: Any) -> bool:
    """Короткие ссылки есть: ответ sub-* говорит short_available (бот настроен — 2FA есть). Нет поля — нет и кнопок."""
    return isinstance(r, dict) and r.get("short_available") is True


def short_outcome(r: Any) -> str:
    """Итог запроса из ответа short-decide / short-status: ok | wrong | denied | swapped | expired | frozen, pending —
    ещё ждёт ответа; "" — отказ моста или непонятный ответ. По договору итог — поле status; мост, у которого status
    занят своим «success», отдаёт тот же итог полем decision (или result)."""
    if not isinstance(r, dict):
        return ""
    for v in (r.get("status"), r.get("decision"), r.get("result")):
        v = v if isinstance(v, str) else ""
        if v in SHORT_OUTCOMES:
            return v
        if v in SHORT_WAITING:
            return "pending"
    return ""


def short_plain(text: str, limit: int = 190) -> str:
    """Текст для всплывающего ответа на нажатие: без разметки (Telegram показывает её как есть) и не длиннее 200."""
    return html.unescape(_ANY_TAG_RE.sub("", str(text or ""))).strip()[:limit]


def short_options(v: Any) -> List[int]:
    """Числа запроса (options): целые 10–99 без повторов, не больше десяти — в порядке ядра (оно их перемешало)."""
    out: List[int] = []
    for x in v if isinstance(v, list) else []:
        if isinstance(x, bool):
            continue
        try:
            n = int(x)
        except (TypeError, ValueError):
            continue
        if 10 <= n <= 99 and n not in out:
            out.append(n)
    return out[:10]


def short_epoch(v: Any) -> float:
    """Срок запроса: число секунд (epoch, у миллисекунд — делим) или ISO-время UTC; непонятное — 0."""
    if isinstance(v, bool):
        return 0.0
    if isinstance(v, str) and re.fullmatch(r"[0-9]{9,13}", v.strip()):
        v = int(v.strip())
    if isinstance(v, (int, float)):
        return float(v) / 1000.0 if v > 1e12 else float(v)
    parsed = parse_iso(str(v or ""))
    return parsed.timestamp() if parsed else 0.0


def _short_geo_clean(v: Any, depth: int = 0) -> Any:
    """Город и страна события: строка или объект ({city, country} или {ru, en}) из строк — остальное прочь."""
    if isinstance(v, str):
        return v.strip()[:80]
    if isinstance(v, dict) and depth < 2:
        out = {}
        for k, x in v.items():
            if isinstance(k, str) and re.fullmatch(r"[a-z_]{1,16}", k):
                x = _short_geo_clean(x, depth + 1)
                if x:
                    out[k] = x
        return out
    return ""


def short_geo_text(user_id: Optional[int], geo: Any) -> str:
    """«Москва, Россия» на языке человека: строка — как есть; {ru, en} — свой язык; {city, region, country} — через
    запятую."""
    if isinstance(geo, str):
        return geo
    if not isinstance(geo, dict):
        return ""
    lang = get_user_lang(user_id)
    if any(k in geo for k in ("ru", "en")):
        return short_geo_text(user_id, geo.get(lang) or geo.get("ru") or geo.get("en"))
    parts = [short_geo_text(user_id, geo.get(k)) for k in ("city", "region", "country")]
    return ", ".join(p for p in parts if p)


def short_event(ev: Any) -> Optional[Dict[str, Any]]:
    """Поля события short_confirm, которые бот рисует и помнит: без мусора и без лишнего; id запроса не по форме — None.
    Верного числа в событии нет — и здесь его нет."""
    if not isinstance(ev, dict):
        return None
    req = str(ev.get("request") or "")
    if not SHORT_REQUEST_RE.match(req):
        return None
    out: Dict[str, Any] = {"request": req, "kind": "replace" if ev.get("kind") == "replace" else "login"}
    for k in ("name", "label", "suffix", "device", "ip"):
        v = ev.get(k)
        out[k] = str(v).strip()[:120] if isinstance(v, (str, int)) and not isinstance(v, bool) else ""
    out["geo"] = _short_geo_clean(ev.get("geo"))
    out["options"] = short_options(ev.get("options"))
    out["expires"] = short_epoch(ev.get("expires"))
    return out


def short_by_text(user_id: Optional[int], rec: Dict[str, Any]) -> str:
    """Кто решил запрос (или заменил ссылку и тем закрыл вход) — словами: администратор бота по имени из Telegram,
    «панель», «SSH», «страница подключения»; незнакомое — как есть."""
    by = str(rec.get("by") or "")
    m = re.fullmatch(r"(?:bot|tg):([0-9]{1,20})", by)
    if m:
        name = rec.get("by_name") or _SHORT_ADMIN_NAMES.get(int(m.group(1)))
        return esc(name) if name else _tf(user_id, "shl_by_id_fmt", m.group(1))
    if by == "bot":
        return esc(rec["by_name"]) if rec.get("by_name") else _t(user_id, "shl_by_bot")
    if by.startswith("panel"):
        return _t(user_id, "shl_by_panel")
    if by.startswith("ssh"):
        return _t(user_id, "shl_by_ssh")
    if by.startswith("page"):
        return _t(user_id, "shl_by_page")
    return esc(by[:32]) if by else _t(user_id, "shl_by_someone")


def short_result_line(user_id: Optional[int], rec: Dict[str, Any]) -> str:
    """Итог под запросом: «✅ Подтвердил: …», «Отклонено…», «↻ Закрыто: ссылку заменили — …» (кнопкой «↻ Заменить
    ссылку» у входа или заменой из панели, SSH, бота — ядро закрывает ждущий вход), «⌛ Время вышло». Незнакомый итог —
    «Закрыто — <кто>», без служебного слова в скобках (SL-UX-03)."""
    status = str(rec.get("done") or "")
    if status == "expired":
        return _t(user_id, "shl_done_expired")
    if status in SHORT_DONE_KEYS:
        return _tf(user_id, SHORT_DONE_KEYS[status], short_by_text(user_id, rec))
    return _tf(user_id, "shl_done_other_fmt", short_by_text(user_id, rec))


def short_confirm_text(user_id: Optional[int], ev: Dict[str, Any], rec: Optional[Dict[str, Any]] = None,
                       now: Optional[float] = None) -> str:
    """Сообщение запроса: что за запрос, крупно — где и с какого устройства, IP, чья подписка и вопрос с остатком
    времени; решённый — те же строки и итог вместо вопроса."""
    login = ev.get("kind") != "replace"
    lines = [_t(user_id, "shl_login_title" if login else "shl_replace_title")]
    where = " · ".join(x for x in (short_geo_text(user_id, ev.get("geo")), str(ev.get("device") or "")) if x)
    if where:
        lines.append("<b>%s</b>" % esc(where))
    meta = []
    if ev.get("ip"):
        meta.append(_tf(user_id, "shl_ip_fmt", esc(ev.get("ip"))))
    person = str(ev.get("label") or ev.get("name") or "")
    if person:
        meta.append(esc(person) + (" · " + esc(ev.get("suffix")) if ev.get("suffix") else ""))
    if meta:
        lines.append(" · ".join(meta))
    if rec is not None and rec.get("done"):
        lines.extend(["", short_result_line(user_id, rec)])
        return "\n".join(lines)
    lines.append(_t(user_id, "shl_question"))
    exp = float(ev.get("expires") or 0)
    if exp:
        left = max(1, int((exp - (time.time() if now is None else now) + 59) // 60))
        lines.append(_tf(user_id, "shl_left_fmt", left))
    return "\n".join(lines)


def short_confirm_rows(user_id: Optional[int], ev: Dict[str, Any]) -> List[List[Tuple[str, str]]]:
    """Клавиатура запроса без PTB — ряды (подпись, ответ): числа из options строками по 5 (в порядке ядра — оно их
    перемешало), последней строкой «Это не я» и у входа — «↻ Заменить ссылку». Вход — 12 кнопок, замена — 11."""
    nums = [str(n) for n in ev.get("options") or []]
    rows = [[(x, x) for x in nums[i:i + 5]] for i in range(0, len(nums), 5)]
    tail = [(_t(user_id, "shl_btn_deny"), "deny")]
    if ev.get("kind") != "replace":
        tail.append((_t(user_id, "shl_btn_swap"), "swap"))
    rows.append(tail)
    return rows


def short_confirm_keyboard(user_id: Optional[int], ev: Dict[str, Any]) -> "InlineKeyboardMarkup":
    """Ряды как есть, без _menu_rows: «↻ Заменить ссылку» длиннее половинной кнопки, а строка обязана остаться одной.
    В callback_data — только id запроса и ответ: ни кода, ни имени, ни адреса."""
    req = str(ev.get("request") or "")
    return InlineKeyboardMarkup([[btn(label, "sc~%s~%s" % (req, ans)) for label, ans in row]
                                 for row in short_confirm_rows(user_id, ev)])


def short_link_text(user_id: Optional[int], what: str, display: str, url: str, new: bool = False,
                    command: str = "") -> str:
    """Сообщение с короткой ссылкой: код крупно (диктовать и набирать), адрес моноширинно (зажать — скопировать), у
    роутера — команда с короткой ссылкой, пометка «2FA через Telegram-бота» и как набирать."""
    lines = [_tf(user_id, "shl_link_new_fmt" if new else "shl_link_title_fmt", what), "<b>%s</b>" % esc(display),
             "<code>%s</code>" % esc(url)]
    if command:
        lines.extend(["", _tf(user_id, "shl_cmd_fmt", esc(command))])
    lines.extend(["", _t(user_id, "shl_2fa_note"), _t(user_id, "shl_typing_note"), _t(user_id, "shl_app_note")])
    return "\n".join(lines)


def short_link_keyboard(user_id: Optional[int], name: str, sfx: str) -> Optional["InlineKeyboardMarkup"]:
    """«↻ Заменить» под короткой ссылкой — по имени и суффиксу (кода в callback_data нет); не по форме — без кнопки."""
    suffix = sfx if SHORT_SUFFIX_RE.match(str(sfx or "")) else ""
    if not valid_name(name) or not suffix:
        return None
    return InlineKeyboardMarkup([[btn(_t(user_id, "shl_btn_replace"), "sbr~%s~%s" % (name, suffix))]])


def short_link_of(r: Any) -> Optional[Tuple[str, str]]:
    """(display, url) короткой ссылки из ответа short-ensure / short-decide / short-status; нет — None."""
    if not isinstance(r, dict):
        return None
    url = str(r.get("url") or "")
    display = str(r.get("display") or r.get("code") or "")
    if not url.startswith("https://") or not re.fullmatch(r"[0-9A-Za-z-]{4,16}", display):
        return None
    return display, url


def short_bans(r: Any) -> List[Dict[str, Any]]:
    """Баны и заморозки из ответа short-bans: kind ip | code, target — строка по форме."""
    out = []
    for b in (r.get("bans") if isinstance(r, dict) and isinstance(r.get("bans"), list) else []):
        if isinstance(b, dict) and b.get("kind") in ("ip", "code") and isinstance(b.get("target"), str) \
                and re.fullmatch(r"[0-9A-Za-z.:/_-]{1,64}", b["target"]):
            out.append(b)
    return out


def short_ban_hash(b: Dict[str, Any]) -> str:
    """Метка бана в callback_data вместо самой цели (код — секрет): 8 hex от вида и цели."""
    return hashlib.sha256(("%s|%s" % (b.get("kind"), b.get("target"))).encode("utf-8")).hexdigest()[:8]


def short_ban_target(user_id: Optional[int], b: Dict[str, Any]) -> str:
    """«IP 203.0.113.7» или «код ••••9BKX» — код целиком на экран не идёт."""
    target = str(b.get("target") or "")
    if b.get("kind") == "code":
        return _tf(user_id, "shl_ban_code_fmt", esc("••••" + re.sub(r"[^0-9A-Za-z]", "", target)[-4:]))
    return _tf(user_id, "shl_ban_ip_fmt", esc(target))


def short_ban_line(user_id: Optional[int], n: int, b: Dict[str, Any]) -> str:
    until = b.get("until")
    if isinstance(until, (int, float)) and not isinstance(until, bool) and until > 0:
        until = _dt.datetime.fromtimestamp(short_epoch(until), _dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    reason = str(b.get("reason") or "")
    why = _t(user_id, SHORT_BAN_REASONS[reason]) if reason in SHORT_BAN_REASONS else esc(reason)
    level = b.get("level")
    parts = [_tf(user_id, "shl_ban_until_fmt", esc(ts_human(until)))] if until else []
    if why:
        parts.append(why)
    if isinstance(level, int) and not isinstance(level, bool) and level > 0:
        parts.append(_t(user_id, SHORT_BAN_STEPS[("code" if b.get("kind") == "code" else "ip", level == 1)]))
    return "%d. %s — %s" % (n, short_ban_target(user_id, b), " · ".join(parts) or "—")


def sub_keyboard(user_id: Optional[int], name: str, rec: Optional[Dict[str, Any]], ready: bool) -> "InlineKeyboardMarkup":
    rows = []
    if rec is None:
        if ready:
            rows.append([btn(_t(user_id, "sub_create_btn"), "sub_new~%s" % name)])
    else:
        rows.append([btn(_t(user_id, "sub_show_btn"), "sub_show~%s" % name)])
        if core_has_action("short-list"):
            # Короткие ссылки подписки и баны со снятием — ядро, которое их знает (lib/actions.json)
            rows.append([btn(_t(user_id, "shl_list_btn"), "shl_list~%s" % name)])
        rows.append([btn(_t(user_id, "sub_rotate_btn"), "sub_rot~%s" % name),
                     btn(_t(user_id, "sub_revoke_btn"), "sub_rev~%s" % name)])
    rows.append([btn(_t(user_id, "btn_refresh"), "u_sub~%s" % name), btn(_t(user_id, "btn_back"), "u_view~%s" % name)])
    return InlineKeyboardMarkup(rows)


async def cb_user_sub(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """u_sub~<name>: подписка человека — состояние без адреса и действия."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    name = _name_from_data(query.data, "u_sub~")
    if not name:
        await show_bad_input(query, user_id, "menu_users")
        return
    r = await run_bot_action("sub-list", timeout=60, name=name)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "u_view~%s" % name)
        return
    rec = sub_record(r, name)
    await safe_edit_message(query, sub_state_text(user_id, name, r, rec),
                            reply_markup=sub_keyboard(user_id, name, rec, r.get("domain_ready") is not False))


async def cb_sub_new(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """sub_new~<name>: sub-create → адреса отдельным сообщением; экран говорит, куда смотреть."""
    query = update.callback_query
    user_id = _uid(update)
    name = _name_from_data(str(query.data), "sub_new~")
    if not name:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    if await _action_busy(query, user_id, "u_sub~%s" % name):
        return
    await safe_edit_message(query, "⏳ " + _t(user_id, "sub_creating"), reply_markup=None)
    r = await mutate("sub-create", who=user_id, name=name)
    if not bridge_ok(r):
        code = str(r.get("code") or "")
        if code == "subs_need_domain":
            text = "<b>%s</b>\n\n%s" % (_tf(user_id, "sub_title_fmt", esc(name)), _t(user_id, "sub_need_domain"))
            markup = back_kb(user_id, "u_view~%s" % name)
        elif code == "no_private_key":
            # Все ключи человека — в приложении Amnezia: слова ядра целиком и два выхода по каждому профилю
            _, user = await _fetch_user(name)
            from_app = imported_profiles(user) if user else []
            if from_app:
                text, markup = imported_view(user_id, name, from_app, head=fail_text(user_id, r))
            else:
                text, markup = fail_text(user_id, r), back_kb(user_id, "u_view~%s" % name)
        else:
            text, markup = fail_text(user_id, r), fail_markup(user_id, r, "u_sub~%s" % name, retry_data(query))
        await safe_edit_message(query, text, reply_markup=markup)
        return
    # В лог — только имя: адреса в ответе секретные.
    logger.info("subscription for %s created (new: %s)", name, bool(r.get("new")))
    clients = sub_clients(r)
    if clients:
        # Выбор по клиенту: экран сам становится выбором приложения — адресов на нём нет, они по кнопке приложения
        await safe_edit_message(query, sub_chooser_text(user_id, r, clients, head="✅ " + _t(user_id, "sub_ready_pick")),
                                reply_markup=sub_chooser_keyboard(user_id, name, clients))
        return
    await safe_edit_message(query, "✅ " + _t(user_id, "sub_ready"), reply_markup=back_kb(user_id, "u_sub~%s" % name))
    if not await send_sub_links(query.message, user_id, r):
        await safe_edit_message(query, "❌ " + _t(user_id, "sub_send_failed"), reply_markup=back_kb(user_id, "u_sub~%s" % name))


async def cb_sub_show(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """sub_show~<name>: адреса ещё раз — отдельным сообщением, мимо лога (sub-show пишет аудит). Ответ с приложениями
    (поле clients) — экран выбора приложения на месте этого: адресов на нём нет, они — по кнопке приложения."""
    query = update.callback_query
    user_id = _uid(update)
    name = _name_from_data(str(query.data), "sub_show~")
    if not name:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    r = await run_bot_action("sub-show", timeout=60, who=user_id, name=name)
    if not bridge_ok(r):
        if str(r.get("code") or "") == "subs_need_domain":
            await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_tf(user_id, "sub_title_fmt", esc(name)),
                                                                _t(user_id, "sub_paused")),
                                    reply_markup=back_kb(user_id, "u_sub~%s" % name))
            return
        await show_error(query, user_id, r, "u_sub~%s" % name)
        return
    clients = sub_clients(r)
    if clients:
        logger.info("subscription of %s: app choice shown", name)
        await safe_edit_message(query, sub_chooser_text(user_id, r, clients),
                                reply_markup=sub_chooser_keyboard(user_id, name, clients))
        return
    logger.info("subscription of %s: addresses sent again", name)
    await safe_edit_message(query, "✅ " + _t(user_id, "sub_sent"), reply_markup=back_kb(user_id, "u_sub~%s" % name))
    if not await send_sub_links(query.message, user_id, r):
        await safe_edit_message(query, "❌ " + _t(user_id, "sub_send_failed"), reply_markup=back_kb(user_id, "u_sub~%s" % name))


async def _sub_show_for(query, user_id: Optional[int], name: str) -> Optional[Dict[str, Any]]:
    """sub-show для кнопок выбора по клиенту: ответ или None, когда человеку уже показан отказ (пауза — своими словами)."""
    r = await run_bot_action("sub-show", timeout=60, who=user_id, name=name)
    if bridge_ok(r):
        return r
    if str(r.get("code") or "") == "subs_need_domain":
        await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_tf(user_id, "sub_title_fmt", esc(name)), _t(user_id, "sub_paused")),
                                reply_markup=back_kb(user_id, "u_sub~%s" % name))
    else:
        await show_error(query, user_id, r, "u_sub~%s" % name)
    return None


async def _sub_gone(query, user_id: Optional[int], name: str, r: Dict[str, Any]) -> None:
    """Приложения или пункта в свежем ответе нет (у человека не стало линии, ядро сменило каталог): выбор — заново."""
    clients = sub_clients(r)
    if clients:
        await safe_edit_message(query, sub_chooser_text(user_id, r, clients, head="❌ " + _t(user_id, "sub_client_gone")),
                                reply_markup=sub_chooser_keyboard(user_id, name, clients))
    else:
        await safe_edit_message(query, "❌ " + _t(user_id, "sub_client_gone"), reply_markup=back_kb(user_id, "u_sub~%s" % name))


async def cb_sub_client(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """sub_cl~<name>~<id записи>: экран приложения на месте выбора — как обновляется, формат, как добавить и способы
    («QR-код», «Скопировать») по линиям; адресов на экране нет, они — по кнопке способа."""
    query = update.callback_query
    user_id = _uid(update)
    parts = str(query.data).split("~")
    if len(parts) != 3 or not valid_name(parts[1]) or not SUB_CLIENT_ID_RE.match(parts[2]):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    name, cid = parts[1], parts[2]
    await query.answer()
    r = await _sub_show_for(query, user_id, name)
    c = next((x for x in sub_clients(r) if x.get("id") == cid), None) if r else None
    if r is not None and c is None:
        await _sub_gone(query, user_id, name, r)
    elif c is not None:
        await safe_edit_message(query, sub_client_text(user_id, r, c), reply_markup=sub_client_keyboard(user_id, name, r, c))


async def _sub_pick_item(query, user_id: Optional[int]) -> Optional[Tuple[str, Dict[str, Any], Dict[str, Any], Dict[str, Any]]]:
    """sbq~ / sbc~<name>~<id записи>~<номер пункта> → (имя, ответ sub-show, запись, пункт) или None, когда человеку уже
    сказано, что не так. Адрес — заново через sub-show: в callback_data его нет."""
    parts = str(query.data).split("~")
    if len(parts) != 4 or not valid_name(parts[1]) or not SUB_CLIENT_ID_RE.match(parts[2]) or not parts[3].isdigit():
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return None
    name, cid, n = parts[1], parts[2], int(parts[3])
    await query.answer()
    r = await _sub_show_for(query, user_id, name)
    if r is None:
        return None
    c = next((x for x in sub_clients(r) if x.get("id") == cid), None)
    items = (c or {}).get("items") or []
    if c is None or n >= len(items):
        await _sub_gone(query, user_id, name, r)
        return None
    return name, r, c, items[n]


async def cb_sub_qr(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """sbq~<name>~<id>~<пункт>: QR адреса или ссылки «в приложение» картинкой, с qr_alt — и второй код (адрес),
    отдельными сообщениями. QR ключа линии сюда не приходит — его выдаёт кнопка ключа карточки (u_key~…~qrvpn|qrconf)."""
    query = update.callback_query
    user_id = _uid(update)
    got = await _sub_pick_item(query, user_id)
    if got is not None:
        name, r, c, it = got
        app = sub_client_name(user_id, c)
        what = app + (" · " + sub_item_label(user_id, it) if it.get("line") else "")
        logger.info("subscription of %s: app %s qr sent", name, c.get("id"))
        sent = 0
        try:
            for kind, text in sub_item_qrs(it):
                png = await qr_png(text)
                if png is None:
                    continue
                await query.message.reply_photo(photo=io.BytesIO(png),
                                                caption=_tf(user_id, SUB_QR_CAPTIONS[kind], what if kind == "url" else app))
                sent += 1
            if not sent:
                await query.message.reply_text("❌ " + _t(user_id, "sub_qr_none"), reply_markup=back_kb(user_id, "sub_show~%s" % name))
        except TelegramError as e:
            logger.warning("subscription of %s: app %s qr delivery failed: %s", name, c.get("id"), e)
            await query.message.reply_text("❌ " + _t(user_id, "sub_client_send_failed"))


async def cb_sub_copy(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """sbc~<name>~<id>~<пункт>: то, что вставляют в приложение, — по полю copy: адрес, готовая команда или ключ линии
    (действием user-key, как ключ в карточке: vpn:// или текст .conf); моноширинным сообщением без превью — долгое
    нажатие копирует; ключ длиннее сообщения — файлом. Ключа этой линии на сервере нет — адрес."""
    query = update.callback_query
    user_id = _uid(update)
    got = await _sub_pick_item(query, user_id)
    if got is not None:
        name, r, c, it = got
        kind = sub_copy_kind(it)
        profile = sub_line_profile(r, str(it.get("line") or "")) if kind in ("vpn", "conf") else ""
        key = None
        if profile:
            key = await run_bot_action("user-key", timeout=120, who=user_id, name=name, profile=profile, format=kind)
            if not bridge_ok(key):
                await show_error(query, user_id, key, "sub_show~%s" % name)
                return
            if not str(key.get(kind) or ""):
                key = None                       # мост не дал ключа — отдаём адрес линии
        text = sub_value_text(user_id, r, c, it, key=key)
        logger.info("subscription of %s: app %s value sent", name, c.get("id"))
        try:
            if key is None or len(text) <= VPN_LINK_INLINE_MAX:
                await query.message.reply_text(text, parse_mode="HTML", disable_web_page_preview=True)
            else:
                value = str(key.get(kind) or "")
                fname = ("%s.conf" % key_file_stem(key, name, profile) if kind == "conf"
                         else "amnezia-%s-%s.vpn.txt" % (name, profile))
                await query.message.reply_document(document=InputFile(io.BytesIO(value.encode("utf-8")), filename=fname),
                                                   caption=_tf(user_id, "sub_copy_file_fmt", sub_client_name(user_id, c)))
        except TelegramError as e:
            logger.warning("subscription of %s: app %s delivery failed: %s", name, c.get("id"), e)
            await query.message.reply_text("❌ " + _t(user_id, "sub_client_send_failed"))


# ── Короткая ссылка: показ, замена, ответ на запрос подтверждения, список подписки и баны ────

# Отказ short-* людям — словами, без служебного кода (SL-UX-03, настоящий бот на 168: «… попробуйте через 5 мин
# (short_pending)»): ни «(<code>short_pending</code>)», ни голого «short_need_bot». Слова ядра у этих отказов сами говорят,
# что делать («попробуйте через 5 мин», «сначала покажите её»); у незнакомого отказа — слова ядра без хвоста «(код)» или
# «не выполнено», и что делать.
SHORT_WORDED_CODES = frozenset(("short_pending", "short_limit", "short_not_found", "short_request_not_found",
                                "short_bad_answer", "bad_suffix", "bad_target", "short_busy", "sub_not_found"))
SHORT_CODE_TAIL_RE = re.compile(r"\s*\((?:<code>)?(?:rc=)?[A-Za-z0-9_.:-]+(?:</code>)?\)\s*\.?\s*$")


def short_error_text(user_id: Optional[int], r: Any) -> str:
    """Отказ моста у действия коротких ссылок словами (HTML): бот не настроен — что делать; «занято», таймаут, «появится
    позже» — общими словами бота; иначе слова ядра без кода, а у незнакомого отказа ещё и «повторите…»."""
    r = r if isinstance(r, dict) else {}
    code = str(r.get("code") or "")
    if code == "short_need_bot":
        return _t(user_id, "shl_need_bot")
    if code in ("lock_timeout", "timeout", "not_implemented"):
        return error_text(user_id, r)
    if code == "transport":
        return _t(user_id, "shl_err_transport")
    words = SHORT_CODE_TAIL_RE.sub("", str(r.get("message") or "")).strip()
    if words == code or re.fullmatch(r"[a-z0-9_]+", words):
        words = ""                                       # «слова» — тот же код
    if words and code in SHORT_WORDED_CODES:
        return esc(words)
    head = esc(words.rstrip(" .")) + "." if words else _t(user_id, "shl_err_failed")
    return "%s %s" % (head, _t(user_id, "shl_err_retry"))


def short_fail_text(user_id: Optional[int], r: Dict[str, Any]) -> str:
    """Отказ действия коротких ссылок строкой экрана: «занято» — ожидание (⏳), ответ без ссылки — что ядро старое,
    остальное — ❌ и short_error_text (без служебного кода)."""
    if is_lock_busy(r):
        return fail_text(user_id, r)
    if bridge_ok(r):
        return "❌ " + _t(user_id, "shl_bad_answer")
    return "❌ " + short_error_text(user_id, r)


async def short_show_error(query, user_id: Optional[int], r: Dict[str, Any], back_to: str) -> None:
    """show_error для short-*: те же кнопки («🔁 Повторить» у «занято», «Назад»), слова — short_fail_text."""
    await safe_edit_message(query, short_fail_text(user_id, r), reply_markup=fail_markup(user_id, r, back_to, retry_data(query)))


def short_replace_text(user_id: Optional[int], name: str, suffix: str, number: int) -> str:
    """Запрос замены создан: число — в чат тому, кто нажал «↻»; подтверждение придёт обычным запросом замены."""
    return "\n".join([_tf(user_id, "shl_replace_req_fmt", esc(name), esc(suffix)),
                      _tf(user_id, "shl_replace_number_fmt", number), "", _t(user_id, "shl_replace_how")])


def _short_admin_name(update: Any) -> str:
    """Имя нажавшего администратора из Telegram — для «Подтвердил: …» у остальных; помнится, пока бот работает."""
    user = getattr(update, "effective_user", None)
    name = _pairing_clean(getattr(user, "full_name", None) or getattr(user, "username", None) or "", 48)
    uid = getattr(user, "id", None)
    if name and isinstance(uid, int) and not isinstance(uid, bool):
        _SHORT_ADMIN_NAMES[uid] = name
    return name


async def _short_show_target(query, user_id: Optional[int]) -> Optional[Tuple[str, str, str, str, str]]:
    """Что показывать по sbs~: (имя, суффикс, подпись, полный адрес, команда роутера) или None, когда человеку уже
    сказано, что не так. sbs~<имя>~<суффикс> — из списка коротких ссылок; sbs~<имя>~<id>~<пункт> — у приложения, пункт
    заново через sub-show (там же short_available)."""
    parts = str(query.data).split("~")
    if len(parts) == 3 and valid_name(parts[1]) and SHORT_SUFFIX_RE.match(parts[2]):
        await query.answer()
        return parts[1], parts[2], "%s · %s" % (esc(parts[1]), esc(parts[2])), "", ""
    got = await _sub_pick_item(query, user_id)
    if got is None:
        return None
    name, r, c, it = got
    suffix = str(it.get("suffix") or "")
    if not short_available(r) or not SHORT_SUFFIX_RE.match(suffix):
        await query.message.reply_text("❌ " + _t(user_id, "shl_need_bot"), parse_mode="HTML",
                                       reply_markup=back_kb(user_id, "sub_show~%s" % name))
        return None
    what = esc(sub_client_name(user_id, c)) + (" · " + esc(sub_item_label(user_id, it)) if it.get("line") else "")
    command = str(it.get("command") or "") if sub_copy_kind(it) == "command" else ""
    return name, suffix, what, str(it.get("url") or ""), command


async def cb_short_show(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """sbs~<имя>~<id записи>~<пункт> (экран приложения) или sbs~<имя>~<суффикс> (короткие ссылки подписки): код и адрес
    короткой ссылки отдельным сообщением с «↻ Заменить». Код создаёт ядро при первом показе (short-ensure); роутеру —
    ещё и команда с короткой ссылкой. В лог — имя и суффикс, кода там нет."""
    query = update.callback_query
    user_id = _uid(update)
    target = await _short_show_target(query, user_id)
    if target is not None:
        await _short_send_link(query, user_id, *target)


async def _short_send_link(query, user_id: Optional[int], name: str, suffix: str, what: str, full_url: str,
                           command: str) -> None:
    """short-ensure → сообщение с кодом и адресом и «↻ Заменить»; отказ — словами с «Назад» к подписке."""
    r2 = await mutate("short-ensure", who=user_id, timeout=60, name=name, suffix=suffix)
    link = short_link_of(r2) if bridge_ok(r2) else None
    if link is None:
        await query.message.reply_text(short_fail_text(user_id, r2), parse_mode="HTML",
                                       reply_markup=back_kb(user_id, "u_sub~%s" % name))
        return
    display, url = link
    # Роутеру — та же команда, что у «Скопировать», только с короткой ссылкой вместо полной
    command = command.replace(full_url, url) if command and full_url and full_url in command else ""
    logger.info("short link of %s (%s) shown", name, suffix)
    try:
        await query.message.reply_text(short_link_text(user_id, what, display, url, command=command), parse_mode="HTML",
                                       disable_web_page_preview=True, reply_markup=short_link_keyboard(user_id, name, suffix))
    except TelegramError as e:
        logger.warning("short link of %s (%s): delivery failed: %s", name, suffix, e)
        await query.message.reply_text("❌ " + _t(user_id, "sub_client_send_failed"))


async def cb_short_replace(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """sbr~<имя>~<суффикс>: «↻ Заменить» — запрос замены (short-replace-request, who — «bot:<id>», если каталог ядра его
    пропускает, иначе «bot»): число — в этот чат, само подтверждение придёт обычным запросом «Замена короткой ссылки» всем
    администраторам; старый код гаснет только после верного числа. Ждущий вход по этой ссылке ядро закрывает событием
    short_decided (swapped, by — этот who): «↻ Закрыто: ссылку заменили — <кто>»."""
    query = update.callback_query
    user_id = _uid(update)
    parts = str(query.data).split("~")
    if len(parts) != 3 or not valid_name(parts[1]) or not SHORT_SUFFIX_RE.match(parts[2]):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    name, suffix = parts[1], parts[2]
    await query.answer()
    r = await mutate("short-replace-request", who=user_id, timeout=60, name=name, suffix=suffix,
                     who_arg=core_who_value("short-replace-request", "bot:%s" % user_id, "bot"))
    number = r.get("number")
    number = int(number) if isinstance(number, (int, str)) and not isinstance(number, bool) \
        and re.fullmatch(r"[1-9][0-9]", str(number)) else 0
    if not bridge_ok(r) or not number or not SHORT_REQUEST_RE.match(str(r.get("request") or "")):
        await query.message.reply_text(short_fail_text(user_id, r), parse_mode="HTML",
                                       reply_markup=back_kb(user_id, "u_sub~%s" % name))
        return
    logger.info("short link of %s (%s): replacement requested, request %s", name, suffix, r.get("request"))
    num_msg = await query.message.reply_text(short_replace_text(user_id, name, suffix, number), parse_mode="HTML")
    # Кто просил: итог и новый код придут ему, даже если подтвердит другой администратор (SL-BOT-01)
    where = lambda m: [getattr(m, "chat_id", None), getattr(m, "message_id", None)]  # noqa: E731
    short_register_ask(str(r["request"]), {"uid": user_id, "name": _short_admin_name(update),
                                           "link": where(query.message), "num": where(num_msg)},
                       name, suffix, short_epoch(r.get("expires")))


async def cb_short_decide(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """sc~<запрос>~<NN|deny|swap>: ответ администратора на запрос входа или замены — мосту short-decide (who — этот
    администратор). Решает первый нажавший: итог правит сообщение запроса у всех администраторов, нажавшему — коротко
    всплывающим ответом. Новый код: замену просил администратор этого бота — ему (short_notify_asker), нажавшему другому —
    «↻ Заменено, ссылка у <кто просил>» (SL-BOT-01); иначе (замена со страницы, из панели, SSH, «↻ Заменить ссылку» у
    входа) — нажавшему отдельным сообщением. Уже решённый запрос мост не зовёт: всплывает, чем он решён."""
    query = update.callback_query
    user_id = _uid(update)
    parts = str(query.data).split("~")
    if len(parts) != 3 or not SHORT_REQUEST_RE.match(parts[1]) or not SHORT_ANSWER_RE.match(parts[2]):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    req, ans = parts[1], parts[2]
    me = _short_admin_name(update)
    tg_bot = getattr(context, "bot", None) or _SHORT_BOT.get("bot")
    msg = getattr(query, "message", None)
    here = (getattr(msg, "chat_id", None), getattr(msg, "message_id", None)) if msg is not None else None
    async with _SHORT_LOCKS.setdefault(req, asyncio.Lock()):
        rec = _short_state().get(req)
        if rec is not None and rec.get("done"):
            await query.answer(_tf(user_id, "shl_already_fmt", short_plain(short_result_line(user_id, rec))), show_alert=True)
            await safe_edit_message(query, short_confirm_text(user_id, rec.get("ev") or {}, rec), reply_markup=None)
            return
        # Мимо замка бота (BOT_UNLOCKED_ACTIONS): нажатое число не ждёт долгой операции бота; у ядра — свой замок
        r = await run_bot_action("short-decide", timeout=60, who=user_id, request=req, answer=ans,
                                 who_arg=core_who_value("short-decide", "bot:%s" % user_id, "bot"))
        outcome = short_outcome(r)
        if outcome in ("", "pending"):
            await query.answer(short_plain(short_error_text(user_id, r)), show_alert=True)
            return
        if rec is None:
            # Запрос старше перезапуска бота без его файла: правим хотя бы это сообщение
            rec = {"ev": {"request": req, "kind": "login"}, "msgs": [list(here)] if here and here[0] else [],
                   "done": "", "by": "", "by_name": "", "at": time.time()}
            _short_state()[req] = rec
        link = short_link_of(r)
        if r.get("already") is True:
            # Решили раньше — в панели, SSH или другим нажатием (гонку решает ядро): итог и кто — от ядра, не этот нажавший
            core_by = str(r.get("by") or "")
            await short_apply_decision(tg_bot, req, outcome, skip=here, link=link,
                                       by=core_by if re.fullmatch(r"[A-Za-z0-9:_.@-]{1,48}", core_by) else "")
            await query.answer(_tf(user_id, "shl_already_fmt", short_plain(short_result_line(user_id, rec))), show_alert=True)
            await safe_edit_message(query, short_confirm_text(user_id, rec.get("ev") or {}, rec), reply_markup=None)
            return
        logger.info("short link request %s: %s by admin %s", req, outcome, user_id)
        await short_apply_decision(tg_bot, req, outcome, by="bot:%s" % user_id, by_name=me, skip=here, link=link)
        ask = rec.get("ask") if isinstance(rec.get("ask"), dict) else None
        if ask and outcome in ("ok", "swapped") and ask.get("uid") != user_id:
            # Замену просил другой администратор: новый код — у него, нажавшему — коротко, у кого (SL-BOT-01)
            asker = ask.get("name") or _SHORT_ADMIN_NAMES.get(ask.get("uid")) or ""
            await query.answer(short_plain(_tf(user_id, "shl_swap_given_fmt", esc(asker) if asker else
                                               _tf(user_id, "shl_by_id_fmt", ask.get("uid")))))
        else:
            await query.answer(short_plain(short_result_line(user_id, rec)))
        await safe_edit_message(query, short_confirm_text(user_id, rec.get("ev") or {}, rec), reply_markup=None)
    ev = rec.get("ev") or {}
    if link and not ask and (outcome == "swapped" or (outcome == "ok" and ev.get("kind") == "replace")) \
            and msg is not None:
        name, suffix = str(ev.get("name") or ""), str(ev.get("suffix") or "")
        what = "%s · %s" % (esc(ev.get("label") or name), esc(suffix))
        try:
            await msg.reply_text(short_link_text(user_id, what, link[0], link[1], new=True), parse_mode="HTML",
                                 disable_web_page_preview=True, reply_markup=short_link_keyboard(user_id, name, suffix))
        except TelegramError as e:
            logger.warning("short link request %s: new link delivery failed: %s", req, e)


async def cb_short_list(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """shl_list~<имя>: короткие ссылки подписки (short-list) — какие созданы и когда, без кодов на экране; кнопка
    ссылки присылает её отдельным сообщением с «↻ Заменить»; «Баны и заморозки» — список со снятием."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    name = _name_from_data(query.data, "shl_list~")
    if not name:
        await show_bad_input(query, user_id, "menu_users")
        return
    r = await run_bot_action("short-list", timeout=60, who=user_id, name=name)
    if not bridge_ok(r):
        await short_show_error(query, user_id, r, "u_sub~%s" % name)
        return
    codes = [c for c in (r.get("codes") if isinstance(r.get("codes"), list) else [])
             if isinstance(c, dict) and SHORT_SUFFIX_RE.match(str(c.get("suffix") or ""))]
    lines = ["<b>%s</b>" % _tf(user_id, "shl_list_title_fmt", esc(name)), "", _t(user_id, "shl_2fa_note"), ""]
    if codes:
        lines.append(_t(user_id, "shl_list_have"))
        lines.extend("• %s — %s" % (esc(c["suffix"]), esc(ts_human(c.get("created")))) for c in codes)
    else:
        lines.append(_t(user_id, "shl_list_none"))
    rows: list = []
    pair: list = []
    for c in codes:
        suffix = str(c["suffix"])
        pair.append(btn("🔗 %s" % suffix, "sbs~%s~%s" % (name, suffix)))
        if len(pair) == 2:
            rows.append(pair)
            pair = []
    if pair:
        rows.append(pair)
    rows.append([btn(_t(user_id, "shl_bans_btn"), "shl_bans~%s" % name)])
    rows.append(_back_row(user_id, "u_sub~%s" % name))
    await safe_edit_message(query, "\n".join(lines), reply_markup=InlineKeyboardMarkup(rows))


async def _short_bans_screen(query, user_id: Optional[int], name: str = "", head: str = "") -> None:
    """Баны адресов и заморозки кодов (short-bans): что, до когда и за что, «✓ Снять N» — номером; цель в кнопке не
    едет (код — секрет): номер и метка бана, по ним снятие находит цель в свежем списке."""
    r = await run_bot_action("short-bans", timeout=60, who=user_id)
    if not bridge_ok(r):
        await short_show_error(query, user_id, r, ("shl_list~%s" % name) if name else "menu_main")
        return
    bans = short_bans(r)[:SHORT_BANS_SHOWN]
    lines = ["<b>%s</b>" % _t(user_id, "shl_bans_title")]
    if head:
        lines.extend(["", head])
    lines.extend(["", _t(user_id, "shl_bans_note"), ""])
    if bans:
        lines.extend(short_ban_line(user_id, n + 1, b) for n, b in enumerate(bans))
    else:
        lines.append(_t(user_id, "shl_bans_none"))
    rows: list = []
    pair: list = []
    for n, b in enumerate(bans):
        idx, bh = str(n), short_ban_hash(b)
        label = _tf(user_id, "shl_unban_btn_fmt", n + 1)
        pair.append(btn(label, ("shl_ub~%s~%s~%s" % (idx, bh, name)) if name else ("shl_ub~%s~%s" % (idx, bh))))
        if len(pair) == 2:
            rows.append(pair)
            pair = []
    if pair:
        rows.append(pair)
    rows.append(_back_row(user_id, ("shl_list~%s" % name) if name else "menu_main"))
    await safe_edit_message(query, "\n".join(lines), reply_markup=InlineKeyboardMarkup(rows))


async def cb_short_bans(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """shl_bans~<имя> (из коротких ссылок подписки) или shl_bans (из тревоги о подборе): баны и заморозки со снятием."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    data = str(query.data)
    name = ""
    if data.startswith("shl_bans~"):
        name = _name_from_data(data, "shl_bans~")
        if not name:
            await show_bad_input(query, user_id, "menu_main")
            return
    await _short_bans_screen(query, user_id, name)


async def cb_short_unban(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """shl_ub~<номер>~<метка>[~<имя>]: снять бан или заморозку (short-unban) — цель берётся из свежего short-bans по
    номеру и метке; список успел смениться — по метке; бана уже нет — так и сказать. В лог — только вид бана."""
    query = update.callback_query
    user_id = _uid(update)
    parts = str(query.data).split("~")
    if len(parts) not in (3, 4) or not parts[1].isdigit() or not re.fullmatch(r"[0-9a-f]{8}", parts[2]) \
            or (len(parts) == 4 and not valid_name(parts[3])):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    idx, bh, name = int(parts[1]), parts[2], (parts[3] if len(parts) == 4 else "")
    r = await run_bot_action("short-bans", timeout=60, who=user_id)
    if not bridge_ok(r):
        await short_show_error(query, user_id, r, ("shl_list~%s" % name) if name else "menu_main")
        return
    bans = short_bans(r)
    b = bans[idx] if idx < len(bans) and short_ban_hash(bans[idx]) == bh \
        else next((x for x in bans if short_ban_hash(x) == bh), None)
    head = "ℹ️ " + _t(user_id, "shl_unban_gone")
    if b is not None:
        r2 = await mutate("short-unban", who=user_id, timeout=60, target=b["target"])
        if not (bridge_ok(r2) or r2.get("status") in ("ok", "unbanned")):
            await short_show_error(query, user_id, r2, ("shl_list~%s" % name) if name else "menu_main")
            return
        logger.info("short link ban (%s) lifted by admin %s", b.get("kind"), user_id)
        head = "✅ " + _tf(user_id, "shl_unbanned_fmt", short_ban_target(user_id, b))
    await _short_bans_screen(query, user_id, name, head=head)


async def cb_sub_rotate(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """sub_rot~<name>: перевыпуск — только фразой ROTATE <name>: прежний адрес умрёт у всех роутеров сразу."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    name = _name_from_data(query.data, "sub_rot~")
    if not name:
        await show_bad_input(query, user_id, "menu_users")
        return
    await arm_typed_confirm(query, context, user_id, "sub-rotate", name, back_to="u_sub~%s" % name,
                            warn=_tf(user_id, "sub_rotate_warn_fmt", esc(name)))


async def cb_sub_revoke(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """sub_rev~<name>: отзыв — только фразой REVOKE <name>."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    name = _name_from_data(query.data, "sub_rev~")
    if not name:
        await show_bad_input(query, user_id, "menu_users")
        return
    await arm_typed_confirm(query, context, user_id, "sub-revoke", name, back_to="u_sub~%s" % name,
                            warn=_tf(user_id, "sub_revoke_warn_fmt", esc(name)))


# ── Зеркало сборок: Настройки → «Копии приложений для клиентов» (docs/CLIENTS.md §8) ────

def platform_label(user_id: Optional[int], platform: str) -> str:
    return _t(user_id, "mr_platform_%s" % platform) if valid_platform(platform) else str(platform or "—")


def mirror_state_label(user_id: Optional[int], item: Dict[str, Any]) -> str:
    """готово · загружается NN% · в очереди · ошибка (код). Проценты — если ядро
    отдало bytes рядом с size; без них — просто «загружается»."""
    state = str(item.get("state") or "")
    label = _t(user_id, "mr_state_%s" % state) if state in MIRROR_STATES else (state or "—")
    if state == "downloading":
        try:
            done, total = int(item.get("bytes") or 0), int(item.get("size") or 0)
        except (TypeError, ValueError):
            done, total = 0, 0
        if total > 0 and done > 0:
            label = "%s %d%%" % (label, min(100, done * 100 // total))
    if state == "failed" and item.get("error"):
        # Фразу пишет ядро (message), код — для поиска в журнале.
        msg = str(item.get("message") or "").strip()
        label = "%s: %s (%s)" % (label, msg, item.get("error")) if msg else "%s (%s)" % (label, item.get("error"))
    return label


def mirror_items(r: Dict[str, Any]) -> List[Dict[str, Any]]:
    """items[] из mirror-list — только записи, чьи app и platform по форме: они едут в callback_data."""
    return [i for i in (r.get("items") or []) if isinstance(i, dict)
            and valid_app_id(str(i.get("app") or "")) and valid_platform(str(i.get("platform") or ""))]


def mirrorable_apps(r: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Приложения каталога, чьи сборки можно держать у себя: есть mirror.assets, платформы — из него."""
    out = []
    for a in r.get("apps") or []:
        if not isinstance(a, dict) or not valid_app_id(str(a.get("id") or "")):
            continue
        mirror = a.get("mirror")
        assets = mirror.get("assets") if isinstance(mirror, dict) else None
        platforms = [p for p in PLATFORM_IDS if isinstance(assets, dict) and p in assets]
        if platforms:
            out.append({"id": str(a.get("id")), "name": str(a.get("name") or a.get("id")),
                        "official": bool(a.get("official")), "platforms": platforms})
    return out


async def cb_se_mirror(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_mirror: копии сборок на сервере — состояние, версия, размер, занято из предела."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    r = await run_bot_action("mirror-list", timeout=60)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "sec_settings")
        return
    items = mirror_items(r)
    lines = ["<b>%s</b>" % _t(user_id, "se_mirror"), "", _t(user_id, "mr_intro"), ""]
    if not items:
        lines.append("<i>%s</i>" % _t(user_id, "mr_none"))
    for i in items:
        lines.append(_tf(user_id, "mr_row_fmt", esc(i.get("app")), esc(platform_label(user_id, str(i.get("platform")))),
                         esc(mirror_state_label(user_id, i)), esc(i.get("version") or "—"), human_bytes(i.get("size"), user_id)))
    lines.append("")
    lines.append(_tf(user_id, "mr_usage_fmt", esc(r.get("used_mb") or 0), esc(r.get("max_total_mb") or 0)))
    rows = [[btn(_t(user_id, "mr_fetch_btn"), "mr_fetch")]]
    for i in items:
        app, platform = str(i.get("app")), str(i.get("platform"))
        rows.append([btn(_tf(user_id, "mr_remove_btn_fmt", app, platform_label(user_id, platform)), "mr_del~%s~%s" % (app, platform))])
    rows.append([btn(_t(user_id, "btn_refresh"), "se_mirror"), btn(_t(user_id, "btn_back"), "sec_settings")])
    await safe_edit_message(query, "\n".join(lines), reply_markup=InlineKeyboardMarkup(rows))


async def cb_mirror_fetch(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """mr_fetch: какое приложение скачать — из каталога, только зеркалируемые."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    r = await run_bot_action("clients-list", timeout=60)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "se_mirror")
        return
    apps = mirrorable_apps(r)
    rows = []
    for a in apps:
        label = a["name"] if a["official"] else "%s (%s)" % (a["name"], _t(user_id, "mr_unofficial"))
        rows.append([btn(label, "mr_app~%s" % a["id"])])
    rows.append(_back_row(user_id, "se_mirror"))
    body = _t(user_id, "mr_pick_app") if apps else _t(user_id, "mr_no_apps")
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "mr_fetch_btn"), body), reply_markup=InlineKeyboardMarkup(rows))


async def cb_mirror_app(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """mr_app~<app>: для какой платформы скачать сборку — только те, что есть в mirror.assets."""
    query = update.callback_query
    user_id = _uid(update)
    app_id = str(query.data).split("~", 1)[1] if "~" in str(query.data) else ""
    if not valid_app_id(app_id):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    r = await run_bot_action("clients-list", timeout=60)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "mr_fetch")
        return
    app = next((a for a in mirrorable_apps(r) if a["id"] == app_id), None)
    if app is None:
        await safe_edit_message(query, "❌ " + _tf(user_id, "mr_unknown_app_fmt", esc(app_id)), reply_markup=back_kb(user_id, "mr_fetch"))
        return
    rows = [[btn(platform_label(user_id, p), "mr_fetch~%s~%s" % (app_id, p))] for p in app["platforms"]]
    rows.append(_back_row(user_id, "mr_fetch"))
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "mr_fetch_btn"), _tf(user_id, "mr_pick_platform_fmt", esc(app["name"]))),
                            reply_markup=InlineKeyboardMarkup(rows))


async def cb_mirror_fetch_do(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """mr_fetch~<app>~<platform>: поставить загрузку; идёт в фоне, состояние — на экране зеркала."""
    query = update.callback_query
    user_id = _uid(update)
    parts = str(query.data).split("~")
    if len(parts) != 3 or not valid_app_id(parts[1]) or not valid_platform(parts[2]):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    app, platform = parts[1], parts[2]
    await query.answer()
    if await _action_busy(query, user_id, "se_mirror"):
        return
    r = await mutate("mirror-fetch", who=user_id, app=app, platform=platform)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "se_mirror")
        return
    logger.info("mirror fetch queued: %s/%s", app, platform)
    await safe_edit_message(query, "✅ " + _tf(user_id, "mr_fetch_queued_fmt", esc(app), esc(platform_label(user_id, platform))),
                            reply_markup=back_kb(user_id, "se_mirror"))


async def cb_mirror_remove(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """mr_del~<app>~<platform> → вопрос; mr_del_do~… → mirror-remove.

    Копию уже могли раздать со страниц — кнопка «скачать с нашего сервера»
    у людей пропадёт, поэтому спрашиваем.
    """
    query = update.callback_query
    user_id = _uid(update)
    data = str(query.data)
    do = data.startswith("mr_del_do~")
    parts = data.split("~")
    if len(parts) != 3 or not valid_app_id(parts[1]) or not valid_platform(parts[2]):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    app, platform = parts[1], parts[2]
    label = platform_label(user_id, platform)
    await query.answer()
    if not do:
        rows = [[btn(_t(user_id, "btn_confirm"), "mr_del_do~%s~%s" % (app, platform))], _back_row(user_id, "se_mirror")]
        await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_tf(user_id, "mr_remove_btn_fmt", esc(app), esc(label)),
                                                          _tf(user_id, "mr_remove_confirm_fmt", esc(app), esc(label))),
                                reply_markup=InlineKeyboardMarkup(rows))
        return
    if await _action_busy(query, user_id, "se_mirror"):
        return
    r = await mutate("mirror-remove", who=user_id, app=app, platform=platform)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "se_mirror")
        return
    logger.info("mirror copy removed: %s/%s", app, platform)
    await safe_edit_message(query, "✅ " + _tf(user_id, "mr_removed_fmt", esc(app), esc(label)),
                            reply_markup=back_kb(user_id, "se_mirror"))


async def cb_user_delete(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Удаление — только фразой `DELETE <name>` в течение 60 секунд."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    name = _name_from_data(query.data, "u_del~")
    if not name:
        await show_bad_input(query, user_id, "menu_users")
        return
    await arm_typed_confirm(query, context, user_id, "user-del", name, back_to="u_view~%s" % name,
                            warn=_tf(user_id, "user_delete_warn_fmt", esc(name)))


async def arm_typed_confirm(query, context, user_id: Optional[int], kind: str, target: str,
                            back_to: str, warn: str, extra: Optional[Dict[str, Any]] = None,
                            rows: Optional[List[list]] = None) -> None:
    """Ожидание фразы подтверждения; rows — кнопки выбора над «Отмена» (у «Переставить на 2.0» — ключ остальным)."""
    phrase = await typed_phrase(kind, target)
    CONFIRM.arm(int(user_id), kind, target, phrase, extra)
    flow_clear(context)
    text = "<b>%s</b>\n\n%s\n\n%s" % (
        _t(user_id, "confirm_title"), warn,
        confirm_type_text(user_id, phrase))
    await safe_edit_message(query, text, reply_markup=InlineKeyboardMarkup(
        list(rows or []) + [[btn(_t(user_id, "btn_cancel"), "tc_cancel~%s" % back_to)]]))


async def drop_confirm_buttons(context, rec: Dict[str, Any]) -> None:
    """Фраза принята — снять кнопки с вопроса (BL-1): выбор и «Отмена» над уже идущим действием только путают. Сообщение
    удалили или оно уже без кнопок — не беда, действие от этого не зависит."""
    chat_id, message_id = (rec.get("msg") or (None, None))
    bot_api = getattr(context, "bot", None)
    if chat_id is None or message_id is None or bot_api is None:
        return
    try:
        await bot_api.edit_message_reply_markup(chat_id=chat_id, message_id=message_id, reply_markup=None)
    except Exception as e:     # noqa: BLE001 — «message is not modified», «not found»: кнопок уже нет
        logger.debug("Confirm buttons not removed: %s", e)


async def cb_typed_cancel(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """tc_cancel~<callback назад>: снять ожидание фразы и вернуться на прежний экран."""
    query = update.callback_query
    user_id = _uid(update)
    qmsg = getattr(query, "message", None)
    if CONFIRM.accepted_recently(int(user_id), (getattr(qmsg, "chat_id", None), getattr(qmsg, "message_id", None))):
        # Фраза уже принята, действие идёт или прошло (RB-2): «Отменено» было бы неправдой. Кнопку, если она ещё здесь
        # (сообщение не удалось поправить), снимаем.
        await query.answer(_t(user_id, "confirm_already_accepted"), show_alert=True)
        try:
            await query.edit_message_reply_markup(reply_markup=None)
        except Exception as e:     # noqa: BLE001
            logger.debug("Confirm buttons not removed: %s", e)
        return
    CONFIRM.cancel(int(user_id))
    back_to = query.data.split("~", 1)[1] if "~" in query.data else "menu_main"
    await query.answer(_t(user_id, "cancelled"))
    await dispatch_callback_data(update, context, back_to)


async def run_typed_confirm(update: Update, context: ContextTypes.DEFAULT_TYPE, rec: Dict[str, Any]) -> None:
    """Фраза совпала — выполнить действие, которое ждало подтверждения."""
    user_id = _uid(update)
    kind, target, extra = rec["kind"], rec["target"], rec.get("extra") or {}
    message = update.message
    # Кнопки сверх «Назад»: их ставит та ветка, после которой человеку нужен следующий шаг,
    # а не просто выход (смена режима на Pro — перенос UDP-порта на 443).
    extra_rows: List[list] = []
    await _queued_notice(message, user_id)     # фраза уже принята: действие ждёт замок
    if kind == "user-del" and valid_name(target):
        await message.reply_text("⏳ " + _t(user_id, "wait"))
        r = await mutate("user-del", who=user_id, name=target)
        ok_text = "✅ " + _tf(user_id, "user_deleted_fmt", esc(target))
        back_to = "menu_users"
    elif kind == "users-del-bulk" and parse_bulk_count(target) is not None and \
            bulk_del_selection_ok(str(extra.get("mode") or ""), str(extra.get("value") or "")):
        # «Удалить сразу несколько»: DELETE <число людей>; выбор — тот, что был показан (способ и значение)
        await _user_bulk_del_run(message, user_id, target, str(extra.get("mode")), str(extra.get("value")))
        return
    elif kind == "profile-remove" and valid_profile(target):
        await message.reply_text("⏳ " + _tf(user_id, "pr_removing_fmt", esc(profile_name(user_id, target))))
        r = await mutate("profile-remove", who=user_id, profile=target)
        ok_text = "✅ " + esc(r.get("message") or _t(user_id, "done"))
        back_to = "sec_protocols"
    elif kind == "profile-subnet-adopted" and valid_profile(target) and valid_subnet(str(extra.get("subnet") or "")):
        # SUBNET <профиль>: смена подсети подхваченного профиля с людьми приложения без ключа — согласие за них
        # (--adopted-confirm, ACC-2); это и выход из пересечения подсетей (SUBNET-01).
        subnet = str(extra.get("subnet"))
        await message.reply_text("⏳ " + _tf(user_id, "pr_subnet_changing_fmt", esc(profile_name(user_id, target)), esc(subnet)))
        r = await mutate("profile-subnet", who=user_id, profile=target, subnet=subnet, adopted_confirm=target)
        ok_text = "✅ " + esc(r.get("message") or _t(user_id, "done"))
        back_to = "pr_card~%s" % target
    elif kind == "profile-fix-s4-adopted" and valid_profile(target):
        # S4 <профиль>: «Исправить S4» у подхваченного профиля с людьми приложения без ключа на сервере — согласие за них
        # (--adopted-confirm, ACC-2). Итог — тот же, что у кнопки: кому что делать.
        await message.reply_text("⏳ " + _tf(user_id, "pr_s4_fixing_fmt", esc(profile_name(user_id, target))))
        r = await mutate("profile-fix-s4", who=user_id, profile=target, adopted_confirm=target)
        ok_text = s4_fix_result_text(user_id, r) if bridge_ok(r) else ""
        back_to = "pr_card~%s" % target
    elif kind == "profile-reline" and valid_profile(target) and str(extra.get("line") or "") in RELINE_LINES:
        # RELINE <профиль>: «Переставить на 2.0» (DUP-LINE-01) — удаление и установка на недостающую линию пары, тот же порт и
        # подсеть, людям — новые ключи. Итог — кому что делать, как у «Исправить S4»; отказы ядра (reline_rolled_back,
        # reline_adopted…) — его словами.
        # Ключ остальным (выбор на экране согласия) — тем же действием ядра (keys_to_others, DUPLINE-KEYS-01): итог
        # называет, кому выдан и у кого ошибка (шаги others / others_failed), второго вопроса и выдачи из бота нет.
        line = str(extra.get("line"))
        await message.reply_text("⏳ " + _tf(user_id, "pr_rl_running_fmt", esc(profile_title(user_id, target)), line))
        r = await mutate("profile-reline", who=user_id, profile=target, line=line,
                         keys_to_others="on" if extra.get("keys") == "on" else None)
        ok_text = reline_result_text(user_id, r) if bridge_ok(r) else ""
        back_to = "pr_card~%s" % target
    elif kind == "profile-regen" and valid_profile(target):
        preset = str(extra.get("preset") or "default")
        if preset not in PRESETS:
            preset = "default"
        await message.reply_text("⏳ " + _tf(user_id, "pr_regenerating_fmt", esc(profile_name(user_id, target))))
        r = await mutate("profile-regen", who=user_id, profile=target, preset=preset)
        ok_text = "✅ " + esc(r.get("message") or _t(user_id, "done")) + "\n" + _t(user_id, "pr_regen_done_hint")
        back_to = "pr_card~%s" % target
    elif kind == "backup-restore" and valid_backup_file(target):
        await message.reply_text("⏳ " + _tf(user_id, "mt_restoring_fmt", esc(target)))
        r = await mutate("backup-restore", who=user_id, file=target)
        ok_text = "✅ " + esc(r.get("message") or _t(user_id, "done"))
        back_to = "sec_maint"
    elif kind == "agent-del" and valid_agent_id(target):
        await message.reply_text("⏳ " + _t(user_id, "wait"))
        r = await mutate("agent-del", who=user_id, id=target)
        ok_text = "✅ " + _tf(user_id, "ag_deleted_fmt", esc(target))
        back_to = "se_agents"
    elif kind == "upstream-update" and valid_profile(target):
        # До 15 минут: бэкап, скрипты, pull образа, пересоздание контейнера,
        # проверка; при провале мост сам откатывает.
        await message.reply_text("⏳ " + _tf(user_id, "up_updating_fmt", esc(profile_name(user_id, target))))
        r = await mutate("upstream-update", who=user_id, profile=target)
        ok_text = "✅ " + esc(r.get("message") or _t(user_id, "done"))
        names = sorted({str(u.get("name")) for u in (((r.get("scripts") or {}).get("unsupported")) or [])
                        if isinstance(u, dict) and u.get("name")})
        if names:
            ok_text += "\n⚠️ " + _tf(user_id, "up_unsupported_fmt", esc(", ".join(names)))
        back_to = "mt_upstream"
    elif kind == "upstream-rollback" and valid_profile(target):
        await message.reply_text("⏳ " + _tf(user_id, "up_rolling_back_fmt", esc(profile_name(user_id, target))))
        r = await mutate("upstream-rollback", who=user_id, profile=target)
        ok_text = "✅ " + esc(r.get("message") or _t(user_id, "done"))
        back_to = "mt_upstream"
    elif kind == "core-update" and valid_profile(target):
        # Тот же таймаут, что у обновления: pull образа и пересоздание контейнера.
        await message.reply_text("⏳ " + _tf(user_id, "up_repairing_fmt", esc(profile_name(user_id, target))))
        r = await mutate("core-update", who=user_id, profile=target)
        ok_text = "✅ " + esc(r.get("message") or _t(user_id, "done"))
        back_to = "mt_upstream"
    elif kind == "change-mode" and valid_mode(target):
        # До минуты: certbot, сборка vhost, перезапуск nginx. Домен передаём,
        # только если он есть: пустой --domain= мост читает как «взять из конфига».
        # Между режимами с сайтом домена в extra нет (_arm_mode_confirm): мост
        # меняет лишь запись режима, и «сертификат, сайт, nginx» тут не к месту.
        domain = str(extra.get("domain") or "")
        switch_only = target in MODES_WITH_SITE and str(extra.get("current") or "") in MODES_WITH_SITE and not domain
        await message.reply_text("⏳ " + (_t(user_id, "wait") if switch_only else
                                         _tf(user_id, "se_mode_switching_fmt", esc(mode_label(user_id, target)))))
        r = await mutate("change-mode", who=user_id, mode=target,
                         domain=domain if valid_host(domain) and domain else None)
        ok_text = "✅ " + esc(r.get("message") or _t(user_id, "done"))
        if target in MODES_WITH_SITE:
            ok_text += "\n\n" + _t(user_id, "se_mode_done_hint")
        back_to = "se_mode"
        if bridge_ok(r):
            # Сам change-mode UDP-порт профиля не двигает НИКОГДА. В Pro линию на UDP 443 человек выбрал до фразы
            # (F-3, сцена mode-pro-line) — её ставит pro-line сразу после смены режима. Выбора не было или линия
            # уже на 443 — как раньше: расхождение режима и порта называем словами и даём кнопку следующего шага.
            line = str(extra.get("line") or "")
            tried = False
            if target == "pro" and valid_profile(line) and \
                    str(profile_info(await get_status(fresh=True), line).get("port") or "") != "443":
                tried = True
                moved, line_text, extra_rows = await _pro_line_step(message, user_id, line)
                ok_text += "\n\n" + (line_text if moved else _t(user_id, "pl_failed") + "\n" + line_text)
            if not tried:
                hint, extra_rows = await mode_port_rows(user_id, target)
                if hint:
                    ok_text += "\n\n⚠️ " + hint
            if target in MODES_WITH_SITE:
                # Подсказка «проверьте сайт» — кнопкой (сцены mode-done, mode-fallback)
                extra_rows = [[btn(_t(user_id, "se_site_check"), "se_check")]] + list(extra_rows)
    elif kind == "change-template" and target == "site":
        template = str(extra.get("template") or "")
        if not valid_template_id(template):
            await message.reply_text("❌ " + _t(user_id, "err_bad_input"))
            return
        # Клон шаблона с GitHub и развёртывание в web root — до пары минут.
        await message.reply_text("⏳ " + _t(user_id, "tpl_deploying"))
        r = await mutate("change-template", who=user_id, template=template)
        ok_text = "✅ " + esc(r.get("message") or _t(user_id, "done"))
        back_to = "se_mode"
    elif kind == "lazy-setup" and valid_domain(target):
        # Ленивый Pro, шаги 4–5: весь сценарий одним действием моста — до получаса (сертификат, сайт, образы,
        # ключи). Очередь за замком бота — _queued_notice выше; замок SSH, панели или агента — lock_timeout (⏳).
        await message.reply_text("⏳ " + _tf(user_id, "lazy_running_fmt", esc(extra.get("display") or target)),
                                 parse_mode="HTML")
        r = await mutate("lazy-setup", who=user_id, domain=target, keys=LAZY_KEYS)
        await _lazy_setup_reply(message, context, user_id, target, r, extra)
        return
    elif (kind == "pro-line" and valid_profile(target)) or \
            (kind == "pro-line-adopted" and valid_profile(target) and valid_profile(str(extra.get("line") or ""))):
        # Линия на UDP 443 в Pro (F-3): LINE <профиль> — эта линия; MOVE <профиль> — перенос подхваченного у
        # приложения профиля с людьми без ключа на сервере (--adopted-confirm, ACC-2). Итог и отказы — свои.
        line, adopted = (target, "") if kind == "pro-line" else (str(extra.get("line")), target)
        _, text, rows = await _pro_line_step(message, user_id, line, adopted)
        await message.reply_text(text, parse_mode="HTML",
                                 reply_markup=InlineKeyboardMarkup(rows + [_back_row(user_id, "se_mode")]))
        return
    elif kind == "sub-rotate" and valid_name(target):
        # Подписка (ROTATE <имя>): новый адрес — сразу следующим сообщением, прежний уже отвечает 404.
        await message.reply_text("⏳ " + _t(user_id, "wait"))
        r = await mutate("sub-rotate", who=user_id, name=target)
        if bridge_ok(r):
            logger.info("subscription of %s rotated", target)
            clients = sub_clients(r)
            if clients:
                # Выбор по клиенту: новые адреса — по кнопке приложения (sub-show), в этом сообщении их нет
                await message.reply_text(sub_chooser_text(user_id, r, clients, head="✅ " + _t(user_id, "sub_rotated_pick")),
                                         parse_mode="HTML", reply_markup=sub_chooser_keyboard(user_id, target, clients))
                return
            await message.reply_text("✅ " + _t(user_id, "sub_rotated_ok"), parse_mode="HTML",
                                     reply_markup=back_kb(user_id, "u_sub~%s" % target))
            if not await send_sub_links(message, user_id, r):
                await message.reply_text("❌ " + _t(user_id, "sub_send_failed"),
                                         reply_markup=back_kb(user_id, "u_sub~%s" % target))
            return
        ok_text = ""
        back_to = "u_sub~%s" % target
    elif kind == "sub-revoke" and valid_name(target):
        await message.reply_text("⏳ " + _t(user_id, "wait"))
        r = await mutate("sub-revoke", who=user_id, name=target)
        if bridge_ok(r):
            logger.info("subscription of %s revoked", target)
        ok_text = "✅ " + _tf(user_id, "sub_revoked_ok_fmt", esc(target))
        back_to = "u_view~%s" % target
    else:
        await message.reply_text("❌ " + _t(user_id, "err_bad_input"))
        return
    if bridge_ok(r):
        text = ok_text
    elif kind == "change-mode":
        # Отказ Let's Encrypt — своими словами по причине; режим, сайт и домен мост вернул как были (L-26)
        text = cert_fail_text(user_id, r, str(extra.get("domain") or ""), kept=True)
    else:
        text = fail_text(user_id, r)
    markup = back_kb(user_id, back_to)
    if extra_rows and bridge_ok(r):
        markup = InlineKeyboardMarkup(extra_rows + [_back_row(user_id, back_to)])
    await message.reply_text(text, parse_mode="HTML", reply_markup=markup)
    if kind == "change-mode" and bridge_ok(r):
        # Сайт снят или поднят — панель на домене ушла или появилась вместе с ним.
        await refresh_menu_button_after(context)


async def _lazy_setup_reply(message, context, user_id: Optional[int], domain: str, r: Dict[str, Any],
                            extra: Dict[str, Any]) -> None:
    """Ленивый Pro, шаг 5: итог и страницы подключения — или отказ с планом и причинами, как на шаге проверки."""
    if not bridge_ok(r):
        if str(r.get("code") or "") == "unknown_action":
            # Ядро старше бота — «после обновления», а не ошибка
            text, markup = _t(user_id, "lazy_unsupported"), back_kb(user_id, "se_mode")
        else:
            text, markup = lazy_refusal_view(user_id, r, str(extra.get("display") or domain))
        await message.reply_text(text, parse_mode="HTML", reply_markup=markup)
        return
    logger.info("lazy setup on %s: mode %s, keys %d", domain, r.get("mode"), len(lazy_keys(r)))
    text, rows = lazy_result_view(user_id, r, extra.get("before"), str(extra.get("display") or ""))
    await message.reply_text(text, parse_mode="HTML",
                             reply_markup=InlineKeyboardMarkup(rows + [_back_row(user_id, "se_mode")]))
    # Страницы подключения — отдельным сообщением после итога, без превью: Telegram сходил бы по адресу сам, и
    # страница засчитала бы открытие. Адреса — ключи людей, в лог их не пишем.
    pages = lazy_pages_text(user_id, r)
    if pages:
        await message.reply_text(pages, parse_mode="HTML", disable_web_page_preview=True)
    # Сайт поднят — панель на домене появилась вместе с ним
    await refresh_menu_button_after(context)


# ============================================================================
# РАЗДЕЛ 2: СОСТОЯНИЕ — Статус · Трафик · Логи · Адреса
# ============================================================================

async def cb_sec_state(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    rows = [
        [btn(_t(user_id, "st_item_status"), "st_status"), btn(_t(user_id, "st_item_traffic"), "st_traffic")],
        [btn(_t(user_id, "st_item_logs"), "st_logs"), btn(_t(user_id, "st_item_addr"), "st_addr")],
        _back_row(user_id),
    ]
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "st_title"), _t(user_id, "sec_state_hint")),
                            reply_markup=kb(rows))


def status_report_text(user_id: Optional[int], status: Dict[str, Any]) -> str:
    lines = ["<b>%s</b>" % _t(user_id, "st_report_title"), ""]
    profiles = status_profiles(status)
    if not profiles:
        lines.append("<i>%s</i>" % _t(user_id, "dash_no_profiles"))
    for p in profiles:
        state = str(p.get("state") or "missing")
        state_key = profile_state_key(state)
        lines.append("%s <b>%s</b> — %s" % (profile_icon(state), esc(profile_name(user_id, p.get("profile"), status)),
                                           _t(user_id, state_key)))
        lines.append("   %s %s · %s %s · %s %s" % (
            _t(user_id, "pr_port"), esc(p.get("port") or "—"),
            _t(user_id, "pr_line"), esc(p.get("line") or "—"),
            _t(user_id, "pr_peers"), esc(p.get("peers") if p.get("peers") is not None else 0)))
        tag = core_ver_words(user_id, p)
        if tag:
            lines.append("   %s %s" % (_t(user_id, "pr_core_ver"), esc(tag)))
    lines.append("")
    lines.append("%s: <b>%s</b>" % (_t(user_id, "st_users"), esc(status.get("users") or 0)))
    lines.append("%s <b>%s</b> · %s <code>%s</code>" % (
        _t(user_id, "dash_mode"), esc(mode_label(user_id, status.get("mode"))),
        _t(user_id, "about_version"), esc(product_version(status))))
    return "\n".join(lines)


async def cb_st_status(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    status = await get_status(fresh=True)
    if not bridge_ok(status):
        await show_error(query, user_id, status, "sec_state")
        return
    await safe_edit_message(query, status_report_text(user_id, status),
                            reply_markup=InlineKeyboardMarkup([[btn(_t(user_id, "btn_refresh"), "st_status")],
                                                               _back_row(user_id, "sec_state")]))


def _as_int(value: Any) -> int:
    """Число из ответа моста; мусор (не число) — 0, а не падение экрана."""
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


# Сообщение Telegram — до 4096 знаков после разбора разметки. Экраны со списками
# держим с запасом и режем только по границе строки (clip_lines).
MESSAGE_SOFT_LIMIT = 3900
# Пиров на профиль на экране трафика: сначала онлайн, потом самые активные.
TRAFFIC_PEERS_PER_PROFILE = 10
_HTML_TAG_RE = re.compile(r"<(/?)(b|i|u|s|code|pre|a|tg-spoiler|blockquote)(?:\s[^>]*)?>")
_ANY_TAG_RE = re.compile(r"<[^>]*>")


def _tag_depth_delta(line: str) -> int:
    depth = 0
    for m in _HTML_TAG_RE.finditer(line):
        depth += -1 if m.group(1) else 1
    return depth


def visible_len(text: str) -> int:
    """Длина так, как её считает Telegram: без тегов, «&lt;» — один знак."""
    return len(html.unescape(_ANY_TAG_RE.sub("", text)))


def clip_lines(text: str, limit: int = MESSAGE_SOFT_LIMIT) -> str:
    """Обрезать HTML-текст экрана по границе строки и «…» в конце.

    Срез `text[:3900]` резал посреди строки: внутри <code>…</code> или прямо в
    «<co» — Telegram отвечал «Can't parse entities», экран не рисовался, и человек
    получал «Внутреннюю ошибку». Здесь режем только там, где ни один тег не открыт.
    Меряем видимую длину: лог в <pre> с «&lt;» в каждой строке по сырой длине
    вдвое длиннее, чем для Telegram, и резался бы зря.
    """
    if visible_len(text) <= limit:
        return text
    kept: List[str] = []
    size, depth, safe = 0, 0, 0
    for line in text.split("\n"):
        add = visible_len(line) + (1 if kept else 0)
        if size + add > limit - 2:
            break
        kept.append(line)
        size += add
        depth += _tag_depth_delta(line)
        if depth == 0:
            safe = len(kept)
    return "\n".join(kept[:safe] + ["…"])


def traffic_text(user_id: Optional[int], r: Dict[str, Any], limit: int = MESSAGE_SOFT_LIMIT) -> str:
    """traffic: profiles[{profile, peers[{pubkey, latest_handshake_ts, rx, tx}]}], users[].

    Влезает в сообщение — показываем всё. Не влезает — пиров на профиль не больше
    TRAFFIC_PEERS_PER_PROFILE (онлайн и самые активные — первыми), пользователей —
    сколько войдёт остатком места, с «… и ещё N». Раньше при нескольких десятках
    человек весь лимит съедали пиры первого профиля, строка «онлайн сейчас» и
    итоги не показывались вовсе, а срез посреди строки ронял экран.
    """
    lines = ["<b>%s</b>" % _t(user_id, "st_traffic_title"), ""]
    users = r.get("users") if isinstance(r.get("users"), list) else []
    # pubkey → имя пользователя, чтобы в списке пиров стояли имена, а не ключи
    owner: Dict[str, str] = {}
    for u in users:
        if not isinstance(u, dict):
            continue
        peers_map = u.get("peers") if isinstance(u.get("peers"), dict) else {}
        for profile, peer in peers_map.items():
            if isinstance(peer, dict) and peer.get("pubkey"):
                owner[str(peer["pubkey"])] = str(u.get("name") or "?")
    now = int(time.time())
    profiles = r.get("profiles") if isinstance(r.get("profiles"), list) else []
    online_total = 0
    blocks = []   # (заголовок профиля, строки пиров: онлайн и самые активные — первыми)
    for p in profiles:
        if not isinstance(p, dict):
            continue
        peers = [x for x in (p.get("peers") if isinstance(p.get("peers"), list) else []) if isinstance(x, dict)]
        # Счётчики пиров живые — с запуска контейнера; итоги по пользователям ниже копятся между перезапусками,
        # и без подписи одно спорило с другим.
        header = "<b>%s</b> · %s · %s" % (esc(profile_name(user_id, p.get("profile"))), _tf(user_id, "peers_count_fmt", len(peers)),
                                          _t(user_id, "st_traffic_live_note"))
        rows = []
        for peer in peers:
            hs = _as_int(peer.get("latest_handshake_ts"))
            # Онлайн = рукопожатие моложе трёх минут (PLAN §5.1)
            online = hs > 0 and (now - hs) < 180
            online_total += 1 if online else 0
            who = owner.get(str(peer.get("pubkey") or ""), str(peer.get("pubkey") or "")[:12])
            # ↓ — скачано пользователем (сервер отдал, tx), ↑ — отдано (rx): как итоги ниже, панель и SSH (A2-12, R-3)
            rows.append((not online, -(_as_int(peer.get("rx")) + _as_int(peer.get("tx"))),
                         "  %s <code>%s</code> ↓ %s ↑ %s" % (
                             "●" if online else "○", esc(who),
                             human_bytes(peer.get("tx"), user_id), human_bytes(peer.get("rx"), user_id))))
        rows.sort(key=lambda x: (x[0], x[1]))
        blocks.append((header, [row[2] for row in rows]))

    def peer_lines(cap: Optional[int]) -> List[str]:
        out = []
        for header, rows in blocks:
            out.append(header)
            shown = rows if cap is None else rows[:cap]
            out.extend(shown)
            if len(rows) > len(shown):
                out.append("  " + _tf(user_id, "st_traffic_more_fmt", len(rows) - len(shown)))
        if not profiles:
            out.append("<i>%s</i>" % _t(user_id, "dash_no_profiles"))
        return out

    tail = ["", _tf(user_id, "online_now_fmt", online_total)]
    # Суточные итоги из stats.json (таймер goamnezia-stats): за сегодня и за
    # календарный месяц; старое ядро без модуля отдаёт null — строку не рисуем.
    today = r.get("today") if isinstance(r.get("today"), dict) else None
    month = r.get("month") if isinstance(r.get("month"), dict) else None
    if today or month:
        # ↓ — скачано пользователями (сервер отдал, tx), ↑ — отдано (rx): та же точка зрения, что в панели и SSH (A2-12)
        tail.append(_tf(user_id, "st_traffic_today_fmt",
                        human_bytes((today or {}).get("tx"), user_id), human_bytes((today or {}).get("rx"), user_id),
                        human_bytes((month or {}).get("tx"), user_id), human_bytes((month or {}).get("rx"), user_id)))
    tail.extend(["", "<b>%s</b>" % _t(user_id, "st_traffic_users")])
    ordered = users_sorted(users)

    def used(u: Dict[str, Any]) -> int:
        traffic = u.get("traffic") if isinstance(u.get("traffic"), dict) else {}
        return _as_int(traffic.get("rx")) + _as_int(traffic.get("tx"))

    user_lines = []
    for u in ordered:
        quota = _as_int(u.get("quota_bytes"))
        quota_txt = " / %s" % human_bytes(quota, user_id) if quota else ""
        user_lines.append("  %s <code>%s</code> %s%s" % (user_icon(u), esc(u.get("name")), human_bytes(used(u), user_id), quota_txt))
    if not users:
        user_lines.append("<i>%s</i>" % _t(user_id, "users_none"))
    # Влезает целиком — показываем всё, как раньше; иначе пиров по TRAFFIC_PEERS_PER_PROFILE.
    whole = lines + peer_lines(None) + tail + user_lines
    if len("\n".join(whole)) <= limit:
        return "\n".join(whole)
    lines = lines + peer_lines(TRAFFIC_PEERS_PER_PROFILE) + tail
    if not users:
        lines.extend(user_lines)
        return clip_lines("\n".join(lines), limit)
    size = len("\n".join(lines))
    more_reserve = len(_tf(user_id, "st_traffic_more_fmt", len(ordered))) + 8
    if size + len("\n".join(user_lines)) + 1 > limit:
        # Всех не показать — показываем самых активных, сколько влезает, и число остальных.
        by_use = sorted(range(len(ordered)), key=lambda i: -used(ordered[i]))
        shown = 0
        for i in by_use:
            if size + len(user_lines[i]) + 1 + more_reserve > limit:
                break
            size += len(user_lines[i]) + 1
            shown += 1
        keep = set(by_use[:shown])
        lines.extend(user_lines[i] for i in range(len(ordered)) if i in keep)
        lines.append("  " + _tf(user_id, "st_traffic_more_fmt", len(ordered) - shown))
    else:
        lines.extend(user_lines)
    return clip_lines("\n".join(lines), limit)


async def cb_st_traffic(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    r = await run_bot_action("traffic", timeout=90)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "sec_state")
        return
    await safe_edit_message(query, traffic_text(user_id, r),
                            reply_markup=InlineKeyboardMarkup([[btn(_t(user_id, "btn_refresh"), "st_traffic")],
                                                               _back_row(user_id, "sec_state")]))


# Компонент лога → ключ словаря с человеческим названием. Профили называются так же,
# как в карточке профиля (profile_title), — «awg2» на экране логов ничего не значит
# человеку, который в остальном боте видит «AmneziaWG 2.0».
LOG_COMPONENT_KEYS = {"bot": "st_logs_bot", "admin": "st_logs_admin", "system": "st_logs_system",
                      "nginx": "st_logs_nginx", "mcp": "st_logs_mcp"}


def log_component_label(user_id: Optional[int], comp: str) -> str:
    """Название компонента для кнопки и заголовка; неизвестный код — как есть."""
    if comp in PROFILE_IDS:
        return profile_title(user_id, comp)
    key = LOG_COMPONENT_KEYS.get(comp)
    return _t(user_id, key) if key else comp


def log_components_for(status: Dict[str, Any]) -> List[str]:
    """Компоненты, которые на этом сервере есть: nginx в режиме без сайта только вернёт пустой лог и зря займёт
    кнопку. Профилей AmneziaWG здесь нет вовсе: продукт запускает их контейнеры без логов (--log-driver none, как и
    само приложение Amnezia), и кнопка вела в заведомое «❌ логи отключены» (живая проверка на test1, 03.10) — вместо
    кнопок экран говорит это одной строкой (st_logs_awg_off)."""
    mode = str(status.get("mode") or "")
    out = []
    for comp in LOG_COMPONENTS:
        if comp in PROFILE_IDS:
            continue
        if comp == "nginx" and mode == "lite":
            continue
        out.append(comp)
    return out


async def cb_st_logs(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    status = await get_status()
    rows, row = [], []
    for comp in log_components_for(status):
        row.append(btn(log_component_label(user_id, comp), "st_log~%s" % comp))
        if len(row) == 2:
            rows.append(row)
            row = []
    if row:
        rows.append(row)
    rows.append(_back_row(user_id, "sec_state"))
    text = "<b>%s</b>" % _t(user_id, "st_logs_title")
    if installed_profiles(status):
        text += "\n\nℹ️ " + _t(user_id, "st_logs_awg_off")
    # kb(): длинные названия уезжают на свою строку, короткие («бот», «панель», «система») остаются парами
    await safe_edit_message(query, text, reply_markup=kb(rows))


LOG_LINES = 60
LOG_MAX_CHARS = 3500


async def cb_st_log(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    comp = query.data.split("~", 1)[1] if "~" in query.data else ""
    if comp not in LOG_COMPONENTS:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    r = await run_bot_action("logs-tail", timeout=60, component=comp, lines=LOG_LINES)
    if str(r.get("code") or "") == "logs_driver_unreadable":
        # Логи контейнера отключены при запуске — так задумано, не сбой: пояснение без ❌ (старая кнопка профиля)
        await safe_edit_message(query, "<b>%s</b>\n\nℹ️ %s" % (_tf(user_id, "st_log_title_fmt", esc(log_component_label(user_id, comp))),
                                                               _t(user_id, "st_logs_awg_off")),
                                reply_markup=back_kb(user_id, "st_logs"))
        return
    if not bridge_ok(r):
        await show_error(query, user_id, r, "st_logs")
        return
    label = log_component_label(user_id, comp)
    log = str(r.get("log") or "").strip()
    if not log:
        body = "<i>%s</i>" % _tf(user_id, "st_logs_empty_fmt", esc(label))
    else:
        if len(log) > LOG_MAX_CHARS:
            log = "…" + log[-LOG_MAX_CHARS:]
        body = "<pre>%s</pre>" % esc(log)
    await safe_edit_message(query, "<b>%s</b>\n%s" % (_tf(user_id, "st_log_title_fmt", esc(label)), body),
                            reply_markup=InlineKeyboardMarkup([[btn(_t(user_id, "btn_refresh"), "st_log~%s" % comp)],
                                                               _back_row(user_id, "st_logs")]))


# Таблица по адресам — как в goTelegram: пакеты клиентов по каждому внешнему адресу и вердикт сторожа.
# Потолок строк: сообщение Telegram обрывается на 4096 символах.
EDGE_MAX_ROWS = 20


def _edge_num(value: Any) -> str:
    try:
        n = int(value or 0)
    except (TypeError, ValueError):
        return "—"
    if n >= 1000000:
        return "%.1fM" % (n / 1000000.0)
    if n >= 1000:
        return "%.1fK" % (n / 1000.0)
    return str(n)


def _edge_mark(user_id: Optional[int], verdict: Any) -> str:
    if verdict == "ok":
        return _t(user_id, "edge_v_ok")
    if verdict == "dark":
        return _t(user_id, "edge_v_dark")
    if verdict == "quiet-all":
        return _t(user_id, "edge_v_quiet_all")
    if verdict == "unused":
        return _t(user_id, "edge_v_unused")
    return _t(user_id, "edge_v_quiet")


def _edge_bytes(value: Any, user_id: Optional[int]) -> str:
    try:
        n = int(value or 0)
    except (TypeError, ValueError):
        n = 0
    return human_bytes(n, user_id) if n > 0 else "0"


def edge_table_lines(user_id: Optional[int], edge: Optional[Dict[str, Any]]) -> List[str]:
    """Строки таблицы адресов; пусто, когда адрес у машины один (сообщать нечего)."""
    edge = edge if isinstance(edge, dict) else {}
    ips = [e for e in (edge.get("ips") or []) if isinstance(e, dict)]
    try:
        count = int(edge.get("count") or 0)
    except (TypeError, ValueError):
        count = 0
    dns = edge.get("dns") if isinstance(edge.get("dns"), dict) else None
    if dns and dns.get("state") == "unknown":
        dns = None
    warn = edge_dns_warn_lines(user_id, dns)
    if count < 2 or not ips:
        # Адрес один — таблицы нет, но беда с A-записями домена из ключей показывается, как в SSH-шапке
        return ([""] + warn) if warn else []
    head = "%-16s%9s%9s%9s" % (_t(user_id, "edge_col_addr"), _t(user_id, "edge_col_15m"),
                               _t(user_id, "edge_col_1h"), _t(user_id, "edge_col_1d"))
    lines = ["", "<b>%s</b>" % _t(user_id, "edge_table_title"), "<code>%s</code>" % esc(head)]
    # Ключи на домене — пометка, есть ли адрес в A-записях (клиенты по домену приходят только на
    # опубликованные адреса), и беда с A-записями отдельными строками — как в SSH-шапке.
    for e in ips[:EDGE_MAX_ROWS]:
        # Входящий трафик клиентов в байтах (владелец: «пакеты не интересны»); у старого ядра байтов нет — пакеты.
        if "bytes_day" in e:
            row = "%-16s%9s%9s%9s" % (str(e.get("ip") or "")[:16], _edge_bytes(e.get("bytes_15m"), user_id),
                                      _edge_bytes(e.get("bytes_1h"), user_id), _edge_bytes(e.get("bytes_day"), user_id))
        else:
            row = "%-16s%8s%8s%8s" % (str(e.get("ip") or "")[:16], _edge_num(e.get("packets_15m")),
                                      _edge_num(e.get("packets_1h")), _edge_num(e.get("packets_day")))
        mark = _edge_mark(user_id, e.get("verdict"))
        if dns is not None:
            mark += " · " + _t(user_id, "edge_dns_in" if e.get("in_dns") is True else "edge_dns_out")
        lines.append("<code>%s</code> %s" % (esc(row), esc(mark)))
    lines.extend(warn)
    lines.append("<i>%s</i>" % esc(_t(user_id, "edge_hint")))
    return lines


def edge_dns_warn_lines(user_id: Optional[int], dns: Optional[Dict[str, Any]]) -> List[str]:
    """Что не так с A-записями домена из ключей — строками с ⚠️ (те же случаи, что в SSH-шапке)."""
    if not dns:
        return []
    dom = str(dns.get("domain") or "")
    st = str(dns.get("state") or "")
    if st in ("elsewhere", "partial") and dns.get("cloudflare"):
        return ["⚠️ " + esc(_tf(user_id, "edge_dns_cloudflare", dom))]
    if st == "elsewhere":
        return ["⚠️ " + esc(_tf(user_id, "edge_dns_elsewhere", dom, ", ".join(str(a) for a in (dns.get("a") or []))))]
    if st == "none":
        return ["⚠️ " + esc(_tf(user_id, "edge_dns_none", dom))]
    return ["⚠️ " + esc(_tf(user_id, "edge_dns_foreign", dom, str(f))) for f in (dns.get("foreign") or [])[:EDGE_MAX_ROWS]]


def addresses_text(user_id: Optional[int], status: Dict[str, Any],
                   edge: Optional[Dict[str, Any]] = None) -> str:
    ip = str(status.get("server_ip") or "—")
    domain = str(status.get("domain") or "")
    # Адрес в ключах называет ядро (endpoint_effective — та же функция, что собирает ключ). Экран считал его
    # сам, с доменом посередине, и обещал домен там, где в каждом ключе стоял IP.
    endpoint = str(status.get("endpoint_effective") or "") or str(status.get("endpoint_host") or "") or ip
    lines = ["<b>%s</b>" % _t(user_id, "st_addr_title"), ""]
    lines.append("%s: <code>%s</code>" % (_t(user_id, "st_addr_ip"), esc(ip)))
    lines.append("%s: <code>%s</code>" % (_t(user_id, "st_addr_domain"), esc(domain or "—")))
    lines.append("%s: <code>%s</code>" % (_t(user_id, "st_addr_endpoint"), esc(endpoint)))
    # Адрес сайта-маскировки (pro — домен, lite_site — IP с самоподписанным)
    site = status.get("site") if isinstance(status.get("site"), dict) else {}
    if str(site.get("url") or "").strip():
        lines.append("%s <code>%s</code>" % (_t(user_id, "site_url"), esc(str(site.get("url")).strip())))
    lines.append("")
    for p in status_profiles(status):
        # Все профили продукта — AmneziaWG, то есть UDP.
        lines.append("<b>%s</b>  <code>%s:%s/udp</code>" % (esc(profile_name(user_id, p.get("profile"), status)), esc(endpoint),
                                                            esc(p.get("port") or "—")))
    lines.extend(edge_table_lines(user_id, edge))
    return "\n".join(lines)


async def cb_st_addr(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    status = await get_status()
    if not bridge_ok(status):
        await show_error(query, user_id, status, "sec_state")
        return
    edge = await run_bot_action("edge-status", timeout=60)
    await safe_edit_message(query, addresses_text(user_id, status, edge if bridge_ok(edge) else None),
                            reply_markup=back_kb(user_id, "sec_state"))


# ============================================================================
# РАЗДЕЛ 3: ПРОТОКОЛЫ — карточка профиля и её действия
# ============================================================================

async def cb_sec_protocols(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    status = await get_status()
    rows = []
    for p in PROFILE_IDS:
        info = profile_info(status, p)
        icon = profile_icon(info.get("state")) if info else PROFILE_NOT_INSTALLED_ICON
        # Порт и «из приложения» — в самой подписи (DUP-LINE-01), свободное место — «… — не установлена»
        rows.append([btn("%s %s" % (icon, profile_title(user_id, p, status)), "pr_card~%s" % p)])
    # «Переставить … на 2.0» (DUP-LINE-01) — над списком, как быстрые действия главного экрана
    rl = lines_check_of(status)["reline"]
    if rl:
        rows.insert(0, reline_row(user_id, rl, status))
    rows.append(_back_row(user_id))
    text = "<b>%s</b>\n\n%s" % (_t(user_id, "pr_title"), _t(user_id, "pr_legend"))
    warn = lines_check_lines(user_id, status)
    if warn:
        text += "\n\n" + "\n".join(warn)
    if not bridge_ok(status):
        text += "\n\n⚠️ " + error_text(user_id, status)
    await safe_edit_message(query, text, reply_markup=InlineKeyboardMarkup(rows))


def _profile_from_data(data: str, prefix: str) -> str:
    rest = data[len(prefix):] if data.startswith(prefix) else ""
    p = rest.split("~", 1)[0]
    return p if valid_profile(p) else ""


# ── Пересечение подсетей профилей (SUBNET-01) ────────────────────────────────
# Приложение Amnezia ставит все свои контейнеры AmneziaWG на 10.8.1.0/24, и подхват берёт их как есть: у двух профилей
# бывает одна подсеть. Ядро отдаёт это в status.subnet_overlaps — с кем и выход (какой профиль перенести и на какую
# свободную подсеть, сколько его людей с ключами из приложения); карточка профиля и экран подсети говорят это прямо.

def subnet_overlap_of(status: Dict[str, Any], profile: str) -> Dict[str, Any]:
    """Запись пересечения профиля из status.subnet_overlaps: {profile, subnet, with, fixed, move} или {}."""
    items = status.get("subnet_overlaps") if isinstance(status, dict) else None
    for e in items if isinstance(items, list) else []:
        if isinstance(e, dict) and str(e.get("profile") or "") == profile:
            return e
    return {}


def subnet_move_of(e: Dict[str, Any]) -> Dict[str, Any]:
    """Выход из пересечения — {profile, subnet, keyless} с проверенными полями, или {} (свободной подсети нет)."""
    mv = e.get("move") if isinstance(e, dict) and isinstance(e.get("move"), dict) else {}
    p, s = str(mv.get("profile") or ""), str(mv.get("subnet") or "")
    if not valid_profile(p) or not valid_subnet(s):
        return {}
    k = mv.get("keyless")
    return {"profile": p, "subnet": s, "keyless": k if isinstance(k, int) and not isinstance(k, bool) and k > 0 else 0}


def subnet_overlap_text(user_id: Optional[int], e: Dict[str, Any], status: Optional[Dict[str, Any]] = None) -> str:
    """Пересечение словами (HTML): с кем и выход — кого перенести и куда, и что будет с людьми приложения."""
    withs = ", ".join(profile_name(user_id, w, status) for w in (e.get("with") or []) if valid_profile(str(w)))
    sub = str(e.get("subnet") or "?")
    mv = subnet_move_of(e)
    if not mv:
        return _tf(user_id, "pr_overlap_nofree_fmt", esc(sub), esc(withs or "—"))
    text = _tf(user_id, "pr_overlap_fmt", esc(sub), esc(withs or "—"), esc(profile_name(user_id, mv["profile"], status)), esc(mv["subnet"]))
    if mv["keyless"]:
        text += " " + _tf(user_id, "pr_overlap_keyless_fmt", mv["keyless"])
    return text


def subnet_move_row(user_id: Optional[int], mv: Dict[str, Any], status: Optional[Dict[str, Any]] = None) -> list:
    """Кнопка выхода из пересечения: «Перенести <профиль> на <подсеть>» → вопрос (pr_smv~). Подсеть — SUBNET_RE:
    частная сеть с маской /20–/24, не длиннее 16 знаков (192.168.255.0/24) — callback_data укладывается в 64 байта."""
    profile, subnet = mv["profile"], mv["subnet"]
    return [btn(_tf(user_id, "pr_overlap_move_fmt", profile_name(user_id, profile, status), subnet),
                "pr_smv~%s~%s" % (profile, subnet))]


def profile_card_text(user_id: Optional[int], profile: str, status: Dict[str, Any], cfg: Dict[str, Any]) -> str:
    info = profile_info(status, profile)
    cfg_p = (cfg.get("profiles") or {}).get(profile) or {}
    lines = ["<b>%s</b>" % _tf(user_id, "pr_card_title", esc(profile_title(user_id, profile, status))), ""]
    if not info:
        lines.append("%s: %s %s" % (_t(user_id, "pr_state"), PROFILE_NOT_INSTALLED_ICON, _t(user_id, "not_installed")))
        lines.append("")
        lines.append(_t(user_id, "pr_not_installed_hint"))
        return "\n".join(lines)
    state = str(info.get("state") or "missing")
    state_key = profile_state_key(state)
    lines.append("%s: %s %s" % (_t(user_id, "pr_state"), profile_icon(state), _t(user_id, state_key)))
    if state_key == "state_missing":
        # Профиль установлен, а контейнера нет: ставить заново не надо (мост ответит
        # «уже установлен») — контейнер поднимается из копии состояния, ключи прежние.
        lines.append("⚠️ " + _t(user_id, "pr_missing_hint"))
    lines.append("%s: <code>%s</code>    %s: <code>%s</code>" % (
        _t(user_id, "pr_port"), esc(info.get("port") or "—"), _t(user_id, "pr_line"), esc(info.get("line") or "—")))
    subnet = str(cfg_p.get("subnet") or "")
    mtu = str((cfg_p.get("params") or {}).get("MTU") or "")
    lines.append("%s: <code>%s</code>    MTU: <code>%s</code>" % (_t(user_id, "pr_subnet"), esc(subnet or "—"), esc(mtu or str(MTU_STANDARD))))
    # Линия 2.0 на сборке ядра 3.x: «Линейка 2.0» и «Версия ядра 3.1.…» рядом читались как «стоит 3.1» (LH-8).
    tag = core_ver_words(user_id, info)
    both20 = " " + _t(user_id, "pr_core_ver_both20") if str(info.get("line") or "") == "2.0" and tag.startswith("3.") else ""
    lines.append("%s: <code>%s</code>%s" % (_t(user_id, "pr_core_ver"), esc(tag or "—"), both20))
    lines.append("%s: <b>%s</b>" % (_t(user_id, "pr_peers"), esc(info.get("peers") if info.get("peers") is not None else 0)))
    # Движок AmneziaWG (KMOD_PLAN Б10): фактический — «модуль ядра» или «программа amneziawg-go»; выбран другой — сменится
    # при следующем перезапуске. Только профили на awg0 (старый контейнер приложения на wg0 модуль AmneziaWG не подхватит).
    engine = str(info.get("engine") or "")
    if engine in KMOD_ENGINE_WORDS and not re.fullmatch(r"wg[0-9]", str(cfg_p.get("iface") or "")):
        lines.append("%s: <b>%s</b>" % (_t(user_id, "pr_engine"), kmod_word(user_id, engine)))
        want = str(info.get("engine_want") or "")
        if want in ("kernel", "program") and want != engine and engine != "stopped":
            lines.append("<i>%s</i>" % _tf(user_id, "pr_engine_pending_fmt", kmod_word(user_id, want)))
    # Подсеть пересекается с другим профилем (SUBNET-01): с кем и выход; кнопка выхода — над остальными.
    ov = subnet_overlap_of(status, profile)
    if ov:
        lines.append("")
        lines.append("⚠️ " + subnet_overlap_text(user_id, ov, status))
    # Пакет данных не влезает в мобильные сети из-за большого S4 (S4-FIX): что не так; кнопка — над остальными.
    risk = packet_risk_of(info)
    if risk:
        lines.append("")
        lines.append("⚠️ " + _tf(user_id, "s4_risk_fmt", esc(profile_name(user_id, profile, status)), risk["s4"]))
    # Этот профиль повторяет линию другого, а второй линии пары нет (DUP-LINE-01): что не так и что можно; кнопка —
    # над остальными. У профиля приложения Amnezia такой строки нет никогда (lines_check_of).
    lc, dup = lines_check_of(status), dupline_fix_of(status)
    if dup.get("profile") == profile:
        lines.append("")
        lines.append("⚠️ " + dupline_text(user_id, "dash_dupline_fmt", dup["line"], dup["from"], dup["port"], dup["users"]))
    elif lc["reline"].get("profile") == profile:
        lines.append("")
        lines.extend(lines_check_lines(user_id, status))
    return "\n".join(lines)


def profile_card_keyboard(user_id: Optional[int], profile: str, installed: bool,
                          move: Optional[Dict[str, Any]] = None, s4fix: bool = False,
                          reline: Optional[list] = None, install_line: str = "",
                          port: str = "") -> "InlineKeyboardMarkup":
    """reline — ряд «Переставить … на 2.0» (DUP-LINE-01), первым; install_line — линия, которая встанет на свободное
    место по «Установить» (status.free_lines): кнопка называет её — «📦 Установить AmneziaWG 2.0». port — нынешний порт
    профиля: уже на 443 — кнопки «Занять UDP/443» нет, занимать нечего (BL-3, как LH-2 в SSH)."""
    if not installed:
        label = _tf(user_id, "pr_install_line_fmt", install_line) if install_line else _t(user_id, "pr_install")
        rows = [[btn(label, "pr_install~%s" % profile)], _back_row(user_id, "sec_protocols")]
        return InlineKeyboardMarkup(rows)
    rows = [reline] if reline else []
    rows += [[btn(_t(user_id, "pr_s4_btn"), "pr_s4~%s" % profile)]] if s4fix else []
    rows += [subnet_move_row(user_id, move)] if move else []
    rows += [
        [btn(_t(user_id, "pr_set_port"), "pr_port~%s" % profile)]
        + ([] if str(port) == "443" else [btn(_t(user_id, "pr_take443"), "pr_443~%s" % profile)]),
        [btn(_t(user_id, "pr_set_subnet"), "pr_subnet~%s" % profile), btn(_t(user_id, "pr_set_mtu"), "pr_mtu~%s" % profile)],
        [btn(_t(user_id, "pr_params"), "pr_params~%s" % profile), btn(_t(user_id, "pr_preset"), "pr_preset~%s" % profile)],
        [btn(_t(user_id, "pr_regen"), "pr_regen~%s" % profile), btn(_t(user_id, "pr_restart"), "pr_restart~%s" % profile)],
        # Как пункт SSH «Поднять контейнер заново»: ответ на пропавший контейнер и на
        # расхождение ключа сервера. Бот и уведомления сторожа советовали его, а кнопки не было.
        [btn(_t(user_id, "pr_repair"), "pr_fix~%s" % profile)],
        [btn(_t(user_id, "pr_remove"), "pr_remove~%s" % profile)],
        [btn(_t(user_id, "btn_refresh"), "pr_card~%s" % profile), btn(_t(user_id, "btn_back"), "sec_protocols")],
    ]
    return kb(rows)


async def show_profile_card(query, user_id: Optional[int], profile: str, fresh: bool = False) -> None:
    status = await get_status(fresh=fresh)
    if not bridge_ok(status):
        await show_error(query, user_id, status, "sec_protocols")
        return
    cfg = read_config_display()
    installed = bool(profile_info(status, profile))
    move = subnet_move_of(subnet_overlap_of(status, profile)) if installed else {}
    s4fix = installed and bool(packet_risk_of(profile_info(status, profile)))
    rl = reline_target(status, profile) if installed else {}
    reline = reline_row(user_id, rl, status) if rl else None
    install_line = "" if installed else status_free_lines(status).get(profile, "")
    await safe_edit_message(query, profile_card_text(user_id, profile, status, cfg),
                            reply_markup=profile_card_keyboard(user_id, profile, installed, move or None, s4fix,
                                                               reline=reline, install_line=install_line,
                                                               port=str((profile_info(status, profile) or {}).get("port") or "")))


async def cb_pr_card(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "pr_card~")
    if not profile:
        await show_bad_input(query, user_id, "sec_protocols")
        return
    await show_profile_card(query, user_id, profile, fresh=True)


async def cb_pr_install(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "pr_install~")
    if not profile:
        await show_bad_input(query, user_id, "sec_protocols")
        return
    rows = [
        [btn(_t(user_id, "pr_install_default_port"), "pr_inst_do~%s~def" % profile)],
        [btn(_t(user_id, "pr_install_custom_port"), "pr_inst_port~%s" % profile)],
    ]
    # UDP/443 для VPN — это режим «Pro»: в «Semi-Pro» мастер его не даёт, и кнопка
    # здесь только сбивала бы с толку (замечание критика). В остальных режимах — как раньше.
    status = await get_status()
    if not (bridge_ok(status) and str(status.get("mode") or "") == "lite_site"):
        rows.append([btn(_t(user_id, "pr_install_443"), "pr_inst_do~%s~443" % profile)])
    rows.append(_back_row(user_id, "pr_card~%s" % profile))
    # Линия — та, что встанет (status.free_lines, DUP-LINE-01): после подхвата 3.1 в awg2 на awg3 встанет 2.0
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_tf(user_id, "pr_install_title_fmt", esc(profile_line_name(user_id, profile, status))),
                                                        _t(user_id, "pr_install_body")),
                            reply_markup=InlineKeyboardMarkup(rows))


async def cb_pr_install_do(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    parts = query.data.split("~")
    # Третья часть — «def» (порт выбирает модуль), «443» или свой номер из «Свой порт»
    if len(parts) != 3 or not valid_profile(parts[1]) or not (parts[2] == "def" or valid_port(parts[2])):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    profile = parts[1]
    if await _action_busy(query, user_id, "pr_card~%s" % profile):
        return
    await safe_edit_message(query, "⏳ " + _tf(user_id, "pr_installing_fmt", esc(profile_line_name(user_id, profile))) + "\n"
                            + _t(user_id, "pr_install_wait"),
                            reply_markup=None)
    r = await mutate("profile-install", who=user_id, profile=profile,
                     port=None if parts[2] == "def" else str(int(parts[2])), preset="default")
    if not bridge_ok(r):
        await show_error(query, user_id, r, "pr_card~%s" % profile)
        return
    await safe_edit_message(query, "✅ " + esc(r.get("message") or _t(user_id, "done")),
                            reply_markup=back_kb(user_id, "pr_card~%s" % profile))


async def cb_pr_install_port(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """pr_inst_port~<profile> — установить профиль на свой порт: номер присылают текстом.

    Как в SSH-меню и в панели: там порт нового профиля задаётся сразу, а бот
    умел только «по умолчанию» и 443 — свой порт приходилось менять вторым шагом.
    """
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "pr_inst_port~")
    if not profile:
        await show_bad_input(query, user_id, "sec_protocols")
        return
    flow_set(context, "profile_install_port", profile=profile)
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (
        _tf(user_id, "pr_install_title_fmt", esc(profile_line_name(user_id, profile))), _t(user_id, "pr_ask_port")),
        reply_markup=cancel_kb(user_id, "pr_install~%s" % profile))


async def cb_pr_remove(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "pr_remove~")
    if not profile:
        await show_bad_input(query, user_id, "sec_protocols")
        return
    warn = _tf(user_id, "pr_remove_warn_fmt", esc(profile_name(user_id, profile)))
    pages = await remove_pages_text(user_id, profile)
    if pages:
        warn += "\n\n" + pages
    await arm_typed_confirm(query, context, user_id, "profile-remove", profile, back_to="pr_card~%s" % profile,
                            warn=warn)


async def remove_pages_text(user_id: Optional[int], profile: str) -> str:
    """Чьи страницы подключения перестанут работать при удалении профиля (в них был только он) — по именам из ядра
    (profile-remove-preview, PROFILE-REMOVE-PAGES), словами бота; ядро старше действия или не ответило — ""."""
    r = await run_bot_action("profile-remove-preview", timeout=60, profile=profile)
    if not bridge_ok(r):
        return ""
    names = [str(x) for x in (r.get("page_users") if isinstance(r.get("page_users"), list) else []) if valid_name(str(x))]
    pages = max(0, _as_int(r.get("pages")))
    if not pages or not names:
        return ""
    shown = ", ".join(esc(n) for n in names[:20])
    if len(names) > 20:
        shown += " " + _tf(user_id, "pr_rl_keys_more_fmt", len(names) - 20)
    return _tf(user_id, "pr_remove_pages_fmt" if pages > 1 else "pr_remove_page1_fmt", shown)


async def cb_pr_port(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "pr_port~")
    if not profile:
        await show_bad_input(query, user_id, "sec_protocols")
        return
    flow_set(context, "profile_port", profile=profile)
    await safe_edit_message(query, "<b>%s</b>\n\n%s\n\n%s" % (
        _tf(user_id, "pr_port_title_fmt", esc(profile_name(user_id, profile))), _t(user_id, "pr_ask_port"), _t(user_id, "pr_port_note")),
        reply_markup=cancel_kb(user_id, "pr_card~%s" % profile))


async def _apply_profile_port(target, user_id: Optional[int], profile: str, port: str, edit: bool) -> None:
    r = await mutate("profile-port", who=user_id, profile=profile, port=port)
    if bridge_ok(r):
        text = "✅ " + esc(r.get("message") or _t(user_id, "done")) + "\n" + _t(user_id, "pr_port_note")
    else:
        text = fail_text(user_id, r)
    markup = fail_markup(user_id, r, "pr_card~%s" % profile, retry_data(target) if edit else None)
    if edit:
        await safe_edit_message(target, text, reply_markup=markup)
    else:
        await target.reply_text(text, parse_mode="HTML", reply_markup=markup)


async def cb_pr_port_do(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """pr_port_do~<profile>~<port> — согласие на смену порта, номер уже назван."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    parts = str(query.data).split("~")
    profile = parts[1] if len(parts) > 2 else ""
    port = parts[2] if len(parts) > 2 else ""
    if not valid_profile(profile) or not valid_port(port):
        await show_bad_input(query, user_id, "sec_protocols")
        return
    if await _action_busy(query, user_id, "pr_card~%s" % profile):
        return
    await safe_edit_message(query, "⏳ " + _t(user_id, "wait"), reply_markup=None)
    await _apply_profile_port(query, user_id, profile, str(int(port)), edit=True)


def port443_mode_note(user_id: Optional[int], status: Dict[str, Any], port: Any) -> str:
    """Строка-предупреждение, когда VPN просят на UDP/443 в режиме «Semi-Pro».

    VPN на UDP/443 — признак режима «Pro». Кнопку «Установить на UDP/443»
    в «Semi-Pro» бот уже прятал, а свой порт 443 и «Занять UDP/443» проходили молча —
    и сразу после этого шапка ругалась «режим и порт VPN не совпадают» (замечание
    критика 24.09, п. 11). Не запрет: человек мог идти в этот режим сознательно.
    """
    if str(port) != "443" or not bridge_ok(status) or str(status.get("mode") or "") != "lite_site":
        return ""
    return "\n\n⚠️ " + _t(user_id, "pr_443_site_mode_warn")


async def cb_pr_443(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "pr_443~")
    if not profile:
        await show_bad_input(query, user_id, "sec_protocols")
        return
    rows = [[btn(_t(user_id, "btn_confirm"), "pr_443_do~%s" % profile)], _back_row(user_id, "pr_card~%s" % profile)]
    await safe_edit_message(query, "<b>%s</b>\n\n%s\n\n%s%s" % (
        _t(user_id, "pr_take443"), _tf(user_id, "pr_443_body_fmt", esc(profile_name(user_id, profile))), _t(user_id, "pr_port_note"),
        port443_mode_note(user_id, await get_status(), 443)),
        reply_markup=InlineKeyboardMarkup(rows))


async def cb_pr_443_do(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "pr_443_do~")
    if not profile:
        await show_bad_input(query, user_id, "sec_protocols")
        return
    if await _action_busy(query, user_id, "pr_card~%s" % profile):
        return
    await _apply_profile_port(query, user_id, profile, "443", edit=True)


async def cb_pr_subnet(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Экран подсети. Подхваченному старому контейнеру (wg0) подсеть не сменить — это сказано сразу, а не после
    отправленной подсети, и если его подсеть пересекается с другим профилем — кнопка выхода: перенести тот (SUBNET-01).
    Пересекается подсеть этого профиля — то же словами и кнопка «Перенести … на <свободная>», вводить не обязательно."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "pr_subnet~")
    if not profile:
        await show_bad_input(query, user_id, "sec_protocols")
        return
    status = await get_status()
    ok = bridge_ok(status)
    ov = subnet_overlap_of(status, profile) if ok else {}
    mv = subnet_move_of(ov)
    title = "<b>%s</b>" % _tf(user_id, "pr_subnet_title_fmt", esc(profile_name(user_id, profile)))
    if ok and profile_info(status, profile).get("subnet_fixed") is True:
        parts, rows = [title, _t(user_id, "pr_subnet_fixed")], []
        if mv and mv["profile"] != profile:
            parts.append(_tf(user_id, "pr_subnet_fixed_way_fmt", esc(str(ov.get("subnet") or "?")),
                             esc(profile_name(user_id, mv["profile"], status)), esc(mv["subnet"])))
            if mv["keyless"]:
                parts.append("⚠️ " + _tf(user_id, "pr_overlap_keyless_fmt", mv["keyless"]))
            rows.append(subnet_move_row(user_id, mv, status))
        else:
            parts.append(_t(user_id, "pr_subnet_fixed_none"))
        rows.append(_back_row(user_id, "pr_card~%s" % profile))
        await safe_edit_message(query, "\n\n".join(parts), reply_markup=InlineKeyboardMarkup(rows))
        return
    flow_set(context, "profile_subnet", profile=profile)
    parts, rows = [title], []
    if ov:
        parts.append("⚠️ " + subnet_overlap_text(user_id, ov, status))
        if mv:
            rows.append(subnet_move_row(user_id, mv, status))
    parts += [_t(user_id, "pr_ask_subnet"), "⚠️ " + _t(user_id, "pr_subnet_warn")]
    rows.append([btn(_t(user_id, "btn_cancel"), "pr_card~%s" % profile)])
    await safe_edit_message(query, "\n\n".join(parts), reply_markup=InlineKeyboardMarkup(rows))


async def _profile_subnet_step(user_id: Optional[int], profile: str, subnet: str,
                               adopted: str = "") -> Tuple[str, Optional["InlineKeyboardMarkup"], Dict[str, Any]]:
    """profile-subnet → (текст итога, кнопки, ответ моста). Отказ adopted_keyless (у подхваченного профиля люди с ключами
    только в приложении — их ключ с прежним адресом перестанет проходить) взводит фразу SUBNET <профиль>: такая смена —
    только словом, как перенос порта (ACC-2). Кнопки None — решает вызывающий (fail_markup)."""
    r = await mutate("profile-subnet", who=user_id, profile=profile, subnet=subnet, adopted_confirm=adopted or None)
    if bridge_ok(r):
        return "✅ " + esc(r.get("message") or _t(user_id, "done")), None, r
    if str(r.get("code") or "") == "adopted_keyless" and not adopted:
        phrase = await typed_phrase("profile-subnet-adopted", profile)
        CONFIRM.arm(int(user_id), "profile-subnet-adopted", profile, phrase, {"subnet": subnet})
        parts = ["⚠️ " + esc(r.get("message"))] if r.get("message") else []
        parts += [_t(user_id, "pr_subnet_adopted_note"), confirm_type_text(user_id, phrase)]
        return "\n\n".join(parts), InlineKeyboardMarkup([[btn(_t(user_id, "btn_cancel"), "tc_cancel~pr_card~%s" % profile)]]), r
    return fail_text(user_id, r), None, r


async def cb_pr_subnet_ok(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Подтверждение подсети кнопкой: значение уже введено текстом и лежит во flow."""
    query = update.callback_query
    user_id = _uid(update)
    flow = flow_get(context)
    if not flow or flow.get("kind") != "profile_subnet" or not flow["data"].get("subnet"):
        await query.answer(_t(user_id, "flow_expired"), show_alert=True)
        return
    profile, subnet = str(flow["data"].get("profile")), str(flow["data"].get("subnet"))
    flow_clear(context)
    if not valid_profile(profile) or not valid_subnet(subnet):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    if await _action_busy(query, user_id, "pr_card~%s" % profile):
        return
    await safe_edit_message(query, "⏳ " + _tf(user_id, "pr_subnet_changing_fmt", esc(profile_name(user_id, profile)), esc(subnet)),
                            reply_markup=None)
    text, markup, r = await _profile_subnet_step(user_id, profile, subnet)
    await safe_edit_message(query, text, reply_markup=markup or fail_markup(user_id, r, "pr_card~%s" % profile, retry_data(query)))


async def cb_pr_subnet_move(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Выход из пересечения подсетей (SUBNET-01): pr_smv~<профиль>~<подсеть> — вопрос «Перенести … на …?». Подсеть —
    свободная, её подобрало ядро. У профиля с людьми приложения без ключа на сервере — сразу фраза SUBNET <профиль>:
    кнопки для такого переноса мало (ACC-2)."""
    query = update.callback_query
    user_id = _uid(update)
    parts = query.data.split("~")
    if len(parts) != 3 or not valid_profile(parts[1]) or not valid_subnet(parts[2]):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    profile, subnet = parts[1], parts[2]
    status = await get_status()
    mv = subnet_move_of(subnet_overlap_of(status, profile)) if bridge_ok(status) else {}
    info = profile_info(status, profile) if bridge_ok(status) else {}
    name = profile_name(user_id, profile, status)
    warn = _tf(user_id, "pr_smv_warn_fmt", esc(name), esc(subnet), info.get("peers") if info.get("peers") is not None else 0)
    if mv.get("keyless"):
        await arm_typed_confirm(query, context, user_id, "profile-subnet-adopted", profile, back_to="pr_card~%s" % profile,
                                warn=warn + "\n\n⚠️ " + _tf(user_id, "pr_overlap_keyless_fmt", mv["keyless"]),
                                extra={"subnet": subnet})
        return
    rows = [[btn(_t(user_id, "pr_smv_go"), "pr_smv_do~%s~%s" % (profile, subnet))],
            [btn(_t(user_id, "btn_cancel"), "pr_card~%s" % profile)]]
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_tf(user_id, "pr_smv_title_fmt", esc(name), esc(subnet)), warn),
                            reply_markup=InlineKeyboardMarkup(rows))


async def cb_pr_subnet_move_do(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """pr_smv_do~<профиль>~<подсеть>: перенос после «Перенести». Люди приложения без ключа (если появились после
    вопроса) — отказ ядра adopted_keyless и фраза SUBNET <профиль>."""
    query = update.callback_query
    user_id = _uid(update)
    parts = query.data.split("~")
    if len(parts) != 3 or not valid_profile(parts[1]) or not valid_subnet(parts[2]):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    profile, subnet = parts[1], parts[2]
    if await _action_busy(query, user_id, "pr_card~%s" % profile):
        return
    await safe_edit_message(query, "⏳ " + _tf(user_id, "pr_subnet_changing_fmt", esc(profile_name(user_id, profile)), esc(subnet)),
                            reply_markup=None)
    text, markup, r = await _profile_subnet_step(user_id, profile, subnet)
    await safe_edit_message(query, text, reply_markup=markup or fail_markup(user_id, r, "pr_card~%s" % profile, retry_data(query)))


# ── «Исправить S4» (S4-FIX, MTU-01, решение владельца 08.10) ─────────────────
# Выданный профиль 2.0 с большим S4: при стандартном MTU 1280 пакет данных больше 1400, и на мобильном интернете, PPPoE
# и у части хостеров скачивание стоит. Ядро ставит S4 12–24 (S4-MARGIN, с 1.0.13; до того — не больше 40) тем же путём, что серверный параметр (profile-fix-s4), и
# отвечает, кому что делать (steps — словами на языке этого человека, L-24).

def s4_fix_result_text(user_id: Optional[int], r: Dict[str, Any]) -> str:
    """Итог «Исправить S4» одним сообщением: что сделано и кому что делать (подписки обновятся сами, ключи и файлы —
    импортировать заново, ключи из приложения Amnezia — поделиться заново)."""
    lines = ["✅ " + esc(r.get("message") or r.get("summary") or _t(user_id, "done"))]
    steps = [s for s in (r.get("steps") if isinstance(r.get("steps"), list) else []) if isinstance(s, dict) and s.get("text")]
    if steps:
        lines.append("")
        lines.extend("• " + esc(str(s["text"])) for s in steps)
    return "\n".join(lines)


async def _profile_fix_s4_step(user_id: Optional[int], profile: str,
                               adopted: str = "") -> Tuple[str, Optional["InlineKeyboardMarkup"], Dict[str, Any]]:
    """profile-fix-s4 → (текст итога, кнопки, ответ моста). Отказ adopted_keyless (люди приложения появились после того,
    как экран был нарисован) взводит фразу S4 <профиль>: такая смена — только словом (ACC-2). Кнопки None — решает
    вызывающий (fail_markup)."""
    r = await mutate("profile-fix-s4", who=user_id, profile=profile, adopted_confirm=adopted or None)
    if bridge_ok(r):
        return s4_fix_result_text(user_id, r), back_kb(user_id, "pr_card~%s" % profile), r
    if str(r.get("code") or "") == "adopted_keyless" and not adopted:
        phrase = await typed_phrase("profile-fix-s4-adopted", profile)
        CONFIRM.arm(int(user_id), "profile-fix-s4-adopted", profile, phrase)
        parts = ["⚠️ " + esc(r.get("message"))] if r.get("message") else []
        parts.append(confirm_type_text(user_id, phrase))
        return "\n\n".join(parts), InlineKeyboardMarkup([[btn(_t(user_id, "btn_cancel"), "tc_cancel~pr_card~%s" % profile)]]), r
    return fail_text(user_id, r), None, r


# R9-1: окна «Исправить S4», которые сейчас открываются (человек, профиль), — повторное нажатие их не дублирует.
_PR_S4_OPENING: set = set()


async def cb_pr_s4(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """pr_s4~<профиль> — «Исправить S4»: что не так и что будет — до вопроса, теми же словами, что в SSH и панели. У людей
    приложения Amnezia без ключа на сервере (packet_risk.keyless) — сразу фраза S4 <профиль>: кнопки для такого мало
    (ACC-2). Риска уже нет (исправили в другом окне) — так и сказать.

    R9-1: пока идёт свежий status, окно сразу говорит «Проверяю…»; повторное нажатие, пока первое не ответило, второго
    запроса не запускает (только всплывающее «Проверяю…»). Срок забора подписки — из того же status (subs_update),
    без обхода подписок. Неожиданное исключение в окне — экран «Внутренняя ошибка» с «Назад», а не тупик «Проверяю…»."""
    query = update.callback_query
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "pr_s4~")
    key = (user_id, profile)
    if not profile:
        await query.answer()
        await show_bad_input(query, user_id, "sec_protocols")
        return
    if key in _PR_S4_OPENING:
        await query.answer(_tf(user_id, "pr_s4_checking_fmt", profile_name(user_id, profile)))
        return
    # R9-1-A: ключ — сразу после проверки, до первого await: иначе второе нажатие, пришедшее, пока первое ждёт ответа
    # Telegram на answer() (concurrent_updates), проходит проверку, и status зовётся дважды.
    _PR_S4_OPENING.add(key)
    try:
        await query.answer()
        await safe_edit_message(query, "⏳ " + _tf(user_id, "pr_s4_checking_fmt", esc(profile_name(user_id, profile))),
                                reply_markup=None)
        try:
            await _pr_s4_screen(query, context, user_id, profile)
        except Exception:  # noqa: BLE001 — R9-1-B: не оставлять «Проверяю…» без кнопок
            logger.exception("pr_s4: window for %s failed", profile)
            await safe_edit_message(query, "❌ " + _t(user_id, "internal_error"),
                                    reply_markup=back_kb(user_id, "pr_card~%s" % profile))
    finally:
        _PR_S4_OPENING.discard(key)


async def _pr_s4_screen(query, context: ContextTypes.DEFAULT_TYPE, user_id: Optional[int], profile: str) -> None:
    """Окно «Исправить S4» по свежему status: вопрос, фраза для людей приложения или «риска уже нет»."""
    status = await get_status(fresh=True)
    if not bridge_ok(status):
        await show_error(query, user_id, status, "pr_card~%s" % profile)
        return
    risk = packet_risk_of(profile_info(status, profile))
    name = profile_name(user_id, profile, status)
    title = "<b>%s</b>" % _tf(user_id, "pr_s4_title_fmt", esc(name))
    if not risk:
        await safe_edit_message(query, "%s\n\n%s" % (title, _t(user_id, "pr_s4_none")),
                                reply_markup=back_kb(user_id, "pr_card~%s" % profile))
        return
    warn = "⚠️ " + _tf(user_id, "s4_risk_fmt", esc(name), risk["s4"])
    note = _tf(user_id, "pr_s4_note_fmt", risk["budget"], esc(sub_within_now(user_id, status)))
    if risk["keyless"]:
        await arm_typed_confirm(query, context, user_id, "profile-fix-s4-adopted", profile, back_to="pr_card~%s" % profile,
                                warn="%s\n\n%s\n\n⚠️ %s" % (warn, note, _tf(user_id, "pr_s4_keyless_fmt", risk["keyless"])))
        return
    rows = [[btn(_t(user_id, "pr_s4_go"), "pr_s4_do~%s" % profile)], [btn(_t(user_id, "btn_cancel"), "pr_card~%s" % profile)]]
    await safe_edit_message(query, "%s\n\n%s\n\n%s" % (title, warn, note), reply_markup=InlineKeyboardMarkup(rows))


async def cb_pr_s4_do(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """pr_s4_do~<профиль>: исправление после «Исправить S4» — итог одним сообщением."""
    query = update.callback_query
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "pr_s4_do~")
    if not profile:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    if await _action_busy(query, user_id, "pr_card~%s" % profile):
        return
    await safe_edit_message(query, "⏳ " + _tf(user_id, "pr_s4_fixing_fmt", esc(profile_name(user_id, profile))), reply_markup=None)
    text, markup, r = await _profile_fix_s4_step(user_id, profile)
    await safe_edit_message(query, text, reply_markup=markup or fail_markup(user_id, r, "pr_card~%s" % profile, retry_data(query)))


# ── Линии на сервере: нет 2.0, две одинаковые, «Переставить на 2.0» (DUP-LINE-01, решение владельца 15.10) ────────
# Подхваченный у приложения Amnezia профиль 3.1 на awg2 и «Установить» awg3 по месту дали две 3.1 и ни одной 2.0: старые
# версии приложений и роутеры Keenetic не подключались ни к одному профилю. Ядро отдаёт это в status.lines_check:
# no_20 — предупреждение, reline — свой профиль, который можно переставить на недостающую линию (profile-reline:
# удаление и установка на тот же порт и подсеть, людям — новые ключи). Профиль приложения не предлагается никогда.
# Согласие — фразой RELINE <профиль>, как у удаления профиля; итог — кому что делать, как у «Исправить S4».

RELINE_LINES = ("2.0", "3.1")


def lines_check_of(status: Any) -> Dict[str, Any]:
    """status.lines_check с проверенными полями: {no_20: bool, reline: {profile, line, port} или {}}; ядро старше
    поля — {"no_20": False, "reline": {}}."""
    lc = status.get("lines_check") if isinstance(status, dict) and bridge_ok(status) else None
    lc = lc if isinstance(lc, dict) else {}
    rl = lc.get("reline") if isinstance(lc.get("reline"), dict) else {}
    profile, line = str(rl.get("profile") or ""), str(rl.get("line") or "")
    info = profile_info(status, profile) if valid_profile(profile) else {}
    # Профиль приложения Amnezia не переставляется никогда (его люди держат ключи только в приложении): ядро его и не
    # предлагает, а бот не нарисует кнопку, даже если запись пришла испорченной.
    if not info or info.get("imported") is True or line not in RELINE_LINES or line == str(info.get("line") or ""):
        rl = {}
    else:
        port = rl.get("port") if isinstance(rl.get("port"), int) and not isinstance(rl.get("port"), bool) else 0
        rl = {"profile": profile, "line": line, "port": port or _as_int(info.get("port"))}
    return {"no_20": lc.get("no_20") is True, "reline": rl}


def lines_check_lines(user_id: Optional[int], status: Any) -> List[str]:
    """Строки-предупреждения о линиях (HTML): «нет 2.0» и «можно переставить» — главный экран, «Протоколы», выбор линии
    на UDP 443."""
    lc = lines_check_of(status)
    out = ["⚠️ " + _t(user_id, "lines_no20")] if lc["no_20"] else []
    rl = lc["reline"]
    if rl:
        out.append("ℹ️ " + _tf(user_id, "lines_reline_fmt", esc(profile_name(user_id, rl["profile"], status)), rl["line"]))
    return out


def reline_row(user_id: Optional[int], rl: Dict[str, Any], status: Any = None) -> list:
    """Кнопка «🔁 Переставить 3.1 (UDP 6714) на 2.0» → экран согласия (pr_rl~<профиль>)."""
    return [btn(_tf(user_id, "pr_rl_btn_fmt", profile_short(rl["profile"], status, user_id), rl["line"]), "pr_rl~%s" % rl["profile"])]


def dupline_fix_of(status: Any) -> Dict[str, Any]:
    """status.dupline_fix — ошибка прошлых версий, найденная миграцией при обновлении: своя линия повторяет подхваченную
    3.1 приложения, а 2.0 нет. {profile, line, from, port, users} с проверенными полями или {}; профиль приложения
    (imported) не принимается никогда — его не переставляем."""
    d = status.get("dupline_fix") if isinstance(status, dict) and bridge_ok(status) else None
    if not isinstance(d, dict):
        return {}
    profile, line = str(d.get("profile") or ""), str(d.get("line") or "")
    info = profile_info(status, profile) if valid_profile(profile) else {}
    cur = str(info.get("line") or "")
    if not info or info.get("imported") is True or line not in RELINE_LINES or line == cur:
        return {}
    frm = str(d.get("from") or "")
    return {"profile": profile, "line": line, "from": frm if frm in LINE_FAMILY else cur,
            "port": _port_of(d) or _port_of(info), "users": max(0, _as_int(d.get("users")))}


def reline_steps(status: Any, profile: str) -> List[str]:
    """Кому что сделать после «Переставить на 2.0» — шаги ядра до неё (lines_check.reline.steps или dupline_fix.steps):
    у каждого пользователя его действие (решение координатора 15.10). Ядро старше поля — []."""
    if not (isinstance(status, dict) and bridge_ok(status)):
        return []
    lc = status.get("lines_check") if isinstance(status.get("lines_check"), dict) else {}
    for rl in (lc.get("reline"), status.get("dupline_fix")):
        if isinstance(rl, dict) and rl.get("profile") == profile and isinstance(rl.get("steps"), list):
            return [str(x.get("text")) for x in rl["steps"] if isinstance(x, dict) and x.get("text")][:6]
    return []


def reline_target(status: Any, profile: str) -> Dict[str, Any]:
    """Что переставлять у этого профиля: lines_check.reline, а нет его — dupline_fix (уведомление после обновления);
    {} — переставлять нечего."""
    for rl in (lines_check_of(status)["reline"], dupline_fix_of(status)):
        if rl.get("profile") == profile:
            return {"profile": profile, "line": rl["line"], "port": rl.get("port") or 0}
    return {}


def dupline_text(user_id: Optional[int], key: str, line: Any, frm: Any, port: Any, users: Any) -> str:
    """Слова про ошибку прошлых версий (HTML): уведомление (ntf_dupline_fmt) и строка главного экрана
    (dash_dupline_fmt)."""
    line, frm = str(line or "2.0"), str(frm or "3.1")
    label = esc(profile_label(user_id, frm, port))
    if key == "ntf_dupline_fmt":
        # Текст карты сервера (DUPLINE-TEXT-01): профиль — подписью, кому что делать; пользователей нет — без них.
        if max(0, _as_int(users)) == 0:
            return _tf(user_id, "ntf_dupline0_fmt", esc(line), esc(frm), esc(line), label, esc(line))
        return _tf(user_id, key, esc(line), esc(frm), esc(line), label, esc(line), max(0, _as_int(users)))
    return _tf(user_id, key, esc(line), esc(frm), label, max(0, _as_int(users)))


def reline_result_text(user_id: Optional[int], r: Dict[str, Any]) -> str:
    """Итог «Переставить на 2.0» одним сообщением — как у «Исправить S4»: что сделано (summary ядра) и кому что делать
    (steps: подписки обновятся сами, страницу открыть заново, ключи и файлы выдать заново, кому ключ не выдан)."""
    return s4_fix_result_text(user_id, r)


def _users_without(users: List[Dict[str, Any]], profile: str) -> Tuple[List[str], bool]:
    """Имена пользователей без ключа на профиле и есть ли ключ на нём хоть у кого-то."""
    todo, have = [], False
    for u in users:
        name = str(u.get("name") or "")
        if not valid_name(name):
            continue
        if profile in set(u.get("profiles") or (u.get("peers") or {}).keys()):
            have = True
        else:
            todo.append(name)
    return todo, have


async def cb_pr_reline_keys(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """pr_rlk~<профиль> — кнопка «Выдать ключ» из сообщений прежних версий (вопрос после итога перестановки). Ключ
    остальным теперь выдаёт ядро вместе с перестановкой (DUPLINE-KEYS-01) — старая кнопка ведёт в карточку профиля."""
    query = update.callback_query
    await query.answer()
    profile = _profile_from_data(query.data, "pr_rlk~")
    await dispatch_callback_data(update, context, "pr_card~%s" % profile if profile else "sec_protocols")


def reline_others_rows(user_id: Optional[int], profile: str, line: str, todo: List[str], have: bool,
                       keys_on: bool, unknown: bool = False) -> Tuple[str, List[list]]:
    """Ключ на новой линии остальным — строкой на экране согласия и кнопкой-переключателем (DUPLINE-KEYS-01): у кого
    ключа на профиле нет, по именам; ни у кого нет — «всем». Отмечено по умолчанию, как галочка в панели; выдаёт ядро
    тем же действием. Выдавать некому — ("", []). Список пользователей не прочитался (unknown) — выбор всё равно есть,
    без имён: кому выдать, ядро посчитает само (R-7)."""
    if not todo and not unknown:
        return "", []
    if not todo:
        text = _tf(user_id, "pr_rl_others_unknown_on_fmt" if keys_on else "pr_rl_others_unknown_off_fmt", esc(line))
    elif have:
        names = ", ".join(esc(n) for n in todo[:20])
        if len(todo) > 20:
            names += " " + _tf(user_id, "pr_rl_keys_more_fmt", len(todo) - 20)
        text = _tf(user_id, "pr_rl_others_on_fmt" if keys_on else "pr_rl_others_off_fmt", names, esc(line))
    else:
        text = _tf(user_id, "pr_rl_all_on_fmt" if keys_on else "pr_rl_all_off_fmt", len(todo), esc(line))
    if keys_on:
        return text, [[btn(_t(user_id, "pr_rl_keys_on_btn"), "pr_rl~%s~off" % profile)]]
    return text, [[btn(_t(user_id, "pr_rl_keys_off_btn"), "pr_rl~%s" % profile)]]


async def cb_pr_reline(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """pr_rl~<профиль>[~off] — «Переставить на 2.0»: что будет — до согласия, согласие — фразой RELINE <порт профиля>, как у
    удаления профиля (профиль удаляется и ставится заново, прежние ключи людей на нём перестают работать). Переставлять
    уже нечего (исправили в другом окне, профиль подхвачен у приложения) — так и сказать. Ключ остальным — выбор на этом
    же экране (~off — не выдавать), выдаёт ядро тем же действием."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "pr_rl~")
    if not profile:
        await show_bad_input(query, user_id, "sec_protocols")
        return
    status = await get_status(fresh=True)
    if not bridge_ok(status):
        await show_error(query, user_id, status, "pr_card~%s" % profile)
        return
    rl = reline_target(status, profile)
    title = profile_title(user_id, profile, status)
    if not rl:
        await safe_edit_message(query, "<b>%s</b>\n\n%s" % (esc(title), _t(user_id, "pr_rl_none")),
                                reply_markup=back_kb(user_id, "pr_card~%s" % profile))
        return
    peers = _as_int(profile_info(status, profile).get("peers"))
    warn = "<b>%s</b>\n\n%s" % (_tf(user_id, "pr_rl_title_fmt", esc(title), rl["line"]),
                                _tf(user_id, "pr_rl_warn_fmt", esc(title), rl["line"], rl["port"] or "—", peers))
    steps = reline_steps(status, profile)
    if steps:
        warn += "\n\n" + _t(user_id, "pr_rl_who") + "\n" + "\n".join("• " + esc(x) for x in steps)
    keys_on = not query.data.endswith("~off")
    ru, users = await fetch_users()
    unknown = not bridge_ok(ru)
    todo, have = _users_without(users, profile) if not unknown else ([], False)
    others, rows = reline_others_rows(user_id, profile, rl["line"], todo, have, keys_on, unknown)
    if others:
        warn += "\n\n" + others
    await arm_typed_confirm(query, context, user_id, "profile-reline", profile, back_to="pr_card~%s" % profile,
                            warn=warn, extra={"line": rl["line"], "keys": "on" if keys_on and (todo or unknown) else "off"},
                            rows=rows)


async def cb_pr_mtu(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "pr_mtu~")
    if not profile:
        await show_bad_input(query, user_id, "sec_protocols")
        return
    flow_set(context, "profile_mtu", profile=profile)
    rows = [[btn(_t(user_id, "pr_mtu_std_btn") if m == MTU_STANDARD else str(m), "pr_mtu_set~%s~%d" % (profile, m))
             for m in MTU_PRESETS],
            [btn(_t(user_id, "btn_cancel"), "pr_card~%s" % profile)]]
    cur = profile_params_display(profile).get("MTU") or ""
    parts = ["<b>%s</b>" % _tf(user_id, "pr_mtu_title_fmt", esc(profile_name(user_id, profile))),
             _tf(user_id, "pr_mtu_now_fmt", esc(cur or str(MTU_STANDARD))), _t(user_id, "pr_mtu_hint"), _t(user_id, "pr_ask_mtu")]
    await safe_edit_message(query, "\n\n".join(parts), reply_markup=InlineKeyboardMarkup(rows))


def profile_params_display(profile: str) -> Dict[str, Any]:
    """Параметры профиля из config.json (без секретов там их нет) — для окна MTU: нынешний MTU и S4."""
    prof = (read_config_display().get("profiles") or {}).get(profile)
    params = prof.get("params") if isinstance(prof, dict) else None
    return params if isinstance(params, dict) else {}


def mtu_warnings(user_id: Optional[int], mtu: int, s4: int) -> List[str]:
    """Что такой MTU сломает наверняка — словами (то же правило, что у ядра: awgkeys.py mtu_warnings). Не выше 1280 за
    большой пакет отвечает S4 — это «Исправить S4», а не окно MTU; ниже 1280 MTU не принимается вовсе (mtu_too_low)."""
    if mtu > MTU_STANDARD and mtu + PACKET_OVERHEAD + s4 > PACKET_PATH:
        return [_tf(user_id, "pr_mtu_warn_path_fmt", mtu + PACKET_OVERHEAD + s4)]
    return []


async def _apply_profile_mtu(target, user_id: Optional[int], profile: str, mtu: str, edit: bool,
                             confirmed: bool = False) -> None:
    # Такой MTU что-то сломает наверняка — сначала сказать и спросить (решение владельца 08.10), а не молча записать.
    if not confirmed:
        s4 = str(profile_params_display(profile).get("S4") or "")
        warns = mtu_warnings(user_id, int(mtu), int(s4) if s4.isdigit() else 0)
        if warns:
            m, std = mtu, MTU_STANDARD     # имена — как у check_menu.py: m и std — число MTU (4 знака)
            rows = [[btn(_tf(user_id, "pr_mtu_keep_fmt", m), "pr_mtu_ok~%s~%s" % (profile, m))],
                    [btn(_t(user_id, "pr_mtu_std_btn"), "pr_mtu_set~%s~%d" % (profile, std))],
                    [btn(_t(user_id, "btn_cancel"), "pr_card~%s" % profile)]]
            text = "<b>%s</b>\n\n%s" % (_tf(user_id, "pr_mtu_title_fmt", esc(profile_name(user_id, profile))),
                                        "\n".join("⚠️ " + esc(w) for w in warns))
            if edit:
                await safe_edit_message(target, text, reply_markup=InlineKeyboardMarkup(rows))
            else:
                await target.reply_text(text, parse_mode="HTML", reply_markup=InlineKeyboardMarkup(rows))
            return
    if not edit:
        await _queued_notice(target, user_id)
    r = await mutate("profile-mtu", who=user_id, profile=profile, mtu=mtu)
    text = ("✅ " + esc(r.get("message") or _t(user_id, "done"))) if bridge_ok(r) else (fail_text(user_id, r))
    markup = fail_markup(user_id, r, "pr_card~%s" % profile, retry_data(target) if edit else None)
    if edit:
        await safe_edit_message(target, text, reply_markup=markup)
    else:
        await target.reply_text(text, parse_mode="HTML", reply_markup=markup)


async def cb_pr_mtu_set(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """pr_mtu_set~<профиль>~<mtu> — кнопка значения (pr_mtu_ok~ — «Сохранить всё равно» после предупреждения)."""
    query = update.callback_query
    user_id = _uid(update)
    parts = query.data.split("~")
    if len(parts) != 3 or not valid_profile(parts[1]) or not valid_mtu(parts[2]):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    flow_clear(context)
    if await _action_busy(query, user_id, "pr_card~%s" % parts[1]):
        return
    await _apply_profile_mtu(query, user_id, parts[1], parts[2], edit=True, confirmed=parts[0] == "pr_mtu_ok")


# Параметры-ключи — на экране «задан (скрыт)», а не значение (K5-3: экраны попадают в записи и скриншоты гайдов).
# Тот же список — GA_AMN_SECRET_PARAMS в lib/amnezia.sh и SECRET_PARAMS в admin-web/static/app.js (paramShown).
SECRET_PARAMS = ("HeaderProtectionKey",)


def param_shown(user_id: Optional[int], key: str, value: Any) -> str:
    """Значение параметра для экрана: пустое — «—», у параметра-ключа — «задан (скрыт)»."""
    if value in ("", None):
        return "—"
    return _t(user_id, "pr_param_secret_set") if key in SECRET_PARAMS else str(value)


def params_text(user_id: Optional[int], profile: str, params: Dict[str, Any], line: str) -> str:
    # В заголовке — фактическая линейка профиля, в списке — ключи её семейства:
    # у профиля на 1.0 пустые I1–I5 показать надо, их разрешено задать.
    lines = ["<b>%s</b>" % _tf(user_id, "pr_params_title_fmt", esc(profile_name(user_id, profile)), esc(line or "—")), ""]
    keys = param_keys_for_line(line_base(profile, line)) if line in ("1.0", "1.5", "2.0", "3.1") else list(params.keys())
    shown = []
    for key in keys:
        value = params.get(key, "")
        scope = "🔒" if param_scope(key) == "server" else "·"
        shown.append("%s <code>%s</code> = <code>%s</code>" % (scope, esc(key), esc(param_shown(user_id, key, value))))
    # ключи, которых нет в списке линейки, но есть в конфиге, — тоже показываем, но
    # только заданные: мост отдаёт полный набор всех линеек, и у 1.5 экран был
    # засыпан строками «S3 = —», «HeaderProtectionKey = —» — параметрами, которых
    # у этой линейки нет и задать которые кнопками нельзя.
    for key in params:
        if key not in keys and params.get(key) not in ("", None):
            shown.append("· <code>%s</code> = <code>%s</code>" % (esc(key), esc(param_shown(user_id, key, params.get(key)))))
    lines.extend(shown or ["<i>%s</i>" % _tf(user_id, "pr_params_unavailable_fmt", esc(profile_name(user_id, profile)))])
    lines.append("")
    lines.append(_t(user_id, "pr_params_legend"))
    return "\n".join(lines)


async def cb_pr_params(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "pr_params~")
    if not profile:
        await show_bad_input(query, user_id, "sec_protocols")
        return
    r = await run_bot_action("profile-params", timeout=60, profile=profile)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "pr_card~%s" % profile)
        return
    params = r.get("params") if isinstance(r.get("params"), dict) else {}
    status = await get_status()
    line = str(profile_info(status, profile).get("line") or DEFAULT_LINE.get(profile) or "")
    rows = [[btn(_t(user_id, "pr_set_param"), "pr_pedit~%s" % profile)], _back_row(user_id, "pr_card~%s" % profile)]
    await safe_edit_message(query, params_text(user_id, profile, params, line), reply_markup=InlineKeyboardMarkup(rows))


async def cb_pr_param_edit(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Выбор параметра кнопками — только те, что понимает линейка профиля."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "pr_pedit~")
    if not profile:
        await show_bad_input(query, user_id, "sec_protocols")
        return
    status = await get_status()
    line = str(profile_info(status, profile).get("line") or DEFAULT_LINE.get(profile) or "")
    keys = param_keys_for_line(line_base(profile, line)) if line in ("1.0", "1.5", "2.0", "3.1") else param_keys_for_line("3.1")
    rows, row = [], []
    for key in keys:
        row.append(btn(("🔒 " if param_scope(key) == "server" else "") + key, "pr_pkey~%s~%s" % (profile, key)))
        if len(row) == 3:
            rows.append(row)
            row = []
    if row:
        rows.append(row)
    rows.append(_back_row(user_id, "pr_params~%s" % profile))
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_tf(user_id, "pr_param_pick_title_fmt", esc(profile_name(user_id, profile)),
                                                            esc(line or "—")),
                                                        _t(user_id, "pr_param_reissue_note")),
                            reply_markup=InlineKeyboardMarkup(rows))


async def cb_pr_param_key(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    parts = query.data.split("~")
    if len(parts) != 3 or not valid_profile(parts[1]) or parts[2] not in param_keys_for_line("3.1"):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    profile, key = parts[1], parts[2]
    r = await run_bot_action("profile-params", timeout=60, profile=profile)
    params = r.get("params") if bridge_ok(r) and isinstance(r.get("params"), dict) else {}
    current = str(params.get(key) or "")
    flow_set(context, "profile_param", profile=profile, key=key)
    scope_note = _t(user_id, "pr_param_scope_server") if param_scope(key) == "server" else _t(user_id, "pr_param_scope_client")
    rows = [[btn(_t(user_id, "pr_param_unset"), "pr_punset")], [btn(_t(user_id, "btn_cancel"), "pr_params~%s" % profile)]]
    await safe_edit_message(query, "<b>%s</b>\n\n%s\n\n%s\n\n%s" % (
        _tf(user_id, "pr_param_edit_title_fmt", esc(key), esc(profile_name(user_id, profile))),
        _tf(user_id, "pr_param_current_fmt", esc(param_shown(user_id, key, current))), scope_note,
        _t(user_id, "pr_param_value_hint")), reply_markup=InlineKeyboardMarkup(rows))


async def _param_confirm_or_apply(target, context, user_id: Optional[int], flow: Dict[str, Any], value: str, edit: bool) -> None:
    """Клиентский параметр применяем сразу; серверный — после предупреждения о перевыпуске."""
    profile, key = str(flow["data"].get("profile")), str(flow["data"].get("key"))
    if param_scope(key) == "server":
        flow["data"]["value"] = value
        flow["data"]["confirm"] = True
        text = "<b>%s</b>\n\n⚠️ %s\n\n%s" % (
            _tf(user_id, "pr_param_edit_title_fmt", esc(key), esc(profile_name(user_id, profile))),
            _t(user_id, "pr_param_reissue_note"),
            # Значение параметра-ключа (HeaderProtectionKey) — «задан (скрыт)», как в списке (KEENETIC-I1-N, N4).
            _tf(user_id, "pr_ask_param_confirm_fmt", esc(key), esc(param_shown(user_id, key, value))))
        markup = InlineKeyboardMarkup([[btn(_t(user_id, "btn_confirm"), "pr_pok")],
                                       [btn(_t(user_id, "btn_cancel"), "pr_params~%s" % profile)]])
        if edit:
            await safe_edit_message(target, text, reply_markup=markup)
        else:
            await target.reply_text(text, parse_mode="HTML", reply_markup=markup)
        return
    flow_clear(context)
    await _apply_param(target, user_id, profile, key, value, edit=edit)


def param_result_text(user_id: Optional[int], r: Dict[str, Any]) -> str:
    """Итог смены параметра. С 1.0.13 (PARAM-11) ядро само говорит, кому нужен новый конфиг: message = итог + summary,
    по людям — result.steps (подписки обновятся сами, ключи vpn:// и .conf — выдать заново), шаг restart — перезапуск.
    Тогда своей строки «выдайте ключи заново» бот не добавляет: она повторяла summary и противоречила ему (подписки
    обновятся сами). Ответ прежнего ядра (без clients_update, summary и steps) — как раньше."""
    res = r.get("result") if isinstance(r.get("result"), dict) else {}
    raw = res.get("steps") if isinstance(res.get("steps"), list) else []
    steps = [s for s in raw if isinstance(s, dict) and s.get("text")]
    summary = str(res.get("summary") or "")
    message = str(r.get("message") or "")
    text = "✅ " + esc(message or summary or _t(user_id, "done"))
    if summary and message and summary not in message:
        text += " " + esc(summary)
    if steps:
        text += "\n\n" + "\n".join("• " + esc(str(s["text"])) for s in steps)
    core_says = "clients_update" in r or "clients_update" in res or bool(summary) or bool(steps)
    if r.get("reissue_required") is True and not core_says:
        text += "\n\n⚠️ " + _t(user_id, "pr_param_reissue_now")
    elif r.get("restarted") is True and r.get("reissue_required") is not True \
            and not any(s.get("kind") == "restart" for s in steps):
        # Клиентский параметр на модуле ядра применён перезапуском профиля (KMOD-01) — честно, сколько ждать.
        text += "\n\n🔄 " + _t(user_id, "pr_param_restarted")
    return text


async def _apply_param(target, user_id: Optional[int], profile: str, key: str, value: str, edit: bool) -> None:
    if not edit:
        await _queued_notice(target, user_id)
    r = await mutate("profile-set-param", who=user_id, profile=profile, key=key, value=value)
    if bridge_ok(r):
        text = param_result_text(user_id, r)
    else:
        text = fail_text(user_id, r)
    # «Повторить» у этих кнопок не ставится (FLOW_BOUND_CALLBACKS): значение жило в ожидании ввода
    markup = fail_markup(user_id, r, "pr_params~%s" % profile, retry_data(target) if edit else None)
    if edit:
        await safe_edit_message(target, text, reply_markup=markup)
    else:
        await target.reply_text(text, parse_mode="HTML", reply_markup=markup)


async def cb_pr_param_unset(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    flow = flow_get(context)
    if not flow or flow.get("kind") != "profile_param":
        await query.answer(_t(user_id, "flow_expired"), show_alert=True)
        return
    await query.answer()
    # Клиентский параметр снимается сразу (мост) — кнопке во время операции бота экран «занято»;
    # серверный сначала спрашивает подтверждение, там замок проверит «Подтвердить».
    profile = str(flow["data"].get("profile") or "")
    if param_scope(str(flow["data"].get("key") or "")) != "server" and valid_profile(profile) \
            and await _action_busy(query, user_id, "pr_params~%s" % profile):
        return
    await _param_confirm_or_apply(query, context, user_id, flow, "", edit=True)


async def cb_pr_param_ok(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    flow = flow_get(context)
    if not flow or flow.get("kind") != "profile_param" or not flow["data"].get("confirm"):
        await query.answer(_t(user_id, "flow_expired"), show_alert=True)
        return
    profile, key, value = str(flow["data"].get("profile")), str(flow["data"].get("key")), str(flow["data"].get("value") or "")
    flow_clear(context)
    if not valid_profile(profile) or not valid_param_value(value):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    if await _action_busy(query, user_id, "pr_params~%s" % profile):
        return
    await _apply_param(query, user_id, profile, key, value, edit=True)


async def cb_pr_preset(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "pr_preset~")
    if not profile:
        await show_bad_input(query, user_id, "sec_protocols")
        return
    rows = [[btn(_t(user_id, "preset_%s" % p), "pr_preset_do~%s~%s" % (profile, p))] for p in PRESETS]
    rows.append(_back_row(user_id, "pr_card~%s" % profile))
    await safe_edit_message(query, "<b>%s</b>\n\n%s\n\n⚠️ %s" % (
        _tf(user_id, "pr_preset_title_fmt", esc(profile_name(user_id, profile))), _t(user_id, "pr_preset_body"), _t(user_id, "pr_regen_warn")),
        reply_markup=InlineKeyboardMarkup(rows))


async def cb_pr_preset_do(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    parts = query.data.split("~")
    if len(parts) != 3 or not valid_profile(parts[1]) or parts[2] not in PRESETS:
        await show_bad_input(query, user_id, "sec_protocols")
        return
    await arm_typed_confirm(query, context, user_id, "profile-regen", parts[1], back_to="pr_card~%s" % parts[1],
                            warn=_tf(user_id, "pr_regen_warn_fmt", esc(parts[1]), esc(parts[2])), extra={"preset": parts[2]})


async def cb_pr_regen(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "pr_regen~")
    if not profile:
        await show_bad_input(query, user_id, "sec_protocols")
        return
    await arm_typed_confirm(query, context, user_id, "profile-regen", profile, back_to="pr_card~%s" % profile,
                            warn=_tf(user_id, "pr_regen_warn_fmt", esc(profile_name(user_id, profile)), "default"),
                            extra={"preset": "default"})


async def cb_pr_restart(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """pr_restart~<profile>: сперва вопрос. Перезапуск рвёт связь всем, кто сейчас
    подключён, — SSH об этом спрашивает, и здесь спрашиваем тем же вопросом."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "pr_restart~")
    if not profile:
        await show_bad_input(query, user_id, "sec_protocols")
        return
    rows = [[btn(_t(user_id, "btn_confirm"), "pr_restart_do~%s" % profile)],
            _back_row(user_id, "pr_card~%s" % profile)]
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (
        _t(user_id, "pr_restart"), _tf(user_id, "pr_restart_warn_fmt", esc(profile_name(user_id, profile)))),
        reply_markup=InlineKeyboardMarkup(rows))


async def cb_pr_restart_do(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "pr_restart_do~")
    if not profile:
        await show_bad_input(query, user_id, "sec_protocols")
        return
    if await _action_busy(query, user_id, "pr_card~%s" % profile):
        return
    await safe_edit_message(query, "⏳ " + _tf(user_id, "pr_restarting_fmt", esc(profile_name(user_id, profile))), reply_markup=None)
    r = await mutate("profile-restart", who=user_id, profile=profile)
    text = ("✅ " + esc(r.get("message") or _t(user_id, "done"))) if bridge_ok(r) else (fail_text(user_id, r))
    await safe_edit_message(query, text, reply_markup=fail_markup(user_id, r, "pr_card~%s" % profile, retry_data(query)))


async def cb_pr_repair(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """pr_fix~<profile>: что будет — и согласие. Действие не разрушительное (ключи прежние),
    поэтому кнопкой, а не фразой, но связь на время пересоздания рвётся — сперва вопрос."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "pr_fix~")
    if not profile:
        await show_bad_input(query, user_id, "sec_protocols")
        return
    rows = [[btn(_t(user_id, "btn_confirm"), "pr_fix_do~%s" % profile)], _back_row(user_id, "pr_card~%s" % profile)]
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (
        _t(user_id, "pr_repair"), _tf(user_id, "pr_repair_warn_fmt", esc(profile_name(user_id, profile)))),
        reply_markup=InlineKeyboardMarkup(rows))


async def cb_pr_repair_do(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """pr_fix_do~<profile>: profile-repair — контейнер из копии состояния (state/), без архива."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "pr_fix_do~")
    if not profile:
        await show_bad_input(query, user_id, "sec_protocols")
        return
    if await _action_busy(query, user_id, "pr_card~%s" % profile):
        return
    await safe_edit_message(query, "⏳ " + _tf(user_id, "pr_repairing_fmt", esc(profile_name(user_id, profile))), reply_markup=None)
    r = await mutate("profile-repair", who=user_id, profile=profile)
    text = ("✅ " + esc(r.get("message") or _t(user_id, "done"))) if bridge_ok(r) else (fail_text(user_id, r))
    await safe_edit_message(query, text, reply_markup=fail_markup(user_id, r, "pr_card~%s" % profile, retry_data(query)))


# ============================================================================
# РАЗДЕЛ 4: ОБСЛУЖИВАНИЕ
# ============================================================================

async def cb_sec_maint(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    rows = [
        [btn(_t(user_id, "mt_restart_all"), "mt_restart_all"), btn(_t(user_id, "mt_backup"), "mt_backup")],
        [btn(_t(user_id, "mt_restore"), "mt_restore"), btn(_t(user_id, "mt_upstream"), "mt_upstream")],
        [btn(_t(user_id, "mt_import"), "mt_import"), btn(_t(user_id, "mt_diag"), "mt_diag")],
        # Модуль ядра AmneziaWG по выбору (KMOD_PLAN этап Б): как SSH «Обслуживание → 9) Ускорение AmneziaWG».
        [btn(_t(user_id, "mt_kmod"), "mt_kmod")],
        # Раздачи живут пять минут, но снять их надо уметь и из другого чата,
        # где сообщения с адресом уже нет.
        [btn(_t(user_id, "share_list_btn"), "sh_list"), btn(_t(user_id, "mt_selfupdate"), "mt_selfupdate")],
        _back_row(user_id),
    ]
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "mt_title"), _t(user_id, "sec_service_hint")),
                            reply_markup=kb(rows))


async def cb_mt_restart_all(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    rows = [[btn(_t(user_id, "btn_confirm"), "mt_restart_all_do")], _back_row(user_id, "sec_maint")]
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "mt_restart_all"), _t(user_id, "mt_restart_all_body")),
                            reply_markup=InlineKeyboardMarkup(rows))


async def cb_mt_restart_all_do(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Перезапуск профилей по одному; самого бота из бота не перезапускаем —
    он убил бы себя, не успев ответить на нажатие."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    if await _action_busy(query, user_id, "sec_maint"):
        return
    status = await get_status(fresh=True)
    profiles = installed_profiles(status)
    if not profiles:
        await safe_edit_message(query, "<i>%s</i>" % _t(user_id, "dash_no_profiles"), reply_markup=back_kb(user_id, "sec_maint"))
        return
    lines = []
    for p in profiles:
        pname = esc(profile_name(user_id, p, status))
        await safe_edit_message(query, "⏳ " + _tf(user_id, "pr_restarting_fmt", pname), reply_markup=None)
        r = await mutate("profile-restart", who=user_id, profile=p)
        lines.append(("✅ %s" % pname) if bridge_ok(r) else ("❌ %s — %s" % (pname, error_text(user_id, r))))
    lines.append("")
    lines.append(_t(user_id, "mt_restart_all_bot_note"))
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "mt_restart_all"), "\n".join(lines)),
                            reply_markup=back_kb(user_id, "sec_maint"))


async def cb_mt_backup(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    if await _action_busy(query, user_id, "sec_maint"):
        return
    await safe_edit_message(query, "⏳ " + _t(user_id, "backup_creating"), reply_markup=None)
    r = await mutate("backup-create", who=user_id)
    if bridge_ok(r):
        text = "✅ " + _tf(user_id, "backup_created_fmt", esc(r.get("file") or r.get("path") or "?"))
    else:
        text = fail_text(user_id, r)
    await safe_edit_message(query, text, reply_markup=fail_markup(user_id, r, "sec_maint", retry_data(query)))


def _backup_names(r: Dict[str, Any]) -> List[str]:
    """backup-list → имена файлов (только безопасной формы), новые сверху."""
    items = r.get("backups") if isinstance(r.get("backups"), list) else []
    names = []
    for item in items:
        name = str(item.get("name") if isinstance(item, dict) else item or "")
        if valid_backup_file(name):
            names.append(name)
    return sorted(names, reverse=True)


async def cb_mt_restore(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    r = await run_bot_action("backup-list", timeout=60)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "sec_maint")
        return
    names = _backup_names(r)
    # Имя файла в callback_data не влезает (до 128 символов) — храним список в
    # сессии и кладём в кнопку индекс; при выборе список перечитывается.
    context.user_data["backups"] = names
    rows = [[btn(name, "mt_rs~%d" % i)] for i, name in enumerate(names[:20])]
    rows.append(_back_row(user_id, "sec_maint"))
    text = "<b>%s</b>\n\n%s" % (_t(user_id, "mt_restore"), _t(user_id, "restore_pick") if names else _t(user_id, "mt_no_backups"))
    await safe_edit_message(query, text, reply_markup=InlineKeyboardMarkup(rows))


async def cb_mt_restore_pick(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    try:
        idx = int(query.data.split("~", 1)[1])
    except (ValueError, IndexError):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    names = context.user_data.get("backups") or []
    if idx < 0 or idx >= len(names):
        await query.answer(_t(user_id, "flow_expired"), show_alert=True)
        return
    await query.answer()
    name = names[idx]
    await arm_typed_confirm(query, context, user_id, "backup-restore", name, back_to="mt_restore",
                            warn="%s\n\n<code>%s</code>" % (_t(user_id, "mt_restore_warn"), esc(name)))


# ── Обновления Amnezia (lib/upstream.sh, PLAN §6.8) ───────────────────────────

def upstream_text(user_id: Optional[int], r: Dict[str, Any]) -> str:
    """Таблица профилей: текущий образ → доступный, релиз клиента, новые
    неподдержанные параметры. Работает и на ответе unreachable: мост кладёт в
    него текущие версии профилей, без колонки «доступно»."""
    lines = ["<b>%s</b>" % _t(user_id, "mt_upstream_title"), ""]
    ok = bridge_ok(r)
    if not ok:
        lines.append("⚠️ " + error_text(user_id, r))
        lines.append("")
    rel = r.get("client_release") if isinstance(r.get("client_release"), dict) else {}
    if rel:
        if rel.get("update"):
            lines.append(_tf(user_id, "up_release_fmt", esc(rel.get("current") or "?"), esc(rel.get("tag") or "?")))
        else:
            lines.append(_tf(user_id, "up_release_current_fmt", esc(rel.get("current") or rel.get("tag") or "?")))
    profiles = r.get("profiles") if isinstance(r.get("profiles"), list) else []
    for item in profiles:
        if not isinstance(item, dict):
            continue
        pid = esc(profile_name(user_id, item.get("profile")))
        cur = esc(item.get("current_tag") or "—")
        if item.get("update"):
            lines.append("⬆️ " + _tf(user_id, "up_profile_update_fmt", pid, cur, esc(item.get("available_tag") or "?")))
        else:
            lines.append("✅ " + _tf(user_id, "up_profile_current_fmt", pid, cur))
        if item.get("rollback_available"):
            lines.append("    ↩️ " + _tf(user_id, "up_rollback_hint_fmt", esc(item.get("previous_tag") or "?")))
    if not profiles:
        lines.append("<i>%s</i>" % _t(user_id, "up_none"))
    names = sorted({str(u.get("name")) for u in (r.get("unsupported") or []) if isinstance(u, dict) and u.get("name")})
    if names:
        lines.append("")
        lines.append("⚠️ " + _tf(user_id, "up_unsupported_fmt", esc(", ".join(names))))
    lines.append("")
    lines.append(_t(user_id, "up_done_hint") if ok else _t(user_id, "up_unreachable_hint"))
    return "\n".join(lines)


def upstream_rows(user_id: Optional[int], r: Dict[str, Any]) -> list:
    """Кнопки: «Обновить» — у профилей с update, «Откатить» — где есть previous."""
    rows = []
    for item in (r.get("profiles") if isinstance(r.get("profiles"), list) else []):
        if not isinstance(item, dict) or not valid_profile(str(item.get("profile") or "")):
            continue
        pid = str(item["profile"])
        short = profile_short(pid, None, user_id)
        row = []
        if item.get("update"):
            row.append(btn(_tf(user_id, "up_btn_update_fmt", short), "up_upd~%s" % pid))
        if item.get("rollback_available"):
            row.append(btn(_tf(user_id, "up_btn_rollback_fmt", short), "up_rb~%s" % pid))
        # Ремонт предлагается ВСЕГДА, а не только когда есть что обновлять: сюда
        # человек приходит после сорвавшегося обновления, когда контейнера уже нет,
        # и «обновить» с «откатить» в этот момент как раз и не показываются.
        row.append(btn(_tf(user_id, "up_btn_repair_fmt", short), "up_fix~%s" % pid))
        if row:
            rows.append(row)
    rows.append([btn(_t(user_id, "btn_refresh"), "mt_upstream")])
    rows.append(_back_row(user_id, "sec_maint"))
    return rows


async def cb_mt_upstream(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    await safe_edit_message(query, "⏳ " + _t(user_id, "up_checking"), reply_markup=None)
    r = await run_bot_action("upstream-check", timeout=120)
    # Ответ кладём в сессию: экраны подтверждения берут отсюда доступный тег.
    context.user_data["upstream"] = r
    await safe_edit_message(query, clip_lines(upstream_text(user_id, r)), reply_markup=InlineKeyboardMarkup(upstream_rows(user_id, r)))


def _upstream_item(context, profile: str) -> Dict[str, Any]:
    r = context.user_data.get("upstream") or {}
    for item in (r.get("profiles") if isinstance(r.get("profiles"), list) else []):
        if isinstance(item, dict) and item.get("profile") == profile:
            return item
    return {}


async def cb_up_update(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """up_upd~<profile> → фраза UPDATE <profile>: обновление ядра с бэкапом и откатом."""
    query = update.callback_query
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "up_upd~")
    if not profile:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    item = _upstream_item(context, profile)
    await arm_typed_confirm(query, context, user_id, "upstream-update", profile, back_to="mt_upstream",
                            warn=_tf(user_id, "up_update_warn_fmt", esc(profile_name(user_id, profile)),
                                     esc(item.get("available_tag") or "?")))


async def cb_up_repair(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """up_fix~<profile> → фраза REPAIR <profile>: пересоздать контейнер на том же
    закреплённом образе из сохранённого состояния. Ключи и настройки не трогаются,
    но связь рвётся — поэтому фраза, а не кнопка."""
    query = update.callback_query
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "up_fix~")
    if not profile:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    await arm_typed_confirm(query, context, user_id, "core-update", profile, back_to="mt_upstream",
                            warn=_tf(user_id, "up_repair_warn_fmt", esc(profile_name(user_id, profile))))


async def cb_up_rollback(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """up_rb~<profile> → фраза ROLLBACK <profile>: прежний образ и скрипты."""
    query = update.callback_query
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "up_rb~")
    if not profile:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    item = _upstream_item(context, profile)
    warn = _tf(user_id, "up_rollback_warn_fmt", esc(profile_name(user_id, profile)), esc(item.get("previous_tag") or "?"))
    if item.get("previous_tag") and not item.get("previous_digest"):
        # Точного отпечатка прежнего образа нет (подхваченный профиль): «вернуть тот самый» — неправда
        warn += "\n\n⚠️ " + _tf(user_id, "up_rollback_floating_fmt", esc(item.get("previous_tag")))
    await arm_typed_confirm(query, context, user_id, "upstream-rollback", profile, back_to="mt_upstream", warn=warn)


# ── Импорт существующей установки (lib/import.sh, PLAN §6.5) ──────────────────

CONTAINER_RE = re.compile(r"^amnezia-[a-z0-9-]{2,32}$")
# Причины «нельзя подхватить» — ключи словаря mt_import_reason_<причина>.
IMPORT_REASONS = ("unsupported_container", "unknown_kind", "managed", "profile_exists", "no_conf")


def valid_container(v: str) -> bool:
    return bool(CONTAINER_RE.match(v or ""))


def _import_profile_title(user_id: Optional[int], profile: Any, line: Any = "", port: Any = 0) -> str:
    """Профиль, которым станет подхваченный контейнер: линия и порт контейнера, если сканер их назвал (у профиля ещё
    нет status), — «AmneziaWG 3.1 · порт 46567 · из приложения» (DUP-LINE-01: без имени места)."""
    profile = str(profile or "")
    line = str(line or "")
    if profile in PROFILE_IDS and line:
        return profile_label(user_id, line, port, imported=True)
    return profile_title(user_id, profile)


def import_scan_text(user_id: Optional[int], r: Dict[str, Any]) -> str:
    lines = ["<b>%s</b>" % _t(user_id, "mt_import_title"), ""]
    items = r.get("containers") if isinstance(r.get("containers"), list) else []
    if not items:
        lines.append("<i>%s</i>" % _t(user_id, "mt_import_none"))
        return "\n".join(lines)
    for c in items:
        if not isinstance(c, dict):
            continue
        port = "%s %s" % (str(c.get("proto") or "udp").upper(), c.get("port") or "—")
        head = "<code>%s</code> · %s" % (esc(c.get("container")), esc(port))
        if c.get("line"):
            head += " · AmneziaWG %s · %s" % (esc(c.get("line")), _tf(user_id, "peers_count_fmt", int(c.get("peers") or 0)))
        if c.get("managed"):
            lines.append("✓ %s\n    %s" % (head, _tf(user_id, "mt_import_managed_fmt", esc(profile_title(user_id, c.get("profile"))))))
        elif c.get("adoptable"):
            lines.append("📥 %s\n    %s" % (head, _tf(user_id, "mt_import_adoptable_fmt",
                                                        esc(_import_profile_title(user_id, c.get("suggested_profile"), c.get("line"), c.get("port"))))))
        else:
            reason = str(c.get("reason") or "unknown_kind")
            if reason not in IMPORT_REASONS:
                reason = "unknown_kind"
            lines.append("· %s\n    %s" % (head, _t(user_id, "mt_import_reason_%s" % reason)))
    lines.append("")
    lines.append(_t(user_id, "mt_import_legend"))
    return "\n".join(lines)


def import_rows(user_id: Optional[int], r: Dict[str, Any]) -> list:
    rows = []
    for c in (r.get("containers") if isinstance(r.get("containers"), list) else []):
        if not isinstance(c, dict):
            continue
        name = str(c.get("container") or "")
        if c.get("adoptable") and valid_container(name):
            rows.append([btn(_tf(user_id, "mt_import_btn_adopt_fmt", name), "imp_adopt~%s" % name)])
        elif c.get("managed") and valid_profile(str(c.get("profile") or "")):
            rows.append([btn(_tf(user_id, "mt_import_btn_reconcile_fmt", profile_short(c["profile"], None, user_id)), "imp_rec~%s" % c["profile"])])
    rows.append([btn(_t(user_id, "btn_refresh"), "mt_import")])
    rows.append(_back_row(user_id, "sec_maint"))
    return rows


async def cb_mt_import(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    r = await run_bot_action("import-scan", timeout=60)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "sec_maint")
        return
    context.user_data["import_scan"] = r
    await safe_edit_message(query, clip_lines(import_scan_text(user_id, r)), reply_markup=InlineKeyboardMarkup(import_rows(user_id, r)))


def _import_item(context, container: str) -> Dict[str, Any]:
    r = context.user_data.get("import_scan") or {}
    for c in (r.get("containers") if isinstance(r.get("containers"), list) else []):
        if isinstance(c, dict) and c.get("container") == container:
            return c
    return {}


async def cb_imp_adopt(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """imp_adopt~<container>: что будет сделано и кнопка подтверждения (не
    разрушительное: контейнер не пересоздаётся, ключи не меняются)."""
    query = update.callback_query
    user_id = _uid(update)
    name = query.data.split("~", 1)[1] if "~" in query.data else ""
    if not valid_container(name):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    item = _import_item(context, name)
    body = _tf(user_id, "mt_import_adopt_body_fmt", esc(name),
               esc(_import_profile_title(user_id, item.get("suggested_profile"), item.get("line")) or "?"),
               int(item.get("peers") or 0))
    rows = [[btn(_t(user_id, "mt_import_adopt_btn"), "imp_adopt_do~%s" % name)], _back_row(user_id, "mt_import")]
    await safe_edit_message(query, "<b>%s</b>\n\n%s\n\n%s" % (_tf(user_id, "mt_import_adopt_title_fmt", esc(name)), body,
                                                              _t(user_id, "mt_import_no_privkey_hint")),
                            reply_markup=InlineKeyboardMarkup(rows))


async def cb_imp_adopt_do(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    name = query.data.split("~", 1)[1] if "~" in query.data else ""
    if not valid_container(name):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    if await _action_busy(query, user_id, "mt_import"):
        return
    await safe_edit_message(query, "⏳ " + _tf(user_id, "mt_import_adopting_fmt", esc(name)), reply_markup=None)
    r = await mutate("import-adopt", who=user_id, container=name)
    ovr = r.get("subnet_overlap") if bridge_ok(r) and isinstance(r.get("subnet_overlap"), dict) else {}
    if bridge_ok(r):
        users = [esc(u) for u in (r.get("users") if isinstance(r.get("users"), list) else [])]
        adopted = _import_profile_title(user_id, r.get("profile"), r.get("line")) or "?"
        text = "✅ " + _tf(user_id, "mt_import_adopted_fmt", esc(name), esc(adopted), int(r.get("users_added") or 0))
        if users:
            text += "\n" + _tf(user_id, "mt_import_users_fmt", ", ".join(users))
        text += "\n\n" + _t(user_id, "mt_import_no_privkey_hint")
        # Подсеть совпала с другим профилем (SUBNET-01): подхвачен как есть — с кем и выход, кнопкой.
        if ovr:
            text += "\n\n⚠️ " + _t(user_id, "mt_import_overlap") + " " + subnet_overlap_text(user_id, ovr)
        text += adopt_ipacket_warnings_text(r)
    else:
        text = fail_text(user_id, r)
    markup = fail_markup(user_id, r, "mt_import", retry_data(query))
    if bridge_ok(r):
        # Подхваченные люди уже в списке — к ним одной кнопкой (сцена import-done)
        mv = subnet_move_of(ovr)
        markup = InlineKeyboardMarkup(([subnet_move_row(user_id, mv)] if mv else []) +
                                      [[btn(_t(user_id, "menu_users"), "menu_users")], _back_row(user_id, "mt_import")])
    await safe_edit_message(query, text, reply_markup=markup)


def adopt_ipacket_warnings_text(r: Dict[str, Any]) -> str:
    """Подхват с тегами I1–I5, которые понимает не каждая реализация (KMOD-02): контейнер подхвачен, но клиенты одной
    из реализаций с таким I не подключатся — слова ядра (ipacket_warnings, язык сервера), по строке с ⚠️; нет — пусто."""
    items = r.get("ipacket_warnings") if isinstance(r.get("ipacket_warnings"), list) else []
    return "".join("\n\n⚠️ " + esc(str(w)) for w in items if isinstance(w, str) and w.strip())


def reconcile_text(user_id: Optional[int], r: Dict[str, Any]) -> str:
    profile = esc(profile_name(user_id, r.get("profile")) or "?")
    lines = ["<b>%s</b>" % _tf(user_id, "mt_import_reconcile_title_fmt", profile), ""]
    # Пиры контейнера, которых сверка не подхватит (не ключ, ключ другого профиля, нет IPv4), — причиной словами ядра,
    # а не «добавлено 0» без слов (KEENETIC-I1-N, N2). Расхождением они не считаются.
    skipped = ["⚠️ " + esc(str(x.get("message")).strip()) for x in (r.get("skipped") if isinstance(r.get("skipped"), list) else [])
               if isinstance(x, dict) and str(x.get("message") or "").strip()]
    if r.get("in_sync"):
        lines.append("✅ " + _tf(user_id, "mt_import_in_sync_fmt", profile))
        lines.extend(skipped)
        return "\n".join(lines)
    for item in (r.get("new") if isinstance(r.get("new"), list) else []):
        if isinstance(item, dict):
            lines.append("+ " + _tf(user_id, "mt_import_new_fmt", esc(item.get("name") or "?"), esc(item.get("ip") or "?")))
    for item in (r.get("gone") if isinstance(r.get("gone"), list) else []):
        if isinstance(item, dict):
            lines.append("− " + _tf(user_id, "mt_import_gone_fmt", esc(item.get("name") or "?")))
    lines.extend(skipped)
    if r.get("applied"):
        lines.append("")
        lines.append("✅ " + _tf(user_id, "mt_import_applied_fmt", int(r.get("added") or 0), int(r.get("deactivated") or 0)))
    return "\n".join(lines)


async def cb_imp_rec(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """imp_rec~<profile>: сверка пиров контейнера с users.json без записи."""
    query = update.callback_query
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "imp_rec~")
    if not profile:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    if await _action_busy(query, user_id, "mt_import"):
        return
    r = await mutate("import-reconcile", who=user_id, profile=profile, apply="off")
    if not bridge_ok(r):
        await show_error(query, user_id, r, "mt_import")
        return
    rows = []
    if not r.get("in_sync"):
        rows.append([btn(_t(user_id, "mt_import_apply_btn"), "imp_rec_do~%s" % profile)])
    rows.append(_back_row(user_id, "mt_import"))
    await safe_edit_message(query, reconcile_text(user_id, r), reply_markup=InlineKeyboardMarkup(rows))


async def cb_imp_rec_do(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    profile = _profile_from_data(query.data, "imp_rec_do~")
    if not profile:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    if await _action_busy(query, user_id, "mt_import"):
        return
    await safe_edit_message(query, "⏳ " + _t(user_id, "wait"), reply_markup=None)
    r = await mutate("import-reconcile", who=user_id, profile=profile, apply="on")
    text = reconcile_text(user_id, r) if bridge_ok(r) else fail_text(user_id, r)
    await safe_edit_message(query, text, reply_markup=fail_markup(user_id, r, "mt_import", retry_data(query)))


def diag_text(user_id: Optional[int], r: Dict[str, Any], status: Optional[Dict[str, Any]] = None) -> str:
    """Диагностика словами. Профиль — линией («AmneziaWG 3.1 · UDP 1320»), как на остальных экранах, а не служебным
    id «awg3» (живая проверка на test1, 03.10); status — чтобы назвать линию профиля на 1.0 или 1.5 точно."""
    q = r.get("quality") if isinstance(r.get("quality"), dict) else {}
    lines = ["<b>%s</b>" % _t(user_id, "mt_diag_title"), ""]

    def good(flag: Any) -> bool:
        return flag in (True, "true", "1", 1)

    # Словами, как в SSH-диагностике, а не сырыми именами «ip_forward» и
    # «amnezia-dns-net», которые человеку ни о чём не говорят (T30).
    docker_ok = good(q.get("docker"))
    lines.append("✅ " + _t(user_id, "diag_docker_ok") if docker_ok else "❌ " + _t(user_id, "diag_docker_unreachable"))
    # Версии клиента и демона: рассогласование (пакет обновлён автообновлением,
    # демон не перезапускался) выглядит как «всё выключено» на работающем VPN.
    dock = q.get("docker_info") if isinstance(q.get("docker_info"), dict) else {}
    if dock.get("installed"):
        lines.append("   <code>%s</code>" % esc("%s (API %s) → %s (API %s)" % (
            dock.get("client_version") or "?", dock.get("client_api") or "?",
            dock.get("daemon_version") or "?", dock.get("daemon_api") or "?")))
        if not dock.get("reachable") and docker_ok:
            # «Демон не отвечает» — ровно одной строкой: при docker=false она уже стоит выше
            lines.append("   ⚠️ %s" % _t(user_id, "diag_docker_unreachable"))
        if dock.get("stale"):
            # Пакет обновлён, а служба старая (DK-02): версии и с какого дня; лечит сторож сам или кнопка ниже.
            lines.append("   ⚠️ %s" % _tf(user_id, "diag_docker_stale_fmt",
                                         esc(dock.get("binary_label") or dock.get("binary_version") or dock.get("client_version") or "?"),
                                         esc(dock.get("daemon_label") or dock.get("daemon_version") or "?")))
            if dock.get("stale_since"):
                lines.append("   %s" % _tf(user_id, "diag_docker_stale_since_fmt", esc(_ntf_date(dock.get("stale_since")))))
        elif dock.get("mismatch"):
            lines.append("   ⚠️ %s" % _t(user_id, "diag_docker_mismatch"))
    if str(q.get("ip_forward")) == "1":
        lines.append("✅ " + _t(user_id, "diag_forward_on"))
    else:
        lines.append("❌ " + _t(user_id, "diag_forward_off"))
    lines.append("✅ " + _t(user_id, "diag_net_ok") if good(q.get("network")) else "⚠️ " + _t(user_id, "diag_net_bad"))
    disk = _as_int(q.get("disk_free_mb"))
    if "disk_free_mb" in q and disk < 1024:
        # Порог SSH-диагностики (GA_AMN_MIN_DISK_MB): ниже не пройдёт обновление ядра.
        lines.append("⚠️ " + _tf(user_id, "diag_disk_low_fmt", disk))
    else:
        lines.append("💽 " + _tf(user_id, "diag_disk_fmt", esc(q.get("disk_free_mb") or 0)))
    # Ключ сервера в трёх хранилищах (config.json, копия состояния, конфиг контейнера):
    # расхождение значит «выданные ключи перестанут подключаться». SSH-диагностика это
    # показывает, бот молчал и рисовал одни зелёные галочки.
    for k in (q.get("server_keys") if isinstance(q.get("server_keys"), list) else []):
        if isinstance(k, dict) and k.get("profile"):
            ok = k.get("ok") is True
            lines.append("%s %s" % ("✅" if ok else "❌", _tf(user_id, "diag_keys_ok_fmt" if ok else "diag_keys_bad_fmt",
                                                             esc(profile_name(user_id, k.get("profile"), status)))))
    # Таймеры (лимиты, сторож, статистика, обновления, сертификат, бэкап, журналы):
    # выключенный или падающий на каждом тике виден только здесь — как в SSH.
    timers = [t for t in (q.get("timers") if isinstance(q.get("timers"), list) else [])
              if isinstance(t, dict) and t.get("name")]
    bad = []
    for tm in timers:
        state, last = str(tm.get("state") or ""), str(tm.get("last") or "")
        if state == "inactive":
            bad.append("⚠️ " + _tf(user_id, "diag_timer_off_fmt", esc(tm.get("name"))))
        elif state == "missing":
            bad.append("⚠️ " + _tf(user_id, "diag_timer_missing_fmt", esc(tm.get("name"))))
        elif last and last not in ("success", "-"):
            bad.append("⚠️ " + _tf(user_id, "diag_timer_failed_fmt", esc(tm.get("name")), esc(last)))
    if timers:
        lines.extend(bad or ["✅ " + _t(user_id, "diag_timers_ok")])
    ports = q.get("ports") if isinstance(q.get("ports"), list) else []
    for item in ports:
        if not isinstance(item, dict):
            continue
        # free=true означает, что порт никто не слушает — для работающего
        # контейнера это плохой знак, поэтому «занят» здесь = хорошо.
        listening = item.get("free") in (False, "false")
        lines.append("%s %s · UDP %s — %s" % ("✅" if listening else "⚠️", esc(profile_name(user_id, item.get("profile"), status)),
                                               esc(item.get("port")),
                                               _t(user_id, "diag_port_listening") if listening else _t(user_id, "diag_port_silent")))
    if not q:
        lines.append("<i>%s</i>" % _t(user_id, "err_unknown"))
    return "\n".join(lines)


async def cb_mt_diag(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    r = await run_bot_action("quality", timeout=60)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "sec_maint")
        return
    status = await get_status()
    # «Перезапустить Docker» (DK-02) — здесь, рядом с тем, что показывает версии Docker: служба старая после
    # обновления пакета или ведёт себя странно. Кнопка ведёт на вопрос, а не перезапускает сразу.
    await safe_edit_message(query, diag_text(user_id, r, status if bridge_ok(status) else None),
                            reply_markup=InlineKeyboardMarkup([[btn(_t(user_id, "btn_refresh"), "mt_diag")],
                                                               [btn(_t(user_id, "mt_dkr"), "mt_dkr")],
                                                               _back_row(user_id, "sec_maint")]))


async def cb_mt_dkr(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """mt_dkr: «Перезапустить Docker» — что будет (VPN пропадёт у всех на 10–30 секунд) и согласие (DK-02)."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    rows = [[btn(_t(user_id, "btn_confirm"), "mt_dkr_do")], _back_row(user_id, "mt_diag")]
    if await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "mt_dkr"), _t(user_id, "mt_dkr_body")),
                               reply_markup=InlineKeyboardMarkup(rows)):
        _rearm_callback(context, query, "mt_dkr_do")


@_once_callback
async def cb_mt_dkr_do(update: Update, context: ContextTypes.DEFAULT_TYPE, attempt) -> None:
    """mt_dkr_do: docker-restart — служба Docker и подъём профилей (интерфейс, изоляция, соседи, goWARP). Итог — за
    сколько секунд, какая служба теперь и какие профили поднялись; отказ — словами и ручной командой. Одно нажатие —
    один перезапуск: второе, пока идёт запрос к Telegram, ничего не повторяет (_once_callback)."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    if await _action_busy(query, user_id, "mt_diag"):
        return
    await safe_edit_message(query, "⏳ " + _t(user_id, "mt_dkr_wait"), reply_markup=None)
    r = await _callback_mutate(attempt, "docker-restart", who=user_id)
    done = [p for p in (r.get("restarted") if isinstance(r.get("restarted"), list) else []) if isinstance(p, str)]
    names = esc(profile_names(user_id, done))
    if bridge_ok(r):
        lines = ["✅ " + _tf(user_id, "mt_dkr_done_fmt", esc(r.get("duration_s") if r.get("duration_s") is not None else "?"),
                              esc(r.get("daemon_after_label") or r.get("daemon_after") or "?"))]
        if names:
            lines.append(_tf(user_id, "mt_dkr_profiles_fmt", names))
        await safe_edit_message(query, "\n".join(lines), reply_markup=back_kb(user_id, "mt_diag"))
        return
    if is_lock_busy(r):
        await safe_edit_message(query, fail_text(user_id, r), reply_markup=fail_markup(user_id, r, "mt_diag", retry_data(query)))
        return
    lines = ["❌ " + _tf(user_id, "mt_dkr_failed_fmt", docker_restart_why(user_id, r))]
    if names:
        lines.append(_tf(user_id, "mt_dkr_profiles_fmt", names))
    lines.append(_t(user_id, "mt_dkr_manual"))
    await safe_edit_message(query, "\n".join(lines), reply_markup=back_kb(user_id, "mt_diag"))


async def cb_mt_selfupdate(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "mt_selfupdate"), _t(user_id, "mt_selfupdate_hint")),
                            reply_markup=back_kb(user_id, "sec_maint"))


# ── Ускорение AmneziaWG: модуль ядра по выбору человека (KMOD_PLAN этап Б, CONTRACT §4.7a) ─────────────────────────────
# «⚙️ Обслуживание → ⚡ Ускорение AmneziaWG» — то же, что SSH «Обслуживание → 9»: что сейчас (программа или модуль),
# ядро, движок каждого профиля, причина словами ядра; кнопки по состоянию. «Включить» — проверка хоста (kmod-check,
# только чтение) и согласие кнопками с тем, что поставит apt (и вопрос о метапакете заголовков, если он тянет новое ядро,
# KMOD-05); «Вернуть программу», «Пересобрать», «Удалить модуль» — вопрос с предупреждением. Действие — цепочка моста под
# замком бота (enable: kmod-install, затем kmod-engine --engine=kernel; rebuild — с возвратом на модуль), ход — правкой
# того же сообщения раз в KMOD_PROGRESS_EVERY секунд по kmod-status.progress.text (чтение замка не берёт), итог — одним
# сообщением на его месте. Только админам — как весь бот (handle_callback). По умолчанию — программа amneziawg-go; модуль —
# только по нажатию человека, сам продукт движок не меняет. Новых событий этап Б боту не шлёт.
KMOD_PROGRESS_EVERY = 5.0
KMOD_OPS = ("enable", "program", "rebuild", "remove")
KMOD_ENGINE_WORDS = {"kernel": "km_word_kernel", "program": "km_word_program", "stopped": "km_word_stopped",
                     "unknown": "km_word_unknown"}
KMOD_BUSY_TITLES = {"enable": "km_busy_enable", "program": "km_busy_program", "rebuild": "km_busy_rebuild",
                    "remove": "km_busy_remove"}
KMOD_FAIL_TITLES = {"enable": "km_fail_enable", "program": "km_fail_program", "rebuild": "km_fail_rebuild",
                    "remove": "km_fail_remove"}
# Путь SSH-меню в скобках в конце причины («Обслуживание → Ускорение AmneziaWG → 3»): в боте кнопка — тут же.
KMOD_SSH_PATH_RE = re.compile(r"\s*\((?:Обслуживание|Maintenance) → [^)]*\)\s*$")
# Команда удаления пакетов сборки из ответа kmod-remove: apt remove и имена пакетов — иначе собираем её сами.
KMOD_APT_CMD_RE = re.compile(r"^apt(-get)? remove( [a-z0-9][a-z0-9.+-]{0,127}){1,32}$")
KMOD_PKG_RE = re.compile(r"^[a-z0-9][a-z0-9.+-]{0,127}$")


def kmod_of(r: Any) -> Dict[str, Any]:
    """kmod-status.kmod или status.kmod этапа Б (со state) — иначе {}: ядро старше 1.0.13 или запись испорчена."""
    km = r.get("kmod") if isinstance(r, dict) else None
    return km if isinstance(km, dict) and isinstance(km.get("state"), str) and km.get("state") else {}


def kmod_reason(text: Any, cap: bool = True) -> str:
    """Причина словами ядра (с ядром, к которому относится) без пути SSH-меню в скобках; cap — с заглавной буквы."""
    s = KMOD_SSH_PATH_RE.sub("", str(text or "")).strip()
    return s[:1].upper() + s[1:] if cap else s


def kmod_word(user_id: Optional[int], engine: Any) -> str:
    return _t(user_id, KMOD_ENGINE_WORDS.get(str(engine or ""), "km_word_unknown"))


def kmod_profiles_order(km: Dict[str, Any]) -> List[str]:
    profs = km.get("profiles") if isinstance(km.get("profiles"), dict) else {}
    return [p for p in PROFILE_IDS if p in profs]


def kmod_screen_text(user_id: Optional[int], km: Dict[str, Any]) -> str:
    lines = ["<b>%s</b>" % _t(user_id, "km_title"), "", "<i>%s</i>" % _t(user_id, "km_note"), ""]
    if not km:
        lines.append("⚠️ " + _t(user_id, "km_unknown"))
        return "\n".join(lines)
    st = str(km.get("state") or "")
    ver = str(km.get("version") or km.get("installed_version") or "")
    if st == "on":
        now = _tf(user_id, "km_now_kernel_fmt", esc(ver))
    else:
        now = _t(user_id, "km_now_busy" if st == "busy" else "km_now_program")
    lines.append("%s: <b>%s</b>" % (_t(user_id, "km_now"), now))
    lines.append("%s: <code>%s</code>" % (_t(user_id, "km_kernel"), esc(km.get("kernel") or "—")))
    profs = km.get("profiles") if isinstance(km.get("profiles"), dict) else {}
    rows = ["%s — %s" % (esc(profile_name(user_id, p)), kmod_word(user_id, (profs.get(p) or {}).get("engine")))
            for p in kmod_profiles_order(km)]
    if rows:
        lines.append("%s: %s" % (_t(user_id, "km_profiles"), " · ".join(rows)))
    if st == "ready":
        lines.append("<i>%s</i>" % _tf(user_id, "km_ready_fmt", esc(ver)))
    elif st == "off":
        lines.append("<i>%s</i>" % _t(user_id, "km_off"))
    if st in ("fallback", "failed", "unpatched") and km.get("reason"):
        lines.append("")
        lines.append("⚠️ " + esc(kmod_reason(km.get("reason"))))
        failed = km.get("failed") if isinstance(km.get("failed"), dict) else {}
        if st == "failed" and failed.get("log"):
            lines.append(_tf(user_id, "km_failed_log_fmt", esc(failed.get("log"))))
    if st == "busy":
        prog = km.get("progress") if isinstance(km.get("progress"), dict) else {}
        lines.append("")
        lines.append(_tf(user_id, "km_busy_now_fmt", esc(prog.get("text") or _t(user_id, "km_busy_wait"))))
    if km.get("want") == "program" and st not in ("off", "busy"):
        lines.append("<i>%s</i>" % _t(user_id, "km_want_program"))
    if km.get("owner") == "kaskad":
        lines.append("<i>%s</i>" % _t(user_id, "km_neighbour"))
    return "\n".join(lines)


def kmod_screen_keyboard(user_id: Optional[int], km: Dict[str, Any]) -> "InlineKeyboardMarkup":
    """Кнопки по состоянию — как в SSH, неприменимых нет: «Включить» (кроме уже включённого), «Вернуть программу» (выбран
    модуль или профиль на нём), «Пересобрать» и «Удалить модуль» (модуль ставила goAmnezia). Выбран модуль, а модуля под
    новое ядро нет, — первой «Пересобрать». Идёт установка или перевод — только «Обновить»."""
    rows: list = []
    st = str(km.get("state") or "") if km else ""
    if km and st != "busy":
        profs = km.get("profiles") if isinstance(km.get("profiles"), dict) else {}
        on_kernel = any(isinstance(v, dict) and v.get("engine") == "kernel" for v in profs.values())
        ours = km.get("owner") == "goamnezia"
        want = km.get("want")
        rebuild_first = ours and st == "fallback" and km.get("code") != "profiles_on_program"
        if rebuild_first:
            rows.append([btn(_t(user_id, "km_btn_rebuild"), "km_rb")])
        elif not (want == "kernel" and st == "on"):
            rows.append([btn(_t(user_id, "km_btn_enable"), "km_on")])
        if want == "kernel" or on_kernel:
            rows.append([btn(_t(user_id, "km_btn_program"), "km_prog")])
        if ours and not rebuild_first:
            rows.append([btn(_t(user_id, "km_btn_rebuild"), "km_rb")])
        if ours or want == "kernel":
            rows.append([btn(_t(user_id, "km_btn_remove"), "km_rm")])
    rows.append([btn(_t(user_id, "btn_refresh"), "mt_kmod"), btn(_t(user_id, "btn_back"), "sec_maint")])
    return InlineKeyboardMarkup(rows)


async def kmod_status(user_id: Optional[int]) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    """(ответ моста kmod-status, kmod этапа Б или {})."""
    r = await run_bot_action("kmod-status", timeout=60, who=user_id)
    return r, (kmod_of(r) if bridge_ok(r) else {})


async def cb_mt_kmod(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """mt_kmod: «⚡ Ускорение AmneziaWG» — состояние и кнопки по нему."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    r, km = await kmod_status(user_id)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "sec_maint")
        return
    await safe_edit_message(query, kmod_screen_text(user_id, km), reply_markup=kmod_screen_keyboard(user_id, km))


def kmod_consent(user_id: Optional[int], check: Dict[str, Any]) -> Tuple[str, list]:
    """Согласие на модуль (рецепт §13): что поставит apt и сколько места, сборка 1–3 минуты, что даст; метапакет
    заголовков, который тянет новое ядро, — отдельной кнопкой (по умолчанию не ставится, KMOD-05)."""
    plan = check.get("plan") if isinstance(check.get("plan"), dict) else {}
    lines = ["<b>%s</b>" % _t(user_id, "km_consent_q"), ""]
    reuse = check.get("reuse") is True
    if reuse:
        mod = check.get("module") if isinstance(check.get("module"), dict) else {}
        lines.append(_tf(user_id, "km_plan_reuse_fmt", esc(mod.get("ko_version") or "")))
    else:
        miss = [str(x) for x in (plan.get("missing") if isinstance(plan.get("missing"), list) else []) if isinstance(x, str)]
        if miss:
            size = plan.get("size_mb")
            lines.append(_tf(user_id, "km_plan_packages_fmt", esc(", ".join(miss)), esc(size if size is not None else "?")))
        else:
            lines.append(_t(user_id, "km_plan_no_packages"))
        lines.append("<i>%s</i>" % _t(user_id, "km_plan_build"))
    meta = plan.get("headers_meta") if not reuse and isinstance(plan.get("headers_meta"), dict) else {}
    pulls_kernel = bool(meta) and meta.get("installed") is not True and meta.get("kernel") is True
    if meta and meta.get("installed") is not True:
        lines.append("")
        if pulls_kernel:
            msize = meta.get("size_mb")
            lines.append("⚠️ " + _tf(user_id, "km_meta_warn_fmt", esc(meta.get("name") or ""), esc(msize if msize is not None else "?")))
        else:
            lines.append("<i>%s</i>" % _tf(user_id, "km_meta_auto_fmt", esc(meta.get("name") or "")))
    lines.append("")
    lines.append(_t(user_id, "km_consent_d"))
    rows: list = []
    if pulls_kernel:
        rows.append([btn(_t(user_id, "km_btn_yes_nometa"), "km_go~enable~off")])
        rows.append([btn(_t(user_id, "km_btn_yes_meta"), "km_go~enable~on")])
    else:
        rows.append([btn(_t(user_id, "km_btn_yes"), "km_go~enable~off")])
    rows.append([btn(_t(user_id, "km_btn_no"), "km_no")])
    return "\n".join(lines), rows


async def cb_km_on(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """km_on: «Включить» — проверка сервера (одной фразой, если нельзя) и согласие кнопками. Ничего не ставит."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    await safe_edit_message(query, "⏳ " + _t(user_id, "km_checking"), reply_markup=None)
    r = await run_bot_action("kmod-check", who=user_id)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "mt_kmod")
        return
    check = r.get("check") if isinstance(r.get("check"), dict) else {}
    if not check:
        await safe_edit_message(query, "⚠️ " + _t(user_id, "km_unknown"), reply_markup=back_kb(user_id, "mt_kmod"))
        return
    if check.get("ok") is not True:
        why = kmod_reason(check.get("reason") or check.get("code") or "")
        await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "km_not_here"), esc(why)),
                                reply_markup=back_kb(user_id, "mt_kmod"))
        return
    text, rows = kmod_consent(user_id, check)
    if await safe_edit_message(query, text, reply_markup=InlineKeyboardMarkup(rows)):
        _rearm_callback(context, query, "km_go~")


async def cb_km_no(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """km_no: «Нет, оставить программу» — ничего не поставлено."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    await safe_edit_message(query, _t(user_id, "km_declined"), reply_markup=back_kb(user_id, "mt_kmod"))


async def _kmod_ask(query, context, user_id: Optional[int], title_key: str, text: str, do_key: str, op: str) -> None:
    rows = [[btn(_t(user_id, do_key), "km_go~%s" % op)], _back_row(user_id, "mt_kmod")]
    if await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, title_key), text), reply_markup=InlineKeyboardMarkup(rows)):
        _rearm_callback(context, query, "km_go~")


async def cb_km_prog(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """km_prog: «Вернуть программу» — по одному, люди переподключатся за 15–25 секунд; вопрос."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    _, km = await kmod_status(user_id)
    names = esc(profile_names(user_id, kmod_profiles_order(km))) or "—"
    await _kmod_ask(query, context, user_id, "km_program_q", _tf(user_id, "km_program_warn_fmt", names), "km_btn_program_do", "program")


async def cb_km_rb(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """km_rb: «Пересобрать» — под нынешнее ядро; профили на модуле на время уходят на программу; вопрос."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    _, km = await kmod_status(user_id)
    await _kmod_ask(query, context, user_id, "km_rebuild_q", _tf(user_id, "km_rebuild_warn_fmt", esc(km.get("kernel") or "?")),
                    "km_btn_rebuild_do", "rebuild")


async def cb_km_rm(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """km_rm: «Удалить модуль» — профили на программу, модуль прочь (или остаётся соседу), пакеты — командой; вопрос."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    _, km = await kmod_status(user_id)
    text = _t(user_id, "km_remove_warn")
    if km.get("owner") == "kaskad":
        text += "\n\n" + _t(user_id, "km_remove_neighbour")
    await _kmod_ask(query, context, user_id, "km_remove_q", text, "km_btn_remove_do", "remove")


async def _kmod_progress_edit(query, user_id: Optional[int], title: str, text: str, t0: float) -> None:
    """Ход — правкой того же сообщения: что делается сейчас словами ядра и сколько идёт. Сбой правки (лимит Telegram,
    сеть) действие не трогает."""
    secs = int(max(0.0, time.monotonic() - t0))
    body = "⏳ <b>%s</b> · %d:%02d\n\n%s\n\n<i>%s</i>" % (esc(title), secs // 60, secs % 60,
                                                     esc(text or _t(user_id, "km_busy_wait")), _t(user_id, "km_busy_hint"))
    try:
        await safe_edit_message(query, body, reply_markup=None)
    except Exception as e:  # noqa: BLE001 — ход не роняет действие
        logger.warning("kmod progress edit: %s", type(e).__name__)


async def _kmod_follow(query, user_id: Optional[int], title: str, task: "asyncio.Task", t0: float) -> Dict[str, Any]:
    """Ждать шаг моста, раз в KMOD_PROGRESS_EVERY секунд показывая kmod-status.progress.text; ответ шага."""
    last = None
    while True:
        done, _ = await asyncio.wait({task}, timeout=KMOD_PROGRESS_EVERY)
        if task in done:
            return task.result()
        _, km = await kmod_status(user_id)
        prog = km.get("progress") if isinstance(km.get("progress"), dict) else {}
        text = str(prog.get("text") or "") or last or ""
        last = text
        await _kmod_progress_edit(query, user_id, title, text, t0)


async def kmod_run(query, user_id: Optional[int], op: str, meta: str = "off") -> List[Tuple[str, Dict[str, Any]]]:
    """Цепочка моста под замком бота — как пункт SSH-меню: [(действие, ответ), …]."""
    steps: List[Tuple[str, Dict[str, Any]]] = []
    title = _t(user_id, KMOD_BUSY_TITLES[op])
    t0 = time.monotonic()

    async def step(action: str, **params: Any) -> Dict[str, Any]:
        r = await _kmod_follow(query, user_id, title, spawn_task(run_bot_action(action, who=user_id, **params)), t0)
        steps.append((action, r))
        return r

    async with _BOT_ACTION_LOCK:
        try:
            await _kmod_progress_edit(query, user_id, title, "", t0)
            if op == "enable":
                r = await step("kmod-install", rebuild="off", headers_meta=meta)
                if bridge_ok(r):
                    await step("kmod-engine", engine="kernel")
            elif op == "program":
                await step("kmod-engine", engine="program")
            elif op == "rebuild":
                r = await step("kmod-install", rebuild="on", headers_meta="off")
                # Выбран модуль, а профили после перезагрузки в новое ядро ушли на программу — вернуть их на модуль.
                if bridge_ok(r) and r.get("want") == "kernel" and r.get("state") != "on":
                    await step("kmod-engine", engine="kernel")
            elif op == "remove":
                await step("kmod-remove")
        finally:
            invalidate_status()
    return steps


def kmod_apt_command(r: Dict[str, Any]) -> str:
    """Команда удаления пакетов сборки из ответа kmod-remove — только apt remove и имена пакетов."""
    cmd = r.get("command")
    if isinstance(cmd, str) and KMOD_APT_CMD_RE.match(cmd):
        return cmd
    pkgs = [p for p in (r.get("packages") if isinstance(r.get("packages"), list) else []) if isinstance(p, str) and KMOD_PKG_RE.match(p)]
    return "apt remove " + " ".join(pkgs) if pkgs else ""


def kmod_row_text(user_id: Optional[int], row: Dict[str, Any]) -> str:
    """Строка перевода профиля из ответа kmod-engine (profiles[]) — словами, как ga_kmod_row_text в SSH."""
    p = esc(profile_name(user_id, row.get("profile")))
    e = kmod_word(user_id, row.get("to"))
    note = str(row.get("note") or "")
    if note == "already":
        return _tf(user_id, "km_row_already_fmt", p, e)
    if note.startswith("not_running"):
        return _tf(user_id, "km_row_not_running_fmt", p, e)
    if note == "no_clients":
        return _tf(user_id, "km_row_no_clients_fmt", p, e)
    if note == "lost":
        return _tf(user_id, "km_row_lost_fmt", p, _as_int(row.get("alive_before")))
    rs = row.get("return_s")
    return _tf(user_id, "km_row_back_fmt", p, e, _as_int(row.get("returned")), _as_int(row.get("alive_before")),
               rs if isinstance(rs, int) and not isinstance(rs, bool) else "?")


def kmod_result_text(user_id: Optional[int], op: str, steps: List[Tuple[str, Dict[str, Any]]]) -> str:
    """Итог одним сообщением: удалось — что теперь работает (и команда удаления пакетов); перевод откатан — «отменён»,
    почему и строка по профилю; установка не удалась — слова ядра и «профили остались на программе»."""
    fail_title = _t(user_id, KMOD_FAIL_TITLES.get(op, "km_fail_enable"))
    if not steps:
        return "❌ <b>%s</b>" % fail_title
    action, last = steps[-1]
    if is_lock_busy(last):
        return fail_text(user_id, last)
    lines: List[str] = []
    if bridge_ok(last):
        if action == "kmod-remove":
            lines.append("✅ " + _t(user_id, "km_removed_kept" if last.get("kept_for_neighbour") is True else "km_removed"))
            cmd = kmod_apt_command(last)
            lines.append(_tf(user_id, "km_remove_packages_fmt", esc(cmd)) if cmd else _t(user_id, "km_remove_no_packages"))
        elif action == "kmod-engine":
            lines.append("✅ " + _tf(user_id, "km_engine_done_fmt", kmod_word(user_id, last.get("engine") or last.get("want"))))
        else:
            lines.append("✅ " + _tf(user_id, "km_installed_fmt", esc(last.get("version") or "?"), esc(last.get("kernel") or "?")))
    elif action == "kmod-engine" and last.get("rolled_back") is True:
        target = last.get("engine") if last.get("engine") in ("kernel", "program") else ("program" if op == "program" else "kernel")
        lines.append("⚠️ <b>%s</b>" % _tf(user_id, "km_rolled_back_fmt", kmod_word(user_id, target)))
        if last.get("message"):
            lines.append(esc(last.get("message")))
    else:
        lines.append("❌ <b>%s</b>" % fail_title)
        lines.append(error_text(user_id, last))
        if action == "kmod-install":
            lines.append(_t(user_id, "km_left_program"))
    details: List[str] = []
    for act, r in steps:
        if act == "kmod-install" and bridge_ok(r):
            sel = r.get("selftest") if isinstance(r.get("selftest"), dict) else {}
            for c in (sel.get("cases") if isinstance(sel.get("cases"), list) else [])[:16]:
                if not isinstance(c, dict) or str(c.get("profile")) not in PROFILE_IDS:
                    continue
                ok = c.get("ok") is True
                row = _tf(user_id, "km_selftest_row_fmt", esc(profile_name(user_id, c.get("profile"))), esc(c.get("line") or "?"),
                          _t(user_id, "km_client_kernel" if c.get("client") == "kernel" else "km_client_program"))
                details.append(("✓ " if ok else "✗ ") + row + ("" if ok or not c.get("detail") else " — " + esc(c.get("detail"))))
            skipped = r.get("headers_meta_skipped")
            if isinstance(skipped, str) and KMOD_PKG_RE.match(skipped):
                details.append("<i>%s</i>" % _tf(user_id, "km_meta_skipped_fmt", esc(skipped)))
        if act == "kmod-engine":
            for row in (r.get("profiles") if isinstance(r.get("profiles"), list) else [])[:8]:
                if isinstance(row, dict) and str(row.get("profile")) in PROFILE_IDS:
                    details.append("· " + kmod_row_text(user_id, row))
    if details:
        lines.append("")
        lines.extend(details)
    return "\n".join(lines)


@_once_callback
async def cb_km_go(update: Update, context: ContextTypes.DEFAULT_TYPE, attempt) -> None:
    """km_go~<действие>[~on|off]: согласие дано — цепочка моста с ходом правкой этого сообщения и итог на его месте. Одно
    нажатие — одно действие: второе, пока идёт первое, ничего не повторяет (_once_callback)."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    parts = str(query.data or "").split("~")
    op = parts[1] if len(parts) > 1 else ""
    meta = parts[2] if len(parts) > 2 else "off"
    if op not in KMOD_OPS or meta not in ("on", "off") or len(parts) > 3 or (len(parts) == 3 and op != "enable"):
        await show_bad_input(query, user_id, "mt_kmod")
        return
    if await _action_busy(query, user_id, "mt_kmod"):
        return
    attempt["started"] = True
    steps = await kmod_run(query, user_id, op, meta)
    first_busy = len(steps) == 1 and is_lock_busy(steps[0][1])
    if first_busy:
        # Замок держит SSH, панель или агент — действие не начиналось: «🔁 Повторить» (та же кнопка) честен.
        attempt["started"] = False
        markup = fail_markup(user_id, steps[0][1], "mt_kmod", retry_data(query))
    else:
        markup = InlineKeyboardMarkup([[btn(_t(user_id, "mt_kmod"), "mt_kmod")], _back_row(user_id, "sec_maint")])
    await safe_edit_message(query, kmod_result_text(user_id, op, steps), reply_markup=markup)


# ============================================================================
# РАЗДЕЛ 5: НАСТРОЙКИ
# ============================================================================

async def cb_sec_settings(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    rows = [
        [btn(_t(user_id, "se_mode_site"), "se_mode"), btn(_t(user_id, "se_dns"), "se_dns")],
        [btn(_t(user_id, "se_endpoint"), "se_endpoint"), btn(_t(user_id, "se_panel"), "se_panel")],
        [btn(_t(user_id, "se_agents"), "se_agents"), btn(_t(user_id, "se_admins"), "se_admins")],
        [btn(_t(user_id, "se_lang"), "menu_lang"), btn(_t(user_id, "se_about"), "se_about")],
        [btn(_t(user_id, "se_mirror"), "se_mirror")],
        [btn(_t(user_id, "se_wipe"), "se_wipe")],
        _back_row(user_id),
    ]
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "se_title"), _t(user_id, "sec_settings_hint")),
                            reply_markup=kb(rows))


async def cb_se_mode(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_mode: что сейчас за режим и всё, что с ним делают из бота."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    status = await get_status()
    mode = str(status.get("mode") or "") if bridge_ok(status) else ""
    lines = ["<b>%s</b>" % _t(user_id, "se_mode_site"), ""]
    fix_rows: list = []
    if bridge_ok(status):
        lines.append("%s <b>%s</b>" % (_t(user_id, "dash_mode"), esc(mode_label(user_id, status.get("mode")))))
        lines.append("%s <code>%s</code>" % (_t(user_id, "dash_domain"), esc(status.get("domain") or "—")))
        # Блок site есть только в режимах с сайтом (pro, lite_site); в lite он null
        lines.extend(site_summary_lines(user_id, status.get("site")))
        if mode in MODES_WITH_SITE:
            lines.append("%s %s" % (_t(user_id, "site_alt_svc"),
                                    _t(user_id, "state_on" if config_alt_svc() else "state_off")))
        on443 = pro_line_on443(status)
        if mode == "pro" and on443:
            # Какая линия сейчас на UDP 443 (F-3): поменять — «🎯 Линия на UDP 443» ниже
            lines.append(_tf(user_id, "pl_now_fmt", esc(profile_line_name(user_id, on443, status))))
        # Ярлык режима и порт VPN разошлись (мост считает это сам — mode_port_mismatch):
        # шапка SSH об этом говорит и объясняет, что перенести, — здесь то же, с кнопкой.
        hint, fix_rows = mode_port_fix(user_id, status, mode)
        if hint:
            lines.append("")
            lines.append("⚠️ " + hint)
    else:
        lines.append("⚠️ " + error_text(user_id, status))
    lines.append("")
    lines.append(_t(user_id, "se_mode_hint"))
    rows = list(fix_rows)
    if mode == "pro" and len(pro_line_choices(status)) > 1 and not any(
            getattr(b, "callback_data", "") == "se_pline" for r in rows for b in r):
        rows.append([btn(_t(user_id, "pl_btn"), "se_pline")])
    rows.append([btn(_t(user_id, "se_mode_change"), "se_mode_pick")])
    if mode in MODES_WITH_SITE:
        rows.append([btn(_t(user_id, "se_tpl"), "se_tpl"), btn(_t(user_id, "se_site_check"), "se_check")])
        rows.append([btn(_t(user_id, "se_alt_svc_btn"), "se_alt")])
    rows.append([btn(_t(user_id, "se_preflight"), "se_pf")])
    rows.append(_back_row(user_id, "sec_settings"))
    await safe_edit_message(query, "\n".join(lines), reply_markup=kb(rows))


# ── Смена режима работы (change-mode) ────────────────────────────────────────
# Действие не пересоздаёт контейнеры и не трогает ключи, но меняет то, как
# сервер выглядит снаружи: включает или гасит сайт на 443, выпускает или
# отзывает сертификат, а в Lite убирает панель с домена. Поэтому — экран с
# объяснением каждого режима и подтверждение фразой, как у удаления профиля.
MODE_DESC_KEYS = {m: "mode_desc_%s" % m for m in MODES}


def mode_port_fix(user_id: Optional[int], status: Dict[str, Any], mode: str) -> Tuple[str, list]:
    """Что сказать и какую кнопку дать, когда ярлык режима и порт VPN разошлись.

    «Pro» — ровно один профиль на UDP/443, «Semi-Pro» — ни одного
    (docs/MAP.md §3). change-mode порт профиля НЕ двигает никогда: перенос
    пересоздаёт контейнер и меняет порт во всех выданных ключах, это отдельное
    решение человека. Пусто — расхождения нет: предлагать сделанное значит учить
    не верить подсказкам.
    """
    if not bridge_ok(status) or mode not in MODES_WITH_SITE:
        return "", []
    profiles = [p for p in status_profiles(status) if str(p.get("state") or "missing") != "missing"]
    if not profiles:
        return "", []
    on443 = [str(p.get("profile")) for p in profiles if str(p.get("port") or "") == "443"]
    if mode == "pro":
        if on443:
            return "", []
        if len(profiles) == 1:
            return _t(user_id, "se_mode_port_hint"), [[btn(_t(user_id, "pr_take443"), "pr_443~%s" % profiles[0].get("profile"))]]
        # Профилей несколько — какой из них занять 443, решает человек: порт один. Выбор линии (F-3, pro-line).
        return _t(user_id, "se_mode_port_hint"), [[btn(_t(user_id, "pl_btn"), "se_pline")]]
    if not on443 or not valid_profile(on443[0]):
        return "", []
    return (_tf(user_id, "se_mode_port_hint_site_fmt", esc(profile_line_name(user_id, on443[0], status))),
            [[btn(_t(user_id, "pr_set_port"), "pr_port~%s" % on443[0])]])


async def mode_port_rows(user_id: Optional[int], mode: str = "pro") -> Tuple[str, list]:
    """mode_port_fix по свежему status — после удачной смены режима."""
    return mode_port_fix(user_id, await get_status(fresh=True), mode)


def _mode_ports_line(user_id: Optional[int], ports: str, info: Optional[Dict[str, Any]], default_ok: bool) -> str:
    """«Порты: … · ✅ доступен» или «· ⛔ причина словами ядра»; проверка не ответила — только порты."""
    if info is None:
        return "<i>%s</i>" % _tf(user_id, "se_mode_ports_fmt", ports)
    if bool(info.get("available", default_ok)):
        return "<i>%s · ✅ %s</i>" % (_tf(user_id, "se_mode_ports_fmt", ports), _t(user_id, "pf_available"))
    why = next((str(x.get("message")) for x in (info.get("reasons") or []) if isinstance(x, dict) and x.get("message")),
               _t(user_id, "pf_unavailable"))
    return "%s · ⛔ %s" % (_tf(user_id, "se_mode_ports_fmt", ports), esc(why))


async def cb_se_mode_pick(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_mode_pick: Ленивый Pro и три режима человеческим языком и что выбрать, если не уверен."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    status = await get_status()
    current = str(status.get("mode") or "") if bridge_ok(status) else ""
    # У каждого режима — порты и доступен ли он сейчас (L-23, сцены mode-pick и mode-pick-busy дизайна
    # 0.5.0): та же проверка, что «🚪 Проверка портов 80/443». Не ответила — экран без строк доступности.
    pf = await run_bot_action("preflight", timeout=120)
    pf_modes = pf.get("modes") if bridge_ok(pf) and isinstance(pf.get("modes"), dict) else {}
    warnings = [w for w in (pf_modes.get("warnings") or []) if isinstance(w, dict) and w.get("message")]
    lines = ["<b>%s</b>" % _t(user_id, "se_mode_change"), ""]
    # Ленивый Pro — сценарий над режимами (F-1, договор 0.6.0), первым, как в мастере. Ему нужны TCP 80/443 —
    # то же, что preflight проверяет у Semi-Pro; занятый UDP 443 его не останавливает (итог — Semi-Pro).
    lines.append("<b>%s</b>: %s" % (esc(lazy_label(user_id)), _tf(user_id, "lazy_desc_fmt", LAZY_KEYS)))
    lazy_info = pf_modes.get("lite_site") if isinstance(pf_modes.get("lite_site"), dict) else None
    lines.append(_mode_ports_line(user_id, _t(user_id, "mode_ports_pro"), lazy_info, False))
    lines.append("")
    for m in MODES:
        mark = " ✓" if m == current else ""
        # «Semi-Pro — VPN и сайт ✓: что это» — название с подписью (F-2), после двоеточия — описание
        lines.append("<b>%s%s</b>: %s" % (esc(mode_label(user_id, m)), mark, _t(user_id, MODE_DESC_KEYS[m])))
        info = pf_modes.get(m) if isinstance(pf_modes.get(m), dict) else None
        lines.append(_mode_ports_line(user_id, _t(user_id, "mode_ports_%s" % m), info, m == "lite"))
        if m == "pro":
            # Занятый UDP/443 режим не запрещает (ядро: предупреждение), но VPN на 443 туда не встанет
            for w in warnings:
                if str(w.get("proto") or "") == "udp" and str(w.get("port") or "") == "443":
                    lines.append("⚠️ " + esc(w.get("message")))
        lines.append("")
    lines.append(_t(user_id, "se_mode_unsure"))
    rows = [[btn(_t(user_id, "lazy_btn"), "se_lazy")]]
    rows += [[btn(_tf(user_id, "se_mode_to_fmt", mode_short(user_id, m)), "se_mode_to~%s" % m)]
             for m in MODES if m != current]
    rows.append(_back_row(user_id, "se_mode"))
    await safe_edit_message(query, "\n".join(lines), reply_markup=InlineKeyboardMarkup(rows))


async def cb_se_mode_to(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_mode_to~<режим>: для Pro сначала линия на UDP 443 (F-3), затем, когда сайту нужен домен, — вопрос
    о домене, иначе сразу фраза.

    Как в SSH (_site_transition): домен спрашивается, когда сайт ПОДНИМАЕТСЯ из «Lite».
    Между двумя режимами с сайтом сайт, домен и сертификат остаются — мост меняет
    лишь запись режима (website_switch_site_mode), и только если --domain НЕ передан: с
    доменом он шёл в полную пересборку сайта с certbot и мог сорваться там, где SSH
    проходит. Исключение — режим с сайтом, но без домена (запасной самоподписанный): у бота
    нет пункта «Домен», и вопрос здесь — единственный способ подключить домен из чата;
    «без домена» тогда и есть простая смена записи.
    """
    query = update.callback_query
    user_id = _uid(update)
    mode = str(query.data).split("~", 1)[1] if "~" in str(query.data) else ""
    if not valid_mode(mode):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    status = await get_status()
    line = ""
    if mode == "pro":
        # Какая линия встанет на UDP 443, выбирает человек (сцена mode-pro-line): линий несколько — экран выбора,
        # одна — она и есть (подтверждение назовёт её и смену порта), ни одной — переносить нечего.
        choices = pro_line_choices(status)
        if len(choices) > 1:
            text, markup = pro_line_picker(user_id, status, "se_mode_pl~", "se_mode_pick", switching=True)
            await safe_edit_message(query, text, reply_markup=markup)
            return
        line = choices[0] if choices else ""
    await _mode_to_step(query, context, user_id, mode, status, line)


async def cb_se_mode_pl(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_mode_pl~<профиль>: линия на UDP 443 для перехода в Pro выбрана — дальше домен или сразу фраза."""
    query = update.callback_query
    user_id = _uid(update)
    line = _profile_from_data(str(query.data), "se_mode_pl~")
    if not line:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    await _mode_to_step(query, context, user_id, "pro", await get_status(), line)


async def _mode_to_step(query, context, user_id: Optional[int], mode: str, status: Dict[str, Any], line: str) -> None:
    """Переход в режим после выбора линии: вопрос о домене (сайт поднимается или без домена) или фраза."""
    ok = bridge_ok(status)
    current = str(status.get("mode") or "") if ok else ""
    domain = str(status.get("domain") or "").strip() if ok else ""
    site = status.get("site") if ok and isinstance(status.get("site"), dict) else {}
    # Сайт на запасном самоподписанном при сохранённом домене (DNS не был готов) — тоже
    # спрашиваем: «Оставить домен» передаёт его мосту, и тот выпускает настоящий
    # сертификат, когда A-запись дошла. Иначе из бота выйти с запасного было нечем.
    fallback = str(site.get("cert") or "") == "selfsigned"
    # Линия едет дальше в callback_data («se_mode_keep~pro~awg3») и в ожидании домена
    tail = "~%s" % line if valid_profile(line) else ""
    if mode in MODES_WITH_SITE and not (current in MODES_WITH_SITE and domain and not fallback):
        # Раньше домен спрашивался только для «Pro» и только без домена в конфиге:
        # «Semi-Pro» вставал на самоподписанном, а домен, оставшийся в конфиге с прошлого раза,
        # уходил молча — поменять его из бота было нечем. Прежний — кнопкой (как Enter в SSH).
        flow_set(context, "mode_domain", mode=mode, current=current, line=line)
        rows = []
        if domain and valid_host(domain) and not IPV4_RE.match(domain):
            rows.append([btn(_tf(user_id, "se_mode_keep_domain_fmt", domain), "se_mode_keep~%s%s" % (mode, tail))])
        else:
            # «Без домена» — только когда домена в конфиге нет: вызов без --domain мост читает
            # как «взять из конфига», и кнопка с сохранённым доменом поднимала сайт на нём же,
            # с certbot (находка SR-55). В SSH так же: при сохранённом домене Enter — он и есть.
            rows.append([btn(_t(user_id, "se_mode_no_domain_btn"), "se_mode_nodom~%s%s" % (mode, tail))])
        rows.append([btn(_t(user_id, "btn_cancel"), "se_mode_pick")])
        await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_tf(user_id, "se_mode_to_fmt", esc(mode_label(user_id, mode))),
                                                            _t(user_id, "se_mode_ask_domain")),
                                reply_markup=InlineKeyboardMarkup(rows))
    else:
        # В «Lite» домен не нужен; между режимами с сайтом при домене — только запись режима.
        await _arm_mode_confirm(query, context, user_id, mode, "", current=current, line=line)


async def _mode_current() -> str:
    status = await get_status()
    return str(status.get("mode") or "") if bridge_ok(status) else ""


def _mode_and_line(data: str, prefix: str) -> Tuple[str, str, bool]:
    """«<prefix><режим>[~<профиль>]» → (режим, линия на UDP 443, разобралось ли). Линия бывает только у Pro."""
    parts = str(data)[len(prefix):].split("~") if str(data).startswith(prefix) else [""]
    mode, line = parts[0], (parts[1] if len(parts) > 1 else "")
    ok = mode in MODES_WITH_SITE and len(parts) <= 2 and (not line or (mode == "pro" and valid_profile(line)))
    return mode, line, ok


async def cb_se_mode_keep(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_mode_keep~<режим>[~<линия>]: поднять сайт на домене, который уже записан в конфиге."""
    query = update.callback_query
    user_id = _uid(update)
    mode, line, ok = _mode_and_line(query.data, "se_mode_keep~")
    if not ok:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    status = await get_status()
    domain = str(status.get("domain") or "").strip() if bridge_ok(status) else ""
    if not domain or not valid_host(domain) or IPV4_RE.match(domain):
        # Домен успели снять, пока экран висел: спрашиваем заново, а не шлём пустоту.
        await dispatch_callback_data(update, context, "se_mode_to~%s" % mode)
        return
    await _arm_mode_confirm(query, context, user_id, mode, domain, current=str(status.get("mode") or ""), line=line)


async def cb_se_mode_nodom(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_mode_nodom~<режим>[~<линия>]: без домена — из «Lite» сайт встанет на запасном
    самоподписанном по IP; между режимами с сайтом — просто смена записи режима."""
    query = update.callback_query
    user_id = _uid(update)
    mode, line, ok = _mode_and_line(query.data, "se_mode_nodom~")
    if not ok:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    await _arm_mode_confirm(query, context, user_id, mode, "", current=await _mode_current(), line=line)


def mode_change_warn(user_id: Optional[int], mode: str, current: str, domain: str, line: str = "",
                     status: Optional[Dict[str, Any]] = None) -> str:
    """Что произойдёт — по переходу, а не одной фразой на все три случая.

    Прежний текст «Сайт и сертификат пересобираются, панель на домене может
    закрыться» не подходил ни к одному: при переходе между режимами с сайтом не
    трогается ничего, при уходе в «Lite» панель закрывается точно, а при
    подъёме сайта она включается сама. В Pro с выбранной линией (F-3) порт VPN как раз
    переносится — вместо «порт не переносится» подтверждение называет, какая линия и откуда.
    """
    name, desc = esc(mode_label(user_id, mode)), _t(user_id, MODE_DESC_KEYS[mode])
    # Домен в НОВЫХ ключах — только в «Pro»: переход в него или из него меняет адрес
    # в новых ключах. «Ключи не меняются» верно лишь для уже выданных — говорим и это (SR-43).
    host_note = ("\n\n" + _t(user_id, "se_mode_warn_keys_host")) if current and (current == "pro") != (mode == "pro") else ""
    if mode not in MODES_WITH_SITE:
        return _tf(user_id, "se_mode_warn_off_fmt", name, desc) + host_note
    line_note = pro_line_switch_note(user_id, line, status or {}) if mode == "pro" and valid_profile(line) else ""
    switch_only = current in MODES_WITH_SITE and not domain
    if line_note:
        warn = _tf(user_id, "se_mode_warn_pro_switch_fmt" if switch_only else "se_mode_warn_pro_fmt", name, desc)
    else:
        warn = _tf(user_id, "se_mode_warn_switch_fmt" if switch_only else "se_mode_warn_fmt", name, desc)
    if domain and not switch_only:
        warn += "\n\n" + _tf(user_id, "se_mode_domain_fmt", esc(domain))
    if line_note:
        warn += "\n\n" + line_note
    return warn + host_note


async def _arm_mode_confirm(query_or_message, context, user_id: Optional[int], mode: str, domain: str,
                            edit: bool = True, current: str = "lite", line: str = "") -> None:
    """Экран фразы MODE <режим>; домен и линию на UDP 443 кладём в extra — они нужны уже при выполнении.

    Домен передают только там, где сайт поднимается или получает домен (см.
    cb_se_mode_to): непустой --domain уводит мост в полную пересборку сайта.
    """
    if mode not in MODES_WITH_SITE:
        domain = ""
    if mode != "pro" or not valid_profile(line):
        line = ""
    status = await get_status() if line else {}
    warn = mode_change_warn(user_id, mode, current, domain, line, status)
    extra = {"domain": domain, "current": current, "line": line}
    if not edit:
        # Домен пришёл текстом: у сообщения нет callback, рисуем ответом.
        phrase = confirm_phrase("change-mode", mode)
        CONFIRM.arm(int(user_id), "change-mode", mode, phrase, extra)
        flow_clear(context)
        markup = InlineKeyboardMarkup([[btn(_t(user_id, "btn_cancel"), "tc_cancel~se_mode")]])
        sent = await query_or_message.reply_text(
            "<b>%s</b>\n\n%s\n\n%s" % (_t(user_id, "confirm_title"), warn,
                                       confirm_type_text(user_id, phrase)),
            parse_mode="HTML", reply_markup=markup)
        note_confirm_message(user_id, sent, markup)
        return
    await arm_typed_confirm(query_or_message, context, user_id, "change-mode", mode,
                            back_to="se_mode", warn=warn, extra=extra)


# ── Линия на UDP 443 в Pro (F-3): pro-line ────────────────────────────────────
# Договор 0.6.0: pro-line --profile=<id> ставит выбранную линию на UDP 443, прежнюю — на свободный случайный
# порт; профиль, подхваченный у приложения Amnezia (у его людей ключей на сервере нет), — только с явным
# --adopted-confirm=<профиль> (ACC-2). Разрушительное: контейнеры пересоздаются, порт в выданных ключах
# меняется — фраза LINE <профиль>, а для подхваченного — ещё и MOVE <профиль>. Выбор при переходе в Pro
# едет в extra фразы MODE pro и применяется сразу после change-mode.

def pro_line_on443(status: Dict[str, Any]) -> str:
    """Профиль, который сейчас держит UDP 443, или пусто."""
    for p in status_profiles(status) if bridge_ok(status) else []:
        if str(p.get("port") or "") == "443" and str(p.get("state") or "missing") != "missing":
            return str(p.get("profile"))
    return ""


def pro_line_choices(status: Dict[str, Any]) -> List[str]:
    """Линии, которые можно поставить на UDP 443: установленные профили, 2.0 — первой (решение владельца 27.09:
    её понимает больше всего клиентов, включая роутеры Keenetic)."""
    if not bridge_ok(status):
        return []
    ids = [str(p.get("profile")) for p in status_profiles(status)
           if str(p.get("state") or "missing") != "missing" and valid_profile(str(p.get("profile")))]
    first = [p for p in ids if profile_line(p, status) == "2.0"]
    return first + [p for p in ids if p not in first]


def pro_line_picker(user_id: Optional[int], status: Dict[str, Any], prefix: str, back_to: str,
                    switching: bool) -> Tuple[str, "InlineKeyboardMarkup"]:
    """Экран «какая линия на UDP 443» (сцена mode-pro-line): при переходе в Pro (switching) — все линии, у той,
    что уже на 443, так и сказано; в Pro — все, кроме стоящей на 443 (выбирать её незачем)."""
    on443 = pro_line_on443(status)
    lines = ["<b>%s</b>" % _t(user_id, "pl_title" if switching else "pl_btn"), "", _t(user_id, "pl_ask")]
    if on443:
        lines.append(_tf(user_id, "pl_now_fmt", esc(profile_line_name(user_id, on443, status))))
    # «Рекомендуем 2.0» — только когда 2.0 есть (R4, DUP-LINE-01): иначе честно сказать, что её нет, и дать выход —
    # «Переставить … на 2.0» (свой профиль повторяет чужую линию) или «Установить AmneziaWG 2.0» на свободное место.
    choices = pro_line_choices(status)
    fix_rows: list = []
    if any(profile_line(p, status) == "2.0" for p in choices):
        lines += ["", _tf(user_id, "pl_why_20_fmt", _t(user_id, "pl_btn"))]
    else:
        lines += ["", "⚠️ " + _t(user_id, "pl_no20")]
        rl = lines_check_of(status)["reline"]
        free20 = [p for p, l in status_free_lines(status).items() if l == "2.0"]
        if rl and rl["line"] == "2.0":
            lines.append(_tf(user_id, "lines_reline_fmt", esc(profile_name(user_id, rl["profile"], status)), rl["line"]))
            fix_rows.append(reline_row(user_id, rl, status))
        elif free20:
            fix_rows.append([btn(_tf(user_id, "pr_install_line_fmt", "2.0"), "pr_install~%s" % free20[0])])
    lines += ["", _t(user_id, "pr_port_note")]
    rows = []
    for p in choices:
        short = profile_short(p, status, user_id)
        if p == on443:
            if not switching:
                continue
            # «— уже на UDP 443»: порт назван рядом — без повтора (DUP-LINE-01)
            label = _tf(user_id, "pl_btn_now_fmt", profile_line(p, status))
        else:
            label = _tf(user_id, "pl_btn_rec_fmt" if profile_line(p, status) == "2.0" else "pl_btn_fmt", short)
        rows.append([btn(label, "%s%s" % (prefix, p))])
    rows.extend(fix_rows)
    rows.append(_back_row(user_id, back_to))
    return "\n".join(lines), InlineKeyboardMarkup(rows)


def pro_line_switch_note(user_id: Optional[int], line: str, status: Dict[str, Any]) -> str:
    """Строка подтверждения MODE pro о выбранной линии: уже на 443 — порты прежние; нет — откуда переедет, кто
    освободит 443 и что порт записан в каждом выданном ключе."""
    # Порт назван в самой строке («с UDP 39001 на 443», «уже там») — подпись без порта (DUP-LINE-01)
    name = esc(profile_line_name(user_id, line, status))
    port = str(profile_info(status, line).get("port") or "") if bridge_ok(status) else ""
    if port == "443":
        return _tf(user_id, "pl_switch_same_fmt", name)
    parts = [_tf(user_id, "pl_switch_move_fmt", name, esc(port or "?"))]
    holder = pro_line_on443(status)
    if holder and holder != line:
        parts.append(_tf(user_id, "pl_prev_fmt", esc(profile_line_name(user_id, holder, status))))
    parts.append(_t(user_id, "pr_port_note"))
    return " ".join(parts)


async def cb_se_pline(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_pline: в Pro — какую линию поставить на UDP 443 (pro-line); вне Pro — куда идти за этим."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    status = await get_status()
    if not bridge_ok(status):
        await show_error(query, user_id, status, "se_mode")
        return
    title = "<b>%s</b>\n\n" % _t(user_id, "pl_btn")
    if str(status.get("mode") or "") != "pro":
        await safe_edit_message(query, title + _tf(user_id, "pl_not_pro_fmt", _t(user_id, "se_mode_change"),
                                                   _tf(user_id, "se_mode_to_fmt", mode_short(user_id, "pro"))),
                                reply_markup=InlineKeyboardMarkup([[btn(_t(user_id, "se_mode_change"), "se_mode_pick")],
                                                                   _back_row(user_id, "se_mode")]))
        return
    if not [p for p in pro_line_choices(status) if p != pro_line_on443(status)]:
        await safe_edit_message(query, title + _tf(user_id, "pl_none_fmt", _t(user_id, "menu_protocols")),
                                reply_markup=InlineKeyboardMarkup([[btn(_t(user_id, "menu_protocols"), "sec_protocols")],
                                                                   _back_row(user_id, "se_mode")]))
        return
    text, markup = pro_line_picker(user_id, status, "se_pline~", "se_mode", switching=False)
    await safe_edit_message(query, text, reply_markup=markup)


async def cb_se_pline_pick(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_pline~<профиль>: линия выбрана — фраза LINE <профиль>, как у прочих разрушительных действий."""
    query = update.callback_query
    user_id = _uid(update)
    profile = _profile_from_data(str(query.data), "se_pline~")
    if not profile:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    status = await get_status(fresh=True)
    if not bridge_ok(status) or str(status.get("mode") or "") != "pro" or profile not in pro_line_choices(status):
        # Экран устарел: режим сменили или профиль пропал — показываем, как есть сейчас
        await dispatch_callback_data(update, context, "se_pline")
        return
    name = esc(profile_line_name(user_id, profile, status))     # порт — в самой строке
    port = str(profile_info(status, profile).get("port") or "")
    if port == "443":
        await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "pl_btn"), _tf(user_id, "pl_now_fmt", name)),
                                reply_markup=back_kb(user_id, "se_mode"))
        return
    parts = [_tf(user_id, "pl_move_fmt", name, esc(port or "?"))]
    holder = pro_line_on443(status)
    if holder:
        parts.append(_tf(user_id, "pl_prev_fmt", esc(profile_line_name(user_id, holder, status))))
    parts.append(_t(user_id, "pr_port_note"))
    await arm_typed_confirm(query, context, user_id, "pro-line", profile, back_to="se_mode", warn="\n\n".join(parts))


def pro_line_done_text(user_id: Optional[int], profile: str, r: Dict[str, Any], status: Dict[str, Any]) -> str:
    """Итог pro-line: какая линия теперь на UDP 443 и порты всех линий — из ответа (договор, уточнения 28.09:
    {mode, udp443:{profile, line}, profiles:[{id, line, port}]}), без них — по свежему status; и что порт — в ключах."""
    udp = r.get("udp443") if isinstance(r.get("udp443"), dict) else {}
    if udp.get("line"):
        on443 = _tf(user_id, "pr_line_name_fmt", udp.get("line"))
    else:
        on443 = profile_name(user_id, udp.get("profile") if valid_profile(str(udp.get("profile") or "")) else profile, status)
    lines = ["✅ " + _tf(user_id, "pl_done_fmt", esc(on443))]
    items = [(p.get("id") or p.get("profile"), p.get("line"), p.get("port"))
             for p in (r.get("profiles") or []) if isinstance(p, dict)]
    if not items and bridge_ok(status):
        items = [(p.get("profile"), p.get("line"), p.get("port")) for p in status_profiles(status)]
    parts = ["%s · UDP %s" % (esc(_tf(user_id, "pr_line_name_fmt", line) if line else profile_line_name(user_id, pid, status)),
                              esc(port or "?")) for pid, line, port in items]
    if parts:
        lines.append("%s %s" % (_t(user_id, "dash_profiles"), ", ".join(parts)))
    return "\n".join(lines) + "\n\n" + _t(user_id, "pr_port_note")


async def _pro_line_step(message, user_id: Optional[int], profile: str, adopted: str = "") -> Tuple[bool, str, list]:
    """pro-line для выбранной линии → (встала ли, текст итога, кнопки над «Назад»).

    Отказ adopted_keyless (у подхваченного профиля люди без ключа на сервере) взводит фразу MOVE <профиль>:
    такой перенос — только словом (ACC-2). Какой профиль подтверждать, ядро называет полем profile; нет поля —
    выбранный. Ядро без действия — «после обновления» и путь через «Протоколы»."""
    await message.reply_text("⏳ " + _tf(user_id, "pl_moving_fmt", esc(profile_name(user_id, profile))))
    r = await mutate("pro-line", who=user_id, profile=profile, adopted_confirm=adopted or None)
    if bridge_ok(r):
        # Порты — из ответа; старое ядро без них — по свежему status (кэш mutate уже сбросил)
        status = {} if r.get("profiles") else await get_status(fresh=True)
        return True, pro_line_done_text(user_id, profile, r, status), []
    code = str(r.get("code") or "")
    if code == "adopted_keyless" and not adopted:
        who = str(r.get("profile") or "")
        who = who if valid_profile(who) else profile
        phrase = await typed_phrase("pro-line-adopted", who)
        CONFIRM.arm(int(user_id), "pro-line-adopted", who, phrase, {"line": profile})
        parts = ["⚠️ " + esc(r.get("message"))] if r.get("message") else []
        parts += [_t(user_id, "pl_adopted_note"), confirm_type_text(user_id, phrase)]
        return False, "\n\n".join(parts), []
    if code == "unknown_action":
        return False, _tf(user_id, "pl_unsupported_fmt", _t(user_id, "menu_protocols"), _t(user_id, "pr_take443")), \
            [[btn(_t(user_id, "menu_protocols"), "sec_protocols")]]
    return False, fail_text(user_id, r), [[btn(_t(user_id, "pl_btn"), "se_pline")]]


# ── Ленивый Pro (F-1): домен → lazy-check → фраза → lazy-setup → итог ────────
# Сценарий, а не режим (docs/MODES_047.md «Договор 0.6.0»): его итог — pro, а при занятом UDP 443 — lite_site;
# внутренние id режимов прежние. Мост проверяет всё сам (lazy-check, без изменений), бот показывает план и
# причины и ставит только после фразы LAZY <домен>, как прочие разрушительные действия. lazy-setup — долгое
# действие: «занято» и очередь те же, что у прочих долгих (_action_busy, _queued_notice, lock_timeout).
LAZY_KEYS = 5                     # ключей со страницами (договор: --keys=1..20, по умолчанию 5)
LAZY_CHECK_TIMEOUT = 120          # DNS и три порта — как у preflight
LAZY_PLAN_TTL = FLOW_TTL          # проверенный план живёт, как ожидание ввода; дольше — проверяем снова
LAZY_PLANS_OK = ("pro", "semi_pro")
# Коды reasons (lazy-check) и warnings (lazy-setup) — договор 0.6.0 в docs/MODES_047.md: «Уточнения» (28.09) и «По
# итогам ядра» (28.09). У каждого свой текст (lazy_code_<код>); незнакомый код показываем как есть — потерять его хуже.
# Код, который экран уже назвал строкой из самих данных (DNS, порты, UDP 443 в итоге), вторым разом не повторяем.
LAZY_CODES = (
    # reasons lazy-check (они же — обойдённые сценарием warnings lazy-setup)
    "dns_none", "dns_elsewhere", "dns_partial", "dns_unknown", "aaaa_foreign", "cloudflare_proxied", "tcp80_busy",
    "tcp443_busy", "tcp443_app", "udp443_busy", "no_line_for_443", "awg2_container_busy",
    # warnings lazy-setup: частые и редкие
    "template_fallback", "cert_fallback", "adopted", "keys_partial", "panel_off",
    "adopt_failed", "firewall_open_failed", "line_skipped", "profile_failed", "site_failed", "timers_failed",
    # контейнеры приложения подхвачены на одной подсети (SUBNET-01) — выход в карточке профиля
    "subnet_overlap")
LINE_RE = re.compile(r"^[0-9]{1,2}\.[0-9]{1,2}$")
# Домен для сертификата — тип domain из lib/actions.json: строчные, точка внутри, до 253 знаков.
DOMAIN_RE = re.compile(r"^([a-z0-9](-*[a-z0-9])*)(\.([a-z0-9](-*[a-z0-9])*))+$")
PAGE_URL_RE = re.compile(r"^https://[^\s<>\"']{4,512}$")


def lazy_label(user_id: Optional[int]) -> str:
    """«Ленивый Pro — только домен, остальное сделаю сам» — строка таблицы договора 0.6.0."""
    return "%s — %s" % (_t(user_id, "mode_name_lazy"), _t(user_id, "mode_sub_lazy"))


def valid_domain(v: str) -> bool:
    return bool(v) and len(v) <= 253 and bool(DOMAIN_RE.match(v)) and not IPV4_RE.match(v)


def lazy_domain_input(text: str) -> Tuple[str, str, str]:
    """Домен из сообщения → (домен для моста, как его показать, "") или ("", "", ключ словаря с ошибкой).

    Без тупиков (MODES_047, Ленивый Pro п. 1): https://, путь, порт и точку в конце отрезаем, регистр
    приводим, кириллицу переводим в punycode (показываем как прислали). IP-адрес — не домен: ленивого
    режима без домена нет."""
    s = (text or "").strip()
    s = re.sub(r"^[A-Za-z][A-Za-z0-9+.-]*://", "", s)
    s = re.split(r"[/?#\s]", s, maxsplit=1)[0]
    if s.count(":") == 1:
        s = s.split(":", 1)[0]
    s = display = s.rstrip(".").lower()
    if any(ord(c) > 127 for c in s):
        try:
            s = s.encode("idna").decode("ascii")
        except UnicodeError:
            return "", "", "lazy_bad_idn"
    if not valid_domain(s):
        return "", "", "lazy_bad_domain"
    return s, display, ""


def _lazy_list(value: Any) -> List[str]:
    return [str(x) for x in value if isinstance(x, (str, int)) and not isinstance(x, bool)] if isinstance(value, list) else []


def _lazy_by(value: Any) -> str:
    """Кто держит порт (ports.*.by): строка — как есть; объект — его message или имя процесса, контейнера."""
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, dict):
        for k in ("message", "container", "process", "unit", "product"):
            v = value.get(k)
            if isinstance(v, str) and v.strip():
                return v.strip()
    return ""


def lazy_domain_line(user_id: Optional[int], domain: Any, display: Any = "") -> str:
    """«Домен: vpn.example.com»; кириллический — как его пишут люди и в скобках punycode, как его видит мост."""
    domain = str(domain or "")
    display = str(display or "").strip() or domain
    if display != domain:
        return "%s %s (<code>%s</code>)" % (_t(user_id, "dash_domain"), esc(display), esc(domain))
    return "%s <code>%s</code>" % (_t(user_id, "dash_domain"), esc(domain))


def lazy_plan_of(r: Dict[str, Any]) -> str:
    """План из ответа: pro | semi_pro | blocked. Незнакомый — «не ставим»: бот не угадывает, что имело в виду ядро."""
    plan = str(r.get("plan") or "")
    return plan if plan in LAZY_PLANS_OK else "blocked"


def lazy_line443(r: Dict[str, Any]) -> str:
    """Какая линия встанет на UDP 443 — поле udp443_line ответа lazy-check («2.0», «3.1»); нет его — пусто."""
    line = str(r.get("udp443_line") or "").strip()
    return line if LINE_RE.match(line) else ""


def lazy_line443_note(user_id: Optional[int], line: str) -> str:
    """Строка о линии на UDP 443: 2.0 — почему она (решение владельца 27.09), другая — что порты с людьми не двигаем.
    Линия неизвестна (ядро не сказало) — ничего: угадывать, что встанет на 443, бот не берётся."""
    if not line:
        return ""
    return _t(user_id, "lazy_why_20") if line == "2.0" else _tf(user_id, "lazy_line443_fmt", esc(line))


def lazy_keys_count(r: Dict[str, Any], key: str, default: int) -> int:
    """Число ключей из ответа lazy-check (keys_new — сколько будет заведено, keys_have — сколько прежних засчитается,
    LZ-05); ядро без этих полей — default."""
    v = r.get(key) if isinstance(r, dict) else None
    return v if isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= 100 else default


def lazy_plan_head(user_id: Optional[int], plan: str, reasons: List[str], keys_new: int = LAZY_KEYS) -> str:
    """Заголовок плана: «⛔ не встанет», «План: Semi-Pro — …» (почему — UDP 443 занят или линии на своих портах)
    или «План: Pro — …». keys_new — сколько ключей сценарий заведёт на самом деле: прежние засчитываются (LZ-05)."""
    if plan == "blocked":
        return _t(user_id, "lazy_plan_blocked")
    if plan == "semi_pro":
        key = "lazy_plan_semi_fmt" if "udp443_busy" in reasons else "lazy_plan_semi_other_fmt"
        return _tf(user_id, key, esc(mode_label(user_id, "lite_site")), keys_new)
    return _tf(user_id, "lazy_plan_pro_fmt", esc(mode_label(user_id, "pro")), keys_new)


def lazy_code_lines(user_id: Optional[int], codes: List[str], said: Any = (),
                    unknown_key: str = "lazy_reason_unknown_fmt") -> List[str]:
    """Коды reasons или warnings словами, без повторов и без уже сказанных; незнакомый — как есть."""
    out = []
    for code in dict.fromkeys(codes):
        if code in said:
            continue
        out.append(_t(user_id, "lazy_code_%s" % code) if code in LAZY_CODES else _tf(user_id, unknown_key, esc(code)))
    return out


def lazy_plan_lines(user_id: Optional[int], plan: str, reasons: List[str], said: Any = (), line: str = "",
                    keys_new: int = LAZY_KEYS, keys_have: int = 0) -> List[str]:
    """План и причины — одинаково на экране проверки (шаг 2) и при отказе lazy-setup: заголовок плана, причины
    словами (кроме уже названных фактами), затем для «не встанет» — что делать, для Pro — какая линия на UDP 443."""
    lines = [lazy_plan_head(user_id, plan, reasons, keys_new)]
    if keys_have and plan != "blocked":
        lines.append(_tf(user_id, "lazy_keys_have_fmt", keys_have))
    lines.extend(lazy_code_lines(user_id, reasons, said))
    if plan == "blocked":
        lines.extend(["", _tf(user_id, "lazy_blocked_hint_fmt", _t(user_id, "btn_refresh"))])
    elif plan == "pro" and lazy_line443_note(user_id, line):
        lines.extend(["", lazy_line443_note(user_id, line)])
    return lines


def lazy_check_facts(user_id: Optional[int], r: Dict[str, Any], blocked: bool) -> Tuple[List[str], set]:
    """Факты проверки из самих данных — DNS, AAAA, три порта, контейнеры приложения — и коды причин, которые эти
    строки уже назвали (второй раз словами их не повторяем). by — формулировка предполётной проверки целиком."""
    said: set = set()
    reasons = set(_lazy_list(r.get("reasons")))
    domain = str(r.get("domain") or "")
    display = str(r.get("domain_display") or "").strip() or domain
    refresh = _t(user_id, "btn_refresh")
    lines = [lazy_domain_line(user_id, domain, display)]
    server_ips = _lazy_list(r.get("server_ips"))
    a = _lazy_list(r.get("a"))
    own = esc(", ".join(server_ips) or "?")
    # A-записи: свои отмечаем ✓, как «Проверить сайт»
    marked = esc(", ".join(ip + (" ✓" if ip in server_ips else "") for ip in a))
    if r.get("points_here") is True:
        foreign = [ip for ip in a if ip not in server_ips]
        lines.append(_tf(user_id, "lazy_dns_ok_fmt", marked if foreign else esc(", ".join(a) or display)))
        if foreign:                         # ядро постарше: points_here при части чужих записей
            lines.append(_t(user_id, "lazy_code_dns_partial"))
            said.add("dns_partial")
    elif r.get("cloudflare_proxied") is True:
        lines.append(_t(user_id, "lazy_dns_cf"))
        said.add("cloudflare_proxied")
    elif "dns_unknown" in reasons:
        lines.append(_tf(user_id, "lazy_dns_unknown_fmt", refresh))
        said.add("dns_unknown")
    elif "dns_partial" in reasons or any(ip in server_ips for ip in a):
        lines.append(_tf(user_id, "lazy_dns_partial_fmt", marked or "?", refresh))
        said.add("dns_partial")
    elif a:
        lines.append(_tf(user_id, "lazy_dns_foreign_fmt", esc(", ".join(a)), own, refresh))
        said.add("dns_elsewhere")
    else:
        lines.append(_tf(user_id, "lazy_dns_none_fmt", own, refresh))
        said.add("dns_none")
    aaaa_foreign = [ip for ip in _lazy_list(r.get("aaaa")) if ip not in server_ips]
    if aaaa_foreign:
        lines.append("⚠️ " + _tf(user_id, "site_check_aaaa_fmt", esc(display), esc(", ".join(aaaa_foreign))))
        said.add("aaaa_foreign")
    ports = r.get("ports") if isinstance(r.get("ports"), dict) else {}
    for key, port in (("tcp80", "TCP 80"), ("tcp443", "TCP 443"), ("udp443", "UDP 443")):
        info = ports.get(key)
        if not isinstance(info, dict) or not isinstance(info.get("free"), bool):
            continue
        if info.get("ours") is True:
            # Порт держим мы сами (наш nginx, наш профиль): для сценария он свободен, но «свободен» — неправда (LZ-05)
            lines.append(_tf(user_id, "lazy_port_ours_fmt", port))
            continue
        if info["free"]:
            lines.append(_tf(user_id, "lazy_port_free_fmt", port))
            continue
        # UDP 443 не останавливает (итог — Semi-Pro); TCP мешает, только когда план «не ставим»
        icon = "⚠️" if key == "udp443" else ("⛔" if blocked else "ℹ️")
        by = _lazy_by(info.get("by"))
        lines.append("%s %s" % (icon, _tf(user_id, "lazy_port_busy_fmt", port, esc(by)) if by
                                else _tf(user_id, "lazy_port_busy_nobody_fmt", port)))
        said.add("%s_busy" % key)
    apps = [c for c in (r.get("app_containers") or []) if isinstance(c, dict) and c.get("name")]
    if apps:
        # AmneziaWG — с линией и портом; прочие протоколы приложения (Xray, Cloak…) — именем
        lines.append(_tf(user_id, "lazy_app_fmt", ", ".join(
            "%s (%s, UDP %s)" % (esc(c.get("name")), esc(c.get("line")), esc(c.get("port") or "?")) if c.get("line")
            else esc(c.get("name")) for c in apps)))
    return lines, said


def lazy_check_lines(user_id: Optional[int], r: Dict[str, Any]) -> Tuple[List[str], str]:
    """Экран плана по ответу lazy-check (шаг 2): факты из самих данных, затем план, причины, которых данные не
    показали (tcp443_app, no_line_for_443, awg2_container_busy…), и какая линия встанет на UDP 443. → (строки, план)."""
    plan = lazy_plan_of(r)
    facts, said = lazy_check_facts(user_id, r, plan == "blocked")
    return facts + [""] + lazy_plan_lines(user_id, plan, _lazy_list(r.get("reasons")), said, lazy_line443(r),
                                          lazy_keys_count(r, "keys_new", LAZY_KEYS),
                                          lazy_keys_count(r, "keys_have", 0)), plan


def lazy_refusal_view(user_id: Optional[int], r: Dict[str, Any], domain: str = "") -> Tuple[str, "InlineKeyboardMarkup"]:
    """Отказ lazy-setup: слова ядра и код. Отказ проверки (до изменений) несёт ещё plan и reasons — их показываем,
    как на шаге проверки: «⛔ не встанет», причины словами (фактов — DNS, портов — в отказе нет), что делать, и
    «🔄 Обновить» с «✏️ Другой домен». Сорвалось по ходу при выполнимом плане — только причины, если они есть.
    Let's Encrypt отказал новому домену живого сайта (cert_failed с причиной) — своими словами (L-26)."""
    text = cert_fail_text(user_id, r, domain)
    reasons = _lazy_list(r.get("reasons"))
    if not r.get("plan") and not reasons:
        return text, back_kb(user_id, "se_mode")
    more = (lazy_plan_lines(user_id, "blocked", reasons) if r.get("plan") and lazy_plan_of(r) == "blocked"
            else lazy_code_lines(user_id, reasons))
    rows = [[btn(_t(user_id, "btn_refresh"), "se_lazy_re"), btn(_t(user_id, "lazy_other_domain_btn"), "se_lazy")],
            _back_row(user_id, "se_mode_pick")]
    return "\n".join([text, ""] + more if more else [text]), InlineKeyboardMarkup(rows)


def lazy_check_view(user_id: Optional[int], r: Dict[str, Any]) -> Tuple[str, "InlineKeyboardMarkup", str]:
    """Экран шага 2 целиком: (текст, кнопки, план). «✅ Поставить по плану» — только у плана, который ставится."""
    title = "<b>%s</b>" % _t(user_id, "lazy_plan_title")
    if not bridge_ok(r):
        if str(r.get("code") or "") == "unknown_action":
            # Ядро старше бота: действия ещё нет — не ошибка, а «после обновления»
            return "%s\n\n%s" % (title, _t(user_id, "lazy_unsupported")), back_kb(user_id, "se_mode_pick"), ""
        return ("%s\n\n%s" % (title, fail_text(user_id, r)),
                InlineKeyboardMarkup([[btn(_t(user_id, "btn_refresh"), "se_lazy_re")], _back_row(user_id, "se_mode_pick")]), "")
    lines, plan = lazy_check_lines(user_id, r)
    rows = []
    if plan in LAZY_PLANS_OK:
        rows.append([btn(_t(user_id, "lazy_go_btn"), "se_lazy_go")])
    rows.append([btn(_t(user_id, "btn_refresh"), "se_lazy_re"), btn(_t(user_id, "lazy_other_domain_btn"), "se_lazy")])
    rows.append(_back_row(user_id, "se_mode_pick"))
    return "%s\n\n%s" % (title, "\n".join(lines)), InlineKeyboardMarkup(rows), plan


async def cb_se_lazy(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_lazy: Ленивый Pro — что будет сделано и вопрос о домене (шаг 1)."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    flow_set(context, "lazy_domain")
    await safe_edit_message(query, "<b>%s — %s</b>\n\n%s\n\n%s" % (
        _t(user_id, "lazy_btn"), _t(user_id, "mode_sub_lazy"), _tf(user_id, "lazy_intro_fmt", LAZY_KEYS),
        _t(user_id, "lazy_ask_domain")), reply_markup=cancel_kb(user_id, "se_mode_pick"))


async def _lazy_check(target, context, user_id: Optional[int], domain: str, edit: bool, display: str = "") -> None:
    """lazy-check и экран плана (шаг 2). target — CallbackQuery (edit) или Message (ответ на домен текстом).

    Домен запоминаем до вызова: «🔄 Обновить» повторяет проверку и после сбоя моста."""
    display = display or domain
    state = {"domain": domain, "display": display, "plan": "", "at": time.monotonic()}
    context.user_data["lazy"] = state
    wait = _tf(user_id, "lazy_checking_fmt", esc(display))
    status_msg = None
    if edit:
        await safe_edit_message(target, wait, reply_markup=None)
    else:
        status_msg = await target.reply_text(wait, parse_mode="HTML")
    r = await run_bot_action("lazy-check", timeout=LAZY_CHECK_TIMEOUT, who=user_id, domain=domain)
    text, markup, plan = lazy_check_view(user_id, r)
    if bridge_ok(r):
        # План, причины и линия на UDP 443 — для подтверждения (шаг 3): оно повторяет их, не спрашивая мост снова
        state.update(plan=plan, display=str(r.get("domain_display") or "").strip() or display, at=time.monotonic(),
                     reasons=_lazy_list(r.get("reasons")), line443=lazy_line443(r),
                     keys_new=lazy_keys_count(r, "keys_new", LAZY_KEYS), keys_have=lazy_keys_count(r, "keys_have", 0))
    await _replace_status(target, edit, status_msg, text, markup)


async def cb_se_lazy_re(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_lazy_re: «🔄 Обновить» — та же проверка того же домена (DNS расходится не сразу)."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    state = context.user_data.get("lazy") if isinstance(context.user_data.get("lazy"), dict) else {}
    domain = str(state.get("domain") or "")
    if not valid_domain(domain):
        # Бот перезапускался или проверки не было: домен спрашиваем заново
        rows = [[btn(_t(user_id, "lazy_other_domain_btn"), "se_lazy")], _back_row(user_id, "se_mode_pick")]
        await safe_edit_message(query, "⚠️ " + _t(user_id, "lazy_expired"), reply_markup=InlineKeyboardMarkup(rows))
        return
    await _lazy_check(query, context, user_id, domain, edit=True, display=str(state.get("display") or ""))


def lazy_confirm_warn(user_id: Optional[int], state: Dict[str, Any], status: Dict[str, Any]) -> str:
    """Что будет сделано — над фразой LAZY <домен> (шаг 3): домен, план, что станет с тем, что уже стоит."""
    plan = str(state.get("plan") or "")
    target = "lite_site" if plan == "semi_pro" else "pro"
    reasons = _lazy_list(state.get("reasons"))
    parts = ["<b>%s</b>\n%s" % (esc(lazy_label(user_id)), lazy_domain_line(user_id, state.get("domain"), state.get("display")))]
    parts.append(lazy_plan_head(user_id, plan, reasons, lazy_keys_count(state, "keys_new", LAZY_KEYS)))
    if lazy_keys_count(state, "keys_have", 0):
        parts.append(_tf(user_id, "lazy_keys_have_fmt", lazy_keys_count(state, "keys_have", 0)))
    if "no_line_for_443" in reasons:
        # «Lite → Ленивый Pro»: почему Semi-Pro и как потом поставить линию на UDP 443 (ключи этой линии — заново)
        parts.append(_t(user_id, "lazy_code_no_line_for_443"))
    note = lazy_line443_note(user_id, str(state.get("line443") or "")) if plan == "pro" else ""
    if note:
        parts.append(note)
    if bridge_ok(status) and installed_profiles(status):
        parts.append(_t(user_id, "lazy_installed_note"))
    current = str(status.get("mode") or "") if bridge_ok(status) else ""
    if current and (current == "pro") != (target == "pro"):
        # Домен в новых ключах — только в Pro (SR-43): переход в него или из него меняет адрес в новых ключах
        parts.append(_t(user_id, "se_mode_warn_keys_host"))
    parts.append(_t(user_id, "lazy_long_note"))
    return "\n\n".join(parts)


async def cb_se_lazy_go(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_lazy_go: план проверен — фраза LAZY <домен> (шаг 3). Устаревший план сначала проверяем снова."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    state = context.user_data.get("lazy") if isinstance(context.user_data.get("lazy"), dict) else {}
    domain = str(state.get("domain") or "")
    if not valid_domain(domain):
        rows = [[btn(_t(user_id, "lazy_other_domain_btn"), "se_lazy")], _back_row(user_id, "se_mode_pick")]
        await safe_edit_message(query, "⚠️ " + _t(user_id, "lazy_expired"), reply_markup=InlineKeyboardMarkup(rows))
        return
    if state.get("plan") not in LAZY_PLANS_OK or time.monotonic() - float(state.get("at") or 0) > LAZY_PLAN_TTL:
        # План старше ожидания ввода или «не ставим»: ставить по нему нельзя — показываем свежий
        await _lazy_check(query, context, user_id, domain, edit=True, display=str(state.get("display") or ""))
        return
    # Бот уже занят операцией (например, другой Ленивый Pro на полчаса) — «занято», как у кнопок прочих
    # действий: фраза, взведённая сейчас, поставила бы вторую установку в очередь за первой.
    if await _action_busy(query, user_id, "se_mode_pick"):
        return
    status = await get_status(fresh=True)
    # Порты профилей ДО установки: итог назовёт каждый сменившийся — выданные с ним ключи перестанут подключаться
    before = {str(p.get("profile")): str(p.get("port") or "") for p in status_profiles(status)} if bridge_ok(status) else {}
    await arm_typed_confirm(query, context, user_id, "lazy-setup", domain, back_to="se_mode_pick",
                            warn=lazy_confirm_warn(user_id, state, status),
                            extra={"display": str(state.get("display") or domain), "before": before})


def lazy_keys(r: Dict[str, Any]) -> List[Dict[str, str]]:
    """keys[] ответа lazy-setup: имя, подпись и адрес страницы (строкой или объектом с url, как у page-create)."""
    out = []
    for k in r.get("keys") or []:
        if not isinstance(k, dict):
            continue
        name = str(k.get("name") or "").strip()
        if not valid_name(name):
            continue
        label = str(k.get("label") or "").strip()
        page = k.get("page")
        url = str((page.get("url") if isinstance(page, dict) else page) or "").strip()
        out.append({"name": name, "label": label if valid_label(label) else "",
                    "url": url if PAGE_URL_RE.match(url) else ""})
    return out


def lazy_result_view(user_id: Optional[int], r: Dict[str, Any], before: Any, display: str = "") -> Tuple[str, list]:
    """Итог lazy-setup (шаг 5): режим, домен, сайт, что на UDP 443, профили и сменившиеся порты, панель, ключи,
    предупреждения; кнопки — к людям, проверке сайта и панели."""
    lines = ["✅ <b>%s</b>" % _t(user_id, "lazy_done_title"), ""]
    mode = str(r.get("mode") or "")
    mode = "lite_site" if mode == "semi_pro" else mode
    if mode:
        lines.append("%s <b>%s</b>" % (_t(user_id, "dash_mode"), esc(mode_label(user_id, mode))))
    if r.get("domain"):
        lines.append(lazy_domain_line(user_id, r.get("domain"), display))
    site = r.get("site") if isinstance(r.get("site"), dict) else {}
    template = str(site.get("template") or site.get("template_id") or "")
    if template:
        lines.append("%s <code>%s</code>" % (_t(user_id, "site_template"), esc(template)))
    warnings = _lazy_list(r.get("warnings"))
    said: set = set()
    udp = r.get("udp443") if isinstance(r.get("udp443"), dict) else None
    if udp and (udp.get("line") or udp.get("profile")):
        name = _tf(user_id, "pr_line_name_fmt", udp.get("line")) if udp.get("line") else profile_name(user_id, udp.get("profile"))
        lines.append(_tf(user_id, "lazy_done_udp443_fmt", esc(name)))
    elif "udp443_busy" in warnings:
        lines.append(_t(user_id, "lazy_done_udp443_none"))
        said.add("udp443_busy")
    else:
        # На 443 никого, но не потому, что порт занят: например, обе линии уже стояли на своих портах
        # (no_line_for_443 — частый «Lite → Ленивый Pro»); почему именно — строкой предупреждения ниже
        lines.append(_t(user_id, "lazy_done_udp443_free"))
    before = before if isinstance(before, dict) else {}
    parts, moved = [], []
    for p in r.get("profiles") or []:
        if not isinstance(p, dict):
            continue
        pid = str(p.get("id") or p.get("profile") or "")
        name = _tf(user_id, "pr_line_name_fmt", p.get("line")) if p.get("line") else profile_line_name(user_id, pid)
        port = str(p.get("port") or "?")
        parts.append("%s · UDP %s" % (esc(name), esc(port)))
        if before.get(pid) and before.get(pid) != port:
            moved.append(_tf(user_id, "lazy_done_port_moved_fmt", esc(name), esc(before.get(pid)), esc(port)))
    if parts:
        lines.append("%s %s" % (_t(user_id, "dash_profiles"), ", ".join(parts)))
    lines.extend(moved)
    if r.get("panel_on_domain") is True:
        lines.append(_tf(user_id, "lazy_done_panel_fmt", _t(user_id, "se_panel")))
    keys = lazy_keys(r)
    lines.append(_tf(user_id, "lazy_done_keys_fmt" if any(k["url"] for k in keys) else "lazy_done_keys_nopages_fmt",
                     len(keys)))
    # Сайт на запасном сертификате, и ядро знает, почему Let's Encrypt отказал (cert_cause): что случилось и что
    # сделать — по причине, а не общее «когда A-запись разойдётся» (L-26)
    cause = cert_cause_text(user_id, r) if "cert_fallback" in warnings else ""
    if cause:
        lines.extend([_tf(user_id, "lazy_cert_fallback_fmt", esc(display or r.get("domain") or "")), cause,
                      _t(user_id, "lazy_cert_fallback_where")])
        said.add("cert_fallback")
    # warnings: свои коды lazy-setup и причины lazy-check, которые сценарий обошёл (договор, уточнения 28.09)
    lines.extend(lazy_code_lines(user_id, warnings, said, "lazy_warn_unknown_fmt"))
    rows = [[btn(_t(user_id, "menu_users"), "menu_users"), btn(_t(user_id, "se_site_check"), "se_check")]]
    if "no_line_for_443" in warnings and mode == "lite_site":
        # Линии на своих портах — Semi-Pro; поставить линию на UDP 443 можно отсюда же: переход в Pro с выбором линии
        rows.append([btn(_t(user_id, "pl_btn"), "se_mode_to~pro")])
    if r.get("panel_on_domain") is True:
        rows.append([btn(_t(user_id, "se_panel"), "se_panel")])
    return "\n".join(lines), rows


def lazy_pages_text(user_id: Optional[int], r: Dict[str, Any]) -> str:
    """Страницы подключения новых ключей — отдельным сообщением после итога: каждая ссылка — ключ человека.
    Без адресов — пусто (сообщения не будет)."""
    keys = lazy_keys(r)
    if not any(k["url"] for k in keys):
        return ""
    lines = ["<b>%s</b>" % _t(user_id, "lazy_pages_title"), ""]
    for i, k in enumerate(keys, 1):
        who = esc(k["label"] or k["name"])
        if k["label"] and k["label"] != k["name"]:
            who += " (<code>%s</code>)" % esc(k["name"])
        lines.append("%d. %s" % (i, who))
        lines.append("<code>%s</code>" % esc(k["url"]) if k["url"] else "<i>%s</i>" % _t(user_id, "lazy_page_none"))
    lines.append("")
    lines.append(_tf(user_id, "lazy_pages_hint", _t(user_id, "menu_users")))
    return clip_lines("\n".join(lines))


# ── Шаблон сайта-маскировки (change-template) ────────────────────────────────
# В каталоге 33 тысячи записей: список в чат не влезает ни при каких страницах,
# поэтому здесь то же, что в панели, — сначала категория (18 штук), потом
# страница по 8 записей, плюс поиск по названию. Соответствие «короткий ключ
# кнопки → id шаблона» живёт в user_data того, кто листает.
TEMPLATES_PER_PAGE = 8
TEMPLATE_SEARCH_LIMIT = 240


def _tpl_remember(context, items: List[Dict[str, Any]]) -> Dict[str, str]:
    """Запомнить ключ→id показанной страницы: в callback_data влезает только ключ."""
    table = context.user_data.get("tpl_keys")
    if not isinstance(table, dict):
        table = {}
    for t in items:
        table[template_short_key(str(t.get("id") or ""))] = str(t.get("id") or "")
    # Держим только последние страницы: карта не должна расти всю сессию.
    if len(table) > 200:
        table = dict(list(table.items())[-200:])
    context.user_data["tpl_keys"] = table
    return table


async def cb_se_tpl(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_tpl: категории каталога, поиск и «наугад»."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    cat = await get_catalog()
    if cat is None:
        await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "se_tpl"), _t(user_id, "tpl_no_catalog")),
                                reply_markup=back_kb(user_id, "se_mode"))
        return
    status = await get_status()
    current = str(((status.get("site") or {}) if bridge_ok(status) else {}).get("template_id") or "")
    lines = ["<b>%s</b>" % _t(user_id, "se_tpl"), ""]
    lines.append("%s %s" % (_t(user_id, "site_template"),
                            ("<code>%s</code>" % esc(current)) if current else ("<i>%s</i>" % _t(user_id, "site_template_none"))))
    lines.append("")
    lines.append(_t(user_id, "tpl_pick_category"))
    rows = []
    for cid, cname, count in cat.categories():
        if not valid_template_category(cid):
            continue
        rows.append([btn("%s (%d)" % (cname, count), "se_tplc~%s~0" % cid)])
    rows.append([btn(_t(user_id, "tpl_search_btn"), "se_tplq"), btn(_t(user_id, "tpl_random_btn"), "se_tplr")])
    rows.append(_back_row(user_id, "se_mode"))
    await safe_edit_message(query, "\n".join(lines), reply_markup=kb(rows))


async def _tpl_page_screen(target, context, user_id: Optional[int], items: List[Dict[str, Any]],
                           page: int, pages: int, back_to: str, category: str, title: str,
                           edit: bool = True) -> None:
    """Одна страница списка шаблонов: кнопка на запись + листалка."""
    _tpl_remember(context, items)
    rows = []
    for t in items:
        name = str(t.get("name") or t.get("id") or "?")[:28]
        rows.append([btn(name, "se_tplp~%s" % template_short_key(str(t.get("id") or "")))])
    if pages > 1:
        # callback листалки — двумя литералами прямо в кнопке: страница
        # категории или страница результатов поиска. Ни склейку, ни вызов
        # tests/check_menu.py разобрать не может, а маршрут должен быть виден.
        nav = []
        if page > 0:
            nav.append(btn("‹", "se_tplc~%s~%d" % (category, page - 1) if category
                           else "se_tplf~%d" % (page - 1)))
        nav.append(btn("%d/%d" % (page + 1, pages), "noop"))
        if page < pages - 1:
            nav.append(btn("›", "se_tplc~%s~%d" % (category, page + 1) if category
                           else "se_tplf~%d" % (page + 1)))
        rows.append(nav)
    rows.append(_back_row(user_id, back_to))
    lines = ["<b>%s</b>" % esc(title), ""]
    if items:
        lines.append(_t(user_id, "tpl_pick_one"))
    else:
        lines.append("<i>%s</i>" % _t(user_id, "tpl_nothing_found"))
    markup = InlineKeyboardMarkup(rows)
    if edit:
        await safe_edit_message(target, "\n".join(lines), reply_markup=markup)
    else:
        await target.reply_text("\n".join(lines), parse_mode="HTML", reply_markup=markup)


async def cb_se_tpl_category(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_tplc~<категория>~<страница>: страница шаблонов категории."""
    query = update.callback_query
    user_id = _uid(update)
    parts = str(query.data).split("~")
    if len(parts) != 3 or not valid_template_category(parts[1]) or not parts[2].isdigit():
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    cat = await get_catalog()
    if cat is None:
        await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "se_tpl"), _t(user_id, "tpl_no_catalog")),
                                reply_markup=back_kb(user_id, "se_mode"))
        return
    cid, page = parts[1], int(parts[2])
    items, pages = cat.page(cid, page, TEMPLATES_PER_PAGE)
    page = max(0, min(page, pages - 1))
    name = next((n for i, n, _ in cat.categories() if i == cid), cid)
    await _tpl_page_screen(query, context, user_id, items, page, pages, "se_tpl", cid, name)


async def cb_se_tpl_search(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_tplq: спросить слово для поиска по названию шаблона."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    flow_set(context, "tpl_search")
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "tpl_search_btn"), _t(user_id, "tpl_search_ask")),
                            reply_markup=cancel_kb(user_id, "se_tpl"))


async def cb_se_tpl_found(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_tplf~<страница>: страница результатов последнего поиска (слово в user_data)."""
    query = update.callback_query
    user_id = _uid(update)
    raw = str(query.data).split("~", 1)[1] if "~" in str(query.data) else ""
    if not raw.isdigit():
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    await _tpl_search_page(query, context, user_id, str(context.user_data.get("tpl_query") or ""), int(raw))


async def _tpl_search_page(target, context, user_id: Optional[int], word: str, page: int,
                           edit: bool = True) -> None:
    cat = await get_catalog()
    if cat is None or not word:
        text = "<b>%s</b>\n\n%s" % (_t(user_id, "se_tpl"), _t(user_id, "tpl_no_catalog"))
        markup = back_kb(user_id, "se_mode")
        if edit:
            await safe_edit_message(target, text, reply_markup=markup)
        else:
            await target.reply_text(text, parse_mode="HTML", reply_markup=markup)
        return
    found = cat.search(word, None, limit=TEMPLATE_SEARCH_LIMIT)
    items, page, pages = paginate(found, page, TEMPLATES_PER_PAGE)
    await _tpl_page_screen(target, context, user_id, items, page, pages, "se_tpl", "",
                           _tf(user_id, "tpl_found_fmt", word, len(found)), edit=edit)


async def cb_se_tpl_pick(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_tplp~<ключ>: карточка шаблона и подтверждение фразой."""
    query = update.callback_query
    user_id = _uid(update)
    key = str(query.data).split("~", 1)[1] if "~" in str(query.data) else ""
    table = context.user_data.get("tpl_keys")
    tid = str((table or {}).get(key) or "") if isinstance(table, dict) else ""
    if not valid_template_key(key) or not valid_template_id(tid):
        # Карта ключей живёт в памяти процесса: после рестарта бота кнопка со
        # старой страницы уже ничего не значит — говорим об этом, а не молчим.
        await query.answer(_t(user_id, "tpl_key_lost"), show_alert=True)
        return
    await query.answer()
    cat = await get_catalog()
    t = cat.get(tid) if cat is not None else None
    name = str((t or {}).get("name") or tid)
    lines = [_tf(user_id, "tpl_card_fmt", esc(name), esc(tid))]
    if t:
        descr = str(t.get("description") or "").strip()
        if descr:
            lines.append(esc(descr[:200]))
        meta = [x for x in (str(t.get("category") or ""), str(t.get("license") or "")) if x]
        if meta:
            lines.append("<i>%s</i>" % esc(" · ".join(meta)))
        preview = str(t.get("preview_url") or "").strip()
        if preview.startswith("https://"):
            lines.append("%s <code>%s</code>" % (_t(user_id, "tpl_preview"), esc(preview)))
    await _arm_template_confirm(query, context, user_id, tid, "\n".join(lines))


async def _arm_template_confirm(query, context, user_id: Optional[int], template_id: str, card: str) -> None:
    """Фраза TEMPLATE site: цель — сайт, а сам шаблон едет в extra (id до 120 символов)."""
    warn = "%s\n\n%s" % (card, _t(user_id, "tpl_replace_warn"))
    await arm_typed_confirm(query, context, user_id, "change-template", "site",
                            back_to="se_tpl", warn=warn, extra={"template": template_id})


async def cb_se_tpl_random(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_tplr: шаблон наугад — выбор делает мост по __random__."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    await _arm_template_confirm(query, context, user_id, TEMPLATE_RANDOM, _t(user_id, "tpl_random_body"))


# ── Проверка сайта, Alt-Svc, предполётная проверка портов ────────────────────

SITE_VERDICT_KEYS = {"ok": "site_verdict_ok", "not_pro": "site_verdict_not_pro",
                     "no_domain": "site_verdict_no_domain", "dns_mismatch": "site_verdict_dns_mismatch",
                     "dns_partial": "site_verdict_dns_partial", "dns_unknown": "site_verdict_dns_unknown",
                     "no_cert": "site_verdict_no_cert", "http_error": "site_verdict_http_error",
                     "no_site": "site_verdict_no_site", "cert_expiring": "site_verdict_cert_expiring",
                     "dry_run": "site_verdict_dry_run"}


async def cb_se_site_check(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_check: сайт и сертификат снаружи — тот же website_check, что в SSH."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    await safe_edit_message(query, "⏳ " + _t(user_id, "site_checking"), reply_markup=None)
    r = await run_bot_action("site-check", timeout=120)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "se_mode")
        return
    site = r.get("site") if isinstance(r.get("site"), dict) else {}
    verdict = str(r.get("verdict") or site.get("verdict") or "")
    lines = ["<b>%s</b>" % _t(user_id, "se_site_check"), ""]
    key = SITE_VERDICT_KEYS.get(verdict)
    lines.append(("✅ " if verdict == "ok" else "⚠️ ") + (_t(user_id, key) if key else esc(verdict or "—")))
    rows = [[btn(_t(user_id, "btn_refresh"), "se_check")], _back_row(user_id, "se_mode")]
    if verdict == "not_pro":
        # «Lite»: сайта нет — и «Ответ HTTPS: 0 · HTTP: 0», «nginx: выключен» под
        # словами «проверять нечего» только спорили с ними (T30, как T29 в SSH).
        await safe_edit_message(query, "\n".join(lines), reply_markup=InlineKeyboardMarkup(rows))
        return
    # Чем именно плох DNS (сцены site-check-a, -foreign, -aaaa дизайна 0.5.0): какие A-записи у домена
    # и какие из них этот сервер (✓), AAAA не сюда — Let's Encrypt пробует IPv6 первым (L-18, DS2-07)
    domain = str(site.get("domain") or "").strip()
    a_ips = [str(x) for x in (site.get("dns_ips") if isinstance(site.get("dns_ips"), list) else []) if x]
    if verdict in ("dns_mismatch", "dns_partial") and a_ips:
        foreign = {str(x) for x in (site.get("dns_foreign") if isinstance(site.get("dns_foreign"), list) else [])}
        here = str(site.get("server_ip") or "")
        marked = ", ".join(("%s ✓" % ip) if (ip == here or (foreign and ip not in foreign)) else ip for ip in a_ips)
        lines.append(_tf(user_id, "site_check_a_records_fmt", esc(domain or "—"), esc(marked)))
    aaaa = [str(x) for x in (site.get("dns_aaaa_foreign") if isinstance(site.get("dns_aaaa_foreign"), list) else []) if x]
    if aaaa:
        lines.append("⚠️ " + _tf(user_id, "site_check_aaaa_fmt", esc(domain or "—"), esc(", ".join(aaaa))))
    if verdict == "http_error":
        # Сайт молчит по HTTPS — первым делом: открыт ли 443 снаружи (сцена site-check-https)
        rows.insert(0, [btn(_t(user_id, "se_preflight"), "se_pf")])
    lines.append("")
    url = str(site.get("url") or "").strip()
    if url:
        lines.append("%s <code>%s</code>" % (_t(user_id, "site_url"), esc(url)))
    lines.append(_tf(user_id, "site_check_codes_fmt", esc(site.get("https_code") or site.get("code") or 0),
                     esc(site.get("http_code") or 0)))
    lines.append("%s %s" % (_t(user_id, "site_check_nginx"),
                            _t(user_id, "state_on" if site.get("nginx_active") else "state_off")))
    lines.extend(site_summary_lines(user_id, dict(site, template_id=site.get("template_id") or "")))
    await safe_edit_message(query, "\n".join(lines), reply_markup=InlineKeyboardMarkup(rows))


async def cb_se_alt_svc(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_alt: заголовок Alt-Svc — объявление HTTP/3 на UDP/443 «для правдоподобия»."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    on = config_alt_svc()
    rows = [[btn(_t(user_id, "se_alt_svc_off" if on else "se_alt_svc_on"), "se_alt_set~%s" % ("off" if on else "on"))],
            _back_row(user_id, "se_mode")]
    text = "<b>%s</b>\n\n%s %s\n\n%s" % (_t(user_id, "se_alt_svc_btn"), _t(user_id, "site_alt_svc"),
                                         _t(user_id, "state_on" if on else "state_off"),
                                         _t(user_id, "se_alt_svc_body"))
    await safe_edit_message(query, text, reply_markup=InlineKeyboardMarkup(rows))


async def cb_se_alt_svc_set(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_alt_set~on|off: применить заголовок (в Lite сохранится до включения сайта)."""
    query = update.callback_query
    user_id = _uid(update)
    arg = str(query.data).split("~", 1)[1] if "~" in str(query.data) else ""
    asked = arg.endswith("~do")
    state = arg[:-3] if asked else arg
    if state not in ("on", "off"):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    # Включение спрашиваем, выключение — нет: ровно как в SSH. Объявив HTTP/3,
    # сервер зовёт браузеры на UDP/443, где стоит AmneziaWG, — они упрутся и
    # откатятся на TCP, и это заметно снаружи. Снять объявление вреда не несёт.
    if state == "on" and not asked:
        rows = [[btn(_t(user_id, "btn_confirm"), "se_alt_set~on~do")], _back_row(user_id, "se_alt")]
        await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "se_alt_svc_btn"),
                                                          _t(user_id, "se_alt_svc_warn")),
                                reply_markup=InlineKeyboardMarkup(rows))
        return
    if await _action_busy(query, user_id, "se_alt"):
        return
    r = await mutate("site-alt-svc", who=user_id, state=state)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "se_alt")
        return
    text = "✅ " + esc(r.get("message") or _t(user_id, "done"))
    if r.get("applied") is False:
        # Lite: настройка легла в config.json, но nginx её ещё не видел.
        text += "\n\n" + _t(user_id, "se_alt_svc_saved_only")
    await safe_edit_message(query, text, reply_markup=back_kb(user_id, "se_alt"))


async def cb_se_preflight(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_pf: кто занял 80/443 и какие режимы из-за этого недоступны."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    await safe_edit_message(query, "⏳ " + _t(user_id, "pf_checking"), reply_markup=None)
    r = await run_bot_action("preflight", timeout=120)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "se_mode")
        return
    modes = r.get("modes") if isinstance(r.get("modes"), dict) else {}
    lines = ["<b>%s</b>" % _t(user_id, "se_preflight"), ""]
    for m in MODES:
        info = modes.get(m) if isinstance(modes.get(m), dict) else {}
        ok = bool(info.get("available", m == "lite"))
        lines.append("%s <b>%s</b>: %s" % ("✅" if ok else "⛔", esc(mode_label(user_id, m)),
                                           _t(user_id, "pf_available" if ok else "pf_unavailable")))
        # reasons[].message мост уже собрал на языке словаря — показываем как есть
        for reason in (info.get("reasons") or [])[:3]:
            if isinstance(reason, dict) and reason.get("message"):
                lines.append("   • %s" % esc(reason.get("message")))
    warnings = [w for w in (modes.get("warnings") or []) if isinstance(w, dict) and w.get("message")]
    if warnings:
        lines.append("")
        for w in warnings[:3]:
            lines.append("⚠️ " + esc(w.get("message")))
    hint = str(r.get("hint") or "").strip()
    if hint:
        lines.append("")
        lines.append("%s <code>%s</code>" % (_t(user_id, "pf_hint"), esc(hint)))
    rows = [[btn(_t(user_id, "btn_refresh"), "se_pf")], _back_row(user_id, "se_mode")]
    await safe_edit_message(query, "\n".join(lines), reply_markup=InlineKeyboardMarkup(rows))


async def cb_se_dns(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    cfg = read_config_display()
    current = cfg.get("client_dns") if isinstance(cfg.get("client_dns"), list) else []
    rows = [
        [btn(_t(user_id, "wz_dns_cf"), "se_dns_set~cf")],
        [btn(_t(user_id, "wz_dns_google"), "se_dns_set~google")],
        [btn(_t(user_id, "wz_dns_adguard"), "se_dns_set~adguard")],
        [btn(_t(user_id, "wz_dns_custom"), "se_dns_custom")],
        _back_row(user_id, "sec_settings"),
    ]
    text = "<b>%s</b>\n\n%s <code>%s</code>\n\n%s" % (
        _t(user_id, "wz_dns_title"), _t(user_id, "dns_current"),
        esc(", ".join(str(x) for x in current) or "—"), _t(user_id, "dns_hint"))
    await safe_edit_message(query, text, reply_markup=InlineKeyboardMarkup(rows))


async def _apply_dns(target, user_id: Optional[int], dns1: str, dns2: str, edit: bool) -> None:
    if not edit:
        await _queued_notice(target, user_id)
    r = await mutate("dns-set", who=user_id, dns1=dns1, dns2=dns2 or None)
    text = ("✅ " + esc(r.get("message") or _t(user_id, "done"))) if bridge_ok(r) else (fail_text(user_id, r))
    markup = fail_markup(user_id, r, "sec_settings", retry_data(target) if edit else None)
    if edit:
        await safe_edit_message(target, text, reply_markup=markup)
    else:
        await target.reply_text(text, parse_mode="HTML", reply_markup=markup)


async def cb_se_dns_set(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    key = query.data.split("~", 1)[1] if "~" in query.data else ""
    if key not in DNS_PRESETS:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    if await _action_busy(query, user_id, "sec_settings"):
        return
    dns1, dns2 = DNS_PRESETS[key]
    await _apply_dns(query, user_id, dns1, dns2, edit=True)


async def cb_se_dns_custom(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    flow_set(context, "dns_custom")
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "wz_dns_custom"), _t(user_id, "dns_ask_custom")),
                            reply_markup=cancel_kb(user_id, "se_dns"))


async def cb_se_endpoint(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    status = await get_status()
    ok = bridge_ok(status)
    current = str(status.get("endpoint_host") or "") if ok else ""
    server_ip = str(status.get("server_ip") or "") if ok else ""
    # Что в ключах сейчас и что встанет по умолчанию — от ядра: пустое поле в Pro даёт домен, а не IP.
    effective = (str(status.get("endpoint_effective") or "") if ok else "") or current or server_ip or "—"
    auto = (str(status.get("endpoint_auto") or "") if ok else "") or server_ip or "—"
    flow_set(context, "endpoint")
    rows = []
    if current:
        rows.append([btn(_t(user_id, "se_endpoint_use_auto"), "se_endpoint_auto")])
    if valid_ipv4(server_ip) and server_ip != "0.0.0.0" and effective != server_ip:
        rows.append([btn(_t(user_id, "se_endpoint_use_ip"), "se_endpoint_ip")])
    rows.append([btn(_t(user_id, "btn_cancel"), "sec_settings")])
    # Вписанного адреса на сервере больше нет (L-02): сказать до вопроса — выбрать IP сервера или другой
    gone = endpoint_gone_host(status)
    warn = ("\n\n⚠️ " + _tf(user_id, "se_endpoint_gone_fmt", esc(gone))) if gone else ""
    text = "<b>%s</b>\n\n%s <code>%s</code>\n%s <code>%s</code>%s\n\n%s" % (
        _t(user_id, "se_endpoint"), _t(user_id, "endpoint_current"), esc(effective),
        _t(user_id, "endpoint_default"), esc(auto), warn, _t(user_id, "se_endpoint_ask"))
    await safe_edit_message(query, text, reply_markup=InlineKeyboardMarkup(rows))


async def _apply_endpoint(target, user_id: Optional[int], host: str, edit: bool) -> None:
    # Пустой host передаётся как --host= : «по умолчанию» — в Pro домен сервера, иначе его IP
    if not edit:
        await _queued_notice(target, user_id)
    r = await mutate("endpoint-set", who=user_id, host=host)
    text = ("✅ " + esc(r.get("message") or _t(user_id, "done"))) if bridge_ok(r) else (fail_text(user_id, r))
    markup = fail_markup(user_id, r, "sec_settings", retry_data(target) if edit else None)
    if edit:
        await safe_edit_message(target, text, reply_markup=markup)
    else:
        await target.reply_text(text, parse_mode="HTML", reply_markup=markup)


async def cb_se_endpoint_ip(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """«IP сервера» вписывает адрес в поле: пустое поле в Pro дало бы домен."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    flow_clear(context)
    if await _action_busy(query, user_id, "sec_settings"):
        return
    status = await get_status()
    ip = str(status.get("server_ip") or "") if bridge_ok(status) else ""
    if not valid_ipv4(ip) or ip == "0.0.0.0":
        await safe_edit_message(query, "❌ " + _t(user_id, "se_endpoint_no_ip"),
                                reply_markup=back_kb(user_id, "sec_settings"))
        return
    await _apply_endpoint(query, user_id, ip, edit=True)


async def cb_se_endpoint_auto(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """«По умолчанию»: пустое поле — в режиме Pro домен сервера, иначе IP."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    flow_clear(context)
    if await _action_busy(query, user_id, "sec_settings"):
        return
    await _apply_endpoint(query, user_id, "", edit=True)


async def cb_se_panel(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_panel: панель на домене — состояние, включение, смена секретного пути."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    status = await get_status()
    st = await run_bot_action("miniapp-status", timeout=60)
    ok = bridge_ok(st)
    if not ok:
        # Отказ моста — не «панель выключена»: иначе экран уверенно врал о состоянии,
        # которого не знает (и предлагал «Открыть панель», которой, может быть, и нет).
        await show_error(query, user_id, st, "sec_settings")
        return
    # enabled — панель на домене РАБОТАЕТ, configured — путь записан в конфиге,
    # available — в этом режиме она вообще возможна. После ухода из Pro в Lite
    # путь остаётся, и экран писал «включена» над панелью, которой нет
    # (DEFECTS §1.8). Теперь три состояния, а причина приходит от ядра.
    enabled = bool(st.get("enabled")) if ok else False
    configured = bool(st.get("configured", enabled)) if ok else False
    mode = str(st.get("mode") or (status.get("mode") if bridge_ok(status) else "") or "")
    available = bool(st.get("available", mode == "pro")) if ok else False
    hint = str(st.get("hint") or "").strip() if ok else ""
    rows = []
    url = miniapp_url(status)
    if url and enabled:
        rows.append([InlineKeyboardButton(_t(user_id, "menu_panel"), web_app=WebAppInfo(url=url))])
    # Экран показывает фактическое состояние: раньше здесь стояло «появится в
    # следующей версии», хотя рядом уже висела рабочая кнопка мини-аппа.
    if enabled:
        lines = [_t(user_id, "se_panel_on")]
    elif configured:
        lines = [_t(user_id, "se_panel_no_place")]
    else:
        lines = [_t(user_id, "se_panel_off")]
    if enabled:
        rows.append([btn(_t(user_id, "se_mini_rotate"), "se_mini~rot")])
    if configured:
        # Снять путь можно в любом режиме — иначе остаток от прежнего режима
        # нечем было бы убрать, и панель вернулась бы сама при возврате в Pro.
        rows.append([btn(_t(user_id, "se_mini_off"), "se_mini~off")])
    elif available:
        rows.append([btn(_t(user_id, "se_mini_on"), "se_mini~on")])
    if not available:
        # Секретный путь живёт в vhost сайта: без домена с доверенным
        # сертификатом его негде разместить. Подсказка ядра на известные причины —
        # команда CLI («подключите домен через change-mode --mode=lite_site|pro
        # --domain=…»): человеку в Telegram она ни о чём, у бота на это свой текст.
        # Незнакомую причину показываем как есть — экранированной: это текст моста.
        reason = str(st.get("reason") or "") if ok else ""
        lines.append("")
        if reason in ("no_site", "no_domain", "untrusted_cert") or not hint:
            lines.append(_t(user_id, "se_mini_needs_pro"))
        else:
            lines.append(esc(hint))
    lines.append("")
    lines.append(_t(user_id, "se_panel_ssh_hint"))
    rows.append(_back_row(user_id, "sec_settings"))
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "se_panel"), "\n".join(lines)),
                            reply_markup=kb(rows))


def miniapp_url_text(user_id: Optional[int], r: Dict[str, Any]) -> str:
    """Сообщение с адресом панели: адрес — секрет, значит как у доступа агента."""
    lines = ["<b>%s</b>" % _t(user_id, "se_panel"), ""]
    lines.append("<code>%s</code>" % esc(r.get("url") or ""))
    hint = str(r.get("hint") or "").strip()
    if hint:
        lines.append("")
        lines.append(esc(hint))
    lines.append("")
    lines.append(_t(user_id, "se_mini_url_is_key"))
    return "\n".join(lines)


async def cb_se_miniapp(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """se_mini~on|off|rot: панель на домене. Адрес с секретным путём — отдельным
    сообщением без предпросмотра и мимо лога, как ключ доступа агента."""
    query = update.callback_query
    user_id = _uid(update)
    arg = str(query.data).split("~", 1)[1] if "~" in str(query.data) else ""
    asked = arg.endswith("_do")
    what = arg[:-3] if asked else arg
    if what not in ("on", "off", "rot"):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    # Смена пути и снятие панели спрашиваются, включение — нет: ровно как в SSH и
    # в панели. Смена рвёт закладку и мини-апп у всех, кто ими пользуется, а
    # снятие закрывает единственный вход не через SSH-туннель.
    if what in ("off", "rot") and not asked:
        rows = [[btn(_t(user_id, "btn_confirm"), "se_mini~%s_do" % what)], _back_row(user_id, "se_panel")]
        await safe_edit_message(query, "<b>%s</b>\n\n%s" % (
            _t(user_id, "se_panel"),
            _t(user_id, "se_mini_rotate_confirm" if what == "rot" else "se_mini_off_confirm")),
            reply_markup=InlineKeyboardMarkup(rows))
        return
    if await _action_busy(query, user_id, "se_panel"):
        return
    action = {"on": "miniapp-on", "off": "miniapp-off", "rot": "miniapp-rotate"}[what]
    r = await mutate(action, who=user_id)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "se_panel")
        return
    logger.info("miniapp %s: enabled=%s", what, r.get("enabled"))
    if what == "off":
        await safe_edit_message(query, "✅ " + esc(r.get("message") or _t(user_id, "done")),
                                reply_markup=back_kb(user_id, "se_panel"))
        await refresh_menu_button_after(context)
        return
    await query.message.reply_text(miniapp_url_text(user_id, r), parse_mode="HTML",
                                   disable_web_page_preview=True,
                                   reply_markup=back_kb(user_id, "se_panel"))
    await safe_edit_message(query, "✅ " + _t(user_id, "se_mini_sent"),
                            reply_markup=back_kb(user_id, "se_panel"))
    await refresh_menu_button_after(context)


# ── Доступы агентов к MCP по HTTP (PLAN §6.10, docs/BOT.md §5) ───────────────
# Всё делает мост (agent-*, mcp-http-*); бот рисует список, карточку и задаёт
# вопросы. Адрес доступа равен ключу: он показывается только по явной кнопке
# «Показать адрес» (и один раз после выдачи), с предупреждением, без превью
# ссылки, и никогда не пишется в лог бота.

def agent_state(rec: Dict[str, Any]) -> str:
    """active | disabled | expired — как считает lib/agents.sh; старый ответ без state — по enabled."""
    state = str(rec.get("state") or "")
    if state in AGENT_STATES:
        return state
    return "active" if rec.get("enabled", True) else "disabled"


def agent_level(user_id: Optional[int], scope: Any) -> str:
    """Уровень доступа одним словарём с панелью (DS2-52): «Только чтение (read)», «Чтение и запись
    (write)», «Полный (admin)»; незнакомый — как есть."""
    scope = str(scope or "")
    return _t(user_id, "ag_level_%s" % scope) if scope in AGENT_SCOPES else scope


def agent_icon(state: str) -> str:
    return {"active": "●", "disabled": "○", "expired": "⏳", "compromised": "🚨"}.get(state, "·")


def transport_configured(tr: Any) -> bool:
    """Записан ли транспорт в конфиге (а не «работает ли он»).

    Ядро отдаёт enabled как ФАКТ, а configured — как запись в config.json: после
    ухода из Pro в Lite флаг остаётся, а слушать транспорту негде. Кнопки
    включения и выключения идут от записи, тексты — от факта.
    """
    if not isinstance(tr, dict):
        return False
    return bool(tr.get("configured", tr.get("enabled")))


def transport_lines(user_id: Optional[int], tr: Any) -> List[str]:
    """Состояние HTTP-транспорта из mcp-http-status / agent-list.transport (без секретов)."""
    if not isinstance(tr, dict):
        return ["%s <i>%s</i>" % (_t(user_id, "ag_transport"), _t(user_id, "err_unknown"))]
    enabled = bool(tr.get("enabled"))
    configured = transport_configured(tr)
    # Состояний три: работает, записан но работать негде, выключен. Раньше их
    # было два, и в Lite экран бодро писал «включён» над молчащим транспортом.
    if enabled:
        state = _t(user_id, "state_enabled")
    elif configured:
        state = _t(user_id, "ag_transport_no_place")
    else:
        state = _t(user_id, "state_disabled")
    lines = ["%s <b>%s</b>" % (_t(user_id, "ag_transport"), state)]
    listen = str(tr.get("listen") or "")
    base = str(tr.get("base_url") or "").strip()
    if listen == "nginx" and base:
        lines.append(_tf(user_id, "ag_listen_nginx_fmt", esc(base)))
    elif listen in ("public_port", "grant_ports"):
        lines.append(_tf(user_id, "ag_listen_port_fmt", esc(base or "—")))
    elif configured:
        lines.append(_t(user_id, "ag_listen_none"))
    fp = str(tr.get("cert_fingerprint_sha256") or "").strip()
    if fp:
        lines.append("%s <code>%s</code>" % (_t(user_id, "site_fingerprint"), esc(fp)))
    hint = str(tr.get("hint") or "").strip()
    if hint:
        lines.append("<i>%s</i>" % esc(hint))
    return lines


def agents_text(user_id: Optional[int], r: Dict[str, Any]) -> str:
    lines = ["<b>%s</b>" % _t(user_id, "se_agents"), ""]
    if not bridge_ok(r):
        lines.append(fail_text(user_id, r))
        lines.append("")
        lines.append(_t(user_id, "agents_body"))
        return "\n".join(lines)
    lines.extend(transport_lines(user_id, r.get("transport")))
    lines.append("")
    agents = [a for a in (r.get("agents") or []) if isinstance(a, dict)]
    if agents:
        lines.append("<b>%s</b>" % _t(user_id, "ag_list_title"))
        weak = 0
        frozen = 0
        for a in agents:
            st = agent_state(a)
            # ⚠️ у доступа без токена, 🔁 у одноразового ключа и ⚲ у привязанного к
            # адресу: состояние защиты видно прямо в списке, а не только в карточке.
            marks = ""
            if a.get("mode") == "rolling":
                marks += " 🔁"
            elif a.get("mode") == "connect":
                # ⏳ — код ещё не использован; ⚠️ — код истёк, и без перевыпуска доступ не привязать
                # (⌛ рядом с ⏳ на телефоне не отличить)
                if a.get("enroll_pending"):
                    marks += " 🔌⚠️" if a.get("enroll_expired") else " 🔌⏳"
                else:
                    marks += " 🔌"
            elif not a.get("require_token"):
                marks += " ⚠️"
                weak += 1
            if a.get("pin_ip"):
                marks += " ⚲"
            if a.get("compromised"):
                frozen += 1
            lines.append("%s <code>%s</code> %s · %s · %s%s" % (
                agent_icon(st), esc(a.get("id")), esc(a.get("label")), esc(agent_level(user_id, a.get("scope"))),
                _t(user_id, "ag_state_%s" % st), marks))
        if frozen:
            # Заморозка важнее слабых доступов: те работают, а этот стоит и ждёт решения
            lines.append("")
            lines.append("🚨 " + _tf(user_id, "ag_frozen_note_fmt", frozen))
        if weak:
            lines.append("")
            lines.append("⚠️ " + _tf(user_id, "ag_weak_note_fmt", weak))
    else:
        lines.append("<i>%s</i>" % _t(user_id, "ag_list_empty"))
    lines.append("")
    lines.append(_t(user_id, "agents_body"))
    return "\n".join(lines)


def agents_keyboard(user_id: Optional[int], r: Dict[str, Any]) -> "InlineKeyboardMarkup":
    rows = []
    if bridge_ok(r):
        for a in (r.get("agents") or []):
            if not isinstance(a, dict) or not valid_agent_id(str(a.get("id") or "")):
                continue
            aid = str(a.get("id"))
            rows.append([btn("%s %s" % (agent_icon(agent_state(a)), a.get("label") or aid), "ag_view~%s" % aid)])
        rows.append([btn(_t(user_id, "ag_btn_add"), "ag_add")])
        tr = r.get("transport") if isinstance(r.get("transport"), dict) else {}
        # По configured, а не по enabled: транспорт, которому негде слушать
        # (ушли из Pro в Lite), в конфиге всё ещё включён — и снять этот флаг
        # должно быть чем, иначе кнопки «выключить» просто не было бы.
        if transport_configured(tr):
            rows.append([btn(_t(user_id, "ag_btn_transport_off"), "ag_http~off")])
        else:
            rows.append([btn(_t(user_id, "ag_btn_transport_on"), "ag_http~on")])
    rows.append([btn(_t(user_id, "btn_refresh"), "se_agents")])
    rows.append(_back_row(user_id, "sec_settings"))
    return InlineKeyboardMarkup(rows)


async def cb_se_agents(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    r = await run_bot_action("agent-list")
    await safe_edit_message(query, agents_text(user_id, r), reply_markup=agents_keyboard(user_id, r))


def _agent_id_from_data(data: str, prefix: str) -> str:
    rest = data[len(prefix):] if data.startswith(prefix) else ""
    aid = rest.split("~", 1)[0]
    return aid if valid_agent_id(aid) else ""


def agent_storage_key(rec: Dict[str, Any]) -> str:
    """Ключ словаря для места хранения ключа переходника (agent-list.key_storage).
    До привязки хранить нечего — «ещё не привязан», а не пустое место."""
    storage = str(rec.get("key_storage") or "")
    if rec.get("enroll_pending") and rec.get("enroll_expired"):
        return "ag_storage_code_expired"
    if rec.get("enroll_pending") or storage not in ("tpm", "file"):
        return "ag_storage_pending"
    return "ag_storage_tpm" if storage == "tpm" else "ag_storage_file"


def agent_card_text(user_id: Optional[int], rec: Dict[str, Any]) -> str:
    st = agent_state(rec)
    lines = ["<b>%s</b>" % _tf(user_id, "ag_card_title_fmt", esc(rec.get("id")), esc(rec.get("label"))), ""]
    lines.append("%s <b>%s</b>" % (_t(user_id, "ag_card_scope"), esc(agent_level(user_id, rec.get("scope")))))
    # Вид доступа — сразу под уровнем: от него зависит и то, чем агент доказывает
    # право, и то, что произойдёт при копировании доступа на другую машину.
    connect = rec.get("mode") == "connect"
    # У переходника тот же одноразовый ключ, что у rolling, — и то же правило «один клиент»
    rolling = rec.get("mode") == "rolling" or connect
    if connect:
        mode_text = _t(user_id, "ag_card_mode_connect")
    else:
        mode_text = _t(user_id, "ag_card_mode_rolling" if rolling else "ag_card_mode_static")
    lines.append("%s %s" % (_t(user_id, "ag_card_mode"), mode_text))
    if connect:
        # Где ключ у переходника: в TPM копия файла бесполезна, файлом — копию заметим
        # по сожжённому ключу, но не предотвратим (MCP_ROTATION §4).
        lines.append("%s %s" % (_t(user_id, "ag_card_storage"), _t(user_id, agent_storage_key(rec))))
    lines.append("%s %s %s" % (_t(user_id, "ag_card_state"), agent_icon(st), _t(user_id, "ag_state_%s" % st)))
    if connect and rec.get("enroll_pending"):
        lines.append(_t(user_id, "ag_enroll_expired_note" if rec.get("enroll_expired") else "ag_enroll_pending_note"))
    expires = str(rec.get("expires") or "").strip()
    lines.append("%s %s" % (_t(user_id, "ag_card_expires"), esc(expires[:10]) if expires else _t(user_id, "never")))
    last = str(rec.get("last_used") or "").strip()
    if last:
        lines.append("%s %s %s" % (_t(user_id, "ag_card_last"), esc(last.replace("T", " ").rstrip("Z")) + " UTC",
                                    ("<code>%s</code>" % esc(rec.get("last_ip"))) if rec.get("last_ip") else ""))
    else:
        lines.append("%s —" % _t(user_id, "ag_card_last"))
    lines.append("%s %s" % (_t(user_id, "ag_card_calls"), esc(rec.get("calls") or 0)))
    # Второй фактор и привязка к адресу — в карточке, а не мелким шрифтом: это
    # ровно то, чем доступ отличается от «утёкшей ссылки, которой можно всё».
    if connect:
        # До привязки ключа ещё нет — есть код; «ключ у переходника» противоречило бы строке хранения
        token_key = "ag_token_connect_pending" if rec.get("enroll_pending") else "ag_token_connect"
        lines.append("%s 🔌 %s" % (_t(user_id, "ag_card_token"), _t(user_id, token_key)))
    elif rolling:
        lines.append("%s 🔁 %s" % (_t(user_id, "ag_card_token"), _t(user_id, "ag_token_rolling")))
    elif rec.get("require_token"):
        lines.append("%s ✅ %s" % (_t(user_id, "ag_card_token"), _t(user_id, "ag_token_on")))
    else:
        lines.append("%s ⚠️ %s" % (_t(user_id, "ag_card_token"), _t(user_id, "ag_token_off")))
    pinned = str(rec.get("pinned_ip") or "").strip()
    if not rec.get("pin_ip"):
        lines.append("%s %s" % (_t(user_id, "ag_card_pin"), _t(user_id, "ag_pin_state_off")))
    elif pinned:
        lines.append("%s <code>%s</code>" % (_t(user_id, "ag_card_pin"), esc(pinned)))
    else:
        lines.append("%s %s" % (_t(user_id, "ag_card_pin"), _t(user_id, "ag_pin_state_wait")))
    ips = rec.get("allow_ips") if isinstance(rec.get("allow_ips"), list) else []
    lines.append("%s %s" % (_t(user_id, "ag_card_ips"),
                            ("<code>%s</code>" % esc(", ".join(str(x) for x in ips))) if ips else _t(user_id, "ag_any_ip")))
    try:
        port = int(rec.get("port") or 0)
    except (TypeError, ValueError):
        port = 0
    if port:
        lines.append("%s <code>%s</code>" % (_t(user_id, "ag_card_port"), port))
    if rolling:
        lines.append("")
        lines.append("ℹ️ " + _t(user_id, "ag_one_client_warn"))
    elif not rec.get("require_token"):
        lines.append("")
        lines.append("⚠️ " + _t(user_id, "ag_weak_warn"))
    # Заморозка — не пометка, а требование решения: два времени и два адреса
    # ставятся рядом, чтобы владелец отличил кражу от восстановления машины из
    # старой копии и от двух клиентов на одном доступе (MCP_ROTATION §11.3).
    if rec.get("compromised"):
        lines.append("")
        lines.append("🚨 <b>%s</b>" % _t(user_id, "ag_card_frozen"))
        lines.append(_tf(user_id, "ag_frozen_when_fmt",
                         esc(str(rec.get("compromised_at") or "?")), esc(str(rec.get("compromised_ip") or "?"))))
        lines.append(_tf(user_id, "ag_frozen_last_fmt",
                         esc(str(rec.get("last_used") or "—")), esc(str(rec.get("last_ip") or "—"))))
        lines.append("")
        lines.append(_t(user_id, "ag_frozen_why"))
    return "\n".join(lines)


def agent_card_keyboard(user_id: Optional[int], rec: Dict[str, Any]) -> "InlineKeyboardMarkup":
    aid = str(rec.get("id"))
    # Замороженный доступ не впускает никого, и включать-выключать его бессмысленно:
    # решений ровно два — перевыпустить (новая цепочка) или отозвать совсем.
    if rec.get("compromised"):
        return InlineKeyboardMarkup([
            [btn(_t(user_id, "ag_btn_reissue"), "ag_rot~%s" % aid)],
            [btn(_t(user_id, "ag_btn_revoke"), "ag_del~%s" % aid)],
            _back_row(user_id, "se_agents"),
        ])
    if rec.get("enabled", True):
        toggle = btn(_t(user_id, "ag_btn_disable"), "ag_en~%s~off" % aid)
    else:
        toggle = btn(_t(user_id, "ag_btn_enable"), "ag_en~%s~on" % aid)
    # «Удалить» — отдельной строкой, как в карточке пользователя: соседство с
    # «Включить» превращало промах пальцем в потерю доступа.
    rows = [
        [btn(_t(user_id, "ag_btn_show_connect" if rec.get("mode") == "connect" else "ag_btn_show"), "ag_show~%s" % aid),
         btn(_t(user_id, "ag_btn_rotate"), "ag_rot~%s" % aid)],
    ]
    # «Выдать токен» показываем только слабому доступу: у остальных токен уже есть,
    # и кнопка была бы приглашением сломать рабочее подключение. У одноразового
    # ключа второй фактор — сам ключ, усиливать нечего.
    if not rec.get("require_token") and rec.get("mode") not in ("rolling", "connect"):
        rows.append([btn(_t(user_id, "ag_btn_harden"), "ag_hard~%s" % aid)])
    if rec.get("pin_ip"):
        rows.append([btn(_t(user_id, "ag_btn_pin_off"), "ag_pin~%s~off" % aid)])
    else:
        rows.append([btn(_t(user_id, "ag_btn_pin_on"), "ag_pin~%s~on" % aid)])
    # Продлить срок (L-10): адрес и токен не меняются — у истёкшего доступа это главный выход
    extend = [btn(_t(user_id, "ag_btn_extend"), "ag_ext~%s" % aid)]
    if agent_state(rec) == "expired":
        rows.insert(0, extend)
    else:
        rows.append(extend)
    rows.extend([
        [toggle],
        [btn(_t(user_id, "ag_btn_delete"), "ag_del~%s" % aid)],
        _back_row(user_id, "se_agents"),
    ])
    return InlineKeyboardMarkup(rows)


async def cb_agent_view(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    aid = _agent_id_from_data(query.data, "ag_view~")
    if not aid:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    r = await run_bot_action("agent-list")
    if not bridge_ok(r):
        await show_error(query, user_id, r, back_to="se_agents")
        return
    rec = next((a for a in (r.get("agents") or []) if isinstance(a, dict) and a.get("id") == aid), None)
    if rec is None:
        await safe_edit_message(query, "❌ " + _tf(user_id, "ag_not_found_fmt", esc(aid)), reply_markup=back_kb(user_id, "se_agents"))
        return
    await safe_edit_message(query, agent_card_text(user_id, rec), reply_markup=agent_card_keyboard(user_id, rec))


def agent_url_text(user_id: Optional[int], r: Dict[str, Any]) -> str:
    """Экран с адресом (ответ agent-add / agent-show / agent-rotate / agent-harden).

    Адрес и токен идут разными блоками, а «одной строкой для отправки» здесь нет
    вовсе: такая строка сама просится в пересылку, а именно пересылка и есть
    самый обыденный способ потерять доступ. Для настройки клиента показывается
    одна команда — с предупреждением, что это пароль, а не ссылка. Сообщение
    отправляется отдельным, чтобы его можно было удалить сразу после копирования.
    """
    url = str(r.get("url") or "")
    token = str(r.get("token") or "")
    connect = str(r.get("connect") or "").strip()
    # У доступа через переходник адреса нет — и заголовок не про адрес
    title_key = "ag_url_title_connect_fmt" if r.get("mode") == "connect" else "ag_url_title_fmt"
    lines = ["<b>%s</b>" % _tf(user_id, title_key, esc(r.get("id")), esc(r.get("label"))), ""]
    # У доступа через переходник неподвижного адреса нет — путь плавающий
    if url:
        lines.append("%s\n<code>%s</code>" % (_t(user_id, "ag_card_url"), esc(url)))
    if r.get("require_token") and token:
        lines.append("")
        lines.append("%s\n<code>%s</code>" % (_t(user_id, "ag_card_token"), esc(token)))
    # Одноразовый ключ показывается ровно один раз — сразу после выдачи или
    # перевыпуска; на сервере остаётся только отпечаток, повторить показ нечем.
    key = str(r.get("key") or "")
    if key:
        lines.append("")
        lines.append("%s\n<code>%s</code>" % (_t(user_id, "ag_card_key"), esc(key)))
        lines.append("<i>%s</i>" % esc(str(r.get("key_hint") or "")))
    # Код привязки переходника — тоже один раз: на сервере лежит только его отпечаток,
    # и живёт он 10 минут (MCP_ROTATION §7).
    code = str(r.get("enroll_code") or "")
    if code:
        lines.append("")
        lines.append("%s\n<code>%s</code>" % (_t(user_id, "ag_card_enroll_code"), esc(code)))
        lines.append("<i>%s</i>" % esc(str(r.get("enroll_hint") or "")))
    lines.append("")
    if connect:
        lines.append("%s\n%s" % (_t(user_id, "ag_url_cmd"), esc(connect)))
    # Пояснение («привязан», «код истёк») — не команда: подпись «Команда подключения» ему не положена
    note = str(r.get("connect_note") or "").strip()
    if note:
        lines.append("<i>%s</i>" % esc(note))
    connector_hint = str(r.get("connector_hint") or "").strip()
    if connector_hint:
        lines.append("")
        lines.append(esc(connector_hint))
    if r.get("mode") in ("rolling", "connect"):
        lines.append("")
        lines.append("ℹ️ " + _t(user_id, "ag_one_client_warn"))
    elif not r.get("require_token"):
        lines.append("")
        lines.append("⚠️ " + _t(user_id, "ag_weak_warn"))
    fp = str(r.get("cert_fingerprint_sha256") or "").strip()
    if fp:
        lines.append("")
        lines.append(_tf(user_id, "ag_url_selfsigned_fmt", esc(fp)))
    if r.get("transport_enabled") is False:
        lines.append("")
        lines.append("⚠️ " + _t(user_id, "ag_url_transport_off_connect" if r.get("mode") == "connect"
                                else "ag_url_transport_off"))
    # «Адрес — это ключ» не про переходник: адреса на экране нет, секреты живут у него
    if r.get("mode") != "connect":
        lines.append("")
        lines.append(_t(user_id, "ag_url_is_key"))
    return "\n".join(lines)


async def cb_agent_show(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    aid = _agent_id_from_data(query.data, "ag_show~")
    if not aid:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    r = await run_bot_action("agent-show", id=aid)
    if not bridge_ok(r):
        await show_error(query, user_id, r, back_to="ag_view~%s" % aid)
        return
    # Отдельным сообщением, а не правкой экрана: ключ должно быть можно удалить
    # из чата, не теряя само меню.
    await query.message.reply_text(agent_url_text(user_id, r), parse_mode="HTML",
                                   reply_markup=back_kb(user_id, "ag_view~%s" % aid),
                                   disable_web_page_preview=True)


async def cb_agent_rotate(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    aid = _agent_id_from_data(query.data, "ag_rot~")
    if not aid:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    # У доступа через переходник перевыпуск — новая привязка с кодом на 10 минут: об этом надо
    # сказать ДО нажатия, иначе владелец перевыпустит с телефона вдали от машины агента.
    r = await run_bot_action("agent-list")
    if not bridge_ok(r):
        # Без записи не узнать, переходник ли это: подтверждение со старым текстом выдало бы не то
        # предупреждение как раз тогда, когда что-то уже идёт не так.
        await show_error(query, user_id, r, back_to="ag_view~%s" % aid)
        return
    rec = next((a for a in (r.get("agents") or []) if isinstance(a, dict) and a.get("id") == aid), None)
    if rec is None:
        await safe_edit_message(query, "❌ " + _tf(user_id, "ag_not_found_fmt", esc(aid)),
                                reply_markup=back_kb(user_id, "se_agents"))
        return
    confirm_key = "ag_rotate_confirm_connect_fmt" if rec.get("mode") == "connect" else "ag_rotate_confirm_fmt"
    rows = [[btn(_t(user_id, "btn_confirm"), "ag_rot_do~%s" % aid)], [btn(_t(user_id, "btn_cancel"), "ag_view~%s" % aid)]]
    if await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "ag_btn_rotate"), _tf(user_id, confirm_key, esc(aid))),
                               reply_markup=InlineKeyboardMarkup(rows)):
        _rearm_callback(context, query, "ag_rot_do~")


@_once_callback
async def cb_agent_rotate_do(update: Update, context: ContextTypes.DEFAULT_TYPE, attempt) -> None:
    query = update.callback_query
    user_id = _uid(update)
    aid = _agent_id_from_data(query.data, "ag_rot_do~")
    if not aid:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    if await _action_busy(query, user_id, "ag_view~%s" % aid):
        return
    # Кнопка «Подтвердить» не должна пережить перевыпуск: экран вопроса оставался как
    # был, и повторное нажатие («ничего не произошло?») перевыпускало ещё раз — ключ из
    # только что присланного сообщения умирал, а у одноразового ключа его предъявление
    # сервер считает клоном и замораживает доступ.
    await safe_edit_message(query, "⏳ " + _t(user_id, "wait"), reply_markup=None)
    r = await _callback_mutate(attempt, "agent-rotate", who=user_id, id=aid)
    if not bridge_ok(r):
        await show_error(query, user_id, r, back_to="ag_view~%s" % aid)
        return
    await query.message.reply_text(agent_url_text(user_id, r), parse_mode="HTML",
                                   reply_markup=back_kb(user_id, "ag_view~%s" % aid),
                                   disable_web_page_preview=True)
    await safe_edit_message(query, "✅ " + _t(user_id, "ag_sent"), reply_markup=back_kb(user_id, "ag_view~%s" % aid))


async def cb_agent_harden(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """ag_hard~<id> — предупредить, что после выдачи токена одного адреса станет мало."""
    query = update.callback_query
    user_id = _uid(update)
    aid = _agent_id_from_data(query.data, "ag_hard~")
    if not aid:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    rows = [[btn(_t(user_id, "btn_confirm"), "ag_hard_do~%s" % aid)], [btn(_t(user_id, "btn_cancel"), "ag_view~%s" % aid)]]
    if await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "ag_btn_harden"), _tf(user_id, "ag_harden_confirm_fmt", esc(aid))),
                               reply_markup=InlineKeyboardMarkup(rows)):
        _rearm_callback(context, query, "ag_hard_do~")


@_once_callback
async def cb_agent_harden_do(update: Update, context: ContextTypes.DEFAULT_TYPE, attempt) -> None:
    query = update.callback_query
    user_id = _uid(update)
    aid = _agent_id_from_data(query.data, "ag_hard_do~")
    if not aid:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    if await _action_busy(query, user_id, "ag_view~%s" % aid):
        return
    await safe_edit_message(query, "⏳ " + _t(user_id, "wait"), reply_markup=None)   # см. cb_agent_rotate_do
    r = await _callback_mutate(attempt, "agent-harden", who=user_id, id=aid)
    if not bridge_ok(r):
        await show_error(query, user_id, r, back_to="ag_view~%s" % aid)
        return
    await query.message.reply_text(agent_url_text(user_id, r), parse_mode="HTML",
                                   reply_markup=back_kb(user_id, "ag_view~%s" % aid),
                                   disable_web_page_preview=True)
    await safe_edit_message(query, "✅ " + _t(user_id, "ag_sent"), reply_markup=back_kb(user_id, "ag_view~%s" % aid))


async def cb_agent_pin(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """ag_pin~<id>~on|off — привязка к адресу первого использования.

    Без подтверждения: обе стороны обратимы одной кнопкой, а «on» лишь просит
    сервер запомнить адрес следующего вызова.
    """
    query = update.callback_query
    user_id = _uid(update)
    parts = str(query.data).split("~")
    aid = parts[1] if len(parts) > 1 else ""
    want = parts[2] if len(parts) > 2 else ""
    if not valid_agent_id(aid) or want not in ("on", "off"):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    if await _action_busy(query, user_id, "ag_view~%s" % aid):
        return
    r = await mutate("agent-pin", who=user_id, id=aid, state=want)
    if not bridge_ok(r):
        await show_error(query, user_id, r, back_to="ag_view~%s" % aid)
        return
    await dispatch_callback_data(update, context, "ag_view~%s" % aid)


async def cb_agent_toggle(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """ag_en~<id>~on|off[~do] — включить/выключить доступ; сервер видит это следующим
    запросом. Сперва вопрос — обе стороны меняют права живого агента: «выключить»
    гасит работающего на следующем же вызове, «включить» возвращает управление
    сервером тому, у кого доступ уже был отобран. В SSH спрашивают обе."""
    query = update.callback_query
    user_id = _uid(update)
    parts = str(query.data).split("~")
    aid = parts[1] if len(parts) > 1 else ""
    arg = parts[2] if len(parts) > 2 else ""
    asked = arg.endswith("_do")
    want = arg[:-3] if asked else arg
    if not valid_agent_id(aid) or want not in ("on", "off"):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    if not asked:
        # Две явные строки, а не одна с двумя подстановками: оценка длины
        # callback_data (tests/check_menu.py) считает каждое свободное «%s» по
        # максимуму, и «ag_en~%s~%s» выходило за предел Telegram в 64 байта.
        if want == "on":
            go = btn(_t(user_id, "btn_confirm"), "ag_en~%s~on_do" % aid)
        else:
            go = btn(_t(user_id, "btn_confirm"), "ag_en~%s~off_do" % aid)
        rows = [[go], [btn(_t(user_id, "btn_cancel"), "ag_view~%s" % aid)]]
        await safe_edit_message(query, "<b>%s</b>\n\n%s" % (
            _t(user_id, "ag_btn_enable" if want == "on" else "ag_btn_disable"),
            _tf(user_id, "ag_toggle_on_confirm_fmt" if want == "on" else "ag_toggle_off_confirm_fmt", esc(aid))),
            reply_markup=InlineKeyboardMarkup(rows))
        return
    if await _action_busy(query, user_id, "ag_view~%s" % aid):
        return
    if want == "on":
        r = await mutate("agent-enable", who=user_id, id=aid)
    else:
        r = await mutate("agent-disable", who=user_id, id=aid)
    if not bridge_ok(r):
        await show_error(query, user_id, r, back_to="ag_view~%s" % aid)
        return
    await dispatch_callback_data(update, context, "ag_view~%s" % aid)


# Продление доступа агента (agent-extend, L-10; сцена agent-extend): адрес и токен не меняются, отсчёт —
# от текущего срока (от сегодня, если он уже прошёл). Сроки — как в дизайне, плюс «бессрочно», как в
# панели (agents-extend-forever): снять срок — ослабление, и ядро требует спросить о нём тем же
# вопросом, что при выдаче (agents_warn_forever), — поэтому у «бессрочно» отдельный экран-вопрос.
AGENT_EXTEND_DAYS = (30, 90)


async def cb_agent_extend(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """ag_ext~<id>: на сколько продлить; ag_ext~<id>~0 — вопрос перед «бессрочно»."""
    query = update.callback_query
    user_id = _uid(update)
    parts = str(query.data).split("~")
    aid = parts[1] if len(parts) in (2, 3) and valid_agent_id(parts[1]) else ""
    if not aid or (len(parts) == 3 and parts[2] != "0"):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    title = "<b>%s</b>" % _tf(user_id, "ag_extend_title_fmt", esc(aid))
    if len(parts) == 3:
        rows = [[btn(_t(user_id, "btn_confirm"), "ag_ext_do~%s~0" % aid)], _back_row(user_id, "ag_ext~%s" % aid)]
        await safe_edit_message(query, "%s\n\n⚠️ %s" % (title, _t(user_id, "ag_extend_forever_warn")),
                                reply_markup=InlineKeyboardMarkup(rows))
        return
    buttons = [btn(_days(user_id, d), "ag_ext_do~%s~%d" % (aid, d)) for d in AGENT_EXTEND_DAYS]
    rows = [buttons, [btn(_t(user_id, "ag_extend_forever_btn"), "ag_ext~%s~0" % aid)], _back_row(user_id, "ag_view~%s" % aid)]
    await safe_edit_message(query, "%s\n\n%s\n\n<i>%s</i>" % (title, _t(user_id, "ag_extend_ask"), _t(user_id, "ag_extend_sliding")),
                            reply_markup=InlineKeyboardMarkup(rows))


async def cb_agent_extend_do(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """ag_ext_do~<id>~<дни>: agent-extend --id --days (0 — снять срок)."""
    query = update.callback_query
    user_id = _uid(update)
    parts = str(query.data).split("~")
    if len(parts) != 3 or not valid_agent_id(parts[1]) or not (parts[2] == "0" or parts[2] in {str(d) for d in AGENT_EXTEND_DAYS}):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    aid, days = parts[1], int(parts[2])
    await query.answer()
    if await _action_busy(query, user_id, "ag_view~%s" % aid):
        return
    r = await mutate("agent-extend", who=user_id, id=aid, days=days)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "ag_view~%s" % aid)
        return
    expires = str(r.get("expires") or "").strip()
    if expires:
        text = "✅ " + _tf(user_id, "ag_extended_fmt", esc(expires[:10]))
    else:
        text = "✅ %s\n\n⚠️ %s" % (_t(user_id, "ag_extended_forever"), _t(user_id, "ag_forever_warn"))
    logger.info("agent %s extended: %s", aid, expires or "forever")
    await safe_edit_message(query, text, reply_markup=back_kb(user_id, "ag_view~%s" % aid))


async def cb_agent_delete(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Удаление — фразой `DELETE a-xxxx` в течение 60 секунд, как у пользователей."""
    query = update.callback_query
    user_id = _uid(update)
    aid = _agent_id_from_data(query.data, "ag_del~")
    if not aid:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    await arm_typed_confirm(query, context, user_id, "agent-del", aid, back_to="ag_view~%s" % aid,
                            warn=_tf(user_id, "ag_delete_warn_fmt", esc(aid)))


async def _apply_http_on(target, user_id: Optional[int], port: Optional[int], edit: bool) -> None:
    params: Dict[str, Any] = {}
    if port:
        params["port"] = port
    if not edit:
        await _queued_notice(target, user_id)
    r = await mutate("mcp-http-on", who=user_id, **params)
    if bridge_ok(r):
        text = "✅ " + _t(user_id, "ag_http_enabled") + "\n\n" + "\n".join(transport_lines(user_id, r))
    else:
        text = fail_text(user_id, r)
    markup = fail_markup(user_id, r, "se_agents", retry_data(target) if edit else None)
    if edit:
        await safe_edit_message(target, text, reply_markup=markup)
    else:
        await target.reply_text(text, parse_mode="HTML", reply_markup=markup, disable_web_page_preview=True)


async def cb_agent_http(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """ag_http~on|rnd|port|off|off_do — HTTP-транспорт MCP.

    В режимах с сайтом транспорт живёт за nginx на 443 — включается сразу. В Lite
    без сайта нужен отдельный TCP-порт: случайный (как у профилей) или свой.
    """
    query = update.callback_query
    user_id = _uid(update)
    arg = query.data.split("~", 1)[1] if "~" in query.data else ""
    if arg == "on":
        await query.answer()
        st = await run_bot_action("mcp-http-status")
        if bridge_ok(st) and str(st.get("mode") or "") == "lite":
            rows = [[btn(_t(user_id, "ag_btn_port_random"), "ag_http~rnd"), btn(_t(user_id, "ag_btn_port_custom"), "ag_http~port")],
                    [btn(_t(user_id, "btn_cancel"), "se_agents")]]
            await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "ag_btn_transport_on"), _t(user_id, "ag_http_on_lite")),
                                    reply_markup=InlineKeyboardMarkup(rows))
            return
        # В режимах с сайтом транспорт включается одной кнопкой — и открывает
        # серверу маршрут из интернета. SSH и панель об этом спрашивают; здесь
        # вопрос был единственным пропущенным.
        rows = [[btn(_t(user_id, "btn_confirm"), "ag_http~on_do")], [btn(_t(user_id, "btn_cancel"), "se_agents")]]
        await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "ag_btn_transport_on"),
                                                          _t(user_id, "ag_http_on_confirm")),
                                reply_markup=InlineKeyboardMarkup(rows))
    elif arg == "on_do":
        await query.answer()
        if await _action_busy(query, user_id, "se_agents"):
            return
        await _apply_http_on(query, user_id, None, edit=True)
    elif arg == "rnd":
        await query.answer()
        if await _action_busy(query, user_id, "se_agents"):
            return
        # Низкий диапазон, как у профилей и у SSH-меню: решение владельца —
        # предлагать порт ближе к трём-пяти тысячам, не выше десяти тысяч
        # (высокие номера у части провайдеров режутся блоком). Занятый порт
        # ядро отвергнет с внятным кодом, и человек назовёт свой.
        await _apply_http_on(query, user_id, random.randint(1024, 9999), edit=True)
    elif arg == "port":
        await query.answer()
        flow_set(context, "agent_port")
        await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "ag_btn_transport_on"), _t(user_id, "ag_ask_port")),
                                reply_markup=cancel_kb(user_id, "se_agents"))
    elif arg == "off":
        await query.answer()
        rows = [[btn(_t(user_id, "btn_confirm"), "ag_http~off_do")], [btn(_t(user_id, "btn_cancel"), "se_agents")]]
        await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "ag_btn_transport_off"), _t(user_id, "ag_http_off_confirm")),
                                reply_markup=InlineKeyboardMarkup(rows))
    elif arg == "off_do":
        await query.answer()
        if await _action_busy(query, user_id, "se_agents"):
            return
        r = await mutate("mcp-http-off", who=user_id)
        text = ("✅ " + _t(user_id, "ag_http_disabled")) if bridge_ok(r) else (fail_text(user_id, r))
        await safe_edit_message(query, text, reply_markup=fail_markup(user_id, r, "se_agents", retry_data(query)))
    else:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)


async def cb_agent_add(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Выдача доступа: название (текстом) → уровень (кнопки) → срок (кнопки) → адрес."""
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    flow_set(context, "agent_add", step="label")
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "ag_btn_add"), _t(user_id, "ag_ask_label")),
                            reply_markup=cancel_kb(user_id, "se_agents"))


async def _agent_add_text(update: Update, context, flow: Dict[str, Any], text: str) -> None:
    user_id = _uid(update)
    step = flow["data"].get("step")
    if step == "ips":
        ips = text.replace(" ", "")
        if not valid_ip_list(ips):
            # В тексте пример в <code> — без HTML человек видел теги буквально
            await update.message.reply_text(_t(user_id, "ag_bad_ips"), parse_mode="HTML")
            return
        flow["data"]["ips"] = ips
        flow["data"]["step"] = "mode"
        await _agent_add_ask_mode(update.message, user_id, edit=False)
        return
    if step != "label":
        await update.message.reply_text(_t(user_id, "text_no_waiter"))
        return
    if not valid_label(text):
        await update.message.reply_text(_t(user_id, "user_bad_label"), parse_mode="HTML")
        return
    flow["data"]["label"] = text
    flow["data"]["step"] = "scope"
    rows = [[btn(_t(user_id, "ag_scope_%s" % scope), "ag_scope~%s" % scope)] for scope in AGENT_SCOPES]
    rows.append([btn(_t(user_id, "btn_cancel"), "se_agents")])
    # Что именно получает уровень — рядом с кнопками, а не в документации: владелец,
    # выдающий доступ из бота, иначе раздаёт приватные ключи всех клиентов, не прочитав
    # об этом ни слова. Умолчание продукта — read, и здесь оно названо.
    await update.message.reply_text("<b>%s</b>\n\n%s\n\n%s" % (_t(user_id, "ag_btn_add"),
                                                                _t(user_id, "ag_ask_scope"),
                                                                _t(user_id, "ag_scope_note")),
                                    parse_mode="HTML", reply_markup=InlineKeyboardMarkup(rows))


async def cb_agent_add_scope(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    flow = flow_get(context)
    if not flow or flow.get("kind") != "agent_add":
        await query.answer(_t(user_id, "flow_expired"), show_alert=True)
        return
    scope = query.data.split("~", 1)[1] if "~" in query.data else ""
    if scope not in AGENT_SCOPES:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    flow["data"]["scope"] = scope
    flow["data"]["step"] = "days"
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "ag_btn_add"), _t(user_id, "ag_ask_days")),
                            reply_markup=_expiry_keyboard(user_id, "ag_days~", "se_agents"))


async def cb_agent_add_days(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Срок выбран → спрашиваем про привязку к адресу. Бессрочный вариант (0) —
    с предупреждением: он переживёт и утечку, о которой никто не узнал."""
    query = update.callback_query
    user_id = _uid(update)
    flow = flow_get(context)
    if not flow or flow.get("kind") != "agent_add":
        await query.answer(_t(user_id, "flow_expired"), show_alert=True)
        return
    value = query.data.split("~", 1)[1] if "~" in query.data else ""
    if not valid_int(value, MAX_DAYS):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    flow["data"]["days"] = int(value)
    flow["data"]["step"] = "pin"
    text = "<b>%s</b>\n\n%s" % (_t(user_id, "ag_btn_add"), _t(user_id, "ag_ask_pin"))
    if int(value) == 0:
        text += "\n\n⚠️ " + _t(user_id, "ag_forever_warn")
    rows = [[btn(_t(user_id, "ag_btn_pin_yes"), "ag_apin~on")], [btn(_t(user_id, "ag_btn_pin_no"), "ag_apin~off")],
            [btn(_t(user_id, "btn_cancel"), "se_agents")]]
    await safe_edit_message(query, text, reply_markup=InlineKeyboardMarkup(rows))


async def cb_agent_add_pin(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """ag_apin~on|off — привязка выбрана, остаётся вид доступа."""
    query = update.callback_query
    user_id = _uid(update)
    flow = flow_get(context)
    if not flow or flow.get("kind") != "agent_add":
        await query.answer(_t(user_id, "flow_expired"), show_alert=True)
        return
    pin = query.data.split("~", 1)[1] if "~" in query.data else ""
    if pin not in ("on", "off"):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    flow["data"]["pin"] = pin
    # Белый список адресов: карточка доступа его показывает, SSH и панель
    # спрашивают — а из бота задать его было нечем, и поле в карточке всегда
    # читалось «любые».
    flow["data"]["step"] = "ips"
    rows = [[btn(_t(user_id, "ag_btn_ips_any"), "ag_aips~any")],
            [btn(_t(user_id, "btn_cancel"), "se_agents")]]
    await safe_edit_message(query, "<b>%s</b>\n\n%s" % (_t(user_id, "ag_btn_add"), _t(user_id, "ag_ask_ips")),
                            reply_markup=InlineKeyboardMarkup(rows))


async def _agent_add_ask_mode(target, user_id: Optional[int], edit: bool) -> None:
    """Последний шаг мастера. Умолчание — static: одноразовый ключ обнаруживает
    кражу, но требует клиента, который сам хранит ключ, а обычный клиент MCP
    заголовок между запросами менять не умеет."""
    rows = [[btn(_t(user_id, "ag_btn_mode_static"), "ag_amode~static")],
            [btn(_t(user_id, "ag_btn_mode_rolling"), "ag_amode~rolling")],
            [btn(_t(user_id, "ag_btn_mode_connect"), "ag_amode~connect")],
            [btn(_t(user_id, "btn_cancel"), "se_agents")]]
    text = "<b>%s</b>\n\n%s\n\n<i>%s</i>" % (_t(user_id, "ag_btn_add"), _t(user_id, "ag_ask_mode"),
                                            _t(user_id, "ag_mode_note"))
    markup = InlineKeyboardMarkup(rows)
    if edit:
        await safe_edit_message(target, text, reply_markup=markup)
    else:
        await target.reply_text(text, parse_mode="HTML", reply_markup=markup)


async def cb_agent_add_ips_any(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """ag_aips~any — «принимать любые адреса»: список остаётся пустым."""
    query = update.callback_query
    user_id = _uid(update)
    flow = flow_get(context)
    if not flow or flow.get("kind") != "agent_add":
        # Ожидание истекло — возвращаем на экран доступов, а не оставляем в никуда
        await query.answer(_t(user_id, "flow_expired"), show_alert=True)
        await safe_edit_message(query, _t(user_id, "flow_expired"), reply_markup=back_kb(user_id, "se_agents"))
        return
    await query.answer()
    flow["data"]["ips"] = ""
    flow["data"]["step"] = "mode"
    await _agent_add_ask_mode(query, user_id, edit=True)


async def cb_agent_add_mode(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """ag_amode~static|rolling|connect — последний шаг мастера: выдаём доступ."""
    query = update.callback_query
    user_id = _uid(update)
    flow = flow_get(context)
    if not flow or flow.get("kind") != "agent_add":
        await query.answer(_t(user_id, "flow_expired"), show_alert=True)
        return
    mode = query.data.split("~", 1)[1] if "~" in query.data else ""
    if mode not in AGENT_MODES:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    data = dict(flow.get("data") or {})
    label = str(data.get("label") or "")
    scope = str(data.get("scope") or "")
    pin = str(data.get("pin") or "off")
    ips = str(data.get("ips") or "")
    days = data.get("days")
    if not valid_label(label) or scope not in AGENT_SCOPES or pin not in ("on", "off") \
            or not valid_ip_list(ips) or not isinstance(days, int):
        # Набранное негодно само по себе — повторять тот же шаг бессмысленно,
        # состояние снимаем и уводим на экран доступов.
        flow_clear(context)
        await safe_edit_message(query, "❌ " + _t(user_id, "err_bad_input"), reply_markup=back_kb(user_id, "se_agents"))
        return
    if await _action_busy(query, user_id, "se_agents"):
        return
    await safe_edit_message(query, "⏳ " + _t(user_id, "ag_adding"), reply_markup=None)
    # Пустой список не передаём вовсе: `--allow-ips=` мост читает как «указали
    # пусто», а это и есть «любые», — но лишний аргумент в аудите ни к чему.
    extra = {"allow_ips": ips} if ips else {}
    r = await mutate("agent-add", who=user_id, label=label, scope=scope, days=days, pin_ip=pin, mode=mode, **extra)
    if not bridge_ok(r):
        # Мост отказал (занят порт, нет места, спор за замок) — набранное НЕ теряем.
        # Раньше flow_clear стоял до вызова, и любой отказ последнего шага отправлял
        # владельца проходить мастер заново: название, уровень, срок, адреса. Теперь
        # состояние остаётся на шаге «режим», и повтор — это одна кнопка.
        flow["data"]["step"] = "mode"
        flow["since"] = time.monotonic()   # отсчёт ожидания — с этой минуты, а не с начала опроса
        # Причина — на месте «⏳ Выдаю доступ…», вопрос про режим — следующим
        # сообщением: так видно и отказ, и кнопку повтора.
        await safe_edit_message(query, fail_text(user_id, r), reply_markup=None)
        await _agent_add_ask_mode(query.message, user_id, edit=False)
        return
    flow_clear(context)
    # Адрес, токен и одноразовый ключ — отдельным сообщением, чтобы его можно было
    # удалить после копирования, не теряя само меню.
    await query.message.reply_text(agent_url_text(user_id, r), parse_mode="HTML",
                                   reply_markup=back_kb(user_id, "se_agents"),
                                   disable_web_page_preview=True)
    # «⏳ Выдаю доступ…» без кнопок иначе так и висел бы над выданным доступом.
    await safe_edit_message(query, "✅ " + _t(user_id, "ag_sent"), reply_markup=back_kb(user_id, "se_agents"))


def admins_text(user_id: Optional[int]) -> str:
    title = _t(user_id, "admins_title")
    own = owner_id()
    if ALLOWED_IDS:
        ids_list = "\n".join(
            "  • <code>%d</code>%s" % (uid, (" — " + _t(user_id, "admins_owner_mark")) if uid == own else "")
            for uid in admin_ids_ordered())
        text = "<b>%s</b>\n\n%s\n%s\n" % (title, _t(user_id, "admins_list"), ids_list)
    else:
        text = "<b>%s</b>\n\n<i>%s</i>\n" % (title, _t(user_id, "admins_empty"))
    text += "\n" + _tf(user_id, "admins_hint" if is_owner(user_id) else "admins_hint_member", len(ALLOWED_IDS))
    # Правило видно на экране, а не только по отсутствию кнопок: иначе
    # приглашённый решил бы, что бот сломался.
    text += "\n\n" + _t(user_id, "admins_owner_rule")
    return text


async def cb_se_admins(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    rows = []
    # Кнопки удаления видит только владелец: приглашённый не должен уметь
    # выкинуть ни владельца, ни другого приглашённого.
    if is_owner(user_id):
        for uid in admin_ids_ordered():
            if uid == user_id:
                continue   # себя не удаляем — иначе можно остаться без единого админа
            rows.append([btn(_tf(user_id, "admin_del_btn_fmt", uid), "se_admin_del~%d" % uid)])
    rows.append(_back_row(user_id, "sec_settings"))
    await safe_edit_message(query, admins_text(user_id), reply_markup=InlineKeyboardMarkup(rows))


async def cb_se_admin_del(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    raw = query.data.split("~", 1)[1] if "~" in query.data else ""
    if not valid_admin_id(raw):
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    target = int(raw)
    if target == user_id:
        await query.answer(_t(user_id, "admin_del_self"), show_alert=True)
        return
    # Проверка не только рисованием кнопок: callback_data приходит из чата, и
    # приглашённый мог бы прислать её руками.
    if not is_owner(user_id):
        await query.answer(_t(user_id, "admin_del_not_owner"), show_alert=True)
        return
    if is_owner(target):
        await query.answer(_t(user_id, "admin_del_owner"), show_alert=True)
        return
    await query.answer()
    if query.data.startswith("se_admin_del_ok~"):
        if target not in ALLOWED_IDS:
            await safe_edit_message(query, "❌ " + _tf(user_id, "admin_not_found_fmt", target), reply_markup=back_kb(user_id, "se_admins"))
            return
        saved = remove_admin(target)
        if getattr(context, "bot", None) is not None:
            await reset_menu_button(context.bot, target)
        text = "✅ " + _tf(user_id, "admin_removed_fmt", target)
        if not saved:
            text += "\n\n⚠️ " + _t(user_id, "admin_env_not_saved_del")
        await safe_edit_message(query, text, reply_markup=back_kb(user_id, "se_admins"))
        return
    rows = [[btn(_t(user_id, "btn_confirm"), "se_admin_del_ok~%d" % target)], _back_row(user_id, "se_admins")]
    await safe_edit_message(query, _tf(user_id, "admin_del_confirm_fmt", target), reply_markup=InlineKeyboardMarkup(rows))


async def cb_menu_lang(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    await safe_edit_message(query, lang_text(user_id), reply_markup=lang_keyboard(user_id, "sec_settings"))


# Подпись языка — на самом языке и одна на оба ряда кнопок («мой язык» и «язык
# продукта»): в словарь её выносить нечего, «Русский» и «English» одинаковы в
# ru.json и en.json, а флаг у языка один.
LANG_LABEL_RU = "🇷🇺 Русский"
LANG_LABEL_EN = "🇬🇧 English"


def lang_text(user_id: Optional[int]) -> str:
    """Два языка на одном экране: свой (только этот чат) и общий для продукта."""
    product = config_lang()
    lines = ["<b>%s</b>" % _t(user_id, "lang_title"), "",
             _tf(user_id, "lang_current", get_language_name(get_user_lang(user_id))),
             _t(user_id, "lang_choose"), "",
             _tf(user_id, "lang_product_current", get_language_name(product) if product else "—"),
             _t(user_id, "lang_product_hint")]
    return "\n".join(lines)


def lang_keyboard(user_id: Optional[int], back_to: str) -> "InlineKeyboardMarkup":
    # callback_data — литералами, а не "lang_set_%s" % code: tests/check_menu.py
    # читает исходник и обязан увидеть каждый маршрут целиком.
    return InlineKeyboardMarkup([
        [btn(LANG_LABEL_RU, "lang_set_ru"), btn(LANG_LABEL_EN, "lang_set_en")],
        [btn(_tf(user_id, "lang_product_btn_fmt", LANG_LABEL_RU), "lang_prod_ru"),
         btn(_tf(user_id, "lang_product_btn_fmt", LANG_LABEL_EN), "lang_prod_en")],
        _back_row(user_id, back_to),
    ])


async def cb_lang_set(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user_id = _uid(update)
    code = query.data.replace("lang_set_", "", 1)
    if code not in SUPPORTED_LANGS:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    set_user_lang(user_id, code)
    await query.answer(_tf(user_id, "lang_saved", get_language_name(code)))
    await render_main(query, user_id)


async def cb_lang_product(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """lang_prod_<код>: общий язык продукта — SSH-меню, панель, умолчание бота.

    Раньше это меняли только по SSH: человек, поставивший продукт с телефона,
    оставался с русским меню навсегда. Свой язык чата при этом не трогаем — он
    сильнее умолчания и живёт в user_langs.json.
    """
    query = update.callback_query
    user_id = _uid(update)
    code = str(query.data).replace("lang_prod_", "", 1)
    if code not in SUPPORTED_LANGS:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    if await _action_busy(query, user_id, "menu_lang"):
        return
    r = await mutate("lang-set", who=user_id, lang=code)
    if not bridge_ok(r):
        await show_error(query, user_id, r, "menu_lang")
        return
    await safe_edit_message(query, "✅ " + _tf(user_id, "lang_product_saved_fmt", get_language_name(code)),
                            reply_markup=back_kb(user_id, "menu_lang"))


async def cb_se_about(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    status = await get_status()
    lines = ["<b>%s</b>" % _t(user_id, "about_title"), ""]
    lines.append("%s: <code>v%s</code>" % (_t(user_id, "about_version"), esc(product_version(status))))
    if bridge_ok(status):
        lines.append("%s: <b>%s</b>" % (_t(user_id, "about_mode"), esc(mode_label(user_id, status.get("mode")))))
    lines.append("%s: AmneziaWG (amneziawg-go) + Docker" % _t(user_id, "about_engine"))
    lines.append("%s: 1.0 / 1.5 / 2.0 / 3.1" % _t(user_id, "about_lines"))
    lines.append("%s: MIT" % _t(user_id, "about_license"))
    # Руководство для человека, как в SSH «О программе», — а не пути внутренних файлов
    # репозитория (docs/CONTRACT.md и т. п.), которые на экране ни о чём не говорят (T30).
    lines.append("%s: %s" % (_t(user_id, "about_docs"), _t(user_id, "about_docs_url")))
    lines.append("")
    lines.append("<b>%s</b>" % _t(user_id, "credits_title"))
    lines.append("• Amnezia — %s" % _t(user_id, "credits_amnezia"))
    await safe_edit_message(query, "\n".join(lines), reply_markup=back_kb(user_id, "sec_settings"))


async def cb_se_wipe(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    user_id = _uid(update)
    # Путь — пунктами SSH-меню с их номерами («5 Настройки → 7 Удалить всё»), а не подписями
    # кнопок бота с эмодзи: в SSH «🧩 Настройки» нет, там цифры (T30).
    await safe_edit_message(query, "<b>%s</b>\n\n%s\n\n%s" % (
        _t(user_id, "se_wipe"), _t(user_id, "wipe_ssh_only"), _t(user_id, "wipe_ssh_path")),
        reply_markup=back_kb(user_id, "sec_settings"))


# ============================================================================
# КОМАНДЫ
# ============================================================================

async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_private_chat(update):
        return      # в группе и канале бот молчит: управление — только в личке
    user_id = _uid(update)
    if not is_user_allowed(user_id):
        # Чужому — один ответ в окне и вне его (в окне он ещё и кандидат для SSH); «/start КОД» —
        # так приходит ссылка t.me/<бот>?start=КОД из установщика без терминала
        await stranger_pairing_reply(update, " ".join(context.args or []))
        return
    # Ожидания снимаются только у своих: user_data чужих не заводим вовсе
    flow_clear(context)
    CONFIRM.cancel(int(user_id))
    await render_main(update.message, user_id, edit=False)


async def cmd_help(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not await require_auth(update, context):
        return
    user_id = _uid(update)
    flow_clear(context)
    # Строка про личный чат (DS2-33, L-11): в группах бот молчит по замыслу — пусть это не выглядит поломкой
    await update.message.reply_text("<b>%s</b>\n\n%s\n<i>%s</i>" % (_t(user_id, "help_title"), _t(user_id, "help_lines"),
                                                                 _t(user_id, "help_private_only")),
                                    parse_mode="HTML")


async def cmd_lang(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not await require_auth(update, context):
        return
    user_id = _uid(update)
    flow_clear(context)
    await update.message.reply_text(lang_text(user_id), reply_markup=lang_keyboard(user_id, "menu_main"), parse_mode="HTML")


async def cmd_status(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not await require_auth(update, context):
        return
    user_id = _uid(update)
    flow_clear(context)
    status = await get_status(fresh=True)
    if not bridge_ok(status):
        await update.message.reply_text("❌ " + error_text(user_id, status), parse_mode="HTML")
        return
    await update.message.reply_text(status_report_text(user_id, status), parse_mode="HTML",
                                    reply_markup=back_kb(user_id, "sec_state"))


async def cmd_users(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not await require_auth(update, context):
        return
    user_id = _uid(update)
    flow_clear(context)
    r, users = await fetch_users()
    if not bridge_ok(r):
        await update.message.reply_text(fail_text(user_id, r), parse_mode="HTML")
        return
    chunk, page, pages = paginate(users, 0, USERS_PER_PAGE)
    await update.message.reply_text(users_list_text(user_id, chunk, page, pages, len(users)), parse_mode="HTML",
                                    reply_markup=users_keyboard(user_id, users, 0))


async def cmd_adduser(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """/adduser <name> [gb] [days] — во все установленные профили."""
    if not await require_auth(update, context):
        return
    user_id = _uid(update)
    flow_clear(context)
    args = context.args or []
    if not args:
        await update.message.reply_text(_t(user_id, "cmd_adduser_usage"), parse_mode="HTML")
        return
    gb = args[1] if len(args) > 1 else "0"
    days = args[2] if len(args) > 2 else "0"
    if not valid_name(args[0]) or len(args) > 3 or not valid_int(gb, MAX_QUOTA_GB) or not valid_int(days, MAX_DAYS):
        # Аргументы есть, но не те (сцена cmd-adduser-bad): сказать, что не понял, и показать формат
        await update.message.reply_text(_t(user_id, "cmd_adduser_bad"), parse_mode="HTML")
        return
    await _queued_notice(update.message, user_id)
    await update.message.reply_text("⏳ " + _tf(user_id, "user_creating_fmt", esc(args[0])), parse_mode="HTML")
    r = await mutate("user-add", who=user_id, name=args[0], quota_gb=int(gb), days=int(days))
    if not bridge_ok(r):
        await update.message.reply_text(fail_text(user_id, r), parse_mode="HTML")
        return
    await update.message.reply_text(adduser_done_text(user_id, args[0], int(gb), int(days), r),
                                    parse_mode="HTML", reply_markup=InlineKeyboardMarkup([
                                        [btn(_t(user_id, "users_open_card"), "u_view~%s" % args[0])]]))


def adduser_done_text(user_id: Optional[int], name: str, gb: int, days: int, r: Dict[str, Any]) -> str:
    """Итог /adduser (сцена cmd-adduser): лимит, срок с датой и профили — из карточки в ответе ядра
    (result), без неё — из самих аргументов; где ключи — строкой ниже, как у мастера."""
    card = r.get("result") if isinstance(r.get("result"), dict) else {}
    quota = _t(user_id, "unlimited") if gb == 0 else "%d %s" % (gb, _t(user_id, "unit_gb"))
    expires = str(card.get("expires") or "")[:10]
    if days == 0:
        term = _t(user_id, "never")
    elif expires:
        term = _tf(user_id, "cmd_adduser_term_fmt", _days(user_id, days), esc(expires))
    else:
        term = _days(user_id, days)
    profiles = profile_names(user_id, card.get("profiles")) or "—"
    return "✅ %s\n%s" % (_tf(user_id, "cmd_adduser_done_fmt", esc(name), esc(quota), term, esc(profiles)),
                          _t(user_id, "user_added_hint"))


def key_usage_text(user_id: Optional[int]) -> str:
    """Подсказка к /key: пример с линией и профили списком «AmneziaWG 3.1 (3.1)» — в скобках то, что
    набирать (дизайн бота, NC-23). Служебных awg1/awg2/awg3 в подсказке нет, хотя команда их понимает."""
    profiles = ", ".join("%s (%s)" % (profile_line_name(user_id, p), profile_line(p)) for p in PROFILE_IDS)
    return _tf(user_id, "cmd_key_usage", esc(profiles))


async def cmd_key(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """/key <name> [профиль] — карточка пользователя с кнопками ключей. Профиль — линией («2.0»), как его
    называют экраны, или прежним id («awg2»)."""
    if not await require_auth(update, context):
        return
    user_id = _uid(update)
    flow_clear(context)
    args = context.args or []
    profile = ""
    if len(args) > 1 and valid_name(args[0]):
        arg = args[1].strip().lower()
        # Линии профилей — из status (кэш 15 с); прежний id разбирается и без него
        profile = arg if arg in PROFILE_IDS else profile_from_arg(arg, await get_status())
    if len(args) < 1 or not valid_name(args[0]) or (len(args) > 1 and not profile):
        await update.message.reply_text(key_usage_text(user_id), parse_mode="HTML")
        return
    name = args[0]
    r, user = await _fetch_user(name)
    if user is None:
        await update.message.reply_text("❌ " + (_tf(user_id, "cmd_key_no_user_fmt", esc(name))
                                                 if r.get("code") in ("user_not_found", "invalid_name") else error_text(user_id, r)),
                                        parse_mode="HTML")
        return
    peers = user.get("peers") if isinstance(user.get("peers"), dict) else {}
    # Без профиля в команде — первый, по которому ключ вообще выдаётся.
    profile = profile or next((p for p in PROFILE_IDS if p in peers and peer_has_key(peers.get(p))),
                              next((p for p in PROFILE_IDS if p in peers), ""))
    if not profile or not peers:
        await update.message.reply_text("❌ " + _t(user_id, "user_no_peers"), parse_mode="HTML")
        return
    if profile not in peers:
        # Просили профиль, на котором у человека ключа нет: не «профилей нет вовсе», а где они есть
        await update.message.reply_text("❌ " + _tf(user_id, "cmd_key_no_profile_fmt", esc(name),
                                                    esc(profile_name(user_id, profile)),
                                                    esc(profile_names(user_id, list(peers)))),
                                        parse_mode="HTML")
        return
    if not peer_has_key(peers.get(profile)):
        # Ключ выдан в приложении Amnezia: у сервера только открытая часть, и все
        # четыре кнопки выдачи гарантированно ответили бы no_private_key. Карточка
        # ставит на такой профиль «Привязать старый ключ» и «Перевыпустить» — здесь то же самое.
        text, markup = imported_view(user_id, name, [profile], command=True)
        await update.message.reply_text(text, parse_mode="HTML", reply_markup=markup)
        return
    rows = [
        [btn(_t(user_id, "key_btn_qr_conf"), "u_key~%s~%s~qrconf" % (name, profile)),
         btn(_t(user_id, "key_btn_conf_file"), "u_key~%s~%s~conf" % (name, profile))],
        [btn(_t(user_id, "key_btn_vpn"), "u_key~%s~%s~vpn" % (name, profile)),
         btn(_t(user_id, "key_btn_qr_vpn"), "u_key~%s~%s~qrvpn" % (name, profile))],
        [btn(_t(user_id, "users_open_card"), "u_view~%s" % name)],
    ]
    await update.message.reply_text("<b>%s</b>\n\n%s" % (_tf(user_id, "key_title_fmt", esc(name), esc(profile_name(user_id, profile))),
                                                         _t(user_id, "key_pick_style")),
                                    parse_mode="HTML", reply_markup=InlineKeyboardMarkup(rows))


async def cmd_invite(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """/invite <id> — добавить админа (ID узнать у @userinfobot). Только владелец (решение владельца 27.09, L-25):
    приглашённый админ не раздаёт доступ дальше — украденный аккаунт не станет цепочкой новых админов."""
    if not await require_auth(update, context):
        return
    user_id = _uid(update)
    flow_clear(context)
    if not is_owner(user_id):
        await update.message.reply_text("⛔ " + _t(user_id, "admin_invite_owner_only"), parse_mode="HTML")
        return
    args = [a.strip().replace(",", "") for a in (context.args or []) if a.strip()]
    if not args:
        await update.message.reply_text(_t(user_id, "cmd_invite_usage"), parse_mode="HTML")
        return
    added, bad, save_failed = [], [], False
    for a in args:
        if not valid_admin_id(a):
            bad.append(a)
            continue
        if not add_admin(int(a)):
            save_failed = True
        added.append(a)
    parts = []
    if added and save_failed:
        parts.append("⚠️ " + _tf(user_id, "admin_added_unsaved_fmt", esc(", ".join(added))))
    elif added:
        parts.append("✅ " + _tf(user_id, "admin_added_fmt", esc(", ".join(added))))
    if bad:
        parts.append("❌ " + _tf(user_id, "admin_bad_ids_fmt", esc(", ".join(bad))))
    await update.message.reply_text("\n".join(parts), parse_mode="HTML")
    # Кнопка меню «🚀 Панель» ставится каждому админу отдельно — новому сразу, как при привязке сообщением
    # (pairing_greet), а не после перезапуска бота (живая проверка на test1, 03.10)
    if added:
        await refresh_menu_button_after(context)


# ============================================================================
# ТЕКСТ: ожидания ввода и typed-confirm
# ============================================================================

async def handle_text_message(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.message is None or update.message.text is None:
        return
    if not is_private_chat(update):
        return      # фраза подтверждения или ключ, набранные в группе, не значат ничего
    user_id = _uid(update)
    if not is_user_allowed(user_id):
        # Чужому — один ответ в окне и вне его; в окне он ещё и кандидат для SSH (или одноразовый
        # код, пока админа нет)
        await stranger_pairing_reply(update, update.message.text)
        return
    text = update.message.text.strip()

    # 0. Ключ (ссылка vpn:// или текст .conf), который сейчас не ждут: ожидание «Привязать
    # старый ключ» истекло, кнопку не нажимали или открыт другой шаг. Мост его не увидит —
    # значит и в истории чата рабочему приватному ключу не место (UI-1).
    pending = flow_get(context)
    if looks_like_key(text) and not (pending and pending.get("kind") == "peer_attach"):
        removed = await _drop_key_message(update.message, user_id)
        await update.message.reply_text("%s\n\n%s" % (_t(user_id, "user_peer_attach_unexpected"), removed))
        return

    # 1. Фраза подтверждения — раньше всего: экран удаления ждёт именно её.
    verdict, rec = CONFIRM.check(int(user_id), text)
    if verdict == "ok" and rec is not None:
        flow_clear(context)
        await drop_confirm_buttons(context, rec)
        await run_typed_confirm(update, context, rec)
        return
    if verdict == "mismatch" and rec is not None:
        key = "confirm_mismatch_port_fmt" if str(rec["phrase"]).isdigit() else "confirm_mismatch_fmt"
        await update.message.reply_text(_tf(user_id, key, esc(rec["phrase"])), parse_mode="HTML")
        return
    if verdict == "expired":
        await update.message.reply_text(_t(user_id, "confirm_expired"))
        return

    # 2. Ожидание ввода (просроченное забывается в flow_get — и один раз говорим, что время вышло)
    flow = flow_get(context)
    if not flow:
        if context.user_data.pop("flow_expired", False):
            await update.message.reply_text(_tf(user_id, "flow_expired_msg_fmt", FLOW_TTL // 60))
        else:
            await update.message.reply_text(_t(user_id, "text_no_waiter"))
        return
    kind = flow.get("kind")
    data = flow.get("data") or {}
    # ВАЖНО: ожидание снимается ТОЛЬКО после успешной обработки: ввод с
    # ошибкой оставляет экран ждать правильное значение, а не «зависает».
    if kind == "user_add":
        await _user_add_text(update, context, flow, text)
    elif kind == "user_bulk":
        await _user_bulk_text(update, context, flow, text)
    elif kind == "user_bulk_del":
        await _user_bulk_del_text(update, context, flow, text)
    elif kind == "user_quota":
        gb = parse_quota_gb(text)
        if gb is None:
            await update.message.reply_text(_tf(user_id, "user_bad_quota_fmt", MAX_QUOTA_GB))
            return
        flow_clear(context)
        await _apply_user_quota(update.message, user_id, str(data.get("name")), gb, edit=False)
    elif kind == "user_expiry":
        days = parse_expiry_days(text)
        if days is None:
            await update.message.reply_text(_tf(user_id, "user_bad_days_fmt", MAX_DAYS))
            return
        flow_clear(context)
        await _apply_user_expiry(update.message, user_id, str(data.get("name")), days, edit=False)
    elif kind == "user_rename":
        if not valid_label(text):
            await update.message.reply_text(_t(user_id, "user_bad_label"))
            return
        name = str(data.get("name"))
        flow_clear(context)
        await _queued_notice(update.message, user_id)
        r = await mutate("user-rename", who=user_id, name=name, label=text)
        msg = ("✅ " + _tf(user_id, "user_renamed_fmt", esc(name), esc(text))) if bridge_ok(r) else (fail_text(user_id, r))
        await update.message.reply_text(msg, parse_mode="HTML", reply_markup=back_kb(user_id, "u_view~%s" % name))
    elif kind == "profile_port":
        if not valid_port(text):
            await update.message.reply_text(_t(user_id, "pr_bad_port"))
            return
        # «0443» — это 443 для человека и для jq, но 291 для арифметики bash и строка
        # «0443» в Endpoint ключа: номер уходит мосту только в каноническом виде.
        text = str(int(text))
        profile = str(data.get("profile"))
        flow_clear(context)
        # Порт стоит в Endpoint каждого выданного ключа: после смены ни один старый
        # конфиг не подключится, пока человек не заберёт новый. SSH об этом
        # спрашивает — спрашиваем и здесь, уже зная номер.
        rows = [[btn(_t(user_id, "btn_confirm"), "pr_port_do~%s~%s" % (profile, text))],
                [btn(_t(user_id, "btn_cancel"), "pr_card~%s" % profile)]]
        note443 = port443_mode_note(user_id, await get_status(), text) if text == "443" else ""
        await update.message.reply_text(
            "<b>%s</b>\n\n%s\n\n%s%s" % (_tf(user_id, "pr_port_title_fmt", esc(profile_name(user_id, profile))),
                                         _tf(user_id, "pr_port_confirm_fmt", esc(profile_name(user_id, profile)), esc(text)),
                                         _t(user_id, "pr_port_note"), note443),
            parse_mode="HTML", reply_markup=InlineKeyboardMarkup(rows))
    elif kind == "profile_install_port":
        if not valid_port(text):
            await update.message.reply_text(_t(user_id, "pr_bad_port"))
            return
        text = str(int(text))   # без ведущих нулей — см. profile_port
        profile = str(data.get("profile"))
        flow_clear(context)
        rows = [[btn(_t(user_id, "btn_confirm"), "pr_inst_do~%s~%s" % (profile, text))],
                [btn(_t(user_id, "btn_cancel"), "pr_install~%s" % profile)]]
        note443 = port443_mode_note(user_id, await get_status(), text) if text == "443" else ""
        await update.message.reply_text(
            "<b>%s</b>\n\n%s%s" % (_tf(user_id, "pr_install_title_fmt", esc(profile_line_name(user_id, profile))),
                                    _tf(user_id, "pr_install_port_confirm_fmt", esc(profile_name(user_id, profile)), esc(text)), note443),
            parse_mode="HTML", reply_markup=InlineKeyboardMarkup(rows))
    elif kind == "profile_subnet":
        if not valid_subnet(text):
            await update.message.reply_text(_t(user_id, "pr_bad_subnet"))
            return
        data["subnet"] = text
        profile = str(data.get("profile"))
        rows = [[btn(_t(user_id, "btn_confirm"), "pr_subnet_ok")], [btn(_t(user_id, "btn_cancel"), "pr_card~%s" % profile)]]
        await update.message.reply_text("⚠️ %s\n\n%s" % (_t(user_id, "pr_subnet_warn"), _tf(user_id, "pr_ask_subnet_confirm_fmt", esc(text))),
                                        parse_mode="HTML", reply_markup=InlineKeyboardMarkup(rows))
    elif kind == "profile_mtu":
        if mtu_too_low(text):
            await update.message.reply_text("❌ " + _t(user_id, "pr_mtu_low"))
            return
        if not valid_mtu(text):
            await update.message.reply_text(_t(user_id, "pr_bad_mtu"))
            return
        profile = str(data.get("profile"))
        flow_clear(context)
        await _apply_profile_mtu(update.message, user_id, profile, text, edit=False)
    elif kind == "profile_param":
        if not valid_param_value(text):
            await update.message.reply_text(_t(user_id, "pr_bad_param_value"))
            return
        await _param_confirm_or_apply(update.message, context, user_id, flow, text, edit=False)
    elif kind == "dns_custom":
        parts = [p for p in re.split(r"[,\s]+", text) if p]
        # Образец `dns` из actions.json строже valid_ipv4: «010.0.0.1» бот принимал, а мост
        # отвечал bad_arg — ошибкой уже после ввода. Проверяем тем же образцом, что мост.
        if not parts or len(parts) > 2 or not all(valid_dns(p) for p in parts):
            await update.message.reply_text(_t(user_id, "dns_bad"))
            return
        flow_clear(context)
        await _apply_dns(update.message, user_id, parts[0], parts[1] if len(parts) > 1 else "", edit=False)
    elif kind == "endpoint":
        host = text.lower()
        if not valid_host(host):
            await update.message.reply_text(_t(user_id, "se_endpoint_bad"))
            return
        flow_clear(context)
        await _apply_endpoint(update.message, user_id, host, edit=False)
    elif kind == "mode_domain":
        # Домен для Pro: та же проверка, что у endpoint — строчные, точка внутри.
        host = text.lower()
        if not host or not valid_host(host) or IPV4_RE.match(host):
            await update.message.reply_text(_t(user_id, "se_mode_bad_domain"), parse_mode="HTML")
            return
        mode = str(data.get("mode") or "pro")
        if not valid_mode(mode):
            flow_clear(context)
            await update.message.reply_text("❌ " + _t(user_id, "err_bad_input"),
                                            reply_markup=back_kb(user_id, "se_mode"))
            return
        await _arm_mode_confirm(update.message, context, user_id, mode, host, edit=False,
                                current=str(data.get("current") or "lite"), line=str(data.get("line") or ""))
    elif kind == "lazy_domain":
        # Ленивый Pro, шаг 1 → 2: домен (https://, путь и кириллицу разбирает lazy_domain_input) → lazy-check
        domain, display, err = lazy_domain_input(text)
        if err:
            await update.message.reply_text(_t(user_id, err), parse_mode="HTML")
            return
        flow_clear(context)
        await _lazy_check(update.message, context, user_id, domain, edit=False, display=display)
    elif kind == "tpl_search":
        # Слово живёт в user_data, а не во flow: листалка результатов приходит
        # кнопками, а любая кнопка снимает ожидание ввода.
        word = text.strip()
        if len(word) < 2 or len(word) > 48:
            await update.message.reply_text(_t(user_id, "tpl_search_bad"))
            return
        flow_clear(context)
        context.user_data["tpl_query"] = word
        await _tpl_search_page(update.message, context, user_id, word, 0, edit=False)
    elif kind == "page_ttl":
        ttl = parse_page_ttl(text)
        if not ttl:
            await update.message.reply_text(_t(user_id, "pg_bad_ttl"))
            return
        name = str(data.get("name"))
        flow_clear(context)
        await _page_create(update.message, user_id, name, ttl, edit=False)
    elif kind == "agent_add":
        await _agent_add_text(update, context, flow, text)
    elif kind == "agent_port":
        if not valid_agent_port(text):
            await update.message.reply_text(_t(user_id, "ag_bad_port"))
            return
        flow_clear(context)
        await _apply_http_on(update.message, user_id, int(text), edit=False)
    elif kind == "peer_attach":
        # Ссылка vpn:// или текст .conf старого ключа; файлом — handle_file_message
        await _peer_attach_submit(update.message, context, user_id, flow, text)
    else:
        flow_clear(context)
        await update.message.reply_text(_t(user_id, "text_no_waiter"))


# ============================================================================
# РОУТЕР КНОПОК
# ============================================================================
# Кнопки под уведомлениями — с этой приставкой: экран открывается новым сообщением (cb_from_notice)
NOTICE_PREFIX = "nt~"


async def cb_notice_later(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """nt_later — «Позже» под уведомлением: убрать кнопки, текст уведомления остаётся. Строка на главном экране
    (dupline_fix) никуда не девается — исправить можно и оттуда."""
    query = update.callback_query
    await query.answer()
    try:
        await query.edit_message_reply_markup(reply_markup=None)
    except Exception as e:  # noqa: BLE001 — сообщение могло быть уже изменено или удалено
        logger.debug("notice later: %s", e)


async def cb_from_notice(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """nt~<callback экрана>: открыть экран новым сообщением под уведомлением, не трогая само уведомление."""
    query = update.callback_query
    user_id = _uid(update)
    inner = query.data[len(NOTICE_PREFIX):] if query.data.startswith(NOTICE_PREFIX) else ""
    handler = resolve_handler(inner) if inner and not inner.startswith(NOTICE_PREFIX) else None
    if handler is None:
        await query.answer(_t(user_id, "err_bad_input"), show_alert=True)
        return
    await query.answer()
    screen = await query.message.reply_text("⏳ " + _t(user_id, "wait"))
    await _dispatch_as_new_message(update, context, handler, inner, screen)


async def _dispatch_as_new_message(update, context, handler, data: str, screen) -> None:
    await handler(_UpdateProxy(update, _NewMessageQuery(update.callback_query, data, screen)), context)


# Точные совпадения и префиксы — две таблицы, которые tests/check_menu.py
# читает статически: каждая callback_data в bot.py обязана найтись здесь.
EXACT_HANDLERS: Dict[str, Callable] = {
    "menu_main": cb_menu_main,
    "close_menu": cb_close_menu,
    "nt_later": cb_notice_later,
    "menu_install": cb_menu_install,
    "menu_users": cb_menu_users,
    "u_add": cb_user_add,
    "ua_done": cb_user_add_done,
    "ua_back": cb_user_add_back,
    "ua_rnd": cb_user_add_suggest,
    "u_addm": cb_user_bulk,
    "u_delm": cb_user_bulk_del,
    "ub_done": cb_user_bulk_done,
    "ub_back": cb_user_bulk_back,
    "ub_names": cb_user_bulk_names,
    "sec_state": cb_sec_state,
    "st_status": cb_st_status,
    "st_traffic": cb_st_traffic,
    "st_logs": cb_st_logs,
    "st_addr": cb_st_addr,
    "sec_protocols": cb_sec_protocols,
    "pr_subnet_ok": cb_pr_subnet_ok,
    "pr_punset": cb_pr_param_unset,
    "pr_pok": cb_pr_param_ok,
    "sec_maint": cb_sec_maint,
    "mt_restart_all": cb_mt_restart_all,
    "mt_restart_all_do": cb_mt_restart_all_do,
    "mt_backup": cb_mt_backup,
    "mt_restore": cb_mt_restore,
    "mt_upstream": cb_mt_upstream,
    "mt_import": cb_mt_import,
    "mt_diag": cb_mt_diag,
    "mt_dkr": cb_mt_dkr,
    "mt_dkr_do": cb_mt_dkr_do,
    # Ускорение AmneziaWG (модуль ядра): экран, «Включить» (проверка и согласие), «Нет», вопросы трёх остальных
    "mt_kmod": cb_mt_kmod,
    "km_on": cb_km_on,
    "km_no": cb_km_no,
    "km_prog": cb_km_prog,
    "km_rb": cb_km_rb,
    "km_rm": cb_km_rm,
    "mt_selfupdate": cb_mt_selfupdate,
    "sh_list": cb_share_list,
    "sh_revall": cb_share_revoke_all,
    "sh_revall_do": cb_share_revoke_all,
    "sec_settings": cb_sec_settings,
    "se_mode": cb_se_mode,
    "se_mode_pick": cb_se_mode_pick,
    "se_lazy": cb_se_lazy,
    "se_lazy_re": cb_se_lazy_re,
    "se_lazy_go": cb_se_lazy_go,
    "se_pline": cb_se_pline,
    "se_tpl": cb_se_tpl,
    "se_tplq": cb_se_tpl_search,
    "se_tplr": cb_se_tpl_random,
    "se_check": cb_se_site_check,
    "se_alt": cb_se_alt_svc,
    "se_pf": cb_se_preflight,
    "se_dns": cb_se_dns,
    "se_dns_custom": cb_se_dns_custom,
    "se_endpoint": cb_se_endpoint,
    "se_endpoint_ip": cb_se_endpoint_ip,
    "se_endpoint_auto": cb_se_endpoint_auto,
    "se_panel": cb_se_panel,
    "se_agents": cb_se_agents,
    "ag_add": cb_agent_add,
    "se_mirror": cb_se_mirror,
    # Баны коротких ссылок из тревоги о подборе (nt~shl_bans): «Назад» — на главный
    "shl_bans": cb_short_bans,
    "mr_fetch": cb_mirror_fetch,
    "se_admins": cb_se_admins,
    "menu_lang": cb_menu_lang,
    "se_about": cb_se_about,
    "se_wipe": cb_se_wipe,
    "admin_cancel": cb_admin_cancel,
    "admin_again": cb_admin_again,
}

PREFIX_HANDLERS: List[Tuple[str, Callable]] = [
    ("admin_confirm_", cb_admin_confirm),
    ("inst_awg2~", cb_install_awg2),
    ("menu_users~", cb_menu_users),
    ("u_view~", cb_user_view),
    ("u_key~", cb_user_key),
    # «Ключ на другой адрес»: выбор адреса → профиль и вид ключа → выдача (u_ka~ — тот же
    # cb_user_key с пятой частью, кодом адреса); файл по ссылке — u_shf~/u_shdo~ с той же пятой частью
    ("u_kaddr~", cb_user_key_addr),
    ("u_kah~", cb_user_key_addr_formats),
    ("u_ka~", cb_user_key),
    # Свой адрес сервера за человеком (user-set-address): экран адресов → закрепить или вернуть общий
    ("u_pin_set~", cb_user_pin_set),
    ("u_pin~", cb_user_pin),
    ("ua_tog~", cb_user_add_toggle),
    ("ua_take~", cb_user_add_take),
    ("ua_q~", cb_user_add_quota),
    ("ua_d~", cb_user_add_days),
    ("ub_n~", cb_user_bulk_count),
    ("ub_nm~", cb_user_bulk_names_pick),
    ("ub_tog~", cb_user_bulk_toggle),
    ("ud_how~", cb_user_bulk_del_how),
    ("ud_pfx~", cb_user_bulk_del_prefix),
    # Кнопки под уведомлениями: экран — новым сообщением, уведомление остаётся (BOT-5)
    ("nt~", cb_from_notice),
    # Ускорение AmneziaWG: согласие дано — km_go~enable~off|on, km_go~program, km_go~rebuild, km_go~remove
    ("km_go~", cb_km_go),
    ("u_quota~", cb_user_quota),
    ("uq_set~", cb_user_quota_set),
    ("u_exp~", cb_user_expiry),
    ("ue_set~", cb_user_expiry_set),
    ("u_en~", cb_user_toggle),
    ("u_ren~", cb_user_rename),
    ("u_addp_do~", cb_user_add_profile_do),
    ("u_addp~", cb_user_add_profile),
    ("u_delp_ask~", cb_user_del_profile_ask),
    ("u_delp_do~", cb_user_del_profile_do),
    ("u_delp~", cb_user_del_profile),
    ("u_reis_do~", cb_user_peer_reissue_do),
    ("u_reis~", cb_user_peer_reissue),
    ("u_att~", cb_user_peer_attach),
    ("u_shdo~", cb_user_share_do),
    ("u_shf~", cb_user_share_format),
    ("u_share~", cb_user_share),
    ("sh_rev~", cb_share_revoke),
    ("u_page~", cb_user_page),
    ("pg_ttl~", cb_page_ttl),
    ("pg_list~", cb_page_list),
    ("pg_card~", cb_page_card),
    ("pg_url~", cb_page_url),
    ("pg_rev_dosk~", cb_page_revoke),
    ("pg_rev_dok~", cb_page_revoke),
    ("pg_rev_dos~", cb_page_revoke),
    ("pg_rev_do~", cb_page_revoke),
    ("pg_rev~", cb_page_revoke),
    ("pg_revall_do~", cb_page_revoke_all),
    ("pg_revall~", cb_page_revoke_all),
    ("u_sub~", cb_user_sub),
    ("sub_new~", cb_sub_new),
    ("sub_show~", cb_sub_show),
    # Выбор по клиенту: sub_cl~<имя>~<id записи> — экран приложения; sbq~ / sbc~<имя>~<id>~<пункт> — QR и то, что
    # вставляют
    ("sub_cl~", cb_sub_client),
    ("sbq~", cb_sub_qr),
    ("sbc~", cb_sub_copy),
    # Короткая ссылка: sbs~ — показать (<имя>~<id>~<пункт> у приложения или <имя>~<суффикс> из списка), sbr~<имя>~<суффикс>
    # — «↻ Заменить»; sc~<запрос>~<NN|deny|swap> — ответ на запрос подтверждения; shl_list~ — короткие ссылки подписки;
    # shl_bans~ — баны и заморозки, shl_ub~ — снять
    ("sbs~", cb_short_show),
    ("sbr~", cb_short_replace),
    ("sc~", cb_short_decide),
    ("shl_list~", cb_short_list),
    ("shl_bans~", cb_short_bans),
    ("shl_ub~", cb_short_unban),
    ("sub_rot~", cb_sub_rotate),
    ("sub_rev~", cb_sub_revoke),
    ("mr_app~", cb_mirror_app),
    ("mr_fetch~", cb_mirror_fetch_do),
    ("mr_del_do~", cb_mirror_remove),
    ("mr_del~", cb_mirror_remove),
    ("u_del~", cb_user_delete),
    ("tc_cancel~", cb_typed_cancel),
    ("up_upd~", cb_up_update),
    ("up_fix~", cb_up_repair),
    ("up_rb~", cb_up_rollback),
    ("imp_adopt_do~", cb_imp_adopt_do),
    ("imp_adopt~", cb_imp_adopt),
    ("imp_rec_do~", cb_imp_rec_do),
    ("imp_rec~", cb_imp_rec),
    ("st_log~", cb_st_log),
    ("pr_card~", cb_pr_card),
    ("pr_inst_do~", cb_pr_install_do),
    ("pr_inst_port~", cb_pr_install_port),
    ("pr_install~", cb_pr_install),
    ("pr_remove~", cb_pr_remove),
    ("pr_port_do~", cb_pr_port_do),
    ("pr_port~", cb_pr_port),
    ("pr_443_do~", cb_pr_443_do),
    ("pr_443~", cb_pr_443),
    ("pr_subnet~", cb_pr_subnet),
    ("pr_smv_do~", cb_pr_subnet_move_do),
    ("pr_smv~", cb_pr_subnet_move),
    ("pr_mtu_set~", cb_pr_mtu_set),
    ("pr_mtu_ok~", cb_pr_mtu_set),
    ("pr_mtu~", cb_pr_mtu),
    ("pr_params~", cb_pr_params),
    ("pr_pedit~", cb_pr_param_edit),
    ("pr_pkey~", cb_pr_param_key),
    ("pr_preset_do~", cb_pr_preset_do),
    ("pr_preset~", cb_pr_preset),
    ("pr_regen~", cb_pr_regen),
    ("pr_restart_do~", cb_pr_restart_do),
    ("pr_restart~", cb_pr_restart),
    ("pr_fix_do~", cb_pr_repair_do),
    ("pr_fix~", cb_pr_repair),
    ("pr_s4_do~", cb_pr_s4_do),
    ("pr_rlk~", cb_pr_reline_keys),
    ("pr_rl~", cb_pr_reline),
    ("pr_s4~", cb_pr_s4),
    ("mt_rs~", cb_mt_restore_pick),
    ("se_dns_set~", cb_se_dns_set),
    ("ag_view~", cb_agent_view),
    ("ag_show~", cb_agent_show),
    ("ag_rot_do~", cb_agent_rotate_do),
    ("ag_rot~", cb_agent_rotate),
    ("ag_hard_do~", cb_agent_harden_do),
    ("ag_hard~", cb_agent_harden),
    ("ag_pin~", cb_agent_pin),
    ("ag_ext_do~", cb_agent_extend_do),
    ("ag_ext~", cb_agent_extend),
    ("ag_en~", cb_agent_toggle),
    ("ag_del~", cb_agent_delete),
    ("ag_http~", cb_agent_http),
    ("ag_scope~", cb_agent_add_scope),
    ("ag_days~", cb_agent_add_days),
    ("ag_apin~", cb_agent_add_pin),
    ("ag_aips~", cb_agent_add_ips_any),
    ("ag_amode~", cb_agent_add_mode),
    ("se_admin_del_ok~", cb_se_admin_del),
    ("se_admin_del~", cb_se_admin_del),
    ("se_mode_to~", cb_se_mode_to),
    ("se_mode_nodom~", cb_se_mode_nodom),
    ("se_mode_keep~", cb_se_mode_keep),
    # Линия на UDP 443 (F-3): при переходе в Pro и в самом Pro (pro-line)
    ("se_mode_pl~", cb_se_mode_pl),
    ("se_pline~", cb_se_pline_pick),
    ("se_tplc~", cb_se_tpl_category),
    ("se_tplf~", cb_se_tpl_found),
    ("se_tplp~", cb_se_tpl_pick),
    ("se_alt_set~", cb_se_alt_svc_set),
    ("se_mini~", cb_se_miniapp),
    ("lang_set_", cb_lang_set),
    ("lang_prod_", cb_lang_product),
]

# Кнопки, доступные ДО проверки доступа: онбординг первого админа («Да»,
# «Нет» и возврат к запросу после «Нет» — до назначения прав ни у кого нет).
PRE_AUTH_PREFIXES = ("admin_confirm_", "admin_cancel", "admin_again")


def resolve_handler(data: str) -> Optional[Callable]:
    """Обработчик по callback_data: сначала точное имя, потом самый длинный префикс."""
    if data in EXACT_HANDLERS:
        return EXACT_HANDLERS[data]
    best = None
    for prefix, handler in PREFIX_HANDLERS:
        if data.startswith(prefix) and (best is None or len(prefix) > len(best[0])):
            best = (prefix, handler)
    return best[1] if best else None


async def dispatch_callback_data(update: Update, context: ContextTypes.DEFAULT_TYPE, data: str) -> None:
    """Вызвать обработчик экрана по callback_data (возврат после typed-confirm).

    Все места вызова к этому моменту уже ответили на нажатие (`query.answer()`),
    а целевой обработчик отвечает ещё раз первой же строкой. Telegram принимает
    ответ на callback ровно один раз: второй answerCallbackQuery получает 400
    «query ID is invalid», исключение вылетает до отрисовки экрана, и вместо
    «Отмены», выбора формата ссылки или обновлённой карточки человек видел
    «Внутреннюю ошибку». Поэтому прокси повторный ответ глотает.
    """
    handler = resolve_handler(data) or cb_menu_main
    # Обработчики читают query.data, а объекты PTB неизменяемы — оборачиваем
    # запрос и апдейт в прокси с подменённым data.
    query = _QueryProxy(update.callback_query, data, answered=True)
    await handler(_UpdateProxy(update, query), context)


class _QueryProxy:
    """CallbackQuery с подменённым data (объекты PTB неизменяемы).

    answered=True — на нажатие уже ответили: повторный answer() ничего не шлёт
    (иначе Telegram отвечает 400 и обработчик падает, не нарисовав экран).
    """

    def __init__(self, query, data: str, answered: bool = False):
        self._query = query
        self.data = data
        self._answered = answered

    async def answer(self, *args: Any, **kwargs: Any) -> bool:
        if self._answered:
            return True
        self._answered = True
        return await self._query.answer(*args, **kwargs)

    def __getattr__(self, item):
        return getattr(self._query, item)


class _UpdateProxy:
    def __init__(self, update, query):
        self._update = update
        self.callback_query = query

    def __getattr__(self, item):
        return getattr(self._update, item)


class _NewMessageQuery(_QueryProxy):
    """Нажатие под уведомлением: экран рисуется в НОВОМ сообщении (его и правит обработчик), а уведомление остаётся.

    Кнопка «🩺 Диагностика» под тревогой о диске правила само уведомление — текст тревоги пропадал из чата
    (живая проверка на test1, 03.10). Обработчики экранов правят query.edit_message_text — здесь это правка нового
    сообщения; query.message — тоже оно, так что «ответить в чат» идёт туда же."""

    def __init__(self, query, data: str, message):
        super().__init__(query, data, answered=True)
        self.message = message

    async def edit_message_text(self, text, **kwargs):
        return await self.message.edit_text(text, **kwargs)

    async def edit_message_reply_markup(self, reply_markup=None, **kwargs):
        return await self.message.edit_reply_markup(reply_markup=reply_markup, **kwargs)


async def handle_callback(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    if query is None or not is_private_chat(update):
        # Кнопка под сообщением в группе (или inline-режим): бот там не работает —
        # ни экрана, ни вызова моста, даже если нажал админ.
        return
    data = str(query.data or "")
    user_id = _uid(update)

    # Онбординг первого админа — до проверки доступа
    if data.startswith(PRE_AUTH_PREFIXES):
        handler = resolve_handler(data)
        if handler is not None:
            await handler(update, context)
        return

    if not is_user_allowed(user_id):
        if stranger_may_reply(user_id):
            await query.answer(_t(user_id, "access_denied_short"))
        return

    # Кнопка = навигация → снимаем ожидание ввода и фразы, кроме кнопок,
    # которые сами продолжают текущий flow (галочки, быстрые значения). Ответ на запрос
    # короткой ссылки (sc~) приходит в любой миг от другого человека — не навигация: начатое
    # администратором (имя, фраза ROTATE …) остаётся.
    keep = data.startswith("sc~")
    if not keep and not data.startswith(FLOW_CALLBACK_PREFIXES):
        flow_clear(context)
    if not keep and not data.startswith("tc_cancel~"):
        CONFIRM.cancel(int(user_id))

    if data == "noop":
        await query.answer()
        return
    handler = resolve_handler(data)
    if handler is None:
        await query.answer(_t(user_id, "err_unknown_button"))
        return
    await handler(update, context)


def update_summary(update: object) -> str:
    """Что писать в лог об апдейте: номер, вид, кто и callback_data — и ничего больше.

    Сам объект Update в лог не идёт: str(update) печатает и подпись к фото, а
    под фото QR страницы она содержит адрес-секрет (под фото ключа — сам ключ).
    """
    query = getattr(update, "callback_query", None)
    if query is not None:
        kind = "callback"
    elif getattr(update, "message", None) is not None:
        kind = "message"
    else:
        kind = type(update).__name__
    user = _uid(update) if hasattr(update, "effective_user") else None
    data = getattr(query, "data", None) if query is not None else None
    return "id=%s kind=%s user=%s data=%r" % (getattr(update, "update_id", None), kind, user, data)


async def error_handler(update: object, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Залогировать ошибку и сказать об этом человеку: молчащая кнопка хуже алерта."""
    logger.error("Exception while handling update %s", update_summary(update), exc_info=context.error)
    user_id = _uid(update) if hasattr(update, "effective_user") else None
    notice = _t(user_id, "internal_error")
    query = getattr(update, "callback_query", None)
    if query is not None:
        try:
            await query.answer(notice, show_alert=True)
            return
        except Exception:  # noqa: BLE001 — callback мог быть уже отвечен
            pass
    message = getattr(update, "effective_message", None)
    if message is not None:
        try:
            await message.reply_text(notice)
        except Exception as e:  # noqa: BLE001
            logger.debug("error_handler: failed to notify user: %s", e)


# ============================================================================
# УВЕДОМЛЕНИЯ: очередь /run/goamnezia/notify → админам
# ============================================================================

def notify_keyboard(user_id: Optional[int], ev: Dict[str, Any]):
    """Кнопки под уведомлением — только там, где от владельца ждут решения.

    Обнаруженный клон замораживает доступ, и дальше решать человеку: «это был я,
    перевыдать» (новая цепочка ключей) или «отозвать совсем». Обе кнопки ведут в
    обычные экраны с подтверждением — из уведомления ничего не выполняется сразу.
    Все кнопки — с приставкой NOTICE_PREFIX: экран открывается новым сообщением, а
    уведомление остаётся в чате (раньше экран заменял собой текст тревоги).
    """
    event = str(ev.get("event") or "")
    agent = str(ev.get("agent") or "")
    if event == "disk_level" and str(ev.get("level") or "") in ("low", "critical"):
        # Диск заполняется: та же кнопка, что под строкой главного экрана, — удалять копии и подрезать журналы бот не
        # умеет, текст говорит, где это делается (TAIL-19)
        return InlineKeyboardMarkup([[btn(_t(user_id, "mt_diag"), "nt~mt_diag")]])
    if event == "docker_stale" or (event == "docker_restarted" and ev.get("ok") not in (True, "true")):
        # Служба Docker старая (DK-02): сторож ждёт, пока все отключатся, или сам не смог — перезапустить можно сейчас.
        # Кнопка ведёт на вопрос с предупреждением «VPN пропадёт у всех», а не перезапускает сразу.
        return InlineKeyboardMarkup([[btn(_t(user_id, "mt_dkr"), "nt~mt_dkr")]])
    if event == "dupline_bug" and valid_profile(str(ev.get("profile") or "")):
        # «Исправить» — экран «Переставить на 2.0» новым сообщением (согласие фразой там же), «Позже» — убрать кнопки
        return InlineKeyboardMarkup([[btn(_t(user_id, "dupline_fix_btn"), "nt~pr_rl~%s" % ev["profile"])],
                                     [btn(_t(user_id, "dupline_later_btn"), "nt_later")]])
    if event == "short_alarm":
        # Подбор коротких ссылок: баны адресов — тем же экраном, что из подписки, со снятием
        return InlineKeyboardMarkup([[btn(_t(user_id, "shl_bans_btn"), "nt~shl_bans")]])
    if event in ("agent_expiring", "agent_expired") and valid_agent_id(agent):
        # Срок доступа: текст называет «📅 Продлить ниже» — кнопка ведёт на экран сроков (там же вопрос)
        return InlineKeyboardMarkup([
            [btn(_t(user_id, "ag_btn_extend"), "nt~ag_ext~%s" % agent)],
            [btn(_t(user_id, "ag_btn_open_card"), "nt~ag_view~%s" % agent)],
        ])
    if event != "agent_compromised" or not valid_agent_id(agent):
        return None
    return InlineKeyboardMarkup([
        [btn(_t(user_id, "ag_btn_reissue"), "nt~ag_rot~%s" % agent)],
        [btn(_t(user_id, "ag_btn_revoke"), "nt~ag_del~%s" % agent)],
        [btn(_t(user_id, "ag_btn_open_card"), "nt~ag_view~%s" % agent)],
    ])


async def notify_admins(bot, events: List[Dict[str, Any]]) -> None:
    for ev in events:
        for admin_id in sorted(ALLOWED_IDS):
            text = "🔔 " + format_notify_event(admin_id, ev)
            try:
                await bot.send_message(chat_id=admin_id, text=text, parse_mode="HTML",
                                       reply_markup=notify_keyboard(admin_id, ev))
            except Exception as e:  # noqa: BLE001 — админ мог заблокировать бота
                logger.warning("notify %s: %s", admin_id, e)


def drop_persistence_marks(app) -> int:
    """Забыть id, которые PTB копит «для persistence», если persistence у бота нет.

    PTB 21 после каждого апдейта, дошедшего до обработчика, кладёт id человека и чата в
    множества для следующей записи persistence, а чистит их только при этой записи. У бота
    persistence нет — и множества росли без края: поток сообщений и нажатий с тысяч чужих
    аккаунтов (им бот даже не отвечает, SEC-B3) оседал в памяти навсегда. Возвращает, сколько
    id забыто. Атрибуты внутренние — через getattr: сменится PTB (он закреплён <22) — чистка
    просто ничего не найдёт, а не уронит бота.
    """
    if getattr(app, "persistence", None) is not None:
        return 0
    dropped = 0
    for attr in ("_user_ids_to_be_updated_in_persistence", "_chat_ids_to_be_updated_in_persistence"):
        marks = getattr(app, attr, None)
        if isinstance(marks, set):
            dropped += len(marks)
            marks.clear()
    return dropped


async def _notify_loop(app) -> None:
    """Раз в 30 с читать очередь событий таймера лимитов и слать админам (и забывать
    id, которые PTB копит для persistence, — см. drop_persistence_marks). Запрос и итог
    короткой ссылки, попавшие в общую очередь, идут своим путём (short_dispatch_event)."""
    while True:
        try:
            drop_persistence_marks(app)
            events = collect_notify_events(NOTIFY_DIR)
            if events:
                logger.info("notify: %d event(s)", len(events))
                rest = []
                for ev in events:
                    if not await short_dispatch_event(app.bot, ev):
                        rest.append(ev)
                await notify_admins(app.bot, rest)
        except asyncio.CancelledError:
            raise
        except Exception as e:  # noqa: BLE001 — цикл не должен умирать от одного сбоя
            logger.warning("notify loop: %s", e)
        await asyncio.sleep(NOTIFY_POLL_SECONDS)


# ============================================================================
# КОРОТКИЕ ССЫЛКИ: очередь запросов подтверждения → администраторам (раз в секунду)
# ============================================================================
# short_confirm {request, kind: login|replace, name, label, suffix, device, ip, geo, options[10], expires} — сообщение
# всем администраторам с 12 (вход) или 11 (замена) кнопками; short_decided {request, status, by} — итог от ядра (решили
# в панели, в SSH, другим администратором или вышло время): сообщение запроса правится у всех. Свой срок запрос
# помнит и сам: истёк, а итога нет — «⌛ Время вышло». Какие сообщения у кого и чем решено — в SHORT_STATE_FILE (0600):
# переживает перезапуск; решённые помним час, не больше SHORT_MAX_REQUESTS.
_SHORT: Dict[str, Dict[str, Any]] = {}
_SHORT_LOADED = {"done": False}
_SHORT_LOCKS: Dict[str, "asyncio.Lock"] = {}
_SHORT_ADMIN_NAMES: Dict[int, str] = {}
_SHORT_BOT: Dict[str, Any] = {"bot": None}
SHORT_KEEP_SECONDS = 3600
SHORT_MAX_REQUESTS = 200
# Пять минут запроса — у ядра; бот ждёт его итога ещё немного, прежде чем написать «время вышло» сам.
SHORT_EXPIRE_GRACE = 5
SHORT_TTL_FALLBACK = 300


def _short_state() -> Dict[str, Dict[str, Any]]:
    """Запросы, о которых бот писал: при первом обращении — из файла (после перезапуска)."""
    if not _SHORT_LOADED["done"]:
        _SHORT_LOADED["done"] = True
        try:
            data = json.loads(Path(SHORT_STATE_FILE).read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, ValueError):
            data = {}
        for req, rec in (data.items() if isinstance(data, dict) else []):
            if SHORT_REQUEST_RE.match(str(req)) and isinstance(rec, dict) and isinstance(rec.get("ev"), dict) \
                    and isinstance(rec.get("msgs"), list):
                _SHORT[str(req)] = rec
    return _SHORT


def _short_save(now: Optional[float] = None) -> None:
    """Забыть решённое больше часа назад и лишнее сверх предела, остальное — в файл 0600 атомарно."""
    now = time.time() if now is None else now
    for req in [k for k, rec in _SHORT.items() if rec.get("done") and now - float(rec.get("at") or 0) > SHORT_KEEP_SECONDS]:
        _SHORT.pop(req, None)
        _SHORT_LOCKS.pop(req, None)
    if len(_SHORT) > SHORT_MAX_REQUESTS:
        for req in sorted(_SHORT, key=lambda k: float(_SHORT[k].get("at") or 0))[:len(_SHORT) - SHORT_MAX_REQUESTS]:
            _SHORT.pop(req, None)
            _SHORT_LOCKS.pop(req, None)
    _write_private_file(SHORT_STATE_FILE, json.dumps(_SHORT, ensure_ascii=False))


async def short_confirm_send(tg_bot, raw: Dict[str, Any], now: Optional[float] = None) -> int:
    """Запрос входа или замены — всем администраторам: текст и клавиатура на языке каждого. Повтор того же события
    (ядро положило дважды) второй раз не шлётся. Вернёт, скольким ушло. В лог — id и вид запроса, без адреса и имени."""
    ev = short_event(raw)
    if ev is None:
        logger.warning("short_confirm without a valid request id — skipped")
        return 0
    state = _short_state()
    req = ev["request"]
    rec = state.get(req)
    if rec is not None and (rec.get("sent") or rec.get("msgs") or rec.get("done")):
        return 0
    if not ev["expires"]:
        ev["expires"] = (time.time() if now is None else now) + SHORT_TTL_FALLBACK
    if rec is None:
        rec = {"ev": ev, "msgs": [], "done": "", "by": "", "by_name": "", "at": time.time() if now is None else now}
        state[req] = rec
    else:
        # Замену попросили в этом боте (short_register_ask): событие ядра дополняет запомненное, кто просил — остаётся
        rec["ev"] = ev
    rec["sent"] = True
    for admin_id in sorted(ALLOWED_IDS):
        try:
            msg = await tg_bot.send_message(chat_id=admin_id, text=short_confirm_text(admin_id, ev, now=now),
                                            parse_mode="HTML", disable_web_page_preview=True,
                                            reply_markup=short_confirm_keyboard(admin_id, ev))
            rec["msgs"].append([admin_id, msg.message_id])
        except Exception as e:  # noqa: BLE001 — админ мог заблокировать бота
            logger.warning("short link request %s → %s: %s", req, admin_id, e)
    _short_save(now)
    logger.info("short link request %s (%s) sent to %d admin(s)", req, ev["kind"], len(rec["msgs"]))
    return len(rec["msgs"])


async def _short_edit_all(tg_bot, rec: Dict[str, Any], skip: Optional[Tuple[Any, Any]] = None) -> int:
    """Сообщение запроса у каждого администратора — с итогом и без кнопок; «не изменилось» — не ошибка."""
    done = 0
    for item in rec.get("msgs") or []:
        if not (isinstance(item, list) and len(item) == 2):
            continue
        chat_id, message_id = item
        if skip is not None and (chat_id, message_id) == tuple(skip):
            continue
        try:
            await tg_bot.edit_message_text(chat_id=chat_id, message_id=message_id, parse_mode="HTML",
                                           text=short_confirm_text(chat_id, rec.get("ev") or {}, rec),
                                           reply_markup=None, disable_web_page_preview=True)
            done += 1
        except Exception as e:  # noqa: BLE001 — сообщение могли удалить, бота — заблокировать
            if "not modified" not in str(e).lower():
                logger.warning("short link request: edit %s failed: %s", chat_id, e)
    return done


async def short_apply_decision(tg_bot, req: str, status: str, by: str = "", by_name: str = "",
                               skip: Optional[Tuple[Any, Any]] = None,
                               link: Optional[Tuple[str, str]] = None) -> bool:
    """Итог запроса: запомнить (чем и кто) и поправить сообщение у всех администраторов; замену просил администратор
    этого бота — итог и новый код ему (short_notify_asker; link — новый код из ответа short-decide, если он есть). Тот же
    итог второй раз — ничего не делать; незнакомый боту запрос — ничего не править. True — итог применён сейчас."""
    rec = _short_state().get(req)
    if rec is None or (rec.get("done") == status and rec.get("by") == by):
        return False
    rec.update(done=status, by=by, at=time.time())
    if by_name:
        rec["by_name"] = by_name
    _short_save()
    if tg_bot is not None:
        await _short_edit_all(tg_bot, rec, skip)
        await short_notify_asker(tg_bot, rec, link)
    return True


def short_register_ask(req: str, ask: Dict[str, Any], name: str, suffix: str, expires: float) -> None:
    """Запомнить, кто в этом боте попросил замену («↻ Заменить»): его id и имя, сообщение с прежней ссылкой и сообщение с
    числом. Событие ядра о запросе могло прийти раньше или придёт позже — запись общая (short_confirm_send её дополнит)."""
    state = _short_state()
    rec = state.get(req)
    if rec is None:
        rec = {"ev": {"request": req, "kind": "replace", "name": name, "label": "", "suffix": suffix, "device": "",
                      "ip": "", "geo": "", "options": [], "expires": expires or time.time() + SHORT_TTL_FALLBACK},
               "msgs": [], "done": "", "by": "", "by_name": "", "at": time.time()}
        state[req] = rec
    rec["ask"] = ask
    _short_save()


async def _short_current_link(user_id: Optional[int], name: str, suffix: str) -> Optional[Tuple[str, str]]:
    """Нынешняя короткая ссылка пары (short-list — чтение, без замка бота): после подтверждённой замены — уже новая."""
    r = await run_bot_action("short-list", timeout=60, who=user_id, name=name)
    for c in (r.get("codes") if bridge_ok(r) and isinstance(r.get("codes"), list) else []):
        if isinstance(c, dict) and c.get("suffix") == suffix:
            return short_link_of(c)
    return None


async def _short_edit_quiet(tg_bot, where: Any, text: str) -> None:
    """Поправить одно сообщение (без кнопок); удалённое или не изменившееся — не беда."""
    if not (isinstance(where, list) and len(where) == 2 and all(isinstance(x, int) for x in where)):
        return
    try:
        await tg_bot.edit_message_text(chat_id=where[0], message_id=where[1], text=text, parse_mode="HTML",
                                       reply_markup=None, disable_web_page_preview=True)
    except Exception as e:  # noqa: BLE001
        if "not modified" not in str(e).lower():
            logger.warning("short link replacement: edit %s failed: %s", where[0], e)


async def short_notify_asker(tg_bot, rec: Dict[str, Any], link: Optional[Tuple[str, str]] = None) -> bool:
    """Итог замены — тому, кто её попросил в этом боте (SL-BOT-01: подтвердить может другой администратор). Сообщение с
    числом — итогом («✅ Подтвердил: …», отказ, «⌛ Время вышло»); замена прошла — прежнее сообщение с мёртвым кодом
    правится («заменена, новая — ниже»), а новый код приходит ему отдельным сообщением с «↻ Заменить» (из ответа
    short-decide, иначе — short-list). Один раз на запрос."""
    ask = rec.get("ask")
    status = str(rec.get("done") or "")
    if not isinstance(ask, dict) or ask.get("told") or not status:
        return False
    ask["told"] = True
    _short_save()
    ev = rec.get("ev") or {}
    uid = ask.get("uid") if isinstance(ask.get("uid"), int) else None
    name, suffix = str(ev.get("name") or ""), str(ev.get("suffix") or "")
    what = "%s · %s" % (esc(ev.get("label") or name), esc(suffix))
    await _short_edit_quiet(tg_bot, ask.get("num"), "\n".join([
        _tf(uid, "shl_replace_req_fmt", esc(ev.get("label") or name), esc(suffix)), "", short_result_line(uid, rec)]))
    if status not in ("ok", "swapped") or uid is None:
        return True
    await _short_edit_quiet(tg_bot, ask.get("link"), _tf(uid, "shl_link_replaced_fmt", what))
    if link is None and valid_name(name) and SHORT_SUFFIX_RE.match(suffix):
        link = await _short_current_link(uid, name, suffix)
    chat = ask.get("link")[0] if isinstance(ask.get("link"), list) and ask.get("link") else uid
    try:
        if link is None:
            await tg_bot.send_message(chat_id=chat, text=_t(uid, "shl_link_lost"), parse_mode="HTML")
        else:
            await tg_bot.send_message(chat_id=chat, text=short_link_text(uid, what, link[0], link[1], new=True),
                                      parse_mode="HTML", disable_web_page_preview=True,
                                      reply_markup=short_link_keyboard(uid, name, suffix))
    except Exception as e:  # noqa: BLE001 — администратор мог заблокировать бота
        logger.warning("short link replacement %s: delivery to the asker failed: %s", ev.get("request"), e)
    return True


async def short_decided_apply(tg_bot, ev: Dict[str, Any]) -> bool:
    """short_decided {request, status, by} от ядра — итог главнее всего, что бот думал раньше (истёкший у бота запрос,
    решённый в панели секундой раньше, получит настоящий итог)."""
    req, status = str(ev.get("request") or ""), str(ev.get("status") or "")
    if not SHORT_REQUEST_RE.match(req) or not re.fullmatch(r"[a-z_]{1,24}", status):
        logger.warning("short_decided: bad request or status — skipped")
        return False
    by = str(ev.get("by") or "")
    return await short_apply_decision(tg_bot, req, status, by=by if re.fullmatch(r"[A-Za-z0-9:_.@-]{1,48}", by) else "")


async def short_expire_sweep(tg_bot, now: Optional[float] = None) -> int:
    """Запросы без итога, чей срок вышел (с запасом SHORT_EXPIRE_GRACE), — «⌛ Время вышло» у всех."""
    now = time.time() if now is None else now
    n = 0
    for req, rec in list(_short_state().items()):
        exp = float((rec.get("ev") or {}).get("expires") or 0) or float(rec.get("at") or 0) + SHORT_TTL_FALLBACK
        if not rec.get("done") and now > exp + SHORT_EXPIRE_GRACE:
            if await short_apply_decision(tg_bot, req, "expired"):
                n += 1
    return n


async def short_dispatch_event(tg_bot, ev: Dict[str, Any]) -> bool:
    """Событие коротких ссылок — своим путём; False — событие не их (его покажет notify_admins)."""
    event = str(ev.get("event") or "")
    if event == "short_confirm":
        await short_confirm_send(tg_bot, ev)
        return True
    if event == "short_decided":
        await short_decided_apply(tg_bot, ev)
        return True
    return False


async def short_confirm_tick(tg_bot, now: Optional[float] = None) -> int:
    """Один обход очереди коротких ссылок: запросы и итоги — сразу, чужие события (тревога о подборе, если ядро
    положило её сюда) — обычным уведомлением; затем истёкшие запросы. Вернёт, сколько событий прочитано."""
    events = collect_notify_events(SHORT_CONFIRM_DIR)
    rest = []
    for ev in events:
        if not await short_dispatch_event(tg_bot, ev):
            rest.append(ev)
    if rest:
        await notify_admins(tg_bot, rest)
    await short_expire_sweep(tg_bot, now)
    return len(events)


async def _short_confirm_loop(app) -> None:
    """Раз в секунду — очередь запросов подтверждения коротких ссылок: человек у экрана ждёт ответа сейчас."""
    _SHORT_BOT["bot"] = app.bot
    while True:
        try:
            await short_confirm_tick(app.bot)
        except asyncio.CancelledError:
            raise
        except Exception as e:  # noqa: BLE001 — цикл не должен умирать от одного сбоя
            logger.warning("short confirm loop: %s", e)
        await asyncio.sleep(SHORT_CONFIRM_POLL_SECONDS)


# ============================================================================
# ПРИВЯЗКА СООБЩЕНИЕМ: подтверждение из SSH → администратор без перезапуска
# ============================================================================

async def pairing_greet(tg_bot, uid: int) -> None:
    """«✓ Вы администратор сервера …» и главный экран — тому, кого подтвердили в SSH."""
    status = await get_status(fresh=True)
    host = ""
    if bridge_ok(status):
        host = str(status.get("domain") or status.get("server_ip") or "").strip()
    try:
        await tg_bot.send_message(chat_id=uid, parse_mode="HTML",
                                  text=_tf(uid, "admin_paired_fmt", esc(host or "goAmnezia pro"),
                                           _dt.datetime.now(_dt.timezone.utc).strftime("%H:%M"), uid))
        await tg_bot.send_message(chat_id=uid, text=dashboard_text(uid, status), parse_mode="HTML",
                                  reply_markup=get_main_menu(uid, status), disable_web_page_preview=True)
    except Exception as exc:  # noqa: BLE001 — человек мог не открыть чат или заблокировать бота
        logger.warning("Admin pairing: greeting %s failed: %s", uid, exc)
    # Кнопка меню чата с панелью ставится каждому админу отдельно — новому тоже
    try:
        await refresh_menu_button(tg_bot)
    except Exception as exc:  # noqa: BLE001 — кнопка меню не повод ронять привязку
        logger.warning("refresh_menu_button: %s", exc)


def _pairing_reject(raw: str, reason: str) -> None:
    """Подтверждение из SSH не принято: ADMIN_CONFIRMED_FILE → ADMIN_CONFIRMED_REJECTED_FILE (0600).

    Первая строка — что написал SSH, вторая — почему: empty (файл так и остался пустым),
    bad_id (не Telegram ID), not_in_env (id так и не появился в ALLOWED_IDS). Пропажа файла
    подтверждения сама по себе больше ничего не значит — SSH ждёт один из двух ответов.
    """
    first = (raw.splitlines() or [""])[0].strip()[:64]
    logger.error("Admin pairing: confirmation %r rejected (%s), see %s", first, reason, ADMIN_CONFIRMED_REJECTED_FILE)
    if not _write_private_file(ADMIN_CONFIRMED_REJECTED_FILE, "%s\n%s\n" % (first, reason)):
        logger.error("Admin pairing: %s not written", ADMIN_CONFIRMED_REJECTED_FILE)
    _unlink_quiet(ADMIN_CONFIRMED_FILE)


async def pairing_tick(tg_bot, now: Optional[float] = None) -> Optional[int]:
    """Один обход (раз в PAIRING_POLL_SECONDS): подтверждение из SSH или уборка после окна.

    SSH, подтвердив человека, пишет ALLOWED_IDS/OWNER_ID в .env и его id в ADMIN_CONFIRMED_FILE.
    Бот перечитывает админов из .env и, если id там есть, отвечает SSH файлом ADMIN_PAIRING_DONE_FILE
    с этим id, убирает файлы привязки, здоровается с новым админом и показывает ему меню. Файл
    пуст или id в .env ещё нет — ждём (SSH мог ещё не дописать), через минуту — отказ
    (_pairing_reject); не Telegram ID — отказ сразу. Вернёт id нового админа.
    """
    now = time.time() if now is None else now
    pairing_sync_window()
    try:
        raw = Path(ADMIN_CONFIRMED_FILE).read_text(encoding="utf-8").strip()
        age = now - os.stat(ADMIN_CONFIRMED_FILE).st_mtime
    except (OSError, UnicodeDecodeError):
        raw = None
    if raw is None:
        if not pairing_window_open(now):
            # Верный код годится только в своём окне: «Да» из прошлого окна ничего не даёт
            _CLAIM_VERIFIED.clear()
            pairing_forget_stale(now)
        return None
    if not raw:
        if age > PAIRING_STALE_SECONDS:
            _pairing_reject(raw, "empty")
        return None
    if not valid_admin_id(raw):
        _pairing_reject(raw, "bad_id")
        return None
    uid = int(raw)
    reload_admins_from_env()
    if uid not in ALLOWED_IDS:
        if age > PAIRING_STALE_SECONDS:
            _pairing_reject(raw, "not_in_env")
        return None
    # Сначала ответ SSH и уборка, потом приветствие: сбой отправки не должен приветствовать дважды
    if not _write_private_file(ADMIN_PAIRING_DONE_FILE, "%d\n" % uid):
        logger.error("Admin pairing: %s not written", ADMIN_PAIRING_DONE_FILE)
    for path in (ADMIN_CONFIRMED_FILE, ADMIN_CONFIRMED_REJECTED_FILE, ADMIN_CANDIDATES_FILE, ADMIN_PAIRING_UNTIL_FILE):
        _unlink_quiet(path)
    forget_admin_claim_code()
    logger.warning("Admin pairing: %s confirmed in SSH — administrator now", uid)
    await pairing_greet(tg_bot, uid)
    return uid


async def _pairing_loop(app) -> None:
    """Раз в пару секунд смотреть, не подтвердил ли SSH привязку: рестарт бота для этого не нужен."""
    while True:
        try:
            await pairing_tick(app.bot)
        except asyncio.CancelledError:
            raise
        except Exception as e:  # noqa: BLE001 — цикл не должен умирать от одного сбоя
            logger.warning("pairing loop: %s", e)
        await asyncio.sleep(PAIRING_POLL_SECONDS)


# ============================================================================
# ЗАПУСК
# ============================================================================
BOT_COMMANDS = ("start", "users", "status", "adduser", "key", "invite", "lang", "help")


def bot_commands_for(lang: str) -> list:
    return [BotCommand(name, _t_in(lang, "cmd_desc_%s" % name)) for name in BOT_COMMANDS]


async def _announce_self(app) -> None:
    """Заявить Telegram свои команды и кнопку меню; поднять цикл уведомлений.

    Без set_my_commands в списке висело бы то, что оставил прежний хозяин
    токена. Русский — общий набор, английский — для клиентов с language_code en.
    """
    try:
        await app.bot.set_my_commands(bot_commands_for("ru"))
        await app.bot.set_my_commands(bot_commands_for("en"), language_code="en")
    except Exception as exc:  # noqa: BLE001
        logger.warning("set_my_commands: %s", exc)
    await refresh_menu_button(app.bot)
    _NOTIFY_TASK["task"] = spawn_task(_notify_loop(app))
    _NOTIFY_TASK["pairing"] = spawn_task(_pairing_loop(app))
    # Запросы подтверждения коротких ссылок — своим циклом раз в секунду, отдельно от общих уведомлений
    _NOTIFY_TASK["short"] = spawn_task(_short_confirm_loop(app))


_NOTIFY_TASK: Dict[str, Any] = {"task": None, "pairing": None, "short": None}


async def _shutdown(app) -> None:
    """Остановить циклы уведомлений, привязки и коротких ссылок до закрытия loop — иначе PTB ругается на висящую задачу."""
    for key in ("task", "pairing", "short"):
        task = _NOTIFY_TASK.get(key)
        if task is not None and not task.done():
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):  # noqa: BLE001
                pass


async def refresh_menu_button_after(context) -> None:
    """Переставить кнопку меню чата после того, как панель на домене сменилась.

    Кнопку ставит только запуск бота (_announce_self). После «Сменить секретный
    путь», «Закрыть» или смены режима она продолжала вести на прежний адрес —
    то есть в чужой 404 — до следующего перезапуска бота.
    """
    tg_bot = getattr(context, "bot", None)
    if tg_bot is None:
        return
    try:
        await refresh_menu_button(tg_bot)
    except Exception as exc:  # noqa: BLE001 — кнопка меню не повод ронять экран
        logger.warning("refresh_menu_button: %s", exc)


async def refresh_menu_button(bot) -> None:
    """Кнопка меню: мини-апп — только в чатах админов, всем остальным — список команд.

    Общую кнопку (без chat_id) видит любой, кто откроет бота, а адрес мини-аппа — секретный путь
    панели на домене: общая кнопка-мини-апп раздавала его всем (аудит безопасности 25.09.2026, высокий).
    Поэтому общая — всегда список команд, а мини-апп ставится персонально каждому админу (персональная
    кнопка перекрывает общую).
    """
    status = await get_status()
    url = miniapp_url(status if bridge_ok(status) else None)
    admin_button = MenuButtonWebApp(text=_t(None, "menu_panel"), web_app=WebAppInfo(url=url)) if url else MenuButtonCommands()
    try:
        await bot.set_chat_menu_button(menu_button=MenuButtonCommands())
    except Exception as exc:  # noqa: BLE001
        logger.warning("set_chat_menu_button(default): %s", exc)
    for chat_id in sorted(ALLOWED_IDS):
        try:
            await bot.set_chat_menu_button(chat_id=chat_id, menu_button=admin_button)
        except Exception as exc:  # noqa: BLE001
            logger.warning("set_chat_menu_button(%s): %s", chat_id, exc)


async def reset_menu_button(bot, chat_id: int) -> None:
    """Бывшему админу — снова общий список команд: персональная кнопка с адресом панели у него
    оставалась бы после удаления из админов."""
    try:
        await bot.set_chat_menu_button(chat_id=chat_id, menu_button=MenuButtonCommands())
    except Exception as exc:  # noqa: BLE001
        logger.warning("reset_menu_button(%s): %s", chat_id, exc)


# Виды апдейтов, которые бот вообще просит у Telegram: сообщения и нажатия. Посты
# каналов, правки, вступления в группы ему не нужны — незачем их и получать.
ALLOWED_UPDATES = ("message", "callback_query")


def register_handlers(application) -> None:
    """Команды, кнопки, текст и файлы — только из личного чата с ботом.

    Фильтр стоит на входе (PTB не зовёт обработчик вовсе), а сами обработчики
    проверяют чат ещё раз (is_private_chat): кнопки PTB фильтром не закрыть, и
    проверка внутри держится, даже если регистрацию когда-нибудь поменяют.
    """
    private = filters.ChatType.PRIVATE & filters.UpdateType.MESSAGE
    for name, handler in (("start", cmd_start), ("help", cmd_help), ("users", cmd_users),
                          ("status", cmd_status), ("adduser", cmd_adduser), ("key", cmd_key),
                          ("invite", cmd_invite), ("lang", cmd_lang)):
        application.add_handler(CommandHandler(name, handler, filters=private))
    application.add_handler(CallbackQueryHandler(handle_callback))
    application.add_handler(MessageHandler(private & filters.TEXT & ~filters.COMMAND, handle_text_message))
    # Файл .conf старого ключа («Привязать старый ключ»); картинке — ответ, что QR не читается;
    # видео, аудио и голосовое — только ради подписи: ссылка vpn:// в ней — ключ в переписке (UI-1)
    application.add_handler(MessageHandler(private & (filters.Document.ALL | filters.PHOTO | filters.CAPTION),
                                           handle_file_message))
    # Остальное из лички — стикер, голосовое, контакт, геопозиция, незнакомая команда: оно важно
    # только окну привязки («напишите боту любое сообщение»). Фильтр не пересекается с текстом и
    # файлами; известные команды разбирают CommandHandler выше — в группе срабатывает первый.
    application.add_handler(MessageHandler(
        private & (filters.COMMAND | ~(filters.TEXT | filters.Document.ALL | filters.PHOTO | filters.CAPTION)),
        handle_other_message))
    application.add_error_handler(error_handler)


def main() -> None:
    """Точка входа: токен и зависимости проверяются только здесь."""
    if _load_dotenv is not None:
        _load_dotenv(ENV_FILE)
        _load_allowed_ids()
    if not PTB_AVAILABLE:
        logger.error("python-telegram-bot is not installed (%s); run install_bot.sh", PTB_IMPORT_ERROR)
        sys.exit(1)
    token = (os.getenv("BOT_TOKEN") or "").strip()
    if not token:
        logger.error("BOT_TOKEN is not set (see %s)", ENV_FILE)
        sys.exit(1)
    if not os.path.exists(ACTION_BIN):
        logger.warning("bridge %s not found — actions will answer with code transport", ACTION_BIN)
    if _WAITING_FOR_ADMIN:
        # Кода бот сам больше не заводит: окно привязки открывает SSH, а код — запасной путь
        # установщика без терминала (он же его и пишет). Сам код в лог не пишем — только путь.
        logger.warning("No administrator yet: open «Telegram bot → Administrators → Bind by message» in the SSH "
                       "menu and write to the bot (pairing window: %s s left; one-time code file: %s)",
                       admin_claim_seconds_left(), ADMIN_CLAIM_CODE_FILE)
    else:
        forget_admin_claim_code()       # админ есть — старый код ничего не должен открывать

    # concurrent_updates: иначе на время установки профиля (до 15 мин) бот
    # глохнет для всех, а экраны «другая операция выполняется» недостижимы.
    application = Application.builder().token(token).concurrent_updates(True).build()
    register_handlers(application)
    application.post_init = _announce_self
    application.post_shutdown = _shutdown

    logger.info("goAmnezia pro bot starting (bridge: %s)", ACTION_BIN)
    application.run_polling(allowed_updates=list(ALLOWED_UPDATES))


if __name__ == "__main__":
    main()
