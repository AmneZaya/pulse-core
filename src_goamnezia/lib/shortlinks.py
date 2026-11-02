#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""goAmnezia pro — короткие ссылки подписки с 2FA через Telegram-бота (docs/SUBSCRIPTION.md §11).

Решения владельца 04.10.2026. Короткая ссылка — https://<домен>/<КОД>:
  • КОД — 8 знаков из алфавита в 32 знака (0–9, A–Z без I, L, O, U), всегда не меньше двух цифр и двух букв
    (843 227 123 200 вариантов, около 39,6 бита), при показе 1–3 тире в случайных промежутках (NV43-9BKX); при вводе
    тире, пробелы, регистр и обрамление при копировании из мессенджера («КОД.», «(КОД)», ««КОД»», «*КОД*», «КОД…» —
    FRAME) не важны, O читается как 0, I и L — как 1;
  • кодом считается только путь, где после этого ровно 8 знаков алфавита, хотя бы одна цифра набрана цифрой и не
    меньше двух букв (O, I и L, ставшие цифрами, — не буквы): слова сайта (/download, /wp-admin, /phpmyadmin), даты
    и номера (/2024-10-01, /12345678) — не код, а обычный 404 — без баллов, тревоги и строки в журнале;
  • код — на пару «подписка + суффикс» (all.yaml, all.txt, all.vpn, awgNN.vpn, awgNN.conf), создаётся при первом
    показе и живёт, пока его не заменят; перевыпуск и отзыв подписки, удаление человека гасят все её коды;
  • работают ТОЛЬКО с 2FA через Telegram-бота: бот не настроен (нет токена или ни одного администратора) — кода не
    выдают, а /<КОД> отвечает 404.

Вход — как у Google. С адреса, которому код ещё не доверен: браузеру — страница подтверждения с числом 10–99,
приложению — 404. Всем администраторам в бот — «Вход по короткой ссылке» и 10 чисел (верное и 9 случайных), «Это
не я», «↻ Заменить ссылку». Верное число открывает адрес (IPv4 целиком, у IPv6 — подсеть /64) для этого кода на
15 минут; первый успешный забор делает его доверенным на 30 дней, окно сдвигается с каждым забором. После
подтверждения страница выдаёт этому устройству полную ссылку подписки (SHORT-03, confirmed: только по номеру
подтверждённого запроса и 15 минут после решения): приложение с полной ссылкой обновляется из любой сети без
подтверждений, короткая — по-прежнему из подтверждённой. «Показать содержимое» — тот же адрес с меткой ?go=<запрос>:
открытый адрес получает подписку, не открытому (адрес сети сменился, время вышло) метка нового запроса не создаёт —
«Нужна новая проверка» (visit, after). Неверное число три раза подряд — код заморожен на сутки, следующие три — на
месяц. «Это не я» — адрес закрыт для коротких ссылок по лестнице банов. «↻ Заменить ссылку» и
подтверждённая замена — новый код, старый — в кладбище на 30 дней.

Баны за подбор. Балл — новый неверный код с адреса (похож на код — см. as_code, — но такого кода нет и он не в
кладбище); повтор того же кода, стук по кладбищу, слова сайта, даты и номера балла не дают. Три балла подряд без
верного кода между ними — бан адреса на сутки, следующие три — на месяц, дальше снова на месяц. Бан закрывает
только короткие ссылки; код, который с этого адреса уже успешно забирали («свой клиент»), работает и во время бана. Неверных кодов со всех адресов больше 100 за час — тревога в бот.

Хранение:
  subs/<имя>/short.json    0600  суффикс → {code, display, created, generation} (generation — поколение подписки:
                                 перевыпуск поднимает его, и код прежнего поколения мёртв, даже если его не погасили)
  subs/.short/state.json   0600  кладбище, баны и баллы, заморозки, доверенные адреса, запросы, счёт промахов;
                                 запись — под замком subs/.short/.lock (flock), всё переживает перезапуск службы.
События — файлами в формате ga_notify (lib/common.sh): short_confirm и short_decided — в отдельную очередь
${GOAMNEZIA_LOCK_DIR:-/run/goamnezia}/short-confirm/ (бот смотрит её раз в секунду), short_alarm — в обычную
очередь notify. Верного числа нет ни в событиях, ни в short-pending: бот передаёт нажатое число в short-decide.

Кода, числа и адресов нет ни в журнале, ни в аудите: в аудите — имя, суффикс, итог и уровень бана.

