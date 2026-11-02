#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# goAmnezia pro — lib/share.sh: временная ссылка на скачивание клиентского файла
#
# Просьба владельца после живой установки, дословно: «когда человек выбирает
# получить профиль файлом — создаётся уникальный путь с уникальным портом, по
# которому я нажимаю и файл качается на компьютер, и путь работает пять минут».
# Смысл: администратор сидит в SSH-меню с телефона или с чужой машины, и ему
# надо быстро забрать .conf на компьютер, не таща текст через терминал.
#
# Модель. Раздача (share) — каталог в $(ga_share_state_dir) (по умолчанию
# /run/goamnezia/share, то есть tmpfs):
#   <id>/meta.json    0600  id, пользователь, профиль, формат, имя файла, порт,
#                           срок, сертификат, отпечаток, хост, как открыт файрвол
#   <id>/secret       0600  43 символа base64url = 32 случайных байта
#   <id>/payload/<файл> 0600  то, что отдаём
#   <id>/ready, pid, state.json, busy, server.log — от процесса раздачи
#                           (busy есть, только пока файл едет клиенту)
# Ссылка: https://<хост>:<порт>/d-<секрет>/<имя файла>. Путь И ЕСТЬ ключ:
# 43 символа base64url не подбираются, поэтому отдельной авторизации нет — как
# у адресов агентов в lib/agents.sh.
#
# Почему /run, а не /opt: раздача не должна пережить перезагрузку. После ребута
# ссылок нет вовсе — и это правильное поведение, а не потеря данных: «временная
# ссылка», молча воскресшая через неделю, перестаёт быть временной.
#
# Почему отдельный порт, а не location в nginx (обсуждалось в задании).
# Раздача одноразовая: она поднимается на минуты и умирает вместе со своим
# файлом. Постоянный location требовал бы постоянно работающего слушателя на
# фиксированном порту петли, флага в config.json, пересборки vhost и reload
# nginx на каждое включение — то есть вечно открытой поверхности вместо той,
# что живёт пять минут, и правки lib/website.sh ради удобства одного экрана.
# Взамен pro-режим получает главное, ради чего был бы нужен nginx: если у домена
# есть действующий сертификат Let's Encrypt, раздача берёт ЕГО, и браузер не
# ругается — сертификат валиден для домена независимо от порта. Самоподписанный
# остаётся только там, где другого нет (lite, lite_site), и тогда рядом со
# ссылкой печатается отпечаток SHA-256 и предупреждение.
#
# Правила модуля (контракт §0):
#   • stdout — только JSON у share_create / share_list / share_revoke /
#     share_revoke_all / share_tick; всё для человека — stderr (log_*);
#   • ни одной видимой строки вне t/tf — словарь lib/lang/<lang>.d/share.sh;
#   • коды ошибок через ga_err: invalid_format, invalid_share_id,
#     share_not_found, share_limit, no_python, no_free_port, no_server_ip,
#     cert_failed, start_failed, write_failed, invalid_ttl, module_missing и
#     коды, всплывающие из lib/export.sh (user_not_found, no_private_key, …);
#   • СЕКРЕТ не пишется ни в лог, ни в аудит — только id раздачи. В аудит идут
#     share-create, share-download (её пишет сам сервер), share-revoke,
#     share-expire;
#   • GOAMNEZIA_DRY_RUN=1 не мешает поднимать слушатель: раздача — это и есть
#     сетевой процесс, и проверять её иначе как настоящим скачиванием нечем
#     (tests/test_share_dryrun.sh). Как «DRY: …» печатаются только правки
#     файрвола — они идут через lib/preflight.sh.
#
# Настройки окружения: GOAMNEZIA_SHARE_TTL (секунд, по умолчанию 300, границы
# 60…3600), GOAMNEZIA_SHARE_ONCE=1 (гасить после первого скачивания),
# GOAMNEZIA_SHARE_MAX_DOWNLOADS (0 = сколько угодно в пределах срока),
# GOAMNEZIA_SHARE_BIND (адрес слушателя, по умолчанию 0.0.0.0),
# GOAMNEZIA_SHARE_DIR (каталог состояния), GOAMNEZIA_SHARE_FIREWALL=0
# (не трогать локальный файрвол), GOAMNEZIA_SHARE_MAX_ACTIVE (предел
# одновременных раздач, по умолчанию 10, границы 1…100).
#
# Подключение в install.sh, боте и панели — docs/SHARE.md.
# ══════════════════════════════════════════════════════════════════════════════

_GA_SHARE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GA_SHARE_ID_RE='^s-[a-f0-9]{4,8}$'
GA_SHARE_SECRET_RE='^[A-Za-z0-9_-]{43}$'
GA_SHARE_TTL_DEFAULT=300
# Границы срока. Меньше минуты человек физически не успевает перенести ссылку
# на другую машину; больше часа — это уже не «временная ссылка», а публикация
# приватного ключа, и такую просьбу лучше отклонить, чем исполнить.
GA_SHARE_TTL_MIN=60
GA_SHARE_TTL_MAX=3600
# Диапазон портов — тот же, что у профилей и персональных портов агентов
# (30000–49999): случайный высокий порт не выделяется среди прочих.
GA_SHARE_PORT_MIN=30000
GA_SHARE_PORT_MAX=49999
GA_SHARE_PORT_TRIES=12
# Попыток поднять слушатель (порт мог занять кто-то между проверкой и стартом)
GA_SHARE_START_TRIES=3
# Ждём маркер готовности сотыми долями секунды: пока его нет, ссылку показывать
# нельзя — человек ткнул бы в неё раньше, чем встал слушатель.
GA_SHARE_START_WAIT=60
# Предел одновременных раздач. Каждая — это отдельный процесс, отдельный порт и
# отдельное правило файрвола, то есть открытая поверхность; меню же позволяло
# нажимать «получить файлом» сколько угодно раз подряд, и предела не было
# никакого. Десяти хватает с запасом: раздача живёт пять минут, а раздаёт
# человек ключи по одному. Настраивается GOAMNEZIA_SHARE_MAX_ACTIVE.
GA_SHARE_MAX_ACTIVE=10
# Столько же, сколько ждёт сам процесс раздачи (DRAIN_MAX в share_server.py):
# маркер busy старше этого срока остался от убитого процесса, и раздачу он
# держать не должен — иначе один сбой делал бы каталог бессмертным.
GA_SHARE_DRAIN_MAX=120
# Сколько секунд каталог раздачи считается «ещё запускается». Маркер starting
# пишется сразу после занятия каталога и снимается, когда слушатель встал.
# Окно должно с запасом перекрывать сборку файла и ожидание готовности
# (GA_SHARE_START_WAIT × 0,1 с), но оставаться коротким: маркер, переживший
# убитый процесс, не должен держать каталог дольше необходимого.
GA_SHARE_START_GRACE=60

