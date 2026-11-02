#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# goAmnezia pro — lib/preflight.sh: предполётная проверка портов перед выбором
# режима (PLAN §4.3.1, CONTRACT §4.6a).
#
# Вопрос, на который отвечает модуль: можно ли на этом сервере включить режим
# с сайтом (lite_site, pro), а если нельзя — КТО именно мешает. Режимы с сайтом
# требуют TCP/80 (Let's Encrypt, редирект) и TCP/443 (nginx); UDP/443 хочет
# профиль по умолчанию, но без него обойдётся (случайный порт) — поэтому
# занятый UDP/443 только предупреждение, а не блок.
#
# Как определяем владельца порта (приёмы из goInstaller):
#   • слушатели — `ss -ltnp` / `ss -lunp`: адрес, порт, имя процесса, PID;
#   • юнит systemd — по `/proc/<pid>/cgroup` («…/nginx.service»), а НЕ по имени
#     процесса: у telemt, dnsdist и xray процесс может называться как угодно
#     (x-ui запускает xray-linux-amd64), а cgroup всегда указывает на юнит,
#     который надо остановить — именно его мы и подсказываем человеку;
#   • docker-proxy сам по себе ничего не говорит — имя контейнера берём из
#     `docker ps --format '{{.Names}} {{.Ports}}'` по опубликованному порту.
#     Тот же список нужен и для порта без слушателя: при userland-proxy=false
#     контейнер держит порт правилом DNAT, и в ss его не видно;
#   • продукт серии — по юниту/процессу/контейнеру и по vhost'ам nginx
#     (NEIGHBOURS.md): одна и та же nginx.service может быть нашей, goTelegram
#     или goVLESS — различаем по sites-enabled;
#   • «своё» (ours=true) — наш nginx (vhost goamnezia включён), контейнеры из
#     нашего config.json и юниты goamnezia-*: это переустановка/обновление,
#     а не конфликт, режим не блокируется;
#   • локальный файрвол — `ufw status verbose`, `iptables -S INPUT`,
#     `nft list ruleset`. Закрытый порт (closed_local) мы умеем открыть сами
#     (preflight_open_local), поэтому это отдельное состояние, а не busy.
#
# Асимметрия ошибок — сознательная: ложное «закрыто» блокирует выбор режима
# целиком, ложное «открыто» человек заметит по site-check после установки.
# Поэтому при сомнениях (сложные цепочки, нет прав, нет инструмента) файрвол
# получает состояние unknown и предупреждение, а не блок.
#
# Правила модуля (контракт §0):
#   • stdout — только результат (JSON) у preflight_port_owner, preflight_modes,
#     preflight_guess_product; экран preflight_render_modes — целиком в stderr;
#   • ни одного exit, ни одной видимой строки вне t/tf (словарь
#     lib/lang/<lang>.d/preflight.sh);
#   • все внешние команды — с таймаутом и 2>/dev/null; отсутствие ss/docker/
#     ufw/iptables/nft не роняет проверку: состояние unknown с пометкой в notes;
#   • GOAMNEZIA_DRY_RUN=1: мутации (ufw allow, iptables -I) печатаются как
#     «DRY: …»; чтения без фикстур считаются пустыми (нет слушателей, нет
#     файрвола) — так сквозные прогоны других модулей детерминированы на любой
#     машине. Фикстуры GOAMNEZIA_*_FIXTURE имеют приоритет и в dry-run, и на
#     живом сервере (tests/test_preflight_dryrun.sh).
#
# Подключение в install.sh и сниппеты для мастера, «Режим и сайт», change-mode,
# preflight, quality, status — docs/PREFLIGHT.md.
# ══════════════════════════════════════════════════════════════════════════════

# ── Запасные помощники: модуль подключают и без lib/docker.sh / lib/website.sh ─
type ga_dry >/dev/null 2>&1 || ga_dry() { [ "${GOAMNEZIA_DRY_RUN:-0}" = "1" ]; }
type ga_dry_echo >/dev/null 2>&1 || ga_dry_echo() { printf 'DRY: %s\n' "$*" >&2; }
if ! type ga_err >/dev/null 2>&1; then
    # ga_err <код> <сообщение> [rc] — те же поля, что читает _action_run в install.sh
    ga_err() {
        GA_ERR_CODE="$1"
        GA_ERR_MSG="$2"
        if declare -F ga_set_error >/dev/null 2>&1; then
            ga_set_error "$1"
        fi
        log_error "$2"
        return "${3:-1}"
    }
fi

# ── Пути и инструменты: функциями, а не константами при source ────────────────
# Тесты и стенды выставляют GOAMNEZIA_* уже после подключения модуля; константа,
# вычисленная при source, этого не увидела бы и полезла в боевой /proc и /etc.
ga_pf_proc_root()   { printf '%s' "${GOAMNEZIA_PROC_ROOT:-/proc}"; }
ga_pf_nginx_dir()   { printf '%s' "${GOAMNEZIA_NGINX_DIR:-/etc/nginx}"; }
ga_pf_systemd_dir() { printf '%s' "${GOAMNEZIA_SYSTEMD_DIR:-/etc/systemd/system}"; }
# Таймаут на одну внешнюю команду. docker ps при полумёртвом демоне и ufw при
# заклинившем iptables висят минутами — мастер не должен висеть вместе с ними.
ga_pf_timeout()     { printf '%s' "${GOAMNEZIA_PREFLIGHT_TIMEOUT:-5}"; }
# ga_pf_bin <ИМЯ_ПЕРЕМЕННОЙ> <умолчание> — путь к инструменту; тесты подменяют
# его несуществующим, чтобы проверить ветку «инструмента нет».
ga_pf_bin() { local v="${1:-}"; printf '%s' "${!v:-$2}"; }

# ── Порты, которые нужны режимам с сайтом ─────────────────────────────────────
# TCP/80 и TCP/443 — обязательны для lite_site и pro (CONTRACT §4.6a);
# UDP/443 — желателен для профиля по умолчанию (PLAN §4.4), но не блокирует.
GA_PF_SITE_PORTS="tcp:443 tcp:80"
GA_PF_SOFT_PORTS="udp:443"

# ══════════════════════════════════════════════════════════════════════════════
#  Источники данных
# ══════════════════════════════════════════════════════════════════════════════
# ga_pf_source <ФИКСТУРА_VAR> <BIN_VAR> <бинарь> <аргументы…> → stdout сырой вывод
#   rc 0 — данные есть; rc 3 — dry-run без фикстуры (считать пустым);
#   rc 1 — инструмента нет; rc 2 — инструмент есть, но не ответил (нет прав,
#   таймаут, демон лежит). Различие 1/2 важно ниже: «нет ufw» — нормально
#   (файрвола нет), «ufw есть, но не отвечает» — состояние unknown.
ga_pf_source() {
    local fx_var="$1" bin_var="$2" bin_default="$3"
    shift 3
    local fx="${!fx_var:-}" bin
    bin=$(ga_pf_bin "$bin_var" "$bin_default")
    if [ -n "$fx" ]; then
        [ -r "$fx" ] || return 2
        cat "$fx" 2>/dev/null || return 2
        return 0
    fi
    if ga_dry; then
        ga_dry_echo "$bin $*"
        return 3
    fi
    command -v "$bin" >/dev/null 2>&1 || return 1
    if command -v timeout >/dev/null 2>&1; then
        timeout "$(ga_pf_timeout)" "$bin" "$@" 2>/dev/null || return 2
    else
        "$bin" "$@" 2>/dev/null || return 2
    fi
    return 0
}

# ga_pf_run <команда…> — мутация (ufw allow, iptables -I): в dry-run печатается
# и считается выполненной; иначе выполняется с таймаутом и без stdout.
ga_pf_run() {
    if ga_dry; then ga_dry_echo "$*"; return 0; fi
    if command -v timeout >/dev/null 2>&1; then
        timeout "$(ga_pf_timeout)" "$@" >/dev/null 2>&1
    else
        "$@" >/dev/null 2>&1
    fi
}

