#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""goamnezia-connect — переходник между клиентом MCP и доступом goAmnezia pro.

Клиент MCP (Claude Desktop, Cursor и прочие) говорит по stdio. Сервер goAmnezia —
по HTTPS с одноразовым ключом, который меняется на каждом запросе
(docs/MCP_ROTATION.md §1). Обычный клиент менять заголовок между запросами не
умеет, поэтому до переходника доступ rolling подключался только клиентом,
написанным под него. Переходник делает это за клиента:

  * привязка одноразовым кодом: в конфигурации клиента секрета нет вовсе (§7);
  * плавающий путь /r-<HMAC(rot_seed, отрезок)>/mcp, отрезок 60 секунд (§2);
  * сверка времени по заголовку Date: нужно не правильное время, а одинаковое
    с сервером (§3);
  * ключ цепочки хранится в TPM, если он есть, иначе файлом 0600, и какой
    вариант выбран, видно в списке доступов (§4);
  * исключительный замок: один доступ — один клиент (§11.2);
  * промах мимо отрезка лечится сам: пересчёт по Date из того же ответа и
    один повтор той же попытки.

Запуск в конфигурации клиента MCP:
    {"command": "goamnezia-connect", "args": ["--grant", "a-b285"]}

Привязка (код печатает agent-add --mode=connect на сервере):
    goamnezia-connect enroll GA-XXXXX-XXXXX-XXXXX-XXXXX --server https://example.com

