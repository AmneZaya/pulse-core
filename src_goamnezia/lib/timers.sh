#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# goAmnezia pro — lib/timers.sh: таймеры systemd продукта (CONTRACT §1, §4.12)
#
# Четыре таймера, которые ставит сам install.sh — при первой установке, при
# миграции на новую версию и при каждом интерактивном запуске (идемпотентно:
# юнит переписывается только если текст изменился, enable — только если таймер
# ещё не включён):
#   goamnezia-quota.timer    5 мин   install.sh --action=quota-tick    (лимиты и сроки, users_quota_tick)
#   goamnezia-watch.timer    2 мин   install.sh --action=watch-tick    (сторож контейнеров, amnezia_watch_tick)
#   goamnezia-stats.timer    10 мин  install.sh --action=stats-tick    (статистика по суткам, stats_tick)
#   goamnezia-upstream.timer сутки   install.sh --action=upstream-tick (проверка обновлений Amnezia, upstream_tick)
#   goamnezia-cert.timer     сутки   install.sh --action=cert-tick     (срок сертификата, website_cert_tick)
# Все идут через мост --action (а не source модулей внутри ExecStart, как у
# бэкапа): мост даёт один замок на все интерфейсы, JSON-ответ в журнале и те
# же коды ошибок, что видят бот и MCP. Действия помечены mcp: null — агенту
# дёргать таймеры незачем. Ещё два таймера живут в своих модулях и ставятся
# отсюда же: goamnezia-backup (lib/backup.sh, по умолчанию daily, если человек
# не выбирал расписание) и goamnezia-logbudget/logrotate (lib/logbudget.sh).
#
# Стенд (GOAMNEZIA_DRY_RUN=1): юниты пишутся в GOAMNEZIA_SYSTEMD_DIR, если он
# задан (иначе только «DRY: write …»), systemctl печатается как «DRY: …»;
# модули backup/logbudget, пишущие прямо в /etc, на стенде не вызываются.
# tests/test_timers_dryrun.sh проверяет тексты юнитов и ответы действий.
# ══════════════════════════════════════════════════════════════════════════════

# cert — сторож срока сертификата. Его не было вовсе: сорвавшееся
# автопродление оставалось невидимым до дня, когда разом умирают сайт, панель и
# транспорт агентов. Раз в сутки: срок меряется неделями, чаще смотреть незачем.
GA_TIMERS="quota watch stats upstream cert"

ga_timers_systemd_dir() { printf '%s' "${GOAMNEZIA_SYSTEMD_DIR:-/etc/systemd/system}"; }
ga_timers_fs_ok() { ! ga_dry || [ -n "${GOAMNEZIA_SYSTEMD_DIR:-}" ]; }
ga_timers_run_quiet() {
    if ga_dry; then ga_dry_echo "$*"; return 0; fi
    "$@" >/dev/null 2>&1
}
# Мост, который зовёт таймер: эталон продукта (CONTRACT §1), не рабочая копия.
ga_timers_bin() { printf '%s/install.sh' "${GOAMNEZIA_DIR:-/opt/goamnezia}"; }

# Расписание одного таймера: «действие|OnBootSec|OnUnitActiveSec|OnCalendar|RandomizedDelaySec».
ga_timers_spec() {
    case "$1" in
        quota)    echo "quota-tick|3min|5min||1min" ;;
        watch)    echo "watch-tick|2min|2min||30s" ;;
        stats)    echo "stats-tick|4min|10min||1min" ;;
        upstream) echo "upstream-tick|||*-*-* 05:10:00|1h" ;;
        cert)     echo "cert-tick|||*-*-* 04:40:00|1h" ;;
        *) return 1 ;;
    esac
}
ga_timers_valid() { case " $GA_TIMERS " in *" ${1:-} "*) return 0 ;; *) return 1 ;; esac; }

# Потолок одного прогона тика. У Type=oneshot таймаута по умолчанию нет вовсе: зависни dockerd — тик держал
# бы общий замок config.lock бесконечно, и каждая запись из бота, панели и меню получала бы lock_timeout,
# пока кто-то не убьёт процесс (находка SR-38). С запасом на пересоздание контейнера сторожем (загрузка
# образа и сборка идут минутами).
ga_timers_timeout() {
    case "$1" in
        quota|stats) echo 10min ;;
        watch)       echo 20min ;;
        *)           echo 30min ;;
    esac
}

