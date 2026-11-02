#!/bin/bash
# goAmnezia pro — lib/awg_params.sh: тонкие обёртки над lib/awgkeys.py (CONTRACT §4.2).
#
# Вся логика параметров AmneziaWG и форматов ключей — в Python; здесь только проверка
# аргументов регексами (правило 8), поиск помощника и перевод ошибок через t/tf.
# Правило 2 (subshell-capture): в stdout — только результат, всё остальное в stderr.
# Подключается через source; никаких exit внутри библиотеки.

# Фолбэки для запуска модуля отдельно (тесты, отладка): в боевом install.sh
# t/tf приходят из lib/i18n.sh, log_error — из lib/common.sh. Без словаря печатаем
# ключ и аргументы — так причина видна даже в «голом» запуске.
if ! declare -F t >/dev/null 2>&1; then
    t() { printf '%s\n' "$1"; }
fi
if ! declare -F tf >/dev/null 2>&1; then
    tf() {
        local key="$1"
        shift
        printf '%s' "$key"
        [ $# -gt 0 ] && printf ' %s' "$@"
        printf '\n'
    }
fi

# Сообщение об ошибке в stderr — через log_error, если ядро загружено.
ga_awg_error() {
    if declare -F log_error >/dev/null 2>&1; then
        log_error "$@"
    else
        printf '%s\n' "$*" >&2
    fi
}

# Путь к awgkeys.py: переменные GOAMNEZIA_AWGKEYS / AWGKEYS_PY (тесты/стенды, та же
# переменная, что у lib/amnezia.sh) → рядом с этим файлом → $SCRIPT_DIR/lib → эталон
# в /opt/goamnezia. Результат в stdout.
ga_awgkeys_py() {
    local py="${GOAMNEZIA_AWGKEYS:-${AWGKEYS_PY:-}}"
    local here cand
    if [ -z "$py" ]; then
        here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
        for cand in "${here:+$here/awgkeys.py}" "${SCRIPT_DIR:+${SCRIPT_DIR}/lib/awgkeys.py}" \
                    "${GOAMNEZIA_DIR:-/opt/goamnezia}/lib/awgkeys.py"; do
            [ -n "$cand" ] && [ -f "$cand" ] && { py="$cand"; break; }
        done
    fi
    if [ -z "$py" ] || [ ! -f "$py" ]; then
        ga_awg_error "$(tf awg_params_script_missing "awgkeys.py")"
        return 1
    fi
    printf '%s\n' "$py"
}

# Интерпретатор: python3 из явного PATH install.sh. Результат в stdout.
ga_awgkeys_python() {
    local py3
    py3="$(command -v python3 2>/dev/null)" || py3=""
    if [ -z "$py3" ]; then
        ga_awg_error "$(t awg_params_python_missing)"
        return 1
    fi
    printf '%s\n' "$py3"
}

# Универсальный запуск подкоманды: stdin и stdout пробрасываются как есть,
# stderr Python уходит в наш stderr. ga_awg_run <подкоманда> [аргументы…]
# (имя нарочно не ga_awgkeys — так называется раннер в lib/amnezia.sh, и два
# определения в одной оболочке перекрывали бы друг друга).
ga_awg_run() {
    local py py3
    py="$(ga_awgkeys_py)" || return 1
    py3="$(ga_awgkeys_python)" || return 1
    "$py3" "$py" "$@"
}

ga_awg_check_line() {
    local re='^(1\.0|1\.5|2\.0|3\.1)$'
    if ! [[ "${1:-}" =~ $re ]]; then
        ga_awg_error "$(tf awg_params_bad_line "${1:-}")"
        return 1
    fi
}

ga_awg_check_preset() {
    local re='^(default|quic|router)$'
    if ! [[ "${1:-}" =~ $re ]]; then
        ga_awg_error "$(tf awg_params_bad_preset "${1:-}")"
        return 1
    fi
}

# awg_params_generate <line> [preset] → JSON params в stdout
awg_params_generate() {
    local line="${1:-}" preset="${2:-default}" out
    ga_awg_check_line "$line" || return 1
    ga_awg_check_preset "$preset" || return 1
    if ! out="$(ga_awg_run gen-params --line "$line" --preset "$preset")" || [ -z "$out" ]; then
        ga_awg_error "$(tf awg_params_generate_failed "$line")"
        return 1
    fi
    printf '%s\n' "$out"
}

# awg_params_validate <line> <json> [write|adopt] → 0 если параметры годятся, иначе 1 и причины в stderr.
# Третий аргумент — правила тегов I1–I5 (KMOD-02): write (по умолчанию) — то, что пишем мы: только теги, понятные и
# модулю ядра, и amneziawg-go; adopt — уже записанные при подхвате: теги любой реализации.
awg_params_validate() {
    local line="${1:-}" json="${2:-}" mode="${3:-write}" err
    ga_awg_check_line "$line" || return 1
    if [ -z "$json" ]; then
        ga_awg_error "$(t awg_params_bad_json)"
        return 1
    fi
    [[ "$mode" =~ ^(write|adopt)$ ]] || mode="write"
    if ! err="$(printf '%s' "$json" | ga_awg_run validate --line "$line" --ipackets "$mode" 2>&1 >/dev/null)"; then
        ga_awg_error "$(tf awg_params_invalid "$line")"
        [ -n "$err" ] && printf '%s\n' "$err" >&2
        return 1
    fi
    return 0
}

# awg_line_detect ← JSON params или текст .conf на stdin → линейка в stdout
awg_line_detect() {
    ga_awg_run detect-line
}

# awg_keys_genkey → приватный ключ X25519 (base64) в stdout
awg_keys_genkey() {
    local out
    if ! out="$(ga_awg_run genkey)" || [ -z "$out" ]; then
        ga_awg_error "$(tf awg_keys_failed "genkey")"
        return 1
    fi
    printf '%s\n' "$out"
}

# awg_keys_pubkey <priv> → публичный ключ в stdout. Приватник передаём через stdin,
# чтобы он не светился в списке процессов.
awg_keys_pubkey() {
    local priv="${1:-}" out
    local re='^[A-Za-z0-9+/]{43}=$'
    if ! [[ "$priv" =~ $re ]]; then
        ga_awg_error "$(t awg_keys_bad_privkey)"
        return 1
    fi
    if ! out="$(printf '%s\n' "$priv" | ga_awg_run pubkey -)" || [ -z "$out" ]; then
        ga_awg_error "$(tf awg_keys_failed "pubkey")"
        return 1
    fi
    printf '%s\n' "$out"
}

# awg_keys_genpsk → PresharedKey (base64) в stdout
awg_keys_genpsk() {
    local out
    if ! out="$(ga_awg_run genpsk)" || [ -z "$out" ]; then
        ga_awg_error "$(tf awg_keys_failed "genpsk")"
        return 1
    fi
    printf '%s\n' "$out"
}
