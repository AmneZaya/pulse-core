"""
goAmnezia pro — i18n Telegram-бота: язык на пользователя и API t()/tf().

Порт модуля из goTelegram Pro: сменились только пути продукта и язык по
умолчанию. Использование:

    from i18n import t, tf, t_in, set_user_lang, get_user_lang, get_language_name

    msg = t(user_id, "menu_users")
    msg = tf(user_id, "user_added_fmt", name)

Словари лежат рядом с модулем в lang/<code>.json (паритет ключей RU/EN
проверяет tests/check_i18n_bot.py). Выбор языка каждого пользователя хранится
в USER_LANG_FILE — один JSON-словарь user_id → код.

Язык по умолчанию — язык продукта: поле lang в config.json (его меняют SSH-меню,
панель и сам бот — «Настройки → Язык → … для всех»), без него — маркер .language,
без него — переменная GOAMNEZIA_LANG (снимок, который install_bot.sh пишет в .env
при установке), и только потом русский, как у SSH-меню (lib/i18n.sh).
"""

import json
import logging
import os
from pathlib import Path
from typing import Dict, Optional

logger = logging.getLogger(__name__)

# ── Пути ──────────────────────────────────────────────────────────────────
# Все пути с переопределением через окружение: тесты и стенды подменяют
# каталоги, и запись user_langs.json обязана уехать за ними, а не в /opt.
_MODULE_DIR = Path(__file__).resolve().parent
LANG_DIR = _MODULE_DIR / "lang"
GOAMNEZIA_DIR = Path(os.getenv("GOAMNEZIA_DIR", "/opt/goamnezia"))
BOT_DIR = Path(os.getenv("GOAMNEZIA_BOT_DIR", "/opt/goamnezia-bot"))
USER_LANG_FILE = BOT_DIR / "user_langs.json"
GOAMNEZIA_CONFIG = GOAMNEZIA_DIR / "config.json"
GOAMNEZIA_LANG_MARKER = GOAMNEZIA_DIR / ".language"

# Поддерживаемые коды; держать в согласии с lang/*.json
SUPPORTED_LANGS = ("ru", "en")
FALLBACK_LANG = "ru"

LANG_NAMES = {
    "en": "English",
    "ru": "Русский",
}


def _detect_default_lang() -> str:
    """Язык продукта: config.json (lang/language) → маркер .language → GOAMNEZIA_LANG → ru.

    Переменная из .env — последней, а не первой. Она снимок языка на момент
    установки: раньше она стояла выше config.json, и смена языка «для всех» (из
    SSH, панели или бота) умолчание бота не меняла никогда, хотя экран это обещал
    (находка BOT-11). config.json читается при каждом обращении — смена видна сразу.
    """
    candidates = []
    try:
        if GOAMNEZIA_CONFIG.exists():
            with open(GOAMNEZIA_CONFIG, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict):
                # `lang` — имя поля по контракту §3.1; `language` — так его
                # называл goTelegram, и так пишут старые копии конфига.
                candidates.extend([data.get("lang"), data.get("language")])
    except Exception as e:  # noqa: BLE001 — язык не повод падать
        logger.warning("failed to read goAmnezia config for language: %s", e)
    try:
        if GOAMNEZIA_LANG_MARKER.exists():
            candidates.append(GOAMNEZIA_LANG_MARKER.read_text(encoding="utf-8").strip()[:2])
    except Exception as e:  # noqa: BLE001
        logger.warning("failed to read goAmnezia language marker: %s", e)
    # Бот без продукта рядом (стенд, установка раньше goAmnezia) — язык установщика
    candidates.append(os.getenv("GOAMNEZIA_LANG", ""))
    for raw in candidates:
        code = str(raw or "").strip().lower()
        if code in SUPPORTED_LANGS:
            return code
    return FALLBACK_LANG


# ── Кэши ──────────────────────────────────────────────────────────────────
_LANG_CACHE: Dict[str, Dict[str, str]] = {}
_USER_LANGS: Dict[int, str] = {}
_USER_LANGS_LOADED = False


def _load_lang_file(code: str) -> Dict[str, str]:
    """Загрузить lang/<code>.json в кэш и вернуть словарь."""
    if code in _LANG_CACHE:
        return _LANG_CACHE[code]
    path = LANG_DIR / f"{code}.json"
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            raise ValueError("lang file must contain a top-level object")
        _LANG_CACHE[code] = data
        return data
    except FileNotFoundError:
        logger.warning("lang file not found: %s", path)
    except Exception as e:  # noqa: BLE001
        logger.warning("failed to load %s: %s", path, e)
    _LANG_CACHE[code] = {}
    return _LANG_CACHE[code]