# ga_pf_listeners <tcp|udp> → строки «addr|port|process|pid»; rc как у ga_pf_source.
# Фикстуры: GOAMNEZIA_SS_FIXTURE_TCP / _UDP (сохранённый `ss -ltnp` / `ss -lunp`,
# с заголовком или без) либо общая GOAMNEZIA_SS_FIXTURE (`ss -H -lntup`, первая
# колонка Netid — как в goInstaller). Разбор не привязан к номеру колонки:
# локальный адрес — поле перед peer-адресом «…:*», поэтому одинаково читается
# вывод с колонкой Netid и без неё, с заголовком и без.
ga_pf_listeners() {
    local proto="$1" raw="" rc=0 fx_var flag
    case "$proto" in
        tcp) fx_var=GOAMNEZIA_SS_FIXTURE_TCP; flag="-ltnp" ;;
        udp) fx_var=GOAMNEZIA_SS_FIXTURE_UDP; flag="-lunp" ;;
        *)   return 2 ;;
    esac
    if [ -z "${!fx_var:-}" ] && [ -n "${GOAMNEZIA_SS_FIXTURE:-}" ]; then
        raw=$(ga_pf_source GOAMNEZIA_SS_FIXTURE GOAMNEZIA_SS_BIN ss -H -lntup) || rc=$?
        [ "$rc" = 0 ] && raw=$(printf '%s\n' "$raw" | awk -v p="$proto" '$1 == p')
    else
        raw=$(ga_pf_source "$fx_var" GOAMNEZIA_SS_BIN ss -H "$flag") || rc=$?
    fi
    [ "$rc" = 0 ] || return "$rc"
    printf '%s\n' "$raw" | awk '
        {
            peer = 0
            for (i = 1; i <= NF; i++) if ($i ~ /:\*$/) { peer = i; break }
            if (peer < 2) next
            loc = $(peer - 1)
            n = split(loc, a, ":"); port = a[n]
            if (port !~ /^[0-9]+$/) next
            addr = substr(loc, 1, length(loc) - length(port) - 1)
            gsub(/^\[|\]$/, "", addr); sub(/%.*$/, "", addr)
            proc = ""; pid = ""
            k = index($0, "users:(")
            if (k > 0) {
                u = substr($0, k)
                if (match(u, /\("[^"]*",pid=[0-9]+/)) {
                    s = substr(u, RSTART + 2, RLENGTH - 2)
                    q = index(s, "\",pid=")
                    proc = substr(s, 1, q - 1); pid = substr(s, q + 6)
                }
            }
            print addr "|" port "|" proc "|" pid
        }'
    return 0
}

# ga_pf_docker_ps → строки «имя порты…» работающих контейнеров; rc как у ga_pf_source.
# Версию API демона закрепляем заранее: без неё на сервере с автообновлениями
# (клиент новее живого демона) `docker ps` падает, и предполётная проверка
# считала бы занятые контейнерами порты свободными.
ga_pf_docker_ps() {
    type docker_api_pin >/dev/null 2>&1 && docker_api_pin
    ga_pf_source GOAMNEZIA_DOCKER_PS_FIXTURE GOAMNEZIA_DOCKER_BIN docker ps --format '{{.Names}} {{.Ports}}'
}

# ga_pf_pid_unit <pid> → юнит systemd («nginx.service») по /proc/<pid>/cgroup.
# Берём только *.service: scope пользовательской сессии (session-3.scope) или
# контейнера (docker-<id>.scope) как подсказка «systemctl disable --now …»
# бессмысленны. Работает и с cgroup v1 (несколько строк), и с v2 («0::/…»).
ga_pf_pid_unit() {
    local pid="${1:-}" f
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    f="$(ga_pf_proc_root)/$pid/cgroup"
    [ -r "$f" ] || return 0
    sed -n -E 's#^.*/([^/]+\.service)$#\1#p' "$f" 2>/dev/null | head -n 1
    return 0
}

# ga_pf_container_by_port <proto> <port> <docker ps вывод> → имя контейнера,
# опубликовавшего порт («0.0.0.0:443->443/udp, :::443->443/udp»). Строка без
# «->» — порт лишь объявлен (EXPOSE), хост он не занимает.
ga_pf_container_by_port() {
    local proto="$1" port="$2" raw="${3:-}"
    [ -n "$raw" ] || return 0
    printf '%s\n' "$raw" | awk -v re=":${port}->[0-9]+/${proto}" '$0 ~ re { print $1; exit }'
    return 0
}

# ── Кто есть кто ──────────────────────────────────────────────────────────────
# Контейнеры из нашего config.json (profiles.*.container). Без config.json —
# пусто: контейнер amnezia-*, которого нет в конфиге, для нас чужой (его
# сначала берут через import-adopt, CONTRACT §4.7).
ga_pf_our_containers() {
    local cfg="${CONFIG_FILE:-${GOAMNEZIA_DIR:-/opt/goamnezia}/config.json}"
    [ -f "$cfg" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    jq -r '.profiles // {} | .[]? | .container // empty' "$cfg" 2>/dev/null
    return 0
}
ga_pf_container_is_ours() {
    local name="${1:-}" c
    [ -n "$name" ] || return 1
    while IFS= read -r c; do
        [ "$c" = "$name" ] && return 0
    done < <(ga_pf_our_containers)
    return 1
}

# Наш vhost включён — это наш nginx (или общий с соседом, но нам он не мешает).
ga_pf_nginx_is_ours() {
    [ -e "$(ga_pf_nginx_dir)/sites-enabled/goamnezia" ] && return 0
    # Без переменной стенда — путь из lib/common.sh (его же читает lib/backup.sh)
    [ -z "${GOAMNEZIA_NGINX_DIR:-}" ] && [ -e "${NGINX_SITE_LINK:-/etc/nginx/sites-enabled/goamnezia}" ] && return 0
    return 1
}

# nginx общий на весь сервер: чей он — смотрим, чей сайт включён (как goInstaller).
ga_pf_nginx_owner() {
    local root
    root=$(ga_pf_nginx_dir)
    if ga_pf_nginx_is_ours; then
        printf 'goamnezia'
    elif [ -e "$root/sites-enabled/gotelegram" ] || [ -e "$root/stream-conf.d/gotelegram-shared443.conf" ]; then
        printf 'gotelegram'
    elif [ -e "$root/sites-enabled/govless" ]; then
        printf 'govless'
    else
        printf 'unknown'
    fi
}

# Следы goVLESS на диске: x-ui и xray сами по себе — это 3x-ui; с vhost govless
# или юнитами govless* — goVLESS Pro.
ga_pf_govless_present() {
    [ -e "$(ga_pf_nginx_dir)/sites-enabled/govless" ] && return 0
    local f
    for f in "$(ga_pf_systemd_dir)"/govless*.service; do
        [ -e "$f" ] && return 0
    done
    return 1
}

# preflight_guess_product <process> <unit> <container>
#   stdout: gotelegram|govless|godns|gowarp|gokaskad|xui|amnezia|goamnezia|unknown
# Порядок источников: контейнер (самый точный — имя даёт сам продукт), затем юнит
# (cgroup не врёт, даже если бинарь переименован), затем имя процесса.
preflight_guess_product() {
    local proc="${1:-}" unit="${2:-}" container="${3:-}"
    if [ -n "$container" ]; then
        if ga_pf_container_is_ours "$container"; then
            printf 'goamnezia\n'
        else
            case "$container" in
                # Любой контейнер с подстрокой amnezia в имени разбирает приложение
                # Amnezia (NEIGHBOURS.md, правила именования) — значит, это оно
                amnezia*|*amnezia*) printf 'amnezia\n' ;;
                *3x-ui*|*x-ui*|*xui*) printf 'xui\n' ;;
                *) printf 'unknown\n' ;;
            esac
        fi
        return 0
    fi
    case "$unit" in
        goamnezia-*)                         printf 'goamnezia\n'; return 0 ;;
        telemt.service|gotelegram*)          printf 'gotelegram\n'; return 0 ;;
        govless*|cloudflared*|webapp-frontend*|tunnel-health*)
                                             printf 'govless\n'; return 0 ;;
        x-ui.service|3x-ui*)                 if ga_pf_govless_present; then printf 'govless\n'; else printf 'xui\n'; fi; return 0 ;;
        xray.service)                        if ga_pf_govless_present; then printf 'govless\n'; else printf 'unknown\n'; fi; return 0 ;;
        dnsdist.service|godns*)              printf 'godns\n'; return 0 ;;
        kaskad*|gokaskad*|wg-quick@kawg*)    printf 'gokaskad\n'; return 0 ;;
        warp-svc.service|warp-bot.service|warp-taskd*|gowarp*)
                                             printf 'gowarp\n'; return 0 ;;
        nginx.service)                       printf '%s\n' "$(ga_pf_nginx_owner)"; return 0 ;;
    esac
    case "$proc" in
        telemt)                              printf 'gotelegram\n' ;;
        dnsdist)                             printf 'godns\n' ;;
        warp-svc|warp-cli)                   printf 'gowarp\n' ;;
        nginx)                               printf '%s\n' "$(ga_pf_nginx_owner)" ;;
        x-ui)                                if ga_pf_govless_present; then printf 'govless\n'; else printf 'xui\n'; fi ;;
        xray|xray-linux*|xray-core)          if ga_pf_govless_present; then printf 'govless\n'; else printf 'unknown\n'; fi ;;
        kaskad*)                             printf 'gokaskad\n' ;;
        wg-quick|wireguard-go|awg|awg-quick|amneziawg-go)
                                             printf 'gokaskad\n' ;;
        *)                                   printf 'unknown\n' ;;
    esac
    return 0
}

