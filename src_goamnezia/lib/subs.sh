#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# goAmnezia pro — lib/subs.sh: подписка, постоянная ссылка на человека (docs/SUBSCRIPTION.md)
#
# Решение владельца 03.10.2026: приём ссылки так, «чтобы работало и для 1.5, и для 2, и для 3.1, формат — как
# забирает mihomo». Подписка — одна постоянная секретная ссылка на человека, суффикс <какие линии>.<формат> выбирает
# формат и линию (каталог форматов — docs/SUBSCRIPTION.md):
#   https://<домен>/s-<секрет>/all.yaml         профиль mihomo со всеми линиями человека — главный формат
#                                               (Clash Verge Rev, FlClash, Mihomo Party, Clash Meta for Android);
#   …/all.txt                                   ссылки amneziawg:// всех линий — подписка incy и AWG Manager;
#   …/awg15.conf, awg20.conf, awg31.conf, awg10.conf  .conf линии (роутер, WG Tunnel, INCY, AmneziaWG);
#   …/awg15.vpn, awg20.vpn, awg31.vpn, awg10.vpn      ключ vpn:// линии, all.vpn — ключи всех линий;
#   синонимы: mihomo.yaml = all.yaml (прежнее имя, уже выдано), awgv15 / awgv2 / awgv3 = awg15 / awg20 / awg31 —
#   рабочие, но в urls и clients их нет.
# Суффикс выбирает ЛИНИЮ, а не профиль: у человека берётся первый профиль этой линии в порядке продукта
# (awg3 → awg2 → awg1) с ключом на сервере; такой линии у него нет — 404, и роутер оставит прежний конфиг.
#
# Модель. Подписка — каталог $(ga_subs_dir)/<имя>/ (0700; по умолчанию /opt/goamnezia/subs):
#   meta.json   0600  user, user_created, created, rotated, generation; после перевыпуска — prev_fetches, prev_last_fetch
#                     (заборы прежнего адреса: счёт в state.json перевыпуск обнуляет)
#   secret      0600  43 символа base64url = 32 случайных байта (256 бит): путь И ЕСТЬ ключ
#   state.json  0600  заборы без адресов: fetches, auto_fetches, last_fetch, last_suffix, last_client, audited (пишет служба)
#   state.lock  0600  пустой: замок заборов (flock) — служба на запись забора, ядро на перевыпуск (Н-5)
# Секрет хранится открытым, как у страниц и доступов агентов: адрес можно показать снова (второе устройство,
# новый роутер). Каталог уходит в бэкап (lib/backup.sh): после переезда на тот же домен роутеры работают дальше.
#
# Отдаёт подписку служба страниц подключения (lib/pages_server.py, goamnezia-pages) за своей локацией nginx
# (site.subs_location → _ga_site_subs_block в lib/website.sh) — только сайт на домене с сертификатом
# Let's Encrypt. Ключи служба берёт у моста при каждом заборе (кеш 60 с): перевыпуск ключа, смена порта,
# параметров и адреса меняют тело, а не адрес. Новый адрес — только «Перевыпустить подписку» (sub-rotate).
#
# Состояния. Выключенный человек — 404: пир снят на сервере, у роутера остаётся прежний конфиг, после включения
# всё работает само. Удаление человека снимает подписку под тем же замком (_users_del_locked →
# _subs_revoke_locked; массовое удаление зовёт ту же точку), сторож тика добирает осиротевшие. Сайт ушёл с
# домена — подписки на паузе: маршрут снят, секреты хранятся; вернулся на домен — адреса ожили (путь тот же,
# хост — нынешний домен). Создать подписку без домена нельзя: subs_need_domain, как у страниц.
#
# Правила модуля (контракт §0) — как у lib/pages.sh:
#   • stdout — только JSON у публичных функций; всё для человека — stderr, словарь lib/lang/<lang>.d/subs.sh;
#   • мутации — под ga_with_config_lock, пара fn() / _fn_locked();
#   • коды через ga_err: subs_need_domain, invalid_name, user_not_found, peer_not_found, no_private_key,
#     sub_not_found, write_failed, unit_failed, no_jq, no_python, module_missing и коды lib/website.sh;
#   • СЕКРЕТ не пишется ни в лог, ни в аудит, ни в sub-list. Аудит: sub-create, sub-show, sub-rotate,
#     sub-revoke; sub-fetch пишет сама служба (раз в час на подписку, без адреса забиравшего). Адрес уходит в
#     jq окружением, не аргументом (SEC46-02). Агентам MCP адресов не даём: у sub-create, sub-show и sub-rotate
#     в actions.json "mcp": null, агенту — только sub-list без адресов;
#   • GOAMNEZIA_DRY_RUN=1 — как у страниц: systemctl печатается «DRY: …», каталог подписок пишется по-настоящему.
# ══════════════════════════════════════════════════════════════════════════════

GA_SUBS_SECRET_RE='^[A-Za-z0-9_-]{43}$'
GA_SUBS_NAME_RE='^[A-Za-z0-9_-]{1,32}$'
# Линии в порядке продукта (3.1 → 2.0 → 1.5 → 1.0) и профили, в которых их ищем у человека.
GA_SUBS_LINES="3.1 2.0 1.5 1.0"
GA_SUBS_PROFILES="awg3 awg2 awg1"
# Часы между заборами, которые подписка советует клиентам (Profile-Update-Interval); subs.update_interval в
# config.json — от 1 до 168.
GA_SUBS_UPDATE_HOURS=12
# Каталог без meta.json моложе этого — подписка ещё создаётся, старше — обломок неудачного создания.
GA_SUBS_START_GRACE=60
# Суффиксы, у которых бывает короткая ссылка (lib/shortlinks.py, SUFFIXES): канонические имена, без синонимов.
GA_SHORT_SUFFIX_RE='^(all\.(yaml|txt|vpn)|awg(31|20|15|10)\.(conf|vpn))$'
# Список клиентов в ответе (clients, ga_subs_clients_json): устройства — те же, что у вкладки «Подписка» страницы
# (SUB_PLATFORMS в lib/pages_server.py: все устройства, с телевизорами), и запись продуктов серии, которых нет в
# каталоге приложений: их пул «Прокси для API Telegram» берёт all.vpn.
GA_SUBS_PLATFORMS='["ios","android","android_tv","tvos","windows","macos","linux","router"]'
GA_SUBS_EGRESS='{"id":"egress","app":"egress","name":"goVLESS, Kaskad, goTelegram","name_en":"","variant":"",
"group":"once","format":"vpn",
"platforms":[],"update_hours":0,"official":false,"recommended":false,"hint":{
"ru":"Пул «Прокси для API Telegram» в goVLESS, Kaskad и goTelegram: добавьте ссылку как подписку — продукт заберёт ключи vpn:// всех линий",
"en":"The “Telegram API proxy” pool in goVLESS, Kaskad and goTelegram: add the link as a subscription — the product takes the vpn:// keys of every line"}}'
_GA_SUBS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Запасные помощники: модуль подключают и без lib/pages.sh ─────────────────
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
if ! type ga_capture >/dev/null 2>&1; then
    ga_capture() {
        local __var="$1"; shift
        local __tmp __rc=0
        __tmp=$(mktemp "${TMPDIR:-/tmp}/.gacap.XXXXXXXX") || return 1
        "$@" >"$__tmp" || __rc=$?
        printf -v "$__var" '%s' "$(<"$__tmp")"
        rm -f "$__tmp" 2>/dev/null || true
        return "$__rc"
    }
fi
# Аудит теми же именами, что у действий моста; секрет в подробности не попадает никогда.
ga_subs_audit() {
    type ga_audit >/dev/null 2>&1 || return 0
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "$1" "${2:-}"
}

