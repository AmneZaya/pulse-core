#!/usr/bin/env bash
# lib/selftest.sh — автопроверка функций БЕЗ сервера (install.sh --selftest).
# Цель: ловить регрессии до выката. Ничего не устанавливает и не меняет систему:
# все проверки идут во временном GOAMNEZIA_DIR, docker-вызовы отключены через
# GOAMNEZIA_DRY_RUN=1, сеть не трогается.
#
# Запуск: install.sh --selftest, либо функцией run_selftest из уже загруженного
# окружения, либо автономно `bash lib/selftest.sh` (сам подтянет common/i18n).

# Счётчики — в ФАЙЛЕ: часть проверок идёт в подоболочках ( … ), где обычные
# переменные не переживают возврата.
ST_TALLY="${ST_TALLY:-}"
_st_add()   { [ -n "$ST_TALLY" ] && printf '%s\n' "$1" >> "$ST_TALLY" 2>/dev/null; return 0; }
_st_count() { local n=0; [ -f "$ST_TALLY" ] && n=$(grep -c "^$1\$" "$ST_TALLY" 2>/dev/null || true); [[ "$n" =~ ^[0-9]+$ ]] || n=0; printf '%s' "$n"; }
_st_ok()    { _st_add PASS; printf '  \033[32m✓\033[0m %s\n' "$1"; }
_st_bad()   { _st_add FAIL; printf '  \033[31m✗\033[0m %s \033[2m(%s: %s / %s: %s)\033[0m\n' "$1" "$(t selftest_expected)" "$2" "$(t selftest_got)" "$3"; }
_st_skip()  { _st_add SKIP; printf '  \033[2m• %s: %s (%s)\033[0m\n' "$(t selftest_skipped)" "$1" "$2"; }
_st_eq()    { if [ "$2" = "$3" ]; then _st_ok "$1"; else _st_bad "$1" "$3" "$2"; fi; }
_st_rc()    { local d="$1"; shift; if "$@" >/dev/null 2>&1; then _st_ok "$d"; else _st_bad "$d" "rc=0" "rc=$?"; fi; }
_st_nrc()   { local d="$1"; shift; if "$@" >/dev/null 2>&1; then _st_bad "$d" "rc≠0" "rc=0"; else _st_ok "$d"; fi; }
# Проверка JSON фильтром jq: grep по имени поля подтверждал бы лишь то, что
# функция что-то напечатала — имена полей есть в её же printf-строке всегда.
_st_json()  { local d="$1" j="$2" q="$3"
    command -v jq >/dev/null 2>&1 || { _st_skip "$d" "jq"; return 0; }
    if jq -e "$q" <<<"$j" >/dev/null 2>&1; then _st_ok "$d"; else _st_bad "$d" "$q" "$j"; fi
}
_st_head()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Корень репозитория: lib/selftest.sh → lib → корень. Нужен проверкам синтаксиса
# и словарей; install.sh может задать его явно (SELFTEST_ROOT=$SCRIPT_DIR).
SELFTEST_ROOT="${SELFTEST_ROOT:-$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")}"

