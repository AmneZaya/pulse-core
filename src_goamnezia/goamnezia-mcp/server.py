#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""goamnezia-mcp — MCP-сервер над мостом `install.sh --action=<имя> --json`.

Model Context Protocol: JSON-RPC 2.0, версия протокола 2025-06-18, транспорт stdio.
Агент (Claude Code, Claude Desktop, Cursor и любой другой MCP-клиент) запускает
`ssh root@HOST goamnezia-mcp`, получает список типизированных инструментов и вызывает их.
Каждый вызов превращается в `install.sh --action=<cli-имя> --json --k=v …`, а последняя
JSON-строка stdout моста становится результатом инструмента.

Почему так устроено:

- Всё продуктовое живёт в lib/actions.json (имена действий, параметры с регексами и
  границами, флаги readonly/destructive, описания RU/EN, ресурсы, подсказки) и в переменных
  окружения GOAMNEZIA_*. В этом файле нет ни одного имени действия: переходник переносится
  в другой скрипт серии сменой блока «умолчания продукта» ниже (или переменных окружения).
- Ресурсы двух видов. Ресурс с полем action — обёртка над действием только для чтения (ответ
  моста как application/json). Ресурс с полем file — документ рядом с сервером (гайд для
  агента, mimeType из записи): агент читает его по протоколу до первого изменяющего вызова,
  поэтому документация для модели живёт на сервере, а не в README для человека (контракт §5).
- Действия с "mcp": null в actions.json (выдача и отзыв доступов агентов agent-*, включение
  HTTP-транспорта mcp-http-*) сервер не публикует вовсе — ни в tools/list, ни в tools/call:
  агент не должен уметь выдать или продлить доступ ни себе, ни другому агенту. Эти действия
  остаются людям: SSH-меню, бот, панель.
- Только stdlib (Python >= 3.8): на сервере нет pip, как и у панели.
- stdout священен. По stdio-транспорту клиент читает из нашего stdout только JSON-RPC-
  сообщения, по одному на строку. Любой посторонний байт (print, спиннер моста, warning
  библиотеки) ломает парсер клиента, и сессия «зависает» без внятной ошибки. Поэтому логи
  идут только в stderr, stdout моста перехватывается целиком, а sys.stdout после старта
  подменяется на stderr (см. main()) — случайный print уже не сможет навредить.
- Разрушительные действия требуют параметр confirm поверх подтверждения клиента: клиент
  спрашивает человека «вызвать ли инструмент», но не все клиенты спрашивают (авто-режимы,
  --dangerously-skip-permissions, скрипты поверх MCP), а модель может перепутать цель.
  confirm заставляет модель осознанно повторить имя цели — это защита от вызова «не того»,
  а подтверждение клиента — от вызова «вообще». Обе линии нужны.

- HTTP-транспорт (--http, PLAN §6.10, CONTRACT §5.1) — тот же диспетчер JSON-RPC поверх
  stdlib ThreadingHTTPServer. Адрес агента — POST /a-<secret>/mcp, и ДВА независимых
  доказательства: секретный путь (32 случайных байта в base64url) и токен доступа в
  заголовке Authorization: Bearer <token> (ещё 32 случайных байта).

  Почему двух мало по одному. Полный адрес утекает буднично: снимок экрана со ссылкой,
  пересылка в мессенджере, история браузера, журнал промежуточного прокси, конфиг агента на
  чужой машине и резервная копия этого конфига. Заголовок в эти места не попадает: браузер
  его не запоминает, прокси пишет в лог метод и URL, а не заголовки, на снимке экрана со
  ссылкой его нет. Поэтому утёкший адрес сам по себе бесполезен — нужен ещё и токен, который
  живёт отдельно (в конфиге клиента, в переменной окружения). Сравнение — hmac.compare_digest.

  Совместимость: у доступов, выданных до появления токена, require_token=false — они работают
  по одному пути и помечены в списках «слабый доступ». Действие agent-harden выдаёт такому
  доступу токен и включает require_token.

- Одноразовый ключ (mode: "rolling", docs/MCP_ROTATION.md §1 в редакции §11). Секретный путь и
  токен доказывают «я знаю пароль», но копию пароля не отличить от подлинника: скопированный на
  чужую машину доступ работает там ровно так же. Одноразовый ключ меняет саму цель — не
  предотвратить кражу (программно это невозможно, §0 того же документа), а гарантированно её
  ЗАМЕТИТЬ. Каждый успешный запрос сжигает пришедший ключ и выдаёт следующий заголовком
  X-Ga-Next-Key; сервер помнит текущий, предыдущий и отпечатки полусотни уже выданных.

  Клон доказывается не «несовпадением», а УЗНАВАНИЕМ (§11.1): ключ из истории выданных — это
  ключ, которого у настоящего агента уже нет, значит цепочка раздвоилась. Ключ, которого сервер
  никогда не выдавал, — обычный мусор, отвечаем тем же 404 и считаем неудачу. Разница
  принципиальная: без неё любой, кто узнал путь, гасил бы чужого агента одним мусорным запросом,
  и защита превращалась бы в кнопку «выключить агента» для постороннего.

  Обнаружение клона ЗАМОРАЖИВАЕТ доступ (compromised), а не удаляет его (§11.3): восстановление
  машины из вчерашней резервной копии выглядит так же, как кража, и владелец должен решать сам —
  «это был я, перевыдать» или «отозвать совсем».

  Одновременность — не копия (§11.8). Клиент MCP сразу после initialize спрашивает инструменты,
  ресурсы и подсказки, не дожидаясь ответов: второй запрос несёт ТОТ ЖЕ ключ (нового он ещё не
  видел) и свой номер. Отличаем по одному признаку: запрос пришёл РАНЬШЕ, чем ушёл ответ с новым
  ключом, — значит отправитель следующего ключа знать не мог. Такой запрос выполняется и получает
  тот же самый новый ключ, цепочка не вращается. Копия на чужой машине так выглядеть не может:
  её запрос приходит уже после того, как ответ ушёл.

  Состояние цепочки живёт отдельным файлом на доступ в постоянном каталоге (§11.6), не в /run:
  тот чистится при перезагрузке, и цепочка обнулялась бы после каждого включения сервера. Реестр
  agents.json от вращения не страдает — он меняется при выдаче, отзыве и заморозке.

  Доступы лежат в agents.json и перечитываются по mtime при каждом запросе — «Выключить» и
  «Удалить» в меню действуют на следующий же вызов без перезапуска. Любой отказ (неизвестный
  секрет, нет или не тот токен, выключенный, истёкший, чужой IP, не тот закреплённый IP,
  бан) — один и тот же 404 с телом как у nginx. Почему 404, а не 401: 401 подтвердил бы, что
  путь существует и нужен лишь пароль, — сканер узнал бы, что нашёл живой адрес, и перешёл к
  подбору токена; 404 не отличим от ответа сайта-маскировки на любой чужой путь, и
  подобравший адрес не понимает, что подобрал.

  Уровень доступа (read/write/admin) режет каталог: агент не видит инструментов вне уровня,
  а вызов по имени получает -32003 forbidden.

