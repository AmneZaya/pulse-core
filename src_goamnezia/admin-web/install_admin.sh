#!/bin/bash
# goAmnezia pro — автономный установщик веб-панели (по образцу goamnezia-bot/install_bot.sh).
#
# Делает всё, что нужно юниту goamnezia-admin.service: проверяет python3 (панели
# хватает stdlib, venv не нужен), копирует server.py и static/ в
# /opt/goamnezia-admin (0700), создаёт токен аварийного входа (0600, 32 байта из
# openssl rand) и учётные данные входа (логин + случайный пароль, на диске
# только хеш), пишет systemd-юнит от root с Restart=always и запускает его.
# Запускается и руками, и из SSH-меню (пункт «Панель» в install.sh зовёт
# `install_admin.sh --auto`, контракт docs/PANEL.md).
#
#   install_admin.sh            установить/обновить и показать, как открыть панель
#   install_admin.sh --auto     то же без подсказок в конце (для вызова из меню)
#   install_admin.sh --lang=en  язык сообщений (по умолчанию — язык goAmnezia из
#                               config.json / .language, иначе ru)
#   install_admin.sh --port=N   порт петлевого слушателя (по умолчанию из
#                               config.json panel.port, иначе 1985)
#   install_admin.sh --login=NAME  логин администратора панели (по умолчанию admin)
#   install_admin.sh --reset-password  выдать новый пароль и напечатать его; ничего
#                               больше не трогает — ни файлов, ни юнита
#
# Правила серии: set -uo pipefail без -e (каждая ошибка обрабатывается явно),
# PATH задан явно, ни одной видимой строки вне словаря t/tf, секреты не в логах:
# токен не печатается — показывается только команда, которой его прочитать;
# пароль печатается РОВНО ОДИН РАЗ, в терминал того, кто ставит, и больше
# нигде — на диске остаётся лишь хеш (server.py --set-password).
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
GOAMNEZIA_DIR="${GOAMNEZIA_DIR:-/opt/goamnezia}"
ADMIN_DIR="${GOAMNEZIA_ADMIN_DIR:-/opt/goamnezia-admin}"
BOT_DIR="${GOAMNEZIA_BOT_DIR:-/opt/goamnezia-bot}"
SERVICE_NAME="goamnezia-admin"
ACTION_BIN="${GOAMNEZIA_ACTION_BIN:-$GOAMNEZIA_DIR/install.sh}"
UNIT_FILE="${GOAMNEZIA_SYSTEMD_DIR:-/etc/systemd/system}/${SERVICE_NAME}.service"
AUTO=0
LANG_CODE=""
PORT=""
LOGIN=""
RESET_PASSWORD=0
NEW_PASSWORD=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; DIM='\033[2m'; NC='\033[0m'

