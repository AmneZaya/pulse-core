#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# goAmnezia pro — lib/users.sh: пользователи и их пиры (контракт §4.5)
#
# Пользователь = одна запись в users.json, у неё пир в каждом профиле (D5):
# один человек ходит с телефона (3.1) и с роутера (1.0) под одним именем.
# Что делаем иначе, чем приложение Amnezia (совместимость не страдает):
#   • свой аллокатор IP с переиспользованием освободившихся адресов;
#   • PSK на каждого пира, а не один на всех (пиры приложения с общим PSK из
#     wireguard_psk.key живут в том же конфиге);
#   • приватный ключ клиента хранится в users.json (0600) — иначе повторно
#     выдать тот же .conf/QR нельзя (приложение хранит его у себя);
#   • выключение = убрать [Peer] из конфига + syncconf, запись остаётся (D10).
#
# Каждая мутация целиком переписывает серверный конфиг и clientsTable из
# users.json (users_apply_profile) — без дописываний «в хвост», чтобы конфиг
# не расходился с источником правды. Все мутации — под ga_with_config_lock:
# пара fn() / _fn_locked(). users_list и users_show — без замка.
#
# Трафик: awg show даёт накопительные счётчики, которые обнуляются при рестарте
# контейнера. В peer храним last_rx/last_tx (последнее показание) и rx/tx
# (накоплено дельтами); правило дельты: показание меньше прошлого → был
# рестарт → дельта = новое показание. traffic.rx/tx пользователя — сумма дельт
# всех пиров, traffic.last_* — сумма последних показаний (справочно).
#
# Уведомления боту — файл-очередь ${GOAMNEZIA_NOTIFY_DIR:-/run/goamnezia/notify}/:
# один файл = одно событие = одна строка JSON {ts, event, user, label, …};
# файл появляется атомарно (mktemp + mv), потребитель читает и удаляет.
# ══════════════════════════════════════════════════════════════════════════════

GA_USERS_NAME_RE='^[A-Za-z0-9_-]{1,32}$'
GA_USERS_MAX_QUOTA_GB=100000
GA_USERS_MAX_DAYS=3650
# Предупреждения таймера лимитов (_users_quota_tick_locked): за сколько суток до конца срока
# и с какой доли израсходованного лимита (в процентах).
GA_USERS_WARN_EXPIRY_DAYS=3
GA_USERS_WARN_QUOTA_PCT=80

# ── Помощники ─────────────────────────────────────────────────────────────────