Модуль — один на двоих: его импортирует служба страниц (lib/pages_server.py: маршрут /<КОД>, кнопки страницы
подключения), а мост зовёт его командой (lib/subs.sh → python3 lib/shortlinks.py <команда> …). Только stdlib,
Python ≥ 3.8.
"""

import os
import re
import sys
import json
import math
import time
import errno
import fcntl
import random
import shutil
import hashlib
import secrets
import ipaddress
import threading
import contextlib
import subprocess

# ── Код ──────────────────────────────────────────────────────────────────────
ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"     # 32 знака: без I, L, O, U
CODE_LEN = 8
CODE_RE = re.compile(r"^[0-9ABCDEFGHJKMNPQRSTVWXYZ]{8}$")
# В выданном коде не меньше двух цифр и не меньше двух букв: так он не похож на слово сайта, а слово — на код
MIN_DIGITS = 2
MIN_LETTERS = 2
READ_MAP = str.maketrans({"O": "0", "I": "1", "L": "1"})
DIGITS = "0123456789"
# Обрамление, которое приносит копирование из мессенджера и разметка: «КОД.», «КОД,», «(КОД)», «[КОД]», ««КОД»»,
# «“КОД”», «*КОД*», «_КОД_», «`КОД`», «<КОД>», «:КОД», «.КОД», «КОД%20», «КОД%09», «• КОД» — таб, пробел, неразрывный
# пробел и ! " ' ( ) , . : ; < > ? [ ] _ ` { } ~ * + « » – — ‘ ’ “ ” „ • …. Его снимает normalize с обоих краёв (в
# середине кода это уже не код); nginx ловит те же знаки побайтно — до 3 в начале и до 6 в конце
# (GA_SITE_SHORT_FRAME в lib/website.sh), служба — SHORT_PATH_RE.
FRAME = "\t !\"'(),.:;<>?[]_`{}~*+\u00a0\u00ab\u00bb\u2013\u2014\u2018\u2019\u201c\u201d\u201e\u2022\u2026"
# Суффиксы, у которых бывает короткая ссылка, — канонические имена подписки (синонимов mihomo.yaml и awgv* нет)
SUFFIXES = ("all.yaml", "all.txt", "all.vpn", "awg31.conf", "awg20.conf", "awg15.conf", "awg10.conf",
            "awg31.vpn", "awg20.vpn", "awg15.vpn", "awg10.vpn")
SUFFIX_LINE = {"awg31": "3.1", "awg20": "2.0", "awg15": "1.5", "awg10": "1.0"}
NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
REQUEST_RE = re.compile(r"^[A-Za-z0-9_-]{1,48}$")       # выдаём 16 знаков, принимаем форму договора
# Кто просит замену или решает: page, panel, ssh, bot — и с уточнением после двоеточия (bot:<id> от бота)
WHO_RE = re.compile(r"^(page|panel|ssh|bot)(:[0-9A-Za-z_.@-]{1,64})?$")
ADMIN_WHO = ("panel", "ssh", "bot")         # кто из них администратор: чужой ожидающий вход ему не помеха (SL-UX-03)
SECRET_RE = re.compile(r"^[A-Za-z0-9_-]{43}$")

# ── Сроки и пороги (SPEC) ────────────────────────────────────────────────────
DAY = 86400
MONTH = 30 * DAY
REQUEST_TTL = 300               # запрос ждёт решения 5 минут
OPEN_TTL = 900                  # подтверждённый адрес открыт для первого забора 15 минут
# Полная ссылка странице подтверждения (SHORT-03) — столько же после «Вход подтверждён»: человек берёт её сразу, за
# минуты, а забытая открытой вкладка (общий компьютер, телевизор) секрет больше не отдаст; решённый запрос служба помнит
# час (DECIDED_KEEP), так что проверка по номеру надёжна всё окно. Как и OPEN_TTL, считается от подтверждения.
FULL_TTL = 900
TRUST_TTL = 30 * DAY            # доверенный адрес — 30 дней, окно сдвигается с каждым забором
GRAVE_TTL = 30 * DAY            # кладбище заменённых и погашенных кодов
STRIKES = 3                     # неверных кодов до бана адреса, неверных чисел до заморозки кода
HOURLY_REQUESTS = 5             # новых запросов на код в час
ALARM_MISSES = 100              # тревога: неверных кодов со всех адресов за час больше этого
DECIDED_KEEP = 3600             # решённый запрос помнится час: опрос статуса и «уже решено»
LEVEL_KEEP = 365 * DAY          # запись адреса с банами помнится год после конца последнего бана (лестница)
ADDR_IDLE_KEEP = 30 * DAY       # запись адреса без банов (баллы, повторы) — 30 дней с последнего промаха
TRUST_SLIDE_STEP = 3600         # сдвиг окна доверия пишется на диск не чаще раза в час на адрес
LOCK_WAIT = 15.0                # секунд ждать замок состояния
# Потолки таблиц: перебор с сотен тысяч адресов не раздует state.json без предела
ADDR_MAX = 20000
ACCESS_MAX = 20000
ACCESS_PER_CODE = 32
GRAVE_MAX = 20000
REQUEST_MAX = 2000
SEEN_MAX = 8
QUEUE_MAX = 200                 # файлов в очереди событий, как GOAMNEZIA_NOTIFY_MAX у ga_notify

_RNG = random.SystemRandom()
_SEQ_LOCK = threading.Lock()
_SEQ = [0]


class ShortError(Exception):
    """Отказ с кодом для моста и страницы: short_need_bot, sub_not_found, short_not_found, short_pending…"""

    def __init__(self, code, rc=1, **extra):
        Exception.__init__(self, code)
        self.code = code
        self.rc = rc
        self.extra = extra


class ShortBusy(ShortError):
    """Замок состояния не взят за LOCK_WAIT: служба отвечает 503, мост — short_busy."""

    def __init__(self):
        ShortError.__init__(self, "short_busy", 1)


# ── Код: генерация, показ, ввод ──────────────────────────────────────────────
def code_space():
    """Сколько всего кодов может выдать new_code: 8 знаков из 10 цифр и 22 букв, цифр и букв — не меньше двух
    (843 227 123 200 из 32⁸; оценка риска в docs/SUBSCRIPTION.md §11.5 — от этого числа)."""
    digits, letters = 10, len(ALPHABET) - 10
    return sum(math.comb(CODE_LEN, d) * digits ** d * letters ** (CODE_LEN - d)
               for d in range(MIN_DIGITS, CODE_LEN - MIN_LETTERS + 1))


def new_code():
    """8 знаков алфавита, не меньше двух цифр и двух букв: secrets.randbelow(32) — криптостойко и без смещения по
    модулю (32 — степень двойки, а randbelow остатка от деления вообще не берёт); код не по правилу отбрасывается и
    тянется заново — так каждый допустимый код равновероятен (отбор, а не подгонка знаков)."""
    while True:
        code = "".join(ALPHABET[secrets.randbelow(len(ALPHABET))] for _ in range(CODE_LEN))
        digits = sum(1 for ch in code if ch.isdigit())
        if digits >= MIN_DIGITS and CODE_LEN - digits >= MIN_LETTERS:
            return code


def display_of(code):
    """Код для показа: 1–3 тире в случайных промежутках между знаками (NV43-9BKX, 7Q-K2T-M9P…)."""
    gaps = set(_RNG.sample(range(1, CODE_LEN), 1 + secrets.randbelow(3)))
    return "".join(("-" if i in gaps else "") + ch for i, ch in enumerate(code))


def _body(text):
    """Ввод без пробелов и обрамления копирования по краям (FRAME)."""
    return str(text or "").strip().strip(FRAME)


def normalize(text):
    """Ввод человека → код или "": тире, пробелы, регистр и обрамление копирования (FRAME: «КОД.», «(КОД)»,
    «*КОД*», «КОД…») не важны, O → 0, I и L → 1. Чего нет в алфавите (U, точка внутри, другая длина) — не код вовсе.
    Для пути адреса — as_code: там ещё нужны цифра, набранная цифрой, и две буквы."""
    raw = _body(text).replace("-", "").replace(" ", "").upper().translate(READ_MAP)
    return raw if CODE_RE.match(raw) else ""


def as_code(text):
    """Путь /<…> → код или "". Код — только когда после нормализации ровно 8 знаков алфавита, хотя бы одна цифра
    набрана цифрой (O → 0 и I, L → 1 тут не в счёт) и букв не меньше двух (O, I и L, ставшие цифрами, — уже не буквы).
    Путь из одних букв — слово сайта (/download → D0WN10AD, /contacts → C0NTACTS), почти из одних цифр — дата или
    номер (/2024-10-01, /12345678), а не опечатка в коде: у выданного кода всегда не меньше двух цифр и двух букв, и
    честный ввод (строчными, с пробелами, O, I, L вместо 0 и 1) их не теряет. Такой путь — обычный 404 без балла и
    без тревоги, сканеры ничего не набирают. Обрамление копирования (FRAME) снято до подсчёта: ни цифр, ни букв оно
    не добавляет."""
    code = normalize(text)
    if not code or not any(ch in DIGITS for ch in _body(text)):
        return ""
    return code if sum(1 for ch in code if ch not in DIGITS) >= MIN_LETTERS else ""


def code_hash(code):
    """Короткий отпечаток неверного кода — чтобы помнить «этот уже считали», не храня сами коды."""
    return hashlib.sha256(code.encode("ascii", "replace")).hexdigest()[:12]


# ── Адрес ────────────────────────────────────────────────────────────────────
def addr_key(ip):
    """Адрес для банов и доверия: IPv4 целиком, у IPv6 — подсеть /64 (у телефона в одной сети адрес меняется в
    пределах /64, а у атакующего их миллиарды). Не адрес — ""."""
    try:
        addr = ipaddress.ip_address(str(ip or "").strip())
    except ValueError:
        return ""
    if addr.version == 6 and addr.ipv4_mapped is not None:
        addr = addr.ipv4_mapped
    if addr.version == 4:
        return str(addr)
    return str(ipaddress.ip_network("%s/64" % addr, strict=False))


def target_key(text):
    """Цель short-unban: адрес (IPv4, IPv6 или его подсеть /64) → ("ip", ключ); код в любом виде → ("code", код)."""
    value = str(text or "").strip()
    if "/" in value:
        try:
            net = ipaddress.ip_network(value, strict=False)
        except ValueError:
            net = None
        if net is not None:
            return "ip", addr_key(str(net.network_address))
    key = addr_key(value)
    if key:
        return "ip", key
    code = normalize(value)
    if code:
        return "code", code
    return "", ""


# ── Устройство и место для сообщения администратору ─────────────────────────
_APPS = (("Clash Verge", re.compile(r"clash[-_ ]?verge", re.I)), ("FlClash", re.compile(r"flclash", re.I)),
         ("Mihomo Party", re.compile(r"mihomo[-_. ]?party", re.I)),
         ("Clash Meta", re.compile(r"clash[-_. ]?meta|clashmetaforandroid", re.I)),
         ("mihomo", re.compile(r"mihomo", re.I)), ("Clash", re.compile(r"clash", re.I)),
         ("incy", re.compile(r"\bincy\b", re.I)), ("v2RayTun", re.compile(r"v2raytun", re.I)),
         ("WG Tunnel", re.compile(r"wg[-_ ]?tunnel", re.I)), ("Keenetic", re.compile(r"keenetic", re.I)),
         ("Amnezia", re.compile(r"amnezia", re.I)), ("curl", re.compile(r"^curl/", re.I)),
         ("Wget", re.compile(r"^wget", re.I)))
_OSES = (("iPhone", re.compile(r"iPhone")), ("iPad", re.compile(r"iPad")),
         ("Apple TV", re.compile(r"AppleTV|tvOS", re.I)),
         ("Android TV", re.compile(r"Android.*(\bTV\b|AFT[A-Z]|BRAVIA|SMART-?TV|GoogleTV)", re.I)),
         ("Smart TV", re.compile(r"Tizen|Web0S|webOS|SMART-?TV|HbbTV|NetCast", re.I)),
         ("Android", re.compile(r"Android", re.I)), ("Windows", re.compile(r"Windows", re.I)),
         ("ChromeOS", re.compile(r"CrOS")), ("macOS", re.compile(r"Macintosh|Mac OS X")),
         ("Linux", re.compile(r"Linux", re.I)))
_BROWSERS = (("Edge", re.compile(r"Edg(A|iOS)?/")), ("Opera", re.compile(r"OPR/|Opera")),
             ("Yandex", re.compile(r"YaBrowser")), ("Samsung Internet", re.compile(r"SamsungBrowser")),
             ("Firefox", re.compile(r"Firefox/|FxiOS/")), ("Chrome", re.compile(r"Chrome/|CriOS/")),
             ("Safari", re.compile(r"Version/[0-9.]+.*Safari/")))


def describe_device(user_agent):
    """Устройство по User-Agent для сообщения в бот: «iPhone · Safari», «Android TV · Chrome», «curl», «FlClash».
    Не узнали — ""; сам User-Agent не хранится (в нём бывает модель телефона)."""
    agent = str(user_agent or "")[:512]
    if not agent.strip():
        return ""
    for name, rx in _APPS:
        if rx.search(agent):
            return name
    os_name = next((name for name, rx in _OSES if rx.search(agent)), "")
    browser = next((name for name, rx in _BROWSERS if rx.search(agent)), "")
    return " · ".join(part for part in (os_name, browser) if part)


_GEO_DBS = ("/usr/share/GeoIP/GeoLite2-City.mmdb", "/var/lib/GeoIP/GeoLite2-City.mmdb",
            "/usr/share/GeoIP/dbip-city-lite.mmdb", "/usr/share/GeoIP/GeoLite2-Country.mmdb",
            "/var/lib/GeoIP/GeoLite2-Country.mmdb", "/usr/share/GeoIP/dbip-country-lite.mmdb")
_GEO_CACHE = {}
_GEO_LOCK = threading.Lock()


def _geo_run(cmd, timeout):
    try:
        proc = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return proc.stdout.decode("utf-8", "replace") if proc.returncode == 0 else ""


def parse_mmdb(text):
    """Строка ответа mmdblookup («"Moscow" <utf8_string>») → значение или ""."""
    match = re.search(r'"([^"\n]{1,64})"\s*<utf8_string>', text or "")
    return match.group(1) if match else ""


def parse_geoiplookup(text):
    """Ответ geoiplookup («GeoIP Country Edition: RU, Russian Federation») → страна или ""."""
    for line in (text or "").splitlines():
        match = re.match(r"^GeoIP Country (?:V6 )?Edition:\s*[A-Z0-9]{2},\s*(.{1,64})$", line.strip())
        if match:
            return match.group(1).strip()
    return ""


def geo_lookup(ip, timeout=1.0):
    """Город и страна по IP — только если на сервере есть GeoIP (mmdblookup с базой GeoLite2/DB-IP или geoiplookup);
    своей базы продукт не возит. Нет — "". Ответы помнятся (256 адресов), внутренние адреса не ищутся."""
    try:
        addr = ipaddress.ip_address(str(ip or "").strip())
    except ValueError:
        return ""
    if not addr.is_global:
        return ""
    key = str(addr)
    with _GEO_LOCK:
        if key in _GEO_CACHE:
            return _GEO_CACHE[key]
    found = ""
    mmdb = shutil.which("mmdblookup")
    if mmdb:
        for db in _GEO_DBS:
            if not os.path.isfile(db):
                continue
            country = parse_mmdb(_geo_run([mmdb, "--file", db, "--ip", key, "country", "names", "en"], timeout))
            city = parse_mmdb(_geo_run([mmdb, "--file", db, "--ip", key, "city", "names", "en"], timeout)) \
                if "ity" in os.path.basename(db) else ""
            found = ", ".join(part for part in (city, country) if part)
            if found:
                break
    if not found:
        tool = shutil.which("geoiplookup6" if addr.version == 6 else "geoiplookup")
        if tool:
            found = parse_geoiplookup(_geo_run([tool, key], timeout))
    found = "".join(ch for ch in found if ch.isprintable())[:80]
    with _GEO_LOCK:
        if len(_GEO_CACHE) >= 256:
            _GEO_CACHE.clear()
        _GEO_CACHE[key] = found
    return found


# ── Мелочи ───────────────────────────────────────────────────────────────────
def iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(epoch)))


def as_int(value, default=0):
    if isinstance(value, bool):
        return default
    try:
        return int(value)
    except (TypeError, ValueError, OverflowError):
        return default


def read_json(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def write_json_atomic(path, data, mode=0o600):
    """Временный файл рядом и os.replace: читатель не увидит полупустой JSON. Имя временного — с процессом и
    потоком: служба многопоточная, а мост пишет из своего процесса."""
    tmp = "%s.%d.%d.tmp" % (path, os.getpid(), threading.get_ident())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, separators=(",", ":"))
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    os.replace(tmp, path)


def read_env(path):
    """.env бота так же, как его читают бот, systemd и SSH (_bot_env_get, SEC50-03): «export » в начале, пробелы
    вокруг имени, кавычки, « # комментарий» после значения без кавычек; повтор — побеждает последняя строка."""
    values = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return values
    for line in lines:
        line = line.lstrip()
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        if "=" not in line:
            continue
        key, val = line.split("=", 1)
        key = key.rstrip()
        val = val.strip()
        quote = val[:1]
        if quote in ('"', "'") and quote in val[1:]:
            val = val[1:val.index(quote, 1)]
        else:
            if quote in ('"', "'"):
                val = val[1:]
            val = re.sub(r"\s+#.*$", "", val)
        values[key] = val
    return values