# ga_pf_is_ours <process> <unit> <container> → 0, если порт держит наше же:
# юнит goamnezia-*, контейнер из config.json или nginx с нашим vhost.
ga_pf_is_ours() {
    local proc="${1:-}" unit="${2:-}" container="${3:-}"
    case "$unit" in goamnezia-*) return 0 ;; esac
    [ -n "$container" ] && ga_pf_container_is_ours "$container" && return 0
    if [ "$proc" = "nginx" ] || [ "$unit" = "nginx.service" ]; then
        ga_pf_nginx_is_ours && return 0
    fi
    return 1
}

# ══════════════════════════════════════════════════════════════════════════════
#  Локальный файрвол
# ══════════════════════════════════════════════════════════════════════════════
# ga_pf_ufw_decide <proto> <port> <вывод ufw status [verbose]> → inactive|open|closed
# Правила ufw читаются сверху вниз, первое совпавшее решает; без совпадений —
# политика по умолчанию (строка «Default:» есть только в verbose; без неё
# считаем deny — это и есть умолчание ufw). Правила с конкретным источником
# («ALLOW 203.0.113.5») не считаем открытием для всего интернета — сайту нужен
# доступ откуда угодно. Профили приложений (Nginx Full, WWW…) раскрываем в порты:
# `ufw allow 'Nginx Full'` — самый частый способ открыть веб.
ga_pf_ufw_decide() {
    local proto="$1" port="$2" raw="${3:-}"
    printf '%s\n' "$raw" | awk -v proto="$proto" -v port="$port" '
        function spec_matches(to,   spec, prt, list, n, i, r, rr, parts, np) {
            if (to == "Nginx Full" || to == "WWW Full" || to == "Apache Full")
                return (proto == "tcp" && (port == 80 || port == 443))
            if (to == "Nginx HTTP" || to == "WWW" || to == "Apache")
                return (proto == "tcp" && port == 80)
            if (to == "Nginx HTTPS" || to == "WWW Secure" || to == "Apache Secure")
                return (proto == "tcp" && port == 443)
            if (to == "Anywhere") return 1
            if (index(to, " ") > 0) { np = split(to, parts, " "); to = parts[np] }
            spec = to; prt = ""
            if (index(spec, "/") > 0) {
                prt = substr(spec, index(spec, "/") + 1)
                spec = substr(spec, 1, index(spec, "/") - 1)
            }
            if (prt != "" && prt != proto) return 0
            n = split(spec, list, ",")
            for (i = 1; i <= n; i++) {
                r = list[i]
                if (r ~ /^[0-9]+:[0-9]+$/) {
                    split(r, rr, ":")
                    if (port + 0 >= rr[1] + 0 && port + 0 <= rr[2] + 0) return 1
                } else if (r ~ /^[0-9]+$/ && r + 0 == port + 0) return 1
            }
            return 0
        }
        BEGIN { active = 0; def = "deny"; decision = "" }
        /^Status: active/   { active = 1; next }
        /^Status: inactive/ { active = 0; next }
        /^Default:/ {
            if ($0 ~ /allow \(incoming\)/) def = "allow"
            else def = "deny"
            next
        }
        {
            if (decision != "") next
            act = 0
            for (i = 2; i <= NF; i++) if ($i ~ /^(ALLOW|DENY|REJECT|LIMIT)$/) { act = i; break }
            if (act < 2) next
            dir = "IN"; fs = act + 1
            if ($(act + 1) == "IN" || $(act + 1) == "OUT" || $(act + 1) == "FWD") { dir = $(act + 1); fs = act + 2 }
            if (dir != "IN") next
            to = $1; for (i = 2; i < act; i++) to = to " " $i
            sub(/ \(v6\)$/, "", to); sub(/ on [^ ]+$/, "", to)
            from = ""; for (i = fs; i <= NF; i++) from = from (from == "" ? "" : " ") $i
            sub(/ \(v6\)$/, "", from); sub(/ on [^ ]+$/, "", from)
            if (from != "" && from != "Anywhere") next
            if (!spec_matches(to)) next
            if ($act == "ALLOW" || $act == "LIMIT") decision = "open"; else decision = "closed"
        }
        END {
            if (!active) print "inactive"
            else if (decision != "") print decision
            else print (def == "allow" ? "open" : "closed")
        }'
}

# ga_pf_iptables_decide <proto> <port> <вывод iptables -S INPUT> → open|closed|unknown
# Первое совпавшее правило решает. Правила с источником (-s), на lo и только для
# ESTABLISHED не влияют на новые соединения снаружи — пропускаем. Переходы в
# чужие цепочки (INPUT_ZONES firewalld, ufw-* без ответа ufw) читать не берёмся:
# после них общий DROP/REJECT или политика DROP дают unknown, а не closed —
# ложный блок хуже пропущенного предупреждения. Цепочки fail2ban безвредны.
ga_pf_iptables_decide() {
    local proto="$1" port="$2" raw="${3:-}"
    printf '%s\n' "$raw" | awk -v proto="$proto" -v port="$port" '
        function port_in(spec,   list, n, i, r, rr) {
            n = split(spec, list, ",")
            for (i = 1; i <= n; i++) {
                r = list[i]
                if (r ~ /^[0-9]+:[0-9]+$/) {
                    split(r, rr, ":")
                    if (port + 0 >= rr[1] + 0 && port + 0 <= rr[2] + 0) return 1
                } else if (r ~ /^[0-9]+$/ && r + 0 == port + 0) return 1
            }
            return 0
        }
        BEGIN { policy = "ACCEPT"; decision = ""; jumps = 0 }
        $1 == "-P" && $2 == "INPUT" { policy = $3; next }
        $1 != "-A" || $2 != "INPUT" { next }
        {
            if (decision != "") next
            p = ""; dports = ""; target = ""; src = ""; iface = ""; neg = 0; ctnew = 1; skip = 0
            for (i = 3; i <= NF; i++) {
                if ($i == "!") { neg = 1; continue }
                if ($i == "-p") { p = $(i + 1); i++ }
                else if ($i == "--dport" || $i == "--dports") { if (neg) skip = 1; dports = $(i + 1); i++ }
                else if ($i == "-j" || $i == "-g") { target = $(i + 1); i++ }
                else if ($i == "-s") { if (!neg) src = $(i + 1); i++ }
                else if ($i == "-i") { if (!neg) iface = $(i + 1); i++ }
                else if ($i == "--ctstate" || $i == "--state") { if ($(i + 1) !~ /NEW/) ctnew = 0; i++ }
                neg = 0
            }
            if (skip || !ctnew) next
            if (src != "" && src != "0.0.0.0/0" && src != "::/0") next
            if (iface == "lo") next
            if (p != "" && p != "all" && p != proto) next
            if (dports != "" && !port_in(dports)) next
            if (target == "ACCEPT") { decision = "open"; next }
            if (target == "DROP" || target == "REJECT") {
                if (dports == "" && jumps) decision = "unknown"; else decision = "closed"
                next
            }
            if (target == "" || target == "RETURN" || target == "LOG") next
            if (target ~ /^(f2b-|fail2ban-|LIBVIRT_INP|DOCKER)/) next
            jumps = 1
        }
        END {
            if (decision != "") print decision
            else if (policy == "ACCEPT") print "open"
            else print (jumps ? "unknown" : "closed")
        }'
}