# ── Пути и настройки: функциями, стенды выставляют GOAMNEZIA_* после подключения модуля ──
ga_subs_dir() { printf '%s' "${GOAMNEZIA_SUBS_DIR:-${GOAMNEZIA_DIR:-/opt/goamnezia}/subs}"; }
ga_subs_domain() { ga_config_get .domain 2>/dev/null || printf ''; }
# Каталог приложений (lib/clients.json) — тот же, что у страницы подключения
ga_subs_catalog() {
    if type ga_pages_clients_json >/dev/null 2>&1; then ga_pages_clients_json; return 0; fi
    printf '%s' "${GOAMNEZIA_CLIENTS_JSON:-$_GA_SUBS_LIB_DIR/clients.json}"
}
# Подписке нужен тот же сайт, что странице: домен с настоящим сертификатом — роутер и клиент забирают адрес
# без исключений для сертификата, а самоподписанный приучал бы людей их делать.
ga_subs_domain_ready() {
    if type ga_pages_domain_ready >/dev/null 2>&1; then ga_pages_domain_ready; return $?; fi
    if type ga_site_domain_ready >/dev/null 2>&1; then ga_site_domain_ready; return $?; fi
    [ "$(ga_config_get .site.cert 2>/dev/null)" = letsencrypt ] && [ -n "$(ga_subs_domain)" ]
}
ga_subs_update_hours() {
    local h
    h=$(ga_config_get .subs.update_interval 2>/dev/null) || h=""
    [[ "$h" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$h))" -ge 1 ] && [ "$((10#$h))" -le 168 ] || h="$GA_SUBS_UPDATE_HOURS"
    # Ведущий ноль — десятичное: «012» — 12 часов, как у службы страниц (lib/pages_server.py update_hours). Без 10#
    # «012» в $(( )) было восьмеричным 10, а «08» — ошибкой, и выбор приложений в sub-show пропадал (CR-5).
    printf '%s' "$((10#$h))"
}
# ga_subs_update_slow <часы> → [{name, hours}]: приложения каталога, которые обновляют подписку сами и реже, чем
# советует сервер (subscription.update_hours больше Profile-Update-Interval: заголовок они не слушают; FlClash — раз в
# сутки). Окна перевыпуска ключа называют их срок, а не только совет сервера (A4-3/B4-4). Одно имя — один раз (с
# наибольшим сроком), по убыванию часов, затем по имени. Каталога нет или он не разобрался — [].
ga_subs_update_slow() {
    local h="${1:-0}" catalog
    catalog=$(ga_subs_catalog)
    [ -r "$catalog" ] || { printf '[]'; return 0; }
    jq -c --argjson h "$((10#$h))" '[(.apps // [])[] | .name as $n | (.subscription // null)
        | (if type == "array" then .[] else . end) | select(type == "object")
        | (.update_hours // 0) | select(type == "number" and . > $h) | {name: $n, hours: .}]
        | group_by(.name) | map(max_by(.hours)) | sort_by([-.hours, .name])' "$catalog" 2>/dev/null || printf '[]'
}
ga_subs_check_name() {
    [[ "${1:-}" =~ $GA_SUBS_NAME_RE ]] && return 0
    ga_err invalid_name "$(tf subs_err_name "${1:-}")" 2
    return 2
}
ga_subs_iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# Линия → суффикс адреса: 3.1 → awg31.
ga_subs_token() {
    case "${1:-}" in
        1.0) printf 'awg10' ;;
        1.5) printf 'awg15' ;;
        2.0) printf 'awg20' ;;
        3.1) printf 'awg31' ;;
        *) return 1 ;;
    esac
}

# ── Секрет ───────────────────────────────────────────────────────────────────
# 32 случайных байта → 43 знака base64url, как у страниц (ga_pages_new_secret) и доступов агентов.
ga_subs_new_secret() {
    local s=""
    s=$(openssl rand -base64 32 2>/dev/null | tr '+/' '-_' | tr -d '=\n')
    if ! [[ "$s" =~ $GA_SUBS_SECRET_RE ]]; then
        s=$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')
    fi
    [[ "$s" =~ $GA_SUBS_SECRET_RE ]] || return 1
    printf '%s' "$s"
}
# Секрет подписки из её каталога в stdout; негодный или нет файла — код 1.
ga_subs_secret_of() {
    local d="$1" s
    s=$( { tr -d '[:space:]' <"$d/secret"; } 2>/dev/null ) || return 1
    [[ "$s" =~ $GA_SUBS_SECRET_RE ]] || return 1
    printf '%s' "$s"
}
# Записать секрет: временный файл рядом и mv — служба читает каталог в любой момент и не должна увидеть
# полупустой секрет; прежний (при перевыпуске) перед заменой затирается.
_ga_subs_write_secret() {
    local d="$1" secret="$2"
    (umask 077; printf '%s' "$secret" >"$d/.secret.tmp") || { rm -f "$d/.secret.tmp"; return 1; }
    if [ -f "$d/secret" ] && type ga_wipe_file >/dev/null 2>&1; then ga_wipe_file "$d/secret"; fi
    mv -f "$d/.secret.tmp" "$d/secret" || { rm -f "$d/.secret.tmp"; return 1; }
    chmod 600 "$d/secret" 2>/dev/null || true
}
_ga_subs_write_meta() {
    local d="$1" meta="$2"
    (umask 077; printf '%s\n' "$meta" >"$d/.meta.tmp" && mv -f "$d/.meta.tmp" "$d/meta.json") || {
        rm -f "$d/.meta.tmp"; return 1; }
}
# _ga_subs_reset_state <каталог> — счёт заборов нового адреса (после перевыпуска): нули, без last_*.
_ga_subs_reset_state() {
    local d="$1"
    (umask 077; printf '%s\n' '{"fetches": 0, "auto_fetches": 0}' >"$d/.state.tmp" && mv -f "$d/.state.tmp" "$d/state.json") || {
        rm -f "$d/.state.tmp"; return 1; }
}