ga_users_name_valid() { [[ "$1" =~ $GA_USERS_NAME_RE ]]; }
# Любые буквы до 48 символов, без управляющих — как pattern label в actions.json.
# Обратная косая черта запрещена: подпись печатается в SSH через echo -e, и «\e]52;…»
# становился настоящей управляющей последовательностью в терминале root — буфер обмена,
# подделка экрана (находка SR-08, 25.09.2026). Тот же запрет — в шаблоне label в actions.json.
# Длина — в символах при любой локали процесса (ga_char_len): службы зовут мост без LANG, и в C 30 русских
# букв считались 57 «символами» (находка SR-23).
ga_users_label_valid() {
    local n
    [ -n "$1" ] || return 1
    if type ga_char_len >/dev/null 2>&1; then n=$(ga_char_len "$1"); else n=${#1}; fi
    [ "$n" -le 48 ] && [[ "$1" != *[[:cntrl:]]* ]] && [[ "$1" != *\\* ]]
}

# ВАЖНО: код возврата чтения пробрасывается наружу. Раньше здесь стояла подмена
# пустым списком, и это стоило бы всех ключей: на битом users.json (обрыв
# записи, кончилось место) чтение «успешно» отдавало нулевой список, следующая
# же мутация записывала его поверх файла, и приватные ключи всех пользователей
# исчезали без возможности восстановления. Пусть лучше действие честно откажет
# кодом users_corrupt, а человек восстановит файл из бэкапа.
# Правило одно на весь продукт (договор §4.1): читаем только ga_users_load, а
# подстановка команды и конвейер вокруг ga_users_read запрещены — там код
# возврата теряется, и «пусто» снова становится «пользователей нет».
ga_users_json() {
    local j
    # Единственное обращение к файлу — ga_users_load (lib/common.sh): он
    # проверяет целость в текущей оболочке и только потом читает.
    ga_users_load j || { printf '%s' ""; return 1; }
    printf '%s' "$j"
    return 0
}

# stdout: JSON пользователя или пусто. Код возврата — из чтения: «пользователя
# нет» и «файл не читается» обязаны различаться уже здесь, иначе битый файл
# выглядит как чистый сервер без единого пользователя.
ga_users_get() {
    local j
    ga_users_load j || return 1
    jq -c --arg n "$1" '.users[]? | select(.name == $n)' <<<"$j" 2>/dev/null
}
users_exists() { [ -n "$(ga_users_get "$1")" ]; }

ga_users_check_name() {
    if ! ga_users_name_valid "$1"; then
        ga_err invalid_name "$(tf users_err_name "$1")" 2
        return 2
    fi
    return 0
}

ga_users_require() {
    ga_users_check_name "$1" || return $?
    # users_exists спрашивает через подстановку и кода отказа не видит, поэтому
    # целость файла проверяем здесь, в текущей оболочке. Без этого каждая
    # мутация на битом users.json отвечала бы «пользователь не найден» — то
    # есть винила бы человека в том, чего он не делал.
    ga_users_intact || { ga_err users_corrupt "$(t users_err_corrupt)"; return 1; }
    if ! users_exists "$1"; then
        ga_err user_not_found "$(tf users_err_not_found "$1")" 3
        return 3
    fi
    return 0
}

ga_users_check_int() {
    local v="$1" max="$2" what="$3"
    if ! [[ "$v" =~ ^[0-9]{1,7}$ ]] || [ "$v" -gt "$max" ]; then
        ga_err invalid_number "$(tf users_err_number "$what" "$v" "$max")" 2
        return 2
    fi
    return 0
}

# Дата истечения через N дней (0 = бессрочно → пусто). python3 — единственный
# переносимый способ прибавить дни между GNU date и BSD date на macOS.
ga_users_expiry_from_days() {
    local days="$1"
    [[ "$days" =~ ^[0-9]+$ ]] && days=$((10#$days))
    if [ "$days" = "0" ]; then
        echo ""
        return 0
    fi
    python3 -c 'import sys, datetime
d = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=int(sys.argv[1]))
print(d.strftime("%Y-%m-%dT%H:%M:%SZ"))' "$days"
}

# Список профилей из CSV или все установленные; каждый проверяется по белому
# списку и по факту установки.
ga_users_resolve_profiles() {
    local csv="$1" p list=""
    if [ -z "$csv" ]; then
        # Загрузчик, а не $( ): на битом config.json подстановка отдавала пустой
        # список, и «профилей нет» звучало там, где их три (см. ga_profiles_load).
        ga_profiles_load list || { ga_err config_corrupt "$(t err_config_unreadable)"; return 1; }
    else
        [[ "$csv" =~ ^(awg1|awg2|awg3)(,(awg1|awg2|awg3))*$ ]] || {
            ga_err invalid_profile "$(tf amnezia_err_profile "$csv")" 2; return 2; }
        list=${csv//,/$'\n'}
    fi
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        ga_profile_check_installed "$p" || return $?
    done <<<"$list"
    if [ -z "$list" ]; then
        ga_err no_profiles "$(t users_err_no_profiles)"
        return 1
    fi
    printf '%s\n' "$list" | awk 'NF && !seen[$0]++'
}

# Свежий пир профиля: IP из аллокатора, ключи и PSK через awgkeys.py.
ga_users_new_peer() {
    local profile="$1" ip priv pub psk now
    ga_capture ip users_alloc_ip "$profile" || return 1
    priv=$(ga_awgkeys genkey) || return 1
    pub=$(ga_awgkeys_pubkey "$priv") || return 1
    psk=$(ga_awgkeys genpsk) || return 1
    if [ -z "$priv" ] || [ -z "$pub" ] || [ -z "$psk" ]; then
        ga_err keys_failed "$(t amnezia_err_keys)"
        return 1
    fi
    now=$(ga_now)
    # Приватный ключ и PSK — окружением ($ENV), а не аргументами jq: argv любого процесса виден каждому
    # локальному пользователю в /proc/*/cmdline, а окружение — только владельцу (находка SR-17).
    GA_S_PRIV="$priv" GA_S_PSK="$psk" jq -cn --arg ip "$ip" --arg pub "$pub" --arg now "$now" \
        '{ip: $ip, privkey: $ENV.GA_S_PRIV, pubkey: $pub, psk: $ENV.GA_S_PSK, created: $now, active: true,
          last_handshake: 0, rx: 0, tx: 0, last_rx: 0, last_tx: 0}'
}

# Строка JSON-события в очередь бота: событие пользователя = общее событие
# (ga_notify, lib/common.sh) с полем user; сторож и проверка обновлений пишут
# в ту же очередь свои события без пользователя.
ga_users_notify() {
    local event="$1" name="$2" extra="${3:-{\}}" payload
    payload=$(jq -cn --arg user "$name" --argjson extra "$extra" '{user: $user} + $extra' 2>/dev/null) || payload="{\"user\":\"$name\"}"
    ga_notify "$event" "$payload"
}

# Пользователь без ключей и PSK — для списка, карточки, бота, панели. endpoint_ip — всегда строкой:
# пусто значит общий адрес сервера, и потребителю не приходится отличать «нет поля» от «пусто».
# disabled_reason — тоже строкой (у включённого пусто): manual — выключен руками, quota и expiry — таймером лимитов.
# Панель называет выключенного таймером по причине («Лимит исчерпан», а не «Выключен»), и «Удалить выключенных руками»
# (users-del-bulk --state=disabled) выбирает ровно тех, кого она показывает выключенными.
ga_users_public_filter() {
    # jq 1.6 не принимает сокращённое {label}: ключевое слово требует явного значения.
    cat <<'JQ'
{name, label: .label, created, enabled, quota_bytes, expires, traffic,
 imported: (.imported // false),
 endpoint_ip: (.endpoint_ip // ""),
 disabled_reason: (.disabled_reason // ""),
 profiles: ((.peers // {}) | keys),
 peers: ((.peers // {}) | with_entries(.value |= (. + {has_key: ((.privkey // "") != "")} | del(.privkey, .psk))))}
JQ
}

# ── Аллокатор IP ──────────────────────────────────────────────────────────────

# Первый свободный адрес подсети профиля (маска /20–/24, для /24 это .1–.254);
# занятые — из users.json (пиры выключенных пользователей тоже: при включении
# конфиг не меняется) и из AllowedIPs хостовой копии конфига (пиры, добавленные
# приложением). Сетевой адрес — адрес сервера, как у Amnezia, последний адрес
# сети — broadcast: оба пропускаем. Разбор подсети — ga_cidr_parse (lib/amnezia.sh).
# Подсеть и занятые адреса собирает _users_ip_pool — по тем же правилам считает
# свободные места users_free_ips («Добавить сразу несколько» проверяет их до записи).
declare -gA _GA_IP_USED=()
_GA_IP_BASE=0
_GA_IP_SIZE=0
_users_ip_pool() {
    local profile="$1" subnet parsed ip conf users
    _GA_IP_USED=(); _GA_IP_BASE=0; _GA_IP_SIZE=0
    ga_profile_check_installed "$profile" || return $?
    # Занятые адреса — то же чтение users.json и то же правило: нечитаемый файл
    # означал бы «занятых нет», и новый пир получил бы адрес живого соседа.
    ga_users_load users || { ga_err users_corrupt "$(t users_err_corrupt)"; return 1; }
    subnet=$(ga_profile_field "$profile" subnet)
    if ! parsed=$(ga_cidr_parse "$subnet"); then
        ga_err invalid_subnet "$(tf users_err_subnet "$subnet")"
        return 1
    fi
    read -r _GA_IP_BASE _GA_IP_SIZE _ <<<"$parsed"
    while IFS= read -r ip; do
        [ -n "$ip" ] && _GA_IP_USED["$ip"]=1
    done < <(jq -r --arg p "$profile" '.users[]? | .peers[$p]? // empty | .ip // empty' <<<"$users" 2>/dev/null)
    # Копия конфига — awg0.conf; у ещё не приведённой копии прежних версий (подхваченный legacy) — wg0.conf:
    # мимо неё пиры приложения выпадали бы из занятых (ACC-4).
    conf=$(ga_amn_state_conf "$profile")
    if [ -f "$conf" ]; then
        while IFS= read -r ip; do
            [ -n "$ip" ] && _GA_IP_USED["$ip"]=1
        done < <(awk -F'=' '/^[[:space:]]*AllowedIPs[[:space:]]*=/ { v=$2; gsub(/[[:space:]]/, "", v); sub(/\/.*/, "", v); print v }' "$conf")
    fi
    return 0
}

users_alloc_ip() {
    local profile="$1" ip n i
    _users_ip_pool "$profile" || return $?
    for ((i = 1; i < _GA_IP_SIZE - 1; i++)); do
        # Адрес — printf -v, а не $(ga_int2ip): подоболочка на каждый проверенный адрес — сотня форков у сотого
        # человека подсети, а «Добавить сразу несколько» проходит этот цикл на каждого.
        n=$((_GA_IP_BASE + i))
        printf -v ip '%d.%d.%d.%d' $(( (n >> 24) & 255 )) $(( (n >> 16) & 255 )) $(( (n >> 8) & 255 )) $(( n & 255 ))
        [ -n "${_GA_IP_USED[$ip]:-}" ] && continue
        echo "$ip"
        return 0
    done
    ga_err subnet_full "$(tf users_err_subnet_full "$profile" "$((_GA_IP_SIZE - 2))")"
    return 1
}

# users_free_ips <профиль> → stdout «свободно всего» (через пробел): сколько адресов подсети ещё не занято и
# сколько мест в ней вообще (/24 — 254: сетевой адрес — сервер, последний — broadcast).
users_free_ips() {
    local profile="$1" ip n i free=0
    _users_ip_pool "$profile" || return $?
    for ((i = 1; i < _GA_IP_SIZE - 1; i++)); do
        n=$((_GA_IP_BASE + i))
        printf -v ip '%d.%d.%d.%d' $(( (n >> 24) & 255 )) $(( (n >> 16) & 255 )) $(( (n >> 8) & 255 )) $(( n & 255 ))
        [ -n "${_GA_IP_USED[$ip]:-}" ] || free=$((free + 1))
    done
    echo "$free $((_GA_IP_SIZE - 2))"
}

# ── Чтение ────────────────────────────────────────────────────────────────────

users_list() {
    # ga_capture, а не $( ): в подоболочке терялся бы код отказа, и битый
    # users.json приезжал бы в бота, панель и агента как «пользователей нет».
    local j
    ga_capture j ga_users_json || {
        ga_err users_corrupt "$(t users_err_corrupt)"
        return 1
    }
    printf '%s' "$j" | jq "[.users[]? | $(ga_users_public_filter)]"
}

users_show() {
    local name="$1" user
    ga_users_require "$name" || return $?
    user=$(ga_users_get "$name")
    printf '%s' "$user" | jq "$(ga_users_public_filter)"
}

# ── «🎲 Случайное имя» ────────────────────────────────────────────────────────
# Решение владельца 27.09 (docs/MODES_047.md «Имена ключей»): имя нового человека — «прилагательное + столица»
# из lib/names_capitals.json: id латиницей (foggy_london), подпись на языке установки или на заданном
# («Туманный Лондон» / «Foggy London»). Одна функция на всех: SSH-меню (пустой Enter или «?» в поле имени) и
# действие name-suggest для бота, панели и MCP. Занятое не предлагается: id и подпись (на любом из двух языков)
# уже заведённого человека, а также exclude — вариант, который уже на экране («🎲 Ещё» обязано дать другой).
# Только чтение: вариант ничего не занимает (имя забирает user-add), поэтому замок не нужен.
_GA_USERS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Набор имён: GOAMNEZIA_NAMES_JSON (стенды), иначе рядом с модулем — bootstrap привозит его вместе с ядром.
ga_names_file() {
    if [ -n "${GOAMNEZIA_NAMES_JSON:-}" ]; then printf '%s' "$GOAMNEZIA_NAMES_JSON"; return 0; fi
    printf '%s/names_capitals.json' "$_GA_USERS_LIB_DIR"
}

# users_name_suggest [lang] [exclude] → stdout {"id", "label", "lang"} одной строкой. lang — ru | en, пусто —
# язык установки. Отказы: names_missing (набора нет или он не разбирается), names_exhausted (свободных вариантов
# не осталось), users_corrupt (users.json не читается — занятое не проверить).
users_name_suggest() {
    local lang="${1:-}" exclude="${2:-}" file users out rc r
    [[ "$lang" =~ ^(ru|en)$ ]] || lang="${LANG_CODE:-ru}"
    [[ "$lang" =~ ^(ru|en)$ ]] || lang="ru"
    file=$(ga_names_file)
    if [ ! -f "$file" ] || ! jq -e 'type == "array" and length > 0' "$file" >/dev/null 2>&1; then
        ga_err names_missing "$(tf users_err_names_missing "$file")"
        return 1
    fi
    ga_users_load users || { ga_err users_corrupt "$(t users_err_corrupt)"; return 1; }
    # 30 случайных бит из двух $RANDOM: остаток от деления на несколько сотен вариантов почти без перекоса.
    r=$(( (RANDOM << 15) | RANDOM ))
    # users.json (в нём приватные ключи) — конвейером в stdin jq, не аргументом и не временным файлом.
    out=$(printf '%s' "$users" | jq -c --arg lang "$lang" --arg ex "$exclude" --argjson r "$r" --slurpfile names "$file" '
        def label_ok: type == "string" and length > 0 and length <= 48 and (test("[[:cntrl:]\\\\]") | not);
        (reduce ([.users[]? | .name, .label][] | select(type == "string" and . != "")) as $x ({}; .[$x] = true)) as $taken
        | [ $names[0][]? | select(type == "object")
            | select((.id | type) == "string" and (.id | test("^[A-Za-z0-9_-]{1,32}$"))
                     and (.ru | label_ok) and (.en | label_ok))
            | select(.id != $ex and ($taken[.id] | not) and ($taken[.ru] | not) and ($taken[.en] | not)) ]
        | if length == 0 then empty
          else .[$r % length] | {id, label: (if $lang == "en" then .en else .ru end), lang: $lang} end' 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        ga_err names_missing "$(tf users_err_names_missing "$file")"
        return 1
    fi
    if [ -z "$out" ]; then
        ga_err names_exhausted "$(t users_err_names_exhausted)"
        return 1
    fi
    printf '%s\n' "$out"
}

# users_name_suggest_many <n> [lang] → stdout JSON-массив из n разных свободных вариантов [{id, label}] — имена для
# «Добавить сразу несколько» без префикса. Правила те же, что у users_name_suggest (занятые id и подписи на любом из
# двух языков не предлагаются), и между собой варианты не повторяются. Свободных меньше n — names_exhausted с их
# числом, до любых записей. Только чтение, как и users_name_suggest.
users_name_suggest_many() {
    local n="$1" lang="${2:-}" file users list id label k j r tmp total
    local -a ids=() labels=()
    [[ "$lang" =~ ^(ru|en)$ ]] || lang="${LANG_CODE:-ru}"
    [[ "$lang" =~ ^(ru|en)$ ]] || lang="ru"
    [[ "$n" =~ ^[0-9]{1,4}$ ]] || n=1
    n=$((10#$n))
    file=$(ga_names_file)
    if [ ! -f "$file" ] || ! jq -e 'type == "array" and length > 0' "$file" >/dev/null 2>&1; then
        ga_err names_missing "$(tf users_err_names_missing "$file")"
        return 1
    fi
    ga_users_load users || { ga_err users_corrupt "$(t users_err_corrupt)"; return 1; }
    # Все свободные варианты строками «id<0x1f>подпись»; выбор — ниже, перетасовкой в bash ($RANDOM): у jq случая нет.
    if ! list=$(printf '%s' "$users" | jq -r --arg lang "$lang" --slurpfile names "$file" '
        def label_ok: type == "string" and length > 0 and length <= 48 and (test("[[:cntrl:]\\\\]") | not);
        (reduce ([.users[]? | .name, .label][] | select(type == "string" and . != "")) as $x ({}; .[$x] = true)) as $taken
        | $names[0][]? | select(type == "object")
        | select((.id | type) == "string" and (.id | test("^[A-Za-z0-9_-]{1,32}$"))
                 and (.ru | label_ok) and (.en | label_ok))
        | select(($taken[.id] | not) and ($taken[.ru] | not) and ($taken[.en] | not))
        | [.id, (if $lang == "en" then .en else .ru end)] | join("\u001f")' 2>/dev/null); then
        ga_err names_missing "$(tf users_err_names_missing "$file")"
        return 1
    fi
    while IFS=$'\x1f' read -r id label; do
        [ -n "$id" ] || continue
        ids+=("$id"); labels+=("$label")
    done <<<"$list"
    total=${#ids[@]}
    if [ "$total" -lt "$n" ]; then
        ga_err names_exhausted "$(tf users_err_bulk_names_short "$total" "$n")"
        return 1
    fi
    # Частичная перетасовка Фишера — Йетса: первые n мест — разные случайные варианты (30 бит из двух $RANDOM).
    for ((k = 0; k < n; k++)); do
        r=$(( (RANDOM << 15) | RANDOM ))
        j=$(( k + r % (total - k) ))
        tmp=${ids[$k]}; ids[$k]=${ids[$j]}; ids[$j]=$tmp
        tmp=${labels[$k]}; labels[$k]=${labels[$j]}; labels[$j]=$tmp
    done
    for ((k = 0; k < n; k++)); do
        printf '%s\x1f%s\n' "${ids[$k]}" "${labels[$k]}"
    done | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\u001f") | {id: .[0], label: .[1]})'
}

# ── Применение к контейнеру ───────────────────────────────────────────────────

# Переписать конфиг и clientsTable профиля из users.json, применить без разрыва
# сессий (syncconf), обновить копию состояния.
users_apply_profile() { ga_with_config_lock _users_apply_profile_locked "$@"; }
_users_apply_profile_locked() {
    local profile="$1"
    ga_profile_check_installed "$profile" || return $?
    amnezia_write_server_conf "$profile" || return 1
    amnezia_clientstable_write "$profile" || return 1
    amnezia_syncconf "$profile" || return 1
    amnezia_state_sync "$profile" || return 1
    return 0
}

ga_users_apply_many() {
    local p rc=0
    for p in "$@"; do
        [ -n "$p" ] || continue
        _users_apply_profile_locked "$p" || rc=1
    done
    return $rc
}

# ── Мутации ───────────────────────────────────────────────────────────────────

users_add() { ga_with_config_lock _users_add_locked "$@"; }
_users_add_locked() {
    local name="$1" label="${2:-}" csv="${3:-}" quota_gb="${4:-0}" days="${5:-0}"
    local profiles p peer peers='{}' user expires quota_bytes now
    # Локальная, а не глобальная: bash отдаёт её и вызываемым функциям
    # (ga_amn_warn_foreign_peers), а по выходе из функции восстанавливает
    # прежнее значение сам — на любой ветке, включая ранний return.
    local GA_EXPECT_DROP=""
    ga_users_check_name "$name" || return $?
    [ -n "$label" ] || label="$name"
    if ! ga_users_label_valid "$label"; then
        ga_err invalid_label "$(t users_err_label)" 2
        return 2
    fi
    ga_users_check_int "$quota_gb" "$GA_USERS_MAX_QUOTA_GB" "quota_gb" || return $?
    ga_users_check_int "$days" "$GA_USERS_MAX_DAYS" "days" || return $?
    # Ведущий ноль — не восьмеричное: «010» ГБ — это 10, а не 8, «08» не роняет меню, «00» дней —
    # бессрочно, а не «истекает сейчас» (находка SR-14, 25.09.2026).
    quota_gb=$((10#$quota_gb)); days=$((10#$days))
    # Здесь нет ga_users_require (пользователя как раз быть не должно), поэтому
    # целость файла спрашиваем отдельно — до генерации ключей и до записи.
    ga_users_intact || { ga_err users_corrupt "$(t users_err_corrupt)"; return 1; }
    if users_exists "$name"; then
        ga_err user_exists "$(tf users_err_exists "$name")"
        return 1
    fi
    ga_capture profiles ga_users_resolve_profiles "$csv" || return $?
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        ga_capture peer ga_users_new_peer "$p" || return 1
        # Пир с приватным ключом — окружением, не аргументом (SR-17).
        peers=$(GA_S_PEER="$peer" jq -c --arg p "$p" '. + {($p): ($ENV.GA_S_PEER | fromjson)}' <<<"$peers") || return 1
    done <<<"$profiles"
    # «ГБ» в продукте — это 1024³ (строго говоря ГиБ), одна и та же единица на
    # вводе и на выводе: человек вводит 50 и видит 50. Так считают и клиенты
    # Amnezia, и большинство панелей; менять подпись на «ГиБ» во всех трёх
    # интерфейсах ради 7 % — шум без выигрыша (DEFECTS §4.9).
    quota_bytes=$((quota_gb * 1073741824))
    expires=$(ga_users_expiry_from_days "$days") || return 1
    now=$(ga_now)
    # Пиры и запись человека несут приватные ключи — окружением, не аргументами jq (SR-17).
    # label — ключевое слово jq 1.6 (Ubuntu 22.04): имя переменной должно отличаться от поля JSON.
    user=$(GA_S_PEERS="$peers" jq -cn --arg name "$name" --arg user_label "$label" --arg now "$now" \
        --argjson quota "$quota_bytes" --arg expires "$expires" \
        '{name: $name, label: $user_label, created: $now, enabled: true, quota_bytes: $quota,
          expires: $expires, traffic: {rx: 0, tx: 0, last_rx: 0, last_tx: 0, updated: ""},
          peers: ($ENV.GA_S_PEERS | fromjson)}') || return 1
    ga_users_json | GA_S_USER="$user" jq '.users += [$ENV.GA_S_USER | fromjson]' | ga_users_write || {
        ga_err users_write_failed "$(t users_err_write)"; return 1; }
    # «Добавить сразу несколько» (users_add_bulk): запись есть, а к контейнерам — одно применение на всех в конце,
    # там же откат, журнал и итог. GA_USERS_BULK — local вызывающего: у одиночного добавления её нет.
    [ "${GA_USERS_BULK:-0}" = 1 ] && return 0
    # shellcheck disable=SC2086  # список профилей — по одному слову в строке, словоделение намеренное
    # Применение может не дойти до сервера (докер молчит, нет state/, нет места).
    # Тогда запись откатываем: иначе в списке жил бы «нормальный» пользователь с
    # ключом, о котором сервер не знает, и человек ловил бы молчащий туннель.
    # Код берём ДО проверки: внутри `if ! …` значение $? уже инвертировано
    # оболочкой и всегда равно нулю — классическая ловушка bash.
    local _add_rc=0
    ga_users_apply_many $profiles || _add_rc=$?
    if [ "$_add_rc" -ne 0 ]; then
        # Профилей у пользователя несколько, и отказ одного не отменяет того,
        # что в ОСТАЛЬНЫХ пир уже уехал в живой контейнер. Снять запись мало:
        # в контейнере остался бы авторизованный пир, приватного ключа от
        # которого больше не существует нигде, а его адрес считался бы занятым
        # и следующий пользователь получал бы следующий. Поэтому после снятия
        # записи профили переприменяем — конфиг собирается заново из users.json
        # и фантом из него уходит.
        GA_EXPECT_DROP=$(jq -r '.[]? | .pubkey // empty' <<<"$peers")
        ga_users_json | jq --arg n "$name" '.users |= map(select(.name != $n))' | ga_users_write \
            || log_error "$(t users_err_write)"
        # shellcheck disable=SC2086
        ga_users_apply_many $profiles || log_warning "$(tf users_warn_rollback_apply "$name")"
        ga_audit "${GOAMNEZIA_WHO:-ssh}" "user-add" "$name apply=failed rollback=done"
        return "$_add_rc"
    fi
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "user-add" "$name profiles=$(printf '%s' "$profiles" | tr '\n' ',') quota_gb=$quota_gb days=$days"
    # Профили — теми же словами, что в выборе профилей и карточке («AmneziaWG 2.0 · порт 443»), а не местами awg3/awg2,
    # которых человек больше нигде не видит (A-1 критика 16.10).
    local _p _lbl _names=""
    for _p in $profiles; do
        _lbl="$_p"
        type ga_profile_title >/dev/null 2>&1 && _lbl=$(ga_profile_title "$_p" 2>/dev/null)
        _names="${_names:+$_names; }${_lbl:-$_p}"
    done
    log_success "$(tf users_added "$name" "$_names")"
}

# ── «Добавить сразу несколько» ────────────────────────────────────────────────
# Просьба владельца 03.10: до 100 человек одним действием — SSH-меню, бот, панель, MCP (действие users-add-bulk).
# Имена: без префикса — случайные «прилагательное + столица» (users_name_suggest_many, подпись на языке lang, как у
# «🎲»); с префиксом — <префикс>-01…NN, нумерация после самого большого номера, уже заведённого с этим префиксом
# (office-01…10 есть — новые с office-11), так что с существующими не совпадает ни одно.
# Каждого заводит тот же _users_add_locked, что одиночное добавление (проверки, ключи, адрес, запись), всех — под
# одним замком; к контейнерам — одно применение на всех в конце, а не по разу на человека.
# Отказ до любых изменений: число вне 1–100, негодный префикс, мест в подсети профиля меньше, чем людей (каждому —
# адрес в каждом выбранном профиле), свободных случайных имён меньше, чем людей. Сбой на k-м человеке — заведённые до
# него остаются и применяются, итог называет, на ком остановилось (partial, failed). Контейнер не принял изменения —
# снимаются заведённые этим вызовом и ещё не внесённые, как у одиночного добавления. В контейнер — пачками по
# GA_USERS_BULK_BATCH: на сотню — минута-две, и прерывание (Ctrl+C в SSH, остановка службы бота или панели, таймаут)
# посреди неё не оставляет людей, которые есть в списке, но не в контейнере (их ключи молчали бы до следующего
# изменения профиля): сигнал ждёт конца текущего человека, заведённые вносятся, итог — «остановлено на …» (partial).
# Убит без предупреждения (kill -9) — в users.json может остаться не больше одной невнесённой пачки, и её внесёт
# следующее изменение профиля: конфиг всегда собирается из users.json целиком.
# stdout: {requested, count, added: [{name, label}], profiles: [..], prefix, partial, failed: null | {name, code, message}}.
GA_USERS_BULK_MAX=100
GA_USERS_BULK_BATCH=10
users_add_bulk() { ga_with_config_lock _users_add_bulk_locked "$@"; }

# _users_bulk_flush — заведённых пачки (batch вызывающего) — в контейнеры профилей одним применением; удалось — они в
# added. Контейнер не принял — как у одиночного: записи пачки снять и профили переприменить (иначе в успевших
# контейнерах остались бы пиры без приватных ключей, а их адреса считались бы занятыми); остановка — на первом из
# пачки (failed), внесённые раньше пачки остаются. Работает на переменных _users_add_bulk_locked (bash видит local
# вызывающего): profiles, batch, added, names, failed, fcode, fmsg, acode, amsg, rc, applyfail, GA_EXPECT_DROP.
_users_bulk_flush() {
    local js batch_js pubs
    rc=0
    # shellcheck disable=SC2086  # список профилей — по одному слову в строке, словоделение намеренное
    ga_users_apply_many $profiles || rc=$?
    if [ "$rc" -eq 0 ]; then
        added+=("${batch[@]}"); batch=()
        return 0
    fi
    acode="${GA_ERR_CODE:-apply_failed}"; amsg="${GA_ERR_MSG:-}"
    ga_users_load js || js='{"users":[]}'
    batch_js=$(printf '%s\n' "${batch[@]}" | jq -R . | jq -sc .)
    pubs=$(jq -r --argjson a "$batch_js" '.users[]? | select(.name as $n | $a | any(. == $n)) | .peers // {} | .[] | .pubkey // empty' <<<"$js" 2>/dev/null)
    GA_EXPECT_DROP="$pubs"
    ga_users_json | jq --argjson a "$batch_js" '.users |= map(select(.name as $n | $a | any(. == $n) | not))' \
        | ga_users_write || log_error "$(t users_err_write)"
    # shellcheck disable=SC2086
    ga_users_apply_many $profiles || log_warning "$(tf users_warn_rollback_apply "${batch[0]}…")"
    GA_EXPECT_DROP=""
    fcode="$acode"; fmsg="$(tf users_err_bulk_apply_batch "${#batch[@]}")${amsg:+ $amsg}"
    failed=$(jq -cn --arg n "${batch[0]}" --arg c "$fcode" --arg m "$fmsg" '{name: $n, code: $c, message: $m}')
    rc=${#batch[@]}; batch=(); applyfail=1
    return 1
}
_users_add_bulk_locked() {
    local count="$1" csv="${2:-}" prefix="${3:-}" quota_gb="${4:-0}" days="${5:-0}" lang="${6:-}"
    local profiles plist p room free total js num_max start last k name label fcode="" fmsg=""
    local failed='null' rc=0 acode="" amsg=""
    local -a names=() labels=() added=()
    local GA_EXPECT_DROP=""   # см. _users_add_locked: локальная и самосбрасывающаяся
    if ! [[ "$count" =~ ^[0-9]{1,3}$ ]] || [ "$((10#$count))" -lt 1 ] || [ "$((10#$count))" -gt "$GA_USERS_BULK_MAX" ]; then
        ga_err invalid_count "$(tf users_err_bulk_count "$count" "$GA_USERS_BULK_MAX")" 2
        return 2
    fi
    count=$((10#$count))
    if [ -n "$prefix" ]; then
        # Хвостовые - и _ не нужны: «office-» даёт office-01, а не office--01
        prefix="${prefix%"${prefix##*[!_-]}"}"
        if ! [[ "$prefix" =~ ^[A-Za-z0-9_-]{1,28}$ ]]; then
            ga_err invalid_prefix "$(tf users_err_bulk_prefix "${3:-}")" 2
            return 2
        fi
    fi
    ga_users_intact || { ga_err users_corrupt "$(t users_err_corrupt)"; return 1; }
    ga_capture profiles ga_users_resolve_profiles "$csv" || return $?
    plist=$(printf '%s' "$profiles" | tr '\n' ',' | sed 's/,$//')
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        ga_capture room users_free_ips "$p" || return $?
        read -r free total <<<"$room"
        if [ "${free:-0}" -lt "$count" ]; then
            ga_err subnet_full "$(tf users_err_bulk_no_room "$(ga_amn_profile_label "$p")" "${free:-0}" "${total:-0}" "$count")"
            return 1
        fi
    done <<<"$profiles"
    if [ -n "$prefix" ]; then
        ga_users_load js || { ga_err users_corrupt "$(t users_err_corrupt)"; return 1; }
        num_max=$(jq -r --arg pre "$prefix-" '[.users[]?.name | select(type == "string" and startswith($pre))
            | ltrimstr($pre) | select(test("^[0-9]{1,6}$")) | tonumber] | max // 0' <<<"$js" 2>/dev/null) || num_max=0
        [[ "$num_max" =~ ^[0-9]{1,6}$ ]] || num_max=0
        # Номер — от двух цифр (01…99), дальше растёт сам (100, 101): ширина не зависит от размера партии, и
        # office-01…10 из прошлого раза не расходятся по виду с office-11… нынешнего.
        start=$((num_max + 1)); last=$((start + count - 1))
        for ((k = start; k <= last; k++)); do
            printf -v name '%s-%02d' "$prefix" "$k"
            names+=("$name"); labels+=("$name")
        done
        # Номер мог вырасти так, что имя не влезает в 32 знака (префикс на пределе и номера за 999)
        if ! ga_users_name_valid "${names[$((count - 1))]}"; then
            ga_err invalid_prefix "$(tf users_err_bulk_prefix "${names[$((count - 1))]}")" 2
            return 2
        fi
    else
        ga_capture js users_name_suggest_many "$count" "$lang" || return $?
        while IFS=$'\x1f' read -r name label; do
            [ -n "$name" ] || continue
            names+=("$name"); labels+=("$label")
        done < <(jq -r '.[]? | [.id, .label] | join("\u001f")' <<<"$js" 2>/dev/null)
        if [ "${#names[@]}" -ne "$count" ]; then
            ga_err names_missing "$(tf users_err_names_missing "$(ga_names_file)")"
            return 1
        fi
    fi
    log_info "$(tf users_bulk_adding "$count" "$plist")"
    # Тот же путь, что у одиночного добавления; в контейнер — пачками (_users_bulk_flush). Прерывание не обрывает
    # посреди человека: флаг, а остановка — перед следующим (сигнал и так ждёт конца текущей команды).
    local GA_USERS_BULK=1 stop=0 applyfail=0
    local -a batch=()
    trap 'stop=1' INT TERM HUP PIPE
    for ((k = 0; k < count; k++)); do
        if [ "$stop" = 1 ]; then
            fcode=interrupted; fmsg="$(t users_err_bulk_interrupted)"
            failed=$(jq -cn --arg n "${names[$k]}" --arg c "$fcode" --arg m "$fmsg" '{name: $n, code: $c, message: $m}')
            break
        fi
        GA_ERR_CODE=""; GA_ERR_MSG=""
        if _users_add_locked "${names[$k]}" "${labels[$k]}" "$plist" "$quota_gb" "$days" >/dev/null; then
            batch+=("${names[$k]}")
            if [ "${#batch[@]}" -ge "$GA_USERS_BULK_BATCH" ]; then
                _users_bulk_flush || break
            fi
            continue
        fi
        # У сбоя без слов (генератор ключей упал молча) — общая причина с кодом, а не пустое место в итоге; сигнал
        # мог уронить и сам шаг (Ctrl+C достаётся всей группе процессов) — тогда это прерывание, а не сбой
        if [ "$stop" = 1 ]; then
            fcode=interrupted; fmsg="$(t users_err_bulk_interrupted)"
        else
            fcode="${GA_ERR_CODE:-user_add_failed}"; fmsg="${GA_ERR_MSG:-$(tf users_err_bulk_step "${GA_ERR_CODE:-user_add_failed}")}"
        fi
        failed=$(jq -cn --arg n "${names[$k]}" --arg c "$fcode" --arg m "$fmsg" '{name: $n, code: $c, message: $m}')
        break
    done
    [ "${#batch[@]}" -eq 0 ] || _users_bulk_flush || true
    trap - INT TERM HUP PIPE
    GA_USERS_BULK=0
    if [ "${#added[@]}" -eq 0 ] && [ "$applyfail" = 1 ]; then
        # Первая же пачка не вошла в контейнер: снята обратно — отказ, как у одиночного добавления
        ga_audit "${GOAMNEZIA_WHO:-ssh}" "users-add-bulk" "count=0/$count profiles=$plist apply=failed rollback=done"
        ga_err "$acode" "$(tf users_err_bulk_apply "$rc")${amsg:+ $amsg}"
        return 1
    fi
    if [ "${#added[@]}" -eq 0 ]; then
        # Никого: отказ первого же человека — его код, слова — с именем, на котором встало
        ga_audit "${GOAMNEZIA_WHO:-ssh}" "users-add-bulk" "count=0/$count profiles=$plist stopped=${names[0]} code=$fcode"
        GA_ERR_CODE="$fcode"; GA_ERR_MSG="$(tf users_err_bulk_none "${names[0]}" "$fmsg")"
        type ga_set_error >/dev/null 2>&1 && ga_set_error "$fcode"
        return 1
    fi
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "users-add-bulk" "count=${#added[@]}/$count profiles=$plist prefix=${prefix:--} quota_gb=$quota_gb days=$days names=$(IFS=,; printf '%s' "${added[*]}")${fcode:+ stopped=${names[${#added[@]}]} code=$fcode}"
    if [ -n "$fcode" ]; then
        log_warning "$(tf users_bulk_partial "${#added[@]}" "$count" "${names[${#added[@]}]}" "${fmsg:-$fcode}")"
    else
        log_success "$(tf users_bulk_added "${#added[@]}" "$plist")"
    fi
    for ((k = 0; k < ${#added[@]}; k++)); do
        printf '%s\x1f%s\n' "${names[$k]}" "${labels[$k]}"
    done | jq -R -s -c --argjson req "$count" --arg pl "$plist" --arg pre "$prefix" --argjson failed "$failed" '
        (split("\n") | map(select(length > 0) | split("\u001f") | {name: .[0], label: .[1]})) as $a
        | {requested: $req, count: ($a | length), added: $a, profiles: ($pl | split(",")), prefix: $pre,
           partial: ($failed != null), failed: $failed}'
}

users_del() { ga_with_config_lock _users_del_locked "$@"; }
_users_del_locked() {
    local name="$1" user profiles
    # ГЛОБАЛЬНАЯ эта переменная стоила предупреждения о чужих пирах: сбрасывали
    # её только на удачных ветках, а после одного неудавшегося удаления ключи
    # покойника до конца жизни процесса считались «своими» — и настоящий чужой
    # пир с таким ключом продукт пропускал молча. В SSH-меню это один процесс
    # на всю сессию. local решает вопрос целиком: значение видно вызываемым
    # функциям и восстанавливается на выходе из этой, какой бы ни была ветка.
    local GA_EXPECT_DROP=""
    ga_users_require "$name" || return $?
    user=$(ga_users_get "$name")
    profiles=$(jq -r '.peers // {} | keys[]' <<<"$user")
    # Свои же пиры при переписывании конфига пропадут ожидаемо — без предупреждений.
    GA_EXPECT_DROP=$(jq -r '.peers // {} | .[] | .pubkey // empty' <<<"$user")
    # Порядок: сначала выключить и применить, запись удалять только после того, как
    # контейнеры приняли изменение. Раньше запись стиралась первой: при сбое Docker пир
    # оставался в контейнере, человек продолжал подключаться, а продукт о нём уже не знал —
    # ни удалить, ни выключить, ни лимит (находка SR-06, 25.09.2026). Теперь при сбое
    # человек остаётся в списке ВЫКЛЮЧЕННЫМ, и удаление можно повторить.
    ga_users_json | jq --arg n "$name" '.users |= map(if .name == $n then .enabled = false | .peers |= with_entries(.value.active = false) else . end)' \
        | ga_users_write || { ga_err users_write_failed "$(t users_err_write)"; return 1; }
    # shellcheck disable=SC2086
    if ! ga_users_apply_many $profiles; then
        GA_EXPECT_DROP=""
        ga_audit "${GOAMNEZIA_WHO:-ssh}" "user-del" "$name apply=failed kept=disabled"
        ga_err user_del_failed "$(tf users_err_del_apply "$name")"
        return 1
    fi
    ga_users_json | jq --arg n "$name" '.users |= map(select(.name != $n))' | ga_users_write || {
        ga_err users_write_failed "$(t users_err_write)"; return 1; }
    # Имя живёт ещё и в clientsTable (список клиентов для приложения Amnezia): она записана при
    # выключении, когда запись была на месте, — переписываем без неё (без syncconf: пиры не менялись).
    local p
    for p in $profiles; do
        amnezia_clientstable_write "$p" >/dev/null 2>&1 || true
    done
    # Страницы подключения удалённого снимаем сразу, под тем же замком: служба страниц выдаёт
    # ключи по ИМЕНИ, и старая ссылка открыла бы ключи тёзки, заведённого позже (находка SR-05,
    # 25.09.2026 — критическая).
    if type _pages_revoke_all_locked >/dev/null 2>&1; then
        _pages_revoke_all_locked "$name" >/dev/null 2>&1 || true
    fi
    # Подписку (постоянную ссылку для роутеров и Clash) — так же, под тем же замком: секрет стирается, адрес
    # отвечает 404, и тёзка, заведённый позже, ключей по ней не получит (lib/subs.sh).
    if type _subs_revoke_locked >/dev/null 2>&1; then
        _subs_revoke_locked "$name" user-del >/dev/null 2>&1 || true
    fi
    GA_EXPECT_DROP=""
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "user-del" "$name"
    log_success "$(tf users_deleted "$name")"
}

# ── «Удалить сразу несколько» ─────────────────────────────────────────────────
# Просьба владельца 03.10 (следом за «Добавить сразу несколько»): по одному сотня людей на живом сервере удалялась
# 380 с — у каждого своё применение к контейнерам. Здесь — до GA_USERS_BULK_MAX человек одним действием
# (users-del-bulk): SSH-меню, бот, панель, MCP. Выбор — ровно одним способом:
#   names  — имена через запятую (1–100; SSH переводит в них номера строк списка, панель — галочки);
#   prefix — <префикс>-<число>, как их заводит массовое добавление (office-boss, заведённого руками, не трогает);
#   state  — disabled: выключены руками (enabled=false, причина manual или неизвестна — своих таймер лимитов помечает
#            quota или expiry); expired: срок вышел (включён человек или уже выключен таймером — всё равно);
#            quota: лимит трафика исчерпан.
# Подтверждение — числом: confirm обязан совпасть с тем, сколько выбрано В МОМЕНТ ИСПОЛНЕНИЯ, под замком. Список
# успел измениться (кого-то продлили, завели, удалили) — отказ confirm_mismatch до изменений, с числом выбранных.
# Больше 100 совпадений — отказ too_many до изменений, а не «первые сто»: число в подтверждении подтверждает весь
# выбор, а у «первых ста» при сдвиге списка оно осталось бы тем же, хотя удалялись бы уже другие люди.
# Порядок — как у одиночного удаления (SR-06): выключить и применить к контейнерам, и только потом стереть записи.
# Пачками по GA_USERS_BULK_BATCH: выключить пачку одной записью → одно применение к её профилям → стереть пачку
# одной записью → снять страницы подключения пачки (SR-05: служба страниц выдаёт ключи по имени, и старая ссылка
# открыла бы ключи тёзки, заведённого позже). Контейнер не принял — пачка остаётся в списке ВЫКЛЮЧЕННОЙ (удаление
# можно повторить), дальше не идём, итог называет, кто удалён, а кто оставлен. Прерывание (Ctrl+C, остановка службы
# бота или панели, обрыв SSH, ушедший читатель вывода) ждёт конца пачки: ни человека «стёрт, а пир в контейнере», ни
# «в списке выключен, а ходит». clientsTable приложения Amnezia — один раз на профиль в конце. Временные ссылки на
# файл (share) не трогаем, как и одиночное удаление: раздача отдаёт снимок файла, а не ключ по имени, ключ из него
# после удаления не подключается, а сама раздача живёт минуты.

# _users_del_bulk_parse <names> <prefix> <state> → способ выбора в _GA_DB_MODE (names | prefix | state), значение в
# _GA_DB_VALUE (имена через запятую без повторов, префикс без хвостовых - и _, состояние) и имена списка JSON-массивом
# в _GA_DB_NAMES. Отказ — до чтения users.json, rc 2 (неверный запрос): не ровно один способ (invalid_selection),
# негодное имя (invalid_name), больше 100 имён (too_many), префикс (invalid_prefix), состояние (invalid_state).
_GA_DB_MODE=""
_GA_DB_VALUE=""
_GA_DB_NAMES='[]'
_users_del_bulk_parse() {
    local csv="${1:-}" prefix="${2:-}" state="${3:-}" n=0 nm
    local -a list=() uniq=()
    local -A seen=()
    _GA_DB_MODE=""; _GA_DB_VALUE=""; _GA_DB_NAMES='[]'
    [ -z "$csv" ] || n=$((n + 1))
    [ -z "$prefix" ] || n=$((n + 1))
    [ -z "$state" ] || n=$((n + 1))
    if [ "$n" -ne 1 ]; then
        ga_err invalid_selection "$(t users_err_del_bulk_selection)" 2
        return 2
    fi
    if [ -n "$csv" ]; then
        IFS=',' read -ra list <<<"$csv"
        for nm in "${list[@]}"; do
            nm="${nm#"${nm%%[![:space:]]*}"}"; nm="${nm%"${nm##*[![:space:]]}"}"
            if ! ga_users_name_valid "$nm"; then
                ga_err invalid_name "$(tf users_err_del_bulk_name "$nm")" 2
                return 2
            fi
            [ -z "${seen[$nm]:-}" ] || continue
            seen[$nm]=1
            uniq+=("$nm")
        done
        if [ "${#uniq[@]}" -gt "$GA_USERS_BULK_MAX" ]; then
            ga_err too_many "$(tf users_err_del_bulk_too_many_names "${#uniq[@]}" "$GA_USERS_BULK_MAX")" 2
            return 2
        fi
        _GA_DB_MODE=names
        _GA_DB_VALUE=$(IFS=,; printf '%s' "${uniq[*]}")
        _GA_DB_NAMES=$(_users_json_names "${uniq[@]}")
    elif [ -n "$prefix" ]; then
        # Хвостовые - и _ не нужны, как у добавления: «office-» — это те же office-01, office-02…
        prefix="${prefix%"${prefix##*[!_-]}"}"
        if ! [[ "$prefix" =~ ^[A-Za-z0-9_-]{1,28}$ ]]; then
            ga_err invalid_prefix "$(tf users_err_del_bulk_prefix "${2:-}")" 2
            return 2
        fi
        _GA_DB_MODE=prefix
        _GA_DB_VALUE="$prefix"
    else
        case "$state" in
            disabled|expired|quota) ;;
            *)  ga_err invalid_state "$(tf users_err_del_bulk_state "$state")" 2
                return 2 ;;
        esac
        _GA_DB_MODE=state
        _GA_DB_VALUE="$state"
    fi
    return 0
}

# _users_json_names <имя>… → JSON-массив строк (пусто — []).
_users_json_names() {
    [ $# -gt 0 ] || { printf '[]'; return 0; }
    printf '%s\n' "$@" | jq -R . | jq -sc .
}

# stdin: users.json → stdout {count, selected: [{name, label}], missing: [..]} — кого задевает выбор _GA_DB_*, в порядке
# users.json; missing — имена списка, которых нет. Срок — fromdateiso8601; дата, которая не читается, истёкшей не
# считается: удаление — не место для догадок.
_users_del_bulk_match() {
    jq -c --arg mode "$_GA_DB_MODE" --arg v "$_GA_DB_VALUE" --argjson want "$_GA_DB_NAMES" --argjson now "$(date -u +%s)" '
        (reduce $want[] as $x ({}; .[$x] = true)) as $set
        | [.users[]? | select(type == "object" and ((.name // null) | type) == "string")
           | select(if $mode == "names" then $set[.name] == true
                    elif $mode == "prefix" then ((.name | startswith($v + "-")) and (.name | ltrimstr($v + "-") | test("^[0-9]{1,6}$")))
                    elif $v == "disabled" then (.enabled == false and ((.disabled_reason // "") == "" or .disabled_reason == "manual"))
                    elif $v == "expired" then (((.expires // "") | tostring) as $e | $e != ""
                        and (($e | try fromdateiso8601 catch null) as $ts | $ts != null and $ts <= $now))
                    else ((.quota_bytes // 0) > 0 and (((.traffic.rx // 0) + (.traffic.tx // 0)) >= (.quota_bytes // 0))) end)
           | {name, label: ((.label // "") | tostring)}] as $sel
        | (reduce $sel[] as $s ({}; .[$s.name] = true)) as $have
        | {count: ($sel | length), selected: $sel, missing: [$want[] | select($have[.] != true)]}'
}

# Как назвать выбор словами — в отказах «никого не нашлось» и «слишком много».
_users_del_bulk_what() {
    case "$_GA_DB_MODE:$_GA_DB_VALUE" in
        names:*)        t users_del_bulk_what_names ;;
        prefix:*)       tf users_del_bulk_what_prefix "$_GA_DB_VALUE" ;;
        state:disabled) t users_del_bulk_what_disabled ;;
        state:expired)  t users_del_bulk_what_expired ;;
        *)              t users_del_bulk_what_quota ;;
    esac
}

# users_del_bulk_preview <names> <prefix> <state> → stdout {mode, value, count, max, too_many, selected, missing} — кого
# удалит users_del_bulk при таком выборе (действие users-del-bulk-preview, SSH-меню перед подтверждением). Только
# чтение, без замка: count — то самое число для confirm, а сверка с ним — под замком в момент удаления.
users_del_bulk_preview() {
    local users sel
    _users_del_bulk_parse "${1:-}" "${2:-}" "${3:-}" || return $?
    ga_users_load users || { ga_err users_corrupt "$(t users_err_corrupt)"; return 1; }
    # users.json (в нём приватные ключи) — конвейером в stdin jq, не аргументом и не временным файлом
    sel=$(printf '%s' "$users" | _users_del_bulk_match) || { ga_err users_corrupt "$(t users_err_corrupt)"; return 1; }
    jq -c --arg mode "$_GA_DB_MODE" --arg v "$_GA_DB_VALUE" --argjson max "$GA_USERS_BULK_MAX" \
        '{mode: $mode, value: $v, count, max: $max, too_many: (.count > $max), selected, missing}' <<<"$sel"
}

# Страницы подключения выбранных: каталог страниц обходится один раз до удаления (_GA_DB_PAGES: id страницы → имя), а
# снимаются они по пачкам, сразу за стиранием записей. _pages_revoke_all_locked на каждого — проход каталога на
# человека, у сотни людей и сотни страниц — десять тысяч чтений meta.json.
declare -gA _GA_DB_PAGES=()
_GA_DB_PAGES_DIR=""
_users_del_bulk_pages_index() {
    local d who
    local -A want=()
    _GA_DB_PAGES=(); _GA_DB_PAGES_DIR=""
    type ga_pages_dir >/dev/null 2>&1 && type ga_pages_drop >/dev/null 2>&1 || return 0
    _GA_DB_PAGES_DIR=$(ga_pages_dir)
    [ -d "$_GA_DB_PAGES_DIR" ] || return 0
    for who in "$@"; do want[$who]=1; done
    for d in "$_GA_DB_PAGES_DIR"/p-*; do
        [ -d "$d" ] || continue
        who=$(jq -r '.user // ""' "$d/meta.json" 2>/dev/null) || continue
        [[ "$who" =~ ^[A-Za-z0-9_-]{1,32}$ ]] && [ -n "${want[$who]:-}" ] || continue
        [[ "$(basename "$d")" =~ ^p-[a-f0-9]{4,8}$ ]] || continue
        _GA_DB_PAGES[$(basename "$d")]="$who"
    done
    return 0
}
# _users_del_bulk_pages_drop <имя>… — снять страницы этих людей из оглавления; счёт — в pages_n вызывающего, каждая
# снятая — в аудит (page-revoke) из ga_pages_drop. Без подоболочки: оглавление худеет и у вызывающего.
_users_del_bulk_pages_drop() {
    local id who
    local -A gone=()
    for who in "$@"; do gone[$who]=1; done
    for id in "${!_GA_DB_PAGES[@]}"; do
        who="${_GA_DB_PAGES[$id]}"
        [ -n "${gone[$who]:-}" ] || continue
        ga_pages_drop "$_GA_DB_PAGES_DIR/$id" revoked
        unset "_GA_DB_PAGES[$id]"
        pages_n=$((pages_n + 1))
    done
    return 0
}

users_del_bulk() { ga_with_config_lock _users_del_bulk_locked "$@"; }

# _users_del_bulk_flush — пачка (batch вызывающего): выключить одной записью → применить к её профилям → стереть одной
# записью → снять её страницы. Удалась — имена в deleted, профили в touched. Контейнер не принял или запись не легла —
# пачка остаётся в списке выключенной (kept), остановка — на первом из пачки (failed), rc 1. Работает на переменных
# _users_del_bulk_locked (bash видит local вызывающего): batch, deleted, kept, touched, pages_n, failed, fcode, fmsg,
# _db_stop, GA_EXPECT_DROP.
_users_del_bulk_flush() {
    local users batch_js bprofiles p rc=0
    batch_js=$(_users_json_names "${batch[@]}")
    if ! ga_users_load users; then
        fcode=users_corrupt; fmsg="$(t users_err_corrupt)"
    else
        bprofiles=$(printf '%s' "$users" | jq -r --argjson a "$batch_js" \
            '[.users[]? | select(.name as $n | $a | index($n) != null) | .peers // {} | keys[]] | unique | .[]')
        # Свои же пиры при переписывании конфига пропадут ожидаемо — без предупреждений о чужих
        GA_EXPECT_DROP=$(printf '%s' "$users" | jq -r --argjson a "$batch_js" \
            '.users[]? | select(.name as $n | $a | index($n) != null) | .peers // {} | .[] | .pubkey // empty')
        if ! printf '%s' "$users" | jq --argjson a "$batch_js" '.users |= map(if (.name as $n | $a | index($n) != null)
                then .enabled = false | .peers |= with_entries(.value.active = false) else . end)' | ga_users_write; then
            fcode=users_write_failed; fmsg="$(t users_err_write)"
        else
            GA_ERR_MSG=""
            # shellcheck disable=SC2086  # список профилей — по одному слову в строке, словоделение намеренное
            ga_users_apply_many $bprofiles || rc=$?
            if [ "$rc" -ne 0 ]; then
                kept+=("${batch[@]}")
                # Сигнал мог уронить и сам шаг (Ctrl+C достаётся всей группе процессов) — тогда это прерывание
                if [ "$_db_stop" = 1 ]; then
                    fcode=interrupted; fmsg="$(tf users_err_del_bulk_interrupted_kept "${#batch[@]}")"
                else
                    fcode=user_del_failed; fmsg="$(tf users_err_del_bulk_apply "${#batch[@]}")${GA_ERR_MSG:+ $GA_ERR_MSG}"
                fi
            elif ! ga_users_json | jq --argjson a "$batch_js" '.users |= map(select(.name as $n | $a | index($n) == null))' \
                    | ga_users_write; then
                kept+=("${batch[@]}")
                fcode=users_write_failed; fmsg="$(t users_err_write)"
            else
                deleted+=("${batch[@]}")
                for p in $bprofiles; do
                    [[ " ${touched[*]} " == *" $p "* ]] || touched+=("$p")
                done
                _users_del_bulk_pages_drop "${batch[@]}"
                # Подписка удалённого — туда же, сразу (docs/SUBSCRIPTION.md): иначе секрет лежал бы до тика сторожа, а
                # тёзка, заведённый следом, получил бы по старой ссылке свои ключи
                if type _subs_revoke_locked >/dev/null 2>&1; then
                    local _sn
                    for _sn in "${batch[@]}"; do _subs_revoke_locked "$_sn" user-del >/dev/null 2>&1 || true; done
                fi
                GA_EXPECT_DROP=""
                batch=()
                return 0
            fi
        fi
    fi
    GA_EXPECT_DROP=""
    failed=$(jq -cn --arg n "${batch[0]}" --arg c "$fcode" --arg m "$fmsg" '{name: $n, code: $c, message: $m}')
    batch=()
    return 1
}

# users_del_bulk <confirm> [names] [prefix] [state] → stdout {requested, count, deleted: [..], kept: [..], partial,
# failed: null | {name, code, message}, mode, value}; ключей в ответе нет. Отказы до изменений: способ выбора и его
# значение (rc 2), confirm не число 1–100 (confirm_required), имён из списка нет (user_not_found), никого не нашлось
# (nothing_selected), больше 100 (too_many), confirm не совпал с выбранным сейчас (confirm_mismatch). Число выбранных
# у последних трёх — в GA_DB_MATCHED (мост кладёт его в ответ полем matched). Никого не удалили — отказ: контейнер не
# принял первую пачку (user_del_failed, люди оставлены выключенными) или прервано до неё (interrupted).
GA_DB_MATCHED=""
_users_del_bulk_locked() {
    local confirm="${1:-}" users sel count missing k fcode="" fmsg="" failed='null' pages_n=0 p by details
    local -a list=() batch=() deleted=() kept=() touched=()
    local GA_EXPECT_DROP=""   # см. _users_del_locked: локальная и самосбрасывающаяся
    GA_DB_MATCHED=""
    _users_del_bulk_parse "${2:-}" "${3:-}" "${4:-}" || return $?
    if ! [[ "$confirm" =~ ^[0-9]{1,3}$ ]] || [ "$((10#$confirm))" -lt 1 ] || [ "$((10#$confirm))" -gt "$GA_USERS_BULK_MAX" ]; then
        ga_err confirm_required "$(tf users_err_del_bulk_confirm "$GA_USERS_BULK_MAX")" 2
        return 2
    fi
    confirm=$((10#$confirm))
    ga_users_load users || { ga_err users_corrupt "$(t users_err_corrupt)"; return 1; }
    sel=$(printf '%s' "$users" | _users_del_bulk_match) || { ga_err users_corrupt "$(t users_err_corrupt)"; return 1; }
    count=$(jq -r '.count' <<<"$sel")
    missing=$(jq -r '.missing | join(", ")' <<<"$sel")
    if [ -n "$missing" ]; then
        ga_err user_not_found "$(tf users_err_del_bulk_missing "$missing")" 3
        return 3
    fi
    GA_DB_MATCHED="$count"
    if [ "$count" -eq 0 ]; then
        ga_err nothing_selected "$(tf users_err_del_bulk_nothing "$(_users_del_bulk_what)")"
        return 1
    fi
    if [ "$count" -gt "$GA_USERS_BULK_MAX" ]; then
        ga_err too_many "$(tf users_err_del_bulk_too_many "$(_users_del_bulk_what)" "$count" "$GA_USERS_BULK_MAX")"
        return 1
    fi
    if [ "$count" -ne "$confirm" ]; then
        ga_err confirm_mismatch "$(tf users_err_del_bulk_mismatch "$confirm" "$count")"
        return 1
    fi
    mapfile -t list < <(jq -r '.selected[].name' <<<"$sel")
    case "$_GA_DB_MODE" in
        names) by="names" ;;
        *)     by="$_GA_DB_MODE:$_GA_DB_VALUE" ;;
    esac
    _users_del_bulk_pages_index "${list[@]}"
    log_info "$(tf users_bulk_deleting "$count")"
    # Пачками (_users_del_bulk_flush). Прерывание не обрывает пачку на середине: флаг, а остановка — перед следующей.
    # PIPE — тоже: читатель вывода ушёл (служба бота или панели остановлена), и первая же строка журнала в закрытую
    # трубу убила бы процесс посреди пачки. Обработчик снимается в одном месте, в конце, — ранних выходов ниже нет.
    local _db_stop=0
    trap '_db_stop=1' INT TERM HUP PIPE
    for ((k = 0; k < count; k++)); do
        batch+=("${list[$k]}")
        [ "${#batch[@]}" -ge "$GA_USERS_BULK_BATCH" ] || [ "$((k + 1))" -eq "$count" ] || continue
        if [ "$_db_stop" = 1 ]; then
            fcode=interrupted; fmsg="$(t users_err_del_bulk_interrupted)"
            failed=$(jq -cn --arg n "${batch[0]}" --arg c "$fcode" --arg m "$fmsg" '{name: $n, code: $c, message: $m}')
            batch=()
            break
        fi
        _users_del_bulk_flush || break
    done
    # Имя живёт ещё и в clientsTable приложения Amnezia: последнее применение писало её, когда записи последней пачки
    # были на месте, — переписываем без них, один раз на профиль (без syncconf: пиры не менялись).
    for p in "${touched[@]}"; do
        amnezia_clientstable_write "$p" >/dev/null 2>&1 || true
    done
    if [ "$pages_n" -gt 0 ]; then
        log_info "$(tf users_bulk_pages_revoked "$pages_n")"
        # Страниц не осталось — маршрут и служба снимаются, как у pages_revoke
        if type ga_pages_count >/dev/null 2>&1 && [ "$(ga_pages_count)" -eq 0 ] && type _pages_disable_locked >/dev/null 2>&1; then
            _pages_disable_locked >/dev/null 2>&1 || true
        fi
    fi
    details="count=${#deleted[@]}/$count by=$by names=$(IFS=,; printf '%s' "${deleted[*]}")"
    [ "${#kept[@]}" -eq 0 ] || details+=" kept=$(IFS=,; printf '%s' "${kept[*]}")"
    [ -z "$fcode" ] || details+=" stopped=$(jq -r '.name' <<<"$failed") code=$fcode"
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "users-del-bulk" "$details"
    trap - INT TERM HUP PIPE
    if [ "${#deleted[@]}" -eq 0 ]; then
        # Никого: контейнер не принял первую пачку (она оставлена выключенной) или прервано до неё — отказ его кодом
        case "$fcode" in
            user_del_failed) ga_err user_del_failed "$(tf users_err_del_bulk_none_apply "${#kept[@]}")" ;;
            interrupted)
                if [ "${#kept[@]}" -gt 0 ]; then
                    ga_err interrupted "$(tf users_err_del_bulk_none_interrupted_kept "${#kept[@]}")"
                else
                    ga_err interrupted "$(t users_err_del_bulk_none_interrupted)"
                fi ;;
            *)  ga_err "${fcode:-user_del_failed}" "$(tf users_err_del_bulk_none "${fmsg:-$fcode}")" ;;
        esac
        return 1
    fi
    if [ -n "$fcode" ]; then
        log_warning "$(tf users_bulk_del_partial "${#deleted[@]}" "$count" "$(jq -r '.name' <<<"$failed")" "$fmsg")"
    else
        log_success "$(tf users_bulk_deleted "${#deleted[@]}")"
    fi
    jq -cn --argjson req "$count" --argjson d "$(_users_json_names "${deleted[@]}")" --argjson k "$(_users_json_names "${kept[@]}")" \
        --argjson failed "$failed" --arg mode "$_GA_DB_MODE" --arg v "$_GA_DB_VALUE" \
        '{requested: $req, count: ($d | length), deleted: $d, kept: $k, partial: ($failed != null), failed: $failed,
          mode: $mode, value: $v}'
}

users_rename() { ga_with_config_lock _users_rename_locked "$@"; }
_users_rename_locked() {
    local name="$1" label="$2" profiles p
    ga_users_require "$name" || return $?
    if ! ga_users_label_valid "$label"; then
        ga_err invalid_label "$(t users_err_label)" 2
        return 2
    fi
    ga_users_json | jq --arg n "$name" --arg l "$label" '.users |= map(if .name == $n then .label = $l else . end)' \
        | ga_users_write || { ga_err users_write_failed "$(t users_err_write)"; return 1; }
    # Имя живёт только в clientsTable — конфиг и syncconf не нужны.
    profiles=$(ga_users_get "$name" | jq -r '.peers // {} | keys[]')
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        amnezia_clientstable_write "$p" || return 1
    done <<<"$profiles"
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "user-rename" "$name"
    log_success "$(tf users_renamed "$name" "$label")"
}

# enabled + active всех пиров → переписать конфиги профилей пользователя.
# Третий аргумент — почему выключен (disabled_reason): manual — руками (по умолчанию), expiry и
# quota ставит таймер лимитов. У включённого причины нет. Записи без поля (users.json прежних
# версий) — причина неизвестна, и сами такие НЕ включаются никогда (_users_reenable_if_lifted).
ga_users_set_enabled() {
    local name="$1" flag="$2" reason="${3:-manual}" profiles
    ga_users_require "$name" || return $?
    # Пир уходит из конфига контейнера (выключение) или возвращается в него (включение) — его счётчик в
    # контейнере начнётся с нуля. Прежнее показание last_* такому пиру обнуляем: иначе тик квот, увидев после
    # возврата показание больше прежнего, вычитал его, и трафик до этого прежнего числа терялся — лимит
    # срабатывал позже (находка SR-16: 3 ГБ → выкл/вкл → 5 ГБ, насчитано 5 из 8). Только тем, кто правда
    # переходит: пир, который и так в конфиге (включили включённого), счётчик не теряет, и обнуление
    # засчитало бы весь его трафик второй раз.
    ga_users_json | jq --arg n "$name" --argjson f "$flag" --arg r "$reason" \
        '.users |= map(if .name == $n then
            (.enabled == true) as $was_on
            | .enabled = $f
            | .peers |= with_entries(
                (($was_on and ((.value.active // false) == true)) != $f) as $moved
                | .value.active = $f
                | if $moved then .value.last_rx = 0 | .value.last_tx = 0 else . end)
            | del(.disable_pending)
            | (if $f then del(.disabled_reason) else .disabled_reason = $r end) else . end)' \
        | ga_users_write || { ga_err users_write_failed "$(t users_err_write)"; return 1; }
    profiles=$(ga_users_get "$name" | jq -r '.peers // {} | keys[]')
    # shellcheck disable=SC2086
    # Отказ применения — это «выключил, а человек ходит»: он обязан дойти до
    # ответа, а не потеряться под успешной записью в users.json.
    ga_users_apply_many $profiles || return 1
}

# stdin: JSON пользователя → quota | expiry | пусто: какой лимит у него действует прямо сейчас (лимит
# исчерпан — раньше, как и в тике). Одно правило на тик, включение и снятие причины выключения.
_GA_USERS_LIMIT_JQ='if ((.quota_bytes // 0) > 0 and (((.traffic.rx // 0) + (.traffic.tx // 0)) >= (.quota_bytes // 0))) then "quota"
        elif ((.expires // "") != "" and ((.expires | try fromdateiso8601 catch 0) <= $now)) then "expiry"
        else "" end'
ga_users_limit_hit() {
    jq -r --argjson now "$(date -u +%s)" "$_GA_USERS_LIMIT_JQ" 2>/dev/null
}

# ga_users_infer_disabled_reason — миграция (находка UP-2): выключенным без disabled_reason (users.json
# 0.2–0.4.2: прежний тик ставил только enabled=false) — причина по тому же правилу, что у тика: действует
# лимит — quota или expiry (тогда продление включит человека само), нет — manual. stdout: сколько поправлено.
ga_users_infer_disabled_reason() {
    local users out n
    ga_users_load users || return 1
    n=$(jq -r '[.users[]? | select(.enabled == false and ((.disabled_reason // "") == ""))] | length' <<<"$users" 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ] || { echo 0; return 0; }
    out=$(jq -c --argjson now "$(date -u +%s)" "def hit: $_GA_USERS_LIMIT_JQ;
        .users |= map(if .enabled == false and ((.disabled_reason // \"\") == \"\")
            then (hit) as \$h | .disabled_reason = (if \$h != \"\" then \$h else \"manual\" end) else . end)" <<<"$users") || return 1
    printf '%s' "$out" | ga_users_write || return 1
    echo "$n"
}

users_enable() { ga_with_config_lock _users_enable_locked "$@"; }
_users_enable_locked() {
    local name="$1" why
    ga_users_set_enabled "$name" true || return $?
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "user-enable" "$name"
    log_success "$(tf users_enabled "$name")"
    # Включение человека, у которого исчерпан лимит или вышел срок, живёт до
    # ближайшего тика квот (5 минут): _users_quota_tick_locked отбирает
    # ВКЛЮЧЁННЫХ нарушителей и выключает их снова. Отчёт об успехе без единого
    # слова об этом и был ложью. Сами не чиним: поднять лимит или продлить
    # срок — решение администратора (а когда он это сделает, выключенный
    # таймером включится сам — _users_reenable_if_lifted).
    why=$(ga_users_get "$name" | ga_users_limit_hit)
    case "$why" in
        quota)  log_warning "$(tf users_enable_quota_spent "$name")" ;;
        expiry) log_warning "$(tf users_enable_expired "$name")" ;;
    esac
    return 0
}

users_disable() { ga_with_config_lock _users_disable_locked "$@"; }
_users_disable_locked() {
    local name="$1"
    ga_users_set_enabled "$name" false || return $?
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "user-disable" "$name"
    log_success "$(tf users_disabled "$name")"
}

users_set_quota() { ga_with_config_lock _users_set_quota_locked "$@"; }
_users_set_quota_locked() {
    local name="$1" gb="$2" bytes
    ga_users_require "$name" || return $?
    ga_users_check_int "$gb" "$GA_USERS_MAX_QUOTA_GB" "quota_gb" || return $?
    gb=$((10#$gb))
    bytes=$((gb * 1073741824))
    # Новый лимит — новый цикл предупреждений: флаг «80 % уже сообщали» снимается.
    ga_users_json | jq --arg n "$name" --argjson b "$bytes" \
        '.users |= map(if .name == $n then .quota_bytes = $b | del(.notified.quota_80) | (if (.notified // {}) == {} then del(.notified) else . end) else . end)' \
        | ga_users_write || { ga_err users_write_failed "$(t users_err_write)"; return 1; }
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "user-quota" "$name gb=$gb"
    # Строку человеку печатает вызывающий — у меню, бота и панели свои словари
    # и свои слова для нуля («без ограничения», а не «0 ГБ»). Здесь она была
    # второй галочкой на одно действие и тащила в ответ подсказку к вопросу.
    log_to_file "quota $name = ${gb} GB"
    _users_reenable_if_lifted "$name" quota
}

users_set_expiry() { ga_with_config_lock _users_set_expiry_locked "$@"; }
_users_set_expiry_locked() {
    local name="$1" days="$2" expires
    ga_users_require "$name" || return $?
    ga_users_check_int "$days" "$GA_USERS_MAX_DAYS" "days" || return $?
    days=$((10#$days))
    # Смысл days прежний: срок = сейчас + N дней (0 — бессрочно). «Продлить от нынешнего срока»
    # считает вызывающий (кнопка «+30 дней» в боте) и передаёт готовое число дней.
    expires=$(ga_users_expiry_from_days "$days") || return 1
    # Новый срок — новый цикл предупреждений: флаг «о конце срока уже сообщали» снимается.
    ga_users_json | jq --arg n "$name" --arg e "$expires" \
        '.users |= map(if .name == $n then .expires = $e | del(.notified.expiry_soon) | (if (.notified // {}) == {} then del(.notified) else . end) else . end)' \
        | ga_users_write || { ga_err users_write_failed "$(t users_err_write)"; return 1; }
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "user-expiry" "$name days=$days"
    # Строку человеку печатает вызывающий: у меню и бота свои словари, и
    # только там известно, как склонять число дней. Здесь она была второй
    # галочкой на одно действие, да ещё тащила в ответ подсказку к вопросу
    # «(0 = бессрочно)».
    log_to_file "expiry $name = ${days} d"
    _users_reenable_if_lifted "$name" expiry
}

# Продление, которое правда включает. Выключенный ТАЙМЕРОМ (disabled_reason = <причина>) снова
# включается, когда администратор снял именно эту причину (продлил срок / поднял или снял лимит),
# а вторая не действует. Включение — тем же путём, что user-enable (ga_users_set_enabled: пиры
# назад в контейнеры, под тем же замком — мы уже внутри _locked). Вторая причина ещё действует —
# не включаем, а переписываем причину на неё: тогда её снятие и включит (порядок действий
# администратора неважен). Выключенного руками (manual) или без поля (users.json прежних версий —
# причина неизвестна) не включаем никогда: решение за администратором.
# stdout: {name, enabled, re_enabled, disabled_reason, expires, quota_bytes} — мосту и тестам.
_users_reenable_if_lifted() {
    local name="$1" what="$2" user reason enabled still re=false
    user=$(ga_users_get "$name") || return 1
    enabled=$(jq -r '.enabled' <<<"$user")
    reason=$(jq -r '.disabled_reason // ""' <<<"$user")
    if [ "$enabled" != "true" ] && [ "$reason" = "$what" ]; then
        still=$(ga_users_limit_hit <<<"$user")
        if [ -z "$still" ]; then
            ga_users_set_enabled "$name" true || return $?
            ga_audit "${GOAMNEZIA_WHO:-ssh}" "user-enable" "$name reason=${what}_lifted"
            log_success "$(tf users_reenabled "$name")"
            re=true
        else
            if [ "$still" != "$what" ]; then
                ga_users_json | jq --arg n "$name" --arg r "$still" \
                    '.users |= map(if .name == $n then .disabled_reason = $r else . end)' \
                    | ga_users_write || { ga_err users_write_failed "$(t users_err_write)"; return 1; }
            fi
            case "$still" in
                quota)  log_info "$(tf users_hint_still_quota "$name")" ;;
                expiry) log_info "$(tf users_hint_still_expired "$name")" ;;
            esac
        fi
    elif [ "$enabled" != "true" ]; then
        # Выключен по другой причине: подсказка — про ту, что держит (снять её — и включится сам).
        still=""
        case "$reason" in quota|expiry) still=$(ga_users_limit_hit <<<"$user") ;; esac
        case "$still" in
            quota)  log_info "$(tf users_hint_still_quota "$name")" ;;
            expiry) log_info "$(tf users_hint_still_expired "$name")" ;;
            *)      log_info "$(tf users_hint_disabled "$name")" ;;
        esac
    fi
    ga_users_get "$name" | jq -c --argjson re "$re" \
        '{name, enabled, re_enabled: $re, disabled_reason: (.disabled_reason // ""), expires: (.expires // ""), quota_bytes: (.quota_bytes // 0)}'
}

# users_set_endpoint_ip <имя> <IPv4|пусто> — свой адрес сервера в ключах пользователя (несколько
# адресов сервера, docs/EDGEIPS.md §3.1); пусто — общий адрес. Ключи не перевыпускаются: пара та же,
# меняется только строка Endpoint. Адрес должен быть на машине сейчас: ключ с чужим адресом не соединится.
# → {name, endpoint_ip, previous_endpoint_ip, endpoint, resend_required, domain_endpoint}: endpoint — что
# теперь стоит в ключах пользователя; resend_required — адрес в САМОМ ключе изменился, и уже выданный
# конфиг смотрит на прежний; domain_endpoint — общий Endpoint домен, свой адрес не действует. Решает
# модуль, тем же правилом, что собирает ключ: догадка вызывающего «адрес сменили — отправить заново»
# врала бы при доменном Endpoint и при повторе того же адреса.
users_set_endpoint_ip() { ga_with_config_lock _users_set_endpoint_ip_locked "$@"; }
_users_set_endpoint_ip_locked() {
    local name="${1:-}" ip="${2:-}" addrs prev before="" after="" resend=false domain=false
    ga_users_require "$name" || return $?
    if [ -n "$ip" ]; then
        # 0.0.0.0 проходит проверку формы, но адресом сервера не бывает: ключ с ним не соединится.
        if ! _valid_ip "$ip" || [ "$ip" = "0.0.0.0" ]; then
            ga_err invalid_ip "$(tf users_err_endpoint_ip "$ip")" 2
            return 2
        fi
        # Свой адрес — только из тех, что машина видит у себя. Пустой список (сервер за NAT, нет команды
        # ip) — отказ, а не пропуск проверки: иначе любой адрес, опечатка или выдуманный, уезжал в ключи
        # с советом «отправьте человеку». Выдача ключа при пустом списке мягче (ga_export_endpoint_host):
        # там отказ по догадке оставил бы человека без ключа, а здесь проверить адрес просто нечем.
        addrs=""
        if type ga_edge_list >/dev/null 2>&1; then
            addrs=$(ga_edge_list 2>/dev/null)
        fi
        if [ -z "$addrs" ]; then
            ga_err addresses_unknown "$(tf users_err_endpoint_ip_unknown "$ip")" 2
            return 2
        fi
        if ! grep -qxF "$ip" <<<"$addrs"; then
            ga_err address_not_here "$(tf users_err_endpoint_ip_not_here "$ip" "$(tr '\n' ' ' <<<"$addrs")")" 2
            return 2
        fi
        # Свой адрес, равный общему адресу в ключах, — это «как у всех»: пишем пусто. Иначе в записи застывала
        # копия: владелец потом менял общий адрес, а у этого человека оставался прежний (находка SR-49; SSH в
        # этом случае и так пишет пусто).
        if type _ga_edge_common_endpoint >/dev/null 2>&1 && [ "$ip" = "$(_ga_edge_common_endpoint 2>/dev/null)" ]; then
            ip=""
        fi
    fi
    prev=$(ga_users_get "$name" | jq -r '.endpoint_ip // ""')
    # Адрес в ключе до записи и после — той же функцией, что собирает ключ. Адрес, пропавший с машины
    # (код 2), значит «ключа не было»: после смены конфиг нужен новый.
    if type ga_export_endpoint_host >/dev/null 2>&1; then
        before=$(ga_export_endpoint_host "$name" 2>/dev/null) || before=""
    fi
    ga_users_json | jq --arg n "$name" --arg ip "$ip" \
        '.users |= map(if .name == $n then (if $ip == "" then del(.endpoint_ip) else .endpoint_ip = $ip end) else . end)' \
        | ga_users_write || { ga_err users_write_failed "$(t users_err_write)"; return 1; }
    if type ga_export_endpoint_host >/dev/null 2>&1; then
        after=$(ga_export_endpoint_host "$name" 2>/dev/null) || after=""
        [ -n "$after" ] && [ "$after" != "$before" ] && resend=true
        [ -n "$after" ] && ! _valid_ip "$after" && domain=true
    elif [ "$prev" != "$ip" ]; then
        # Сборщика ключа нет (модуль выдачи не загружен) — судим по самому полю: «отправлять не нужно»
        # без проверки было бы неправдой.
        resend=true
    fi
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "user-set-address" "$name ip=${ip:--}"
    log_to_file "endpoint_ip $name = ${ip:--}"
    jq -cn --arg n "$name" --arg ip "$ip" --arg prev "$prev" --arg host "$after" \
        --argjson resend "$resend" --argjson domain "$domain" \
        '{name: $n, endpoint_ip: $ip, previous_endpoint_ip: $prev, endpoint: $host,
          resend_required: $resend, domain_endpoint: $domain}'
}

users_add_peer() { ga_with_config_lock _users_add_peer_locked "$@"; }
_users_add_peer_locked() {
    local name="$1" profile="$2" user peer enabled
    local GA_EXPECT_DROP=""   # см. _users_add_locked: локальная и самосбрасывающаяся
    ga_users_require "$name" || return $?
    ga_profile_check_installed "$profile" || return $?
    user=$(ga_users_get "$name")
    if [ "$(jq -r --arg p "$profile" '.peers[$p] != null' <<<"$user")" = "true" ]; then
        ga_err peer_exists "$(tf users_err_peer_exists "$name" "$(ga_amn_profile_label "$profile")")"
        return 1
    fi
    ga_capture peer ga_users_new_peer "$profile" || return 1
    enabled=$(jq -r '.enabled' <<<"$user")
    # Пир выключенного пользователя создаётся, но в конфиг не попадает. Пир с приватным ключом — окружением,
    # не аргументом jq (SR-17).
    ga_users_json | GA_S_PEER="$peer" jq --arg n "$name" --arg p "$profile" --argjson en "$enabled" \
        '($ENV.GA_S_PEER | fromjson) as $peer | .users |= map(if .name == $n then .peers[$p] = ($peer | .active = $en) else . end)' \
        | ga_users_write || { ga_err users_write_failed "$(t users_err_write)"; return 1; }
    # Тот же случай: код возврата берём до отрицания
    local _peer_rc=0
    _users_apply_profile_locked "$profile" || _peer_rc=$?
    if [ "$_peer_rc" -ne 0 ]; then
        # Откатываем пир по той же причине, что и в users_add, и по той же
        # причине переприменяем профиль: применение — цепочка из четырёх шагов,
        # и оборваться она могла уже ПОСЛЕ того, как конфиг с новым пиром лёг в
        # контейнер (сорвался syncconf или копия состояния).
        GA_EXPECT_DROP=$(jq -r '.pubkey // empty' <<<"$peer")
        ga_users_json | jq --arg n "$name" --arg p "$profile" \
            '.users |= map(if .name == $n then del(.peers[$p]) else . end)' | ga_users_write \
            || log_error "$(t users_err_write)"
        _users_apply_profile_locked "$profile" || log_warning "$(tf users_warn_rollback_apply "$name")"
        ga_audit "${GOAMNEZIA_WHO:-ssh}" "user-add-peer" "$name $profile apply=failed rollback=done"
        return "$_peer_rc"
    fi
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "user-add-peer" "$name $profile"
    log_success "$(tf users_peer_added "$name" "$(ga_amn_profile_label "$profile")")"
}

# users_reissue_peer <имя> <профиль> — ЗАМЕНА пира новым ключом одним шагом.
#
# Раньше перевыпуск собирался из пары «снять, потом выдать» в каждом из трёх
# интерфейсов: меню, бот, панель. Это тот самый образец, который договор
# запрещает, — один порядок действий в трёх копиях, и каждая по-своему
# обрабатывает отказ на середине. Хуже того, между двумя вызовами есть окно:
# оборвалась сессия SSH, закрылась вкладка панели, упал бот — и человек остаётся
# БЕЗ доступа на профиль, хотя просил всего лишь новый ключ.
#
# Здесь новый пир подменяет старый ОДНОЙ записью под общим замком: если
# применение к контейнеру сорвалось, возвращается прежний пир и профиль
# переприменяется — человек остаётся с тем ключом, с которым пришёл.
users_reissue_peer() { ga_with_config_lock _users_reissue_peer_locked "$@"; }
_users_reissue_peer_locked() {
    local name="$1" profile="$2" user old peer enabled rc=0
    local GA_EXPECT_DROP=""   # см. _users_del_locked: локальная и самосбрасывающаяся
    ga_users_require "$name" || return $?
    ga_profile_check_installed "$profile" || return $?
    user=$(ga_users_get "$name")
    old=$(jq -c --arg p "$profile" '.peers[$p] // empty' <<<"$user")
    if [ -z "$old" ]; then
        ga_err peer_not_found "$(tf users_err_peer_not_found "$name" "$(ga_amn_profile_label "$profile")")"
        return 1
    fi
    ga_capture peer ga_users_new_peer "$profile" || return 1
    # Адрес оставляем прежний: перевыпуск меняет КЛЮЧ, а не место человека в
    # подсети. Иначе каждый перевыпуск сдвигал бы адрес, а всё, что на него
    # смотрит — журнал, правила, чужие заметки — переставало сходиться.
    # Старый и новый пиры несут приватные ключи — окружением, не аргументами jq (SR-17).
    peer=$(GA_S_OLD="$old" jq -c '($ENV.GA_S_OLD | fromjson) as $old | .ip = ($old.ip // .ip)' <<<"$peer") || return 1
    enabled=$(jq -r '.enabled' <<<"$user")
    # Старый открытый ключ пропадёт из конфига контейнера ожидаемо — сторож не
    # должен считать это чужой правкой.
    GA_EXPECT_DROP=$(jq -r '.pubkey // empty' <<<"$old")
    ga_users_json | GA_S_PEER="$peer" jq --arg n "$name" --arg p "$profile" --argjson en "$enabled" \
        '($ENV.GA_S_PEER | fromjson) as $peer | .users |= map(if .name == $n then .peers[$p] = ($peer | .active = $en) else . end)' \
        | ga_users_write || { ga_err users_write_failed "$(t users_err_write)"; return 1; }
    _users_apply_profile_locked "$profile" || rc=$?
    if [ "$rc" -ne 0 ]; then
        GA_EXPECT_DROP=$(jq -r '.pubkey // empty' <<<"$peer")
        ga_users_json | GA_S_OLD="$old" jq --arg n "$name" --arg p "$profile" \
            '($ENV.GA_S_OLD | fromjson) as $old | .users |= map(if .name == $n then .peers[$p] = $old else . end)' | ga_users_write \
            || log_error "$(t users_err_write)"
        _users_apply_profile_locked "$profile" || log_warning "$(tf users_warn_rollback_apply "$name")"
        ga_audit "${GOAMNEZIA_WHO:-ssh}" "user-reissue-peer" "$name $profile apply=failed rollback=done"
        return "$rc"
    fi
    GA_EXPECT_DROP=""
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "user-reissue-peer" "$name $profile"
    return 0
}

# Привязка старого ключа (подхват из приложения Amnezia). Человеку ключ выдало
# приложение, у сервера от него только открытая часть: ни .conf, ни ссылку, ни QR
# по такому пиру не собрать, и раньше выход был один — перевыпуск, который
# отключает человека. Но приватный ключ лежит в ссылке vpn:// или .conf, которые
# админ когда-то отправил человеку (приложение его не хранит — в бэкапе
# приложения его тоже нет). Проверяем, что ключ ЭТОГО человека: открытый ключ,
# посчитанный из приватного, совпадает с его пиром, — и кладём приватный в
# users.json. Контейнер не трогаем: пир в нём тот же, у человека не меняется
# ничего. Профиль можно не называть — найдётся по совпавшему пиру.
#
#   users_attach_key <имя> <профиль|""> <ссылка или текст .conf>
#
# stdout: JSON {name, profile, line}. Ключ — третьим аргументом функции, в
# argv внешних процессов он не попадает: awgkeys.py читает его из stdin, jq —
# из окружения.
users_attach_key() { ga_with_config_lock _users_attach_key_locked "$@"; }
_users_attach_key_locked() {
    local name="$1" profile="${2:-}" material="${3:-}" parsed priv pub srv user peer owner p line
    ga_users_require "$name" || return $?
    [ -z "$profile" ] || ga_profile_check_installed "$profile" || return $?
    if [ -z "${material//[[:space:]]/}" ]; then
        ga_err no_config "$(t users_err_no_config)" 2
        return 2
    fi
    if ! parsed=$(printf '%s' "$material" | ga_awgkeys client-key 2>/dev/null) || [ -z "$parsed" ]; then
        ga_err config_unreadable "$(t users_err_config_unreadable)" 2
        return 2
    fi
    priv=$(jq -r '.privkey // ""' <<<"$parsed")
    pub=$(jq -r '.pubkey // ""' <<<"$parsed")
    srv=$(jq -r '.server_pubkey // ""' <<<"$parsed")
    parsed=""
    # Вставили СЕРВЕРНЫЙ конфиг профиля (state/…/awg0.conf, снимок подхвата): его «ключ» — ключ самого
    # сервера, и раньше это объявлялось «ключом от другого сервера» (находка TK-8). Нужен ключ человека.
    if [ -n "$pub" ] && _users_server_key_known "$pub"; then
        priv=""
        ga_err config_unreadable "$(t users_err_server_conf)" 2
        return 2
    fi
    user=$(ga_users_get "$name")
    # Пир, которому принадлежит ключ: в названном профиле или в любом.
    if [ -n "$profile" ]; then
        if [ "$(jq -r --arg p "$profile" '.peers[$p] != null' <<<"$user")" != true ]; then
            ga_err peer_not_found "$(tf users_err_peer_not_found "$name" "$(ga_amn_profile_label "$profile")")" 3
            return 3
        fi
        [ "$(jq -r --arg p "$profile" '.peers[$p].pubkey // ""' <<<"$user")" = "$pub" ] || profile="!$profile"
    else
        profile=$(jq -r --arg k "$pub" '(.peers // {}) | to_entries[] | select(.value.pubkey == $k) | .key' <<<"$user" | head -n 1)
    fi
    # Ключ этого же человека, но с другого профиля (открыта не та вкладка, или вставлен .conf, выданный
    # продуктом на awg3): раньше это называлось «ключ anna, а не anna» (находка TK-5). Ключ принадлежит
    # человеку — привязываем его к тому профилю, чей он, как и без названного профиля, и говорим об этом.
    local mine=""
    if [ "${profile#!}" != "$profile" ]; then
        mine=$(jq -r --arg k "$pub" '(.peers // {}) | to_entries[] | select(.value.pubkey == $k) | .key' <<<"$user" | head -n 1)
        if [ -n "$mine" ]; then
            log_info "$(tf users_key_other_profile "$name" "$(ga_amn_profile_label "$mine")" "$(ga_amn_profile_label "${profile#!}")" "$(ga_amn_profile_label "$mine")")"
            profile="$mine"
        fi
    fi
    if [ -z "$profile" ] || [ "${profile#!}" != "$profile" ]; then
        p="${profile#!}"
        # Чей же это ключ: другого человека на этом сервере — назовём его;
        # ни одного профиля этого сервера — значит, ключ от другого сервера.
        owner=$(ga_users_json | jq -r --arg k "$pub" '.users[]? | select([(.peers // {})[] | .pubkey] | index($k)) | .name' | head -n 1)
        if [ -n "$owner" ]; then
            ga_err key_mismatch "$(tf users_err_key_other_user "$owner" "$name" "$owner")"
        elif [ -n "$srv" ] && ! _users_server_key_known "$srv"; then
            ga_err server_mismatch "$(t users_err_server_mismatch)"
        else
            ga_err key_mismatch "$(tf users_err_key_mismatch "$name" "${p:-$(jq -r '(.peers // {}) | keys | join(", ")' <<<"$user")}")"
        fi
        return 1
    fi
    peer=$(jq -c --arg p "$profile" '.peers[$p]' <<<"$user")
    if [ -n "$(jq -r '.privkey // ""' <<<"$peer")" ]; then
        ga_err already_has_key "$(tf users_err_already_has_key "$name" "$(ga_amn_profile_label "$profile")")"
        return 1
    fi
    ga_users_json | GA_ATTACH_PRIV="$priv" jq --arg n "$name" --arg p "$profile" --arg now "$(ga_now)" \
        '.users |= map(if .name == $n then .peers[$p] += {privkey: $ENV.GA_ATTACH_PRIV, key_attached_at: $now} else . end)' \
        | ga_users_write || { ga_err users_write_failed "$(t users_err_write)"; return 1; }
    priv=""
    line=$(ga_profile_line "$profile" 2>/dev/null) || line=""
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "user-attach-key" "name=$name profile=$profile"
    log_success "$(tf users_key_attached "$name" "$(ga_amn_profile_label "$profile")")"
    jq -cn --arg n "$name" --arg p "$profile" --arg line "$line" '{name: $n, profile: $p, line: $line}'
}

# Открытый ключ сервера — одного из наших профилей?
_users_server_key_known() {
    local k="$1" p
    for p in $(ga_profiles_installed 2>/dev/null); do
        [ "$(ga_profile_field "$p" server_pubkey 2>/dev/null)" = "$k" ] && return 0
    done
    return 1
}

users_del_peer() { ga_with_config_lock _users_del_peer_locked "$@"; }
_users_del_peer_locked() {
    local name="$1" profile="$2" user
    local GA_EXPECT_DROP=""   # см. _users_del_locked
    ga_users_require "$name" || return $?
    ga_profile_check "$profile" || return $?
    user=$(ga_users_get "$name")
    if [ "$(jq -r --arg p "$profile" '.peers[$p] != null' <<<"$user")" != "true" ]; then
        ga_err peer_not_found "$(tf users_err_peer_not_found "$name" "$(ga_amn_profile_label "$profile")")" 3
        return 3
    fi
    GA_EXPECT_DROP=$(jq -r --arg p "$profile" '.peers[$p].pubkey // empty' <<<"$user")
    ga_users_json | jq --arg n "$name" --arg p "$profile" '.users |= map(if .name == $n then del(.peers[$p]) else . end)' \
        | ga_users_write || { ga_err users_write_failed "$(t users_err_write)"; return 1; }
    if ga_profile_installed "$profile"; then
        _users_apply_profile_locked "$profile" || {
            GA_EXPECT_DROP=""
            ga_audit "${GOAMNEZIA_WHO:-ssh}" "user-del-peer" "$name $profile apply=failed"
            return 1
        }
    fi
    GA_EXPECT_DROP=""
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "user-del-peer" "$name $profile"
    log_success "$(tf users_peer_deleted "$name" "$(ga_amn_profile_label "$profile")")"
    # Страницы подключения человека, где после снятия не осталось ни одного ключа, — снимаем (UI-4c).
    ga_users_pages_prune_locked "$name"
    return 0
}

# ga_users_pages_prune_locked [имя] — снять страницы подключения, на которых у человека не осталось ни
# одного профиля с ключом (с приватной частью). Раньше их снимало только удаление человека: после «Отобрать
# ключ на профиль» страница продолжала отвечать одной справкой, а в списках её никто не замечал, — и стоило
# потом выдать ключ на тот же профиль снова, забытая ссылка опять отдавала настоящий ключ (находка UI-4,
# 25.09.2026). Без имени — по всем людям (удаление профиля целиком). Зовётся под замком; без модуля страниц —
# нечего снимать. Каждая снятая страница уходит в аудит (page-revoke) из lib/pages.sh.
ga_users_pages_prune_locked() {
    local only="${1:-}" dir d who keyed n=0 users
    type ga_pages_dir >/dev/null 2>&1 && type ga_pages_drop >/dev/null 2>&1 || return 0
    dir=$(ga_pages_dir)
    [ -d "$dir" ] || return 0
    ga_users_load users 2>/dev/null || return 0
    for d in "$dir"/p-*; do
        [ -f "$d/meta.json" ] || continue
        who=$(jq -r '.user // ""' "$d/meta.json" 2>/dev/null) || continue
        [ -n "$who" ] || continue
        [ -z "$only" ] || [ "$who" = "$only" ] || continue
        keyed=$(jq -c --arg n "$who" '[.users[]? | select(.name == $n) | .peers // {} | to_entries[]
            | select((.value.privkey // "") != "") | .key]' <<<"$users" 2>/dev/null) || continue
        [ -n "$keyed" ] || keyed='[]'
        if jq -e --argjson k "$keyed" '[(.profiles // [])[] | select(. as $p | $k | index($p) != null)] | length == 0' \
                "$d/meta.json" >/dev/null 2>&1; then
            ga_pages_drop "$d" revoked
            n=$((n + 1))
            log_info "$(tf users_page_revoked_no_keys "$(basename "$d")" "$who")"
        fi
    done
    [ "$n" -gt 0 ] || return 0
    # Страниц не осталось — маршрут и служба снимаются, как у pages_revoke.
    if type ga_pages_count >/dev/null 2>&1 && [ "$(ga_pages_count)" -eq 0 ] && type _pages_disable_locked >/dev/null 2>&1; then
        _pages_disable_locked >/dev/null 2>&1 || true
    fi
    return 0
}

# ga_users_pages_lost_json <профиль> → JSON {pages: N, users: [имена]} — страницы подключения, которые снимет удаление
# этого профиля (PROFILE-REMOVE-PAGES): в странице был только он — из профилей страницы ключ с приватной частью у
# человека есть только на нём. Правило то же, что у ga_users_pages_prune_locked после удаления; страницы, которые уже
# сейчас без ключей, сюда не входят (снимет их не удаление профиля). Адрес страницы (секрет) не отдаётся — только имена.
# Нет модуля страниц, каталога или пользователей — {pages: 0, users: []}.
ga_users_pages_lost_json() {
    local profile="$1" dir d who users n=0 lost='[]'
    type ga_pages_dir >/dev/null 2>&1 || { printf '{"pages":0,"users":[]}'; return 0; }
    dir=$(ga_pages_dir)
    [ -d "$dir" ] || { printf '{"pages":0,"users":[]}'; return 0; }
    ga_users_load users 2>/dev/null || { printf '{"pages":0,"users":[]}'; return 0; }
    # {имя: [профили с приватной частью ключа]} — без самих ключей: так его можно отдать jq аргументом.
    local keyed
    keyed=$(jq -c '[.users[]? | {key: .name, value: [(.peers // {}) | to_entries[]
        | select((.value.privkey // "") != "") | .key]}] | from_entries' <<<"$users" 2>/dev/null) || keyed='{}'
    for d in "$dir"/p-*; do
        [ -f "$d/meta.json" ] || continue
        who=$(jq -r '.user // ""' "$d/meta.json" 2>/dev/null) || continue
        [ -n "$who" ] || continue
        if jq -e --arg n "$who" --arg p "$profile" --argjson k "$keyed" '
                ($k[$n] // []) as $mine
                | [(.profiles // [])[] | select(. as $x | $mine | index($x) != null)] as $live
                | ($live | length) > 0 and ($live | all(. == $p))' "$d/meta.json" >/dev/null 2>&1; then
            n=$((n + 1))
            lost=$(jq -c --arg n "$who" 'if index($n) then . else . + [$n] end' <<<"$lost")
        fi
    done
    jq -cn --argjson n "$n" --argjson u "$lost" '{pages: $n, users: $u}'
}

# Новые ключи всех пиров профиля (после profile-regen): IP и дата создания
# остаются, active — как было. Старые .conf у клиентов перестают работать.
users_reissue_profile() { ga_with_config_lock _users_reissue_profile_locked "$@"; }
_users_reissue_profile_locked() {
    local profile="$1" users names n priv pub psk count=0
    ga_profile_check_installed "$profile" || return $?
    users=$(ga_users_json) || return $?   # битый users.json — отказ, а не пустой список
    names=$(jq -r --arg p "$profile" '.users[]? | select(.peers[$p] != null) | .name' <<<"$users")
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        priv=$(ga_awgkeys genkey) || return 1
        pub=$(ga_awgkeys_pubkey "$priv") || return 1
        psk=$(ga_awgkeys genpsk) || return 1
        # Приватный ключ и PSK — окружением, не аргументами jq (SR-17).
        users=$(GA_S_PRIV="$priv" GA_S_PSK="$psk" jq -c --arg n "$n" --arg p "$profile" --arg pub "$pub" \
            '.users |= map(if .name == $n then .peers[$p] += {privkey: $ENV.GA_S_PRIV, pubkey: $pub, psk: $ENV.GA_S_PSK,
                                                            last_handshake: 0, last_rx: 0, last_tx: 0} else . end)' <<<"$users") || return 1
        count=$((count + 1))
    done <<<"$names"
    printf '%s' "$users" | ga_users_write || { ga_err users_write_failed "$(t users_err_write)"; return 1; }
    _users_apply_profile_locked "$profile" || return 1
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "users-reissue" "$profile count=$count"
    log_success "$(tf users_reissued "$profile" "$count")"
}

# Новые адреса всем пирам профиля по порядку записей users.json (.1, .2, …) в
# новой подсети; ключи, PSK и даты не меняются. Трогает только users.json:
# серверный конфиг и контейнер переписывает amnezia_profile_set_subnet, чьим
# шагом эта функция и является; вызванная отдельно, требует users_apply_profile
# следом. stdout: JSON [{name, old_ip, ip}].
users_renumber_profile() { ga_with_config_lock _users_renumber_profile_locked "$@"; }
_users_renumber_profile_locked() {
    local profile="$1" cidr="${2:-}" parsed base size names n old ip users changes='[]' i=0
    ga_profile_check_installed "$profile" || return $?
    if ! parsed=$(ga_cidr_parse "$cidr"); then
        ga_err invalid_subnet "$(tf users_err_subnet "$cidr")" 2
        return 2
    fi
    read -r base size _ <<<"$parsed"
    users=$(ga_users_json) || return $?   # см. комментарий у ga_users_json
    names=$(jq -r --arg p "$profile" '.users[]? | select(.peers[$p] != null) | .name' <<<"$users")
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        i=$((i + 1))
        # Последний адрес сети — broadcast, в него пира не сажаем.
        if [ "$i" -ge $((size - 1)) ]; then
            ga_err subnet_full "$(tf users_err_subnet_full "$profile" "$((size - 2))")"
            return 1
        fi
        ip=$(ga_int2ip $((base + i)))
        old=$(jq -r --arg n "$n" --arg p "$profile" '.users[] | select(.name == $n) | .peers[$p].ip // ""' <<<"$users")
        changes=$(jq -c --arg n "$n" --arg old "$old" --arg ip "$ip" '. + [{name: $n, old_ip: $old, ip: $ip}]' <<<"$changes") || return 1
        users=$(jq -c --arg n "$n" --arg p "$profile" --arg ip "$ip" \
            '.users |= map(if .name == $n then .peers[$p].ip = $ip else . end)' <<<"$users") || return 1
    done <<<"$names"
    printf '%s' "$users" | ga_users_write || { ga_err users_write_failed "$(t users_err_write)"; return 1; }
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "users-renumber" "$profile $cidr count=$i"
    log_success "$(tf users_renumbered "$profile" "$i" "$cidr")"
    printf '%s\n' "$changes"
}

# ── Хост Endpoint и DNS в ключах ──────────────────────────────────────────────

# ga_set_client_dns <dns1> [dns2] — DNS клиентских конфигов (контракт §3.1).
# Отдельная функция, а не сборка JSON на месте вызова: адрес приходит снаружи
# (бот, панель, агент, мастер), и проверять его надо ЗДЕСЬ — иначе в
# client_dns оседает 999.999.999.999, а виден он только тем, у кого туннель
# встал и не резолвит. Пустой второй адрес — законный случай (один DNS).
ga_set_client_dns() { ga_with_config_lock _ga_set_client_dns_locked "$@"; }
_ga_set_client_dns_locked() {
    local dns1="${1:-}" dns2="${2:-}" list
    if ! _valid_ip "$dns1"; then
        ga_err invalid_dns "$(tf users_err_dns "$dns1")" 2
        return 2
    fi
    if [ -n "$dns2" ] && ! _valid_ip "$dns2"; then
        ga_err invalid_dns "$(tf users_err_dns "$dns2")" 2
        return 2
    fi
    list=$(jq -cn --arg a "$dns1" --arg b "$dns2" '[$a, $b] | map(select(. != ""))') || {
        ga_err config_write_failed "$(t amnezia_err_config)"; return 1; }
    ga_config_merge "$(jq -cn --argjson d "$list" '{client_dns: $d}')" \
        || { ga_err config_write_failed "$(t amnezia_err_config)"; return 1; }
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "dns-set" "${dns1} ${dns2:--}"
    # Один адрес — одной строкой, без «, -» на месте второго (находка SR-53).
    if [ -n "$dns2" ]; then log_success "$(tf users_dns_set "$dns1" "$dns2")"; else log_success "$(tf users_dns_set_one "$dns1")"; fi
    printf '%s\n' "$list"
}

# ga_set_endpoint_host <хост> — домен или IPv4 для Endpoint выдаваемых ключей,
# пусто = по умолчанию: в режиме Pro домен сервера, иначе IP сервера (ga_export_endpoint_host).
# Только config.json: уже выданные конфиги не меняются, export_* читают endpoint_host при
# каждой сборке ключа.
ga_set_endpoint_host() { ga_with_config_lock _ga_set_endpoint_host_locked "$@"; }
_ga_set_endpoint_host_locked() {
    local host="${1:-}" shown
    # Своя регулярка здесь принимала 999.999.999.999: её IPv4-ветка проверяла
    # ВИД адреса, а не значения октетов. Общая проверка (lib/common.sh) сама
    # решает, имя перед ней или адрес, — законный домен по-прежнему проходит.
    # 0.0.0.0 проходит проверку формы, но адресом сервера не бывает: «IP сервера» из старого конфига, где
    # осел неудачный поиск адреса, вписал бы его, и ключи перестали бы выдаваться вовсе.
    if [ -n "$host" ] && { [ "$host" = 0.0.0.0 ] || ! ga_valid_host "$host"; }; then
        ga_err invalid_host "$(tf users_err_endpoint_host "$host")" 2
        return 2
    fi
    # Вписан IP, которого на машине нет (проброс портов, балансировщик), — запоминаем, что он чужой
    # НАМЕРЕННО: после переезда сервера проверка адреса снимает вписанный IP, пропавший вместе со старой
    # машиной, а такой — оставляет (находка SR-45, 25.09.2026). Адресов машины не узнать (NAT) — не чужой.
    local foreign=false own=""
    if [ -n "$host" ] && _valid_ip "$host" && type ga_edge_list >/dev/null 2>&1; then
        own=$(ga_edge_list 2>/dev/null)
        if [ -n "$own" ]; then
            own+=$'\n'"$(ga_config_get .server_ip 2>/dev/null)"
            grep -qxF -- "$host" <<<"$own" || foreign=true
        fi
    fi
    ga_config_merge "$(jq -cn --arg h "$host" --argjson f "$foreign" '{endpoint_host: $h, endpoint_host_foreign: $f}')" \
        || { ga_err config_write_failed "$(t amnezia_err_config)"; return 1; }
    # Что теперь в ключах — той же функцией, что их собирает: пустое поле называлось «IP сервера» и
    # в Pro, где ключи уходят с доменом.
    shown="$host"
    if [ -z "$shown" ] && type ga_export_endpoint_host >/dev/null 2>&1; then
        shown=$(ga_export_endpoint_host 2>/dev/null) || shown=""
    fi
    [ -n "$shown" ] || shown=$(ga_config_get ".server_ip" 2>/dev/null)
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "endpoint-set" "${host:--}"
    log_success "$(tf users_endpoint_set "${shown:--}")"
}

# ── Таймер лимитов и сроков ───────────────────────────────────────────────────

# goamnezia-quota.timer → users_quota_tick: awg show по каждому профилю →
# дельты → лимиты и сроки → выключение + событие в очередь бота.
users_quota_tick() { ga_with_config_lock _users_quota_tick_locked "$@"; }
_users_quota_tick_locked() {
    local users profile show now now_ts victims name reason affected="" p container state
    local profiles stale="" failed="" victim_profiles warns warn_filter
    users=$(ga_users_json) || return $?   # таймер лимитов на битом файле молчать не должен
    # Битый config.json молчать не должен ровно по той же причине: пустой список
    # профилей — это «лимиты и сроки никому не применены», а не «применять
    # некому», и отчёт об успехе на таком тике прячет отказ насовсем.
    ga_profiles_load profiles || { ga_err config_corrupt "$(t err_config_unreadable)"; return 1; }
    now=$(ga_now)
    now_ts=$(date -u +%s)
    for profile in $profiles; do
        # «Демон Docker не отвечает» — НЕ то же самое, что «у профиля нет
        # трафика». Раньше awg show в этом случае молча падал, цикл шёл дальше
        # по `|| continue`, и тик отчитывался success с нулями: лимиты и сроки
        # переставали работать, а по логам всё было хорошо. Такое молчание
        # опаснее ложной тревоги — отказываемся вслух, с кодом для моста.
        container=$(ga_profile_field "$profile" container)
        state=$(docker_container_state "$container")
        if [ "$state" = "$GA_DOCKER_STATE_UNREACHABLE" ]; then
            ga_err docker_unreachable "$(t docker_err_unreachable)" 1
            return 1
        fi
        show=$(amnezia_show "$profile" 2>/dev/null) || continue
        # Пустой список «[]» — тоже ответ: пиров в интерфейсе нет, и их показания ниже обнуляются.
        [ -n "$show" ] || continue
        # users.json и показания пиров — через stdin: аргументом jq они упирались бы в предел
        # 128 КБ на один аргумент (как в SR-09).
        # Пира опрошенный профиль не показывает (снят из конфига, контейнер пересоздан) — его счётчик в
        # контейнере начнётся с нуля, и прежнее показание обнуляем: иначе после возврата трафик до этого
        # числа терялся (находка SR-16).
        users=$(printf '%s\n%s\n' "$users" "$show" | jq -cn --arg p "$profile" --arg now "$now" '
            input as $u | input as $show | $u
            | ($show | map({key: .pubkey, value: .}) | from_entries) as $by
            | .users |= map(
                if (.peers[$p] // null) == null then . else
                  (.peers[$p]) as $peer
                  | ($by[$peer.pubkey] // null) as $s
                  | if $s == null then (.peers[$p].last_rx = 0 | .peers[$p].last_tx = 0) else
                      (if $s.rx < ($peer.last_rx // 0) then $s.rx else $s.rx - ($peer.last_rx // 0) end) as $drx
                      | (if $s.tx < ($peer.last_tx // 0) then $s.tx else $s.tx - ($peer.last_tx // 0) end) as $dtx
                      | .peers[$p].rx = (($peer.rx // 0) + $drx)
                      | .peers[$p].tx = (($peer.tx // 0) + $dtx)
                      | .peers[$p].last_rx = $s.rx
                      | .peers[$p].last_tx = $s.tx
                      | .peers[$p].last_handshake = (if $s.latest_handshake_ts > 0 then $s.latest_handshake_ts else ($peer.last_handshake // 0) end)
                      | .traffic.rx = ((.traffic.rx // 0) + $drx)
                      | .traffic.tx = ((.traffic.tx // 0) + $dtx)
                      | .traffic.updated = $now
                    end
                end)') || { ga_err users_write_failed "$(t users_err_tick)"; return 1; }
        # Профиль, в живом контейнере которого ещё стоит пир выключенного человека, применяем
        # заново: так выключение, не дошедшее до контейнера на прошлом тике (контейнер лежал),
        # догоняет само, и откатывать его ради повтора не нужно (находка SR-07, 25.09.2026).
        if printf '%s\n%s\n' "$users" "$show" | jq -en --arg p "$profile" '
            input as $u | input as $show
            | [$u.users[]? | select(.enabled == false or (.peers[$p].active // true) == false) | .peers[$p].pubkey // empty] as $off
            | ($show | map(.pubkey)) as $live
            | any($off[]; . as $k | ($live | index($k)) != null)' >/dev/null 2>&1; then
            stale+=$'\n'"$profile"
        fi
    done
    users=$(printf '%s' "$users" | jq -c '.users |= map(
        .traffic.last_rx = ([.peers[]? | .last_rx // 0] | add // 0)
        | .traffic.last_tx = ([.peers[]? | .last_tx // 0] | add // 0))') || return 1
    # Кто превысил лимит или просрочен (среди включённых): имя<TAB>причина. Плюс те, чьё
    # выключение на прошлом тике не дошло до какого-то контейнера (disable_pending): их
    # профили применяем снова, а событие владельцу уходит, когда дойдёт (SR-07).
    victims=$(printf '%s' "$users" | jq -r --argjson now "$now_ts" '.users[]?
        | if ((.disable_pending // "") != "") then "\(.name)\t\(.disable_pending)"
          elif (.enabled != true) then empty
          elif ((.quota_bytes // 0) > 0 and ((.traffic.rx // 0) + (.traffic.tx // 0)) >= .quota_bytes) then "\(.name)\tquota_exceeded"
          elif ((.expires // "") != "" and ((.expires | try fromdateiso8601 catch 0) <= $now)) then "\(.name)\texpired"
          else empty end')
    # disabled_reason — ЗАЧЕМ выключили: продление срока или новый лимит включат человека сами
    # (_users_reenable_if_lifted), а выключенного руками — никогда.
    while IFS=$'\t' read -r name reason; do
        [ -n "$name" ] || continue
        # Пир уходит из конфига — прежнее показание обнуляем, как при выключении руками (SR-16).
        users=$(printf '%s' "$users" | jq -c --arg n "$name" --arg r "$reason" '.users |= map(if .name == $n then
            (.enabled == true) as $was_on | .enabled = false
            | .peers |= with_entries((($was_on and ((.value.active // false) == true))) as $moved | .value.active = false
                | if $moved then .value.last_rx = 0 | .value.last_tx = 0 else . end)
            | .disabled_reason = (if $r == "quota_exceeded" then "quota" else "expiry" end) else . end)')
        affected+=$'\n'$(printf '%s' "$users" | jq -r --arg n "$name" '.users[] | select(.name == $n) | .peers // {} | keys[]')
    done <<<"$victims"
    # Предупредить ДО того, как сломается: срок кончается в ближайшие GA_USERS_WARN_EXPIRY_DAYS суток
    # (expiry_soon) или израсходовано ≥ GA_USERS_WARN_QUOTA_PCT % лимита (quota_80). Одно событие на
    # пользователя и на значение: notified.* хранит, О ЧЁМ уже сказали (дату срока, размер лимита).
    # Условие ушло (продлили, подняли лимит, счётчик обнулили) — флаг снимается, и следующий цикл
    # сможет предупредить снова; продление и новый лимит снимают его и сразу (set_expiry/set_quota).
    # Выключенных (в том числе только что, выше) не предупреждаем — им уже пришло своё событие.
    warn_filter='((.traffic.rx // 0) + (.traffic.tx // 0)) as $used | (.quota_bytes // 0) as $q
        | ((.expires // "") | if . == "" then null else (try fromdateiso8601 catch null) end) as $exp
        | ($exp != null and $exp > $now and ($exp - $now) <= $soon) as $esoon
        | ($q > 0 and ($used * 100) >= ($q * $pct)) as $qhigh'
    warns=$(printf '%s' "$users" | jq -r --argjson now "$now_ts" --argjson soon "$((GA_USERS_WARN_EXPIRY_DAYS * 86400))" \
        --argjson pct "$GA_USERS_WARN_QUOTA_PCT" '.users[]? | select(.enabled == true) | '"$warn_filter"'
        | (if $esoon and ((.notified.expiry_soon // "") != .expires) then "\(.name)\texpiry_soon" else empty end),
          (if $qhigh and ((.notified.quota_80 // -1) != $q) then "\(.name)\tquota_80" else empty end)') || warns=""
    users=$(printf '%s' "$users" | jq -c --argjson now "$now_ts" --argjson soon "$((GA_USERS_WARN_EXPIRY_DAYS * 86400))" \
        --argjson pct "$GA_USERS_WARN_QUOTA_PCT" '.users |= map(if .enabled != true then . else '"$warn_filter"'
        | (if $esoon then .notified.expiry_soon = .expires else del(.notified.expiry_soon) end)
        | (if $qhigh then .notified.quota_80 = $q else del(.notified.quota_80) end)
        | (if (.notified // {}) == {} then del(.notified) else . end) end)') || return 1
    printf '%s' "$users" | ga_users_write || { ga_err users_write_failed "$(t users_err_write)"; return 1; }
    # Код применения здесь ОБЯЗАН влиять на ответ: «выключен» в файле при пире в живом
    # контейнере — худшая из картин. Но ОТКАТА больше нет. Раньше отказ любого профиля
    # возвращал включёнными ВСЕХ нарушителей, и пока у кого-то из них был пир в сломанном
    # профиле, лимиты и сроки не действовали ни для кого, а просроченный возвращался в
    # здоровый профиль при любой чужой правке (SR-07). Теперь выключенные остаются
    # выключенными, профиль с отказом догоняет следующий тик (см. stale выше), а владелец
    # узнаёт кодом ответа.
    for p in $(printf '%s\n%s\n' "$affected" "$stale" | awk 'NF && !seen[$0]++'); do
        _users_apply_profile_locked "$p" || failed+=" $p "
    done
    # Событие владельцу — только тем, чьё выключение дошло до всех контейнеров: «лимит
    # исчерпан, доступ закрыт» должно означать, что он действительно закрыт.
    while IFS=$'\t' read -r name reason; do
        [ -n "$name" ] || continue
        victim_profiles=$(printf '%s' "$users" | jq -r --arg n "$name" '.users[] | select(.name == $n) | .peers // {} | keys[]')
        local pending=0
        for p in $victim_profiles; do
            [[ "$failed" == *" $p "* ]] && pending=1
        done
        if [ "$pending" = 1 ]; then
            users=$(printf '%s' "$users" | jq -c --arg n "$name" --arg r "$reason" '.users |= map(if .name == $n then .disable_pending = $r else . end)')
            ga_audit "quota" "user-disable" "$name reason=$reason apply=pending"
            continue
        fi
        users=$(printf '%s' "$users" | jq -c --arg n "$name" '.users |= map(if .name == $n then del(.disable_pending) else . end)')
        ga_users_notify "$reason" "$name" "$(printf '%s' "$users" | jq -c --arg n "$name" '.users[] | select(.name == $n)
            | {label: .label, quota_bytes, used_bytes: ((.traffic.rx // 0) + (.traffic.tx // 0)), expires}')"
        ga_audit "quota" "user-disable" "$name reason=$reason"
        # Причина словами, а не кодом события (quota_exceeded/expired) — журнал таймера читают люди (LC-05).
        # Ключ словаря — буквально, через case (правило словарей).
        case "$reason" in
            quota_exceeded) log_warning "$(tf users_auto_disabled "$name" "$(t users_reason_quota)")" ;;
            *)              log_warning "$(tf users_auto_disabled "$name" "$(t users_reason_expiry)")" ;;
        esac
    done <<<"$victims"
    # Предупреждения — после записи флагов: упади запись, флаг не встал бы, и событие ушло бы дважды.
    while IFS=$'\t' read -r name reason; do
        [ -n "$name" ] || continue
        ga_users_notify "$reason" "$name" "$(printf '%s' "$users" | jq -c --arg n "$name" --argjson now "$now_ts" '.users[] | select(.name == $n)
            | ((.expires // "") | if . == "" then null else (try fromdateiso8601 catch null) end) as $exp
            | {label: .label, quota_bytes, used_bytes: ((.traffic.rx // 0) + (.traffic.tx // 0)), expires,
               seconds_left: (if $exp == null then null else ($exp - $now) end)}')"
        ga_audit "quota" "user-warn" "$name event=$reason"
    done <<<"$warns"
    # Пометки disable_pending поставлены или сняты — записываем (пусто в victims — нечего).
    if [ -n "$victims" ]; then
        printf '%s' "$users" | ga_users_write || { ga_err users_write_failed "$(t users_err_write)"; return 1; }
    fi
    if [ -n "${failed// /}" ]; then
        ga_err quota_apply_failed "$(t users_err_tick_apply)"
        return 1
    fi
    return 0
}