# ga_pf_nft_decide <proto> <port> <вывод nft list ruleset> <skip_ipt 0|1> → open|closed|unknown|none
# Базовые цепочки с hook input во всех таблицах; skip_ipt=1 пропускает таблицы
# `ip filter` / `ip6 filter` — это отражение iptables-nft, уже разобранное
# ga_pf_iptables_decide (иначе одно правило считалось бы дважды). Понимаем
# `tcp dport 443`, множества `{ 80, 443 }`, диапазоны `80-443`, именованные
# множества `@web` (по elements таблицы) и `dport vmap { … }`. Закрыто хотя бы в
# одной таблице — закрыто (пакет проходит все базовые цепочки).
ga_pf_nft_decide() {
    local proto="$1" port="$2" raw="${3:-}" skip_ipt="${4:-0}"
    printf '%s\n' "$raw" | awk -v proto="$proto" -v port="$port" -v skip_ipt="$skip_ipt" '
        function port_in(spec,   list, n, i, r, rr) {
            gsub(/[{},]/, " ", spec)
            n = split(spec, list, " ")
            for (i = 1; i <= n; i++) {
                r = list[i]
                if (r ~ /^[0-9]+-[0-9]+$/) {
                    split(r, rr, "-")
                    if (port + 0 >= rr[1] + 0 && port + 0 <= rr[2] + 0) return 1
                } else if (r ~ /^[0-9]+$/ && r + 0 == port + 0) return 1
            }
            return 0
        }
        function chain_end() {
            if (in_chain && is_input && !skip_tbl && cdecision == "") {
                if (cpolicy == "drop" || cpolicy == "reject") cdecision = (jumps ? "unknown" : "closed")
            }
            if (in_chain && is_input && !skip_tbl) {
                if (cdecision == "closed") closed_any = 1
                else if (cdecision == "unknown") unknown_any = 1
                else open_any = 1
            }
            in_chain = 0; is_input = 0
        }
        BEGIN { closed_any = 0; open_any = 0; unknown_any = 0; in_chain = 0; is_input = 0; skip_tbl = 0; in_set = ""; collecting = 0 }
        /^table / {
            family = $2; tname = $3
            skip_tbl = (skip_ipt == 1 && (family == "ip" || family == "ip6") && tname == "filter")
            next
        }
        /^[ \t]*set [^ ]+ \{/ { in_set = family " " tname " " $2; sets[in_set] = ""; next }
        in_set != "" {
            if ($0 ~ /^[ \t]*\}[ \t]*$/ && !collecting) { in_set = ""; next }
            if ($0 ~ /elements =/) { collecting = 1; sub(/.*elements = \{/, "", $0) }
            if (collecting) {
                line = $0
                if (index(line, "}") > 0) { line = substr(line, 1, index(line, "}") - 1); collecting = 0 }
                gsub(/,/, " ", line)
                sets[in_set] = sets[in_set] " " line
            }
            next
        }
        /^[ \t]*chain / { chain_end(); in_chain = 1; is_input = 0; cpolicy = "accept"; cdecision = ""; jumps = 0; next }
        /^[ \t]*\}[ \t]*$/ { if (in_chain) chain_end(); next }
        in_chain && /type filter hook input/ {
            is_input = 1
            if ($0 ~ /policy drop/) cpolicy = "drop"
            else if ($0 ~ /policy reject/) cpolicy = "reject"
            next
        }
        in_chain && is_input && !skip_tbl && cdecision == "" {
            line = $0
            sub(/comment ".*"$/, "", line)
            if (line ~ /(^|[ \t])(ip|ip6) saddr /) next
            if (line ~ /iif(name)? "?lo"?/) next
            if (line ~ /ct state / && line !~ /new/ && line !~ /dport/) next
            p = ""; dspec = ""; verdict = ""; vmap = 0
            if (match(line, /meta l4proto \{[^}]*\}/)) {
                p = substr(line, RSTART + 13, RLENGTH - 13)
                if (p !~ proto) next
                p = proto
            } else if (match(line, /meta l4proto [a-z]+/)) { p = substr(line, RSTART + 13, RLENGTH - 13) }
            else if (match(line, /ip protocol [a-z]+/)) { p = substr(line, RSTART + 12, RLENGTH - 12) }
            if (match(line, /(tcp|udp|th) dport /)) {
                d = substr(line, RSTART, 3)
                if (d != "th") p = d
                rest = substr(line, RSTART + RLENGTH)
                if (rest ~ /^vmap \{/) {
                    vmap = 1
                    sub(/^vmap \{/, "", rest); sub(/\}.*$/, "", rest)
                    n = split(rest, pairs, ",")
                    verdict = ""
                    for (i = 1; i <= n; i++) {
                        split(pairs[i], kv, ":")
                        gsub(/^[ \t]+|[ \t]+$/, "", kv[1]); gsub(/^[ \t]+|[ \t]+$/, "", kv[2])
                        if (port_in(kv[1])) { verdict = kv[2]; break }
                    }
                    if (verdict == "") next
                    dspec = port
                } else if (rest ~ /^@/) {
                    sname = rest; sub(/[ \t].*$/, "", sname); sub(/^@/, "", sname)
                    key = family " " tname " " sname
                    if (!(key in sets)) { jumps = 1; next }
                    dspec = sets[key]
                } else if (rest ~ /^\{/) {
                    dspec = substr(rest, 1, index(rest, "}"))
                } else {
                    dspec = rest; sub(/[ \t].*$/, "", dspec)
                }
            }
            if (p != "" && p != proto) next
            if (dspec != "" && !port_in(dspec)) next
            if (!vmap) {
                n = split(line, tok, /[ \t]+/)
                for (i = 1; i <= n; i++) if (tok[i] ~ /^(accept|drop|reject|jump|goto|return|continue)$/) { verdict = tok[i]; break }
            }
            if (verdict == "accept") { cdecision = "open"; next }
            if (verdict == "drop" || verdict == "reject") {
                if (dspec == "" && jumps) cdecision = "unknown"; else cdecision = "closed"
                next
            }
            if (verdict == "jump" || verdict == "goto") { jumps = 1; next }
        }
        END {
            chain_end()
            if (closed_any) print "closed"
            else if (unknown_any) print "unknown"
            else if (open_any) print "open"
            else print "none"
        }'
}

# ══════════════════════════════════════════════════════════════════════════════
#  Один сбор данных на прогон
# ══════════════════════════════════════════════════════════════════════════════
# preflight_modes спрашивает три порта; чтобы не гонять ss/docker/ufw/iptables/nft
# по три раза, сырые выводы собираются один раз в глобальные переменные, а
# ga_pf_owner работает только с ними. Кэша между вызовами нет намеренно:
# человек нажал «r — повторить проверку» — значит, хочет свежие данные.
_GA_PF_TCP=""; _GA_PF_TCP_RC=3
_GA_PF_UDP=""; _GA_PF_UDP_RC=3
_GA_PF_DOCKER=""; _GA_PF_DOCKER_RC=3
_GA_PF_UFW=""; _GA_PF_UFW_RC=3
_GA_PF_IPT=""; _GA_PF_IPT_RC=3
_GA_PF_NFT=""; _GA_PF_NFT_RC=3

ga_pf_collect() {
    local a want_tcp=0 want_udp=0
    for a in "$@"; do
        case "$a" in tcp) want_tcp=1 ;; udp) want_udp=1 ;; esac
    done
    _GA_PF_TCP=""; _GA_PF_TCP_RC=3; _GA_PF_UDP=""; _GA_PF_UDP_RC=3
    if [ "$want_tcp" = 1 ]; then
        _GA_PF_TCP=$(ga_pf_listeners tcp); _GA_PF_TCP_RC=$?
    fi
    if [ "$want_udp" = 1 ]; then
        _GA_PF_UDP=$(ga_pf_listeners udp); _GA_PF_UDP_RC=$?
    fi
    _GA_PF_DOCKER=$(ga_pf_docker_ps); _GA_PF_DOCKER_RC=$?
    _GA_PF_UFW=$(ga_pf_source GOAMNEZIA_UFW_FIXTURE GOAMNEZIA_UFW_BIN ufw status verbose); _GA_PF_UFW_RC=$?
    _GA_PF_IPT=$(ga_pf_source GOAMNEZIA_IPTABLES_FIXTURE GOAMNEZIA_IPTABLES_BIN iptables -S INPUT); _GA_PF_IPT_RC=$?
    _GA_PF_NFT=$(ga_pf_source GOAMNEZIA_NFT_FIXTURE GOAMNEZIA_NFT_BIN nft list ruleset); _GA_PF_NFT_RC=$?
    return 0
}