# ── Словарь установщика ──────────────────────────────────────────────────────
# Свой, а не lib/lang/*: установщик обязан работать из любого каталога, куда его
# скопировали, без ядра goAmnezia рядом. Ключи те же в обоих языках.
declare -A I18N_RU I18N_EN
I18N_RU[title]="goAmnezia pro — установка веб-панели"
I18N_EN[title]="goAmnezia pro — web panel install"
I18N_RU[need_root]="Запустите от root или через sudo."
I18N_EN[need_root]="Run as root or with sudo."
I18N_RU[bad_option]="Неизвестный ключ: %s"
I18N_EN[bad_option]="Unknown option: %s"
I18N_RU[bad_port]="Порт должен быть числом 1–65535: %s"
I18N_EN[bad_port]="The port must be a number 1–65535: %s"
I18N_RU[bad_login]="Логин: 1–32 символа латиницы, цифр, точки, дефиса и подчёркивания: %s"
I18N_EN[bad_login]="The login must be 1–32 characters of letters, digits, dot, dash and underscore: %s"
I18N_RU[src_missing]="Файлы панели не найдены рядом с установщиком: %s"
I18N_EN[src_missing]="Panel files not found next to the installer: %s"
I18N_RU[python_install]="Ставлю python3…"
I18N_EN[python_install]="Installing python3…"
I18N_RU[python_missing]="python3 не установлен и поставить его не удалось. Установите вручную: apt install python3"
I18N_EN[python_missing]="python3 is missing and could not be installed. Install it manually: apt install python3"
I18N_RU[python_old]="Нужен Python ≥ 3.8, найден %s"
I18N_EN[python_old]="Python ≥ 3.8 is required, found %s"
I18N_RU[copying]="Копирую файлы панели в %s"
I18N_EN[copying]="Copying panel files to %s"
I18N_RU[compile_failed]="server.py не компилируется — установка остановлена"
I18N_EN[compile_failed]="server.py does not compile — install stopped"
I18N_RU[token_legacy_removed]="Старый постоянный аварийный ключ удалён: теперь ключ на час выдаёт SSH-меню"
I18N_EN[token_legacy_removed]="The old permanent emergency key is removed: a one-hour key now comes from the SSH menu"
I18N_RU[pwd_exists]="Пароль входа уже задан — оставляю"
I18N_EN[pwd_exists]="The login password is already set — keeping it"
I18N_RU[pwd_created]="Пароль входа создан (на диске только хеш, %s)"
I18N_EN[pwd_created]="Login password created (only the hash is stored, %s)"
I18N_RU[pwd_failed]="Не удалось задать пароль входа: %s"
I18N_EN[pwd_failed]="Could not set the login password: %s"
I18N_RU[pwd_title]="Вход в панель по логину и паролю"
I18N_EN[pwd_title]="Panel login with a login and a password"
I18N_RU[pwd_login]="Логин:"
I18N_EN[pwd_login]="Login:"
I18N_RU[pwd_pass]="Пароль:"
I18N_EN[pwd_pass]="Password:"
I18N_RU[pwd_once]="Пароль показан один раз и больше нигде не хранится — сохраните его."
I18N_EN[pwd_once]="The password is shown once and stored nowhere else — save it now."
I18N_RU[pwd_tunnel]="Он нужен только для входа с домена; через туннель пароль не нужен."
I18N_EN[pwd_tunnel]="It is needed only to sign in from a domain; through the tunnel no password is needed."
I18N_RU[pwd_change]="Сменить пароль: %s --reset-password (или «Настройки → Пароль панели» в самой панели)"
I18N_EN[pwd_change]="Change the password: %s --reset-password (or «Settings → Panel password» in the panel itself)"
I18N_RU[pwd_reset_done]="Пароль перевыпущен — панель принимает его сразу, перезапуск не нужен"
I18N_EN[pwd_reset_done]="Password reissued — the panel accepts it right away, no restart needed"
I18N_RU[pwd_no_server]="Панель не установлена: не найден %s"
I18N_EN[pwd_no_server]="The panel is not installed: %s not found"
I18N_RU[unit_written]="Юнит %s записан"
I18N_EN[unit_written]="Unit %s written"
I18N_RU[unit_failed]="systemd не запустил %s — смотрите journalctl -u %s"
I18N_EN[unit_failed]="systemd did not start %s — see journalctl -u %s"
I18N_RU[no_systemd]="systemctl не найден: юнит записан, но запустить службу нечем."
I18N_EN[no_systemd]="systemctl not found: the unit is written, but there is nothing to start the service with."
I18N_RU[bridge_missing]="Мост %s не найден: панель запустится, но действия будут отвечать ошибкой transport, пока не установлен goAmnezia."
I18N_EN[bridge_missing]="Bridge %s not found: the panel starts, but actions answer with a transport error until goAmnezia is installed."
I18N_RU[bot_missing]="Бот не настроен (%s): кода в Telegram не будет, вход — по логину и паролю (и без них по SSH-туннелю)."
I18N_EN[bot_missing]="The bot is not configured (%s): there will be no Telegram code; sign in with the login and password (or with neither over an SSH tunnel)."
I18N_RU[port_busy]="Порт 127.0.0.1:%s уже занят другим процессом — панель не поднимется."
I18N_EN[port_busy]="Port 127.0.0.1:%s is already taken by another process — the panel will not start."
I18N_RU[done_title]="Панель установлена и запущена"
I18N_EN[done_title]="Panel installed and running"
I18N_RU[done_check]="Проверка:"
I18N_EN[done_check]="Check:"
I18N_RU[done_logs]="Логи:"
I18N_EN[done_logs]="Logs:"
I18N_RU[done_tunnel]="Открыть по SSH-туннелю (без кода и пароля):"
I18N_EN[done_tunnel]="Open over an SSH tunnel (no code and no password needed):"
I18N_RU[done_browser]="затем в браузере"
I18N_EN[done_browser]="then in the browser"
I18N_RU[done_token]="Аварийный вход — «Настройки → Веб-панель, админы бота, ИИ-агенты → Панель и мини-апп → Аварийный ключ» в SSH"
I18N_EN[done_token]="Emergency sign-in — «Settings → Web panel, bot admins, AI agents → Panel and mini app → Emergency key» in SSH"
I18N_RU[done_domain]="С доменом: «Настройки → Режим и сайт → Панель на домене»; вход кодом из бота или логином и паролем."
I18N_EN[done_domain]="With a domain: Settings → Mode and site → Panel on the domain; sign in with a bot code or with the login and password."

