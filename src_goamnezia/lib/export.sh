#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# goAmnezia pro — lib/export.sh: выдача ключей во всех форматах (контракт §4.6)
#
# Два стиля везде (решение владельца §10.5): классический .conf AmneziaWG с QR и
# «стиль Amnezia» — ключ vpn:// плюс QR в формате приложения. Сам текст .conf и
# кодек vpn:// делает lib/awgkeys.py (один код для SSH, бота и панели), здесь —
# сборка входных данных из config.json + users.json и обёртка над qrencode.
#
# QR для vpn:// — не картинка со строкой vpn://: приложение Amnezia сканирует
# набор чанков (awgkeys.py qr-chunks), по одному PNG на чанк (01.png, 02.png…).
# QR для .conf — обычный текст, его читают клиенты AmneziaWG и роутеры.
#
# Приватный ключ клиента отдаём только здесь (правило серии §0.7) — этот модуль
# и есть «user-key». В stdout — только результат; сообщения — в stderr.
# ══════════════════════════════════════════════════════════════════════════════

GA_EXPORT_DNS_DEFAULT='["1.1.1.1","1.0.0.1"]'
GA_EXPORT_MTU_DEFAULT=1280
GA_EXPORT_QR_SCALE=6

# Признак «ключ выдан выключенному»: 1 — у человека `.enabled == false` или у
# его пира `.active == false`. Ставит ga_export_peer, читают export_bundle (в
# ответ моста уходит полем disabled) и SSH-меню.
#
# Почему предупреждаем, а не отказываем. Ключ выключенного нужен заранее:
# человека заводят на завтра, лимит выбран и будет поднят, срок продлят — и
# требовать «сначала включите» значит ломать законный порядок работы. Но и
# молчать нельзя: владелец отдаёт QR, человек не подключается, а причина не
# видна ни на одном экране — пир в контейнере просто снят. Поэтому выдаём и
# ГОВОРИМ, одинаково во всех трёх интерфейсах.
GA_EXPORT_DISABLED=0
# Страж от повторов ВНУТРИ одной выдачи: export_bundle зовёт ga_export_peer,
# потом export_conf, потом export_vpn — три одинаковые строки подряд человек
# читает как три разные беды. Приём тот же, что у реентрантного замка
# (GA_CONFIG_LOCK_HELD): внешний вызов объявляет флаг через `local`, и он
# снимается сам при выходе, каким бы этот выход ни был. Между РАЗНЫМИ выдачами
# флага нет — второй показ ключа в той же сессии предупредит снова, и должен.
GA_EXPORT_SAID=0

# ── Помощники ─────────────────────────────────────────────────────────────────

# Домен сервера для Endpoint по умолчанию — только в режиме 3, Pro: там AmneziaWG стоит на UDP/443 под
# доменом, рядом с сайтом (решение владельца 17.09.2026: «где участвует домен именно на 443 порту с
# амнезией, т.е. 3 режим — писался домен»). В «VPN и сайт» (lite_site) VPN живёт на своём порту в стороне
# от домена, и в ключах, как прежде, IP; домен от прежнего режима (ушли в Lite, запись осталась) — тоже
# IP. Сертификат — как у ga_site_cert_kind (lib/website.sh): самоподписанный стоит, пока домен не
# разошёлся, и верить домену тогда нельзя; пустое поле старых установок читается как Let's Encrypt. Без
# похода в сеть: функцию зовут сборка ключа, сторож адресов и status. Пусто и код 1 — такого домена нет.
ga_export_pro_domain() {
    local mode cert d
    mode=$(ga_config_get ".mode" 2>/dev/null)
    [ "$mode" = pro ] || return 1
    cert=$(ga_config_get ".site.cert" 2>/dev/null)
    [ "$cert" = selfsigned ] && return 1
    d=$(ga_config_get ".domain" 2>/dev/null)
    [ -n "$d" ] && [ "$d" != "null" ] || return 1
    # Адрес в поле домена — не домен: IP в ключ и так ставит server_ip.
    if _valid_ip "$d" || ! ga_valid_host "$d"; then
        return 1
    fi
    printf '%s\n' "$d"
}

# Откуда общий Endpoint ключей (без пользователя): host — вписан владельцем (endpoint_host), domain —
# домен сервера по умолчанию (ga_export_pro_domain), ip — адрес сервера. По нему экраны решают, что
# предложить, а свой адрес пользователя — уступать ли домену.
ga_export_endpoint_source() {
    local h
    h=$(ga_config_get ".endpoint_host" 2>/dev/null)
    if [ -n "$h" ] && [ "$h" != "null" ]; then
        echo host
    elif ga_export_pro_domain >/dev/null 2>&1; then
        echo domain
    else
        echo ip
    fi
}

