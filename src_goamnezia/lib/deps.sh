#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# lib/deps.sh — зависимости goAmnezia pro (порт из goTelegram Pro).
#
# Что делает:
#   • проверяет команды и свойства системы по ПРОФИЛЯМ;
#   • печатает человекочитаемую таблицу «статус · компонент · зачем» (в stderr);
#   • отдаёт машиночитаемое: deps_missing_list (name|pkg|severity) и
#     deps_report_json (для бота, панели и MCP);
#   • по ЯВНОМУ вызову доустанавливает apt-пакеты (deps_install_missing).
#
# Контракт модуля (не менять, на нём стоят вызывающие):
#   • ни одна функция не делает exit — только return: модуль сорсится в меню;
#   • безопасен под `set -uo pipefail` (везде ${VAR:-}, нет `… | grep -q` в
#     условиях: SIGPIPE + pipefail дают ложное «нет»);
#   • при source ничего не выполняет и ничего не меняет в системе;
#   • идемпотентен;
#   • таблица и логи — в stderr, stdout остаётся чистым для JSON и списков.
#
# Профили: core docker qr web tls botweb mcp templates   (а также `all`)
#
# Примеры:
#   source lib/deps.sh
#   deps_check core docker || echo "не хватает критичного"
#   deps_missing_list                      # jq|jq|crit
#   deps_install_missing --yes core docker
#   deps_report_json | jq .
#   bash lib/deps.sh core tls              # автономный прогон
# ══════════════════════════════════════════════════════════════════════════════

# ── Цвета: если модуль сорснут без common.sh — заводим свои (формат echo -e) ──
# Умолчания цветов — ТОЛЬКО для НЕОБЪЯВЛЕННЫХ переменных: `${VAR=…}`, а не
# `${VAR:=…}`. Разница в одном двоеточии, но она решающая — `:=`, а оно срабатывает и на ПУСТОМ значении: lib/common.sh выключал
# раскраску (GOAMNEZIA_COLOR=never, NO_COLAR/NO_COLOR, TERM=dumb, вывод не в
# терминал) и присваивал пустые строки, а эти строки тут же возвращали цвета
# обратно. Выключатель не работал вовсе, и `goamnezia > отчёт.txt` давал файл с
# управляющими последовательностями.
: "${RED=\033[0;31m}"
: "${GREEN=\033[0;32m}"
: "${YELLOW=\033[1;33m}"
: "${CYAN=\033[0;36m}"
: "${WHITE=\033[1;37m}"
: "${BOLD=\033[1m}"
: "${DIM=\033[2m}"
: "${NC=\033[0m}"

# ── Логгеры и i18n: берём из common.sh/i18n.sh, если они уже загружены ────────
if ! type log_info    >/dev/null 2>&1; then log_info()    { echo -e "  ${CYAN}ℹ${NC} $*" >&2; }; fi
if ! type log_success >/dev/null 2>&1; then log_success() { echo -e "  ${GREEN}✓${NC} $*" >&2; }; fi
if ! type log_warning >/dev/null 2>&1; then log_warning() { echo -e "  ${YELLOW}⚠${NC} $*" >&2; }; fi
if ! type log_error   >/dev/null 2>&1; then log_error()   { echo -e "  ${RED}✗${NC} $*" >&2; }; fi
if ! type log_step    >/dev/null 2>&1; then log_step()    { echo -e "\n${BOLD}${WHITE}  $*${NC}" >&2; }; fi
if ! type log_dim     >/dev/null 2>&1; then log_dim()     { echo -e "  ${DIM}$*${NC}" >&2; }; fi
if ! type t           >/dev/null 2>&1; then t()  { printf '%s\n' "${1:-}"; }; fi
if ! type tf          >/dev/null 2>&1; then tf() { local k="${1:-}"; shift; printf '%s %s\n' "$k" "$*"; }; fi

# ── Состояние последней проверки ─────────────────────────────────────────────
DEPS_PROFILES_ALL="core docker qr web tls botweb mcp templates"
DEPS_MISSING=()                 # строки "name|pkg|severity"
DEPS_RESULTS=()                 # строки "name|installed|required|reason"
DEPS_LAST_PROFILES="core"
DEPS_CHECKED=0                  # 1 = deps_check хоть раз отработал
DEPS_QUIET="${DEPS_QUIET:-0}"   # 1 = не печатать таблицу (внутренний режим)
DEPS_N_CRIT=0
DEPS_N_WARN=0
DEPS_N_OPT=0

