#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# goAmnezia pro — lib/stats.sh: статистика трафика по суткам (CONTRACT §4.11)
#
# Зачем отдельно от users_quota_tick: тот копит трафик пользователя «за всё
# время» ради лимитов, а панели, боту и SSH-экрану «Трафик» нужны «за сутки» и
# «за месяц» по профилям и людям. Источник один — `awg show <iface> dump`
# (amnezia_show), счётчики в нём накопительные и обнуляются при рестарте
# контейнера. Поэтому stats.json помнит последнее показание каждого пира
# (last: {"<профиль>/<pubkey>": {rx, tx}}) и складывает в суточный ящик только
# дельты; показание меньше прошлого → был рестарт → дельта = новое показание
# (то же правило, что в users.sh). Пиры, которых нет в users.json (добавлены
# приложением Amnezia и ещё не подхвачены import-reconcile), считаются под
# именем "" — в профиле они видны, в «по пользователям» нет.
#
# Файл: $GOAMNEZIA_DIR/stats.json (0600, атомарная запись):
#   {schema: 1, updated, last: {...},
#    days: {"YYYY-MM-DD": {rx, tx, profiles: {p: {rx, tx}}, users: {name: {rx, tx}}}},
#    hours: {"YYYY-MM-DDTHH": {rx, tx, active}}}
# Хранятся последние 30 суток и 192 часа (8 суток, UTC). hours — для карты «Активность по часам 7×24» и
# вида «24 часа» (задача HM-1): rx/tx — те же дельты тика, что в сутках, сложенные по часу; active —
# МАКСИМУМ за час числа людей «на связи» (последнее рукопожатие моложе GA_STATS_ONLINE_SEC — то же окно
# 180 с, что у «●» на экране трафика, в боте и в панели). Ключ добавочный, schema остаётся 1: файл прежней
# версии без hours читается как есть. Таймер goamnezia-stats.timer зовёт stats_tick раз в 10 минут;
# действие traffic добавляет к ответу today/month/days/hours из stats_summary.
# ══════════════════════════════════════════════════════════════════════════════

GA_STATS_KEEP_DAYS="${GOAMNEZIA_STATS_KEEP_DAYS:-30}"
GA_STATS_KEEP_HOURS=192
GA_STATS_SUMMARY_HOURS=168
# «На связи» — рукопожатие моложе трёх минут: ровно то окно, что у «●» на экране «Трафик» (install.sh), в боте
# и в панели (ONLINE_WINDOW). Своё число здесь разошлось бы с «N на связи» в интерфейсах.
GA_STATS_ONLINE_SEC=180

ga_stats_file() { printf '%s/stats.json' "${GOAMNEZIA_DIR:-/opt/goamnezia}"; }

# _ga_stats_fail — машинная часть отказа для вызывающего и моста --action.
# Человеку ga_stats_read уже всё сказала в stderr; здесь только код и короткий
# текст, и ставятся они в ТОЙ ЖЕ оболочке: ga_stats_read зовут через $( ), а
# из подоболочки ни GA_ERR_CODE, ни GA_LAST_ERROR_CODE не выходят.
_ga_stats_fail() {
    GA_ERR_CODE=stats_corrupt
    GA_ERR_MSG="$(tf stats_corrupt_short "$(ga_stats_file)")"
    ga_set_error stats_corrupt
    return 1
}

# stats.json целиком. Файла нет → скелет (законно: первый тик таймера); файл
# есть, но не разбирается → отказ кодом stats_corrupt и НИ ОДНОЙ записи.
#
# Раньше здесь был тот самый узор, который для config.json и users.json уже
# признан дефектом: предупреждение уходило в журнал таймера, ближайший тик
# через десять минут переписывал файл скелетом, и накопленная статистика за
# месяц исчезала без следа. Копию битого файла кладём в backups/ тем же
# помощником, что и для конфига, — чинить его человек будет по ней.
ga_stats_read() {
    local f out rescue
    f=$(ga_stats_file)
    if [ -f "$f" ]; then
        out=$(jq -c 'select(type == "object")' "$f" 2>/dev/null)
        if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
        rescue=""
        if type _ga_json_rescue >/dev/null 2>&1; then
            rescue=$(_ga_json_rescue "$f") || rescue=""
        fi
        ga_set_error stats_corrupt
        if [ -n "$rescue" ]; then
            log_error "$(tf stats_corrupt "$f" "$rescue")"
        else
            log_error "$(tf stats_corrupt_nocopy "$f")"
        fi
        log_error "$(tf stats_corrupt_howto "$f")"
        return 1
    fi
    printf '%s\n' '{"schema":1,"updated":"","last":{},"days":{}}'
}

