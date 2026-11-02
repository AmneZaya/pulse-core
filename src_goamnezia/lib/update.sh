#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# goAmnezia pro — lib/update.sh: откат неудачного обновления (находка OPS-02)
#
# Обновление — транзакция из трёх частей.
#   1. bootstrap.sh ДО замены кода кладёт прежний код рядом с продуктом, в $GOAMNEZIA_DIR/.prev_code/:
#        files/          прежние файлы — жёсткими ссылками (места не занимают: новые файлы ложатся через rename,
#                        старые inode остаются за снимком), без них — копией;
#        manifest        «old <путь>» — файл был и сохранён, «new <путь>» — появился с новой версией;
#        meta            from/to — версии, from_ref/to_ref — коммиты, branch, at;
#        install-source  прежний .install-source (его нет — не было и до обновления).
#      Новый код до этого обязан запуститься из временного каталога (bash -n, компиляция python-частей,
#      install.sh --version) — нет, и обновление не начинается вовсе. Раскладка — через rename: сначала все
#      файлы рядом с целями, потом переименование; оборвалась на втором шаге — прежний код из снимка обратно.
#   2. Новый код при первом пишущем вызове (меню сразу после загрузчика, тик сторожа, бот) мигрирует данные:
#      снимок preupgrade, юниты systemd как до миграции (units/), шаги в подоболочке, версия в config.json и
#      отметка — после всех шагов (OPS-03), затем проверка «новый код отвечает на status». Прошло — обновление
#      завершено (ga_upd_commit), .prev_code убирается.
#   3. Не прошло (снимок не снялся, шаг упал, версия не записалась, status не отвечает) — ga_upd_rollback:
#      данные из архива preupgrade, юниты как до миграции, прежний код и .install-source; отметка
#      .update_failed.json (status → update_rollback, строка в шапке меню), событие боту update_rolled_back,
#      строка в журнале действий. Вызывающий после отката отдаёт тот же вызов прежнему коду (install.sh).
#
# Код запущен не из каталога продукта (стенд: код из репозитория, данные во временном каталоге) — откатывать
# нечего, модуль молчит, и миграция идёт как раньше.
# ══════════════════════════════════════════════════════════════════════════════

ga_upd_prev_dir()    { printf '%s/.prev_code' "${GOAMNEZIA_DIR:-/opt/goamnezia}"; }
ga_upd_notice_file() { printf '%s/.update_failed.json' "${GOAMNEZIA_DIR:-/opt/goamnezia}"; }

# _ga_upd_kv <файл> <ключ> → значение первой строки «ключ=значение».
_ga_upd_kv() {
    local line
    line=$(grep -m1 -- "^$2=" "$1" 2>/dev/null) || return 1
    printf '%s' "${line#*=}"
}

# _ga_upd_same_dir <a> <b> — один и тот же каталог по физическому пути.
_ga_upd_same_dir() {
    local a b
    a=$(cd "${1:-/nonexistent}" 2>/dev/null && pwd -P) || return 1
    b=$(cd "${2:-/nonexistent}" 2>/dev/null && pwd -P) || return 1
    [ "$a" = "$b" ]
}

# _ga_upd_ver_lt A B → 0, если A строго меньше B (sort -V, как у _ver_lt в install.sh).
_ga_upd_ver_lt() {
    [ "$1" = "$2" ] && return 1
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V 2>/dev/null | head -n 1)" = "$1" ]
}

# ga_upd_pending — идёт обновление на ЭТУ версию, и прежний код лежит рядом: миграция — под защитой отката.
# Нет — если код запущен не из каталога продукта. Второго отката подряд не бывает: удавшийся откат забирает
# снимок с собой.
ga_upd_pending() {
    local prev
    prev=$(ga_upd_prev_dir)
    [ -f "$prev/meta" ] && [ -f "$prev/manifest" ] || return 1
    [ "$(_ga_upd_kv "$prev/meta" to)" = "$GOAMNEZIA_VERSION" ] || return 1
    _ga_upd_same_dir "${SCRIPT_DIR:-}" "${GOAMNEZIA_DIR:-/opt/goamnezia}"
}