detect_lang() {
    local cfg="$GOAMNEZIA_DIR/config.json" marker="$GOAMNEZIA_DIR/.language" lang=""
    [ -n "${GOAMNEZIA_LANG:-}" ] && lang="$GOAMNEZIA_LANG"
    if [ -z "$lang" ] && [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
        lang=$(jq -r '.lang // .language // empty' "$cfg" 2>/dev/null)
    fi
    if [ -z "$lang" ] && [ -f "$marker" ]; then
        lang=$(head -c 2 "$marker" 2>/dev/null | tr -d '[:space:]')
    fi
    [[ "$lang" =~ ^(ru|en)$ ]] || lang="ru"
    printf '%s' "$lang"
}

# Порт из config.json panel.port — так юнит и nginx (lib/website.sh) смотрят в одно место.
detect_port() {
    local cfg="$GOAMNEZIA_DIR/config.json" p=""
    if [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
        p=$(jq -r '.panel.port // empty' "$cfg" 2>/dev/null)
    fi
    [[ "$p" =~ ^[0-9]{1,5}$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || p="1985"
    printf '%s' "$p"
}

# Пускает ли панель по SSH-туннелю без пароля — то же правило, что у server.py (_trust_tunnel_default): окружение
# GOAMNEZIA_TRUST_TUNNEL=0|1 главнее, затем config.json panel.trust_tunnel; по умолчанию — да.
ga_tunnel_trusted() {
    local cfg="$GOAMNEZIA_DIR/config.json" v=""
    case "${GOAMNEZIA_TRUST_TUNNEL:-}" in 0) return 1 ;; 1) return 0 ;; esac
    if [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
        v=$(jq -r '.panel.trust_tunnel' "$cfg" 2>/dev/null)
    fi
    [ "$v" != false ]
}

t() {
    local key="$1" val=""
    if [ "$LANG_CODE" = "en" ]; then val="${I18N_EN[$key]:-}"; else val="${I18N_RU[$key]:-}"; fi
    printf '%s' "${val:-$key}"
}

tf() {
    local key="$1" fmt
    shift
    fmt="$(t "$key")"
    # shellcheck disable=SC2059  # формат приезжает из словаря — так и задумано
    printf "$fmt" "$@"
}

log_info()    { echo -e "  ${CYAN}ℹ${NC} $*" >&2; }
log_success() { echo -e "  ${GREEN}✓${NC} $*" >&2; }
log_warning() { echo -e "  ${YELLOW}⚠${NC} $*" >&2; }
log_error()   { echo -e "  ${RED}✗${NC} $*" >&2; }

# ── Аргументы ────────────────────────────────────────────────────────────────
for a in "$@"; do
    case "$a" in
        --auto)            AUTO=1 ;;
        --lang=*)          LANG_CODE="${a#--lang=}" ;;
        --port=*)          PORT="${a#--port=}" ;;
        --login=*)         LOGIN="${a#--login=}" ;;
        --reset-password)  RESET_PASSWORD=1 ;;
        *)
            LANG_CODE="${LANG_CODE:-$(detect_lang)}"
            log_error "$(tf bad_option "$a")"
            exit 2 ;;
    esac
done
[[ "$LANG_CODE" =~ ^(ru|en)$ ]] || LANG_CODE="$(detect_lang)"
if [ -n "$PORT" ]; then
    if ! [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        log_error "$(tf bad_port "$PORT")"
        exit 2
    fi
else
    PORT="$(detect_port)"
fi
if [ -n "$LOGIN" ] && ! [[ "$LOGIN" =~ ^[A-Za-z0-9._-]{1,32}$ ]]; then
    log_error "$(tf bad_login "$LOGIN")"
    exit 2
fi

echo ""
echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GREEN}$(t title)${NC}"
echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    log_error "$(t need_root)"
    exit 1
