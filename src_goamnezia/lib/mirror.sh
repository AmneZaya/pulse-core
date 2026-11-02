#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# goAmnezia pro — lib/mirror.sh: зеркало сборок приложений (docs/CLIENTS.md §8)
#
# Решение владельца 17.09.2026 (п. 2–3): человек на странице подключения
# может попросить копию приложения на наш сервер — сервер сам скачивает
# официальную сборку из источника, дальше её раздаёт nginx с нашего домена.
# Зеркалятся только открытые приложения из каталога lib/clients.json с полем
# mirror (AmneziaVPN, AmneziaWG, WG Tunnel); iPhone — никогда (в App Store).
#
# Модель. Пара «приложение/платформа» — каталог $(ga_mirror_dir)/<app>/<platform>/
# (по умолчанию /opt/goamnezia/mirror, переживает перезагрузку):
#   <файл сборки>  0644  публикуется атомарным переносом после проверки
#   meta.json      0644  version, file, size, sha256, fetched, source_url
#   LICENSE        0644  лицензия из репозитория на том же теге
#   SOURCE.txt     0644  ссылка на исходники той же версии
#   state.json     0644  queued | downloading | ready | failed, bytes, error
#   request        0600  заявка со страницы (пишет lib/pages_server.py)
#   .lock/         замок на пару: одна загрузка на пару, внутри pid
#   .<файл>.part   временный файл загрузки — в том же каталоге, чтобы mv был
#                  переименованием, а не копированием
# Каталог и файлы читает nginx (internal-локация /_ga_mirror/, X-Accel-Redirect
# от службы страниц), поэтому права 755/644, а не 700/600: в зеркале нет
# секретов, только публичные сборки.
#
# Загрузка (§8): последний релиз GitHub (не pre-release) через API → файл по
# regex → размер ≤ mirror.max_file_mb (400) и итог каталога ≤ mirror.max_total_mb
# (3072), свободного места ≥ размер + 1 ГиБ → curl --proto '=https' во
# временный файл → сверка размера и digest sha256 из API. Нет digest — не
# публикуем (mirror_unverified): сборка без подтверждения подлинности хуже,
# чем её отсутствие. Загрузка идёт в фоне: systemd-run, а без него —
# отсоединённый процесс (nohup) с pid-файлом; в dry-run — в этом же процессе,
# чтобы проверки видели итог сразу.
#
# Заявки со страниц: не чаще одной на пару в 10 минут и не больше 6 загрузок в
# час на сервер (GA_MIRROR_PAIR_INTERVAL, GA_MIRROR_HOUR_LIMIT); обрабатывает
# mirror_tick (watch-tick, 2 мин). Раз в сутки (upstream-tick) mirror_tick daily
# сверяет версии уже скачанных копий и подтягивает новую.
#
# Правила модуля (контракт §0):
#   • stdout — только JSON у mirror_list / mirror_fetch / mirror_remove /
#     mirror_tick; всё для человека — stderr;
#   • ни одной видимой строки вне t/tf — словарь lib/lang/<lang>.d/mirror.sh;
#   • коды ошибок через ga_err: unknown_app, not_mirrorable, mirror_busy,
#     mirror_no_space, mirror_too_big, mirror_unverified, mirror_fetch_failed,
#     invalid_argument, no_jq, no_curl, catalog_missing, write_failed;
#   • GOAMNEZIA_DRY_RUN=1: в сеть не ходим. Стенд подставляет
#     GOAMNEZIA_MIRROR_CURL (программа вместо curl, отдающая файлы по адресу)
#     и при желании GOAMNEZIA_MIRROR_API_BASE / GOAMNEZIA_MIRROR_RAW_BASE;
#     без подставного curl загрузка отвечает mirror_fetch_failed.
#     GOAMNEZIA_MIRROR_FOREGROUND=1 — вести загрузку в текущем процессе и на
#     живом сервере (отладка).
#
# Файл исполним сам по себе: `bash lib/mirror.sh --worker <app> <platform>` —
# так его запускает фоновая загрузка (без моста и без общего замка: загрузка
# идёт до получаса, держать всё это время замок продукта нельзя).
# ══════════════════════════════════════════════════════════════════════════════

_GA_MIRROR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GA_MIRROR_MAX_FILE_MB_DEFAULT=400
GA_MIRROR_MAX_TOTAL_MB_DEFAULT=3072
# Свободного места после загрузки должно остаться не меньше гигабайта: зеркало
# не должно оставить без места users.json и бэкапы.
GA_MIRROR_FREE_RESERVE_MB=1024
GA_MIRROR_PAIR_INTERVAL=600
GA_MIRROR_HOUR_LIMIT=6
GA_MIRROR_CURL_TIMEOUT=1800
GA_MIRROR_API_TIMEOUT=30
# Замок старше двух часов — от убитого процесса: загрузка идёт до получаса.
GA_MIRROR_LOCK_STALE=7200
GA_MIRROR_APP_RE='^[a-z0-9-]{2,32}$'
# iOS в списке нет намеренно: сборки для iPhone живут только в App Store.
GA_MIRROR_PLATFORM_RE='^(android|android_tv|windows|macos|linux)$'
# Имя файла сборки уезжает в путь X-Accel-Redirect и в Content-Disposition:
# ничего, кроме букв, цифр, точки, подчёркивания, плюса и дефиса.
GA_MIRROR_FILE_RE='^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$'
GA_MIRROR_STATES='queued downloading ready failed'

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
type ga_now >/dev/null 2>&1 || ga_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
ga_mirror_audit() {
    type ga_audit >/dev/null 2>&1 || return 0
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "$1" "${2:-}"
}