# stdin JSON → stats.json атомарно, 0600.
ga_stats_write() { _ga_write_json "$(ga_stats_file)"; }

# День (UTC) для ящика; GOAMNEZIA_STATS_TODAY подменяет в тестах.
ga_stats_today() { printf '%s' "${GOAMNEZIA_STATS_TODAY:-$(date -u +%Y-%m-%d)}"; }
# Сейчас (секунды UTC) для часового ящика и окна «на связи»; GOAMNEZIA_STATS_NOW подменяет в тестах.
ga_stats_now() { printf '%s' "${GOAMNEZIA_STATS_NOW:-$(date -u +%s)}"; }

# stats_tick → снимок по всем установленным профилям, дельты в ящик дня.
# stdout JSON {day, profiles: [{profile, rx, tx}], total: {rx, tx}, updated}.
stats_tick() { ga_with_config_lock _stats_tick_locked "$@"; }
_stats_tick_locked() {
    local stats users day profile show n=0 total polled='[]' seen='[]' profiles now hour online='[]'
    # Битый stats.json — отказ, а не чистый лист.
    if ! stats=$(ga_stats_read); then
        _ga_stats_fail
        return 1
    fi
    # «Пусто» на битом файле означало бы «пользователей нет», и тик записал бы
    # в статистику ноль там, где их десятки. Считать по неизвестно чему хуже,
    # чем не считать: пропускаем тик и говорим об этом кодом.
    ga_users_load users || { _ga_stats_fail; return 1; }
    # То же и про config.json: на битом конфиге подстановка команды отдавала
    # пустой список профилей, тик записывал сутки без единого байта и отвечал
    # «успешно» — статистика замирала, и понять это по ответу было нельзя.
    # Код именно config_corrupt, а не stats_corrupt: человеку чинить надо
    # config.json, и посылать его в stats.json значило бы увести от причины.
    ga_profiles_load profiles || { ga_err config_corrupt "$(t err_config_unreadable)"; return 1; }
    day=$(ga_stats_today)
    # Часовой ящик (UTC) и «сейчас» для окна «на связи» — одно число на весь тик (HM-1).
    now=$(ga_stats_now)
    hour=$(jq -rn --argjson t "$now" '$t | strftime("%Y-%m-%dT%H")') || { ga_err stats_write_failed "$(t stats_err_write)"; return 1; }
    for profile in $profiles; do
        show=$(amnezia_show "$profile" 2>/dev/null) || continue
        [ -n "$show" ] && [ "$show" != "[]" ] || continue
        n=$((n + 1))
        # Копим, какие профили действительно опрошены и какие пиры в них живы:
        # ниже по этим спискам чистится last (см. обрезку).
        polled=$(jq -c --arg p "$profile" '. + [$p]' <<<"$polled")
        # Большие JSON (показания пиров, весь users.json) — через stdin, а не аргументами: один
        # аргумент в Linux не длиннее 128 КБ, и около сотни пользователей статистика переставала
        # копиться с stats_write_failed (находка SR-09, 25.09.2026).
        seen=$(printf '%s\n%s\n' "$seen" "$show" | jq -cn --arg p "$profile" \
               'input as $cur | input as $show | $cur + ($show | map(select((.pubkey // "") != "") | $p + "/" + .pubkey))')
        # Кто «на связи» в этом профиле: люди по имени (человек с двумя профилями — один), пир без хозяина — сам
        # по себе. Окно то же, что у «●» в интерфейсах (GA_STATS_ONLINE_SEC).
        online=$(printf '%s\n%s\n%s\n' "$online" "$show" "$users" | jq -cn --arg p "$profile" --argjson now "$now" \
                 --argjson win "$GA_STATS_ONLINE_SEC" '
            input as $cur | input as $show | input as $users
            | ($users.users // [] | map({key: (.peers[$p].pubkey // ""), value: .name}) | map(select(.key != "")) | from_entries) as $owner
            | $cur + ($show | map(select((.pubkey // "") != "" and (.latest_handshake_ts // 0) > 0
                                          and ($now - (.latest_handshake_ts // 0)) < $win)
                                  | ($owner[.pubkey] // ("peer:" + $p + "/" + .pubkey))))') \
            || { ga_err stats_write_failed "$(t stats_err_write)"; return 1; }
        stats=$(printf '%s\n%s\n%s\n' "$stats" "$show" "$users" | jq -cn --arg p "$profile" --arg day "$day" --arg hour "$hour" '
            input as $st | input as $show | input as $users | $st
            | ($users.users // [] | map({key: (.peers[$p].pubkey // ""), value: .name}) | map(select(.key != "")) | from_entries) as $owner
            | reduce ($show[] | select((.pubkey // "") != "")) as $s (.;
                ($p + "/" + $s.pubkey) as $k
                | (.last[$k] // {rx: 0, tx: 0}) as $l
                | (if ($s.rx // 0) < $l.rx then ($s.rx // 0) else ($s.rx // 0) - $l.rx end) as $drx
                | (if ($s.tx // 0) < $l.tx then ($s.tx // 0) else ($s.tx // 0) - $l.tx end) as $dtx
                | ($owner[$s.pubkey] // "") as $u
                | .last[$k] = {rx: ($s.rx // 0), tx: ($s.tx // 0)}
                | .days[$day] = ((.days[$day] // {rx: 0, tx: 0, profiles: {}, users: {}})
                    | .rx += $drx | .tx += $dtx
                    | .profiles[$p] = ((.profiles[$p] // {rx: 0, tx: 0}) | .rx += $drx | .tx += $dtx)
                    | (if $u == "" then . else .users[$u] = ((.users[$u] // {rx: 0, tx: 0}) | .rx += $drx | .tx += $dtx) end))
                | .hours[$hour] = ((.hours[$hour] // {rx: 0, tx: 0, active: 0}) | .rx += $drx | .tx += $dtx))') \
            || { ga_err stats_write_failed "$(t stats_err_write)"; return 1; }
    done
    # Обрезка до 30 суток и метка времени; last чистим от пиров, которых в
    # профиле больше нет, чтобы файл не рос вечно. Обещание чистки стояло здесь
    # комментарием с самого начала, а выражение трогало только метку и сутки —
    # ключи копились при каждом перевыпуске пира и не удалялись никогда.
    #
    # Чистим ТОЛЬКО профили, опрошенные в этом тике. Показание пира — база для
    # следующей дельты; убрать базу у профиля, чей контейнер сейчас лежит,
    # значит на ближайшем тике засчитать весь накопительный счётчик как трафик
    # за сутки. Профиль в ключе стоит до первой «/», а идентификаторы профилей
    # слэша не содержат — в отличие от base64-ключей пиров.
    #
    # Часы: active — МАКСИМУМ за час (тик раз в 10 минут, в часе их шесть), и только если хоть один профиль
    # опрошен: лежащий Docker не должен рисовать «ноль на связи» там, где просто не смотрели. Хранится 192 часа
    # (8 суток) — обрезка тем же проходом.
    stats=$(printf '%s\n%s\n%s\n' "$stats" "$seen" "$online" | jq -cn --arg now "$(ga_now)" --argjson keep "$GA_STATS_KEEP_DAYS" \
                  --argjson polled "$polled" --arg hour "$hour" --argjson nowts "$now" --argjson keeph "$GA_STATS_KEEP_HOURS" '
        input as $st | input as $seen | input as $online | $st
        | ($polled | map({key: ., value: true}) | from_entries) as $P
        | ($seen | map({key: ., value: true}) | from_entries) as $S
        | .updated = $now
        | .days = (.days | to_entries | sort_by(.key) | .[-$keep:] | from_entries)
        | .hours = (.hours // {})
        | (if ($polled | length) > 0 then
               .hours[$hour] = ((.hours[$hour] // {rx: 0, tx: 0, active: 0})
                                | .active = ([(.active // 0), ($online | unique | length)] | max))
           else . end)
        | .hours = (.hours | with_entries(select(((.key + ":00:00Z") | fromdateiso8601? // 0) > ($nowts - $keeph * 3600))))
        | .last = ((.last // {}) | with_entries(
              select(($P[(.key | split("/") | .[0])] // false | not) or ($S[.key] // false))))') || return 1
    printf '%s' "$stats" | ga_stats_write || { ga_err stats_write_failed "$(t stats_err_write)"; return 1; }
    total=$(jq -c --arg day "$day" '(.days[$day] // {rx: 0, tx: 0}) | {rx, tx}' <<<"$stats")
    log_dim "$(tf stats_tick_done "$n" "$(jq -r '.tx' <<<"$total")" "$(jq -r '.rx' <<<"$total")")"
    printf '%s' "$stats" | jq -c --arg day "$day" --argjson total "$total" --arg now "$(ga_now)" '
        . as $st | {day: $day, profiles: (($st.days[$day].profiles // {}) | to_entries | map({profile: .key, rx: .value.rx, tx: .value.tx})),
         total: $total, updated: $now}'
}

# stats_summary → stdout JSON {today: {date, rx, tx, by_profile, by_user},
# month: {from, rx, tx, by_profile, by_user}, days: [{date, rx, tx}] (по
# возрастанию, до 30 записей), hours: [{hour: "YYYY-MM-DDTHH:00Z", rx, tx, active}]
# (последние 168 часов, по возрастанию; пусто, пока ничего не собрано), updated}. Только чтение, без замка.
stats_summary() {
    local stats day month
    # Отказ пробрасываем наружу: пустая сводка на битом файле выглядела бы как
    # «трафика не было», и человек искал бы поломку в туннеле.
    if ! stats=$(ga_stats_read); then
        _ga_stats_fail
        return 1
    fi
    day=$(ga_stats_today); month="${day%-*}"
    jq -c --arg day "$day" --arg month "$month" --argjson nowts "$(ga_stats_now)" --argjson lasth "$GA_STATS_SUMMARY_HOURS" '
        def sum_bucket(entries): reduce entries as $e ({rx: 0, tx: 0, by_profile: {}, by_user: {}};
            .rx += ($e.rx // 0) | .tx += ($e.tx // 0)
            | .by_profile = (reduce (($e.profiles // {}) | to_entries[]) as $p (.by_profile;
                  .[$p.key] = ((.[$p.key] // {rx: 0, tx: 0}) | .rx += ($p.value.rx // 0) | .tx += ($p.value.tx // 0))))
            | .by_user = (reduce (($e.users // {}) | to_entries[]) as $u (.by_user;
                  .[$u.key] = ((.[$u.key] // {rx: 0, tx: 0}) | .rx += ($u.value.rx // 0) | .tx += ($u.value.tx // 0)))));
        (.days // {}) as $d
        | {today: ({date: $day} + sum_bucket($d[$day] // empty)),
           month: ({from: ($month + "-01")} + sum_bucket($d | to_entries[] | select(.key | startswith($month)) | .value)),
           days: ($d | to_entries | sort_by(.key) | map({date: .key, rx: (.value.rx // 0), tx: (.value.tx // 0)})),
           hours: ((.hours // {}) | if type == "object" then to_entries else [] end
                   | map(select(((.key + ":00:00Z") | fromdateiso8601? // 0) > ($nowts - $lasth * 3600)))
                   | sort_by(.key)
                   | map({hour: (.key + ":00Z"), rx: (.value.rx // 0), tx: (.value.tx // 0), active: (.value.active // 0)})),
           updated: (.updated // "")}' <<<"$stats"
}