fi

# ── Источник файлов ──────────────────────────────────────────────────────────
# Файлы лежат рядом с установщиком (admin-web/ в эталоне /opt/goamnezia).
SRC_DIR="$SCRIPT_DIR"
for f in server.py static/index.html static/app.js static/styles.css; do
    if [ ! -f "$SRC_DIR/$f" ]; then
        log_error "$(tf src_missing "$SRC_DIR/$f")"
        exit 1
    fi
done

# ── Python ───────────────────────────────────────────────────────────────────
# Панели хватает stdlib (http.server, json, hmac): ни venv, ни pip не нужны —
# это осознанно, чтобы аварийный вход не зависел от PyPI.
ensure_python() {
    if [ -f "$GOAMNEZIA_DIR/lib/deps.sh" ]; then
        ( source "$GOAMNEZIA_DIR/lib/deps.sh"
          source "$GOAMNEZIA_DIR/lib/i18n.sh"
          load_language "${LANG_CODE:-ru}" >/dev/null 2>&1
          deps_install_missing --yes mcp )
        return $?
    fi
    python3 -c 'import sys, ssl; assert sys.version_info >= (3, 8)' >/dev/null 2>&1 && return 0
    log_info "$(t python_install)"
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q python3 >/dev/null 2>&1 || true
    fi
    python3 -c 'import sys, ssl; assert sys.version_info >= (3, 8)' >/dev/null 2>&1
}
if ! ensure_python; then
    log_error "$(t python_missing)"
    exit 1
fi
py_ver="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "0.0")"
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
    log_error "$(tf python_old "$py_ver")"
    exit 1
fi

# ── Учётные данные входа ─────────────────────────────────────────────────────
# Хеш считает сам server.py (--set-password): правило хеширования обязано быть
# ОДНО, иначе установщик и панель однажды разойдутся в параметрах и выданный
# пароль перестанет подходить. Пароль уходит в python потоком, а не аргументом:
# аргументы видны в `ps` любому пользователю машины.
SELF_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

ga_admin_server() {
    if [ -f "$ADMIN_DIR/server.py" ]; then
        printf '%s' "$ADMIN_DIR/server.py"
    elif [ -f "$SCRIPT_DIR/server.py" ]; then
        printf '%s' "$SCRIPT_DIR/server.py"
    fi
}

ga_password_is_set() {
    local server
    server="$(ga_admin_server)"
    [ -n "$server" ] || return 1
    GOAMNEZIA_DIR="$GOAMNEZIA_DIR" GOAMNEZIA_ADMIN_DIR="$ADMIN_DIR" \
        python3 "$server" --password-status 2>/dev/null | grep -q '"set": true'
}

# $1 — пароль. Возвращает 0, если хеш записан.
ga_password_set() {
    local server
    server="$(ga_admin_server)"
    [ -n "$server" ] || return 1
    printf '%s\n' "$1" | GOAMNEZIA_DIR="$GOAMNEZIA_DIR" GOAMNEZIA_ADMIN_DIR="$ADMIN_DIR" \
        python3 "$server" --set-password --login="${LOGIN:-admin}" >/dev/null 2>&1
}

# 20 знаков из букв и цифр (≈119 бит): без спецсимволов, чтобы пароль
# переживал копирование через любые терминалы и не ломался в кавычках.
ga_generate_password() {
    python3 - <<'PY'
import secrets
import string
alphabet = string.ascii_letters + string.digits
print("".join(secrets.choice(alphabet) for _ in range(20)))
PY
}

# Единственное место, где пароль виден. В журнал не уходит: log_* пишут в
# stderr, а это — stdout того, кто запустил установку своими руками.
ga_print_credentials() {
    echo ""
    echo -e "  ${GREEN}✓ $(t pwd_title)${NC}"
    echo -e "    $(t pwd_login) ${CYAN}${1}${NC}"
    echo -e "    $(t pwd_pass) ${CYAN}${2}${NC}"
    echo -e "  ${YELLOW}$(t pwd_once)${NC}"
    # Туннель пароля не спрашивает — сказать сразу, иначе пароль ищут там, где он не нужен (NC-14). Туннель без
    # доверия — строки нет: там и по туннелю нужен код или пароль.
    if ga_tunnel_trusted; then echo -e "  ${YELLOW}$(t pwd_tunnel)${NC}"; fi
    echo -e "  ${DIM}$(tf pwd_change "$SELF_PATH")${NC}"
}