Только стандартная библиотека Python 3.8+. macOS и Linux.
"""

import argparse
import base64
import datetime
import email.utils
import errno
import hashlib
import hmac
import http.client
import ipaddress
import json
import os
import re
import secrets
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

try:
    import fcntl
except ImportError:  # pragma: no cover — Windows
    fcntl = None

VERSION = "1"
USER_AGENT = "goamnezia-connect/" + VERSION
SLOT_SECONDS = 60
# Сверка по Date делается из каждого ответа сама; отдельный запрос «который час»
# нужен только на холодном старте и после долгой тишины: монотонные часы на macOS
# стоят, пока ноутбук спит, и после сна счёт отрезков отстаёт.
RESYNC_AFTER = 600
# Дольше, чем ждут сервер и nginx (мост до 300 с, proxy_read_timeout 310 с): переходник,
# сдавшийся раньше, бросал запрос, который сервер ещё выполнял и после которого повернул
# цепочку, — и следующий вызов приходил прежним ключом.
TIMEOUT = 330
# Соединение и рукопожатие TLS ждём коротко: сервер, недоступный молча (блокировка, сломанный
# IPv6), держал бы клиента по 330 с на каждой попытке, а запросы копились бы в очереди.
CONNECT_TIMEOUT = 15
# Сервер не ответил на соединение — следующие попытки в ближайшие 30 с не ждут его снова: иначе
# после перезапуска клиента сверка часов, восстановление и первый вызов ждали бы по 15 с каждый,
# и ответ на initialize опаздывал за общий таймаут клиента.
DOWN_BACKOFF = 30
# Повтор оборванной попытки, упёршийся в закрытый порт (служба перезапускается), — ещё один раз
# через пару секунд: иначе модель получала «исход неизвестен» ровно тогда, когда ответ вот-вот вернётся.
REPLAY_RETRY_DELAY = 2

GRANT_RE = re.compile(r"^a-[0-9a-f]{4,8}$")
SECRET_RE = re.compile(r"^[A-Za-z0-9_-]{43}$")
KEY_HEADER = "X-Ga-Key"
NONCE_HEADER = "X-Ga-Nonce"
NEXT_KEY_HEADER = "x-ga-next-key"

# Уведомление без последствий — тело для восстановления оборванной попытки: сервер
# либо повторит сохранённый ответ (запрос до него дошёл), либо примет это как
# обычную первую попытку и ничего не сделает.
RECOVERY_BODY = b'{"jsonrpc":"2.0","method":"notifications/initialized"}'

# Нынешний Google Drive на macOS живёт в ~/Library/CloudStorage/GoogleDrive-<аккаунт>/…, там же
# OneDrive и Dropbox нового образца — поэтому метка CloudStorage, а путь сверяется после realpath.
SYNCED_DIR_MARKS = ("Mobile Documents", "iCloud", "Dropbox", "OneDrive", "Google Drive", "GoogleDrive",
                    "CloudStorage", "Yandex.Disk")


# ── Сообщения ───────────────────────────────────────────────────────────────
def _ru():
    for var in ("GOAMNEZIA_CONNECT_LANG", "LC_ALL", "LC_MESSAGES", "LANG"):
        v = os.environ.get(var, "")
        if v:
            return v.lower().startswith("ru")
    return False


MSG = {
    "busy": ("Этот доступ уже занят другим клиентом MCP. Один доступ — один клиент: выдайте отдельный "
             "доступ (agent-add --mode=connect) для второй программы.",
             "This grant is already in use by another MCP client. One grant, one client: issue a separate "
             "grant (agent-add --mode=connect) for the second program."),
    "no_cfg": ("Доступ %s не привязан на этой машине: нет файла %s. Сначала: goamnezia-connect enroll <код> "
               "--server <адрес>.",
               "Grant %s is not enrolled on this machine: no file %s. First run: goamnezia-connect enroll "
               "<code> --server <address>."),
    "enroll_refused": ("Код не принят: неверный, уже использован или истёк (он живёт 10 минут). Выдайте новый "
                       "на сервере: agent-add --mode=connect.",
                       "The code was refused: wrong, already used or expired (it lives 10 minutes). Issue a new "
                       "one on the server: agent-add --mode=connect."),
    "enroll_bad_reply": ("Сервер ответил на привязку, но ответ не похож на доступ: %s",
                         "The server answered the enrollment, but the reply does not look like a grant: %s"),
    "enrolled": ("Привязано: доступ %s (%s, уровень %s). Ключ хранится: %s.\n"
                 "В конфигурацию клиента MCP впишите (путь полный: клиент с окнами не видит PATH оболочки):\n"
                 "  %s",
                 "Enrolled: grant %s (%s, scope %s). Key storage: %s.\n"
                 "Put this into the MCP client configuration (full path: a windowed client does not see the shell PATH):\n"
                 "  %s"),
    "storage_file_note": ("Ключ лежит файлом: TPM на этой машине не нашлось. Копия файла на чужой машине "
                          "будет обнаружена со второго запроса, но не предотвращена.",
                          "The key is kept as a file: no TPM on this machine. A copy of the file on a foreign "
                          "machine will be detected by the second request, but not prevented."),
    "synced_dir": ("Каталог %s похож на синхронизируемую папку. Облако размножит ключ на вторую машину, и "
                   "сервер примет это за кражу. Укажите другой каталог (--dir).",
                   "Directory %s looks like a synced folder. The cloud would copy the key to another machine and "
                   "the server would take it for theft. Choose another directory (--dir)."),
    "unreachable": ("Сервер goAmnezia недоступен: %s", "The goAmnezia server is unreachable: %s"),
    "refused": ("Сервер не принял запрос (404): доступ отозван, заморожен, истёк или ключ сбился. Посмотрите "
                "карточку доступа на сервере.",
                "The server refused the request (404): the grant is revoked, frozen, expired or the key went "
                "out of sync. Check the grant card on the server."),
    "rate": ("Слишком часто: сервер просит подождать %s с.", "Too often: the server asks to wait %s s."),
    "http": ("Сервер ответил HTTP %s.", "The server answered HTTP %s."),
    "fingerprint": ("Отпечаток сертификата сервера не совпал: ждали %s, пришёл %s. Соединение прервано.",
                    "The server certificate fingerprint did not match: expected %s, got %s. Connection dropped."),
    "no_fcntl": ("Эта система не поддерживает замок на файл: переходник работает на macOS и Linux.",
                 "This system does not support file locking: the connector works on macOS and Linux."),
    "bad_json": ("Клиент прислал не JSON.", "The client sent something that is not JSON."),
    "tpm_failed": ("TPM не сохранил ключ: %s", "TPM did not store the key: %s"),
    "store_unreadable": ("Хранилище ключа доступа %s не читается (%s). Переходник остановлен, чтобы не "
                         "затереть ключ: проверьте файл и права; если ключ потерян — перевыпустите доступ.",
                         "The key storage of grant %s cannot be read (%s). The connector stopped so as not to "
                         "overwrite the key: check the file and its permissions; if the key is lost, reissue the grant."),
    "no_key": ("У доступа %s нет ключа на этой машине. Привяжите его заново: goamnezia-connect enroll <код> "
               "--server <адрес>.",
               "Grant %s has no key on this machine. Enroll it again: goamnezia-connect enroll <code> "
               "--server <address>."),
    "recovery_pending": ("Прошлый запрос оборвался, и сервер ещё не подтвердил, выполнен ли он. Повторите чуть "
                         "позже: переходник сначала заберёт ответ на тот запрос, иначе сервер принял бы новый "
                         "за копию доступа.",
                         "The previous request broke off and the server has not yet confirmed whether it ran. "
                         "Retry a little later: the connector first collects the answer to that request, "
                         "otherwise the server would take the new one for a copy of the grant."),
    "outcome_unknown": ("Ответ сервера потерялся (%s), и забрать его повтором не удалось: запрос мог "
                        "выполниться. Проверьте состояние, прежде чем повторять действие.",
                        "The server's answer was lost (%s) and could not be collected by a replay: the request "
                        "may have run. Check the state before repeating the action."),
    "outcome_lost": ("Ответ сервера потерялся, а сохранённого ответа у сервера нет (скорее всего, служба "
                     "перезапускалась посреди запроса): действие могло выполниться, а могло и нет. Проверьте "
                     "состояние, прежде чем повторять.",
                     "The server's answer was lost and the server kept no copy (most likely the service restarted "
                     "mid-request): the action may or may not have run. Check the state before repeating it."),
    "store_write_failed": ("Ключ доступа %s не записался (%s). Переходник остановлен, чтобы не разойтись с "
                           "сервером: освободите место или поправьте права и запустите его снова.",
                           "The key of grant %s was not written (%s). The connector stopped so as not to drift "
                           "from the server: free some space or fix permissions and start it again."),
    "enroll_store_failed": ("Привязка прошла, но ключ не записался (%s). Код уже использован: освободите место "
                            "или поправьте права, перевыпустите доступ и привяжите его заново.",
                            "Enrollment succeeded but the key was not written (%s). The code is already used: free "
                            "some space or fix permissions, reissue the grant and enroll again."),
    "staged": ("Привязано: доступ %s (%s, уровень %s). Его прежний переходник ещё работает — закройте клиент "
               "MCP: новая привязка включится при следующем запуске. Строка для клиента MCP:\n  %s",
               "Enrolled: grant %s (%s, scope %s). Its previous connector is still running — close the MCP "
               "client: the new enrollment takes effect on the next start. The line for the MCP client:\n  %s"),
    "bad_server": ("Адрес сервера не подходит (%s). Нужен https://домен[:порт]; обычный http — только до "
                   "127.0.0.1 через туннель, иначе токен и ключ шли бы по сети открытым текстом.",
                   "Unusable server address (%s). Use https://domain[:port]; plain http only to 127.0.0.1 "
                   "through a tunnel, otherwise the token and the key would travel in clear text."),
}


def say(key, *args):
    text = MSG[key][0 if _ru() else 1]
    return text % args if args else text


def log(text):
    sys.stderr.write("goamnezia-connect: %s\n" % text)
    sys.stderr.flush()


# ── Кодировки и вычисления, общие с сервером ────────────────────────────────
def b64url(raw):
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def b64url_decode(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def normalize_code(code):
    """Код привязки без пробелов и дефисов, заглавными: человек набирает его как угодно."""
    return re.sub(r"[\s-]", "", code or "").upper()


def enroll_path(code):
    """Путь привязки. Сам код по сети не едет: на сервер уходит его отпечаток."""
    return b64url(hashlib.sha256(b"goamnezia-enroll|" + normalize_code(code).encode("utf-8")).digest())[:43]


def float_path(rot_seed, slot):
    """Плавающий путь отрезка: HMAC-SHA256(rot_seed, "path|<отрезок>") в base64url, 43 знака."""
    digest = hmac.new(b64url_decode(rot_seed), ("path|%d" % slot).encode("ascii"), hashlib.sha256).digest()
    return b64url(digest)[:43]


# ── Часы: следуем за сервером ────────────────────────────────────────────────
class Clock(object):
    """Время сервера по заголовку Date и монотонному счётчику.

    Между сверками счёт идёт по монотонным часам: перевод системных часов и
    поправка NTP смещение не портят. Date округлён до секунды вниз — прибавляем
    полсекунды, чтобы в среднем попадать в середину.
    """

    def __init__(self, wall=time.time, mono=time.monotonic):
        self.wall = wall
        self.mono = mono
        self.server_at_sync = None
        self.mono_at_sync = None

    def synced(self):
        return self.server_at_sync is not None

    def age(self):
        return None if self.mono_at_sync is None else self.mono() - self.mono_at_sync

    def observe(self, date_header):
        if not date_header:
            return False
        try:
            dt = email.utils.parsedate_to_datetime(date_header)
        except (TypeError, ValueError, IndexError):
            return False
        if dt is None:
            return False
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        self.server_at_sync = dt.timestamp() + 0.5
        self.mono_at_sync = self.mono()
        return True

    def server_now(self):
        if not self.synced():
            return self.wall()
        return self.server_at_sync + (self.mono() - self.mono_at_sync)

    def slot(self):
        return int(self.server_now() // SLOT_SECONDS)


# ── Хранилища ключа ─────────────────────────────────────────────────────────
def _atomic_write(path, data, mode=0o600):
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=directory)
    try:
        os.fchmod(fd, mode)
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, path)
    try:
        dfd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except OSError:
        pass


class StoreError(Exception):
    """Хранилище есть, но не читается. Не путать с «ключа нет»: пустое состояние, записанное
    поверх нечитаемого, стёрло бы настоящий ключ навсегда."""


class ConnectorError(Exception):
    """Отказ самого переходника с текстом для человека (вместо ответа сервера)."""


class NotSent(OSError):
    """Соединение не установилось: запрос до сервера не дошёл, исход известен. fast — отказ пришёл
    сразу (порт закрыт, служба перезапускается): ждать его снова дёшево, и пауза ему не нужна."""

    def __init__(self, message="", fast=False):
        OSError.__init__(self, message)
        self.fast = fast


class StoreAfterReply(StoreError):
    """Сервер ответил, а новый ключ не записался: ответ всё равно надо отдать клиенту — действие
    уже выполнено, и модель, не получившая ответа, повторила бы его."""

    def __init__(self, cause, reply):
        StoreError.__init__(self, str(cause))
        self.reply = reply


class FileStore(object):
    """Ключ файлом 0600. Запись атомарная и с fsync ДО следующего запроса (§1.2)."""

    kind = "file"

    def __init__(self, path):
        self.path = path

    def load(self):
        try:
            with open(self.path, "rb") as fh:
                raw = fh.read()
        except FileNotFoundError:
            return None
        except OSError as exc:
            raise StoreError(str(exc))
        try:
            data = json.loads(raw.decode("utf-8"))
        except ValueError as exc:
            raise StoreError("json: %s" % exc)
        if not isinstance(data, dict):
            raise StoreError("not an object")
        return data

    def save(self, data):
        try:
            _atomic_write(self.path, json.dumps(data, sort_keys=True).encode("utf-8"))
        except OSError as exc:
            raise StoreError(str(exc))


class TpmStore(object):
    """Ключ, запечатанный в TPM через systemd-creds: копия файла на чужой машине не
    расшифровывается. Открытый текст идёт в systemd-creds через stdin, а не аргументом:
    аргументы процесса видит любой локальный пользователь.
    """

    kind = "tpm"

    def __init__(self, path, name):
        self.path = path
        self.name = name

    @staticmethod
    def available():
        tool = shutil.which("systemd-creds")
        if not tool:
            return False
        try:
            if subprocess.run([tool, "has-tpm2"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=15).returncode != 0:
                return False
        except (OSError, subprocess.SubprocessError):
            return False
        # Проба туда и обратно: has-tpm2 говорит о железе, а не о том, пустит ли
        # systemd-creds этого пользователя к ключу.
        directory = tempfile.mkdtemp(prefix="ga-connect-tpm-")
        try:
            probe = TpmStore(os.path.join(directory, "probe.cred"), "goamnezia-probe")
            probe.save({"probe": True})
            return probe.load() == {"probe": True}
        except (OSError, RuntimeError, subprocess.SubprocessError, StoreError):
            return False
        finally:
            shutil.rmtree(directory, ignore_errors=True)

    def load(self):
        if not os.path.exists(self.path):
            return None
        try:
            done = subprocess.run(["systemd-creds", "decrypt", "--name=" + self.name, self.path, "-"],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        except (OSError, subprocess.SubprocessError) as exc:
            raise StoreError(str(exc))
        if done.returncode != 0:
            raise StoreError(done.stderr.decode("utf-8", "replace").strip()[:200] or "systemd-creds decrypt")
        try:
            data = json.loads(done.stdout.decode("utf-8"))
        except ValueError as exc:
            raise StoreError("json: %s" % exc)
        if not isinstance(data, dict):
            raise StoreError("not an object")
        return data

    def save(self, data):
        directory = os.path.dirname(self.path) or "."
        tmp = os.path.join(directory, ".tmp-%d.cred" % os.getpid())
        try:
            done = subprocess.run(["systemd-creds", "encrypt", "--with-key=tpm2", "--name=" + self.name, "-", tmp],
                                  input=json.dumps(data, sort_keys=True).encode("utf-8"),
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        except (OSError, subprocess.SubprocessError) as exc:
            raise StoreError(say("tpm_failed", exc))
        if done.returncode != 0:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise StoreError(say("tpm_failed", done.stderr.decode("utf-8", "replace").strip()[:200]))
        try:
            os.chmod(tmp, 0o600)
            os.replace(tmp, self.path)
        except OSError as exc:
            raise StoreError(str(exc))


def make_store(kind, directory, grant, suffix=""):
    if kind == "tpm":
        return TpmStore(os.path.join(directory, grant + ".cred" + suffix), "goamnezia-" + grant)
    return FileStore(os.path.join(directory, grant + ".key" + suffix))


# ── Замок: один доступ — один клиент ────────────────────────────────────────
class Busy(Exception):
    pass


def acquire_lock(path):
    if fcntl is None:
        raise OSError(say("no_fcntl"))
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        os.close(fd)
        if exc.errno in (errno.EAGAIN, errno.EACCES, errno.EWOULDBLOCK):
            raise Busy()
        raise
    return fd


# ── HTTP ─────────────────────────────────────────────────────────────────────
class FingerprintMismatch(Exception):
    pass


def _is_loopback(host):
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


class Http(object):
    """Один запрос — одно соединение. Самоподписанный сертификат сервера проверяется
    по отпечатку SHA-256 из карточки доступа, остальные — обычной цепочкой доверия."""

    def __init__(self, base_url, fingerprint="", timeout=TIMEOUT):
        parts = urlsplit(base_url)
        if parts.scheme not in ("http", "https") or not parts.hostname:
            raise ValueError("server must be http(s)://host[:port]")
        self.scheme = parts.scheme
        self.host = parts.hostname
        self.port = parts.port or (443 if parts.scheme == "https" else 80)
        # Обычный http — только до петли (туннель ssh -L): иначе токен, ключ и ответ на
        # привязку с зерном пути шли бы по сети открытым текстом.
        if self.scheme == "http" and not _is_loopback(self.host):
            raise ValueError("plain http only to a loopback address")
        self.prefix = parts.path.rstrip("/")
        self.fingerprint = (fingerprint or "").replace(":", "").strip().lower()
        self.timeout = timeout

    def _connection(self):
        if self.scheme == "http":
            return http.client.HTTPConnection(self.host, self.port, timeout=CONNECT_TIMEOUT)
        if self.fingerprint:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        else:
            ctx = ssl.create_default_context()
        return http.client.HTTPSConnection(self.host, self.port, timeout=CONNECT_TIMEOUT, context=ctx)

    def request(self, method, path, body=None, headers=None, read_timeout=None):
        conn = self._connection()
        try:
            try:
                conn.connect()
            except OSError as exc:
                raise NotSent(str(exc), fast=isinstance(exc, ConnectionRefusedError))
            # Ответ ждём долго: мост выполняет действие до 300 с, nginx держит 310 с.
            conn.sock.settimeout(read_timeout or self.timeout)
            if self.scheme == "https" and self.fingerprint:
                der = conn.sock.getpeercert(binary_form=True) or b""
                got = hashlib.sha256(der).hexdigest()
                if not hmac.compare_digest(got, self.fingerprint):
                    raise FingerprintMismatch(say("fingerprint", self.fingerprint, got))
            conn.request(method, self.prefix + path, body=body, headers=headers or {})
            resp = conn.getresponse()
            data = resp.read()
            return resp.status, {k.lower(): v for k, v in resp.getheaders()}, data
        finally:
            conn.close()


# ── Переходник ───────────────────────────────────────────────────────────────
class Connector(object):
    def __init__(self, cfg, store, http_client, clock=None):
        self.cfg = cfg
        self.store = store
        self.http = http_client
        self.clock = clock or Clock()
        self.state = store.load() or {}
        self.protocol_version = ""
        self._down_until = 0.0
        self._down_reason = ""

    def _mark_down(self, exc):
        if getattr(exc, "fast", False):
            return      # закрытый порт отвечает сразу — повторять дёшево, паузы не нужно
        self._down_until = time.monotonic() + DOWN_BACKOFF
        self._down_reason = str(exc)

    def _save(self, key, pending):
        if not key:
            raise StoreError("empty key")      # пустой ключ поверх настоящего — потеря доступа
        new = {"key": key, "pending_nonce": pending}
        # Сперва на диск, потом в память: при сбое записи память не должна обгонять хранилище,
        # иначе после перезапуска на диске окажется ключ, уже ушедший в историю, — «копия».
        self.store.save(new)
        self.state = new

    @staticmethod
    def _next_key(headers):
        nxt = (headers.get(NEXT_KEY_HEADER) or "").strip()
        return nxt if SECRET_RE.match(nxt) else ""

    def _ensure_clock(self):
        age = self.clock.age()
        if self.clock.synced() and age is not None and age < RESYNC_AFTER:
            return
        if time.monotonic() < self._down_until:
            return      # сервер только что не отвечал — вторую сверку подряд не ждём
        try:
            _st, headers, _data = self.http.request("GET", "/", headers={"User-Agent": USER_AGENT},
                                                    read_timeout=CONNECT_TIMEOUT)
            self.clock.observe(headers.get("date"))
        except NotSent as exc:
            self._mark_down(exc)
        except (OSError, http.client.HTTPException, ssl.SSLError, FingerprintMismatch):
            pass   # сверимся по первому рабочему ответу; чужой сертификат назовёт сам запрос

    def _path(self):
        return "/r-%s/mcp" % float_path(self.cfg["rot_seed"], self.clock.slot())

    def _post(self, body, key, nonce):
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "User-Agent": USER_AGENT,
            "Authorization": "Bearer " + self.cfg["token"],
            KEY_HEADER: key,
            NONCE_HEADER: nonce,
        }
        if self.protocol_version:
            headers["MCP-Protocol-Version"] = self.protocol_version
        path = self._path()
        status, resp_headers, data = self.http.request("POST", path, body=body, headers=headers)
        self.clock.observe(resp_headers.get("date"))
        return status, resp_headers, data, path

    def _attempt(self, body, key, nonce, allow_down=False):
        """Одна попытка с самолечением промаха мимо отрезка."""
        if not allow_down and time.monotonic() < self._down_until:
            raise NotSent(self._down_reason)
        try:
            status, headers, data, path = self._post(body, key, nonce)
            if status == 404 and self._path() != path:
                # Часы только что сверены по Date из этого же отказа, и отрезок другой.
                # Повтор — тот же ключ и тот же номер: путь сервер проверяет раньше ключа
                # (§11.5), поэтому промах мимо пути цепочку не тронул.
                status, headers, data, path = self._post(body, key, nonce)
        except NotSent as exc:
            self._mark_down(exc)
            raise
        return status, headers, data

    def _finish(self, status, headers, key):
        nxt = self._next_key(headers)
        if nxt:
            # Сервер выдал следующий ключ — цепочка сдвинулась, каким бы ни был статус: на
            # корректный JSON без method сервер отвечает 400, но запрос учтён и ключ повёрнут.
            # Остаться на прежнем — прийти следующим запросом «копией» и заморозить доступ.
            self._save(nxt, "")
        elif 200 <= status < 500:
            # Ответ без нового ключа: отказ (запрос не выполнен) или ответ без вращения —
            # цепочка не сдвинулась.
            self._save(key, "")
        # 5xx без ключа: исход неизвестен (сервер мог не записать состояние). Номер остаётся,
        # и следующий вызов сперва повторит ту попытку дословно.

    def recover(self, raise_errors=False):
        """Оборванная попытка: ответ с новым ключом мог не доехать. Повтор той же пары
        ключ и номер вернёт сохранённый ответ, новый ключ и не выполнит действие снова.
        → (status, headers) ответа на повтор или None."""
        pending = self.state.get("pending_nonce") or ""
        key = self.state.get("key") or ""
        if not pending or not key:
            return None
        self._ensure_clock()
        try:
            status, headers, _data = self._attempt(RECOVERY_BODY, key, pending)
        except (OSError, http.client.HTTPException, ssl.SSLError, FingerprintMismatch) as exc:
            if raise_errors:
                raise
            log(say("unreachable", exc))
            return None
        nxt = self._next_key(headers)
        if nxt:
            self._save(nxt, "")
        # Без нового ключа номер остаётся: отказ до цепочки (404 — бан, выключен, привязка к адресу;
        # 429 — предел частоты) не доказывает, что оборванная попытка не повернула цепочку, а стёртый
        # номер отправил бы следующий вызов прежним ключом — «копией» доступа.
        return status, headers

    def _refusal(self, status, headers, cause=""):
        if status == 404:
            return ConnectorError(say("refused"))
        if status == 429:
            return ConnectorError(say("rate", headers.get("retry-after") or "?"))
        return ConnectorError(say("outcome_unknown", cause or ("HTTP %s" % status)))

    def _finish_reply(self, status, headers, data, key):
        try:
            self._finish(status, headers, key)
        except StoreError as exc:
            raise StoreAfterReply(exc, (status, headers, data))

    def call(self, body, expects_reply=True):
        """→ (status, headers, data). Исключения транспорта пробрасываются."""
        self._ensure_clock()
        if self.state.get("pending_nonce"):
            # Прошлая попытка оборвалась (таймаут, обрыв связи, 502 прокси), а сервер мог её
            # выполнить и повернуть цепочку. Новый номер с прежним ключом сервер счёл бы копией
            # доступа и заморозил его: сначала забираем ответ на ту попытку тем же ключом и номером.
            got = self.recover(raise_errors=True)
            if self.state.get("pending_nonce"):
                if got is not None and got[0] in (404, 429):
                    raise self._refusal(got[0], got[1])
                raise ConnectorError(say("recovery_pending"))
        key = self.state.get("key") or ""
        if not key:
            raise ConnectorError(say("no_key", self.cfg.get("grant") or "?"))
        nonce = b64url(secrets.token_bytes(18))
        # Номер записан ДО отправки: если сервер примет запрос, а ответ не доедет,
        # следующий вызов или запуск восстановит цепочку повтором, а не придёт «копией».
        self._save(key, nonce)
        try:
            status, headers, data = self._attempt(body, key, nonce)
        except NotSent:
            # До сервера не дошло — исход известен. Номер снимаем: иначе каждый следующий запуск
            # сначала ждал бы восстановления, которому нечего восстанавливать.
            self._save(key, "")
            raise
        except FingerprintMismatch:
            raise
        except (OSError, http.client.HTTPException, ssl.SSLError) as exc:
            return self._replay_lost(key, nonce, expects_reply, str(exc))
        if status >= 500 and not self._next_key(headers):
            # 502/504 от nginx (служба перезапустилась, мост не уложился) или 500 «состояние не
            # записано»: сервер мог выполнить действие. Это тот же обрыв, что и исключение, — и
            # забирается тем же повтором, а не отдаётся модели как «HTTP 502» приглашением повторить.
            return self._replay_lost(key, nonce, expects_reply, "HTTP %s" % status)
        self._finish_reply(status, headers, data, key)
        return status, headers, data

    def _replay_lost(self, key, nonce, expects_reply, cause):
        """Ответ на попытку потерян. Повтор той же пары ключ и номер с БЕЗВРЕДНЫМ телом: выполненное и
        записанное сервер не повторит и отдаст сохранённый ответ; если действие выполнено, а цепочка
        не записана (перезапуск службы посреди запроса), выполнится только уведомление. Всё, что не
        дало нового ключа, — «исход неизвестен» с причиной: «сервер недоступен» или «слишком часто»
        модель прочла бы как приглашение повторить действие, и оно выполнилось бы второй раз."""
        status, headers, data = 0, {}, b""
        for delay in (0, REPLAY_RETRY_DELAY):
            if delay:
                time.sleep(delay)
            try:
                status, headers, data = self._attempt(RECOVERY_BODY, key, nonce, allow_down=True)
            except NotSent as exc:
                if exc.fast and not delay:
                    continue      # служба перезапускается — ещё одна попытка через пару секунд
                raise ConnectorError(say("outcome_unknown", "%s; %s" % (cause, exc)))
            except (OSError, http.client.HTTPException, ssl.SSLError, FingerprintMismatch) as exc:
                # Чужой отпечаток на повторе — тоже «исход неизвестен»: действие могло выполниться до
                # смены сертификата, а «сервер недоступен» модель прочла бы как «повтори».
                raise ConnectorError(say("outcome_unknown", "%s; %s" % (cause, exc)))
            break
        if not self._next_key(headers):
            # Отказ до цепочки или снова 5xx. Номер остаётся: следующий вызов сперва заберёт ответ.
            raise ConnectorError(say("outcome_unknown", "%s; HTTP %s" % (cause, status)))
        if expects_reply and not data.strip():
            # Сохранённого ответа нет — сервер выполнил наше уведомление: исход исходного запроса
            # неизвестен, и так и надо сказать.
            try:
                self._finish(status, headers, key)
            except StoreError as exc:
                raise StoreAfterReply(exc, (status, headers, data))
            raise ConnectorError(say("outcome_lost"))
        self._finish_reply(status, headers, data, key)
        return status, headers, data

    # ── stdio ────────────────────────────────────────────────────────────────
    @staticmethod
    def _error(msg_id, text, code=-32000):
        return json.dumps({"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": text}},
                          ensure_ascii=False)

    @staticmethod
    def _ids(message):
        items = message if isinstance(message, list) else [message]
        return [m.get("id") for m in items if isinstance(m, dict) and "id" in m]

    @staticmethod
    def _bodies(headers, data):
        text = data.decode("utf-8", "replace").strip()
        if not text:
            return []
        if "text/event-stream" in (headers.get("content-type") or ""):
            out, buf = [], []
            for line in text.splitlines():
                if line.startswith("data:"):
                    buf.append(line[5:].strip())
                elif not line.strip() and buf:
                    out.append("\n".join(buf))
                    buf = []
            if buf:
                out.append("\n".join(buf))
            return out
        return [text]

    def run(self, stdin, stdout):
        try:
            self.recover()
        except StoreError as exc:
            log(say("store_write_failed", self.cfg.get("grant") or "?", exc))
            return
        for raw in stdin:
            line = raw.strip()
            if not line:
                continue
            try:
                message = json.loads(line.decode("utf-8"))
            except ValueError:
                self._emit(stdout, self._error(None, say("bad_json"), -32700))
                continue
            ids = self._ids(message)
            try:
                status, headers, data = self.call(line, expects_reply=bool(ids))
            except ConnectorError as exc:
                for msg_id in ids:
                    self._emit(stdout, self._error(msg_id, str(exc)))
                continue
            except StoreAfterReply as exc:
                # Действие выполнено — ответ отдаём, и только потом останавливаемся. Пустой ответ на
                # запрос с id — «исход неизвестен», а не молчание до таймаута клиента.
                if ids and not (exc.reply[2] or b"").strip():
                    for msg_id in ids:
                        self._emit(stdout, self._error(msg_id, say("outcome_lost")))
                else:
                    self._deliver(stdout, message, ids, *exc.reply)
                log(say("store_write_failed", self.cfg.get("grant") or "?", exc))
                return
            except StoreError as exc:
                # Хранилище не пишется: дальше работать нельзя — память и диск разойдутся.
                text = say("store_write_failed", self.cfg.get("grant") or "?", exc)
                for msg_id in ids:
                    self._emit(stdout, self._error(msg_id, text))
                log(text)
                return
            except (OSError, http.client.HTTPException, ssl.SSLError, FingerprintMismatch) as exc:
                for msg_id in ids:
                    self._emit(stdout, self._error(msg_id, say("unreachable", exc)))
                continue
            self._deliver(stdout, message, ids, status, headers, data)

    def _deliver(self, stdout, message, ids, status, headers, data):
        if 200 <= status < 300:
            for body in self._bodies(headers, data):
                try:
                    parsed = json.loads(body)
                except ValueError:
                    parsed = None
                if isinstance(parsed, dict) and parsed.get("id") is None and "error" in parsed and ids:
                    # Ответ без id на запрос с id (сервер не сохранил ответ на повторённую попытку):
                    # клиент не сопоставил бы его со своим запросом и ждал бы до таймаута.
                    error = parsed.get("error") if isinstance(parsed.get("error"), dict) else {}
                    text = str(error.get("message") or say("http", status))
                    for msg_id in ids:
                        self._emit(stdout, self._error(msg_id, text))
                    continue
                self._remember_version(message, body)
                self._emit(stdout, json.dumps(parsed, ensure_ascii=False) if parsed is not None else body)
            return
        if status == 404:
            text = say("refused")
        elif status == 429:
            text = say("rate", headers.get("retry-after") or "?")
        else:
            text = say("http", status)
        for msg_id in ids:
            self._emit(stdout, self._error(msg_id, text))

    @staticmethod
    def _is_json(body):
        try:
            json.loads(body)
            return True
        except ValueError:
            return False

    def _remember_version(self, request, body):
        if not isinstance(request, dict) or request.get("method") != "initialize":
            return
        try:
            version = json.loads(body).get("result", {}).get("protocolVersion")
        except (ValueError, AttributeError):
            return
        if isinstance(version, str) and version:
            self.protocol_version = version

    @staticmethod
    def _emit(stdout, text):
        stdout.write(text.encode("utf-8") + b"\n")
        stdout.flush()


# ── Команды ──────────────────────────────────────────────────────────────────
def config_dir(explicit=None):
    if explicit:
        return explicit
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "goamnezia-connect")


def _prepare_dir(directory):
    os.makedirs(directory, mode=0o700, exist_ok=True)
    try:
        os.chmod(directory, 0o700)
    except OSError:
        pass
    # realpath без приведения регистра: на macOS ~/dropbox и ~/Dropbox — одна папка.
    if any(mark.lower() in os.path.realpath(directory).lower() for mark in SYNCED_DIR_MARKS):
        log(say("synced_dir", directory))
        return False
    return True


def _self_command():
    """Полный путь к самому переходнику — для строки клиента MCP: клиент с окнами (Claude
    Desktop и прочие) PATH оболочки не видит, и голое имя там не запускается."""
    return os.path.abspath(__file__)


def _client_config(grant, directory):
    """Запуск для клиента MCP: интерпретатор, скрипт и каталог настроек — полными путями. Первая
    строка скрипта ищет python3 через PATH, а клиент с окнами (Claude Desktop и прочие) не видит ни
    PATH, ни XDG_CONFIG_HOME оболочки; каталог, заданный при привязке через --dir, тоже нужен явно."""
    return {"command": sys.executable or "python3",
            "args": [_self_command(), "--grant", grant, "--dir", os.path.abspath(directory)]}


def _client_line(grant, directory):
    return json.dumps(_client_config(grant, directory), ensure_ascii=False)


def _promote_staged(directory, grant):
    """Привязка, сделанная, пока работал прежний переходник этого доступа, включается при первом
    запуске под замком: сперва ключ, потом настройки — настройки не должны указывать на чужой ключ."""
    staged_cfg = os.path.join(directory, grant + ".json.new")
    if not os.path.exists(staged_cfg):
        return
    for name in (grant + ".key", grant + ".cred"):
        src = os.path.join(directory, name + ".new")
        if os.path.exists(src):
            os.replace(src, os.path.join(directory, name))
    os.replace(staged_cfg, os.path.join(directory, grant + ".json"))


def cmd_enroll(args):
    directory = config_dir(args.dir)
    if not _prepare_dir(directory):
        return 2
    # Всё, что может сорвать запись привязки, проверяется ДО отправки кода: сервер сжигает
    # код и отдаёт секреты один раз, и провал после ответа означал бы новый перевыпуск.
    if fcntl is None:
        log(say("no_fcntl"))
        return 2
    try:
        client = Http(args.server, args.fingerprint or "")
    except ValueError as exc:
        log(say("bad_server", exc))
        return 2
    storage = args.storage
    if storage == "auto":
        storage = "tpm" if TpmStore.available() else "file"
    body = json.dumps({"key_storage": storage, "client": USER_AGENT, "host": socket.gethostname()}).encode("utf-8")
    try:
        status, _headers, data = client.request("POST", "/a-%s/enroll" % enroll_path(args.code), body=body,
                                                headers={"Content-Type": "application/json",
                                                         "User-Agent": USER_AGENT})
    except (OSError, http.client.HTTPException, ssl.SSLError, FingerprintMismatch) as exc:
        log(say("unreachable", exc))
        return 3
    if status != 200:
        log(say("enroll_refused"))
        return 3
    try:
        reply = json.loads(data.decode("utf-8"))
        grant = str(reply["grant"])
        rot_seed = str(reply["rot_seed"])
        token = str(reply["token"])
        key = str(reply["key"])
    except (ValueError, KeyError, TypeError) as exc:
        log(say("enroll_bad_reply", exc))
        return 3
    if not (GRANT_RE.match(grant) and SECRET_RE.match(rot_seed) and SECRET_RE.match(token) and SECRET_RE.match(key)):
        log(say("enroll_bad_reply", "format"))
        return 3
    # Работающий переходник ЭТОГО доступа (перевыпуск при открытом клиенте MCP) держит замок и
    # на каждом вызове пишет свой ключ: писать поверх нельзя. Код уже сгорел, поэтому привязка
    # не теряется, а откладывается: файлы .new включатся при следующем запуске под замком.
    try:
        lock = acquire_lock(os.path.join(directory, grant + ".lock"))
    except Busy:
        lock = None
    suffix = "" if lock is not None else ".new"
    try:
        cfg = {"version": 1, "server": args.server, "fingerprint": args.fingerprint or "", "grant": grant,
               "rot_seed": rot_seed, "token": token, "storage": storage,
               "label": str(reply.get("label") or ""), "scope": str(reply.get("scope") or ""),
               "enrolled": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
        try:
            if lock is not None:
                # Прямая привязка новее любой отложенной: та иначе включилась бы при следующем
                # запуске поверх неё, с сожжённым кодом и мёртвым ключом.
                for stale in (".json.new", ".key.new", ".cred.new"):
                    try:
                        os.unlink(os.path.join(directory, grant + stale))
                    except OSError:
                        pass
            make_store(storage, directory, grant, suffix).save({"key": key, "pending_nonce": ""})
            _atomic_write(os.path.join(directory, grant + ".json" + suffix),
                          json.dumps(cfg, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8"))
        except (StoreError, OSError) as exc:
            log(say("enroll_store_failed", exc))
            return 3
    finally:
        if lock is not None:
            os.close(lock)
    if lock is None:
        print(say("staged", grant, cfg["label"] or "-", cfg["scope"] or "-", _client_line(grant, directory)))
        return 0
    print(say("enrolled", grant, cfg["label"] or "-", cfg["scope"] or "-", storage, _client_line(grant, directory)))
    if storage == "file":
        log(say("storage_file_note"))
    return 0


def load_cfg(directory, grant):
    path = os.path.join(directory, grant + ".json")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            cfg = json.load(fh)
    except (OSError, ValueError):
        return None, path
    return (cfg if isinstance(cfg, dict) else None), path


def cmd_run(args):
    directory = config_dir(args.dir)
    if fcntl is None:
        log(say("no_fcntl"))
        return 2
    try:
        lock = acquire_lock(os.path.join(directory, args.grant + ".lock"))
    except Busy:
        log(say("busy"))
        return 2
    except OSError:
        log(say("no_cfg", args.grant, os.path.join(directory, args.grant + ".json")))
        return 2
    try:
        _promote_staged(directory, args.grant)
        cfg, path = load_cfg(directory, args.grant)
        if cfg is None:
            log(say("no_cfg", args.grant, path))
            return 2
        try:
            client = Http(str(cfg.get("server") or ""), cfg.get("fingerprint") or "")
        except ValueError as exc:
            log(say("bad_server", exc))
            return 2
        try:
            connector = Connector(cfg, make_store(cfg.get("storage") or "file", directory, args.grant), client)
        except StoreError as exc:
            log(say("store_unreadable", args.grant, exc))
            return 2
        connector.run(sys.stdin.buffer, sys.stdout.buffer)
    finally:
        os.close(lock)
    return 0


def cmd_status(args):
    directory = config_dir(args.dir)
    cfg, path = load_cfg(directory, args.grant)
    if cfg is None:
        log(say("no_cfg", args.grant, path))
        return 2
    store = make_store(cfg.get("storage") or "file", directory, args.grant)
    try:
        state, readable = (store.load() or {}), True
    except StoreError:
        state, readable = {}, False
    busy = False
    try:
        os.close(acquire_lock(os.path.join(directory, args.grant + ".lock")))
    except Busy:
        busy = True
    out = {"grant": args.grant, "server": cfg.get("server"), "label": cfg.get("label"),
           "scope": cfg.get("scope"), "storage": store.kind, "key_present": bool(state.get("key")),
           "store_readable": readable, "recovery_pending": bool(state.get("pending_nonce")), "in_use": busy,
           "staged": os.path.exists(os.path.join(directory, args.grant + ".json.new")),
           "mcp_client_config": _client_config(args.grant, directory)}
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="goamnezia-connect",
                                     description="Переходник MCP stdio ↔ goAmnezia pro (одноразовый ключ).")
    parser.add_argument("--grant", help="идентификатор доступа (a-xxxx) — запустить переходник для клиента MCP")
    parser.add_argument("--dir", help="каталог настроек (по умолчанию ~/.config/goamnezia-connect)")
    parser.add_argument("--version", action="version", version=USER_AGENT)
    sub = parser.add_subparsers(dest="cmd")
    enroll = sub.add_parser("enroll", help="привязать доступ одноразовым кодом")
    enroll.add_argument("code")
    enroll.add_argument("--server", required=True, help="https://домен или http://127.0.0.1:1986 (туннель)")
    enroll.add_argument("--fingerprint", help="SHA-256 самоподписанного сертификата из карточки доступа")
    enroll.add_argument("--storage", choices=("auto", "file", "tpm"), default="auto")
    enroll.add_argument("--dir")
    status = sub.add_parser("status", help="состояние привязки, без секретов")
    status.add_argument("--grant", required=True)
    status.add_argument("--dir")
    args = parser.parse_args(argv)
    if args.cmd == "enroll":
        return cmd_enroll(args)
    if args.cmd == "status":
        return cmd_status(args)
    if args.grant:
        return cmd_run(args)
    parser.print_help(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