# ga_upd_prev_version → версия прежнего кода (из meta снимка).
ga_upd_prev_version() { _ga_upd_kv "$(ga_upd_prev_dir)/meta" from | tr -cd '0-9A-Za-z.+-'; }

# ── Юниты systemd ────────────────────────────────────────────────────────────
# Там же, где их пишет lib/timers.sh: в сухом прогоне — только каталог стенда (GOAMNEZIA_SYSTEMD_DIR).
_ga_upd_units_dir() { printf '%s' "${GOAMNEZIA_SYSTEMD_DIR:-/etc/systemd/system}"; }
_ga_upd_units_ok() { [ "${GOAMNEZIA_DRY_RUN:-0}" != 1 ] || [ -n "${GOAMNEZIA_SYSTEMD_DIR:-}" ]; }
_ga_upd_systemctl() {
    if [ "${GOAMNEZIA_DRY_RUN:-0}" = 1 ]; then printf 'DRY: systemctl %s\n' "$*" >&2; return 0; fi
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl "$@" >/dev/null 2>&1
}

# ga_upd_units_snapshot — юниты продукта (goamnezia-*.service и *.timer) как до миграции. Новая версия пишет
# свои (таймеры, служба изоляции), и после отката прежнему коду незнакомый юнит звал бы то, чего тот не знает.
# Один раз на обновление: повтор оборванной миграции (OPS-03) снимок не переписывает.
ga_upd_units_snapshot() {
    local prev dir f
    prev=$(ga_upd_prev_dir)
    [ -d "$prev" ] && _ga_upd_units_ok || return 0
    [ -f "$prev/units.list" ] && return 0
    dir=$(_ga_upd_units_dir)
    rm -rf "$prev/units" 2>/dev/null
    mkdir -p "$prev/units" 2>/dev/null || return 1
    { : >"$prev/units.list.new"; } 2>/dev/null || return 1
    for f in "$dir"/goamnezia-*.service "$dir"/goamnezia-*.timer; do
        [ -f "$f" ] || continue
        cp -p "$f" "$prev/units/" 2>/dev/null || return 1
        { printf '%s\n' "${f##*/}" >>"$prev/units.list.new"; } 2>/dev/null || return 1
    done
    mv -f "$prev/units.list.new" "$prev/units.list" 2>/dev/null
}

# ga_upd_units_restore → stdout: сколько юнитов возвращено. Появившиеся после снимка — выключаются и
# убираются, изменённые — прежними; systemd перечитывает юниты один раз.
ga_upd_units_restore() {
    local prev dir f name n=0
    prev=$(ga_upd_prev_dir)
    if [ ! -f "$prev/units.list" ] || ! _ga_upd_units_ok; then echo 0; return 0; fi
    dir=$(_ga_upd_units_dir)
    for f in "$dir"/goamnezia-*.service "$dir"/goamnezia-*.timer; do
        [ -f "$f" ] || continue
        name="${f##*/}"
        grep -qxF -- "$name" "$prev/units.list" && continue
        _ga_upd_systemctl disable --now "$name"
        rm -f "$f" 2>/dev/null && n=$((n + 1))
    done
    while IFS= read -r name; do
        [ -n "$name" ] && [ -f "$prev/units/$name" ] || continue
        cmp -s "$prev/units/$name" "$dir/$name" && continue
        cp -p "$prev/units/$name" "$dir/.$name.ga-rb" 2>/dev/null \
            && mv -f "$dir/.$name.ga-rb" "$dir/$name" 2>/dev/null && n=$((n + 1))
    done <"$prev/units.list"
    [ "$n" -gt 0 ] && _ga_upd_systemctl daemon-reload
    echo "$n"
}

# ── Данные ───────────────────────────────────────────────────────────────────
_ga_upd_wipe() {
    if type ga_wipe_dir >/dev/null 2>&1; then ga_wipe_dir "$1"; else rm -rf "$1" 2>/dev/null; fi
    return 0
}