# ══════════════════════════════════════════════════════════════════════════════
#  ТАБЛИЦА ЗАВИСИМОСТЕЙ
#  формат строки:  профиль|имя|проверка|apt-пакет|важность|ключ-«зачем»
#    проверка : cmd:<команда> | lib:<libname> | file:<путь> | func:<функция>
#    пакет    : имя пакета в apt, либо "-" если поставить нельзя
#    важность : crit — без него профиль не работает | warn — есть обход |
#               opt  — приятно иметь
#    «зачем»  : КЛЮЧ словаря, а не текст. Текст в таблице означал бы видимую
#               строку вне t/tf и второй экземпляр таблицы на каждый язык.
#  Один компонент может встречаться в нескольких профилях — при проверке
#  дубликаты схлопываются по имени (побеждает первое вхождение).
# ══════════════════════════════════════════════════════════════════════════════
DEPS_TABLE=(
  # ── core: нужно всегда ─────────────────────────────────────────────────────
  "core|bash|cmd:bash|bash|crit|deps_why_bash"
  "core|jq|cmd:jq|jq|crit|deps_why_jq"
  "core|curl|cmd:curl|curl|crit|deps_why_curl"
  "core|openssl|cmd:openssl|openssl|crit|deps_why_openssl"
  "core|tar|cmd:tar|tar|crit|deps_why_tar"
  "core|flock|cmd:flock|util-linux|crit|deps_why_flock"
  "core|ss|cmd:ss|iproute2|crit|deps_why_ss"
  "core|dig|cmd:dig|dnsutils|warn|deps_why_dig"
  # python3 — ключи, параметры и разбор конфигов (lib/awgkeys.py) нужны уже мастеру: без него поиск
  # контейнеров приложения Amnezia объявлял их «без конфига AmneziaWG», а установка профиля падала на
  # генерации параметров. Раньше он приезжал только с ботом и панелью (botweb).
  "core|python3|cmd:python3|python3|crit|deps_why_python3"
  "core|ip|cmd:ip|iproute2|crit|deps_why_ip"
  "core|iptables|cmd:iptables|iptables|crit|deps_why_iptables"
  "core|systemctl|cmd:systemctl|systemd|crit|deps_why_systemctl"
  "core|gzip|cmd:gzip|gzip|crit|deps_why_gzip"
  "core|awk|cmd:awk|gawk|crit|deps_why_text"
  "core|sed|cmd:sed|sed|crit|deps_why_text"
  "core|grep|cmd:grep|grep|crit|deps_why_text"
  "core|find|cmd:find|findutils|crit|deps_why_coreutils"
  "core|xargs|cmd:xargs|findutils|crit|deps_why_coreutils"
  "core|cmp|cmd:cmp|diffutils|crit|deps_why_text"
  "core|sysctl|cmd:sysctl|procps|crit|deps_why_ip"
  "core|hostname|cmd:hostname|hostname|crit|deps_why_ip"
  "core|getent|cmd:getent|libc-bin|crit|deps_why_ip"
  "core|nsenter|cmd:nsenter|util-linux|crit|deps_why_ip"
  "core|coreutils|func:_deps_have_coreutils|coreutils|crit|deps_why_coreutils"
  "core|ca-certificates|func:_deps_have_ca|ca-certificates|crit|deps_why_ca"

  # ── docker: контейнеры Amnezia ─────────────────────────────────────────────
  # Пакет именно docker.io из репозитория дистрибутива, а не скрипт
  # get.docker.com: на серверах в закрытых сетях он не скачивается, а версия
  # из репозитория нам подходит — мы тянем образы по дайджесту, а не по тегу.
  "docker|docker|cmd:docker|docker.io|crit|deps_why_docker"

  # ── qr: выдача ключей картинкой ────────────────────────────────────────────
  "qr|qrencode|cmd:qrencode|qrencode|opt|deps_why_qrencode"

  # ── web: сайт-маскировка в Pro ─────────────────────────────────────────────
  "web|nginx|cmd:nginx|nginx|crit|deps_why_nginx"

  # ── tls: сертификат домена ─────────────────────────────────────────────────
  "tls|certbot|cmd:certbot|certbot|crit|deps_why_certbot"

  # ── botweb: Telegram-бот и веб-панель ──────────────────────────────────────
  "botweb|python3|cmd:python3|python3|crit|deps_why_python3"
  "botweb|python3-venv|func:_deps_have_venv|python3-venv|crit|deps_why_venv"

  # ── mcp: MCP-сервер (только stdlib, venv не нужен) ─────────────────────────
  "mcp|python3|cmd:python3|python3|crit|deps_why_python3"
  "templates|git|cmd:git|git|crit|deps_why_git"
)

# ══════════════════════════════════════════════════════════════════════════════
#  Низкоуровневые проверки
# ══════════════════════════════════════════════════════════════════════════════

