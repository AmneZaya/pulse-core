#!/bin/bash
# goAmnezia pro — движок интернационализации (порт из goTelegram Pro).
#
# Использование:
#   source lib/i18n.sh
#   load_language "ru"          # или "en"
#   echo "$(t menu_users)"      # перевод
#   printf '%s\n' "$(tf banner_title "$GOAMNEZIA_VERSION")"   # с подстановкой
#
# Отличие от goTelegram: словарь разбит на ядро (lib/lang/<lang>.sh) и фрагменты
# по модулям (lib/lang/<lang>.d/<module>.sh). Разбиение нужно не для красоты:
# модули продукта пишутся параллельно разными исполнителями, и один общий
# файл словаря превращается в постоянный конфликт слияния на каждой строке.

# ── Глобальное состояние i18n ────────────────────────────────────────────────
declare -gA I18N
LANG_CODE="${LANG_CODE:-ru}"
LANG_FILE=""
LANG_FRAGMENTS=""

# ── Загрузка языка ───────────────────────────────────────────────────────────
# Заполняет ассоциативный массив I18N из lib/lang/<lang>.sh, затем из всех
# lib/lang/<lang>.d/*.sh в алфавитном порядке. Нет запрошенного языка — берём en.
load_language() {
    local lang="${1:-ru}"
    # Санитизация: пропускаем только двухбуквенные коды. Значение приходит из
    # config.json и маркера на диске, а идёт в путь к файлу, который мы source-им.
    if ! [[ "$lang" =~ ^[a-z]{2}$ ]]; then
        lang="en"
    fi

    local lang_dir
    # Абсолютный путь без ссылки — каталог прямо из него, без процессов: словарь грузит КАЖДЫЙ вызов моста, а
    # readlink, dirname и basename ниже стоили два десятка форков на вызов (CPU-03). Иначе — как раньше.
    if [[ "${BASH_SOURCE[0]}" == /*/* ]] && [ ! -L "${BASH_SOURCE[0]}" ]; then
        lang_dir="${BASH_SOURCE[0]%/*}/lang"
    else
        lang_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lang"
    fi
    local lang_file="${lang_dir}/${lang}.sh"

    if [ ! -f "$lang_file" ]; then
        lang_file="${lang_dir}/en.sh"
        lang="en"
    fi

    [ -f "$lang_file" ] || return 1

    # Чистим прежние ключи и грузим ядро словаря
    I18N=()
    # shellcheck disable=SC1090
    source "$lang_file"

    # Фрагменты модулей. Порядок алфавитный и потому воспроизводимый: если два
    # фрагмента случайно объявят один ключ, побеждать всегда будет один и тот же,
    # а не тот, чьё имя файла оказалось первым на конкретной ФС. Дубликаты между
    # фрагментами ловит tests/check_i18n_ssh.py — здесь мы их молча не чиним.
    LANG_FRAGMENTS=""
    local frag_dir="${lang_dir}/${lang}.d" frag
    if [ -d "$frag_dir" ]; then
        for frag in "$frag_dir"/*.sh; do
            # Глоб без совпадений подставляет сам шаблон — отсюда проверка -f
            [ -f "$frag" ] || continue
            # shellcheck disable=SC1090
            source "$frag"
            LANG_FRAGMENTS="${LANG_FRAGMENTS}${frag##*/} "
        done
    fi

    LANG_CODE="$lang"
    LANG_FILE="$lang_file"
    return 0
}

# ── Перевод: значение по ключу ───────────────────────────────────────────────
# t <key> → перевод (или сам ключ, если его нет в словаре — так пропажа видна)
t() {
    local key="$1"
    local val="${I18N[$key]:-}"
    if [ -z "$val" ]; then
        echo "$key"
    else
        echo "$val"
    fi
}

# ── Перевод + подстановка в стиле printf ─────────────────────────────────────
# tf <key> <arg1> <arg2> ...
tf() {
    local key="$1"
    shift
    local fmt="${I18N[$key]:-$key}"
    # shellcheck disable=SC2059
    printf "$fmt" "$@"
}

# ── Текущий код языка ────────────────────────────────────────────────────────
get_language() {
    echo "$LANG_CODE"
}

# ── Определение языка: config.json → маркер .language → ru ───────────────────
# Дефолт этого продукта — русский: владелец и первые установки русскоязычные.
# В config.json поле называется `lang` (контракт §3.1); `language` читаем тоже,
# потому что так называлось поле в goTelegram и так его пишут старые копии.
detect_language() {
    local cfg="${CONFIG_FILE:-${GOAMNEZIA_DIR:-/opt/goamnezia}/config.json}"
    local lang=""
    if [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
        lang=$(jq -r '.lang // .language // empty' "$cfg" 2>/dev/null)
    fi
    # Маркер-файл: язык выбирают до того, как появится config.json
    if [ -z "$lang" ]; then
        local marker="${GOAMNEZIA_DIR:-/opt/goamnezia}/.language"
        if [ -f "$marker" ]; then
            lang=$(head -c 2 "$marker" 2>/dev/null | tr -d '[:space:]')
        fi
    fi
    if ! [[ "$lang" =~ ^(en|ru)$ ]]; then
        lang="ru"
    fi
    echo "$lang"
}

# ── Сохранение выбранного языка ──────────────────────────────────────────────
# Пишем и в сам config.json (его detect_language читает первым), и в маркер (он нужен до появления config.json).
# Отказ любой из двух записей — отказ всего сохранения: код lang_write_failed и слова в GA_ERR_CODE / GA_ERR_MSG,
# сказано в stderr. Раньше обе записи глушились (`|| true`, голое `echo >`), и при кончившемся месте lang-set
# отвечал success, а config.json оставался прежним, маркер — пустым (находка OPS-04).
save_language() {
    local lang="$1"
    if ! [[ "$lang" =~ ^(en|ru)$ ]]; then
        return 1
    fi
    local dir="${GOAMNEZIA_DIR:-/opt/goamnezia}"
    mkdir -p "$dir" 2>/dev/null
    GA_ERR_CODE=""; GA_ERR_MSG=""

    local cfg="${CONFIG_FILE:-${dir}/config.json}"
    if [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
        # Под общим замком, как любая запись config.json: из SSH «Настройки → Язык» запись таймера в то же окно
        # (тик квот, сторож) иначе терялась — прочитали оба, записал последний (находка SR-38). ga_config_merge
        # берёт замок сам и пишет атомарным писателем продукта (проверка jq, fsync, rename). Без модуля
        # (ранний выбор языка до загрузки common.sh) — своя времянка рядом с целью.
        if type ga_config_merge >/dev/null 2>&1; then
            ga_config_merge "{\"lang\":\"${lang}\"}" >/dev/null || { _save_language_failed "$cfg"; return 1; }
        elif ! _save_language_cfg "$lang" "$cfg"; then
            _save_language_failed "$cfg"
            return 1
        fi
    fi

    if type ga_write_file >/dev/null 2>&1; then
        ga_write_file "${dir}/.language" "${lang}"$'\n' 644 || { _save_language_failed "${dir}/.language"; return 1; }
    else
        local tmp
        if ! tmp=$(mktemp "${dir}/.language.XXXXXX" 2>/dev/null) \
           || ! { printf '%s\n' "$lang" >"$tmp"; } 2>/dev/null || ! chmod 644 "$tmp" 2>/dev/null \
           || ! mv -f "$tmp" "${dir}/.language" 2>/dev/null; then
            [ -n "${tmp:-}" ] && rm -f "$tmp" 2>/dev/null
            _save_language_failed "${dir}/.language"
            return 1
        fi
    fi
    return 0
}

# _save_language_failed <файл> — код и слова отказа там, где их ждут мост и меню.
_save_language_failed() {
    GA_ERR_CODE=lang_write_failed
    GA_ERR_MSG="$(tf ops_lang_write_failed "$1")"
    type ga_set_error >/dev/null 2>&1 && ga_set_error lang_write_failed
    if type log_error >/dev/null 2>&1; then log_error "$GA_ERR_MSG"; else printf '  %s\n' "$GA_ERR_MSG" >&2; fi
    return 0
}

# Запасной путь без lib/common.sh: tmp рядом с целью + mv — в пределах одной ФС атомарно, и читатели (бот,
# панель, MCP) никогда не увидят обрезанный config.json.
_save_language_cfg() {
    local lang="$1" cfg="$2" tmp
    tmp=$(mktemp "${cfg}.XXXXXX") || return 1
    if jq --arg lang "$lang" '. + {lang: $lang}' "$cfg" > "$tmp" 2>/dev/null && [ -s "$tmp" ] \
       && chmod 600 "$tmp" 2>/dev/null && mv -f "$tmp" "$cfg" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# ── Выбор языка при первом запуске ───────────────────────────────────────────
# Экран намеренно двуязычный и без обращений к словарю: словарь ещё не загружен,
# а спрашивать «на каком языке говорить» на языке, который человек не понимает,
# бессмысленно. Это единственное место с литералами вне t/tf.
#
# pick_language_interactive [first] — first: самый первый запуск. Оставлять там
# нечего, и пункт «0) Оставить как есть» на первом экране мастера только путал
# (находка NC-03 критика-новичка, 28.09.2026): его нет, а Enter — русский, язык
# продукта по умолчанию. Из «Настройки → Язык» пункт «0» остаётся: там это отмена.
pick_language_interactive() {
    local first=0
    [ "${1:-}" = first ] && first=1
    echo "" >&2
    echo "  ┌──────────────────────────────────────────┐" >&2
    echo "  │  Выберите язык / Select language         │" >&2
    echo "  ├──────────────────────────────────────────┤" >&2
    echo "  │  1) Русский                              │" >&2
    echo "  │  2) English                              │" >&2
    [ "$first" = 1 ] || echo "  │  0) Оставить как есть / Keep as is       │" >&2
    echo "  └──────────────────────────────────────────┘" >&2
    echo -n "  > " >&2
    local ch
    # Конец ввода — «не выбрано», а не Enter: раньше он попадал в пустой ответ и на первом запуске записывал русский
    # без человека (тот же класс, что INST-02 у мастера: конец ввода — не ответ). Отметка GA_INPUT_EOF — как у
    # остальных вопросов (lib/common.sh).
    if ! read -r ch; then
        echo "" >&2
        GA_INPUT_EOF=1
        return 1
    fi
    case "$ch" in
        2|en|EN|english|English) echo "en"; return 0 ;;
        1|ru|RU|russian|Russian|русский) echo "ru"; return 0 ;;
    esac
    # Первый запуск: Enter — русский. Прочее (опечатка, конец ввода) — как раньше, «не выбрано»: вызывающий
    # ничего не пишет, и продукт говорит по-русски до следующего запуска, где спросит снова.
    if [ "$first" = 1 ] && [ -z "$ch" ]; then echo "ru"; return 0; fi
    # Всё остальное — «передумал», а НЕ «русский». Раньше сюда попадали «0»,
    # пустой Enter, опечатка и оборванный ввод, и все они молча переключали
    # продукт на русский, а вызывающий рапортовал «язык сохранён». На
    # английской установке человек, нажавший «0», чтобы выйти, переводил на
    # русский и меню, и бота, и панель.
    return 1
}