def _next_seq():
    with _SEQ_LOCK:
        _SEQ[0] += 1
        return _SEQ[0]


def emit_event(directory, event, fields, now=None):
    """Событие файлом, как ga_notify (lib/common.sh): одна строка JSON {ts, event, …}, имя
    <время>_<процесс>_<номер>.json — лексический порядок и есть хронологический; файл появляется атомарно
    (временный .tmp.* и переименование), каталог 0700, файл 0600; очередь — не больше QUEUE_MAX файлов (старые
    выбрасываются: читателя может не быть). → True, если записан."""
    stamp = iso(now if now is not None else time.time())
    record = {"ts": stamp, "event": event}
    record.update(fields)
    line = json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n"
    try:
        os.makedirs(directory, mode=0o700, exist_ok=True)
        os.chmod(directory, 0o700)
    except OSError:
        return False
    tmp = os.path.join(directory, ".tmp.%d.%d.%s" % (os.getpid(), threading.get_ident(), secrets.token_hex(4)))
    name = "%s_%d_%04d.json" % (stamp.replace(":", "").replace("-", ""), os.getpid(), _next_seq())
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(line)
        os.replace(tmp, os.path.join(directory, name))
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False
    try:
        files = sorted(f for f in os.listdir(directory) if f.endswith(".json") and not f.startswith("."))
        for old in files[:max(0, len(files) - QUEUE_MAX)]:
            os.unlink(os.path.join(directory, old))
    except OSError:
        pass
    return True


def _empty_state():
    return {"schema": 1, "rev": 0, "graveyard": {}, "addrs": {}, "codes": {}, "access": {}, "requests": {},
            "misses": {}, "alarm_at": 0}


def _clean_state(state):
    if not isinstance(state, dict):
        state = {}
    out = _empty_state()
    for key in ("graveyard", "addrs", "codes", "access", "requests", "misses"):
        value = state.get(key)
        out[key] = {k: v for k, v in value.items() if isinstance(v, (dict, int))} if isinstance(value, dict) else {}
    for key in ("rev", "alarm_at"):
        out[key] = as_int(state.get(key))
    return out


class _Tx(object):
    """Одна правка состояния под замком: что записать и какие события и строки аудита выпустить после записи."""

    def __init__(self, state):
        self.st = state
        self.dirty = False
        self.confirm = []     # (событие, поля) → очередь short-confirm
        self.notify = []      # (событие, поля) → очередь ga_notify
        self.audit = []       # (действие, подробности)