# Хост в Endpoint: endpoint_host, если его вписал владелец; иначе домен сервера в режиме Pro
# (ga_export_pro_domain); иначе IP сервера из config.json, иначе определяем снаружи. Пусто в stdout
# и код 1 — адреса нет. Домен по умолчанию — с 17.09.2026: пустое поле давало IP и в Pro, и файл,
# скачанный для роутера на сервере «VPN на 443 под доменом», приходил с IP.
#
# Почему здесь нужен код возврата, а не просто непустая строка. get_server_ip
# по договору при неудаче ПЕЧАТАЕТ `0.0.0.0` и возвращает единицу. Код тут
# выбрасывался, а `0.0.0.0` — строка непустая, и страж выдачи её пропускал:
# человек получал файл, QR и ссылку, которые никогда не соединятся, и причину
# искал в параметрах обфускации. Значение из конфига тоже проверяем по
# ЗНАЧЕНИЮ одной функцией на весь продукт (ga_valid_host, контракт §0.8): в
# config.json мог осесть «0.0.0.0» от неудачного определения в прошлой версии.
#
# С именем пользователя — ещё и его собственный адрес сервера (endpoint_ip, несколько адресов
# сервера, docs/EDGEIPS.md §3.1). Он действует, когда общий Endpoint — IP или домен сервера по
# умолчанию: домен по умолчанию никто не выбирал, а свой адрес пользователю владелец задал сам. Домен,
# вписанный в endpoint_host, побеждает: адрес выбирает DNS. Адрес, которого на машине больше нет, —
# код 2 и пустой stdout: ключ с ним не соединился бы никогда. Слова об ошибке пишет вызывающий: здесь
# подоболочка, и код ошибки в ней потерялся бы.
ga_export_endpoint_host() {
    local name="${1:-}" h rc own addrs pinned=0
    h=$(ga_config_get ".endpoint_host" 2>/dev/null)
    if [ -n "$h" ] && [ "$h" != "null" ]; then
        pinned=1
    else
        h=$(ga_export_pro_domain 2>/dev/null) || h=""
    fi
    [ -n "$h" ] || h=$(ga_config_get ".server_ip" 2>/dev/null)
    if [ -z "$h" ] || [ "$h" = "null" ]; then
        if [ -n "${GA_EXPORT_SERVER_IP+x}" ]; then
            # Адрес вызывающий уже спросил сам (status, экран адреса в SSH): второй поход в сеть на сервере без
            # выхода наружу стоил бы ещё одного таймаута на каждом экране бота и панели.
            h="$GA_EXPORT_SERVER_IP"
        else
            h=$(get_server_ip 2>/dev/null); rc=$?
            [ "$rc" = 0 ] || h=""
        fi
    fi
    # 0.0.0.0 — «адрес не определён» в любой записи, откуда бы он ни пришёл.
    if [ -z "$h" ] || [ "$h" = "0.0.0.0" ] || ! ga_valid_host "$h"; then
        return 1
    fi
    if [ -n "$name" ] && { _valid_ip "$h" || [ "$pinned" = 0 ]; }; then
        own=$(ga_users_get "$name" 2>/dev/null | jq -r '.endpoint_ip // ""' 2>/dev/null)
        if [ -n "$own" ]; then
            # Мусор в поле (правка файла руками, 0.0.0.0) — тот же отказ, что у пропавшего адреса: ключ
            # с ним не соединился бы.
            if ! _valid_ip "$own" || [ "$own" = "0.0.0.0" ]; then
                return 2
            fi
            # Список адресов машины не прочитался (нет ip, чужая среда) — выдачу не блокируем:
            # отказ по догадке хуже ключа, который владелец сам проверит.
            if type ga_edge_list >/dev/null 2>&1; then
                addrs=$(ga_edge_list 2>/dev/null)
                if [ -n "$addrs" ] && ! grep -qxF "$own" <<<"$addrs"; then
                    return 2
                fi
            fi
            h="$own"
        fi
    fi
    echo "$h"
}

