#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# goAmnezia pro — lib/amnezia.sh: контейнеры AmneziaWG (контракт §4.4)
#
# Профиль = линейка = контейнер = порт (решение D2 плана): awg2 → amnezia-awg2
# (2.0, по умолчанию), awg3 → amnezia-awg3 (3.1), awg1 → amnezia-awg1 (1.0/1.5).
# Все три собираются из одного официального Dockerfile папки awg на образе
# amneziavpn/amneziawg-go по закреплённому дайджесту (D8).
#
# Порядок установки повторяет клиент Amnezia (PLAN §2.3): docker → сеть →
# каталог /opt/amnezia/<container> → build → run → конфиг → start.sh → файрвол
# хоста → проверка `awg show awg0`. Отличия от приложения:
#   • образ по дайджесту, а не `--pull latest`;
#   • start.sh — наша копия из lib/upstream/awg/ (идемпотентные правила iptables);
#   • серверный awg0.conf собирает `awgkeys.py server-conf` из config.json +
#     users.json, а не upstream configure_container.sh. Причина: у приложения
#     конфиг — это одноразовый heredoc с генерацией ключей внутри контейнера
#     (`awg genkey`), и повторно его не собрать; нам нужно переписывать конфиг
#     целиком после каждой операции с пользователями (источник правды —
#     users.json) и делать это одинаково на сервере и в dry-run без Docker.
#     configure_container.sh при этом остаётся эталоном имён переменных
#     ($AWG_SUBNET_IP, $AWG_SERVER_PORT, …) и путей (/opt/amnezia/awg/*.key,
#     awg0.conf) — файлы кладём ровно туда же, чтобы приложение и goWARP PRO
#     видели контейнер как «родной».
#
# Главная идея продукта — state/<container>/: хостовая копия /opt/amnezia/awg/*,
# /opt/amnezia/start.sh и /opt/warp/ (если есть). У официальной схемы томов нет,
# `docker rm` = потеря всех ключей; копия позволяет пересоздать контейнер
# (смена порта, обновление ядра, переезд) без перевыпуска ключей.
#
# Зависимости: lib/docker.sh (docker_*, ga_err, ga_dry), lib/common.sh (§4.1),
# lib/awgkeys.py (§4.2). Функции users_* вызываются только если загружены.
# ══════════════════════════════════════════════════════════════════════════════

# Пути внутри контейнера — официальные (configure_container.sh, start.sh).
GA_AWG_DIR="/opt/amnezia/awg"
GA_AWG_CONF="$GA_AWG_DIR/awg0.conf"
GA_AWG_CLIENTS_TABLE="$GA_AWG_DIR/clientsTable"
GA_AWG_SERVER_PRIV="wireguard_server_private_key.key"
GA_AWG_SERVER_PUB="wireguard_server_public_key.key"
GA_AWG_PSK="wireguard_psk.key"
GA_START_SH="/opt/amnezia/start.sh"
# goWARP PRO внутри контейнера профиля (NEIGHBOURS.md): /opt/warp — профиль WARP, выбор клиентов, метка «выключен»;
# /opt/warp-tools/usr — стандартные wg и wg-quick, которыми goWARP поднимает интерфейс warp (на модуле wireguard,
# а не amneziawg); блок «# --- WARP-MANAGER BEGIN/END ---» в start.sh — подъём WARP при каждом старте контейнера.
GA_WARP_DIR="/opt/warp"
GA_WARP_TOOLS_DIR="/opt/warp-tools"
GA_WARP_BLOCK_BEGIN="# --- WARP-MANAGER BEGIN ---"
GA_WARP_BLOCK_END="# --- WARP-MANAGER END ---"
# Сторож goWARP: --once поднимает WARP во всех работающих amnezia-awg* по их /opt/warp и блоку в start.sh.
GA_GOWARP_WATCH="${GOAMNEZIA_GOWARP_WATCH:-/usr/local/bin/gowarp-awg-watch}"
GA_AWG_IFACE="awg0"
GA_IMAGE_KEY="amneziawg-go"

# Каталог библиотек фиксируем при source: внутри функций cwd уже может быть другим.
GA_LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)}"

# ── Помощники ─────────────────────────────────────────────────────────────────

# Все криптооперации и форматы — в lib/awgkeys.py (один код на сервере и в
# dry-run; wireguard-tools на хосте не нужны). GOAMNEZIA_AWGKEYS — переопределение
# пути для тестов.
ga_awgkeys() {
    local py="${GOAMNEZIA_AWGKEYS:-$GA_LIB_DIR/awgkeys.py}"
    if [ ! -f "$py" ]; then
        ga_err awgkeys_missing "$(tf amnezia_err_awgkeys "$py")" 3
        return 3
    fi
    python3 "$py" "$@"
}

# Публичный ключ по приватному — приватник через stdin («-»), а не аргументом:
# аргументы видны в `ps` любому пользователю машины.
ga_awgkeys_pubkey() {
    printf '%s\n' "$1" | ga_awgkeys pubkey -
}

ga_profile_valid() { [[ "$1" =~ ^(awg1|awg2|awg3)$ ]]; }

# Значения по умолчанию ДЛЯ СВЕЖЕЙ УСТАНОВКИ из таблицы контракта §2.
# Идентификатор профиля — только имя: контейнер `amnezia-awg2`, поставленный
# приложением Amnezia, бывает какой угодно линейки, и после `import-adopt`
# спрашивать линейку у имени нельзя. Фактическую отдаёт ga_profile_line.
ga_profile_default() {
    case "$1:$2" in
        awg2:container) echo "amnezia-awg2" ;;
        awg2:line)      echo "2.0" ;;
        awg2:subnet)    echo "10.8.2.0/24" ;;
        awg3:container) echo "amnezia-awg3" ;;
        awg3:line)      echo "3.1" ;;
        awg3:subnet)    echo "10.8.3.0/24" ;;
        awg1:container) echo "amnezia-awg1" ;;
        awg1:line)      echo "1.5" ;;
        awg1:subnet)    echo "10.8.1.0/24" ;;
        *) return 1 ;;
    esac
}

# Поле профиля из config.json, иначе значение по умолчанию.
ga_profile_field() {
    local v
    v=$(ga_config_get ".profiles.$1.$2" 2>/dev/null)
    if [ -n "$v" ] && [ "$v" != "null" ]; then
        echo "$v"
        return 0
    fi
    ga_profile_default "$1" "$2"
}

ga_profile_installed() {
    local v
    v=$(ga_config_get ".profiles.$1.installed_at" 2>/dev/null)
    [ -n "$v" ] && [ "$v" != "null" ]
}

# ── Линейка профиля: спрашиваем состояние, а не имя ──────────────────────────
#
# ga_profile_line <профиль> → фактическая линейка (1.0 | 1.5 | 2.0 | 3.1).
# Источник правды — поле `line` в config.json: его пишет и установка (по
# detect-line от сгенерированных параметров), и подхват чужого контейнера (по
# конфигу внутри него). Поле пустое только у старых установок — тогда выводим
# линейку по фактическим `params` тем же detect-line; параметров нет вовсе
# (профиль ещё не установлен) — берём умолчание идентификатора.
ga_profile_line() {
    local profile="$1" line params
    line=$(ga_config_get ".profiles.$profile.line" 2>/dev/null)
    if [[ "$line" =~ ^(1\.0|1\.5|2\.0|3\.1)$ ]]; then
        echo "$line"
        return 0
    fi
    # Пустой объект detect-line считает линейкой 1.0 (в нём нет ни одного
    # признака старших) — такой ответ был бы враньём, поэтому пустые params
    # отсекаем до вызова.
    params=$(ga_config_get ".profiles.$profile.params" 2>/dev/null \
        | jq -c 'select(type == "object" and length > 0)' 2>/dev/null)
    if [ -n "$params" ]; then
        line=$(printf '%s' "$params" | ga_awgkeys detect-line 2>/dev/null | tr -d '[:space:]')
        if [[ "$line" =~ ^(1\.0|1\.5|2\.0|3\.1)$ ]]; then
            echo "$line"
            return 0
        fi
    fi
    ga_profile_default "$profile" line
}

# ga_key_file_base <имя> <профиль> → stdout основа имени файла ключа: <пользователь>-<линия> (anna-2_0), одна для
# SSH (файл .conf для scp), временной ссылки (lib/share.sh) и страницы подключения (lib/pages_server.py,
# key_file_base — то же правило). AmneziaWG берёт из имени файла имя туннеля, а Linux — не длиннее 15 знаков: имя —
# латиница до 10 знаков, линия — с подчёркиванием вместо точки (B3-6: «-20» не читалось как 2.0, а точку в середине
# имени файла некоторые программы принимают за начало расширения). Имя длиннее — начало и три знака его отпечатка
# (RR-3: verylongusername1 и verylongusername2 иначе давали один файл). Два профиля одной линии (подхват из
# приложения, DUP-LINE) — к линии номер места, имя на знак короче: anna-3_1-2 и anna-3_1-3 (R-6). Линию не узнать —
# имя места: anna-awg2. Ведущие дефисы имени снимаются (Н-6): туннель «-x-2_0» wg-quick передал бы ip link ключом.
# Имя файла ключа в ответе user-key (file_name) — это же правило: панель, бот и подписка берут его оттуда (Н-2).
ga_key_file_base() {
    local name="${1:-}" profile="${2:-}" base line other dup="" lim=10 h=2166136261 i c
    base="${name//[^A-Za-z0-9_-]/}"
    while [ "${base:0:1}" = "-" ]; do base="${base:1}"; done
    [ -n "$base" ] || base=key
    line=$(ga_profile_line "$profile" 2>/dev/null)
    if [[ "$line" =~ ^[0-9]\.[0-9]$ ]]; then
        for other in $(ga_config_get .profiles 2>/dev/null | jq -r 'keys[]?' 2>/dev/null); do
            [ "$other" != "$profile" ] && [[ "$other" =~ ^awg[0-9]$ ]] || continue
            [ "$(ga_profile_line "$other" 2>/dev/null)" = "$line" ] && { dup=1; break; }
        done
    fi
    [ -n "$dup" ] && lim=9
    if [ "${#base}" -gt "$lim" ]; then
        # FNV-1a (32 бита) по знакам имени — те же три знака считает страница (key_file_base в lib/pages_server.py)
        for ((i = 0; i < ${#base}; i++)); do
            printf -v c '%d' "'${base:i:1}"
            h=$(( ((h ^ c) * 16777619) & 0xFFFFFFFF ))
        done
        printf -v h '%03x' $((h & 0xFFF))
        base="${base:0:$((lim - 3))}${h}"
    fi
    if ! [[ "$line" =~ ^[0-9]\.[0-9]$ ]]; then
        printf '%s-%s' "$base" "$profile"
        return 0
    fi
    line="${line//./_}"
    [ -n "$dup" ] && [[ "$profile" =~ ^awg([0-9])$ ]] && line="${line}-${BASH_REMATCH[1]}"
    printf '%s-%s' "$base" "$line"
}

# ga_profile_line_base <профиль> → линейка, по которой проверяются и
# генерируются параметры этого профиля. Это фактическая линейка, поднятая до
# старшей в своём семействе: 1.0 и 1.5 отличаются только пакетами I1–I5, и
# профиль обязан ходить между ними в обе стороны (добавили I1 — стало 1.5,
# убрали — снова 1.0). Выше семейства не поднимаемся: линейки несовместимы,
# S3/S4 в конфиг 1.x и 3.x-поля в конфиг 2.0 пройти не должны.
# ga_line_family <линейка> → семейство: 1 (1.0 и 1.5), 2 (2.0), 3 (3.1). Линейки разных семейств несовместимы.
ga_line_family() {
    case "${1:-}" in
        1.0|1.5) echo 1 ;;
        2.0)     echo 2 ;;
        3.1)     echo 3 ;;
        *)       echo "${1:-}" ;;
    esac
}

ga_profile_line_base() {
    case "$(ga_profile_line "$1")" in
        1.0|1.5) echo "1.5" ;;
        2.0)     echo "2.0" ;;
        3.1)     echo "3.1" ;;
        *)       ga_profile_default "$1" line ;;
    esac
}

# ── Линии пары 2.0 / 3.1 на местах awg2 и awg3 (LZ-02 в режимах, DUP-LINE-01 в «Установить») ─────────────────────
# Место профиля (awg2, awg3) — только имя контейнера; линия — по версии. Приложение Amnezia держит 3.1 и в amnezia-awg2,
# и «Установить» свободного awg3 по месту (3.1) давало вторую 3.1 и ни одной 2.0: старые приложения и роутеры Keenetic
# не подключались ни к одному профилю (у пользователя 15.10). Правило одно — для Ленивого Pro (lib/modes.sh) и для
# «Установить» (SSH, панель, бот, мост profile-install): недостающая линия встаёт на своё место (2.0 → awg2,
# 3.1 → awg3), а если оно занято — на другое свободное. awg1 (1.x) — вне пары, его линию правило не трогает.
#
# ga_lines_need <линии мест> <занятые места> <добавить> <без места> — имена переменных вызывающего:
#   линии мест  — ассоциативный массив «место → линия» того, что на месте стоит (свой профиль или подхватываемый
#                 контейнер; «?» — не узнать);
#   занятые     — ассоциативный массив «место → 1»: место держит контейнер приложения с людьми, которого не берём;
#   добавить    — итог, массив «линия:место» по порядку 2.0 → 3.1;
#   без места   — итог, линии, которым места нет.
# Локальные — с приставкой _gln_: ссылка по имени (local -n) на массив вызывающего с тем же именем, что у локальной,
# указала бы на локальную.
ga_lines_need() {
    local -n _gln_line="$1" _gln_busy="$2" _gln_add="$3" _gln_skip="$4"
    local _gln_l _gln_s _gln_pref _gln_other _gln_have
    local -A _gln_used=()
    _gln_add=(); _gln_skip=()
    for _gln_l in 2.0 3.1; do
        _gln_have=0
        for _gln_s in awg1 awg2 awg3; do [ "${_gln_line[$_gln_s]:-}" = "$_gln_l" ] && _gln_have=1; done
        [ "$_gln_have" = 1 ] && continue
        if [ "$_gln_l" = 2.0 ]; then _gln_pref=awg2; _gln_other=awg3; else _gln_pref=awg3; _gln_other=awg2; fi
        for _gln_s in "$_gln_pref" "$_gln_other"; do
            [ -z "${_gln_line[$_gln_s]:-}" ] && [ -z "${_gln_busy[$_gln_s]:-}" ] && [ -z "${_gln_used[$_gln_s]:-}" ] || continue
            _gln_add+=("$_gln_l:$_gln_s"); _gln_used[$_gln_s]=1
            continue 2
        done
        _gln_skip+=("$_gln_l")
    done
    return 0
}

# ga_profile_lines_now <массив> — линии установленных профилей по местам (ga_profile_line) в ассоциативный массив
# вызывающего: «awg2 → 3.1». Не установленного места в массиве нет.
ga_profile_lines_now() {
    local -n _gpl_out="$1"
    local _gpl_p _gpl_l
    _gpl_out=()
    for _gpl_p in awg1 awg2 awg3; do
        ga_profile_installed "$_gpl_p" 2>/dev/null || continue
        _gpl_l=$(ga_profile_line "$_gpl_p" 2>/dev/null)
        _gpl_out[$_gpl_p]="${_gpl_l:-?}"
    done
    return 0
}

# ga_profile_auto_line <профиль> → линия, которая встанет на это место по «Установить» без просьбы о линии (DUP-LINE-01):
# правило ga_lines_need по тому, что стоит сейчас. Другое место пары уже держит линию этого места (подхваченный
# amnezia-awg2 с 3.1) — сюда встаёт вторая из пары (2.0 в awg3). awg1 — всегда своя 1.5. Профиль уже стоит — его линия.
# Тем же ответом меню, панель и бот подписывают свободное место заранее: «AmneziaWG 2.0 (awg3)».
ga_profile_auto_line() {
    local p="$1" e own other
    local -A _gpa_sl=() _gpa_sb=()
    local -a _gpa_add=() _gpa_skip=()
    case "$p" in
        awg2) own=2.0; other=awg3 ;;
        awg3) own=3.1; other=awg2 ;;
        *)    ga_profile_default "$p" line; return ;;
    esac
    ga_profile_lines_now _gpa_sl
    if [ -n "${_gpa_sl[$p]:-}" ] && [ "${_gpa_sl[$p]}" != "?" ]; then printf '%s\n' "${_gpa_sl[$p]}"; return 0; fi
    unset '_gpa_sl[$p]'
    ga_lines_need _gpa_sl _gpa_sb _gpa_add _gpa_skip
    for e in "${_gpa_add[@]}"; do
        [ "${e#*:}" = "$p" ] && { printf '%s\n' "${e%%:*}"; return 0; }
    done
    # Обе линии пары уже есть (2.0 держит, например, awg1): правило места — линия этого места у соседа по паре, значит
    # сюда вторая из пары; иначе — своя.
    if [ "${_gpa_sl[$other]:-}" = "$own" ]; then
        if [ "$own" = 2.0 ]; then printf '3.1\n'; else printf '2.0\n'; fi
        return 0
    fi
    printf '%s\n' "$own"
}

# ga_profile_line_shared <профиль> — у другого установленного профиля та же линия (две 3.1: подхваченная у приложения
# и своя, DUP-LINE-01): поле line_shared в status; подписка называет такую линию с портом.
ga_profile_line_shared() {
    local p="$1" l s
    ga_profile_installed "$p" 2>/dev/null || return 1
    l=$(ga_profile_line "$p" 2>/dev/null)
    [ -n "$l" ] || return 1
    for s in awg1 awg2 awg3; do
        [ "$s" = "$p" ] && continue
        ga_profile_installed "$s" 2>/dev/null || continue
        [ "$(ga_profile_line "$s" 2>/dev/null)" = "$l" ] && return 0
    done
    return 1
}

# ga_profile_title <профиль> [noport] → имя профиля для людей (решение владельца 15.10): без имени места awg2/awg3 —
# оно читалось как версия — и всегда с портом: «AmneziaWG 3.1 · порт 6714»; подхваченный у приложения Amnezia —
# «AmneziaWG 3.1 · порт 46567 · из приложения». Порт однозначен и есть у пользователя в приложении; две одинаковые
# линии (DUP-LINE-01) различаются им же. noport — где порт стоит рядом своей колонкой. Свободное место — по линии,
# которая на него встанет (ga_profile_auto_line): «AmneziaWG 2.0 — не установлена». Место и контейнер остаются только
# в технике: мост, MCP, журналы, аудит, ответы JSON.
ga_profile_title() {
    local p="$1" mode="${2:-}" l port app=""
    if ga_profile_installed "$p" 2>/dev/null; then
        l=$(ga_profile_line "$p" 2>/dev/null)
        if ! [[ "$l" =~ ^(1\.0|1\.5|2\.0|3\.1)$ ]]; then printf '%s' "$p"; return 0; fi
        [ "$(ga_config_get ".profiles.$p.imported" 2>/dev/null)" = true ] && app=1
        port=$(ga_profile_field "$p" port 2>/dev/null)
        if [ "$mode" != noport ] && [[ "$port" =~ ^[0-9]{1,5}$ ]]; then
            if [ -n "$app" ]; then printf '%s' "$(tf pr_title_port_app "$l" "$port")"; else printf '%s' "$(tf pr_title_port "$l" "$port")"; fi
        elif [ -n "$app" ]; then
            printf '%s' "$(tf pr_title_app "$l")"
        else
            printf '%s' "$(tf pr_title_line "$l")"
        fi
        return 0
    fi
    case "$p" in
        awg2|awg3) printf '%s' "$(tf pr_title_free "$(ga_profile_auto_line "$p")")" ;;
        awg1)      printf '%s' "$(tf pr_title_free "$(ga_profile_auto_line awg1)")" ;;   # 1.5 — так и встанет (LABEL-02)
        *)         printf '%s' "$p" ;;
    esac
}

# Миграция старых установок: профиль без поля `line` (или с мусором в нём)
# получает линейку по фактическим параметрам. Зовётся из auto_migrate_state
# под замком конфига; идемпотентна — писать нечего, значит ничего и не пишет.
# stdout: строки «профиль=линейка» на то, что действительно поправили.
ga_migrate_profile_line() {
    local profile line stored patch list
    [ -f "$CONFIG_FILE" ] || return 0
    # Список берём загрузчиком: `< <(ga_profiles_installed)` терял бы код отказа
    # так же, как подстановка команды, и миграция на битом конфиге тихо ничего
    # бы не сделала — а чинить старую установку она обязана до первой записи.
    ga_profiles_load list || return 1
    while IFS= read -r profile; do
        [ -n "$profile" ] || continue
        stored=$(ga_config_get ".profiles.$profile.line" 2>/dev/null)
        [[ "$stored" =~ ^(1\.0|1\.5|2\.0|3\.1)$ ]] && continue
        line=$(ga_profile_line "$profile")
        [[ "$line" =~ ^(1\.0|1\.5|2\.0|3\.1)$ ]] || continue
        patch=$(jq -cn --arg p "$profile" --arg l "$line" '{profiles: {($p): {line: $l}}}') || continue
        ga_config_merge "$patch" >/dev/null 2>&1 || continue
        printf '%s=%s\n' "$profile" "$line"
    done <<<"$list"
    return 0
}

# Установленные AWG-профили (по одному в строке).
#
# ВАЖНО (договор §4.1, тот же класс, что и users.json): неразбираемый
# config.json — это НЕ «профилей нет». Раньше здесь стоял голый jq без проверки
# кода, и на битом конфиге функция молча печатала пустоту. Дальше по списку
# ходят три сторожа продукта — amnezia_watch_tick, users_quota_tick и
# stats_tick, — и пустой список они читали как «делать нечего»: сторож
# переставал сторожить, лимиты и сроки не применялись, статистика замирала, и
# все трое отчитывались «успешно». Слепота, о которой никто не узнаёт, хуже
# честного отказа: пусть тик откажет кодом config_corrupt, а человек
# восстановит конфиг из спасательной копии (её снимает ga_config_intact).
ga_profiles_installed() {
    [ -f "$CONFIG_FILE" ] || return 0
    # Проверка В ТЕКУЩЕЙ оболочке и ДО чтения — как ga_users_intact: она же
    # спасает копию файла и объясняет человеку, где эта копия лежит.
    if type ga_config_intact >/dev/null 2>&1; then
        ga_config_intact || return 1
    fi
    jq -r '.profiles // {} | to_entries[]
           | select((.value.installed_at // "") != "")
           | select(.key | test("^awg[123]$"))
           | .key' "$CONFIG_FILE" 2>/dev/null
}

# ga_profiles_load <переменная> — ЕДИНСТВЕННОЕ правильное обращение к списку
# профилей для всех, кто ходит по нему циклом.
#
# Почему не `for p in $(ga_profiles_installed)`: подстановка команды съедает код
# возврата (её код — код последней команды конвейера, а сама функция живёт в
# подоболочке, откуда не доходит ни GA_LAST_ERROR_CODE, ни решение отказать).
# Ровно на этом продукт слеп: битый конфиг давал пустой список и «успешно».
# То же относится к `< <(…)` и `mapfile < <(…)` — там код теряется так же.
# Парный образец — ga_users_load (lib/common.sh).
#
# В переменную кладётся список строк (профиль на строку); пустая строка —
# законное «установленных профилей нет», rc 1 — «конфиг прочитать нельзя».
ga_profiles_load() {
    local __var="${1:?}" __list
    # Проверку делаем ЗДЕСЬ, в текущей оболочке, и только потом читаем: код
    # config_corrupt, выставленный внутри $( ), наружу бы не дожил, и мост с
    # ботом получили бы отказ без объяснения.
    if [ -f "$CONFIG_FILE" ] && type ga_config_intact >/dev/null 2>&1; then
        ga_config_intact || return 1
    fi
    __list=$(ga_profiles_installed) || { ga_set_error config_corrupt; return 1; }
    printf -v "$__var" '%s' "$__list"
    return 0
}

# Проверка id профиля с кодами для моста.
ga_profile_check() {
    local profile="$1"
    if ! ga_profile_valid "$profile"; then
        ga_err invalid_profile "$(tf amnezia_err_profile "$profile")" 2
        return 2
    fi
    return 0
}

ga_profile_check_installed() {
    ga_profile_check "$1" || return $?
    if ! ga_profile_installed "$1"; then
        ga_err profile_not_installed "$(tf amnezia_err_not_installed "$1")" 3
        return 3
    fi
    return 0
}

# ga_amn_docker_up <состояние> — общий отказ на «демон Docker недоступен».
#
# Зачем отдельной функцией, а не проверкой на месте: docker_container_state
# теперь умеет отвечать docker_unreachable («мы не знаем»), и любая операция,
# которая без демона всё равно ничего не сделает, обязана остановиться ЗДЕСЬ, с
# понятным кодом, а не свалиться на середине — половина смены порта хуже, чем
# несделанная смена порта. Вызывать надо в текущей оболочке (не через $(…)):
# ga_err кладёт код в переменные процесса, подоболочка их теряет.
ga_amn_docker_up() {
    [ "${1:-}" = "$GA_DOCKER_STATE_UNREACHABLE" ] || return 0
    ga_err docker_unreachable "$(t docker_err_unreachable)" 1
}

# ga_amn_foreign_peers <контейнер> → stdout: сколько [Peer] в конфиге
# контейнера, которого нет в config.json (0 — контейнера нет, конфига нет или
# Docker не отвечает). Имена amnezia-awg1/2/3 у нас те же, что у контейнеров
# приложения Amnezia, и установка профиля сносила такой «остаток» без вопросов —
# вместе с ключами всех, кто через него ходит. Их приватные ключи хранит
# приложение, перевыпустить людям нечего. Legacy-контейнер amnezia-awg живёт
# на wg0.conf, поэтому смотрим оба имени.
ga_amn_foreign_peers() {
    local container="$1" state path raw=""
    if ! ga_dry && ! command -v docker >/dev/null 2>&1; then echo 0; return 0; fi
    ga_capture state docker_container_state "$container"
    case "$state" in running|exited) ;; *) echo 0; return 0 ;; esac
    for path in /opt/amnezia/awg/awg0.conf /opt/amnezia/awg/wg0.conf; do
        raw=$(docker_read_file_any "$container" "$path" 2>/dev/null) || raw=""
        [ -n "$raw" ] && break
    done
    printf '%s\n' "$raw" | grep -ciE '^[[:space:]]*\[peer\][[:space:]]*$' || true
}

# ga_amn_foreign_guard <контейнер> — отказ foreign_container, если в чужом
# контейнере есть люди. В текущей оболочке, не в $( ): ga_err кладёт код в
# переменные процесса.
ga_amn_foreign_guard() {
    local n
    n=$(ga_amn_foreign_peers "$1")
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ] || return 0
    ga_err foreign_container "$(tf amnezia_err_foreign_container "$1" "$n")"
    return 1
}

ga_amn_state_dir() { echo "$STATE_DIR/$(ga_profile_field "$1" container)"; }

# Интерфейс, утилита и путь конфига профиля внутри контейнера. Наши контейнеры
# живут на awg0/awg (образ amneziawg-go); legacy-контейнер amnezia-awg (образ
# amnezia-wg, AmneziaWG 1.x), подхваченный импортом, — на wg0/wg и wg0.conf.
# В state/ наша копия конфига всегда называется awg0.conf: имя внутри
# контейнера — свойство контейнера, а не копии (приводит ga_amn_state_canon).
ga_amn_iface() {
    local v
    v=$(ga_profile_field "$1" iface 2>/dev/null)
    [[ "$v" =~ ^(awg|wg)[0-9]$ ]] || v="$GA_AWG_IFACE"
    echo "$v"
}
ga_amn_tool() { case "$(ga_amn_iface "$1")" in wg*) echo wg ;; *) echo awg ;; esac; }
ga_amn_conf_path() { echo "$GA_AWG_DIR/$(ga_amn_iface "$1").conf"; }

# ── Движок профиля: модуль ядра или программа (KMOD_PLAN, этап А0) ────────────
# Контейнеры привилегированные, с SYS_MODULE и /lib/modules хоста, а awg-quick в образе сначала пробует
# `ip link add awg0 type amneziawg` и только потом программу amneziawg-go. Модуль ядра, который на хосте поставил
# кто-то другой (сосед, человек вручную), при следующем рестарте молча переводит профиль на ядро. Поэтому движок —
# то, что стоит в контейнере сейчас, а не настройка: тип интерфейса по `ip -d link` (amneziawg — модуль, tun —
# программа), запасом — sysfs (DEVTYPE= в uevent у модуля, tun_flags у tun), если ip в образе без -d.
# Подхваченный legacy-контейнер amnezia-awg (образ amnezia-wg от 03.10.2023: alpine, iproute2, wireguard-go, wg,
# wg-quick) живёт на wg0, и его wg-quick — прежний WireGuard: `type wireguard`, затем wireguard-go. Там бывает tun
# (программа) или wireguard (обычный модуль ядра WireGuard, если он есть на хосте), но не amneziawg; wireguard
# считаем ядром — syncconf без маскировки ему тоже безопасен.

# ga_amn_engine_parse < ответ контейнера → kernel | program | unknown (ничего не узнали — unknown).
ga_amn_engine_parse() {
    awk '{ sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "") }
         /^(amneziawg|wireguard)[[:space:]]/ || /^(amneziawg|wireguard)$/ || /^DEVTYPE=(amneziawg|wireguard)$/ { k = 1 }
         /^tun[[:space:]]/ || /^tun$/ || /^tun_flags=/ { p = 1 }
         END { if (k) print "kernel"; else if (p) print "program"; else print "unknown" }'
}

# ga_amn_engine_of <контейнер> <интерфейс> → kernel | program | unknown, один docker exec. unknown — контейнер не
# отвечает или интерфейса нет; вызывающие считают его ядром (так безопасно). Стенд (GOAMNEZIA_DRY_RUN=1): ответ
# контейнера — файл .iplink в каталоге-фикстуре (GOAMNEZIA_CONTAINER_FS_DIR, как .state и .image); без файла —
# program, как у всех серверов сегодня.
ga_amn_engine_of() {
    local container="$1" iface="$2" cmd fs out
    [[ "$iface" =~ ^(awg|wg)[0-9]$ ]] || { echo unknown; return 0; }
    cmd="ip -d link show dev $iface 2>/dev/null; cat /sys/class/net/$iface/uevent 2>/dev/null; [ -e /sys/class/net/$iface/tun_flags ] && echo tun_flags=1; exit 0"
    if ga_dry; then
        ga_dry_echo "docker exec -i $container sh -c '$cmd'"
        if fs=$(ga_docker_fs_path "$container" ".iplink") && [ -f "$fs" ]; then
            ga_amn_engine_parse <"$fs"
        else
            echo program
        fi
        return 0
    fi
    out=$(ga_docker exec -i "$container" sh -c "$cmd" </dev/null 2>/dev/null) || out=""
    printf '%s\n' "$out" | ga_amn_engine_parse
}

# ga_amn_engine <профиль> → kernel | program | unknown (см. выше). Один вызов на действие: кому движок нужен дважды
# (проверка параметров и применение), передаёт его дальше, а не спрашивает снова.
ga_amn_engine() { ga_amn_engine_of "$(ga_profile_field "$1" container)" "$(ga_amn_iface "$1")"; }

# ── Модуль ядра AmneziaWG на хосте (KMOD_PLAN, этап А3) ──────────────────────
# Метка набора исправлений (навык Kaskad amneziawg-kernel-module): сборка с набором дописывает к WIREGUARD_VERSION
# «+kaskad-k31.N», её же видно в /sys/module/amneziawg/version. Этап Б берёт ту же метку; «+goamnezia-k31» — на
# случай своей. Без метки модуль считаем стоковым: на нём syncconf с HeaderProtectionKey под трафиком вешает сервер
# с 1 vCPU или даёт kernel panic (upstream #253). Наш syncconf маскировку на модуль больше не шлёт (KMOD-01), но
# приложение Amnezia, когда меняет людей по SSH, шлёт весь [Interface].
GA_KMOD_PATCH_RE='\+(kaskad|goamnezia)-k31'
# Каталог модулей ядра; стенд и тесты подменяют его GOAMNEZIA_SYS_MODULE_DIR.
ga_kmod_sys_dir() { printf '%s/amneziawg' "${GOAMNEZIA_SYS_MODULE_DIR:-/sys/module}"; }

# ga_amn_kmod_json → поле status.kmod: {loaded, version, patched, warn}. loaded — модуль amneziawg в памяти,
# version — его версия (пусто — не узнать), patched — есть метка набора, warn — загружен без метки, а у нас есть
# профиль 3.1 (предупреждение в шапке SSH, на «Обзоре» панели и на главном экране бота). Только чтение: ничего не
# ставит и не перезапускает — выбор и пересборка будут в этапе Б.
ga_amn_kmod_json() {
    local dir ver="" loaded=false patched=false warn=false list p
    dir=$(ga_kmod_sys_dir)
    if [ -d "$dir" ]; then
        loaded=true
        ver=$(head -c 128 "$dir/version" 2>/dev/null | tr -cd 'A-Za-z0-9.+_~-')
        [[ "$ver" =~ $GA_KMOD_PATCH_RE ]] && patched=true
    fi
    if [ "$loaded" = true ] && [ "$patched" = false ]; then
        list=$(ga_profiles_installed 2>/dev/null) || list=""
        for p in $list; do
            [ "$(ga_profile_line "$p" 2>/dev/null)" = 3.1 ] && { warn=true; break; }
        done
    fi
    jq -cn --argjson l "$loaded" --arg v "$ver" --argjson p "$patched" --argjson w "$warn" \
        '{loaded: $l, version: $v, patched: $p, warn: $w}'
}

ga_amn_state_init() {
    mkdir -p "$1" || return 1
    chmod 700 "$1"
}

# ── Копия конфига в state/ — всегда awg0.conf (находка ACC-4) ────────────────
# По этому имени копию ищут восстановление из бэкапа, «Поднять заново», обновление ядра, сверка ключей и
# выдача адресов. А amnezia_state_sync клал в state/ каталог контейнера как есть, и у подхваченного
# legacy-контейнера (amnezia-awg, wg0) после первой же синхронизации копия называлась wg0.conf:
# восстановление отвечало state_missing, контейнер не пересоздавался, а пиры, которых нет в восстановленном
# users.json, оставались живыми (живая приёмка 27.09.2026).
#
# ga_amn_state_canon <каталог> <интерфейс> [live] — <интерфейс>.conf → awg0.conf (0600). Если awg0.conf
# уже есть, без live прежнее имя — устаревший дубль (awg0.conf пишет amnezia_write_server_conf уже после
# синхронизации) и убирается; live — каталог только что снят с контейнера, и побеждает конфиг интерфейса:
# его контейнер и применяет. Ключа сервера отдельным файлом у контейнера приложения может не быть — тогда он
# берётся из строки PrivateKey копии (с ним контейнер и работает), открытый — из приватного: иначе
# синхронизация стирала бы единственную хостовую копию ключа, записанную подхватом.
# Что сделано — в GA_AMN_STATE_CANON_DONE (conf, keys); не удалось переименовать — код state_failed.
GA_AMN_STATE_CANON_DONE=""
ga_amn_state_canon() {
    local dir="$1" iface="${2:-}" mode="${3:-}" priv pub
    GA_AMN_STATE_CANON_DONE=""
    [ -d "$dir" ] || return 0
    if [[ "$iface" =~ ^(awg|wg)[0-9]$ ]] && [ "$iface" != "$GA_AWG_IFACE" ] && [ -f "$dir/$iface.conf" ]; then
        if [ -f "$dir/awg0.conf" ] && [ "$mode" != live ]; then
            rm -f "$dir/$iface.conf"
        elif ! mv -f "$dir/$iface.conf" "$dir/awg0.conf"; then
            ga_err state_failed "$(tf amnezia_err_state "$dir")"
            return 1
        fi
        chmod 600 "$dir/awg0.conf" 2>/dev/null
        GA_AMN_STATE_CANON_DONE="conf"
    fi
    if [ ! -s "$dir/$GA_AWG_SERVER_PRIV" ] && [ -f "$dir/awg0.conf" ]; then
        # Режем ровно по ПЕРВОМУ «=»: ключ base64 сам кончается на «=».
        priv=$(sed -n 's/^PrivateKey[[:space:]]*=[[:space:]]*//p' "$dir/awg0.conf" 2>/dev/null | head -n 1 | tr -d '[:space:]')
        if [[ "$priv" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
            printf '%s\n' "$priv" | ga_amn_write_secret "$dir/$GA_AWG_SERVER_PRIV" \
                || { ga_err state_failed "$(tf amnezia_err_state "$dir")"; return 1; }
            GA_AMN_STATE_CANON_DONE="${GA_AMN_STATE_CANON_DONE:+$GA_AMN_STATE_CANON_DONE }keys"
        fi
    fi
    if [ ! -s "$dir/$GA_AWG_SERVER_PUB" ] && [ -s "$dir/$GA_AWG_SERVER_PRIV" ]; then
        pub=$(ga_awgkeys_pubkey "$(head -n 1 "$dir/$GA_AWG_SERVER_PRIV" | tr -d '[:space:]')" 2>/dev/null) || pub=""
        [[ "$pub" =~ ^[A-Za-z0-9+/]{43}=$ ]] && printf '%s\n' "$pub" | ga_amn_write_secret "$dir/$GA_AWG_SERVER_PUB"
    fi
    return 0
}

# ga_amn_state_conf <профиль> → путь копии конфига профиля в state/: awg0.conf, а у копии прежних версий,
# которую ещё не привели, — <интерфейс>.conf. Только чтение (сверка ключей, выдача адресов): переименовывать
# им нельзя, а промахиваться мимо копии — тоже.
ga_amn_state_conf() {
    local sdir iface
    sdir=$(ga_amn_state_dir "$1")
    iface=$(ga_amn_iface "$1")
    if [ ! -f "$sdir/awg0.conf" ] && [ "$iface" != "$GA_AWG_IFACE" ] && [ -f "$sdir/$iface.conf" ]; then
        printf '%s/%s.conf' "$sdir" "$iface"
    else
        printf '%s/awg0.conf' "$sdir"
    fi
}

# ga_amn_state_canon_all → stdout: профили, чью копию состояния привели (по одному в строке). Зовёт миграция
# (install.sh, _migrate_state_conf): у серверов прежних версий копия подхваченного legacy-профиля уже лежит
# под wg0.conf. Идемпотентна — приведённой копии ничего не делается; rc 1 — config.json не читается.
ga_amn_state_canon_all() {
    local p list
    ga_profiles_load list || return 1
    for p in $list; do
        ga_amn_state_canon "$(ga_amn_state_dir "$p")" "$(ga_amn_iface "$p")" || continue
        [ -n "$GA_AMN_STATE_CANON_DONE" ] && printf '%s\n' "$p"
    done
    return 0
}

# Запись секрета на хост: 0600 с первого байта (umask в подоболочке).
ga_amn_write_secret() (
    umask 077
    cat >"$1"
)

ga_amn_port_valid() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

# Порт свободен для профиля: не занят другим профилем в config.json (443 может
# держать только один профиль — там сайт по TCP, а UDP/443 один), не слушается
# на хосте и не опубликован другим контейнером.
ga_amn_port_check() {
    local profile="$1" port="$2" owner
    if ! ga_amn_port_valid "$port"; then
        ga_err invalid_port "$(tf amnezia_err_port "$port")" 2
        return 2
    fi
    if [ -f "$CONFIG_FILE" ]; then
        owner=$(jq -r --argjson p "$port" --arg me "$profile" \
            '.profiles // {} | to_entries[] | select(.key != $me and .value.port == $p) | .key' \
            "$CONFIG_FILE" 2>/dev/null | head -n 1)
        if [ -n "$owner" ]; then
            ga_err port_busy "$(tf amnezia_err_port_taken "$port" "$owner")"
            return 1
        fi
    fi
    if ! docker_port_free "$port" udp; then
        ga_err port_busy "$(tf amnezia_err_port_busy "$port")"
        return 1
    fi
    return 0
}

# qrencode — необязательная зависимость (профиль qr в lib/deps.sh), но без неё
# `user-key --format=all` отказывает целиком, а меню не рисует QR. Мастер ставит
# её сам, а установка через мост (бот, панель, MCP, CI) мастера не проходит — и
# на таком сервере ключ картинкой было не выдать. Спрашиваем deps, только когда
# команды нет или она несовместима: иначе каждая установка профиля печатала бы «ставить
# нечего». В dry-run не трогаем пакеты.
ga_amn_ensure_qr_dep() {
    ga_dry && return 0
    if command -v qrencode >/dev/null 2>&1; then
        if ! type _deps_check_cmd >/dev/null 2>&1 || _deps_check_cmd qrencode; then return 0; fi
    fi
    type deps_install_missing >/dev/null 2>&1 || return 0
    deps_install_missing --yes qr >&2 || true
    return 0
}

# Порт по умолчанию: Pro + awg2 → UDP/443 (сайт на TCP/443 не мешает — разные
# сокеты, а UDP/443 снаружи выглядит как HTTP/3); иначе случайный из низкого
# диапазона 1024–9999 (решение владельца 10.09.2026 — такие порты реже режут
# промежуточные сети), общеизвестные пропускаем. Весь низкий диапазон занят —
# честно откатываемся на прежние 30000–49999, как выбирает само приложение.
# Второй аргумент no443 — «только случайный»: профиль уходит С UDP/443 (другая линия встаёт на 443 в Pro, pro-line),
# и 443 ему предлагать нельзя — это его нынешний порт.
ga_amn_pick_port() {
    local profile="$1" skip443="${2:-}" mode port i
    mode=$(ga_config_get ".mode" 2>/dev/null)
    if [ "$mode" = "pro" ] && [ "$profile" = "awg2" ] && [ "$skip443" != no443 ]; then
        if ga_amn_port_check "$profile" 443 2>/dev/null; then
            echo 443
            return 0
        fi
    fi
    for ((i = 0; i < 80; i++)); do
        port=$(ga_port_random "$GA_PORT_LOW_MIN" "$GA_PORT_LOW_MAX")
        ga_port_wellknown "$port" && continue
        if ga_amn_port_check "$profile" "$port" 2>/dev/null; then
            # Неудачные пробы выше оставили код port_busy — сбрасываем, порт найден.
            GA_ERR_CODE=""; GA_ERR_MSG=""
            echo "$port"
            return 0
        fi
    done
    log_warning "$(t amnezia_port_low_none)" >&2
    for ((i = 0; i < 50; i++)); do
        port=$(ga_port_random "$GA_PORT_HIGH_MIN" "$GA_PORT_HIGH_MAX")
        if ga_amn_port_check "$profile" "$port" 2>/dev/null; then
            GA_ERR_CODE=""; GA_ERR_MSG=""
            echo "$port"
            return 0
        fi
    done
    ga_err port_busy "$(t amnezia_err_no_free_port)"
    return 1
}

# Места под образ и слои сборки хватает? check_disk_space (lib/common.sh) был
# написан, переведён и записан в договор — и не вызван ни разу: на заполненном
# диске человек получал «не удалось записать» и английскую ошибку системы, а
# про место продукт не говорил ни слова. Гигабайт — это образ (~60 МБ), слои
# сборки и распакованный контекст с запасом: меньше — и docker валится на
# полпути, оставляя недособранный контейнер.
GA_AMN_MIN_DISK_MB=1024
ga_amn_disk_ok() {
    type check_disk_space >/dev/null 2>&1 || return 0
    check_disk_space "$GA_AMN_MIN_DISK_MB" && return 0
    # check_disk_space уже сказала вслух, сколько места есть и сколько надо —
    # второй раз не печатаем. Здесь остаётся код и сообщение для моста, бота и
    # панели: без них агент увидит голый rc и не отличит нехватку места от
    # любой другой беды.
    GA_ERR_CODE=low_disk
    GA_ERR_MSG="$(tf amnezia_err_low_disk "$GA_AMN_MIN_DISK_MB")"
    ga_set_error low_disk
    return 1
}

# Каталог сборки — /opt/amnezia/<container>, как DOCKERFILE_FOLDER у приложения
# (prepare_host.sh). В dry-run — временный каталог, чтобы не трогать хост.
ga_amn_build_dir() {
    local container="$1" root="${GOAMNEZIA_BUILD_ROOT:-}"
    if [ -z "$root" ]; then
        if ga_dry; then
            root=$(mktemp -d) || return 1
        else
            root="/opt/amnezia"
        fi
    fi
    mkdir -p "$root/$container" || return 1
    echo "$root/$container"
}

# Контекст сборки: официальный Dockerfile, но FROM закреплён на repo@digest.
# Без --pull docker всё равно скачает отсутствующий тег latest из реестра, а он
# у Amnezia переезжает без предупреждения — только дайджест воспроизводим.
ga_amn_build_context() {
    local container="$1" ref="$2" dir src
    src="$UPSTREAM_DIR/awg/Dockerfile"
    if [ ! -f "$src" ]; then
        ga_err upstream_missing "$(tf amnezia_err_upstream "$src")" 3
        return 3
    fi
    dir=$(ga_amn_build_dir "$container") || return 1
    sed -e "s|^FROM .*|FROM $ref|" "$src" >"$dir/Dockerfile" || return 1
    echo "$dir"
}

# Сборка образа профиля с запасными зеркалами пакетов Alpine. Официальный
# Dockerfile ставит пакеты `apk add` из dl-cdn.alpinelinux.org, и на части
# серверов этот CDN не отвечает или отказывает («Permission denied», «stale/
# unavailable repositories»): на живом прогоне 24.09.2026 в Москве профиль
# так и не встал — сборка падала после восьми минут ожидания. Сперва собираем
# как есть; не вышло — пробуем зеркала по очереди. Зеркало вписывается строкой
# RUN сразу после FROM только в копию Dockerfile в каталоге сборки: сам
# вендоренный lib/upstream/awg/Dockerfile не меняется. Список зеркал —
# GOAMNEZIA_APK_MIRRORS (через пробел).
GA_AMN_APK_MIRRORS_DEFAULT="https://dl-4.alpinelinux.org/alpine https://mirror.yandex.ru/mirrors/alpine"
ga_amn_apk_mirror_file() { printf '%s/state/apk_mirror' "$GOAMNEZIA_DIR"; }
ga_amn_docker_build() {
    local container="$1" dir="$2" m f saved=""
    f="$dir/Dockerfile"
    # Зеркало, на котором сборка уже удавалась на этой машине, — сразу: иначе
    # каждый следующий профиль снова ждал бы отказа CDN (на живом прогоне это
    # восемь минут на профиль).
    if ! ga_dry && [ -f "$f" ]; then
        saved=$(head -n 1 "$(ga_amn_apk_mirror_file)" 2>/dev/null) || saved=""
        [[ "$saved" =~ ^https?://[A-Za-z0-9._/-]+$ ]] || saved=""
        [ -n "$saved" ] && ga_amn_dockerfile_mirror "$f" "$saved"
    fi
    docker_build "$container" "$dir" && return 0
    ga_dry && return 1
    [ -f "$f" ] || return 1
    # Запомненное зеркало не сработало — дальше основной CDN (без строки зеркала), и только потом прочие
    # зеркала. Раньше основной CDN после первого же запомненного зеркала не пробовался больше никогда, а
    # умершее зеркало так и оставалось запомненным (находка SR-36).
    if [ -n "$saved" ]; then
        rm -f "$(ga_amn_apk_mirror_file)" 2>/dev/null || true
        ga_amn_dockerfile_mirror "$f" "" || return 1
        log_warning "$(t amnezia_build_retry_cdn)" >&2
        GA_ERR_CODE=""; GA_ERR_MSG=""; GA_LAST_ERROR_CODE=""
        docker_build "$container" "$dir" && return 0
    fi
    for m in ${GOAMNEZIA_APK_MIRRORS:-$GA_AMN_APK_MIRRORS_DEFAULT}; do
        [[ "$m" =~ ^https?://[A-Za-z0-9._/-]+$ ]] || continue
        [ "$m" = "$saved" ] && continue
        log_warning "$(tf amnezia_build_retry_mirror "$m")" >&2
        ga_amn_dockerfile_mirror "$f" "$m" || return 1
        # Код прошлой попытки — долой вместе с текстом: иначе после удачной сборки через зеркало мост мог
        # ответить build_failed на отказ следующего шага без своего кода (SR-36).
        GA_ERR_CODE=""; GA_ERR_MSG=""; GA_LAST_ERROR_CODE=""
        if docker_build "$container" "$dir"; then
            mkdir -p "$(dirname "$(ga_amn_apk_mirror_file)")" 2>/dev/null
            printf '%s\n' "$m" >"$(ga_amn_apk_mirror_file)" 2>/dev/null || true
            return 0
        fi
    done
    return 1
}

# ga_amn_dockerfile_mirror <Dockerfile> <зеркало> — вписать строку зеркала сразу
# после FROM. Прежняя строка зеркала (если была) убирается: зеркала не наслаиваются.
# Пустое зеркало — только убрать строку зеркала: сборка через основной CDN (SR-36). Строка зеркала не роняет
# сборку на образе без /etc/apk/repositories.
ga_amn_dockerfile_mirror() {
    local f="$1" m="$2" tmp
    tmp=$(mktemp) || return 1
    grep -v 'goamnezia-apk-mirror' "$f" | awk -v m="$m" '
        /^FROM / && !done && m != "" { print; printf "RUN [ ! -f /etc/apk/repositories ] || sed -i -E \"s#https?://[^/]+/alpine#%s#\" /etc/apk/repositories # goamnezia-apk-mirror\n", m; done = 1; next }
        { print }' >"$tmp" && mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# Наш start.sh (lib/upstream/awg/start.sh) с подстановкой переменных приложения.
# Замена — строковая, как replaceVars у клиента: значения простые (IP, маска),
# и bash-подстановка не спотыкается на спецсимволах sed.
ga_amn_render_start_sh() {
    local profile="$1" src text subnet subnet_ip cidr server_ip want=on
    src="$UPSTREAM_DIR/awg/start.sh"
    if [ ! -f "$src" ]; then
        ga_err upstream_missing "$(tf amnezia_err_upstream "$src")" 3
        return 3
    fi
    subnet=$(ga_profile_field "$profile" subnet)
    subnet_ip="${subnet%/*}"
    cidr="${subnet#*/}"
    server_ip=$(ga_config_get ".server_ip" 2>/dev/null)
    text=$(<"$src")
    text=${text//\$AWG_SUBNET_IP/$subnet_ip}
    text=${text//\$WIREGUARD_SUBNET_CIDR/$cidr}
    text=${text//\$SERVER_IP_ADDRESS/$server_ip}
    # Изоляция клиентов — строкой в самом start.sh: правило ставится при каждом старте контейнера, и без нас
    # тоже (--restart always, перезагрузка хоста). В вендоренный файл её не вписываем: он — копия upstream.
    # Тем же путём — MSS по MTU туннеля и блок движка AmneziaWG (ga_amn_start_sh_ours).
    ga_amn_isolation_on || want=off
    text=$(ga_amn_start_sh_ours "$text" "$(ga_amn_iface "$profile")" "$want") || return 1
    printf '%s\n' "$text"
}

# ── Изоляция клиентов профиля (SEC-NET-1) ────────────────────────────────────
# start.sh контейнера — и наш, и приложения — разрешает `FORWARD -i awg0 -j ACCEPT`, а под это правило
# попадает и awg0→awg0: любой человек на профиле доходил через сервер до устройств остальных людей того же
# профиля. По умолчанию такой трафик режется правилом ПЕРВЫМ в FORWARD внутри сетевого пространства
# контейнера; выход в интернет (awg0→eth0 и NAT) не трогается. Выключается только настройкой
# client_isolation=false в config.json (решение владельца 27.09.2026; переключатель в интерфейсах — позже).
# Туннели у продукта только IPv4, поэтому ip6tables не нужен. Строку в start.sh своих профилей узнаём по метке.
GA_AMN_ISOLATION_MARK="goamnezia-client-isolation"

# ga_amn_isolation_on → 0, если изоляция клиентов включена (client_isolation не false).
ga_amn_isolation_on() {
    [ "$(ga_config_get .client_isolation 2>/dev/null)" != "false" ]
}

# ga_amn_isolation_cmd <интерфейс> on|off → команда sh для контейнера: поставить правило первым в FORWARD, если
# его нет, — или снять все его копии. Интерфейс — только awgN/wgN (у legacy-контейнера приложения — wg0).
ga_amn_isolation_cmd() {
    local i="${1:-}"
    [[ "$i" =~ ^(awg|wg)[0-9]$ ]] || return 1
    if [ "${2:-on}" = on ]; then
        printf 'iptables -C FORWARD -i %s -o %s -j DROP 2>/dev/null || iptables -I FORWARD 1 -i %s -o %s -j DROP' \
            "$i" "$i" "$i" "$i"
    else
        printf 'while iptables -C FORWARD -i %s -o %s -j DROP 2>/dev/null; do iptables -D FORWARD -i %s -o %s -j DROP || break; done' \
            "$i" "$i" "$i" "$i"
    fi
}

# ga_amn_start_sh_isolation <текст start.sh> <интерфейс> on|off → тот же текст со строкой изоляции перед первым
# правилом iptables (так и в первые мгновения старта окна нет) — или без неё. Повтор ничего не меняет.
ga_amn_start_sh_isolation() {
    local text="$1" iface="$2" want="${3:-on}" line l out="" put=0
    line="$(ga_amn_isolation_cmd "$iface" on) # $GA_AMN_ISOLATION_MARK" || return 1
    [ "$want" = on ] || put=1
    while IFS= read -r l || [ -n "$l" ]; do
        [[ "$l" == *"$GA_AMN_ISOLATION_MARK"* ]] && continue
        if [ "$put" = 0 ] && [[ "$l" =~ ^(iptables|tail)[[:space:]] ]]; then
            out+="$line"$'\n'
            put=1
        fi
        out+="$l"$'\n'
    done <<<"$text"
    [ "$put" = 1 ] || out+="$line"$'\n'
    printf '%s' "${out%$'\n'}"
}

# ga_amn_isolation_sync_start_sh <профиль> on|off — строка изоляции, блок MSS и блок движка (ga_amn_start_sh_ours) в
# start.sh своего профиля: копия в state/ и сам контейнер. Правка на месте, а не пересборка из шаблона: goWARP PRO
# дописывает в start.sh свой запуск. Перед записью в контейнер блок goWARP в копии — из самого контейнера
# (ga_amn_start_sh_warp_refresh, WRP-05): копия бывает старше, и запись затёрла бы свежий блок. Что start.sh правили —
# GA_AMN_START_SH_CHANGED=1. start.sh контейнера, подхваченного у приложения, не переписываем — там правила держит
# сторож (ниже).
GA_AMN_START_SH_CHANGED=0
ga_amn_isolation_sync_start_sh() {
    local profile="$1" want="${2:-on}" sdir text new container iface
    [ "$(ga_config_get ".profiles.$profile.imported" 2>/dev/null)" = "true" ] && return 0
    sdir=$(ga_amn_state_dir "$profile")
    [ -f "$sdir/start.sh" ] || return 0
    iface=$(ga_amn_iface "$profile")
    text=$(<"$sdir/start.sh")
    new=$(ga_amn_start_sh_ours "$text" "$iface" "$want") || return 1
    [ "$new" = "$text" ] && return 0
    container=$(ga_profile_field "$profile" container)
    ga_amn_start_sh_warp_refresh "$container" "$sdir/start.sh"
    text=$(<"$sdir/start.sh")
    new=$(ga_amn_start_sh_ours "$text" "$iface" "$want") || return 1
    printf '%s\n' "$new" >"$sdir/start.sh" || return 1
    chmod 600 "$sdir/start.sh"
    GA_AMN_START_SH_CHANGED=1
    printf '%s\n' "$new" | docker_write_file "$container" "$GA_START_SH" 0755
}

# ga_amn_isolation_apply <профиль> [quiet] — правило изоляции (или его снятие при client_isolation=false) в
# сетевом пространстве работающего контейнера профиля, у своих профилей — и строкой в start.sh. Правило живёт
# в контейнере и пропадает с каждым его перезапуском, поэтому ставится при каждом подъёме и тиком сторожа.
# quiet — ошибки docker молча: сторож повторит сам через пару минут.
ga_amn_isolation_apply() {
    local profile="$1" want=on container cmd rc=0
    ga_amn_isolation_on || want=off
    GA_AMN_START_SH_CHANGED=0
    ga_amn_isolation_sync_start_sh "$profile" "$want" || true
    container=$(ga_profile_field "$profile" container)
    cmd=$(ga_amn_isolation_cmd "$(ga_amn_iface "$profile")" "$want") || return 1
    if [ "${2:-}" = quiet ] && ! ga_dry; then
        docker_exec "$container" "$cmd" >/dev/null 2>&1 || rc=$?
    else
        docker_exec "$container" "$cmd" >/dev/null || rc=$?
    fi
    # MSS — в работающий контейнер, если его start.sh этого ещё не сделал: start.sh своего профиля только что получил
    # блок (обновление) или это контейнер приложения (его start.sh не трогаем).
    if [ "$GA_AMN_START_SH_CHANGED" = 1 ] || [ "$(ga_config_get ".profiles.$profile.imported" 2>/dev/null)" = true ]; then
        ga_amn_mss_apply "$profile" "${2:-}" || true
    fi
    return "$rc"
}

# ga_amn_isolation_apply_all → stdout: у скольких работающих контейнеров профилей правило приведено к настройке.
# Миграция обновления зовёт её сразу, не дожидаясь тика сторожа.
ga_amn_isolation_apply_all() {
    local p profiles n=0
    ga_profiles_load profiles || return 1
    for p in $profiles; do
        [ "$(ga_config_get ".profiles.$p.enabled" 2>/dev/null)" = "false" ] && continue
        [ "$(docker_container_state "$(ga_profile_field "$p" container)")" = running ] || continue
        ga_amn_isolation_apply "$p" && n=$((n + 1))
    done
    printf '%s' "$n"
}

# ── Изоляция сразу после старта контейнера (находка OPS-05) ──────────────────
# Свои профили ставят правило строкой в start.sh — при каждом старте контейнера, без нас. start.sh контейнера,
# подхваченного у приложения, мы не трогаем (ga_amn_isolation_sync_start_sh), и после перезагрузки хоста такой
# контейнер до первого тика сторожа (OnBootSec=2min и до 30 с случайной задержки) пускал людей профиля к
# устройствам друг друга. Служба goamnezia-isolation (lib/timers.sh) слушает события Docker и ставит правило в
# ту же секунду, как контейнер профиля стартовал, а при своём запуске — всем уже работающим.

# ga_amn_isolation_on_start <имя контейнера> — правило контейнеру, если это контейнер профиля и изоляция
# включена. Снятие при client_isolation=false — дело тика сторожа (ga_amn_isolation_apply).
# Тем же событием — соседи в сети контейнера (warp-socks рядом с goWARP PRO, lib/docker.sh «Соседи в сети
# контейнера»): контейнер профиля стартовал с новым сетевым пространством — после пересоздания продуктом, docker
# restart руками или перезапуска Docker, — и сосед, оставшийся в прежнем, возвращается в сеть сразу, а не через тик.
ga_amn_isolation_on_start() {
    local name="${1:-}" p list
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || return 0
    list=$(ga_profiles_installed 2>/dev/null) || return 0
    for p in $list; do
        [ "$(ga_profile_field "$p" container)" = "$name" ] || continue
        if ga_amn_isolation_on; then
            docker_exec "$name" "$(ga_amn_isolation_cmd "$(ga_amn_iface "$p")" on)" >/dev/null \
                || log_warning "$(tf amnezia_warn_isolation_failed "$p" "$name")"
        fi
        # MSS контейнеру приложения: его start.sh не трогаем, правило ставим со старта (свои — блоком в start.sh).
        [ "$(ga_config_get ".profiles.$p.imported" 2>/dev/null)" = true ] && ga_amn_mss_apply "$p" quiet
        ga_amn_netdeps_reattach "$p"
        return 0
    done
    return 0
}

# ga_amn_isolation_watch — тело службы goamnezia-isolation (install.sh --isolation-watch). Подписка на старты —
# первой, догоняющий проход по уже работающим контейнерам профилей — после неё: контейнер, стартовавший между
# ними, придёт событием. Возврат — когда события кончились (демон Docker остановлен или перезапущен): код 1, и
# systemd поднимет службу снова, а она подпишется заново.
ga_amn_isolation_watch() {
    local fd name p c list
    exec {fd}< <(docker_events_starts)
    # Подписке — секунда на то, чтобы демон её принял: контейнер, стартовавший раньше, догонит проход ниже.
    ga_dry || sleep 1
    if list=$(ga_profiles_installed 2>/dev/null); then
        for p in $list; do
            c=$(ga_profile_field "$p" container)
            [ "$(docker_container_state "$c")" = running ] && ga_amn_isolation_on_start "$c"
        done
    fi
    while IFS= read -r -u "$fd" name; do
        ga_amn_isolation_on_start "$name"
    done
    exec {fd}<&-
    ga_dry && return 0
    return 1
}

# ── Подгонка TCP MSS по MTU туннеля (решение владельца 08.10.2026, этап Б) ────
# За роутером-клиентом (Keenetic, AWG Manager) стоят устройства с MTU 1500: они просят сайты слать сегменты по 1460
# байт, а в туннель с MTU 1280 такой пакет не лезет, и если ICMP «нужна фрагментация» по дороге теряется — часть
# сайтов «висит» на загрузке. Правила mangle для TCP SYN по awg0 в обе стороны: из туннеля — --set-mss по MTU
# интерфейса (−40 для IPv4, −60 для IPv6 — ip6tables, если он есть в контейнере): по PMTU здесь не выйдет, маршрут
# такого пакета — наружу через eth0 с MTU 1500; в туннель — --clamp-mss-to-pmtu (маршрут — awg0, его MTU). Ядро MSS
# только уменьшает (xt_TCPMSS), поэтому клиенту с MTU меньше профиля правило не мешает. Форма идемпотентная, как у
# соседних правил (-C … || -A …); прежнее значение после смены MTU снимается.
# Где: своим профилям — блоком в start.sh (каждый старт контейнера, на модуле ядра и на программе), в работающий
# контейнер — командой тем же путём, что изоляция: подъём (ga_amn_wait_up), тик сторожа и миграция при обновлении
# (ga_amn_isolation_apply: start.sh только что получил блок или это контейнер приложения), старт контейнера приложения
# (служба изоляции), смена MTU на лету (ga_amn_mtu_live).
GA_AMN_MSS_BEGIN="# --- goamnezia-mss BEGIN ---"
GA_AMN_MSS_END="# --- goamnezia-mss END ---"

# ga_amn_mss_cmd <интерфейс> → команда sh для контейнера (POSIX: её же несёт start.sh, который goWARP проверяет `sh -n`).
# Первая строка — комментарий со словом TCPMSS: по нему команду узнают в журнале сухого прогона (docker exec).
ga_amn_mss_cmd() {
    local i="${1:-}" text
    [[ "$i" =~ ^(awg|wg)[0-9]$ ]] || return 1
    text=$(cat <<'EOF'
# goAmnezia: TCP MSS по MTU туннеля (TCPMSS) — за роутером-клиентом устройства с MTU 1500, без этого сайты «висят»
ga_mtu=$(ip -o link show dev @IF@ 2>/dev/null | sed -n 's/.* mtu \([0-9][0-9]*\).*/\1/p')
[ -n "$ga_mtu" ] || ga_mtu=1280
for ga_t in iptables:40 ip6tables:60; do
  ga_b=${ga_t%:*}; ga_v=$((ga_mtu - ${ga_t#*:}))
  command -v "$ga_b" >/dev/null 2>&1 || continue
  "$ga_b" -t mangle -S FORWARD 2>/dev/null | sed -n 's/^-A \(FORWARD -i @IF@ .*-j TCPMSS --set-mss \)\([0-9][0-9]*\)$/\2 \1\2/p' | while read -r ga_o ga_r; do [ "$ga_o" = "$ga_v" ] || "$ga_b" -t mangle -D $ga_r; done
  "$ga_b" -t mangle -C FORWARD -i @IF@ -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$ga_v" 2>/dev/null || "$ga_b" -t mangle -A FORWARD -i @IF@ -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$ga_v" 2>/dev/null
  "$ga_b" -t mangle -C FORWARD -o @IF@ -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || "$ga_b" -t mangle -A FORWARD -o @IF@ -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
done
EOF
)
    printf '%s' "${text//@IF@/$i}"
}

# ga_amn_start_sh_mss <текст start.sh> <интерфейс> → тот же текст с блоком MSS (прежний блок — нынешним): перед блоком
# goWARP, строкой `tail -f /dev/null` или первой строкой `exit` — там же, куда свой блок ставит goWARP, — иначе в конец.
# Повтор ничего не меняет; блок goWARP, строка изоляции и правки приложения — как были. Блок без пары меток — не трогаем.
ga_amn_start_sh_mss() {
    local text="$1" iface="$2" block nb ne
    nb=$(grep -cxF -- "$GA_AMN_MSS_BEGIN" <<<"$text")
    ne=$(grep -cxF -- "$GA_AMN_MSS_END" <<<"$text")
    if [ "$nb" != "$ne" ]; then printf '%s' "$text"; return 0; fi
    # Блок goWARP без метки конца: start.sh в странном виде — не трогаем, как и перенос блока goWARP (WRP-05).
    if [ "$(grep -cxF -- "$GA_WARP_BLOCK_BEGIN" <<<"$text")" != "$(grep -cxF -- "$GA_WARP_BLOCK_END" <<<"$text")" ]; then
        printf '%s' "$text"; return 0
    fi
    block=$(printf '%s\n%s\n%s' "$GA_AMN_MSS_BEGIN" "$(ga_amn_mss_cmd "$iface")" "$GA_AMN_MSS_END") || return 1
    printf '%s\n' "$text" | GA_AMN_MSS_TEXT="$block" awk -v b="$GA_AMN_MSS_BEGIN" -v e="$GA_AMN_MSS_END" \
        -v w="$GA_WARP_BLOCK_BEGIN" '
        BEGIN { blk = ENVIRON["GA_AMN_MSS_TEXT"] }
        skip { if ($0 == e) skip = 0; next }
        $0 == b { skip = 1; next }
        { l[++n] = $0 }
        END {
            for (i = 1; i <= n; i++) {
                if (!done && (l[i] == w || l[i] ~ /tail -f \/dev\/null/ || l[i] ~ /^[[:space:]]*exit([[:space:]]|$)/)) { print blk; done = 1 }
                print l[i]
            }
            if (!done) print blk
        }'
}

# ga_amn_start_sh_ours <текст start.sh> <интерфейс> on|off → start.sh своего профиля: изоляция клиентов, MSS и блок
# движка AmneziaWG (lib/kmod.sh: программа при загруженном модуле ядра — по выбору). Один путь для шаблона нового
# профиля и правки на месте у работающего.
ga_amn_start_sh_ours() {
    local text t2
    text=$(ga_amn_start_sh_isolation "$1" "$2" "${3:-on}") || return 1
    text=$(ga_amn_start_sh_mss "$text" "$2") || return 1
    if type ga_kmod_start_sh_engine >/dev/null 2>&1 && t2=$(ga_kmod_start_sh_engine "$text"); then text="$t2"; fi
    printf '%s' "$text"
}

# ga_amn_mss_apply <профиль> [quiet] — правила MSS в работающем контейнере профиля (идемпотентно).
ga_amn_mss_apply() {
    local container cmd
    container=$(ga_profile_field "$1" container)
    cmd=$(ga_amn_mss_cmd "$(ga_amn_iface "$1")") || return 1
    if [ "${2:-}" = quiet ] && ! ga_dry; then
        docker_exec "$container" "$cmd" >/dev/null 2>&1
    else
        docker_exec "$container" "$cmd" >/dev/null
    fi
}

# ga_amn_update_start_sh_subnet <профиль> <старая подсеть> <новая> — правила NAT в start.sh заданы подсетью.
# Если в копии состояния свой start.sh контейнера, подсеть меняется в нём на месте: goWARP PRO дописывает туда
# свой запуск, и пересборка из шаблона эти строки стирала. Копии нет или подсети в ней нет — из шаблона.
ga_amn_update_start_sh_subnet() {
    local profile="$1" old="$2" new="$3" container sdir text
    container=$(ga_profile_field "$profile" container)
    sdir=$(ga_amn_state_dir "$profile")
    if [ -n "$old" ] && [ -f "$sdir/start.sh" ] && grep -qF -- "$old" "$sdir/start.sh"; then
        text=$(<"$sdir/start.sh")
        text=${text//"$old"/"$new"}
        printf '%s\n' "$text" >"$sdir/start.sh" || return 1
        chmod 600 "$sdir/start.sh"
        printf '%s\n' "$text" | docker_write_file "$container" "$GA_START_SH" 0755
        return $?
    fi
    ga_amn_write_start_sh "$profile"
}

ga_amn_write_start_sh() {
    local profile="$1" container sdir text
    container=$(ga_profile_field "$profile" container)
    sdir=$(ga_amn_state_dir "$profile")
    ga_capture text ga_amn_render_start_sh "$profile" || return $?
    ga_amn_state_init "$sdir" || return 1
    printf '%s\n' "$text" >"$sdir/start.sh" || return 1
    chmod 600 "$sdir/start.sh"
    printf '%s\n' "$text" | docker_write_file "$container" "$GA_START_SH" 0755 || return 1
    # Движок AmneziaWG, выбранный на сервере (lib/kmod.sh), — новому профилю до первого старта: модуль ядра в памяти
    # иначе подхватил бы его сам.
    type ga_kmod_engine_seed >/dev/null 2>&1 && ga_kmod_engine_seed "$profile"
    return 0
}

# Первый запуск — как у приложения: docker exec -d "chmod a+x start.sh && start.sh".
# Дальше start.sh — ENTRYPOINT образа, и docker restart запускает его сам.
ga_amn_container_start() {
    docker_exec_bg "$1" "chmod a+x $GA_START_SH && $GA_START_SH"
}

# Интерфейс поднят и порт слушается. `--log-driver none` у контейнера — логов
# нет, поэтому единственная диагностика — сам awg show.
#
# «Интерфейс поднят» — ещё не «люди доходят»: Docker поднимал контейнер и с пустыми NetworkSettings.Ports,
# когда порт из копии состояния в момент запуска держал другой профиль (находка LC-20, 25.09.2026). awg
# show отвечал, профиль значился работающим, а связи не было ни у кого. Поэтому здесь же — опубликован ли
# порт у ЭТОГО контейнера; нет — отказ port_unpublished (лечится пересозданием из копии состояния).
#
# Поднятый контейнер — сразу с изоляцией клиентов (SEC-NET-1): сюда сходятся все пути подъёма — установка,
# перезапуск, пересоздание и восстановление из копии, смена порта и подсети, обновление ядра, сторож.
ga_amn_wait_up() {
    _ga_amn_wait_up_iface "$@" || return $?
    ga_amn_isolation_apply "$1" \
        || log_warning "$(tf amnezia_warn_isolation_failed "$1" "$(ga_profile_field "$1" container)")"
    # Сюда же — соседи (goWARP PRO и контейнеры в сети профиля): у контейнера, поднятого любым из этих путей, новое
    # сетевое пространство, а у пересозданного — и новый ID.
    ga_amn_neighbours_up "$1"
    return 0
}

# ── Соседи профиля: goWARP PRO и контейнеры в его сети ─────────────────────────
#
# goWARP PRO (NEIGHBOURS.md) находит контейнеры по имени `^amnezia-awg[0-9]*$` и держит внутри каждого свой WARP:
# /opt/warp, /opt/warp-tools и блок в start.sh. Всё это продукт переносит через пересоздание контейнера (копия
# состояния: ga_amn_warp_refresh, amnezia_state_sync, amnezia_state_restore; блок в start.sh нового релиза —
# ga_amn_start_sh_carry_warp) и через «Поднять заново» (части goWARP в копии сначала обновляются из самого контейнера —
# ga_amn_warp_refresh), а после подъёма зовёт сторож самого goWARP (ga_gowarp_reapply). Контейнеры в сети
# профиля (NetworkMode=container:amnezia-awgN, например warp-socks с прокси на 1080) снова входят в неё —
# docker_netdeps_reattach (lib/docker.sh).

# ga_amn_netdeps_reattach <профиль> — соседи в сети контейнера профиля — в его нынешнее пространство; что сделано —
# в журнал и журнал действий. Отказ — предупреждением: профиль уже работает.
# Итоги копятся и в GA_AMN_NETDEPS_LOG («действие<TAB>сосед<TAB>контейнер<TAB>причина»): установка прячет вывод шагов
# под спиннер, и конец установки (ga_amn_install_notes) повторяет их человеку.
GA_AMN_NETDEPS_LOG=""
ga_amn_netdeps_reattach() {
    local container res act name why
    container=$(ga_profile_field "$1" container)
    res=$(docker_netdeps_reattach "$container") || res=""
    [ -n "$res" ] || return 0
    while IFS=$'\t' read -r act name why; do
        [ -n "$name" ] || continue
        case "$act" in
            restarted) log_info "$(tf amnezia_netdep_restarted "$name" "$container")" ;;
            recreated) log_info "$(tf amnezia_netdep_recreated "$name" "$container")" ;;
            *)         log_warning "$(tf amnezia_netdep_failed "$name" "$container" "${why:-?}")" ;;
        esac
        GA_AMN_NETDEPS_LOG+="$act"$'\t'"$name"$'\t'"$container"$'\t'"$why"$'\n'
        ga_audit "${GOAMNEZIA_WHO:-ssh}" "netdep-${act}" "$name host=$container${why:+ reason=$why}"
    done <<<"$res"
    return 0
}

# ga_amn_install_notes — конец установки (мастер, Ленивый Pro): что с соседями профилей (WRP-06). Печатает только то,
# что есть, отдельным абзацем:
#   • соседи, вернувшиеся в сеть новых контейнеров (после «Удалить всё» — по хранилищу реестра), и те, кого вернуть не
#     вышло: их строки ушли под спиннер шага установки;
#   • соседи в сети пропавшего контейнера, которого нет ни в одном реестре: чьи они — не узнать, сами не трогаем
#     (WRP-01), — как вернуть руками;
#   • goWARP PRO на машине (его сторож gowarp-awg-watch), а WARP нет ни в одном работающем контейнере профилей: его WARP
#     жил в снесённых контейнерах и пропал молча. Сами не восстанавливаем — ключ мог быть перевыпущен (WRP-05).
ga_amn_install_notes() {
    local act name host why names list p c running=0 warp=0
    local -a lines=()
    while IFS=$'\t' read -r act name host why; do
        [ -n "$name" ] || continue
        case "$act" in
            restarted|recreated) lines+=("ok"$'\t'"$(tf amnezia_netdep_back "$name" "$host")") ;;
            *)                   lines+=("warn"$'\t'"$(tf amnezia_netdep_failed "$name" "$host" "${why:-?}")") ;;
        esac
    done <<<"$GA_AMN_NETDEPS_LOG"
    names=$(docker_netdeps_dangling 2>/dev/null | sort -u | paste -sd, - 2>/dev/null)
    [ -n "$names" ] && lines+=("warn"$'\t'"$(tf amnezia_warn_netdeps_dangling "$names")")
    if [ -x "$GA_GOWARP_WATCH" ] && list=$(ga_profiles_installed 2>/dev/null); then
        for p in $list; do
            c=$(ga_profile_field "$p" container)
            [ "$(docker_container_state "$c" 2>/dev/null)" = running ] || continue
            running=1
            if ga_amn_has_warp "$c"; then warp=1; break; fi
        done
        [ "$running" = 1 ] && [ "$warp" = 0 ] && lines+=("warn"$'\t'"$(t amnezia_gowarp_missing)")
    fi
    [ "${#lines[@]}" -gt 0 ] || return 0
    echo "" >&2
    for p in "${lines[@]}"; do
        c=$(ga_wrap "${p#*$'\t'}" "$(( ${GA_UI_W:-76} - 4 ))" 4)
        if [ "${p%%$'\t'*}" = ok ]; then log_success "$c"; else log_warning "$c"; fi
    done
    return 0
}

# ga_amn_has_warp <контейнер> — внутри есть WARP goWARP PRO (/opt/warp/warp.conf). Ключ из файла не читаем.
ga_amn_has_warp() {
    local fs
    if ga_dry; then
        fs=$(ga_docker_fs_path "$1" "$GA_WARP_DIR/warp.conf") && [ -f "$fs" ]
        return $?
    fi
    ga_docker exec -i "$1" test -f "$GA_WARP_DIR/warp.conf" </dev/null >/dev/null 2>&1
}

# ga_gowarp_reapply <контейнер> — WARP поднят сторожем самого goWARP (gowarp-awg-watch --once): его код, его замок
# внутри контейнера, идемпотентно — рядом с блоком в start.sh, который поднимает WARP при старте. goWARP не стоит или
# в контейнере его нет — ничего.
ga_gowarp_reapply() {
    [ -x "$GA_GOWARP_WATCH" ] || return 0
    ga_amn_has_warp "$1" || return 0
    if ga_dry; then ga_dry_echo "$GA_GOWARP_WATCH --once"; return 0; fi
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$GA_GOWARP_WATCH" --once </dev/null >/dev/null 2>&1 || true
    else
        "$GA_GOWARP_WATCH" --once </dev/null >/dev/null 2>&1 || true
    fi
    return 0
}

# ga_amn_neighbours_up <профиль> — после подъёма контейнера профиля: соседи в его сети и WARP goWARP PRO.
ga_amn_neighbours_up() {
    ga_amn_netdeps_reattach "$1"
    ga_gowarp_reapply "$(ga_profile_field "$1" container)"
    return 0
}

# ga_amn_warp_refresh <профиль> — /opt/warp, /opt/warp-tools и блок в start.sh goWARP PRO из самого контейнера в
# state/, пока копия ещё не вернулась в контейнер: перед сносом (ga_amn_container_rm) и в «Поднять заново» перед записью
# копии в работающий контейнер. Свежий источник для WARP — контейнер: goWARP перевыпускает устройство (новый ключ,
# прежнее удаляется у Cloudflare) и пишет свой блок прямо в start.sh контейнера, а копия от прошлой синхронизации
# вернула бы уже отозванный ключ и start.sh без блока, если снята до установки goWARP (WRP-05); у остановленного
# контейнера синхронизации перед сносом не бывает вовсе. docker cp читает и остановленный. Каталога в контейнере нет —
# копия в state/ снимается (goWARP удалён — не воскрешаем); другой отказ docker — копия прежняя. После docker run
# нового контейнера не зовём: goWARP в нём ещё нет, и снимок стёр бы его из копии.
ga_amn_warp_refresh() {
    local container sdir src dst tmp err state
    container=$(ga_profile_field "$1" container)
    [ -n "$container" ] || return 0
    sdir="$STATE_DIR/$container"
    [ -d "$sdir" ] || return 0
    if ga_dry; then
        ga_dry_echo "docker cp $container:$GA_WARP_DIR/. $sdir/warp/ ; docker cp $container:$GA_WARP_TOOLS_DIR/usr $sdir/warp-tools/usr (if exist)"
        ga_amn_start_sh_warp_refresh "$container" "$sdir/start.sh"
        return 0
    fi
    ga_capture state docker_container_state "$container"
    case "$state" in running|exited) ;; *) return 0 ;; esac
    for src in "$GA_WARP_DIR" "$GA_WARP_TOOLS_DIR/usr"; do
        if [ "$src" = "$GA_WARP_DIR" ]; then dst="$sdir/warp"; else dst="$sdir/warp-tools/usr"; fi
        tmp=$(mktemp -d "$sdir/.warp.XXXXXX") || continue
        if err=$(ga_docker cp "$container:$src" "$tmp/x" 2>&1 >/dev/null); then
            mkdir -p "${dst%/*}" && rm -rf "$dst" && mv "$tmp/x" "$dst"
            find "$sdir/warp" "$sdir/warp-tools" -type d -exec chmod 700 {} + 2>/dev/null
            find "$sdir/warp" "$sdir/warp-tools" -type f -exec chmod 600 {} + 2>/dev/null
        elif grep -qiE 'could not find the file|no such file' <<<"$err"; then
            rm -rf "$dst"
            [ "$src" = "$GA_WARP_DIR" ] || rmdir "$sdir/warp-tools" 2>/dev/null
        fi
        rm -rf "$tmp"
    done
    ga_amn_start_sh_warp_refresh "$container" "$sdir/start.sh"
    return 0
}

# ga_amn_container_rm <профиль> — снос контейнера профиля перед пересозданием: сначала свежий WARP goWARP в state/.
ga_amn_container_rm() {
    ga_amn_warp_refresh "$1"
    docker_rm "$(ga_profile_field "$1" container)"
}

# ga_amn_start_sh_carry_warp <текст нового start.sh> <прежний start.sh (файл)> → новый текст с блоком goWARP PRO из
# прежнего. Новый start.sh из шаблона (обновление upstream) иначе терял WARP: после пересоздания он не поднимался
# до ручного восстановления в goWARP. Блок встаёт туда же, куда его ставит сам goWARP, — перед `tail -f /dev/null`
# или `exit`, иначе в конец. Блока в прежнем нет или он уже есть в новом — текст как есть.
ga_amn_start_sh_carry_warp() {
    local text="$1" old="${2:-}" block
    block=$(sed -n "/^${GA_WARP_BLOCK_BEGIN}\$/,/^${GA_WARP_BLOCK_END}\$/p" "$old" 2>/dev/null) || block=""
    if [ -z "$block" ] || [[ "$text" == *"$GA_WARP_BLOCK_BEGIN"* ]] || [[ "$block" != *"$GA_WARP_BLOCK_END"* ]]; then
        printf '%s' "$text"
        return 0
    fi
    printf '%s\n' "$text" | GA_WARP_BLOCK="$block" awk '
        !done && (/tail -f \/dev\/null/ || /^[[:space:]]*exit([[:space:]]|$)/) { print ENVIRON["GA_WARP_BLOCK"]; done = 1 }
        { print }
        END { if (!done) print ENVIRON["GA_WARP_BLOCK"] }'
}

# ga_amn_start_sh_warp_refresh <контейнер> <копия start.sh в state/> — блок goWARP PRO в копии — тот, что сейчас в
# start.sh контейнера (WRP-05): прежний блок копии (снятый до обновления goWARP) уходит, блок контейнера встаёт туда
# же, куда его ставит сам goWARP (ga_amn_start_sh_carry_warp). Остальные строки копии — как были. Блока в контейнере
# нет или он без метки конца, у копии блок без метки конца, копии или файла в контейнере нет — копия как есть.
ga_amn_start_sh_warp_refresh() {
    local container="$1" copy="$2" live block text tmp
    [ -f "$copy" ] || return 0
    live=$(docker_read_file_any "$container" "$GA_START_SH") || return 0
    block=$(sed -n "/^${GA_WARP_BLOCK_BEGIN}\$/,/^${GA_WARP_BLOCK_END}\$/p" <<<"$live")
    [[ "$block" == *"$GA_WARP_BLOCK_END" ]] || return 0
    text=$(<"$copy") || return 0
    [ "$(sed -n "/^${GA_WARP_BLOCK_BEGIN}\$/,/^${GA_WARP_BLOCK_END}\$/p" <<<"$text")" != "$block" ] || return 0
    if grep -qxF -- "$GA_WARP_BLOCK_BEGIN" <<<"$text"; then
        # Без метки конца вырезка ушла бы до конца файла вместе с `tail -f /dev/null` — контейнер перестал бы стартовать.
        grep -qxF -- "$GA_WARP_BLOCK_END" <<<"$text" || return 0
        text=$(sed "/^${GA_WARP_BLOCK_BEGIN}\$/,/^${GA_WARP_BLOCK_END}\$/d" <<<"$text")
    fi
    tmp=$(mktemp "${copy%/*}/.start.XXXXXX") || return 0
    if printf '%s\n' "$live" >"$tmp" && text=$(ga_amn_start_sh_carry_warp "$text" "$tmp") \
       && printf '%s\n' "$text" >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$copy"; then
        return 0
    fi
    rm -f "$tmp"
    return 0
}

_ga_amn_wait_up_iface() {
    local profile="$1" container port i tool iface pub=0
    container=$(ga_profile_field "$profile" container)
    port=$(ga_profile_field "$profile" port)
    tool=$(ga_amn_tool "$profile"); iface=$(ga_amn_iface "$profile")
    if ga_dry; then
        ga_dry_echo "docker exec -i $container $tool show $iface"
        docker_port_published "$container" "$port" udp || pub=$?
        if [ "$pub" = 1 ]; then
            ga_err port_unpublished "$(tf amnezia_err_port_unpublished "$container" "$port")"
            return 1
        fi
        return 0
    fi
    for ((i = 0; i < 20; i++)); do
        if ga_docker exec -i "$container" "$tool" show "$iface" </dev/null >/dev/null 2>&1; then
            docker_port_published "$container" "$port" udp || pub=$?
            if [ "$pub" = 1 ]; then
                ga_err port_unpublished "$(tf amnezia_err_port_unpublished "$container" "$port")"
                return 1
            fi
            if ! docker_port_free "$port" udp; then
                return 0
            fi
            log_warning "$(tf amnezia_warn_port_not_listening "$port")"
            return 0
        fi
        sleep 1
    done
    # Имя интерфейса в сообщении — фактическое: у подхваченного legacy-профиля
    # это wg0, и жалоба на «awg0» сбивала с толку.
    ga_err container_not_up "$(tf amnezia_err_not_up "$container" "$iface")"
    return 1
}

# Файрвол хоста по setup_host_firewall.sh приложения, минус DROP на ICMP echo
# (опция options.drop_icmp, по умолчанию выключена — пинг до сервера нужен
# людям чаще, чем мешает). Правила идемпотентны (-C || -A).
amnezia_host_firewall() {
    local drop_icmp
    drop_icmp=$(ga_config_get ".options.drop_icmp" 2>/dev/null)
    if ga_dry; then
        ga_dry_echo "sysctl -w net.ipv4.ip_forward=1; iptables FORWARD → DOCKER-USER/docker0 (idempotent); conntrack tuning; drop_icmp=${drop_icmp:-false}"
        return 0
    fi
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    # Docker сам включает ip_forward при старте, но после перезагрузки без Docker
    # (или с его задержкой) VPN молчит — закрепляем.
    mkdir -p /etc/sysctl.d 2>/dev/null
    printf 'net.ipv4.ip_forward = 1\n' >/etc/sysctl.d/99-goamnezia.conf 2>/dev/null
    if [ "$drop_icmp" = "true" ]; then
        iptables -C INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null \
            || iptables -A INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null
    fi
    iptables -C FORWARD -j DOCKER-USER 2>/dev/null || iptables -A FORWARD -j DOCKER-USER 2>/dev/null
    iptables -C FORWARD -j DOCKER-ISOLATION-STAGE-1 2>/dev/null || iptables -A FORWARD -j DOCKER-ISOLATION-STAGE-1 2>/dev/null
    iptables -C FORWARD -o docker0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
        || iptables -A FORWARD -o docker0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
    iptables -C FORWARD -o docker0 -j DOCKER 2>/dev/null || iptables -A FORWARD -o docker0 -j DOCKER 2>/dev/null
    iptables -C FORWARD -i docker0 ! -o docker0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i docker0 ! -o docker0 -j ACCEPT 2>/dev/null
    iptables -C FORWARD -i docker0 -o docker0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i docker0 -o docker0 -j ACCEPT 2>/dev/null
    # Тюнинг из официального скрипта; на стенде goWARP проверен (D7). Каждая
    # строка независима — отсутствие ключа на ядре не должно ронять установку.
    local kv
    for kv in net.netfilter.nf_conntrack_max=262144 fs.file-max=51200 \
              net.core.rmem_max=67108864 net.core.wmem_max=67108864 \
              net.core.netdev_max_backlog=250000 net.core.somaxconn=4096 \
              net.ipv4.tcp_syncookies=1 net.ipv4.tcp_tw_reuse=1 net.ipv4.tcp_fin_timeout=30 \
              net.ipv4.tcp_keepalive_time=1200 net.ipv4.tcp_max_syn_backlog=8192 \
              net.ipv4.tcp_max_tw_buckets=5000 net.ipv4.tcp_fastopen=3 net.ipv4.tcp_mtu_probing=1; do
        sysctl -w "$kv" >/dev/null 2>&1 || true
    done
    return 0
}

# Публичные ключи пиров из текста конфига (для сверки с users.json).
# Режем по ПЕРВОМУ «=», а не через -F'=': ключ WireGuard — base64 от 32 байт,
# он всегда кончается на «=», и awk -F'=' обрезал этот хвост. Обрезанный ключ
# не совпадал ни с users.json, ни с GA_EXPECT_DROP — и каждая запись конфига
# ругалась «в контейнере чужой пир, подхватите его через import-adopt» на
# собственных пользователей.
ga_amn_conf_pubkeys() {
    awk '/^[[:space:]]*PublicKey[[:space:]]*=/ {
             i = index($0, "="); v = substr($0, i + 1)
             gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
             if (v != "") print v
         }'
}

# ── Параметры маскировки: стороны, линейки, проверка ─────────────────────────

# Параметры делятся на серверные и клиентские (PLAN §10 п.9). Серверные живут в
# [Interface] контейнера и участвуют в рукопожатии: клиент со старыми значениями
# не соединится, после смены нужен перевыпуск конфигов. Клиентские сервер не
# сверяет: Jc/Jmin/Jmax — сколько мусора шлёт сама сторона, I* — сигнатурные
# пакеты клиента, MTU/keepalive/тайминги — поведение клиента; они действуют на
# новые выдачи ключей.
GA_AMN_SERVER_PARAMS="S1 S2 S3 S4 H1 H2 H3 H4 HeaderProtectionKey RandomTrailers DisableCookies"
GA_AMN_CLIENT_PARAMS="Jc Jmin Jmax I1 I2 I3 I4 I5 ContentPaddingAddition RekeyAfterTime RekeyTimeout RejectAfterTime KeepaliveTimeout MaxHandshakeAttempts PersistentKeepalive MTU"

# ga_amn_param_scope <ключ> → server | client; неизвестный ключ — код 1.
ga_amn_param_scope() {
    case " $GA_AMN_SERVER_PARAMS " in *" ${1:-} "*) echo server; return 0 ;; esac
    case " $GA_AMN_CLIENT_PARAMS " in *" ${1:-} "*) echo client; return 0 ;; esac
    return 1
}

# ga_amn_param_keys <линейка> → ключи, которые понимает линейка, в порядке
# template.conf приложения (что не знает линейка, тому в её конфиге не место).
ga_amn_param_keys() {
    local line="$1" keys="Jc Jmin Jmax S1 S2"
    case "$line" in 2.0|3.1) keys+=" S3 S4" ;; esac
    keys+=" H1 H2 H3 H4"
    case "$line" in 1.5|2.0|3.1) keys+=" I1 I2 I3 I4 I5" ;; esac
    case "$line" in
        3.1) keys+=" HeaderProtectionKey ContentPaddingAddition RekeyAfterTime RekeyTimeout RejectAfterTime KeepaliveTimeout MaxHandshakeAttempts RandomTrailers DisableCookies" ;;
    esac
    keys+=" PersistentKeepalive MTU"
    echo "$keys"
}

# Проверка набора параметров по правилам линейки (контракт §4.2). Обёртка
# awg_params_validate из lib/awg_params.sh предпочтительна — она переводит
# причину через словарь; без неё (модули загружены без awg_params.sh, как в
# tests/test_core_dryrun.sh) зовём awgkeys.py напрямую. Причины — в stderr.
# Третий аргумент — правила тегов I1–I5 (KMOD-02): write (по умолчанию) — то, что пишем мы: только теги, понятные
# и модулю ядра, и amneziawg-go; adopt — уже записанные при подхвате: теги любой реализации.
ga_amn_validate_params() {
    local line="$1" json="$2" mode="${3:-write}"
    if declare -F awg_params_validate >/dev/null; then
        awg_params_validate "$line" "$json" "$mode"
    else
        printf '%s' "$json" | ga_awgkeys validate --line "$line" --ipackets "$mode"
    fi
}

# Параметры, которые живут строкой в [Interface] сервера: их смена на модуле ядра — пересоздание интерфейса
# (KMOD-01, amnezia_syncconf). I1–I5 сюда не входят — у сервера они закомментированы (`# I1 = …`, как у приложения
# Amnezia) и до интерфейса не доходят ни на каком движке; PersistentKeepalive — поле клиентов; MTU — ga_amn_mtu_live.
GA_AMN_IFACE_MASK_PARAMS="Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 HeaderProtectionKey ContentPaddingAddition RekeyAfterTime RekeyTimeout RejectAfterTime KeepaliveTimeout MaxHandshakeAttempts RandomTrailers DisableCookies"
ga_amn_iface_mask_param() { case " $GA_AMN_IFACE_MASK_PARAMS " in *" ${1:-} "*) return 0 ;; esac; return 1; }

# Параметры-ключи: на экранах (SSH «Параметры маскировки» и «Изменить один параметр», панель, бот) — «задан (скрыт)»
# вместо значения (K5-3: экраны попадают в записи и скриншоты гайдов). Мост (profile-params) отдаёт значение как есть.
# Тот же список — SECRET_PARAMS в goamnezia-bot/bot.py и SECRET_PARAMS в admin-web/static/app.js (paramShown),
# SECRET_PROFILE_PARAMS в admin-web/server.py и goamnezia-mcp/server.py (журналы).
GA_AMN_SECRET_PARAMS="HeaderProtectionKey"
ga_amn_param_secret() { case " $GA_AMN_SECRET_PARAMS " in *" ${1:-} "*) return 0 ;; esac; return 1; }

# ga_amn_param_shown <ключ> <значение> [json] — значение параметра там, где его видят люди или журнал: у параметра-ключа
# (ga_amn_param_secret) — «задан (скрыт)», пустое — «-», остальное — как есть. С json — для полей ответа: у ключа «***»,
# пустое остаётся пустым («параметр убран»). Одна функция на все места записи параметра (KEENETIC-I1-N, N3/N4/F3):
# строка об успехе, откат и «не применился», подтверждение SSH (_pr_param_shown), ответ записи (value, old_value) и
# сообщение моста profile-set-param. Прежде значение HeaderProtectionKey печаталось целиком сразу после «задан (скрыт)».
ga_amn_param_shown() {
    if [ -n "${2:-}" ] && ga_amn_param_secret "${1:-}"; then
        if [ "${3:-}" = json ]; then printf '***'; else t pr_param_secret_set; fi
    elif [ "${3:-}" = json ]; then
        printf '%s' "${2:-}"
    else
        printf '%s' "${2:--}"
    fi
}

# ga_amn_ipacket_reason <JSON params> [write|adopt] → слова о первой беде сигнатурных пакетов I1–I5 (KMOD-02):
# отрицательный или нулевой размер, незнакомый тег, пакет больше 1280 байт, а в write — ещё тег, который понимает не
# каждая реализация (<c> — только модуль ядра; <d> <ds> <dz> — только amneziawg-go), и пакет, который начинается не с
# <b> (KEENETIC-I1: KeeneticOS 5.1 такой ключ не принимает). Всё в порядке — пусто.
ga_amn_ipacket_reason() {
    local rows key code tag num
    rows=$(printf '%s' "$1" | ga_awgkeys ipackets --mode "${2:-write}" 2>/dev/null) && return 0
    IFS=$'\t' read -r key code tag num <<<"$(head -n 1 <<<"$rows")"
    [[ "$key" =~ ^I[1-5]$ ]] || return 0
    [ "$tag" = - ] && tag=""
    [ "$num" = - ] && num=""
    case "$code" in
        syntax)       tf amnezia_err_ipacket_syntax "$key" ;;
        b_hex)        tf amnezia_err_ipacket_b_hex "$key" ;;
        noarg)        tf amnezia_err_ipacket_noarg "$key" "$tag" ;;
        size)         tf amnezia_err_ipacket_size "$key" "$tag" "${num:-—}" ;;
        unknown)      tf amnezia_err_ipacket_unknown "$key" "$tag" ;;
        kernel_only)  tf amnezia_err_ipacket_kernel_only "$key" "$tag" ;;
        program_only) tf amnezia_err_ipacket_program_only "$key" "$tag" ;;
        too_big)      tf amnezia_err_ipacket_too_big "$key" "${num:-?}" ;;
        b_first)      tf amnezia_err_ipacket_b_first "$key" "${tag:-?}" ;;
    esac
    return 0
}

# ga_amn_ipacket_warnings <JSON params> → по строке слов на каждый тег I1–I5, который понимает не каждая реализация, и
# на каждый пакет, который начинается не с <b> (Keenetic, KEENETIC-I1) — подхват: не отказ, а предупреждение, люди,
# которые подключаются сейчас, не должны остаться без сервиса. Бед нет и таких тегов нет — пусто. Беды (отказ) —
# ga_amn_ipacket_reason … adopt.
ga_amn_ipacket_warnings() {
    local rows key code tag num
    rows=$(printf '%s' "$1" | ga_awgkeys ipackets --mode adopt 2>/dev/null) || return 0
    while IFS=$'\t' read -r key code tag num; do
        [[ "$key" =~ ^I[1-5]$ ]] || continue
        case "$code" in
            kernel_only)  tf amnezia_warn_ipacket_kernel_only "$key" "$tag" "$key" "$key"; echo ;;
            program_only) tf amnezia_warn_ipacket_program_only "$key" "$tag" "$key" "$key"; echo ;;
            b_first)      tf amnezia_warn_ipacket_b_first "$key" "$tag" "$key" "$key"; echo ;;
        esac
    done <<<"$rows"
    return 0
}

# ── Пределы того, что пишем мы (1.0.13; живые проверки 08.10, PARAM-03, 05, 08, 09) ──────────────────────────────
# Правила и числа — lib/awgkeys.py (limit_problems, подкоманда limits): тайминги 3.1 и ContentPaddingAddition вне
# коридора, связка таймингов (ключ сессии умирает раньше смены), всплеск мусора Jc × Jmax больше 16 КБ, Jc + число I
# больше 127 (клиент на программе не поднимется), хвосты 3.1 + разные S + широкие H (#226). Здесь — слова.

# _ga_amn_limit_words <err|warn> <строка limits> → слова одной беды: отказ записи (err) или предупреждение подхвата.
_ga_amn_limit_words() {
    local mode="$1" code key val a b c d e why
    IFS=$'\t' read -r code key val a b c d e <<<"$2"
    [ "$val" = - ] && val=""
    [ "$c" = - ] && c=""
    case "$code" in
        corridor)
            case "$key" in
                RekeyAfterTime)         why=$(t amnezia_corridor_why_rekey_after) ;;
                RekeyTimeout)           why=$(t amnezia_corridor_why_rekey_timeout) ;;
                RejectAfterTime)        why=$(t amnezia_corridor_why_reject_after) ;;
                KeepaliveTimeout)       why=$(t amnezia_corridor_why_keepalive) ;;
                MaxHandshakeAttempts)   why=$(t amnezia_corridor_why_handshakes) ;;
                ContentPaddingAddition) why=$(t amnezia_corridor_why_padding) ;;
                *)                      why="" ;;
            esac
            if [ "$mode" = err ]; then tf amnezia_err_corridor "$key" "$val" "$a" "$b" "$c" "$why"
            else tf amnezia_warn_corridor "$key" "$val" "$a" "$b" "$c" "$why"; fi ;;
        timing_order)
            if [ "$mode" != err ]; then tf amnezia_warn_timing_order "$a" "$b" "${c:-—}"
            elif [ -n "$c" ]; then tf amnezia_err_timing_order "$key" "$val" "$a" "$b" "$c"
            else tf amnezia_err_timing_order_plain "$key" "$val" "$a" "$b"; fi ;;
        junk_burst)
            if [ "$mode" = err ]; then tf amnezia_err_junk_burst "$key" "$val" "$a" "$b" "$c" "$d"
            else tf amnezia_warn_junk_burst "$a" "$b" "$c" "$d"; fi ;;
        jc_ipackets)
            if [ "$mode" = err ]; then tf amnezia_err_jc_ipackets "$key" "$val" "$a" "$b" "$c" "$d"
            else tf amnezia_warn_jc_ipackets "$a" "$b" "$c" "$d"; fi ;;
        trailers_loss)
            if [ "$mode" = err ]; then tf amnezia_err_trailers_loss "$key" "$val" "${b//,/, }" "$c" "${a//,/, }" "$d" "$e"
            else tf amnezia_warn_trailers_loss "${b//,/, }" "$c" "${a//,/, }" "$d" "$e"; fi ;;
        *) return 1 ;;
    esac
    return 0
}

# ga_amn_limits_reason <линия> <JSON params после записи> <ключ> <прежнее значение> → код 0: слова о первой беде, которую
# ломает или ухудшает запись этого ключа (отказ params_invalid словами), бед нет — пусто; код 1: проверить не удалось
# (awgkeys.py упал, нет jq, ответ без строки беды) — слова «не удалось проверить значение — <причина>», писать нельзя.
# Набор и прежнее значение идут jq и awgkeys.py через stdin (printf — встроенная команда), не argv: argv любого процесса
# видит любой пользователь машины в /proc, а в наборе — HeaderProtectionKey.
ga_amn_limits_reason() {
    local rows rc=0 errf why val
    val=$(jq -r --arg k "$3" '.[$k] // ""' <<<"$2" 2>/dev/null) || val=""
    # stderr jq и awgkeys.py (текст исключения может нести значения набора) — секретным файлом в памяти и затиранием, как
    # у ga_capture (R2-6), а не обычным mktemp в общем каталоге.
    if type ga_mktemp_secret >/dev/null 2>&1; then errf=$(ga_mktemp_secret galim); else errf=$(mktemp); fi \
        || { tf amnezia_err_limits_check "$3" "${val:--}" "mktemp"; return 1; }
    # Строка 1 — набор (jq -c, одной строкой), остальное — прежнее значение.
    rows=$(printf '%s\n%s' "$2" "$4" \
        | jq -Rsc 'split("\n") | {params: (.[0] | fromjson), old: (.[1:] | join("\n"))}' 2>>"$errf" \
        | ga_awgkeys limits --line "$1" --key "$3" 2>>"$errf") || rc=$?
    why=$(grep -v '^[[:space:]]*$' "$errf" | tail -n 1 | sed -e $'s/\x1b\\[[0-9;]*m//g' -e 's/^awgkeys: limits: //')
    if type ga_wipe_file >/dev/null 2>&1; then ga_wipe_file "$errf"; else rm -f "$errf"; fi
    [ "$rc" = 0 ] && return 0
    # Код 2 со строкой беды — запись ломает предел; код 2 без строки — кривой вход (awgkeys пишет его в stderr).
    if [ "$rc" = 2 ] && [ -n "$rows" ] && _ga_amn_limit_words err "$(head -n 1 <<<"$rows")"; then return 0; fi
    tf amnezia_err_limits_check "$3" "${val:--}" "${why:-$(tf amnezia_err_limits_check_rc "$rc")}"
    return 1
}

# ga_amn_limits_warnings <линия> <JSON params> → по строке слов на каждую беду всего набора: подхват — не отказ, а
# предупреждение (люди, которые подключаются сейчас, не должны остаться без сервиса). Бед нет — пусто.
ga_amn_limits_warnings() {
    local rows row
    rows=$(printf '%s' "$2" | ga_awgkeys limits --line "$1" 2>/dev/null) || return 0
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        _ga_amn_limit_words warn "$row" && echo
    done <<<"$rows"
    return 0
}

# ── Подсети ──────────────────────────────────────────────────────────────────

# ga_cidr_parse <a.b.c.d/n> → stdout "адрес_сети размер префикс" целыми числами.
# Код 1 — не CIDR, код 2 — адрес не выровнен по маске (10.8.2.0/22 — это адрес
# внутри 10.8.0.0/22, а не сеть; awg-quick такое поднимет, а аллокатор и
# проверка пересечений посчитают неверно — отвергаем сразу).
ga_cidr_parse() {
    local a b c d prefix base size
    [[ "${1:-}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
    a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}; c=${BASH_REMATCH[3]}; d=${BASH_REMATCH[4]}
    prefix=${BASH_REMATCH[5]}
    [ "$a" -le 255 ] && [ "$b" -le 255 ] && [ "$c" -le 255 ] && [ "$d" -le 255 ] && [ "$prefix" -le 32 ] || return 1
    base=$(( (a << 24) | (b << 16) | (c << 8) | d ))
    size=$(( 1 << (32 - prefix) ))
    [ $(( base & (size - 1) )) -eq 0 ] || return 2
    echo "$base $size $prefix"
}

# ga_int2ip <целое> → a.b.c.d
ga_int2ip() {
    printf '%d.%d.%d.%d' $(( ($1 >> 24) & 255 )) $(( ($1 >> 16) & 255 )) $(( ($1 >> 8) & 255 )) $(( $1 & 255 ))
}

# ga_amn_cidr_net <адрес/маска> → stdout «сеть/маска»: приложение пишет в Address сам адрес сети (10.8.1.0/24),
# чужие сборки — адрес сервера (10.8.1.1/24). Адрес проверяется по значению единственной функцией продукта
# _valid_ip (CONTRACT §0.8). Код 1 — не адрес с маской.
ga_amn_cidr_net() {
    local addr a b c d prefix base size
    [[ "${1:-}" == */* ]] || return 1
    addr="${1%/*}"; prefix="${1##*/}"
    _valid_ip "$addr" || return 1
    [[ "$prefix" =~ ^[0-9]{1,2}$ ]] && [ "$prefix" -le 32 ] || return 1
    IFS='.' read -r a b c d <<<"$addr"
    base=$(( (a << 24) | (b << 16) | (c << 8) | d ))
    size=$(( 1 << (32 - prefix) ))
    base=$(( base & ~(size - 1) & 0xFFFFFFFF ))
    printf '%s/%s' "$(ga_int2ip "$base")" "$prefix"
}

# ga_amn_conf_subnet < конфиг → stdout: подсеть по первой IPv4-записи строки Address ([Interface] сервера; у чужих
# сборок там бывает и IPv6 через запятую). Код 1 — строки нет или в ней нет IPv4 с маской.
ga_amn_conf_subnet() {
    local line item net
    line=$(sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' 2>/dev/null | head -n 1)
    [ -n "$line" ] || return 1
    local IFS=','
    for item in $line; do
        item="${item//[[:space:]]/}"
        net=$(ga_amn_cidr_net "$item") || continue
        printf '%s' "$net"
        return 0
    done
    return 1
}

# ga_amn_state_subnet <профиль> → подсеть, на которой профиль работает на самом деле: строка Address его копии
# конфига в state/ (у подхваченного — конфиг приложения как есть). Код 1 — копии нет или строки в ней нет.
ga_amn_state_subnet() {
    local f
    f=$(ga_amn_state_conf "$1" 2>/dev/null) || return 1
    [ -r "$f" ] || return 1
    ga_amn_conf_subnet <"$f"
}

# ga_amn_app_subnets [контейнер] → строки «контейнер<TAB>cidr»: контейнеры AmneziaWG приложения Amnezia на машине
# (legacy amnezia-awg — wg0.conf, amnezia-awgN — awg0.conf), за которыми не стоит установленный профиль. Их подсеть
# займёт профиль, когда контейнер подхватят, — новый профиль на ней сделал бы подхват пересечением (SUBNET-01).
# Контейнер из аргумента пропускается: это место, которое установка профиля и так займёт (без людей снесёт как
# остаток, с людьми откажет foreign_container). Docker не стоит или молчит — пусто: это подсказка выбору подсети,
# а не условие установки.
ga_amn_app_subnets() {
    local skip="${1:-}" ps name st rest managed=" " p path cidr
    if ! ga_dry && ! command -v docker >/dev/null 2>&1; then return 0; fi
    type docker_ps_all >/dev/null 2>&1 || return 0
    ps=$(docker_ps_all 2>/dev/null) || return 0
    [ -n "$ps" ] || return 0
    for p in awg1 awg2 awg3; do
        ga_profile_installed "$p" || continue
        managed+="$(ga_profile_field "$p" container) "
    done
    while IFS=$'\t' read -r name st rest; do
        [[ "$name" =~ ^amnezia-awg[0-9]*$ ]] || continue
        [ "$name" = "$skip" ] && continue
        case "$managed" in *" $name "*) continue ;; esac
        for path in /opt/amnezia/awg/awg0.conf /opt/amnezia/awg/wg0.conf; do
            [ "$name" = amnezia-awg ] && [ "$path" = /opt/amnezia/awg/awg0.conf ] && continue
            cidr=$(docker_read_file_any "$name" "$path" 2>/dev/null | ga_amn_conf_subnet) || cidr=""
            [ -n "$cidr" ] && break
        done
        [ -n "$cidr" ] && printf '%s\t%s\n' "$name" "$cidr"
    done <<<"$ps"
    return 0
}

# ga_amn_taken_subnets <профиль> [виды] → строки «имя<TAB>cidr<TAB>вид»: с чем подсеть профиля не должна
# пересекаться. Виды через запятую (по умолчанию все три):
#   net     — сети Docker: amnezia-dns-net и мост docker0 (на 172.17.x у пиров есть рукопожатие, но нет трафика —
#             eth0 контейнера сам живёт в 172.17.0.2, находка SR-37);
#   profile — другие профили config.json: записанная подсеть, а у установленного ещё и та, на которой он работает
#             на самом деле (Address его копии в state/), если она другая или записи нет. Раньше считалась только
#             запись: подхваченный профиль без поля subnet или с устаревшим полем свободной считал свою же сеть, и
#             новый профиль вставал на неё (SUBNET-01, сценарий «в»);
#   app     — контейнеры AmneziaWG приложения, ещё не подхваченные (ga_amn_app_subnets).
ga_amn_taken_subnets() {
    local me="$1" kinds=",${2:-net,profile,app}," d0="" a b c e p base size rec inst real line
    if [[ "$kinds" == *",net,"* ]]; then
        printf '%s\t%s\tnet\n' "${GA_DOCKER_NET:-amnezia-dns-net}" "${GA_DOCKER_NET_SUBNET:-172.29.172.0/24}"
        # Живую сеть моста берём у машины (daemon.json мог её сменить), не узнать — умолчание Docker.
        if ! ga_dry && command -v ip >/dev/null 2>&1; then
            d0=$(ip -4 -o addr show docker0 2>/dev/null | awk '{print $4; exit}')
        fi
        if [[ "$d0" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] && [ "${BASH_REMATCH[5]}" -le 32 ]; then
            a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}; c=${BASH_REMATCH[3]}; e=${BASH_REMATCH[4]}; p=${BASH_REMATCH[5]}
            size=$(( 1 << (32 - p) )); base=$(( ((a << 24) | (b << 16) | (c << 8) | e) & ~(size - 1) & 0xFFFFFFFF ))
            d0="$(ga_int2ip "$base")/$p"
        else
            d0="${GA_DOCKER0_SUBNET:-172.17.0.0/16}"
        fi
        printf 'docker0\t%s\tnet\n' "$d0"
    fi
    if [[ "$kinds" == *",profile,"* ]] && [ -f "$CONFIG_FILE" ]; then
        # Разделитель — \x1f, а не табуляция: табуляция в IFS «пробельная», и пустое поле (подсеть не записана —
        # тот самый случай) склеивалось с соседним, сдвигая колонки.
        while IFS=$'\x1f' read -r p rec inst; do
            [ -n "$p" ] || continue
            [ -n "$rec" ] && printf '%s\t%s\tprofile\n' "$p" "$rec"
            [ "$inst" = 1 ] && ga_profile_valid "$p" || continue
            real=$(ga_amn_state_subnet "$p" 2>/dev/null) || real=""
            [ -n "$real" ] || [ -n "$rec" ] || real=$(ga_profile_default "$p" subnet 2>/dev/null) || real=""
            [ -n "$real" ] && [ "$real" != "$rec" ] && printf '%s\t%s\tprofile\n' "$p" "$real"
        done < <(jq -r --arg me "$me" '.profiles // {} | to_entries[] | select(.key != $me and (.value | type) == "object")
                    | [.key, ((.value.subnet // "") | tostring),
                       (if ((.value.installed_at // "") | tostring) != "" then "1" else "0" end)]
                    | map(gsub("[\u001f\n\t]"; " ")) | join("\u001f")' "$CONFIG_FILE" 2>/dev/null)
    fi
    if [[ "$kinds" == *",app,"* ]]; then
        while IFS=$'\t' read -r p line; do
            [ -n "$p" ] && printf '%s\t%s\tapp\n' "$p" "$line"
        done < <(ga_amn_app_subnets "$(ga_profile_default "$me" container 2>/dev/null)")
    fi
    return 0
}

# Занятое — массивами, один раз на выбор или проверку: подбор свободной подсети перебирает до 254 кандидатов, и
# чтение config.json, копий состояния и контейнеров на каждого (как было) стоило секунд на сервере в 1 vCPU.
# _ga_amn_taken_load <профиль> [виды] [доп. строки «имя<TAB>cidr<TAB>вид»] — заполнить; _ga_amn_taken_hit <cidr> —
# пересекается ли cidr с занятым (rc 0 — да, номер записи в _GA_TK_HIT). Записи не CIDR пропускаются.
_GA_TK_NAME=(); _GA_TK_CIDR=(); _GA_TK_KIND=(); _GA_TK_BASE=(); _GA_TK_SIZE=(); _GA_TK_HIT=-1
_ga_amn_taken_load() {
    local me="$1" kinds="${2:-}" extra="${3:-}" name cidr kind parsed b s
    _GA_TK_NAME=(); _GA_TK_CIDR=(); _GA_TK_KIND=(); _GA_TK_BASE=(); _GA_TK_SIZE=(); _GA_TK_HIT=-1
    while IFS=$'\t' read -r name cidr kind; do
        [ -n "$name" ] && [ -n "$cidr" ] || continue
        parsed=$(ga_cidr_parse "$cidr") || continue
        read -r b s _ <<<"$parsed"
        _GA_TK_NAME+=("$name"); _GA_TK_CIDR+=("$cidr"); _GA_TK_KIND+=("${kind:-profile}")
        _GA_TK_BASE+=("$b"); _GA_TK_SIZE+=("$s")
    done < <(ga_amn_taken_subnets "$me" "$kinds"; [ -n "$extra" ] && printf '%s\n' "$extra")
    return 0
}
_ga_amn_taken_hit() {
    local parsed base size i
    _GA_TK_HIT=-1
    parsed=$(ga_cidr_parse "${1:-}") || return 1
    read -r base size _ <<<"$parsed"
    for i in "${!_GA_TK_BASE[@]}"; do
        if [ "$base" -lt $(( _GA_TK_BASE[i] + _GA_TK_SIZE[i] )) ] && [ "${_GA_TK_BASE[i]}" -lt $(( base + size )) ]; then
            _GA_TK_HIT="$i"
            return 0
        fi
    done
    return 1
}
# _ga_amn_taken_free <профиль> → первая свободная по загруженному занятому: умолчание профиля (CONTRACT §2), затем
# 10.8.N.0/24. Код 1 — свободной нет.
_ga_amn_taken_free() {
    local cidr n
    cidr=$(ga_profile_default "$1" subnet 2>/dev/null) || cidr=""
    if [ -n "$cidr" ] && ! _ga_amn_taken_hit "$cidr"; then printf '%s' "$cidr"; return 0; fi
    for ((n = 1; n <= 254; n++)); do
        cidr="10.8.$n.0/24"
        _ga_amn_taken_hit "$cidr" || { printf '%s' "$cidr"; return 0; }
    done
    return 1
}

# ga_amn_subnet_overlapping <cidr> [профиль-исключение] → JSON-массив профилей config.json, чья подсеть (записанная или
# фактическая) пересекается с cidr. Для находки контейнеров приложения (import_scan): с кем совпадёт подхват.
ga_amn_subnet_overlapping() {
    local cidr="$1" parsed base size i acc=" " out='[]'
    parsed=$(ga_cidr_parse "$cidr" 2>/dev/null) || { printf '[]'; return 0; }
    read -r base size _ <<<"$parsed"
    _ga_amn_taken_load "${2:-}" profile
    for i in "${!_GA_TK_BASE[@]}"; do
        if [ "$base" -lt $(( _GA_TK_BASE[i] + _GA_TK_SIZE[i] )) ] && [ "${_GA_TK_BASE[i]}" -lt $(( base + size )) ]; then
            case "$acc" in *" ${_GA_TK_NAME[i]} "*) continue ;; esac
            acc+="${_GA_TK_NAME[i]} "
        fi
    done
    for i in $acc; do out=$(jq -c --arg p "$i" '. + [$p]' <<<"$out"); done
    printf '%s' "$out"
}

# ga_amn_profile_label <профиль> → «AmneziaWG 1.0 (awg1)»: профиль словами в сообщениях ядра (линия — фактическая; у двух
# профилей одна линия — с портом, ga_profile_title). Не установлен — имя места, как прежде.
ga_amn_profile_label() {
    if ga_profile_installed "$1" 2>/dev/null; then ga_profile_title "$1"; else printf '%s' "$1"; fi
}

# ga_amn_subnet_check <профиль> <cidr> [виды] — подсеть годится профилю: частный диапазон и маска /20–/24 (как
# pattern subnet в actions.json), сетевой адрес выровнен, нет пересечений с занятым (ga_amn_taken_subnets, по
# умолчанию — со всем). Код 2 — плохая подсеть, 1 — пересечение (subnet_overlap): в тексте — с чем именно и
# свободная подсеть, которую можно взять вместо (её же подставляют меню и бот).
ga_amn_subnet_check() {
    local profile="$1" cidr="${2:-}" kinds="${3:-}" i who free msg
    if ! [[ "$cidr" =~ ^(10\.[0-9]{1,3}\.[0-9]{1,3}\.0|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.0|192\.168\.[0-9]{1,3}\.0)/2[0-4]$ ]] \
       || ! ga_cidr_parse "$cidr" >/dev/null; then
        ga_err invalid_subnet "$(tf amnezia_err_subnet "$cidr")" 2
        return 2
    fi
    _ga_amn_taken_load "$profile" "$kinds"
    _ga_amn_taken_hit "$cidr" || return 0
    i="$_GA_TK_HIT"
    case "${_GA_TK_KIND[i]}" in
        app)     msg=$(tf amnezia_err_subnet_overlap_app "$cidr" "${_GA_TK_CIDR[i]}" "${_GA_TK_NAME[i]}") ;;
        profile) who=$(ga_amn_profile_label "${_GA_TK_NAME[i]}")
                 msg=$(tf amnezia_err_subnet_overlap "$cidr" "${_GA_TK_CIDR[i]}" "$who") ;;
        *)       msg=$(tf amnezia_err_subnet_overlap_net "$cidr" "${_GA_TK_NAME[i]}" "${_GA_TK_CIDR[i]}") ;;
    esac
    # Свободная — по тому же загруженному занятому (вид — все: подсказка не должна вести на чужой контейнер).
    if [ -z "$kinds" ] && free=$(_ga_amn_taken_free "$profile"); then
        msg="$msg $(tf amnezia_subnet_free_hint "$free")"
    fi
    ga_err subnet_overlap "$msg"
    return 1
}

# Подсеть для новой установки: значение по умолчанию из таблицы контракта §2, а если оно занято (другим профилем,
# в том числе подхваченным у приложения, контейнером приложения или сетью Docker) — первая свободная 10.8.N.0/24.
# Второй аргумент — что ещё считать занятым (строки «имя<TAB>cidr<TAB>вид»: подсети, уже предложенные другим
# профилям в том же выходе из пересечения). stdout: cidr.
ga_amn_pick_subnet() {
    local profile="$1" extra="${2:-}" cidr
    _ga_amn_taken_load "$profile" "" "$extra"
    if cidr=$(_ga_amn_taken_free "$profile"); then
        GA_ERR_CODE=""; GA_ERR_MSG=""
        echo "$cidr"
        return 0
    fi
    ga_err subnet_overlap "$(tf amnezia_err_no_free_subnet "$profile")"
    return 1
}

# ── Пересечение подсетей профилей и выход из него (SUBNET-01) ───────────────
#
# Приложение Amnezia ставит любой контейнер AmneziaWG — и старый amnezia-awg (wg0), и amnezia-awg2 — на одну и ту
# же 10.8.1.0/24 (protocols::wireguard::defaultSubnetAddress, client/core/utils/constants/protocolConstants.h). Подхват
# второго из них отказывал «подсеть пересекается», а старому сменить подсеть нельзя (его start.sh знает только
# прежнюю, subnet_legacy): тупик. Теперь подхват берёт контейнер как есть — люди продолжают ходить, — а пересечение
# показывают SSH, панель и бот с выходом: перенести на свободную подсеть тот профиль, которому смена разрешена.
#
# ga_amn_subnet_fixed <профиль> — подсеть профилю не сменить: подхваченный legacy-контейнер на wg0 (start.sh
# приложения знает только прежнюю подсеть, наш start.sh — только awg0; amnezia_profile_set_subnet отказывает).
ga_amn_subnet_fixed() { [ "$(ga_amn_iface "$1")" != "$GA_AWG_IFACE" ]; }

# ga_amn_subnet_overlaps → stdout JSON-массив: запись на каждый установленный профиль, чья подсеть пересекается с
# подсетью другого установленного: {profile, subnet, with: [профили], fixed, move: {profile, subnet, keyless} | null}.
# fixed — подсеть этому профилю не сменить (ga_amn_subnet_fixed). move — выход для этой записи: какой профиль
# перенести и на какую свободную подсеть (у переносимого — он сам, у остающегося — его сосед); keyless — сколько
# людей того профиля без ключа на сервере (подхвачены у приложения): после переноса они без связи, пока не получат
# новые ключи, и перенос — только с согласием (adopted_confirm, ACC-2). null — свободной подсети нет.
# Кто остаётся: тот, кому подсеть не сменить; иначе — у кого больше людей без ключа (их перенос рвёт больше); при
# равенстве — поставленный раньше. Переносятся остальные: так новый профиль уходит, а старый остаётся.
# Без пересечений — [] одним проходом jq по config.json и чтением копий конфигов (status зовут часто).
ga_amn_subnet_overlaps() {
    local -a ids=() subs=() fixed=() since=() bases=() sizes=() owners=()
    local p sub inst iface cont at real parsed b s i j n=0 rows k
    [ -f "$CONFIG_FILE" ] || { printf '[]'; return 0; }
    # Разделитель — \x1f: пустые поля (подсеть не записана, iface у старых установок) табуляция склеила бы.
    while IFS=$'\x1f' read -r p sub inst iface cont at; do
        [ "$inst" = 1 ] && ga_profile_valid "$p" || continue
        [[ "$iface" =~ ^(awg|wg)[0-9]$ ]] || iface="$GA_AWG_IFACE"
        [ -n "$cont" ] || cont=$(ga_profile_default "$p" container)
        real=""
        if [ -f "$STATE_DIR/$cont/awg0.conf" ]; then real=$(ga_amn_conf_subnet <"$STATE_DIR/$cont/awg0.conf") || real=""
        elif [ -f "$STATE_DIR/$cont/$iface.conf" ]; then real=$(ga_amn_conf_subnet <"$STATE_DIR/$cont/$iface.conf") || real=""
        fi
        [ -n "$sub" ] || sub="$real"
        [ -n "$sub" ] || sub=$(ga_profile_default "$p" subnet)
        for k in "$sub" "$real"; do
            [ -n "$k" ] || continue
            parsed=$(ga_cidr_parse "$k") || continue
            read -r b s _ <<<"$parsed"
            bases+=("$b"); sizes+=("$s"); owners+=("$n")
        done
        ids+=("$p"); subs+=("$sub"); since+=("$at")
        if [ "$iface" != "$GA_AWG_IFACE" ]; then fixed+=(true); else fixed+=(false); fi
        n=$((n + 1))
    done < <(jq -r '.profiles // {} | to_entries[] | select((.value | type) == "object")
                | [.key, ((.value.subnet // "") | tostring),
                   (if ((.value.installed_at // "") | tostring) != "" then "1" else "0" end),
                   ((.value.iface // "") | tostring), ((.value.container // "") | tostring),
                   ((.value.installed_at // "") | tostring)]
                | map(gsub("[\u001f\n\t]"; " ")) | join("\u001f")' "$CONFIG_FILE" 2>/dev/null)
    # Пары по любой из подсетей профиля (записанной и фактической).
    local -A pair=() paired=()
    for i in "${!bases[@]}"; do
        for j in "${!bases[@]}"; do
            [ "${owners[i]}" != "${owners[j]}" ] || continue
            if [ "${bases[i]}" -lt $(( bases[j] + sizes[j] )) ] && [ "${bases[j]}" -lt $(( bases[i] + sizes[i] )) ]; then
                pair["${owners[i]},${owners[j]}"]=1
                paired["${owners[i]}"]=1
            fi
        done
    done
    [ "${#pair[@]}" -gt 0 ] || { printf '[]'; return 0; }
    # Группы связности: кто с кем пересекается хотя бы через третьего.
    local -a grp=() keyless=()
    for i in "${!ids[@]}"; do grp[i]="$i"; keyless[i]=$(ga_profile_keyless_count "${ids[i]}" 2>/dev/null) || keyless[i]=0; done
    local changed=1
    while [ "$changed" = 1 ]; do
        changed=0
        for k in "${!pair[@]}"; do
            i="${k%,*}"; j="${k#*,}"
            if [ "${grp[i]}" -lt "${grp[j]}" ]; then grp[j]="${grp[i]}"; changed=1
            elif [ "${grp[j]}" -lt "${grp[i]}" ]; then grp[i]="${grp[j]}"; changed=1; fi
        done
    done
    # Остающийся в каждой группе (см. выше), остальные — переносятся, каждый на свою свободную подсеть.
    local -a keep=() mto=() mfree=()
    local g best reserved=""
    for i in "${!ids[@]}"; do
        g="${grp[i]}"
        [ -n "${keep[g]:-}" ] || { keep[g]="$i"; continue; }
        best="${keep[g]}"
        if [ "${fixed[i]}" = true ] && [ "${fixed[best]}" != true ]; then keep[g]="$i"
        elif [ "${fixed[i]}" = "${fixed[best]}" ]; then
            if [ "${keyless[i]:-0}" -gt "${keyless[best]:-0}" ]; then keep[g]="$i"
            elif [ "${keyless[i]:-0}" = "${keyless[best]:-0}" ] && [ -n "${since[i]}" ] && { [ -z "${since[best]}" ] || [[ "${since[i]}" < "${since[best]}" ]]; }; then keep[g]="$i"
            fi
        fi
    done
    for i in "${!ids[@]}"; do
        g="${grp[i]}"
        # Не в паре ни с кем — не в выдаче; остающийся — не переносится.
        [ -n "${paired[$i]:-}" ] || continue
        [ "${keep[g]}" = "$i" ] && continue
        [ "${fixed[i]}" = true ] && continue
        mto[i]=1
        mfree[i]=$(ga_amn_pick_subnet "${ids[i]}" "$reserved" 2>/dev/null) || mfree[i]=""
        [ -n "${mfree[i]}" ] && reserved+="${reserved:+$'\n'}${ids[i]}-next"$'\t'"${mfree[i]}"$'\t'"profile"
    done
    rows='[]'
    local with mv first
    for i in "${!ids[@]}"; do
        with='[]'
        for k in "${!pair[@]}"; do
            [ "${k%,*}" = "$i" ] || continue
            with=$(jq -c --arg p "${ids[${k#*,}]}" '. + [$p] | unique' <<<"$with")
        done
        [ "$with" != '[]' ] || continue
        mv=null
        if [ -n "${mto[i]:-}" ]; then
            [ -n "${mfree[i]}" ] && mv=$(jq -cn --arg p "${ids[i]}" --arg s "${mfree[i]}" --argjson k "${keyless[i]:-0}" '{profile: $p, subnet: $s, keyless: $k}')
        else
            # Остающийся — выход через соседа: первый переносимый из тех, с кем он пересекается.
            first=""
            for j in "${!ids[@]}"; do
                [ -n "${mto[j]:-}" ] && [ -n "${pair["$i,$j"]:-}" ] && { first="$j"; break; }
            done
            [ -n "$first" ] && [ -n "${mfree[first]}" ] && mv=$(jq -cn --arg p "${ids[first]}" --arg s "${mfree[first]}" \
                --argjson k "${keyless[first]:-0}" '{profile: $p, subnet: $s, keyless: $k}')
        fi
        rows=$(jq -c --arg p "${ids[i]}" --arg s "${subs[i]}" --argjson w "$with" --argjson f "${fixed[i]}" --argjson m "$mv" \
            '. + [{profile: $p, subnet: $s, with: $w, fixed: $f, move: $m}]' <<<"$rows") || rows="$rows"
    done
    printf '%s' "$rows"
}

# ga_amn_subnet_overlap_of <профиль> → запись ga_amn_subnet_overlaps для профиля (JSON) или null.
ga_amn_subnet_overlap_of() {
    local js
    js=$(ga_amn_subnet_overlaps 2>/dev/null) || js='[]'
    jq -c --arg p "$1" 'first(.[]? | select(.profile == $p)) // null' <<<"$js" 2>/dev/null || printf 'null'
}

# ga_amn_subnet_overlap_text <запись ga_amn_subnet_overlaps> → то же словами: с кем пересекается и выход (кого
# перенести, куда и что будет с людьми приложения без ключа). Для SSH и сообщений моста; бот и панель складывают
# свои слова из тех же полей.
ga_amn_subnet_overlap_text() {
    local e="$1" p sub with="" w mp mfree mk text
    p=$(jq -r '.profile // empty' <<<"$e" 2>/dev/null) || return 1
    [ -n "$p" ] || return 1
    sub=$(jq -r '.subnet // "?"' <<<"$e")
    while IFS= read -r w; do
        [ -n "$w" ] && with="${with:+$with, }$(ga_amn_profile_label "$w")"
    done < <(jq -r '.with[]? // empty' <<<"$e")
    text=$(tf amnezia_subnet_overlap_note "$sub" "$(ga_amn_profile_label "$p")" "${with:--}")
    mp=$(jq -r '.move.profile // empty' <<<"$e"); mfree=$(jq -r '.move.subnet // empty' <<<"$e")
    mk=$(jq -r '.move.keyless // 0' <<<"$e"); [[ "$mk" =~ ^[0-9]+$ ]] || mk=0
    if [ -n "$mp" ] && [ -n "$mfree" ]; then
        text="$text $(tf amnezia_subnet_overlap_move "$(ga_amn_profile_label "$mp")" "$mfree")"
        [ "$mk" -gt 0 ] && text="$text $(tf amnezia_subnet_overlap_keyless "$mk")"
    else
        text="$text $(t amnezia_subnet_overlap_nofree)"
    fi
    printf '%s' "$text"
}

# IP сервера в config.json: он уходит в start.sh контейнера и в Endpoint ключей.
# Мастер пишет его при установке; мост --action на конфиге без адреса —
# здесь. Не нашли (нет выхода в интернет) — не блокируем: экспорт ключа
# определит адрес при выдаче, а start.sh использует его только в комментарии.
ga_amn_ensure_server_ip() {
    local ip
    ip=$(ga_config_get ".server_ip" 2>/dev/null)
    [ -n "$ip" ] && return 0
    ip=$(get_server_ip 2>/dev/null) || ip=""
    if [ -z "$ip" ] || [ "$ip" = "0.0.0.0" ]; then
        log_warning "$(t amnezia_warn_server_ip)"
        return 0
    fi
    ga_config_merge "$(jq -cn --arg ip "$ip" '{server_ip: $ip}')" || true
    return 0
}

# amnezia_server_ip_check — заметить переезд сервера.
#
# Поле server_ip писалось ТОЛЬКО в пустое (выше), и обновить его было некому:
# после переезда на другой VPS или смены белого адреса хостером config.json
# хранил мёртвый адрес, а он и есть Endpoint каждого ключа, выданного без
# домена. Все новые ключи уезжали в никуда, и ни один экран об этом не говорил.
#
# Почему отдельной функцией, а не внутри ensure. Ensure зовётся при установке
# профиля, и ходить за адресом в сеть на каждой установке незачем; а главное —
# «записанный адрес не тот» это НЕ рядовое событие установки, а тревога, и
# место ей там, где живут остальные тревоги продукта: в стороже.
#
# Записываем новый адрес и говорим вслух. Молчать нельзя, а не записывать —
# бессмысленно: server_ip по определению «адрес этого сервера», и устаревшее
# значение ломает каждый следующий ключ. Кому нужен постоянный адрес поверх
# переездов, задаёт домен в endpoint_host — о нём и напоминает строка.
# stdout: JSON {checked, ip, old, changed}.
amnezia_server_ip_check() {
    local ip old pinned changed=false
    old=$(ga_config_get ".server_ip" 2>/dev/null)
    ip=$(get_server_ip 2>/dev/null) || ip=""
    # Определить адрес не вышло — записанное не трогаем: «сеть молчит» не повод
    # затирать верный адрес нулями.
    # Прежний адрес всё ещё на машине — это не переезд, а машина с несколькими адресами: внешняя
    # служба называет адрес ИСХОДЯЩИХ, а он может не принимать входящие. Раньше проверка раз в час
    # переписывала рабочий адрес в ключах на такой (находка SR-41, 25.09.2026).
    if [ -n "$old" ] && [ "$old" != "$ip" ] && type ga_edge_list >/dev/null 2>&1 \
       && grep -qxF -- "$old" <<<"$(ga_edge_list 2>/dev/null)"; then
        ip="$old"
    fi
    local pin_action=""
    # Адреса сервера в config.json нет вовсе (установка без сети, адрес не определился): раньше проверка
    # его не заполняла никогда (условие «[ -n старый ]»), ключ уходил на исходящий, а при следующем сбое
    # сети выдача отказывала endpoint_unknown (находка SR-49). Первый найденный адрес — записываем.
    if [ -z "$old" ] && [ -n "$ip" ] && [ "$ip" != "0.0.0.0" ] && _valid_ip "$ip"; then
        ga_config_merge "$(jq -cn --arg ip "$ip" '{server_ip: $ip}')" || true
        ga_audit "${GOAMNEZIA_WHO:-timer}" "server-ip-set" "$ip"
    fi
    if [ -n "$ip" ] && [ "$ip" != "0.0.0.0" ] && _valid_ip "$ip" && [ -n "$old" ] && [ "$old" != "$ip" ]; then
        changed=true
        log_warning "$(tf amnezia_server_ip_changed "$old" "$ip")"
        ga_audit "${GOAMNEZIA_WHO:-timer}" "server-ip-changed" "$old -> $ip"
        # Endpoint, закреплённый на IP сервера («IP сервера» в боте и панели), едет вместе с адресом:
        # иначе новые ключи уходили бы на прежний, мёртвый.
        pinned=$(ga_config_get ".endpoint_host" 2>/dev/null)
        local addrs=""
        type ga_edge_list >/dev/null 2>&1 && addrs=$(ga_edge_list 2>/dev/null)
        if [ "$pinned" = "$old" ]; then
            ga_config_merge "$(jq -cn --arg ip "$ip" '{server_ip: $ip, endpoint_host: $ip, endpoint_host_foreign: false}')" || true
            pin_action=moved
        elif [ -n "$pinned" ] && _valid_ip "$pinned" && [ -n "$addrs" ] && ! grep -qxF -- "$pinned" <<<"$addrs"; then
            if [ "$(ga_config_get ".endpoint_host_foreign" 2>/dev/null)" = true ]; then
                # Вписан НАМЕРЕННО чужой адрес (проброс, балансировщик: при записи его на машине не было, и
                # владелец это подтвердил) — он и после переезда не наш; снимать его молча значило бы
                # сломать проброс. Оставляем и говорим: проброс надо перенаправить на новый адрес.
                log_warning "$(tf amnezia_endpoint_pin_foreign_kept "$pinned" "$ip")"
                ga_config_merge "$(jq -cn --arg ip "$ip" '{server_ip: $ip}')" || true
                pin_action=kept
            else
                # Вписанный вручную IP, которого после переезда на машине больше нет, — в ключах он
                # остался бы навсегда (находка SR-45, 25.09.2026). Снимаем закрепление: ключи берут
                # адрес по умолчанию. Список адресов пуст (NAT) — не трогаем: за NAT свой внешний
                # адрес машина на интерфейсах не видит.
                log_warning "$(tf amnezia_endpoint_pin_gone "$pinned")"
                ga_config_merge "$(jq -cn --arg ip "$ip" '{server_ip: $ip, endpoint_host: "", endpoint_host_foreign: false}')" || true
                ga_audit "${GOAMNEZIA_WHO:-timer}" "endpoint-set" "- (pinned $pinned left with the old server)"
                pin_action=dropped
            fi
        else
            ga_config_merge "$(jq -cn --arg ip "$ip" '{server_ip: $ip}')" || true
        fi
        # Переезд — и в config.json (L-06): уведомление видит только бот и только в момент события, а Обзор
        # панели и главный экран бота показывают «IP изменился: было, стало, когда» и потом (status.server_ip_change).
        # Хранится последний переезд, все ключи всегда есть — при слиянии не остаются хвосты прошлого.
        ga_config_merge "$(jq -cn --arg o "$old" --arg n "$ip" --arg at "$(ga_now)" --arg eh "${pinned:-}" --arg a "$pin_action" \
            '{server_ip_change: {old: $o, new: $n, at: $at, endpoint_host: (if $a != "" then $eh else "" end),
                                 endpoint_host_action: $a}}')" || true
        # Что стало с вписанным адресом, — в самом событии: бот узнаёт о снятом (или оставленном чужом)
        # адресе вместе с переездом, а не из журнала таймера.
        type ga_notify >/dev/null 2>&1 && \
            ga_notify server_ip_changed "$(jq -cn --arg o "$old" --arg n "$ip" --arg eh "${pinned:-}" --arg a "$pin_action" \
                '{old: $o, new: $n} + (if $a != "" then {endpoint_host: $eh, endpoint_host_action: $a} else {} end)')"
    fi
    jq -cn --arg now "$(ga_now)" --arg ip "$ip" --arg old "$old" --argjson c "$changed" --arg a "$pin_action" \
        '{checked: $now, ip: $ip, old: $old, changed: $c, endpoint_host_action: $a}'
}

# ── Установка / удаление / перезапуск ─────────────────────────────────────────

amnezia_profile_install() { ga_with_config_lock _amnezia_profile_install_locked "$@"; }
_amnezia_profile_install_locked() {
    local profile="$1" port="${2:-}" preset="${3:-default}" subnet_req="${4:-}" line_req="${5:-}" state
    [[ "$port" =~ ^[0-9]{1,6}$ ]] && port=$((10#$port))   # «05191» — порт 5191 (LC-09)
    ga_profile_check "$profile" || return $?
    # Неразбираемый config.json — честный отказ config_corrupt ПЕРВЫМ делом: иначе «профиля в конфиге нет»,
    # и страж ниже объявлял СВОЙ же контейнер владельца поставленным приложением Amnezia (foreign_container,
    # «подхватите контейнер») — агент по этому совету шёл подхватывать собственный профиль (находка UP-5).
    _ga_config_intact || { ga_err config_corrupt "$(t err_config_unreadable)"; return 1; }
    if ! [[ "$preset" =~ ^(default|quic|router)$ ]]; then
        ga_err invalid_preset "$(tf amnezia_err_preset "$preset")" 2
        return 2
    fi
    if ga_profile_installed "$profile"; then
        ga_err profile_exists "$(tf amnezia_err_exists "$profile")"
        return 1
    fi
    local container line_base subnet
    container=$(ga_profile_default "$profile" container)
    # Контейнер с таким именем уже есть, а профиля в config.json нет (иначе
    # отказал бы profile_exists выше) — значит, его ставил не goAmnezia. Если в
    # его конфиге есть люди, отказываем и зовём в импорт: подхват оставляет
    # контейнер работать, а людей — со своими ключами. Остаток без конфига или
    # без пиров (наша сорвавшаяся установка, пустой контейнер приложения)
    # сносится на шаге 4, как раньше. Проверка — до ключей и сборки образа:
    # отказ не должен оставлять после себя ничего.
    ga_amn_foreign_guard "$container" || return 1
    # Свежая установка без просьбы о линии — недостающая линия пары (DUP-LINE-01, правило LZ-02: ga_profile_auto_line):
    # по месту (awg3 → 3.1), если другое место пары не держит уже эту линию; держит (подхваченный amnezia-awg2 с 3.1) —
    # сюда вторая из пары, 2.0. Иначе на сервере вставали две 3.1 и ни одной 2.0. Дальше по жизни профиля источник
    # правды — его фактические параметры (ga_profile_line).
    line_base=$(ga_profile_auto_line "$profile")
    [[ "$line_base" =~ ^(1\.5|2\.0|3\.1)$ ]] || line_base=$(ga_profile_default "$profile" line)
    # Линия по просьбе (пятый аргумент; Ленивый Pro, LZ-02; мост profile-install --line): место awg2/awg3 — только имя
    # контейнера, линия 2.0 или 3.1 — любая из двух (приложение Amnezia само держит 3.1 в amnezia-awg2). 1.x — только
    # на своём месте, awg1.
    if [ -n "$line_req" ]; then
        case "$profile:$line_req" in
            awg2:2.0|awg2:3.1|awg3:2.0|awg3:3.1) line_base="$line_req" ;;
            *) ga_err invalid_line "$(tf amnezia_err_line "$line_req" "$profile")" 2; return 2 ;;
        esac
    fi
    # Своя подсеть, если её назвали: нужна, когда у клиента уже есть туннели с такими адресами (роутер держит
    # подключения к другим серверам в 10.8.1.x). Правила те же, что у profile-subnet, и проверка — до всякой
    # установки. Не назвали — по умолчанию; её могли отдать другому профилю (profile-subnet), и тогда берём
    # первую свободную, а не поднимаем два интерфейса на одной сети.
    if [ -n "$subnet_req" ]; then
        ga_amn_subnet_check "$profile" "$subnet_req" || return $?
        subnet="$subnet_req"
    else
        ga_capture subnet ga_amn_pick_subnet "$profile" || return 1
    fi

    # 1. Порт, Docker, сеть.
    if [ -z "$port" ]; then
        ga_capture port ga_amn_pick_port "$profile" || return 1
    fi
    ga_amn_port_check "$profile" "$port" || return $?
    log_step "$(tf amnezia_installing "$profile" "$container" "$port")"
    ga_amn_disk_ok || return 1
    docker_ensure_installed || return 1
    docker_ensure_network || return 1
    # Второй раз — когда демон точно работает: был остановлен, и проверка выше
    # контейнера не видела, а docker_ensure_installed его поднял.
    ga_amn_foreign_guard "$container" || return 1
    ga_amn_ensure_qr_dep
    ga_amn_ensure_server_ip

    # 2. Параметры линейки: генератор → валидатор → фактическая линейка по
    # содержимому (пресет router для awg1 даёт 1.0 без I — как приложение).
    local params line
    params=$(ga_awgkeys gen-params --line "$line_base" --preset "$preset") || {
        ga_err params_failed "$(tf amnezia_err_params "$line_base" "$preset")"; return 1; }
    if ! ga_amn_validate_params "$line_base" "$params"; then
        ga_err params_invalid "$(tf amnezia_err_params "$line_base" "$preset")"
        return 1
    fi
    params=$(jq -c . <<<"$params" 2>/dev/null) || { ga_err params_failed "$(tf amnezia_err_params "$line_base" "$preset")"; return 1; }
    line=$(printf '%s' "$params" | ga_awgkeys detect-line 2>/dev/null | tr -d '[:space:]')
    [[ "$line" =~ ^(1\.0|1\.5|2\.0|3\.1)$ ]] || line="$line_base"

    # 3. Серверные ключи — на хосте, сразу в state/: это единственное место,
    # где приватный ключ сервера лежит вне контейнера.
    local sdir priv pub psk
    sdir="$STATE_DIR/$container"

    # Приватный ключ сервера существует в ОДНОМ экземпляре, и вот он. Если файл
    # уже есть, значит профиль когда-то ставился, и перезаписать ключ — значит
    # убить все выданные ключи разом: серверный конфиг пересоберётся из нового
    # приватника и уедет в контейнер, а клиенты останутся со старым публичным.
    # Так и случалось, когда битый config.json уводил в мастер первой установки:
    # проверка «профиль установлен?» читала тот же конфиг, отвечала «нет», и
    # установка шла поверх живого состояния (docs/DEFECTS.md §1c.1). Здесь
    # второй рубеж, не зависящий от конфига вовсе: смотрим на сам файл ключа.
    if [ -s "$sdir/$GA_AWG_SERVER_PRIV" ]; then
        # Ключ есть — но это ДВА разных состояния, и путать их нельзя:
        #
        #   • профиль есть и в config.json — живая установка, перезапись убьёт
        #     все выданные ключи, отказываем и советуем profile-remove;
        #   • профиля в config.json нет — это осиротевший ключ от установки,
        #     сорвавшейся между шагом 3 (ключи на диск) и шагом 5 (запись в
        #     конфиг): нет сети, лимит Docker Hub, медленный сервер. Им никто
        #     никогда не пользовался, выдавать по нему нечего. Если считать и
        #     это конфликтом, получается замкнутый круг: установка просит
        #     удалить профиль, а удаление отвечает «профиль не установлен», и
        #     выхода нет ни из одного интерфейса — только rm руками на сервере;
        #   • конфиг не читается — не знаем, какое из двух, и потому отказываем:
        #     это тот самый случай, ради которого страж и появился.
        if ! _ga_config_intact; then
            ga_err config_corrupt "$(tf amnezia_err_state_conflict "$profile" "$sdir/$GA_AWG_SERVER_PRIV")"
            return 1
        fi
        if ga_profile_installed "$profile"; then
            ga_err state_conflict "$(tf amnezia_err_state_conflict "$profile" "$sdir/$GA_AWG_SERVER_PRIV")"
            return 1
        fi
        log_warning "$(tf amnezia_state_orphan "$profile")"
        rm -rf "$sdir" 2>/dev/null || { ga_err state_failed "$(tf amnezia_err_state "$sdir")"; return 1; }
    fi

    # Осиротевшее состояние не должно копиться и впредь: если установка сорвётся
    # ниже (образ, сборка, запуск контейнера), снимаем каталог, который только
    # что завели. Ловушка RETURN снимается сама в конце удачного пути.
    GA_AMN_NEW_SDIR="$sdir"
    # Тело ловушки — в ОДИНАРНЫХ кавычках, и это не вкусовщина: в двойных
    # "$GA_AMN_NEW_SDIR" раскрылся бы прямо здесь, при установке ловушки, а не
    # при выходе. Раньше сюда попало экранирование вида '"'"' (так одинарную
    # кавычку прячут ВНУТРИ одинарных кавычек — например, когда строку правили
    # однострочником), и всё тело склеилось в одно слово: bash пытался
    # выполнить его как имя команды, писал в stderr «No such file or
    # directory» на каждой установке профиля, а осиротевший каталог состояния
    # после сорвавшейся установки так и не убирался — ради чего ловушка и
    # ставилась.
    trap '[ -n "${GA_AMN_NEW_SDIR:-}" ] && rm -rf "$GA_AMN_NEW_SDIR" 2>/dev/null; GA_AMN_NEW_SDIR=""' RETURN

    ga_amn_state_init "$sdir" || { ga_err state_failed "$(tf amnezia_err_state "$sdir")"; return 1; }
    priv=$(ga_awgkeys genkey) || return 1
    pub=$(ga_awgkeys_pubkey "$priv") || return 1
    psk=$(ga_awgkeys genpsk) || return 1
    if [ -z "$priv" ] || [ -z "$pub" ] || [ -z "$psk" ]; then
        ga_err keys_failed "$(t amnezia_err_keys)"
        return 1
    fi
    # Код записи проверяем у КАЖДОГО из трёх файлов. Провал записи приватника
    # вылезет позже и громко (конфиг собрать не из чего), а вот незаписанные
    # открытый ключ и общий секрет уехали бы в тишине: восстановление
    # состояния отсутствующие файлы просто пропускает, и профиль поднимался бы
    # без PSK — то есть без той самой пары, что лежит у клиентов.
    printf '%s\n' "$priv" | ga_amn_write_secret "$sdir/$GA_AWG_SERVER_PRIV" \
        || { ga_err state_failed "$(tf amnezia_err_state "$sdir")"; return 1; }
    printf '%s\n' "$pub"  | ga_amn_write_secret "$sdir/$GA_AWG_SERVER_PUB" \
        || { ga_err state_failed "$(tf amnezia_err_state "$sdir")"; return 1; }
    printf '%s\n' "$psk"  | ga_amn_write_secret "$sdir/$GA_AWG_PSK" \
        || { ga_err state_failed "$(tf amnezia_err_state "$sdir")"; return 1; }

    # 4. Образ по дайджесту → сборка официального Dockerfile → контейнер.
    local ref repo tag digest build_dir
    docker_pull_pinned "$GA_IMAGE_KEY" || return 1
    ref=$(docker_image_ref "$GA_IMAGE_KEY")
    repo=$(docker_image_field "$GA_IMAGE_KEY" repo)
    tag=$(docker_image_field "$GA_IMAGE_KEY" tag)
    digest=$(docker_image_field "$GA_IMAGE_KEY" digest)
    ga_capture build_dir ga_amn_build_context "$container" "$ref" || return $?
    ga_amn_docker_build "$container" "$build_dir" || return 1
    ga_capture state docker_container_state "$container"
    ga_amn_docker_up "$state" || return 1
    if [ "$state" != "missing" ]; then
        # Остаток от приложения или прошлой попытки — как remove_container.sh.
        log_warning "$(tf amnezia_warn_old_container "$container")"
        docker_rm "$container"
    fi
    docker_run_awg "$container" "$port" "$container" || return 1

    # 5. Профиль в config.json — до записи конфига: write_server_conf читает
    # параметры и порт оттуда (единый источник правды).
    local now entry
    now=$(ga_now)
    entry=$(jq -cn --arg line "$line" --arg c "$container" --argjson port "$port" \
        --arg subnet "$subnet" --arg image "$repo" --arg tag "$tag" --arg digest "$digest" \
        --arg preset "$preset" --argjson params "$params" --arg pub "$pub" --arg now "$now" \
        '{line: $line, container: $c, port: $port, subnet: $subnet, iface: "awg0",
          image: $image, image_tag: $tag, image_digest: $digest, preset: $preset,
          params: $params, server_pubkey: $pub, installed_at: $now, enabled: true}') || return 1
    ga_config_set ".profiles.$profile" "$entry" || { ga_err config_write_failed "$(t amnezia_err_config)"; return 1; }

    # Метку снимаем ЗДЕСЬ, а не в конце. С этой строки каталог состояния больше
    # не осиротевший: профиль записан в config.json, и приватный ключ сервера в
    # state/ — единственная его копия на хосте. Раньше метка держалась до самого
    # конца, и любой отказ дальше (запись в контейнер, сборка конфига, запуск,
    # ожидание подъёма с таймаутом в 20 секунд, синхронизация состояния) уводил
    # в ловушку RETURN, а та сносила каталог вместе с ключом. Человек оставался в
    # тупике: поставить заново нельзя — «профиль уже есть», поднять из состояния
    # нельзя — «состояния нет», и каждая следующая копия архивировала пустоту.
    # Это была регрессия от починки осиротевшего каталога: лечили один тупик и
    # завели второй, хуже прежнего.
    GA_AMN_NEW_SDIR=""

    # 6. Ключи и конфиг в контейнер, clientsTable, start.sh, запуск, файрвол.
    printf '%s\n' "$priv" | docker_write_file "$container" "$GA_AWG_DIR/$GA_AWG_SERVER_PRIV" 0600 || return 1
    printf '%s\n' "$pub"  | docker_write_file "$container" "$GA_AWG_DIR/$GA_AWG_SERVER_PUB" 0600 || return 1
    printf '%s\n' "$psk"  | docker_write_file "$container" "$GA_AWG_DIR/$GA_AWG_PSK" 0600 || return 1
    amnezia_write_server_conf "$profile" || return 1
    amnezia_clientstable_write "$profile" || return 1
    ga_amn_write_start_sh "$profile" || return 1
    ga_amn_container_start "$container" || return 1
    amnezia_host_firewall
    ga_amn_wait_up "$profile" || return 1
    amnezia_state_sync "$profile" || return 1

    ga_audit "${GOAMNEZIA_WHO:-ssh}" "profile-install" "$profile port=$port line=$line preset=$preset"
    log_success "$(tf amnezia_installed "$profile" "$line" "$port")"
    jq -cn --arg profile "$profile" --arg container "$container" --argjson port "$port" \
        --arg line "$line" --arg preset "$preset" --arg pub "$pub" --arg tag "$tag" --arg digest "$digest" \
        '{profile: $profile, container: $container, port: $port, line: $line, preset: $preset,
          server_pubkey: $pub, image_tag: $tag, image_digest: $digest}'
}

amnezia_profile_remove() { ga_with_config_lock _amnezia_profile_remove_locked "$@"; }
_amnezia_profile_remove_locked() {
    local profile="$1" container sdir profiles users state
    ga_profile_check_installed "$profile" || return $?
    container=$(ga_profile_field "$profile" container)
    sdir="$STATE_DIR/$container"
    # Пользователей читаем ПЕРВЫМ ДЕЙСТВИЕМ, до сноса контейнера и ключей.
    # Раньше здесь стояла подстановка команды со скелетом на пустоту, и на
    # НЕРАЗБИРАЕМОМ файле это означало «пользователей нет»:
    # удаление ненужного профиля отвечало «успешно» и записывало пустой список
    # поверх файла — исчезали приватные ключи ВСЕХ профилей, а не только
    # удаляемого. Отказ обязан случиться до первой разрушительной операции.
    ga_users_load users || return 1
    # Демон Docker не отвечает — контейнер не снимется, а ключи и запись удалились бы: контейнер с --restart
    # always продолжал бы обслуживать всех пиров профиля, о котором продукт уже не знает (ни удалить
    # пользователя, ни применить лимит). Отказ — до первой разрушительной операции.
    ga_capture state docker_container_state "$container"
    ga_amn_docker_up "$state" || return 1
    # Соседи в сети контейнера (warp-socks рядом с goWARP PRO) без него остаются без сети — говорим, кто именно.
    local deps
    deps=$(docker_netdeps_list "$container" | paste -sd, - 2>/dev/null)
    [ -n "$deps" ] && log_warning "$(tf amnezia_warn_netdeps_remove "$container" "$deps")"
    docker_rm "$container" || return 1
    # Предупреждение, подтверждение и бэкап — на стороне интерфейса (правило
    # серии §0.11); здесь ключи профиля удаляются безвозвратно.
    rm -rf "$sdir"
    if ! ga_dry; then
        rm -rf "/opt/amnezia/$container"
    fi
    printf '%s' "$users" | jq --arg p "$profile" '.users |= map(del(.peers[$p]))' | ga_users_write || return 1
    profiles=$(ga_config_get ".profiles" | jq -c --arg p "$profile" 'del(.[$p])') || return 1
    ga_config_set ".profiles" "$profiles" || return 1
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "profile-remove" "$profile"
    log_success "$(tf amnezia_removed "$profile")"
    # Страницы подключения, где ключей больше не осталось (они вели только на этот профиль), — снимаем: после
    # переустановки профиля забытая ссылка снова отдала бы ключ (находка UI-4). Кроме перестановки на другую линию
    # (GA_AMN_KEEP_PAGES=1, amnezia_profile_reline): профиль тут же встаёт снова, и те же люди получают ключи — их
    # страницы должны отдать новый ключ, а не пропасть.
    [ "${GA_AMN_KEEP_PAGES:-}" = 1 ] || { type ga_users_pages_prune_locked >/dev/null 2>&1 && ga_users_pages_prune_locked; }
    return 0
}

# ga_amn_remove_preview <профиль> → JSON {profile, title, holders, pages, page_users[], text} — что потеряют пользователи
# при «Удалить профиль», до согласия (PROFILE-REMOVE-PAGES): holders — у скольких ключ на нём, page_users — у кого
# перестанет работать страница подключения (в ней был только этот профиль: удаление её снимает, ga_users_pages_prune_locked),
# text — то же словами на языке вызова (пусто — страниц таких нет). Только чтение; само удаление не меняется.
ga_amn_remove_preview() {
    local profile="$1" users holders lost pu np text=""
    ga_profile_check_installed "$profile" || return $?
    ga_users_load users || return 1
    holders=$(jq -r --arg p "$profile" '[.users[]? | select(((.peers // {})[$p]) != null)] | length' <<<"$users" 2>/dev/null)
    [[ "$holders" =~ ^[0-9]+$ ]] || holders=0
    lost=$(ga_users_pages_lost_json "$profile")
    np=$(jq -r '.pages // 0' <<<"$lost" 2>/dev/null)
    [[ "$np" =~ ^[0-9]+$ ]] || np=0
    pu=$(jq -c '.users // []' <<<"$lost" 2>/dev/null) || pu='[]'
    if [ "$np" -eq 1 ]; then text=$(tf amnezia_remove_pages_one "$(_ga_amn_names "$pu")")
    elif [ "$np" -gt 1 ]; then text=$(tf amnezia_remove_pages_many "$(_ga_amn_names "$pu")")
    fi
    jq -cn --arg p "$profile" --arg title "$(ga_amn_profile_label "$profile")" --argjson h "$holders" --argjson n "$np" \
        --argjson pu "$pu" --arg text "$text" \
        '{profile: $p, title: $title, holders: $h, pages: $n, page_users: $pu, text: $text}'
}

amnezia_profile_restart() { ga_with_config_lock _amnezia_profile_restart_locked "$@"; }
_amnezia_profile_restart_locked() {
    local profile="$1" container
    ga_profile_check_installed "$profile" || return $?
    container=$(ga_profile_field "$profile" container)
    # После рестарта счётчики awg show начинаются с нуля — users_quota_tick
    # это учитывает (дельта = новое показание).
    docker_restart "$container" || return 1
    if ! ga_amn_wait_up "$profile"; then
        [ "${GA_ERR_CODE:-}" = port_unpublished ] || return 1
        # Docker поднял контейнер без опубликованного порта (LC-20): перезапуск этого не лечит, лечит
        # пересоздание из копии состояния — ключи и люди прежние.
        log_warning "$(tf amnezia_warn_port_unpublished_recreate "$profile" "$(ga_profile_field "$profile" port)")"
        GA_ERR_CODE=""; GA_ERR_MSG=""
        amnezia_state_restore "$profile" recreate || return 1
    fi
    amnezia_state_sync "$profile"
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "profile-restart" "$profile"
    log_success "$(tf amnezia_restarted "$profile")"
}

# ga_profile_keyless_count <профиль> → сколько людей профиля без приватного ключа на сервере: подхвачены у
# приложения Amnezia (ключ выдало приложение и держит только у себя) и не привязаны и не перевыпущены. Смена
# порта рвёт им связь, а переслать новые конфиги нечем (находка ACC-2). Пир, которого приложение уже убрало
# (сверка ставит active=false), не считаем: его и так нет. Битый users.json — код 1.
ga_profile_keyless_count() {
    local users n
    ga_users_load users 2>/dev/null || return 1
    n=$(jq -r --arg p "${1:-}" '[.users[]? | .peers[$p]? // empty
                                 | select(type == "object" and (.privkey // "") == "" and .active != false)] | length' \
        <<<"$users" 2>/dev/null) || return 1
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$n"
}

# Смена порта = пересоздание контейнера из state/ (порт задаётся флагом -p при
# docker run и не меняется у живого контейнера). Ключи не трогаем — у клиентов
# меняется только Endpoint.
#
# Третий аргумент — согласие на перенос профиля с людьми без ключа на сервере (подхвачены у приложения
# Amnezia): имя того же профиля ещё раз. Без него такой перенос отклоняется кодом adopted_keyless — SSH-меню
# просит набрать порт профиля (согласие — имя профиля), мост берёт имя из --adopted-confirm (ACC-2).
amnezia_profile_set_port() { ga_with_config_lock _amnezia_profile_set_port_locked "$@"; }
_amnezia_profile_set_port_locked() {
    local profile="$1" port="$2" confirm="${3:-}" container old state keyless
    # «05191» из бота или панели — это порт 5191: иначе сообщения («UDP/05191», «порт 04398 занят») повторяли
    # сырой ввод (находка LC-09). Десятичная запись, а не восьмеричная.
    [[ "$port" =~ ^[0-9]{1,6}$ ]] && port=$((10#$port))
    ga_profile_check_installed "$profile" || return $?
    container=$(ga_profile_field "$profile" container)
    old=$(ga_profile_field "$profile" port)
    if [ "$old" = "$port" ]; then
        ga_err invalid_port "$(tf amnezia_err_same_port "$port")" 2
        return 2
    fi
    # Люди приложения Amnezia без ключа на сервере: после переноса они перестанут подключаться, а переслать им
    # новые конфиги нечем — молча такой перенос не делаем (ACC-2). Не прочитали users.json — не знаем, кого
    # отрежем, и контейнер не трогаем: дальше запись конфига всё равно упала бы, но уже после пересоздания.
    keyless=$(ga_profile_keyless_count "$profile") || { ga_err users_corrupt "$(t users_err_corrupt)"; return 1; }
    if [ "$keyless" -gt 0 ] && [ "$confirm" != "$profile" ]; then
        ga_err adopted_keyless "$(tf amnezia_err_port_adopted "$profile" "$keyless" "$old" "$port" "$profile")" 2
        return 2
    fi
    # Порт нашего же контейнера в ss занят — проверяем до остановки, чужие сокеты видны и так.
    ga_amn_port_check "$profile" "$port" || return $?
    ga_capture state docker_container_state "$container"
    ga_amn_docker_up "$state" || return 1
    if [ "$state" = "running" ]; then
        amnezia_state_sync "$profile" || return 1
    fi
    if [ ! -f "$STATE_DIR/$container/$GA_AWG_SERVER_PRIV" ]; then
        ga_err state_missing "$(tf amnezia_err_state_missing "$container")" 3
        return 3
    fi
    ga_amn_container_rm "$profile" || return 1
    if ! docker_run_awg "$container" "$port" "$container"; then
        # Контейнер уже снят, а на новом порту не поднялся (порт занят вне нашего учёта, сбой Docker).
        # Раньше профиль так и оставался лежать у всех, а сторож его не поднимал: возвращаем контейнер
        # на прежний порт из копии состояния — порт не сменён, ключи прежние (находка SR-35).
        if docker_run_awg "$container" "$old" "$container" && amnezia_state_restore "$profile" \
           && ga_amn_wait_up "$profile"; then
            amnezia_state_sync "$profile"
            ga_err port_change_failed "$(tf amnezia_err_port_kept "$port" "$profile" "$old")"
        else
            ga_err port_change_failed "$(tf amnezia_err_port_down "$profile" "$container")"
        fi
        return 1
    fi
    ga_config_set ".profiles.$profile.port" "$port" || return 1
    amnezia_write_server_conf "$profile" || return 1
    amnezia_state_restore "$profile" || return 1
    ga_amn_wait_up "$profile" || return 1
    amnezia_state_sync "$profile"
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "profile-port" "$profile ${old}->${port}"
    log_success "$(tf amnezia_port_changed "$profile" "$port")"
}

# ── Состояние и параметры ─────────────────────────────────────────────────────

# ga_profile_core_version <профиль> → сборка ядра профиля для людей. У своего профиля — тег образа (3.1.20260828). У
# подхваченного у приложения Amnezia тег «latest» (приложение собирает образ из FROM <repo>:latest), и слово «latest»
# ничего не говорило о совместимости (A-8 критика 16.10): сверяем дайджест его базового образа с последней удачной
# проверкой обновлений (upstream last_check.json — дайджест тега latest и новейший версионный тег на Docker Hub). Совпал —
# печатаем этот тег; не узнать (проверок не было, образ старше или новее) — пусто, rc 1.
ga_profile_core_version() {
    local p="$1" tag dig f v
    tag=$(ga_profile_field "$p" image_tag 2>/dev/null)
    if [ "$tag" != latest ]; then [ -n "$tag" ] && printf '%s' "$tag"; return 0; fi
    dig=$(ga_profile_field "$p" image_digest 2>/dev/null)
    [[ "$dig" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    type ga_up_last_check >/dev/null 2>&1 || return 1
    f=$(ga_up_last_check 2>/dev/null)
    [ -f "$f" ] || return 1
    v=$(jq -r --arg d "$dig" '[(.images // {}) | to_entries[] | .value | select(type == "object")
            | select((.latest_tag // "") != "" and ($d == .alias_latest_digest or $d == .latest_digest or $d == .latest_amd64_digest))
            | .latest_tag][0] // empty' "$f" 2>/dev/null)
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

amnezia_profile_status() {
    local profile="$1" container state port line tag digest peers enabled users
    ga_profile_check_installed "$profile" || return $?
    container=$(ga_profile_field "$profile" container)
    state=$(docker_container_state "$container")
    port=$(ga_profile_field "$profile" port)
    line=$(ga_profile_line "$profile")
    tag=$(ga_profile_field "$profile" image_tag)
    digest=$(ga_profile_field "$profile" image_digest)
    # ga_config_get пропускает только простые пути (без выражений) и печатает
    # пусто для false — поэтому сравниваем строку, а не вычисляем в jq.
    enabled=$(ga_config_get ".profiles.$profile.enabled" 2>/dev/null)
    [ "$enabled" = "true" ] || enabled=false
    # «Пиров ноль» и «файл пользователей не читается» — разные ответы. В
    # конвейере из подстановки второе неотличимо от первого, и карточка
    # профиля спокойно показывала ноль пиров у работающего сервера.
    ga_users_load users || return 1
    peers=$(jq --arg p "$profile" '[.users[]? | .peers[$p]? // empty | select(.active == true)] | length' <<<"$users" 2>/dev/null)
    [[ "$peers" =~ ^[0-9]+$ ]] || peers=0
    [[ "$port" =~ ^[0-9]+$ ]] || port=0
    # port_published — у работающего контейнера опубликован ли его порт (false — «работает», а связи нет:
    # находка LC-20); null — контейнер не работает или Docker не ответил.
    local published=null prc=0
    if [ "$state" = running ]; then
        docker_port_published "$container" "$port" udp 2>/dev/null || prc=$?
        case "$prc" in 0) published=true ;; 1) published=false ;; esac
    fi
    # client_isolation — настройка изоляции клиентов профиля (SEC-NET-1), только для показа: переключателя в
    # интерфейсах пока нет, выключается client_isolation=false в config.json.
    local iso=true
    ga_amn_isolation_on || iso=false
    # subnet_fixed — подсеть профилю не сменить (подхваченный старый контейнер на wg0, ga_amn_subnet_fixed): экраны
    # подсети говорят это сразу и ведут к выходу из пересечения, а не после набранной подсети (SUBNET-01).
    local sfixed=false
    ga_amn_subnet_fixed "$profile" && sfixed=true
    # packet_risk — пакет данных профиля не влезает в мобильные сети и PPPoE из-за большого S4 (S4-FIX, MTU-01):
    # предупреждение и кнопка «Исправить S4» в SSH, панели и боте; null — риска нет. Без Docker: config.json и, когда
    # риск есть, users.json.
    local risk
    risk=$(ga_amn_packet_risk "$profile" 2>/dev/null) || risk=null
    case "$risk" in '{"packet":'*'}') ;; *) risk=null ;; esac
    # line_shared — у другого профиля та же линия (подхваченная 3.1 приложения и своя, DUP-LINE-01); title — подпись
    # для людей на языке ядра (ga_profile_title): «AmneziaWG 3.1 · порт 46567 · из приложения».
    # imported — подхвачен у приложения Amnezia: переставлять на другую линию такой профиль нельзя никогда.
    local shared=false imported=false title
    ga_profile_line_shared "$profile" && shared=true
    [ "$(ga_config_get ".profiles.$profile.imported" 2>/dev/null)" = true ] && imported=true
    title=$(ga_profile_title "$profile")
    # core_version — сборка ядра словами экрана: у подхваченного «latest» — версия по дайджесту, пусто — не узнать (A-8).
    local corev=""
    corev=$(ga_profile_core_version "$profile" 2>/dev/null) || corev=""
    jq -cn --arg profile "$profile" --arg container "$container" --arg state "$state" \
        --argjson port "$port" --arg line "$line" --argjson peers "$peers" \
        --arg tag "$tag" --arg digest "$digest" --argjson enabled "${enabled:-false}" --argjson pub "$published" \
        --argjson iso "$iso" --argjson fixed "$sfixed" --argjson risk "${risk:-null}" \
        --argjson shared "$shared" --argjson imp "$imported" --arg title "$title" --arg corev "$corev" \
        '{profile: $profile, container: $container, state: $state, port: $port, line: $line,
          peers: $peers, image_tag: $tag, image_digest: $digest, core_version: $corev, enabled: $enabled, port_published: $pub,
          client_isolation: $iso, subnet_fixed: $fixed, packet_risk: $risk, line_shared: $shared,
          imported: $imp, title: $title}'
}

amnezia_profile_params() {
    local profile="$1" params
    ga_profile_check_installed "$profile" || return $?
    params=$(ga_config_get ".profiles.$profile.params" | jq -c . 2>/dev/null)
    [ -n "$params" ] || params='{}'
    echo "$params"
}

# Новые параметры маскировки: конфиг сервера переписывается, все пиры профиля
# перевыпускаются (старые ключи с новыми параметрами не соединятся всё равно —
# линейки и параметры несовместимы), контейнер перезапускается, чтобы
# awg-quick up перечитал [Interface].
amnezia_profile_regen() { ga_with_config_lock _amnezia_profile_regen_locked "$@"; }
_amnezia_profile_regen_locked() {
    local profile="$1" preset="${2:-default}" container line_base params line patch state
    ga_profile_check_installed "$profile" || return $?
    if ! [[ "$preset" =~ ^(default|quic|router)$ ]]; then
        ga_err invalid_preset "$(tf amnezia_err_preset "$preset")" 2
        return 2
    fi
    container=$(ga_profile_field "$profile" container)
    # Пересборка параметров идёт в линейке, в которой профиль живёт сейчас:
    # у подхваченного из приложения контейнера она может не совпадать с той,
    # что подразумевает имя профиля (amnezia-awg2 бывает и 3.1).
    line_base=$(ga_profile_line_base "$profile")
    params=$(ga_awgkeys gen-params --line "$line_base" --preset "$preset") || {
        ga_err params_failed "$(tf amnezia_err_params "$line_base" "$preset")"; return 1; }
    if ! ga_amn_validate_params "$line_base" "$params"; then
        ga_err params_invalid "$(tf amnezia_err_params "$line_base" "$preset")"
        return 1
    fi
    params=$(jq -c . <<<"$params") || return 1
    # MTU — не параметр маскировки: выбранный человеком переживает перегенерацию. Иначе новые параметры тихо
    # возвращали умолчание 1280 — и в клиентские конфиги, и в конфиг сервера (WRP-02).
    local keep_mtu
    keep_mtu=$(ga_config_get ".profiles.$profile.params.MTU" 2>/dev/null)
    if [[ "$keep_mtu" =~ ^[0-9]{3,5}$ ]]; then
        params=$(jq -c --arg m "$keep_mtu" '.MTU = $m' <<<"$params") || return 1
    fi
    line=$(printf '%s' "$params" | ga_awgkeys detect-line 2>/dev/null | tr -d '[:space:]')
    [[ "$line" =~ ^(1\.0|1\.5|2\.0|3\.1)$ ]] || line="$line_base"
    # Демон Docker — ДО первой записи: иначе при лежащем демоне ключи всех пользователей уже
    # перевыпущены, а контейнер со старыми — и мост отвечал безликим «не выполнено» (SR-33).
    ga_capture state docker_container_state "$container"
    ga_amn_docker_up "$state" || return 1
    patch=$(jq -cn --arg p "$profile" --argjson params "$params" --arg line "$line" --arg preset "$preset" \
        '{profiles: {($p): {params: $params, line: $line, preset: $preset}}}') || return 1
    ga_config_merge "$patch" || { ga_err config_write_failed "$(t amnezia_err_config)"; return 1; }
    GA_AMN_SYNC_RESTARTED=""
    if declare -F users_reissue_profile >/dev/null; then
        users_reissue_profile "$profile" || return 1
    else
        amnezia_write_server_conf "$profile" || return 1
    fi
    if [ "$state" = "running" ] || ga_dry; then
        # На модуле ядра новую маскировку уже применил рестарт внутри amnezia_syncconf (KMOD-01) — второй рвал бы
        # связь ещё раз.
        if ! ga_amn_sync_restarted "$container"; then
            docker_restart "$container" || return 1
            ga_amn_wait_up "$profile" || return 1
        fi
        amnezia_state_sync "$profile"
    fi
    ga_amn_mask_take "$container" || true
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "profile-regen" "$profile line=$line preset=$preset"
    log_success "$(tf amnezia_regenerated "$profile" "$line")"
}

# ── Настройки профиля «как в приложении Amnezia» (PLAN §10 п.9) ──────────────

# amnezia_profile_param_list <профиль> → stdout JSON [{key, value, scope}] по
# фактической линейке профиля (свежая установка: awg1 → 1.5, awg2 → 2.0,
# awg3 → 3.1; подхваченный контейнер — линейка его конфига): это всё, что
# можно задать в этом контейнере. Для SSH-меню, бота и панели — один список.
amnezia_profile_param_list() {
    local profile="$1" line_base params
    ga_profile_check_installed "$profile" || return $?
    line_base=$(ga_profile_line_base "$profile")
    params=$(ga_config_get ".profiles.$profile.params" | jq -c . 2>/dev/null)
    [ -n "$params" ] || params='{}'
    jq -cn --argjson p "$params" --arg keys "$(ga_amn_param_keys "$line_base")" \
        --arg srv "$GA_AMN_SERVER_PARAMS" '
        ($srv | split(" ")) as $s
        | [ $keys | split(" ")[]
            | . as $k
            | {key: $k, value: (($p[$k] // "") | tostring),
               scope: (if ($s | index([$k])) != null then "server" else "client" end)} ]'
}

# amnezia_profile_set_param <профиль> <ключ> <значение> — один параметр, как в
# настройках приложения. stdout: JSON {profile, key, value, old_value, scope,
# line, reissue_required, restarted, engine, clients_update, audience, update_hours, summary, steps}. Пустое значение =
# убрать параметр. С 1.0.13: пределы того, что пишем мы (ga_amn_limits_reason, params_invalid словами); не применилось —
# прежнее назад (_ga_amn_param_undo: param_rolled_back или param_apply_failed словами, PARAM-10); кому нужен новый
# конфиг — audience и steps (PARAM-11).
amnezia_profile_set_param() { ga_with_config_lock _amnezia_profile_set_param_locked "${1:-}" "${2:-}" "${3:-}"; }
# amnezia_profile_param_check <профиль> <ключ> <значение> — те же проверки значения, что у amnezia_profile_set_param,
# без записи и без замка конфига (только чтение). Код 0 — запишется; иначе отказ теми же словами (ga_err). SSH спрашивает
# «Записать …?» только после неё (K5-1: прежде подтверждали значение, которое затем всё равно не записывалось).
amnezia_profile_param_check() { _amnezia_profile_set_param_locked "${1:-}" "${2:-}" "${3:-}" check-only; }
_amnezia_profile_set_param_locked() {
    local profile="$1" key="${2:-}" value="${3:-}" check="${4:-}"
    local container line_base line_old line params new scope old detail patch reissue=false state engine reason
    local restarted=false
    local value_re='^[A-Za-z0-9+/=<>. _-]*$'
    ga_profile_check_installed "$profile" || return $?
    # Имя — только из белого списка, значение — как pattern param_value в
    # actions.json: число, диапазон a-b, on/off, base64 или сигнатурный пакет
    # <b 0x…><r N>. Оба уходят в jq только аргументами, но в конфиг контейнера
    # попадают текстом — лишнему там не место.
    if ! scope=$(ga_amn_param_scope "$key"); then
        ga_err invalid_param "$(tf amnezia_err_param_key "$key")" 2
        return 2
    fi
    if ! [[ "$value" =~ $value_re ]] || [ "${#value}" -gt 512 ]; then
        ga_err invalid_param_value "$(tf amnezia_err_param_value "$key")" 2
        return 2
    fi
    # MTU — единственный параметр с продуктовым диапазоном (ga_amn_mtu_settable:
    # ga_valid_mtu из lib/common.sh и не меньше 1280). Спрашиваем ту же проверку,
    # что и profile-mtu: раньше валидатор awgkeys.py держал здесь свои 576–65535,
    # и один и тот же MTU 9000 через profile-mtu отвергался, а через
    # profile-set-param проходил. Пустое значение — это «убрать параметр»,
    # диапазон к нему не применим.
    if [ "$key" = "MTU" ] && [ -n "$value" ]; then
        ga_amn_mtu_settable "$value" || return 2
    fi
    # PARAM-01 (S4-FIX): S4, который пишем мы, — не больше 40: при стандартном MTU 1280 пакет данных 1280 + 80 + S4
    # обязан уложиться в 1400, иначе та же поломка, что MTU-01 (скачивание стоит на мобильном интернете и PPPoE). Путь
    # один на SSH, бот, панель и MCP. Подхваченный профиль с большим S4 так и живёт: его другие параметры меняются,
    # а у него самого — пометка и «Исправить S4».
    if [ "$key" = S4 ] && [ -n "$value" ] && ga_amn_s4_risky "$value"; then
        ga_err params_invalid "$(tf amnezia_err_s4_budget "$((10#$value))" \
            "$((GA_AMN_MTU_STANDARD + GA_AMN_PACKET_OVERHEAD + 10#$value))" "$GA_AMN_PACKET_BUDGET" "$GA_AMN_S4_SAFE_MAX")" 2
        return 2
    fi
    container=$(ga_profile_field "$profile" container)
    line_base=$(ga_profile_line_base "$profile")
    line_old=$(ga_profile_line "$profile")
    params=$(ga_config_get ".profiles.$profile.params" | jq -c . 2>/dev/null)
    [ -n "$params" ] || params='{}'
    old=$(jq -r --arg k "$key" '.[$k] // ""' <<<"$params")
    new=$(jq -c --arg k "$key" --arg v "$value" '.[$k] = $v' <<<"$params") || return 1
    # Проверяем по линейке-основанию профиля (семейство его ФАКТИЧЕСКОЙ линейки,
    # не его имени), а новую фактическую определяем по содержимому, как при
    # установке: так awg1 переходит между 1.0 и 1.5, добавляя или убирая I1, но
    # S3/S4 и 3.x-поля в линейку 1.x не пройдут, а в 2.0 не пройдут 3.x-поля.
    # Подхваченный из приложения amnezia-awg2 с 3.x-конфигом при этом остаётся
    # редактируемым в своей линейке — имя профиля тут ничего не решает.
    # Причины валидатора показываем человеку и первую из них отдаём мосту в
    # сообщении (stderr — через файл: подстановка $( ) с уведённым stdout
    # ловится shellcheck как пустая, и справедливо).
    #
    #
    # Сигнатурные пакеты I1–I5 (KMOD-02) шлёт клиент, и годность тега решают реализации у клиентов, а не движок
    # сервера. Значение, которое пишем мы, — только теги, понятные всем (b t r rc rd); причина отказа — словами. Уже
    # записанные I (подхват, где тег не всех реализаций — предупреждение) проверяются правилами подхвата: иначе
    # подхваченный профиль с <c> в I1 не дал бы поменять даже Jc.
    if [[ "$key" =~ ^I[1-5]$ ]] && [ -n "$value" ] \
       && reason=$(ga_amn_ipacket_reason "$(jq -cn --arg k "$key" --arg v "$value" '{($k): $v}')" write) \
       && [ -n "$reason" ]; then
        ga_err params_invalid "$reason" 2
        return 2
    fi
    local errf
    # stderr валидатора (в нём могут быть значения набора) — секретным файлом в памяти и затиранием, как у
    # ga_amn_limits_reason (R2-6), а не обычным mktemp в общем каталоге.
    if type ga_mktemp_secret >/dev/null 2>&1; then errf=$(ga_mktemp_secret gaval); else errf=$(mktemp); fi || return 1
    if ! ga_amn_validate_params "$line_base" "$new" adopt >/dev/null 2>"$errf"; then
        [ -s "$errf" ] && sed 's/^/    /' "$errf" >&2
        detail=$(sed -n 's/^awgkeys: validate: //p' "$errf" | head -n 1)
        if type ga_wipe_file >/dev/null 2>&1; then ga_wipe_file "$errf"; else rm -f "$errf"; fi
        # Беда в уже записанном сигнатурном пакете — словами, а не английской строкой валидатора.
        if [[ "$detail" =~ ^I[1-5]: ]] && reason=$(ga_amn_ipacket_reason "$new" adopt) && [ -n "$reason" ]; then
            ga_err params_invalid "$reason" 2
            return 2
        fi
        ga_err params_invalid "$(tf amnezia_err_param_invalid "$key" "${detail:-?}")" 2
        return 2
    fi
    if type ga_wipe_file >/dev/null 2>&1; then ga_wipe_file "$errf"; else rm -f "$errf"; fi
    line=$(printf '%s' "$new" | ga_awgkeys detect-line 2>/dev/null | tr -d '[:space:]')
    [[ "$line" =~ ^(1\.0|1\.5|2\.0|3\.1)$ ]] || line="$line_old"
    # Семейство правкой параметров не меняется ни вверх (это ловит валидатор), ни вниз: 3.1, у которого по
    # одному сняли все 3.x-поля, становился 2.0, и вернуть его не мог даже profile-regen — он пересобирает
    # в фактической линейке. Уже выданные ключи и клиенты другой линейки при этом не подходят.
    if [ "$(ga_line_family "$line")" != "$(ga_line_family "$line_base")" ]; then
        ga_err params_invalid "$(tf amnezia_err_param_family "$key" "$profile" "$line_old" "$line")" 2
        return 2
    fi
    # Пределы того, что пишем мы (1.0.13, живые проверки 08.10): тайминги 3.1 и ContentPaddingAddition — в коридоре
    # вокруг значений приложения Amnezia (PARAM-03), всплеск мусора Jc × Jmax — до 16 КБ (PARAM-08), Jc + число I — до
    # 127 (PARAM-09), хвосты 3.1 при разных S — без широких H (PARAM-05, #226). Путь один на SSH, бот, панель и MCP.
    # Только то, что ломает или ухудшает запись ЭТОГО ключа: подхваченный профиль с чужими значениями так и живёт
    # (при подхвате о них — предупреждение), его другие параметры меняются, а чинить его можно по шагу.
    # Проверка сама упала — значение без проверки не пишем (params_failed словами).
    if ! reason=$(ga_amn_limits_reason "$line_base" "$new" "$key" "$old"); then
        ga_err params_failed "$reason"
        return 1
    fi
    if [ -n "$reason" ]; then
        ga_err params_invalid "$reason" 2
        return 2
    fi
    # Проверка без записи (amnezia_profile_param_check, K5-1): все отказы выше — здесь, дальше только Docker и запись.
    [ "$check" = check-only ] && return 0
    [ "$scope" = "server" ] && reissue=true
    # Демон Docker — ДО первой записи (SR-33): иначе параметр уже в config.json и state/, а в
    # контейнере прежний, и отказ приходил без кода.
    ga_capture state docker_container_state "$container"
    ga_amn_docker_up "$state" || return 1
    # Движок профиля (модуль ядра или программа, KMOD_PLAN А0) — один раз на действие, только чтобы решить, как
    # применить параметр (KMOD-01). Контейнер не работает — применять нечего: unknown.
    engine=unknown
    if [ "$state" = "running" ] || ga_dry; then engine=$(ga_amn_engine "$profile"); fi
    # PARAM-10: что было до записи — запись профиля в config.json целиком и копия awg0.conf. Не применилось — вернём.
    local prof_old conf_old fail=""
    prof_old=$(ga_config_get ".profiles.$profile" 2>/dev/null | jq -c 'if type == "object" then . else empty end' 2>/dev/null)
    conf_old=$(cat "$(ga_amn_state_conf "$profile")" 2>/dev/null) || conf_old=""
    patch=$(jq -cn --arg p "$profile" --argjson params "$new" --arg line "$line" \
        '{profiles: {($p): {params: $params, line: $line}}}') || return 1
    ga_config_merge "$patch" || { ga_err config_write_failed "$(t amnezia_err_config)"; return 1; }
    # Конфиг контейнера держим в согласии с config.json всегда: из него читают
    # параметры приложение Amnezia и import-scan. Серверный параметр требует
    # перечитать [Interface] — это только рестарт; клиентский применяем
    # syncconf'ом, не разрывая сессии. MTU убрали из настроек — строку MTU из
    # конфига сервера убираем тоже, а не сохраняем как чужую (WRP-02).
    if [ "$key" = MTU ] && [ -z "$value" ]; then
        GA_AMN_MTU_DROP=1 amnezia_write_server_conf "$profile" || fail=conf
    else
        amnezia_write_server_conf "$profile" || fail=conf
    fi
    if [ -n "$fail" ]; then
        :
    elif [ "$scope" = "server" ]; then
        if [ "$state" = "running" ] || ga_dry; then
            if docker_restart "$container" && ga_amn_wait_up "$profile"; then restarted=true; else fail=up; fi
        fi
        # Рестарт перечитал весь [Interface] — пометка о смене маскировки больше не нужна.
        ga_amn_mask_take "$container" || true
    elif [ "$state" = "running" ] || ga_dry; then
        # Клиентский параметр, который живёт строкой в [Interface] сервера (Jc, Jmin, Jmax, поля 3.x): на модуле ядра
        # syncconf его не несёт, и amnezia_syncconf пересоздаёт интерфейс рестартом (KMOD-01) — клиенты переподключатся
        # сами, обычно за 15–25 секунд. Пометку ставим и сами: живой конфиг мог не прочитаться. На программе — как
        # прежде, на лету. I1–I5 у сервера закомментированы и до интерфейса не доходят, PersistentKeepalive — поле
        # клиентов, MTU встаёт на живой интерфейс (ga_amn_mtu_live): им рестарт не нужен ни на каком движке.
        if [ "$old" != "$value" ] && ga_amn_iface_mask_param "$key"; then ga_amn_mask_mark "$container"; fi
        if amnezia_syncconf "$profile" "$engine"; then
            ga_amn_sync_restarted "$container" && restarted=true
        else
            fail=sync
        fi
    else
        # Контейнер не работает: применять нечего, при старте он прочтёт конфиг целиком. Пометку о смене маскировки
        # (её ставит amnezia_write_server_conf) снимаем, как в ветке сервера: иначе её взял бы следующий syncconf этого
        # контейнера в том же процессе и на модуле ядра перезапустил бы его зря (KEENETIC-I1-Q, P3).
        ga_amn_mask_take "$container" || true
    fi
    if [ -n "$fail" ]; then
        # PARAM-10: вживую 08.10 RekeyAfterTime 9999999999 записался в config.json и awg0.conf, `awg setconf` его не
        # принял — профиль лежал (container_not_up), и значение оставалось до следующей правки. Теперь — прежнее назад.
        _ga_amn_param_undo "$profile" "$key" "$value" "$old" "$prof_old" "$conf_old" "$state" "$fail"
        return 1
    fi
    amnezia_state_sync "$profile"
    local clients_update=false aud='{"subscription":[],"page":[],"key":[],"app":[]}' steps='[]' summary="" hours
    local warn_people=false
    hours="$GA_AMN_SUBS_HOURS_DEFAULT"
    # GA_AMN_PARAM_QUIET=1 — смена шагом другого действия (profile-fix-s4): запись в журнал и слова человеку — у него
    # («кому что делать» вместо общего «выдайте новые»).
    if [ "${GA_AMN_PARAM_QUIET:-0}" != 1 ]; then
        ga_audit "${GOAMNEZIA_WHO:-ssh}" "profile-set-param" "$profile $key scope=$scope line=$line engine=$engine"
        # PARAM-11: кому нужен новый конфиг. Значение — в конфиге каждого клиента (и серверное, и клиентское): выданные
        # ключи несут прежнее, пока человек не возьмёт новый. Серверное — старые конфиги больше не подключатся;
        # клиентское — работают со старым значением. Подписки отдают новое сами, остальным — выдать заново.
        if [ "$old" != "$value" ]; then
            clients_update=true
            type ga_subs_update_hours >/dev/null 2>&1 && hours=$(ga_subs_update_hours)
            [[ "$hours" =~ ^[0-9]{1,3}$ ]] || hours="$GA_AMN_SUBS_HOURS_DEFAULT"
            # Людей определить не удалось (users.json не прочитался) — не «людей нет», а общая фраза для всех.
            local aud_ok=1
            ga_capture aud ga_amn_s4_audience "$profile" 2>/dev/null || aud=""
            jq -e 'type == "object"' >/dev/null 2>&1 <<<"$aud" || { aud='{"subscription":[],"page":[],"key":[],"app":[]}'; aud_ok=0; }
            steps=$(_ga_amn_param_steps "$scope" "$restarted" "$state" "$aud" "$hours" "$aud_ok")
            jq -e 'type == "array"' >/dev/null 2>&1 <<<"$steps" || steps='[]'
            if [ "$aud_ok" = 1 ] && [ "$(jq -r '[.subscription, .page, .key, .app] | add | length' <<<"$aud" 2>/dev/null)" = 0 ]; then
                summary=$(t amnezia_s4_step_nobody)
            elif [ "$scope" = server ]; then
                summary=$(t amnezia_param_summary_server)
                warn_people=true
            else
                summary=$(t amnezia_param_summary_client)
            fi
        fi
        log_success "$(tf amnezia_param_set "$profile" "$key" "$(ga_amn_param_shown "$key" "$value")")"
        # Старые конфиги больше не подключатся — предупреждением; остальное — справкой.
        if [ "$warn_people" = true ]; then log_warning "$summary"
        elif [ -n "$summary" ]; then log_info "$summary"; fi
    fi
    # restarted — профиль перезапускался (серверный параметр или маскировка на модуле ядра): клиенты переподключатся
    # сами, обычно за 15–25 секунд; engine — движок профиля при смене (kernel | program | unknown). clients_update —
    # выданным ключам нужен новый конфиг, чтобы получить значение; audience — кто они по тому, что им делать
    # (ga_amn_s4_audience), steps — то же словами, summary — одной фразой (PARAM-11).
    # value и old_value у параметра-ключа — «***» (ga_amn_param_shown … json): ответ уходит в мост, панель, бот и MCP.
    jq -cn --arg p "$profile" --arg k "$key" --arg v "$(ga_amn_param_shown "$key" "$value" json)" \
        --arg old "$(ga_amn_param_shown "$key" "$old" json)" --arg scope "$scope" \
        --arg line "$line" --argjson reissue "$reissue" --argjson restarted "$restarted" --arg engine "$engine" \
        --argjson cu "$clients_update" --argjson aud "$aud" --argjson h "$hours" --argjson steps "$steps" \
        --arg sum "$summary" \
        '{profile: $p, key: $k, value: $v, old_value: $old, scope: $scope, line: $line, reissue_required: $reissue,
          restarted: $restarted, engine: $engine, clients_update: $cu, audience: $aud, update_hours: $h,
          summary: $sum, steps: $steps}'
}

# _ga_amn_param_steps <server|client> <перезапущен true|false> <состояние контейнера> <JSON audience> <часы подписки>
# [<1|0 — люди определены>] → JSON [{kind, text}] — кому что делать после смены параметра (PARAM-11), помощник шагов
# S4-FIX. Серверный — старые конфиги больше не подключатся (слова «Исправить S4»); клиентский — выданные работают со
# старым значением, новое — с новым конфигом. Подписки отдают новое сами. Людей определить не удалось — шаг unknown:
# «касается всех», а не «людей нет»; что делать — в summary (мост дописывает его в message), здесь не повторяем (R2-5).
_ga_amn_param_steps() {
    local scope="$1" restarted="$2" state="$3" aud="$4" hours="$5" known="${6:-1}" steps='[]' k names
    if [ "$restarted" = true ]; then
        steps=$(_ga_amn_step "$steps" restart "$(t amnezia_s4_step_restart)")
    elif [ "$state" != running ] && ! ga_dry; then
        steps=$(_ga_amn_step "$steps" start "$(t amnezia_param_step_start)")
    fi
    if [ "$known" != 1 ]; then
        _ga_amn_step "$steps" unknown "$(t amnezia_param_step_unknown)"
        return 0
    fi
    for k in subscription page key app; do
        names=$(_ga_amn_names "$(jq -c --arg k "$k" '.[$k] // []' <<<"$aud")")
        [ -n "$names" ] || continue
        if [ "$scope" = server ]; then
            case "$k" in
                subscription) steps=$(_ga_amn_step "$steps" "$k" "$(tf amnezia_s4_step_sub "$names" "$(_ga_amn_within "$hours")")") ;;
                page)         steps=$(_ga_amn_step "$steps" "$k" "$(tf amnezia_s4_step_page "$names")") ;;
                key)          steps=$(_ga_amn_step "$steps" "$k" "$(tf amnezia_s4_step_key "$names")") ;;
                app)          steps=$(_ga_amn_step "$steps" "$k" "$(tf amnezia_s4_step_app "$names")") ;;
            esac
        else
            case "$k" in
                subscription) steps=$(_ga_amn_step "$steps" "$k" "$(tf amnezia_param_cli_step_sub "$names" "$(_ga_amn_within "$hours")")") ;;
                page)         steps=$(_ga_amn_step "$steps" "$k" "$(tf amnezia_param_cli_step_page "$names")") ;;
                key)          steps=$(_ga_amn_step "$steps" "$k" "$(tf amnezia_param_cli_step_key "$names")") ;;
                app)          steps=$(_ga_amn_step "$steps" "$k" "$(tf amnezia_param_cli_step_app "$names")") ;;
            esac
        fi
    done
    if [ "$(jq -r '[.subscription, .page, .key, .app] | add | length' <<<"$aud" 2>/dev/null)" = 0 ]; then
        steps=$(_ga_amn_step "$steps" nobody "$(t amnezia_s4_step_nobody)")
    fi
    printf '%s' "$steps"
}

# _ga_amn_param_wait_up <профиль> — подъём после отката, как у «Перезапустить» (amnezia_profile_restart): Docker поднял
# контейнер без опубликованного порта (LC-20) — пересоздание из копии состояния, в ней уже прежнее значение.
_ga_amn_param_wait_up() {
    ga_amn_wait_up "$1" && return 0
    [ "${GA_ERR_CODE:-}" = port_unpublished ] || return 1
    log_warning "$(tf amnezia_warn_port_unpublished_recreate "$1" "$(ga_profile_field "$1" port)")"
    GA_ERR_CODE=""; GA_ERR_MSG=""
    amnezia_state_restore "$1" recreate
}

# _ga_amn_param_undo <профиль> <ключ> <значение> <прежнее> <прежняя запись профиля JSON> <прежний awg0.conf>
#                    <состояние контейнера до> <шаг: conf|up|sync> — PARAM-10: новое значение не применилось (конфиг не
# записался, контейнер не поднялся, syncconf не прошёл). Прежняя запись профиля — в config.json, прежний awg0.conf — в
# копию state/ и в контейнер (docker cp работает и с остановленным), контейнер, который работал, — перезапуск и подъём,
# копия state/ — заново с живого. Отказ — словами с именем параметра и причиной: param_rolled_back (прежнее значение
# вернулось, профиль работает) или param_apply_failed (вернуть или поднять не вышло — профиль лежит, как поднять).
_ga_amn_param_undo() {
    local profile="$1" key="$2" value="$3" old="$4" prof_old="$5" conf_old="$6" state="$7" step="$8"
    local why code container ok=1
    why="${GA_ERR_MSG:-$(t act_failed)}"; why="${why%.}"
    code="${GA_ERR_CODE:-$step}"
    container=$(ga_profile_field "$profile" container)
    ga_amn_mask_take "$container" >/dev/null 2>&1 || true
    if [ -n "$prof_old" ]; then
        ga_config_set ".profiles.$profile" "$prof_old" || ok=0
    else
        ok=0
    fi
    if [ -n "$conf_old" ]; then
        printf '%s\n' "$conf_old" | ga_amn_write_secret "$(ga_amn_state_conf "$profile")" || ok=0
        if [ "$state" != missing ]; then
            printf '%s\n' "$conf_old" | docker_write_file "$container" "$(ga_amn_conf_path "$profile")" 0600 || ok=0
        fi
    elif [ "$ok" = 1 ]; then
        amnezia_write_server_conf "$profile" || ok=0
    fi
    if [ "$ok" = 1 ] && { [ "$state" = running ] || ga_dry; }; then
        if [ "$step" = conf ] && ga_amn_iface_alive "$profile"; then
            :   # конфиг сервера не записался — до живого интерфейса новое не дошло, перезапускать нечего
        elif docker_restart "$container" && _ga_amn_param_wait_up "$profile"; then
            # Перезапуск — и после неудачного syncconf: программа применяет строки по одной, и часть могла встать.
            amnezia_state_sync "$profile" >/dev/null 2>&1 || true
        else
            ok=0
        fi
    fi
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "profile-set-param" \
        "$profile $key failed step=$step code=$code rolled_back=$([ "$ok" = 1 ] && echo yes || echo no)"
    if [ "$ok" = 1 ]; then
        ga_err param_rolled_back "$(tf amnezia_err_param_rolled_back "$key" "$(ga_amn_param_shown "$key" "$value")" "$why" \
            "$(ga_amn_param_shown "$key" "$old")")"
    else
        ga_err param_apply_failed "$(tf amnezia_err_param_not_applied "$key" "$(ga_amn_param_shown "$key" "$value")" "$why" \
            "$(ga_amn_param_shown "$key" "$old")" "$container")"
    fi
    return 1
}

# ── Сверка личности сервера ──────────────────────────────────────────────────
# У одной пары ключей сервера ТРИ независимых хранилища, и раньше между ними не
# было ни одной сверки:
#   • config.json .profiles.<p>.server_pubkey — отсюда открытый ключ берёт выдача;
#   • state/<container>/wireguard_server_private_key.key — отсюда приватник берёт
#     сборка серверного конфига;
#   • state/<container>/awg0.conf — то, что реально применено в контейнере.
# Расхождение возникало молча (§1c.1) и всплывало только тогда, когда о нём
# узнавали все пользователи разом: выданные ключи мертвы, и новые тоже, потому
# что выдача и сервер смотрят в разные места. Сверка нужна не меньше запретов:
# запрет ловит известный путь, сверка — любой.
#
# ga_amn_keys_consistent <профиль> → JSON {profile, config, state, conf, ok}
# В полях — ОТКРЫТЫЕ ключи (приватные наружу не отдаём), пусто = источника нет.
ga_amn_keys_consistent() {
    local profile="${1:-}" container sdir cfg_pub state_priv state_pub conf_priv conf_pub ok
    container=$(ga_profile_field "$profile" container 2>/dev/null) || container=""
    [ -n "$container" ] || { printf '%s' 'null'; return 1; }
    sdir="$STATE_DIR/$container"

    cfg_pub=$(ga_config_get ".profiles.$profile.server_pubkey" 2>/dev/null) || cfg_pub=""
    [ "$cfg_pub" = "null" ] && cfg_pub=""

    state_pub=""
    state_priv=$(cat "$sdir/$GA_AWG_SERVER_PRIV" 2>/dev/null) || state_priv=""
    if [ -n "$state_priv" ]; then
        state_pub=$(ga_awgkeys_pubkey "$state_priv" 2>/dev/null) || state_pub=""
    fi

    conf_pub=""
    # Режем ровно по ПЕРВОМУ знаку равенства: ключ base64 сам кончается на «=»,
    # и разделитель полей съедал бы этот хвост, превращая ключ в негодный.
    # Копия конфига — awg0.conf, у ещё не приведённой копии прежних версий — wg0.conf (ACC-4).
    conf_priv=$(sed -n 's/^PrivateKey[[:space:]]*=[[:space:]]*//p' "$(ga_amn_state_conf "$profile")" 2>/dev/null | head -1) || conf_priv=""
    if [ -n "$conf_priv" ]; then
        conf_pub=$(ga_awgkeys_pubkey "$conf_priv" 2>/dev/null) || conf_pub=""
    fi

    # Согласованными считаем, только когда все ТРИ источника есть и совпадают.
    # Отсутствие источника — тоже повод посмотреть: профиль установлен, а ключа
    # сервера нет, значит состояние неполное.
    ok=false
    if [ -n "$cfg_pub" ] && [ "$cfg_pub" = "$state_pub" ] && [ "$state_pub" = "$conf_pub" ]; then ok=true; fi

    jq -nc --arg p "$profile" --arg c "$cfg_pub" --arg s "$state_pub" --arg f "$conf_pub" --argjson ok "$ok" \
        '{profile:$p, config:$c, state:$s, conf:$f, ok:$ok}' 2>/dev/null \
        || printf '{"profile":"%s","config":"","state":"","conf":"","ok":false}' "$profile"
}

# amnezia_profile_set_mtu <профиль> <mtu> — MTU профиля: клиентские конфиги
# (при новых выдачах ключей), строка MTU в конфиге сервера и живой интерфейс
# сразу — без перезапуска, сессии не рвутся (решение владельца 29.09.2026:
# MTU из настроек обязан совпадать с awg0.conf и интерфейсом). Перевыпуск
# ключей не нужен: MTU в рукопожатии не участвует. Диапазон —
# ga_amn_mtu_settable (1280–1500), одна проверка на все пути: и на этот, и на
# profile-set-param MTU. Контейнера нет — только копия в state/: с ней его и
# поднимут.
amnezia_profile_set_mtu() { ga_with_config_lock _amnezia_profile_set_mtu_locked "$@"; }
_amnezia_profile_set_mtu_locked() {
    local profile="$1" mtu="${2:-}" patch container state
    ga_profile_check_installed "$profile" || return $?
    ga_amn_mtu_settable "$mtu" || return 2
    # Демон Docker — ДО первой записи (SR-33), как у profile-set-param.
    container=$(ga_profile_field "$profile" container)
    ga_capture state docker_container_state "$container"
    ga_amn_docker_up "$state" || return 1
    patch=$(jq -cn --arg p "$profile" --arg m "$mtu" '{profiles: {($p): {params: {MTU: $m}}}}') || return 1
    ga_config_merge "$patch" || { ga_err config_write_failed "$(t amnezia_err_config)"; return 1; }
    if [ "$state" = missing ]; then
        amnezia_write_server_conf "$profile" state || return 1
    else
        amnezia_write_server_conf "$profile" || return 1
        [ "$state" = running ] && amnezia_state_sync "$profile"
    fi
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "profile-mtu" "$profile $mtu"
    log_success "$(tf amnezia_mtu_set "$profile" "$mtu")"
}

# ── Пакет данных профиля: S4-FIX (MTU-01) и окно MTU ─────────────────────────
# Пакет данных = MTU + 80 + S4 (3.1 сверх этого ничего не добавляет — lib/awgkeys.py, PACKET_OVERHEAD). MTU 1280 —
# стандарт goAmnezia (решение владельца 08.10): ставится по умолчанию везде, и риск считается при нём, а не при MTU,
# который человек поднял сам для проводной сети. Риск — пакет 1280 + 80 + S4 больше бюджета 1400 (мобильный интернет,
# PPPoE, часть хостеров), то есть S4 > 40: у профилей 2.0, выданных до 1.0.12 (генератор давал S4 15–150). Формула —
# packet_risk в lib/awgkeys.py; здесь её повторяет арифметика bash (status спрашивают бот и панель на каждом экране —
# без python), сверка обеих — tests/test_awgkeys.py.
GA_AMN_MTU_STANDARD=1280
GA_AMN_PACKET_OVERHEAD=80
GA_AMN_PACKET_BUDGET=1400
GA_AMN_S4_SAFE_MAX=40
# Нижняя граница MTU, который можно задать (lib/awgkeys.py, MTU_MIN): ниже 1280 у интерфейса нет IPv6, и у клиента с
# AllowedIPs ::/0 — наш стандартный конфиг — `awg-quick up` падает («No such device» на `ip -6 route add ::/0`): туннель
# не поднимается вовсе (живая проверка L-02б, 08.10: 1279, 1240, 1200 — rc 2).
GA_AMN_MTU_MIN=1280

# Через сколько часов приложение с подпиской забирает её снова — когда модуля подписок нет (GA_SUBS_UPDATE_HOURS).
GA_AMN_SUBS_HOURS_DEFAULT=12

# ga_amn_mtu_settable <mtu> — MTU, который можно задать (profile-mtu, profile-set-param MTU — из SSH, бота, панели и MCP):
# целое не меньше 1280 (GA_AMN_MTU_MIN) и в договоре ga_valid_mtu (lib/common.sh, не больше 1500). Ниже 1280 — отказ
# словами, почему туннель не поднимется; прочее — прежний отказ с диапазоном. Код invalid_mtu, rc 2. Записанный раньше
# MTU 1200–1279 (поставлен до 1.0.12 или подхвачен) ga_valid_mtu по-прежнему пускает в выдачу ключей: эта проверка —
# только на задание.
ga_amn_mtu_settable() {
    local v="${1:-}"
    if [[ "$v" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$v))" -lt "$GA_AMN_MTU_MIN" ]; then
        ga_err invalid_mtu "$(t amnezia_err_mtu_low)" 2
        return 2
    fi
    if ! ga_valid_mtu "$v"; then
        ga_err invalid_mtu "$(tf amnezia_err_mtu "$v")" 2
        return 2
    fi
    return 0
}

# ga_amn_s4_risky <S4> — 0, если такой S4 при стандартном MTU выводит пакет данных за бюджет.
ga_amn_s4_risky() {
    local s4="${1:-}"
    [[ "$s4" =~ ^[0-9]{1,10}$ ]] || return 1
    [ $((GA_AMN_MTU_STANDARD + GA_AMN_PACKET_OVERHEAD + 10#$s4)) -gt "$GA_AMN_PACKET_BUDGET" ]
}

# ga_amn_packet_risk <профиль> → JSON {packet, budget, s4, safe_s4, mtu, keyless} или null — поле packet_risk профиля в
# status и profiles-status. keyless — люди приложения Amnezia без ключа на сервере: смена S4 у них — только с согласием
# (как перенос порта, ACC-2), экраны спрашивают его сразу. Только чтение config.json (и users.json, когда риск есть),
# без Docker.
ga_amn_packet_risk() {
    local profile="$1" s4 keyless
    s4=$(ga_config_get ".profiles.$profile.params.S4" 2>/dev/null) || s4=""
    if ! ga_amn_s4_risky "$s4"; then printf 'null'; return 0; fi
    s4=$((10#$s4))
    keyless=$(ga_profile_keyless_count "$profile" 2>/dev/null) || keyless=0
    [[ "$keyless" =~ ^[0-9]+$ ]] || keyless=0
    printf '{"packet":%d,"budget":%d,"s4":%d,"safe_s4":%d,"mtu":%d,"keyless":%d}' \
        "$((GA_AMN_MTU_STANDARD + GA_AMN_PACKET_OVERHEAD + s4))" "$GA_AMN_PACKET_BUDGET" "$s4" "$GA_AMN_S4_SAFE_MAX" \
        "$GA_AMN_MTU_STANDARD" "$keyless"
}

# ga_amn_s4_audience <профиль> → JSON {subscription, page, key, app}: имена людей профиля по тому, что им делать после
# смены S4, — насколько это знает продукт. Каждый — в одном списке, по самому простому для него пути:
#   app          — ключ выдало приложение Amnezia (приватного ключа на сервере нет): поделиться конфигом из приложения
#                  заново или перевыпустить ключ здесь;
#   subscription — подписку человека забирало приложение, которое обновляется само (state.json, auto_fetches > 0:
#                  все линии сразу — all.yaml/all.txt/mihomo.yaml, не браузер, не curl/wget, не ключ одной линии
#                  awgNN.* и не all.vpn — разовый импорт пула, R-1 и N-1 проверки 15.10): подтянет новое само. У state.json прежней службы счёта нет — по последнему забору;
#   page         — живая страница подключения с этим профилем: открыть её снова и импортировать ключ заново;
#   key          — остальные с ключом на сервере: выданный ключ vpn:// или файл .conf импортировать заново.
ga_amn_s4_audience() {
    local profile="$1" users fetched='[]' paged='[]' dir d n f
    ga_users_load users || return 1
    if type ga_subs_dir >/dev/null 2>&1; then
        dir=$(ga_subs_dir)
        for d in "$dir"/*; do
            [ -f "$d/meta.json" ] && [ -f "$d/secret" ] || continue
            n=$(basename "$d")
            [[ "$n" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || continue
            if type _ga_subs_owner_gone >/dev/null 2>&1 && _ga_subs_owner_gone "$d"; then continue; fi
            f=$(jq -r 'if has("auto_fetches") then (.auto_fetches // 0)
                elif ((.fetches // 0) > 0) and ((.last_suffix // "") | test("^(all\\.(yaml|txt)|mihomo\\.yaml)$"))
                    and ((.last_client // "") as $c | ($c != "browser" and $c != "curl" and $c != "wget")) then 1
                else 0 end' "$d/state.json" 2>/dev/null) || f=0
            [[ "$f" =~ ^[0-9]+$ ]] && [ "$f" -gt 0 ] || continue
            fetched=$(jq -c --arg n "$n" '. + [$n]' <<<"$fetched")
        done
    fi
    if type ga_pages_dir >/dev/null 2>&1; then
        dir=$(ga_pages_dir)
        for d in "$dir"/p-*; do
            [ -f "$d/meta.json" ] || continue
            if type ga_pages_expired >/dev/null 2>&1 && ga_pages_expired "$d"; then continue; fi
            n=$(jq -r --arg p "$profile" 'select(((.profiles // []) | index($p)) != null) | .user // empty' \
                "$d/meta.json" 2>/dev/null) || n=""
            [[ "$n" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || continue
            paged=$(jq -c --arg n "$n" 'if index($n) == null then . + [$n] else . end' <<<"$paged")
        done
    fi
    jq -c --arg p "$profile" --argjson subs "$fetched" --argjson pages "$paged" '
        [.users[]? | select(((.peers // {})[$p]) != null)
         | {name, key: ((((.peers // {})[$p].privkey) // "") != "")}] as $all
        | {subscription: [$all[] | select(.key) | .name | select(. as $n | ($subs | index($n)) != null)],
           page: [$all[] | select(.key) | .name | select(. as $n | ($subs | index($n)) == null and ($pages | index($n)) != null)],
           key: [$all[] | select(.key) | .name | select(. as $n | ($subs | index($n)) == null and ($pages | index($n)) == null)],
           app: [$all[] | select(.key | not) | .name]}' <<<"$users"
}

# _ga_amn_names <JSON-массив имён> → «anna, boris»: не больше 20 имён, дальше — «и ещё N».
_ga_amn_names() {
    local n
    n=$(jq -r 'length' <<<"${1:-[]}" 2>/dev/null) || n=0
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    if [ "$n" -le 20 ]; then jq -r 'join(", ")' <<<"${1:-[]}" 2>/dev/null; return 0; fi
    printf '%s %s' "$(jq -r '.[:20] | join(", ")' <<<"$1" 2>/dev/null)" "$(tf amnezia_s4_names_more "$((n - 20))")"
}

# _ga_amn_within <часы> → «до 12 ч» или «до 12 ч, у FlClash — до 24 ч»: когда подписка заберёт новое сама — словами окон
# перевыпуска (панель subWithin, бот, SSH _user_sub_within; A4-3/B4-4). Приложения каталога, которые забирают подписку
# сами реже совета сервера (ga_subs_update_slow; FlClash — раз в сутки), называются со своим сроком: с одним сроком —
# через запятую, сначала самые долгие; не дольше совета сервера — не называются. Модуля подписок или каталога нет —
# «до N ч».
_ga_amn_within() {
    local h="${1:-12}" slow='[]' rest="" hh names
    [[ "$h" =~ ^[0-9]{1,3}$ ]] || h=12
    h=$((10#$h))
    if type ga_subs_update_slow >/dev/null 2>&1; then slow=$(ga_subs_update_slow "$h" 2>/dev/null) || slow='[]'; fi
    [ -n "$slow" ] || slow='[]'
    while IFS=$'\t' read -r hh names; do
        [ -n "$hh" ] && [ -n "$names" ] || continue
        rest="${rest:+$rest, }$(tf amnezia_sub_within_app "$names" "$hh")"
    done < <(printf '%s' "$slow" | jq -r --argjson h "$h" '[.[]? | select(type == "object" and (.name | type) == "string"
        and .name != "" and (.hours | type) == "number" and .hours > $h)] | group_by(.hours) | sort_by(-.[0].hours)
        | .[] | "\(.[0].hours)\t\(map(.name) | join(", "))"' 2>/dev/null)
    if [ -z "$rest" ]; then tf amnezia_sub_within "$h"; else tf amnezia_sub_within_slow "$h" "$rest"; fi
}

# _ga_amn_step <JSON-массив шагов> <вид> <текст> → тот же массив с ещё одним шагом {kind, text}.
_ga_amn_step() {
    jq -c --arg k "$2" --arg t "$3" '. + [{kind: $k, text: $t}]' <<<"$1"
}

# amnezia_profile_fix_s4 <профиль> [согласие] → JSON — S4-FIX (MTU-01, решение владельца 08.10): выданный профиль 2.0 с
# большим S4 получает новый S4 12–24 (lib/awgkeys.py fix-s4: итоговые размеры S1–S4 попарно различны) тем же путём,
# что серверный параметр через profile-set-param: проверка набора по правилам линии, демон Docker до первой записи,
# config.json, awg0.conf, перезапуск работающего контейнера (на модуле ядра это и пересоздание интерфейса, этап А),
# копия в state/. Приватные ключи людей прежние. Страницы подключения и подписки отдают новое сами: ключи у моста
# служба берёт при каждом показе и заборе, её кеш сбрасывается по config.json. Профиль подхвачен у приложения, и у
# людей на нём ключи только в приложении (keyless) — только с согласием: второй аргумент — имя того же профиля (как
# ACC-2 и SUBNET-01), иначе adopted_keyless до всякого изменения. Риска нет — s4_safe (rc 2).
# Ответ: {profile, line, s4_old, s4, packet_old, packet, budget, restarted, engine, keyless, update_hours,
# subscription[], page[], key[], app[], summary, steps[{kind, text}]} — steps словами: кому что делать.
amnezia_profile_fix_s4() { ga_with_config_lock _amnezia_profile_fix_s4_locked "$@"; }
_amnezia_profile_fix_s4_locked() {
    local profile="$1" confirm="${2:-}" params s4_old label line keyless pick new aud out restarted engine hours
    local packet_old packet summary steps='[]' names k
    ga_profile_check_installed "$profile" || return $?
    label=$(ga_amn_profile_label "$profile")
    line=$(ga_profile_line "$profile")
    params=$(ga_config_get ".profiles.$profile.params" 2>/dev/null | jq -c 'if type == "object" then . else {} end' 2>/dev/null)
    [ -n "$params" ] || params='{}'
    s4_old=$(jq -r '.S4 // "" | tostring' <<<"$params" 2>/dev/null) || s4_old=""
    if ! [[ "$s4_old" =~ ^[0-9]{1,10}$ ]]; then
        ga_err s4_safe "$(tf amnezia_err_s4_absent "$label")" 2
        return 2
    fi
    if ! ga_amn_s4_risky "$s4_old"; then
        ga_err s4_safe "$(tf amnezia_err_s4_safe "$label" "$((10#$s4_old))" \
            "$((GA_AMN_MTU_STANDARD + GA_AMN_PACKET_OVERHEAD + 10#$s4_old))" "$GA_AMN_PACKET_BUDGET")" 2
        return 2
    fi
    s4_old=$((10#$s4_old))
    # Люди приложения Amnezia без ключа на сервере: их конфиги со старым S4 перестанут подключаться, а переслать им
    # новые нечем — молча не меняем (как перенос порта, ACC-2). users.json не читается — не знаем, кого отрежем.
    keyless=$(ga_profile_keyless_count "$profile") || { ga_err users_corrupt "$(t users_err_corrupt)"; return 1; }
    if [ "$keyless" -gt 0 ] && [ "$confirm" != "$profile" ]; then
        ga_err adopted_keyless "$(tf amnezia_err_s4_adopted "$profile" "$keyless" "$profile")" 2
        return 2
    fi
    pick=$(printf '%s' "$params" | ga_awgkeys fix-s4 2>/dev/null) || pick=""
    new=$(jq -r '.S4 // empty' <<<"$pick" 2>/dev/null) || new=""
    if ! [[ "$new" =~ ^[0-9]{1,2}$ ]]; then
        ga_err params_failed "$(tf amnezia_err_s4_pick "$label")"
        return 1
    fi
    # Кому что делать — до смены: список людей тот же, а читать его после записи незачем.
    aud=$(ga_amn_s4_audience "$profile") || { ga_err users_corrupt "$(t users_err_corrupt)"; return 1; }
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$aud" || aud='{"subscription":[],"page":[],"key":[],"app":[]}'
    # Тем же путём, что серверный параметр (profile-set-param); его журнал и слова — наши, ниже.
    GA_AMN_PARAM_QUIET=1 ga_capture out _amnezia_profile_set_param_locked "$profile" S4 "$new" || return $?
    restarted=$(jq -r 'if .restarted == true then "true" else "false" end' <<<"$out" 2>/dev/null) || restarted=false
    engine=$(jq -r '.engine // "unknown"' <<<"$out" 2>/dev/null) || engine=unknown
    line=$(jq -r '.line // empty' <<<"$out" 2>/dev/null) || line=""
    [ -n "$line" ] || line=$(ga_profile_line "$profile")
    hours="$GA_AMN_SUBS_HOURS_DEFAULT"
    type ga_subs_update_hours >/dev/null 2>&1 && hours=$(ga_subs_update_hours)
    packet_old=$((GA_AMN_MTU_STANDARD + GA_AMN_PACKET_OVERHEAD + s4_old))
    packet=$((GA_AMN_MTU_STANDARD + GA_AMN_PACKET_OVERHEAD + new))
    summary=$(tf amnezia_s4_fixed "$label" "$s4_old" "$new" "$packet_old" "$packet" "$GA_AMN_PACKET_BUDGET")
    if [ "$restarted" = true ]; then
        steps=$(_ga_amn_step "$steps" restart "$(t amnezia_s4_step_restart)")
    else
        steps=$(_ga_amn_step "$steps" start "$(t amnezia_s4_step_start)")
    fi
    for k in subscription page key app; do
        names=$(_ga_amn_names "$(jq -c --arg k "$k" '.[$k] // []' <<<"$aud")")
        [ -n "$names" ] || continue
        case "$k" in
            subscription) steps=$(_ga_amn_step "$steps" "$k" "$(tf amnezia_s4_step_sub "$names" "$(_ga_amn_within "$hours")")") ;;
            page)         steps=$(_ga_amn_step "$steps" "$k" "$(tf amnezia_s4_step_page "$names")") ;;
            key)          steps=$(_ga_amn_step "$steps" "$k" "$(tf amnezia_s4_step_key "$names")") ;;
            app)          steps=$(_ga_amn_step "$steps" "$k" "$(tf amnezia_s4_step_app "$names")") ;;
        esac
    done
    if [ "$(jq -r '[.subscription, .page, .key, .app] | add | length' <<<"$aud" 2>/dev/null)" = 0 ]; then
        steps=$(_ga_amn_step "$steps" nobody "$(t amnezia_s4_step_nobody)")
    fi
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "profile-fix-s4" \
        "$profile S4 ${s4_old}->${new} line=$line engine=$engine keyless=$keyless${confirm:+ adopted_confirm=$confirm}"
    log_success "$summary"
    jq -cn --arg p "$profile" --arg line "$line" --argjson s4o "$s4_old" --argjson s4 "$new" --argjson po "$packet_old" \
        --argjson pk "$packet" --argjson b "$GA_AMN_PACKET_BUDGET" --argjson r "$restarted" --arg e "$engine" \
        --argjson kl "$keyless" --argjson h "$hours" --argjson aud "$aud" --arg sum "$summary" --argjson steps "$steps" \
        '{profile: $p, line: $line, s4_old: $s4o, s4: $s4, packet_old: $po, packet: $pk, budget: $b, restarted: $r,
          engine: $e, keyless: $kl, update_hours: $h, subscription: $aud.subscription, page: $aud.page, key: $aud.key,
          app: $aud.app, summary: $sum, steps: $steps}'
}

# ga_amn_i1_universal <профиль> → stdout: имя профиля, если его I1 был ровно прежним умолчанием (LEGACY_DEFAULT_I1 в
# lib/awgkeys.py: <r 2><b 0x…>, его KeeneticOS 5.1 не принимает) и стал универсальным <b 0x{ID}{DNS-ответ}> со свежим
# ID (KEENETIC-I1). Тем же путём, что клиентский параметр через profile-set-param: config.json, строка «# I1 = …» в
# конфиге контейнера, копия в state/ — без рестарта (у сервера I1 закомментирован, маскировку он не меняет), без
# перевыпуска и без разрыва сессий. Выданные ключи с прежним I1 подключаются как прежде; в Keenetic их скачивают заново.
# Свой I1 человека и I2–I5 не трогаются, повтор ничего не меняет (I1 уже не прежнее умолчание). Docker не отвечает,
# контейнера нет, конфиг не прочитался, смена не прошла (и откатилась) — пропуск, rc 0: обновление, подхват и сверка из-за
# этого не падают. В конфиге контейнера пир, которого нет в users.json (приложение Amnezia добавило человека после
# подхвата, или там ключ пользователя другого профиля), — тоже пропуск: перезапись конфига его бы сняла, а шаг идёт без
# человека (_ga_amn_foreign_peer_any). Пропуск не молчаливый
# (KEENETIC-I1-R, R2): строка-предупреждение — профиль, причина и как довести (_ga_amn_i1u_skip), в журнал —
# profile-i1-universal-skipped. Повтор — при следующем обновлении кода (шаги миграции идут при смене версии или
# отпечатка кода) и после сверки с контейнером (import_reconcile … apply: люди приложения становятся своими). Вызывать
# под замком конфига (миграция, подхват и сверка уже под ним); запись в журнал — profile-i1-universal. Сообщения смены
# (в сухом прогоне — строки DRY) — только если она прошла.
ga_amn_i1_universal() {
    local profile="$1" params new state out container errf frc why code
    ga_profile_valid "$profile" && ga_profile_installed "$profile" || return 0
    params=$(ga_config_get ".profiles.$profile.params" 2>/dev/null | jq -c 'if type == "object" then . else {} end' 2>/dev/null)
    [ -n "$params" ] || return 0
    new=$(printf '%s' "$params" | ga_awgkeys i1-universal 2>/dev/null | head -n 1) || new=""
    [[ "$new" =~ ^\<b\ 0x[0-9a-f]+\>$ ]] || return 0
    container=$(ga_profile_field "$profile" container)
    ga_capture state docker_container_state "$container" 2>/dev/null
    case "$state" in
        running|exited) ;;
        missing) _ga_amn_i1u_skip "$profile" "$container" container_missing "$new"; return 0 ;;
        *)       _ga_amn_i1u_skip "$profile" "$container" docker_unreachable "$new"; return 0 ;;
    esac
    frc=0; _ga_amn_foreign_peer_any "$profile" "$container" || frc=$?
    case "$frc" in
        1) ;;
        0) _ga_amn_i1u_skip "$profile" "$container" foreign_peers "$new"; return 0 ;;
        3) _ga_amn_i1u_skip "$profile" "$container" taken_peer "$new"; return 0 ;;
        *) _ga_amn_i1u_skip "$profile" "$container" conf_unreadable "$new"; return 0 ;;
    esac
    if type ga_mktemp_secret >/dev/null 2>&1; then errf=$(ga_mktemp_secret gai1); else errf=$(mktemp); fi \
        || { _ga_amn_i1u_skip "$profile" "$container" apply_failed "$new" tmp_failed; return 0; }
    if ! GA_AMN_PARAM_QUIET=1 ga_capture out _amnezia_profile_set_param_locked "$profile" I1 "$new" 2>"$errf"; then
        # Сообщения неудачной смены (в них и прежнее, и новое значение) стираются вместе с файлом; строка о пропуске —
        # после, мимо файла: человек видит, что I1 не заменён, почему и что делать. Профиль не поднялся после
        # возврата (param_apply_failed) — сказать и это: тогда сначала поднять контейнер.
        if type ga_wipe_file >/dev/null 2>&1; then ga_wipe_file "$errf"; else rm -f "$errf"; fi
        code="${GA_ERR_CODE:-failed}"
        why=apply_failed; [ "$code" = param_apply_failed ] && why=apply_failed_down
        _ga_amn_i1u_skip "$profile" "$container" "$why" "$new" "$code"
        return 0
    fi
    cat "$errf" >&2
    if type ga_wipe_file >/dev/null 2>&1; then ga_wipe_file "$errf"; else rm -f "$errf"; fi
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "profile-i1-universal" "$profile I1 legacy-default->universal"
    printf '%s\n' "$profile"
}

# _ga_amn_i1u_skip <профиль> <контейнер> <причина> <универсальный I1> [код ошибки] — профиль с I1 прежнего умолчания
# пропущен (KEENETIC-I1-R, R2): одна строка-предупреждение на языке сервера — профиль, причина и что делать (заменить I1
# в «Изменить один параметр» на готовое значение — оно следующей строкой; контейнера нет или профиль не поднялся —
# сначала поднять контейнер, Docker не отвечает — когда заработает; пользователи приложения в контейнере — сначала
# сверка, после неё замена сама; ключ пользователя другого профиля — убрать его в приложении, затем заменить I1), и
# запись в журнал profile-i1-universal-skipped с профилем и причиной. Значений и секретов в журнале нет. Коды ошибок
# пропуска не остаются: обновление, подхват и сверка идут дальше как прошедшие.
_ga_amn_i1u_skip() {
    local profile="$1" container="$2" why="$3" new="$4" code="${5:-}" reason how
    case "$why" in
        foreign_peers)
            log_warning "$(tf amnezia_i1u_skip_foreign "$profile" "$(t amnezia_reconcile_where)")" ;;
        *)
            # Что делать — по причине (KEENETIC-I1-Q, Q3): контейнера нет или профиль не поднялся — сначала поднять
            # контейнер, Docker не отвечает — дождаться его; «замените I1» без этого невыполнимо.
            # Ключ пользователя другого профиля (taken_peer, KEENETIC-I1-N V1): сверка его не подхватит — совета «сверкой»
            # нет; сначала убрать ключ в приложении, иначе ручная замена I1 тоже снимет его из конфига профиля.
            case "$why" in
                docker_unreachable|apply_failed|apply_failed_down) reason=$(t "amnezia_i1u_why_$why") ;;
                taken_peer) reason=$(tf amnezia_i1u_why_taken_peer "$container" "${GA_AMN_FOREIGN_TAG:-?}") ;;
                *) reason=$(tf "amnezia_i1u_why_$why" "$container") ;;
            esac
            case "$why" in
                docker_unreachable)                  how=$(t amnezia_i1u_do_docker) ;;
                container_missing|apply_failed_down) how=$(tf amnezia_i1u_do_up "$container") ;;
                taken_peer)                          how=$(t amnezia_i1u_do_taken) ;;
                *)                                   how=$(t amnezia_i1u_do) ;;
            esac
            log_warning "$(tf amnezia_i1u_skip "$profile" "$reason" "$how")"
            # Готовое значение — отдельной строкой, мимо переноса (KEENETIC-I1-Q, Q1): ga_wrap рвёт текст по пробелам,
            # а внутри <b 0x…> пробел есть — на терминале значение уезжало на две строки, и целиком его не скопировать.
            printf '    %s\n' "$new" >&2 ;;
    esac
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "profile-i1-universal-skipped" "$profile reason=$why${code:+ code=$code}"
    GA_ERR_CODE=""; GA_ERR_MSG=""; GA_LAST_ERROR_CODE=""
    return 0
}

# _ga_amn_foreign_peer_any <профиль> <контейнер> — есть ли в конфиге контейнера пир, которого нет у профиля в users.json:
#   rc 0 — есть, и сверка его подхватит (человек приложения);
#   rc 3 — есть пир с ключом пользователя другого профиля (ga_import_peers_sort: taken) — годный, клиент с ним работает,
#          а сверка его не подхватит: один ключ на два профиля не делится. Начало его ключа (ga_peer_tag, только
#          base64) — в GA_AMN_FOREIGN_TAG. Важнее rc 0: после сверки он всё равно останется;
#   rc 2 — это не узнать (конфиг или users.json не читаются, разбор пиров не удался);
#   rc 1 — таких нет.
# Для шагов без человека: перезапись конфига (amnezia_write_server_conf) снимает такого пира — при rc 0, 2 и 3 шаг
# пропускают (KEENETIC-I1-N, V1: прежде taken чужим не считался, и миграция I1 при обновлении молча снимала рабочего
# клиента). Чужими не считаются только пиры, которых сверка не подхватит и с которыми клиент не подключится (N2): ключ
# не WireGuard или нет адреса IPv4 — совет «подхватите сверкой» для них неверен; перезапись снимет их с
# предупреждением amnezia_warn_foreign_peer_skipped (с причиной), как любая запись конфига.
_ga_amn_foreign_peer_any() {
    local profile="$1" container="$2" raw live known key users sorted n
    GA_AMN_FOREIGN_TAG=""
    raw=$(docker_read_file_any "$container" "$(ga_amn_conf_path "$profile")" 2>/dev/null) || return 2
    [ -n "$raw" ] || return 2
    ga_users_load users 2>/dev/null || { GA_LAST_ERROR_CODE=""; return 2; }
    if type ga_import_peers_sort >/dev/null 2>&1; then
        # Тот же разбор, что у сверки: PSK нужен, чтобы решить «ключ ли» (только в памяти, на stdin).
        live=$(printf '%s\n' "$raw" | ga_awgkeys parse-conf --with-secrets 2>/dev/null \
            | jq -c '[.peers[]? | {pubkey, ip: (.ip // ""), psk: (.psk // "")}]' 2>/dev/null) || return 2
        [ -n "$live" ] || return 2
        sorted=$(ga_import_peers_sort "$profile" "$live" "$users" 2>/dev/null) || return 2
        [ -n "$sorted" ] || return 2
        GA_AMN_FOREIGN_TAG=$(jq -r 'first(.[] | select(.skip == "taken") | .tag) // empty' <<<"$sorted" 2>/dev/null) || return 2
        [ -n "$GA_AMN_FOREIGN_TAG" ] && return 3
        n=$(jq -r '[.[] | select(.skip == "")] | length' <<<"$sorted" 2>/dev/null) || return 2
        [ "$n" = 0 ] && return 1
        return 0
    fi
    live=$(printf '%s\n' "$raw" | ga_amn_conf_pubkeys)
    known=$(jq -r --arg p "$profile" '.users[]? | .peers[$p]? // empty | .pubkey // empty' <<<"$users" 2>/dev/null) || return 2
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        grep -qxF -- "$key" <<<"$known" || return 0
    done <<<"$live"
    return 1
}

# ga_amn_i1_universal_all → stdout: профили, чей I1 прежнего умолчания стал универсальным (шаг миграции, KEENETIC-I1).
# Конфиг не прочитался — ничего, rc 0.
ga_amn_i1_universal_all() {
    local p list
    ga_profiles_load list 2>/dev/null || { GA_LAST_ERROR_CODE=""; return 0; }
    for p in $list; do ga_amn_i1_universal "$p"; done
    return 0
}

# ── Линии на сервере: нет 2.0, две одинаковые, «Переставить на 2.0» (DUP-LINE-01, решение владельца 15.10) ───────
# ga_amn_lines_check → JSON {no_20, shared: [{line, profiles[]}], missing[], reline: {profile, from, line, port, title}
# | null, text} — поле lines_check действия status (и в brief: только config.json, без Docker).
#   no_20    — профили стоят, а ни 2.0, ни 1.x среди них нет: старые версии приложений и роутеры Keenetic не
#              подключатся ни к одному (1.x они понимают — с awg1 предупреждать не о чем);
#   shared   — линии, которые держат два профиля и больше (их подписи — с портом, ga_profile_title);
#   missing  — линии пары 2.0 / 3.1, которых на сервере нет;
#   reline   — свой профиль goAmnezia (не подхваченный у приложения) повторяет линию другого, а второй линии пары
#              нет: его можно переставить на неё (amnezia_profile_reline). Свои обе — первым то место, чья это линия
#              по умолчанию (2.0 → awg2). Профиль приложения не предлагается никогда;
#   text     — то же словами на языке ядра.
ga_amn_lines_check() {
    local p l imp port obj='{}' js text="" title rp rl
    local -A sl=()
    ga_profile_lines_now sl
    for p in awg1 awg2 awg3; do
        [ -n "${sl[$p]:-}" ] || continue
        l="${sl[$p]}"
        imp=false
        [ "$(ga_config_get ".profiles.$p.imported" 2>/dev/null)" = true ] && imp=true
        port=$(ga_profile_field "$p" port 2>/dev/null)
        [[ "$port" =~ ^[0-9]{1,5}$ ]] || port=0
        obj=$(jq -c --arg p "$p" --arg l "$l" --argjson i "$imp" --argjson port "$((10#$port))" \
            '. + {($p): {line: $l, imported: $i, port: $port}}' <<<"$obj") || obj='{}'
    done
    js=$(jq -c '
        to_entries as $e | ($e | length) as $n | [$e[].value.line] as $lines
        | ([$lines | group_by(.)[] | select(length > 1) | .[0]]) as $dup
        | (if $n > 0 then [("2.0", "3.1") as $l | select(($lines | index($l)) == null) | $l] else [] end) as $miss
        | ([$miss[] as $m | (if $m == "2.0" then "3.1" else "2.0" end) as $o | select(($dup | index($o)) != null)
            | ($e | map(select(.value.line == $o and .value.imported != true and (.key == "awg2" or .key == "awg3")))
                  | sort_by(if (.key == "awg2") == ($m == "2.0") then 0 else 1 end)) as $c
            | select(($c | length) > 0)
            | {profile: $c[0].key, from: $o, line: $m, port: $c[0].value.port}] | first) as $re
        | {no_20: ($n > 0 and ([$lines[] | select(. == "2.0" or . == "1.0" or . == "1.5")] | length) == 0),
           shared: [$dup[] as $l | {line: $l, profiles: [$e[] | select(.value.line == $l) | .key]}],
           missing: $miss, reline: $re}' <<<"$obj" 2>/dev/null) || js=""
    [ -n "$js" ] || js='{"no_20":false,"shared":[],"missing":[],"reline":null}'
    [ "$(jq -r '.no_20' <<<"$js")" = true ] && text=$(t amnezia_lines_no20)
    rp=$(jq -r '.reline.profile // empty' <<<"$js" 2>/dev/null)
    if [ -n "$rp" ]; then
        rl=$(jq -r '.reline.line' <<<"$js")
        title=$(ga_profile_title "$rp")
        js=$(jq -c --arg t "$title" '.reline.title = $t' <<<"$js")
        text="${text:+$text }$(tf amnezia_lines_reline "$title" "AmneziaWG $rl")"
    fi
    # Переставлять нечего, а недостающая линия пары встанет на свободное место по «Установить» (ga_profile_auto_line):
    # куда идти — словами и полем install {profile, line} (находка WA-3 стенда 15.10: нигде не было сказано, как
    # поставить пропавшую 2.0). Свободное место называем по линии, которая встанет: «AmneziaWG 2.0 — не установлена».
    local ip il=""
    if [ -z "$rp" ]; then
        for ip in awg2 awg3; do
            ga_profile_installed "$ip" 2>/dev/null && continue
            il=$(ga_profile_auto_line "$ip" 2>/dev/null)
            jq -e --arg l "$il" '(.missing // []) | index($l) != null' <<<"$js" >/dev/null 2>&1 && break
            il=""
        done
    fi
    if [ -n "$il" ]; then
        js=$(jq -c --arg p "$ip" --arg l "$il" '. + {install: {profile: $p, line: $l}}' <<<"$js")
        [ -n "$text" ] && text="$text $(tf amnezia_lines_install "$(ga_profile_title "$ip")")"
    else
        js=$(jq -c '. + {install: null}' <<<"$js")
    fi
    jq -c --arg t "$text" '. + {text: $t}' <<<"$js"
}

# ga_amn_free_lines → JSON {место: линия} свободных мест: какая линия встанет по «Установить» (ga_profile_auto_line) —
# поле free_lines действия status; меню, панель и бот подписывают ею пункт заранее: «AmneziaWG 2.0 (awg3)».
ga_amn_free_lines() {
    local p out='{}'
    for p in awg1 awg2 awg3; do
        ga_profile_installed "$p" 2>/dev/null && continue
        out=$(jq -c --arg p "$p" --arg l "$(ga_profile_auto_line "$p")" '. + {($p): $l}' <<<"$out") || out='{}'
    done
    printf '%s' "$out"
}

# ── Сообщение после обновления: «Ошибка прошлых версий» (DUP-LINE-01, решение владельца 15.10) ─────────────────
# Прошлые версии ставили по «Установить» линию по месту, и рядом с подхваченной 3.1 приложения вставала вторая 3.1, а
# 2.0 на сервере не было. После обновления продукт сам находит такие серверы (миграция ставит флаг dupline_bug в
# config.json и одно событие dupline_bug для бота), а интерфейсы говорят об ошибке прямо и предлагают исправить —
# «Переставить на 2.0» (amnezia_profile_reline). Миграция сама ничего не переставляет.
#
# ga_amn_dupline_candidate → JSON {profile, from, line, port, title, users} или пусто: своя 3.1 повторяет подхваченную
# у приложения 3.1, а 2.0 на сервере нет (lines_check.reline с линией 2.0, и рядом есть подхваченный профиль той же
# линии); users — сколько пользователей с ключом на этом профиле (им ключ выдавать заново).
ga_amn_dupline_candidate() {
    local chk rp from users n
    chk=$(ga_amn_lines_check 2>/dev/null) || return 0
    rp=$(jq -r 'select(.reline.line == "2.0") | .reline.profile // empty' <<<"$chk" 2>/dev/null)
    [ -n "$rp" ] || return 0
    from=$(jq -r '.reline.from' <<<"$chk")
    local p app=0
    for p in awg1 awg2 awg3; do
        [ "$p" = "$rp" ] && continue
        ga_profile_installed "$p" 2>/dev/null || continue
        [ "$(ga_profile_line "$p" 2>/dev/null)" = "$from" ] || continue
        [ "$(ga_config_get ".profiles.$p.imported" 2>/dev/null)" = true ] && app=1
    done
    [ "$app" = 1 ] || return 0
    ga_users_load users 2>/dev/null || return 0
    n=$(jq -r --arg p "$rp" '[.users[]? | select((((.peers // {})[$p].privkey) // "") != "")] | length' <<<"$users" 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    jq -c --argjson n "$n" '.reline + {users: $n}' <<<"$chk"
}

# ga_amn_dupline_mark → флаг dupline_bug в config.json, если сервер в таком состоянии и флага ещё нет (шаг миграции
# _migrate_dupline; идемпотентно), и одно событие dupline_bug для бота. stdout — профиль, если флаг поставлен сейчас.
ga_amn_dupline_mark() {
    local c p cur
    c=$(ga_amn_dupline_candidate 2>/dev/null)
    [ -n "$c" ] || return 0
    p=$(jq -r '.profile' <<<"$c")
    cur=$(ga_config_get ".dupline_bug.profile" 2>/dev/null)
    # Флаг ставится один раз на сервер: исправленный (fixed_at) снова не ставим — если пользователь потом сам поставит
    # вторую 3.1, это его выбор, а не ошибка прошлых версий (обычное предупреждение lines_check об этом скажет).
    [ -n "$cur" ] && return 0
    ga_config_merge "$(jq -cn --arg p "$p" --arg at "$(ga_now)" \
        '{dupline_bug: {profile: $p, detected_at: $at, fixed_at: "", ssh_shown: false}}')" >/dev/null || return 1
    type ga_notify >/dev/null 2>&1 && ga_notify dupline_bug "$(jq -c --arg t "$(ga_amn_dupline_text "$c")" '. + {text: $t}' <<<"$c")"
    printf '%s\n' "$p"
}

# ga_amn_dupline_text <JSON кандидата> → текст сообщения на языке ядра (текст карты сервера, решение владельца 15.10):
# профиль — подписью, кому что делать — подписки сами, страница — открыть заново, ключ или файл вручную — заново.
ga_amn_dupline_text() {
    local n title
    n=$(jq -r '.users // 0' <<<"$1" 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    title=$(jq -r '.title // .profile // ""' <<<"$1" 2>/dev/null)
    if [ "$n" -gt 0 ]; then tf amnezia_dupline_text "$title" "$n"; else tf amnezia_dupline_text_nobody "$title"; fi
}

# ga_amn_dupline_fix_json → поле dupline_fix действия status (и в brief): {profile, from, line, port, title, users, text,
# detected_at} — флаг стоит, не исправлен, и сервер всё ещё в том состоянии; иначе null.
ga_amn_dupline_fix_json() {
    local fp c
    fp=$(ga_config_get ".dupline_bug.profile" 2>/dev/null)
    if [ -z "$fp" ] || [ -n "$(ga_config_get ".dupline_bug.fixed_at" 2>/dev/null)" ]; then printf 'null'; return 0; fi
    c=$(ga_amn_dupline_candidate 2>/dev/null)
    if [ -z "$c" ] || [ "$(jq -r '.profile' <<<"$c")" != "$fp" ]; then printf 'null'; return 0; fi
    jq -c --arg t "$(ga_amn_dupline_text "$c")" --arg at "$(ga_config_get ".dupline_bug.detected_at" 2>/dev/null)" \
        '. + {text: $t, detected_at: $at}' <<<"$c"
}

# _ga_amn_reline_aud_steps <JSON шагов> <JSON audience> <часы подписки> → шаги + у каждого пользователя его действие
# после перестановки: подписка обновится сама (только забиравшие all.yaml/all.txt приложением, R-1), страницу открыть заново,
# ключ выдать заново (ключ из приложения — тоже сюда). Общий для итога и окна согласия (ga_amn_reline_preview).
_ga_amn_reline_aud_steps() {
    local steps="$1" aud="$2" hours="$3" k names
    aud=$(jq -c '.key = ((.key // []) + (.app // [])) | .app = []' <<<"$aud" 2>/dev/null) || aud='{}'
    for k in subscription page key; do
        names=$(_ga_amn_names "$(jq -c --arg k "$k" '.[$k] // []' <<<"$aud")")
        [ -n "$names" ] || continue
        case "$k" in
            subscription) steps=$(_ga_amn_step "$steps" "$k" "$(tf amnezia_reline_step_sub "$names" "$(_ga_amn_within "$hours")")") ;;
            page)         steps=$(_ga_amn_step "$steps" "$k" "$(tf amnezia_reline_step_page "$names")") ;;
            key)          steps=$(_ga_amn_step "$steps" "$k" "$(tf amnezia_reline_step_key "$names")") ;;
        esac
    done
    printf '%s' "$steps"
}

# ga_amn_reline_preview <профиль> → JSON [{kind, text}] — кому что придётся сделать после «Переставить на 2.0», до
# неё: окно согласия в SSH, панели и боте (решение координатора 15.10) — теми же словами, что итог. Пользователей на
# профиле нет или их не прочитать — [].
ga_amn_reline_preview() {
    local aud hours="$GA_AMN_SUBS_HOURS_DEFAULT"
    aud=$(ga_amn_s4_audience "$1" 2>/dev/null) || aud=""
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$aud" || { printf '[]'; return 0; }
    type ga_subs_update_hours >/dev/null 2>&1 && hours=$(ga_subs_update_hours)
    _ga_amn_reline_aud_steps '[]' "$aud" "$hours"
}

# ga_amn_dupline_fixed — перестановка удалась: флаг снят (fixed_at), сообщение больше не показывается.
ga_amn_dupline_fixed() {
    [ -n "$(ga_config_get ".dupline_bug.profile" 2>/dev/null)" ] || return 0
    ga_config_merge "$(jq -cn --arg at "$(ga_now)" '{dupline_bug: {fixed_at: $at}}')" >/dev/null || true
}

# amnezia_profile_reline <профиль> [линия] → JSON — «Переставить на 2.0» (DUP-LINE-01, решение владельца 15.10): свой
# профиль goAmnezia, который повторяет линию другого (подхваченной 3.1 приложения), встаёт на вторую линию пары — ту,
# которой на сервере нет. Собрано из готовых действий: удаление профиля и установка с линией по просьбе на прежние
# порт, подсеть и пресет, затем ключи на новом профиле всем, у кого они были (users_add_peer). Страницы подключения
# при удалении не снимаются (GA_AMN_KEEP_PAGES): после установки они отдают новый ключ сами. Не встал с новой линией —
# прежняя линия на то же место и те же ключи людям, отказ reline_rolled_back; не встала и она — reline_failed со
# списком людей. Профиль, подхваченный у приложения Amnezia, — отказ reline_adopted до всякого изменения: его люди
# держат ключи только в приложении. Вторая линия уже есть или линия не повторяется — reline_needless (rc 2).
# Ответ: {profile, line_old, line, port, subnet, title, users[], failed[], subscription[], page[], key[], app[],
# update_hours, summary, steps[{kind, text}]} — как у profile-fix-s4: кому что сделать.
# Третий аргумент on (--keys-to-others=on, DUPLINE-KEYS-01) — ключ на новой линии и остальным пользователям, у кого
# его на профиле не было (пользователи приложения, новые), — тем же действием, на сервере: раньше их выдавала панель
# из браузера после «ОК», и закрытая вкладка оставляла их без ключей молча. В ответе тогда others[] (кому выдан) и
# others_failed[{name, code, message}] (у кого ошибка), в steps — шаги others и others_failed. Без него — как прежде.
amnezia_profile_reline() { ga_with_config_lock _amnezia_profile_reline_locked "$@"; }
_amnezia_profile_reline_locked() {
    local profile="$1" want="${2:-}" others="${3:-}" from to label port subnet preset users aud hours names k summary
    local steps='[]' n out irc=0 back_rc=0 errc errm
    local -a people=() ok=() failed=()
    ga_profile_check_installed "$profile" || return $?
    label=$(ga_amn_profile_label "$profile")
    if [ "$(ga_config_get ".profiles.$profile.imported" 2>/dev/null)" = true ]; then
        ga_err reline_adopted "$(tf amnezia_err_reline_adopted "$label")" 2
        return 2
    fi
    from=$(ga_profile_line "$profile")
    case "$profile:$from" in
        awg2:2.0|awg3:2.0) to=3.1 ;;
        awg2:3.1|awg3:3.1) to=2.0 ;;
        *) ga_err reline_needless "$(tf amnezia_err_reline_needless "$label" "-")" 2; return 2 ;;
    esac
    if [ -n "$want" ] && [ "$want" != "$to" ]; then
        ga_err invalid_line "$(tf amnezia_err_reline_line "$label" "$to")" 2
        return 2
    fi
    local -A sl=()
    ga_profile_lines_now sl
    for k in "${!sl[@]}"; do
        if [ "${sl[$k]}" = "$to" ]; then
            ga_err reline_needless "$(tf amnezia_err_reline_needless "$label" "$to")" 2
            return 2
        fi
    done
    if ! ga_profile_line_shared "$profile"; then
        ga_err reline_needless "$(tf amnezia_err_reline_needless "$label" "$to")" 2
        return 2
    fi
    port=$(ga_profile_field "$profile" port)
    subnet=$(ga_config_get ".profiles.$profile.subnet" 2>/dev/null)
    [ "$subnet" = null ] && subnet=""
    preset=$(ga_config_get ".profiles.$profile.preset" 2>/dev/null)
    [[ "$preset" =~ ^(default|quic|router)$ ]] || preset=default
    ga_users_load users || return 1
    mapfile -t people < <(jq -r --arg p "$profile" '.users[]? | select(((.peers // {})[$p]) != null) | .name' <<<"$users" 2>/dev/null)
    # Кому что делать — до перестановки: список людей тот же, а после удаления профиля его уже не прочитать.
    aud=$(ga_amn_s4_audience "$profile") || { ga_err users_corrupt "$(t users_err_corrupt)"; return 1; }
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$aud" || aud='{"subscription":[],"page":[],"key":[],"app":[]}'
    # 0. Всё, что можно проверить, — до разрушительного удаления (находка проверки 15.10): место на диске, демон Docker,
    # параметры новой линии собираются. Порт и подсеть — прежние, их освобождает само удаление.
    ga_amn_disk_ok || return 1
    local cst
    ga_capture cst docker_container_state "$(ga_profile_field "$profile" container)"
    ga_amn_docker_up "$cst" || return 1
    local tparams
    tparams=$(ga_awgkeys gen-params --line "$to" --preset "$preset" 2>/dev/null) || tparams=""
    if [ -z "$tparams" ] || ! ga_amn_validate_params "$to" "$tparams" >/dev/null 2>&1; then
        ga_err params_failed "$(tf amnezia_err_params "$to" "$preset")"
        return 1
    fi
    # 1. Удаление — тем же действием, что «Удалить» (контейнер, ключи сервера, пиры людей), страницы — оставляем.
    GA_AMN_KEEP_PAGES=1 _amnezia_profile_remove_locked "$profile" || return $?
    # 2. Установка на прежнее место: линия по просьбе, порт, подсеть и пресет — прежние.
    GA_ERR_CODE=""; GA_ERR_MSG=""
    _amnezia_profile_install_locked "$profile" "$port" "$preset" "$subnet" "$to" >/dev/null || irc=$?
    if [ "$irc" -ne 0 ]; then
        errc="${GA_ERR_CODE:-install_failed}"; errm="${GA_ERR_MSG:-$(t amnezia_reline_cause_log)}"
        GA_ERR_CODE=""; GA_ERR_MSG=""
        # Выбор «ключ остальным» при отказе не выполняется (шаг 4 после отказа не идёт) — так и сказать (R-5).
        local oth_txt=""
        [ "$others" = on ] && oth_txt=" $(t amnezia_reline_others_not_issued)"
        local ln="$to"
        if ! ga_profile_installed "$profile"; then
            # Новая линия не записалась — убираем остатки контейнера и возвращаем прежнюю на то же место.
            docker_rm "$(ga_profile_default "$profile" container)" >/dev/null 2>&1 || true
            ln="$from"
            _amnezia_profile_install_locked "$profile" "$port" "$preset" "$subnet" "$from" >/dev/null || back_rc=$?
        fi
        if ! ga_profile_installed "$profile"; then
            # Не встала и прежняя: профиля нет — «Установить» в «Протоколах» сработает, людям — ключи заново.
            names=$(_ga_amn_names "$(printf '%s\n' "${people[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')")
            ga_audit "${GOAMNEZIA_WHO:-ssh}" "profile-reline" "$profile $from->$to failed=$errc rollback=failed"
            ga_err reline_failed "$(tf amnezia_err_reline_failed "$label" "$to" "$errm" "${names:--}")${oth_txt}"
            return 1
        fi
        # Профиль записан (с новой линией, если сорвался только подъём контейнера, или с прежней — откат): ключи тем,
        # у кого они были, — сразу. Выдача применяет ключ к контейнеру и на лежащем откатывается (находка проверки 15.10),
        # поэтому кому выдан, а кому нет — по коду users_add_peer, и словами: «выдайте после подъёма».
        local -a got=() todo=()
        for n in "${people[@]}"; do
            if users_add_peer "$n" "$profile" >/dev/null 2>&1; then got+=("$n"); else todo+=("$n"); fi
        done
        local keys_txt="" gotj todoj down=0 head
        gotj=$(printf '%s\n' "${got[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')
        todoj=$(printf '%s\n' "${todo[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')
        { [ "$ln" = "$to" ] || [ "$back_rc" -ne 0 ]; } && down=1
        if [ "${#got[@]}" -gt 0 ]; then
            # Ключи у них новые (ключ сервера сменился): кому что делать — как после удачной перестановки.
            keys_txt="$(tf amnezia_reline_keys_got "$(_ga_amn_names "$gotj")") $(t amnezia_reline_keys_redo)"
        fi
        if [ "${#todo[@]}" -gt 0 ]; then
            if [ "$down" = 1 ]; then
                keys_txt="${keys_txt:+$keys_txt }$(tf amnezia_reline_keys_todo "$(_ga_amn_names "$todoj")")"
            else
                keys_txt="${keys_txt:+$keys_txt }$(tf amnezia_reline_keys_todo_card "$(_ga_amn_names "$todoj")")"
            fi
        fi
        if [ "$down" = 1 ]; then
            # Записан, но не поднялся: новая линия — или прежняя, вернувшаяся откатом. Поднять из копии состояния.
            ga_audit "${GOAMNEZIA_WHO:-ssh}" "profile-reline" "$profile $from->$to failed=$errc state=installed_down line=$ln keys=${#got[@]} todo=${#todo[@]}"
            if [ "$ln" = "$to" ]; then
                ga_amn_dupline_fixed
                head=$(tf amnezia_err_reline_partial "$label" "$ln" "$errm")
            else
                head=$(tf amnezia_err_reline_back_down "$label" "$to" "$errm" "$from")
            fi
            ga_err reline_partial "${head}${keys_txt:+ $keys_txt}${oth_txt}"
        else
            ga_audit "${GOAMNEZIA_WHO:-ssh}" "profile-reline" "$profile $from->$to failed=$errc rollback=done keys=${#got[@]} todo=${#todo[@]}"
            ga_err reline_rolled_back "$(tf amnezia_err_reline_rolled_back "$label" "$to" "$errm" "$from")${keys_txt:+ $keys_txt}${oth_txt}"
        fi
        return 1
    fi
    # 3. Ключи на новом профиле — тем, у кого они были (выдача ключа: пир выключенного человека создаётся выключенным).
    for n in "${people[@]}"; do
        if users_add_peer "$n" "$profile" >/dev/null 2>&1; then ok+=("$n"); else failed+=("$n"); fi
    done
    # 4. Остальным (--keys-to-others=on) — у кого ключа на этом профиле не было и до перестановки: тем же действием,
    # чтобы выдача не зависела от открытой вкладки панели или ответа в боте. Кому не вышло — имя, код и слова ошибки.
    local -a oth=() rest=()
    local othj='[]' othfj='[]' u2 pj
    if [ "$others" = on ]; then
        pj=$(printf '%s\n' "${people[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')
        if ga_users_load u2 2>/dev/null; then
            # Порядок — как в списках панели и бота: admin первым, остальные по имени (RV-4: в окне согласия и в итоге
            # «остальные» шли в разном порядке).
            mapfile -t rest < <(jq -r --arg p "$profile" --argjson had "$pj" \
                '[.users[]? | select(((.peers // {})[$p]) == null) | .name | select(. as $n | $had | index($n) | not)]
                 | sort_by([(. != "admin"), ascii_downcase]) | .[]' <<<"$u2" 2>/dev/null)
        fi
        for n in "${rest[@]}"; do
            [ -n "$n" ] || continue
            GA_ERR_CODE=""; GA_ERR_MSG=""
            if users_add_peer "$n" "$profile" >/dev/null 2>&1; then
                oth+=("$n")
            else
                othfj=$(jq -c --arg n "$n" --arg c "${GA_ERR_CODE:-add_peer_failed}" --arg m "${GA_ERR_MSG:-}" \
                    '. + [{name: $n, code: $c, message: $m}]' <<<"$othfj")
            fi
        done
        GA_ERR_CODE=""; GA_ERR_MSG=""
        othj=$(printf '%s\n' "${oth[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')
    fi
    hours="$GA_AMN_SUBS_HOURS_DEFAULT"
    type ga_subs_update_hours >/dev/null 2>&1 && hours=$(ga_subs_update_hours)
    summary=$(tf amnezia_reline_done "$label" "$to" "$port" "${subnet:-$(ga_profile_field "$profile" subnet)}")
    local okj failj
    okj=$(printf '%s\n' "${ok[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')
    failj=$(printf '%s\n' "${failed[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')
    [ "${#ok[@]}" -gt 0 ] && steps=$(_ga_amn_step "$steps" users "$(tf amnezia_reline_step_users "$(_ga_amn_names "$okj")")")
    [ "${#failed[@]}" -gt 0 ] && steps=$(_ga_amn_step "$steps" failed "$(tf amnezia_reline_step_failed "$(_ga_amn_names "$failj")")")
    # Ключ из приложения у своего профиля не бывает, но если был — ему тоже выдать заново: он в «key».
    aud=$(jq -c '.key = (.key + .app) | .app = []' <<<"$aud")
    steps=$(_ga_amn_reline_aud_steps "$steps" "$aud" "$hours")
    local nothf
    nothf=$(jq -r 'length' <<<"$othfj")
    [ "${#oth[@]}" -gt 0 ] && steps=$(_ga_amn_step "$steps" others "$(tf amnezia_reline_step_others "$to" "$(_ga_amn_names "$othj")")")
    if [ "$nothf" -gt 0 ]; then
        # Причины — по группам (R-5): одна на всех — она; разные — «причина (имена)» через «; », не больше пяти,
        # остальное — в журнале. Несколько имён — во множественном числе.
        local fm="" fgroups nfg fgi fnames fmsg
        fgroups=$(jq -c --arg d "$(t amnezia_reline_cause_log)" '
            [.[] | {n: .name, m: ((.message // "") | rtrimstr(".") | if . == "" then $d else . end)}]
            | reduce .[] as $x ([]; if any(.[]; .m == $x.m) then map(if .m == $x.m then .n += [$x.n] else . end)
                                     else . + [{m: $x.m, n: [$x.n]}] end)' <<<"$othfj")
        nfg=$(jq -r 'length' <<<"$fgroups")
        if [ "$nfg" -le 1 ]; then
            fm=$(jq -r '.[0].m' <<<"$fgroups")
        else
            for ((fgi = 0; fgi < nfg && fgi < 5; fgi++)); do
                fm+="${fm:+; }$(jq -r ".[$fgi].m" <<<"$fgroups") ($(_ga_amn_names "$(jq -c ".[$fgi].n" <<<"$fgroups")"))"
            done
            [ "$nfg" -gt 5 ] && fm+="; $(t amnezia_reline_cause_log)"
        fi
        fnames=$(_ga_amn_names "$(jq -c 'map(.name)' <<<"$othfj")")
        if [ "$nfg" -gt 1 ] && [ "$nfg" -le 5 ]; then
            # Каждая причина уже со своими именами — общий список в скобках их только повторял (NB2-3). Больше пяти
            # причин — общий список остаётся: имена за пятой группой иначе не названы нигде.
            fmsg=$(tf amnezia_reline_step_others_failed_groups "$to" "$fm")
        elif [ "$nothf" -gt 1 ]; then
            fmsg=$(tf amnezia_reline_step_others_failed_many "$to" "$fnames" "$fm")
        else
            fmsg=$(tf amnezia_reline_step_others_failed "$to" "$fnames" "$fm")
        fi
        steps=$(_ga_amn_step "$steps" others_failed "$fmsg")
    fi
    [ "${#people[@]}" -eq 0 ] && [ "${#oth[@]}" -eq 0 ] && steps=$(_ga_amn_step "$steps" nobody "$(t amnezia_reline_step_nobody)")
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "profile-reline" "$profile $from->$to port=$port users=${#ok[@]} failed=${#failed[@]}$([ "$others" = on ] && printf " others=%s failed_others=%s" "${#oth[@]}" "$nothf")"
    # Сообщение «Ошибка прошлых версий» (флаг миграции dupline_bug) больше не нужно.
    ga_amn_dupline_fixed
    log_success "$summary"
    out=$(jq -cn --arg p "$profile" --arg lo "$from" --arg l "$to" --argjson port "$((10#$port))" \
        --arg sub "$(ga_profile_field "$profile" subnet)" --arg title "$(ga_amn_profile_label "$profile")" \
        --argjson users "$okj" --argjson failed "$failj" --argjson aud "$aud" --argjson h "$hours" \
        --arg sum "$summary" --argjson steps "$steps" \
        '{profile: $p, line_old: $lo, line: $l, port: $port, subnet: $sub, title: $title, users: $users, failed: $failed,
          subscription: $aud.subscription, page: $aud.page, key: $aud.key, app: [], update_hours: $h,
          summary: $sum, steps: $steps}')
    [ "$others" = on ] && out=$(jq -c --argjson o "$othj" --argjson f "$othfj" '. + {others: $o, others_failed: $f}' <<<"$out")
    printf '%s\n' "$out"
}

# ga_amn_mtu_check <профиль> <mtu> → JSON {mtu, s4, packet, warnings[]} (lib/awgkeys.py mtu-check): что такой MTU сломает
# наверняка — path (MTU выше 1280 и пакет данных MTU + 80 + S4 больше 1440: на части хостеров и сетей скачивание
# встанет, L-02а). Подъём до 1320 при S4 ≤ 40 — без предупреждений (решение владельца 08.10); ниже 1280 MTU не
# принимается вовсе (ga_amn_mtu_settable). Окно MTU в SSH, ответ profile-mtu.
ga_amn_mtu_check() {
    local params
    params=$(ga_config_get ".profiles.$1.params" 2>/dev/null | jq -c 'if type == "object" then . else {} end' 2>/dev/null)
    [ -n "$params" ] || params='{}'
    printf '%s' "$params" | ga_awgkeys mtu-check --mtu "$2"
}

# ga_amn_mtu_warn_lines <JSON ga_amn_mtu_check> → по строке слов на каждое предупреждение (пусто — сказать нечего).
ga_amn_mtu_warn_lines() {
    local js="${1:-}" code packet
    packet=$(jq -r '.packet // empty' <<<"$js" 2>/dev/null)
    while IFS= read -r code; do
        case "$code" in
            path) tf amnezia_mtu_warn_path "$packet"; echo ;;
        esac
    done < <(jq -r '.warnings[]?' <<<"$js" 2>/dev/null)
    return 0
}

# ga_amn_subnet_legacy_msg <профиль> <интерфейс> — отказ «подсеть не сменить» для подхваченного legacy-профиля.
# Пересекается его подсеть с другим профилем — в отказе выход (SUBNET-01): какой профиль перенести и на какую
# свободную подсеть (ga_amn_subnet_overlaps); иначе прежний совет — поставить профиль заново.
ga_amn_subnet_legacy_msg() {
    local profile="$1" iface="$2" js mv to free sub
    js=$(ga_amn_subnet_overlaps 2>/dev/null) || js='[]'
    mv=$(jq -c --arg p "$profile" 'first(.[]? | select(.profile == $p)) // empty' <<<"$js" 2>/dev/null) || mv=""
    to=$(jq -r '.move.profile // empty' <<<"$mv" 2>/dev/null)
    free=$(jq -r '.move.subnet // empty' <<<"$mv" 2>/dev/null)
    sub=$(jq -r '.subnet // empty' <<<"$mv" 2>/dev/null)
    if [ -n "$to" ] && [ -n "$free" ]; then
        local who
        who=$(ga_amn_profile_label "$to")
        tf amnezia_err_subnet_legacy_overlap "$profile" "$iface" "${sub:-?}" "$who" "$free" "$who"
    else
        tf amnezia_err_subnet_legacy "$profile" "$iface"
    fi
}

# amnezia_profile_set_subnet <профиль> <cidr> [согласие] — смена подсети. Адрес интерфейса
# и правила iptables в start.sh заданы подсетью, живому контейнеру их не
# поменять — пересоздаём его из state/ тем же путём, что при смене порта.
# Пиры перенумеровываются по порядку (users_renumber_profile), ключи прежние,
# но адрес в каждом конфиге другой — конфиги надо раздать заново.
# Третий аргумент — согласие на смену у профиля с людьми без ключа на сервере (подхвачены у приложения Amnezia):
# имя того же профиля ещё раз, как у смены порта (ACC-2). Их ключи с прежним адресом после перенумерации не
# пройдут, а переслать новые нечем — без согласия отказ adopted_keyless до всякого изменения. Это и выход из
# пересечения подсетей (SUBNET-01), когда переносить приходится подхваченный у приложения amnezia-awg2.
# stdout: JSON {profile, subnet, old_subnet, renumbered, peers: [{name, old_ip, ip}]}.
# _amnezia_subnet_undo <профиль> <прежняя подсеть> <users.json до перенумерации> — вернуть данные
# сорвавшейся смены подсети; код и слова исходного отказа сохраняются.
_amnezia_subnet_undo() {
    local profile="$1" old="$2" users="$3" code="${GA_ERR_CODE:-}" msg="${GA_ERR_MSG:-}"
    [ -n "$users" ] && { printf '%s' "$users" | ga_users_write >/dev/null 2>&1 || true; }
    ga_config_merge "$(jq -cn --arg p "$profile" --arg s "$old" '{profiles: {($p): {subnet: $s}}}')" >/dev/null 2>&1 || true
    GA_ERR_CODE="$code"; GA_ERR_MSG="$msg"
}
amnezia_profile_set_subnet() { ga_with_config_lock _amnezia_profile_set_subnet_locked "$@"; }
_amnezia_profile_set_subnet_locked() {
    local profile="$1" cidr="${2:-}" confirm="${3:-}" container old port peers renum='[]' n=0 state users iface keyless
    ga_profile_check_installed "$profile" || return $?
    # Подхваченный legacy-контейнер amnezia-awg живёт на wg0 со своим start.sh, где подсеть зашита в правила
    # NAT. Пересоздание контейнера пишет наш start.sh — он знает только awg0, и профиль не поднимался вовсе,
    # а отката не было: все пользователи профиля без связи. Отказ — до всякого изменения, а если его подсеть
    # с кем-то пересекается — с выходом: кого перенести и куда (SUBNET-01).
    iface=$(ga_amn_iface "$profile")
    if [ "$iface" != "$GA_AWG_IFACE" ]; then
        ga_err subnet_legacy "$(ga_amn_subnet_legacy_msg "$profile" "$iface")" 2
        return 2
    fi
    container=$(ga_profile_field "$profile" container)
    # Прежняя подсеть — записанная, а без записи — та, на которой профиль работает (копия конфига в state/): по ней
    # правится start.sh, и умолчание места (10.8.2.0/24 у awg2) у подхваченного с 10.8.1.0/24 там бы не нашлось.
    old=$(ga_config_get ".profiles.$profile.subnet" 2>/dev/null)
    { [ -n "$old" ] && [ "$old" != null ]; } || old=$(ga_amn_state_subnet "$profile" 2>/dev/null) || old=""
    [ -n "$old" ] || old=$(ga_profile_default "$profile" subnet)
    port=$(ga_profile_field "$profile" port)
    ga_amn_subnet_check "$profile" "$cidr" || return $?
    if [ "$old" = "$cidr" ]; then
        ga_err invalid_subnet "$(tf amnezia_err_same_subnet "$cidr")" 2
        return 2
    fi
    # Люди приложения Amnezia без ключа на сервере: их ключ с прежним адресом после перенумерации не пройдёт,
    # а переслать новый нечем — молча такую смену не делаем (как перенос порта, ACC-2). users.json не читается —
    # не знаем, кого отрежем, и не трогаем ничего.
    keyless=$(ga_profile_keyless_count "$profile") || { ga_err users_corrupt "$(t users_err_corrupt)"; return 1; }
    if [ "$keyless" -gt 0 ] && [ "$confirm" != "$profile" ]; then
        ga_err adopted_keyless "$(tf amnezia_err_subnet_adopted "$profile" "$keyless" "$old" "$cidr" "$profile")" 2
        return 2
    fi
    # Свежая копия состояния до сноса контейнера; без ключа сервера в state/
    # пересоздавать не из чего.
    ga_capture state docker_container_state "$container"
    ga_amn_docker_up "$state" || return 1
    if [ "$state" = "running" ]; then
        amnezia_state_sync "$profile" || return 1
    fi
    if [ ! -f "$STATE_DIR/$container/$GA_AWG_SERVER_PRIV" ]; then
        ga_err state_missing "$(tf amnezia_err_state_missing "$container")" 3
        return 3
    fi
    # Сначала данные (пиры, потом подсеть в config.json), потом контейнер:
    # сорвавшаяся перенумерация оставляет контейнер нетронутым.
    ga_users_load users || return 1
    peers=$(jq --arg p "$profile" '[.users[]? | select(.peers[$p] != null)] | length' <<<"$users" 2>/dev/null)
    [[ "$peers" =~ ^[0-9]+$ ]] || peers=0
    if declare -F users_renumber_profile >/dev/null; then
        ga_capture renum users_renumber_profile "$profile" "$cidr" || return 1
        n=$(jq -r 'length' <<<"$renum" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] || n=0
    elif [ "$peers" -gt 0 ]; then
        ga_err module_missing "$(tf amnezia_err_users_module "$profile")" 3
        return 3
    fi
    ga_config_merge "$(jq -cn --arg p "$profile" --arg s "$cidr" '{profiles: {($p): {subnet: $s}}}')" \
        || { ga_err config_write_failed "$(t amnezia_err_config)"; return 1; }
    # Контейнер не снялся — данные назад, контейнер цел (находка SR-34).
    ga_amn_container_rm "$profile" || { _amnezia_subnet_undo "$profile" "$old" "$users"; return 1; }
    if ! docker_run_awg "$container" "$port" "$container"; then
        # Контейнер снят, а на новой подсети не поднялся. Копия состояния (state/awg0.conf, start.sh) ещё
        # прежняя: возвращаем пользователей и подсеть и поднимаем контейнер как был. Раньше данные
        # оставались новыми, копия старой, повтор той же подсети отказывал «уже использует», а «Поднять
        # заново» с «успехом» возвращало старую подсеть — новые ключи не проходили AllowedIPs (SR-34).
        _amnezia_subnet_undo "$profile" "$old" "$users"
        if docker_run_awg "$container" "$port" "$container" && amnezia_state_restore "$profile" \
           && ga_amn_wait_up "$profile"; then
            amnezia_state_sync "$profile"
            ga_err subnet_change_failed "$(tf amnezia_err_subnet_kept "$cidr" "$profile" "$old")"
        else
            ga_err subnet_change_failed "$(tf amnezia_err_subnet_down "$profile" "$container")"
        fi
        return 1
    fi
    amnezia_write_server_conf "$profile" || return 1
    amnezia_clientstable_write "$profile" || return 1
    ga_amn_update_start_sh_subnet "$profile" "$old" "$cidr" || return 1
    amnezia_state_restore "$profile" || return 1
    ga_amn_wait_up "$profile" || return 1
    amnezia_state_sync "$profile"
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "profile-subnet" "$profile ${old}->${cidr} peers=$n"
    log_success "$(tf amnezia_subnet_changed "$profile" "$cidr" "$n")"
    jq -cn --arg p "$profile" --arg s "$cidr" --arg old "$old" --argjson n "$n" --argjson peers "$renum" \
        '{profile: $p, subnet: $s, old_subnet: $old, renumbered: $n, peers: $peers}'
}

# ── Конфиг сервера, syncconf, awg show ────────────────────────────────────────

# awg0.conf из config.json (параметры, порт, подсеть) + users.json (активные
# пиры включённых пользователей) через awgkeys.py server-conf. Приватный ключ
# сервера — из state/. Пишем и в контейнер, и в state/ — второе делает dry-run
# и восстановление независимыми от docker cp. Второй аргумент state — только копия
# в state/ (контейнера нет: его поднимут из копии).
#
# MTU профиля — строкой MTU в [Interface] (жалоба 29.09.2026: подхваченный конфиг с MTU = 1360 после первой же
# пересборки остался без строки, интерфейс работал с 1420, а настройки показывали 1360) и сразу на живой
# интерфейс (ga_amn_mtu_live). MTU в настройках нет (подхват у приложения без строки MTU) — строку живого конфига
# сохраняем как есть: её вписал человек или сосед, и пересборка стирать её не вправе. Свой MTU goWARP PRO держит
# в /opt/warp/warp.conf (интерфейс warp, 1280) — этот файл продукт только переносит, не пишет.
amnezia_write_server_conf() {
    local profile="$1" only="${2:-}" container sdir line params port subnet priv peers input conf users mtu live=""
    ga_profile_check_installed "$profile" || return $?
    # Пиров читаем ДО всякой записи и отказываем на нечитаемом users.json.
    # Раньше здесь стоял конвейер в подстановке команды: код возврата он
    # съедал, а пустой ответ превращался в peers='[]'. Цена: смена любого
    # параметра, порта, подсети, перевыпуск, обновление ядра и восстановление
    # состояния собирали конфиг БЕЗ ЕДИНОГО ПИРА и уезжали с ним в контейнер —
    # все пользователи профиля мгновенно теряли связь, а занятые адреса
    # переставали быть занятыми.
    ga_users_load users || return 1
    container=$(ga_profile_field "$profile" container)
    sdir="$STATE_DIR/$container"
    if [ ! -f "$sdir/$GA_AWG_SERVER_PRIV" ]; then
        ga_err state_missing "$(tf amnezia_err_state_missing "$container")" 3
        return 3
    fi
    priv=$(<"$sdir/$GA_AWG_SERVER_PRIV")
    # Живой конфиг контейнера — один раз на запись: по нему MTU без настройки, чужие пиры и смена маскировки
    # [Interface] (KMOD-01: на модуле ядра её применяет только рестарт, см. amnezia_syncconf).
    [ "$only" = state ] || live=$(docker_read_file "$container" "$(ga_amn_conf_path "$profile")" 2>/dev/null) || live=""
    line=$(ga_profile_line "$profile")
    port=$(ga_profile_field "$profile" port)
    subnet=$(ga_profile_field "$profile" subnet)
    params=$(ga_config_get ".profiles.$profile.params" | jq -c . 2>/dev/null)
    [ -n "$params" ] || params='{}'
    mtu=$(jq -r '.MTU // "" | tostring' <<<"$params" 2>/dev/null)
    # GA_AMN_MTU_DROP=1 — MTU убрали из настроек сами (profile-set-param MTU ""): строку не сохраняем.
    if [ -z "$mtu" ] && [ "${GA_AMN_MTU_DROP:-0}" != 1 ]; then
        mtu=$(ga_amn_conf_mtu "$profile" "$container" "$live")
        [ -n "$mtu" ] && params=$(jq -c --arg m "$mtu" '.MTU = $m' <<<"$params")
    fi
    peers=$(jq -c --arg p "$profile" \
        '[.users[]? | select(.enabled == true) | .peers[$p]? // empty | select(.active == true)
          | {pubkey: .pubkey, psk: .psk, ip: .ip}]' <<<"$users" 2>/dev/null)
    # Здесь пусто означает только «включённых пиров нет»: битый файл отсеян выше.
    [ -n "$peers" ] || peers='[]'
    # Приватный ключ сервера — окружением, пиры с PSK — через stdin, а не аргументами jq: argv любого
    # процесса виден каждому локальному пользователю в /proc/*/cmdline (находка SR-17). Через stdin пиры
    # не упираются и в предел 128 КБ на один аргумент (как в SR-09).
    input=$(printf '%s' "$peers" | GA_S_PRIV="$priv" jq -c --argjson params "$params" --arg subnet "$subnet" \
        --argjson port "$port" \
        '{params: $params, server: {privkey: $ENV.GA_S_PRIV, subnet: $subnet, port: $port}, peers: .}') || return 1
    conf=$(printf '%s' "$input" | ga_awgkeys server-conf --line "$line") || {
        ga_err conf_failed "$(tf amnezia_err_server_conf "$profile")"; return 1; }
    if [ -z "$conf" ]; then
        ga_err conf_failed "$(tf amnezia_err_server_conf "$profile")"
        return 1
    fi
    [ "$only" = state ] || ga_amn_warn_foreign_peers "$profile" "$container" "$live"
    ga_amn_state_init "$sdir" || return 1
    printf '%s\n' "$conf" | ga_amn_write_secret "$sdir/awg0.conf" || return 1
    [ "$only" = state ] && return 0
    printf '%s\n' "$conf" | docker_write_file "$container" "$(ga_amn_conf_path "$profile")" 0600 || return 1
    ga_amn_mask_diff "$live" "$conf" && ga_amn_mask_mark "$container"
    ga_amn_mtu_live "$profile" "$(sed -n 's/^MTU = //p' <<<"$conf" | head -n 1)"
    return 0
}

# ga_amn_conf_mtu <профиль> <контейнер> [живой конфиг] → MTU из [Interface] живого конфига профиля (а нет контейнера —
# из копии в state/); пусто — строки нет. Третий аргумент — уже прочитанный живой конфиг (не читать его второй раз).
ga_amn_conf_mtu() {
    local raw v
    if [ $# -ge 3 ]; then raw="$3"; else raw=$(docker_read_file "$2" "$(ga_amn_conf_path "$1")" 2>/dev/null) || raw=""; fi
    [ -n "$raw" ] || raw=$(cat "$(ga_amn_state_conf "$1")" 2>/dev/null) || raw=""
    v=$(printf '%s\n' "$raw" | awk '
        /^[[:space:]]*\[/ { sec = tolower($0); gsub(/[^a-z]/, "", sec); next }
        sec == "interface" && /^[[:space:]]*MTU[[:space:]]*=/ { v = substr($0, index($0, "=") + 1); gsub(/[[:space:]]/, "", v); print v; exit }')
    [[ "$v" =~ ^[0-9]{3,5}$ ]] && printf '%s' "$v"
    return 0
}

# ga_amn_mtu_live <профиль> <mtu> — MTU на живой интерфейс профиля (ip link set), если он другой. awg-quick берёт
# строку MTU только при подъёме, а перезапуск ради MTU рвал бы связь всем на профиле; смена MTU на лету сессий не
# рвёт. Интерфейса ещё нет (контейнер только что создан, не работает) — нечего менять: поднимется уже с ним.
ga_amn_mtu_live() {
    local profile="$1" mtu="${2:-}" container iface cmd
    [[ "$mtu" =~ ^[0-9]{3,5}$ ]] || return 0
    container=$(ga_profile_field "$profile" container)
    iface=$(ga_amn_iface "$profile")
    [[ "$iface" =~ ^(awg|wg)[0-9]$ ]] || return 0
    cmd="[ -e /sys/class/net/$iface ] || exit 0; [ \"\$(cat /sys/class/net/$iface/mtu)\" = $mtu ] || ip link set dev $iface mtu $mtu"
    # MSS идёт за MTU: правило из туннеля задано числом (MTU − 40), прежнее значение снимается.
    cmd+=$'\n'"$(ga_amn_mss_cmd "$iface")"
    if ga_dry; then docker_exec "$container" "$cmd"; return 0; fi
    if ! docker_exec "$container" "$cmd" >/dev/null 2>&1 && [ "$(docker_container_state "$container")" = running ]; then
        log_warning "$(tf amnezia_warn_mtu_live "$profile" "$mtu")"
    fi
    return 0
}

# ga_amn_mtu_sync_all → stdout: «профиль=MTU» у профилей, чей конфиг сервера приведён к MTU настроек (миграция на
# версию с MTU в конфиге сервера). Сошлось — ничего не пишется; Docker не отвечает — профиль пропускается (повтор при
# следующем прогоне шагов); контейнера нет — только копия в state/, с ней его и поднимут.
ga_amn_mtu_sync_all() {
    local p list want have st
    ga_profiles_load list || return 1
    for p in $list; do
        want=$(ga_config_get ".profiles.$p.params.MTU" 2>/dev/null)
        [[ "$want" =~ ^[0-9]{3,5}$ ]] || continue
        have=$(sed -n 's/^MTU = //p' "$(ga_amn_state_conf "$p")" 2>/dev/null | head -n 1)
        [ "$have" = "$want" ] && continue
        st=$(docker_container_state "$(ga_profile_field "$p" container)")
        case "$st" in
            running|exited) amnezia_write_server_conf "$p" >/dev/null || continue ;;
            missing)        amnezia_write_server_conf "$p" state >/dev/null || continue ;;
            *)              continue ;;
        esac
        printf '%s=%s\n' "$p" "$want"
    done
    return 0
}

# users.json — источник правды: пир, которого в нём нет (добавлен приложением
# Amnezia прямо в контейнер), при переписывании конфига пропадёт. Молча терять
# чужого клиента нельзя — предупреждаем и советуем import-adopt. Пиры, которые
# мы сами сейчас удаляем, перечислены в GA_EXPECT_DROP — о них не шумим.
# Совет — по причине (KEENETIC-I1-N, V3): «подхватите сверкой» — только тому, кого
# сверка подхватит; пиру, которого она пропустит (ga_import_peers_sort: не ключ,
# нет IPv4, ключ другого профиля), — строка с причиной, без сверки. Начало ключа —
# только знаки base64 (как ga_peer_tag): конфиг контейнера — чужой ввод.
ga_amn_warn_foreign_peers() {
    local profile="$1" container="$2" raw live known key users sorted='' sorted_done='' peers tag skip
    # Третий аргумент — уже прочитанный живой конфиг (amnezia_write_server_conf читает его один раз).
    if [ $# -ge 3 ]; then
        raw=$3
    else
        raw=$(docker_read_file "$container" "$(ga_amn_conf_path "$profile")" 2>/dev/null)
    fi
    live=$(printf '%s\n' "$raw" | ga_amn_conf_pubkeys)
    [ -n "$live" ] || return 0
    # Не прочитали своих — молчим совсем. Раньше конвейер отдавал пустой список
    # известных ключей, и предупреждение объявляло чужим КАЖДЫЙ СВОЙ пир: шум,
    # в котором настоящий чужой пир невозможно заметить.
    ga_users_load users || return 1
    known=$(jq -r --arg p "$profile" '.users[]? | .peers[$p]? // empty | .pubkey // empty' <<<"$users" 2>/dev/null)
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        grep -qxF -- "$key" <<<"$known" && continue
        grep -qxF -- "$key" <<<"${GA_EXPECT_DROP:-}" && continue
        tag=${key:0:12}; tag=${tag//[^A-Za-z0-9+\/=]/?}
        # Причина по пиру — тем же разбором, что у сверки, один раз и только при первом чужом (запись конфига без чужих
        # его не ждёт). PSK — только в памяти, на stdin. Не вышло — прежний совет.
        if [ -z "$sorted_done" ]; then
            sorted_done=1
            if type ga_import_peers_sort >/dev/null 2>&1; then
                peers=$(printf '%s\n' "$raw" | ga_awgkeys parse-conf --with-secrets 2>/dev/null \
                    | jq -c '[.peers[]? | {pubkey, ip: (.ip // ""), psk: (.psk // "")}]' 2>/dev/null) || peers=""
                [ -n "$peers" ] && { sorted=$(ga_import_peers_sort "$profile" "$peers" "$users" 2>/dev/null) || sorted=""; }
            fi
        fi
        skip=""
        # Открытый ключ в argv jq — не секрет; разобранные пиры (с PSK) — на stdin.
        [ -n "$sorted" ] && skip=$(jq -r --arg k "$key" 'first(.[] | select(.pubkey == $k) | .skip) // ""' <<<"$sorted" 2>/dev/null)
        case "$skip" in
            key|ip|taken)
                log_warning "$(tf amnezia_warn_foreign_peer_skipped "$tag" "$profile" "$(t "amnezia_foreign_why_$skip")")" ;;
            *)
                log_warning "$(tf amnezia_warn_foreign_peer "$tag" "$profile" "$(t amnezia_reconcile_where)")" ;;
        esac
    done <<<"$live"
    return 0
}

# ── syncconf на модуле ядра — без маскировки (KMOD-01) ───────────────────────
# На программе (tun) — ровно команда приложения: awg syncconf awg0 <(awg-quick strip …), весь [Interface] и пиры
# без разрыва сессий. На модуле ядра так нельзя: маскировка на живом интерфейсе модуля — зависание сервера с 1 vCPU
# или kernel panic (upstream #253: HeaderProtectionKey под трафиком) и нестабильные I-пакеты (#140). Поэтому там
# в syncconf идут только PrivateKey, ListenPort, FwMark и все [Peer]; параметр, которого нет в syncconf, у интерфейса
# остаётся прежним, а новая маскировка встаёт пересозданием интерфейса — рестартом контейнера. Движок unknown —
# как модуль: так безопасно. Эталон фильтра — sync_conf_text Kaskad (навык amneziawg-kernel-module, pitfalls §2);
# программа без одинарных кавычек: она уходит в контейнер внутри bash -c.
GA_AMN_SYNC_AWK='/^[[:space:]]*\[.*\][[:space:]]*$/ { s = tolower($0); gsub(/[[:space:]]/, "", s); sec = s; print; next } sec == "[interface]" && $0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*$/ { k = $0; sub(/=.*/, "", k); gsub(/[[:space:]]/, "", k); k = tolower(k); if (k != "privatekey" && k != "listenport" && k != "fwmark") next } { print }'

# ga_amn_mask_lines < конфиг → маскировка [Interface] строками «ключ=значение» (ключ в нижнем регистре, по алфавиту):
# всё, что awg-quick strip оставляет в [Interface], кроме PrivateKey, ListenPort и FwMark. Комментарии не в счёт —
# I1–I5 у сервера закомментированы (`# I1 = …`, как у приложения Amnezia) и до интерфейса не доходят ни на модуле,
# ни на программе. Разница этих строк до и после записи конфига — знак, что интерфейсу на модуле нужен рестарт.
# I1–I5 без «#» (ручная правка или чужая сборка) — тоже не в счёт (KEENETIC-I1-R, R1): I-пакеты шлёт клиент, ключи
# людей берут их из config.json, а наша запись конфига ставит их закомментированными. Иначе смена I-пакета или
# перевод I1 на универсальный на модуле ядра перезапускали бы профиль и рвали сессии всем на нём без нужды. На модуле
# фильтр syncconf (GA_AMN_SYNC_AWK) строку I и так не несёт, до рестарта у интерфейса остаётся прежняя.
ga_amn_mask_lines() {
    awk '/^[[:space:]]*\[.*\][[:space:]]*$/ { s = tolower($0); gsub(/[[:space:]]/, "", s); sec = s; next }
         sec != "[interface]" || /^[[:space:]]*#/ || index($0, "=") == 0 { next }
         { i = index($0, "="); k = substr($0, 1, i - 1); v = substr($0, i + 1)
           gsub(/[[:space:]]/, "", k); k = tolower(k); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
           if (k ~ /^(privatekey|listenport|fwmark|address|dns|mtu|table|preup|postup|predown|postdown|saveconfig|i[1-5])$/) next
           print k "=" v }' | LC_ALL=C sort
}

# Контейнеры, у которых запись конфига поменяла маскировку [Interface], — имена через пробел (GA_AMN_MASK_DIRTY); и
# контейнер, который ради неё перезапустил ПОСЛЕДНИЙ вызов amnezia_syncconf (GA_AMN_SYNC_RESTARTED; каждый вызов его
# сбрасывает — SSH-меню живёт одним процессом, и прошлое действие не должно выдавать себя за нынешнее).
GA_AMN_MASK_DIRTY=""
GA_AMN_SYNC_RESTARTED=""
ga_amn_mask_mark() { case " $GA_AMN_MASK_DIRTY " in *" $1 "*) ;; *) GA_AMN_MASK_DIRTY="${GA_AMN_MASK_DIRTY:+$GA_AMN_MASK_DIRTY }$1" ;; esac; }
# ga_amn_mask_take <контейнер> — была ли пометка (и снять её).
ga_amn_mask_take() {
    case " $GA_AMN_MASK_DIRTY " in *" $1 "*) ;; *) return 1 ;; esac
    local c out=""
    for c in $GA_AMN_MASK_DIRTY; do [ "$c" = "$1" ] || out="${out:+$out }$c"; done
    GA_AMN_MASK_DIRTY="$out"
    return 0
}
ga_amn_sync_restarted() { [ -n "${1:-}" ] && [ "$GA_AMN_SYNC_RESTARTED" = "$1" ]; }

# ga_amn_mask_diff <старый конфиг> <новый конфиг> — rc 0, если маскировка [Interface] разошлась. Старого нет
# (не прочитали) — не знаем, rc 1: рестарт без причины рвал бы связь всем на профиле.
ga_amn_mask_diff() {
    [ -n "${1//[[:space:]]/}" ] || return 1
    [ "$(printf '%s\n' "$1" | ga_amn_mask_lines)" != "$(printf '%s\n' "$2" | ga_amn_mask_lines)" ]
}

# amnezia_syncconf <профиль> [движок] — применить конфиг контейнера к живому интерфейсу. Движок спрашивается, если
# его не передали (ga_amn_engine). На модуле или неизвестном движке — syncconf без маскировки, а если запись конфига
# в этом действии поменяла маскировку [Interface] (ga_amn_mask_mark) — рестарт контейнера вместо syncconf: только
# пересоздание интерфейса применит её безопасно; клиенты переподключатся сами, обычно за 15–25 секунд.
# Движок, на котором применили, — в GA_AMN_SYNC_ENGINE.
amnezia_syncconf() {
    local profile="$1" engine="${2:-}" container tool iface conf filter="" dirty=0
    ga_profile_check_installed "$profile" || return $?
    container=$(ga_profile_field "$profile" container)
    tool=$(ga_amn_tool "$profile"); iface=$(ga_amn_iface "$profile"); conf=$(ga_amn_conf_path "$profile")
    GA_AMN_SYNC_RESTARTED=""
    case "$engine" in kernel|program|unknown) ;; *) engine=$(ga_amn_engine "$profile") ;; esac
    GA_AMN_SYNC_ENGINE="$engine"
    ga_amn_mask_take "$container" && dirty=1
    if [ "$engine" != program ]; then
        if [ "$dirty" = 1 ]; then
            log_warning "$(tf amnezia_kmod_mask_restart "$profile")"
            docker_restart "$container" || return 1
            ga_amn_wait_up "$profile" || return 1
            GA_AMN_SYNC_RESTARTED="$container"
            return 0
        fi
        filter=" | awk '$GA_AMN_SYNC_AWK'"
    fi
    if ! docker_exec_bash "$container" "$tool syncconf $iface <($tool-quick strip $conf$filter)"; then
        ga_err syncconf_failed "$(tf amnezia_err_syncconf "$profile")"
        return 1
    fi
    return 0
}

# amnezia_show <профиль> → JSON [{pubkey, endpoint, allowed_ips,
# latest_handshake_ts, rx, tx}]. Читаем `awg show awg0 dump`: один вызов,
# табуляция, unix-время и байты — без разбора «2 minutes ago» и «1.2 MiB» из
# человеческого вывода. Приватный ключ и PSK из dump наружу не выходят.
# GOAMNEZIA_AWG_SHOW_FIXTURE=<файл> подменяет вывод (тесты, dry-run).
amnezia_show() {
    local profile="$1" container raw tool iface
    ga_profile_check_installed "$profile" || return $?
    container=$(ga_profile_field "$profile" container)
    tool=$(ga_amn_tool "$profile"); iface=$(ga_amn_iface "$profile")
    if [ -n "${GOAMNEZIA_AWG_SHOW_FIXTURE:-}" ] && [ -f "$GOAMNEZIA_AWG_SHOW_FIXTURE" ]; then
        raw=$(<"$GOAMNEZIA_AWG_SHOW_FIXTURE")
    elif ga_dry; then
        ga_dry_echo "docker exec -i $container $tool show $iface dump"
        echo "[]"
        return 0
    else
        if ! raw=$(ga_docker exec -i "$container" "$tool" show "$iface" dump </dev/null 2>/dev/null); then
            ga_err show_failed "$(tf amnezia_err_show "$profile")"
            return 1
        fi
    fi
    # Строка пира — 8 полей: pubkey psk endpoint allowed-ips handshake rx tx
    # keepalive. Строку интерфейса ОТЛИЧАЕМ ПО allowed-ips, а не по числу полей:
    # у ванильного wg интерфейс — это 4 поля (private-key public-key listen-port
    # fwmark), но awg дописывает туда все параметры маскировки, и полей
    # становится больше восьми. Из-за проверки «NF >= 8» строка интерфейса
    # уезжала в ответ как пир, и первым «pubkey» шёл ПРИВАТНЫЙ КЛЮЧ СЕРВЕРА —
    # в traffic, в панель, в MCP-инструмент traffic_report (доступен даже на
    # уровне read) и в статистику, где его rx/tx были параметрами маскировки.
    # У пира в 4-м поле всегда список подсетей («10.8.2.1/32») или «(none)»,
    # у интерфейса там fwmark — ни слэша, ни «(none)».
    # Комментарии (#) допускаем ради fixture-файлов.
    printf '%s\n' "$raw" | awk -F'\t' '$1 !~ /^#/ && NF >= 8 && ($4 ~ /\// || $4 == "(none)") { printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1, $3, $4, $5, $6, $7 }' \
        | jq -Rn '[inputs | split("\t") | select(length >= 6)
                   | {pubkey: .[0], endpoint: (if .[1] == "(none)" then "" else .[1] end),
                      allowed_ips: .[2], latest_handshake_ts: (.[3] | tonumber? // 0),
                      rx: (.[4] | tonumber? // 0), tx: (.[5] | tonumber? // 0)}]'
}

# Подпись человека из имени клиента приложения Amnezia: первые 48 знаков (знаков, а не байтов — как у
# подписей, SR-23) без управляющих. Одно определение на подхват (lib/import.sh) и на запись clientsTable:
# по нему запись узнаёт, что имя у нас не меняли, и оставляет имя приложения дословно (находка ACC-1).
GA_AMN_LABEL_JQ='def ga_app_label: tostring | .[0:48] | explode | map(select(. >= 32 and . != 127)) | implode;'

# clientsTable в формате приложения: [{clientId: pubkey, userData: {clientName,
# creationDate}}] — все пиры профиля, включая выключенных (у приложения запись
# живёт, пока клиента не отозвали). Приложение при чтении само дописывает
# latestHandshake/dataReceived/dataSent/allowed_ips из awg show.
#
# Прежняя таблица (копия в state/) — основа, а не мусор (находка ACC-1). У людей, подхваченных у
# приложения, в userData лежит то, что писало само приложение: creationDate в его формате (Qt TextDate,
# «Sun Sep 27 08:33:56 2026»), allowed_ips и прочее. Сборка «с нуля» ставила вместо даты время подхвата
# и теряла остальное — с первой же записи, то есть с первого нового человека на профиле. Теперь userData
# остаётся дословно; своё — имя, только если его сменили у нас, и дата — только там, где её не было.
amnezia_clientstable_write() {
    local profile="$1" container sdir table users old
    ga_profile_check_installed "$profile" || return $?
    # Тот же конвейер, что в write_server_conf, и та же цена: пустая таблица
    # поверх настоящей — приложение Amnezia теряет имена всех клиентов.
    ga_users_load users || return 1
    container=$(ga_profile_field "$profile" container)
    sdir="$STATE_DIR/$container"
    old=$(jq -c 'if type == "array" then
            [.[] | select(type == "object" and (.clientId | type) == "string" and (.userData | type) == "object")
             | {key: .clientId, value: .userData}] | from_entries
          else {} end' "$sdir/clientsTable" 2>/dev/null) || old=""
    [ -n "$old" ] || old='{}'
    table=$(jq --arg p "$profile" --argjson old "$old" "$GA_AMN_LABEL_JQ"'
        [.users[]? | select(.peers[$p] != null)
         | .label as $l | .created as $c | ($old[(.peers[$p].pubkey // "") | tostring] // {}) as $u
         | {clientId: .peers[$p].pubkey,
            userData: ($u + {clientName: (if ($u.clientName | type) == "string"
                                              and ($u.clientName == $l or ($u.clientName | ga_app_label) == $l)
                                          then $u.clientName else $l end)}
                       | if has("creationDate") then . else . + {creationDate: $c} end)}]' <<<"$users" 2>/dev/null)
    [ -n "$table" ] || table='[]'
    ga_amn_state_init "$sdir" || return 1
    printf '%s\n' "$table" | ga_amn_write_secret "$sdir/clientsTable" || return 1
    printf '%s\n' "$table" | docker_write_file "$container" "$GA_AWG_CLIENTS_TABLE" 0600
}

# ── Копия состояния контейнера ────────────────────────────────────────────────

# Контейнер → state/<container>/: /opt/amnezia/awg/* (конфиг, ключи, clientsTable),
# /opt/amnezia/start.sh (goWARP PRO дописывает в него свой запуск — сохраняем
# как есть) и /opt/warp/ при наличии. Копируем во временный каталог и меняем
# местами: полукопия при обрыве docker cp не должна затирать рабочую.
# В dry-run копия уже наполнена нашими же записями (write_server_conf,
# clientstable_write, write_start_sh) — не трогаем, только приводим имя конфига.
# Конфиг интерфейса контейнера (wg0.conf у подхваченного legacy) ложится в копию
# под awg0.conf — так её ищут восстановление, починка и обновление ядра (ACC-4).
amnezia_state_sync() {
    local profile="$1" container sdir tmp state iface
    ga_profile_check_installed "$profile" || return $?
    container=$(ga_profile_field "$profile" container)
    iface=$(ga_amn_iface "$profile")
    sdir="$STATE_DIR/$container"
    ga_amn_state_init "$sdir" || return 1
    # Копия прежних версий под wg0.conf — к awg0.conf сразу, в сухом прогоне тоже.
    ga_amn_state_canon "$sdir" "$iface" || return 1
    if ga_dry; then
        ga_dry_echo "docker cp $container:$GA_AWG_DIR/. $sdir/ ; docker cp $container:$GA_START_SH $sdir/start.sh ; docker cp $container:$GA_WARP_DIR/. $sdir/warp/ (if exists)"
        return 0
    fi
    ga_capture state docker_container_state "$container"
    ga_amn_docker_up "$state" || return 1
    if [ "$state" = "missing" ]; then
        ga_err container_missing "$(tf amnezia_err_container_missing "$container")" 3
        return 3
    fi
    tmp=$(mktemp -d "$STATE_DIR/.${container}.XXXXXX") || return 1
    chmod 700 "$tmp"
    if ! docker_cp_from "$container" "$GA_AWG_DIR/." "$tmp/"; then
        rm -rf "$tmp"
        ga_err state_failed "$(tf amnezia_err_state "$sdir")"
        return 1
    fi
    # Свежая копия: конфиг интерфейса — то, что применяет контейнер, он и становится awg0.conf.
    if ! ga_amn_state_canon "$tmp" "$iface" live; then
        rm -rf "$tmp"
        return 1
    fi
    docker_cp_from "$container" "$GA_START_SH" "$tmp/start.sh" || true
    if ga_docker exec -i "$container" test -d "$GA_WARP_DIR" </dev/null >/dev/null 2>&1; then
        mkdir -p "$tmp/warp"
        docker_cp_from "$container" "$GA_WARP_DIR/." "$tmp/warp/" || true
    fi
    # Стандартные wg и wg-quick goWARP (без скачанных пакетов): без них пересозданный контейнер поднимал бы WARP
    # инструментами Amnezia на модуле amneziawg (задержка до секунд, README goWARP 2.5.1), пока goWARP их не скачает.
    if ga_docker exec -i "$container" test -d "$GA_WARP_TOOLS_DIR/usr" </dev/null >/dev/null 2>&1; then
        mkdir -p "$tmp/warp-tools"
        docker_cp_from "$container" "$GA_WARP_TOOLS_DIR/usr" "$tmp/warp-tools/usr" || rm -rf "$tmp/warp-tools"
    fi
    find "$tmp" -type d -exec chmod 700 {} + 2>/dev/null
    find "$tmp" -type f -exec chmod 600 {} + 2>/dev/null
    # Три перемещения подряд, и код возврата обязан дойти до вызывающего.
    # Раньше цепочка стояла через && без проверки: если первое перемещение
    # прошло, а второе нет, единственная ХОСТОВАЯ копия приватного ключа
    # сервера оставалась под именем с суффиксом .old, каталога состояния не
    # было вовсе, а функция отвечала нулём — отказ вылезал позже и в другом
    # месте («нет копии состояния»), уже без объяснения причины.
    rm -rf "$sdir.old"
    if ! mv "$sdir" "$sdir.old"; then
        rm -rf "$tmp"
        ga_err state_failed "$(tf amnezia_err_state "$sdir")"
        return 1
    fi
    if ! mv "$tmp" "$sdir"; then
        # Возвращаем прежнюю копию на место: пусть она устарела на один тик,
        # но ключ сервера в ней есть, и профиль остаётся восстановимым.
        mv "$sdir.old" "$sdir" 2>/dev/null || true
        rm -rf "$tmp"
        ga_err state_failed "$(tf amnezia_err_state "$sdir")"
        return 1
    fi
    rm -rf "$sdir.old"
    return 0
}

# state/<container>/ → контейнер, затем применить: если интерфейс уже поднят —
# syncconf, если контейнер свежий (после docker run со «start.sh-заглушкой»
# образа) — первый запуск start.sh, как у приложения.
# ga_amn_recreate_container <профиль> — поднять контейнер профиля заново на его
# нынешнем образе, не трогая state/ и ключи. Нужен там, где контейнера НЕТ:
# восстановление из бэкапа на чистой машине, ручной docker rm, чистка диска.
# Раньше amnezia_state_restore в такой ситуации просто не находил цели для
# docker cp и отчитывался «профиль поднять не удалось» — то есть главная
# страховка продукта не срабатывала ровно в том случае, ради которого нужна.
ga_amn_recreate_container() {
    local profile="$1" container port repo tag digest ref key build_dir
    container=$(ga_profile_field "$profile" container)
    port=$(ga_profile_field "$profile" port)
    repo=$(ga_config_get ".profiles.$profile.image" 2>/dev/null)
    key=$(ga_amn_image_key "$profile" 2>/dev/null) || key=""
    [ -n "$key" ] || key="$GA_IMAGE_KEY"
    [ -n "$repo" ] || repo=$(docker_image_field "$key" repo)
    [ -n "$repo" ] || { ga_err invalid_image_name "$(tf docker_err_image_name "${repo:-<пусто>}")" 2; return 2; }
    tag=$(ga_profile_field "$profile" image_tag)
    digest=$(ga_profile_field "$profile" image_digest)
    # Дайджест точнее тега: у подхваченного профиля приложения дайджеста нет —
    # тогда тег, а его нет — latest, как собирает само приложение.
    if [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        ref="${repo}@${digest}"
    else
        ref="${repo}:${tag:-latest}"
    fi
    # replace — контейнер ЕСТЬ и заменяется намеренно (восстановление из копии, ремонт остановленного): «контейнера
    # нет» там неправда, и владелец, читая журнал бота или SSH, решал, что контейнеры пропали (находка UP-10).
    if [ "${2:-}" = replace ]; then
        log_step "$(tf amnezia_replacing "$profile" "$container")"
    else
        log_step "$(tf amnezia_recreating "$profile" "$container")"
    fi
    ga_amn_disk_ok || return 1
    docker_ensure_installed || return 1
    docker_ensure_network || return 1
    # Образ, уже лежащий на сервере, не качаем заново: пересоздание не должно зависеть от Docker Hub (лимиты,
    # недоступность) — у восстановления это и было поводом класть работавшие профили.
    if ! docker_image_exists "$ref"; then
        docker_pull_ref "$ref" || return 1
    fi
    ga_capture build_dir ga_amn_build_context "$container" "$ref" || return $?
    ga_amn_docker_build "$container" "$build_dir" || return 1
    # replace — снести работающий контейнер только теперь, когда образ собран: всё, что могло упасть (место,
    # загрузка, сборка), уже позади, и сорвавшееся пересоздание не оставляет профиль лежать.
    if [ "${2:-}" = replace ]; then
        ga_amn_container_rm "$profile" || return 1
    fi
    docker_run_awg "$container" "$port" "$container" || return 1
    return 0
}

amnezia_state_restore() {
    local profile="$1" mode="${2:-}" container sdir f state
    ga_profile_check_installed "$profile" || return $?
    container=$(ga_profile_field "$profile" container)
    sdir="$STATE_DIR/$container"
    # Копия прежних версий у подхваченного legacy-контейнера лежит под wg0.conf — принимаем её, приводя к
    # awg0.conf (ACC-4). Раньше здесь был отказ state_missing: восстановление из бэкапа и «Поднять заново» не
    # пересоздавали контейнер, и пиры, которых нет в восстановленном users.json, оставались живыми.
    ga_amn_state_canon "$sdir" "$(ga_amn_iface "$profile")" || return 1
    if [ ! -f "$sdir/awg0.conf" ] || [ ! -f "$sdir/$GA_AWG_SERVER_PRIV" ]; then
        ga_err state_missing "$(tf amnezia_err_state_missing "$container")" 3
        return 3
    fi
    # Контейнера может не быть вовсе — это и есть сценарий восстановления
    # «снесли контейнер, поднимаем из state/». Пересоздаём и продолжаем.
    ga_capture state docker_container_state "$container"
    ga_amn_docker_up "$state" || return 1
    local pub=0
    if [ "$state" = "missing" ]; then
        ga_amn_recreate_container "$profile" || return 1
    elif [ "$mode" = recreate ] || [ "$state" != running ]; then
        # Контейнер есть, но не работает (Created после неудачного запуска, Exited): записать в
        # него файлы нельзя, и «Поднять заново» отвечало «не удалось записать файл» — ремонт не
        # ремонтировал (находка LC-20, 25.09.2026). Пересоздаём из копии состояния.
        # Восстановление из архива: работающий контейнер несёт порт публикации и адрес интерфейса прежнего
        # состояния. Одной записью файлов и syncconf порт, подсеть и MTU архива не применялись: Docker
        # публиковал один порт, интерфейс слушал другой, профиль был недоступен всем при «успехе». Снос — внутри
        # пересоздания, после сборки образа.
        ga_amn_recreate_container "$profile" replace || return 1
    else
        # Работает, но порт у контейнера не опубликован (LC-20): запись файлов и syncconf этого не лечат,
        # docker restart — тоже; лечит только новый docker run. Ключи и состояние — прежние, из копии.
        # Код снимаем без отрицания: `! cmd` в условии отдал бы наружу ноль вместо кода проверки.
        docker_port_published "$container" "$(ga_profile_field "$profile" port)" udp || pub=$?
        if [ "$pub" = 1 ]; then
            log_warning "$(tf amnezia_warn_port_unpublished_recreate "$profile" "$(ga_profile_field "$profile" port)")"
            ga_amn_recreate_container "$profile" replace || return 1
        fi
    fi
    # Работающий контейнер остаётся — его нынешний конфиг нужен, чтобы увидеть, что копия состояния меняет маскировку
    # [Interface] (KMOD-01): на модуле ядра её применит только рестарт, его сделает amnezia_syncconf по пометке.
    local live_old=""
    if [ "$state" = running ] && [ "$mode" != recreate ] && [ "$pub" != 1 ]; then
        live_old=$(docker_read_file "$container" "$(ga_amn_conf_path "$profile")" 2>/dev/null) || live_old=""
    fi
    # Конфиг уходит под именем интерфейса контейнера (awg0.conf / wg0.conf у
    # legacy), остальные файлы — как лежат.
    docker_write_file "$container" "$(ga_amn_conf_path "$profile")" 0600 <"$sdir/awg0.conf" || return 1
    ga_amn_mask_diff "$live_old" "$(cat "$sdir/awg0.conf" 2>/dev/null)" && ga_amn_mask_mark "$container"
    # engine — выбранный движок AmneziaWG (lib/kmod.sh): его читает start.sh при каждом старте.
    for f in clientsTable "$GA_AWG_SERVER_PRIV" "$GA_AWG_SERVER_PUB" "$GA_AWG_PSK" engine; do
        [ -f "$sdir/$f" ] || continue
        docker_write_file "$container" "$GA_AWG_DIR/$f" 0600 <"$sdir/$f" || return 1
    done
    if [ -f "$sdir/start.sh" ]; then
        docker_write_file "$container" "$GA_START_SH" 0755 <"$sdir/start.sh" || return 1
    else
        ga_amn_write_start_sh "$profile" || return 1
    fi
    if [ -d "$sdir/warp" ]; then
        docker_exec "$container" "mkdir -p $GA_WARP_DIR" >/dev/null
        docker_cp_to "$container" "$sdir/warp/." "$GA_WARP_DIR/" || log_warning "$(tf amnezia_warn_warp_restore "$container")"
    fi
    # Инструменты WARP goWARP — туда же, исполняемыми (в state/ файлы лежат 0600).
    if [ -d "$sdir/warp-tools/usr" ]; then
        docker_exec "$container" "mkdir -p $GA_WARP_TOOLS_DIR" >/dev/null
        if docker_cp_to "$container" "$sdir/warp-tools/usr" "$GA_WARP_TOOLS_DIR/"; then
            docker_exec "$container" "chmod 755 $GA_WARP_TOOLS_DIR/usr/bin/* 2>/dev/null; true" >/dev/null
        else
            log_warning "$(tf amnezia_warn_warp_restore "$container")"
        fi
    fi
    if ga_dry; then
        ga_dry_echo "docker exec -i $container $(ga_amn_tool "$profile") show $(ga_amn_iface "$profile") || start.sh"
        amnezia_syncconf "$profile"
        ga_amn_wait_up "$profile"
        return $?
    fi
    if ga_docker exec -i "$container" "$(ga_amn_tool "$profile")" show "$(ga_amn_iface "$profile")" </dev/null >/dev/null 2>&1; then
        amnezia_syncconf "$profile" || return 1
    else
        ga_amn_container_start "$container" || return 1
    fi
    # «Поднят» — только когда интерфейс ответил и порт опубликован: раньше ответ «поднят заново из копии
    # состояния» уходил сразу после docker exec -d start.sh, не дождавшись интерфейса (находка SR-37).
    ga_amn_wait_up "$profile"
}

# amnezia_profile_repair <профиль> — «Поднять контейнер заново» из SSH и моста (profile-repair): тот же
# amnezia_state_restore, но под общим замком и с записью в журнал действий — починка шла без записи effect,
# хотя пересоздаёт контейнер и рвёт связь всем на профиле (находка SR-47).
amnezia_profile_repair() { ga_with_config_lock _amnezia_profile_repair_locked "$@"; }
_amnezia_profile_repair_locked() {
    local profile="${1:-}"
    ga_profile_check_installed "$profile" || return $?
    # goWARP PRO пишет в контейнер сам (/opt/warp, /opt/warp-tools, блок в start.sh), копия состояния узнаёт об этом
    # только при следующей синхронизации. У работающего контейнера ремонт записывал поверх копию, снятую до установки
    # goWARP или до перевыпуска его ключа: блок пропадал, /opt/warp возвращал отозванный ключ (WRP-05). Части goWARP —
    # сначала из контейнера; люди, ключи и порт профиля — по-прежнему из копии, ради них ремонт и нужен.
    ga_amn_warp_refresh "$profile"
    amnezia_state_restore "$profile" || return $?
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "profile-repair" "$profile"
    return 0
}

# ── Обновление ядра: пересоздание контейнера из state/ на другом образе ──────

# Ключ images.json для образа профиля: по repo из config.json (у подхваченного
# legacy-контейнера это amneziavpn/amnezia-wg), иначе — образ наших профилей.
ga_amn_image_key() {
    local profile="$1" repo key images="${UPSTREAM_DIR:-}/images.json"
    repo=$(ga_config_get ".profiles.$profile.image" 2>/dev/null)
    if [ -n "$repo" ] && [ -f "$images" ]; then
        key=$(jq -r --arg r "$repo" 'to_entries[] | select((.value|type) == "object" and .value.repo == $r) | .key' "$images" 2>/dev/null | head -n 1)
        [ -n "$key" ] && { echo "$key"; return 0; }
    fi
    echo "$GA_IMAGE_KEY"
}

# amnezia_core_update <профиль> <repo@sha256:…|repo:tag> [тег] [дайджест]
# Общая механика core-update, upstream-update и upstream-rollback (PLAN §6.6):
# свежая копия состояния → docker rm → сборка нашего контекста с новым FROM →
# docker run с прежним портом → конфиг, clientsTable, ключи, start.sh и
# /opt/warp обратно из state/ → проверка `awg show` и порта → state_sync.
# Ключи сервера и пиров не меняются, клиентам ничего не перевыпускается.
# Образ по ссылке должен быть уже вытянут (docker_pull_ref) — здесь сеть не
# нужна, и откат на прежний образ работает даже без интернета.
# stdout: JSON {profile, container, image_tag, image_digest, old_tag, old_digest}.
amnezia_core_update() { ga_with_config_lock _amnezia_core_update_locked "$@"; }
_amnezia_core_update_locked() {
    local profile="$1" ref="${2:-}" tag="${3:-}" digest="${4:-}"
    local container port old_tag old_digest build_dir repo patch state
    local start_source="${5:-}" start_text=""
    # Снесён ли уже контейнер: откат upstream-update и core-update нужен только после сноса. До него (место,
    # копия состояния, сборка) прежний контейнер работает, и «откатывать» значило бы пересоздать здоровый
    # контейнер или объявить профиль лежащим, когда он цел.
    GA_AMN_CORE_RM_DONE=0
    ga_profile_check_installed "$profile" || return $?
    if ! [[ "$ref" =~ ^[a-z0-9][a-z0-9._/-]{0,127}(:[A-Za-z0-9._-]{1,128}|@sha256:[0-9a-f]{64})?$ ]]; then
        ga_err invalid_image_name "$(tf docker_err_image_name "$ref")" 2
        return 2
    fi
    container=$(ga_profile_field "$profile" container)
    port=$(ga_profile_field "$profile" port)
    old_tag=$(ga_profile_field "$profile" image_tag)
    old_digest=$(ga_profile_field "$profile" image_digest)
    repo="${ref%%@*}"; repo="${repo%%:*}"
    [ -n "$tag" ] || tag="${ref##*:}"; [[ "$ref" == *@* ]] && [ -z "$3" ] && tag="$old_tag"
    [ -n "$digest" ] || { [[ "$ref" == *@sha256:* ]] && digest="${ref##*@}"; }
    log_step "$(tf amnezia_core_updating "$profile" "${tag:-?}")"
    ga_amn_disk_ok || return 1
    # Свежая копия состояния — с неё поднимается новый контейнер. Без ключа
    # сервера в state/ пересоздавать не из чего.
    ga_capture state docker_container_state "$container"
    ga_amn_docker_up "$state" || return 1
    if [ "$state" = "running" ]; then
        amnezia_state_sync "$profile" || return 1
    else
        # Остановленный не синхронизируется, а блок goWARP для start.sh нового релиза берётся из копии ниже, до сноса:
        # части goWARP — из самого контейнера (WRP-05).
        ga_amn_warp_refresh "$profile"
    fi
    # Остановленный контейнер не синхронизировался — копия прежних версий может лежать под wg0.conf (ACC-4).
    ga_amn_state_canon "$STATE_DIR/$container" "$(ga_amn_iface "$profile")" || return 1
    if [ ! -f "$STATE_DIR/$container/$GA_AWG_SERVER_PRIV" ] || [ ! -f "$STATE_DIR/$container/awg0.conf" ]; then
        ga_err state_missing "$(tf amnezia_err_state_missing "$container")" 3
        return 3
    fi
    # Выбор скрипта идёт ПОСЛЕ снимка живого контейнера: снимок иначе возвращал
    # старый start.sh поверх нового upstream. Пятый аргумент внутренний: template
    # для нового релиза или файл сохранённого скрипта для точного отката goWARP.
    # Подготовить его надо до сноса, а записать — только после успешного docker run.
    if [ "$start_source" = template ]; then
        ga_capture start_text ga_amn_render_start_sh "$profile" || return $?
        # Блок goWARP PRO — из снятого только что start.sh контейнера в новый: иначе WARP после обновления не
        # поднимался до ручного восстановления в goWARP.
        start_text=$(ga_amn_start_sh_carry_warp "$start_text" "$STATE_DIR/$container/start.sh")
    elif [ -n "$start_source" ]; then
        [ -s "$start_source" ] || { ga_err state_failed "$(tf amnezia_err_state "$container")"; return 1; }
        start_text=$(cat "$start_source") || return 1
    fi
    ga_capture build_dir ga_amn_build_context "$container" "$ref" || return $?
    ga_amn_docker_build "$container" "$build_dir" || return 1
    if ! ga_amn_container_rm "$profile"; then
        # docker stop прошёл, а docker rm — нет: контейнер стоит, и ответ «образ и скрипты откачены,
        # вмешательства не нужно» был неправдой (находка SR-30). Запускаем прежний; не поднялся — это то же,
        # что снос: вызывающий назовёт контейнер и способ поднять профиль.
        local st_after=""
        ga_capture st_after docker_container_state "$container"
        if [ "$st_after" != running ] \
           && ! { docker_start "$container" >/dev/null 2>&1 && ga_amn_wait_up "$profile" >/dev/null 2>&1; }; then
            GA_AMN_CORE_RM_DONE=1
        fi
        return 1
    fi
    GA_AMN_CORE_RM_DONE=1
    docker_run_awg "$container" "$port" "$container" || return 1
    if [ -n "$start_source" ]; then
        printf '%s\n' "$start_text" >"$STATE_DIR/$container/start.sh" || return 1
        chmod 600 "$STATE_DIR/$container/start.sh" || return 1
    fi
    patch=$(jq -cn --arg p "$profile" --arg repo "$repo" --arg tag "$tag" --arg d "$digest" --arg now "$(ga_now)" \
        '{profiles: {($p): {image: $repo, image_tag: $tag, image_digest: $d, core_updated_at: $now}}}') || return 1
    ga_config_merge "$patch" || { ga_err config_write_failed "$(t amnezia_err_config)"; return 1; }
    amnezia_state_restore "$profile" || return 1
    ga_amn_wait_up "$profile" || return 1
    amnezia_state_sync "$profile" || true
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "core-update" "$profile ${old_tag:--}->${tag:--}"
    log_success "$(tf amnezia_core_updated "$profile" "${tag:-?}")"
    jq -cn --arg p "$profile" --arg c "$container" --arg tag "$tag" --arg d "$digest" \
        --arg ot "$old_tag" --arg od "$old_digest" \
        '{profile: $p, container: $c, image_tag: $tag, image_digest: $d, old_tag: $ot, old_digest: $od}'
}

# ── Сторож контейнеров (goamnezia-watch.timer, раз в 2 минуты) ───────────────

# Интерфейс профиля отвечает на `awg show`? Стенд: файл .iface_down в
# каталоге-фикстуре контейнера изображает контейнер, который работает, но
# туннель внутри не поднялся (сломанный start.sh, кончилась память).
ga_amn_iface_alive() {
    local profile="$1" container fs
    container=$(ga_profile_field "$profile" container)
    if ga_dry; then
        if type ga_docker_fs_path >/dev/null 2>&1 && fs=$(ga_docker_fs_path "$container" ".iface_down") && [ -f "$fs" ]; then
            return 1
        fi
        return 0
    fi
    ga_docker exec -i "$container" "$(ga_amn_tool "$profile")" show "$(ga_amn_iface "$profile")" </dev/null >/dev/null 2>&1
}

# Пауза перед переспросом сторожа: разовый сбой docker exec под нагрузкой не должен рвать связь всем на
# профиле. Проверки ставят GA_AMN_WATCH_RECHECK_SECONDS=0.
_ga_amn_watch_pause() {
    local s="${GA_AMN_WATCH_RECHECK_SECONDS:-3}"
    [[ "$s" =~ ^[0-9]+$ ]] || s=3
    [ "$s" -gt 0 ] && sleep "$s"
    return 0
}

# _ga_amn_watch_unpublished <профиль> <контейнер> — rc 0, если порт у работающего контейнера не опубликован
# и при повторном вопросе через паузу (LC-20). «Не узнать» (Docker не ответил) — не повод пересоздавать.
_ga_amn_watch_unpublished() {
    local port rc=0
    port=$(ga_profile_field "$1" port)
    docker_port_published "$2" "$port" udp 2>/dev/null || rc=$?
    [ "$rc" = 1 ] || return 1
    _ga_amn_watch_pause
    rc=0
    docker_port_published "$2" "$port" udp 2>/dev/null || rc=$?
    [ "$rc" = 1 ]
}

# Память сторожа: /run/goamnezia/watch.json — по контейнеру последнее событие
# и время. Одно и то же событие повторяем боту не чаще раза в час: контейнер,
# который не поднимается, иначе присылал бы уведомление каждые две минуты.
ga_amn_watch_state_file() { printf '%s/watch.json' "${LOCK_DIR:-/run/goamnezia}"; }
ga_amn_watch_should_notify() {
    local container="$1" event="$2" f last_ev last_ts now_ts
    f=$(ga_amn_watch_state_file)
    [ -f "$f" ] || return 0
    last_ev=$(jq -r --arg c "$container" '.[$c].event // ""' "$f" 2>/dev/null)
    last_ts=$(jq -r --arg c "$container" '.[$c].ts // 0' "$f" 2>/dev/null)
    now_ts=$(date -u +%s)
    [[ "$last_ts" =~ ^[0-9]+$ ]] || last_ts=0
    [ "$last_ev" = "$event" ] && [ $((now_ts - last_ts)) -lt 3600 ] && return 1
    return 0
}
ga_amn_watch_remember() {
    local container="$1" event="$2" f tmp
    f=$(ga_amn_watch_state_file)
    # «Всё хорошо», а память уже «ok» — переписывать нечего: время у «ok» никто не читает (should_notify сверяет
    # только тревоги), а сторож заходит сюда на каждый здоровый контейнер раз в две минуты (CPU-03).
    if [ "$event" = ok ] && [ -f "$f" ] \
       && [ "$(jq -r --arg c "$container" '.[$c].event // ""' "$f" 2>/dev/null)" = ok ]; then
        return 0
    fi
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
    tmp=$(mktemp "${f}.XXXXXX" 2>/dev/null) || return 0
    { [ -f "$f" ] && cat "$f" || echo '{}'; } | jq -c --arg c "$container" --arg e "$event" --argjson ts "$(date -u +%s)" \
        '.[$c] = {event: $e, ts: $ts}' 2>/dev/null >"$tmp" && mv -f "$tmp" "$f" || rm -f "$tmp"
    chmod 600 "$f" 2>/dev/null || true
    return 0
}

# ga_amn_netdeps_dangling_watch — соседи в сети пропавшего контейнера, которого нет ни в одном реестре (WRP-06): сторож
# говорит о них один раз — строкой в журнал и записью netdeps_dangling в журнал действий, — а не каждые две минуты.
# Отметка — их имена в state/.netdeps/dangling.reported: набор тот же — молчим, изменился — снова, висящих не осталось —
# отметка снимается. Сами контейнеры не трогаем: гадать, чьими они были, нельзя (WRP-01). Событием боту (ga_notify) —
# только вместе с его текстом в боте: событие продукта общим дампом не приходит (test_bot_features).
ga_amn_netdeps_dangling_watch() {
    local names f
    f="$(docker_netdeps_dir)/dangling.reported"
    # Docker не ответил — ни сказать, ни снять отметку: иначе разовый сбой демона повторял бы ту же строку.
    names=$(docker_netdeps_dangling 2>/dev/null) || return 0
    names=$(printf '%s\n' "$names" | sort -u | paste -sd, - 2>/dev/null)
    names="${names#,}"
    if [ -z "$names" ]; then
        rm -f "$f" 2>/dev/null
        return 0
    fi
    [ "$(cat "$f" 2>/dev/null)" = "$names" ] && return 0
    log_warning "$(tf amnezia_warn_netdeps_dangling "$names")"
    ga_audit "watch" "netdeps_dangling" "containers=$names"
    # Тем же разом — боту: сторож работает без человека, и строка журнала иначе прошла бы мимо (WRP-06)
    type ga_notify >/dev/null 2>&1 && ga_notify netdeps_dangling "$(jq -cn --arg c "$names" '{containers: ($c | split(","))}')"
    { mkdir -p "${f%/*}" && chmod 700 "${f%/*}" && printf '%s\n' "$names" >"$f" && chmod 600 "$f"; } 2>/dev/null
    return 0
}

# amnezia_watch_tick — контейнеры включённых профилей работают и `awg show`
# отвечает; иначе docker start / docker restart и событие боту
# (container_restarted с ok=true|false, container_missing — контейнера нет,
# восстановить его может только backup-restore или core-update).
#
# Отдельно — docker_unreachable: демон Docker не отвечает (чаще всего пакет
# docker.io обновился автообновлением, а демон не перезапускали). Контейнеры
# при этом живут, и объявлять их пропавшими — худшее, что можно сделать:
# именно так сторож ночью раз за разом звал восстанавливать из бэкапа три
# работающих профиля. В этом состоянии сторож НИЧЕГО не чинит (чинить нечем) и
# шлёт ОДНО событие на весь тик, а не по одному на профиль.
# При живом демоне — ещё и «старый ли он» (DK-02, ga_amn_docker_stale_watch ниже):
# пакет обновлён, а служба нет — перезапуск, когда к VPN никто не подключён.
# stdout: JSON {checked, profiles: [{profile, container, state, action, ok}], events,
# docker_unreachable, docker_stale: none|waiting|backoff|busy|restarted|failed}.
amnezia_watch_tick() {
    local p container state action ok event rows='[]' events=0 enabled profiles
    local docker_down=false down_profiles='[]'
    # Переезд сервера замечаем здесь же: отдельного сторожа для этого нет, а
    # тик и так ходит каждые две минуты. В сеть — раз в час (память та же, что
    # у тревог, ключ «ip»), иначе получилось бы 720 запросов в сутки к чужому
    # сервису определения адреса.
    if ga_amn_watch_should_notify ip "probe"; then
        ga_amn_watch_remember ip "probe"
        amnezia_server_ip_check >/dev/null
    fi
    # Битый config.json — отказ, а не «нечего сторожить». Подстановка команды
    # здесь съедала код, сторож обходил пустой список и отчитывался «успешно»:
    # худшее из состояний — контейнеры лежат, а по журналу всё хорошо.
    ga_profiles_load profiles || return 1
    for p in $profiles; do
        enabled=$(ga_config_get ".profiles.$p.enabled" 2>/dev/null)
        [ "$enabled" = "false" ] && continue
        container=$(ga_profile_field "$p" container)
        state=$(docker_container_state "$container")
        action="none"; ok=true; event=""
        case "$state" in
            "$GA_DOCKER_STATE_UNREACHABLE")
                ok=false
                docker_down=true
                down_profiles=$(jq -c --arg p "$p" '. + [$p]' <<<"$down_profiles") || down_profiles="$down_profiles"
                ;;
            missing)
                ok=false; event="container_missing"
                log_warning "$(tf amnezia_watch_missing "$p" "$container")"
                ;;
            exited)
                action="started"; event="container_restarted"
                if docker_start "$container" && ga_amn_wait_up "$p"; then
                    log_warning "$(tf amnezia_watch_started "$p" "$container")"
                else
                    ok=false
                    log_error "$(tf amnezia_watch_start_failed "$p" "$container")"
                fi
                ;;
            *)
                # Один неудачный `awg show` под нагрузкой — ещё не упавший интерфейс: перезапуск рвёт связь
                # всем на профиле, поэтому переспрашиваем через паузу (находка SR-38).
                if ! ga_amn_iface_alive "$p" && { _ga_amn_watch_pause; ! ga_amn_iface_alive "$p"; }; then
                    action="restarted"; event="container_restarted"
                    if docker_restart "$container" && ga_amn_wait_up "$p"; then
                        log_warning "$(tf amnezia_watch_iface_restart "$p" "$container")"
                    elif [ "${GA_ERR_CODE:-}" = port_unpublished ] && amnezia_state_restore "$p" recreate; then
                        action="recreated"
                        log_warning "$(tf amnezia_watch_recreated "$p" "$container" "$(ga_profile_field "$p" port)")"
                    else
                        ok=false
                        log_error "$(tf amnezia_watch_start_failed "$p" "$container")"
                    fi
                elif _ga_amn_watch_unpublished "$p" "$container"; then
                    # Интерфейс жив, а порт у контейнера не опубликован: «работает» для Docker, а для людей
                    # связи нет (LC-20). docker restart этого не лечит — пересоздаём из копии состояния.
                    action="recreated"; event="container_restarted"
                    if amnezia_state_restore "$p" recreate; then
                        log_warning "$(tf amnezia_watch_recreated "$p" "$container" "$(ga_profile_field "$p" port)")"
                    else
                        ok=false
                        log_error "$(tf amnezia_watch_start_failed "$p" "$container")"
                    fi
                else
                    # Здоров — изоляция клиентов на месте? Контейнер мог перезапуститься без нас (--restart always,
                    # перезагрузка хоста), а start.sh приложения у подхваченного правила не ставит (SEC-NET-1).
                    ga_amn_isolation_apply "$p" quiet || true
                    # Соседи в его сети — в нынешнем пространстве? Служба изоляции возвращает их по событию старта;
                    # здесь — страховка, если она лежала (перезапуск контейнера Docker'ом, docker restart руками).
                    ga_amn_netdeps_reattach "$p"
                fi
                ;;
        esac
        if [ -n "$event" ]; then
            # Ключ памяти — событие + действие + исход: «запущен после stop» и
            # «перезапущен из-за интерфейса» — разные тревоги, обе нужны боту.
            if ga_amn_watch_should_notify "$container" "$event:$action:$ok"; then
                ga_notify "$event" "$(jq -cn --arg p "$p" --arg c "$container" --arg a "$action" --argjson ok "$ok" \
                    '{profile: $p, container: $c, action: $a, ok: $ok}')" && events=$((events + 1))
                ga_amn_watch_remember "$container" "$event:$action:$ok"
            fi
            ga_audit "watch" "$event" "$p container=$container action=$action ok=$ok"
        else
            # Всё хорошо — забываем прошлую тревогу, чтобы следующая не глушилась.
            [ -f "$(ga_amn_watch_state_file)" ] && ga_amn_watch_remember "$container" "ok"
        fi
        rows=$(jq -c --arg p "$p" --arg c "$container" --arg s "$state" --arg a "$action" --argjson ok "$ok" \
            '. + [{profile: $p, container: $c, state: $s, action: $a, ok: $ok}]' <<<"$rows") || rows="$rows"
    done
    # Недоступный демон — беда хоста, а не профиля: одно событие на весь тик и
    # одна память дедупликации (ключ «docker»), иначе очередь бота набирала бы
    # по событию на профиль каждый обход. Восстановление из бэкапа тут НЕ
    # предлагаем — восстанавливать нечего, надо поднимать демон.
    if [ "$docker_down" = true ]; then
        log_error "$(t amnezia_watch_docker_down)"
        if ga_amn_watch_should_notify docker "docker_unreachable"; then
            ga_notify docker_unreachable "$(jq -cn --argjson p "$down_profiles" \
                --arg client "${GA_DOCKER_API_CLIENT:-}" --arg daemon "${GA_DOCKER_API_DAEMON:-}" \
                '{profiles: $p, api_client: $client, api_daemon: $daemon}')" && events=$((events + 1))
            ga_amn_watch_remember docker "docker_unreachable"
        fi
        ga_audit "watch" "docker_unreachable" "profiles=$(jq -r 'join(",")' <<<"$down_profiles" 2>/dev/null)"
    elif [ -f "$(ga_amn_watch_state_file)" ]; then
        ga_amn_watch_remember docker "ok"
    fi
    # Соседи в сети пропавшего контейнера, чьи — не записано (снос версией до 03.10.2026, docker rm руками): один раз,
    # а не на каждом тике (WRP-06). При лежащем демоне спрашивать некого.
    [ "$docker_down" = true ] || ga_amn_netdeps_dangling_watch
    # Пакет Docker обновлён, а служба старая (DK-02): перезапуск, когда к VPN никто не подключён. В этой же оболочке
    # (ga_capture, а не $(…)): номер события в имени файла очереди (GA_NOTIFY_SEQ) растёт у всего тика. Лежащий
    # демон — другая беда (docker_unreachable выше), перезапускать там «старое» нечего.
    local dsw="none"
    if [ "$docker_down" != true ]; then
        ga_capture dsw ga_amn_docker_stale_watch || dsw="none"
        events=$((events + GA_AMN_DSW_EVENTS))
    fi
    # Несколько адресов сервера (lib/edgeips.sh): снимок счётчиков и тревоги «адрес замолчал» — тем же
    # тиком, раз в две минуты. Сбой учёта сторож контейнеров не роняет; с одним адресом модуль молчит.
    local edge_events=0
    if type ga_edge_tick >/dev/null 2>&1; then
        edge_events=$(ga_edge_tick 2>/dev/null) || edge_events=0
        [[ "$edge_events" =~ ^[0-9]+$ ]] || edge_events=0
        events=$((events + edge_events))
    fi
    jq -cn --arg now "$(ga_now)" --argjson rows "$rows" --argjson n "$events" --argjson down "$docker_down" \
        --arg dsw "${dsw:-none}" \
        '{checked: $now, profiles: $rows, events: $n, docker_unreachable: $down, docker_stale: $dsw}'
}

# ── Старый демон Docker: перезапуск, когда к VPN никто не подключён (DK-02) ──────
#
# Пакет docker.io обновился, а служба осталась старой (lib/docker.sh, раздел «Старый демон»). Решение владельца
# 04.10.2026: goAmnezia перезапускает Docker сама, когда к VPN никто не подключён, а человек — кнопкой в любой момент.
# Ручной перезапуск на сервере владельца (29.09 и 04.10) занимал 6–11 с: контейнеры профилей с --restart always
# поднимаются сами, а изоляцию, соседей в сети профиля и goWARP возвращаем тем же путём, что после перезапуска
# профиля (ga_amn_wait_up).
# Правило сторожа (ga_amn_docker_stale_watch, раз в 2 минуты при живом демоне) — всё сразу:
#   • с прошлой попытки (своей или кнопкой) прошло не меньше 6 ч (GA_AMN_DOCKER_RETRY): не вышло — не долбим;
#   • apt/dpkg сейчас не работает (docker_pkg_busy): посреди установки пакета службу не трогаем;
#   • к VPN никто не подключён: у всех пиров всех профилей с работающим контейнером — подхваченных у приложения тоже,
#     у них wg и wg0 — последнее рукопожатие старше 5 минут (GA_AMN_ONLINE_WINDOW); awg show не ответил — не знаем,
#     кто там, и ждём;
#   • замок продукта свободен (не идёт установка или обновление) — без ожидания: тик сторожа и так под замком моста,
#     а занятый замок — «не сейчас», следующий тик через две минуты.
# Тогда — событие docker_restarting боту, перезапуск, подъём профилей и событие docker_restarted с итогом и
# длительностью; запись в журнал действий. Люди подключены — одно событие docker_stale на обнаружение (подпись
# docker_stale_sig) с кнопкой «Перезапустить Docker», дальше молча ждём, Docker не трогаем. Память —
# LOCK_DIR/docker-stale.json: после перезагрузки её нет, и это правильно — перезагрузка лечит и сам старый демон.
GA_AMN_DOCKER_RETRY="${GA_AMN_DOCKER_RETRY:-21600}"
[[ "$GA_AMN_DOCKER_RETRY" =~ ^[0-9]{1,7}$ ]] || GA_AMN_DOCKER_RETRY=21600
GA_AMN_DSW_EVENTS=0
GA_AMN_DKR_EVENTS=0

ga_amn_dsw_file() { printf '%s/docker-stale.json' "${LOCK_DIR:-/run/goamnezia}"; }

# _ga_amn_dsw_get <поле> → значение из памяти сторожа (нет файла или поля — пусто).
_ga_amn_dsw_get() {
    local f
    f=$(ga_amn_dsw_file)
    [ -f "$f" ] || return 0
    jq -r --arg k "$1" 'if type == "object" and has($k) and .[$k] != null then .[$k] | tostring else empty end' "$f" 2>/dev/null
}

# _ga_amn_dsw_put <JSON-объект> — слить поля в память сторожа (атомарно, 0600). Тихая: память не повод валить тик.
_ga_amn_dsw_put() {
    local f tmp
    f=$(ga_amn_dsw_file)
    mkdir -p "${f%/*}" 2>/dev/null || return 0
    tmp=$(mktemp "$f.XXXXXX" 2>/dev/null) || return 0
    if { if [ -f "$f" ]; then cat "$f"; else echo '{}'; fi; } 2>/dev/null \
         | jq -c --argjson p "$1" '(if type == "object" then . else {} end) + $p' 2>/dev/null >"$tmp"; then
        chmod 600 "$tmp" 2>/dev/null
        mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
    else
        rm -f "$tmp"
    fi
    return 0
}

# _ga_amn_dsw_facts [поля…] → JSON-объект о старом демоне для событий: версии демона, бинаря и API, причина, с какого
# времени бинарь новый (ISO), плюс переданные пары «ключ=значение».
_ga_amn_dsw_facts() {
    local since kv extra='{}'
    since=$(_ga_docker_iso "$GA_DOCKER_BIN_SINCE" 2>/dev/null) || since=""
    for kv in "$@"; do
        extra=$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k): $v}' <<<"$extra" 2>/dev/null) || true
    done
    jq -cn --arg dv "$GA_DOCKER_DAEMON_VER" --arg bv "$GA_DOCKER_BIN_VER" --arg bb "$GA_DOCKER_BIN_BUILD" \
           --arg db "$GA_DOCKER_DAEMON_BUILD" --arg ca "$GA_DOCKER_API_CLIENT" --arg da "$GA_DOCKER_API_DAEMON" \
           --arg why "$GA_DOCKER_STALE_REASON" --arg s "$since" --argjson x "$extra" \
           --arg bl "$(docker_label "$GA_DOCKER_BIN_VER" "$GA_DOCKER_BIN_BUILD" "$GA_DOCKER_DAEMON_VER")" \
           --arg dl "$(docker_label "$GA_DOCKER_DAEMON_VER" "$GA_DOCKER_DAEMON_BUILD" "$GA_DOCKER_BIN_VER")" \
        '{daemon_version: $dv, daemon_build: $db, binary_version: $bv, binary_build: $bb, client_api: $ca,
          daemon_api: $da, reason: $why, since: $s, binary_label: $bl, daemon_label: $dl} + $x'
}

# ga_amn_vpn_online → stdout: сколько пиров на связи — последнее рукопожатие моложе GA_AMN_ONLINE_WINDOW (300 с) — у
# всех профилей с работающим контейнером, подхваченных тоже (amnezia_show сам берёт wg и wg0 у legacy-контейнера
# приложения). Выключенные профили не пропускаем: контейнер работает — люди на нём могут быть, а перезапуск Docker
# рвёт связь всем. rc 1 — у работающего контейнера awg show не ответил: кто подключён, не знаем.
ga_amn_vpn_online() {
    local p profiles js n total=0 now window="${GA_AMN_ONLINE_WINDOW:-300}"
    [[ "$window" =~ ^[0-9]+$ ]] || window=300
    now=$(date +%s)
    ga_profiles_load profiles || return 1
    for p in $profiles; do
        [ "$(docker_container_state "$(ga_profile_field "$p" container)" 2>/dev/null)" = running ] || continue
        # Отказ awg show — строкой в журнал (amnezia_show говорит сам): «ждём, потому что не знаем» должно быть видно.
        js=$(amnezia_show "$p") || return 1
        n=$(jq -r --argjson now "$now" --argjson w "$window" \
            '[.[]? | select((.latest_handshake_ts // 0) > 0 and ($now - .latest_handshake_ts) < $w)] | length' \
            <<<"$js" 2>/dev/null) || return 1
        [[ "$n" =~ ^[0-9]+$ ]] || return 1
        total=$((total + n))
    done
    printf '%s' "$total"
}

# _ga_amn_dsw_notify <подпись> [на связи] [повтор не раньше, ISO] — событие docker_stale (Docker обновлён, перезапуск
# — когда никто не подключён; под сообщением кнопка «Перезапустить Docker») — один раз на обнаружение. Третий аргумент
# — ждём не людей, а правила шести часов (retry_after в событии; строка журнала — своя, а не «подключены люди»).
_ga_amn_dsw_notify() {
    local sig="$1" online="${2:-}" retry="${3:-}"
    [ "$(_ga_amn_dsw_get notified)" = "$sig" ] && return 0
    [[ "$online" =~ ^[0-9]+$ ]] || online=""
    ga_notify docker_stale "$(_ga_amn_dsw_facts "online=$online" "retry_after=$retry")" && GA_AMN_DSW_EVENTS=$((GA_AMN_DSW_EVENTS + 1))
    _ga_amn_dsw_put "$(jq -cn --arg s "$sig" '{notified: $s}')"
    ga_audit "watch" "docker_stale" "daemon=$(docker_label "$GA_DOCKER_DAEMON_VER" "$GA_DOCKER_DAEMON_BUILD" "$GA_DOCKER_BIN_VER") binary=$(docker_label "$GA_DOCKER_BIN_VER" "$GA_DOCKER_BIN_BUILD" "$GA_DOCKER_DAEMON_VER") reason=${GA_DOCKER_STALE_REASON} online=${online:-?}${retry:+ retry_after=$retry}"
    if [ -n "$retry" ]; then
        log_warning "$(tf amnezia_docker_stale_backoff "$(ga_human_ts "$retry")")"
    else
        log_warning "$(t amnezia_docker_stale_wait)"
    fi
    return 0
}

# ga_amn_docker_stale_watch → stdout: что сделал сторож — none (демон свежий) | waiting (люди подключены или не
# узнать) | backoff (6 ч с прошлой попытки не прошли) | busy (apt/dpkg или замок заняты) | restarted | failed. Число
# событий боту — в GA_AMN_DSW_EVENTS. Звать в оболочке тика (ga_capture). Не падает: код всегда 0.
ga_amn_docker_stale_watch() {
    local sig now at retry="$GA_AMN_DOCKER_RETRY" online="" rc=0 res=""
    GA_AMN_DSW_EVENTS=0
    if ! docker_stale_probe; then
        # Демон свежий — «сказано» больше не нужно: следующее обнаружение снова придёт сообщением. Время попытки
        # остаётся — шесть часов отсчитываются между любыми попытками.
        [ -n "$(_ga_amn_dsw_get notified)" ] && _ga_amn_dsw_put '{"notified": ""}'
        echo none
        return 0
    fi
    [[ "$retry" =~ ^[0-9]+$ ]] || retry=21600
    # Профилей нет (установка ещё идёт, все сняты) — Docker на этой машине служит не нам: сами его не трогаем, кнопка
    # остаётся.
    local installed=""
    ga_profiles_load installed 2>/dev/null || installed=""
    if [ -z "${installed//[[:space:]]/}" ]; then
        echo none
        return 0
    fi
    sig=$(docker_stale_sig)
    now=$(date +%s)
    at=$(_ga_amn_dsw_get attempt_at); [[ "$at" =~ ^[0-9]+$ ]] || at=0
    if [ $(( now - at )) -lt "$retry" ]; then
        # О неудавшейся попытке уже сказало её событие; новое обнаружение (пакет обновили ещё раз) — одно сообщение.
        [ "$(_ga_amn_dsw_get attempt_sig)" = "$sig" ] || _ga_amn_dsw_notify "$sig" "" "$(_ga_docker_iso $(( at + retry )))"
        echo backoff
        return 0
    fi
    if docker_pkg_busy; then
        echo busy
        return 0
    fi
    if ! online=$(ga_amn_vpn_online) || [ "$online" != 0 ]; then
        _ga_amn_dsw_notify "$sig" "$online"
        echo waiting
        return 0
    fi
    # Счётчик событий перезапуска — с нуля: замок занят — тело не выполнялось, и прежнее значение соврало бы тику.
    GA_AMN_DKR_EVENTS=0
    GA_LOCK_WAIT=0 GA_LOCK_QUIET=1 ga_capture res amnezia_docker_restart watch || rc=$?
    GA_AMN_DSW_EVENTS=$((GA_AMN_DSW_EVENTS + GA_AMN_DKR_EVENTS))
    if [ "$rc" = 75 ]; then
        echo busy
    elif [ "$rc" = 0 ]; then
        echo restarted
    else
        echo failed
    fi
    return 0
}

# ga_amn_docker_stale_status → поле docker_stale действия status: null — демон не старый (или не узнать); иначе факты
# (docker_stale_json) и что знает сторож: last_attempt {at, ok, by, code} — прошлая попытка перезапуска, если была;
# retry_after — раньше этого времени сам не перезапустит (ISO), пусто — на ближайшем тике, если никто не подключён.
ga_amn_docker_stale_status() {
    local js at ok by code retry=""
    js=$(docker_stale_json) || js=""
    [ -n "$js" ] && [ "$js" != null ] || { printf 'null'; return 0; }
    at=$(_ga_amn_dsw_get attempt_at)
    if ! [[ "$at" =~ ^[0-9]+$ ]]; then
        jq -c '. + {last_attempt: null, retry_after: ""}' <<<"$js" 2>/dev/null || printf '%s' "$js"
        return 0
    fi
    ok=$(_ga_amn_dsw_get attempt_ok); by=$(_ga_amn_dsw_get attempt_by); code=$(_ga_amn_dsw_get attempt_code)
    [ $(( at + GA_AMN_DOCKER_RETRY )) -gt "$(date +%s)" ] && retry=$(_ga_docker_iso $(( at + GA_AMN_DOCKER_RETRY )))
    jq -c --arg at "$(_ga_docker_iso "$at")" --arg ok "$ok" --arg by "$by" --arg c "$code" --arg r "$retry" \
        '. + {last_attempt: {at: $at, ok: (if $ok == "true" then true elif $ok == "false" then false else null end),
                             by: $by, code: $c},
              retry_after: $r}' <<<"$js" 2>/dev/null || printf '%s' "$js"
}

# _ga_amn_dkr_profile_up <профиль> <контейнер> — профиль после перезапуска Docker: контейнер с --restart always
# Docker поднимает сам — ждём его до GOAMNEZIA_DOCKER_UP_WAIT (30 с), не поднялся — docker start; дальше тем же путём,
# что после перезапуска профиля: интерфейс, порт, изоляция, соседи, goWARP (ga_amn_wait_up), а порт без публикации
# (LC-20) — пересоздание из копии состояния, ключи прежние.
_ga_amn_dkr_profile_up() {
    local p="$1" c="$2" st="" i wait="${GOAMNEZIA_DOCKER_UP_WAIT:-30}"
    [[ "$wait" =~ ^[0-9]{1,4}$ ]] || wait=30
    for ((i = 0; i <= wait; i++)); do
        st=$(docker_container_state "$c" 2>/dev/null)
        case "$st" in running|missing) break ;; esac
        ga_dry && break
        [ "$i" -lt "$wait" ] && sleep 1
    done
    case "$st" in
        running) ;;
        missing) ga_err container_missing "$(tf amnezia_docker_up_missing "$p" "$c")"; return 1 ;;
        *)       docker_start "$c" || return 1 ;;
    esac
    if ! ga_amn_wait_up "$p"; then
        [ "${GA_ERR_CODE:-}" = port_unpublished ] || return 1
        log_warning "$(tf amnezia_warn_port_unpublished_recreate "$p" "$(ga_profile_field "$p" port)")"
        GA_ERR_CODE=""; GA_ERR_MSG=""
        amnezia_state_restore "$p" recreate || return 1
    fi
    return 0
}

# amnezia_docker_restart [watch|manual] — перезапуск службы Docker и подъём профилей; stdout — JSON итога {ok, by,
# duration_s, restarted[], failed[{profile, code, message}], daemon_before, daemon_after, binary_version, stale}. rc 0 —
# служба перезапущена, демон больше не старый и все профили поднялись; иначе код в GA_ERR_CODE: docker_restart_failed
# (systemctl отказал), docker_restart_timeout (демон не ответил), docker_still_stale (перезапущен, а демон всё тот же),
# restart_failed (не поднялся профиль) — и слова в GA_ERR_MSG. watch — сторож: событие боту до и после (их число — в
# GA_AMN_DKR_EVENTS); manual — кнопка (SSH, бот, панель, MCP): итог получает нажавший. Любая попытка запоминается для
# правила шести часов.
amnezia_docker_restart() { ga_with_config_lock _amnezia_docker_restart_locked "$@"; }
_amnezia_docker_restart_locked() {
    local by="${1:-manual}" who sig t0 dur p profiles c ok=true code="" msg="" before after bin stale=false
    local before_b after_b before_l after_l done_list='[]' fail_list='[]' dl fl
    GA_AMN_DKR_EVENTS=0
    [ "$by" = watch ] || by=manual
    who="${GOAMNEZIA_WHO:-ssh}"
    [ "$by" = watch ] && who=watch
    docker_stale_probe || true
    before="$GA_DOCKER_DAEMON_VER"; before_b="$GA_DOCKER_DAEMON_BUILD"; bin="$GA_DOCKER_BIN_VER"
    sig=$(docker_stale_sig)
    t0=$(date +%s)
    # Попытка — в память ДО перезапуска: оборвись процесс посреди, следующая всё равно не раньше чем через 6 ч.
    _ga_amn_dsw_put "$(jq -cn --argjson t "$t0" --arg s "$sig" --arg b "$by" '{attempt_at: $t, attempt_sig: $s, attempt_by: $b, attempt_ok: null}')"
    if [ "$by" = watch ]; then
        ga_notify docker_restarting "$(_ga_amn_dsw_facts)" && GA_AMN_DKR_EVENTS=$((GA_AMN_DKR_EVENTS + 1))
        log_warning "$(t amnezia_docker_restarting)"
    fi
    GA_ERR_CODE=""; GA_ERR_MSG=""
    if docker_daemon_restart; then
        ga_profiles_load profiles || profiles=""
        for p in $profiles; do
            [ "$(ga_config_get ".profiles.$p.enabled" 2>/dev/null)" = "false" ] && continue
            c=$(ga_profile_field "$p" container)
            GA_ERR_CODE=""; GA_ERR_MSG=""; GA_LAST_ERROR_CODE=""
            if _ga_amn_dkr_profile_up "$p" "$c"; then
                done_list=$(jq -c --arg p "$p" '. + [$p]' <<<"$done_list")
            else
                fail_list=$(jq -c --arg p "$p" --arg c "${GA_ERR_CODE:-${GA_LAST_ERROR_CODE:-restart_failed}}" \
                    --arg m "${GA_ERR_MSG:-}" '. + [{profile: $p, code: $c, message: $m}]' <<<"$fail_list")
            fi
        done
        # Демон — заново, без кэша: тот ли он теперь, что лежит на диске.
        docker_stale_reset
        if docker_stale_probe; then
            stale=true; ok=false; code=docker_still_stale
            before_l=$(docker_label "$GA_DOCKER_DAEMON_VER" "$GA_DOCKER_DAEMON_BUILD" "$GA_DOCKER_BIN_VER")
            after_l=$(docker_label "$GA_DOCKER_BIN_VER" "$GA_DOCKER_BIN_BUILD" "$GA_DOCKER_DAEMON_VER")
            msg=$(tf amnezia_docker_still_stale "$before_l" "$after_l")
        elif [ "$(jq 'length' <<<"$fail_list")" != 0 ]; then
            ok=false; code=restart_failed
            msg=$(tf amnezia_docker_profiles_failed "$(jq -r 'map(.profile) | join(", ")' <<<"$fail_list")")
        fi
    else
        ok=false; code="${GA_ERR_CODE:-docker_restart_failed}"; msg="${GA_ERR_MSG:-}"
        docker_stale_probe && stale=true
    fi
    after="$GA_DOCKER_DAEMON_VER"; after_b="$GA_DOCKER_DAEMON_BUILD"
    # Человеку — версии, а если они те же (сменилась одна сборка) — сборки: «29.1.3 → 29.1.3» не говорит ничего.
    before_l=$(docker_label "$before" "$before_b" "$after"); after_l=$(docker_label "$after" "$after_b" "$before")
    dur=$(( $(date +%s) - t0 ))
    _ga_amn_dsw_put "$(jq -cn --argjson ok "$ok" --arg c "$code" '{attempt_ok: $ok, attempt_code: $c}')"
    dl=$(jq -r 'join(",")' <<<"$done_list"); fl=$(jq -r 'map(.profile) | join(",")' <<<"$fail_list")
    ga_audit "$who" "docker-restart" "by=$by ok=$ok duration=${dur}s daemon=${before_l:--}->${after_l:--} binary=${bin:--} profiles=${dl:--}${fl:+ failed=$fl}${code:+ code=$code}"
    # Отказ самой службы (systemctl, демон не ответил) уже сказан строкой ga_err — здесь только итоги после подъёма.
    if [ "$ok" = true ]; then
        log_success "$(tf amnezia_docker_restarted "$dur" "${after_l:-?}")"
    elif [ "$code" = docker_still_stale ] || [ "$code" = restart_failed ]; then
        log_error "$msg"
    fi
    if [ "$by" = watch ]; then
        ga_notify docker_restarted "$(jq -cn --argjson ok "$ok" --argjson d "$dur" --arg db "$before" --arg da "$after" \
            --arg bv "$bin" --argjson r "$done_list" --argjson f "$fail_list" --arg c "$code" --arg m "$msg" \
            --argjson h "$(( GA_AMN_DOCKER_RETRY / 3600 ))" --arg bl "$before_l" --arg al "$after_l" \
            '{ok: $ok, duration_s: $d, daemon_before: $db, daemon_after: $da, daemon_before_label: $bl,
              daemon_after_label: $al, binary_version: $bv, restarted: $r, failed: $f, code: $c, reason: $m,
              command: "systemctl restart docker", retry_hours: $h}')" \
            && GA_AMN_DKR_EVENTS=$((GA_AMN_DKR_EVENTS + 1))
    fi
    jq -cn --argjson ok "$ok" --arg by "$by" --argjson d "$dur" --argjson r "$done_list" --argjson f "$fail_list" \
           --arg db "$before" --arg da "$after" --arg bv "$bin" --argjson st "$stale" --arg bl "$before_l" --arg al "$after_l" \
        '{ok: $ok, by: $by, duration_s: $d, restarted: $r, failed: $f, daemon_before: $db, daemon_after: $da,
          daemon_before_label: $bl, daemon_after_label: $al, binary_version: $bv, stale: $st}'
    if [ "$ok" != true ]; then
        GA_ERR_CODE="${code:-docker_restart_failed}"; GA_ERR_MSG="$msg"
        declare -F ga_set_error >/dev/null 2>&1 && ga_set_error "$GA_ERR_CODE"
        return 1
    fi
    return 0
}

# ── Поиск контейнеров Amnezia ─────────────────────────────────────────────────

# Та же логика, что у приложения (docker ps + регулярка по «amnezia…:порт->»):
# stdout JSON [{container, port, proto, profile, managed}] — profile/managed
# показывают, наш ли это профиль по config.json.
amnezia_scan_containers() {
    local line name port proto profile managed rows="" p c
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        [[ "$line" =~ ^(amnezia[-a-z0-9]*)[[:space:]] ]] || continue
        name="${BASH_REMATCH[1]}"
        port=""; proto=""
        if [[ "$line" =~ :([0-9]+)-\>[0-9]+/(udp|tcp) ]]; then
            port="${BASH_REMATCH[1]}"
            proto="${BASH_REMATCH[2]}"
        fi
        profile=""; managed=false
        for p in awg1 awg2 awg3; do
            c=$(ga_profile_field "$p" container 2>/dev/null)
            if [ "$c" = "$name" ]; then
                profile="$p"
                ga_profile_installed "$p" && managed=true
                break
            fi
        done
        rows+=$(jq -cn --arg n "$name" --arg port "${port:-0}" --arg proto "$proto" --arg profile "$profile" --argjson managed "$managed" \
            '{container: $n, port: ($port | tonumber), proto: $proto, profile: $profile, managed: $managed}')
        rows+=$'\n'
    done < <(docker_ps_names_ports)
    printf '%s' "$rows" | jq -cs '.'
}