# _ga_upd_restore_vhost <nginx.conf из архива> — vhost сайта, каким он был до миграции (её шаг собирает его из
# шаблона новой версии). nginx -t отказал — остаётся тот, что был.
_ga_upd_restore_vhost() {
    local src="$1" conf
    [ -f "$src" ] || return 0
    if type _ga_backup_nginx_conf >/dev/null 2>&1; then conf=$(_ga_backup_nginx_conf)
    else conf="${NGINX_SITE_CONF:-/etc/nginx/sites-available/goamnezia}"; fi
    [ -f "$conf" ] || return 0
    cmp -s "$src" "$conf" && return 0
    if type _ga_backup_external_ok >/dev/null 2>&1 && ! _ga_backup_external_ok "$conf"; then
        printf 'DRY: restore vhost %s\n' "$conf" >&2
        return 0
    fi
    cp -p "$conf" "$conf.ga-rb" 2>/dev/null || return 1
    if ! { cp "$src" "$conf.ga-new" && chmod 600 "$conf.ga-new" && mv -f "$conf.ga-new" "$conf"; } 2>/dev/null; then
        rm -f "$conf.ga-new" "$conf.ga-rb" 2>/dev/null
        return 1
    fi
    if [ "${GOAMNEZIA_DRY_RUN:-0}" != 1 ] && command -v nginx >/dev/null 2>&1; then
        if ! nginx -t >/dev/null 2>&1; then
            mv -f "$conf.ga-rb" "$conf" 2>/dev/null
            return 1
        fi
        _ga_upd_systemctl reload nginx
    fi
    rm -f "$conf.ga-rb" 2>/dev/null
    return 0
}

