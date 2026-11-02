#!/usr/bin/env bash
# lib/edgeips.sh — несколько внешних адресов сервера: учёт трафика по каждому
# адресу и сторож «адрес замолчал» (DEFECTS §2.3, замысел — docs/EDGEIPS.md).
#
# Порты профилей Docker публикует на все адреса машины, поэтому второй адрес
# принимает клиентов без правок контейнера. Счётчики — правила без действия в
# своей цепочке таблицы mangle: PREROUTING mangle стоит ДО DNAT Docker, и адрес
# назначения там ещё настоящий, а не адрес контейнера.
#
# Считаются ПАКЕТЫ установленных соединений (conntrack ESTABLISHED), а не байты:
# по байтам спящий клиент (keepalive — сотни байт за тик) не отличался от
# сканера, перебирающего порты. Сканеру AmneziaWG не отвечает, и его поток
# остаётся NEW; подключённый клиент, даже спящий, шлёт keepalive в уже
# установленном соединении.

GA_EDGE_CHAIN="${GA_EDGE_CHAIN:-GOAMNEZIA_EDGE}"
# Шаг тика сторожа. Разрыв между соседними тиками больше трёх шагов — не тишина, а отсутствие
# наблюдения (сервер был выключен): счёт тишины через разрыв не идёт.
GA_EDGE_TICK_SECONDS="${GA_EDGE_TICK_SECONDS:-120}"
GA_EDGE_GAP_SECONDS="${GA_EDGE_GAP_SECONDS:-360}"
# Тишина короче 10 тиков (20 минут) — не повод.
GA_EDGE_DARK_STRIKES="${GA_EDGE_DARK_STRIKES:-10}"
# Сравнение с прошлыми днями — окно ±90 минут вокруг того же времени суток, что у последнего наблюдения.
# День «занят», если в окне живы 90% тиков: адрес в это время суток принимает непрерывно, а не «кто-то
# зашёл на минуту». «Обычно занят» — занят не меньше чем в 70% из 7 прошлых дней с историей (таких дней
# не меньше двух) или занят в тот же день недели и неделю, и две недели назад: выходные последней недели
# не размывают будничную привычку. Тишина в тот же день недели неделю назад тревогу снимает (суббота после
# рабочей недели, пользователь «через день»), если только две недели назад в это время не было занято —
# разовый праздник неделю назад настоящую блокировку не глушит.
# Окно — на текущем времени суток, а не на начале тишины: блокировку, начавшуюся ночью, видно утром, а
# конец обычного дня тревогой не выглядит. Полтора часа в обе стороны — чтобы край дня (пришли позже,
# ушли раньше, перевод часов у клиентов) не был тревогой; цена — утреннюю блокировку видно примерно через
# час с небольшим после обычного начала трафика. Дни, чьё окно заходит в нынешнюю тишину, не в счёт:
# блокировка дольше суток сама не превращается в «привычку молчать».
GA_EDGE_HISTORY_DAYS="${GA_EDGE_HISTORY_DAYS:-7}"
GA_EDGE_BUSY_HALF_SECONDS="${GA_EDGE_BUSY_HALF_SECONDS:-5400}"
GA_EDGE_BUSY_SHARE="${GA_EDGE_BUSY_SHARE:-90}"
GA_EDGE_USUAL_SHARE="${GA_EDGE_USUAL_SHARE:-70}"
# Адрес с одним пользователем тревоги не даёт: по счётчикам отгул человека от блокировки не отличить.
GA_EDGE_MIN_USERS="${GA_EDGE_MIN_USERS:-2}"
# «Снова принимает» — после стольких живых тиков подряд: один пакет с непострадавшей сети — ещё не
# возврат.
GA_EDGE_BACK_TICKS="${GA_EDGE_BACK_TICKS:-3}"
# История — две недели сравнения (тот же день недели две недели назад) и запас; резать — не чаще раза в
# сутки.
GA_EDGE_RETENTION_DAYS="${GA_EDGE_RETENTION_DAYS:-15}"
# Тревога по одному адресу — не чаще раза в сутки (и напоминание о всё ещё тёмном — тоже).
GA_EDGE_REMIND_SECONDS="${GA_EDGE_REMIND_SECONDS:-86400}"
GA_EDGE_HEADER="timestamp,ip,port,packets,bytes"
# История версий до 0.4.4 — без байтов; её строки читаются с нулём байтов, а шапка переписывается на месте
# (сбросить историю значило бы неделю заново учить сторожа привычкам адресов).
GA_EDGE_HEADER_V1="timestamp,ip,port,packets"
# Часы модуля. GA_EDGE_NOW подставляют проверки: тики в прогоне идут в одну секунду, а в работе —
# раз в две минуты, и без подстановки три тика подряд сливались бы в один.
_ga_edge_now() { printf '%s' "${GA_EDGE_NOW:-$(date -u +%s)}"; }

ga_edge_state_dir() { printf '%s' "${GOAMNEZIA_STATE_DIR:-$GOAMNEZIA_DIR/state}"; }
ga_edge_history() { printf '%s/edge_ips.csv' "$(ga_edge_state_dir)"; }
ga_edge_alerts_file() { printf '%s/edge_alerts.json' "$(ga_edge_state_dir)"; }