# ga_export_endpoint_host_gone — вписанный в endpoint_host IP больше не на этой машине: rc 0 — пропал.
# Ключи с ним не соединятся, а выдача об этом молчала (находка SR-45: после переезда вписанный адрес старой
# машины оставался в ключах, пока его не снимет часовая проверка). Выдачу не блокируем — чужой адрес бывает
# законным (проброс, балансировщик: такой записан с отметкой endpoint_host_foreign и пропавшим не считается);
# о пропавшем говорят status (endpoint_host_gone) и шапка меню. Адресов машины не узнать (NAT) — rc 1.
ga_export_endpoint_host_gone() {
    local h addrs
    h=$(ga_config_get ".endpoint_host" 2>/dev/null)
    [ -n "$h" ] && [ "$h" != null ] && _valid_ip "$h" || return 1
    [ "$(ga_config_get ".endpoint_host_foreign" 2>/dev/null)" = true ] && return 1
    type ga_edge_list >/dev/null 2>&1 || return 1
    addrs=$(ga_edge_list 2>/dev/null)
    [ -n "$addrs" ] || return 1
    addrs+=$'\n'"$(ga_config_get ".server_ip" 2>/dev/null)"
    ! grep -qxF -- "$h" <<<"$addrs"
}

# ── Ключ на другой адрес сервера (разовый Endpoint, docs/EDGEIPS.md §3.4) ─────
#
# У машины бывает несколько внешних адресов. Владелец может выдать ТОТ ЖЕ ключ (та же пара, тот же порт
# профиля) с другим адресом сервера внутри — для человека, у которого не открывается домен или молчит
# основной адрес. За пользователем при этом ничего не сохраняется: закрепить адрес — отдельная функция
# (endpoint_ip, users_set_endpoint_ip). Без адреса выдача остаётся байт в байт прежней.

# ga_export_key_hosts — какие хосты можно вписать в ключ разово, по одному в строке, без похода в сеть:
# домены — только настроенные (endpoint_host, если там домен; домен Pro; домен сайта с Let's Encrypt),
# затем внешние IPv4 машины (ga_edge_list), адрес сервера из config.json и IP из endpoint_host.
# Произвольный хост не принимается: ключ на чужой адрес не соединится, а выглядит как настоящий.
ga_export_key_hosts() {
    local h d ip doms="" ips=""
    h=$(ga_config_get ".endpoint_host" 2>/dev/null)
    [ "$h" = "null" ] && h=""
    if [ -n "$h" ]; then
        if _valid_ip "$h"; then
            ips+="$h"$'\n'
        elif ga_valid_host "$h"; then
            doms+="$h"$'\n'
        fi
    fi
    d=$(ga_export_pro_domain 2>/dev/null) && [ -n "$d" ] && doms+="$d"$'\n'
    if type ga_site_domain_ready >/dev/null 2>&1 && ga_site_domain_ready 2>/dev/null; then
        d=$(ga_config_get ".domain" 2>/dev/null)
        if [ -n "$d" ] && [ "$d" != "null" ] && ! _valid_ip "$d" && ga_valid_host "$d"; then
            doms+="$d"$'\n'
        fi
    fi
    # Адрес сервера из config.json — первым среди адресов (его человек знает как «адрес сервера»), затем
    # остальные адреса машины.
    ip=$(ga_config_get ".server_ip" 2>/dev/null)
    [ -n "$ip" ] && [ "$ip" != "null" ] && ips+="$ip"$'\n'
    if type ga_edge_list >/dev/null 2>&1; then
        ips+="$(ga_edge_list 2>/dev/null)"$'\n'
    fi
    printf '%s' "$doms" | tr 'A-Z' 'a-z' | sed 's/\.$//' | awk 'NF && !seen[$0]++'
    while IFS= read -r ip; do
        [ -n "$ip" ] && [ "$ip" != "0.0.0.0" ] && _valid_ip "$ip" && printf '%s\n' "$ip"
    done <<<"$ips" | awk '!seen[$0]++'
}

