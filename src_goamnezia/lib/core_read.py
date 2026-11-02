#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""goAmnezia pro — lib/core_read.py: частые чтения ядра внутри процесса панели (PERF-01, часть C).

Зачем. Каждое чтение панели было запуском моста `install.sh --action=… --json`: bash, два десятка модулей и
словарь, отметка зависимостей, снимок config.json, десятки jq. На сервере в 1 vCPU это 2–3 с на карточку
человека, 3 с на ключ и 2,5 с на адреса подписки (живая проверка на 168, 05.10.2026), при низкой нагрузке:
медленен сам запуск. Модуль отвечает на те же чтения из тех же файлов в уже запущенном процессе панели —
тем же JSON, что мост: те же поля, в том же порядке, с теми же словами.

Действия: user-list, user-show, user-key (без разового адреса), share-list, sub-list, sub-show, page-list.
Изменения (add, del, rotate и прочие) идут только мостом, под его замком. Модуль ничего не пишет, кроме строки
аудита выдачи ключа (user-key) и показа адресов подписки (sub-show) — той же строки, что пишет ядро.

Правила (docs/PANEL.md §5b, docs/CONTRACT.md §6):
 * Ответ — одно из двух: тот же JSON, что у моста, или None — «пусть ответит мост». None — на любой отказ (нет
   человека, битый файл, не тот профиль: отказ мост скажет своими словами, со своим кодом и спасательной
   копией), на редкие ветки (разовый адрес в ключе, адрес сервера не записан в config.json, раздача, которую
   уборщик ядра снял бы) и на данные, в форме которых модуль не уверен (дробные числа, поля не того типа,
   подпись с !*'() в адресах Clash, порядок имён в чужой локали).
 * Зеркало сверено с ядром отпечатком (MIRROR): функции ядра, которые модуль повторяет, хешируются; правка
   любой из них без сверки модуля выключает быстрый путь этого действия — чтение снова идёт мостом.
   Сверка: `python3 tests/check_core_read.py` (секунда, без bash: какие места изменились и их дифф), равенство с
   мостом — tests/test_core_read.py, обновить отпечаток — `python3 lib/core_read.py --fingerprint --write`.
 * Замок: чтение берёт общий замок ядра (config.lock) на чтение — flock LOCK_SH — и ждёт идущую запись не
   дольше READ_LOCK_WAIT (GOAMNEZIA_READ_LOCK_WAIT, 0–5 с). Мутация ядра держит LOCK_EX на всю правку users.json
   и config.json, поэтому чтение видит их до правки или после, но не посередине. Не дождались (долгая установка) —
   читаем без замка, как мост: каждый файл ядро всё равно меняет атомарно (временный файл и rename). Под замком —
   только чтение файлов: адреса машины (ip) собираются до него, qrencode — после.
 * Срок: весь ответ — не дольше ANSWER_TIMEOUT (замок, ip, qrencode вместе); вышел — отвечает мост.
 * Секреты: приватные ключи и PSK уходят только в ответе user-key, как у моста; в журнал модуль не пишет ничего,
   кроме строки аудита без ключей.

Только stdlib, Python ≥ 3.8.
"""

from __future__ import annotations

import ast
import base64
import contextlib
import copy
import errno
import fcntl
import hashlib
import importlib.util
import json
import math
import os
import re
import shutil
import subprocess
import sys
import threading
import time

ACTIONS = ("user-list", "user-show", "user-key", "share-list", "sub-list", "sub-show", "page-list")

# Сколько ждать идущую запись ядра (секунды). Мост мутаций ждёт замок 30 с, но чтение панели не должно висеть
# за установкой профиля: не дождались — читаем без замка, как мост (файлы ядро пишет атомарно).
# GOAMNEZIA_READ_LOCK_WAIT — от 0 до READ_LOCK_WAIT_MAX; не число, nan и бесконечность — READ_LOCK_WAIT.
READ_LOCK_WAIT = 1.0
READ_LOCK_WAIT_MAX = 5.0
# Срок всего ответа (секунды): замок (до 5 с), адреса машины (ip, до 5 с) и qrencode (до 20 с на картинку) вместе.
# Вышел — Fallback, и отвечает мост со своим сроком (у панели — 60 с на чтение): быстрый путь не может растянуть
# ожидание ответа больше чем на эти секунды.
ANSWER_TIMEOUT = 20.0


class Fallback(Exception):
    """Этот случай отвечает мост (см. правила в шапке)."""


class _NeedAddrs(Exception):
    """Чтению под замком понадобились адреса машины (ga_edge_list): answer() собирает их без замка и повторяет
    чтение — ip не держит замок ядра."""


class _Call(object):
    """Один ответ answer(): его срок (time.monotonic) и адреса машины, собранные до замка (None — ещё нет)."""
    __slots__ = ("deadline", "addrs")

    def __init__(self, deadline):
        self.deadline = deadline
        self.addrs = None


# ── Правила ядра, повторённые здесь (источник — в скобках) ───────────────────
_NAME_RE = re.compile(r"[A-Za-z0-9_-]{1,32}")                       # GA_USERS_NAME_RE, GA_SUBS_NAME_RE
_LINE_RE = re.compile(r"1\.0|1\.5|2\.0|3\.1")                       # ga_profile_line
_PROFILES = ("awg3", "awg2", "awg1")                                # PROFILE_IDS, GA_SUBS_PROFILES
_PROFILE_DEFAULTS = {                                               # ga_profile_default
    ("awg2", "container"): "amnezia-awg2", ("awg2", "line"): "2.0", ("awg2", "subnet"): "10.8.2.0/24",
    ("awg3", "container"): "amnezia-awg3", ("awg3", "line"): "3.1", ("awg3", "subnet"): "10.8.3.0/24",
    ("awg1", "container"): "amnezia-awg1", ("awg1", "line"): "1.5", ("awg1", "subnet"): "10.8.1.0/24",
}
_IPV4_SHAPE = re.compile(r"[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}")    # _valid_ip
_DIGITS_DOTS = re.compile(r"[0-9.]+")                                            # ga_valid_host
_HOST_RE = re.compile(r"[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)+")
_DIGITS = re.compile(r"[0-9]+")
_MTU_RE = re.compile(r"[0-9]{4}")                                                # ga_valid_mtu
_MIN_CLIENT = {"1.0": "4.0.0", "1.5": "4.8.8.3", "2.0": "4.8.12.9", "3.1": "5.0.1.5"}   # ga_export_min_client
_DNS_DEFAULT = ["1.1.1.1", "1.0.0.1"]                               # GA_EXPORT_DNS_DEFAULT
_MTU_DEFAULT = 1280                                                 # GA_EXPORT_MTU_DEFAULT
_MTU_MIN, _MTU_MAX = 1200, 1500                                     # GA_MTU_MIN, GA_MTU_MAX
_QR_ARGS = ("-l", "L", "-t", "PNG", "-s", "6", "-m", "2")           # export_qr_png, GA_EXPORT_QR_SCALE
_FORMATS = ("conf", "vpn", "qr-conf", "qr-vpn", "all")              # export_bundle
_SECRET43 = re.compile(r"[A-Za-z0-9_-]{43}")                        # GA_SUBS_SECRET_RE
_SUB_TOKENS = {"1.0": "awg10", "1.5": "awg15", "2.0": "awg20", "3.1": "awg31"}   # ga_subs_lines_json
_SUB_LINES = ("3.1", "2.0", "1.5", "1.0")                           # GA_SUBS_LINES
_SUB_FILES = {"mihomo": "yaml", "txt": "txt", "vpn": "vpn", "conf": "conf"}      # ga_subs_clients_json
_SUB_RANK = {"mihomo": 0, "txt": 1, "vpn": 2, "conf": 3}
_SUB_INSTALL_RE = re.compile(r"[a-z][a-z0-9+.-]*://install-config\?")
_EDGE_PRIVATE = re.compile(r"(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|169\.254\."
                           r"|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)")   # ga_edge_list
_HEX_ID = re.compile(r"[ps]-[a-f0-9]+")
# @uri у jq: 1.7 кодирует !*'(), 1.6 — нет. Подпись с этими знаками отдаём мосту — у него свой jq.
_URI_KEEP = frozenset(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
_URI_AMBIGUOUS = frozenset("!*'()")
_SAFE_INT = 2 ** 53
_SURROGATE = re.compile("[\ud800-\udfff]")
_SYS_PATH = ("/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin")   # install.sh: PATH
_I18N_LINE = re.compile(r'^I18N\[([A-Za-z0-9_]+)\]="((?:[^"\\$`]|\\.)*)"\s*$')
_I18N_ANY = re.compile(r'^\s*I18N\[([^\]]*)\]=')
_C_LOCALES = ("", "C", "POSIX", "C.UTF-8", "C.utf8", "C.UTF8", "C.utf-8")


# ── Зеркало: что из ядра повторено здесь ─────────────────────────────────────
# Место — (файл от корня продукта, вид, имя). bash: fn — функция, case — ветка диспетчера _action_dispatch_locked,
# pre — его начало до первой ветки, var — переменная модуля. Python (awgkeys.py, shortlinks.py — их зовёт мост, а
# модуль импортирует): fn — функция или метод («Класс.метод»), case — ветка if/elif вида `x == "строка"` внутри неё
# («функция:строка», как подкоманды CLI). lib/actions.json: action — описание действия, param — тип параметра (без
# description и mcp). Отпечаток места — sha256 его текста без строк-комментариев и docstring (PLACES), действия — его
# мест по порядку (RECORDED); правка любого места выключает быстрый путь действия до сверки: tests/check_core_read.py
# называет изменённые места и показывает их дифф, после сверки — `python3 lib/core_read.py --fingerprint --write`.
_BASE = (
    ("install.sh", "fn", "_cfg"), ("install.sh", "fn", "_as_json"), ("install.sh", "fn", "_action_run"),
    ("install.sh", "fn", "_action_emit_merged"), ("install.sh", "fn", "action_dispatch"),
    ("install.sh", "pre", "_action_dispatch_locked"), ("install.sh", "fn", "_action_meta"),
    ("install.sh", "fn", "_action_known"), ("install.sh", "fn", "_action_own_lock"),
    ("install.sh", "fn", "_action_parse_args"), ("install.sh", "fn", "_action_reject_unknown_args"),
    ("install.sh", "fn", "_action_validate_args"), ("install.sh", "fn", "_action_re_normalize"),
    ("install.sh", "fn", "_action_value_fits"),
    ("lib/common.sh", "var", "GOAMNEZIA_DIR"), ("lib/common.sh", "var", "CONFIG_FILE"),
    ("lib/common.sh", "var", "USERS_FILE"), ("lib/common.sh", "var", "LOCK_DIR"), ("lib/common.sh", "var", "LOCK_FILE"),
    ("lib/common.sh", "var", "AUDIT_LOG"), ("lib/common.sh", "var", "BOT_DIR"),
    ("lib/common.sh", "fn", "ga_config_get"), ("lib/common.sh", "fn", "_ga_config_memo_get"),
    ("lib/common.sh", "fn", "ga_config_memo_load"), ("lib/common.sh", "fn", "ga_emit_json"),
    ("lib/docker.sh", "fn", "ga_capture"), ("lib/docker.sh", "fn", "ga_dry"),
    ("lib/i18n.sh", "fn", "load_language"), ("lib/i18n.sh", "fn", "t"), ("lib/i18n.sh", "fn", "tf"),
    ("lib/i18n.sh", "fn", "detect_language"),
)
_USERS = (
    ("lib/common.sh", "fn", "ga_users_intact"), ("lib/common.sh", "fn", "ga_users_read"),
    ("lib/common.sh", "fn", "ga_users_load"), ("lib/common.sh", "fn", "_valid_ip"), ("lib/common.sh", "fn", "ga_valid_host"),
    ("lib/users.sh", "fn", "ga_users_json"), ("lib/users.sh", "fn", "ga_users_get"),
    ("lib/users.sh", "fn", "ga_users_public_filter"), ("lib/users.sh", "fn", "ga_users_check_name"),
    ("lib/users.sh", "fn", "ga_users_require"), ("lib/users.sh", "var", "GA_USERS_NAME_RE"),
    ("lib/users.sh", "fn", "ga_users_name_valid"), ("lib/users.sh", "fn", "users_exists"),
    ("lib/actions.json", "param", "name"),
)
_ENDPOINT = (
    ("lib/export.sh", "fn", "ga_export_pro_domain"), ("lib/export.sh", "fn", "ga_export_endpoint_host"),
    ("lib/edgeips.sh", "fn", "ga_edge_list"),
)
_PROFILE = (
    ("lib/amnezia.sh", "fn", "ga_profile_valid"), ("lib/amnezia.sh", "fn", "ga_profile_default"),
    ("lib/amnezia.sh", "fn", "ga_profile_field"), ("lib/amnezia.sh", "fn", "ga_profile_installed"),
    ("lib/amnezia.sh", "fn", "ga_profile_line"), ("lib/amnezia.sh", "fn", "ga_profile_check"),
    ("lib/amnezia.sh", "fn", "ga_profile_check_installed"),
    # линия по параметрам (ga_profile_line → `awgkeys.py detect-line`): модуль зовёт detect_line импортом
    ("lib/amnezia.sh", "var", "GA_LIB_DIR"), ("lib/amnezia.sh", "fn", "ga_awgkeys"),
    ("lib/awgkeys.py", "case", "_run:detect-line"), ("lib/awgkeys.py", "fn", "_read_params_stdin"),
    ("lib/awgkeys.py", "fn", "_read_stdin"),
)
_SITE = (
    ("lib/website.sh", "fn", "ga_site_mode"), ("lib/website.sh", "fn", "ga_site_has_site"),
    ("lib/website.sh", "fn", "ga_site_cert_kind"), ("lib/website.sh", "fn", "ga_site_domain_ready"),
    ("lib/pages.sh", "fn", "ga_pages_domain"), ("lib/pages.sh", "fn", "ga_pages_domain_ready"),
)
_AUDIT = (("lib/common.sh", "fn", "ga_audit"), ("lib/common.sh", "fn", "_ga_json_str"), ("lib/common.sh", "fn", "ga_now"))
_SUBS = (
    ("lib/subs.sh", "var", "GA_SUBS_SECRET_RE"), ("lib/subs.sh", "var", "GA_SUBS_NAME_RE"),
    ("lib/subs.sh", "var", "GA_SUBS_LINES"), ("lib/subs.sh", "var", "GA_SUBS_PROFILES"),
    ("lib/subs.sh", "var", "GA_SUBS_UPDATE_HOURS"), ("lib/subs.sh", "var", "GA_SUBS_PLATFORMS"),
    ("lib/subs.sh", "var", "GA_SUBS_EGRESS"),
    ("lib/subs.sh", "fn", "ga_subs_dir"), ("lib/subs.sh", "fn", "ga_subs_domain"), ("lib/subs.sh", "fn", "ga_subs_catalog"),
    ("lib/subs.sh", "fn", "ga_subs_domain_ready"), ("lib/subs.sh", "fn", "ga_subs_update_hours"),
    ("lib/subs.sh", "fn", "ga_subs_check_name"), ("lib/subs.sh", "fn", "ga_subs_secret_of"),
    ("lib/subs.sh", "fn", "ga_subs_exists"), ("lib/subs.sh", "fn", "_ga_subs_owner_gone"),
    ("lib/subs.sh", "fn", "ga_subs_lines_json"), ("lib/subs.sh", "fn", "ga_subs_row"),
    ("lib/pages.sh", "fn", "ga_pages_clients_json"),
)
MIRROR = {
    "user-list": _BASE + _USERS + (("install.sh", "case", "user-list"), ("lib/users.sh", "fn", "users_list"),
                                   ("lib/actions.json", "action", "user-list")),
    "user-show": _BASE + _USERS + _ENDPOINT + (("install.sh", "case", "user-show"), ("lib/users.sh", "fn", "users_show"),
                                               ("lib/actions.json", "action", "user-show")),
    "user-key": _BASE + _USERS + _ENDPOINT + _PROFILE + _AUDIT + (
        ("lib/actions.json", "action", "user-key"), ("lib/actions.json", "param", "profile"),
        ("lib/actions.json", "param", "format"), ("lib/actions.json", "param", "key_endpoint"),
        # .conf, vpn:// и чанки QR мост берёт подкомандами awgkeys.py, модуль — теми же функциями импортом
        ("lib/awgkeys.py", "case", "_run:conf"), ("lib/awgkeys.py", "case", "_run:vpn-encode"),
        ("lib/awgkeys.py", "case", "_run:qr-chunks"), ("lib/awgkeys.py", "fn", "_read_json_stdin"),
        ("lib/awgkeys.py", "fn", "_print_json"),
        ("install.sh", "case", "user-key"), ("lib/common.sh", "fn", "ga_valid_mtu"),
        ("lib/common.sh", "var", "GA_MTU_MIN"), ("lib/common.sh", "var", "GA_MTU_MAX"),
        ("lib/export.sh", "var", "GA_EXPORT_DNS_DEFAULT"), ("lib/export.sh", "var", "GA_EXPORT_MTU_DEFAULT"),
        ("lib/export.sh", "var", "GA_EXPORT_QR_SCALE"), ("lib/export.sh", "fn", "_ga_export_host_for"),
        ("lib/export.sh", "fn", "ga_export_dns_json"), ("lib/export.sh", "fn", "ga_export_min_client"),
        ("lib/export.sh", "fn", "ga_export_peer"), ("lib/export.sh", "fn", "ga_export_qrencode_ok"),
        ("lib/export.sh", "fn", "export_conf"), ("lib/export.sh", "fn", "export_vpn"),
        ("lib/export.sh", "fn", "export_qr_png"), ("lib/export.sh", "fn", "ga_export_audit_key"),
        ("lib/export.sh", "fn", "export_bundle"), ("lib/amnezia.sh", "fn", "ga_key_file_base")),
    "share-list": _BASE + (
        ("lib/actions.json", "action", "share-list"),
        ("install.sh", "case", "share-list"), ("lib/share.sh", "var", "GA_SHARE_DRAIN_MAX"),
        ("lib/share.sh", "var", "GA_SHARE_START_GRACE"), ("lib/share.sh", "fn", "ga_share_state_dir"),
        ("lib/share.sh", "fn", "ga_share_read_num"), ("lib/share.sh", "fn", "ga_share_alive"),
        ("lib/share.sh", "fn", "ga_share_busy"), ("lib/share.sh", "fn", "ga_share_starting"),
        ("lib/share.sh", "fn", "ga_share_expired"), ("lib/share.sh", "fn", "ga_share_sweep"),
        ("lib/share.sh", "fn", "share_list")),
    "sub-list": _BASE + _USERS + _PROFILE + _SITE + _SUBS + (("install.sh", "case", "sub-list"), ("lib/subs.sh", "fn", "subs_list"),
                                                              ("lib/subs.sh", "fn", "ga_subs_update_slow"),
                                                              ("lib/actions.json", "action", "sub-list")),
    "sub-show": _BASE + _USERS + _PROFILE + _SITE + _SUBS + _AUDIT + (
        ("lib/actions.json", "action", "sub-show"),
        ("install.sh", "case", "sub-show"), ("lib/subs.sh", "fn", "subs_show"), ("lib/subs.sh", "fn", "ga_subs_audit"),
        ("lib/subs.sh", "fn", "ga_subs_urls_json"), ("lib/subs.sh", "fn", "ga_subs_clients_json"),
        ("lib/subs.sh", "fn", "_ga_subs_answer"), ("lib/subs.sh", "fn", "ga_short_urls"),
        ("lib/subs.sh", "fn", "ga_short_py"), ("lib/subs.sh", "fn", "_ga_short_call"),
        # короткие ссылки мост берёт `shortlinks.py urls`, модуль — теми же codes_of и available импортом
        ("lib/shortlinks.py", "case", "main:urls"), ("lib/shortlinks.py", "fn", "_args"),
        ("lib/shortlinks.py", "fn", "ShortLinks.__init__")),
    "page-list": _BASE + (
        ("lib/actions.json", "action", "page-list"), ("lib/actions.json", "param", "name"),
        ("install.sh", "case", "page-list"), ("lib/pages.sh", "fn", "ga_pages_dir"),
        ("lib/pages.sh", "fn", "ga_pages_expired"), ("lib/pages.sh", "fn", "ga_pages_row"),
        ("lib/pages.sh", "fn", "pages_list")),
}
# >>> отпечатки: пишет `python3 lib/core_read.py --fingerprint --write` после сверки (tests/test_core_read.py)
RECORDED = {
    "user-list": "0fcc50f2de8cf169",
    "user-show": "9d35b172a3ddc1e4",
    "user-key": "81178b7be6dbe69c",
    "share-list": "df23e3984710e155",
    "sub-list": "01e62367207db1ba",
    "sub-show": "43f497142116fd9f",
    "page-list": "234ff21f7586aa70",
}
PLACES = {
    "install.sh|case|page-list": "9b70bc7643af9326",
    "install.sh|case|share-list": "ce1da56211c2cfd7",
    "install.sh|case|sub-list": "373c1461148c129e",
    "install.sh|case|sub-show": "5f2fece91983004d",
    "install.sh|case|user-key": "17dcf871996059fe",
    "install.sh|case|user-list": "a3ef7b5a7b339896",
    "install.sh|case|user-show": "72d15c4d76b8fa65",
    "install.sh|fn|_action_emit_merged": "cd1b5b1fec4689e2",
    "install.sh|fn|_action_known": "d6353f348e9ae568",
    "install.sh|fn|_action_meta": "a270205ece1fcf61",
    "install.sh|fn|_action_own_lock": "f3db6fa0380c1361",
    "install.sh|fn|_action_parse_args": "fea0b8fc89f12471",
    "install.sh|fn|_action_re_normalize": "a0769550b47fd218",
    "install.sh|fn|_action_reject_unknown_args": "614a56d1a0e7fbe7",
    "install.sh|fn|_action_run": "c1f5a2e0f54a937b",
    "install.sh|fn|_action_validate_args": "6208668c7460b37e",
    "install.sh|fn|_action_value_fits": "ac50d3b0c5feaf8e",
    "install.sh|fn|_as_json": "be1bcf127a05b8e5",
    "install.sh|fn|_cfg": "a272a03d80614f12",
    "install.sh|fn|action_dispatch": "cc4150a2598b282f",
    "install.sh|pre|_action_dispatch_locked": "eda4b179a3912b2f",
    "lib/actions.json|action|page-list": "0fe4ecfa1f225498",
    "lib/actions.json|action|share-list": "2929182046b04863",
    "lib/actions.json|action|sub-list": "9266602b3ccb02a4",
    "lib/actions.json|action|sub-show": "7ca090ce2be81614",
    "lib/actions.json|action|user-key": "3704ffef10f99768",
    "lib/actions.json|action|user-list": "34d22d34450ac25f",
    "lib/actions.json|action|user-show": "8aa9832fee0fc622",
    "lib/actions.json|param|format": "0f2dc16f566faadc",
    "lib/actions.json|param|key_endpoint": "0cd893ddf59f4b9d",
    "lib/actions.json|param|name": "0def7c51f5016216",
    "lib/actions.json|param|profile": "991d4a9330926b19",
    "lib/amnezia.sh|fn|ga_awgkeys": "e11fe0540d8d5159",
    "lib/amnezia.sh|fn|ga_key_file_base": "07fb944f9d2ce212",
    "lib/amnezia.sh|fn|ga_profile_check": "4f386bff72c9cf05",
    "lib/amnezia.sh|fn|ga_profile_check_installed": "44170dfcabdd9d14",
    "lib/amnezia.sh|fn|ga_profile_default": "78e97cd03c637836",
    "lib/amnezia.sh|fn|ga_profile_field": "7448b7f1bf19ce3d",
    "lib/amnezia.sh|fn|ga_profile_installed": "e7824ba77e7080e9",
    "lib/amnezia.sh|fn|ga_profile_line": "fc6564c80419feae",
    "lib/amnezia.sh|fn|ga_profile_valid": "0b32c0d1ed97420f",
    "lib/amnezia.sh|var|GA_LIB_DIR": "8d1464877681d6bf",
    "lib/awgkeys.py|case|_run:conf": "436217fb39c292c5",
    "lib/awgkeys.py|case|_run:detect-line": "2f7cef3f4a82bf53",
    "lib/awgkeys.py|case|_run:qr-chunks": "3e94373e9182ea11",
    "lib/awgkeys.py|case|_run:vpn-encode": "f957586088b233db",
    "lib/awgkeys.py|fn|_print_json": "ae508e1c6d00fd0e",
    "lib/awgkeys.py|fn|_read_json_stdin": "b17cc68dd433c024",
    "lib/awgkeys.py|fn|_read_params_stdin": "d041d86a43ca72e8",
    "lib/awgkeys.py|fn|_read_stdin": "f902a67620c1ae6a",
    "lib/common.sh|fn|_ga_config_memo_get": "5863dc55e4f3efa7",
    "lib/common.sh|fn|_ga_json_str": "9cffdb7ae93ae7bb",
    "lib/common.sh|fn|_valid_ip": "bd54d786e3d9fab1",
    "lib/common.sh|fn|ga_audit": "d233634d74e8531b",
    "lib/common.sh|fn|ga_config_get": "485a7de9e1de566a",
    "lib/common.sh|fn|ga_config_memo_load": "48b962a5a60b2596",
    "lib/common.sh|fn|ga_emit_json": "7ed0791b5bc87842",
    "lib/common.sh|fn|ga_now": "f165255a42b9db98",
    "lib/common.sh|fn|ga_users_intact": "c848fb6c13a35b64",
    "lib/common.sh|fn|ga_users_load": "e3e87329e715cec3",
    "lib/common.sh|fn|ga_users_read": "6a4f32a56247876d",
    "lib/common.sh|fn|ga_valid_host": "27944679cb6c1a64",
    "lib/common.sh|fn|ga_valid_mtu": "1270a7c9b2ae2bf3",
    "lib/common.sh|var|AUDIT_LOG": "a25321c6a557f3a5",
    "lib/common.sh|var|BOT_DIR": "b249ba70b1901838",
    "lib/common.sh|var|CONFIG_FILE": "fa1d53b24a21e6a8",
    "lib/common.sh|var|GA_MTU_MAX": "3d3852f6f8031505",
    "lib/common.sh|var|GA_MTU_MIN": "60b8f019bc1cad2d",
    "lib/common.sh|var|GOAMNEZIA_DIR": "373ec84d95de7f4a",
    "lib/common.sh|var|LOCK_DIR": "5082a5c6f2c371b8",
    "lib/common.sh|var|LOCK_FILE": "68eac87c69b94b02",
    "lib/common.sh|var|USERS_FILE": "b1f6199741d6935d",
    "lib/docker.sh|fn|ga_capture": "a3baa75e0601aad4",
    "lib/docker.sh|fn|ga_dry": "1da746b4f455f04c",
    "lib/edgeips.sh|fn|ga_edge_list": "684424049a481de5",
    "lib/export.sh|fn|_ga_export_host_for": "82ce0354cca21161",
    "lib/export.sh|fn|export_bundle": "c01a0492eded8902",
    "lib/export.sh|fn|export_conf": "ea0f87eb0f45db6d",
    "lib/export.sh|fn|export_qr_png": "ebdbe1caf83e53ff",
    "lib/export.sh|fn|export_vpn": "e3766d73f49ea72f",
    "lib/export.sh|fn|ga_export_audit_key": "865e18fea1cd0b97",
    "lib/export.sh|fn|ga_export_dns_json": "f5ced9b32a3f6c52",
    "lib/export.sh|fn|ga_export_endpoint_host": "cc47eb45f942f2a9",
    "lib/export.sh|fn|ga_export_min_client": "b7ea3b1eba853881",
    "lib/export.sh|fn|ga_export_peer": "b1e854f83bc74ad5",
    "lib/export.sh|fn|ga_export_pro_domain": "025ed24dfbfd5efc",
    "lib/export.sh|fn|ga_export_qrencode_ok": "b8bd57bd30d96798",
    "lib/export.sh|var|GA_EXPORT_DNS_DEFAULT": "34a0f1018570860d",
    "lib/export.sh|var|GA_EXPORT_MTU_DEFAULT": "bce651d58d2471ad",
    "lib/export.sh|var|GA_EXPORT_QR_SCALE": "32599ac15cfe9a83",
    "lib/i18n.sh|fn|detect_language": "d534c8047bd0efef",
    "lib/i18n.sh|fn|load_language": "1e38d30248437266",
    "lib/i18n.sh|fn|t": "29ae63a6f21d7cf2",
    "lib/i18n.sh|fn|tf": "50e7d07deb36e838",
    "lib/pages.sh|fn|ga_pages_clients_json": "4a41ad277fe35f75",
    "lib/pages.sh|fn|ga_pages_dir": "936453aeec1e7e0e",
    "lib/pages.sh|fn|ga_pages_domain": "99d4e0435db9a5d0",
    "lib/pages.sh|fn|ga_pages_domain_ready": "e5c19fafae959620",
    "lib/pages.sh|fn|ga_pages_expired": "ab7be5a142d756d5",
    "lib/pages.sh|fn|ga_pages_row": "004faa064ef1946b",
    "lib/pages.sh|fn|pages_list": "3df1d04fa9c0a472",
    "lib/share.sh|fn|ga_share_alive": "e7de9fabdc6e1937",
    "lib/share.sh|fn|ga_share_busy": "52b2fee4b93daf13",
    "lib/share.sh|fn|ga_share_expired": "702ca83dd107b11b",
    "lib/share.sh|fn|ga_share_read_num": "ca6183d02c31bd87",
    "lib/share.sh|fn|ga_share_starting": "01167b35da721b0a",
    "lib/share.sh|fn|ga_share_state_dir": "fdf9c63c60a18e31",
    "lib/share.sh|fn|ga_share_sweep": "ab327517233d1da6",
    "lib/share.sh|fn|share_list": "a75f98b193403371",
    "lib/share.sh|var|GA_SHARE_DRAIN_MAX": "96943d7d80955ded",
    "lib/share.sh|var|GA_SHARE_START_GRACE": "c1b0ceaeb5b9ad33",
    "lib/shortlinks.py|case|main:urls": "4e6edad9f5f84f17",
    "lib/shortlinks.py|fn|ShortLinks.__init__": "08bae5e2c2bcd173",
    "lib/shortlinks.py|fn|_args": "468510219c339534",
    "lib/subs.sh|fn|_ga_short_call": "fe5ab27b41b492f8",
    "lib/subs.sh|fn|_ga_subs_answer": "b69209ecb607543c",
    "lib/subs.sh|fn|_ga_subs_owner_gone": "07839bc51348c0c5",
    "lib/subs.sh|fn|ga_short_py": "c12b282fcf0665f3",
    "lib/subs.sh|fn|ga_short_urls": "f1ab8fc7da6d40e5",
    "lib/subs.sh|fn|ga_subs_audit": "eb4a62752c0aaca9",
    "lib/subs.sh|fn|ga_subs_catalog": "90409d2b711a3690",
    "lib/subs.sh|fn|ga_subs_check_name": "981e98233a3e0fa8",
    "lib/subs.sh|fn|ga_subs_clients_json": "bcab42925be1e16f",
    "lib/subs.sh|fn|ga_subs_dir": "43df834384a31652",
    "lib/subs.sh|fn|ga_subs_domain": "5875d8ac8704c100",
    "lib/subs.sh|fn|ga_subs_domain_ready": "8ad8d916c6e6515f",
    "lib/subs.sh|fn|ga_subs_exists": "8a2c44f42a3abbd2",
    "lib/subs.sh|fn|ga_subs_lines_json": "d384c526e239b51e",
    "lib/subs.sh|fn|ga_subs_row": "f72b832aa2df62a7",
    "lib/subs.sh|fn|ga_subs_secret_of": "b48d1fde42989f46",
    "lib/subs.sh|fn|ga_subs_update_hours": "72954e6d4374cf89",
    "lib/subs.sh|fn|ga_subs_update_slow": "ff8313f6c9d24392",
    "lib/subs.sh|fn|ga_subs_urls_json": "b652677348047ab1",
    "lib/subs.sh|fn|subs_list": "d7b7962defe1d024",
    "lib/subs.sh|fn|subs_show": "7b402f42f1d856cd",
    "lib/subs.sh|var|GA_SUBS_EGRESS": "dd73de2c48bd27b1",
    "lib/subs.sh|var|GA_SUBS_LINES": "758c7d5e52e10b2f",
    "lib/subs.sh|var|GA_SUBS_NAME_RE": "9fcb61934782905a",
    "lib/subs.sh|var|GA_SUBS_PLATFORMS": "fee95ff8f6bdbe69",
    "lib/subs.sh|var|GA_SUBS_PROFILES": "6562182871acf0ab",
    "lib/subs.sh|var|GA_SUBS_SECRET_RE": "1a6165522c6eb26d",
    "lib/subs.sh|var|GA_SUBS_UPDATE_HOURS": "c28955a49b178b97",
    "lib/users.sh|fn|ga_users_check_name": "facafe8d5109dde0",
    "lib/users.sh|fn|ga_users_get": "a728a5ed3fbe1d60",
    "lib/users.sh|fn|ga_users_json": "13221be4f406d3d7",
    "lib/users.sh|fn|ga_users_name_valid": "16b1c8a08a3e8651",
    "lib/users.sh|fn|ga_users_public_filter": "424c01e23c08b106",
    "lib/users.sh|fn|ga_users_require": "ff65d384ac84a33f",
    "lib/users.sh|fn|users_exists": "48c18e13c7dd29ca",
    "lib/users.sh|fn|users_list": "405915d155ddefc7",
    "lib/users.sh|fn|users_show": "2a69713427cc511a",
    "lib/users.sh|var|GA_USERS_NAME_RE": "7a88c0dbe3c220f7",
    "lib/website.sh|fn|ga_site_cert_kind": "a817a5135b44f16d",
    "lib/website.sh|fn|ga_site_domain_ready": "8b1493e6c2aa21c8",
    "lib/website.sh|fn|ga_site_has_site": "754dbc6b54038960",
    "lib/website.sh|fn|ga_site_mode": "a6bcba06466778d1",
}
# <<< отпечатки


# ── Помощники: как это делает jq и bash ──────────────────────────────────────
def _alt(v, d):
    """jq «v // d»: null и false — значение по умолчанию (пустая строка и ноль — нет)."""
    return d if v is None or v is False else v


def _raw(v):
    """Текст, который печатает «jq -r» для скаляра. Дробь, большое целое, объект и массив — мимо (мосту)."""
    if v is None:
        return "null"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, str):
        return v
    if isinstance(v, int):
        if abs(v) > _SAFE_INT:
            raise Fallback("big int")
        return str(v)
    raise Fallback("not a scalar")