# Глобальные IPv4 машины: без петли, частных сетей, link-local и CGNAT —
# клиенты приходят только на глобальные адреса.
ga_edge_list() {
    # Стенд (dry-run): адреса машины — из GOAMNEZIA_EDGE_IPS_STUB (через пробел), как ответ DNS у сайта
    # из GOAMNEZIA_DNS_STUB; без переменной — как на сервере.
    if ga_dry && [ -n "${GOAMNEZIA_EDGE_IPS_STUB+x}" ]; then
        tr ' ' '\n' <<<"$GOAMNEZIA_EDGE_IPS_STUB" | sed '/^$/d' | sort -u
        return 0
    fi
    ip -4 -o addr show scope global 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 \
        | grep -vE '^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|169\.254\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' \
        | sort -u
}

# UDP-порты включённых профилей, по одному в строке.
ga_edge_ports() {
    local profiles p port
    ga_profiles_load profiles || return 1
    for p in $profiles; do
        [ "$(ga_config_get ".profiles.$p.enabled" 2>/dev/null)" = "false" ] && continue
        port=$(ga_profile_field "$p" port)
        [[ "$port" =~ ^[0-9]+$ ]] && printf '%s\n' "$port"
    done | sort -un
}

# iptables с ожиданием замка xtables: без -w вызов, совпавший с Docker, fail2ban или ufw,
# падал, а отказ «-S» читался как «правил нет» — и весь набор добавлялся повторно.
_ga_edge_ipt_read() { iptables -w 5 "$@"; }
_ga_edge_ipt() {
    if ga_dry; then ga_dry_echo "iptables -w 5 $*"; return 0; fi
    iptables -w 5 "$@"
}

# Строки «ip<TAB>порт<TAB>правило» для правил цепочки из iptables -S. Правило не нашего вида
# (без адреса, порта или признака ESTABLISHED) идёт с «-» вместо адреса и порта.
_ga_edge_rule_keys() {
    awk -v chain="$GA_EDGE_CHAIN" '
        $1 == "-A" && $2 == chain {
            ip = ""; port = ""; est = 0
            for (i = 3; i <= NF; i++) {
                if ($i == "-d") { ip = $(i + 1); sub(/\/32$/, "", ip) }
                if ($i == "--dport") port = $(i + 1)
                if ($i == "--ctstate" && $(i + 1) == "ESTABLISHED") est = 1
            }
            if (ip == "" || port == "" || !est) { ip = "-"; port = "-" }
            print ip "\t" port "\t" $0
        }'
}

# ga_edge_rules_remove — снять цепочку учёта целиком: все переходы из PREROUTING, правила и саму
# цепочку. Зовётся при сносе продукта: иначе счётчики по адресам висели бы в mangle до перезагрузки
# (находка SR-01, 25.09.2026). Идемпотентно; без iptables — нечего снимать.
ga_edge_rules_remove() {
    command -v iptables >/dev/null 2>&1 || return 0
    local jumps n
    jumps=$(_ga_edge_ipt_read -t mangle -S PREROUTING 2>/dev/null) || jumps=""
    n=$(grep -cxF -- "-A PREROUTING -j $GA_EDGE_CHAIN" <<<"$jumps")
    while [ "${n:-0}" -gt 0 ]; do
        _ga_edge_ipt -t mangle -D PREROUTING -j "$GA_EDGE_CHAIN" >/dev/null 2>&1 || break
        n=$((n - 1))
    done
    _ga_edge_ipt -t mangle -F "$GA_EDGE_CHAIN" >/dev/null 2>&1 || true
    _ga_edge_ipt -t mangle -X "$GA_EDGE_CHAIN" >/dev/null 2>&1 || true
    return 0
}