# ── Только перевыпуск пароля: ни файлов, ни юнита не трогаем ──────────────────
if [ "$RESET_PASSWORD" -eq 1 ]; then
    if [ -z "$(ga_admin_server)" ]; then
        log_error "$(tf pwd_no_server "$ADMIN_DIR/server.py")"
        exit 1
    fi
    # Логин сохраняем прежний, если его не задали ключом: перевыпуск пароля не
    # повод менять имя, под которым человек привык входить.
    if [ -z "$LOGIN" ]; then
        LOGIN=$(GOAMNEZIA_DIR="$GOAMNEZIA_DIR" GOAMNEZIA_ADMIN_DIR="$ADMIN_DIR" \
            python3 "$(ga_admin_server)" --password-status 2>/dev/null \
            | sed -n 's/.*"login": "\([A-Za-z0-9._-]\{1,32\}\)".*/\1/p')
        [ -n "$LOGIN" ] || LOGIN="admin"
    fi
    NEW_PASSWORD="$(ga_generate_password)"
    if [ -z "$NEW_PASSWORD" ] || ! ga_password_set "$NEW_PASSWORD"; then
        log_error "$(tf pwd_failed "$ADMIN_DIR")"
        exit 1
    fi
    log_success "$(t pwd_reset_done)"
    ga_print_credentials "$LOGIN" "$NEW_PASSWORD"
    NEW_PASSWORD=""
    echo ""
    exit 0
fi

# ── Файлы панели ─────────────────────────────────────────────────────────────
log_info "$(tf copying "$ADMIN_DIR")"
mkdir -p "$ADMIN_DIR/static" || exit 1
# 0700: рядом лежит токен, а каталог читает только root (CONTRACT §1).
chmod 700 "$ADMIN_DIR"
# -ef: при запуске из уже установленного каталога источник и приёмник — один
# файл, cp на этом падает; сравнение по inode ловит и симлинк.
copy_one() {
    local rel="$1"
    if [ "$SRC_DIR/$rel" -ef "$ADMIN_DIR/$rel" ] 2>/dev/null; then
        return 0
    fi
    cp -f "$SRC_DIR/$rel" "$ADMIN_DIR/$rel"
}
for f in server.py static/index.html static/app.js static/styles.css; do
    copy_one "$f" || { log_error "$(tf src_missing "$f")"; exit 1; }