# ga_export_key_host_check <хост> — годится ли хост для разовой выдачи; в stdout — хост в нижнем регистре.
# Отказы (код 2, слова в GA_ERR_*): invalid_ip — похоже на IPv4, но адрес негодный или 0.0.0.0;
# addresses_unknown — машина не видит своих внешних адресов (NAT), а спросили не известный адрес;
# address_not_here — такого адреса или домена у сервера нет (в сообщении — какие есть).
ga_export_key_host_check() {
    local raw="${1:-}" host allowed list
    host=$(printf '%s' "$raw" | tr 'A-Z' 'a-z')
    host="${host%.}"
    if [[ "$host" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
        if ! _valid_ip "$host" || [ "$host" = "0.0.0.0" ]; then
            ga_err invalid_ip "$(tf export_err_key_host_invalid "$raw")" 2
            return 2
        fi
    elif [ -z "$host" ] || ! ga_valid_host "$host"; then
        ga_err invalid_ip "$(tf export_err_key_host_invalid "$raw")" 2
        return 2
    fi
    allowed=$(ga_export_key_hosts)
    if grep -qxF "$host" <<<"$allowed"; then
        printf '%s\n' "$host"
        return 0
    fi
    list=$(awk 'NF' <<<"$allowed" | paste -sd, - | sed 's/,/, /g')
    if _valid_ip "$host" && { ! type ga_edge_list >/dev/null 2>&1 || [ -z "$(ga_edge_list 2>/dev/null)" ]; }; then
        ga_err addresses_unknown "$(tf export_err_key_host_unknown "$host" "${list:-—}")" 2
        return 2
    fi
    ga_err address_not_here "$(tf export_err_key_host_not_here "$host" "${list:-—}")" 2
    return 2
}

# _ga_export_host_for <имя> [разовый хост] — хост для Endpoint этой выдачи в stdout. Разовый — проверенный
# ga_export_key_host_check; без него — как всегда (ga_export_endpoint_host, с адресом пользователя).
# Коды: как у ga_export_endpoint_host (1 — адреса нет, 2 — закреплённый адрес пропал) и 2 с GA_ERR_* у
# негодного разового.
_ga_export_host_for() {
    local name="$1" ep="${2:-}"
    if [ -n "$ep" ]; then
        ga_export_key_host_check "$ep"
        return $?
    fi
    ga_export_endpoint_host "$name"
}

# DNS для клиентского конфига. Каждый адрес проверяется по ЗНАЧЕНИЮ октетов
# (_valid_ip, lib/common.sh), а не по виду: в config.json мог осесть мусор от
# старой версии или от правки файла руками, и «DNS = 999.999.999.999» в ключе
# выглядит как поломка туннеля, причину которой ищут где угодно, только не в
# строке DNS. Негодный адрес выбрасываем и говорим об этом в stderr — stdout у
# модуля занят результатом.
ga_export_dns_json() {
    local d ip kept='[]'
    d=$(ga_config_get ".client_dns" 2>/dev/null | jq -c 'if type == "array" and length > 0 then . else empty end' 2>/dev/null)
    if [ -n "$d" ]; then
        while IFS= read -r ip; do
            [ -n "$ip" ] || continue
            if _valid_ip "$ip"; then
                kept=$(jq -c --arg v "$ip" '. + [$v]' <<<"$kept") || kept='[]'
            else
                log_warning "$(tf export_warn_dns "$ip")"
            fi
        done < <(jq -r '.[]? | tostring' <<<"$d" 2>/dev/null)
        [ "$kept" = "[]" ] || { echo "$kept"; return 0; }
    fi
    echo "$GA_EXPORT_DNS_DEFAULT"
}

# Минимальная версия приложения Amnezia для линейки (по контракту §4.6; для
# 1.0 — первая версия с AmneziaWG вообще). 1.5 и 2.0 — первые СТАБИЛЬНЫЕ выпуски, как в lib/clients.json (сверен
# 25.09.2026; 4.8.8.1 и 4.8.12.7 — предварительные): страница подключения и экраны говорят одно число (A-15).
ga_export_min_client() {
    case "$1" in
        1.0) echo "4.0.0" ;;
        1.5) echo "4.8.8.3" ;;
        2.0) echo "4.8.12.9" ;;
        3.1) echo "5.0.1.5" ;;
        *)   echo "" ;;
    esac
}

# Пир пользователя в профиле с приватным ключом (импортированные из приложения
# пользователи приватника не имеют — им доступна только ротация ключа).
ga_export_peer() {
    local name="$1" profile="$2" user peer priv
    ga_users_require "$name" || return $?
    ga_profile_check_installed "$profile" || return $?
    user=$(ga_users_get "$name")
    peer=$(jq -c --arg p "$profile" '.peers[$p] // empty' <<<"$user")
    if [ -z "$peer" ]; then
        ga_err peer_not_found "$(tf export_err_peer "$name" "$profile")" 3
        return 3
    fi
    priv=$(jq -r '.privkey // empty' <<<"$peer")
    if [ -z "$priv" ]; then
        ga_err no_private_key "$(tf export_err_no_privkey "$name" "$profile")" 3
        return 3
    fi
    # `.enabled == false` сравниваем ЯВНО: в jq `false // true` даёт true, и
    # выключенный человек выглядел бы включённым (тот же капкан уже обойдён в
    # списке пользователей SSH-меню и в lib/agents.sh).
    if [ "$(jq -r 'if (.enabled == false) then 1 else 0 end' <<<"$user" 2>/dev/null)" = 1 ] \
       || [ "$(jq -r 'if (.active == false) then 1 else 0 end' <<<"$peer" 2>/dev/null)" = 1 ]; then
        GA_EXPORT_DISABLED=1
        [ "${GA_EXPORT_SAID:-0}" = 1 ] || log_warning "$(tf export_warn_disabled "$name" "$profile")"
    else
        GA_EXPORT_DISABLED=0
    fi
    printf '%s' "$peer"
}