# Правила: цепочка, ровно один переход из PREROUTING и ровно одно правило на пару «адрес, порт».
# Идемпотентно. Пропавшие адреса, сменённые порты, чужой вид и лишние копии снимаются: копия
# перехода считала бы каждый пакет дважды.
ga_edge_ensure_rules() {
    command -v iptables >/dev/null 2>&1 || return 1
    local ips ports have jumps ip port key rule n rc
    ips=$(ga_edge_list); ports=$(ga_edge_ports) || return 1
    [ -n "$ips" ] && [ -n "$ports" ] || return 0
    have=$(_ga_edge_ipt_read -t mangle -S "$GA_EDGE_CHAIN" 2>/dev/null); rc=$?
    # Код 4 — замок xtables занят и после ожидания: ничего не трогаем до следующего тика. Иной
    # отказ — цепочки ещё нет (у legacy и nft это код 1).
    [ "$rc" = 4 ] && return 1
    if [ "$rc" != 0 ]; then
        _ga_edge_ipt -t mangle -N "$GA_EDGE_CHAIN" >/dev/null 2>&1 || true
        if ga_dry; then
            have=""
        else
            have=$(_ga_edge_ipt_read -t mangle -S "$GA_EDGE_CHAIN" 2>/dev/null) || return 1
        fi
    fi
    jumps=$(_ga_edge_ipt_read -t mangle -S PREROUTING 2>/dev/null) || return 1
    n=$(grep -cxF -- "-A PREROUTING -j $GA_EDGE_CHAIN" <<<"$jumps")
    if [ "${n:-0}" -eq 0 ]; then
        _ga_edge_ipt -t mangle -I PREROUTING 1 -j "$GA_EDGE_CHAIN" || return 1
    fi
    while [ "${n:-0}" -gt 1 ]; do
        _ga_edge_ipt -t mangle -D PREROUTING -j "$GA_EDGE_CHAIN" || break
        n=$((n - 1))
    done
    local -A want=() seen=()
    for ip in $ips; do
        for port in $ports; do want["$ip"$'\t'"$port"]=1; done
    done
    while IFS=$'\t' read -r ip port rule; do
        [ -n "$rule" ] || continue
        key="$ip"$'\t'"$port"
        if [ "$ip" = "-" ] || [ -z "${want[$key]:-}" ] || [ -n "${seen[$key]:-}" ]; then
            # shellcheck disable=SC2086 # правило — готовый список аргументов iptables
            _ga_edge_ipt -t mangle ${rule/-A /-D } || true
            continue
        fi
        seen["$key"]=1
    done < <(printf '%s\n' "$have" | _ga_edge_rule_keys)
    for key in "${!want[@]}"; do
        [ -n "${seen[$key]:-}" ] && continue
        ip="${key%%$'\t'*}"; port="${key#*$'\t'}"
        _ga_edge_ipt -t mangle -A "$GA_EDGE_CHAIN" -d "$ip/32" -p udp -m udp --dport "$port" \
            -m conntrack --ctstate ESTABLISHED || return 1
    done
    return 0
}

# Накопительные счётчики по паре «адрес, порт»: «ip<TAB>порт<TAB>пакеты<TAB>байты». Из iptables-save -c:
# формат «[пакеты:байты] -A цепочка …» один у legacy и у nft-сборки. Считается только входящее от
# клиентов (ESTABLISHED на порт профиля): вердикту нужны пакеты, экранам — байты.
ga_edge_counters() {
    iptables-save -c -t mangle 2>/dev/null \
        | awk -v chain="$GA_EDGE_CHAIN" '
            $2 == "-A" && $3 == chain && $1 ~ /^\[[0-9]+:[0-9]+\]$/ {
                split(substr($1, 2, length($1) - 2), c, ":")
                ip = ""; port = ""; est = 0
                for (i = 4; i <= NF; i++) {
                    if ($i == "-d") { ip = $(i + 1); sub(/\/32$/, "", ip) }
                    if ($i == "--dport") port = $(i + 1)
                    if ($i == "--ctstate" && $(i + 1) == "ESTABLISHED") est = 1
                }
                if (ip != "" && port != "" && est) { p[ip "\t" port] += c[1]; b[ip "\t" port] += c[2] }
            }
            END { for (k in p) printf "%s\t%d\t%d\n", k, p[k], b[k] }' \
        | sort
}

# Снимок в историю: timestamp,ip,port,packets — накопительные. Приросты читатель считает по
# каждой паре отдельно: снятое правило одного порта не должно выглядеть обнулением адреса.
ga_edge_sample() {
    local f now ip port pkts bytes head
    ga_edge_ensure_rules || return 1
    f=$(ga_edge_history); now=$(_ga_edge_now)
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
    head=$(head -1 "$f" 2>/dev/null)
    if [ "$head" = "$GA_EDGE_HEADER_V1" ]; then
        sed -i.bak "1s/.*/$GA_EDGE_HEADER/" "$f" 2>/dev/null && rm -f "$f.bak"
    elif [ ! -f "$f" ] || [ "$head" != "$GA_EDGE_HEADER" ]; then
        printf '%s\n' "$GA_EDGE_HEADER" >"$f" && chmod 600 "$f"
    fi
    while IFS=$'\t' read -r ip port pkts bytes; do
        [ -n "$ip" ] && printf '%s,%s,%s,%s,%s\n' "$now" "$ip" "$port" "${pkts:-0}" "${bytes:-0}" >>"$f"
    done < <(ga_edge_counters)
    _ga_edge_prune "$f"
}

_ga_edge_prune() {
    local f="$1" cutoff oldest tmp
    cutoff=$(( $(_ga_edge_now) - GA_EDGE_RETENTION_DAYS * 86400 ))
    oldest=$(sed -n '2{s/,.*//;p;q;}' "$f" 2>/dev/null)
    # Резать, только когда хвост старше срока на сутки: после первого среза самая старая строка
    # ложилась на границу, и файл переписывался на каждом тике.
    [[ "$oldest" =~ ^[0-9]+$ ]] && [ "$oldest" -lt $(( cutoff - 86400 )) ] || return 0
    tmp=$(mktemp "${f}.XXXXXX") || return 0
    if awk -F, -v c="$cutoff" 'NR == 1 || $1 + 0 >= c' "$f" >"$tmp" && chmod 600 "$tmp"; then
        mv -f "$tmp" "$f"
    else
        rm -f "$tmp"
    fi
}