done
[ -f "$SRC_DIR/README.md" ] && copy_one "README.md"
chmod 755 "$ADMIN_DIR/server.py"
chmod 644 "$ADMIN_DIR"/static/* 2>/dev/null || true
rm -rf "$ADMIN_DIR/__pycache__"
# Битый server.py лучше поймать здесь, чем циклом рестартов у systemd.
if ! python3 -m py_compile "$ADMIN_DIR/server.py" 2>/dev/null; then
    log_error "$(t compile_failed)"
    exit 1
fi
rm -rf "$ADMIN_DIR/__pycache__"

# ── Аварийный ключ ───────────────────────────────────────────────────────────
# Постоянного ключа больше нет (SEC50-08, решение владельца 28.09): «на домене — только пароль или код из бота;
# аварийный ключ — только формировать в SSH полной строкой». Ключ на час выдаёт SSH-меню («Настройки → Веб-панель,
# админы бота, ИИ-агенты → Панель и мини-апп → Аварийный ключ»): файл ключа и рядом token.meta со сроком. Панель
# принимает его только по SSH-туннелю и сжигает при входе. Установщик ключ не заводит и не печатает; старый
# постоянный (файл без token.meta) панель не примет — хранить его незачем, убираем.
TOKEN_FILE="$ADMIN_DIR/token"
if [ -e "$TOKEN_FILE" ] && [ ! -e "$TOKEN_FILE.meta" ]; then
    rm -f "$TOKEN_FILE" && log_info "$(t token_legacy_removed)"
fi

# ── Логин и пароль ───────────────────────────────────────────────────────────
# Панель ставится всегда и в любом режиме, поэтому вход по паролю заводится
# тоже всегда: без бота это единственный вход с домена, с ботом — запасной.
# Существующий пароль не трогаем: он мог быть выдан человеку и записан.
PASSWORD_FILE="$ADMIN_DIR/password.json"
if ga_password_is_set; then
    chmod 600 "$PASSWORD_FILE" 2>/dev/null || true
    log_info "$(t pwd_exists)"
else
    [ -n "$LOGIN" ] || LOGIN="admin"
    NEW_PASSWORD="$(ga_generate_password)"
    if [ -z "$NEW_PASSWORD" ] || ! ga_password_set "$NEW_PASSWORD"; then
        # Не смертельно: панель поднимется, вход по туннелю и код в боте
        # работают, а пароль можно выдать потом --reset-password.
        NEW_PASSWORD=""
        log_warning "$(tf pwd_failed "$PASSWORD_FILE")"
    else
        log_success "$(tf pwd_created "$PASSWORD_FILE")"
    fi
fi

# ── systemd ──────────────────────────────────────────────────────────────────
# От root: мост install.sh управляет docker и пишет /opt/goamnezia — тот же
# размен, что у бота (docs/BOT.md §3). PATH явный: на старых установках юнит
# наследовал PATH без /usr/sbin, и мост не находил ss/iptables. Слушатель —
# только петля: наружу панель выходит через nginx по секретному пути.
mkdir -p "$(dirname "$UNIT_FILE")" 2>/dev/null || true
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=goAmnezia pro web panel (127.0.0.1:${PORT})
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$ADMIN_DIR
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=PYTHONUNBUFFERED=1
Environment=GOAMNEZIA_DIR=$GOAMNEZIA_DIR
Environment=GOAMNEZIA_ADMIN_DIR=$ADMIN_DIR
Environment=GOAMNEZIA_BOT_DIR=$BOT_DIR
Environment=GOAMNEZIA_ACTION_BIN=$ACTION_BIN
Environment=GOAMNEZIA_ACTIONS_JSON=$GOAMNEZIA_DIR/lib/actions.json
Environment=GOAMNEZIA_ADMIN_HOST=127.0.0.1
Environment=GOAMNEZIA_ADMIN_PORT=$PORT
ExecStart=/usr/bin/env python3 $ADMIN_DIR/server.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "$UNIT_FILE"
log_success "$(tf unit_written "$UNIT_FILE")"

[ -x "$ACTION_BIN" ] || log_warning "$(tf bridge_missing "$ACTION_BIN")"
[ -f "$BOT_DIR/.env" ] || log_warning "$(tf bot_missing "$BOT_DIR/.env")"

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    if ! systemctl restart "$SERVICE_NAME" 2>/dev/null; then
        systemctl start "$SERVICE_NAME" 2>/dev/null || true
    fi
    sleep 2
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        # Самая частая причина — порт занят (второй экземпляр или чужая служба).
        if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q "127.0.0.1:${PORT} "; then
            log_warning "$(tf port_busy "$PORT")"
        fi
        log_error "$(tf unit_failed "$SERVICE_NAME" "$SERVICE_NAME")"
        exit 1
    fi
else
    log_warning "$(t no_systemd)"
fi

echo ""
echo -e "  ${GREEN}✓ $(t done_title)${NC}"
echo ""
echo -e "  $(t done_check)  ${CYAN}systemctl status $SERVICE_NAME${NC}"
echo -e "  $(t done_logs)  ${CYAN}journalctl -u $SERVICE_NAME -f${NC}"
# Пароль печатается и при --auto: из меню и мастера установщик зовут именно
# так, и промолчи он там — выданный пароль не увидел бы никто и никогда.
if [ -n "$NEW_PASSWORD" ]; then
    ga_print_credentials "${LOGIN:-admin}" "$NEW_PASSWORD"
    NEW_PASSWORD=""
elif [ "$AUTO" -ne 1 ]; then
    echo -e "  ${DIM}$(tf pwd_change "$SELF_PATH")${NC}"
fi
if [ "$AUTO" -ne 1 ]; then
    echo ""
    echo -e "  $(t done_tunnel)"
    echo -e "    ${CYAN}ssh -L ${PORT}:127.0.0.1:${PORT} root@SERVER_IP${NC}   $(t done_browser)   ${CYAN}http://127.0.0.1:${PORT}/${NC}"
    echo -e "  $(t done_token)"
    echo -e "  ${DIM}$(t done_domain)${NC}"
fi
echo ""
exit 0