# ga_upd_restore_data <архив preupgrade> — вернуть то, что меняет миграция: config.json, users.json, state/
# контейнеров профилей (amnezia-*: копия конфига, ключи сервера, start.sh — ровно как в архиве) и vhost сайта.
# Это не восстановление из бэкапа: контейнеры не пересоздаются (миграция их не трогает — люди не теряют
# связь), бот и панель не останавливаются, пароль панели, доступы агентов и сертификаты не откатываются
# (миграция их не меняет, а откат доступов агентов — дыра SEC-C1). Снимок снят секунды назад под тем же
# замком конфигурации, который держит миграция, — чужих записей между ним и откатом нет. Новый шаг миграции,
# который трогает другие данные, обязан добавить их сюда.
ga_upd_restore_data() {
    local archive="${1:-}" tmp root d name f rel rc=0
    [ -n "$archive" ] && [ -f "$archive" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    if type ga_mktemp_secret_dir >/dev/null 2>&1; then
        tmp=$(ga_mktemp_secret_dir garb) || return 1
    else
        tmp=$(mktemp -d "${TMPDIR:-/tmp}/garb.XXXXXX") || return 1
    fi
    chmod 700 "$tmp" 2>/dev/null
    # Внутри — ключи всех людей и сервера: распаковка только для root (umask), без чужих владельцев и прав.
    if ! ( umask 077; tar xzf "$archive" -C "$tmp" --no-same-owner --no-same-permissions ) 2>/dev/null; then
        _ga_upd_wipe "$tmp"
        return 1
    fi
    root=$(find "$tmp" -maxdepth 1 -type d -name 'goamnezia_backup_*' 2>/dev/null | head -n 1)
    # Запасной снимок без lib/backup.sh (preupgrade_<версия>_<время>.tar.gz) лежит в корне архива.
    [ -n "$root" ] || root="$tmp"
    if [ ! -f "$root/config.json" ] || ! jq -e 'type == "object"' "$root/config.json" >/dev/null 2>&1; then
        _ga_upd_wipe "$tmp"
        return 1
    fi
    ga_put_json_file "$root/config.json" "$CONFIG_FILE" || rc=1
    if [ "$rc" = 0 ] && [ -f "$root/users.json" ]; then
        ga_put_json_file "$root/users.json" "$USERS_FILE" || rc=1
    fi
    if [ "$rc" = 0 ] && [ -d "$root/state" ]; then
        for d in "$root/state"/amnezia-*; do
            [ -d "$d" ] || continue
            name="${d##*/}"
            [[ "$name" =~ ^amnezia-[A-Za-z0-9_.-]+$ ]] || continue
            mkdir -p "$STATE_DIR/$name" 2>/dev/null || { rc=1; break; }
            # Появившееся с миграцией (копия конфига под новым именем) — прочь, остальное — как в архиве.
            while IFS= read -r f; do
                rel="${f#"$STATE_DIR/$name/"}"
                [ -e "$d/$rel" ] || rm -f "$f" 2>/dev/null
            done < <(find "$STATE_DIR/$name" -type f 2>/dev/null)
            cp -a "$d/." "$STATE_DIR/$name/" 2>/dev/null || rc=1
            chmod 700 "$STATE_DIR/$name" 2>/dev/null
            find "$STATE_DIR/$name" -type f -exec chmod 600 {} + 2>/dev/null
        done
    fi
    if [ "$rc" = 0 ]; then
        _ga_upd_restore_vhost "$root/nginx.conf" || log_warning "$(t mig_site_vhost_failed)"
    fi
    _ga_upd_wipe "$tmp"
    return "$rc"
}

# ── Код ──────────────────────────────────────────────────────────────────────
_ga_upd_path_ok() { [[ "${1:-}" =~ ^[A-Za-z0-9_][A-Za-z0-9_./-]*$ ]] && [[ "$1" != *..* ]]; }

# ga_upd_restore_code — прежний код из .prev_code на место: сохранённые файлы — обратно (rename, места не
# нужно), появившиеся с новой версией — прочь, .install-source — прежний (его не было — нет и теперь).
# Работающий процесс это не рушит: bash дочитывает свой install.sh по открытому дескриптору прежнего inode.
ga_upd_restore_code() {
    local prev kind path bad=0
    prev=$(ga_upd_prev_dir)
    [ -f "$prev/manifest" ] || return 1
    while read -r kind path; do
        _ga_upd_path_ok "$path" || continue
        case "$kind" in
            old)
                # Файла в снимке нет — его уже вернул прерванный прежде откат.
                [ -e "$prev/files/$path" ] || continue
                mkdir -p "$(dirname "$GOAMNEZIA_DIR/$path")" 2>/dev/null
                mv -f "$prev/files/$path" "$GOAMNEZIA_DIR/$path" 2>/dev/null \
                    || cp -p "$prev/files/$path" "$GOAMNEZIA_DIR/$path" 2>/dev/null || bad=1
                ;;
            new)
                rm -f "$GOAMNEZIA_DIR/$path" 2>/dev/null
                ;;
        esac
    done <"$prev/manifest"
    [ "$bad" = 0 ] || return 1
    if [ -f "$prev/install-source" ]; then
        mv -f "$prev/install-source" "$GOAMNEZIA_DIR/.install-source" 2>/dev/null || return 1
    elif [ -f "$prev/meta" ]; then
        rm -f "$GOAMNEZIA_DIR/.install-source" 2>/dev/null
    fi
    return 0
}

# ── Отметка неудачного обновления ────────────────────────────────────────────
# .update_failed.json — что не встало и что вернулось: её отдаёт status (поле update_rollback — бот и панель),
# по ней строка в шапке меню. Снимается следующим удавшимся обновлением на эту версию или новее.
ga_upd_notice_write() {
    local js
    command -v jq >/dev/null 2>&1 || return 1
    js=$(jq -cn --arg at "$(ga_now)" --arg stage "$1" --arg reason "$2" --arg v "$3" --arg fv "$4" \
            --argjson code "$5" --argjson data "$6" --arg archive "${7:-}" \
            '{at: $at, stage: $stage, reason: $reason, version: $v, failed_version: $fv,
              code_restored: $code, data_restored: $data, archive: $archive}') || return 1
    ga_write_file "$(ga_upd_notice_file)" "$js"$'\n' 600
}