# Сравнение числовых частей без sort -V: тот отсутствует на macOS, где идут сухие прогоны.
_deps_ver_ge() {
    local a="${1:-}" b="${2:-}" i av bv
    local aa=() bb=()
    [[ "$a" =~ ^[0-9]+(\.[0-9]+)*$ ]] && [[ "$b" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
    IFS=. read -r -a aa <<<"$a"; IFS=. read -r -a bb <<<"$b"
    for ((i=0; i<${#aa[@]} || i<${#bb[@]}; i++)); do
        av=$((10#${aa[$i]:-0})); bv=$((10#${bb[$i]:-0}))
        [ "$av" -gt "$bv" ] && return 0
        [ "$av" -lt "$bv" ] && return 1
    done
    return 0
}

# Минимум подтверждается используемыми возможностями: nameref (bash), $ENV/inputs (jq),
# заголовки из stdin и сокет Docker (curl), PBKDF2 (openssl), stdlib Python 3.8.
_deps_min_version() {
    case "${1:-}" in
        bash) printf 4.3 ;; jq) printf 1.6 ;; curl) printf 7.55.0 ;;
        openssl) printf 1.1.1 ;; python3) printf 3.8 ;;
        docker) printf 20.10 ;; nginx) printf 1.18 ;; certbot) printf 1.0 ;;
        qrencode) printf 3.4 ;; git) printf 2.20 ;;
    esac
}

_deps_cmd_version() {
    local cmd="${1:-}" out="" v=""
    case "$cmd" in
        bash) out=$("${BASH:-bash}" -c 'printf "%s" "$BASH_VERSION"' 2>/dev/null) || return 1 ;;
        jq) out=$(jq --version 2>/dev/null) || return 1; out=${out#jq-} ;;
        python3) out=$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))' 2>/dev/null) || return 1 ;;
        openssl) out=$(openssl version 2>/dev/null) || return 1; out=${out#* } ;;
        nginx) out=$(nginx -v 2>&1) || return 1; out=${out##*/} ;;
        *) out=$("$cmd" --version 2>/dev/null) || return 1 ;;
    esac
    # Только номер: суффиксы дистрибутива и вывод чужого бинарника не попадают в JSON/арифметику.
    if [[ "$out" =~ ([0-9]+\.[0-9]+(\.[0-9]+)*) ]]; then v=${BASH_REMATCH[1]}; fi
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

_deps_have_coreutils() {
    local cmd
    # Список — DEPS_COREUTILS (ниже): по нему же снимается отпечаток отметки «уже проверено».
    for cmd in $DEPS_COREUTILS; do
        command -v "$cmd" >/dev/null 2>&1 || return 1
    done
    readlink -f / >/dev/null 2>&1 || return 1
}
_deps_have_ca() {
    [ -s /etc/ssl/certs/ca-certificates.crt ] || [ -s /etc/ssl/cert.pem ]
}

# Наличие файла команды недостаточно: она может оказаться старой, сломанной или без нужного модуля.
# Не трогаем службы и не обращаемся к сети: docker --version проверяет CLI, не работающий демон.
_deps_check_cmd() {
    local cmd="${1:-}" out=""
    DEPS_REQUIRED=$(_deps_min_version "$cmd"); DEPS_INSTALLED=""; DEPS_REASON=missing
    # PTB 21 из requirements.txt требует Python 3.9; ядру и MCP достаточно 3.8.
    if [ "$cmd" = python3 ]; then
        case " ${DEPS_LAST_PROFILES:-core} " in *" botweb "*) DEPS_REQUIRED=3.9 ;; esac
    fi
    command -v "$cmd" >/dev/null 2>&1 || return 1
    DEPS_REASON=capability
    if [ -n "$DEPS_REQUIRED" ]; then
        DEPS_INSTALLED=$(_deps_cmd_version "$cmd") || return 1
        if ! _deps_ver_ge "$DEPS_INSTALLED" "$DEPS_REQUIRED"; then DEPS_REASON=version; return 1; fi
    fi
    case "$cmd" in
        jq) jq -en 'env | type == "object"' >/dev/null 2>&1 || return 1 ;;
        python3) python3 -c 'import ssl, json, hashlib, zlib, subprocess, http.server; assert hasattr(ssl, "TLSVersion")' >/dev/null 2>&1 || return 1 ;;
        curl) out=$(curl --version 2>/dev/null) || return 1
            printf '%s\n' "$out" | awk '/^Protocols:/ {for (i=2; i<=NF; i++) if ($i=="https") ok=1} END {exit !ok}' || return 1 ;;
        openssl) printf test | openssl enc -aes-256-cbc -pbkdf2 -nosalt -pass pass:dependency-probe -out /dev/null >/dev/null 2>&1 || return 1 ;;
        docker) out=$(docker --version 2>/dev/null) || return 1; case "${out,,}" in *podman*) return 1 ;; esac ;;
        ip) ip -V >/dev/null 2>&1 || return 1 ;;
        ss) ss -V >/dev/null 2>&1 || return 1 ;;
        iptables) iptables --version >/dev/null 2>&1 || return 1 ;;
        systemctl) systemctl --version >/dev/null 2>&1 || return 1 ;;
        tar) out=$(tar --help 2>&1) || return 1
            case "$out" in *--no-same-owner*--no-same-permissions*|*--no-same-permissions*--no-same-owner*) : ;; *) return 1 ;; esac ;;
        flock) flock --help >/dev/null 2>&1 || return 1 ;;
        awk) awk 'BEGIN {exit 0}' </dev/null >/dev/null 2>&1 || return 1 ;;
        sed) sed -n '' </dev/null >/dev/null 2>&1 || return 1 ;;
        grep) grep '' /dev/null >/dev/null 2>&1; [ "$?" -le 1 ] || return 1 ;;
        cmp) cmp /dev/null /dev/null >/dev/null 2>&1 || return 1 ;;
        gzip|sysctl|nsenter|xargs|hostname) "$cmd" --version >/dev/null 2>&1 || return 1 ;;
        getent) getent passwd root >/dev/null 2>&1 || return 1 ;;
    esac
    DEPS_REASON=ok
    return 0
}