def _sub(text):
    """Подстановка команды $(…): хвостовые переводы строк срезаются."""
    return text.rstrip("\n")


def _check_plain(obj, depth=0):
    """Ответ только из того, что мост напечатал бы так же: без дробей (jq 1.6 и 1.7 печатают их по-разному),
    без целых больше 2^53 (jq 1.6 их округляет) и без одиноких суррогатов."""
    if depth > 64:
        raise Fallback("deep")
    if obj is None or isinstance(obj, bool):
        return
    if isinstance(obj, int):
        if abs(obj) > _SAFE_INT:
            raise Fallback("big int")
        return
    if isinstance(obj, float):
        raise Fallback("float")
    if isinstance(obj, str):
        if _SURROGATE.search(obj):
            raise Fallback("surrogate")
        return
    if isinstance(obj, dict):
        for k, v in obj.items():
            _check_plain(k, depth + 1)
            _check_plain(v, depth + 1)
        return
    if isinstance(obj, list):
        for v in obj:
            _check_plain(v, depth + 1)
        return
    raise Fallback("type")


def _bad_constant(name):
    raise ValueError("bad constant %s" % name)


def _loads(raw):
    """Строгий разбор: NaN и Infinity jq не примет — и мы не принимаем."""
    return json.loads(raw.decode("utf-8") if isinstance(raw, bytes) else raw, parse_constant=_bad_constant)