class ShortLinks(object):
    """Короткие ссылки одной установки: коды в subs/<имя>/short.json, состояние в subs/.short/state.json.

    Все правки — под замком: flock на subs/.short/.lock между процессами (служба и мост) и threading.Lock внутри
    процесса. Разобранное состояние держится в памяти и перечитывается, только когда файл на диске сменился (запись
    моста): служба на каждый запрос /<КОД> не разбирает state.json заново."""

    def __init__(self, gdir=None, subs_dir=None, bot_dir=None, lock_dir=None, confirm_dir=None, notify_dir=None,
                 audit=None, log=None, now=time.time, geo=None):
        env = os.environ.get
        self.gdir = gdir or env("GOAMNEZIA_DIR") or "/opt/goamnezia"
        self.subs_dir = subs_dir or env("GOAMNEZIA_SUBS_DIR") or os.path.join(self.gdir, "subs")
        self.state_dir = os.path.join(self.subs_dir, ".short")
        self.state_path = os.path.join(self.state_dir, "state.json")
        self.lock_path = os.path.join(self.state_dir, ".lock")
        self.bot_dir = bot_dir or env("GOAMNEZIA_BOT_DIR") or env("BOT_DIR") or "/opt/goamnezia-bot"
        run_dir = lock_dir or env("GOAMNEZIA_LOCK_DIR") or "/run/goamnezia"
        self.confirm_dir = confirm_dir or env("GOAMNEZIA_SHORT_CONFIRM_DIR") or os.path.join(run_dir, "short-confirm")
        self.notify_dir = notify_dir or env("GOAMNEZIA_NOTIFY_DIR") or os.path.join(run_dir, "notify")
        self.audit_fn = audit
        self.log = log
        self.now = now
        self.geo = geo or (lambda ip: "")
        self._tlock = threading.RLock()
        self._cache = None          # (отпечаток файла, разобранное состояние)
        self._index = None          # (rev, mtime каталога подписок, {код: (имя, суффикс)})
        self._env = None            # (отпечаток .env бота, доступны ли короткие ссылки)
        self._tidied = 0.0

    # ── бот настроен? ────────────────────────────────────────────────────────
    def available(self):
        """Короткие ссылки есть, только когда бот настроен: в .env есть токен и хотя бы один администратор (то же
        правило, что _bot_has_admins в SSH-меню). Перечитывается по отпечатку файла."""
        path = os.path.join(self.bot_dir, ".env")
        try:
            st = os.stat(path)
            stamp = (st.st_mtime_ns, st.st_size, st.st_ino)
        except OSError:
            return False
        with self._tlock:
            if self._env is not None and self._env[0] == stamp:
                return self._env[1]
            values = read_env(path)
            ok = bool(values.get("BOT_TOKEN", "").strip()) and bool(re.sub(r"[\s,]", "", values.get("ALLOWED_IDS", "")))
            self._env = (stamp, ok)
            return ok

    # ── замок и состояние ────────────────────────────────────────────────────
    def _ensure_dir(self):
        os.makedirs(self.state_dir, mode=0o700, exist_ok=True)
        try:
            os.chmod(self.state_dir, 0o700)
        except OSError:
            pass

    def _load(self):
        try:
            st = os.stat(self.state_path)
        except OSError:
            self._cache = None
            return _empty_state()
        stamp = (st.st_mtime_ns, st.st_size, st.st_ino)
        if self._cache is not None and self._cache[0] == stamp:
            return self._cache[1]
        try:
            state = _clean_state(read_json(self.state_path))
        except (OSError, ValueError) as exc:
            if self.log:
                self.log.warn("короткие ссылки: state.json не прочитан (%s) — начинаю с пустого" % exc)
            state = _empty_state()
        self._cache = (stamp, state)
        return state

    def _save(self, state):
        self._ensure_dir()
        write_json_atomic(self.state_path, state)
        try:
            st = os.stat(self.state_path)
            self._cache = (st.st_mtime_ns, st.st_size, st.st_ino), state
        except OSError:
            self._cache = None

    @contextlib.contextmanager
    def _tx(self, write=True):
        """Правка состояния. write=False — только чтение: ни каталога, ни замка-файла не заводит, если их ещё нет."""
        with self._tlock:
            if not write and not os.path.isfile(self.state_path):
                yield _Tx(_empty_state())
                return
            self._ensure_dir()
            fd = os.open(self.lock_path, os.O_RDWR | os.O_CREAT, 0o600)
            try:
                deadline = time.monotonic() + LOCK_WAIT
                while True:
                    try:
                        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except OSError as exc:
                        if exc.errno not in (errno.EAGAIN, errno.EACCES, errno.EWOULDBLOCK):
                            raise
                        if time.monotonic() >= deadline:
                            raise ShortBusy()
                        time.sleep(0.02)
                tx = _Tx(self._load())
                try:
                    yield tx
                except BaseException:
                    self._cache = None          # недописанная правка: следующий раз — заново с диска
                    raise
                if tx.dirty:
                    self._save(tx.st)
                for event, fields in tx.confirm:
                    emit_event(self.confirm_dir, event, fields, self.now())
                for event, fields in tx.notify:
                    emit_event(self.notify_dir, event, fields, self.now())
                for action, details in tx.audit:
                    self._audit(action, details)
            finally:
                try:
                    fcntl.flock(fd, fcntl.LOCK_UN)
                finally:
                    os.close(fd)

    def _audit(self, action, details):
        if self.audit_fn is None:
            return
        try:
            self.audit_fn(action, details)
        except Exception:                                   # noqa: BLE001 — аудит не роняет вход
            pass

    # ── коды подписок ────────────────────────────────────────────────────────
    def _sub_dir(self, name):
        return os.path.join(self.subs_dir, name)

    def _sub_generation(self, name):
        """Поколение подписки из meta.json или None — подписки нет (нет meta.json или секрета, чужой каталог)."""
        if not NAME_RE.match(str(name or "")):
            return None
        sdir = self._sub_dir(name)
        try:
            meta = read_json(os.path.join(sdir, "meta.json"))
            with open(os.path.join(sdir, "secret"), "r", encoding="utf-8") as fh:
                secret = fh.read().strip()
        except (OSError, ValueError):
            return None
        if not isinstance(meta, dict) or not SECRET_RE.match(secret) or str(meta.get("user") or name) != name:
            return None
        return max(1, as_int(meta.get("generation"), 1))

    def _read_codes(self, name):
        """short.json подписки: {суффикс: {code, display, created, generation}} — только записи правильного вида."""
        try:
            data = read_json(os.path.join(self._sub_dir(name), "short.json"))
        except (OSError, ValueError):
            return {}
        out = {}
        if isinstance(data, dict):
            for suffix, ent in data.items():
                if suffix in SUFFIXES and isinstance(ent, dict) and CODE_RE.match(str(ent.get("code") or "")):
                    out[suffix] = ent
        return out

    def _write_codes(self, name, codes):
        path = os.path.join(self._sub_dir(name), "short.json")
        write_json_atomic(path, codes)

    def _live_codes(self, name, generation=None):
        """Действующие коды подписки: запись своего поколения. → {суффикс: запись}."""
        gen = self._sub_generation(name) if generation is None else generation
        if gen is None:
            return {}
        return {s: e for s, e in self._read_codes(name).items() if max(1, as_int(e.get("generation"), 1)) == gen}

    def _subs_stamp(self):
        try:
            return os.stat(self.subs_dir).st_mtime_ns
        except OSError:
            return None

    def _index_of(self, state):
        """Код → (имя, суффикс) по всем short.json. Пересобирается, когда коды менялись (rev в состоянии) или
        каталог подписок (создание и снятие подписки)."""
        stamp = self._subs_stamp()
        rev = as_int(state.get("rev"))
        if self._index is not None and self._index[0] == rev and self._index[1] == stamp:
            return self._index[2]
        index = {}
        try:
            names = sorted(os.listdir(self.subs_dir))
        except OSError:
            names = []
        for name in names:
            if not NAME_RE.match(name):
                continue
            for suffix, ent in self._read_codes(name).items():
                index[str(ent["code"])] = (name, suffix)
        self._index = (rev, stamp, index)
        return index

    def _resolve(self, state, code):
        """Живой код → (имя, суффикс, запись) или None. Индекс — подсказка, правду говорит свежий short.json и
        поколение подписки: перевыпуск гасит коды даже без явного погашения."""
        hit = self._index_of(state).get(code)
        if hit is None:
            return None
        name, suffix = hit
        ent = self._live_codes(name).get(suffix)
        if not ent or ent.get("code") != code:
            return None
        return name, suffix, ent

    def _url(self, display):
        domain = self._domain()
        return "https://%s/%s" % (domain, display) if domain and display else ""

    def _domain(self):
        try:
            cfg = read_json(os.path.join(self.gdir, "config.json"))
        except (OSError, ValueError):
            return ""
        return str(cfg.get("domain") or "").strip().lower() if isinstance(cfg, dict) else ""

    def _label(self, name):
        try:
            data = read_json(os.path.join(self.gdir, "users.json"))
        except (OSError, ValueError):
            return name
        for user in (data.get("users") if isinstance(data, dict) else None) or []:
            if isinstance(user, dict) and user.get("name") == name:
                return str(user.get("label") or name)
        return name

    def _out(self, suffix, ent):
        display = str(ent.get("display") or ent.get("code") or "")
        return {"suffix": suffix, "code": str(ent.get("code") or ""), "display": display, "url": self._url(display),
                "created": str(ent.get("created") or "")}

    def _taken(self, state, code, now):
        if code in self._index_of(state):
            return True
        grave = state["graveyard"].get(code)
        return isinstance(grave, dict) and as_int(grave.get("until")) > now

    def _fresh_code(self, state, now):
        for _ in range(64):
            code = new_code()
            if not self._taken(state, code, now):
                return code
        raise ShortError("write_failed")

    def _bury(self, tx, code, name, suffix, why, now):
        """Код — в кладбище на 30 дней: такой путь отвечает 404 и не считается попыткой подбора. Доверие адресов,
        счётчики кода и ожидающий запрос по нему уходят вместе с ним."""
        st = tx.st
        st["graveyard"][code] = {"until": int(now + GRAVE_TTL), "name": name, "suffix": suffix, "why": why}
        st["codes"].pop(code, None)
        for key in [k for k, a in st["access"].items() if isinstance(a, dict) and a.get("c") == code]:
            del st["access"][key]
        for rid, req in list(st["requests"].items()):
            if isinstance(req, dict) and req.get("code") == code and req.get("status") == "pending":
                self._finish(tx, rid, req, "expired", "", now)
        if len(st["graveyard"]) > GRAVE_MAX:
            for old in sorted(st["graveyard"], key=lambda c: as_int(st["graveyard"][c].get("until")))[
                    :len(st["graveyard"]) - GRAVE_MAX]:
                del st["graveyard"][old]
        st["rev"] = as_int(st.get("rev")) + 1
        tx.dirty = True

    def _new_entry(self, tx, name, suffix, generation, now):
        code = self._fresh_code(tx.st, now)
        return {"code": code, "display": display_of(code), "created": iso(now), "generation": generation}

    # ── публичное: коды ──────────────────────────────────────────────────────
    def ensure(self, name, suffix, who="", now=None):
        """Код пары «подписка + суффикс»; нет — создать. → {suffix, code, display, url, created, new}."""
        now = self.now() if now is None else now
        if suffix not in SUFFIXES:
            raise ShortError("bad_suffix", 2)
        if not self.available():
            raise ShortError("short_need_bot", 2)
        gen = self._sub_generation(name)
        if gen is None:
            raise ShortError("sub_not_found", 3)
        with self._tx() as tx:
            codes = self._read_codes(name)
            ent = codes.get(suffix)
            if ent and max(1, as_int(ent.get("generation"), 1)) == gen:
                out = self._out(suffix, ent)
                out["new"] = False
                return out
            if ent:
                # Код прежнего поколения подписки (перевыпуск без погашения) — в кладбище, взамен новый
                self._bury(tx, str(ent["code"]), name, suffix, "rotate", now)
            ent = self._new_entry(tx, name, suffix, gen, now)
            codes[suffix] = ent
            self._write_codes(name, codes)
            tx.st["rev"] = as_int(tx.st.get("rev")) + 1
            tx.dirty = True
            tx.audit.append(("short-ensure", "user=%s suffix=%s who=%s" % (name, suffix, who or "-")))
            out = self._out(suffix, ent)
            out["new"] = True
            return out

    def codes_of(self, name):
        """Уже созданные коды подписки: {суффикс: {suffix, code, display, url, created}} (без создания новых)."""
        return {s: self._out(s, e) for s, e in self._live_codes(name).items()}

    def kill(self, name, reason="revoked", now=None):
        """Погасить все коды подписки (перевыпуск, отзыв, удаление человека): в кладбище на 30 дней, ожидающие
        запросы по ним — истёкшими. При перевыпуске short.json пустеет; при отзыве каталог снимает вызывающий.
        → число погашенных."""
        now = self.now() if now is None else now
        if not NAME_RE.match(str(name or "")):
            return 0
        codes = self._read_codes(name)
        if not codes:
            return 0
        with self._tx() as tx:
            codes = self._read_codes(name)
            for suffix, ent in codes.items():
                self._bury(tx, str(ent["code"]), name, suffix, reason, now)
            try:
                self._write_codes(name, {})
            except OSError:
                pass
            if codes:
                tx.audit.append(("short-kill", "user=%s codes=%d reason=%s" % (name, len(codes), reason)))
            return len(codes)

    # ── публичное: вход по ссылке ────────────────────────────────────────────
    def visit(self, raw, ip, browser=False, rid="", head=False, device="", now=None, after=""):
        """Запрос /<КОД> к службе. → словарь с полем do:
          404     — ответить 404 как nginx (слово сайта, неверный или погашенный код, бан, приложение без доверия);
          status  — опрос страницы подтверждения (?r=<запрос>): {"decision": …};
          serve   — отдать подписку (name, suffix, code): адрес доверен этому коду или открыт после подтверждения;
          page    — браузеру страница подтверждения: state wait (число, request, left) | busy (ждём другой вход) |
                    limit (5 запросов в час) | frozen (код заморожен, days, left) | moved (см. after).
        after — номер запроса из метки ?go=<запрос>: так ведёт ссылка «Показать содержимое» страницы подтверждения после
        «Вход подтверждён» (SHORT-02, SHORT-03). Открытый и доверенный адрес получает подписку, как без метки; иначе
        (адрес сети сменился — IPv4 ↔ IPv6, другая сеть, — или время вышло) нового запроса в бот метка не создаёт:
        браузеру — moved, «Нужна новая проверка», а новый запрос — кнопкой, адресом без метки. Иначе переход шёл бы по
        кругу: новое число в боте, подтверждение, снова переход. Метка в счёт, только если это подтверждённый (ok) вход
        по этому самому коду, — номер знает лишь его страница; чужая, выдуманная или забытая (решённый запрос помнится
        час) метка ничего не меняет: без неё живой код нельзя было бы проверить молча, мимо запроса в бот."""
        now = self.now() if now is None else now
        code = as_code(raw)
        addr = addr_key(ip)
        after = str(after or "")
        after = after if REQUEST_RE.match(after) else ""
        if not code or not addr:
            return {"do": "404"}                        # слово сайта или не код вовсе: ни балла, ни тревоги
        with self._tx() as tx:
            st = tx.st
            if rid:
                # Опрос своей страницы: по номеру запроса, без банов (после «Это не я» адрес уже закрыт, а итог
                # человеку нужен). Чужой или забытый номер — 404 и без учёта: подбирать по нему нечего.
                req = st["requests"].get(rid) if REQUEST_RE.match(rid) else None
                if isinstance(req, dict) and req.get("code") == code and req.get("kind") == "login":
                    self._expire(tx, rid, req, now)
                    # number и request — только для страницы без JavaScript (она обновляет себя по ?r=); here — опрос
                    # с того же адреса, что начинал вход (одноразовое значение для полной ссылки служба выдаёт только
                    # ему, SHORT-03); в ответ опроса JSON уходит лишь status
                    return {"do": "status", "status": self._page_status(st, req, now), "request": rid,
                            "number": as_int(req.get("number")), "here": bool(addr) and req.get("addr") == addr}
                return {"do": "404"}
            live = self._resolve(st, code)
            acc = st["access"].get(code + " " + addr) if live else None
            acc = acc if isinstance(acc, dict) and as_int(acc.get("u")) > now else None
            if live and acc and acc.get("s") == "trust":
                # Свой клиент: этот адрес уже забирал подписку по этому коду — работает и во время бана
                return {"do": "serve", "code": code, "name": live[0], "suffix": live[1]}
            rec = st["addrs"].get(addr)
            if isinstance(rec, dict) and as_int(rec.get("u")) > now:
                return {"do": "404"}                    # бан закрывает только короткие ссылки
            if live:
                if isinstance(rec, dict) and as_int(rec.get("p")):
                    rec["p"] = 0                        # верный код между промахами — счёт сначала
                    tx.dirty = True
                if acc and acc.get("s") == "open":
                    return {"do": "serve", "code": code, "name": live[0], "suffix": live[1]}
                if browser and not head:
                    went = st["requests"].get(after) if after else None
                    if (isinstance(went, dict) and went.get("code") == code and went.get("kind") == "login"
                            and went.get("status") == "ok"):
                        # Переход страницы после «Вход подтверждён», а адрес не открыт и не доверен: без запроса в бот
                        return {"do": "page", "state": "moved"}
                    return self._login(tx, code, live, addr, ip, device, now)
                return {"do": "404"}                    # приложение без доверия: подтверждение — из браузера
            grave = st["graveyard"].get(code)
            if isinstance(grave, dict) and as_int(grave.get("until")) > now:
                return {"do": "404"}                    # кладбище: 404 без балла
            if code in self._index_of(st):
                return {"do": "404"}                    # код прежнего поколения подписки — тоже погашен, не подбор
            self._miss(tx, addr, code, now)
            return {"do": "404"}

    def fetched(self, code, ip, now=None):
        """Успешный забор по короткой ссылке: открытый адрес становится доверенным на 30 дней, у доверенного окно
        сдвигается (на диск — не чаще раза в час)."""
        now = self.now() if now is None else now
        addr = addr_key(ip)
        if not CODE_RE.match(str(code or "")) or not addr or not os.path.isfile(self.state_path):
            return
        with self._tx() as tx:
            key = code + " " + addr
            acc = tx.st["access"].get(key)
            if not isinstance(acc, dict) or as_int(acc.get("u")) <= now:
                return
            if acc.get("s") == "open":
                tx.st["access"][key] = {"c": code, "a": addr, "s": "trust", "u": int(now + TRUST_TTL), "f": int(now)}
                tx.dirty = True
                hit = self._index_of(tx.st).get(code) or ("-", "-")
                tx.audit.append(("short-trust", "user=%s suffix=%s" % hit))
            elif acc.get("s") == "trust" and now + TRUST_TTL - as_int(acc.get("u")) >= TRUST_SLIDE_STEP:
                acc["u"] = int(now + TRUST_TTL)
                tx.dirty = True

    def confirmed(self, raw, rid, now=None):
        """Полная ссылка странице подтверждения (SHORT-03, решение владельца 05.10): после «Вход подтверждён» страница
        просит полный адрес подписки, чтобы приложение обновлялось из любой сети без подтверждений. → {"name", "suffix",
        "left"} — rid — вход (login) по этому самому коду, подтверждён (ok), код живой и окно выдачи (FULL_TTL после
        решения) не вышло; {"expired": True} — подтверждён, но окно вышло («Нужна новая проверка»); None — номер чужой,
        выдуманный или забытый (решённый запрос помнится час), вход не подтверждён или код погашен. Адрес не
        проверяется: телефон, сменивший сеть после подтверждения, свою полную ссылку получит (номер запроса знает лишь
        страница, начавшая вход, а одноразовое значение служба выдаёт только ей). Только чтение: ни баллов, ни банов."""
        now = self.now() if now is None else now
        code = as_code(raw)
        if not code or not REQUEST_RE.match(str(rid or "")) or not os.path.isfile(self.state_path):
            return None
        with self._tx(write=False) as tx:
            st = tx.st
            req = st["requests"].get(rid)
            if (not isinstance(req, dict) or req.get("code") != code or req.get("kind") != "login"
                    or req.get("status") != "ok"):
                return None
            live = self._resolve(st, code)
            if live is None:
                return None
            left = int(as_int(req.get("decided")) + FULL_TTL - now)
            if left <= 0:
                return {"expired": True}
            return {"name": live[0], "suffix": live[1], "left": left}

    def _miss(self, tx, addr, code, now):
        """Неверный код с адреса: новый — балл (и в счёт тревоги), повтор того же — ничего. Три балла подряд — бан."""
        st = tx.st
        rec = st["addrs"].get(addr)
        if not isinstance(rec, dict):
            rec = st["addrs"][addr] = {"t": int(now)}
            self._cap_addrs(st, now, keep=addr)
        mark = code_hash(code)
        seen = [s for s in (rec.get("seen") or []) if isinstance(s, str)]
        rec["t"] = int(now)
        tx.dirty = True
        if mark in seen:
            rec["seen"] = seen
            return
        rec["seen"] = (seen + [mark])[-SEEN_MAX:]
        rec["p"] = as_int(rec.get("p")) + 1
        self._count_miss(tx, now)
        if rec["p"] >= STRIKES:
            self._ban(tx, addr, rec, "misses", now)

    def _ban(self, tx, addr, rec, why, now):
        """Бан адреса по лестнице: первый — сутки, каждый следующий — месяц."""
        level = as_int(rec.get("lv"))
        rec["u"] = int(now + (DAY if level == 0 else MONTH))
        rec["lv"] = level + 1
        rec["p"] = 0
        rec["why"] = why
        rec["t"] = int(now)
        tx.dirty = True
        tx.audit.append(("short-ban", "kind=ip level=%d reason=%s" % (level + 1, why)))
        if self.log:
            self.log.warn("короткие ссылки: адрес закрыт на %s (уровень %d, %s)"
                          % ("сутки" if level == 0 else "месяц", level + 1, why))

    def _cap_addrs(self, st, now, keep=""):
        table = st["addrs"]
        if len(table) <= ADDR_MAX:
            return
        # Сначала без действующего бана — давно молчавшие, потом и с баном — те, чей бан кончается раньше всех;
        # запись, ради которой место освобождаем, не трогаем
        order = sorted((a for a in table if a != keep),
                       key=lambda a: (as_int(table[a].get("u")) > now, as_int(table[a].get("u")),
                                      as_int(table[a].get("t"))))
        for key in order[:len(table) - ADDR_MAX]:
            del table[key]

    def _count_miss(self, tx, now):
        st = tx.st
        minute = int(now // 60)
        misses = st["misses"]
        misses[str(minute)] = as_int(misses.get(str(minute))) + 1
        for key in [k for k in misses if as_int(k, -1) <= minute - 60]:
            del misses[key]
        total = sum(as_int(v) for v in misses.values())
        if total > ALARM_MISSES and now - as_int(st.get("alarm_at")) >= 3600:
            st["alarm_at"] = int(now)
            tx.notify.append(("short_alarm", {"misses_hour": total}))
            tx.audit.append(("short-alarm", "misses_hour=%d" % total))

    def _pending(self, tx, code, now):
        """Ожидающий запрос по коду (истёкшие по пути закрываются) → (id, запрос) или None."""
        for rid, req in list(tx.st["requests"].items()):
            if isinstance(req, dict) and req.get("code") == code and req.get("status") == "pending":
                if self._expire(tx, rid, req, now):
                    continue
                return rid, req
        return None

    def _hour_stamps(self, st, code, now):
        cst = st["codes"].get(code)
        return [t for t in ((cst or {}).get("rq") or []) if isinstance(t, int) and now - t < 3600]

    def _limit(self, tx, code, now):
        """Пятый запрос за час — предел: → секунд до освобождения места или 0."""
        stamps = self._hour_stamps(tx.st, code, now)
        if len(stamps) < HOURLY_REQUESTS:
            return 0
        return max(1, int(sorted(stamps)[-HOURLY_REQUESTS] + 3600 - now))

    def _login(self, tx, code, live, addr, ip, device, now):
        st = tx.st
        cst = st["codes"].get(code) or {}
        frozen = as_int(cst.get("fu"))
        if frozen > now:
            return {"do": "page", "state": "frozen", "days": 1 if as_int(cst.get("fl")) <= 1 else 30,
                    "left": int(frozen - now)}
        pend = self._pending(tx, code, now)
        if pend is not None:
            rid, req = pend
            if req.get("kind") == "login" and req.get("addr") == addr:
                return {"do": "page", "state": "wait", "request": rid, "number": as_int(req.get("number")),
                        "left": max(1, int(as_int(req.get("expires")) - now))}
            return {"do": "page", "state": "busy", "left": max(1, int(as_int(req.get("expires")) - now))}
        wait = self._limit(tx, code, now)
        if wait:
            return {"do": "page", "state": "limit", "left": wait}
        rid, req = self._new_request(tx, "login", live[0], live[1], code, addr, ip, device, "", now)
        return {"do": "page", "state": "wait", "request": rid, "number": req["number"], "left": REQUEST_TTL}

    def _new_request(self, tx, kind, name, suffix, code, addr, ip, device, who, now):
        st = tx.st
        number = 10 + secrets.randbelow(90)
        options = _RNG.sample([n for n in range(10, 100) if n != number], 9) + [number]
        _RNG.shuffle(options)
        rid = secrets.token_urlsafe(12)
        while rid in st["requests"]:
            rid = secrets.token_urlsafe(12)
        geo = ""
        if ip:
            try:
                geo = str(self.geo(ip) or "")
            except Exception:                           # noqa: BLE001 — без города запрос всё равно уйдёт
                geo = ""
        req = {"kind": kind, "name": name, "label": self._label(name), "suffix": suffix, "code": code,
               "addr": addr, "ip": str(ip or ""), "device": str(device or "")[:64], "geo": geo[:80], "who": who,
               "number": number, "options": options, "created": int(now), "expires": int(now + REQUEST_TTL),
               "status": "pending", "by": "", "decided": 0}
        st["requests"][rid] = req
        cst = st["codes"].setdefault(code, {})
        cst["rq"] = self._hour_stamps(st, code, now) + [int(now)]
        self._cap_requests(st, now)
        tx.dirty = True
        tx.confirm.append(("short_confirm", self._public(rid, req, now)))
        tx.audit.append(("short-request", "kind=%s user=%s suffix=%s who=%s" % (kind, name, suffix, who or "link")))
        return rid, req

    def _cap_requests(self, st, now):
        reqs = st["requests"]
        if len(reqs) <= REQUEST_MAX:
            return
        done = sorted((r for r in reqs if reqs[r].get("status") != "pending"), key=lambda r: as_int(reqs[r].get("created")))
        for rid in done[:len(reqs) - REQUEST_MAX]:
            del reqs[rid]

    def _public(self, rid, req, now):
        """Запрос для бота, панели и SSH — без верного числа."""
        return {"request": rid, "kind": req.get("kind"), "name": req.get("name"), "label": req.get("label"),
                "suffix": req.get("suffix"), "device": req.get("device") or "", "ip": req.get("ip") or "",
                "geo": req.get("geo") or "", "options": list(req.get("options") or []), "who": req.get("who") or "",
                "created": iso(as_int(req.get("created"))), "expires": iso(as_int(req.get("expires"))),
                "left": max(0, int(as_int(req.get("expires")) - now))}

    def _expire(self, tx, rid, req, now):
        """Ожидающий запрос, чей срок вышел, — истёкший (отказом не считается). → True, если закрыт сейчас."""
        if req.get("status") == "pending" and as_int(req.get("expires")) <= now:
            self._finish(tx, rid, req, "expired", "", now)
            return True
        return False

    def _finish(self, tx, rid, req, status, by, now):
        req["status"] = status
        req["by"] = by
        req["decided"] = int(now)
        tx.dirty = True
        tx.confirm.append(("short_decided", {"request": rid, "status": status, "by": by}))
        tx.audit.append(("short-decide", "kind=%s user=%s suffix=%s status=%s by=%s"
                         % (req.get("kind"), req.get("name"), req.get("suffix"), status, by or "-")))

    def _page_status(self, st, req, now):
        """Итог для страницы подтверждения: без кода (тот, кто открыл ссылку, может быть атакующим)."""
        status = req.get("status") or "pending"
        out = {"decision": status, "left": max(0, int(as_int(req.get("expires")) - now)) if status == "pending" else 0}
        if status == "ok":
            acc = st["access"].get("%s %s" % (req.get("code"), req.get("addr")))
            out["open_left"] = max(0, int(as_int(acc.get("u")) - now)) if isinstance(acc, dict) else 0
            # Сколько ещё страница может взять полную ссылку (SHORT-03); 0 — «Нужна новая проверка»
            out["full_left"] = max(0, int(as_int(req.get("decided")) + FULL_TTL - now))
        elif status == "wrong":
            out["strikes"] = as_int(req.get("strikes"))
        elif status in ("frozen", "denied"):
            out["days"] = as_int(req.get("days")) or 1
        return out

    # ── публичное: замена и решения ──────────────────────────────────────────
    def replace_request(self, name, suffix, who, ip="", device="", now=None):
        """Запрос замены короткой ссылки (кнопка ↻ на странице, в панели, SSH или боте): число показывает тот, кто
        попросил, решает администратор в боте (10 чисел и «Это не я»). Ожидающий запрос по этому коду — чужой вход или
        прежняя замена — не мешает администратору (who — panel, ssh, bot, bot:<id>): он закрывается как «заменён»
        (short_decided, status swapped, by = who), и замена идёт дальше (SL-UX-03); странице (who=page) — по-прежнему
        short_pending.
        → {request, number, expires, left}."""
        now = self.now() if now is None else now
        if suffix not in SUFFIXES:
            raise ShortError("bad_suffix", 2)
        if not self.available():
            raise ShortError("short_need_bot", 2)
        if self._sub_generation(name) is None:
            raise ShortError("sub_not_found", 3)
        with self._tx() as tx:
            ent = self._live_codes(name).get(suffix)
            if not ent:
                raise ShortError("short_not_found", 3)
            code = str(ent["code"])
            pend = self._pending(tx, code, now)
            if pend is not None and str(who).split(":")[0] in ADMIN_WHO:
                # Вход, открытый кем-то другим, или прежняя замена администратору не помеха: закрыт как «заменён»
                # (страница входа и замены так и покажет), а при отказе дальше (предел запросов) правка откатывается
                # вместе с замком
                self._finish(tx, pend[0], pend[1], "swapped", who, now)
                pend = None
            if pend is not None:
                raise ShortError("short_pending", 2, left=max(1, int(as_int(pend[1].get("expires")) - now)))
            wait = self._limit(tx, code, now)
            if wait:
                raise ShortError("short_limit", 2, left=wait)
            addr = addr_key(ip) if ip else ""
            rid, req = self._new_request(tx, "replace", name, suffix, code, addr, ip if addr else "", device, who, now)
            return {"request": rid, "number": req["number"], "expires": iso(req["expires"]), "left": REQUEST_TTL}

    def decide(self, rid, answer, by="", now=None):
        """Решение администратора (бот, панель, SSH): answer — число 10–99, deny («Это не я») или swap («↻
        Заменить ссылку», только у входа). Решает первый: повторное нажатие получает прежний итог (already).
        → {decision: ok|wrong|denied|swapped|expired|frozen, display?, url?} (поле decision, а не status: status корня
        у моста занят конвертом success|error)."""
        now = self.now() if now is None else now
        answer = str(answer or "").strip()
        if not REQUEST_RE.match(str(rid or "")):
            raise ShortError("short_request_not_found", 3)
        if not re.match(r"^([1-9][0-9]|deny|swap)$", answer):
            raise ShortError("short_bad_answer", 2)
        by = "".join(ch for ch in str(by or "") if ch.isprintable())[:64]
        if not os.path.isfile(self.state_path):
            raise ShortError("short_request_not_found", 3)
        with self._tx() as tx:
            st = tx.st
            req = st["requests"].get(rid)
            if not isinstance(req, dict):
                raise ShortError("short_request_not_found", 3)
            self._expire(tx, rid, req, now)
            if req.get("status") != "pending":
                out = {"decision": req.get("status"), "already": True, "by": req.get("by") or ""}
                out.update(self._new_code_out(req))
                return out
            if answer == "swap" and req.get("kind") != "login":
                raise ShortError("short_bad_answer", 2)
            live = self._resolve(st, str(req.get("code") or ""))
            if live is None:
                # Код погасили, пока запрос ждал (перевыпуск, отзыв, замена): решать нечего
                self._finish(tx, rid, req, "expired", by, now)
                return {"decision": "expired"}
            name, suffix, _ent = live
            code = str(req["code"])
            cst = st["codes"].setdefault(code, {})
            out = {}
            if answer == "deny":
                status = "denied"
                addr = str(req.get("addr") or "")
                if addr:
                    rec = st["addrs"].get(addr)
                    if not isinstance(rec, dict):
                        rec = st["addrs"][addr] = {"t": int(now)}
                        self._cap_addrs(st, now, keep=addr)
                    req["days"] = 1 if as_int(rec.get("lv")) == 0 else 30
                    self._ban(tx, addr, rec, "denied", now)
            elif answer == "swap":
                status = "swapped"
                out = self._swap(tx, req, name, suffix, code, "swap", now)
            elif int(answer) == as_int(req.get("number")):
                status = "ok"
                cst["w"] = 0
                if req.get("kind") == "login":
                    key = "%s %s" % (code, req.get("addr"))
                    st["access"][key] = {"c": code, "a": req.get("addr"), "s": "open", "u": int(now + OPEN_TTL)}
                    self._cap_access(st, code, now)
                else:
                    out = self._swap(tx, req, name, suffix, code, "replace", now)
            else:
                strikes = as_int(cst.get("w")) + 1
                if strikes >= STRIKES:
                    status = "frozen"
                    level = as_int(cst.get("fl"))
                    cst["fu"] = int(now + (DAY if level == 0 else MONTH))
                    cst["fl"] = level + 1
                    cst["w"] = 0
                    req["days"] = 1 if level == 0 else 30
                    tx.audit.append(("short-freeze", "user=%s suffix=%s level=%d" % (name, suffix, level + 1)))
                else:
                    status = "wrong"
                    cst["w"] = strikes
                    req["strikes"] = strikes
            tx.dirty = True
            self._finish(tx, rid, req, status, by, now)
            res = {"decision": status}
            res.update(out)
            return res

    def _swap(self, tx, req, name, suffix, code, why, now):
        """Новый код пары взамен code (замена из бота или подтверждённая кнопка ↻); старый — в кладбище."""
        gen = self._sub_generation(name) or 1
        codes = self._read_codes(name)
        ent = self._new_entry(tx, name, suffix, gen, now)
        codes[suffix] = ent
        self._write_codes(name, codes)
        req["status"] = "deciding"           # _bury не закроет этот же запрос как истёкший
        self._bury(tx, code, name, suffix, why, now)
        req["new"] = ent["code"]
        req["new_display"] = ent["display"]
        tx.audit.append(("short-replace", "user=%s suffix=%s why=%s" % (name, suffix, why)))
        return {"display": ent["display"], "url": self._url(ent["display"])}

    def _new_code_out(self, req):
        if req.get("new_display") and req.get("status") in ("ok", "swapped"):
            return {"display": req["new_display"], "url": self._url(req["new_display"])}
        return {}

    def _cap_access(self, st, code, now):
        table = st["access"]
        mine = sorted((k for k, a in table.items() if isinstance(a, dict) and a.get("c") == code),
                      key=lambda k: as_int(table[k].get("u")))
        for key in mine[:max(0, len(mine) - ACCESS_PER_CODE)]:
            del table[key]
        if len(table) > ACCESS_MAX:
            for key in sorted(table, key=lambda k: as_int(table[k].get("u")))[:len(table) - ACCESS_MAX]:
                del table[key]

    def status(self, rid, name=None, now=None):
        """Состояние запроса для опроса (панель, SSH, страница с кнопкой ↻): {decision, kind, expires, left,
        display?, url?}; новый код — только у подтверждённой замены и у «↻ Заменить ссылку» входа. name — запрос
        должен быть этой подписки (страница). Нет такого — ShortError short_request_not_found."""
        now = self.now() if now is None else now
        if not REQUEST_RE.match(str(rid or "")) or not os.path.isfile(self.state_path):
            raise ShortError("short_request_not_found", 3)
        with self._tx() as tx:
            req = tx.st["requests"].get(rid)
            if not isinstance(req, dict) or (name is not None and req.get("name") != name):
                raise ShortError("short_request_not_found", 3)
            self._expire(tx, rid, req, now)
            out = {"decision": req.get("status"), "kind": req.get("kind"), "suffix": req.get("suffix"),
                   "expires": iso(as_int(req.get("expires"))),
                   "left": max(0, int(as_int(req.get("expires")) - now)) if req.get("status") == "pending" else 0}
            out.update(self._new_code_out(req))
            if req.get("status") in ("frozen", "denied"):
                out["days"] = as_int(req.get("days")) or 1
            return out

    def pending(self, now=None):
        """Ждут подтверждения — для панели (запасной путь без Telegram): без верного числа."""
        now = self.now() if now is None else now
        with self._tx(write=os.path.isfile(self.state_path)) as tx:
            out = []
            for rid, req in sorted(tx.st["requests"].items(), key=lambda kv: as_int(kv[1].get("created"))):
                if not isinstance(req, dict) or req.get("status") != "pending":
                    continue
                if self._expire(tx, rid, req, now):
                    continue
                item = self._public(rid, req, now)
                item["created"] = iso(as_int(req.get("created")))
                out.append(item)
            return out

    def bans(self, now=None):
        """Действующие баны адресов и заморозки кодов: [{kind: ip|code, target, level, until, reason, …}]."""
        now = self.now() if now is None else now
        with self._tx(write=False) as tx:
            st = tx.st
            out = []
            for addr, rec in sorted(st["addrs"].items()):
                if isinstance(rec, dict) and as_int(rec.get("u")) > now:
                    out.append({"kind": "ip", "target": addr, "level": as_int(rec.get("lv")),
                                "until": iso(as_int(rec.get("u"))), "reason": rec.get("why") or "misses"})
            index = self._index_of(st)
            for code, cst in sorted(st["codes"].items()):
                if isinstance(cst, dict) and as_int(cst.get("fu")) > now:
                    name, suffix = index.get(code, ("", ""))
                    ent = self._live_codes(name).get(suffix) if name else None
                    display = str((ent or {}).get("display") or code)
                    out.append({"kind": "code", "target": display, "level": as_int(cst.get("fl")),
                                "until": iso(as_int(cst.get("fu"))), "reason": "wrong", "name": name,
                                "label": self._label(name) if name else "", "suffix": suffix})
            return out

    def unban(self, target, now=None):
        """Снять бан адреса или заморозку кода (бот, панель, SSH): лестница начинается заново. → {unbanned: true|false,
        kind}."""
        now = self.now() if now is None else now
        kind, key = target_key(target)
        if not kind:
            raise ShortError("bad_target", 2)
        if not os.path.isfile(self.state_path):
            return {"unbanned": False, "kind": kind}
        with self._tx() as tx:
            st = tx.st
            done = False
            if kind == "ip":
                rec = st["addrs"].pop(key, None)
                done = isinstance(rec, dict) and (as_int(rec.get("u")) > now or as_int(rec.get("lv")) > 0
                                                  or as_int(rec.get("p")) > 0)
            else:
                cst = st["codes"].get(key)
                if isinstance(cst, dict) and (as_int(cst.get("fu")) > now or as_int(cst.get("fl")) or as_int(cst.get("w"))):
                    for field in ("fu", "fl", "w"):
                        cst.pop(field, None)
                    done = True
            if done:
                tx.dirty = True
                tx.audit.append(("short-unban", "kind=%s" % kind))
            return {"unbanned": done, "kind": kind}

    def sweep(self, now=None, tidy=None):
        """Истёкшие запросы — истёкшими (событие short_decided, бот уберёт кнопки), раз в 10 минут — уборка:
        кладбище старше 30 дней, решённые запросы старше часа, баллы без банов, кончившееся доверие. → закрыто
        запросов."""
        now = self.now() if now is None else now
        if not os.path.isfile(self.state_path):
            return 0
        if tidy is None:
            tidy = time.monotonic() - self._tidied >= 600
        with self._tx() as tx:
            st = tx.st
            n = 0
            for rid, req in list(st["requests"].items()):
                if isinstance(req, dict) and self._expire(tx, rid, req, now):
                    n += 1
            if tidy:
                self._tidied = time.monotonic()
                self._tidy(tx, now)
            return n

    def _tidy(self, tx, now):
        st = tx.st
        before = json.dumps(st, sort_keys=True)
        for code in [c for c, g in st["graveyard"].items() if as_int((g or {}).get("until")) <= now]:
            del st["graveyard"][code]
        for rid in [r for r, q in st["requests"].items()
                    if q.get("status") != "pending" and now - as_int(q.get("decided") or q.get("expires")) > DECIDED_KEEP]:
            del st["requests"][rid]
        for key in [k for k, a in st["access"].items() if as_int((a or {}).get("u")) <= now]:
            del st["access"][key]
        for addr in list(st["addrs"]):
            rec = st["addrs"][addr]
            if as_int(rec.get("u")) > now:
                continue
            keep = LEVEL_KEEP if as_int(rec.get("lv")) else ADDR_IDLE_KEEP
            if now - max(as_int(rec.get("t")), as_int(rec.get("u"))) > keep:
                del st["addrs"][addr]
        index = self._index_of(st)
        for code in list(st["codes"]):
            cst = st["codes"][code]
            if code not in index:
                del st["codes"][code]
                continue
            cst["rq"] = self._hour_stamps(st, code, now)
            if not cst["rq"]:
                del cst["rq"]
            if not cst:
                del st["codes"][code]
        minute = int(now // 60)
        for key in [k for k in st["misses"] if as_int(k, -1) <= minute - 60]:
            del st["misses"][key]
        if json.dumps(st, sort_keys=True) != before:
            tx.dirty = True


# ══════════════════════════════════════════════════════════════════════════════
#  Командная строка — для моста (lib/subs.sh)
# ══════════════════════════════════════════════════════════════════════════════
def _cli_audit():
    """Аудит из моста — строкой того же вида, что ga_audit (CONTRACT §7.1): {ts, iface, stage, who, action,
    details}; кто — из GOAMNEZIA_WHO."""
    path = os.environ.get("GOAMNEZIA_AUDIT_LOG") or ""
    who = os.environ.get("GOAMNEZIA_WHO") or "ssh"
    if who.startswith("panel"):
        iface = "panel"
    elif who.startswith("bot"):
        iface = "bot"
    elif who.startswith("agent:") or who.startswith("mcp"):
        iface = "mcp"
    elif who == "pages":
        iface = "pages"
    else:
        iface = "ssh"

    def write(action, details):
        if not path:
            return
        line = json.dumps({"ts": iso(time.time()), "iface": iface, "stage": "effect", "who": who, "action": action,
                           "details": str(details).replace("\n", " ")}, ensure_ascii=False) + "\n"
        try:
            fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        except OSError:
            return
        try:
            os.write(fd, line.encode("utf-8", "replace"))
        except OSError:
            pass
        finally:
            os.close(fd)
    return write


def _args(argv):
    out = {}
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg.startswith("--") and "=" in arg:
            key, value = arg[2:].split("=", 1)
            out[key] = value
            i += 1
        elif arg.startswith("--") and i + 1 < len(argv):
            out[arg[2:]] = argv[i + 1]
            i += 2
        else:
            raise ShortError("bad_arg", 2)
    return out


def main(argv):
    """python3 shortlinks.py <команда> [--ключ значение]… → одна строка JSON в stdout; отказ — {"error": код, …}
    и код возврата (2 — неверный ввод, 3 — нет такого, 1 — прочее). Команды: available, ensure, list, urls, kill,
    replace-request, decide, status, pending, bans, unban, sweep, normalize."""
    if not argv:
        print(json.dumps({"error": "bad_arg"}))
        return 2
    cmd = argv[0]
    try:
        args = _args(argv[1:])
        links = ShortLinks(audit=_cli_audit())
        if cmd == "available":
            out = {"available": links.available()}
        elif cmd == "ensure":
            out = links.ensure(args.get("name", ""), args.get("suffix", ""), who=os.environ.get("GOAMNEZIA_WHO", ""))
        elif cmd == "list":
            name = args.get("name", "")
            if links._sub_generation(name) is None:
                raise ShortError("sub_not_found", 3)
            codes = links.codes_of(name)
            out = {"codes": [codes[s] for s in SUFFIXES if s in codes], "short_available": links.available()}
        elif cmd == "urls":
            codes = links.codes_of(args.get("name", ""))
            out = {"available": links.available(), "short": {s: c["url"] for s, c in codes.items()}}
        elif cmd == "kill":
            out = {"killed": links.kill(args.get("name", ""), args.get("reason", "revoked"))}
        elif cmd == "replace-request":
            who = args.get("who", "")
            if not WHO_RE.match(who):
                raise ShortError("bad_arg", 2)
            out = links.replace_request(args.get("name", ""), args.get("suffix", ""), who)
        elif cmd == "decide":
            out = links.decide(args.get("request", ""), args.get("answer", ""),
                               args.get("who", "") or os.environ.get("GOAMNEZIA_WHO", ""))
        elif cmd == "status":
            out = links.status(args.get("request", ""))
        elif cmd == "pending":
            out = {"requests": links.pending()}
        elif cmd == "bans":
            out = {"bans": links.bans()}
        elif cmd == "unban":
            out = links.unban(args.get("target", ""))
        elif cmd == "sweep":
            out = {"expired": links.sweep(tidy=True)}
        elif cmd == "normalize":
            out = {"code": normalize(args.get("text", ""))}
        else:
            raise ShortError("bad_arg", 2)
    except ShortError as exc:
        err = {"error": exc.code}
        err.update(exc.extra)
        print(json.dumps(err, ensure_ascii=False))
        return exc.rc
    except OSError as exc:
        print(json.dumps({"error": "write_failed", "detail": str(exc.strerror or exc)}, ensure_ascii=False))
        return 1
    print(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