# На Debian/Ubuntu venv без ensurepip не создаётся — проверяем именно ensurepip,
# иначе «python3 -m venv» падает уже при установке бота, а не при проверке.
_deps_have_venv() { python3 -c 'import venv, ensurepip' >/dev/null 2>&1; }

# Разделяемая библиотека по имени (для будущих lib:-строк таблицы)
_deps_have_lib() {
    local so="${1:-}"; [ -n "$so" ] || return 1
    # ldconfig -p целиком в переменную: `| grep -q` под pipefail даёт 141
    local out; out="$(ldconfig -p 2>/dev/null || /sbin/ldconfig -p 2>/dev/null || true)"
    case "$out" in *"$so"*) return 0 ;; esac
    local d
    for d in /lib /usr/lib /lib64 /usr/lib64 /usr/lib/x86_64-linux-gnu /usr/local/lib; do
        [ -d "$d" ] || continue
        ls "$d"/"$so".so* >/dev/null 2>&1 && return 0
    done
    return 1
}

# deps_openssl_version → «3.0.13» (буквенный суффикс 1.1.1f срезается), либо пусто
deps_openssl_version() {
    local v
    v="$(openssl version 2>/dev/null | awk '{print $2}')"
    v="${v%%[!0-9.]*}"
    v="${v%.}"
    echo "${v:-}"
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  Внутренняя кухня проверки
# ══════════════════════════════════════════════════════════════════════════════

# Выполнить одну проверку из колонки «проверка»
_deps_check_one() {
    local spec="${1:-}" kind arg
    kind="${spec%%:*}"; arg="${spec#*:}"
    [ -n "${arg:-}" ] || return 1
    DEPS_INSTALLED=""; DEPS_REQUIRED=""; DEPS_REASON=missing
    case "$kind" in
        cmd)  _deps_check_cmd "$arg" ;;
        lib)  _deps_have_lib "$arg" ;;
        file) [ -e "$arg" ] ;;
        func) "$arg" >/dev/null 2>&1 ;;
        *)    return 1 ;;
    esac
}