def valid_ip(s):
    """_valid_ip: четыре группы по 1–3 цифры, без ведущих нулей, каждая ≤ 255."""
    if not isinstance(s, str) or not _IPV4_SHAPE.fullmatch(s):
        return False
    for octet in s.split("."):
        if len(octet) > 1 and octet[0] == "0":
            return False
        if int(octet) > 255:
            return False
    return True


def valid_host(h):
    """ga_valid_host: имя узла (строчные, две метки и больше) или IPv4 по значению."""
    if not isinstance(h, str) or not h or len(h) > 253:
        return False
    if _DIGITS_DOTS.fullmatch(h):
        return valid_ip(h)
    return bool(_HOST_RE.fullmatch(h))


def _json_str(s):
    """_ga_json_str: экранирование строки аудита без jq."""
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ").replace("\r", " ").replace("\t", " ")


def _uri(text):
    """jq @uri: UTF-8 байты, кроме A-Za-z0-9 -_.~, — %XX."""
    if any(c in _URI_AMBIGUOUS for c in text):
        raise Fallback("@uri differs between jq 1.6 and 1.7")
    return "".join(chr(b) if b in _URI_KEEP else "%%%02X" % b for b in text.encode("utf-8"))


def _unescape_dq(s):
    """Значение в двойных кавычках bash: \\ \" \\$ \\` и перевод строки — экранирование, прочее — как есть."""
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            if n in '"\\$`':
                out.append(n)
                i += 2
                continue
            if n == "\n":
                i += 2
                continue
        out.append(c)
        i += 1
    return "".join(out)


def _printf(fmt, args):
    """printf "$fmt" "$@" у tf: только %s и %%; другого в словаре нет — иначе мосту."""
    if "\\" in fmt:
        raise Fallback("printf escapes")
    out = []
    i = 0
    used = 0
    convs = 0
    while i < len(fmt):
        c = fmt[i]
        if c != "%":
            out.append(c)
            i += 1
            continue
        nxt = fmt[i + 1:i + 2]
        if nxt == "%":
            out.append("%")
        elif nxt == "s":
            convs += 1
            out.append(args[used] if used < len(args) else "")
            used += 1
        else:
            raise Fallback("printf spec")
        i += 2
    if len(args) > used and convs:
        raise Fallback("printf reuses format")
    return "".join(out)


def _now():
    return time.time()


# ── Чтение файлов: разбор один раз на содержимое ──────────────────────────────
_MISSING = object()


