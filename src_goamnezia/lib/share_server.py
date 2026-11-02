#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""goAmnezia pro — одноразовый HTTPS-сервер временной ссылки (lib/share.sh, docs/SHARE.md).

Зачем он есть. Администратор сидит в SSH-меню с телефона или с чужой машины и
хочет забрать .conf на компьютер, не таща текст через терминал. Модуль
lib/share.sh кладёт файл во временный каталог и запускает ЭТОТ процесс: он
поднимает TLS-слушатель на случайном свободном порту, отдаёт файл по одному
секретному пути и через TTL (по умолчанию 5 минут) гасит себя сам, затирая
файл и секрет.

Почему отдельный процесс, а не общая служба. В конфиге лежит ПРИВАТНЫЙ КЛЮЧ
клиента. Постоянно работающая раздача — постоянно доступная поверхность атаки;
процесс, который живёт пять минут и умирает вместе со своими файлами, её не
создаёт. По той же причине раздачи НЕ восстанавливаются после перезагрузки
сервера: состояние лежит в /run (tmpfs), и после ребута ссылок просто нет.

Правила, которые здесь важнее красоты (docs/SHARE.md §3):
  • только HTTPS: файл с приватным ключом по открытому HTTP не отдаём;
  • своей страницы у ссылки нет (решение владельца В1, 26.09.2026): по верному
    адресу сразу отдаётся файл, скачать можно несколько раз, пока ссылка живёт
    (по умолчанию 5 минут); предупреждение о самоподписанном сертификате — экран
    самого браузера, отпечаток человеку присылает администратор;
  • неизвестный путь, истёкшая или снятая ссылка → 404 с телом и заголовками
    nginx по умолчанию, без единой подсказки;
  • счётчик неудач по IP с временным баном — приём из goamnezia-mcp/server.py,
    бан тоже отвечает 404, чтобы подбирающий не узнал, что его заметили;
  • секретная часть пути НЕ пишется ни в лог, ни в аудит — только id раздачи;
  • Content-Disposition: attachment и запрет кеширования: браузер не должен ни
    показать конфиг на экране, ни оставить его в кеше.

Только stdlib: на сервере нет и не будет pip-зависимостей у этой части.

Запуск (его делает lib/share.sh, вручную он не нужен):
    python3 share_server.py --dir /run/goamnezia/share/s-1a2b