# ga_pf_firewall_state <proto> <port> → «<open|closed|unknown> <ufw|iptables|nft|none>»
# Порядок: ufw активен — решает он (его же правила лежат в iptables цепочками
# ufw-*, которые мы не читаем). Иначе iptables -S INPUT, затем nft для таблиц
# помимо отражения iptables. Инструментов нет вовсе — файрвола нет (open none);
# инструмент есть, но не ответил (нет root) — unknown.
ga_pf_firewall_state() {
    local proto="$1" port="$2" d ipt="" nft="" src="none" state="open" skip_ipt=0
    if [ "$_GA_PF_UFW_RC" = 0 ]; then
        d=$(ga_pf_ufw_decide "$proto" "$port" "$_GA_PF_UFW")
        if [ "$d" != "inactive" ]; then
            printf '%s ufw\n' "$d"
            return 0
        fi
    elif [ "$_GA_PF_UFW_RC" = 2 ]; then
        state="unknown"; src="ufw"
    fi
    if [ "$_GA_PF_IPT_RC" = 0 ]; then
        ipt=$(ga_pf_iptables_decide "$proto" "$port" "$_GA_PF_IPT")
        skip_ipt=1
    elif [ "$_GA_PF_IPT_RC" = 2 ]; then
        state="unknown"; src="iptables"
    fi
    if [ "$_GA_PF_NFT_RC" = 0 ]; then
        nft=$(ga_pf_nft_decide "$proto" "$port" "$_GA_PF_NFT" "$skip_ipt")
        [ "$nft" = "none" ] && nft=""
    elif [ "$_GA_PF_NFT_RC" = 2 ] && [ -z "$ipt" ]; then
        state="unknown"; src="nft"
    fi
    if [ "$ipt" = "closed" ] || [ "$nft" = "closed" ]; then
        state="closed"
    elif [ "$ipt" = "unknown" ] || [ "$nft" = "unknown" ]; then
        state="unknown"
    elif [ -n "$ipt" ] || [ -n "$nft" ]; then
        state="open"
    fi
    if [ "$ipt" = "$state" ] && [ "$nft" = "$state" ]; then src="iptables+nft"
    elif [ "$ipt" = "$state" ]; then src="iptables"
    elif [ "$nft" = "$state" ]; then src="nft"
    fi
    printf '%s %s\n' "$state" "$src"
    return 0
}

# ga_pf_owner <tcp|udp> <port> → stdout JSON владельца порта (по собранным данным).
# Поля контракта: state, pid, process, unit, container, product, ours; сверх
# контракта — proto, port, addr (кому виден порт), firewall/firewall_source и
# notes (коды пометок: no_ss, no_docker, no_pid, dry_run…) — их читают экран и
# предупреждения preflight_modes.
ga_pf_owner() {
    local proto="$1" port="$2"
    local listeners="" lrc=3 line="" addr="" p="" proc="" pid="" unit="" container="" product="unknown"
    local ours=false state="free" fw="open" fws="none" notes="" pid_json=null notes_json='[]'
    case "$proto" in
        tcp) listeners="$_GA_PF_TCP"; lrc="$_GA_PF_TCP_RC" ;;
        udp) listeners="$_GA_PF_UDP"; lrc="$_GA_PF_UDP_RC" ;;
    esac
    case "$lrc" in
        0)
            # Первый слушатель нужного порта с PID; без PID (не root) — любой
            while IFS='|' read -r addr p proc pid; do
                [ "$p" = "$port" ] || continue
                [ -n "$line" ] && [ -z "$pid" ] && continue
                line="$addr|$p|$proc|$pid"
                [ -n "$pid" ] && break
            done <<<"$listeners"
            ;;
        3) notes="dry_run" ;;
        1) notes="no_ss" ;;
        *) notes="ss_failed" ;;
    esac
    if [ -n "$line" ]; then
        IFS='|' read -r addr p proc pid <<<"$line"
        state="busy"
        if [ -z "$pid" ]; then
            notes="${notes:+$notes }no_pid"
        else
            unit=$(ga_pf_pid_unit "$pid")
        fi
        # docker-proxy — лишь посредник: кто за ним, скажет docker ps по порту
        if [ "$proc" = "docker-proxy" ] || [ "$unit" = "docker.service" ] || [ -z "$proc" ]; then
            case "$_GA_PF_DOCKER_RC" in
                0) container=$(ga_pf_container_by_port "$proto" "$port" "$_GA_PF_DOCKER") ;;
                1|2) [ "$proc" = "docker-proxy" ] && notes="${notes:+$notes }no_docker" ;;
            esac
        fi
    else
        addr=""
        # Слушателя нет, но порт может держать DNAT контейнера (userland-proxy=false)
        if [ "$_GA_PF_DOCKER_RC" = 0 ]; then
            container=$(ga_pf_container_by_port "$proto" "$port" "$_GA_PF_DOCKER")
            if [ -n "$container" ]; then
                state="busy"; proc="docker"; notes="${notes:+$notes }dnat_only"
            fi
        fi
        if [ "$state" = "free" ] && [ "$lrc" != 0 ] && [ "$lrc" != 3 ]; then
            state="unknown"
        fi
    fi
    if [ "$state" = "busy" ]; then
        product=$(preflight_guess_product "$proc" "$unit" "$container")
        ga_pf_is_ours "$proc" "$unit" "$container" && ours=true
    fi
    read -r fw fws <<<"$(ga_pf_firewall_state "$proto" "$port")"
    # Порт свободен или наш, но закрыт локально — это отдельное состояние: мы
    # умеем открыть его сами (preflight_open_local). Чужой busy важнее файрвола.
    if [ "$fw" = "closed" ] && { [ "$state" = "free" ] || [ "$ours" = true ]; }; then
        state="closed_local"
    fi
    [ "$fw" = "unknown" ] && notes="${notes:+$notes }fw_unknown"
    [[ "$pid" =~ ^[0-9]+$ ]] && pid_json="$pid"
    if [ -n "$notes" ]; then
        notes_json=$(printf '%s\n' $notes | jq -R . | jq -sc .) || notes_json='[]'
    fi
    jq -nc --arg proto "$proto" --argjson port "$port" --arg state "$state" --arg addr "$addr" \
           --argjson pid "$pid_json" --arg process "$proc" --arg unit "$unit" \
           --arg container "$container" --arg product "$product" --argjson ours "$ours" \
           --arg fw "$fw" --arg fws "$fws" --argjson notes "$notes_json" \
           '{proto:$proto, port:$port, state:$state, addr:$addr, pid:$pid, process:$process,
             unit:$unit, container:$container, product:$product, ours:$ours,
             firewall:$fw, firewall_source:$fws, notes:$notes}'
}

# ══════════════════════════════════════════════════════════════════════════════
#  Публичные функции (CONTRACT §4.6a)
# ══════════════════════════════════════════════════════════════════════════════
ga_pf_valid_args() {
    local proto="${1:-}" port="${2:-}"
    case "$proto" in tcp|udp) ;; *) return 1 ;; esac
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

# preflight_port_owner <tcp|udp> <port> → stdout JSON
#   {state: free|busy|closed_local|unknown, pid, process, unit, container, product, ours, …}
preflight_port_owner() {
    local proto="${1:-}" port="${2:-}"
    if ! ga_pf_valid_args "$proto" "$port"; then
        ga_err preflight_bad_args "$(tf preflight_err_args "$proto" "$port")" 2
        return 2
    fi
    if ! command -v jq >/dev/null 2>&1; then
        ga_err no_jq "$(t preflight_err_no_jq)"
        return 1
    fi
    ga_pf_collect "$proto"
    ga_pf_owner "$proto" "$port"
}

# ga_pf_product_name <id> → человеческое имя продукта (пусто для unknown)
ga_pf_product_name() {
    case "${1:-}" in
        gotelegram|govless|godns|gowarp|gokaskad|xui|amnezia|goamnezia) t "preflight_product_$1" ;;
        *) printf '' ;;
    esac
}

# ga_pf_describe_owner <process> <pid> <unit> <container> <product> <short 0|1>
#   → «nginx (PID 812, юнит nginx.service) — похоже, это goTelegram Pro»
# short=1 — повтор того же владельца строкой ниже: только имя и PID, как в макете
# PLAN §4.3.1 («✗ TCP/80 занят: nginx (PID 812)»).
ga_pf_describe_owner() {
    local proc="${1:-}" pid="${2:-}" unit="${3:-}" container="${4:-}" product="${5:-unknown}" short="${6:-0}"
    local who details="" name
    who="$proc"
    [ -n "$who" ] || who=$(t preflight_who_unknown)
    [ -n "$pid" ] && [ "$pid" != "null" ] && details="$(tf preflight_who_pid "$pid")"
    if [ "$short" != 1 ]; then
        [ -n "$unit" ] && details="${details:+$details, }$(tf preflight_who_unit "$unit")"
    fi
    [ -n "$container" ] && details="${details:+$details, }$(tf preflight_who_container "$container")"
    [ -n "$details" ] && who="$who ($details)"
    if [ "$short" != 1 ]; then
        name=$(ga_pf_product_name "$product")
        [ -n "$name" ] && who="$who — $(tf preflight_looks_like "$name")"
    fi
    printf '%s' "$who"
}