# ══════════════════════════════════════════════════════════════════════════════
#  Регистрация проверок
# ══════════════════════════════════════════════════════════════════════════════
# selftest_case <ключ-заголовка> <функция>
# Имя проверки — КЛЮЧ словаря, а не текст: иначе в selftest поселились бы
# видимые строки вне t/tf, а вместе с ними и второй экземпляр перевода.
# Модули, которые появятся позже (amnezia.sh, users.sh, export.sh), дописывают
# свои проверки этим же вызовом — трогать selftest_run для этого не нужно.
SELFTEST_CASES=()
selftest_case() {
    local key="${1:-}" fn="${2:-}"
    [ -n "$key" ] && [ -n "$fn" ] || return 1
    SELFTEST_CASES+=("${key}|${fn}")
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  Проверки ядра
# ══════════════════════════════════════════════════════════════════════════════

# ── Синтаксис всех скриптов репозитория ──────────────────────────────────────
_st_syntax() {
    local f bad=0 root="${SELFTEST_ROOT:-.}"
    # Проверяем ТЕМ ЖЕ интерпретатором, что нас запустил ($BASH), а не первым
    # bash из PATH: на macOS в /bin/bash лежит 3.2, и «чисто» от него ничего
    # не значит для кода, который поедет на сервер с bash 5.
    for f in "$root"/install.sh "$root"/bootstrap.sh "$root"/lib/*.sh \
             "$root"/lib/lang/*.sh "$root"/lib/lang/*.d/*.sh; do
        [ -f "$f" ] || continue
        "${BASH:-bash}" -n "$f" 2>/dev/null || { _st_bad "bash -n $(basename "$f")" "ok" "syntax"; bad=1; }
    done
    [ "$bad" = 0 ] && _st_ok "$(t selftest_syntax_clean)"
    return 0
}

# ── i18n ─────────────────────────────────────────────────────────────────────
_st_i18n() {
    if ! type load_language >/dev/null 2>&1; then
        _st_skip "$(t selftest_i18n)" "i18n.sh"
        return 0
    fi
    # Неизвестный ключ обязан печатать сам себя: только так пропажа перевода
    # видна человеку в меню, а не превращается в пустую строку.
    # Ключи с префиксом no_such_key_ tests/check_i18n_ssh.py намеренно
    # пропускает: этот ключ обязан ОТСУТСТВОВАТЬ в словарях.
    _st_eq "$(t selftest_i18n_unknown_key)" "$(t no_such_key_probe)" "no_such_key_probe"
    # Фрагменты lib/lang/<lang>.d/*.sh должны подхватываться после ядра словаря:
    # на них держится параллельная работа модулей над словарём.
    local probe
    probe=$(t selftest_fragment_probe)
    if [ "$probe" != "selftest_fragment_probe" ] && [ -n "$probe" ]; then
        _st_ok "$(t selftest_i18n_fragments)"
    else
        _st_bad "$(t selftest_i18n_fragments)" "≠ selftest_fragment_probe" "$probe"
    fi
    # Ключи ядра словаря должны совпадать в ru и en (полную сверку с учётом
    # фрагментов делает tests/check_i18n_ssh.py — здесь быстрый предохранитель).
    local dir ru en diff
    dir="${SELFTEST_ROOT:-.}/lib/lang"
    if [ -f "$dir/ru.sh" ] && [ -f "$dir/en.sh" ]; then
        ru=$(grep -oE '^I18N\[[a-z0-9_]+\]' "$dir/ru.sh" | sort -u)
        en=$(grep -oE '^I18N\[[a-z0-9_]+\]' "$dir/en.sh" | sort -u)
        diff=$(comm -3 <(printf '%s\n' "$ru") <(printf '%s\n' "$en") | tr -d '\t' | head -5)
        if [ -z "$diff" ]; then
            _st_ok "$(tf selftest_i18n_parity "$(printf '%s\n' "$ru" | wc -l | tr -d ' ')")"
        else
            _st_bad "$(tf selftest_i18n_parity "?")" "-" "$(printf '%s' "$diff" | tr '\n' ' ')"
        fi
    else
        _st_skip "$(t selftest_i18n)" "lang"
    fi
    return 0
}

# ── Валидаторы входа ─────────────────────────────────────────────────────────
_st_validators() {
    _st_rc  "$(t selftest_valid_name_ok)"      validate_name "anna_01-x"
    _st_nrc "$(t selftest_valid_name_space)"   validate_name "anna ivanova"
    _st_nrc "$(t selftest_valid_name_empty)"   validate_name ""
    _st_nrc "$(t selftest_valid_name_long)"    validate_name "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    # Перевод строки внутри значения — та самая инъекция, ради которой в
    # validate_* используется [[ =~ ]], а не grep.
    _st_nrc "$(t selftest_valid_name_newline)" validate_name "$(printf 'anna\nroot')"
    _st_rc  "$(t selftest_valid_port_ok)"      validate_port 443
    _st_nrc "$(t selftest_valid_port_zero)"    validate_port 0
    _st_nrc "$(t selftest_valid_port_big)"     validate_port 70000
    _st_nrc "$(t selftest_valid_port_text)"    validate_port "44a3"
    _st_rc  "$(t selftest_valid_profile_ok)"   validate_profile awg2
    _st_nrc "$(t selftest_valid_profile_bad)"  validate_profile awg9
    _st_rc  "$(t selftest_valid_domain_ok)"    validate_domain "example.test"
    _st_nrc "$(t selftest_valid_domain_multi)" validate_domain "$(printf 'example.test\nevil')"
    return 0
}

# ── Архитектура ──────────────────────────────────────────────────────────────
_st_arch() {
    local out rc
    if [ "$(uname -m)" = "x86_64" ] || [ "$(uname -m)" = "amd64" ]; then
        out=$(get_arch 2>/dev/null)
        _st_eq "$(t selftest_arch_amd64)" "$out" "amd64"
    else
        # Не-x86_64: обязаны получить отказ и код unsupported_arch, а не тихое
        # «ну ладно» — иначе пользователю соберут заведомо нерабочий контейнер.
        # Зовём БЕЗ $( ): в подоболочке ga_set_error пишет в свою копию
        # переменной, и наружу код ошибки не выходит.
        GA_LAST_ERROR_CODE=""
        get_arch >/dev/null 2>&1; rc=$?
        if [ "$rc" -ne 0 ] && [ "${GA_LAST_ERROR_CODE:-}" = "unsupported_arch" ]; then
            _st_ok "$(t selftest_arch_refused)"
        else
            _st_bad "$(t selftest_arch_refused)" "rc≠0 + unsupported_arch" "rc=$rc ${GA_LAST_ERROR_CODE:-}"
        fi
    fi
    return 0
}

# ── ga_emit_json ─────────────────────────────────────────────────────────────
_st_emit_json() {
    local j
    # Экранирование: кавычки, обратные слэши и перевод строки в сообщении не
    # должны разваливать последнюю строку stdout — её разбирают бот, панель и MCP.
    j=$(ga_emit_json success "$(printf 'кавычка " слэш \\ таб\tконец')" code=ok)
    _st_json "$(t selftest_emit_escape)" "$j" '.status=="success" and (.message|test("кавычка")) and .code=="ok"'
    # Ровно одна строка: мост отдаёт JSON последней строкой stdout, и перевод
    # строки внутри сообщения разорвал бы ответ на два «сообщения» для читателя.
    _st_eq "$(t selftest_emit_one_line)" "$(printf '%s' "$j" | wc -l | tr -d ' ')" "0"

    # @json: значение вставляется как есть, без кавычек — иначе список
    # пользователей приезжал бы в бот строкой со \" вместо массива.
    j=$(ga_emit_json success ok users='@json:[{"name":"anna"}]' n='@json:3')
    _st_json "$(t selftest_emit_at_json)" "$j" '(.users|type=="array") and .users[0].name=="anna" and .n==3'

    # Мусор после @json: не должен ронять ответ: мост обязан вернуть валидный
    # JSON при любом входе, иначе вызывающий получает transport-ошибку.
    j=$(ga_emit_json error boom bad='@json:{не json}')
    _st_json "$(t selftest_emit_at_json_bad)" "$j" '.status=="error" and (.bad|type=="string")'

    # Небезопасное имя поля отбрасывается, а не попадает в программу jq
    j=$(ga_emit_json success ok 'a b'=1 ok=1)
    _st_json "$(t selftest_emit_bad_key)" "$j" '(has("a b")|not) and .ok=="1"'
    return 0
}

# ── config.json: чтение, запись, атомарность, права ──────────────────────────
_st_config() {
    command -v jq >/dev/null 2>&1 || { _st_skip "$(t selftest_config)" "jq"; return 0; }

    printf '%s' '{"schema":1,"mode":"lite","profiles":{"awg2":{"port":443}},"client_dns":["1.1.1.1"]}' \
        | _ga_write_json "$CONFIG_FILE"

    _st_eq "$(t selftest_config_get)"      "$(ga_config_get .mode)" "lite"
    _st_eq "$(t selftest_config_get_null)" "$(ga_config_get .nope)" ""

    ga_config_set .mode pro >/dev/null 2>&1
    _st_eq "$(t selftest_config_set)" "$(ga_config_get .mode)" "pro"

    # 0600 после записи: в config.json лежат домен и путь мини-аппа, а рядом
    # тем же кодом пишется users.json с приватными ключами.
    local mode
    mode=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null)
    _st_eq "$(t selftest_config_perm)" "$mode" "600"

    # Слияние не должно сносить соседние ветки profiles
    ga_config_merge '{"profiles":{"awg3":{"port":51820}}}' >/dev/null 2>&1
    _st_eq "$(t selftest_config_merge_keeps)" "$(ga_config_get '.profiles["awg2"].port')" "443"
    _st_eq "$(t selftest_config_merge_adds)"  "$(ga_config_get '.profiles["awg3"].port')" "51820"

    # Небезопасный jq-путь обязан быть отвергнут: значение приходит из аргументов
    # моста и подставляется прямо в программу jq.
    _st_nrc "$(t selftest_config_bad_path)" ga_config_set '.mode | error("x")' pro

    # Битый вход не затирает рабочий файл и не оставляет мусора рядом с ним
    printf '%s' '{"broken":' | _ga_write_json "$CONFIG_FILE" >/dev/null 2>&1
    _st_eq "$(t selftest_config_atomic)" "$(ga_config_get .mode)" "pro"
    local leftovers
    leftovers=$(find "$(dirname "$CONFIG_FILE")" -maxdepth 1 -name 'config.json.*' 2>/dev/null | wc -l | tr -d ' ')
    _st_eq "$(t selftest_config_no_tmp)" "$leftovers" "0"
    return 0
}

# ── users.json ───────────────────────────────────────────────────────────────
_st_users() {
    command -v jq >/dev/null 2>&1 || { _st_skip "$(t selftest_users)" "jq"; return 0; }

    rm -f "$USERS_FILE"
    # Нет файла → скелет, а не ошибка: вызывающему не приходится различать
    # «пользователей нет» и «файла нет».
    _st_json "$(t selftest_users_skeleton)" "$(ga_users_read)" '.schema==1 and (.users|length)==0'

    printf '%s' '{"schema":1,"users":[{"name":"anna","enabled":true,"peers":{"awg2":{"privkey":"SECRET"}}}]}' \
        | ga_users_write
    _st_json "$(t selftest_users_roundtrip)" "$(ga_users_read)" '.users[0].name=="anna" and .users[0].peers.awg2.privkey=="SECRET"'

    local mode
    mode=$(stat -c '%a' "$USERS_FILE" 2>/dev/null || stat -f '%Lp' "$USERS_FILE" 2>/dev/null)
    _st_eq "$(t selftest_users_perm)" "$mode" "600"

    # Битый users.json не должен молча превращаться в пустой список: следующая
    # запись затёрла бы реальных пользователей вместе с их ключами.
    printf '%s' '{"users": [' > "$USERS_FILE"
    _st_nrc "$(t selftest_users_corrupt)" ga_users_read
    rm -f "$USERS_FILE"
    return 0
}

# ── Замок ────────────────────────────────────────────────────────────────────
_st_lock() {
    # Реентрантность: вложенный ga_config_set берёт тот же замок. Без
    # GA_CONFIG_LOCK_HELD здесь был бы вечный flock на самом себе.
    _outer_lock_body() {
        [ -n "${GA_CONFIG_LOCK_HELD:-}" ] || return 1
        ga_config_set .lock_probe yes >/dev/null 2>&1 || return 1
        ga_with_config_lock true || return 1
        return 0
    }
    _st_rc "$(t selftest_lock_reentrant)" ga_with_config_lock _outer_lock_body
    _st_eq "$(t selftest_lock_probe_written)" "$(ga_config_get .lock_probe)" "yes"
    # Флаг обязан исчезнуть после возврата, иначе следующий вызов пойдёт мимо
    # замка и две записи из разных интерфейсов потеряют друг друга.
    _st_eq "$(t selftest_lock_flag_cleared)" "${GA_CONFIG_LOCK_HELD:-}" ""
    unset -f _outer_lock_body
    return 0
}

# ── Зависимости ──────────────────────────────────────────────────────────────
_st_deps() {
    if ! type deps_report_json >/dev/null 2>&1; then
        _st_skip "$(t selftest_deps)" "deps.sh"
        return 0
    fi
    local dj
    dj=$(DEPS_QUIET=1 deps_report_json core 2>/dev/null)
    # Сверяем связность полей, а не наличие имени "ok": ok=false с пустым
    # missing — это «чего-то не хватает, а чего, не скажем» в боте и панели.
    _st_json "$(t selftest_deps_json)" "$dj" \
        '(.ok|type=="boolean") and (.missing|type=="array") and (.ok or ((.missing|length)>0))'
    return 0
}

# ── Бюджет логов ─────────────────────────────────────────────────────────────
_st_logbudget() {
    if ! type _logb_trim_dir >/dev/null 2>&1; then
        _st_skip "$(t selftest_logb)" "logbudget.sh"
        return 0
    fi
    # Предохранитель: /var/log без маски — это логи всей системы и соседей.
    # Функция обязана уйти, не тронув ни одного файла, даже при нулевом бюджете.
    _st_rc "$(t selftest_logb_guard)" _logb_trim_dir "/var/log" "" 0
    _st_eq "$(t selftest_logb_mb)" "$(_logb_mb 314572800)" "300"
    return 0
}

# ── Бэкап ────────────────────────────────────────────────────────────────────
_st_backup() {
    if ! type backup_schedule_calendar >/dev/null 2>&1; then
        _st_skip "$(t selftest_backup)" "backup.sh"
        return 0
    fi
    _st_eq  "$(t selftest_backup_daily)"  "$(backup_schedule_calendar daily)"  "*-*-* 03:20:00"
    _st_eq  "$(t selftest_backup_off)"    "$(backup_schedule_calendar off)"    ""
    _st_nrc "$(t selftest_backup_bad)"    backup_schedule_calendar hourly
    # Без lib/amnezia.sh восстановление профилей обязано мягко предупредить,
    # а не упасть: бэкап-таймер грузит не весь набор модулей. Под полным
    # `install.sh --selftest` модуль загружен, и настоящее восстановление в
    # песочнице честно отвечало 1 — «1 провалено» на исправном сервере (T26).
    # Поэтому проверяем именно путь «модуля нет»: в подоболочке без функции.
    _st_rc  "$(t selftest_backup_restore_soft)" _st_restore_soft_probe
    return 0
}

_st_restore_soft_probe() { ( unset -f amnezia_state_restore 2>/dev/null; restore_profiles_from_state ); }

# ── Спринт 4: обновления, импорт, таймеры ───────────────────────────────────
# Модули подключает install.sh; автономный `bash lib/selftest.sh` их не грузит —
# тогда проверка честно пропускается, а не падает по set -u.
_st_sprint4() {
    local root="${SELFTEST_ROOT:-.}" tmp
    if ! type ga_up_patch_start_sh >/dev/null 2>&1; then
        _st_skip "$(t selftest_sprint4)" "upstream.sh"
        return 0
    fi
    # Патч идемпотентных iptables обязан воспроизводить наш awg/start.sh байт в
    # байт из дословного upstream — иначе upstream-update молча подменит правку.
    if [ -f "$root/lib/upstream/awg/start.sh.upstream" ]; then
        tmp=$(mktemp) || return 0
        ga_up_patch_start_sh "$root/lib/upstream/awg/start.sh.upstream" 2>/dev/null >"$tmp"
        if cmp -s "$tmp" "$root/lib/upstream/awg/start.sh"; then
            _st_ok "$(t selftest_sprint4_patch)"
        else
            _st_bad "$(t selftest_sprint4_patch)" "identical" "differs"
        fi
        rm -f "$tmp"
    fi
    if type ga_import_user_name >/dev/null 2>&1; then
        _st_eq "$(t selftest_sprint4_import_name)" "$(ga_import_user_name "iPhone Анны" "AAAA" "")" "iPhone"
        _st_eq "$(t selftest_sprint4_import_dup)" "$(ga_import_user_name "office-router" "AAAA" "office-router")" "office-router-2"
    fi
    if type ga_timers_spec >/dev/null 2>&1; then
        _st_eq "$(t selftest_sprint4_timer)" "$(ga_timers_spec quota | cut -d'|' -f1,3)" "quota-tick|5min"
        _st_nrc "$(t selftest_sprint4_timer_bad)" ga_timers_spec nope
    fi
    return 0
}

# ── Линейка профиля: поле line, вывод по параметрам, миграция ───────────────
# Имя профиля — это имя, а не линейка: контейнер amnezia-awg2, поставленный
# приложением Amnezia, бывает и 3.1. Проверяем то, на что опираются валидация
# параметров и выдача ключей, и заодно миграцию старых установок без поля.
_st_profile_line() {
    if ! type ga_profile_line >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        _st_skip "$(t selftest_line)" "amnezia.sh/jq"
        return 0
    fi
    # Песочница run_selftest: CONFIG_FILE во временном каталоге, портить нечего.
    local p31 p20
    p31='{"Jc":"4","Jmin":"10","Jmax":"50","S1":"12","S2":"12","S3":"12","S4":"12","H1":"1","H2":"2","H3":"3","H4":"4","HeaderProtectionKey":"uBfHoaixlboq2YYNTicMJa5Y76DwpaIc5/vrYKbPbGI=","RandomTrailers":"on"}'
    p20='{"Jc":"4","Jmin":"10","Jmax":"50","S1":"12","S2":"12","S3":"12","S4":"12","H1":"1-2","H2":"3-4","H3":"5-6","H4":"7-8"}'
    jq -cn --argjson a "$p31" --argjson b "$p20" '
        {schema: 1, profiles: {
            awg2: {container: "amnezia-awg2", line: "3.1", params: $a, installed_at: "2026-01-01T00:00:00Z"},
            awg3: {container: "amnezia-awg3", line: "",    params: $b, installed_at: "2026-01-01T00:00:00Z"},
            awg1: {container: "amnezia-awg1", line: "",    params: {},  installed_at: "2026-01-01T00:00:00Z"}}}' \
        2>/dev/null >"$CONFIG_FILE" || return 0
    chmod 600 "$CONFIG_FILE" 2>/dev/null

    _st_eq "$(t selftest_line_field)" "$(ga_profile_line awg2)" "3.1"
    _st_eq "$(t selftest_line_base)" "$(ga_profile_line_base awg2)/$(ga_profile_line_base awg1)" "3.1/1.5"
    # awg3 без поля line, но с 2.0-параметрами: имя обещало бы 3.1, конфиг
    # говорит 2.0 — верим конфигу.
    _st_eq "$(t selftest_line_derive)" "$(ga_profile_line awg3)" "2.0"
    # awg1 без поля и без параметров — выводить не из чего, остаётся умолчание.
    _st_eq "$(t selftest_line_fresh)" "$(ga_profile_line awg1)" "1.5"

    if type ga_migrate_profile_line >/dev/null 2>&1; then
        local fixed
        fixed=$(ga_migrate_profile_line 2>/dev/null | sort | tr '\n' ' ')
        _st_eq "$(t selftest_line_migrate)" "${fixed% }|$(jq -r '.profiles.awg3.line' "$CONFIG_FILE" 2>/dev/null)" "awg1=1.5 awg3=2.0|2.0"
        _st_eq "$(t selftest_line_migrate_idem)" "$(ga_migrate_profile_line 2>/dev/null)" ""
    fi
    return 0
}

# ── Регистрация (порядок = порядок вывода) ───────────────────────────────────
selftest_case selftest_head_syntax     _st_syntax
selftest_case selftest_head_i18n       _st_i18n
selftest_case selftest_head_validators _st_validators
selftest_case selftest_head_arch       _st_arch
selftest_case selftest_head_emit       _st_emit_json
selftest_case selftest_head_config     _st_config
selftest_case selftest_head_users      _st_users
selftest_case selftest_head_lock       _st_lock
selftest_case selftest_head_deps       _st_deps
selftest_case selftest_head_logb       _st_logbudget
selftest_case selftest_head_backup     _st_backup
selftest_case selftest_head_sprint4    _st_sprint4
selftest_case selftest_head_line       _st_profile_line

# ══════════════════════════════════════════════════════════════════════════════
#  Прогон
# ══════════════════════════════════════════════════════════════════════════════
run_selftest() {
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/goamnezia-selftest.XXXXXX") || return 1
    ST_TALLY="$tmp/tally"; : > "$ST_TALLY"

    # Пути common.sh вычисляются в момент source, поэтому одной подменой
    # GOAMNEZIA_DIR тут не обойтись — переставляем каждую производную явно и
    # так же явно возвращаем назад: --selftest может быть вызван из меню.
    local o_dir="$GOAMNEZIA_DIR" o_cfg="$CONFIG_FILE" o_users="$USERS_FILE" \
          o_state="$STATE_DIR" o_backup="$BACKUP_DIR" o_lock="$LOCK_FILE" \
          o_log="$LOG_FILE" o_audit="$AUDIT_LOG" o_dry="${GOAMNEZIA_DRY_RUN:-}" \
          o_lang=""
    type get_language >/dev/null 2>&1 && o_lang=$(get_language)

    GOAMNEZIA_DIR="$tmp"
    CONFIG_FILE="$tmp/config.json"
    USERS_FILE="$tmp/users.json"
    STATE_DIR="$tmp/state"
    BACKUP_DIR="$tmp/backups"
    LOCK_FILE="$tmp/config.lock"
    LOG_FILE="$tmp/goamnezia.log"
    AUDIT_LOG="$tmp/goamnezia-audit.log"
    GOAMNEZIA_DRY_RUN=1
    export GOAMNEZIA_DRY_RUN
    mkdir -p "$STATE_DIR" "$BACKUP_DIR" 2>/dev/null

    printf '\n\033[1;37m  %s\033[0m\n' "$(tf selftest_title "$GOAMNEZIA_VERSION")"
    printf '\033[2m  %s\033[0m\n' "$(tf selftest_sandbox "$tmp")"

    local entry key fn
    for entry in "${SELFTEST_CASES[@]}"; do
        key="${entry%%|*}"; fn="${entry#*|}"
        type "$fn" >/dev/null 2>&1 || continue
        _st_head "$(t "$key")"
        "$fn" || true
    done

    local p f k
    p=$(_st_count PASS); f=$(_st_count FAIL); k=$(_st_count SKIP)
    printf '\n\033[1m  %s: \033[32m%s\033[0m' "$(t selftest_total)" "$(tf selftest_passed "$p")"
    [ "$f" -gt 0 ] && printf ', \033[31m%s\033[0m' "$(tf selftest_failed "$f")"
    [ "$k" -gt 0 ] && printf ', \033[2m%s\033[0m' "$(tf selftest_skipped_n "$k")"
    printf '\n\n'

    # Возвращаем окружение и язык на место
    GOAMNEZIA_DIR="$o_dir"; CONFIG_FILE="$o_cfg"; USERS_FILE="$o_users"
    STATE_DIR="$o_state"; BACKUP_DIR="$o_backup"; LOCK_FILE="$o_lock"
    LOG_FILE="$o_log"; AUDIT_LOG="$o_audit"
    if [ -n "$o_dry" ]; then GOAMNEZIA_DRY_RUN="$o_dry"; else unset GOAMNEZIA_DRY_RUN; fi
    [ -n "$o_lang" ] && type load_language >/dev/null 2>&1 && load_language "$o_lang"

    rm -rf "$tmp" 2>/dev/null
    [ "$f" -eq 0 ]
}

# Имя из goTelegram оставлено синонимом: install.sh серии зовёт selftest_run.
selftest_run() { run_selftest "$@"; }

# ── Автономный запуск: bash lib/selftest.sh ──────────────────────────────────
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
    _st_self_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
    # shellcheck source=/dev/null
    source "$_st_self_dir/common.sh"
    # shellcheck source=/dev/null
    source "$_st_self_dir/i18n.sh"
    # shellcheck source=/dev/null
    [ -f "$_st_self_dir/deps.sh" ]      && source "$_st_self_dir/deps.sh"
    # shellcheck source=/dev/null
    [ -f "$_st_self_dir/logbudget.sh" ] && source "$_st_self_dir/logbudget.sh"
    # shellcheck source=/dev/null
    [ -f "$_st_self_dir/backup.sh" ]    && source "$_st_self_dir/backup.sh"
    load_language "$(detect_language)"
    run_selftest
fi
