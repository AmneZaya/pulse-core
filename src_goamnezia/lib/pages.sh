#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# goAmnezia pro — lib/pages.sh: постоянная страница подключения (docs/CLIENTS.md §5–§9)
#
# Решение владельца 17.09.2026: человек получает не файл, а страницу — свои
# ключи (ссылкой и QR), приложения под своё устройство (ссылкой и QR) и
# «запросить копию приложения на наш сервер». Срок жизни — часы, дни или
# бессрочно. Временная ссылка на файл (lib/share.sh) остаётся для Lite и для
# «быстро забрать .conf»; страница — для режимов с сайтом на домене.
#
# Модель. Страница (page) — каталог в $(ga_pages_dir) (по умолчанию
# /opt/goamnezia/pages, переживает перезагрузку — в отличие от раздач):
#   <id>/meta.json   0600  id, пользователь, профили, срок, зеркало on/off
#   <id>/secret      0600  43 символа base64url = 32 случайных байта
#   <id>/state.json  0600  визиты (пишет служба страниц, lib/pages_server.py)
# Адрес: https://<домен>/p-<секрет>/. Путь И ЕСТЬ ключ — как у раздач и у
# адресов агентов: 43 символа base64url не подбираются.
#
# Почему nginx и служба, а не отдельный порт (в отличие от lib/share.sh):
# страница живёт дни и открывается обычным браузером с телефона, ей нужен
# доверенный сертификат и адрес без порта. Поэтому — только режимы с сайтом
# на домене (ga_site_domain_ready): одна regex-локация /p-<43>/ в vhost
# (site.pages_location, website_pages_location_on в lib/website.sh) и одна
# служба goamnezia-pages.service на 127.0.0.1:${pages.port} (1987). Локация и
# служба включаются с первой страницей и снимаются, когда страниц не осталось:
# без единой страницы открытой поверхности быть не должно.
#
# Ключи страница берёт у моста при показе (install.sh --action=user-key), а
# не из копии: за дни жизни страницы ключ могли перевыпустить, а Endpoint —
# сменить. Каталог приложений — lib/clients.json (§2), зеркало сборок —
# lib/mirror.sh. Ключ, выданный в приложении Amnezia до подхвата (у пира нет
# приватной части, has_key: false), страница не показывает, а объясняет человеку,
# что он у него уже есть; страницу, где такие все профили, не создаём.
#
# Правила модуля (контракт §0):
#   • stdout — только JSON у публичных функций; всё для человека — stderr;
#   • ни одной видимой строки вне t/tf — словарь lib/lang/<lang>.d/pages.sh;
#   • мутации — под ga_with_config_lock, пара fn() / _fn_locked();
#   • коды ошибок через ga_err: pages_need_domain, user_not_found,
#     user_disabled, invalid_ttl, invalid_page_id, page_not_found, page_limit,
#     invalid_profiles, peer_not_found, no_private_key, invalid_toggle, invalid_platform,
#     invalid_line, catalog_missing, catalog_corrupt, no_jq, no_python,
#     write_failed, unit_failed, module_missing и коды lib/website.sh;
#   • СЕКРЕТ не пишется ни в лог, ни в аудит, ни в page-list — только id.
#     Аудит: page-create, page-url (повторная выдача адреса), page-revoke,
#     page-expire; page-visit пишет сама служба (раз в час на страницу);
#   • GOAMNEZIA_DRY_RUN=1: systemctl печатается как «DRY: …», юнит пишется в
#     GOAMNEZIA_SYSTEMD_DIR, vhost — через lib/website.sh (тот же dry-run);
#     каталог страниц пишется по-настоящему — это состояние, а не система.
# ══════════════════════════════════════════════════════════════════════════════

_GA_PAGES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GA_PAGES_ID_RE='^p-[a-f0-9]{4,8}$'
GA_PAGES_SECRET_RE='^[A-Za-z0-9_-]{43}$'
# Срок: NNNh / NNNd / forever (actions.json, param_types.ttl). Границы —
# договор §9: часы до 720 (месяц), дни до 365.
GA_PAGES_TTL_RE='^([1-9][0-9]{0,2}h|[1-9][0-9]{0,2}d|forever)$'
GA_PAGES_TTL_MAX_HOURS=720
GA_PAGES_TTL_MAX_DAYS=365
# Предел страниц на сервер (§9): каждая — секретный адрес, живущий днями.
GA_PAGES_MAX=200
GA_PAGES_PORT_DEFAULT=1987
GA_PAGES_UNIT="goamnezia-pages.service"
# Каталог без meta.json моложе этого срока — страница ещё создаётся (mkdir →
# secret → meta.json идут тремя шагами), старше — обломок неудачного старта.
GA_PAGES_START_GRACE=60
GA_PAGES_START_TRIES=3

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
if ! type ga_capture >/dev/null 2>&1; then
    # stdout функции в переменную БЕЗ подоболочки: код в GA_ERR_CODE должен
    # доехать до вызывающего, а `x=$(fn)` теряет его вместе с подоболочкой.
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
# Аудит теми же именами, что у действий моста; секрет в подробности не попадает.
ga_pages_audit() {
    type ga_audit >/dev/null 2>&1 || return 0
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "$1" "${2:-}"
}