# ── Запасные помощники: модуль подключают и без lib/docker.sh ─────────────────
type ga_dry >/dev/null 2>&1 || ga_dry() { [ "${GOAMNEZIA_DRY_RUN:-0}" = "1" ]; }
type ga_dry_echo >/dev/null 2>&1 || ga_dry_echo() { printf 'DRY: %s\n' "$*" >&2; }
if ! type ga_err >/dev/null 2>&1; then
    # ga_err <код> <сообщение> [rc] — те же поля, что читает _action_run в install.sh
    ga_err() {
        GA_ERR_CODE="$1"
        GA_ERR_MSG="$2"
        if declare -F ga_set_error >/dev/null 2>&1; then ga_set_error "$1"; fi
        log_error "$2"
        return "${3:-1}"
    }
fi
# Временный файл с секретом: в памяти и с затиранием (lib/common.sh). Запасные
# определения — на случай подключения модуля без общей библиотеки.
type ga_mktemp_secret >/dev/null 2>&1 || ga_mktemp_secret() { mktemp "${TMPDIR:-/tmp}/.${1:-goamnezia}.XXXXXXXX"; }
type ga_wipe_file >/dev/null 2>&1 || ga_wipe_file() { rm -f "$@" 2>/dev/null || true; }
if ! type ga_capture >/dev/null 2>&1; then
    # stdout функции в переменную БЕЗ подоболочки: код в GA_ERR_CODE должен
    # доехать до вызывающего, а `x=$(fn)` теряет его вместе с подоболочкой.
    # Временный файл — секретный (через захват идёт готовый клиентский конфиг
    # с приватным ключом), поэтому каталог в памяти и затирание нулями.
    ga_capture() {
        local __var="$1"; shift
        local __tmp __rc=0
        __tmp=$(ga_mktemp_secret gacap) || return 1
        "$@" >"$__tmp" || __rc=$?
        printf -v "$__var" '%s' "$(<"$__tmp")"
        ga_wipe_file "$__tmp"
        return "$__rc"
    }
fi
# Аудит теми же именами, что у действий моста; секрет в подробности не попадает.
ga_share_audit() {
    type ga_audit >/dev/null 2>&1 || return 0
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "$1" "${2:-}"
}

# ── Пути и настройки: функциями, а не константами при source ──────────────────
# Стенды выставляют GOAMNEZIA_* уже после подключения модуля; константа,
# вычисленная при source, полезла бы в боевой /run.
ga_share_state_dir() { printf '%s' "${GOAMNEZIA_SHARE_DIR:-${LOCK_DIR:-/run/goamnezia}/share}"; }
# Рабочая копия сервера рядом с рабочей копией модуля (install.sh обновляет их
# вместе), иначе — эталон рядом с этим файлом. Порядок как в lib/agents.sh:
# юнит обязан переживать обновление файлов эталона на лету.
ga_share_server_py() {
    local work="${GOAMNEZIA_DIR:-/opt/goamnezia}/lib/share_server.py"
    [ -f "$work" ] && { printf '%s' "$work"; return 0; }
    printf '%s/share_server.py' "$_GA_SHARE_LIB_DIR"
}
ga_share_bind() { printf '%s' "${GOAMNEZIA_SHARE_BIND:-0.0.0.0}"; }

# Срок жизни ссылки: значение вне границ не отвергаем, а прижимаем к границе с
# предупреждением — из-за опечатки в переменной окружения человек не должен
# остаться без ссылки, но и получить ссылку на сутки он тоже не должен.
ga_share_ttl() {
    local ttl="${GOAMNEZIA_SHARE_TTL:-$GA_SHARE_TTL_DEFAULT}"
    if ! [[ "$ttl" =~ ^[0-9]{1,6}$ ]]; then
        log_warning "$(tf share_warn_ttl "$ttl" "$GA_SHARE_TTL_DEFAULT")"
        ttl="$GA_SHARE_TTL_DEFAULT"
    elif [ "$ttl" -lt "$GA_SHARE_TTL_MIN" ]; then
        log_warning "$(tf share_warn_ttl "$ttl" "$GA_SHARE_TTL_MIN")"
        ttl="$GA_SHARE_TTL_MIN"
    elif [ "$ttl" -gt "$GA_SHARE_TTL_MAX" ]; then
        log_warning "$(tf share_warn_ttl "$ttl" "$GA_SHARE_TTL_MAX")"
        ttl="$GA_SHARE_TTL_MAX"
    fi
    printf '%s' "$ttl"
}
# Сколько раз можно скачать. По умолчанию — сколько угодно в пределах срока:
# человек промахивается мимо ссылки в мобильном терминале постоянно, и
# одноразовость по умолчанию превратила бы фичу в лотерею. Строгий режим —
# GOAMNEZIA_SHARE_ONCE=1.
ga_share_max_downloads() {
    local n
    if [ "${GOAMNEZIA_SHARE_ONCE:-0}" = "1" ]; then printf '1'; return 0; fi
    n="${GOAMNEZIA_SHARE_MAX_DOWNLOADS:-0}"
    [[ "$n" =~ ^[0-9]{1,4}$ ]] || n=0
    printf '%s' "$n"
}
ga_share_firewall_enabled() { [ "${GOAMNEZIA_SHARE_FIREWALL:-1}" != "0" ]; }
# Предел одновременных раздач: значение вне разумных границ игнорируем молча в
# пользу умолчания — опечатка в переменной окружения не должна ни снимать
# предел, ни запрещать раздачу вовсе.
ga_share_max_active() {
    local n="${GOAMNEZIA_SHARE_MAX_ACTIVE:-$GA_SHARE_MAX_ACTIVE}"
    [[ "$n" =~ ^[0-9]{1,3}$ ]] && [ "$n" -ge 1 ] && [ "$n" -le 100 ] || n="$GA_SHARE_MAX_ACTIVE"
    printf '%s' "$n"
}
# Сколько раздач заведено сейчас. Каталог без meta.json не считается обломком
# только пока на нём свежий маркер starting: раздача, которая прямо сейчас
# собирает файл, место занимает, а вот остаток неудачного старта — нет.
ga_share_count_active() {
    local dir d n=0
    dir=$(ga_share_state_dir)
    if [ -d "$dir" ]; then
        for d in "$dir"/s-*; do
            [ -d "$d" ] || continue
            { [ -f "$d/meta.json" ] || ga_share_starting "$d"; } && n=$((n + 1))
        done
    fi
    printf '%s' "$n"
}

