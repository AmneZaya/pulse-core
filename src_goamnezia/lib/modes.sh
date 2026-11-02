#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# goAmnezia pro — lib/modes.sh: режимы 0.6.0 (docs/MODES_047.md) — «Ленивый Pro» и линия на UDP 443 в Pro.
#
# Ленивый Pro — не режим, а сценарий: человек вводит только домен, а продукт сам проверяет DNS и порты, подхватывает
# контейнеры приложения Amnezia, ставит AmneziaWG 2.0 и 3.1, сайт с сертификатом Let's Encrypt, панель на домене,
# заводит ключи и страницу подключения на каждый. Итог — режим pro, а если UDP 443 занят — lite_site (Semi-Pro).
# Первая установка (мастер, install.sh --lazy) и пункт «Режим и сайт» на установленном сервере — один сценарий: он
# ничего не ломает (порты стоящих профилей с людьми не двигаются, рабочий сайт при отказе Let's Encrypt остаётся,
# ключи не множатся). Своего модуль ничего не ставит: каждый шаг — функция соседнего модуля (import_adopt,
# amnezia_profile_install, website_enable_pro, users_add, pages_create…); здесь только решение «что и в каком
# порядке» и сводка для моста. Внутренние id режимов прежние (pro, lite_site, lite) — на них стоят config.json,
# мост, бот, панель, MCP и goInstaller.
#
#   ga_modes_domain_norm <ввод>         домен из того, что вставил человек: схема, путь, порт, точка в конце —
#                                       прочь; кириллица — в punycode (GA_MODES_DOMAIN / GA_MODES_DISPLAY)
#   lazy_check <домен>                  что будет: DNS, порты, контейнеры приложения, план — только чтение
#   lazy_setup <домен> [ключей]         весь сценарий без вопросов (stdout — JSON договора моста)
#   pro_line_set <профиль> [согласие]   в Pro: выбранная линия на UDP 443, прежняя — на свободный случайный порт
#
# Договор моста (lazy-check, lazy-setup, pro-line) — docs/MODES_047.md (с «Уточнениями» 28.09) и docs/CONTRACT.md
# §4.7b. Коды отказов: invalid_domain, domain_is_ip, idn_failed, no_domain, invalid_keys, dns_not_here, port_busy,
# app_container_busy, awg2_container_busy, adopt_failed, mode_not_pro, adopted_keyless и коды соседних модулей.
#
# Правила модуля (контракт §0): stdout — только JSON у lazy_check / lazy_setup / pro_line_set; всё для человека —
# stderr через log_*; видимые строки — только t / tf (словарь lib/lang/<lang>.d/modes.sh); коды отказов — ga_err.
# GOAMNEZIA_DRY_RUN=1: всё, что трогает систему, делают соседние модули в своём сухом прогоне; DNS на стенде —
# GOAMNEZIA_DNS_STUB (без него домен считается указывающим сюда, как у _site_dns_points_here).
# ══════════════════════════════════════════════════════════════════════════════

GA_MODES_KEYS_DEFAULT=5
GA_MODES_KEYS_MAX=20
# Срок страницы подключения у ключей Ленивого Pro: месяц — чтобы раздать ссылки людям, а не бессрочный секрет.
GA_MODES_PAGE_TTL=30d

# ── Запасные помощники: модуль подключают и без lib/docker.sh ─────────────────
type ga_dry >/dev/null 2>&1 || ga_dry() { [ "${GOAMNEZIA_DRY_RUN:-0}" = "1" ]; }
if ! type ga_err >/dev/null 2>&1; then
    ga_err() {
        GA_ERR_CODE="$1"
        GA_ERR_MSG="$2"
        if declare -F ga_set_error >/dev/null 2>&1; then ga_set_error "$1"; fi
        log_error "$2"
        return "${3:-1}"
    }
fi

# Ожидание DNS в SSH и без терминала: раз в 15 секунд, до 5 минут (решение владельца 27.09). Стенды сокращают.
ga_modes_dns_interval() {
    local v="${GOAMNEZIA_LAZY_DNS_INTERVAL:-15}"
    [[ "$v" =~ ^[0-9]{1,4}$ ]] || v=15
    printf '%s' "$((10#$v))"
}
ga_modes_dns_timeout() {
    local v="${GOAMNEZIA_LAZY_DNS_TIMEOUT:-300}"
    [[ "$v" =~ ^[0-9]{1,5}$ ]] || v=300
    printf '%s' "$((10#$v))"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Домен
# ══════════════════════════════════════════════════════════════════════════════
# Строка из одних печатных ASCII? Счёт по байтам (C): в UTF-8 кириллица — байты выше 0x7F.
_ga_modes_ascii() {
    local LC_ALL=C
    [[ ! "${1:-}" =~ [^\ -~] ]]
}

# _ga_modes_idna encode|decode — stdin → stdout. python3 — зависимость ядра (lib/deps.sh): встроенный кодек idna
# (IDNA 2003) приводит национальные буквы к нижнему регистру и переводит в xn--, а обратно — для показа людям.
_ga_modes_idna() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 -c '
import sys
way = sys.argv[1]
v = sys.stdin.read().strip()
try:
    out = v.encode("idna").decode("ascii") if way == "encode" else v.encode("ascii").decode("idna")
except Exception:
    sys.exit(1)
if not out:
    sys.exit(1)
sys.stdout.write(out)
' "$1" 2>/dev/null
}