# ── Пути и настройки: функциями, а не константами при source ──────────────────
# Стенды выставляют GOAMNEZIA_* уже после подключения модуля.
ga_pages_dir() { printf '%s' "${GOAMNEZIA_PAGES_DIR:-${GOAMNEZIA_DIR:-/opt/goamnezia}/pages}"; }
# Рабочая копия сервера и каталога рядом с рабочей копией модуля (install.sh
# обновляет их вместе), иначе — эталон рядом с этим файлом (как у lib/share.sh).
ga_pages_server_py() {
    local work="${GOAMNEZIA_DIR:-/opt/goamnezia}/lib/pages_server.py"
    [ -f "$work" ] && { printf '%s' "$work"; return 0; }
    printf '%s/pages_server.py' "$_GA_PAGES_LIB_DIR"
}
ga_pages_clients_json() {
    if [ -n "${GOAMNEZIA_CLIENTS_JSON:-}" ]; then printf '%s' "$GOAMNEZIA_CLIENTS_JSON"; return 0; fi
    local work="${GOAMNEZIA_DIR:-/opt/goamnezia}/lib/clients.json"
    [ -f "$work" ] && { printf '%s' "$work"; return 0; }
    printf '%s/clients.json' "$_GA_PAGES_LIB_DIR"
}
# Порт службы на петле: pages.port из config.json, иначе 1987. Испорченное
# значение не должно ронять ни юнит, ни nginx -t — берём умолчание.
ga_pages_port() {
    local p
    p=$(ga_config_get .pages.port 2>/dev/null) || p=""
    [[ "$p" =~ ^[0-9]{2,5}$ ]] || p="$GA_PAGES_PORT_DEFAULT"
    printf '%s' "$p"
}
ga_pages_systemd_dir()   { printf '%s' "${GOAMNEZIA_SYSTEMD_DIR:-/etc/systemd/system}"; }
ga_pages_unit_path()     { printf '%s/%s' "$(ga_pages_systemd_dir)" "$GA_PAGES_UNIT"; }
ga_pages_fs_systemd_ok() { ! ga_dry || [ -n "${GOAMNEZIA_SYSTEMD_DIR:-}" ]; }
ga_pages_run_quiet() {
    if ga_dry; then ga_dry_echo "$*"; return 0; fi
    "$@" >/dev/null 2>&1
}
ga_pages_domain() { ga_config_get .domain 2>/dev/null || printf ''; }
# Сайт стоит на домене с настоящим сертификатом? Только тогда страницу можно
# открыть обычным браузером без предупреждений — на самоподписанном человеку
# с телефона его не обойти. Спрашиваем lib/website.sh, а без него — конфиг.
ga_pages_domain_ready() {
    if type ga_site_domain_ready >/dev/null 2>&1; then ga_site_domain_ready; return $?; fi
    [ "$(ga_config_get .site.cert 2>/dev/null)" = letsencrypt ] && [ -n "$(ga_pages_domain)" ]
}

# ── Секрет, идентификатор, время ──────────────────────────────────────────────
ga_pages_new_secret() {
    local s=""
    s=$(openssl rand -base64 32 2>/dev/null | tr '+/' '-_' | tr -d '=\n')
    if ! [[ "$s" =~ $GA_PAGES_SECRET_RE ]]; then
        s=$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')
    fi
    [[ "$s" =~ $GA_PAGES_SECRET_RE ]] || return 1
    printf '%s' "$s"
}
# p-<4 hex>; при совпадении — длиннее (до 8). Дешёвый фильтр: занимает
# идентификатор голый mkdir в _pages_create_locked, как у lib/share.sh.
ga_pages_new_id() {
    local n id
    for n in 4 6 8; do
        id="p-$(generate_hex "$n")"
        [[ "$id" =~ $GA_PAGES_ID_RE ]] || continue
        [ -e "$(ga_pages_dir)/$id" ] && continue
        printf '%s' "$id"
        return 0
    done
    return 1
}
ga_pages_check_id() {
    [[ "${1:-}" =~ $GA_PAGES_ID_RE ]] && return 0
    ga_err invalid_page_id "$(tf pages_err_id "${1:-}")" 2
    return 2
}
ga_pages_iso_at() {
    local epoch="$1"
    date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# ga_pages_ttl_seconds <ttl> → секунды в stdout (0 — бессрочно); rc 2 и код
# invalid_ttl на всём, что не по договору §9.
ga_pages_ttl_seconds() {
    local ttl="${1:-}" n
    if ! [[ "$ttl" =~ $GA_PAGES_TTL_RE ]]; then
        ga_err invalid_ttl "$(tf pages_err_ttl "$ttl")" 2
        return 2
    fi
    case "$ttl" in
        forever) printf '0' ;;
        *h) n="${ttl%h}"
            [ "$n" -le "$GA_PAGES_TTL_MAX_HOURS" ] || { ga_err invalid_ttl "$(tf pages_err_ttl "$ttl")" 2; return 2; }
            printf '%s' $((n * 3600)) ;;
        *d) n="${ttl%d}"
            [ "$n" -le "$GA_PAGES_TTL_MAX_DAYS" ] || { ga_err invalid_ttl "$(tf pages_err_ttl "$ttl")" 2; return 2; }
            printf '%s' $((n * 86400)) ;;
    esac
    return 0
}
# on/off/true/false/1/0 → true|false (та же таблица, что у lib/website.sh)
ga_pages_toggle() {
    case "${1,,}" in
        on|true|1|yes)  printf 'true' ;;
        off|false|0|no) printf 'false' ;;
        *) return 1 ;;
    esac
}