class _Files(object):
    """Чтение JSON-файлов ядра. Каждый файл читается целиком одним open: ядро пишет их атомарно (rename), и открытый
    файл — всегда один целый вариант. В памяти между запросами держится только то, где нет секретов (каталог
    приложений, cache=True), по содержимому (blake2b): users.json с приватными ключами разбирается заново на каждый
    ответ и не переживает его."""

    def __init__(self):
        self._lock = threading.Lock()
        self._cache = {}

    def read(self, path, cache=False):
        """→ (сырые байты или None — файла нет, разобранное или _BAD / _MISSING)."""
        try:
            with open(path, "rb") as fh:
                raw = fh.read()
        except FileNotFoundError:
            return None, _MISSING
        except OSError:
            raise Fallback("unreadable")
        digest = hashlib.blake2b(raw, digest_size=20).digest() if cache else None
        if cache:
            with self._lock:
                hit = self._cache.get(path)
                if hit is not None and hit[0] == digest:
                    return raw, hit[1]
        try:
            value = _loads(raw)
        except (UnicodeDecodeError, ValueError, RecursionError):
            value = _BAD
        if cache:
            with self._lock:
                if len(self._cache) > 16:
                    self._cache.clear()
                self._cache[path] = (digest, value)
        return raw, value


_BAD = object()