Переменные окружения: GOAMNEZIA_DIR, GOAMNEZIA_ACTION_BIN, GOAMNEZIA_ACTIONS_JSON,
GOAMNEZIA_AUDIT_LOG, GOAMNEZIA_LANG, GOAMNEZIA_MCP_TIMEOUT, GOAMNEZIA_MCP_LOG,
GOAMNEZIA_AGENTS_JSON, GOAMNEZIA_LOCK_FILE, GOAMNEZIA_NOTIFY_DIR, GOAMNEZIA_STATE_DIR —
см. README.md.
"""

import base64
import datetime
import hashlib
import secrets
import hmac
import ipaddress
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import calendar
import time
import traceback

# ---------------------------------------------------------------------------------------------
# Умолчания продукта. Единственное место, где упоминается имя продукта: при переносе в другой
# скрипт серии (goTelegram, goDNS…) меняются эти строки — или задаются переменные окружения.
# ---------------------------------------------------------------------------------------------
PRODUCT = "goamnezia"                      # имя сервера в serverInfo, если config.json молчит
ENV_PREFIX = "GOAMNEZIA"                   # префикс переменных окружения: GOAMNEZIA_ACTION_BIN …
DEFAULT_DIR = "/opt/goamnezia"             # каталог с config.json, lib/actions.json, install.sh
DEFAULT_AUDIT_LOG = "/var/log/goamnezia-audit.log"

PROTOCOL_VERSION = "2025-06-18"
# Старые версии протокола отличаются от 2025-06-18 только надстройками (structuredContent,
# title, отмена пакетной передачи), наши ответы совместимы со всеми тремя — поэтому по правилу
# спецификации («если версия поддерживается, ответить той же») мы отвечаем версией клиента.
SUPPORTED_PROTOCOL_VERSIONS = ("2025-06-18", "2025-03-26", "2024-11-05")
DEFAULT_TIMEOUT = 300.0                    # секунд на одно действие моста (контракт §5)
KILL_GRACE = 3.0                           # секунд между SIGTERM и SIGKILL по таймауту

# HTTP-транспорт (CONTRACT §5.1).
DEFAULT_HTTP_BIND = "127.0.0.1"
DEFAULT_HTTP_PORT = 1986
HTTP_MAX_BODY = 1024 * 1024                # 1 МБ на запрос: JSON-RPC с параметрами — килобайты
HTTP_BAN_FAILURES = 20                     # неудач с одного IP…
HTTP_BAN_WINDOW = 600.0                    # …за 10 минут…
HTTP_BAN_SECONDS = 600.0                   # …→ бан на 10 минут (тоже 404, а не 429)
HTTP_FAILURE_TABLE_MAX = 10000             # потолок таблицы IP: сканер не должен раздуть память
HTTP_LOCK_WAIT = 5.0                       # ждать config.lock ради статистики вызовов, не дольше
HTTP_BUSY_RETRY_AFTER = 10                 # 503 «замок занят» при первом закреплении адреса (pin_ip):
                                           # через сколько секунд повторить (SEC46-01)
HTTP_KNOWN_IPS_MAX = 10                    # сколько адресов доступа помним, чтобы не слать
                                           # уведомление о «новом адресе» на каждый скачок NAT
# Предел частоты на УДАЧНЫЕ вызовы (MCP_ROTATION §6). Счётчик неудач выше ловит
# подбор пути и токена, но ничего не говорит про доступ, который вошёл законно:
# агент в цикле (или чужой, уже укравший ключ) мог звать мост без всякого предела,
# а каждый вызов — это запуск install.sh под root. Считаем скользящим окном на
# доступ, а не на IP: за адресом стоит NAT, а за доступом — один клиент.
HTTP_RATE_CALLS = 120                      # вызовов с одного доступа…
HTTP_RATE_WINDOW = 60.0                    # …за минуту; сверх того — отказ 429 с Retry-After
HTTP_RATE_RETRY_AFTER = 10                 # сколько просить подождать (секунд)
HTTP_RATE_ALARM_QUIET = 900.0              # событие о всплеске — не чаще раза в 15 минут на доступ
# «Срок на исходе»: одно событие владельцу, пока доступ ещё работает, и одно —
# когда он уже отвечает отказом. Без них доступ просто замолкал, и отличить
# истёкший от сломанного было нечем.
#
# Полоса считается ОТ ВЫДАННОЙ ДЛИТЕЛЬНОСТИ, а не одним числом на все доступы, и
# вот почему. Срок продлевается сам, когда осталось меньше ПОЛОВИНЫ длительности
# (см. GrantStore.touch): половина — это пол, ниже которого запись доступа, пока
# им пользуются, не опускается. Постоянные трое суток этот пол перекрывали: при
# длительности шесть суток и меньше половина сама не больше трёх суток, живой
# доступ попадал в полосу на каждом круге, и тревога била раз в сутки вечно —
# про доступ, вызов которого обслуживался прямо в эту секунду. Текст тревоги при
# этом утверждает обратное: «близкий конец означает одно — этим доступом давно не
# пользовались».
#
# Поэтому полоса лежит ВДВОЕ ниже пола — четверть длительности — и не шире
# прежних трёх суток. Четверть выбрана не на глаз: раз запись опустилась ниже
# неё, значит с того мгновения, когда срок прошёл половину, не было НИ ОДНОГО
# удачного вызова (любой продлил бы срок) — то есть доступ молчит уже не меньше
# четверти длительности. Ровно это тревога и утверждает, и теперь это правда при
# любом сроке, а не только при длинном.
HTTP_EXPIRY_WARN_DAYS = 3                  # верхняя граница полосы, суток…
HTTP_EXPIRY_WARN_TERM_PART = 4             # …но не шире 1/4 выданной длительности
HTTP_EXPIRY_ALARM_QUIET = 86400.0          # не чаще раза в сутки на доступ
HTTP_ALARM_QUIET = 3600.0                  # не чаще раза в час на доступ — тревога о чужом токене
HTTP_ALARM_QUIET_LIVE = 60.0               # …но если заморозить НЕ удалось, доступ жив и клон
                                           # работает дальше: час молчания оставил бы владельца
                                           # с одним сообщением про угон, который не остановлен
# Одноразовый ключ (docs/MCP_ROTATION.md §1 в редакции §11).
HTTP_KEY_HISTORY_MAX = 50                  # отпечатков выданных ключей на доступ: столько назад
                                           # цепочка узнаёт свой ключ и отличает клон от мусора
HTTP_CHAIN_REPLY_MAX = 4 * 1024 * 1024     # предел сохраняемого ответа: повтор обязан вернуть
                                           # тот же ответ, но держать в файле десятки МБ незачем
HTTP_CHAIN_PAR_MAX = 16                    # сколько одновременных запросов одним ключом помним:
                                           # клиент MCP после initialize шлёт три-четыре разом,
                                           # здесь запас вчетверо — но не бесконечность, иначе
                                           # файл состояния рос бы на чужом упорстве
SCOPES = ("read", "write", "admin")
# static — постоянный токен в заголовке (совместимый режим); rolling — одноразовый ключ.
GRANT_MODES = ("static", "rolling")
SECRET_RE = re.compile(r"^[A-Za-z0-9_-]{43}$")   # 32 байта в base64url без «=»
TOKEN_RE = SECRET_RE                             # токен доступа того же вида, что и секрет пути
AGENT_ID_RE = re.compile(r"^a-[a-f0-9]{4,8}$")
# Authorization: Bearer <token>. Схема по RFC 7235 регистронезависима, значение берём широко —
# длину и алфавит решает TOKEN_RE, а сюда попадает и мусор от сканера (его отсечёт сравнение).
BEARER_RE = re.compile(r"^\s*Bearer[ \t]+([\x21-\x7e]{1,512})[ \t]*$", re.IGNORECASE)
# Одноразовый ключ и его номер — отдельными заголовками, а не в Authorization: постоянный токен
# у rolling-доступа остаётся на своём месте, и обе проверки идут независимо друг от друга.
KEY_HEADER = "X-Ga-Key"
NONCE_HEADER = "X-Ga-Nonce"
# Следующий ключ едет ЗАГОЛОВКОМ, а не в теле JSON-RPC (§11.7): тело ответа клиенты MCP пишут в
# свои отладочные журналы целиком, и ключ уезжал бы туда при каждом вызове.
NEXT_KEY_HEADER = "X-Ga-Next-Key"
KEY_RE = SECRET_RE                               # ключ той же длины и того же алфавита
NONCE_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")  # одноразовый номер запроса, придумывает клиент
KEY_HASH_RE = re.compile(r"^[a-f0-9]{64}$")      # sha256 в hex: отпечаток ключа
# Переходник goamnezia-connect (docs/MCP_ROTATION.md §2, §3, §7).
# Плавающий путь: /r-<HMAC-SHA256(rot_seed, "path|<отрезок>")>/mcp, отрезок 60 с, принимаются
# предыдущий, текущий и следующий — худший срок жизни утёкшей ссылки три минуты.
FLOAT_SLOT_SECONDS = 60
HTTP_FLOAT_RE = re.compile(r"^/r-([A-Za-z0-9_-]{43})/mcp/?$")
# Привязка: /a-<sha256("goamnezia-enroll|"+код)>/enroll. Префикс /a- — чтобы nginx пропускал её
# той же location, что и адреса доступов; сам код по сети не едет.
HTTP_ENROLL_RE = re.compile(r"^/a-([A-Za-z0-9_-]{43})/enroll/?$")
ENROLL_BODY_MAX = 4096
KEY_STORAGE_KINDS = ("file", "tpm")
# Прыжок собственных часов сервера больше отрезка — все агенты промахнутся разом (§3).
CLOCK_JUMP_SECONDS = FLOAT_SLOT_SECONDS
CLOCK_ALARM_QUIET = 600.0


def b64url(raw):
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def b64url_decode(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def float_path(rot_seed, slot):
    """Плавающий путь отрезка. Та же формула, что в goamnezia-mcp/connect.py."""
    digest = hmac.new(b64url_decode(rot_seed), ("path|%d" % slot).encode("ascii"), hashlib.sha256).digest()
    return b64url(digest)[:43]


def _boot_clock():
    """Монотонные часы, которые идут и во сне машины (CLOCK_BOOTTIME в Linux).

    time.monotonic() на время приостановки стоит, а календарные часы идут: после паузы
    виртуальной машины (миграция, снимок) разница выглядела бы прыжком календарных часов,
    хотя они не прыгали, — и владелец получил бы ложную тревогу. Где BOOTTIME нет
    (macOS, прочие), остаётся monotonic.
    """
    clock = getattr(time, "CLOCK_BOOTTIME", None)
    if clock is not None:
        try:
            time.clock_gettime(clock)
            return lambda: time.clock_gettime(clock)
        except OSError:
            pass
    return time.monotonic


class ClockWatch(object):
    """Прыжок календарных часов сервера относительно монотонных (§3).

    Сравнение идёт между соседними проверками: медленная подстройка NTP копится днями и
    прыжком не считается, а перевод часов на минуту и больше — считается.
    """

    def __init__(self, wall=time.time, mono=None, threshold=CLOCK_JUMP_SECONDS):
        mono = mono or _boot_clock()
        self.wall = wall
        self.mono = mono
        self.threshold = threshold
        self._lock = threading.Lock()
        self._mark = (wall(), mono())

    def check(self):
        """→ величина прыжка в секундах (со знаком) или 0."""
        with self._lock:
            wall0, mono0 = self._mark
            wall, mono = self.wall(), self.mono()
            self._mark = (wall, mono)
        drift = (wall - wall0) - (mono - mono0)
        return int(drift) if abs(drift) > self.threshold else 0
# Одна запись белого списка адресов: тот же образец, что у ip_list в lib/actions.json и у
# ga_agents_ips_valid. Октеты по значению и без ведущего нуля (010.0.0.1 для ipaddress —
# ошибка разбора, а для bash — восьмеричное 8: «тот же» адрес у двух половин продукта разный),
# префикс 1..32 без нуля (`/0` выглядит как «только мой адрес», а значит «любой»).
ALLOW_IP_RE = re.compile(
    r"^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"
    r"(/([1-9]|[12][0-9]|3[0-2]))?$")
# Единственный законный путь: /a-<43 символа секрета>/mcp. Всё остальное — 404 сайта.
HTTP_PATH_RE = re.compile(r"^/a-([A-Za-z0-9_-]{43})/mcp/?$")
# Тело 404 — байт в байт как у nginx по умолчанию: наш ответ на чужой путь не должен
# отличаться от ответа сайта-маскировки на тот же путь.
NGINX_404 = (b"<html>\r\n<head><title>404 Not Found</title></head>\r\n<body>\r\n"
             b"<center><h1>404 Not Found</h1></center>\r\n<hr><center>nginx</center>\r\n"
             b"</body>\r\n</html>\r\n")

# Коды JSON-RPC 2.0 и MCP.
PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603
RESOURCE_NOT_FOUND = -32002
FORBIDDEN = -32003                          # инструмент вне уровня доступа (CONTRACT §5.1)

# Параметры, чьи значения нельзя писать в аудит-лог, даже если такие появятся в actions.json.
SENSITIVE_PARAM_RE = re.compile(r"(token|secret|pass|privkey|psk|apikey|api_key)", re.IGNORECASE)
# Параметры-ключи профиля: значение у profile-set-param — не для журнала и не для отладочной строки моста (KEENETIC-I1-N,
# N3). Тот же список — GA_AMN_SECRET_PARAMS в lib/amnezia.sh, SECRET_PROFILE_PARAMS в admin-web/server.py. Без учёта
# регистра: в журнал попадает и вызов, который ядро отвергнет.
SECRET_PROFILE_PARAMS = frozenset({"headerprotectionkey"})


def secret_param_value(cli_action, key, value):
    """True — значение value у этого действия и ключа скрывать («***»): параметр-ключ профиля в profile-set-param."""
    return cli_action == "profile-set-param" and str(key or "").strip().lower() in SECRET_PROFILE_PARAMS \
        and str(value if value is not None else "") != ""
# Управляющие символы в аргументах запрещены: значения уходят в argv моста и в строку аудита,
# а перевод строки внутри значения обходит `$` регексов (в Python `$` совпадает и перед
# завершающим \n). Ни один законный идентификатор, порт или домен их не содержит.
CONTROL_CHARS_RE = re.compile(r"[\x00-\x1f\x7f]")
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

# Тексты сервера (ошибки валидации, подсказки). Ключи — на языке GOAMNEZIA_LANG.
T = {
    "err_args_object": {"ru": "arguments должен быть объектом", "en": "arguments must be an object"},
    "err_unknown_tool": {"ru": "Неизвестный инструмент: {name}", "en": "Unknown tool: {name}"},
    "err_unknown_params": {"ru": "Неизвестные параметры: {names}. Допустимые: {allowed}",
                           "en": "Unknown parameters: {names}. Allowed: {allowed}"},
    "err_missing": {"ru": "Не хватает обязательных параметров: {names}",
                    "en": "Missing required parameters: {names}"},
    "err_type": {"ru": "Параметр {name}: ожидается {type}", "en": "Parameter {name}: expected {type}"},
    "err_control": {"ru": "Параметр {name}: управляющие символы и переводы строк недопустимы",
                    "en": "Parameter {name}: control characters and line breaks are not allowed"},
    "err_pattern": {"ru": "Параметр {name}: значение не подходит под шаблон {pattern}",
                    "en": "Parameter {name}: value does not match pattern {pattern}"},
    "err_pattern_broken": {"ru": "Параметр {name}: шаблон в actions.json не поддерживается валидатором",
                           "en": "Parameter {name}: pattern in actions.json is not supported by the validator"},
    "err_enum": {"ru": "Параметр {name}: допустимые значения: {values}",
                 "en": "Parameter {name}: allowed values: {values}"},
    "err_min": {"ru": "Параметр {name}: минимум {limit}", "en": "Parameter {name}: minimum is {limit}"},
    "err_max": {"ru": "Параметр {name}: максимум {limit}", "en": "Parameter {name}: maximum is {limit}"},
    "err_confirm": {"ru": "confirm не совпадает со значением параметра «{name}» — разрушительное действие отклонено",
                    "en": "confirm does not match the value of parameter '{name}' — destructive action rejected"},
    "err_confirm_toolname": {"ru": "confirm должен повторять имя инструмента «{name}»",
                             "en": "confirm must repeat the tool name '{name}'"},
    "err_unknown_prompt": {"ru": "Неизвестная подсказка: {name}", "en": "Unknown prompt: {name}"},
    "err_prompt_args": {"ru": "Не хватает обязательных аргументов подсказки: {names}",
                        "en": "Missing required prompt arguments: {names}"},
    "err_resource_file": {"ru": "Файл ресурса {uri} отсутствует на сервере: {path}",
                          "en": "The file behind resource {uri} is missing on the server: {path}"},
    "err_logs_system": {
        "ru": "Компонент system — это весь журнал машины от root: чужие службы, попытки входа, "
              "всё подряд. Уровню {scope} он не положен. Смотрите журнал нужного компонента "
              "(awg1/awg2/awg3, bot, admin, nginx) или попросите человека.",
        "en": "Component 'system' is the whole machine journal as root: other people's services, "
              "login attempts, everything. Level {scope} does not get it. Read the journal of the "
              "component you need (awg1/awg2/awg3, bot, admin, nginx) or ask the human."},
    "logs_mcp_narrowed": {
        "ru": "Показаны только строки аудита ЭТОГО доступа ({agent}): {kept} из {total}. "
              "Действия человека, бота, панели и других агентов в них не входят.",
        "en": "Only the audit lines of THIS grant ({agent}) are shown: {kept} of {total}. "
              "The human's, the bot's, the panel's and other agents' actions are not included."},
    "err_forbidden": {"ru": "forbidden: инструмент {name} недоступен на уровне доступа «{scope}»",
                      "en": "forbidden: tool {name} is not available at access level '{scope}'"},
    "err_forbidden_prompt": {"ru": "forbidden: подсказка {name} использует инструменты вне уровня доступа «{scope}»",
                             "en": "forbidden: prompt {name} uses tools outside access level '{scope}'"},
    "confirm_desc": {"ru": "Подтверждение необратимого действия: повторите значение параметра «{name}»",
                     "en": "Confirmation of the irreversible action: repeat the value of parameter '{name}'"},
    "confirm_desc_toolname": {"ru": "Подтверждение необратимого действия: повторите имя инструмента",
                              "en": "Confirmation of the irreversible action: repeat the tool name"},
    "destructive_note": {"ru": "Необратимо: нужен параметр confirm = значение «{name}».",
                         "en": "Irreversible: requires confirm = value of '{name}'."},
    "destructive_note_own": {"ru": "Необратимо: confirm — то, что человек подтвердил (см. описание confirm); сервер "
                                   "сверяет его в момент исполнения и при расхождении ничего не меняет.",
                             "en": "Irreversible: confirm is what the human confirmed (see the confirm description); "
                                   "the server checks it at the moment of execution and changes nothing on a mismatch."},
    "png_placeholder": {"ru": "<PNG {size} байт: см. изображение №{n}>", "en": "<PNG {size} bytes: see image #{n}>"},
    "transport_cannot_run": {"ru": "Не удалось запустить мост {bin}: {error}", "en": "Cannot run the bridge {bin}: {error}"},
    "transport_no_json": {"ru": "Мост завершился с кодом {rc}, но не вернул JSON-строку",
                          "en": "The bridge exited with code {rc} but returned no JSON line"},
    "timeout": {"ru": "Мост не ответил за {seconds} с и был остановлен",
                "en": "The bridge did not answer within {seconds} s and was stopped"},
    "prompt_args": {"ru": "Аргументы", "en": "Arguments"},
    "prompt_unset": {"ru": "(не задан)", "en": "(not set)"},
    "prompt_steps": {"ru": "Порядок действий", "en": "Steps"},
    "prompt_generic": {"ru": "Сначала собери картину инструментами только для чтения ({ro}), затем выполни "
                             "нужные действия ({rw}). Перед каждым изменяющим вызовом скажи человеку, что "
                             "именно будет сделано.",
                       "en": "First build the picture with read-only tools ({ro}), then perform the needed "
                             "actions ({rw}). Before every mutating call tell the human what exactly will be done."},
    "prompt_footer": {"ru": "Разрушительные инструменты ({destructive}) необратимы: вызывай их только после "
                            "явного согласия человека и передавай confirm, равный значению первого параметра.",
                      "en": "Destructive tools ({destructive}) are irreversible: call them only after the human's "
                            "explicit consent and pass confirm equal to the value of the first parameter."},
}

# Рецепты подсказок: какие инструменты звать и в каком порядке. Это единственное место, где
# логика зависит от набора инструментов конкретного продукта; шаг с инструментом, которого нет
# в actions.json, молча пропускается. Если в actions.json у подсказки появится поле "steps"
# того же вида ([{"tool": …, "ru": …, "en": …}]), оно имеет приоритет над рецептом отсюда —
# так подсказки можно вынести в JSON целиком и сделать сервер полностью безразличным к продукту.
PROMPT_RECIPES = {
    "onboard_user": {
        "intro": {"ru": "Подключить нового пользователя «{name}», профили: {profiles}.",
                  "en": "Onboard a new user '{name}', profiles: {profiles}."},
        "steps": [
            {"tool": "profiles_list",
             "ru": "убедись, какие профили установлены и запущены; если profiles не задан — пользователь получит все установленные",
             "en": "check which profiles are installed and running; if profiles is not set the user gets all installed ones"},
            {"tool": "users_list",
             "ru": "проверь, что идентификатора «{name}» ещё нет (иначе предложи другой)",
             "en": "make sure the id '{name}' does not exist yet (otherwise suggest another one)"},
            {"tool": "user_add",
             "ru": "создай пользователя: name={name}, profiles={profiles} (если не задан — параметр не передавай); label, quota_gb и days задавай только если человек их назвал (0 = без ограничения)",
             "en": "create the user: name={name}, profiles={profiles} (if not set, omit the parameter); set label, quota_gb and days only if the human named them (0 = unlimited)"},
            {"tool": "user_get_key",
             "ru": "для каждого профиля пользователя: name={name}, profile=<профиль>, format=all — передай человеку .conf, ссылку vpn:// и QR (они приходят изображениями) и назови min_client — минимальную версию приложения Amnezia",
             "en": "for every profile of the user: name={name}, profile=<profile>, format=all — hand over the .conf, the vpn:// link and the QR codes (they arrive as images) and quote min_client, the minimum Amnezia app version"},
            {"tool": "user_show",
             "ru": "проверь карточку: enabled=true, пиры во всех нужных профилях",
             "en": "verify the card: enabled=true, peers in all required profiles"},
        ],
    },
    "diagnose_user": {
        "intro": {"ru": "Пользователь «{name}» не подключается. Собери факты по порядку, потом делай выводы.",
                  "en": "User '{name}' cannot connect. Gather the facts in order, then draw conclusions."},
        "steps": [
            {"tool": "user_show",
             "ru": "существует ли пользователь, enabled, не исчерпаны ли лимит и срок, в каких профилях есть пиры",
             "en": "does the user exist, enabled, quota and expiry not exhausted, which profiles have peers"},
            {"tool": "traffic_report",
             "ru": "последнее рукопожатие и трафик: рукопожатия не было никогда — проблема в ключе или на пути к серверу; было давно — клиент отвалился",
             "en": "last handshake and traffic: never — key or path problem; long ago — the client dropped"},
            {"tool": "profiles_list",
             "ru": "контейнер профиля запущен, порт совпадает с Endpoint в ключе пользователя",
             "en": "the profile container is running and the port matches the Endpoint in the user's key"},
            {"tool": "diagnose",
             "ru": "ip_forward, Docker, занятость портов, MTU, место на диске",
             "en": "ip_forward, Docker, port usage, MTU, disk space"},
            {"tool": "logs_tail",
             "ru": "component=<профиль>, lines=200 — ошибки рукопожатий и отказы по ключу",
             "en": "component=<profile>, lines=200 — handshake errors and key rejections"},
        ],
        "outro": {"ru": "Типовые причины: пользователь выключен → user_enable; лимит или срок → user_set_quota / user_set_expiry; "
                        "приложение старее min_client → обновить клиент; ключ выдан до profile_regen → перевыпустить через user_get_key; "
                        "порт режется провайдером → profile_set_port (443 может держать только один профиль); крайняя мера — "
                        "перевыпуск пира: user_remove_profile (разрушительное, confirm) и user_add_profile.",
                  "en": "Typical causes: user disabled → user_enable; quota or expiry → user_set_quota / user_set_expiry; "
                        "app older than min_client → update the client; key issued before profile_regen → reissue via user_get_key; "
                        "port throttled by the ISP → profile_set_port (443 can be held by one profile only); last resort — "
                        "reissue the peer: user_remove_profile (destructive, confirm) and user_add_profile."},
    },
    "safe_core_update": {
        "intro": {"ru": "Безопасно обновить ядро профиля «{profile}»: бэкап, проверка, обновление, тест рукопожатия.",
                  "en": "Safely update the core of profile '{profile}': backup, check, update, handshake test."},
        "steps": [
            {"tool": "upstream_check",
             "ru": "есть ли обновление для {profile}: в profiles[] найди запись профиля — current_tag → available_tag, update; unsupported[] — новые параметры протокола, которых goAmnezia не знает (предупреди); код unreachable — источники недоступны, повторить позже",
             "en": "is there an update for {profile}: find the profile entry in profiles[] — current_tag → available_tag, update; unsupported[] — new protocol parameters unknown to goAmnezia (warn); code unreachable — sources unreachable, retry later"},
            {"tool": "profiles_list",
             "ru": "состояние до обновления: state, image_tag, число пиров",
             "en": "state before the update: state, image_tag, peer count"},
            {"tool": "traffic_report",
             "ru": "зафиксируй активные рукопожатия — с ними сравнишь после",
             "en": "record the active handshakes — you will compare against them afterwards"},
            {"tool": "backup_create",
             "ru": "бэкап обязателен перед обновлением ядра",
             "en": "a backup is mandatory before a core update"},
            {"tool": "upstream_update",
             "ru": "profile={profile}, confirm={profile} — только после явного согласия человека; действие само делает бэкап, ставит скрипты релиза, тянет образ по дайджесту, пересоздаёт контейнер из копии состояния, проверяет awg show и порт и откатывается при неудаче (update_failed = откат сделан, вмешательства не нужно; update_failed_no_rollback = откат НЕ сделан, контейнер снесён и не поднят, нужен человек; already_current = обновлять нечего); в ответе image_tag, previous_tag, scripts.unsupported[]",
             "en": "profile={profile}, confirm={profile} — only after the human's explicit consent; the action backs up, installs the release scripts, pulls the image by digest, recreates the container from the state copy, verifies awg show and the port and rolls back on failure (update_failed = rolled back, no action needed; update_failed_no_rollback = NOT rolled back, the container is gone and not running, a human is needed; already_current = nothing to update); the reply carries image_tag, previous_tag, scripts.unsupported[]"},
            {"tool": "profiles_list",
             "ru": "после обновления: контейнер running, версия образа новая",
             "en": "after the update: the container is running, the image version is new"},
            {"tool": "traffic_report",
             "ru": "рукопожатия возобновились в течение нескольких минут",
             "en": "handshakes resumed within a few minutes"},
            {"tool": "upstream_rollback",
             "ru": "если рукопожатий нет или контейнер не поднялся: profile={profile}, confirm={profile}",
             "en": "if there are no handshakes or the container did not come up: profile={profile}, confirm={profile}"},
        ],
    },
}


# ---------------------------------------------------------------------------------------------
# Мелкие помощники
# ---------------------------------------------------------------------------------------------

def env_name(suffix):
    """GOAMNEZIA_<suffix> — имя переменной окружения с префиксом продукта."""
    return ENV_PREFIX + "_" + suffix


def pick(d, lang):
    """Выбрать строку на нужном языке из {"ru": …, "en": …}; ru → en → что есть."""
    if isinstance(d, str):
        return d
    if not isinstance(d, dict):
        return ""
    for key in (lang, "ru", "en"):
        if d.get(key):
            return str(d[key])
    for value in d.values():
        if value:
            return str(value)
    return ""


def bilingual(d):
    """«RU / EN» — описание для tools/list: обе версии сразу, как требует контракт §5."""
    if isinstance(d, str):
        return d
    if not isinstance(d, dict):
        return ""
    return " / ".join(str(d[key]) for key in ("ru", "en") if d.get(key))


def msg(lang, key, **kw):
    """Текст сервера по ключу T на языке lang с подстановкой."""
    return pick(T.get(key, {}), lang).format(**kw)


def _parse_utc(text):
    """Строка вида 2026-09-11T13:00:00Z → секунды эпохи; мусор → None."""
    try:
        return calendar.timegm(time.strptime(str(text), "%Y-%m-%dT%H:%M:%SZ"))
    except (ValueError, TypeError):
        return None


def _seconds_left(expires):
    """Сколько секунд осталось до срока; нет срока или мусор → None."""
    when = _parse_utc(expires)
    return None if when is None else when - time.time()


def _utc_plus_days(days):
    """Метка времени через N суток от сейчас, в том же виде, что пишет мост."""
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + days * 86400))


def _term_days_from(raw):
    """Выданная длительность доступа в сутках, выведенная из created→expires.

    Нужна для записей, заведённых до появления поля term_days: без неё
    скользящий срок не работал бы у уже выданных доступов, а именно они и
    страдают от молчаливого истечения.
    """
    a = _parse_utc(raw.get("created"))
    b = _parse_utc(raw.get("expires"))
    if a is None or b is None or b <= a:
        return 0
    return max(1, int(round((b - a) / 86400.0)))


def _expiry_warn_seconds(term_days):
    """Ширина полосы «срок на исходе» для доступа с такой длительностью, в секундах.

    Согласована с правилом продления (HTTP_EXPIRY_WARN_DAYS выше): не шире
    четверти длительности, то есть вдвое ниже половины, на которой срок
    продлевается сам. Длительность неизвестна (term_days = 0 — старая запись, у
    которой её не вывести из created→expires) — остаётся прежний календарный
    порог: без длительности сказать что-то более точное не из чего.
    """
    band = HTTP_EXPIRY_WARN_DAYS * 86400.0
    if term_days > 0:
        band = min(band, term_days * 86400.0 / HTTP_EXPIRY_WARN_TERM_PART)
    return band


# Потолок строки аудита (символов) и обрезка текста для журналов: имя клиента, инструмент, ключи аргументов.
AUDIT_LINE_MAX = 4096
# Срок TLS-рукопожатия одного соединения (секунды): дольше молчащий клиент отключается.
TLS_HANDSHAKE_TIMEOUT = 15


def clip_text(value, limit):
    """Строка без управляющих символов и не длиннее limit — для всего, что пишется в лог и аудит."""
    text = "".join(ch for ch in str(value if value is not None else "") if ch >= " " and ch != "\x7f")
    return text if len(text) <= limit else text[:limit] + "…"


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def fill_placeholders(text, values, unset="<{key}>"):
    """Подставить {name} из values; незаданные — текстом unset, чтобы шаблон не падал."""
    def repl(match):
        key = match.group(1)
        value = values.get(key)
        return str(value) if value not in (None, "") else unset.format(key=key)
    return re.sub(r"\{([A-Za-z_][A-Za-z0-9_]*)\}", repl, text)


class Log(object):
    """Логи только в stderr. Уровни: debug, info (по умолчанию), warn, error, none."""

    LEVELS = {"debug": 10, "info": 20, "warn": 30, "warning": 30, "error": 40, "none": 100, "quiet": 100, "off": 100}

    def __init__(self, level_name, stream):
        self.level = self.LEVELS.get(str(level_name or "info").lower(), 20)
        self.stream = stream
        self.tag = PRODUCT + "-mcp[" + str(os.getpid()) + "]"

    def _emit(self, level, level_name, text):
        if level < self.level:
            return
        try:
            self.stream.write("%s %s %s: %s\n" % (utc_now(), self.tag, level_name, text))
            self.stream.flush()
        except Exception:  # stderr закрыт — терять лог не страшно, а падать нельзя
            pass

    def debug(self, text):
        self._emit(10, "DEBUG", text)

    def info(self, text):
        self._emit(20, "INFO", text)

    def warn(self, text):
        self._emit(30, "WARN", text)

    def error(self, text):
        self._emit(40, "ERROR", text)


class RpcError(Exception):
    """Ошибка JSON-RPC: превращается в {"error": {code, message, data}} на уровне диспетчера."""

    def __init__(self, code, message, data=None):
        Exception.__init__(self, message)
        self.code = code
        self.message = message
        self.data = data


class AdmissionDenied(Exception):
    """HTTP-допуск изменился перед выполнением: транспорт отвечает обычным 404."""


class AdmissionBusy(AdmissionDenied):
    """Первое закрепление адреса не дождалось config.lock или каталога замка ещё нет: это не отказ,
    а «повторите позже» — транспорт отвечает 503 с Retry-After (SEC46-01)."""


# ---------------------------------------------------------------------------------------------
# Настройки из окружения и config.json
# ---------------------------------------------------------------------------------------------

class Settings(object):
    def __init__(self, environ, script_dir):
        self.dir = environ.get(env_name("DIR")) or DEFAULT_DIR
        self.action_bin = environ.get(env_name("ACTION_BIN")) or os.path.join(self.dir, "install.sh")
        self.audit_log = environ.get(env_name("AUDIT_LOG")) or DEFAULT_AUDIT_LOG
        self.log_level = environ.get(env_name("MCP_LOG")) or "info"
        self.config = self._read_config(os.path.join(self.dir, "config.json"))
        # Версия и имя сервера — из config.json продукта; без него 0.0.0 (контракт §5).
        self.version = str(self.config.get("version") or "0.0.0")
        mcp_cfg = self.config.get("mcp") if isinstance(self.config.get("mcp"), dict) else {}
        self.server_name = str(mcp_cfg.get("name") or self.config.get("name") or PRODUCT)
        lang = environ.get(env_name("LANG")) or self.config.get("lang") or "ru"
        self.lang = str(lang).strip().lower()[:2] or "ru"
        self.timeout = self._parse_timeout(environ.get(env_name("MCP_TIMEOUT")))
        self.actions_json = self._find_actions_json(environ.get(env_name("ACTIONS_JSON")), script_dir)
        # HTTP-транспорт (CONTRACT §3.1 mcp{…}, §5.1): доступы агентов и их учёт лежат рядом с
        # config.json; замок — тот же config.lock, что у install.sh, бота и панели, иначе
        # обновление счётчиков вызовов гонялось бы с перевыпуском секрета из меню.
        self.agents_json = environ.get(env_name("AGENTS_JSON")) or os.path.join(self.dir, "agents.json")
        lock_dir = environ.get(env_name("LOCK_DIR")) or "/run/goamnezia"
        self.lock_file = environ.get(env_name("LOCK_FILE")) or os.path.join(lock_dir, "config.lock")
        # Очередь событий бота (docs/BOT.md §6): о первом использовании доступа и о вызове с
        # нового адреса владелец должен узнать сам — так угон становится заметен, а не остаётся
        # строкой в agents.json, куда никто не смотрит. Формат файла тот же, что у ga_notify.
        self.notify_dir = environ.get(env_name("NOTIFY_DIR")) or os.path.join(lock_dir, "notify")
        # Состояние одноразовых цепочек (MCP_ROTATION §11.6). Каталог ПОСТОЯННЫЙ, рядом с
        # config.json, а не в /run: tmpfs чистится при перезагрузке, и после каждого включения
        # сервера цепочка начиналась бы заново — то есть честный агент со своим ключом
        # оказывался бы клоном. Ровно тот исход, ради предотвращения которого всё и делается.
        self.state_dir = environ.get(env_name("STATE_DIR")) or os.path.join(self.dir, "state")
        self.http_enabled = bool(mcp_cfg.get("http_enabled"))
        self.http_port = self._parse_port(mcp_cfg.get("http_port"), DEFAULT_HTTP_PORT)
        self.public_port = self._parse_port(mcp_cfg.get("public_port"), 0)
        origins = mcp_cfg.get("allowed_origins")
        self.allowed_origins = [str(o).strip().lower().rstrip("/") for o in origins if str(o).strip()] \
            if isinstance(origins, list) else []
        self.port_exclusive = bool(mcp_cfg.get("port_exclusive"))

    @staticmethod
    def _parse_port(raw, default):
        try:
            value = int(raw)
        except (TypeError, ValueError):
            return default
        return value if 0 <= value <= 65535 else default

    @staticmethod
    def _read_config(path):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    @staticmethod
    def _parse_timeout(raw):
        if raw in (None, ""):
            return DEFAULT_TIMEOUT
        try:
            value = float(raw)
        except ValueError:
            return DEFAULT_TIMEOUT
        return value if value > 0 else DEFAULT_TIMEOUT

    def _find_actions_json(self, explicit, script_dir):
        """Порядок: переменная → $DIR/lib/actions.json (сервер) → ../lib/actions.json (репозиторий)."""
        if explicit:
            return explicit
        candidates = [
            os.path.join(self.dir, "lib", "actions.json"),
            os.path.normpath(os.path.join(script_dir, "..", "lib", "actions.json")),
        ]
        for path in candidates:
            if os.path.isfile(path):
                return path
        return candidates[0]


# ---------------------------------------------------------------------------------------------
# Каталог: инструменты, ресурсы и подсказки из actions.json
# ---------------------------------------------------------------------------------------------

class ParamSpec(object):
    """Один параметр инструмента: тип из param_types + required/default из действия."""

    def __init__(self, name, ptype, pdef, log):
        self.name = name
        self.type = str(ptype.get("type") or "string")
        self.pattern = ptype.get("pattern")
        self.enum = ptype.get("enum")
        self.minimum = ptype.get("minimum")
        self.maximum = ptype.get("maximum")
        # below_minimum — объяснение границы словами (у mtu: ниже 1280 туннель не поднимется у клиентов с IPv6):
        # отказ им, а не общим «минимум N» — агент передаст человеку причину, а не число.
        self.below_minimum = ptype.get("below_minimum")
        self.description = ptype.get("description")
        self.required = bool(pdef.get("required"))
        self.default = pdef.get("default")
        # stdin: true — значение уходит мосту каналом, а не в argv (ключ человека в
        # user-attach-key: в argv его видно в ps), в аудит — только длина.
        self.stdin = bool(pdef.get("stdin"))
        self.min_length = ptype.get("minLength")
        self.max_length = ptype.get("maxLength")
        self.regex = None
        self.regex_broken = False
        if self.pattern:
            try:
                self.regex = re.compile(self.pattern)
            except re.error as exc:
                # Не валидировать молча нельзя — мост запускается от root. Такой параметр будет
                # отклоняться при вызове, а проблема видна в --check.
                self.regex_broken = True
                log.error("actions.json: шаблон параметра %s не компилируется: %s" % (name, exc))

    def json_schema(self):
        schema = {"type": self.type}
        if self.pattern:
            schema["pattern"] = self.pattern
        if self.enum is not None:
            schema["enum"] = list(self.enum)
        if self.minimum is not None:
            schema["minimum"] = self.minimum
        if self.maximum is not None:
            schema["maximum"] = self.maximum
        if self.min_length is not None:
            schema["minLength"] = self.min_length
        if self.max_length is not None:
            schema["maxLength"] = self.max_length
        if self.default is not None:
            schema["default"] = self.default
        desc = bilingual(self.description)
        if desc:
            schema["description"] = desc
        return schema


class ToolDef(object):
    def __init__(self, cli_name, adef, param_types, log):
        self.cli = cli_name
        self.name = str(adef.get("mcp") or cli_name.replace("-", "_"))
        self.readonly = bool(adef.get("readonly"))
        self.destructive = bool(adef.get("destructive"))
        # secret: true — ответ содержит секрет (ключ пользователя, адрес панели). Такие
        # инструменты закрыты для уровня read даже при readonly: «только чтение» не значит
        # «читать чужие ключи» (PLAN §6.10).
        self.secret = bool(adef.get("secret"))
        self.description = adef.get("description") or {}
        self.params = []
        for pname, pdef in (adef.get("params") or {}).items():
            # "mcp": false у параметра — только для людей (SSH, бот, панель): агенту его нет ни в схеме, ни в вызове
            # (лишнее имя — err_unknown_params), мост берёт значение по умолчанию. page-revoke sub=on перевыпускает
            # подписку, а перевыпуск подписки агентам закрыт (sub-rotate — mcp: null; находка R-2).
            if (pdef or {}).get("mcp") is False:
                continue
            ref = pdef.get("ref", pname)
            ptype = param_types.get(ref)
            if ptype is None:
                log.error("actions.json: действие %s ссылается на неизвестный тип %s" % (cli_name, ref))
                ptype = {"type": "string"}
            self.params.append(ParamSpec(pname, ptype, pdef, log))
        self.first_param = self.params[0].name if self.params else None
        # Своё подтверждение: действие объявляет параметр confirm в каталоге и сверяет его само, в момент исполнения
        # (users-del-bulk: confirm — число людей из предпросмотра, ядро сверяет его с выбранным под замком). Такой
        # confirm — обычный параметр со своим типом и описанием, он уходит мосту; общей сверки «confirm = первый
        # параметр» у него нет — сверять было бы не с чем, кроме него самого.
        self.own_confirm = any(p.name == "confirm" for p in self.params)

    def confirm_description(self, lang):
        if self.first_param:
            return msg(lang, "confirm_desc", name=self.first_param)
        return msg(lang, "confirm_desc_toolname")

    def to_mcp(self):
        properties = {}
        required = []
        for spec in self.params:
            properties[spec.name] = spec.json_schema()
            if spec.required:
                required.append(spec.name)
        description = bilingual(self.description)
        if self.destructive and self.own_confirm:
            if "confirm" not in required:
                required.append("confirm")
            description = (description + " " if description else "") + " / ".join(
                msg(l, "destructive_note_own") for l in ("ru", "en"))
        elif self.destructive:
            properties["confirm"] = {
                "type": "string",
                "description": " / ".join(self.confirm_description(l) for l in ("ru", "en")),
            }
            required.append("confirm")
            target = self.first_param or self.name
            description = (description + " " if description else "") + " / ".join(
                msg(l, "destructive_note", name=target) for l in ("ru", "en"))
        schema = {"type": "object", "properties": properties, "additionalProperties": False}
        if required:
            schema["required"] = required
        return {
            "name": self.name,
            "description": description,
            "inputSchema": schema,
            "annotations": {
                "readOnlyHint": self.readonly,
                "destructiveHint": self.destructive,
                # Идемпотентность: у читающего повтор ничего не меняет по
                # определению. У остальных стоит False честно — «поставить
                # лимит» повторить безопасно, а «добавить пользователя» нет, и
                # различать это по одному флагу нечем. Раньше False стоял у всех
                # подряд, включая чтение: поле просто не заполняли (DEFECTS §5.5).
                "idempotentHint": bool(self.readonly),
                "openWorldHint": False,
            },
        }


class Catalog(object):
    def __init__(self, spec, lang, log, base_dir=None):
        self.lang = lang
        self.log = log
        # Файловые ресурсы ищутся рядом с server.py, а не рядом с actions.json: гайд для агента —
        # часть сервера (/opt/goamnezia-mcp/), а каталог действий живёт в /opt/goamnezia/lib/.
        self.base_dir = base_dir or os.path.dirname(os.path.realpath(__file__))
        self.param_types = spec.get("param_types") or {}
        self.tools = {}          # mcp-имя → ToolDef (порядок как в actions.json)
        self.tools_by_cli = {}
        self.hidden = []         # cli-имена действий с "mcp": null — у моста есть, агенту не показываются
        for cli_name, adef in (spec.get("actions") or {}).items():
            if not isinstance(adef, dict):
                log.error("actions.json: действие %s описано не объектом — пропущено" % cli_name)
                continue
            if self.is_hidden(adef):
                # Контракт §5: "mcp": null — действие намеренно не для агента (доступы агентов,
                # HTTP-транспорт). Его нет ни в tools/list, ни в tools/call: модель, которая не
                # видит инструмента, не станет им «помогать», а вызов по имени получит -32602.
                self.hidden.append(cli_name)
                continue
            tool = ToolDef(cli_name, adef, self.param_types, log)
            if tool.name in self.tools:
                log.error("actions.json: имя инструмента %s повторяется" % tool.name)
                continue
            self.tools[tool.name] = tool
            self.tools_by_cli[cli_name] = tool

        self.resources = []      # [{uri, name, kind: action|file, mime, description, tool | path}]
        for rdef in spec.get("resources") or []:
            res = self._resource(rdef)
            if res is not None:
                self.resources.append(res)
        self.resources_by_uri = dict((r["uri"], r) for r in self.resources)

        self.prompts = []
        for pdef in spec.get("prompts") or []:
            if pdef.get("name"):
                self.prompts.append(pdef)
        self.prompts_by_name = dict((p["name"], p) for p in self.prompts)

    @staticmethod
    def is_hidden(adef):
        """Поле mcp есть, но равно null (или пусто) — не публиковать. Отсутствие поля — другое:
        тогда имя выводится из cli-имени, чтобы actions.json другого продукта серии работал и без mcp."""
        if "mcp" not in adef:
            return False
        value = adef["mcp"]
        return not (isinstance(value, str) and value.strip())

    def _resource(self, rdef):
        """Запись resources из actions.json → внутреннее описание ресурса, или None с записью в лог."""
        if not isinstance(rdef, dict) or not rdef.get("uri"):
            self.log.error("actions.json: ресурс без uri пропущен")
            return None
        uri = str(rdef["uri"])
        if rdef.get("file"):
            path = str(rdef["file"])
            if not os.path.isabs(path):
                path = os.path.normpath(os.path.join(self.base_dir, path))
            if not os.path.isfile(path):
                # Ресурс всё равно остаётся в списке: чтение ответит -32002 с путём, а --check
                # покажет проблему. Выбросить молча — значит спрятать ошибку упаковки ото всех.
                self.log.warn("ресурс %s: файл %s не найден — чтение будет отвечать -32002" % (uri, path))
            return {"uri": uri, "kind": "file", "path": path,
                    "name": str(rdef.get("name") or os.path.basename(path)),
                    "mime": str(rdef.get("mimeType") or "text/plain"),
                    "description": bilingual(rdef.get("description"))}
        action = rdef.get("action")
        tool = self.tools_by_cli.get(action)
        if tool is None:
            why = "скрытое (mcp: null)" if action in self.hidden else "неизвестное"
            self.log.error("actions.json: ресурс %s ссылается на %s действие %s — пропущен" % (uri, why, action))
            return None
        if not tool.readonly:
            # Чтение ресурса не должно ничего менять: клиенты читают ресурсы сами, без человека.
            self.log.error("actions.json: ресурс %s указывает на изменяющее действие %s — пропущен" % (uri, tool.cli))
            return None
        return {"uri": uri, "kind": "action", "tool": tool,
                "name": str(rdef.get("name") or tool.name),
                "mime": "application/json",
                "description": bilingual(tool.description)}

    # --- уровни доступа (CONTRACT §5.1) ------------------------------------------------------

    @staticmethod
    def tool_allowed(tool, scope):
        """Виден ли инструмент на уровне scope. None — stdio через SSH, ограничений нет.

        read — только чтение и без секретов (ключи пользователей, адрес панели): агенту-наблюдателю
        ключи не нужны; write — всё, кроме разрушительного; admin — всё (с confirm).
        """
        if scope is None or scope == "admin":
            return True
        if scope == "write":
            return not tool.destructive
        if scope == "read":
            return tool.readonly and not tool.secret
        return False

    def prompt_steps(self, pdef):
        """Шаги подсказки: из actions.json (steps) или из рецепта сервера."""
        if isinstance(pdef.get("steps"), list):
            return pdef["steps"]
        return PROMPT_RECIPES.get(pdef.get("name"), {}).get("steps") or []

    def prompt_allowed(self, pdef, scope):
        """Подсказка показывается, только если все её инструменты доступны на этом уровне:
        сценарий, половину шагов которого агент выполнить не может, лишь запутает модель."""
        if scope is None or scope == "admin":
            return True
        for step in self.prompt_steps(pdef):
            tool = self.tools.get(step.get("tool"))
            if tool is not None and not self.tool_allowed(tool, scope):
                return False
        return True

    def visible_tools(self, scope=None):
        return [t for t in self.tools.values() if self.tool_allowed(t, scope)]

    # --- списки для протокола --------------------------------------------------------------

    def tools_list(self, scope=None):
        return [tool.to_mcp() for tool in self.visible_tools(scope)]

    def resources_list(self, scope=None):
        out = []
        for res in self.resources:
            # Ресурсы доступны всем уровням (CONTRACT §5.1), но ресурс-обёртка над инструментом
            # с секретом для read скрывается вместе с инструментом — иначе запрет обходился бы чтением.
            if res["kind"] == "action" and not self.tool_allowed(res["tool"], scope):
                continue
            item = {"uri": res["uri"], "name": res["name"], "mimeType": res["mime"]}
            if res.get("description"):
                item["description"] = res["description"]
            out.append(item)
        return out

    def resources_by_kind(self, kind):
        return [r for r in self.resources if r["kind"] == kind]

    def prompts_list(self, scope=None):
        out = []
        for pdef in self.prompts:
            if not self.prompt_allowed(pdef, scope):
                continue
            item = {"name": pdef["name"], "description": bilingual(pdef.get("description"))}
            args = []
            for adef in pdef.get("arguments") or []:
                arg = {"name": str(adef.get("name")), "required": bool(adef.get("required"))}
                ptype = self.param_types.get(arg["name"])
                if ptype and ptype.get("description"):
                    arg["description"] = bilingual(ptype["description"])
                args.append(arg)
            item["arguments"] = args
            out.append(item)
        return out

    def names_by_kind(self, scope=None):
        tools = self.visible_tools(scope)
        ro = [t.name for t in tools if t.readonly]
        destructive = [t.name for t in tools if t.destructive]
        rw = [t.name for t in tools if not t.readonly and not t.destructive]
        return ro, rw, destructive

    # --- валидация -------------------------------------------------------------------------

    def validate_value(self, spec, value, lang):
        """Проверить одно значение по ParamSpec; вернуть нормализованное значение или RpcError."""
        name = spec.name
        if spec.type == "integer":
            if isinstance(value, bool) or not isinstance(value, (int, float)) or \
                    (isinstance(value, float) and not value.is_integer()):
                raise RpcError(INVALID_PARAMS, msg(lang, "err_type", name=name, type="integer"), {"param": name})
            value = int(value)
        elif spec.type == "number":
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise RpcError(INVALID_PARAMS, msg(lang, "err_type", name=name, type="number"), {"param": name})
        elif spec.type == "boolean":
            if not isinstance(value, bool):
                raise RpcError(INVALID_PARAMS, msg(lang, "err_type", name=name, type="boolean"), {"param": name})
        else:
            if not isinstance(value, str):
                raise RpcError(INVALID_PARAMS, msg(lang, "err_type", name=name, type="string"), {"param": name})
            # Текст для stdin (ключ из .conf) многострочный по природе: перевод строки и
            # табуляция там законны, прочие управляющие символы — нет. В argv их не пускаем никогда.
            checked = value.replace("\n", "").replace("\r", "").replace("\t", "") if spec.stdin else value
            if CONTROL_CHARS_RE.search(checked):
                raise RpcError(INVALID_PARAMS, msg(lang, "err_control", name=name), {"param": name})
            if spec.max_length is not None and len(value) > spec.max_length:
                raise RpcError(INVALID_PARAMS, msg(lang, "err_max", name=name, limit=spec.max_length), {"param": name})
            if spec.min_length is not None and len(value) < spec.min_length:
                raise RpcError(INVALID_PARAMS, msg(lang, "err_min", name=name, limit=spec.min_length), {"param": name})
            if spec.regex_broken:
                raise RpcError(INVALID_PARAMS, msg(lang, "err_pattern_broken", name=name), {"param": name})
            # Семантика pattern в JSON Schema — поиск, не полное совпадение; наши шаблоны сами якорные.
            if spec.regex is not None and spec.regex.search(value) is None:
                raise RpcError(INVALID_PARAMS, msg(lang, "err_pattern", name=name, pattern=spec.pattern),
                               {"param": name, "pattern": spec.pattern})
        if spec.enum is not None and value not in spec.enum:
            raise RpcError(INVALID_PARAMS, msg(lang, "err_enum", name=name, values=", ".join(map(str, spec.enum))),
                           {"param": name, "enum": list(spec.enum)})
        if spec.minimum is not None and isinstance(value, (int, float)) and value < spec.minimum:
            raise RpcError(INVALID_PARAMS, pick(spec.below_minimum, lang)
                           or msg(lang, "err_min", name=name, limit=spec.minimum), {"param": name})
        if spec.maximum is not None and isinstance(value, (int, float)) and value > spec.maximum:
            raise RpcError(INVALID_PARAMS, msg(lang, "err_max", name=name, limit=spec.maximum), {"param": name})
        return value

    def validate_call(self, tool, arguments, lang):
        """Полная проверка tools/call: вернуть (чистые аргументы, argv моста)."""
        if arguments is None:
            arguments = {}
        if not isinstance(arguments, dict):
            raise RpcError(INVALID_PARAMS, msg(lang, "err_args_object"))
        allowed = [p.name for p in tool.params] + (["confirm"] if tool.destructive and not tool.own_confirm else [])
        unknown = [k for k in arguments if k not in allowed]
        if unknown:
            raise RpcError(INVALID_PARAMS, msg(lang, "err_unknown_params", names=", ".join(sorted(unknown)),
                                               allowed=", ".join(allowed) or "—"), {"unknown": sorted(unknown)})
        clean = {}
        missing = []
        for spec in tool.params:
            value = arguments.get(spec.name)
            if value is None:           # null считаем «не передано»: модели часто шлют null для необязательных
                if spec.required or (spec.name == "confirm" and tool.destructive):
                    missing.append(spec.name)
                continue
            clean[spec.name] = self.validate_value(spec, value, lang)
        if tool.destructive and not tool.own_confirm:
            confirm = arguments.get("confirm")
            if confirm is None:
                missing.append("confirm")
        if missing:
            raise RpcError(INVALID_PARAMS, msg(lang, "err_missing", names=", ".join(missing)), {"missing": missing})
        if tool.destructive and not tool.own_confirm:
            # Сверка confirm с первым параметром по строковому представлению: то, что уйдёт в argv.
            confirm = arguments.get("confirm")
            if tool.first_param and tool.first_param in clean:
                expected = self.cli_value(clean[tool.first_param])
                if not isinstance(confirm, str) or confirm != expected:
                    raise RpcError(INVALID_PARAMS, msg(lang, "err_confirm", name=tool.first_param),
                                   {"param": "confirm", "expected_param": tool.first_param})
            elif not isinstance(confirm, str) or confirm != tool.name:
                raise RpcError(INVALID_PARAMS, msg(lang, "err_confirm_toolname", name=tool.name),
                               {"param": "confirm"})
            clean["confirm"] = confirm
        argv = []
        for spec in tool.params:
            if spec.name in clean and not spec.stdin:
                # Подчёркивания → дефисы: quota_gb → --quota-gb (соглашение моста из actions.json).
                argv.append("--%s=%s" % (spec.name.replace("_", "-"), self.cli_value(clean[spec.name])))
        return clean, argv

    @staticmethod
    def cli_value(value):
        if isinstance(value, bool):
            return "true" if value else "false"
        return str(value)

    # --- подсказки -------------------------------------------------------------------------

    def render_prompt(self, pdef, arguments, lang):
        """Текст подсказки на языке lang: описание, аргументы, шаги по рецепту, напоминание о confirm."""
        name = pdef["name"]
        recipe = PROMPT_RECIPES.get(name, {})
        steps = self.prompt_steps(pdef)
        intro = pdef.get("intro") if isinstance(pdef.get("intro"), dict) else recipe.get("intro")
        outro = pdef.get("outro") if isinstance(pdef.get("outro"), dict) else recipe.get("outro")

        unset = msg(lang, "prompt_unset")
        lines = []
        description = pick(pdef.get("description"), lang)
        lines.append(fill_placeholders(pick(intro, lang), arguments, unset) if intro else description)
        declared = [str(a.get("name")) for a in pdef.get("arguments") or []]
        if declared:
            shown = ["%s=%s" % (a, arguments.get(a) if arguments.get(a) not in (None, "") else unset) for a in declared]
            lines.append("%s: %s" % (msg(lang, "prompt_args"), "; ".join(shown)))
        lines.append("")
        lines.append(msg(lang, "prompt_steps") + ":")
        n = 0
        for step in steps:
            tool_name = step.get("tool")
            if tool_name not in self.tools:
                self.log.warn("подсказка %s: инструмент %s отсутствует в actions.json, шаг пропущен" % (name, tool_name))
                continue
            note = step.get("note") if isinstance(step.get("note"), dict) else {"ru": step.get("ru"), "en": step.get("en")}
            n += 1
            lines.append("%d. %s — %s" % (n, tool_name, fill_placeholders(pick(note, lang), arguments, unset)))
        if n == 0:
            ro, rw, destructive = self.names_by_kind()
            lines.append(msg(lang, "prompt_generic", ro=", ".join(ro) or "—", rw=", ".join(rw + destructive) or "—"))
        if outro:
            lines.append("")
            lines.append(fill_placeholders(pick(outro, lang), arguments, unset))
        destructive_names = ", ".join(self.names_by_kind()[2]) or "—"
        lines.append("")
        lines.append(msg(lang, "prompt_footer", destructive=destructive_names))
        return "\n".join(lines)

    def instructions(self, server_name, version, scope=None):
        """Текст для initialize.instructions (контракт §5: 10–15 строк, RU и EN).

        Что за сервер, где полный гайд, с чего начать, правило confirm, подсказки, ключи. Все
        имена — из каталога: инструменты «с чего начать» — это действия за ресурсами (статус,
        профили…), гайд — файловые ресурсы, сценарии — подсказки. Продукт в текст не зашит.
        По HTTP с уровнем доступа перечисляются только видимые агенту инструменты и подсказки.
        """
        ro, rw, destructive = self.names_by_kind(scope)
        start = [r["tool"].name for r in self.resources_by_kind("action") if self.tool_allowed(r["tool"], scope)]
        start_uris = [r["uri"] for r in self.resources_by_kind("action") if self.tool_allowed(r["tool"], scope)]
        guides = ["%s (%s)" % (r["uri"], r["mime"]) for r in self.resources_by_kind("file")]
        prompts = [p["name"] for p in self.prompts if self.prompt_allowed(p, scope)]
        j = lambda items: ", ".join(items) or "—"   # noqa: E731 — короче, чем четыре вызова join

        ru = ["MCP-сервер {name} {ver}: типизированный доступ к действиям сервера через штатный мост "
              "(install.sh --action). Ответ каждого инструмента — JSON моста: status (success|error), message, "
              "code и данные; при status=error результат помечен isError."]
        en = ["MCP server {name} {ver}: typed access to server actions through the standard bridge "
              "(install.sh --action). Every tool returns the bridge JSON: status (success|error), message, code and "
              "data; on status=error the result is flagged isError."]
        if guides:
            ru.append("Полный гайд для агента — ресурс {guides}: прочитай его (resources/read) перед первым "
                      "изменяющим вызовом. В нём порядок операций для типовых задач, коды ошибок моста и что с "
                      "ними делать, ограничения продукта, примеры вызовов.")
            en.append("The full agent guide is the resource {guides}: read it (resources/read) before the first "
                      "mutating call. It holds the step order for typical tasks, bridge error codes and what to do "
                      "about them, product limits and call examples.")
        if start:
            ru.append("С чего начать: собери картину сервера инструментами {start} (те же данные доступны как "
                      "ресурсы {uris}). Не меняй то, чего не видел.")
            en.append("Where to start: build the picture with {start} (the same data is available as resources "
                      "{uris}). Do not change what you have not looked at.")
        ru.append("Инструменты только для чтения: {ro}. Изменяющие: {rw}. Разрушительные и необратимые: {destr} — "
                  "каждому нужен параметр confirm, равный значению первого параметра (например confirm=name); "
                  "подставляй его только после явного согласия человека на это конкретное действие.")
        en.append("Read-only tools: {ro}. Mutating: {rw}. Destructive and irreversible: {destr} — each requires the "
                  "confirm parameter equal to the value of the first parameter (e.g. confirm=name); pass it only "
                  "after the human's explicit consent to that specific action.")
        if scope in ("read", "write"):
            ru.append("Твой уровень доступа по HTTP — «{scope}»: инструменты вне уровня не показаны, вызов по имени "
                      "ответит ошибкой forbidden; расширить доступ может только человек из меню сервера.")
            en.append("Your HTTP access level is '{scope}': tools outside it are hidden and a call by name answers "
                      "forbidden; only a human can widen the grant from the server menu.")
        if prompts:
            ru.append("Подсказки-сценарии (prompts/get): {prompts} — готовый порядок шагов для типовых задач; "
                      "когда задача совпадает, следуй им.")
            en.append("Prompt scenarios (prompts/get): {prompts} — a ready step order for typical tasks; follow "
                      "them when the task matches.")
        ru.append("Приватные ключи и конфиги возвращают только инструменты выдачи ключей — не переноси их дальше "
                  "без явной просьбы. Все вызовы пишутся в аудит-лог сервера.")
        en.append("Private keys and configs come only from the key-issuing tools — do not forward them without an "
                  "explicit request. Every call is written to the server audit log.")
        values = dict(name=server_name, ver=version, ro=j(ro), rw=j(rw), destr=j(destructive),
                      start=j(start), uris=j(start_uris), guides=j(guides), prompts=j(prompts), scope=scope or "")
        return "\n".join(line.format(**values) for line in ru) + "\n\n" + "\n".join(line.format(**values) for line in en)


def load_catalog(path, lang, log, base_dir=None):
    with open(path, "r", encoding="utf-8") as fh:
        spec = json.load(fh)
    if not isinstance(spec, dict) or not isinstance(spec.get("actions"), dict):
        raise ValueError("actions.json: ожидается объект с полем actions")
    return Catalog(spec, lang, log, base_dir)


# ---------------------------------------------------------------------------------------------
# Мост: запуск install.sh --action и разбор ответа
# ---------------------------------------------------------------------------------------------

class Bridge(object):
    def __init__(self, bin_path, timeout, lang, log):
        self.bin = bin_path
        self.timeout = timeout
        self.lang = lang
        self.log = log

    @staticmethod
    def loggable(cli_action, cmd):
        """Команда моста для отладочной строки: значение параметра-ключа (--value= у profile-set-param с
        --key=HeaderProtectionKey) — «***» (KEENETIC-I1-N, N3)."""
        key = next((c[len("--key="):] for c in cmd if str(c).startswith("--key=")), "")
        val = next((c[len("--value="):] for c in cmd if str(c).startswith("--value=")), "")
        if not secret_param_value(cli_action, key, val):
            return list(cmd)
        return ["--value=***" if str(c).startswith("--value=") else c for c in cmd]

    def run(self, cli_action, argv, who=None, stdin_text=None):
        """Выполнить действие; всегда вернуть dict со status — ошибки запуска тоже как JSON моста.
        stdin_text — секрет, который мост читает каналом (ключ в user-attach-key), а не из argv."""
        cmd = [self.bin, "--action=" + cli_action, "--json"] + list(argv)
        self.log.debug("bridge: " + " ".join(self.loggable(cli_action, cmd)))
        env = dict(os.environ)
        env.setdefault(env_name("CALLER"), "mcp")     # подсказка мосту, кто зовёт (для его аудита)
        # Действующее лицо для аудита МОСТА: модули пишут ${GOAMNEZIA_WHO:-ssh}, и без этой строки
        # каждая правка агента ложилась в журнал как «ssh» — то есть приписывалась владельцу,
        # сидящему за терминалом. Подставляем всегда, а не setdefault: имя, доставшееся от чужого
        # окружения, было бы ровно тем же подлогом.
        env[env_name("WHO")] = who or "mcp"
        try:
            # stdin=DEVNULL: мост не должен читать наш протокольный stdin (confirm читает /dev/tty,
            # но с --action диалогов быть не должно — страхуемся). Своя сессия процессов — чтобы по
            # таймауту убить и мост, и всё, что он породил (docker, jq, sleep), а не одного родителя.
            proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL if stdin_text is None else subprocess.PIPE,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True, env=env)
        except (OSError, ValueError) as exc:
            return {"status": "error", "code": "transport",
                    "message": msg(self.lang, "transport_cannot_run", bin=self.bin, error=str(exc)),
                    "action": cli_action}
        timed_out = False
        payload = None if stdin_text is None else stdin_text.encode("utf-8")
        try:
            out, err = proc.communicate(input=payload, timeout=self.timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            self._kill_group(proc)
            try:
                out, err = proc.communicate(timeout=KILL_GRACE)
            except subprocess.TimeoutExpired:
                out, err = b"", b""
        out_text = out.decode("utf-8", "replace")
        err_text = ANSI_RE.sub("", err.decode("utf-8", "replace"))
        if err_text.strip():
            self.log.debug("bridge stderr (%s): %s" % (cli_action, self._tail(err_text, 20)))
        if timed_out:
            self.log.warn("bridge: действие %s превысило таймаут %.0f с и остановлено" % (cli_action, self.timeout))
            return {"status": "error", "code": "timeout",
                    "message": msg(self.lang, "timeout", seconds=int(self.timeout)),
                    "action": cli_action, "timeout_s": self.timeout, "stderr_tail": self._tail(err_text, 10)}
        response, trailing = self._last_json_line(out_text)
        if response is None:
            self.log.warn("bridge: действие %s не вернуло JSON (код %s)" % (cli_action, proc.returncode))
            return {"status": "error", "code": "transport",
                    "message": msg(self.lang, "transport_no_json", rc=proc.returncode),
                    "action": cli_action, "exit_code": proc.returncode,
                    "stdout_tail": self._tail(out_text, 10), "stderr_tail": self._tail(err_text, 10)}
        if trailing:
            self.log.warn("bridge: после JSON-строки действия %s есть ещё %d строк stdout — нарушение контракта §0 п.3"
                          % (cli_action, trailing))
        if proc.returncode != 0 and response.get("status") == "success":
            self.log.warn("bridge: код возврата %s при status=success у %s" % (proc.returncode, cli_action))
        return response

    @staticmethod
    def _last_json_line(text):
        """Последняя строка stdout, которая разбирается как JSON-объект.

        Контракт гарантирует JSON только последней строкой, но терпимость к пустым строкам и
        случайному хвосту («\\r», прощальная строка trap-обработчика) делает мост надёжнее без
        риска взять чужой JSON: идём с конца и берём первый же объект; если после него были
        непустые строки, сообщаем об этом в лог (это нарушение контракта, но не повод ронять вызов).
        """
        lines = text.splitlines()
        trailing = 0
        for line in reversed(lines):
            stripped = line.strip()
            if not stripped:
                continue
            if stripped[0] == "{":
                try:
                    obj = json.loads(stripped)
                except ValueError:
                    obj = None
                if isinstance(obj, dict):
                    return obj, trailing
            trailing += 1
        return None, trailing

    @staticmethod
    def _tail(text, n_lines, limit=2000):
        lines = [l for l in text.splitlines() if l.strip()]
        tail = "\n".join(lines[-n_lines:])
        return tail[-limit:]

    def _kill_group(self, proc):
        """SIGTERM всей группе (trap'ы моста успеют прибраться), через KILL_GRACE — SIGKILL."""
        for sig, wait in ((signal.SIGTERM, KILL_GRACE), (signal.SIGKILL, KILL_GRACE)):
            try:
                os.killpg(proc.pid, sig)
            except (ProcessLookupError, PermissionError, OSError):
                return
            try:
                proc.wait(timeout=wait)
                return
            except subprocess.TimeoutExpired:
                continue


# ---------------------------------------------------------------------------------------------
# Аудит
# ---------------------------------------------------------------------------------------------

class Audit(object):
    """Одна строка на вызов: время, mcp, инструмент, действие, параметры без секретов, статус.

    Кто и откуда — приходит от Server при каждой записи: по stdio это клиент из initialize и
    адрес SSH-сессии (from=<ip>), по HTTP — метка доступа agent=<id> и IP агента. Сам объект
    состояния сессии не держит: в HTTP-режиме он один на все потоки.
    """

    def __init__(self, path, log):
        self.path = path
        self.log = log
        self.failed = False
        ssh = os.environ.get("SSH_CONNECTION", "").split()
        self.peer = ssh[0] if ssh else "local"

    @staticmethod
    def scrub(args, cli_action=None):
        clean = {}
        for key, value in (args or {}).items():
            clean[key] = "***" if SENSITIVE_PARAM_RE.search(key) else value
        if secret_param_value(cli_action, clean.get("key"), clean.get("value")):
            clean["value"] = "***"
        return clean

    def write(self, kind, tool, cli_action, args, status, code, ms, client="-", origin=None,
              agent=None):
        # Одна строка — один объект JSON: тот же формат, что у ядра и панели
        # (CONTRACT §7.1). Раньше здесь был свободный текст, и в одном файле
        # лежали три разных формата (DEFECTS §2.2). stage=call: это запись о
        # ПРОСЬБЕ — что вызвали и чем ответили; о случившемся на сервере пишет
        # само ядро строкой stage=effect.
        # Отклонённый вызов — только имена и размеры аргументов: в отказ приходит что угодно, и сырые
        # значения раздували журнал (находка аудита безопасности 25.09.2026). У принятого — как было.
        params = self.scrub(args, cli_action)
        if status == "rejected":
            params = {clip_text(k, 40): "<%s %d>" % (type(v).__name__, len(json.dumps(v, ensure_ascii=False)))
                      for k, v in list((args or {}).items())[:20]}
        rec = {"ts": utc_now(), "iface": "mcp", "stage": "call", "kind": kind,
               "tool": clip_text(tool, 80), "action": clip_text(cli_action, 80), "params": params,
               "status": status, "code": code or "", "ms": ms, "client": clip_text(client, 100),
               "origin": origin or ("from=%s" % self.peer)}
        if agent:
            # Отдельным полем, а не только меткой в origin: сужение журнала по
            # доступу разбирает JSON, а не ищет подстроку.
            rec["agent"] = agent
        line = json.dumps(rec, ensure_ascii=False, sort_keys=True) + "\n"
        if len(line) > AUDIT_LINE_MAX:
            # Жёсткий потолок строки: принятый вызов с огромным значением не должен съесть диск.
            rec["params"] = {"_truncated": True, "_len": len(line)}
            line = json.dumps(rec, ensure_ascii=False, sort_keys=True) + "\n"
        try:
            fd = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            try:
                os.write(fd, line.encode("utf-8"))
            finally:
                os.close(fd)
        except OSError as exc:
            # Аудит важен, но не важнее работоспособности: один раз предупреждаем и продолжаем.
            if not self.failed:
                self.failed = True
                self.log.warn("аудит-лог %s недоступен: %s" % (self.path, exc))


# ---------------------------------------------------------------------------------------------
# Сервер JSON-RPC / MCP
# ---------------------------------------------------------------------------------------------

class Server(object):
    NOTIFICATIONS = ("notifications/initialized", "notifications/cancelled",
                     "notifications/progress", "notifications/roots/list_changed")

    def __init__(self, settings, catalog, bridge, audit, log, scope=None, agent_id=None, origin=None, client="-"):
        self.settings = settings
        self.catalog = catalog
        self.bridge = bridge
        self.audit = audit
        self.log = log
        self.lang = settings.lang
        self.initialized = False
        # Уровень доступа и метка доступа — только по HTTP (CONTRACT §5.1): по stdio через SSH
        # ограничений нет (scope None), в аудит идёт адрес SSH-сессии. По HTTP экземпляр Server
        # создаётся на каждый запрос: сервер без состояния, Mcp-Session-Id не нужен.
        self.scope = scope if scope in SCOPES else None
        self.agent_id = agent_id
        self.origin = origin
        self.client = client
        self.before_execute = None
        self._admission_done = False
        self.methods = {
            "initialize": self.m_initialize,
            "ping": self.m_ping,
            "tools/list": self.m_tools_list,
            "tools/call": self.m_tools_call,
            "resources/list": self.m_resources_list,
            "resources/read": self.m_resources_read,
            "resources/templates/list": self.m_resources_templates_list,
            "prompts/list": self.m_prompts_list,
            "prompts/get": self.m_prompts_get,
        }

    # --- разбор строки и диспетчер ----------------------------------------------------------

    def handle_line(self, raw, allow_batch=True):
        """Одна строка stdin → список ответов (0, 1 или, для пакета, несколько).

        allow_batch=False — транспорт HTTP: пакет там — обход лимита частоты и обещания «украденный
        ключ = один вызов» (лимит и поворот ключа считаются на HTTP-запрос, а пакет — тысячи вызовов в
        одном; находка аудита безопасности 25.09.2026). Протокол 2025-06-18 пакеты и так убрал."""
        try:
            text = raw.decode("utf-8")
            message = json.loads(text)
        except (UnicodeDecodeError, ValueError) as exc:
            return [self._error_response(None, PARSE_ERROR, "Parse error: %s" % exc)]
        if isinstance(message, list) and not allow_batch:
            return [self._error_response(None, INVALID_REQUEST,
                                         "Invalid Request: batch requests are not supported over HTTP")]
        if isinstance(message, list):
            # Пакеты убраны из протокола 2025-06-18, но клиенты 2025-03-26 могут их слать —
            # обработать дешевле, чем отвергать.
            if not message:
                return [self._error_response(None, INVALID_REQUEST, "Invalid Request: empty batch")]
            responses = [self.handle_message(item) for item in message]
            responses = [r for r in responses if r is not None]
            return [responses] if responses else []
        response = self.handle_message(message)
        return [response] if response is not None else []

    def handle_message(self, message):
        if not isinstance(message, dict):
            return self._error_response(None, INVALID_REQUEST, "Invalid Request: not an object")
        is_request = "id" in message
        msg_id = message.get("id")
        method = message.get("method")
        if method is None:
            if "result" in message or "error" in message:
                return None      # ответ на запрос сервера — мы запросов не шлём, игнорируем
            return self._error_response(msg_id, INVALID_REQUEST, "Invalid Request: missing method")
        if message.get("jsonrpc") != "2.0" or not isinstance(method, str):
            return self._error_response(msg_id, INVALID_REQUEST, "Invalid Request: jsonrpc must be \"2.0\"")
        params = message.get("params")
        if params is None:
            params = {}
        if not is_request:
            if method in self.NOTIFICATIONS:
                self._admit_execution()
                if method == "notifications/initialized":
                    self.initialized = True
                self.log.debug("notification: " + method)
            else:
                self.log.debug("unknown notification ignored: " + method)
            return None
        if not isinstance(params, dict):
            return self._error_response(msg_id, INVALID_PARAMS, "Invalid params: params must be an object")
        handler = self.methods.get(method)
        if handler is None:
            return self._error_response(msg_id, METHOD_NOT_FOUND, "Method not found: " + method)
        try:
            # Эти методы сначала проверяют свой scope/аргументы: отказ не должен закреплять IP.
            if method not in ("tools/call", "resources/read", "prompts/get"):
                self._admit_execution()
            result = handler(params)
        except AdmissionDenied:
            raise
        except RpcError as exc:
            return self._error_response(msg_id, exc.code, exc.message, exc.data)
        except Exception as exc:  # ни одна ошибка не должна уронить сессию
            self.log.error("%s: %s\n%s" % (method, exc, traceback.format_exc()))
            return self._error_response(msg_id, INTERNAL_ERROR, "Internal error: %s" % exc)
        return {"jsonrpc": "2.0", "id": msg_id, "result": result}

    def _admit_execution(self):
        if not self._admission_done:
            if self.before_execute is not None:
                self.before_execute()
            self._admission_done = True

    @staticmethod
    def _error_response(msg_id, code, message, data=None):
        error = {"code": code, "message": message}
        if data is not None:
            error["data"] = data
        return {"jsonrpc": "2.0", "id": msg_id, "error": error}

    # --- методы MCP ------------------------------------------------------------------------

    def _who(self):
        """Действующее лицо для аудита моста — договорный формат `mcp:<a-xxxx>`.

        По HTTP лицо известно поимённо: это доступ агента. По stdio доступов нет вовсе — за
        сервером стоит владелец по SSH, и честное имя здесь просто `mcp`: соврать «ssh» значило
        бы стереть разницу между «владелец сделал руками» и «сделала модель».
        """
        return ("mcp:%s" % self.agent_id) if self.agent_id else "mcp"

    def _audit(self, kind, tool, cli_action, args, status, code, ms):
        self.audit.write(kind, tool, cli_action, args, status, code, ms, client=self.client,
                         origin=self.origin, agent=self.agent_id)

    def m_initialize(self, params):
        requested = params.get("protocolVersion")
        version = requested if requested in SUPPORTED_PROTOCOL_VERSIONS else PROTOCOL_VERSION
        client = params.get("clientInfo") if isinstance(params.get("clientInfo"), dict) else {}
        # Имя клиента уходит в каждую строку аудита и в лог: без обрезки 100 КБ в clientInfo превращали
        # сотню отказов в гигабайты журнала (находка аудита безопасности 25.09.2026).
        self.client = "%s/%s" % (clip_text(client.get("name", "?"), 60), clip_text(client.get("version", "?"), 30))
        self.log.info("initialize: client %s, protocol %s -> %s%s" % (
            self.client, requested, version, (" (agent %s, %s)" % (self.agent_id, self.scope)) if self.agent_id else ""))
        return {
            "protocolVersion": version,
            "capabilities": {
                "tools": {"listChanged": False},
                "resources": {"subscribe": False, "listChanged": False},
                "prompts": {"listChanged": False},
            },
            "serverInfo": {"name": self.settings.server_name, "version": self.settings.version},
            "instructions": self.catalog.instructions(self.settings.server_name, self.settings.version, self.scope),
        }

    def m_ping(self, params):
        return {}

    def m_tools_list(self, params):
        return {"tools": self.catalog.tools_list(self.scope)}

    def m_tools_call(self, params):
        name = params.get("name")
        tool = self.catalog.tools.get(name) if isinstance(name, str) else None
        if tool is None:
            raise RpcError(INVALID_PARAMS, msg(self.lang, "err_unknown_tool", name=str(name)))
        arguments = params.get("arguments")
        if not self.catalog.tool_allowed(tool, self.scope):
            # Инструмент существует, но не для этого уровня: -32003, а не «неизвестный инструмент» —
            # модели важно понять, что расширить доступ может только человек. Попытка — в аудит.
            self._audit("call", tool.name, tool.cli, arguments if isinstance(arguments, dict) else {},
                        "rejected", "forbidden", 0)
            raise RpcError(FORBIDDEN, msg(self.lang, "err_forbidden", name=tool.name, scope=self.scope),
                           {"tool": tool.name, "scope": self.scope})
        try:
            clean, argv = self.catalog.validate_call(tool, arguments, self.lang)
        except RpcError as exc:
            # Отклонённые вызовы тоже в аудит: попытка разрушительного без confirm — событие безопасности.
            self._audit("call", tool.name, tool.cli, arguments if isinstance(arguments, dict) else {},
                        "rejected", "invalid_params", 0)
            raise exc
        self._guard_logs(tool, clean, arguments)
        self._admit_execution()
        stdin_text = None
        for spec in tool.params:
            if spec.stdin and spec.name in clean:
                stdin_text = clean[spec.name]
                # В аудит — длина, а не сам ключ.
                clean = dict(clean)
                clean[spec.name] = "<%d chars>" % len(stdin_text)
        started = time.time()
        response = self.bridge.run(tool.cli, argv, who=self._who(), stdin_text=stdin_text)
        stdin_text = None
        ms = int((time.time() - started) * 1000)
        status = str(response.get("status", "?"))
        self._audit("call", tool.name, tool.cli, clean, status, response.get("code"), ms)
        self.log.info("tools/call %s -> %s (%d ms)" % (tool.name, status, ms))
        return self.tool_result(self._narrow_logs(tool, clean, response))

    # --- уровень read и журналы (DEFECTS §1d.2) --------------------------------------------
    # Инструмент logs_tail помечен readonly, поэтому попадал в уровень read целиком. А внутри
    # у него два компонента, которые уровню «наблюдатель» не принадлежат:
    #   system — весь журнал машины от root: чужие службы, ssh, sudo, попытки входа;
    #   mcp    — ВЕСЬ аудит-лог, то есть действия владельца, бота, панели и ВСЕХ других агентов,
    #            хотя руководство обещает агенту «аудит твоих же вызовов».
    # Через SSH (stdio) сужения нет: там за клавиатурой человек с root, и прятать от него
    # собственный журнал бессмысленно. Сужение включается только для доступа по HTTP.

    def _guard_logs(self, tool, clean, arguments):
        """system — только уровню admin: до запуска моста, чтобы журнал даже не читался."""
        if self.agent_id is None or tool.cli != "logs-tail":
            return
        if str(clean.get("component") or "") != "system" or self.scope == "admin":
            return
        self._audit("call", tool.name, tool.cli, arguments if isinstance(arguments, dict) else {},
                    "rejected", "forbidden", 0)
        raise RpcError(FORBIDDEN, msg(self.lang, "err_logs_system", scope=self.scope),
                       {"tool": tool.name, "scope": self.scope, "component": "system"})

    def _line_is_mine(self, line, mark):
        """Строка журнала принадлежит ЭТОМУ доступу.

        Журнал теперь построчный JSON: сверяем поле agent — точно и без догадок.
        Старые строки свободного текста (файл переживает обновление) опознаём
        прежним правилом по метке origin.
        """
        try:
            rec = json.loads(line)
        except Exception:
            rec = None
        if isinstance(rec, dict):
            if rec.get("agent"):
                return rec.get("agent") == self.agent_id
            return mark in str(rec.get("origin") or "")
        return line.endswith(mark) or (mark + " ") in line

    def _narrow_logs(self, tool, clean, response):
        """mcp — только строки аудита ЭТОГО доступа.

        Опознаём их по метке origin, которую HttpTransport ставит каждой своей записи:
        «agent=<id> ip=<адрес>» в конце строки. Точное совпадение по «agent=<id> » и по концу
        строки: подстрока «agent=a-1a» не должна поймать «agent=a-1a2b».
        """
        if self.agent_id is None or tool.cli != "logs-tail":
            return response
        if str(clean.get("component") or "") != "mcp" or not isinstance(response.get("log"), str):
            return response
        lines = response["log"].splitlines()
        mark = "agent=%s" % self.agent_id
        mine = [ln for ln in lines if self._line_is_mine(ln, mark)]
        out = dict(response)
        out["log"] = "\n".join(mine)
        out["lines_total"] = len(lines)
        out["lines_shown"] = len(mine)
        out["narrowed_to_agent"] = self.agent_id
        out["message"] = msg(self.lang, "logs_mcp_narrowed", agent=self.agent_id,
                             kept=len(mine), total=len(lines))
        return out

    def tool_result(self, response):
        """content (текст + изображения) + structuredContent + isError из JSON моста."""
        is_error = response.get("status") != "success"
        images = []
        text_view = dict(response)
        # Любое поле *_png_b64 (строка или список строк) уходит клиенту как image-контент, а в
        # текстовой копии заменяется заглушкой: модели не нужны килобайты base64 в контексте,
        # а structuredContent остаётся полным ответом моста для программных клиентов.
        for key in list(response.keys()):
            if not key.endswith("_png_b64"):
                continue
            value = response[key]
            if isinstance(value, str):
                image = self._png_content(value)
                if image is not None:
                    images.append(image)
                    text_view[key] = msg(self.lang, "png_placeholder", size=image["_size"], n=len(images))
            elif isinstance(value, list):
                placeholders = []
                for item in value:
                    image = self._png_content(item) if isinstance(item, str) else None
                    if image is None:
                        placeholders.append(item)
                        continue
                    images.append(image)
                    placeholders.append(msg(self.lang, "png_placeholder", size=image["_size"], n=len(images)))
                text_view[key] = placeholders
        content = [{"type": "text", "text": json.dumps(text_view, ensure_ascii=False, indent=2)}]
        for image in images:
            content.append({"type": "image", "data": image["data"], "mimeType": "image/png"})
        return {"content": content, "structuredContent": response, "isError": bool(is_error)}

    def _png_content(self, b64):
        try:
            raw = base64.b64decode(b64, validate=True)
        except (ValueError, TypeError):
            self.log.warn("ответ моста: поле *_png_b64 не является base64 — пропущено")
            return None
        if not raw.startswith(PNG_SIGNATURE):
            self.log.warn("ответ моста: поле *_png_b64 не содержит PNG — пропущено")
            return None
        return {"data": b64, "_size": len(raw)}

    def m_resources_list(self, params):
        return {"resources": self.catalog.resources_list(self.scope)}

    def m_resources_templates_list(self, params):
        return {"resourceTemplates": []}

    def m_resources_read(self, params):
        uri = params.get("uri")
        res = self.catalog.resources_by_uri.get(uri) if isinstance(uri, str) else None
        if res is None:
            raise RpcError(RESOURCE_NOT_FOUND, "Resource not found", {"uri": uri})
        if res["kind"] == "file":
            self._admit_execution()
            return self.read_file_resource(res)
        tool = res["tool"]
        if not self.catalog.tool_allowed(tool, self.scope):
            self._audit("resource", tool.name, tool.cli, {"uri": uri}, "rejected", "forbidden", 0)
            raise RpcError(FORBIDDEN, msg(self.lang, "err_forbidden", name=tool.name, scope=self.scope),
                           {"uri": uri, "scope": self.scope})
        self._admit_execution()
        started = time.time()
        response = self.bridge.run(tool.cli, [], who=self._who())
        ms = int((time.time() - started) * 1000)
        status = str(response.get("status", "?"))
        self._audit("resource", tool.name, tool.cli, {"uri": uri}, status, response.get("code"), ms)
        if status != "success":
            raise RpcError(INTERNAL_ERROR, str(response.get("message") or "bridge error"), response)
        return {"contents": [{"uri": uri, "mimeType": res["mime"],
                              "text": json.dumps(response, ensure_ascii=False, indent=2)}]}

    def read_file_resource(self, res):
        """Документ рядом с сервером (гайд для агента). Мост не вызывается, замок не берётся.

        Файл читается при каждом запросе, без кэша: он маленький, а правка гайда на сервере
        должна быть видна следующей сессии без перезапуска чего бы то ни было. Отсутствие файла —
        ошибка упаковки, и агент должен увидеть её явно (-32002 с путём), а не пустой документ.
        """
        uri, path = res["uri"], res["path"]
        started = time.time()
        try:
            with open(path, "rb") as fh:
                raw = fh.read()
        except OSError as exc:
            self.log.warn("ресурс %s: не удалось прочитать %s: %s" % (uri, path, exc))
            self._audit("resource", "-", "file:" + os.path.basename(path), {"uri": uri}, "error", "file_missing", 0)
            raise RpcError(RESOURCE_NOT_FOUND, msg(self.lang, "err_resource_file", uri=uri, path=path),
                           {"uri": uri, "path": path})
        item = {"uri": uri, "mimeType": res["mime"]}
        try:
            item["text"] = raw.decode("utf-8")
        except UnicodeDecodeError:
            # Не текст (картинка, архив): по спецификации такой ресурс отдаётся полем blob в base64.
            item["blob"] = base64.b64encode(raw).decode("ascii")
        self._audit("resource", "-", "file:" + os.path.basename(path), {"uri": uri}, "success", None,
                    int((time.time() - started) * 1000))
        return {"contents": [item]}

    def m_prompts_list(self, params):
        return {"prompts": self.catalog.prompts_list(self.scope)}

    def m_prompts_get(self, params):
        name = params.get("name")
        pdef = self.catalog.prompts_by_name.get(name) if isinstance(name, str) else None
        if pdef is None:
            raise RpcError(INVALID_PARAMS, msg(self.lang, "err_unknown_prompt", name=str(name)))
        if not self.catalog.prompt_allowed(pdef, self.scope):
            raise RpcError(FORBIDDEN, msg(self.lang, "err_forbidden_prompt", name=pdef["name"], scope=self.scope),
                           {"prompt": pdef["name"], "scope": self.scope})
        raw_args = params.get("arguments") or {}
        if not isinstance(raw_args, dict):
            raise RpcError(INVALID_PARAMS, msg(self.lang, "err_args_object"))
        arguments = {}
        for key, value in raw_args.items():
            if value is None:
                continue
            arguments[str(key)] = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
        missing = [str(a.get("name")) for a in pdef.get("arguments") or []
                   if a.get("required") and not arguments.get(str(a.get("name")))]
        if missing:
            raise RpcError(INVALID_PARAMS, msg(self.lang, "err_prompt_args", names=", ".join(missing)), {"missing": missing})
        # Аргумент с именем типа из param_types проверяем тем же валидатором — подсказка с мусором
        # в имени пользователя ушла бы в модель и дальше в инструменты.
        for key, value in arguments.items():
            ptype = self.catalog.param_types.get(key)
            if ptype and ptype.get("type", "string") == "string":
                self.catalog.validate_value(ParamSpec(key, ptype, {}, self.log), value, self.lang)
        self._admit_execution()
        text = self.catalog.render_prompt(pdef, arguments, self.lang)
        return {"description": pick(pdef.get("description"), self.lang),
                "messages": [{"role": "user", "content": {"type": "text", "text": text}}]}


# ---------------------------------------------------------------------------------------------
# HTTP-транспорт: доступы агентов (PLAN §6.10, CONTRACT §5.1)
# ---------------------------------------------------------------------------------------------

def parse_iso(text):
    """ISO-8601 UTC «2026-09-08T12:00:00Z» → aware datetime; мусор → None."""
    try:
        return datetime.datetime.strptime(str(text), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except (TypeError, ValueError):
        return None


def is_loopback(ip):
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    if isinstance(addr, ipaddress.IPv6Address) and addr.ipv4_mapped is not None:
        addr = addr.ipv4_mapped
    return addr.is_loopback


def mask_path(path):
    """Путь для логов: секрет заменяется звёздочками — иначе лог сервера был бы копией ключей."""
    return re.sub(r"/a-[A-Za-z0-9_-]{43}", "/a-***", str(path))


class Notifier(object):
    """Очередь событий для бота (lib/common.sh ga_notify, docs/BOT.md §6).

    Один файл — одно событие — одна строка JSON {ts, event, …}; появляется атомарно (tmp рядом
    + rename), потому что бот читает каталог по обходу и не должен увидеть полузапись. Ни адреса
    доступа, ни токена в событии нет — только идентификатор доступа, метка и IP: уведомление
    уходит в чат, а чат — не то место, где должен оказаться ключ.

    Молчаливая: читателя может не быть вовсе (бот не поставлен), и запрос агента важнее записи
    в очередь — любая ошибка гасится предупреждением в лог, а не отказом агенту.
    """

    def __init__(self, directory, log, limit=200):
        self.dir = directory
        self.log = log
        self.limit = limit
        self._lock = threading.Lock()
        self._seq = 0
        self._warned = False

    def send(self, event, fields):
        if not self.dir:
            return False
        with self._lock:
            self._seq += 1
            seq = self._seq
        stamp = utc_now()
        payload = {"ts": stamp, "event": event}
        payload.update(fields)
        try:
            os.makedirs(self.dir, mode=0o700, exist_ok=True)
            tmp = os.path.join(self.dir, ".tmp.mcp%d.%d" % (os.getpid(), seq))
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            try:
                os.write(fd, (json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8"))
            finally:
                os.close(fd)
            name = "%s_%d_%04d.json" % (re.sub(r"[:-]", "", stamp), os.getpid(), seq)
            os.replace(tmp, os.path.join(self.dir, name))
            self._trim()
            return True
        except OSError as exc:
            if not self._warned:
                self._warned = True
                self.log.warn("очередь уведомлений %s недоступна (%s) — события владельцу не уходят"
                              % (self.dir, exc))
            return False

    def _trim(self):
        """Тот же предел, что у ga_notify_trim: без читателя очередь на tmpfs росла бы вечно."""
        if not self.limit:
            return
        try:
            names = sorted(n for n in os.listdir(self.dir) if n.endswith(".json") and not n.startswith(".tmp."))
        except OSError:
            return
        for name in names[:max(0, len(names) - self.limit)]:
            try:
                os.unlink(os.path.join(self.dir, name))
            except OSError:
                pass


class Grant(object):
    """Одна запись agents.json. Поля с умолчаниями: старый файл не должен ломать сервер.

    require_token отсутствует у доступов, выданных до второго фактора: у них умолчание false —
    «слабый доступ, только путь». Ломать выданное молча нельзя, поэтому усиление — отдельное
    решение человека (agent-harden), а не побочный эффект обновления.
    """

    def __init__(self, raw):
        self.id = str(raw.get("id") or "")
        self.label = str(raw.get("label") or "")
        self.secret = str(raw.get("secret") or "")
        self.token = str(raw.get("token") or "")
        self.require_token = bool(raw.get("require_token", False))
        self.scope = str(raw.get("scope") or "")
        self.enabled = bool(raw.get("enabled", True))
        self.expires = str(raw.get("expires") or "")
        # Выданная длительность в сутках. По ней считается полоса предупреждения
        # «срок на исходе»: одним числом на все доступы она перекрывала правило
        # продления. У записей, заведённых до появления поля, выводим её из
        # created→expires тем же _term_days_from, что и продление, — иначе два
        # места считали бы длительность по-разному.
        term = raw.get("term_days")
        if not isinstance(term, int) or isinstance(term, bool) or term <= 0:
            term = _term_days_from(raw)
        self.term_days = term
        self.port = raw.get("port") if isinstance(raw.get("port"), int) and not isinstance(raw.get("port"), bool) else 0
        ips = raw.get("allow_ips")
        entries = [str(x).strip() for x in ips if str(x).strip()] if isinstance(ips, list) else []
        # Записи разбираем здесь, а не при каждом запросе: битую нельзя ни впустить молча, ни
        # молча выбросить. bad_ips хранит отброшенные — по ним GrantStore говорит владельцу, из-за
        # чего агент не входит, иначе белый список запирает его без единого слова.
        self.allow_ips = [e for e in entries if ALLOW_IP_RE.match(e)]
        self.bad_ips = [e for e in entries if not ALLOW_IP_RE.match(e)]
        # Привязка к адресу при первом использовании: pin_ip включает правило, pinned_ip — то,
        # что доступ запомнил. Пока pinned_ip пуст, доступ принимает любой адрес и закрепит первый.
        self.pin_ip = bool(raw.get("pin_ip", False))
        self.pinned_ip = str(raw.get("pinned_ip") or "")
        # Вид доступа. Поля mode нет у всех, кто выдан до одноразового ключа, — умолчание static,
        # то есть «как работало, так и работает». Молчаливое повышение до rolling сломало бы
        # каждого уже настроенного агента: он не умеет ни присылать ключ, ни принимать новый.
        mode = str(raw.get("mode") or "static").strip().lower()
        self.mode = mode if mode in GRANT_MODES else "static"
        # Отпечаток ПЕРВОГО ключа цепочки: сам ключ печатается один раз при выдаче и на сервере
        # не хранится. Он же — метка цепочки: сменился отпечаток, значит доступ перевыпущен, и
        # состояние прежней цепочки на диске больше не относится к делу.
        self.key_hash = str(raw.get("key_hash") or "").strip().lower()
        # Заморозка после обнаружения клона (§11.3): доступ перестаёт впускать, но остаётся —
        # владелец решает, перевыпустить или отозвать совсем.
        self.compromised = bool(raw.get("compromised", False))
        self.last_used = str(raw.get("last_used") or "")
        self.last_ip = str(raw.get("last_ip") or "")
        # Адреса, с которых доступ уже работал: по ним снимается бан при перевыпуске.
        known = raw.get("known_ips")
        self.known_ips = [str(x) for x in known if str(x).strip()] if isinstance(known, list) else []
        # Переходник: rot_seed задаёт плавающий путь; enroll_path/enroll_expires — одноразовая
        # привязка, ещё не использованная; key_storage — где агент держит ключ (видно в списке).
        self.transport = str(raw.get("transport") or "").strip().lower()
        rs = str(raw.get("rot_seed") or "")
        self.rot_seed = rs if SECRET_RE.match(rs) else ""
        ep = str(raw.get("enroll_path") or "")
        self.enroll_path = ep if SECRET_RE.match(ep) else ""
        self.enroll_expires = str(raw.get("enroll_expires") or "")
        ks = str(raw.get("key_storage") or "")
        self.key_storage = ks if ks in KEY_STORAGE_KINDS else ""

    def pending_enroll(self):
        """Выдан переходнику, но ещё не привязан: ни плавающего пути, ни ключа."""
        return self.transport == "connect" and not self.rot_seed

    def seen_ips(self):
        """Все адреса, которые доступ уже показывал: известные, последний и закреплённый."""
        out = []
        for ip in list(self.known_ips) + [self.last_ip, self.pinned_ip]:
            if ip and ip not in out:
                out.append(ip)
        return out

    def valid(self):
        if not (AGENT_ID_RE.match(self.id) and SECRET_RE.match(self.secret) and self.scope in SCOPES):
            return False
        # Ожидающая привязки запись законна без токена и ключа: они появятся при привязке.
        # Впускать по ней нельзя (authenticate её пропускает), но и выбрасывать нельзя — иначе
        # привязке не с чем сверить код.
        if self.pending_enroll():
            return bool(self.enroll_path)
        # require_token без токена — испорченная запись. Впустить её значило бы тихо понизить
        # доступ до одного пути; отказать безопаснее, поэтому она просто выпадает из списка.
        if self.require_token and not TOKEN_RE.match(self.token):
            return False
        # rolling без отпечатка первого ключа — та же испорченная запись: цепочку не с чего
        # начать, а впустить «просто по пути и токену» значило бы тихо понизить доступ до static.
        if self.mode == "rolling" and not KEY_HASH_RE.match(self.key_hash):
            return False
        return True

    def expired(self, now=None):
        if not self.expires:
            return False
        exp = parse_iso(self.expires)
        # Нечитаемая дата — считаем истёкшей: отказать безопаснее, чем впустить навсегда.
        return exp is None or exp <= (now or datetime.datetime.now(datetime.timezone.utc))

    def seconds_left(self, now=None):
        """Сколько секунд доступу осталось; None — бессрочный или дата нечитаема."""
        if not self.expires:
            return None
        exp = parse_iso(self.expires)
        if exp is None:
            return None
        return (exp - (now or datetime.datetime.now(datetime.timezone.utc))).total_seconds()

    def token_ok(self, token):
        """Второй фактор. Доступ без require_token принимает запрос с любым Authorization (в том
        числе без него) — иначе обновление сервера сломало бы уже выданные адреса."""
        if not self.require_token:
            return True
        if not token:
            return False
        return hmac.compare_digest(self.token.encode("utf-8"), token.encode("utf-8"))

    def pin_ok(self, ip):
        """Привязка к адресу: пока pinned_ip пуст, подойдёт любой (его и закрепим при учёте)."""
        if not self.pin_ip or not self.pinned_ip:
            return True
        return self.pinned_ip == ip

    def ip_allowed(self, ip):
        # Пустой список — ограничения нет вовсе, входит любой. Но если список БЫЛ, а годных
        # записей не осталось, «пусто» обязано значить «никого»: иначе одна опечатка в белом
        # списке открывала бы доступ всему интернету — ровно наоборот тому, чего просили.
        if not self.allow_ips:
            return not self.bad_ips
        try:
            addr = ipaddress.ip_address(ip)
        except ValueError:
            return False
        if isinstance(addr, ipaddress.IPv6Address) and addr.ipv4_mapped is not None:
            addr = addr.ipv4_mapped
        for entry in self.allow_ips:
            try:
                if addr in ipaddress.ip_network(entry, strict=False):
                    return True
            except ValueError:
                continue     # битая запись не открывает и не закрывает — просто не совпадает
        return False


class GrantStore(object):
    """agents.json: чтение по mtime при каждом запросе и атомарное обновление учёта.

    Файл маленький, а отзыв должен действовать мгновенно (PLAN §6.10), поэтому кэш живёт ровно до
    смены mtime/размера/inode. Учёт (last_used, last_ip, calls) пишется tmp+rename под тем же
    flock, что берут install.sh, бот и панель: иначе перевыпуск секрета из меню мог бы потеряться
    под нашей записью старой копии. Не удалось взять замок за HTTP_LOCK_WAIT — статистику
    пропускаем: запрос агента важнее счётчика.
    """

    def __init__(self, path, lock_file, log):
        self.path = path
        self.lock_file = lock_file
        self.log = log
        self._lock = threading.Lock()
        self._stamp = None
        self._doc = None
        self._grants = []
        self._warned = set()
        # Кого позвать, когда доступ перевыпустили (agents_rotate): сменился секрет
        # или снялась заморозка. Ставит serve_http; без слушателя — просто None.
        self.on_rotate = None

    def _warn_once(self, key, text):
        if key not in self._warned:
            self._warned.add(key)
            self.log.warn(text)

    @staticmethod
    def _stat(path):
        try:
            st = os.stat(path)
        except OSError:
            return None
        return (st.st_mtime_ns, st.st_size, st.st_ino)

    def _parse(self, doc):
        records = doc.get("agents") if isinstance(doc, dict) else doc
        grants = []
        for raw in records if isinstance(records, list) else []:
            if not isinstance(raw, dict):
                continue
            grant = Grant(raw)
            if grant.valid():
                grants.append(grant)
            else:
                # Причину называем: «запись пропущена» без неё выглядит как случайный сбой, а
                # чаще всего это правка руками — rolling без key_hash или require_token без токена.
                why = "нет id, секрета или уровня"
                if grant.mode == "rolling" and not KEY_HASH_RE.match(grant.key_hash):
                    why = "mode=rolling без key_hash — цепочку не с чего начать"
                elif grant.require_token and not TOKEN_RE.match(grant.token):
                    why = "require_token без токена"
                self._warn_once("bad:" + grant.id, "agents.json: запись %r пропущена (%s)" % (grant.id, why))
                continue
            if grant.bad_ips:
                # Запись цела, негодны только адреса. Молчать нельзя: белый список запирает
                # агента, а причина видна только здесь — снаружи это обычный 404.
                self._warn_once("ips:" + grant.id,
                                "agents.json: у доступа %r отброшены адреса allow_ips (%s) — нужен IPv4 "
                                "по значению октетов, без ведущих нулей, префикс 1..32; с этих адресов "
                                "доступ не впускает" % (grant.id, ", ".join(grant.bad_ips)))
        return grants

    def _read_doc(self):
        with open(self.path, "r", encoding="utf-8") as fh:
            return json.load(fh)

    def grants(self):
        """Актуальный список доступов; нет файла или он битый — пусто, то есть всем 404."""
        with self._lock:
            stamp = self._stat(self.path)
            if stamp != self._stamp or self._doc is None:
                self._stamp = stamp
                if stamp is None:
                    self._doc, self._grants = {"schema": 1, "agents": []}, []
                else:
                    try:
                        self._doc = self._read_doc()
                        previous = {g.id: (g.secret, g.key_hash, g.compromised) for g in self._grants}
                        self._grants = self._parse(self._doc)
                        self._notify_rotated(previous, self._grants)
                        self._warned.discard("corrupt")
                    except (OSError, ValueError) as exc:
                        # Битый файл = никого не пускать, а не «жить на старой копии»: отзыв, сделанный
                        # прямо перед поломкой, обязан подействовать.
                        self._warn_once("corrupt", "agents.json не читается (%s) — все доступы отклоняются" % exc)
                        self._doc, self._grants = None, []
            return list(self._grants)

    def _notify_rotated(self, previous, current):
        """Доступ перевыпустили — сказать слушателю и отдать адреса, которые он знал.

        Перевыпуск видно по смене секрета, отпечатка первого ключа цепочки или по снятию
        заморозки: всё это делает agents_rotate. Слушатель снимает по этим адресам бан —
        иначе ответ владельца «это был я» не действовал бы ещё десять минут.
        """
        if not self.on_rotate or not previous:
            return
        for grant in current:
            was = previous.get(grant.id)
            if was is None:
                continue
            if was[0] != grant.secret or was[1] != grant.key_hash or (was[2] and not grant.compromised):
                try:
                    self.on_rotate(grant)
                except Exception as exc:                      # слушатель не должен ронять чтение
                    self.log.warn("перевыпуск доступа %s: слушатель упал (%s)" % (grant.id, exc))

    def authenticate(self, secret, token, ip, only_grant_id=None, port_exclusive=False):
        """→ (Grant, "ok") или (None, причина). Сравнение секретов — постоянного времени и по всем
        записям без раннего выхода, чтобы время ответа не подсказывало, какая запись совпала.

        Причина наружу не уходит (все отказы — один 404), она нужна логу и счётчику неудач.
        Отдельная причина token означает «путь верный, второго фактора нет» — это и есть сигнал
        утёкшего адреса, и вызывающий поднимает по нему тревогу."""
        match = None
        for grant in self.grants():
            if hmac.compare_digest(grant.secret.encode("utf-8"), secret.encode("utf-8")):
                match = grant
        if match is None:
            return None, "unknown"
        # Доступ переходника по неподвижному пути не открывается вовсе: у привязанного путь
        # плавающий, и старый адрес, когда-то утёкший, открывать его не должен; у ожидающего
        # привязки ключа ещё нет.
        if match.pending_enroll() or match.rot_seed:
            return None, "path"
        return self._admit(match, token, ip, only_grant_id, port_exclusive)

    def path_known(self, secret=None, path_token=None, now=None):
        """Есть ли доступ с таким путём (неподвижным или плавающим) — без второго фактора и без побочных
        действий (тревог, закрепления адреса, счётчиков). Нужен только ответу на не-POST."""
        found = False
        if secret:
            for grant in self.grants():
                if hmac.compare_digest(grant.secret.encode("utf-8"), secret.encode("utf-8")) \
                        and not grant.pending_enroll() and not grant.rot_seed:
                    found = True
        if path_token:
            slot = int((now if now is not None else time.time()) // FLOAT_SLOT_SECONDS)
            want = path_token.encode("utf-8")
            for grant in self.grants():
                if not grant.rot_seed:
                    continue
                for s_ in (slot - 1, slot, slot + 1):
                    if hmac.compare_digest(float_path(grant.rot_seed, s_).encode("utf-8"), want):
                        found = True
        return found

    def authenticate_float(self, path_token, token, ip, only_grant_id=None, port_exclusive=False, now=None):
        """Плавающий путь (§2): принимаются предыдущий, текущий и следующий отрезки. Сравнение по
        всем доступам и всем отрезкам без раннего выхода."""
        slot = int((now if now is not None else time.time()) // FLOAT_SLOT_SECONDS)
        want = path_token.encode("utf-8")
        match = None
        for grant in self.grants():
            if not grant.rot_seed:
                continue
            for s_ in (slot - 1, slot, slot + 1):
                if hmac.compare_digest(float_path(grant.rot_seed, s_).encode("utf-8"), want):
                    match = grant
        if match is None:
            return None, "unknown"
        return self._admit(match, token, ip, only_grant_id, port_exclusive)

    def _admit(self, match, token, ip, only_grant_id, port_exclusive):
        """Всё, что решается после опознания записи по пути: слушатель, состояние, второй фактор,
        адрес. Одно место для неподвижного и плавающего пути."""
        if only_grant_id is not None and match.id != only_grant_id:
            return None, "wrong_listener"     # чужой доступ на персональном порту
        if only_grant_id is None and match.port and port_exclusive:
            return None, "port_only"          # mcp.port_exclusive: доступ с портом — только на своём порту
        # Отозванный и истёкший — раньше токена: по такому доступу тревожить владельца незачем,
        # он уже принял решение, а лишние события только приучили бы не читать уведомления.
        # Запись возвращаем вместе с причиной: доступ впускать нельзя, но назвать его надо —
        # по ней вызывающий и не считает эти отказы подбором, и говорит про истёкший срок.
        if not match.enabled:
            return match, "disabled"
        if match.expired():
            return match, "expired"
        # Замороженный — рядом с отозванным и по той же причине: решение уже принято, и лишние
        # тревоги по нему только приучили бы не читать уведомления. Ключ у такого доступа не
        # спрашиваем вовсе: цепочка уже раздвоена, спрашивать нечего.
        if match.compromised:
            return match, "compromised"
        if not match.token_ok(token):
            return match, "token"             # запись возвращаем ради тревоги, доступ НЕ даём
        if not match.ip_allowed(ip):
            return None, "ip"
        if not match.pin_ok(ip):
            return match, "pin"
        return match, "ok"

    def pending_enrollment(self, path_token, now=None, ip=None, only_grant_id=None, port_exclusive=False):
        """→ (Grant, "ok") — запись ждёт привязки с этим кодом, код жив и привязка разрешена
        отсюда; иначе причина.

        Код — лишь замена секрета пути, а не пропуск мимо остальных правил доступа: белый
        список адресов, персональный порт и срок самого доступа действуют и на привязку.
        Иначе код, утёкший за свои 10 минут, привязывался бы с любого адреса мира к
        доступу, который владелец ограничил одной подсетью.
        """
        want = path_token.encode("utf-8")
        found = None
        for grant in self.grants():
            if grant.pending_enroll() and hmac.compare_digest(grant.enroll_path.encode("utf-8"), want):
                found = grant
        if found is None:
            return None, "unknown"
        if only_grant_id is not None and found.id != only_grant_id:
            return None, "wrong_listener"
        if only_grant_id is None and found.port and port_exclusive:
            return None, "port_only"
        if not found.enabled:
            return found, "disabled"
        if found.expired():
            return found, "expired"
        exp = parse_iso(found.enroll_expires)
        if exp is None or exp <= (now or datetime.datetime.now(datetime.timezone.utc)):
            return found, "code_expired"
        if ip is not None and not found.ip_allowed(ip):
            return found, "ip"
        return found, "ok"

    def complete_enrollment(self, grant_id, path_token, updates):
        """Записать привязку в agents.json под config.lock и погасить код (§7).

        Запись меняется, только если она всё ещё ждёт привязки именно этим кодом: два запроса с
        одним кодом разом не выдадут двух ключей.
        """
        with self._lock:
            try:
                fd = self._flock()
            except RuntimeError:
                self.log.error("agents.json: замок занят — привязка доступа %s не записана" % grant_id)
                return False
            try:
                try:
                    doc = self._read_doc()
                except (OSError, ValueError) as exc:
                    self.log.error("agents.json не читается (%s) — привязка %s не записана" % (exc, grant_id))
                    return False
                records = doc.get("agents") if isinstance(doc, dict) else doc
                if not isinstance(records, list):
                    return False
                target = None
                for raw in records:
                    if isinstance(raw, dict) and raw.get("id") == grant_id \
                            and str(raw.get("enroll_path") or "") == path_token and not raw.get("rot_seed"):
                        target = raw
                if target is None:
                    return False
                target.update(updates)
                target.pop("enroll_path", None)
                target.pop("enroll_expires", None)
                directory = os.path.dirname(self.path) or "."
                tmp = os.path.join(directory, ".agents.json.%d.enr" % os.getpid())
                out = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                try:
                    os.write(out, json.dumps(doc, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8"))
                    os.fchmod(out, 0o600)
                    os.fsync(out)
                finally:
                    os.close(out)
                os.replace(tmp, self.path)
                self._doc = doc
                self._grants = self._parse(doc)
                self._stamp = self._stat(self.path)
                return True
            except OSError as exc:
                self.log.error("agents.json: привязка доступа %s не записана: %s" % (grant_id, exc))
                return False
            finally:
                if fd is not None:
                    try:
                        os.close(fd)
                    except OSError:
                        pass

    def _flock(self):
        """fd замка config.lock или None (замка нет/недоступен); RuntimeError — не дождались."""
        if not self.lock_file:
            return None
        try:
            import fcntl
        except ImportError:
            return None
        try:
            fd = os.open(self.lock_file, os.O_RDWR | os.O_CREAT, 0o600)
        except OSError as exc:
            self._warn_once("lock", "замок %s недоступен (%s) — учёт вызовов пишется без него" % (self.lock_file, exc))
            return None
        deadline = time.monotonic() + HTTP_LOCK_WAIT
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return fd
            except OSError:
                if time.monotonic() >= deadline:
                    os.close(fd)
                    raise RuntimeError("lock timeout")
                time.sleep(0.05)

    @staticmethod
    def _fresh_admits(grant, doc, ip):
        """→ (запись из doc, Grant по ней), если свежая запись по-прежнему впускает этот запрос,
        иначе (None, None).

        Отзыв/перевыпуск/сужение scope между authenticate и допуском не продолжает старый запрос."""
        records = doc.get("agents") if isinstance(doc, dict) else doc
        raw = next((r for r in records if isinstance(r, dict) and r.get("id") == grant.id), None) \
            if isinstance(records, list) else None
        if raw is None:
            return None, None
        current = Grant(raw)
        identity = ("secret", "token", "require_token", "key_hash", "rot_seed", "mode", "transport", "scope", "port")
        if any(getattr(current, k) != getattr(grant, k) for k in identity) \
                or not current.enabled or current.expired() or current.compromised \
                or not current.ip_allowed(ip) or not current.pin_ok(ip):
            return None, None
        return raw, current

    def claim_pin(self, grant, ip):
        """Допуск по pin_ip ДО RPC → "ok" (допущен), "claimed" (допущен, адрес закреплён этим
        вызовом), "denied" (не впускать, 404) или "busy" (замок занят или недоступен — 503).

        Два первых запроса уже могли пройти authenticate с пустым pinned_ip. Свежую запись
        проверяем и закрепляем под config.lock; touch после RPC слишком поздно запрещать второй.
        При отказе записи/замка действие не выполняется: для ограничения доступа best-effort нельзя.

        Уже закреплённый адрес замка НЕ ждёт (SEC46-01). config.lock держит всё время работы каждое
        пишущее действие моста — установка профиля, восстановление, обновление ядра, смена режима идут
        минутами, — и закреплённый агент получал 404 на всё, даже на ping, а в журнале это стояло
        отказом pin; так же после перезагрузки, пока нет /run/goamnezia. Закреплять тут нечего, а свежую
        запись читаем без замка: agents.json все пишут только целиком (tmp + rename), и чтение видит
        либо прежний файл, либо новый. Замок нужен одному первому закреплению — его и ждём.
        """
        if not grant.pin_ip:
            return "ok"
        if grant.pinned_ip:
            try:
                _raw, current = self._fresh_admits(grant, self._read_doc(), ip)
            except (OSError, ValueError) as exc:
                self.log.warn("agents.json не читается (%s) — вызов доступа %s отклонён" % (exc, grant.id))
                return "denied"
            if current is None:
                return "denied"
            if not current.pin_ip or current.pinned_ip:
                return "ok"
            # Привязку сбросили между authenticate и допуском — дальше как первое закрепление.
        with self._lock:
            fd, tmp = None, None
            try:
                try:
                    fd = self._flock()
                except RuntimeError:
                    self.log.info("agent %s: config.lock занят дольше %.0f с — адрес %s не закреплён, ответ 503"
                                  % (grant.id, HTTP_LOCK_WAIT, ip))
                    return "busy"
                if self.lock_file and fd is None:
                    self.log.info("agent %s: замок %s недоступен — адрес %s не закреплён, ответ 503"
                                  % (grant.id, self.lock_file, ip))
                    return "busy"
                doc = self._read_doc()
                raw, current = self._fresh_admits(grant, doc, ip)
                if current is None:
                    return "denied"
                if not current.pin_ip or current.pinned_ip:
                    return "ok"
                raw["pinned_ip"] = ip
                out, tmp = tempfile.mkstemp(prefix=".agents-pin-", dir=os.path.dirname(self.path) or ".")
                with os.fdopen(out, "w", encoding="utf-8") as fh:
                    json.dump(doc, fh, ensure_ascii=False, indent=2, sort_keys=True)
                    fh.flush()
                    os.fsync(fh.fileno())
                os.replace(tmp, self.path)
                tmp = None
                self._doc = doc
                self._grants = self._parse(doc)
                self._stamp = self._stat(self.path)
                return "claimed"
            except (OSError, ValueError, RuntimeError) as exc:
                self.log.warn("agents.json: адрес доступа %s не закреплён (%s)" % (grant.id, exc))
                return "denied"
            finally:
                if tmp is not None:
                    try:
                        os.unlink(tmp)
                    except OSError:
                        pass
                if fd is not None:
                    os.close(fd)

    def touch(self, grant_id, ip):
        """last_used/last_ip/calls доступа: свежее чтение → правка → tmp+rename 0600.

        Адрес уже закреплён claim_pin до RPC; здесь копится known_ips —
        короткий список уже виденных адресов. → (событие|None, закреплён ли адрес этим вызовом):
        «first_use» при самом первом вызове доступа, «new_ip» при вызове с адреса, которого в
        known_ips ещё не было. По ним HttpTransport кладёт уведомление владельцу.
        """
        event = None
        pinned_now = False
        renewed = False
        with self._lock:
            try:
                fd = self._flock()
            except RuntimeError:
                self.log.warn("agents.json: замок занят дольше %.0f с — учёт вызова %s пропущен" % (HTTP_LOCK_WAIT, grant_id))
                return None, False
            try:
                try:
                    doc = self._read_doc()
                except (OSError, ValueError):
                    return None, False
                records = doc.get("agents") if isinstance(doc, dict) else doc
                if not isinstance(records, list):
                    return None, False
                found = False
                for raw in records:
                    if isinstance(raw, dict) and raw.get("id") == grant_id:
                        known = [str(x) for x in raw.get("known_ips") or [] if str(x).strip()] \
                            if isinstance(raw.get("known_ips"), list) else []
                        if not str(raw.get("last_used") or ""):
                            event = "first_use"
                        elif ip not in known:
                            event = "new_ip"
                        if ip not in known:
                            known.append(ip)
                        raw["known_ips"] = known[-HTTP_KNOWN_IPS_MAX:]
                        # СКОЛЬЗЯЩИЙ СРОК. Доступ, которым пользуются, не должен
                        # умирать по календарю: владелец не обязан помнить про
                        # продление, а молчаливое истечение выглядит как поломка
                        # (тот же неотличимый отказ, что у чужого ключа).
                        #
                        # Поэтому каждый удачный вызов отодвигает срок на полную
                        # выданную длительность. Кончается доступ только двумя
                        # путями: владелец убрал его сам, или им НЕ ПОЛЬЗОВАЛИСЬ
                        # всю выданную длительность. Бессрочный (term_days = 0)
                        # не трогаем, у него и срока нет.
                        #
                        # Двигаем не на каждый вызов, а когда прошла половина
                        # срока: иначе запись менялась бы постоянно без пользы.
                        term = raw.get("term_days")
                        if not isinstance(term, int) or isinstance(term, bool) or term <= 0:
                            # Старая запись без длительности: выводим её из
                            # created→expires, чтобы продление работало и у
                            # доступов, выданных до этой правки.
                            term = _term_days_from(raw)
                            if term > 0:
                                raw["term_days"] = term
                        if term > 0 and str(raw.get("expires") or ""):
                            left = _seconds_left(raw.get("expires"))
                            if left is not None and left < term * 86400 / 2:
                                raw["expires"] = _utc_plus_days(term)
                                renewed = True
                        raw["last_used"] = utc_now()
                        raw["last_ip"] = ip
                        calls = raw.get("calls")
                        raw["calls"] = (calls if isinstance(calls, int) and not isinstance(calls, bool) else 0) + 1
                        found = True
                if not found:
                    return None, False
                directory = os.path.dirname(self.path) or "."
                tmp = os.path.join(directory, ".agents.json.%d.tmp" % os.getpid())
                out = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                try:
                    os.write(out, json.dumps(doc, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8"))
                    os.fchmod(out, 0o600)
                finally:
                    os.close(out)
                os.replace(tmp, self.path)
                # Кэш обновляем сразу: файл наш, перечитывать его на следующем запросе незачем.
                self._doc = doc
                self._grants = self._parse(doc)
                self._stamp = self._stat(self.path)
                if renewed:
                    # Говорим вслух: срок продлился сам. Владелец должен видеть,
                    # что доступ жив не по недосмотру, а потому что им пользуются.
                    self.log.info("agent %s: срок продлён сам на %d сут. — доступом пользуются"
                                  % (grant_id, term))
                return event, pinned_now
            except OSError as exc:
                self._warn_once("write", "agents.json: учёт вызовов не записан: %s" % exc)
                return None, False
            finally:
                if fd is not None:
                    try:
                        os.close(fd)     # close снимает flock
                    except OSError:
                        pass

    def freeze(self, grant_id, ip, when):
        """Заморозить доступ после обнаружения клона: compromised + когда и откуда он пришёл.

        Заморозка, а не удаление (§11.3). Восстановление машины агента из вчерашней резервной
        копии выглядит ровно как кража — ключ там старый, из истории, — и решать, что это было,
        должен человек, а не сервер. Удалённая запись такого выбора уже не оставляет.

        Пишется в agents.json под тем же config.lock, что берут install.sh, бот и панель. Это
        редкое событие, не горячий путь: тут дороже потерять запись, чем потратить миллисекунды.
        """
        with self._lock:
            try:
                fd = self._flock()
            except RuntimeError:
                self.log.error("agents.json: замок занят — доступ %s НЕ заморожен, повторите отзыв вручную" % grant_id)
                return False
            try:
                try:
                    doc = self._read_doc()
                except (OSError, ValueError) as exc:
                    self.log.error("agents.json не читается (%s) — доступ %s не заморожен" % (exc, grant_id))
                    return False
                records = doc.get("agents") if isinstance(doc, dict) else doc
                if not isinstance(records, list):
                    return False
                found = False
                for raw in records:
                    if isinstance(raw, dict) and raw.get("id") == grant_id:
                        raw["compromised"] = True
                        raw["compromised_at"] = when
                        raw["compromised_ip"] = ip
                        found = True
                if not found:
                    return False
                directory = os.path.dirname(self.path) or "."
                tmp = os.path.join(directory, ".agents.json.%d.frz" % os.getpid())
                out = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                try:
                    os.write(out, json.dumps(doc, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8"))
                    os.fchmod(out, 0o600)
                    os.fsync(out)
                finally:
                    os.close(out)
                os.replace(tmp, self.path)
                self._doc = doc
                self._grants = self._parse(doc)
                self._stamp = self._stat(self.path)
                return True
            except OSError as exc:
                self.log.error("agents.json: заморозка доступа %s не записана: %s" % (grant_id, exc))
                return False
            finally:
                if fd is not None:
                    try:
                        os.close(fd)
                    except OSError:
                        pass

    def summary(self):
        grants = self.grants()
        return {"total": len(grants),
                "enabled": sum(1 for g in grants if g.enabled and not g.expired() and not g.compromised),
                "with_port": sum(1 for g in grants if g.port),
                "weak": sum(1 for g in grants if not g.require_token and g.mode != "rolling"),
                "pinned": sum(1 for g in grants if g.pin_ip),
                "rolling": sum(1 for g in grants if g.mode == "rolling"),
                "compromised": sum(1 for g in grants if g.compromised)}


class FailureTracker(object):
    """Неудачи по IP: HTTP_BAN_FAILURES за HTTP_BAN_WINDOW → бан на HTTP_BAN_SECONDS.

    Бан тоже отвечает 404 (не 429): подобравший 20 путей не должен узнать, что его заметили.
    Таблица ограничена по размеру — иначе сканер с миллиона адресов раздул бы память процесса.
    """

    def __init__(self, limit=HTTP_BAN_FAILURES, window=HTTP_BAN_WINDOW, ban=HTTP_BAN_SECONDS, now=time.monotonic):
        self.limit, self.window, self.ban, self.now = limit, window, ban, now
        self._lock = threading.Lock()
        self._fails = {}      # ip → [timestamps]
        self._banned = {}     # ip → until

    def banned(self, ip):
        with self._lock:
            until = self._banned.get(ip)
            if until is None:
                return False
            if until <= self.now():
                del self._banned[ip]
                return False
            return True

    def forget(self, ip):
        """Успешная проверка ключа обнуляет счётчик неудач адреса (MCP_ROTATION §11.5).

        Без этого агент, у которого однажды разъехались часы или потерялся ответ, копил бы
        неудачи между удачными вызовами и через двадцать таких промахов забанил бы сам себя —
        причём выглядело бы это как молчаливый отзыв доступа.
        """
        with self._lock:
            self._fails.pop(ip, None)

    def unban(self, ips):
        """Снять бан и счётчик с перечисленных адресов. → сколько банов снято.

        Зовётся при ПЕРЕВЫПУСКЕ доступа. Без этого честный агент после заморозки успевал
        забанить собственный адрес — заморожённый доступ отвечает отказом на каждый вызов,
        двадцать вызовов подряд набираются за минуты, — и владелец, ответивший «это был я»,
        наблюдал, как новый ключ те же десять минут получает 404. Бан по адресу задуман
        против перебора чужих путей, а не против агента, которому только что выдали новый.
        """
        lifted = 0
        with self._lock:
            for ip in ips:
                if not ip:
                    continue
                if self._banned.pop(ip, None) is not None:
                    lifted += 1
                self._fails.pop(ip, None)
        return lifted

    def record(self, ip):
        """Отметить неудачу; True — этим запросом IP забанен."""
        now = self.now()
        with self._lock:
            stamps = [t for t in self._fails.get(ip, []) if now - t < self.window]
            stamps.append(now)
            self._fails[ip] = stamps
            if len(self._fails) > HTTP_FAILURE_TABLE_MAX:
                for key in [k for k, v in self._fails.items() if not v or now - v[-1] >= self.window]:
                    del self._fails[key]
                while len(self._fails) > HTTP_FAILURE_TABLE_MAX:
                    self._fails.pop(next(iter(self._fails)))
            if len(stamps) >= self.limit:
                self._banned[ip] = now + self.ban
                del self._fails[ip]
                return True
            return False



class RateLimiter(object):
    """Скользящее окно удачных вызовов на доступ: HTTP_RATE_CALLS за HTTP_RATE_WINDOW.

    Отказ здесь — честный 429 с Retry-After, а НЕ 404: предел частоты ничего не рассказывает
    о существовании пути (запрос уже прошёл проверку ключа), а вот агенту нужно понять, что его
    просят притормозить, а не что доступ отозвали. Молчаливый 404 отправил бы его перевыпускать
    ключи на ровном месте.
    """

    def __init__(self, limit=HTTP_RATE_CALLS, window=HTTP_RATE_WINDOW, now=time.monotonic):
        self.limit, self.window, self.now = limit, window, now
        self._lock = threading.Lock()
        self._hits = {}       # id доступа → [моменты]

    def allow(self, grant_id):
        """→ (можно ли, сколько вызовов в окне). Первый отказ виден по счётчику limit + 1."""
        now = self.now()
        with self._lock:
            stamps = [t for t in self._hits.get(grant_id, []) if now - t < self.window]
            if len(stamps) >= self.limit:
                # Отказанный вызов в окно не кладём: иначе агент, упершийся в предел,
                # продлевал бы себе наказание каждой новой попыткой без конца.
                self._hits[grant_id] = stamps
                return False, len(stamps)
            stamps.append(now)
            self._hits[grant_id] = stamps
            return True, len(stamps)

    def forget(self, grant_id):
        with self._lock:
            self._hits.pop(grant_id, None)


# ── Одноразовый ключ: цепочка на доступ (MCP_ROTATION §1 в редакции §11) ──────

CHAIN_OK = "ok"          # пришёл текущий ключ — выполняем и выдаём следующий
CHAIN_REPLAY = "replay"  # предыдущий с тем же номером — ответ потерялся, отдаём сохранённый
CHAIN_PARALLEL = "par"   # предыдущий с ДРУГИМ номером, но запрос пришёл РАНЬШЕ, чем ушёл ответ
                         # с новым ключом: клиент послал два запроса разом и следующего ключа
                         # знать не мог. Выполняем и отдаём тот же новый ключ (§11.8)
CHAIN_CLONE = "clone"    # ключ из истории выданных — цепочка раздвоилась, замораживаем
CHAIN_BAD = "bad"        # такого ключа сервер не выдавал никогда — обычный неверный ключ
CHAIN_MALFORMED = "malformed"   # ключ или номер не той формы: отвечаем как всем, но в журнал пишем причину


def key_fingerprint(key):
    """Отпечаток ключа. В состоянии цепочки лежат отпечатки, а не ключи, — кроме текущего,
    который нужен целиком, чтобы повторить потерянный ответ вместе с тем же новым ключом."""
    return hashlib.sha256(key.encode("utf-8")).hexdigest()


def new_key():
    """Следующий ключ цепочки: те же 32 случайных байта в base64url, что у секрета и токена."""
    import secrets
    return secrets.token_urlsafe(32)


class ChainStore(object):
    """Состояние одноразовых цепочек: отдельный маленький файл на доступ (§11.6).

    Почему не в agents.json. Цепочка меняется на КАЖДОМ запросе. Ворочать ради двухсот байт весь
    реестр — с блокировкой, сортировкой и перезаписью — значит класть лишнюю работу на горячий
    путь и лишний раз рисковать общим файлом, в котором лежат все доступы. Реестр остаётся
    описанием доступа и меняется при выдаче, отзыве и заморозке.

    Почему каталог постоянный, а не /run. Тот чистится при перезагрузке: после включения сервера
    цепочка начиналась бы с нуля, а честный агент приходил бы со своим ключом — и объявлялся
    клоном. Ложная тревога с заморозкой, худший возможный исход.

    Что лежит в файле:
      origin     отпечаток первого ключа цепочки (он же в agents.json.key_hash) — метка цепочки:
                 перевыпуск меняет его, и прежнее состояние на диске само перестаёт действовать;
      cur/cur_key отпечаток и сам текущий ключ (первый ключ выдаёт не сервер, а agent-add, и до
                 первого вращения плоского значения у сервера просто нет — только отпечаток);
      prev, prev_nonce, prev_status, prev_body — предыдущий ключ, номер запроса, который его
                 сжёг, и ГОТОВЫЙ ответ на тот запрос: повтор обязан вернуть тот же ответ и НЕ
                 выполнить действие заново (§11.4), иначе потерянный ответ на «удалить
                 пользователя» удалял бы второй раз;
      history    отпечатки уже выданных ключей, последние HTTP_KEY_HISTORY_MAX. Это и есть
                 разница между клоном и мусором: в историю попадают только те ключи, которые
                 сервер сам выдал этому доступу, и посторонний в неё не попадает никогда;
      par        одновременные запросы тем же ключом (§11.8): номер и готовый ответ на каждый.
                 Они цепочку не вращают, но их повтор обязан отдавать сохранённый ответ — иначе
                 потерянный ответ на одновременный запрос выглядел бы клоном.

    Отметка «ответ с новым ключом ушёл» (_answered) на диск НЕ идёт и живёт только в памяти
    процесса: одновременность бывает лишь внутри одного запуска, а после перезапуска сервера
    ни один честный запрос не может быть «ещё в полёте».

    Права 0600. Файл держит и текущий ключ, и сохранённый ответ — то есть ровно те же секреты,
    что уже лежат в agents.json рядом.
    """

    def __init__(self, directory, log):
        self.dir = os.path.join(directory, "agents") if directory else ""
        self.log = log
        self._locks = {}
        self._answered = {}               # доступ → монотонное время, когда ушёл ответ с новым ключом
        self._master = threading.Lock()
        self._warned = False

    def mark_answered(self, grant_id):
        """Ответ с новым ключом только что ушёл агенту. С этого мгновения «я не мог знать
        следующий ключ» перестаёт быть правдой, и запрос прежним ключом — уже не одновременный."""
        with self._master:
            self._answered[grant_id] = time.monotonic()

    def answered_at(self, grant_id):
        """Когда в последний раз ушёл ответ с новым ключом; None — в этом запуске ещё ни разу."""
        with self._master:
            return self._answered.get(grant_id)

    def path(self, grant_id):
        return os.path.join(self.dir, grant_id + ".key")

    def freeze_failed_path(self, grant_id):
        return os.path.join(self.dir, grant_id + ".freeze_failed")

    def mark_freeze_failed(self, grant_id, ip, when):
        """Отметка «заморозить не удалось» (L-08): клон обнаружен, а agents.json в этот миг не записался (замок
        занят, реестр испорчен, запись упала) — доступ ЖИВ, и владелец должен увидеть это в карточке доступа, а не
        только в журнале. Файл рядом с цепочкой, не в реестре: реестр как раз и не пишется. agents_list (ядро)
        читает её в поле freeze_failed; снимают удачная заморозка, перевыпуск, выключение и отзыв доступа."""
        if not self.dir or not AGENT_ID_RE.match(str(grant_id)):
            return False
        path = self.freeze_failed_path(grant_id)
        tmp = "%s.%d.tmp" % (path, os.getpid())
        try:
            os.makedirs(self.dir, mode=0o700, exist_ok=True)
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump({"id": grant_id, "at": when, "ip": str(ip or "")}, fh)
            os.replace(tmp, path)
            return True
        except OSError as exc:
            self.log.error("доступ %s: отметку «заморозить не удалось» не записать: %s" % (grant_id, exc))
            try:
                os.unlink(tmp)
            except OSError:
                pass
            return False

    def clear_freeze_failed(self, grant_id):
        if not self.dir or not AGENT_ID_RE.match(str(grant_id)):
            return
        try:
            os.unlink(self.freeze_failed_path(grant_id))
        except OSError:
            pass

    def lock(self, grant_id):
        """Замок на доступ: два запроса одной цепочкой обязаны идти по очереди.

        Переходник и так держит замок на своей стороне (§1.2), но на честность клиента здесь
        полагаться нельзя: два потока, прочитавшие одно и то же состояние, вращали бы цепочку
        параллельно, и второй ответ объявил бы первого клоном.
        """
        with self._master:
            existing = self._locks.get(grant_id)
            if existing is None:
                existing = self._locks[grant_id] = threading.Lock()
            return existing

    @staticmethod
    def fresh(grant):
        """Цепочка, которой ещё не пользовались: текущий ключ — тот, что напечатал agent-add."""
        return {"grant": grant.id, "origin": grant.key_hash, "n": 0,
                "cur": grant.key_hash, "cur_key": "",
                "prev": "", "prev_nonce": "", "prev_status": 0, "prev_body": "",
                "history": [], "par": []}

    def load(self, grant):
        """Состояние цепочки доступа; нет файла, битый или от прежней цепочки → свежее."""
        try:
            with open(self.path(grant.id), "r", encoding="utf-8") as fh:
                state = json.load(fh)
        except (OSError, ValueError):
            return self.fresh(grant)
        if not isinstance(state, dict) or state.get("origin") != grant.key_hash:
            # Не наша цепочка: доступ перевыпущен (новый первый ключ), а файл остался от старой.
            # Начинаем заново — иначе агент с новым ключом попал бы в «мусор», а вор со старым
            # продолжал бы вращать чужую цепочку.
            return self.fresh(grant)
        out = self.fresh(grant)
        for key in ("cur", "cur_key", "prev", "prev_nonce", "prev_body"):
            if isinstance(state.get(key), str):
                out[key] = state[key]
        for key in ("n", "prev_status"):
            if isinstance(state.get(key), int) and not isinstance(state.get(key), bool):
                out[key] = state[key]
        if isinstance(state.get("history"), list):
            out["history"] = [str(x) for x in state["history"] if isinstance(x, str) and KEY_HASH_RE.match(x)]
        if isinstance(state.get("par"), list):
            for item in state["par"][-HTTP_CHAIN_PAR_MAX:]:
                if isinstance(item, dict) and isinstance(item.get("nonce"), str) and NONCE_RE.match(item["nonce"]):
                    status = item.get("status")
                    out["par"].append({"nonce": item["nonce"],
                                       "status": status if isinstance(status, int) and not isinstance(status, bool) else 0,
                                       "body": item["body"] if isinstance(item.get("body"), str) else ""})
        if not KEY_HASH_RE.match(out["cur"]):
            return self.fresh(grant)
        if out["prev"] and not out["cur_key"]:
            # Есть предыдущий ключ, но нет плоского текущего: повторить потерянный
            # ответ вместе с тем же новым ключом нечем. Такого сервер не пишет —
            # значит файл правили руками. Начинаем цепочку заново: агент получит
            # обычный отказ и перевыпуск, а не ложное обвинение в клоне.
            return self.fresh(grant)
        return out

    @staticmethod
    def classify(state, key, nonce, arrived=None, answered_at=None):
        """Решение по пришедшему ключу — таблица §11.1 плюс одновременность из §11.8.

        arrived — монотонное время, когда запрос пришёл (до ожидания замка!), answered_at — когда
        в последний раз ушёл ответ с новым ключом. Сравнение отпечатков — постоянного времени;
        истории это не касается: в ней лежат уже сожжённые ключи, и знание того, какой именно
        совпал, вору ничего не даёт.
        """
        if not (key and nonce and KEY_RE.match(key) and NONCE_RE.match(nonce)):
            # Ключ или номер не той формы. Ответ обязан остаться неотличимым от
            # любого другого отказа, а вот В ЖУРНАЛЕ причину назвать надо:
            # иначе агент с номером короче восьми знаков получает глухой 404 и
            # ни одной строки нигде — искать нечего. Поймано вживую на стенде.
            return CHAIN_MALFORMED
        
        fingerprint = key_fingerprint(key)
        if hmac.compare_digest(fingerprint, state["cur"]):
            return CHAIN_OK
        if state["prev"] and hmac.compare_digest(fingerprint, state["prev"]):
            # Предыдущий ключ. С ТЕМ ЖЕ номером — это дословный повтор той же попытки: ответ не
            # доехал (§1.1). Номер одновременного запроса — тоже повтор, но своего ответа.
            if state["prev_nonce"] and hmac.compare_digest(state["prev_nonce"], nonce):
                return CHAIN_REPLAY
            if ChainStore.saved_reply(state, nonce) is not None:
                return CHAIN_REPLAY
            # Другой номер. Если запрос пришёл РАНЬШЕ, чем ушёл ответ с новым ключом, отправитель
            # следующего ключа знать не мог — значит это второй запрос того же клиента, посланный
            # не дожидаясь первого ответа. Так после initialize делает большинство клиентов MCP.
            # Копия на чужой машине так выглядеть не может: её запрос приходит уже после того, как
            # ответ ушёл, — на этом различении всё и держится (§11.8).
            if arrived is not None and answered_at is not None and arrived < answered_at:
                return CHAIN_PARALLEL
            return CHAIN_CLONE
        if fingerprint in state["history"]:
            return CHAIN_CLONE
        # Ключ, которого сервер не выдавал этому доступу НИКОГДА. Это не доказательство клона, а
        # обычный неверный ключ: иначе всякий, кто узнал путь, гасил бы чужого агента одним
        # мусорным запросом, и защита превращалась бы в кнопку «выключить агента» для чужого.
        return CHAIN_BAD

    @staticmethod
    def saved_reply(state, nonce):
        """Сохранённый ответ на одновременный запрос с этим номером; None — такого номера нет."""
        for item in state["par"]:
            if hmac.compare_digest(item["nonce"], nonce):
                return item
        return None

    @staticmethod
    def add_parallel(state, nonce, status, body):
        """Состояние после одновременного запроса: цепочка НЕ вращается, ключ остаётся прежним.

        Вращать нельзя: первому из одновременных запросов следующий ключ уже отдан, и второй
        обязан получить тот же самый — иначе клиент, разобравший ответы в другом порядке, ушёл бы
        с ключом, которого сервер уже не ждёт. Сохранённый ответ здесь ради того же, ради чего
        он хранится у §11.4: повтор одновременного запроса не должен выполнить действие дважды.
        """
        kept = body if len(body) <= HTTP_CHAIN_REPLY_MAX else ""
        par = [item for item in state["par"] if not hmac.compare_digest(item["nonce"], nonce)]
        par.append({"nonce": nonce, "status": status, "body": kept})
        par = par[-HTTP_CHAIN_PAR_MAX:]
        # Общий предел на сохранённые ответы: состояние переписывается с fsync на КАЖДОМ
        # запросе, и шестнадцать ответов по четыре мегабайта превратили бы горячий путь в
        # перезапись десятков мегабайт. Номера остаются все — по ним повтор узнаётся и
        # действие не выполняется дважды; телом жертвуем у самых старых, и повтор такого
        # запроса честно получит «ответ не сохранён, действие НЕ повторено».
        budget, trimmed = HTTP_CHAIN_REPLY_MAX, []
        for item in reversed(par):
            body_kept = item["body"] if len(item["body"]) <= budget else ""
            budget -= len(body_kept)
            trimmed.append({"nonce": item["nonce"], "status": item["status"], "body": body_kept})
        trimmed.reverse()
        out = dict(state)
        out["par"] = trimmed
        out["updated"] = utc_now()
        return out

    @staticmethod
    def rotate(state, burned_key, nonce, status, body, issued):
        """Новое состояние после успешного запроса: сожжённый ключ → prev, выданный → cur."""
        history = list(state["history"])
        if state["prev"] and state["prev"] not in history:
            history.append(state["prev"])
        kept = body if len(body) <= HTTP_CHAIN_REPLY_MAX else ""
        return {"grant": state["grant"], "origin": state["origin"], "n": state["n"] + 1,
                "cur": key_fingerprint(issued), "cur_key": issued,
                "prev": key_fingerprint(burned_key), "prev_nonce": nonce,
                "prev_status": status, "prev_body": kept,
                "history": history[-HTTP_KEY_HISTORY_MAX:],
                # Одновременные запросы принадлежали прежнему ключу — с его сожжением они
                # перестают быть повторами и становятся обычным «ключ из истории».
                "par": [],
                "updated": utc_now()}

    def save(self, grant_id, state):
        """Записать состояние и дождаться, пока оно ляжет на диск. True — легло.

        Переименование атомарно по отношению к другим процессам, а не к отключению питания:
        без fsync ядро вправе держать и данные, и запись каталога в кэше сколько угодно. Поэтому
        fsync временного файла И каталога — и только потом ответ агенту (§10). При таком порядке
        любое выключение оставляет стороны согласованными: до записи оба на прежнем ключе, после
        записи и до ответа — повтор с тем же номером отдаст сохранённый ответ.

        Не легло — отвечать новым ключом НЕЛЬЗЯ: агент ушёл бы вперёд сервера, и его следующий
        законный запрос выглядел бы мусором.
        """
        if not self.dir:
            return False
        try:
            os.makedirs(self.dir, mode=0o700, exist_ok=True)
            data = json.dumps(state, ensure_ascii=False, sort_keys=True).encode("utf-8")
            tmp = os.path.join(self.dir, ".%s.%d.tmp" % (grant_id, os.getpid()))
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            try:
                # Цикл, а не один os.write: сохранённый ответ бывает в мегабайты, а короткая
                # запись оставила бы на диске обрезанный JSON — то есть цепочку без состояния.
                written = 0
                while written < len(data):
                    written += os.write(fd, data[written:])
                os.fsync(fd)
            finally:
                os.close(fd)
            os.replace(tmp, self.path(grant_id))
            dir_fd = os.open(self.dir, os.O_RDONLY)
            try:
                os.fsync(dir_fd)      # без этого само появление файла может не пережить питание
            finally:
                os.close(dir_fd)
            return True
        except OSError as exc:
            if not self._warned:
                self._warned = True
                self.log.error("состояние цепочек %s недоступно (%s) — доступы с одноразовым "
                               "ключом отвечают ошибкой, пока каталог не починен" % (self.dir, exc))
            return False


class HttpTransport(object):
    """Общее состояние всех слушателей: каталог, мост, доступы, бан, настройки Origin."""

    def __init__(self, settings, catalog, bridge, audit, log, grants, failures=None, notifier=None):
        self.settings = settings
        self.catalog = catalog
        self.bridge = bridge
        self.audit = audit
        self.log = log
        self.grants = grants
        self.failures = failures or FailureTracker()
        self.notifier = notifier or Notifier(settings.notify_dir, log)
        self.chains = ChainStore(settings.state_dir, log)
        self.clock = ClockWatch()
        self.rates = RateLimiter()
        self._alarms = {}                 # id доступа → когда в последний раз била тревога
        self._alarm_lock = threading.Lock()
        # Перевыпуск замечает сам реестр — он перечитывает файл при каждом запросе.
        self.grants.on_rotate = self.grant_reissued

    def _alarm_due(self, key, quiet):
        """Пропустить событие не чаще раза в quiet секунд по этому ключу."""
        now = time.monotonic()
        with self._alarm_lock:
            last = self._alarms.get(key)
            if last is not None and now - last < quiet:
                return False
            self._alarms[key] = now
            return True

    def grant_reissued(self, grant):
        """Доступ перевыпустили: снять бан с его адресов и обнулить его предел частоты.

        Замороженный доступ отвечает отказом на каждый вызов, а честный агент об этом не знает
        и продолжает звать: двадцать отказов набираются за минуты, и его собственный адрес
        уходит в бан на десять минут. Владелец отвечает «это был я», выдаётся новый ключ — а
        сервер ещё десять минут отвечает 404 по адресу, который к перебору не имеет отношения.
        Перевыпуск — это и есть решение владельца, и бан после него держать не за что.
        """
        lifted = self.failures.unban(grant.seen_ips())
        self.rates.forget(grant.id)
        if lifted:
            self.log.info("agent %s: перевыпущен — снят бан с %d адрес(ов)" % (grant.id, lifted))

    def check_clock(self):
        """Прыжок часов сервера: громко в журнал и владельцу, не чаще раза в десять минут."""
        jump = self.clock.check()
        if not jump:
            return 0
        self.log.error("часы сервера прыгнули на %+d с — агенты с плавающим путём промахнутся мимо "
                       "отрезка, пока не сверятся по Date заново" % jump)
        if self._alarm_due("clock_jump", CLOCK_ALARM_QUIET):
            self.notifier.send("server_clock_jump", {"delta_s": jump})
        return jump

    def notify_enrolled(self, grant, ip, storage):
        """Переходник привязан. Владелец увидит и чужую привязку: свою он в этот миг не делал (§7)."""
        self.notifier.send("agent_enrolled", {"agent": grant.id, "label": grant.label,
                                              "scope": grant.scope, "ip": ip, "storage": storage})

    def notify_expired(self, grant, ip):
        """Доступ истёк и уже отвечает отказом. Раньше он просто замолкал, и отличить
        истёкший от сломанного было нечем ни в одном интерфейсе."""
        if not self._alarm_due("expired:" + grant.id, HTTP_EXPIRY_ALARM_QUIET):
            return
        self.notifier.send("agent_expired", {"agent": grant.id, "label": grant.label,
                                             "scope": grant.scope, "expires": grant.expires, "ip": ip})

    def notify_expiring(self, grant):
        """Срок на исходе, доступ ещё работает: сказать заранее, чтобы продлить без простоя."""
        left = grant.seconds_left()
        if left is None or left > _expiry_warn_seconds(grant.term_days):
            return
        if not self._alarm_due("expiring:" + grant.id, HTTP_EXPIRY_ALARM_QUIET):
            return
        self.notifier.send("agent_expiring", {"agent": grant.id, "label": grant.label,
                                              "scope": grant.scope, "expires": grant.expires,
                                              "days_left": max(0, int(left // 86400))})

    def notify_rate_limited(self, grant, ip, hits):
        """Всплеск вызовов с одного доступа. Замысел (MCP_ROTATION §6) обещал событие —
        без него предел частоты выглядел бы для владельца как поломка агента."""
        if not self._alarm_due("rate:" + grant.id, HTTP_RATE_ALARM_QUIET):
            return
        self.notifier.send("agent_rate_limited", {"agent": grant.id, "label": grant.label,
                                                  "scope": grant.scope, "ip": ip, "calls": hits,
                                                  "window_s": int(HTTP_RATE_WINDOW)})

    def notify_use(self, grant, ip, event):
        """Первое использование доступа и вызов с нового адреса — событие владельцу."""
        if event not in ("first_use", "new_ip"):
            return
        self.notifier.send("agent_" + event, {"agent": grant.id, "label": grant.label,
                                              "scope": grant.scope, "ip": ip})

    def alarm_token(self, grant, ip):
        """Путь верный, токена нет или он чужой — адрес доступа где-то утёк и им уже пробуют
        воспользоваться. Тревожим не чаще раза в час на доступ: иначе сканер, нашедший адрес,
        сам себе устроил бы рассылку владельцу (бан по IP гасит его за 20 попыток, но события
        успели бы уйти)."""
        now = time.monotonic()
        with self._alarm_lock:
            last = self._alarms.get(grant.id)
            if last is not None and now - last < HTTP_ALARM_QUIET:
                return
            self._alarms[grant.id] = now
        self.notifier.send("agent_token_failed", {"agent": grant.id, "label": grant.label, "ip": ip})

    def raise_clone(self, grant, ip):
        """Пришёл ключ из истории выданных: цепочка раздвоилась. Заморозить и сказать владельцу.

        В карточку идут ДВА времени и ДВА адреса — когда и откуда работал доступ в последний раз
        и когда и откуда пришёл ключ, которого у настоящего агента быть уже не может. Владельцу
        этого хватает, чтобы отличить кражу от восстановления машины из вчерашней копии или от
        второго клиента на одном доступе (§11.2), не заглядывая в журналы.

        Признак frozen в событии — не украшение: если заморозить не удалось (реестр не пишется),
        доступ ЖИВ и клон работает дальше. Тогда и молчать час нельзя: тревога повторяется раз в
        минуту, пока владелец не вмешается или пока бан по адресу не погасит источник.
        """
        when = utc_now()
        frozen = self.grants.freeze(grant.id, ip, when)
        self.log.error("agent %s: ключ из истории выданных пришёл с адреса %s — доступ %s"
                       % (grant.id, ip, "заморожен" if frozen else "ЗАМОРОЗИТЬ НЕ УДАЛОСЬ"))
        # Не заморозили — отметка рядом с цепочкой (карточка доступа: «заморозить не удалось», L-08);
        # заморозили — прежняя отметка, если была, больше не правда.
        if frozen:
            self.chains.clear_freeze_failed(grant.id)
        else:
            self.chains.mark_freeze_failed(grant.id, ip, when)
        now = time.monotonic()
        quiet = HTTP_ALARM_QUIET if frozen else HTTP_ALARM_QUIET_LIVE
        with self._alarm_lock:
            last = self._alarms.get("clone:" + grant.id)
            if last is not None and now - last < quiet:
                return
            self._alarms["clone:" + grant.id] = now
        self.notifier.send("agent_compromised",
                           {"agent": grant.id, "label": grant.label, "scope": grant.scope,
                            "ip": ip, "clone_ip": ip, "clone_at": when,
                            "last_ip": grant.last_ip, "last_used": grant.last_used,
                            "frozen": frozen})

    def origin_allowed(self, origin, host):
        """Origin (если прислан) должен совпадать с Host по имени или быть в mcp.allowed_origins —
        защита от DNS-rebinding: страница с чужого сайта не должна ходить в наш сервер из браузера."""
        try:
            from urllib.parse import urlsplit
            parts = urlsplit(origin.strip())
        except ValueError:
            return False
        origin_host = (parts.hostname or "").lower()
        if not origin_host:
            return False
        host_name = (host or "").strip().lower()
        if host_name.startswith("["):
            host_name = host_name[1:host_name.find("]")] if "]" in host_name else host_name
        elif host_name.count(":") == 1:
            host_name = host_name.rsplit(":", 1)[0]
        if origin_host == host_name:
            return True
        normalized = origin.strip().lower().rstrip("/")
        return normalized in self.settings.allowed_origins or origin_host in self.settings.allowed_origins

    def make_server(self, grant, ip, user_agent):
        client = re.sub(r"[^\x21-\x7e]", "_", user_agent or "")[:60] or "-"
        return Server(self.settings, self.catalog, self.bridge, self.audit, self.log,
                      scope=grant.scope, agent_id=grant.id, origin="agent=%s ip=%s" % (grant.id, ip), client=client)


def _http_classes():
    """Классы HTTP собираются лениво: http.server и ssl не нужны stdio-режиму, а импорт при старте
    каждой SSH-сессии — лишние миллисекунды и лишние точки отказа."""
    import http.server
    import socket
    import socketserver

    class McpHttpHandler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"      # keep-alive: nginx проксирует с proxy_http_version 1.1
        timeout = 60                        # чтение запроса; мост отвечает до 300 с, но это уже запись
        arrived = None                      # монотонное время прихода запроса, ставит do_POST (§11.8)

        # --- служебное -------------------------------------------------------------------
        def version_string(self):
            return "nginx"                  # заголовок Server как у сайта-маскировки

        def log_request(self, code="-", size="-"):
            self.server.transport.log.debug("%s %s -> %s" % (self.command, mask_path(self.path), code))

        def log_error(self, fmt, *args):
            self.server.transport.log.debug("http: " + (fmt % args))

        def log_message(self, fmt, *args):
            self.server.transport.log.debug("http: " + mask_path(fmt % args))

        def client_ip(self):
            """Адрес агента. По нему считаются неудачи и баны, поэтому важно, ЧЕЙ это адрес.

            X-Real-IP и X-Forwarded-For ставит nginx директивой proxy_set_header, которая
            ПЕРЕЗАПИСЫВАЕТ присланное клиентом, — на петлевом слушателе, куда ходит только nginx,
            заголовок поэтому и есть доказательство. На публичном слушателе (lite со своим TLS-
            портом, персональные порты доступов) впереди нет никакого nginx: там заголовок
            целиком клиентский, и верить ему значило бы банить тот адрес, который назвал сам
            стучащийся, — то есть подставлять чужие адреса под чужие баны и уходить от своих.
            Поэтому на публичном слушателе адрес только один: адрес сокета.
            """
            peer = self.client_address[0]
            if self.server.public or not is_loopback(peer):
                return peer
            forwarded = self.headers.get("X-Real-IP") or (self.headers.get("X-Forwarded-For") or "").split(",")[0]
            forwarded = forwarded.strip()
            if forwarded:
                try:
                    return str(ipaddress.ip_address(forwarded))
                except ValueError:
                    pass
            return peer

        def bearer_token(self):
            """Токен доступа из Authorization: Bearer <token>; нет заголовка — пустая строка.

            Заголовок, а не адрес: адрес утекает снимком экрана, историей браузера и журналом
            прокси, заголовок туда не попадает. Разбор нарочно нестрогий — решает не он, а
            сравнение постоянного времени в Grant.token_ok."""
            raw = self.headers.get("Authorization") or ""
            match = BEARER_RE.match(raw)
            return match.group(1) if match else ""

        def send_bytes(self, status, body, content_type, extra=None, close=False):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            for key, value in (extra or []):
                self.send_header(key, value)
            if close:
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def send_404(self):
            self.send_bytes(404, NGINX_404, "text/html", close=True)

        def send_json(self, status, payload, extra=None):
            body = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
            self.send_bytes(status, body, "application/json", extra)

        def rpc_error(self, status, code, message):
            self.send_json(status, {"jsonrpc": "2.0", "id": None, "error": {"code": code, "message": message}})

        # --- методы ------------------------------------------------------------------------
        def do_GET(self):
            self._not_post()

        do_HEAD = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_GET

        def _not_post(self):
            """GET (поток сервер→клиент нам не нужен) и прочее на НАСТОЯЩЕМ адресе доступа → 405 (так велит
            спецификация MCP клиенту, открывающему поток); на адресе верной формы, но чужом — тот же 404, что
            у сайта: иначе один GET по случайному /a-<43 знака>/mcp выдавал сканеру, что здесь MCP
            (находка аудита безопасности 25.09.2026)."""
            path_only = self.path.split("?", 1)[0]
            m_fixed = HTTP_PATH_RE.match(path_only)
            m_float = HTTP_FLOAT_RE.match(path_only)
            if (m_fixed or m_float) and self.server.transport.grants.path_known(
                    m_fixed.group(1) if m_fixed else None, m_float.group(1) if m_float else None):
                self.send_json(405, {"error": "method not allowed", "hint": "POST JSON-RPC to this URL"},
                               extra=[("Allow", "POST")])
                return
            # Корень — не подбор пути: по нему переходник сверяет часы по Date на холодном старте
            # (§3), а через SSH-туннель он приходит сюда, минуя nginx. Считай корень промахом — и
            # клиент MCP, который перезапускает переходник, сам бы загнал в бан адрес туннеля.
            if self.path.split("?", 1)[0] != "/":
                self.server.transport.failures.record(self.client_ip())
            self.send_404()

        def do_POST(self):
            transport = self.server.transport
            # Время прихода запроса снимается ДО разбора и ДО ожидания замка: им доказывается
            # одновременность (§11.8), а запрос, простоявший в очереди за чужим, пришёл всё-таки
            # тогда, когда пришёл. Часы монотонные: перевод календарных не должен ни превращать
            # честный запрос в клона, ни наоборот.
            self.arrived = time.monotonic()
            ip = self.client_ip()
            transport.check_clock()
            path_only = self.path.split("?", 1)[0]
            match = HTTP_PATH_RE.match(path_only)
            float_match = HTTP_FLOAT_RE.match(path_only)
            enroll_match = HTTP_ENROLL_RE.match(path_only)
            # Реестр перечитывается ДО проверки бана (чтение дешёвое — по mtime): именно на
            # перечитывании замечается перевыпуск, а он снимает бан с адресов доступа. Проверь
            # бан раньше — и первый же запрос с новым ключом получил бы 404, то есть ответ
            # владельца «это был я» не действовал бы до конца бана.
            transport.grants.grants()
            if transport.failures.banned(ip):
                self.send_404()
                return
            # Порядок проверок закреплён (§11.5): СПЕРВА путь и срок доступа, ПОТОМ ключ. Промах
            # мимо пути состояние цепочки не трогает вовсе — иначе чужой запрос по чужому адресу
            # жёг бы ключи живого агента, и разъехавшиеся часы или сканер гасили бы работу.
            if enroll_match is not None:
                self._serve_enroll(transport, enroll_match.group(1), ip)
                return
            if match is None and float_match is None:
                self._fail(ip, "path")
                return
            if float_match is not None:
                grant, why = transport.grants.authenticate_float(float_match.group(1), self.bearer_token(), ip,
                                                                 self.server.only_grant_id,
                                                                 transport.settings.port_exclusive)
            else:
                grant, why = transport.grants.authenticate(match.group(1), self.bearer_token(), ip,
                                                           self.server.only_grant_id,
                                                           transport.settings.port_exclusive)
            if why != "ok":
                # Отказ по второму фактору или по закреплённому адресу — не рядовой промах
                # сканера: путь-то верный. Об этом стоит знать владельцу, но ответ всё равно
                # ровно тот же 404 (см. верх файла: 401 подтвердил бы существование пути).
                if grant is not None and why in ("token", "pin"):
                    transport.log.warn("agent %s: отказ %s с адреса %s — адрес доступа мог утечь"
                                       % (grant.id, why, ip))
                    if why == "token":
                        transport.alarm_token(grant, ip)
                elif grant is not None:
                    transport.log.info("agent %s: отказ %s с адреса %s" % (grant.id, why, ip))
                    if why == "expired":
                        transport.notify_expired(grant, ip)
                self._fail(ip, why, grant=grant)
                return
            # Тревогу про срок НЕ шлём здесь: этот же вызов через touch() срок
            # продлит, и владелец получал бы «истекает через N дней» ровно в тот
            # миг, когда доступ ожил. Решение принимается после учёта вызова, по
            # состоянию, которое уже сложилось.
            if grant.mode != "rolling":
                if self._rate_refused(transport, grant, ip):
                    return
                # Успешная проверка ключа обнуляет счётчик неудач адреса (§11.5): у static ключ —
                # это токен, и он только что сошёлся.
                transport.failures.forget(ip)
                self._serve_rpc(transport, grant, ip, None)
                return
            self._serve_rolling(transport, grant, ip)

        def _rate_refused(self, transport, grant, ip):
            """Предел частоты — ПОСЛЕ проверки ключа целиком и ДО запуска моста: каждый вызов
            запускает install.sh под root, и законно вошедший доступ тоже не должен уметь звать его
            без конца (MCP_ROTATION §6). У rolling «ключ целиком» — это и одноразовый ключ цепочки:
            раньше слот списывался уже после пути и токена, и тот, кому утекли только они, мог
            держать настоящего агента в 429 запросами с негодным ключом (аудит 25.09.2026).
            True — отказ 429 уже отправлен."""
            allowed, hits = transport.rates.allow(grant.id)
            if allowed:
                return False
            transport.log.warn("agent %s: предел частоты — %d вызовов за %.0f с с адреса %s"
                               % (grant.id, hits, HTTP_RATE_WINDOW, ip))
            transport.notify_rate_limited(grant, ip, hits)
            # Честный 429, а не 404: запрос уже доказал знание ключа, скрывать от него
            # нечего, а молчаливый 404 отправил бы агента перевыпускать доступ впустую.
            self._drain_body()
            self.send_json(429, {"jsonrpc": "2.0", "id": None,
                                 "error": {"code": INTERNAL_ERROR,
                                           "message": "rate limit: %d calls per %ds; slow down and retry"
                                                      % (HTTP_RATE_CALLS, int(HTTP_RATE_WINDOW))}},
                           extra=[("Retry-After", str(HTTP_RATE_RETRY_AFTER))])
            return True

        def _serve_rolling(self, transport, grant, ip):
            """Доступ с одноразовым ключом: решение по таблице §11.1 под замком на доступ."""
            key = (self.headers.get(KEY_HEADER) or "").strip()
            nonce = (self.headers.get(NONCE_HEADER) or "").strip()
            with transport.chains.lock(grant.id):
                state = transport.chains.load(grant)
                verdict = ChainStore.classify(state, key, nonce, arrived=self.arrived,
                                              answered_at=transport.chains.answered_at(grant.id))
                if verdict == CHAIN_CLONE:
                    transport.raise_clone(grant, ip)
                    self._fail(ip, "clone")
                    return
                if verdict == CHAIN_MALFORMED:
                    # Ответ тот же, что у всех отказов, а в журнале причина названа:
                    # иначе агент с номером не той формы получал глухой отказ и ни
                    # одной строки нигде. Формат номера: 8–64 знака [A-Za-z0-9_-].
                    # .warn, а не .warning: журнал здесь свой, не стандартный, и
                    # метода warning у него нет — вызов падал с ошибкой прямо в
                    # обработчике, и соединение рвалось без ответа вовсе.
                    transport.log.warn(
                        "agent %s: заголовки одноразового ключа не той формы "
                        "(X-Ga-Key — %d знаков, X-Ga-Nonce — %d; номер должен быть 8–64 знака "
                        "из букв, цифр, дефиса и подчёркивания) с адреса %s"
                        % (grant.id, len(key), len(nonce), ip))
                    self._fail(ip, "key")
                    return
                if verdict == CHAIN_BAD:
                    # Обычный неверный ключ: тот же 404 и та же копилка неудач, что у чужого пути.
                    self._fail(ip, "key")
                    return
                transport.failures.forget(ip)
                if verdict == CHAIN_REPLAY:
                    # Ответ не доехал, агент повторил дословно (§1.1). Отдаём СОХРАНЁННЫЙ ответ и
                    # тот же новый ключ, а действие заново не выполняем (§11.4): первый вызов мог
                    # быть «удалить пользователя», и повтор удалил бы второго. Повтор
                    # одновременного запроса (§11.8) лежит в par и отдаётся ровно так же.
                    self._drain_body()
                    transport.log.info("agent %s: повтор с прежним ключом и тем же номером — отдан "
                                       "сохранённый ответ, действие заново не выполнялось" % grant.id)
                    kept = ChainStore.saved_reply(state, nonce)
                    saved = state["prev_body"] if kept is None else kept["body"]
                    status = state["prev_status"] if kept is None else kept["status"]
                    if not saved and status not in (202,):
                        # Ответ был слишком велик, чтобы его хранить. Главное всё равно соблюдено:
                        # действие не повторено. Агенту честно говорим, что ответ утрачен, — и отдаём
                        # следующий ключ: без него клиент остался бы на прежнем и следующим запросом
                        # пришёл бы «копией» доступа.
                        self.send_json(200, {"jsonrpc": "2.0", "id": None,
                                             "error": {"code": INTERNAL_ERROR,
                                                       "message": "previous answer was not kept; the action was NOT repeated"}},
                                       extra=[(NEXT_KEY_HEADER, state["cur_key"])])
                        return
                    self.send_bytes(status or 200, saved.encode("utf-8"),
                                    "application/json", extra=[(NEXT_KEY_HEADER, state["cur_key"])])
                    return
                if verdict == CHAIN_PARALLEL:
                    # Два запроса одним ключом от одного клиента (§11.8). Выполняем как обычный,
                    # но цепочку не вращаем: следующий ключ уже выдан первому из них.
                    transport.log.info("agent %s: второй запрос тем же ключом пришёл раньше, чем ушёл "
                                       "ответ с новым, — это одновременность, а не копия" % grant.id)
                # Слот частоты — только за доказанный ключ; повтор (выше) мост не запускает и слота
                # не тратит. Отказ 429 цепочку не вращает: агент повторит тем же ключом.
                if self._rate_refused(transport, grant, ip):
                    return
                self._serve_rpc(transport, grant, ip, (state, key, nonce), parallel=(verdict == CHAIN_PARALLEL))

        def _busy(self):
            """Первое закрепление адреса не дождалось config.lock — честный 503 с Retry-After (SEC46-01).

            Не 404: для клиента 404 значит «доступ отозван», а его никто не отзывал — замок держит долгое
            действие моста или каталога замка ещё нет после перезагрузки. И не неудача подбора: запрос
            уже доказал знание пути и ключа. Действие не выполнялось, цепочка ключей не сдвинута —
            повтор идёт тем же ключом, как после 429."""
            self.send_json(503, {"jsonrpc": "2.0", "id": None,
                                 "error": {"code": INTERNAL_ERROR,
                                           "message": "server busy: another action holds the configuration "
                                                      "lock; nothing was executed, retry later"}},
                           extra=[("Retry-After", str(HTTP_BUSY_RETRY_AFTER))])

        def _drain_body(self):
            """Дочитать тело повтора: без этого следующий запрос по тому же keep-alive соединению
            начался бы читаться с середины чужого тела."""
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = -1
            if 0 < length <= HTTP_MAX_BODY:
                self.rfile.read(length)
            elif length != 0:
                self.close_connection = True

        def _serve_rpc(self, transport, grant, ip, chain, parallel=False):
            """Разобрать и выполнить запрос доступа; chain — состояние цепочки или None (static).

            parallel — запрос пришёл одновременно с предыдущим (§11.8): он выполняется, но цепочку
            не двигает и получает тот же ключ, что уже ушёл первому.
            """
            origin = self.headers.get("Origin")
            if origin and not transport.origin_allowed(origin, self.headers.get("Host")):
                transport.log.warn("agent %s: чужой Origin отклонён (%s)" % (grant.id, mask_path(origin)[:80]))
                self.send_json(403, {"error": "origin not allowed"})
                return
            version = self.headers.get("MCP-Protocol-Version")
            if version and version not in SUPPORTED_PROTOCOL_VERSIONS:
                self.rpc_error(400, INVALID_REQUEST, "Unsupported MCP-Protocol-Version: %s" % version[:40])
                return
            length_raw = self.headers.get("Content-Length")
            if length_raw is None:
                self.rpc_error(411, INVALID_REQUEST, "Content-Length required")
                return
            try:
                length = int(length_raw)
            except ValueError:
                self.rpc_error(400, INVALID_REQUEST, "Bad Content-Length")
                return
            if length < 0 or length > HTTP_MAX_BODY:
                self.rpc_error(413, INVALID_REQUEST, "Request body too large (limit %d bytes)" % HTTP_MAX_BODY)
                return
            body = self.rfile.read(length) if length else b""
            server = transport.make_server(grant, ip, self.headers.get("User-Agent"))
            def admit_execution():
                verdict = transport.grants.claim_pin(grant, ip)
                if verdict == "busy":
                    raise AdmissionBusy()
                if verdict not in ("ok", "claimed"):
                    raise AdmissionDenied()
                if verdict == "claimed":
                    transport.log.info("agent %s: адрес закреплён за %s (pin_ip)" % (grant.id, ip))
            server.before_execute = admit_execution
            try:
                responses = server.handle_line(body.strip() or b"", allow_batch=False)
            except AdmissionBusy:
                self._busy()
                return
            except AdmissionDenied:
                self._fail(ip, "pin", grant=grant)
                return
            event, pinned = transport.grants.touch(grant.id, ip)
            # Теперь, когда продление уже применено, смотрим на срок: если он
            # всё ещё на исходе, значит доступом давно не пользовались — ровно
            # то, о чём тревога и говорит.
            fresh = grant
            for _g in transport.grants.grants():
                if _g.id == grant.id:
                    fresh = _g
                    break
            transport.notify_expiring(fresh)
            if pinned:
                transport.log.info("agent %s: адрес закреплён за %s (pin_ip)" % (grant.id, ip))
            transport.notify_use(grant, ip, event)
            if not responses:
                # Только уведомления — по спецификации 202 без тела
                status, text = 202, ""
            else:
                payload = responses[0] if len(responses) == 1 else responses
                status = 200
                if isinstance(payload, dict) and payload.get("error", {}).get("code") in (PARSE_ERROR, INVALID_REQUEST):
                    status = 400
                text = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
            if chain is not None:
                state, key, nonce = chain
                if parallel:
                    # Ключ не меняется: первому из одновременных запросов следующий уже отдан, и
                    # этот обязан получить тот же самый. Записать номер и ответ всё равно нужно —
                    # чтобы повтор ЭТОГО запроса не выполнил действие второй раз. Не записалось —
                    # отвечаем всё равно: ключ не разъехался, потеряна только защита от повтора,
                    # а отказ после выполненного действия был бы хуже (агент повторил бы его).
                    if not transport.chains.save(grant.id, ChainStore.add_parallel(state, nonce, status, text)):
                        transport.log.warn("agent %s: одновременный запрос выполнен, но его ответ не "
                                           "сохранён — повтор выполнит действие заново" % grant.id)
                    self.send_bytes(status, text.encode("utf-8"), "application/json",
                                    [(NEXT_KEY_HEADER, state["cur_key"])])
                    return
                issued = new_key()
                # Порядок из §10: ключ проверен → действие выполнено → следующий ключ сгенерирован
                # → состояние ЗАПИСАНО и дошло до диска → и только теперь ответ. Иначе выключение
                # питания между «отдал» и «записал» объявило бы честного агента клоном.
                if not transport.chains.save(grant.id, ChainStore.rotate(state, key, nonce, status, text, issued)):
                    # Ответить новым ключом нельзя: агент ушёл бы вперёд сервера. Цепочка осталась
                    # на прежнем ключе, повтор выполнит действие ещё раз — это ровно первая строка
                    # таблицы §10 и лучшее, что можно сделать без диска.
                    self.rpc_error(500, INTERNAL_ERROR, "chain state was not persisted; retry with the same key")
                    return
                self.send_bytes(status, text.encode("utf-8"), "application/json",
                                [(NEXT_KEY_HEADER, issued)])
                # Ответ с новым ключом ушёл — и только теперь запрос прежним ключом перестаёт быть
                # одновременным. Отметка ставится ПОСЛЕ отправки: всё, что пришло раньше неё,
                # следующего ключа знать не могло (§11.8).
                transport.chains.mark_answered(grant.id)
                return
            # static: цепочки нет, следующего ключа тоже — отвечаем как есть
            self.send_bytes(status, text.encode("utf-8"), "application/json")

        def _serve_enroll(self, transport, path_token, ip):
            """Привязка переходника одноразовым кодом (MCP_ROTATION §7).

            Код по сети не едет — приходит его отпечаток путём. Неверный, истёкший и уже
            использованный код отвечают тем же 404, что и чужой путь, и считаются подбором.
            Секреты (rot_seed, токен, первый ключ) создаются здесь и уходят один раз в этом ответе.
            """
            grant, why = transport.grants.pending_enrollment(path_token, ip=ip,
                                                              only_grant_id=self.server.only_grant_id,
                                                              port_exclusive=transport.settings.port_exclusive)
            if why != "ok":
                if grant is not None:
                    transport.log.info("agent %s: привязка отклонена (%s) с адреса %s" % (grant.id, why, ip))
                self._fail(ip, "enroll" if grant is None else "enroll_" + why)
                return
            try:
                length = int(self.headers.get("Content-Length") or "0")
            except ValueError:
                length = -1
            if length < 0 or length > ENROLL_BODY_MAX:
                self._fail(ip, "enroll_body")
                return
            raw = self.rfile.read(length) if length else b""
            try:
                req = json.loads(raw.decode("utf-8")) if raw.strip() else {}
            except ValueError:
                req = {}
            if not isinstance(req, dict):
                req = {}
            storage = str(req.get("key_storage") or "file")
            if storage not in KEY_STORAGE_KINDS:
                storage = "file"
            rot_seed = b64url(secrets.token_bytes(32))
            token = b64url(secrets.token_bytes(32))
            key = b64url(secrets.token_bytes(32))
            updates = {"rot_seed": rot_seed, "token": token, "require_token": True, "mode": "rolling",
                       "key_hash": hashlib.sha256(key.encode("utf-8")).hexdigest(),
                       "key_storage": storage, "enrolled_at": utc_now(), "enrolled_ip": ip,
                       "compromised": False}
            if grant.pin_ip:
                # Привязка к адресу у переходника закрепляется за машиной, которая привязалась, —
                # это и есть «первое использование». Адрес прежней привязки сюда не доживает:
                # иначе каждый вызов с новой машины после перевыпуска получал бы 404.
                updates["pinned_ip"] = ip
            if not transport.grants.complete_enrollment(grant.id, path_token, updates):
                self._fail(ip, "enroll_write")
                return
            transport.failures.forget(ip)
            transport.notify_enrolled(grant, ip, storage)
            transport.audit.write("enroll", "-", "agent-enroll", {"agent": grant.id, "storage": storage},
                                  "success", "", 0, client=str(req.get("client") or "-")[:60],
                                  origin="agent=%s ip=%s" % (grant.id, ip), agent=grant.id)
            transport.log.info("agent %s: привязан переходником с адреса %s, ключ хранится: %s"
                               % (grant.id, ip, storage))
            self.send_json(200, {"grant": grant.id, "rot_seed": rot_seed, "token": token, "key": key,
                                 "label": grant.label, "scope": grant.scope},
                           extra=[("Cache-Control", "no-store")])

        def _fail(self, ip, why, grant=None):
            transport = self.server.transport
            # Отказ по СОСТОЯНИЮ доступа (выключен, истёк, заморожен) счётчик подбора не
            # трогает: запрос пришёл по верному секретному пути, то есть это не перебор, а
            # честный агент, которому ещё не сказали, что доступ закрыли. Раньше он за
            # двадцать таких вызовов банил собственный адрес на десять минут — и владелец,
            # ответивший «это был я», всё равно ждал. Подбор пути, чужой токен и чужой
            # ключ считаются по-прежнему.
            if why in ("disabled", "expired", "compromised"):
                transport.log.debug("http: отказ %s для %s (%s) — счётчик подбора не трогаем"
                                    % (why, ip, grant.id if grant is not None else "-"))
                self.send_404()
                return
            if transport.failures.record(ip):
                transport.log.warn("http: IP %s забанен на %.0f с после %d неудач (последняя: %s)"
                                   % (ip, HTTP_BAN_SECONDS, HTTP_BAN_FAILURES, why))
            else:
                transport.log.debug("http: отказ %s для %s (%s)" % (why, ip, mask_path(self.path)))
            self.send_404()

    class McpHttpServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True
        allow_reuse_address = True
        request_queue_size = 64

        def __init__(self, address, transport, only_grant_id=None, name="main"):
            if ":" in address[0]:
                self.address_family = socket.AF_INET6
            self.transport = transport
            self.only_grant_id = only_grant_id
            self.name = name
            # Петлевой слушатель — тот, перед которым стоит nginx; публичный слушает интернет
            # сам. От этого зависит, чьи заголовки считать доказательством (см. client_ip).
            self.public = not (is_loopback(address[0]) or address[0] == "localhost")
            http.server.HTTPServer.__init__(self, address, McpHttpHandler)

        # TLS-рукопожатие — в рабочем потоке и со сроком, а не в accept() единственного потока serve_forever:
        # там одно молчащее TCP-соединение подвешивало весь слушатель (аудит безопасности 25.09.2026).
        def get_request(self):
            sock, addr = self.socket.accept()
            if hasattr(sock, "do_handshake"):
                sock.settimeout(TLS_HANDSHAKE_TIMEOUT)
            return sock, addr

        def finish_request(self, request, client_address):
            if hasattr(request, "do_handshake"):
                try:
                    request.do_handshake()
                except (OSError, ValueError):
                    return
                # Дальше — прежние сроки: их ставит сам обработчик (timeout класса), рукопожатию хватило своего.
                request.settimeout(None)
            http.server.HTTPServer.finish_request(self, request, client_address)

        def handle_error(self, request, client_address):
            # Обрыв TLS-рукопожатия сканером — не повод печатать traceback на каждый коннект
            self.transport.log.debug("http: ошибка соединения с %s: %s" % (client_address[0], traceback.format_exc().splitlines()[-1]))

    return McpHttpServer


def make_tls_context(cert_path, key_path):
    import ssl
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(cert_path, key_path)
    return ctx


class HttpOptions(object):
    """Разбор аргументов --http … (см. usage в main). Ошибка разбора → ValueError с текстом."""

    def __init__(self, settings):
        self.bind = DEFAULT_HTTP_BIND
        self.port = settings.http_port or DEFAULT_HTTP_PORT
        self.tls = None            # (cert, key) для основного слушателя
        self.extra_tls = None      # (cert, key) для персональных портов; по умолчанию = tls
        self.extra_bind = "0.0.0.0"
        self.extra_ports = "auto"  # auto — порты доступов из agents.json; none — не открывать; список

    @staticmethod
    def _pair(value, flag):
        parts = [p.strip() for p in str(value).split(",")]
        if len(parts) != 2 or not all(parts):
            raise ValueError("%s ожидает cert.pem,key.pem" % flag)
        for path in parts:
            if not os.path.isfile(path):
                raise ValueError("%s: файла %s нет" % (flag, path))
        return parts[0], parts[1]

    def apply(self, flag, value):
        if flag == "--bind":
            self.bind = value
        elif flag == "--port":
            self.port = int(value)
            if not 1 <= self.port <= 65535:
                raise ValueError("--port вне 1..65535")
        elif flag == "--tls":
            self.tls = self._pair(value, flag)
        elif flag == "--extra-tls":
            self.extra_tls = self._pair(value, flag)
        elif flag == "--extra-bind":
            self.extra_bind = value
        elif flag == "--extra-ports":
            self.extra_ports = value
        else:
            raise ValueError("неизвестный ключ %s" % flag)

    def resolved_extra_ports(self, grants):
        """[(port, grant_id)] персональных слушателей: auto — из agents.json, иначе явный список
        (порт без доступа в agents.json — предупреждение и пропуск: слушать некому)."""
        by_port = {}
        for grant in grants:
            if grant.port and grant.port not in by_port:
                by_port[grant.port] = grant.id
        if self.extra_ports == "auto":
            return sorted(by_port.items())
        if self.extra_ports in ("none", ""):
            return []
        out = []
        for item in str(self.extra_ports).split(","):
            item = item.strip()
            if not item:
                continue
            port = int(item)
            if not 1 <= port <= 65535:
                raise ValueError("--extra-ports: порт %s вне 1..65535" % item)
            out.append((port, by_port.get(port)))
        return out


def serve_http(settings, catalog, bridge, audit, log, options):
    """Поднять слушатели и работать до SIGTERM/SIGINT. Код возврата — как у процесса."""
    McpHttpServer = _http_classes()
    grants = GrantStore(settings.agents_json, settings.lock_file, log)
    transport = HttpTransport(settings, catalog, bridge, audit, log, grants)
    listeners = []

    # Публичный слушатель без TLS — открытый текст для сканеров всего интернета: не поднимаем.
    if not is_loopback(options.bind) and options.bind not in ("localhost",) and options.tls is None:
        log.error("--bind %s вне петли требует --tls cert.pem,key.pem (перед петлёй TLS терминирует nginx)" % options.bind)
        return 2
    extra_tls = options.extra_tls or options.tls
    try:
        extra_ports = options.resolved_extra_ports(grants.grants())
    except ValueError as exc:
        log.error(str(exc))
        return 2

    def listen(bind, port, tls, only_grant_id, name):
        try:
            httpd = McpHttpServer((bind, port), transport, only_grant_id, name)
        except OSError as exc:
            log.error("слушатель %s на %s:%d не поднялся: %s" % (name, bind, port, exc))
            return None
        if tls is not None:
            try:
                httpd.socket = make_tls_context(tls[0], tls[1]).wrap_socket(httpd.socket, server_side=True,
                                                                             do_handshake_on_connect=False)
            except (OSError, ValueError) as exc:
                log.error("слушатель %s: TLS не настроен (%s)" % (name, exc))
                httpd.server_close()
                return None
        thread = threading.Thread(target=httpd.serve_forever, kwargs={"poll_interval": 0.5},
                                  name="mcp-http-" + name)
        thread.daemon = True
        thread.start()
        log.info("слушаю %s:%d (%s%s%s)" % (bind, port, name, ", TLS" if tls else ", без TLS",
                                            (", только доступ %s" % only_grant_id) if only_grant_id else ""))
        return httpd

    main_httpd = listen(options.bind, options.port, options.tls, None, "main")
    if main_httpd is None:
        return 3
    listeners.append(main_httpd)
    for port, grant_id in extra_ports:
        if grant_id is None:
            log.warn("--extra-ports: за портом %d нет доступа в agents.json — слушатель не открыт" % port)
            continue
        if extra_tls is None and not is_loopback(options.extra_bind):
            log.error("персональный порт %d доступа %s: нужен --extra-tls (или --tls) — слушатель не открыт" % (port, grant_id))
            continue
        httpd = listen(options.extra_bind, port, extra_tls, grant_id, "port-%d" % port)
        if httpd is not None:
            listeners.append(httpd)

    summary = grants.summary()
    log.info("HTTP-транспорт запущен: доступов %d (действующих %d, с портом %d, без токена %d, "
             "с привязкой к адресу %d, с одноразовым ключом %d, замороженных %d), agents.json %s, "
             "состояние цепочек %s, замок %s, очередь уведомлений %s"
             % (summary["total"], summary["enabled"], summary["with_port"], summary["weak"], summary["pinned"],
                summary["rolling"], summary["compromised"], settings.agents_json,
                transport.chains.dir, settings.lock_file, settings.notify_dir))
    if summary["weak"]:
        log.warn("доступов без второго фактора: %d — утёкший адрес такого доступа сам по себе "
                 "даёт управление; усильте их (agent-harden)" % summary["weak"])
    if summary["compromised"]:
        log.warn("замороженных доступов (обнаружен клон): %d — они не впускают до решения "
                 "владельца: перевыпустить (agent-rotate) или отозвать (agent-del)" % summary["compromised"])

    stop = threading.Event()

    def on_signal(signum, frame):
        log.info("сигнал %d, останавливаюсь" % signum)
        stop.set()

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    try:
        while not stop.is_set():
            stop.wait(1.0)
    finally:
        for httpd in listeners:
            httpd.shutdown()
            httpd.server_close()
    return 0


# ---------------------------------------------------------------------------------------------
# Транспорт stdio и точка входа
# ---------------------------------------------------------------------------------------------

def debug_rpc_line(raw):
    """Строка для журнала debug о сообщении JSON-RPC — БЕЗ значений: метод, id, инструмент, имена аргументов с
    длинами; у ответа — id, код ошибки или размер результата.

    Раньше в журнал шли первые 512 байт сообщения как есть: у tools/call user_attach_key это ключ человека
    («config»: «[Interface] PrivateKey = …»), у ответа user_key — выданный .conf с приватным ключом, — и оба
    уезжали в stderr и journald, хотя аудит и argv моста секреты прячут (находка TK-6)."""
    try:
        msg = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return "<%d bytes, not JSON>" % len(raw)
    if isinstance(msg, list):
        return "<batch of %d>" % len(msg)
    if not isinstance(msg, dict):
        return "<%s>" % type(msg).__name__
    parts = []
    if "method" in msg:
        parts.append("method=%s" % str(msg.get("method"))[:64])
    if "id" in msg:
        parts.append("id=%s" % str(msg.get("id"))[:32])
    params = msg.get("params")
    if isinstance(params, dict):
        if "name" in params:
            parts.append("tool=%s" % str(params.get("name"))[:64])
        args = params.get("arguments")
        if isinstance(args, dict):
            parts.append("args={%s}" % ", ".join(
                "%s:<%d chars>" % (str(k)[:32], len(v) if isinstance(v, str) else len(json.dumps(v, default=str)))
                for k, v in list(args.items())[:24]))
    if isinstance(msg.get("error"), dict):
        parts.append("error=%s" % str(msg["error"].get("code"))[:16])
    elif "result" in msg:
        parts.append("result=<%d bytes>" % len(json.dumps(msg["result"], default=str)))
    return " ".join(parts) or "<%d bytes>" % len(raw)


def serve(server, stdin, stdout, log):
    """Цикл: строка → ответ(ы). Один поток: мост всё равно сериализован общим замком config.lock."""
    while True:
        raw = stdin.readline()
        if not raw:
            log.info("stdin закрыт, завершение")
            return 0
        raw = raw.strip()
        if not raw:
            continue
        log.debug("<- " + debug_rpc_line(raw))
        for response in server.handle_line(raw):
            data = json.dumps(response, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
            log.debug("-> " + debug_rpc_line(data))
            try:
                stdout.write(data + b"\n")
                stdout.flush()
            except (BrokenPipeError, OSError):
                log.info("stdout закрыт клиентом, завершение")
                return 0


def build(environ, script_dir, log_stream):
    settings = Settings(environ, script_dir)
    log = Log(settings.log_level, log_stream)
    catalog = load_catalog(settings.actions_json, settings.lang, log, script_dir)
    bridge = Bridge(settings.action_bin, settings.timeout, settings.lang, log)
    audit = Audit(settings.audit_log, log)
    return settings, log, catalog, bridge, audit


def tools_markdown(catalog):
    """Таблицы инструментов и ресурсов для README (генерируются из actions.json, чтобы не расходиться).

    Первая таблица — инструменты, после пустой строки вторая — ресурсы обоих видов: действие
    (application/json) и файл рядом с сервером (гайд для агента). Скрытые действия (mcp: null)
    сюда не попадают намеренно: README описывает то, что видит агент.
    """
    kinds = {"ro": "чтение", "rw": "изменение", "destructive": "**разрушительное**"}
    rows = ["| Инструмент | Тип | Параметры | Действие моста | Описание |", "|---|---|---|---|---|"]
    for tool in catalog.tools.values():
        kind = kinds["destructive"] if tool.destructive else (kinds["ro"] if tool.readonly else kinds["rw"])
        params = []
        for spec in tool.params:
            item = "`%s`%s" % (spec.name, "*" if spec.required else "")
            if spec.default is not None:
                item += "=%s" % json.dumps(spec.default, ensure_ascii=False)
            params.append(item)
        if tool.destructive and not tool.own_confirm:
            params.append("`confirm`*")
        rows.append("| `%s` | %s | %s | `%s` | %s |" % (
            tool.name, kind, ", ".join(params) or "—", tool.cli, pick(tool.description, "ru").replace("|", "\\|")))
    rows.append("")
    rows.append("| Ресурс | Источник | MIME | Что внутри |")
    rows.append("|---|---|---|---|")
    for res in catalog.resources:
        if res["kind"] == "file":
            source = "файл `%s`" % os.path.basename(res["path"])
        else:
            source = "действие `%s`" % res["tool"].cli
        rows.append("| `%s` | %s | `%s` | %s |" % (res["uri"], source, res["mime"], res["name"].replace("|", "\\|")))
    return "\n".join(rows)


def check(settings, log, catalog):
    """--check: показать, что сервер видит, и вернуть 0/1."""
    ok = True
    out = sys.stderr
    out.write("actions.json : %s\n" % settings.actions_json)
    out.write("action bin   : %s%s\n" % (settings.action_bin,
                                         "" if os.access(settings.action_bin, os.X_OK) else "  (НЕ найден или не исполняемый)"))
    if not os.access(settings.action_bin, os.X_OK):
        ok = False
    out.write("config dir   : %s (версия %s, имя %s)\n" % (settings.dir, settings.version, settings.server_name))
    out.write("audit log    : %s\n" % settings.audit_log)
    out.write("lang/timeout : %s / %.0f с\n" % (settings.lang, settings.timeout))
    ro, rw, destructive = catalog.names_by_kind()
    out.write("tools        : %d (чтение %d, изменение %d, разрушительных %d); скрыто (mcp: null): %d\n"
              % (len(catalog.tools), len(ro), len(rw), len(destructive), len(catalog.hidden)))
    files = catalog.resources_by_kind("file")
    out.write("resources    : %d (действий %d, файлов %d), prompts: %d\n"
              % (len(catalog.resources), len(catalog.resources) - len(files), len(files), len(catalog.prompts)))
    broken = [p.name for t in catalog.tools.values() for p in t.params if p.regex_broken]
    if broken:
        ok = False
        out.write("ПРОБЛЕМА: шаблоны не компилируются: %s\n" % ", ".join(sorted(set(broken))))
    for res in files:
        # Гайд входит в комплект сервера; его отсутствие — ошибка упаковки (bootstrap/копирование),
        # которую лучше поймать в --check и --selftest, чем получить -32002 у агента.
        if not os.path.isfile(res["path"]):
            ok = False
            out.write("ПРОБЛЕМА: нет файла ресурса %s: %s\n" % (res["uri"], res["path"]))
    # HTTP-транспорт (CONTRACT §5.1): включён ли по config.json, где доступы и сколько их.
    grants = GrantStore(settings.agents_json, settings.lock_file, log)
    summary = grants.summary()
    state = "включён" if settings.http_enabled else "выключен"
    where = "127.0.0.1:%d за nginx" % settings.http_port
    if settings.public_port:
        where += ", публичный TLS-порт %d" % settings.public_port
    out.write("http         : %s (%s); agents.json %s%s — доступов %d (действующих %d, с портом %d, "
              "без токена %d, с привязкой к адресу %d, с одноразовым ключом %d, замороженных %d); замок %s\n"
              % (state, where, settings.agents_json, "" if os.path.isfile(settings.agents_json) else " (нет файла)",
                 summary["total"], summary["enabled"], summary["with_port"], summary["weak"], summary["pinned"],
                 summary["rolling"], summary["compromised"], settings.lock_file))
    out.write("состояние цепочек: %s%s\n"
              % (os.path.join(settings.state_dir, "agents"),
                 "" if summary["rolling"] else "  (доступов с одноразовым ключом нет)"))
    if settings.http_enabled and summary["total"] == 0:
        out.write("ЗАМЕТКА: HTTP-транспорт включён, но доступов нет — agent-add выдаст первый\n")
    if summary["weak"]:
        out.write("ЗАМЕТКА: доступов без токена (только секретный путь): %d — усильте их agent-harden\n"
                  % summary["weak"])
    if summary["compromised"]:
        out.write("ТРЕВОГА: замороженных доступов (обнаружен клон ключа): %d — перевыпустите "
                  "(agent-rotate) или отзовите (agent-del)\n" % summary["compromised"])
    out.write("OK\n" if ok else "ЕСТЬ ПРОБЛЕМЫ\n")
    return 0 if ok else 1


USAGE = ("usage: server.py [--check | --tools-md | --version]\n"
         "       server.py --http [--bind ADDR] [--port N] [--tls cert.pem,key.pem]\n"
         "                 [--extra-ports auto|none|P1,P2] [--extra-bind ADDR] [--extra-tls cert.pem,key.pem]\n"
         "Без аргументов — MCP-сервер по stdio (JSON-RPC 2.0, %s).\n"
         "--http — Streamable HTTP: POST /a-<secret>/mcp, доступы из agents.json (CONTRACT §5.1);\n"
         "  слушатель вне петли обязан быть с --tls; --extra-ports auto открывает персональные порты\n"
         "  доступов (поле port в agents.json) на --extra-bind (0.0.0.0) с --extra-tls (или --tls).\n" % PROTOCOL_VERSION)


def parse_cli(argv, settings):
    """→ (mode, HttpOptions|None): mode ∈ help, version, tools-md, check, stdio, http. ValueError — ошибка."""
    mode = "stdio"
    options = HttpOptions(settings)
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("-h", "--help"):
            return "help", None
        if arg in ("--version", "-V"):
            return "version", None
        if arg in ("--check", "--tools-md"):
            mode = arg[2:]
        elif arg == "--http":
            mode = "http"
        elif arg.startswith("--") and "=" in arg:
            flag, value = arg.split("=", 1)
            options.apply(flag, value)
        elif arg in ("--bind", "--port", "--tls", "--extra-tls", "--extra-bind", "--extra-ports"):
            if i + 1 >= len(argv):
                raise ValueError("%s: нет значения" % arg)
            options.apply(arg, argv[i + 1])
            i += 1
        else:
            raise ValueError("неизвестный аргумент %s" % arg)
        i += 1
    return mode, options


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    # realpath, а не abspath: клиент запускает симлинк /usr/local/bin/goamnezia-mcp, и без
    # раскрытия ссылки «каталог сервера» оказался бы /usr/local/bin — гайд и ../lib/actions.json
    # искались бы не там, где лежат.
    script_dir = os.path.dirname(os.path.realpath(__file__))
    if argv and argv[0] in ("-h", "--help"):
        sys.stderr.write(USAGE)
        return 0
    if argv and argv[0] in ("--version", "-V"):
        settings = Settings(os.environ, script_dir)
        sys.stdout.write("%s-mcp %s (MCP %s)\n" % (PRODUCT, settings.version, PROTOCOL_VERSION))
        return 0

    # stdout священен: забираем бинарный поток протокола себе, а sys.stdout направляем в stderr —
    # любой случайный print (свой, библиотечный, отладочный) попадёт в лог, а не в протокол.
    proto_out = sys.stdout.buffer
    proto_in = sys.stdin.buffer
    sys.stdout = sys.stderr

    try:
        settings, log, catalog, bridge, audit = build(os.environ, script_dir, sys.stderr)
    except (OSError, ValueError) as exc:
        sys.stderr.write("%s-mcp: не удалось загрузить каталог действий: %s\n" % (PRODUCT, exc))
        return 2
    try:
        mode, options = parse_cli(argv, settings)
    except ValueError as exc:
        sys.stderr.write("%s-mcp: %s\n%s" % (PRODUCT, exc, USAGE))
        return 2

    if mode == "help":
        sys.stderr.write(USAGE)
        return 0
    if mode == "version":
        proto_out.write(("%s-mcp %s (MCP %s)\n" % (PRODUCT, settings.version, PROTOCOL_VERSION)).encode("utf-8"))
        return 0
    if mode == "tools-md":
        proto_out.write((tools_markdown(catalog) + "\n").encode("utf-8"))
        return 0
    if mode == "check":
        return check(settings, log, catalog)

    if not os.access(settings.action_bin, os.X_OK):
        log.warn("мост %s не найден или не исполняемый — вызовы инструментов будут отвечать ошибкой transport"
                 % settings.action_bin)
    log.info("старт: %s %s, MCP %s, %d инструментов (скрыто %d), %d ресурсов, мост %s, таймаут %.0f с"
             % (settings.server_name, settings.version, PROTOCOL_VERSION, len(catalog.tools), len(catalog.hidden),
                len(catalog.resources), settings.action_bin, settings.timeout))
    if mode == "http":
        return serve_http(settings, catalog, bridge, audit, log, options)
    server = Server(settings, catalog, bridge, audit, log)
    try:
        return serve(server, proto_in, proto_out, log)
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