# Тексты юнитов (stdout). Description — из словаря: язык тот, что был при
# установке, как у goamnezia-backup. After=docker: тику нечего делать раньше.
_timers_render_service() {
    local name="$1" spec action
    spec=$(ga_timers_spec "$name") || return 1
    action="${spec%%|*}"
    cat <<EOUNIT
[Unit]
Description=$(t "timers_desc_${name}")
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
Environment=GOAMNEZIA_WHO=timer
TimeoutStartSec=$(ga_timers_timeout "$name")
ExecStart=/bin/bash $(ga_timers_bin) --action=${action} --json
EOUNIT
}
_timers_render_timer() {
    local name="$1" spec boot active cal delay
    spec=$(ga_timers_spec "$name") || return 1
    IFS='|' read -r _ boot active cal delay <<<"$spec"
    {
        printf '[Unit]\nDescription=%s\n\n[Timer]\n' "$(t "timers_desc_${name}")"
        if [ -n "$cal" ]; then
            printf 'OnCalendar=%s\nPersistent=true\n' "$cal"
        else
            printf 'OnBootSec=%s\nOnUnitActiveSec=%s\n' "$boot" "$active"
        fi
        printf 'RandomizedDelaySec=%s\nAccuracySec=1min\nUnit=goamnezia-%s.service\n\n[Install]\nWantedBy=timers.target\n' "$delay" "$name"
    }
}

# Служба изоляции (находка OPS-05): не таймер, а постоянный слушатель событий Docker — ставит правило изоляции
# клиентов контейнеру профиля в ту же секунду, как он стартовал. После перезагрузки подхваченный у приложения
# контейнер (его start.sh мы не трогаем) иначе до первого тика сторожа — две с лишним минуты — жил без правила.
# PartOf: остановка и перезапуск Docker уводят службу за собой; WantedBy=docker.service: старт Docker её
# поднимает; упала сама (события оборвались) — поднимается через 10 с.
GA_ISOLATION_UNIT="goamnezia-isolation.service"
_timers_render_isolation() {
    cat <<EOUNIT
[Unit]
Description=$(t ops_iso_unit_desc)
After=docker.service
PartOf=docker.service

[Service]
Type=simple
User=root
Environment=GOAMNEZIA_WHO=isolation
ExecStart=/bin/bash $(ga_timers_bin) --isolation-watch
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target docker.service
EOUNIT
}

# timers_isolation_restart — служба держит код продукта в памяти: после смены кода (обновление, откат) —
# перезапуск, если она работает (try-restart не поднимает остановленную).
timers_isolation_restart() {
    ga_timers_run_quiet systemctl try-restart "$GA_ISOLATION_UNIT" || true
    return 0
}

# Записать файл, если содержимое изменилось. stdout: changed|same.
_timers_write_unit() {
    local path="$1" content="$2" tmp
    if ! ga_timers_fs_ok; then
        ga_dry_echo "write $path"
        echo changed
        return 0
    fi
    if [ -f "$path" ] && [ "$(cat "$path" 2>/dev/null)" = "$content" ]; then
        echo same
        return 0
    fi
    mkdir -p "$(dirname "$path")" 2>/dev/null || { ga_err unit_failed "$(tf timers_err_write "$path")"; return 1; }
    tmp=$(mktemp "${path}.XXXXXX" 2>/dev/null) || { ga_err unit_failed "$(tf timers_err_write "$path")"; return 1; }
    if ! printf '%s\n' "$content" >"$tmp" || ! chmod 644 "$tmp" || ! mv -f "$tmp" "$path"; then
        rm -f "$tmp"
        ga_err unit_failed "$(tf timers_err_write "$path")"
        return 1
    fi
    echo changed
}