# ga_upd_notice_json → содержимое отметки (объект) или null.
ga_upd_notice_json() {
    local f js=""
    f=$(ga_upd_notice_file)
    [ -f "$f" ] && js=$(jq -c 'if type == "object" then . else empty end' "$f" 2>/dev/null)
    printf '%s' "${js:-null}"
}

# ── Откат ────────────────────────────────────────────────────────────────────
# _ga_upd_why <этап> → слова причины для человека.
_ga_upd_why() {
    case "${1:-}" in
        snapshot)  t ops_upd_why_snapshot ;;
        record)    t ops_upd_why_record ;;
        check)     t ops_upd_why_check ;;
        *)         t ops_upd_why_migration ;;
    esac
}

# ga_upd_rollback <этап> [архив preupgrade] — откат неудачного обновления: этап — snapshot | record |
# migration | check. → 0 и GA_UPDATE_ROLLED_BACK=1, если прежний код на месте: вызывающий передаёт ему тот же
# вызов (_ga_after_update_rollback в install.sh). Зовётся под замком конфигурации (из миграции).
ga_upd_rollback() {
    local stage="${1:-migration}" archive="${2:-}" prev from to why msg units data_ok=false code_ok=false
    prev=$(ga_upd_prev_dir)
    from=$(ga_upd_prev_version)
    to="$GOAMNEZIA_VERSION"
    why=$(_ga_upd_why "$stage")
    [ "$stage" = check ] && [ -n "${GA_UPD_CHECK_ERR:-}" ] && why="$why (${GA_UPD_CHECK_ERR})"
    echo "" >&2
    log_error "$(tf ops_upd_failed "$to" "$why")"
    log_info "$(tf ops_upd_rolling_back "${from:-?}")"
    # Данные — первыми: точка невозврата отката — код. Оборвётся после данных — следующий вызов нового кода
    # повторит миграцию, упадёт снова и доделает откат; оборвись он после кода — прежнему коду достались бы
    # полупереведённые данные, а доделывать откат прежний код не умеет.
    # Снимка нет (миграция до данных не дошла: снимок не снялся, та же версия) — данные не менялись.
    if [ -z "$archive" ]; then
        data_ok=true
    elif ga_upd_restore_data "$archive"; then
        data_ok=true
        log_success "$(tf ops_upd_data_restored "$archive")"
    else
        log_error "$(tf ops_upd_data_failed "$archive")"
    fi
    units=$(ga_upd_units_restore) || units=0
    [[ "$units" =~ ^[0-9]+$ ]] && [ "$units" -gt 0 ] && log_dim "$(tf ops_upd_units_restored "$units")"
    ga_upd_restore_code && code_ok=true
    # Служба изоляции (OPS-05) держит код в памяти: осталась после отката (прежняя версия её знает) — на прежний
    # код; прежней версии она не знакома — её юнит уже убран выше.
    if [ "$code_ok" = true ] && _ga_upd_units_ok && [ -f "$(_ga_upd_units_dir)/goamnezia-isolation.service" ]; then
        _ga_upd_systemctl try-restart goamnezia-isolation.service
    fi
    # Отметки этой попытки: следующая попытка обновиться на ту же версию снимет свой снимок и мигрирует заново.
    rm -f "$GOAMNEZIA_DIR/.migrating_${to}" "$GOAMNEZIA_DIR/.preupgrade_${to}_done" \
          "$GOAMNEZIA_DIR/.migrated_${to}" 2>/dev/null
    [ "$code_ok" = true ] && rm -rf "$prev" 2>/dev/null
    ga_upd_notice_write "$stage" "$why" "${from:-}" "$to" "$code_ok" "$data_ok" "$archive" \
        || log_warning "${GA_ERR_MSG:-}"
    # Боту — готовой фразой в поле message: бот любой версии покажет событие, даже не зная его имени.
    if [ "$code_ok" = true ] && [ "$data_ok" = true ]; then
        msg=$(tf ops_upd_notify "$to" "$why" "${from:-?}")
    else
        msg=$(tf ops_upd_notify_stuck "$to" "$why")
    fi
    # message — первым полем: бот, не знающий события, печатает поля по порядку («Событие …: message=…, …»).
    if type ga_notify >/dev/null 2>&1; then
        ga_notify update_rolled_back "$(jq -cn --arg v "${from:-}" --arg fv "$to" --arg s "$stage" --arg r "$why" \
            --argjson c "$code_ok" --argjson d "$data_ok" --arg a "$archive" --arg m "$msg" \
            '{message: $m, version: $v, failed_version: $fv, stage: $s, reason: $r, code_restored: $c,
              data_restored: $d, archive: $a}')" || true
    fi
    type ga_audit >/dev/null 2>&1 && ga_audit "${GOAMNEZIA_WHO:-ssh}" "update-rollback" \
        "$to -> ${from:-?} stage=$stage code=$code_ok data=$data_ok"
    if [ "$code_ok" = true ]; then
        log_success "$(tf ops_upd_code_restored "${from:-?}")"
        GA_UPDATE_ROLLED_BACK=1
        return 0
    fi
    log_error "$(t ops_upd_code_failed)"
    return 1
}