# ga_modes_domain_norm <ввод> — домен из того, что вставил человек (урок goVLESS pro, U-03: никаких тупиков).
# Итог — в переменных, а не в stdout (код отказа из подоболочки не дошёл бы):
#   GA_MODES_DOMAIN   — ASCII в нижнем регистре, кириллица — в punycode: он идёт в server_name nginx, в сертификат,
#                       в config.json и в адреса страниц;
#   GA_MODES_DISPLAY  — как его читают люди (кириллица — кириллицей);
#   GA_MODES_FIXED    — что поправлено: scheme, path, port, dot, idn (через пробел) — экран говорит об этом вслух.
# rc: 0 — годится; 1 — пусто; 2 — не домен (GA_ERR_CODE: invalid_domain | domain_is_ip | idn_failed).
GA_MODES_DOMAIN=""; GA_MODES_DISPLAY=""; GA_MODES_FIXED=""
ga_modes_domain_norm() {
    local v="${1:-}" fixed="" d
    GA_MODES_DOMAIN=""; GA_MODES_DISPLAY=""; GA_MODES_FIXED=""
    GA_ERR_CODE=""; GA_ERR_MSG=""
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    [ -n "$v" ] || return 1
    if [[ "$v" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then v="${v#*://}"; fixed+=" scheme"; fi
    case "$v" in */*|*\?*|*\#*) v="${v%%[/?#]*}"; fixed+=" path" ;; esac
    case "$v" in *@*) v="${v##*@}"; fixed+=" path" ;; esac
    if [[ "$v" =~ :[0-9]{1,5}$ ]]; then v="${v%:*}"; fixed+=" port"; fi
    if [[ "$v" == *. ]]; then
        while [[ "$v" == *. ]]; do v="${v%.}"; done
        fixed+=" dot"
    fi
    if [ -z "$v" ]; then
        ga_err invalid_domain "$(tf modes_err_domain "${1:-}")" 2
        return 2
    fi
    # Адрес вместо домена: Ленивому Pro нужен именно домен — на него выпускается сертификат.
    if [[ "$v" =~ ^[0-9.]+$ ]] || [[ "$v" == *:*:* ]] || [[ "$v" =~ ^\[.*\]$ ]]; then
        ga_err domain_is_ip "$(tf modes_err_domain_ip "$v")" 2
        return 2
    fi
    if ! _ga_modes_ascii "$v"; then
        if ! d=$(printf '%s' "$v" | _ga_modes_idna encode) || [ -z "$d" ]; then
            ga_err idn_failed "$(tf modes_err_idn "$v")" 2
            return 2
        fi
        v="$d"
        fixed+=" idn"
    fi
    v="${v,,}"
    if [ "${#v}" -gt 253 ] || ! validate_domain "$v"; then
        ga_err invalid_domain "$(tf modes_err_domain "${1:-}")" 2
        return 2
    fi
    GA_MODES_DOMAIN="$v"
    GA_MODES_DISPLAY="$v"
    if [[ "$v" == *xn--* ]]; then
        d=$(printf '%s' "$v" | _ga_modes_idna decode) || d=""
        [ -n "$d" ] && GA_MODES_DISPLAY="$d"
    fi
    GA_MODES_FIXED="${fixed# }"
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  Проверки: DNS, порты, контейнеры приложения, план
# ══════════════════════════════════════════════════════════════════════════════
# _ga_modes_dns_json <домен> → JSON ga_site_dns_state. Стенд без подставного DNS (GOAMNEZIA_DNS_STUB) в сеть не
# ходит и считает, что домен указывает сюда, — как _site_dns_points_here: сухие прогоны идут основным путём.
_ga_modes_dns_json() {
    local d="$1" js=""
    if ga_dry && [ -z "${GOAMNEZIA_DNS_STUB+x}" ]; then
        jq -nc --arg d "$d" '{domain: $d, state: "ok", a: [], own: [], ours: [], foreign: [], unpublished: [],
            cloudflare: false, aaaa: [], aaaa_foreign: [], assumed: true}'
        return 0
    fi
    type ga_site_dns_state >/dev/null 2>&1 && js=$(ga_site_dns_state "$d" 2>/dev/null)
    if [ -z "$js" ] || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$js"; then
        js=$(jq -nc --arg d "$d" '{domain: $d, state: "unknown", a: [], own: [], ours: [], foreign: [],
            unpublished: [], cloudflare: false, aaaa: [], aaaa_foreign: []}')
    fi
    printf '%s' "$js"
}

# Кто держит TCP 80, TCP 443 и UDP 443 — разбор предполётной проверки (lib/preflight.sh): один ss и один docker ps.
# Своё (наш nginx, наш контейнер) — свободно: повтор после оборванной установки не конфликт.
#   _GM_PST[k]    free | busy | closed_local | unknown     (k — tcp80, tcp443, udp443)
#   _GM_PBY[k]    кто держит, словами (пусто — свободен)
#   _GM_PCT[k]    контейнер, если порт держит контейнер
#   _GM_POURS[k]  true — порт держим мы сами (наш nginx, наш профиль): для сценария свободен, человеку — «занят нами»
declare -gA _GM_PST=() _GM_PBY=() _GM_PCT=() _GM_POURS=()
_ga_modes_ports() {
    local spec proto port k js st ours proc pid unit container product
    _GM_PST=(); _GM_PBY=(); _GM_PCT=(); _GM_POURS=()
    if ! type ga_pf_collect >/dev/null 2>&1 || ! type ga_pf_owner >/dev/null 2>&1; then
        for k in tcp80 tcp443 udp443; do _GM_PST[$k]=unknown; _GM_PBY[$k]=""; _GM_PCT[$k]=""; _GM_POURS[$k]=false; done
        return 0
    fi
    ga_pf_collect tcp udp
    for spec in tcp:80 tcp:443 udp:443; do
        proto="${spec%%:*}"; port="${spec##*:}"; k="${proto}${port}"
        js=$(ga_pf_owner "$proto" "$port" 2>/dev/null) || js=""
        jq -e 'type == "object"' >/dev/null 2>&1 <<<"$js" || js='{}'
        # Разделитель U+001F, а не таб: пустые поля (pid, контейнер) таб бы схлопнул.
        IFS=$'\x1f' read -r st ours proc pid unit container product <<<"$(jq -r '[(.state // "unknown"),
            (.ours | tostring), (.process // ""), (.pid // "" | tostring), (.unit // ""), (.container // ""),
            (.product // "")] | join("\u001f")' <<<"$js" 2>/dev/null)"
        _GM_POURS[$k]=false
        if [ "$st" = busy ] && [ "$ours" = true ]; then st=free; _GM_POURS[$k]=true; fi
        _GM_PST[$k]="${st:-unknown}"
        _GM_PCT[$k]="${container:-}"
        _GM_PBY[$k]=""
        if [ "$st" = busy ]; then
            _GM_PBY[$k]=$(ga_pf_describe_owner "$proc" "$pid" "$unit" "$container" "${product:-unknown}" 0)
        fi
    done
    return 0
}

# Контейнеры приложения Amnezia на сервере (import_scan: и остановленные, и других протоколов) → _GM_APPS (JSON).
# Docker не отвечает — список пуст, а в причинах — docker_unreachable: «контейнеров нет» и «не узнать» — разное.
_GM_APPS='[]'
_GM_APPS_UNKNOWN=0
_ga_modes_apps() {
    local js=""
    _GM_APPS='[]'; _GM_APPS_UNKNOWN=0
    type import_scan >/dev/null 2>&1 || return 0
    if ! ga_dry && ! command -v docker >/dev/null 2>&1; then return 0; fi
    GA_ERR_CODE=""
    if GA_IMPORT_QUIET=1 ga_capture js import_scan 2>/dev/null && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$js"; then
        _GM_APPS="$js"
    else
        _GM_APPS_UNKNOWN=1
    fi
    return 0
}

# Контейнер приложения Amnezia: имя со словом amnezia и не из нашего config.json (своё preflight считает «ours»).
_ga_modes_is_app() {
    [ -n "${1:-}" ] || return 1
    case "$1" in *amnezia*) ;; *) return 1 ;; esac
    type ga_pf_container_is_ours >/dev/null 2>&1 && ga_pf_container_is_ours "$1" && return 1
    return 0
}

# Подхватывать ли контейнеры приложения без вопроса. В SSH-мастере о подхвате уже спросил его первый экран
# (OWN-1): отказ человека уважаем — GA_MODES_ADOPT=0, и такие контейнеры просто занимают свои места.
_ga_modes_adopt_on() { [ "${GA_MODES_ADOPT:-1}" != 0 ]; }

# _ga_modes_plan <домен> — всё, что решает сценарий, в глобальных (читают lazy_check, lazy_setup и экраны SSH):
#   _GM_DNS, _GM_POINTS (A-записи сюда), _GM_CF (прокси Cloudflare), _GM_REASONS (коды), _GM_PLAN (pro | semi_pro |
#   blocked), _GM_HOLD443 (профиль, который останется на UDP 443), _GM_LINE443 (место профиля, которое встанет на
#   443) и _GM_LINE443_LINE (его линия), _GM_UDP443_LINE (какая линия будет на UDP 443 по итогу плана — «2.0», «3.1»…;
#   пусто — никакая: semi_pro, blocked); _GM_ADD — какие линии поставить и на какие места (_ga_modes_lines_need).
_GM_DNS='{}'; _GM_POINTS=false; _GM_CF=false; _GM_PLAN=""; _GM_HOLD443=""; _GM_LINE443=""; _GM_LINE443_LINE=""
_GM_UDP443_LINE=""
# Причины (договор моста, docs/MODES_047.md «Уточнения»): dns_none, dns_elsewhere, dns_partial, aaaa_foreign,
# cloudflare_proxied, tcp80_busy, tcp443_busy, tcp443_app, udp443_busy; сверх договора — dns_unknown (DNS не ответил),
# no_line_for_443 (обе линии стоят на своих портах с людьми) и awg2_container_busy. Заметки «как будет» (файрвол
# открою сам, контейнеры приложения подхвачу, UDP 443 останется у подхваченного) — только для экранов SSH.
_GM_REASONS=(); _GM_NOTES=()

# ── Линии — по версии, а не по месту профиля (находка LZ-02 живой проверки 0.6.0) ─────────────────────────────────
# Приложение Amnezia называет контейнеры по-своему: на живом сервере «amnezia-awg2» оказался линией 3.1, и сценарий,
# выбиравший по месту, ставил на UDP 443 вторую 3.1, а 2.0 на сервере не было вовсе. Место профиля (awg2, awg3) — это
# только имя контейнера; линия — по его параметрам (ga_profile_line) или по скану контейнера приложения. Сценарию
# нужны обе линии, 2.0 и 3.1: недостающая встаёт на своё место (2.0 → awg2, 3.1 → awg3), а если оно занято — на
# другое свободное (контейнер amnezia-awg3 с линией 2.0 так же законен, как подхваченный amnezia-awg2 с 3.1).
#   _GM_SLOT_LINE[место]  линия того, что стоит на месте (свой профиль или подхватываемый контейнер; «?» — не узнать)
#   _GM_SLOT_BUSY[место]  1 — место занято контейнером приложения с людьми, которого не подхватываем
# Итог _ga_modes_lines_need: _GM_ADD — «линия:место» по порядку 2.0 → 3.1; _GM_ADD_SKIP — линии, которым места нет.
declare -gA _GM_SLOT_LINE=() _GM_SLOT_BUSY=()
_GM_ADD=(); _GM_ADD_SKIP=()
# Правило — общее с «Установить» (ga_lines_need в lib/amnezia.sh, DUP-LINE-01): одно на весь продукт, не копия.
_ga_modes_lines_need() {
    ga_lines_need _GM_SLOT_LINE _GM_SLOT_BUSY _GM_ADD _GM_ADD_SKIP
}

# _ga_modes_slots_now — места по тому, что стоит сейчас (после подхвата): линия своего профиля; место, занятое
# контейнером приложения с людьми, — занято.
_ga_modes_slots_now() {
    local p l
    _GM_SLOT_LINE=(); _GM_SLOT_BUSY=()
    for p in awg1 awg2 awg3; do
        if ga_profile_installed "$p" 2>/dev/null; then
            l=$(ga_profile_line "$p" 2>/dev/null)
            _GM_SLOT_LINE[$p]="${l:-?}"
        elif _ga_modes_slot_busy "$p"; then
            _GM_SLOT_BUSY[$p]=1
        fi
    done
    return 0
}

# ga_modes_dns_ready <домен> — только DNS (его SSH перепроверяет раз в 15 секунд): _GM_DNS, _GM_POINTS (все A-записи
# сюда), _GM_CF (прокси Cloudflare — оранжевое облако: сайт и сертификат идут через прокси, ключи — прямо на IP,
# UDP Cloudflare не проводит). rc 0 — можно ставить: домен указывает сюда или стоит за прокси Cloudflare.
ga_modes_dns_ready() {
    local st cf
    _GM_POINTS=false; _GM_CF=false
    _GM_DNS=$(_ga_modes_dns_json "$1")
    st=$(jq -r '.state // "unknown"' <<<"$_GM_DNS" 2>/dev/null)
    cf=$(jq -r '.cloudflare == true' <<<"$_GM_DNS" 2>/dev/null)
    if [ "$st" = ok ]; then _GM_POINTS=true; return 0; fi
    if [ "$cf" = true ]; then _GM_CF=true; return 0; fi
    return 1
}

_ga_modes_plan() {
    local domain="$1" st k c p name kind managed ad sug peers port line hold_line="" blocked=0 semi=0
    local -A have=() occupied=() app_prof=() app_line=()
    _GM_REASONS=(); _GM_NOTES=(); _GM_PLAN=""; _GM_HOLD443=""; _GM_LINE443=""; _GM_LINE443_LINE=""; _GM_UDP443_LINE=""
    # DNS: все A-записи сюда; прокси Cloudflare — не отказ (ga_modes_dns_ready).
    ga_modes_dns_ready "$domain"
    st=$(jq -r '.state // "unknown"' <<<"$_GM_DNS" 2>/dev/null)
    if [ "$_GM_POINTS" = true ]; then
        :
    elif [ "$_GM_CF" = true ]; then
        _GM_REASONS+=(cloudflare_proxied)
    else
        case "$st" in
            elsewhere) _GM_REASONS+=(dns_elsewhere) ;;
            partial)   _GM_REASONS+=(dns_partial) ;;
            none)      _GM_REASONS+=(dns_none) ;;
            *)         _GM_REASONS+=(dns_unknown) ;;
        esac
        blocked=1
    fi
    [ "$(jq -r '(.aaaa_foreign // []) | length' <<<"$_GM_DNS" 2>/dev/null)" -gt 0 ] 2>/dev/null \
        && _GM_REASONS+=(aaaa_foreign)
    # TCP 80 и 443 — сайт и сертификат. Чужое не останавливаем: занято — отказ с именем владельца; контейнер приложения
    # Amnezia на TCP 443 (Xray, Cloak) — отдельной причиной: людей в нём молча не ломаем. Своё (наш nginx) — свободно.
    _ga_modes_ports
    _ga_modes_apps
    [ "$_GM_APPS_UNKNOWN" = 1 ] && _GM_NOTES+=(docker_unreachable)
    for k in tcp80 tcp443; do
        case "${_GM_PST[$k]}" in
            busy)
                if [ "$k" = tcp443 ] && _ga_modes_is_app "${_GM_PCT[$k]}"; then
                    _GM_REASONS+=(tcp443_app)
                else
                    _GM_REASONS+=("${k}_busy")
                fi
                blocked=1 ;;
            closed_local) _GM_NOTES+=("${k}_closed_local") ;;
        esac
    done
    # Линии: свои профили (и уже подхваченные) — с их портами; контейнеры приложения AmneziaWG, которые подхватим, —
    # тоже (их порты не трогаем, ACC-2); контейнер приложения с людьми, который не подхватываем, занимает место своего
    # профиля — ставить поверх него значило бы удалить людей.
    for p in awg1 awg2 awg3; do
        ga_profile_installed "$p" 2>/dev/null || continue
        have[$p]=$(ga_profile_field "$p" port 2>/dev/null)
    done
    while IFS=$'\x1f' read -r name kind managed ad sug peers port line; do
        [ -n "$name" ] || continue
        [ "$managed" = true ] && continue
        case "$kind" in awg|legacy) ;; *) continue ;; esac
        [ -n "$sug" ] || continue
        [[ "$peers" =~ ^[0-9]+$ ]] || peers=0
        if [ "$ad" = true ] && _ga_modes_adopt_on; then
            if [ -z "${have[$sug]:-}" ]; then have[$sug]="$port"; app_line[$sug]="$line"; fi
            app_prof[$name]="$sug"
            app_line[$name]="$line"
        elif [ "$peers" -gt 0 ]; then
            occupied[$sug]="$name"
        fi
    done < <(jq -r '.[]? | [.container, (.kind // ""), (.managed | tostring), (.adoptable | tostring),
        (.suggested_profile // ""), (.peers // 0 | tostring), (.port // 0 | tostring), (.line // "")]
        | join("\u001f")' <<<"$_GM_APPS" 2>/dev/null)
    if [ -z "${have[awg2]:-}" ] && [ -n "${occupied[awg2]:-}" ]; then
        _GM_REASONS+=(awg2_container_busy); blocked=1
    fi
    # UDP 443: свой профиль или подхватываемый контейнер приложения AmneziaWG на нём — он там и останется; чужой
    # процесс — Semi-Pro (сайт на 443, профили на своих портах).
    case "${_GM_PST[udp443]}" in
        busy)
            c="${_GM_PCT[udp443]}"
            if [ -n "$c" ] && [ -n "${app_prof[$c]:-}" ]; then
                _GM_HOLD443="${app_prof[$c]}"
                hold_line="${app_line[$c]:-}"
                _GM_NOTES+=(udp443_app)
            else
                _GM_REASONS+=(udp443_busy); semi=1
            fi ;;
        closed_local) _GM_NOTES+=(udp443_closed_local) ;;
    esac
    if [ "$semi" = 0 ] && [ -z "$_GM_HOLD443" ]; then
        for p in awg1 awg2 awg3; do
            [ "${have[$p]:-}" = 443 ] || continue
            _GM_HOLD443="$p"
            # Свой (или подхваченный раньше) профиль — его линия из config.json; подхватываемый контейнер — из скана.
            if ga_profile_installed "$p" 2>/dev/null; then hold_line=$(ga_profile_line "$p" 2>/dev/null)
            else hold_line="${app_line[$p]:-}"
            fi
        done
    fi
    # Какие линии стоят — по версии (LZ-02): свой профиль — по config.json, подхватываемый контейнер — по скану.
    _GM_SLOT_LINE=(); _GM_SLOT_BUSY=()
    for p in awg1 awg2 awg3; do
        if ga_profile_installed "$p" 2>/dev/null; then
            line=$(ga_profile_line "$p" 2>/dev/null); _GM_SLOT_LINE[$p]="${line:-?}"
        elif [ -n "${have[$p]:-}" ]; then
            _GM_SLOT_LINE[$p]="${app_line[$p]:-?}"
        elif [ -n "${occupied[$p]:-}" ]; then
            _GM_SLOT_BUSY[$p]=1
        fi
    done
    _ga_modes_lines_need
    # На 443 — недостающая линия: 2.0 (решение владельца 27.09: шире всего поддержка клиентов, включая Keenetic), а
    # если 2.0 уже стоит на своём порту (подхвачена или поставлена раньше — её порт с людьми не трогаем) — 3.1. Обе
    # стоят на своих портах — на 443 ставить нечего: Semi-Pro, перенести линию на 443 можно потом явно (pro-line).
    if [ "$semi" = 0 ] && [ -z "$_GM_HOLD443" ]; then
        if [ "${#_GM_ADD[@]}" -gt 0 ]; then
            _GM_LINE443="${_GM_ADD[0]#*:}"; _GM_LINE443_LINE="${_GM_ADD[0]%%:*}"
        else
            _GM_REASONS+=(no_line_for_443); semi=1
        fi
    fi
    [ "$(jq -r '[.[]? | select(.managed != true)] | length' <<<"$_GM_APPS" 2>/dev/null)" -gt 0 ] 2>/dev/null \
        && _GM_NOTES+=(app_containers)
    if [ "$blocked" = 1 ]; then _GM_PLAN=blocked
    elif [ "$semi" = 1 ]; then _GM_PLAN=semi_pro
    else _GM_PLAN=pro
    fi
    # Какая линия будет на UDP 443 (lazy-check: udp443_line): только у плана pro — та, что там уже стоит (наша или
    # подхватываемая: её порт с людьми не трогаем), иначе та, что встанет; у semi_pro и blocked — никакая.
    if [ "$_GM_PLAN" = pro ]; then
        if [ -n "$_GM_HOLD443" ]; then _GM_UDP443_LINE="$hold_line"
        elif [ -n "$_GM_LINE443" ]; then _GM_UDP443_LINE="$_GM_LINE443_LINE"
        fi
    fi
    [[ "$_GM_UDP443_LINE" =~ ^(1\.0|1\.5|2\.0|3\.1)$ ]] || _GM_UDP443_LINE=""
    return 0
}
# _ga_modes_has_reason <код> — есть ли такой код в _GM_REASONS
_ga_modes_has_reason() {
    local r
    for r in "${_GM_REASONS[@]}"; do [ "$r" = "$1" ] && return 0; done
    return 1
}

# _ga_modes_reasons_json → JSON-массив кодов
_ga_modes_reasons_json() {
    if [ "${#_GM_REASONS[@]}" -eq 0 ]; then printf '[]'; return 0; fi
    printf '%s\n' "${_GM_REASONS[@]}" | jq -R . | jq -sc .
}

# _ga_modes_dns_words <JSON DNS> <домен для людей> — почему домен «не сюда», словами (по коду состояния).
_ga_modes_dns_words() {
    local js="$1" shown="$2" st a own foreign
    st=$(jq -r '.state // "unknown"' <<<"$js" 2>/dev/null)
    a=$(jq -r '(.a // []) | join(", ")' <<<"$js" 2>/dev/null)
    foreign=$(jq -r '(.foreign // []) | join(", ")' <<<"$js" 2>/dev/null)
    own=$(ga_site_own_ips 2>/dev/null | paste -sd, - | sed 's/,/, /g')
    [ -n "$own" ] || own="-"
    case "$st" in
        none)      tf modes_err_dns_none "$shown" "$own" ;;
        partial)   tf modes_err_dns_partial "$shown" "${foreign:--}" "$own" ;;
        elsewhere) tf modes_err_dns "$shown" "${a:--}" "$own" ;;
        *)         tf modes_err_dns_unknown "$shown" ;;
    esac
}

# _ga_modes_reason_text <код> — одна причина словами (для message моста и экранов SSH).
_ga_modes_reason_text() {
    local shown="${GA_MODES_DISPLAY:-$GA_MODES_DOMAIN}" ip
    case "$1" in
        dns_elsewhere|dns_partial|dns_none|dns_unknown) _ga_modes_dns_words "$_GM_DNS" "$shown" ;;
        cloudflare_proxied)
            ip=$(ga_site_server_ip 2>/dev/null)
            tf modes_why_cloudflare "$shown" "${ip:--}" ;;
        aaaa_foreign) tf modes_why_aaaa "$shown" "$(jq -r '(.aaaa_foreign // []) | join(", ")' <<<"$_GM_DNS" 2>/dev/null)" ;;
        tcp80_busy)   tf modes_err_port_busy "TCP/80" "${_GM_PBY[tcp80]:-?}" ;;
        tcp443_busy)  tf modes_err_port_busy "TCP/443" "${_GM_PBY[tcp443]:-?}" ;;
        tcp443_app)   tf modes_err_app_port "TCP/443" "${_GM_PCT[tcp443]:-?}" ;;
        tcp80_closed_local)   tf modes_why_closed "TCP/80" ;;
        tcp443_closed_local)  tf modes_why_closed "TCP/443" ;;
        udp443_closed_local)  tf modes_why_closed "UDP/443" ;;
        udp443_busy)  tf modes_why_udp443_busy "${_GM_PBY[udp443]:-?}" ;;
        udp443_app)   tf modes_why_udp443_app "${_GM_PCT[udp443]:-?}" ;;
        no_line_for_443) t modes_why_no_line ;;
        awg2_container_busy) t modes_err_awg2_busy ;;
        app_containers) tf modes_why_apps "$(jq -r '[.[]? | select(.managed != true) | .container] | join(", ")' <<<"$_GM_APPS" 2>/dev/null)" ;;
        docker_unreachable) t modes_why_docker ;;
        *) printf '%s' "$1" ;;
    esac
}

# _ga_modes_blocking — первая причина, из-за которой сценарий не пойдёт: код отказа моста и слова.
# stdout: «код<U+001F>причина». Порядок — от того, что человек поправит быстрее всего, к тому, что не поправить.
_ga_modes_blocking() {
    local r code=""
    for r in tcp443_app tcp443_busy tcp80_busy awg2_container_busy dns_elsewhere dns_partial dns_none dns_unknown; do
        _ga_modes_has_reason "$r" || continue
        case "$r" in
            tcp443_app)           code=app_container_busy ;;
            tcp*_busy)            code=port_busy ;;
            awg2_container_busy)  code=awg2_container_busy ;;
            dns_*)                code=dns_not_here ;;
        esac
        printf '%s\x1f%s' "$code" "$(_ga_modes_reason_text "$r")"
        return 0
    done
    printf 'blocked\x1f'
}

# Итог проверки словами — для message моста и экранов SSH: почему Semi-Pro и почему сценарий не пойдёт.
ga_modes_semi_words() {
    if _ga_modes_has_reason udp443_busy; then _ga_modes_reason_text udp443_busy
    elif _ga_modes_has_reason no_line_for_443; then _ga_modes_reason_text no_line_for_443
    fi
}
ga_modes_blocking_words() {
    local blk
    blk=$(_ga_modes_blocking)
    printf '%s' "${blk#*$'\x1f'}"
}

# _ga_modes_apps_json → [{name, line, port}] контейнеров приложения (не наших). line — линия AmneziaWG (1.0, 1.5, 2.0,
# 3.1); у других протоколов приложения (Xray, OpenVPN…) пусто — goAmnezia их не ведёт.
_ga_modes_apps_json() {
    jq -c '[.[]? | select(.managed != true)
            | {name: .container, line: (if (.kind == "awg" or .kind == "legacy") then (.line // "") else "" end),
               port: (.port // 0)}]' <<<"$_GM_APPS" 2>/dev/null || printf '[]'
}

# _ga_modes_keys_have — сколько ключей прошлых заходов Ленивого Pro живы (config.json .lazy.keys): сценарий их
# засчитывает, новых заводит только недостающие.
_ga_modes_keys_have() {
    local id n=0
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        users_exists "$id" 2>/dev/null && n=$((n + 1))
    done < <(jq -r '(.lazy.keys // [])[]? // empty' "$CONFIG_FILE" 2>/dev/null)
    printf '%s' "$n"
}

# lazy_check <домен> [ключей] → stdout JSON договора: {domain, domain_display, points_here, a, aaaa, server_ips,
# cloudflare_proxied, ports: {tcp80, tcp443, udp443: {free, by, ours}}, app_containers: [{name, line, port}],
# plan: pro | semi_pro | blocked, reasons: [код…], udp443_line, keys_have, keys_new}. by — кто держит порт, словами
# предполётной проверки («nginx (PID 812, юнит nginx.service) — похоже, это goTelegram Pro», «docker (контейнер
# amnezia-xray)»), у свободного — null; ours — порт держим мы сами (наш nginx, наш профиль): для сценария он свободен,
# человеку — «занят нами» (LZ-05). udp443_line — какая линия будет на UDP 443 («2.0», «3.1»; null — никакая: semi_pro,
# blocked). keys_have — ключи прошлых заходов (засчитываются), keys_new — сколько ключей сценарий заведёт на самом
# деле из просимых (по умолчанию 5). Только чтение: ничего не пишет и не ставит.
lazy_check() {
    local input="${1:-}" keys="${2:-$GA_MODES_KEYS_DEFAULT}" rc=0 own ports have new
    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t err_no_jq)"; return 1; }
    ga_modes_domain_norm "$input" || rc=$?
    if [ "$rc" = 1 ]; then ga_err no_domain "$(t modes_err_no_domain)" 2; return 2; fi
    [ "$rc" = 0 ] || return 2
    if ! [[ "$keys" =~ ^[0-9]{1,3}$ ]] || [ "$((10#$keys))" -lt 1 ] || [ "$((10#$keys))" -gt "$GA_MODES_KEYS_MAX" ]; then
        ga_err invalid_keys "$(tf modes_err_keys "$GA_MODES_KEYS_MAX" "$keys")" 2
        return 2
    fi
    keys=$((10#$keys))
    _ga_modes_plan "$GA_MODES_DOMAIN"
    have=$(_ga_modes_keys_have); [[ "$have" =~ ^[0-9]+$ ]] || have=0
    new=$(( keys > have ? keys - have : 0 ))
    own=$(ga_site_own_ips 2>/dev/null | jq -R . | jq -sc 'map(select(. != ""))') || own='[]'
    [ -n "$own" ] || own='[]'
    ports=$(jq -nc --arg s80 "${_GM_PST[tcp80]}" --arg b80 "${_GM_PBY[tcp80]}" --arg o80 "${_GM_POURS[tcp80]:-false}" \
                   --arg s443 "${_GM_PST[tcp443]}" --arg b443 "${_GM_PBY[tcp443]}" --arg o443 "${_GM_POURS[tcp443]:-false}" \
                   --arg su "${_GM_PST[udp443]}" --arg bu "${_GM_PBY[udp443]}" --arg ou "${_GM_POURS[udp443]:-false}" '
        def by($s; $b): if $s == "busy" and $b != "" then $b else null end;
        {tcp80: {free: ($s80 != "busy"), by: by($s80; $b80), ours: ($o80 == "true")},
         tcp443: {free: ($s443 != "busy"), by: by($s443; $b443), ours: ($o443 == "true")},
         udp443: {free: ($su != "busy"), by: by($su; $bu), ours: ($ou == "true")}}')
    jq -nc --arg d "$GA_MODES_DOMAIN" --arg disp "$GA_MODES_DISPLAY" --argjson points "$_GM_POINTS" \
        --argjson dns "$_GM_DNS" --argjson own "$own" --argjson cf "$_GM_CF" --argjson ports "$ports" \
        --argjson apps "$(_ga_modes_apps_json)" --arg plan "$_GM_PLAN" --argjson reasons "$(_ga_modes_reasons_json)" \
        --arg line "$_GM_UDP443_LINE" --argjson have "$have" --argjson new "$new" '
        {domain: $d, domain_display: $disp, points_here: $points, a: ($dns.a // []), aaaa: ($dns.aaaa // []),
         server_ips: $own, cloudflare_proxied: $cf, ports: $ports, app_containers: $apps,
         plan: $plan, reasons: $reasons, udp443_line: (if $line == "" then null else $line end),
         keys_have: $have, keys_new: $new}'
}

# ══════════════════════════════════════════════════════════════════════════════
#  Сценарий
# ══════════════════════════════════════════════════════════════════════════════
# Предупреждения сценария — коды для моста (warnings) и строки для человека (stderr) в момент, когда они случились.
GA_MODES_WARN=()
_ga_modes_warn() {
    local code="$1" r
    shift
    for r in "${GA_MODES_WARN[@]}"; do [ "$r" = "$code" ] && { [ $# -gt 0 ] && log_warning "$*"; return 0; }; done
    GA_MODES_WARN+=("$code")
    [ $# -gt 0 ] && log_warning "$*"
    return 0
}

# Имя режима для людей по id (ключи — те же, что у экранов SSH).
_ga_modes_mode_word() {
    case "${1:-}" in
        pro)       t ms_mode_name_pro ;;
        lite_site) t ms_mode_name_lite_site ;;
        *)         t ms_mode_name_lite ;;
    esac
}

# Профили с портами: [{id, line, port}] — всё, что стоит, по порядку 3.1 → 2.0 → 1.x.
ga_modes_profiles_json() {
    local p acc='[]' port
    for p in awg3 awg2 awg1; do
        ga_profile_installed "$p" 2>/dev/null || continue
        port=$(ga_profile_field "$p" port 2>/dev/null)
        [[ "$port" =~ ^[0-9]+$ ]] || port=0
        acc=$(jq -c --arg p "$p" --arg l "$(ga_profile_line "$p" 2>/dev/null)" --argjson port "$port" \
            '. + [{id: $p, line: $l, port: $port}]' <<<"$acc") || acc="$acc"
    done
    printf '%s' "$acc"
}

# Профиль на UDP 443 (пусто — никого).
ga_modes_udp443_profile() {
    local p
    for p in awg3 awg2 awg1; do
        ga_profile_installed "$p" 2>/dev/null || continue
        [ "$(ga_profile_field "$p" port 2>/dev/null)" = 443 ] && { printf '%s' "$p"; return 0; }
    done
    return 1
}

# Профиль занят контейнером приложения с людьми (подхват не состоялся или от него отказались) — ставить нельзя.
_ga_modes_slot_busy() {
    local c n
    type ga_amn_foreign_peers >/dev/null 2>&1 || return 1
    c=$(ga_profile_default "$1" container 2>/dev/null) || return 1
    n=$(ga_amn_foreign_peers "$c" 2>/dev/null) || n=0
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ]
}

# Подхват контейнеров приложения без вопроса (решение владельца 27.09): контейнеры не пересоздаются, порты и ключи
# людей остаются (import_adopt). Не вышло с местом 2.0 — дальше не идём: ставить профиль поверх людей нельзя.
_ga_modes_adopt_all() {
    local row c sug peers n=0
    local -a todo=()
    _ga_modes_adopt_on || return 0
    mapfile -t todo < <(jq -r '.[]? | select(.adoptable == true)
        | [.container, (.suggested_profile // ""), (.peers // 0 | tostring)] | join("\u001f")' <<<"$_GM_APPS" 2>/dev/null)
    local res ovl
    for row in "${todo[@]}"; do
        IFS=$'\x1f' read -r c sug peers <<<"$row"
        [ -n "$c" ] || continue
        GA_ERR_CODE=""; GA_ERR_MSG=""
        if GA_IMPORT_QUIET=1 ga_capture res import_adopt "$c"; then
            n=$((n + 1))
            # Подсеть совпала с другим профилем (приложение ставит свои контейнеры на одну 10.8.1.0/24, SUBNET-01):
            # подхвачен как есть, люди ходят как ходили; без вопроса не переносим — предупреждение с выходом.
            ovl=$(jq -c '.subnet_overlap // empty' <<<"$res" 2>/dev/null) || ovl=""
            if [ -n "$ovl" ] && type ga_amn_subnet_overlap_text >/dev/null 2>&1; then
                _ga_modes_warn subnet_overlap "$(ga_amn_subnet_overlap_text "$ovl")"
            fi
            continue
        fi
        [[ "$peers" =~ ^[0-9]+$ ]] || peers=0
        if [ "$sug" = awg2 ] && [ "$peers" -gt 0 ]; then
            ga_err adopt_failed "$(tf modes_err_adopt "$c" "${GA_ERR_MSG:-${GA_ERR_CODE:-?}}")"
            return 1
        fi
        _ga_modes_warn adopt_failed "$(tf modes_warn_adopt_failed "$c" "${GA_ERR_MSG:-${GA_ERR_CODE:-?}}")"
    done
    [ "$n" -gt 0 ] && _ga_modes_warn adopted
    return 0
}

# Порты сайта, закрытые локальным файрволом, открываем сами — «остальное сделаю сам»; чужой процесс не трогаем.
_ga_modes_open_ports() {
    local k port
    type preflight_open_local >/dev/null 2>&1 || return 0
    for k in tcp80 tcp443; do
        [ "${_GM_PST[$k]:-}" = closed_local ] || continue
        port="${k#tcp}"
        if ! preflight_open_local "$port" tcp; then
            _ga_modes_warn firewall_open_failed "$(tf modes_warn_firewall "$port")"
        fi
    done
    return 0
}

# Ответы — в config.json до установки профилей (как мастер): сорвалась установка — повтор не спрашивает заново.
# На установленном сервере режим и домен меняет сам модуль сайта (при удаче), а версию ведёт миграция — здесь их
# не трогаем: отказ Let's Encrypt не должен оставить ярлык режима, который врёт.
_ga_modes_write_answers() {
    local mode="$1" domain="$2" ip="" patch='{}'
    if [ "$(ga_config_get .installed 2>/dev/null)" != true ]; then
        patch=$(jq -nc --arg m "$mode" --arg d "$domain" --arg v "${GOAMNEZIA_VERSION:-}" '{mode: $m, domain: $d, version: $v}')
    fi
    if [ -z "$(ga_config_get .server_ip 2>/dev/null)" ]; then
        # Адрес SSH-входа, если он публичный и на машине (_ssh_inbound_ip в install.sh), — иначе внешний.
        type _ssh_inbound_ip >/dev/null 2>&1 && ip=$(_ssh_inbound_ip 2>/dev/null)
        [ -n "$ip" ] || ip=$(ga_site_server_ip 2>/dev/null)
        [ -n "$ip" ] && patch=$(jq -c --arg ip "$ip" '. + {server_ip: $ip}' <<<"$patch")
    fi
    # DNS клиентов — Google, как у мастера (решение владельца 10.09): только если его ещё не задавали.
    if [ "$(jq -r '(.client_dns // []) | length' "$CONFIG_FILE" 2>/dev/null || echo 0)" = 0 ]; then
        patch=$(jq -c '. + {client_dns: ["8.8.8.8", "8.8.4.4"]}' <<<"$patch")
    fi
    ga_config_merge "$patch" >/dev/null || { ga_err config_write_failed "$(t modes_err_config)"; return 1; }
}

# Ставит недостающие линии (_GM_ADD, порядок 2.0 → 3.1 — по версии, а не по месту профиля, LZ-02): линия для UDP 443 —
# на 443, остальные — на случайный порт (его выбирает сам модуль профилей); на чужом месте — с линией по просьбе
# (amnezia_profile_install, пятый аргумент). Не встала 2.0 — дальше не идём (её понимает больше всего клиентов, на ней
# держится продукт), 3.1 — идём. Линии без места (всё занято контейнерами приложения с людьми) — предупреждением.
_ga_modes_install_profiles() {
    local line443="$1" e L p port
    for L in "${_GM_ADD_SKIP[@]}"; do
        _ga_modes_warn line_skipped "$(tf modes_warn_line_skipped "AmneziaWG $L")"
    done
    for e in "${_GM_ADD[@]}"; do
        L="${e%%:*}"; p="${e#*:}"
        port=""
        [ "$p" = "$line443" ] && port=443
        GA_ERR_CODE=""; GA_ERR_MSG=""
        if ga_step "$(tf modes_step_line "$L")" "$(tf modes_step_line_done "$L")" "$(t eta_profile)" \
                amnezia_profile_install "$p" "$port" default "" "$L"; then
            continue
        fi
        [ "$L" = 2.0 ] && return 1
        _ga_modes_warn profile_failed "$(tf modes_warn_profile_failed "AmneziaWG $L" "${GA_ERR_MSG:-${GA_ERR_CODE:-?}}")"
    done
    return 0
}

# Сайт: основной путь — домен и Let's Encrypt (случайный шаблон, до трёх попыток, потом встроенная заглушка;
# панель на домене включается сама). Отказ Let's Encrypt — запасной самоподписанный, домен сохраняется; не встал и
# он — Lite, как у мастера. Но если сайт уже жил на домене с настоящим сертификатом (Ленивый Pro из «Режим и сайт»),
# отказ — это отказ: модуль сайта вернул прежний домен, и менять рабочий сайт на запасной ради нового домена нельзя
# (повторный запуск ничего не ломает). rc 1 — тогда; вид исхода — в _GM_SITE (le | selfsigned | none).
# _GM_HAD_LE — сайт жил на домене с настоящим сертификатом ДО сценария; lazy_setup ставит его до записи ответов
# (запись режима с сайтом без site.cert модуль сайта читает как Let's Encrypt — у старых установок так и было).
_GM_SITE=""; _GM_HAD_LE=0
_ga_modes_site() {
    local mode="$1" domain="$2" msg had_le="${_GM_HAD_LE:-0}" code
    _GM_SITE=""
    # Причина отказа Let's Encrypt (dns | net | limit, lib/website.sh) переживает запасной путь: ответ сценария несёт
    # её рядом с cert_fallback, чтобы бот сказал, почему сайт на запасном и что делать (L-26).
    GA_ERR_CODE=""; GA_ERR_MSG=""; GA_CERT_CAUSE=""; GA_CERT_RETRY_AFTER=""
    if ga_step "$(tf modes_step_site "$GA_MODES_DISPLAY")" "$(tf modes_step_site_done "$domain")" "$(t modes_eta_site)" \
            website_enable_pro "$domain" "" "$mode"; then
        _GM_SITE=le
    else
        code="${GA_ERR_CODE:-cert_failed}"
        msg="${GA_ERR_MSG:-$code}"
        if [ "$had_le" = 1 ]; then
            ga_err "$code" "$msg"
            return 1
        fi
        GA_ERR_CODE=""; GA_ERR_MSG=""
        if ga_step "$(t modes_step_site_ss)" "$(t modes_step_site_ss_done)" "" website_enable_site_selfsigned "" "$mode"; then
            ga_config_merge "$(jq -nc --arg d "$domain" '{domain: $d}')" >/dev/null 2>&1 || true
            _GM_SITE=selfsigned
            _ga_modes_warn cert_fallback "$(tf modes_warn_cert "$GA_MODES_DISPLAY" "$msg")"
        else
            ga_config_merge '{"mode":"lite"}' >/dev/null 2>&1 || true
            _GM_SITE=none
            _ga_modes_warn site_failed "$(t modes_warn_site_failed)"
        fi
    fi
    [ "$(ga_config_get .site.template_id 2>/dev/null)" = "${GA_SITE_STUB_ID:-builtin_stub}" ] && _ga_modes_warn template_fallback
    return 0
}

# Панель — службой (для туннеля и для домена): молча, пароль выдаст сводка SSH один раз (_panel_ensure_local и
# _panel_password_pending_issue в install.sh). Без install.sh (модуль сам по себе) ставить нечем.
_ga_modes_panel() {
    type _panel_ensure_local >/dev/null 2>&1 || return 0
    ga_step "$(t modes_step_panel)" "$(t modes_step_panel_done)" "" _panel_ensure_local \
        || _ga_modes_warn panel_off "$(t modes_warn_panel)"
    return 0
}

# Панель на домене работает: сайт на настоящем сертификате, путь выдан, служба стоит.
ga_modes_panel_on_domain() {
    type ga_site_domain_ready >/dev/null 2>&1 && ga_site_domain_ready || return 1
    [ -n "$(ga_config_get .panel.miniapp_path 2>/dev/null)" ] || return 1
    if type _panel_present >/dev/null 2>&1; then _panel_present; return $?; fi
    [ -f "${ADMIN_DIR:-/opt/goamnezia-admin}/server.py" ]
}

# Ключи: N человек со случайными именами «прилагательное + столица» (lib/names_capitals.json, язык подписи — язык
# установки), у каждого — обе линии 2.0 и 3.1 (подхваченный старый 1.x — нет: первая запись в него — только по
# решению владельца, как у мастера). Заведённые прошлым заходом (config.json .lazy.keys) засчитываются — повтор после
# обрыва не плодит лишних. Итог — в _GM_KEYS.
_GM_KEYS=()
_ga_modes_keys() {
    local want="$1" p csv="" js id label have=0 n tries=0 lang="${LANG_CODE:-ru}" names
    _GM_KEYS=()
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        users_exists "$id" 2>/dev/null || continue
        _GM_KEYS+=("$id")
    done < <(jq -r '(.lazy.keys // [])[]? // empty' "$CONFIG_FILE" 2>/dev/null)
    have=${#_GM_KEYS[@]}
    for p in awg3 awg2; do
        ga_profile_installed "$p" 2>/dev/null || continue
        [ "$(ga_config_get ".profiles.$p.iface" 2>/dev/null)" = wg0 ] && continue
        csv="${csv:+$csv,}$p"
    done
    [ -n "$csv" ] || { ga_err no_profiles "$(t modes_err_no_profiles)"; return 1; }
    # Ключи прошлых заходов — тоже «у каждого обе линии» (находка WA-2 стенда 15.10): линия, которую поставил этот заход
    # (недостающая 2.0 рядом с подхваченной 3.1), им выдаётся сразу; раньше ключ на ней не получал никто.
    # Только линии, поставленные этим заходом (_GM_ADD «линия:место»): пир, который админ сам снял у ключа на старой
    # линии, обратно не возвращаем (находка проверки 15.10).
    local e newp=""
    for e in "${_GM_ADD[@]}"; do
        p="${e#*:}"
        [[ ",$csv," == *",$p,"* ]] && newp="${newp:+$newp }$p"
    done
    for id in "${_GM_KEYS[@]}"; do
        for p in $newp; do
            [ "$(ga_users_get "$id" 2>/dev/null | jq -r --arg p "$p" '(.peers // {})[$p] != null' 2>/dev/null)" = false ] || continue
            users_add_peer "$id" "$p" >/dev/null 2>&1 || _ga_modes_warn keys_partial "$(tf modes_warn_peer_failed "$id" "$(ga_amn_profile_label "$p")")"
        done
    done
    n=$have
    while [ "$n" -lt "$want" ] && [ "$tries" -lt $((want * 3)) ]; do
        tries=$((tries + 1))
        GA_ERR_CODE=""; GA_ERR_MSG=""
        ga_capture js users_name_suggest "$lang" 2>/dev/null || break
        id=$(jq -r '.id // ""' <<<"$js" 2>/dev/null); label=$(jq -r '.label // ""' <<<"$js" 2>/dev/null)
        [ -n "$id" ] || break
        users_add "$id" "$label" "$csv" 0 0 >/dev/null || continue
        _GM_KEYS+=("$id")
        n=$((n + 1))
        names=$(printf '%s\n' "${_GM_KEYS[@]}" | jq -R . | jq -sc .)
        ga_config_merge "$(jq -nc --argjson k "$names" '{lazy: {keys: $k}}')" >/dev/null 2>&1 || true
    done
    [ "${#_GM_KEYS[@]}" -ge "$want" ] || _ga_modes_warn keys_partial "$(tf modes_warn_keys_short "${#_GM_KEYS[@]}" "$want")"
    [ "${#_GM_KEYS[@]}" -gt 0 ]
}

# Страницы подключения — по одной на ключ, только на домене с настоящим сертификатом (иначе браузер телефона её не
# откроет). Страница прошлого захода жива — её адрес, новую не заводим. Итог — _GM_PAGE[имя] = адрес.
declare -gA _GM_PAGE=()
_ga_modes_pages() {
    local name id js url n=0
    _GM_PAGE=()
    # Без сайта на настоящем сертификате страниц нет (keys[].page — null): причина уже в cert_fallback / site_failed.
    type pages_create >/dev/null 2>&1 && ga_pages_domain_ready 2>/dev/null || return 0
    for name in "${_GM_KEYS[@]}"; do
        url=""
        id=$(jq -r --arg n "$name" '.lazy.pages[$n] // ""' "$CONFIG_FILE" 2>/dev/null)
        if [ -n "$id" ] && ga_capture js pages_url "$id" 2>/dev/null; then
            url=$(jq -r '.url // ""' <<<"$js" 2>/dev/null)
        fi
        if [ -z "$url" ]; then
            GA_ERR_CODE=""; GA_ERR_MSG=""
            if ga_capture js pages_create "$name" "$GA_MODES_PAGE_TTL" "" on 2>/dev/null; then
                url=$(jq -r '.url // ""' <<<"$js" 2>/dev/null)
                id=$(jq -r '.id // ""' <<<"$js" 2>/dev/null)
                [ -n "$id" ] && ga_config_merge "$(jq -nc --arg n "$name" --arg id "$id" '{lazy: {pages: {($n): $id}}}')" >/dev/null 2>&1
            fi
        fi
        js=""
        [ -n "$url" ] && { _GM_PAGE[$name]="$url"; n=$((n + 1)); }
    done
    [ "$n" -gt 0 ]
}

# lazy_setup <домен> [ключей] → stdout JSON договора: {mode, domain, udp443: {profile, line} | null,
# profiles: [{id, line, port}], site: {template}, panel_on_domain, keys: [{name, label, page | null}], warnings: [код…]}.
# Весь сценарий без вопросов. На чистом сервере — первая установка; на установленном (Ленивый Pro из «Режим и сайт»)
# — то же без поломок: порты стоящих профилей с людьми не двигаются, сайт на прежнем домене при отказе Let's Encrypt
# остаётся, ключи Ленивого Pro (config.json .lazy.keys) засчитываются — повтор не плодит лишних. Отказ проверки — ДО
# любых изменений: коды dns_not_here, port_busy, app_container_busy, awg2_container_busy; причины списком — в
# GA_MODES_REASONS_JSON (их кладёт в ответ мост). warnings — коды сценария (template_fallback, cert_fallback, adopted,
# keys_partial, panel_off; редкие — adopt_failed, firewall_open_failed, line_skipped, profile_failed, site_failed,
# timers_failed, subnet_overlap — контейнеры приложения подхвачены на одной подсети, SUBNET-01) и все причины проверки,
# которые сценарий обошёл (udp443_busy, cloudflare_proxied, aaaa_foreign…).
GA_MODES_REASONS_JSON='[]'
lazy_setup() {
    local input="${1:-}" keys="${2:-$GA_MODES_KEYS_DEFAULT}" rc=0 domain mode code msg blk line443 js name label
    local p443now line443now warns ip
    GA_MODES_WARN=(); GA_MODES_REASONS_JSON='[]'; GA_CERT_CAUSE=""; GA_CERT_RETRY_AFTER=""
    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t err_no_jq)"; return 1; }
    if ! [[ "$keys" =~ ^[0-9]{1,3}$ ]] || [ "$((10#$keys))" -lt 1 ] || [ "$((10#$keys))" -gt "$GA_MODES_KEYS_MAX" ]; then
        ga_err invalid_keys "$(tf modes_err_keys "$GA_MODES_KEYS_MAX" "$keys")" 2
        return 2
    fi
    keys=$((10#$keys))
    ga_modes_domain_norm "$input" || rc=$?
    if [ "$rc" = 1 ]; then ga_err no_domain "$(t modes_err_no_domain)" 2; return 2; fi
    [ "$rc" = 0 ] || return 2
    domain="$GA_MODES_DOMAIN"

    # 1. Проверки — без вопросов. Чужое на TCP 80/443 и домен не сюда — отказ ДО любых изменений.
    _ga_modes_plan "$domain"
    GA_MODES_REASONS_JSON=$(_ga_modes_reasons_json)
    if [ "$_GM_PLAN" = blocked ]; then
        blk=$(_ga_modes_blocking)
        code="${blk%%$'\x1f'*}"; msg="${blk#*$'\x1f'}"
        ga_err "$code" "${msg:-$(t modes_err_blocked)}"
        return 1
    fi
    mode=pro
    [ "$_GM_PLAN" = semi_pro ] && mode=lite_site
    log_step "$(tf modes_setup_title "$GA_MODES_DISPLAY")"
    # Почему Semi-Pro — здесь, если этого ещё не сказали: SSH (install.sh: _lazy_run) объясняет итог проверки до
    # установки и ставит GA_MODES_EXPLAINED, чтобы та же строка не шла дважды.
    [ "$_GM_PLAN" = semi_pro ] && [ -z "${GA_MODES_EXPLAINED:-}" ] && log_warning "$(ga_modes_semi_words)"

    # 2. Контейнеры приложения — подхват без вопроса; 3. порты сайта в локальном файрволе.
    _ga_modes_adopt_all || return 1
    _ga_modes_open_ports

    # 4. Линии — по тому, что стоит ПОСЛЕ подхвата, и по версии, а не по месту профиля (LZ-02): подхваченный на 443
    # там и остаётся; иначе на 443 — недостающая 2.0, а если 2.0 уже стоит на своём порту (её порт с людьми не
    # трогаем) — недостающая 3.1; обе стоят — Semi-Pro.
    _ga_modes_slots_now
    _ga_modes_lines_need
    line443=""
    if [ "$mode" = pro ] && ! ga_modes_udp443_profile >/dev/null; then
        if [ "${#_GM_ADD[@]}" -gt 0 ]; then
            line443="${_GM_ADD[0]#*:}"
        else
            mode=lite_site
            _GM_REASONS+=(no_line_for_443)
            log_warning "$(t modes_why_no_line)"
        fi
    fi
    _GM_HAD_LE=0
    type ga_site_domain_ready >/dev/null 2>&1 && ga_site_domain_ready && _GM_HAD_LE=1
    _ga_modes_write_answers "$mode" "$domain" || return 1

    # 5. Профили: недостающие линии 2.0 и 3.1 (подхваченные не трогаем — их порты с людьми).
    _ga_modes_install_profiles "$line443" || return 1

    # 6. Сайт, сертификат, шаблон, панель на домене; ключи на IP за прокси Cloudflare (если адрес в ключах никто не
    # вписывал сам — вписанный владельцем не трогаем).
    _ga_modes_site "$mode" "$domain" || return 1
    mode=$(ga_site_mode 2>/dev/null)
    if [ "$_GM_CF" = true ] && [ -z "$(ga_config_get .endpoint_host 2>/dev/null)" ]; then
        ip=$(ga_site_server_ip 2>/dev/null)
        if [ -n "$ip" ] && type ga_set_endpoint_host >/dev/null 2>&1; then
            ga_set_endpoint_host "$ip" >/dev/null 2>&1 || true
        fi
    fi
    _ga_modes_panel

    # 7. Ключи и страницы подключения.
    GA_ERR_CODE=""; GA_ERR_MSG=""
    ga_step "$(tf modes_step_keys "$keys")" "$(t modes_step_keys_done)" "" _ga_modes_keys "$keys" || {
        [ "${#_GM_KEYS[@]}" -gt 0 ] || return 1; }
    ga_step "$(t modes_step_pages)" "$(t modes_step_pages_done)" "" _ga_modes_pages || true

    # 8. Установка состоялась: таймеры продукта (лимиты, сторож, статистика, бэкап…).
    ga_config_merge "$(jq -nc --arg d "$domain" '{installed: true, lazy: {domain: $d}}')" >/dev/null 2>&1 || true
    if type timers_install >/dev/null 2>&1; then timers_install >/dev/null 2>&1 || _ga_modes_warn timers_failed; fi
    ga_modes_panel_on_domain || _ga_modes_warn panel_off
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "lazy-setup" "domain=$domain mode=$mode keys=${#_GM_KEYS[@]}"

    # Ответ: адреса страниц — секрет (действие помечено secret), поэтому через окружение, не аргументом jq (SEC46-02).
    js='[]'
    for name in "${_GM_KEYS[@]}"; do
        label=$(ga_users_get "$name" 2>/dev/null | jq -r '.label // ""' 2>/dev/null)
        js=$(GA_S_URL="${_GM_PAGE[$name]:-}" jq -c --arg n "$name" --arg l "$label" \
            '. + [{name: $n, label: $l, page: (if $ENV.GA_S_URL == "" then null else $ENV.GA_S_URL end)}]' <<<"$js") || js="$js"
    done
    p443now=$(ga_modes_udp443_profile) || p443now=""
    line443now=""
    [ -n "$p443now" ] && line443now=$(ga_profile_line "$p443now" 2>/dev/null)
    # Предупреждения: обойдённые причины проверки, затем коды самого сценария — без повторов.
    warns=$( { printf '%s\n' "${_GM_REASONS[@]}"; printf '%s\n' "${GA_MODES_WARN[@]}"; } | awk 'NF && !seen[$0]++' \
        | jq -R . | jq -sc .) || warns='[]'
    [ -n "$warns" ] || warns='[]'
    # Сайт встал на запасном сертификате из-за отказа Let's Encrypt — причина словом и срок лимита рядом с
    # cert_fallback (cert_cause, cert_retry_after); иначе этих полей нет.
    GA_S_KEYS="$js" jq -nc --arg mode "$mode" --arg d "$domain" --arg p "$p443now" --arg l "$line443now" \
        --argjson profiles "$(ga_modes_profiles_json)" --arg tpl "$(ga_config_get .site.template_id 2>/dev/null)" \
        --argjson panel "$(ga_modes_panel_on_domain && echo true || echo false)" --argjson warnings "$warns" \
        --arg cc "${GA_CERT_CAUSE:-}" --arg cra "${GA_CERT_RETRY_AFTER:-}" '
        {mode: $mode, domain: $d,
         udp443: (if $p == "" then null else {profile: $p, line: $l} end),
         profiles: $profiles, site: {template: $tpl}, panel_on_domain: $panel,
         keys: ($ENV.GA_S_KEYS | fromjson), warnings: $warnings}
        + (if $cc != "" and ($warnings | index("cert_fallback")) != null
           then {cert_cause: $cc, cert_retry_after: $cra} else {} end)'
}

# ══════════════════════════════════════════════════════════════════════════════
#  Pro: какая линия стоит на UDP 443 (F-3)
# ══════════════════════════════════════════════════════════════════════════════
# pro_line_set <профиль> [согласие] → stdout JSON договора {mode: "pro", udp443: {profile, line},
# profiles: [{id, line, port}]}. Только в режиме pro (иначе mode_not_pro): выбранная линия встаёт на UDP 443 (не
# стоит — ставится сразу на 443), прежняя — на свободный случайный порт. Порт записан в каждом выданном ключе, поэтому
# профиль, подхваченный у приложения Amnezia с людьми без ключа на сервере, переносится только с согласием — именем
# этого профиля (ACC-2): отказ adopted_keyless, какой профиль — в GA_MODES_KEYLESS (мост отдаёт его полем profile).
# Проверка — ДО любого переноса, чтобы не оставить UDP 443 пустым на полпути. Что сделано — для слов ответа и SSH:
# GA_MODES_PL_CHANGED (0|1), GA_MODES_PL_PREV / GA_MODES_PL_PREV_PORT (прежний держатель 443 и куда он уехал).
GA_MODES_KEYLESS=""; GA_MODES_PL_CHANGED=0; GA_MODES_PL_PREV=""; GA_MODES_PL_PREV_PORT=""
pro_line_set() { ga_with_config_lock _pro_line_set_locked "$@"; }
_pro_line_set_locked() {
    local p="${1:-}" confirm="${2:-}" holder="" q n newport
    GA_MODES_KEYLESS=""; GA_MODES_PL_CHANGED=0; GA_MODES_PL_PREV=""; GA_MODES_PL_PREV_PORT=""
    ga_profile_check "$p" || return $?
    if [ "$(ga_config_get .mode 2>/dev/null)" != pro ]; then
        ga_err mode_not_pro "$(tf modes_err_mode_not_pro "$(_ga_modes_mode_word "$(ga_config_get .mode 2>/dev/null)")")" 2
        return 2
    fi
    holder=$(ga_modes_udp443_profile) || holder=""
    if [ "$holder" != "$p" ]; then
        # Куда уедет прежний держатель — узнаём ДО проверки согласия: отказ называет оба порта.
        newport=""
        if [ -n "$holder" ]; then
            GA_ERR_CODE=""; GA_ERR_MSG=""
            ga_capture newport ga_amn_pick_port "$holder" no443 || return 1
        else
            # UDP 443 держит не профиль, а чужой процесс — ничего не трогаем.
            ga_amn_port_check "$p" 443 || return $?
        fi
        for q in "$p" "$holder"; do
            [ -n "$q" ] && ga_profile_installed "$q" || continue
            n=$(ga_profile_keyless_count "$q") || { ga_err users_corrupt "$(t users_err_corrupt)"; return 1; }
            if [ "$n" -gt 0 ] && [ "$confirm" != "$q" ]; then
                GA_MODES_KEYLESS="$q"
                ga_err adopted_keyless "$(tf amnezia_err_port_adopted "$q" "$n" "$(ga_profile_field "$q" port)" \
                    "$(if [ "$q" = "$p" ]; then echo 443; else echo "$newport"; fi)" "$q")" 2
                return 2
            fi
        done
        if [ -n "$holder" ]; then
            amnezia_profile_set_port "$holder" "$newport" "$confirm" >/dev/null || return 1
            GA_MODES_PL_PREV="$holder"; GA_MODES_PL_PREV_PORT="$newport"
        fi
        if ga_profile_installed "$p"; then
            if ! amnezia_profile_set_port "$p" 443 "$confirm" >/dev/null; then
                # Прежний держатель уехал, а выбранный на 443 не встал — возвращаем прежнего, чтобы 443 не пустовал.
                [ -n "$holder" ] && amnezia_profile_set_port "$holder" 443 "$confirm" >/dev/null 2>&1
                return 1
            fi
        elif ! amnezia_profile_install "$p" 443 default >/dev/null; then
            [ -n "$holder" ] && amnezia_profile_set_port "$holder" 443 "$confirm" >/dev/null 2>&1
            return 1
        fi
        GA_MODES_PL_CHANGED=1
        ga_audit "${GOAMNEZIA_WHO:-ssh}" "pro-line" "$p${holder:+ previous=$holder:$newport}"
    fi
    jq -nc --arg p "$p" --arg l "$(ga_profile_line "$p")" --argjson profiles "$(ga_modes_profiles_json)" \
        '{mode: "pro", udp443: {profile: $p, line: $l}, profiles: $profiles}'
}