# ── Секрет, идентификатор, время ──────────────────────────────────────────────
# 32 случайных байта в base64url без «=» = 43 символа (как у lib/agents.sh):
# перебор невозможен, поэтому путь и работает вместо пароля.
ga_share_new_secret() {
    local s=""
    s=$(openssl rand -base64 32 2>/dev/null | tr '+/' '-_' | tr -d '=\n')
    if ! [[ "$s" =~ $GA_SHARE_SECRET_RE ]]; then
        s=$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')
    fi
    [[ "$s" =~ $GA_SHARE_SECRET_RE ]] || return 1
    printf '%s' "$s"
}
# s-<4 hex>; при совпадении — длиннее (до 8), чтобы id оставался коротким для
# чата. Проверка занятости здесь — только дешёвый фильтр, чтобы не тратить
# попытки: ЗАНИМАЕТ идентификатор сам вызывающий, создавая каталог голым mkdir
# (share_create). Между этой проверкой и созданием всегда есть окно.
ga_share_new_id() {
    local n id
    for n in 4 6 8; do
        id="s-$(generate_hex "$n")"
        [[ "$id" =~ $GA_SHARE_ID_RE ]] || continue
        [ -e "$(ga_share_state_dir)/$id" ] && continue
        printf '%s' "$id"
        return 0
    done
    return 1
}
ga_share_check_id() {
    [[ "${1:-}" =~ $GA_SHARE_ID_RE ]] && return 0
    ga_err invalid_share_id "$(tf share_err_id "${1:-}")" 2
    return 2
}
# Эпоха и ISO-8601 UTC на N секунд вперёд. GNU date и BSD date (стенд на macOS).
ga_share_iso_at() {
    local epoch="$1"
    date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# ── Адрес и сертификат ────────────────────────────────────────────────────────
ga_share_mode() {
    if type ga_site_mode >/dev/null 2>&1; then ga_site_mode; return 0; fi
    local m; m=$(ga_config_get .mode 2>/dev/null) || m=""
    case "$m" in pro|lite_site) printf '%s' "$m" ;; *) printf 'lite' ;; esac
}
ga_share_server_ip() {
    if type ga_site_server_ip >/dev/null 2>&1; then ga_site_server_ip; return 0; fi
    ga_config_get .server_ip 2>/dev/null || printf ''
}
ga_share_domain() { ga_config_get .domain 2>/dev/null || printf ''; }

# ga_share_pick_cert → заполняет GA_SHARE_CERT / GA_SHARE_KEY / GA_SHARE_CERT_KIND
# (letsencrypt | selfsigned) / GA_SHARE_HOST / GA_SHARE_VIA (domain | ip) /
# GA_SHARE_FP (отпечаток SHA-256, пусто для валидного сертификата — сверять
# нечего, его проверил браузер).
#
# Приватный ключ клиента по открытому HTTP не отдаём никогда, поэтому отсутствие
# сертификата — не «отдадим без TLS», а отказ.
GA_SHARE_CERT=""; GA_SHARE_KEY=""; GA_SHARE_CERT_KIND=""; GA_SHARE_HOST=""; GA_SHARE_VIA=""; GA_SHARE_FP=""
ga_share_pick_cert() {
    local mode domain ip crt="" key=""
    GA_SHARE_CERT=""; GA_SHARE_KEY=""; GA_SHARE_CERT_KIND=""; GA_SHARE_HOST=""; GA_SHARE_VIA=""; GA_SHARE_FP=""
    mode=$(ga_share_mode)
    domain=$(ga_share_domain)
    ip=$(ga_share_server_ip)
    # Pro с живым сертификатом Let's Encrypt: берём его и ставим в ссылку домен.
    # Сертификат валиден для имени, а не для порта, — браузер молчит.
    # По ФАКТУ готовности домена, а не по названию режима: во втором режиме
    # домен и сертификат Let's Encrypt точно такие же, и решение по имени
    # режима выдавало там ссылку по адресу с самоподписанным — человеку
    # приходилось сверять отпечаток руками. Тот же корень, что у двух уже
    # закрытых дефектов (адрес доступа агента, перевыпуск сертификата).
    if [ -n "$domain" ] && type ga_site_cert_ok >/dev/null 2>&1 \
       && ga_site_cert_ok "$domain" 0 2>/dev/null; then
        GA_SHARE_CERT=$(ga_site_cert_file "$domain")
        GA_SHARE_KEY=$(ga_site_key_file "$domain")
        GA_SHARE_CERT_KIND="letsencrypt"
        GA_SHARE_HOST="$domain"; GA_SHARE_VIA="domain"
        return 0
    fi
    # Иначе — самоподписанный сертификат сайта, тот же, что у lite_site и у
    # персональных портов агентов: у него уже есть отпечаток, который человек
    # мог видеть раньше, и второй самоподписанный только путал бы.
    if type website_selfsigned_ensure >/dev/null 2>&1; then
        website_selfsigned_ensure >/dev/null 2>&1 || true
    fi
    if type ga_site_ss_crt >/dev/null 2>&1; then crt=$(ga_site_ss_crt); else crt="${GOAMNEZIA_DIR:-/opt/goamnezia}/tls/site.crt"; fi
    if type ga_site_ss_key >/dev/null 2>&1; then key=$(ga_site_ss_key); else key="${GOAMNEZIA_DIR:-/opt/goamnezia}/tls/site.key"; fi
    if [ ! -f "$crt" ] || [ ! -f "$key" ]; then
        ga_err cert_failed "$(t share_err_cert)"
        return 1
    fi
    [ -n "$ip" ] || { ga_err no_server_ip "$(t share_err_no_host)"; return 1; }
    GA_SHARE_CERT="$crt"; GA_SHARE_KEY="$key"; GA_SHARE_CERT_KIND="selfsigned"
    GA_SHARE_HOST="$ip"; GA_SHARE_VIA="ip"
    if type website_cert_fingerprint >/dev/null 2>&1; then
        GA_SHARE_FP=$(website_cert_fingerprint "$crt" 2>/dev/null) || GA_SHARE_FP=""
    fi
    return 0
}

# ── Порт ──────────────────────────────────────────────────────────────────────
# Свободен ли TCP-порт. Спрашиваем ту же предполётную проверку, что и мастер
# (lib/preflight.sh): она видит и слушателей, и порты, которые контейнер держит
# правилом DNAT без слушателя. Без модуля — запасной путь через docker_port_free.
ga_share_port_free() {
    local port="$1" js state
    # ga_pf_owner, а не preflight_port_owner: второй на КАЖДЫЙ вызов заново
    # опрашивает ss, docker, ufw, iptables и nft (каждый со своим таймаутом), и
    # десяток кандидатов подряд превратился бы в полминуты ожидания. Снимок
    # делает ga_share_random_port — один раз на выбор порта.
    if type ga_pf_owner >/dev/null 2>&1; then
        js=$(ga_pf_owner tcp "$port" 2>/dev/null) || return 1
        state=$(printf '%s' "$js" | jq -r '.state // "unknown"' 2>/dev/null)
        # closed_local — порт свободен, но закрыт файрволом: это мы умеем
        # поправить сами, и брать такой порт можно.
        case "$state" in free|closed_local) return 0 ;; *) return 1 ;; esac
    fi
    if type docker_port_free >/dev/null 2>&1; then docker_port_free "$port" tcp; return $?; fi
    command -v ss >/dev/null 2>&1 || return 0
    ! grep -qE "[:.]${port}[[:space:]]" <<<"$(ss -ltn 2>/dev/null)"
}
# Случайный свободный порт из диапазона; занят и порт, на котором уже стоит
# другая наша раздача (её слушателя может ещё не быть на момент проверки).
ga_share_random_port() {
    local p="" i used
    used=$(ga_share_ports_in_use)
    type ga_pf_collect >/dev/null 2>&1 && ga_pf_collect tcp >/dev/null 2>&1
    for i in $(seq 1 "$GA_SHARE_PORT_TRIES"); do
        if command -v shuf >/dev/null 2>&1; then
            p=$(shuf -i "${GA_SHARE_PORT_MIN}-${GA_SHARE_PORT_MAX}" -n 1 2>/dev/null) || p=""
        fi
        [ -n "$p" ] || p=$(( GA_SHARE_PORT_MIN + ((RANDOM << 15 | RANDOM) % (GA_SHARE_PORT_MAX - GA_SHARE_PORT_MIN + 1)) ))
        case " $used " in *" $p "*) p=""; continue ;; esac
        if ga_share_port_free "$p"; then printf '%s' "$p"; return 0; fi
        p=""
    done
    return 1
}
ga_share_ports_in_use() {
    local dir d p out=""
    dir=$(ga_share_state_dir)
    [ -d "$dir" ] || { printf ''; return 0; }
    for d in "$dir"/s-*; do
        [ -f "$d/meta.json" ] || continue
        p=$(jq -r '.port // empty' "$d/meta.json" 2>/dev/null)
        [ -n "$p" ] && out="${out}${p} "
    done
    printf '%s' "$out"
}