ga_export_qrencode_ok() {
    if ! command -v qrencode >/dev/null 2>&1; then
        ga_err qrencode_missing "$(t export_err_qrencode)" 3
        return 3
    fi
    return 0
}

# ── Форматы ───────────────────────────────────────────────────────────────────

# export_conf <имя> <профиль> → stdout текст .conf по ФАКТИЧЕСКОЙ линейке
# профиля (ga_profile_line, а не имя профиля): у подхваченного контейнера
# приложения линейка бывает старше той, что подразумевает идентификатор, и
# ключ, выданный не в той линейке, просто не соединится.
export_conf() {
    local name="$1" profile="$2" ep="${3:-}" peer line params pub port host host_rc=0 dns mtu input
    ga_capture peer ga_export_peer "$name" "$profile" || return $?
    line=$(ga_profile_line "$profile")
    params=$(ga_config_get ".profiles.$profile.params" | jq -c . 2>/dev/null)
    [ -n "$params" ] || params='{}'
    pub=$(ga_config_get ".profiles.$profile.server_pubkey")
    port=$(ga_profile_field "$profile" port)
    # Разовый адрес (третий аргумент) проверяется здесь же, в этой оболочке: отказ несёт свой код и слова
    # (address_not_here, invalid_ip), а подоболочка их потеряла бы.
    if [ -n "$ep" ]; then
        ga_capture host ga_export_key_host_check "$ep" || return $?
    else
        host=$(ga_export_endpoint_host "$name"); host_rc=$?
    fi
    dns=$(ga_export_dns_json)
    mtu=$(jq -r '.MTU // empty' <<<"$params")
    # Та же проверка, что у profile-mtu и profile-set-param: в ключ не должен
    # уехать MTU, который продукт задать не даёт. Не прошло — берём умолчание.
    ga_valid_mtu "$mtu" || mtu="$GA_EXPORT_MTU_DEFAULT"
    # Адрес — отдельным отказом со своим кодом: «профиль неполный» отправляет
    # человека проверять профиль, а дело в том, что сервер не знает своего
    # адреса. Молчать здесь нельзя — ключ без адреса не соединится никогда.
    if [ "$host_rc" = 2 ]; then
        ga_err address_gone "$(tf export_err_address_gone "$(ga_users_get "$name" | jq -r '.endpoint_ip // ""')" "$name")"
        return 1
    fi
    if [ -z "$host" ]; then
        ga_err endpoint_unknown "$(t export_err_endpoint)"
        return 1
    fi
    if [ -z "$pub" ] || ! [[ "$port" =~ ^[0-9]+$ ]]; then
        ga_err profile_incomplete "$(tf export_err_profile "$profile")"
        return 1
    fi
    # Пир с приватным ключом и PSK — через stdin, а не аргументом jq: argv виден каждому локальному
    # пользователю в /proc/*/cmdline (находка SR-17).
    input=$(printf '%s' "$peer" | jq -c --argjson params "$params" --arg pub "$pub" \
        --arg host "$host" --argjson port "$port" --argjson dns "$dns" --argjson mtu "$mtu" \
        '. as $peer | {params: $params, client: {ip: $peer.ip, privkey: $peer.privkey, psk: $peer.psk},
          server: {pubkey: $pub, endpoint_host: $host, port: $port}, dns: $dns, mtu: $mtu}') || return 1
    local conf
    conf=$(printf '%s' "$input" | ga_awgkeys conf --line "$line") || {
        ga_err conf_failed "$(tf export_err_conf "$name" "$profile")"; return 1; }
    if [ -z "$conf" ]; then
        ga_err conf_failed "$(tf export_err_conf "$name" "$profile")"
        return 1
    fi
    printf '%s\n' "$conf"
}