Каталог раздачи содержит meta.json (0600), secret (0600) и payload/<файл>.
"""

import os
import re
import sys
import ssl
import json
import time
import errno
import signal
import hmac
import socket
import threading
import http.server
import socketserver

# ── Пороги бана. Раздача живёт минуты, поэтому они жёстче, чем у MCP: там
# агент работает часами и случайные ошибки нормальны, здесь один правильный
# адрес приходит копипастой, а всё остальное — перебор.
BAN_FAILURES = 10                 # неудач с одного IP…
BAN_WINDOW = 300.0                # …за 5 минут…
BAN_SECONDS = 900.0               # …→ 15 минут молчания (тоже 404, не 429)
FAILURE_TABLE_MAX = 4096          # потолок таблицы IP: сканер не раздует память
READ_TIMEOUT = 30                 # секунд на чтение запроса
MAX_REQUEST_LINE = 2048           # длиннее нашего пути не бывает — режем сразу
STOP_GRACE = 0.4                  # даём дописать текущий ответ перед выходом
# Срок TLS-рукопожатия одного соединения (секунды): дольше молчащий клиент отключается.
TLS_HANDSHAKE_TIMEOUT = 15
# Сколько ждать конца ИДУЩИХ отдач, прежде чем гасить слушатель и затирать
# файл. Раньше ждали только STOP_GRACE, и скачивание рвалось на середине:
# истёк TTL — сторож гасит сервер, уборка в lib/share.sh сносит каталог, а
# клиент в этот момент ещё тянет файл по медленному мобильному каналу и
# получает обрезанный .conf, который выглядит как «продукт выдал битый ключ».
# Новых скачиваний за дедлайном не начинается (их не пускает Share.take), так
# что ожидание НЕ продлевает жизнь ссылки — оно только доводит до конца то,
# что уже началось. Потолок нужен на случай клиента, который открыл соединение
# и не читает: вечно живая раздача была бы хуже оборванной.
DRAIN_MAX = 120.0                 # секунд на дорезание начатых отдач

# Единственный законный путь: /d-<43 символа base64url>/<имя файла>.
# 43 символа = 32 случайных байта в base64url без «=» — перебор невозможен,
# поэтому отдельной авторизации у раздачи нет: путь И ЕСТЬ ключ.
PATH_RE = re.compile(r"^/d-([A-Za-z0-9_-]{43})/([A-Za-z0-9._-]{1,128})$")

# Тело 404 — байт в байт как у nginx по умолчанию: ответ на чужой путь не
# должен отличаться от ответа обычного сайта на тот же путь.
NGINX_404 = (b"<html>\r\n<head><title>404 Not Found</title></head>\r\n<body>\r\n"
             b"<center><h1>404 Not Found</h1></center>\r\n<hr><center>nginx</center>\r\n"
             b"</body>\r\n</html>\r\n")


def utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def mask_path(text):
    """Секрет из строки — на «d-***». Зовётся ПЕРЕД каждой записью в лог: путь
    попадает в лог и от самого http.server (log_message), и из наших сообщений."""
    return re.sub(r"d-[A-Za-z0-9_-]{6,}", "d-***", str(text))


class Log(object):
    """Лог процесса: stderr, который lib/share.sh перенаправляет в server.log
    внутри каталога раздачи (он удаляется вместе с ней). Всё, что сюда идёт,
    проходит через mask_path — иначе секрет пережил бы саму раздачу."""

    def __init__(self, stream):
        self.stream = stream
        self.lock = threading.Lock()

    def write(self, level, text):
        line = "%s %s %s\n" % (utc_now(), level, mask_path(text))
        with self.lock:
            try:
                self.stream.write(line)
                self.stream.flush()
            except (OSError, ValueError):
                pass

    def info(self, text):
        self.write("info", text)

    def warn(self, text):
        self.write("warn", text)

    def error(self, text):
        self.write("error", text)


class Audit(object):
    """Аудит продукта: тот же формат, что у ga_audit в lib/common.sh — одна
    строка, один объект JSON (CONTRACT §7.1). Пишем через O_APPEND одной
    строкой: короткая запись в режиме дописывания атомарна, поэтому замок не
    нужен и таймер, пишущий туда же, ничего не порвёт.

    В подробностях — ТОЛЬКО id раздачи. Ни секрета, ни полного пути: аудит
    живёт на диске месяцами, а ссылка — пять минут; секрет в нём означал бы,
    что «временная» ссылка на самом деле вечная."""

    def __init__(self, path, log):
        self.path = path
        self.log = log

    def write(self, action, details):
        if not self.path:
            return
        line = json.dumps({"ts": utc_now(), "iface": "share", "stage": "effect",
                           "who": "share", "action": action,
                           "details": mask_path(details).replace("\n", " ")},
                          ensure_ascii=False, sort_keys=True) + "\n"
        try:
            fd = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        except OSError as exc:
            self.log.warn("аудит недоступен: %s" % exc)
            return
        try:
            os.write(fd, line.encode("utf-8", "replace"))
        except OSError as exc:
            self.log.warn("аудит не записан: %s" % exc)
        finally:
            try:
                os.close(fd)
            except OSError:
                pass


class FailureTracker(object):
    """Неудачи по IP: BAN_FAILURES за BAN_WINDOW → бан на BAN_SECONDS.

    Копия приёма из goamnezia-mcp/server.py, включая главное: забаненный
    получает тот же 404, что и любой промахнувшийся. Ответ «слишком много
    попыток» подтвердил бы, что по этому адресу что-то есть."""

    def __init__(self, limit=BAN_FAILURES, window=BAN_WINDOW, ban=BAN_SECONDS, now=time.monotonic):
        self.limit, self.window, self.ban, self.now = limit, window, ban, now
        self._lock = threading.Lock()
        self._fails = {}
        self._banned = {}

    def banned(self, ip):
        with self._lock:
            until = self._banned.get(ip)
            if until is None:
                return False
            if until <= self.now():
                del self._banned[ip]
                return False
            return True

    def record(self, ip):
        """Отметить неудачу; True — этим запросом IP забанен."""
        now = self.now()
        with self._lock:
            stamps = [t for t in self._fails.get(ip, []) if now - t < self.window]
            stamps.append(now)
            self._fails[ip] = stamps
            if len(self._fails) > FAILURE_TABLE_MAX:
                for key in [k for k, v in self._fails.items() if not v or now - v[-1] >= self.window]:
                    del self._fails[key]
                while len(self._fails) > FAILURE_TABLE_MAX:
                    self._fails.pop(next(iter(self._fails)))
            if len(stamps) >= self.limit:
                self._banned[ip] = now + self.ban
                del self._fails[ip]
                return True
            return False


class Share(object):
    """Одна раздача: метаданные, секрет, файл и всё, что с ними делается.

    Каталог раздачи — единица жизни: пока он есть, ссылка работает; как только
    он снят, не осталось ни файла, ни секрета, ни отметки о пути."""

    def __init__(self, directory, log, audit, users_file=""):
        self.dir = os.path.abspath(directory)
        self.log = log
        self.audit = audit
        self.users_file = users_file
        self.meta = self._read_json("meta.json")
        self.user = str(self.meta.get("name") or "")
        self.secret = self._read_text("secret")
        self.id = str(self.meta.get("id") or "")
        self.file_name = str(self.meta.get("file_name") or "")
        self.payload = os.path.join(self.dir, "payload", self.file_name)
        self.deadline = float(self.meta.get("expires_epoch") or 0)
        self.max_downloads = int(self.meta.get("max_downloads") or 0)
        self._lock = threading.Lock()
        # Отдельный замок под счётчик идущих отдач: wipe() держит self._lock и
        # ждать под ним конца скачивания нельзя — take() из потока запроса
        # берёт тот же замок, и мы встали бы сами против себя.
        self._idle = threading.Condition(threading.Lock())
        self.inflight = 0
        self.downloads = 0
        self.dead = False

    # ── чтение каталога раздачи ────────────────────────────────────────────
    def _read_json(self, name):
        with open(os.path.join(self.dir, name), "r", encoding="utf-8") as fh:
            return json.load(fh)

    def _read_text(self, name):
        with open(os.path.join(self.dir, name), "r", encoding="utf-8") as fh:
            return fh.read().strip()

    def valid(self):
        """Каталог пригоден к раздаче? Пустой секрет или отсутствующий файл —
        не «отдадим пустое», а отказ стартовать: пустой секрет означал бы путь,
        который подбирается с первого раза."""
        problems = []
        if not re.match(r"^[A-Za-z0-9_-]{43}$", self.secret or ""):
            problems.append("secret")
        if not re.match(r"^[A-Za-z0-9._-]{1,128}$", self.file_name or ""):
            problems.append("file_name")
        if not os.path.isfile(self.payload):
            problems.append("payload")
        if self.deadline <= 0:
            problems.append("expires_epoch")
        return problems

    def seconds_left(self):
        return self.deadline - time.time()

    def user_off(self):
        """A4-2: пользователя выключили — ссылка файл не отдаёт (404), как подписка (pages_server sub_answer):
        «выключен — ключ наружу не отдаём». Включили — снова отдаёт, пока не вышел срок: ссылку не снимаем, а
        проверяем на каждом запросе. Решает только явное enabled: false; учёт не задан (старый запуск без --users),
        не читается или человека в нём нет — как раньше: раздача отдаёт снимок файла и живёт минуты."""
        if not self.users_file or not self.user:
            return False
        try:
            with open(self.users_file, "r", encoding="utf-8") as fh:
                doc = json.load(fh)
        except (OSError, ValueError) as exc:
            self.log.warn("учёт пользователей не прочитан: %s" % exc)
            return False
        users = doc.get("users") if isinstance(doc, dict) else None
        for u in users if isinstance(users, list) else []:
            if isinstance(u, dict) and u.get("name") == self.user:
                return u.get("enabled") is False
        return False

    def match(self, secret, file_name):
        """Сравнение секрета — compare_digest: обычное == выходит на первом
        несовпавшем символе, и по времени ответа секрет подбирается побайтно."""
        if not hmac.compare_digest(secret, self.secret):
            return False
        return hmac.compare_digest(file_name, self.file_name)

    # ── идущие отдачи ──────────────────────────────────────────────────────
    def _mark_busy(self, busy):
        """Маркер busy — единственный способ для lib/share.sh узнать, что файл
        прямо сейчас едет клиенту: уборка снаружи видит только каталог. Внутри
        — время начала, чтобы маркер, оставшийся от убитого процесса, не делал
        раздачу бессмертной."""
        path = os.path.join(self.dir, "busy")
        try:
            if busy:
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    fh.write("%d\n" % int(time.time()))
            elif os.path.exists(path):
                os.unlink(path)
        except OSError as exc:
            self.log.warn("маркер отдачи не обновлён: %s" % exc)

    def begin_send(self):
        with self._idle:
            self.inflight += 1
            if self.inflight == 1:
                self._mark_busy(True)

    def end_send(self):
        with self._idle:
            self.inflight -= 1
            if self.inflight <= 0:
                self.inflight = 0
                self._mark_busy(False)
                self._idle.notify_all()

    def wait_idle(self, timeout=DRAIN_MAX):
        """Дождаться, пока все начатые отдачи допишутся. True — дождались."""
        deadline = time.monotonic() + timeout
        with self._idle:
            while self.inflight > 0:
                left = deadline - time.monotonic()
                if left <= 0:
                    return False
                self._idle.wait(min(left, 0.5))
        return True

    def take(self):
        """Отметить скачивание. Возвращает (можно, исчерпано):
        «можно» — отдавать ли файл, «исчерпано» — гасить ли сервер после.

        Предел проверяется НА ВХОДЕ, а не только после прибавки. Гашение
        сервера по «исчерпано» идёт отдельным шагом и занимает время: между
        первой отдачей и закрытием сокета успевал войти второй запрос, счётчик
        становился 2, и одноразовая ссылка отдавала ключ ДВА раза
        (доказано на стенде: два HTTP 200 подряд при max_downloads=1,
        DEFECTS §4.7). Одноразовая — значит одна отдача, чего бы ни успело
        случиться с гашением.
        """
        with self._lock:
            if self.dead or self.seconds_left() <= 0:
                return False, False
            if 0 < self.max_downloads <= self.downloads:
                # Предел уже выбран: не отдаём и просим погасить ещё раз —
                # прошлое гашение могло не дойти.
                return False, True
            self.downloads += 1
            spent = 0 < self.max_downloads <= self.downloads
            return True, spent

    # ── уборка ─────────────────────────────────────────────────────────────
    def wipe(self, reason):
        """Затереть файл и снять каталог. Идемпотентна: её зовут и сторож по
        TTL, и обработчик сигнала, и ветка «скачано столько, сколько можно»."""
        # Последний рубеж: файл затираем только тогда, когда его никто уже не
        # читает. Ждём ЗДЕСЬ, а не только в _shutdown, потому что wipe зовут и
        # аварийные ветки, мимо штатного гашения.
        if not self.wait_idle():
            self.log.warn("отдача не завершилась за %.0f с — закрываем принудительно" % DRAIN_MAX)
        with self._lock:
            if self.dead:
                return
            self.dead = True
        # Перезапись нулями перед удалением. На журналируемой ФС это не
        # гарантия (копии блоков остаются), но /run — tmpfs, то есть память:
        # там перезапись действительно стирает содержимое, а стоит она
        # микросекунды на файле в несколько килобайт.
        try:
            if os.path.isfile(self.payload):
                size = os.path.getsize(self.payload)
                with open(self.payload, "r+b") as fh:
                    fh.write(b"\0" * size)
                    fh.flush()
                    os.fsync(fh.fileno())
        except OSError as exc:
            self.log.warn("файл не затёрт: %s" % exc)
        for name in ("secret", "payload", "meta.json", "ready", "pid", "state.json", "busy"):
            path = os.path.join(self.dir, name)
            try:
                if os.path.isdir(path):
                    for entry in os.listdir(path):
                        os.unlink(os.path.join(path, entry))
                    os.rmdir(path)
                elif os.path.exists(path):
                    os.unlink(path)
            except OSError as exc:
                if exc.errno != errno.ENOENT:
                    self.log.warn("не удалён %s: %s" % (name, exc))
        self.audit.write("share-expire", "id=%s reason=%s downloads=%d" % (self.id, reason, self.downloads))
        # Каталог сносим последним и уже без server.log: пока файл лога открыт
        # процессом, unlink на него безопасен, а каталог должен исчезнуть весь —
        # оставшийся пустой каталог показался бы в share_list живой раздачей.
        try:
            for entry in os.listdir(self.dir):
                try:
                    os.unlink(os.path.join(self.dir, entry))
                except OSError:
                    pass
            os.rmdir(self.dir)
        except OSError as exc:
            if exc.errno != errno.ENOENT:
                self.log.warn("каталог раздачи не снят: %s" % exc)

    def write_state(self):
        """Число скачиваний — наружу, для share_list. Пишем во временный файл
        рядом и переименовываем: читатель никогда не увидит полупустой JSON."""
        tmp = os.path.join(self.dir, ".state.tmp")
        data = {"downloads": self.downloads, "updated": utc_now()}
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(data, fh)
            os.replace(tmp, os.path.join(self.dir, "state.json"))
        except OSError as exc:
            self.log.warn("состояние не записано: %s" % exc)


def build_handler(share, failures, log, audit, stopper):
    class ShareHandler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        timeout = READ_TIMEOUT

        def version_string(self):
            return "nginx"          # заголовок Server как у сайта-маскировки

        # Весь вывод http.server проходит через mask_path (см. Log.write)
        def log_request(self, code="-", size="-"):
            log.info("%s -> %s" % (self.command, code))

        def log_error(self, fmt, *args):
            log.info("http: " + (fmt % args))

        def log_message(self, fmt, *args):
            log.info("http: " + (fmt % args))

        def client_ip(self):
            try:
                return self.client_address[0]
            except (AttributeError, IndexError):
                return "-"

        def _send(self, status, body, content_type, extra=None, close=True, length=None, plain=False):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            # length задают отдельно только для HEAD: тела нет, а размер файла
            # клиенту сообщить надо — по нему менеджер закачек рисует прогресс.
            self.send_header("Content-Length", str(len(body) if length is None else length))
            if not plain:
                # Конфиг не должен осесть ни в кеше браузера, ни в кеше прокси
                self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, private")
                self.send_header("Pragma", "no-cache")
                self.send_header("X-Content-Type-Options", "nosniff")
                self.send_header("Referrer-Policy", "no-referrer")
            for key, value in (extra or []):
                self.send_header(key, value)
            if close:
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            if self.command != "HEAD" and body:
                try:
                    self.wfile.write(body)
                except (OSError, ValueError) as exc:
                    log.warn("ответ не дописан: %s" % exc)

        def send_404(self):
            # Истёкшая, снятая, чужая ссылка и бан — «404», как у любого сайта (решение владельца В1, 26.09.2026):
            # тело nginx байт в байт и заголовки 404 nginx по умолчанию — Server, Date, Content-Type,
            # Content-Length, Connection. Защитные no-store/nosniff/Referrer-Policy — только у ответа с файлом:
            # на 404 их нет и у nginx, и по ним сканер отличил бы порт раздачи от обычного сайта (как SEC-G4
            # у страниц подключения).
            self._send(404, NGINX_404, "text/html", plain=True)

        def _fail(self, why):
            ip = self.client_ip()
            if failures.record(ip):
                log.warn("IP %s забанен на %.0f с после %d неудач (последняя: %s)"
                         % (ip, BAN_SECONDS, BAN_FAILURES, why))
            else:
                log.info("отказ %s для %s" % (why, ip))
            self.send_404()

        def _match(self):
            # Длинный путь даже не разбираем: наш — около 90 символов, всё
            # остальное либо мусор сканера, либо попытка нагрузить регулярку.
            if len(self.path) > MAX_REQUEST_LINE:
                return None
            return PATH_RE.match(self.path.split("?", 1)[0])

        def do_GET(self):
            ip = self.client_ip()
            # Бан проверяем ПЕРВЫМ: забаненный не должен получить даже 405,
            # по которому видно, что путь угадан.
            if failures.banned(ip):
                self.send_404()
                return
            match = self._match()
            if match is None:
                self._fail("path")
                return
            if not share.match(match.group(1), match.group(2)):
                self._fail("secret")
                return
            if share.seconds_left() <= 0:
                # Срок вышел между проверкой сторожа и этим запросом
                self.send_404()
                stopper("expired")
                return
            # Выключенному — 404 без счёта скачивания и без неудачи в бан: адрес верный, включат — заработает (A4-2)
            if share.user_off():
                log.info("раздача %s: пользователь выключен — файл не отдан" % share.id)
                self.send_404()
                return
            allowed, spent = share.take()
            if not allowed:
                self.send_404()
                # Предел выбран, а сервер ещё жив: повторяем гашение — прошлое
                # могло не дойти. Иначе ссылка остаётся висеть открытой.
                if spent:
                    stopper("spent")
                return
            # Начатую отдачу гашение сервера и уборка снаружи обязаны дождаться:
            # между этой строкой и концом _send файл ещё едет клиенту.
            share.begin_send()
            try:
                try:
                    with open(share.payload, "rb") as fh:
                        body = fh.read()
                except OSError as exc:
                    log.error("файл не прочитан: %s" % exc)
                    self.send_404()
                    return
                # filename в кавычках: имя состоит из [A-Za-z0-9._-], кавычек в нём
                # быть не может, но заголовок без кавычек ломается на первой точке
                # у части клиентов.
                disp = 'attachment; filename="%s"' % share.file_name
                self._send(200, body, "application/octet-stream", extra=[("Content-Disposition", disp)])
            finally:
                share.end_send()
            share.write_state()
            audit.write("share-download", "id=%s ip=%s bytes=%d n=%d"
                        % (share.id, ip, len(body), share.downloads))
            log.info("выдан файл раздачи %s (%d байт, скачиваний: %d)" % (share.id, len(body), share.downloads))
            if spent:
                log.info("лимит скачиваний исчерпан — раздача закрывается")
                stopper("spent")

        def do_HEAD(self):
            # HEAD браузеры и менеджеры закачек шлют перед GET. Отвечаем как на
            # GET, но НЕ считаем скачиванием: иначе одноразовая ссылка сгорала бы
            # до того, как файл поехал.
            ip = self.client_ip()
            if failures.banned(ip):
                self.send_404()
                return
            match = self._match()
            if match is None or not share.match(match.group(1), match.group(2)) or share.seconds_left() <= 0:
                self._fail("path")
                return
            if share.user_off():
                self.send_404()
                return
            try:
                size = os.path.getsize(share.payload)
            except OSError:
                self.send_404()
                return
            disp = 'attachment; filename="%s"' % share.file_name
            self._send(200, b"", "application/octet-stream",
                       extra=[("Content-Disposition", disp)], length=size)

        def _other(self):
            # POST/PUT/DELETE по верному адресу — 405 (клиент ошибся методом),
            # по чужому — 404 с записью неудачи, как у любого чужого пути.
            if failures.banned(self.client_ip()):
                self.send_404()
                return
            match = self._match()
            if match is not None and share.match(match.group(1), match.group(2)):
                self._send(405, b"", "application/octet-stream", extra=[("Allow", "GET, HEAD")])
                return
            self._fail("method")

        do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = _other

    return ShareHandler


class ShareHttpServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 32

    def __init__(self, address, handler, log):
        self._log = log
        if ":" in address[0]:
            self.address_family = socket.AF_INET6
        http.server.HTTPServer.__init__(self, address, handler)

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
        # Оборванное TLS-рукопожатие сканера — обычное дело на публичном порту,
        # traceback на каждый такой коннект только засорил бы лог.
        exc = sys.exc_info()[1]
        self._log.info("соединение с %s: %s" % (client_address[0], exc))


def make_tls_context(cert_path, key_path):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(cert_path, key_path)
    return ctx


def parse_args(argv):
    opts = {"dir": "", "bind": "0.0.0.0", "port": 0, "audit": os.environ.get("GOAMNEZIA_AUDIT_LOG", ""), "users": ""}
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("--dir", "--bind", "--port", "--audit", "--users"):
            if i + 1 >= len(argv):
                raise ValueError("нет значения для %s" % arg)
            opts[arg[2:]] = argv[i + 1]
            i += 2
            continue
        raise ValueError("неизвестный аргумент: %s" % arg)
    if not opts["dir"]:
        raise ValueError("не задан --dir")
    opts["port"] = int(opts["port"])
    return opts


def main(argv):
    log = Log(sys.stderr)
    try:
        opts = parse_args(argv)
    except ValueError as exc:
        log.error(str(exc))
        return 2

    audit = Audit(opts["audit"], log)
    try:
        share = Share(opts["dir"], log, audit, opts["users"])
    except (OSError, ValueError) as exc:
        log.error("каталог раздачи не прочитан: %s" % exc)
        return 2
    problems = share.valid()
    if problems:
        log.error("каталог раздачи неполон: %s" % ", ".join(problems))
        return 2
    if share.seconds_left() <= 0:
        log.error("срок раздачи уже вышел")
        share.wipe("stale")
        return 2

    port = opts["port"] or int(share.meta.get("port") or 0)
    bind = opts["bind"] or str(share.meta.get("bind") or "0.0.0.0")
    cert, key = share.meta.get("cert"), share.meta.get("key")
    if not port or not cert or not key:
        log.error("в meta.json нет порта или сертификата")
        return 2

    # Своя сессия: раздача обязана пережить выход из SSH-меню, а меню — это
    # управляющий терминал, при закрытии которого группе процессов приходит
    # SIGHUP. setsid(2) уводит нас из этой группы. Делаем это сами, а не через
    # утилиту setsid: на macOS-стенде её попросту нет.
    try:
        os.setsid()
    except OSError:
        pass

    # Закрываем ВСЁ, что унаследовали и чего не открывали сами.
    #
    # Раздача создаётся под общим замком продукта, и этот процесс наследовал
    # открытый описатель файла замка. flock держится, пока жив хоть один
    # описатель, а процесс живёт пять минут — то есть после КАЖДОЙ выданной
    # ссылки весь продукт на пять минут отвечал «другое действие уже
    # выполняется»: и боту, и панели, и агенту, и меню. Воспроизведено на
    # стенде: lsof показывал этот python3 с описателем на config.lock, а
    # share-revoke-all и agent-add подряд давали lock_timeout.
    #
    # Закрывать здесь, а не в bash при запуске: перенаправления из переменной
    # bash не разбирает, а номер описателя замка динамический. Свои 0, 1 и 2 к
    # этому моменту уже перенаправлены вызывающим, их не трогаем.
    try:
        os.closerange(3, 256)
    except OSError:
        pass

    failures = FailureTracker()
    stop_reason = {"why": "ttl"}
    stopping = threading.Event()

    def stopper(why):
        """Погасить сервер. Зовётся из сторожа TTL, из обработчика запроса
        (лимит скачиваний) и из обработчика сигнала. Реальное выключение — в
        отдельном потоке: shutdown() из обработчика запроса заклинил бы сам
        себя, он ждёт завершения цикла обслуживания."""
        if stopping.is_set():
            return
        stop_reason["why"] = why
        stopping.set()
        threading.Thread(target=_shutdown, daemon=True).start()

    httpd = None

    def _shutdown():
        time.sleep(STOP_GRACE)      # дать дописать ответ, ради которого гасимся
        # …и дождаться отдач, которые идут прямо сейчас. serve_forever ниже
        # выходит в finally на share.wipe(), а тот затирает файл нулями —
        # выйти отсюда с недокачанным клиентом значит отдать ему обрезок.
        if not share.wait_idle():
            log.warn("гасимся, не дождавшись конца отдачи (%.0f с)" % DRAIN_MAX)
        if httpd is not None:
            httpd.shutdown()

    try:
        handler = build_handler(share, failures, log, audit, stopper)
        httpd = ShareHttpServer((bind, port), handler, log)
        httpd.socket = make_tls_context(cert, key).wrap_socket(httpd.socket, server_side=True,
                                                               do_handshake_on_connect=False)
    except (OSError, ssl.SSLError, ValueError) as exc:
        log.error("слушатель не поднят: %s" % exc)
        share.wipe("start_failed")
        return 1

    def watchdog():
        """Сторож TTL. Спим короткими шагами, а не одним sleep до дедлайна:
        так процесс не проспит смену системного времени и быстро отзывается на
        отзыв раздачи (каталог снят снаружи — гасимся)."""
        while not stopping.is_set():
            left = share.seconds_left()
            if left <= 0:
                # Срок вышел — новых скачиваний take() уже не пропускает. Но
                # начатое дорезаем: оборванная закачка выглядит как битый ключ,
                # а не как «ссылка отжила своё».
                if share.inflight > 0 and -left < DRAIN_MAX:
                    time.sleep(0.2)
                    continue
                stopper("ttl")
                return
            if not os.path.isdir(share.dir) or not os.path.exists(os.path.join(share.dir, "secret")):
                # Отзыв — дело человека, и он ждать не обязан: секрет должен
                # умереть немедленно. Здесь пауза была бы вредной.
                stopper("revoked")
                return
            time.sleep(min(1.0, max(0.05, left)))

    def on_signal(signum, _frame):
        stopper("signal-%d" % signum)

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        try:
            signal.signal(sig, on_signal)
        except (ValueError, OSError):
            pass

    threading.Thread(target=watchdog, daemon=True).start()

    # Маркер готовности: lib/share.sh ждёт его появления, а не «просто спит».
    # Пока маркера нет, ссылку показывать нельзя — человек ткнул бы в неё
    # раньше, чем встал слушатель, и получил бы отказ соединения.
    try:
        with open(os.path.join(share.dir, "pid"), "w", encoding="utf-8") as fh:
            fh.write("%d\n" % os.getpid())
        os.chmod(os.path.join(share.dir, "pid"), 0o600)
        with open(os.path.join(share.dir, "ready"), "w", encoding="utf-8") as fh:
            fh.write("%d\n" % port)
        os.chmod(os.path.join(share.dir, "ready"), 0o600)
    except OSError as exc:
        log.error("маркер готовности не записан: %s" % exc)
        share.wipe("start_failed")
        return 1

    log.info("раздача %s поднята на %s:%d, срок %.0f с" % (share.id, bind, port, share.seconds_left()))
    try:
        httpd.serve_forever(poll_interval=0.2)
    except Exception as exc:                       # noqa: BLE001 — падать молча нельзя
        log.error("цикл обслуживания прерван: %s" % exc)
    finally:
        try:
            httpd.server_close()
        except OSError:
            pass
        share.wipe(stop_reason["why"])
    log.info("раздача %s закрыта (%s)" % (share.id, stop_reason["why"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