# Метка порта для сообщений: «TCP/443» — одинакова в обоих языках.
ga_pf_label() { printf '%s/%s' "${1^^}" "$2"; }

# preflight_modes → stdout JSON
#   {lite: {available: true},
#    lite_site: {available, reasons: [{port, proto, state, process, pid, unit, container, product, message}]},
#    pro: {available, reasons: […]},            # те же причины: обоим нужны TCP/80 и TCP/443
#    warnings: [{code, port, proto, process, pid, unit, container, product, message}],
#    ports: {tcp80, tcp443, udp443},            # полные JSON preflight_port_owner
#    hints: {free_cmd, open_cmd}, dry_run}
# Правила: lite_site/pro недоступны при busy (не ours) или closed_local на TCP/80
# или TCP/443; ours не блокирует; занятый UDP/443 и unknown — предупреждения.
preflight_modes() {
    if ! command -v jq >/dev/null 2>&1; then
        ga_err no_jq "$(t preflight_err_no_jq)"
        return 1
    fi
    local reasons='[]' warnings='[]' free_cmd="" open_cmd="" closed_ports="" fw_src="" dry=false
    local spec proto port js state ours proc pid unit container product fws label who msg key seen=""
    local -A owner=()
    ga_pf_collect tcp udp
    ga_dry && dry=true
    for spec in $GA_PF_SITE_PORTS $GA_PF_SOFT_PORTS; do
        proto="${spec%%:*}"; port="${spec##*:}"
        js=$(ga_pf_owner "$proto" "$port") || return 1
        owner["$proto$port"]="$js"
    done
    # Причины (TCP/443, затем TCP/80 — как в макете) и предупреждения
    for spec in $GA_PF_SITE_PORTS $GA_PF_SOFT_PORTS; do
        proto="${spec%%:*}"; port="${spec##*:}"
        js="${owner[$proto$port]}"
        # Разделитель — U+001F, а не таб: таб для read — «пробельный» символ, и
        # два таба подряд (пустые container/pid) схлопываются, сдвигая поля.
        IFS=$'\x1f' read -r state ours proc pid unit container product fws <<<"$(printf '%s' "$js" | jq -r '[.state, (.ours|tostring), .process, (.pid // "" | tostring), .unit, .container, .product, .firewall_source] | join("")')"
        label=$(ga_pf_label "$proto" "$port")
        key="${unit:-}|${container:-}|${product:-}|${pid:-}"
        case "$state" in
            busy)
                if [ "$ours" = true ]; then
                    continue
                fi
                if [ "$proto" = "udp" ]; then
                    who=$(ga_pf_describe_owner "$proc" "$pid" "$unit" "$container" "$product" 0)
                    msg=$(tf preflight_warn_udp443 "$who")
                    warnings=$(jq -nc --argjson acc "$warnings" --arg code udp443_busy --argjson port "$port" --arg proto "$proto" \
                        --arg process "$proc" --argjson pid "${pid:-null}" --arg unit "$unit" --arg container "$container" \
                        --arg product "$product" --arg message "$msg" \
                        '$acc + [{code:$code, port:$port, proto:$proto, process:$process, pid:$pid, unit:$unit, container:$container, product:$product, message:$message}]')
                    continue
                fi
                if [[ " $seen " == *" $key "* ]]; then
                    who=$(ga_pf_describe_owner "$proc" "$pid" "$unit" "$container" "$product" 1)
                else
                    who=$(ga_pf_describe_owner "$proc" "$pid" "$unit" "$container" "$product" 0)
                    seen="$seen $key"
                fi
                msg=$(tf preflight_reason_busy "$label" "$who")
                # Контейнер важнее юнита: у docker-proxy юнит — docker.service, и
                # «systemctl disable --now docker.service» погасил бы все контейнеры,
                # включая наши. Останавливать надо именно контейнер.
                if [ -z "$free_cmd" ]; then
                    if [ -n "$container" ]; then free_cmd="docker stop $container"
                    elif [ -n "$unit" ]; then free_cmd="systemctl disable --now $unit"
                    fi
                fi
                ;;
            closed_local)
                [ "$proto" = "udp" ] && continue
                msg=$(tf preflight_reason_closed "$label" "$(t "preflight_fw_src_${fws%%+*}")")
                closed_ports="${closed_ports:+$closed_ports,}$port"
                fw_src="$fws"
                ;;
            unknown)
                msg=$(tf preflight_warn_unknown "$label" "$(t preflight_note_no_ss)")
                warnings=$(jq -nc --argjson acc "$warnings" --arg code check_unavailable --argjson port "$port" --arg proto "$proto" \
                    --arg message "$msg" \
                    '$acc + [{code:$code, port:$port, proto:$proto, process:"", pid:null, unit:"", container:"", product:"unknown", message:$message}]')
                continue
                ;;
            *)
                # free: проверка файрвола могла не состояться — предупредим один раз на порт
                if printf '%s' "$js" | jq -e '.notes | index("fw_unknown")' >/dev/null 2>&1; then
                    msg=$(tf preflight_warn_fw_unknown "$label" "$(t "preflight_fw_src_${fws%%+*}")")
                    warnings=$(jq -nc --argjson acc "$warnings" --arg code firewall_unknown --argjson port "$port" --arg proto "$proto" \
                        --arg message "$msg" \
                        '$acc + [{code:$code, port:$port, proto:$proto, process:"", pid:null, unit:"", container:"", product:"unknown", message:$message}]')
                fi
                continue
                ;;
        esac
        reasons=$(jq -nc --argjson acc "$reasons" --argjson port "$port" --arg proto "$proto" --arg state "$state" \
            --arg process "$proc" --argjson pid "${pid:-null}" --arg unit "$unit" --arg container "$container" \
            --arg product "$product" --arg fws "$fws" --arg message "$msg" \
            '$acc + [{port:$port, proto:$proto, state:$state, process:$process, pid:$pid, unit:$unit, container:$container, product:$product, firewall_source:$fws, message:$message}]')
    done
    if [ -n "$closed_ports" ]; then
        # Порты в команде — по возрастанию («80,443»), а не в порядке обхода
        closed_ports=$(printf '%s\n' "${closed_ports//,/$'\n'}" | sort -n | paste -sd, -)
        case "${fw_src%%+*}" in
            ufw)  open_cmd="ufw allow ${closed_ports}/tcp" ;;
            nft)  open_cmd="nft add rule inet filter input tcp dport { ${closed_ports} } accept" ;;
            *)    open_cmd="iptables -I INPUT -p tcp -m multiport --dports ${closed_ports} -j ACCEPT" ;;
        esac
    fi
    jq -nc --argjson r "$reasons" --argjson w "$warnings" \
           --argjson p80 "${owner[tcp80]}" --argjson p443 "${owner[tcp443]}" --argjson u443 "${owner[udp443]}" \
           --arg free_cmd "$free_cmd" --arg open_cmd "$open_cmd" --argjson dry "$dry" \
           '{lite: {available: true},
             lite_site: {available: ($r | length == 0), reasons: $r},
             pro: {available: ($r | length == 0), reasons: $r},
             warnings: $w,
             ports: {tcp80: $p80, tcp443: $p443, udp443: $u443},
             hints: {free_cmd: $free_cmd, open_cmd: $open_cmd},
             dry_run: $dry}'
}