# Строка таблицы. Ширину считаем от ДЛИНЫ ПЕРЕВОДА, а не константой: в
# goTelegram отступы были прибиты гвоздями под русские подписи, и любой другой
# язык разъезжал колонку. printf %-Ns бьёт по БАЙТАМ и на кириллице врёт втрое,
# поэтому меряем ${#txt} (символы в UTF-8 локали) и добиваем пробелами сами.
_deps_row() {
    local st="${1:-}" name="${2:-}" why_key="${3:-}" txt="" color="" pad=0 pads="" namecell=""
    case "$st" in
        ok)   txt="$(t deps_state_ok)";   color="$GREEN" ;;
        crit) txt="$(t deps_state_crit)"; color="$RED" ;;
        warn) txt="$(t deps_state_warn)"; color="$YELLOW" ;;
        *)    txt="$(t deps_state_opt)";  color="$DIM" ;;
    esac
    pad=$(( 20 - ${#txt} ))
    [ "$pad" -lt 1 ] && pad=1
    printf -v pads '%*s' "$pad" ''
    printf -v namecell '%-18s' "$name"
    echo -e "  ${color}${txt}${NC}${pads}${namecell} ${DIM}$(t "$why_key")${NC}" >&2
}

# Уникальные apt-пакеты недостающего (без "-")
_deps_pkg_list() {
    local line name pkg sev out=" "
    if [ ${#DEPS_MISSING[@]} -gt 0 ]; then
        for line in "${DEPS_MISSING[@]}"; do
            IFS='|' read -r name pkg sev <<< "$line"
            [ -n "${pkg:-}" ] && [ "$pkg" != "-" ] || continue
            case "$out" in *" $pkg "*) continue ;; esac
            out="${out}${pkg} "
        done
    fi
    out="${out# }"; out="${out% }"
    echo "$out"
}

# Тихая проверка (без таблицы) — для JSON, списков и доустановки
_deps_quiet_check() {
    local prev="${DEPS_QUIET:-0}"
    DEPS_QUIET=1
    if [ $# -gt 0 ]; then
        deps_check "$@" >/dev/null 2>&1 || true
    else
        # shellcheck disable=SC2086
        deps_check ${DEPS_LAST_PROFILES:-core} >/dev/null 2>&1 || true
    fi
    DEPS_QUIET="$prev"
    return 0
}

_deps_ensure_checked() {
    [ "${DEPS_CHECKED:-0}" = "1" ] && return 0
    _deps_quiet_check
}

# Экранирование для JSON (имена ASCII, но пусть будет честно)
_deps_jesc() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# ── Отметка «профиль уже проверен» (частые вызовы моста) ─────────────────────
# Полная проверка core — двадцать пять команд с версиями и возможностями (импорт ssl и http.server в python3,
# openssl enc, --version у curl, tar, ss…): на сервере в 1 vCPU это 0,2–0,3 CPU-с, и платил их КАЖДЫЙ вызов
# моста — панель на каждом обновлении экрана, бот, сторож раз в две минуты (замер 03.10.2026, CPU-03). Отметка в
# $LOCK_DIR (/run — tmpfs, перезагрузка снимает её сама) хранит отпечаток проверенного: версию продукта, путь
# каждой команды (hash и BASH_CMDS — без процессов) и одним stat — inode, ctime и размер этих файлов, файлов
# сертификатов, базы пакетов (dpkg/status меняется при любой установке и удалении пакета) и самого lib/deps.sh.
# Совпал отпечаток и не прошли сутки — проверять было бы то же самое. Пакет обновили или откатили (ctime файла
# и dpkg/status), подложили свой jq раньше в PATH (путь), заменили файл руками (inode, ctime, размер) — проверка
# идёт полностью. Верят отметке только чтения моста и тики таймеров (install.sh, main → GA_DEPS_STAMP=1); меню,
# установка и изменения из интерфейсов проверяют полностью всегда — несовместимый пакет ловится до установки, как
# в 1.0.7. Без stat GNU (macOS) отпечатка нет — проверка полная, как раньше.
DEPS_STAMP_TTL="${GOAMNEZIA_DEPS_STAMP_TTL:-86400}"
[[ "$DEPS_STAMP_TTL" =~ ^[0-9]{1,7}$ ]] || DEPS_STAMP_TTL=86400
# Команды проверки _deps_have_coreutils — тот же список: их пути входят в отпечаток.
DEPS_COREUTILS="base64 basename cat chmod chown cksum cp cut date df dirname du env head id ln ls mkdir mktemp mv od
readlink rm sha256sum sleep sort stat tail tee touch tr truncate wc"

# _deps_fingerprint <переменная> <профиль…> — отпечаток проверяемого в переменную. rc 1 — снять нельзя (команды
# нет, проверка незнакомого вида, stat не GNU): отметкой тогда не пользуются, проверка идёт полностью.
_deps_fingerprint() {
    local __var="$1" row prof name chk kind arg cmd f st sel seen=" "
    local -a files=()
    shift
    sel=" $* "
    for row in "${DEPS_TABLE[@]}"; do
        prof="${row%%|*}"; row="${row#*|}"
        name="${row%%|*}"; row="${row#*|}"
        chk="${row%%|*}"
        case "$sel" in *" $prof "*) ;; *) continue ;; esac
        case "$seen" in *" $name "*) continue ;; esac
        seen+="$name "
        kind="${chk%%:*}"; arg="${chk#*:}"
        case "$kind" in
            cmd)
                # hash молча пропускает функцию и встроенную команду с тем же именем — тогда файла нет и отпечатка нет.
                hash "$arg" 2>/dev/null && [ -n "${BASH_CMDS[$arg]:-}" ] || return 1
                files+=("${BASH_CMDS[$arg]}") ;;
            func)
                case "$arg" in
                    _deps_have_coreutils)
                        for cmd in $DEPS_COREUTILS; do
                            hash "$cmd" 2>/dev/null && [ -n "${BASH_CMDS[$cmd]:-}" ] || return 1
                            files+=("${BASH_CMDS[$cmd]}")
                        done ;;
                    _deps_have_ca)
                        for f in /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem; do
                            [ -e "$f" ] && files+=("$f")
                        done ;;
                    *) return 1 ;;
                esac ;;
            *) return 1 ;;
        esac
    done
    files+=("${BASH_SOURCE[0]}")
    for f in /var/lib/dpkg/status /var/lib/rpm/rpmdb.sqlite /var/lib/rpm/Packages; do
        [ -e "$f" ] && files+=("$f")
    done
    st=$(LC_ALL=C stat -L -c '%n %i %Z %s' -- "${files[@]}" 2>/dev/null) || return 1
    [ -n "$st" ] || return 1
    printf -v "$__var" 'v=%s p=%s\n%s' "${GOAMNEZIA_VERSION:-?}" "$*" "$st"
}

