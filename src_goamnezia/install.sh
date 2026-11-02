#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# goAmnezia pro — AmneziaWG 1.0/1.5 · 2.0 · 3.1 на своём сервере
# Версия берётся из GOAMNEZIA_VERSION (lib/common.sh) — здесь её не дублируем,
# чтобы шапка и конфиг не разъезжались при обновлении.
#
# Docker + официальные контейнеры Amnezia • ключи .conf и vpn:// • QR •
# пользователи с лимитами и сроками • Telegram-бот и веб-панель • MCP • i18n RU/EN
# Lite: IP:порт без домена   ·   Pro: домен, сайт-маскировка, панель на домене, мини-апп
#
# Install (main — стабильная; экспериментальная dev — то же с `export GOAMNEZIA_BRANCH=dev` перед командой):
#   export GOAMNEZIA_PAT="YOUR_READ_ONLY_GITHUB_TOKEN"; bash <(printf 'Authorization: token %s\n' "$GOAMNEZIA_PAT" | curl -fsSL -H @- https://raw.githubusercontent.com/anten-ka/goamnezia_pro/main/bootstrap.sh)
# ══════════════════════════════════════════════════════════════════════════════

# -e НЕ включаем сознательно: интерактивное меню обязано пережить любую неудачу
# отдельной команды (нет docker, оборвался curl) и вернуться к выбору, а не
# закрыть человеку сессию. Ошибки ловим по кодам возврата вручную.
set -uo pipefail

# PATH задаём САМИ, а не полагаемся на вызывающего. Скрипт работает от root и
# зовёт ss, iptables, ip, docker — они лежат в /usr/sbin и /usr/local/bin. У
# systemd-юнитов PATH свой и урезанный: юнит бота получает venv/bin:/usr/bin,
# где sbin нет вовсе, и из бота молча ломается всё, что трогает сеть.
for _d in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
    case ":${PATH}:" in *":${_d}:"*) ;; *) PATH="${PATH}:${_d}" ;; esac
done
export PATH
unset _d

# Инициализация для set -u: выставляется миграцией, читается в main().
MIGRATED_FROM="${MIGRATED_FROM:-}"

# ── Пути скрипта и библиотек ─────────────────────────────────────────────────
# Абсолютный путь не ссылкой (так зовут мост панель, бот и таймеры) — каталог прямо из него, без трёх процессов на
# каждый вызов (CPU-03); ссылка (/usr/local/bin/goamnezia) и относительный путь — как раньше, через readlink.
if [[ "${BASH_SOURCE[0]}" == /*/* ]] && [ ! -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
else
    SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
fi
LIB_DIR="$SCRIPT_DIR/lib"
# Защитный fallback: скрипт могли скопировать одним файлом (например, в
# /usr/local/bin без каталога lib рядом). Библиотеки и actions.json тогда берём
# из штатного места установки.
if [ ! -f "$LIB_DIR/common.sh" ] && [ -f "/opt/goamnezia/lib/common.sh" ]; then
    SCRIPT_DIR="/opt/goamnezia"
    LIB_DIR="$SCRIPT_DIR/lib"
fi

# ── Модули ───────────────────────────────────────────────────────────────────
# Пять обязательных — без них продукт не работает; остальные подключаются, если
# есть (спринты 2–5 добавляют их постепенно, и install.sh обязан запускаться
# на неполном комплекте).
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/i18n.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/deps.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/docker.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/amnezia.sh"
# shellcheck source=/dev/null
[ -f "$LIB_DIR/awg_params.sh" ] && source "$LIB_DIR/awg_params.sh"
# shellcheck source=/dev/null
[ -f "$LIB_DIR/users.sh" ]      && source "$LIB_DIR/users.sh"
# shellcheck source=/dev/null
[ -f "$LIB_DIR/export.sh" ]     && source "$LIB_DIR/export.sh"
# Модуль ядра AmneziaWG по выбору человека (docs/KMOD_PLAN.md, этап Б): установка, перевод движка, сторож, мост kmod-*
# shellcheck source=/dev/null
[ -f "$LIB_DIR/kmod.sh" ]       && source "$LIB_DIR/kmod.sh"
# Адреса сервера (docs/EDGEIPS.md): список адресов машины нужен выдаче ключей с endpoint_ip
[ -f "$LIB_DIR/edgeips.sh" ]    && source "$LIB_DIR/edgeips.sh"
# Pro-режим (nginx, Let's Encrypt, сайт-маскировка, панель и доступы агентов на
# домене) — часть продукта, а не поздний спринт: bootstrap кладёт модуль в
# обязательный FILES, поэтому и здесь source без проверки -f. Библиотеку
# шаблонов lib/templates_lib.sh модуль подключает сам.
# shellcheck source=/dev/null
source "$LIB_DIR/website.sh"
# Предполётная проверка портов 80/443 (PLAN §4.3.1, docs/PREFLIGHT.md): кто
# держит порт, чей это продукт, не закрыт ли он файрволом. Модуль не зависит от
# website.sh, но мастер и экран «Режим и сайт» зовут оба. Все обращения к нему
# обёрнуты `type preflight_modes` — без модуля мастер и мост работают как прежде.
# shellcheck source=/dev/null
[ -f "$LIB_DIR/preflight.sh" ]  && source "$LIB_DIR/preflight.sh"
# Доступы агентов к MCP по HTTP (PLAN §6.10, CONTRACT §5.1): agents.json,
# юнит goamnezia-mcp-http, nginx-location через lib/website.sh. Подключается
# после website.sh и preflight.sh — модуль опирается на оба (адрес по режиму,
# самоподписанный сертификат, открытие порта в файрволе).
# shellcheck source=/dev/null
[ -f "$LIB_DIR/agents.sh" ]     && source "$LIB_DIR/agents.sh"
[ -f "$LIB_DIR/share.sh" ]      && source "$LIB_DIR/share.sh"
# Страница подключения и зеркало сборок (docs/CLIENTS.md): каталог
# lib/clients.json, служба goamnezia-pages, локация в vhost через lib/website.sh.
# Идут после website.sh, users.sh и share.sh — опираются на их функции.
# shellcheck source=/dev/null
[ -f "$LIB_DIR/pages.sh" ]      && source "$LIB_DIR/pages.sh"
# Подписка — постоянная ссылка на человека для Clash/mihomo, роутеров и приложений (docs/SUBSCRIPTION.md): служба —
# общая со страницами, поэтому после pages.sh.
# shellcheck source=/dev/null
[ -f "$LIB_DIR/subs.sh" ]       && source "$LIB_DIR/subs.sh"
# shellcheck source=/dev/null
[ -f "$LIB_DIR/mirror.sh" ]     && source "$LIB_DIR/mirror.sh"
# shellcheck source=/dev/null
[ -f "$LIB_DIR/backup.sh" ]     && source "$LIB_DIR/backup.sh"
# shellcheck source=/dev/null
[ -f "$LIB_DIR/logbudget.sh" ]  && source "$LIB_DIR/logbudget.sh"
# Спринт 4: обновления из официального репозитория Amnezia (по кнопке, с
# откатом), импорт существующей установки, статистика по суткам, таймеры
# systemd. Идут после amnezia/users/backup — опираются на их функции.
# shellcheck source=/dev/null
[ -f "$LIB_DIR/upstream.sh" ]   && source "$LIB_DIR/upstream.sh"
# shellcheck source=/dev/null
[ -f "$LIB_DIR/import.sh" ]     && source "$LIB_DIR/import.sh"
# shellcheck source=/dev/null
[ -f "$LIB_DIR/stats.sh" ]      && source "$LIB_DIR/stats.sh"
# shellcheck source=/dev/null
[ -f "$LIB_DIR/timers.sh" ]     && source "$LIB_DIR/timers.sh"
# Режимы 0.6.0 (docs/MODES_047.md): «Ленивый Pro» — первая установка по одному домену — и линия на UDP 443 в Pro.
# Своего ничего не ставит — зовёт модули выше (import, amnezia, website, users, pages, timers), поэтому идёт после них.
# shellcheck source=/dev/null
[ -f "$LIB_DIR/modes.sh" ]      && source "$LIB_DIR/modes.sh"
# shellcheck source=/dev/null
[ -f "$LIB_DIR/selftest.sh" ]   && source "$LIB_DIR/selftest.sh"
# Откат неудачного обновления (OPS-02): прежний код рядом кладёт bootstrap.sh, откатывает миграция.
# shellcheck source=/dev/null
[ -f "$LIB_DIR/update.sh" ]     && source "$LIB_DIR/update.sh"

# ── Аварийный минимум ────────────────────────────────────────────────────────
# `source` несуществующего файла при `set -uo pipefail` (без -e) НЕ прерывает
# скрипт: bash печатает ошибку и идёт дальше. Дальше первое же обращение к
# ${CYAN} или к `t` роняет процесс по -u, и вызывающий (бот, MCP, тест) не
# получает ни JSON, ни причины. Поэтому доопределяем ровно то, без чего
# невозможно СООБЩИТЬ об ошибке. Настоящую работу это не подменяет: наличие
# конкретных функций модулей проверяет _require_fn и отвечает module_missing.
: "${RED:=}" ; : "${GREEN:=}" ; : "${YELLOW:=}" ; : "${BLUE:=}"
: "${MAGENTA:=}" ; : "${CYAN:=}" ; : "${WHITE:=}" ; : "${BOLD:=}"
: "${DIM:=}" ; : "${NC:=}"
: "${GOAMNEZIA_VERSION:=0.1.0}"
: "${GOAMNEZIA_DIR:=/opt/goamnezia}"
: "${CONFIG_FILE:=$GOAMNEZIA_DIR/config.json}"
: "${USERS_FILE:=$GOAMNEZIA_DIR/users.json}"
: "${STATE_DIR:=$GOAMNEZIA_DIR/state}"
: "${BACKUP_DIR:=$GOAMNEZIA_DIR/backups}"
: "${UPSTREAM_DIR:=$LIB_DIR/upstream}"
: "${LOCK_DIR:=/run/goamnezia}"
: "${LOCK_FILE:=$LOCK_DIR/config.lock}"
: "${LOG_FILE:=/var/log/goamnezia.log}"
: "${AUDIT_LOG:=/var/log/goamnezia-audit.log}"
: "${BOT_DIR:=/opt/goamnezia-bot}"
: "${ADMIN_DIR:=/opt/goamnezia-admin}"
: "${MCP_DIR:=/opt/goamnezia-mcp}"
: "${PROFILE_IDS:=awg3 awg2 awg1}"

if ! type log_info >/dev/null 2>&1; then
    log_info()    { echo "  $*" >&2; }
    log_success() { echo "  $*" >&2; }
    log_warning() { echo "  $*" >&2; }
    log_error()   { echo "  $*" >&2; }
    log_step()    { echo "  $*" >&2; }
    log_dim()     { echo "  $*" >&2; }
fi
if ! type t >/dev/null 2>&1; then
    # Без словаря печатаем сам ключ: человеку видно, чего не хватает, а скрипт
    # продолжает работать.
    t()  { printf '%s' "${1:-}"; }
    tf() { local _k="${1:-}"; shift; printf '%s' "${_k}${*:+ $*}"; }
fi
if ! type ga_emit_json >/dev/null 2>&1; then
    ga_emit_json() {
        local status="${1:-error}" message="${2:-}" extra="" kv k v
        shift 2 2>/dev/null || true
        for kv in "$@"; do
            k="${kv%%=*}"; v="${kv#*=}"
            if [ "${v:0:6}" = "@json:" ]; then
                extra="${extra},\"${k}\":${v:6}"
            else
                v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
                extra="${extra},\"${k}\":\"${v}\""
            fi
        done
        message="${message//\\/\\\\}"; message="${message//\"/\\\"}"
        printf '{"status":"%s","message":"%s"%s}\n' "$status" "$message" "$extra"
    }
fi
if ! type confirm >/dev/null 2>&1; then
    # Согласие только явное: пустой ввод и EOF считаем отказом, иначе
    # разрушительное действие проходит «само» на оборванной сессии.
    # Тот же договор, что у настоящего confirm (lib/common.sh): цифра — главный
    # ответ, буквы принимаются по привычке. Запасная копия обязана отвечать
    # одинаково с основной, иначе «1» в одном месте согласие, а в другом отказ.
    confirm() {
        local ans=""
        echo -ne "  ${1:-?} [1/0]: " >&2
        if ! { IFS= read -r ans </dev/tty; } 2>/dev/null; then
            if [ -t 0 ]; then IFS= read -r ans || ans="n"; else ans="n"; fi
        fi
        ans="$(printf '%s' "$ans" | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
        case "$ans" in 1|y|yes|д|да) return 0 ;; *) return 1 ;; esac
    }
fi
if ! type run_with_spinner >/dev/null 2>&1; then
    run_with_spinner() {
        local label="$1"; shift
        log_step "$label"
        "$@" >/dev/null
    }
fi

# Язык: из config.json или из файла-маркера, по умолчанию ru. Проверка type —
# на случай, когда i18n.sh не подгрузился (см. аварийный минимум выше).
if type load_language >/dev/null 2>&1 && type detect_language >/dev/null 2>&1; then
    load_language "$(detect_language)"
fi

# Каталог с описанием действий моста. Переопределяется в тестах и в MCP.
ACTIONS_JSON="${GOAMNEZIA_ACTIONS_JSON:-$LIB_DIR/actions.json}"

# ── Мелкие хелперы экрана и данных ───────────────────────────────────────────

# Горизонтальная линейка. seq не используем: на минимальных образах его может
# не быть, а разделитель нужен в каждом экране. Ширина по умолчанию — одна на
# весь продукт (GA_UI_W из lib/common.sh): раньше соседние экраны рисовались в
# 56, 74 и 93 колонки, и два из трёх не помещались в стандартное окно 80×24.
_rule() {
    local ch="${1:-─}" n="${2:-${GA_UI_W:-76}}" i out=""
    for ((i = 0; i < n; i++)); do out+="$ch"; done
    printf '%s' "$out"
}

# Заголовок экрана: подпись пункта меню, под ней — уточнение (подзаголовок).
# Раньше заголовок расходился с пунктом, которым сюда пришли («Обновления
# Amnezia» → «Обновление ядра AmneziaWG»), и человек не был уверен, что попал
# туда, куда хотел. Теперь заголовок РАВЕН подписи пункта, а всё уточняющее
# уходит вниз и переносится по словам.
_screen_head() {
    # Новый экран — пропуск паузы, поставленный чьим-то «0 — назад», больше ни к чему (SR-40).
    GA_BACK=0
    local title="$1" note="${2:-}"
    echo ""
    echo -e "  ${BOLD}${WHITE}${title}${NC}"
    [ -n "$note" ] && echo -e "  ${DIM}$(ga_wrap "$note" "${GA_UI_W:-76}" 2)${NC}"
    echo -e "  ${DIM}$(_rule)${NC}"
}

# Строка-пояснение под пунктом или полем: перенос по словам с висячим отступом,
# чтобы длинные объяснения не уезжали за правый край (в разборе критика самая
# длинная строка была 353 знака в одну полосу).
_note() {
    [ -n "${1:-}" ] || return 0
    # Отступ продолжения — те же пять колонок, что у первой строки: с нулём
    # вторая строка пояснения начиналась с края окна и читалась как новый пункт.
    echo -e "     ${DIM}$(ga_wrap "$1" "$(( ${GA_UI_W:-76} - 3 ))" 5)${NC}"
}

# Безопасное чтение config.json. Печатает ТОЛЬКО значение (вызывается через $()).
_cfg() {
    local path="$1" v=""
    if type ga_config_get >/dev/null 2>&1; then
        v=$(ga_config_get "$path" 2>/dev/null) || v=""
    elif [ -f "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1; then
        v=$(jq -r "${path} // empty" "$CONFIG_FILE" 2>/dev/null) || v=""
    fi
    [ "$v" = "null" ] && v=""
    printf '%s' "$v"
}

# Состояние профиля одним словом: running | exited | missing |
# docker_unreachable. Никогда не пусто — на пустом значении рушится раскраска
# в дашборде. docker_unreachable к missing НЕ сводим: «демон не отвечает» и
# «контейнера нет» требуют разных действий от человека, и врать про пропажу
# живого профиля нельзя (см. lib/docker.sh, раздел «Версия API демона»).
_profile_state() {
    local p="$1" js="" st=""
    if type amnezia_profile_status >/dev/null 2>&1; then
        js=$(amnezia_profile_status "$p" 2>/dev/null) || js=""
        if [ -n "$js" ] && command -v jq >/dev/null 2>&1; then
            # Работает без опубликованного порта (LC-20) — отдельное состояние: для людей профиль лежит.
            st=$(printf '%s' "$js" | jq -r 'if .state == "running" and .port_published == false then "unpublished" else (.state // empty) end' 2>/dev/null) || st=""
        fi
    fi
    case "$st" in running|exited|missing|docker_unreachable|unpublished) : ;; *) st="missing" ;; esac
    printf '%s' "$st"
}

# Значок состояния профиля с цветом: ● работает · ○ остановлен · ✗ нет ·
# ⚠ неизвестно (демон Docker не отвечает).
_profile_icon() {
    case "$1" in
        running)            printf '%s●%s' "$GREEN" "$NC" ;;
        restarting)         printf '%s↻%s' "$CYAN" "$NC" ;;
        exited)             printf '%s○%s' "$YELLOW" "$NC" ;;
        docker_unreachable) printf '%s⚠%s' "$YELLOW" "$NC" ;;
        unpublished)        printf '%s◌%s' "$RED" "$NC" ;;
        *)                  printf '%s✗%s' "$DIM" "$NC" ;;
    esac
}

# Состояние профиля словами — человеку показываем перевод, а не машинный код.
_profile_state_label() {
    case "$1" in
        running)            t docker_state_running ;;
        restarting)         t docker_state_restarting ;;
        exited)             t docker_state_exited ;;
        docker_unreachable) t docker_state_unreachable ;;
        unpublished)        t docker_state_unpublished ;;
        *)                  t docker_state_missing ;;
    esac
}

# IP сервера: из config.json (мастер записал его при установке), иначе
# определяем снаружи. Прямой get_server_ip на каждую перерисовку дашборда —
# это три curl с таймаутами: без интернета экран «думал» бы по 15 секунд.
_server_ip() {
    local ip
    ip=$(_cfg '.server_ip')
    if [ -z "$ip" ] && type get_server_ip >/dev/null 2>&1; then
        ip=$(get_server_ip 2>/dev/null) || ip=""
        [ "$ip" = "0.0.0.0" ] && ip=""
    fi
    printf '%s' "$ip"
}

# Адрес, на который пришло SSH-подключение владельца: входящие на него доходят наверняка. На
# машине с несколькими адресами внешняя служба (get_server_ip) называет адрес ИСХОДЯЩИХ, а он может
# не принимать входящие — на стенде 25.09.2026 ключи по нему не подключались ни в одном режиме, кроме
# третьего с доменом (находка SR-42). Берём адрес SSH, только если он публичный и есть на машине:
# за NAT там частный адрес, и остаётся прежний путь.
_ssh_inbound_ip() {
    local a
    a=$(printf '%s' "${SSH_CONNECTION:-}" | awk '{print $3}')
    [ -n "$a" ] || return 1
    type ga_edge_list >/dev/null 2>&1 || return 1
    grep -qxF -- "$a" <<<"$(ga_edge_list 2>/dev/null)" || return 1
    printf '%s' "$a"
}

# Установлен ли профиль (есть запись в config.json).
_profile_installed() {
    local v
    if type ga_profile_installed >/dev/null 2>&1; then
        ga_profile_installed "$1"
        return $?
    fi
    v=$(_cfg ".profiles.$1.container")
    [ -n "$v" ]
}

# Фактическая линейка профиля для экранов меню. Не имя профиля и не голое поле
# конфига: у подхваченного контейнера приложения линейка своя, а у старых
# установок поля ещё нет — ga_profile_line разбирается и с тем, и с другим.
_profile_line() {
    if type ga_profile_line >/dev/null 2>&1; then
        ga_profile_line "$1"
        return 0
    fi
    _cfg ".profiles.$1.line"
}

# Список пользователей как JSON-массив, независимо от обёртки модуля.
# GA_USERS_BROKEN выставляется здесь и читается карточкой меню: «0 пользователей»
# и «файл сломан» — разные вещи, и человек должен видеть вторую, а не первую.
_users_json() {
    local raw="" out="[]"
    GA_USERS_BROKEN=0
    if type users_list >/dev/null 2>&1; then
        raw=$(users_list 2>/dev/null) || { raw=""; GA_USERS_BROKEN=1; }
    elif [ -f "$USERS_FILE" ]; then
        raw=$(cat "$USERS_FILE" 2>/dev/null) || raw=""
    fi
    if [ -n "$raw" ] && command -v jq >/dev/null 2>&1; then
        out=$(printf '%s' "$raw" | jq -c 'if type=="array" then . else (.users // []) end' 2>/dev/null) || out="[]"
    fi
    printf '%s' "$out"
}

# Возвращает число ИЛИ слово «сломан». Показывать «0 пользователей» на
# неразбираемом файле нельзя: человек решит, что ключей не было, и заведёт
# заново поверх существующих. Код возврата 1 — повод покрасить строку.
_users_count() {
    local n="" js=""
    # Число — одним jq прямо по файлу (CPU-03): раньше длину считали по полному списку с выборкой полей — полдюжины
    # jq и временный файл ради одного числа на каждом status. Та же проверка формы, что у ga_users_intact (объект,
    # .users — массив); не сошлось или файл не читается — прежний путь ниже, он и скажет «сломан».
    if command -v jq >/dev/null 2>&1; then
        if [ ! -e "$USERS_FILE" ]; then
            n=0
        else
            n=$(jq -r 'if type == "object" and ((.users // []) | type == "array") then ((.users // []) | length)
                       else error("shape") end' "$USERS_FILE" 2>/dev/null) || n=""
        fi
        if [[ "$n" =~ ^[0-9]+$ ]]; then
            GA_USERS_BROKEN=0
            printf '%s' "$n"
            return 0
        fi
        n=""
    fi
    # ga_capture, а НЕ $( … | … ): в подстановке команды _users_json уходит в
    # дочерний процесс, и флаг GA_USERS_BROKEN оттуда наружу не возвращается —
    # вся ветка «файл сломан» ниже была недостижима, а счётчик по-прежнему
    # показывал ноль. Ровно тот узор, ради которого ga_capture и написан.
    if command -v jq >/dev/null 2>&1; then
        ga_capture js _users_json || js=""
        n=$(printf '%s' "$js" | jq -r 'length' 2>/dev/null) || n=""
    fi
    if [ "${GA_USERS_BROKEN:-0}" = "1" ]; then
        printf '%s' "$(t st_users_broken)"
        return 1
    fi
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}

# Байты в человекочитаемое. Целочисленная арифметика: bc на сервере может не быть.
# Единицы и десятичный знак — из словаря: в русском меню «1 ГБ» в сообщении лимита соседствовал с
# «1.0 GB» и «34 KB» в той же карточке (находка LC-08).
# Как в панели (fmtBytes, A3-8): одна цифра после запятой с округлением, от 100 — целым; КБ тоже с дробью — «41,9 КБ»,
# а не «41 КБ» рядом с панелью.
_human_bytes() {
    local b="${1:-0}" sep u unit t10
    [[ "$b" =~ ^[0-9]+$ ]] || b=0
    sep=$(t unit_dec_sep)
    if   [ "$b" -ge 1099511627776 ]; then u=1099511627776; unit=$(t unit_tb)
    elif [ "$b" -ge 1073741824 ]; then u=1073741824; unit=$(t unit_gb)
    elif [ "$b" -ge 1048576 ];    then u=1048576; unit=$(t unit_mb)
    elif [ "$b" -ge 1024 ];       then u=1024; unit=$(t unit_kb)
    else printf '%s %s' "$b" "$(t unit_b)"; return 0
    fi
    t10=$(((b * 10 + u / 2) / u))
    if [ "$t10" -ge 1000 ]; then printf '%s %s' "$(((b + u / 2) / u))" "$unit"
    else printf '%s%s%s %s' "$((t10 / 10))" "$sep" "$((t10 % 10))" "$unit"
    fi
}

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Дополнить строку пробелами до ширины w. printf %-Ns выравнивает по БАЙТАМ, а
# кириллица в UTF-8 занимает два — колонки со «Анна»/«Боб» разъезжались. ${#s}
# в UTF-8-локали считает символы, в C-локали ведёт себя как printf (не хуже).
_pad() {
    local s="${1:-}" w="${2:-0}" n
    n=$(( w - ${#s} ))
    [ "$n" -lt 0 ] && n=0
    printf '%s%*s' "$s" "$n" ''
}

# Пауза «Нажмите Enter». Отдельной функцией — повторяется в каждом подменю, и
# read без ||true при оборванной сессии возвращает 1 и портит код возврата.
# «0 — назад» из подменю возвращает сразу, без «Нажмите Enter...»: экран, закрытый
# нулём, ставит GA_BACK=1, и пауза у вызывающего пропускается один раз. Пауза нужна
# после ДЕЙСТВИЯ (правило владельца), чтобы успеть прочитать итог, а не после шага
# назад: от ключа до главного меню было восемь нажатий вместо четырёх (находки T17 и
# критика UX, 25.09.2026).
GA_BACK=0
_pause() {
    if [ "${GA_BACK:-0}" = 1 ]; then GA_BACK=0; return 0; fi
    echo ""
    echo -ne "  ${DIM}$(t press_enter)${NC}"
    read -r _ || true
}

# Свободный случайный порт. Основной диапазон — 1024–9999 (решение владельца
# 10.09.2026: «старайся ставить ниже десяти тысяч» — низкие UDP-порты реже режут
# промежуточные сети). Общеизвестные пропускаем (GA_PORT_WELLKNOWN), занятость
# проверяем предполётной проверкой lib/preflight.sh, а без неё — тем же ss/docker,
# что и раньше. Весь низкий диапазон занят → прежние 30000–49999 и честная строка
# об этом. Печатает ТОЛЬКО порт (вызов через $()), сообщение — в stderr.
#
# Аргументы — порты, которые брать нельзя, хотя на машине они свободны: мастер
# раздаёт порты всем профилям ДО установки, и порт, уже выбранный для awg2, ещё
# никто не слушает. Раньше случайный порт awg3 выбирался без этого списка и мог
# совпасть с портом awg2 — установка awg2 обрывалась на «порт уже занят
# профилем awg3», и мастер не доходил до конца.
_random_port() {
    local p i skip=" $* "
    for ((i = 0; i < 80; i++)); do
        p=$(ga_port_random "$GA_PORT_LOW_MIN" "$GA_PORT_LOW_MAX")
        ga_port_wellknown "$p" && continue
        [[ "$skip" == *" $p "* ]] && continue
        if _port_free "$p" udp; then printf '%s' "$p"; return 0; fi
    done
    log_warning "$(t pr_port_low_none)" >&2
    for ((i = 0; i < 50; i++)); do
        p=$(ga_port_random "$GA_PORT_HIGH_MIN" "$GA_PORT_HIGH_MAX")
        [[ "$skip" == *" $p "* ]] && continue
        if _port_free "$p" udp; then printf '%s' "$p"; return 0; fi
    done
    # Совсем безвыходно — отдаём последний кандидат: дальше его проверит
    # amnezia_profile_install и откажет с внятным port_busy.
    printf '%s' "$p"
}

# Порт свободен? Сначала предполётная проверка (она же знает про файрвол и
# соседей по серии), иначе модуль docker.sh, иначе ss напрямую.
_port_free() {
    local port="$1" proto="${2:-udp}" state
    if type preflight_port_owner >/dev/null 2>&1; then
        state=$(preflight_port_owner "$proto" "$port" 2>/dev/null | jq -r '.state // ""' 2>/dev/null) || state=""
        # closed_local — это про наш файрвол, а не про чужой процесс: порт свободен.
        case "$state" in
            busy) return 1 ;;
            free|closed_local) return 0 ;;
        esac
    fi
    if type docker_port_free >/dev/null 2>&1; then
        docker_port_free "$port" "$proto"
        return $?
    fi
    command -v ss >/dev/null 2>&1 || return 0
    if [ "$proto" = "udp" ]; then
        ! grep -qE "[:.]${port}[[:space:]]" <<<"$(ss -lun 2>/dev/null)"
    else
        ! grep -qE "[:.]${port}[[:space:]]" <<<"$(ss -ltn 2>/dev/null)"
    fi
}

# QR в терминал. qrencode ставится через deps.sh, но на битой установке его
# может не быть — тогда честно говорим об этом и печатаем саму строку.
#
# Картинка ключа awg2 занимает 77×39 знаков, а стандартное окно SSH — 80×24:
# верх кода уходил за край, и человек сканировал обрезок (замечание критика).
# Поэтому: рамка -m 1 вместо -m 2 (минус четыре строки и четыре колонки; сканеры
# телефонов читают такую рамку), а если и этого мало — НЕ рисуем ничего, а
# честно говорим, сколько надо и сколько есть, и что делать вместо этого.
# rc 1 — QR показать не удалось (вызывающий предлагает текстовый ключ); почему — в GA_QR_WHY: missing (рисовать
# нечем) или big (не влез в окно).
GA_QR_WHY=""
_qr_utf8() {
    GA_QR_WHY=""
    if ! _qr_make "$1"; then
        GA_QR_WHY=missing
        log_warning "$(t qr_missing)"
        return 1
    fi
    if ! _qr_fits "$GA_QR_W" "$GA_QR_H"; then
        GA_QR_WHY=big
        _qr_say_too_big "$GA_QR_W" "$GA_QR_H"
        return 1
    fi
    _qr_print "$GA_QR_OUT"
    return 0
}

# _qr_make <текст> → GA_QR_OUT (картинка), GA_QR_W и GA_QR_H — сколько ей нужно места вместе с отступом слева,
# заголовком и пустой строкой. rc 1 — рисовать нечем (нет qrencode). Текст — через stdin, не аргументом: в argv
# он виден в `ps` любому процессу на сервере, а здесь это приватный ключ или адрес-секрет страницы.
GA_QR_OUT=""; GA_QR_W=0; GA_QR_H=0
_qr_make() {
    local first
    GA_QR_OUT=""; GA_QR_W=0; GA_QR_H=0
    command -v qrencode >/dev/null 2>&1 || return 1
    GA_QR_OUT=$(printf '%s' "$1" | qrencode -r /dev/stdin -t UTF8 -m 1 2>/dev/null) || GA_QR_OUT=""
    [ -n "$GA_QR_OUT" ] || return 1
    first="${GA_QR_OUT%%$'\n'*}"
    GA_QR_W=$(( $(ga_str_width "$first") + 2 ))
    GA_QR_H=$(( $(printf '%s\n' "$GA_QR_OUT" | wc -l | tr -d ' ') + 2 ))
    return 0
}

# _qr_fits <ширина> <высота> — влезает ли картинка в окно. Размер окна перечитывается с терминала: человек
# развернул окно или уменьшил шрифт, а COLUMNS/LINES у скрипта остались прежними.
_qr_fits() {
    _term_size_refresh
    [ "$1" -le "$(ga_term_cols)" ] && [ "$2" -le "$(ga_term_lines)" ]
}

# Не влезла: сколько нужно, сколько есть и что сделать — уменьшить шрифт или развернуть окно (NC-06). Раньше
# подсказка отправляла к «соседнему пункту карточки», которого в мастере нет вовсе (NC-05).
_qr_say_too_big() {
    log_warning "$(tf qr_too_big "${1}×${2}" "$(ga_term_cols)×$(ga_term_lines)")"
    log_dim "$(t qr_too_big_hint)"
}

_qr_print() {
    printf '%s\n' "$1" | while IFS= read -r l; do echo "  $l"; done
}

# Размер окна — с терминала (stty size), если он есть и назвал не ноль: pty без размера (стенд) и запуск без
# терминала оставляют прежние COLUMNS/LINES.
_term_size_refresh() {
    local sz r c
    [ -t 1 ] || return 0
    sz=$( { stty size </dev/tty; } 2>/dev/null) || return 0
    read -r r c <<<"$sz"
    [[ "$r" =~ ^[0-9]+$ ]] && [[ "$c" =~ ^[0-9]+$ ]] || return 0
    [ "$r" -gt 0 ] && [ "$c" -gt 0 ] || return 0
    LINES="$r"; COLUMNS="$c"
}

# ── Легенда значков ──────────────────────────────────────────────────────────
# В боте и в панели легенда есть, в SSH её не было вовсе: человек видел ● ○ ⏳ ▮
# и догадывался (замечание критика). Один текст на все три места — таблицу
# пользователей, шапку дашборда и «Трафик», — иначе они однажды разойдутся.
_legend_users() { echo -e "  ${DIM}$(ga_win_wrap "$(t legend_users)" 2)${NC}"; }
_legend_profiles() { echo -e "  ${DIM}$(ga_win_wrap "$(t legend_profiles)" 2)${NC}"; }
_legend_online() { echo -e "  ${DIM}$(ga_win_wrap "$(t legend_online)" 2)${NC}"; }

# ── Снимок состояния для дашборда ────────────────────────────────────────────
# Дашборд перерисовывается каждые 30 секунд и на каждый возврат в меню, а
# собирал он себя десятками процессов: три amnezia_profile_status (по восемь
# форков каждый) плюс отдельные чтения config.json на каждое поле. Здесь всё то
# же берётся ОДНИМ чтением конфига, ОДНИМ запросом к Docker и одним jq, и живёт
# несколько секунд: за это время состояние контейнера всё равно не меняется, а
# при действиях кэш сбрасывается принудительно (_dash_snapshot force).
GA_DASH_TS=0
GA_DASH_MODE=""; GA_DASH_DOMAIN=""; GA_DASH_IP=""; GA_DASH_USERS=0; GA_DASH_PANEL=""; GA_DASH_CERT=""; GA_DASH_LAZY=""; GA_DASH_WZ=""
declare -A GA_DASH_STATE=()
declare -A GA_DASH_PORT=()
declare -A GA_DASH_LINE=()
# S4 профиля, у которого пакет данных не влезает в мобильные сети (S4-FIX, ga_amn_s4_risky); пусто — риска нет.
declare -A GA_DASH_S4=()

_dash_snapshot() {
    local now raw ps_out ps_rc=0 p cname line
    now=$(date +%s 2>/dev/null) || now=0
    if [ "${1:-}" != force ] && [ "$GA_DASH_TS" -gt 0 ] \
       && [ $(( now - GA_DASH_TS )) -lt "${GOAMNEZIA_DASH_TTL:-5}" ]; then
        return 0
    fi
    GA_DASH_TS="$now"
    # Меню живёт часами, а Docker за это время могли перезапустить без него (сторож, DK-02): закрепление версии API
    # старого демона новый не примет, а шапка твердила бы «служба старая».
    type docker_pin_refresh >/dev/null 2>&1 && docker_pin_refresh
    raw="{}"
    GA_DASH_BROKEN=0
    [ -f "$CONFIG_FILE" ] && raw=$(cat "$CONFIG_FILE" 2>/dev/null)
    command -v jq >/dev/null 2>&1 || return 0
    # «Файла нет» и «файл не разбирается» — РАЗНЫЕ вещи. Раньше обе сводились к
    # пустому скелету, и главный экран рисовал «только VPN, профилей нет,
    # пользователей 0» на живом сервере в третьем режиме с контейнерами. Человек
    # видел пустой сервер и соглашался на мастер первой установки — первая
    # половина сценария §1c.1, который убивает все ключи разом.
    if [ -f "$CONFIG_FILE" ] && ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
        GA_DASH_BROKEN=1
        raw="{}"
    fi
    printf '%s' "$raw" | jq -e . >/dev/null 2>&1 || raw="{}"
    # Один jq на весь экран: режим, домен, адрес, а затем по строке на профиль. Последним — режим, выбранный в
    # мастере, пока установка не закончена (запись .wizard, INST-01): шапка говорит об этом словами.
    IFS=$'\x1f' read -r GA_DASH_MODE GA_DASH_DOMAIN GA_DASH_IP GA_DASH_PANEL GA_DASH_CERT GA_DASH_LAZY GA_DASH_WZ \
        <<<"$(printf '%s' "$raw" | jq -r '[(.mode // ""), (.domain // ""), (.server_ip // ""), (.panel.miniapp_path // ""), (.site.cert // ""), (.lazy.domain // ""), (if (.wizard.step // "") != "" then (.wizard.mode // "lite") else "" end)] | join("")')"
    case "$GA_DASH_MODE" in pro|lite_site) ;; *) GA_DASH_MODE="lite" ;; esac
    [ -n "$GA_DASH_IP" ] || GA_DASH_IP=$(_server_ip)
    GA_DASH_USERS=$(_users_count)
    # Один запрос к Docker вместо трёх: имена и состояния всех контейнеров сразу.
    # Отказ команды — это «демон не отвечает», и врать про пропавшие профили
    # нельзя: у установленного профиля состояние станет docker_unreachable.
    ps_out=""
    # Порты — тем же запросом: работающий контейнер без опубликованного порта для людей не работает
    # (находка LC-20), и шапка обязана показать это, а не «● awg2 :443».
    if command -v docker >/dev/null 2>&1 && type ga_docker >/dev/null 2>&1; then
        ps_out=$(ga_docker ps -a --format '{{.Names}}	{{.State}}	{{.Ports}}' 2>/dev/null) || ps_rc=1
    else
        ps_rc=1
    fi
    local known pline ps4
    for p in $PROFILE_IDS; do
        IFS=$'\x1f' read -r cname line known pline ps4 \
            <<<"$(printf '%s' "$raw" | jq -r --arg p "$p" '[(.profiles[$p].container // ""), (.profiles[$p].port // "" | tostring), (if .profiles[$p] then "1" else "" end), (.profiles[$p].line // ""), (.profiles[$p].params.S4 // "" | tostring)] | join("")')"
        GA_DASH_PORT[$p]="$line"
        # Линия — из той же записи конфига (без детектора по параметрам: шапка перерисовывается каждые 30 с)
        [[ "$pline" =~ ^(1\.0|1\.5|2\.0|3\.1)$ ]] || pline=""
        GA_DASH_LINE[$p]="$pline"
        # Большой S4 у выданного профиля 2.0 (S4-FIX) — тем же чтением конфига, без Docker и без python.
        GA_DASH_S4[$p]=""
        if [ -n "$known" ] && type ga_amn_s4_risky >/dev/null 2>&1 && ga_amn_s4_risky "$ps4"; then
            GA_DASH_S4[$p]="$((10#$ps4))"
        fi
        if [ -z "$known" ]; then
            # Профиль не ставили — это не поломка. «missing» оставлен для записи
            # без контейнера: там человеку есть что чинить.
            GA_DASH_STATE[$p]="absent"
        elif [ -z "$cname" ]; then
            GA_DASH_STATE[$p]="missing"
        elif [ "$ps_rc" != 0 ]; then
            GA_DASH_STATE[$p]="docker_unreachable"
        else
            # Состояние берём ТОЧНО по имени и без конвейера «printf | grep -q»:
            # под pipefail ранний выход grep мог обернуться отказом всей трубы.
            # И не сводим всё, что не running, к «остановлен»: restarting — это
            # контейнер, который Docker поднимает прямо сейчас (DEFECTS §2.4а —
            # мелькание «○» у живого профиля в минуту перезапуска).
            GA_DASH_STATE[$p]="missing"
            local _row _name _st _ports
            while IFS= read -r _row; do
                _name="${_row%%$'\t'*}"; _row="${_row#*$'\t'}"
                _st="${_row%%$'\t'*}"; _ports="${_row#*$'\t'}"
                [ "$_name" = "$cname" ] || continue
                case "$_st" in
                    running)
                        GA_DASH_STATE[$p]="running"
                        # «0.0.0.0:443->443/udp» — опубликован; пусто или «443/udp» — нет.
                        [[ "$line" =~ ^[0-9]+$ ]] && [[ "$_ports" != *":${line}->"* ]] && GA_DASH_STATE[$p]="unpublished" ;;
                    restarting) GA_DASH_STATE[$p]="restarting" ;;
                    *)          GA_DASH_STATE[$p]="exited" ;;
                esac
                break
            done <<<"$ps_out"
        fi
    done
    return 0
}

# ── Главное меню (компактный дашборд + 6 разделов) ───────────────────────────
show_main_menu() {
    local ip p line line2
    GA_BACK=0
    _dash_snapshot
    ip="$GA_DASH_IP"
    [ -n "$ip" ] || ip="—"

    line=$(_rule '━')
    line2=$(_rule)

    # Правой рамки нет сознательно: ANSI-коды цвета не считаются как ширина, и
    # закрывающий столбец разъезжается на любой строке со значком состояния.
    echo ""
    echo -e "  ${BOLD}${CYAN}${line}${NC}"
    echo -e "  ${BOLD}${WHITE} goAmnezia pro v${GOAMNEZIA_VERSION}${NC}  ${DIM}— $(t dash_title)${NC}"
    echo -e "  ${BOLD}${CYAN}${line}${NC}"
    echo ""

    # Режим — Pro или Semi-Pro и после Ленивого Pro: это сценарий, а не режим. Сайт на домене, который ставил он, —
    # так и подписать (NC6-04), из той же записи конфига (.lazy.domain).
    local mode_note=""
    if [ -n "$GA_DASH_LAZY" ] && [ "$GA_DASH_LAZY" = "$GA_DASH_DOMAIN" ] && [ "$GA_DASH_MODE" != lite ]; then
        mode_note=" ${DIM}$(t dash_mode_by_lazy)${NC}"
    fi
    echo -e "  ${WHITE}$(t dash_mode)${NC} ${CYAN}$(_mode_name "$GA_DASH_MODE")${NC}${mode_note}    ${WHITE}$(t dash_ip)${NC} ${CYAN}${ip}${NC}"
    # Установка прервана (мастер отменён, сорвался шаг, «0 — в меню» на экране продолжения): режим выше — тот, что
    # есть на самом деле (режим с сайтом пишется, только когда сайт поднят), а выбранный в мастере — здесь, словами,
    # с тем, как продолжить (INST-01). Прежде шапка показывала выбранный как действующий: «Режим: Pro» без сайта.
    if [ -n "$GA_DASH_WZ" ]; then
        log_warning "$(_ui_w "$(tf dash_wizard_pending "$(_mode_name "$GA_DASH_WZ")")")"
    fi
    if [ -n "$GA_DASH_DOMAIN" ]; then
        echo -e "  ${WHITE}$(t dash_domain)${NC} ${CYAN}${GA_DASH_DOMAIN}${NC}"
        # Состояние веб-панели на домене — в строке состояния (владелец 17.09.2026); на самоподписанном сертификате
        # панели на домене нет, в Lite — сайта. Адрес с секретным путём в шапке — только замаскированным, как номер
        # карты (владелец 04.10.2026): шапка на каждом экране и уходит с любым скриншотом, а путь — половина входа
        # (находка NC-15 критика-новичка); по начальным и последним знакам видно, тот ли это адрес. Целиком — по F1
        # («п» — запасная клавиша, где терминал забирает F1 себе) на 5 минут прямо в шапке, потом снова маска
        # (владелец 04.10.2026, _panel_reveal); и пунктом «Настройки → Режим и сайт → Панель на домене».
        if [ "$GA_DASH_MODE" != lite ] && [ "$GA_DASH_CERT" != selfsigned ]; then
            if [ -n "$GA_DASH_PANEL" ] && _panel_service_installed; then
                local pshown phint pnow
                pnow=$(date +%s)
                if [ "${GA_PANEL_REVEAL_UNTIL:-0}" -gt "$pnow" ]; then
                    pshown=$(_site_panel_url "$GA_DASH_DOMAIN" "$GA_DASH_PANEL")
                    phint=$(tf dash_panel_reveal_left "$(( (GA_PANEL_REVEAL_UNTIL - pnow + 59) / 60 ))")
                else
                    pshown="${GA_DASH_DOMAIN}/$(_panel_path_masked "$GA_DASH_PANEL")"
                    phint=$(t dash_panel_reveal_hint)
                fi
                if [ $(( ${#pshown} + ${#phint} + 10 )) -le "${GA_UI_W:-76}" ]; then
                    echo -e "  ${WHITE}$(t dash_panel)${NC} ${CYAN}${pshown}${NC} ${DIM}${phint}${NC}"
                else
                    echo -e "  ${WHITE}$(t dash_panel)${NC} ${CYAN}${pshown}${NC}"
                    echo -e "  ${DIM}${phint}${NC}"
                fi
                [ "${GA_PANEL_REVEAL_UNTIL:-0}" -gt "$pnow" ] && echo -e "  ${YELLOW}$(_ui_w "$(t dash_panel_reveal_warn)")${NC}"
            elif [ -n "$GA_DASH_PANEL" ]; then
                # Путь выдан, а службы нет: по адресу открылась бы ошибка 502 (находка T6)
                echo -e "  ${WHITE}$(t dash_panel)${NC} ${DIM}$(_ui_w "$(t dash_panel_noservice)")${NC}"
            else
                echo -e "  ${WHITE}$(t dash_panel)${NC} ${DIM}$(t dash_panel_off)${NC}"
            fi
        fi
    fi
    # Что стоит в ключах, когда это не голый адрес сервера: от этого зависит, о
    # каком домене говорят строки про A-записи ниже (замечание критика).
    local keys_host=""
    type _ga_edge_common_endpoint >/dev/null 2>&1 && keys_host=$(_ga_edge_common_endpoint 2>/dev/null)
    if [ -n "$keys_host" ] && [ "$keys_host" != "$ip" ]; then
        echo -e "  ${WHITE}$(t dash_keys_host)${NC} ${CYAN}${keys_host}${NC}"
    fi
    # Вписанного в ключи IP на машине нет (переезд) — новые ключи с ним не соединятся (SR-45).
    if type ga_export_endpoint_host_gone >/dev/null 2>&1 && ga_export_endpoint_host_gone; then
        log_warning "$(_ui_w "$(tf dash_endpoint_host_gone "$(_cfg '.endpoint_host')")")"
    fi

    # Профили одной строкой: это первое, на что смотрят, когда «не подключается».
    # Только поставленные и с портом: «✗ awg1» у профиля, который просто не
    # ставили, выглядел поломкой, а порт с 0.4.3 выбирает сам человек (замечания
    # критика UX). Легенда значков — только когда есть что объяснять: при всех
    # «●» она шум.
    local profiles_line="" pst pport pline notok=0
    for p in $PROFILE_IDS; do
        pst="${GA_DASH_STATE[$p]:-absent}"
        [ "$pst" = absent ] && continue
        pport="${GA_DASH_PORT[$p]:-}"
        # Линия рядом с профилем: новичок не знает, что awg2 — это линия 2.0 (находка NC6-09)
        pline="${GA_DASH_LINE[$p]:-}"
        # Без имени места (решение владельца 15.10): «● AmneziaWG 3.1 · из приложения :46567»
        profiles_line+="$(_profile_icon "$pst") $(_pr_name "$p" noport)${pport:+ ${DIM}:${pport}${NC}}   "
        [ "$pst" = running ] || notok=1
    done
    [ -n "$profiles_line" ] || profiles_line="${DIM}$(t dash_no_profiles)${NC}"
    echo -e "  ${WHITE}$(t dash_profiles)${NC} ${profiles_line}"
    [ "$notok" = 1 ] && _legend_profiles
    # Ярлык режима и место VPN разошлись: «Сайт и VPN на 443» без профиля на 443
    # (или наоборот). Считаем по уже снятому снимку — лишних вызовов jq нет.
    local on443=""
    for p in $PROFILE_IDS; do [ "${GA_DASH_PORT[$p]:-}" = "443" ] && on443="$p"; done
    if { [ "$GA_DASH_MODE" = "pro" ] && [ -z "$on443" ]; } \
       || { [ "$GA_DASH_MODE" = "lite_site" ] && [ -n "$on443" ]; }; then
        log_warning "$(_ui_w "$(t dash_mode_port_mismatch)")"
    fi
    echo -e "  ${WHITE}$(t dash_users)${NC} ${CYAN}${GA_DASH_USERS}${NC}"
    # Адреса сервера — таблица прямо в шапке, как в goTelegram: это первое, на что смотрят, когда «у части
    # людей не работает». Всегда, и на машине с одним адресом: там — адрес и галочка A-записи (владелец).
    local edge_rows edge_js=""
    type ga_edge_status_json >/dev/null 2>&1 && edge_js=$(ga_edge_status_json 2>/dev/null)
    if [ -n "$edge_js" ] && edge_rows=$(_edge_table "$edge_js" 2>/dev/null) && [ -n "$edge_rows" ]; then
        echo -e "  ${DIM}${line2}${NC}"
        echo -e "  ${BOLD}${WHITE}$(t st_addr_title)${NC}"
        printf '%s\n' "$edge_rows"
    elif [ -n "$edge_js" ]; then
        # Адрес один, но в A-записях домена есть чужие — таблицы нет, строка есть
        _edge_dns_warn_single "$edge_js" 2>&1 || true
    fi
    # Домен сайта с чужой A-записью, когда ключи на IP (про него таблица молчит)
    _site_dns_warn_header "$edge_js" 2>&1 || true
    # Обновление не встало и откатано (OPS-02); места на диске мало (OPS-01); пакет Docker обновлён, а служба старая
    # (DK-02).
    _dash_update_notice 2>&1 || true
    _dash_disk_warn 2>&1 || true
    _dash_docker_stale_warn 2>&1 || true
    # Модуль ядра AmneziaWG без исправлений при профиле 3.1 (KMOD_PLAN А3).
    _dash_kmod_warn 2>&1 || true
    # Выданный профиль 2.0 с большим S4: на мобильных сетях скачивание не идёт (S4-FIX, MTU-01).
    _dash_s4_warn 2>&1 || true
    # Нет 2.0 на сервере (старые приложения и Keenetic не подключатся) и «Переставить на 2.0» (DUP-LINE-01).
    _dash_lines_warn 2>&1 || true

    echo -e "  ${DIM}${line2}${NC}"
    echo -e "  ${CYAN}1${NC}) $(t menu_users)"
    echo -e "  ${CYAN}2${NC}) $(t menu_status)"
    echo -e "  ${CYAN}3${NC}) $(t menu_protocols)"
    echo -e "  ${CYAN}4${NC}) $(t menu_maintenance)"
    echo -e "  ${CYAN}5${NC}) $(t menu_settings)"
    echo -e "  ${CYAN}6${NC}) $(t menu_bot)"
    echo -e "  ${CYAN}0${NC}) ${DIM}$(t menu_exit)${NC}"
    echo -e "  ${DIM}${line2}${NC}"
    echo -e "  ${DIM}$(t dash_auto_refresh)${NC}"
    echo -ne "  ${WHITE}▸ ${NC}"
}

# ══════════════════════════════════════════════════════════════════════════════
# Раздел 1: Пользователи
# ══════════════════════════════════════════════════════════════════════════════

# Номер строки → идентификатор пользователя. Заполняется _users_render_list по
# ВСЕМУ списку, а не по видимой странице: владелец просил «выбирать номером», и
# номер обязан значить одно и то же на любой странице — иначе на второй
# странице «5» открывало бы не того, кого человек видит.
GA_USER_NAMES=()
# Номер последней строки списка. Задаётся и до ранних выходов рендера («пользователей нет»,
# «users.json повреждён»): без глобального нуля экран «Пользователи» ронял всё меню под set -u,
# и завести первого пользователя из SSH было нельзя (находка SR-50, 25.09.2026; было и в 0.4.2).
GA_USERS_LAST=0
GA_USERS_PAGES=1
GA_USERS_PAGE=1

# Таблица пользователей. Значки как в PLAN §5.1: ● активен · ○ выключен ·
# ⏳ истёк срок · ▮ выбран лимит. Первая колонка — номер для выбора.
_users_render_list() {
    local js rows want_page="${1:-1}"
    # До любых ранних выходов: иначе «0 пользователей» наследовал номер от прошлого списка (SR-50).
    GA_USERS_LAST=0
    if ! command -v jq >/dev/null 2>&1; then
        log_warning "$(t err_no_jq)"; return 1
    fi
    # ga_capture, а НЕ $( ): в подстановке команды _users_json уходит в дочерний
    # процесс, и флаг GA_USERS_BROKEN оттуда не возвращается — список на битом
    # users.json рисовался словами «Пользователей пока нет». Человек читает это
    # как «сервер пуст» и заводит людей заново поверх существующих ключей.
    # Тот же узор уже обойдён в счётчике _users_count.
    ga_capture js _users_json || js=""
    if [ "${GA_USERS_BROKEN:-0}" = "1" ]; then
        GA_USER_NAMES=()
        GA_USERS_PAGES=1
        GA_USERS_PAGE=1
        log_error "$(t users_err_corrupt)"
        return 1
    fi
    # Разделитель \x1f, а не @tsv: пустые поля (нет профилей, нет срока) при
    # табуляции схлопываются вместе с соседями, и колонки уезжают влево.
    rows=$(printf '%s' "$js" | jq -r --arg now "$(_now_iso)" '
        .[] |
        # ВАЖНО: не `.enabled // true`. В jq `//` отбрасывает не только null, но
        # и false, поэтому `false // true` даёт true — выключенный человек
        # показывался включённым, значок «○ выключен» был недостижим, а пункт
        # меню всегда читался «Выключить» и всегда звал users_disable: включить
        # человека из SSH-меню было нельзя вообще. Тот же капкан описан в
        # lib/agents.sh, там сравнение с false сделано явно.
        # Причина важнее самого «выключен»: таймер выключает просроченных и исчерпавших лимит,
        # и значок «○» прятал, ПОЧЕМУ у человека не работает (находки LC-04 и критика UX).
        [ (if ((.expires // "") != "" and (.expires // "") < $now) then "exp"
           elif ((.quota_bytes // 0) > 0 and (((.traffic.rx // 0) + (.traffic.tx // 0)) >= (.quota_bytes // 0))) then "lim"
           elif (.enabled == false) then "off"
           else "on" end),
          (.name // "?"),
          ((.label // "") | gsub("[[:cntrl:]]"; "") | gsub("\\\\"; "∖")),
          ((.peers // {}) | keys | sort_by({"awg3":0,"awg2":1,"awg1":2}[.] // 9) | join(",")),
          (((.traffic.rx // 0) + (.traffic.tx // 0)) | tostring),
          (.expires // "") ] | join("")' 2>/dev/null)

    GA_USER_NAMES=()
    GA_USERS_PAGES=1
    GA_USERS_PAGE=1
    if [ -z "$rows" ]; then
        echo -e "  ${DIM}$(t users_none)${NC}"
        return 0
    fi

    local -a all=()
    mapfile -t all <<< "$rows"
    local total=${#all[@]} per="${GOAMNEZIA_USERS_PAGE_SIZE:-20}" pages first last i
    pages=$(( (total + per - 1) / per )); [ "$pages" -lt 1 ] && pages=1
    # GA_USERS_FOCUS — «покажи страницу, где лежит этот человек». Ставит его
    # тот, кто только что завёл запись: новая уходит в конец списка, и без
    # этого список оставался на прежней странице.
    if [ -n "${GA_USERS_FOCUS:-}" ]; then
        for ((i = 0; i < total; i++)); do
            case "${all[$i]}" in
                *$'\x1f'"${GA_USERS_FOCUS}"$'\x1f'*) want_page=$(( i / per + 1 )); break ;;
            esac
        done
        GA_USERS_FOCUS=""
    fi
    [ "$want_page" -gt "$pages" ] && want_page="$pages"
    [ "$want_page" -lt 1 ] && want_page=1
    GA_USERS_PAGES="$pages"
    GA_USERS_PAGE="$want_page"
    # Пункты экрана нумеруются ЗА ВСЕМ списком, а не за последней строкой
    # страницы: номера строк сквозные (строка 21 — это 21-й человек на любой
    # странице), и «за страницей» пункт «Добавить» получал бы номер, который на
    # другой странице означает живого человека. За общим числом — не получит
    # никогда, и при этом номера не прыгают при листании.
    GA_USERS_LAST=0
    first=$(( (want_page - 1) * per ))
    last=$(( first + per - 1 )); [ "$last" -ge "$total" ] && last=$(( total - 1 ))
    GA_USERS_LAST=$total; [ "$GA_USERS_LAST" -lt 0 ] && GA_USERS_LAST=0

    local icon name label profs bytes exp mark
    # Шапка колонок: без неё «14 колонок непонятно чего» — числа и обрезки
    # читались наугад (замечание критика к таблицам).
    # Широкая таблица занимает 82 колонки. На узком окне колонка «Подпись»
    # уходит (подпись видна в карточке человека), а имя получает остаток ширины:
    # иначе строки вылезали за край и переносились терминалом посреди колонок
    # (DEFECTS §2.5). Только на терминале — в файл таблица идёт прежней.
    # Индекс имён строим по ВСЕМУ списку — номер строки не зависит от страницы.
    for ((i = 0; i < total; i++)); do
        IFS=$'\x1f' read -r icon name label profs bytes exp <<< "${all[$i]}"
        GA_USER_NAMES[$i]="$name"
    done
    # Колонка «Профили» — линиями, а не голыми awgN (по «awg2» не понять, что это 3.1 приложения): «3.1 2.0»; линию,
    # которую держат два профиля, — с портом, «3.1:6714 3.1:46567» (DUP-LINE-01). Подписи считаются раз на экран.
    local -A pshort=()
    local -a rowprofs=()
    local pp pl pw=0
    for pp in $PROFILE_IDS; do
        _profile_installed "$pp" || continue
        pl=$(ga_profile_line "$pp" 2>/dev/null)
        [ -n "$pl" ] || continue
        if type ga_profile_line_shared >/dev/null 2>&1 && ga_profile_line_shared "$pp"; then
            pl="$pl:$(_cfg ".profiles.$pp.port")"
        fi
        pshort[$pp]="$pl"
    done
    # Строки страницы — заранее: ширина колонки «Профили» — по самой длинной из них («3.1:6714 3.1:46567» не влезала
    # в 14 знаков, и «Трафик» у этой строки съезжал вправо — D-2 проверки 15.10).
    for ((i = first; i <= last; i++)); do
        IFS=$'\x1f' read -r icon name label profs bytes exp <<< "${all[$i]}"
        pl=""
        for pp in ${profs//,/ }; do pl="${pl:+$pl }${pshort[$pp]:-$pp}"; done
        rowprofs[$i]="${pl:--}"
        [ "${#rowprofs[$i]}" -gt "$pw" ] && pw=${#rowprofs[$i]}
    done
    local cols tbl_narrow=0 nw=16 lw=18 pwide=14 pnarrow=10
    [ "$pw" -gt "$pwide" ] && pwide=$pw
    [ "$pw" -gt "$pnarrow" ] && pnarrow=$pw
    cols=$(ga_term_cols)
    # Широкая таблица — 68 знаков без колонки «Профили». Не влезает — сначала сужается «Подпись» (до 10), потом
    # таблица становится узкой.
    if [ -t 1 ] && [ "$cols" -lt $((68 + pwide)) ]; then
        lw=$(( 18 - (68 + pwide - cols) ))
        if [ "$lw" -lt 10 ]; then
            tbl_narrow=1; lw=18
            # 13 под «Действует до»: заголовок длиннее даты (12 знаков против 10).
            nw=$(( cols - 1 - 9 - 11 - (pnarrow + 1) - 13 )); [ "$nw" -lt 10 ] && nw=10
        fi
    fi
    if [ "$tbl_narrow" = 1 ]; then
        printf '  %b%3s%b  %s %s %s %s %s\n' "$DIM" "#" "$NC" " " \
            "$(_pad "$(t col_name)" "$nw")" "$(_pad "$(t col_profiles)" "$pnarrow")" \
            "$(_pad "$(t col_traffic)" 10)" "$(t col_expires)"
    else
        printf '  %b%3s%b  %s %s %s %s %s %s\n' "$DIM" "#" "$NC" " " \
            "$(_pad "$(t col_name)" 16)" "$(_pad "$(t col_label)" "$lw")" \
            "$(_pad "$(t col_profiles)" "$pwide")" "$(_pad "$(t col_traffic)" 10)" "$(t col_expires)"
    fi
    for ((i = first; i <= last; i++)); do
        IFS=$'\x1f' read -r icon name label profs bytes exp <<< "${all[$i]}"
        [ -n "$name" ] || continue
        profs="${rowprofs[$i]}"
        case "$icon" in
            on)  mark="${GREEN}●${NC}" ;;
            off) mark="${YELLOW}○${NC}" ;;
            exp) mark="${RED}⏳${NC}" ;;
            lim) mark="${RED}▮${NC}" ;;
            *)   mark="${DIM}·${NC}" ;;
        esac
        if [ "$tbl_narrow" = 1 ]; then
            printf '  %b%3d%b) %b %s %s %s %s\n' "$CYAN" "$((i + 1))" "$NC" "$mark" \
                "$(ga_cell "$name" "$nw")" "$(_pad "$profs" "$pnarrow")" \
                "$(_pad "$(_human_bytes "$bytes")" 10)" "${exp:0:10}"
        else
            printf '  %b%3d%b) %b %s %s %s %s %s\n' "$CYAN" "$((i + 1))" "$NC" "$mark" \
                "$(ga_cell "$name" 16)" "$(ga_cell "$label" "$lw")" "$(_pad "$profs" "$pwide")" \
                "$(_pad "$(_human_bytes "$bytes")" 10)" "${exp:0:10}"
        fi
    done
    [ "$pages" -gt 1 ] && echo -e "  ${DIM}$(tf users_page_of "$want_page" "$pages" "$total")${NC}"
    return 0
}

# Список пользователей. Владелец: «в карточку заходят вводом имени — пронумеруй
# и дай выбирать номером». Поэтому цифры отданы СТРОКАМ списка, а действия
# переехали на буквы: иначе «1» значило бы одновременно «добавить» и «первый
# пользователь». Ввод имени остался запасным путём (буква f).
submenu_users() {
    local ch name page=1 idx
    while true; do
        _screen_head "$(t menu_users)"
        _users_render_list "$page"
        page="$GA_USERS_PAGE"
        _legend_users
        echo -e "  ${DIM}$(_rule)${NC}"
        # Управление — только цифрами (решение владельца 12.09.2026): пункты
        # идут сразу за последней строкой списка, поэтому с номерами строк они
        # не сталкиваются никогда, а глаз находит их там же, где кончился список.
        local n_add n_bulk n_bulk_del n_find n_share n_next n_prev
        # «Добавить сразу несколько» и «Удалить сразу несколько» (просьбы владельца 03.10) — следом за одиночным
        # добавлением
        n_add=$(( ${GA_USERS_LAST:-0} + 1 )); n_bulk=$(( ${GA_USERS_LAST:-0} + 2 )); n_bulk_del=$(( ${GA_USERS_LAST:-0} + 3 ))
        n_find=$(( ${GA_USERS_LAST:-0} + 4 )); n_share=$(( ${GA_USERS_LAST:-0} + 5 ))
        n_next=$(( ${GA_USERS_LAST:-0} + 6 )); n_prev=$(( ${GA_USERS_LAST:-0} + 7 ))
        # Номера пунктов — в той же колонке, что номера строк (ширина 3, скобка): список и пункты читаются
        # одним меню, а номера людей не теряются левее пунктов (просьба владельца 25.09.2026).
        printf '  %b%3d%b) %s\n' "$CYAN" "$n_add" "$NC" "$(t users_add_item)"
        printf '  %b%3d%b) %s\n' "$CYAN" "$n_bulk" "$NC" "$(t users_bulk_item)"
        printf '  %b%3d%b) %s\n' "$CYAN" "$n_bulk_del" "$NC" "$(t users_bulk_del_item)"
        printf '  %b%3d%b) %s\n' "$CYAN" "$n_find" "$NC" "$(t users_open_item)"
        # Раздачи — общие для всех людей, поэтому пункт в списке, а не в
        # карточке: снять «ту ссылку, что я вчера кому-то отправил» иначе
        # пришлось бы через карточку человека, которого ещё надо вспомнить.
        printf '  %b%3d%b) %s\n' "$CYAN" "$n_share" "$NC" "$(t share_ui_list_title)"
        if [ "$GA_USERS_PAGES" -gt 1 ]; then
            printf '  %b%3d%b) %s   %b%d%b) %s\n' "$CYAN" "$n_next" "$NC" "$(t users_page_next)" \
                "$CYAN" "$n_prev" "$NC" "$(t users_page_prev)"
        fi
        printf '  %b%3d%b) %s\n' "$CYAN" 0 "$NC" "$(t back)"
        echo -e "  ${DIM}$(ga_win_wrap "$(tf users_pick_legend "$n_add" "$n_bulk" "$n_bulk_del" "$n_find" "$n_share")" 2)${NC}"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        # EOF (оборванная SSH-сессия) → 0: иначе ветка *) «неверный выбор» и
        # снова read — бесконечный цикл на 100 % CPU.
        read -r ch || ch=0

        case "$ch" in
            "") continue ;;
            "$n_add") _user_add_interactive ;;
            "$n_bulk") _users_add_bulk_interactive ;;
            "$n_bulk_del") _users_del_bulk_interactive ;;
            "$n_next")
                # Когда страница одна, этих пунктов на экране нет — и нажатие по
                # ним не должно молча перерисовывать экран: человек ждёт ответа.
                if [ "$GA_USERS_PAGES" -gt 1 ]; then
                    [ "$page" -lt "$GA_USERS_PAGES" ] && page=$((page + 1))
                else
                    log_error "$(t users_bad_number)"; _pause
                fi
                continue ;;
            "$n_prev")
                if [ "$GA_USERS_PAGES" -gt 1 ]; then
                    [ "$page" -gt 1 ] && page=$((page - 1))
                else
                    log_error "$(t users_bad_number)"; _pause
                fi
                continue ;;
            "$n_share") _shares_screen ;;
            "$n_find")
                # Экран показывает НОМЕРА строк, поэтому номер обязан
                # приниматься и здесь: человек видит «2», выбирает «открыть
                # карточку» и получал отказ «пользователь 2 не найден». Сперва
                # пробуем как номер текущей страницы (тот же разбор, что в
                # ветке цифр главного приглашения), потом как имя — имя из
                # одних цифр возможно, но номер на экране важнее.
                name=$(ga_ask "$(t user_ask_name_or_row)" '^[A-Za-z0-9_-]{1,32}$' "$(t user_bad_name)") || name=""
                if [[ "$name" =~ ^[1-9][0-9]{0,3}$ ]]; then
                    idx=$(( name - 1 ))
                    if [ "$idx" -lt "${#GA_USER_NAMES[@]}" ] && [ -n "${GA_USER_NAMES[$idx]:-}" ]; then
                        name="${GA_USER_NAMES[$idx]}"
                    fi
                fi
                [ -n "$name" ] && _user_card "$name"
                ;;
            0) GA_BACK=1; break ;;
            [1-9]|[1-9][0-9]|[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9])
                idx=$((10#$ch - 1))
                if [ "$idx" -lt "${#GA_USER_NAMES[@]}" ] && [ -n "${GA_USER_NAMES[$idx]:-}" ]; then
                    _user_card "${GA_USER_NAMES[$idx]}"
                else
                    log_error "$(t users_bad_number)"
                fi
                ;;
            *) log_error "$(t invalid_choice)" ;;
        esac

        _pause
    done
}

# Имя нового человека. Своё — латиница, цифры, _ и - (подпись = имя, её правят в карточке). Пустой Enter или
# «?» — «🎲 Случайное имя» (решение владельца 27.09, docs/MODES_047.md «Имена ключей»): вариант «прилагательное +
# столица» тем же users_name_suggest, что у бота, панели и MCP (действие name-suggest), — подпись на языке меню,
# id латиницей, не занятые никем из заведённых; «Enter — взять, r — другое, или введите своё». Печатает
# «id<TAB>подпись» (вызов через $()), весь экран — в stderr. Возврат: 0 — имя выбрано; 1 — отмена: «0», конец
# ввода или три негодных имени подряд (прежний ga_ask тоже сдавался после трёх).
_user_add_ask_name() {
    local v sug_id="" sug_label="" js misses=0 prompt zb hint
    zb=$(t ask_zero_back)
    hint=" ${DIM}${zb// /$'\xc2\xa0'}${NC}"
    while true; do
        if [ -n "$sug_id" ]; then prompt=$(t user_name_take_prompt); else prompt=$(t user_ask_name_random); fi
        echo -ne "  $(ga_win_wrap "${WHITE}${prompt}${NC}${hint}${WHITE}:${NC}" 2) " >&2
        if ! IFS= read -r v; then
            echo "" >&2
            return 1
        fi
        v="${v#"${v%%[![:space:]]*}"}"
        v="${v%"${v##*[![:space:]]}"}"
        [ "$v" = "0" ] && return 1
        if [ -z "$v" ] && [ -n "$sug_id" ]; then
            printf '%s\t%s' "$sug_id" "$sug_label"
            return 0
        fi
        # «r» — «другое» только когда вариант уже на экране; «р» — та же клавиша в русской раскладке
        if [ -z "$v" ] || [ "$v" = "?" ] || { [ -n "$sug_id" ] && [[ "$v" == r || "$v" == R || "$v" == р || "$v" == Р ]]; }; then
            GA_ERR_MSG=""
            js=""
            ga_capture js users_name_suggest "${LANG_CODE:-ru}" "$sug_id" 2>/dev/null || js=""
            sug_id=$(jq -r '.id // empty' <<<"$js" 2>/dev/null) || sug_id=""
            sug_label=$(jq -r '.label // empty' <<<"$js" 2>/dev/null) || sug_label=""
            if [[ "$sug_id" =~ ^[A-Za-z0-9_-]{1,32}$ ]] && [ -n "$sug_label" ]; then
                echo -e "  $(tf user_name_suggested "${BOLD}${sug_label}${NC}" "${CYAN}${sug_id}${NC}")" >&2
            else
                sug_id="" sug_label=""
                log_warning "${GA_ERR_MSG:-$(t user_name_random_failed)}"
            fi
            continue
        fi
        if [[ "$v" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; then
            printf '%s\t%s' "$v" "$v"
            return 0
        fi
        # Имя по-человечески — «Мама телефон»: подпись остаётся как написано, имя в системе — латиницей (находка
        # NC-07 критика-новичка): раньше такой ввод получал «Недопустимый идентификатор», и ни слова о том, что
        # подпись по-русски бывает. Предлагаем вариант, как у «🎲»: Enter — взять, r — другое, или своё.
        local lid=""
        if type ga_users_label_valid >/dev/null 2>&1 && ga_users_label_valid "$v"; then
            lid=$(_user_id_from_label "$v") || lid=""
        fi
        if [ -n "$lid" ]; then
            sug_id="$lid"; sug_label="$v"
            echo -e "  $(tf user_name_from_label "${BOLD}${v}${NC}" "${CYAN}${lid}${NC}")" >&2
            continue
        fi
        log_error "$(t user_bad_name_add)"
        misses=$((misses + 1))
        [ "$misses" -lt 3 ] || return 1
    done
}

# _user_id_from_label <подпись> — имя в системе из подписи: «Мама телефон» → mama_telefon. Кириллица — транслитом,
# как у людей, подхваченных из приложения (ga_import_translit), прочее — «_», нижний регистр, до 28 знаков; занятое
# — с -2, -3… Не вышло ни буквы — rc 1.
_user_id_from_label() {
    local s base cand n=1
    s="$1"
    type ga_import_translit >/dev/null 2>&1 && s=$(ga_import_translit "$s")
    base=$(printf '%s' "$s" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -c 'a-z0-9_-' '_' | tr -s '_' \
        | sed 's/^[-_]*//; s/[-_]*$//' | cut -c1-28 | sed 's/[-_]*$//')
    [[ "$base" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || return 1
    cand="$base"
    while type users_exists >/dev/null 2>&1 && users_exists "$cand" 2>/dev/null; do
        n=$((n + 1))
        [ "$n" -le 99 ] || return 1
        cand="${base}-${n}"
    done
    printf '%s' "$cand"
}

# Добавление пользователя. Три замечания владельца сразу:
#   • «отображаемое имя» лишнее — идентификатор и есть имя, вопроса больше нет
#     (поправить подпись можно в карточке, пункт «Изменить отображаемое имя»;
#     у случайного имени подпись — его вариант на языке меню, «Туманный Лондон»);
#   • «профили через запятую» непонятны — тот же экран с галочками, что в
#     мастере, и по умолчанию отмечены ВСЕ установленные профили;
#   • Enter значит «без лимита» и «бессрочно» — ноль вводить не надо.
_user_add_interactive() {
    local name label picked profiles quota days rc i key_ask
    if ! type users_add >/dev/null 2>&1; then
        log_error "$(tf module_missing users_add)"; return 1
    fi
    echo ""
    # Переспрос вместо выхода: опечатка в имени выбрасывала из сценария целиком,
    # и человек заново искал пункт меню (замечание критика). Ноль — отмена.
    picked=$(_user_add_ask_name) || { log_info "$(t cancelled)"; return 1; }
    name="${picked%%$'\t'*}"
    label="${picked#*$'\t'}"

    _user_pick_profiles || return 1
    profiles="$GA_PICKED_PROFILES"

    # Пустая строка — осмысленный ответ («без лимита», «бессрочно»), а вот мусор
    # молча означал то же самое: человек писал «10гб» и получал безлимит, ничего
    # об этом не узнав (замечание критика). Теперь непустой не-числовой ввод —
    # переспрос, и только Enter значит «нет ограничения».
    # Ноль значит ОДНО И ТО ЖЕ во всём продукте — «назад». В карточке
    # пользователя этот уговор уже был, а при заведении того же пользователя
    # ноль молча означал «без лимита»: один вопрос, два смысла у одной клавиши.
    quota=$(GA_EOF_CANCEL=1 ga_ask_optional "$(t user_ask_quota)" '^[0-9]+$' "$(t bad_number)") \
        || { log_info "$(t cancelled)"; return 1; }
    [ "$quota" = 0 ] && { log_info "$(t cancelled)"; return 1; }
    [ -n "$quota" ] || quota=0
    days=$(GA_EOF_CANCEL=1 ga_ask_optional "$(t user_ask_days)" '^[0-9]+$' "$(t bad_number)") \
        || { log_info "$(t cancelled)"; return 1; }
    [ "$days" = 0 ] && { log_info "$(t cancelled)"; return 1; }
    [ -n "$days" ] || days=0

    # Подпись — имя (отдельного вопроса больше нет, правится в карточке) или подпись случайного варианта.
    users_add "$name" "$label" "$profiles" "$quota" "$days" >/dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        # Модуль уже напечатал «Пользователь %s создан, профили: …» — с профилями,
        # которых в этой строке нет. Двух галочек на одно действие быть не должно.
        # Список после возврата должен показать страницу с НОВОЙ записью: при
        # двадцати с лишним людях новый уходит в конец, а список оставался на
        # прежней странице, и человек искал только что заведённого глазами.
        GA_USERS_FOCUS="$name"
        # «Завести человека и сразу отдать ключ» — самая частая операция
        # продукта, и она была разорвана пополам: «создан» и возврат в список,
        # а до ключа ещё девять-десять нажатий. Предлагаем сразу и здесь же;
        # отказ — обычный путь, когда человека заводят впрок.
        # После ключа — те же пункты, что в конце мастера (NC-05, NC-07): QR не влез — как перенести ключ на
        # телефон; подключения больше не ждём сами три минуты — только по просьбе. Enter там уже подтвердил
        # прочитанное, второго «Нажмите Enter» у списка не нужно.
        # С доменом вопрос называет и страницу подключения: для друга это главный путь, и он — первым пунктом
        # следующего шага (NC6-01).
        if type pages_create >/dev/null 2>&1 && _pages_domain_ok; then
            key_ask=$(tf user_added_key_ask_page "$name")
        else
            key_ask=$(tf user_added_key_ask "$name")
        fi
        if confirm "$key_ask"; then
            if _user_key "$name" qr-first; then
                _key_next_steps "$name" "${GA_LAST_KEY_PROFILE:-}" "${GA_LAST_QR_OK:-0}"
                GA_BACK=1
            fi
        fi
    else
        log_error "$(tf user_add_failed "$name")"
    fi
    return $rc
}

# Галочки профилей для нового человека — у одиночного добавления и у «Добавить сразу несколько»: все установленные,
# отмечены все, порядок 3.1 → 2.0 → 1.x, у каждой строка «кому он». Итог — в GA_PICKED_PROFILES через запятую;
# rc 1 — отмена, профилей нет или ничего не отмечено (причина уже сказана).
GA_PICKED_PROFILES=""
_user_pick_profiles() {
    local profiles i
    GA_PICKED_PROFILES=""
    local -a up_ids=() up_labels=() up_notes=() up_state=() up_locked=()
    # ga_profiles_load, а НЕ `mapfile < <(ga_profiles_installed)`: в подстановке
    # процесса код отказа теряется так же, как в $( ), и битый config.json
    # выглядел бы как «профили не установлены» — человек шёл бы ставить их
    # заново поверх работающих. Тот же узор, что у _users_count с ga_capture.
    local up_list=""
    if type ga_profiles_load >/dev/null 2>&1; then
        ga_profiles_load up_list || { log_error "$(t err_config_unreadable)"; return 1; }
        [ -z "$up_list" ] || mapfile -t up_ids <<< "$up_list"
    fi
    if [ "${#up_ids[@]}" -eq 0 ]; then
        log_error "$(t user_no_profiles)"; return 1
    fi
    # Порядок галочек — как везде в меню и мастере: 3.1 → 2.0 → 1.x, а не порядок ключей config.json
    # (awg1, awg2, awg3 — находка LC-17).
    local _p
    local -a _ordered=()
    for _p in $PROFILE_IDS; do
        [[ " ${up_ids[*]} " == *" $_p "* ]] && _ordered+=("$_p")
    done
    up_ids=("${_ordered[@]}")
    for i in "${!up_ids[@]}"; do
        up_labels+=("$(_pr_name "${up_ids[$i]}")")
        # Одна строка «кому он» у каждой линейки, как в мастере: выбор между 3.1 и 2.0 без совета был гаданием (NC-07).
        # По линии профиля, а не по месту: 3.1 бывает и в awg2 (подхват из приложения Amnezia, AWG31-01).
        case "$(_profile_line "${up_ids[$i]}" 2>/dev/null)" in
            3.1) up_notes+=("$(t user_pick_note_awg3)") ;;
            2.0) up_notes+=("$(t user_pick_note_awg2)") ;;
            *)   up_notes+=("$(t user_pick_note_awg1)") ;;
        esac
        up_state+=(1)
        up_locked+=(0)
    done
    _pick_checkboxes "$(t user_pick_profiles_title)" up_labels up_notes up_state up_locked \
        || { log_info "$(t cancelled)"; return 1; }
    profiles=""
    for i in "${!up_ids[@]}"; do
        [ "${up_state[$i]}" = "1" ] || continue
        profiles="${profiles:+$profiles,}${up_ids[$i]}"
    done
    if [ -z "$profiles" ]; then
        log_error "$(t user_no_profiles_picked)"; return 1
    fi
    GA_PICKED_PROFILES="$profiles"
    return 0
}

# «Добавить сразу несколько» (просьба владельца 03.10): сколько (1–100) → те же галочки профилей → имена: Enter —
# случайные «прилагательное + столица», как у «🎲», или префикс — office-01, office-02… → подтверждение →
# users_add_bulk (тот же путь, что одиночное добавление, одно применение к контейнерам на всех) → список
# добавленных и где брать ключи. Лимит и срок не спрашиваются: у всех без ограничений, их ставят в карточке.
# Страниц подключения всем сразу не предлагаем: такого действия в продукте нет (страница — в карточке человека).
_users_add_bulk_interactive() {
    local count prefix names_word js rc n i name label line
    if ! type users_add_bulk >/dev/null 2>&1; then
        log_error "$(tf module_missing users_add_bulk)"; return 1
    fi
    echo ""
    echo -e "  ${DIM}$(ga_win_wrap "$(t users_bulk_intro)" 2)${NC}"
    count=$(ga_ask "$(t users_bulk_ask_count)" '^([1-9][0-9]?|100)$' "$(t users_bulk_bad_count)") \
        || { log_info "$(t cancelled)"; return 1; }
    _user_pick_profiles || return 1
    prefix=$(GA_EOF_CANCEL=1 ga_ask_optional "$(t users_bulk_ask_prefix)" '^[A-Za-z0-9_-]{1,28}$' "$(t users_bulk_bad_prefix)") \
        || { log_info "$(t cancelled)"; return 1; }
    # Ноль — «назад», как на любом вопросе меню, а не префикс «0»
    [ "$prefix" = 0 ] && { log_info "$(t cancelled)"; return 1; }
    if [ -n "$prefix" ]; then
        names_word=$(tf users_bulk_names_prefix "${prefix%"${prefix##*[!_-]}"}")
    else
        names_word=$(t users_bulk_names_random)
    fi
    local p pwords=""
    for p in ${GA_PICKED_PROFILES//,/ }; do pwords="${pwords:+$pwords, }$(_pr_label "$p")"; done
    confirm "$(tf users_bulk_confirm "$count" "$pwords" "$names_word")" \
        || { log_info "$(t cancelled)"; return 1; }
    GA_ERR_CODE=""; GA_ERR_MSG=""
    # Модуль сам говорит, что начал и чем кончил (в том числе «на ком остановилось»); здесь — список и куда дальше
    ga_capture js users_add_bulk "$count" "$GA_PICKED_PROFILES" "$prefix" 0 0 "${LANG_CODE:-ru}"
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    n=$(jq -r '.count // 0' <<<"$js" 2>/dev/null) || n=0
    echo ""
    echo -e "  ${WHITE}$(tf users_bulk_list_title "$n")${NC}"
    i=0
    while IFS=$'\x1f' read -r name label; do
        [ -n "$name" ] || continue
        i=$((i + 1))
        # Подпись случайного имени — рядом с id; у префиксных они совпадают, второй раз не пишем
        if [ "$label" = "$name" ] || [ -z "$label" ]; then line="$name"; else line="$(ga_cell "$label" 24) ${DIM}${name}${NC}"; fi
        echo -e "  ${CYAN}$(_pad "$i" 3)${NC} ${line}"
    done < <(jq -r '.added[]? | [.name, ((.label // "") | gsub("[[:cntrl:]]"; "") | gsub("\\\\"; "∖"))] | join("\u001f")' <<<"$js" 2>/dev/null)
    echo ""
    echo -e "  ${DIM}$(ga_win_wrap "$(t users_bulk_where_keys)" 2)${NC}"
    if type pages_create >/dev/null 2>&1 && _pages_domain_ok; then
        echo -e "  ${DIM}$(ga_win_wrap "$(t users_bulk_where_pages)" 2)${NC}"
    fi
    # Список после возврата — на странице с первым добавленным
    GA_USERS_FOCUS=$(jq -r '.added[0].name // empty' <<<"$js" 2>/dev/null) || GA_USERS_FOCUS=""
    return 0
}

# Номера строк списка → имена: «3-7,12» (пробелы можно), номера — сквозные, как на экране (GA_USER_NAMES по всему
# списку). Повтор — один раз, порядок — как набрано. Итог — в GA_ROWS_NAMES через запятую; rc 1 — номер вне списка,
# кривая запись или больше GA_USERS_BULK_MAX строк (причина уже сказана).
GA_ROWS_NAMES=""
_users_rows_to_names() {
    local spec="${1// /}" tok a b i total="${#GA_USER_NAMES[@]}" max="${GA_USERS_BULK_MAX:-100}"
    local -a toks=() picked=()
    local -A seen=()
    GA_ROWS_NAMES=""
    IFS=',' read -ra toks <<<"$spec"
    for tok in "${toks[@]}"; do
        [ -n "$tok" ] || continue
        if [[ "$tok" =~ ^([1-9][0-9]{0,3})-([1-9][0-9]{0,3})$ ]]; then
            a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
        elif [[ "$tok" =~ ^[1-9][0-9]{0,3}$ ]]; then
            a=$((10#$tok)); b=$a
        else
            log_error "$(tf users_bulk_del_bad_rows "$total")"; return 1
        fi
        if [ "$a" -gt "$b" ] || [ "$b" -gt "$total" ]; then
            log_error "$(tf users_bulk_del_bad_rows "$total")"; return 1
        fi
        for ((i = a; i <= b; i++)); do
            [ -z "${seen[$i]:-}" ] || continue
            seen[$i]=1
            picked+=("${GA_USER_NAMES[$((i - 1))]}")
            if [ "${#picked[@]}" -gt "$max" ]; then
                log_error "$(tf users_bulk_del_rows_many "$max")"; return 1
            fi
        done
    done
    if [ "${#picked[@]}" -eq 0 ]; then
        log_error "$(tf users_bulk_del_bad_rows "$total")"; return 1
    fi
    GA_ROWS_NAMES=$(IFS=,; printf '%s' "${picked[*]}")
    return 0
}

# «Удалить сразу несколько» (просьба владельца 03.10): способ — префикс, номера строк списка, выключенные руками,
# истёкшие, с исчерпанным лимитом → кого именно (до 20 имён и «…и ещё N») → подтверждение числом людей →
# users_del_bulk (порядок одиночного удаления, в контейнер — пачками) → итог. Кого задевает выбор, считает ядро
# (users_del_bulk_preview) — тем же правилом, что и при удалении; изменился список между показом и удалением —
# ядро откажет до изменений (confirm_mismatch), и человек увидит новое число.
_users_del_bulk_interactive() {
    local how names="" prefix="" state="" js count shown i name label line kept
    if ! type users_del_bulk >/dev/null 2>&1 || ! type users_del_bulk_preview >/dev/null 2>&1; then
        log_error "$(tf module_missing users_del_bulk)"; return 1
    fi
    if [ "${#GA_USER_NAMES[@]}" -eq 0 ]; then
        log_info "$(t users_bulk_del_no_users)"; return 1
    fi
    echo ""
    echo -e "  ${DIM}$(ga_win_wrap "$(t users_bulk_del_intro)" 2)${NC}"
    how=$(select_option "$(t users_bulk_del_how)" "$(t users_bulk_del_by_prefix)" "$(t users_bulk_del_by_rows)" \
        "$(t users_bulk_del_by_disabled)" "$(t users_bulk_del_by_expired)" "$(t users_bulk_del_by_quota)")
    case "$how" in
        1)  prefix=$(ga_ask "$(t users_bulk_del_ask_prefix)" '^[A-Za-z0-9_-]{1,28}$' "$(t users_bulk_bad_prefix)") \
                || { log_info "$(t cancelled)"; return 1; } ;;
        2)  js=$(ga_ask "$(t users_bulk_del_ask_rows)" '^[0-9][0-9 ,-]{0,200}$' "$(tf users_bulk_del_bad_rows "${#GA_USER_NAMES[@]}")") \
                || { log_info "$(t cancelled)"; return 1; }
            _users_rows_to_names "$js" || return 1
            names="$GA_ROWS_NAMES" ;;
        3)  state=disabled ;;
        4)  state=expired ;;
        5)  state=quota ;;
        0|"") log_info "$(t cancelled)"; return 1 ;;
        *)  log_error "$(t invalid_choice)"; return 1 ;;
    esac
    GA_ERR_CODE=""; GA_ERR_MSG=""
    ga_capture js users_del_bulk_preview "$names" "$prefix" "$state" || return 1
    count=$(jq -r '.count // 0' <<<"$js" 2>/dev/null) || count=0
    if [ "$count" -eq 0 ]; then
        log_info "$(t users_bulk_del_nobody)"; return 1
    fi
    if [ "$(jq -r '.too_many' <<<"$js" 2>/dev/null)" = true ]; then
        log_error "$(tf users_bulk_del_too_many "$count" "$(jq -r '.max // 100' <<<"$js")")"; return 1
    fi
    echo ""
    echo -e "  ${WHITE}$(tf users_bulk_del_list_title "$count")${NC}"
    i=0
    shown=20
    while IFS=$'\x1f' read -r name label; do
        [ -n "$name" ] || continue
        i=$((i + 1))
        [ "$i" -le "$shown" ] || continue
        if [ "$label" = "$name" ] || [ -z "$label" ]; then line="$name"; else line="$(ga_cell "$label" 24) ${DIM}${name}${NC}"; fi
        echo -e "  ${CYAN}$(_pad "$i" 3)${NC} ${line}"
    done < <(jq -r '.selected[]? | [.name, ((.label // "") | gsub("[[:cntrl:]]"; "") | gsub("\\\\"; "∖"))] | join("\u001f")' <<<"$js" 2>/dev/null)
    [ "$count" -le "$shown" ] || echo -e "  ${DIM}$(tf users_bulk_del_more $((count - shown)))${NC}"
    echo ""
    log_warning "$(t users_bulk_del_warn)"
    confirm_phrase "$count" "$(tf users_bulk_del_ask "$count")" || return 1
    GA_ERR_CODE=""; GA_ERR_MSG=""
    # Модуль сам говорит, что начал и чем кончил (в том числе «на ком остановилось»); здесь — кто удалён и кто оставлен
    ga_capture js users_del_bulk "$count" "$names" "$prefix" "$state" || return 1
    count=$(jq -r '.count // 0' <<<"$js" 2>/dev/null) || count=0
    echo ""
    echo -e "  ${WHITE}$(tf users_bulk_del_done_title "$count")${NC}"
    echo -e "  $(ga_win_wrap "$(jq -r '.deleted | join(", ")' <<<"$js" 2>/dev/null)" 2)"
    kept=$(jq -r '.kept | join(", ")' <<<"$js" 2>/dev/null) || kept=""
    [ -z "$kept" ] || log_warning "$(tf users_bulk_del_kept "$(jq -r '.kept | length' <<<"$js")" "$kept")"
    return 0
}

# Профили, у которых есть пир этого пользователя — из них и выбираем ключ.
# Профили, у которых приватной части ключа нет: пир пришёл из контейнера
# (импорт существующей установки или подхват после потери настроек). Сервер
# знает только открытый ключ клиента, поэтому ни .conf, ни QR по такому пиру не
# собрать — и человек должен узнать об этом в карточке, а не четырьмя ошибками
# подряд, перебрав все пункты выдачи ключа.
_user_imported_profiles() {
    local name="$1" js out=""
    js=$(_users_json)
    if command -v jq >/dev/null 2>&1; then
        # Спрашиваем has_key, а не отсутствие privkey: список приходит через
        # публичный фильтр, который приватный ключ ВЫРЕЗАЕТ, и проверка «privkey
        # пуст» объявляла импортированными всех подряд — предупреждение висело
        # бы в карточке каждого пользователя. Признак считает сам модуль
        # (ga_users_public_filter), одним правилом на меню, бота и панель.
        out=$(printf '%s' "$js" | jq -r --arg n "$name" \
            '.[] | select(.name==$n) | (.peers // {}) | to_entries[] | select(.value.has_key != true) | .key' 2>/dev/null) || out=""
    fi
    printf '%s' "$out"
}

# Профили человека — в том же порядке, что везде: 3.1 → 2.0 → 1.x. По алфавиту первым шёл 2.0, а совет рядом говорил
# «берите 3.1» (находка NC-27): рекомендуемое на телефоне приложение AmneziaWG линию 3.1 читает (lib/clients.json).
_user_profiles() {
    local name="$1" js out=""
    js=$(_users_json)
    if command -v jq >/dev/null 2>&1; then
        out=$(printf '%s' "$js" | jq -r --arg n "$name" \
            '.[] | select(.name==$n) | (.peers // {}) | keys | sort_by({"awg3":0,"awg2":1,"awg1":2}[.] // 9) | .[]' 2>/dev/null) || out=""
    fi
    printf '%s' "$out"
}

# _pr_names_list <профили через пробел, запятую или перевод строки> → «AmneziaWG 3.1 (awg2), AmneziaWG 2.0 (awg3)»:
# профили человека словами (_pr_name), а не голые awgN — по «awg2» не понять, какая это версия AmneziaWG (на сервере
# после подхвата приложения это 3.1). Пусто — пусто.
_pr_names_list() {
    local p out=""
    for p in ${1//,/ }; do
        [ -n "$p" ] || continue
        out="${out:+$out, }$(_pr_name "$p")"
    done
    printf '%s' "$out"
}

# Карточка пользователя — третий уровень и конечная точка (PLAN §5.1).
_user_card() {
    local name="$1" ch js row label enabled quota expires traffic profs
    js=$(_users_json)
    if ! command -v jq >/dev/null 2>&1; then log_warning "$(t err_no_jq)"; return 1; fi
    row=$(printf '%s' "$js" | jq -c --arg n "$name" '.[] | select(.name==$n)' 2>/dev/null | head -1)
    if [ -z "$row" ]; then
        log_error "$(tf user_not_found "$name")"; return 1
    fi

    while true; do
        row=$(_users_json | jq -c --arg n "$name" '.[] | select(.name==$n)' 2>/dev/null | head -1)
        [ -n "$row" ] || return 0
        # Подпись печатается через echo -e: обратная косая черта в ней стала бы
        # управляющей последовательностью в терминале root (SR-08). Новые подписи
        # с «\» отвергаются при вводе, старые — обезвреживаются здесь.
        label=$(printf '%s' "$row"   | jq -r '(.label // "") | gsub("[[:cntrl:]]"; "") | gsub("\\\\"; "∖")')
        # Та же ловушка `//`, что и в списке выше: сравниваем с false явно.
        enabled=$(printf '%s' "$row" | jq -r 'if (.enabled == false) then "0" else "1" end')
        quota=$(printf '%s' "$row"   | jq -r '.quota_bytes // 0')
        expires=$(printf '%s' "$row" | jq -r '.expires // ""')
        traffic=$(printf '%s' "$row" | jq -r '((.traffic.rx // 0) + (.traffic.tx // 0))')
        profs=$(printf '%s' "$row"   | jq -r '(.peers // {}) | keys | sort_by({"awg3":0,"awg2":1,"awg1":2}[.] // 9) | join(", ")')

        echo ""
        echo -e "  ${BOLD}${WHITE}$(tf user_card_title "$name" "${label:-$name}")${NC}"
        echo -e "  ${DIM}$(_rule)${NC}"
        local why=""
        why=$(printf '%s' "$row" | jq -r --arg now "$(_now_iso)" '
            if ((.expires // "") != "" and (.expires // "") < $now) then "exp"
            elif ((.quota_bytes // 0) > 0 and (((.traffic.rx // 0) + (.traffic.tx // 0)) >= (.quota_bytes // 0))) then "lim"
            else "" end' 2>/dev/null) || why=""
        case "$why" in
            exp) why=" — $(t state_reason_expired)" ;;
            lim) why=" — $(t state_reason_quota)" ;;
        esac
        if [ "$enabled" = "1" ]; then
            echo -e "  $(t user_state): ${GREEN}$(t state_enabled)${NC}${YELLOW}${why}${NC}"
        else
            echo -e "  $(t user_state): ${YELLOW}$(t state_disabled)${why}${NC}"
        fi
        if [ "$quota" = "0" ]; then
            echo -e "  $(t user_quota_label): ${DIM}$(t unlimited)${NC}    $(t user_traffic_label): ${CYAN}$(_human_bytes "$traffic")${NC}"
        else
            echo -e "  $(t user_quota_label): ${CYAN}$(_human_bytes "$quota")${NC}    $(t user_traffic_label): ${CYAN}$(_human_bytes "$traffic")${NC}"
        fi
        echo -e "  $(t user_expiry_label): ${CYAN}$([ -n "$expires" ] && _expiry_words "$expires" || t never)${NC}"
        profs=$(_pr_names_list "$profs")
        echo -e "  $(t user_profiles_label): ${CYAN}${profs:--}${NC}"
        # Адрес сервера в ключах — только там, где он что-то значит: у машины два внешних адреса и больше
        # или пользователю адрес уже задан. На сервере с одним адресом строка была бы шумом.
        _user_address_offer "$name" && echo -e "  $(ga_win_wrap "$(_user_address_line "$name")" 2)"
        local imported
        imported=$(_user_imported_profiles "$name" | tr '\n' ' ')
        imported="${imported% }"
        if [ -n "$imported" ]; then
            log_warning "$(_ui_w "$(tf user_imported_note "$(_pr_names_list "$imported")")")"
        fi
        echo -e "  ${DIM}$(_rule)${NC}"
        # Карточка была на четырнадцать пунктов, и человек читал её как стену.
        # Близкое собрано в два: всё про выдачу ключа — в «Ключ», всё про набор
        # профилей — в «Профили». Управление только цифрами (решение владельца
        # 12.09.2026): букв в пунктах не осталось.
        echo -e "  ${CYAN}1${NC}) $(t user_keys_menu)"
        echo -e "  ${CYAN}2${NC}) $(t user_profiles_menu)"
        echo -e "  ${CYAN}3${NC}) $(t user_set_quota)"
        echo -e "  ${CYAN}4${NC}) $(t user_set_expiry)"
        if [ "$enabled" = "1" ]; then
            echo -e "  ${CYAN}5${NC}) $(t user_disable_item)"
        else
            echo -e "  ${CYAN}5${NC}) $(t user_enable_item)"
        fi
        echo -e "  ${CYAN}6${NC}) $(t user_rename_item)"
        # Страница подключения (docs/CLIENTS.md §10) и подписка (docs/SUBSCRIPTION.md) — рядом с остальными
        # способами отдать ключ; удаление остаётся последним, как везде.
        echo -e "  ${CYAN}7${NC}) $(t user_page_item)"
        echo -e "  ${CYAN}8${NC}) $(t user_sub_item)"
        echo -e "  ${CYAN}9${NC}) ${RED}$(t user_delete_item)${NC}"
        echo -e "  ${CYAN}0${NC}) $(t back)"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0

        case "$ch" in
            1) _user_keys_menu "$name" ;;
            2) _user_profiles_menu "$name" ;;
            3) _user_edit_quota "$name" ;;
            4) _user_edit_expiry "$name" ;;
            5)
                # Итог печатает модуль сам — второй строки «✓ Пользователь … выключен.» на то же действие не нужно
                # (находка LC-05).
                if [ "$enabled" = "1" ]; then
                    type users_disable >/dev/null 2>&1 && users_disable "$name" >/dev/null
                else
                    type users_enable >/dev/null 2>&1 && users_enable "$name" >/dev/null
                fi
                ;;
            6) _user_rename "$name" ;;
            7) _pages_screen "$name" ;;
            8) _subs_screen "$name" ;;
            9) _user_delete "$name" && return 0 ;;
            0) GA_BACK=1; return 0 ;;
            "") continue ;;
            *) log_error "$(t invalid_choice)" ;;
        esac

        _pause
    done
}

# Выдать ключ ещё на один профиль. Список — профили, установленные на сервере,
# которых у человека ещё нет; ни одного такого нет — честная строка, а не пустой
# экран с приглашением ввода.
# Ключи одним пунктом: четыре формата и раздача ссылкой жили в карточке
# отдельными строками и занимали треть экрана. Здесь же — предупреждение про
# импортированный ключ, если по этому человеку выдать нечего.
# ── Страница подключения (lib/pages.sh, docs/CLIENTS.md §10) ──────────────────
# Адрес страницы — секрет: печатается только echo в терминал (не через log_*,
# в аудит модуль пишет лишь id), появляется по явному действию — создание или
# «показать адрес ещё раз» — и рядом рисуется QR, как у ключа (_qr_utf8).

# Срок страницы цифрами: пресеты договора и своё значение (12h / 3d / forever).
# Срок — в stdout; rc 1 — передумал или ввёл негодное.
_pages_ask_ttl() {
    local ch ttl n
    echo "" >&2
    echo -e "  ${WHITE}$(t pg_ttl_pick)${NC}" >&2
    # Срок страницы владелец принимал за срок VPN (находка NC6-05 критика-новичка): ключ работает и после неё.
    echo -e "  ${DIM}$(ga_win_wrap "$(t pg_ttl_not_vpn)" 2)${NC}" >&2
    echo -e "  ${CYAN}1${NC}) $(t pg_ttl_1h)" >&2
    echo -e "  ${CYAN}2${NC}) $(t pg_ttl_24h)" >&2
    echo -e "  ${CYAN}3${NC}) $(t pg_ttl_7d)" >&2
    echo -e "  ${CYAN}4${NC}) $(t pg_ttl_30d)" >&2
    echo -e "  ${CYAN}5${NC}) $(t pg_ttl_forever)" >&2
    echo -e "  ${CYAN}6${NC}) $(t pg_ttl_custom)" >&2
    echo -e "  ${CYAN}0${NC}) $(t back)" >&2
    echo -ne "  ${WHITE}$(t choose):${NC} " >&2
    read -r ch || ch=0
    case "$ch" in
        1) ttl=1h ;;
        2) ttl=24h ;;
        3) ttl=7d ;;
        4) ttl=30d ;;
        5) ttl=forever ;;
        6)
            ttl=$(ga_ask "$(t pg_ask_custom)" '^([1-9][0-9]{0,2}[hHdD]|forever)$' "$(t pg_bad_ttl)") || return 1
            ttl=$(printf '%s' "$ttl" | tr '[:upper:]' '[:lower:]')
            # Регекс держит только форму; границы (720 часов, 365 дней) — те же,
            # что у модуля, чтобы отказ пришёл здесь, а не после вопроса.
            n="${ttl%[hd]}"
            case "$ttl" in
                forever) ;;
                *h) [ "$n" -le 720 ] || { log_error "$(t pg_bad_ttl)"; return 1; } ;;
                *)  [ "$n" -le 365 ] || { log_error "$(t pg_bad_ttl)"; return 1; } ;;
            esac
            ;;
        *) return 1 ;;
    esac
    printf '%s' "$ttl"
}

# Адрес и QR по JSON страницы (ответ pages_create или запись списка + pages_url).
_pages_show_url() {
    local js="$1" url forever exp profs
    url=$(_json_field "$js" .url)
    forever=$(_json_field "$js" .forever)
    exp=$(_json_field "$js" .expires)
    profs=$(printf '%s' "$js" | jq -r '(.profiles // []) | join(", ")' 2>/dev/null)
    echo ""
    echo -e "  ${WHITE}$(t pg_link_label)${NC}"
    echo -e "  ${GREEN}${url}${NC}"
    if [ "$forever" = true ]; then
        echo -e "  ${DIM}$(t pg_link_forever)${NC}"
    else
        echo -e "  ${DIM}$(tf pg_link_until "$(ga_human_ts "$exp")")${NC}"
    fi
    [ -n "$profs" ] && echo -e "  ${DIM}$(tf pg_link_profiles "$profs")${NC}"
    # Бессрочной — громче: срок её не остановит.
    if [ "$forever" = true ]; then
        log_warning "$(t pg_forever_warn)"
    else
        log_warning "$(t pg_is_key)"
    fi
    # Страница отдаёт и адрес подписки (вкладка «Подписка»): отзыв страницы его не гасит, если не перевыпустить
    # подписку вместе с ней (B2-2/A2-4).
    case "$(_json_field "$js" .subscription)" in
        created) echo -e "  ${DIM}$(ga_win_wrap "$(t pg_link_sub_created)" 2)${NC}" ;;
        exists)  echo -e "  ${DIM}$(ga_win_wrap "$(t pg_link_sub_exists)" 2)${NC}" ;;
    esac
    echo ""
    echo -e "  ${DIM}$(t pg_qr_title)${NC}"
    _qr_utf8 "$url" || true
    return 0
}

# Есть ли где жить странице: сайт на домене с настоящим сертификатом — та же проверка, что у модуля страниц.
_pages_domain_ok() {
    if type ga_pages_domain_ready >/dev/null 2>&1; then ga_pages_domain_ready; return $?; fi
    _site_domain_ready
}

# Домена нет — страницы не будет, и сказать это надо до вопросов, словами, без команд моста, и сразу дать, как
# отдать ключ без неё: временная ссылка на файл или QR и файл в веб-панели через SSH-туннель (NC-09).
_pages_no_domain_offer() {
    local name="$1" ch i label
    local -a acts=()
    log_warning "$(t pg_no_domain)"
    # Куда идти за доменом: у режима с сайтом (Semi-Pro, Pro на запасном сертификате) — пункт «Домен»: он выпустит
    # Let's Encrypt и переведёт сайт на домен; «Сменить режим» домена там не спрашивал (LZ-10). В Lite сайта нет —
    # сначала режим с сайтом.
    if _site_has_site; then
        echo -e "  ${DIM}$(ga_win_wrap "$(t pg_no_domain_later_site)" 2)${NC}"
    else
        echo -e "  ${DIM}$(ga_win_wrap "$(t pg_no_domain_later)" 2)${NC}"
    fi
    type share_create >/dev/null 2>&1 && acts+=(link)
    _panel_present && acts+=(panel)
    [ "${#acts[@]}" -gt 0 ] || return 0
    echo ""
    echo -e "  ${WHITE}$(t pg_no_domain_ways)${NC}"
    for i in "${!acts[@]}"; do
        case "${acts[$i]}" in
            link) label=$(t pg_way_link) ;;
            *)    label=$(t pg_way_panel) ;;
        esac
        echo -e "  ${CYAN}$((i + 1))${NC}) $(ga_win_wrap "$label" 5)"
    done
    echo -e "  ${CYAN}0${NC}) $(t back)"
    echo -ne "  ${WHITE}$(t choose):${NC} "
    read -r ch || ch=0
    case "$ch" in ""|0) GA_BACK=1; return 0 ;; esac
    if ! [[ "$ch" =~ ^[0-9]{1,2}$ ]] || [ "$((10#$ch))" -lt 1 ] || [ "$((10#$ch))" -gt "${#acts[@]}" ]; then
        log_error "$(t invalid_choice)"
        return 0
    fi
    case "${acts[$((10#$ch - 1))]}" in
        link) _user_share "$name" ;;
        *)
            echo ""
            _panel_tunnel_hint
            echo -e "  ${DIM}$(ga_win_wrap "$(tf kn_panel_where "$name")" 2)${NC}"
            ;;
    esac
    return 0
}

# Создать страницу: срок → pages_create → адрес и QR. Без домена с настоящим сертификатом страницы не будет —
# это говорится до вопроса о сроке, вместе с путями без неё (_pages_no_domain_offer).
_pages_create() {
    local name="$1" ttl js enabled
    type pages_create >/dev/null 2>&1 || { log_error "$(tf module_missing pages_create)"; return 1; }
    # Выключенному человеку страница не откроется (ядро ответит user_disabled
    # и назовёт глагол моста) — говорим своими словами и до вопроса о сроке:
    # включается он пунктом карточки, а не командой.
    enabled=$(_users_json | jq -r --arg n "$name" '.[] | select(.name == $n) | if (.enabled == false) then "0" else "1" end' 2>/dev/null | head -1)
    if [ "${enabled:-1}" = "0" ]; then
        log_warning "$(t pg_user_disabled)"
        return 1
    fi
    # Без домена с настоящим сертификатом странице жить негде — говорим это ДО вопроса о сроке и сразу даём, как
    # отдать ключ без неё (находка NC-09 критика-новичка): раньше отказ приходил после выбора срока, с командами
    # моста (change-mode, share-create) в тексте.
    if ! _pages_domain_ok; then
        _pages_no_domain_offer "$name"
        return 1
    fi
    echo -e "  ${DIM}$(ga_win_wrap "$(t pg_intro)" 2)${NC}"
    ttl=$(_pages_ask_ttl) || { log_info "$(t cancelled)"; return 1; }
    GA_ERR_CODE=""
    if ! ga_capture js pages_create "$name" "$ttl"; then
        if [ "${GA_ERR_CODE:-}" = pages_need_domain ]; then
            # Сайт сняли, пока человек выбирал срок, — те же пути без страницы
            _pages_no_domain_offer "$name"
        elif [ "${GA_ERR_CODE:-}" = no_private_key ]; then
            # Отказ ядра одинаков для SSH, бота и панели и пути по меню не называет (находка UI-9):
            # где лежит «Привязать старый ключ» в SSH — говорим здесь.
            log_dim "$(t pg_attach_where)"
        fi
        return 1
    fi
    _pages_show_url "$js"
    return 0
}

# Страницы пользователя: список без адресов, номер строки — карточка, N+1 — новая.
_pages_screen() {
    local name="$1" js n ch i id forever exp visits profs till n_new
    local -a ids=()
    type pages_list >/dev/null 2>&1 || { log_error "$(tf module_missing pages_list)"; return 1; }
    command -v jq >/dev/null 2>&1 || { log_error "$(t err_no_jq)"; return 1; }
    while true; do
        _screen_head "$(t user_page_item)" "$(tf user_menu_for "$name")"
        ga_capture js pages_list "$name" || js=""
        if ! printf '%s' "$js" | jq -e . >/dev/null 2>&1; then
            log_error "${GA_ERR_MSG:-$(t pg_list_failed)}"; return 1
        fi
        n=$(printf '%s' "$js" | jq -r '.count // 0')
        ids=()
        if [ "${n:-0}" = 0 ]; then
            echo -e "  ${DIM}$(t pg_list_empty)${NC}"
        else
            # Разделитель и чтение через подстановку процесса — по тем же
            # причинам, что у списка раздач (_shares_screen).
            echo -e "  ${DIM}$(t pg_list_cols)${NC}"
            i=0
            while IFS=$'\x1f' read -r id forever exp visits profs; do
                [ -n "$id" ] || continue
                i=$((i + 1)); ids+=("$id")
                if [ "$forever" = true ]; then till=$(t never); else till=$(tf pg_until "$(ga_human_ts "$exp")"); fi
                echo -e "  ${CYAN}$(_pad "$i" 2)${NC} $(tf pg_list_row "${DIM}${id}${NC}" "$till" "$visits" "${profs:--}")"
            done < <(printf '%s' "$js" | jq -r '.pages[]? | [.id, ((.forever // false) | tostring), (.expires // ""),
                ((.visits // 0) | tostring), ((.profiles // []) | join(","))] | join("\u001f")')
        fi
        echo -e "  ${DIM}$(_rule)${NC}"
        n_new=$(( ${#ids[@]} + 1 ))
        echo -e "  ${CYAN}${n_new}${NC}) $(t pg_item_create)"
        echo -e "  ${CYAN}0${NC}) $(t back)"
        [ "${#ids[@]}" -gt 0 ] && echo -e "  ${DIM}$(ga_win_wrap "$(tf pg_pick_legend "$n_new")" 2)${NC}"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0
        case "$ch" in
            "$n_new") _pages_create "$name"; _pause ;;
            0) GA_BACK=1; return 0 ;;
            "") continue ;;
            *)
                # Номер — не длиннее четырёх цифр и десятичный: число длиннее int64 роняло сравнение, индекс
                # переполнялся, и set -u закрывало всё меню (находка SR-53).
                if ! [[ "$ch" =~ ^[0-9]{1,4}$ ]] || [ "$((10#$ch))" -lt 1 ] || [ "$((10#$ch))" -gt "${#ids[@]}" ]; then
                    log_error "$(t invalid_choice)"; _pause; continue
                fi
                _pages_card "${ids[$((10#$ch - 1))]}" "$name"
                ;;
        esac
    done
}

# _pages_user_has_sub <имя> <subscription из записи страницы> → 0, если у пользователя подписка есть СЕЙЧАС: страница
# отдаёт её адрес на лету (pages_server: subs.for_user), а поле subscription — снимок при создании страницы (у старых
# страниц его нет вовсе, у «off» подписку могли завести позже; R-1). Правило — как у ядра отзыва: каталог с секретом
# и владелец на месте. Модуля подписок нет — по снимку.
_pages_user_has_sub() {
    local u="${1:-}" psub="${2:-}"
    if type ga_subs_exists >/dev/null 2>&1 && type ga_subs_dir >/dev/null 2>&1; then
        [[ "$u" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || return 1
        ga_subs_exists "$u" || return 1
        ! { type _ga_subs_owner_gone >/dev/null 2>&1 && _ga_subs_owner_gone "$(ga_subs_dir)/$u"; }
        return
    fi
    [ "$psub" = created ] || [ "$psub" = exists ]
}

# Карточка страницы: срок, открытия, ключи; адрес — только по пункту.
_pages_card() {
    local id="$1" name="$2" ch js rec forever last
    while true; do
        ga_capture js pages_list "$name" || js=""
        rec=$(printf '%s' "$js" | jq -c --arg id "$id" '.pages[]? | select(.id == $id)' 2>/dev/null | head -1)
        if [ -z "$rec" ]; then log_error "$(tf pg_not_found "$id")"; return 1; fi
        _screen_head "$(tf pg_card_title "$id")" "$(tf user_menu_for "$name")"
        forever=$(_json_field "$rec" .forever)
        last=$(_json_field "$rec" .last_visit)
        echo -e "  $(t pg_card_created): ${CYAN}$(ga_human_ts "$(_json_field "$rec" .created)")${NC}"
        if [ "$forever" = true ]; then
            echo -e "  $(t pg_card_expires): ${CYAN}$(t never)${NC}"
        else
            echo -e "  $(t pg_card_expires): ${CYAN}$(ga_human_ts "$(_json_field "$rec" .expires)")${NC}"
        fi
        echo -e "  $(t pg_card_visits): ${CYAN}$(_json_field "$rec" .visits)${NC}    $(t pg_card_last): ${CYAN}$([ -n "$last" ] && ga_human_ts "$last" || t pg_never_opened)${NC}"
        echo -e "  $(t pg_card_profiles): ${CYAN}$(printf '%s' "$rec" | jq -r '(.profiles // []) | join(", ")')${NC}"
        if [ "$(_json_field "$rec" .mirror)" = true ]; then
            echo -e "  $(t pg_card_mirror): ${CYAN}$(t pg_mirror_on)${NC}"
        else
            echo -e "  $(t pg_card_mirror): ${CYAN}$(t pg_mirror_off)${NC}"
        fi
        echo -e "  ${DIM}$(ga_win_wrap "$(t pg_card_hint)" 2)${NC}"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -e "  ${CYAN}1${NC}) $(t pg_item_url)"
        echo -e "  ${CYAN}2${NC}) ${RED}$(t pg_item_revoke)${NC}"
        echo -e "  ${CYAN}0${NC}) $(t back)"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0
        case "$ch" in
            1)
                type pages_url >/dev/null 2>&1 || { log_error "$(tf module_missing pages_url)"; _pause; continue; }
                # Срок и ключи — из записи списка: показ тот же, что при выдаче. Ответ с адресом —
                # в jq через stdin, а не аргументом: argv читает любой локальный пользователь (SEC46-02).
                if ga_capture js pages_url "$id"; then
                    _pages_show_url "$(printf '%s' "$js" | jq -c --argjson r "$rec" '$r + .')"
                fi
                _pause
                ;;
            2)
                type pages_revoke >/dev/null 2>&1 || { log_error "$(tf module_missing pages_revoke)"; _pause; continue; }
                # Ссылка могла быть уже отправлена человеку — отзыв гасит её у него в руках.
                local psub rsub="off" rkeys="off" pch pvis
                psub=$(_json_field "$rec" .subscription)
                if _pages_user_has_sub "$(_json_field "$rec" .user)" "$psub"; then
                    # Страница отдаёт адрес подписки пользователя на лету (вкладка «Подписка»), какой бы ни была
                    # подписка при создании страницы: выбор, гасить ли и его (B2-2/A2-4, R-1). Подписку завела эта
                    # страница — «рекомендуется», как галочка, включённая по умолчанию в панели.
                    echo ""
                    echo -e "  $(ga_win_wrap "$(tf pg_revoke_ask "$id")" 2)"
                    echo -e "  ${DIM}$(ga_win_wrap "$(t pg_revoke_sub_note)" 2)${NC}"
                    if [ "$psub" = created ]; then
                        echo -e "  ${CYAN}1${NC}) $(t pg_revoke_with_sub) ${GREEN}($(t pg_recommended))${NC}"
                    else
                        echo -e "  ${CYAN}1${NC}) $(t pg_revoke_with_sub)"
                    fi
                    echo -e "  ${CYAN}2${NC}) $(t pg_revoke_page_only)"
                    echo -e "  ${CYAN}0${NC}) $(t back)"
                    echo -ne "  ${WHITE}$(t choose):${NC} "
                    read -r pch || pch=0
                    case "$pch" in
                        1) rsub=on ;;
                        2) rsub=off ;;
                        *) log_info "$(t cancelled)"; _pause; continue ;;
                    esac
                else
                    confirm "$(tf pg_revoke_ask "$id")" || { log_info "$(t cancelled)"; _pause; continue; }
                fi
                # B3-3: ключ, который страница уже отдала, отзыв не гасит. Открывали — сколько раз и отдельный вопрос
                # (по умолчанию «нет»: перевыпуск отключит и устройства самого пользователя до нового ключа). Профили
                # названы те же, что перевыпустит ядро (ga_pages_revoke_key_profiles): страницы, а с подпиской — и её
                # линий (Н-1). Перевыпускать нечего (ключи из приложения) — вопроса нет.
                pvis=$(_json_field "$rec" .visits); [[ "$pvis" =~ ^[0-9]+$ ]] || pvis=0
                if [ "$pvis" -gt 0 ] && type ga_pages_revoke_key_profiles >/dev/null 2>&1; then
                    local kpj kpage ksub
                    kpj=$(ga_pages_revoke_key_profiles "$(_json_field "$rec" .user)" \
                        "$(printf '%s' "$rec" | jq -c '[(.profiles // [])[] | strings]' 2>/dev/null || echo '[]')" "$rsub")
                    kpage=$(_pr_names_list "$(printf '%s' "$kpj" | jq -r '.page | join(" ")' 2>/dev/null)")
                    ksub=$(_pr_names_list "$(printf '%s' "$kpj" | jq -r '.sub | join(" ")' 2>/dev/null)")
                    if [ -n "$kpage$ksub" ]; then
                        echo -e "  ${DIM}$(ga_win_wrap "$(tf pg_revoke_keys_note "$pvis")" 2)${NC}"
                        if [ -n "$kpage" ] && [ -n "$ksub" ]; then
                            confirm "$(tf pg_revoke_keys_ask_both "$kpage" "$ksub")" && rkeys=on
                        elif [ -n "$kpage" ]; then
                            confirm "$(tf pg_revoke_keys_ask_page "$kpage")" && rkeys=on
                        else
                            confirm "$(tf pg_revoke_keys_ask_sub "$ksub")" && rkeys=on
                        fi
                    fi
                fi
                pages_revoke "$id" "$rsub" "$rkeys" >/dev/null && return 0
                _pause
                ;;
            0) GA_BACK=1; return 0 ;;
            "") continue ;;
            *) log_error "$(t invalid_choice)"; _pause ;;
        esac
    done
}

# ── Подписка: постоянная ссылка для Clash и роутеров (lib/subs.sh, docs/SUBSCRIPTION.md) ──
# Адреса подписки — секрет того же порядка, что ключ: печатаются только echo в терминал (не log_*: в аудит модуль
# пишет лишь имя) и только по явному действию — создать, «Показать адреса», перевыпустить; рядом — QR главного
# адреса (профиль mihomo), его сканируют FlClash и Clash Meta for Android.

# Адреса по форматам с подсказкой, кому какой (ответ subs_create / subs_show / subs_rotate).
_subs_show_urls() {
    local js="$1" label base url line suffix fmt
    base=$(_json_field "$js" .base_url)
    label=$(_json_field "$js" .label)
    if [ -z "$base" ]; then
        # Сайт не на домене: адресов сейчас нет — подписка на паузе, секрет цел.
        log_warning "$(t sb_paused)"
        return 0
    fi
    # Ядро с выбором по клиенту (поле clients): вместо списка по форматам — выбор приложения; ядро старше — как раньше.
    if _subs_has_clients "$js"; then
        _subs_clients_screen "$js"
        return 0
    fi
    if [ "$(printf '%s' "$js" | jq -r '.urls | length' 2>/dev/null)" = 0 ]; then
        log_warning "$(t sb_no_keys)"
        return 0
    fi
    echo ""
    echo -e "  ${WHITE}$(tf sb_urls_title "${label:-$(_json_field "$js" .name)}")${NC}"
    echo -e "  ${DIM}$(ga_win_wrap "$(t sb_for_mihomo)" 2)${NC}"
    url=$(printf '%s' "$js" | jq -r '.urls[] | select(.suffix == "mihomo.yaml") | .url' 2>/dev/null)
    echo -e "  ${GREEN}${url}${NC}"
    echo -e "  ${DIM}$(ga_win_wrap "$(t sb_for_conf)" 2)${NC}"
    while IFS=$'\x1f' read -r fmt line suffix url; do
        [ "$fmt" = conf ] || continue
        echo -e "    AmneziaWG ${line}: ${GREEN}${url}${NC}"
    done < <(printf '%s' "$js" | jq -r '.urls[] | [.format, .line, .suffix, .url] | join("\u001f")' 2>/dev/null)
    echo -e "  ${DIM}$(ga_win_wrap "$(t sb_for_vpn)" 2)${NC}"
    while IFS=$'\x1f' read -r fmt line suffix url; do
        [ "$fmt" = vpn ] || continue
        if [ -z "$line" ]; then
            echo -e "    $(t sb_all_lines): ${GREEN}${url}${NC}"
        else
            echo -e "    AmneziaWG ${line}: ${GREEN}${url}${NC}"
        fi
    done < <(printf '%s' "$js" | jq -r '.urls[] | [.format, .line, .suffix, .url] | join("\u001f")' 2>/dev/null)
    echo -e "  ${DIM}$(ga_win_wrap "$(tf sb_update_note "$(_json_field "$js" .update_interval)")" 2)${NC}"
    [ "$(_json_bool "$js" .disabled)" = true ] && log_warning "$(t sb_user_off)"
    log_warning "$(t sb_is_key)"
    echo ""
    echo -e "  ${DIM}$(t sb_qr_title)${NC}"
    _qr_utf8 "$(printf '%s' "$js" | jq -r '.urls[] | select(.suffix == "mihomo.yaml") | .url' 2>/dev/null)" || true
    return 0
}

# ── Подписка по клиенту: поле clients ответа subs_create / subs_show / subs_rotate ──
# Вместо списка адресов по форматам — выбор приложения по группам «Обновляется сам» (приложение само забирает свежий
# ключ по подписке) и «Разово» (ключ по ссылке один раз); записи с одним app — одно приложение, у него «Формат» по
# variant (AWG Manager). Номер — экран приложения без адресов (решение владельца 04.10.2026, как в панели и боте):
# 1) QR-код — по qr и qr_alt (qr "" — с причиной), 2) показать, что вставлять — по copy (адрес, команда, ключ линии), у
# нескольких форматов и линий — пункты «другой формат» и «другая линия». QR и ключ линии — тем же путём, что «Ключ: QR» и
# «Ключ: ссылка» (_user_key с профилем линии, в аудит — выдача ключа). «Короткая ссылка» и «Заменить короткую ссылку» —
# только с 2FA через бота (short_available ответа, _subs_short_show / _subs_short_swap). Ответ с адресами — только в
# переменной и в jq через stdin (SEC46-02); адреса печатаются в терминал, в журнал не идут.

# Записи ответа в порядке групп (сначала «Обновляется сам»), у каждой — только пункты с адресом https.
GA_SUBC_JQ='[ ("auto", "once") as $g | .clients[]? | select(type == "object" and .group == $g)
    | .items = [ .items[]? | select(type == "object") | select((.url | type) == "string")
                 | select(.url | startswith("https://")) ]
    | select((.items | length) > 0) ]'
# Приложения списка: записи с одним app — одно приложение (группа — у первой записи), его форматы — эти записи.
GA_SUBC_APPS_JQ="${GA_SUBC_JQ}"' | reduce .[] as $c ([]; ($c.app // $c.id) as $k
    | if any(.[]; .key == $k) then map(if .key == $k then .variants += [$c] else . end)
      else . + [{key: $k, group: $c.group, variants: [$c]}] end)'

# _subs_has_clients <JSON> — есть ли в ответе приложения с адресами (ядро с выбором по клиенту).
_subs_has_clients() {
    local n
    n=$(printf '%s' "$1" | jq -r "${GA_SUBC_JQ} | length" 2>/dev/null) || n=0
    [[ "$n" =~ ^[1-9][0-9]*$ ]]
}

# _subs_platforms «android windows tvos» → «Android, Windows, Apple TV» — слова зеркала сборок.
_subs_platforms() {
    local p out=""
    for p in ${1:-}; do
        [[ "$p" =~ ^[a-z_]{1,16}$ ]] || continue
        if [ "$p" = tvos ]; then p=$(t sb_platform_tvos); else p=$(_mirror_platform_name "$p"); fi
        out="${out:+$out, }$p"
    done
    printf '%s' "$out"
}

# _subs_line_profile <JSON ответа> <линия> → профиль человека с ключом на сервере, который подписка отдаёт по линии.
_subs_line_profile() {
    local p
    p=$(printf '%s' "$1" | jq -r --arg l "${2:-}" \
        '[.lines[]? | select(type == "object" and .line == $l and .has_key != false) | (.profile // empty)] | first // empty' 2>/dev/null)
    [[ "$p" =~ ^[a-z0-9]{1,16}$ ]] && printf '%s' "$p"
}

# Ссылка «в приложение» — своя схема приложения (flclash://, incy://, wg://); javascript:, data: и прочие — никогда.
_subs_deeplink_ok() {
    local d="${1:-}"
    [[ "$d" =~ ^[A-Za-z][A-Za-z0-9+.-]{1,31}://[^[:space:]]+$ ]] || return 1
    case "${d,,}" in javascript:*|data:*|vbscript:*|file:*|about:*|blob:*) return 1 ;; esac
    return 0
}

# _subs_qr_off <платформы через пробел> — почему QR не нужен (qr ""), теми же словами, что панель и бот: роутеру —
# команда; Clash на компьютере — вставить строкой; продуктам серии (без платформ) — вставляют строкой; остальным — не
# для этого приложения.
_subs_qr_off() {
    local p desk=1 n=0
    for p in ${1:-}; do
        n=$((n + 1))
        [ "$p" = router ] && { t sb_noqr_router; return 0; }
        case "$p" in windows|macos|linux) ;; *) desk=0 ;; esac
    done
    if [ "$n" = 0 ]; then t sb_noqr_paste
    elif [ "$desk" = 1 ]; then t sb_noqr_desktop
    else t sb_noqr_app
    fi
}

# Выбор приложения: группы и номера. Номер — экран приложения (он сам ждёт Enter после показанного и возвращает 0 без
# паузы); 0 и Enter — назад к подписке без лишней паузы.
_subs_clients_screen() {
    local js="$1" label grp name plats rec last n ch
    label=$(_json_field "$js" .label)
    [ -n "$label" ] || label=$(_json_field "$js" .name)
    while true; do
        _screen_head "$(tf sb_clients_title "$label")" "$(t sb_clients_note)"
        n=0
        last=""
        while IFS=$'\x1f' read -r grp name plats rec; do
            [ -n "$grp" ] || continue
            if [ "$grp" != "$last" ]; then
                [ -n "$last" ] && echo ""
                if [ "$grp" = auto ]; then
                    echo -e "  ${WHITE}$(ga_win_wrap "$(t sb_grp_auto)" 2)${NC}"
                else
                    echo -e "  ${WHITE}$(ga_win_wrap "$(t sb_grp_once)" 2)${NC}"
                fi
                last="$grp"
            fi
            n=$((n + 1))
            plats=$(_subs_platforms "$plats")
            printf '  %b%s%b) %s' "$CYAN" "$n" "$NC" "$name"
            [ "$rec" = true ] && printf ' %b· %s%b' "$GREEN" "$(t sb_recommended)" "$NC"
            [ -n "$plats" ] && printf '  %b%s%b' "$DIM" "$plats" "$NC"
            printf '\n'
        done < <(printf '%s' "$js" | jq -r --arg lang "${LANG_CODE:-ru}" "${GA_SUBC_APPS_JQ}"' | .[] | .variants[0] as $v
            | [.group, (if $lang == "en" and (($v.name_en // "") != "") then $v.name_en else ($v.name // $v.id // "?") end),
               (($v.platforms // []) | map(tostring) | join(" ")), (if any(.variants[]; .recommended == true) then "true" else "false" end)]
            | map(tostring) | join("\u001f")' 2>/dev/null)
        [ "$n" -gt 0 ] || return 0
        echo -e "  ${CYAN}0${NC}) $(t back)"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0
        case "$ch" in ""|0) GA_BACK=1; return 0 ;; esac
        if ! [[ "$ch" =~ ^[0-9]{1,3}$ ]] || [ "$((10#$ch))" -lt 1 ] || [ "$((10#$ch))" -gt "$n" ]; then
            log_error "$(t invalid_choice)"
            _pause
            continue
        fi
        _subs_client_screen "$js" "$((10#$ch - 1))"
        _pause
    done
}

# Экран приложения без адресов: как обновляется и где работает, формат и линия, как добавить, предупреждения; пункты —
# «QR-код», «показать, что вставлять», «другой формат», «другая линия». После показанного — «Нажмите Enter» и снова
# экран; 0 и Enter — назад к приложениям.
_subs_client_screen() {
    local js="$1" idx="$2" app who uname nv vi=0 li=0 c ni name grp hours plats hint mode variant line url cmd dl qr qra copy kf
    local label prof ch n i kind what text sfx shorton
    local -a acts=()
    app=$(printf '%s' "$js" | jq -c --argjson i "$idx" "${GA_SUBC_APPS_JQ}"' | .[$i] // empty' 2>/dev/null)
    [ -n "$app" ] || { log_error "$(t invalid_choice)"; return 1; }
    uname=$(_json_field "$js" .name)
    who=$(_json_field "$js" .label)
    [ -n "$who" ] || who="$uname"
    nv=$(printf '%s' "$app" | jq -r '.variants | length' 2>/dev/null)
    [[ "$nv" =~ ^[0-9]+$ ]] || nv=1
    while true; do
        c=$(printf '%s' "$app" | jq -c --argjson v "$vi" '.variants[$v]' 2>/dev/null)
        ni=$(printf '%s' "$c" | jq -r '.items | length' 2>/dev/null)
        [[ "$ni" =~ ^[0-9]+$ ]] && [ "$ni" -gt 0 ] || ni=1
        [ "$li" -lt "$ni" ] || li=0
        name=$(printf '%s' "$c" | jq -r --arg lang "${LANG_CODE:-ru}" \
            'if $lang == "en" and ((.name_en // "") != "") then .name_en else (.name // .id // "?") end' 2>/dev/null)
        grp=$(_json_field "$c" .group)
        variant=$(printf '%s' "$c" | jq -r --arg lang "${LANG_CODE:-ru}" \
            'if (.variant | type) == "object" then (.variant[$lang] // .variant.ru // .variant.en // "") else (.variant // "") end | tostring' 2>/dev/null)
        # «Обновляется сам»: 0 часов — интервал сервера (update_interval ответа).
        hours=$(_json_field "$c" .update_hours)
        [[ "$hours" =~ ^[0-9]{1,4}$ ]] && [ "$hours" -gt 0 ] || hours=$(_json_field "$js" .update_interval)
        [[ "$hours" =~ ^[0-9]{1,4}$ ]] && [ "$hours" -gt 0 ] || hours=12
        plats=$(printf '%s' "$c" | jq -r '(.platforms // []) | map(tostring) | join(" ")' 2>/dev/null)
        hint=$(printf '%s' "$c" | jq -r --arg lang "${LANG_CODE:-ru}" \
            'if (.hint | type) == "object" then (.hint[$lang] // .hint.ru // .hint.en // "") else "" end | tostring' 2>/dev/null)
        hint="${hint//\{minutes\}/$((hours * 60))}"
        IFS=$'\x1f' read -r line url cmd dl qr qra copy kf sfx < <(printf '%s' "$c" | jq -r --argjson i "$li" '.items[$i]
            | [(.line // "" | tostring), (.url // "" | tostring), (.command // "" | tostring), (.deeplink // "" | tostring),
               (.qr // "" | tostring), (.qr_alt // "" | tostring), (.copy // "" | tostring), (.key_format // "" | tostring),
               (.suffix // "" | tostring)]
            | join("\u001f")' 2>/dev/null)
        if [ -n "$line" ]; then label="AmneziaWG $line"; else label=$(t sb_all_lines_short); fi
        # Что отдаёт «показать, что вставлять» — поле copy: url — адрес, command — команду, key — ключ линии в key_format.
        case "$copy" in
            url|command) kind="$copy" ;;
            key) if [ "$kf" = conf ]; then kind="conf"; else kind="vpn"; fi ;;
            *) if [ -n "$cmd" ]; then kind="command"; else kind="url"; fi ;;
        esac
        prof=$(_subs_line_profile "$js" "$line")
        # Короткая ссылка (2FA через Telegram-бота): только при short_available ответа и ядре, которое знает short-ensure
        shorton=0
        if [ "$(_json_bool "$js" .short_available)" = true ] && [[ "$sfx" =~ $GA_SHORT_SUFFIX_RE ]] && _action_known short-ensure; then
            shorton=1
        fi
        if [ "$grp" = auto ]; then mode=$(tf sb_auto_every "$hours"); else mode=$(t sb_once_note); fi
        [ -n "$plats" ] && mode="$mode · $(_subs_platforms "$plats")"
        _screen_head "$(tf sb_client_title "$name" "$who")" "$mode"
        [ "$nv" -gt 1 ] && echo -e "  $(tf sb_format_now "$variant")"
        [ "$ni" -gt 1 ] && echo -e "  $(tf sb_line_now "$label")"
        [ -n "$hint" ] && echo -e "  $(ga_win_wrap "$(tf sb_howto "$hint")" 2)"
        [ "$(_json_bool "$js" .disabled)" = true ] && log_warning "$(t sb_user_off)"
        log_warning "$(t sb_is_key)"
        echo -e "  ${DIM}$(_rule)${NC}"
        acts=(qr paste)
        if [ "$qr" = url ] || { [ "$qr" = deeplink ] && _subs_deeplink_ok "$dl"; } || { [ "$qr" = key ] && [ -n "$prof" ]; }; then
            echo -e "  ${CYAN}1${NC}) $(t sb_item_qr)"
        elif [ "$qr" = key ]; then
            echo -e "  ${CYAN}1${NC}) ${DIM}$(tf sb_item_qr_off "$(t sb_noqr_nokey)")${NC}"
        else
            echo -e "  ${CYAN}1${NC}) ${DIM}$(tf sb_item_qr_off "$(_subs_qr_off "$plats")")${NC}"
        fi
        case "$kind" in
            command) what=$(t sb_paste_cmd) ;;
            vpn) what=$(t sb_paste_vpn) ;;
            conf) what=$(t sb_paste_conf) ;;
            *) what=$(t sb_paste_url) ;;
        esac
        echo -e "  ${CYAN}2${NC}) $(tf sb_item_paste "$what")"
        n=3
        if [ "$shorton" = 1 ]; then
            echo -e "  ${CYAN}${n}${NC}) $(t sb_item_short)"; acts+=(short); n=$((n + 1))
            echo -e "  ${CYAN}${n}${NC}) $(t sb_item_short_swap)"; acts+=(swap); n=$((n + 1))
        fi
        if [ "$nv" -gt 1 ]; then echo -e "  ${CYAN}${n}${NC}) $(tf sb_item_format "$variant")"; acts+=(format); n=$((n + 1)); fi
        if [ "$ni" -gt 1 ]; then echo -e "  ${CYAN}${n}${NC}) $(tf sb_item_line "$label")"; acts+=(line); fi
        echo -e "  ${CYAN}0${NC}) $(t back)"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0
        case "$ch" in ""|0) GA_BACK=1; return 0 ;; esac
        if ! [[ "$ch" =~ ^[0-9]{1,2}$ ]] || [ "$((10#$ch))" -lt 1 ] || [ "$((10#$ch))" -gt "${#acts[@]}" ]; then
            log_error "$(t invalid_choice)"
            continue
        fi
        case "${acts[$((10#$ch - 1))]}" in
            format) vi=$(( (vi + 1) % nv )); li=0; continue ;;
            line) li=$(( (li + 1) % ni )); continue ;;
            short) _subs_short_show "$uname" "$sfx" "$name" "$label" "$url" "$cmd" "$kind" || true ;;
            swap) _subs_short_swap "$uname" "$sfx" || true ;;
            qr)
                # QR адреса (сканер приложения) или ссылки «в приложение» (камера телефона), с qr_alt — второй код;
                # QR ключа линии — как «Ключ: QR».
                if [ "$qr" = key ] && [ -n "$prof" ]; then
                    if [ "$kf" = conf ]; then _user_key "$uname" qr-conf "" "$prof" || true
                    else _user_key "$uname" qr-vpn "" "$prof" || true; fi
                elif [ "$qr" = url ] || { [ "$qr" = deeplink ] && _subs_deeplink_ok "$dl"; }; then
                    for i in main alt; do
                        if [ "$i" = main ] && [ "$qr" = deeplink ]; then text="$dl"; echo ""; echo -e "  ${DIM}$(tf sb_qr_camera "$name")${NC}"
                        elif [ "$i" = main ]; then text="$url"; echo ""; echo -e "  ${DIM}$(t sb_qr_url)${NC}"
                        elif [ "$qra" = url ]; then text="$url"; echo ""; echo -e "  ${DIM}$(tf sb_qr_scanner "$name")${NC}"
                        else continue; fi
                        _qr_utf8 "$text" || true
                    done
                else
                    log_info "$(tf sb_item_qr_off "$(_subs_qr_off "$plats")")"
                fi
                ;;
            paste)
                # То, что вставляют: ключ линии — как «Ключ: ссылка» / «Ключ: текст .conf»; нет ключа на сервере — адрес.
                echo ""
                [ -n "$hint" ] && echo -e "  ${WHITE}$(ga_win_wrap "$(tf sb_paste_where "$name" "$hint")" 2)${NC}"
                if [ "$kind" = vpn ] && [ -n "$prof" ]; then
                    _user_key "$uname" vpn "" "$prof" || true
                elif [ "$kind" = conf ] && [ -n "$prof" ]; then
                    _user_key "$uname" conf "" "$prof" || true
                elif [ "$kind" = command ]; then
                    printf '    %b%s%b\n' "$GREEN" "$cmd" "$NC"
                else
                    printf '    %b%s%b\n' "$GREEN" "$url" "$NC"
                fi
                ;;
        esac
        _pause
    done
}

# ── Короткие ссылки с 2FA через Telegram-бота (договор ядра и интерфейсов — docs/SUBSCRIPTION.md) ──
# Код https://<домен>/<КОД> — у пары «подписка + суффикс»; вход по нему и замену подтверждает администратор в боте (число
# на экране устройства). Действия ядра — мост short-* в этой же оболочке (_subs_short_call): имена функций модуля — дело
# ядра, договор — ответы моста. Ответ с кодом — только в переменной и в jq через stdin (SEC46-02); на экран — по явному
# пункту; код бана — ••••XXXX.
GA_SHORT_SUFFIX_RE='^(all\.(yaml|txt|vpn)|awg[0-9]{2}\.(vpn|conf))$'

# _subs_short_call <действие> [--k=v …] → ответ моста одной строкой (последний JSON-объект со status). Мост — в подоболочке
# этой же оболочки: его переменные (ARG_*, замок, язык) в меню не утекают, нового bash нет; кто зовёт — ssh (аудит ядра).
_subs_short_call() {
    local action="$1" out line last=""
    shift
    out=$( (GOAMNEZIA_WHO=ssh GOAMNEZIA_CALLER=ssh action_dispatch --action="$action" --json "$@") 2>/dev/null ) || true
    while IFS= read -r line; do
        case "$line" in
            "{"*) printf '%s' "$line" | jq -e 'type == "object" and has("status")' >/dev/null 2>&1 && last="$line" ;;
        esac
    done <<<"$out"
    printf '%s' "$last"
}

# Отказ моста словами, без служебного кода (SL-UX-03: «… попробуйте через 5 мин (short_pending)» в боте): бот не настроен —
# что делать; у известных отказов слова ядра сами говорят, что делать («попробуйте через 5 мин»); хвост «(код)» в словах
# ядра снимается; слов нет или отказ незнакомый — «не выполнено» и что делать. Ответа нет вовсе — ядро старше меню.
_subs_short_fail() {
    local code msg
    code=$(_json_field "$1" .code)
    msg=$(_json_field "$1" .message)
    msg=$(printf '%s' "$msg" | LC_ALL=C sed -E 's/[[:space:]]*\((rc=)?[A-Za-z0-9_.:-]+\)[[:space:]]*\.?[[:space:]]*$//')
    if [ "$msg" = "$code" ] || [[ "$msg" =~ ^[a-z0-9_]+$ ]]; then msg=""; fi
    case "$code" in
        "") log_error "${msg:-$(t sb_short_bad)}" ;;
        short_need_bot) log_error "$(t sb_short_need_bot)" ;;
        short_pending|short_limit|short_not_found|short_request_not_found|short_bad_answer|bad_suffix|bad_target|short_busy|sub_not_found)
            log_error "${msg:-$(t sb_short_failed)}" ;;
        *)
            log_error "${msg:-$(t sb_short_failed)}"
            log_dim "$(t sb_short_retry)" ;;
    esac
}

# Итог запроса из ответа short-status: ok | wrong | denied | swapped | expired | frozen, pending — ждёт; пусто — отказ. По
# договору — полем status; мост, у которого status занят «success», отдаёт его полем decision (или result).
_subs_short_outcome() {
    local v
    v=$(printf '%s' "$1" | jq -r '[.status, .decision, .result] | map(select(type == "string"))
        | map(select(. == "ok" or . == "wrong" or . == "denied" or . == "swapped" or . == "expired" or . == "frozen"
                     or . == "pending" or . == "waiting")) | first // empty' 2>/dev/null) || v=""
    [ "$v" = waiting ] && v=pending
    printf '%s' "$v"
}

# Срок запроса в секундах epoch: ISO-время UTC или число (миллисекунды — делим); непонятное — 0.
_subs_short_epoch() {
    local v="${1:-}" e
    if [[ "$v" =~ ^[0-9]{9,10}$ ]]; then printf '%s' "$v"; return 0; fi
    if [[ "$v" =~ ^[0-9]{12,13}$ ]]; then printf '%s' "$((v / 1000))"; return 0; fi
    e=$(ga_iso_epoch "$v" 2>/dev/null) || e=0
    [[ "$e" =~ ^[0-9]+$ ]] || e=0
    printf '%s' "$e"
}

# Короткая ссылка пункта: short-ensure (код создаётся при первом показе) — код крупно, адрес; роутеру — та же команда, что
# у «показать, что вставлять», только с короткой ссылкой; пометка «2FA через Telegram-бота» и как набирать.
_subs_short_show() {
    local uname="$1" sfx="$2" app="$3" what="$4" full="$5" cmd="$6" kind="$7" js display surl
    js=$(_subs_short_call short-ensure --name="$uname" --suffix="$sfx")
    if [ "$(_json_field "$js" .status)" != success ]; then
        _subs_short_fail "$js"
        return 1
    fi
    display=$(_json_field "$js" .display)
    surl=$(_json_field "$js" .url)
    if [[ "$surl" != https://* ]] || ! [[ "$display" =~ ^[0-9A-Za-z-]{4,16}$ ]]; then
        log_error "$(t sb_short_bad)"
        return 1
    fi
    echo ""
    echo -e "  ${WHITE}$(tf sb_short_title "$app" "$what")${NC}"
    echo -e "    ${BOLD}${GREEN}${display}${NC}"
    printf '    %b%s%b\n' "$GREEN" "$surl" "$NC"
    if [ "$kind" = command ] && [ -n "$cmd" ] && [ -n "$full" ] && [[ "$cmd" == *"$full"* ]]; then
        echo -e "  ${DIM}$(t sb_short_cmd)${NC}"
        printf '    %b%s%b\n' "$GREEN" "${cmd//"$full"/$surl}" "$NC"
    fi
    echo ""
    echo -e "  $(ga_win_wrap "$(t sb_short_2fa)" 2)"
    echo -e "  ${DIM}$(ga_win_wrap "$(t sb_short_typing)" 2)${NC}"
    return 0
}

# «Заменить короткую ссылку»: запрос замены (who — ssh) — число на экран, затем опрос short-status раз в GA_SHORT_POLL с
# (2) до итога или срока; Enter — не ждать (запрос живёт в боте до своего срока), оборванный ввод — тоже не ждать.
_subs_short_swap() {
    local uname="$1" sfx="$2" js req num exp now st="" rc key left
    js=$(_subs_short_call short-replace-request --name="$uname" --suffix="$sfx" --who=ssh)
    req=$(_json_field "$js" .request)
    num=$(_json_field "$js" .number)
    if [ "$(_json_field "$js" .status)" != success ] || ! [[ "$req" =~ ^[A-Za-z0-9_-]{1,48}$ ]] || ! [[ "$num" =~ ^[1-9][0-9]$ ]]; then
        _subs_short_fail "$js"
        return 1
    fi
    exp=$(_subs_short_epoch "$(_json_field "$js" .expires)")
    [ "$exp" -gt 0 ] || exp=$(( $(date +%s) + 300 ))
    echo ""
    echo -e "  ${WHITE}$(t sb_swap_number)${NC}  ${BOLD}${CYAN}${num}${NC}"
    echo -e "  ${DIM}$(ga_win_wrap "$(t sb_swap_how)" 2)${NC}"
    while true; do
        now=$(date +%s)
        if [ "$now" -gt $((exp + 5)) ]; then st=expired; break; fi
        left=$(( exp > now ? exp - now : 0 ))
        echo -ne "\r  ${DIM}$(tf sb_swap_wait "$((left / 60))" "$(printf '%02d' $((left % 60)))")${NC}   "
        rc=0
        read -r -t "${GA_SHORT_POLL:-2}" key || rc=$?
        # Enter — не ждать; конец ввода (оборванная сессия) — тоже: крутить опрос некому
        if [ "$rc" -eq 0 ] || [ "$rc" -le 128 ]; then st=stopped; break; fi
        js=$(_subs_short_call short-status --request="$req")
        st=$(_subs_short_outcome "$js")
        [ -z "$st" ] || [ "$st" = pending ] || break
    done
    echo ""
    case "$st" in
        ok|swapped)
            log_success "$(t sb_swap_ok)"
            if [ "$(_json_field "$js" .url)" != "" ] && [[ "$(_json_field "$js" .display)" =~ ^[0-9A-Za-z-]{4,16}$ ]]; then
                echo -e "    ${BOLD}${GREEN}$(_json_field "$js" .display)${NC}"
                printf '    %b%s%b\n' "$GREEN" "$(_json_field "$js" .url)" "$NC"
            fi ;;
        wrong) log_error "$(t sb_swap_wrong)" ;;
        denied) log_error "$(t sb_swap_denied)" ;;
        frozen) log_error "$(t sb_swap_frozen)" ;;
        stopped) log_info "$(t sb_swap_stopped)" ;;
        *) log_warning "$(t sb_swap_expired)" ;;
    esac
    return 0
}

# Цель бана словами: «IP 203.0.113.7» или «код ••••9BKX» — код целиком на экран не идёт.
_subs_short_ban_target() {
    local kind="$1" target="$2" tail
    if [ "$kind" = code ]; then
        tail="${target//[^0-9A-Za-z]/}"
        tf sb_ban_code "••••${tail: -4}"
    else
        tf sb_ban_ip "$target"
    fi
}

# Баны адресов и заморозки кодов (short-bans): номер — снять (short-unban). Бан закрывает только короткие ссылки.
_subs_short_bans() {
    local js ch n kind target until reason level why label step
    local -a rows=()
    while true; do
        _screen_head "$(t sb_bans_title)" "$(t sb_bans_note)"
        js=$(_subs_short_call short-bans)
        if [ "$(_json_field "$js" .status)" != success ]; then
            _subs_short_fail "$js"
            return 1
        fi
        mapfile -t rows < <(printf '%s' "$js" | jq -r '.bans[]?
            | select(type == "object" and (.kind == "ip" or .kind == "code") and ((.target | type) == "string"))
            | select(.target | test("^[0-9A-Za-z.:/_-]{1,64}$"))
            | [.kind, .target, (.until // "" | tostring), (.reason // "" | tostring), (.level // "" | tostring)]
            | join("\u001f")' 2>/dev/null)
        if [ "${#rows[@]}" -eq 0 ]; then
            echo -e "  ${GREEN}$(t sb_bans_none)${NC}"
            return 0
        fi
        n=0
        for ch in "${rows[@]}"; do
            n=$((n + 1))
            IFS=$'\x1f' read -r kind target until reason level <<<"$ch"
            case "$reason" in
                misses|guess|bad_code) why=$(t sb_why_misses) ;;
                denied|deny|not_me) why=$(t sb_why_denied) ;;
                wrong|wrong_number|wrong_numbers) why=$(t sb_why_wrong) ;;
                *) why="$reason" ;;
            esac
            # Ступень лестницы словами (PNL-COS-03): первый раз — на сутки, повторно — на месяц
            if [[ "$level" =~ ^[1-9][0-9]?$ ]]; then
                case "$kind:$level" in
                    code:1) step=$(t sb_ban_step_code_1) ;;
                    code:*) step=$(t sb_ban_step_code_n) ;;
                    *:1)    step=$(t sb_ban_step_ip_1) ;;
                    *)      step=$(t sb_ban_step_ip_n) ;;
                esac
                why="${why:+$why · }$step"
            fi
            label=$(_subs_short_ban_target "$kind" "$target")
            echo -e "  ${CYAN}${n}${NC}) ${label}  ${DIM}$(tf sb_ban_until "$(ga_human_ts "$until")")${why:+ · $why}${NC}"
        done
        echo -e "  ${CYAN}0${NC}) $(t back)"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -ne "  ${WHITE}$(t sb_bans_pick):${NC} "
        read -r ch || ch=0
        case "$ch" in ""|0) GA_BACK=1; return 0 ;; esac
        if ! [[ "$ch" =~ ^[0-9]{1,3}$ ]] || [ "$((10#$ch))" -lt 1 ] || [ "$((10#$ch))" -gt "$n" ]; then
            log_error "$(t invalid_choice)"
            _pause
            continue
        fi
        IFS=$'\x1f' read -r kind target _ <<<"${rows[$((10#$ch - 1))]}"
        js=$(_subs_short_call short-unban --target="$target")
        if [ "$(_json_field "$js" .status)" = success ] || [ "$(_json_field "$js" .status)" = ok ]; then
            log_success "$(tf sb_unbanned "$(_subs_short_ban_target "$kind" "$target")")"
        else
            _subs_short_fail "$js"
        fi
        _pause
    done
}

# Создать подписку. Без домена с настоящим сертификатом ей негде жить — говорим это до любых вопросов, как у
# страницы (NC-09), и называем, чем отдать ключ без неё.
_subs_create() {
    local name="$1" js
    type subs_create >/dev/null 2>&1 || { log_error "$(tf module_missing subs_create)"; return 1; }
    if ! _pages_domain_ok; then
        log_warning "$(t sb_need_domain)"
        echo -e "  ${DIM}$(ga_win_wrap "$(t sb_need_domain_ways)" 2)${NC}"
        return 1
    fi
    GA_ERR_CODE=""
    if ! ga_capture js subs_create "$name"; then
        # Отказ модуль уже сказал своими словами; где «Привязать старый ключ» в SSH — говорим здесь (как у страниц).
        [ "${GA_ERR_CODE:-}" = no_private_key ] && log_dim "$(t pg_attach_where)"
        return 1
    fi
    _subs_show_urls "$js"
    return 0
}

# Перевыпуск: прежний адрес умирает сразу — роутеры и приложения придётся перенастроить. Подтверждение — именем.
_subs_rotate() {
    local name="$1" js
    type subs_rotate >/dev/null 2>&1 || { log_error "$(tf module_missing subs_rotate)"; return 1; }
    log_warning "$(t sb_rotate_warn)"
    confirm_phrase "$name" "$(tf sb_rotate_ask "$name")" || return 1
    ga_capture js subs_rotate "$name" || return 1
    _subs_show_urls "$js"
    return 0
}

# Отзыв: адрес умирает сразу, ключи VPN остаются. Подтверждение — именем.
_subs_revoke() {
    local name="$1"
    type subs_revoke >/dev/null 2>&1 || { log_error "$(tf module_missing subs_revoke)"; return 1; }
    log_warning "$(t sb_revoke_warn)"
    confirm_phrase "$name" "$(tf sb_revoke_ask "$name")" || return 1
    subs_revoke "$name" >/dev/null
}

# Экран подписки человека: состояние без адреса (есть ли, с какого числа, заборы, линии за ссылкой) и действия.
_subs_screen() {
    local name="$1" js row ready created rotated fetches last client lines keyless ch js2 pfetch plast pwhen pe
    type subs_list >/dev/null 2>&1 || { log_error "$(tf module_missing subs_list)"; return 1; }
    command -v jq >/dev/null 2>&1 || { log_error "$(t err_no_jq)"; return 1; }
    while true; do
        _screen_head "$(t user_sub_item)" "$(tf user_menu_for "$name")"
        ga_capture js subs_list "$name" || js=""
        if ! printf '%s' "$js" | jq -e . >/dev/null 2>&1; then
            log_error "${GA_ERR_MSG:-$(t sb_list_failed)}"; return 1
        fi
        row=$(printf '%s' "$js" | jq -c '.subs[0] // empty' 2>/dev/null)
        ready=$(_json_bool "$js" .domain_ready)
        echo -e "  ${DIM}$(ga_win_wrap "$(t sb_intro)" 2)${NC}"
        if [ -z "$row" ]; then
            echo -e "  $(t sb_state): ${YELLOW}$(t sb_state_none)${NC}"
            [ "$ready" = true ] || echo -e "  ${DIM}$(ga_win_wrap "$(t sb_need_domain)" 2)${NC}"
        else
            created=$(_json_field "$row" .created)
            rotated=$(_json_field "$row" .rotated)
            fetches=$(_json_field "$row" .fetches)
            last=$(_json_field "$row" .last_fetch)
            client=$(_json_field "$row" .last_client)
            echo -e "  $(t sb_state): ${GREEN}$(tf sb_state_since "$(ga_human_ts "$created")")${NC}"
            [ -n "$rotated" ] && echo -e "  $(t sb_rotated_label): ${CYAN}$(ga_human_ts "$rotated")${NC}"
            if [ "${fetches:-0}" != 0 ] && [ -n "$last" ]; then
                echo -e "  $(t sb_fetches_label): ${CYAN}${fetches}${NC}    $(t sb_last_label): ${CYAN}$(ga_human_ts "$last")${client:+ · $client}${NC}"
            else
                echo -e "  $(t sb_fetches_label): ${DIM}$(t sb_never_fetched)${NC}"
            fi
            # След прежнего адреса (Н-1): перевыпуск обнуляет счёт, а сколько раз забирали адрес до него — в строке.
            pfetch=$(_json_field "$row" .prev_fetches); plast=$(_json_field "$row" .prev_last_fetch)
            if [[ "$pfetch" =~ ^[0-9]+$ ]] && [ "$pfetch" -gt 0 ]; then
                # П-6-2: «N · когда», как в панели и боте; время — относительное, чтобы строка уложилась в ~70 знаков
                pwhen=""
                if [ -n "$plast" ]; then
                    if pe=$(ga_iso_epoch "$plast"); then pwhen=$(ga_rel_time "$pe"); else pwhen=$(ga_human_ts "$plast"); fi
                fi
                echo -e "  $(t sb_prev_fetches_label): ${CYAN}${pfetch}${NC}${pwhen:+ · ${CYAN}${pwhen}${NC}}"
            fi
            lines=$(printf '%s' "$row" | jq -r '[.lines[]? | select(.has_key) | "AmneziaWG \(.line) (\(.profile))"] | join(", ")' 2>/dev/null)
            keyless=$(printf '%s' "$row" | jq -r '[.lines[]? | select(.has_key | not) | .profile] | join(", ")' 2>/dev/null)
            echo -e "  $(t sb_lines_label): ${CYAN}${lines:--}${NC}"
            [ -n "$keyless" ] && log_warning "$(_ui_w "$(tf sb_keyless_note "$keyless")")"
            [ "$(_json_bool "$row" .disabled)" = true ] && log_warning "$(_ui_w "$(t sb_user_off)")"
            [ "$ready" = true ] || log_warning "$(_ui_w "$(t sb_paused)")"
        fi
        echo -e "  ${DIM}$(_rule)${NC}"
        if [ -z "$row" ]; then
            echo -e "  ${CYAN}1${NC}) $(t sb_item_create)"
        else
            echo -e "  ${CYAN}1${NC}) $(t sb_item_show)"
            echo -e "  ${CYAN}2${NC}) $(t sb_item_rotate)"
            echo -e "  ${CYAN}3${NC}) ${RED}$(t sb_item_revoke)${NC}"
            # Баны коротких ссылок со снятием — у ядра, которое их знает
            _action_known short-bans && echo -e "  ${CYAN}4${NC}) $(t sb_item_bans)"
        fi
        echo -e "  ${CYAN}0${NC}) $(t back)"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0
        case "$ch" in
            1)
                if [ -z "$row" ]; then
                    _subs_create "$name"
                elif type subs_show >/dev/null 2>&1; then
                    # Ответ с адресами — в переменную и дальше через stdin jq, не аргументом (SEC46-02).
                    ga_capture js2 subs_show "$name" && _subs_show_urls "$js2"
                else
                    log_error "$(tf module_missing subs_show)"
                fi
                _pause
                ;;
            2) if [ -n "$row" ]; then _subs_rotate "$name"; _pause; else log_error "$(t invalid_choice)"; _pause; fi ;;
            3) if [ -n "$row" ]; then _subs_revoke "$name"; _pause; else log_error "$(t invalid_choice)"; _pause; fi ;;
            4) if [ -n "$row" ] && _action_known short-bans; then _subs_short_bans || true; _pause
               else log_error "$(t invalid_choice)"; _pause; fi ;;
            0) GA_BACK=1; return 0 ;;
            "") continue ;;
            *) log_error "$(t invalid_choice)"; _pause ;;
        esac
    done
}

# ── Зеркало сборок приложений (lib/mirror.sh, docs/CLIENTS.md §8) ──────────────
_mirror_platform_name() {
    case "$1" in
        ios) t mr_platform_ios ;;
        android) t mr_platform_android ;;
        android_tv) t mr_platform_android_tv ;;
        windows) t mr_platform_windows ;;
        macos) t mr_platform_macos ;;
        linux) t mr_platform_linux ;;
        router) t mr_platform_router ;;
        *) printf '%s' "$1" ;;
    esac
}

# _mirror_state_name <state> <bytes> <size> <error> [message] → «готово», «загружается 25%»,
# «ошибка: <фраза ядра> (код)».
_mirror_state_name() {
    local st="$1" got="$2" total="$3" err="$4" msg="${5:-}" label
    case "$st" in
        ready) label=$(t mr_state_ready) ;;
        downloading) label=$(t mr_state_downloading) ;;
        queued) label=$(t mr_state_queued) ;;
        failed) label=$(t mr_state_failed) ;;
        *) label="$st" ;;
    esac
    if [ "$st" = downloading ] && [[ "$got" =~ ^[0-9]+$ ]] && [[ "$total" =~ ^[0-9]+$ ]] \
       && [ "$total" -gt 0 ] && [ "$got" -gt 0 ]; then
        label="$label $(( got * 100 / total ))%"
    fi
    if [ "$st" = failed ] && [ -n "$err" ]; then
        if [ -n "$msg" ]; then label="$label: $msg ($err)"; else label="$label ($err)"; fi
    fi
    printf '%s' "$label"
}

# Список копий: состояние, версия, размер, занято из предела; номер строки —
# удалить (с вопросом), N+1 — скачать новую.
_mirror_screen() {
    local js n ch i app platform st ver size got err msg used max n_fetch
    local -a apps=() plats=()
    type mirror_list >/dev/null 2>&1 || { log_error "$(tf module_missing mirror_list)"; return 1; }
    command -v jq >/dev/null 2>&1 || { log_error "$(t err_no_jq)"; return 1; }
    while true; do
        _screen_head "$(t se_mirror)" "$(t mr_intro)"
        ga_capture js mirror_list || js=""
        if ! printf '%s' "$js" | jq -e . >/dev/null 2>&1; then
            log_error "${GA_ERR_MSG:-$(t mr_list_failed)}"; return 1
        fi
        n=$(printf '%s' "$js" | jq -r '.items | length')
        apps=(); plats=()
        if [ "${n:-0}" = 0 ]; then
            echo -e "  ${DIM}$(t mr_list_empty)${NC}"
        else
            echo -e "  ${DIM}$(t mr_list_cols)${NC}"
            i=0
            while IFS=$'\x1f' read -r app platform st ver size got err msg; do
                [ -n "$app" ] || continue
                i=$((i + 1)); apps+=("$app"); plats+=("$platform")
                echo -e "  ${CYAN}$(_pad "$i" 2)${NC} $(tf mr_list_row "$app" "$(_mirror_platform_name "$platform")" "$(_mirror_state_name "$st" "$got" "$size" "$err" "$msg")" "${ver:--}" "$(_human_bytes "$size")")"
            done < <(printf '%s' "$js" | jq -r '.items[]? | [.app, .platform, (.state // ""), (.version // ""),
                ((.size // 0) | tostring), ((.bytes // 0) | tostring), (.error // ""), (.message // "")] | join("\u001f")')
        fi
        used=$(_json_field "$js" .used_mb); max=$(_json_field "$js" .max_total_mb)
        echo -e "  ${DIM}$(tf mr_usage "${used:-0}" "${max:-0}")${NC}"
        echo -e "  ${DIM}$(_rule)${NC}"
        n_fetch=$(( ${#apps[@]} + 1 ))
        echo -e "  ${CYAN}${n_fetch}${NC}) $(t mr_item_fetch)"
        echo -e "  ${CYAN}0${NC}) $(t back)"
        [ "${#apps[@]}" -gt 0 ] && echo -e "  ${DIM}$(ga_win_wrap "$(tf mr_pick_legend "$n_fetch")" 2)${NC}"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0
        case "$ch" in
            "$n_fetch") _mirror_fetch_pick; _pause ;;
            0) GA_BACK=1; return 0 ;;
            "") continue ;;
            *)
                # Не длиннее четырёх цифр и десятично (SR-53: число длиннее int64 роняло меню).
                if ! [[ "$ch" =~ ^[0-9]{1,4}$ ]] || [ "$((10#$ch))" -lt 1 ] || [ "$((10#$ch))" -gt "${#apps[@]}" ]; then
                    log_error "$(t invalid_choice)"; _pause; continue
                fi
                app="${apps[$((10#$ch - 1))]}"; platform="${plats[$((10#$ch - 1))]}"
                type mirror_remove >/dev/null 2>&1 || { log_error "$(tf module_missing mirror_remove)"; _pause; continue; }
                # Копию уже могли раздать со страниц — кнопка «скачать с нашего
                # сервера» у людей пропадёт, поэтому спрашиваем.
                confirm "$(tf mr_remove_ask "$app" "$(_mirror_platform_name "$platform")")" \
                    || { log_info "$(t cancelled)"; _pause; continue; }
                mirror_remove "$app" "$platform" >/dev/null
                _pause
                ;;
        esac
    done
}

# Скачать сборку: приложение из каталога (только зеркалируемые) → платформа из
# его mirror.assets → mirror_fetch (загрузка идёт в фоне).
_mirror_fetch_pick() {
    local js app platform ch i p
    local -a ids=() names=() pl=()
    type clients_list >/dev/null 2>&1 || { log_error "$(tf module_missing clients_list)"; return 1; }
    type mirror_fetch >/dev/null 2>&1 || { log_error "$(tf module_missing mirror_fetch)"; return 1; }
    ga_capture js clients_list || return 1
    echo ""
    echo -e "  ${BOLD}${WHITE}$(t mr_item_fetch)${NC}"
    echo -e "  ${DIM}$(ga_win_wrap "$(t mr_pick_app)" 2)${NC}"
    echo -e "  ${DIM}$(_rule)${NC}"
    i=0
    while IFS=$'\x1f' read -r app platform p; do
        [ -n "$app" ] || continue
        i=$((i + 1)); ids+=("$app"); names+=("$platform")
        if [ "$p" = true ]; then
            echo -e "  ${CYAN}${i}${NC}) $platform"
        else
            echo -e "  ${CYAN}${i}${NC}) $platform ($(t mr_unofficial))"
        fi
    done < <(printf '%s' "$js" | jq -r '.apps[]? | select(((.mirror // {}).assets // {}) | length > 0)
        | [.id, (.name // .id), ((.official // false) | tostring)] | join("\u001f")')
    if [ "${#ids[@]}" = 0 ]; then log_info "$(t mr_no_apps)"; return 1; fi
    echo -e "  ${CYAN}0${NC}) $(t back)"
    echo -ne "  ${WHITE}$(t choose):${NC} "
    read -r ch || ch=0
    case "$ch" in ""|0) GA_BACK=1; return 1 ;; esac
    if ! [[ "$ch" =~ ^[0-9]{1,3}$ ]] || [ $((10#$ch)) -lt 1 ] || [ $((10#$ch)) -gt "${#ids[@]}" ]; then
        log_error "$(t invalid_choice)"; return 1
    fi
    app="${ids[$((10#$ch - 1))]}"
    while IFS= read -r p; do
        [ -n "$p" ] && pl+=("$p")
    done < <(printf '%s' "$js" | jq -r --arg a "$app" '.apps[]? | select(.id == $a) | ((.mirror // {}).assets // {}) | keys[]')
    [ "${#pl[@]}" -gt 0 ] || { log_info "$(t mr_no_apps)"; return 1; }
    echo ""
    echo -e "  ${WHITE}$(tf mr_pick_platform "${names[$((10#$ch - 1))]}")${NC}"
    i=0
    for p in "${pl[@]}"; do
        i=$((i + 1))
        echo -e "  ${CYAN}${i}${NC}) $(_mirror_platform_name "$p")"
    done
    echo -e "  ${CYAN}0${NC}) $(t back)"
    echo -ne "  ${WHITE}$(t choose):${NC} "
    read -r ch || ch=0
    case "$ch" in ""|0) GA_BACK=1; return 1 ;; esac
    if ! [[ "$ch" =~ ^[0-9]{1,3}$ ]] || [ $((10#$ch)) -lt 1 ] || [ $((10#$ch)) -gt "${#pl[@]}" ]; then
        log_error "$(t invalid_choice)"; return 1
    fi
    platform="${pl[$((10#$ch - 1))]}"
    mirror_fetch "$app" "$platform" >/dev/null || return 1
    log_dim "$(t mr_queued_hint)"
    return 0
}

_user_keys_menu() {
    local name="$1" ch imported offer kaddr key_ep="" extra=() n i
    while true; do
        # Через общий заголовок экрана: заголовок равен подписи пункта, и вокруг
        # него те же линейки, что у всех остальных экранов продукта. Раньше эти
        # два подменю печатались «своим» заголовком «Ключи: имя», неотличимым от
        # строки данных, и без разделителей.
        _screen_head "$(t user_keys_menu)" "$(tf user_menu_for "$name")"
        imported=$(_user_imported_profiles "$name" | tr '\n' ' '); imported="${imported% }"
        [ -n "$imported" ] && log_warning "$(_ui_w "$(tf user_imported_note "$(_pr_names_list "$imported")")")"
        # Адрес сервера в ключе — здесь, рядом с выдачей: сменив его, человек тут же выдаёт ключ заново.
        offer=""
        _user_address_offer "$name" && offer=1
        # Ключ на другой адрес сервера (docs/EDGEIPS.md §3.4): разово, пока открыт этот экран, — пункты 1–5
        # выдают тот же ключ с выбранным адресом внутри; за пользователем ничего не сохраняется.
        kaddr=""
        _key_addr_offer "$name" && kaddr=1
        [ -n "$offer" ] && echo -e "  ${DIM}$(ga_win_wrap "$(_user_address_line "$name")" 2)${NC}"
        [ -n "$key_ep" ] && echo -e "  ${YELLOW}$(ga_win_wrap "$(tf user_key_addr_active "$key_ep")" 2)${NC}"
        # Все ключи человека выданы в приложении Amnezia (KEY-APP-02): QR, текст, vpn://, серия QR и ссылка вели
        # в одну и ту же ошибку «ключ выдан в приложении». Здесь — только то, что сработает: привязать старый ключ
        # и перевыпустить ключ на профиле; строкой выше — почему остального нет.
        if [ -n "$imported" ] && ! _user_has_private_key "$name"; then
            echo -e "  ${DIM}$(ga_win_wrap "$(t user_keys_app_only_menu)" 2)${NC}"
            echo -e "  ${CYAN}1${NC}) $(t user_attach_item)"
            echo -e "  ${CYAN}2${NC}) $(t user_peer_reissue_item)"
            echo -e "  ${CYAN}0${NC}) $(t back)"
            echo -ne "  ${WHITE}$(t choose):${NC} "
            read -r ch || ch=0
            case "$ch" in
                1) _user_attach_key "$name" ;;
                2) _user_peer_reissue "$name" ;;
                0) GA_BACK=1; return 0 ;;
                "") continue ;;
                *) log_error "$(t invalid_choice)" ;;
            esac
            _pause
            continue
        fi
        echo -e "  ${CYAN}1${NC}) $(t user_key_qr_conf)"
        echo -e "  ${CYAN}2${NC}) $(t user_key_text_conf)"
        echo -e "  ${CYAN}3${NC}) $(t user_key_vpn_link)"
        echo -e "  ${CYAN}4${NC}) $(t user_key_qr_vpn)"
        echo -e "  ${CYAN}5${NC}) $(t share_menu_item)"
        # Хвост меню — по порядку, без дыр в номерах: пункты появляются только когда есть что выбирать.
        extra=()
        [ -n "$imported" ] && extra+=(attach)
        [ -n "$kaddr" ] && extra+=(keyaddr)
        [ -n "$offer" ] && extra+=(pin)
        n=6
        for i in "${extra[@]+"${extra[@]}"}"; do
            case "$i" in
                attach)  echo -e "  ${CYAN}${n}${NC}) $(t user_attach_item)" ;;
                keyaddr) echo -e "  ${CYAN}${n}${NC}) $(t user_key_addr_item)" ;;
                pin)     echo -e "  ${CYAN}${n}${NC}) $(t user_address_item)" ;;
            esac
            n=$((n + 1))
        done
        echo -e "  ${CYAN}0${NC}) $(t back)"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0
        case "$ch" in
            # QR-пункты — с теми же путями, что у первого ключа (NC-27): не влез — показать снова, панель, ссылка;
            # раньше у «Серии QR» после «не помещается» был только Enter. Enter там же — назад, без второй паузы.
            1) if _user_key "$name" qr-conf "$key_ep"; then
                   _key_next_steps "$name" "${GA_LAST_KEY_PROFILE:-}" "${GA_LAST_QR_OK:-0}" "" conf "$key_ep"
                   GA_BACK=1
               fi ;;
            2) _user_key "$name" conf "$key_ep" ;;
            3) _user_key "$name" vpn "$key_ep" ;;
            4) if _user_key "$name" qr-vpn "$key_ep"; then
                   _key_next_steps "$name" "${GA_LAST_KEY_PROFILE:-}" "${GA_LAST_QR_OK:-0}" "" vpn "$key_ep"
                   GA_BACK=1
               fi ;;
            5) _user_share "$name" "$key_ep" ;;
            0) GA_BACK=1; return 0 ;;
            "") continue ;;
            *)
                i=""
                if [[ "$ch" =~ ^[0-9]{1,4}$ ]] && [ "$((10#$ch))" -ge 6 ] && [ "$((10#$ch - 6))" -lt "${#extra[@]}" ]; then
                    i="${extra[$((10#$ch - 6))]}"
                fi
                case "$i" in
                    attach) _user_attach_key "$name" ;;
                    keyaddr)
                        # Выбор адреса — настройка экрана, а не действие: без «Нажмите Enter».
                        _pick_key_address "$name" key_ep
                        continue ;;
                    pin) _user_address_screen "$name" ;;
                    *) log_error "$(t invalid_choice)" ;;
                esac
                ;;
        esac
        _pause
    done
}

# Предлагать ли «Ключ на другой адрес»: у человека есть приватный ключ хоть в одном профиле (у подхваченных
# из приложения его нет) и у сервера есть адрес, отличный от того, что сейчас в ключах человека.
_key_addr_offer() {
    local name="${1:-}" cur hosts
    type ga_export_key_hosts >/dev/null 2>&1 || return 1
    [ -n "$(_user_profiles "$name" 2>/dev/null)" ] || return 1
    _user_has_private_key "$name" || return 1
    cur=$(ga_export_endpoint_host "$name" 2>/dev/null) || cur=""
    hosts=$(ga_export_key_hosts 2>/dev/null)
    [ -n "$(grep -vxF -- "${cur:-<none>}" <<<"$hosts" | grep .)" ]
}

# Есть ли у человека приватный ключ хоть в одном профиле (импортированные пиры его не имеют).
_user_has_private_key() {
    local name="${1:-}"
    type ga_users_get >/dev/null 2>&1 || return 0
    [ "$(ga_users_get "$name" 2>/dev/null | jq -r '[.peers[]? | select((.privkey // "") != "")] | length' 2>/dev/null)" != 0 ]
}

# _pick_key_address <имя> <переменная> — выбор адреса сервера для разовой выдачи: «как обычно» первой
# строкой, затем домены и адреса машины с вердиктом сторожа и A-записью (как в таблице «Адреса сервера»).
# Выбор кладётся в переменную вызывающего (пусто — как обычно). 0 и пустой ввод — назад без выбора.
_pick_key_address() {
    local name="$1" __var="$2" edge choices cur n i host kind def verdict dns mark ch
    local -a hosts=()
    edge=$(ga_edge_status_json 2>/dev/null) || edge='{}'
    choices=$(export_key_choices_json "$edge" 2>/dev/null) || choices='[]'
    cur=$(ga_export_endpoint_host "$name" 2>/dev/null) || cur=""
    _screen_head "$(tf user_key_addr_title "$name")" ""
    echo -e "  ${DIM}$(ga_win_wrap "$(t user_key_addr_note)" 2)${NC}"
    echo -e "  ${DIM}$(_rule)${NC}"
    echo -e "  ${CYAN}1${NC}) $(tf user_key_addr_usual "${cur:-—}")"
    hosts+=("")
    n=2
    while IFS=$'\t' read -r host kind def verdict dns; do
        [ -n "$host" ] || continue
        [ "$host" = "$cur" ] && continue
        mark=""
        [ "$kind" = domain ] && mark=" · $(t user_key_addr_domain_mark)"
        case "$verdict" in
            ok)        mark+=" · ${GREEN}$(t edge_v_ok)${NC}" ;;
            dark)      mark+=" · ${YELLOW}$(t edge_v_dark)${NC}" ;;
            quiet-all) mark+=" · ${DIM}$(t edge_v_quiet_all)${NC}" ;;
            # «Ключи не смотрят» у запасного адреса читалось как «годен», а входящих на нём может не быть вовсе.
            unused)    mark+=" · ${YELLOW}$(t user_key_addr_unverified)${NC}" ;;
            quiet)     mark+=" · ${DIM}$(t edge_v_quiet)${NC}" ;;
        esac
        [ "$dns" = false ] && mark+=" · ${DIM}$(t user_key_addr_spare_mark)${NC}"
        echo -e "  ${CYAN}${n}${NC}) ${host}${mark}"
        hosts+=("$host")
        n=$((n + 1))
    done < <(jq -r '.[] | [.host, .kind, (.default|tostring), (.verdict // ""), (.in_dns|tostring)] | @tsv' <<<"$choices" 2>/dev/null)
    echo -e "  ${CYAN}0${NC}) $(t back)"
    echo -ne "  ${WHITE}$(t choose):${NC} "
    read -r ch || ch=0
    if [ -z "$ch" ] || [ "$ch" = 0 ]; then
        GA_BACK=1
        return 1
    fi
    if ! [[ "$ch" =~ ^[0-9]{1,4}$ ]] || [ "$((10#$ch))" -lt 1 ] || [ "$((10#$ch))" -gt "${#hosts[@]}" ]; then
        log_error "$(t invalid_choice)"
        return 1
    fi
    host="${hosts[$((10#$ch - 1))]}"
    printf -v "$__var" '%s' "$host"
    if [ -n "$host" ] && [ "$(jq -r --arg h "$host" '.[] | select(.host == $h) | .verdict // ""' <<<"$choices" 2>/dev/null)" = dark ]; then
        log_warning "$(tf user_key_addr_dark_warn "$host")"
    fi
    return 0
}

# Набор профилей одним пунктом: выдать, отобрать, перевыпустить — три соседние
# строки карточки, которые нужны редко, а места занимали как ключи.
_user_profiles_menu() {
    local name="$1" ch imported
    while true; do
        _screen_head "$(t user_profiles_menu)" "$(tf user_menu_for "$name")"
        echo -e "  ${DIM}$(t user_profiles_label): $(_pr_names_list "$(_user_profiles "$name" | tr '\n' ' ')")${NC}"
        echo -e "  ${CYAN}1${NC}) $(t user_add_profile_item)"
        echo -e "  ${CYAN}2${NC}) $(t user_del_profile_item)"
        echo -e "  ${CYAN}3${NC}) $(t user_peer_reissue_item)"
        imported=$(_user_imported_profiles "$name")
        [ -n "$imported" ] && echo -e "  ${CYAN}4${NC}) $(t user_attach_item)"
        echo -e "  ${CYAN}0${NC}) $(t back)"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0
        case "$ch" in
            1) _user_peer_add "$name" ;;
            2) _user_peer_del "$name" ;;
            3) _user_peer_reissue "$name" ;;
            4) if [ -n "$imported" ]; then _user_attach_key "$name"; else log_error "$(t invalid_choice)"; fi ;;
            0) GA_BACK=1; return 0 ;;
            "") continue ;;
            *) log_error "$(t invalid_choice)" ;;
        esac
        _pause
    done
}

_user_peer_add() {
    local name="$1" have p ch i
    local -a free=()
    type users_add_peer >/dev/null 2>&1 || { log_error "$(tf module_missing users_add_peer)"; return 1; }
    # Пробел в конце обязателен: у последнего профиля иначе нет пробела справа, и `*" $p "*` его не
    # находил — меню предлагало профиль, ключ на который уже есть (находка LC-11).
    have=" $(_user_profiles "$name" | tr '\n' ' ') "
    for p in $PROFILE_IDS; do
        _profile_installed "$p" || continue
        [[ "$have" == *" $p "* ]] && continue
        free+=("$p")
    done
    if [ "${#free[@]}" -eq 0 ]; then
        log_info "$(t user_peer_add_none)"; return 0
    fi
    echo ""
    echo -e "  ${BOLD}${WHITE}$(tf user_peer_add_title "$name")${NC}"
    for i in "${!free[@]}"; do
        echo -e "  ${CYAN}$((i + 1))${NC}) $(_pr_name "${free[$i]}")"
    done
    echo -e "  ${CYAN}0${NC}) $(t back)"
    ch=$(ga_ask "$(t choose)" '^[0-9]+$' "$(t invalid_choice)") || return 0
    [ "$((10#$ch))" = 0 ] && { GA_BACK=1; return 0; }
    [ "$ch" -ge 1 ] && [ "$ch" -le "${#free[@]}" ] || return 0
    p="${free[$((10#$ch - 1))]}"
    GA_ERR_MSG=""
    if users_add_peer "$name" "$p" >/dev/null; then
        log_success "$(tf user_peer_added "$name" "$(_pr_name "$p")")"
    else
        _err_once "$(tf user_peer_add_failed "$name" "$(_pr_name "$p")")"
    fi
}

# Отобрать ключ на профиль. Ключ перестаёт работать сразу — это разрушительное
# действие, поэтому предупреждение и подтверждение, а не «y» вслепую.
# _user_reissue_facts <имя> <профиль> → «<страниц> <подписка 1|0> <часов> <update_slow JSON>»: что пользователю делать
# после перевыпуска ключа — по фактам, как в панели и боте (Н-4): живые страницы с этим профилем и подписка, которая
# отдаёт его ключ. Модуля нет или он не ответил — «?» вместо числа: текст скажет условно. Последнее поле —
# ga_subs_update_slow (A4-3/B4-4): приложения, которые забирают подписку реже совета сервера; в нём бывают пробелы,
# поэтому оно последнее.
_user_reissue_facts() {
    local name="$1" p="$2" js pages="?" sub="?" hours=12 slow='[]'
    if type pages_list >/dev/null 2>&1 && ga_capture js pages_list "$name" 2>/dev/null; then
        pages=$(printf '%s' "$js" | jq -r --arg u "$name" --arg p "$p" \
            '[(.pages // [])[] | select(.user == $u and ((.profiles // []) | index([$p])))] | length' 2>/dev/null) || pages="?"
        [[ "$pages" =~ ^[0-9]+$ ]] || pages="?"
    fi
    if type ga_subs_lines_json >/dev/null 2>&1 && type ga_subs_exists >/dev/null 2>&1; then
        hours=$(ga_subs_update_hours 2>/dev/null); [[ "$hours" =~ ^[0-9]+$ ]] || hours=12
        if type ga_subs_update_slow >/dev/null 2>&1; then slow=$(ga_subs_update_slow "$hours" 2>/dev/null) || slow='[]'; fi
        [ -n "$slow" ] || slow='[]'
        sub=0
        if ga_subs_exists "$name" && ! _ga_subs_owner_gone "$(ga_subs_dir)/$name" &&
            [ "$(ga_users_get "$name" 2>/dev/null | jq -r '.enabled != false' 2>/dev/null)" = true ] &&
            ga_subs_lines_json "$name" | jq -e --arg p "$p" 'any(.[]; .profile == $p and .has_key != false)' >/dev/null 2>&1; then
            sub=1
        fi
    fi
    printf '%s %s %s %s' "$pages" "$sub" "$hours" "$slow"
}
# _user_sub_within <часов> [update_slow JSON] — слова панели (subWithin): «до 12 ч» или «до 12 ч, у FlClash — до 24 ч»;
# приложения с одним сроком — через запятую, сначала самые долгие; не дольше совета сервера — не называются.
_user_sub_within() {
    local h="$1" slow="${2:-[]}" rest="" hh names
    while IFS=$'\t' read -r hh names; do
        [ -n "$hh" ] && [ -n "$names" ] || continue
        rest="${rest:+$rest, }$(tf ur_within_app "$names" "$hh")"
    done < <(printf '%s' "$slow" | jq -r --argjson h "$h" '[.[]? | select(type == "object" and (.name | type) == "string"
        and .name != "" and (.hours | type) == "number" and .hours > $h)] | group_by(.hours) | sort_by(-.[0].hours)
        | .[] | "\(.[0].hours)\t\(map(.name) | join(", "))"' 2>/dev/null)
    if [ -z "$rest" ]; then tf ur_within "$h"; else tf ur_within_slow "$h" "$rest"; fi
}
# _user_reissue_facts_text <факты> [done] — слова панели (reissueFactsText).
_user_reissue_facts_text() {
    local pages sub hours slow d="" out=""
    read -r pages sub hours slow <<<"$1"
    [ "${2:-}" = "done" ] && d=_done
    if [ "$pages" = "?" ] || [ "$sub" = "?" ]; then
        printf '%s %s' "$(t "ur_facts${d}_manual")" "$(tf ur_facts_unknown "$(_user_sub_within "$hours" "$slow")")"
        return 0
    fi
    if [ "$pages" = 0 ] && [ "$sub" = 0 ]; then
        t "ur_facts${d}_only_manual"
        return 0
    fi
    [ "$pages" != 0 ] && out="$(t "ur_facts${d}_pages")"
    [ "$sub" = 1 ] && out="${out:+$out }$(tf "ur_facts${d}_sub" "$(_user_sub_within "$hours" "$slow")")"
    printf '%s %s' "$out" "$(t "ur_facts${d}_manual")"
}

# Перевыпуск ключа на профиле. Совет «перевыпустите ключ» звучал в ошибке
# выдачи, но такого пункта в меню не было вовсе: сделать это можно было только
# двумя шагами — «Отобрать ключ на профиль», потом «Выдать ключ ещё на один
# профиль», — и догадаться об этом по тексту ошибки человек не мог.
_user_peer_reissue() {
    local name="$1" list p ch i
    local -a arr=()
    type users_reissue_peer >/dev/null 2>&1 \
        || { log_error "$(tf module_missing users_reissue_peer)"; return 1; }
    list=$(_user_profiles "$name")
    [ -n "$list" ] || { log_info "$(t user_no_peers)"; return 0; }
    mapfile -t arr <<< "$list"
    echo ""
    echo -e "  ${BOLD}${WHITE}$(tf user_peer_reissue_title "$name")${NC}"
    for i in "${!arr[@]}"; do
        echo -e "  ${CYAN}$((i + 1))${NC}) $(_pr_name "${arr[$i]}")"
    done
    echo -e "  ${CYAN}0${NC}) $(t back)"
    ch=$(ga_ask "$(t choose)" '^[0-9]+$' "$(t invalid_choice)") || return 0
    [ "$((10#$ch))" = 0 ] && { GA_BACK=1; return 0; }
    [ "$ch" -ge 1 ] && [ "$ch" -le "${#arr[@]}" ] || return 0
    p="${arr[$((10#$ch - 1))]}"
    log_warning "$(_ui_w "$(tf user_peer_reissue_warn "$name" "$(_pr_name "$p")")")"
    local facts
    facts=$(_user_reissue_facts "$name" "$p")
    echo -e "  ${DIM}$(ga_win_wrap "$(_user_reissue_facts_text "$facts")" 2)${NC}"
    # Ключ из приложения: у человека он работает, и перевыпуск его отключит.
    # Если ссылка или файл целы — привязка обходится без этого.
    if grep -qxF "$p" <<<"$(_user_imported_profiles "$name")"; then
        log_warning "$(_ui_w "$(t user_peer_reissue_imported_warn)")"
    fi
    confirm "$(tf user_peer_reissue_ask "$name" "$(_pr_name "$p")")" || { log_info "$(t cancelled)"; return 1; }
    # Одно действие модуля, а не пара «снять и выдать»: подмена идёт под общим
    # замком, и при сорвавшемся применении возвращается прежний ключ — человек
    # остаётся с тем, с которым пришёл, вместо пустого профиля.
    if users_reissue_peer "$name" "$p" >/dev/null; then
        log_success "$(_ui_w "$(tf user_peer_reissued "$name" "$(_pr_name "$p")")")"
        echo -e "  ${DIM}$(ga_win_wrap "$(_user_reissue_facts_text "$facts" "done")" 2)${NC}"
    else
        log_error "$(_ui_w "${GA_ERR_MSG:-$(tf user_peer_reissue_failed "$(_pr_name "$p")" "$(t user_add_profile_item)")}")"
        return 1
    fi
}

# Привязка старого ключа человека, подхваченного из приложения Amnezia: админ
# вставляет ссылку vpn:// или текст .conf, которые когда-то ему отправил (или
# путь к файлу на сервере). Модуль сам находит профиль по ключу и проверяет, что
# ключ именно этого человека; у человека ничего не меняется. Ввод без эха:
# на экране и в истории терминала приватному ключу делать нечего. Вставка
# .conf приходит пачкой строк, в том числе пустых между [Interface] и [Peer],
# поэтому конец ввода — пауза, а не пустая строка.
_user_attach_key() {
    local name="$1" first nl material="" n=0
    type users_attach_key >/dev/null 2>&1 || { log_error "$(tf module_missing users_attach_key)"; return 1; }
    if [ -z "$(_user_imported_profiles "$name")" ]; then
        log_info "$(tf user_attach_none "$name")"; return 0
    fi
    echo ""
    echo -e "  ${BOLD}${WHITE}$(tf user_attach_title "$name")${NC}"
    echo -e "  ${DIM}$(ga_win_wrap "$(t user_attach_hint)" 2)${NC}"
    echo -ne "  ${WHITE}> ${NC}"
    # Вставку читает общий помощник (lib/common.sh): строка без предела терминала — длинная ссылка vpn:// с
    # I1–I5 больше не режется на 4095 байтах (находки TK-3, TAIL-1); строки .conf, идущие следом, дочитываются,
    # пока идут; пустые строки начала вставки пропускаются (текст из чата с переводом строки впереди: пустая
    # первая строка раньше значила «назад», а остаток вставки уходил в меню ключей — находка TK-2); конец ввода
    # и Ctrl-D — отмена.
    ga_read_paste material -s || material=""
    echo ""
    first="${material%%$'\n'*}"
    case "$first" in
        ""|0) material=""; log_info "$(t cancelled)"; return 0 ;;
        /*|~/*)
            material=""
            first="${first/#\~/$HOME}"
            if [ ! -f "$first" ]; then log_error "$(tf user_attach_file_missing "$first")"; return 1; fi
            material=$(head -c 65536 "$first" 2>/dev/null) || material="" ;;
    esac
    # Строк — по переводам строки, без внешних команд: ключ не уходит ни в чей stdin.
    nl="${material//[!$'\n']/}"
    n=$(( ${#nl} + 1 ))
    log_dim "$(tf user_attach_got "$n")"
    GA_ERR_CODE=""
    if ! users_attach_key "$name" "" "$material" >/dev/null; then
        material=""
        # Отказ «не удалось прочитать ключ» раньше не говорил, что делать: человек вставлял ссылку снова и
        # снова (находка TK-3). Терминал ссылку больше не режет, но скопировать её могли не целиком —
        # подсказываем путь через файл.
        [ "${GA_ERR_CODE:-}" = config_unreadable ] && log_info "$(_ui_w "$(t user_attach_file_route)")"
        return 1
    fi
    material=""
    log_info "$(_ui_w "$(t user_attach_next)")"
}

_user_peer_del() {
    local name="$1" list p ch i
    local -a arr=()
    type users_del_peer >/dev/null 2>&1 || { log_error "$(tf module_missing users_del_peer)"; return 1; }
    list=$(_user_profiles "$name")
    [ -n "$list" ] || { log_info "$(t user_no_peers)"; return 0; }
    mapfile -t arr <<< "$list"
    echo ""
    echo -e "  ${BOLD}${WHITE}$(tf user_peer_del_title "$name")${NC}"
    for i in "${!arr[@]}"; do
        echo -e "  ${CYAN}$((i + 1))${NC}) $(_pr_name "${arr[$i]}")"
    done
    echo -e "  ${CYAN}0${NC}) $(t back)"
    ch=$(ga_ask "$(t choose)" '^[0-9]+$' "$(t invalid_choice)") || return 0
    [ "$((10#$ch))" = 0 ] && { GA_BACK=1; return 0; }
    [ "$ch" -ge 1 ] && [ "$ch" -le "${#arr[@]}" ] || return 0
    p="${arr[$((10#$ch - 1))]}"
    log_warning "$(tf user_peer_del_warn "$name" "$(_pr_name "$p")")"
    confirm "$(tf user_peer_del_ask "$name" "$(_pr_name "$p")")" || { log_info "$(t cancelled)"; return 1; }
    GA_ERR_MSG=""
    if users_del_peer "$name" "$p" >/dev/null; then
        log_success "$(tf user_peer_deleted "$name" "$(_pr_name "$p")")"
    else
        _err_once "$(tf user_peer_del_failed "$name" "$(_pr_name "$p")")"
    fi
}

# Выбор профиля пользователя. Печатает ТОЛЬКО id профиля (вызов через $()).
#
# Это единственный вопрос во всей цепочке выдачи ключа, и он был сделан на
# голом read: ни «0) Назад», ни переспроса, а на любой промах — «У пользователя
# нет ни одного профиля», хотя экран только что показал два. Соседние пункты
# той же карточки (_user_peer_add, _user_peer_del) спрашивают правильно, через
# ga_ask с тремя попытками и человеческими именами линеек, — здесь то же самое.
#
# Коды возврата разные, и вызывающий обязан их различать:
#   0 — выбран профиль (в stdout);
#   1 — профилей у человека нет вовсе (тогда и только тогда user_no_peers);
#   2 — человек отказался («0», три промаха, оборванный ввод).
#   3 — (keyed) профили есть, но ключи на всех выданы в приложении Amnezia: здесь их не показать (KEY-APP-02).
# Второй аргумент keyed — выбор для выдачи ключа (QR, текст, vpn://, ссылка): профили, где ключ только в приложении
# Amnezia, в список не идут — каждый вёл в одну и ту же ошибку «ключ выдан в приложении» (KEY-APP-02); под списком —
# строка, какие убраны и что с ними делать.
_pick_user_profile() {
    local name="$1" mode="${2:-}" list arr i ch p skipped=""
    list=$(_user_profiles "$name")
    [ -n "$list" ] || return 1
    if [ "$mode" = keyed ]; then
        local imp keep=""
        imp=" $(_user_imported_profiles "$name" | tr '\n' ' ') "
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            case "$imp" in *" $p "*) skipped="${skipped:+$skipped }$p" ;; *) keep="${keep:+$keep$'\n'}$p" ;; esac
        done <<<"$list"
        [ -n "$keep" ] || return 3
        list="$keep"
    fi
    mapfile -t arr <<< "$list"
    if [ "${#arr[@]}" -eq 1 ]; then
        [ -n "$skipped" ] && echo -e "  ${DIM}$(ga_win_wrap "$(tf user_pick_app_skipped "$(_pr_names_list "$skipped")")" 2)${NC}" >&2
        printf '%s' "${arr[0]}"
        return 0
    fi
    echo "" >&2
    echo -e "  ${BOLD}${WHITE}$(tf user_pick_profile_title "$name")${NC}" >&2
    for i in "${!arr[@]}"; do
        # Имя линейки, а не голый id: «AmneziaWG 2.0» человек узнаёт, «awg2» —
        # нет, а выбирает он ровно то, что раздаёт клиентам. Идентификатор в
        # строке словаря уже есть — второй раз его не печатаем.
        echo -e "  ${CYAN}$((i + 1))${NC}) $(_pr_name "${arr[$i]}")" >&2
    done
    echo -e "  ${CYAN}0${NC}) $(t back)" >&2
    [ -n "$skipped" ] && echo -e "  ${DIM}$(ga_win_wrap "$(tf user_pick_app_skipped "$(_pr_names_list "$skipped")")" 2)${NC}" >&2
    # Совет, когда есть из чего выбирать: 3.1 и что-то старше. Без него «2.0 или 3.1?» было гаданием (NC-07). Линия — по
    # профилю, а не по месту: 3.1 бывает и в awg2 (подхват из приложения Amnezia, AWG31-01).
    local has31=0
    for i in "${!arr[@]}"; do [ "$(_profile_line "${arr[$i]}" 2>/dev/null)" = 3.1 ] && has31=1; done
    if [ "$has31" = 1 ] && [ "${#arr[@]}" -gt 1 ]; then
        # «Не подключится — возьмите 2.0» — только когда 2.0 на сервере есть (DUP-LINE-01, R4 стенда 15.10).
        if _server_has_line 2.0; then
            echo -e "  ${DIM}$(ga_win_wrap "$(t user_pick_profile_advice)" 2)${NC}" >&2
        else
            echo -e "  ${DIM}$(ga_win_wrap "$(t user_pick_profile_advice_no20) $(_reline_hint)" 2)${NC}" >&2
        fi
    fi
    ch=$(ga_ask "$(t choose)" '^[0-9]+$' "$(t invalid_choice)") || return 2
    [ "$ch" -ge 1 ] && [ "$ch" -le "${#arr[@]}" ] || return 2
    printf '%s' "${arr[$((10#$ch - 1))]}"
}

# _server_has_line <линия> — эту линию держит хоть один установленный профиль. Советы «возьмите 2.0» и «рекомендуем 2.0»
# говорятся только тогда (DUP-LINE-01, R4 стенда 15.10: на сервере две 3.1 и ни одной 2.0).
_server_has_line() {
    local p
    for p in $PROFILE_IDS; do
        _profile_installed "$p" || continue
        [ "$(ga_profile_line "$p" 2>/dev/null)" = "$1" ] && return 0
    done
    return 1
}

# _reline_hint → «Своя AmneziaWG 3.1 (awg3 · UDP 6714) переставляется на 2.0: «Протоколы» → профиль → …» — куда идти за
# недостающей линией, когда её можно получить перестановкой своего профиля (lines_check.reline); иначе пусто.
_reline_hint() {
    local js rp rl
    type ga_amn_lines_check >/dev/null 2>&1 || return 0
    js=$(ga_amn_lines_check 2>/dev/null) || return 0
    rp=$(jq -r '.reline.profile // empty' <<<"$js" 2>/dev/null)
    rl=$(jq -r '.reline.line // empty' <<<"$js" 2>/dev/null)
    [ -n "$rp" ] && [ -n "$rl" ] || return 0
    printf '%s' "$(tf dash_reline_hint "$(_pr_name "$rp")" "$rl")"
}

# _err_once <запасной текст> — отказ модуля словами ОДИН раз (KEY-APP-01): ga_err модуля уже напечатал свою ошибку
# (и положил её в GA_ERR_MSG), а экран повторял её второй строкой — «✗ Ключ … выдан в приложении Amnezia…» дважды
# подряд. Модуль промолчал — запасной текст экрана. Перед вызовом модуля вызывающий обнуляет GA_ERR_MSG.
_err_once() { [ -n "${GA_ERR_MSG:-}" ] || log_error "$1"; }

# Общий разбор ответа _pick_user_profile: результат в переменную с именем $1.
# Вынесено, чтобы «нет профилей» и «передумал» не разъезжались между экраном
# ключа и экраном ссылки — раньше оба печатали одно и то же.
_pick_profile_into() {
    local __var="$1" __name="$2" __rc=0
    ga_capture "$__var" _pick_user_profile "$__name" "${3:-}" || __rc=$?
    case "$__rc" in
        0) return 0 ;;   # 0 — код «профиль выбран», не пункт «назад» (SR-40)
        2) GA_BACK=1 ;;  # «0» в списке профилей — назад, без лишнего «Нажмите Enter» (SR-55)
        3) log_warning "$(_ui_w "$(t user_keys_app_only)")" ;;   # ключи только в приложении (KEY-APP-02)
        *) log_error "$(t user_no_peers)" ;;
    esac
    return 1
}

# Временная ссылка на файл конфигурации (lib/share.sh, docs/SHARE.md).
# Владелец просил: по ссылке скачивается ТОЛЬКО файл, без картинок — QR он
# сканирует с экрана в меню, боте или панели. Поэтому здесь два формата, оба
# файлы, — те же два, что у бота и панели (TAIL-14; модуль и мост умеют ещё
# qr-conf, qr-vpn и all, их не зовёт ни один интерфейс). Секретный адрес
# показывается человеку и НЕ пишется ни в лог, ни в аудит — то же правило, что
# у показа приватного ключа в _user_key.
# Третий аргумент — профиль, если он уже выбран (после показа ключа в мастере и в «Добавить», NC-05): второй раз
# «каким профилем?» не спрашиваем.
_user_share() {
    local name="$1" ep="${2:-}" profile="${3:-}" fmt ch js url fp ttl
    type share_create >/dev/null 2>&1 || { log_error "$(tf module_missing share_create)"; return 1; }
    # Выключенному ядро ссылку не создаст (user_disabled, A3-5): говорим своими словами до выбора профиля, как
    # _pages_create.
    if [ "$(_users_json | jq -r --arg n "$name" '.[] | select(.name == $n) | if (.enabled == false) then "0" else "1" end' 2>/dev/null | head -1)" = 0 ]; then
        log_warning "$(t share_user_disabled)"
        return 1
    fi
    [ -n "$profile" ] || _pick_profile_into profile "$name" keyed || return 1

    echo ""
    echo -e "  ${BOLD}${WHITE}$(t share_menu_title)${NC}"
    # Для чего ссылка: перенести ключ на СВОЙ телефон за пять минут; другу — страница подключения, где у неё есть
    # домен (NC6-02: владелец принимал ссылку за способ отдать ключ другу и пугался совета про порт у хостера).
    echo -e "  ${DIM}$(ga_win_wrap "$(tf share_menu_hint "$(_share_ttl_words)")" 2)${NC}"
    if type pages_create >/dev/null 2>&1 && _pages_domain_ok; then
        echo -e "  ${DIM}$(ga_win_wrap "$(t share_menu_friend_page)" 2)${NC}"
    fi
    echo -e "  ${DIM}$(_rule)${NC}"
    echo -e "  ${DIM}$(t share_menu_pick_format)${NC}"
    echo -e "  ${CYAN}1${NC}) $(t share_menu_fmt_conf)"
    echo -e "  ${CYAN}2${NC}) $(t share_menu_fmt_vpn)"
    echo -e "  ${CYAN}0${NC}) $(t back)"
    echo -ne "  ${WHITE}$(t choose):${NC} "
    read -r ch || ch=0
    case "$ch" in
        1) fmt=conf ;;
        2) fmt=vpn ;;
        ""|0) GA_BACK=1; return 0 ;;
        *) log_error "$(t invalid_choice)"; return 0 ;;
    esac

    # Через ga_capture, а не $( ): в подоболочке терялся бы код отказа модуля. GA_SHARE_QUIET — модуль молчит о
    # том, что этот экран скажет сам и понятнее (NC-11); отказы и файрвол он называет по-прежнему.
    GA_ERR_MSG=""
    GA_SHARE_QUIET=1 ga_capture js share_create "$name" "$profile" "$fmt" "$ep" \
        || { _err_once "$(t key_failed)"; return 1; }
    local file port mins
    url=$(printf '%s' "$js" | jq -r '.url')
    fp=$(printf '%s' "$js"  | jq -r '.fingerprint // ""')
    ttl=$(printf '%s' "$js" | jq -r '.ttl')
    file=$(printf '%s' "$js" | jq -r '.file_name // ""')
    port=$(printf '%s' "$js" | jq -r '.port // ""')
    # Срок — минутами и временем сервера, а не «300 секунд» и «23:06 UTC» (находка NC-11 критика-новичка)
    [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=300
    mins=$(( (ttl + 30) / 60 )); [ "$mins" -ge 1 ] || mins=1
    echo ""
    echo -e "  ${WHITE}$(tf share_ui_link "$file" "$(_minutes_words "$mins")")${NC}"
    echo -e "  ${GREEN}${url}${NC}"
    echo -e "  ${DIM}$(t share_ui_open_hint)${NC}"
    [ -n "$ep" ] && echo -e "  ${DIM}$(tf share_ui_endpoint "$ep")${NC}"
    echo -e "  ${DIM}$(ga_win_wrap "$(tf share_ui_expires "$(_minutes_words "$mins")" "$(_clock_in "$ttl")")" 2)${NC}"
    if [ "$(printf '%s' "$js" | jq -r '.selfsigned')" = true ]; then
        # Самоподписанный: одна строка, что увидит браузер и куда нажать; отпечаток — один раз, для тех, кто сверяет
        log_warning "$(t share_ui_selfsigned_note)"
    fi
    # Порт у ссылки случайный, TCP: у многих хостеров свой файрвол в панели, и там он закрыт
    [[ "$port" =~ ^[0-9]+$ ]] && echo -e "  ${DIM}$(ga_win_wrap "$(tf share_ui_port_hint "$port")" 2)${NC}"
    # Что увидит человек по ссылке и после срока: сразу файл (не страница), а потом «не удаётся подключиться» —
    # владелец должен знать это заранее, чтобы объяснить (находка NC-12 критика-новичка).
    case "$fmt" in
        conf) echo -e "  $(ga_win_wrap "$(tf share_ui_friend_conf "$file")" 2)" ;;
        *)    echo -e "  $(ga_win_wrap "$(tf share_ui_friend_vpn "$file")" 2)" ;;
    esac
    echo -e "  $(ga_win_wrap "$(t share_ui_friend_expired)" 2)"
    if [ "$(printf '%s' "$js" | jq -r '.selfsigned')" = true ] && [ -n "$fp" ]; then
        echo -e "  ${DIM}$(ga_win_wrap "$(tf share_ui_fingerprint "$fp")" 2)${NC}"
    fi
    # Паузу делает вызывающий (меню ключа): своя давала «Нажмите Enter» два раза подряд.
    return 0
}

# _minutes_words <n> → «5 минут» / «1 минуту» / «2 минуты» (EN — «5 minutes»): склонение — общее, ga_minutes.
_minutes_words() { ga_minutes "$@"; }

# _clock_in <секунд> → «02:06»: который час будет на сервере через столько секунд (его часовой пояс, а не UTC —
# рядом всегда пометка «по времени сервера»). GNU date и BSD date.
_clock_in() {
    local e
    e=$(( $(date +%s) + ${1:-0} ))
    date -d "@$e" +%H:%M 2>/dev/null || date -r "$e" +%H:%M 2>/dev/null || printf '%s' '-'
}

# Экран «Раздачи»: что сейчас раздаётся, снять одну, снять все.
#
# Создать раздачу из SSH было можно, а снять — нечем: список, отзыв и отзыв
# всех есть и в модуле (share_list / share_revoke / share_revoke_all), и в
# мосте, строки словаря для этого экрана написаны и не использовались ни разу,
# а текст отказа на пределе одновременных раздач сам советовал «снимите
# лишние». Секретной части адреса здесь нет и быть не может — share_list её не
# отдаёт: кому нужна ссылка, создаёт новую раздачу.
_shares_screen() {
    local js n id ch i who prof fmt left dl exp e now when
    local -a ids=()
    type share_list >/dev/null 2>&1 || { log_error "$(tf module_missing share_list)"; return 1; }
    command -v jq >/dev/null 2>&1 || { log_error "$(t err_no_jq)"; return 1; }
    while true; do
        _screen_head "$(t share_ui_list_title)"
        ga_capture js share_list || js=""
        if ! printf '%s' "$js" | jq -e . >/dev/null 2>&1; then
            log_error "${GA_ERR_MSG:-$(t share_err_no_jq)}"; return 1
        fi
        n=$(printf '%s' "$js" | jq -r '.count // 0')
        ids=()
        if [ "${n:-0}" = 0 ]; then
            echo -e "  ${DIM}$(t share_ui_list_empty)${NC}"
        else
            # Строки нумеруются, и номер строки СНИМАЕТ эту раздачу: прежде
            # снятие требовало набрать идентификатор вида s-1591 — единственное
            # место продукта, где от человека ждали букв. Разделитель \x1f по
            # той же причине, что в списке пользователей: пустые поля при
            # табуляции схлопываются с соседними. Читаем через подстановку
            # процесса, а не конвейером: в конвейере цикл идёт в подоболочке, и
            # собранный список идентификаторов до меню бы не доехал.
            i=0
            now=$(date +%s)
            while IFS=$'\x1f' read -r id who prof fmt left dl exp; do
                [ -n "$id" ] || continue
                i=$((i + 1)); ids+=("$id")
                # Срок словами тем же ga_rel_time, что у страниц подключения («истекает через 5 минут»), а не
                # «осталось 277 с» (TAIL-22). Отсчёт — от expires раздачи: раздача, что дорезает отдачу после
                # срока, честно «истекла N назад»; expires не разобрался — остаток секунд от «сейчас».
                [[ "$left" =~ ^[0-9]+$ ]] || left=0
                e=$(ga_iso_epoch "$exp") || e=$(( now + left ))
                if [ "$e" -ge "$now" ]; then when=$(tf ts_expires_in "$(ga_rel_time "$e")")
                else when=$(tf ts_expired_ago "$(ga_rel_time "$e")"); fi
                echo -e "  ${CYAN}$(_pad "$i" 2)${NC} $(tf share_ui_list_row "${DIM}${id}${NC}" "$who" "$(_pr_name "$prof")" "$fmt" "$when" "$dl")"
            done < <(printf '%s' "$js" | jq -r '.shares[]? | [.id, .name, .profile, .format,
                ((.seconds_left // 0) | tostring), ((.downloads // 0) | tostring), (.expires // "")] | join("\u001f")')
        fi
        echo -e "  ${DIM}$(_rule)${NC}"
        local n_all
        n_all=$(( ${#ids[@]} + 1 ))
        echo -e "  ${CYAN}${n_all}${NC}) $(t share_ui_revoke_all)"
        echo -e "  ${CYAN}0${NC}) $(t back)"
        [ "${#ids[@]}" -gt 0 ] && echo -e "  ${DIM}$(ga_win_wrap "$(tf share_ui_pick_legend "$n_all")" 2)${NC}"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0
        case "$ch" in
            "$n_all")
                [ "${#ids[@]}" = 0 ] && { log_info "$(t share_ui_list_empty)"; _pause; continue; }
                # Снятие раздачи не рушит ничего, кроме самой ссылки, но она
                # может быть уже отправлена человеку — поэтому спрашиваем.
                confirm "$(t share_ui_revoke_all)" || { log_info "$(t cancelled)"; _pause; continue; }
                GA_ERR_MSG=""
                share_revoke_all >/dev/null || _err_once "$(t share_err_no_jq)"
                _pause
                ;;
            0) GA_BACK=1; return 0 ;;
            "") continue ;;
            *)
                # Не длиннее четырёх цифр и десятично (SR-53: число длиннее int64 роняло меню).
                if ! [[ "$ch" =~ ^[0-9]{1,4}$ ]] || [ "$((10#$ch))" -lt 1 ] || [ "$((10#$ch))" -gt "${#ids[@]}" ]; then
                    log_error "$(t invalid_choice)"; _pause; continue
                fi
                id="${ids[$((10#$ch - 1))]}"
                confirm "$(tf share_ui_revoke_ask "$id")" || { log_info "$(t cancelled)"; _pause; continue; }
                GA_ERR_MSG=""
                share_revoke "$id" >/dev/null || _err_once "$(tf share_err_not_found "$id")"
                _pause
                ;;
        esac
    done
}

# Показ ключа в четырёх видах. Приватный ключ уходит на экран человеку и НЕ
# пишется ни в лог, ни в аудит (правило §0.7 контракта).
# Четвёртый аргумент — профиль, если он уже известен (подписка: QR ключа линии у приложения, _subs_client_screen):
# «каким профилем?» тогда не спрашиваем.
_user_key() {
    local name="$1" kind="$2" ep="${3:-}" profile="${4:-}" conf link tmp title_conf title_vpn
    [ -n "$profile" ] || _pick_profile_into profile "$name" keyed || return 1
    # Какой профиль выдан — для проверки подключения после ключа (_wait_first_handshake).
    GA_LAST_KEY_PROFILE="$profile"
    # Разовый адрес сервера (экран ключей, «Ключ на другой адрес») — в заголовке: иначе два ключа одного
    # человека на экране не отличить.
    if [ -n "$ep" ]; then
        title_conf=$(tf key_title_conf_at "$name" "$(_pr_name "$profile")" "$ep")
        title_vpn=$(tf key_title_vpn_at "$name" "$(_pr_name "$profile")" "$ep")
    else
        title_conf=$(tf key_title_conf "$name" "$(_pr_name "$profile")")
        title_vpn=$(tf key_title_vpn "$name" "$(_pr_name "$profile")")
    fi

    GA_LAST_QR_OK=0
    case "$kind" in
        qr-conf|qr-first|conf)
            type export_conf >/dev/null 2>&1 || { log_error "$(tf module_missing export_conf)"; return 1; }
            # Через ga_capture: отказ разового адреса (address_not_here) несёт свои слова, подоболочка их теряла.
            GA_ERR_MSG=""
            ga_capture conf export_conf "$name" "$profile" "$ep" || { _err_once "$(t key_failed)"; return 1; }
            [ -n "$conf" ] || { log_error "$(t key_failed)"; return 1; }
            if [ "$kind" != conf ]; then
                echo ""
                echo -e "  ${BOLD}${WHITE}${title_conf}${NC}"
                # Не влезла картинка — после ключа пункты, как перенести его на телефон (_key_next_steps: и в
                # карточке, и в «Добавить», и в мастере — NC-05, NC-07, NC-27); конфиг текстом — отдельный пункт
                # карточки, двадцать пять строк с приватным ключом телефону не помогут.
                _key_conf_qr "$conf" "$profile" && GA_LAST_QR_OK=1
            else
                # mktemp, а не предсказуемый путь: в файле приватный ключ, и
                # симлинк-атака на /tmp/<name>.conf отдала бы его чужому.
                # Каталог — в памяти (ga_mktemp_secret), а не на диске: файл
                # раньше не удалялся ничем и никогда, то есть приватный ключ
                # клиента оставался в /tmp до перезагрузки, и обычное удаление
                # его содержимого не стирает (docs/DEFECTS.md §1c.14).
                # Файл — с понятным именем «<пользователь>-<линия>.conf» (anna-2_0.conf): приложения берут имя туннеля
                # из имени файла, а Linux — не длиннее 15 знаков. Лежит в своём каталоге 0700 со случайным именем
                # (симлинк-атака на предсказуемый путь исключена) и затирается, когда человек уходит с экрана; рядом —
                # готовая строка scp (A-2 критика 16.10: безликое скрытое имя без .conf жило до перезагрузки).
                local kdir="" kbase="" kline
                # Основа имени — одна с временной ссылкой (ga_key_file_base, R-6: у двух профилей одной линии —
                # anna-3_1-2 / anna-3_1-3); модуля нет — прежнее правило.
                type ga_key_file_base >/dev/null 2>&1 && kbase=$(ga_key_file_base "$name" "$profile" 2>/dev/null)
                if [ -z "$kbase" ]; then
                    kline=$(_profile_line "$profile"); kline="${kline//./_}"
                    kbase="${name//[^A-Za-z0-9_-]/}"; kbase="${kbase:0:10}"; [ -n "$kbase" ] || kbase=key
                    kbase="${kbase}${kline:+-$kline}"
                fi
                if type ga_mktemp_secret_dir >/dev/null 2>&1; then
                    # Остатки прошлых показов (убитый процесс, SIGKILL — ловушка ниже их не ловит) стираем сразу.
                    # Только старше 10 минут: соседний сеанс SSH, может быть, прямо сейчас держит свой файл для scp.
                    _key_conf_sweep
                    ga_capture kdir ga_mktemp_secret_dir "goamnezia-conf" || return 1
                else
                    kdir=$(mktemp -d "${TMPDIR:-/tmp}/goamnezia-conf.XXXXXXXX") || return 1
                    chmod 700 "$kdir" 2>/dev/null || true
                fi
                # Ctrl+C или обрыв SSH, пока файл с приватным ключом на диске: он не должен пережить экран (R-2).
                # Ловушка — до записи файла (Q-3): между записью и паузой идут подоболочки, и сигнал в этом окне
                # без неё либо проглатывался (INT — скрипт шёл дальше), либо оставлял файл до очистки (HUP).
                # Ловушка стирает каталог и пропускает сигнал дальше — как и без неё, программа выходит.
                local __ko_int __ko_term __ko_hup
                __ko_int=$(trap -p INT); __ko_term=$(trap -p TERM); __ko_hup=$(trap -p HUP)
                _GA_KEY_CONF_DIR="$kdir"
                trap '_key_conf_signal INT' INT
                trap '_key_conf_signal TERM' TERM
                trap '_key_conf_signal HUP' HUP
                tmp="$kdir/${kbase}.conf"
                ( umask 077; printf '%s\n' "$conf" > "$tmp" )
                # Вошёл обычным пользователем и поднялся через sudo — scp пойдёт от его имени, а каталог 0700
                # root он не прочтёт. Отдаём ему только файл (ключ он и так видит на экране); каталог остаётся за
                # root, 0711: войти по известному имени можно, прочесть список и подменить файл ссылкой — нельзя
                # (Q-4: иначе root на затирании мог пойти по его ссылке в чужой файл).
                local kuser=root
                if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] \
                        && [[ "$SUDO_USER" =~ ^[a-z_][a-z0-9_.-]*\$?$ ]] && id "$SUDO_USER" >/dev/null 2>&1; then
                    chown "$SUDO_USER" "$tmp" 2>/dev/null && chmod 711 "$kdir" 2>/dev/null && kuser="$SUDO_USER"
                fi
                echo ""
                echo -e "  ${BOLD}${WHITE}${title_conf}${NC}"
                _key_min_client "$profile" conf
                echo -e "  ${DIM}$(_rule)${NC}"
                printf '%s\n' "$conf"
                echo -e "  ${DIM}$(_rule)${NC}"
                log_info "$(tf key_saved_to "$tmp")"
                echo -e "  ${DIM}$(t key_saved_scp)${NC}"
                echo -e "    ${GREEN}scp ${kuser}@$(_key_scp_host):${tmp} .${NC}"
                echo ""
                echo -ne "  ${DIM}$(t key_saved_enter)${NC}"
                read -r _ || true
                eval "${__ko_int:-trap - INT}"; eval "${__ko_term:-trap - TERM}"; eval "${__ko_hup:-trap - HUP}"
                _GA_KEY_CONF_DIR=""
                if type ga_wipe_dir >/dev/null 2>&1; then ga_wipe_dir "$kdir"; else rm -rf "$kdir"; fi
                # Своя пауза уже была — вызывающему вторая ни к чему.
                GA_BACK=1
            fi
            ;;
        vpn|qr-vpn)
            type export_vpn >/dev/null 2>&1 || { log_error "$(tf module_missing export_vpn)"; return 1; }
            GA_ERR_MSG=""
            ga_capture link export_vpn "$name" "$profile" "$ep" || { _err_once "$(t key_failed)"; return 1; }
            [ -n "$link" ] || { log_error "$(t key_failed)"; return 1; }
            echo ""
            echo -e "  ${BOLD}${WHITE}${title_vpn}${NC}"
            _key_min_client "$profile" vpn
            if [ "$kind" = "vpn" ]; then
                echo -e "  ${GREEN}${link}${NC}"
            else
                _key_vpn_series "$link" && GA_LAST_QR_OK=1
            fi
            ;;
    esac
    # Выдача ключа из SSH — в журнал действий, как из бота, панели и MCP (находка SR-03).
    type ga_export_audit_key >/dev/null 2>&1 && ga_export_audit_key "$name" "$profile" "${kind/qr-first/qr-conf}" "$ep"
    # Разовый адрес сторож не видит (он считает людей по закреплённому адресу) — подсказать, как закрепить.
    if [ -n "$ep" ] && _user_address_offer "$name"; then
        echo -e "  ${DIM}$(ga_win_wrap "$(tf user_key_addr_pin_hint "$ep" "$(t user_address_item)")" 2)${NC}"
    fi
    return 0
}

# _key_conf_signal <сигнал> — сигнал на паузе экрана «.conf»: стереть каталог с ключом, вернуть прежние ловушки
# (переменные __ko_* — локальные _user_key, видны отсюда, пока она ждёт Enter) и отдать сигнал себе же.
_key_conf_signal() {
    local d="${_GA_KEY_CONF_DIR:-}"
    _GA_KEY_CONF_DIR=""
    if [ -n "$d" ]; then
        if type ga_wipe_dir >/dev/null 2>&1; then ga_wipe_dir "$d"; else rm -rf "$d"; fi
    fi
    eval "${__ko_int:-trap - INT}"; eval "${__ko_term:-trap - TERM}"; eval "${__ko_hup:-trap - HUP}"
    kill -s "$1" "$BASHPID" 2>/dev/null
}

# _key_conf_sweep — стереть забытые каталоги «.goamnezia-conf.*» старше 10 минут в каталоге секретов.
# Только свои (-user): /dev/shm открыт всем на запись, и чужой каталог с тем же именем — чужой; стирать его от root
# значит идти по ссылкам, которые подложил его владелец (Q-2). Ссылки на каталоги find не выдаёт: -type d без -L.
_key_conf_sweep() {
    type ga_secret_tmpdir >/dev/null 2>&1 && type ga_wipe_dir >/dev/null 2>&1 || return 0
    local base d
    base=$(ga_secret_tmpdir)
    [ -d "$base" ] || return 0
    while IFS= read -r d; do
        [ -n "$d" ] && ga_wipe_dir "$d"
    done < <(find "$base" -maxdepth 1 -type d -user "$(id -u)" -name '.goamnezia-conf.*' -mmin +10 2>/dev/null)
    return 0
}

# Адрес сервера для строки scp: внешний адрес машины из настроек; нет — заглушка, которую человек заменит.
_key_scp_host() {
    local h
    h=$(_cfg '.server_ip')
    _valid_ip "$h" 2>/dev/null || h="<IP>"
    case "$h" in *:*) printf '[%s]' "$h" ;; *) printf '%s' "$h" ;; esac
}

# Минимальная версия приложения Amnezia для линейки профиля. Функция была
# (ga_export_min_client), мост её отдаёт, документ обещает — а рядом с ключом в
# SSH её не показывали, и человек узнавал о старом приложении, только когда
# ключ не импортировался (замечание критика).
# _key_next_steps <имя> <профиль> <QR показан 1|0> [подпись пункта «0»] — что дальше после первого ключа (конец
# мастера, «Добавить → показать ключ»). Раньше мастер сразу ждал подключения 3 минуты — и когда QR не влез в
# окно и подключаться было нечем, а «соседний пункт карточки» из подсказки в мастере не существовал (находка
# NC-05 критика-новичка, 28.09.2026). Теперь ожидание — только по просьбе, а если QR не показан, сразу пути,
# как перенести ключ на телефон: показать QR снова (уменьшив шрифт или развернув окно), QR в браузере через
# веб-панель и SSH-туннель, временная ссылка на файл. Enter и 0 — дальше; управление только цифрами.
# _key_conf_qr <conf> <профиль> — QR ключа .conf с подписью, какие приложения его читают. Подпись — только над
# настоящей картинкой: над «QR-код не помещается» она говорила о QR, которого на экране нет (находка NC-27). Строка
# про свежую AmneziaWG у ключа 3.1 — в любом случае. rc 0 — QR показан; 1 — нет (почему — GA_QR_WHY).
_key_conf_qr() {
    local conf="$1" line
    line=$(_profile_line "$2")
    GA_QR_WHY=""
    if _qr_make "$conf" && _qr_fits "$GA_QR_W" "$GA_QR_H"; then
        echo -e "  ${DIM}$(ga_win_wrap "$(t key_app_conf)" 2)${NC}"
        _key_note_31 "$line"
        _qr_print "$GA_QR_OUT"
        return 0
    fi
    if [ -n "$GA_QR_OUT" ]; then
        GA_QR_WHY=big
        _qr_say_too_big "$GA_QR_W" "$GA_QR_H"
    else
        GA_QR_WHY=missing
        log_warning "$(t qr_missing)"
    fi
    _key_note_31 "$line"
    return 1
}

# _key_vpn_series <ссылка vpn://> — серия QR для приложения Amnezia: ключ длиннее, чем влезает в один QR, и
# приложение читает серию кусков — режем ровно её кодеком (ссылка — через stdin: в ней приватный ключ, а argv
# виден всем в /proc, находка SR-17). Все куски рисуются и меряются ДО первого заголовка (NC-06): не влезает хоть
# один — ни одного заголовка, подсказка и ссылка текстом. rc 0 — серия показана; 1 — нет (почему — GA_QR_WHY).
_key_vpn_series() {
    local link="$1" chunks="" n=0 i c qw=0 qh=0
    local -a qrs=()
    GA_QR_WHY=""
    if [ -f "$LIB_DIR/awgkeys.py" ] && command -v python3 >/dev/null 2>&1; then
        chunks=$(printf '%s' "$link" | python3 "$LIB_DIR/awgkeys.py" qr-chunks - 2>/dev/null) || chunks=""
    fi
    if [ -z "$chunks" ] || ! command -v jq >/dev/null 2>&1; then
        GA_QR_WHY=missing
        log_warning "$(t key_chunks_missing)"
        echo -e "  ${GREEN}${link}${NC}"
        return 1
    fi
    n=$(printf '%s' "$chunks" | jq -r 'length' 2>/dev/null) || n=0
    for ((i = 0; i < n; i++)); do
        c=$(printf '%s' "$chunks" | jq -r --argjson i "$i" '.[$i]' 2>/dev/null)
        if ! _qr_make "$c"; then
            GA_QR_WHY=missing
            log_warning "$(t qr_missing)"
            echo -e "  ${GREEN}${link}${NC}"
            return 1
        fi
        qrs+=("$GA_QR_OUT")
        [ "$GA_QR_W" -gt "$qw" ] && qw="$GA_QR_W"
        [ "$GA_QR_H" -gt "$qh" ] && qh="$GA_QR_H"
    done
    if ! _qr_fits "$qw" "$qh"; then
        GA_QR_WHY=big
        _qr_say_too_big "$qw" "$qh"
        echo -e "  ${GREEN}${link}${NC}"
        return 1
    fi
    for ((i = 0; i < n; i++)); do
        echo ""
        echo -e "  ${DIM}$(tf key_qr_chunk "$((i + 1))" "$n")${NC}"
        _qr_print "${qrs[$i]}"
    done
    return 0
}

GA_HS_OK=0
# _share_ttl_words → «5 минут»: срок временной ссылки (GOAMNEZIA_SHARE_TTL, по умолчанию 300 с) словами.
_share_ttl_words() {
    local ttl=300 mins
    type ga_share_ttl >/dev/null 2>&1 && ttl=$(ga_share_ttl 2>/dev/null)
    [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=300
    mins=$(( (ttl + 30) / 60 )); [ "$mins" -ge 1 ] || mins=1
    _minutes_words "$mins"
}

# _key_next_steps — «как перенести ключ на телефон» после ключа (мастер, «Добавить», экран ключей). Где у
# страницы подключения есть домен, она — первым пунктом: для друга это главный путь, а временная ссылка — чтобы
# перенести ключ на свой телефон за пять минут (находки NC6-01 и NC6-02 критика-новичка: страница упоминалась
# строкой выше, а среди вариантов её не было).
_key_next_steps() {
    local name="$1" profile="$2" qr_ok="${3:-1}" done_label="${4:-}" kind="${5:-conf}" ep="${6:-}" ch i label conf link
    local pjs pn
    local -a acts=()
    [ -n "$done_label" ] || done_label=$(t kn_done)
    while true; do
        acts=()
        type pages_create >/dev/null 2>&1 && _pages_domain_ok && acts+=(page)
        [ "$qr_ok" != 1 ] && [ "${GA_QR_WHY:-}" = big ] && acts+=(again)
        _panel_present && acts+=(panel)
        type share_create >/dev/null 2>&1 && acts+=(link)
        acts+=(wait)
        echo ""
        if [ "$qr_ok" = 1 ]; then
            echo -e "  ${BOLD}${WHITE}$(t kn_title_qr)${NC}"
        else
            echo -e "  ${BOLD}${WHITE}$(t kn_title_noqr)${NC}"
        fi
        for i in "${!acts[@]}"; do
            case "${acts[$i]}" in
                page)  label=$(t kn_page) ;;
                again) label=$(t kn_again) ;;
                panel) label=$(t kn_panel) ;;
                link)  label=$(tf kn_link "$(_share_ttl_words)") ;;
                *)     label=$(t kn_wait) ;;
            esac
            echo -e "  ${CYAN}$((i + 1))${NC}) $(ga_win_wrap "$label" 5)"
        done
        echo -e "  ${CYAN}0${NC}) ${done_label}"
        echo -ne "  ${WHITE}$(t kn_prompt):${NC} "
        read -r ch || ch=0
        case "$ch" in ""|0) return 0 ;; esac
        if ! [[ "$ch" =~ ^[0-9]{1,2}$ ]] || [ "$((10#$ch))" -lt 1 ] || [ "$((10#$ch))" -gt "${#acts[@]}" ]; then
            log_error "$(t invalid_choice)"
            continue
        fi
        case "${acts[$((10#$ch - 1))]}" in
            page)
                # Тот же поток, что пункт «Страница подключения» карточки: страниц ещё нет — сразу создать (срок →
                # адрес и QR), есть — их список (показать адрес, отозвать, создать ещё).
                pjs=""; pn=0
                type pages_list >/dev/null 2>&1 && { ga_capture pjs pages_list "$name" 2>/dev/null || pjs=""; }
                pn=$(printf '%s' "$pjs" | jq -r '.count // 0' 2>/dev/null) || pn=0
                if [[ "$pn" =~ ^[0-9]+$ ]] && [ "$pn" -gt 0 ]; then
                    _pages_screen "$name"
                else
                    _pages_create "$name" || true
                fi
                GA_BACK=0
                ;;
            again)
                GA_ERR_MSG=""
                if [ "$kind" = vpn ]; then
                    if ga_capture link export_vpn "$name" "$profile" "$ep" 2>/dev/null && [ -n "$link" ]; then
                        _key_vpn_series "$link" && qr_ok=1
                    else
                        log_error "$(_ui_w "${GA_ERR_MSG:-$(t key_failed)}")"
                    fi
                    link=""
                elif ga_capture conf export_conf "$name" "$profile" "$ep" 2>/dev/null && [ -n "$conf" ]; then
                    echo ""
                    _key_conf_qr "$conf" "$profile" && qr_ok=1
                else
                    log_error "$(_ui_w "${GA_ERR_MSG:-$(t key_failed)}")"
                fi
                conf=""
                ;;
            panel)
                echo ""
                _panel_tunnel_hint
                echo -e "  ${DIM}$(ga_win_wrap "$(tf kn_panel_where "$name")" 2)${NC}"
                ;;
            link)
                _user_share "$name" "$ep" "$profile" || true
                GA_BACK=0
                ;;
            *)
                GA_HS_OK=0
                _wait_first_handshake "$name" "$profile"
                [ "$GA_HS_OK" = 1 ] && return 0
                ;;
        esac
    done
}

# _wait_first_handshake <имя> <профиль> — «проверка подключения» после ключа (находка критика продукта 25.09.2026):
# момент «заработало» — главный, и только в эту минуту закрытый UDP-порт в файрволе хостера ловится, пока человек
# ещё сидит в терминале. Ждём СВЕЖЕГО рукопожатия пира до 3 минут; Enter — прекратить. Зовётся только по просьбе
# человека (_key_next_steps, NC-05). Без терминала, на стенде (dry-run без подставного вывода awg) и с
# GOAMNEZIA_NO_HANDSHAKE_WAIT=1 — не ждём. Подключился — GA_HS_OK=1.
_wait_first_handshake() {
    local name="${1:-}" profile="${2:-}" pub port start now ts ch limit="${GOAMNEZIA_HANDSHAKE_WAIT_SECONDS:-180}"
    [ -n "$name" ] && [ -n "$profile" ] || return 0
    [[ "$limit" =~ ^[0-9]+$ ]] || limit=180
    [ -t 0 ] && [ -t 1 ] || return 0
    [ "${GOAMNEZIA_NO_HANDSHAKE_WAIT:-0}" = 1 ] && return 0
    if ga_dry && [ -z "${GOAMNEZIA_AWG_SHOW_FIXTURE:-}" ]; then
        return 0
    fi
    type amnezia_show >/dev/null 2>&1 || return 0
    pub=$(ga_users_get "$name" 2>/dev/null | jq -r --arg p "$profile" '.peers[$p].pubkey // empty' 2>/dev/null)
    [ -n "$pub" ] || return 0
    port=$(ga_profile_field "$profile" port 2>/dev/null)
    start=$(date +%s)
    echo ""
    echo -e "  ${CYAN}$(ga_win_wrap "$(t hs_wait)" 2)${NC}"
    echo -ne "  "
    while :; do
        ts=$(amnezia_show "$profile" 2>/dev/null | jq -r --arg k "$pub" '.[] | select(.pubkey == $k) | .latest_handshake_ts' 2>/dev/null | head -1)
        # Рукопожатие не старше начала ожидания: старое — это прежнее подключение, а не этот ключ.
        if [[ "$ts" =~ ^[0-9]+$ ]] && [ "$ts" -ge "$((start - 5))" ]; then
            echo ""
            log_success "$(t hs_ok)"
            GA_HS_OK=1
            return 0
        fi
        now=$(date +%s)
        if [ $((now - start)) -ge "$limit" ]; then
            echo ""
            log_warning "$(t hs_timeout_title)"
            echo -e "  ${DIM}$(ga_win_wrap "$(tf hs_timeout_hint "${port:-?}")" 2)${NC}"
            return 0
        fi
        if read -r -t 3 ch; then
            log_info "$(t hs_skipped)"
            return 0
        fi
        echo -n "."
    done
}

#
# Какое приложение что читает — по каталогу клиентов (lib/clients.json): QR и файл .conf читают AmneziaWG,
# WG Tunnel и роутеры, а приложение AmneziaVPN — только vpn:// и серию QR vpn://. Раньше под QR .conf стояло
# «Нужно приложение Amnezia версии…», и человек сканировал его в AmneziaVPN, который такой QR не примет
# (находка критика продукта 25.09.2026). Второй аргумент — вид ключа: conf (по умолчанию) или vpn.
_key_min_client() {
    local line kind="${2:-conf}"
    line=$(_profile_line "$1")
    if [ "$kind" = conf ]; then
        echo -e "  ${DIM}$(ga_win_wrap "$(t key_app_conf)" 2)${NC}"
        _key_note_31 "$line"
        return 0
    fi
    # Один номер версии на все устройства врал: на iPhone и на Android минимальные версии разные, и страница
    # подключения называла другое число (находка NC-18 критика-новичка). Здесь — «свежая версия» и где номера:
    # на странице подключения, если ей есть где жить, иначе — «обновите до последней»: в «Только VPN» страницы нет,
    # и ссылка на неё вела в никуда (находка NC-26).
    [ -n "$line" ] || return 0
    if _pages_domain_ok; then
        echo -e "  ${DIM}$(ga_win_wrap "$(t key_min_client)" 2)${NC}"
    else
        echo -e "  ${DIM}$(ga_win_wrap "$(t key_min_client_nopage)" 2)${NC}"
    fi
}

# Строка про свежую версию AmneziaWG у ключа 3.1 — с отсылкой к странице, только если странице есть где жить (NC-26).
_key_note_31() {
    [ "${1:-}" = "3.1" ] || return 0
    if _pages_domain_ok; then
        echo -e "  ${DIM}$(ga_win_wrap "$(t key_app_conf_31)" 2)${NC}"
    else
        echo -e "  ${DIM}$(ga_win_wrap "$(t key_app_conf_31_nopage)" 2)${NC}"
    fi
}

# Ноль в этих двух ответах значит не «ноль дней» и не «ноль гигабайт», а «срок
# снят» и «лимита нет». Продукт печатал «Срок пользователя anna: 0 дней.» и
# «Лимит пользователя anna: 0 ГБ.» — по букве верно, по смыслу наоборот.
_days_or_never() { [ "${1:-0}" = 0 ] && t never || ga_days "$1"; }
_gb_or_unlimited() { [ "${1:-0}" = 0 ] && t unlimited || printf '%s %s' "$1" "$(t unit_gb)"; }

# Текущий лимит в ГБ и текущий срок словами — для вопросов, где Enter меняет
# настройку: человек должен видеть, что у него стоит сейчас.
_user_quota_gb() {
    local name="$1" b
    b=$(_users_json | jq -r --arg n "$name" '.[] | select(.name==$n) | (.quota_bytes // 0)' 2>/dev/null) || b=0
    [[ "$b" =~ ^[0-9]+$ ]] || b=0
    printf '%s' $(( b / 1073741824 ))
}
# _expiry_words <ISO> → «истекает через 29 дн. (… по времени сервера)» или «истёк 2 дн. назад (…)» (NC-11).
_expiry_words() {
    local e
    e=$(ga_iso_epoch "${1:-}") || { ga_human_ts "${1:-}"; return 0; }
    if [ "$e" -ge "$(date +%s)" ]; then tf ts_expires_in "$(ga_human_ts "$1")"; else tf ts_expired_ago "$(ga_human_ts "$1")"; fi
}

_user_expiry_human() {
    local name="$1" e
    e=$(_users_json | jq -r --arg n "$name" '.[] | select(.name==$n) | (.expires // "")' 2>/dev/null) || e=""
    [ -n "$e" ] && _expiry_words "$e" || t never
}

# ── Адрес сервера в ключе пользователя (несколько адресов, docs/EDGEIPS.md §3.1) ─────────────────────

_user_endpoint_ip() {
    _users_json | jq -r --arg n "${1:-}" '.[] | select(.name==$n) | (.endpoint_ip // "")' 2>/dev/null | head -1
}

# Пункт «Адрес сервера в ключе» нужен, когда выбирать есть из чего — у машины два внешних адреса и
# больше, — или когда адрес уже задан: иначе его не снять. На сервере с одним адресом пункта нет.
_user_address_offer() {
    local own n
    if ! type users_set_endpoint_ip >/dev/null 2>&1 || ! type ga_edge_list >/dev/null 2>&1; then
        return 1
    fi
    own=$(_user_endpoint_ip "${1:-}")
    [ -n "$own" ] && return 0
    n=$(ga_edge_list 2>/dev/null | grep -c .)
    [ "${n:-0}" -ge 2 ]
}

# Что сейчас в ключах пользователя — тем же правилом, что сборка ключа (ga_export_endpoint_host): домен,
# вписанный в общий Endpoint, побеждает свой адрес, домен сервера по умолчанию ему уступает, а свой адрес,
# пропавший с машины, называется прямо.
_user_address_line() {
    local name="${1:-}" own common rc=0
    own=$(_user_endpoint_ip "$name")
    common=$(ga_export_endpoint_host 2>/dev/null) || common=""
    if [ -n "$common" ] && ! _valid_ip "$common" \
        && { [ -z "$own" ] || [ "$(ga_export_endpoint_source 2>/dev/null)" = host ]; }; then
        if [ -n "$own" ]; then
            tf user_address_line_domain_own "$common" "$own"
        else
            tf user_address_line_domain "$common"
        fi
    elif [ -n "$own" ]; then
        ga_export_endpoint_host "$name" >/dev/null 2>&1 || rc=$?
        if [ "$rc" = 2 ]; then
            tf user_address_line_gone "$own"
        else
            tf user_address_line_own "$own"
        fi
    else
        tf user_address_line_common "${common:--}"
    fi
}

# Что сказать после смены адреса — одна функция на SSH-меню и мост. Решает ответ модуля
# (users_set_endpoint_ip): изменился ли адрес в самом ключе и не домен ли в общем Endpoint.
_user_address_note() {
    local js="${1:-}" name ip host
    name=$(jq -r '.name // ""' <<<"$js" 2>/dev/null)
    ip=$(jq -r '.endpoint_ip // ""' <<<"$js" 2>/dev/null)
    host=$(jq -r '.endpoint // ""' <<<"$js" 2>/dev/null)
    if [ "$(jq -r '.resend_required == true' <<<"$js" 2>/dev/null)" = true ]; then
        if [ -n "$ip" ]; then
            tf user_address_set_resend "$name" "$ip"
        else
            tf user_address_common_resend "$name" "$host"
        fi
    elif [ "$(jq -r '.domain_endpoint == true' <<<"$js" 2>/dev/null)" = true ] && [ -n "$ip" ]; then
        tf user_address_domain "$ip" "$name" "$host"
    else
        tf user_address_same "$name" "${host:--}"
    fi
}

# Выбор адреса: строки — внешние адреса машины с числом пользователей на каждом. Общий адрес подписан, и
# выбрать его — вернуть общий, а не записать копию: копия застыла бы при смене общего адреса. Пустой
# ввод и 0 — назад, как во всём меню.
_user_address_screen() {
    local name="${1:-}" own common domain="" listed="" map a cnt label ch i res
    local -a addrs=() opts=() vals=()
    type users_set_endpoint_ip >/dev/null 2>&1 || { log_error "$(tf module_missing users_set_endpoint_ip)"; return 1; }
    own=$(_user_endpoint_ip "$name")
    common=$(ga_export_endpoint_host 2>/dev/null) || common=""
    if [ -n "$common" ] && ! _valid_ip "$common"; then domain=1; fi
    mapfile -t addrs < <(ga_edge_list 2>/dev/null)
    map=$(ga_edge_users_map 2>/dev/null)
    _screen_head "$(t user_address_item)" "$(tf user_menu_for "$name")"
    echo -e "  $(ga_win_wrap "$(_user_address_line "$name")" 2)"
    if [ -n "$domain" ]; then
        # Вписанный домен побеждает свой адрес — предупреждаем; домен по умолчанию уступает — просто говорим.
        if [ "$(ga_export_endpoint_source 2>/dev/null)" = host ]; then
            log_warning "$(tf user_address_domain_note "$common")"
        else
            log_dim "$(tf user_address_site_domain_note "$common")"
        fi
    fi
    for a in "${addrs[@]}"; do
        [ -n "$a" ] || continue
        label="$a"
        if [ -z "$domain" ] && [ "$a" = "$common" ]; then
            label+=" · $(t user_address_common_mark)"
            listed=1
            vals+=("")
        else
            vals+=("$a")
        fi
        if [ "$a" = "$own" ] || { [ -z "$own" ] && [ -z "$domain" ] && [ "$a" = "$common" ]; }; then
            label+=" · $(t user_address_current_mark)"
        fi
        # Пользователи на адресе — как в отчёте сторожа (ga_edge_users_map): со своим адресом — на нём, с доменом
        # в ключе — на каждом адресе, его выбирает DNS. Прежде при домене счётчики прятались целиком, а под доменом
        # по умолчанию пользователи со своим адресом к адресам приписаны.
        cnt=$(awk -F'\t' -v ip="$a" '$1 == ip || $1 == "?" { n += $2 } END { print n + 0 }' <<<"$map")
        label+=" · $(tf user_address_users "$cnt")"
        opts+=("$label")
    done
    if [ -n "$own" ] && [ -z "$listed" ]; then
        opts+=("$(t user_address_reset_item)")
        vals+=("")
    fi
    for ((i = 0; i < ${#opts[@]}; i++)); do
        echo -e "  ${CYAN}$((i + 1))${NC}) ${opts[$i]}"
    done
    echo -e "  ${CYAN}0${NC}) $(t back)"
    echo -e "  ${DIM}$(_rule)${NC}"
    echo -ne "  ${WHITE}$(t choose):${NC} "
    read -r ch || ch=0
    case "$ch" in ""|0) GA_BACK=1; return 0 ;; esac
    if ! [[ "$ch" =~ ^[0-9]{1,3}$ ]] || [ $((10#$ch)) -lt 1 ] || [ $((10#$ch)) -gt "${#opts[@]}" ]; then
        log_error "$(t invalid_choice)"
        return 1
    fi
    res=$(users_set_endpoint_ip "$name" "${vals[$((10#$ch - 1))]}") || return 1
    if [ "$(jq -r '.resend_required == true' <<<"$res" 2>/dev/null)" = true ]; then
        log_warning "$(_user_address_note "$res")"
    else
        log_success "$(_user_address_note "$res")"
    fi
}

_user_edit_quota() {
    local name="$1" gb
    type users_set_quota >/dev/null 2>&1 || { log_error "$(tf module_missing users_set_quota)"; return 1; }
    # Текущее значение перед вопросом: без него человек, зашедший посмотреть,
    # жмёт Enter и снимает лимит, даже не узнав, какой он был.
    # «0» здесь значит «назад», как везде в меню, а не «без лимита»: во всём
    # перестроенном меню ноль — выход, и человек, зашедший посмотреть и нажавший
    # привычный ноль, молча снимал чужой лимит. Снять лимит — это Enter, и так и
    # написано в самом вопросе.
    gb=$(GA_EOF_CANCEL=1 ga_ask_optional "$(tf user_ask_quota_cur "$(_gb_or_unlimited "$(_user_quota_gb "$name")")")" '^[0-9]+$' "$(t bad_number)") \
        || { log_info "$(t cancelled)"; return 1; }
    [ "$gb" = 0 ] && { log_info "$(t cancelled)"; return 1; }
    [ -n "$gb" ] || gb=0
    users_set_quota "$name" "$gb" >/dev/null || return 1
    # Лимит — за всё время, сброса по месяцам нет (lib/users.sh): так и сказать в итоге (находка NC6-06).
    if [ "$gb" -gt 0 ]; then
        log_success "$(tf user_quota_set_total "$name" "$(_gb_or_unlimited "$gb")")"
    else
        log_success "$(tf user_quota_set "$name" "$(_gb_or_unlimited "$gb")")"
    fi
}

_user_edit_expiry() {
    local name="$1" days
    type users_set_expiry >/dev/null 2>&1 || { log_error "$(tf module_missing users_set_expiry)"; return 1; }
    # Тот же уговор, что с лимитом: ноль — выход, «бессрочно» — Enter.
    days=$(GA_EOF_CANCEL=1 ga_ask_optional "$(tf user_ask_days_cur "$(_user_expiry_human "$name")")" '^[0-9]+$' "$(t bad_number)") \
        || { log_info "$(t cancelled)"; return 1; }
    [ "$days" = 0 ] && { log_info "$(t cancelled)"; return 1; }
    [ -n "$days" ] || days=0
    users_set_expiry "$name" "$days" >/dev/null && log_success "$(tf user_expiry_set "$name" "$(_days_or_never "$days")")"
}

_user_rename() {
    local name="$1" label
    type users_rename >/dev/null 2>&1 || { log_error "$(tf module_missing users_rename)"; return 1; }
    label=$(ga_ask "$(t user_ask_new_label)" '.' "$(t user_bad_label)") \
        || { log_info "$(t cancelled)"; return 1; }
    users_rename "$name" "$label" >/dev/null && log_success "$(tf user_renamed "$name" "$label")"
}

# Удаление пользователя: набор имени, а не «y». В боте и в панели удаление уже
# требует набрать фразу, и странно, что слабее всего оно было защищено там, где
# человек сидит под root (замечание критика).
_user_delete() {
    local name="$1"
    type users_del >/dev/null 2>&1 || { log_error "$(tf module_missing users_del)"; return 1; }
    log_warning "$(tf user_delete_warn "$name")"
    confirm_phrase "$name" "$(tf user_delete_ask "$name")" || return 1
    users_del "$name" >/dev/null   # модуль сам говорит «удалён вместе со всеми пирами»
}

# ══════════════════════════════════════════════════════════════════════════════
# Раздел 2: Состояние
# ══════════════════════════════════════════════════════════════════════════════

submenu_status() {
    local ch
    while true; do
        _screen_head "$(t menu_status)"
        echo -e "  ${CYAN}1${NC}) $(t st_item_status)"
        echo -e "  ${CYAN}2${NC}) $(t st_item_traffic)"
        echo -e "  ${CYAN}3${NC}) $(t st_item_logs)"
        echo -e "  ${CYAN}4${NC}) $(t st_item_addr)"
        echo -e "  ${CYAN}0${NC}) $(t back)"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0

        case "$ch" in
            1) _status_report ;;
            2) _traffic_report ;;
            3) _logs_screen ;;
            4) _addresses_report ;;
            0) GA_BACK=1; break ;;
            "") continue ;;
            *) log_error "$(t invalid_choice)" ;;
        esac

        _pause
    done
}

# _core_ver_words <профиль> <тег образа> → «3.1.20260828», а у подхваченного у приложения (тег latest) — «3.1.20260828
# (образ приложения, latest)» или «не узнать (образ приложения, latest)» (A-8 критика 16.10).
_core_ver_words() {
    local p="$1" tag="${2:-}" v=""
    [ "$tag" = latest ] || { printf '%s' "$tag"; return 0; }
    type ga_profile_core_version >/dev/null 2>&1 && v=$(ga_profile_core_version "$p" 2>/dev/null)
    if [ -n "$v" ] && [ "$v" != latest ]; then tf pr_core_ver_app "$v"; else t pr_core_ver_app_unknown; fi
}

_status_report() {
    local p js st port line ver
    _screen_head "$(t st_item_status)" "$(t st_report_note)"
    # Профиль — тем же названием, что в «Протоколах» и «Трафике» («AmneziaWG 2.0», «AmneziaWG 3.1 · из приложения»),
    # а не местом awg3/awg2 с отдельной колонкой линейки: номер в имени места сбивал с линией (A-9 критика 16.10).
    printf '  %b%s %s %s %s%b\n' "$DIM" " " "$(_pad "$(t col_profile)" 30)" \
        "$(_pad "$(t col_port)" 10)" "$(t col_core)" "$NC"
    for p in $PROFILE_IDS; do
        _profile_installed "$p" || continue
        st=$(_profile_state "$p")
        port=$(_cfg ".profiles.$p.port")
        line=$(_profile_line "$p")
        ver=$(_cfg ".profiles.$p.image_tag")
        if type amnezia_profile_status >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
            js=$(amnezia_profile_status "$p" 2>/dev/null) || js=""
            if [ -n "$js" ]; then
                port=$(printf '%s' "$js" | jq -r '.port // empty' 2>/dev/null)
                line=$(printf '%s' "$js" | jq -r '.line // empty' 2>/dev/null)
                ver=$(printf '%s' "$js" | jq -r '.image_tag // empty' 2>/dev/null)
            fi
        fi
        # Версия образа — словом «образ»: голое «3.1.20260828» у профиля линии 2.0 читалось как линия 3.1 (NC6-09).
        # У подхваченного «latest» — сборка по дайджесту или «не узнать» (A-8).
        if [ "$ver" = latest ]; then ver=$(_core_ver_words "$p" "$ver")
        elif [ -n "$ver" ]; then ver=$(tf st_image_fmt "$ver"); fi
        printf '  %b %s %s %s\n' "$(_profile_icon "$st")" \
            "$(ga_cell "$(_pr_name "$p" noport)" 30)" "$(_pad "UDP ${port:--}" 10)" "${ver:--}"
    done
    _legend_profiles
    echo -e "  ${DIM}$(_rule)${NC}"
    if command -v docker >/dev/null 2>&1; then
        echo -e "  $(t st_docker): ${GREEN}$(docker --version 2>/dev/null | head -1)${NC}"
    else
        echo -e "  $(t st_docker): ${RED}$(t st_docker_missing)${NC}"
    fi
    echo -e "  $(t st_users): ${CYAN}$(_users_count)${NC}"
}

# Трафик по подключениям. Раньше в первой колонке стояли двенадцать знаков
# публичного ключа — для человека это шум: соответствие «ключ → имя» лежит в
# users.json, и печатать надо имя. Ключ остаётся ТОЛЬКО у подключения, которого
# в списке пользователей нет (его завели приложением Amnezia напрямую), и с
# пометкой — иначе такую строку не отличить от нашей.
_traffic_report() {
    local p js users users_map now n_on n_all seen
    local -A shows=()
    _screen_head "$(t st_item_traffic)" "$(t st_traffic_note)"
    if ! command -v jq >/dev/null 2>&1; then log_warning "$(t err_no_jq)"; return 1; fi

    # Сначала — все профили: над таблицами строка «Сейчас на связи: N из M» (люди, у которых хоть одно подключение
    # моложе трёх минут, из всех в списке). У всех стояло «○ давно не выходил», и кто на связи, приходилось
    # высматривать по строкам (находка NC6-08 критика-новичка).
    now=$(date +%s)
    users=$(_users_json)
    for p in $PROFILE_IDS; do
        _profile_installed "$p" || continue
        type amnezia_show >/dev/null 2>&1 || break
        js=$(amnezia_show "$p" 2>/dev/null) || js=""
        [ -n "$js" ] && shows[$p]="$js"
    done
    n_all=$(printf '%s' "$users" | jq -r 'length' 2>/dev/null) || n_all=0
    n_on=$( { printf '%s\n' "$users"; printf '%s\n' "${shows[@]+"${shows[@]}"}" | jq -cs 'add // []'; } \
        | jq -rs --argjson now "$now" '.[0] as $u | (.[1] // []) as $s
            | [$s[] | select((.latest_handshake_ts // 0) > 0 and ($now - .latest_handshake_ts) < 180) | .pubkey] as $on
            | [$u[] | select([.peers[]?.pubkey] as $k | any($on[]; . as $x | $k | index($x))) | .name] | unique | length' 2>/dev/null) || n_on=0
    [[ "$n_on" =~ ^[0-9]+$ ]] || n_on=0
    [[ "$n_all" =~ ^[0-9]+$ ]] || n_all=0
    echo -e "  $(tf st_online_now "${CYAN}${n_on}${NC}" "${n_all}")"
    echo ""

    for p in $PROFILE_IDS; do
        [ -n "${shows[$p]:-}" ] || continue
        js="${shows[$p]}"
        # Идентификатор уже внутри названия линейки («AmneziaWG 3.1 (awg3)»),
        # второй раз его дописывать незачем.
        echo -e "  ${WHITE}$(_pr_name "${p}")${NC}"
        # Подпись обязательна: в этой таблице СЧЁТЧИКИ КОНТЕЙНЕРА, и они
        # обнуляются при каждом его перезапуске. Ниже — сумма за всё время,
        # которую считает сам продукт. Две несравнимые величины стояли под
        # одной подписью «Трафик», и человек читал их как одно и то же.
        echo -e "    ${DIM}$(ga_win_wrap "$(t st_traffic_live_note)" 4)${NC}"
        printf '    %b%s %s %s %s %s%b\n' "$DIM" " " "$(ga_cell "$(t col_user)" 26)" \
            "$(_pad "$(t col_down)" 11)" "$(_pad "$(t col_up)" 11)" "$(t col_seen)" "$NC"
        # {публичный ключ: «имя (подпись)»} по этому профилю — один jq на весь профиль; подпись — когда она
        # отличается от имени (NC6-08: «Туманный Лондон» рядом с foggy_london).
        # Порядок строк — как в списке пользователей (A-11 критика 16.10: был порядок `awg show`, случайный для
        # человека); подключения не из списка — в конце.
        users_map=$(printf '%s' "$users" | jq -c --arg p "$p" \
            'to_entries | [.[] | .key as $i | .value | select(.peers[$p].pubkey != null) | {key: .peers[$p].pubkey,
                value: {i: $i, n: ((.name // "?") + (if (.label // "") != "" and .label != .name then " (\(.label))" else "" end))}}]
             | from_entries' 2>/dev/null)
        [ -n "$users_map" ] || users_map='{}'
        # Онлайн = связь была меньше трёх минут назад (PLAN §5.1); рукопожатия не было ни разу — «ещё не подключался»,
        # а не «давно не выходил» (NC6-08).
        # Колонка «Связь» — когда было последнее рукопожатие («2 ч назад»), как в карточке панели: «○ давно» без
        # времени не отличало час назад от недели (A-11).
        printf '%s' "$js" | jq -r --argjson now "$now" --argjson map "$users_map" --arg unknown "$(t traffic_unknown_peer)" '
            [.[]? | ($map[(.pubkey // "")]) as $u | {u: $u, r: .}] | sort_by(if .u then .u.i else 1e9 end) | .[]
            | .r as $r | [ (if ($r.latest_handshake_ts // 0) == 0 then "–"
                      elif ($now - $r.latest_handshake_ts) < 180 then "●" else "○" end),
                     (if .u then .u.n else "\(($r.pubkey // "")[0:12])… " + $unknown end),
                     (($r.rx // 0)|tostring), (($r.tx // 0)|tostring), (($r.latest_handshake_ts // 0)|tostring) ] | @tsv' 2>/dev/null |
        while IFS=$'\t' read -r on who rx tx hs; do
            [ -n "$who" ] || continue
            case "$on" in
                "●") seen=$(t st_seen_now) ;;
                "○") seen=$(ga_rel_time "$hs") ;;
                *)   seen="–" ;;
            esac
            # Стрелки — с точки зрения пользователя, как в панели и боте (A2-12): ↓ скачал (сервер отдал, tx),
            # ↑ отдал (сервер принял, rx).
            printf '    %s %s %s %s %s\n' "$on" "$(ga_cell "$who" 26)" \
                "$(_pad "↓ $(_human_bytes "$tx")" 11)" "$(_pad "↑ $(_human_bytes "$rx")" 11)" "$seen"
        done
    done
    _legend_online

    echo -e "  ${DIM}$(_rule)${NC}"
    echo -e "  ${WHITE}$(t st_traffic_users)${NC}"
    echo -e "  ${DIM}$(ga_win_wrap "$(t st_traffic_total_note)" 2)${NC}"
    printf '    %b%s %s%b\n' "$DIM" "$(_pad "$(t col_user)" 20)" "$(t col_traffic)" "$NC"
    _users_json | jq -r '.[] | [ (.name // "?"), (((.traffic.rx // 0) + (.traffic.tx // 0))|tostring) ] | @tsv' 2>/dev/null |
    while IFS=$'\t' read -r name bytes; do
        [ -n "$name" ] || continue
        printf '    %s %s\n' "$(_pad "$name" 20)" "$(_human_bytes "$bytes")"
    done
    _traffic_summary
}

# Сводка «за сегодня / за месяц» из lib/stats.sh. Её считает таймер статистики,
# её показывает бот — и она ни разу не звалась из SSH: единственный интерфейс,
# где владелец сидит чаще всего, отвечал на вопрос «сколько за сегодня» только
# суммой за всё время.
_traffic_summary() {
    local js
    type stats_summary >/dev/null 2>&1 || return 0
    command -v jq >/dev/null 2>&1 || return 0
    # ga_capture, а не $( ): отказ на битом stats.json обязан дойти сюда кодом,
    # иначе «трафика не было» и «файл сломан» выглядят одинаково.
    ga_capture js stats_summary || {
        log_warning "${GA_ERR_MSG:-$(tf stats_corrupt_short "$(ga_stats_file)")}"
        return 0
    }
    printf '%s' "$js" | jq -e . >/dev/null 2>&1 || return 0
    echo -e "  ${DIM}$(_rule)${NC}"
    echo -e "  ${WHITE}$(t st_traffic_period)${NC}"
    echo -e "    $(_pad "$(tf st_traffic_today "$(printf '%s' "$js" | jq -r '.today.date // "-"')")" 24)" \
            "${CYAN}↓ $(_human_bytes "$(printf '%s' "$js" | jq -r '.today.tx // 0')")${NC}" \
            "${CYAN}↑ $(_human_bytes "$(printf '%s' "$js" | jq -r '.today.rx // 0')")${NC}"
    echo -e "    $(_pad "$(tf st_traffic_month "$(printf '%s' "$js" | jq -r '.month.from // "-"')")" 24)" \
            "${CYAN}↓ $(_human_bytes "$(printf '%s' "$js" | jq -r '.month.tx // 0')")${NC}" \
            "${CYAN}↑ $(_human_bytes "$(printf '%s' "$js" | jq -r '.month.rx // 0')")${NC}"
}

# Имена, которые понимает _ga_logs_tail, — ИСТОЧНИКИ логов: служба, контейнер
# или файл, у которого есть строки. Список обязан совпадать с
# param_types.component.enum в lib/actions.json (это проверяет тест): мост
# отсеивает чужое имя раньше нас, а человеку в SSH список называем мы.
#
# С участками диска из logs-status (journal, nginx, goamnezia, docker, free)
# этот список НЕ пересекается по смыслу: там считают занятое место, здесь читают
# строки. Одно слово «component» на два разных списка водило за нос и человека,
# и агента — поэтому у logs-status поля называются area (DEFECTS §3.9).
GA_LOG_SOURCES="awg1 awg2 awg3 bot admin mcp nginx system"

# Первая строка чужого сообщения об ошибке: в ответ моста и в строку на экране
# идёт она одна — многострочный текст демона рвёт и то, и другое.
_ga_logs_first_line() { printf '%s' "${1%%$'\n'*}"; }

# Почему docker не отдал лог. Текст демона всегда английский, поэтому разбираем
# его теми же помощниками, что и остальной код (ga_docker_err_*), а не ещё одной
# копией тех же регулярок.
_ga_logs_docker_err() {
    local comp="$1" cname="$2" err="$3"
    if ga_docker_err_no_such "$err"; then
        ga_err logs_no_container "$(tf st_logs_err_no_container "$cname" "$comp")"
    elif ga_docker_err_no_logs "$err"; then
        ga_err logs_driver_unreadable "$(tf st_logs_err_driver "$cname")"
    elif ga_docker_err_unreachable "$err"; then
        ga_err logs_docker_down "$(t st_logs_err_docker_down)"
    else
        ga_err logs_read_failed "$(tf st_logs_err_read "$comp" "$(_ga_logs_first_line "$err")")"
    fi
    return 1
}

# Журнал systemd: с юнитом или целиком. Сначала убеждаемся, что служба вообще
# есть: journalctl на несуществующий юнит отвечает пустотой и ровно с тем же
# кодом 0, что и живая служба без записей, — «службы нет» выглядело как «логов
# не было».
_ga_logs_journal() {
    local comp="$1" n="$2" unit="${3:-}" out rc=0
    local -a cmd=(journalctl -n "$n" --no-pager)
    command -v journalctl >/dev/null 2>&1 \
        || { ga_err logs_no_journal "$(t st_logs_err_no_journal)"; return 1; }
    if [ -n "$unit" ]; then
        if command -v systemctl >/dev/null 2>&1 && ! systemctl cat "$unit" >/dev/null 2>&1; then
            ga_err logs_no_unit "$(tf st_logs_err_no_unit "$unit")"
            return 1
        fi
        cmd+=(-u "$unit")
    fi
    out=$("${cmd[@]}" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        ga_err logs_read_failed "$(tf st_logs_err_read "$comp" "$(_ga_logs_first_line "$out")")"
        return 1
    fi
    if [ -n "$out" ]; then printf '%s\n' "$out"; fi
}

# Хвост лога компонента. Используется и экраном, и действием logs-tail, поэтому
# печатает СЫРОЙ текст в stdout и ничего больше.
#
# Отказ обязан отличаться от пустого лога. Раньше любая беда — контейнера нет,
# драйвер логов не отдаёт строк, journalctl не установлен — доезжала до человека
# как «лог пуст», а до агента как status=success с log="" (DEFECTS §3.8). Теперь
# каждая причина названа словами и кодом через ga_err: мост отвечает отказом,
# экран печатает строку.
_ga_logs_tail() {
    local comp="$1" n="${2:-100}" cname out rc=0
    [[ "$n" =~ ^[0-9]+$ ]] || n=100
    case "$comp" in
        awg1|awg2|awg3)
            cname=$(_cfg ".profiles.$comp.container")
            [ -n "$cname" ] || cname="amnezia-${comp}"
            command -v docker >/dev/null 2>&1 \
                || { ga_err logs_no_docker "$(t st_logs_err_no_docker)"; return 1; }
            out=$(ga_docker logs --tail "$n" "$cname" 2>&1) || rc=$?
            [ "$rc" -eq 0 ] || { _ga_logs_docker_err "$comp" "$cname" "$out"; return 1; }
            if [ -n "$out" ]; then printf '%s\n' "$out"; fi
            ;;
        bot)    _ga_logs_journal "$comp" "$n" goamnezia-bot.service   ;;
        admin)  _ga_logs_journal "$comp" "$n" goamnezia-admin.service ;;
        nginx)  _ga_logs_journal "$comp" "$n" nginx                   ;;
        system) _ga_logs_journal "$comp" "$n"                         ;;
        mcp)
            # Журнала действий нет не потому, что «пусто»: файл создаёт первое
            # же действие через мост, и его отсутствие — это ответ «через мост
            # ещё ничего не делали», а не поломка чтения.
            [ -f "$AUDIT_LOG" ] \
                || { ga_err logs_absent "$(tf st_logs_err_absent "$AUDIT_LOG")"; return 1; }
            out=$(tail -n "$n" "$AUDIT_LOG" 2>&1) || rc=$?
            [ "$rc" -eq 0 ] \
                || { ga_err logs_read_failed "$(tf st_logs_err_read "$comp" "$(_ga_logs_first_line "$out")")"; return 1; }
            if [ -n "$out" ]; then printf '%s\n' "$out"; fi
            ;;
        *)      ga_err bad_component "$(tf st_logs_err_unknown "$comp" "$GA_LOG_SOURCES")"; return 1 ;;
    esac
}

# Хвост лога на экран: строки — либо ПРИЧИНА, почему их нет. Три экрана (логи,
# панель, бот) решали это каждый сам и все трое одинаково неверно: любую неудачу
# называли «лог пуст».
_logs_print() {
    local comp="$1" n="${2:-60}" out cnt
    # ga_err внутри уже напечатал причину человеку — второй раз не повторяем.
    if type ga_capture >/dev/null 2>&1; then
        ga_capture out _ga_logs_tail "$comp" "$n" || return 1
    else
        out=$(_ga_logs_tail "$comp" "$n") || return 1
    fi
    if [ -z "$out" ]; then
        log_warning "$(tf st_logs_empty "$comp")"
        return 0
    fi
    # Журнал действий на диске — построчный JSON (CONTRACT §7.1): машине он и
    # нужен такой, а человеку показываем словами. Мост отдаёт сырые строки —
    # разбирать их его дело, не наше.
    # Строку разбираем ПООТДЕЛЬНОСТИ и терпим чужой формат: в файле остаются
    # строки от прежних версий, и на них jq отказывал ЦЕЛИКОМ — экран говорил
    # «пусто» при непустом журнале. Отказ разбора не имеет права выглядеть как
    # отсутствие записей (тот же узор, что в §3.8): не разобралось — печатаем
    # как есть.
    if [ "$comp" = mcp ] && command -v jq >/dev/null 2>&1; then
        local words
        words=$(printf '%s\n' "$out" | jq -Rr '
            (fromjson? // null) as $r
            | if ($r | type) == "object"
              then [ ($r.ts // "-"), ($r.iface // "-"), ($r.who // $r.client // "-"),
                     ($r.action // "-"),
                     (($r.details // "") + (if ($r.params | type) == "object"
                                            then ($r.params | tostring) else "" end)),
                     (if ($r.status // "") == "" then "" else "→ " + $r.status end) ]
                   | map(select(. != "")) | join("  ")
              else . end' 2>/dev/null) && [ -n "$words" ] && out="$words"
    fi
    printf '%s\n' "$out" | tail -n "$n"
    cnt=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
    echo -e "  ${DIM}$(tf st_logs_shown "$cnt")${NC}"
}

# Полная команда для компонента — её человек копирует, когда ста строк мало.
_logs_cmd() {
    local comp="$1" cname
    case "$comp" in
        awg1|awg2|awg3)
            cname=$(_cfg ".profiles.$comp.container"); [ -n "$cname" ] || cname="amnezia-${comp}"
            printf 'docker logs -f --tail 200 %s' "$cname" ;;
        bot)    printf 'journalctl -u goamnezia-bot.service -f' ;;
        admin)  printf 'journalctl -u goamnezia-admin.service -f' ;;
        nginx)  printf 'journalctl -u nginx -f' ;;
        system) printf 'journalctl -f' ;;
        mcp)    printf 'tail -f %s' "$AUDIT_LOG" ;;
    esac
}

# Установлен ли компонент. Экран предлагал бота, панель и nginx на сервере, где
# их нет, и «Логи пусты» ничего не объясняло (замечание критика).
_logs_available() {
    case "$1" in
        awg1|awg2|awg3) _profile_installed "$1" ;;
        bot)    systemctl cat goamnezia-bot.service   >/dev/null 2>&1 ;;
        admin)  systemctl cat goamnezia-admin.service >/dev/null 2>&1 ;;
        nginx)  command -v nginx >/dev/null 2>&1 ;;
        system) return 0 ;;
        mcp)    [ -f "$AUDIT_LOG" ] ;;
        *) return 1 ;;
    esac
}

# Экран логов: только то, что реально стоит; вывод режем по высоте окна, а не
# вываливаем сто сырых строк; внизу — полная команда, чтобы смотреть дальше.
_logs_screen() {
    local ch comp i lines
    local -a comps=() labels=()
    # mcp — журнал действий продукта: кто и что делал через SSH, панель, бота и
    # агентов. Его читал только мост, а человеку в меню «кто что сделал» было
    # взять негде (DEFECTS §5.10). Показываем словами, файл — построчный JSON.
    # Профилей AmneziaWG в списке нет: их контейнеры запущены с --log-driver none (так же делает приложение
    # Amnezia), docker logs для них пуст всегда, а пункт с ошибкой и советом `docker logs -f` следом только путал
    # (A-10 критика 16.10). Их подключения и рукопожатия — «Трафик и онлайн».
    for comp in bot admin nginx system mcp; do
        _logs_available "$comp" || continue
        comps+=("$comp")
        case "$comp" in
            awg1|awg2|awg3) labels+=("$(_pr_name "${comp}")") ;;
            bot)    labels+=("$(t st_logs_bot)") ;;
            admin)  labels+=("$(t st_logs_admin)") ;;
            nginx)  labels+=("nginx") ;;
            system) labels+=("$(t st_logs_system)") ;;
            mcp)    labels+=("$(t st_logs_audit)") ;;
        esac
    done
    _screen_head "$(t st_item_logs)" "$(t st_logs_note)"
    _profile_installed awg1 || _profile_installed awg2 || _profile_installed awg3 \
        && echo -e "  ${DIM}$(ga_wrap "$(t st_logs_profiles_note)" "${GA_UI_W:-76}" 2)${NC}"
    local _sfx
    for i in "${!comps[@]}"; do
        # У профилей идентификатор уже стоит в названии линейки — не дублируем;
        # у nginx и системного журнала подпись нужна, там она называет юнит.
        case "${labels[$i]}" in
            *"(${comps[$i]})"*) _sfx="" ;;
            *) _sfx=" ${DIM}(${comps[$i]})${NC}" ;;
        esac
        echo -e "  ${CYAN}$((i + 1))${NC}) ${labels[$i]}${_sfx}"
    done
    echo -e "  ${CYAN}0${NC}) $(t back)"
    echo -ne "  ${WHITE}$(t choose):${NC} "
    read -r ch || ch=0
    case "$ch" in ""|0) GA_BACK=1; return 0 ;; esac
    if ! [[ "$ch" =~ ^[0-9]{1,3}$ ]] || [ $((10#$ch)) -lt 1 ] || [ $((10#$ch)) -gt "${#comps[@]}" ]; then
        log_error "$(t invalid_choice)"
        return 0
    fi
    comp="${comps[$((10#$ch - 1))]}"
    # Сколько строк поместится: высота окна минус шапка, подсказка и «Enter».
    lines=$(( $(ga_term_lines) - 8 ))
    [ "$lines" -ge 5 ] || lines=5
    [ "$lines" -le 200 ] || lines=200
    echo ""
    _logs_print "$comp" "$lines" || return 0
    echo -e "  ${DIM}$(tf st_logs_full_cmd "$(_logs_cmd "$comp")")${NC}"
}

# Адреса. Колонки выравниваются по ШИРИНЕ подписи текущего языка: раньше отступы
# были набиты пробелами под английский, и в русском колонка рвалась (замечание
# критика). Слово «Endpoint» из видимых строк убрано — человеку нужен «адрес,
# который попадёт в ключ».
# Таблица «Адреса сервера» — как в goTelegram: по каждому внешнему адресу машины. В шапке она ВСЕГДА
# (просьба владельца 25.09.2026): адрес и галочка — ведёт ли на него A-запись домена. С двумя и больше
# адресами — ещё пакеты клиентов за 15 минут, час и сутки, пользователи и вердикт сторожа; на одном
# адресе сторож правил не ставит и счётчиков нет, поэтому эти колонки там не рисуем (иначе «0» и «тихо»).
#
# Домен для галочки — из ключей, если в ключах домен (клиенты расходятся только по опубликованным
# адресам, и адрес без A-записи честно простаивает); иначе — домен сайта из config.json. ✓ — адрес
# есть в A-записях, ✗ — нет, ? — DNS не ответил, — — домена нет. Под таблицей для домена из ключей —
# чужие адреса из A-записей: часть клиентов с ключами по домену попадёт на другую машину.
# Аргумент — готовый ответ ga_edge_status_json (шапка считает его один раз на кадр). rc 1 — адресов нет.
_edge_table() {
    local js="${1:-}" n ip v u p15 p1h pday mark d full=1 has_dns=0 dom="" dst="" alist="" sjs cell
    if ! type ga_edge_status_json >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        return 1
    fi
    [ -n "$js" ] || js=$(ga_edge_status_json 2>/dev/null) || return 1
    n=$(jq -r '.count // 0' <<<"$js" 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] || return 1
    [ "$n" -ge 2 ] || full=0
    # Узкое окно (SSH с телефона): полная строка — до сотни знаков и рвалась бы посреди колонок. Тогда
    # адрес, A-запись, сутки, пользователи и значок состояния; «замолчал» — отдельной строкой под таблицей.
    local compact=0
    [ "$full" = 1 ] && [[ "${GA_TERM_COLS:-120}" =~ ^[0-9]+$ ]] && [ "${GA_TERM_COLS:-120}" -lt 100 ] && compact=1
    if jq -e '.dns != null' >/dev/null 2>&1 <<<"$js"; then
        dom=$(jq -r '.dns.domain // ""' <<<"$js" 2>/dev/null)
        dst=$(jq -r '.dns.state // ""' <<<"$js" 2>/dev/null)
        alist=$(jq -r '(.dns.a // []) | join(" ")' <<<"$js" 2>/dev/null)
        [ "$dst" != unknown ] && has_dns=1
    else
        dom=$(_cfg '.domain')
        if [ -n "$dom" ] && ! _valid_ip "$dom" && type ga_site_dns_state >/dev/null 2>&1; then
            sjs=$(ga_site_dns_state "$dom" 120 stale 2>/dev/null) || sjs=""
            dst=$(jq -r '.state // "unknown"' <<<"$sjs" 2>/dev/null) || dst=unknown
            [ -n "$dst" ] || dst=unknown
            alist=$(jq -r '(.a // []) | join(" ")' <<<"$sjs" 2>/dev/null) || alist=""
        else
            dom=""
        fi
    fi
    local dark_rows=""
    if [ "$compact" = 1 ]; then
        printf '  %b%s %s %s %s%b\n' "$DIM" "$(_pad "$(t edge_col_addr)" 16)" "$(_pad "$(t edge_col_dns)" 9)" \
            "$(_pad "$(t edge_col_1d)" 9)" "$(t edge_col_users)" "$NC"
    elif [ "$full" = 1 ]; then
        printf '  %b%s %s %s %s %s %s %s%b\n' "$DIM" "$(_pad "$(t edge_col_addr)" 16)" "$(_pad "$(t edge_col_15m)" 9)" \
            "$(_pad "$(t edge_col_1h)" 9)" "$(_pad "$(t edge_col_1d)" 9)" "$(_pad "$(t edge_col_users)" 6)" \
            "$(_pad "$(t edge_col_dns)" 9)" "$(t edge_col_state)" "$NC"
    else
        printf '  %b%s %s%b\n' "$DIM" "$(_pad "$(t edge_col_addr)" 16)" "$(t edge_col_dns)" "$NC"
    fi
    while IFS=$'\t' read -r ip v u p15 p1h pday d b15 b1h bday; do
        [ -n "$ip" ] || continue
        if [ -z "$dom" ]; then
            cell="${DIM}$(_pad "—" 9)${NC}"
        elif [ "$dst" = unknown ]; then
            cell="${DIM}$(_pad "?" 9)${NC}"
        elif [[ " $alist " == *" $ip "* ]]; then
            cell="${GREEN}$(_pad "✓" 9)${NC}"
        else
            cell="${YELLOW}$(_pad "✗" 9)${NC}"
        fi
        if [ "$compact" = 1 ]; then
            case "$v" in
                ok)   mark="${GREEN}✓${NC}" ;;
                dark) mark="${YELLOW}⚠${NC}"; dark_rows+="  ${YELLOW}⚠${NC} ${ip} — $(t edge_v_dark | sed 's/^⚠ *//')"$'\n' ;;
                *)    mark="${DIM}·${NC}" ;;
            esac
            echo -e "  $(_pad "$ip" 16) ${cell} $(_pad "$(_edge_bytes "$bday")" 9) $(_pad "$u" 6) ${mark}"
        elif [ "$full" = 1 ]; then
            case "$v" in
                ok)        mark="${GREEN}$(t edge_v_ok)${NC}" ;;
                dark)      mark="${YELLOW}$(t edge_v_dark)${NC}" ;;
                quiet-all) mark="${DIM}$(t edge_v_quiet_all)${NC}" ;;
                unused)    mark="${DIM}$(t edge_v_unused)${NC}" ;;
                *)         mark="${DIM}$(t edge_v_quiet)${NC}" ;;
            esac
            echo -e "  $(_pad "$ip" 16) $(_pad "$(_edge_bytes "$b15")" 9) $(_pad "$(_edge_bytes "$b1h")" 9) $(_pad "$(_edge_bytes "$bday")" 9) $(_pad "$u" 6) ${cell} ${mark}"
        else
            echo -e "  $(_pad "$ip" 16) ${cell}"
        fi
    done < <(jq -r '.ips[] | [.ip, .verdict, (.users | tostring), (.packets_15m | tostring), (.packets_1h | tostring), (.packets_day | tostring), (.in_dns | tostring), ((.bytes_15m // 0) | tostring), ((.bytes_1h // 0) | tostring), ((.bytes_day // 0) | tostring)] | @tsv' <<<"$js" 2>/dev/null)
    [ -n "$dark_rows" ] && printf '%b' "$dark_rows"
    # Что значит галочка — одной строкой; для домена из ключей с «✗» — прежнее пояснение, что это не поломка
    if [ -z "$dom" ]; then
        echo -e "  ${DIM}$(ga_wrap "$(t edge_dns_legend_nodomain)" "${GA_UI_W:-76}" 2)${NC}"
    elif [ "$dst" = unknown ]; then
        echo -e "  ${DIM}$(ga_wrap "$(tf edge_dns_legend_unknown "$dom")" "${GA_UI_W:-76}" 2)${NC}"
    elif [ "$has_dns" = 1 ] && jq -e '[.ips[] | select(.in_dns == false)] | length > 0' >/dev/null 2>&1 <<<"$js"; then
        echo -e "  ${DIM}$(ga_wrap "$(tf edge_dns_legend "$dom")" "${GA_UI_W:-76}" 2)${NC}"
    else
        echo -e "  ${DIM}$(ga_wrap "$(tf edge_dns_legend_mark "$dom")" "${GA_UI_W:-76}" 2)${NC}"
    fi
    [ "$has_dns" = 1 ] && _edge_dns_lines "$js"
    return 0
}

# _edge_dns_lines <JSON edge-status> — что не так с A-записями домена из ключей, словами, в stdout:
# проксирование Cloudflare, домен целиком не сюда, записей нет или отдельные чужие адреса. Перенос —
# по ширине меню, а не окна: вывод идёт через $(…), где окна не видно (замечание критика: строки
# в 130 знаков рвались посреди слова в SSH с телефона).
_edge_dns_lines() {
    local js="$1" dom st f
    dom=$(jq -r '.dns.domain // ""' <<<"$js" 2>/dev/null)
    st=$(jq -r '.dns.state // ""' <<<"$js" 2>/dev/null)
    _edge_warn_line() { echo -e "  ${YELLOW}⚠${NC} $(ga_wrap "$1" "$(( ${GA_UI_W:-76} - 2 ))" 4)"; }
    if [ "$st" = elsewhere ] || [ "$st" = partial ]; then
        if [ "$(jq -r '.dns.cloudflare // false' <<<"$js" 2>/dev/null)" = true ]; then
            _edge_warn_line "$(tf website_dns_cloudflare "$dom")"
            return 0
        fi
    fi
    case "$st" in
        elsewhere) _edge_warn_line "$(tf edge_dns_elsewhere "$dom" "$(jq -r '.dns.a | join(", ")' <<<"$js")")" ;;
        none)      _edge_warn_line "$(tf edge_dns_none "$dom")" ;;
        partial)
            while IFS= read -r f; do
                [ -n "$f" ] && _edge_warn_line "$(tf edge_dns_foreign "$f" "$dom")"
            done < <(jq -r '.dns.foreign[]?' <<<"$js" 2>/dev/null)
            ;;
    esac
    return 0
}

# Строка в шапку про домен САЙТА, если у него есть A-запись на чужой адрес, а таблица о нём не сказала
# (ключи на IP или на другом домене): Let's Encrypt проверяет домен по любой из записей, и продление
# сертификата будет то проходить, то нет, а посетители сайта будут попадать на другую машину.
# Ответ DNS — из кэша на две минуты, как у таблицы. rc 1 — говорить нечего.
_site_dns_warn_header() {
    local edge_js="${1:-}" dom js f
    type ga_site_dns_state >/dev/null 2>&1 || return 1
    type ga_site_domain_ready >/dev/null 2>&1 && ga_site_domain_ready || return 1
    dom=$(_cfg '.domain')
    [ -n "$dom" ] || return 1
    # Тот же домен уже разобран таблицей или строкой про ключи
    [ -n "$edge_js" ] && [ "$(jq -r '.dns.domain // ""' <<<"$edge_js" 2>/dev/null)" = "$dom" ] && return 1
    js=$(ga_site_dns_state "$dom" 120 2>/dev/null) || return 1
    f=$(jq -r '(.foreign // []) | join(", ")' <<<"$js" 2>/dev/null)
    [ -n "$f" ] || return 1
    log_warning "$(_ui_w "$(tf dash_site_dns_foreign "$dom" "$f")")"
    return 0
}

# Строки в шапку, когда адрес у машины один, а с A-записями домена из ключей что-то не так:
# таблицы нет, а сказать надо — часть клиентов уходит на другую машину. rc 1 — говорить нечего.
_edge_dns_warn_single() {
    local js="${1:-}" out
    type ga_edge_status_json >/dev/null 2>&1 || return 1
    [ -n "$js" ] || js=$(ga_edge_status_json 2>/dev/null) || return 1
    jq -e '(.count // 0) < 2 and .dns != null' >/dev/null 2>&1 <<<"$js" || return 1
    out=$(_edge_dns_lines "$js")
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
    return 0
}
# Входящий трафик клиентов на адрес — байтами по-человечески («1,2 МБ»), ноль — «0» (владелец 25.09.2026:
# «пакеты не интересны, лучше трафик в мегабайтах»). Пакеты остались только для вердикта сторожа.
_edge_bytes() {
    local b="${1:-0}"
    [[ "$b" =~ ^[0-9]+$ ]] || b=0
    if [ "$b" = 0 ]; then printf '0'; else _human_bytes "$b"; fi
}

_edge_num() {
    local v="${1:-0}"
    [[ "$v" =~ ^[0-9]+$ ]] || { printf '%s' "$v"; return 0; }
    if [ "$v" -ge 1000000 ]; then
        awk -v v="$v" 'BEGIN { printf "%.1fM", v / 1000000 }'
    elif [ "$v" -ge 1000 ]; then
        awk -v v="$v" 'BEGIN { printf "%.1fK", v / 1000 }'
    else
        printf '%s' "$v"
    fi
}

_addresses_report() {
    local ip domain endpoint real p port w k
    ip=$(_server_ip)
    domain=$(_cfg '.domain')
    endpoint=$(_cfg '.endpoint_host')
    # Адрес в ключах спрашиваем у ТОЙ САМОЙ функции, которая его туда и кладёт
    # (ga_export_endpoint_host). Экран считал его сам по другой цепочке — с
    # доменом посередине, — и на сервере с доменом обещал «Адрес в ключах:
    # example.com», пока в каждом выданном ключе стоял IP. Человек был уверен,
    # что ключи переживут смену адреса сервера; они бы не пережили.
    real=""
    if type ga_export_endpoint_host >/dev/null 2>&1; then
        real=$(ga_export_endpoint_host 2>/dev/null) || real=""
    fi
    [ -n "$real" ] || real="${endpoint:-${ip:--}}"
    _screen_head "$(t st_item_addr)" "$(t st_addr_note)"
    w=0
    for k in st_addr_ip st_addr_domain st_addr_endpoint; do
        [ "$(ga_str_width "$(t "$k")")" -gt "$w" ] && w=$(ga_str_width "$(t "$k")")
    done
    echo -e "  $(_pad "$(t st_addr_ip):" $((w + 2)))${CYAN}${ip:--}${NC}"
    echo -e "  $(_pad "$(t st_addr_domain):" $((w + 2)))${CYAN}${domain:--}${NC}"
    echo -e "  $(_pad "$(t st_addr_endpoint):" $((w + 2)))${CYAN}${real}${NC}"
    # Домен есть, а в ключи идёт не он: это законно (домен зависит от DNS, адрес
    # — нет), но человек должен знать, что выбор за ним и где он делается.
    if [ -n "$domain" ] && [ "$real" != "$domain" ]; then
        echo -e "  ${DIM}$(ga_wrap "$(tf st_addr_domain_hint "$domain" "$(t se_endpoint)")" "${GA_UI_W:-76}" 2)${NC}"
    fi
    echo -e "  ${DIM}$(_rule)${NC}"
    # Ширина колонки — по самой длинной подписи профиля: «AmneziaWG 1.0/1.5 (awg1)» ровно 24 знака и
    # слипалась с адресом (находка LS-11).
    local lw=0 lbl
    for p in $PROFILE_IDS; do
        lbl=$(_pr_name "${p}")
        [ "$(ga_str_width "$lbl")" -gt "$lw" ] && lw=$(ga_str_width "$lbl")
    done
    for p in $PROFILE_IDS; do
        _profile_installed "$p" || continue
        port=$(_cfg ".profiles.$p.port")
        echo -e "  ${WHITE}$(_pad "$(_pr_name "${p}")" $((lw + 2)))${NC}${CYAN}${real}:${port:--}/udp${NC}"
    done
    local edge_rows edge_js=""
    edge_js=$(ga_edge_status_json 2>/dev/null) || edge_js=""
    if edge_rows=$(_edge_table "$edge_js" 2>/dev/null) && [ -n "$edge_rows" ]; then
        echo -e "  ${DIM}$(_rule)${NC}"
        printf '%s\n' "$edge_rows"
        # Пояснение про пакеты и «замолчал» — только там, где эти колонки есть (два адреса и больше)
        if [ "$(jq -r '.count // 0' <<<"$edge_js" 2>/dev/null)" -ge 2 ] 2>/dev/null; then
            echo -e "  ${DIM}$(ga_win_wrap "$(t edge_hint)" 2)${NC}"
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Раздел 3: Протоколы
# ══════════════════════════════════════════════════════════════════════════════

submenu_protocols() {
    local ch st port i p s4mark
    local -a order=()
    while true; do
        _screen_head "$(t menu_protocols)" "$(t pr_note)"
        _dash_snapshot
        order=()
        i=0
        for p in $PROFILE_IDS; do
            i=$((i + 1)); order+=("$p")
            st="${GA_DASH_STATE[$p]:-missing}"; port="${GA_DASH_PORT[$p]:-}"
            # Большой S4 (S4-FIX) — пометкой у строки: что с ним и пункт починки — в карточке.
            s4mark=""
            [ -n "${GA_DASH_S4[$p]:-}" ] && s4mark="  ${YELLOW}$(tf pr_s4_mark "${GA_DASH_S4[$p]}")${NC}"
            # Порт — своей колонкой, поэтому имя без него (две одинаковые линии различает она же, DUP-LINE-01).
            echo -e "  ${CYAN}${i}${NC}) $(_profile_icon "$st") $(_pr_name "${p}" noport)  ${DIM}${port:+UDP $port}${NC}${s4mark}"
        done
        _legend_profiles
        _dash_lines_warn protocols 2>&1 || true
        echo -e "  ${CYAN}0${NC}) $(t back)"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0

        case "$ch" in
            0) GA_BACK=1; break ;;
            [1-9])
                if [ "$ch" -le "${#order[@]}" ]; then
                    _profile_card "${order[$((10#$ch - 1))]}"
                    _dash_snapshot force
                else
                    log_error "$(t invalid_choice)"
                fi
                ;;
            *) log_error "$(t invalid_choice)" ;;
        esac

        _pause
    done
}

_profile_card() {
    local profile="$1" ch st port line ver peers js ovl s4risk relineto n_s4 n_rl n_rm act
    while true; do
        st=$(_profile_state "$profile")
        port=$(_cfg ".profiles.$profile.port")
        line=$(_profile_line "$profile")
        ver=$(_cfg ".profiles.$profile.image_tag")
        peers=""
        s4risk=""
        if type amnezia_profile_status >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
            js=$(amnezia_profile_status "$profile" 2>/dev/null) || js=""
            [ -n "$js" ] && peers=$(printf '%s' "$js" | jq -r '.peers // empty' 2>/dev/null)
            [ -n "$js" ] && s4risk=$(printf '%s' "$js" | jq -r '.packet_risk.s4 // empty' 2>/dev/null)
        fi
        ver=$(_core_ver_words "$profile" "$ver")

        _screen_head "$(_pr_name "${profile}")" "$(tf pr_card_note "$(_pr_name "$profile" noport)")"
        echo -e "  $(t pr_state): $(_profile_icon "$st") $(_profile_state_label "$st")    $(t pr_port): ${CYAN}${port:--}${NC}    $(t pr_line): ${CYAN}${line:--}${NC}"
        # Линия 2.0 на сборке ядра 3.x: рядом «Линейка 2.0» и «Версия ядра 3.1.…» читались как «стоит 3.1» (LH-8) — сказать,
        # что эта сборка обслуживает и 2.0.
        local ver_note=""
        [ "$line" = 2.0 ] && [[ "$ver" == 3.* ]] && ver_note=" ${DIM}$(t pr_core_ver_both20)${NC}"
        echo -e "  $(t pr_core_ver): ${CYAN}${ver:--}${NC}${ver_note}    $(t pr_peers): ${CYAN}${peers:-0}${NC}"
        # Движок AmneziaWG: модуль ядра или программа — фактический и выбранный (lib/kmod.sh, KMOD_PLAN Б10)
        _profile_installed "$profile" && type ga_kmod_card_line >/dev/null 2>&1 && ga_kmod_card_line "$profile"
        # Подсеть пересекается с другим профилем (SUBNET-01): сказать на карточке, выход — пункт «Подсеть».
        if _profile_installed "$profile" && ovl=$(_subnet_overlap_of "$profile"); then
            log_warning "$(_ui_w "$(ga_amn_subnet_overlap_text "$ovl")")"
        fi
        # Свой профиль повторяет линию другого, а второй линии пары нет (DUP-LINE-01) — пункт «Переставить».
        relineto=""
        if _profile_installed "$profile" && type ga_amn_lines_check >/dev/null 2>&1; then
            relineto=$(ga_amn_lines_check 2>/dev/null | jq -r --arg p "$profile" 'select(.reline.profile == $p) | .reline.line' 2>/dev/null)
        fi
        # Пункты починки — по порядку следом за постоянными 1–10, «Удалить» — последним (D-7 проверки 15.10: раньше
        # «13) Переставить» стоял над «1)», а 12 не было). Постоянные номера 1–10 не сдвигаются никогда; номера после них
        # (11–13: починка и «Удалить») — по тому, что есть на карточке.
        n_s4=""; n_rl=""; n_rm=11
        [ -n "$s4risk" ] && { n_s4=$n_rm; n_rm=$((n_rm + 1)); }
        [ -n "$relineto" ] && { n_rl=$n_rm; n_rm=$((n_rm + 1)); }
        # Пакет данных не влезает в мобильные сети из-за большого S4 (S4-FIX, MTU-01): сказать на карточке и пункт.
        if [ -n "$s4risk" ]; then
            log_warning "$(_ui_w "$(tf amnezia_s4_risk "$(_pr_name "$profile")" "$s4risk") $(tf pr_s4_card_hint "$n_s4")")"
        fi
        [ -n "$relineto" ] && _dash_lines_warn card "$profile" "$n_rl"
        echo -e "  ${DIM}$(_rule)${NC}"
        # Профиль не поставлен — один пункт «Установить»: настройки порта, подсети и
        # параметров у несуществующего профиля только пугали («выглядит сломанным»). У
        # поставленного «Удалить» — последним и красным, как везде в продукте (правило
        # владельца «разрушительное — в конце»; находки LC-10 и критика UX, 25.09.2026).
        if ! _profile_installed "$profile"; then
            echo -e "  ${CYAN}1${NC}) $(t pr_install)"
            echo -e "  ${CYAN}0${NC}) $(t back)"
            echo -e "  ${DIM}$(_rule)${NC}"
            echo -ne "  ${WHITE}$(t choose):${NC} "
            read -r ch || ch=0
            case "$ch" in
                1) _profile_install_interactive "$profile" ;;
                0) GA_BACK=1; return 0 ;;
                "") continue ;;
                *) log_error "$(t invalid_choice)" ;;
            esac
            _pause
            continue
        fi
        echo -e "  ${CYAN}1${NC}) $(t pr_set_port)"
        # Профиль уже на UDP/443 — «Занять UDP/443» ни к чему (как в панели); номера остальных пунктов прежние (LH-2).
        # Пункт 2 тогда серый с пояснением: дырка 1), 3) читалась как пропавший пункт (A-7).
        if [ "$port" = 443 ]; then
            echo -e "  ${DIM}2) $(t pr_take443) — $(t pr_take443_here)${NC}"
        else
            echo -e "  ${CYAN}2${NC}) $(t pr_take443)"
        fi
        echo -e "  ${CYAN}3${NC}) $(t pr_params)"
        echo -e "  ${CYAN}4${NC}) $(t pr_set_param)"
        echo -e "  ${CYAN}5${NC}) $(t pr_set_mtu)"
        echo -e "  ${CYAN}6${NC}) $(t pr_set_subnet)"
        echo -e "  ${CYAN}7${NC}) $(t pr_preset)"
        echo -e "  ${CYAN}8${NC}) $(t pr_regen)"
        echo -e "  ${CYAN}9${NC}) $(t pr_restart)"
        # Починка пропавшего контейнера. Она была во всём продукте, кроме
        # кнопки: amnezia_state_restore поднимает контейнер из state/ без
        # перевыпуска ключей и без архива, а и сторож, и бот советовали
        # восстановление из бэкапа — самое разрушительное действие продукта.
        echo -e "  ${CYAN}10${NC}) $(t pr_repair)"
        [ -n "$n_s4" ] && echo -e "  ${CYAN}${n_s4}${NC}) ${YELLOW}$(t pr_s4_fix)${NC}"
        [ -n "$n_rl" ] && echo -e "  ${CYAN}${n_rl}${NC}) ${YELLOW}$(tf pr_reline "$relineto")${NC}"
        echo -e "  ${CYAN}${n_rm}${NC}) ${RED}$(t pr_remove)${NC}"
        echo -e "  ${CYAN}0${NC}) $(t back)"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0
        # Номера после 10 — по тому, что есть на карточке: в слова, а 11–13 сами по себе ничего не значат. Набранное
        # словом (reline, s4, remove) — неверный выбор, а не действие в обход номеров (P-2 проверки 15.10).
        case "$ch" in
            ""|[0-9]|10) act="$ch" ;;
            *) act=invalid ;;
        esac
        [ "$act" = 2 ] && [ "$port" = 443 ] && act=on443
        if [ -n "$n_s4" ] && [ "$ch" = "$n_s4" ]; then act=s4
        elif [ -n "$n_rl" ] && [ "$ch" = "$n_rl" ]; then act=reline
        elif [ "$ch" = "$n_rm" ]; then act=remove
        elif [[ "$ch" =~ ^1[1-9]$ ]]; then act=invalid
        fi

        case "$act" in
            1) _profile_port_interactive "$profile" "" ;;
            2) _profile_port_interactive "$profile" 443 ;;
            3) _profile_params_show "$profile" ;;
            4) _profile_set_param_interactive "$profile" ;;
            5) _profile_set_mtu_interactive "$profile" ;;
            6) _profile_set_subnet_interactive "$profile" ;;
            7) _profile_regen_interactive "$profile" ask ;;
            8) _profile_regen_interactive "$profile" default ;;
            9)
                # Перезапуск рвёт связь всем, кто сейчас подключён, — раньше он
                # уходил в дело без единого вопроса (замечание критика).
                if type amnezia_profile_restart >/dev/null 2>&1; then
                    log_warning "$(tf pr_restart_warn "$(_pr_name "${profile}")")"
                    if confirm "$(tf pr_restart_ask "$(_pr_name "${profile}")")"; then
                        ga_step "$(tf pr_restarting "$(_pr_name "$profile")")" "$(tf pr_restarted "$(_pr_name "$profile")")" "" \
                            amnezia_profile_restart "$profile"
                    else
                        log_info "$(t cancelled)"
                    fi
                else
                    log_error "$(tf module_missing amnezia_profile_restart)"
                fi
                ;;
            10) _profile_repair_interactive "$profile" ;;
            on443) log_info "$(t pr_take443_already)" ;;
            remove) _profile_remove_interactive "$profile" ;;
            s4) _profile_fix_s4_interactive "$profile" ;;
            reline) _profile_reline_interactive "$profile" "$relineto" ;;
            0) GA_BACK=1; return 0 ;;
            "") continue ;;
            *) log_error "$(t invalid_choice)" ;;
        esac

        _pause
    done
}

_profile_install_interactive() {
    local profile="$1" port subnet
    type amnezia_profile_install >/dev/null 2>&1 || { log_error "$(tf module_missing amnezia_profile_install)"; return 1; }
    port=$(_ask_port "$profile" "$(_random_port)") || return 1
    subnet=$(_ask_install_subnet "$profile") || return 1
    # Линия — недостающая (ядро, ga_profile_auto_line; DUP-LINE-01): имя профиля в строках шага — по ней же,
    # «Ставлю профиль AmneziaWG 2.0 (awg3)», а не по месту.
    ga_step "$(tf pr_installing "$(_pr_install_name "$profile")")" "$(tf pr_installed "$(_pr_install_name "$profile")")" "$(t eta_profile)" \
        amnezia_profile_install "$profile" "$port" default "$subnet" || return 1
    _profile_offer_keys_to_all "$profile"
    return 0
}

# Новый профиль стоит, а ключей на нём нет ни у кого: удаление профиля стирает их у всех, и
# повторная установка их не возвращает. Раньше об этом молчали и при удалении, и после установки
# (находка LC-12, 25.09.2026). Предлагаем выдать ключ всем сразу; отказ — строка, где это сделать.
# Ключи на профиле уже есть у кого-то (после «Переставить на 2.0» их только что выдали тем, у кого он был, — D-4
# проверки 15.10) — вопрос не «нет ни у кого», а по именам: у кого ключа нет.
_profile_offer_keys_to_all() {
    local profile="$1" names n name ok=0 users have ask
    type users_add_peer >/dev/null 2>&1 || return 0
    users=$(_users_json 2>/dev/null) || users='[]'
    names=$(jq -r --arg p "$profile" '.[] | select((.peers // {})[$p] == null) | .name' <<<"$users" 2>/dev/null) || names=""
    n=$(printf '%s\n' "$names" | awk 'NF' | wc -l | tr -d ' ')
    [ "${n:-0}" -gt 0 ] || return 0
    have=$(jq -r --arg p "$profile" '[.[] | select((.peers // {})[$p] != null)] | length' <<<"$users" 2>/dev/null) || have=0
    if [[ "$have" =~ ^[0-9]+$ ]] && [ "$have" -gt 0 ]; then
        local who
        who=$(jq -c --arg p "$profile" '[.[] | select((.peers // {})[$p] == null) | .name]' <<<"$users" 2>/dev/null) || who='[]'
        if type _ga_amn_names >/dev/null 2>&1; then who=$(_ga_amn_names "$who"); else who=$(jq -r 'join(", ")' <<<"$who"); fi
        ask=$(tf pr_keys_rest_ask "$(_pr_name "${profile}")" "$who")
    else
        ask=$(tf pr_keys_all_ask "$n" "$(_pr_name "${profile}")")
    fi
    if confirm "$ask"; then
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            users_add_peer "$name" "$profile" >/dev/null 2>&1 && ok=$((ok + 1))
        done <<<"$names"
        log_success "$(tf pr_keys_all_done "$ok" "$n" "$(_pr_name "${profile}")")"
    else
        log_dim "$(t pr_keys_all_later)"
    fi
}

# Подсеть нового профиля. Enter — та, что продукт выбрал бы сам (по умолчанию или первая свободная), 0 —
# назад. Своя нужна, когда у клиента уже есть туннели с такими адресами: сервер видит пересечения только
# со своими профилями, а туннели роутера к другим серверам — нет, о них и говорит подсказка. Проверка та
# же, что у установки. stdout: подсеть или пусто (по умолчанию).
_ask_install_subnet() {
    local profile="$1" def="" cidr i
    type ga_amn_pick_subnet >/dev/null 2>&1 && def=$(ga_amn_pick_subnet "$profile" 2>/dev/null)
    echo -e "  ${DIM}$(ga_win_wrap "$(t pr_subnet_install_note)" 2)${NC}" >&2
    for ((i = 0; i < 3; i++)); do
        cidr=$(ga_ask_optional "$(tf pr_ask_subnet_install "$(_pr_install_name "${profile}")" "${def:--}")" \
            '^(0|(10|172|192)\.[0-9]{1,3}\.[0-9]{1,3}\.0/2[0-4])$' "$(t pr_bad_subnet)" 1) || continue
        [ "$cidr" = 0 ] && { log_info "$(t cancelled)" >&2; return 1; }
        [ -n "$cidr" ] || return 0
        if type ga_amn_subnet_check >/dev/null 2>&1; then
            GA_ERR_CODE=""; GA_ERR_MSG=""
            if ! ga_amn_subnet_check "$profile" "$cidr" 2>/dev/null; then
                log_error "${GA_ERR_MSG:-$(t pr_bad_subnet)}" >&2
                continue
            fi
        fi
        printf '%s' "$cidr"
        return 0
    done
    log_info "$(t cancelled)" >&2
    return 1
}

# Поднять контейнер профиля заново из копии состояния. Ключи прежние, архив не
# нужен, выданные людям конфиги продолжают работать — это ответ на «контейнер
# пропал», а НЕ восстановление из бэкапа.
_profile_repair_interactive() {
    local profile="$1"
    type amnezia_profile_repair >/dev/null 2>&1 || { log_error "$(tf module_missing amnezia_profile_repair)"; return 1; }
    _profile_installed "$profile" || { log_error "$(tf amnezia_err_not_installed "$profile")"; return 1; }
    log_info "$(t pr_repair_note)"
    confirm "$(tf pr_repair_ask "$(_pr_name "${profile}")")" || { log_info "$(t cancelled)"; return 1; }
    ga_step "$(tf pr_repairing "$(_pr_name "$profile")")" "$(tf pr_repaired "$(_pr_name "$profile")")" "$(t eta_profile)" \
        amnezia_profile_repair "$profile"
}

# _profile_confirm_phrase <профиль> <вопрос> [ключ строки отказа] — согласие на необратимое с профилем набором его
# порта (D-5, проверка 15.10): имя места (awg3) пользователь больше нигде не видит — подписи по версии и порту, — а
# порт есть и в подписи, и в карточке. Порт не записан — по-старому, имя места. Мост и бот подтверждают по-своему
# (adopted_confirm=<профиль>). Ключ строки отказа — в confirm_phrase (RB4-1).
_profile_confirm_phrase() {
    local profile="$1" msg="$2" cancel_key="${3:-}" port
    port=$(_cfg ".profiles.$profile.port")
    if [[ "$port" =~ ^[0-9]{1,5}$ ]]; then
        confirm_phrase "$port" "$msg" "$(tf pr_confirm_port_ask "$port")" "$cancel_key"
    else
        confirm_phrase "$profile" "$msg" "" "$cancel_key"
    fi
}

_profile_remove_interactive() {
    local profile="$1"
    type amnezia_profile_remove >/dev/null 2>&1 || { log_error "$(tf module_missing amnezia_profile_remove)"; return 1; }
    log_warning "$(tf pr_remove_warn "$(_pr_name "$profile")")"
    # Сколько людей теряет ключ насовсем — сказать до подтверждения (LC-12).
    local holders
    holders=$(_users_json 2>/dev/null | jq -r --arg p "$profile" '[.[] | select((.peers // {})[$p] != null)] | length' 2>/dev/null) || holders=0
    if [[ "${holders:-0}" =~ ^[0-9]+$ ]] && [ "$holders" -gt 0 ]; then
        log_warning "$(_ui_w "$(tf pr_remove_holders "$holders")")"
    fi
    # Чьи страницы подключения перестанут работать — в них был только этот профиль, удаление их снимает
    # (PROFILE-REMOVE-PAGES): ядро считает по тем же правилам, что снятие (ga_amn_remove_preview).
    local pages_txt=""
    type ga_amn_remove_preview >/dev/null 2>&1 && pages_txt=$(ga_amn_remove_preview "$profile" 2>/dev/null | jq -r '.text // empty' 2>/dev/null)
    [ -n "$pages_txt" ] && log_warning "$(_ui_w "$pages_txt")"
    _profile_confirm_phrase "$profile" "$(tf pr_remove_ask "$(_pr_name "$profile")")" || return 1
    ga_step "$(tf pr_removing "$(_pr_name "$profile")")" "$(tf pr_removed "$(_pr_name "$profile")")" "" amnezia_profile_remove "$profile"
}

_profile_port_interactive() {
    local profile="$1" want="$2" port other busy=""
    type amnezia_profile_set_port >/dev/null 2>&1 || { log_error "$(tf module_missing amnezia_profile_set_port)"; return 1; }
    if [ -n "$want" ]; then
        port="$want"
        # UDP/443 держит РОВНО один профиль (PLAN §4.4) — иначе docker не
        # опубликует порт, а человек будет искать причину в конфиге.
        for other in $PROFILE_IDS; do
            [ "$other" = "$profile" ] && continue
            [ "$(_cfg ".profiles.$other.port")" = "443" ] && busy="$other"
        done
        if [ -n "$busy" ]; then
            log_error "$(tf pr_443_taken "$busy")"; return 1
        fi
    else
        # Предлагать ТЕКУЩИЙ порт было двойной ошибкой: он занят собственным
        # контейнером, и проверка занятости трижды подряд отвечала «порт занят»
        # на предложение самого же меню; а если человек всё-таки его набирал,
        # модуль отказывал «это и есть нынешний порт». Поэтому предлагаем
        # свободный, а нынешний показываем отдельной строкой и отвергаем своим
        # словом, а не общим «занят».
        local cur
        cur=$(_cfg ".profiles.$profile.port")
        [ -n "$cur" ] && log_dim "$(tf pr_port_current "$cur")"
        port=$(_ask_port "$profile" "$(_random_port)" "$cur") || return 1
    fi
    # Порт стоит в Endpoint каждого выданного ключа: после смены ни один старый
    # конфиг не подключится, пока человек не заберёт новый. Раньше об этом была
    # только строка-предупреждение, а действие шло без вопроса.
    log_warning "$(t pr_port_note)"
    # Кого это заденет — числом и именами, а после смены — где взять новые ключи: раньше
    # человек узнавал только «конфиги придётся переслать», но не кому и как (находки LS-14
    # и критика UX, 25.09.2026).
    local holders names
    names=$(_users_json 2>/dev/null | jq -r --arg p "$profile" '[.[] | select((.peers // {})[$p] != null) | .name] | .[:8] | join(", ")' 2>/dev/null) || names=""
    holders=$(_users_json 2>/dev/null | jq -r --arg p "$profile" '[.[] | select((.peers // {})[$p] != null)] | length' 2>/dev/null) || holders=0
    if [[ "${holders:-0}" =~ ^[0-9]+$ ]] && [ "$holders" -gt 0 ]; then
        log_dim "$(_ui_w "$(tf pr_port_holders "$holders" "$names")")"
    fi
    # Люди приложения Amnezia без ключа на сервере: объяснение и согласие набором порта профиля (ACC-2).
    local adopted_ok=""
    if [ "$(_profile_keyless "$profile")" -gt 0 ]; then
        _profile_adopted_move_ok "$profile" "$(_cfg ".profiles.$profile.port")" "$port" || return 1
        adopted_ok="$profile"
    else
        confirm "$(tf pr_port_ask "$(_pr_name "${profile}")" "$port")" || { log_info "$(t cancelled)"; return 1; }
    fi
    ga_step "$(tf pr_port_changing "$(_pr_name "$profile")" "$port")" "$(tf pr_port_changed "$(_pr_name "$profile")" "$port")" "" \
        amnezia_profile_set_port "$profile" "$port" "$adopted_ok" || return 1
    if [[ "${holders:-0}" =~ ^[0-9]+$ ]] && [ "$holders" -gt 0 ]; then
        log_info "$(_ui_w "$(t pr_port_next_steps)")"
    fi
    return 0
}

_profile_regen_interactive() {
    local profile="$1" mode="$2" preset="default" ch
    type amnezia_profile_regen >/dev/null 2>&1 || { log_error "$(tf module_missing amnezia_profile_regen)"; return 1; }
    # Пресет: заголовок, какой сейчас, и в подтверждении — какой пресет и у кого ключи перестанут работать (A-12).
    if [ "$mode" = "ask" ]; then
        local cur_p k lbl i=0
        cur_p=$(_cfg ".profiles.$profile.preset"); [[ "$cur_p" =~ ^(default|quic|router)$ ]] || cur_p=""
        _screen_head "$(t pr_preset)" "$(tf pr_preset_note "$(_pr_name "${profile}")")"
        for k in default quic router; do
            i=$((i + 1))
            if [ "$k" = "$cur_p" ]; then
                echo -e "  ${CYAN}${i}${NC}) $(t "pr_preset_$k") ${GREEN}· $(t pr_preset_now)${NC}"
            else
                echo -e "  ${CYAN}${i}${NC}) $(t "pr_preset_$k")"
            fi
        done
        echo -e "  ${CYAN}0${NC}) $(t back)"
        echo -e "  ${DIM}$(_rule)${NC}"
        ch=$(ga_ask "$(t choose)" '^[0-9]+$' "$(t invalid_choice)") || { log_info "$(t cancelled)"; return 1; }
        case "$((10#$ch))" in
            1) preset=default ;; 2) preset=quic ;; 3) preset=router ;;
            0) GA_BACK=1; return 0 ;;
            *) log_error "$(t invalid_choice)"; return 1 ;;
        esac
        lbl=$(t "pr_preset_$preset"); lbl="${lbl%% — *}"
    fi
    log_warning "$(t pr_regen_warn)"
    local holders names
    names=$(_users_json 2>/dev/null | jq -r --arg p "$profile" '[.[] | select((.peers // {})[$p] != null) | .name] | .[:8] | join(", ")' 2>/dev/null) || names=""
    holders=$(_users_json 2>/dev/null | jq -r --arg p "$profile" '[.[] | select((.peers // {})[$p] != null)] | length' 2>/dev/null) || holders=0
    if [[ "${holders:-0}" =~ ^[0-9]+$ ]] && [ "$holders" -gt 0 ]; then
        log_dim "$(_ui_w "$(tf pr_regen_holders "$holders" "$names")")"
    fi
    if [ "$mode" = "ask" ]; then
        confirm "$(tf pr_preset_ask "$lbl" "$(_pr_name "$profile")")" || { log_info "$(t cancelled)"; return 1; }
    else
        confirm "$(t pr_regen_ask)" || { log_info "$(t cancelled)"; return 1; }
    fi
    ga_step "$(tf pr_regenerating "$(_pr_name "$profile")")" "$(tf pr_regenerated "$(_pr_name "$profile")")" "" \
        amnezia_profile_regen "$profile" "$preset"
}

# Один параметр маскировки — как в настройках приложения Amnezia. Список
# параметров линейки, их стороны (сервер/клиент) и валидацию даёт модуль:
# правила разные для 1.0/1.5/2.0/3.1, дублировать их в меню значит однажды
# разойтись с ядром. Серверный параметр — предупреждение о перевыпуске ДО
# подтверждения (PLAN §10 п.9).
# Показ параметров маскировки словами, а не сырым JSON. Пункт печатал вывод
# `jq .` — тридцать строк фигурных скобок без заголовка, без пояснения и без
# «0 — назад», хотя соседний пункт «Изменить один параметр» тот же набор
# показывает по-человечески. Тот же класс, который уже закрывали на экране
# диагностики: машине — JSON через мост, человеку — слова.
# _pr_param_shown <ключ> <значение> — значение для экрана: у параметра-ключа (ga_amn_param_secret) — «задан (скрыт)»,
# пустое — «-» (K5-3: начало HeaderProtectionKey было видно на записях и скриншотах). Решает модуль
# (ga_amn_param_shown — одна функция на SSH, итог, откат и мост, KEENETIC-I1-N N3/N4); без модуля — то же здесь.
_pr_param_shown() {
    if type ga_amn_param_shown >/dev/null 2>&1; then
        ga_amn_param_shown "${1:-}" "${2:-}"
    elif [ -n "${2:-}" ] && type ga_amn_param_secret >/dev/null 2>&1 && ga_amn_param_secret "${1:-}"; then
        t pr_param_secret_set
    else
        printf '%s' "${2:--}"
    fi
}

_profile_params_show() {
    local profile="$1" list line key cur scope mark
    type amnezia_profile_param_list >/dev/null 2>&1 || { log_error "$(tf module_missing amnezia_profile_param_list)"; return 1; }
    command -v jq >/dev/null 2>&1 || { log_error "$(t err_no_jq)"; return 1; }
    list=$(amnezia_profile_param_list "$profile" 2>/dev/null) || list=""
    if [ -z "$list" ] || ! printf '%s' "$list" | jq -e 'length > 0' >/dev/null 2>&1; then
        log_error "$(tf pr_params_unavailable "$profile")"; return 1
    fi
    line=$(_profile_line "$profile")
    # Экран только показывает — подзаголовок без вопроса «какой изменить?»; правка — пункт 4 карточки (A-5).
    _screen_head "$(t pr_params)" "$(tf pr_params_note "$(_pr_name "${profile}")" "${line:--}")"
    echo -e "  ${DIM}$(ga_wrap "$(t pr_param_what)" "${GA_UI_W:-76}" 2)${NC}"
    echo -e "  ${DIM}$(_rule)${NC}"
    # Широкая раскладка занимает 81 колонку. На узком окне (телефон, панель
    # терминала сбоку) сторона пишется коротким словом, значение сжимается, а
    # смысл «серверный — нужен перевыпуск» уезжает одной строкой под таблицу
    # (DEFECTS §2.5).
    local cols narrow=0 kw=24 vw=22
    cols=$(ga_term_cols)
    if [ -t 1 ] && [ "$cols" -lt 82 ]; then
        narrow=1; kw=20; vw=$(( cols - 1 - 2 - kw - 2 - 9 )); [ "$vw" -lt 10 ] && vw=10
    fi
    while IFS=$'\x1f' read -r key cur scope; do
        [ -n "$key" ] || continue
        if [ "$narrow" = 1 ]; then
            if [ "$scope" = "server" ]; then mark="${YELLOW}$(t pr_param_scope_server_short)${NC}"
            else mark="${DIM}$(t pr_param_scope_client_short)${NC}"; fi
        elif [ "$scope" = "server" ]; then
            mark="${YELLOW}$(t pr_param_scope_server)${NC}"
        else
            mark="${DIM}$(t pr_param_scope_client)${NC}"
        fi
        printf '  %s %s %b\n' "$(_pad "$key" "$kw")" "$(ga_cell "$(_pr_param_shown "$key" "$cur")" "$vw")" "$mark"
    done < <(printf '%s' "$list" | jq -r '.[] | [.key, (.value // ""), .scope] | join("\u001f")' 2>/dev/null)
    echo -e "  ${DIM}$(_rule)${NC}"
    [ "$narrow" = 1 ] && echo -e "  ${DIM}$(ga_win_wrap "$(t pr_param_scope_legend)" 2)${NC}"
    return 0
}

_profile_set_param_interactive() {
    local profile="$1" list n line ch key cur scope value mark
    local -a rows=()
    type amnezia_profile_set_param >/dev/null 2>&1 || { log_error "$(tf module_missing amnezia_profile_set_param)"; return 1; }
    type amnezia_profile_param_list >/dev/null 2>&1 || { log_error "$(tf module_missing amnezia_profile_param_list)"; return 1; }
    command -v jq >/dev/null 2>&1 || { log_error "$(t err_no_jq)"; return 1; }
    list=$(amnezia_profile_param_list "$profile" 2>/dev/null) || list=""
    n=$(printf '%s' "$list" | jq -r 'length' 2>/dev/null) || n=0
    if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -eq 0 ]; then
        log_error "$(tf pr_params_unavailable "$profile")"; return 1
    fi
    line=$(_profile_line "$profile")
    # Разделитель \x1f, а не табуляция: табуляция — IFS-пробел, и bash
    # схлопывает соседние табы в один — у параметра с пустым значением (I2,
    # HeaderProtectionKey) сторона уезжала в колонку значения, а серверный
    # параметр терял предупреждение о перевыпуске.
    mapfile -t rows < <(printf '%s' "$list" | jq -r '.[] | [.key, (.value // ""), .scope] | join("")' 2>/dev/null)

    _screen_head "$(t pr_set_param)" "$(tf pr_param_pick_note "$(_pr_name "${profile}")" "${line:--}")"
    # Имена параметров пришли из ядра AmneziaWG и человеку не говорят НИЧЕГО
    # («Jc», «S1»). Одна строка-пояснение над списком — что это вообще такое.
    echo -e "  ${DIM}$(ga_wrap "$(t pr_param_what)" "${GA_UI_W:-76}" 2)${NC}"
    echo -e "  ${DIM}$(_rule)${NC}"
    local i=0 row
    for row in "${rows[@]}"; do
        i=$((i + 1))
        IFS=$'\x1f' read -r key cur scope <<< "$row"
        if [ "$scope" = "server" ]; then
            mark="${YELLOW}$(t pr_param_scope_server)${NC}"
        else
            mark="${DIM}$(t pr_param_scope_client)${NC}"
        fi
        # Длинное значение — через ga_cell с «…», как на «Параметрах маскировки»: жёсткий срез ${cur:0:20} молча
        # терял последнюю цифру диапазона H2–H4 (21 знак), и человек переписывал с экрана другое число (A-4).
        # Полное значение — в самом вопросе после выбора.
        printf '  %b%2d%b) %s %s %b\n' "$CYAN" "$i" "$NC" "$(_pad "$key" 22)" "$(ga_cell "$(_pr_param_shown "$key" "$cur")" 20)" "$mark"
    done
    echo -e "  ${CYAN} 0${NC}) $(t back)"
    echo -e "  ${DIM}$(_rule)${NC}"
    # Не длиннее четырёх цифр и десятично (SR-53: число длиннее int64 роняло сравнение и меню).
    ch=$(ga_ask "$(t choose)" '^[0-9]{1,4}$' "$(t invalid_choice)") || return 0
    [ "$((10#$ch))" -ge 1 ] && [ "$((10#$ch))" -le "$n" ] || return 0
    IFS=$'\x1f' read -r key cur scope <<< "${rows[$((10#$ch - 1))]}"

    # Enter — назад без изменений, «-» — убрать параметр (A-6): прежде пустой Enter, привычный «оставить как есть»,
    # означал удаление серверного параметра, а выхода не было вовсе (0 — законное значение многих параметров).
    value=$(GA_EOF_CANCEL=1 ga_ask_optional "$(tf pr_ask_param_value "$key" "$(_pr_param_shown "$key" "$cur")")" '.' "") \
        || { log_info "$(t cancelled)"; return 1; }
    [ -z "$value" ] && { GA_BACK=1; return 0; }
    [ "$value" = "-" ] && value=""
    # Значение проверяем ДО предупреждений и «Записать …?» (K5-1, живой стенд 29.10): прежде I1 с <r 2> или S4 = 41
    # сначала подтверждали, а отказ приходил после «1». Проверка — та же, что у записи, и отказ — теми же словами.
    if type amnezia_profile_param_check >/dev/null 2>&1; then
        amnezia_profile_param_check "$profile" "$key" "$value" >/dev/null || return 1
    fi
    if [ "$scope" = "server" ]; then
        log_warning "$(t pr_param_reissue_note)"
    elif [ "$value" != "$cur" ] && type ga_amn_iface_mask_param >/dev/null 2>&1 && ga_amn_iface_mask_param "$key" \
         && [ "$(docker_container_state "$(ga_profile_field "$profile" container)" 2>/dev/null)" = running ] \
         && [ "$(ga_amn_engine "$profile" 2>/dev/null)" != program ]; then
        # Клиентский параметр из [Interface] сервера на модуле ядра (KMOD-01): применится перезапуском профиля —
        # говорим ДО подтверждения, как о перевыпуске у серверных.
        log_warning "$(t pr_param_kmod_restart_note)"
    fi
    if [ -n "$value" ]; then
        confirm "$(tf pr_ask_param_confirm "$key" "$(_pr_param_shown "$key" "$value")")" || { log_info "$(t cancelled)"; return 1; }
    else
        confirm "$(tf pr_ask_param_unset_confirm "$key")" || { log_info "$(t cancelled)"; return 1; }
    fi
    # Итог и одну фразу «кому нужен новый конфиг» модуль уже сказал (PARAM-11); здесь — по людям, как у «Исправить S4».
    # Прежде здесь шли ещё своя строка «Параметр … теперь …» и «выдайте ключи заново» — вторым разом за модулем.
    local res="" step
    ga_capture res amnezia_profile_set_param "$profile" "$key" "$value" || return 1
    while IFS= read -r step; do
        [ -n "$step" ] && echo -e "    • $(ga_win_wrap "$step" 6)"
    done < <(jq -r '.steps[]?.text // empty' <<<"$res" 2>/dev/null)
    return 0
}

# MTU профиля (решение владельца 08.10): 1280 — стандарт, работает везде, и нижняя граница — ниже у клиентов с IPv6
# (AllowedIPs ::/0) туннель не поднимется вовсе (L-02б); на проводном интернете можно поднять до 1320. Enter — вернуть
# 1280. Ниже 1280 — отказ словами и тот же вопрос снова. Предупреждаем только о том, что такой MTU сломает наверняка
# (ga_amn_mtu_check): пакет данных MTU + 80 + S4 больше 1440 — на части хостеров и сетей скачивание встанет (L-02а);
# тогда — вопрос «Сохранить всё равно?». Подъём до 1320 при S4 ≤ 40 — без вопросов.
_profile_set_mtu_interactive() {
    local profile="$1" mtu rc=0 chk w warned=0 try
    type amnezia_profile_set_mtu >/dev/null 2>&1 || { log_error "$(tf module_missing amnezia_profile_set_mtu)"; return 1; }
    # Нынешнее значение в самом вопросе: без него человек не знает, что меняет,
    # и пример в скобках читается как текущая настройка (DEFECTS §3.10). Совет
    # — отдельной строкой НАД вопросом: в одной строке с подсказкой
    # «[0 — назад]» вопрос вылезал за 80 колонок (DEFECTS §4.4).
    local cur; cur=$(_cfg ".profiles.$profile.params.MTU"); [ -n "$cur" ] || cur="$(t pr_mtu_unset)"
    log_dim "$(_ui_w "$(t pr_mtu_note)")"
    # ga_capture, а не $( ): отметка «ввода нет» (GA_INPUT_EOF) должна дойти сюда — иначе оборванная сессия молча
    # записала бы умолчание 1280. Число любое — границы проверяем сами: ниже 1280 человек должен услышать почему.
    for try in 1 2 3; do
        GA_INPUT_EOF=0; rc=0; mtu=""
        ga_capture mtu ga_ask "$(tf pr_ask_mtu_cur "$cur")" '^[0-9]{1,4}$' "$(t pr_bad_mtu)" \
            "${GA_AMN_MTU_STANDARD:-1280}" || rc=$?
        # «0» — назад, без «Отменено.» (как у подсети, A-13); конец ввода и три промаха — отмена.
        if [ "$rc" = 1 ] && [ "${GA_INPUT_EOF:-0}" != 1 ]; then GA_BACK=1; return 0; fi
        if [ "$rc" != 0 ] || [ "${GA_INPUT_EOF:-0}" = 1 ] || [ -z "$mtu" ]; then log_info "$(t cancelled)"; return 1; fi
        mtu=$((10#$mtu))
        if [ "$mtu" -lt "${GA_AMN_MTU_MIN:-1280}" ]; then
            log_error "$(_ui_w "$(t amnezia_err_mtu_low)")"
        elif [ "$mtu" -gt "${GA_MTU_MAX:-1500}" ]; then
            log_error "$(t pr_bad_mtu)"
        else
            break
        fi
        [ "$try" = 3 ] && { log_info "$(t cancelled)"; return 1; }
    done
    if type ga_amn_mtu_check >/dev/null 2>&1; then
        chk=$(ga_amn_mtu_check "$profile" "$mtu" 2>/dev/null) || chk=""
        while IFS= read -r w; do
            [ -n "$w" ] || continue
            log_warning "$(_ui_w "$w")"
            warned=1
        done < <(ga_amn_mtu_warn_lines "$chk")
    fi
    if [ "$warned" = 1 ]; then
        confirm "$(tf pr_mtu_keep_ask "$mtu")" || { log_info "$(t cancelled)"; return 1; }
    fi
    amnezia_profile_set_mtu "$profile" "$mtu" >/dev/null \
        && { log_success "$(tf pr_mtu_set "$mtu")"; _note_only_new_keys; }
}

# Исправить S4 (S4-FIX, MTU-01): у выданного профиля 2.0 с большим S4 пакет данных не влезает в мобильные сети и
# PPPoE. Что будет — до вопроса; люди приложения Amnezia без ключа на сервере — ещё и набор порта профиля (ACC-2);
# после — кому что делать (шаги ядра словами): подписки обновятся сами, выданные ключи и файлы — импортировать заново.
_profile_fix_s4_interactive() {
    local profile="$1" risk budget keyless adopted="" row hours slow
    type amnezia_profile_fix_s4 >/dev/null 2>&1 || { log_error "$(tf module_missing amnezia_profile_fix_s4)"; return 1; }
    risk=$(ga_amn_packet_risk "$profile" 2>/dev/null) || risk=null
    if [ -z "$risk" ] || [ "$risk" = null ]; then log_info "$(t pr_s4_nothing)"; return 0; fi
    IFS=$'\x1f' read -r budget keyless \
        <<<"$(jq -r '[.budget, .keyless] | map(tostring) | join("\u001f")' <<<"$risk" 2>/dev/null)"
    [[ "$keyless" =~ ^[0-9]+$ ]] || keyless=0
    # R8-2: срок подписки — словами окон перевыпуска (_user_sub_within): совет сервера и приложения, что забирают реже
    hours=12 slow='[]'
    if type ga_subs_update_hours >/dev/null 2>&1; then hours=$(ga_subs_update_hours 2>/dev/null); [[ "$hours" =~ ^[0-9]+$ ]] || hours=12; fi
    if type ga_subs_update_slow >/dev/null 2>&1; then slow=$(ga_subs_update_slow "$hours" 2>/dev/null) || slow='[]'; fi
    [ -n "$slow" ] || slow='[]'
    # S4-MARGIN (K5-2): подбирается 12–24 (awgkeys.py S4_GEN_RANGE), пакет данных не больше 1280 + 80 + 24 = 1384 — так и
    # сказано; ручной предел 40 (safe_s4) здесь ни при чём. Числа текста сверяет с awgkeys tests/test_s4fix_dryrun.sh.
    log_warning "$(_ui_w "$(tf pr_s4_fix_note "${budget:-1400}" "$(_user_sub_within "$hours" "$slow")")")"
    confirm "$(tf pr_s4_fix_ask "$(_pr_name "$profile")")" || { log_info "$(t cancelled)"; return 1; }
    if [ "$keyless" -gt 0 ]; then
        log_warning "$(_ui_w "$(tf pr_s4_adopted_warn "$(_pr_name "$profile")" "$keyless")")"
        _profile_confirm_phrase "$profile" "$(tf pr_s4_adopted_ask "$(_pr_name "$profile")")" || return 1
        adopted="$profile"
    fi
    GA_S4_FIX_OUT=""
    ga_step "$(tf pr_s4_fixing "$(_pr_name "$profile")")" "$(t pr_s4_fixed)" "" \
        _profile_fix_s4_run "$profile" "$adopted" || return 1
    row=$(jq -r '.summary // empty' <<<"$GA_S4_FIX_OUT" 2>/dev/null) || row=""
    [ -n "$row" ] && log_info "$(_ui_w "$row")"
    while IFS= read -r row; do
        [ -n "$row" ] && echo -e "    • $(_ui_wb "$row")"
    done < <(jq -r '.steps[]?.text // empty' <<<"$GA_S4_FIX_OUT" 2>/dev/null)
    return 0
}

# Шаг под спиннером: ответ ядра — в GA_S4_FIX_OUT (ga_capture пишет в эту же оболочку), а не в выброшенный stdout.
_profile_fix_s4_run() { ga_capture GA_S4_FIX_OUT amnezia_profile_fix_s4 "$@"; }

# Переставить на 2.0 (DUP-LINE-01, решение владельца 15.10): свой профиль, который повторяет линию другого (подхваченной
# 3.1 приложения), — на недостающую линию пары. Что будет — до вопроса; согласие — набором порта профиля, как у
# «Удалить»: профиль удаляется и ставится заново, прежние ключи людей на нём перестают работать. После — кому что
# делать (шаги ядра словами, как у «Исправить S4»). Ключ на новой линии остальным пользователям (у кого его на профиле
# нет) — вопросом до согласия, а выдаёт ядро тем же действием (--keys-to-others, DUPLINE-KEYS-01), как панель и бот.
GA_RELINE_OUT=""
_profile_reline_interactive() {
    local profile="$1" to="$2" n row keys=off rest_n rest_names
    local -a who_rows=()
    type amnezia_profile_reline >/dev/null 2>&1 || { log_error "$(tf module_missing amnezia_profile_reline)"; return 1; }
    n=$(jq -r --arg p "$profile" '[.users[]? | select(((.peers // {})[$p]) != null)] | length' "$USERS_FILE" 2>/dev/null) || n=0
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    if [ "$n" -gt 0 ]; then
        log_warning "$(_ui_w "$(tf pr_reline_note "$(_pr_name "$profile")" "$to" "$(_cfg ".profiles.$profile.port")" "$n")")"
        # У каждого пользователя его действие — до согласия, теми же словами, что итог (ga_amn_reline_preview): подписка
        # обновится сама только у забиравших all.yaml/all.txt приложением (R-1), страницу — открыть заново, ключ — выдать заново.
        # Списка нет (не прочитать пользователей, подписки) — честно: скажу после, а не «Кому что сделать после:» в пустоту (P-5).
        if type ga_amn_reline_preview >/dev/null 2>&1; then
            while IFS= read -r row; do
                [ -n "$row" ] && who_rows+=("$row")
            done < <(ga_amn_reline_preview "$profile" 2>/dev/null | jq -r '.[]?.text // empty' 2>/dev/null)
        fi
        if [ "${#who_rows[@]}" -gt 0 ]; then
            echo -e "  $(t pr_reline_who)"
            for row in "${who_rows[@]}"; do echo -e "    • $(_ui_wb "$row")"; done
        else
            echo -e "  $(_ui_w "$(t pr_reline_who_later)")"
        fi
    else
        log_warning "$(_ui_w "$(tf pr_reline_note0 "$(_pr_name "$profile")" "$to" "$(_cfg ".profiles.$profile.port")")")"
    fi
    rest_n=$(jq -r --arg p "$profile" '[.users[]? | select(((.peers // {})[$p]) == null)] | length' "$USERS_FILE" 2>/dev/null) || rest_n=0
    [[ "$rest_n" =~ ^[0-9]+$ ]] || rest_n=0
    if [ "$rest_n" -gt 0 ] && type users_add_peer >/dev/null 2>&1; then
        if [ "$n" -gt 0 ]; then
            # Порядок — как в итоге ядра, панели и бота: admin первым, остальные по имени (RV-4).
            rest_names=$(jq -c --arg p "$profile" '[.users[]? | select(((.peers // {})[$p]) == null) | .name] | sort_by([(. != "admin"), ascii_downcase])' "$USERS_FILE" 2>/dev/null) || rest_names='[]'
            if type _ga_amn_names >/dev/null 2>&1; then rest_names=$(_ga_amn_names "$rest_names"); else rest_names=$(jq -r 'join(", ")' <<<"$rest_names"); fi
            confirm "$(tf pr_reline_keys_rest_ask "$rest_names" "$to")" && keys=on
        else
            confirm "$(tf pr_reline_keys_all_ask "$rest_n" "$to")" && keys=on
        fi
    fi
    _profile_confirm_phrase "$profile" "$(tf pr_reline_ask "$(_pr_name "$profile")" "$to")" || return 1
    GA_RELINE_OUT=""
    GA_ERR_MSG=""
    if ! GA_STEP_NO_ERRHEAD=1 ga_step "$(tf pr_relining "$(_pr_name "$profile")" "$to")" "$(t pr_relined)" "$(t eta_profile)" \
            _profile_reline_run "$profile" "$to" "$keys"; then
        # Итог ядра — что вернули, кому выданы ключи, кому выдать, что поднять — последней строкой stderr, а шаг
        # показывает только первые строки: говорим его целиком (находка проверки 15.10).
        [ -n "${GA_ERR_MSG:-}" ] && log_error "$(_ui_w "$GA_ERR_MSG")"
        return 1
    fi
    row=$(jq -r '.summary // empty' <<<"$GA_RELINE_OUT" 2>/dev/null) || row=""
    [ -n "$row" ] && log_info "$(_ui_w "$row")"
    while IFS= read -r row; do
        [ -n "$row" ] && echo -e "    • $(_ui_wb "$row")"
    done < <(jq -r '.steps[]?.text // empty' <<<"$GA_RELINE_OUT" 2>/dev/null)
    # Ключ остальным отложили — где выдать потом (выдали — шаг ядра «others» выше).
    [ "$rest_n" -gt 0 ] && [ "$keys" != on ] && log_dim "$(t pr_keys_all_later)"
    return 0
}
_profile_reline_run() { ga_capture GA_RELINE_OUT amnezia_profile_reline "$@"; }

# _dupline_notice_once — сообщение «Ошибка прошлых версий» в SSH один раз (после «Что нового», решение владельца
# 15.10): что случилось, что сделает исправление и кому что придётся сделать; «1) Исправить» — «Переставить на 2.0»
# с тем же согласием и итогом, «2) Позже» — дальше строкой в шапке, пока не исправлено.
_dupline_notice_once() {
    local dfx p l ch
    type ga_amn_dupline_fix_json >/dev/null 2>&1 || return 0
    [ -t 0 ] || return 0
    [ "$(_cfg '.dupline_bug.ssh_shown')" = true ] && return 0
    dfx=$(ga_amn_dupline_fix_json 2>/dev/null) || return 0
    [ -n "$dfx" ] && [ "$dfx" != null ] || return 0
    p=$(jq -r '.profile' <<<"$dfx"); l=$(jq -r '.line' <<<"$dfx")
    ga_config_merge '{"dupline_bug": {"ssh_shown": true}}' >/dev/null 2>&1 || true
    echo ""
    echo -e "  ${BOLD}${YELLOW}$(t dupline_title)${NC}"
    echo -e "  ${DIM}$(_rule)${NC}"
    echo -e "  $(ga_wrap "$(jq -r '.text' <<<"$dfx")" "${GA_UI_W:-76}" 2)"
    echo -e "  ${DIM}$(_rule)${NC}"
    echo -e "  ${CYAN}1${NC}) $(tf dupline_fix_item "$(_pr_name "$p")" "$l")"
    echo -e "  ${CYAN}2${NC}) $(t dupline_later)"
    echo -ne "  ${WHITE}$(t choose):${NC} "
    read -r ch || ch=2
    case "$ch" in
        1)
            # Отменили набор порта или перестановка сорвалась — экран больше не покажется (ssh_shown), поэтому где
            # исправить потом — и здесь, а не только у «Позже» (R-4 проверки 15.10).
            if ! _profile_reline_interactive "$p" "$l"; then
                dfx=$(ga_amn_dupline_fix_json 2>/dev/null) || dfx=null
                [ -n "$dfx" ] && [ "$dfx" != null ] && log_info "$(_ui_w "$(tf dupline_retry_note "$(_pr_name "$p")")")"
            fi
            _pause ;;
        *) log_info "$(_ui_w "$(t dupline_later_note)")" ;;
    esac
    return 0
}

# ── Пересечение подсетей профилей (SUBNET-01) ────────────────────────────────
# Приложение Amnezia ставит все свои контейнеры AmneziaWG на 10.8.1.0/24, и подхват берёт их как есть: у двух
# профилей может оказаться одна подсеть. Экраны говорят это прямо и ведут к выходу — перенести на свободную подсеть
# тот профиль, которому смена разрешена (ядро выбирает его и подсеть: ga_amn_subnet_overlaps), человеку остаётся
# подтвердить.

# _subnet_overlap_of <профиль> → запись пересечения этого профиля (JSON); код 1 — пересечения нет.
_subnet_overlap_of() {
    local e
    type ga_amn_subnet_overlap_of >/dev/null 2>&1 || return 1
    e=$(ga_amn_subnet_overlap_of "$1" 2>/dev/null) || return 1
    [ -n "$e" ] && [ "$e" != null ] || return 1
    printf '%s' "$e"
}

# _subnet_overlaps_note — все пересечения подсетей строками предупреждения, по одной на выход (кого переносить):
# итог подхвата в мастере, сводка Ленивого Pro.
_subnet_overlaps_note() {
    local js e mp told=" "
    type ga_amn_subnet_overlaps >/dev/null 2>&1 || return 0
    js=$(ga_amn_subnet_overlaps 2>/dev/null) || return 0
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        mp=$(jq -r '.move.profile // .profile' <<<"$e" 2>/dev/null)
        case "$told" in *" $mp "*) continue ;; esac
        told+="$mp "
        log_warning "$(_ui_w "$(ga_amn_subnet_overlap_text "$e")")"
    done < <(jq -c '.[]? | select(.move == null or .move.profile == .profile)' <<<"$js" 2>/dev/null)
    return 0
}

# _subnet_move_offer <профиль> <подсеть> [go] — выход из пересечения: перевести профиль на свободную подсеть, которую
# подставило ядро. go — согласие уже спрошено. У профиля с людьми приложения без ключа на сервере — ещё и набор порта
# профиля (их ключи с прежним адресом перестанут проходить, переслать новые нечем — как у переноса порта, ACC-2).
_subnet_move_offer() {
    local p="$1" cidr="$2" go="${3:-}" n adopted="" cur
    type amnezia_profile_set_subnet >/dev/null 2>&1 || { log_error "$(tf module_missing amnezia_profile_set_subnet)"; return 1; }
    if [ "$go" != go ]; then
        log_warning "$(_ui_w "$(t pr_subnet_warn)")"
        confirm "$(tf pr_subnet_move_ask "$(_pr_name "$p")" "$cidr")" || { log_info "$(t cancelled)"; return 1; }
    fi
    n=$(_profile_keyless "$p")
    if [ "$n" -gt 0 ]; then
        cur=$(_cfg ".profiles.$p.subnet"); [ -n "$cur" ] || cur="-"
        log_warning "$(_ui_w "$(tf pr_subnet_adopted_warn "$(_pr_name "$p")" "$n" "$cur" "$cidr")")"
        _profile_confirm_phrase "$p" "$(tf pr_subnet_adopted_ask "$(_pr_name "$p")" "$cidr")" || return 1
        adopted="$p"
    fi
    ga_step "$(tf pr_subnet_changing "$(_pr_name "$p")" "$cidr")" "$(tf pr_subnet_changed "$(_pr_name "$p")" "$cidr")" "" \
        amnezia_profile_set_subnet "$p" "$cidr" "$adopted"
}

# Смена подсети перенумеровывает пиров: ключ остаётся, но адрес в нём другой —
# всем пользователям профиля придётся импортировать конфиг заново.
# Подхваченному старому контейнеру (wg0) подсеть не сменить — это говорится сразу, а не после набранной подсети, и
# если его подсеть пересекается с другим профилем, предлагается выход: перенести тот (SUBNET-01). Пересекается подсеть
# этого профиля — Enter берёт свободную, которую подставило ядро.
_profile_set_subnet_interactive() {
    local profile="$1" cidr e="" mp="" mfree="" def="" n adopted=""
    type amnezia_profile_set_subnet >/dev/null 2>&1 || { log_error "$(tf module_missing amnezia_profile_set_subnet)"; return 1; }
    local cur; cur=$(_cfg ".profiles.$profile.subnet"); [ -n "$cur" ] || cur="-"
    if e=$(_subnet_overlap_of "$profile"); then
        mp=$(jq -r '.move.profile // empty' <<<"$e" 2>/dev/null)
        mfree=$(jq -r '.move.subnet // empty' <<<"$e" 2>/dev/null)
    else
        e=""
    fi
    if type ga_amn_subnet_fixed >/dev/null 2>&1 && ga_amn_subnet_fixed "$profile"; then
        log_warning "$(_ui_w "$(ga_amn_subnet_legacy_msg "$profile" "$(ga_amn_iface "$profile")")")"
        [ -n "$mp" ] && [ -n "$mfree" ] && [ "$mp" != "$profile" ] || return 1
        _subnet_move_offer "$mp" "$mfree"
        return $?
    fi
    if [ -n "$e" ]; then
        log_warning "$(_ui_w "$(ga_amn_subnet_overlap_text "$e")")"
        # Ядро советует перенести соседа (у него меньше людей с ключами из приложения или он поставлен позже) —
        # предложить это первым; «нет» — сменить подсеть этому профилю.
        if [ -n "$mp" ] && [ "$mp" != "$profile" ] && [ -n "$mfree" ]; then
            log_warning "$(_ui_w "$(t pr_subnet_warn)")"
            if confirm "$(tf pr_subnet_move_other_ask "$(_pr_name "$mp")" "$mfree")"; then
                _subnet_move_offer "$mp" "$mfree" go
                return $?
            fi
            [ "${GA_INPUT_EOF:-0}" = 1 ] && { log_info "$(t cancelled)"; return 1; }
        fi
        if [ "$mp" = "$profile" ] && [ -n "$mfree" ]; then
            def="$mfree"
        else
            def=$(ga_amn_pick_subnet "$profile" 2>/dev/null) || def=""
        fi
    fi
    # «0 — назад» — шаг назад без «Отменено.» и лишнего «Нажмите Enter» (A-13); три промаха — по-прежнему отмена.
    local arc=0
    if [ -n "$def" ]; then
        cidr=$(ga_ask "$(tf pr_ask_subnet_free "$cur" "$def")" '^(10|172|192)\.[0-9]{1,3}\.[0-9]{1,3}\.0/2[0-4]$' \
            "$(t pr_bad_subnet)" "$def") || arc=$?
    else
        cidr=$(ga_ask "$(tf pr_ask_subnet_cur "$cur")" '^(10|172|192)\.[0-9]{1,3}\.[0-9]{1,3}\.0/2[0-4]$' "$(t pr_bad_subnet)") \
            || arc=$?
    fi
    [ "$arc" = 1 ] && { GA_BACK=1; return 0; }
    [ "$arc" = 0 ] || { log_info "$(t cancelled)"; return 1; }
    log_warning "$(t pr_subnet_warn)"
    confirm "$(tf pr_ask_subnet_confirm "$cidr")" || { log_info "$(t cancelled)"; return 1; }
    # Люди приложения Amnezia без ключа на сервере: их ключ с прежним адресом перестанет проходить — набор порта
    # профиля, как у переноса порта (ACC-2); без него модуль откажет adopted_keyless.
    n=$(_profile_keyless "$profile")
    if [ "$n" -gt 0 ]; then
        log_warning "$(_ui_w "$(tf pr_subnet_adopted_warn "$(_pr_name "$profile")" "$n" "$cur" "$cidr")")"
        _profile_confirm_phrase "$profile" "$(tf pr_subnet_adopted_ask "$(_pr_name "$profile")" "$cidr")" || return 1
        adopted="$profile"
    fi
    ga_step "$(tf pr_subnet_changing "$(_pr_name "$profile")" "$cidr")" "$(tf pr_subnet_changed "$(_pr_name "$profile")" "$cidr")" "" \
        amnezia_profile_set_subnet "$profile" "$cidr" "$adopted"
}

# Спросить порт с проверкой занятости. Печатает порт в stdout (вызов через $()).
#
# Раньше одна опечатка отменяла вопрос, а вызывающий молча подставлял СЛУЧАЙНЫЙ
# порт — человек был уверен, что поставил 51820, а получал 7431 и не понимал,
# почему ключ не подключается (замечание критика). Теперь три попытки с
# переспросом, а после третьей — вслух сказанное «оставляю предложенный порт».
#
# Третий аргумент — НЫНЕШНИЙ порт профиля, когда порт меняют. Его надо
# отвергать своими словами: он занят нашим же контейнером, и общее «порт занят»
# отправляло человека искать чужой процесс, которого нет.
_ask_port() {
    local profile="$1" suggested="$2" current="${3:-}" port i
    [ -n "$suggested" ] || suggested=$(_random_port)
    for ((i = 0; i < 3; i++)); do
        echo -ne "  $(ga_win_wrap "${WHITE}$(tf pr_ask_port "$(_pr_name "${profile}")" "$suggested"):${NC}" 2) " >&2
        if ! read -r port; then echo "" >&2; port=0; fi
        # «0» — выход, как во всём меню. Прежде ноль не проходил проверку порта,
        # человек получал три «Порт должен быть числом» подряд, а после третьего
        # промаха помощник ПОДСТАВЛЯЛ предложенный случайный порт и выводил на
        # вопрос «перенести профиль на 4630?» — то есть попытка выйти
        # заканчивалась предложением переехать неизвестно куда.
        [ "$port" = 0 ] && { log_info "$(t cancelled)" >&2; return 1; }
        [ -n "$port" ] || port="$suggested"
        if type validate_port >/dev/null 2>&1; then
            validate_port "$port" || { log_error "$(t pr_bad_port)"; continue; }
        elif ! [[ "$port" =~ ^[0-9]{2,5}$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            log_error "$(t pr_bad_port)"; continue
        fi
        # «0443» — это 443: как строка он обходил сравнение с нынешним портом и
        # запрет на повтор, а Docker потом отказывал (замечание критика).
        port=$((10#$port))
        if [ -n "$current" ] && [ "$port" = "$current" ]; then
            log_error "$(tf pr_port_same "$port")"; continue
        fi
        # Занятость спрашиваем у модуля: он ОДИН знает, что порт соседнего
        # профиля из config.json тоже занят, и умеет не считать занятым свой
        # собственный (ga_amn_port_check исключает профиль, для которого
        # спрашивают). Меню этим не пользовалось и проверяло только сокеты.
        if type ga_amn_port_check >/dev/null 2>&1; then
            GA_ERR_CODE=""; GA_ERR_MSG=""
            if ! ga_amn_port_check "$profile" "$port" 2>/dev/null; then
                log_error "${GA_ERR_MSG:-$(tf pr_port_busy "$port")}"; continue
            fi
        elif ! _port_free "$port" udp; then
            log_error "$(tf pr_port_busy "$port")"; continue
        fi
        printf '%s' "$port"
        return 0
    done
    # Три промаха — отмена, а не чужое значение: подстановка случайного порта
    # означала бы перенос профиля туда, куда человек не просил.
    log_warning "$(t pr_port_giveup)" >&2
    return 1
}

# Спросить TCP-порт доступа агентов. Печатает порт в stdout (вызов через $()),
# весь UI — в stderr.
#
# Одна опечатка выбрасывала из сценария целиком: человек, набравший «433» вместо
# «4433», терял и название, и уровень, и срок — всё, что успел ответить, — и шёл
# искать пункт меню заново. Переспрашиваем трижды, как `_ask_port` у порта
# профиля и `ga_ask` у остальных вопросов, а после третьей неудачи вслух говорим,
# на чём остановились: молчаливая подстановка и была бы тем самым сюрпризом.
# Пустой ввод — законный ответ: «предложенный порт» там, где он предложен, и
# «без отдельного порта» там, где его нет.
_ask_agent_port() {
    local prompt="$1" suggested="${2:-}" port i
    for ((i = 0; i < 3; i++)); do
        echo -ne "  ${WHITE}${prompt}:${NC} " >&2
        if ! read -r port; then echo "" >&2; port=""; fi
        [ -n "$port" ] || port="$suggested"
        [ -n "$port" ] || return 0
        if [[ "$port" =~ ^[0-9]{4,5}$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; then
            printf '%s' "$port"
            return 0
        fi
        log_error "$(t ag_bad_port)"
    done
    if [ -n "$suggested" ]; then
        log_warning "$(tf pr_port_fallback "$suggested")"
        printf '%s' "$suggested"
    else
        log_warning "$(t ag_port_fallback_none)"
    fi
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# Раздел 4: Обслуживание
# ══════════════════════════════════════════════════════════════════════════════

submenu_maintenance() {
    local ch
    while true; do
        _screen_head "$(t menu_maintenance)"
        echo -e "  ${CYAN}1${NC}) $(t mt_restart_all)"
        echo -e "  ${CYAN}2${NC}) $(t mt_backup)"
        echo -e "  ${CYAN}3${NC}) $(t mt_restore)"
        echo -e "  ${CYAN}4${NC}) $(t mt_upstream)"
        echo -e "  ${CYAN}5${NC}) $(t mt_import)"
        echo -e "  ${CYAN}6${NC}) $(t mt_selfupdate)"
        echo -e "  ${CYAN}7${NC}) $(t mt_diag)"
        echo -e "  ${CYAN}8${NC}) $(t mt_docker_restart)"
        echo -e "  ${CYAN}9${NC}) $(t mt_kmod)"
        echo -e "  ${CYAN}0${NC}) $(t back)"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0

        case "$ch" in
            1) _restart_everything ;;
            2) _backup_screen ;;
            3) _restore_interactive ;;
            4) _upstream_screen ;;
            5) _import_scan_screen ;;
            6) _selfupdate_screen ;;
            7) _diagnose_screen ;;
            8) _docker_restart_screen ;;
            # Модуль ядра AmneziaWG по выбору (lib/kmod.sh, KMOD_PLAN этап Б)
            9) if type ga_kmod_screen >/dev/null 2>&1; then ga_kmod_screen; else log_error "$(tf module_missing ga_kmod_screen)"; fi ;;
            0) GA_BACK=1; break ;;
            "") continue ;;
            *) log_error "$(t invalid_choice)" ;;
        esac

        _pause
    done
}

# ── Обслуживание → Бэкап ─────────────────────────────────────────────────────
# Пункт делал ровно одно: снимал копию. При этом расписание менять было нечем
# (set_backup_schedule звалась только из первой установки), а строка словаря
# обещала «настраивается в Обслуживание → Бэкап»; и ни один экран продукта не
# отвечал на вопрос «когда была последняя копия», хотя восстановление из копии
# продукт советует при каждой беде.
_backup_screen() {
    local ch
    while true; do
        _screen_head "$(t mt_backup)" "$(t mt_backup_note)"
        _backup_last_line
        _backup_schedule_line
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -e "  ${CYAN}1${NC}) $(t mt_backup_now)"
        echo -e "  ${CYAN}2${NC}) $(t mt_backup_schedule)"
        echo -e "  ${CYAN}0${NC}) $(t back)"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0
        case "$ch" in
            1)
                if type create_backup >/dev/null 2>&1; then
                    ga_step "$(t mt_backup)" "$(t mt_backup_done)" "" create_backup && _backup_where
                else
                    log_error "$(tf module_missing create_backup)"
                fi
                _pause
                ;;
            2) _backup_schedule_interactive; _pause ;;
            0) GA_BACK=1; return 0 ;;
            "") continue ;;
            *) log_error "$(t invalid_choice)"; _pause ;;
        esac
    done
}

# Где лежит копия и как её унести: копия на той же машине, которую она должна пережить, а
# путь и команда скачивания нигде не назывались (находка критика UX, 25.09.2026).
_backup_where() {
    local js name size path ip
    type backup_last_json >/dev/null 2>&1 || return 0
    js=$(backup_last_json 2>/dev/null) || return 0
    name=$(printf '%s' "$js" | jq -r '.name // ""' 2>/dev/null) || name=""
    [ -n "$name" ] || return 0
    size=$(printf '%s' "$js" | jq -r '.size // 0' 2>/dev/null) || size=0
    path="$BACKUP_DIR/$name"
    ip=$(_ssh_inbound_ip 2>/dev/null) || ip=""
    [ -n "$ip" ] || ip=$(_server_ip)
    # Порт SSH — из SSH_CONNECTION (четвёртое поле — порт сервера): на нестандартном порту
    # команда без -P не соединялась (находка SR-55).
    local sport="" popt=""
    read -r _ _ _ sport _ <<<"${SSH_CONNECTION:-}"
    [[ "$sport" =~ ^[0-9]{1,5}$ ]] && [ "$sport" != 22 ] && popt="-P $sport "
    echo -e "  $(tf mt_backup_where "$path" "$(_human_bytes "${size:-0}")")"
    echo -e "  ${DIM}$(ga_win_wrap "$(t mt_backup_download)" 2)${NC}"
    echo -e "    ${CYAN}scp ${popt}root@${ip:-<server_ip>}:${path} .${NC}"
    echo -e "  ${DIM}$(ga_win_wrap "$(t mt_backup_move_hint)" 2)${NC}"
}

# «Когда была последняя копия» — одной строкой. Отдельно: чем кончился
# последний НОЧНОЙ проход. Копия могла молча умереть навсегда, и узнавали об
# этом в день, когда она понадобилась.
_backup_last_line() {
    local js name created count ok code at
    if ! type backup_last_json >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        return 0
    fi
    ga_capture js backup_last_json || js=""
    printf '%s' "$js" | jq -e . >/dev/null 2>&1 || return 0
    name=$(printf '%s' "$js" | jq -r '.name // ""')
    created=$(printf '%s' "$js" | jq -r '.created // ""')
    count=$(printf '%s' "$js" | jq -r '.count // 0')
    if [ -z "$name" ]; then
        echo -e "  ${YELLOW}$(t backup_last_never)${NC}"
    else
        echo -e "  $(tf backup_last_line "$(ga_human_ts "${created:0:19}")" "$name" "$count")"
    fi
    # НЕ `.tick_ok // ""`: в jq двойной слэш отбрасывает и `false`, поэтому
    # провалившийся ночной проход превращался в «неизвестно» и красная строка
    # ниже не печаталась НИКОГДА. Экран заводился ровно чтобы показывать, чем
    # кончилась последняя копия, и показывал благополучие, пока копии умирали.
    ok=$(printf '%s' "$js" | jq -r 'if (.tick_ok|type) == "boolean" then (.tick_ok|tostring) else "" end')
    if [ "$ok" = "false" ]; then
        code=$(printf '%s' "$js" | jq -r '.tick_code // ""')
        at=$(printf '%s' "$js" | jq -r '.tick_at // ""')
        log_error "$(tf backup_last_tick_failed "${at:0:19}" "${code:--}")"
    fi
}

_backup_schedule_line() {
    local st freq
    type backup_schedule_status >/dev/null 2>&1 || return 0
    st=$(backup_schedule_status 2>/dev/null) || st=""
    freq="${st#frequency=}"; freq="${freq%% *}"
    [ -n "$freq" ] || freq=off
    echo -e "  $(t mt_backup_schedule): ${CYAN}$(_backup_freq_name "$freq")${NC}"
}

# Имя периодичности словами. case, а не подстановка в имя ключа: так
# tests/check_i18n_ssh.py видит каждый ключ и проверяет оба языка.
_backup_freq_name() {
    case "${1:-off}" in
        daily)   t mt_backup_freq_daily ;;
        weekly)  t mt_backup_freq_weekly ;;
        monthly) t mt_backup_freq_monthly ;;
        *)       t mt_backup_freq_off ;;
    esac
}

_backup_schedule_interactive() {
    local ch freq
    type set_backup_schedule >/dev/null 2>&1 || { log_error "$(tf module_missing set_backup_schedule)"; return 1; }
    echo ""
    echo -e "  ${BOLD}${WHITE}$(t mt_backup_schedule)${NC}"
    echo -e "  ${CYAN}1${NC}) $(t mt_backup_freq_daily)"
    echo -e "  ${CYAN}2${NC}) $(t mt_backup_freq_weekly)"
    echo -e "  ${CYAN}3${NC}) $(t mt_backup_freq_monthly)"
    echo -e "  ${CYAN}4${NC}) $(t mt_backup_freq_off)"
    echo -e "  ${CYAN}0${NC}) $(t back)"
    # rc 1 у ga_ask — «0» (назад): без лишнего «Нажмите Enter» (SR-55)
    ch=$(ga_ask "$(t choose)" '^[0-4]$' "$(t invalid_choice)") || { [ $? = 1 ] && GA_BACK=1; return 1; }
    case "$ch" in
        1) freq=daily ;; 2) freq=weekly ;; 3) freq=monthly ;; 4) freq=off ;;
        *) log_info "$(t cancelled)"; return 1 ;;
    esac
    # Выключение расписания — это отказ от единственной автоматической
    # страховки продукта, поэтому спрашиваем отдельно.
    if [ "$freq" = off ]; then
        log_warning "$(t mt_backup_off_warn)"
        confirm "$(t mt_backup_off_ask)" || { log_info "$(t cancelled)"; return 1; }
    fi
    set_backup_schedule "$freq" >/dev/null || { log_error "${GA_ERR_MSG:-$(tf backup_schedule_bad "$freq")}"; return 1; }
    return 0
}

# Человеческое имя юнита. Одно место на весь продукт: «goamnezia-bot.service» —
# это для journalctl, а человеку в списке нужен «Telegram-бот».
_unit_label() {
    case "$1" in
        goamnezia-bot.service)      printf '%s' "$(t bot_title)" ;;
        goamnezia-admin.service)    printf '%s' "$(t pn_title)" ;;
        goamnezia-mcp-http.service) printf '%s' "$(t unit_mcp_http)" ;;
        goamnezia-pages.service)    printf '%s' "$(t unit_pages)" ;;
        nginx|nginx.service)        printf '%s' "nginx" ;;
        *)                          printf '%s' "$1" ;;
    esac
}

# Перезапуск всего рвёт связь каждому подключённому — и делался без единого
# вопроса (замечание критика). Сначала показываем, что именно будет перезапущено.
_restart_everything() {
    local p unit list nprof=0
    local -a plan=()
    for p in $PROFILE_IDS; do
        _profile_installed "$p" || continue
        plan+=("$(_pr_name "${p}")")
        nprof=$((nprof + 1))
    done
    # Список обязан совпадать с тем, что ниже действительно перезапускается: в
    # предупреждении стояли две службы из четырёх, а имена юнитов были свалены
    # вперемешку с человеческими названиями (DEFECTS §3.12).
    for unit in goamnezia-bot.service goamnezia-admin.service goamnezia-mcp-http.service goamnezia-pages.service nginx; do
        _svc_probe cat "$unit" >/dev/null && plan+=("$(_unit_label "$unit")")
    done
    if [ "${#plan[@]}" -eq 0 ]; then
        log_info "$(t mt_restart_nothing)"; return 0
    fi
    # Запятая с пробелом: «${plan[*]}» склеивает ПЕРВЫМ знаком IFS, и «IFS=', '»
    # давал «awg3,awg2» без пробела.
    list=$(printf '%s, ' "${plan[@]}"); list="${list%, }"
    log_warning "$(_ui_w "$(tf mt_restart_all_warn "$list")")"
    confirm "$(t mt_restart_all_ask)" || { log_info "$(t cancelled)"; return 1; }
    # Счётчик «Шаг i из N» считает ВСЁ, что будет сделано. Он считал одни
    # профили, и «Шаг 2 из 2» читалось как «готово», после чего шли ещё четыре
    # службы (DEFECTS §4.2).
    GA_STEP_N="${#plan[@]}"; GA_STEP_I=0
    for p in $PROFILE_IDS; do
        _profile_installed "$p" || continue
        type amnezia_profile_restart >/dev/null 2>&1 || break
        ga_step "$(tf pr_restarting "$(_pr_name "$p")")" "$(tf pr_restarted "$(_pr_name "$p")")" "" amnezia_profile_restart "$p"
    done
    # Транспорт агентов и nginx — такие же составляющие продукта, как бот и
    # панель: без них не работают доступы MCP и сайт на 443. Их отсутствие в
    # списке означало, что «перезапустить всё» перезапускало не всё.
    #
    # И отказ обязан быть ВИДЕН: экран без единой красной строки раньше означал
    # и «перезапустилось», и «не смогло» (docs/DEFECTS.md §1c.10).
    local label
    for unit in goamnezia-bot.service goamnezia-admin.service goamnezia-mcp-http.service goamnezia-pages.service nginx; do
        _svc_probe cat "$unit" >/dev/null || continue
        label=$(_unit_label "$unit")
        if _svc_do restart "$unit"; then
            ga_step_done "$(tf mt_unit_restarted "$label")"
        else
            GA_STEP_I=$(( GA_STEP_I + 1 ))
            log_error "$(tf mt_unit_restart_failed "$label" "$unit")"
        fi
    done
    GA_STEP_N=0
    _dash_snapshot force
}

# ── Обслуживание → Перезапустить Docker (DK-02) ──────────────────────────────
# Служба Docker целиком: пакет обновлён, а служба старая (сторож сделает это сам, когда к VPN никто не подключён, —
# здесь сразу), или Docker ведёт себя странно. Что сейчас со службой — до вопроса: свежую перезапускать не обязательно.
# Сам перезапуск — тем же путём, что у моста docker-restart (amnezia_docker_restart): служба, затем каждый профиль —
# интерфейс, порт, изоляция, соседи, goWARP.
_docker_restart_screen() {
    local js="" rc=0 p name code why
    _screen_head "$(t mt_docker_restart)" "$(t mt_docker_restart_note)"
    if ! type amnezia_docker_restart >/dev/null 2>&1; then
        log_error "$(tf module_missing amnezia_docker_restart)"; return 1
    fi
    # Сведения — свежие: служба могла смениться, пока меню открыто.
    docker_stale_reset
    if docker_stale_probe; then
        # При одной версии — сборки (docker_label): «29.1.3 → 29.1.3» человеку ничего не скажет.
        name=$(docker_label "$GA_DOCKER_BIN_VER" "$GA_DOCKER_BIN_BUILD" "$GA_DOCKER_DAEMON_VER")
        why=$(docker_label "$GA_DOCKER_DAEMON_VER" "$GA_DOCKER_DAEMON_BUILD" "$GA_DOCKER_BIN_VER")
        log_warning "$(_ui_w "$(tf mt_docker_stale_now "${name:-${GA_DOCKER_API_CLIENT:-?}}" "${why:-${GA_DOCKER_API_DAEMON:-?}}")")"
    elif [ -n "$GA_DOCKER_DAEMON_VER" ]; then
        log_dim "$(_ui_w "$(tf mt_docker_fresh "$GA_DOCKER_DAEMON_VER")")"
    fi
    log_warning "$(_ui_w "$(t mt_docker_restart_warn)")"
    confirm "$(t mt_docker_restart_ask)" || { log_info "$(t cancelled)"; return 1; }
    GA_ERR_CODE=""; GA_ERR_MSG=""
    ga_step "$(t mt_docker_restarting)" "$(t mt_docker_restarting_done)" "" ga_capture js amnezia_docker_restart manual || rc=$?
    if [ "$rc" = 0 ]; then
        log_success "$(tf mt_docker_done "$(_json_field "$js" .duration_s)" "$(_json_field "$js" ".daemon_after_label // .daemon_after")")"
    else
        [ -n "$GA_ERR_MSG" ] && log_error "$(_ui_w "$GA_ERR_MSG")"
        log_dim "$(_ui_w "$(t mt_docker_manual)")"
    fi
    # По профилям — что поднялось, а что нет и почему (код и слова модуля).
    for p in $(_json_field "$js" '.restarted[]?'); do
        log_success "$(tf pr_restarted "$(_pr_name "${p}")")"
    done
    while IFS=$'\x1f' read -r p code why; do
        [ -n "$p" ] || continue
        name=$(_pr_name "${p}")
        log_error "$(_ui_w "$name — ${why:-$code}")"
    done < <(printf '%s' "$js" | jq -r '.failed[]? | [.profile, .code, .message] | join("\u001f")' 2>/dev/null)
    _dash_snapshot force
    return "$rc"
}

# _read_secret_tty <переменная> — строка без эха с управляющего терминала, по договору confirm (lib/common.sh):
# через `curl | bash` stdin занят телом скрипта. `read … </dev/tty 2>/dev/null` не гасил неудачу самого
# ПЕРЕНАПРАВЛЕНИЯ — перенаправления разбираются слева направо, и без управляющего терминала (setsid, cron,
# юнит) человек видел сырое «/dev/tty: No such device or address», а набранный ключ оставался в очереди и
# уходил ответом на следующий вопрос (находка L2-05). Скобки гасят и её; не открылся терминал — читаем stdin,
# только если он сам терминал; из конвейера ключа не берём.
_read_secret_tty() {
    local __v=""
    if ! { IFS= read -rs __v </dev/tty; } 2>/dev/null; then
        if [ -t 0 ]; then IFS= read -rs __v || __v=""; else __v=""; fi
    fi
    printf -v "$1" '%s' "$__v"
}

# ── Обновить goAmnezia ───────────────────────────────────────────────────────
# Пункт был заглушкой с подсказкой «запустите однострочник руками». Теперь он
# делает то, что обещает: берёт из .install-source (его пишет bootstrap.sh)
# репозиторий и ветку, из которых сервер поставлен, и повторяет установку.
# Токен доступа НЕ хранится нигде на диске — приватный репозиторий требует его
# на каждый запуск, поэтому спрашиваем (или берём из GOAMNEZIA_PAT).
#
# Веток две, как у всей серии (goinstaller-ready §2): main — стабильная, dev — экспериментальная, и переезд
# установленного между ними — главный сценарий. Раньше экран молча подменял main на dev (main убрали 13.09.2026):
# человек со стабильной ветки уезжал на экспериментальную. Теперь ветку выбирают — по умолчанию ту, откуда
# сервер поставлен, — экран узнаёт у GitHub коммит её головы и версию в нём, называет, обновление это или откат,
# и запускает загрузчик ИМЕННО ЭТОГО коммита.
_install_source_field() {
    local key="$1" f="$SCRIPT_DIR/.install-source" v=""
    [ -f "$f" ] || return 1
    v=$(grep -E "^${key}=" "$f" 2>/dev/null | head -1) || v=""
    v="${v#*=}"
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

# Имя ветки и репозитория уходят в адреса GitHub вместе с ключом владельца: из .install-source берём только
# похожее на них (то же правило, что у имени ветки в bootstrap.sh).
_su_branch_ok() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$ ]] && [[ "$1" != *..* ]]; }
_su_repo_ok()   { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}/[A-Za-z0-9._-]{1,100}$ ]] && [[ "$1" != *..* ]]; }

# _su_get <ключ> <адрес> <файл> [Accept] — скачать из приватного репозитория; stdout — код ответа HTTP («000» —
# сеть не ответила). Заголовок с ключом — в stdin curl (-K -, настройки), а не в аргументах: argv виден любому
# локальному пользователю в /proc/*/cmdline (то же правило, что у токена бота в _bot_install_interactive).
_su_get() {
    local pat="$1" url="$2" out="$3" accept="${4:-}" code=""
    code=$( { printf 'header = "Authorization: token %s"\n' "$pat"
              if [ -n "$accept" ]; then printf 'header = "Accept: %s"\n' "$accept"; fi
            } | curl -sSL --max-time 60 -K - -o "$out" -w '%{http_code}' "$url" 2>/dev/null ) || code=""
    [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
    printf '%s' "$code"
}

# _su_head_sha <ключ> <репозиторий> <ветка> — stdout: SHA головы ветки (тип ответа application/vnd.github.sha —
# голые 40 знаков, а не JSON всего коммита). rc: 0 — узнали; 2 — такой ветки нет (API: 422 «No commit found»);
# 3 — репозиторий не отдаёт (401/404: ключ не тот или нет доступа); 1 — API не ответил (сеть, лимит, 5xx).
_su_head_sha() {
    local tmp code body="" re='"sha"[[:space:]]*:[[:space:]]*"([0-9a-f]{40})"'
    tmp=$(mktemp "${TMPDIR:-/tmp}/goamnezia-su.XXXXXX" 2>/dev/null) || return 1
    code=$(_su_get "$1" "https://api.github.com/repos/$2/commits/$3" "$tmp" "application/vnd.github.sha")
    body=$(head -c 65536 "$tmp" 2>/dev/null) || body=""
    rm -f "$tmp"
    case "$code" in
        200)     ;;
        422)     return 2 ;;
        401|404) return 3 ;;
        *)       return 1 ;;
    esac
    if [[ "$body" =~ ^[[:space:]]*([0-9a-f]{40})[[:space:]]*$ ]] || [[ "$body" =~ $re ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# _su_remote_version <ключ> <репозиторий> <коммит или ветка> — stdout: GOAMNEZIA_VERSION из lib/common.sh там
# (правило серии: присваивание в начале строки, значение с цифры — goinstaller-ready §1).
_su_remote_version() {
    local tmp code v=""
    tmp=$(mktemp "${TMPDIR:-/tmp}/goamnezia-su.XXXXXX" 2>/dev/null) || return 1
    code=$(_su_get "$1" "https://raw.githubusercontent.com/$2/$3/lib/common.sh" "$tmp")
    if [ "$code" = 200 ]; then
        v=$(sed -n -E 's/^GOAMNEZIA_VERSION="([0-9][0-9A-Za-z.+-]*)".*/\1/p' "$tmp" 2>/dev/null) || v=""
    fi
    rm -f "$tmp"
    v="${v%%$'\n'*}"
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

# _su_ask_pat <переменная> — ключ доступа к закрытому репозиторию (решение владельца 28.09: репозиторий остаётся
# закрытым, установка и обновление — по ключу). Сначала — что это за ключ и откуда он у человека: голое «Ключ доступа
# к репозиторию» путало (находка NC-20 критика-новичка), — потом ввод без эха. Ключ нигде не сохраняется и не
# печатается: живёт в переменной вызывающего, уходит только в stdin curl (_su_get) и в окружение загрузчика.
_su_ask_pat() {
    echo -e "  ${DIM}$(_ui_w "$(t mt_su_pat_why)")${NC}" >&2
    echo -ne "  ${WHITE}$(t mt_selfupdate_ask_pat):${NC} " >&2
    _read_secret_tty "$1"
    echo "" >&2
}

# _selfupdate_exec <файл загрузчика> — передать ему управление.
# exec, а НЕ обычный вызов: загрузчик заканчивается запуском новой версии,
# и без exec она поднималась вложенной сессией ВНУТРИ старой. Человек видел
# второй баннер, работал в новом меню, выходил «0» — и попадал обратно в
# старый процесс со старыми модулями в памяти, уже после того как новая
# версия прогнала миграцию состояния. Отличить одно от другого по экрану
# нельзя (docs/DEFECTS.md §1c.6).
#
# Файл-времянку открываем на чтение и сразу удаляем, а новая оболочка читает загрузчик из открытого
# дескриптора: прежняя ловушка EXIT не переживала exec, и .bootstrap.tmp оставался в /opt/goamnezia навсегда.
_selfupdate_exec() {
    exec 3<"$1" || return 1
    rm -f "$1"
    exec bash /dev/fd/3
}

_selfupdate_screen() {
    local repo cur ref pat ch branch def here m1="" m2="" m3="" sha="" rc remote src shown down=0 loader code first="" ask
    _screen_head "$(t mt_selfupdate)" "$(t mt_selfupdate_note)"
    repo=$(_install_source_field repo) || repo=""
    cur=$(_install_source_field branch) || cur=""
    ref=$(_install_source_field ref) || ref=""
    _su_repo_ok "$repo" || repo=""
    _su_branch_ok "$cur" || cur=""
    echo -e "  $(t mt_selfupdate_version): ${CYAN}v${GOAMNEZIA_VERSION}${NC}"
    if [ -z "$repo" ] || [ -z "$cur" ]; then
        # Установка старее самого признака источника (или каталог перенесли)
        log_warning "$(t mt_selfupdate_no_source)"
        log_dim "$(t mt_selfupdate_hint)"
        return 0
    fi
    echo -e "  $(t mt_selfupdate_repo): ${CYAN}${repo}${NC}    $(t mt_selfupdate_branch): ${CYAN}${cur}${NC}"
    [[ "$ref" =~ ^[0-9a-f]{12} ]] && echo -e "  $(t mt_selfupdate_ref): ${DIM}${ref:0:12}${NC}"
    echo -e "  ${DIM}$(_rule)${NC}"

    # Выбор ветки. Людям — две; рабочая ветка автора (стенд), с которой сервер поставлен, — третьим пунктом,
    # чтобы стенд обновлялся оттуда же, как раньше. Enter — ветка, откуда сервер поставлен.
    here=" ${DIM}$(t mt_su_here)${NC}"
    case "$cur" in
        main) m1="$here"; def=main ;;
        dev)  m2="$here"; def=dev ;;
        *)    m3="$here"; def="$cur" ;;
    esac
    echo -e "  ${CYAN}1${NC}) $(t mt_su_main)${m1}"
    echo -e "  ${CYAN}2${NC}) $(t mt_su_dev)${m2}"
    if [ -n "$m3" ]; then
        echo -e "  ${CYAN}3${NC}) $(tf mt_su_other "$cur")${m3}"
    fi
    echo -e "  ${CYAN}0${NC}) $(t back)"
    echo -e "  ${DIM}$(_rule)${NC}"
    echo -ne "  ${WHITE}$(tf mt_su_choose "$def"):${NC} "
    # Конец ввода — отмена, а не согласие с умолчанием (goinstaller-ready §10).
    read -r ch || ch=0
    case "$ch" in
        "") branch="$def" ;;
        1)  branch=main ;;
        2)  branch=dev ;;
        3)  if [ -n "$m3" ]; then branch="$cur"; else log_error "$(t invalid_choice)"; return 1; fi ;;
        0)  GA_BACK=1; return 0 ;;
        *)  log_error "$(t invalid_choice)"; return 1 ;;
    esac

    pat="${GOAMNEZIA_PAT:-}"
    [ -n "$pat" ] || _su_ask_pat pat
    if [ -z "$pat" ]; then
        log_error "$(t mt_selfupdate_no_pat)"
        log_dim "$(t mt_selfupdate_hint)"
        return 1
    fi

    # Коммит головы ветки — у API: raw по имени ветки кэшируется на пять минут, и сразу после выпуска приехал бы
    # прежний загрузчик. Не ответил API (сеть, лимит) — берём по имени ветки, но не падаем (goinstaller-ready §3).
    log_info "$(tf mt_su_checking "$branch")"
    rc=0
    sha=$(_su_head_sha "$pat" "$repo" "$branch") || rc=$?
    case "$rc" in
        0) ;;
        2) log_error "$(tf mt_su_no_branch "$branch")"; return 1 ;;
        3) log_error "$(t mt_selfupdate_fetch_failed)"; log_dim "$(t mt_selfupdate_hint)"; return 1 ;;
        *) sha=""; log_warning "$(t mt_su_no_sha)" ;;
    esac
    src="${sha:-$branch}"
    remote=$(_su_remote_version "$pat" "$repo" "$src") || remote=""
    if [ -z "$remote" ]; then
        log_error "$(tf mt_su_no_version "$branch")"
        log_dim "$(t mt_selfupdate_hint)"
        return 1
    fi
    shown="${sha:0:12}"
    [ -n "$shown" ] || shown="—"
    if [ "$branch" != "$cur" ]; then
        log_info "$(tf mt_su_switch "$cur" "$branch")"
    fi

    # Сначала — что лежит в ветке против установленного: «доступна vX» или «у вас последняя» (NC-20: экран не говорил,
    # есть ли новее), и только потом вопрос. Номер тот же, а коммит другой (правки без смены номера, другая ветка) —
    # так и сказано, и вопрос — об обновлении; тот же коммит — «переустановить?», обычно незачем.
    if _ver_lt "$remote" "$GOAMNEZIA_VERSION"; then
        # Откат: dev обычно впереди main, поэтому переезд на стабильную ветку — почти всегда версия ниже. Запретить
        # его нельзя (переезд между ветками — главный сценарий серии), делать молча — тоже: возможности новее целевой
        # версии пропадут, а записанное новой версией старая может понять не так. Поэтому — набранное слово вместо
        # «1» и копия настроек, ключей и людей ДО переезда: не снялась копия — отката нет.
        log_warning "$(tf mt_su_down_warn "$branch" "$remote" "$GOAMNEZIA_VERSION")"
        log_dim "$(tf mt_su_commit "$branch" "$shown")"
        log_dim "$(t mt_su_down_backup)"
        confirm_phrase "$(t mt_su_down_phrase)" "$(tf mt_su_down_ask "$GOAMNEZIA_VERSION" "$remote")" || return 1
        down=1
    else
        ask=$(tf mt_selfupdate_ask "$remote" "$branch")
        if [ "$remote" != "$GOAMNEZIA_VERSION" ]; then
            log_info "$(tf mt_su_avail "$remote" "$GOAMNEZIA_VERSION")"
            log_dim "$(tf mt_su_commit "$branch" "$shown")"
        elif [ -n "$sha" ] && [[ "$ref" =~ ^[0-9a-f]{7,40}$ ]] && [[ "$sha" != "$ref"* ]]; then
            log_info "$(_ui_w "$(tf mt_su_same_other_commit "$remote" "$branch" "$shown" "${ref:0:12}")")"
        else
            log_success "$(tf mt_su_latest "$branch" "$remote")"
            log_dim "$(tf mt_su_commit "$branch" "$shown")"
            ask=$(tf mt_su_reinstall_ask "$remote" "$branch")
        fi
        log_warning "$(t mt_selfupdate_warn)"
        confirm "$ask" || { log_info "$(t cancelled)"; return 1; }
    fi

    # Загрузчик — из того же коммита, что и версия выше. Первая строка — «#!»: страница ошибки вместо файла
    # запущена не будет (goinstaller-ready §3). Времянка — в каталоге продукта, а не в общем /tmp.
    loader=$(mktemp "$GOAMNEZIA_DIR/.bootstrap.XXXXXX" 2>/dev/null) || loader=""
    if [ -z "$loader" ]; then
        log_error "$(t mt_selfupdate_fetch_failed)"
        return 1
    fi
    code=$(_su_get "$pat" "https://raw.githubusercontent.com/${repo}/${src}/bootstrap.sh" "$loader")
    { IFS= read -r first <"$loader"; } 2>/dev/null || true
    if [ "$code" != 200 ] || [[ "$first" != '#!'* ]]; then
        rm -f "$loader"
        log_error "$(t mt_selfupdate_fetch_failed)"
        log_dim "$(t mt_selfupdate_hint)"
        return 1
    fi

    if [ "$down" = 1 ]; then
        if ! type create_backup >/dev/null 2>&1; then
            rm -f "$loader"
            log_error "$(tf module_missing create_backup)"
            return 1
        fi
        # Место — по размеру данных (режим data), как у снимка перед миграцией: общий порог плановых копий
        # (512 МБ) на маленьком VPS не давал бы откатиться никогда (находка UP-1).
        if ! ga_step "$(t mt_backup)" "$(t mt_backup_done)" "" create_backup "" "$BACKUP_DIR" data; then
            rm -f "$loader"
            log_error "$(t mt_su_down_nobackup)"
            return 1
        fi
        _backup_where
    fi

    log_info "$(tf mt_selfupdate_running "$branch")"
    # Ключ — окружением (export), а не аргументом `env`: argv процесса env на миг клал его в /proc/*/cmdline
    # (находка SR-38); окружение видит только владелец процесса. GOAMNEZIA_REF — загрузчик уже из этого коммита:
    # себя второй раз не качает, файлы берёт оттуда же. GOAMNEZIA_EXPECT_VERSION — версия, которую видел человек:
    # загрузчик сверит с ней разложенное на диске. Коммит не узнан — обе снимаем: прежние значения в окружении
    # приколотили бы загрузчик к старому коммиту.
    export GOAMNEZIA_PAT="$pat" GOAMNEZIA_BRANCH="$branch"
    # «Обновить goAmnezia» ставит только из выбранной ветки GitHub: каталог-дерево стенда (GOAMNEZIA_LOCAL_TREE,
    # bootstrap.sh) из окружения этой сессии не должен подменить её файлы.
    unset GOAMNEZIA_LOCAL_TREE GOAMNEZIA_BOOTSTRAP_CHECK
    if [ -n "$sha" ]; then
        export GOAMNEZIA_REF="$sha" GOAMNEZIA_EXPECT_VERSION="$remote"
    else
        unset GOAMNEZIA_REF GOAMNEZIA_EXPECT_VERSION
    fi
    _selfupdate_exec "$loader"
    rm -f "$loader"
    log_error "$(t mt_selfupdate_fetch_failed)"
    return 1
}

# Список, выбор и подтверждение живут в lib/backup.sh (interactive_restore →
# list_backups → restore_backup с confirm внутри): list_backups печатает
# список в stderr, поэтому собирать его через $( ) здесь было бы пустой затеей.
_restore_interactive() {
    type interactive_restore >/dev/null 2>&1 || { log_error "$(tf module_missing interactive_restore)"; return 1; }
    log_warning "$(t mt_restore_warn)"
    interactive_restore
}

# _import_pr_label <профиль> — подпись профиля (ключ словаря буквально, через case — правило MAP §1 п.8).
# Второй аргумент — линия контейнера из скана (import_scan .line): «можно подхватить как профиль AmneziaWG 3.1 (awg2)» —
# по версии, а не по месту (DUP-LINE-01: приложение держит 3.1 в amnezia-awg2, и подпись по месту говорила «2.0»).
# Профиль уже стоит — его подпись по линии с портом (_pr_name).
_import_pr_label() {
    if [[ "${2:-}" =~ ^(1\.0|1\.5|2\.0|3\.1)$ ]] && [[ "$1" =~ ^awg[123]$ ]]; then
        tf pr_title_line "$2"
        return 0
    fi
    if [[ "$1" =~ ^awg[123]$ ]] && _profile_installed "$1"; then
        _pr_name "$1"
        return 0
    fi
    case "$1" in
        awg1) t pr_awg1 ;;
        awg2) t pr_awg2 ;;
        awg3) t pr_awg3 ;;
        *)    printf '%s' "${1:--}" ;;
    esac
}

# _import_rows <JSON import_scan> [1 — с номерами] — таблица «что нашли на сервере»: одна строка на
# контейнер (имя, протокол, порт, работает ли, сколько людей) и под ней, что с ним будет. Общая для первого
# экрана мастера и «Обслуживание → Импорт»: раньше экран импорта показывал у xray «UDP 443» и «неизвестный
# тип контейнера» у DNS приложения, а остановленных контейнеров не видел вовсе (TK-4, OWN-1).
_import_rows() {
    local js="$1" num="${2:-0}" i=0 c st port proto protocol line peers managed profile ad sug rtext kind sub ovl
    local lbl where stl pp head arrow o ol
    # Разделитель — \x1f, а не табуляция: табуляция в IFS — «пробельный» символ, и пустые поля (профиль,
    # причина) склеивались, сдвигая колонки.
    while IFS=$'\x1f' read -r c st port proto protocol line peers managed profile ad sug rtext kind sub ovl; do
        i=$((i + 1))
        lbl=$(ga_import_protocol_label "$protocol" "$line")
        if [ "${port:-0}" != 0 ] && [ -n "$proto" ]; then where="${proto^^} $port"; else where="—"; fi
        case "$st" in
            exited)     stl=$(t import_state_stopped) ;;
            restarting) stl=$(t import_state_restarting) ;;
            *)          stl=$(t import_state_running) ;;
        esac
        pp=""
        case "$kind" in awg|legacy) [ -n "$line" ] && pp=$(tf import_col_people "${peers:-0}") ;; esac
        head="  "
        [ "$num" = 1 ] && head="  ${CYAN}$(_pad "$i)" 3)${NC} "
        echo -e "${head}$(_pad "$c" 16) $(_pad "$lbl" 18) $(_pad "$where" 10) $(_pad "$stl" 11) ${pp}"
        if [ "$managed" = true ]; then
            arrow=$(tf import_row_managed "$(_import_pr_label "$profile")")
            echo -e "       ${DIM}$(ga_wrap "→ ${arrow}" "$(( ${GA_UI_W:-76} - 7 ))" 9)${NC}"
            continue
        fi
        if [ "$ad" = true ]; then
            if [ "$st" = exited ]; then
                arrow=$(tf import_row_adoptable_stopped "$(_import_pr_label "$sug" "$line")")
            elif [ "${peers:-0}" = 0 ]; then
                arrow=$(tf import_row_adoptable_empty "$(_import_pr_label "$sug" "$line")")
            else
                arrow=$(tf import_row_adoptable "$(_import_pr_label "$sug" "$line")")
            fi
            echo -e "       ${GREEN}$(ga_wrap "→ ${arrow}" "$(( ${GA_UI_W:-76} - 7 ))" 9)${NC}"
            # Подсеть совпадёт с уже стоящим профилем (так приложение ставит свои контейнеры, SUBNET-01) — сказать
            # заранее: подхват не откажет, а развести подсети предложим сразу после него.
            if [ -n "$ovl" ] && [ -n "$sub" ]; then
                ol=""
                for o in ${ovl//,/ }; do ol="${ol:+$ol, }$(_import_pr_label "$o")"; done
                echo -e "       ${YELLOW}$(ga_wrap "→ $(tf import_scan_overlap "$sub" "$ol")" "$(( ${GA_UI_W:-76} - 7 ))" 9)${NC}"
            fi
        else
            arrow=$(tf import_row_not "${rtext:-$(t import_reason_unknown_kind)}")
            echo -e "       ${DIM}$(ga_wrap "→ ${arrow}" "$(( ${GA_UI_W:-76} - 7 ))" 9)${NC}"
        fi
    done < <(printf '%s' "$js" | jq -r '.[] | [.container, (.state // "running"), (.port // 0 | tostring), (.proto // ""),
        (.protocol // ""), (.line // ""), (.peers // 0 | tostring), (.managed | tostring), (.profile // ""),
        (.adoptable | tostring), (.suggested_profile // ""), (.reason_text // ""), (.kind // ""), (.subnet // ""),
        ((.subnet_overlap // []) | join(","))]
        | map(tostring | gsub("[\u001f\n]"; " ")) | join("\u001f")' 2>/dev/null)
}

_import_scan_screen() {
    local js n ch name
    type import_scan >/dev/null 2>&1 || { log_error "$(tf module_missing import_scan)"; return 1; }
    command -v jq >/dev/null 2>&1 || { log_warning "$(t err_no_jq)"; return 1; }
    _screen_head "$(t mt_import)" "$(t mt_import_note)"
    # В текущей оболочке, а не в $( ): отказ (битый users.json, демон Docker не отвечает) раньше превращался
    # в «Чужих контейнеров Amnezia не найдено» — хотя их было три (находка SR-31).
    GA_ERR_CODE=""; GA_ERR_MSG=""
    if ! ga_capture js import_scan 2>/dev/null; then
        log_error "$(_ui_w "${GA_ERR_MSG:-$(t act_failed)}")"
        return 1
    fi
    printf '%s' "$js" | jq -e . >/dev/null 2>&1 || js="[]"
    n=$(printf '%s' "$js" | jq -r 'length')
    if [ "${n:-0}" = 0 ]; then
        echo -e "  ${DIM}$(t mt_import_none)${NC}"
        return 0
    fi
    # Только свои контейнеры (чистый сервер после мастера) — ни таблицы, ни слов «подхват», «пиры без приватных
    # ключей»: подхватывать нечего, так и говорим (находка NC-22 критика-новичка). Свои профили с контейнерами
    # сверяются сами при каждом запуске меню (_import_reconcile_prompt).
    if [ "$(printf '%s' "$js" | jq -r '[.[] | select(.managed != true)] | length')" = 0 ]; then
        local ours="" op
        while IFS= read -r op; do
            [ -n "$op" ] && ours="${ours:+$ours, }$(_import_pr_label "$op")"
        done < <(printf '%s' "$js" | jq -r '[.[].profile // empty] | unique | .[]')
        echo -e "  $(ga_win_wrap "$(tf mt_import_only_ours "${ours:--}")" 2)"
        return 0
    fi
    _import_rows "$js" 1
    echo -e "  ${DIM}$(_rule)${NC}"
    echo -e "  ${DIM}$(ga_wrap "$(t mt_import_hint)" "${GA_UI_W:-76}" 2)${NC}"
    # «Enter — назад», как обещает подсказка: ga_ask принимал пустой ответ за
    # ошибку и переспрашивал трижды (найдено при составлении карты проекта).
    # Длина номера ограничена: число длиннее int64 роняло сравнение (SR-53).
    # 0 и Enter — назад БЕЗ «Нажмите Enter»: следующая набранная цифра уходила в паузу и терялась (NC-22).
    ch=$(ga_ask_optional "$(t mt_import_pick)" '^[0-9]{1,4}$' "$(t invalid_choice)") || return 0
    [ -n "$ch" ] || { GA_BACK=1; return 0; }
    ch=$((10#$ch))
    [ "$ch" != 0 ] || { GA_BACK=1; return 0; }
    [ "$ch" -ge 1 ] && [ "$ch" -le "$n" ] || return 0
    name=$(printf '%s' "$js" | jq -r --argjson i "$((ch - 1))" '.[$i].container')
    if [ "$(printf '%s' "$js" | jq -r --argjson i "$((ch - 1))" '.[$i].managed')" = true ]; then
        _import_reconcile_interactive "$(printf '%s' "$js" | jq -r --argjson i "$((ch - 1))" '.[$i].profile')"
        return $?
    fi
    if [ "$(printf '%s' "$js" | jq -r --argjson i "$((ch - 1))" '.[$i].adoptable')" != true ]; then
        log_warning "$(_ui_w "$(tf import_err_not_adoptable "$name" "$(printf '%s' "$js" | jq -r --argjson i "$((ch - 1))" '.[$i].reason_text // ""')")")"
        return 0
    fi
    type import_adopt >/dev/null 2>&1 || { log_error "$(tf module_missing import_adopt)"; return 1; }
    log_info "$(_ui_w "$(t mt_import_adopt_note)")"
    confirm "$(tf mt_import_adopt_ask "$name" "$(printf '%s' "$js" | jq -r --argjson i "$((ch - 1))" '.[$i].suggested_profile')")" || { log_info "$(t cancelled)"; return 0; }
    # Подсказку про ключи людей import_adopt печатает сам (когда люди есть) — второй раз не повторяем.
    local res="" e mp mfree
    GA_ERR_CODE=""; GA_ERR_MSG=""
    if ga_capture res import_adopt "$name"; then
        # Подхват из меню — тоже «появился профиль»: после отменённого мастера сервер оставался с
        # installed=false, без таймеров, и следующий заход снова открывал мастер (UP-4). В мастере отметку
        # ставит его собственный конец, а этот экран из мастера не зовётся.
        _ga_mark_installed
        # Подсеть совпала с другим профилем (SUBNET-01): с кем и выход import_adopt уже сказал — здесь сразу
        # предлагаем его (свободную подсеть подставило ядро; «нет» — развести можно потом, пунктом «Подсеть»).
        e=$(printf '%s' "$res" | jq -c '.subnet_overlap // empty' 2>/dev/null) || e=""
        mp=$(jq -r '.move.profile // empty' <<<"$e" 2>/dev/null)
        mfree=$(jq -r '.move.subnet // empty' <<<"$e" 2>/dev/null)
        if [ -n "$mp" ] && [ -n "$mfree" ]; then
            echo ""
            _subnet_move_offer "$mp" "$mfree" || log_dim "$(_ui_w "$(t pr_subnet_move_later)")"
        fi
    fi
}

# Сверка пиров контейнера с users.json: показать разницу и предложить подхватить.
_import_reconcile_interactive() {
    local profile="$1" js
    type import_reconcile >/dev/null 2>&1 || { log_error "$(tf module_missing import_reconcile)"; return 1; }
    # В текущей оболочке: причина отказа модуля (контейнер пропал, битый users.json) из подоболочки не
    # доходила, и всегда печаталось «Действие не выполнено (reconcile_failed)» (находка SR-31).
    GA_ERR_CODE=""; GA_ERR_MSG=""
    if ! ga_capture js import_reconcile "$profile" 2>/dev/null; then
        log_error "${GA_ERR_MSG:-$(t act_failed)}"
        return 1
    fi
    if [ "$(printf '%s' "$js" | jq -r '.in_sync')" = true ]; then
        log_success "$(tf import_reconcile_in_sync "$(_pr_name "$profile")")"
        _import_reconcile_skipped_show "$js"
        return 0
    fi
    echo ""
    printf '%s' "$js" | jq -r --arg n "$(t mt_import_new_peers)" --arg g "$(t mt_import_gone_peers)" '
        (.new[]? | "  + \($n): \(.name // "-")  \(.ip // "-")  \(.pubkey[0:12])…"),
        (.gone[]? | "  - \($g): \(.name)  \(.pubkey[0:12])…")'
    _import_reconcile_skipped_show "$js"
    confirm "$(tf import_reconcile_ask "$(_pr_name "$profile")")" || { log_info "$(t cancelled)"; return 0; }
    # Строки о пропуске уже показаны до вопроса — ядро их второй раз не печатает (KEENETIC-I1-N, V4).
    GA_RECONCILE_QUIET_SKIPPED=1 import_reconcile "$profile" apply >/dev/null
}

# _import_reconcile_skipped_show <JSON сверки> — пиры контейнера, которых сверка не подхватит (не ключ, ключ другого
# профиля, нет IPv4; KEENETIC-I1-N, N2): строка о пропуске с причиной на каждого — слова ядра (skipped[].message).
# Расхождением они не считаются, и вопроса «Подхватить?» из-за них нет.
_import_reconcile_skipped_show() {
    local sk
    while IFS= read -r sk; do
        [ -n "$sk" ] && log_warning "$sk"
    done < <(printf '%s' "$1" | jq -r '.skipped[]?.message // empty' 2>/dev/null)
    return 0
}

# Сверка при старте (PLAN §6.5, §11 «двойное управление»): приложение Amnezia
# могло добавить или удалить пира в контейнере, минуя нас. Только в интерактиве
# и только по установленным профилям с живым контейнером; молча — ничего.
_import_reconcile_prompt() {
    local p js
    type import_reconcile >/dev/null 2>&1 || return 0
    command -v jq >/dev/null 2>&1 || return 0
    for p in $PROFILE_IDS; do
        _profile_installed "$p" || continue
        case "$(_profile_state "$p")" in running|unpublished) ;; *) continue ;; esac
        js=$(import_reconcile "$p" 2>/dev/null) || continue
        # Только пропущенные пиры (их не подхватить, KEENETIC-I1-N, N2) — не расхождение: без вопроса «Подхватить?»,
        # только причина строкой — при каждом старте, пока пира не исправят или не уберут в приложении (запись конфига
        # профиля его тоже снимет, как любого чужого).
        if [ "$(printf '%s' "$js" | jq -r '.in_sync' 2>/dev/null)" != false ]; then
            if [ "$(printf '%s' "$js" | jq -r '.skipped | length' 2>/dev/null)" -gt 0 ] 2>/dev/null; then
                log_info "$(tf import_reconcile_in_sync "$(_pr_name "$p")")"
                _import_reconcile_skipped_show "$js"
            fi
            continue
        fi
        log_warning "$(tf import_reconcile_diff "$(_pr_name "$p")" "$(printf '%s' "$js" | jq -r '.new|length')" "$(printf '%s' "$js" | jq -r '.gone|length')")"
        _import_reconcile_interactive "$p" || true
    done
    return 0
}

# ── Обновления Amnezia (lib/upstream.sh, PLAN §6.8): таблица профилей и кнопки ──
_upstream_screen() {
    local js n i ch p cur avail upd rb rel_cur rel_new hint line
    type upstream_check >/dev/null 2>&1 || { log_error "$(tf module_missing upstream_check)"; return 1; }
    command -v jq >/dev/null 2>&1 || { log_warning "$(t err_no_jq)"; return 1; }
    _screen_head "$(t mt_upstream)" "$(t mt_upstream_note)"
    log_dim "$(t mt_upstream_checking)"
    GA_ERR_CODE=""; GA_ERR_MSG=""
    # В текущей оболочке (ga_capture), а не в $( … ): причина отказа модуля (битый config.json и др.) из
    # подоболочки не доходила, и экран на любую писал «GitHub и Docker Hub недоступны» (находка SR-31).
    ga_capture js upstream_check 2>/dev/null || js=""
    if [ -z "$js" ] || ! printf '%s' "$js" | jq -e . >/dev/null 2>&1; then
        # Источники недоступны: показываем текущие версии и совет, меню живёт.
        log_warning "${GA_ERR_MSG:-$(t upstream_err_unreachable)}"
        if type ga_up_profiles_current >/dev/null 2>&1; then
            ga_up_profiles_current 2>/dev/null | jq -r '.[] | "  \(.profile)  \(.container)  \(.current_tag // "-")"' 2>/dev/null
        fi
        return 0
    fi
    rel_cur=$(printf '%s' "$js" | jq -r '.client_release.current // ""'); rel_new=$(printf '%s' "$js" | jq -r '.client_release.tag // ""')
    echo -e "  $(t mt_upstream_release): ${CYAN}${rel_cur:--}${NC} → ${CYAN}${rel_new:--}${NC}  $( [ "$(printf '%s' "$js" | jq -r '.client_release.update // false')" = true ] && printf '%b' "${YELLOW}$(t mt_upstream_new)${NC}" )"
    printf '%s' "$js" | jq -r '.scripts | to_entries[] | select(.value.changed != null and (.value.changed|length) > 0) | "  scripts/\(.key): \(.value.changed | join(", "))"' 2>/dev/null
    n=$(printf '%s' "$js" | jq -r '.unsupported | length')
    if [ "${n:-0}" != 0 ]; then
        log_warning "$(tf mt_upstream_unsupported "$(printf '%s' "$js" | jq -r '[.unsupported[].name] | unique | join(", ")')")"
    fi
    echo -e "  ${DIM}$(_rule)${NC}"
    # Шапка колонок: это версия ОБРАЗА ЯДРА, общего для всех линеек, — у 2.0 он тоже 3.1.x, и без подписи
    # «awg2 3.1.… → 3.1.…» выглядело ошибкой (находка NC-19 критика-новичка). Профиль — именем линейки.
    local any_upd=0 any_rb=0
    echo -e "  ${DIM}   $(_pad "$(t col_profile)" 22) $(t mt_upstream_col_image)${NC}"
    i=0
    while IFS=$'\t' read -r p cur avail upd rb; do
        i=$((i + 1))
        line="$(_pad "$(_import_pr_label "$p")" 22) ${cur:--} → ${avail:--}"
        if [ "$upd" = true ]; then line="$line  ${YELLOW}$(t mt_upstream_available)${NC}"; any_upd=1; else line="$line  ${DIM}$(t mt_upstream_current)${NC}"; fi
        [ "$rb" = true ] && { line="$line  ${DIM}$(t mt_upstream_rollback_ok)${NC}"; any_rb=1; }
        printf '  %b%s%b) %b\n' "$CYAN" "$i" "$NC" "$line"
    done < <(printf '%s' "$js" | jq -r '.profiles[] | [.profile, (.current_tag // "-"), (.available_tag // "-"), (.update|tostring), (.rollback_available|tostring)] | @tsv')
    n=$i
    echo -e "  ${DIM}$(ga_win_wrap "$(t mt_upstream_image_note)" 2)${NC}"
    echo -e "  ${DIM}$(_rule)${NC}"
    # Есть обновление — словами меню, а не командой моста (upstream-update --profile=…) длиннее экрана
    # (находка LC-21); прочие подсказки модуля (актуально, вышло только приложение, скрипты не скачались) — как есть.
    if [ "$(printf '%s' "$js" | jq -r '.updates_available // false')" = true ]; then
        hint=$(t mt_upstream_hint_update)
    else
        hint=$(printf '%s' "$js" | jq -r '.hint // ""')
    fi
    [ -n "$hint" ] && echo -e "  ${DIM}$(_ui_w "$hint")${NC}"
    [ "${n:-0}" -gt 0 ] || return 0
    # Что делает номер — только когда есть что обновлять или откатывать: «номер — обновить профиль» у актуальных
    # профилей обещал пересоздание, которое ничего не меняет (NC-19).
    [ "$any_upd" = 1 ] && echo -e "  ${DIM}$(ga_win_wrap "$(t mt_upstream_pick_hint)" 2)${NC}"
    [ "$any_rb" = 1 ] && echo -e "  ${DIM}$(ga_win_wrap "$(t mt_upstream_pick_hint_rb)" 2)${NC}"
    echo -ne "  ${WHITE}$(t mt_upstream_pick):${NC} "
    read -r ch || ch=""
    case "$ch" in
        ""|0) GA_BACK=1; return 0 ;;
        r[0-9]*)
            ch="${ch#r}"
            [[ "$ch" =~ ^[0-9]{1,4}$ ]] && [ "$((10#$ch))" -ge 1 ] && [ "$((10#$ch))" -le "$n" ] || return 0
            p=$(printf '%s' "$js" | jq -r --argjson i "$((10#$ch - 1))" '.profiles[$i].profile')
            if [ "$(printf '%s' "$js" | jq -r --argjson i "$((10#$ch - 1))" '.profiles[$i].rollback_available')" != true ]; then
                log_info "$(tf mt_upstream_no_rollback "$(_import_pr_label "$p")")"
                return 0
            fi
            type upstream_rollback >/dev/null 2>&1 || { log_error "$(tf module_missing upstream_rollback)"; return 1; }
            log_warning "$(_ui_w "$(tf mt_upstream_rollback_warn "$(_pr_name "$p")")")"
            # Без точного отпечатка «вернуть предыдущий образ» — обещание,
            # которого продукт сдержать не может: он потянет то, что лежит под
            # тем же тегом СЕЙЧАС. Так бывает у профилей, подхваченных из
            # приложения (previous_digest пуст) — говорим об этом до вопроса
            # (DEFECTS §5.9).
            if [ -z "$(_cfg ".profiles.$p.previous.image_digest")" ]; then
                log_warning "$(_ui_w "$(tf mt_upstream_rollback_floating \
                    "$(_cfg ".profiles.$p.previous.image_tag")")")"
            fi
            confirm "$(tf mt_upstream_rollback_ask "$(_pr_name "$p")")" || { log_info "$(t cancelled)"; return 0; }
            upstream_rollback "$p" >/dev/null
            ;;
        [0-9]*)
            # Не длиннее четырёх цифр и десятично (SR-53).
            [[ "$ch" =~ ^[0-9]{1,4}$ ]] && [ "$((10#$ch))" -ge 1 ] && [ "$((10#$ch))" -le "$n" ] || return 0
            p=$(printf '%s' "$js" | jq -r --argjson i "$((10#$ch - 1))" '.profiles[$i].profile')
            # Актуальный профиль не пересоздаём «до той же версии» (NC-19): обновлять нечего
            if [ "$(printf '%s' "$js" | jq -r --argjson i "$((10#$ch - 1))" '.profiles[$i].update')" != true ]; then
                log_info "$(tf mt_upstream_already_current "$(_import_pr_label "$p")" \
                    "$(printf '%s' "$js" | jq -r --argjson i "$((10#$ch - 1))" '.profiles[$i].current_tag // "-"')")"
                return 0
            fi
            type upstream_update >/dev/null 2>&1 || { log_error "$(tf module_missing upstream_update)"; return 1; }
            log_warning "$(tf mt_upstream_update_warn "$(_pr_name "$p")")"
            confirm "$(tf mt_upstream_update_ask "$(_pr_name "$p")" "$(printf '%s' "$js" | jq -r --argjson i "$((10#$ch - 1))" '.profiles[$i].available_tag // "-"')")" || { log_info "$(t cancelled)"; return 0; }
            upstream_update "$p" >/dev/null
            ;;
        *) return 0 ;;
    esac
}

# Диагностика: ровно те проверки, что отдаёт действие quality (одна функция на
# оба интерфейса — иначе SSH и бот однажды начнут отвечать по-разному).
_ga_quality_json() {
    local docker_ok="false" fwd="0" net_ok="false" disk="0" p ports="[]" free dock='null'
    # Версию API демона закрепляем ДО первой команды: на сервере с
    # автообновлениями клиент docker бывает новее живого демона, и без этого
    # диагностика показывала бы «Docker: нет» на работающем Docker.
    type docker_api_pin >/dev/null 2>&1 && docker_api_pin --probe
    command -v docker >/dev/null 2>&1 && ga_docker info >/dev/null 2>&1 && docker_ok="true"
    [ -r /proc/sys/net/ipv4/ip_forward ] && fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)
    if command -v docker >/dev/null 2>&1 && ga_docker network inspect amnezia-dns-net >/dev/null 2>&1; then
        net_ok="true"
    fi
    # Версии клиента и демона, их совместимость и подсказка про рестарт —
    # ровно то, чего не хватало, когда «всё выключено», а VPN работает.
    if type docker_diag_json >/dev/null 2>&1; then
        dock=$(docker_diag_json 2>/dev/null) || dock='null'
        printf '%s' "$dock" | jq -e . >/dev/null 2>&1 || dock='null'
    fi
    disk=$(ga_df_mb "$GOAMNEZIA_DIR" | awk '{print $3}') || disk=0
    [[ "$disk" =~ ^[0-9]+$ ]] || disk=0
    if command -v jq >/dev/null 2>&1; then
        local pport pcont pub prc
        for p in $PROFILE_IDS; do
            _profile_installed "$p" || continue
            pport=$(_cfg ".profiles.$p.port")
            free="true"; _port_free "$pport" udp || free="false"
            # published — опубликован ли порт у работающего контейнера профиля: «работает» без него — это
            # профиль, до которого не доходит никто (находка LC-20); null — не работает или не узнать.
            pub=null
            if type docker_port_published >/dev/null 2>&1 && type docker_container_state >/dev/null 2>&1; then
                pcont=$(_cfg ".profiles.$p.container"); [ -n "$pcont" ] || pcont="amnezia-$p"
                if [ "$(docker_container_state "$pcont" 2>/dev/null)" = running ]; then
                    prc=0; docker_port_published "$pcont" "$pport" udp 2>/dev/null || prc=$?
                    case "$prc" in 0) pub=true ;; 1) pub=false ;; esac
                fi
            fi
            ports=$(jq -nc --argjson acc "$ports" --arg p "$p" --arg port "$pport" \
                --argjson free "$free" --argjson pub "$pub" \
                '$acc + [{profile:$p, port:$port, free:$free, published:$pub}]' 2>/dev/null) || ports="$ports"
        done
        # Публичные порты 80/443 и доступность режимов с сайтом — из
        # предполётной проверки (PLAN §4.3.1): та же таблица, что видит мастер,
        # только в JSON — бот и панель показывают, кто держит порт и чей он.
        local pf='null' tm='[]'
        if type preflight_modes >/dev/null 2>&1; then
            pf=$(preflight_modes 2>/dev/null) || pf='null'
            printf '%s' "$pf" | jq -e . >/dev/null 2>&1 || pf='null'
        fi
        # Личность сервера: у одной пары ключей три хранилища, и расхождение
        # между ними убивает все ключи разом, оставаясь незаметным (§1c.1).
        # Диагностика — единственное место, где это видно ДО того, как о нём
        # узнают пользователи.
        local keys='[]' kj
        if type ga_amn_keys_consistent >/dev/null 2>&1; then
            for p in $PROFILE_IDS; do
                _profile_installed "$p" || continue
                kj=$(ga_amn_keys_consistent "$p" 2>/dev/null) || kj=""
                printf '%s' "$kj" | jq -e . >/dev/null 2>&1 || continue
                keys=$(jq -nc --argjson acc "$keys" --argjson k "$kj" '$acc + [$k]' 2>/dev/null) || keys="$keys"
            done
        fi

        # Таймеры продукта (lib/timers.sh): стоит ли каждый и активен ли —
        # выключенный сторож или таймер лимитов молчит, пока сюда не посмотришь.
        if type timers_status >/dev/null 2>&1; then
            tm=$(timers_status 2>/dev/null) || tm='[]'
            printf '%s' "$tm" | jq -e . >/dev/null 2>&1 || tm='[]'
        fi
        # Контейнеры в сети пропавшего контейнера, чьи — не записано (WRP-06): связи у них нет, а сами мы их не трогаем.
        local dangling='[]'
        if type docker_netdeps_dangling >/dev/null 2>&1; then
            dangling=$(docker_netdeps_dangling 2>/dev/null | sort -u | jq -R . | jq -sc .) || dangling='[]'
            printf '%s' "$dangling" | jq -e 'type == "array"' >/dev/null 2>&1 || dangling='[]'
        fi
        jq -nc --argjson d "$docker_ok" --arg f "${fwd:-0}" --argjson n "$net_ok" \
               --argjson disk "$disk" --argjson ports "$ports" --argjson pf "$pf" --argjson tm "$tm" \
               --argjson dock "$dock" --argjson keys "$keys" --argjson dangling "$dangling" \
               '{docker:$d, ip_forward:$f, network:$n, disk_free_mb:$disk, ports:$ports,
                 docker_info: $dock,
                 server_keys: $keys,
                 server_keys_ok: ([$keys[]? | select(.ok == false)] | length == 0),
                 public_ports: ($pf.ports // null),
                 modes: (if $pf == null then null else {lite_site: $pf.lite_site.available, pro: $pf.pro.available} end),
                 port_warnings: ($pf.warnings // []), timers: $tm, netdeps_dangling: $dangling}'
    else
        printf '{"docker":%s,"ip_forward":"%s","network":%s,"disk_free_mb":%s,"ports":[]}' \
            "$docker_ok" "${fwd:-0}" "$net_ok" "$disk"
    fi
}

# Диагностика словами. Экран печатал `jq .` всего ответа quality: шестьдесят
# строк JSON, в которых человек не видел ни расхождения ключей сервера (а это
# смерть всех выданных ключей), ни таймера, который тикает вхолостую. Машинам
# — `--action=quality --json`, человеку — слова; подсказка о JSON внизу экрана.
_DIAG_JS=""
_dq() { jq -r "$1" <<<"$_DIAG_JS" 2>/dev/null; }
# Длинную строку переносим по словам с висячим отступом под значок ✓/✗/⚠:
# без этого совет про sysctl уезжал за край даже на широком терминале. Тем же
# переносом печатаются длинные объяснения переходов между режимами.
_ui_w() { ga_wrap "$1" "$(( ${GA_UI_W:-76} - 4 ))" 4; }
# _ui_wb — то же для строки списка «    • …» (шаги итога, «кому что сделать»): та же ширина, что у строк ⚠/ℹ над ней,
# а не ширина окна — на широком окне итог и предупреждение переносились по-разному (F-4 живой проверки 15.10).
_ui_wb() { ga_wrap "$1" "$(( ${GA_UI_W:-76} - 4 ))" 6; }

_diagnose_screen() {
    local pf="" v line name state owned last unit mark bad=0 warn=0
    _DIAG_JS=$(_ga_quality_json)
    _screen_head "$(t mt_diag)" "$(t mt_diag_note)"
    # Без jq и на негодном ответе печатаем сырое: разбирать нечем, а молча
    # выдавать пустые поля за факты («демон не отвечает», «сети нет») нельзя —
    # человек примет решение по картине, которой не существует.
    if ! command -v jq >/dev/null 2>&1 || ! printf '%s' "$_DIAG_JS" | jq -e . >/dev/null 2>&1; then
        log_warning "$(t diag_raw_only)"
        printf '%s\n' "$_DIAG_JS"
        return 0
    fi

    # ── Система ──────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}${WHITE}$(t diag_sec_system)${NC}"
    # Docker словами: рассогласование версий из сырого JSON человек не выудит,
    # а именно оно и делает вид «всё выключено» на работающем сервере.
    # Строку версий печатаем, только когда версии есть: в сухом прогоне и на
    # сервере без демона она выходила пустой скорлупой «клиент  (API )».
    # Сообщение «демон не отвечает» — ровно одно, из одного места.
    local dj mism dver
    dj=$(_dq '.docker_info // empty'); [ "$dj" = null ] && dj=""
    dver=""; [ -n "$dj" ] && dver=$(jq -r '[.client_version // "", .daemon_version // ""] | join("")' <<<"$dj" 2>/dev/null)
    if [ -n "$dver" ]; then
        echo -e "  ${DIM}$(t docker_diag_title)${NC}: $(tf docker_diag_versions \
            "$(jq -r '.client_version // "-"' <<<"$dj")" "$(jq -r '.client_api // "-"' <<<"$dj")" \
            "$(jq -r '.daemon_version // "-"' <<<"$dj")" "$(jq -r '.daemon_api // "-"' <<<"$dj")")"
    fi
    if [ "$(_dq '.docker')" = true ]; then
        log_success "$(t diag_docker_ok)"
    else
        log_error "$(t docker_diag_unreachable)"; bad=$((bad + 1))
    fi
    if [ -n "$dj" ]; then
        local stl sbin sdmn ssince
        mism=$(jq -r '.mismatch' <<<"$dj" 2>/dev/null)
        # Пакет обновлён, а служба старая (DK-02) — версии и с какого времени; рассогласование API — частный случай.
        # Что показать: подпись (при одной версии — сборка), иначе версия; бинарь не узнать — версия клиента.
        IFS=$'\x1f' read -r stl sbin sdmn ssince <<<"$(jq -r '[(.stale // false | tostring),
            ([.binary_label, .binary_version, .client_version] | map(select(. != null and . != "")) | (.[0] // "?")),
            ([.daemon_label, .daemon_version] | map(select(. != null and . != "")) | (.[0] // "?")),
            (.stale_since // "")] | join("\u001f")' <<<"$dj" 2>/dev/null)"
        if [ "$stl" = true ]; then
            log_warning "$(_ui_w "$(tf docker_diag_stale "$sbin" "$sdmn")")"; warn=$((warn + 1))
            [ -n "$ssince" ] && log_dim "$(_ui_w "$(tf docker_diag_stale_since "$(ga_human_ts "$ssince")")")"
        elif [ "$mism" = "true" ]; then
            log_warning "$(_ui_w "$(t docker_diag_mismatch)")"; warn=$((warn + 1))
        fi
        if [ "$mism" = "true" ] && [ -n "$(jq -r '.api_pinned // ""' <<<"$dj")" ]; then
            log_dim "$(tf docker_diag_pinned "$(jq -r '.api_pinned' <<<"$dj")")"
        fi
    fi
    if [ "$(_dq '.ip_forward // "0"')" = "1" ]; then
        log_success "$(t diag_forward_on)"
    else
        log_error "$(_ui_w "$(t diag_forward_off)")"; bad=$((bad + 1))
    fi
    if [ "$(_dq '.network')" = true ]; then
        log_success "$(t diag_net_ok)"
    else
        log_warning "$(_ui_w "$(t diag_net_bad)")"; warn=$((warn + 1))
    fi
    # Работающий профиль без опубликованного порта: Docker говорит «Up», а до людей не доходит ни пакет
    # (находка LC-20). Раньше диагностика отвечала «замечаний нет».
    local _unpub
    _unpub=$(_dq '[.ports[]? | select(.published == false) | "\(.profile)\t\(.port)"] | .[]')
    if [ -n "$_unpub" ]; then
        while IFS=$'\t' read -r name v; do
            [ -n "$name" ] || continue
            log_error "$(_ui_w "$(tf diag_port_unpublished "$(_pr_name "$name" noport)" "$v")")"; bad=$((bad + 1))
        done <<<"$_unpub"
    elif [ "$(_dq '[.ports[]? | select(.published == true)] | length')" != 0 ]; then
        log_success "$(t diag_ports_published_ok)"
    fi
    # Соседи в сети контейнера, которого больше нет и которого нет ни в одном реестре (WRP-06): прокси рядом с goWARP
    # молчит, а продукт его не трогает — здесь хотя бы видно, кого и как вернуть.
    v=$(_dq '(.netdeps_dangling // []) | join(",")')
    if [ -n "$v" ]; then
        log_warning "$(_ui_w "$(tf diag_netdeps_dangling "$v")")"; warn=$((warn + 1))
    fi
    v=$(_dq '.disk_free_mb // 0'); [[ "$v" =~ ^[0-9]+$ ]] || v=0
    # Порог — самый большой в продукте (образ Amnezia, GA_AMN_MIN_DISK_MB): ниже
    # него не пройдёт обновление ядра, а бэкап ещё пройдёт.
    if [ "$v" -lt 1024 ]; then log_warning "$(_ui_w "$(tf diag_disk_low "$v")")"; warn=$((warn + 1)); else log_dim "$(tf diag_disk "$v")"; fi

    # ── Ключи сервера ────────────────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}${WHITE}$(t diag_sec_keys)${NC}"
    if [ "$(_dq '.server_keys | length')" = "0" ]; then
        log_dim "$(t diag_keys_none)"
    else
        while IFS=$'\t' read -r name v; do
            [ -n "$name" ] || continue
            if [ "$v" = true ]; then log_success "$(tf diag_keys_ok "$(_pr_name "$name")")"
            else log_error "$(_ui_w "$(tf diag_keys_bad "$(_pr_name "$name")")")"; bad=$((bad + 1)); fi
        done < <(_dq '.server_keys[]? | [.profile, (.ok|tostring)] | @tsv')
    fi

    # ── Таймеры ──────────────────────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}${WHITE}$(t diag_sec_timers)${NC}"
    local foreign=0 site_le=0
    _site_domain_ready && site_le=1
    while IFS=$'\t' read -r name state owned last unit; do
        [ -n "$name" ] || continue
        case "$state" in
            active)   mark="${GREEN}✓${NC}"; v="$(t diag_state_active)" ;;
            inactive) v="$(t diag_state_inactive)"; mark="${RED}✗${NC}"; [ "$owned" = true ] || mark="${YELLOW}⚠${NC}" ;;
            missing)  v="$(t diag_state_missing)"; mark="${RED}✗${NC}"; [ "$owned" = true ] || mark="${YELLOW}⚠${NC}" ;;
            *)        mark="${DIM}·${NC}"; v="$(t diag_state_dry)" ;;
        esac
        # Продлевать нечего, пока нет сайта на домене с сертификатом Let's Encrypt: в «Только VPN» «⚠ cert-renew
        # юнита нет» пугало поломкой, которой нет (находка NC-21 критика-новичка).
        if [ "$name" = cert-renew ] && [ "$site_le" != 1 ] && [ "$state" != active ]; then
            mark="${DIM}·${NC}"; v="$(t diag_timer_not_needed)"
        fi
        case "$mark" in *✗*) bad=$((bad + 1)) ;; *⚠*) warn=$((warn + 1)) ;; esac
        line=$(printf '  %b %-11s %-14s' "$mark" "$name" "$v")
        # «Чужой» — про ЮНИТ, а не про то, какой модуль его ставит. Ночная копия
        # и бюджет журналов — наши таймеры, просто поставленные не этим модулем;
        # называть их чужими значит пугать человека своим же хозяйством
        # (DEFECTS §5.8). Настоящий чужой тут один — certbot.timer.
        case "$unit" in
            goamnezia-*) ;;
            *) line="$line ${DIM}($(t diag_timer_foreign): $unit)${NC}"; foreign=1 ;;
        esac
        echo -e "$line"
        # Таймер «работает», а служба падает на каждом тике — видно только здесь.
        if [ -n "$last" ] && [ "$last" != success ] && [ "$last" != "-" ]; then
            echo -e "      ${RED}✗ $(tf diag_timer_failed "$last")${NC}"; bad=$((bad + 1))
        fi
    done < <(_dq '.timers[]? | [.name, .state, (.owned|tostring), ((.last // "") | if . == "" then "-" else . end), .timer] | @tsv')
    # Что значит «чужой» — только когда такая строка есть: абзац про него на экране, где чужих нет, был загадкой (NC-21)
    [ "$foreign" = 1 ] && echo -e "  ${DIM}$(ga_wrap "$(t diag_timers_note)" "${GA_UI_W:-76}" 2)${NC}"

    # Человеку таблица портов понятнее сырого JSON: тот же экран ✓/✗/⚠, что в
    # мастере, без заголовка и нумерации (brief). Повторный сбор данных — один
    # ss и один docker ps, это дешевле, чем тащить весь ответ через quality.
    if type preflight_modes >/dev/null 2>&1; then
        pf=$(preflight_modes 2>/dev/null) || pf=""
        # Экран диагностики ничего не читает и заканчивается паузой, поэтому
        # подсказки «повторить проверку — цифра» тут быть не должно: нажатая
        # цифра проваливалась в меню «Обслуживание» и открывала пункт с тем же
        # номером. Пустое значение прячет строку целиком.
        if [ -n "$pf" ]; then
            # Причины (✗) и предупреждения (⚠) проверки портов — в тот же итог
            v=$(printf '%s' "$pf" | jq -r '[(.pro.reasons // [] | length), (.warnings // [] | length)] | @tsv' 2>/dev/null)
            IFS=$'\t' read -r name state <<<"$v"
            [[ "$name" =~ ^[0-9]+$ ]] || name=0
            [[ "$state" =~ ^[0-9]+$ ]] || state=0
            bad=$((bad + name)); warn=$((warn + state))
            # На поставленном сервере выбор режимов установки — шум посреди сводки (A-14 критика 16.10): блок
            # только при неполадках портов; до установки — как прежде, всегда.
            if [ "$(_cfg .installed)" != true ] || [ "$name" -gt 0 ] || [ "$state" -gt 0 ]; then
                GA_PF_AGAIN_ITEM="" preflight_render_modes "$pf" brief
            else
                pf=""
            fi
        fi
    fi
    # Итог словами — последней строкой: экран заканчивался блоком режимов, и где-то посередине терялось, есть ли
    # вообще неполадки (находка NC6-07 критика-новичка). Блок режимов сам кончается пустой строкой.
    [ -n "$pf" ] || echo ""
    if [ "$bad" -gt 0 ]; then
        echo -e "  ${BOLD}$(tf diag_summary_bad "$bad")${NC}"
    elif [ "$warn" -gt 0 ]; then
        echo -e "  ${BOLD}$(t diag_summary_warn)${NC}"
    else
        echo -e "  ${BOLD}${GREEN}$(t diag_summary_ok)${NC}"
    fi
    # Строки «те же данные целиком: install.sh --action=quality --json» больше нет: команда моста — для бота, панели и
    # агентов, человеку с ней делать нечего (NC-21).
}

# ══════════════════════════════════════════════════════════════════════════════
# Раздел 5: Настройки
# ══════════════════════════════════════════════════════════════════════════════

submenu_settings() {
    local ch
    while true; do
        _screen_head "$(t menu_settings)"
        # Было десять пунктов вперемешку: сайт, DNS, панель, админы, язык,
        # Endpoint, о программе, агенты, «удалить всё». Собрано по смыслу: что
        # получают клиенты (DNS и адрес в ключах) и кто управляет сервером
        # (панель, админы бота, доступы агентов).
        echo -e "  ${CYAN}1${NC}) $(t se_mode_site)"
        echo -e "  ${CYAN}2${NC}) $(t se_clients_menu)"
        echo -e "  ${CYAN}3${NC}) $(t se_access_menu)"
        echo -e "  ${CYAN}4${NC}) $(t se_lang)"
        echo -e "  ${CYAN}5${NC}) $(t se_about)"
        echo -e "  ${CYAN}6${NC}) $(t se_mirror)"
        echo -e "  ${CYAN}7${NC}) ${RED}$(t se_wipe)${NC}"
        echo -e "  ${CYAN}0${NC}) $(t back)"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0

        case "$ch" in
            1) _mode_site_screen ;;
            2) _clients_menu ;;
            3) _access_menu ;;
            4) _language_interactive ;;
            5) _about_screen ;;
            6) _mirror_screen ;;
            7) _wipe_everything ;;
            0) GA_BACK=1; break ;;
            "") continue ;;
            *) log_error "$(t invalid_choice)" ;;
        esac

        _pause
    done
}

# Что получают клиенты: серверы имён в конфиге и адрес, который уедет в ключ.
# Два вопроса про одно и то же — куда пойдёт клиент, — и в плоском списке
# настроек они стояли врозь, между панелью и «о программе».
_clients_menu() {
    local ch
    while true; do
        _screen_head "$(t se_clients_menu)" "$(t se_clients_menu_note)"
        echo -e "  ${CYAN}1${NC}) $(t se_dns)"
        echo -e "  ${CYAN}2${NC}) $(t se_endpoint)"
        echo -e "  ${CYAN}0${NC}) $(t back)"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0
        case "$ch" in
            1) _dns_interactive ;;
            2) _endpoint_interactive ;;
            0) GA_BACK=1; return 0 ;;
            "") continue ;;
            *) log_error "$(t invalid_choice)" ;;
        esac
        _pause
    done
}

# Веб-панель, админы бота, ИИ-агенты: панель, админы бота, доступы ИИ-агентов. Три разных
# двери в одно и то же управление — и в списке настроек они тоже стояли врозь.
_access_menu() {
    local ch
    while true; do
        _screen_head "$(t se_access_menu)" "$(t se_access_menu_note)"
        echo -e "  ${CYAN}1${NC}) $(t se_panel)"
        echo -e "  ${CYAN}2${NC}) $(t se_admins)"
        echo -e "  ${CYAN}3${NC}) $(t se_agents)"
        echo -e "  ${CYAN}0${NC}) $(t back)"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0
        case "$ch" in
            1) _panel_screen ;;
            2) _bot_admins_screen ;;
            3) _agents_screen ;;
            0) GA_BACK=1; return 0 ;;
            "") continue ;;
            *) log_error "$(t invalid_choice)" ;;
        esac
        _pause
    done
}

# DNS для клиентских конфигов. Один экран на мастер и на настройки: набор
# вариантов обязан совпадать, иначе «как при установке» перестаёт работать.
# _dns_pick [--menu] — выбор адресов серверов имён.
#
# В МАСТЕРЕ первой установки Enter означает «оставь как предложено», и умолчание
# законно: человек только что согласился на весь набор умолчаний.
#
# В МЕНЮ настроек тот же Enter означал «перезапиши то, что у меня настроено» —
# и переписывал, молча, с записью в аудит и словом «сохранено». Так же вела себя
# любая опечатка и даже «0», которым во всём продукте выходят назад. Настроенный
# 8.8.8.8 превращался в Cloudflare, и человек об этом не узнавал.
#
# Поэтому с --menu: показываем текущее значение, добавляем выход, а Enter,
# «0» и непонятный ввод НИЧЕГО НЕ МЕНЯЮТ.
_dns_pick() {
    local ch d1 d2 menu=0
    [ "${1:-}" = "--menu" ] && menu=1
    echo "" >&2
    echo -e "  ${BOLD}${WHITE}$(t wz_dns_title)${NC}" >&2
    if [ "$menu" = 1 ]; then
        local cur1 cur2
        cur1=$(_cfg '.client_dns[0]'); cur2=$(_cfg '.client_dns[1]')
        [ -n "$cur1" ] && echo -e "  ${DIM}$(tf se_dns_current "$cur1" "${cur2:--}")${NC}" >&2
    fi
    echo -e "  ${CYAN}1${NC}) $(t wz_dns_cf)" >&2
    echo -e "  ${CYAN}2${NC}) $(t wz_dns_google)" >&2
    echo -e "  ${CYAN}3${NC}) $(t wz_dns_adguard)" >&2
    echo -e "  ${CYAN}4${NC}) $(t wz_dns_custom)" >&2
    [ "$menu" = 1 ] && echo -e "  ${CYAN}0${NC}) $(t back)" >&2
    echo -ne "  ${WHITE}$(t choose):${NC} " >&2
    read -r ch || ch=""
    if [ "$menu" = 1 ]; then
        case "$ch" in
            1|2|3|4) ;;
            *) printf '%s' "__GA_DNS_KEEP__"; return 0 ;;
        esac
    fi
    case "$ch" in
        2) d1="8.8.8.8";        d2="8.8.4.4" ;;
        3) d1="94.140.14.14";   d2="94.140.15.15" ;;
        4)
            # Проверка по ЗНАЧЕНИЮ октетов (_valid_ip), а не по виду: старая
            # регулярка пропускала 999.999.999.999, и такой адрес доезжал до
            # конфига, а в ключ не попадал — экран показывал одно, клиент
            # получал другое. §0.8 договора запрещает этот образец прямо.
            # ga_ask возвращает 1 на «0» (назад) и 2 после трёх промахов. В МЕНЮ
            # оба случая означают «человек передумал», и подставлять ему
            # умолчание нельзя: прошлая починка закрыла выбор пункта, а этот
            # уровень пропустила — «0» внутри «свой адрес» по-прежнему заменял
            # настроенное на Cloudflare и печатал «сохранено».
            if ! d1=$(ga_ask "DNS 1" "$GA_RE_IPV4" "$(t se_dns_bad)"); then
                [ "$menu" = 1 ] && { printf '%s' "__GA_DNS_KEEP__"; return 0; }
                d1=""
            fi
            # «0 — назад» и три опечатки у второго адреса — тоже «передумал», как у первого: раньше настройка всё
            # равно сохранялась без второго DNS (находка SR-53). Enter — законное «второго нет».
            local rc2=0
            d2=$(ga_ask_optional "DNS 2" "$GA_RE_IPV4" "$(t se_dns_bad)") || rc2=$?
            if [ "$rc2" != 0 ]; then
                [ "$menu" = 1 ] && { printf '%s' "__GA_DNS_KEEP__"; return 0; }
                d2=""
            fi
            ;;
        *) d1="1.1.1.1";        d2="1.0.0.1" ;;
    esac
    _valid_ip "$d1" || d1="1.1.1.1"
    _valid_ip "$d2" || d2=""
    printf '%s %s' "$d1" "$d2"
}

_dns_interactive() {
    local pair d1 d2
    pair=$(_dns_pick --menu)
    # Ничего не выбрали — ничего и не трогаем. Прежде Enter, «0» и опечатка
    # одинаково переписывали настроенное умолчанием и печатали «сохранено».
    if [ "$pair" = "__GA_DNS_KEEP__" ]; then
        GA_BACK=1   # назад без лишнего «Нажмите Enter» (SR-55)
        return 0
    fi
    d1="${pair%% *}"; d2="${pair#* }"
    [ "$d2" = "$d1" ] && d2=""
    # Через тот же модуль, что и мост: одна проверка, один аудит, одно
    # поведение во всех интерфейсах. Своя сборка JSON здесь была второй копией
    # договора, и она разошлась с первой (docs/DEFECTS.md §1c.2).
    # Итог печатает модуль («DNS в новых ключах: …») — второй строки успеха на то же действие не нужно
    # (находка SR-38); своя строка — только в запасном пути без модуля.
    if type ga_set_client_dns >/dev/null 2>&1; then
        ga_set_client_dns "$d1" "$d2" >/dev/null
    elif _cfg_merge_dns "$d1" "$d2"; then
        if [ -n "$d2" ]; then log_success "$(tf se_dns_saved "$d1" "$d2")"; else log_success "$(tf se_dns_saved_one "$d1")"; fi
    fi
    _note_only_new_keys
}

# Настройка действует ТОЛЬКО на ключи, выданные после неё. Строка одна на все
# три таких экрана (DNS, MTU, Endpoint): раньше её печатал один экран из трёх,
# и человек менял адрес серверов имён, а выданные ключи оставались со старым —
# без единого слова о том, что их надо выдать заново.
_note_only_new_keys() { log_dim "$(t se_only_new_keys)"; }

_cfg_merge_dns() {
    local d1="$1" d2="$2" json
    command -v jq >/dev/null 2>&1 || { log_error "$(t err_no_jq)"; return 1; }
    json=$(jq -nc --arg a "$d1" --arg b "$d2" '{client_dns: ([$a,$b] | map(select(. != "")))}') || return 1
    if type ga_config_merge >/dev/null 2>&1; then
        ga_config_merge "$json"
    else
        log_error "$(tf module_missing ga_config_merge)"; return 1
    fi
}

_language_interactive() {
    local chosen
    if type pick_language_interactive >/dev/null 2>&1; then
        # «0», пустой Enter и опечатка — это «передумал»: ничего не пишем и
        # говорим об этом, а не молча переключаем язык всего продукта.
        chosen=$(pick_language_interactive) || { log_info "$(t cancelled)"; return 1; }
        [ -n "$chosen" ] || { log_info "$(t cancelled)"; return 1; }
        # Не записалось (место, права) — причину save_language уже сказал; «сохранён» тут было бы неправдой (OPS-04).
        if type save_language >/dev/null 2>&1; then save_language "$chosen" || return 1; fi
        type load_language >/dev/null 2>&1 && load_language "$chosen"
        log_success "$(tf se_lang_saved "$chosen")"
    else
        log_error "$(tf module_missing pick_language_interactive)"
    fi
}

# Что стоит в Endpoint ключей сейчас и что встанет при пустом поле — для status (бот, панель). Считает
# та же функция, что собирает ключ: экран, угадывавший адрес сам, обещал домен, пока в ключах стоял IP.
# Адрес сервера можно передать первым аргументом: status и экран спрашивают его один раз, а не на каждого
# помощника (на сервере без выхода наружу каждый поход — таймаут).
_endpoint_effective() {
    local ip
    if [ "$#" -gt 0 ]; then ip="$1"; else ip=$(_server_ip); fi
    type ga_export_endpoint_host >/dev/null 2>&1 || { _cfg '.endpoint_host'; return 0; }
    GA_EXPORT_SERVER_IP="$ip" ga_export_endpoint_host 2>/dev/null || true
}
# Хосты для «Ключа на другой адрес» (status.key_hosts): то, что примет user-key --endpoint; без сети.
# Ровно один JSON: прежнее `… | jq -sc . || echo '[]'` при ненулевом коде ga_export_key_hosts (pipefail) печатало
# И список, И []; в ответе status второй текст сдвигал все следующие поля @json на одно (update_rollback
# получал [] вместо null).
_key_hosts_json() {
    local js=""
    if type ga_export_key_hosts >/dev/null 2>&1; then
        js=$( { ga_export_key_hosts 2>/dev/null || true; } | jq -R . | jq -sc . 2>/dev/null) || js=""
    fi
    printf '%s\n' "${js:-[]}"
}

_endpoint_auto() {
    local ip d=""
    if [ "$#" -gt 0 ]; then ip="$1"; else ip=$(_server_ip); fi
    if type ga_export_pro_domain >/dev/null 2>&1; then
        d=$(ga_export_pro_domain 2>/dev/null) || d=""
    fi
    printf '%s' "${d:-$ip}"
}

# Адрес сервера в ключах (Endpoint). Экран, а не голый вопрос: прежнее «Хост для Endpoint (пусто — IP
# сервера, 0 — назад)» владелец 17.09.2026 назвал непонятной настройкой — не было видно ни что стоит в
# ключах сейчас, ни что даст пустой ответ. Теперь сверху — что в ключах и откуда оно, ниже — пункты
# цифрами: по умолчанию (в Pro домен, иначе IP сервера), IP сервера, свой домен или IP. Выбор того, что
# уже стоит, ничего не пишет.
_endpoint_interactive() {
    local host ip auto domain now pinned src label ch i
    local -a opts=() vals=()
    type ga_set_endpoint_host >/dev/null 2>&1 || { log_error "$(tf module_missing ga_set_endpoint_host)"; return 1; }
    ip=$(_server_ip)
    auto=$(_endpoint_auto "$ip")
    domain=$(_cfg '.domain')
    now=$(_endpoint_effective "$ip")
    pinned=$(_cfg '.endpoint_host')
    [ "$pinned" = null ] && pinned=""
    src=default
    [ -n "$pinned" ] && src=manual
    _screen_head "$(t se_endpoint)" "$(t se_endpoint_note)"
    echo -e "  $(t se_endpoint_now): ${CYAN}${now:--}${NC} ${DIM}· $(t "se_endpoint_src_${src}")${NC}"
    # Домен есть, а в ключи по умолчанию не идёт (режим не Pro) — говорим, почему, чтобы «По умолчанию — IP»
    # на сервере с доменом не выглядело поломкой.
    if [ -n "$domain" ] && [ "$domain" != null ] && [ "$auto" != "$domain" ] && [ "$now" != "$domain" ]; then
        echo -e "  ${DIM}$(ga_wrap "$(tf se_endpoint_domain_not_default "$domain")" "${GA_UI_W:-76}" 2)${NC}"
    fi
    echo -e "  ${DIM}$(ga_wrap "$(t se_endpoint_why)" "${GA_UI_W:-76}" 2)${NC}"
    echo -e "  ${DIM}$(_rule)${NC}"
    if [ -n "$auto" ] && [ "$auto" != "$ip" ]; then
        label=$(tf se_endpoint_opt_default_domain "$auto")
    else
        label=$(tf se_endpoint_opt_default_ip "${ip:--}")
    fi
    [ -z "$pinned" ] && label+=" · $(t user_address_current_mark)"
    opts+=("$label"); vals+=("")
    # «IP сервера» вписывает адрес в поле. Пункт нужен, когда по умолчанию не IP или вписано что-то своё; в
    # Lite без вписанного адреса он повторял бы первый.
    if [ -n "$ip" ] && [ "$ip" != 0.0.0.0 ] && { [ "$auto" != "$ip" ] || [ -n "$pinned" ]; }; then
        label=$(tf se_endpoint_opt_ip "$ip")
        [ "$pinned" = "$ip" ] && label+=" · $(t user_address_current_mark)"
        opts+=("$label"); vals+=("$ip")
    fi
    label=$(t se_endpoint_opt_manual)
    [ -n "$pinned" ] && [ "$pinned" != "$ip" ] && label+=" · $(t user_address_current_mark)"
    opts+=("$label"); vals+=("__manual__")
    for ((i = 0; i < ${#opts[@]}; i++)); do
        echo -e "  ${CYAN}$((i + 1))${NC}) ${opts[$i]}"
    done
    echo -e "  ${CYAN}0${NC}) $(t back)"
    echo -e "  ${DIM}$(_rule)${NC}"
    echo -ne "  ${WHITE}$(t choose):${NC} "
    read -r ch || ch=0
    case "$ch" in ""|0) GA_BACK=1; return 0 ;; esac
    if ! [[ "$ch" =~ ^[0-9]{1,2}$ ]] || [ $((10#$ch)) -lt 1 ] || [ $((10#$ch)) -gt "${#opts[@]}" ]; then
        log_error "$(t invalid_choice)"
        return 1
    fi
    host="${vals[$((10#$ch - 1))]}"
    if [ "$host" = "__manual__" ]; then
        # «0» и пустой ответ — назад. У пустого ответа больше нет тайного смысла «IP сервера».
        host=$(ga_ask_optional "$(t se_endpoint_ask)" \
            '^(0|[a-z0-9](-*[a-z0-9])*(\.[a-z0-9](-*[a-z0-9])*)+|([0-9]{1,3}\.){3}[0-9]{1,3})$' \
            "$(t se_endpoint_bad)") || { log_info "$(t cancelled)"; return 1; }
        if [ -z "$host" ] || [ "$host" = 0 ]; then
            GA_BACK=1
            return 1
        fi
        # Достижимость — до записи: опечатка в домене иначе проходила молча, и ни один ключ, выданный после
        # неё, не соединялся — причину искали в параметрах обфускации.
        _endpoint_check "$host" || { log_info "$(t cancelled)"; return 1; }
    fi
    if [ "$host" = "$pinned" ]; then
        log_info "$(tf se_endpoint_same "${now:--}")"
        return 0
    fi
    ga_set_endpoint_host "$host" >/dev/null \
        && _note_only_new_keys   # модуль уже сказал, какой адрес записан
}

# Проверка хоста для Endpoint. rc 0 — писать можно (всё сошлось или человек
# настоял), rc 1 — передумал.
#
# Отказать наотрез нельзя: домен бывает заведён заранее, A-запись ещё не
# разошлась, а сервер за NAT честно отвечает не тем адресом, который видит
# мир. Поэтому расхождение — вопрос, а не запрет; молчание — то, чего быть не
# должно.
_endpoint_check() {
    local host="${1:-}" ip resolved
    # Пусто — законный ответ «по умолчанию» (в Pro домен сервера, иначе его IP), проверять нечего.
    [ -n "$host" ] || return 0
    ip=$(_server_ip)
    if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        # Адрес по ЗНАЧЕНИЮ, одной функцией продукта (договор §0.8).
        if type _valid_ip >/dev/null 2>&1 && ! _valid_ip "$host"; then
            log_error "$(t se_endpoint_bad)"; return 1
        fi
        # Свой — любой внешний адрес машины, а не только основной: у сервера с
        # несколькими адресами второй адрес в ключе — законный выбор (замечание
        # критика). Список — тот же, с которым сверяются A-записи домена.
        local own=""
        type ga_site_own_ips >/dev/null 2>&1 && own=$(ga_site_own_ips 2>/dev/null)
        [ -n "$own" ] || own="$ip"
        if [ -n "$own" ] && [ "$ip" != "0.0.0.0" ] && ! grep -qxF -- "$host" <<<"$own"; then
            log_warning "$(tf se_endpoint_not_server "$host" "$(tr '\n' ' ' <<<"$own" | sed 's/ $//; s/ /, /g')")"
            confirm "$(t se_endpoint_use_anyway)" || return 1
        fi
        return 0
    fi
    if ! type ga_site_dns_state >/dev/null 2>&1 || ! command -v dig >/dev/null 2>&1; then
        # Спросить не у кого — говорим об этом, а не делаем вид, что проверили.
        log_dim "$(t se_endpoint_no_dig)"
        return 0
    fi
    # Все A-записи против всех адресов машины: у домена их может быть несколько
    # (адрес на каждый интерфейс), и клиенты разойдутся по ним круговым DNS.
    local js st
    js=$(ga_site_dns_state "$host" 2>/dev/null) || js=""
    st=$(jq -r '.state // "unknown"' <<<"$js" 2>/dev/null) || st=unknown
    case "$st" in
        none)
            log_warning "$(tf se_endpoint_no_dns "$host")"
            confirm "$(t se_endpoint_use_anyway)" || return 1 ;;
        elsewhere|partial)
            if [ "$(jq -r '.cloudflare' <<<"$js" 2>/dev/null)" = true ]; then
                log_warning "$(tf website_dns_cloudflare "$host")"
            elif [ "$st" = elsewhere ]; then
                log_warning "$(tf se_endpoint_dns_other "$host" "$(ga_site_dns_list "$js" .a)" "$(ga_site_dns_list "$js" .own)")"
            else
                log_warning "$(tf se_endpoint_dns_partial "$host" "$(ga_site_dns_list "$js" .foreign)")"
            fi
            confirm "$(t se_endpoint_use_anyway)" || return 1 ;;
        ok)
            log_dim "$(tf se_endpoint_dns_ok "$host" "$(ga_site_dns_list "$js" .a)")" ;;
        *)
            # DNS не ответил — проверить не вышло: как и при пустом ответе,
            # спрашиваем, а не записываем молча.
            log_warning "$(tf website_dns_unknown "$host")"
            confirm "$(t se_endpoint_use_anyway)" || return 1 ;;
    esac
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# Настройки → Режим и сайт (Pro-обвязка, lib/website.sh)
# ══════════════════════════════════════════════════════════════════════════════
# Модуль сам пишет config.json под замком и печатает ход дела в stderr; здесь
# только экраны, вопросы и подтверждения. Ни одна функция модуля не зовётся под
# спиннером: certbot и клон шаблона идут до минуты и печатают подсказки.

_site_require() {
    type website_enable_pro >/dev/null 2>&1 && return 0
    log_error "$(tf module_missing website_enable_pro)"
    return 1
}
_site_is_pro() { [ "$(_cfg '.mode')" = "pro" ]; }
# Сайт есть в ОБОИХ старших режимах: и во втором, и в третьем. Отличаются они
# только тем, где стоит AmneziaWG (свой порт против UDP/443 рядом с сайтом).
_site_has_site() { case "$(_cfg '.mode')" in pro|lite_site) return 0 ;; *) return 1 ;; esac; }
# Вид сертификата, которым сайт отдаётся сейчас: letsencrypt | selfsigned | "".
# Пустое поле у режима с сайтом читаем как letsencrypt — как и модуль сайта:
# старые установки его не писали, и «неизвестно» не должно молча превращать
# домен в запасной путь.
_site_cert_kind() {
    case "$(_cfg '.site.cert')" in
        letsencrypt) printf 'letsencrypt' ;;
        selfsigned)  printf 'selfsigned' ;;
        *) if _site_has_site; then printf 'letsencrypt'; else printf ''; fi ;;
    esac
}
# Сайт стоит на домене с настоящим сертификатом? Всё, чему нужен доверенный TLS
# (панель на домене, адреса агентов, ссылки в боте), решается по этому признаку,
# а не по режиму: самоподписанный — запасной путь, и он есть в обоих режимах.
_site_domain_ready() {
    [ "$(_site_cert_kind)" = "letsencrypt" ] && [ -n "$(_cfg '.domain')" ]
}
_site_panel_url() { printf 'https://%s/%s/' "$1" "$2"; }

# _panel_path_masked <путь панели> → «app-AbCd••••••WxYz»: префикс, первые и последние четыре знака секрета, середина
# скрыта, как номер карты. Восемь видимых знаков из 86 — меньше 50 бит из 512: угадывать остальное бесполезно, а свой
# адрес по ним узнаётся (после «Сменить адрес» видно, что он новый). Короткий путь прежнего формата — только префикс.
_panel_path_masked() {
    local p="${1:-}" pre="" sec
    case "$p" in app-*) pre="app-"; sec="${p#app-}" ;; *) sec="$p" ;; esac
    if [ "${#sec}" -ge 16 ]; then
        printf '%s%s••••••%s' "$pre" "${sec:0:4}" "${sec: -4}"
    else
        printf '%s••••••' "$pre"
    fi
}

# _panel_reveal — F1 (или «п») в главном меню: адрес панели целиком в шапке на GA_PANEL_REVEAL_SECS (5 минут), потом
# снова маска — шапка перерисовывается раз в 30 с. В журнал не пишется. 0 — показано (перерисовать сразу, без паузы);
# 1 — панели на домене нет, сказано отдельным экраном (дальше обычная пауза).
_panel_reveal() {
    local domain ppath
    domain=$(_cfg '.domain'); ppath=$(_cfg '.panel.miniapp_path')
    if [ -z "$domain" ] || [ -z "$ppath" ] || ! _panel_service_installed; then
        _screen_head "$(t dash_panel_reveal_title)"
        log_info "$(t dash_panel_reveal_off)"
        return 1
    fi
    GA_PANEL_REVEAL_UNTIL=$(( $(date +%s) + ${GA_PANEL_REVEAL_SECS:-300} ))
    return 0
}

# Человеческое имя режима (PLAN §4.3). case, а не подстановка в имя ключа: так
# tests/check_i18n_ssh.py видит каждый ключ и проверяет оба языка.
_mode_name() {
    case "${1:-}" in
        pro)       t ms_mode_name_pro ;;
        lite_site) t ms_mode_name_lite_site ;;
        *)         t ms_mode_name_lite ;;
    esac
}
# Текущий режим одним из трёх слов: пусто и мусор в config.json читаем как lite
_mode_current() {
    local m
    m=$(_cfg '.mode')
    case "$m" in pro|lite_site) printf '%s' "$m" ;; *) printf 'lite' ;; esac
}

# Срок сертификата для шапки: «до <дата> (ещё N дн.)» или «нет».
_site_cert_line() {
    local domain="${1:-}" exp=""
    if [ -n "$domain" ] && type website_cert_expiry >/dev/null 2>&1; then
        exp=$(website_cert_expiry "$domain" 2>/dev/null) || exp=""
    fi
    # Дата — через ga_human_ts, как на экране проверки сайта: сырой штамп «2026-12-23T19:30:54Z»
    # человеку читать незачем (находка T28).
    if [ -n "$exp" ]; then tf ms_cert_days "$(ga_human_ts "${exp%% *}")"; else t ms_cert_none; fi
}

# Шаблон для шапки: «Имя (id)», только id или «не развёрнут».
_site_template_line() {
    local js id name
    js=$(website_current_template 2>/dev/null) || js=""
    id=$(printf '%s' "$js" | jq -r '.template_id // ""' 2>/dev/null)
    name=$(printf '%s' "$js" | jq -r '.name // ""' 2>/dev/null)
    if [ -z "$id" ]; then t ms_template_none
    elif [ -n "$name" ]; then printf '%s (%s)' "$name" "$id"
    else printf '%s' "$id"; fi
}

# Подсказка про DNS до включения Pro: не отказ (DNS мог не разойтись), но
# человек должен знать заранее, иначе Let's Encrypt откажет уже после ожидания.
#
# Сравнение — набором: у домена может быть несколько A-записей, по одной на
# каждый адрес машины (как в goTelegram), и первая в ответе DNS — случайная.
# Сама проверка и тексты — в модуле (website_dns_hint), одни на все экраны.
_site_dns_hint() {
    local domain="$1"
    command -v dig >/dev/null 2>&1 || return 0
    type website_dns_hint >/dev/null 2>&1 || return 0
    website_dns_hint "$domain" || true
    return 0
}

# Три строки перед вопросом о домене, когда домена ещё нет (находка NC-10 критика-новичка): «Домен, который указывает
# на этот сервер» не говорил ни что такое A-запись, ни где взять домен. Адрес — тот, по которому человек зашёл
# (входящие на него доходят), иначе адрес сервера из настроек. Всё — в stderr: stdout у вызывающих — ответ.
_domain_help() {
    local ip rec
    ip=$(_ssh_inbound_ip 2>/dev/null) || ip=""
    [ -n "$ip" ] || ip=$(_server_ip)
    if [ -n "$ip" ]; then rec=$(tf domain_help_a_record "$ip"); else rec=$(t domain_help_a_record_noip); fi
    echo -e "  ${DIM}$(ga_win_wrap "$(t domain_help_what)" 2)${NC}" >&2
    echo -e "  ${DIM}$(ga_win_wrap "$rec" 2)${NC}" >&2
    echo -e "  ${DIM}$(ga_win_wrap "$(t domain_help_wait)" 2)${NC}" >&2
}

# Спросить домен (stdout — домен в нижнем регистре; UI — stderr). Enter при
# заданном умолчании оставляет его; пустой ввод без умолчания — отмена (rc 1).
_site_ask_domain() {
    local def="${1:-}" domain prompt
    [ -n "$def" ] || _domain_help
    if [ -n "$def" ]; then prompt=$(tf ms_domain_ask_default "$def"); else prompt=$(t wz_domain_ask); fi
    domain=$(ga_ask "$prompt" '^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$' \
        "$(t wz_domain_bad)" "$def") || return $?
    domain="${domain,,}"
    [ "${#domain}" -le 253 ] || { log_error "$(t wz_domain_bad)"; return 1; }
    _site_dns_hint "$domain"
    printf '%s' "$domain"
}

# Домен при переходе в режим с сайтом — как в мастере: Enter — прежний домен (или без домена),
# 0 — назад. Раньше вопрос был обязательным, Enter давал ошибку, а «0 — назад» вёл ВПЕРЁД — к
# подтверждению перехода без домена (находки критика UX и LC-14, 25.09.2026). rc 1 — отмена.
_site_ask_domain_optional() {
    local def="${1:-}" v prompt
    local re='^(0|([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,})$'
    [ -n "$def" ] || _domain_help
    if [ -n "$def" ]; then prompt=$(tf wz_domain_ask_keep "$def"); else prompt=$(t wz_domain_ask_wizard); fi
    v=$(ga_ask_optional "$prompt" "$re" "$(t wz_domain_bad)") || return 1
    [ "$v" = 0 ] && return 1
    [ -n "$v" ] || v="$def"
    v="${v,,}"
    if [ -n "$v" ]; then
        [ "${#v}" -le 253 ] || { log_error "$(t wz_domain_bad)"; return 1; }
        _site_dns_hint "$v"
    fi
    printf '%s' "$v"
}

# Указывает ли A-запись домена на этот сервер. rc 0 — да; 1 — нет или не узнать
# (нет dig, домен ещё не разошёлся). По нему мастер и экран режима решают,
# выпускать ли Let's Encrypt сразу или пока поднять сайт на запасном
# самоподписанном сертификате и предложить выпустить настоящий позже.
#
# «Указывает сюда» — ВСЕ A-записи ведут на адреса этой машины (одна или
# несколько). Раньше сравнивалась только первая запись с одним адресом сервера,
# и домен с двумя адресами этого же сервера в половине случаев уводил мастер на
# самоподписанный сертификат. Если часть записей чужая, Let's Encrypt может
# проверять по чужому адресу: отказ тратит лимит попыток, а сорвавшийся выпуск
# оставлял сервер вовсе без сайта. Поэтому такой домен — «DNS ещё не готов»:
# сайт встаёт на запасном сертификате, а подсказка называет чужие адреса
# (замечание критика).
_site_dns_points_here() {
    local domain="${1:-}" st
    [ -n "$domain" ] || return 1
    # Стенд (dry-run) в сеть не ходит. Без подставного ответа (GOAMNEZIA_DNS_STUB) считаем,
    # что домен указывает сюда: сухие прогоны идут основным путём. С подставным — честная
    # проверка, чтобы запасной путь тоже был достижим в тестах (находка SR-54).
    if ga_dry; then
        [ -n "${GOAMNEZIA_DNS_STUB+x}" ] || return 0
    else
        command -v dig >/dev/null 2>&1 || return 1
    fi
    type ga_site_dns_state >/dev/null 2>&1 || return 1
    st=$(ga_site_dns_state "$domain" 2>/dev/null | jq -r '.state // ""' 2>/dev/null) || st=""
    [ "$st" = ok ]
}

# Поднять сайт в режиме <mode> на домене <domain>. Основной путь — Let's Encrypt;
# самоподписанный остаётся ЗАПАСНЫМ ровно для двух случаев, названных владельцем:
# домена нет или A-запись ещё не указывает на сервер. Боевой сертификат на домен
# выпускается ОДИН раз (правило владельца, лимиты Let's Encrypt): повторные
# прогоны гоняются через GOAMNEZIA_LE_STAGING=1, и сам модуль живой сертификат
# не перевыпускает. rc 0 — сайт поднят (пусть и на запасном сертификате).
_site_bring_up() {
    local mode="$1" domain="${2:-}" ask_tpl="${3:-1}" tpl_before tpl_after
    tpl_before=$(_cfg '.site.template_id')
    if [ -z "$domain" ]; then
        # Домена нет вовсе — запасной путь и честная строка, чего человек лишается
        log_warning "$(t ms_no_domain_fallback)"
        website_enable_site_selfsigned "" "$mode" || { log_warning "$(t wz_site_failed_hint)"; return 1; }
    elif _site_dns_points_here "$domain"; then
        website_enable_pro "$domain" "" "$mode" || { log_warning "$(t wz_pro_failed_hint)"; return 1; }
        _panel_ensure_service || true
    else
        # Домен есть, но A-запись ещё не разошлась: certbot откажет, а сайт нужен
        # уже сейчас. Поднимаем на запасном и говорим, каким пунктом выпустить
        # настоящий, когда DNS дойдёт.
        log_warning "$(tf ms_dns_not_ready_fallback "$domain")"
        website_enable_site_selfsigned "" "$mode" || { log_warning "$(t wz_site_failed_hint)"; return 1; }
        ga_config_merge "$(jq -nc --arg d "$domain" '{domain: $d}')" >/dev/null 2>&1 || true
        log_dim "$(t ms_issue_later_hint)"
    fi
    # Сайт мог остаться с прежним шаблоном (файлы на диске) — тогда и вопрос о нём, а не «случайный
    # шаблон развёрнут» (находка LS-06).
    tpl_after=$(_cfg '.site.template_id')
    local tpl_q
    if [ -n "$tpl_before" ] && [ "$tpl_before" = "$tpl_after" ]; then
        tpl_q=$(tf wz_pick_template_ask_kept "$tpl_after")
    else
        tpl_q=$(t wz_pick_template_ask)
    fi
    if [ "$ask_tpl" = 1 ] && confirm "$tpl_q"; then
        website_change_template_interactive || true
    fi
    return 0
}

_mode_site_screen() {
    local ch mode domain ppath alt fp ip pf="" p443
    _site_require || return 1
    while true; do
        mode=$(_mode_current)
        domain=$(_cfg '.domain')
        ppath=$(_cfg '.panel.miniapp_path')
        alt=$(_cfg '.options.alt_svc')
        _screen_head "$(t se_mode_site)" "$(t ms_note)"
        # Предполётная проверка портов 80/443 — по одному ss и одному docker ps.
        # Раньше она шла на КАЖДУЮ перерисовку экрана, в том числе после возврата
        # из любого пункта (замечание критика). Теперь держим результат на время
        # экрана, а «r» пересканирует по явной просьбе.
        if [ -z "$pf" ] && type preflight_modes >/dev/null 2>&1; then
            pf=$(preflight_modes 2>/dev/null) || pf=""
        fi
        if [ -n "$pf" ]; then
            GA_PF_AGAIN_ITEM=8 preflight_render_modes "$pf" brief
            echo -e "  ${DIM}$(_rule)${NC}"
        fi
        echo -e "  $(t ms_mode): ${CYAN}$(_mode_name "$mode")${NC}    $(t ms_domain): ${CYAN}${domain:--}${NC}"
        # В Pro — какая линия на UDP 443 (F-3): её меняет пункт 9 ниже.
        if [ "$mode" = pro ]; then
            p443=$(_vpn_443_profile) || p443=""
            [ -n "$p443" ] && echo -e "  $(t pl_header): ${CYAN}$(_pr_label "$p443" noport)${NC}"
        fi
        # Экран режима — то самое место, где расхождение ярлыка и порта VPN
        # надо видеть: отсюда до «Протоколов» один шаг.
        _mode_port_warn
        if _site_has_site; then
            # Домен и настоящий сертификат есть в ОБОИХ режимах с сайтом. На
            # запасном самоподписанном вместо срока показываем отпечаток: по нему
            # агенты и человек убеждаются, что говорят с нашим сервером.
            if [ "$(_site_cert_kind)" = "selfsigned" ]; then
                ip=$(_server_ip)
                [ -n "$ip" ] && echo -e "  $(t ms_site_url): ${CYAN}https://${ip}/${NC}"
                fp=$(website_cert_fingerprint 2>/dev/null) || fp="-"
                echo -e "  $(t ms_cert): ${CYAN}$(tf ms_cert_selfsigned_fp "$fp")${NC}"
                echo -e "  ${DIM}$(ga_wrap "$(t ms_cert_selfsigned_why)" "${GA_UI_W:-76}" 2)${NC}"
            else
                [ -n "$domain" ] && echo -e "  $(t ms_site_url): ${CYAN}https://${domain}/${NC}"
                echo -e "  $(t ms_cert): ${CYAN}$(_site_cert_line "$domain")${NC}"
            fi
            echo -e "  $(t ms_template): ${CYAN}$(_site_template_line)${NC}"
            if [ "$alt" = "true" ]; then
                echo -e "  $(t ms_alt_svc): ${GREEN}$(t website_on)${NC}"
            else
                echo -e "  $(t ms_alt_svc): ${DIM}$(t website_off)${NC}"
            fi
            # Панель на домене доступна в обоих режимах с сайтом — ей нужен не
            # «Pro», а доверенный сертификат.
            # Адрес — секрет и в шапке не печатается (NC-15): только пунктом «Панель на домене» ниже
            if [ -n "$ppath" ] && _site_domain_ready; then
                echo -e "  $(t ms_panel): ${GREEN}$(t ms_panel_on_hidden)${NC}"
            else
                echo -e "  $(t ms_panel): ${DIM}$(t ms_panel_off_state)${NC}"
            fi
        fi
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -e "  ${CYAN}1${NC}) $(tf ms_item_change_mode "$(_mode_name "$mode")")"
        echo -e "  ${CYAN}2${NC}) $(t ms_item_domain)"
        echo -e "  ${CYAN}3${NC}) $(t ms_item_template)"
        echo -e "  ${CYAN}4${NC}) $(t ms_item_ssl)"
        echo -e "  ${CYAN}5${NC}) $(t ms_item_check)"
        if [ "$alt" = "true" ]; then
            echo -e "  ${CYAN}6${NC}) $(t ms_item_alt_svc_off)"
        else
            echo -e "  ${CYAN}6${NC}) $(t ms_item_alt_svc_on)"
        fi
        echo -e "  ${CYAN}7${NC}) $(t ms_item_panel)"
        echo -e "  ${CYAN}8${NC}) $(t preflight_again_item)"
        [ "$mode" = pro ] && echo -e "  ${CYAN}9${NC}) $(t ms_item_pro_line)"
        echo -e "  ${CYAN}0${NC}) $(t back)"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0

        case "$ch" in
            1) _site_mode_change "$pf" ;;
            2) _site_domain_change ;;
            3) _site_template_screen ;;
            4) _site_ssl_screen ;;
            5) _site_check_screen ;;
            6) _site_alt_svc_toggle ;;
            7) _site_panel_screen ;;
            8) log_info "$(t preflight_rechecking)"; pf=""; continue ;;
            9) if [ "$mode" = pro ]; then _pro_line_screen; else log_error "$(t invalid_choice)"; fi ;;
            0) GA_BACK=1; return 0 ;;
            "") continue ;;
            *) log_error "$(t invalid_choice)" ;;
        esac

        # После действия состояние портов могло измениться (подняли nginx, сняли
        # сайт) — сбрасываем кэш, чтобы шапка не врала.
        pf=""
        _pause
    done
}

# Доступен ли режим по данным предполётной проверки. Пустой JSON (модуля нет,
# проверка не удалась) — режим считаем доступным: отказывать без данных нельзя,
# а модуль сайта сам сообщит, если nginx не привяжет порт.
_mode_available() {
    local target="$1" pf="${2:-}"
    # Ленивому Pro нужны те же TCP 80/443, что Pro (UDP 443 занят — он сам встанет Semi-Pro).
    [ "$target" = lazy ] && target=pro
    case "$target" in pro|lite_site) ;; *) return 0 ;; esac
    [ -n "$pf" ] || return 0
    [ "$(printf '%s' "$pf" | jq -r --arg m "$target" '.[$m].available' 2>/dev/null)" = true ]
}

# Отказ в переходе с тем же объяснением, что на экране, плюс предложение открыть
# закрытые локально порты. Возвращает 0, если порты открыли и стоит повторить
# проверку; 1 — режим остаётся недоступным.
_mode_blocked_explain() {
    local target="$1" pf="$2" jm="$1"
    # Ленивому Pro нужны те же TCP 80/443, что Pro: причины — из его строки проверки.
    [ "$jm" = lazy ] && jm=pro
    log_error "$(tf preflight_mode_blocked "$(_mode_title "$target")" \
        "$(printf '%s' "$pf" | jq -r --arg m "$jm" '.[$m].reasons[0].message // ""' 2>/dev/null)")"
    _wizard_offer_open_ports "$pf" && return 0
    log_info "$(t preflight_mode_blocked_hint)"
    return 1
}

# Короткое имя режима для фраз «Режим „…“ сейчас недоступен» — вместе со сценарием Ленивый Pro (у него id нет).
_mode_title() {
    case "${1:-}" in
        lazy) t preflight_mode_lazy ;;
        *)    _mode_name "$1" ;;
    esac
}

# Смена режима: экран из четырёх пунктов в порядке договора 0.6.0 (docs/MODES_047.md: 1 Ленивый Pro, 2 Pro,
# 3 Semi-Pro, 4 Lite) → объяснение, что произойдёт → подтверждение → функция модуля. Граф переходов — PLAN §4.3:
# любой ↔ любой, контейнеры и ключи не трогаются, меняются nginx, сертификат, config.json и (для Pro) порт одной
# линии. Ленивый Pro на установленном сервере — справка: это сценарий первой установки, то же самое даёт Pro.
# Нынешний режим отмечен; Pro, если он нынешний, — выбор линии на UDP 443 (F-3). Режимы с сайтом, недоступные по
# предполётной проверке (порт занят чужим или закрыт файрволом), не выбираются — только объяснение.
_site_mode_change() {
    local pf="${1:-}" cur ch target i suffix
    local -a opts=(lazy pro lite_site lite)
    cur=$(_mode_current)
    echo ""
    echo -e "  ${BOLD}${WHITE}$(t ms_change_title)${NC}"
    echo -e "  ${DIM}$(_rule)${NC}"
    echo -e "  $(ga_win_wrap "$(tf ms_change_current "$(_mode_name "$cur")")" 2)"
    for i in 0 1 2 3; do
        target="${opts[$i]}"
        suffix=""
        if [ "$target" = lazy ]; then
            _mode_available lazy "$pf" || suffix="  ${RED}✗ $(t ms_change_unavailable)${NC}"
        elif [ "$target" = "$cur" ] && [ "$cur" = pro ]; then
            suffix="  ${GREEN}$(t ms_change_now_pro)${NC}"
        elif [ "$target" = "$cur" ]; then
            suffix="  ${GREEN}$(t ms_change_now)${NC}"
        elif ! _mode_available "$target" "$pf"; then
            suffix="  ${RED}✗ $(t ms_change_unavailable)${NC}"
        fi
        echo -e "  ${CYAN}$((i + 1))${NC}) $(_mode_change_item "$target")${suffix}"
    done
    echo -e "  ${CYAN}0${NC}) $(t back)"
    echo -ne "  ${WHITE}$(t choose):${NC} "
    read -r ch || ch=0
    case "$ch" in
        1) _site_lazy_run "$pf"; return $? ;;
        2) target=pro ;;
        3) target=lite_site ;;
        4) target=lite ;;
        0) GA_BACK=1; return 0 ;;
        "") GA_BACK=1; return 0 ;;
        *) log_error "$(t invalid_choice)"; return 1 ;;
    esac
    if [ "$target" = "$cur" ]; then
        [ "$cur" = pro ] && { _pro_line_screen; return $?; }
        log_info "$(t ms_mode_same)"
        return 0
    fi
    if ! _mode_available "$target" "$pf"; then
        # Порты открыли прямо здесь — экран «Режим и сайт» перечитает проверку
        # при следующем показе, человеку достаточно выбрать пункт снова.
        _mode_blocked_explain "$target" "$pf"
        return 1
    fi
    _site_transition "$cur" "$target"
}

_mode_change_item() {
    case "${1:-}" in
        lazy)      t ms_change_to_lazy ;;
        pro)       t ms_change_to_pro ;;
        lite_site) t ms_change_to_lite_site ;;
        *)         t ms_change_to_lite ;;
    esac
}

# Ленивый Pro на установленном сервере — пункт «Режим и сайт» (docs/MODES_047.md п. 8): тот же сценарий, что при
# первой установке, — домен (Enter — нынешний), проверки без вопросов, недостающее ставится, в конце сводка. Повторный
# запуск ничего не ломает: порты стоящих профилей с людьми не двигаются, сайт на прежнем домене при отказе Let's
# Encrypt остаётся, ключи Ленивого Pro не множатся (lib/modes.sh). Перед установкой — одно подтверждение: это смена
# режима на живом сервере.
_site_lazy_run() {
    local pf="$1" rc
    if ! _mode_available lazy "$pf"; then
        _mode_blocked_explain lazy "$pf"
        return 1
    fi
    echo ""
    echo -e "  ${BOLD}${WHITE}$(t lz_title)${NC}"
    echo -e "  ${DIM}$(ga_win_wrap "$(t ms_lazy_info)" 2)${NC}"
    while true; do
        _lazy_ask_domain "$(_cfg '.domain')"; rc=$?
        [ "$rc" = 0 ] || { GA_BACK=1; return 0; }
        GA_MODES_ADOPT=1 _lazy_run "${GA_LAZY_KEYS:-$GA_MODES_KEYS_DEFAULT}" ask; rc=$?
        case "$rc" in
            0) _dash_snapshot force; return 0 ;;
            3) continue ;;
            6) GA_BACK=1; return 0 ;;
            *) return 1 ;;
        esac
    done
}

# ── Pro: какая линия AmneziaWG на UDP 443 (F-3, docs/MODES_047.md) ─────────────
# _pro_line_pick → _PL_P — линия, которая встанет на UDP 443. Решение владельца 27.09: рекомендуем 2.0 — её понимает
# больше всего клиентов, включая роутеры Keenetic; это и сказано рядом с выбором. Стоит одна линия — вопроса нет, она
# и встаёт. rc 0 — выбрано; 1 — «0» (или Enter), назад.
_PL_P=""
# _pr_label <профиль> [noport] и _pr_name — имя профиля для людей во всех списках, карточках и вопросах меню
# (ga_profile_title, решение владельца 15.10): «AmneziaWG 3.1 · порт 6714», подхваченный у приложения —
# «AmneziaWG 3.1 · порт 46567 · из приложения»; noport — где порт стоит рядом своей колонкой. Имени места
# awg2/awg3 нет: оно читалось как версия (по месту пункт «AmneziaWG 2.0 (awg2)» выдавал ключ 3.1 — AWG31-01). Профиль
# не стоит — по линии, которая встанет: «AmneziaWG 2.0 — не установлена» (DUP-LINE-01).
_pr_label() {
    if type ga_profile_title >/dev/null 2>&1; then
        ga_profile_title "$1" "${2:-}"
        return 0
    fi
    t "pr_$1"
}
# _pr_install_name <профиль> — имя в строках шага установки: «Ставлю профиль AmneziaWG 2.0», «AmneziaWG 2.0
# установлен» — линия, которая встанет (ga_profile_auto_line), без «— не установлена» и без порта: его ещё нет.
_pr_install_name() {
    case "$1" in
        awg2|awg3) tf pr_title_line "$(ga_profile_auto_line "$1" 2>/dev/null)" ;;
        awg1)      tf pr_title_line "$(ga_profile_auto_line awg1 2>/dev/null)" ;;
        *)         printf '%s' "${1:--}" ;;
    esac
}
# _wz_pr <профиль> — подпись в экране портов мастера, где порт стоит своей колонкой: стоящий профиль — без порта
# («AmneziaWG 3.1 · из приложения»), ставящийся — линией, которая встанет («AmneziaWG 2.0», без «— не установлена»).
_wz_pr() {
    if _profile_installed "$1"; then _pr_name "$1" noport; else _pr_install_name "$1"; fi
}
_pr_name() {
    case "$1" in
        awg1|awg2|awg3) _pr_label "$1" "${2:-}" ;;
        *)              printf '%s' "${1:--}" ;;
    esac
}
# _profile_31_first <профили через пробел или запятую> → профиль с линией 3.1, если он среди них есть, иначе первый:
# «ключ — самого сильного профиля» по линии, а не по месту (2.0 бывает и в awg3, AWG31-01).
_profile_31_first() {
    local p first=""
    for p in ${1//,/ }; do
        [ -n "$first" ] || first="$p"
        [ "$(_profile_line "$p" 2>/dev/null)" = 3.1 ] && { printf '%s' "$p"; return 0; }
    done
    printf '%s' "$first"
}
_pro_line_pick() {
    local -a lines=()
    local p i ch holder label
    _PL_P=""
    for p in awg2 awg3; do _profile_installed "$p" && lines+=("$p"); done
    # 2.0 — первой (её и рекомендуем) — по линии, а не по месту профиля
    if [ "${#lines[@]}" = 2 ] && [ "$(ga_profile_line "${lines[1]}" 2>/dev/null)" = 2.0 ]; then
        lines=("${lines[1]}" "${lines[0]}")
    fi
    if [ "${#lines[@]}" -lt 2 ]; then
        _PL_P="${lines[0]:-}"
        # Стоит одна линия, а вторая пара встанет на свободное место (ga_profile_auto_line; находка WA-1 стенда 15.10:
        # пункт говорил «вторую ставит «Протоколы»», а они ставили 3.1, и сразу предлагал увезти на 443 подхваченную
        # у приложения 3.1 с пользователями без ключей на сервере). Выбор: поставить недостающую сразу на UDP 443 или
        # перенести стоящую — перенос профиля приложения спросит отдельно (ACC-2, набор порта профиля).
        local free="" fl=""
        for p in awg2 awg3; do _profile_installed "$p" || { free="$p"; break; }; done
        [ -n "$free" ] && [ -n "$_PL_P" ] && fl=$(ga_profile_auto_line "$free" 2>/dev/null)
        if [[ "$fl" =~ ^(2\.0|3\.1)$ ]] && [ "$fl" != "$(ga_profile_line "$_PL_P" 2>/dev/null)" ]; then
            holder=$(_vpn_443_profile) || holder=""
            echo ""
            echo -e "  ${BOLD}${WHITE}$(t pl_title)${NC}"
            echo -e "  $(ga_win_wrap "$(t pl_explain)" 2)"
            [ "$fl" = 2.0 ] && log_warning "$(_ui_w "$(t pl_recommend_install)")"
            label="$(tf pl_install_item "$(tf pr_title_line "$fl")")"
            [ "$fl" = 2.0 ] && label="$label — $(t pl_recommended)"
            echo -e "  ${CYAN}1${NC}) ${label}"
            # Держатель 443 — без порта: «сейчас на UDP 443» стоит рядом
            if [ "$_PL_P" = "$holder" ]; then label="$(_pr_label "$_PL_P" noport)  ${GREEN}$(t pl_now_443)${NC}"
            else label="$(_pr_label "$_PL_P")"; fi
            echo -e "  ${CYAN}2${NC}) ${label}"
            echo -e "  ${CYAN}0${NC}) $(t back)"
            echo -ne "  ${WHITE}$(t choose):${NC} "
            read -r ch || ch=0
            case "$ch" in
                1) _PL_P="$free"; return 0 ;;
                2) return 0 ;;
                0|"") _PL_P=""; return 1 ;;
            esac
            log_error "$(t invalid_choice)"
            _PL_P=""
            return 1
        fi
        return 0
    fi
    holder=$(_vpn_443_profile) || holder=""
    echo ""
    echo -e "  ${BOLD}${WHITE}$(t pl_title)${NC}"
    echo -e "  $(ga_win_wrap "$(t pl_explain)" 2)"
    # Совет «Рекомендуем 2.0» — только когда 2.0 есть на сервере: иначе он вёл в несуществующее (DUP-LINE-01, R4 стенда
    # 15.10: «Рекомендуем 2.0», а на выбор две одинаковые 3.1). Нет — говорим это и куда идти за 2.0.
    if _server_has_line 2.0; then
        log_warning "$(_ui_w "$(t pl_recommend)")"
    else
        log_warning "$(_ui_w "$(t pl_recommend_no20) $(_reline_hint)")"
    fi
    for i in "${!lines[@]}"; do
        p="${lines[$i]}"
        if [ "$p" = "$holder" ]; then label="$(_pr_label "$p" noport)"; else label="$(_pr_label "$p")"; fi
        [ "$(ga_profile_line "$p" 2>/dev/null)" = 2.0 ] && label="$label — $(t pl_recommended)"
        [ "$p" = "$holder" ] && label="$label  ${GREEN}$(t pl_now_443)${NC}"
        echo -e "  ${CYAN}$((i + 1))${NC}) ${label}"
    done
    echo -e "  ${CYAN}0${NC}) $(t back)"
    echo -ne "  ${WHITE}$(t choose):${NC} "
    read -r ch || ch=0
    case "$ch" in
        1|2) _PL_P="${lines[$((ch - 1))]}"; return 0 ;;
        0|"") return 1 ;;
    esac
    log_error "$(t invalid_choice)"
    return 1
}

# «Режим и сайт» в Pro: сменить линию на UDP 443 — тот же выбор и тот же перенос (pro_line_set), что у перехода в Pro.
_pro_line_screen() {
    local n=0 p
    if [ "$(_mode_current)" != pro ]; then
        log_info "$(_ui_w "$(t pl_only_pro)")"
        return 0
    fi
    for p in awg2 awg3; do _profile_installed "$p" && n=$((n + 1)); done
    _pro_line_pick || { GA_BACK=1; return 0; }
    [ -n "$_PL_P" ] || return 0
    [ "$n" -lt 2 ] && _profile_installed "$_PL_P" && log_dim "$(_ui_w "$(tf pl_one_line "$(_pr_label "$_PL_P")")")"
    _site_vpn_port_plan pro "$_PL_P" || return 1
    [ -n "$_SVP_P" ] || return 0
    _site_vpn_port_apply || return 1
    _mode_port_warn
    _dash_snapshot force
    return 0
}

# Перевести AmneziaWG на UDP/443 (третий режим) или увести с него (второй).
# Именно в этом вся разница между вторым и третьим режимом, поэтому смена режима
# обязана менять порт — раньше она его не трогала вовсе, и «Pro» отличался от
# «Lite + сайт» только словом в конфиге. Порт стоит в Endpoint каждого выданного
# ключа, поэтому спрашиваем отдельно и объясняем последствия.
#
# Два шага: план (какой профиль, откуда, куда; предупреждение и вопрос) и перенос.
# Между ними вызывающий меняет режим — и только если человек согласился: экран
# перехода обещает «откажетесь — и порт, и режим останутся прежними», а раньше
# отказ всё равно переписывал режим, и меню жило с ярлыком, который не совпадал
# с портом (находка LS-02, 25.09.2026).
#
# _site_vpn_port_plan <в> [линия] → _SVP_P / _SVP_WANT (пусто — переносить нечего), _SVP_CONFIRM — согласие на
# перенос профиля с людьми приложения Amnezia без ключа (порт профиля, набранный человеком). Линия для Pro (F-3,
# выбор человека): она встаёт на UDP 443, а профиль, который держит 443 сейчас (_SVP_HOLDER), уезжает на случайный
# свободный порт — перенос делает pro_line_set (lib/modes.sh). Согласие ACC-2 — за один профиль, поэтому, если у
# обоих люди приложения без ключа, переносить так нельзя: сказано словами и отказ.
# Код 1 — человек отказался от переноса. Об отказе говорит сама, одной строкой «Отменено.»: на вопросе y/n — здесь, на
# наборе фразы — confirm_phrase (LH-3); вызывающий своё «Отменено.» не печатает, иначе их две (NB2-2).
# _SVP_CANCEL_KEY — строка отказа вместо «Отменено.»: при переходе Lite → Pro сайт уже поднят, и отменяется только
# перенос порта (RB3-3).
_SVP_P=""; _SVP_WANT=""; _SVP_CONFIRM=""; _SVP_HOLDER=""
_site_vpn_port_plan() {
    local to="$1" want="${2:-}" p="" cur other port cand first=""
    local -a taken=()
    _SVP_P=""; _SVP_WANT=""; _SVP_CONFIRM=""; _SVP_HOLDER=""
    type amnezia_profile_set_port >/dev/null 2>&1 || return 0
    # Профиль, который сейчас держит 443
    for other in $PROFILE_IDS; do
        _profile_installed "$other" || continue
        port=$(_cfg ".profiles.$other.port")
        [ -n "$port" ] && taken+=("$port")
        [ "$port" = "443" ] && p="$other"
    done
    # Недостающая линия на свободное место — сразу на UDP 443 (WA-1): ставит pro_line_set (не установлена — ставится на
    # 443), прежний держатель 443 уезжает на случайный порт; держатель с людьми приложения без ключа — согласие ACC-2.
    if [ "$to" = "pro" ] && [ -n "$want" ] && ! _profile_installed "$want"; then
        _SVP_HOLDER="$p"
        _SVP_P="$want"
        _SVP_WANT=443
        [ -n "$_SVP_HOLDER" ] && log_warning "$(_ui_w "$(tf pl_holder_moves "$(_pr_label "$_SVP_HOLDER")")")"
        if [ -n "$_SVP_HOLDER" ] && [ "$(_profile_keyless "$_SVP_HOLDER")" -gt 0 ]; then
            _profile_adopted_move_ok "$_SVP_HOLDER" 443 "$(t pl_random_port)" || { _SVP_P=""; _SVP_WANT=""; _SVP_HOLDER=""; return 1; }
            _SVP_CONFIRM="$_SVP_HOLDER"
            return 0
        fi
        confirm "$(tf pl_install_ask "$(_pr_label "$want")" 443)" || { _SVP_P=""; _SVP_WANT=""; _SVP_HOLDER=""; log_info "$(t "${_SVP_CANCEL_KEY:-cancelled}")"; return 1; }
        return 0
    fi
    if [ "$to" = "pro" ] && [ -n "$want" ] && [ "$want" != "$p" ] && _profile_installed "$want"; then
        _SVP_HOLDER="$p"
        _SVP_P="$want"
        _SVP_WANT=443
        cur=$(_cfg ".profiles.$want.port")
        log_warning "$(_ui_w "$(tf ms_vpn_port_warn "$(_pr_label "$want")" "$cur" 443)")"
        [ -n "$_SVP_HOLDER" ] && log_warning "$(_ui_w "$(tf pl_holder_moves "$(_pr_label "$_SVP_HOLDER")")")"
        if [ "$(_profile_keyless "$want")" -gt 0 ] && [ -n "$_SVP_HOLDER" ] && [ "$(_profile_keyless "$_SVP_HOLDER")" -gt 0 ]; then
            log_warning "$(_ui_w "$(tf pl_both_adopted "$(_pr_label "$want")" "$(_pr_label "$_SVP_HOLDER")")")"
            _SVP_P=""; _SVP_WANT=""; _SVP_HOLDER=""
            log_info "$(t "${_SVP_CANCEL_KEY:-cancelled}")"
            return 1
        fi
        if [ "$(_profile_keyless "$want")" -gt 0 ]; then
            _profile_adopted_move_ok "$want" "$cur" 443 || { _SVP_P=""; _SVP_WANT=""; _SVP_HOLDER=""; return 1; }
            _SVP_CONFIRM="$want"
            return 0
        fi
        if [ -n "$_SVP_HOLDER" ] && [ "$(_profile_keyless "$_SVP_HOLDER")" -gt 0 ]; then
            _profile_adopted_move_ok "$_SVP_HOLDER" 443 "$(t pl_random_port)" || { _SVP_P=""; _SVP_WANT=""; _SVP_HOLDER=""; return 1; }
            _SVP_CONFIRM="$_SVP_HOLDER"
            return 0
        fi
        confirm "$(tf ms_vpn_port_ask "$(_pr_label "$want")" 443)" || { _SVP_P=""; _SVP_WANT=""; _SVP_HOLDER=""; log_info "$(t "${_SVP_CANCEL_KEY:-cancelled}")"; return 1; }
        return 0
    fi
    if [ "$to" = "pro" ]; then
        [ -z "$p" ] || { log_info "$(tf ms_vpn_already_443 "$(_pr_name "${p}")")"; return 0; }
        # На 443 — свой профиль, а не подхваченный у приложения Amnezia с людьми без ключа на сервере: им
        # после переноса новые конфиги не переслать (находка ACC-2 — раньше сюда молча уезжал awg2, а на
        # сервере из приложения это и есть контейнер приложения). Первым — awg2, как было всегда; такой
        # подхваченный — только если других нет, и только набором порта профиля (ниже).
        for cand in awg2 $PROFILE_IDS; do
            _profile_installed "$cand" || continue
            [ -n "$first" ] || first="$cand"
            if [ "$(_profile_keyless "$cand")" = 0 ]; then p="$cand"; break; fi
        done
        [ -n "$first" ] || return 0
        if [ -z "$p" ]; then
            p="$first"
        elif [ "$p" != "$first" ]; then
            log_info "$(_ui_w "$(tf ms_vpn_443_native "$(_pr_name "${p}")" "$(_pr_name "${first}")")")"
        fi
        _SVP_WANT=443
    else
        [ -n "$p" ] || return 0
        # Случайный порт — мимо портов остальных профилей (как в мастере)
        _SVP_WANT=$(_random_port "${taken[@]}")
    fi
    cur=$(_cfg ".profiles.$p.port")
    [ "$cur" = "$_SVP_WANT" ] && { _SVP_WANT=""; return 0; }
    _SVP_P="$p"
    log_warning "$(tf ms_vpn_port_warn "$(_pr_name "${p}")" "$cur" "$_SVP_WANT")"
    if [ "$(_profile_keyless "$p")" -gt 0 ]; then
        _profile_adopted_move_ok "$p" "$cur" "$_SVP_WANT" || { _SVP_P=""; _SVP_WANT=""; return 1; }
        _SVP_CONFIRM="$p"
        return 0
    fi
    confirm "$(tf ms_vpn_port_ask "$(_pr_name "${p}")" "$_SVP_WANT")" || { log_info "$(t "${_SVP_CANCEL_KEY:-cancelled}")"; return 1; }
    return 0
}
# _profile_keyless <профиль> → сколько людей профиля без ключа на сервере (подхвачены у приложения Amnezia).
# Модуля нет или users.json не читается — 0: перенос тогда отвергнет сам модуль, и отказ человек увидит.
_profile_keyless() {
    local n=""
    type ga_profile_keyless_count >/dev/null 2>&1 && n=$(ga_profile_keyless_count "$1" 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}
# _profile_adopted_move_ok <профиль> <порт сейчас> <порт после> → 0 — переносить можно: людей без ключа нет или
# человек набрал порт профиля; 1 — отказ. Кого отрежет и почему им не переслать новое — до вопроса, а вопрос —
# набором порта профиля, как у других необратимых действий (ACC-2).
_profile_adopted_move_ok() {
    local p="$1" from="$2" to="$3" n
    n=$(_profile_keyless "$p")
    [ "$n" -gt 0 ] || return 0
    log_warning "$(_ui_w "$(tf pr_port_adopted_warn "$(_pr_name "${p}")" "$n" "$from" "$to")")"
    # Из плана переноса при Lite → Pro — его строка отказа (_SVP_CANCEL_KEY, RB4-1): сайт уже поднят.
    _profile_confirm_phrase "$p" "$(tf pr_port_adopted_ask "$(_pr_name "${p}")" "$to")" "${_SVP_CANCEL_KEY:-}"
}
_site_vpn_port_apply() {
    local js="" q port
    [ -n "$_SVP_P" ] && [ -n "$_SVP_WANT" ] || return 0
    # На UDP 443 в Pro — через pro_line_set (lib/modes.sh): он же уводит прежнего держателя 443 на случайный порт и
    # возвращает его, если новая линия не встала (одна дорога с мостом pro-line).
    if [ "$_SVP_WANT" = 443 ] && [ "$(_mode_current)" = pro ] && type pro_line_set >/dev/null 2>&1; then
        GA_ERR_CODE=""; GA_ERR_MSG=""
        local fresh=""
        _profile_installed "$_SVP_P" || fresh=1
        if ga_step "$(tf pr_port_changing "$(_pr_name "$_SVP_P")" 443)" "$(tf pr_port_changed "$(_pr_name "$_SVP_P")" 443)" "" \
                ga_capture js pro_line_set "$_SVP_P" "$_SVP_CONFIRM"; then
            q="${GA_MODES_PL_PREV:-}"
            port="${GA_MODES_PL_PREV_PORT:-}"
            [ -n "$q" ] && log_info "$(_ui_w "$(tf pl_holder_moved "$(_pr_label "$q" noport)" "$port")")"
            # Недостающая линия встала только что (WA-1, WA-2): ключей на ней нет ни у кого — предложить выдать всем.
            [ -n "$fresh" ] && _profile_offer_keys_to_all "$_SVP_P"
            return 0
        fi
        [ -n "${GA_ERR_MSG:-}" ] && log_warning "$(_ui_w "$GA_ERR_MSG")"
        log_warning "$(t ms_vpn_port_failed)"
        return 1
    fi
    ga_step "$(tf pr_port_changing "$_SVP_P" "$_SVP_WANT")" "$(tf pr_port_changed "$_SVP_P" "$_SVP_WANT")" "" \
        amnezia_profile_set_port "$_SVP_P" "$_SVP_WANT" "$_SVP_CONFIRM" && return 0
    log_warning "$(t ms_vpn_port_failed)"
    return 1
}
# Порт остался на месте (человек отказался или перенос сорвался) — ярлык режима по факту:
# VPN на UDP/443 — «Сайт и VPN на 443», на своём порту — «VPN и сайт». Раньше при сорвавшемся
# переносе ярлык оставался новым, и меню жило с режимом, который врёт (LS-02, SR-55).
_site_label_by_fact() {
    local real=lite_site
    [ -n "$(_vpn_443_profile)" ] && real=pro
    [ "$(_mode_current)" = "$real" ] && return 0
    website_switch_site_mode "$real" >/dev/null 2>&1 || true
    log_info "$(_ui_w "$(tf ms_vpn_port_declined_label "$(_mode_name "$(_mode_current)")")")"
}

# Адрес в НОВЫХ ключах после смены режима. Домен в ключах ставится только в «Сайт и VPN
# на 443» (правило владельца 17.09.2026), поэтому переход между режимами меняет хост в
# Endpoint — а экран перехода обещал «ключи не меняются» (находка LS-01, 25.09.2026).
# Сравниваем, что выдал бы ключ до и после, и говорим, если разное. Отдельно — адрес
# сервера, которого нет в A-записях домена: на машине с несколькими адресами это бывает
# адрес без входящих (стенд A), и новые ключи на него не подключатся.
_site_keys_host_note() {
    local before="$1" after domain a
    type ga_export_endpoint_host >/dev/null 2>&1 || return 0
    after=$(ga_export_endpoint_host 2>/dev/null) || after=""
    [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ] || return 0
    if _valid_ip "$after"; then
        log_info "$(_ui_w "$(tf ms_keys_to_ip "$before" "$after")")"
        domain=$(_cfg '.domain')
        if [ -n "$domain" ] && type ga_site_dns_a_all >/dev/null 2>&1; then
            a=$(ga_site_dns_a_all "$domain" 2>/dev/null) || a=""
            if [ -n "$a" ] && ! grep -qxF "$after" <<<"$a"; then
                log_warning "$(_ui_w "$(tf ms_keys_ip_not_in_dns "$after")")"
            fi
        fi
    else
        log_info "$(_ui_w "$(tf ms_keys_to_domain "$before" "$after")")"
    fi
    return 0
}

# Режим второго и третьего вида — это ярлык одного-единственного факта: стоит
# VPN на UDP/443 или на своём порту. А перенос порта человек вправе отклонить —
# порт записан в каждом выданном ключе, и переезд рвёт связь всем, кто не успел
# забрать новый конфиг. Раньше отказ проходил молча: меню писало «VPN и сайт», а
# AmneziaWG как стоял на UDP/443, так и стоял, и человек об этом не узнавал ни на
# экране перехода, ни потом. Ярлык мы не переписываем — это выбор человека, — но
# о расхождении говорим вслух здесь, на приборной доске и в ответе моста.
#
# _vpn_443_profile → id профиля на UDP/443 (пусто — такого нет).
_vpn_443_profile() {
    local p
    for p in $PROFILE_IDS; do
        _profile_installed "$p" || continue
        [ "$(_cfg ".profiles.$p.port")" = "443" ] && { printf '%s' "$p"; return 0; }
    done
    printf ''
    return 1
}
# _mode_port_mismatch → 0, когда ярлык режима и порт VPN расходятся.
_mode_port_mismatch() {
    local mode on443
    mode=$(_mode_current)
    case "$mode" in pro|lite_site) ;; *) return 1 ;; esac
    on443=$(_vpn_443_profile) || on443=""
    [ "$mode" = pro ] && { [ -z "$on443" ] && return 0 || return 1; }
    [ -n "$on443" ] && return 0
    return 1
}
_mode_port_warn() {
    local on443 mode
    _mode_port_mismatch || return 0
    mode=$(_mode_current)
    on443=$(_vpn_443_profile) || on443=""
    if [ -n "$on443" ]; then
        log_warning "$(_ui_w "$(tf ms_mode_port_mismatch "$(_mode_name "$mode")" "$(_pr_name "${on443}")" "443")")"
    else
        log_warning "$(_ui_w "$(tf ms_mode_port_missing_443 "$(_mode_name "$mode")")")"
    fi
    return 0
}

# _site_transition <из> <в> — объяснить переход, подтвердить, выполнить.
#
# Граф пересмотрен под уточнённый замысел владельца. Второй и третий режим — это
# один и тот же сайт на домене с настоящим сертификатом; разница только в том,
# где стоит AmneziaWG: на своём порту или на UDP/443 рядом с сайтом. Отсюда:
#   lite → lite_site|pro   спросить домен → поднять сайт (Let's Encrypt, а если
#                          домена нет или A-запись ещё не разошлась — запасной
#                          самоподписанный) → для pro увести VPN на UDP/443;
#   lite_site ↔ pro        сайт НЕ трогаем вовсе (website_switch_site_mode) —
#                          меняется только порт VPN;
#   * → lite               сайт снять (website_disable_site), домен, сертификат
#                          и файлы сайта остаются на диске.
# Модули пишут mode только при успехе: неудача оставляет прежний режим.
_site_transition() {
    local from="$1" to="$2" domain keys_before
    # Ярлык режима с сайтом, а vhost нет (оборванный мастер) — переход считаем из «Только VPN»:
    # сайт поднимается заново, а не меняется одно слово в config.json (SR-13).
    if [ "$from" != lite ] && type ga_site_fs_nginx_ok >/dev/null 2>&1 && ga_site_fs_nginx_ok \
       && [ ! -f "$(ga_site_conf_path)" ]; then
        case "$to" in pro|lite_site) from=lite ;; esac
    fi
    # Pro без домена не бывает (LZ-10): из Semi-Pro без домена отказываем ДО объяснения перехода — иначе экран
    # сначала обещает «сайт, домен и сертификат остаются как есть», а следующей строкой отказывает (живой прогон 28.09).
    if [ "$from" = lite_site ] && [ "$to" = pro ] && [ -z "$(_cfg '.domain')" ]; then
        log_warning "$(_ui_w "$(t ms_pro_needs_domain)")"
        return 1
    fi
    case "${from}:${to}" in
        lite:lite_site)      log_info "$(_ui_w "$(t ms_tr_lite_to_site)")" ;;
        lite:pro)            log_info "$(_ui_w "$(t ms_tr_lite_to_pro)")" ;;
        lite_site:pro)       log_info "$(_ui_w "$(t ms_tr_site_to_pro)")" ;;
        pro:lite_site)       log_info "$(_ui_w "$(t ms_tr_pro_to_site)")" ;;
        lite_site:lite|pro:lite) log_warning "$(_ui_w "$(t ms_tr_site_to_lite)")" ;;
        *) log_info "$(t ms_mode_same)"; return 0 ;;
    esac
    case "$to" in
        lite)
            # Страницы подключения без домена мертвы и при уходе сайта отзываются насовсем —
            # сказать об этом ДО вопроса, а не после (находка LS-04, 25.09.2026).
            local npages=0
            if type pages_list >/dev/null 2>&1; then
                npages=$(pages_list 2>/dev/null | jq -r '.count // 0' 2>/dev/null) || npages=0
            fi
            if [[ "${npages:-0}" =~ ^[0-9]+$ ]] && [ "$npages" -gt 0 ]; then
                log_warning "$(_ui_w "$(tf ms_tr_pages_revoke "$npages")")"
            fi
            confirm "$(tf ms_change_ask "$(_mode_name lite)")" || { log_info "$(t cancelled)"; return 1; }
            keys_before=$(ga_export_endpoint_host 2>/dev/null) || keys_before=""
            website_disable_site || return $?
            _site_keys_host_note "$keys_before"
            return 0
            ;;
        pro|lite_site)
            type website_switch_site_mode >/dev/null 2>&1 \
                || { log_error "$(tf module_missing website_switch_site_mode)"; return 1; }
            keys_before=$(ga_export_endpoint_host 2>/dev/null) || keys_before=""
            if [ "$from" = "lite" ]; then
                # Сайта ещё нет: спрашиваем домен и поднимаем его целиком.
                domain=$(_site_ask_domain_optional "$(_cfg '.domain')") || { log_info "$(t cancelled)"; return 1; }
                confirm "$(tf ms_change_ask "$(_mode_name "$to")")" || { log_info "$(t cancelled)"; return 1; }
                _site_bring_up "$to" "$domain" 1 || return 1
                # Сайт уже поднят, и отказ от переноса порта его не откатывает. Ярлык режима
                # тогда ставим по факту: VPN на UDP/443 — Pro, на своём порту — Semi-Pro
                # (LS-02): так меню не живёт с ярлыком, который врёт. Какая линия встанет на
                # UDP 443 — выбирает человек (F-3); «0» на выборе — тот же отказ от переноса.
                local want=""
                if [ "$to" = pro ]; then
                    if _pro_line_pick; then want="${_PL_P:-}"; else want="-"; fi
                fi
                if [ "$want" != "-" ] && _SVP_CANCEL_KEY=ms_port_move_cancelled _site_vpn_port_plan "$to" "$want"; then
                    _site_vpn_port_apply || _site_label_by_fact
                else
                    _site_label_by_fact
                fi
            else
                # Semi-Pro ↔ Pro: сайт тот же, разница только в месте VPN. Вопрос о переносе
                # порта и есть подтверждение перехода — отказ оставляет и режим, и порт, как
                # обещает экран перехода (LS-02). В Pro — сначала какая линия на UDP 443 (F-3).
                local want=""
                if [ "$to" = pro ] && [ -z "$(_cfg '.domain')" ]; then
                    # Pro без домена не бывает (LZ-10): в Pro ключи ведут на домен. Домен здесь не спрашиваем, а
                    # отказываем с подсказкой: пункт «Домен» проверит DNS и выпустит сертификат отдельным шагом, а при
                    # отказе Let's Encrypt оставит прежний сайт; смешивать это с переносом порта VPN, записанного в ключах
                    # людей, в одном переходе — рисковать половинчатым состоянием. Ничего не изменено.
                    log_warning "$(_ui_w "$(t ms_pro_needs_domain)")"
                    return 1
                fi
                if [ "$to" = pro ]; then
                    _pro_line_pick || { log_info "$(t cancelled)"; return 1; }
                    want="${_PL_P:-}"
                fi
                _site_vpn_port_plan "$to" "$want" || return 1
                if [ -z "$_SVP_P" ]; then
                    # Переносить нечего (443 уже у другого профиля или профилей нет) —
                    # переход подтверждаем обычным вопросом.
                    confirm "$(tf ms_change_ask "$(_mode_name "$to")")" || { log_info "$(t cancelled)"; return 1; }
                fi
                website_switch_site_mode "$to" || return 1
                _site_vpn_port_apply || _site_label_by_fact
            fi
            _site_keys_host_note "$keys_before"
            _mode_port_warn
            _dash_snapshot force
            return 0
            ;;
    esac
}

# Смена домена. В любом режиме С САЙТОМ — новый сертификат Let's Encrypt и новый
# vhost (старый сертификат остаётся в /etc/letsencrypt и лимита не тратит); в
# Lite сайта нет — только запись в config.json до включения сайта.
_site_domain_change() {
    local cur new mode
    cur=$(_cfg '.domain')
    mode=$(_mode_current)
    # «0 — назад» (rc 1) — назад без «Отменено» и без паузы (NC-22); три промаха подряд (rc 2) — «Отменено»
    new=$(_site_ask_domain "$cur") || { [ $? = 1 ] && { GA_BACK=1; return 1; }; log_info "$(t cancelled)"; return 1; }
    if [ "$new" = "$cur" ] && [ "$(_site_cert_kind)" != "selfsigned" ]; then
        log_info "$(t ms_domain_same)"
        return 0
    fi
    if _site_has_site; then
        log_warning "$(t ms_domain_change_warn)"
        confirm "$(tf ms_domain_change_ask "$new")" || { log_info "$(t cancelled)"; return 1; }
        website_enable_pro "$new" "" "$mode" || return $?
        _panel_ensure_service || true
        return 0
    fi
    ga_config_merge "$(jq -nc --arg d "$new" '{domain: $d}')" || return 1
    log_success "$(tf ms_domain_saved_lite "$new")"
}

# Каталог шаблонов — 14 МБ снимок. Раньше он ехал при КАЖДОЙ установке, включая
# первый режим, где сайта нет вовсе (замечание критика). Теперь он необязательный
# файл загрузчика, а сюда приезжает при первой смене шаблона — с индикатором,
# потому что качается он заметное время. Источник — тот же, откуда поставлен
# сервер (.install-source); токен приватного репозитория нигде не хранится,
# поэтому спрашиваем его (или берём из GOAMNEZIA_PAT).
_site_ensure_catalog() {
    local f repo ref pat url tmp
    f="${GOAMNEZIA_CATALOG:-$SCRIPT_DIR/templates_catalog.json}"
    if [ -s "$f" ] && jq -e 'length > 0' "$f" >/dev/null 2>&1; then
        return 0
    fi
    repo=$(_install_source_field repo) || repo=""
    ref=$(_install_source_field ref) || ref=$(_install_source_field branch) || ref=""
    if [ -z "$repo" ] || [ -z "$ref" ]; then
        log_error "$(t ms_catalog_no_source)"
        return 1
    fi
    log_info "$(t ms_catalog_missing)"
    confirm "$(t ms_catalog_ask)" || { log_info "$(t cancelled)"; return 1; }
    pat="${GOAMNEZIA_PAT:-}"
    [ -n "$pat" ] || _su_ask_pat pat
    [ -n "$pat" ] || { log_error "$(t mt_selfupdate_no_pat)"; return 1; }
    url="https://raw.githubusercontent.com/${repo}/${ref}/templates_catalog.json"
    tmp="${f}.part"
    # curl -# рисует полосу загрузки: 14 МБ без признаков движения выглядят
    # зависанием (то же замечание, что про Docker и образ).
    log_info "$(t ms_catalog_downloading)"
    # Ключ — в stdin curl, а не в аргументах: см. загрузку bootstrap.sh выше.
    if ! printf 'header = "Authorization: token %s"\n' "$pat" \
         | curl -fL --progress-bar -K - -o "$tmp" "$url"; then
        rm -f "$tmp"
        log_error "$(t ms_catalog_failed)"
        return 1
    fi
    if ! jq -e 'length > 0' "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        log_error "$(t ms_catalog_broken)"
        return 1
    fi
    mv "$tmp" "$f" || { rm -f "$tmp"; log_error "$(t ms_catalog_failed)"; return 1; }
    log_success "$(tf ms_catalog_ready "$(jq -r 'length' "$f" 2>/dev/null || printf '?')")"
    return 0
}

_site_template_screen() {
    local ch
    _site_has_site || { log_warning "$(t ms_needs_site)"; return 1; }
    _screen_head "$(t ms_item_template)" "$(t ms_tpl_note)"
    echo -e "  $(t ms_tpl_current): ${CYAN}$(_site_template_line)${NC}"
    echo -e "  ${CYAN}1${NC}) $(t ms_tpl_pick)"
    echo -e "  ${CYAN}2${NC}) $(t ms_tpl_random)"
    echo -e "  ${CYAN}0${NC}) $(t back)"
    echo -ne "  ${WHITE}$(t choose):${NC} "
    read -r ch || ch=0
    case "$ch" in
        1) _site_ensure_catalog && website_change_template_interactive ;;
        2)
            confirm "$(t ms_tpl_random_ask)" || { log_info "$(t cancelled)"; return 1; }
            _site_ensure_catalog || return 1
            website_deploy_template __random__ >/dev/null
            ;;
        0) GA_BACK=1; return 0 ;;
        "") GA_BACK=1; return 0 ;;
        *) log_error "$(t invalid_choice)" ;;
    esac
}

# Запасной самоподписанный сертификат: срок, отпечаток, перевыпуск и — главное —
# переход на настоящий, как только домен появился и A-запись разошлась. Продлевать
# самоподписанный некому (10 лет); перевыпуск нужен, только чтобы сменить отпечаток.
_site_selfsigned_screen() {
    local ch fp exp domain mode
    fp=$(website_cert_fingerprint 2>/dev/null) || fp=""
    exp=$(website_selfsigned_expiry 2>/dev/null) || exp=""
    domain=$(_cfg '.domain')
    mode=$(_mode_current)
    _screen_head "$(t ms_item_ssl)" "$(t ms_ssl_selfsigned_note)"
    if [ -n "$exp" ]; then
        echo -e "  $(t ms_cert): ${CYAN}$(tf ms_cert_days "$(ga_human_ts "${exp%% *}")")${NC}"
    else
        echo -e "  $(t ms_cert): ${RED}$(t ms_cert_none)${NC}"
    fi
    echo -e "  $(t ms_fingerprint): ${CYAN}${fp:--}${NC}"
    echo -e "  $(t ms_domain): ${CYAN}${domain:--}${NC}"
    echo -e "  ${DIM}$(ga_wrap "$(t ms_ssl_selfsigned_hint)" "${GA_UI_W:-76}" 2)${NC}"
    echo -e "  ${CYAN}1${NC}) $(t ms_ssl_to_le)"
    echo -e "  ${CYAN}2${NC}) $(t ms_ssl_regen)"
    echo -e "  ${CYAN}0${NC}) $(t back)"
    echo -ne "  ${WHITE}$(t choose):${NC} "
    read -r ch || ch=0
    case "$ch" in
        1)
            # Основной путь: домен и настоящий сертификат. Боевой выпускается один
            # раз (правило владельца) — модуль живой сертификат не перевыпускает.
            # Спрошенный здесь домен подсказку уже получил в _site_ask_domain
            if [ -n "$domain" ]; then
                _site_dns_hint "$domain"
            else
                domain=$(_site_ask_domain "") || { log_info "$(t cancelled)"; return 1; }
            fi
            confirm "$(tf ms_ssl_to_le_ask "$domain")" || { log_info "$(t cancelled)"; return 1; }
            website_enable_pro "$domain" "" "$mode" && { _panel_ensure_service || true; }
            ;;
        2)
            log_warning "$(t ms_ssl_regen_warn)"
            confirm "$(t ms_ssl_regen_ask)" || { log_info "$(t cancelled)"; return 1; }
            website_selfsigned_renew
            ;;
        0) GA_BACK=1; return 0 ;;
        "") GA_BACK=1; return 0 ;;
        *) log_error "$(t invalid_choice)" ;;
    esac
}

# Сертификат. Ветка выбирается по тому, чем сайт отдаётся СЕЙЧАС, а не по режиму:
# домен и Let's Encrypt есть в обоих режимах с сайтом, самоподписанный — запасной
# путь в обоих же. «Выпустить/проверить» живой сертификат не перевыпускает
# (лимиты Let's Encrypt — правило владельца), «продлить» — certbot renew по сроку.
_site_ssl_screen() {
    local ch domain
    _site_has_site || { log_warning "$(t ms_needs_site)"; return 1; }
    if [ "$(_site_cert_kind)" != "letsencrypt" ]; then
        _site_selfsigned_screen
        return $?
    fi
    domain=$(_cfg '.domain')
    [ -n "$domain" ] || { log_error "$(t website_err_no_domain)"; return 1; }
    _screen_head "$(t ms_item_ssl)" "$(t ms_ssl_note)"
    echo -e "  $(t ms_domain): ${CYAN}${domain}${NC}    $(t ms_cert): ${CYAN}$(_site_cert_line "$domain")${NC}"
    # Почта центра сертификации: без неё Let's Encrypt физически не может
    # предупредить о сорвавшемся автопродлении, а спросить её было негде.
    echo -e "  $(t ms_ssl_email): ${CYAN}$(_cfg '.acme_email')${NC}"
    [ -n "$(_cfg '.acme_email')" ] || log_dim "$(t website_cert_no_email)"
    echo -e "  ${CYAN}1${NC}) $(t ms_ssl_issue)"
    echo -e "  ${CYAN}2${NC}) $(t ms_ssl_renew)"
    echo -e "  ${CYAN}3${NC}) $(t ms_ssl_email_set)"
    echo -e "  ${CYAN}0${NC}) $(t back)"
    echo -ne "  ${WHITE}$(t choose):${NC} "
    read -r ch || ch=0
    case "$ch" in
        1) website_issue_cert "$domain" ;;
        2) website_renew_cert ;;
        3) _site_email_interactive ;;
        0) GA_BACK=1; return 0 ;;
        "") GA_BACK=1; return 0 ;;
        *) log_error "$(t invalid_choice)" ;;
    esac
}

# Почта для писем центра сертификации. Пустой ввод — законный ответ «убрать»:
# certbot тогда регистрируется без адреса, и мы говорим об этом вслух.
_site_email_interactive() {
    local email
    type website_set_acme_email >/dev/null 2>&1 || { log_error "$(tf module_missing website_set_acme_email)"; return 1; }
    email=$(GA_EOF_CANCEL=1 ga_ask_optional "$(t ms_ssl_email_ask)" \
        '^[^[:space:]@]+@[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$' \
        "$(t ms_ssl_email_bad)") || { log_info "$(t cancelled)"; return 1; }
    website_set_acme_email "$email" >/dev/null || { log_error "${GA_ERR_MSG:-$(tf website_err_email "$email")}"; return 1; }
    return 0
}

# Вердикт website_check → строка словаря. case, а не подстановка в имя ключа:
# так tests/check_i18n_ssh.py видит каждый ключ и проверяет оба языка.
_site_verdict_text() {
    case "${1:-}" in
        ok)            t ms_verdict_ok ;;
        not_pro)       t ms_verdict_not_pro ;;
        no_domain)     t ms_verdict_no_domain ;;
        dns_mismatch)  t ms_verdict_dns_mismatch ;;
        dns_partial)   t ms_verdict_dns_partial ;;
        dns_unknown)   t ms_verdict_dns_unknown ;;
        no_cert)       t ms_verdict_no_cert ;;
        http_error)    t ms_verdict_http_error ;;
        no_site)       t ms_verdict_no_site ;;
        cert_expiring) t ms_verdict_cert_expiring ;;
        dry_run)       t ms_verdict_dry_run ;;
        *)             t ms_verdict_unknown ;;
    esac
}
_site_yesno() { if [ "${1:-}" = "true" ]; then t ms_ok; else t ms_bad; fi; }

# Поле JSON строкой (null и отсутствие → пусто): для экранов проверки и шапок.
_site_jv() { printf '%s' "$1" | jq -r "$2 // \"\"" 2>/dev/null; }

# website_check печатает JSON (для моста); здесь его поля — человеку.
_site_check_screen() {
    local js verdict
    js=$(website_check 2>/dev/null) || js=""
    if ! printf '%s' "$js" | jq -e . >/dev/null 2>&1; then
        log_error "$(t ms_check_failed)"; return 1
    fi
    verdict=$(_site_jv "$js" .verdict)
    echo ""
    echo -e "  ${BOLD}${WHITE}$(t ms_check_title)${NC}"
    echo -e "  ${DIM}$(_rule)${NC}"
    echo -e "  $(t ms_mode): ${CYAN}$(_mode_name "$(_site_jv "$js" .mode)")${NC}    $(t ms_domain): ${CYAN}$(_site_jv "$js" .domain)${NC}"
    echo -e "  $(t ms_check_server_ip): ${CYAN}$(_site_jv "$js" .server_ip)${NC}    $(t ms_site_url): ${CYAN}$(_site_jv "$js" .url)${NC}"
    # A-записи — только когда проверяется домен: на запасном пути сайт живёт на IP.
    # Каждая со своей пометкой: у домена их может быть несколько (адрес на
    # каждый интерфейс машины), и чужой адрес среди них — это отдельная беда.
    if [ -n "$(_site_jv "$js" .domain)" ]; then
        local a_line="" a mark
        while IFS= read -r a; do
            [ -n "$a" ] || continue
            if printf '%s' "$js" | jq -e --arg a "$a" 'any((.dns_foreign // [])[]; . == $a)' >/dev/null 2>&1; then
                mark="${RED}✗ $(t ms_check_dns_foreign)${NC}"
            else
                mark="${GREEN}✓${NC}"
            fi
            a_line+="${a_line:+, }${CYAN}${a}${NC} ${mark}"
        done < <(printf '%s' "$js" | jq -r '(.dns_ips // [])[]' 2>/dev/null)
        if [ -z "$a_line" ]; then
            if [ "$(_site_jv "$js" .dns_state)" = unknown ]; then
                a_line="${YELLOW}$(t ms_check_dns_unknown)${NC}"
            else
                a_line="${RED}$(t ms_check_dns_none)${NC}"
            fi
        fi
        echo -e "  $(t ms_check_dns): ${a_line}"
        if [ "$(_site_jv "$js" .dns_cloudflare)" = true ]; then
            log_warning "$(ga_wrap "$(tf website_dns_cloudflare "$(_site_jv "$js" .domain)")" "${GA_UI_W:-76}" 4)"
        fi
        if [ -n "$(printf '%s' "$js" | jq -r '(.dns_aaaa_foreign // [])[]' 2>/dev/null)" ]; then
            log_warning "$(ga_wrap "$(tf website_dns_aaaa "$(_site_jv "$js" .domain)" "$(printf '%s' "$js" | jq -r '.dns_aaaa_foreign | join(", ")')")" "${GA_UI_W:-76}" 4)"
        fi
    fi
    # Код 0 — это «никто не ответил», а не код ответа (находка T29, 25.09.2026).
    local hc hsc
    hc=$(_site_jv "$js" .http_code); [ "$hc" = 0 ] && hc="$(t ms_check_no_answer)"
    hsc=$(_site_jv "$js" .https_code); [ "$hsc" = 0 ] && hsc="$(t ms_check_no_answer)"
    echo -e "  $(t ms_check_http): ${CYAN}${hc:--}${NC}"
    echo -e "  $(t ms_check_https): ${CYAN}${hsc:--}${NC} — $(_site_yesno "$(_site_jv "$js" .https_ok)")"
    if [ "$(_site_jv "$js" .nginx_active)" = "true" ]; then
        echo -e "  $(t ms_check_nginx): ${GREEN}$(t ms_active)${NC}"
    else
        echo -e "  $(t ms_check_nginx): ${RED}$(t ms_inactive)${NC}"
    fi
    if [ "$(_site_jv "$js" .index_present)" = "true" ]; then
        echo -e "  $(t ms_check_index): ${GREEN}$(t ms_present)${NC}"
    else
        echo -e "  $(t ms_check_index): ${RED}$(t ms_absent)${NC}"
    fi
    if [ "$(_site_jv "$js" .cert)" = "selfsigned" ]; then
        echo -e "  $(t ms_cert): ${CYAN}$(tf ms_cert_selfsigned_fp "$(_site_jv "$js" .cert_fingerprint_sha256)")${NC}"
    fi
    if [ -n "$(_site_jv "$js" .cert_expires)" ]; then
        echo -e "  $(t ms_cert): ${CYAN}$(tf ms_cert_days "$(ga_human_ts "$(_site_jv "$js" .cert_expires)")")${NC} — $(_site_yesno "$(_site_jv "$js" .cert_ok)")"
    else
        echo -e "  $(t ms_cert): ${RED}$(t ms_cert_none)${NC}"
    fi
    echo -e "  ${DIM}$(_rule)${NC}"
    if [ "$verdict" = "ok" ]; then
        echo -e "  $(t ms_check_verdict): ${GREEN}$(_site_verdict_text "$verdict")${NC}"
    else
        echo -e "  $(t ms_check_verdict): ${YELLOW}$(_site_verdict_text "$verdict")${NC}"
    fi
    [ "$(_site_jv "$js" .dry_run)" = "true" ] && log_dim "$(t ms_check_dry)"
    return 0
}

# Alt-Svc: выключить — сразу; включить — с предупреждением про откат браузеров
# на TCP. В Lite модуль лишь сохраняет настройку до включения Pro.
_site_alt_svc_toggle() {
    if [ "$(_cfg '.options.alt_svc')" = "true" ]; then
        website_set_alt_svc off
        return $?
    fi
    # Предупреждение — по тому, кто стоит на UDP/443: в «Сайт и VPN на 443» браузер упрётся в AmneziaWG, а в
    # «VPN и сайт» на 443 никого нет — объявление HTTP/3 без сервера за ним правдоподобия не добавляет (LS-17).
    if [ -n "$(_vpn_443_profile)" ]; then
        log_warning "$(t ms_alt_svc_warn)"
    else
        log_warning "$(t ms_alt_svc_warn_no443)"
    fi
    confirm "$(t ms_alt_svc_ask)" || { log_info "$(t cancelled)"; return 1; }
    website_set_alt_svc on
}

# Панель на домене: путь app-<hex12> (не начинается с a- — маршрут агентов),
# пишется модулем в panel.miniapp_path и site.panel_path. Адрес — секрет,
# показываем только здесь, человеку с root.
_site_panel_apply() {
    local domain="$1" path
    path=$(ga_site_panel_path_new)
    website_panel_path_set "$path" || return 1
    echo -e "  $(t ms_panel_url): ${GREEN}$(_site_panel_url "$domain" "$path")${NC}"
    log_dim "$(ga_wrap "$(t ms_panel_hint_bot)" "${GA_UI_W:-76}" 2)"
}

_site_panel_screen() {
    local ch domain ppath
    # Панели нужен не «режим Pro», а домен с доверенным сертификатом: браузер
    # откажется открывать мини-апп по самоподписанному. Поэтому проверяем именно
    # это — и панель появляется в обоих режимах с сайтом.
    _site_domain_ready || { log_warning "$(t ms_panel_needs_domain)"; return 1; }
    domain=$(_cfg '.domain')
    [ -n "$domain" ] || { log_error "$(t website_err_no_domain)"; return 1; }
    ppath=$(_cfg '.panel.miniapp_path')
    _screen_head "$(t ms_item_panel)" "$(t ms_panel_note)"
    if [ -n "$ppath" ]; then
        echo -e "  $(t ms_panel): ${GREEN}$(t ms_panel_state_on)${NC}"
        echo -e "  $(t ms_panel_url): ${GREEN}$(_site_panel_url "$domain" "$ppath")${NC}"
        echo -e "  ${DIM}$(t ms_panel_hint_bot)${NC}"
        echo -e "  ${CYAN}1${NC}) $(t ms_panel_rotate)"
        echo -e "  ${CYAN}2${NC}) $(t ms_panel_disable)"
    else
        echo -e "  $(t ms_panel): ${DIM}$(t ms_panel_state_off)${NC}"
        echo -e "  ${CYAN}1${NC}) $(t ms_panel_enable)"
    fi
    echo -e "  ${CYAN}0${NC}) $(t back)"
    echo -ne "  ${WHITE}$(t choose):${NC} "
    read -r ch || ch=0
    case "$ch" in
        1)
            if [ -n "$ppath" ]; then
                log_warning "$(t ms_panel_rotate_warn)"
                confirm "$(t ms_panel_rotate_ask)" || { log_info "$(t cancelled)"; return 1; }
            fi
            _site_panel_apply "$domain"
            ;;
        2)
            [ -n "$ppath" ] || { log_error "$(t invalid_choice)"; return 1; }
            confirm "$(t ms_panel_disable_ask)" || { log_info "$(t cancelled)"; return 1; }
            website_panel_path_clear
            ;;
        0) GA_BACK=1; return 0 ;;
        "") GA_BACK=1; return 0 ;;
        *) log_error "$(t invalid_choice)" ;;
    esac
}

# ── Службы бота и панели: общее ─────────────────────────────────────────────

# systemctl экранов меню под сухим прогоном (находка L2-09). Машина, где идёт прогон, — чужая: «Перезапустить
# всё» видело её настоящие юниты и по «1» перезапускало её nginx и службы goamnezia-*, экраны «Бот» и «Панель»
# показывали их состояние, а каждый запуск меню перезапускал её страницы и MCP, если код на диске «изменился».
#   _svc_probe <cat|is-active|is-enabled|show> … — только чтение; в сухом прогоне юнита «нет» (rc 1, пусто).
#     stdout systemctl не глушится (его читают show и is-enabled), stderr — да.
#   _svc_do <restart|disable|daemon-reload|…> … — действие; в сухом прогоне строка «DRY: systemctl …» и успех,
#     иначе systemctl с заглушённым выводом и его код возврата.
_svc_probe() {
    ga_dry && return 1
    systemctl "$@" 2>/dev/null
}
_svc_do() {
    if ga_dry; then ga_dry_echo "systemctl $*"; return 0; fi
    systemctl "$@" >/dev/null 2>&1
}

# Состояние юнита одним словом: running | stopped | not_installed. systemctl cat,
# а не is-enabled: последний отвечает «disabled» и для несуществующего юнита.
_svc_state() {
    local unit="$1"
    _svc_probe cat "$unit" >/dev/null || { printf 'not_installed'; return 0; }
    if _svc_probe is-active --quiet "$unit"; then printf 'running'; else printf 'stopped'; fi
}

_svc_state_line() {
    case "$(_svc_state "$1")" in
        # «Служба … остановлена», в одном роде с «не установлена» (находка T8)
        running) echo -e "${GREEN}$(t svc_card_running)${NC}" ;;
        stopped) echo -e "${YELLOW}$(t svc_card_stopped)${NC}" ;;
        *)       echo -e "${DIM}$(t svc_card_missing)${NC}" ;;
    esac
}

# Карточка службы вместо сырого `systemctl status`. Тот печатал английский текст
# с CGroup, Tasks и Memory — человеку, который нажал «Статус службы», нужны
# четыре вещи: работает ли, поднимется ли сама после перезагрузки, с какого
# времени и чем кончился прошлый запуск (DEFECTS §3.12).
_svc_card() {
    local unit="$1" state since last enabled w k active
    state=$(_svc_state "$unit")
    # _svc_state знает два состояния, а systemd — больше: упавшая по кругу
    # служба с Restart=always показывалась просто «остановлена», и человек не
    # понимал, что она падает (DEFECTS §4.5).
    active=$(_svc_probe show "$unit" -p ActiveState --value)
    case "$active" in
        failed)     state=failed ;;
        activating) state=activating ;;
        deactivating) state=stopped ;;
    esac
    w=0
    for k in svc_card_state svc_card_autostart svc_card_since svc_card_stopped_since \
             svc_card_last svc_card_unit; do
        [ "$(ga_str_width "$(t "$k")")" -gt "$w" ] && w=$(ga_str_width "$(t "$k")")
    done
    case "$state" in
        running)    echo -e "  $(_pad "$(t svc_card_state):" $((w + 2)))${GREEN}$(t svc_card_running)${NC}" ;;
        failed)     echo -e "  $(_pad "$(t svc_card_state):" $((w + 2)))${RED}$(t svc_card_failed)${NC}" ;;
        activating) echo -e "  $(_pad "$(t svc_card_state):" $((w + 2)))${YELLOW}$(t svc_card_activating)${NC}" ;;
        stopped)    echo -e "  $(_pad "$(t svc_card_state):" $((w + 2)))${YELLOW}$(t svc_card_stopped)${NC}" ;;
        *)          echo -e "  $(_pad "$(t svc_card_state):" $((w + 2)))${DIM}$(t svc_card_missing)${NC}"
                    return 0 ;;
    esac
    enabled=$(_svc_probe is-enabled "$unit") || enabled=""
    case "$enabled" in
        enabled|enabled-runtime|static|indirect|generated) enabled="$(t svc_card_on)" ;;
        "") enabled="$(t svc_card_unknown)" ;;
        *)  enabled="$(t svc_card_off)" ;;
    esac
    echo -e "  $(_pad "$(t svc_card_autostart):" $((w + 2)))${CYAN}${enabled}${NC}"
    # systemd печатает «Fri 2026-09-12 14:30:00 UTC»: день недели человеку не
    # нужен, секунды тоже. У остановленной службы спрашиваем момент ОСТАНОВКИ:
    # «Работает с …» под строкой «Состояние: остановлена» — противоречие.
    if [ "$state" = "running" ] || [ "$state" = "activating" ]; then
        since=$(_svc_probe show "$unit" -p ActiveEnterTimestamp --value)
        k=svc_card_since
    else
        since=$(_svc_probe show "$unit" -p InactiveEnterTimestamp --value)
        k=svc_card_stopped_since
    fi
    since="${since#* }"; since="${since/:[0-9][0-9] / }"
    [ -n "$since" ] && echo -e "  $(_pad "$(t "$k"):" $((w + 2)))${CYAN}${since}${NC}"
    # Причина прошлого выхода — словами: «exit-code» и «oom-kill» человеку
    # ничего не говорят. Незнакомое значение печатаем как есть: врать про него
    # хуже, чем показать машинное слово.
    last=$(_svc_probe show "$unit" -p Result --value)
    if [ -n "$last" ] && [ "$last" != "success" ]; then
        case "$last" in
            exit-code)       last="$(t svc_res_exit_code)" ;;
            signal)          last="$(t svc_res_signal)" ;;
            timeout)         last="$(t svc_res_timeout)" ;;
            oom-kill)        last="$(t svc_res_oom)" ;;
            core-dump)       last="$(t svc_res_core)" ;;
            watchdog)        last="$(t svc_res_watchdog)" ;;
            start-limit-hit) last="$(t svc_res_start_limit)" ;;
            resources)       last="$(t svc_res_resources)" ;;
        esac
        echo -e "  $(_pad "$(t svc_card_last):" $((w + 2)))${YELLOW}${last}${NC}"
    fi
    echo -e "  $(_pad "$(t svc_card_unit):" $((w + 2)))${DIM}${unit}${NC}"
    echo -e "  ${DIM}$(ga_wrap "$(tf svc_card_logs_hint "journalctl -u $unit -f")" "${GA_UI_W:-76}" 2)${NC}"
}

# Полное удаление компонента: юнит, файл юнита, рабочая копия. Эталон в
# /opt/goamnezia не трогаем — из него компонент ставится снова одним пунктом.
_component_remove() {
    local unit="$1" dir="$2" sd="${GOAMNEZIA_SYSTEMD_DIR:-/etc/systemd/system}"
    _svc_do disable --now "$unit" || true
    rm -f "$sd/$unit" 2>/dev/null || true
    _svc_do daemon-reload || true
    rm -rf "$dir" 2>/dev/null || true
    return 0
}

# ── Настройки → Панель и мини-апп (docs/PANEL.md §4) ─────────────────────────

# Установка/обновление панели её собственным установщиком из эталонного каталога
# (admin-web/install_admin.sh --auto): python3, копия в /opt/goamnezia-admin,
# токен (существующий сохраняется), юнит, запуск. Язык сообщений — наш.
_panel_install() {
    local inst="$SCRIPT_DIR/admin-web/install_admin.sh"
    if [ ! -f "$inst" ]; then
        log_error "$(tf pn_installer_missing "$inst")"
        return 1
    fi
    log_info "$(t pn_installing)"
    if GOAMNEZIA_LANG="${LANG_CODE:-ru}" bash "$inst" --auto; then
        log_success "$(t pn_installed)"
        _panel_show_access
        return 0
    fi
    log_error "$(t pn_install_failed)"
    return 1
}

# Служба панели стоит? Дёшево и без systemctl — шапка рисуется каждые 30 секунд:
# установщик панели кладёт server.py в ADMIN_DIR, снос каталог убирает.
_panel_service_installed() { [ -f "$ADMIN_DIR/server.py" ]; }
# Панель есть — или её «поставил» сухой прогон (на стенде установщик не зовётся, файлов нет, а экраны мастера
# должны идти той же дорогой, что на сервере).
GA_PANEL_DRY=0
_panel_present() { _panel_service_installed || [ "${GA_PANEL_DRY:-0}" = 1 ]; }

# Панель на домене включается сама вместе с сайтом (решение владельца 17.09.2026): путь выдаёт
# модуль сайта, но без службы по этому адресу открывается ошибка 502. Поэтому, как только сайт
# поднят на домене с настоящим сертификатом и путь панели выдан, ставим и службу — без вопроса.
# Раньше мастер печатал «Панель на домене включена сама», а следом спрашивал «Установить
# веб-панель?» с «нет» по Enter, и шапка показывала адрес, который не открывался (находка T6,
# 25.09.2026). Путь, снятый человеком (panel.miniapp_auto=false), сюда не доходит: его нет.
# Служба уже стоит (мастер поставил её без домена, NC-13) — выдаём пароль, которого человек ещё не видел.
_panel_ensure_service() {
    _site_domain_ready || return 0
    [ -n "$(_cfg '.panel.miniapp_path')" ] || return 0
    if _panel_present; then
        _panel_password_pending_issue || true
        return 0
    fi
    [ -f "$SCRIPT_DIR/admin-web/install_admin.sh" ] || return 0
    if ga_dry; then
        ga_dry_echo "admin-web/install_admin.sh --auto"
        GA_PANEL_DRY=1
        return 0
    fi
    _panel_install || { log_warning "$(t wz_panel_failed_hint)"; return 1; }
}

# Панель без домена (находка NC-13 критика-новичка, 28.09.2026): документы обещали «туннель работает всегда», а в
# «Только VPN» мастер панель не ставил, и туннель упирался в Connection reset. Теперь мастер ставит её во всех
# режимах. Без домена она слушает только 127.0.0.1 и открывается через SSH-туннель без пароля, поэтому установщик
# идёт молча: пароль, который он заводит, нужен лишь для входа с домена — его выдадим, когда панель туда выйдет
# (_panel_password_pending_issue). Обновление эту функцию не зовёт: на уже установленном сервере без панели её
# молча не ставим. rc 1 — не поставилась (мастер идёт дальше: VPN работает и без неё).
_panel_ensure_local() {
    local inst="$SCRIPT_DIR/admin-web/install_admin.sh" out="" rc=0 had_password=0
    _panel_present && return 0
    [ -f "$inst" ] || return 1
    [ -f "$ADMIN_DIR/password.json" ] && had_password=1
    if ga_dry; then
        ga_dry_echo "admin-web/install_admin.sh --auto"
        GA_PANEL_DRY=1
    else
        out=$(GOAMNEZIA_LANG="${LANG_CODE:-ru}" bash "$inst" --auto 2>&1) || rc=$?
        if [ "$rc" != 0 ]; then
            log_warning "$(_ui_w "$(t wz_panel_local_failed)")"
            # Хвост вывода установщика — причина отказа. Пароля в нём нет: установщик печатает его только в самом
            # конце, после того как служба встала.
            printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -n 3 | sed 's/^/    /' >&2
            out=""
            return 1
        fi
        out=""
    fi
    [ "$had_password" = 1 ] || ga_config_merge '{"panel":{"password_pending":true}}' >/dev/null 2>&1 || true
    log_success "$(t wz_panel_local_ok)"
    return 0
}

# Пароль панели, заведённый мастером без показа (панель ставилась только для туннеля), выдаётся, как только панель
# вышла на домен: там без пароля или кода из бота не войти. Только из SSH (мост эту дорогу не зовёт): пароль
# печатается ОДИН раз, в терминал.
# Аргумент quiet — без вступительной строки: сводка Ленивого Pro говорит о пароле своими словами.
_panel_password_pending_issue() {
    local inst="$SCRIPT_DIR/admin-web/install_admin.sh"
    [ "$(_cfg '.panel.password_pending')" = true ] || return 0
    [ -f "$inst" ] || return 0
    [ "${1:-}" = quiet ] || log_info "$(_ui_w "$(t pn_password_pending_issue)")"
    if ga_dry; then
        ga_dry_echo "admin-web/install_admin.sh --reset-password"
    else
        GOAMNEZIA_LANG="${LANG_CODE:-ru}" bash "$inst" --reset-password || { log_warning "$(t pn_password_failed)"; return 1; }
    fi
    _panel_password_pending_clear
}
_panel_password_pending_clear() {
    [ "$(_cfg '.panel.password_pending')" = true ] || return 0
    ga_config_merge '{"panel":{"password_pending":false}}' >/dev/null 2>&1 || true
}

# Команда SSH-туннеля к панели: порт из config.json, адрес — тот, по которому человек зашёл сейчас; не узнать —
# тот, где сторож видит входящие: на машине с несколькими адресами основной бывает исходящим без входящих, и
# туннель на него не соединялся (PUI-25, в панели — tunnel_host). SSH не на 22-м порту — с -p, иначе команда
# с чужого компьютера не соединится.
_panel_port() {
    local port
    port=$(_cfg '.panel.port'); [[ "$port" =~ ^[0-9]+$ ]] || port=1985
    printf '%s' "$port"
}
_panel_tunnel_cmd() {
    local port ip sp=""
    port=$(_panel_port)
    ip=$(_ssh_inbound_ip 2>/dev/null) || ip=""
    if [ -z "$ip" ]; then
        ip=$(_server_ip)
        if [ -n "$ip" ] && type ga_edge_reach_ip >/dev/null 2>&1; then ip=$(ga_edge_reach_ip "$ip" 2>/dev/null) || ip=$(_server_ip); fi
    fi
    [ -n "$ip" ] || ip="<server_ip>"
    sp=$(printf '%s' "${SSH_CONNECTION:-}" | awk '{print $4}')
    if [[ "$sp" =~ ^[0-9]{1,5}$ ]] && [ "$sp" != 22 ]; then sp="-p $sp "; else sp=""; fi
    printf 'ssh %s-L %s:127.0.0.1:%s root@%s' "$sp" "$port" "$port" "$ip"
}

# Три строки «как открыть панель через туннель» — в конце мастера и там, где человеку нужен QR в браузере.
_panel_tunnel_hint() {
    echo -e "  $(ga_win_wrap "$(t wz_panel_tunnel_title)" 2)"
    echo -e "    ${CYAN}$(_panel_tunnel_cmd)${NC}"
    echo -e "  ${DIM}$(ga_win_wrap "$(tf wz_panel_tunnel_open "$(_panel_port)")" 2)${NC}"
}

# Как открыть панель: команда SSH-туннеля с портом из config.json и где лежит
# токен аварийного входа. Сам токен здесь НЕ печатаем — для него отдельный пункт,
# чтобы он не попадал в прокрутку вместе с обычным экраном.
_panel_show_access() {
    echo ""
    echo -e "  ${BOLD}${WHITE}$(t pn_access_title)${NC}"
    echo -e "  $(tf pn_tunnel_hint "$(_panel_port)")"
    echo -e "    ${CYAN}$(_panel_tunnel_cmd)${NC}"
    # Обе строки длиннее окна: печатались без переноса и уезжали за край
    # (DEFECTS §4.6). Соседняя подсказка карточки уже шла через ga_wrap.
    echo -e "  ${DIM}$(_ui_w "$(t pn_login_hint)")${NC}"
    echo -e "  ${DIM}$(_ui_w "$(t pn_token_hint)")${NC}"
}

# ── Аварийный ключ панели (SEC50-08, решение владельца 28.09) ────────────────
# Правило владельца: «на домене — только пароль или код из бота; аварийный ключ — только формировать в SSH полной
# строкой». Поэтому прежний пункт «Показать токен» (постоянный токен из файла) заменён выпуском: каждый вызов — новый
# ключ, прежний перестаёт действовать; ключ живёт час, после входа сгорает и принимается только через SSH-туннель —
# это проверяет служба панели (admin-web/server.py) по файлам token и token.meta рядом с ним. Здесь — только выпуск.
# Формат ключа — как у server.py (_create_token_file: secrets.token_urlsafe(32) — 43 знака base64url), срок —
# {"created": <epoch>, "expires": <epoch + 3600>}. Оба файла 0600 и пишутся времянками в том же каталоге с переносом
# mv: служба не прочтёт половину файла. Сначала готовы обе времянки, потом переносится ключ, потом срок: между двумя mv
# новый ключ живёт по сроку прежнего (не дольше), а прежний ключ по новому сроку не оживает никогда.
# Ключ — только в терминал: не через log_*, не в аудит (там — только срок) и не в мост — бот, панель и MCP его не
# выдают. Без меню — `goamnezia --panel-emergency-key` (install.sh, main).
GA_PANEL_KEY_TTL=3600
_panel_token_file() { printf '%s' "${GOAMNEZIA_ADMIN_TOKEN_FILE:-$ADMIN_DIR/token}"; }

# _panel_key_new → stdout: 32 случайных байта в base64url без «=» (43 знака)
_panel_key_new() {
    local k=""
    if command -v openssl >/dev/null 2>&1; then
        k=$(openssl rand -base64 32 2>/dev/null | tr -d '\n=' | tr '+/' '-_')
    fi
    if ! [[ "$k" =~ ^[A-Za-z0-9_-]{43}$ ]]; then
        k=$(head -c 32 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -d '\n=' | tr '+/' '-_')
    fi
    [[ "$k" =~ ^[A-Za-z0-9_-]{43}$ ]] || return 1
    printf '%s' "$k"
}

# _panel_key_store <файл ключа> <файл срока> <создан> <истекает> — ключ (из переменной GA_PK_KEY: не в argv) и срок,
# оба 0600, времянками в том же каталоге и mv: сначала ключ, потом срок. rc 1 — ничего не перенесено.
_panel_key_store() {
    local f="$1" meta="$2" now="$3" exp="$4" dir tk="" tm=""
    dir=$(dirname "$f")
    tk=$(mktemp "$dir/.token.XXXXXX" 2>/dev/null) || tk=""
    tm=$(mktemp "$dir/.token.meta.XXXXXX" 2>/dev/null) || tm=""
    if [ -z "$tk" ] || [ -z "$tm" ] || ! chmod 600 "$tk" "$tm" 2>/dev/null \
       || ! { printf '%s\n' "${GA_PK_KEY:-}" >"$tk"; } 2>/dev/null \
       || ! { printf '{"created":%s,"expires":%s}\n' "$now" "$exp" >"$tm"; } 2>/dev/null \
       || ! mv -f "$tk" "$f" 2>/dev/null || ! mv -f "$tm" "$meta" 2>/dev/null; then
        rm -f "$tk" "$tm" 2>/dev/null
        return 1
    fi
    return 0
}

# _panel_emergency_key — выпустить ключ и напечатать полной строкой команду туннеля и адрес с ключом.
# rc 1 — панели нет или файлы не записались (прежний ключ тогда не тронут).
_panel_emergency_key() {
    local f dir meta key="" now exp till port
    if ! _panel_service_installed; then
        log_error "$(_ui_w "$(t pn_key_no_panel)")"
        return 1
    fi
    # Срок — рядом с ключом, в <файл ключа>.meta: так его ищет служба (server.py: ADMIN_TOKEN_META).
    f=$(_panel_token_file); dir=$(dirname "$f"); meta="$f.meta"
    key=$(_panel_key_new) || key=""
    now=$(date +%s); exp=$(( now + GA_PANEL_KEY_TTL ))
    # Под общим замком (как миграция): шаг миграции «ключ без срока — прочь» (_migrate_panel_legacy_key) не снимет
    # новый ключ в миг между двумя mv. Замок не взялся (идёт долгое действие) — ключ не выпущен, прежний не тронут.
    # Ключ — в _panel_key_store обычной переменной оболочки, не аргументом и не окружением: дочерние процессы (mktemp,
    # chmod, mv) его не видят.
    GA_ERR_CODE=""; GA_ERR_MSG=""
    GA_PK_KEY="$key"
    if [ -z "$key" ] || ! ga_with_config_lock _panel_key_store "$f" "$meta" "$now" "$exp"; then
        GA_PK_KEY=""; key=""
        log_error "$(_ui_w "${GA_ERR_MSG:-$(tf pn_key_failed "$f")}")"
        return 1
    fi
    GA_PK_KEY=""
    type ga_audit >/dev/null 2>&1 && ga_audit "${GOAMNEZIA_WHO:-ssh}" "panel-emergency-key" "ttl=${GA_PANEL_KEY_TTL} expires=${exp}"
    till=$(date -d "@$exp" +%H:%M 2>/dev/null || date -r "$exp" +%H:%M 2>/dev/null) || till="-"
    port=$(_panel_port)
    echo ""
    log_success "$(t pn_key_done)"
    echo -e "  $(_ui_w "$(t pn_key_rules)")"
    echo ""
    # Обе строки — целиком, без переноса по ширине окна: их копируют как есть.
    echo -e "  $(t pn_key_tunnel)"
    echo -e "    ${CYAN}$(_panel_tunnel_cmd)${NC}"
    echo -e "  $(t pn_key_open)"
    echo -e "    ${CYAN}http://127.0.0.1:${port}/?token=${key}${NC}"
    echo ""
    echo -e "  ${DIM}$(_ui_w "$(tf pn_key_until "$till")")${NC}"
    echo -e "  ${DIM}$(_ui_w "$(t pn_key_secret)")${NC}"
    key=""
    return 0
}

# Перевыпуск пароля панели. Вход по логину и паролю есть всегда, а узнать о нём
# и сменить его можно было только из текста на самой странице входа — куда ещё
# надо как-то попасть. Пункт зовёт тот же install_admin.sh --reset-password,
# что и раньше набирали руками, и печатает выданную пару один раз.
_panel_password_reset() {
    local inst="$SCRIPT_DIR/admin-web/install_admin.sh"
    if [ ! -f "$inst" ]; then
        log_error "$(tf pn_installer_missing "$inst")"
        return 1
    fi
    log_warning "$(_ui_w "$(t pn_password_warn)")"
    confirm "$(t pn_password_ask)" || { log_info "$(t cancelled)"; return 1; }
    GOAMNEZIA_LANG="${LANG_CODE:-ru}" bash "$inst" --reset-password || {
        log_error "$(t pn_password_failed)"; return 1; }
    # Пароль показан — выдавать его ещё раз при выходе панели на домен незачем
    _panel_password_pending_clear
}

_panel_remove() {
    log_warning "$(t pn_remove_warn)"
    confirm "$(t pn_remove_ask)" || { log_info "$(t cancelled)"; return 1; }
    # Панель на домене снимаем первой: иначе nginx проксировал бы в пустоту
    if [ -n "$(_cfg '.panel.miniapp_path')" ] && type website_panel_path_clear >/dev/null 2>&1; then
        website_panel_path_clear >/dev/null 2>&1 || true
    fi
    _component_remove goamnezia-admin.service "$ADMIN_DIR"
    # Файл пароля ушёл вместе с каталогом: новая установка заведёт и покажет свой
    _panel_password_pending_clear
    log_success "$(t pn_removed)"
}

_panel_screen() {
    local ch port unit="goamnezia-admin.service"
    while true; do
        port=$(_cfg '.panel.port'); [[ "$port" =~ ^[0-9]+$ ]] || port=1985
        echo ""
        echo -e "  ${BOLD}${WHITE}$(t pn_title)${NC}"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -e "  $(t pn_state): $(_svc_state_line "$unit")    $(t pn_port_label): ${CYAN}${port}${NC}"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -e "  ${CYAN}1${NC}) $(t pn_install)"
        echo -e "  ${CYAN}2${NC}) $(t pn_status)"
        echo -e "  ${CYAN}3${NC}) $(t pn_logs)"
        echo -e "  ${CYAN}4${NC}) $(t pn_restart)"
        echo -e "  ${CYAN}5${NC}) $(t pn_token)"
        echo -e "  ${CYAN}6${NC}) $(t pn_password)"
        echo -e "  ${CYAN}7${NC}) $(t pn_domain)"
        echo -e "  ${CYAN}8${NC}) ${RED}$(t pn_remove)${NC}"
        echo -e "  ${CYAN}0${NC}) $(t back)"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0
        case "$ch" in
            1) _panel_install ;;
            2)
                if [ "$(_svc_state "$unit")" = "not_installed" ]; then
                    log_warning "$(t pn_not_installed_hint)"
                else
                    _svc_card "$unit"
                    _panel_show_access
                fi
                ;;
            3)
                echo ""
                echo -e "  ${BOLD}${WHITE}$(t pn_logs_title)${NC}"
                _logs_print admin 60
                ;;
            4)
                if [ "$(_svc_state "$unit")" = "not_installed" ]; then
                    log_warning "$(t pn_not_installed_hint)"
                elif _svc_do restart "$unit"; then
                    log_success "$(t pn_restarted)"
                else
                    log_error "$(t pn_restart_failed)"
                fi
                ;;
            5) _panel_emergency_key ;;
            6) _panel_password_reset ;;
            7) _site_panel_screen ;;
            8) _panel_remove ;;
            0) GA_BACK=1; return 0 ;;
            "") continue ;;
            *) log_error "$(t invalid_choice)" ;;
        esac
        _pause
    done
}

# ── Настройки → Доступы агентов (MCP по HTTP), PLAN §6.10, docs/MENU.md §6.3 ──
# Экран компонента по образцу _panel_screen: шапка с состоянием транспорта,
# список доступов, действия. Всё делает lib/agents.sh; здесь только вопросы,
# подтверждения и показ. Секрет (url) печатается ТОЛЬКО в терминал — не через
# log_* и не в аудит (там лишь id, как у токена панели).
_agents_require() {
    type agents_list >/dev/null 2>&1 && return 0
    log_error "$(tf module_missing agents_list)"
    return 1
}

# Состояние доступа по его же карточке — тем же правилом, что и в списке
# (agents_list): заморожен → выключен → истёк → действует. Карточка состояние не
# показывала вовсе: после «Доступ выключен» она выглядела как карточка рабочего
# и предлагала скопировать команду подключения, которая заведомо получит 404.
_agents_card_state() {
    local card="$1" exp epoch now
    [ "$(_json_field "$card" .compromised)" = true ] && { printf 'compromised'; return 0; }
    [ "$(_json_field "$card" .enabled)" = false ] && { printf 'disabled'; return 0; }
    exp=$(_json_field "$card" .expires)
    if [ -n "$exp" ] && type ga_agents_iso_epoch >/dev/null 2>&1; then
        epoch=$(ga_agents_iso_epoch "$exp" 2>/dev/null) || epoch=""
        now=$(date -u +%s 2>/dev/null) || now=0
        if [[ "$epoch" =~ ^[0-9]+$ ]] && [ "$epoch" -lt "$now" ]; then printf 'expired'; return 0; fi
    fi
    printf 'active'
}

_agents_state_name() {
    case "${1:-}" in
        active)      t ag_state_active ;;
        disabled)    t ag_state_disabled ;;
        expired)     t ag_state_expired ;;
        compromised) t ag_state_compromised ;;
        *)           printf '%s' "${1:-}" ;;
    esac
}
_agents_state_color() {
    case "${1:-}" in
        active)      printf '%s' "$GREEN" ;;
        expired)     printf '%s' "$YELLOW" ;;
        compromised) printf '%s' "$RED" ;;
        *)           printf '%s' "$DIM" ;;
    esac
}
_agents_unit_line() {
    # Служба — она: «остановлена», «не установлена» (слова карточки служб, а не профиля; находка LS-07)
    case "${1:-}" in
        active)   echo -e "${GREEN}$(t svc_card_running)${NC}" ;;
        inactive) echo -e "${YELLOW}$(t svc_card_stopped)${NC}" ;;
        dry)      echo -e "${DIM}$(t ag_unit_dry)${NC}" ;;
        *)        echo -e "${DIM}$(t svc_card_missing)${NC}" ;;
    esac
}

# Шапка: транспорт (включён/выключен, где живёт адрес, отпечаток), служба.
_agents_print_transport() {
    local st="$1" enabled configured listen base fp unit hint
    enabled=$(_json_field "$st" .enabled); listen=$(_json_field "$st" .listen)
    configured=$(_json_field "$st" .configured)
    base=$(_json_field "$st" .base_url); fp=$(_json_field "$st" .cert_fingerprint_sha256)
    unit=$(_json_field "$st" .unit_state); hint=$(_json_field "$st" .hint)
    # Состояний три, а не два: «включён» в конфиге и «работает» — разные вещи,
    # и после ухода из Pro в Lite шапка бодро писала «включён» над транспортом,
    # которому негде слушать (DEFECTS §1.8). Третья строка называет это прямо.
    if [ "$enabled" = true ]; then
        echo -e "  $(t ag_transport): ${GREEN}$(t ag_transport_on)${NC}"
    elif [ "$configured" = true ]; then
        echo -e "  $(t ag_transport): ${YELLOW}$(t ag_transport_no_place)${NC}"
    else
        echo -e "  $(t ag_transport): ${DIM}$(t ag_transport_off)${NC}"
    fi
    case "$listen" in
        nginx)                   echo -e "  ${DIM}$(tf ag_listen_nginx "$base")${NC}" ;;
        public_port|grant_ports) echo -e "  ${DIM}$(tf ag_listen_port "${base:--}")${NC}" ;;
        *)                       echo -e "  ${DIM}$(t ag_listen_none)${NC}" ;;
    esac
    [ -n "$fp" ] && echo -e "  $(t ag_fingerprint): ${CYAN}${fp}${NC}"
    echo -e "  $(t ag_unit): $(_agents_unit_line "$unit")"
    [ -n "$hint" ] && echo -e "  ${DIM}${hint}${NC}"
    return 0
}

# Список доступов одной таблицей: № · id · метка · уровень · второй фактор ·
# срок · последний вызов и IP · вызовы · состояние. Один вызов jq на весь список.
# Колонка «2ф» — не украшение: доступ без токена живёт на одном лишь адресе, и
# человек должен видеть это в списке, а не узнавать после утечки.
_agents_print_list() {
    local list="$1" n i=0 id label scope exp last ip calls state weak pin mode pending codegone color tf_col tf_color pad weak_n frozen_n
    n=$(jq -r 'length' <<<"$list" 2>/dev/null) || n=0
    echo -e "  ${BOLD}${WHITE}$(t ag_list_title)${NC}"
    if [ "$n" = 0 ]; then
        echo -e "  ${DIM}$(t ag_list_empty)${NC}"
        return 0
    fi
    echo -e "  ${DIM}$(t ag_list_cols)${NC}"
    # Разделитель — \x1f, а не табуляция: табуляция входит в IFS-пробелы, и bash
    # схлопывает подряд идущие такие разделители в один. У свежего доступа пусты
    # и срок, и последний вызов, и его адрес — три пустых поля подряд съезжали, и
    # в колонке «вызовы» оказывалось состояние. \x1f управляющий, а в метке
    # управляющих нет (ga_agents_label_valid их запрещает).
    while IFS=$'\x1f' read -r id label scope exp last ip calls state weak pin mode pending codegone; do
        i=$((i + 1))
        # Пустое поле — ответ моста без вида доступа (старая сборка): это static
        [ -n "$mode" ] || mode="static"
        if [ -n "$exp" ]; then exp="${exp%%T*}"; else exp="$(t never)"; fi
        # Дата и время до минут, БЕЗ адреса вызова: адрес в строку не помещался
        # и выталкивал «вызовы» и «состояние» вправо ровно на свою длину — в
        # списке из нескольких доступов столбцы переставали быть столбцами.
        # Адрес теперь в карточке, где под него есть место и подпись.
        if [ -n "$last" ]; then last="${last%%T*} ${last#*T}"; last="${last%Z}"; last="${last%:*}"; else last="—"; fi
        # Колонка «2ф» отвечает на один вопрос: чем доказывается право, кроме
        # адреса. У rolling это одноразовый ключ — он и сильнее токена, и виден
        # в списке иначе, чтобы «ключ» не путали с «токеном».
        # У переходника до привязки второго фактора ещё нет — есть код, который ждёт.
        if [ "$mode" = connect ] && [ "$codegone" = true ]; then tf_col=$(t ag_second_factor_expired); tf_color="$RED"
        elif [ "$mode" = connect ] && [ "$pending" = true ]; then tf_col=$(t ag_second_factor_code); tf_color="$YELLOW"
        elif [ "$mode" = rolling ] || [ "$mode" = connect ]; then tf_col=$(t ag_second_factor_key); tf_color="$CYAN"
        elif [ "$weak" = true ]; then tf_col=$(t ag_second_factor_off); tf_color="$RED"
        else tf_col=$(t ag_second_factor_on); tf_color="$GREEN"; fi
        # Значок привязки — ПЕРЕД меткой: в хвосте его срезала бы точность %-26.26s
        [ "$pin" = true ] && label="⚲ ${label}"
        color=$(_agents_state_color "$state")
        # Колонку «2ф» набиваем сами: в значении есть цветовые последовательности,
        # и printf посчитал бы их за ширину, разъехав таблицу.
        pad=$(( 5 - $(ga_str_width "$tf_col") )); [ "$pad" -lt 1 ] && pad=1
        printf '  %-2s %-8s %s %-8s ' "$i" "$id" "$(ga_cell "$label" 26)" "$scope"
        echo -ne "${tf_color}${tf_col}${NC}"
        printf '%*s' "$pad" ""
        printf '%-11s %-17s %-7s ' "$exp" "$last" "$calls"
        echo -e "${color}$(_agents_state_name "$state")${NC}"
    done < <(jq -r '.[] | [.id, .label, .scope, (.expires // ""), (.last_used // ""), (.last_ip // ""), (.calls // 0), .state, (.weak == true), (.pin_ip == true), (.mode // "static"), (.enroll_pending == true), (.enroll_expired == true)] | map(tostring) | join("\u001f")' <<<"$list" 2>/dev/null)
    weak_n=$(jq -r '[.[] | select(.weak == true)] | length' <<<"$list" 2>/dev/null) || weak_n=0
    [ "${weak_n:-0}" -gt 0 ] 2>/dev/null && log_warning "$(tf ag_weak_note "$weak_n")"
    # Заморозка — не пометка в строке, а требование решения: доступ уже никого не
    # впускает, и пока владелец не выбрал «перевыпустить» или «удалить», агент стоит.
    frozen_n=$(jq -r '[.[] | select(.compromised == true)] | length' <<<"$list" 2>/dev/null) || frozen_n=0
    [ "${frozen_n:-0}" -gt 0 ] 2>/dev/null && log_error "$(tf ag_frozen_note "$frozen_n")"
    return 0
}

# Номер из списка → id в stdout (вопрос и ошибки — в stderr: зовётся через $()).

# Карточка с адресом: адрес, токен, готовая команда подключения, отпечаток, QR
# адреса и предупреждение «это пароль». Адрес и токен — только echo в терминал.
#
# Почему адрес и токен показаны РАЗНЫМИ строками, а «одной строкой для отправки»
# нет вовсе: единая строка сама просится в мессенджер, а именно пересылка и есть
# самый частый способ потерять доступ. Для настройки клиента есть одна команда —
# и она помечена как пароль. QR печатается только для адреса: в него токен не
# кладём, иначе снимок экрана снова стал бы полным ключом.
_agents_show_card() {
    local card="$1" id label scope url token req fp hint warn te connect weak pin pinned pin_line \
          mode key key_hint one_client frozen frozen_at frozen_ip last_used last_ip code code_hint storage cget cnote codegone
    id=$(_json_field "$card" .id); label=$(_json_field "$card" .label); scope=$(_json_field "$card" .scope)
    code=$(_json_field "$card" .enroll_code); code_hint=$(_json_field "$card" .enroll_hint)
    storage=$(_json_field "$card" .key_storage); cget=$(_json_field "$card" .connector_hint)
    cnote=$(_json_field "$card" .connect_note); codegone=$(_json_field "$card" .enroll_expired)
    url=$(_json_field "$card" .url); fp=$(_json_field "$card" .cert_fingerprint_sha256)
    token=$(_json_field "$card" .token); req=$(_json_field "$card" .require_token)
    connect=$(_json_field "$card" .connect); weak=$(_json_field "$card" .weak_hint)
    pin=$(_json_field "$card" .pin_ip); pinned=$(_json_field "$card" .pinned_ip)
    mode=$(_json_field "$card" .mode); key=$(_json_field "$card" .key); key_hint=$(_json_field "$card" .key_hint)
    one_client=$(_json_field "$card" .one_client_hint); frozen=$(_json_field "$card" .compromised)
    frozen_at=$(_json_field "$card" .compromised_at); frozen_ip=$(_json_field "$card" .compromised_ip)
    last_used=$(_json_field "$card" .last_used); last_ip=$(_json_field "$card" .last_ip)
    hint=$(_json_field "$card" .cert_hint); warn=$(_json_field "$card" .warning); te=$(_json_field "$card" .transport_enabled)
    echo ""
    echo -e "  ${BOLD}${WHITE}$(tf ag_card_title "$id" "$label")${NC}"
    echo -e "  ${DIM}$(_rule)${NC}"
    local st_now st_color
    st_now=$(_agents_card_state "$card"); st_color=$(_agents_state_color "$st_now")
    echo -e "  $(t ag_card_state): ${st_color}$(_agents_state_name "$st_now")${NC}"
    echo -e "  $(t ag_card_level): ${CYAN}${scope}${NC}"
    case "$mode" in
        connect)
            echo -e "  $(t ag_card_mode): ${CYAN}$(t ag_card_mode_connect)${NC}"
            case "$storage" in
                tpm)  echo -e "  $(t ag_card_storage): ${GREEN}$(t ag_card_storage_tpm)${NC}" ;;
                file) echo -e "  $(t ag_card_storage): ${YELLOW}$(t ag_card_storage_file)${NC}" ;;
                *)    if [ "$codegone" = true ]; then
                          echo -e "  $(t ag_card_storage): ${RED}$(t ag_card_storage_code_expired)${NC}"
                      else
                          echo -e "  $(t ag_card_storage): ${DIM}$(t ag_card_storage_pending)${NC}"
                      fi ;;
            esac ;;
        rolling) echo -e "  $(t ag_card_mode): ${CYAN}$(t ag_card_mode_rolling)${NC}" ;;
        *)       echo -e "  $(t ag_card_mode): ${CYAN}$(t ag_card_mode_static)${NC}" ;;
    esac
    # Заморозка — первое, что человек должен увидеть в карточке: доступ стоит, и
    # два времени с двумя адресами здесь для того, чтобы решение принималось по
    # фактам, а не по догадке (docs/MCP_ROTATION.md §11.3).
    if [ "$frozen" = true ]; then
        echo ""
        log_error "$(t ag_card_frozen)"
        echo -e "  ${RED}$(tf ag_frozen_line "${frozen_at:--}" "${frozen_ip:--}" "${last_used:--}" "${last_ip:--}")${NC}"
        echo ""
    fi
    # Последний вызов и адрес, с которого он пришёл: в списке для адреса места
    # нет, а знать его нужно — это единственный след того, кто ходит доступом.
    if [ -n "$last_used" ]; then
        echo -e "  $(t ag_card_last): ${CYAN}$(ga_human_ts "$last_used")${NC}${last_ip:+ ${DIM}$(tf ag_card_from "$last_ip")${NC}}"
    else
        echo -e "  $(t ag_card_last): ${DIM}$(t ag_card_last_never)${NC}"
    fi
    # У доступа через переходник неподвижного адреса нет: путь плавающий.
    if [ -n "$url" ]; then
        echo -e "  $(t ag_card_url):"
        echo -e "    ${GREEN}${url}${NC}"
    fi
    if [ "$req" = true ] && [ -n "$token" ]; then
        echo -e "  $(t ag_card_token):"
        echo -e "    ${GREEN}${token}${NC}"
    fi
    # Одноразовый ключ показывается ровно один раз — сразу после выдачи или
    # перевыпуска. На сервере остаётся только отпечаток, повторить показ нечем.
    if [ -n "$key" ]; then
        echo -e "  $(t ag_card_key):"
        echo -e "    ${GREEN}${key}${NC}"
        [ -n "$key_hint" ] && echo -e "  ${DIM}${key_hint}${NC}"
    fi
    # Код привязки — тоже один раз: на сервере лежит только его отпечаток.
    if [ -n "$code" ]; then
        echo -e "  $(t ag_card_enroll_code):"
        echo -e "    ${GREEN}${code}${NC}"
        [ -n "$code_hint" ] && echo -e "  ${DIM}$(ga_win_wrap "$code_hint" 2)${NC}"
    fi
    if [ "$pin" = true ] && [ -n "$pinned" ]; then pin_line=$(tf ag_pin_state_on "$pinned")
    elif [ "$pin" = true ]; then pin_line=$(t ag_pin_state_wait)
    else pin_line=$(t ag_pin_state_off); fi
    echo -e "  $(t ag_card_pin): ${CYAN}${pin_line}${NC}"
    # У переходника команды может не быть вовсе (привязан, код истёк): тогда вместо
    # «Команда подключения» с пустой строкой — пояснение.
    if [ -n "$connect" ]; then
        echo -e "  $(t ag_card_cmd):"
        echo -e "    ${CYAN}${connect}${NC}"
    fi
    [ -n "$cnote" ] && echo -e "  ${DIM}$(ga_win_wrap "$cnote" 2)${NC}"
    if [ -n "$fp" ]; then
        echo -e "  $(t ag_fingerprint): ${CYAN}${fp}${NC}"
        [ -n "$hint" ] && echo -e "  ${DIM}${hint}${NC}"
    fi
    echo ""
    [ -n "$warn" ] && log_warning "$warn"
    [ -n "$weak" ] && log_warning "$weak"
    [ -n "$one_client" ] && log_warning "$one_client"
    if [ "$te" != true ]; then
        if [ "$mode" = connect ]; then log_warning "$(t agents_hint_transport_off_connect)"
        else log_warning "$(t agents_hint_transport_off)"; fi
    fi
    [ -n "$cget" ] && log_dim "$cget"
    echo ""
    # QR — только при выдаче и перевыпуске, то есть когда карточку показывают
    # ОДИН раз. На экране карточки она перерисовывается после каждого действия,
    # и картинка на сорок строк уносила пункты меню за нижний край: на окне
    # 80×24 после любого нажатия пунктов не видно вовсе. Там QR вызывается
    # отдельным пунктом.
    if [ "${GA_AG_CARD_QR:-1}" = 1 ] && [ -n "$url" ]; then
        echo -e "  ${DIM}$(t ag_qr_title)${NC}"
        _qr_utf8 "$url"
    fi
    echo ""
}

# Выдать доступ: название → уровень → вид доступа → срок → привязка к адресу →
# адреса → (Lite) отдельный порт. Enter на сроке даёт 30 дней; «0»
# переспрашивается — бессрочный доступ переживает утечку, о которой никто не узнал.
_agents_add_interactive() {
    local label scope="" days ips port="" pin="off" mode="static" choice card ans
    echo ""
    # Через ga_ask: «0» — назад, как везде в меню; голый read делал из нуля название доступа. Длину проверяет
    # модуль символами при любой локали (ga_agents_label_valid): шаблон «^.{1,48}$» в SSH с LANG=C считал байты, и
    # название кириллицей упиралось в предел вдвое раньше (L1-15 / TAIL-8). Не годится — переспрашиваем.
    while true; do
        label=$(ga_ask "$(t ag_ask_label)" '.' "$(t ag_bad_label)") || { log_info "$(t cancelled)"; return 1; }
        ga_agents_label_valid "$label" && break
        log_error "$(t ag_bad_label)"
    done
    choice=$(select_option "$(t ag_ask_scope)" "$(t ag_scope_read)" "$(t ag_scope_write)" "$(t ag_scope_admin)")
    # Enter даёт read — наименьшие права, как и во всех остальных интерфейсах.
    # Прежде Enter означал write, а это уровень, который выдаёт приватный ключ
    # ЛЮБОГО клиента: владелец, проскочивший вопрос, раздавал его не читая.
    case "$choice" in
        1|"") scope="read" ;;
        2) scope="write" ;;
        3) scope="admin" ;;
        0) log_info "$(t cancelled)"; return 1 ;;
        *) log_error "$(t invalid_choice)"; return 1 ;;
    esac
    # Вид доступа спрашивается явно и по умолчанию даёт static: rolling требует
    # клиента, который сам хранит ключ, а обычный клиент MCP этого не умеет —
    # выдать такой доступ молча значило бы выдать нерабочий.
    log_info "$(t ag_mode_note)"
    choice=$(select_option "$(t ag_ask_mode)" "$(t ag_mode_item_static)" "$(t ag_mode_item_rolling)" \
             "$(t ag_mode_item_connect)")
    case "$choice" in
        1|"") mode="static" ;;
        2) mode="rolling" ;;
        3)
            mode="connect"
            # Код живёт 10 минут: транспорт проверяем сразу, а не после всех вопросов мастера
            if ! ga_agents_http_enabled; then log_error "$(t agents_err_connect_transport_off)"; return 1; fi
            ;;
        0) log_info "$(t cancelled)"; return 1 ;;
        *) log_error "$(t invalid_choice)"; return 1 ;;
    esac
    echo -ne "  ${WHITE}$(tf ag_ask_days "$GA_AGENTS_DEFAULT_DAYS"):${NC} "
    read -r days || days=""
    days="${days:-$GA_AGENTS_DEFAULT_DAYS}"
    if ! [[ "$days" =~ ^[0-9]{1,4}$ ]] || [ "$days" -gt 3650 ]; then log_error "$(t ag_bad_days)"; return 1; fi
    if [ "$days" = 0 ]; then
        log_warning "$(t agents_warn_forever)"
        confirm "$(t ag_forever_warn)" || { log_info "$(t cancelled)"; return 1; }
    fi
    # Да/нет — как везде в продукте, цифрой: «(y/N)» принимало только буквы, и «1» молча
    # значило «нет» (находка T12, 25.09.2026). confirm сам дописывает «[1 — да, 0 — нет]».
    if confirm "$(t ag_ask_pin)"; then pin="on"; else pin="off"; fi
    echo -ne "  ${WHITE}$(t ag_ask_ips):${NC} "
    read -r ips || ips=""
    ips="${ips// /}"
    ga_agents_ips_valid "$ips" || { log_error "$(t ag_bad_ips)"; return 1; }
    # Персональный порт — опция Lite: в режимах с сайтом адрес живёт на 443
    if [ "$(_mode_current)" = "lite" ]; then
        if ga_agents_http_enabled 2>/dev/null; then
            port=$(_ask_agent_port "$(t ag_ask_port)")
        else
            # В «Только VPN» без включённого транспорта доступу без своего порта жить негде: подсказка «Enter —
            # не нужен» вела к отказу needs_site после всех ответов (находка SR-53). Здесь порт обязателен, а
            # Enter берёт предложенный свободный.
            local sug=""
            sug=$(ga_agents_random_port 2>/dev/null) || sug=""
            port=$(_ask_agent_port "$(tf ag_ask_port_required "${sug:--}")" "$sug")
            [ -n "$port" ] || { log_error "$(t ag_bad_port)"; return 1; }
        fi
    fi
    card=$(agents_add "$label" "$scope" "$days" "$ips" "$port" "$pin" "$mode") || return 1
    _agents_show_card "$card"
}

# Продлить срок доступа: число дней → переспрос → agents_extend.
#
# Отдельный пункт, а не «перевыпустить со сроком»: перевыпуск меняет секрет и
# токен, то есть требует перенастроить клиента агента, а истечение — календарь, а
# не компрометация. Модуль и мост это умели с самого начала, а в SSH-меню пункта
# не было вовсе — при том что тревоги бота («срок на исходе», «доступ истёк»)
# ведут человека именно сюда, дословно: «Настройки → Доступы агентов → карточка
# доступа → Продлить». Строки словаря под пункт тоже были написаны заранее и не
# запрашивались ни одной строкой кода.
_agents_extend_interactive() {
    local id="$1" days
    log_info "$(t ag_extend_note)"
    echo -ne "  ${WHITE}$(tf ag_ask_extend_days "$GA_AGENTS_DEFAULT_DAYS"):${NC} "
    read -r days || days=""
    days="${days:-$GA_AGENTS_DEFAULT_DAYS}"
    if ! [[ "$days" =~ ^[0-9]{1,4}$ ]] || [ "$days" -gt 3650 ]; then log_error "$(t ag_bad_days)"; return 1; fi
    # Ноль — не «продлить на ноль дней», а СНЯТЬ срок совсем. Это ослабление, и
    # спрашивается оно тем же вопросом, что и при выдаче: общий «продлить на 0
    # дней?» скрыл бы от человека, что доступ станет бессрочным и переживёт
    # утечку, о которой никто не узнал.
    if [ "$days" = 0 ]; then
        log_warning "$(t agents_warn_forever)"
        confirm "$(t ag_forever_warn)" || { log_info "$(t cancelled)"; return 1; }
    else
        confirm "$(tf ag_extend_ask "$id" "$(ga_days "$days")")" || { log_info "$(t cancelled)"; return 1; }
    fi
    agents_extend "$id" "$days" >/dev/null
}

# Включить/выключить транспорт. В Lite без сайта — только на отдельном TLS-порту:
# спрашиваем порт (по умолчанию прежний или случайный 30000–49999).
_agents_transport_toggle() {
    local st configured port="" def
    st=$(agents_http_status 2>/dev/null) || st=""
    # Выключаем по ЗАПИСАННОМУ состоянию, а не по фактическому: флаг, оставшийся
    # от прежнего режима, иначе снять было бы нечем — кнопки «выключить» просто
    # не было бы, а «включить» отвечало бы «уже включено».
    configured=$(_json_field "$st" .configured)
    if [ "$configured" = true ]; then
        confirm "$(t ag_transport_off_ask)" || { log_info "$(t cancelled)"; return 1; }
        agents_http_off >/dev/null || return 1
        return 0
    fi
    if [ "$(_mode_current)" = "lite" ]; then
        log_info "$(t ag_transport_on_lite_note)"
        def=$(ga_agents_public_port)
        [ -n "$def" ] || def=$(ga_agents_random_port 2>/dev/null) || def=""
        port=$(_ask_agent_port "$(tf ag_ask_public_port "${def:--}")" "$def")
        # Предложить нечего и человек ничего не назвал — включать транспорт
        # некуда: без порта в Lite он слушает в пустоту.
        [ -n "$port" ] || { log_error "$(t ag_bad_port)"; return 1; }
    fi
    confirm "$(t ag_transport_on_ask)" || { log_info "$(t cancelled)"; return 1; }
    st=$(agents_http_on "$port") || return 1
    echo ""
    _agents_print_transport "$st"
}

_agents_screen() {
    local ch st list n id
    _agents_require || return 1
    while true; do
        st=$(agents_http_status 2>/dev/null) || st=""
        list=$(agents_list 2>/dev/null) || list="[]"
        n=$(jq -r 'length' <<<"$list" 2>/dev/null) || n=0
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
        echo ""
        echo -e "  ${BOLD}${WHITE}$(t ag_title)${NC}"
        echo -e "  ${DIM}$(_rule)${NC}"
        _agents_print_transport "$st"
        # Когда транспорт выключен, ту же команду уже назвал его собственный
        # ответ (agents_status_hint_off) — второй раз подряд она читается как
        # сбой печати, а не как подсказка.
        [ "$(_json_field "$st" .enabled)" = true ] && echo -e "  ${DIM}$(t ag_ssh_hint)${NC}"
        echo -e "  ${DIM}$(_rule)${NC}"
        _agents_print_list "$list"
        echo -e "  ${DIM}$(_rule)${NC}"
        # Экран был на одиннадцать пунктов, и каждый начинался с «а теперь
        # назовите номер доступа». Теперь как у пользователей: номер строки
        # открывает карточку, и все действия над доступом живут в ней, а на
        # этом экране остаётся только общее — выдать, транспорт, журнал.
        local n_add n_tr n_logs
        n_add=$(( n + 1 )); n_tr=$(( n + 2 )); n_logs=$(( n + 3 ))
        echo -e "  ${CYAN}${n_add}${NC}) $(t ag_item_add)"
        # По configured, а не по enabled: транспорт, которому негде слушать,
        # всё равно записан в конфиге — и выключить его должно быть чем.
        if [ "$(_json_field "$st" .configured)" = true ]; then
            echo -e "  ${CYAN}${n_tr}${NC}) $(t ag_item_transport_off)"
        else
            echo -e "  ${CYAN}${n_tr}${NC}) $(t ag_item_transport_on)"
        fi
        echo -e "  ${CYAN}${n_logs}${NC}) $(t ag_item_logs)"
        echo -e "  ${CYAN}0${NC}) $(t back)"
        echo -e "  ${DIM}$(ga_win_wrap "$(tf ag_pick_legend "$n_add" "$n_tr" "$n_logs")" 2)${NC}"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0
        case "$ch" in
            "$n_add") _agents_add_interactive ;;
            "$n_tr") _agents_transport_toggle ;;
            "$n_logs")
                echo ""
                echo -e "  ${BOLD}${WHITE}$(t ag_logs_title)${NC}"
                if command -v journalctl >/dev/null 2>&1; then
                    journalctl -u goamnezia-mcp-http.service -n 60 --no-pager 2>&1 || log_warning "$(t ag_logs_empty)"
                else
                    log_warning "$(t ag_logs_empty)"
                fi
                ;;
            0) GA_BACK=1; return 0 ;;
            "") continue ;;
            *)
                # Любое число — это строка списка. Образец «a && b || c» здесь
                # врал: непустой id с карточкой, вернувшей отказ, печатал «такой
                # строки нет», хотя строка была. И класс [1-9][0-9] молча
                # отвергал бы сотый доступ.
                # Не длиннее четырёх цифр и десятично: «08» — не восьмеричное, число длиннее int64 не роняет
                # сравнение (SR-53).
                if ! [[ "$ch" =~ ^[0-9]{1,4}$ ]] || [ "$((10#$ch))" -lt 1 ] || [ "$((10#$ch))" -gt "$n" ]; then
                    log_error "$(t ag_bad_number)"
                else
                    id=$(jq -r --argjson i "$((10#$ch))" '.[$i - 1].id // empty' <<<"$list" 2>/dev/null) || id=""
                    if [ -n "$id" ]; then
                        _agents_card_screen "$id"
                    else
                        log_error "$(t ag_bad_number)"
                    fi
                fi
                ;;
        esac
        _pause
    done
}

# Карточка доступа и всё, что с ним делают. Раньше это были семь пунктов
# главного экрана, и каждый заново спрашивал номер доступа — человек выбирал
# один и тот же доступ по три раза подряд, чтобы посмотреть, продлить и выдать
# токен. Здесь доступ выбран один раз, и он же виден на экране.
_agents_card_screen() {
    local id="$1" ch card rec list label choice cmode curl creq ask
    while true; do
        card=$(agents_show "$id" 2>/dev/null) || card=""
        if [ -z "$card" ]; then log_error "$(tf ag_not_found "$id")"; return 1; fi
        GA_AG_CARD_QR=0 _agents_show_card "$card"
        cmode=$(_json_field "$card" .mode); curl=$(_json_field "$card" .url); creq=$(_json_field "$card" .require_token)
        echo -e "  ${DIM}$(_rule)${NC}"
        if [ "$cmode" = connect ]; then
            echo -e "  ${CYAN}1${NC}) $(t ag_item_rotate_connect)"
        else
            echo -e "  ${CYAN}1${NC}) $(t ag_item_rotate)"
        fi
        # «Выдать токен» — только старому доступу без второго фактора: у остальных он уже
        # есть (у rolling и переходника — одноразовый ключ), и пункт вёл бы к отказу.
        if [ "$creq" != true ] && [ "$cmode" = static ]; then
            echo -e "  ${CYAN}2${NC}) $(t ag_item_harden)"
        fi
        echo -e "  ${CYAN}3${NC}) $(t ag_item_pin)"
        # Продление — рядом с остальными действиями над тем же доступом: тревоги
        # бота ведут человека именно сюда.
        echo -e "  ${CYAN}4${NC}) $(t ag_item_extend)"
        if [ "$(_agents_card_state "$card")" = disabled ]; then
            echo -e "  ${CYAN}5${NC}) $(t ag_item_enable)"
        else
            echo -e "  ${CYAN}5${NC}) $(t ag_item_disable)"
        fi
        echo -e "  ${CYAN}6${NC}) ${RED}$(t ag_item_del)${NC}"
        # QR адреса — только когда адрес есть: у переходника путь плавающий.
        [ -n "$curl" ] && echo -e "  ${CYAN}7${NC}) $(t ag_item_qr)"
        echo -e "  ${CYAN}0${NC}) $(t back)"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0
        case "$ch" in
            1)
                if [ "$cmode" = connect ]; then
                    log_warning "$(t ag_rotate_warn_connect)"; ask=$(tf ag_rotate_ask_connect "$id")
                else
                    log_warning "$(t ag_rotate_warn)"; ask=$(tf ag_rotate_ask "$id")
                fi
                if confirm "$ask"; then
                    card=$(agents_rotate "$id") && _agents_show_card "$card"
                else
                    log_info "$(t cancelled)"
                fi
                ;;
            2)
                if [ "$creq" = true ] || [ "$cmode" != static ]; then
                    log_error "$(t invalid_choice)"
                else
                    # «Выдать токен» — для доступов, выданных до второго фактора.
                    log_warning "$(t ag_harden_warn)"
                    if confirm "$(tf ag_harden_ask "$id")"; then
                        card=$(agents_harden "$id") && _agents_show_card "$card"
                    else
                        log_info "$(t cancelled)"
                    fi
                fi
                ;;
            3)
                choice=$(select_option "$(tf ag_pin_ask "$id")" "$(t ag_pin_item_on)" "$(t ag_pin_item_off)")
                case "$choice" in
                    1) agents_pin "$id" on >/dev/null ;;
                    2) agents_pin "$id" off >/dev/null ;;
                    0|"") log_info "$(t cancelled)" ;;
                    *) log_error "$(t ag_bad_state)" ;;
                esac
                ;;
            4) _agents_extend_interactive "$id" ;;
            5)
                list=$(agents_list 2>/dev/null) || list="[]"
                rec=$(jq -c --arg id "$id" '.[] | select(.id == $id)' <<<"$list")
                # Не «a && b || c»: при согласии и сорвавшемся действии этот
                # образец печатал «Отменено» — продукт говорил, что человек
                # передумал, хотя он согласился, а работа не прошла.
                if [ "$(_json_field "$rec" .enabled)" = true ]; then
                    if confirm "$(tf ag_toggle_off_ask "$id")"; then
                        agents_disable "$id" >/dev/null || log_error "${GA_ERR_MSG:-$(tf ag_toggle_failed "$id")}"
                    else
                        log_info "$(t cancelled)"
                    fi
                else
                    if confirm "$(tf ag_toggle_on_ask "$id")"; then
                        agents_enable "$id" >/dev/null || log_error "${GA_ERR_MSG:-$(tf ag_toggle_failed "$id")}"
                    else
                        log_info "$(t cancelled)"
                    fi
                fi
                ;;
            6)
                list=$(agents_list 2>/dev/null) || list="[]"
                label=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .label' <<<"$list")
                if confirm "$(tf ag_del_ask "$id" "$label")"; then
                    agents_del "$id" >/dev/null
                    # Паузу ставит вызывающий экран: своя здесь заставляла жать
                    # Enter дважды подряд на одно удаление.
                    return 0
                else
                    log_info "$(t cancelled)"
                fi
                ;;
            7)
                if [ -z "$curl" ]; then
                    log_error "$(t invalid_choice)"
                else
                    echo ""
                    echo -e "  ${DIM}$(t ag_qr_title)${NC}"
                    _qr_utf8 "$curl"
                fi
                ;;
            0|"") GA_BACK=1; return 0 ;;
            *) log_error "$(t invalid_choice)" ;;
        esac
        _pause
    done
}

# Колонка значений выравнивается по САМОЙ ДЛИННОЙ подписи текущего языка.
# Раньше отступы были набиты пробелами вручную под английский, и в русском
# («Ядро:», «Линейки:») колонка рвалась (замечание критика). Ссылка на
# внутренние docs/CONTRACT.md заменена руководством для человека: разработческие
# файлы на сервере всё равно не лежат.
_about_screen() {
    local w=0 k
    for k in about_version about_mode about_engine about_lines about_license about_docs; do
        [ "$(ga_str_width "$(t "$k")")" -gt "$w" ] && w=$(ga_str_width "$(t "$k")")
    done
    w=$((w + 2))
    _screen_head "$(t se_about)"
    echo -e "  $(_pad "$(t about_version)" "$w")${CYAN}v${GOAMNEZIA_VERSION}${NC}"
    echo -e "  $(_pad "$(t about_mode)" "$w")${CYAN}$(_mode_name "$(_mode_current)")${NC}"
    echo -e "  $(_pad "$(t about_engine)" "$w")AmneziaWG (amneziawg-go) + Docker"
    echo -e "  $(_pad "$(t about_lines)" "$w")3.1 / 2.0 / 1.5 / 1.0"
    echo -e "  $(_pad "$(t about_license)" "$w")MIT"
    echo -e "  $(_pad "$(t about_docs)" "$w")$(t about_docs_url)"
    echo -e "  ${DIM}$(_rule)${NC}"
}

# Админы бота живут в самом боте: он один знает Telegram ID, умеет проверить
# человека по /start и держит список в своей базе. Раньше пункт был заглушкой
# «появится в спринте 2» — теперь это честный указатель, куда идти.
# Владелец бота живёт ЗАПИСЬЮ OWNER_ID в .env, а не порядком списка админов
# (порядок прежние версии сортировали по номеру, и владельцем становился не тот
# человек). Но у установок, обновлённых с тех версий, записи нет вовсе: ни один
# установщик её не допишет, потому что оба видят готовый .env и обходят запись.
# Без владельца админами не управляет НИКТО, и назначить его можно только
# отсюда: за консолью сервера сидит тот, кто им владеет.
# .env бота читается везде одинаково (SEC50-03): как у самого бота (bot.py _read_env_values) и systemd —
# «export » в начале строки, пробелы вокруг имени, кавычки, « # комментарий» после значения; повтор
# переменной — побеждает ПОСЛЕДНЯЯ строка. Раньше SSH и панель брали первую, а бот и systemd — последнюю:
# при повторе ALLOWED_IDS SSH показывал не тех админов, с которыми работает бот. Без source: файл —
# данные, а не код. Печатает значение; нет файла или переменной — пусто и код 1.
_bot_env_get() {
    local want="$1" line key val q out="" rc=1
    [ -r "$BOT_DIR/.env" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in "export "*) line="${line#export }"; line="${line#"${line%%[![:space:]]*}"}" ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
        key="${line%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        [ "$key" = "$want" ] || continue
        val="${line#*=}"
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        q="${val:0:1}"
        if { [ "$q" = '"' ] || [ "$q" = "'" ]; } && [[ "${val:1}" == *"$q"* ]]; then
            val="${val:1}"
            val="${val%%"$q"*}"
        else
            [ "$q" = '"' ] || [ "$q" = "'" ] && val="${val:1}"
            val=$(printf '%s' "$val" | sed -E 's/[[:space:]]+#.*$//')
        fi
        out="$val" rc=0
    done < "$BOT_DIR/.env"
    printf '%s' "$out"
    return "$rc"
}
_bot_owner_id() { _bot_env_get OWNER_ID | tr -d '[:space:]'; }
_bot_admin_ids() { _bot_env_get ALLOWED_IDS | tr ',' ' '; }

_bot_owner_set() {
    local ids id n=0 pick chosen=""
    ids=$(_bot_admin_ids)
    [ -n "$ids" ] || { log_error "$(t se_owner_none)"; return 1; }
    echo ""
    echo -e "  ${BOLD}${WHITE}$(t se_owner_pick)${NC}"
    for id in $ids; do n=$((n + 1)); echo -e "  ${CYAN}$n${NC}) $id"; done
    echo -e "  ${CYAN}0${NC}) $(t back)"
    echo -ne "  ${WHITE}$(t choose):${NC} "
    read -r pick || pick=0
    [ "$pick" = 0 ] && { log_info "$(t cancelled)"; return 0; }
    n=0
    for id in $ids; do n=$((n + 1)); [ "$n" = "$pick" ] && chosen="$id"; done
    [ -n "$chosen" ] || { log_error "$(t invalid_choice)"; return 1; }
    local rc=0
    _bot_with_env_lock _bot_owner_write "$chosen" || rc=$?
    case "$rc" in
        0) ;;
        75) log_error "$(t se_owner_env_busy)"; return 1 ;;
        3) log_error "$(tf se_owner_gone "$chosen")"; return 1 ;;
        *) log_error "$(t se_owner_write_failed)"; return 1 ;;
    esac
    _svc_do restart goamnezia-bot.service || true
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "bot-owner-set" "$chosen"
    log_success "$(tf se_owner_done "$chosen")"
}

# Замок .env бота (SEC50-04): писателей у .env несколько — бот (/invite, удаление админа), установщик
# бота (создание, привязка сообщением) и это меню (владелец), — и каждый читает файл, меняет строку и кладёт
# весь файл обратно. Все берут flock на .env.lock рядом с .env (здесь и в install_bot.sh — flock(1), в
# python — fcntl.flock) и держат его на всё «прочитать — изменить — записать». Нет flock (стенд на macOS)
# — без замка, как ga_with_config_lock. Занят дольше 30 секунд — 75, файл не тронут.
_bot_with_env_lock() {
    local fd rc=0
    command -v flock >/dev/null 2>&1 || { "$@"; return $?; }
    { exec {fd}>>"$BOT_DIR/.env.lock"; } 2>/dev/null || { "$@"; return $?; }
    chmod 600 "$BOT_DIR/.env.lock" 2>/dev/null || true
    if ! flock -w 30 "$fd"; then
        { exec {fd}>&-; } 2>/dev/null
        return 75
    fi
    "$@" || rc=$?
    { exec {fd}>&-; } 2>/dev/null
    return "$rc"
}

# OWNER_ID в .env — под замком (_bot_with_env_lock): выбранный должен ещё быть в списке админов (его могли
# удалить из бота, пока человек выбирал), и файл пишется атомарно рядом с целью — .env держит и токен
# бота, полумеры тут означали бы бота без доступа вовсе. Прежние строки OWNER_ID уходят, новая — последней
# (побеждает последняя, SEC50-03). 0 — записан, 3 — выбранного уже нет в списке, 1 — не записать.
_bot_owner_write() {
    local chosen="$1" env="$BOT_DIR/.env" tmp
    [[ " $(_bot_admin_ids) " == *" $chosen "* ]] || return 3
    tmp=$(mktemp "${env}.XXXXXX") || return 1
    { grep -v '^OWNER_ID=' "$env" 2>/dev/null; printf 'OWNER_ID=%s\n' "$chosen"; } > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" && mv "$tmp" "$env" || { rm -f "$tmp"; return 1; }
}

_bot_admins_screen() {
    local own ids ch title="${1:-$(t se_admins)}"
    _screen_head "$title" "$(t se_admins_note)"
    echo -e "  ${WHITE}$(t se_admins_cmd)${NC}"
    # Состояние службы, а не наличие файла юнита. `systemctl cat` отвечает «да»
    # и про остановленного бота, и экран писал «работает» человеку, который
    # пришёл сюда именно потому, что бот молчит. Тот же _svc_state_line, что на
    # экранах «Telegram-бот» и «Панель»: три состояния вместо двух.
    echo -e "  $(t se_admins_state): $(_svc_state_line goamnezia-bot.service)"
    if [ "$(_svc_state goamnezia-bot.service)" = "not_installed" ]; then
        log_dim "$(t se_admins_install_hint)"
    fi
    # Привязывать некого, пока бот не поставлен: .env нет — и пунктов нет.
    [ -f "$BOT_DIR/.env" ] || return 0
    ids=$(_bot_admin_ids); own=$(_bot_owner_id)
    if [ -n "$ids" ]; then
        echo -e "  $(t se_admins_list): ${CYAN}$(printf '%s' "$ids" | tr ' ' ',')${NC}"
        if [ -n "$own" ]; then
            echo -e "  $(t se_owner_is): ${CYAN}${own}${NC}"
        else
            log_warning "$(t se_owner_missing)"
        fi
    else
        log_warning "$(t se_admins_none)"
    fi
    echo ""
    # «Привязать по сообщению» — и первого администратора, и ещё одного (docs/BOT.md «Контракт привязки»)
    echo -e "  ${CYAN}1${NC}) $(t se_admins_pair)"
    [ -n "$ids" ] && echo -e "  ${CYAN}2${NC}) $(t se_owner_item)"
    echo -e "  ${CYAN}0${NC}) $(t back)"
    echo -ne "  ${WHITE}$(t choose):${NC} "
    read -r ch || ch=0
    case "$ch" in
        1) _bot_pair_by_message ;;
        2) if [ -n "$ids" ]; then _bot_owner_set; else log_error "$(t invalid_choice)"; fi ;;
        ""|0) GA_BACK=1 ;;
        *) log_error "$(t invalid_choice)" ;;
    esac
}

# Полное удаление. Двойное подтверждение и бэкап в /root: каталог продукта
# сносится целиком, и после этого восстановить ключи будет неоткуда.
_wipe_everything() {
    local ts archive p unit
    echo ""
    log_warning "$(t se_wipe_warn1)"
    log_warning "$(t se_wipe_warn2)"
    confirm "$(t se_wipe_ask1)" || { log_info "$(t cancelled)"; return 1; }
    # Второе подтверждение — НАБОР слова, а не ещё одна «y»: удаление сносит
    # каталог продукта целиком, и восстановить ключи после него неоткуда.
    confirm_phrase "$(t se_wipe_phrase)" "$(t se_wipe_ask2)" || return 1
    # Сухой прогон дальше не идёт: снос трогает машину целиком — docker rm и rmi, правила iptables, юниты
    # systemd, /etc/sysctl.d, журналы, /usr/local/bin, — а на стенде это машина разработчика (находка L2-09).
    # Исключение — стенд с отдельным «домашним» каталогом для копий (GOAMNEZIA_WIPE_HOME): там проходят копии и
    # снятие контейнеров (через стендовые модули), а всё, что трогает машину, по-прежнему отрезано ниже (NC-25).
    if ga_dry && [ -z "${GOAMNEZIA_WIPE_HOME:-}" ]; then
        ga_dry_echo "wipe: containers, images, firewall rules, units, site, $GOAMNEZIA_DIR"
        return 0
    fi
    # Сносят обычно тогда, когда что-то сломано. При лежащем Docker контейнеры с --restart
    # always продолжили бы пускать людей по ключам, а state/ и users.json мы бы уже стёрли —
    # отключить их было бы нечем. Поэтому без ответа Docker не трогаем ничего (SR-32).
    if ! ga_dry && command -v docker >/dev/null 2>&1 && ! docker info >/dev/null 2>&1; then
        log_error "$(t se_wipe_docker_down)"
        return 1
    fi

    ts=$(date +%Y%m%d_%H%M%S)
    # Сначала — настоящая копия в формате бэкапа, рядом в /root: в ней и бот, и пароль панели, и
    # сертификаты, которых нет в архиве сноса (находка LC-19, 25.09.2026). Экран «Восстановить из
    # бэкапа» на новой установке находит её в /root сам.
    local restore_copy="" home first_copy="" marker
    home=$(type ga_backup_wipe_home >/dev/null 2>&1 && ga_backup_wipe_home || printf '/root')
    # Прошлая попытка сноса оборвалась на полпути: профили уже сняты, а данные на месте. Полная копия осталась от
    # НЕЁ — снятая сейчас уже без профилей, и называть её «копией для восстановления» значило бы потерять ключи
    # (находка NC-25). Отметку пишет сама попытка — перед первым разрушительным шагом.
    marker="$GOAMNEZIA_DIR/state/wipe_first_copy"
    if [ -f "$marker" ]; then
        first_copy=$(head -n 1 "$marker" 2>/dev/null)
        [ -n "$first_copy" ] && [ -f "$first_copy" ] || first_copy=""
    fi
    if type create_backup >/dev/null 2>&1 && create_backup >/dev/null 2>&1; then
        local last_bk
        last_bk=$(backup_last_json 2>/dev/null | jq -r '.name // ""' 2>/dev/null) || last_bk=""
        [ -n "$last_bk" ] && last_bk="$BACKUP_DIR/$last_bk"
        if [ -n "$last_bk" ] && [ -f "$last_bk" ] && cp -p "$last_bk" "$home/" 2>/dev/null; then
            restore_copy="$home/$(basename "$last_bk")"
            [ -f "${last_bk}.sha256" ] && cp -p "${last_bk}.sha256" "$home/" 2>/dev/null
            chmod 600 "$restore_copy" 2>/dev/null || true
        fi
    fi
    archive="$home/goamnezia-wipe-${ts}.tar.gz"
    # Журналы продукта (действия людей и агентов) едут в тот же архив: после сноса
    # правило их ротации снято, и оставлять их лежать без хозяина незачем (LC-02).
    local -a extra=()
    local lf
    for lf in /var/log/goamnezia*.log*; do [ -f "$lf" ] && extra+=("${lf#/}"); done
    if ( umask 077; tar czf "$archive" -C / \
            "${GOAMNEZIA_DIR#/}" "${extra[@]}" 2>/dev/null ) && [ -s "$archive" ]; then
        chmod 600 "$archive" 2>/dev/null || true
        log_success "$(tf se_wipe_backup "$archive")"
        # Копию снять не вышло (битый файл состояния, место) — вернуть всё можно из самого архива сноса:
        # восстановление его понимает (LC-19).
        [ -n "$restore_copy" ] || restore_copy="$archive"
    else
        rm -f "$archive" 2>/dev/null
        log_warning "$(t se_wipe_backup_failed)"
        confirm "$(t se_wipe_ask_nobackup)" || { log_info "$(t cancelled)"; return 1; }
    fi

    # Перед первым разрушительным шагом — где лежит полная копия: оборвётся снос — повтор назовёт её, а не свою.
    if [ -z "$first_copy" ] && [ -n "$restore_copy" ]; then
        # Целиком или никак (ga_write_file, OPS-04): обрезанная отметка назвала бы не тот файл
        ga_write_file "$marker" "$restore_copy" 600 || true
    fi

    local drop_icmp c i
    local -a containers=()
    drop_icmp=$(_cfg '.options.drop_icmp')
    local deps
    for p in $PROFILE_IDS; do
        _profile_installed "$p" || continue
        c=$(_cfg ".profiles.$p.container"); [ -n "$c" ] || c="amnezia-$p"
        containers+=("$c")
        # Соседи в сети контейнера (warp-socks рядом с goWARP) после сноса останутся без сети — называем их здесь:
        # предупреждение самого profile-remove ниже уходит в /dev/null вместе с остальным его выводом (WRP-01). До новой
        # установки: запись о них переживёт снос в хранилище вне каталога продукта (ниже, WRP-06).
        if type docker_netdeps_list >/dev/null 2>&1; then
            deps=$(docker_netdeps_list "$c" 2>/dev/null | paste -sd, - 2>/dev/null)
            [ -n "$deps" ] && log_warning "$(_ui_w "$(tf se_wipe_netdeps "$c" "$deps")")"
        fi
        type amnezia_profile_remove >/dev/null 2>&1 && amnezia_profile_remove "$p" >/dev/null 2>&1
    done
    # Модуль отказывает ДО docker rm, например на битом users.json. Контейнер, который он не
    # снял, снимаем по имени; не снялся и так — останавливаемся, пока данные на месте (SR-32).
    # Снят ли — по отсутствию КОНТЕЙНЕРА (docker_container_gone), а не по коду ответа и не голым `docker inspect`:
    # тот находил одноимённый образ профиля (docker build -t amnezia-awg3), и снос на каждом сервере обрывался
    # «контейнер не снялся» при пустом docker ps -a (находка NC-25). Служба goamnezia-isolation здесь ни при чём:
    # она слушает только старты и делает docker exec в работающем контейнере, контейнеров не создаёт и не
    # запускает. Исчезновение ждём до пяти секунд — демону под нагрузкой бывает нужна пауза.
    for c in "${containers[@]}"; do
        ga_dry || command -v docker >/dev/null 2>&1 || break
        docker_container_gone "$c" && continue
        docker_rm "$c" >/dev/null 2>&1 || true
        for i in 1 2 3 4 5 6 7 8 9 10; do
            docker_container_gone "$c" && break
            ga_dry && break
            sleep 0.5
        done
        if ! docker_container_gone "$c"; then
            log_error "$(tf se_wipe_container_left "$c" "$c")"
            return 1
        fi
    done
    # Реестр прежних ID контейнеров с соседями (state/.netdeps) — в хранилище вне каталога продукта: ниже снос сотрёт
    # state/, а соседи держат ссылку на ID только что снятых контейнеров. Новая установка узнает их по ней и вернёт в
    # сеть нового контейнера профиля сама (WRP-06: без этого warp-socks оставался в сети удалённого amnezia-awg2).
    if type docker_netdeps_stash >/dev/null 2>&1 && ! docker_netdeps_stash; then
        log_warning "$(_ui_w "$(tf se_wipe_netdeps_stash_failed "$(docker_netdeps_stash_dir)")")"
    fi
    # Стенд (GOAMNEZIA_WIPE_HOME): копии и контейнеры пройдены, остальное трогает машину — отрезано.
    if ga_dry; then
        ga_dry_echo "wipe: images, firewall rules, units, site, $GOAMNEZIA_DIR"
        log_success "$(t se_wipe_done)"
        _wipe_restore_hint "$first_copy" "$restore_copy"
        return 0
    fi
    # Модуль ядра AmneziaWG, если ставили мы (lib/kmod.sh, рецепт §11): контейнеров уже нет — выгрузка, dkms remove,
    # исходники, хуки, автозагрузка; пакеты сборки называются строкой apt remove. Модулем пользуется сосед Kaskad —
    # модуль остаётся, убираем только своё.
    type ga_kmod_remove >/dev/null 2>&1 && [ -f "$(ga_kmod_state_file 2>/dev/null)" ] && ga_kmod_remove wipe >/dev/null
    # Образы профилей собраны продуктом у себя — чужие образы Docker не трогаем.
    for p in $PROFILE_IDS; do
        docker image inspect "amnezia-${p}:latest" >/dev/null 2>&1 && docker rmi "amnezia-${p}:latest" >/dev/null 2>&1
    done
    # Сайт уходит целиком: vhost, веб-корни, deploy-хук, таймер продления; раздачи и
    # страницы подключения — до снятия их служб (LC-01, SR-01).
    type share_revoke_all >/dev/null 2>&1 && share_revoke_all >/dev/null 2>&1
    type website_wipe >/dev/null 2>&1 && website_wipe >/dev/null 2>&1
    type ga_edge_rules_remove >/dev/null 2>&1 && ga_edge_rules_remove >/dev/null 2>&1
    if [ "$drop_icmp" = "true" ]; then
        iptables -D INPUT -p icmp --icmp-type echo-request -j DROP >/dev/null 2>&1 || true
    fi
    for unit in goamnezia-bot.service goamnezia-admin.service goamnezia-mcp-http.service goamnezia-pages.service; do
        systemctl cat "$unit" >/dev/null 2>&1 || continue
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
        rm -f "${GOAMNEZIA_SYSTEMD_DIR:-/etc/systemd/system}/$unit" 2>/dev/null || true
    done
    type timers_remove >/dev/null 2>&1 && timers_remove >/dev/null 2>&1
    for unit in goamnezia-backup.timer goamnezia-backup.service goamnezia-logbudget.timer goamnezia-logbudget.service \
                goamnezia-logrotate.timer goamnezia-logrotate.service; do
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
        rm -f "${GOAMNEZIA_SYSTEMD_DIR:-/etc/systemd/system}/$unit" 2>/dev/null || true
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
    # Правила ротации: наши конфиги снимаем, а чужой (штатный nginx, который мы
    # унесли к себе в состояние) возвращаем на место — ОБЯЗАТЕЛЬНО до rm -rf
    # каталога продукта, иначе копия уедет вместе с ним и /var/log/nginx
    # останется без ротации навсегда.
    type logb_remove_logrotate >/dev/null 2>&1 && logb_remove_logrotate >/dev/null 2>&1
    # Системные настройки продукта возвращаются: потолок журнала всей системы и
    # ip_forward из sysctl.d (сам ip_forward не выключаем — им живёт Docker) (LC-02).
    if [ -f /etc/systemd/journald.conf.d/99-goamnezia.conf ]; then
        rm -f /etc/systemd/journald.conf.d/99-goamnezia.conf 2>/dev/null
        systemctl restart systemd-journald >/dev/null 2>&1 || true
    fi
    rm -f /etc/sysctl.d/99-goamnezia.conf 2>/dev/null || true
    rm -f /var/log/goamnezia*.log* 2>/dev/null || true
    rm -rf /run/goamnezia /run/goamnezia-logbudget.state 2>/dev/null || true
    rmdir /opt/amnezia/awg /opt/amnezia 2>/dev/null || true
    rm -rf "$GOAMNEZIA_DIR" "$BOT_DIR" "$ADMIN_DIR" "$MCP_DIR" 2>/dev/null || true
    rm -f /usr/local/bin/goamnezia /usr/local/bin/goamnezia-mcp 2>/dev/null || true
    log_success "$(t se_wipe_done)"
    _wipe_restore_hint "$first_copy" "$restore_copy"
    exit 0
}

# Где копия для восстановления. Снос с прошлой попытки, оборвавшейся на полпути, — первой называется ЕЁ полная
# копия, а снятая сейчас (уже без профилей) — отдельной строкой (NC-25).
_wipe_restore_hint() {
    local first="${1:-}" now="${2:-}"
    if [ -n "$first" ]; then
        log_info "$(tf se_wipe_restore_hint_first "$first")"
        [ -n "$now" ] && [ "$now" != "$first" ] && log_dim "$(tf se_wipe_restore_now "$now")"
    elif [ -n "$now" ]; then
        log_info "$(tf se_wipe_restore_hint "$now")"
    fi
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# Раздел 6: Telegram-бот (docs/BOT.md §4)
# ══════════════════════════════════════════════════════════════════════════════

# Короткая инструкция «где взять токен». Владелец на живой установке уткнулся в
# голый вопрос «Токен бота» — теперь рядом четыре строки, по которым бот
# заводится с нуля, и сама ссылка на BotFather (её можно кликнуть в терминале).
_bot_token_help() {
    echo "" >&2
    echo -e "  ${BOLD}${WHITE}$(t bot_token_help_title)${NC}" >&2
    echo -e "  ${DIM}1.${NC} $(tf bot_token_help_1 "https://t.me/BotFather")" >&2
    echo -e "  ${DIM}2.${NC} $(t bot_token_help_2)" >&2
    echo -e "  ${DIM}3.${NC} $(t bot_token_help_3)" >&2
    echo -e "  ${DIM}4.${NC} $(t bot_token_help_4)" >&2
}

# Экран «кто администратор бота». Первый администратор — не «первый написавший» (находка SEC-B00): имя бота
# видно всем. Enter — привязка сообщением (docs/BOT.md «Контракт привязки», решение владельца 27.09): бот
# встанет, откроется окно, человек пишет боту любое сообщение и подтверждает себя здесь, в SSH, — у
# постороннего SSH нет. Одноразовый код остался запасным путём только для установки без терминала
# (install_bot.sh --auto с GOAMNEZIA_ADMIN_CLAIM=1), здесь терминал есть. Ручной ввод ID — запасной путь.
# Печатает ТОЛЬКО строку ID (пустая строка = «привязать сообщением»). Возврат: 0 — решили, 1 — отмена.
_bot_admin_pick() {
    local ch ids
    local ids_re='^[0-9]+(,[0-9]+)*$'
    while true; do
        echo "" >&2
        echo -e "  ${BOLD}${WHITE}$(t bot_admin_title)${NC}" >&2
        echo -e "  ${CYAN}1${NC}) $(t bot_admin_auto)" >&2
        echo -e "  ${CYAN}2${NC}) $(t bot_admin_manual)" >&2
        echo -e "  ${CYAN}0${NC}) $(t cancel)" >&2
        echo -e "  ${DIM}$(t bot_admin_legend)${NC}" >&2
        echo -ne "  ${WHITE}$(t pick_prompt):${NC} " >&2
        read -r ch || ch=""
        case "$ch" in
            ""|1)
                log_info "$(_ui_w "$(t bot_admin_pair_note)")" >&2
                printf '%s' ""
                return 0
                ;;
            2)
                echo -e "  ${DIM}$(t bot_ids_hint)${NC}" >&2
                echo -ne "  ${WHITE}$(t bot_ids_ask):${NC} " >&2
                read -r ids || ids=""
                ids="${ids// /}"
                if [[ "$ids" =~ $ids_re ]]; then printf '%s' "$ids"; return 0; fi
                log_error "$(t bot_ids_bad)" >&2
                ;;
            0) return 1 ;;
            *) log_error "$(t invalid_choice)" >&2 ;;
        esac
    done
}

# Есть ли у бота администратор: ALLOWED_IDS в .env не пуст.
_bot_has_admins() {
    [ -n "$(_bot_admin_ids | tr -d '[:space:],')" ]
}

# «Telegram-бот → Администраторы → Привязать по сообщению» и мастер после установки бота: окно привязки
# открывает сам установщик бота (install_bot.sh --pair) — одна реализация на SSH-меню, мастер и ручной
# запуск установщика: окно (.admin_pairing_until) → «Напишите боту @имя» → живой список написавших →
# номер себя → «Это вы? 1 — да · 0 — отмена» → .env, потом .admin_confirmed → ответ бота; «0» и Ctrl-C — отмена с
# закрытием окна. Отдельным процессом: его Ctrl-C закрывает окно и возвращает сюда, а не рвёт меню.
_bot_pair_by_message() {
    local inst="$SCRIPT_DIR/goamnezia-bot/install_bot.sh" rc=0
    if [ ! -f "$BOT_DIR/.env" ]; then
        log_warning "$(t bot_not_installed_hint)"
        return 1
    fi
    if [ ! -f "$inst" ]; then
        log_error "$(tf bot_installer_missing "$inst")"
        return 1
    fi
    GOAMNEZIA_BOT_DIR="$BOT_DIR" GOAMNEZIA_DIR="$GOAMNEZIA_DIR" bash "$inst" --pair --lang="${LANG_CODE:-ru}" || rc=$?
    # Привязали ещё одного администратора, а владельца нет: привязка его не назначает (SEC50-02) — сразу
    # к выбору владельца, пока человек у терминала («0» — позже, пункт «Назначить владельца»).
    if [ "$rc" = 0 ] && _bot_has_admins && _bot_owner_missing; then
        _bot_owner_set || true
    fi
    return "$rc"
}

# Владелец не назначен: OWNER_ID пуст или не из ALLOWED_IDS — бот тогда админами не даёт управлять никому.
_bot_owner_missing() {
    local own
    own=$(_bot_owner_id)
    [ -z "$own" ] || [[ " $(_bot_admin_ids) " != *" $own "* ]]
}

# Установка/обновление бота его собственным установщиком из эталонного каталога
# (goamnezia-bot/install_bot.sh --auto). Токен и ID спрашиваем здесь, только
# если .env ещё нет: на установленном боте повторный вызов безопасен — .env и
# venv сохраняются, файлы и юнит обновляются, служба перезапускается.
# Токен читается без эха и уходит установщику через окружение, а не через
# аргументы: argv виден любому локальному пользователю в /proc/*/cmdline.
# Аргумент pair — Ленивый Pro: «токен скрытым вводом → привязка сообщением» без экрана выбора администратора.
_bot_install_interactive() {
    local inst="$SCRIPT_DIR/goamnezia-bot/install_bot.sh" env_file="$BOT_DIR/.env"
    local token="" ids="" rc=0 pair=0 how="${1:-}"
    local token_re='^[0-9]{6,12}:[A-Za-z0-9_-]{30,50}$'
    if [ ! -f "$inst" ]; then
        log_error "$(tf bot_installer_missing "$inst")"
        return 1
    fi
    if [ -f "$env_file" ]; then
        log_info "$(tf bot_env_reuse "$env_file")"
    else
        _bot_token_help
        # Выход из вопроса обязан быть всегда — три причины, и каждая уже
        # стоила продукту зависания:
        #   • «0» — явная отмена: человек передумал ставить бота прямо сейчас,
        #     и единственным выходом не должен быть Ctrl+C посреди мастера;
        #   • конец ввода (rc ≠ 0) — оборванная SSH-сессия или запуск без
        #     терминала: read отдаёт EOF мгновенно, и `while true` крутился бы
        #     вхолостую на 100 % CPU. Тот же разбор стоит в главном меню, там
        #     он описан у read -t 30;
        #   • счётчик попыток — токен набирают вслепую (read -rs), и после
        #     трёх промахов честнее выйти и предложить пункт меню, чем
        #     спрашивать одно и то же до бесконечности.
        local try=0
        token=""
        # Ввод скрыт (read -s), и после вставки на экране не меняется ничего — новичок решал, что вставка не
        # сработала, и вставлял снова (находка NC-24 критика-новичка). Говорим заранее, что так задумано.
        echo -e "  ${DIM}$(ga_win_wrap "$(t bot_token_hidden_note)" 2)${NC}" >&2
        while [ "$try" -lt 3 ]; do
            try=$((try + 1))
            echo -ne "  ${WHITE}$(t bot_token_ask):${NC} " >&2
            if ! IFS= read -rs token; then
                echo "" >&2
                token=""
                log_info "$(t cancelled)"
                return 1
            fi
            echo "" >&2
            [ "$token" = "0" ] && { token=""; log_info "$(t cancelled)"; return 1; }
            [[ "$token" =~ $token_re ]] && break
            token=""
            log_error "$(t bot_token_bad)"
        done
        if [ -z "$token" ]; then
            log_error "$(t bot_token_giveup)"
            return 1
        fi
        log_success "$(t bot_token_ok)"
        if [ "$how" = pair ]; then
            ids=""
            log_info "$(_ui_w "$(t bot_admin_pair_note)")"
        else
            ids=$(_bot_admin_pick) || { token=""; log_info "$(t cancelled)"; return 1; }
        fi
        # Пусто — администратора привяжут сообщением сразу после установки (_bot_pair_by_message)
        [ -n "$ids" ] || pair=1
    fi
    log_info "$(t bot_installing)"
    # GOAMNEZIA_ADMIN_PAIR=1 — установщик не заводит одноразового кода: терминал здесь, и администратора
    # привязывают сообщением (код — запасной путь только для установки без терминала).
    if [ -n "$token" ]; then
        # OWNER_ID — владелец сервера, записью, а не догадкой по порядку списка.
        # Первый из введённых и есть тот, кто ставит сервер.
        BOT_TOKEN="$token" ALLOWED_IDS="$ids" OWNER_ID="${ids%%,*}" GOAMNEZIA_ADMIN_PAIR=1 \
            GOAMNEZIA_LANG="${LANG_CODE:-ru}" GOAMNEZIA_BOT_DIR="$BOT_DIR" GOAMNEZIA_DIR="$GOAMNEZIA_DIR" \
            bash "$inst" --auto || rc=$?
    else
        GOAMNEZIA_ADMIN_PAIR=1 GOAMNEZIA_LANG="${LANG_CODE:-ru}" GOAMNEZIA_BOT_DIR="$BOT_DIR" \
            GOAMNEZIA_DIR="$GOAMNEZIA_DIR" bash "$inst" --auto || rc=$?
    fi
    token=""
    if [ "$rc" != 0 ]; then
        log_error "$(t bot_install_failed)"
        return 1
    fi
    # Администратора в .env нет (выбрали «напишу боту» или прежний .env без админов) — окно привязки
    # сразу, пока человек у терминала; «0 — позже» вернёт сюда, а где открыть окно потом, скажет само окно.
    if [ "$pair" = 1 ] || { [ -f "$BOT_DIR/.env" ] && ! _bot_has_admins; }; then
        log_success "$(t bot_installed_pair)"
        _bot_pair_by_message || true
        return 0
    fi
    log_success "$(t bot_installed)"
    return 0
}

# .env бота без строки BOT_TOKEN: остальное (ID админов, язык, путь к мосту) —
# не секрет и нужно, чтобы понять, кто имеет доступ к боту.
_bot_env_screen() {
    local env_file="$BOT_DIR/.env"
    if [ ! -f "$env_file" ]; then
        log_error "$(tf bot_env_missing "$env_file")"
        return 1
    fi
    echo ""
    echo -e "  ${BOLD}${WHITE}$(tf bot_env_title "$env_file")${NC}"
    echo -e "  ${DIM}$(_rule)${NC}"
    # Строку токена прячем по разобранному имени, как его читает бот: «export BOT_TOKEN=…» и отступ перед
    # именем голый grep по началу строки пропускал — и токен печатался на экране (SEC50-03).
    local line key
    while IFS= read -r line || [ -n "$line" ]; do
        key="${line#"${line%%[![:space:]]*}"}"
        case "$key" in "export "*) key="${key#export }"; key="${key#"${key%%[![:space:]]*}"}" ;; esac
        key="${key%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        [ "$key" = "BOT_TOKEN" ] && continue
        printf '  %s\n' "$line"
    done < "$env_file"
    echo -e "  ${DIM}BOT_TOKEN=$(t bot_env_token_hidden)${NC}"
    echo -e "  ${DIM}$(_rule)${NC}"
}

_bot_remove() {
    log_warning "$(t bot_remove_warn)"
    confirm "$(t bot_remove_ask)" || { log_info "$(t cancelled)"; return 1; }
    _component_remove goamnezia-bot.service "$BOT_DIR"
    log_success "$(t bot_removed)"
}

submenu_bot() {
    local ch unit="goamnezia-bot.service"
    while true; do
        echo ""
        echo -e "  ${BOLD}${WHITE}$(t bot_title)${NC}"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -e "  $(t bot_state): $(_svc_state_line "$unit")"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -e "  ${CYAN}1${NC}) $(t bot_install)"
        echo -e "  ${CYAN}2${NC}) $(t bot_status)"
        echo -e "  ${CYAN}3${NC}) $(t bot_logs)"
        echo -e "  ${CYAN}4${NC}) $(t bot_restart)"
        echo -e "  ${CYAN}5${NC}) $(t bot_env)"
        echo -e "  ${CYAN}6${NC}) $(t bot_admins)"
        echo -e "  ${CYAN}7${NC}) ${RED}$(t bot_remove)${NC}"
        echo -e "  ${CYAN}0${NC}) $(t back)"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0
        case "$ch" in
            1) _bot_install_interactive ;;
            2)
                if [ "$(_svc_state "$unit")" = "not_installed" ]; then
                    log_warning "$(t bot_not_installed_hint)"
                else
                    _svc_card "$unit"
                fi
                ;;
            3)
                echo ""
                echo -e "  ${BOLD}${WHITE}$(t bot_logs_title)${NC}"
                _logs_print bot 60
                ;;
            4)
                if [ "$(_svc_state "$unit")" = "not_installed" ]; then
                    log_warning "$(t bot_not_installed_hint)"
                elif _svc_do restart "$unit"; then
                    log_success "$(t bot_restarted)"
                else
                    log_error "$(t bot_restart_failed)"
                fi
                ;;
            5) _bot_env_screen ;;
            6)
                if [ "$(_svc_state "$unit")" = "not_installed" ] && [ ! -f "$BOT_DIR/.env" ]; then
                    log_warning "$(t bot_not_installed_hint)"
                else
                    _bot_admins_screen "$(t bot_admins)"
                fi
                ;;
            7) _bot_remove ;;
            0) GA_BACK=1; return 0 ;;
            "") continue ;;
            *) log_error "$(t invalid_choice)" ;;
        esac
        _pause
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# Мастер первой установки (CONTRACT §4.7)
# ══════════════════════════════════════════════════════════════════════════════

# Галочка для экрана выбора профилей.
_checkbox() {
    if [ "${1:-0}" = "1" ]; then printf 'x'; else printf ' '; fi
}

# ── Экран с галочками (общий) ────────────────────────────────────────────────
# Владелец: «не нравится, что нужно выбирать галочками цифрами, хотя нет
# подсказки, как это делать; нет легенды; нужно догадаться. И не нравится, что
# продолжить нулём, а не Enter». Поэтому один экран на все такие вопросы:
# легенда прямо над строкой ввода, ENTER продолжает с тем, что отмечено, ноль —
# отмена (а не «готово»), у каждого пункта строка «кому это нужно».
#
#   _pick_checkboxes <заголовок> <массив-подписей> <массив-пояснений> \
#                    <массив-состояний 0/1> <массив-замков 0/1> <текст замка> [легенда]
# Легенда по умолчанию говорит «0 — отмена»; мастер передаёт свою, «0 — назад».
#
# Массивы передаются ИМЕНАМИ (nameref): состояния меняются на месте, вызывающему
# не надо разбирать строку с результатом. Возврат: 0 — продолжить, 1 — отмена.
# EOF (терминал закрылся, `curl … | bash` без терминала) — отмена с отметкой
# GA_INPUT_EOF, а не «продолжить с умолчаниями»: так мастер, оставшийся без
# человека, сам поставил профили по умолчанию (INST-02). Вхолостую цикл не
# крутится и теперь: выход сразу.
_pick_checkboxes() {
    local _cb_title="$1" _cb_lockmsg="${6:-}" _cb_legend="${7:-}" _cb_lm_name="${8:-}"
    # shellcheck disable=SC2178  # nameref на массив, не строка
    local -n _cb_labels="$2" _cb_notes="$3" _cb_state="$4" _cb_locked="$5"
    # Восьмой аргумент (необязательный) — имя массива своих объяснений на каждую замкнутую галочку: замкнута
    # бывает не только 2.0 («ставится всегда»), но и подхваченный профиль или занятый приложением (OWN-1).
    local -a _cb_lm=()
    if [ -n "$_cb_lm_name" ]; then
        local -n _cb_lm_ref="$_cb_lm_name"
        _cb_lm=("${_cb_lm_ref[@]}")
    fi
    local ch i
    while true; do
        echo ""
        echo -e "  ${BOLD}${WHITE}${_cb_title}${NC}"
        for i in "${!_cb_labels[@]}"; do
            echo -e "  ${DIM}[$(_checkbox "${_cb_state[$i]}")]${NC} ${CYAN}$((i + 1))${NC}) ${_cb_labels[$i]}"
            # Перенос с висячим отступом: отступ здесь девять колонок, значит
            # на текст остаётся GA_UI_W минус семь. Без этого пояснения про
            # линейки вылезали за край на окне уже вокруг 80 колонок. Отступ
            # продолжения — те же девять: с нулём хвост пояснения («маскировка»,
            # «приложение») падал на край окна под галочки.
            [ -n "${_cb_notes[$i]}" ] && echo -e "         ${DIM}$(ga_wrap "${_cb_notes[$i]}" "$(( ${GA_UI_W:-76} - 7 ))" 9)${NC}"
        done
        echo -e "  ${DIM}$(ga_win_wrap "${_cb_legend:-$(t pick_legend)}" 2)${NC}"
        echo -ne "  ${WHITE}$(t pick_prompt):${NC} "
        if ! read -r ch; then echo ""; GA_INPUT_EOF=1; return 1; fi
        case "$ch" in
            "") return 0 ;;
            0)  return 1 ;;
            [1-9]|[1-9][0-9])
                i=$((10#$ch - 1))
                if [ "$i" -ge "${#_cb_labels[@]}" ]; then
                    log_error "$(t invalid_choice)"
                elif [ "${_cb_locked[$i]}" = "1" ]; then
                    if [ -n "${_cb_lm[$i]:-}" ]; then
                        log_info "${_cb_lm[$i]}"
                    elif [ -n "$_cb_lockmsg" ]; then
                        log_info "$_cb_lockmsg"
                    fi
                elif [ "${_cb_state[$i]}" = "1" ]; then
                    _cb_state[$i]=0
                else
                    _cb_state[$i]=1
                fi
                ;;
            *) log_error "$(t invalid_choice)" ;;
        esac
    done
}

# Порты закрыты только локальным файрволом → «Открыть 80,443/tcp в ufw?» прямо в
# мастере или на экране «Режим и сайт» (PLAN §4.3.1). Согласие спрашиваем здесь,
# модуль только делает. Возвращает 0, если хоть один порт открыли (стоит
# повторить проверку); 1 — закрытых локально портов нет или человек отказался.
_wizard_offer_open_ports() {
    local pf="$1" ports p opened=0
    type preflight_open_local >/dev/null 2>&1 || return 1
    ports=$(printf '%s' "$pf" | jq -r '.pro.reasons[]? | select(.state == "closed_local") | .port' 2>/dev/null | sort -un | paste -sd, -)
    [ -n "$ports" ] || return 1
    confirm "$(tf preflight_ask_open "${ports}/tcp" "$(printf '%s' "$pf" | jq -r '.hints.open_cmd // ""' 2>/dev/null)")" || return 1
    for p in ${ports//,/ }; do
        preflight_open_local "$p" tcp && opened=1
    done
    [ "$opened" = 1 ]
}

# ── Мастер: порты всех выбранных профилей ────────────────────────────────────
# Раньше мастер спрашивал порт только у awg2, а awg3 и awg1 молча получали
# случайные уже при установке. Отсюда три беды: своего порта им было не задать;
# случайный порт awg3 выбирался ДО установки awg2 без оглядки на уже выбранный,
# и при совпадении мастер обрывался на полпути («порт уже занят профилем awg3»);
# «0 — назад» на вопросе порта назад не вёл — мастер печатал «Отменено» и ставил
# awg2 на другой случайный порт.
#
# Теперь один экран-сводка: у каждого выбранного профиля свой порт, все разные.
# Enter — принять предложенные (нажатий столько же, сколько было), 1 — задать
# свои по очереди, 0 — назад к выбору профилей. UDP/443 держит не больше одного
# профиля: в режиме «Сайт и VPN на 443» ровно один (по умолчанию awg2 — его видит
# официальное приложение), в режиме «VPN и сайт» ни одного — VPN там стоит на
# своём порту, иначе это и был бы третий режим. В «Только VPN» 443 — обычный порт.
#
# Результат — в глобальных _WZ_PORT[профиль] и _WZ_MODE: третий режим без
# профиля на 443 ничем не отличается от второго, поэтому с вопросом мастер
# ставит второй. Возврат: 0 — порты приняты, 1 — назад или конец ввода (тогда
# отметка GA_INPUT_EOF, и мастер останавливается, ничего не ставя, INST-02;
# раньше конец ввода значил «принять предложенные»).
declare -A _WZ_PORT=()
_WZ_MODE=""
_WZ_NOTE443=""
_WZ_LAST_MODE=""
_WZ_EDITED=0
# Мастер Pro: какая линия встанет на UDP 443 (LZ-11) — awg2 (2.0, по умолчанию) или awg3 (3.1)
_WZ_LINE443=awg2
_WZ_LAST_LINE=awg2

# _wz_line_applicable — выбирать есть из чего: обе линии мастер ставит сам (ни одна не стоит — подхвачена или
# поставлена прошлым заходом — и место 3.1 не занято контейнером приложения с людьми). Иначе на 443 — 2.0, как было.
_wz_line_applicable() {
    ! _profile_installed awg2 && ! _profile_installed awg3 && [[ " $_WZ_TK_LOCKED " != *" awg3 "* ]]
}

# _wz_line_pick → _WZ_LINE443. Тот же выбор, что «Режим и сайт → Линия на UDP 443» (_pro_line_pick), для мастера:
# профилей ещё нет, 2.0 — первой и рекомендуем (решение владельца 27.09: её понимает больше всего клиентов, включая
# роутеры), Enter — 2.0. rc 0 — выбрано; 1 — «0», шаг назад, или конец ввода (тогда отметка GA_INPUT_EOF, и мастер
# останавливается: на сервере 168 конец ввода на этом вопросе шёл как Enter, и мастер сам поставил профили, INST-02).
_wz_line_pick() {
    local ch
    echo ""
    echo -e "  ${BOLD}${WHITE}$(t pl_title)${NC}"
    echo -e "  $(ga_win_wrap "$(t wz_line_explain)" 2)"
    echo -e "  ${CYAN}1${NC}) $(t pr_awg2) — $(t pl_recommended)"
    echo -e "  ${CYAN}2${NC}) $(t pr_awg3)"
    echo -e "  ${CYAN}0${NC}) $(t back)"
    echo -e "  ${DIM}$(ga_win_wrap "$(t wz_line_why)" 2)${NC}"
    while true; do
        echo -ne "  ${WHITE}$(t wz_line_prompt):${NC} "
        if ! read -r ch; then echo ""; GA_INPUT_EOF=1; return 1; fi
        case "$ch" in
            ""|1) _WZ_LINE443=awg2; return 0 ;;
            2)    _WZ_LINE443=awg3; return 0 ;;
            0)    return 1 ;;
            *)    log_error "$(t invalid_choice)" ;;
        esac
    done
}

# _wz_port_taken <порт> — порт уже отдан какому-то профилю в сводке
_wz_port_taken() {
    local q
    for q in "${_WZ_PORT[@]}"; do [ "$q" = "$1" ] && return 0; done
    return 1
}

# _wz_ports_default <режим> <профиль…> — предложить порты. Профилю, который уже
# стоит (повтор мастера после сорвавшейся установки), — его нынешний порт; в
# третьем режиме awg2 — 443, если UDP/443 свободен; остальным — случайные
# свободные, все разные.
_wz_ports_default() {
    local mode="$1" p k q h="${_WZ_LINE443:-awg2}"
    local -a taken=()
    local -A prev=()
    shift
    # Вернулся от сводки к галочкам и обратно — порты оставшихся профилей те же,
    # в том числе заданные вручную: иначе каждый шаг назад перетасовывал бы их.
    # Но только в том же режиме: порты «Только VPN» в третьем режиме оставили бы
    # awg2 без 443, а 443 из третьего в «Только VPN» — лишним (замечание критика).
    # И только при той же линии на UDP 443 (LZ-11): вернулись к её выбору и сменили — 443 переходит к новой.
    if [ "$mode" = "$_WZ_LAST_MODE" ] && [ "$h" = "$_WZ_LAST_LINE" ]; then
        for k in "${!_WZ_PORT[@]}"; do prev[$k]="${_WZ_PORT[$k]}"; done
    else
        _WZ_EDITED=0
    fi
    _WZ_LAST_MODE="$mode"
    _WZ_LAST_LINE="$h"
    _WZ_PORT=()
    _WZ_MODE="$mode"
    _WZ_NOTE443=""
    for p in "$@"; do
        _profile_installed "$p" || continue
        _WZ_PORT[$p]=$(_cfg ".profiles.$p.port")
        taken+=("${_WZ_PORT[$p]}")
    done
    # Третий режим: 443 отдаём линии, выбранной шагом «Линия на UDP 443» (по умолчанию 2.0 — awg2), раньше, чем
    # возвращаем прежние порты, — если 443 не держит другой оставшийся профиль (сняли галочку с профиля, которому его
    # отдали, — 443 возвращается ей). Выбранной нет в списке — 2.0, как было.
    [[ " $* " == *" $h "* ]] || h=awg2
    if [ "$mode" = pro ] && [ -z "${_WZ_PORT[$h]:-}" ] && ! _wz_port_taken 443; then
        q=""
        for p in "$@"; do [ "${prev[$p]:-}" = 443 ] && q="$p"; done
        if [ -z "$q" ]; then
            if _port_free 443 udp; then
                _WZ_PORT[$h]=443
                taken+=(443)
            else
                _WZ_NOTE443=busy
            fi
        fi
    fi
    for p in "$@"; do
        [ -n "${_WZ_PORT[$p]:-}" ] && continue
        q="${prev[$p]:-}"
        if [ -n "$q" ] && ! _wz_port_taken "$q" && { [ "$mode" != lite_site ] || [ "$q" != 443 ]; }; then
            _WZ_PORT[$p]="$q"
            taken+=("$q")
            continue
        fi
        _WZ_PORT[$p]=$(_random_port "${taken[@]}")
        taken+=("${_WZ_PORT[$p]}")
    done
}

# _wz_port_line <профиль> — строка сводки: имя линейки, порт, пометка
_wz_port_line() {
    local p="$1" lbl note=""
    # Порт — своей колонкой: стоящий профиль — подписью без порта, ставящийся — линией, которая встанет (DUP-LINE-01)
    printf -v lbl '%-26s' "$(_wz_pr "${p}")"
    if _profile_installed "$p" && [ "$(_cfg ".profiles.$p.imported")" = true ]; then
        # Подхваченный из приложения: на этом порту живые люди со своими ключами (OWN-1).
        note="  ${DIM}$(t wz_port_imported)${NC}"
    elif _profile_installed "$p"; then
        note="  ${DIM}$(t wz_port_installed)${NC}"
    elif [ "${_WZ_PORT[$p]}" = 443 ] && [ "$_WZ_MODE" = pro ]; then
        note="  ${DIM}$(t wz_port_443_note)${NC}"
    fi
    echo -e "    ${lbl} ${CYAN}${_WZ_PORT[$p]}${NC}${note}"
}

# _wz_port_check <профиль> <порт> — годится ли набранный порт. Печатает причину
# отказа (вызов через $()), код 0 — годится. Повторы между профилями проверяет
# вызывающий: он знает, кому порт уже отдан.
_wz_port_check() {
    local p="$1" port="$2"
    if ! validate_port "$port"; then t pr_bad_port; return 1; fi
    # rc 3 — порт годен только в третьем режиме: вызывающий предложит переключиться
    if [ "$_WZ_MODE" = lite_site ] && [ "$port" = 443 ]; then
        t wz_port_443_site
        return 3
    fi
    # Модуль знает и сокеты, и порты профилей из config.json (свой не в счёт)
    if type ga_amn_port_check >/dev/null 2>&1; then
        GA_ERR_CODE=""; GA_ERR_MSG=""
        if ! ga_amn_port_check "$p" "$port" 2>/dev/null; then
            printf '%s' "${GA_ERR_MSG:-$(tf pr_port_busy "$port")}"
            return 1
        fi
    elif ! _port_free "$port" udp; then
        tf pr_port_busy "$port"
        return 1
    fi
    return 0
}

# _wz_ports_edit <профиль…> — задать порты по очереди. Enter — предложенный,
# 0 — шаг назад (с первого профиля — к сводке без изменений). Выбор попадает в
# _WZ_PORT только в конце прохода: вернувшийся к сводке нулём ничего не теряет.
_wz_ports_edit() {
    local -a profs=("$@") chosen=()
    local i=0 j n=${#profs[@]} p sug port msg owner rc
    while [ "$i" -lt "$n" ]; do
        p="${profs[$i]}"
        # Уже стоящий профиль мастер не двигает — его порт меняют в «Протоколах»
        if _profile_installed "$p"; then
            chosen[i]="${_WZ_PORT[$p]}"
            i=$((i + 1))
            continue
        fi
        # Предложение — прежний выбор, если его не забрал профиль выше
        sug="${chosen[i]:-${_WZ_PORT[$p]}}"
        for ((j = 0; j < i; j++)); do
            [ "${chosen[j]}" = "$sug" ] && sug=""
        done
        { [ "$_WZ_MODE" = lite_site ] && [ "$sug" = 443 ]; } && sug=""
        [ -n "$sug" ] || sug=$(_random_port "${chosen[@]:0:i}")
        echo -ne "  $(ga_win_wrap "${WHITE}$(tf pr_ask_port "$(_wz_pr "${p}")" "$sug"):${NC}" 2) "
        # Конец ввода — не «назад» и не «предложенный»: отметка, и мастер останавливается (INST-02)
        if ! read -r port; then echo ""; GA_INPUT_EOF=1; return 1; fi
        if [ "$port" = 0 ]; then
            # Назад — к предыдущему профилю, который мастер ставит сам
            while [ "$i" -gt 0 ]; do
                i=$((i - 1))
                _profile_installed "${profs[$i]}" || continue 2
            done
            return 1
        fi
        [ -n "$port" ] || port="$sug"
        # «0443» проходит проверку числа, но как строка не равен «443»: повторы и
        # запрет 443 такой ввод обходил, а Docker потом отказывал. Приводим к числу.
        validate_port "$port" && port=$((10#$port))
        owner=""
        for ((j = 0; j < i; j++)); do
            [ "${chosen[j]}" = "$port" ] && owner="${profs[$j]}"
        done
        if [ -n "$owner" ]; then
            log_error "$(tf wz_port_taken "$port" "$(_wz_pr "${owner}")")"
            continue
        fi
        msg=$(_wz_port_check "$p" "$port"); rc=$?
        if [ "$rc" = 3 ]; then
            # 443 во втором режиме — это и есть третий: предлагаем переключиться,
            # а не просто отказываем (замечание критика-пользователя)
            log_info "$msg"
            confirm "$(t wz_port_443_switch_ask)" || { [ "$GA_INPUT_EOF" = 1 ] && return 1; continue; }
            _WZ_MODE=pro
            msg=$(_wz_port_check "$p" "$port"); rc=$?
        fi
        if [ "$rc" != 0 ]; then
            log_error "$msg"
            continue
        fi
        chosen[i]="$port"
        i=$((i + 1))
    done
    for ((i = 0; i < n; i++)); do _WZ_PORT[${profs[$i]}]="${chosen[i]}"; done
    _WZ_EDITED=1
    return 0
}

# _wz_ports_step <режим> <профиль…> — экран-сводка портов (см. выше)
_wz_ports_step() {
    local mode="$1" ch p
    shift
    local -a profs=("$@")
    _wz_ports_default "$mode" "${profs[@]}"
    while true; do
        echo ""
        echo -e "  ${WHITE}$(t wz_ports_title)${NC}"
        for p in "${profs[@]}"; do _wz_port_line "$p"; done
        if [ "$_WZ_NOTE443" = busy ]; then
            log_warning "$(ga_wrap "$(t wz_port_443_busy)" "${GA_UI_W:-76}" 2)"
            _WZ_NOTE443=""
        fi
        if [ "$_WZ_EDITED" = 1 ]; then
            echo -e "  ${DIM}$(ga_wrap "$(t wz_ports_note_edited)" "${GA_UI_W:-76}" 2)${NC}"
        else
            echo -e "  ${DIM}$(ga_wrap "$(t wz_ports_note)" "${GA_UI_W:-76}" 2)${NC}"
        fi
        echo -ne "  $(ga_win_wrap "${WHITE}$(t wz_ports_ask):${NC}" 2) "
        # Конец ввода — не Enter: без человека порты не принимаются и режим сам не меняется (INST-02)
        if ! read -r ch; then echo ""; GA_INPUT_EOF=1; return 1; fi
        case "$ch" in
            "")
                # Во втором режиме профиль на 443 бывает только уже стоящий (повтор
                # мастера): второй режим с VPN на 443 — это третий, предлагаем его.
                if [ "$_WZ_MODE" = lite_site ] && _wz_port_taken 443; then
                    log_info "$(t wz_port_443_site)"
                    if confirm "$(t wz_port_443_switch_ask)"; then
                        _WZ_MODE=pro
                        log_info "$(tf wz_port_mode_changed "$(_mode_name pro)")"
                    fi
                    [ "$GA_INPUT_EOF" = 1 ] && return 1
                    return 0
                fi
                if [ "$_WZ_MODE" = pro ] && ! _wz_port_taken 443; then
                    # Третий режим — это и есть VPN на UDP/443. Без него ярлык
                    # врал бы: снаружи сервер выглядел бы как второй режим.
                    if confirm "$(t wz_port_no443_ask)"; then
                        _WZ_MODE=lite_site
                        log_info "$(tf wz_port_mode_changed "$(_mode_name lite_site)")"
                        return 0
                    fi
                    [ "$GA_INPUT_EOF" = 1 ] && return 1
                    continue
                fi
                return 0
                ;;
            1) _wz_ports_edit "${profs[@]}" || true
               [ "$GA_INPUT_EOF" = 1 ] && return 1 ;;
            0) return 1 ;;
            *) log_error "$(t invalid_choice)" ;;
        esac
    done
}

# ── Мастер: контейнеры Amnezia, которые уже стоят на сервере (OWN-1) ─────────
# Живая жалоба владельца 25.09.2026: он ставил goAmnezia на сервер, где уже работали контейнеры приложения
# Amnezia, — установщик их «не увидел», подхват не предложил, и владелец от установки отказался. Поиск шёл на
# шаге 6а — ПОСЛЕ вопросов о режиме, домене, профилях, портах и записи ответов в конфиг: до него человек видел
# обычный мастер без слова о своих людях. Остановленных контейнеров поиск не видел вовсе (docker ps без -a), а
# контейнеры без людей молча пропускал. Теперь это первый экран мастера — до выбора режима: все контейнеры
# amnezia-* (и остановленные, и без людей, и других протоколов приложения — их не подхватываем, но называем),
# и подхват предлагается первым. Дальше мастер идёт уже с подхваченными профилями: не ставит их заново и не
# спрашивает их порты, а профили, чьё место занимает контейнер с людьми, от которого отказались, не предлагает.
#
# _WZ_TK_LOCKED — такие профили (через пробел); мастер снимает и замыкает их галочки.
_WZ_TK_LOCKED=""
# _WZ_TK_LINE[место] — линия контейнера приложения, который занимает это место (по скану): подписать строку мастера
# по версии, а не по месту (DUP-LINE-01).
declare -gA _WZ_TK_LINE=()

# _wz_takeover_gate → 0 — мастер идёт дальше; 1 — остановиться: ничего не установлено и не изменено; 3 — ввод
# кончился на вопросе (INST-02): тоже ничего не изменено, мастер говорит, как продолжить.
_wz_takeover_gate() {
    local js c sug peers st line n_ad=0 n_foreign=0 adopted="" main_busy="" main_n=0 main_line="" p
    local -a todo=()
    _WZ_TK_LOCKED=""; _WZ_TK_LINE=()
    type import_scan >/dev/null 2>&1 && type import_adopt >/dev/null 2>&1 || return 0
    command -v jq >/dev/null 2>&1 || return 0
    # Docker не поставлен — контейнеров на машине нет: молча к обычному мастеру.
    if ! ga_dry && ! command -v docker >/dev/null 2>&1; then return 0; fi
    log_dim "$(t import_scanning)"
    GA_ERR_CODE=""; GA_ERR_MSG=""
    if ! GA_IMPORT_QUIET=1 ga_capture js import_scan 2>/dev/null; then
        if [ "${GA_ERR_CODE:-}" = docker_unreachable ]; then
            # Docker стоит, но молчит (остановлен, рассогласованы версии): что на сервере, не узнать. Установка
            # всё равно не удалит контейнер с людьми (страж профиля проверит ещё раз, когда поднимет демон),
            # но о своих людях человек должен узнать до вопросов, а не на полпути.
            echo ""
            log_warning "$(_ui_w "$(t wz_tk_docker_down)")"
            if ! ga_dry && confirm "$(t wz_tk_docker_start_ask)"; then
                systemctl start docker >/dev/null 2>&1 || true
                GA_ERR_CODE=""; GA_ERR_MSG=""
                ga_capture js import_scan 2>/dev/null || js=""
            else
                [ "$GA_INPUT_EOF" = 1 ] && return 3
                js=""
            fi
            [ -n "$js" ] || { log_info "$(_ui_w "$(t wz_tk_docker_down_go)")"; return 0; }
        else
            log_warning "$(_ui_w "$(tf wz_tk_scan_failed "${GA_ERR_MSG:-${GA_ERR_CODE:-?}}")")"
            return 0
        fi
    fi
    # Экран — только когда есть что-то не наше: свои же контейнеры (повтор мастера после сорвавшейся
    # установки) шуметь таблицей не должны.
    n_foreign=$(jq -r '[.[]? | select(.managed != true)] | length' <<<"$js" 2>/dev/null)
    [[ "$n_foreign" =~ ^[0-9]+$ ]] && [ "$n_foreign" -gt 0 ] || return 0
    echo ""
    echo -e "  ${BOLD}${WHITE}$(t wz_tk_title)${NC}"
    echo -e "  ${DIM}$(_rule)${NC}"
    _import_rows "$js"
    echo -e "  ${DIM}$(_rule)${NC}"
    mapfile -t todo < <(jq -r '.[]? | select(.adoptable == true)
        | [.container, .suggested_profile, (.peers // 0 | tostring), (.state // "running"), (.line // "")]
        | join("\u001f")' <<<"$js" 2>/dev/null)
    n_ad=${#todo[@]}
    if [ "$n_ad" = 0 ]; then
        # Подхватывать нечего (другие протоколы приложения): контейнеры остаются как были, мастер идёт дальше.
        log_info "$(_ui_w "$(t wz_tk_nothing_to_adopt)")"
        return 0
    fi
    echo -e "  $(ga_wrap "$(t wz_tk_explain)" "${GA_UI_W:-76}" 2)"
    if confirm "$(tf wz_tk_ask "$n_ad")"; then
        for p in "${todo[@]}"; do
            IFS=$'\x1f' read -r c sug peers st line <<<"$p"
            echo ""
            # Итог, подсказку про ключи людей и причину отказа import_adopt печатает сам.
            if import_adopt "$c" >/dev/null; then
                adopted="${adopted:+$adopted, }$(_import_pr_label "$sug")"
                continue
            fi
            _wz_takeover_left "$c" "$sug" "$peers" "$line" || { main_busy="$c"; main_n="$peers"; main_line="$line"; }
        done
        if [ -n "$adopted" ]; then
            echo ""
            log_success "$(_ui_w "$(tf wz_tk_done "$adopted")")"
            # Приложение ставит свои контейнеры на одну подсеть, и подхват берёт их как есть (SUBNET-01): раньше
            # второй отказывал «подсеть пересекается», а мастер на месте 2.0 с людьми останавливался. С кем совпала
            # подсеть и выход («Протоколы → профиль → Подсеть») import_adopt сказал выше; мастер идёт дальше, а новые
            # профили встанут на свободные подсети.
        fi
    else
        # Ответа нет вовсе (конец ввода) — это не отказ человека, а его отсутствие: ни подхвата, ни объяснений
        # отказа, остановка (INST-02).
        [ "$GA_INPUT_EOF" = 1 ] && return 3
        # Отказ — не молчаливое «ничего»: что это значит для каждого контейнера, говорим вслух.
        for p in "${todo[@]}"; do
            IFS=$'\x1f' read -r c sug peers st line <<<"$p"
            _wz_takeover_left "$c" "$sug" "$peers" "$line" || { main_busy="$c"; main_n="$peers"; main_line="$line"; }
        done
    fi
    if [ -n "$main_busy" ]; then
        # Место awg2 — опора мастера (его профиль ставится всегда), а занимает его контейнер приложения с людьми.
        # Удалять контейнер с людьми мы не будем — дальше мастеру идти не на чем. Линию называем честно: приложение
        # держит в amnezia-awg2 и 3.1, и тогда «профиль AmneziaWG 2.0 живёт в контейнере» было неправдой — 2.0 на
        # сервере свободна и после подхвата встанет на место awg3 (DUP-LINE-01).
        if [[ "$main_line" =~ ^(1\.0|1\.5|3\.1)$ ]]; then
            log_warning "$(_ui_w "$(tf wz_tk_declined_main_line "$main_busy" "$main_line" "$main_n")")"
        else
            log_warning "$(_ui_w "$(tf wz_tk_declined_main "$main_busy" "$main_n")")"
        fi
        return 1
    fi
    return 0
}

# _wz_takeover_left <контейнер> <профиль> <людей> — контейнер остался неподхваченным (отказ человека или
# неудача подхвата): сказать, что это значит. Код 1 — это место профиля 2.0 и в нём люди: мастер остановится.
_wz_takeover_left() {
    local c="$1" p="$2" n="${3:-0}" l="${4:-}"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    if [ "$n" -gt 0 ]; then
        [ "$p" = awg2 ] && return 1
        _WZ_TK_LOCKED="${_WZ_TK_LOCKED} $p"
        _WZ_TK_LINE[$p]="$l"
        log_info "$(_ui_w "$(tf wz_tk_declined_optional "$(_import_pr_label "$p" "$l")" "$c" "$n")")"
    else
        log_info "$(_ui_w "$(tf wz_tk_declined_empty "$c" "$(_import_pr_label "$p" "$l")")")"
    fi
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# Ленивый Pro в SSH (docs/MODES_047.md, F-1): домен — в цикле с подсказками, дальше без вопросов, в конце — сводка.
# Логика — lib/modes.sh (ga_modes_domain_norm, ga_modes_dns_ready, _ga_modes_plan, lazy_setup); здесь только экраны.
# Два входа: пункт 1 первого экрана мастера и `install.sh --lazy --domain=… [--keys=N]` без меню (goInstaller).
# ══════════════════════════════════════════════════════════════════════════════

# _lazy_ask_domain [нынешний домен] → GA_MODES_DOMAIN / GA_MODES_DISPLAY. rc 0 — домен есть; 1 — «0», назад; 2 —
# конец ввода. Никаких тупиков (урок goVLESS pro, U-03): пусто, мусор, IP — подсказка и тот же вопрос; выход — только
# «0». https://, путь и точка в конце отрезаются, кириллица переводится в punycode — и об этом сказано вслух. С нынешним
# доменом (установленный сервер) Enter оставляет его.
_lazy_ask_domain() {
    local def="${1:-}" v rc zb prompt
    zb=$(t ask_zero_back)
    zb="${zb// /$'\xc2\xa0'}"
    prompt=$(t lz_domain_ask)
    [ -n "$def" ] && prompt=$(tf lz_domain_ask_keep "$def")
    while true; do
        echo -ne "  $(ga_win_wrap "${WHITE}${prompt}${NC} ${DIM}${zb}${NC}${WHITE}:${NC}" 2) "
        if ! IFS= read -r v; then echo ""; GA_INPUT_EOF=1; return 2; fi
        v="${v#"${v%%[![:space:]]*}"}"
        v="${v%"${v##*[![:space:]]}"}"
        [ "$v" = 0 ] && return 1
        [ -z "$v" ] && [ -n "$def" ] && v="$def"
        rc=0
        ga_modes_domain_norm "$v" 2>/dev/null || rc=$?
        case "$rc" in
            0)
                case " $GA_MODES_FIXED " in
                    *" idn "*) log_info "$(_ui_w "$(tf lz_domain_idn "$GA_MODES_DISPLAY" "$GA_MODES_DOMAIN")")" ;;
                    "  ")      ;;
                    *)         log_info "$(_ui_w "$(tf lz_domain_taken "$GA_MODES_DOMAIN")")" ;;
                esac
                return 0
                ;;
            1) log_warning "$(_ui_w "$(t lz_domain_empty)")" ;;
            *)
                log_error "$(_ui_w "${GA_ERR_MSG:-$(t wz_domain_bad)}")"
                log_dim "$(_ui_w "$(t lz_domain_hint)")"
                ;;
        esac
    done
}

# _lazy_dns_wait <домен> → 0 — домен указывает сюда (или стоит за прокси Cloudflare); 1 — не дождались или «0» (ввести
# другой домен). Не сюда — показать, куда указывает, и перепроверять раз в 15 секунд до 5 минут (решение владельца
# 27.09); Enter — проверить сейчас. Без терминала read отвечает сразу — тогда ждём сами, вхолостую не крутимся.
_lazy_dns_wait() {
    local domain="$1" interval timeout start elapsed n=0 ch rc a mins
    interval=$(ga_modes_dns_interval)
    timeout=$(ga_modes_dns_timeout)
    mins=$(( (timeout + 59) / 60 ))
    start=$(date +%s)
    while true; do
        if ga_modes_dns_ready "$domain"; then
            if [ "$_GM_CF" = true ]; then
                log_info "$(_ui_w "$(_ga_modes_reason_text cloudflare_proxied)")"
            else
                log_success "$(_ui_w "$(tf lz_dns_ok "$GA_MODES_DISPLAY")")"
            fi
            return 0
        fi
        n=$((n + 1))
        elapsed=$(( $(date +%s) - start ))
        a=$(jq -r '(.a // []) | join(", ")' <<<"$_GM_DNS" 2>/dev/null)
        if [ "$n" = 1 ]; then
            log_warning "$(_ui_w "$(_ga_modes_dns_words "$_GM_DNS" "$GA_MODES_DISPLAY")")"
            log_dim "$(_ui_w "$(tf lz_dns_wait "$interval" "$mins")")"
        else
            log_dim "$(_ui_w "$(tf lz_dns_again "$n" "${a:--}" "$(( elapsed / 60 ))" "$(( elapsed % 60 ))")")"
        fi
        if [ "$elapsed" -ge "$timeout" ]; then
            log_warning "$(_ui_w "$(tf lz_dns_giveup "$mins")")"
            return 1
        fi
        ch=""
        if IFS= read -r -t "$interval" ch; then
            [ "$ch" = 0 ] && return 1
        else
            rc=$?
            [ "$rc" -gt 128 ] || sleep "$interval"
        fi
    done
}

# _lazy_explain — что показала проверка, словами: отказ — ошибками, Semi-Pro и прочее «как будет» — строками ниже.
_lazy_explain() {
    local r
    for r in "${_GM_REASONS[@]}" "${_GM_NOTES[@]}"; do
        case "$r" in
            tcp80_busy|tcp443_busy|tcp443_app|awg2_container_busy|dns_*)
                log_error "$(_ui_w "$(_ga_modes_reason_text "$r")")" ;;
            cloudflare_proxied) ;;
            udp443_busy|no_line_for_443|aaaa_foreign|docker_unreachable)
                log_warning "$(_ui_w "$(_ga_modes_reason_text "$r")")" ;;
            *)  log_info "$(_ui_w "$(_ga_modes_reason_text "$r")")" ;;
        esac
    done
    [ "$_GM_PLAN" = blocked ] || log_success "$(t lz_checks_ok)"
    return 0
}

# _lazy_run <ключей> [ask] — проверки, установка, сводка для домена GA_MODES_DOMAIN. ask — перед установкой спросить
# (установленный сервер: это смена режима на живом сервере). rc: 0 — готово; 3 — домен так и не указал сюда (спросить
# другой); 4 — здесь Ленивый Pro не встанет (порты, контейнер приложения); 5 — сбой установки; 6 — человек отказался.
_lazy_run() {
    local keys="$1" ask="${2:-}" js="" domain="$GA_MODES_DOMAIN" have new
    _lazy_dns_wait "$domain" || return 3
    _ga_modes_plan "$domain"
    _lazy_explain
    if [ "$_GM_PLAN" = blocked ]; then
        log_info "$(_ui_w "$(t lz_blocked_hint)")"
        return 4
    fi
    if [ "$ask" = ask ]; then
        # Ключи прошлых заходов засчитываются: обещать «ключей: 5», когда новых не будет ни одного, — неправда (LZ-05).
        have=$(_ga_modes_keys_have); [[ "$have" =~ ^[0-9]+$ ]] || have=0
        new=$(( keys > have ? keys - have : 0 ))
        [ "$have" -gt 0 ] && log_dim "$(_ui_w "$(tf lz_keys_have "$have")")"
        confirm "$(tf lz_confirm_installed "$(_mode_name "$( [ "$_GM_PLAN" = pro ] && echo pro || echo lite_site )")" "$new")" \
            || { log_info "$(t cancelled)"; return 6; }
    fi
    echo ""
    log_info "$(_ui_w "$(t lz_go)")"
    GA_ERR_CODE=""; GA_ERR_MSG=""
    # Профили до запуска: линию, которую поставит этот заход, остальным пользователям предложим выдать сразу (WA-2).
    local p before=""
    for p in $PROFILE_IDS; do _profile_installed "$p" && before="$before $p"; done
    # Шаги со спиннером печатает сам сценарий (ga_step); в stdout — только JSON итога. Почему Semi-Pro, уже сказано выше.
    if ! GA_MODES_EXPLAINED=1 ga_capture js lazy_setup "$domain" "$keys"; then
        log_info "$(_ui_w "$(t lz_failed_hint)")"
        return 5
    fi
    _lazy_summary "$js"
    # Недостающая линия встала на уже установленном сервере (WA-2 стенда 15.10: 2.0 рядом с подхваченной 3.1): ключи
    # Ленивого Pro её получили, а остальным — тот же вопрос, что после «Установить».
    if [ -n "$before" ]; then
        for p in $PROFILE_IDS; do
            [[ " $before " == *" $p "* ]] && continue
            _profile_installed "$p" && _profile_offer_keys_to_all "$p"
        done
    fi
    return 0
}

# _lazy_summary <JSON lazy_setup> — итог: режим и почему такая линия на 443, сайт, панель и её пароль (один раз),
# ключи со страницами подключения и QR по номеру, «Привязать Telegram-бота?» (токен скрытым вводом → привязка
# сообщением). Без терминала вопросы отвечают концом ввода — это «нет» и «позже».
_lazy_summary() {
    local js="$1" domain mode path w i n ch kp conf label l443 other oport oid
    local -a names=() labels=() pages=()
    domain=$(_json_field "$js" .domain)
    mode=$(_json_field "$js" .mode)
    echo ""
    echo -e "  ${BOLD}${GREEN}$(t lz_done_title)${NC}"
    echo -e "  ${DIM}$(_rule)${NC}"
    echo -e "  $(t ms_mode): ${CYAN}$(_mode_name "$mode")${NC}"
    # Почему такая линия на UDP 443 (решение владельца 27.09: 2.0 — шире всего поддержка клиентов) и где вторая — по
    # линиям из ответа, а не по местам профилей: приложение Amnezia держит 3.1 и в amnezia-awg2 (LZ-02).
    l443=$(_json_field "$js" .udp443.line)
    if [ "$l443" = 2.0 ] || [ "$l443" = 3.1 ]; then
        other=3.1; [ "$l443" = 3.1 ] && other=2.0
        oport=$(jq -r --arg l "$other" '[.profiles[]? | select(.line == $l)][0].port // ""' <<<"$js" 2>/dev/null)
        oid=$(jq -r --arg l "$other" '[.profiles[]? | select(.line == $l)][0].id // ""' <<<"$js" 2>/dev/null)
        if [ -z "$oport" ]; then
            if [ "$l443" = 2.0 ]; then log_info "$(_ui_w "$(t modes_line_20_only)")"; else log_info "$(_ui_w "$(t modes_line_31_only)")"; fi
        elif [ -n "$oid" ] && [ "$(_cfg ".profiles.$oid.preset")" = imported ]; then
            if [ "$l443" = 2.0 ]; then log_info "$(_ui_w "$(tf modes_line_20_adopted "$oport")")"
            else log_info "$(_ui_w "$(tf modes_line_31 "$oport")")"
            fi
        elif [ "$l443" = 2.0 ]; then
            log_info "$(_ui_w "$(tf modes_line_20 "$oport")")"
        else
            log_info "$(_ui_w "$(tf modes_line_31_own "$oport")")"
        fi
    fi
    jq -e '.warnings | index("cloudflare_proxied") != null' <<<"$js" >/dev/null 2>&1 \
        && log_info "$(_ui_w "$(tf lz_keys_ip "$(_server_ip)")")"
    # Контейнеры приложения подхвачены на одной подсети (SUBNET-01): сценарий без вопросов их не переносит —
    # напоминание с выходом здесь, в итоге, а не только посреди хода установки.
    jq -e '.warnings | index("subnet_overlap") != null' <<<"$js" >/dev/null 2>&1 && _subnet_overlaps_note
    # Сайт: на домене с настоящим сертификатом, на запасном (по IP) или никакого.
    if _site_domain_ready; then
        echo -e "  $(t lz_site): ${CYAN}https://${domain}/${NC}"
    elif _site_has_site; then
        echo -e "  $(t lz_site): ${CYAN}https://$(_server_ip)/${NC}"
        echo -e "  ${DIM}$(_ui_w "$(t lz_site_selfsigned)")${NC}"
    else
        echo -e "  $(t lz_site): ${DIM}$(t lz_site_none)${NC}"
    fi
    # Панель на домене: адрес и пароль — один раз, здесь.
    path=$(_cfg '.panel.miniapp_path')
    if [ "$(_json_field "$js" .panel_on_domain)" = true ] && [ -n "$path" ]; then
        echo -e "  $(t lz_panel): ${CYAN}$(_site_panel_url "$domain" "$path")${NC}"
        echo -e "  ${DIM}$(_ui_w "$(t lz_panel_secret)")${NC}"
        if [ "$(_cfg '.panel.password_pending')" = true ]; then
            _panel_password_pending_issue quiet || true
        else
            echo -e "  ${DIM}$(_ui_w "$(t lz_panel_pwd_known)")${NC}"
        fi
    elif _panel_present; then
        echo ""
        _panel_tunnel_hint
    fi
    # Ключи и страницы подключения — по номеру и QR по номеру.
    mapfile -t names < <(jq -r '.keys[]? | .name' <<<"$js" 2>/dev/null)
    mapfile -t labels < <(jq -r '.keys[]? | .label' <<<"$js" 2>/dev/null)
    mapfile -t pages < <(jq -r '.keys[]? | (.page // "")' <<<"$js" 2>/dev/null)
    n=${#names[@]}
    echo ""
    echo -e "  ${WHITE}$(tf lz_keys_title "$n")${NC}"
    for ((i = 0; i < n; i++)); do
        echo -e "  ${CYAN}$((i + 1))${NC}) ${labels[$i]} ${DIM}(${names[$i]})${NC}"
        [ -n "${pages[$i]:-}" ] && echo -e "     ${GREEN}${pages[$i]}${NC}"
    done
    if [ "$n" -gt 0 ] && [ -z "${pages[0]:-}" ]; then
        log_dim "$(_ui_w "$(t lz_pages_none)")"
    elif [ "$n" -gt 0 ]; then
        log_warning "$(_ui_w "$(t pg_is_key)")"
    fi
    # QR ключа без страницы — самого сильного профиля: 3.1 по линии, а не по месту (AWG31-01).
    kp=""
    for i in awg3 awg2; do _profile_installed "$i" && kp="${kp:+$kp }$i"; done
    kp=$(_profile_31_first "${kp:-awg2}")
    while [ "$n" -gt 0 ]; do
        echo -ne "  $(ga_win_wrap "${WHITE}$(tf lz_qr_ask "$n")${NC}:" 2) "
        IFS= read -r ch || { echo ""; break; }
        ch="${ch//[[:space:]]/}"
        [ -n "$ch" ] && [ "$ch" != 0 ] || break
        if ! [[ "$ch" =~ ^[0-9]{1,2}$ ]] || [ "$((10#$ch))" -lt 1 ] || [ "$((10#$ch))" -gt "$n" ]; then
            log_error "$(t invalid_choice)"
            continue
        fi
        i=$((10#$ch - 1))
        label="${labels[$i]}"
        echo ""
        if [ -n "${pages[$i]:-}" ]; then
            echo -e "  ${WHITE}$(tf lz_qr_title "$label")${NC}"
            _qr_utf8 "${pages[$i]}" || echo -e "  ${GREEN}${pages[$i]}${NC}"
        elif type export_conf >/dev/null 2>&1; then
            conf=""
            if ga_capture conf export_conf "${names[$i]}" "$kp" 2>/dev/null && [ -n "$conf" ]; then
                type ga_export_audit_key >/dev/null 2>&1 && ga_export_audit_key "${names[$i]}" "$kp" lazy
                echo -e "  ${WHITE}$(tf key_title_conf "${names[$i]}" "$(_pr_name "$kp")")${NC}"
                _key_conf_qr "$conf" "$kp" || true
            fi
            conf=""
        fi
    done
    # Бот — после всего: токен скрытым вводом, администратор — сообщением с подтверждением здесь, в SSH.
    if [ -f "$SCRIPT_DIR/goamnezia-bot/install_bot.sh" ] && [ ! -f "$BOT_DIR/.env" ]; then
        echo ""
        if confirm "$(t lz_bot_ask)"; then
            _bot_install_interactive pair || true
        else
            log_dim "$(t lz_bot_later)"
        fi
    fi
    # Соседи профилей и goWARP PRO после «Удалить всё» — как в конце мастера (WRP-06).
    type ga_amn_install_notes >/dev/null 2>&1 && ga_amn_install_notes
    log_info "$(_ui_w "$(t lz_next)")"
    return 0
}

# _lazy_wizard — пункт «1 Ленивый Pro» первого экрана мастера. rc 0 — установлено (сводка показана); 1 — «0», назад
# к выбору режима; 2 — конец ввода или сбой: мастер заканчивается, при следующем запуске откроется снова.
_lazy_wizard() {
    local rc
    echo ""
    echo -e "  ${BOLD}${WHITE}$(t lz_title)${NC}"
    echo -e "  ${DIM}$(ga_win_wrap "$(t lz_intro)" 2)${NC}"
    while true; do
        _lazy_ask_domain; rc=$?
        [ "$rc" = 1 ] && return 1
        # Конец ввода — мастер скажет сам, как продолжить (INST-02); «отменён» здесь было бы второй строкой о том же.
        [ "$rc" = 0 ] || { [ "$GA_INPUT_EOF" = 1 ] || log_info "$(t lz_cancelled)"; return 2; }
        _lazy_run "${GA_LAZY_KEYS:-$GA_MODES_KEYS_DEFAULT}"; rc=$?
        case "$rc" in
            0) return 0 ;;
            3) continue ;;
            4) return 1 ;;
            *) return 2 ;;
        esac
    done
}

# install.sh --lazy --domain=<домен> [--keys=N] — Ленивый Pro без меню (goInstaller, MODES_047 п. 7). Конец ввода —
# отмена, а не согласие (goinstaller-ready §10): вопросов нет, кроме домена (не передан или не годится — спросим, если
# есть терминал) и бота в конце. Установленный сервер не трогаем — повторный запуск ничего не ломает (п. 8).
# rc 0 — готово или уже установлен; 1 — не встал или отменён; 2 — неверные аргументы.
_lazy_headless() {
    local domain="${1:-}" keys="${2:-}" rc
    [ -n "$keys" ] || keys="$GA_MODES_KEYS_DEFAULT"
    if ! [[ "$keys" =~ ^[0-9]{1,3}$ ]] || [ "$((10#$keys))" -lt 1 ] || [ "$((10#$keys))" -gt "$GA_MODES_KEYS_MAX" ]; then
        log_error "$(tf modes_err_keys "$GA_MODES_KEYS_MAX" "$keys")"
        return 2
    fi
    keys=$((10#$keys))
    if [ "$(_cfg '.installed')" = true ]; then
        log_info "$(_ui_w "$(t lz_already_installed)")"
        return 0
    fi
    echo ""
    echo -e "  ${BOLD}${WHITE}$(t lz_title)${NC}"
    echo -e "  ${DIM}$(ga_win_wrap "$(t lz_intro)" 2)${NC}"
    while true; do
        rc=1
        if [ -n "$domain" ]; then
            rc=0
            ga_modes_domain_norm "$domain" 2>/dev/null || rc=$?
            if [ "$rc" = 0 ]; then
                case " $GA_MODES_FIXED " in
                    *" idn "*) log_info "$(_ui_w "$(tf lz_domain_idn "$GA_MODES_DISPLAY" "$GA_MODES_DOMAIN")")" ;;
                    "  ")      ;;
                    *)         log_info "$(_ui_w "$(tf lz_domain_taken "$GA_MODES_DOMAIN")")" ;;
                esac
            else
                log_error "$(_ui_w "${GA_ERR_MSG:-$(t lz_domain_empty)}")"
            fi
            domain=""
        fi
        if [ "$rc" != 0 ]; then
            _lazy_ask_domain || { log_info "$(t lz_cancelled)"; return 1; }
        fi
        GA_MODES_ADOPT=1 _lazy_run "$keys"; rc=$?
        case "$rc" in
            0) return 0 ;;
            3) continue ;;
            *) return 1 ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# Мастер: прерванная установка (INST-01, INST-02 — чистая установка на сервере 168, 04.10.2026)
# ══════════════════════════════════════════════════════════════════════════════
# Как было. Мастер дошёл до вопроса о линии на UDP 443, и терминал пропал. Конец ввода он принимал за Enter: сам
# ответил по умолчанию и поставил Docker, awg3 и awg2 — без человека. Человек запустил установку снова, и пошли два
# мастера сразу: второй насчитал, что awg2 ещё нет, а поставить не смог — «Профиль awg2 уже установлен» (успел
# первый). Установка оборвалась на шаге профилей, сайт Pro так и не поднялся, а меню показывало «Режим: Pro»:
# желаемый режим мастер писал в config.json (mode) ДО установки, и меню читало его как действующий. status к тому
# времени показывал lite — первый мастер дошёл до сайта, сайт не встал, и режим вернулся в Lite: одно поле значило
# то «хочу», то «есть», смотря кто и когда его прочёл.
#
# Как стало:
#   • конец ввода на вопросе — остановка: без человека мастер ничего не ставит, уже данные ответы запоминает, и
#     повторный запуск продолжает с того же вопроса (_wz_save, экран _wz_resume_screen);
#   • ответы — отдельной записью .wizard в config.json, а не в mode и domain: режим и домен пишет модуль сайта,
#     когда сайт поднят (_ga_site_set_mode). Пока запись есть, установка не закончена: main() открывает мастер, и
#     при installed=true тоже (оборвалось после профилей), а шапка меню говорит об этом словами;
#   • мастер на сервере один (_wz_lock): второй заход, пока жив первый, называет его и ничего не трогает;
#   • уже стоящий профиль — «уже стоит — оставляю» (_wz_profile_ensure): не переставляется (ключи сервера и людей
#     прежние), лежащий поднимается из копии состояния, порт не двигается.
#
# Запись .wizard: step — где остановились: вопрос domain | line | profiles | ports или install (ответы все, идёт
# установка); mode, domain, line443, awg3 и awg1 (true|false), ports {профиль: порт} — ответы, по мере того как они
# даны; admin — первый пользователь, когда он заведён; started — когда начали. Снимается в конце установки.

# Установка не закончена: есть запись ответов мастера.
_wz_pending() { [ -n "$(_cfg '.wizard.step')" ]; }

# _wz_step_n <шаг> → номер шага мастера по порядку: по нему видно, какие ответы к этому шагу уже даны.
_wz_step_n() {
    case "${1:-}" in
        domain) echo 1 ;; line) echo 2 ;; profiles) echo 3 ;; ports) echo 4 ;; install) echo 5 ;; *) echo 0 ;;
    esac
}

# _wz_save <шаг> — записать в .wizard ответы, данные до шага <шаг>. Ответы — local мастера (mode, domain, want_awg3,
# want_awg1: bash видит их отсюда), линия и порты — глобальные _WZ_LINE443 и _WZ_PORT. На первом вопросе помнить
# нечего — прежняя запись, если была, остаётся как есть.
_wz_save() {
    local at="${1:-}" n js started adm p pj='{}' a3=false a1=false
    command -v jq >/dev/null 2>&1 && type ga_config_set >/dev/null 2>&1 || return 0
    n=$(_wz_step_n "$at")
    [ "$n" -ge 1 ] || return 0
    started=$(_cfg '.wizard.started'); [ -n "$started" ] || started=$(_now_iso)
    adm=$(_cfg '.wizard.admin')
    [ "$want_awg3" = 1 ] && a3=true
    [ "$want_awg1" = 1 ] && a1=true
    if [ "$n" -ge 5 ]; then
        for p in awg3 awg2 awg1; do
            case "$p" in awg3) [ "$a3" = true ] || continue ;; awg1) [ "$a1" = true ] || continue ;; esac
            [[ "${_WZ_PORT[$p]:-}" =~ ^[0-9]{1,5}$ ]] || continue
            pj=$(jq -c --arg p "$p" --argjson v "$((10#${_WZ_PORT[$p]}))" '. + {($p): $v}' <<<"$pj") || pj='{}'
        done
    fi
    js=$(jq -nc --arg s "$at" --arg t "$started" --arg a "$adm" --arg m "$mode" --arg d "$domain" \
                --arg l "${_WZ_LINE443:-awg2}" --argjson a3 "$a3" --argjson a1 "$a1" --argjson pj "$pj" --argjson n "$n" '
        {step: $s, started: $t, mode: $m}
        + (if $n >= 2 then {domain: $d} else {} end)
        + (if $n >= 3 then {line443: $l} else {} end)
        + (if $n >= 4 then {awg3: $a3, awg1: $a1} else {} end)
        + (if $n >= 5 then {ports: $pj} else {} end)
        + (if $a != "" then {admin: $a} else {} end)') || return 0
    ga_config_set .wizard "$js" >/dev/null 2>&1 \
        || log_warning "$(_ui_w "$(t act_failed)")"
    return 0
}

# _wz_clear — установка закончена: записи ответов больше нет, следующий запуск — меню, а не мастер.
_wz_clear() {
    [ -f "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1 || return 0
    jq -e 'has("wizard")' "$CONFIG_FILE" >/dev/null 2>&1 || return 0
    ga_with_config_lock _wz_clear_locked \
        || log_warning "$(_ui_w "$(t act_failed)")"
    return 0
}
_wz_clear_locked() {
    local out
    ga_config_intact || return 1
    out=$(jq -c 'del(.wizard)' "$CONFIG_FILE" 2>/dev/null) || return 1
    [ -n "$out" ] || return 1
    printf '%s' "$out" | _ga_write_json "$CONFIG_FILE"
}

# _wz_stop_no_input — вопрос мастера остался без ответа (конец ввода): ничего не ставлю, как продолжить.
_wz_stop_no_input() {
    echo ""
    log_warning "$(_ui_w "$(t wz_eof_stop)")"
}

# ── Один мастер на сервер ─────────────────────────────────────────────────────
# _wz_lock → 0 — мастер наш (номер процесса записан); 1 — идёт другой: назван, ничего не тронуто. Номер — в
# $LOCK_DIR/wizard.pid (/run: после перезагрузки файла нет), создаётся атомарно (noclobber). Файл убитого процесса
# не мешает: жив ли записанный процесс и мастер ли он (install.sh или goamnezia без --action=: номер мог достаться
# вызову моста), проверяется. Не flock на дескрипторе: его унаследовали бы процессы, которые мастер оставляет жить
# (временная ссылка на файл), и замок держался бы после мастера.
_WZ_LOCKED=0
_wz_lock_file() { printf '%s/wizard.pid' "${LOCK_DIR:-/run/goamnezia}"; }
_wz_pid_is_wizard() {
    local pid="${1:-}" cmd
    [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" != "$$" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    cmd=$(ps -o args= -p "$pid" 2>/dev/null) || return 0
    case "$cmd" in
        *--action=*)               return 1 ;;
        *install.sh*|*goamnezia*)  return 0 ;;
    esac
    return 1
}
_wz_lock() {
    local f pid i
    f=$(_wz_lock_file)
    mkdir -p "${f%/*}" 2>/dev/null || return 0
    for i in 1 2; do
        if ( set -C; printf '%s\n' "$$" >"$f" ) 2>/dev/null; then
            _WZ_LOCKED=1
            return 0
        fi
        pid=$(head -c 16 "$f" 2>/dev/null | tr -cd '0-9')
        if [ "$pid" = "$$" ]; then _WZ_LOCKED=1; return 0; fi
        if _wz_pid_is_wizard "$pid"; then
            log_warning "$(_ui_w "$(tf wz_busy "$pid")")"
            return 1
        fi
        # Файл от процесса, которого больше нет (убит, оборвалась сессия), — убрать и взять заново.
        rm -f "$f" 2>/dev/null
    done
    # Записать не вышло (только чтение, нет места) — человека из-за служебного файла не держим.
    return 0
}
_wz_unlock() {
    local f
    [ "$_WZ_LOCKED" = 1 ] || return 0
    _WZ_LOCKED=0
    f=$(_wz_lock_file)
    [ "$(head -c 16 "$f" 2>/dev/null | tr -cd '0-9')" = "$$" ] && rm -f "$f" 2>/dev/null
    return 0
}

# _wz_session — мастер под замком «один на сервер»; main() зовёт его вместо install_wizard. rc мастера: 0 — готово;
# 1 — отменён или не встал (дальше меню); 3 — ввод оборвался; 4 — уже идёт другой мастер.
_wz_session() {
    local rc=0
    _wz_lock || return 4
    install_wizard || rc=$?
    _wz_unlock
    return "$rc"
}

# _wz_legacy_pending — прерванная установка прежней версии (INST-01): мастер до 1.0.10 писал желаемый режим в mode ДО
# установки сайта, и обрыв после профилей оставлял installed=true, «Режим: Pro» в шапке меню и сайт, которого нет
# (так было на сервере 168). «Сменить режим → Pro» из меню такой сервер тоже не чинил: режим и так «pro», и смена
# была бы только выбором линии. Узнаётся по фактам: режим с сайтом, а vhost нашего сайта на диске нет, и вида
# сертификата модуль сайта не записывал (он пишет его вместе с режимом). Тогда — запись ответов, как у прерванного
# мастера этой версии (режим и домен — из config.json, профили и порты — стоящие), и честный Lite в mode: мастер
# предложит продолжить — дальше сайт, панель, первый пользователь, если его нет. Судить нельзя (сухой прогон без путей
# nginx стенда) — ничего не трогаем.
_wz_legacy_pending() {
    local m d p q js pj='{}' l443=awg2 a3=false a1=false
    command -v jq >/dev/null 2>&1 && type ga_config_set >/dev/null 2>&1 || return 0
    [ "$(_cfg '.installed')" = true ] || return 0
    _wz_pending && return 0
    m=$(_mode_current)
    [ "$m" != lite ] || return 0
    [ -z "$(_cfg '.site.cert')" ] || return 0
    _ga_site_vhost_checkable || return 0
    _ga_site_vhost_present && return 0
    d=$(_cfg '.domain')
    for p in awg3 awg2 awg1; do
        _profile_installed "$p" || continue
        case "$p" in awg3) a3=true ;; awg1) a1=true ;; esac
        q=$(_cfg ".profiles.$p.port")
        [[ "$q" =~ ^[0-9]{1,5}$ ]] || continue
        pj=$(jq -c --arg p "$p" --argjson v "$((10#$q))" '. + {($p): $v}' <<<"$pj") || pj='{}'
        [ "$q" = 443 ] && [ "$p" != awg1 ] && l443="$p"
    done
    js=$(jq -nc --arg t "$(_now_iso)" --arg m "$m" --arg d "$d" --arg l "$l443" \
                --argjson a3 "$a3" --argjson a1 "$a1" --argjson pj "$pj" \
        '{step: "install", started: $t, mode: $m, domain: $d, line443: $l, awg3: $a3, awg1: $a1, ports: $pj}') || return 0
    ga_config_set .wizard "$js" >/dev/null 2>&1 || return 0
    ga_config_merge '{"mode":"lite"}' >/dev/null 2>&1 || true
    return 0
}

# _wz_resume_screen — повторный запуск после обрыва (INST-01): что уже ответили и что уже стоит, откуда дальше.
# rc 0 — продолжить; 1 — ответить на вопросы заново; 2 — в меню; 3 — конец ввода.
_wz_resume_screen() {
    local at n mode_w dom l443 p port mark ch any=0
    at=$(_cfg '.wizard.step'); n=$(_wz_step_n "$at")
    mode_w=$(_cfg '.wizard.mode'); dom=$(_cfg '.wizard.domain'); l443=$(_cfg '.wizard.line443')
    echo ""
    echo -e "  ${BOLD}${WHITE}$(t wz_resume_title)${NC}"
    echo -e "  ${DIM}$(_rule)${NC}"
    [ -n "$mode_w" ] && echo -e "  $(t ms_mode): ${CYAN}$(_mode_name "$mode_w")${NC}"
    [ -n "$dom" ] && echo -e "  $(t ms_domain): ${CYAN}${dom}${NC}"
    if [ "$mode_w" = pro ] && [ "$n" -ge 3 ] && [ -n "$l443" ]; then
        echo -e "  $(t pl_header): ${CYAN}$(_pr_label "$l443" noport)${NC}"
    fi
    # Профили: выбранные в прошлый раз и уже стоящие — с портом; стоящий — с пометкой.
    for p in awg3 awg2 awg1; do
        mark=""; port=""
        if _profile_installed "$p"; then
            port=$(_cfg ".profiles.$p.port"); mark=" · $(t wz_resume_installed)"
        elif [ "$n" -ge 4 ] && { [ "$p" = awg2 ] || [ "$(_cfg ".wizard.$p")" = true ]; }; then
            port=$(_cfg ".wizard.ports.$p")
        else
            continue
        fi
        [ "$any" = 1 ] || echo -e "  $(t wz_resume_profiles):"
        any=1
        if [ -n "$port" ]; then
            echo -e "    $(_pr_label "$p" noport) — ${CYAN}$(tf wz_resume_port "$port")${NC}${DIM}${mark}${NC}"
        else
            echo -e "    $(_pr_label "$p")${DIM}${mark}${NC}"
        fi
    done
    case "$at" in
        domain)   log_dim "$(_ui_w "$(t wz_resume_next_domain)")" ;;
        line)     log_dim "$(_ui_w "$(t wz_resume_next_line)")" ;;
        profiles) log_dim "$(_ui_w "$(t wz_resume_next_profiles)")" ;;
        ports)    log_dim "$(_ui_w "$(t wz_resume_next_ports)")" ;;
        *)        log_dim "$(_ui_w "$(t wz_resume_next_install)")" ;;
    esac
    echo -e "  ${DIM}$(_rule)${NC}"
    while true; do
        echo -ne "  $(ga_win_wrap "${WHITE}$(t wz_resume_prompt):${NC}" 2) "
        if ! read -r ch; then echo ""; GA_INPUT_EOF=1; return 3; fi
        case "$ch" in
            "") return 0 ;;
            1)  return 1 ;;
            0)  return 2 ;;
            *)  log_error "$(t invalid_choice)" ;;
        esac
    done
}

# _wz_load — ответы из записи .wizard — в local мастера (bash видит их отсюда): режим, домен, линия на UDP 443,
# галочки профилей. Замкнутые галочки (подхвачен, место занято людьми приложения) решают сами, как и в опросе.
# Порты — отдельно (_wz_resume_ports): им ещё надо годиться.
_wz_load() {
    local n v
    n=$(_wz_step_n "$(_cfg '.wizard.step')")
    v=$(_cfg '.wizard.mode'); case "$v" in pro|lite_site|lite) mode="$v" ;; esac
    domain=$(_cfg '.wizard.domain')
    v=$(_cfg '.wizard.line443'); case "$v" in awg2|awg3) _WZ_LINE443="$v" ;; esac
    [ "$n" -ge 4 ] || return 0
    want_awg3=0; want_awg1=0
    [ "$(_cfg '.wizard.awg3')" = true ] && want_awg3=1
    [ "$(_cfg '.wizard.awg1')" = true ] && want_awg1=1
    if [ "${wz_locked[0]}" = 1 ]; then want_awg3="${wz_state[0]}"; else wz_state[0]="$want_awg3"; fi
    if [ "${wz_locked[2]}" = 1 ]; then want_awg1="${wz_state[2]}"; else wz_state[2]="$want_awg1"; fi
    return 0
}

# _wz_resume_ports — порты из записи для продолжения установки (шаг install): стоящему профилю — его нынешний порт
# (разошёлся с записанным — сказано вслух, порт не двигается), остальным — записанные, если ещё годятся. rc 0 —
# годятся все, ставим; 1 — какой-то нет (занял кто-то другой) или Pro остался без профиля на UDP 443: экран портов,
# где прежние порты предложены там, где они годятся.
_wz_resume_ports() {
    local p q msg rc=0
    local -a profs=()
    [ "$want_awg3" = 1 ] && profs+=(awg3)
    profs+=(awg2)
    [ "$want_awg1" = 1 ] && profs+=(awg1)
    _WZ_PORT=()
    _WZ_MODE="$mode"
    # Сначала стоящие: их порты заняты наверняка, и записанный порт другого профиля сверяется с ними. Стоит не на том
    # порту, что выбран в прошлый раз (сменили в «Протоколах», ботом, вторая установка), — оставляем, как стоит, и
    # говорим вслух.
    for p in "${profs[@]}"; do
        _profile_installed "$p" || continue
        _WZ_PORT[$p]=$(_cfg ".profiles.$p.port")
        q=$(_cfg ".wizard.ports.$p")
        if [[ "$q" =~ ^[0-9]{1,5}$ ]] && [ "$q" != "${_WZ_PORT[$p]}" ]; then
            log_warning "$(_ui_w "$(tf wz_port_kept "$(_pr_label "$p" noport)" "${_WZ_PORT[$p]}" "$q" "${_WZ_PORT[$p]}")")"
        fi
    done
    for p in "${profs[@]}"; do
        _profile_installed "$p" && continue
        q=$(_cfg ".wizard.ports.$p")
        if ! [[ "$q" =~ ^[0-9]{1,5}$ ]] || _wz_port_taken "$q"; then rc=1; continue; fi
        if ! msg=$(_wz_port_check "$p" "$q"); then
            log_warning "$(_ui_w "$(tf wz_resume_port_bad "$q" "$(_pr_label "$p")" "$msg")")"
            rc=1
            continue
        fi
        _WZ_PORT[$p]="$q"
    done
    [ "$rc" = 0 ] && [ "$_WZ_MODE" = pro ] && ! _wz_port_taken 443 && rc=1
    # Экран портов возьмёт годные прежние (_wz_ports_default: тот же режим и та же линия — прежний выбор).
    [ "$rc" = 0 ] || { _WZ_LAST_MODE="$mode"; _WZ_LAST_LINE="${_WZ_LINE443:-awg2}"; }
    return "$rc"
}

# _wz_profile_ensure <профиль> <порт> — шаг 8 мастера для одного профиля: не стоит — поставить; уже стоит (прошлый
# заход, подхват, вторая установка успела раньше) — оставить как есть. rc 0 — профиль на месте; 1 — не встал.
_wz_profile_ensure() {
    local p="$1" port="${2:-}"
    if ! _profile_installed "$p"; then
        GA_ERR_CODE=""
        if ga_step "$(tf wz_install_profile "$(_pr_install_name "$p")")" "$(tf wz_profile_done "$(_pr_install_name "$p")")" "$(t eta_profile)" \
                amnezia_profile_install "$p" "$port" default; then
            return 0
        fi
        # «Профиль уже установлен» — его поставили, пока шла эта установка (сервер 168: второй мастер и первый,
        # оставшийся без терминала). Это не обрыв: профиль есть — оставляем его, как стоящий.
        [ "${GA_ERR_CODE:-}" = profile_exists ] && _profile_installed "$p" || return 1
    fi
    _wz_profile_keep "$p" "$port"
    return 0
}

# _wz_profile_keep <профиль> <порт из мастера> — профиль уже стоит: не переставлять (ключи сервера и людей —
# прежние). Работает — так и сказать; лежит или контейнера нет — поднять из копии состояния, как «Поднять контейнер
# заново». Порт не двигается: разошёлся с выбранным в мастере — сказать вслух, какой остаётся и где его менять.
# Решение (INST-01): оставить работающий, а не спрашивать — порт уже мог уйти в ключ первого пользователя или в
# приложение владельца, смена порта пересоздаёт контейнер, а сменить его можно одним пунктом в «Протоколах».
_wz_profile_keep() {
    local p="$1" want="${2:-}" st cur label n_save="${GA_STEP_N:-0}"
    cur=$(_cfg ".profiles.$p.port")
    label=$(_pr_label "$p" noport)     # порт — в самих фразах («уже стоит и работает (порт 3049)»)
    st=$(_profile_state "$p")
    if [ "$st" = running ]; then
        log_success "$(_ui_w "$(tf wz_profile_kept "$label" "${cur:-?}")")"
    elif [ "$(_cfg ".profiles.$p.imported")" = true ]; then
        # Подхваченный у приложения контейнер мастер сам не пересоздаёт (запускает его экран подхвата): только
        # говорит, что он лежит и где его поднять.
        log_warning "$(_ui_w "$(tf wz_profile_imported_down "$label")")"
    else
        log_info "$(_ui_w "$(tf wz_profile_kept_down "$label")")"
        # Подъём — вне нумерации шагов: «Шаг 4 из 3» обещал бы то, чего в счёте не было.
        GA_STEP_N=0
        if ! { type amnezia_profile_repair >/dev/null 2>&1 \
               && ga_step "$(tf pr_repairing "$(_pr_name "$p")")" "$(tf pr_repaired "$(_pr_name "$p")")" "$(t eta_profile)" amnezia_profile_repair "$p"; }; then
            log_warning "$(_ui_w "$(tf wz_profile_revive_failed "$label")")"
        fi
        GA_STEP_N="$n_save"
    fi
    if [ -n "$want" ] && [ -n "$cur" ] && [ "$want" != "$cur" ]; then
        log_warning "$(_ui_w "$(tf wz_port_kept "$label" "$cur" "$want" "$cur")")"
    fi
    return 0
}

install_wizard() {
    local mode="lite" domain="" ch
    local want_awg3=0 want_awg1=0
    local port dns1 dns2 p cfg ip pf="" pick lrc rs=""
    # Конец ввода считается заново на каждый заход мастера (lib/common.sh, GA_INPUT_EOF).
    GA_INPUT_EOF=0

    echo ""
    echo -e "  ${BOLD}${WHITE}$(t wz_title)${NC}"
    echo -e "  ${DIM}$(_rule)${NC}"

    # ── 0. Контейнеры Amnezia, которые уже стоят на сервере — до первого вопроса (OWN-1) ──
    # Конец ввода на вопросе о подхвате — остановка с тем же объяснением, что на любом вопросе мастера (INST-02).
    _wz_takeover_gate; lrc=$?
    case "$lrc" in
        0) ;;
        3) _wz_stop_no_input; return 3 ;;
        *) return 1 ;;
    esac

    # Шаги 1–4 — режим, домен, профили, порты — идут по кругу, и «0» на каждом
    # ведёт на шаг назад, а не бросает мастер: раньше ноль на галочках отменял
    # установку целиком, а у домена выхода назад не было вовсе (замечание
    # критика-пользователя). Выйти совсем — «0» на первом экране. Конец ввода на
    # любом шаге — остановка (INST-02): раньше он значил «дальше с умолчаниями», и
    # мастер, оставшийся без терминала, сам ставил профили по умолчанию.
    local -a wz_labels wz_notes wz_state wz_locked wz_profs wz_lockmsg
    local step=mode i w3_locked w3_msg
    _WZ_LINE443=awg2
    wz_labels=("$(t pr_awg3)" "$(t pr_awg2)" "$(t pr_awg1)")
    wz_notes=("$(t wz_awg3_for)" "$(t wz_awg2_for)" "$(t wz_awg1_for)")
    wz_state=(1 1 0)
    wz_locked=(0 1 0)
    wz_lockmsg=("" "" "")
    # Подхваченные профили (этот экран или прошлый заход) — отмечены и замкнуты: мастер их не ставит заново,
    # только показывает. Профиль, чьё место занимает контейнер с людьми, от подхвата которого отказались, —
    # снят и замкнут: ставить его значило бы удалить людей (установка и так отказала бы foreign_container).
    i=0
    for p in awg3 awg2 awg1; do
        if [ "$(_cfg ".profiles.$p.imported")" = true ] && _profile_installed "$p"; then
            wz_state[i]=1; wz_locked[i]=1
            wz_notes[i]="$(t wz_tk_note_adopted)"
            wz_lockmsg[i]="$(tf wz_tk_lock_adopted "$(_import_pr_label "$p")")"
        elif [[ " $_WZ_TK_LOCKED " == *" $p "* ]]; then
            wz_state[i]=0; wz_locked[i]=1
            wz_notes[i]="$(t wz_tk_note_busy)"
            wz_lockmsg[i]="$(tf wz_tk_lock_busy "$(_import_pr_label "$p" "${_WZ_TK_LINE[$p]:-}")")"
        fi
        i=$((i + 1))
    done
    # Строки — по линии, а не по месту (DUP-LINE-01, сценарий пользователя 15.10): подхваченный amnezia-awg2 приложения
    # держит 3.1 — его строка «AmneziaWG 3.1 (awg2 · UDP 46567)», а свободное место awg3 подписано линией, которая на
    # него встанет (ga_profile_auto_line — то же правило, что «Установить» и Ленивый Pro): «AmneziaWG 2.0 (awg3)».
    # Строка, на которую встанет 2.0, отмечена и замкнута — 2.0 ставится всегда (её понимают и прошлые версии
    # приложений, и роутеры Keenetic). Раньше галочка 2.0 жила только у места awg2: при подхваченной 3.1 в нём человек
    # видел «2.0 подхвачен из приложения», а поставить 2.0 было некуда.
    local -a wz_places=(awg3 awg2 awg1)
    local wl
    for i in 0 1; do
        p="${wz_places[$i]}"
        if _profile_installed "$p"; then
            wz_labels[i]="$(_pr_name "$p")"
            continue
        fi
        if [[ " $_WZ_TK_LOCKED " == *" $p "* ]]; then
            wz_labels[i]="$(_import_pr_label "$p" "${_WZ_TK_LINE[$p]:-}")"
            continue
        fi
        type ga_profile_auto_line >/dev/null 2>&1 || continue
        wl=$(ga_profile_auto_line "$p" 2>/dev/null)
        [[ "$wl" =~ ^(2\.0|3\.1)$ ]] || continue
        wz_labels[i]="$(tf pr_title_line "$wl")"
        if [ "$wl" = 2.0 ]; then
            wz_notes[i]="$(t wz_awg2_for)"; wz_state[i]=1; wz_locked[i]=1; wz_lockmsg[i]="$(t wz_awg2_always)"
        else
            wz_notes[i]="$(t wz_awg3_for)"
        fi
    done
    # awg1: стоит — подписью, свободный — линией, которая встанет («AmneziaWG 1.5», как везде, LABEL-02)
    if _profile_installed awg1; then wz_labels[2]="$(_pr_name awg1)"
    elif [[ " $_WZ_TK_LOCKED " == *" awg1 "* ]]; then wz_labels[2]="$(_import_pr_label awg1 "${_WZ_TK_LINE[awg1]:-}")"
    else wz_labels[2]="$(_pr_install_name awg1)"; fi
    # Галочка 3.1 — как её поставил экран подхвата: шаг «Линия на UDP 443» замыкает её, пока 3.1 выбрана на 443.
    w3_locked="${wz_locked[0]}"; w3_msg="${wz_lockmsg[0]}"

    # ── Прерванная установка — с того же места (INST-01, INST-02) ────────────
    # Запись ответов прошлого захода есть — что ответили и что уже стоит, одним экраном. Enter — дальше с вопроса,
    # на котором оборвалось (все ответы есть — сразу установка, уже стоящее не переставляется); 1 — вопросы заново
    # (прежние ответы — подсказкой, как при шаге назад); 0 — в меню, запись остаётся до следующего запуска.
    rs=$(_cfg '.wizard.step')
    if [ -n "$rs" ]; then
        _wz_resume_screen; lrc=$?
        case "$lrc" in
            0|1)
                _wz_load
                if [ "$lrc" = 1 ]; then
                    step=mode
                elif [ "$rs" = install ]; then
                    # Порты из записи ещё годятся — сразу к установке; нет — экран портов с прежними, где можно.
                    if _wz_resume_ports; then step=finished; else step=ports; fi
                else
                    case "$rs" in domain|line|profiles|ports) step="$rs" ;; *) step=mode ;; esac
                fi
                ;;
            3) _wz_stop_no_input; return 3 ;;
            *) return 1 ;;
        esac
    fi
    while [ "$step" != finished ]; do
        # Конец ввода на любом вопросе — остановка, а не «дальше с умолчаниями» (INST-02, сервер 168): уже данные
        # ответы — в запись .wizard, чтобы повторный запуск продолжил с этого же вопроса; ничего не ставится. Шаг
        # здесь — тот, на котором ввод кончился: вопросы при конце ввода шаг не меняют.
        if [ "$GA_INPUT_EOF" = 1 ]; then
            _wz_save "$step"
            _wz_stop_no_input
            return 3
        fi
        case "$step" in
        mode)
    # ── 1. Режим (PLAN §4.3, решение владельца §10 п.10 — три режима) ────────
    # Предполётная проверка портов ДО показа выбора (PLAN §4.3.1): режимы с
    # сайтом недоступны, пока TCP/80 или TCP/443 заняты чужим или закрыты
    # локальным файрволом. Недоступный режим показывается, но не выбирается:
    # объяснение то же, что на экране, плюс предложение открыть порт (ufw);
    # «4» повторяет проверку после того, как человек освободил порт. Цифры
    # совпадают с экраном preflight_render_modes: 1 — lite, 2 — lite_site, 3 — pro.
    # Без модуля — прежний список из трёх пунктов с пояснениями: выбор режима
    # определяет, что увидит снаружи сканер, и человек должен понимать разницу.
            pf=""
            if type preflight_modes >/dev/null 2>&1; then
                pf=$(preflight_modes 2>/dev/null) || pf=""
            fi
            # Порядок — договор 0.6.0 (docs/MODES_047.md): 1 Ленивый Pro, 2 Pro, 3 Semi-Pro, 4 Lite; «5» — повторить
            # проверку портов. Enter — Lite, как было: без домена человеку нужен именно он. Конец ввода — не Enter, а
            # остановка (INST-02).
            if [ -n "$pf" ]; then
                preflight_render_modes "$pf"
            else
                echo -e "  ${WHITE}$(t wz_mode_title)${NC}"
                echo -e "  ${CYAN}1${NC}) $(t wz_mode_lazy)"
                echo -e "     ${DIM}$(t wz_mode_lazy_desc)${NC}"
                echo -e "  ${CYAN}2${NC}) $(t wz_mode_pro)"
                echo -e "     ${DIM}$(t wz_mode_pro_desc)${NC}"
                echo -e "  ${CYAN}3${NC}) $(t wz_mode_lite_site)"
                echo -e "     ${DIM}$(t wz_mode_lite_site_desc)${NC}"
                echo -e "  ${CYAN}4${NC}) $(t wz_mode_lite)"
                echo -e "     ${DIM}$(t wz_mode_lite_desc)${NC}"
            fi
            echo -ne "  ${WHITE}$(t wz_mode_prompt):${NC} "
            if ! read -r ch; then echo ""; GA_INPUT_EOF=1; continue; fi
            case "$ch" in
                5) [ -n "$pf" ] && log_info "$(t preflight_rechecking)"; continue ;;
                0)   log_info "$(t wz_cancelled_hint)"; return 1 ;;
                4|"") mode="lite"; domain=""; step=profiles ;;
                1)
                    # Ленивый Pro: только домен, остальное — сценарий lib/modes.sh. Контейнеры приложения здесь уже
                    # предложил подхватить первый экран (OWN-1) — отказ человека уважаем (GA_MODES_ADOPT=0).
                    if ! _mode_available lazy "$pf"; then
                        _mode_blocked_explain lazy "$pf" || true
                        continue
                    fi
                    GA_MODES_ADOPT=0 _lazy_wizard; lrc=$?
                    case "$lrc" in
                        # Ленивый Pro довёл установку сам — запись ответов этого мастера (прошлый заход) больше не нужна.
                        0) _wz_clear; return 0 ;;
                        1) continue ;;
                        # Конец ввода на домене — та же остановка, что на любом вопросе (наверху цикла).
                        *) [ "$GA_INPUT_EOF" = 1 ] && continue; return 1 ;;
                    esac
                    ;;
                2|3)
                    pick="pro"; [ "$ch" = 3 ] && pick="lite_site"
                    if _mode_available "$pick" "$pf"; then
                        mode="$pick"; step=domain
                    else
                        # Закрыто только локально — открыть прямо здесь и проверить снова
                        _mode_blocked_explain "$pick" "$pf" || true
                    fi
                    ;;
                *)   log_error "$(t invalid_choice)" ;;
            esac
            ;;
        domain)
    # ── 2. Домен (оба режима с сайтом) ───────────────────────────────────────
    # Домен спрашивается и во втором режиме тоже: по уточнённому замыслу владельца
    # это домен, сайт-заглушка и панель на TCP/443 с настоящим сертификатом
    # Let's Encrypt, а AmneziaWG стоит на своём отдельном порту. Третий режим —
    # то же самое, но AmneziaWG на UDP/443 рядом с сайтом. Самоподписанный
    # сертификат остаётся ЗАПАСНЫМ путём: домена нет или A-запись ещё не
    # указывает сюда. Поэтому пустой ответ — не отказ: ставим сайт на запасном и
    # честно говорим, чего человек лишается и каким пунктом это исправить.
    # «0» — назад к выбору режима.
            # Вернулись к домену шагом назад — прежний ответ предлагается по Enter,
            # а не стирается пустым вводом.
            local prev_domain="$domain" dprompt
            [ -n "$prev_domain" ] || _domain_help
            if [ -n "$prev_domain" ]; then dprompt=$(tf wz_domain_ask_keep "$prev_domain"); else dprompt=$(t wz_domain_ask_wizard); fi
            # ga_capture, а не $( … ): отметка конца ввода (GA_INPUT_EOF) из подоболочки не дошла бы, и пустой ответ
            # оборванной сессии ушёл бы дальше как «без домена» (INST-02).
            ga_capture domain ga_ask_optional "$dprompt" \
                '^(0|([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,})$' \
                "$(t wz_domain_bad)" || domain=""
            if [ "$GA_INPUT_EOF" = 1 ]; then domain="$prev_domain"; continue; fi
            if [ "$domain" = 0 ]; then domain=""; step=mode; continue; fi
            [ -n "$domain" ] || domain="$prev_domain"
            # Нижний регистр: домен идёт в server_name, в путь сертификата и в
            # ключи, а pattern домена у моста принимает только строчные буквы.
            domain="${domain,,}"
            if [ -z "$domain" ]; then
                log_warning "$(ga_wrap "$(t ms_no_domain_fallback)" "${GA_UI_W:-76}" 4)"
            else
                # Сверяем A-записи с адресами машины (набором — их может быть
                # несколько). Не блокируем: DNS мог не разойтись — но человек должен
                # знать заранее, иначе Let's Encrypt откажет уже после установки
                # контейнеров.
                _site_dns_hint "$domain"
            fi
            if [ "$mode" = pro ]; then step=line; else step=profiles; fi
            ;;
        line)
    # ── 2а. Pro: какая линия AmneziaWG встанет на UDP 443 (LZ-11) ────────────
    # Раньше на 443 молча вставала 2.0. Экран — тот же, что «Режим и сайт → Линия на UDP 443»: 2.0 первой и
    # рекомендуем, Enter — 2.0; «0» — назад к домену. Выбирать не из чего (линия уже стоит) — 2.0, как было.
            if ! _wz_line_applicable; then
                # Выбирать не из чего — на 443 встаёт 2.0, на каком бы месте она ни встала: рядом с подхваченной 3.1
                # приложения в awg2 её место — awg3 (DUP-LINE-01; иначе в Pro UDP 443 не получал никто — находка проверки).
                _WZ_LINE443=awg2
                if _profile_installed awg2 && ! _profile_installed awg3 \
                        && [ "$(ga_profile_auto_line awg3 2>/dev/null)" = 2.0 ]; then
                    _WZ_LINE443=awg3
                fi
                step=profiles; continue
            fi
            if _wz_line_pick; then step=profiles
            elif [ "$GA_INPUT_EOF" = 1 ]; then continue
            else step=domain; fi
            ;;
        profiles)
    # ── 3. Профили ───────────────────────────────────────────────────────────
    # Порядок и умолчания — решение владельца 10.09.2026: сверху 3.1, затем 2.0,
    # затем 1.0/1.5; отмечены 3.1 и 2.0, 1.x — по желанию. У каждого одна строка
    # «кому он нужен»: без неё выбор из трёх линеек AmneziaWG — гадание.
    # 2.0 замкнут: это единственный контейнер, который видит официальное
    # приложение Amnezia, на нём же стоит первый пользователь (PLAN §10 п.1–2).
            # 3.1 выбрана на UDP 443 — её галочка отмечена и замкнута; выбор сменили — прежний замок экрана подхвата.
            if [ "$mode" = pro ] && [ "$_WZ_LINE443" = awg3 ] && [ "$(ga_profile_auto_line awg3 2>/dev/null)" = 3.1 ]; then
                wz_state[0]=1; wz_locked[0]=1; wz_lockmsg[0]="$(t wz_line_lock31)"
            else
                wz_locked[0]="$w3_locked"; wz_lockmsg[0]="$w3_msg"
            fi
            if _pick_checkboxes "$(t wz_profiles_title)" wz_labels wz_notes wz_state wz_locked \
                "$(t wz_awg2_always)" "$(t wz_pick_legend)" wz_lockmsg; then
                want_awg3="${wz_state[0]}"
                want_awg1="${wz_state[2]}"
                step=ports
            elif [ "$GA_INPUT_EOF" = 1 ]; then
                continue
            elif [ "$mode" = lite ]; then
                step=mode
            elif [ "$mode" = pro ] && _wz_line_applicable; then
                step=line
            else
                step=domain
            fi
            ;;
        ports)
    # ── 4. Порты всех выбранных профилей ─────────────────────────────────────
    # В третьем режиме порт 443/udp выглядит для DPI как QUIC рядом с настоящим
    # сайтом на 443/tcp (PLAN §4.4) — в этом и есть его отличие от второго. В
    # первом и втором AmneziaWG живёт на своём порту: случайный из низкого
    # диапазона 1024–9999 (_random_port, CONTRACT §2) или свой. «0 — назад» на
    # экране портов возвращает к галочкам профилей, а они помнят выбор.
            wz_profs=()
            [ "$want_awg3" = "1" ] && wz_profs+=(awg3)
            wz_profs+=(awg2)
            [ "$want_awg1" = "1" ] && wz_profs+=(awg1)
            if _wz_ports_step "$mode" "${wz_profs[@]}"; then step=finished
            elif [ "$GA_INPUT_EOF" = 1 ]; then continue
            else step=profiles; fi
            ;;
        esac
    done
    mode="$_WZ_MODE"
    port="${_WZ_PORT[awg2]}"

    # ── 5. DNS клиентов ──────────────────────────────────────────────────────
    # Вопрос убран (решение владельца 10.09.2026): на первой установке он ничего
    # не решает — человек ещё не знает, чем Cloudflare отличается от AdGuard, а
    # мастер и так длинный. Ставим Google и одной строкой говорим, где менять.
    dns1="8.8.8.8"; dns2="8.8.4.4"
    log_dim "$(ga_wrap "$(tf wz_dns_default "$dns1" "$dns2")" "${GA_UI_W:-76}" 2)"

    # ── 6. Ответы в конфиг ДО установки ──────────────────────────────────────
    # Ответы мастера — в запись .wizard до того, как трогаем Docker: если установка сорвётся (нет образа, занят
    # порт, оборвалась сессия), повторный запуск продолжит с того же места и опрос заново не начнёт (INST-01).
    # Режим и домен в mode и domain НЕ пишем: их пишет модуль сайта, когда сайт поднят (шаг 11). Прежде здесь
    # писался желаемый режим, и прерванная установка оставляла «Режим: Pro» в шапке меню при сайте, которого нет,
    # а миграция пересобирала vhost несуществующего сайта (INST-01, INST-03). Lite сайта не требует — его пишем
    # сразу, как раньше. IP сервера и DNS — тоже сразу: IP нужен start.sh контейнера и Endpoint ключей —
    # определяем один раз здесь, а не при каждой выдаче. Признак installed выставляем только после удачи.
    [ -n "${ip:-}" ] || ip=$(_server_ip)
    local ssh_ip=""
    # Адрес SSH-входа поправляет только догадку внешней службы (SR-42): явно заданный GOAMNEZIA_SERVER_IP
    # (стенд, установщик) главнее, и молча заменять его нельзя (TAIL-10).
    if [ -z "$(_cfg '.server_ip')" ] && [ -z "${GOAMNEZIA_SERVER_IP:-}" ]; then
        ssh_ip=$(_ssh_inbound_ip 2>/dev/null) || ssh_ip=""
        if [ -n "$ssh_ip" ] && [ "$ssh_ip" != "${ip:-}" ]; then
            log_dim "$(ga_wrap "$(tf wz_ip_from_ssh "$ssh_ip" "${ip:--}")" "${GA_UI_W:-76}" 2)"
            ip="$ssh_ip"
        fi
    fi
    if command -v jq >/dev/null 2>&1 && type ga_config_merge >/dev/null 2>&1; then
        cfg=$(jq -nc --arg v "$GOAMNEZIA_VERSION" --arg a "$dns1" --arg b "$dns2" --arg ip "${ip:-}" \
              '{version:$v, server_ip:$ip, client_dns: ([$a,$b] | map(select(. != "")))}') || cfg=""
        # Lite — режим без сайта: записать его сразу честно. Режим с сайтом, оставшийся от прерванной установки
        # прежней версии (она писала желаемый режим здесь же), при сайте, которого на сервере нет, — тоже Lite:
        # сайт поднимет шаг 11, и режим запишет он.
        if [ -n "$cfg" ] && { [ "$mode" = lite ] || { [ "$(_mode_current)" != lite ] && ! _ga_site_vhost_present; }; }; then
            if [ "$mode" = lite ]; then
                cfg=$(jq -c '. + {mode: "lite", domain: ""}' <<<"$cfg") || cfg=""
            else
                cfg=$(jq -c '. + {mode: "lite"}' <<<"$cfg") || cfg=""
            fi
        fi
        [ -n "$cfg" ] && ga_config_merge "$cfg"
        _wz_save install
    else
        log_error "$(tf module_missing ga_config_merge)"
    fi

    # ── 6а. Страж выбранных профилей ─────────────────────────────────────────
    # Подхват контейнеров приложения предложен первым экраном мастера (_wz_takeover_gate, OWN-1). Здесь —
    # только страховка на случай, если контейнер появился или изменился за время опроса: amnezia-awg2 (и
    # -awg3, -awg1) у приложения зовётся так же, как наш профиль, и установка на его месте удалила бы ключи
    # людей (она откажет кодом foreign_container). Без awg2 продукту не на чем стоять, а сносить чужое мы не
    # будем, поэтому мастер останавливается; необязательный профиль просто снимается с установки.
    local fc fn
    if type ga_amn_foreign_peers >/dev/null 2>&1; then
        for p in awg3 awg2 awg1; do
            case "$p" in awg3) [ "$want_awg3" = 1 ] || continue ;; awg1) [ "$want_awg1" = 1 ] || continue ;; esac
            _profile_installed "$p" && continue
            fc=$(ga_profile_default "$p" container)
            fn=$(ga_amn_foreign_peers "$fc" 2>/dev/null)
            [[ "$fn" =~ ^[0-9]+$ ]] && [ "$fn" -gt 0 ] || continue
            if [ "$p" = awg2 ]; then
                log_warning "$(ga_wrap "$(tf wz_adopt_declined_main "$p" "$fc")" "${GA_UI_W:-76}" 4)"
                return 1
            fi
            log_info "$(ga_wrap "$(tf wz_adopt_declined_optional "$p" "$fc")" "${GA_UI_W:-76}" 4)"
            case "$p" in awg3) want_awg3=0 ;; awg1) want_awg1=0 ;; esac
        done
    fi

    # ── 7. Docker и сеть ─────────────────────────────────────────────────────
    # qrencode — необязательная зависимость (профиль qr в lib/deps.sh), но без
    # него мастер не покажет QR в конце, а user-key --format=all откажет.
    if type deps_install_missing >/dev/null 2>&1 && [ "${GOAMNEZIA_DRY_RUN:-0}" != "1" ]; then
        deps_install_missing --yes qr >&2 || true
    fi
    # Номер шага из общего числа + ожидаемое время + счётчик секунд у спиннера:
    # установка Docker и первая загрузка образа идут минутами, и раньше это была
    # молчащая точка, по которой нельзя было понять, идёт что-то или зависло.
    # Шагов столько, сколько профилей ставится на самом деле: уже стоящие
    # (повтор мастера) пропускаются, и счётчик не должен обещать лишний шаг.
    GA_STEP_N=2
    for p in awg3 awg2 awg1; do
        case "$p" in awg3) [ "$want_awg3" = 1 ] || continue ;; awg1) [ "$want_awg1" = 1 ] || continue ;; esac
        _profile_installed "$p" || GA_STEP_N=$((GA_STEP_N + 1))
    done
    GA_STEP_I=0
    if type docker_ensure_installed >/dev/null 2>&1; then
        ga_step "$(t wz_docker)" "$(t wz_docker_done)" "$(t eta_docker)" docker_ensure_installed \
            || { GA_STEP_N=0; log_info "$(_ui_w "$(t wz_unfinished_hint)")"; return 1; }
    else
        log_error "$(tf module_missing docker_ensure_installed)"; GA_STEP_N=0; return 1
    fi
    if type docker_ensure_network >/dev/null 2>&1; then
        ga_step "$(t wz_network)" "$(t wz_network_done)" "" docker_ensure_network \
            || { GA_STEP_N=0; log_info "$(_ui_w "$(t wz_unfinished_hint)")"; return 1; }
    fi

    # ── 8. Профили ───────────────────────────────────────────────────────────
    if ! type amnezia_profile_install >/dev/null 2>&1; then
        log_error "$(tf module_missing amnezia_profile_install)"; return 1
    fi
    # Порядок установки — как везде: 3.1, затем 2.0, затем 1.x. Порты розданы
    # на шаге 4, все разные. Профиль, который уже стоит (прошлый заход мастера, подхват, вторая установка успела
    # раньше), не переставляется: «уже стоит — оставляю», лежит — поднимается из копии состояния (_wz_profile_ensure).
    # Прежде на сервере 168 awg2 появился между проверкой и установкой, и «Профиль awg2 уже установлен» обрывал
    # мастер на шаге профилей — без сайта, сертификата и панели (INST-01). Не встал awg2 — дальше не идём: запись
    # ответов остаётся, повторный запуск продолжит с этого шага.
    if [ "$want_awg3" = "1" ]; then
        _wz_profile_ensure awg3 "${_WZ_PORT[awg3]:-}" || true
    fi
    if ! _wz_profile_ensure awg2 "$port"; then
        GA_STEP_N=0
        log_info "$(_ui_w "$(t wz_unfinished_hint)")"
        return 1
    fi
    if [ "$want_awg1" = "1" ]; then
        _wz_profile_ensure awg1 "${_WZ_PORT[awg1]:-}" || true
    fi
    GA_STEP_N=0

    # ── 9. Установка состоялась ──────────────────────────────────────────────
    # installed=true = «мастер дошёл до конца»: по этому полю main() решает,
    # показывать меню или снова мастер, а миграция — есть ли что мигрировать.
    if type ga_config_merge >/dev/null 2>&1; then
        ga_config_merge '{"installed":true}' || true
    fi
    # Таймеры продукта (лимиты, сторож, статистика, проверка обновлений,
    # бэкап по умолчанию, бюджет логов) — сразу, как только есть что сторожить.
    _timers_apply

    # ── 10. Первый пользователь ──────────────────────────────────────────────
    # Имя admin бывает уже занято человеком, подхваченным из приложения (у него на сервере нет приватного
    # ключа): отказ user_exists глотался, и ключа в конце мастера не было вовсе (находка В7 плана перехвата).
    # Тогда первый пользователь — admin-ga. Профили — все стоящие, кроме подхваченного старого 1.x (контейнер
    # на образе amnezia-wg): первая запись в него — только когда владелец сам выдаст там ключ.
    # Повторный заход после обрыва (INST-01): первый пользователь, заведённый прошлым заходом, остаётся тем же —
    # раньше «admin уже есть» читалось как «подхвачен из приложения», и заводился лишний admin-ga. Свой —
    # записан в .wizard.admin или (прерванная установка прежней версии) admin с ключом на сервере.
    local admin_name="admin" admin_profiles="" ap admin_new=1 admin_was
    admin_was=$(_cfg '.wizard.admin')
    if type users_exists >/dev/null 2>&1; then
        if [ -n "$admin_was" ] && users_exists "$admin_was" 2>/dev/null; then
            admin_name="$admin_was"; admin_new=0
        elif users_exists admin 2>/dev/null; then
            if _user_has_private_key admin; then
                admin_new=0
            else
                admin_name="admin-ga"
                log_info "$(_ui_w "$(tf wz_admin_name_taken admin "$admin_name")")"
                users_exists "$admin_name" 2>/dev/null && admin_new=0
            fi
        fi
    fi
    for ap in awg3 awg2 awg1; do
        _profile_installed "$ap" || continue
        [ "$(_cfg ".profiles.$ap.iface")" = wg0 ] && continue
        admin_profiles="${admin_profiles:+$admin_profiles,}$ap"
    done
    if [ "$admin_new" = 0 ]; then
        log_dim "$(_ui_w "$(tf wz_admin_kept "$admin_name")")"
    elif type users_add >/dev/null 2>&1; then
        ga_step "$(t wz_first_user)" "$(t wz_first_user_done)" "" users_add "$admin_name" "$(t wz_admin_label)" "$admin_profiles" || true
    else
        log_error "$(tf module_missing users_add)"
    fi
    # Кто первый пользователь — в запись ответов: оборвётся дальше (сайт, панель) — следующий заход его не задвоит.
    if _wz_pending && type users_exists >/dev/null 2>&1 && users_exists "$admin_name" 2>/dev/null; then
        ga_config_merge "$(jq -nc --arg a "$admin_name" '{wizard: {admin: $a}}')" >/dev/null 2>&1 || true
    fi

    # ── 11. Сайт: один путь на оба режима с сайтом ───────────────────────────
    # Не под спиннером: certbot идёт до минуты и сам объясняет, зачем нужен
    # открытый порт 80; случайный шаблон модуль разворачивает сам. Основной путь —
    # домен и Let's Encrypt; запасной (домена нет или A-запись ещё не разошлась) —
    # самоподписанный, о чём _site_bring_up говорит вслух. Сайт не поднялся вовсе
    # → сервер честно остаётся в Lite (режим пишет модуль сайта только при удаче),
    # домен сохранён здесь, повтор из «Настройки → Режим и сайт» его не спрашивает.
    # Сайт, уже поднятый прошлым заходом (оборвалось на боте или панели), — тот же
    # вызов: повтор в том же режиме — ремонт, живой сертификат не перевыпускается.
    case "$mode" in
        pro|lite_site)
            if type website_enable_pro >/dev/null 2>&1; then
                if ! _site_bring_up "$mode" "$domain" 1 && type ga_config_merge >/dev/null 2>&1; then
                    ga_config_merge "$(jq -nc --arg d "$domain" '{mode: "lite"} + (if $d != "" then {domain: $d} else {} end)')" \
                        >/dev/null 2>&1 || true
                fi
            else
                log_error "$(tf module_missing website_enable_pro)"
            fi
            ;;
    esac

    # ── 12. Бот и панель (docs/BOT.md §4, docs/PANEL.md §4) ──────────────────
    # Предложение, а не обязательный шаг: боту нужны токен от @BotFather и
    # Telegram ID, которых у человека может ещё не быть; панель без бота тоже
    # работает (вход через SSH-туннель). Оба ставятся своими установщиками из
    # эталонного каталога — теми же, что зовут пункты меню, поэтому повтор
    # позже ничего не ломает. Отказ — подсказка, где это находится в меню.
    # Бот уже стоит (прошлый заход мастера дошёл до него) — второй раз не предлагаем. Конец ввода здесь — «нет»:
    # всё, о чём человек просил, уже поставлено, а бот — только предложение.
    echo ""
    if [ -f "$SCRIPT_DIR/goamnezia-bot/install_bot.sh" ] && [ ! -f "$BOT_DIR/.env" ]; then
        if confirm "$(t wz_bot_ask)"; then
            _bot_install_interactive || true
        else
            log_dim "$(t wz_bot_skipped_hint)"
        fi
    fi
    # Панель на ДОМЕНЕ С НАСТОЯЩИМ СЕРТИФИКАТОМ включается сама вместе с сайтом (решения владельца 10.09 и
    # 17.09.2026): службу уже поставил подъём сайта (_panel_ensure_service), здесь — повтор на случай, если сайт
    # поднимали не через него (находка T6). Без домена (первый режим, запасной самоподписанный) панель тоже
    # ставится — для SSH-туннеля, молча и без пароля (NC-13): раньше здесь была строка «откройте через туннель»,
    # а туннелю открывать было нечего. Как открыть — строкой в конце мастера, рядом с ключом.
    if [ -f "$SCRIPT_DIR/admin-web/install_admin.sh" ]; then
        if _site_domain_ready && [ -n "$(_cfg '.panel.miniapp_path')" ]; then
            _panel_ensure_service || true
        else
            _panel_ensure_local || true
        fi
    fi

    # Установка закончена: запись ответов больше не нужна (следующий запуск — меню), замок мастера снят до показа
    # ключа — «Что дальше» может оставить жить процессы (временная ссылка), а второй мастер ждать нечего.
    _wz_clear
    _wz_unlock

    # ── 13. Ключ администратора ──────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}${GREEN}$(t wz_done)${NC}"
    echo -e "  ${DIM}$(_rule)${NC}"
    local qr_ok=0 kp
    GA_QR_WHY=""
    # Ключ — самого сильного профиля, что стоит: 3.1, если он есть, иначе 2.0. Раньше мастер первым показывал 2.0, а
    # совет везде говорил «берите 3.1» (находка NC-27; рекомендуемое приложение AmneziaWG читает 3.1).
    # По линии, а не по месту: подхваченный из приложения amnezia-awg2 держит 3.1 (AWG31-01).
    kp=$(_profile_31_first "$admin_profiles")
    [ -n "$kp" ] || kp=awg2
    if type export_conf >/dev/null 2>&1; then
        local conf link
        # В текущей оболочке, а не в $( … ) с глушением: не собрался ключ (сервер не знает своего адреса — нет
        # сети при установке) — мастер заканчивался без ключа и без слова о причине (находка SR-49).
        GA_ERR_CODE=""; GA_ERR_MSG=""
        if ! ga_capture conf export_conf "$admin_name" "$kp" 2>/dev/null; then
            conf=""
            log_error "$(_ui_w "${GA_ERR_MSG:-$(t key_failed)}")"
        fi
        if [ -n "$conf" ]; then
            # Выдача ключа первому пользователю — в журнал действий, как любая выдача (находка SR-03).
            type ga_export_audit_key >/dev/null 2>&1 && ga_export_audit_key "$admin_name" "$kp" wizard
            echo -e "  ${BOLD}${WHITE}$(tf key_title_conf "$admin_name" "$(_pr_name "$kp")")${NC}"
            # Не влез в окно — конфиг текстом больше не вываливаем: двадцать пять строк с приватным ключом телефону
            # не помогут. Ключ текстом есть и так (vpn:// ниже), а как перенести его на телефон — сразу пунктами
            # после ключа (_key_next_steps, NC-05). Подпись «этот QR читают…» — только над настоящим QR (NC-27).
            _key_conf_qr "$conf" "$kp" && qr_ok=1
            conf=""
        fi
        if type export_vpn >/dev/null 2>&1; then
            link=$(export_vpn "$admin_name" "$kp" 2>/dev/null) || link=""
            if [ -n "$link" ]; then
                echo ""
                echo -e "  ${BOLD}${WHITE}$(t wz_link)${NC}"
                _key_min_client "$kp" vpn
                echo -e "  ${GREEN}${link}${NC}"
            fi
        fi
        # Ключ 3.1 и рядом стоит 2.0 — где взять запасной, если приложение 3.1 не прочтёт
        # По линиям, а не по местам: ключ 3.1 бывает в awg2, запасной 2.0 — в awg3 (AWG31-01).
        if [ "$(_profile_line "$kp" 2>/dev/null)" = 3.1 ]; then
            local _wz_p _wz_20=""
            for _wz_p in ${admin_profiles//,/ }; do [ "$(_profile_line "$_wz_p" 2>/dev/null)" = 2.0 ] && _wz_20=1; done
            [ -n "$_wz_20" ] && log_info "$(tf wz_key_31_note "$admin_name")"
        fi
    fi
    echo -e "  ${DIM}$(_rule)${NC}"
    # Несколько внешних адресов у машины — сказать, что ключ можно выдать на любой (docs/EDGEIPS.md §3.4).
    # Счёт — отдельно от запасного нуля: у `grep -c .` без строк и вывод «0», и код 1, и прежнее «… || echo 0»
    # давало «0\n0» и «[: integer expected» в конце мастера на машине без внешних адресов.
    local nips=0
    if type ga_edge_list >/dev/null 2>&1; then nips=$(ga_edge_list 2>/dev/null | grep -c .) || true; fi
    [[ "$nips" =~ ^[0-9]+$ ]] || nips=0
    [ "$nips" -ge 2 ] && log_info "$(tf wz_key_other_addresses "$nips")"
    # Веб-панель — в любом режиме через SSH-туннель, без пароля (NC-13): её поставил шаг 12.
    if _panel_present; then
        echo ""
        _panel_tunnel_hint
    fi
    # Соседи профилей и goWARP PRO после «Удалить всё»: кто вернулся в сеть новых контейнеров, кого вернуть руками, где
    # снова включить WARP (WRP-06). Шаги установки шли под спиннером — здесь их итог.
    type ga_amn_install_notes >/dev/null 2>&1 && ga_amn_install_notes
    # Раньше возврат в меню чистил экран вместе с историей прокрутки, и ключ
    # исчезал безвозвратно. Историю мы больше не режем, но сказать, где взять
    # ключ снова, всё равно надо: человек не обязан знать путь в меню.
    log_info "$(t wz_key_again_hint)"
    # Человек, который ставит VPN «для семьи», дальше идёт раздавать ключи — и
    # не знает, где это (замечание критика UX: «главного для меня нет»).
    log_info "$(t wz_people_hint)"
    # Что дальше — вместо «Нажмите Enter»: Enter по-прежнему ведёт в меню. Проверка подключения — только по просьбе
    # (NC-05); QR не влез — первыми идут пути, как перенести ключ на телефон.
    _key_next_steps "$admin_name" "$kp" "$qr_ok" "$(t kn_done_menu)"
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# Обновление: миграции состояния и рабочих копий компонентов
# ══════════════════════════════════════════════════════════════════════════════

# _ver_lt A B → 0, если A строго меньше B (semver-ish, через sort -V).
_ver_lt() {
    [ "$1" = "$2" ] && return 1
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V 2>/dev/null | head -1)" = "$1" ]
}

# _ga_mark_write <файл> <значение> — отметка обновления (снимок снят, миграция прошла, «Что нового») целиком или
# никак: ga_write_file (времянка, сверка, fsync, rename). Голое `printf >отметка` при кончившемся месте
# оставляло пустой файл — на C1 так обнулилась отметка миграции (находка OPS-04). Не записалась — прежняя
# отметка цела, человеку сказано почему, код 1: миграция тогда повторится при следующем вызове (шаги
# идемпотентны), а не сочтёт себя сделанной.
_ga_mark_write() {
    local f="$1" v="${2-}" body=""
    [ -n "$v" ] && body="$v"$'\n'
    if type ga_write_file >/dev/null 2>&1; then
        ga_write_file "$f" "$body" 600 && return 0
        log_warning "${GA_ERR_MSG:-$(tf ops_write_failed "$f")}"
        return 1
    fi
    { printf '%s' "$body" >"$f"; } 2>/dev/null && return 0
    log_warning "$(tf ops_write_failed "$f")"
    return 1
}

# Снимок состояния до миграции. Нет бэкапа — нет миграции: без этого правила
# провалившийся tar проглатывается, конфиг переписывается, а откатываться не с
# чего (грабли goTelegram 2.7).
snapshot_preupgrade_state() {
    local marker="$GOAMNEZIA_DIR/.preupgrade_${GOAMNEZIA_VERSION}_done" snap=""
    [ -f "$marker" ] && return 0

    if type create_backup >/dev/null 2>&1; then
        # Место — по размеру данных (режим data), а не общим порогом 512 МБ: на маленьком VPS миграция иначе
        # не проходила никогда (находка UP-1). В текущей оболочке (ga_capture), а не в $( … ) с глушением:
        # причина отказа (битый users.json, место) доходит до человека, а не «освободите место» на любую
        # (SR-31). Путь снимка называем — миграция обещает снимок (LC-17). kind=preupgrade — в карточке копии.
        GA_ERR_CODE=""; GA_ERR_MSG=""
        if GA_BACKUP_KIND=preupgrade ga_capture snap create_backup "" "$BACKUP_DIR" data 2>/dev/null; then
            snap=$(printf '%s' "$snap" | tail -n 1)
            # В отметке — путь снимка: из него откат неудачного обновления возвращает данные (OPS-02).
            _ga_mark_write "$marker" "$snap" || return 1
            [ -n "$snap" ] && log_dim "$(tf mig_snapshot "$snap")"
            return 0
        fi
        log_error "$(tf mig_backup_failed_why "${GA_ERR_MSG:-$(t act_failed)}")"
        return 1
    fi

    # lib/backup.sh ещё не установлен (или обрезанная установка) — делаем
    # минимальный снимок сами: конфиг, пользователи, состояние контейнеров.
    local ts archive
    ts=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    chmod 700 "$BACKUP_DIR" 2>/dev/null || true
    archive="$BACKUP_DIR/preupgrade_${GOAMNEZIA_VERSION}_${ts}.tar.gz"
    local items=()
    [ -f "$CONFIG_FILE" ] && items+=("$(basename "$CONFIG_FILE")")
    [ -f "$USERS_FILE" ]  && items+=("$(basename "$USERS_FILE")")
    [ -d "$STATE_DIR" ]   && items+=("$(basename "$STATE_DIR")")
    if [ "${#items[@]}" -eq 0 ]; then
        _ga_mark_write "$marker" "" || return 1
        return 0
    fi
    # -s: tar может «успешно» создать пустой архив при нехватке места.
    if ( umask 077; tar czf "$archive" -C "$GOAMNEZIA_DIR" "${items[@]}" 2>/dev/null ) && [ -s "$archive" ]; then
        chmod 600 "$archive" 2>/dev/null || true
        _ga_mark_write "$marker" "$archive" || return 1
        log_dim "$(tf mig_snapshot "$archive")"
        return 0
    fi
    rm -f "$archive" 2>/dev/null
    log_error "$(t mig_backup_failed)"
    return 1
}

# Пара fn()/_fn_locked() по CONTRACT §0.4: аргументов у миграции нет, но
# замок нужен — иначе она столкнётся с записью из бота или таймера.
auto_migrate_state() {
    if type ga_with_config_lock >/dev/null 2>&1; then
        ga_with_config_lock _auto_migrate_state_locked
    else
        _auto_migrate_state_locked
    fi
}

# Миграция — одно целое (находка OPS-03). Версия в config.json, отметка .migrated_<v> и «Что нового» ставятся
# только ПОСЛЕ всех шагов. Раньше версия поднималась первой, и миграция, оборванная посередине (упал шаг,
# оборвалась SSH-сессия, перезагрузка), при следующем вызове (тик сторожа) уходила в ветку «та же версия»:
# отметка ставилась без оставшихся шагов (причины выключения, отметка установки, юниты, vhost, изоляция) и без
# «Что нового». Теперь начатая миграция оставляет .migrating_<v> (с какой версии и где снимок), и следующий
# вызов — меню, бот или тик — доделывает её целиком: шаги идемпотентны, снимок второй раз не снимается.
#
# Обновление с прежним кодом рядом (bootstrap.sh положил его в .prev_code — lib/update.sh, находка OPS-02) —
# под защитой отката: снимок данных не снялся, шаг упал, версия не записалась или новый код не отвечает на
# status — прежний код, данные из снимка preupgrade, юниты и .install-source возвращаются (ga_upd_rollback), а
# вызывающий отдаёт тот же вызов прежнему коду (_ga_after_update_rollback). Прошло — снимок кода убирается.
_auto_migrate_state_locked() {
    local marker="$GOAMNEZIA_DIR/.migrated_${GOAMNEZIA_VERSION}"
    local wip="$GOAMNEZIA_DIR/.migrating_${GOAMNEZIA_VERSION}"
    local pmark="$GOAMNEZIA_DIR/.preupgrade_${GOAMNEZIA_VERSION}_done"
    local current from="" fp resume=0 archive="" txn=0 disk_ver=""
    # Код на диске — уже не тот, что в памяти: обновление откатил соседний процесс (тик, бот), пока этот ждал
    # замка, или загрузчик положил другую версию. Мигрировать данные кодом, которого на диске больше нет, нельзя —
    # тот же вызов отдаётся коду с диска (_ga_after_update_rollback).
    disk_ver=$(sed -n -E 's/^GOAMNEZIA_VERSION="([0-9][0-9A-Za-z.+-]*)".*/\1/p' "$LIB_DIR/common.sh" 2>/dev/null) || disk_ver=""
    disk_ver="${disk_ver%%$'\n'*}"
    if [ -n "$disk_ver" ] && [ "$disk_ver" != "$GOAMNEZIA_VERSION" ]; then
        GA_CODE_MOVED=1
        return 1
    fi
    current=$(_cfg '.version')
    fp=$(_ga_code_fingerprint)
    [ -f "$wip" ] && resume=1
    type ga_upd_pending >/dev/null 2>&1 && ga_upd_pending && txn=1

    # Чистая установка той же версии — мигрировать нечего. Маркер ставим сразу:
    # без него человек при каждом заходе видел бы «Миграция состояния…» и лишний
    # архив падал бы на диск (грабли goTelegram).
    if [ "$resume" = 0 ] && [ "$current" = "$GOAMNEZIA_VERSION" ] && [ -f "$CONFIG_FILE" ] && [ -z "${MIGRATED_FROM:-}" ]; then
        # Код на диске сменился с прошлой миграции при той же версии — обновление легло не целиком, пока
        # тикал таймер (bootstrap кладёт файлы по одному, а миграцию выполняет первый же тик): она прошла на
        # смеси старых и новых файлов, и vhost с юнитами остались от старого кода навсегда (находка UP-7).
        # Или новый код той же версии (загрузчик положил его с прежним рядом). Идемпотентные шаги, зависящие от
        # кода, — ещё раз. Не дошли до конца — отметка прежняя, и следующий вызов повторит их.
        if { [ -f "$marker" ] && [ -n "$fp" ] && [ "$(head -c 128 "$marker" 2>/dev/null | tr -cd '0-9a-f')" != "$fp" ]; } \
           || [ "$txn" = 1 ]; then
            if ! _ga_migrate_run reapply; then
                [ "$txn" = 1 ] && { ga_upd_rollback migration ""; return 1; }
                log_error "$(tf ops_mig_unfinished "$GOAMNEZIA_VERSION")"
                return 1
            fi
            if [ "$txn" = 1 ] && ! ga_upd_check; then
                ga_upd_rollback check ""
                return 1
            fi
        fi
        # Отметки — только когда их нет или отпечаток другой: сюда приходит каждый пишущий вызов моста (тик
        # сторожа раз в две минуты), и переписывать одно и то же незачем.
        [ -f "$pmark" ] || _ga_mark_write "$pmark" ""
        if [ ! -f "$marker" ] || [ "$(head -c 128 "$marker" 2>/dev/null | tr -cd '0-9a-f')" != "$fp" ]; then
            _ga_mark_write "$marker" "$fp"
        fi
        [ "$txn" = 1 ] && ga_upd_commit
        return 0
    fi
    [ "$resume" = 0 ] && [ -f "$marker" ] && [ "$current" = "$GOAMNEZIA_VERSION" ] && return 0

    # Гейт строго по config.json: он пишется в самом конце установки, то есть
    # означает «установка когда-то дошла до конца». Без него это первый запуск,
    # и мигрировать нечего — им займётся мастер.
    [ -f "$CONFIG_FILE" ] || return 0

    [ -n "$current" ] && [ "$current" != "$GOAMNEZIA_VERSION" ] && from="$current"
    # Доделываем начатое: с какой версии шла миграция и где её снимок — из отметки начала (она пишется до
    # первого шага; config.json хранит прежнюю версию, пока миграция не дойдёт до конца).
    if [ "$resume" = 1 ]; then
        from=$(_ga_kv "$wip" from | tr -cd '0-9A-Za-z.+-')
        archive=$(_ga_kv "$wip" archive)
    fi

    # Откат: код МЛАДШЕ состояния — сервер переехал на ветку с версией ниже (dev → main, «Обновить goAmnezia»,
    # goInstaller, однострочник). Отметки прежних снимков тут не указ: снимок этой версии мог сниматься при прошлом
    # обновлении на неё, и откат прошёл бы вовсе без снимка, а следующее обновление вверх — тоже. Поэтому отметки
    # снимков снимаются, и снимок делается сейчас (кроме повтора оборванной миграции: её снимок уже снят).
    # «Что нового» не показываем: это возврат, а не обновление, — экран «Обновление 0.5.1 → 0.5.0» врал бы
    # (сообщение об откате — ниже, после удавшейся миграции).
    local rollback=0
    if [ -n "$from" ] && _ver_lt "$GOAMNEZIA_VERSION" "$from"; then
        rollback=1
        [ "$resume" = 1 ] || rm -f "$GOAMNEZIA_DIR"/.preupgrade_*_done 2>/dev/null || true
    fi

    log_step "$(t mig_title)"
    [ "$resume" = 1 ] && log_info "$(tf ops_mig_resume "${from:-?}" "$GOAMNEZIA_VERSION")"
    # План — сообщением, без вопроса. Вопрос держал общий замок, пока человек думал: бот, панель, MCP и
    # таймеры получали lock_timeout, а «нет» отменяло миграцию лишь на словах — через две минуты её молча
    # проводил тик сторожа, «Что нового» показывалось дважды (находки SR-04, UP-9). Код уже новый, отказ
    # ничего не откатывал: миграция обязательна и безопасна — сначала снимок, ключи и люди не трогаются.
    if [ -t 0 ] || { : < /dev/tty; } 2>/dev/null; then
        echo "" >&2
        echo -e "  ${DIM}• $(t mig_plan_keep)${NC}"   >&2
        echo -e "  ${DIM}• $(t mig_plan_upd)${NC}"    >&2
        echo -e "  ${DIM}• $(t mig_plan_backup)${NC}" >&2
    fi

    # Снимка нет — нет и миграции (данные не тронуты). При обновлении с прежним кодом рядом — он и обратно:
    # прежний код с прежними данными лучше нового кода без миграции (OPS-02).
    if ! snapshot_preupgrade_state; then
        [ "$txn" = 1 ] && ga_upd_rollback snapshot ""
        return 1
    fi
    [ -n "$archive" ] || archive=$(head -n 1 "$pmark" 2>/dev/null)
    # Юниты systemd — как до миграции: откат вернёт их прежними (новая версия могла завести свои).
    [ "$txn" = 1 ] && { ga_upd_units_snapshot || log_warning "$(t ops_upd_units_snapshot_failed)"; }
    # Отметка начала — до первого шага: без неё оборванная миграция не узнала бы себя при следующем вызове.
    if [ "$resume" = 0 ] && ! _ga_mark_write "$wip" "$(printf 'from=%s\narchive=%s\nstarted=%s' "$from" "$archive" "$(ga_now)")"; then
        [ "$txn" = 1 ] && ga_upd_rollback record "$archive"
        return 1
    fi

    # Схема данных с версии 0.1.0 одна (schema 1), переносить пока нечего. Сюда же добавляются шаги вида
    # `_ver_lt "$from" "0.2.0" && …` — в _ga_migrate_steps.
    if ! _ga_migrate_run full "$from"; then
        [ "$txn" = 1 ] && { ga_upd_rollback migration "$archive"; return 1; }
        log_error "$(tf ops_mig_unfinished "$GOAMNEZIA_VERSION")"
        return 1
    fi
    # Версия — только когда все шаги прошли: иначе следующий вызов счёл бы миграцию сделанной (OPS-03).
    if command -v jq >/dev/null 2>&1 && type ga_config_merge >/dev/null 2>&1 \
       && ! ga_config_merge "$(jq -nc --arg v "$GOAMNEZIA_VERSION" '{version:$v}')" >/dev/null; then
        [ "$txn" = 1 ] && { ga_upd_rollback record "$archive"; return 1; }
        log_error "$(tf ops_mig_unfinished "$GOAMNEZIA_VERSION")"
        return 1
    fi
    # Первый запуск нового кода: он обязан ответить на status, как спросит бот или панель. Упал — откат.
    if [ "$txn" = 1 ] && ! ga_upd_check; then
        ga_upd_rollback check "$archive"
        return 1
    fi
    # Отметка не записалась (место) — отметка начала остаётся, и следующий вызов повторит шаги (они
    # идемпотентны) и запишет её снова.
    _ga_mark_write "$marker" "$fp" && rm -f "$wip" 2>/dev/null
    [ "$txn" = 1 ] && ga_upd_commit
    # «Что нового» — только после УДАВШЕЙСЯ миграции: раньше отметка писалась до снимка, и сорвавшаяся
    # миграция (место, битый файл) показывала экран при каждом входе, а тик сторожа писал его снова (UP-1,
    # UP-9). Видит человек при первом входе в меню, кто бы миграцию ни провёл: её часто проводит тик таймера
    # (мост), и экран иначе не показывался никогда (находка LC-03).
    if [ "$rollback" = 1 ]; then
        rm -f "$GOAMNEZIA_DIR/.changelog_pending" 2>/dev/null || true
        log_dim "$(tf mig_rollback "$from" "$GOAMNEZIA_VERSION")"
    elif [ -n "$from" ]; then
        MIGRATED_FROM="$from"
        _ga_mark_write "$GOAMNEZIA_DIR/.changelog_pending" "$from"
    fi
    return 0
}

# _ga_kv <файл> <ключ> → значение первой строки «ключ=значение» (отметка начала миграции).
_ga_kv() {
    local line
    line=$(grep -m1 -- "^$2=" "$1" 2>/dev/null) || return 1
    printf '%s' "${line#*=}"
}

# _ga_migrate_steps <с какой версии> — шаги миграции. Каждый идемпотентен: повтор после обрыва (OPS-03)
# ничего не портит и не удваивает.
_ga_migrate_steps() {
    local from="${1:-}"
    _migrate_profile_line
    _migrate_state_conf
    _migrate_disabled_reason
    _migrate_mark_installed
    # Юниты и таймеры новой версии (тексты могли измениться) — идемпотентно.
    _timers_apply
    _migrate_site_vhost
    # Изоляция клиентов профилей — с 0.4.6; сообщение — только при переходе через эту версию.
    if [ -n "$from" ] && _ver_lt "$from" "0.4.6"; then _migrate_client_isolation; else _migrate_client_isolation quiet; fi
    _migrate_isolation_watch
    _migrate_panel_legacy_key
    _migrate_server_mtu
    _migrate_netdeps_dangling
    _migrate_kmod
    _migrate_i1_universal
    _migrate_dupline
    return 0
}

# _ga_migrate_reapply — шаги, зависящие от кода, при той же версии (UP-7).
_ga_migrate_reapply() {
    _timers_apply
    _migrate_site_vhost reapply
    _migrate_client_isolation quiet
    _migrate_state_conf
    _migrate_isolation_watch
    # Серверы, получившие 0.6.0 раньше этого шага, идут сюда (код сменился при той же версии) — и тоже без старого ключа.
    _migrate_panel_legacy_key
    _migrate_server_mtu
    _migrate_netdeps_dangling
    _migrate_kmod
    _migrate_i1_universal
    _migrate_dupline
    return 0
}

# Ошибка прошлых версий (DUP-LINE-01, решение владельца 15.10): рядом с подхваченной у приложения 3.1 «Установить»
# ставило вторую 3.1, и 2.0 на сервере не было. Миграция только находит такое состояние и ставит флаг (и одно
# событие для бота) — исправляет человек: «Исправить» в сообщении SSH, на Обзоре панели или в боте. Идемпотентно.
_migrate_dupline() {
    type ga_amn_dupline_mark >/dev/null 2>&1 || return 0
    ga_amn_dupline_mark >/dev/null 2>&1 || true
    return 0
}

# Модуль ядра AmneziaWG (lib/kmod.sh, KMOD_PLAN Б13): хуки нового ядра — текстом этой версии, профили без файла engine —
# за выбранным движком. Движок молча не меняется; пересборку под метку нового набора начнёт сторож отдельной службой —
# обновление её не ждёт. Модулем не занимались — ничего.
_migrate_kmod() {
    type ga_kmod_after_update >/dev/null 2>&1 || return 0
    ga_kmod_after_update || true
    return 0
}

# Соседи в сети контейнера, которого больше нет (WRP-01): профиль пересоздан версией до 29.09.2026, и сосед (warp-socks
# рядом с goWARP) остался в пустой сети — прокси молчит. Вернуть его сами не можем: прежний ID нигде не записан, а
# гадать, чьим он был, нельзя. Называем, чтобы человек пересоздал его один раз; дальше продукт переподключает сам.
_migrate_netdeps_dangling() {
    type docker_netdeps_dangling >/dev/null 2>&1 || return 0
    ga_dry || command -v docker >/dev/null 2>&1 || return 0
    local names
    names=$(docker_netdeps_dangling 2>/dev/null | sort -u | paste -sd, - 2>/dev/null)
    [ -n "$names" ] || return 0
    log_warning "$(tf mig_netdeps_dangling "$names")"
    return 0
}

# MTU профиля — в конфиг сервера (жалоба 29.09.2026): прежние версии писали его только в клиентские конфиги, а
# строку MTU подхваченного конфига теряли при первой пересборке — интерфейс шёл с 1420 при 1360 в настройках.
# Профилям, у которых строка в копии конфига расходится с настройкой, конфиг пересобирается (с тем же набором пиров)
# и MTU ставится на живой интерфейс без перезапуска. Идемпотентно: сошлось — ничего не пишется.
_migrate_server_mtu() {
    type ga_amn_mtu_sync_all >/dev/null 2>&1 || return 0
    local fixed
    fixed=$(ga_amn_mtu_sync_all 2>/dev/null) || return 0
    [ -n "$fixed" ] || return 0
    log_dim "$(tf mig_server_mtu "$(printf '%s' "$fixed" | tr '\n' ' ' | sed 's/ *$//')")"
    return 0
}

# I1 по умолчанию прежних версий (<r 2><b 0x…>, KEENETIC-I1, 29.10): KeeneticOS 5.1 не принимает ключ, где сигнатурный
# пакет начинается не с <b>. Профилям, у которых I1 ровно прежнее умолчание, — универсальный <b 0x{ID}{DNS-ответ}> тем
# же путём, что клиентский параметр через profile-set-param (lib/amnezia.sh ga_amn_i1_universal): без рестарта и
# перевыпуска. Свой I1 человека не трогается; повтор ничего не меняет. Профиль пропущен (Docker не отвечает, контейнера
# нет, в контейнере люди приложения, смена не прошла) — строка-предупреждение с причиной и тем, как довести вручную, и
# запись profile-i1-universal-skipped; повтор — при следующем обновлении кода (шаги идут при смене версии или отпечатка
# кода) или после сверки с контейнером (import_reconcile … apply), обновление из-за пропуска не падает.
_migrate_i1_universal() {
    type ga_amn_i1_universal_all >/dev/null 2>&1 || return 0
    ga_dry || command -v docker >/dev/null 2>&1 || return 0
    local fixed
    fixed=$(ga_with_config_lock ga_amn_i1_universal_all) || return 0
    [ -n "$fixed" ] || return 0
    log_dim "$(tf mig_i1_universal "$(printf '%s' "$fixed" | tr '\n' ' ' | sed 's/ *$//')")"
    return 0
}

# Аварийный ключ панели прежних версий (LZ-07, SEC50-08): постоянный файл ключа без срока рядом (<файл ключа>.meta).
# С 0.6.0 служба панели такой ключ не принимает (no_meta), а договор обещает, что при обновлении он удаляется. Убирал
# его только установщик панели, а обновление установщик не зовёт — убираем здесь. Ключ со сроком (выпущен пунктом
# «Аварийный ключ») не трогаем. Идемпотентно: ключа без срока нет — делать нечего. В аудит — что удалено, без ключа.
_migrate_panel_legacy_key() {
    local f
    type _panel_token_file >/dev/null 2>&1 || return 0
    f=$(_panel_token_file)
    { [ -f "$f" ] || [ -L "$f" ]; } && [ ! -d "$f" ] || return 0
    [ -e "$f.meta" ] && return 0
    if ! rm -f "$f" 2>/dev/null; then
        log_warning "$(tf mig_panel_legacy_key_failed "$f")"
        return 0
    fi
    type ga_audit >/dev/null 2>&1 && ga_audit "${GOAMNEZIA_WHO:-ssh}" "panel-legacy-key-removed" "file=$f"
    log_dim "$(t mig_panel_legacy_key)"
    return 0
}

# Служба изоляции (OPS-05) держит код продукта в памяти: код сменился — перезапуск, если она работает.
_migrate_isolation_watch() {
    type timers_isolation_restart >/dev/null 2>&1 || return 0
    [ "$(_cfg '.installed')" = "true" ] || return 0
    timers_isolation_restart
    return 0
}

# _ga_migrate_run full <с какой версии> | reapply — шаги в подоболочке. Шаг, упавший посередине (set -u,
# опечатка в новом коде), обрывает только её, а не весь процесс: вызывающий узнаёт об отказе кодом возврата
# и решает, что дальше. Что шаги дошли до конца, подтверждает строка из подоболочки: выход раньше времени с
# кодом 0 (exit в шаге) — тоже отказ. Вывод шагов — в stderr, как у всей миграции.
_ga_migrate_run() {
    local what="${1:-full}" from="${2:-}" done_mark="" rc=0
    done_mark=$(
        if [ "$what" = full ]; then _ga_migrate_steps "$from" >&2; else _ga_migrate_reapply >&2; fi
        printf 'steps-done'
    ) || rc=$?
    [ "$rc" = 0 ] && [ "$done_mark" = steps-done ] && return 0
    [ "$rc" != 0 ] || rc=1
    return "$rc"
}

# _ga_code_fingerprint — отпечаток кода на диске (install.sh, lib/*.sh, шаблоны nginx): по нему миграция
# узнаёт, что код сменился при той же версии (UP-7). Пусто — нечем посчитать (тогда повтора не будет).
_ga_code_fingerprint() {
    command -v sha256sum >/dev/null 2>&1 || return 0
    cat "$SCRIPT_DIR/install.sh" "$LIB_DIR"/*.sh "$LIB_DIR"/nginx/* 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}'
}

# Выключенные прежними версиями (0.2–0.4.2) лимитами не знали причины: тик ставил только enabled=false, и
# «продлил — включился сам» (0.4.3+) на таких не срабатывало — продление отвечало re_enabled:false, а человек
# оставался выключенным (находка UP-2). Причину выводим один раз: действует лимит — quota/expiry, нет — manual.
_migrate_disabled_reason() {
    type ga_users_infer_disabled_reason >/dev/null 2>&1 || return 0
    local n
    n=$(ga_users_infer_disabled_reason 2>/dev/null) || return 0
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ] && log_dim "$(tf mig_disabled_reason "$n")"
    return 0
}

# Изоляция клиентов профилей (SEC-NET-1): контейнеры прежних версий пропускали людей одного профиля к
# устройствам друг друга. Правило — сразу при обновлении, не дожидаясь тика сторожа; у своих профилей — и
# строкой в start.sh, контейнеры приложения — только правилом (их start.sh не трогаем). Идемпотентно.
# quiet — без строки человеку (повтор после смены кода той же версии).
_migrate_client_isolation() {
    type ga_amn_isolation_apply_all >/dev/null 2>&1 || return 0
    local n
    n=$(ga_amn_isolation_apply_all) || n=0
    [ "${1:-}" = quiet ] && return 0
    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ] && ga_amn_isolation_on; then
        log_dim "$(tf mig_client_isolation "$n")"
    fi
    return 0
}

# Серверы, где профили появились мимо мастера (мастер отменён, контейнер подхвачен из меню, профиль поставлен
# ботом прежней версии), жили с installed=false: таймеры продукта не ставились никогда, а после обновления
# снова открывался мастер — перезаписывал DNS, заводил лишнего admin (находка UP-4). Есть поставленный
# профиль — установка состоялась.
_migrate_mark_installed() {
    [ "$(_cfg '.installed')" = "true" ] && return 0
    command -v jq >/dev/null 2>&1 || return 0
    jq -e '[(.profiles // {}) | to_entries[] | select((.value.installed_at // "") != "")] | length > 0' \
        "$CONFIG_FILE" >/dev/null 2>&1 || return 0
    _ga_mark_installed
    log_dim "$(t mig_marked_installed)"
    return 0
}

# _ga_site_vhost_present — наш vhost сайта на диске: сайт на сервере ставился (nginx настроен нами). Режим из
# config.json этого не говорит: прерванная установка прежних версий оставляла в нём желаемый режим при сайте,
# которого нет (INST-01, INST-03). _ga_site_vhost_checkable — судить по файлу можно: сухой прогон без путей nginx
# стенда (GOAMNEZIA_NGINX_DIR, NGINX_SITE_CONF) смотрел бы в боевой /etc/nginx, а на машине разработчика его нет и
# быть не должно. Где судить нельзя, vhost считается «есть» — поведение прежнее.
_ga_site_vhost_checkable() {
    type ga_site_conf_path >/dev/null 2>&1 || return 1
    if ga_dry && [ -z "${GOAMNEZIA_NGINX_DIR:-}" ] && [ "$(ga_site_conf_path)" = /etc/nginx/sites-available/goamnezia ]; then
        return 1
    fi
    return 0
}
_ga_site_vhost_present() {
    _ga_site_vhost_checkable || return 0
    [ -f "$(ga_site_conf_path)" ]
}

# Сайт после обновления — под конфиг новой версии. vhost собирается из шаблона только при включении сайта и
# смене его настроек, и защиты новой версии (disable_symlinks, access_log off у аварийных локаций — аудит
# безопасности 25.09.2026) до уже установленных серверов иначе не дошли бы никогда. Заодно — ссылки из корня
# сайта, развёрнутого прежней версией. Отказ nginx -t миграцию не роняет: прежний vhost остаётся на месте
# (_website_write_conf_locked возвращает его сам), человек видит предупреждение.
# Аргумент reapply — только перечитать vhost (повтор после смены кода, UP-7), без уборки ссылок.
#
# «Сайт есть» — по факту, а не по режиму в config.json (INST-03): мастер прежних версий писал желаемый режим ДО
# установки, и на сервере, где установку прервали до сайта (168, 04.10.2026), загрузчик пересобирал vhost сайта,
# которого нет, и писал «Конфиг сайта новой версии не применился — сайт работает на прежнем». vhost не ставился —
# пересобирать нечего: ни сборки, ни строки.
_migrate_site_vhost() {
    local root n
    type ga_site_has_site >/dev/null 2>&1 || return 0
    ga_site_has_site 2>/dev/null || return 0
    _ga_site_vhost_present || return 0
    if [ "${1:-}" != reapply ]; then
        root=$(ga_site_root 2>/dev/null)
        # Сам корень бывает ссылкой на свой каталог владельца: find по нему без -mindepth 1 удалял саму
        # ссылку, и сайт отвечал 403/404 после первого же тика, молча (находка UP-6). Корень разворачиваем, а
        # внутри снимаем только ссылки и говорим, сколько.
        root=$(readlink -f "$root" 2>/dev/null) || root=""
        case "$root" in
            ""|/|/var|/var/www|/etc|/opt|/root|/home|/usr|/srv|/tmp) ;;
            /*/*)
                n=$(find "$root" -mindepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')
                if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ]; then
                    find "$root" -mindepth 1 -type l -delete 2>/dev/null || true
                    log_warning "$(tf mig_site_symlinks_removed "$n" "$root")"
                fi ;;
        esac
    fi
    if type _website_reapply_conf_locked >/dev/null 2>&1; then
        _website_reapply_conf_locked >/dev/null 2>&1 || log_warning "$(t mig_site_vhost_failed)"
    fi
    return 0
}

# Линейка профиля у старых установок: поле `line` появилось не сразу, а без
# него всё, что проверяет и генерирует параметры, гадало по имени профиля — и
# у подхваченного из приложения контейнера гадало неверно. Один раз выводим
# линейку по фактическим параметрам и записываем в config.json (idempotent:
# профилю с уже заполненным полем ничего не пишется). Модуля нет — молчим:
# ядро подхватят на следующем запуске, конфиг при этом цел.
_migrate_profile_line() {
    type ga_migrate_profile_line >/dev/null 2>&1 || return 0
    local fixed
    fixed=$(ga_migrate_profile_line 2>/dev/null) || return 0
    [ -n "$fixed" ] || return 0
    log_dim "$(tf mig_profile_line "$(printf '%s' "$fixed" | tr '\n' ' ' | sed 's/ *$//')")"
    return 0
}

# Копия конфига подхваченного legacy-профиля (amnezia-awg, wg0) у прежних версий лежала в state/ под
# wg0.conf, а восстановление из бэкапа, «Поднять заново» и обновление ядра ищут awg0.conf и отвечали
# state_missing (находка ACC-4). Один раз переименовываем (0600); идемпотентно — приведённой копии ничего не
# делается, поэтому шаг есть и в повторе после смены кода той же версии (UP-7): серверы на 0.4.6 до починки.
_migrate_state_conf() {
    type ga_amn_state_canon_all >/dev/null 2>&1 || return 0
    local fixed
    fixed=$(ga_amn_state_canon_all 2>/dev/null) || return 0
    [ -n "$fixed" ] || return 0
    log_dim "$(tf mig_state_conf "$(printf '%s' "$fixed" | tr '\n' ' ' | sed 's/ *$//')")"
    return 0
}

# Таймеры продукта (lib/timers.sh): без модуля — ничего; ошибка не роняет
# мастер и миграцию — таймеры чинятся при следующем запуске меню.
_timers_apply() {
    type timers_install >/dev/null 2>&1 || return 0
    [ "$(_cfg '.installed')" = "true" ] || return 0
    timers_install >/dev/null 2>&1 || log_warning "$(t act_failed)"
    return 0
}

# Установка «состоялась» — это появление первого профиля, а не только финал
# мастера. Через мост (--action=, то есть бот, панель, MCP, CI) мастера не
# бывает вовсе, и сервер оставался с installed=false: таймеры продукта (лимиты,
# сторож, статистика, проверка обновлений, бэкап, бюджет логов) не ставились
# НИКОГДА — их вешает только _timers_apply, а он молча выходит при
# installed != true; интерактивный запуск на таком живом сервере снова
# предлагал первую установку. Отмечаем факт установки там, где он и наступает.
_ga_mark_installed() {
    [ "$(_cfg '.installed')" = "true" ] && return 0
    type ga_config_merge >/dev/null 2>&1 || return 0
    ga_config_merge '{"installed":true}' >/dev/null 2>&1 || return 0
    _timers_apply
    return 0
}

# Ченджлог показывается один раз после обновления версии.
show_upgrade_changelog() {
    local from="${1:-?}" i
    echo ""
    echo -e "  ${BOLD}${GREEN}$(tf upd_title "$from" "$GOAMNEZIA_VERSION")${NC}"
    echo -e "  ${DIM}$(_rule)${NC}"
    # Строк сколько есть в словаре (до двенадцати): список «что нового» меняется с
    # каждым выпуском, и пустая строка в словаре — просто конец списка.
    # Пункт прошлого выпуска («• Из 1.0.11: …», «• From 1.0.11: …» — одно слово, версия, двоеточие) тому, кто уже
    # на этой версии или новее, не новость — не показываем (LH-1 живой проверки 16.10).
    local line since since_re='^•[[:space:]]+[^[:space:]]+[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+):'
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        line=$(t "upd_l${i}")
        [ -n "$line" ] && [ "$line" != "upd_l${i}" ] || continue
        since=""
        [[ "$line" =~ $since_re ]] && since="${BASH_REMATCH[1]}"
        if [ -n "$since" ] && [[ "$from" =~ ^[0-9]+(\.[0-9]+)*$ ]] && ! _ver_lt "$from" "$since"; then
            continue
        fi
        echo -e "  $(ga_win_wrap "$line" 4)"
    done
    echo ""
    echo -ne "  ${DIM}$(t press_enter)${NC}"
    read -r _ || true
}

# Рабочая копия компонента отстаёт от эталона в /opt/goamnezia — накатываем.
# Секреты (.env, token) и venv НЕ трогаем: они принадлежат установке, а не коду.
#
# auto_update_component <откуда> <куда> [юнит] [create] [имя компонента для человека]
# Человеку — одна строка «Установлена новая версия: веб-панель», и только когда компонент уже стоял и его файлы
# правда сменились. Заведённая впервые рабочая копия (MCP на первой установке) — молча: строки «копия
# goamnezia-mcp создана из эталона» и сразу «…обновлена из эталона» были первым, что видел новичок, и ни о чём
# ему не говорили (находка NC-03 критика-новичка, 28.09.2026).
auto_update_component() {
    local src="$1" dst="$2" unit="${3:-}" create="${4:-}" label="${5:-}" changed=0 fresh=0 f rel
    [ -d "$src" ] || return 0
    # Компонента нет на машине — обновлять нечего, ставить будет своё меню
    # (бот и панель). У MCP своего установщика нет: его рабочую копию заводит
    # install.sh (CONTRACT §5) — четвёртый аргумент create. В стендовом режиме
    # каталоги вне $TMP не создаём.
    if [ ! -d "$dst" ]; then
        [ "$create" = "create" ] || return 0
        [ "${GOAMNEZIA_DRY_RUN:-0}" != "1" ] || return 0
        mkdir -p "$dst" 2>/dev/null || return 0
        chmod 700 "$dst" 2>/dev/null || true
        fresh=1
    fi

    while IFS= read -r f; do
        rel="${f#"$src"/}"
        case "$rel" in
            .env|token|.admin_claimed|user_langs.json) continue ;;
            venv/*|__pycache__/*|*/__pycache__/*|*.pyc) continue ;;
            # Установщик компонента работает из /opt/goamnezia и в рабочую копию не нужен. Сами установщики его
            # туда не кладут, и первый же запуск меню после установки бота или панели находил «новый» файл,
            # печатал «обновлена» и перезапускал только что поставленную службу.
            install_*.sh) continue ;;
        esac
        if [ ! -f "$dst/$rel" ] || ! cmp -s "$f" "$dst/$rel"; then
            mkdir -p "$(dirname "$dst/$rel")" 2>/dev/null || true
            cp -f "$f" "$dst/$rel" 2>/dev/null && changed=1
        fi
    done < <(find "$src" -type f 2>/dev/null)

    [ "$changed" = "1" ] || return 0
    [ "$fresh" = 1 ] && return 0
    # Целая фраза на компонент («Веб-панель обновлена.»): «Установлена новая версия: веб-панель.» читалось
    # как отчёт программы, а не как новость для человека (находка NC-28).
    log_dim "${label:-$(tf upd_component "$(basename "$dst")")}"
    # systemctl cat, а не list-unit-files: последний возвращает 0 и для
    # несуществующего юнита, и рестарт уходил в пустоту с ошибкой в логе.
    if [ -n "$unit" ] && _svc_probe cat "$unit" >/dev/null; then
        _svc_do restart "$unit" || log_warning "$(tf upd_restart_failed "$unit")"
    fi
    return 0
}

auto_update_components() {
    auto_update_component "$SCRIPT_DIR/goamnezia-bot"  "$BOT_DIR"   goamnezia-bot.service "" "$(t upd_done_bot)"
    auto_update_component "$SCRIPT_DIR/admin-web"      "$ADMIN_DIR" goamnezia-admin.service "" "$(t upd_done_admin)"
    # MCP-сервер работает по stdio из ssh — юнита у него нет, рестартовать нечего;
    # рабочая копия создаётся здесь же (у MCP нет своего установщика), а команда
    # goamnezia-mcp должна указывать на неё, а не на эталон: гайд-ресурс сервер
    # ищет рядом с собой (realpath), и оба файла обязаны быть одной версии.
    auto_update_component "$SCRIPT_DIR/goamnezia-mcp"  "$MCP_DIR"   "" create "$(t upd_done_mcp)"
    _mcp_ensure_symlink
    # Долгоживущие службы, которые исполняют код прямо с диска, после обновления подхватывают его только
    # перезапуском: страницы подключения (lib/pages_server.py из эталона) и HTTP-транспорт MCP (рабочая копия
    # server.py). Раньше новый код начинал работать лишь после перезагрузки сервера — вместе с исправлениями
    # безопасности (живая проверка 25.09.2026).
    # Служба страниц собирает профиль mihomo подписок кодом lib/awgkeys.py, а короткие ссылки — lib/shortlinks.py
    # (import): правка любого из них тоже требует перезапуска.
    _restart_if_code_changed goamnezia-pages.service "$SCRIPT_DIR/lib/pages_server.py" "$(t upd_restarted_pages)" \
        "$SCRIPT_DIR/lib/awgkeys.py" "$SCRIPT_DIR/lib/shortlinks.py"
    _restart_if_code_changed goamnezia-mcp-http.service "$MCP_DIR/server.py" "$(t upd_restarted_mcp_http)"
}

# _restart_if_code_changed <юнит> <файл> [имя для человека] [ещё файлы кода…] — перезапустить работающую службу,
# если её код на диске изменился с прошлого запуска (отпечаток всех файлов подряд — в state/; у одного файла он
# тот же, что sha256 самого файла). Выключенную не трогаем: перезапуск её бы включил.
_restart_if_code_changed() {
    local unit="$1" file="$2" label="${3:-}" stamp sum old f
    local -a files=("$file")
    shift 3 2>/dev/null || shift $#
    for f in "$@"; do [ -f "$f" ] && files+=("$f"); done
    [ -f "$file" ] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    _svc_probe is-active --quiet "$unit" || return 0
    stamp="$GOAMNEZIA_DIR/state/.code_${unit%.service}.sha256"
    sum=$( { cat "${files[@]}" | { sha256sum || shasum -a 256; }; } 2>/dev/null | cut -d' ' -f1)
    [ -n "$sum" ] || return 0
    old=$(cat "$stamp" 2>/dev/null)
    [ "$sum" = "$old" ] && return 0
    if _svc_do restart "$unit"; then
        mkdir -p "$GOAMNEZIA_DIR/state" 2>/dev/null
        _ga_mark_write "$stamp" "$sum"
        log_dim "${label:-$(tf upd_service_restarted "${unit%.service}")}"
    else
        log_warning "$(tf upd_restart_failed "$unit")"
    fi
    return 0
}

# /usr/local/bin/goamnezia-mcp → рабочая копия server.py (CONTRACT §1, §5).
# bootstrap.sh делает симлинк на эталон ещё до первого запуска install.sh —
# здесь он перенацеливается на рабочую копию, как только она появилась.
_mcp_ensure_symlink() {
    local target="$MCP_DIR/server.py" link="/usr/local/bin/goamnezia-mcp"
    [ "${GOAMNEZIA_DRY_RUN:-0}" != "1" ] || return 0
    [ -f "$target" ] || return 0
    chmod 755 "$target" 2>/dev/null || true
    [ "$(readlink "$link" 2>/dev/null)" = "$target" ] && return 0
    ln -sfn "$target" "$link" 2>/dev/null || true
    return 0
}

# ── Выбор языка при первом запуске ───────────────────────────────────────────
first_run_language_picker() {
    local marker="$GOAMNEZIA_DIR/.language" cfg_lang chosen
    cfg_lang=$(_cfg '.lang')
    [ -f "$marker" ] && return 0
    [ -n "$cfg_lang" ] && return 0
    type pick_language_interactive >/dev/null 2>&1 || return 0
    chosen=$(pick_language_interactive first) || return 0
    [ -n "$chosen" ] || return 0
    type save_language >/dev/null 2>&1 && save_language "$chosen"
    type load_language >/dev/null 2>&1 && load_language "$chosen"
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# Неинтерактивный мост --action= (бот, веб-панель, MCP, CI)
# ══════════════════════════════════════════════════════════════════════════════
# Правила веток (CONTRACT §0.2, §0.3):
#   - в stdout уходит ТОЛЬКО JSON, последней строкой; весь UI — в stderr
#     (log_* уже пишут в stderr);
#   - код возврата 0 при успехе, ≠0 при ошибке, но JSON печатается в обоих
#     случаях: вызывающий разбирает именно его;
#   - имя действия обязано быть в lib/actions.json, иначе unknown_action;
#   - readonly-действия замок не берут: панель опрашивает их по таймеру, и на
#     время долгой записи весь интерфейс вставал бы.
#
# Примеры:
#   goamnezia --action=user-add --name=anna --profiles=awg2,awg3 --json
#   goamnezia --action=user-key --name=anna --profile=awg2 --format=all --json

# Функция модуля есть? Если нет — честный JSON вместо падения по set -u.
_require_fn() {
    local fn="$1"
    type "$fn" >/dev/null 2>&1 && return 0
    ga_emit_json error "$(tf module_missing "$fn")" "code=module_missing"
    return 1
}

# Значение аргумента --k=v. Через косвенную ссылку с дефолтом — прямое обращение
# к ARG_x рушит скрипт по set -u, когда аргумент не передан.
_arg() {
    local _v="ARG_${1}"
    printf '%s' "${!_v:-}"
}

# Валидный JSON или фолбэк: модуль мог вернуть пусто или текст ошибки, а
# @json: вставляет значение в ответ БЕЗ кавычек и сломал бы весь ответ.
_as_json() {
    local v="$1" fb="${2:-null}"
    # Без -e: с ним jq считает false и null «неуспехом», и булево из модуля
    # (reissue_required) подменялось бы запасным значением.
    if [ -n "$v" ] && command -v jq >/dev/null 2>&1 && printf '%s' "$v" | jq -c . >/dev/null 2>&1; then
        printf '%s' "$v" | jq -c .
    else
        printf '%s' "$fb"
    fi
}

_action_fail() {
    ga_emit_json error "${2:-$(t act_failed)}" "code=${1:-exec_failed}"
    return 1
}

# Одно поле из JSON модуля (пусто, если нет или не JSON) — для сообщений ответа.
_json_field() {
    local js="$1" path="$2" v
    v=$(printf '%s' "$js" | jq -r "${path} // empty" 2>/dev/null) || v=""
    printf '%s' "$v"
}

# _json_bool <JSON> <путь> → true | false (всегда одно из двух: «// empty» у _json_field глотает false).
_json_bool() {
    local v
    v=$(printf '%s' "$1" | jq -r "if (${2}) == true then \"true\" else \"false\" end" 2>/dev/null) || v=false
    [ "$v" = true ] && printf 'true' || printf 'false'
}

# _bytes_len <строка> → длина в БАЙТАХ при любой локали: ${#…} в UTF-8 считает символы (TK-10).
_bytes_len() {
    local LC_ALL=C
    printf '%s' "${#1}"
}

# Ответ моста = объект модуля + status/message в корне. Карточка доступа
# агента и состояние транспорта — плоские объекты с десятком полей; класть их
# под result заставило бы бота, панель и тесты разбирать лишний уровень, а
# перечислять поля по одному в ga_emit_json — дублировать модуль. Не JSON-объект
# → обычный ответ с result (валидный JSON гарантирован при любом входе).
_action_emit_merged() {
    local status="$1" message="$2" js="$3"
    if [ -n "$js" ] && command -v jq >/dev/null 2>&1 \
       && printf '%s' "$js" | jq -e 'type == "object"' >/dev/null 2>&1; then
        printf '%s' "$js" | jq -c --arg s "$status" --arg m "$message" '. + {status: $s, message: $m}' && return 0
    fi
    ga_emit_json "$status" "$message" "result=@json:$(_as_json "$js" 'null')"
}

# Запуск функции модуля с сохранением кода ошибки. Через $(…) функция работает
# в подоболочке, и код с сообщением, которые она положила в GA_ERR_CODE /
# GA_ERR_MSG (lib/docker.sh) или GA_LAST_ERROR_CODE (lib/common.sh), наружу
# не доходят — мост отвечал бы обобщённым install_failed вместо port_busy, и
# агент MCP не понимал бы, что чинить. ga_capture пишет stdout в файл в ТЕКУЩЕЙ
# оболочке: результат — в out, код и сообщение модуля — в ответе.
# _action_run <код-по-умолчанию> <функция> [аргументы…] → 0 и out; иначе JSON
# ошибки уже напечатан, вернуть 1.
_action_run() {
    local fallback="$1" code
    shift
    GA_ERR_CODE=""; GA_ERR_MSG=""; GA_LAST_ERROR_CODE=""; GA_CERT_CAUSE=""; GA_CERT_RETRY_AFTER=""
    if type ga_capture >/dev/null 2>&1; then
        ga_capture out "$@" && return 0
    else
        out=$("$@") && return 0
    fi
    code="${GA_ERR_CODE:-${GA_LAST_ERROR_CODE:-$fallback}}"
    # Отказ Let's Encrypt — с причиной словом (dns | net | limit) и сроком лимита (lib/website.sh, L-26): у бота на
    # каждую причину свой текст «что случилось и что сделать», а не разбор слов ядра.
    if [ "$code" = cert_failed ] && [ -n "${GA_CERT_CAUSE:-}" ]; then
        ga_emit_json error "${GA_ERR_MSG:-$(t act_failed)}" "code=${code}" "cert_cause=${GA_CERT_CAUSE}" \
            "cert_retry_after=${GA_CERT_RETRY_AFTER:-}"
        return 1
    fi
    ga_emit_json error "${GA_ERR_MSG:-$(t act_failed)}" "code=${code}"
    return 1
}

# _tick_extra <функция> [аргументы…] → JSON модуля или null. Дополнительные
# тики (истёкшие страницы подключения, заявки зеркала — docs/CLIENTS.md §9)
# едут в ответе основного таймера отдельным блоком: своих таймеров у них
# нет, а их отказ сторож контейнеров ронять не должен. Без модуля — null.
_tick_extra() {
    local js
    type "$1" >/dev/null 2>&1 || { printf 'null'; return 0; }
    js=$("$@") || js=""
    _as_json "$js" 'null'
}

# Режимы с сайтом: pro и lite_site. У обоих один и тот же сайт на домене с
# сертификатом Let's Encrypt (самоподписанный — запасной путь, когда домена нет
# или A-запись ещё не разошлась); отличаются они ТОЛЬКО тем, где стоит
# AmneziaWG: на своём порту (lite_site) или на UDP/443 рядом с сайтом (pro).
_site_mode_has_site() { case "$(_cfg '.mode')" in pro|lite_site) return 0 ;; *) return 1 ;; esac; }

# Ветки, которым нужен сайт (шаблон): в lite нет nginx — needs_site, как у
# mcp-http-on (CONTRACT §5.1), а не запись в config.json, которую никто не увидит.
_action_require_site() {
    _site_mode_has_site && return 0
    ga_emit_json error "$(t act_needs_site)" "code=needs_site" "mode=$(_cfg '.mode')"
    return 1
}
# Ветки, которым нужен ДОМЕН С ДОВЕРЕННЫМ СЕРТИФИКАТОМ (панель на домене,
# ссылки мини-аппа): оба режима с сайтом, если сертификат Let's Encrypt и домен
# на месте. На запасном самоподписанном браузер мини-апп не откроет, поэтому
# отказ остаётся — код not_pro сохранён ради контракта (его разбирают бот,
# панель и MCP), но значит он теперь «нет домена с настоящим сертификатом».
# Чего не хватает панели на домене: пусто — всё на месте, иначе код причины.
# Один источник правды на отказ (miniapp-on/rotate) и на состояние
# (miniapp-status): пока их было два, состояние отвечало «включено» там, где
# включение отказывало, — продукт врал сам себе (DEFECTS §1.8).
_site_panel_reason() {
    _site_mode_has_site                          || { printf 'no_site'; return 0; }
    [ -n "$(_cfg '.domain')" ]                   || { printf 'no_domain'; return 0; }
    [ "$(_cfg '.site.cert')" = "letsencrypt" ]   || { printf 'untrusted_cert'; return 0; }
    printf ''
}

# Подсказка к причине — из словаря; пустая причина подсказки не требует.
_site_panel_reason_hint() {
    case "${1:-}" in
        no_site)                  t act_needs_site ;;
        no_domain|untrusted_cert) t act_not_pro ;;
        *)                        printf '' ;;
    esac
}

_action_require_pro() {
    local reason
    reason=$(_site_panel_reason)
    [ -z "$reason" ] && return 0
    ga_emit_json error "$(t act_not_pro)" "code=not_pro" "mode=$(_cfg '.mode')" \
        "cert=$(_cfg '.site.cert')" "domain=$(_cfg '.domain')" "reason=${reason}"
    return 1
}

# Режимы с сайтом требуют свободных и открытых TCP/80 и TCP/443 (PLAN §4.3.1).
# Отказ несёт поля первой причины (port, proto, pid, process, unit, container,
# product), команду-подсказку и все причины списком — бот показывает message и
# «Освободите порт или используйте чистый сервер», панель и MCP разбирают код:
# port_busy — порт держит чужой процесс, closed_local — закрыт локальным
# файрволом (его умеет открыть мастер). Наш nginx/контейнер (ours) не блокирует:
# повторное включение режима — ремонт, а не конфликт. Без модуля проверки нет.
_action_require_ports() {
    local mode="$1" js first code
    case "$mode" in pro|lite_site) ;; *) return 0 ;; esac
    type preflight_modes >/dev/null 2>&1 || return 0
    js=$(preflight_modes 2>/dev/null) || return 0
    printf '%s' "$js" | jq -e . >/dev/null 2>&1 || return 0
    [ "$(printf '%s' "$js" | jq -r --arg m "$mode" '.[$m].available')" = true ] && return 0
    first=$(printf '%s' "$js" | jq -c --arg m "$mode" '.[$m].reasons[0] // {}')
    code="port_busy"
    [ "$(printf '%s' "$first" | jq -r '.state // ""')" = closed_local ] && code="closed_local"
    ga_emit_json error "$(printf '%s' "$first" | jq -r '.message // ""')" "code=${code}" "mode=${mode}" \
        "port=@json:$(printf '%s' "$first" | jq -c '.port // null')" \
        "proto=$(printf '%s' "$first" | jq -r '.proto // ""')" \
        "pid=@json:$(printf '%s' "$first" | jq -c '.pid // null')" \
        "process=$(printf '%s' "$first" | jq -r '.process // ""')" \
        "unit=$(printf '%s' "$first" | jq -r '.unit // ""')" \
        "container=$(printf '%s' "$first" | jq -r '.container // ""')" \
        "product=$(printf '%s' "$first" | jq -r '.product // ""')" \
        "hint=$(printf '%s' "$js" | jq -r 'if (.hints.open_cmd // "") != "" then .hints.open_cmd else (.hints.free_cmd // "") end')" \
        "reasons=@json:$(printf '%s' "$js" | jq -c --arg m "$mode" '.[$m].reasons // []')"
    return 1
}

# Срок забора подписки для status (R9-1): совет сервера (subs.update_interval) и приложения каталога, которые
# обновляют подписку сами и реже (ga_subs_update_slow), — {update_interval, update_slow}, как в ответе sub-list, но без
# обхода подписок: окно «Исправить S4» в боте брало их из sub-list без имени и ждало строку каждой подписки. Модуля
# подписок нет — null.
_subs_update_json() {
    type ga_subs_update_hours >/dev/null 2>&1 || { printf 'null'; return 0; }
    local h slow='[]'
    h=$(ga_subs_update_hours 2>/dev/null); [[ "$h" =~ ^[0-9]+$ ]] || h=12
    if type ga_subs_update_slow >/dev/null 2>&1; then slow=$(ga_subs_update_slow "$h" 2>/dev/null) || slow='[]'; fi
    case "$slow" in "["*"]") ;; *) slow='[]' ;; esac
    printf '{"update_interval":%s,"update_slow":%s}' "$((10#$h))" "$slow"
}

# Блок site для status в режимах с сайтом: домен и адрес сайта, шаблон, вид
# сертификата (letsencrypt | selfsigned), его срок и — для самоподписанного —
# отпечаток SHA-256 (по нему агенты MCP и человек доверяют серверу), панель на
# домене (только факт: секретный путь выдают лишь miniapp-on/rotate), Alt-Svc,
# listen, маршрут MCP; в lite — null. Каталог шаблонов (14 МБ) здесь не читаем:
# status дёргают бот и панель на каждом экране, имя отдаёт change-template.
_site_status_json() {
    local mode domain="" url="" cert exp="" expires="" days="null" fp="" ip
    local panel=false alt=false mcp=false idx=false listen root
    _site_mode_has_site || { printf 'null'; return 0; }
    mode=$(_mode_current)
    cert=$(_cfg '.site.cert')
    [ -n "$cert" ] || cert="letsencrypt"
    if [ "$cert" = "selfsigned" ]; then
        # Запасной путь: сайт отдаётся по IP, сохранённый домен к нему пока не
        # относится — site.domain пуст, а status.domain выше по-прежнему отдаёт
        # сохранённое значение (по нему видно, куда сайт переедет).
        ip=$(_server_ip); [ -n "$ip" ] && url="https://${ip}/"
        if type website_selfsigned_expiry >/dev/null 2>&1; then
            exp=$(website_selfsigned_expiry 2>/dev/null) || exp=""
        fi
        if type website_cert_fingerprint >/dev/null 2>&1; then
            fp=$(website_cert_fingerprint 2>/dev/null) || fp=""
        fi
    else
        domain=$(_cfg '.domain')
        [ -n "$domain" ] && url="https://${domain}/"
        if [ -n "$domain" ] && type website_cert_expiry >/dev/null 2>&1; then
            exp=$(website_cert_expiry "$domain" 2>/dev/null) || exp=""
        fi
    fi
    if [ -n "$exp" ]; then
        expires="${exp%% *}"; days="${exp#* }"
        [[ "$days" =~ ^-?[0-9]+$ ]] || days="null"
    fi
    # Панель на домене живёт в обоих режимах с сайтом — ей нужен доверенный
    # сертификат, а не «Pro».
    [ -n "$(_cfg '.panel.miniapp_path')" ] && [ "$cert" = "letsencrypt" ] && [ -n "$domain" ] && panel=true
    [ "$(_cfg '.options.alt_svc')" = "true" ] && alt=true
    [ "$(_cfg '.site.mcp_location')" = "true" ] && mcp=true
    if type ga_site_root >/dev/null 2>&1; then
        root=$(ga_site_root); [ -f "$root/index.html" ] && idx=true
    fi
    # Поле listen остаётся ради стабильности контракта: значение у него одно —
    # сайт сам держит публичный 443 (lib/website.sh).
    listen="public"
    jq -cn --arg d "$domain" --arg url "$url" --arg tpl "$(_cfg '.site.template_id')" --arg src "$(_cfg '.site.template_source')" \
        --arg cert "$cert" --arg fp "$fp" --arg exp "$expires" --argjson days "$days" \
        --argjson panel "$panel" --argjson alt "$alt" --argjson mcp "$mcp" --argjson idx "$idx" --arg listen "$listen" \
        '{domain: $d, url: $url, template_id: $tpl, template_source: $src, index_present: $idx,
          cert: $cert, cert_fingerprint_sha256: $fp, cert_expires: $exp, cert_days_left: $days,
          panel: $panel, alt_svc: $alt, mcp_location: $mcp, listen: $listen}' 2>/dev/null || printf 'null'
}

# Последний переезд сервера на другой IP (L-06): {old, new, at, endpoint_host, endpoint_host_action} или null.
# Пишет сторож (amnezia_server_ip_check → config.json .server_ip_change); форма — белым списком полей.
_server_ip_change_json() {
    local js
    js=$(jq -c '(.server_ip_change // null)
        | if type == "object" then {old: (.old // "" | tostring), new: (.new // "" | tostring), at: (.at // "" | tostring),
               endpoint_host: (.endpoint_host // "" | tostring), endpoint_host_action: (.endpoint_host_action // "" | tostring)}
          else null end' "$CONFIG_FILE" 2>/dev/null) || js=""
    printf '%s' "${js:-null}"
}

# Итог суточной проверки обновлений Amnezia (L-07) — без сети, из памяти таймера (lib/upstream.sh
# upstream_summary); модуля нет или проверок ещё не было — null.
_upstream_summary_json() {
    local js=""
    type upstream_summary >/dev/null 2>&1 && js=$(upstream_summary 2>/dev/null)
    _as_json "$js" 'null'
}

# _action_meta <имя> — всё о действии из lib/actions.json ОДНИМ проходом jq: известно ли, readonly ли, какие
# аргументы принимает и правила их проверки. Раньше это были пять отдельных jq по файлу в 115 КБ на каждый вызов
# моста (main, диспетчер, разбор и проверка аргументов) — заметная доля цены частого чтения (CPU-03). Ответ живёт
# до конца процесса: каталог за время одного вызова не меняется. Звать в текущей оболочке — подоболочки потом
# пользуются готовым. Строки ответа jq: «y|n», readonly, имена аргументов через пробел, дальше правила проверки
# (по строке на параметр, поля через \x1f — как ждёт _action_validate_args).
GA_ACT_META_NAME=""
GA_ACT_KNOWN=n
GA_ACT_READONLY=false
GA_ACT_ARGS=""
GA_ACT_SPEC=""
_action_meta() {
    local name="${1:-}" out rest
    [ -n "$name" ] || return 1
    [ "$GA_ACT_META_NAME" = "$name" ] && return 0
    out=$(jq -r --arg a "$name" '
        . as $root
        | if (($root.actions // {}) | has($a)) | not then "n"
          else
            "y",
            ($root.actions[$a].readonly // false | tostring),
            ([($root.actions[$a].params // {}) | to_entries[] | select((.value.stdin // false) | not) | .key] | join(" ")),
            (($root.actions[$a].params // {}) | to_entries[]
             | select((.value.stdin // false) | not)
             | .key as $k
             | ((.value.ref // $k)) as $r
             | (($root.param_types[$r]) // {}) as $pt
             | [ $k,
                 ((.value.required // false) | tostring),
                 ((.value.default // "") | tostring),
                 ($pt.type // "string"),
                 ($pt.pattern // ""),
                 (($pt.enum // []) | join(",")),
                 (($pt.minimum // "") | tostring),
                 (($pt.maximum // "") | tostring) ] | join("\u001f"))
          end' "$ACTIONS_JSON" 2>/dev/null) || out=""
    GA_ACT_KNOWN=n; GA_ACT_READONLY=false; GA_ACT_ARGS=""; GA_ACT_SPEC=""
    if [ "${out%%$'\n'*}" = y ]; then
        GA_ACT_KNOWN=y
        rest="${out#*$'\n'}"
        GA_ACT_READONLY="${rest%%$'\n'*}"
        if [ "$rest" != "${rest#*$'\n'}" ]; then
            rest="${rest#*$'\n'}"
            GA_ACT_ARGS="${rest%%$'\n'*}"
            [ "$rest" != "${rest#*$'\n'}" ] && GA_ACT_SPEC="${rest#*$'\n'}"
        fi
    fi
    # Пустой ответ (нет jq или каталога) не запоминаем: следующий вопрос спросит снова.
    [ -n "$out" ] && GA_ACT_META_NAME="$name"
    return 0
}

_action_known() {
    [ -n "${1:-}" ] || return 1
    _action_meta "$1"
    [ "$GA_ACT_KNOWN" = y ]
}

# _action_own_lock <имя> — изменяющее действие со своим замком: ни общего замка моста, ни миграции перед ним. Это
# решение по короткой ссылке (short-decide, docs/SUBSCRIPTION.md §11): состояние коротких ссылок пишет lib/shortlinks.py
# под своим flock (subs/.short/.lock), а под общим замком нажатие администратора в боте висело бы до 30 с за долгой
# операцией (установка, обновление), пока человек ждёт на экране число. Чтения short-status и short-pending и так
# readonly. Миграцию сделает следующий обычный вызов моста.
_action_own_lock() {
    case "${1:-}" in
        short-decide) return 0 ;;
        *) return 1 ;;
    esac
}

_action_readonly() {
    _action_meta "${1:-}"
    printf '%s\n' "$GA_ACT_READONLY"
}

# Разбор --k=v в ARG_<k>. Дефисы в имени параметра становятся подчёркиваниями
# (--quota-gb=5 → ARG_quota_gb), как описано в lib/actions.json.
_action_parse_args() {
    local a k v
    for a in "$@"; do
        case "$a" in
            --action=*) ;;
            --json)     ;;
            --*=*)
                k="${a%%=*}"; k="${k#--}"; k="${k//-/_}"
                v="${a#*=}"
                if ! [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]{0,63}$ ]]; then
                    ga_emit_json error "$(tf act_bad_arg_name "$k")" "code=bad_arg"
                    return 2
                fi
                printf -v "ARG_${k}" '%s' "$v"
                ;;
            *) ;;   # прочее (например --json после действия) молча игнорируем
        esac
    done
    return 0
}

_RE_PAT=""
_RE_MAXLEN=0

# _action_value_fits <значение> — предел длины (_RE_MAXLEN) и шаблон (_RE_PAT) параметра, считая СИМВОЛЫ, а не
# байты: бот, панель и страницы зовут мост без LANG, и в локали C подпись из 30 русских букв (57 байт) не
# проходила шаблон {1,48}, а из SSH (UTF-8) проходила (находка SR-23). Длину считает ga_char_len при любой
# локали — C.UTF-8 есть не везде (L1-15 / TAIL-8), — а у шаблонов «одна скобка на всё значение» верхнюю границу
# повторителя _action_re_normalize переносит в _RE_MAXLEN. Локаль C.UTF-8 (где есть) — только на сам шаблон.
_action_value_fits() {
    local n
    if [ "$_RE_MAXLEN" -gt 0 ]; then
        if type ga_char_len >/dev/null 2>&1; then n=$(ga_char_len "$1"); else n=${#1}; fi
        [ "$n" -le "$_RE_MAXLEN" ] || return 1
    fi
    type ga_utf8_lc_init >/dev/null 2>&1 && ga_utf8_lc_init
    [ -z "${GA_UTF8_LC:-}" ] || local LC_ALL="$GA_UTF8_LC"
    # Справа от =~ переменная СПЕЦИАЛЬНО без кавычек: в кавычках bash
    # сравнивает буквально, и любая проверка проходила бы всегда.
    [[ "$1" =~ $_RE_PAT ]]
}

# Регексы из JSON Schema приводим к тому, что понимает ERE в bash.
_action_re_normalize() {
    local re="$1" head tail
    _RE_MAXLEN=0
    # Опережающие проверки (?=…) ERE не компилирует вовсе: [[ =~ ]] вернёт 2 на
    # ЛЮБОМ значении, и валидный домен был бы отвергнут. В actions.json они
    # задают только длину — забираем её отдельным пределом и вырезаем группу.
    if [[ "$re" =~ \(\?=\.\{1,([0-9]+)\}\$\) ]]; then
        _RE_MAXLEN="${BASH_REMATCH[1]}"
    fi
    while [[ "$re" == *'(?='* ]]; do
        head="${re%%'(?='*}"; tail="${re#*'(?='}"
        re="${head}${tail#*)}"
    done
    # \xHH в ERE тоже не понимается и распадается на отдельные символы: диапазон
    # управляющих кодов заменяем эквивалентным классом POSIX.
    re="${re//\\x00-\\x1f\\x7f/[:cntrl:]}"
    re="${re//\\x00-\\x1f/[:cntrl:]}"

    # Шаблон — одна скобка на всё значение с повторителем («^[^…]{1,48}$», «^[A-Za-z0-9_-]{1,32}$»): его
    # верхняя граница — это предел длины, и считать её надо СИМВОЛАМИ при любой локали. В локали C повторитель
    # ERE считает байты, и подпись кириллицей упиралась в предел вдвое раньше (L1-15 / TAIL-8). Границу — в
    # _RE_MAXLEN (её проверяет ga_char_len), в шаблоне остаётся «{m,}». Одна скобка — это ровно одна «[» и одна
    # «]» после снятия классов POSIX ([:cntrl:] и т. п.), первая — сразу за «^», последняя — перед повторителем.
    local body strip cls brk lo hi lo_n hi_n
    if [[ "$re" =~ ^\^(.*)\{([0-9]+),([0-9]+)\}\$$ ]]; then
        body="${BASH_REMATCH[1]}"; lo="${BASH_REMATCH[2]}"; hi="${BASH_REMATCH[3]}"
        strip="$body"
        for cls in alnum alpha blank cntrl digit graph lower print punct space upper xdigit; do
            strip="${strip//"[:${cls}:]"/}"
        done
        brk="${strip//\[/}"; lo_n=$(( ${#strip} - ${#brk} ))      # сколько «[»
        brk="${strip//\]/}"; hi_n=$(( ${#strip} - ${#brk} ))      # сколько «]»
        if [ "$lo_n" = 1 ] && [ "$hi_n" = 1 ] && [ "${strip:0:1}" = "[" ] && [ "${strip: -1}" = "]" ]; then
            if [ "$_RE_MAXLEN" -eq 0 ] || [ "$hi" -lt "$_RE_MAXLEN" ]; then _RE_MAXLEN="$hi"; fi
            re="^${body}{${lo},}\$"
        fi
    fi

    # Повторитель {m,n} в POSIX ERE ограничен RE_DUP_MAX = 255 (и в glibc, и в
    # BSD). Шаблон вида {0,512} из actions.json не компилируется вовсе, bash
    # возвращает 2 — «не совпало», и валидное значение отвергалось. Верхнюю
    # границу снимаем, а длину проверяем отдельно.
    local rest="$re" rebuilt="" pre before
    while [[ "$rest" =~ \{([0-9]+),([0-9]+)\} ]]; do
        lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
        before="$rest"
        pre="${rest%%\{"${lo}","${hi}"\}*}"
        rest="${rest#*\{"${lo}","${hi}"\}}"
        # Страховка от вечного цикла: если подстроку вырезать не удалось,
        # отдаём остаток как есть — лучше строгая проверка, чем зависший мост.
        if [ "$rest" = "$before" ]; then break; fi
        if [ "$hi" -gt 255 ]; then
            [ "$_RE_MAXLEN" -eq 0 ] && _RE_MAXLEN="$hi"
            rebuilt+="${pre}{${lo},}"
        else
            rebuilt+="${pre}{${lo},${hi}}"
        fi
    done
    re="${rebuilt}${rest}"

    _RE_PAT="$re"
}

# Проверка аргументов по param_types из lib/actions.json + подстановка default.
# Все имена, которые действие принимает: свои параметры плюс общие. Неизвестное
# имя мост ГЛОТАЛ молча (`--bogus=1` → success), и опечатка в имени параметра
# тихо теряла значение: `--quota-gb=50` вместо `--quota_gb=50` заводило
# пользователя без лимита и рапортовало об успехе (DEFECTS §5.2). MCP такое
# отвергал всегда — теперь и мост.
_action_known_args() {
    local name="$1" k
    # Параметр со stdin: true (ключ человека в user-attach-key) приходит только
    # каналом: в argv его видно в ps, поэтому --config=… в командной строке —
    # неизвестный аргумент, а не второй способ передать секрет (_action_meta
    # такие параметры в список не берёт).
    _action_meta "$name"
    for k in $GA_ACT_ARGS; do printf '%s\n' "$k"; done
    # confirm разрешён везде: разрушительные его требуют, остальные не заметят.
    printf 'confirm\n'
}

_action_reject_unknown_args() {
    local name="$1" known var k
    _action_meta "$name"
    known=" $GA_ACT_ARGS confirm "
    # ${!ARG_@} — имена всех переменных с этим началом; compgen тут не нужен.
    for var in ${!ARG_@}; do
        k="${var#ARG_}"
        case "$known" in
            *" $k "*) ;;
            *)  ga_emit_json error "$(tf act_unknown_arg "$name" "$k")" "code=bad_arg"
                return 2 ;;
        esac
    done
    return 0
}

_action_validate_args() {
    local name="$1" spec p req def ptype pat penum pmin pmax var val e ok
    _action_reject_unknown_args "$name" || return 2
    # Разделитель \x1f, а НЕ табуляция: табуляция входит в IFS-пробелы, и bash
    # схлопывает соседние табы в один — пустые поля (нет enum, нет границ)
    # исчезали, всё уезжало влево, и вместо диапазона проверялся «enum».
    # Регексы содержат | и , поэтому обычные разделители тоже не годятся.
    # Правила — из того же прохода jq, что и всё остальное о действии (_action_meta).
    _action_meta "$name"
    spec="$GA_ACT_SPEC"

    [ -n "$spec" ] || return 0

    # Herestring, а не пайп: цикл должен идти в ТЕКУЩЕЙ оболочке, иначе
    # подставленные default и return из ветки ошибки потеряются в подоболочке.
    while IFS=$'\x1f' read -r p req def ptype pat penum pmin pmax; do
        [ -n "$p" ] || continue
        var="ARG_${p}"
        val="${!var:-}"

        if [ -z "$val" ]; then
            # Аргумент не передан и пустой — разные вещи: --value= у
            # profile-set-param значит «убрать параметр», --host= у
            # endpoint-set — «вернуть IP сервера» (actions.json так и описывает).
            # Обязательным считаем только отсутствующий; пустому подставляем
            # default, если он есть, иначе отдаём модулю как есть.
            if [ "$req" = "true" ] && ! [[ -v "$var" ]]; then
                ga_emit_json error "$(tf act_missing_arg "$p")" "code=missing_arg"
                return 2
            fi
            # Обязательный выбор из списка, где пустого варианта нет, — пустое значение не «по
            # умолчанию», а ошибка: `backup-schedule --frequency=` молча снимал ночные копии
            # (находка SR-47, 25.09.2026; MCP такое уже отвергал, мост и панель — нет).
            # У --mode свой страж с кодом invalid_mode (договор change-mode) — его не перебиваем.
            if [ "$req" = "true" ] && [ "$p" != mode ] && [ -n "$penum" ] && [ -z "$def" ] && [[ ",$penum," != *",,"* ]]; then
                ga_emit_json error "$(tf act_bad_value "$p" "")" "code=bad_arg"
                return 2
            fi
            [ -n "$def" ] && printf -v "$var" '%s' "$def"
            continue
        fi

        if [ "$ptype" = "integer" ]; then
            # Не длиннее 18 цифр: дальше арифметика bash переполняется и «проверенное» число становится другим.
            if ! [[ "$val" =~ ^-?[0-9]{1,18}$ ]]; then
                ga_emit_json error "$(tf act_bad_value "$p" "$val")" "code=bad_arg"
                return 2
            fi
            # Ведущие нули — не восьмеричное: «0443» — это 443, а арифметика bash в модулях читала его как 291
            # (находка BOT-8, сторона моста). Число приводим к десятичному виду один раз здесь — до границ и до
            # модулей, — и дальше им пользуются все.
            if [[ "$val" == -* ]]; then val=$(( -(10#${val#-}) )); else val=$(( 10#$val )); fi
            printf -v "$var" '%s' "$val"
            if [ -n "$pmin" ] && [ "$val" -lt "$pmin" ]; then
                ga_emit_json error "$(tf act_out_of_range "$p" "$pmin" "$pmax")" "code=bad_arg"
                return 2
            fi
            if [ -n "$pmax" ] && [ "$val" -gt "$pmax" ]; then
                ga_emit_json error "$(tf act_out_of_range "$p" "$pmin" "$pmax")" "code=bad_arg"
                return 2
            fi
        fi

        if [ -n "$penum" ]; then
            ok=0
            local _list=()
            IFS=',' read -ra _list <<< "$penum"
            for e in "${_list[@]}"; do
                [ "$val" = "$e" ] && { ok=1; break; }
            done
            if [ "$ok" != "1" ]; then
                ga_emit_json error "$(tf act_bad_enum "$p" "$penum")" "code=bad_arg"
                return 2
            fi
        fi

        if [ -n "$pat" ]; then
            _action_re_normalize "$pat"
            if ! _action_value_fits "$val"; then
                ga_emit_json error "$(tf act_bad_value "$p" "$val")" "code=bad_arg"
                return 2
            fi
        fi
    done <<< "$spec"
    return 0
}

# Сводка по всем профилям одним JSON-массивом (для status и profiles-status).
# Возвращает 1, если хоть один установленный профиль НЕ УДАЛОСЬ опросить.
# Раньше такой профиль молча выбрасывался, и ответ выглядел как «профилей нет»:
# на битом users.json живая установка с двумя работающими контейнерами
# отвечала пустым списком со словом «успешно», а соседнее поле в том же ответе
# перечисляло эти самые контейнеры. Ответ противоречил сам себе.
_profiles_status_json() {
    local out="[]" p js rc=0
    command -v jq >/dev/null 2>&1 || { printf '[]'; return 0; }
    type amnezia_profile_status >/dev/null 2>&1 || { printf '[]'; return 0; }
    for p in $PROFILE_IDS; do
        _profile_installed "$p" || continue
        js=$(amnezia_profile_status "$p" 2>/dev/null) || js=""
        if ! printf '%s' "$js" | jq -ce . >/dev/null 2>&1; then
            # Профиль установлен, а опросить его нечем: это отказ, а не пустота.
            rc=1
            continue
        fi
        out=$(jq -nc --argjson acc "$out" --argjson item "$js" '$acc + [$item]' 2>/dev/null) || out="$out"
    done
    # Движок AmneziaWG каждого профиля (lib/kmod.sh): engine — фактический, engine_want — выбранный. live (profiles-status)
    # — живой опрос контейнера, иначе (status) — кэш; модуля в памяти нет — program без похода в Docker.
    type ga_kmod_profiles_enrich >/dev/null 2>&1 && out=$(ga_kmod_profiles_enrich "$out" "${1:-}")
    printf '%s' "$out"
    return "$rc"
}

# Линии на сервере для status (DUP-LINE-01): ga_amn_lines_check — {no_20, shared, missing, reline, text}; без модуля —
# пустая картина. free_lines — {место: линия} свободных мест (ga_amn_free_lines).
_lines_check_json() {
    local js
    type ga_amn_lines_check >/dev/null 2>&1 || { printf '{"no_20":false,"shared":[],"missing":[],"reline":null,"text":""}'; return 0; }
    js=$(ga_amn_lines_check 2>/dev/null) || js=""
    _as_json "$js" '{"no_20":false,"shared":[],"missing":[],"reline":null,"text":""}'
}
_dupline_fix_json() {
    local js
    type ga_amn_dupline_fix_json >/dev/null 2>&1 || { printf 'null'; return 0; }
    js=$(ga_amn_dupline_fix_json 2>/dev/null) || js=null
    _as_json "${js:-null}" null
}
# _reline_steps_fill <имя переменной lines_check> <имя переменной dupline_fix> — окну согласия «Переставить на 2.0» в
# панели и боте: steps — у каждого пользователя его действие после перестановки (ga_amn_reline_preview, решение
# координатора 15.10) в lines_check.reline и dupline_fix. Один расчёт на профиль: оба поля обычно о том же профиле
# (N-3 проверки 15.10). Только полный status: brief (Обзор раз в 10 с) их не несёт — окно согласия панели берёт их
# отдельным запросом. И не в шапке SSH: там хватает строки (D-1).
_reline_steps_fill() {
    local -n _rs_lc="$1" _rs_df="$2"
    local p1 p2 st1='' st2=''
    type ga_amn_reline_preview >/dev/null 2>&1 || return 0
    p1=$(jq -r '.reline.profile? // empty' <<<"$_rs_lc" 2>/dev/null)
    p2=$(jq -r '.profile? // empty' <<<"$_rs_df" 2>/dev/null)
    if [ -n "$p1" ]; then
        st1=$(_reline_preview_json "$p1")
        _rs_lc=$(jq -c --argjson st "$st1" '.reline.steps = $st' <<<"$_rs_lc" 2>/dev/null || printf '%s' "$_rs_lc")
    fi
    if [ -n "$p2" ]; then
        if [ "$p2" = "$p1" ]; then st2="$st1"; else st2=$(_reline_preview_json "$p2"); fi
        _rs_df=$(jq -c --argjson st "$st2" '.steps = $st' <<<"$_rs_df" 2>/dev/null || printf '%s' "$_rs_df")
    fi
    return 0
}
_reline_preview_json() {
    local st
    st=$(ga_amn_reline_preview "$1" 2>/dev/null) || st='[]'
    jq -e 'type == "array"' >/dev/null 2>&1 <<<"$st" || st='[]'
    printf '%s' "$st"
}
_free_lines_json() {
    local js
    type ga_amn_free_lines >/dev/null 2>&1 || { printf '{}'; return 0; }
    js=$(ga_amn_free_lines 2>/dev/null) || js='{}'
    _as_json "$js" '{}'
}

# Пересечения подсетей профилей для status и profiles-status (SUBNET-01): ga_amn_subnet_overlaps — запись на
# профиль {profile, subnet, with, fixed, move: {profile, subnet, keyless} | null}; без модуля или пересечений — [].
_subnet_overlaps_json() {
    local js
    type ga_amn_subnet_overlaps >/dev/null 2>&1 || { printf '[]'; return 0; }
    js=$(ga_amn_subnet_overlaps 2>/dev/null) || js='[]'
    _as_json "$js" '[]'
}

# Порты установленных профилей для status: [{profile, port, proto, listening,
# ours, container, state}]. Пакетный путь preflight (ga_pf_collect один раз на
# все профили, затем ga_pf_owner по порту) — один ss и один docker ps, а не по
# вызову на профиль: status дёргают бот и панель на каждом экране.
# listening=false у включённого профиля — верный признак, что контейнер не
# слушает свой порт. Все профили продукта — AmneziaWG, то есть UDP.
_ga_profile_ports_json() {
    local acc="[]" p port proto js
    command -v jq >/dev/null 2>&1 || { printf '[]'; return 0; }
    type ga_pf_collect >/dev/null 2>&1 || { printf '[]'; return 0; }
    ga_pf_collect tcp udp
    for p in $PROFILE_IDS; do
        _profile_installed "$p" || continue
        port=$(_cfg ".profiles.$p.port"); [[ "$port" =~ ^[0-9]+$ ]] || continue
        proto="udp"
        js=$(ga_pf_owner "$proto" "$port" 2>/dev/null) || continue
        printf '%s' "$js" | jq -e . >/dev/null 2>&1 || continue
        acc=$(jq -nc --argjson acc "$acc" --arg p "$p" --arg proto "$proto" --argjson o "$js" \
              '$acc + [{profile:$p, port:$o.port, proto:$proto, listening:($o.state == "busy"),
                        ours:$o.ours, container:$o.container, state:$o.state}]' 2>/dev/null) || acc="$acc"
    done
    printf '%s' "$acc"
}

action_dispatch() {
    local name="" a rc
    for a in "$@"; do
        case "$a" in --action=*) name="${a#--action=}"; break ;; esac
    done

    # Язык ответа — на один вызов (L-24): слова моста (message, подсказки) шли на языке установки, и админ,
    # говорящий с ботом по-английски на русском сервере, получал итоги по-русски. Бот и панель ставят
    # GOAMNEZIA_CALL_LANG=ru|en — язык того, кто нажал; словарь переключается только в этом процессе (каждый
    # вызов моста — отдельный процесс), config.json и язык установки не трогаются. Нет переменной или она не
    # ru/en — язык установки, как раньше.
    case "${GOAMNEZIA_CALL_LANG:-}" in
        ru|en)
            if [ "$GOAMNEZIA_CALL_LANG" != "${LANG_CODE:-}" ] && type load_language >/dev/null 2>&1; then
                load_language "$GOAMNEZIA_CALL_LANG"
            fi ;;
    esac

    # jq и actions.json — фундамент моста: без них нельзя даже понять, что за
    # действие просят. Отвечаем кодом, а не молчанием.
    if ! command -v jq >/dev/null 2>&1; then
        ga_emit_json error "$(t err_no_jq)" "code=deps_missing"
        return 1
    fi
    if [ ! -f "$ACTIONS_JSON" ]; then
        ga_emit_json error "$(tf act_no_actions_json "$ACTIONS_JSON")" "code=actions_json_missing"
        return 1
    fi
    if ! _action_known "$name"; then
        ga_emit_json error "$(tf act_unknown "$name")" "code=unknown_action"
        return 2
    fi

    _action_parse_args "$@" || return 2
    _action_validate_args "$name" || return 2

    _action_meta "$name"
    if [ "$GA_ACT_READONLY" = "true" ] || _action_own_lock "$name"; then
        _action_dispatch_locked "$name"
        return $?
    fi

    # Один замок на все интерфейсы (SSH, бот, панель, MCP): иначе прямые записи
    # из панели и мост сериализуются независимо и гонятся за один и тот же файл.
    mkdir -p "$LOCK_DIR" 2>/dev/null || true
    [ -e "$LOCK_FILE" ] || { : > "$LOCK_FILE"; } 2>/dev/null || true

    # Таймер (юниты goamnezia-*.service ставят GOAMNEZIA_WHO=timer) ждёт замок дольше, а не дождался — это «занято —
    # пропущено, следующий запуск по таймеру» с кодом 0: установка и обновление держат замок минутами, и юнит
    # проверки сертификата падал в failed посреди установки (жалоба 29.09.2026). Остальные — 30 с и lock_timeout.
    # Таймер ждёт остаток общего бюджета тика: часть его уже могла уйти на замок миграции (main, GA_TIMER_LOCK_DEADLINE).
    local lock_wait=30 timer_call=0
    if [ "${GOAMNEZIA_WHO:-}" = timer ]; then
        timer_call=1
        lock_wait=$(ga_timer_lock_wait 2>/dev/null) || lock_wait=120
    fi
    if command -v flock >/dev/null 2>&1 && [ -r "$LOCK_FILE" ]; then
        (
            flock -w "$lock_wait" 9 || {
                if [ "$timer_call" = 1 ]; then
                    log_warning "$(tf timer_busy_skipped "$name")"
                    ga_emit_json success "$(tf timer_busy_skipped "$name")" "code=busy" "skipped=@json:true" "tick=$name"
                    exit 0
                fi
                ga_emit_json error "$(t lock_timeout)" "code=lock_timeout"
                exit 75   # EX_TEMPFAIL
            }
            # Замок этого файла уже наш: вложенные ga_with_config_lock внутри
            # модулей должны выполнить тело, а не ждать тот же файл — иначе
            # взаимоблокировка на ровном месте.
            GA_CONFIG_LOCK_HELD=1 _action_dispatch_locked "$name"
        ) 9<"$LOCK_FILE"
        rc=$?
        return $rc
    fi

    # flock нет или /run недоступен (контейнер, тестовый стенд) — работаем без
    # сериализации, но громко предупреждаем: молча терять замок нельзя.
    log_warning "$(t act_no_flock)"
    _action_dispatch_locked "$name"
}

# Ветки действий. Метки case сверяются с lib/actions.json тестом
# tests/check_actions.py — новое действие добавляется в ОБА места.
_action_dispatch_locked() {
    local name="$1"
    # Общие для веток временные значения объявляем здесь: local внутри case
    # оставил бы их глобальными для остальных веток, а под set -u ещё и роняет
    # на первом же обращении в ветке, где присвоения не было.
    local out js j m d

    # Частые вызовы (CPU-03): читающее действие берёт config.json одним проходом jq на весь вызов
    # (ga_config_memo_load), а действия, которые ходят в Docker по каждому профилю, закрепляют версию API демона
    # здесь, в этой оболочке, — подоболочки $(…) наследуют закрепление, а не спрашивают демон заново каждая.
    [ "$GA_ACT_READONLY" = true ] && type ga_config_memo_load >/dev/null 2>&1 && ga_config_memo_load
    case "$name" in
        traffic|status|profiles-status|watch-tick|quota-tick|stats-tick)
            type docker_api_pin >/dev/null 2>&1 && docker_api_pin ;;
    esac

    case "$name" in
        status)
            # Битый config.json или users.json — отказ с кодом, а не «установлено: нет, профилей нет»:
            # по такой картине бот рисовал «Установить», панель — «не установлено», а агент читал
            # installed=false (находка SR-46, 25.09.2026; CONTRACT §0 п.5).
            ga_config_intact 2>/dev/null || { _action_fail config_corrupt "$(t err_config_unreadable)"; return 1; }
            ga_users_intact 2>/dev/null || { _action_fail users_corrupt "$(t users_err_corrupt)"; return 1; }
            local inst="false"
            [ "$(_cfg '.installed')" = "true" ] && inst="true"
            # lang — язык ядра (lang-set его меняет; панель и бот берут умолчание
            # отсюда; в старом конфиге поля нет — маркер .language, как при запуске),
            # ports — слушают ли контейнеры свои порты (PLAN §4.3.1). Язык этого вызова
            # (GOAMNEZIA_CALL_LANG, L-24) сюда не попадает: lang — язык установки.
            local lang sip eh_gone=false
            lang=$(_cfg '.lang')
            [ -n "$lang" ] || lang=$(type detect_language >/dev/null 2>&1 && detect_language || echo ru)
            sip=$(_server_ip)
            # Вписанного в ключи IP на машине больше нет (переезд, снятый адрес) — ключи с ним не соединятся
            # (находка SR-45); намеренно чужой адрес (проброс) пропавшим не считается.
            type ga_export_endpoint_host_gone >/dev/null 2>&1 && ga_export_endpoint_host_gone && eh_gone=true
            # brief=on — сводка для частых опросов (Обзор панели раз в 10 с, CPU-03): без проверок, которые дороги и
            # меняются не сами по себе, — порты профилей (ss, docker ps, файрвол), сайт и сертификат, адреса в ключах
            # людей, расхождение режима с портами и действующий адрес в ключах. Поля в brief отсутствуют целиком, а
            # не null: «не проверяли» не выдаётся за «проверили — пусто». Без brief ответ прежний, поле в поле.
            local brief=0
            [ "${ARG_brief:-}" = on ] && brief=1
            local -a sf=("version=${GOAMNEZIA_VERSION}" "installed=@json:${inst}" "mode=$(_cfg '.mode')" "lang=${lang}" \
                "domain=$(_cfg '.domain')" "server_ip=${sip}" "endpoint_host=$(_cfg '.endpoint_host')" \
                "endpoint_host_gone=@json:${eh_gone}" "server_ip_change=@json:$(_server_ip_change_json)" \
                "upstream=@json:$(_upstream_summary_json)")
            [ "$brief" = 1 ] || sf+=("endpoint_effective=$(_endpoint_effective "$sip")" "endpoint_auto=$(_endpoint_auto "$sip")")
            sf+=("users=@json:$(_users_count)" "profiles=@json:$(_profiles_status_json)")
            # Линии на сервере (DUP-LINE-01) — и в brief: только config.json. lines_check — нет 2.0 (старые приложения
            # и Keenetic не подключатся), две одинаковые линии, «Переставить на 2.0»; free_lines — какая линия встанет
            # на свободное место по «Установить».
            # «Ошибка прошлых версий» (флаг миграции dupline_bug, решение владельца 15.10) — и в brief: Обзор панели и
            # главный экран бота держат сообщение с «Исправить», пока сервер в том состоянии. Кому что сделать после
            # перестановки (steps) — только без brief, один расчёт на оба поля (N-3).
            local lcj dfj
            lcj=$(_lines_check_json)
            dfj=$(_dupline_fix_json)
            [ "$brief" = 1 ] || _reline_steps_fill lcj dfj
            sf+=("lines_check=@json:${lcj}" "free_lines=@json:$(_free_lines_json)")
            sf+=("dupline_fix=@json:${dfj}")
            [ "$brief" = 1 ] || sf+=("ports=@json:$(_ga_profile_ports_json)" \
                "mode_port_mismatch=@json:$(_mode_port_mismatch && echo true || echo false)")
            # Пересечение подсетей профилей и выход из него (SUBNET-01): экраны подсети бота и панели.
            [ "$brief" = 1 ] || sf+=("subnet_overlaps=@json:$(_subnet_overlaps_json)")
            sf+=("client_isolation=@json:$(ga_amn_isolation_on 2>/dev/null && echo true || echo false)")
            [ "$brief" = 1 ] || sf+=("site=@json:$(_site_status_json)" "key_hosts=@json:$(_key_hosts_json)")
            # Срок забора подписки (R9-1): окно «Исправить S4» бота — без обхода подписок; только без brief.
            [ "$brief" = 1 ] || sf+=("subs_update=@json:$(_subs_update_json)")
            sf+=("update_rollback=@json:$(_ga_update_rollback_json)" "disk=@json:$(_ga_disk_status_json)")
            # Пакет Docker обновлён, а служба старая (DK-02) — и в brief: по нему «Обзор» держит строку-предупреждение.
            sf+=("docker_stale=@json:$(_ga_docker_stale_status_json)")
            # Модуль ядра AmneziaWG на хосте (KMOD_PLAN А3) — и в brief: чтение одного файла в /sys, без Docker.
            sf+=("kmod=@json:$(_ga_kmod_status_json)")
            ga_emit_json success "$(t act_ok)" "${sf[@]}"
            ;;

        profiles-status)
            # Битый config.json или users.json — отказ с кодом, а не «установлено: нет, профилей нет»:
            # по такой картине бот рисовал «Установить», панель — «не установлено», а агент читал
            # installed=false (находка SR-46, 25.09.2026; CONTRACT §0 п.5).
            ga_config_intact 2>/dev/null || { _action_fail config_corrupt "$(t err_config_unreadable)"; return 1; }
            ga_users_intact 2>/dev/null || { _action_fail users_corrupt "$(t users_err_corrupt)"; return 1; }
            # ga_capture, а не подстановка: код «профиль опросить не удалось»
            # обязан дойти до бота, панели и агента. Пустой список со словом
            # «успешно» на живой установке — это ложная картина «продукт не
            # установлен», и бот по ней рисует кнопку «Установить».
            # live — движок каждого профиля живым опросом контейнера (lib/kmod.sh), а не кэшем, как в status.
            if ! ga_capture out _profiles_status_json live; then
                _action_fail profiles_unreadable
                return 1
            fi
            ga_emit_json success "$(t act_ok)" "profiles=@json:${out:-[]}" "subnet_overlaps=@json:$(_subnet_overlaps_json)" \
                "kmod=@json:$(_ga_kmod_status_json)"
            ;;

        quality)
            ga_emit_json success "$(t act_ok)" "quality=@json:$(_ga_quality_json)"
            ;;

        traffic)
            # Битый config.json или users.json — отказ с кодом, а не «установлено: нет, профилей нет»:
            # по такой картине бот рисовал «Установить», панель — «не установлено», а агент читал
            # installed=false (находка SR-46, 25.09.2026; CONTRACT §0 п.5).
            ga_config_intact 2>/dev/null || { _action_fail config_corrupt "$(t err_config_unreadable)"; return 1; }
            ga_users_intact 2>/dev/null || { _action_fail users_corrupt "$(t users_err_corrupt)"; return 1; }
            local acc="" sep="" p
            if type amnezia_show >/dev/null 2>&1; then
                for p in $PROFILE_IDS; do
                    _profile_installed "$p" || continue
                    # amnezia_show печатает массив, собранный jq, или падает — тогда у профиля пусто. Склейка строкой,
                    # а не jq на каждый профиль (CPU-03); имя профиля — из PROFILE_IDS, кавычкам в нём взяться неоткуда.
                    js=$(amnezia_show "$p" 2>/dev/null) || js=""
                    case "$js" in "["*"]") ;; *) js="[]" ;; esac
                    acc+="${sep}{\"profile\":\"${p}\",\"peers\":${js}}"; sep=","
                done
            fi
            acc="[${acc}]"
            # Суточные итоги из stats.json (lib/stats.sh, таймер goamnezia-stats):
            # «трафик за сутки» в панели и боте; без модуля — null. hours — почасовые корзины за 168 часов для
            # карты активности 7×24 и вида «24 часа» (HM-1); без модуля или без сбора — пустой список.
            # Четыре поля сводки — одним jq, по строке на поле (CPU-03); сводки нет или она не JSON — прежние null и [].
            local st="" st_today='null' st_month='null' st_days='[]' st_hours='[]'
            local -a stf=()
            if type stats_summary >/dev/null 2>&1; then
                st=$(stats_summary 2>/dev/null) || st=""
                if [ -n "$st" ]; then
                    mapfile -t stf < <(printf '%s' "$st" | jq -c '(.today // null), (.month // null), (.days // []), (.hours // [])' 2>/dev/null)
                    if [ "${#stf[@]}" = 4 ]; then
                        st_today="${stf[0]}"; st_month="${stf[1]}"; st_days="${stf[2]}"; st_hours="${stf[3]}"
                    fi
                fi
            fi
            ga_emit_json success "$(t act_ok)" "profiles=@json:${acc}" "users=@json:$(_users_json)" \
                "today=@json:${st_today}" "month=@json:${st_month}" "days=@json:${st_days}" "hours=@json:${st_hours}"
            ;;

        logs-tail)
            # Отказ не выдаём за пустой лог: «контейнера нет» и «драйвер логов не
            # отдаёт строк» — разные поломки, и чинят их по-разному (DEFECTS §3.8).
            _action_run logs_failed _ga_logs_tail "$(_arg component)" "$(_arg lines)" || return 1
            ga_emit_json success "$(t act_ok)" \
                "component=$(_arg component)" "lines=@json:$(_arg lines)" \
                "log=@json:$(printf '%s' "$out" | jq -Rs . 2>/dev/null || printf '""')"
            ;;

        logs-enforce)
            # Бюджет логов применялся только таймером раз в сутки: человеку,
            # у которого кончается место, ждать было нечего — руками применить
            # было нечем (DEFECTS §5.4).
            _require_fn logb_enforce || return 1
            _action_run logs_failed logb_enforce || return 1
            # Сам модуль пишет не в stdout, а в своё состояние: оттуда и берём
            # строку «что подрезали» — иначе ответ был бы пустым «успехом».
            ga_emit_json success "$(t act_ok)" \
                "trimmed=$({ tail -n 1 "${LOGB_STATE:-/run/goamnezia-logbudget.state}"; } 2>/dev/null | cut -c1-300)"
            ;;

        logs-status)
            _require_fn logb_status || return 1

            # logb_status печатает строки «имя занято_МБ бюджет_МБ процент»
            # (последние две — docker и free); в JSON переводим здесь, чтобы
            # модуль остался без знания про формат моста.
            #
            # Имена в этих строках — УЧАСТКИ ДИСКА (journal, nginx, goamnezia,
            # docker, free), а не источники логов из logs-tail: читать по ним
            # нечего, считают там занятое место. Пока поле называлось component,
            # список звал подставить своё имя в logs-tail --component, где из
            # пяти имён подходило одно (DEFECTS §3.9).
            _action_run logs_failed logb_status || return 1
            # Последняя строка модуля — «free»: это СВОБОДНОЕ место на диске, а не
            # занятое. Лежащее в том же поле used_mb, оно означало ровно обратное
            # соседним строкам: панель спасалась частным случаем, бот и агент —
            # ничем (DEFECTS §5.3). Отдаём его отдельным полем free_mb, а в areas
            # оставляем только то, что действительно занято.
            ga_emit_json success "$(t act_ok)" \
                "areas=@json:$(printf '%s' "$out" | jq -Rn '
                    [ inputs | select(length > 0) | split(" ") | select(.[0] != "free")
                      | {area: .[0], used_mb: (.[1] // "0"), budget_mb: (.[2] // "-"), percent: (.[3] // "-")} ]' \
                    2>/dev/null || printf '[]')" \
                "free_mb=$(printf '%s' "$out" | awk '$1 == "free" {print $2; exit}' 2>/dev/null)"
            ;;

        profile-install)
            _require_fn amnezia_profile_install || return 1
            _action_run install_failed amnezia_profile_install "$(_arg profile)" "$(_arg port)" "$(_arg preset)" "$(_arg subnet)" \
                "$(_arg line)" || return 1
            # Первый профиль через мост = установка состоялась: ставим таймеры.
            _ga_mark_installed >&2
            ga_emit_json success "$(tf act_profile_installed "$(_arg profile)")" \
                "profile=$(_arg profile)" "result=@json:$(_as_json "$out" '{}')"
            ;;

        profile-remove)
            _require_fn amnezia_profile_remove || return 1
            _action_run remove_failed amnezia_profile_remove "$(_arg profile)" || return 1
            ga_emit_json success "$(tf act_profile_removed "$(_arg profile)")" "profile=$(_arg profile)"
            ;;

        profile-restart)
            _require_fn amnezia_profile_restart || return 1
            _action_run restart_failed amnezia_profile_restart "$(_arg profile)" || return 1
            ga_emit_json success "$(tf act_profile_restarted "$(_arg profile)")" "profile=$(_arg profile)"
            ;;

        profiles-restart)
            # «Перезапустить все профили» одним действием (L-12, docs/DESIGN_ITERATION3_ACCEPTANCE.md §4.1): по
            # установленным профилям в порядке меню (3.1 → 2.0 → 1.x), каждый — тем же amnezia_profile_restart, что
            # у profile-restart. Службы (бот, панель, MCP, nginx) не трогаются: это действие зовут они сами, и
            # перезапуск вызывающего оборвал бы ответ. Не поднялся хоть один — отказ restart_failed, в ответе оба
            # списка: какие перезапущены и какие нет (с кодом и словами модуля).
            _require_fn amnezia_profile_restart || return 1
            local rp rdone="[]" rfail="[]" rn=0
            for rp in $PROFILE_IDS; do
                _profile_installed "$rp" || continue
                rn=$((rn + 1))
                GA_ERR_CODE=""; GA_ERR_MSG=""; GA_LAST_ERROR_CODE=""
                if ga_capture out amnezia_profile_restart "$rp"; then
                    rdone=$(jq -c --arg p "$rp" '. + [$p]' <<<"$rdone")
                else
                    rfail=$(jq -c --arg p "$rp" --arg c "${GA_ERR_CODE:-${GA_LAST_ERROR_CODE:-restart_failed}}" \
                        --arg m "${GA_ERR_MSG:-}" '. + [{profile: $p, code: $c, message: $m}]' <<<"$rfail")
                fi
            done
            if [ "$rn" -eq 0 ]; then
                ga_emit_json error "$(t act_profiles_restart_none)" "code=no_profiles" \
                    "restarted=@json:[]" "failed=@json:[]"
                return 1
            fi
            if [ "$(jq 'length' <<<"$rfail")" != 0 ]; then
                ga_emit_json error "$(tf act_profiles_restart_failed "$(jq -r 'map(.profile) | join(", ")' <<<"$rfail")")" \
                    "code=restart_failed" "restarted=@json:${rdone}" "failed=@json:${rfail}"
                return 1
            fi
            ga_emit_json success "$(tf act_profiles_restarted "$(jq -r 'join(", ")' <<<"$rdone")")" \
                "restarted=@json:${rdone}" "failed=@json:[]"
            ;;

        docker-restart)
            # «Перезапустить Docker» (DK-02): служба Docker целиком — пакет обновлён, а служба старая (сторож сделает
            # это сам, когда к VPN никто не подключён), или Docker ведёт себя странно. Профили поднимаются тем же путём,
            # что после перезапуска профиля: интерфейс, порт, изоляция, соседи, goWARP. Рвёт связь всем на 10–30 с —
            # разрушительное: в MCP уровень admin и confirm, в панели и боте — вопрос перед нажатием. Ответ — итог модуля
            # (duration_s, restarted[], failed[], daemon_before, daemon_after, binary_version, stale); отказ — с кодом
            # модуля (docker_restart_failed, docker_restart_timeout, docker_still_stale, restart_failed) и ручной
            # командой в command.
            _require_fn amnezia_docker_restart || return 1
            local dr_rc=0
            GA_ERR_CODE=""; GA_ERR_MSG=""; GA_LAST_ERROR_CODE=""
            ga_capture out amnezia_docker_restart manual || dr_rc=$?
            out=$(_as_json "$out" '{}')
            if [ "$dr_rc" != 0 ]; then
                local dr_code="${GA_ERR_CODE:-${GA_LAST_ERROR_CODE:-docker_restart_failed}}"
                out=$(jq -c --arg c "$dr_code" '. + {code: $c, command: "systemctl restart docker"}' <<<"$out" 2>/dev/null) \
                    || out=$(jq -cn --arg c "$dr_code" '{code: $c, command: "systemctl restart docker"}')
                _action_emit_merged error "${GA_ERR_MSG:-$(t act_failed)}" "$out"
                return 1
            fi
            _action_emit_merged success "$(tf act_docker_restarted "$(_json_field "$out" .duration_s)" \
                "$(_json_field "$out" ".daemon_after_label // .daemon_after")")" "$out"
            ;;

        # Модуль ядра AmneziaWG по выбору человека (docs/KMOD_PLAN.md, этап Б; договор — CONTRACT §4.7a): ветки — в
        # lib/kmod.sh (ga_kmod_bridge). kmod-status и kmod-check только читают; kmod-install, kmod-engine и kmod-remove —
        # долгие изменения с ходом в журнале действий и в kmod-status.progress.
        kmod-status|kmod-check|kmod-install|kmod-engine|kmod-remove)
            _require_fn ga_kmod_bridge || return 1
            ga_kmod_bridge "$name" || return $?
            ;;

        # Починка пропавшего контейнера из копии состояния. Функция жила в
        # модуле с самого начала (amnezia_state_restore поднимает контейнер без
        # перевыпуска ключей и без архива), но кнопки не было нигде: и сторож, и
        # бот советовали восстановление из бэкапа — самое разрушительное
        # действие продукта там, где хватает одного docker run.
        profile-repair)
            _require_fn amnezia_profile_repair || return 1
            _action_run repair_failed amnezia_profile_repair "$(_arg profile)" || return 1
            ga_emit_json success "$(tf act_profile_repaired "$(_arg profile)")" "profile=$(_arg profile)"
            ;;

        backup-schedule)
            _require_fn set_backup_schedule || return 1
            _action_run schedule_failed set_backup_schedule "$(_arg frequency)" || return 1
            ga_emit_json success "$(tf act_backup_schedule "$(_arg frequency)")" "frequency=$(_arg frequency)"
            ;;

        backup-last)
            _require_fn backup_last_json || return 1
            _action_run backup_failed backup_last_json || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        profile-port)
            _require_fn amnezia_profile_set_port || return 1
            # «07078» — порт 7078: иначе сообщение повторяло сырой ввод, поле port в ответе было негодным
            # JSON-числом, а «0443» обходило проверку занятого 443 ниже (находка LC-09).
            local pport
            pport=$(_arg port)
            [[ "$pport" =~ ^[0-9]{1,6}$ ]] && pport=$((10#$pport))
            # UDP/443 держит ровно один профиль (PLAN §4.4): проверяем ДО
            # пересоздания контейнера, иначе docker откажет уже после сноса.
            if [ "$pport" = "443" ]; then
                local other busy=""
                for other in $PROFILE_IDS; do
                    [ "$other" = "$(_arg profile)" ] && continue
                    [ "$(_cfg ".profiles.$other.port")" = "443" ] && busy="$other"
                done
                if [ -n "$busy" ]; then
                    ga_emit_json error "$(tf pr_443_taken "$busy")" "code=port_taken"
                    return 1
                fi
            fi
            # Профиль с людьми приложения Amnezia без ключа на сервере модуль без согласия не переносит (ACC-2):
            # бот, панель и агент получают отказ adopted_keyless с объяснением, а не тихо отрезанных людей.
            _action_run port_failed amnezia_profile_set_port "$(_arg profile)" "$pport" "$(_arg adopted_confirm)" || return 1
            ga_emit_json success "$(tf act_profile_port "$(_arg profile)" "$pport")" \
                "profile=$(_arg profile)" "port=@json:$pport" "mode=$(_mode_current)"
            ;;

        # ── Настройки профиля как в приложении Amnezia (PLAN §10 п.9) ────────
        # Модуль отдаёт JSON: scope (server|client) и reissue_required — по
        # ним бот и MCP решают, предупреждать ли о перевыпуске конфигов; restarted — профиль перезапускался
        # (серверный параметр или маскировка на модуле ядра, KMOD-01): клиенты переподключатся сами за 15–25 с.
        profile-set-param)
            _require_fn amnezia_profile_set_param || return 1
            _action_run param_set_failed amnezia_profile_set_param "$(_arg profile)" "$(_arg key)" "$(_arg value)" || return 1
            # PARAM-11 (1.0.13): кому нужен новый конфиг — одной фразой в message (бот показывает его как есть),
            # clients_update — в корне, по людям и словами — result.audience и result.steps.
            # Значение параметра-ключа (HeaderProtectionKey) — ни в сообщение, ни в поле value: «задан (скрыт)» и «***»
            # (ga_amn_param_shown, KEENETIC-I1-N N4) — сообщение бот и панель показывают как есть.
            local pv pvj psum
            pv=$(ga_amn_param_shown "$(_arg key)" "$(_arg value)"); pvj=$(ga_amn_param_shown "$(_arg key)" "$(_arg value)" json)
            psum=$(_json_field "$out" .summary)
            ga_emit_json success "$(tf act_profile_param "$(_arg profile)" "$(_arg key)" "$pv")${psum:+ $psum}" \
                "profile=$(_arg profile)" "key=$(_arg key)" "value=$pvj" \
                "reissue_required=@json:$(_as_json "$(printf '%s' "$out" | jq -c '.reissue_required // false' 2>/dev/null)" 'false')" \
                "restarted=@json:$(_as_json "$(printf '%s' "$out" | jq -c '.restarted // false' 2>/dev/null)" 'false')" \
                "clients_update=@json:$(_as_json "$(printf '%s' "$out" | jq -c '.clients_update // false' 2>/dev/null)" 'false')" \
                "result=@json:$(_as_json "$out" '{}')"
            ;;

        # S4-FIX (MTU-01, решение владельца 08.10): выданный профиль 2.0 с большим S4 — новый S4 12–24 тем же путём, что
        # серверный параметр (profile-set-param). Подхваченный у приложения с людьми без ключа на сервере — только с
        # adopted_confirm=<тот профиль>, иначе adopted_keyless до всякого изменения; риска нет — s4_safe. В ответе —
        # поля модуля (s4_old, s4, packet, restarted, кому что делать: subscription, page, key, app, steps словами).
        profile-fix-s4)
            _require_fn amnezia_profile_fix_s4 || return 1
            _action_run s4_fix_failed amnezia_profile_fix_s4 "$(_arg profile)" "$(_arg adopted_confirm)" || return 1
            local s4sum
            s4sum=$(_json_field "$out" .summary)
            _action_emit_merged success "${s4sum:-$(t act_ok)}" "$out"
            ;;

        profile-reline)
            # «Переставить на 2.0» (DUP-LINE-01): свой профиль, который повторяет линию другого, — на вторую линию пары;
            # профиль приложения — отказ reline_adopted. Ответ — кому что сделать, как у profile-fix-s4. keys_to_others=on —
            # ключ на новой линии и остальным пользователям тем же действием (DUPLINE-KEYS-01): others, others_failed.
            _require_fn amnezia_profile_reline || return 1
            _action_run reline_failed amnezia_profile_reline "$(_arg profile)" "$(_arg line)" "$(_arg keys_to_others)" || return 1
            local rlsum
            rlsum=$(_json_field "$out" .summary)
            _action_emit_merged success "${rlsum:-$(t act_ok)}" "$out"
            ;;

        profile-subnet)
            _require_fn amnezia_profile_set_subnet || return 1
            # Как у переноса порта (ACC-2): профиль с людьми приложения Amnezia без ключа на сервере — только с
            # adopted_confirm=<тот профиль>, иначе adopted_keyless до всякого изменения. Это и выход из пересечения
            # подсетей (SUBNET-01), когда переносить приходится подхваченный amnezia-awg2.
            _action_run subnet_failed amnezia_profile_set_subnet "$(_arg profile)" "$(_arg subnet)" "$(_arg adopted_confirm)" || return 1
            ga_emit_json success "$(tf act_profile_subnet "$(_arg profile)" "$(_arg subnet)")" \
                "profile=$(_arg profile)" "subnet=$(_arg subnet)" "result=@json:$(_as_json "$out" '{}')"
            ;;

        profile-mtu)
            _require_fn amnezia_profile_set_mtu || return 1
            _action_run mtu_failed amnezia_profile_set_mtu "$(_arg profile)" "$(_arg mtu)" || return 1
            # Что такой MTU сломает наверняка (решение владельца 08.10: 1280 — стандарт и минимум, предупреждаем только
            # о верном): warnings — код path (пакет больше 1440), warning — те же слова строкой, packet — пакет данных.
            local mchk mwarn="" mline
            mchk=$(ga_amn_mtu_check "$(_arg profile)" "$(_arg mtu)" 2>/dev/null) || mchk=""
            jq -e 'type == "object"' >/dev/null 2>&1 <<<"$mchk" || mchk='{"warnings":[],"packet":null}'
            while IFS= read -r mline; do [ -n "$mline" ] && mwarn="${mwarn:+$mwarn }$mline"; done \
                < <(ga_amn_mtu_warn_lines "$mchk")
            ga_emit_json success "$(tf act_profile_mtu "$(_arg profile)" "$(_arg mtu)")" \
                "profile=$(_arg profile)" "mtu=@json:$(_arg mtu)" \
                "packet=@json:$(_as_json "$(jq -c '.packet // null' <<<"$mchk")" null)" \
                "warnings=@json:$(_as_json "$(jq -c '.warnings // []' <<<"$mchk")" '[]')" "warning=$mwarn"
            ;;

        endpoint-set)
            _require_fn ga_set_endpoint_host || return 1
            # Пустой host — законное значение: «по умолчанию» — в Pro домен сервера, иначе его IP.
            _action_run endpoint_failed ga_set_endpoint_host "$(_arg host)" || return 1
            local shown; shown=$(_arg host); [ -n "$shown" ] || shown=$(_endpoint_effective)
            [ -n "$shown" ] || shown=$(_server_ip)
            # Та же проверка, что в SSH (_endpoint_check), но ответом, а не вопросом: бот, панель и
            # агент раньше молча записывали чужой IP и домен без A-записей (находка SR-44, 25.09.2026).
            local eh warn="" own dstate overridden
            eh=$(_arg host)
            if [ -n "$eh" ] && _valid_ip "$eh" && type ga_site_own_ips >/dev/null 2>&1; then
                own=$(ga_site_own_ips 2>/dev/null) || own=""
                if [ -n "$own" ] && ! grep -qxF -- "$eh" <<<"$own"; then warn="$(tf act_endpoint_not_on_server "$eh")"; fi
            elif [ -n "$eh" ] && type ga_site_dns_state >/dev/null 2>&1; then
                dstate=$(ga_site_dns_state "$eh" 2>/dev/null | jq -r '.state // ""' 2>/dev/null) || dstate=""
                case "$dstate" in
                    none|elsewhere|partial) warn="$(tf act_endpoint_dns_not_here "$eh")" ;;
                esac
                overridden=$(_users_json 2>/dev/null | jq -r '[.[] | select((.endpoint_ip // "") != "") | .name] | join(", ")' 2>/dev/null) || overridden=""
                [ -n "$overridden" ] && warn="${warn:+$warn }$(tf act_endpoint_users_overridden "$overridden")"
            fi
            ga_emit_json success "$(tf act_endpoint_set "${shown:--}")${warn:+ $warn}" \
                "endpoint_host=$(_arg host)" "effective_host=${shown}" "warning=${warn}"
            ;;

        profile-params)
            _require_fn amnezia_profile_params || return 1
            _action_run params_failed amnezia_profile_params "$(_arg profile)" || return 1
            ga_emit_json success "$(t act_ok)" "profile=$(_arg profile)" "params=@json:$(_as_json "$out" '{}')"
            ;;

        profile-regen)
            _require_fn amnezia_profile_regen || return 1
            _action_run regen_failed amnezia_profile_regen "$(_arg profile)" "$(_arg preset)" || return 1
            ga_emit_json success "$(tf act_profile_regen "$(_arg profile)")" \
                "profile=$(_arg profile)" "preset=$(_arg preset)" "result=@json:$(_as_json "$out" '{}')"
            ;;

        user-add)
            _require_fn users_add || return 1
            # Пустой --profiles= и отсутствующий --profiles — разные ответы
            # (CONTRACT §4.7). Отсутствующий значит «во все установленные», а
            # пустой приходит ровно оттуда, где человек снял все галочки: молча
            # понять его как «во все» — тихо завести ключи в линейках, которых
            # никто не просил, и человек о них не узнает. Проверка стоит в ядре,
            # а не только в панели: тем же пустым значением ходят бот и агент.
            if [[ -v ARG_profiles ]] && [ -z "$(_arg profiles)" ]; then
                ga_emit_json error "$(t act_no_profiles_picked)" "code=no_profiles_picked" \
                    "name=$(_arg name)"
                return 2
            fi
            _action_run user_add_failed users_add "$(_arg name)" "$(_arg label)" "$(_arg profiles)" "$(_arg quota_gb)" "$(_arg days)" || return 1
            # users_add молчит в stdout; в ответ кладём карточку (без ключей) —
            # боту и агенту сразу видны адреса пиров и профили.
            out=""
            if type users_show >/dev/null 2>&1; then
                out=$(users_show "$(_arg name)" 2>/dev/null) || out=""
            fi
            ga_emit_json success "$(tf act_user_added "$(_arg name)")" \
                "name=$(_arg name)" "result=@json:$(_as_json "$out" '{}')"
            ;;

        users-add-bulk)
            # «Добавить сразу несколько» (просьба владельца 03.10): до 100 человек тем же путём, что user-add, одним
            # применением к контейнерам. Пустой --profiles= — отказ, как у user-add (CONTRACT §4.7). Частичный сбой —
            # success с partial=true и failed {name, code, message}: заведённые до сбоя остаются, и сказать об этом
            # отказом было бы неправдой; никого не завели — отказ кодом первого сбоя.
            _require_fn users_add_bulk || return 1
            if [[ -v ARG_profiles ]] && [ -z "$(_arg profiles)" ]; then
                ga_emit_json error "$(t act_no_profiles_picked)" "code=no_profiles_picked"
                return 2
            fi
            _action_run users_add_failed users_add_bulk "$(_arg count)" "$(_arg profiles)" "$(_arg prefix)" \
                "$(_arg quota_gb)" "$(_arg days)" "$(_arg lang)" || return 1
            if [ "$(_json_bool "$out" .partial)" = true ]; then
                m=$(tf act_users_added_bulk_partial "$(_json_field "$out" .count)" "$(_json_field "$out" .requested)" \
                    "$(_json_field "$out" .failed.name)" "$(_json_field "$out" .failed.message)")
            else
                m=$(tf act_users_added_bulk "$(_json_field "$out" .count)")
            fi
            _action_emit_merged success "$m" "$out"
            ;;

        name-suggest)
            # «🎲 Случайное имя» (docs/MODES_047.md «Имена ключей»): вариант «прилагательное + столица» — только
            # чтение, ничего не занимает (имя забирает user-add). id и label — в корне ответа, как их ждут бот
            # (bot.py name_suggestion), панель и MCP; --lang не передан — язык установки.
            _require_fn users_name_suggest || return 1
            _action_run names_failed users_name_suggest "$(_arg lang)" "$(_arg exclude)" || return 1
            _action_emit_merged success \
                "$(tf act_name_suggested "$(_json_field "$out" .label)" "$(_json_field "$out" .id)")" "$out"
            ;;

        user-del)
            _require_fn users_del || return 1
            _action_run user_del_failed users_del "$(_arg name)" || return 1
            ga_emit_json success "$(tf act_user_deleted "$(_arg name)")" "name=$(_arg name)"
            ;;

        profile-remove-preview)
            # «Удалить профиль», до согласия (PROFILE-REMOVE-PAGES) — только чтение: у скольких ключ на профиле и чьи
            # страницы подключения перестанут работать (в них был только этот профиль). Само удаление не меняется.
            _require_fn ga_amn_remove_preview || return 1
            _action_run remove_failed ga_amn_remove_preview "$(_arg profile)" || return 1
            local rptext
            rptext=$(_json_field "$out" .text)
            _action_emit_merged success "${rptext:-$(t act_remove_preview)}" "$out"
            ;;

        users-del-bulk-preview)
            # «Удалить сразу несколько», шаг «кого задевает выбор» — только чтение: ровно один способ (--names,
            # --prefix или --state), ответ — mode, value, count, max, too_many, selected [{name, label}], missing.
            # count — то самое число для --confirm у users-del-bulk; сверка с ним — под замком в момент удаления.
            _require_fn users_del_bulk_preview || return 1
            _action_run users_failed users_del_bulk_preview "$(_arg names)" "$(_arg prefix)" "$(_arg state)" || return 1
            if [ "$(_json_bool "$out" .too_many)" = true ]; then
                m=$(tf act_users_del_bulk_preview_many "$(_json_field "$out" .count)" "$(_json_field "$out" .max)")
            else
                m=$(tf act_users_del_bulk_preview "$(_json_field "$out" .count)")
            fi
            _action_emit_merged success "$m" "$out"
            ;;

        users-del-bulk)
            # «Удалить сразу несколько» (просьба владельца 03.10): до 100 человек одним действием, порядок одиночного
            # удаления (выключить → применить → стереть), в контейнер — пачками. --confirm — число людей, которое
            # человек увидел в предпросмотре; не совпало с выбранным в момент исполнения — отказ до изменений, и в
            # ответе matched: сколько выбрано сейчас (так же у too_many и nothing_selected). Частичный итог —
            # success с partial=true, failed {name, code, message} и kept (оставлены в списке выключенными); никого
            # не удалили — отказ его кодом.
            _require_fn users_del_bulk || return 1
            GA_ERR_CODE=""; GA_ERR_MSG=""; GA_LAST_ERROR_CODE=""; GA_DB_MATCHED=""
            if ! ga_capture out users_del_bulk "$(_arg confirm)" "$(_arg names)" "$(_arg prefix)" "$(_arg state)"; then
                j="${GA_ERR_CODE:-${GA_LAST_ERROR_CODE:-user_del_failed}}"
                if [[ "${GA_DB_MATCHED:-}" =~ ^[0-9]+$ ]]; then
                    ga_emit_json error "${GA_ERR_MSG:-$(t act_failed)}" "code=$j" "matched=@json:$GA_DB_MATCHED"
                else
                    ga_emit_json error "${GA_ERR_MSG:-$(t act_failed)}" "code=$j"
                fi
                return 1
            fi
            if [ "$(_json_bool "$out" .partial)" = true ]; then
                m=$(tf act_users_deleted_bulk_partial "$(_json_field "$out" .count)" "$(_json_field "$out" .requested)" \
                    "$(_json_field "$out" .failed.name)" "$(_json_field "$out" .failed.message)")
            else
                m=$(tf act_users_deleted_bulk "$(_json_field "$out" .count)")
            fi
            _action_emit_merged success "$m" "$out"
            ;;

        user-list)
            # Битый users.json обязан быть виден как отказ, а не как пустой
            # список: иначе бот, панель и агент решат, что пользователей нет.
            _require_fn users_list || return 1
            _action_run users_failed users_list || return 1
            ga_emit_json success "$(t act_ok)" "users=@json:$out"
            ;;

        user-show)
            _require_fn users_show || return 1
            _action_run user_not_found users_show "$(_arg name)" || return 1
            # key_host — адрес в ключах этого человека как обычно (с его закреплённым адресом); key_host_gone —
            # закреплённого адреса на машине больше нет. Без похода в сеть: адрес сервера — из config.json.
            local ukh="" ukrc=0 ugone=false
            if type ga_export_endpoint_host >/dev/null 2>&1; then
                ukh=$(GA_EXPORT_SERVER_IP=$(_cfg '.server_ip') ga_export_endpoint_host "$(_arg name)" 2>/dev/null) || ukrc=$?
                [ "$ukrc" = 2 ] && ugone=true
            fi
            ga_emit_json success "$(t act_ok)" "name=$(_arg name)" "user=@json:$(_as_json "$out" '{}')" \
                "key_host=${ukh}" "key_host_gone=@json:${ugone}"
            ;;

        user-key)
            _require_fn export_bundle || return 1
            # endpoint — тот же ключ с другим адресом сервера этой машины, разово (docs/EDGEIPS.md §3.4).
            _action_run key_failed export_bundle "$(_arg name)" "$(_arg profile)" "$(_arg format)" "$(_arg endpoint)" || return 1
            out=$(_as_json "$out" '')
            if [ -z "$out" ]; then
                _action_fail key_failed
                return 1
            fi
            # Поля связки кладём в КОРЕНЬ ответа: MCP ищет qr_conf_png_b64 и
            # qr_vpn_png_b64 именно там, чтобы отдать их картинками (CONTRACT §5).
            local kv=() k
            while IFS= read -r k; do
                [ -n "$k" ] || continue
                kv+=( "${k}=@json:$(printf '%s' "$out" | jq -c --arg k "$k" '.[$k]' 2>/dev/null)" )
            done < <(printf '%s' "$out" | jq -r 'keys_unsorted[]' 2>/dev/null)
            ga_emit_json success "$(t act_ok)" "name=$(_arg name)" "profile=$(_arg profile)" \
                ${kv[@]+"${kv[@]}"}
            ;;

        user-rename)
            _require_fn users_rename || return 1
            _action_run rename_failed users_rename "$(_arg name)" "$(_arg label)" || return 1
            # Подпись — свободный текст: «@str:», чтобы «@json:true» не ушло в ответ булевым (SR-38).
            ga_emit_json success "$(tf act_user_renamed "$(_arg name)" "$(_arg label)")" \
                "name=$(_arg name)" "label=@str:$(_arg label)"
            ;;

        user-enable)
            _require_fn users_enable || return 1
            _action_run enable_failed users_enable "$(_arg name)" || return 1
            ga_emit_json success "$(tf act_user_enabled "$(_arg name)")" "name=$(_arg name)"
            ;;

        user-disable)
            _require_fn users_disable || return 1
            _action_run disable_failed users_disable "$(_arg name)" || return 1
            ga_emit_json success "$(tf act_user_disabled "$(_arg name)")" "name=$(_arg name)"
            ;;

        # re_enabled / enabled — включил ли новый лимит или срок человека, выключенного таймером («продлил —
        # включился сам»): модуль это отдаёт, а мост ронял, и бот с панелью узнать не могли (находка UP-2).
        user-quota)
            _require_fn users_set_quota || return 1
            _action_run quota_failed users_set_quota "$(_arg name)" "$(_arg quota_gb)" || return 1
            ga_emit_json success "$(tf act_user_quota "$(_arg name)" "$(_gb_or_unlimited "$(_arg quota_gb)")")" \
                "name=$(_arg name)" "quota_gb=@json:$(_arg quota_gb)" \
                "re_enabled=@json:$(_json_bool "$out" .re_enabled)" "enabled=@json:$(_json_bool "$out" .enabled)"
            ;;

        user-expiry)
            _require_fn users_set_expiry || return 1
            _action_run expiry_failed users_set_expiry "$(_arg name)" "$(_arg days)" || return 1
            ga_emit_json success "$(tf act_user_expiry "$(_arg name)" "$(_days_or_never "$(_arg days)")")" \
                "name=$(_arg name)" "days=@json:$(_arg days)" \
                "re_enabled=@json:$(_json_bool "$out" .re_enabled)" "enabled=@json:$(_json_bool "$out" .enabled)"
            ;;

        user-set-address)
            # Пустой --ip= — законное значение: «вернуть общий адрес»; не переданный вовсе отвергает
            # проверка аргументов (missing_arg), как host у endpoint-set. Надо ли отправлять конфиг
            # заново, решает модуль, а слова — те же, что у SSH-меню (_user_address_note).
            _require_fn users_set_endpoint_ip || return 1
            _action_run address_failed users_set_endpoint_ip "$(_arg name)" "$(_arg ip)" || return 1
            out=$(_as_json "$out" '{}')
            ga_emit_json success "$(_user_address_note "$out")" "name=$(_arg name)" \
                "endpoint_ip=$(jq -r '.endpoint_ip // ""' <<<"$out")" \
                "previous_endpoint_ip=$(jq -r '.previous_endpoint_ip // ""' <<<"$out")" \
                "endpoint=$(jq -r '.endpoint // ""' <<<"$out")" \
                "resend_required=@json:$(jq -c '.resend_required == true' <<<"$out")" \
                "domain_endpoint=@json:$(jq -c '.domain_endpoint == true' <<<"$out")"
            ;;

        user-add-peer)
            _require_fn users_add_peer || return 1
            _action_run peer_add_failed users_add_peer "$(_arg name)" "$(_arg profile)" || return 1
            ga_emit_json success "$(tf act_peer_added "$(_arg name)" "$(_pr_name "$(_arg profile)")")" \
                "name=$(_arg name)" "profile=$(_arg profile)"
            ;;

        user-del-peer)
            _require_fn users_del_peer || return 1
            _action_run peer_del_failed users_del_peer "$(_arg name)" "$(_arg profile)" || return 1
            ga_emit_json success "$(tf act_peer_removed "$(_arg name)" "$(_pr_name "$(_arg profile)")")" \
                "name=$(_arg name)" "profile=$(_arg profile)"
            ;;

        user-reissue-peer)
            # Перевыпуск одним действием: пара «снять, потом выдать» жила в трёх
            # интерфейсах сразу, и между её шагами было окно, в котором человек
            # оставался без доступа. Модуль делает подмену под общим замком и сам
            # возвращает прежний ключ, если применение сорвалось.
            _require_fn users_reissue_peer || return 1
            _action_run peer_reissue_failed users_reissue_peer "$(_arg name)" "$(_arg profile)" || return 1
            ga_emit_json success "$(tf act_peer_reissued "$(_arg name)" "$(_pr_name "$(_arg profile)")")" \
                "name=$(_arg name)" "profile=$(_arg profile)"
            ;;

        user-attach-key)
            # Старый ключ человека из приложения Amnezia (ссылка vpn:// или
            # текст .conf) — ТОЛЬКО из stdin: в argv приватный ключ был бы виден
            # в ps любому процессу. Терминал вместо канала — значит, ключ не
            # передали: ждать ввода мост не должен.
            _require_fn users_attach_key || return 1
            local material=""
            if [ ! -t 0 ]; then
                material=$(head -c 65537 2>/dev/null) || material=""
            fi
            # Предел — в БАЙТАХ, как у панели, бота и MCP: ${#…} в UTF-8 считает символы, и 64 КБ
            # кириллицы (~32 тыс. символов) проходили, обрезанные посреди буквы (находка TK-10).
            if [ "$(_bytes_len "$material")" -gt 65536 ]; then
                ga_emit_json error "$(t users_err_config_unreadable)" "code=config_unreadable"
                return 1
            fi
            _action_run attach_failed users_attach_key "$(_arg name)" "$(_arg profile)" "$material" || return 1
            material=""
            _action_emit_merged success "$(tf users_key_attached "$(_json_field "$out" .name)" "$(_json_field "$out" .profile)")" "$out"
            ;;

        backup-create)
            _require_fn create_backup || return 1
            # create_backup — подоболочка (umask внутри): код ошибки наружу не
            # доходит, остаётся общий backup_failed. stdout — путь к архиву.
            _action_run backup_failed create_backup "" || return 1
            ga_emit_json success "$(t act_backup_created)" "file=$(basename "$out")" "path=${out}"
            ;;

        backup-list)
            # list_backups рисует список для человека в stderr; машиночитаемый
            # — backup_list_json (lib/backup.sh): [{name, size, created}].
            _require_fn backup_list_json || return 1
            # Отказ модуля — это ОТКАЗ, а не пустой список: иначе бот, панель и
            # агент решают, что ничего нет, и действуют по этому. Особенно
            # больно у списка копий: «копий нет» показывается прямо перед
            # разрушительным действием (docs/DEFECTS.md §1c.3).
            _action_run backup_failed backup_list_json || return 1
            ga_emit_json success "$(t act_ok)" "backups=@json:$(_as_json "$out" '[]')"
            ;;

        backup-restore)
            _require_fn restore_backup || return 1
            # file — ИМЯ архива (без путей, см. pattern в actions.json): в каталоге бэкапов или копия, которую
            # оставил снос продукта в /root (goamnezia_backup_*, goamnezia-wipe-*; находка LC-19). Третий
            # аргумент yes снимает вопрос confirm — подтверждение уже дал вызывающий (бот, MCP через confirm).
            local rfile=""
            type ga_backup_resolve_name >/dev/null 2>&1 && rfile=$(ga_backup_resolve_name "$(_arg file)")
            [ -n "$rfile" ] || rfile="$BACKUP_DIR/$(_arg file)"
            GA_RESTORE_MODE_HINT=""; GA_RESTORE_KEPT=""; GA_RESTORE_AGENTS_DROPPED=""; GA_RESTORE_IP_JSON=""
            _action_run restore_failed restore_backup "$rfile" "" yes || return 1
            # kept_current — что копия НЕ откатила (bot, panel_password, agents: SEC-C1); agents_not_restored —
            # доступы из копии, удалённые после неё; server_ip — адрес машины после сверки (переезд, SR-45).
            local kept_js dropped_js rip rchanged
            kept_js=$(printf '%s' "${GA_RESTORE_KEPT:-}" | jq -Rc 'split(" ") | map(select(. != ""))' 2>/dev/null) || kept_js='[]'
            dropped_js=$(printf '%s' "${GA_RESTORE_AGENTS_DROPPED:-}" | jq -Rc 'split(" ") | map(select(. != ""))' 2>/dev/null) || dropped_js='[]'
            rip=$(_json_field "${GA_RESTORE_IP_JSON:-}" .ip); [ -n "$rip" ] || rip=$(_cfg '.server_ip')
            rchanged=$(_json_field "${GA_RESTORE_IP_JSON:-}" .changed); [ "$rchanged" = true ] || rchanged=false
            ga_emit_json success "$(tf act_backup_restored "$(_arg file)")" "file=$(_arg file)" \
                ${GA_RESTORE_MODE_HINT:+"mode_hint=$GA_RESTORE_MODE_HINT"} \
                "kept_current=@json:${kept_js:-[]}" "agents_not_restored=@json:${dropped_js:-[]}" \
                "server_ip=${rip}" "server_ip_changed=@json:${rchanged}"
            ;;

        import-scan)
            # Полный разбор (lib/import.sh: линейка, пиры, можно ли подхватить и
            # почему нет) — надмножество короткого списка amnezia_scan_containers,
            # который остаётся запасным путём без модуля импорта.
            if type import_scan >/dev/null 2>&1; then
                # На битом users.json import_scan намеренно отвечает
                # users_corrupt: иначе КАЖДЫЙ пир контейнера объявляется новым и
                # человеку предлагают подхватить собственных пользователей.
                _action_run import_failed import_scan || return 1
            else
                _require_fn amnezia_scan_containers || return 1
                out=$(amnezia_scan_containers 2>/dev/null) || out=""
            fi
            out=$(_as_json "$out" '[]')
            ga_emit_json success "$(t act_ok)" "containers=@json:${out}" \
                "adoptable=@json:$(printf '%s' "$out" | jq -c '[.[] | select(.adoptable == true) | .container]' 2>/dev/null || printf '[]')"
            ;;

        # ── Импорт существующей установки Amnezia (lib/import.sh, PLAN §6.5) ──
        # import-scan выше отдаёт короткий список (amnezia_scan_containers);
        # здесь — подхват и сверка. Ответы модуля плоские — кладём в корень.
        import-adopt)
            _require_fn import_adopt || return 1
            _action_run adopt_failed import_adopt "$(_arg container)" || return 1
            # Подхват — такое же «появление профиля», как profile-install: без отметки установки сторож, квоты и
            # ночной бэкап не ставились никогда, а следующий заход в SSH снова открывал мастер (находки В3, UP-4).
            _ga_mark_installed >&2
            # Подсеть совпала с другим профилем (SUBNET-01) — подхвачен как есть; в сообщении — с кем и выход.
            m="$(tf act_import_adopted "$(_arg container)" "$(_json_field "$out" .profile)")"
            js=$(printf '%s' "$out" | jq -c '.subnet_overlap // empty' 2>/dev/null) || js=""
            if [ -n "$js" ] && type ga_amn_subnet_overlap_text >/dev/null 2>&1; then
                m="$m $(t import_adopted_overlap) $(ga_amn_subnet_overlap_text "$js")"
            fi
            # Теги I1–I5, которые понимает не каждая реализация (KMOD-02): подхвачен, но клиенты одной из реализаций
            # с таким I не подключатся — словами в сообщении (поле ipacket_warnings — в корне ответа).
            js=$(printf '%s' "$out" | jq -r '(.ipacket_warnings // []) | join(" ")' 2>/dev/null) || js=""
            [ -n "$js" ] && m="$m $js"
            _action_emit_merged success "$m" "$out"
            ;;

        import-reconcile)
            _require_fn import_reconcile || return 1
            local apply=""
            [ "$(_arg apply)" = on ] && apply="apply"
            _action_run reconcile_failed import_reconcile "$(_arg profile)" "$apply" || return 1
            # Пиры, которых не подхватить (skipped, KEENETIC-I1-N, N2), — их причины словами ядра в конце сообщения:
            # прежде было «добавлено 0» без причины (строка о пропуске шла только в stderr).
            local rsk m
            rsk=$(printf '%s' "$out" | jq -r '[(.skipped // [])[] | .message? // empty | select(type == "string" and length > 0)
                | if test("[.!?]$") then . else . + "." end] | join(" ")' 2>/dev/null) || rsk=""
            if [ "$(_json_field "$out" .in_sync)" = true ]; then
                m=$(tf act_import_in_sync "$(_arg profile)")
            elif [ "$(_json_field "$out" .applied)" = true ]; then
                m=$(tf act_import_reconciled "$(_arg profile)" "$(_json_field "$out" .added)" "$(_json_field "$out" .deactivated)")
            else
                m=$(tf act_import_diverged "$(_arg profile)")
            fi
            _action_emit_merged success "$m${rsk:+ $rsk}" "$out"
            ;;

        # ── Обновления из официального репозитория Amnezia (lib/upstream.sh, PLAN §6.8) ──
        # Сеть недоступна — код unreachable с советом; текущие версии профилей
        # отдаём и в этом случае (бот и панель рисуют таблицу без колонки «доступно»).
        upstream-check)
            _require_fn upstream_check || return 1
            # --cached=on — отчёт последней удачной суточной проверки без похода в сеть (L-07): экран обновлений
            # открывается сразу, а за свежим — кнопка «Проверить». Проверок ещё не было — no_cached_check.
            if [ "$(_arg cached)" = on ]; then
                out=$(upstream_last_check 2>/dev/null) || out=null
                if [ -z "$out" ] || [ "$out" = null ]; then
                    ga_emit_json error "$(t act_upstream_no_cached)" "code=no_cached_check" \
                        "summary=@json:$(_upstream_summary_json)"
                    return 1
                fi
                out=$(jq -c --argjson s "$(_upstream_summary_json)" '. + {cached: true, summary: $s}' <<<"$out" 2>/dev/null) \
                    || { _action_fail upstream_failed; return 1; }
                _action_emit_merged success "$(_json_field "$out" .hint)" "$out"
                return 0
            fi
            # Не через _action_run: у ошибки здесь есть полезная нагрузка —
            # текущие версии профилей, и ответ должен быть ОДНОЙ строкой JSON.
            GA_ERR_CODE=""; GA_ERR_MSG=""; GA_LAST_ERROR_CODE=""
            local ok_check=1
            if type ga_capture >/dev/null 2>&1; then
                ga_capture out upstream_check || ok_check=0
            else
                out=$(upstream_check) || ok_check=0
            fi
            if [ "$ok_check" = 1 ]; then
                _action_emit_merged success "$(_json_field "$out" .hint)" "$out"
            else
                local cur='[]'
                type ga_up_profiles_current >/dev/null 2>&1 && cur=$(ga_up_profiles_current 2>/dev/null)
                ga_emit_json error "${GA_ERR_MSG:-$(t upstream_err_unreachable)}" \
                    "code=${GA_ERR_CODE:-${GA_LAST_ERROR_CODE:-check_failed}}" \
                    "profiles=@json:$(_as_json "$cur" '[]')" "updates_available=@json:false"
                return 1
            fi
            ;;

        upstream-update)
            _require_fn upstream_update || return 1
            _action_run update_failed upstream_update "$(_arg profile)" "$(_arg tag)" || return 1
            _action_emit_merged success "$(tf act_upstream_updated "$(_arg profile)" "$(_json_field "$out" .image_tag)")" "$out"
            ;;

        upstream-rollback)
            _require_fn upstream_rollback || return 1
            _action_run rollback_failed upstream_rollback "$(_arg profile)" || return 1
            _action_emit_merged success "$(tf act_upstream_rolled_back "$(_arg profile)" "$(_json_field "$out" .image_tag)")" "$out"
            ;;

        core-update)
            _require_fn upstream_core_update || return 1
            _action_run update_failed upstream_core_update "$(_arg profile)" || return 1
            _action_emit_merged success "$(tf act_core_updated "$(_arg profile)" "$(_json_field "$out" .image_tag)")" "$out"
            ;;

        # ── Тики таймеров systemd (lib/timers.sh): mcp null, зовутся юнитами ──
        # Ответ — JSON модуля в корне: journalctl -u goamnezia-*.service показывает
        # ровно то, что таймер сделал.
        quota-tick)
            _require_fn users_quota_tick || return 1
            _action_run tick_failed users_quota_tick || return 1
            ga_emit_json success "$(t act_ok)" "tick=quota" "checked=$(_now_iso)" \
                "users=@json:$(_users_count)" "disabled=@json:$(_users_json | jq -c '[.[] | select(.enabled == false) | .name]' 2>/dev/null || printf '[]')"
            ;;

        edge-status)
            # Несколько адресов сервера: пакеты клиентов по каждому адресу за 15 минут, час и сутки и
            # вердикт сторожа (lib/edgeips.sh). У машины с одним адресом count=1 — экраны таблицу не рисуют.
            _require_fn ga_edge_status_json || return 1
            _action_run edge_failed ga_edge_status_json || return 1
            # Для «Ключа на другой адрес»: адрес в ключах как обычно и варианты, которые примет user-key
            # --endpoint (с вердиктом сторожа и A-записью по каждому адресу).
            if type export_key_choices_json >/dev/null 2>&1; then
                local kc kh
                kc=$(GA_EXPORT_SERVER_IP=$(_cfg '.server_ip') export_key_choices_json "$out" 2>/dev/null) || kc='[]'
                [ -n "$kc" ] || kc='[]'
                kh=$(GA_EXPORT_SERVER_IP=$(_cfg '.server_ip') ga_export_endpoint_host 2>/dev/null) || kh=""
                out=$(jq -c --argjson kc "$kc" --arg kh "$kh" '. + {keys_host: $kh, key_choices: $kc}' <<<"$out" 2>/dev/null) || true
            fi
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        watch-tick)
            _require_fn amnezia_watch_tick || return 1
            _action_run tick_failed amnezia_watch_tick || return 1
            # Тем же тиком (2 мин) — истёкшие страницы подключения и заявки
            # зеркала со страниц (lib/pages.sh, lib/mirror.sh): блоки pages и
            # mirror в ответе, null — модуля нет или тик не удался. И место на
            # диске: событие disk_level боту — только при смене уровня (TAIL-19);
            # в этой же оболочке, а не подоболочкой _tick_extra: номер события в
            # имени файла очереди (GA_NOTIFY_SEQ) должен расти у всего тика.
            j="null"
            type ga_disk_tick >/dev/null 2>&1 && { ga_capture j ga_disk_tick 2>/dev/null || j="null"; }
            # Подписки (lib/subs.sh) — тем же тиком: осиротевшие снимаются, маршрут и служба — по факту (пауза без
            # домена, ремонт после переустановки и восстановления из копии): блок subs в ответе.
            # Модуль ядра AmneziaWG (lib/kmod.sh): выбран модуль, а профили на программе после перезагрузки; закрепление
            # движка новых профилей; пересборка под метку новой версии отдельной службой — блок kmod (null — не занимались).
            out=$(jq -c --argjson p "$(_tick_extra pages_tick)" --argjson m "$(_tick_extra mirror_tick)" \
                --argjson s "$(_tick_extra subs_tick)" --argjson d "$(_as_json "$j" 'null')" \
                --argjson k "$(_tick_extra ga_kmod_watch)" \
                '. + {pages: $p, mirror: $m, subs: $s, disk: $d, kmod: $k}' <<<"$out" 2>/dev/null) || out="$out"
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        stats-tick)
            _require_fn stats_tick || return 1
            _action_run tick_failed stats_tick || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        upstream-tick)
            _require_fn upstream_tick || return 1
            _action_run tick_failed upstream_tick || return 1
            # Раз в сутки — новые версии уже скачанных копий зеркала сборок
            # (lib/mirror.sh, docs/CLIENTS.md §8): блок mirror в ответе.
            out=$(jq -c --argjson m "$(_tick_extra mirror_tick daily)" '. + {mirror: $m}' <<<"$out" 2>/dev/null) || out="$out"
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        cert-tick)
            _require_fn website_cert_tick || return 1
            _action_run tick_failed website_cert_tick || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        backup-tick)
            _require_fn backup_tick || return 1
            _action_run backup_failed backup_tick || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        # ── Pro-режим: домен, сайт-маскировка, панель на домене (lib/website.sh) ──
        # Функции модуля зовутся через _action_run: их коды (cert_failed,
        # nginx_conf_invalid, unknown_template, download_failed, no_index,
        # app_shell, broken_assets, invalid_path…) доходят до ответа как есть.
        change-mode)
            # Граф переходов под уточнённый замысел владельца: pro и lite_site —
            # ОДИН И ТОТ ЖЕ сайт на домене с сертификатом Let's Encrypt, разница
            # только в том, где живёт AmneziaWG (UDP/443 рядом с сайтом против
            # своего порта). Отсюда:
            #   lite → pro|lite_site   website_enable_pro <домен> [tpl] <режим>;
            #                          домена нет — website_enable_site_selfsigned
            #                          (запасной путь, cert=selfsigned);
            #   pro ↔ lite_site        website_switch_site_mode — сайт, домен и
            #                          сертификат не трогаются вовсе;
            #   * → lite               website_disable_site.
            # Порт профиля мост не двигает: это отдельное действие profile-port,
            # и рвать связь всем без явной просьбы он не имеет права (в SSH-меню
            # перенос предлагается отдельным вопросом с подтверждением).
            # Повтор того же режима — не ошибка: это ремонт vhost.
            m=$(_arg mode); d=$(_arg domain); d="${d,,}"
            local prev dns_fallback=0 keys_before keys_after
            prev=$(_mode_current)
            # Адрес в новых ключах до перехода: домен в ключах только в третьем режиме, и переход
            # меняет хост — бот, панель и агент должны узнать это из ответа (находка SR-43).
            keys_before=$(ga_export_endpoint_host 2>/dev/null) || keys_before=""
            # Страж на само значение --mode. Раньше ветка *) читала «не pro и не
            # lite_site» как «иди в lite», и `change-mode --mode=` с пустым
            # значением (или с опечаткой) СНИМАЛ живой сайт и отвечал
            # «успешно»: домен, сертификат и панель на 443 исчезали по пустому
            # аргументу. У остальных действий такой страж стоит в модуле —
            # здесь его не было, потому что переход в lite делается прямо в
            # диспетчере, и модуля, который сказал бы «это не режим», нет.
            case "$m" in
                pro|lite_site|lite) ;;
                *) _action_fail invalid_mode "$(tf act_mode_unknown "$m")"; return 1 ;;
            esac
            case "$m" in
                pro|lite_site)
                    _require_fn website_enable_pro || return 1
                    # Режим с сайтом, а сайта нет (мастер оборвали на certbot или клоне шаблона) —
                    # это не «поменять слово», а поднять сайт заново: иначе повтор режима, который
                    # AGENT_GUIDE называет ремонтом, ничего не чинил (находка SR-13, 25.09.2026).
                    local site_up=1
                    if type ga_site_fs_nginx_ok >/dev/null 2>&1 && ga_site_fs_nginx_ok && [ ! -f "$(ga_site_conf_path)" ]; then
                        site_up=0
                    fi
                    if [ "$prev" != "lite" ] && [ -z "$d" ] && [ "$site_up" = 1 ]; then
                        # Сайт уже стоит и остаётся как есть — меняем только режим
                        _require_fn website_switch_site_mode || return 1
                        _action_run switch_failed website_switch_site_mode "$m" || return 1
                    else
                        # Домен — из аргумента или из config.json (мастер и прежний
                        # режим с сайтом его уже сохранили).
                        [ -n "$d" ] || d=$(_cfg '.domain')
                        # Порты 80/443 — до certbot и nginx: занятый чужим порт даёт
                        # port_busy с владельцем, а не невнятный отказ nginx -t
                        _action_require_ports "$m" || return 1
                        if [ -z "$d" ]; then
                            # Запасной путь: сайт на IP с самоподписанным. Отказывать
                            # нельзя — это законное состояние режима, пока домена нет.
                            _require_fn website_enable_site_selfsigned || return 1
                            _action_run enable_failed website_enable_site_selfsigned "" "$m" || return 1
                        elif _site_dns_points_here "$d" || ga_site_cert_ok "$d" \
                             || { [ "$prev" != lite ] && [ "$site_up" = 1 ] && [ "$(ga_site_cert_kind)" != selfsigned ]; }; then
                            # Сюда же — живой сайт на Let's Encrypt (смена домена, ремонт с доменом):
                            # website_enable_pro при отказе certbot откатывается на прежний домен и
                            # оставляет рабочий сайт. Запасной путь ниже сносил бы его на
                            # самоподписанный по IP вместе с панелью на домене (находка SR-54).
                            _action_run enable_failed website_enable_pro "$d" "" "$m" || return 1
                        else
                            # Сайта на Let's Encrypt ещё нет (из «Только VPN», с запасного
                            # самоподписанного, или vhost пропал), а A-запись не сюда (или DNS не
                            # ответил) — то же правило, что в SSH (_site_bring_up): сайт на запасном
                            # сертификате, домен сохранён, настоящий выпускается позже. Раньше мост
                            # шёл прямо в certbot: отказ, откат и неудачная проверка у Let's Encrypt
                            # (лимит — 5 в час на имя), а тот же переход из SSH давал сайт (SR-02).
                            _require_fn website_enable_site_selfsigned || return 1
                            _action_run enable_failed website_enable_site_selfsigned "" "$m" || return 1
                            ga_config_merge "$(jq -nc --arg d "$d" '{domain: $d}')" >/dev/null 2>&1 || true
                            dns_fallback=1
                        fi
                    fi
                    ;;
                *)
                    if [ "$prev" != "lite" ]; then
                        _require_fn website_disable_site || return 1
                        _action_run disable_failed website_disable_site || return 1
                    elif [ "$(_cfg '.mode')" != "lite" ]; then
                        # Уже lite: только выровнять поле, если в нём мусор
                        _require_fn ga_config_merge || return 1
                        ga_config_merge '{"mode":"lite"}' || { _action_fail config_write_failed; return 1; }
                    fi
                    # Домен, переданный вместе с lite, сохраняем: он подставится при
                    # следующем включении сайта (так мост вёл себя и до модуля).
                    if [ -n "$d" ]; then
                        ga_config_merge "$(jq -nc --arg d "$d" '{domain: $d}')" || { _action_fail config_write_failed; return 1; }
                    fi
                    ;;
            esac
            # Ответ один на все переходы: режим, домен, шаблон и блок site (в lite —
            # null, как у status), плюс откуда пришли — боту и агенту для отчёта.
            out="null"
            if _site_mode_has_site && type website_current_template >/dev/null 2>&1; then
                out=$(website_current_template 2>/dev/null) || out="null"
            fi
            local mode_msg
            mode_msg="$(tf act_mode_set "$(_mode_name "$(_mode_current)")")"
            [ "${dns_fallback:-0}" = 1 ] && mode_msg="$mode_msg $(tf act_mode_dns_fallback "$d")"
            keys_after=$(ga_export_endpoint_host 2>/dev/null) || keys_after=""
            if [ -n "$keys_before" ] && [ -n "$keys_after" ] && [ "$keys_before" != "$keys_after" ]; then
                mode_msg="$mode_msg $(tf act_mode_keys_host "$keys_before" "$keys_after")"
            fi
            # Режим и порт VPN разошлись («Сайт и VPN на 443», а на UDP/443 никого; «VPN и сайт», а профиль остался
            # на 443): мост порт не двигает (см. выше), но и молчать не должен — SSH-шапка и бот это показывают, а
            # панель писала «Режим переключён» и молчала (находка LC-18). Поле и те же слова, что у SSH.
            local mm=false on443=""
            if _mode_port_mismatch; then
                mm=true
                on443=$(_vpn_443_profile) || on443=""
                if [ -n "$on443" ]; then
                    mode_msg="$mode_msg $(tf ms_mode_port_mismatch "$(_mode_name "$(_mode_current)")" "$(_pr_name "${on443}")" "443")"
                else
                    mode_msg="$mode_msg $(tf ms_mode_port_missing_443 "$(_mode_name "$(_mode_current)")")"
                fi
            fi
            ga_emit_json success "$mode_msg" \
                "mode=$(_mode_current)" "previous_mode=${prev}" "domain=$(_cfg '.domain')" \
                "dns_fallback=@json:$([ "${dns_fallback:-0}" = 1 ] && echo true || echo false)" \
                "keys_host_before=${keys_before}" "keys_host=${keys_after}" \
                "mode_port_mismatch=@json:${mm}" "vpn_443_profile=${on443}" \
                "template=@json:$(_as_json "$out" 'null')" "site=@json:$(_site_status_json)"
            ;;

        # ── Режимы 0.6.0: Ленивый Pro и линия на UDP 443 (lib/modes.sh, docs/MODES_047.md) ──
        # В MCP не публикуются (mcp: null): первая установка и перенос портов с людьми — решение человека.
        lazy-check)
            # Только чтение: DNS, порты, контейнеры приложения и план — pro | semi_pro | blocked. Поля модуля — в корне
            # ответа, message — итог словами (первая причина, когда план не pro).
            _require_fn lazy_check || return 1
            _action_run lazy_check_failed lazy_check "$(_arg domain)" "$(_arg keys)" || return 1
            case "$(_json_field "$out" .plan)" in
                pro)      m=$(tf act_lazy_check_pro "$(_json_field "$out" .udp443_line)") ;;
                semi_pro) m=$(tf act_lazy_check_semi "$(ga_modes_semi_words)") ;;
                *)        m=$(tf act_lazy_check_blocked "$(ga_modes_blocking_words)") ;;
            esac
            # За прокси Cloudflare ключи ведут на IP сервера — панель и бот говорят это своими словами, мост тоже (LZ-03).
            [ "$(_json_field "$out" .cloudflare_proxied)" = true ] && m="$m $(tf lz_keys_ip "$(_server_ip)")"
            _action_emit_merged success "$m" "$out"
            ;;

        lazy-setup)
            # Весь сценарий без вопросов — и первой установкой, и из «Режим и сайт» на установленном сервере (ничего не
            # ломает, lib/modes.sh). Отказ проверки (домен не сюда, чужое на TCP 80/443) — до любых изменений: код,
            # слова, причины списком (reasons) и план.
            _require_fn lazy_setup || return 1
            GA_ERR_CODE=""; GA_ERR_MSG=""; GA_LAST_ERROR_CODE=""
            if ! ga_capture out lazy_setup "$(_arg domain)" "$(_arg keys)"; then
                m="${GA_ERR_CODE:-${GA_LAST_ERROR_CODE:-lazy_failed}}"
                # Сайт жил на домене с настоящим сертификатом, а Let's Encrypt отказал новому — ещё и причина словом и
                # срок лимита, как у change-mode (_action_run, L-26).
                local -a cf=()
                [ "$m" = cert_failed ] && [ -n "${GA_CERT_CAUSE:-}" ] \
                    && cf=("cert_cause=${GA_CERT_CAUSE}" "cert_retry_after=${GA_CERT_RETRY_AFTER:-}")
                if [ -n "${_GM_PLAN:-}" ]; then
                    ga_emit_json error "${GA_ERR_MSG:-$(t act_failed)}" "code=$m" "plan=${_GM_PLAN}" \
                        "reasons=@json:$(_as_json "${GA_MODES_REASONS_JSON:-[]}" '[]')" "${cf[@]+"${cf[@]}"}"
                else
                    ga_emit_json error "${GA_ERR_MSG:-$(t act_failed)}" "code=$m" "${cf[@]+"${cf[@]}"}"
                fi
                return 1
            fi
            m=$(tf act_lazy_done "$(_json_field "$out" .domain)" "$(_mode_name "$(_json_field "$out" .mode)")" \
                "$(printf '%s' "$out" | jq -r '.keys | length' 2>/dev/null)")
            jq -e '.warnings | index("cloudflare_proxied") != null' <<<"$out" >/dev/null 2>&1 \
                && m="$m $(tf lz_keys_ip "$(_server_ip)")"
            _action_emit_merged success "$m" "$out"
            ;;

        pro-line)
            # В Pro: выбранная линия на UDP 443, прежняя — на свободный случайный порт. Профиль с людьми приложения
            # Amnezia без ключа на сервере — только с adopted_confirm (ACC-2), иначе adopted_keyless.
            _require_fn pro_line_set || return 1
            GA_ERR_CODE=""; GA_ERR_MSG=""; GA_LAST_ERROR_CODE=""
            if ! ga_capture out pro_line_set "$(_arg profile)" "$(_arg adopted_confirm)"; then
                m="${GA_ERR_CODE:-${GA_LAST_ERROR_CODE:-pro_line_failed}}"
                # Отказ подхваченного профиля — как у profile-port, плюс какой профиль ждёт согласия: им бывает и
                # прежний держатель 443, а не тот, что выбрали (повтор — с --adopted-confirm=<profile>).
                if [ "$m" = adopted_keyless ] && [ -n "${GA_MODES_KEYLESS:-}" ]; then
                    ga_emit_json error "${GA_ERR_MSG:-$(t act_failed)}" "code=$m" "profile=${GA_MODES_KEYLESS}"
                else
                    ga_emit_json error "${GA_ERR_MSG:-$(t act_failed)}" "code=$m"
                fi
                return 1
            fi
            if [ "${GA_MODES_PL_CHANGED:-0}" = 1 ]; then
                m=$(tf act_pro_line_set "$(_pr_label "$(_arg profile)" noport)")
                [ -n "${GA_MODES_PL_PREV:-}" ] && m="$m $(tf act_pro_line_moved "$(_pr_label "$GA_MODES_PL_PREV" noport)" "$GA_MODES_PL_PREV_PORT")"
            else
                m=$(tf act_pro_line_same "$(_pr_label "$(_arg profile)" noport)")
            fi
            _action_emit_merged success "$m" "$out"
            ;;

        change-template)
            _require_fn website_deploy_template || return 1
            _action_require_site || return 1
            # stdout модуля — JSON website_current_template развёрнутого шаблона
            _action_run deploy_failed website_deploy_template "$(_arg template)" || return 1
            out=$(_as_json "$out" 'null')
            ga_emit_json success "$(tf act_template_set "$(printf '%s' "$out" | jq -r '.template_id // "-"' 2>/dev/null)")" \
                "template=@json:${out}"
            ;;

        domain-check)
            # A и AAAA НОВОГО домена до смены режима или домена (L-09): readonly, ничего не пишет. Поля
            # ga_site_dns_state в корне ответа + ready и hint; message — та же подсказка словами (или «DNS в порядке»).
            _require_fn website_domain_check || return 1
            _action_run dns_failed website_domain_check "$(_arg domain)" || return 1
            m=$(_json_field "$out" .hint)
            _action_emit_merged success "${m:-$(tf act_domain_ready "$(_arg domain)")}" "$out"
            ;;

        site-check)
            # readonly: замок не берётся, модуль ничего не пишет; в lite вердикт not_pro
            _require_fn website_check || return 1
            _action_run site_failed website_check || return 1
            out=$(_as_json "$out" 'null')
            ga_emit_json success "$(t act_ok)" "site=@json:${out}" \
                "verdict=$(printf '%s' "$out" | jq -r '.verdict // "unknown"' 2>/dev/null)"
            ;;

        preflight)
            # readonly, без замка: та же проверка, что видит мастер перед выбором
            # режима (PLAN §4.3.1). Ответ модуля — как есть в modes (бот рисует
            # экран из reasons[].message / warnings[].message, MCP отдаёт агенту),
            # плюс два флага и подсказка в корне — панели не нужно лезть внутрь.
            _require_fn preflight_modes || return 1
            _action_run preflight_check_failed preflight_modes || return 1
            out=$(_as_json "$out" '')
            [ -n "$out" ] || { _action_fail preflight_check_failed; return 1; }
            ga_emit_json success "$(t act_ok)" "modes=@json:${out}" \
                "lite_site_available=@json:$(printf '%s' "$out" | jq -c '.lite_site.available // false')" \
                "pro_available=@json:$(printf '%s' "$out" | jq -c '.pro.available // false')" \
                "hint=$(printf '%s' "$out" | jq -r 'if (.hints.open_cmd // "") != "" then .hints.open_cmd else (.hints.free_cmd // "") end')"
            ;;

        dns-set)
            # Через модуль, а не руками. Своя сборка JSON мимо ga_set_client_dns
            # означала три вещи сразу: адрес не проверялся по значению октетов
            # (проходило 999.999.999.999), аудит не писался вовсе — единственная
            # мутация из десяти без записи, — и панель с ботом потом месяцами
            # показывали адрес, которого у клиентов нет: последний рубеж выдачи
            # мусор молча отбрасывает (docs/DEFECTS.md §1c.2).
            _require_fn ga_set_client_dns || return 1
            _action_run dns_failed ga_set_client_dns "$(_arg dns1)" "$(_arg dns2)" || return 1
            # Один адрес — без «DNS клиентов: 8.8.8.8, .» с пустым вторым (находка SR-48).
            local dns_msg
            if [ -n "$(_arg dns2)" ]; then dns_msg=$(tf se_dns_saved "$(_arg dns1)" "$(_arg dns2)"); else dns_msg=$(tf se_dns_saved_one "$(_arg dns1)"); fi
            ga_emit_json success "$dns_msg" \
                "client_dns=@json:$(_as_json "$out" '[]')"
            ;;

        lang-set)
            # Язык всех интерфейсов сразу: save_language пишет маркер .language и
            # поле lang в config.json (панель и бот читают его как умолчание), а
            # load_language переключает словарь уже в этом процессе — ответ
            # приходит на новом языке, как и последующие экраны меню.
            _require_fn save_language || return 1
            m=$(_arg lang)
            # Отказ записи (место, права) — наружу с кодом и словами, а не success с прежним языком (OPS-04).
            GA_ERR_CODE=""; GA_ERR_MSG=""
            save_language "$m" || { _action_fail "${GA_ERR_CODE:-lang_failed}" "${GA_ERR_MSG:-}"; return 1; }
            type load_language >/dev/null 2>&1 && load_language "$m"
            type ga_audit >/dev/null 2>&1 && ga_audit "${GOAMNEZIA_WHO:-ssh}" "lang-set" "$m"
            ga_emit_json success "$(tf se_lang_saved "$m")" "lang=${m}"
            ;;

        miniapp-status)
            # Путь панели — секрет: readonly-ответ несёт только факт включения
            # (адрес выдают miniapp-on/rotate, помеченные secret в actions.json).
            #
            # Сначала факт, потом ответ. Панель на домене живёт локацией в vhost
            # сайта: нет сайта — нет и панели, сколько бы путей ни осталось в
            # конфиге от прежнего режима. Прежний ответ читал только конфиг и в
            # Lite рапортовал «включено» там, где включать нечего (DEFECTS §1.8).
            # Поэтому полей три: configured — что записано, available — можно ли
            # в этом режиме вообще, enabled — работает ли на самом деле; reason и
            # hint называют, чего не хватает.
            local configured=false available=false on=false reason hint
            [ -n "$(_cfg '.panel.miniapp_path')" ] && configured=true
            reason=$(_site_panel_reason)
            [ -z "$reason" ] && available=true
            [ "$available" = true ] && [ "$configured" = true ] && on=true
            hint=$(_site_panel_reason_hint "$reason")
            js=""
            if _site_mode_has_site && type website_check >/dev/null 2>&1; then
                js=$(website_check 2>/dev/null | jq -c '{nginx_active, https_ok, cert_ok, verdict}' 2>/dev/null) || js=""
            fi
            ga_emit_json success "$(t act_ok)" "enabled=@json:${on}" \
                "configured=@json:${configured}" "available=@json:${available}" \
                "reason=${reason}" "hint=${hint}" "mode=$(_cfg '.mode')" \
                "domain=$(_cfg '.domain')" "panel_port=@json:$(_as_json "$(_cfg '.panel.port')" '1985')" \
                "site=@json:$(_as_json "$js" 'null')"
            ;;

        miniapp-on)
            _require_fn website_panel_path_set || return 1
            _action_require_pro || return 1
            d=$(_cfg '.domain')
            [ -n "$d" ] || { ga_emit_json error "$(t website_err_no_domain)" "code=no_domain"; return 1; }
            local ppath changed=true
            ppath=$(_cfg '.panel.miniapp_path')
            if [ -n "$ppath" ] && ga_site_panel_path_valid "$ppath"; then
                # Уже включено — путь не трогаем: повторный вызов из бота не должен
                # молча обесценивать ссылку, которую человек уже открыл. Модуль
                # всё равно прогоняем: он пересобирает vhost и чинит location.
                changed=false
            else
                ppath=$(ga_site_panel_path_new)
            fi
            _action_run panel_failed website_panel_path_set "$ppath" || return 1
            ga_emit_json success "$(tf act_panel_enabled "$(_site_panel_url "$d" "$ppath")")" \
                "enabled=@json:true" "changed=@json:${changed}" "path=${ppath}" \
                "url=$(_site_panel_url "$d" "$ppath")" "hint=$(t act_panel_hint)"
            ;;

        miniapp-rotate)
            _require_fn website_panel_path_set || return 1
            _action_require_pro || return 1
            d=$(_cfg '.domain')
            [ -n "$d" ] || { ga_emit_json error "$(t website_err_no_domain)" "code=no_domain"; return 1; }
            # Смена пути у выключенной панели включала бы её тайком — отказ
            if [ -z "$(_cfg '.panel.miniapp_path')" ]; then
                ga_emit_json error "$(t act_panel_off)" "code=panel_disabled"
                return 1
            fi
            local ppath
            ppath=$(ga_site_panel_path_new)
            _action_run panel_failed website_panel_path_set "$ppath" || return 1
            ga_emit_json success "$(tf act_panel_rotated "$(_site_panel_url "$d" "$ppath")")" \
                "enabled=@json:true" "changed=@json:true" "path=${ppath}" \
                "url=$(_site_panel_url "$d" "$ppath")" "hint=$(t act_panel_hint)"
            ;;

        miniapp-off)
            # Работает и в Lite: модуль там пишет только config.json
            _require_fn website_panel_path_clear || return 1
            _action_run panel_failed website_panel_path_clear || return 1
            ga_emit_json success "$(t act_panel_disabled)" "enabled=@json:false" "mode=$(_cfg '.mode')"
            ;;

        site-alt-svc)
            _require_fn website_set_alt_svc || return 1
            # В Lite настройка сохраняется и применится при включении режима с
            # сайтом — applied говорит вызывающему, дошла ли она до nginx уже сейчас.
            _action_run alt_svc_failed website_set_alt_svc "$(_arg state)" || return 1
            local applied=false
            _site_mode_has_site && applied=true
            ga_emit_json success "$(tf act_alt_svc_set "$(_arg state)")" \
                "alt_svc=@json:$(_as_json "$(_cfg '.options.alt_svc')" 'false')" \
                "applied=@json:${applied}" "mode=$(_cfg '.mode')"
            ;;

        # ── Доступы агентов и HTTP-транспорт MCP (lib/agents.sh, PLAN §6.10) ──
        # Карточка доступа (agent-add/show/rotate) содержит url с секретом —
        # действия помечены secret: true, панель и бот показывают адрес только
        # тому, кто попросил. Ответы плоские: поля карточки/статуса лежат в
        # корне, чтобы бот и панель не разбирали вложенность.
        agent-list)
            _require_fn agents_list || return 1
            _action_run agents_failed agents_list || return 1
            js=$(agents_http_status 2>/dev/null) || js=""
            ga_emit_json success "$(t act_ok)" "agents=@json:$(_as_json "$out" '[]')" \
                "transport=@json:$(_as_json "$js" 'null')"
            ;;

        agent-add)
            _require_fn agents_add || return 1
            _action_run agents_failed agents_add "$(_arg label)" "$(_arg scope)" "$(_arg days)" "$(_arg allow_ips)" "$(_arg port)" "$(_arg pin_ip)" "$(_arg mode)" || return 1
            # У доступа через переходник нет ни адреса, ни токена — есть одноразовый код.
            # Общая фраза «адрес в поле url, токен в поле token» отправляла бы искать пустые поля.
            if [ "$(_json_field "$out" .mode)" = connect ]; then
                _action_emit_merged success "$(tf act_agent_added_connect "$(_json_field "$out" .id)")" "$out"
            else
                _action_emit_merged success "$(tf act_agent_added "$(_json_field "$out" .id)")" "$out"
            fi
            ;;

        # Усиление старого доступа: токен второго фактора. Ответ содержит токен,
        # поэтому действие помечено secret: true — как agent-show.
        agent-harden)
            _require_fn agents_harden || return 1
            _action_run agents_failed agents_harden "$(_arg id)" || return 1
            _action_emit_merged success "$(tf act_agent_hardened "$(_arg id)")" "$out"
            ;;

        agent-pin)
            _require_fn agents_pin || return 1
            _action_run agents_failed agents_pin "$(_arg id)" "$(_arg state)" || return 1
            _action_emit_merged success "$(tf act_agent_pinned "$(_arg id)")" "$out"
            ;;

        agent-extend)
            # Продление вместо «удалить и выдать заново»: адрес и токен не
            # меняются, значит клиента агента перенастраивать не надо. Модуль
            # был написан, а звать его было некому — действия в описании не
            # существовало, и кнопки в боте и панели ушли бы в никуда.
            _require_fn agents_extend || return 1
            _action_run agents_failed agents_extend "$(_arg id)" "$(_arg days)" || return 1
            _action_emit_merged success "$(tf act_agent_extended "$(_arg id)")" "$out"
            ;;

        agent-show)
            _require_fn agents_show || return 1
            _action_run agents_failed agents_show "$(_arg id)" || return 1
            if [ "$(_json_field "$out" .mode)" = connect ]; then
                _action_emit_merged success "$(tf act_agent_shown_connect "$(_arg id)")" "$out"
            else
                _action_emit_merged success "$(tf act_agent_shown "$(_arg id)")" "$out"
            fi
            ;;

        agent-rotate)
            _require_fn agents_rotate || return 1
            _action_run agents_failed agents_rotate "$(_arg id)" || return 1
            # У доступа с одноразовым ключом перевыпуск — это ещё и новая цепочка
            # со снятой заморозкой, и говорить про «секрет и токен» мало.
            case "$(_json_field "$out" .mode)" in
                connect) _action_emit_merged success "$(tf act_agent_reenrolled "$(_arg id)")" "$out" ;;
                rolling) _action_emit_merged success "$(tf act_agent_reissued "$(_arg id)")" "$out" ;;
                *)       _action_emit_merged success "$(tf act_agent_rotated "$(_arg id)")" "$out" ;;
            esac
            ;;

        agent-enable)
            _require_fn agents_enable || return 1
            _action_run agents_failed agents_enable "$(_arg id)" || return 1
            _action_emit_merged success "$(tf act_agent_enabled "$(_arg id)")" "$out"
            ;;

        agent-disable)
            _require_fn agents_disable || return 1
            _action_run agents_failed agents_disable "$(_arg id)" || return 1
            _action_emit_merged success "$(tf act_agent_disabled "$(_arg id)")" "$out"
            ;;

        agent-del)
            _require_fn agents_del || return 1
            _action_run agents_failed agents_del "$(_arg id)" || return 1
            _action_emit_merged success "$(tf act_agent_deleted "$(_arg id)")" "$out"
            ;;

        mcp-http-status)
            # readonly: состояние транспорта без секретов (адрес — только base_url)
            _require_fn agents_http_status || return 1
            _action_run agents_failed agents_http_status || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        mcp-http-on)
            # Коды модуля (needs_site в lite без порта, port_busy, unit_failed,
            # selfsigned_failed, nginx_conf_invalid…) доходят через _action_run.
            _require_fn agents_http_on || return 1
            _action_run agents_failed agents_http_on "$(_arg port)" || return 1
            _action_emit_merged success "$(t act_mcp_http_on)" "$out"
            ;;

        mcp-http-off)
            _require_fn agents_http_off || return 1
            _action_run agents_failed agents_http_off || return 1
            _action_emit_merged success "$(t act_mcp_http_off)" "$out"
            ;;

        # Ответ share-create содержит секретный адрес (действие помечено
        # secret: true): он уходит только тому, кто попросил, а в лог и аудит
        # попадает лишь идентификатор раздачи.
        share-create)
            _require_fn share_create || return 1
            _action_run share_failed share_create "$(_arg name)" "$(_arg profile)" "$(_arg format)" "$(_arg endpoint)" || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        share-list)
            _require_fn share_list || return 1
            _action_run share_failed share_list || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        share-revoke)
            _require_fn share_revoke || return 1
            _action_run share_failed share_revoke "$(_arg id)" || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        share-revoke-all)
            _require_fn share_revoke_all || return 1
            _action_run share_failed share_revoke_all || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        share-tick)
            _require_fn share_tick || return 1
            _action_run share_failed share_tick || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        # ── Страница подключения, каталог приложений, зеркало сборок ──────────
        # (lib/pages.sh, lib/mirror.sh, lib/clients.json — docs/CLIENTS.md §9).
        # Ответы page-create и page-url содержат адрес-секрет: действия помечены
        # secret: true, в лог и аудит попадает только id страницы. Коды модулей
        # (pages_need_domain, user_disabled, invalid_ttl, page_not_found,
        # page_limit, unknown_app, not_mirrorable, mirror_busy, mirror_no_space,
        # mirror_too_big, mirror_unverified, mirror_fetch_failed) доходят через
        # _action_run.
        clients-list)
            _require_fn clients_list || return 1
            _action_run clients_failed clients_list "$(_arg platform)" "$(_arg line)" || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        page-create)
            _require_fn pages_create || return 1
            _action_run page_failed pages_create "$(_arg name)" "$(_arg ttl)" "$(_arg profiles)" "$(_arg mirror)" || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        page-list)
            _require_fn pages_list || return 1
            _action_run page_failed pages_list "$(_arg name)" || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        page-url)
            _require_fn pages_url || return 1
            _action_run page_failed pages_url "$(_arg id)" || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        page-revoke)
            _require_fn pages_revoke || return 1
            _action_run page_failed pages_revoke "$(_arg id)" "$(_arg sub)" "$(_arg keys)" || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        page-revoke-all)
            _require_fn pages_revoke_all || return 1
            _action_run page_failed pages_revoke_all "$(_arg name)" || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        # ── Подписка: постоянная ссылка на человека (lib/subs.sh, docs/SUBSCRIPTION.md) ──
        # Ответы sub-create, sub-show и sub-rotate содержат адрес-секрет: действия помечены secret: true и агентам
        # MCP не публикуются ("mcp": null); в лог и аудит попадает только имя. Коды модуля (subs_need_domain,
        # sub_not_found, peer_not_found, no_private_key…) доходят через _action_run.
        sub-list)
            _require_fn subs_list || return 1
            _action_run sub_failed subs_list "$(_arg name)" || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        sub-create)
            _require_fn subs_create || return 1
            _action_run sub_failed subs_create "$(_arg name)" || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        sub-show)
            _require_fn subs_show || return 1
            _action_run sub_failed subs_show "$(_arg name)" || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        sub-rotate)
            _require_fn subs_rotate || return 1
            _action_run sub_failed subs_rotate "$(_arg name)" || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        sub-revoke)
            _require_fn subs_revoke || return 1
            _action_run sub_failed subs_revoke "$(_arg name)" || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        # ── Короткие ссылки подписки с 2FA через Telegram-бота (lib/shortlinks.py, docs/SUBSCRIPTION.md §11) ──
        # Ответы несут код или число: действия помечены secret: true, агентам MCP их нет ("mcp": null); кодов и
        # числа нет ни в логе, ни в аудите. Итог решения и опроса — поле decision (ok, wrong, pending…), снятия бана —
        # unbanned: status корня занят конвертом моста (success|error). short-decide идёт без общего замка
        # (_action_own_lock): у состояния коротких ссылок свой замок.
        short-ensure)
            _require_fn subs_short_ensure || return 1
            _action_run short_failed subs_short_ensure "$(_arg name)" "$(_arg suffix)" || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        short-list)
            _require_fn subs_short_list || return 1
            _action_run short_failed subs_short_list "$(_arg name)" || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        short-replace-request)
            _require_fn subs_short_replace_request || return 1
            _action_run short_failed subs_short_replace_request "$(_arg name)" "$(_arg suffix)" "$(_arg who)" || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        short-decide)
            _require_fn subs_short_decide || return 1
            _action_run short_failed subs_short_decide "$(_arg request)" "$(_arg answer)" "$(_arg who)" || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        short-status)
            _require_fn subs_short_status || return 1
            _action_run short_failed subs_short_status "$(_arg request)" || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        short-pending)
            _require_fn subs_short_pending || return 1
            _action_run short_failed subs_short_pending || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        short-bans)
            _require_fn subs_short_bans || return 1
            _action_run short_failed subs_short_bans || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        short-unban)
            _require_fn subs_short_unban || return 1
            _action_run short_failed subs_short_unban "$(_arg target)" || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        mirror-list)
            _require_fn mirror_list || return 1
            _action_run mirror_failed mirror_list || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        mirror-fetch)
            _require_fn mirror_fetch || return 1
            _action_run mirror_failed mirror_fetch "$(_arg app)" "$(_arg platform)" || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        mirror-remove)
            _require_fn mirror_remove || return 1
            _action_run mirror_failed mirror_remove "$(_arg app)" "$(_arg platform)" || return 1
            _action_emit_merged success "$(t act_ok)" "$out"
            ;;

        *)
            # Сюда попасть можно только при рассинхроне case и actions.json —
            # ровно то, что ловит tests/check_actions.py.
            ga_emit_json error "$(tf act_unknown "$name")" "code=unknown_action"
            return 2
            ;;
    esac

    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# main
# ══════════════════════════════════════════════════════════════════════════════

# Проверки окружения обёрнуты: на неполном комплекте модулей (или на macOS в
# тестах) их просто нет, и падать по set -u из-за отсутствующей функции нельзя.
_ga_preflight() {
    # GOAMNEZIA_DRY_RUN=1 — стенд и статические тесты (в том числе на macOS
    # arm64): там нет ни root, ни поддерживаемой архитектуры, и проверять их
    # бессмысленно — работать всё равно нечему, docker-команды не выполняются.
    if [ "${GOAMNEZIA_DRY_RUN:-0}" != "1" ]; then
        type check_root >/dev/null 2>&1 && { check_root || return 1; }
        type get_arch   >/dev/null 2>&1 && { get_arch >/dev/null || return 1; }
    fi
    type init_dirs >/dev/null 2>&1 && init_dirs
    return 0
}

# Зависимости. В DRY_RUN (стенд, macOS) ставить ничего нельзя и не нужно.
# lib/deps.sh ставит пакеты только по явному вызову — это он и есть: без ядра
# (jq, flock, ss…) не работает ни меню, ни мост.
_ga_ensure_deps() {
    type check_deps_present >/dev/null 2>&1 || return 0
    check_deps_present && return 0
    if [ "${GOAMNEZIA_DRY_RUN:-0}" = "1" ]; then
        log_warning "$(t deps_missing_dry)"
        return 0
    fi
    type deps_install_missing >/dev/null 2>&1 || return 1
    deps_install_missing --yes core >&2 || return 1
    check_deps_present
}

# _ga_after_update_rollback menu|bridge [аргументы main] — обновление не встало и откатано (OPS-02), или код на
# диске сменился, пока этот процесс ждал замка: на диске не тот код, что в памяти. Дальше работает код с диска:
# тот же вызов с теми же аргументами — мост ответит его JSON, меню откроется им. В меню после отката сначала
# пауза: строки об откате не должны уехать с экрана под заставку прежней версии.
_ga_after_update_rollback() {
    local how="$1" v
    shift
    [ "${GA_UPDATE_ROLLED_BACK:-0}" = 1 ] || [ "${GA_CODE_MOVED:-0}" = 1 ] || return 0
    if [ "$how" = menu ]; then
        v=$(sed -n -E 's/^GOAMNEZIA_VERSION="([0-9][0-9A-Za-z.+-]*)".*/\1/p' "$LIB_DIR/common.sh" 2>/dev/null | head -n 1)
        if [ "${GA_UPDATE_ROLLED_BACK:-0}" = 1 ]; then
            log_info "$(tf ops_upd_restart_old "${v:-?}")"
            [ -t 0 ] && _pause
        else
            log_info "$(tf ops_upd_restart_disk "${v:-?}")"
        fi
    fi
    exec "${BASH:-bash}" "$SCRIPT_DIR/install.sh" "$@"
}

# _ga_update_rollback_json → поле update_rollback действия status: отметка неудачного обновления (что не встало,
# на какой этапе, что вернулось, из какой копии) или null. По нему бот и панель говорят об откате (OPS-02).
_ga_update_rollback_json() {
    if type ga_upd_notice_json >/dev/null 2>&1; then ga_upd_notice_json; else printf 'null'; fi
}

# _ga_disk_status_json → поле disk действия status (OPS-01): раздел каталога продукта — всего, занято, свободно
# (МБ), занято %, уровень ok | low | critical и пороги; df не ответил — null. По нему панель и бот предупреждают.
_ga_disk_status_json() {
    if type ga_disk_json >/dev/null 2>&1; then ga_disk_json; else printf 'null'; fi
}

# _ga_docker_stale_status_json → поле docker_stale действия status (DK-02): пакет Docker обновлён, а служба старая —
# версии, с какого времени и что знает сторож (прошлая попытка, раньше чего сам не перезапустит); null — служба свежая
# или не узнать. По нему панель и мини-апп держат строку на «Обзоре».
_ga_docker_stale_status_json() {
    local js
    type ga_amn_docker_stale_status >/dev/null 2>&1 || { printf 'null'; return 0; }
    js=$(ga_amn_docker_stale_status 2>/dev/null) || js=null
    if [ -z "$js" ] || [ "$js" = null ]; then printf 'null'; return 0; fi
    _as_json "$js" null
}

# _ga_kmod_status_json → поле kmod действия status (KMOD_PLAN А3): {loaded, version, patched, warn} — загружен ли на
# хосте модуль ядра amneziawg, его версия, есть ли метка набора исправлений и надо ли предупредить (без метки, а есть
# профиль 3.1). С этапа Б (lib/kmod.sh) — ещё state, code, reason, kernel, want, installed, owner, profiles, progress…
# (CONTRACT §4.7a). Модуля ядра у продукта нет (lib/amnezia.sh не загружен) — null.
_ga_kmod_status_json() {
    local js
    if type ga_kmod_status_json >/dev/null 2>&1; then
        js=$(ga_kmod_status_json 2>/dev/null) || js=null
        _as_json "${js:-null}" null
        return 0
    fi
    type ga_amn_kmod_json >/dev/null 2>&1 || { printf 'null'; return 0; }
    js=$(ga_amn_kmod_json 2>/dev/null) || js=null
    _as_json "${js:-null}" null
}

# _dash_kmod_warn — строка в шапке главного меню (KMOD_PLAN А3): на хосте модуль ядра AmneziaWG без исправлений, а у
# нас есть профиль 3.1. Этап Б — ещё «выбран модуль, а профили на программе» с ядром и неудавшаяся установка.
_dash_kmod_warn() {
    local js
    type ga_kmod_dash_warn >/dev/null 2>&1 && ga_kmod_dash_warn
    js=$(_ga_kmod_status_json)
    [ "$(jq -r '.warn // false' <<<"$js" 2>/dev/null)" = true ] || return 0
    log_warning "$(_ui_w "$(t dash_kmod_unpatched)")"
    return 0
}

# _dash_lines_warn [protocols | card <профиль> <номер пункта>] — строка о линиях сервера (DUP-LINE-01): в шапке главного меню и на экране
# «Протоколы» — нет 2.0 (старые версии приложений и роутеры Keenetic не подключатся) и свой профиль, который можно
# переставить на недостающую линию, с тем, где это делается; на карточке профиля (card) — только когда речь о нём.
_dash_lines_warn() {
    local js text rp rl dfx
    type ga_amn_lines_check >/dev/null 2>&1 || return 0
    # Флаг миграции «Ошибка прошлых версий» (DUP-LINE-01): в шапке и «Протоколах», пока не исправлено, — одна-две
    # строки: что не так и куда идти (D-1 проверки 15.10). Полный текст — один раз после обновления
    # (_dupline_notice_once) и до согласия на перестановку; в «Протоколах» путь — без «Протоколы →», пользователь уже там.
    if [ "${1:-}" != card ] && type ga_amn_dupline_fix_json >/dev/null 2>&1; then
        dfx=$(ga_amn_dupline_fix_json 2>/dev/null) || dfx=null
        if [ -n "$dfx" ] && [ "$dfx" != null ]; then
            if [ "${1:-}" = protocols ]; then
                log_warning "$(_ui_w "$(tf dash_dupline_here "$(_pr_name "$(jq -r '.profile' <<<"$dfx")")")")"
            else
                log_warning "$(_ui_w "$(tf dash_dupline_short "$(_pr_name "$(jq -r '.profile' <<<"$dfx")")")")"
            fi
            return 0
        fi
    fi
    js=$(ga_amn_lines_check 2>/dev/null) || return 0
    text=$(jq -r '.text // ""' <<<"$js" 2>/dev/null)
    [ -n "$text" ] || return 0
    rp=$(jq -r '.reline.profile // empty' <<<"$js" 2>/dev/null)
    rl=$(jq -r '.reline.line // empty' <<<"$js" 2>/dev/null)
    if [ "${1:-}" = card ]; then
        [ -n "$rp" ] && [ "$rp" = "${2:-}" ] || return 0
        log_warning "$(_ui_w "$text $(tf pr_reline_card_hint "${3:-}" "$rl")")"
        return 0
    fi
    if [ "${1:-}" = protocols ]; then
        if [ -n "$rp" ]; then
            log_warning "$(_ui_w "$text $(tf pr_reline_here_hint "$(_pr_name "$rp")" "$rl")")"
        else
            log_warning "$(_ui_w "$text")"
        fi
        return 0
    fi
    # Шапка главного меню — одна-две строки, как у флага миграции (F-2 живой проверки 15.10: общий абзац
    # lines_check.text при 160 колонках шёл на три строки): что не так и куда идти. Полный текст — в «Протоколах».
    local no20 ip
    no20=$(jq -r '.no_20' <<<"$js" 2>/dev/null)
    ip=$(jq -r '.install.profile // empty' <<<"$js" 2>/dev/null)
    if [ -n "$rp" ] && [ "$no20" = true ]; then
        log_warning "$(_ui_w "$(tf dash_lines_no20_reline "$(_pr_name "$rp")" "$rl")")"
    elif [ -n "$rp" ]; then
        log_warning "$(_ui_w "$(tf dash_lines_reline_short "$rl" "$(_pr_name "$rp")" "$rl")")"
    elif [ "$no20" = true ] && [ -n "$ip" ]; then
        log_warning "$(_ui_w "$(tf dash_lines_no20_install "$(_pr_name "$ip")")")"
    elif [ "$no20" = true ]; then
        log_warning "$(_ui_w "$(t dash_lines_no20_short)")"
    else
        log_warning "$(_ui_w "$text")"
    fi
    return 0
}

# _dash_s4_warn — строка в шапке главного меню на каждый профиль, у которого пакет данных не влезает в мобильные сети
# из-за большого S4 (S4-FIX, MTU-01): что не так и где чинится. По снимку шапки (_dash_snapshot) — без лишних чтений.
_dash_s4_warn() {
    local p
    for p in $PROFILE_IDS; do
        [ -n "${GA_DASH_S4[$p]:-}" ] || continue
        log_warning "$(_ui_w "$(tf amnezia_s4_risk "$(_pr_name "$p")" "${GA_DASH_S4[$p]}") $(t dash_s4_hint)")"
    done
    return 0
}

# _dash_docker_stale_warn — строка в шапке главного меню, пока служба Docker старая (DK-02): словами и с тем, что
# будет дальше, — не ошибка, а «сделаю сам; можно и сейчас».
_dash_docker_stale_warn() {
    type docker_stale_probe >/dev/null 2>&1 || return 0
    command -v docker >/dev/null 2>&1 || return 0
    docker_stale_probe || return 0
    log_warning "$(_ui_w "$(t dash_docker_stale)")"
    return 0
}

# _dash_disk_warn — строка в шапке главного меню, когда места мало (OPS-01): порог тот же, что у «Диагностики»
# (1024 МБ свободных), ниже 512 МБ — тревогой. Раньше при 99 % занятого об этом говорила одна «Диагностика».
_dash_disk_warn() {
    local js level pct free
    js=$(_ga_disk_status_json)
    [ "$js" != null ] && [ -n "$js" ] || return 0
    IFS=$'\x1f' read -r level pct free <<<"$(jq -r '[.level, (.used_pct | tostring), (.free_mb | tostring)] | join("\u001f")' \
        <<<"$js" 2>/dev/null)"
    case "${level:-ok}" in
        low)      log_warning "$(_ui_w "$(tf ops_disk_low "$pct" "$free")")" ;;
        critical) log_error "$(_ui_w "$(tf ops_disk_critical "$pct" "$free")")" ;;
    esac
    return 0
}

# _dash_update_notice — строка в шапке главного меню: обновление не встало и откатано (OPS-02). Неделю после
# отката; следующее удавшееся обновление снимает её раньше.
_dash_update_notice() {
    local js fv at reason v ok
    js=$(_ga_update_rollback_json)
    [ "$js" != null ] && [ -n "$js" ] || return 0
    # Разделитель — \x1f, а не табуляция: пустое поле между табуляциями read бы схлопнул.
    IFS=$'\x1f' read -r fv at reason v ok <<<"$(jq -r '
        select(((.at // "") | fromdateiso8601? // 0) > (now - 7 * 86400))
        | [(.failed_version // "?"), ((.at // "")[8:10] + "." + (.at // "")[5:7] + "." + (.at // "")[0:4]),
           (.reason // ""), (.version // "?"), (.code_restored | tostring)] | join("\u001f")' <<<"$js" 2>/dev/null)"
    [ -n "${fv:-}" ] || return 0
    if [ "${ok:-}" = true ]; then
        log_warning "$(_ui_w "$(tf ops_upd_header "$fv" "$at" "$reason" "$v")")"
    else
        log_error "$(_ui_w "$(tf ops_upd_header_stuck "$fv" "$at" "$reason")")"
    fi
}

main() {
    local a has_action=0 action_name="" choice="" rc=0

    # Неинтерактивный режим разбираем ДО всего остального: бот, панель и MCP
    # должны получить чистый JSON без баннера, меню и вопросов.
    for a in "$@"; do
        case "$a" in --action=*) has_action=1; action_name="${a#--action=}"; break ;; esac
    done
    if [ "$has_action" = "1" ]; then
        # Мост обязан ответить JSON-ом даже на отказ окружения: вызывающий
        # (бот, панель, MCP) разбирает stdout и без JSON видит только тишину.
        if ! _ga_preflight; then
            ga_emit_json error "$(t act_preflight_failed)" "code=preflight_failed"
            exit 1
        fi
        # Чтения моста и тики таймеров верят отметке «core уже проверен, с тех пор ничего не менялось» (lib/deps.sh,
        # deps_stamp_valid): полная проверка — 0,2–0,3 CPU-с на вызов, а мост зовут панель на каждом обновлении
        # экрана и сторож раз в две минуты (CPU-03). Меню, установка и прочие изменения проверяют полностью, как в
        # 1.0.7. Без jq каталог действий не прочитать — тогда и отметки нет: полная проверка назовёт нехватку.
        if [ "${GOAMNEZIA_WHO:-}" = timer ] || { _action_known "$action_name" && { [ "$GA_ACT_READONLY" = true ] || _action_own_lock "$action_name"; }; }; then
            GA_DEPS_STAMP=1
        fi
        if ! _ga_ensure_deps; then
            ga_emit_json error "$(t deps_missing)" "code=deps_missing"
            exit 1
        fi
        # Читающие действия НЕ тянут миграцию: панель дёргает их на каждом
        # обновлении экрана и убивает по таймауту, а оборванная посреди записи
        # миграция рвёт конфиг. Несуществующее имя (опечатка) — тоже: оно всё равно
        # получит отказ unknown_action, а миграцию со снимком запускало (SR-38).
        if _action_known "$action_name" && [ "$GA_ACT_READONLY" != "true" ] && ! _action_own_lock "$action_name"; then
            # Таймеру замок, занятый установкой, — не ошибка: миграцию доделает следующий вызов, а сам тик скажет
            # «занято — пропущено» (action_dispatch). Без GA_LOCK_QUIET в журнал юнита шла строка ошибки.
            # Ждать замок тик может ga_timer_lock_wait (120 с) на всё сразу: миграция ждёт из этого бюджета, действию —
            # остаток до общего срока (GA_TIMER_LOCK_DEADLINE). Раньше миграция ждала свои 30 с, а действие — ещё 120,
            # и тик при занятом замке висел ~150 с (живая проверка 03.10.2026).
            if [ "${GOAMNEZIA_WHO:-}" = timer ]; then
                local tick_wait
                tick_wait=$(GA_TIMER_LOCK_DEADLINE="" ga_timer_lock_wait)
                GA_TIMER_LOCK_DEADLINE=$(( $(date +%s) + tick_wait ))
                GA_LOCK_WAIT="$tick_wait" GA_LOCK_QUIET=1 auto_migrate_state >&2 || true
            else
                auto_migrate_state >&2 || true
            fi
            _ga_after_update_rollback bridge "$@"
        fi
        action_dispatch "$@"
        exit $?
    fi

    case "${1:-}" in
        --selftest)
            # Автопроверка без сервера и без root (lib/selftest.sh).
            if type run_selftest >/dev/null 2>&1; then run_selftest; exit $?; fi
            if type selftest_run >/dev/null 2>&1; then selftest_run; exit $?; fi
            log_error "$(tf module_missing run_selftest)"
            exit 2
            ;;
        --version|-V)
            printf 'goAmnezia pro %s\n' "$GOAMNEZIA_VERSION"
            exit 0
            ;;
        --isolation-watch)
            # Служба goamnezia-isolation (lib/timers.sh): правило изоляции клиентов контейнеру профиля в ту же
            # секунду, как он стартовал, — и подхваченному у приложения, чей start.sh мы не трогаем (OPS-05).
            # Без модуля делать нечего: выход с 0, чтобы служба не перезапускалась вхолостую.
            type ga_amn_isolation_watch >/dev/null 2>&1 || exit 0
            _ga_preflight || exit 1
            ga_amn_isolation_watch
            exit $?
            ;;
        --panel-emergency-key)
            # Аварийный ключ панели без меню (SEC50-08): только SSH и эта команда — в мост для бота, панели и MCP
            # не выносится. Ни баннера, ни миграций: ключ и две строки, как у пункта меню.
            _ga_preflight || exit 1
            _panel_emergency_key
            exit $?
            ;;
        --help|-h)
            printf 'goAmnezia pro %s\n' "$GOAMNEZIA_VERSION"
            printf '  %s\n' "$(t help_usage)"
            printf '  --action=<name> [--k=v ...] [--json]\n'
            printf '  --lazy --domain=<domain> [--keys=N]\n'
            printf '  --panel-emergency-key\n'
            printf '  --selftest | --version | --help\n'
            exit 0
            ;;
    esac

    # Ленивый Pro без меню (goInstaller, docs/MODES_047.md п. 7): install.sh --lazy --domain=<домен> [--keys=N].
    local lazy=0 lazy_domain="" lazy_keys=""
    for a in "$@"; do
        case "$a" in
            --lazy)     lazy=1 ;;
            --domain=*) lazy_domain="${a#--domain=}" ;;
            --keys=*)   lazy_keys="${a#--keys=}" ;;
        esac
    done

    # bootstrap (exec bash) и `curl | bash`: stdin может быть не терминалом, и
    # тогда все read/confirm получают EOF — установка «сама себя отменяет».
    # Перецепляем на управляющий терминал.
    if [ ! -t 0 ] && { true < /dev/tty; } 2>/dev/null; then exec < /dev/tty; fi

    # Баннер — до ТЯЖЁЛЫХ шагов. Раньше между запуском и первой строкой проходило
    # несколько секунд тишины (установка зависимостей, миграция состояния,
    # обновление рабочих копий), и человек не понимал, запустилось ли вообще
    # (замечание критика). _ga_preflight остаётся выше: это мгновенные проверки
    # root и архитектуры плюс создание каталогов, без которых выбор языка
    # некуда записать, а рамку баннера не на чем считать.
    _ga_preflight || exit 1
    first_run_language_picker
    show_banner

    _ga_ensure_deps || { log_error "$(t deps_missing)"; exit 1; }

    auto_migrate_state || true
    _ga_after_update_rollback menu "$@"
    # Рабочие копии бота, панели и MCP обновляем из эталона /opt/goamnezia:
    # install.sh откатывает их к эталону, и деплой обязан попадать в оба места.
    auto_update_components || true

    local chg_from="${MIGRATED_FROM:-}"
    if [ -z "$chg_from" ] && [ -f "$GOAMNEZIA_DIR/.changelog_pending" ]; then
        chg_from=$(head -c 32 "$GOAMNEZIA_DIR/.changelog_pending" 2>/dev/null | tr -cd '0-9.')
    fi
    if [ -n "$chg_from" ]; then
        show_upgrade_changelog "$chg_from"
        # Сразу после «Что нового» — один раз сообщение об ошибке прошлых версий, если сервер в том состоянии
        # (DUP-LINE-01); дальше — строкой в шапке, пока не исправлено.
        _dupline_notice_once
        rm -f "$GOAMNEZIA_DIR/.changelog_pending" 2>/dev/null || true
    fi

    if [ "$lazy" = 1 ]; then
        # Битый config.json — не «не установлено»: второй установки поверх живой не будет (DEFECTS §1c.1).
        if [ -f "$CONFIG_FILE" ] && ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
            log_error "$(tf mn_config_broken "$CONFIG_FILE")"
            exit 1
        fi
        type lazy_setup >/dev/null 2>&1 || { log_error "$(tf module_missing lazy_setup)"; exit 1; }
        _lazy_headless "$lazy_domain" "$lazy_keys"
        exit $?
    fi

    # Мастер первой установки открывается ТОЛЬКО когда точно известно, что
    # установки нет. Решение принимал _cfg '.installed', а он отдаёт пустоту и
    # на «файла нет», и на «файл не разбирается». На битом конфиге мастер
    # поднимал ВТОРУЮ установку поверх живой: проверка «профиль установлен?»
    # тоже читала конфиг, отвечала «нет», и установка перезаписывала приватный
    # ключ сервера в state/. Следующее серверное действие уезжало с новым ключом
    # в контейнер, и все выданные ключи умирали — вместе с вновь выдаваемыми,
    # потому что выдача берёт открытый ключ из конфига (docs/DEFECTS.md §1c.1).
    if [ -f "$CONFIG_FILE" ] && ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
        echo ""
        log_error "$(tf mn_config_broken "$CONFIG_FILE")"
        log_warning "$(t mn_config_broken_what)"
        echo ""
        _pause
    elif _wz_legacy_pending; [ "$(_cfg '.installed')" != "true" ] || _wz_pending; then
        # Прерванная установка (запись .wizard; прежней версии — узнаёт _wz_legacy_pending) — тоже мастер, и при
        # installed=true: профили встали, а сайт, панель или первый пользователь — нет (INST-01). Ввод оборвался (3)
        # или идёт другой мастер (4) — меню без человека и поверх чужой установки ни к чему: как продолжить, мастер
        # уже сказал.
        _wz_session; rc=$?
        case "$rc" in 3|4) exit 1 ;; esac
        rc=0
    else
        # Установка уже есть: таймеры на месте (идемпотентно) и сверка пиров с
        # контейнерами — приложение Amnezia могло менять их напрямую (PLAN §6.5).
        _timers_apply
        _import_reconcile_prompt
    fi

    local rest="" ch=""
    while true; do
        # ga_clear_screen вместо `clear`: последний шлёт ещё и E3 (\033[3J) и
        # выбрасывает историю прокрутки — вместе с ней со страницы исчезал
        # только что показанный ключ первого пользователя (замечание критика).
        ga_clear_screen
        show_main_menu
        # Авто-обновление дашборда раз в 30 секунд.
        # ВАЖНО: различаем таймаут (rc > 128) и EOF (rc = 1). Без этого на
        # мёртвой SSH-сессии stdin отдаёт EOF мгновенно → busy-loop на 100 % CPU
        # (каждый виток форкает docker/jq в show_main_menu).
        # Первый символ — отдельно (read -n 1): в обычном режиме терминала недонабранная строка до Enter лежит в
        # буфере ядра, и read -t по таймауту её не отдаёт — перерисовка раз в 30 с прятала набранную цифру, а
        # повторный набор давал «22» и «Неверный выбор» (находка SR-53). Начал человек печатать — таймера больше
        # нет: остаток строки читаем без него, экран не трогаем.
        while true; do
            read -t 30 -r -n 1 choice; rc=$?
            if [ $rc -gt 128 ]; then
                choice=""; break
            elif [ $rc -ne 0 ]; then
                echo ""; log_info "$(t bye)"; exit 0
            fi
            if [ "$choice" = $'\e' ]; then
                # Функциональная клавиша: остаток последовательности уже в буфере — дочитываем по знаку без Enter.
                # F1 у разных терминалов: \eOP (xterm, iTerm, Tabby), \e[11~ (PuTTY), \e[[A (консоль Linux), \e[1P.
                rest=""
                while [ "${#rest}" -lt 6 ] && IFS= read -t 0.05 -r -n 1 ch 2>/dev/null; do rest+="$ch"; done
                case "$rest" in
                    OP|'[11~'|'[[A'|'[1P') choice="F1" ;;
                    *) choice="" ;;
                esac
            elif [ -n "$choice" ]; then
                IFS= read -r rest || rest=""
                choice="${choice}${rest%$'\r'}"
            fi
            break
        done
        # Пустой выбор — это таймаут или голый Enter: перерисовываем и ждём снова
        [ -n "$choice" ] || continue
        _dash_snapshot force

        case "$choice" in
            1) submenu_users ;;
            2) submenu_status ;;
            3) submenu_protocols ;;
            4) submenu_maintenance ;;
            5) submenu_settings ;;
            6) submenu_bot ;;
            F1|п|П|p|P) _panel_reveal && continue ;;
            0|q|exit) echo ""; log_info "$(t bye)"; exit 0 ;;
            *) log_error "$(t invalid_choice)" ;;
        esac

        _pause
    done
}

main "$@"