# ga_pf_pad <строка> <ширина> — дополнить пробелами до ширины В СИМВОЛАХ.
# printf '%-14s' считает байты, и «Lite + сайт» уезжал бы на полстроки вправо.
ga_pf_pad() {
    local s="$1" w="$2" n
    n=${#s}
    printf '%s' "$s"
    while [ "$n" -lt "$w" ]; do printf ' '; n=$((n + 1)); done
}

# _ga_pf_mode_line <номер> <название> <описание> <available true|false> <итог по портам>
# Итог справа — про ПОРТЫ, а не «доступен/недоступен»: слово «доступен» ничего
# не объясняло («доступен» кому? почему второй — нет?), а «порт 443/tcp занят»
# сразу называет причину и что именно надо освободить (замечание владельца).
#
# Две строки вместо одной: раньше строка была 93 колонки (13 на имя + 58 на
# описание + итог) и не помещалась в стандартное окно 80×24 — правый край с
# ✓/✗ просто уезжал за экран (замечание критика). Теперь имя и итог по портам в
# первой строке, описание — во второй, с переносом по словам.
_ga_pf_mode_line() {
    local num="$1" name="$2" desc="$3" avail="$4" verdict="$5" mark w
    w="${GA_UI_W:-76}"
    if [ "$avail" = true ]; then
        mark="${GREEN}✓${NC} ${verdict}"
    else
        mark="${RED}✗${NC} ${verdict}"
    fi
    # Номер — только там, где его можно нажать (мастер). На экранах со своим
    # меню (brief) вместо номера точка: «2) VPN и сайт» над пунктом «2) Домен»
    # учил нажимать цифру, которая значит другое (находка T4, 25.09.2026).
    if [ -n "$num" ]; then
        echo -e "  ${CYAN}${num}${NC}) ${BOLD}$(ga_pf_pad "$name" 22)${NC} ${mark}" >&2
    else
        echo -e "  ${DIM}•${NC}  ${BOLD}$(ga_pf_pad "$name" 22)${NC} ${mark}" >&2
    fi
    # Висячий отступ 5 — под первую букву описания: без него хвост переноса
    # вставал в нулевую колонку и строка «на своём порту.» начиналась у самого
    # края экрана.
    echo -e "     ${DIM}$(ga_wrap "$desc" "$(( w - 5 ))" 5)${NC}" >&2
}

# Итог по портам одной строкой: свободны / «порт 443/tcp занят» / «порт 80/tcp
# закрыт файрволом». Порты перечисляются по возрастанию, дубли снимаются —
# один и тот же 443 приходит и как причина lite_site, и как причина pro.
# Третий аргумент site — режиму нужны TCP 80/443 сайта: держит их наше же (свой nginx, свой контейнер) — так и
# сказать, а не «порты свободны» на сервере, где сайт уже стоит (находка NC6-04 критика-новичка).
# Печатает ТОЛЬКО строку (вызов через $()).
_ga_pf_ports_verdict() {
    local js="$1" available="$2" need="${3:-}" ports_busy ports_closed ours
    if [ "$available" = true ]; then
        if [ "$need" = site ]; then
            ours=$(printf '%s' "$js" | jq -r '[.ports.tcp80, .ports.tcp443 | select(. != null and .ours == true and (.state == "busy" or .state == "closed_local")) | {p: .port, s: "\(.port)/\(.proto)"}] | sort_by(.p) | map(.s) | join(", ")' 2>/dev/null)
            case "$ours" in
                "")  ;;
                *,*) printf '%s' "$(tf preflight_ports_ours_many "$ours")"; return 0 ;;
                *)   printf '%s' "$(tf preflight_ports_ours_one "$ours")"; return 0 ;;
            esac
        fi
        printf '%s' "$(t preflight_ports_free)"
        return 0
    fi
    # Сортировка по НОМЕРУ порта: `unique` над строками поставил бы «443» перед
    # «80», и человек читал бы список задом наперёд.
    ports_busy=$(printf '%s' "$js" | jq -r '[.pro.reasons[]? | select(.state == "busy") | {p: .port, s: "\(.port)/\(.proto)"}] | unique_by(.s) | sort_by(.p) | map(.s) | join(", ")' 2>/dev/null)
    ports_closed=$(printf '%s' "$js" | jq -r '[.pro.reasons[]? | select(.state == "closed_local") | {p: .port, s: "\(.port)/\(.proto)"}] | unique_by(.s) | sort_by(.p) | map(.s) | join(", ")' 2>/dev/null)
    if [ -n "${ports_busy:-}" ]; then
        printf '%s' "$(tf preflight_ports_busy "$ports_busy")"
    elif [ -n "${ports_closed:-}" ]; then
        printf '%s' "$(tf preflight_ports_closed "$ports_closed")"
    else
        printf '%s' "$(t preflight_ports_unknown)"
    fi
}

# _ga_pf_lazy_desc <json> → описание Ленивого Pro с хвостом по положению дел: здесь уже стоит goAmnezia — доставит
# недостающее и людей не тронет; UDP 443 занят чужим — встанет Semi-Pro. Прежде «UDP 443 занят — встанет Semi-Pro»
# стояло всегда, и на Pro, где UDP 443 держит наша же линия, читалось как поломка (находка NC6-04).
_ga_pf_lazy_desc() {
    local js="$1" desc
    desc=$(t preflight_desc_lazy)
    if type ga_config_get >/dev/null 2>&1 && [ "$(ga_config_get .installed 2>/dev/null)" = true ]; then
        desc="$desc $(t preflight_lazy_installed)"
    fi
    if printf '%s' "$js" | jq -e '[.warnings[]? | select(.code == "udp443_busy")] | length > 0' >/dev/null 2>&1; then
        desc="$desc $(t preflight_lazy_udp443_busy)"
    fi
    printf '%s' "$desc"
}

# _ga_pf_udp443_ours_line <json> → «UDP 443 — наша линия 2.0, всё в порядке» (или «наш профиль awg2», если линии
# в конфиге нет) либо пусто, когда UDP 443 не наш. Профиль — по имени контейнера из config.json.
_ga_pf_udp443_ours_line() {
    local js="$1" c p="" line="" cfg
    [ "$(printf '%s' "$js" | jq -r '.ports.udp443.ours // false' 2>/dev/null)" = true ] || return 0
    c=$(printf '%s' "$js" | jq -r '.ports.udp443.container // ""' 2>/dev/null)
    cfg="${CONFIG_FILE:-${GOAMNEZIA_DIR:-/opt/goamnezia}/config.json}"
    if [ -n "$c" ] && [ -f "$cfg" ]; then
        IFS=$'\t' read -r p line <<<"$(jq -r --arg c "$c" '[.profiles // {} | to_entries[] | select(.value.container == $c) | [.key, (.value.line // "")]] | (.[0] // ["", ""]) | @tsv' "$cfg" 2>/dev/null)"
    fi
    if [[ "$line" =~ ^(1\.0|1\.5|2\.0|3\.1)$ ]]; then
        tf preflight_udp443_ours "$line"
    else
        tf preflight_udp443_ours_other "${p:-${c:-?}}"
    fi
}