# Общий адрес в ключах — та же цепочка, что у выдачи ключа (ga_export_endpoint_host), но без
# похода в сеть: endpoint_host, иначе домен сервера по умолчанию, иначе server_ip.
_ga_edge_common_endpoint() {
    local h
    h=$(ga_config_get .endpoint_host 2>/dev/null)
    if [ -z "$h" ] || [ "$h" = null ]; then
        h=""
        if type ga_export_pro_domain >/dev/null 2>&1; then
            h=$(ga_export_pro_domain 2>/dev/null) || h=""
        fi
        [ -n "$h" ] || h=$(ga_config_get .server_ip 2>/dev/null)
    fi
    [ "$h" = null ] && h=""
    printf '%s' "$h"
}

# _ga_edge_dns_json — A-записи домена из ключей (кэш две минуты: сторож тикает раз в две минуты, а
# шапка меню — раз в 30 секунд). DNS не ответил — последний удачный ответ из кэша: иначе на тике со
# сбоем DNS доменные пользователи снова считались бы на каждом адресе, и адрес, снятый из DNS, давал
# бы ложную тревогу. Ключи на IP — пусто: DNS тут ни при чём. Формат — ga_site_dns_state.
_ga_edge_dns_json() {
    local common
    common=$(_ga_edge_common_endpoint)
    [ -n "$common" ] || return 1
    _valid_ip "$common" && return 1
    type ga_site_dns_state >/dev/null 2>&1 || return 1
    ga_site_dns_state "$common" "${GA_EDGE_DNS_TTL:-120}" stale 2>/dev/null
}

# _ga_edge_dns_set [JSON из _ga_edge_dns_json] — на каких адресах машины считать доменных пользователей:
#   «адрес адрес…» — адреса машины из A-записей (ok, partial);
#   «-»            — домен известен, но сюда не ведёт (elsewhere) или записей нет (none): люди с такими
#                    ключами сюда не приходят вовсе;
#   пусто          — не знаем (ключи на IP, DNS не ответил и удачного ответа не было): по-старому, на каждом.
_ga_edge_dns_set() {
    local js="${1:-}"
    [ -n "$js" ] || js=$(_ga_edge_dns_json) || return 0
    jq -r 'if .state == "ok" or .state == "partial" then (.ours | join(" "))
           elif .state == "elsewhere" or .state == "none" then "-"
           else "" end' <<<"$js" 2>/dev/null
}

# Включённые профили JSON-массивом: их порты принимают (ga_edge_ports), у выключенного правила сняты.
_ga_edge_enabled_profiles() {
    local profiles p
    local -a on=()
    ga_profiles_load profiles || return 1
    for p in $profiles; do
        [ "$(ga_config_get ".profiles.$p.enabled" 2>/dev/null)" = "false" ] && continue
        on+=("$p")
    done
    printf '%s\n' ${on[@]+"${on[@]}"} | jq -R . | jq -sc 'map(select(. != ""))'
}

