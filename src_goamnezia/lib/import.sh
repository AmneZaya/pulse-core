#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# goAmnezia pro — lib/import.sh: импорт существующей установки Amnezia
# (PLAN §6.5, CONTRACT §4.10)
#
# Сервер уже ставили официальным приложением Amnezia: на нём крутятся
# контейнеры amnezia-awg2 (AmneziaWG 2.0/3.x) или legacy amnezia-awg (1.x, образ
# amnezia-wg, интерфейс wg0 и wg0.conf), внутри — серверные ключи, awg0.conf с
# [Peer] пользователей и clientsTable с их именами. Модуль:
#   • import_scan — повторяет поиск приложения (docker ps + регулярка
#     «amnezia…:порт->»), читает конфиг и clientsTable каждого найденного
#     контейнера и отдаёт таблицу «что нашли» без единого секрета;
#   • import_adopt — записывает контейнер профилем в config.json (линейка — по
#     параметрам конфига, awgkeys.py detect-line), пользователей — в users.json
#     БЕЗ приватных ключей (их у сервера нет и не было: приложение хранит ключ
#     клиента у себя), с пометкой imported, копирует конфиг и ключи в state/.
#     Контейнер не пересоздаётся и не трогается: люди продолжают ходить через
#     него теми же ключами. Такому пользователю доступна только ротация ключа
#     (user-del-peer + user-add-peer — новый .conf вместо ключа из приложения);
#   • import_reconcile — сверка после старта: приложение могло добавить или
#     удалить пира прямо в контейнере, минуя нас. Новые пиры подхватываются
#     как импортированные пользователи, исчезнувшие помечаются active=false.
#
# Стенд (GOAMNEZIA_DRY_RUN=1): docker ps — из GOAMNEZIA_DOCKER_PS_FIXTURE,
# файлы контейнеров — из GOAMNEZIA_CONTAINER_FS_DIR/<контейнер>/<путь>
# (lib/docker.sh); tests/test_import_dryrun.sh.
#
# Правила серии: stdout — только JSON; секреты (приватный ключ сервера, PSK) в
# stdout не попадают никогда — только в state/ и users.json с правами 0600;
# коды ошибок через ga_err; словарь lib/lang/<lang>.d/import.sh.
# Зависимости: lib/common.sh, lib/docker.sh, lib/amnezia.sh (ga_profile_*,
# ga_amn_*, amnezia_state_sync), lib/users.sh (ga_users_*), lib/awgkeys.py.
# ══════════════════════════════════════════════════════════════════════════════

GA_IMPORT_NAME_RE='^amnezia-[a-z0-9-]{2,32}$'
GA_IMPORT_LEGACY="amnezia-awg"

# ── Помощники ─────────────────────────────────────────────────────────────────

# Вид контейнера по имени: awg (наши/приложения amnezia-awgN), legacy
# (amnezia-awg, 1.x), unsupported, other. Профиль, в который он ложится: только
# те имена, что знает контракт §2 (amnezia-awg1/2/3) и legacy → awg1.
# amnezia-xray ставит на сервер приложение Amnezia; goAmnezia — продукт только
# про AmneziaWG, поэтому такой контейнер показываем в находке отдельным видом
# и честно говорим, что не поддерживаем (решение владельца 09.09.2026).
#
# Прочие контейнеры приложения (OpenVPN, Cloak, Shadowsocks, WireGuard, IPsec, Xray+Shadowsocks, служебные
# DNS, Tor, SFTP, SOCKS5) — тот же вид unsupported: их тоже ставит приложение, и человек должен увидеть их
# в находке с именем протокола, а не «неизвестный тип контейнера» (живая жалоба владельца 25.09.2026:
# установщик «не увидел» контейнеры приложения).
ga_import_kind() {
    case "$1" in
        "$GA_IMPORT_LEGACY") echo legacy ;;
        amnezia-awg[0-9]*)   echo awg ;;
        *) if [ -n "$(ga_import_protocol "$1")" ]; then echo unsupported; else echo other; fi ;;
    esac
}

# ga_import_protocol <контейнер> — протокол контейнера приложения Amnezia по имени (имена контейнеров — из
# containers_defs клиента Amnezia): awg, awg_legacy, xray, openvpn, cloak, shadowsocks, wireguard, ipsec,
# ssxray, dns, tor, sftp, socks5proxy. Пусто — такого имени у приложения нет (чужая сборка amnezia-*).
ga_import_protocol() {
    case "$1" in
        "$GA_IMPORT_LEGACY")   echo awg_legacy ;;
        amnezia-awg[0-9]*)     echo awg ;;
        amnezia-xray)          echo xray ;;
        amnezia-openvpn)       echo openvpn ;;
        amnezia-openvpn-cloak) echo cloak ;;
        amnezia-shadowsocks)   echo shadowsocks ;;
        amnezia-wireguard)     echo wireguard ;;
        amnezia-ipsec)         echo ipsec ;;
        amnezia-ssxray)        echo ssxray ;;
        amnezia-dns)           echo dns ;;
        amnezia-tor)           echo tor ;;
        amnezia-sftp)          echo sftp ;;
        amnezia-socks5proxy)   echo socks5proxy ;;
        *)                     echo "" ;;
    esac
}
ga_import_profile_for() {
    case "$1" in
        "$GA_IMPORT_LEGACY") echo awg1 ;;
        amnezia-awg1) echo awg1 ;;
        amnezia-awg2) echo awg2 ;;
        amnezia-awg3) echo awg3 ;;
        *) echo "" ;;
    esac
}
ga_import_iface_for() { case "$(ga_import_kind "$1")" in legacy) echo wg0 ;; *) echo awg0 ;; esac; }
ga_import_conf_path_for() { echo "/opt/amnezia/awg/$(ga_import_iface_for "$1").conf"; }
# Образ ядра по виду: legacy — замороженный amnezia-wg, остальные — amneziawg-go.
ga_import_image_key_for() { case "$(ga_import_kind "$1")" in legacy) echo amnezia-wg ;; *) echo amneziawg-go ;; esac; }