# Таймер включён и активен? (dry → считаем «нет», чтобы enable печатался)
ga_timers_enabled() {
    ga_dry && return 1
    systemctl is-enabled --quiet "goamnezia-$1.timer" 2>/dev/null && systemctl is-active --quiet "goamnezia-$1.timer" 2>/dev/null
}
# Служба изоляции включена и работает? (dry → «нет»)
_timers_isolation_active() {
    ga_dry && return 1
    systemctl is-enabled --quiet "$GA_ISOLATION_UNIT" 2>/dev/null && systemctl is-active --quiet "$GA_ISOLATION_UNIT" 2>/dev/null
}

# timers_install — поставить/починить все таймеры продукта. Идемпотентно.
# stdout: JSON {changed: [...], enabled: [...]}.
timers_install() {
    local name dir svc tmr changed='[]' enabled='[]' c1 c2 reload=0 iso_changed=0
    dir=$(ga_timers_systemd_dir)
    for name in $GA_TIMERS; do
        svc=$(_timers_render_service "$name") || return 1
        tmr=$(_timers_render_timer "$name") || return 1
        # Через ga_capture, а не `c1=$(…)`: _timers_write_unit кладёт причину
        # отказа в GA_ERR_CODE (нет прав на /etc/systemd/system, диск полон), а
        # подстановка команды выполняет функцию в дочернем процессе — код туда
        # и ложится, и наружу доходит голый rc. Агент моста тогда не отличает
        # «нет прав» от любой другой беды (тот же урок, что у lib/docker.sh).
        ga_capture c1 _timers_write_unit "$dir/goamnezia-${name}.service" "$svc" || return 1
        ga_capture c2 _timers_write_unit "$dir/goamnezia-${name}.timer" "$tmr" || return 1
        if [ "$c1" = changed ] || [ "$c2" = changed ]; then
            reload=1
            changed=$(jq -c --arg n "$name" '. + [$n]' <<<"$changed")
        fi
    done
    # Служба изоляции — тем же проходом (OPS-05); в списках ответа — только таймеры, как раньше.
    ga_capture c1 _timers_write_unit "$dir/$GA_ISOLATION_UNIT" "$(_timers_render_isolation)" || return 1
    if [ "$c1" = changed ]; then
        reload=1; iso_changed=1
    fi
    [ "$reload" = 1 ] && { ga_timers_run_quiet systemctl daemon-reload || true; }
    for name in $GA_TIMERS; do
        if [ "$reload" = 1 ] || ! ga_timers_enabled "$name"; then
            ga_timers_run_quiet systemctl enable --now "goamnezia-${name}.timer" \
                || { ga_err unit_failed "$(tf timers_err_enable "goamnezia-${name}.timer")"; return 1; }
            enabled=$(jq -c --arg n "$name" '. + [$n]' <<<"$enabled")
        fi
    done
    # Текст юнита сменился — restart (подхватить его); служба не включена или не работает — enable и restart.
    if [ "$iso_changed" = 1 ] || ! _timers_isolation_active; then
        { ga_timers_run_quiet systemctl enable "$GA_ISOLATION_UNIT" \
            && ga_timers_run_quiet systemctl restart "$GA_ISOLATION_UNIT"; } \
            || { ga_err unit_failed "$(tf timers_err_enable "$GA_ISOLATION_UNIT")"; return 1; }
    fi
    # Бэкап по умолчанию раз в сутки, если человек ещё не выбирал расписание;
    # бюджет логов. Оба модуля пишут прямо в /etc — на стенде их не трогаем.
    if ! ga_dry; then
        if type set_backup_schedule >/dev/null 2>&1 && [ ! -f "${GOAMNEZIA_DIR:-/opt/goamnezia}/backup_schedule.json" ]; then
            set_backup_schedule daily >/dev/null 2>&1 && log_dim "$(t timers_backup_default)"
        fi
        type logb_apply_all >/dev/null 2>&1 && logb_apply_all >/dev/null 2>&1
    fi
    if [ "$(jq -r 'length' <<<"$changed")" != 0 ]; then
        log_success "$(tf timers_installed "$(jq -r 'join(", ")' <<<"$changed")")"
    else
        log_dim "$(t timers_unchanged)"
    fi
    jq -cn --argjson c "$changed" --argjson e "$enabled" '{changed: $c, enabled: $e}'
}