# ga_upd_health_check — новый код отвечает на status: вызов моста отдельным процессом, как спросил бы бот.
# → 0 — success; 1 — упал или отказал (чем — в GA_UPD_CHECK_ERR); 2 — не дождались (таймаут): судить не по
# чему, откатывать из-за зависшего Docker незачем — прежний код завис бы так же.
ga_upd_health_check() {
    local out rc=0 last
    local -a tmo=()
    command -v timeout >/dev/null 2>&1 && tmo=(timeout 120)
    GA_UPD_CHECK_ERR=""
    out=$(GOAMNEZIA_WHO=update "${tmo[@]}" "${BASH:-bash}" "$SCRIPT_DIR/install.sh" --action=status --json \
          </dev/null 2>/dev/null) || rc=$?
    [ "$rc" = 124 ] && return 2
    last=$(printf '%s\n' "$out" | tail -n 1)
    printf '%s' "$last" | jq -e '.status == "success"' >/dev/null 2>&1 && return 0
    GA_UPD_CHECK_ERR=$(printf '%s' "$last" | jq -r '.code // empty' 2>/dev/null) || GA_UPD_CHECK_ERR=""
    [ -n "$GA_UPD_CHECK_ERR" ] || GA_UPD_CHECK_ERR="rc=$rc"
    return 1
}

# ga_upd_check — то же для миграции: 0 — новый код отвечает или ждать ответа не дождались (тогда
# предупреждение: зависший Docker — не повод откатывать); 1 — упал или отказал.
ga_upd_check() {
    local rc=0
    ga_upd_health_check || rc=$?
    case "$rc" in
        0) return 0 ;;
        2) log_warning "$(t ops_upd_check_skipped)"; return 0 ;;
    esac
    return 1
}

# ga_upd_commit — обновление завершено: копия прежнего кода больше не нужна (место), отметка прошлого
# неудачного обновления снимается, если встала та же версия или новее.
ga_upd_commit() {
    local prev from fv
    prev=$(ga_upd_prev_dir)
    [ -d "$prev" ] || return 0
    from=$(ga_upd_prev_version)
    rm -rf "$prev" 2>/dev/null
    fv=$(ga_upd_notice_json | jq -r '.failed_version // empty' 2>/dev/null)
    if [ -n "$fv" ] && ! _ga_upd_ver_lt "$GOAMNEZIA_VERSION" "$fv"; then
        rm -f "$(ga_upd_notice_file)" 2>/dev/null
    fi
    if [ -n "$from" ] && [ "$from" != "$GOAMNEZIA_VERSION" ]; then
        log_dim "$(tf ops_upd_done "$from" "$GOAMNEZIA_VERSION")"
        type ga_audit >/dev/null 2>&1 && ga_audit "${GOAMNEZIA_WHO:-ssh}" "update-done" "$from -> $GOAMNEZIA_VERSION"
    fi
    return 0
}