# ── Файрвол ───────────────────────────────────────────────────────────────────
# Открываем порт на время раздачи и закрываем при уборке. Своё правило мы
# знаем точно (порт из meta.json), поэтому снимаем ровно его и ничего больше.
# Правило переживает смерть процесса раздачи и снимается позже — share_tick или
# следующим вызовом модуля; висящее правило на порту, который никто не слушает,
# безвредно (соединение просто отвергается ядром).
ga_share_fw_open() {
    local port="$1" state how
    ga_share_firewall_enabled || { printf 'none'; return 0; }
    type ga_pf_firewall_state >/dev/null 2>&1 || { printf 'none'; return 0; }
    type preflight_open_local >/dev/null 2>&1 || { printf 'none'; return 0; }
    # Снимок делаем здесь заново. Тот, что взял ga_share_random_port, до нас не
    # доезжает: random_port зовут через $( ), а подоболочка уносит _GA_PF_* с
    # собой. Один опрос на создание раздачи — столько же, сколько у
    # _agents_firewall_open в lib/agents.sh.
    type ga_pf_collect >/dev/null 2>&1 && ga_pf_collect tcp >/dev/null 2>&1
    state=$(ga_pf_firewall_state tcp "$port" 2>/dev/null) || state=""
    case "$state" in
        closed*) ;;
        *) printf 'none'; return 0 ;;
    esac
    # Чем ИМЕННО откроет preflight_open_local, решаем той же проверкой, что и он
    # (ufw активен → ufw, иначе iptables), а не по источнику из firewall_state:
    # источник бывает «nft», а правило при этом ложится через iptables — и
    # закрывать его пришлось бы не тем инструментом, то есть никогда.
    how="iptables"
    if type ga_pf_source >/dev/null 2>&1 \
       && ga_pf_source GOAMNEZIA_UFW_FIXTURE GOAMNEZIA_UFW_BIN ufw status 2>/dev/null | grep -q '^Status: active'; then
        how="ufw"
    fi
    # stderr НЕ глушим: там и «DRY: ufw allow …» на стенде, и объяснение отказа
    # на живом сервере — единственное, по чему человек поймёт, почему ссылка не
    # открывается снаружи. Глушим только stdout: мы внутри $( ).
    if preflight_open_local "$port" tcp >/dev/null; then
        log_dim "$(tf share_fw_opened "$port")"
        printf '%s' "$how"
        return 0
    fi
    log_warning "$(tf share_warn_firewall "$port")"
    printf 'none'
    return 0
}
# Снять правило, которое мы же и поставили. ufw умеет `delete allow`, iptables —
# `-D` с теми же аргументами, что были у `-I`. nft отдельной цепочкой мы не
# трогаем (preflight_open_local тоже её не трогает), поэтому и снимать нечего.
ga_share_fw_close() {
    local port="$1" how="${2:-none}" bin
    type ga_pf_run >/dev/null 2>&1 || return 0
    type ga_pf_bin >/dev/null 2>&1 || return 0
    case "$how" in
        ufw)
            bin=$(ga_pf_bin GOAMNEZIA_UFW_BIN ufw)
            ga_pf_run "$bin" delete allow "${port}/tcp" >/dev/null || true
            ;;
        iptables)
            bin=$(ga_pf_bin GOAMNEZIA_IPTABLES_BIN iptables)
            ga_pf_run "$bin" -D INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null || true
            if ga_dry || command -v ip6tables >/dev/null 2>&1; then
                ga_pf_run ip6tables -D INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null || true
            fi
            ;;
        *) return 0 ;;
    esac
    log_dim "$(tf share_fw_closed "$port")"
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  Сборка файла раздачи
# ══════════════════════════════════════════════════════════════════════════════
# ga_share_archive <каталог с файлами> <файл-архив без расширения> → stdout имя
# файла архива. zip, если он есть (его открывают все системы двойным щелчком),
# иначе tar.gz — на голом сервере zip бывает не установлен.
ga_share_archive() {
    local src="$1" base="$2" out
    if command -v zip >/dev/null 2>&1; then
        out="${base}.zip"
        ( cd "$src" && zip -q -r -X "$out" . ) >/dev/null 2>&1 || { ga_err write_failed "$(tf share_err_archive "$(basename "$out")")"; return 1; }
    else
        out="${base}.tar.gz"
        tar -czf "$out" -C "$src" . >/dev/null 2>&1 || { ga_err write_failed "$(tf share_err_archive "$(basename "$out")")"; return 1; }
    fi
    chmod 600 "$out" 2>/dev/null || true
    printf '%s' "$(basename "$out")"
}