# deps_stamp_valid [профиль…] — rc 0: эти профили уже проверены полностью и с тех пор ничего из проверенного не
# менялось (см. выше). Файл отметки — только свой (владелец — этот пользователь) и не старше DEPS_STAMP_TTL.
deps_stamp_valid() {
    local f ts="" body="" now fp=""
    [ $# -gt 0 ] || set -- core
    f="${LOCK_DIR:-/run/goamnezia}/deps-${*// /+}.ok"
    [ -f "$f" ] && [ -O "$f" ] || return 1
    { { IFS= read -r ts; IFS= read -r -d '' body; } <"$f"; } 2>/dev/null
    [[ "$ts" =~ ^[0-9]{1,12}$ ]] || return 1
    printf -v now '%(%s)T' -1
    [ "$now" -ge "$ts" ] && [ $((now - ts)) -lt "$DEPS_STAMP_TTL" ] || return 1
    _deps_fingerprint fp "$@" || return 1
    [ "$fp" = "$body" ]
}

# deps_stamp_write [профиль…] — отметка после ПОЛНОЙ проверки этих профилей без единой нехватки (DEPS_MISSING
# пуст, в том числе необязательного: так же решает check_deps_present). Не записалась — не беда: следующий вызов
# проверит полностью.
deps_stamp_write() {
    local dir="${LOCK_DIR:-/run/goamnezia}" fp="" now
    [ $# -gt 0 ] || set -- core
    [ "${DEPS_CHECKED:-0}" = 1 ] && [ "${#DEPS_MISSING[@]}" = 0 ] || return 0
    [ "${DEPS_LAST_PROFILES:-}" = "$*" ] || return 0
    [ -d "$dir" ] || return 0
    _deps_fingerprint fp "$@" || return 0
    printf -v now '%(%s)T' -1
    { printf '%s\n%s' "$now" "$fp" >"$dir/deps-${*// /+}.ok"; } 2>/dev/null || true
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  ПУБЛИЧНОЕ API
# ══════════════════════════════════════════════════════════════════════════════

# deps_profiles — список доступных профилей (для UI)
deps_profiles() { echo "$DEPS_PROFILES_ALL"; }

# deps_check [профиль…] — проверка + таблица-отчёт.
#   0 — всё критичное на месте;  1 — есть неудовлетворённое критичное.
# Без аргументов проверяет профиль core.
deps_check() {
    local profiles=() p sel=" " selt="" quiet="${DEPS_QUIET:-0}"
    local row prof name chk pkg sev why seen=" " st line="" hdr=""

    if [ $# -gt 0 ]; then profiles=("$@"); else profiles=("core"); fi

    for p in "${profiles[@]}"; do
        [ -n "${p:-}" ] || continue
        if [ "$p" = "all" ]; then sel=" ${DEPS_PROFILES_ALL} "; break; fi
        case " ${DEPS_PROFILES_ALL} " in
            *" $p "*)
                case "$sel" in *" $p "*) : ;; *) sel="${sel}${p} " ;; esac ;;
            *)
                [ "$quiet" = "1" ] || log_warning "$(tf deps_unknown_profile "$p" "$DEPS_PROFILES_ALL")" ;;
        esac
    done
    [ "$sel" = " " ] && sel=" core "
    selt="${sel# }"; selt="${selt% }"

    # ── сброс состояния ──
    DEPS_MISSING=(); DEPS_RESULTS=(); DEPS_N_CRIT=0; DEPS_N_WARN=0; DEPS_N_OPT=0
    DEPS_LAST_PROFILES="$selt"; DEPS_CHECKED=1

    if [ "$quiet" != "1" ]; then
        printf -v line '%*s' 66 ''; line="${line// /─}"
        printf -v hdr '%s%*s%s%*s%s' "$(t deps_col_status)" 12 '' "$(t deps_col_component)" 8 '' "$(t deps_col_why)"
        log_step "$(tf deps_check_title "${selt// /, }")"
        echo -e "  ${DIM}${hdr}${NC}" >&2
        echo -e "  ${DIM}${line}${NC}" >&2
    fi

    for row in "${DEPS_TABLE[@]}"; do
        IFS='|' read -r prof name chk pkg sev why <<< "$row"
        [ -n "${name:-}" ] || continue
        case "$sel" in *" $prof "*) : ;; *) continue ;; esac
        case "$seen" in *" $name "*) continue ;; esac      # дубликат из другого профиля
        seen="${seen}${name} "

        if _deps_check_one "$chk"; then
            st="ok"
            DEPS_REASON=ok
        else
            st="$sev"
            DEPS_MISSING+=("${name}|${pkg}|${sev}")
            case "$sev" in
                crit) DEPS_N_CRIT=$((DEPS_N_CRIT + 1)) ;;
                warn) DEPS_N_WARN=$((DEPS_N_WARN + 1)) ;;
                *)    DEPS_N_OPT=$((DEPS_N_OPT + 1)) ;;
            esac
        fi
        DEPS_RESULTS+=("${name}|${DEPS_INSTALLED:-}|${DEPS_REQUIRED:-}|${DEPS_REASON:-missing}")
        [ "$quiet" = "1" ] || _deps_row "$st" "$name" "$why"
        if [ "$quiet" != 1 ] && [ "$st" != ok ] && [ -n "${DEPS_REQUIRED:-}" ]; then
            log_dim "$(tf deps_version_needed "$name" "${DEPS_INSTALLED:--}" "$DEPS_REQUIRED")"
        fi
        if [ "$quiet" != 1 ] && [ "$st" != ok ] && [ "${DEPS_REASON:-}" = capability ]; then
            log_dim "$(tf deps_capability_missing "$name")"
        fi
    done

    if [ "$quiet" != "1" ]; then
        echo -e "  ${DIM}${line}${NC}" >&2
        if [ "$DEPS_N_CRIT" -gt 0 ]; then
            log_error "$(tf deps_summary_bad "$DEPS_N_CRIT" "$DEPS_N_WARN" "$DEPS_N_OPT")"
        elif [ "$DEPS_N_WARN" -gt 0 ] || [ "$DEPS_N_OPT" -gt 0 ]; then
            log_success "$(tf deps_summary_partial "$DEPS_N_WARN" "$DEPS_N_OPT")"
        else
            log_success "$(t deps_summary_ok)"
        fi
        local plist; plist="$(_deps_pkg_list)"
        [ -n "$plist" ] && log_dim "$(tf deps_hint_install "$plist")"
    fi

    [ "$DEPS_N_CRIT" -gt 0 ] && return 1
    return 0
}