# Сетевой адрес по любому адресу с маской (приложение пишет 10.8.1.0/24, но
# чужие сборки встречались и с 10.8.1.1/24): stdout «a.b.c.0/24».
# Адрес проверяется по ЗНАЧЕНИЮ единственной функцией продукта _valid_ip
# (CONTRACT §0.8): своя регулярка по четыре цифры на октет пропускала
# «999.999.999.0/24», и такая «подсеть» уезжала в config.json профиля, откуда
# её берут и проверка пересечений, и выдача адресов пирам.
ga_import_network() {
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

# Кириллица из имён приложения — латиницей: «Телефон Маши» → Telefon_Mashi.
# Раньше она выпадала, и идентификатором становилось «client-xxxx»: в списках,
# в сообщениях и в боте человек был неузнаваем (живой подхват 25.09.2026 — три
# имени из четырёх). Прочие не-латинские буквы по-прежнему выпадают.
ga_import_translit() {
    printf '%s' "$1" | python3 -c '
import sys
m = dict(zip("абвгдеёжзийклмнопрстуфхцчшщъыьэюяіїєґў",
             ["a", "b", "v", "g", "d", "e", "e", "zh", "z", "i", "y", "k", "l", "m", "n", "o", "p", "r", "s",
              "t", "u", "f", "kh", "ts", "ch", "sh", "sch", "", "y", "", "e", "yu", "ya", "i", "yi", "ye", "g", "u"]))
out = []
for ch in sys.stdin.read():
    lo = ch.lower()
    t = m.get(lo)
    out.append(ch if t is None else (t.capitalize() if ch != lo else t))
sys.stdout.write("".join(out))' 2>/dev/null || printf '%s' "$1"
}

# Идентификатор пользователя из имени клиента приложения: латиница/цифры/_/-
# до 32 символов, кириллица — транслитом; если не осталось ничего → «client-…»;
# уникальность — суффиксом -2, -3… Отображаемое имя (label) сохраняет оригинал.
ga_import_user_name() {
    local label="$1" pubkey="$2" taken="$3" base cand n=1
    base=$(ga_import_translit "$label" | tr -c 'A-Za-z0-9_-' '_' | sed 's/^_*//; s/_*$//' | cut -c1-24)
    base=$(printf '%s' "$base" | tr -s '_' | sed 's/^[-_]*//; s/[-_]*$//')
    if [ -z "$base" ]; then
        base="client-$(printf '%s' "$pubkey" | tr -cd 'A-Za-z0-9' | cut -c1-6)"
    fi
    cand="$base"
    while grep -qxF "$cand" <<<"$taken"; do
        n=$((n + 1))
        cand="${base}-${n}"
    done
    printf '%s' "$cand"
}

# clientsTable контейнера → JSON {pubkey: {name, created}} (пусто/битый → {}).
# Чтение — и у остановленного контейнера (docker cp): его тоже показываем и подхватываем (TK-4).
ga_import_clients_map() {
    local raw
    raw=$(docker_read_file_any "$1" /opt/amnezia/awg/clientsTable 2>/dev/null) || raw=""
    # Таблицы нет или она пустая — {} (KEENETIC-I1-Q, P2): jq на пустом вводе ничего не печатает и выходит с 0, и
    # вместо {} выходила пустая строка — сверка падала на ней с rc 2.
    [ -n "${raw//[[:space:]]/}" ] || { echo '{}'; return 0; }
    # -s (S3): таблица — ровно один JSON-текст. Без -s на «[…] хвост» jq печатал карту первого текста и падал на хвосте,
    # `|| echo '{}'` дописывал второй текст, и --argjson сверки отказывал с rc 2. С -s битый ввод — ни строки, и {}.
    printf '%s' "$raw" | jq -c -s 'if length == 1 and (.[0] | type) == "array" then .[0] |
        map(select(type == "object" and (.clientId // "") != "")
            | {key: .clientId, value: {name: ((.userData.clientName // "") | tostring), created: ((.userData.creationDate // "") | tostring)}})
        | from_entries else {} end' 2>/dev/null || echo '{}'
}

# Конфиг контейнера через awgkeys.py parse-conf → JSON (см. lib/awgkeys.py);
# with_secrets=1 добавляет приватный ключ сервера и PSK пиров — только для adopt.
ga_import_parse_conf() {
    local container="$1" with_secrets="${2:-0}" raw
    raw=$(docker_read_file_any "$container" "$(ga_import_conf_path_for "$container")" 2>/dev/null) || raw=""
    [ -n "$raw" ] || return 3
    if [ "$with_secrets" = 1 ]; then
        printf '%s' "$raw" | ga_awgkeys parse-conf --with-secrets 2>/dev/null
    else
        printf '%s' "$raw" | ga_awgkeys parse-conf 2>/dev/null
    fi
}

# ga_import_snapshot <контейнер> → stdout: каталог снимка. Снимок контейнера
# как он есть ДО подхвата: конфиг, clientsTable, ключи сервера и start.sh —
# отдельно от бэкапов продукта (import-snapshots/, не backups/: список и
# ротация бэкапов снимок не тронут, а восстановление не примет его за архив).
# Сам подхват контейнер не меняет, но дальше мы пишем в его конфиг и
# clientsTable, и вернуть «как было у приложения» можно только из снимка.
# Права 700/600: внутри приватный ключ сервера и PSK. Без конфига в снимке
# подхват не начинается.
ga_import_snapshot() {
    local container="$1" dir f name conf
    ga_amn_state_init "$GOAMNEZIA_DIR/import-snapshots" || return 1
    dir="$GOAMNEZIA_DIR/import-snapshots/${container}-$(date -u +%Y%m%dT%H%M%SZ)"
    ga_amn_state_init "$dir" || return 1
    conf=$(ga_import_conf_path_for "$container")
    for f in "$conf" "$GA_AWG_CLIENTS_TABLE" "$GA_AWG_DIR/$GA_AWG_SERVER_PRIV" "$GA_AWG_DIR/$GA_AWG_SERVER_PUB" \
             "$GA_AWG_DIR/$GA_AWG_PSK" /opt/amnezia/start.sh; do
        name="${f##*/}"
        docker_read_file_any "$container" "$f" 2>/dev/null | ga_amn_write_secret "$dir/$name"
        [ -s "$dir/$name" ] || rm -f "$dir/$name"
    done
    [ -s "$dir/${conf##*/}" ] || { rm -rf "$dir"; return 1; }
    printf '%s' "$dir"
}

# ── import_scan ───────────────────────────────────────────────────────────────

# import_scan → stdout JSON [{container, state, port, proto, kind, protocol, profile, managed,
# suggested_profile, adoptable, reason, reason_text, line, subnet, subnet_overlap, listen_port, iface,
# server_pubkey, image, peers, clients: [{pubkey, name, ip, created, known}]}].
# subnet_overlap — профили, с чьей подсетью совпадает подсеть контейнера (SUBNET-01): подхват от этого не
# отказывает, контейнер берётся как есть, а экраны подсети предлагают развести подсети.
# known=true — пир уже есть в users.json (наш профиль или уже подхваченный).
# state — running | restarting | exited: остановленные контейнеры тоже в списке (раньше поиск шёл по
# `docker ps` без -a и их не видел — TK-4), и остановленный контейнер AmneziaWG подхватывается: import_adopt
# запускает его после записи профиля. reason_text — причина словами на языке сервера (что мешает подхвату).
# Демон не отвечает — отказ docker_unreachable, а не пустой список: «контейнеров нет» и «не узнать» — разное.
import_scan() {
    local line name port proto kind profile managed suggested adoptable reason rtext state protocol
    local conf clients image cur_line subnet lport pub peers known rows='[]' p c ps_out ovl
    # GA_IMPORT_QUIET=1 — поиск изнутри подхвата: строка «Ищу контейнеры…» перед каждым подхватом — шум.
    [ "${GA_IMPORT_QUIET:-0}" = 1 ] || log_dim "$(t import_scanning)"
    # Битый users.json здесь означал бы «своих пиров нет», и КАЖДЫЙ пир
    # контейнера объявлялся бы новым: человеку предложили бы подхватить
    # собственных же пользователей. Читаем одним законным способом и отказываем.
    local __u
    ga_users_load __u || { ga_err users_corrupt "$(t users_err_corrupt)"; return 1; }
    known=$(printf '%s' "$__u" | jq -c '[.users[]? | .peers[]? | .pubkey // empty]' 2>/dev/null)
    [ -n "$known" ] || known='[]'
    # Docker не поставлен вовсе — и контейнеров приложения на машине нет: пустой список, не ошибка.
    if ! ga_dry && ! command -v docker >/dev/null 2>&1; then printf '[]\n'; return 0; fi
    if ! ps_out=$(docker_ps_all); then
        ga_err docker_unreachable "$(t import_err_docker_unreachable)"
        return 1
    fi
    while IFS=$'\t' read -r name state line; do
        [ -n "$name" ] || continue
        [[ "$name" =~ ^amnezia[-a-z0-9]*$ ]] || continue
        port=""; proto=""
        if [[ "$line" =~ :([0-9]+)-\>[0-9]+/(udp|tcp) ]]; then
            port="${BASH_REMATCH[1]}"; proto="${BASH_REMATCH[2]}"
        fi
        kind=$(ga_import_kind "$name")
        protocol=$(ga_import_protocol "$name")
        profile=""; managed=false
        for p in awg1 awg2 awg3; do
            c=$(ga_profile_field "$p" container 2>/dev/null)
            if [ "$c" = "$name" ] && ga_profile_installed "$p"; then
                profile="$p"; managed=true; break
            fi
        done
        suggested=$(ga_import_profile_for "$name")
        adoptable=true; reason=""
        conf='null'; clients='[]'; image=""; cur_line=""; subnet=""; lport=0; pub=""; peers=0
        case "$kind" in
            awg|legacy)
                image=$(docker_container_image "$name" 2>/dev/null | head -n 1)
                if conf=$(ga_import_parse_conf "$name" 0) && [ -n "$conf" ]; then
                    cur_line=$(jq -r '.line // ""' <<<"$conf")
                    subnet=$(ga_import_network "$(jq -r '.address // ""' <<<"$conf")" 2>/dev/null) || subnet=""
                    lport=$(jq -r '.listen_port // 0' <<<"$conf")
                    pub=$(jq -r '.server_pubkey // ""' <<<"$conf")
                    clients=$(jq -c --argjson m "$(ga_import_clients_map "$name")" --argjson known "$known" '
                        [.peers[]? | . as $peer | ($m[$peer.pubkey] // {}) as $u
                         | {pubkey: $peer.pubkey, name: ($u.name // ""), ip: $peer.ip, created: ($u.created // ""),
                            known: (($known | index([$peer.pubkey])) != null)}]' <<<"$conf")
                    peers=$(jq -r 'length' <<<"$clients")
                else
                    conf='null'; adoptable=false; reason="no_conf"
                fi
                ;;
            unsupported) adoptable=false; reason="unsupported_container" ;;
            *)    adoptable=false; reason="unknown_kind" ;;
        esac
        if [ "$adoptable" = true ]; then
            if [ "$managed" = true ]; then
                adoptable=false; reason="managed"
            elif [ -z "$suggested" ]; then
                adoptable=false; reason="unknown_kind"
            elif ga_profile_installed "$suggested"; then
                adoptable=false; reason="profile_exists"
            fi
        fi
        [[ "$lport" =~ ^[0-9]+$ ]] || lport=0
        [[ "$port" =~ ^[0-9]+$ ]] || port=0
        # У остановленного контейнера Docker портов не показывает — берём порт из его конфига.
        if [ "$port" = 0 ] && [ "$lport" != 0 ]; then port="$lport"; proto="udp"; fi
        case "$state" in running|restarting|exited) ;; *) state=running ;; esac
        rtext=""
        [ -n "$reason" ] && rtext=$(ga_import_reason_text "$reason" "$protocol" "$profile" "$suggested")
        # С какими профилями совпадёт подсеть (SUBNET-01): подхват не откажет, а экраны скажут заранее.
        ovl='[]'
        if [ -n "$subnet" ]; then
            if [ "$managed" = true ]; then ovl=$(ga_amn_subnet_overlapping "$subnet" "$profile")
            else ovl=$(ga_amn_subnet_overlapping "$subnet" "$suggested"); fi
            jq -e 'type == "array"' <<<"$ovl" >/dev/null 2>&1 || ovl='[]'
        fi
        rows=$(jq -c --arg n "$name" --argjson port "$port" --arg proto "$proto" --arg kind "$kind" \
            --arg profile "$profile" --argjson managed "$managed" --arg sug "$suggested" --argjson ad "$adoptable" \
            --arg reason "$reason" --arg line "$cur_line" --arg subnet "$subnet" --argjson lport "$lport" \
            --arg iface "$(ga_import_iface_for "$name")" --arg pub "$pub" --arg image "$image" --argjson peers "$peers" \
            --argjson clients "$clients" --arg state "$state" --arg protocol "$protocol" --arg rtext "$rtext" \
            --argjson ovl "$ovl" '
            . + [{container: $n, state: $state, port: $port, proto: $proto, kind: $kind, protocol: $protocol,
                  profile: $profile, managed: $managed, suggested_profile: $sug, adoptable: $ad, reason: $reason,
                  reason_text: $rtext, line: $line, subnet: $subnet, subnet_overlap: $ovl, listen_port: $lport,
                  iface: $iface, server_pubkey: $pub, image: $image, peers: $peers, clients: $clients}]' <<<"$rows") || rows="$rows"
    done <<<"$ps_out"
    printf '%s\n' "$rows"
}

# ga_import_reason_text <причина> <протокол> <профиль> <предлагаемый профиль> — что мешает подхвату, словами.
# Ключ словаря выбираем через case (ключ всегда буквально — правило словарей, MAP §1 п.8).
ga_import_reason_text() {
    local reason="$1" protocol="$2" profile="$3" sug="$4"
    case "$reason" in
        managed)        tf import_reason_managed_as "${profile:-?}" ;;
        profile_exists) tf import_reason_profile_exists_as "${sug:-?}" ;;
        no_conf)        t import_reason_no_conf ;;
        unsupported_container)
            case "$protocol" in
                dns)  t import_reason_app_dns ;;
                sftp|tor) t import_reason_app_service ;;
                *)    t import_reason_unsupported_container ;;
            esac ;;
        *)              t import_reason_unknown_kind ;;
    esac
}