# ── Пути и настройки: функциями, а не константами при source ──────────────────
ga_mirror_dir()      { printf '%s' "${GOAMNEZIA_MIRROR_DIR:-${GOAMNEZIA_DIR:-/opt/goamnezia}/mirror}"; }
ga_mirror_pair_dir() { printf '%s/%s/%s' "$(ga_mirror_dir)" "$1" "$2"; }
ga_mirror_api_base() { printf '%s' "${GOAMNEZIA_MIRROR_API_BASE:-https://api.github.com/repos}"; }
ga_mirror_raw_base() { printf '%s' "${GOAMNEZIA_MIRROR_RAW_BASE:-https://raw.githubusercontent.com}"; }
ga_mirror_curl_bin() { printf '%s' "${GOAMNEZIA_MIRROR_CURL:-curl}"; }
ga_mirror_catalog() {
    if type ga_pages_clients_json >/dev/null 2>&1; then ga_pages_clients_json; return 0; fi
    if [ -n "${GOAMNEZIA_CLIENTS_JSON:-}" ]; then printf '%s' "$GOAMNEZIA_CLIENTS_JSON"; return 0; fi
    local work="${GOAMNEZIA_DIR:-/opt/goamnezia}/lib/clients.json"
    [ -f "$work" ] && { printf '%s' "$work"; return 0; }
    printf '%s/clients.json' "$_GA_MIRROR_LIB_DIR"
}
# Пределы из config.json; мусор — умолчание, а не «без предела».
ga_mirror_max_file_mb() {
    local v
    v=$(ga_config_get .mirror.max_file_mb 2>/dev/null) || v=""
    [[ "$v" =~ ^[1-9][0-9]{0,5}$ ]] || v="$GA_MIRROR_MAX_FILE_MB_DEFAULT"
    printf '%s' "$v"
}
ga_mirror_max_total_mb() {
    local v
    v=$(ga_config_get .mirror.max_total_mb 2>/dev/null) || v=""
    [[ "$v" =~ ^[1-9][0-9]{0,6}$ ]] || v="$GA_MIRROR_MAX_TOTAL_MB_DEFAULT"
    printf '%s' "$v"
}
# Размер файла (байт), sha256 файла, свободное место каталога (КиБ): по одной
# функции на весь модуль, каждая с запасным путём для стенда на macOS.
ga_mirror_file_size() { { stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null; } | tr -d ' '; }
ga_mirror_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
    else python3 -c 'import sys,hashlib; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1" 2>/dev/null
    fi
}
# Свободно КБ на разделе каталога. С фикстурой GOAMNEZIA_DF_FIXTURE (ga_df_mb, TAIL-12) — из неё: запас зеркалу —
# гигабайт, и на маленьком /tmp сухой прогон иначе отказывал бы «места нет».
ga_mirror_free_kb() {
    if [ -n "${GOAMNEZIA_DF_FIXTURE:-}" ] && type ga_df_mb >/dev/null 2>&1; then
        ga_df_mb "$1" | awk '{print $3 * 1024}'
        return 0
    fi
    df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

# ── Каталог: что и откуда зеркалить ──────────────────────────────────────────
# ga_mirror_check_target <app> <platform> — форма аргументов (они идут в пути).
ga_mirror_check_target() {
    if ! [[ "${1:-}" =~ $GA_MIRROR_APP_RE ]] || ! [[ "${2:-}" =~ $GA_MIRROR_PLATFORM_RE ]]; then
        ga_err invalid_argument "$(tf mirror_err_target "${1:-}" "${2:-}")" 2
        return 2
    fi
    return 0
}
# ga_mirror_spec <app> <platform> → stdout JSON {app, platform, repo, pattern,
# license}; коды unknown_app (нет такого приложения), not_mirrorable (закрытое
# или сборки этой платформы нет).
ga_mirror_spec() {
    local app="$1" platform="$2" f js
    f=$(ga_mirror_catalog)
    [ -f "$f" ] || { ga_err catalog_missing "$(tf mirror_err_catalog "$f")"; return 1; }
    js=$(jq -c --arg a "$app" --arg p "$platform" '
        (.apps[] | select(.id == $a)) // empty
        | .mirror as $m
        | ($m.assets[$p] // null) as $asset
        | if $m == null or $asset == null then {app: $a, platform: $p, mirrorable: false}
          elif ($asset | type) == "object"
          then {app: $a, platform: $p, mirrorable: true, repo: ($asset.repo // $m.repo), pattern: $asset.pattern,
                license: ($asset.license // $m.license // "")}
          else {app: $a, platform: $p, mirrorable: true, repo: $m.repo, pattern: $asset, license: ($m.license // "")} end' "$f" 2>/dev/null)
    if [ -z "$js" ]; then
        ga_err unknown_app "$(tf mirror_err_unknown_app "$app")" 2
        return 2
    fi
    if [ "$(jq -r '.mirrorable' <<<"$js")" != true ]; then
        ga_err not_mirrorable "$(tf mirror_err_not_mirrorable "$app" "$platform")" 2
        return 2
    fi
    printf '%s' "$js"
}

# ── Состояние пары ───────────────────────────────────────────────────────────
# ga_mirror_state_write <каталог> <состояние> [json с полями] — state.json
# атомарно: временный файл рядом и mv, читатель (служба страниц) не увидит
# полупустой JSON.
ga_mirror_state_write() {
    local d="$1" state="$2" extra="${3:-{\}}" tmp js
    case " $GA_MIRROR_STATES " in *" $state "*) ;; *) return 1 ;; esac
    printf '%s' "$extra" | jq -e 'type == "object"' >/dev/null 2>&1 || extra='{}'
    js=$(jq -nc --arg s "$state" --arg now "$(ga_now)" --argjson e "$extra" '{state: $s, updated: $now} + $e') || return 1
    tmp=$(mktemp "$d/.state.XXXXXX" 2>/dev/null) || return 1
    printf '%s\n' "$js" >"$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$d/state.json"
}
ga_mirror_state_read() {
    local d="$1" js
    js=$(jq -c . "$d/state.json" 2>/dev/null) || js=""
    [ -n "$js" ] || js='{"state":"none"}'
    printf '%s' "$js"
}
ga_mirror_meta_read() { jq -c . "$1/meta.json" 2>/dev/null || printf 'null'; }
# Замок пары — каталог .lock (mkdir атомарен) с pid внутри. Протухший замок
# (процесс мёртв или старше GA_MIRROR_LOCK_STALE) снимается.
ga_mirror_lock_alive() {
    local d="$1" pid mt now
    [ -d "$d/.lock" ] || return 1
    pid=$( { tr -d '[:space:]' <"$d/.lock/pid"; } 2>/dev/null )
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then return 0; fi
    mt=$( { stat -c %Y "$d/.lock" 2>/dev/null || stat -f %m "$d/.lock" 2>/dev/null; } )
    now=$(date -u +%s)
    if [[ "$mt" =~ ^[0-9]+$ ]] && [ $((now - mt)) -lt "$GA_MIRROR_LOCK_STALE" ] && [ -z "$pid" ]; then
        # Замок только что взят, pid ещё не записан
        return 0
    fi
    rm -rf "$d/.lock" 2>/dev/null || true
    return 1
}
ga_mirror_lock_take() {
    local d="$1"
    ga_mirror_lock_alive "$d" && return 1
    mkdir "$d/.lock" 2>/dev/null || return 1
    { printf '%s\n' "$$" >"$d/.lock/pid"; } 2>/dev/null || true
    return 0
}
ga_mirror_lock_drop() { rm -rf "$1/.lock" 2>/dev/null || true; }

# ga_mirror_published_file <каталог> → stdout имя опубликованного файла (есть
# meta.json и сам файл на диске), иначе пусто и rc 1. ЭТО и есть «копия готова»
# — что бы ни лежало в state.json.
ga_mirror_published_file() {
    local d="$1" f
    f=$(jq -r '.file // ""' "$d/meta.json" 2>/dev/null)
    [[ "$f" =~ $GA_MIRROR_FILE_RE ]] && [ -f "$d/$f" ] || return 1
    printf '%s' "$f"
}
# Возраст state.json (секунд по полю updated); нечитаемо — 0.
ga_mirror_state_age() {
    local d="$1" upd now ts
    upd=$(jq -r '.updated // ""' "$d/state.json" 2>/dev/null)
    ts=$(date -u -d "$upd" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$upd" +%s 2>/dev/null) || ts=""
    [[ "$ts" =~ ^[0-9]+$ ]] || { printf '0'; return 0; }
    now=$(date -u +%s)
    printf '%s' $((now - ts))
}
# ga_mirror_stale <каталог> — загрузка брошена: state.json обещает downloading
# (или queued без заявки, старше GA_MIRROR_QUEUE_GRACE — воркер так и не взял
# замок), а живого замка нет: процесс убит или сервер перезагружен. Без этого
# страница вечно показывала бы «загружается, 0 %», заявка не принималась бы,
# а тик пару не трогал.
GA_MIRROR_QUEUE_GRACE=120
ga_mirror_stale() {
    local d="$1" st
    st=$(jq -r '.state // "none"' "$d/state.json" 2>/dev/null)
    case "$st" in
        downloading) ;;
        queued) [ -f "$d/request" ] && return 1
                [ "$(ga_mirror_state_age "$d")" -gt "$GA_MIRROR_QUEUE_GRACE" ] || return 1 ;;
        *) return 1 ;;
    esac
    ! ga_mirror_lock_alive "$d"
}
# ga_mirror_normalize <каталог> — привести state.json к факту (зовёт тик):
# брошенная загрузка → failed (stale); опубликованная пара → ready (ошибка
# сверки остаётся полем error). stdout: stale | ready | same.
ga_mirror_normalize() {
    local d="$1" pub st err
    if ga_mirror_stale "$d"; then
        pub=$(ga_mirror_published_file "$d") || pub=""
        if [ -n "$pub" ]; then
            ga_mirror_state_write "$d" ready "$(jq -c '{version: (.version // ""), file: (.file // ""), bytes: (.size // 0), total: (.size // 0), error: "stale"}' "$d/meta.json" 2>/dev/null)" || true
        else
            ga_mirror_state_write "$d" failed '{"error": "stale"}' || true
        fi
        log_warning "$(tf mirror_warn_stale "$(basename "$(dirname "$d")")" "$(basename "$d")")"
        printf 'stale'
        return 0
    fi
    pub=$(ga_mirror_published_file "$d") || { printf 'same'; return 0; }
    st=$(jq -r '.state // "none"' "$d/state.json" 2>/dev/null)
    if [ "$st" != ready ] && ! ga_mirror_lock_alive "$d"; then
        err=$(jq -r '.error // ""' "$d/state.json" 2>/dev/null)
        ga_mirror_state_write "$d" ready "$(jq -c --arg e "$err" '{version: (.version // ""), file: (.file // ""), bytes: (.size // 0), total: (.size // 0)} + (if $e == "" then {} else {error: $e} end)' "$d/meta.json" 2>/dev/null)" || true
        printf 'ready'
        return 0
    fi
    printf 'same'
}

# Сумма опубликованных сборок (байт) — по meta.json каждой пары; [исключить]
# — пара, чей файл будет заменён.
ga_mirror_used_bytes() {
    local skip="${1:-}" d total=0 size
    for d in "$(ga_mirror_dir)"/*/*; do
        [ -f "$d/meta.json" ] || continue
        [ -n "$skip" ] && [ "$d" = "$skip" ] && continue
        size=$(jq -r '.size // 0' "$d/meta.json" 2>/dev/null)
        [[ "$size" =~ ^[0-9]+$ ]] && total=$((total + size))
    done
    printf '%s' "$total"
}

# ── Сеть ─────────────────────────────────────────────────────────────────────
# ga_mirror_curl <url> <файл> [таймаут] — единственная точка выхода в сеть.
# В dry-run без подставного curl наружу не ходим вовсе.
ga_mirror_curl() {
    local url="$1" out="$2" timeout="${3:-$GA_MIRROR_API_TIMEOUT}" max="${4:-}" bin
    local -a limit=()
    bin=$(ga_mirror_curl_bin)
    if ga_dry && [ -z "${GOAMNEZIA_MIRROR_CURL:-}" ]; then
        ga_dry_echo "curl $url"
        ga_err mirror_fetch_failed "$(t mirror_err_dry_network)"
        return 1
    fi
    command -v "$bin" >/dev/null 2>&1 || { ga_err no_curl "$(t mirror_err_no_curl)"; return 1; }
    # Предел размера ВО ВРЕМЯ загрузки: размер из API точный, и всё сверх него
    # — чужой файл, обрывать его надо на лету, а не после того, как он лёг на диск.
    if [[ "$max" =~ ^[0-9]+$ ]] && [ "$max" -gt 0 ]; then limit=(--max-filesize "$max"); fi
    # --proto '=https': ни редиректа на http, ни file:// из подмены адреса.
    if ! "$bin" -fsSL --proto '=https' --max-time "$timeout" ${limit[@]+"${limit[@]}"} -A "goamnezia-mirror" \
            -H 'Accept: application/vnd.github+json' -o "$out" "$url" 2>/dev/null; then
        rm -f "$out" 2>/dev/null || true
        ga_err mirror_fetch_failed "$(tf mirror_err_fetch "$url")"
        return 1
    fi
    return 0
}
# ga_mirror_release <repo> → stdout JSON последнего релиза (releases/latest —
# GitHub сам отдаёт здесь только не-draft и не-prerelease).
ga_mirror_release() {
    local repo="$1" tmp js
    tmp=$(mktemp "${TMPDIR:-/tmp}/goamnezia-release.XXXXXX") || { ga_err write_failed "$(t mirror_err_tmp)"; return 1; }
    if ! ga_mirror_curl "$(ga_mirror_api_base)/${repo}/releases/latest" "$tmp"; then rm -f "$tmp"; return 1; fi
    js=$(jq -c 'select(type == "object" and (.tag_name // "") != "")' "$tmp" 2>/dev/null)
    rm -f "$tmp"
    [ -n "$js" ] || { ga_err mirror_fetch_failed "$(tf mirror_err_no_release "$repo")"; return 1; }
    printf '%s' "$js"
}
# ga_mirror_pick_asset <release json> <regex> → stdout JSON {name, size, url, digest}
ga_mirror_pick_asset() {
    local js
    js=$(jq -c --arg re "$2" '[.assets[]? | select((.name // "") | test($re))] | first // empty
        | {name: .name, size: (.size // 0), url: (.browser_download_url // ""), digest: (.digest // "")}' <<<"$1" 2>/dev/null)
    [ -n "$js" ] || return 1
    printf '%s' "$js"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Загрузка одной пары (фоновый процесс или dry-run в текущем)
# ══════════════════════════════════════════════════════════════════════════════
# _mirror_fail <каталог> <код> <сообщение> — состояние failed с кодом и ga_err.
_mirror_fail() {
    local d="$1" code="$2" msg="$3" pub
    # Опубликованная копия остаётся ready: провал (чаще всего суточной сверки
    # новой версии) — поле error, а не состояние. Иначе страница прятала бы
    # готовый файл из-за неудачной проверки обновления.
    pub=$(ga_mirror_published_file "$d")
    if [ -n "$pub" ]; then
        ga_mirror_state_write "$d" ready "$(jq -c --arg e "$code" --arg m "$msg" \
            '{version: (.version // ""), file: (.file // ""), bytes: (.size // 0), total: (.size // 0), error: $e, message: $m}' \
            "$d/meta.json" 2>/dev/null)" || true
    else
        ga_mirror_state_write "$d" failed "$(jq -nc --arg e "$code" --arg m "$msg" '{error: $e, message: $m}')" || true
    fi
    ga_mirror_audit mirror-fetch "app=$(basename "$(dirname "$d")") platform=$(basename "$d") error=${code}"
    ga_err "$code" "$msg"
    return 1
}
# ga_mirror_worker <app> <platform> — вся загрузка целиком. rc 0 — сборка
# опубликована (или уже была той же версии).
ga_mirror_worker() {
    local app="$1" platform="$2" spec d repo pattern license rel tag asset name size digest url sha
    local max_file max_total used free_kb need_kb part meta tmp cur_file cur_ver lic_ok=0 lic_name
    ga_mirror_check_target "$app" "$platform" || return $?
    spec=$(ga_mirror_spec "$app" "$platform") || return $?
    d=$(ga_mirror_pair_dir "$app" "$platform")
    mkdir -p "$d" 2>/dev/null || { ga_err write_failed "$(tf mirror_err_write "$d")"; return 1; }
    chmod 755 "$(ga_mirror_dir)" "$(dirname "$d")" "$d" 2>/dev/null || true
    if ! ga_mirror_lock_take "$d"; then
        ga_err mirror_busy "$(tf mirror_err_busy "$app" "$platform")" 2
        return 2
    fi
    # Замок снимается при любом выходе: и по return, и по сигналу.
    # shellcheck disable=SC2064
    trap "ga_mirror_lock_drop '$d'" RETURN
    repo=$(jq -r '.repo' <<<"$spec"); pattern=$(jq -r '.pattern' <<<"$spec"); license=$(jq -r '.license' <<<"$spec")
    ga_mirror_state_write "$d" queued '{}' || true

    rel=$(ga_mirror_release "$repo") || { _mirror_fail "$d" mirror_fetch_failed "${GA_ERR_MSG:-$(tf mirror_err_no_release "$repo")}"; return 1; }
    tag=$(jq -r '.tag_name' <<<"$rel")
    if ! asset=$(ga_mirror_pick_asset "$rel" "$pattern"); then
        _mirror_fail "$d" mirror_fetch_failed "$(tf mirror_err_no_asset "$repo" "$tag" "$pattern")"; return 1
    fi
    name=$(jq -r '.name' <<<"$asset"); size=$(jq -r '.size' <<<"$asset")
    url=$(jq -r '.url' <<<"$asset"); digest=$(jq -r '.digest' <<<"$asset")
    if ! [[ "$name" =~ $GA_MIRROR_FILE_RE ]] || ! [[ "$size" =~ ^[0-9]+$ ]] || [ -z "$url" ]; then
        _mirror_fail "$d" mirror_fetch_failed "$(tf mirror_err_no_asset "$repo" "$tag" "$pattern")"; return 1
    fi
    # Подлинность — ДО загрузки: без digest от API сверять файл не с чем, а
    # тянуть сотни мегабайт, чтобы потом выбросить, незачем.
    if ! [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]]; then
        _mirror_fail "$d" mirror_unverified "$(tf mirror_err_no_digest "$name" "$tag")"; return 1
    fi
    digest="${digest#sha256:}"
    # Та же версия и тот же файл уже опубликованы — качать нечего.
    cur_ver=$(jq -r '.version // ""' "$d/meta.json" 2>/dev/null); cur_file=$(jq -r '.file // ""' "$d/meta.json" 2>/dev/null)
    if [ "$cur_ver" = "$tag" ] && [ "$cur_file" = "$name" ] && [ -f "$d/$name" ] \
       && [ "$(jq -r '.sha256 // ""' "$d/meta.json" 2>/dev/null)" = "$digest" ]; then
        ga_mirror_state_write "$d" ready "$(jq -nc --arg v "$tag" --arg f "$name" --argjson s "$size" '{version: $v, file: $f, bytes: $s, total: $s}')" || true
        log_dim "$(tf mirror_current "$app" "$platform" "$tag")"
        return 0
    fi
    # Пределы: файл, итог каталога (без файла, который заменяем), свободное место.
    max_file=$(ga_mirror_max_file_mb); max_total=$(ga_mirror_max_total_mb)
    if [ "$size" -gt $((max_file * 1048576)) ]; then
        _mirror_fail "$d" mirror_too_big "$(tf mirror_err_too_big "$name" $((size / 1048576)) "$max_file")"; return 1
    fi
    used=$(ga_mirror_used_bytes "$d")
    if [ $((used + size)) -gt $((max_total * 1048576)) ]; then
        # Мегабайты с округлением вверх: «1 МБ больше предела 1 МБ» читалось бы как ошибка счёта
        _mirror_fail "$d" mirror_no_space "$(tf mirror_err_total "$(( (used + size + 1048575) / 1048576 ))" "$max_total")"; return 1
    fi
    free_kb=$(ga_mirror_free_kb "$d"); [[ "$free_kb" =~ ^[0-9]+$ ]] || free_kb=0
    need_kb=$(( size / 1024 + GA_MIRROR_FREE_RESERVE_MB * 1024 ))
    if [ "$free_kb" -lt "$need_kb" ]; then
        _mirror_fail "$d" mirror_no_space "$(tf mirror_err_disk $((free_kb / 1024)) $((need_kb / 1024)))"; return 1
    fi

    part="$d/.${name}.part"
    rm -f "$part" 2>/dev/null || true
    ga_mirror_state_write "$d" downloading "$(jq -nc --arg v "$tag" --arg f "$name" --argjson s "$size" '{version: $v, file: $f, bytes: 0, total: $s}')" || true
    ga_mirror_audit mirror-fetch "app=${app} platform=${platform} version=${tag} file=${name} size=${size} start"
    log_info "$(tf mirror_started "$app" "$platform" "$tag" $((size / 1048576)))"
    if ! ga_mirror_curl "$url" "$part" "$GA_MIRROR_CURL_TIMEOUT" "$size"; then
        rm -f "$part" 2>/dev/null || true
        _mirror_fail "$d" mirror_fetch_failed "${GA_ERR_MSG:-$(tf mirror_err_fetch "$url")}"; return 1
    fi
    # Сверка размера и sha256 с тем, что обещал API: файл с чужим содержимым
    # не публикуется, каким бы «настоящим» ни выглядел.
    if [ "$(ga_mirror_file_size "$part")" != "$size" ]; then
        rm -f "$part" 2>/dev/null || true
        _mirror_fail "$d" mirror_fetch_failed "$(tf mirror_err_size "$name")"; return 1
    fi
    sha=$(ga_mirror_sha256 "$part")
    if [ "$sha" != "$digest" ]; then
        rm -f "$part" 2>/dev/null || true
        _mirror_fail "$d" mirror_unverified "$(tf mirror_err_sha "$name")"; return 1
    fi
    # Лицензия с того же тега; SOURCE.txt — ссылка на исходники версии.
    for lic_name in LICENSE LICENSE.md LICENSE.txt COPYING; do
        if ga_mirror_curl "$(ga_mirror_raw_base)/${repo}/${tag}/${lic_name}" "$d/.LICENSE.part" 2>/dev/null; then lic_ok=1; break; fi
    done
    if [ "$lic_ok" = 1 ]; then
        chmod 644 "$d/.LICENSE.part" 2>/dev/null; mv -f "$d/.LICENSE.part" "$d/LICENSE"
    else
        rm -f "$d/.LICENSE.part" 2>/dev/null || true
        log_warning "$(tf mirror_warn_license "$repo" "$tag")"
        printf '%s\nhttps://github.com/%s/blob/%s/LICENSE\n' "$license" "$repo" "$tag" >"$d/.LICENSE.part" \
            && chmod 644 "$d/.LICENSE.part" && mv -f "$d/.LICENSE.part" "$d/LICENSE"
    fi
    printf 'https://github.com/%s/tree/%s\n%s\n' "$repo" "$tag" "$url" >"$d/.SOURCE.part" \
        && chmod 644 "$d/.SOURCE.part" && mv -f "$d/.SOURCE.part" "$d/SOURCE.txt"
    # Публикация: атомарный перенос, потом meta.json, потом снятие прежней
    # версии — в любой момент в каталоге есть либо старая пара файл+meta, либо
    # новая.
    chmod 644 "$part" 2>/dev/null || true
    mv -f "$part" "$d/$name" || { _mirror_fail "$d" write_failed "$(tf mirror_err_write "$d/$name")"; return 1; }
    meta=$(jq -nc --arg app "$app" --arg p "$platform" --arg v "$tag" --arg f "$name" --argjson s "$size" \
        --arg sha "$digest" --arg now "$(ga_now)" --arg url "$url" --arg repo "$repo" --arg lic "$license" \
        '{app: $app, platform: $p, version: $v, file: $f, size: $s, sha256: $sha, fetched: $now,
          source_url: ("https://github.com/" + $repo + "/tree/" + $v), download_url: $url, repo: $repo, license: $lic}')
    tmp=$(mktemp "$d/.meta.XXXXXX") && printf '%s\n' "$meta" >"$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$d/meta.json" \
        || { _mirror_fail "$d" write_failed "$(tf mirror_err_write "$d/meta.json")"; return 1; }
    if [ -n "$cur_file" ] && [ "$cur_file" != "$name" ] && [[ "$cur_file" =~ $GA_MIRROR_FILE_RE ]]; then
        rm -f "$d/$cur_file" 2>/dev/null || true
    fi
    ga_mirror_state_write "$d" ready "$(jq -nc --arg v "$tag" --arg f "$name" --argjson s "$size" '{version: $v, file: $f, bytes: $s, total: $s}')" || true
    ga_mirror_audit mirror-fetch "app=${app} platform=${platform} version=${tag} file=${name} size=${size} ok"
    log_success "$(tf mirror_ready "$app" "$platform" "$tag")"
    return 0
}

# Запуск загрузки в фоне. systemd-run даёт юнит с журналом и не наследует
# ничего от вызывающего; без него — отсоединённый процесс с pid-файлом.
_mirror_spawn() {
    local app="$1" platform="$2" d self unit
    d=$(ga_mirror_pair_dir "$app" "$platform")
    self="$_GA_MIRROR_LIB_DIR/mirror.sh"
    if ga_dry || [ "${GOAMNEZIA_MIRROR_FOREGROUND:-0}" = "1" ]; then
        ga_mirror_worker "$app" "$platform"
        return $?
    fi
    unit="goamnezia-mirror-${app}-${platform}"
    if command -v systemd-run >/dev/null 2>&1; then
        if systemd-run --unit="$unit" --collect --quiet \
               --setenv=GOAMNEZIA_DIR="${GOAMNEZIA_DIR:-/opt/goamnezia}" \
               --setenv=GOAMNEZIA_AUDIT_LOG="${AUDIT_LOG:-/var/log/goamnezia-audit.log}" \
               --setenv=GOAMNEZIA_WHO="${GOAMNEZIA_WHO:-ssh}" \
               /bin/bash "$self" --worker "$app" "$platform" >/dev/null 2>&1; then
            return 0
        fi
    fi
    # Запасной путь без systemd-run. Дочерний процесс наследовал дескриптор замка config.lock (мост держит его
    # на время действия) и флаг GA_CONFIG_LOCK_HELD: замок висел всю загрузку, а сам рабочий писал без замка
    # (находка SR-38; у share_server.py то же закрыто os.closerange). Флаг — долой, дескрипторы выше 2 — закрыть;
    # замок моста (fd 9, install.sh _action_dispatch) — ещё и явно у самого exec (L3-13 / TAIL-7): закрытие по
    # списку зависит от /proc, а этот дескриптор держать загрузку не должен ни при каком раскладе.
    (
        unset GA_CONFIG_LOCK_HELD
        for _fd in $(ls "/proc/$BASHPID/fd" 2>/dev/null || seq 3 63); do
            [[ "$_fd" =~ ^[0-9]+$ ]] && [ "$_fd" -gt 2 ] && eval "exec ${_fd}>&-" 2>/dev/null
        done
        exec nohup /bin/bash "$self" --worker "$app" "$platform" >"$d/worker.log" 2>&1 </dev/null 9>&-
    ) &
    { printf '%s\n' "$!" >"$d/worker.pid"; } 2>/dev/null || true
    disown 2>/dev/null || true
    return 0
}

# Учёт стартов загрузок за час (заявки со страниц): файл с эпохами.
ga_mirror_hour_count() {
    local f now
    f="$(ga_mirror_dir)/.fetches"
    [ -f "$f" ] || { printf '0'; return 0; }
    now=$(date -u +%s)
    awk -v now="$now" '$1 ~ /^[0-9]+$/ && now - $1 < 3600 { n++ } END { print n + 0 }' "$f" 2>/dev/null || printf '0'
}
ga_mirror_hour_record() {
    local f now tmp
    f="$(ga_mirror_dir)/.fetches"; now=$(date -u +%s); tmp="$f.tmp"
    mkdir -p "$(ga_mirror_dir)" 2>/dev/null || return 0
    # Внешние скобки обязательны: ошибку ПЕРЕНАПРАВЛЕНИЯ печатает сама оболочка,
    # и 2>/dev/null у команды её не гасит (правило lib/share.sh, ga_share_read_num).
    { { awk -v now="$now" '$1 ~ /^[0-9]+$/ && now - $1 < 3600' "$f" 2>/dev/null; printf '%s\n' "$now"; } >"$tmp"; } 2>/dev/null \
        && mv -f "$tmp" "$f" 2>/dev/null
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  Публичные функции
# ══════════════════════════════════════════════════════════════════════════════
# mirror_fetch <app> <platform> → stdout JSON {app, platform, state}. На живом
# сервере state — queued (загрузка ушла в фон), в dry-run — итог (ready | failed).
mirror_fetch() { ga_with_config_lock _mirror_fetch_locked "$@"; }
_mirror_fetch_locked() {
    local app="${1:-}" platform="${2:-}" d rc=0
    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t mirror_err_no_jq)"; return 1; }
    ga_mirror_check_target "$app" "$platform" || return $?
    ga_mirror_spec "$app" "$platform" >/dev/null || return $?
    d=$(ga_mirror_pair_dir "$app" "$platform")
    mkdir -p "$d" 2>/dev/null || { ga_err write_failed "$(tf mirror_err_write "$d")"; return 1; }
    chmod 755 "$(ga_mirror_dir)" "$(dirname "$d")" "$d" 2>/dev/null || true
    if ga_mirror_lock_alive "$d"; then
        ga_err mirror_busy "$(tf mirror_err_busy "$app" "$platform")" 2
        return 2
    fi
    rm -f "$d/request" 2>/dev/null || true
    ga_mirror_state_write "$d" queued '{}' || { ga_err write_failed "$(tf mirror_err_write "$d/state.json")"; return 1; }
    ga_mirror_hour_record
    { date -u +%s >"$d/.last_fetch"; } 2>/dev/null || true
    log_info "$(tf mirror_queued "$app" "$platform")"
    _mirror_spawn "$app" "$platform" || rc=$?
    jq -nc --arg a "$app" --arg p "$platform" --arg s "$(jq -r '.state' <<<"$(ga_mirror_state_read "$d")")" \
        '{app: $a, platform: $p, state: $s}'
    return "$rc"
}

# mirror_remove <app> <platform> → stdout JSON {app, platform}
mirror_remove() { ga_with_config_lock _mirror_remove_locked "$@"; }
_mirror_remove_locked() {
    local app="${1:-}" platform="${2:-}" d
    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t mirror_err_no_jq)"; return 1; }
    ga_mirror_check_target "$app" "$platform" || return $?
    d=$(ga_mirror_pair_dir "$app" "$platform")
    if ga_mirror_lock_alive "$d"; then
        ga_err mirror_busy "$(tf mirror_err_busy "$app" "$platform")" 2
        return 2
    fi
    rm -rf "$d" 2>/dev/null || true
    rmdir "$(dirname "$d")" 2>/dev/null || true
    ga_mirror_audit mirror-remove "app=${app} platform=${platform}"
    log_success "$(tf mirror_removed "$app" "$platform")"
    jq -nc --arg a "$app" --arg p "$platform" '{app: $a, platform: $p}'
}

# mirror_list → stdout JSON {max_file_mb, max_total_mb, used_mb, items: [...]}
mirror_list() {
    local d app platform items='[]' st meta row used got pfile eff
    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t mirror_err_no_jq)"; return 1; }
    for d in "$(ga_mirror_dir)"/*/*; do
        [ -d "$d" ] || continue
        platform=$(basename "$d"); app=$(basename "$(dirname "$d")")
        [[ "$app" =~ $GA_MIRROR_APP_RE ]] && [[ "$platform" =~ $GA_MIRROR_PLATFORM_RE ]] || continue
        st=$(ga_mirror_state_read "$d"); meta=$(ga_mirror_meta_read "$d")
        [ "$meta" != null ] || [ "$(jq -r '.state' <<<"$st")" != none ] || continue
        # Байты идущей загрузки — по размеру .<файл>.part, как считает служба
        # страниц (pages_server.status): в state.json воркер пишет 0 в начале и
        # size в конце, и по нему проценты не видны всю загрузку.
        got=$(jq -r '.bytes // 0' <<<"$st"); [[ "$got" =~ ^[0-9]+$ ]] || got=0
        if [ "$(jq -r '.state // ""' <<<"$st")" = downloading ]; then
            pfile=$(jq -r '.file // ""' <<<"$st")
            if [[ "$pfile" =~ $GA_MIRROR_FILE_RE ]] && [ -f "$d/.${pfile}.part" ]; then
                got=$(ga_mirror_file_size "$d/.${pfile}.part"); [[ "$got" =~ ^[0-9]+$ ]] || got=0
            fi
        fi
        # Состояние по факту (чтение — без записи в state.json, её делает тик):
        # брошенная загрузка — failed (stale), опубликованная копия — ready,
        # что бы ни лежало в state.json. Считается ПОСЛЕ байтов: они берутся по
        # тому, что написано в state.json, и .part брошенной загрузки тоже виден.
        eff=$(jq -r '.state // "none"' <<<"$st")
        if ga_mirror_stale "$d"; then
            st=$(jq -c '. + {state: "failed", error: (.error // "stale")}' <<<"$st"); eff=failed
        fi
        ga_mirror_published_file "$d" >/dev/null && eff=ready
        row=$(jq -nc --arg a "$app" --arg p "$platform" --argjson st "$st" --argjson meta "$meta" --arg eff "$eff" \
            --argjson busy "$(ga_mirror_lock_alive "$d" && printf true || printf false)" --argjson got "$got" \
            '{app: $a, platform: $p, state: $eff,
              version: (($meta.version // $st.version) // ""), file: (($meta.file // $st.file) // ""),
              size: (($meta.size // $st.total) // 0), sha256: ($meta.sha256 // ""), fetched: ($meta.fetched // ""),
              error: ($st.error // ""), message: ($st.message // ""), bytes: $got,
              updated: ($st.updated // ""), busy: $busy, source_url: ($meta.source_url // ""),
              published: ($meta != null)}')
        items=$(jq -c --argjson i "$row" '. + [$i]' <<<"$items")
    done
    used=$(ga_mirror_used_bytes)
    jq -nc --argjson items "$items" --argjson mf "$(ga_mirror_max_file_mb)" --argjson mt "$(ga_mirror_max_total_mb)" \
        --argjson used "$used" \
        '{max_file_mb: $mf, max_total_mb: $mt, used_mb: (($used / 1048576) | floor), used_bytes: $used,
          items: $items, count: ($items | length)}'
}

# mirror_tick [daily] → stdout JSON {requests, started, deferred, checked, updates}
# Заявки со страниц с пределами §8; daily — сверка версий уже скачанного.
mirror_tick() { ga_with_config_lock _mirror_tick_locked "$@"; }
_mirror_tick_locked() {
    local daily="${1:-}" d app platform now last requests=0 started=0 deferred=0 checked=0 updates=0
    local rel tag cur repo spec
    command -v jq >/dev/null 2>&1 || { ga_err no_jq "$(t mirror_err_no_jq)"; return 1; }
    now=$(date -u +%s)
    # Сначала — состояние по факту у каждой пары: брошенные загрузки → failed
    # (заявка снова принимается), опубликованные → ready. Иначе «загружается»
    # от убитого воркера жило бы вечно, а провал сверки прятал готовый файл.
    for d in "$(ga_mirror_dir)"/*/*; do
        [ -f "$d/state.json" ] || continue
        platform=$(basename "$d"); app=$(basename "$(dirname "$d")")
        [[ "$app" =~ $GA_MIRROR_APP_RE ]] && [[ "$platform" =~ $GA_MIRROR_PLATFORM_RE ]] || continue
        ga_mirror_normalize "$d" >/dev/null
    done
    for d in "$(ga_mirror_dir)"/*/*; do
        [ -f "$d/request" ] || continue
        platform=$(basename "$d"); app=$(basename "$(dirname "$d")")
        [[ "$app" =~ $GA_MIRROR_APP_RE ]] && [[ "$platform" =~ $GA_MIRROR_PLATFORM_RE ]] || { rm -f "$d/request"; continue; }
        requests=$((requests + 1))
        # Заявка на пару, которая уже опубликована или качается, — снимается:
        # ей ничего не нужно (опубликованная уже приведена к ready выше).
        if ga_mirror_lock_alive "$d" || ga_mirror_published_file "$d" >/dev/null; then rm -f "$d/request"; continue; fi
        last=$( { tr -d '[:space:]' <"$d/.last_fetch"; } 2>/dev/null ); [[ "$last" =~ ^[0-9]+$ ]] || last=0
        if [ $((now - last)) -lt "$GA_MIRROR_PAIR_INTERVAL" ] || [ "$(ga_mirror_hour_count)" -ge "$GA_MIRROR_HOUR_LIMIT" ]; then
            # Предел: заявка остаётся ждать следующего тика, страница видит queued.
            deferred=$((deferred + 1))
            ga_mirror_state_write "$d" queued '{"deferred": true}' || true
            continue
        fi
        if _mirror_fetch_locked "$app" "$platform" >/dev/null; then started=$((started + 1)); else started=$((started + 1)); fi
    done
    if [ "$daily" = daily ]; then
        for d in "$(ga_mirror_dir)"/*/*; do
            [ -f "$d/meta.json" ] || continue
            platform=$(basename "$d"); app=$(basename "$(dirname "$d")")
            [[ "$app" =~ $GA_MIRROR_APP_RE ]] && [[ "$platform" =~ $GA_MIRROR_PLATFORM_RE ]] || continue
            ga_mirror_lock_alive "$d" && continue
            spec=$(ga_mirror_spec "$app" "$platform" 2>/dev/null) || continue
            repo=$(jq -r '.repo' <<<"$spec")
            checked=$((checked + 1))
            rel=$(ga_mirror_release "$repo" 2>/dev/null) || continue
            tag=$(jq -r '.tag_name' <<<"$rel"); cur=$(jq -r '.version // ""' "$d/meta.json" 2>/dev/null)
            [ -n "$tag" ] && [ "$tag" != "$cur" ] || continue
            updates=$((updates + 1))
            _mirror_fetch_locked "$app" "$platform" >/dev/null || true
        done
    fi
    log_dim "$(tf mirror_tick_done "$requests" "$started" "$deferred" "$checked" "$updates")"
    jq -nc --argjson r "$requests" --argjson s "$started" --argjson d "$deferred" --argjson c "$checked" --argjson u "$updates" \
        '{requests: $r, started: $s, deferred: $d, checked: $c, updates: $u}'
}

# ── Запуск файлом: фоновая загрузка одной пары ────────────────────────────────
# bash lib/mirror.sh --worker <app> <platform>: подключает общую библиотеку и
# словарь, ведёт загрузку и выходит с её кодом. Через мост не идёт нарочно —
# см. шапку.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -uo pipefail
    if [ "${1:-}" != "--worker" ] || [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
        printf 'usage: mirror.sh --worker <app> <platform>\n' >&2
        exit 2
    fi
    # shellcheck source=lib/common.sh
    source "$_GA_MIRROR_LIB_DIR/common.sh"
    # shellcheck source=lib/i18n.sh
    source "$_GA_MIRROR_LIB_DIR/i18n.sh"
    load_language "$(detect_language)" >/dev/null 2>&1 || true
    ga_mirror_worker "$2" "$3"
    exit $?
fi