# deps_missing_list — машиночитаемо: по строке «name|pkg|severity».
# Если проверка ещё не запускалась — тихо прогоняет её (профили: последние/core).
deps_missing_list() {
    _deps_ensure_checked
    [ ${#DEPS_MISSING[@]} -gt 0 ] || return 0
    printf '%s\n' "${DEPS_MISSING[@]}"
    return 0
}

# deps_install_missing [--yes] [профиль…] — доустановка недостающих apt-пакетов.
#   0 — ставить нечего / поставили / сухой прогон;
#   1 — установка не удалась либо критичное осталось.
deps_install_missing() {
    local yes=0 profiles=() a pkgs="" err=""

    while [ $# -gt 0 ]; do
        a="${1:-}"
        case "$a" in
            --yes|-y) yes=1 ;;
            --)       : ;;
            -*)       log_warning "$(tf deps_unknown_flag "$a")" ;;
            *)        [ -n "$a" ] && profiles+=("$a") ;;
        esac
        shift
    done

    # Профили заданы явно — перепроверяем по ним; иначе используем прошлую проверку
    if [ ${#profiles[@]} -gt 0 ]; then
        _deps_quiet_check "${profiles[@]}"
    else
        _deps_quiet_check
    fi

    pkgs="$(_deps_pkg_list)"
    if [ -z "$pkgs" ]; then
        log_success "$(t deps_nothing_to_install)"
        return 0
    fi

    if [ "${GOAMNEZIA_DRY_RUN:-0}" = 1 ]; then
        log_dim "DRY: apt-get update && apt-get install --no-remove $pkgs"
        return 0
    fi

    # Без apt объясняем ручную установку; отсутствующее критичное блокирует продолжение.
    if ! command -v apt-get >/dev/null 2>&1; then
        log_warning "$(t deps_not_debian)"
        log_dim "$(tf deps_manual_hint "$pkgs")"
        [ "${DEPS_N_CRIT:-0}" = 0 ]
        return $?
    fi

    if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
        log_warning "$(t deps_need_root)"
        log_dim "$(tf deps_manual_sudo "$pkgs")"
        return 1
    fi

    if [ "$yes" != "1" ] && type confirm >/dev/null 2>&1; then
        if ! confirm "$(tf deps_confirm_install "$pkgs")"; then
            log_dim "$(t deps_install_skipped)"
            return 0
        fi
    fi

    log_step "$(tf deps_installing "$pkgs")"
    # Ждём чужой apt/dpkg-лок, если common.sh загружен (unattended-upgrades)
    if type apt_lock_wait >/dev/null 2>&1; then apt_lock_wait 120 >/dev/null 2>&1 || true; fi

    # Запасное значение — /dev/null, и удалять его НЕЛЬЗЯ: на devtmpfs файл сам
    # не вернётся, а без него от root встаёт половина системы. Отсюда правило
    # (образец — lib/website.sh, выпуск сертификата): запасной путь ставится
    # отдельным `|| err=/dev/null`, а каждое удаление спрашивает, не он ли это.
    err=$(mktemp "${TMPDIR:-/tmp}/goamnezia_deps.XXXXXXXX" 2>/dev/null) || err=/dev/null
    # Вывод apt и dpkg — в тот же файл, а не на экран: «Selecting previously unselected package…», «Setting up…» и
    # отчёт needrestart по-английски шли посреди мастера (находка NC-03 критика-новичка, 28.09.2026); на экран он
    # попадает хвостом, только если установка не удалась. Раз вывода не видно, вопросов быть не должно: dpkg
    # на изменённом конфиге спросил бы невидимо и повис, поэтому --force-confdef/--force-confold и stdin из
    # /dev/null. Повтор после обновления списков — обычное дело на свежем сервере, не тревога: строка без ⚠.
    local dpkg_opts="-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
    # Нужный пакет может быть уже установлен, но стар: свежий индекс нужен ДО первого install.
    log_dim "$(t deps_update_index)"
    if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq -o DPkg::Lock::Timeout=120 >"$err" 2>&1 </dev/null; then
        log_warning "$(t deps_update_index_failed)"
    fi
    # shellcheck disable=SC2086
    if ! DEBIAN_FRONTEND=noninteractive apt-get install --no-remove -y -qq -o DPkg::Lock::Timeout=120 $dpkg_opts $pkgs \
            >"$err" 2>&1 </dev/null; then
        log_dim "$(t deps_install_retry)"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq -o DPkg::Lock::Timeout=120 >/dev/null 2>&1 </dev/null || true
        # shellcheck disable=SC2086
        if ! DEBIAN_FRONTEND=noninteractive apt-get install --no-remove -y -qq -o DPkg::Lock::Timeout=120 $dpkg_opts $pkgs \
                >"$err" 2>&1 </dev/null; then
            log_error "$(tf deps_install_failed "$pkgs")"
            [ -s "$err" ] && tail -n 5 "$err" | sed 's/^/    /' >&2
            [ "$err" = /dev/null ] || rm -f "$err"
            return 1
        fi
    fi
    [ "$err" = /dev/null ] || rm -f "$err"
    hash -r
    log_success "$(t deps_installed_ok)"

    # Контрольная перепроверка тех же профилей
    # shellcheck disable=SC2086
    _deps_quiet_check ${DEPS_LAST_PROFILES:-core}
    if [ "${DEPS_N_CRIT:-0}" -gt 0 ]; then
        log_error "$(t deps_still_missing)"
        deps_missing_list | sed 's/^/    /' >&2
        deps_check ${DEPS_LAST_PROFILES:-core} >&2 || true
        return 1
    fi
    log_success "$(t deps_crit_ok)"
    return 0
}

# deps_report_json [профиль…] — валидный JSON в stdout для бота/панели/MCP:
# {"ok":true,"profiles":"core","crit":0,"warn":0,"opt":0,
#  "missing":[{"name","pkg","severity"}],"openssl":"3.0.13"}
deps_report_json() {
    if [ $# -gt 0 ]; then _deps_quiet_check "$@"; else _deps_ensure_checked; fi

    local ok="true" ov items="" line name pkg sev checks="" installed required reason
    [ "${DEPS_N_CRIT:-0}" -gt 0 ] && ok="false"
    ov="$(deps_openssl_version)"

    if [ ${#DEPS_MISSING[@]} -gt 0 ]; then
        for line in "${DEPS_MISSING[@]}"; do
            IFS='|' read -r name pkg sev <<< "$line"
            [ -n "$items" ] && items="${items},"
            items="${items}{\"name\":\"$(_deps_jesc "$name")\",\"pkg\":\"$(_deps_jesc "$pkg")\",\"severity\":\"$(_deps_jesc "$sev")\"}"
        done
    fi

    for line in ${DEPS_RESULTS[@]+"${DEPS_RESULTS[@]}"}; do
        IFS='|' read -r name installed required reason <<<"$line"
        [ -n "$checks" ] && checks+=,
        checks+="{\"name\":\"$(_deps_jesc "$name")\",\"installed\":\"$(_deps_jesc "$installed")\",\"required\":\"$(_deps_jesc "$required")\",\"reason\":\"$reason\"}"
    done

    printf '{"ok":%s,"profiles":"%s","crit":%s,"warn":%s,"opt":%s,"missing":[%s],"openssl":"%s","checks":[%s]}\n' \
        "$ok" "$(_deps_jesc "${DEPS_LAST_PROFILES:-core}")" \
        "${DEPS_N_CRIT:-0}" "${DEPS_N_WARN:-0}" "${DEPS_N_OPT:-0}" \
        "$items" "$(_deps_jesc "$ov")" "$checks"
    return 0
}

# ── Автономный запуск: bash lib/deps.sh [профили…] (при source не срабатывает) ──
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
    deps_check "$@"
fi