# export_vpn <имя> <профиль> → stdout vpn://… (ключ приложения Amnezia, вариант
# «подключение»: один контейнер, без SSH-учётки).
export_vpn() {
    local name="$1" profile="$2" ep="${3:-}" conf container line params host port dns subnet label desc input
    ga_capture conf export_conf "$name" "$profile" "$ep" || return $?
    container=$(ga_profile_field "$profile" container)
    line=$(ga_profile_line "$profile")
    params=$(ga_config_get ".profiles.$profile.params" | jq -c . 2>/dev/null)
    [ -n "$params" ] || params='{}'
    # Тот же хост, что попал в .conf выше: export_conf его уже проверил.
    host=$(_ga_export_host_for "$name" "$ep" 2>/dev/null)
    port=$(ga_profile_field "$profile" port)
    dns=$(ga_export_dns_json)
    subnet=$(ga_profile_field "$profile" subnet)
    label=$(ga_users_get "$name" | jq -r '.label // .name')
    # С разовым адресом — адрес и в подписи: в приложении Amnezia записи одного человека на разные адреса
    # иначе назывались бы одинаково.
    if [ -n "$ep" ]; then
        desc=$(tf export_vpn_description_at "$label" "$line" "$host")
    else
        desc=$(tf export_vpn_description "$label" "$line")
    fi
    # Текст .conf с приватным ключом — окружением, не аргументом jq (SR-17).
    input=$(GA_S_CONF="$conf" jq -cn --arg container "$container" --arg line "$line" --argjson params "$params" \
        --arg desc "$desc" --arg host "$host" --argjson port "$port" \
        --argjson dns "$dns" --arg subnet "$subnet" \
        '{container: $container, line: $line, params: $params, conf_text: $ENV.GA_S_CONF, description: $desc,
          hostName: $host, port: $port, dns: $dns, subnet: $subnet}') || return 1
    local vpn
    vpn=$(printf '%s' "$input" | ga_awgkeys vpn-encode | tr -d '[:space:]') || {
        ga_err vpn_failed "$(tf export_err_vpn "$name" "$profile")"; return 1; }
    if [[ "$vpn" != vpn://* ]]; then
        ga_err vpn_failed "$(tf export_err_vpn "$name" "$profile")"
        return 1
    fi
    printf '%s\n' "$vpn"
}

# export_qr_png <текст> <файл> — PNG через qrencode, уровень коррекции L
# (у .conf ~700 символов, у чанка vpn:// ~1100 — выше L картинка не читается
# с экрана телефона). Текст — через stdin: аргумент такой длины режет шелл.
export_qr_png() {
    local text="$1" out="$2"
    ga_export_qrencode_ok || return $?
    if [ -z "$text" ] || [ -z "$out" ]; then
        ga_err invalid_argument "$(tf export_err_qr "$out")" 2
        return 2
    fi
    if ! (umask 077; printf '%s' "$text" | qrencode -o "$out" -l L -t PNG -s "$GA_EXPORT_QR_SCALE" -m 2 2>/dev/null); then
        ga_err qr_failed "$(tf export_err_qr "$out")"
        return 1
    fi
    return 0
}

# export_qr_vpn_pngs <имя> <профиль> <каталог> → PNG на чанк (01.png, 02.png…);
# stdout — пути файлов по одному в строке.
export_qr_vpn_pngs() {
    local name="$1" profile="$2" outdir="$3" ep="${4:-}" vpn chunks n i chunk file
    ga_export_qrencode_ok || return $?
    if [ -z "$outdir" ]; then
        ga_err invalid_argument "$(tf export_err_outdir "$outdir")" 2
        return 2
    fi
    ga_capture vpn export_vpn "$name" "$profile" "$ep" || return $?
    # Ссылка — через stdin: в ней приватный ключ клиента, а argv виден любому локальному пользователю
    # в /proc/*/cmdline (находка SR-17).
    chunks=$(printf '%s' "$vpn" | ga_awgkeys qr-chunks -) || { ga_err chunks_failed "$(t export_err_chunks)"; return 1; }
    n=$(jq -r 'if type == "array" then length else 0 end' <<<"$chunks" 2>/dev/null)
    if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -eq 0 ]; then
        ga_err chunks_failed "$(t export_err_chunks)"
        return 1
    fi
    mkdir -p "$outdir" || { ga_err invalid_argument "$(tf export_err_outdir "$outdir")" 2; return 2; }
    chmod 700 "$outdir" 2>/dev/null
    for ((i = 0; i < n; i++)); do
        chunk=$(jq -r --argjson i "$i" '.[$i]' <<<"$chunks")
        file=$(printf '%s/%02d.png' "$outdir" $((i + 1)))
        export_qr_png "$chunk" "$file" || return $?
        printf '%s\n' "$file"
    done
}

# ga_export_audit_key <имя> <профиль> <формат> [разовый адрес] — выдача приватного ключа — событие журнала
# действий: кто, кому, какой профиль и формат, без самого ключа. Панель и MCP писали свои строки «call», а бот
# (главный путь выдачи, админов бывает несколько) и SSH-меню — ничего, и журнал не знал, что ключ выдан
# (находка SR-03). Кто — из GOAMNEZIA_WHO (бот передаёт bot:<id>, панель panel:<логин>).
ga_export_audit_key() {
    type ga_audit >/dev/null 2>&1 || return 0
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "user-key" "$1 profile=$2 format=$3${4:+ endpoint=$4}"
}

# export_bundle <имя> <профиль> <формат> → JSON {conf, vpn, qr_conf_png_b64,
# qr_vpn_png_b64: […], line, min_client, …, file_name}. file_name — имя файла .conf (ga_key_file_base, Н-2): одно
# для SSH, страницы, временной ссылки, подписки, панели и бота; не длиннее 15 знаков до «.conf» — AmneziaWG берёт из
# него имя туннеля. С разовым адресом — то же имя: адрес в имени файла сделал бы туннель длиннее. Формат — как в actions.json:
# conf | vpn | qr-conf | qr-vpn | all. Ненужные поля пустые, чтобы бот и панель
# разбирали один и тот же объект.
export_bundle() {
    local name="$1" profile="$2" format="${3:-all}" ep="${4:-}"
    local conf="" vpn="" qrc="" qrv='[]' line min tmp chunks n i chunk b64 rc=0 disabled=false
    local khost="" kport override=false fname=""
    # Объявляем локально: вложенные export_conf/export_vpn увидят флаг, а на
    # выходе из функции — любом, включая ранний return — он исчезнет сам.
    local GA_EXPORT_SAID=0
    case "$format" in
        conf|vpn|qr-conf|qr-vpn|all) ;;
        *)
            ga_err invalid_format "$(tf export_err_format "$format")" 2
            return 2 ;;
    esac
    ga_export_peer "$name" "$profile" >/dev/null || return $?
    # Признак снимаем сразу после проверки пира: дальше export_conf/export_vpn
    # позовут ga_export_peer ещё раз, и значение не изменится, но читать его
    # надо там, где оно точно уже выставлено. Сказано уже здесь — дальше молчим.
    [ "$GA_EXPORT_DISABLED" = 1 ] && disabled=true
    GA_EXPORT_SAID=1
    # Разовый адрес — одна проверка до сборки: отказ приходит своим кодом, а не «ключ не собрался».
    if [ -n "$ep" ]; then
        ga_capture khost ga_export_key_host_check "$ep" || return $?
        ep="$khost"
        override=true
    fi
    line=$(ga_profile_line "$profile")
    min=$(ga_export_min_client "$line")
    case "$format" in conf|qr-conf|all) ga_capture conf export_conf "$name" "$profile" "$ep" || return $? ;; esac
    case "$format" in vpn|qr-vpn|all) ga_capture vpn export_vpn "$name" "$profile" "$ep" || return $? ;; esac
    # Какой адрес в этом ключе — интерфейсы пишут его в подписи и имени файла.
    [ -n "$khost" ] || khost=$(ga_export_endpoint_host "$name" 2>/dev/null) || khost=""
    kport=$(ga_profile_field "$profile" port)
    type ga_key_file_base >/dev/null 2>&1 && fname=$(ga_key_file_base "$name" "$profile" 2>/dev/null)
    [ -n "$fname" ] && fname="${fname}.conf"
    case "$format" in
        qr-conf|qr-vpn|all)
            ga_export_qrencode_ok || return $?
            # QR — это тот же приватный ключ, только картинкой, и раскодировать
            # его можно любым телефоном. Каталог берём в памяти, а на выходе
            # затираем содержимое: rm снимает имя, а не блоки.
            tmp=$(mktemp -d "$(ga_secret_tmpdir)/.goamnezia-qr.XXXXXXXX") || return 1
            chmod 700 "$tmp"
            if [ "$format" != "qr-vpn" ] && [ -n "$conf" ]; then
                if export_qr_png "$conf" "$tmp/conf.png"; then
                    qrc=$(base64 <"$tmp/conf.png" | tr -d '\n')
                else
                    rc=1
                fi
            fi
            if [ "$rc" = 0 ] && [ "$format" != "qr-conf" ] && [ -n "$vpn" ]; then
                chunks=$(printf '%s' "$vpn" | ga_awgkeys qr-chunks -) || rc=1   # stdin, не argv (SR-17)
                n=$(jq -r 'if type == "array" then length else 0 end' <<<"${chunks:-[]}" 2>/dev/null)
                [[ "$n" =~ ^[0-9]+$ ]] || n=0
                for ((i = 0; i < n && rc == 0; i++)); do
                    chunk=$(jq -r --argjson i "$i" '.[$i]' <<<"$chunks")
                    if export_qr_png "$chunk" "$tmp/vpn-$i.png"; then
                        b64=$(base64 <"$tmp/vpn-$i.png" | tr -d '\n')
                        qrv=$(GA_S_B64="$b64" jq -c '. + [$ENV.GA_S_B64]' <<<"$qrv")   # картинка ключа — не в argv (SR-17)
                    else
                        rc=1
                    fi
                done
                if [ "$n" -eq 0 ]; then
                    ga_err chunks_failed "$(t export_err_chunks)"
                    rc=1
                fi
            fi
            ga_wipe_dir "$tmp"
            [ "$rc" = 0 ] || return 1 ;;
    esac
    # Ключ собран — выдача состоялась: в журнал действий (SR-03).
    ga_export_audit_key "$name" "$profile" "$format" "${ep:-}"
    # disabled — не украшение ответа: бот и панель обязаны сказать то же самое,
    # что сказал экран SSH, иначе «ключ выдан, а человек не подключается»
    # остаётся загадкой ровно в двух интерфейсах из трёх.
    # Ключ, ссылка и их QR — окружением, не аргументами jq: это тот же приватный ключ, а argv виден всем в
    # /proc/*/cmdline (находка SR-17).
    GA_S_CONF="$conf" GA_S_VPN="$vpn" GA_S_QRC="$qrc" GA_S_QRV="$qrv" jq -cn \
        --arg line "$line" --arg min "$min" --argjson disabled "$disabled" \
        --arg khost "$khost" --arg kport "$kport" --argjson override "$override" --arg fname "$fname" \
        '$ENV.GA_S_CONF as $conf | $ENV.GA_S_VPN as $vpn | $ENV.GA_S_QRC as $qrc | ($ENV.GA_S_QRV | fromjson) as $qrv
         | {conf: $conf, vpn: $vpn, qr_conf_png_b64: $qrc, qr_vpn_png_b64: $qrv, line: $line,
          min_client: $min, disabled: $disabled, key_host: $khost,
          key_endpoint: (if $khost != "" and $kport != "" then "\($khost):\($kport)" else "" end),
          key_host_override: $override, file_name: $fname}'
}