# ── Отпечаток зеркала ─────────────────────────────────────────────────────────
_FN_START = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{")
_CASE_HEAD = re.compile(r"^        ([a-z][a-z0-9-]*)\)$")
_VAR_HEAD = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=")


def _strip_comments(lines):
    return [l.rstrip() for l in lines if l.strip() and not l.lstrip().startswith("#")]


def _index(text):
    """Места исходника bash за один проход: {(вид, имя): текст} — функции с нулевого отступа (до строки «}»),
    ветки диспетчера _action_dispatch_locked (8 пробелов, «имя)» … «            ;;») и его начало до первой ветки
    («pre»), переменные модуля (первое присваивание с нулевого отступа вне функций)."""
    lines = text.split("\n")
    out = {}
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        m = _FN_START.match(line)
        if m:
            body = line[m.end():].strip()
            if body.endswith("}") and body.count("}") == body.count("{") + 1:
                out.setdefault(("fn", m.group(1)), "\n".join(_strip_comments([line])))
                i += 1
                continue
            j = i + 1
            while j < n and lines[j] != "}":
                j += 1
            if j >= n:
                break
            out.setdefault(("fn", m.group(1)), "\n".join(_strip_comments(lines[i:j + 1])))
            if m.group(1) == "_action_dispatch_locked":
                k = i + 1
                while k < j:
                    c = _CASE_HEAD.match(lines[k].rstrip())
                    if c:
                        out.setdefault(("pre", m.group(1)), "\n".join(_strip_comments(lines[i:k])))
                        e = k + 1
                        while e < j and lines[e].rstrip() != "            ;;":
                            e += 1
                        out.setdefault(("case", c.group(1)), "\n".join(_strip_comments(lines[k:e + 1])))
                        k = e
                    k += 1
            i = j + 1
            continue
        m = _VAR_HEAD.match(line)
        if m and ("var", m.group(1)) not in out:
            value = line[m.end():]
            quote = value[:1] if value[:1] in ("'", '"') else ""
            if not quote or value.count(quote) >= 2:
                out[("var", m.group(1))] = line.rstrip()
            else:
                j = i + 1
                while j < n and quote not in lines[j]:
                    j += 1
                if j < n:
                    out[("var", m.group(1))] = "\n".join(l.rstrip() for l in lines[i:j + 1])
                    i = j
        i += 1
    return out


def _index_py(text):
    """Места исходника Python: {(вид, имя): текст} — функции и методы классов верхнего уровня («fn», «имя» или
    «Класс.метод») и ветки if/elif вида `x == "строка"` внутри них («case», «функция:строка»: строка условия и тело
    ветки — как подкоманды CLI). Без docstring и строк-комментариев; файл не разбирается — мест нет."""
    try:
        tree = ast.parse(text)
    except (SyntaxError, ValueError):
        return {}
    lines = text.split("\n")
    out = {}

    def doc_lines(node):
        body = getattr(node, "body", None) or []
        first = body[0] if body else None
        if isinstance(first, ast.Expr) and isinstance(getattr(first, "value", None), ast.Constant) \
                and isinstance(first.value.value, str):
            return set(range(first.lineno, first.end_lineno + 1))
        return set()

    def seg(a, b, skip=()):
        return "\n".join(_strip_comments([lines[n - 1] for n in range(a, b + 1) if n not in skip]))

    def add_fn(name, node):
        start = min([d.lineno for d in node.decorator_list] + [node.lineno])
        skip = doc_lines(node)
        out.setdefault(("fn", name), seg(start, node.end_lineno, skip))
        for sub in ast.walk(node):
            if not isinstance(sub, ast.If) or not sub.body or not isinstance(sub.test, ast.Compare):
                continue
            t = sub.test
            if len(t.ops) != 1 or not isinstance(t.ops[0], ast.Eq) or len(t.comparators) != 1:
                continue
            c = t.comparators[0]
            if isinstance(c, ast.Constant) and isinstance(c.value, str):
                out.setdefault(("case", "%s:%s" % (name, c.value)), seg(sub.lineno, sub.body[-1].end_lineno, skip))

    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            add_fn(node.name, node)
        elif isinstance(node, ast.ClassDef):
            for item in node.body:
                if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    add_fn("%s.%s" % (node.name, item.name), item)
    return out


def _index_json(text):
    """Места каталога действий lib/actions.json: («action», имя) — описание действия, («param», имя) — тип параметра;
    текст — JSON с упорядоченными ключами, без description и mcp (слова и имя для агента ответ моста не меняют)."""
    try:
        doc = json.loads(text)
    except ValueError:
        return {}
    if not isinstance(doc, dict):
        return {}

    def bare(v):
        if isinstance(v, dict):
            return {k: bare(x) for k, x in v.items() if k not in ("description", "mcp")}
        if isinstance(v, list):
            return [bare(x) for x in v]
        return v

    out = {}
    for kind, key in (("action", "actions"), ("param", "param_types")):
        block = doc.get(key)
        if isinstance(block, dict):
            for name, value in block.items():
                out[(kind, name)] = json.dumps(bare(value), ensure_ascii=False, sort_keys=True)
    return out


def index_source(rel, text):
    """Места файла ядра по его виду: .py — _index_py, .json — _index_json, остальное — bash (_index)."""
    if rel.endswith(".py"):
        return _index_py(text)
    if rel.endswith(".json"):
        return _index_json(text)
    return _index(text)


def place_hash(rel, kind, name, part):
    """Отпечаток одного места ядра (PLACES): 16 знаков sha256 его текста; места нет — пусто."""
    if part is None:
        return ""
    return hashlib.sha256(("%s|%s|%s\n%s\n" % (rel, kind, name, part)).encode("utf-8", "surrogateescape")).hexdigest()[:16]


# ── Само чтение ──────────────────────────────────────────────────────────────
class CoreRead(object):
    """Частые чтения ядра без моста. root — корень продукта (каталог install.sh), lib — его lib/."""

    def __init__(self, root, environ=None, lock_wait=None):
        self.root = os.path.abspath(root)
        self.lib = os.path.join(self.root, "lib")
        self.env = os.environ if environ is None else environ
        env = self.env.get
        # Пути — как у ядра (lib/common.sh и модули): те же переменные окружения, те же умолчания.
        self.gdir = env("GOAMNEZIA_DIR") or "/opt/goamnezia"
        self.config_file = env("CONFIG_FILE") or os.path.join(self.gdir, "config.json")
        self.users_file = env("USERS_FILE") or os.path.join(self.gdir, "users.json")
        self.lock_dir = env("GOAMNEZIA_LOCK_DIR") or "/run/goamnezia"
        self.lock_file = env("GOAMNEZIA_LOCK_FILE") or os.path.join(self.lock_dir, "config.lock")
        self.audit_log = env("GOAMNEZIA_AUDIT_LOG") or "/var/log/goamnezia-audit.log"
        self.bot_dir = env("BOT_DIR") or "/opt/goamnezia-bot"
        self.subs_dir = env("GOAMNEZIA_SUBS_DIR") or os.path.join(self.gdir, "subs")
        self.pages_dir = env("GOAMNEZIA_PAGES_DIR") or os.path.join(self.gdir, "pages")
        self.share_dir = env("GOAMNEZIA_SHARE_DIR") or os.path.join(self.lock_dir, "share")
        self.dry = env("GOAMNEZIA_DRY_RUN", "0") == "1"
        path = env("PATH") or ""
        parts = path.split(":") if path else []
        for d in _SYS_PATH:
            if d not in parts:
                parts.append(d)
        self.path = ":".join(parts)
        self.lock_wait = self._lock_wait(lock_wait if lock_wait is not None else env("GOAMNEZIA_READ_LOCK_WAIT"))
        self._tls = threading.local()
        self.files = _Files()
        self._mlock = threading.Lock()
        self._mods = {}
        self._texts = {}
        self._fps = {}
        self._dicts = {}
        self._said = set()

    @staticmethod
    def _lock_wait(value):
        """GOAMNEZIA_READ_LOCK_WAIT: секунды от 0 до READ_LOCK_WAIT_MAX; пусто, не число, nan, ±inf — READ_LOCK_WAIT."""
        if value is None or value == "":
            return READ_LOCK_WAIT
        try:
            wait = float(value)
        except (TypeError, ValueError):
            return READ_LOCK_WAIT
        if not math.isfinite(wait):
            return READ_LOCK_WAIT
        return min(max(wait, 0.0), READ_LOCK_WAIT_MAX)

    # ── Публичное ────────────────────────────────────────────────────────────
    def answer(self, action, params=None, lang="", who="", timeout=None):
        """Ответ моста на чтение или None — пусть отвечает мост. timeout — срок ответа (не больше ANSWER_TIMEOUT)."""
        if action not in ACTIONS or not self.mirror_ok(action):
            return None
        params = dict(params or {})
        fn = getattr(self, "_a_" + action.replace("-", "_"))
        budget = ANSWER_TIMEOUT
        if timeout is not None:
            try:
                t = float(timeout)
            except (TypeError, ValueError):
                t = ANSWER_TIMEOUT
            budget = min(max(t, 0.0), ANSWER_TIMEOUT) if math.isfinite(t) else ANSWER_TIMEOUT
        call = _Call(time.monotonic() + budget)
        outer = getattr(self._tls, "call", None)
        self._tls.call = call
        try:
            for _ in range(2):
                try:
                    return fn(params, self._lang(lang), who or self.env.get("GOAMNEZIA_WHO") or "ssh")
                except _NeedAddrs:
                    if call.addrs is not None:
                        return None
                    call.addrs = self._edge_addrs()     # без замка ядра; чтение — заново, с адресами
            return None
        except Fallback:
            return None
        finally:
            self._tls.call = outer

    def _left(self, cap):
        """Сколько может ждать шаг ответа: не больше cap и не дольше срока answer(); срок вышел — мосту."""
        call = getattr(self._tls, "call", None)
        if call is None:
            return cap
        left = call.deadline - time.monotonic()
        if left <= 0:
            raise Fallback("deadline")
        return min(cap, left)

    def fingerprints(self):
        """{действие: отпечаток мест ядра} — сейчас, по файлам на диске; место не нашлось — пусто."""
        return {a: self._fingerprint(a) for a in ACTIONS}

    def place_hashes(self):
        """{«файл|вид|имя»: отпечаток места} — сейчас, по файлам на диске; места нет — пусто."""
        out = {}
        for items in MIRROR.values():
            for item in items:
                out.setdefault("|".join(item), self._place_hash(*item))
        return out

    def mirror_ok(self, action):
        want = RECORDED.get(action) or ""
        have = self._fingerprint(action)
        if want and have == want:
            return True
        if action not in self._said:
            self._said.add(action)
            sys.stderr.write("[core_read] %s: места ядра изменились после сверки (отпечаток %s, ждали %s) — "
                             "чтение через мост; сверка: python3 tests/check_core_read.py\n"
                             % (action, have or "—", want or "—"))
        return False

    # ── Отпечаток ────────────────────────────────────────────────────────────
    def _places(self, rel):
        """Места исходника (_index) по файлу; пересчёт — когда файл сменился (inode, mtime, размер)."""
        path = os.path.join(self.root, rel)
        try:
            st = os.stat(path)
        except OSError:
            return None
        sig = (st.st_ino, st.st_mtime_ns, st.st_size)
        with self._mlock:
            hit = self._texts.get(rel)
            if hit is not None and hit[0] == sig:
                return hit[1]
        try:
            with open(path, "r", encoding="utf-8", errors="surrogateescape") as fh:
                places = index_source(rel, fh.read())
        except OSError:
            return None
        with self._mlock:
            self._texts[rel] = (sig, places)
        return places

    def _place_hash(self, rel, kind, name):
        places = self._places(rel)
        return place_hash(rel, kind, name, places.get((kind, name)) if places is not None else None)

    def _fingerprint(self, action):
        """Отпечаток мест действия; пересчёт — когда сменился хоть один его файл (inode, mtime, размер): на каждый
        ответ — stat десятка файлов, а не хеши полутора сотен мест."""
        items = MIRROR.get(action, ())
        sig = []
        for rel in sorted({rel for rel, _, _ in items}):
            try:
                st = os.stat(os.path.join(self.root, rel))
            except OSError:
                return ""
            sig.append((rel, st.st_ino, st.st_mtime_ns, st.st_size))
        sig = tuple(sig)
        with self._mlock:
            hit = self._fps.get(action)
            if hit is not None and hit[0] == sig:
                return hit[1]
        h = hashlib.sha256()
        for item in items:
            ph = self._place_hash(*item)
            if not ph:
                return ""
            h.update(("%s=%s\n" % ("|".join(item), ph)).encode("utf-8", "surrogateescape"))
        fp = h.hexdigest()[:16]
        with self._mlock:
            self._fps[action] = (sig, fp)
        return fp

    def _var(self, rel, name):
        """Значение переменной модуля bash (кавычки — как у bash: одинарные дословно)."""
        places = self._places(rel)
        part = places.get(("var", name)) if places is not None else None
        if part is None:
            raise Fallback("no var")
        value = part[len(name) + 1:]
        if value[:1] == "'" and value.endswith("'"):
            return value[1:-1]
        if value[:1] == '"' and value.endswith('"'):
            return _unescape_dq(value[1:-1])
        return value

    # ── Модули ядра на Python (awgkeys, shortlinks) ──────────────────────────
    def _module(self, name, path):
        try:
            st = os.stat(path)
        except OSError:
            raise Fallback("no module")
        sig = (st.st_ino, st.st_mtime_ns, st.st_size)
        with self._mlock:
            hit = self._mods.get(path)
            if hit is not None and hit[0] == sig:
                return hit[1]
        spec = importlib.util.spec_from_file_location("ga_core_read_%s_%d" % (name, st.st_ino), path)
        if spec is None or spec.loader is None:
            raise Fallback("no module")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        with self._mlock:
            self._mods[path] = (sig, mod)
        return mod

    def _awgkeys(self):
        return self._module("awgkeys", self.env.get("GOAMNEZIA_AWGKEYS") or os.path.join(self.lib, "awgkeys.py"))

    def _shortlinks_path(self):
        work = os.path.join(self.gdir, "lib", "shortlinks.py")
        return work if os.path.isfile(work) else os.path.join(self.lib, "shortlinks.py")

    def _which(self, name):
        return shutil.which(name, path=self.path)

    # ── Замок ядра на чтение ─────────────────────────────────────────────────
    @contextlib.contextmanager
    def locked(self):
        """Общий замок ядра на время чтения файлов: LOCK_SH на config.lock, не дольше lock_wait ожидания (и не дольше
        срока ответа)."""
        wait = self._left(self.lock_wait)
        try:
            fd = os.open(self.lock_file, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
        except OSError:
            fd = -1
        held = False
        if fd >= 0:
            deadline = time.monotonic() + wait
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
                    held = True
                    break
                except OSError as exc:
                    if exc.errno not in (errno.EAGAIN, errno.EACCES, errno.EWOULDBLOCK):
                        break
                    if time.monotonic() >= deadline:
                        break
                    time.sleep(0.02)
        try:
            yield held
        finally:
            if fd >= 0:
                try:
                    if held:
                        fcntl.flock(fd, fcntl.LOCK_UN)
                finally:
                    os.close(fd)

    # ── config.json и users.json ─────────────────────────────────────────────
    def _config(self):
        """Разобранный config.json; нет файла — пустой объект (ga_config_get отвечает пусто); битый — мосту."""
        raw, value = self.files.read(self.config_file)
        if value is _MISSING:
            return {}
        if value is _BAD or not isinstance(value, dict):
            raise Fallback("config")
        return value

    def _cfg(self, cfg, *path):
        """ga_config_get <путь>: текст значения (как jq -r), null и нет поля — пусто; объект и массив — мимо."""
        node = cfg
        for key in path:
            if node is None:
                return ""
            if not isinstance(node, dict):
                return ""
            node = node.get(key)
        if node is None:
            return ""
        return _sub(_raw(node))

    def _cfg_node(self, cfg, *path):
        node = cfg
        for key in path:
            if not isinstance(node, dict):
                return None
            node = node.get(key)
        return node

    def _users(self):
        """users.json по правилу ga_users_load: нет файла — скелет; не объект или .users не массив — мосту
        (он скажет users_corrupt и спасёт копию)."""
        raw, value = self.files.read(self.users_file)
        if value is _MISSING:
            return {"schema": 1, "users": []}
        if value is _BAD or not isinstance(value, dict):
            raise Fallback("users")
        users = _alt(value.get("users"), [])
        if not isinstance(users, list):
            raise Fallback("users shape")
        return value

    @staticmethod
    def _user_rows(udoc):
        users = _alt(udoc.get("users"), [])
        if not isinstance(users, list):
            raise Fallback("users shape")
        for u in users:
            if not isinstance(u, dict):
                raise Fallback("user shape")
        return users

    def _user(self, udoc, name):
        """ga_users_get <имя>: ровно одна запись; нет её — мосту (user_not_found), две — тоже."""
        hits = [u for u in self._user_rows(udoc) if u.get("name") == name]
        if len(hits) != 1:
            raise Fallback("user")
        return hits[0]

    def _user_or_none(self, udoc, name):
        hits = [u for u in self._user_rows(udoc) if u.get("name") == name]
        if len(hits) > 1:
            raise Fallback("dup")
        return hits[0] if hits else None

    @staticmethod
    def _public_peer(p):
        if p is None:
            return {"has_key": False}
        if not isinstance(p, dict):
            raise Fallback("peer shape")
        pk = _alt(p.get("privkey"), "")
        q = dict(p)
        q["has_key"] = pk != ""
        q.pop("privkey", None)
        q.pop("psk", None)
        return q

    def _public_user(self, u):
        """ga_users_public_filter — без приватных ключей и PSK (users.json разобран на этот ответ и дальше не живёт,
        поэтому вложенное — traffic и прочее — не копируется)."""
        if not isinstance(u, dict):
            raise Fallback("user shape")
        peers = _alt(u.get("peers"), {})
        if not isinstance(peers, dict):
            raise Fallback("peers shape")
        return {
            "name": u.get("name"), "label": u.get("label"), "created": u.get("created"), "enabled": u.get("enabled"),
            "quota_bytes": u.get("quota_bytes"), "expires": u.get("expires"), "traffic": u.get("traffic"),
            "imported": _alt(u.get("imported"), False),
            "endpoint_ip": _alt(u.get("endpoint_ip"), ""),
            "disabled_reason": _alt(u.get("disabled_reason"), ""),
            "profiles": sorted(peers.keys()),
            "peers": {k: self._public_peer(v) for k, v in peers.items()},
        }

    # ── Язык и слова ─────────────────────────────────────────────────────────
    def _install_lang(self):
        """detect_language: config.json .lang // .language → маркер .language → ru."""
        lang = ""
        raw, cfg = self.files.read(self.config_file)
        if cfg is not _MISSING and cfg is not _BAD and isinstance(cfg, dict):
            v = _alt(cfg.get("lang"), None)
            if v is None:
                v = _alt(cfg.get("language"), None)
            if v is not None:
                lang = _sub(_raw(v))
        elif cfg is _BAD:
            raise Fallback("config")
        if not lang:
            try:
                with open(os.path.join(self.gdir, ".language"), "rb") as fh:
                    lang = re.sub(r"\s", "", fh.read(2).decode("utf-8", "replace"))
            except OSError:
                lang = ""
        return lang if lang in ("en", "ru") else "ru"

    def _lang(self, call_lang):
        """Язык словаря моста: язык вызова (GOAMNEZIA_CALL_LANG) или язык установки; файла нет — en."""
        lang = call_lang if call_lang in ("ru", "en") else self._install_lang()
        if not re.fullmatch(r"[a-z]{2}", lang):
            lang = "en"
        if not os.path.isfile(os.path.join(self.lib, "lang", lang + ".sh")):
            lang = "en"
        return lang

    def _dict(self, lang):
        """Словарь load_language: ядро lib/lang/<язык>.sh, затем фрагменты .d/*.sh по алфавиту."""
        base = os.path.join(self.lib, "lang")
        files = [os.path.join(base, lang + ".sh")]
        frag = os.path.join(base, lang + ".d")
        try:
            files += [os.path.join(frag, f) for f in sorted(os.listdir(frag)) if f.endswith(".sh")
                      and os.path.isfile(os.path.join(frag, f))]
        except OSError:
            pass
        sig = []
        for f in files:
            try:
                st = os.stat(f)
            except OSError:
                raise Fallback("dict")
            sig.append((f, st.st_ino, st.st_mtime_ns, st.st_size))
        sig = tuple(sig)
        with self._mlock:
            hit = self._dicts.get(lang)
            if hit is not None and hit[0] == sig:
                return hit[1]
        words, odd = {}, set()
        for f in files:
            try:
                with open(f, "r", encoding="utf-8", errors="surrogateescape") as fh:
                    lines = fh.read().split("\n")
            except OSError:
                raise Fallback("dict")
            for line in lines:
                m = _I18N_LINE.match(line)
                if m:
                    words[m.group(1)] = _unescape_dq(m.group(2))
                    odd.discard(m.group(1))
                    continue
                m = _I18N_ANY.match(line)
                if m:
                    odd.add(m.group(1))
        with self._mlock:
            self._dicts[lang] = (sig, (words, odd))
        return words, odd

    def _t(self, lang, key):
        words, odd = self._dict(lang)
        if key in odd:
            raise Fallback("dict line")
        return _sub(words.get(key) or key)

    def _tf(self, lang, key, *args):
        words, odd = self._dict(lang)
        if key in odd:
            raise Fallback("dict line")
        return _sub(_printf(words.get(key) or key, list(args)))

    # ── Ответ моста ──────────────────────────────────────────────────────────
    def _emit(self, lang, fields):
        """ga_emit_json success «ok» k=v…: status и message первыми."""
        out = {"status": "success", "message": self._t(lang, "act_ok")}
        for k, v in fields:
            out[k] = v
        _check_plain(out)
        return out

    def _merged(self, lang, obj):
        """_action_emit_merged: объект модуля + status и message в конце (существующие — на своём месте)."""
        out = dict(obj)
        out["status"] = "success"
        out["message"] = self._t(lang, "act_ok")
        _check_plain(out)
        return out

    def _audit(self, who, action, details):
        """ga_audit: строка stage=effect, как пишет ядро."""
        path = self.audit_log
        d = os.path.dirname(path) or "."
        try:
            if not os.path.isdir(d):
                os.makedirs(d, exist_ok=True)
            if not os.path.exists(path):
                os.close(os.open(path, os.O_WRONLY | os.O_CREAT, 0o600))
                os.chmod(path, 0o600)
        except OSError:
            return
        if who in ("panel",) or who.startswith("panel:"):
            iface = "panel"
        elif who == "bot" or who.startswith("bot:"):
            iface = "bot"
        elif who.startswith("agent:") or who == "mcp" or who.startswith("mcp:"):
            iface = "mcp"
        else:
            iface = "ssh"
        line = ('{"ts":"%s","iface":"%s","stage":"effect","who":"%s","action":"%s","details":"%s"}\n'
                % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(_now())), iface, _json_str(who),
                   _json_str(action), _json_str(details)))
        try:
            fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        except OSError:
            return
        try:
            os.write(fd, line.encode("utf-8", "surrogateescape"))
        except OSError:
            pass
        finally:
            os.close(fd)

    # ── Профили и адрес сервера ──────────────────────────────────────────────
    def _profile_field(self, cfg, p, field):
        """ga_profile_field: поле из config.json, иначе умолчание (у порта умолчания нет — пусто)."""
        v = self._cfg(cfg, "profiles", p, field)
        if v and v != "null":
            return v
        return _PROFILE_DEFAULTS.get((p, field), "")

    def _installed(self, cfg, p):
        v = self._cfg(cfg, "profiles", p, "installed_at")
        return bool(v) and v != "null"

    def _profile_line(self, cfg, p):
        """ga_profile_line: поле line; без него — линия по params (awgkeys detect-line); иначе умолчание."""
        line = self._cfg(cfg, "profiles", p, "line")
        if _LINE_RE.fullmatch(line):
            return line
        params = self._cfg_node(cfg, "profiles", p, "params")
        if isinstance(params, dict) and params:
            _check_plain(params)
            try:
                ak = self._awgkeys()
                got = re.sub(r"\s", "", str(ak.detect_line(ak.normalize_params(json.loads(json.dumps(params))))))
            except Fallback:
                raise
            except Exception:                           # noqa: BLE001 — у моста: 2>/dev/null, линия по умолчанию
                got = ""
            if _LINE_RE.fullmatch(got):
                return got
        return _PROFILE_DEFAULTS.get((p, "line"), "")

    def _pro_domain(self, cfg):
        """ga_export_pro_domain: домен в Endpoint только в Pro с настоящим сертификатом."""
        if self._cfg(cfg, "mode") != "pro":
            return ""
        if self._cfg(cfg, "site", "cert") == "selfsigned":
            return ""
        d = self._cfg(cfg, "domain")
        if not d or d == "null":
            return ""
        if valid_ip(d) or not valid_host(d):
            return ""
        return d

    def _edge_list(self):
        """ga_edge_list для чтения под замком: адреса, собранные answer() до замка. Ещё не собраны — _NeedAddrs:
        answer() отпустит замок, соберёт их (_edge_addrs) и повторит чтение."""
        call = getattr(self._tls, "call", None)
        if call is None:
            return self._edge_addrs()                   # не из answer(): отладка, тесты
        if call.addrs is None:
            raise _NeedAddrs()
        return call.addrs

    def _edge_addrs(self):
        """ga_edge_list: внешние IPv4 машины (стенд — GOAMNEZIA_EDGE_IPS_STUB), множество строк. Без замка ядра."""
        if self.dry and "GOAMNEZIA_EDGE_IPS_STUB" in self.env:
            stub = self.env.get("GOAMNEZIA_EDGE_IPS_STUB") or ""
            return {l for l in stub.replace(" ", "\n").split("\n") if l != ""}
        ip = self._which("ip")
        if not ip:
            return set()
        try:
            proc = subprocess.run([ip, "-4", "-o", "addr", "show", "scope", "global"], stdin=subprocess.DEVNULL,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=self._left(5),
                                  check=False)
        except subprocess.TimeoutExpired:
            raise Fallback("ip timeout")
        except OSError:
            return set()
        out = set()
        for line in proc.stdout.decode("utf-8", "replace").split("\n"):
            if line == "":
                continue
            fields = line.split()
            addr = fields[3].split("/")[0] if len(fields) >= 4 else ""
            if _EDGE_PRIVATE.match(addr):
                continue
            out.add(addr)
        return out

    def _endpoint_host(self, cfg, name, user, server_ip=None):
        """ga_export_endpoint_host → (хост, код): 0 — есть, 1 — адреса нет, 2 — свой адрес человека пропал.
        server_ip — GA_EXPORT_SERVER_IP вызывающего; без него ядро спросило бы адрес в сети — это мосту."""
        h = self._cfg(cfg, "endpoint_host")
        pinned = False
        if h and h != "null":
            pinned = True
        else:
            h = self._pro_domain(cfg)
        if not h:
            h = self._cfg(cfg, "server_ip")
        if not h or h == "null":
            if server_ip is None:
                raise Fallback("server ip from the network")
            h = server_ip
        if not h or h == "0.0.0.0" or not valid_host(h):
            return "", 1
        if name and (valid_ip(h) or not pinned):
            own = _sub(_raw(_alt(user.get("endpoint_ip"), ""))) if user is not None else ""
            if own:
                if not valid_ip(own) or own == "0.0.0.0":
                    return "", 2
                addrs = self._edge_list()
                if addrs and own not in addrs:
                    return "", 2
                h = own
        return h, 0

    def _site_domain_ready(self, cfg):
        """ga_site_domain_ready (через ga_pages_domain_ready): Let's Encrypt и домен."""
        c = self._cfg(cfg, "site", "cert")
        if c not in ("letsencrypt", "selfsigned"):
            mode = self._cfg(cfg, "mode")
            c = "letsencrypt" if mode in ("pro", "lite_site") else ""
        return c == "letsencrypt" and bool(self._cfg(cfg, "domain"))

    # ── user-list и user-show ────────────────────────────────────────────────
    def _a_user_list(self, params, lang, who):
        with self.locked():
            udoc = self._users()
            users = [self._public_user(u) for u in self._user_rows(udoc)]
        return self._emit(lang, [("users", users)])

    def _a_user_show(self, params, lang, who):
        name = str(params.get("name") or "")
        if not _NAME_RE.fullmatch(name):
            raise Fallback("name")
        with self.locked():
            udoc = self._users()
            user = self._user(udoc, name)
            pub = self._public_user(user)
            cfg = self._config()
            # GA_EXPORT_SERVER_IP=$(_cfg '.server_ip'): адрес сервера — только из config.json, без сети
            sip = self._cfg(cfg, "server_ip")
            host, rc = self._endpoint_host(cfg, name, user, "" if sip == "null" else sip)
        return self._emit(lang, [("name", name), ("user", pub), ("key_host", host if rc == 0 else ""),
                                 ("key_host_gone", rc == 2)])

    # ── user-key ─────────────────────────────────────────────────────────────
    def _dns(self, cfg):
        """ga_export_dns_json: годные IPv4 из client_dns, иначе 1.1.1.1 и 1.0.0.1."""
        node = self._cfg_node(cfg, "client_dns")
        if isinstance(node, str):
            raise Fallback("client_dns as text")
        kept = []
        if isinstance(node, list) and node:
            for item in node:
                if not isinstance(item, str):
                    continue
                for line in item.split("\n"):
                    if line and valid_ip(line):
                        kept.append(line)
            if kept:
                return kept
        return list(_DNS_DEFAULT)

    def _params(self, cfg, p):
        node = self._cfg_node(cfg, "profiles", p, "params")
        if node is None or node is False:
            return {}
        if not isinstance(node, dict):
            raise Fallback("params shape")
        return node

    def _key_material(self, name, profile, fmt, lang):
        """export_bundle до картинок: conf, vpn, чанки QR, линия, адрес — под замком ядра."""
        with self.locked():
            udoc = self._users()
            user = self._user(udoc, name)
            cfg = self._config()
            if profile not in ("awg1", "awg2", "awg3") or not self._installed(cfg, profile):
                raise Fallback("profile")
            peers = _alt(user.get("peers"), {})
            if not isinstance(peers, dict):
                raise Fallback("peers shape")
            peer = _alt(peers.get(profile), None)
            if not isinstance(peer, dict):
                raise Fallback("peer")
            priv = peer.get("privkey")
            if (priv is None or priv is False) or _sub(_raw(priv)) == "":
                raise Fallback("no private key")
            disabled = user.get("enabled") is False or peer.get("active") is False
            line = self._profile_line(cfg, profile)
            params = self._params(cfg, profile)
            pub = self._cfg(cfg, "profiles", profile, "server_pubkey")
            port = self._profile_field(cfg, profile, "port")
            host, rc = self._endpoint_host(cfg, name, user)
            dns = self._dns(cfg)
            mtu_raw = _alt(params.get("MTU"), None)
            mtu_txt = _sub(_raw(mtu_raw)) if mtu_raw is not None else ""
            mtu = int(mtu_txt) if (_MTU_RE.fullmatch(mtu_txt) and _MTU_MIN <= int(mtu_txt) <= _MTU_MAX) \
                else _MTU_DEFAULT
            if rc == 2 or not host:
                raise Fallback("address")
            if not pub or not _DIGITS.fullmatch(port):
                raise Fallback("profile incomplete")
            port_n = int(port)
            ak = self._awgkeys()
            conf = vpn = ""
            chunks = []
            data = {"params": params, "client": {"ip": peer.get("ip"), "privkey": peer.get("privkey"),
                                                 "psk": peer.get("psk")},
                    "server": {"pubkey": pub, "endpoint_host": host, "port": port_n}, "dns": dns, "mtu": mtu}
            # Вход awgkeys — как его отдал бы jq: дробь в параметрах jq 1.6 и 1.7 напечатали бы по-разному, и ключ
            # разошёлся бы с мостом молча (в тексте .conf, а не в поле ответа) — такое отвечает мост.
            _check_plain(data)
            try:
                conf_text = _sub(_sub(ak.render_conf(line, json.loads(json.dumps(data)))))
            except Exception:                           # noqa: BLE001 — у моста это conf_failed
                raise Fallback("conf")
            if not conf_text:
                raise Fallback("conf")
            if fmt in ("conf", "qr-conf", "all"):
                conf = conf_text
            if fmt in ("vpn", "qr-vpn", "all"):
                label = _sub(_raw(_alt(user.get("label"), user.get("name"))))
                vdata = {"container": self._profile_field(cfg, profile, "container"), "line": line, "params": params,
                         "conf_text": conf_text, "description": self._tf(lang, "export_vpn_description", label, line),
                         "hostName": host, "port": port_n, "dns": dns,
                         "subnet": self._profile_field(cfg, profile, "subnet")}
                try:
                    vpn = re.sub(r"[ \t\n\r\x0b\x0c]", "", ak.vpn_encode(json.loads(json.dumps(vdata))) + "\n")
                except Exception:                       # noqa: BLE001 — у моста это vpn_failed
                    raise Fallback("vpn")
                if not vpn.startswith("vpn://"):
                    raise Fallback("vpn")
            if fmt in ("qr-vpn", "all") and vpn:
                try:
                    chunks = [_sub(str(c)) for c in ak.qr_chunks(vpn)]
                except Exception:                       # noqa: BLE001 — у моста это chunks_failed
                    raise Fallback("chunks")
                if not chunks:
                    raise Fallback("chunks")
            khost = host
            kport = port
        return {"conf": conf, "vpn": vpn, "chunks": chunks, "line": line, "disabled": disabled,
                "khost": khost, "kport": kport, "fname": self._key_file_base(cfg, name, profile, line) + ".conf"}

    def _key_file_base(self, cfg, name, profile, line):
        """ga_key_file_base (lib/amnezia.sh) — основа имени файла ключа, то же правило, что key_file_base страницы
        (lib/pages_server.py): <имя>-<линия> (anna-2_0), имя — латиница до 10 знаков без ведущих дефисов, длиннее —
        начало и три знака FNV-1a; второй профиль той же линии — номер места и имя на знак короче; линию не узнать —
        имя места."""
        base = re.sub(r"[^A-Za-z0-9_-]", "", name).lstrip("-") or "key"
        ok = bool(re.fullmatch(r"[0-9]\.[0-9]", line))
        dup = False
        if ok:
            node = self._cfg_node(cfg, "profiles")
            for other in sorted(node) if isinstance(node, dict) else []:
                if other == profile or not re.fullmatch(r"awg[0-9]", str(other)):
                    continue
                if other not in ("awg1", "awg2", "awg3"):
                    raise Fallback("profile key")       # линию места вне awg1–3 считает только мост
                if self._profile_line(cfg, other) == line:
                    dup = True
                    break
        lim = 9 if dup else 10
        if len(base) > lim:
            h = 2166136261
            for ch in base:
                h = ((h ^ ord(ch)) * 16777619) & 0xFFFFFFFF
            base = base[:lim - 3] + "%03x" % (h & 0xFFF)
        if not ok:
            return "%s-%s" % (base, profile)
        tag = line.replace(".", "_")
        m = re.fullmatch(r"awg([0-9])", profile)
        if dup and m:
            tag += "-" + m.group(1)
        return "%s-%s" % (base, tag)

    def _qr(self, text):
        """export_qr_png: PNG через qrencode (текст — stdin), base64 одной строкой. Без замка ядра: файлы уже прочитаны."""
        exe = self._which("qrencode")
        if not exe:
            raise Fallback("no qrencode")
        try:
            proc = subprocess.run([exe, "-o", "-"] + list(_QR_ARGS), input=text.encode("utf-8"),
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=self._left(20),
                                  check=False)
        except (OSError, subprocess.SubprocessError):
            raise Fallback("qrencode")
        if proc.returncode != 0 or not proc.stdout:
            raise Fallback("qrencode")
        return base64.b64encode(proc.stdout).decode("ascii")

    def _a_user_key(self, params, lang, who):
        name = str(params.get("name") or "")
        profile = str(params.get("profile") or "")
        fmt = str(params.get("format") or "all")
        if params.get("endpoint"):
            raise Fallback("one-off address")          # разовый адрес проверяет мост (ga_export_key_host_check)
        if not _NAME_RE.fullmatch(name) or fmt not in _FORMATS:
            raise Fallback("args")
        km = self._key_material(name, profile, fmt, lang)
        qrc, qrv = "", []
        if fmt in ("qr-conf", "qr-vpn", "all"):
            if not self._which("qrencode"):
                raise Fallback("no qrencode")
            if fmt != "qr-vpn" and km["conf"]:
                qrc = self._qr(km["conf"])
            if fmt != "qr-conf" and km["vpn"]:
                qrv = [self._qr(c) for c in km["chunks"]]
        khost, kport = km["khost"], km["kport"]
        resp = self._emit(lang, [
            ("name", name), ("profile", profile),
            ("conf", km["conf"]), ("vpn", km["vpn"]), ("qr_conf_png_b64", qrc), ("qr_vpn_png_b64", qrv),
            ("line", km["line"]), ("min_client", _MIN_CLIENT.get(km["line"], "")), ("disabled", km["disabled"]),
            ("key_host", khost), ("key_endpoint", "%s:%s" % (khost, kport) if khost and kport else ""),
            ("key_host_override", False), ("file_name", km["fname"])])
        # Выдача ключа — событие журнала действий, как у ядра (ga_export_audit_key): строка — после того, как ответ
        # собран, иначе отказ после неё дал бы вторую строку уже от моста.
        self._audit(who, "user-key", "%s profile=%s format=%s" % (name, profile, fmt))
        return resp

    # ── Каталоги: порядок имён как у glob bash ───────────────────────────────
    def _c_collation(self):
        for k in ("LC_ALL", "LC_COLLATE", "LANG"):
            v = self.env.get(k)
            if v:
                return v in _C_LOCALES
        return True

    def _glob(self, directory, prefix=""):
        """«"$dir"/<prefix>*» по порядку bash. Чужая локаль и не только id вида p-/s-<hex> — мосту."""
        try:
            names = [n for n in os.listdir(directory) if not n.startswith(".") and n.startswith(prefix)]
        except OSError:
            return []
        names.sort()
        if len(names) > 1 and not self._c_collation() and not all(_HEX_ID.fullmatch(n) for n in names):
            raise Fallback("collation")
        return names

    @staticmethod
    def _jq_r_file(doc, key, default_text):
        """«jq -r '.<key> // <умолчание>' <файл>»: файла нет или не тот вид — пусто; иначе текст значения."""
        if doc is _MISSING:
            return ""
        if doc is _BAD:
            raise Fallback("bad json")
        if doc is None:
            return default_text
        if not isinstance(doc, dict):
            return ""
        v = doc.get(key)
        if v is None or v is False:
            return default_text
        return _sub(_raw(v))

    # ── share-list ───────────────────────────────────────────────────────────
    def _read_num(self, path):
        """ga_share_read_num: файл с одним числом (пробелы срезаются)."""
        try:
            with open(path, "rb") as fh:
                v = re.sub(rb"\s", b"", fh.read())
        except OSError:
            return None
        return int(v) if v and re.fullmatch(rb"[0-9]+", v) else None

    def _alive(self, d):
        """ga_share_alive: «kill -0 <pid>» удался (чужой процесс без прав — как у bash, не жив)."""
        pid = self._read_num(os.path.join(d, "pid"))
        if pid is None:
            return False
        try:
            os.kill(pid, 0)
        except (OSError, OverflowError):
            return False
        return True

    def _a_share_list(self, params, lang, who):
        drain = int(self._var("lib/share.sh", "GA_SHARE_DRAIN_MAX"))
        grace = int(self._var("lib/share.sh", "GA_SHARE_START_GRACE"))
        rows = []
        with self.locked():
            now = int(_now())
            if os.path.isdir(self.share_dir):
                names = self._glob(self.share_dir, "s-")
                # Уборщик ядра (ga_share_sweep) — мутация: найдёт ли он работу? Да — пусть мост и уберёт.
                for n in names:
                    d = os.path.join(self.share_dir, n)
                    if not os.path.isdir(d):
                        continue
                    started = self._read_num(os.path.join(d, "starting"))
                    if started is not None and now - started < grace:
                        continue
                    meta_path = os.path.join(d, "meta.json")
                    if not os.path.isfile(meta_path):
                        raise Fallback("sweep: no meta")
                    raw, meta = self.files.read(meta_path)
                    exp_txt = self._jq_r_file(meta, "expires_epoch", "0") if meta is not _BAD else ""
                    expired = not _DIGITS.fullmatch(exp_txt) or now >= int(exp_txt)
                    if expired or not self._alive(d):
                        busy = self._read_num(os.path.join(d, "busy"))
                        if self._alive(d) and busy is not None and now - busy < drain:
                            continue
                        raise Fallback("sweep: expired")
                for n in names:
                    d = os.path.join(self.share_dir, n)
                    meta_path = os.path.join(d, "meta.json")
                    if not os.path.isfile(meta_path):
                        continue
                    raw, st = self.files.read(os.path.join(d, "state.json"))
                    dl_txt = self._jq_r_file(st, "downloads", "0") if st is not _BAD else ""
                    dl = int(dl_txt) if _DIGITS.fullmatch(dl_txt) else 0
                    raw, meta = self.files.read(meta_path)
                    if meta is _MISSING or meta is _BAD:
                        continue
                    if meta is None:
                        meta = {}
                    if not isinstance(meta, dict):
                        continue
                    exp = _alt(meta.get("expires_epoch"), 0)
                    if isinstance(exp, bool) or not isinstance(exp, int):
                        if isinstance(exp, float):
                            raise Fallback("float")
                        continue                        # jq: строка минус число — ошибка, строка пропущена
                    left = exp - now
                    rows.append(copy.deepcopy({
                        "id": meta.get("id"), "name": meta.get("name"), "profile": meta.get("profile"),
                        "format": meta.get("format"), "file_name": meta.get("file_name"), "port": meta.get("port"),
                        "host": meta.get("host"), "via": meta.get("via"), "size": meta.get("size"),
                        "endpoint": _alt(meta.get("endpoint"), ""), "created": meta.get("created"),
                        "expires": meta.get("expires"), "ttl": meta.get("ttl"),
                        "max_downloads": meta.get("max_downloads"), "cert": meta.get("cert_kind"),
                        "downloads": dl, "seconds_left": 0 if left < 0 else left}))
        return self._merged(lang, {"shares": rows, "count": len(rows)})

    # ── page-list ────────────────────────────────────────────────────────────
    def _a_page_list(self, params, lang, who):
        name = str(params.get("name") or "")
        if name and not _NAME_RE.fullmatch(name):
            raise Fallback("name")
        rows = []
        with self.locked():
            now = int(_now())
            if os.path.isdir(self.pages_dir):
                for n in self._glob(self.pages_dir, "p-"):
                    d = os.path.join(self.pages_dir, n)
                    meta_path = os.path.join(d, "meta.json")
                    if not os.path.isfile(meta_path):
                        continue
                    raw, meta = self.files.read(meta_path)
                    if meta is _BAD:
                        continue                        # ga_pages_expired: jq не разобрал — «истекла»
                    exp_txt = self._jq_r_file(meta, "expires_epoch", "0")
                    if not _DIGITS.fullmatch(exp_txt):
                        continue
                    exp = int(exp_txt)
                    if exp > _SAFE_INT:
                        raise Fallback("big int")
                    if exp > 0 and now >= exp:
                        continue
                    if name and self._jq_r_file(meta, "user", "") != name:
                        continue
                    raw, st = self.files.read(os.path.join(d, "state.json"))
                    if st is _BAD:
                        raise Fallback("bad json")
                    v_txt = self._jq_r_file(st, "visits", "0")
                    visits = int(v_txt) if _DIGITS.fullmatch(v_txt) else 0
                    last = self._jq_r_file(st, "last_visit", "")
                    m = meta if meta is not None else {}
                    if not isinstance(m, dict):
                        continue
                    rows.append(copy.deepcopy({
                        "id": m.get("id"), "user": m.get("user"), "created": m.get("created"),
                        "expires": m.get("expires"), "forever": m.get("forever"), "ttl": m.get("ttl"),
                        "profiles": m.get("profiles"), "mirror": m.get("mirror"), "visits": visits,
                        "last_visit": last, "subscription": m.get("subscription")}))
        return self._merged(lang, {"pages": rows, "count": len(rows)})

    # ── Подписка ─────────────────────────────────────────────────────────────
    def _update_hours(self, cfg):
        """ga_subs_update_hours: subs.update_interval 1–168, иначе GA_SUBS_UPDATE_HOURS."""
        h = self._cfg(cfg, "subs", "update_interval")
        if re.fullmatch(r"[0-9]{1,3}", h) and 1 <= int(h) <= 168:
            return int(h)
        return int(self._var("lib/subs.sh", "GA_SUBS_UPDATE_HOURS"))

    def _owner_gone(self, d, udoc):
        """_ga_subs_owner_gone: владельца подписки нет в users.json (или под его именем другой человек)."""
        if not os.access(self.users_file, os.R_OK) or not os.access(os.path.join(d, "meta.json"), os.R_OK):
            return False
        raw, meta = self.files.read(os.path.join(d, "meta.json"))
        if meta is _BAD or meta is _MISSING:
            return False
        if not isinstance(meta, dict):
            if meta is None:
                return False
            raise Fallback("meta shape")
        n = _alt(meta.get("user"), "")
        want = _alt(meta.get("user_created"), "")
        if n == "":
            return False
        u = next((x for x in self._user_rows(udoc) if x.get("name") == n), None)
        if u is None:
            return True
        if want != "":
            return _alt(u.get("created"), "") != want
        return False

    def _sub_lines(self, cfg, card):
        """ga_subs_lines_json: по линии — первый профиль человека с ключом (awg3 → awg2 → awg1)."""
        if card is None:
            return []
        peers = _alt(card.get("peers"), {})
        if not isinstance(peers, dict):
            raise Fallback("peers shape")
        rows = []
        for p in _PROFILES:
            if peers.get(p) is None:
                continue
            if not self._installed(cfg, p):
                continue
            line = self._profile_line(cfg, p)
            if not _LINE_RE.fullmatch(line):
                continue
            peer = peers.get(p)
            if not isinstance(peer, dict):
                raise Fallback("peer shape")
            has_key = _alt(peer.get("privkey"), "") != ""
            active = not (card.get("enabled") is False or peer.get("active") is False)
            rows.append({"line": line, "profile": p, "has_key": has_key, "active": active})
        out = []
        for l in _SUB_LINES:
            c = [r for r in rows if r["line"] == l]
            if not c:
                continue
            pick = next((r for r in c if r["has_key"]), c[0])
            item = dict(pick)
            item["token"] = _SUB_TOKENS[l]
            out.append(item)
        return out

    def _sub_row(self, d, name, udoc, cfg):
        """ga_subs_row: meta.json и заборы из state.json, линии и подпись человека — без секрета."""
        raw, st = self.files.read(os.path.join(d, "state.json"))
        if st is _BAD:
            raise Fallback("bad json")
        f_txt = self._jq_r_file(st, "fetches", "0")
        fetches = int(f_txt) if _DIGITS.fullmatch(f_txt) else 0
        last = self._jq_r_file(st, "last_fetch", "")
        suffix = self._jq_r_file(st, "last_suffix", "")
        client = self._jq_r_file(st, "last_client", "")
        card = self._user_or_none(udoc, name)
        c = card if card is not None else {}
        label = _sub(_raw(_alt(_alt(c.get("label"), c.get("name")), "")))
        enabled = not (c.get("enabled") is False)
        lines = self._sub_lines(cfg, card)
        raw, meta = self.files.read(os.path.join(d, "meta.json"))
        if meta is _MISSING or meta is _BAD:
            raise Fallback("meta")
        if meta is None:
            meta = {}
        if not isinstance(meta, dict):
            raise Fallback("meta shape")
        if fetches > _SAFE_INT:
            raise Fallback("big int")
        pf = _alt(meta.get("prev_fetches"), 0)
        if not isinstance(pf, int) or isinstance(pf, bool) or pf > _SAFE_INT or pf < 0:
            raise Fallback("prev_fetches")
        return copy.deepcopy({
            "name": name, "label": label or name, "created": _alt(meta.get("created"), ""),
            "rotated": _alt(meta.get("rotated"), ""), "generation": _alt(meta.get("generation"), 1),
            "fetches": fetches, "last_fetch": last, "last_suffix": suffix, "last_client": client, "lines": lines,
            "disabled": not enabled, "prev_fetches": pf,
            "prev_last_fetch": _alt(meta.get("prev_last_fetch"), "")})

    def _sub_exists(self, name):
        d = os.path.join(self.subs_dir, name)
        return bool(_NAME_RE.fullmatch(name)) and os.path.isfile(os.path.join(d, "meta.json")) \
            and os.path.isfile(os.path.join(d, "secret"))

    def _a_sub_list(self, params, lang, who):
        name = str(params.get("name") or "")
        if name and not _NAME_RE.fullmatch(name):
            raise Fallback("name")
        rows = []
        with self.locked():
            udoc = self._users()
            cfg = self._config()
            if os.path.isdir(self.subs_dir):
                names = []
                for n in self._glob_names(self.subs_dir):
                    d = os.path.join(self.subs_dir, n)
                    if not (os.path.isfile(os.path.join(d, "meta.json")) and os.path.isfile(os.path.join(d, "secret"))):
                        continue
                    if not _NAME_RE.fullmatch(n):
                        continue
                    if name and n != name:
                        continue
                    names.append(n)
                if len(names) > 1 and not self._c_collation():
                    raise Fallback("collation")
                for n in names:
                    d = os.path.join(self.subs_dir, n)
                    if self._owner_gone(d, udoc):
                        continue
                    rows.append(self._sub_row(d, n, udoc, cfg))
            ready = self._site_domain_ready(cfg)
            hours = self._update_hours(cfg)
            slow = self._update_slow(hours)
        return self._merged(lang, {"subs": rows, "count": len(rows), "domain_ready": ready, "update_interval": hours,
                                   "update_slow": slow})

    def _update_slow(self, hours):
        """ga_subs_update_slow: приложения каталога, которые обновляют подписку сами реже, чем советует сервер."""
        path = self._catalog_path()
        if not os.access(path, os.R_OK):
            return []
        raw, cat = self.files.read(path, cache=True)
        if cat is _MISSING or cat is _BAD:
            return []                                    # jq не разобрал каталог — у моста []
        if not isinstance(cat, dict):
            raise Fallback("catalog shape")
        apps = _alt(cat.get("apps"), [])
        if not isinstance(apps, list):
            raise Fallback("catalog shape")
        best = {}
        for a in apps:
            if not isinstance(a, dict):
                raise Fallback("catalog shape")
            s = _alt(a.get("subscription"), None)
            for v in (s if isinstance(s, list) else [s]):
                if not isinstance(v, dict):
                    continue
                h = _alt(v.get("update_hours"), 0)
                if isinstance(h, bool) or not isinstance(h, (int, float)):
                    continue
                if not isinstance(h, int) or h > _SAFE_INT:
                    raise Fallback("catalog number")     # дробь и большие числа jq печатает по-своему — решает мост
                if h <= hours:
                    continue
                n = a.get("name")
                if not isinstance(n, str):
                    raise Fallback("catalog type")
                best[n] = max(best.get(n, 0), h)
        return [{"name": n, "hours": h} for n, h in sorted(best.items(), key=lambda x: (-x[1], x[0]))]

    def _glob_names(self, directory):
        try:
            names = [n for n in os.listdir(directory) if not n.startswith(".")]
        except OSError:
            return []
        return sorted(names)

    def _sub_urls(self, cfg, secret, lines):
        """ga_subs_urls_json: адреса подписки; без домена — пауза, пусто."""
        domain = self._cfg(cfg, "domain")
        if not domain or not self._site_domain_ready(cfg):
            return {"base_url": "", "urls": []}
        b = "https://%s/s-%s/" % (domain, secret)
        k = [l for l in lines if l["has_key"]]
        if not k:
            urls = []
        else:
            urls = ([{"suffix": "all.yaml", "format": "mihomo", "line": ""}, {"suffix": "all.txt", "format": "incy", "line": ""}]
                    + [{"suffix": "%s.conf" % l["token"], "format": "conf", "line": l["line"]} for l in k]
                    + [{"suffix": "%s.vpn" % l["token"], "format": "vpn", "line": l["line"]} for l in k]
                    + [{"suffix": "all.vpn", "format": "vpn", "line": ""}])
            for u in urls:
                u["url"] = b + u["suffix"]
        return {"base_url": b, "urls": urls}

    def _catalog_path(self):
        """ga_subs_catalog → ga_pages_clients_json."""
        v = self.env.get("GOAMNEZIA_CLIENTS_JSON")
        if v:
            return v
        work = os.path.join(self.gdir, "lib", "clients.json")
        return work if os.path.isfile(work) else os.path.join(self.lib, "clients.json")

    def _sub_clients(self, cfg, base, lines, label, short):
        """ga_subs_clients_json: кто какой адрес берёт (форма — docs/SUBSCRIPTION.md, «Каталог форматов»)."""
        path = self._catalog_path()
        if not base or not os.access(path, os.R_OK):
            return []
        hours = self._update_hours(cfg)
        minutes = hours * 60
        raw, cat = self.files.read(path, cache=True)
        if cat is _MISSING or cat is _BAD:
            return []                                    # jq не разобрал каталог — у моста clients=[]
        plats = json.loads(self._var("lib/subs.sh", "GA_SUBS_PLATFORMS"))
        egress = json.loads(self._var("lib/subs.sh", "GA_SUBS_EGRESS"))
        mine = [l["line"] for l in lines if l["has_key"]]
        if not mine:
            return []
        if not isinstance(cat, dict) or not isinstance(cat.get("apps"), list):
            raise Fallback("catalog shape")

        def sval(obj, key):
            if not isinstance(obj, dict):
                raise Fallback("catalog shape")
            return obj.get(key)

        def text(v, default=""):
            v = _alt(v, default)
            if not isinstance(v, str):
                raise Fallback("catalog type")
            return v

        def sup_of(sup, line):
            if not isinstance(sup, dict):
                raise Fallback("catalog shape")
            return _alt(sup.get(line), "unknown")

        def link(tpl, url):
            t = _alt(tpl, "")
            if t == "":
                return ""
            if not isinstance(t, str):
                raise Fallback("catalog type")
            if _SUB_INSTALL_RE.match(t):
                if "{name}" in t:
                    t = t.replace("{name}", _uri(label))
                return t.replace("{minutes}", str(minutes)).replace("{url}", _uri(url))
            if "{host_path}" in t:
                return t.replace("{host_path}", url[len("https://"):] if url.startswith("https://") else url)
            if "{url}" in t:
                return t.replace("{url}", url)
            return ""

        def item(line, suffix, s, fmt):
            url = base + suffix
            copy_ = _alt(sval(s, "copy"), "url")
            cmd = _alt(sval(s, "command"), "")
            if cmd == "":
                command = ""
            elif isinstance(cmd, str):
                command = cmd.replace("{iface}", "Wireguard9").replace("{url}", url)
            else:
                raise Fallback("catalog type")
            qr = _alt(sval(s, "qr"), "")
            qr_alt = _alt(sval(s, "qr_alt"), "")
            short_url = _alt(short.get(suffix), "")
            return {"line": line, "suffix": suffix, "url": url, "deeplink": link(sval(s, "deeplink"), url),
                    "command": command, "copy": copy_, "qr": qr, "qr_alt": qr_alt,
                    "key_format": fmt if (qr == "key" or copy_ == "key") else "",
                    "short_url": short_url if isinstance(short_url, str)
                    else json.dumps(short_url, ensure_ascii=False, separators=(",", ":"))}

        found = []
        for i, a in enumerate(cat["apps"]):
            if not isinstance(a, dict):
                raise Fallback("catalog shape")
            sub = a.get("subscription")
            multi = isinstance(sub, list)
            subs = sub if multi else [sub]
            for v, s in enumerate(subs):
                if not isinstance(s, dict):
                    continue
                fname = _alt(s.get("format"), "")
                if not isinstance(fname, str):
                    raise Fallback("catalog type")
                if _SUB_RANK.get(fname) is None:
                    continue
                once = fname in ("vpn", "conf")
                fmt = _SUB_FILES[fname]
                s_lines = _alt(s.get("lines"), [])
                if not isinstance(s_lines, list) or not all(isinstance(x, str) for x in s_lines):
                    raise Fallback("catalog type")
                takes = [x for x in s_lines if x in _SUB_TOKENS]
                aplat = _alt(a.get("platforms"), {})
                if not isinstance(aplat, dict):
                    raise Fallback("catalog shape")
                splat = s.get("platforms")
                if splat is not None and not isinstance(splat, list):
                    raise Fallback("catalog shape")
                pl = []
                for p in plats:
                    if p not in aplat:
                        continue
                    if splat is not None and p not in splat:
                        continue
                    ap = aplat.get(p)
                    if ap is not None and not isinstance(ap, dict):
                        raise Fallback("catalog shape")
                    sup = _alt(ap.get("support") if isinstance(ap, dict) else None, {})
                    if not any(sup_of(sup, l) != "no" for l in mine):
                        continue
                    if once and not any(l in mine and sup_of(sup, l) != "no" for l in takes):
                        continue
                    pl.append((p, sup))
                if not pl:
                    continue
                if once:
                    items = [item(l, _SUB_TOKENS[l] + "." + fmt, s, fmt) for l in takes
                             if l in mine and any(sup_of(sup, l) != "no" for _, sup in pl)]
                else:
                    items = [item("", "all." + fmt, s, fmt)]
                if not items:
                    continue
                aid = _alt(a.get("id"), "")
                if not isinstance(aid, str):
                    raise Fallback("catalog type")
                variant = ""
                if multi:
                    var = s.get("variant")
                    if var is not None and not isinstance(var, dict):
                        raise Fallback("catalog type")
                    variant = text(var.get("ru") if isinstance(var, dict) else None)
                hint = _alt(s.get("hint"), {"ru": "", "en": ""})
                if not isinstance(hint, dict) or not all(isinstance(x, str) for x in hint.values()):
                    raise Fallback("catalog type")
                rec = _alt(s.get("recommended"), [])
                if not isinstance(rec, list):
                    raise Fallback("catalog type")
                found.append((_SUB_RANK[fname], i, v, {
                    "id": aid + ("-" + fmt if multi else ""), "app": aid, "name": text(a.get("name")),
                    "name_en": text(a.get("name_en")), "variant": variant, "group": "once" if once else "auto",
                    "format": fmt, "platforms": [p for p, _ in pl],
                    "update_hours": 0 if once else _alt(s.get("update_hours"), 0),
                    "official": a.get("official") is True,
                    "recommended": len([r for r in rec if any(p == r for p, _ in pl)]) > 0,
                    "hint": {k: x.replace("{minutes}", str(minutes)) for k, x in hint.items()},
                    "items": items}))
        found.sort(key=lambda t: (t[0], t[1], t[2]))
        tail = dict(egress)
        tail["items"] = [item("", "all.vpn", {}, "vpn")]
        return copy.deepcopy([t[3] for t in found] + [tail])

    def _short(self, name):
        """ga_short_urls: {available, short: {суффикс: адрес}} модулем коротких ссылок; сбой — недоступны."""
        try:
            mod = self._module("shortlinks", self._shortlinks_path())
            links = mod.ShortLinks(gdir=self.gdir, subs_dir=self.subs_dir, bot_dir=self.bot_dir,
                                   lock_dir=self.lock_dir)
            codes = links.codes_of(name)
            out = {"available": links.available(), "short": {s: c["url"] for s, c in codes.items()}}
            return json.loads(json.dumps(out, ensure_ascii=False))
        except Exception:                               # noqa: BLE001 — у моста любой сбой модуля — «недоступны»
            return {"available": False, "short": {}}

    def _a_sub_show(self, params, lang, who):
        name = str(params.get("name") or "")
        if not _NAME_RE.fullmatch(name):
            raise Fallback("name")
        d = os.path.join(self.subs_dir, name)
        with self.locked():
            udoc = self._users()
            cfg = self._config()
            if not self._sub_exists(name) or self._owner_gone(d, udoc):
                raise Fallback("sub_not_found")
            if not self._site_domain_ready(cfg):
                raise Fallback("subs_need_domain")
            row = self._sub_row(d, name, udoc, cfg)
            try:
                with open(os.path.join(d, "secret"), "rb") as fh:
                    secret = re.sub(r"\s", "", fh.read().decode("utf-8", "replace"))
            except OSError:
                raise Fallback("secret")
            if not _SECRET43.fullmatch(secret):
                raise Fallback("secret")
            urls = self._sub_urls(cfg, secret, row["lines"])
            short = self._short(name)
            avail = short.get("available") is True
            smap = _alt(short.get("short"), {})
            if not isinstance(smap, dict):
                smap = {}
            if not (urls["base_url"] and avail):
                smap = {}
            clients = self._sub_clients(cfg, urls["base_url"], row["lines"], row["label"], smap)
            hours = self._update_hours(cfg)
        out = dict(row)
        out.update(urls)
        out["clients"] = clients
        out["new"] = False
        out["paused"] = urls["base_url"] == ""
        out["update_interval"] = hours
        out["short_available"] = avail
        resp = self._merged(lang, out)
        self._audit(who, "sub-show", "user=%s" % name)
        return resp