# ── Состояние подписок ───────────────────────────────────────────────────────
# Каталог без meta.json: подписка ещё создаётся (свежий каталог) или обломок.
ga_subs_starting() {
    local d="$1" mt now
    mt=$( { stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null; } ) || return 1
    [[ "$mt" =~ ^[0-9]+$ ]] || return 1
    now=$(date -u +%s)
    [ $((now - mt)) -lt "$GA_SUBS_START_GRACE" ]
}
# Сколько подписок заведено (с meta.json или рождающихся).
ga_subs_count() {
    local dir d n=0
    dir=$(ga_subs_dir)
    if [ -d "$dir" ]; then
        for d in "$dir"/*; do
            [ -d "$d" ] || continue
            [[ "$(basename "$d")" =~ $GA_SUBS_NAME_RE ]] || continue
            { [ -f "$d/meta.json" ] || ga_subs_starting "$d"; } && n=$((n + 1))
        done
    fi
    printf '%s' "$n"
}
# Есть ли у человека подписка (meta.json и секрет на месте).
ga_subs_exists() {
    local d
    d="$(ga_subs_dir)/${1:-}"
    [[ "${1:-}" =~ $GA_SUBS_NAME_RE ]] && [ -f "$d/meta.json" ] && [ -f "$d/secret" ]
}
# _ga_subs_owner_gone <каталог> → 0, только если users.json читается и владельца подписки в нём нет: имени нет
# вовсе или под этим именем теперь другой человек (метка user_created не совпала) — тёзка, заведённый после
# удаления владельца, ключей по чужой ссылке не получит (SR-05, SEC-G3; служба отвечает таким 404 тем же
# правилом). Не прочитался users.json — не повод рушить подписки.
_ga_subs_owner_gone() {
    local d="$1" f rc
    f="${USERS_FILE:-${GOAMNEZIA_DIR:-/opt/goamnezia}/users.json}"
    [ -r "$f" ] && [ -r "$d/meta.json" ] || return 1
    jq -e --slurpfile m "$d/meta.json" '
        ($m[0].user // "") as $n | ($m[0].user_created // "") as $want
        | if $n == "" then false
          else ((.users // []) | map(select(.name == $n)) | first) as $u
          | if $u == null then true
            elif $want != "" then ($u.created // "") != $want
            else false end
          end' "$f" >/dev/null 2>&1; rc=$?
    [ "$rc" = 0 ]
}
# ga_subs_drop <каталог> <причина> — снять подписку. Секрет затирается первым: с этой секунды адрес мёртв,
# даже если остальное не удалилось. Причина — в аудит: revoked (по действию), user-del (удалён человек),
# owner_gone (сторож тика: владельца нет).
ga_subs_drop() {
    local d="$1" reason="${2:-revoked}" user
    [ -d "$d" ] || return 0
    user=$(basename "$d")
    # Короткие ссылки подписки — в кладбище до того, как каталог уйдёт (docs/SUBSCRIPTION.md §11)
    _ga_subs_short_kill "$d" "$reason"
    if type ga_wipe_file >/dev/null 2>&1; then ga_wipe_file "$d/secret"; fi
    rm -f "$d/secret" 2>/dev/null || true
    rm -rf "$d" 2>/dev/null || true
    ga_subs_audit sub-revoke "user=${user} reason=${reason}"
    return 0
}
# ga_subs_sweep → stdout число снятых. Только под замком (subs_tick, создание): обломки неудачного создания и
# подписки, чей владелец ушёл (удалён до этой версии, тёзка).
ga_subs_sweep() {
    local dir d n=0
    dir=$(ga_subs_dir)
    [ -d "$dir" ] || { printf '0'; return 0; }
    for d in "$dir"/*; do
        [ -d "$d" ] || continue
        [[ "$(basename "$d")" =~ $GA_SUBS_NAME_RE ]] || continue
        if [ ! -f "$d/meta.json" ]; then
            ga_subs_starting "$d" && continue
            rm -rf "${d:?}" 2>/dev/null || true
            n=$((n + 1))
            continue
        fi
        if _ga_subs_owner_gone "$d"; then
            ga_subs_drop "$d" owner_gone
            n=$((n + 1))
        fi
    done
    printf '%s' "$n"
}

# ga_subs_lines_json <имя> → JSON-массив линий за подпиской, в порядке продукта:
#   [{line, token, profile, has_key, active}]
# По каждой линии — первый установленный профиль человека этой линии с ключом на сервере (awg3 → awg2 → awg1);
# у всех профилей линии ключ из приложения Amnezia — первый из них с has_key: false (по суффиксу — 404).
# Линия — ga_profile_line: та же, которой подписан ключ в user-key (у подхваченного контейнера она бывает
# старше, чем подсказывает имя профиля). Это же правило у службы (lib/pages_server.py, sub_lines).
ga_subs_lines_json() {
    local name="$1" card p line rows='[]' has_key active
    card=$(ga_users_get "$name" 2>/dev/null) || card=""
    [ -n "$card" ] || { printf '[]'; return 0; }
    for p in $GA_SUBS_PROFILES; do
        jq -e --arg p "$p" '(.peers // {})[$p] != null' <<<"$card" >/dev/null 2>&1 || continue
        type ga_profile_installed >/dev/null 2>&1 && { ga_profile_installed "$p" || continue; }
        line=$(ga_profile_line "$p" 2>/dev/null) || line=""
        [[ "$line" =~ ^(1\.0|1\.5|2\.0|3\.1)$ ]] || continue
        has_key=$(jq -r --arg p "$p" 'if (((.peers // {})[$p].privkey // "") != "") then "true" else "false" end' <<<"$card" 2>/dev/null)
        active=$(jq -r --arg p "$p" 'if (.enabled == false or (.peers // {})[$p].active == false) then "false" else "true" end' <<<"$card" 2>/dev/null)
        rows=$(jq -c --arg p "$p" --arg l "$line" --argjson k "${has_key:-false}" --argjson a "${active:-true}" \
            '. + [{line: $l, profile: $p, has_key: $k, active: $a}]' <<<"$rows") || rows='[]'
    done
    jq -c '. as $all
        | [ ("3.1", "2.0", "1.5", "1.0") as $l
            | ($all | map(select(.line == $l))) as $c
            | select(($c | length) > 0)
            | ((($c | map(select(.has_key)) | first) // $c[0])
               + {token: ({"1.0": "awg10", "1.5": "awg15", "2.0": "awg20", "3.1": "awg31"}[$l])}) ]' <<<"$rows" 2>/dev/null \
        || printf '[]'
}

# ga_subs_urls_json <секрет> <JSON линий> → JSON {base_url, urls: [{suffix, format, line, url}]}: all.yaml (профиль
# mihomo, формат mihomo) первым, all.txt (ссылки amneziawg:// всех линий — подписка incy, формат incy), затем .conf и
# vpn:// каждой линии с ключом, all.vpn последним; синонимов (mihomo.yaml, awgv*) нет. Без домена (подписка на паузе) —
# пусто. Секрет и адрес — окружением, не аргументами jq (SEC46-02).
ga_subs_urls_json() {
    local secret="$1" lines="${2:-[]}" domain
    domain=$(ga_subs_domain)
    if [ -z "$domain" ] || ! ga_subs_domain_ready; then
        printf '{"base_url":"","urls":[]}'
        return 0
    fi
    GA_S_BASE="https://${domain}/s-${secret}/" jq -c '
        $ENV.GA_S_BASE as $b
        | [ .[] | select(.has_key) ] as $k
        | {base_url: $b,
           urls: (if ($k | length) == 0 then [] else
                    [{suffix: "all.yaml", format: "mihomo", line: ""}, {suffix: "all.txt", format: "incy", line: ""}]
                    + [ $k[] | {suffix: "\(.token).conf", format: "conf", line: .line} ]
                    + [ $k[] | {suffix: "\(.token).vpn", format: "vpn", line: .line} ]
                    + [{suffix: "all.vpn", format: "vpn", line: ""}]
                  end | map(. + {url: ($b + .suffix)}))}' <<<"$lines"
}

# ga_subs_clients_json <base_url> <JSON линий> <подпись> → JSON-массив clients — кто какой адрес берёт (по нему панель,
# мини-апп, бот и SSH показывают адреса; форма — docs/SUBSCRIPTION.md, «Каталог форматов»; менять её только вместе с
# ними): приложения с полем subscription каталога (lib/clients.json) и запись продуктов серии (GA_SUBS_EGRESS).
#   {id, app, name, name_en, variant, group: auto|once, format: yaml|txt|vpn|conf, platforms, update_hours, official,
#    recommended, hint{ru,en}, items: [{line, suffix, url, deeplink, command, copy: url|key|command,
#    qr: url|deeplink|key|"", qr_alt: url|"", key_format: vpn|conf|"", short_url}]}
# short_url — короткая ссылка этого суффикса (docs/SUBSCRIPTION.md §11), если код уже создан, иначе "": карта
# суффикс → адрес приходит окружением GA_S_SHORT (в ней коды — как и адрес, не аргументом, SEC46-02).
# У приложения с несколькими форматами (subscription — список, AWG Manager) — запись на формат: id <app>-<формат>, app —
# id приложения для группировки, variant — подпись формата; у остальных id = app, variant "". copy — что копирует
# «Скопировать» (адрес, сам ключ линии или команда), qr_alt — второй QR рядом (у incy — голый адрес), key_format — при
# qr или copy = key. Платформы — GA_SUBS_PLATFORMS, у которых приложение берёт хоть одну линию человека; у разового
# (vpn, conf) — items по линиям из subscription.lines, которые у человека есть и которые приложение хоть на одной его
# платформе не помечает «no». Ссылка «Открыть в …» — как на странице: install-config — адрес и подпись в процентной
# кодировке, иначе {url} — адрес как есть, {host_path} — без https://; команда роутера — с Wireguard9, {minutes} в
# подсказке — интервал сервера, как на странице. Порядок — auto, затем once (профиль mihomo, txt, vpn, conf; внутри —
# как в каталоге), продукты серии — последними. Клиента без items нет в списке; адреса нет (пауза) или ключей нет — [].
# Адрес — окружением, не аргументом jq (SEC46-02).
ga_subs_clients_json() {
    local base="$1" lines="${2:-[]}" label="${3:-}" catalog hours
    catalog=$(ga_subs_catalog)
    if [ -z "$base" ] || [ ! -r "$catalog" ]; then
        printf '[]'
        return 0
    fi
    hours=$(ga_subs_update_hours)
    GA_S_BASE="$base" jq -c --slurpfile c "$catalog" --argjson lines "$lines" --arg name "$label" \
        --argjson minutes "$((10#$hours * 60))" --argjson plats "$GA_SUBS_PLATFORMS" --argjson egress "$GA_SUBS_EGRESS" -n '
        def tokens: {"1.0": "awg10", "1.5": "awg15", "2.0": "awg20", "3.1": "awg31"};
        def files: {"mihomo": "yaml", "txt": "txt", "vpn": "vpn", "conf": "conf"};
        def rank: {"mihomo": 0, "txt": 1, "vpn": 2, "conf": 3};
        def link($tpl; $url):
            if ($tpl // "") == "" then ""
            elif ($tpl | test("^[a-z][a-z0-9+.-]*://install-config\\?")) then
                $tpl | gsub("\\{name\\}"; $name | @uri) | gsub("\\{minutes\\}"; $minutes | tostring)
                     | gsub("\\{url\\}"; $url | @uri)
            elif ($tpl | contains("{host_path}")) then $tpl | gsub("\\{host_path\\}"; $url | ltrimstr("https://"))
            elif ($tpl | contains("{url}")) then $tpl | gsub("\\{url\\}"; $url)
            else "" end;
        (($ENV.GA_S_SHORT // "{}") | (try fromjson catch {}) | if type == "object" then . else {} end) as $short
        | def item($line; $suffix; $s; $fmt):
            ($ENV.GA_S_BASE + $suffix) as $url
            | ($s.copy // "url") as $copy
            | {line: $line, suffix: $suffix, url: $url, deeplink: link($s.deeplink; $url),
               command: (if ($s.command // "") == "" then ""
                         else $s.command | gsub("\\{iface\\}"; "Wireguard9") | gsub("\\{url\\}"; $url) end),
               copy: $copy, qr: ($s.qr // ""), qr_alt: ($s.qr_alt // ""),
               key_format: (if ($s.qr // "") == "key" or $copy == "key" then $fmt else "" end),
               short_url: (($short[$suffix] // "") | tostring)};
        [ $lines[] | select(.has_key) | .line ] as $mine
        | if ($mine | length) == 0 then [] else
          ([ $c[0].apps | to_entries[]
             | .key as $i | .value as $a
             | (($a.subscription // null) | type == "array") as $multi
             | (if $multi then $a.subscription else [$a.subscription // null] end) as $subs
             | range(0; $subs | length) as $v | $subs[$v] as $s
             | select(($s | type) == "object" and rank[$s.format // ""] != null)
             | ($s.format == "vpn" or $s.format == "conf") as $once
             | files[$s.format] as $fmt
             | [ ($s.lines // [])[] | select(tokens[.] != null) ] as $takes
             | [ $plats[] as $p
                 | select(($a.platforms // {}) | has($p))
                 | select($s.platforms == null or ($s.platforms | index($p)) != null)
                 | ($a.platforms[$p].support // {}) as $sup
                 | select(any($mine[]; ($sup[.] // "unknown") != "no"))
                 | select(($once | not)
                          or any($takes[]; . as $l | ($mine | index($l)) != null and ($sup[$l] // "unknown") != "no"))
                 | {p: $p, sup: $sup} ] as $pl
             | select(($pl | length) > 0)
             | (if $once then
                  [ $takes[] as $l
                    | select(($mine | index($l)) != null and any($pl[]; (.sup[$l] // "unknown") != "no"))
                    | item($l; tokens[$l] + "." + $fmt; $s; $fmt) ]
                else [ item(""; "all." + $fmt; $s; $fmt) ] end) as $items
             | select(($items | length) > 0)
             | {i: $i, v: $v, r: rank[$s.format],
                c: {id: (($a.id // "") + (if $multi then "-" + $fmt else "" end)), app: ($a.id // ""),
                    name: ($a.name // ""), name_en: ($a.name_en // ""),
                    variant: (if $multi then ($s.variant.ru // "") else "" end),
                    group: (if $once then "once" else "auto" end), format: $fmt, platforms: [ $pl[].p ],
                    update_hours: (if $once then 0 else ($s.update_hours // 0) end), official: ($a.official == true),
                    recommended: ([ ($s.recommended // [])[] as $r | select(any($pl[]; .p == $r)) ] | length > 0),
                    hint: (($s.hint // {ru: "", en: ""}) | map_values(gsub("\\{minutes\\}"; $minutes | tostring))),
                    items: $items}} ]
           | sort_by([.r, .i, .v]) | map(.c))
          + [ $egress + {items: [ item(""; "all.vpn"; {}; "vpn") ]} ]
          end' 2>/dev/null || printf '[]'
}

# Строка состояния подписки без секрета: meta.json + заборы из state.json + линии и подпись человека.
ga_subs_row() {
    local d="$1" name card lines fetches last suffix client label enabled
    name=$(basename "$d")
    fetches=$(jq -r '.fetches // 0' "$d/state.json" 2>/dev/null); [[ "$fetches" =~ ^[0-9]+$ ]] || fetches=0
    last=$(jq -r '.last_fetch // ""' "$d/state.json" 2>/dev/null) || last=""
    suffix=$(jq -r '.last_suffix // ""' "$d/state.json" 2>/dev/null) || suffix=""
    client=$(jq -r '.last_client // ""' "$d/state.json" 2>/dev/null) || client=""
    card=$(ga_users_get "$name" 2>/dev/null) || card=""
    [ -n "$card" ] || card='{}'
    label=$(jq -r '.label // .name // ""' <<<"$card" 2>/dev/null) || label=""
    enabled=$(jq -r 'if (.enabled == false) then "false" else "true" end' <<<"$card" 2>/dev/null) || enabled=true
    lines=$(ga_subs_lines_json "$name")
    jq -c --arg n "$name" --arg lb "${label:-$name}" --argjson f "$fetches" --arg l "$last" --arg s "$suffix" \
        --arg c "$client" --argjson lines "${lines:-[]}" --argjson on "${enabled:-true}" \
        '{name: $n, label: $lb, created: (.created // ""), rotated: (.rotated // ""), generation: (.generation // 1),
          fetches: $f, last_fetch: $l, last_suffix: $s, last_client: $c, lines: $lines, disabled: ($on | not),
          prev_fetches: (.prev_fetches // 0), prev_last_fetch: (.prev_last_fetch // "")}' \
        "$d/meta.json" 2>/dev/null
}

# Ответ создания, показа и перевыпуска: строка состояния + адреса (base_url, urls) и кто какой берёт (clients), у
# пунктов clients — короткая ссылка (short_url), если код уже создан, и short_available — работают ли короткие ссылки
# (бот настроен: есть токен и хотя бы один администратор). Адрес с секретом и коды — окружением (SEC46-02).
_ga_subs_answer() {
    local d="$1" new="${2:-false}" row secret urls clients short avail=false map='{}'
    row=$(ga_subs_row "$d") || return 1
    [ -n "$row" ] || return 1
    secret=$(ga_subs_secret_of "$d") || return 1
    urls=$(ga_subs_urls_json "$secret" "$(jq -c '.lines' <<<"$row")") || return 1
    short=$(ga_short_urls "$(basename "$d")")
    if jq -e 'type == "object"' <<<"$short" >/dev/null 2>&1; then
        [ "$(jq -r '.available == true' <<<"$short")" = true ] && avail=true
        map=$(jq -c '.short // {} | if type == "object" then . else {} end' <<<"$short") || map='{}'
    fi
    # Пауза (сайт не на домене) — адресов нет, коротких тоже; бот не настроен — короткие не открываются (404), их не
    # показываем
    [ -n "$(jq -r '.base_url' <<<"$urls")" ] && [ "$avail" = true ] || map='{}'
    clients=$(GA_S_SHORT="$map" ga_subs_clients_json "$(jq -r '.base_url' <<<"$urls")" "$(jq -c '.lines' <<<"$row")" \
        "$(jq -r '.label' <<<"$row")") || clients='[]'
    GA_S_URLS="$urls" GA_S_CLIENTS="$clients" jq -c --argjson new "$new" --argjson h "$(ga_subs_update_hours)" \
        --argjson sa "$avail" \
        '. + ($ENV.GA_S_URLS | fromjson) + {clients: ($ENV.GA_S_CLIENTS | fromjson), new: $new,
                                            paused: (($ENV.GA_S_URLS | fromjson).base_url == ""), update_interval: $h,
                                            short_available: $sa}' <<<"$row"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Служба и маршрут: служба — общая со страницами (lib/pages.sh), маршрут — свой
# ══════════════════════════════════════════════════════════════════════════════
# Включить: сначала служба (общая со страницами), потом маршрут /s-… — nginx не проксирует в пустоту ни секунды.
_subs_enable_locked() {
    type _pages_service_on_locked >/dev/null 2>&1 \
        || { ga_err module_missing "$(tf module_missing _pages_service_on_locked)"; return 1; }
    _pages_service_on_locked || return 1
    if [ "$(ga_config_get .site.subs_location 2>/dev/null)" != "true" ]; then
        type _website_subs_location_locked >/dev/null 2>&1 \
            || { ga_err module_missing "$(tf module_missing website_subs_location_on)"; return 1; }
        _website_subs_location_locked true || return 1
    fi
    return 0
}
# Снять маршрут; службу — только если и страниц на ней нет. Тихая и идемпотентная: её зовёт каждый тик.
_subs_disable_locked() {
    if [ "$(ga_config_get .site.subs_location 2>/dev/null)" = "true" ] \
       && type _website_subs_location_locked >/dev/null 2>&1; then
        _website_subs_location_locked false || return 1
    fi
    if [ "$(ga_config_get .site.pages_location 2>/dev/null)" != "true" ] && type _pages_service_off_locked >/dev/null 2>&1; then
        _pages_service_off_locked
    fi
    return 0
}
# subs_reconcile — обвязка по факту (каждый watch-tick): есть подписки и сайт на домене — служба и маршрут
# включены (ремонт после переустановки, восстановления из копии, возврата на домен); иначе — сняты (пауза).
subs_reconcile() { ga_with_config_lock _subs_reconcile_locked "$@"; }
_subs_reconcile_locked() {
    if [ "$(ga_subs_count)" -gt 0 ] && ga_subs_domain_ready; then
        _subs_enable_locked
    else
        _subs_disable_locked
    fi
}
# _subs_mode_off_locked — сайт уходит с домена (lib/website.sh → lite): подписки на ПАУЗУ — маршрут снят, служба
# (если и страниц нет) остановлена, секреты остаются: при возврате на домен адреса оживут, и роутеры перенастраивать
# не придётся. У страниц иначе — их отзывают (_pages_mode_off_locked). Зовётся под общим замком.
_subs_mode_off_locked() {
    local n
    n=$(ga_subs_count)
    # Вызывающий снимает сайт целиком (vhost уже удалён): флаг маршрута — прямо в config.json, без пересборки vhost,
    # которая вернула бы снятый сайт; службу — если и страниц на ней нет. Зовётся ДО _pages_mode_off_locked: тот
    # при живых страницах vhost пересобирает, и маршрута подписок в нём уже не будет.
    if [ "$(ga_config_get .site.subs_location 2>/dev/null)" = "true" ]; then
        ga_config_set .site.subs_location false >/dev/null 2>&1 || true
    fi
    if [ "$(ga_config_get .site.pages_location 2>/dev/null)" != "true" ] && type _pages_service_off_locked >/dev/null 2>&1; then
        _pages_service_off_locked
    fi
    [ "${n:-0}" -gt 0 ] && log_warning "$(tf subs_paused_mode "$n")"
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  Публичные функции
# ══════════════════════════════════════════════════════════════════════════════
# subs_create <имя> → stdout JSON {name, label, created, rotated, generation, fetches, last_fetch, last_suffix,
#   last_client, lines, disabled, base_url, urls, clients, new, paused, update_interval}. Подписка уже есть — тот же адрес и
#   new: false (адрес меняет только sub-rotate). В ответе СЕКРЕТ — действие помечено "secret": true.
subs_create() { ga_with_config_lock _subs_create_locked "$@"; }
_subs_create_locked() {
    local name="${1:-}" dir sdir secret now lines keyed keyless ucreated meta server
    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t subs_err_no_jq)"; return 1; }
    command -v python3 >/dev/null 2>&1 || { ga_err no_python "$(t subs_err_no_python)"; return 1; }
    type ga_users_require >/dev/null 2>&1 || { ga_err module_missing "$(tf module_missing ga_users_require)"; return 1; }
    type ga_pages_server_py >/dev/null 2>&1 || { ga_err module_missing "$(tf module_missing ga_pages_server_py)"; return 1; }
    server=$(ga_pages_server_py)
    [ -f "$server" ] || { ga_err module_missing "$(tf module_missing "$(basename "$server")")"; return 1; }
    ga_subs_check_name "$name" || return 2
    # Только сайт на домене с настоящим сертификатом: адрес забирают роутер и приложение, им самоподписанный не показать.
    if ! ga_subs_domain_ready; then
        ga_err subs_need_domain "$(t subs_err_need_domain)" 2
        return 2
    fi
    ga_users_require "$name" || return $?
    lines=$(ga_subs_lines_json "$name")
    if [ "$(jq -r 'length' <<<"$lines" 2>/dev/null)" = 0 ]; then
        ga_err peer_not_found "$(tf subs_err_no_peers "$name")" 3
        return 3
    fi
    keyed=$(jq -r '[.[] | select(.has_key)] | length' <<<"$lines" 2>/dev/null)
    if [ "${keyed:-0}" = 0 ]; then
        keyless=$(jq -r '[.[].profile] | join(", ")' <<<"$lines" 2>/dev/null)
        ga_err no_private_key "$(tf subs_err_no_privkey "$name" "$keyless")" 3
        return 3
    fi
    dir=$(ga_subs_dir)
    sdir="$dir/$name"
    # Подписка уже есть и её владелец — этот человек: тот же адрес (обвязку чиним, если её сняли руками).
    if ga_subs_exists "$name" && ! _ga_subs_owner_gone "$sdir"; then
        _subs_enable_locked || return 1
        ga_subs_audit sub-create "user=${name} existing=yes"
        log_info "$(tf subs_exists "$name")"
        _ga_subs_answer "$sdir" false
        return $?
    fi
    # Обломок или подписка прежнего владельца имени (тёзка) — снимаем и заводим новую.
    [ -d "$sdir" ] && ga_subs_drop "$sdir" owner_gone
    mkdir -p "$dir" 2>/dev/null || { ga_err write_failed "$(tf subs_err_dir "$dir")"; return 1; }
    chmod 700 "$dir" 2>/dev/null || true
    mkdir "$sdir" 2>/dev/null || { ga_err write_failed "$(tf subs_err_dir "$sdir")"; return 1; }
    chmod 700 "$sdir" 2>/dev/null || true
    secret=$(ga_subs_new_secret) || { rm -rf "${sdir:?}"; ga_err write_failed "$(t subs_err_secret)"; return 1; }
    _ga_subs_write_secret "$sdir" "$secret" || { rm -rf "${sdir:?}"; ga_err write_failed "$(tf subs_err_write "$sdir/secret")"; return 1; }
    now=$(ga_subs_iso_now)
    # user_created — метка ЗАПИСИ человека: подписка привязана к нему, а не к имени (SR-05).
    ucreated=$(ga_users_get "$name" 2>/dev/null | jq -r '.created // ""' 2>/dev/null) || ucreated=""
    meta=$(jq -nc --arg u "$name" --arg uc "$ucreated" --arg c "$now" \
        '{user: $u, user_created: $uc, created: $c, rotated: "", generation: 1}') || {
        rm -rf "${sdir:?}"; ga_err write_failed "$(tf subs_err_write "$sdir/meta.json")"; return 1; }
    _ga_subs_write_meta "$sdir" "$meta" || { rm -rf "${sdir:?}"; ga_err write_failed "$(tf subs_err_write "$sdir/meta.json")"; return 1; }
    # Обвязка — после записи подписки: не поднялась — подписку снимаем, адрес не выдаём.
    if ! _subs_enable_locked; then
        rm -rf "${sdir:?}"
        return 1
    fi
    ga_subs_audit sub-create "user=${name} generation=1"
    log_success "$(tf subs_created "$name")"
    if [ "$(ga_users_get "$name" | jq -r 'if (.enabled == false) then "off" else "on" end' 2>/dev/null)" = off ]; then
        log_warning "$(tf subs_warn_disabled "$name")"
    fi
    keyless=$(jq -r '[.[] | select(.has_key | not) | .profile] | join(", ")' <<<"$lines" 2>/dev/null)
    [ -n "$keyless" ] && log_warning "$(tf subs_warn_imported "$name" "$keyless")"
    _ga_subs_answer "$sdir" true
}

# _subs_for_page_locked <имя> → stdout одним словом: created | exists | off. Подписка вместе со страницей подключения
# (решение владельца 04.10.2026): у человека её ещё нет, а адрес будет открываться (сайт на домене с доверенным
# сертификатом) — заводим; вкладка «Подписка» страницы покажет ссылку по нажатию. Существующим людям без новой страницы
# подписку молча не создаём — миграции нет. Адрес сюда не печатается: stdout — одно слово; отказ создания (все ключи из
# приложения Amnezia, ключей нет, не записалось) страницу не роняет — вкладка скажет «подписку ещё не включили».
# Зовётся под замком из _pages_create_locked.
_subs_for_page_locked() {
    local name="${1:-}"
    if ! ga_subs_check_name "$name" 2>/dev/null || ! ga_subs_domain_ready 2>/dev/null; then
        printf 'off'
        return 0
    fi
    if ga_subs_exists "$name" && ! _ga_subs_owner_gone "$(ga_subs_dir)/$name"; then
        printf 'exists'
        return 0
    fi
    # В подоболочке: отказ оставил бы в GA_ERR_* свой код ответу страницы, а адреса из stdout здесь не нужны вовсе
    if (_subs_create_locked "$name" >/dev/null 2>&1); then
        log_info "$(tf subs_created_with_page "$name")"
        printf 'created'
    else
        printf 'off'
    fi
    return 0
}

# subs_show <имя> → stdout JSON как у subs_create (new: false) — адреса ещё раз, чтобы настроить новое
# устройство. Только чтение (без замка); в аудит — только имя.
subs_show() {
    local name="${1:-}" sdir
    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t subs_err_no_jq)"; return 1; }
    ga_subs_check_name "$name" || return 2
    sdir="$(ga_subs_dir)/$name"
    if ! ga_subs_exists "$name" || _ga_subs_owner_gone "$sdir"; then
        ga_err sub_not_found "$(tf subs_err_not_found "$name")" 3
        return 3
    fi
    if ! ga_subs_domain_ready; then
        ga_err subs_need_domain "$(tf subs_err_paused "$name")" 2
        return 2
    fi
    ga_subs_audit sub-show "user=${name}"
    _ga_subs_answer "$sdir" false
}

# _ga_subs_with_state_lock <каталог> <команда…> — под замком заборов подписки (state.lock, flock): его же берёт служба
# страниц на запись забора (Sub.fetched), и перевыпуск не перемешивается с забором (Н-5: служба проверила секрет,
# ядро обнулило счёт, служба записала счёт прежнего адреса поверх; или забор нового адреса между записью секрета и
# сбросом счёта терялся). Нет flock (стенд на macOS) — без замка, как ga_with_config_lock. Файл замка — 0600, как у
# службы и в шапке модуля (П-5): создаётся в подоболочке с umask 077, umask самой оболочки не меняется; права
# выставляются при каждом взятии замка (П-5-2: файл, созданный кодом до П-5, остался 0644).
_ga_subs_with_state_lock() {
    local d="$1" fd rc
    shift
    command -v flock >/dev/null 2>&1 || { "$@"; return $?; }
    [ -e "$d/state.lock" ] || { (umask 077; : >>"$d/state.lock"); } 2>/dev/null || true
    chmod 600 "$d/state.lock" 2>/dev/null || true
    { exec {fd}>>"$d/state.lock"; } 2>/dev/null || { "$@"; return $?; }
    flock -w 10 "$fd" 2>/dev/null || true
    "$@"; rc=$?
    exec {fd}>&-
    return "$rc"
}
# _ga_subs_rotate_files <каталог> <секрет> <поколение> — файлы перевыпуска под замком заборов: счёт прежнего адреса в
# meta.json (Н-1: после перевыпуска на утечку в карточке остаётся след «прежний адрес забирали N раз, последний —
# тогда-то»: prev_fetches, prev_last_fetch в ga_subs_row; П-4: прежний адрес не забирали ни разу — след не трогаем,
# иначе второй перевыпуск подряд, например сразу после отзыва страницы, затёр бы след утёкшего адреса нулём; в
# карточке остаётся последний адрес, который забирали), секрет, meta, счёт с нуля (A3-2: прежний адрес мёртв, и
# «Забирали: 2 · curl» про него вводило в заблуждение того, кто проверяет, трогали ли новый адрес; auto_fetches —
# ключом с нулём, а не без ключа: без него ядро взяло бы счёт по последнему забору (миграция старой службы) и сказало
# бы «обновится сама» про приложение, которому теперь 404).
_ga_subs_rotate_files() {
    local sdir="$1" secret="$2" gen="$3" meta pf pl
    pf=$(jq -r '.fetches // 0' "$sdir/state.json" 2>/dev/null); [[ "$pf" =~ ^[0-9]{1,15}$ ]] || pf=0
    pl=$(jq -r '.last_fetch // "" | strings' "$sdir/state.json" 2>/dev/null) || pl=""
    [ "$pf" -gt 0 ] || pl=""
    meta=$(jq -c --arg r "$(ga_subs_iso_now)" --argjson g "$gen" --argjson pf "$pf" --arg pl "$pl" \
        '.rotated = $r | .generation = $g | if $pf > 0 then .prev_fetches = $pf | .prev_last_fetch = $pl else . end' \
        "$sdir/meta.json" 2>/dev/null) || meta=""
    [ -n "$meta" ] || { ga_err write_failed "$(tf subs_err_write "$sdir/meta.json")"; return 1; }
    _ga_subs_write_secret "$sdir" "$secret" || { ga_err write_failed "$(tf subs_err_write "$sdir/secret")"; return 1; }
    _ga_subs_write_meta "$sdir" "$meta" || { ga_err write_failed "$(tf subs_err_write "$sdir/meta.json")"; return 1; }
    _ga_subs_reset_state "$sdir" || { ga_err write_failed "$(tf subs_err_write "$sdir/state.json")"; return 1; }
}

# subs_rotate <имя> → stdout JSON как у subs_create: новый секрет, прежний адрес умирает сразу. Без домена (пауза)
# перевыпуск тоже идёт — адрес утёк, а сайт вернётся: тогда base_url пуст и paused: true.
subs_rotate() { ga_with_config_lock _subs_rotate_locked "$@"; }
_subs_rotate_locked() {
    local name="${1:-}" sdir secret gen
    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t subs_err_no_jq)"; return 1; }
    ga_subs_check_name "$name" || return 2
    sdir="$(ga_subs_dir)/$name"
    if ! ga_subs_exists "$name" || _ga_subs_owner_gone "$sdir"; then
        ga_err sub_not_found "$(tf subs_err_not_found "$name")" 3
        return 3
    fi
    secret=$(ga_subs_new_secret) || { ga_err write_failed "$(t subs_err_secret)"; return 1; }
    gen=$(jq -r '(.generation // 1) | tonumber? // 1' "$sdir/meta.json" 2>/dev/null)
    [[ "$gen" =~ ^[0-9]+$ ]] || gen=1
    gen=$((gen + 1))
    _ga_subs_with_state_lock "$sdir" _ga_subs_rotate_files "$sdir" "$secret" "$gen" || return 1
    # Перевыпуск гасит и короткие ссылки (в кладбище на 30 дней); новые — при следующем показе. Не погасились — их
    # всё равно не примет служба: код прежнего поколения подписки мёртв (lib/shortlinks.py).
    _ga_subs_short_kill "$sdir" rotate
    # Служба перечитывает каталог подписок по его mtime: прежний секрет она отвергает сразу (сверка с файлом), а
    # новый узнаёт с этой отметкой без ожидания очередного перечитывания.
    touch "$(ga_subs_dir)" 2>/dev/null || true
    ga_subs_domain_ready && { _subs_enable_locked || return 1; }
    ga_subs_audit sub-rotate "user=${name} generation=${gen}"
    log_success "$(tf subs_rotated "$name")"
    _ga_subs_answer "$sdir" false
}

# subs_revoke <имя> → stdout JSON {name, revoked: true}: адрес умирает сразу; новая подписка — с новым секретом.
subs_revoke() { ga_with_config_lock _subs_revoke_cmd_locked "$@"; }
_subs_revoke_cmd_locked() {
    local name="${1:-}"
    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t subs_err_no_jq)"; return 1; }
    ga_subs_check_name "$name" || return 2
    if [ ! -d "$(ga_subs_dir)/$name" ]; then
        ga_err sub_not_found "$(tf subs_err_not_found "$name")" 3
        return 3
    fi
    _subs_revoke_locked "$name" revoked
    log_success "$(tf subs_revoked "$name")"
    jq -nc --arg n "$name" '{name: $n, revoked: true}'
}
# _subs_revoke_locked <имя> [причина] — точка, которую зовёт удаление человека (_users_del_locked, массовое
# удаление — по имени на каждого): снять подписку, если она есть, и обвязку, если подписок не осталось. Тихая,
# stdout пуст, код всегда 0 — удаление человека не должно спотыкаться о подписку. Причина — в аудит.
_subs_revoke_locked() {
    local name="${1:-}" reason="${2:-user-del}" d
    [[ "$name" =~ $GA_SUBS_NAME_RE ]] || return 0
    d="$(ga_subs_dir)/$name"
    [ -d "$d" ] || return 0
    ga_subs_drop "$d" "$reason"
    [ "$(ga_subs_count)" -gt 0 ] || _subs_disable_locked >/dev/null 2>&1 || true
    return 0
}

# subs_list [имя] → stdout JSON {subs: [...], count, domain_ready, update_interval, update_slow} — БЕЗ адресов: адрес
# выдают только sub-create, sub-show и sub-rotate (secret). update_slow — ga_subs_update_slow. Только чтение, без
# замка: осиротевшие не показываем, снимет тик.
subs_list() {
    local name="${1:-}" dir d list='[]' row ready=false hours
    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t subs_err_no_jq)"; return 1; }
    if [ -n "$name" ]; then ga_subs_check_name "$name" || return 2; fi
    dir=$(ga_subs_dir)
    if [ -d "$dir" ]; then
        for d in "$dir"/*; do
            [ -f "$d/meta.json" ] && [ -f "$d/secret" ] || continue
            [[ "$(basename "$d")" =~ $GA_SUBS_NAME_RE ]] || continue
            [ -n "$name" ] && [ "$(basename "$d")" != "$name" ] && continue
            _ga_subs_owner_gone "$d" && continue
            row=$(ga_subs_row "$d") || continue
            [ -n "$row" ] || continue
            list=$(jq -c --argjson item "$row" '. + [$item]' <<<"$list")
        done
    fi
    ga_subs_domain_ready && ready=true
    hours=$(ga_subs_update_hours)
    jq -nc --argjson s "$list" --argjson r "$ready" --argjson h "$hours" --argjson slow "$(ga_subs_update_slow "$hours")" \
        '{subs: $s, count: ($s | length), domain_ready: $r, update_interval: $h, update_slow: $slow}'
}

# subs_tick → stdout JSON {removed, active} — уборка осиротевших и обвязка по факту (watch-tick, 2 минуты).
subs_tick() { ga_with_config_lock _subs_tick_locked "$@"; }
_subs_tick_locked() {
    local removed active
    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t subs_err_no_jq)"; return 1; }
    removed=$(ga_subs_sweep)
    active=$(ga_subs_count)
    _subs_reconcile_locked || true
    # Короткие ссылки: истёкшие запросы подтверждения и уборка состояния — и тогда, когда службы нет
    if [ -f "$(ga_subs_dir)/.short/state.json" ]; then
        ( _ga_short_call sweep >/dev/null 2>&1 ) || true
    fi
    jq -nc --argjson r "${removed:-0}" --argjson a "${active:-0}" '{removed: $r, active: $a}'
}

# ══════════════════════════════════════════════════════════════════════════════
#  Короткие ссылки с 2FA через Telegram-бота (lib/shortlinks.py, docs/SUBSCRIPTION.md §11)
# ══════════════════════════════════════════════════════════════════════════════
# https://<домен>/<КОД>: 8 знаков из 32, код на пару «подписка + суффикс». Работают только с 2FA через Telegram-бота:
# вход с нового адреса подтверждает администратор числом в боте. Логика целиком — в lib/shortlinks.py: тот же код
# у службы страниц (маршрут /<КОД>, кнопки страницы) и у моста. Здесь — обёртки действий short-*: модуль печатает одну
# строку JSON, отказ — {"error": код, …} с кодом возврата; код уходит в ga_err со словами словаря
# (lib/lang/<язык>.d/short.sh). Кодов, числа и адресов в журнале и аудите нет. Ответы short-* несут секрет (код или
# число) — в actions.json они "secret": true, в MCP их нет.

# Путь к модулю: рабочая копия продукта, иначе — рядом с этим файлом (стенды, первый запуск).
ga_short_py() {
    local work="${GOAMNEZIA_DIR:-/opt/goamnezia}/lib/shortlinks.py"
    if [ -f "$work" ]; then printf '%s' "$work"; else printf '%s/shortlinks.py' "$_GA_SUBS_LIB_DIR"; fi
}

# _ga_short_call <команда> [--ключ значение]… → stdout ответа модуля. Отказ — ga_err с кодом модуля и словами; код
# возврата модуля (2 — неверный ввод, 3 — нет такого, 1 — прочее).
_ga_short_call() {
    local out rc=0 code left msg
    command -v python3 >/dev/null 2>&1 || { ga_err no_python "$(t subs_err_no_python)"; return 1; }
    out=$(GOAMNEZIA_DIR="${GOAMNEZIA_DIR:-/opt/goamnezia}" GOAMNEZIA_SUBS_DIR="$(ga_subs_dir)" \
          GOAMNEZIA_LOCK_DIR="${LOCK_DIR:-/run/goamnezia}" GOAMNEZIA_BOT_DIR="${BOT_DIR:-/opt/goamnezia-bot}" \
          GOAMNEZIA_AUDIT_LOG="${AUDIT_LOG:-${GOAMNEZIA_AUDIT_LOG:-}}" GOAMNEZIA_WHO="${GOAMNEZIA_WHO:-ssh}" \
          python3 "$(ga_short_py)" "$@" 2>/dev/null) || rc=$?
    if [ "$rc" = 0 ] && jq -e 'type == "object" and (has("error") | not)' <<<"$out" >/dev/null 2>&1; then
        printf '%s' "$out"
        return 0
    fi
    code=$(jq -r '.error // empty' <<<"$out" 2>/dev/null) || code=""
    left=$(jq -r '((.left // 0) + 59) / 60 | floor' <<<"$out" 2>/dev/null) || left=1
    [[ "$left" =~ ^[0-9]+$ ]] && [ "$left" -ge 1 ] || left=1
    [ "$rc" = 0 ] && rc=1
    case "$code" in
        short_need_bot)          msg=$(t short_err_need_bot) ;;
        sub_not_found)           msg=$(tf subs_err_not_found "${GA_SHORT_NAME:-?}") ;;
        short_not_found)         msg=$(tf short_err_not_found "${GA_SHORT_NAME:-?}" "${GA_SHORT_SUFFIX:-?}") ;;
        short_pending)           msg=$(tf short_err_pending "$left") ;;
        short_limit)             msg=$(tf short_err_limit "$left") ;;
        short_request_not_found) msg=$(t short_err_request) ;;
        short_bad_answer)        msg=$(t short_err_answer) ;;
        bad_suffix)              msg=$(tf short_err_suffix "${GA_SHORT_SUFFIX:-?}") ;;
        bad_target)              msg=$(t short_err_target) ;;
        short_busy)              msg=$(t short_err_busy) ;;
        "")                      code=short_failed; msg=$(t short_err_failed) ;;
        *)                       msg=$(t short_err_failed) ;;
    esac
    ga_err "$code" "$msg" "$rc"
    return "$rc"
}

# _ga_subs_short_kill <каталог подписки> <причина> — погасить её короткие ссылки (перевыпуск, отзыв, удаление
# человека, в том числе массовое). Тихая и всегда 0: снятие подписки о короткие ссылки не спотыкается — код
# прежнего поколения или без подписки служба и так не примет.
_ga_subs_short_kill() {
    local d="$1" reason="${2:-revoked}"
    [ -f "$d/short.json" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    ( _ga_short_call kill --name "$(basename "$d")" --reason "$reason" >/dev/null 2>&1 ) || true
    return 0
}

# ga_short_urls <имя> → {available, short: {суффикс: адрес}} — для ответов sub-create, sub-show, sub-rotate; без
# модуля или python3 — {available: false, short: {}}.
ga_short_urls() {
    local out
    out=$( ( _ga_short_call urls --name "${1:-}" ) 2>/dev/null ) || out=""
    jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1 || out='{"available":false,"short":{}}'
    printf '%s' "$out"
}

# Общие проверки: имя, подписка этого человека, сайт на домене; суффикс — канонический, а у суффикса линии — линия с
# ключом у человека (иначе по полному адресу тоже 404). → 0 или ga_err.
_ga_short_check() {
    local name="${1:-}" suffix="${2:-}" line tok
    GA_SHORT_NAME="$name"; GA_SHORT_SUFFIX="$suffix"
    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t subs_err_no_jq)"; return 1; }
    ga_subs_check_name "$name" || return 2
    if ! ga_subs_exists "$name" || _ga_subs_owner_gone "$(ga_subs_dir)/$name"; then
        ga_err sub_not_found "$(tf subs_err_not_found "$name")" 3
        return 3
    fi
    if ! ga_subs_domain_ready; then
        ga_err subs_need_domain "$(tf subs_err_paused "$name")" 2
        return 2
    fi
    [ -n "$suffix" ] || return 0
    if ! [[ "$suffix" =~ $GA_SHORT_SUFFIX_RE ]]; then
        ga_err bad_suffix "$(tf short_err_suffix "$suffix")" 2
        return 2
    fi
    tok="${suffix%%.*}"
    case "$tok" in
        awg31) line=3.1 ;; awg20) line=2.0 ;; awg15) line=1.5 ;; awg10) line=1.0 ;; *) line="" ;;
    esac
    if [ -n "$line" ] && ! jq -e --arg l "$line" 'any(.[]; .line == $l and .has_key)' <<<"$(ga_subs_lines_json "$name")" >/dev/null 2>&1; then
        ga_err short_no_line "$(tf short_err_no_line "$name" "$line")" 3
        return 3
    fi
    return 0
}

# subs_short_ensure <имя> <суффикс> → {code, display, url, created, suffix, new}: код пары «подписка + суффикс», нет —
# создаётся. Бот не настроен — short_need_bot.
subs_short_ensure() { ga_with_config_lock _subs_short_ensure_locked "$@"; }
_subs_short_ensure_locked() {
    _ga_short_check "${1:-}" "${2:-}" || return $?
    _ga_short_call ensure --name "$1" --suffix "$2"
}

# subs_short_list <имя> → {codes: [{suffix, code, display, url, created}], short_available} — только уже созданные.
subs_short_list() {
    _ga_short_check "${1:-}" "" || return $?
    _ga_short_call list --name "$1"
}

# subs_short_replace_request <имя> <суффикс> <кто: page|panel|ssh|bot[:<id>]> → {request, number, expires, left}: запрос
# замены; число показывает тот, кто попросил, решает администратор в боте.
subs_short_replace_request() { ga_with_config_lock _subs_short_replace_locked "$@"; }
_subs_short_replace_locked() {
    _ga_short_check "${1:-}" "${2:-}" || return $?
    _ga_short_call replace-request --name "$1" --suffix "$2" --who "${3:-ssh}"
}

# subs_short_decide <запрос> <ответ: NN|deny|swap> [кто решил] → {decision, display?, url?, already?, by?}. Без общего
# замка (мост — _action_own_lock): нажатие в боте не ждёт долгих операций, состояние пишется под замком модуля.
subs_short_decide() {
    _ga_short_call decide --request "${1:-}" --answer "${2:-}" --who "${3:-${GOAMNEZIA_WHO:-ssh}}"
}

# subs_short_status <запрос> → {decision, kind, suffix, expires, left, display?, url?}
subs_short_status() { _ga_short_call status --request "${1:-}"; }

# subs_short_pending → {requests: […]} — без верного числа (запасной путь панели, если Telegram недоступен)
subs_short_pending() { _ga_short_call pending; }

# subs_short_bans → {bans: [{kind: ip|code, target, level, until, reason: misses|denied|wrong}]}
subs_short_bans() { _ga_short_call bans; }

# subs_short_unban <адрес или код> → {unbanned: true|false, kind: ip|code}
subs_short_unban() { ga_with_config_lock _ga_short_call unban --target "${1:-}"; }