# export_key_choices_json — варианты адреса для разовой выдачи (ответ edge-status, поле key_choices): ровно
# то, что примет --endpoint. Вход — готовый JSON edge-status (вердикт, пользователи и A-записи по адресам).
# Порядок: адрес «как обычно» первым, затем домены, затем адреса в порядке машины, замолчавшие — в конце.
export_key_choices_json() {
    local edge="${1:-}" def hosts
    [ -n "$edge" ] || edge='{}'
    def=$(ga_export_endpoint_host 2>/dev/null) || def=""
    hosts=$(ga_export_key_hosts | jq -R . | jq -sc .)
    [ -n "$hosts" ] || hosts='[]'
    # $def — ключевое слово jq 1.6: для адреса по умолчанию используем default_host.
    jq -cn --argjson hosts "$hosts" --arg default_host "$def" --argjson edge "$edge" '
        ($edge.ips // []) as $ips | (($edge.count // ($ips | length)) >= 2) as $many
        | ($hosts + (if $default_host != "" and (($hosts | index($default_host)) == null) then [$default_host] else [] end)) as $all
        | [ $all[] | . as $h
            | ($ips | map(select(.ip == $h)) | .[0]) as $e
            | { host: $h,
                kind: (if test("^[0-9]+(\\.[0-9]+){3}$") then "ip" else "domain" end),
                default: ($h == $default_host),
                verdict: (if $e != null and $many then $e.verdict else null end),
                users: (if $e != null and $many then $e.users else null end),
                in_dns: (if $e != null then $e.in_dns else null end) } ]
        | (map(select(.default)) + map(select(.default | not) | select(.kind == "domain"))
           + map(select(.default | not) | select(.kind == "ip") | select(.verdict != "dark"))
           + map(select(.default | not) | select(.kind == "ip") | select(.verdict == "dark")))'
}