def _load_user_langs() -> None:
    """Прочитать выбор языка пользователей из USER_LANG_FILE."""
    global _USER_LANGS, _USER_LANGS_LOADED
    _USER_LANGS_LOADED = True
    try:
        if USER_LANG_FILE.exists():
            with open(USER_LANG_FILE, "r", encoding="utf-8") as f:
                raw = json.load(f)
            if isinstance(raw, dict):
                _USER_LANGS = {
                    int(k): v for k, v in raw.items()
                    if isinstance(v, str) and v in SUPPORTED_LANGS
                }
    except Exception as e:  # noqa: BLE001
        logger.warning("failed to load user_langs: %s", e)
        _USER_LANGS = {}


def _save_user_langs() -> None:
    """Сохранить выбор языка пользователей (атомарно: tmp рядом + replace)."""
    tmp = None
    try:
        USER_LANG_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = USER_LANG_FILE.with_suffix(".json.tmp.%d" % os.getpid())
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(
                {str(k): v for k, v in _USER_LANGS.items()},
                f, ensure_ascii=False, indent=2,
            )
        os.chmod(tmp, 0o600)
        os.replace(tmp, USER_LANG_FILE)
    except Exception as e:  # noqa: BLE001
        logger.warning("failed to save user_langs: %s", e)
        try:
            if tmp is not None and tmp.exists():
                tmp.unlink()
        except OSError:
            pass


# ── Публичный API ─────────────────────────────────────────────────────────

def get_user_lang(user_id: Optional[int]) -> str:
    """Код языка пользователя (или язык продукта по умолчанию)."""
    if not _USER_LANGS_LOADED:
        _load_user_langs()
    if user_id is None:
        return _detect_default_lang()
    return _USER_LANGS.get(int(user_id), _detect_default_lang())


def set_user_lang(user_id: int, code: str) -> bool:
    """Запомнить язык пользователя и сохранить на диск."""
    if not _USER_LANGS_LOADED:
        _load_user_langs()
    code = (code or "").strip().lower()
    if code not in SUPPORTED_LANGS:
        return False
    _USER_LANGS[int(user_id)] = code
    _save_user_langs()
    return True


def get_language_name(code: str) -> str:
    return LANG_NAMES.get(code, code)


def t(user_id: Optional[int], key: str, default: Optional[str] = None) -> str:
    """Перевод ключа для пользователя. Промах → другой язык → default/ключ.

    При промахе печатается сам ключ: так дыра в словаре видна на экране, а
    не прячется за пустой строкой (tests/check_i18n_bot.py ловит её раньше).
    """
    code = get_user_lang(user_id)
    table = _load_lang_file(code)
    if key in table:
        return table[key]
    for other in SUPPORTED_LANGS:
        if other == code:
            continue
        other_table = _load_lang_file(other)
        if key in other_table:
            return other_table[key]
    return default if default is not None else key


def t_in(lang: str, key: str, default: Optional[str] = None) -> str:
    """Перевод в конкретный язык, а не в язык пользователя.

    Нужен для set_my_commands (описания команд по языку клиента) и для
    уведомлений админам, у которых языка ещё может не быть в user_langs.
    """
    table = _load_lang_file(lang if lang in SUPPORTED_LANGS else FALLBACK_LANG)
    if key in table:
        return table[key]
    return default if default is not None else key


def tf(user_id: Optional[int], key: str, *args, default: Optional[str] = None) -> str:
    """Перевод с подстановкой позиционных аргументов в стиле printf (%s)."""
    template = t(user_id, key, default=default)
    try:
        return template % args if args else template
    except (TypeError, ValueError):
        return template

def days(user_id: Optional[int], n) -> str:
    """Число дней вместе со словом: «1 день», «2 дня», «5 дней», «1 day».

    Внутри строки словаря склонять нечем, поэтому число и слово приходят в неё
    одним аргументом — как в bash-части продукта (ga_days в lib/common.sh).
    Правило выбора формы называет сам словарь ключом days_rule: по-русски
    «last-digit» (21 — день), по-английски «only-one» (21 — days). Незнакомое
    правило считаем английским. Не число возвращаем как есть.
    """
    try:
        num = int(str(n).strip())
    except (TypeError, ValueError):
        return str(n)
    # Ключи назван каждый своим литералом, а не переменной: так их видит
    # tests/check_i18n_bot.py и не объявляет мёртвыми.
    if t(user_id, "days_rule") == "last-digit":
        two, last = abs(num) % 100, abs(num) % 10
        if 11 <= two <= 14:
            return tf(user_id, "days_many", num)
        if last == 1:
            return tf(user_id, "days_one", num)
        if 2 <= last <= 4:
            return tf(user_id, "days_few", num)
        return tf(user_id, "days_many", num)
    return tf(user_id, "days_one", num) if abs(num) == 1 else tf(user_id, "days_many", num)