# ── Командная строка: сверка и отпечаток ─────────────────────────────────────
def write_fingerprints(path, core):
    """Переписать блок отпечатков в этом файле (между метками) нынешними — после сверки модуля с ядром."""
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    head = re.search(r"^# >>> отпечатки.*\n", text, re.M)
    tail = re.search(r"^# <<< отпечатки", text, re.M)
    if head is None or tail is None or tail.start() < head.end():
        raise SystemExit("в %s нет блока отпечатков между метками" % path)
    a, b = head.end(), tail.start()
    rec = core.fingerprints()
    places = core.place_hashes()
    missing = [k for k, v in places.items() if not v]
    if missing:
        raise SystemExit("места ядра не нашлись: %s" % ", ".join(missing))
    block = "RECORDED = {\n" + "".join('    "%s": "%s",\n' % (k, v) for k, v in rec.items()) + "}\n"
    block += "PLACES = {\n" + "".join('    "%s": "%s",\n' % (k, v) for k, v in sorted(places.items())) + "}\n"
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text[:a] + block + text[b:])
    os.replace(tmp, path)
    return rec


def main(argv):
    """python3 core_read.py --fingerprint [--write] — отпечатки мест ядра; --write — записать их в этот файл (после
    сверки: tests/check_core_read.py, tests/test_core_read.py);
    python3 core_read.py <действие> [--k=v]… — ответ быстрого пути одной строкой или код 3 (ответит мост)."""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    core = CoreRead(root)
    if argv[:1] == ["--fingerprint"]:
        if argv[1:2] == ["--write"]:
            rec = write_fingerprints(os.path.abspath(__file__), core)
            print("отпечатки записаны в %s: %s" % (os.path.abspath(__file__), ", ".join(sorted(rec))))
            return 0
        print(json.dumps({"RECORDED": core.fingerprints(), "PLACES": core.place_hashes()}, indent=4,
                         ensure_ascii=False))
        return 0
    if not argv:
        sys.stderr.write("usage: core_read.py --fingerprint [--write] | <action> [--k=v ...]\n")
        return 2
    params = {}
    for a in argv[1:]:
        if a.startswith("--") and "=" in a:
            k, v = a[2:].split("=", 1)
            params[k.replace("-", "_")] = v
    out = core.answer(argv[0], params, os.environ.get("GOAMNEZIA_CALL_LANG", ""),
                      os.environ.get("GOAMNEZIA_WHO", "ssh"))
    if out is None:
        return 3
    sys.stdout.write(json.dumps(out, ensure_ascii=False, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