# ga_share_payload <имя> <профиль> <формат> <каталог payload> [разовый адрес] → stdout имя файла.
# Форматы — те же, что у export_bundle (lib/export.sh): conf, vpn, qr-conf,
# qr-vpn, all. Имя осмысленное: <пользователь>-<линия>.<расширение> (линия с подчёркиванием: anna-2_0.conf), как у файла
# .conf в SSH (ga_key_file_base: имя до 10 знаков, у двух профилей одной линии — anna-3_1-2 / anna-3_1-3), — человек
# скачает несколько файлов подряд и должен различать их в папке «Загрузки»; имени места (awg3) в нём нет: AmneziaWG
# берёт из имени файла имя туннеля, и «awg3» у линии 2.0 путало (A2-7/B2-9). Линию не узнать — имя места, как
# раньше. С разовым адресом сервера (ключ на другой адрес, docs/EDGEIPS.md §3.4) — то же имя, как у user-key (П-2):
# адрес сделал бы имя туннеля длиннее 15 знаков, а Android и Linux такой туннель не примут; адрес — в самом ключе.
ga_share_payload() {
    local name="$1" profile="$2" format="$3" out="$4" ep="${5:-}"
    local base="" conf="" vpn="" stage n file rc=0
    # Имя — как у файла .conf в SSH (ga_key_file_base: латиница до 10 знаков, линия, номер места при двух профилях
    # одной линии — R-6); модуля нет — <пользователь>-<профиль>, как раньше.
    type ga_key_file_base >/dev/null 2>&1 && base=$(ga_key_file_base "$name" "$profile" 2>/dev/null)
    [ -n "$base" ] || base="${name}-${profile}"
    mkdir -p "$out" || { ga_err write_failed "$(tf share_err_write "$out")"; return 1; }
    chmod 700 "$out" 2>/dev/null || true
    case "$format" in
        conf)
            ga_capture conf export_conf "$name" "$profile" "$ep" || return $?
            (umask 077; printf '%s\n' "$conf" >"$out/${base}.conf") || { ga_err write_failed "$(tf share_err_write "${base}.conf")"; return 1; }
            printf '%s' "${base}.conf"
            ;;
        vpn)
            ga_capture vpn export_vpn "$name" "$profile" "$ep" || return $?
            (umask 077; printf '%s\n' "$vpn" >"$out/${base}.vpn") || { ga_err write_failed "$(tf share_err_write "${base}.vpn")"; return 1; }
            printf '%s' "${base}.vpn"
            ;;
        qr-conf)
            ga_capture conf export_conf "$name" "$profile" "$ep" || return $?
            export_qr_png "$conf" "$out/${base}-qr.png" || return $?
            chmod 600 "$out/${base}-qr.png" 2>/dev/null || true
            printf '%s' "${base}-qr.png"
            ;;
        qr-vpn)
            stage="$out/.qr"
            export_qr_vpn_pngs "$name" "$profile" "$stage" "$ep" >/dev/null || return $?
            n=$(find "$stage" -maxdepth 1 -name '*.png' -type f 2>/dev/null | wc -l | tr -d ' ')
            if [ "$n" = 1 ]; then
                # Один чанк — отдаём картинкой: её видно прямо в браузере, и
                # архив ради одного файла только мешает.
                file=$(find "$stage" -maxdepth 1 -name '*.png' -type f 2>/dev/null | head -1)
                mv "$file" "$out/${base}-qr.png" || { ga_err write_failed "$(tf share_err_write "${base}-qr.png")"; return 1; }
                rm -rf "$stage"
                chmod 600 "$out/${base}-qr.png" 2>/dev/null || true
                printf '%s' "${base}-qr.png"
            else
                ga_capture file ga_share_archive "$stage" "$out/${base}-qr" || return $?
                rm -rf "$stage"
                printf '%s' "$file"
            fi
            ;;
        all)
            stage="$out/.all"
            mkdir -p "$stage" || { ga_err write_failed "$(tf share_err_write "$stage")"; return 1; }
            chmod 700 "$stage" 2>/dev/null || true
            ga_capture conf export_conf "$name" "$profile" "$ep" || { rc=$?; rm -rf "$stage"; return "$rc"; }
            ga_capture vpn export_vpn "$name" "$profile" "$ep" || { rc=$?; rm -rf "$stage"; return "$rc"; }
            (umask 077; printf '%s\n' "$conf" >"$stage/${base}.conf"; printf '%s\n' "$vpn" >"$stage/${base}.vpn") \
                || { rm -rf "$stage"; ga_err write_failed "$(tf share_err_write "$base")"; return 1; }
            # QR — по возможности: без qrencode ключ всё равно полноценный, и
            # ронять из-за картинки всю выдачу нельзя.
            if export_qr_png "$conf" "$stage/${base}-qr.png" >/dev/null 2>&1; then
                export_qr_vpn_pngs "$name" "$profile" "$stage/qr-vpn" "$ep" >/dev/null 2>&1 || rm -rf "$stage/qr-vpn"
            else
                log_warning "$(t share_warn_no_qr)"
            fi
            ga_capture file ga_share_archive "$stage" "$out/${base}" || { rc=$?; rm -rf "$stage"; return "$rc"; }
            rm -rf "$stage"
            printf '%s' "$file"
            ;;
        *)
            ga_err invalid_format "$(tf share_err_format "$format")" 2
            return 2
            ;;
    esac
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  Уборка
# ══════════════════════════════════════════════════════════════════════════════
# ga_share_read_num <файл> → stdout число, rc 0; иначе пусто и rc 1.
# ЕДИНСТВЕННОЕ место модуля, где читается файл-маркер раздачи (pid, busy,
# starting). Каталог раздачи снимают и уборщик, и сам процесс отдачи, поэтому
# между «каталог есть» и «читаем файл» файла может уже не быть — и это обычный
# ход дел, а не поломка.
# Фигурные скобки обязательны: ошибку ПЕРЕНАПРАВЛЕНИЯ печатает САМА ОБОЛОЧКА
# до запуска команды, и `2>/dev/null` после команды её не гасит — гасит только
# перенаправление, навешенное на всю конструкцию. Без скобок на экран
# «Активные раздачи» посреди списка вылезала сырая строка оболочки
# «…/starting: No such file or directory» (§1b, живой стенд).
# Нет файла, он пуст или в нём не число — rc 1: «маркера нет». Тихо вернуть 0
# нельзя: ноль означал бы «маркер поставлен в 1970», и раздача, которая только
# рождается, читалась бы как протухшая.
ga_share_read_num() {
    local v
    v=$( { tr -d '[:space:]' <"$1"; } 2>/dev/null ) || return 1
    [[ "$v" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$v"
}
# ga_share_alive <каталог> — процесс раздачи ещё жив?
ga_share_alive() {
    local d="$1" pid
    pid=$(ga_share_read_num "$d/pid") || return 1
    kill -0 "$pid" 2>/dev/null
}
# ga_share_kill <каталог> — погасить процесс раздачи и дождаться его смерти.
# Сначала SIGTERM (сервер сам затрёт файл и снимет каталог), потом добиваем:
# секрет не должен пережить отзыв ни на секунду дольше необходимого.
ga_share_kill() {
    local d="$1" pid
    pid=$(ga_share_read_num "$d/pid") || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    kill "$pid" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.1
    done
    kill -9 "$pid" 2>/dev/null || true
    return 0
}
# ga_share_drop <каталог> <причина> — снять раздачу: погасить процесс, закрыть
# порт в файрволе, затереть файл и удалить каталог. Идемпотентна.
ga_share_drop() {
    local d="$1" reason="${2:-expired}" id port fw f size action
    [ -d "$d" ] || return 0
    id=$(basename "$d")
    port=$(jq -r '.port // empty' "$d/meta.json" 2>/dev/null)
    fw=$(jq -r '.fw // "none"' "$d/meta.json" 2>/dev/null)
    ga_share_kill "$d"
    # Файл затираем перед удалением: /run — tmpfs, то есть память, и перезапись
    # там действительно стирает содержимое, а стоит микросекунды.
    if [ -d "$d/payload" ]; then
        for f in "$d/payload"/*; do
            [ -f "$f" ] || continue
            # Те же скобки, что и в ga_share_read_num: файл мог исчезнуть
            # между `[ -f ]` и этими двумя строками (процесс отдачи снимает
            # каталог за собой), и голое `2>/dev/null` ошибку оболочки не гасит.
            size=$( { wc -c <"$f"; } 2>/dev/null | tr -d ' ')
            [[ "$size" =~ ^[0-9]+$ ]] && { head -c "$size" /dev/zero >"$f"; } 2>/dev/null
        done
    fi
    rm -f "$d/secret" 2>/dev/null || true
    rm -rf "$d" 2>/dev/null || true
    [ -n "$port" ] && ga_share_fw_close "$port" "$fw"
    # Отзыв и истечение — разные события: по аудиту должно быть видно, забрал
    # человек ссылку обратно или она просто отжила своё.
    case "$reason" in revoked) action="share-revoke" ;; *) action="share-expire" ;; esac
    ga_share_audit "$action" "id=${id} reason=${reason}"
    return 0
}
# ga_share_busy <каталог> — файл прямо сейчас едет клиенту? Маркер busy пишет
# сам процесс раздачи на время ответа (share_server.py). Читаем время начала:
# маркер, переживший убитый процесс, раздачу держать не должен.
ga_share_busy() {
    local d="$1" started now
    started=$(ga_share_read_num "$d/busy") || return 1
    now=$(date -u +%s)
    [ $((now - started)) -lt "$GA_SHARE_DRAIN_MAX" ]
}
# ── Фаза запуска ──────────────────────────────────────────────────────────────
# Раздача рождается в три приёма: занимается каталог → собирается файл и
# пишется meta.json → поднимается процесс, и только он пишет pid и ready. До
# последнего шага каталог для уборщика выглядит мёртвым (нет meta.json — значит
# «обломок», есть meta.json без живого pid — значит «умерла»), а уборку зовёт
# КАЖДАЯ публичная функция модуля: параллельный share-list сносил каталог
# из-под рождающейся раздачи вместе с уже собранным файлом ключа.
# Маркер starting закрывает обе дыры сразу: пока он свеж, каталог не трогают.
# Скобки обязательны и при записи, и при чтении: ошибку ПЕРЕНАПРАВЛЕНИЯ печатает
# сама оболочка, и `2>/dev/null` после команды её не гасит — в stderr сыпалось
# «starting: No such file or directory», когда каталог раздачи уже снят
# уборщиком. Чтение живёт в ga_share_read_num, запись — здесь.
ga_share_start_mark() { { date -u +%s >"$1/starting"; } 2>/dev/null || true; }
ga_share_start_clear() { rm -f "$1/starting" 2>/dev/null || true; }
ga_share_starting() {
    local d="$1" started now
    started=$(ga_share_read_num "$d/starting") || return 1
    now=$(date -u +%s)
    [ $((now - started)) -lt "$GA_SHARE_START_GRACE" ]
}
# ga_share_expired <каталог> — срок вышел?
ga_share_expired() {
    local d="$1" exp now
    exp=$(jq -r '.expires_epoch // 0' "$d/meta.json" 2>/dev/null)
    [[ "$exp" =~ ^[0-9]+$ ]] || return 0
    now=$(date -u +%s)
    [ "$now" -ge "$exp" ]
}
# ga_share_sweep → stdout число убранных. Тихая уборка: её зовёт КАЖДАЯ
# публичная функция модуля, поэтому она не должна ни печатать, ни падать.
ga_share_sweep() {
    local dir d n=0
    dir=$(ga_share_state_dir)
    [ -d "$dir" ] || { printf '0'; return 0; }
    for d in "$dir"/s-*; do
        [ -d "$d" ] || continue
        # Раздача, которая ещё запускается, — не мусор и не покойник. Проверка
        # стоит ПЕРВОЙ: обе ветки ниже сносят каталог вместе с файлом ключа.
        ga_share_starting "$d" && continue
        # Каталог без meta.json — обломок неудачного старта: он не раздаётся и
        # только мешает считать порты.
        if [ ! -f "$d/meta.json" ]; then
            rm -rf "$d" 2>/dev/null || true
            n=$((n + 1))
            continue
        fi
        if ga_share_expired "$d" || ! ga_share_alive "$d"; then
            # Живой процесс, который прямо сейчас отдаёт файл, не трогаем.
            # Раньше уборка сносила каталог из-под работающей отдачи, и
            # скачивание рвалось на середине: человек получал обрезанный .conf
            # и считал, что продукт выдал битый ключ. Ждать не надо — уборку
            # зовёт каждая публичная функция модуля, а сам процесс раздачи,
            # дорезав отдачу, снимет каталог за собой.
            if ga_share_alive "$d" && ga_share_busy "$d"; then
                continue
            fi
            ga_share_drop "$d" expired
            n=$((n + 1))
        fi
    done
    printf '%s' "$n"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Публичные функции
# ══════════════════════════════════════════════════════════════════════════════
# share_create <имя> <профиль> <формат> [разовый адрес сервера в ключе] → stdout JSON
#   {id, url, path, port, host, via, format, file_name, size, created, expires,
#    ttl, max_downloads, cert, fingerprint, selfsigned, endpoint}
# path и url содержат СЕКРЕТ — действие моста помечено "secret": true, в аудит и
# лог уходит только id.
share_create() {
    local name="${1:-}" profile="${2:-}" format="${3:-conf}" ep="${4:-}"
    local dir sdir id secret port="" ttl now exp iso file payload size fw try rc=0
    local server bind meta url path start_err=""

    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t share_err_no_jq)"; return 1; }
    if ! command -v python3 >/dev/null 2>&1; then
        ga_err no_python "$(t share_err_no_python)"
        return 1
    fi
    type export_conf >/dev/null 2>&1 || { ga_err module_missing "$(tf module_missing export_conf)"; return 1; }
    case "$format" in conf|vpn|qr-conf|qr-vpn|all) ;; *) ga_err invalid_format "$(tf share_err_format "$format")" 2; return 2 ;; esac
    # Имя и профиль проверяем ЗДЕСЬ, а не только в lib/export.sh: из них
    # собирается имя файла, которое уезжает в URL и в заголовок
    # Content-Disposition. Пропустить сюда что-то вроде «../» нельзя.
    if ! [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || ! [[ "$profile" =~ ^awg[1-9]$ ]]; then
        ga_err invalid_argument "$(tf share_err_target "$name" "$profile")" 2
        return 2
    fi
    # Пользователь и профиль — теми же проверками, что у выдачи ключа: раздача
    # не должна быть окном в обход правил lib/export.sh.
    if type ga_users_require >/dev/null 2>&1; then
        ga_users_require "$name" || return $?
    fi
    # Выключенному — не выдаём (A3-5/B3-5): пира в профиле нет, файл по ссылке не подключится, а памятка
    # человеку велела бы «Включите VPN». То же правило и тот же код, что у страницы подключения (user_disabled).
    if type ga_users_get >/dev/null 2>&1 && [ "$(ga_users_get "$name" 2>/dev/null | jq -r '.enabled' 2>/dev/null)" = false ]; then
        ga_err user_disabled "$(tf share_err_disabled "$name")" 3
        return 3
    fi
    # Разовый адрес сервера в ключе — до уборки и открытия порта: чужой адрес отказывается сразу. Он же
    # попадёт в имя файла, поэтому только проверенный (IPv4 или настроенный домен в нижнем регистре).
    if [ -n "$ep" ]; then
        type ga_export_key_host_check >/dev/null 2>&1 || { ga_err module_missing "$(tf module_missing ga_export_key_host_check)"; return 1; }
        ga_capture ep ga_export_key_host_check "$ep" || return $?
    fi
    server=$(ga_share_server_py)
    [ -f "$server" ] || { ga_err module_missing "$(tf module_missing "$(basename "$server")")"; return 1; }

    ga_share_sweep >/dev/null
    # Предел проверяем ПОСЛЕ уборки: отжившие раздачи место не занимают.
    local active limit
    active=$(ga_share_count_active)
    limit=$(ga_share_max_active)
    if [ "$active" -ge "$limit" ]; then
        ga_err share_limit "$(tf share_err_limit "$active" "$limit")" 2
        return 2
    fi
    ga_share_pick_cert || return 1

    dir=$(ga_share_state_dir)
    if ! mkdir -p "$dir" 2>/dev/null; then
        ga_err write_failed "$(tf share_err_state_dir "$dir")"
        return 1
    fi
    chmod 700 "$dir" 2>/dev/null || true

    # Идентификатор занимается САМИМ созданием каталога, и mkdir идёт БЕЗ -p:
    # на существующем каталоге -p молчит и отвечает успехом, поэтому «проверил
    # свободен → создал» двум одновременным вызовам выдавало один и тот же id,
    # и тот, кто пришёл вторым, ложился в чужой каталог — с чужим секретом,
    # чужим meta.json и общим концом по первому же отзыву. Голый mkdir на
    # занятом каталоге отказывает, и это единственное атомарное «занял».
    sdir=""
    for try in $(seq 1 "$GA_SHARE_START_TRIES"); do
        id=$(ga_share_new_id) || continue
        if mkdir "$dir/$id" 2>/dev/null; then
            # Дальше каталог раздачи адресуется ТОЛЬКО через sdir с ${sdir:?}:
            # любая ветка отката делает rm -rf, и пустая переменная означала бы
            # rm -rf /.
            sdir="$dir/$id"
            break
        fi
    done
    if [ -z "$sdir" ]; then
        ga_err write_failed "$(tf share_err_state_dir "$dir")"
        return 1
    fi
    chmod 700 "$sdir" 2>/dev/null || true
    # С этой секунды каталог под защитой уборщика и до конца запуска.
    ga_share_start_mark "$sdir"
    secret=$(ga_share_new_secret) || { rm -rf "${sdir:?}"; ga_err write_failed "$(t share_err_secret)"; return 1; }

    # Файл собираем ДО того, как поднимаем слушатель: незачем открывать порт,
    # если ключа у пользователя нет и выдавать нечего.
    # Код возврата забираем ЧЕРЕЗ ||, а не из `if ! …; then rc=$?`: во второй
    # форме $? — это статус успешного отрицания, то есть всегда 0, и отказ
    # («нет пира в профиле») уезжал бы наружу как успех с пустым ответом.
    ga_capture file ga_share_payload "$name" "$profile" "$format" "$sdir/payload" "$ep" || rc=$?
    if [ "$rc" != 0 ]; then
        rm -rf "${sdir:?}"
        return "$rc"
    fi
    payload="$sdir/payload/$file"
    chmod 600 "$payload" 2>/dev/null || true
    # Скобки — по той же причине, что в ga_share_read_num: без них не удавшееся
    # перенаправление печатает сырую строку оболочки мимо словаря.
    size=$( { wc -c <"$payload"; } 2>/dev/null | tr -d ' ')

    ttl=$(ga_share_ttl)
    now=$(date -u +%s)
    exp=$((now + ttl))
    iso=$(ga_share_iso_at "$exp")
    bind=$(ga_share_bind)

    (umask 077; printf '%s' "$secret" >"$sdir/secret") || {
        rm -rf "${sdir:?}"; ga_err write_failed "$(tf share_err_write "$sdir/secret")"; return 1; }

    # Слушатель: порт мог занять кто-то между проверкой и стартом — тогда
    # берём следующий. Больше нескольких попыток смысла нет: значит, дело не в
    # гонке, а в чём-то другом, и об этом надо сказать, а не крутиться.
    for try in $(seq 1 "$GA_SHARE_START_TRIES"); do
        port=$(ga_share_random_port) || { rm -rf "${sdir:?}"; ga_err no_free_port "$(tf share_err_no_port "$GA_SHARE_PORT_TRIES")"; return 1; }
        fw=$(ga_share_fw_open "$port")
        meta=$(jq -nc --arg id "$id" --arg name "$name" --arg profile "$profile" --arg format "$format" \
            --arg file "$file" --argjson port "$port" --arg bind "$bind" \
            --arg created "$(ga_share_iso_at "$now")" --arg expires "$iso" --argjson exp "$exp" \
            --argjson ttl "$ttl" --argjson maxd "$(ga_share_max_downloads)" \
            --arg cert "$GA_SHARE_CERT" --arg key "$GA_SHARE_KEY" --arg kind "$GA_SHARE_CERT_KIND" \
            --arg fp "$GA_SHARE_FP" --arg host "$GA_SHARE_HOST" --arg via "$GA_SHARE_VIA" \
            --arg fw "$fw" --argjson size "${size:-0}" --arg ep "$ep" \
            '{id:$id, name:$name, profile:$profile, format:$format, file_name:$file, port:$port,
              bind:$bind, created:$created, expires:$expires, expires_epoch:$exp, ttl:$ttl,
              max_downloads:$maxd, cert:$cert, key:$key, cert_kind:$kind, fingerprint:$fp,
              host:$host, via:$via, fw:$fw, size:$size, endpoint:$ep}') || {
            rm -rf "${sdir:?}"; ga_err write_failed "$(tf share_err_write "$sdir/meta.json")"; return 1; }
        (umask 077; printf '%s\n' "$meta" >"$sdir/meta.json") || {
            rm -rf "${sdir:?}"; ga_err write_failed "$(tf share_err_write "$sdir/meta.json")"; return 1; }

        # Отвязываем от терминала: раздача обязана пережить выход из SSH-меню.
        # Свою сессию процесс заводит сам (os.setsid в share_server.py) — утилиты
        # setsid на macOS-стенде нет, а проверять раздачу надо и там.
        rm -f "$sdir/ready" "$sdir/pid" 2>/dev/null || true
        # --users: выключенному пользователю раздача отвечает 404, включили — снова отдаёт (A4-2, как подписка)
        nohup python3 "$server" --dir "$sdir" --bind "$bind" --port "$port" \
            --audit "${AUDIT_LOG:-}" --users "${USERS_FILE:-}" >"$sdir/server.log" 2>&1 </dev/null &
        disown 2>/dev/null || true

        if ga_share_wait_ready "$sdir"; then
            rc=0
            break
        fi
        rc=1
        # Лог сервера читаем ДО удаления каталога: в нём единственное объяснение,
        # почему слушатель не встал (порт занят, сертификат не читается…).
        start_err=$(tail -n 3 "$sdir/server.log" 2>/dev/null | tr '\n' ' ')
        ga_share_kill "$sdir"
        ga_share_fw_close "$port" "$fw"
    done
    if [ "$rc" != 0 ]; then
        ga_share_drop "$sdir" start_failed
        ga_err start_failed "$(tf share_err_start "${port:-0}" "$start_err")"
        return 1
    fi
    # Слушатель встал и написал свой pid — дальше каталог защищает он сам.
    ga_share_start_clear "$sdir"

    path="/d-${secret}/${file}"
    url="https://${GA_SHARE_HOST}:${port}${path}"
    ga_share_audit share-create "id=${id} user=${name} profile=${profile} format=${format} port=${port} ttl=${ttl} cert=${GA_SHARE_CERT_KIND}${ep:+ endpoint=${ep}}"
    # Экран SSH (install.sh _user_share) говорит всё это своими словами — минутами, временем сервера и «Подробнее →
    # Перейти» вместо «сверьте отпечаток»; второй раз то же самое секундами — лишнее (находка NC-11). Для моста
    # (бот, панель, MCP) строки остаются: там это журнал.
    if [ "${GA_SHARE_QUIET:-0}" != 1 ]; then
        log_success "$(tf share_created "$file" "$port" "$ttl")"
        if [ "$GA_SHARE_CERT_KIND" = "selfsigned" ]; then
            log_warning "$(tf share_warn_selfsigned "${GA_SHARE_FP:-$(t unknown)}")"
        fi
    fi

    # Адрес и путь — через окружение, не аргументами jq: в них секрет раздачи, то есть сам ключ
    # человека, а argv читает любой локальный пользователь в /proc/<pid>/cmdline (находка SEC46-02).
    GA_S_URL="$url" GA_S_PATH="$path" jq -nc --arg id "$id" --argjson port "$port" \
        --arg host "$GA_SHARE_HOST" --arg via "$GA_SHARE_VIA" --arg format "$format" \
        --arg file "$file" --argjson size "${size:-0}" --arg created "$(ga_share_iso_at "$now")" \
        --arg expires "$iso" --argjson ttl "$ttl" --argjson maxd "$(ga_share_max_downloads)" \
        --arg cert "$GA_SHARE_CERT_KIND" --arg fp "$GA_SHARE_FP" \
        --argjson ss "$([ "$GA_SHARE_CERT_KIND" = selfsigned ] && printf true || printf false)" \
        --arg ep "$ep" \
        '{id:$id, url:$ENV.GA_S_URL, path:$ENV.GA_S_PATH, port:$port, host:$host, via:$via, format:$format,
          file_name:$file, size:$size, created:$created, expires:$expires, ttl:$ttl,
          max_downloads:$maxd, cert:$cert, fingerprint:$fp, selfsigned:$ss, endpoint:$ep}'
}

# Ждать маркер готовности от процесса раздачи (его пишет share_server.py после
# того, как слушатель встал). Пока маркера нет, ссылку показывать нельзя.
ga_share_wait_ready() {
    local d="$1" i
    for i in $(seq 1 "$GA_SHARE_START_WAIT"); do
        [ -f "$d/ready" ] && return 0
        # Процесс умер, не написав маркер — ждать больше нечего
        [ -f "$d/pid" ] && ! ga_share_alive "$d" && return 1
        sleep 0.1
    done
    return 1
}

# share_list → stdout JSON {shares: [...], count}
# БЕЗ секретной части пути: здесь только то, что можно показать на экране, в
# боте и в панели. Кто захочет ссылку — создаёт новую раздачу.
share_list() {
    local dir d list='[]' now js dl
    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t share_err_no_jq)"; return 1; }
    ga_share_sweep >/dev/null
    dir=$(ga_share_state_dir)
    now=$(date -u +%s)
    if [ -d "$dir" ]; then
        for d in "$dir"/s-*; do
            [ -f "$d/meta.json" ] || continue
            # Счётчик скачиваний пишет сам процесс раздачи; файла может ещё не
            # быть (ни одного скачивания) — это ноль, а не повод пропустить строку.
            dl=$(jq -r '.downloads // 0' "$d/state.json" 2>/dev/null)
            [[ "$dl" =~ ^[0-9]+$ ]] || dl=0
            js=$(jq -c --argjson now "$now" --argjson dl "$dl" \
                '{id, name, profile, format, file_name, port, host, via, size, endpoint: (.endpoint // ""),
                  created, expires, ttl, max_downloads, cert: .cert_kind,
                  downloads: $dl, seconds_left: (((.expires_epoch // 0) - $now) | if . < 0 then 0 else . end)}' \
                "$d/meta.json" 2>/dev/null) || continue
            list=$(jq -c --argjson item "$js" '. + [$item]' <<<"$list")
        done
    fi
    jq -nc --argjson shares "$list" '{shares: $shares, count: ($shares | length)}'
}

# share_revoke <id> → stdout JSON {id, revoked}
share_revoke() {
    local id="${1:-}" dir
    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t share_err_no_jq)"; return 1; }
    ga_share_check_id "$id" || return 2
    dir="$(ga_share_state_dir)/$id"
    if [ ! -d "$dir" ]; then
        ga_share_sweep >/dev/null
        ga_err share_not_found "$(tf share_err_not_found "$id")" 3
        return 3
    fi
    ga_share_drop "$dir" revoked
    ga_share_sweep >/dev/null
    log_success "$(tf share_revoked "$id")"
    jq -nc --arg id "$id" '{id: $id, revoked: 1}'
}

# share_revoke_all → stdout JSON {revoked}
share_revoke_all() {
    local dir d n=0
    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t share_err_no_jq)"; return 1; }
    dir=$(ga_share_state_dir)
    if [ -d "$dir" ]; then
        for d in "$dir"/s-*; do
            [ -d "$d" ] || continue
            ga_share_drop "$d" revoked
            n=$((n + 1))
        done
    fi
    if [ "$n" -gt 0 ]; then log_success "$(tf share_revoked_all "$n")"; else log_dim "$(t share_none)"; fi
    jq -nc --argjson n "$n" '{revoked: $n}'
}

# share_tick → stdout JSON {removed, active} — уборка просроченного для таймера.
# Ту же уборку делает любой другой вызов модуля: даже без таймера просроченная
# раздача не переживёт следующего обращения к share_list или share_create.
share_tick() {
    local removed active
    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t share_err_no_jq)"; return 1; }
    removed=$(ga_share_sweep)
    active=$(ga_share_count_active)
    log_dim "$(tf share_tick_done "$removed" "$active")"
    jq -nc --argjson r "${removed:-0}" --argjson a "$active" '{removed: $r, active: $a}'
}