# Пользователи по адресам: «адрес<TAB>число» для каждого адреса, на который смотрит хоть один ключ
# включённого пользователя с пиром в конфиге (active) включённого профиля: пользователь одного лишь
# выключенного профиля подключиться не может, и его адрес трафика не ждёт. Когда в ключе домен, адрес
# решает DNS: такие пользователи идут строкой «?<TAB>число», и отчёт считает их на каждом адресе. Правило
# то же, что у выдачи ключа (ga_export_endpoint_host): домен, вписанный в endpoint_host, побеждает и
# свой адрес пользователя, а домен сервера по умолчанию ему уступает.
ga_edge_users_map() {
    local users common pinned enabled
    ga_capture users ga_users_json || return 1
    enabled=$(_ga_edge_enabled_profiles) || return 1
    common=$(_ga_edge_common_endpoint)
    pinned=$(ga_config_get .endpoint_host 2>/dev/null)
    [ "$pinned" = null ] && pinned=""
    jq -r --arg common "$common" --arg pinned "$pinned" --argjson on "$enabled" '
        ($common | test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$")) as $ip_common
        | ($pinned != "" and ($pinned | test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$") | not)) as $pinned_domain
        | [.users[]? | select(.enabled != false)
           | select([(.peers // {}) | to_entries[] | select(.value.active != false) | .key
                     | . as $p | select($on | any(. == $p))] | length > 0)
           | (.endpoint_ip // "") as $own
           | if $own != "" and ($pinned_domain | not) then $own elif $ip_common then $common else "?" end]
        | group_by(.) | .[] | "\(.[0])\t\(length)"' <<<"$users"
}
ga_edge_users_on() {
    local n
    n=$(ga_edge_users_map 2>/dev/null | awk -F'\t' -v ip="${1:-}" '$1 == ip { print $2 }')
    printf '%s' "${n:-0}"
}

# Вердикт по каждому адресу машины: «ip<TAB>пакеты за последний тик<TAB>пакеты за сутки<TAB>вердикт
# <TAB>пользователей<TAB>начало тишины (ts или 0)<TAB>живых тиков подряд в конце<TAB>пакеты за 15 минут
# <TAB>пакеты за час<TAB>байты за 15 минут<TAB>байты за час<TAB>байты за сутки».
#   unused    — на адрес не смотрит ни один ключ (при доменном Endpoint адрес выбирает DNS, как в
#               goTelegram, и все пользователи считаются на каждом адресе);
#   quiet     — адрес ни разу не принимал, или тишина есть, но в это время он обычно и молчит;
#   ok        — трафик идёт или тишина короче 20 минут, пока соседний адрес принимает;
#   quiet-all — в последний тик ни один адрес не принимал (ночь, клиентов нет) — не тревога, и вердикт у
#               всех молчащих адресов один, как бы давно каждый ни замолчал (NC6-10);
#   dark      — на адрес смотрят не меньше двух пользователей, 20 минут подряд ни пакета (без разрывов в
#               наблюдении), у соседнего адреса в последний тик пакеты были, а в это время суток адрес
#               обычно занят (окно ±90 минут, 90% живых тиков, 70% дней или тот же день недели неделю и
#               две недели назад — см. константы).
# Адреса, которых на машине уже нет, не учитываются нигде — ни в строках, ни как «живой сосед».
# [$1] — готовый ответ _ga_edge_dns_json (edge-status спрашивает DNS один раз на кадр).
ga_edge_report() {
    local f live users dnsset dnsjs="${1:-}"
    f=$(ga_edge_history)
    # Истории ещё нет — строки всё равно по каждому адресу машины, с нулями: экранам нужен список адресов.
    [ -f "$f" ] || f=/dev/null
    live=$(ga_edge_list | tr '\n' ' ')
    [ -n "${live// /}" ] || return 0
    # Битый users.json (или config.json) — «не знаем, кто на каком адресе», а не «людей нет»: раньше отчёт
    # отвечал нулями, edge-status — «успешно», а вердикт unused у тика молча снимал прежнюю тревогу dark
    # (находка SR-37). Отказ — и тик ничего не меняет в памяти тревог.
    local umap=""
    if ! ga_capture umap ga_edge_users_map 2>/dev/null; then
        ga_err users_corrupt "$(t users_err_corrupt)"
        return 1
    fi
    users=$(printf '%s\n' "$umap" | tr '\n' ';')
    dnsset=$(_ga_edge_dns_set "$dnsjs")
    awk -F, -v strikes="$GA_EDGE_DARK_STRIKES" -v step="$GA_EDGE_TICK_SECONDS" -v gap="$GA_EDGE_GAP_SECONDS" \
        -v days="$GA_EDGE_HISTORY_DAYS" -v half="$GA_EDGE_BUSY_HALF_SECONDS" -v busy_share="$GA_EDGE_BUSY_SHARE" \
        -v usual_share="$GA_EDGE_USUAL_SHARE" -v min_users="$GA_EDGE_MIN_USERS" -v live="$live" -v users="$users" \
        -v dnsset="$dnsset" \
        -v now="$(_ga_edge_now)" '
        # Занят ли адрес dd дней назад в окне ±half вокруг времени lastt: -1 — день не в счёт (окно заходит
        # в нынешнюю тишину S или наблюдений меньше половины окна), 0 — не занят, 1 — занят.
        function dayv(ip, m, lastt, S, dd,    a, b, c, l, i, t) {
            a = lastt - dd * 86400 - half; b = lastt - dd * 86400 + half
            if (b >= S) return -1
            c = 0; l = 0
            for (i = 1; i <= m; i++) {
                t = order[ip, i]
                if (t < a) continue
                if (t > b) break
                c++; if (tick[ip, t] > 0) l++
            }
            if (c * step < half) return -1
            return (l * 100 >= c * busy_share) ? 1 : 0
        }
        BEGIN {
            na = split(live, L, " ")
            for (i = 1; i <= na; i++) if (L[i] != "") alive[L[i]] = 1
            nu = split(users, U, ";")
            for (i = 1; i <= nu; i++) {
                if (U[i] == "") continue
                split(U[i], kv, "\t"); ucnt[kv[1]] = kv[2] + 0
            }
            # Endpoint — домен: адрес выбирает DNS (несколько A-записей, как в goTelegram), и доменный
            # пользователь может прийти на любой адрес ИЗ A-ЗАПИСЕЙ. Адрес, которого в DNS нет, по домену
            # не достаётся никому: считать на нём доменных пользователей значило бы ждать от него трафика
            # и поднимать ложную тревогу «замолчал» (в goTelegram так и было до 2.10.30). DNS не знаем —
            # считаем на каждом, как раньше. Прибавляем, а не заменяем: у адреса могут быть и свои
            # пользователи (адрес вписан в ключ), раньше доменные их затирали.
            # «-» — домен сюда не ведёт вовсе (или записей нет): доменных пользователей нет нигде.
            nd = split(dnsset, D, " ")
            for (i = 1; i <= nd; i++) if (D[i] != "" && D[i] != "-") indns[D[i]] = 1
            if (("?" in ucnt) && dnsset != "-") for (a in alive) if (nd == 0 || (a in indns)) ucnt[a] += ucnt["?"]
        }
        NR == 1 { next }
        {
            ts = $1 + 0; ip = $2; p = $4 + 0; bb = $5 + 0; hb = (NF >= 5 && $5 != "")
            if (!(ip in alive)) next
            k = ip SUBSEP $3
            if (k in last) {
                d = p - last[k]; if (d < 0) d = p          # правило пересоздано — счёт с нуля
                # Байты считаются только между двумя строками С байтами. Первая строка нового вида после
                # строк прежней версии (без байтов) — не прирост, а накопленный с создания правила счётчик:
                # правила переживают обновление, и раньше он весь ложился в один тик — «трафик по адресам»
                # сутки показывал десятки ГБ (находка UP-3). Такую строку берём только точкой отсчёта.
                if (hadb[k] && hb) { db = bb - lastb[k]; if (db < 0) db = bb } else db = 0
                if (!((ip, ts) in seen)) { seen[ip, ts] = 1; n[ip]++; order[ip, n[ip]] = ts }
                tick[ip, ts] += d
                btick[ip, ts] += db
            }
            last[k] = p; lastb[k] = bb; hadb[k] = hb
        }
        END {
            W = strikes * step
            # Хоть один адрес принимал в последний тик? Нет — тихо у всех прямо сейчас, и у всех молчащих
            # адресов вердикт один: «тихо у всех адресов». Раньше адрес, замолчавший меньше 20 минут назад,
            # оставался «принимает» строкой выше «тихо у всех адресов», хотя за 15 минут у всех был ноль
            # (находка NC6-10 критика-новичка).
            anyrecent = 0
            for (ip in n) { lastd[ip] = tick[ip, order[ip, n[ip]]]; if (lastd[ip] > 0) anyrecent = 1 }
            for (ip in alive) {
                u = (ip in ucnt) ? ucnt[ip] : 0
                if (!(ip in n)) { printf "%s\t0\t0\t%s\t%d\t0\t0\t0\t0\t0\t0\t0\n", ip, (u > 0 ? (anyrecent ? "quiet" : "quiet-all") : "unused"), u; continue }
                m = n[ip]; lastt = order[ip, m]
                anylive = 0; day = 0; h1 = 0; m15 = 0; bday = 0; bh1 = 0; bm15 = 0
                for (i = 1; i <= m; i++) {
                    t = order[ip, i]
                    if (tick[ip, t] > 0) anylive = 1
                    if (t >= now - 86400) { day += tick[ip, t]; bday += btick[ip, t] }
                    if (t > now - 3600) { h1 += tick[ip, t]; bh1 += btick[ip, t] }
                    if (t > now - 900) { m15 += tick[ip, t]; bm15 += btick[ip, t] }
                }
                lr = 0
                for (i = m; i > 0; i--) { if (tick[ip, order[ip, i]] > 0) lr++; else break }
                S = 0; silent = 0
                if (lr == 0) {
                    S = lastt
                    for (i = m; i > 0; i--) {
                        t = order[ip, i]
                        if (tick[ip, t] > 0) break
                        if (i < m && order[ip, i + 1] - t > gap) break
                        S = t
                    }
                    silent = lastt - S + step
                }
                usual = 0
                if (lr == 0 && silent >= W) {
                    cov = 0; bus = 0
                    for (dd = 1; dd <= days; dd++) {
                        v = dayv(ip, m, lastt, S, dd)
                        if (v < 0) continue
                        cov++; bus += v
                    }
                    # Тот же день недели: тишина неделю назад прощает тишину сегодня, если и две недели назад
                    # в это время не было занято (праздник неделю назад не глушит блокировку); занято и неделю,
                    # и две недели назад — привычка, даже когда выходные последней недели тянут долю вниз.
                    w1 = dayv(ip, m, lastt, S, 7); w2 = dayv(ip, m, lastt, S, 14)
                    weekly_quiet = (w1 == 0 && w2 != 1) ? 1 : 0
                    weekly_busy = (w1 == 1 && w2 == 1) ? 1 : 0
                    usual = (!weekly_quiet && ((cov >= 2 && bus * 100 >= cov * usual_share) || weekly_busy)) ? 1 : 0
                }
                # Молчащий адрес: сосед с пакетами в последний тик есть тогда и только тогда, когда anyrecent.
                if (u == 0)                              st = "unused"
                else if (lr > 0)                         st = "ok"
                else if (!anyrecent)                     st = "quiet-all"
                else if (!anylive)                       st = "quiet"
                else if (silent < W)                     st = "ok"
                else if (!usual)                         st = "quiet"
                else if (u < min_users)                  st = "quiet"
                else                                     st = "dark"
                printf "%s\t%d\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%.0f\t%.0f\t%.0f\n", ip, lastd[ip], day, st, u, (lr == 0 ? S : 0), lr, m15, h1, bm15, bh1, bday
            }
        }' "$f" | sort
}

# ga_edge_reach_ip <основной адрес> → адрес, на который к машине реально приходят: основной, если адрес у
# машины один или сторож видит на нём входящие (вердикт ok); иначе — первый адрес с вердиктом ok; тихо у всех
# прямо сейчас (quiet-all, ни одного ok) — адрес, принявший больше всех пакетов за последний час; данных
# нет — основной. Тот же выбор, что у панели (tunnel_host): на машине с несколькими адресами команда
# SSH-туннеля к панели в SSH-меню вела на исходящий адрес, который входящих не принимает (находка PUI-25).
ga_edge_reach_ip() {
    local main="${1:-}" rows alt
    rows=$(ga_edge_report "" 2>/dev/null) || rows=""
    if [ "$(printf '%s\n' "$rows" | grep -c .)" -ge 2 ] \
       && ! printf '%s\n' "$rows" | awk -F'\t' -v m="$main" '$1 == m && $4 == "ok" { f = 1 } END { exit !f }'; then
        alt=$(printf '%s\n' "$rows" | awk -F'\t' '$4 == "ok" { print $1; exit }')
        # С NC6-10 короткая тишина у всех сразу — уже не «ok», а «тихо у всех»: тогда — кто принимал за час (9-е поле)
        [ -n "$alt" ] || alt=$(printf '%s\n' "$rows" | awk -F'\t' '$9 + 0 > best { best = $9 + 0; ip = $1 } END { if (best > 0) print ip }')
        if [ -n "$alt" ]; then printf '%s' "$alt"; return 0; fi
    fi
    printf '%s' "$main"
}

# Сводка для моста (edge-status) — бот, панель, MCP: строка на каждый внешний адрес машины.
# → {count, domain_endpoint, dns, ips: [{ip, verdict, users, packets_15m, packets_1h, packets_day,
#     bytes_15m, bytes_1h, bytes_day, silent_since, in_dns}]} — байты: входящий трафик клиентов на адрес.
# dns — A-записи домена из ключей (ga_site_dns_state) или null, если ключи на IP или DNS не спросить;
# in_dns — адрес есть в A-записях этого домена (null — не знаем).
ga_edge_status_json() {
    local rows common dom=false dns
    common=$(_ga_edge_common_endpoint)
    if [ -n "$common" ] && ! _valid_ip "$common"; then dom=true; fi
    # DNS — один раз на весь ответ: и отчёту, и полю dns (раньше за кадр спрашивали дважды)
    dns=$(_ga_edge_dns_json) || dns=""
    # jq 1.6 возвращает успех на пустом вводе даже с -e: проверяем один объект через -s.
    jq -es 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 <<<"$dns" || dns=null
    # В текущей оболочке: отказ отчёта (битый users.json — SR-37) — отказ ответа с кодом, а не «успешно» с нулями.
    ga_capture rows ga_edge_report "$([ "$dns" = null ] || printf '%s' "$dns")" 2>/dev/null || return 1
    jq -cn --arg rows "$rows" --argjson dom "$dom" --argjson dns "$dns" '
        [$rows | split("\n")[] | select(length > 0) | split("\t")
         | {ip: .[0], verdict: .[3], users: (.[4] | tonumber),
            packets_15m: ((.[7] // "0") | tonumber), packets_1h: ((.[8] // "0") | tonumber),
            packets_day: (.[2] | tonumber),
            bytes_15m: ((.[9] // "0") | tonumber), bytes_1h: ((.[10] // "0") | tonumber),
            bytes_day: ((.[11] // "0") | tonumber),
            silent_since: (if (.[5] // "0") == "0" then "" else (.[5] | tonumber | todate) end)}
         | .ip as $ip
         | .in_dns = (if $dns == null or $dns.state == "unknown" then null
                      else ($dns.a | any(. == $ip)) end)]
        | {count: length, domain_endpoint: $dom,
           dns: (if $dns == null then null else {domain: $dns.domain, state: $dns.state, a: $dns.a, foreign: $dns.foreign,
                                                cloudflare: ($dns.cloudflare // false)} end),
           ips: .}'
}

_ga_edge_iso() {
    local ts="${1:-0}"
    [[ "$ts" =~ ^[0-9]+$ ]] && [ "$ts" -gt 0 ] || return 0
    date -u -d "@$ts" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$ts" +%Y-%m-%dT%H:%M:%SZ
}

# Память тревог — в state/, а не в /run: /run чистится при перезагрузке, и тёмный адрес будил бы
# владельца после каждого включения сервера.
_ga_edge_alerts_doc() {
    local cur
    cur=$(cat "$(ga_edge_alerts_file)" 2>/dev/null)
    # Пустой или битый файл — пустая память: иначе он таким и оставался, а тревога шла бы каждый тик.
    printf '%s' "$cur" | jq -es 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 || cur='{}'
    printf '%s' "$cur"
}
# «состояние<TAB>когда сказали<TAB>тишина с<TAB>объявлено»
_ga_edge_alert_get() {
    _ga_edge_alerts_doc | jq -r --arg ip "${1:-}" \
        '.[$ip] // empty | "\(.state // "")\t\(.notified // 0)\t\(.since // 0)\t\(.announced // false)"' 2>/dev/null
}
# _ga_edge_alert_write <аргументы jq> — атомарно; код 1, если записать не удалось.
_ga_edge_alert_write() {
    local f tmp doc
    f=$(ga_edge_alerts_file)
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
    doc=$(_ga_edge_alerts_doc | jq -c "$@" 2>/dev/null) || return 1
    [ -n "$doc" ] || return 1
    tmp=$(mktemp "${f}.XXXXXX" 2>/dev/null) || return 1
    if printf '%s\n' "$doc" 2>/dev/null >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$f"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}
_ga_edge_alert_set() {   # <адрес> <состояние> <когда сказали> <тишина с> <объявлено true|false>
    _ga_edge_alert_write --arg ip "$1" --arg st "$2" --argjson n "${3:-0}" --argjson s "${4:-0}" \
        --argjson a "${5:-false}" '.[$ip] = {state: $st, notified: $n, since: $s, announced: $a}'
}
_ga_edge_alert_prune() {   # <адреса машины…> — память о снятых с машины адресах не копится
    local keep
    keep=$(printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(. != ""))') || return 1
    _ga_edge_alert_write --argjson keep "$keep" 'with_entries(select(.key as $k | $keep | index($k)))'
}
_ga_edge_notify_dark() {   # <адрес> <пользователей> <тишина с> <напоминание true|false>
    ga_notify edge_ip_dark "$(jq -cn --arg ip "$1" --argjson u "${2:-0}" --arg since "$(_ga_edge_iso "$3")" \
        --argjson r "${4:-false}" '{ip: $ip, users: $u, since: $since} + (if $r then {reminder: true} else {} end)')"
}

# Тик сторожа: снимок и тревоги (docs/EDGEIPS.md §3.2).
#   edge_ip_dark — на переход в «dark», но по одному адресу не чаще раза в сутки: эпизод мигающего
#     адреса внутри суток записывается молча и объявляется, если тянется дольше; напоминание о всё
#     ещё тёмном — раз в сутки;
#   edge_ip_back — после GA_EDGE_BACK_TICKS живых тиков подряд и только об объявленном эпизоде;
#   адрес, с которого всех пересадили (unused), тревогу снимает молча.
# Память пишется ДО отправки: не записалась — не шлём, иначе при полном диске тревога шла бы каждый тик.
# → число отправленных событий.
ga_edge_tick() {
    local ip _recent _day verdict users since live_run _m15 _h1 events=0 now prev notified psince announced alive=""
    # Один адрес у машины — сторожить нечего: правила учёта не ставятся, история не копится.
    [ "$(ga_edge_list 2>/dev/null | grep -c .)" -ge 2 ] || { printf 0; return 0; }
    ga_edge_sample || { printf 0; return 0; }
    now=$(_ga_edge_now)
    while IFS=$'\t' read -r ip _recent _day verdict users since live_run _m15 _h1; do
        [ -n "$ip" ] || continue
        alive="$alive $ip"
        prev=""; notified=0; psince=0; announced=false
        IFS=$'\t' read -r prev notified psince announced <<<"$(_ga_edge_alert_get "$ip")"
        [[ "$notified" =~ ^[0-9]+$ ]] || notified=0
        [[ "$psince" =~ ^[0-9]+$ ]] || psince=0
        [ "$announced" = true ] || announced=false
        case "$verdict" in
            dark)
                if [ "$prev" != dark ]; then
                    if [ $(( now - notified )) -ge "$GA_EDGE_REMIND_SECONDS" ]; then
                        _ga_edge_alert_set "$ip" dark "$now" "$since" true || continue
                        _ga_edge_notify_dark "$ip" "$users" "$since" false && events=$((events + 1))
                    else
                        _ga_edge_alert_set "$ip" dark "$notified" "$since" false || continue
                    fi
                elif [ $(( now - notified )) -ge "$GA_EDGE_REMIND_SECONDS" ]; then
                    _ga_edge_alert_set "$ip" dark "$now" "$psince" true || continue
                    _ga_edge_notify_dark "$ip" "$users" "$psince" "$announced" && events=$((events + 1))
                fi ;;
            ok)
                if [ "$prev" = dark ] && [ "${live_run:-0}" -ge "$GA_EDGE_BACK_TICKS" ]; then
                    _ga_edge_alert_set "$ip" ok "$notified" 0 false || continue
                    if [ "$announced" = true ]; then
                        ga_notify edge_ip_back "$(jq -cn --arg ip "$ip" --arg since "$(_ga_edge_iso "$psince")" \
                            '{ip: $ip, since: $since}')" && events=$((events + 1))
                    fi
                fi ;;
            unused)
                [ "$prev" = dark ] && _ga_edge_alert_set "$ip" ok "$notified" 0 false ;;
        esac
    done < <(ga_edge_report)
    if [ -n "${alive// /}" ]; then
        # shellcheck disable=SC2086 # адреса через пробел — отдельными аргументами
        _ga_edge_alert_prune $alive
    fi
    printf '%s' "$events"
}