# ga_import_protocol_label <протокол> [линейка] — подпись протокола для списка «что нашли».
ga_import_protocol_label() {
    case "$1" in
        awg)         if [ -n "${2:-}" ]; then printf 'AmneziaWG %s' "$2"; else printf 'AmneziaWG'; fi ;;
        awg_legacy)  if [ -n "${2:-}" ]; then printf 'AmneziaWG %s' "$2"; else printf 'AmneziaWG 1.x'; fi ;;
        xray)        printf 'Xray (VLESS)' ;;
        openvpn)     printf 'OpenVPN' ;;
        cloak)       printf 'OpenVPN + Cloak' ;;
        shadowsocks) printf 'Shadowsocks' ;;
        wireguard)   printf 'WireGuard' ;;
        ipsec)       printf 'IPsec' ;;
        ssxray)      printf 'Shadowsocks (Xray)' ;;
        dns)         printf 'DNS' ;;
        tor)         printf 'Tor' ;;
        sftp)        printf 'SFTP' ;;
        socks5proxy) printf 'SOCKS5' ;;
        *)           t import_protocol_unknown ;;
    esac
}

# ── import_adopt ──────────────────────────────────────────────────────────────

# Пир из конфига контейнера — чужой ввод (KEENETIC-I1-NITS, S1 и S2). Годный пир: PublicKey — ключ WireGuard
# (44 знака base64 с «=» в конце), PresharedKey — пусто или такой же ключ, адрес — IPv4 (первый из AllowedIPs, его
# берёт parse_server_conf; без AllowedIPs конфиг профиля не собрать: «each peer needs pubkey and ip»).
# ga_peer_bad → "key", если ключ не ключ, иначе "". ga_peer_ip — адрес, если в нём только цифры и точки, иначе пусто:
# так в строку для read не попадает ни \x1f, ни перевод строки; сам адрес проверяет _valid_ip (одна проверка IPv4 на
# весь код, CONTRACT §0.8). ga_peer_tag — начало PublicKey для строки на экран: 12 знаков, всё, кроме base64, — «?»
# (управляющие символы на экран не идут). \A…\z, а не ^…$: «$» в test() совпадает и перед конечным переводом строки.
GA_IMPORT_PEER_JQ='def ga_peer_bad:
        ((.pubkey // "") | tostring) as $k | ((.psk // "") | tostring) as $s
        | if ($k | test("\\A[A-Za-z0-9+/]{43}=\\z") | not) or ($s != "" and ($s | test("\\A[A-Za-z0-9+/]{43}=\\z") | not)) then "key"
          else "" end;
    def ga_peer_ip: ((.ip // "") | tostring) as $a | if ($a | test("\\A[0-9.]+\\z")) then $a else "" end;
    def ga_peer_tag: ((.pubkey // "") | tostring | .[0:12] | gsub("[^A-Za-z0-9+/=]"; "?")) as $t | if $t == "" then "-" else $t end;'

# ga_import_peers_sort <профиль> <пиры JSON [{pubkey, ip, psk}]> <users.json как JSON> → stdout: тот же массив, у каждого
# пира поля skip и tag (KEENETIC-I1-N, N2). skip — можно ли подхватить пира в этот профиль:
#   ""    — можно;
#   known — уже пользователь этого профиля (свой);
#   key   — PublicKey или PresharedKey не ключ WireGuard (S1);
#   taken — ключ уже у пользователя другого профиля: подхват его не возьмёт, один ключ на два профиля не делится;
#   ip    — в AllowedIPs нет адреса IPv4 (S2, N1: только IPv6 или пусто).
# tag — начало PublicKey для экрана (ga_peer_tag). Одно решение на подхват (ga_import_users_add), сверку
# (import_reconcile) и пропуск миграции I1 (_ga_amn_foreign_peer_any): прежде сверка считала новыми и тех, кого подхват
# потом пропускал, — и профиль навсегда оставался «разошедшимся». Пиры и users.json — на stdin jq (в них PSK, а argv
# виден всем в /proc, SR-17). rc 1 и пустой stdout — разбор не удался (битый вход, сбой jq): решения нет ни для одного
# пира. Прежде недостающие коды становились «не ключ», и миграция I1 сочла бы людей приложения не чужими (V2).
ga_import_peers_sort() {
    local profile="$1" peers="$2" users="$3" codes='' bad st ip skip n=0 want
    # Адрес в строку для read — только цифры и точки (ga_peer_ip), по значению его проверяет _valid_ip (CONTRACT §0.8).
    # users.json и пиры — оба на stdin одного jq (input): в них секреты, а список ключей всех пользователей в argv ещё
    # и упёрся бы в предел длины одного аргумента.
    while IFS=$'\x1f' read -r bad st ip; do
        if [ "$st" = known ]; then skip=known
        elif [ "$bad" = key ]; then skip=key
        elif [ "$st" = taken ]; then skip=taken
        elif ! _valid_ip "$ip"; then skip=ip
        else skip=""
        fi
        codes+="${codes:+,}\"$skip\""
        n=$((n + 1))
    done < <({ printf '%s\n' "$users"; printf '%s\n' "$peers"; } | jq -n -r --arg p "$profile" "$GA_IMPORT_PEER_JQ"'
        input as $u | input as $peers
        | [$u.users[]? | .peers[$p]?.pubkey? // empty] as $here | [$u.users[]? | .peers[]?.pubkey? // empty] as $all
        | $peers[] | ((.pubkey // "") | tostring) as $k
        | [ga_peer_bad, (if ($here | index([$k])) != null then "known" elif ($all | index([$k])) != null then "taken" else "" end), ga_peer_ip]
        | map(tostring) | join("\u001f")')
    # Решение — на каждого пира (KEENETIC-I1-N, V2): кодов меньше, чем пиров, — разбор сбился, отказ, а не «не ключ».
    want=$(jq -r 'if type == "array" then length else error end' <<<"$peers" 2>/dev/null) || return 1
    [ "$n" = "$want" ] || return 1
    jq -c --argjson s "[$codes]" "$GA_IMPORT_PEER_JQ"' [to_entries[] | .value + {skip: $s[.key], tag: (.value | ga_peer_tag)}]' <<<"$peers"
}

# Записать импортированных пользователей из пиров конфига в users.json.
# Аргументы: профиль, JSON пиров с секретами ([{pubkey, psk, ip}]), карта
# clientsTable {pubkey: {name, created}}. Свои пиры профиля пропускаются молча
# (повторный подхват не плодит дублей). Пир, которого не подхватить
# (ga_import_peers_sort: не ключ, ключ другого профиля, нет IPv4), пропускается
# со строкой-предупреждением: пользователь из него не собрать, а с пустым
# адресом он ломал бы каждую запись конфига профиля.
# stdout: JSON-массив имён добавленных пользователей.
ga_import_users_add() {
    local profile="$1" peers="$2" clients="$3" users sorted taken added='[]' n=0
    local skip tag pubkey psk ip label name created now
    # Подхват дописывает пиров в users.json: читать его «как получится» нельзя,
    # иначе на битом файле подхват начнёт с пустого списка и затрёт всех.
    ga_users_load users || { ga_err users_corrupt "$(t users_err_corrupt)"; return 1; }
    now=$(ga_now)
    sorted=$(ga_import_peers_sort "$profile" "$peers" "$users") || return 1
    # Поля — через \x1f, а не таб (KEENETIC-I1-Q, P1): таб для read — пробельный разделитель, подряд идущие склеиваются,
    # и у пира без PresharedKey адрес уезжал в psk, а ip оставался пустым. \x1f не пробельный: пустое поле остаётся полем.
    # Значения пропущенного пира в строку не идут вовсе (S1: \x1f внутри PresharedKey сдвигал поля — часть PSK уезжала
    # в адрес и на экран): только причина и начало ключа, очищенное ga_peer_tag. У годного поля — base64, цифры и точки.
    while IFS=$'\x1f' read -r skip tag pubkey psk ip; do
        case "$skip" in
            "") ;;
            known) continue ;;
            *) log_warning "$(tf "import_peer_skipped_$skip" "$tag")"; continue ;;
        esac
        [ -n "$pubkey" ] || continue
        # Тот же ключ дважды в одном конфиге — второй раз он уже наш (дописан выше): пропускаем.
        if [ "$(jq -r --arg k "$pubkey" '[.users[]? | .peers[]? | .pubkey] | index([$k]) != null' <<<"$users")" = true ]; then
            continue
        fi
        # Подпись — тем же определением, по которому запись clientsTable узнаёт нетронутое имя
        # (GA_AMN_LABEL_JQ, lib/amnezia.sh): 48 знаков, а не байтов — cut -c резал кириллицу посреди буквы.
        label=$(jq -r --arg k "$pubkey" "$GA_AMN_LABEL_JQ"' .[$k].name // "" | ga_app_label' <<<"$clients")
        # В users.json — метка ISO (по ней сортируют и сравнивают). Дата приложения в его формате (Qt TextDate)
        # остаётся дословно в clientsTable: запись таблицы её не трогает (находка ACC-1).
        created=$(jq -r --arg k "$pubkey" '.[$k].created // ""' <<<"$clients")
        [[ "$created" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || created="$now"
        taken=$(jq -r '.users[]? | .name' <<<"$users")
        name=$(ga_import_user_name "$label" "$pubkey" "$taken")
        [ -n "$label" ] || label="$name"
        # PSK — окружением, не аргументом jq: argv виден всем в /proc/*/cmdline (находка SR-17).
        # $label не разбирается в jq 1.6; поле label сохраняем, переменную называем user_label.
        users=$(GA_S_PSK="$psk" jq -c --arg name "$name" --arg user_label "$label" --arg created "$created" --arg p "$profile" \
            --arg pub "$pubkey" --arg ip "$ip" --arg now "$now" '
            .users += [{name: $name, label: $user_label, created: $created, enabled: true, quota_bytes: 0, expires: "",
                        imported: true, traffic: {rx: 0, tx: 0, last_rx: 0, last_tx: 0, updated: ""},
                        peers: {($p): {ip: $ip, privkey: "", pubkey: $pub, psk: $ENV.GA_S_PSK, created: $created,
                                       active: true, imported: true, last_handshake: 0, rx: 0, tx: 0, last_rx: 0, last_tx: 0}}}]' <<<"$users") || return 1
        added=$(jq -c --arg n "$name" '. + [$n]' <<<"$added")
        n=$((n + 1))
        log_dim "$(tf import_user_added "$name" "${ip:--}")"
    done < <(jq -r "$GA_IMPORT_PEER_JQ"' .[]
        | if .skip == "" then [.skip, .tag, .pubkey, (.psk // ""), ga_peer_ip] else [.skip, .tag, "", "", ""] end
        | map(tostring) | join("\u001f")' <<<"$sorted")
    printf '%s' "$users" | ga_users_write || { ga_err users_write_failed "$(t users_err_write)"; return 1; }
    printf '%s' "$added"
}

# Откат незавершённого подхвата (см. _import_adopt_locked): убрать запись
# профиля из config.json, только что добавленных импортированных пользователей
# из users.json и каталог state/, если его завёл сам подхват.
#
# Зачем: профиль появляется в конфиге раньше, чем добавлены пиры и заполнено
# состояние, и отказ на любом шаге дальше оставлял запись без пиров и без
# ключей. Повторный подхват такого контейнера отвечал «профиль уже есть»
# (import_scan видит установленный профиль), то есть штатного выхода из
# полусостояния не было вовсе: человеку оставалось править config.json руками.
# Ошибки самого отката не превращаем в ошибку операции — наружу уже идёт
# причина отказа, а вторая поверх неё только запутает.
_ga_import_adopt_undo() {
    local profile="$1" sdir="${2:-}" keep_state="${3:-0}" added="${4:-[]}" profiles users name
    profiles=$(ga_config_get ".profiles" 2>/dev/null | jq -c --arg p "$profile" 'del(.[$p])' 2>/dev/null) || profiles=""
    [ -n "$profiles" ] && ga_config_set ".profiles" "$profiles" >/dev/null 2>&1
    if [ "$(jq -r 'length' <<<"$added" 2>/dev/null || echo 0)" != 0 ]; then
        users=$(ga_users_read 2>/dev/null) || users=""
        if [ -n "$users" ]; then
            while IFS= read -r name; do
                [ -n "$name" ] || continue
                users=$(jq -c --arg n "$name" '.users |= map(select(.name != $n))' <<<"$users") || break
            done < <(jq -r '.[]' <<<"$added" 2>/dev/null)
            printf '%s' "$users" | ga_users_write >/dev/null 2>&1
        fi
    fi
    [ "$keep_state" = 1 ] || [ -z "$sdir" ] || rm -rf "$sdir" 2>/dev/null
    log_warning "$(tf import_adopt_undone "$profile")"
    return 0
}

# import_adopt <контейнер> → stdout JSON {profile, container, line, port, subnet, iface, image_tag,
# image_digest, users_added, users, peers, hint, snapshot, state_before, started, subnet_overlap, ipacket_warnings,
# param_warnings}.
# ipacket_warnings — слова о тегах I1–I5, которые понимает не каждая реализация (KMOD-02; пусто — их нет).
# param_warnings — слова о том, что продукт сам так не записал бы (1.0.13: тайминги 3.1 вне коридора, связка таймингов,
# всплеск мусора, Jc + число I, хвосты 3.1 + разные S + широкие H; пусто — всё в пределах). started —
# запустился ли контейнер, который до подхвата стоял (null — он и так работал). subnet_overlap — запись
# ga_amn_subnet_overlaps этого профиля (с кем совпала подсеть и выход) или null.
import_adopt() { ga_with_config_lock _import_adopt_locked "$@"; }
_import_adopt_locked() {
    local container="$1" scan entry profile reason conf line subnet port iface key repo tag digest
    local params pub priv psk_file peers clients sdir added n entry_json image state_existed=0
    if ! [[ "$container" =~ $GA_IMPORT_NAME_RE ]]; then
        ga_err invalid_container "$(tf import_err_container_name "$container")" 2
        return 2
    fi
    local GA_IMPORT_QUIET=1
    ga_capture scan import_scan || return 1
    entry=$(jq -c --arg c "$container" '.[] | select(.container == $c)' <<<"$scan" | head -n 1)
    if [ -z "$entry" ]; then
        ga_err container_not_found "$(tf import_err_not_found "$container")" 3
        return 3
    fi
    if [ "$(jq -r '.adoptable' <<<"$entry")" != true ]; then
        reason=$(jq -r '.reason // ""' <<<"$entry")
        case "$reason" in
            managed)        ga_err already_managed "$(tf import_err_already_managed "$container" "$(jq -r '.profile' <<<"$entry")")" ;;
            profile_exists) ga_err profile_exists "$(tf import_err_profile_exists "$container" "$(jq -r '.suggested_profile' <<<"$entry")")" ;;
            no_conf)        ga_err conf_read_failed "$(tf import_err_conf_read "$container")" ;;
            unsupported_container)
                            ga_err unsupported_container "$(tf import_err_not_adoptable "$container" "$(jq -r '.reason_text // ""' <<<"$entry")")" ;;
            *)              ga_err not_adoptable "$(tf import_err_not_adoptable "$container" "$(jq -r '.reason_text // ""' <<<"$entry")")" ;;
        esac
        return 1
    fi
    profile=$(jq -r '.suggested_profile' <<<"$entry")
    # Конфиг ещё раз, теперь с секретами — они идут только в state/ и users.json.
    if ! conf=$(ga_import_parse_conf "$container" 1) || [ -z "$conf" ]; then
        ga_err conf_read_failed "$(tf import_err_conf_read "$container")"
        return 1
    fi
    line=$(jq -r '.line // ""' <<<"$conf")
    [[ "$line" =~ ^(1\.0|1\.5|2\.0|3\.1)$ ]] || { ga_err conf_parse_failed "$(tf import_err_conf_parse "$container")"; return 1; }
    subnet=$(ga_import_network "$(jq -r '.address // ""' <<<"$conf")" 2>/dev/null) || subnet=""
    port=$(jq -r '.listen_port // 0' <<<"$conf")
    [ "$port" != 0 ] || port=$(jq -r '.port // 0' <<<"$entry")
    priv=$(jq -r '.server_privkey // ""' <<<"$conf")
    pub=$(jq -r '.server_pubkey // ""' <<<"$conf")
    params=$(jq -c '.params // {}' <<<"$conf")
    if [ -z "$subnet" ] || ! ga_amn_port_valid "$port" || [ -z "$priv" ] || [ -z "$pub" ]; then
        ga_err conf_parse_failed "$(tf import_err_conf_parse "$container")"
        return 1
    fi
    # Подсеть на сетях Docker — отказ: на 172.17.x у людей рукопожатие без трафика (SR-37). С подсетью другого
    # профиля — подхват всё равно (SUBNET-01): приложение Amnezia ставит любой свой контейнер AmneziaWG — и старый
    # amnezia-awg, и amnezia-awg2 — на одну 10.8.1.0/24, и отказ оставлял второй без управления, а старому (wg0)
    # подсеть не сменить — тупик. Контейнеры живут каждый в своём сетевом пространстве, людям обоих пересечение не
    # мешает; его показывают экраны подсети с выходом — перенести тот профиль, которому смена разрешена.
    ga_amn_subnet_check "$profile" "$subnet" net || return $?
    # Порт — не тот же, что у другого профиля в config.json: подхват писал два профиля на один порт (находка
    # SR-38), и дальше порт-зависимое (смена порта, режим на 443, пересоздание) путало их. Проверяем только
    # config.json: сам порт на машине держит этот же контейнер, и «занят» тут — не отказ.
    local powner
    powner=$(jq -r --argjson p "$port" --arg me "$profile" \
        '.profiles // {} | to_entries[] | select(.key != $me and .value.port == $p) | .key' "$CONFIG_FILE" 2>/dev/null | head -n 1)
    if [ -n "$powner" ]; then
        ga_err port_busy "$(tf amnezia_err_port_taken "$port" "$powner")"
        return 1
    fi
    iface=$(ga_import_iface_for "$container")
    # Сигнатурные пакеты I1–I5 чужого конфига уходят в ключи людей (KMOD-02). Отрицательный размер, незнакомый тег,
    # пакет больше 1280 байт — модуль ядра AmneziaWG у клиента падает или конфиг не принимает: отказ словами до всякого
    # изменения. Тег, который понимает не каждая реализация (<c>; <d> <ds> <dz>), — не повод отказать: люди, которые
    # подключаются сейчас, остались бы без сервиса. Подхватываем и предупреждаем словами (ipacket_warnings в ответе).
    # Остальные правила линейки к чужому рабочему контейнеру по-прежнему не применяем.
    local ipk ipk_warn
    ipk=$(ga_amn_ipacket_reason "$params" adopt)
    if [ -n "$ipk" ]; then
        ga_err params_invalid "$(tf import_err_ipacket "$container" "$ipk")" 2
        return 2
    fi
    ipk_warn=$(ga_amn_ipacket_warnings "$params")
    # Пределы того, что пишем мы (1.0.13: тайминги 3.1 вне коридора, связка таймингов, всплеск мусора, Jc + число I,
    # хвосты 3.1 + разные S + широкие H) — у чужого работающего конфига не отказ, а предупреждение словами
    # (param_warnings в ответе): правка того же значения потом — по правилам записи.
    local lim_warn
    lim_warn=$(ga_amn_limits_warnings "$line" "$params")
    key=$(ga_import_image_key_for "$container")
    repo=$(docker_image_field "$key" repo 2>/dev/null); [ -n "$repo" ] || repo="amneziavpn/$key"
    image=$(jq -r '.image // ""' <<<"$entry")
    # Приложение собирает образ из FROM <repo>:latest — тег «latest», дайджест
    # берём у локально вытянутого базового образа (пусто — если не узнать).
    tag="latest"
    digest=$(docker_image_repo_digest "${repo}:latest" 2>/dev/null | tr -d '[:space:]')
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || digest=""
    log_step "$(tf import_adopting "$container" "$profile" "$line")"

    # 0. Снимок контейнера до любых изменений — страховка на случай, если
    # подхват придётся откатывать руками.
    local snap
    if ! snap=$(ga_import_snapshot "$container") || [ -z "$snap" ]; then
        ga_err snapshot_failed "$(tf import_err_snapshot "$container")"
        return 1
    fi
    log_info "$(tf import_snapshot_saved "$snap")"

    # 1. state/: каталог под копию состояния. Помним, был ли он до нас: откат
    # сносит только то, что завёл сам подхват, — в чужом каталоге могли
    # остаться ключи прежнего профиля с этим же именем контейнера.
    sdir="$STATE_DIR/$container"
    [ -d "$sdir" ] && state_existed=1
    ga_amn_state_init "$sdir" || { ga_err state_failed "$(tf amnezia_err_state "$sdir")"; return 1; }

    # 2. Профиль в config.json: контейнер как есть, линейка по конфигу,
    # пресет imported, образ приложения (тег latest).
    entry_json=$(jq -cn --arg line "$line" --arg c "$container" --argjson port "$port" --arg subnet "$subnet" \
        --arg iface "$iface" --arg image "$repo" --arg tag "$tag" --arg digest "$digest" --argjson params "$params" \
        --arg pub "$pub" --arg now "$(ga_now)" --arg built "$image" '
        {line: $line, container: $c, port: $port, subnet: $subnet, iface: $iface, image: $image, image_tag: $tag,
         image_digest: $digest, preset: "imported", params: $params, server_pubkey: $pub, installed_at: $now,
         enabled: true, imported: true, imported_at: $now, built_image: $built}') || return 1
    ga_config_set ".profiles.$profile" "$entry_json" || { ga_err config_write_failed "$(t amnezia_err_config)"; return 1; }

    # Дальше начинается полусостояние: профиль в конфиге уже есть, а пиров и
    # копии состояния ещё нет. Любой отказ отсюда и до конца обязан откатить
    # запись профиля (_ga_import_adopt_undo), иначе повторный подхват ответит
    # «профиль уже есть» и выхода не останется.
    #
    # 3. Пользователи из [Peer] + clientsTable, без приватных ключей.
    peers=$(jq -c '[.peers[]? | {pubkey, psk: (.psk // ""), ip: (.ip // "")}]' <<<"$conf")
    clients=$(ga_import_clients_map "$container")
    ga_capture added ga_import_users_add "$profile" "$peers" "$clients" \
        || { _ga_import_adopt_undo "$profile" "$sdir" "$state_existed" '[]'; return 1; }
    n=$(jq -r 'length' <<<"$added")

    # 4. На живом сервере — полная копия каталога контейнера (start.sh, /opt/warp).
    if ! ga_dry; then
        amnezia_state_sync "$profile" || log_warning "$(tf amnezia_err_state "$sdir")"
    fi

    # 5. Канонические файлы state/ — ПОСЛЕ state_sync, а не до него: sync
    # подменяет каталог целиком тем, что лежит в контейнере, и раньше стирал
    # эти же файлы. У legacy-контейнера приложения конфиг называется wg0.conf, а
    # ключей сервера отдельными файлами может не быть вовсе — после подхвата
    # профиль оставался без awg0.conf и без приватного ключа, и любая операция,
    # переписывающая конфиг (set-param, subnet, mtu, user-add, бэкап), падала с
    # state_missing. Приватный и публичный ключи у нас уже разобраны из конфига.
    # Теперь и сам sync кладёт wg0.conf под awg0.conf и берёт ключ из конфига — на
    # каждой синхронизации, не только здесь (ga_amn_state_canon, ACC-4); этот шаг —
    # для сухого прогона и сорвавшейся синхронизации.
    # Чтение — и у остановленного контейнера (docker cp): такие теперь подхватываются (TK-4).
    docker_read_file_any "$container" "$(ga_import_conf_path_for "$container")" 2>/dev/null | ga_amn_write_secret "$sdir/awg0.conf" \
        || { ga_err state_failed "$(tf amnezia_err_state "$sdir")"; _ga_import_adopt_undo "$profile" "$sdir" "$state_existed" "$added"; return 1; }
    printf '%s\n' "$priv" | ga_amn_write_secret "$sdir/$GA_AWG_SERVER_PRIV"
    printf '%s\n' "$pub"  | ga_amn_write_secret "$sdir/$GA_AWG_SERVER_PUB"
    psk_file=$(docker_read_file_any "$container" "$GA_AWG_DIR/$GA_AWG_PSK" 2>/dev/null | tr -d '[:space:]')
    [ -n "$psk_file" ] && printf '%s\n' "$psk_file" | ga_amn_write_secret "$sdir/$GA_AWG_PSK"
    docker_read_file_any "$container" "$GA_AWG_CLIENTS_TABLE" 2>/dev/null | ga_amn_write_secret "$sdir/clientsTable" || true
    [ -s "$sdir/clientsTable" ] || printf '[]\n' | ga_amn_write_secret "$sdir/clientsTable"

    ga_audit "${GOAMNEZIA_WHO:-ssh}" "import-adopt" "$container profile=$profile line=$line users=$n"
    log_success "$(tf import_adopted "$container" "$profile" "$n")"
    [ "$n" -gt 0 ] && log_info "$(t import_hint_no_privkey)"
    # Подсеть совпала с другим профилем (SUBNET-01) — подхвачен как есть; словами — с кем и какой выход, в ответе —
    # запись subnet_overlap (её же показывают экраны подсети SSH, панели и бота).
    local ovl
    ovl=$(ga_amn_subnet_overlap_of "$profile") || ovl=null
    [ -n "$ovl" ] || ovl=null
    if [ "$ovl" != null ]; then
        log_warning "$(t import_adopted_overlap) $(ga_amn_subnet_overlap_text "$ovl")"
    fi

    # 6. Остановленный контейнер — запускаем: под управлением профиль и так поднял бы сторож (через две минуты,
    # молча), а человеку, который подхватывал его, чтобы люди снова подключались, лучше увидеть итог сразу.
    # Не поднялся (порт занял кто-то другой, пока он стоял) — подхват всё равно состоялся: профиль виден в
    # «Протоколах», причина названа, сторож будет пробовать сам.
    local was started=null
    was=$(jq -r '.state // "running"' <<<"$entry")
    if [ "$was" = exited ]; then
        if docker_start "$container" && ga_amn_wait_up "$profile"; then
            started=true
            log_success "$(tf import_started "$container" "$profile")"
        else
            started=false
            log_warning "$(tf import_start_failed "$container" "${GA_ERR_MSG:-$(t import_start_failed_why)}")"
            GA_ERR_CODE=""; GA_ERR_MSG=""
        fi
    else
        # Работающий контейнер приложения — изоляция клиентов сразу, в его сетевом пространстве; start.sh
        # приложения не трогаем, после его перезапусков правило докладывает сторож (SEC-NET-1). Запущенный
        # выше получил его при подъёме (ga_amn_wait_up).
        ga_amn_isolation_apply "$profile" \
            || log_warning "$(tf amnezia_warn_isolation_failed "$profile" "$container")"
    fi
    # I1 по умолчанию приложения Amnezia (<r 2><b 0x…>) KeeneticOS 5.1 не принимает (KEENETIC-I1): у подхваченного
    # профиля он становится универсальным тем же путём, что при обновлении (ga_amn_i1_universal) — клиентский параметр,
    # без рестарта, люди приложения подключаются как прежде. Свой I1 не трогается. Предупреждения о тегах — по тому, что
    # стало.
    local i1conv="" pnow
    ga_capture i1conv ga_amn_i1_universal "$profile" || i1conv=""
    if [ -n "$i1conv" ]; then
        pnow=$(ga_config_get ".profiles.$profile.params" 2>/dev/null | jq -c 'if type == "object" then . else {} end' 2>/dev/null)
        [ -n "$pnow" ] && ipk_warn=$(ga_amn_ipacket_warnings "$pnow")
    fi
    # Теги I1–I5, которые понимает не каждая реализация (KMOD-02), — предупреждением: в SSH строкой, мосту, боту и
    # панели — полем ipacket_warnings (слова на языке сервера).
    local wl
    while IFS= read -r wl; do [ -n "$wl" ] && log_warning "$wl"; done <<<"$ipk_warn"
    while IFS= read -r wl; do [ -n "$wl" ] && log_warning "$wl"; done <<<"$lim_warn"
    jq -cn --arg p "$profile" --arg c "$container" --arg line "$line" --argjson port "$port" --arg subnet "$subnet" \
        --arg iface "$iface" --arg tag "$tag" --arg digest "$digest" --argjson added "$added" --argjson n "$n" \
        --argjson peers "$(jq -r 'length' <<<"$peers")" --arg hint "$(t import_hint_no_privkey)" --arg snap "$snap" \
        --arg was "$was" --argjson started "$started" --argjson ovl "$ovl" --arg ipkw "$ipk_warn" --arg limw "$lim_warn" '
        {profile: $p, container: $c, line: $line, port: $port, subnet: $subnet, iface: $iface, image_tag: $tag,
         image_digest: $digest, users_added: $n, users: $added, peers: $peers, hint: $hint, snapshot: $snap,
         state_before: $was, started: $started, subnet_overlap: $ovl,
         ipacket_warnings: ($ipkw | split("\n") | map(select(length > 0))),
         param_warnings: ($limw | split("\n") | map(select(length > 0)))}'
}

# ── import_reconcile ──────────────────────────────────────────────────────────

# import_reconcile <профиль> [apply] → stdout JSON {profile, container, in_sync,
# new: [{pubkey, name, ip}], gone: [{name, pubkey}], skipped: [{key, reason, message}],
# applied, added, deactivated, users}.
# Без apply — только сверка (ничего не пишет). С apply — новые пиры контейнера
# становятся импортированными пользователями, исчезнувшие пиры помечаются
# active=false (запись остаётся — человек решает, что с ней делать).
# Новые — только те, кого подхват возьмёт (ga_import_peers_sort). Пир, которого
# не подхватить (не ключ, ключ другого профиля, нет IPv4), — в skipped: key —
# начало его ключа (ga_peer_tag), reason — key | taken | ip, message — строка о
# пропуске на языке сервера (её же видно в SSH). Расхождением он не считается:
# иначе профиль навсегда оставался «разошедшимся», и меню на каждом старте
# зря спрашивало «Подхватить?» (KEENETIC-I1-N, N2).
import_reconcile() {
    if [ "${2:-}" = apply ]; then ga_with_config_lock _import_reconcile_locked "$@"; else _import_reconcile_locked "$@"; fi
}
_import_reconcile_locked() {
    local profile="$1" mode="${2:-}" container conf live known new gone in_sync=true applied=false added='[]' n=0 d=0 state
    local peers clients users name sorted skipped='[]' sk_tag sk_why sk_msg
    ga_profile_check_installed "$profile" || return $?
    container=$(ga_profile_field "$profile" container)
    ga_capture state docker_container_state "$container"
    ga_amn_docker_up "$state" || return 1
    if [ "$state" = "missing" ]; then
        ga_err container_missing "$(tf import_err_container_missing "$container")" 3
        return 3
    fi
    # PSK — и без apply (N2): годность пира (PresharedKey — ключ ли) решается так же, как при подхвате, иначе сверка
    # звала бы новым того, кого подхват пропустит. Секреты — только в памяти: в ответ идут ключ, адрес и подпись.
    if ! conf=$(ga_import_parse_conf "$container" 1) || [ -z "$conf" ]; then
        ga_err conf_read_failed "$(tf import_err_conf_read "$container")"
        return 1
    fi
    live=$(jq -c '[.peers[]? | {pubkey, ip: (.ip // ""), psk: (.psk // "")}]' <<<"$conf")
    # На битом файле список своих пиров оказывался пустым, и сверка объявляла
    # чужими всех до единого — с советом их подхватить.
    ga_users_load users || { ga_err users_corrupt "$(t users_err_corrupt)"; return 1; }
    known=$(jq -c --arg p "$profile" '[.users[]? | select(.peers[$p] != null) | {name, pubkey: .peers[$p].pubkey, active: (.peers[$p].active // false), enabled}]' <<<"$users")
    clients=$(ga_import_clients_map "$container")
    sorted=$(ga_import_peers_sort "$profile" "$live" "$users") || return 1
    new=$(jq -c --argjson m "$clients" '[.[] | select(.skip == "") | {pubkey, ip, name: (($m[.pubkey] // {}).name // "")}]' <<<"$sorted")
    # Пропущенные — со строкой на языке сервера: SSH печатает её здесь, панель и бот берут из ответа.
    while IFS=$'\x1f' read -r sk_why sk_tag; do
        [ -n "$sk_why" ] || continue
        sk_msg=$(tf "import_peer_skipped_$sk_why" "$sk_tag")
        skipped=$(jq -c --arg k "$sk_tag" --arg r "$sk_why" --arg m "$sk_msg" '. + [{key: $k, reason: $r, message: $m}]' <<<"$skipped")
    done < <(jq -r '.[] | select(.skip == "key" or .skip == "taken" or .skip == "ip") | [.skip, .tag] | join("\u001f")' <<<"$sorted")
    # Исчез из контейнера пир, который у нас числится активным (выключенные
    # нами и так вне конфига — это не расхождение).
    # В argv jq — только открытые ключи пиров: в $live и PSK, а argv виден всем в /proc (SR-17).
    gone=$(jq -c --argjson lp "$(jq -c 'map(.pubkey)' <<<"$live")" '
        [.[] | select(.active == true and .enabled == true and (.pubkey as $k | ($lp | index([$k])) == null))
           | {name, pubkey}]' <<<"$known")
    if [ "$(jq -r 'length' <<<"$new")" != 0 ] || [ "$(jq -r 'length' <<<"$gone")" != 0 ]; then
        in_sync=false
    fi
    if [ "$in_sync" = true ]; then
        log_dim "$(tf import_reconcile_in_sync "$profile")"
    else
        log_warning "$(tf import_reconcile_diff "$profile" "$(jq -r 'length' <<<"$new")" "$(jq -r 'length' <<<"$gone")")"
    fi
    # GA_RECONCILE_QUIET_SKIPPED=1 — вызывающий уже показал эти строки (SSH «Подхватить?» — до вопроса; V4): в ответе
    # skipped[] остаётся, на stderr второй раз не печатается.
    if [ "${GA_RECONCILE_QUIET_SKIPPED:-}" != 1 ]; then
        while IFS= read -r sk_msg; do [ -n "$sk_msg" ] && log_warning "$sk_msg"; done < <(jq -r '.[].message' <<<"$skipped")
    fi
    if [ "$mode" = apply ] && [ "$in_sync" = false ]; then
        peers=$(jq -c --argjson new "$new" '($new | map(.pubkey)) as $np | [.[] | select(.pubkey as $k | ($np | index([$k])) != null)]' <<<"$live")
        ga_capture added ga_import_users_add "$profile" "$peers" "$clients" || return 1
        n=$(jq -r 'length' <<<"$added")
        users=$(ga_users_json)
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            users=$(jq -c --arg n "$name" --arg p "$profile" '.users |= map(if .name == $n then .peers[$p].active = false else . end)' <<<"$users")
            d=$((d + 1))
        done < <(jq -r '.[].name' <<<"$gone")
        if [ "$d" -gt 0 ]; then
            printf '%s' "$users" | ga_users_write || { ga_err users_write_failed "$(t users_err_write)"; return 1; }
        fi
        # Копия состояния — с контейнера: он теперь источник правды по пирам.
        if ! ga_dry; then amnezia_state_sync "$profile" || true; fi
        applied=true
        ga_audit "${GOAMNEZIA_WHO:-ssh}" "import-reconcile" "$profile added=$n deactivated=$d"
        log_success "$(tf import_reconcile_applied "$profile" "$n" "$d")"
    fi
    # KEENETIC-I1-R (R2): после сверки люди приложения — свои, и пропуск миграции I1 «в контейнере чужие люди» снят.
    # I1 прежнего умолчания (<r 2><b 0x…>) — в универсальный тем же путём, что при обновлении и подхвате
    # (ga_amn_i1_universal): клиентский параметр, без рестарта, мы уже под замком конфига. Сверка к этому моменту
    # прошла: замена не прошла — только строка-предупреждение (её печатает ga_amn_i1_universal), ответ и код сверки
    # прежние. Свой I1 и уже универсальный не трогаются — тогда ни строки, ни записи.
    if [ "$mode" = apply ]; then
        local i1conv=""
        ga_capture i1conv ga_amn_i1_universal "$profile" || i1conv=""
        if [ -n "$i1conv" ]; then log_dim "$(tf mig_i1_universal "$profile")"; fi
    fi
    jq -cn --arg p "$profile" --arg c "$container" --argjson sync "$in_sync" --argjson new "$new" --argjson gone "$gone" \
        --argjson applied "$applied" --argjson n "$n" --argjson d "$d" --argjson added "$added" --argjson sk "$skipped" '
        {profile: $p, container: $c, in_sync: $sync, new: $new, gone: $gone, skipped: $sk, applied: $applied,
         added: $n, deactivated: $d, users: $added}'
}