# timers_remove — выключить и удалить таймеры продукта (снос установки).
timers_remove() {
    local name dir
    dir=$(ga_timers_systemd_dir)
    for name in $GA_TIMERS; do
        ga_timers_run_quiet systemctl disable --now "goamnezia-${name}.timer" || true
        if ga_timers_fs_ok; then
            rm -f "$dir/goamnezia-${name}.timer" "$dir/goamnezia-${name}.service" 2>/dev/null || true
        else
            ga_dry_echo "rm -f $dir/goamnezia-${name}.timer $dir/goamnezia-${name}.service"
        fi
    done
    ga_timers_run_quiet systemctl disable --now "$GA_ISOLATION_UNIT" || true
    if ga_timers_fs_ok; then
        rm -f "$dir/$GA_ISOLATION_UNIT" 2>/dev/null || true
    else
        ga_dry_echo "rm -f $dir/$GA_ISOLATION_UNIT"
    fi
    ga_timers_run_quiet systemctl daemon-reload || true
    log_success "$(t timers_removed)"
    return 0
}

# timers_status → JSON [{name, timer, action, installed, state}] для quality и
# экрана диагностики: state = active | inactive | missing | dry.
# Состояние ВСЕХ таймеров продукта, а не только тех, что ставит этот модуль.
# Диагностика видела пять из девяти: ночную копию, бюджет журналов, их ротацию и
# продление сертификата ставят другие места, и отвалившийся таймер копий продукт
# не замечал вовсе — при том что восстановление из копии он же и советует как
# выход изо всех бед.
GA_TIMERS_FOREIGN="backup logbudget logrotate cert-renew"

timers_status() {
    local name dir spec rows='[]' installed state unit owned last
    dir=$(ga_timers_systemd_dir)
    for name in $GA_TIMERS $GA_TIMERS_FOREIGN; do
        # У чужих таймеров своего описания в этом модуле нет — и не должно
        # быть: мы их не ставим, только смотрим. owned отделяет одно от другого:
        # пропавший свой таймер — наш дефект, пропавший чужой — повод сходить в
        # его модуль, а не переставлять расписание.
        spec=$(ga_timers_spec "$name" 2>/dev/null) || spec="|"
        [ -n "$spec" ] || spec="|"
        owned=false; ga_timers_valid "$name" && owned=true
        unit="goamnezia-${name}.timer"
        installed=false; [ -f "$dir/$unit" ] && installed=true
        # Продление сертификата — единственный случай, где отсутствие НАШЕГО
        # юнита нормально: при пакетном certbot мы намеренно не плодим второй
        # таймер и пользуемся его собственным (website_setup_auto_renew). Без
        # этой оговорки диагностика пугала бы «продление сертификата пропало»
        # на сервере, где оно исправно работает.
        if [ "$name" = cert-renew ] && [ "$installed" = false ] && ! ga_dry \
           && systemctl cat certbot.timer >/dev/null 2>&1; then
            unit="certbot.timer"; installed=true
        fi
        # Результат последнего запуска службы. Таймер может исправно тикать, а
        # служба — падать на каждом тике: «активен» тогда врёт, и молча. Это
        # ровно тот случай, ради которого на диагностику и смотрят.
        last=""
        if ! ga_dry && [ "$installed" = true ]; then
            last=$(systemctl show "${unit%.timer}.service" -p Result --value 2>/dev/null) || last=""
        fi
        if ga_dry; then
            state="dry"
        elif ! systemctl cat "$unit" >/dev/null 2>&1; then
            state="missing"
        elif systemctl is-active --quiet "$unit" 2>/dev/null; then
            state="active"
        else
            state="inactive"
        fi
        rows=$(jq -c --arg n "$name" --arg t "$unit" --arg a "${spec%%|*}" --argjson i "$installed" --arg s "$state" --argjson o "$owned" --arg l "$last" \
            '. + [{name: $n, timer: $t, action: $a, installed: $i, state: $s, owned: $o, last: $l}]' <<<"$rows")
    done
    printf '%s\n' "$rows"
}