# ga_pages_profiles_for <имя> <csv> → JSON-массив профилей страницы в stdout.
# Пусто — все профили, в которых у человека есть пир; иначе каждый названный
# обязан быть профилем с его пиром: страница на профиль без ключа отдавала бы
# человеку пустоту под видом ключа.
ga_pages_profiles_for() {
    local name="$1" csv="${2:-}" peers p out='[]'
    # Порядок — 3.1 → 2.0 → 1.x, как в SSH, мастере и на самой странице (NC-27), а не по алфавиту
    peers=$(ga_users_get "$name" | jq -c '.peers // {} | keys | sort_by({"awg3":0,"awg2":1,"awg1":2}[.] // 9)' 2>/dev/null) || peers='[]'
    if [ -z "$csv" ]; then
        out="$peers"
    else
        if ! [[ "$csv" =~ ^(awg[1-9])(,(awg[1-9]))*$ ]]; then
            ga_err invalid_profiles "$(tf pages_err_profiles "$csv")" 2
            return 2
        fi
        for p in ${csv//,/ }; do
            if [ "$(jq -r --arg p "$p" 'index($p) != null' <<<"$peers")" != true ]; then
                ga_err peer_not_found "$(tf pages_err_peer "$name" "$p")" 3
                return 3
            fi
            out=$(jq -c --arg p "$p" 'if index($p) == null then . + [$p] else . end' <<<"$out")
        done
    fi
    if [ "$(jq -r 'length' <<<"$out")" = 0 ]; then
        ga_err peer_not_found "$(tf pages_err_no_peers "$name")" 3
        return 3
    fi
    printf '%s' "$out"
}

# ga_pages_keyless_for <имя> <JSON-массив профилей> → JSON-массив тех из них, где у
# человека ключ без приватной части: пир подхвачен из приложения Amnezia, сервер
# знает только открытый ключ (has_key: false). Страница покажет там справку, а не
# ключ. Карточка — через публичный фильтр lib/users.sh: этому модулю приватные
# ключи ни к чему, признак has_key считается там же, где его видят бот и панель.
ga_pages_keyless_for() {
    local name="$1" profiles="${2:-[]}" card
    type ga_users_public_filter >/dev/null 2>&1 || { printf '[]'; return 0; }
    card=$(ga_users_get "$name" | jq -c "$(ga_users_public_filter)" 2>/dev/null) || card=""
    [ -n "$card" ] || card='{}'
    # has_key сравниваем с false явно: в jq `false // x` даёт x, и пир без
    # приватного ключа выглядел бы пиром с ключом.
    jq -c --argjson sel "$profiles" '[$sel[] as $p | select((.peers // {})[$p].has_key == false) | $p]' \
        <<<"$card" 2>/dev/null || printf '[]'
}

# ── Состояние страниц ─────────────────────────────────────────────────────────
ga_pages_expired() {
    local d="$1" exp now
    exp=$(jq -r '.expires_epoch // 0' "$d/meta.json" 2>/dev/null)
    [[ "$exp" =~ ^[0-9]+$ ]] || return 0
    [ "$exp" -gt 0 ] || return 1
    now=$(date -u +%s)
    [ "$now" -ge "$exp" ]
}
# Каталог без meta.json: страница ещё рождается (свежий каталог) или обломок.
ga_pages_starting() {
    local d="$1" mt now
    mt=$( { stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null; } ) || return 1
    [[ "$mt" =~ ^[0-9]+$ ]] || return 1
    now=$(date -u +%s)
    [ $((now - mt)) -lt "$GA_PAGES_START_GRACE" ]
}
# Сколько страниц заведено (живых: с meta.json или рождающихся).
ga_pages_count() {
    local dir d n=0
    dir=$(ga_pages_dir)
    if [ -d "$dir" ]; then
        for d in "$dir"/p-*; do
            [ -d "$d" ] || continue
            { [ -f "$d/meta.json" ] || ga_pages_starting "$d"; } && n=$((n + 1))
        done
    fi
    printf '%s' "$n"
}
# ga_pages_drop <каталог> <причина> — снять страницу. Секрет стирается первым:
# с этой секунды адрес мёртв, даже если остальное не удалилось.
ga_pages_drop() {
    local d="$1" reason="${2:-expired}" id user action
    [ -d "$d" ] || return 0
    id=$(basename "$d")
    user=$(jq -r '.user // ""' "$d/meta.json" 2>/dev/null)
    if type ga_wipe_file >/dev/null 2>&1; then ga_wipe_file "$d/secret"; else rm -f "$d/secret" 2>/dev/null || true; fi
    rm -rf "$d" 2>/dev/null || true
    # revoked — человек, mode — сайт ушёл с домена (lib/website.sh), всё
    # остальное — истечение срока.
    case "$reason" in revoked|mode) action="page-revoke" ;; *) action="page-expire" ;; esac
    ga_pages_audit "$action" "id=${id} user=${user} reason=${reason}"
    return 0
}
# ga_pages_sweep → stdout число снятых истёкших страниц. Тихая: печатать ей
# нечего. Зовётся ТОЛЬКО под замком (pages_create, pages_revoke*, pages_tick):
# это rm -rf с записью в аудит, и из readonly-действий (page-list, page-url)
# такая мутация шла бы без замка и давала двойной page-expire при
# параллельном тике. Чтение истёкшие просто не показывает (ga_pages_expired).
ga_pages_sweep() {
    local dir d n=0
    dir=$(ga_pages_dir)
    [ -d "$dir" ] || { printf '0'; return 0; }
    for d in "$dir"/p-*; do
        [ -d "$d" ] || continue
        if [ ! -f "$d/meta.json" ]; then
            ga_pages_starting "$d" && continue
            rm -rf "$d" 2>/dev/null || true
            n=$((n + 1))
            continue
        fi
        if ga_pages_expired "$d"; then
            ga_pages_drop "$d" expired
            n=$((n + 1))
            continue
        fi
        # Владельца страницы больше нет (удалён до 0.4.3, когда удаление страниц не снимало,
        # или под тем же именем теперь другой человек) — страница снимается: ключей по ней
        # выдавать некому (SR-05, SEC-G3). Снимаем ТОЛЬКО по честному ответу users.json:
        # не прочитался — это не повод рушить страницы.
        if _ga_pages_owner_gone "$d"; then
            ga_pages_drop "$d" revoked
            n=$((n + 1))
        fi
    done
    printf '%s' "$n"
}
# _ga_pages_owner_gone <каталог страницы> → 0, только если users.json читается и владельца страницы в
# нём нет: имени нет вовсе; или запись с этим именем — другой человек: метка user_created (0.4.3+) не
# совпала, а у страницы 0.4.0–0.4.2 без метки запись моложе самой страницы — тёзка, заведённый после
# удаления владельца ссылки (SEC-G3; служба страниц отвечает на такую страницу 404 тем же правилом —
# App.namesake_of_legacy). Даты сравниваются строкой: продукт пишет обе как 2026-09-18T10:00:00Z.
_ga_pages_owner_gone() {
    local d="$1" f rc
    f="${USERS_FILE:-${GOAMNEZIA_DIR:-/opt/goamnezia}/users.json}"
    [ -r "$f" ] && [ -r "$d/meta.json" ] || return 1
    jq -e --slurpfile m "$d/meta.json" '
        def iso: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
        ($m[0].user // "") as $n | ($m[0].user_created // "") as $want | ($m[0].created // "") as $pc
        | if $n == "" then false
          else ((.users // []) | map(select(.name == $n)) | first) as $u
          | if $u == null then true
            elif $want != "" then ($u.created // "") != $want
            elif ($pc | iso) and ($u.created | iso) then $u.created > $pc
            else false end
          end' "$f" >/dev/null 2>&1; rc=$?
    [ "$rc" = 0 ]
}
# Одна строка списка: meta.json без секрета плюс визиты из state.json.
ga_pages_row() {
    local d="$1" visits last
    visits=$(jq -r '.visits // 0' "$d/state.json" 2>/dev/null); [[ "$visits" =~ ^[0-9]+$ ]] || visits=0
    last=$(jq -r '.last_visit // ""' "$d/state.json" 2>/dev/null)
    jq -c --argjson v "$visits" --arg l "$last" \
        '{id, user, created, expires, forever, ttl, profiles, mirror, visits: $v, last_visit: $l, subscription}' "$d/meta.json" 2>/dev/null
}
ga_pages_url_of() {
    local d="$1" secret domain
    secret=$( { tr -d '[:space:]' <"$d/secret"; } 2>/dev/null ) || return 1
    [[ "$secret" =~ $GA_PAGES_SECRET_RE ]] || return 1
    domain=$(ga_pages_domain)
    [ -n "$domain" ] || return 1
    printf 'https://%s/p-%s/' "$domain" "$secret"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Служба goamnezia-pages.service и маршрут в vhost
# ══════════════════════════════════════════════════════════════════════════════
# Текст юнита (stdout). User=root: служба зовёт мост install.sh за ключами. GOAMNEZIA_BOT_DIR — где .env бота: короткие
# ссылки подписки работают, только когда бот настроен (lib/shortlinks.py); GOAMNEZIA_LOCK_DIR — где очередь событий
# short-confirm, та же, что у ядра (LOCK_DIR). Сменился текст — тик пересоберёт юнит и перезапустит службу
# (_pages_service_on_locked): так новый код службы доезжает и при обновлении через мост.
_pages_unit_render() {
    local server dir
    server=$(ga_pages_server_py)
    dir="${GOAMNEZIA_DIR:-/opt/goamnezia}"
    cat <<EOUNIT
[Unit]
Description=goAmnezia pro - connection pages and subscriptions (docs/CLIENTS.md, docs/SUBSCRIPTION.md)
Documentation=file://${dir}/docs/CLIENTS.md
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=GOAMNEZIA_DIR=${dir}
Environment=GOAMNEZIA_ACTION_BIN=${dir}/install.sh
Environment=GOAMNEZIA_AUDIT_LOG=${AUDIT_LOG:-/var/log/goamnezia-audit.log}
Environment=GOAMNEZIA_BOT_DIR=${BOT_DIR:-/opt/goamnezia-bot}
Environment=GOAMNEZIA_LOCK_DIR=${LOCK_DIR:-/run/goamnezia}
ExecStart=/usr/bin/env python3 ${server} --dir ${dir} --bind 127.0.0.1 --port $(ga_pages_port)
Restart=always
RestartSec=3
# Ключи людей проходят через процесс службы; временные файлы не видны другим
PrivateTmp=true
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOUNIT
}
# Записать юнит, если изменился (GA_PAGES_UNIT_CHANGED=1), и daemon-reload.
_pages_unit_write_locked() {
    local path content tmp
    GA_PAGES_UNIT_CHANGED=0
    content=$(_pages_unit_render) || { ga_err unit_failed "$(tf pages_err_unit "$(ga_pages_unit_path)")"; return 1; }
    path=$(ga_pages_unit_path)
    if ! ga_pages_fs_systemd_ok; then
        ga_dry_echo "write $path"
        GA_PAGES_UNIT_CHANGED=1
        return 0
    fi
    if [ -f "$path" ] && [ "$(cat "$path" 2>/dev/null)" = "$content" ]; then
        return 0
    fi
    mkdir -p "$(dirname "$path")" 2>/dev/null || { ga_err unit_failed "$(tf pages_err_unit "$path")"; return 1; }
    tmp=$(mktemp "${path}.XXXXXX" 2>/dev/null) || { ga_err unit_failed "$(tf pages_err_unit "$path")"; return 1; }
    if ! printf '%s\n' "$content" >"$tmp" || ! chmod 644 "$tmp" || ! mv -f "$tmp" "$path"; then
        rm -f "$tmp"
        ga_err unit_failed "$(tf pages_err_unit "$path")"
        return 1
    fi
    GA_PAGES_UNIT_CHANGED=1
    ga_pages_run_quiet systemctl daemon-reload || true
    return 0
}
_pages_unit_remove_locked() {
    local path
    path=$(ga_pages_unit_path)
    ga_pages_run_quiet systemctl disable --now "$GA_PAGES_UNIT" || true
    if ga_pages_fs_systemd_ok; then rm -f "$path" 2>/dev/null || true; else ga_dry_echo "rm -f $path"; fi
    ga_pages_run_quiet systemctl daemon-reload || true
    log_dim "$(t pages_unit_removed)"
    return 0
}
# Состояние юнита одним словом: active | inactive | missing | dry
ga_pages_unit_state() {
    if ga_dry; then printf 'dry'; return 0; fi
    systemctl cat "$GA_PAGES_UNIT" >/dev/null 2>&1 || { printf 'missing'; return 0; }
    if systemctl is-active --quiet "$GA_PAGES_UNIT" 2>/dev/null; then printf 'active'; else printf 'inactive'; fi
}
# Служба goamnezia-pages — общая для страниц и подписок (lib/subs.sh, маршрут /s-…): юнит пишется и поднимается
# тем, кому он нужен первым, а снимается, когда ни у страниц, ни у подписок маршрута не осталось. Служба ставится и
# там, где юнит уже есть: enable --now на работающем юните ничего не делает, а остановленный руками — поднимает.
_pages_service_on_locked() {
    _pages_unit_write_locked || return 1
    ga_pages_run_quiet systemctl enable --now "$GA_PAGES_UNIT" \
        || { ga_err unit_failed "$(tf pages_err_unit_start "$GA_PAGES_UNIT")"; return 1; }
    if [ "${GA_PAGES_UNIT_CHANGED:-0}" = 1 ]; then
        ga_pages_run_quiet systemctl restart "$GA_PAGES_UNIT" \
            || { ga_err unit_failed "$(tf pages_err_unit_start "$GA_PAGES_UNIT")"; return 1; }
        log_dim "$(t pages_unit_restarted)"
    fi
    return 0
}
# Остановить службу и убрать юнит, если он есть. Тихая, когда снимать нечего.
_pages_service_off_locked() {
    if ga_pages_fs_systemd_ok && [ -f "$(ga_pages_unit_path)" ]; then
        _pages_unit_remove_locked
    fi
    return 0
}
# Включить обвязку: сначала служба, потом маршрут — чтобы nginx не проксировал
# в пустоту ни секунды.
_pages_enable_locked() {
    _pages_service_on_locked || return 1
    if [ "$(ga_config_get .site.pages_location 2>/dev/null)" != "true" ]; then
        type _website_pages_location_locked >/dev/null 2>&1 \
            || { ga_err module_missing "$(tf module_missing website_pages_location_on)"; return 1; }
        _website_pages_location_locked true || return 1
    fi
    return 0
}
# Снять обвязку: маршрут, затем служба — если её не держит маршрут подписок (site.subs_location). Идемпотентна и
# тихая, когда снимать нечего: её зовёт каждый тик, и без единой страницы она не должна ни печатать, ни дёргать
# systemctl.
_pages_disable_locked() {
    if [ "$(ga_config_get .site.pages_location 2>/dev/null)" = "true" ] \
       && type _website_pages_location_locked >/dev/null 2>&1; then
        _website_pages_location_locked false || return 1
    fi
    [ "$(ga_config_get .site.subs_location 2>/dev/null)" = "true" ] || _pages_service_off_locked
    return 0
}
# pages_reconcile — обвязка по факту: есть страницы и домен готов → служба и
# маршрут включены (ремонт после переустановки или ручного вмешательства),
# страниц нет → сняты. Зовётся из каждого pages_tick (watch-tick, 2 минуты):
# сравнение текста юнита и флага в config.json стоит копейки, а enable --now на
# работающей службе — пустая операция.
pages_reconcile() { ga_with_config_lock _pages_reconcile_locked "$@"; }
_pages_reconcile_locked() {
    if [ "$(ga_pages_count)" -gt 0 ]; then
        ga_pages_domain_ready || return 0
        _pages_enable_locked
    else
        _pages_disable_locked
    fi
}
# _pages_mode_off_locked — сайт уходит с домена (lib/website.sh → lite):
# страницы без домена мертвы, поэтому отзываются все (аудит page-revoke
# reason=mode), а маршрут и служба снимаются. Зовётся под общим замком из
# _website_disable_site_locked / _website_disable_pro_locked.
_pages_mode_off_locked() {
    local dir d n=0
    dir=$(ga_pages_dir)
    if [ -d "$dir" ]; then
        for d in "$dir"/p-*; do
            [ -d "$d" ] || continue
            ga_pages_drop "$d" mode
            n=$((n + 1))
        done
    fi
    # Вызывающий снимает сайт целиком (vhost уже удалён): флаг маршрута — прямо в config.json. Через
    # _pages_disable_locked он шёл пересборкой vhost (_ga_site_apply_setting при ещё не записанном lite), и снятый
    # сайт возвращался: с живой страницей «Lite» оставлял nginx отдавать сайт дальше (найдено 03.10.2026 при
    # подписках). Служба — если её не держит маршрут подписок.
    if [ "$(ga_config_get .site.pages_location 2>/dev/null)" = "true" ]; then
        ga_config_set .site.pages_location false >/dev/null 2>&1 || true
    fi
    [ "$(ga_config_get .site.subs_location 2>/dev/null)" = "true" ] || _pages_service_off_locked
    [ "$n" -gt 0 ] && log_warning "$(tf pages_revoked_mode "$n")"
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  Публичные функции
# ══════════════════════════════════════════════════════════════════════════════
# pages_create <имя> <ttl> [профили через запятую] [зеркало on|off] → stdout JSON
#   {id, url, user, created, expires, forever, ttl, profiles, mirror, imported_profiles, subscription}
# url содержит СЕКРЕТ — действие моста помечено "secret": true. imported_profiles —
# профили страницы с ключом из приложения Amnezia (там справка вместо ключа). subscription —
# created | exists | off: подписка человека заводится вместе со страницей (lib/subs.sh,
# _subs_for_page_locked), её адреса в ответе нет — он на вкладке «Подписка» страницы.
pages_create() { ga_with_config_lock _pages_create_locked "$@"; }
_pages_create_locked() {
    local name="${1:-}" ttl="${2:-}" csv="${3:-}" mirror_arg="${4:-on}"
    local dir pdir="" id secret seconds now exp iso="" forever=false mirror profiles try url meta enabled server
    local keyless="[]" keyless_csv=""

    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t pages_err_no_jq)"; return 1; }
    command -v python3 >/dev/null 2>&1 || { ga_err no_python "$(t pages_err_no_python)"; return 1; }
    type ga_users_require >/dev/null 2>&1 || { ga_err module_missing "$(tf module_missing ga_users_require)"; return 1; }
    server=$(ga_pages_server_py)
    [ -f "$server" ] || { ga_err module_missing "$(tf module_missing "$(basename "$server")")"; return 1; }
    # Только сайт на домене с настоящим сертификатом: страницу открывает
    # человек в браузере с телефона, самоподписанный ему не показать.
    if ! ga_pages_domain_ready; then
        ga_err pages_need_domain "$(t pages_err_need_domain)" 2
        return 2
    fi
    ga_capture seconds ga_pages_ttl_seconds "$ttl" || return $?
    mirror=$(ga_pages_toggle "$mirror_arg") || { ga_err invalid_toggle "$(tf pages_err_toggle "$mirror_arg")" 2; return 2; }
    ga_users_require "$name" || return $?
    enabled=$(ga_users_get "$name" | jq -r '.enabled' 2>/dev/null)
    if [ "$enabled" = false ]; then
        ga_err user_disabled "$(tf pages_err_disabled "$name")" 3
        return 3
    fi
    ga_capture profiles ga_pages_profiles_for "$name" "$csv" || return $?
    # Ключи, выданные в приложении Amnezia до подхвата: на сервере только их
    # открытая часть, и страница покажет по ним справку, а не ключ. Если такие
    # все выбранные — страницу не создаём: человек получил бы ссылку без единого
    # ключа. Часть — создаём и предупреждаем ниже, после успеха.
    # Не массив — считаем, что таких нет: битое значение ниже в --argjson оставило
    # бы уже записанную страницу без ответа с адресом.
    keyless=$(ga_pages_keyless_for "$name" "$profiles")
    jq -e 'type == "array"' <<<"$keyless" >/dev/null 2>&1 || keyless="[]"
    keyless_csv=$(jq -r 'join(", ")' <<<"$keyless" 2>/dev/null) || keyless_csv=""
    if [ -n "$keyless_csv" ] && [ "$(jq -r 'length' <<<"$keyless")" = "$(jq -r 'length' <<<"$profiles")" ]; then
        ga_err no_private_key "$(tf pages_err_no_privkey "$name" "$keyless_csv")" 3
        return 3
    fi

    ga_pages_sweep >/dev/null
    if [ "$(ga_pages_count)" -ge "$GA_PAGES_MAX" ]; then
        ga_err page_limit "$(tf pages_err_limit "$GA_PAGES_MAX")" 2
        return 2
    fi

    dir=$(ga_pages_dir)
    mkdir -p "$dir" 2>/dev/null || { ga_err write_failed "$(tf pages_err_state_dir "$dir")"; return 1; }
    chmod 700 "$dir" 2>/dev/null || true
    # Идентификатор занимается САМИМ созданием каталога, mkdir без -p: на
    # существующем каталоге -p молчит, и два одновременных создания получали
    # бы один id (урок lib/share.sh, DEFECTS §1b.12).
    for try in $(seq 1 "$GA_PAGES_START_TRIES"); do
        id=$(ga_pages_new_id) || continue
        if mkdir "$dir/$id" 2>/dev/null; then pdir="$dir/$id"; break; fi
    done
    # Дальше каталог адресуется ТОЛЬКО через ${pdir:?}: любая ветка отката
    # делает rm -rf, и пустая переменная означала бы rm -rf /.
    [ -n "$pdir" ] || { ga_err write_failed "$(tf pages_err_state_dir "$dir")"; return 1; }
    chmod 700 "$pdir" 2>/dev/null || true
    secret=$(ga_pages_new_secret) || { rm -rf "${pdir:?}"; ga_err write_failed "$(t pages_err_secret)"; return 1; }
    (umask 077; printf '%s' "$secret" >"$pdir/secret") || {
        rm -rf "${pdir:?}"; ga_err write_failed "$(tf pages_err_write "$pdir/secret")"; return 1; }

    now=$(date -u +%s)
    if [ "$seconds" -gt 0 ]; then
        exp=$((now + seconds)); iso=$(ga_pages_iso_at "$exp")
    else
        exp=0; forever=true
    fi
    # user_created — метка создания ЗАПИСИ пользователя: страница привязана к человеку, а не к
    # имени. Служба страниц сверяет её с users.json и тёзке, заведённому после удаления, отдаёт
    # 404, а не его ключи (SR-05).
    local ucreated
    ucreated=$(ga_users_get "$name" 2>/dev/null | jq -r '.created // ""' 2>/dev/null) || ucreated=""
    meta=$(jq -nc --arg id "$id" --arg user "$name" --arg created "$(ga_pages_iso_at "$now")" \
        --arg expires "$iso" --argjson exp "$exp" --argjson forever "$forever" --arg ttl "$ttl" \
        --argjson profiles "$profiles" --argjson mirror "$mirror" --arg ucreated "$ucreated" \
        '{id: $id, user: $user, user_created: $ucreated, created: $created, expires: $expires, expires_epoch: $exp,
          forever: $forever, ttl: $ttl, profiles: $profiles, mirror: $mirror}') || {
        rm -rf "${pdir:?}"; ga_err write_failed "$(tf pages_err_write "$pdir/meta.json")"; return 1; }
    # meta.json — через временный файл рядом и mv: служба страниц читает
    # каталог в любой момент и не должна увидеть полупустой JSON.
    if ! (umask 077; printf '%s\n' "$meta" >"$pdir/.meta.tmp" && mv -f "$pdir/.meta.tmp" "$pdir/meta.json"); then
        rm -rf "${pdir:?}"; ga_err write_failed "$(tf pages_err_write "$pdir/meta.json")"; return 1
    fi

    # Обвязка — после того как страница записана: служба и маршрут нужны ей,
    # а не наоборот. Не поднялась — страницу снимаем, адрес не выдаём.
    if ! _pages_enable_locked; then
        rm -rf "${pdir:?}"
        return 1
    fi

    url="https://$(ga_pages_domain)/p-${secret}/"
    ga_pages_audit page-create "id=${id} user=${name} ttl=${ttl} profiles=$(jq -r 'join(",")' <<<"$profiles") mirror=${mirror}"
    if [ "$forever" = true ]; then
        log_success "$(tf pages_created_forever "$name")"
        log_warning "$(t pages_warn_forever)"
    else
        # Срок — как на экране: «через 24 ч (… по времени сервера)», а не сырой ISO (NC-11)
        log_success "$(tf pages_created "$name" "$(type ga_human_ts >/dev/null 2>&1 && ga_human_ts "$iso" || printf '%s' "$iso")")"
    fi
    [ -n "$keyless_csv" ] && log_warning "$(tf pages_warn_imported "$name" "$keyless_csv")"
    # Подписка — вместе со страницей (решение владельца 04.10.2026, lib/subs.sh): у человека её ещё нет — заводим,
    # если адрес будет открываться; на странице она — вкладкой «Подписка». Адрес подписки в этот ответ не идёт.
    local sub_state="off"
    if type _subs_for_page_locked >/dev/null 2>&1; then
        sub_state=$(_subs_for_page_locked "$name") || sub_state="off"
    fi
    # Чья подписка — в meta.json страницы (B2-2/A2-4): окно «Отозвать» по ней ставит галочку «и перевыпустить
    # подписку» — включённой, если подписку завела эта страница. Не записалось — страница жива, галочка просто выключена.
    local meta2
    meta2=$(jq -c --arg s "$sub_state" '.subscription = $s' "$pdir/meta.json" 2>/dev/null) && [ -n "$meta2" ] &&
        (umask 077; printf '%s\n' "$meta2" >"$pdir/.meta.tmp" && mv -f "$pdir/.meta.tmp" "$pdir/meta.json") 2>/dev/null || true
    # imported_profiles — те же профили для бота, панели и агента: предупреждение
    # выше уходит в stderr, а до них доходит только JSON. subscription — created | exists | off.
    # Адрес — через окружение, не аргументом jq: он и есть ключ к приватным ключам человека, а
    # argv читает любой локальный пользователь в /proc/<pid>/cmdline (находка SEC46-02).
    GA_S_URL="$url" jq -nc --arg id "$id" --arg user "$name" --arg created "$(ga_pages_iso_at "$now")" \
        --arg expires "$iso" --argjson forever "$forever" --arg ttl "$ttl" \
        --argjson profiles "$profiles" --argjson mirror "$mirror" --argjson keyless "$keyless" --arg sst "$sub_state" \
        '{id: $id, url: $ENV.GA_S_URL, user: $user, created: $created, expires: $expires, forever: $forever,
          ttl: $ttl, profiles: $profiles, mirror: $mirror, imported_profiles: $keyless, subscription: $sst}'
}

# pages_list [имя] → stdout JSON {pages: [...], count} — БЕЗ адресов: адрес
# отдаёт только pages_url, и это действие помечено secret.
pages_list() {
    local name="${1:-}" dir d list='[]' row
    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t pages_err_no_jq)"; return 1; }
    if [ -n "$name" ] && ! [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; then
        ga_err invalid_name "$(tf pages_err_name "$name")" 2
        return 2
    fi
    # Только чтение (действие readonly, без замка): истёкшие не показываем,
    # но и не снимаем — их снимет pages_tick под замком.
    dir=$(ga_pages_dir)
    if [ -d "$dir" ]; then
        for d in "$dir"/p-*; do
            [ -f "$d/meta.json" ] || continue
            ga_pages_expired "$d" && continue
            if [ -n "$name" ] && [ "$(jq -r '.user // ""' "$d/meta.json" 2>/dev/null)" != "$name" ]; then continue; fi
            row=$(ga_pages_row "$d") || continue
            [ -n "$row" ] || continue
            list=$(jq -c --argjson item "$row" '. + [$item]' <<<"$list")
        done
    fi
    jq -nc --argjson pages "$list" '{pages: $pages, count: ($pages | length)}'
}

# pages_url <id> → stdout JSON {id, url} — адрес с секретом, чтобы отправить
# человеку ещё раз. В аудит — только id.
pages_url() {
    local id="${1:-}" d url
    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t pages_err_no_jq)"; return 1; }
    ga_pages_check_id "$id" || return 2
    d="$(ga_pages_dir)/$id"
    # Без уборки (readonly): истёкшая страница — «не найдена», снимет её тик.
    if [ ! -f "$d/meta.json" ] || ga_pages_expired "$d"; then
        ga_err page_not_found "$(tf pages_err_not_found "$id")" 3
        return 3
    fi
    url=$(ga_pages_url_of "$d") || { ga_err write_failed "$(tf pages_err_write "$d/secret")"; return 1; }
    ga_pages_audit page-url "id=${id} user=$(jq -r '.user // ""' "$d/meta.json" 2>/dev/null)"
    # Адрес — через окружение, не аргументом jq (SEC46-02, как в pages_create)
    GA_S_URL="$url" jq -nc --arg id "$id" '{id: $id, url: $ENV.GA_S_URL}'
}

# pages_revoke <id> [sub on|off] [keys on|off] → stdout JSON {id, user, sub_rotated, sub_present, keys_reissued, keys_failed}
# sub=on — заодно перевыпустить подписку человека (B2-2/A2-4): страница отдаёт и её адрес на вкладке «Подписка», и
# отзыв одной страницы прежний адрес подписки не гасит. Перевыпуск — тот же, что «Перевыпустить подписку»
# (_subs_rotate_locked): прежний адрес — 404 сразу, подписка остаётся, новый адрес — на других страницах человека и
# по «Показать адреса». Новый адрес в этот ответ не идёт. Подписки нет — sub_rotated: false, без ошибки.
# sub_present — была ли подписка у пользователя в момент отзыва с sub=on: false и sub_rotated: false — «перевыпускать
# нечего» (не отказ), true и sub_rotated: false — перевыпуск не удался (R-4). При sub=off — null: подписку не
# спрашивали (агенту MCP sub закрыт — false читался бы как «подписки нет», RR-2).
# keys=on — заодно перевыпустить ключи пользователя на профилях страницы (B3-3): кто открыл утёкшую ссылку и нажал
# «Показать ключ», унёс рабочий ключ, и ни отзыв, ни перевыпуск подписки его не гасят. Перевыпуск — тот же, что
# «Перевыпустить ключ» (_users_reissue_peer_locked): старый ключ перестаёт подключаться сразу — и у пользователя тоже, до
# нового ключа. Только пиры с ключом на сервере (ключ из приложения Amnezia страница не отдавала). keys_reissued и
# keys_failed — профили; при keys=off — null. Для MCP закрыт, как sub.
# sub=on и keys=on вместе — ещё и профили линий подписки (Н-1): по адресу подписки, взятому со страницы, получатель
# забрал ключи всех линий пользователя, а не только профилей страницы. Какие профили — ga_pages_revoke_key_profiles;
# тем же правилом окна отзыва в панели, боте и SSH называют их заранее.
pages_revoke() { ga_with_config_lock _pages_revoke_locked "$@"; }
_pages_revoke_locked() {
    local id="${1:-}" sub_arg="${2:-off}" keys_arg="${3:-off}" d sub keys user="" rotated=false present=null
    local profiles="[]" reissued=null failed=null p kp='{"page":[],"sub":[]}'
    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t pages_err_no_jq)"; return 1; }
    ga_pages_check_id "$id" || return 2
    sub=$(ga_pages_toggle "$sub_arg") || { ga_err invalid_toggle "$(tf pages_err_toggle "$sub_arg")" 2; return 2; }
    keys=$(ga_pages_toggle "$keys_arg") || { ga_err invalid_toggle "$(tf pages_err_toggle "$keys_arg")" 2; return 2; }
    d="$(ga_pages_dir)/$id"
    if [ ! -d "$d" ]; then
        ga_pages_sweep >/dev/null
        ga_err page_not_found "$(tf pages_err_not_found "$id")" 3
        return 3
    fi
    user=$(jq -r '.user // ""' "$d/meta.json" 2>/dev/null) || user=""
    profiles=$(jq -c '[(.profiles // [])[] | strings]' "$d/meta.json" 2>/dev/null) || profiles="[]"
    # Чьи ключи перевыпускать — до отзыва и до перевыпуска подписки: подписка нужна живой, как её видел получатель.
    [ "$keys" = true ] && kp=$(ga_pages_revoke_key_profiles "$user" "$profiles" "$sub")
    ga_pages_drop "$d" revoked
    ga_pages_sweep >/dev/null
    # Страниц не осталось — маршрут и служба снимаются: открытой поверхности
    # без единой страницы быть не должно.
    [ "$(ga_pages_count)" -gt 0 ] || _pages_disable_locked || true
    log_success "$(tf pages_revoked "$id")"
    # Подписка — после страницы: страница уже не откроется, даже если перевыпуск споткнётся. В подоболочке: ответ
    # перевыпуска несёт новый адрес (секрет), а отказ оставил бы свой код в GA_ERR_* ответу отзыва.
    # Подписка «есть» по тому же правилу, что у перевыпуска: каталог с секретом и владелец на месте (тёзка — не он).
    [ "$sub" = true ] && present=false
    if [ "$sub" = true ] && [[ "$user" =~ ^[A-Za-z0-9_-]{1,32}$ ]] && type _subs_rotate_locked >/dev/null 2>&1 &&
        type ga_subs_exists >/dev/null 2>&1 && ga_subs_exists "$user" &&
        ! _ga_subs_owner_gone "$(ga_subs_dir)/$user"; then
        present=true
        if (_subs_rotate_locked "$user" >/dev/null 2>&1); then
            rotated=true
            log_success "$(tf pages_revoked_sub "$user")"
        else
            log_warning "$(tf pages_revoked_sub_failed "$user")"
        fi
    elif [ "$sub" = true ]; then
        log_info "$(tf pages_revoked_sub_none "$user")"
    fi
    # Ключи — последними и каждый в подоболочке, как подписка: страница и подписка уже погашены, а отказ одного
    # профиля не мешает остальным и не оставляет своего кода в ответе отзыва.
    if [ "$keys" = true ]; then
        reissued='[]'; failed='[]'
        if [[ "$user" =~ ^[A-Za-z0-9_-]{1,32}$ ]] && type _users_reissue_peer_locked >/dev/null 2>&1; then
            for p in $(jq -r '(.page + .sub)[]' <<<"$kp" 2>/dev/null); do
                [[ "$p" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || continue
                if (_users_reissue_peer_locked "$user" "$p" >/dev/null 2>&1); then
                    reissued=$(jq -c --arg p "$p" '. + [$p]' <<<"$reissued")
                else
                    failed=$(jq -c --arg p "$p" '. + [$p]' <<<"$failed")
                fi
            done
        fi
        if [ "$(jq -r 'length' <<<"$reissued")" -gt 0 ]; then
            log_success "$(tf pages_revoked_keys "$user" "$(jq -r 'join(", ")' <<<"$reissued")")"
        fi
        if [ "$(jq -r 'length' <<<"$failed")" -gt 0 ]; then
            log_warning "$(tf pages_revoked_keys_failed "$user" "$(jq -r 'join(", ")' <<<"$failed")")"
        elif [ "$(jq -r 'length' <<<"$reissued")" = 0 ]; then
            log_info "$(tf pages_revoked_keys_none "$user")"
        fi
    fi
    jq -nc --arg id "$id" --arg u "$user" --argjson r "$rotated" --argjson p "$present" \
        --argjson kr "$reissued" --argjson kf "$failed" \
        '{id: $id, user: $u, sub_rotated: $r, sub_present: $p, keys_reissued: $kr, keys_failed: $kf}'
}

# ga_pages_revoke_key_profiles <имя> <JSON профилей страницы> <sub true|false|on|off> → JSON {page: [...], sub: [...]}:
# чьи ключи перевыпустит отзыв страницы с keys=on. page — профили страницы с ключом на сервере; sub — при sub=on и живой
# подписке (каталог с секретом, владелец на месте) ещё профили её линий с ключом на сервере (ga_subs_lines_json), которых
# нет в page (Н-1). Порядок — как у страницы, затем как у подписки. SSH зовёт эту функцию, панель и бот — то же правило
# по user-show и sub-list.
ga_pages_revoke_key_profiles() {
    local user="${1:-}" profiles="${2:-[]}" sub="${3:-false}" card lines='[]' none='{"page":[],"sub":[]}'
    [[ "$user" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || { printf '%s' "$none"; return 0; }
    card=$(ga_users_get "$user" 2>/dev/null) || card=""
    [ -n "$card" ] || { printf '%s' "$none"; return 0; }
    if { [ "$sub" = true ] || [ "$sub" = on ]; } && type ga_subs_exists >/dev/null 2>&1 && ga_subs_exists "$user" &&
        ! _ga_subs_owner_gone "$(ga_subs_dir)/$user"; then
        lines=$(ga_subs_lines_json "$user" 2>/dev/null) || lines='[]'
    fi
    jq -c --argjson pr "${profiles:-[]}" --argjson ln "${lines:-[]}" '
        def uniq: reduce .[] as $p ([]; if index([$p]) then . else . + [$p] end);
        (.peers // {}) as $peers
        | def keyed: select(type == "string" and test("^[A-Za-z0-9_-]{1,32}$")
                            and ((($peers[.] // {}).privkey // "") != ""));
        ([$pr[] | keyed] | uniq) as $page
        | {page: $page,
           sub: ([$ln[] | select(.has_key == true) | .profile | keyed | select(. as $p | $page | index([$p]) | not)]
                 | uniq)}' <<<"$card" 2>/dev/null || printf '%s' "$none"
}

# pages_revoke_all [имя] → stdout JSON {revoked}
pages_revoke_all() { ga_with_config_lock _pages_revoke_all_locked "$@"; }
_pages_revoke_all_locked() {
    local name="${1:-}" dir d n=0
    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t pages_err_no_jq)"; return 1; }
    if [ -n "$name" ] && ! [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; then
        ga_err invalid_name "$(tf pages_err_name "$name")" 2
        return 2
    fi
    dir=$(ga_pages_dir)
    if [ -d "$dir" ]; then
        for d in "$dir"/p-*; do
            [ -d "$d" ] || continue
            if [ -n "$name" ] && [ "$(jq -r '.user // ""' "$d/meta.json" 2>/dev/null)" != "$name" ]; then continue; fi
            ga_pages_drop "$d" revoked
            n=$((n + 1))
        done
    fi
    [ "$(ga_pages_count)" -gt 0 ] || _pages_disable_locked || true
    if [ "$n" -gt 0 ]; then log_success "$(tf pages_revoked_all "$n")"; else log_dim "$(t pages_none)"; fi
    jq -nc --argjson n "$n" '{revoked: $n}'
}

# pages_tick → stdout JSON {expired, active} — снятие истёкших (watch-tick).
pages_tick() { ga_with_config_lock _pages_tick_locked "$@"; }
_pages_tick_locked() {
    local removed active
    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t pages_err_no_jq)"; return 1; }
    removed=$(ga_pages_sweep)
    active=$(ga_pages_count)
    # Обвязка по факту раз в тик: страниц нет — снята; есть и домен готов —
    # служба и маршрут на месте (ремонт после переустановки или руками).
    _pages_reconcile_locked || true
    log_dim "$(tf pages_tick_done "${removed:-0}" "$active")"
    jq -nc --argjson r "${removed:-0}" --argjson a "$active" '{expired: $r, active: $a}'
}

# ── Каталог приложений (docs/CLIENTS.md §2, §9) ──────────────────────────────
# clients_list [платформа] [линейка] → stdout JSON {checked, lines, platforms,
# apps: [...]}: приложения каталога, у которых остались платформы после
# фильтра; support "no" по линейке снимает платформу из ответа, "unknown" —
# оставляет (интерфейс скажет «не подтверждено»).
clients_list() {
    local platform="${1:-}" line="${2:-}" f
    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t pages_err_no_jq)"; return 1; }
    f=$(ga_pages_clients_json)
    [ -f "$f" ] || { ga_err catalog_missing "$(tf pages_err_catalog "$f")"; return 1; }
    jq -e '.apps | type == "array"' "$f" >/dev/null 2>&1 || { ga_err catalog_corrupt "$(tf pages_err_catalog "$f")"; return 1; }
    if [ -n "$platform" ] && [ "$(jq -r --arg p "$platform" '.platforms | index($p) != null' "$f")" != true ]; then
        ga_err invalid_platform "$(tf pages_err_platform "$platform")" 2
        return 2
    fi
    if [ -n "$line" ] && [ "$(jq -r --arg l "$line" '.lines | index($l) != null' "$f")" != true ]; then
        ga_err invalid_line "$(tf pages_err_line "$line")" 2
        return 2
    fi
    jq -c --arg p "$platform" --arg l "$line" '
        {checked, lines, platforms,
         apps: [ .apps[]
            | (if $p != "" then .platforms |= with_entries(select(.key == $p)) else . end)
            | (if $l != "" then .platforms |= with_entries(select((.value.support[$l] // "unknown") != "no")) else . end)
            | select(.platforms | length > 0)
            | . + {mirror: (.mirror // null)} ]}' "$f"
}