# preflight_render_modes <json> [wizard|brief] → stderr: экран выбора режима
# (PLAN §4.3.1, docs/MODES_047.md): четыре строки режимов с ✓/✗, причины с процессом/PID/юнитом/
# продуктом, предупреждения ⚠, подсказки. Вариант brief — без заголовка и без
# строки «выбрать режим — цифра» (для экрана «Режим и сайт», где меню своё).
preflight_render_modes() {
    local js="${1:-}" variant="${2:-wizard}" a_lite a_site a_pro free_cmd open_cmd line
    if [ -z "$js" ] || ! printf '%s' "$js" | jq -e . >/dev/null 2>&1; then
        ga_err preflight_bad_json "$(t preflight_err_json)"
        return 1
    fi
    # U+001F вместо таба: пустой free_cmd не должен сдвигать open_cmd (см. preflight_modes)
    IFS=$'\x1f' read -r a_lite a_site a_pro free_cmd open_cmd <<<"$(printf '%s' "$js" | jq -r '[(.lite.available|tostring), (.lite_site.available|tostring), (.pro.available|tostring), (.hints.free_cmd // ""), (.hints.open_cmd // "")] | join("")')"
    echo "" >&2
    if [ "$variant" != brief ]; then
        echo -e "  ${BOLD}${WHITE}$(t preflight_title)${NC}" >&2
        echo "" >&2
    fi
    # Порядок и названия — договор 0.6.0 (docs/MODES_047.md): 1 Ленивый Pro, 2 Pro, 3 Semi-Pro, 4 Lite; внутренние
    # id прежние. Ленивому Pro нужны те же TCP 80/443, что Pro (UDP 443 занят — он сам встанет Semi-Pro).
    local n0=1 n1=2 n2=3 n3=4
    [ "$variant" = brief ] && { n0=""; n1=""; n2=""; n3=""; }
    _ga_pf_mode_line "$n0" "$(t preflight_mode_lazy)" "$(_ga_pf_lazy_desc "$js")" "$a_pro" "$(_ga_pf_ports_verdict "$js" "$a_pro" site)"
    _ga_pf_mode_line "$n1" "$(t preflight_mode_pro)" "$(t preflight_desc_pro)" "$a_pro" "$(_ga_pf_ports_verdict "$js" "$a_pro" site)"
    _ga_pf_mode_line "$n2" "$(t preflight_mode_lite_site)" "$(t preflight_desc_lite_site)" "$a_site" "$(_ga_pf_ports_verdict "$js" "$a_site" site)"
    _ga_pf_mode_line "$n3" "$(t preflight_mode_lite)" "$(t preflight_desc_lite)" "$a_lite" "$(_ga_pf_ports_verdict "$js" "$a_lite")"
    # UDP 443 держит наша же линия — сказать словами, что это она и всё в порядке (NC6-04)
    line=$(_ga_pf_udp443_ours_line "$js")
    [ -n "$line" ] && echo -e "  ${CYAN}ℹ${NC} $(ga_wrap "$line" "$(( ${GA_UI_W:-76} - 2 ))" 2)" >&2
    echo "" >&2
    # Легенда: без неё человек видит строки режимов и не понимает, по какому
    # признаку выбирать (замечание владельца «нет легенды»). Три строки — «что
    # значат галочки», «кому какой режим» и отдельная строка на случай «не
    # уверен»: без неё выбор между вторым и третьим режимом остаётся гаданием.
    # «Кому какой режим» и «жмите Enter» — советы мастера: на экранах со своим
    # меню (brief) Enter режим не выбирает, и совет вёл бы не туда.
    echo -e "  ${DIM}$(ga_wrap "$(t preflight_legend_marks)" "${GA_UI_W:-76}" 2)${NC}" >&2
    if [ "$variant" != brief ]; then
        echo -e "  ${DIM}$(ga_wrap "$(t preflight_legend_pick)" "${GA_UI_W:-76}" 2)${NC}" >&2
        echo -e "  ${DIM}$(ga_wrap "$(t preflight_legend_unsure)" "${GA_UI_W:-76}" 2)${NC}" >&2
    fi
    echo "" >&2
    # Причины и предупреждения: сообщения уже собраны preflight_modes на языке
    # словаря — экран их только раскрашивает
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        echo -e "  ${RED}✗${NC} $(ga_wrap "$line" "$(( ${GA_UI_W:-76} - 2 ))" 2)" >&2
    done < <(printf '%s' "$js" | jq -r '.pro.reasons[]? | .message // empty')
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        echo -e "  ${YELLOW}⚠${NC} $(ga_wrap "$line" "$(( ${GA_UI_W:-76} - 2 ))" 2)" >&2
    done < <(printf '%s' "$js" | jq -r '.warnings[]? | .message // empty')
    if [ "$a_pro" != true ]; then
        echo "" >&2
        # В jq 1.6 пустой результат select с -e даёт 0; any всегда возвращает явное true/false.
        if printf '%s' "$js" | jq -e 'any(.pro.reasons[]?; .state == "busy")' >/dev/null 2>&1; then
            if [ -n "$free_cmd" ]; then
                echo -e "  $(tf preflight_hint_free "$free_cmd")" >&2
            else
                echo -e "  $(t preflight_hint_free_generic)" >&2
            fi
        fi
        if [ -n "$open_cmd" ]; then
            echo -e "  $(tf preflight_hint_closed "$open_cmd")" >&2
        fi
    fi
    # Номер пункта «повторить проверку» приходит от вызывающего: в мастере и на
    # экране режима пунктов разное число, а управление в продукте только
    # цифрами — буква «r» была последней в этих двух местах.
    # Пустое значение — «на этом экране повторять нечем»: там, где ввод не
    # читается (диагностика), звать нажать цифру нельзя, она провалится в меню.
    local again="${GA_PF_AGAIN_ITEM-5}"
    if [ -z "$again" ]; then
        :
    elif [ "$variant" != brief ]; then
        echo -e "  ${DIM}$(ga_wrap "$(tf preflight_prompt "$again")" "${GA_UI_W:-76}" 2)${NC}" >&2
    else
        echo -e "  ${DIM}$(tf preflight_prompt_brief "$again")${NC}" >&2
    fi
    return 0
}

# preflight_open_local <port> <proto> — открыть порт в локальном файрволе.
# Согласие уже получено вызывающим (мастер спрашивает «Открыть 80/443 в ufw?»),
# здесь только действие: ufw активен → `ufw allow`; иначе iptables (и ip6tables,
# если есть) с сохранением через netfilter-persistent, когда он установлен —
# без этого правило исчезнет при перезагрузке, и сайт молча погаснет.
# Чистый nftables без iptables не трогаем: имена таблиц и цепочек произвольны,
# промахнуться проще, чем помочь — печатаем подсказку и возвращаем ошибку.
preflight_open_local() {
    local port="${1:-}" proto="${2:-tcp}" raw="" rc=0 how="" bin
    if ! ga_pf_valid_args "$proto" "$port"; then
        ga_err preflight_bad_args "$(tf preflight_err_args "$proto" "$port")" 2
        return 2
    fi
    raw=$(ga_pf_source GOAMNEZIA_UFW_FIXTURE GOAMNEZIA_UFW_BIN ufw status) || rc=$?
    if [ "$rc" = 0 ] && printf '%s\n' "$raw" | grep -q '^Status: active'; then
        bin=$(ga_pf_bin GOAMNEZIA_UFW_BIN ufw)
        log_info "$(tf preflight_open_ufw "$port" "$proto")"
        if ! ga_pf_run "$bin" allow "${port}/${proto}"; then
            ga_err preflight_open_failed "$(tf preflight_open_failed "$port" "$proto" "ufw allow ${port}/${proto}")"
            return 1
        fi
        how="ufw"
    else
        # Закрывает родной nftables (своя таблица, не отражение iptables-nft): правило iptables легло бы в
        # другую таблицу, а базовая цепочка nft с policy drop пакет всё равно отбросила бы — раньше так и
        # было: правило ставилось, и человеку рапортовался успех (находка SR-19). Как сказано выше, nft
        # сами не трогаем — отказ с готовой командой для своей таблицы.
        local fws=""
        if type ga_pf_collect >/dev/null 2>&1 && type ga_pf_firewall_state >/dev/null 2>&1; then
            ga_pf_collect "$proto" >/dev/null 2>&1
            fws=$(ga_pf_firewall_state "$proto" "$port" 2>/dev/null) || fws=""
        fi
        if [ "$fws" = "closed nft" ]; then
            ga_err preflight_open_nft "$(tf preflight_open_nft "$port" "$proto" "nft add rule inet filter input ${proto} dport ${port} accept")"
            return 1
        fi
        bin=$(ga_pf_bin GOAMNEZIA_IPTABLES_BIN iptables)
        if ! ga_dry && ! command -v "$bin" >/dev/null 2>&1; then
            ga_err preflight_no_fw_tool "$(tf preflight_open_no_tool "$port" "$proto")"
            return 1
        fi
        log_info "$(tf preflight_open_iptables "$port" "$proto")"
        if ! ga_pf_run "$bin" -I INPUT -p "$proto" --dport "$port" -j ACCEPT; then
            ga_err preflight_open_failed "$(tf preflight_open_failed "$port" "$proto" "iptables -I INPUT -p ${proto} --dport ${port} -j ACCEPT")"
            return 1
        fi
        # Правило легло, а порт всё ещё закрыт (рядом таблица nft со своим drop) — это не успех. На стенде
        # правила не применяются, и перепроверка сказала бы «закрыт» всегда — там её нет.
        if ! ga_dry && [ -n "$fws" ]; then
            ga_pf_collect "$proto" >/dev/null 2>&1
            fws=$(ga_pf_firewall_state "$proto" "$port" 2>/dev/null) || fws=""
            if [ "${fws%% *}" = closed ]; then
                ga_err preflight_open_nft "$(tf preflight_open_nft "$port" "$proto" "nft add rule inet filter input ${proto} dport ${port} accept")"
                return 1
            fi
        fi
        if ga_dry || command -v ip6tables >/dev/null 2>&1; then
            ga_pf_run ip6tables -I INPUT -p "$proto" --dport "$port" -j ACCEPT || true
        fi
        if ga_dry || command -v netfilter-persistent >/dev/null 2>&1; then
            ga_pf_run netfilter-persistent save || log_warning "$(t preflight_open_persist_warn)"
        else
            log_warning "$(t preflight_open_persist_warn)"
        fi
        how="iptables"
    fi
    if type ga_audit >/dev/null 2>&1; then
        ga_audit "${GOAMNEZIA_WHO:-ssh}" "preflight-open" "${port}/${proto} via ${how}"
    fi
    log_success "$(tf preflight_open_done "$port" "$proto" "$how")"
    return 0
}
