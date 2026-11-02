#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# goAmnezia pro — lib/agents.sh: доступы агентов к MCP по HTTP (PLAN §6.10, CONTRACT §5.1)
#
# Задача владельца: агент (Claude Code, облачная сессия) подключается к серверу
# без SSH по адресу, который работает как ключ; у каждого агента свой ключ; все
# ключи видны в скрипте и отзываются мгновенно.
#
# Модель. Доступ (grant) — запись в $GOAMNEZIA_DIR/agents.json (0600):
#   {id: "a-7f3c", label, secret (43 символа base64url = 32 случайных байта),
#    token (ещё 43 символа), require_token, mode: static|rolling, key_hash,
#    compromised, scope: read|write|admin, enabled, created, expires, port,
#    allow_ips[], pin_ip, pinned_ip, known_ips[], last_used, last_ip, calls}
#
# Два доказательства, а не одно. Секретный путь — то, что видно: он попадает в
# снимок экрана со ссылкой, в пересылку, в историю браузера, в журнал
# промежуточного прокси, в конфиг агента на чужой машине и в бэкап этого
# конфига. Токен передаётся заголовком Authorization: Bearer <token> и ни в одно
# из этих мест не попадает — поэтому утёкший адрес сам по себе бесполезен.
# У новых доступов require_token=true; у выданных раньше поля нет, умолчание
# false («слабый доступ, только путь»), и они продолжают работать — усиление
# делает человек действием agents_harden. Срок по умолчанию — 30 дней
# (GA_AGENTS_DEFAULT_DAYS); days=0 остаётся явным выбором «бессрочно».
# Срок ПРОДЛЕВАЕТСЯ действием agents_extend, не трогая ни секрет, ни токен:
# истечение — календарь, а не компрометация, и перевыпуск ради него означал бы
# остановку работы агента и перенастройку его клиента. Отсчёт идёт от текущей
# даты окончания, у истёкшего и бессрочного — от сегодня.
# pin_ip — привязка к адресу при первом использовании: сервер запоминает
# pinned_ip и дальше принимает только его; снимается agents_pin <id> off.
#
# Два вида доступа (docs/MCP_ROTATION.md §1 в редакции §11).
#   static  — постоянный токен в заголовке. Умолчание: с ним работает любой
#             клиент MCP без всяких переходников.
#   rolling — одноразовый ключ. Каждый успешный запрос сжигает пришедший ключ и
#             выдаёт следующий заголовком X-Ga-Next-Key. Копия доступа на чужой
#             машине неизбежно приходит с ключом, который сервер уже выдавал, —
#             и это ловится: доступ замораживается (compromised), владелец
#             получает карточку с двумя временами и двумя адресами. Здесь модуль
#             делает только выдачу: генерирует ПЕРВЫЙ ключ (печатается один раз,
#             как токен) и кладёт в запись его отпечаток key_hash. Сам ключ на
#             сервере не хранится, цепочку дальше ведёт server.py в отдельном
#             файле $GOAMNEZIA_DIR/state/agents/<id>.key.
#             Правило «один доступ — один клиент» обязательно: второй клиент на
#             том же доступе вращает ту же цепочку и выглядит клоном (§11.2).
#             Пока нет переходника goamnezia-connect, rolling выбирается явно —
#             обычный клиент MCP заголовок между запросами менять не умеет.
#
# Ключ = секретный путь. Адрес агента зависит от того, на чём стоит сайт, а не
# от названия режима (docs/DEFECTS.md §1.1): сайт на домене с Let's Encrypt даёт
# https://<домен>/a-<secret>/mcp, сайт на запасном самоподписанном сертификате —
# https://<IP>/a-<secret>/mcp (рядом отдаётся отпечаток SHA-256), а lite с
# отдельным TLS-портом — https://<IP>:<порт>/a-<secret>/mcp (персональный порт
# доступа — тоже так). Сервер
# goamnezia-mcp/server.py --http читает agents.json при каждом запросе, поэтому
# «Выключить», «Удалить» и «Перевыпустить» действуют на следующий же вызов —
# ни nginx, ни юнит перезапускать не нужно. Исключение — персональные порты:
# слушатели открываются при старте, и смена набора портов перезапускает юнит.
#
# Где живёт транспорт по режимам (таблица PLAN §6.10):
#   pro       — nginx на домене, location ~ ^/a-[A-Za-z0-9_-]{43}/ → 127.0.0.1:1986
#               (site.mcp_location, website_mcp_location_on);
#   lite_site — тот же nginx на IP с самоподписанным сертификатом сайта;
#   lite      — nginx нет: без --port ответ needs_site; с портом — собственный
#               TLS-слушатель server.py --bind 0.0.0.0 --port N --tls на том же
#               самоподписанном сертификате (mcp.public_port).
# Во всех режимах основной слушатель — 127.0.0.1:${mcp.http_port} (1986), TLS
# терминирует nginx; в lite с портом основной слушатель сам публичный с TLS.
# Смена режима из lib/website.sh зовёт _agents_unit_reconcile_locked: юнит
# пересобирается под новый режим, иначе после pro → lite он слушал бы петлю,
# на которую больше некому проксировать.
#
# Правила модуля (контракт §0):
#   • stdout — только JSON у функций, где это сказано; всё для человека — stderr;
#   • ни одной видимой строки вне t/tf — словарь lib/lang/<lang>.d/agents.sh;
#   • мутации — под ga_with_config_lock (пара fn / _fn_locked), коды через ga_err:
#     agent_not_found, invalid_agent_id, invalid_label, invalid_scope, invalid_days,
#     invalid_ips, invalid_port, invalid_state, port_busy, needs_site, agents_corrupt,
#     write_failed, unit_failed, openssl_missing / no_server_ip (из website.sh);
#   • секрет и токен пишутся только в agents.json и печатаются только функциями
#     agents_add / agents_show / agents_rotate / agents_harden (действия помечены
#     secret: true); в аудит и логи — только id;
#   • GOAMNEZIA_DRY_RUN=1: systemctl, ufw/iptables печатаются как «DRY: …»; файл
#     юнита пишется в GOAMNEZIA_SYSTEMD_DIR, если стенд его задал; nginx-location
#     — через lib/website.sh (тот же dry-run). Так модуль целиком проверяется на
#     macOS (tests/test_agents_dryrun.sh, раздел 13 tests/test_actions_dryrun.sh).
# ══════════════════════════════════════════════════════════════════════════════

GA_AGENTS_UNIT="goamnezia-mcp-http.service"
GA_AGENTS_SCOPES="read write admin"
# Умолчание — read: наименьшие права (docs/MCP_ROTATION.md §5). Уровень write не
# только меняет настройки, но и ВЫДАЁТ приватные ключи клиентов (user_get_key),
# а украденный доступ успевает ровно один запрос — и этим запросом не должен
# быть чужой конфиг. Кому нужно больше, выбирает уровень явно и читает, что он
# отдаёт: наблюдение агенту нужно почти всегда, выдача ключей — почти никогда.
GA_AGENTS_DEFAULT_SCOPE="read"
# connect — одноразовый ключ через переходник goamnezia-connect: код привязки вместо
# секрета в конфигурации клиента, плавающий путь, ключ в TPM агента (MCP_ROTATION §2–§7).
GA_AGENTS_MODES="static rolling connect"
# Умолчание — static: rolling без переходника требует клиента, который сам
# хранит ключ и подставляет его в заголовок. Тихо выдать такой доступ значило бы
# выдать нерабочий.
GA_AGENTS_DEFAULT_MODE="static"
GA_AGENTS_MAX_DAYS=3650
# Срок по умолчанию. Бессрочный доступ живёт ровно столько, сколько живёт утечка,
# о которой никто не узнал; месяц — обозримый срок, за который человек либо
# продлит доступ осознанно, либо забудет о нём, и тот погаснет сам.
GA_AGENTS_DEFAULT_DAYS=30
GA_AGENTS_ID_RE='^a-[a-f0-9]{4,8}$'
GA_AGENTS_SECRET_RE='^[A-Za-z0-9_-]{43}$'
GA_AGENTS_HASH_RE='^[a-f0-9]{64}$'
# Префикс подсети: 1..32 без ведущего нуля — тот же образец, что у ip_list в
# lib/actions.json. Нуля здесь нет нарочно: `203.0.113.10/0` читается как «только
# мой адрес», а означает «любой», то есть опечатка в один символ молча снимает
# ограничение целиком. Адрес проверяет _valid_ip (lib/common.sh), своей копии
# регулярки на адрес здесь больше нет.
GA_AGENTS_PREFIX_RE='^([1-9]|[12][0-9]|3[0-2])$'
# Порт публичного слушателя и персональных портов: непривилегированный диапазон,
# как у профилей AmneziaWG (случайный из низкого, если человек не назвал свой).
GA_AGENTS_PORT_MIN=1024

# ── Запасные помощники: модуль подключают и без lib/docker.sh / lib/website.sh ──
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
# Аудит теми же именами, что у действий моста; секрет в подробности не попадает.
ga_agents_audit() {
    type ga_audit >/dev/null 2>&1 || return 0
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "$1" "${2:-}"
}

# ── Пути: функциями, а не константами при source (стенды меняют GOAMNEZIA_* позже) ──
ga_agents_file()        { printf '%s' "${GOAMNEZIA_AGENTS_JSON:-$GOAMNEZIA_DIR/agents.json}"; }
ga_agents_systemd_dir() { printf '%s' "${GOAMNEZIA_SYSTEMD_DIR:-/etc/systemd/system}"; }
ga_agents_unit_path()   { printf '%s/%s' "$(ga_agents_systemd_dir)" "$GA_AGENTS_UNIT"; }
# Рабочая копия сервера (install.sh обновляет её из эталона), а не эталон:
# юнит должен переживать обновление файлов эталона на лету. Но рабочую копию
# создаёт auto_update_components — то есть ИНТЕРАКТИВНЫЙ запуск install.sh;
# установка целиком через мост (бот, панель, MCP, CI) её не создаёт, и юнит
# падал в цикле «can't open file '/opt/goamnezia-mcp/server.py'», пока
# mcp-http-on рапортовал успех. Нет рабочей копии — берём эталон: гайд-ресурс
# сервер ищет рядом с собой, и в эталоне он лежит там же.
ga_agents_server_py() {
    local work="${MCP_DIR:-/opt/goamnezia-mcp}/server.py"
    local ref="${GOAMNEZIA_DIR:-/opt/goamnezia}/goamnezia-mcp/server.py"
    if [ ! -f "$work" ] && [ -f "$ref" ]; then printf '%s' "$ref"; return 0; fi
    printf '%s' "$work"
}
# Состояние одноразовых цепочек: отдельный файл на доступ, каталог ПОСТОЯННЫЙ
# (не /run — тот чистится при перезагрузке, и цепочка обнулялась бы после
# каждого включения сервера, объявляя честного агента клоном). Тот же путь
# знает server.py через GOAMNEZIA_STATE_DIR.
ga_agents_state_dir()  { printf '%s/agents' "${GOAMNEZIA_STATE_DIR:-$GOAMNEZIA_DIR/state}"; }
ga_agents_state_file() { printf '%s/%s.key' "$(ga_agents_state_dir)" "$1"; }
# Обрыв цепочки при перевыпуске и удалении. Не критично, если не удалось:
# server.py сверяет origin состояния с key_hash записи и сам отбрасывает чужое.
_agents_state_drop() { rm -f "$(ga_agents_state_file "$1")" 2>/dev/null || true; }
# Отметка «заморозить не удалось» (L-08): сервер MCP увидел клон ключа, а agents.json не записался — доступ жив.
# Пишет её server.py (ChainStore.mark_freeze_failed) рядом с цепочкой; снимают удачная заморозка, перевыпуск,
# выключение и отзыв — ответы владельца на карточку.
ga_agents_freeze_failed_file() { printf '%s/%s.freeze_failed' "$(ga_agents_state_dir)" "$1"; }
_agents_freeze_failed_drop() { rm -f "$(ga_agents_freeze_failed_file "$1")" 2>/dev/null || true; }
# Все отметки одним объектом {id: {at, ip}} для agents_list; испорченная отметка пропускается, а не роняет список.
_agents_freeze_failed_json() {
    local dir f out="{}" one
    dir=$(ga_agents_state_dir)
    for f in "$dir"/*.freeze_failed; do
        [ -f "$f" ] || continue
        one=$(jq -c 'if type == "object" and ((.id // "") | test("^a-[a-f0-9]{4,8}$"))
                     then {(.id): {at: (.at // "" | tostring), ip: (.ip // "" | tostring)}} else {} end' "$f" 2>/dev/null) \
            || continue
        out=$(jq -c --argjson o "${one:-{\}}" '. + $o' <<<"$out" 2>/dev/null) || out="{}"
    done
    printf '%s' "$out"
}
ga_agents_fs_systemd_ok() { ! ga_dry || [ -n "${GOAMNEZIA_SYSTEMD_DIR:-}" ]; }
# Системные команды (systemctl): в dry-run печатаются и считаются выполненными.
ga_agents_run() {
    if ga_dry; then ga_dry_echo "$*"; return 0; fi
    "$@"
}
ga_agents_run_quiet() {
    if ga_dry; then ga_dry_echo "$*"; return 0; fi
    "$@" >/dev/null 2>&1
}

# ── Режим, адрес сервера, сертификат — через lib/website.sh, если он подключён ──
ga_agents_mode() {
    local m
    if type ga_site_mode >/dev/null 2>&1; then ga_site_mode; return 0; fi
    m=$(ga_config_get .mode 2>/dev/null) || m=""
    case "$m" in pro|lite_site) printf '%s' "$m" ;; *) printf 'lite' ;; esac
}
ga_agents_server_ip() {
    local ip=""
    if type ga_site_server_ip >/dev/null 2>&1; then
        ip=$(ga_site_server_ip)
    else
        ip=$(ga_config_get .server_ip 2>/dev/null) || ip=""
    fi
    printf '%s' "$ip"
}
ga_agents_domain() { ga_config_get .domain 2>/dev/null || printf ''; }
# Живёт ли сайт на домене с настоящим сертификатом. Вопрос НЕ к названию режима:
# lite_site по уточнённому договору — это тот же домен и тот же Let's Encrypt,
# что в pro, и адрес вида https://<IP> с отпечатком запасного самоподписанного
# там просто не работает — nginx стоит на server_name <домен> (docs/DEFECTS.md
# §1.1). Спрашиваем сайт, а не режим.
ga_agents_domain_ready() {
    if type ga_site_domain_ready >/dev/null 2>&1; then ga_site_domain_ready; return $?; fi
    [ "$(ga_config_get .site.cert 2>/dev/null)" = letsencrypt ] && [ -n "$(ga_agents_domain)" ]
}
ga_agents_fingerprint() {
    type website_cert_fingerprint >/dev/null 2>&1 || { printf ''; return 0; }
    website_cert_fingerprint 2>/dev/null || printf ''
}
ga_agents_ss_crt() { if type ga_site_ss_crt >/dev/null 2>&1; then ga_site_ss_crt; else printf '%s/tls/site.crt' "$GOAMNEZIA_DIR"; fi; }
ga_agents_ss_key() { if type ga_site_ss_key >/dev/null 2>&1; then ga_site_ss_key; else printf '%s/tls/site.key' "$GOAMNEZIA_DIR"; fi; }
# Самоподписанный сертификат нужен всякому публичному TLS-слушателю (lite с
# портом, персональные порты). Живой не перевыпускается — его отпечаток закреплён
# у агентов (website_selfsigned_ensure).
ga_agents_cert_ensure() {
    if type website_selfsigned_ensure >/dev/null 2>&1; then
        website_selfsigned_ensure || return 1
    elif [ ! -f "$(ga_agents_ss_crt)" ]; then
        ga_err module_missing "$(tf module_missing website_selfsigned_ensure)"
        return 1
    fi
    return 0
}

# ── Настройки транспорта из config.json ───────────────────────────────────────
ga_agents_http_enabled() { [ "$(ga_config_get .mcp.http_enabled 2>/dev/null)" = "true" ]; }
ga_agents_loopback_port() {
    local p
    p=$(ga_config_get .mcp.http_port 2>/dev/null) || p=""
    [[ "$p" =~ ^[0-9]{2,5}$ ]] || p="${MCP_HTTP_PORT:-1986}"
    printf '%s' "$p"
}
# Публичный TLS-порт Lite (0/пусто — нет)
ga_agents_public_port() {
    local p
    p=$(ga_config_get .mcp.public_port 2>/dev/null) || p=""
    if [[ "$p" =~ ^[0-9]{1,5}$ ]] && [ "$p" -gt 0 ]; then printf '%s' "$p"; fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  agents.json: чтение и атомарная запись
# ══════════════════════════════════════════════════════════════════════════════
# agents_read — весь файл в stdout; нет файла → пустой скелет (как ga_users_read).
# Битый файл — ошибка agents_corrupt: молча подсунуть пустой список нельзя,
# следующая запись затёрла бы настоящие доступы.
agents_read() {
    local f out
    f=$(ga_agents_file)
    if [ -f "$f" ] && command -v jq >/dev/null 2>&1; then
        out=$(jq -c '.' "$f" 2>/dev/null)
        if [ -n "$out" ] && printf '%s' "$out" | jq -e '(.agents|type) == "array"' >/dev/null 2>&1; then
            printf '%s\n' "$out"
            return 0
        fi
        ga_err agents_corrupt "$(tf agents_err_corrupt "$f")"
        return 1
    fi
    printf '%s\n' '{"schema":1,"agents":[]}'
    return 0
}
ga_agents_json() {
    local j
    j=$(agents_read 2>/dev/null)
    [ -n "$j" ] || j='{"schema":1,"agents":[]}'
    printf '%s' "$j"
}
# stdin JSON → agents.json атомарно (tmp рядом + mv, 0600 до mv — _ga_write_json)
_agents_write_locked() {
    _ga_write_json "$(ga_agents_file)" || { ga_err write_failed "$(tf agents_err_write "$(ga_agents_file)")"; return 1; }
    chmod 600 "$(ga_agents_file)" 2>/dev/null || true
    return 0
}
# stdout: запись доступа (с секретом) или пусто
ga_agents_get() { ga_agents_json | jq -c --arg id "$1" '.agents[]? | select(.id == $id)' 2>/dev/null; }
agents_exists() { [ -n "$(ga_agents_get "$1")" ]; }
ga_agents_check_id() {
    [[ "${1:-}" =~ $GA_AGENTS_ID_RE ]] && return 0
    ga_err invalid_agent_id "$(tf agents_err_id "${1:-}")" 2
    return 2
}
# Идентификатор корректен, файл читается, запись есть. Битый файл — своя
# ошибка, а не «не найден»: человек должен понять, что чинить.
ga_agents_require() {
    ga_agents_check_id "$1" || return 2
    agents_read >/dev/null || return 1
    agents_exists "$1" && return 0
    ga_err agent_not_found "$(tf agents_err_not_found "$1")"
    return 1
}
# Порты, занятые доступами (персональные), через пробел
ga_agents_ports_in_use() { ga_agents_json | jq -r '[.agents[]? | .port // 0 | select(. > 0)] | unique | .[]' 2>/dev/null | tr '\n' ' '; }
ga_agents_has_port_grants() { [ -n "$(ga_agents_ports_in_use | tr -d ' ')" ]; }

# ── Секрет, токен и идентификатор ─────────────────────────────────────────────
# 32 случайных байта в base64url без «=» = 43 символа. Тем же генератором делается
# и токен второго фактора: он не слабее секрета пути, просто едет заголовком, а не
# адресом — и потому не оседает в истории браузера и журналах прокси (PLAN §6.10).
ga_agents_new_secret() {
    local s=""
    s=$(openssl rand -base64 32 2>/dev/null | tr '+/' '-_' | tr -d '=\n')
    if ! [[ "$s" =~ $GA_AGENTS_SECRET_RE ]]; then
        s=$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')
    fi
    [[ "$s" =~ $GA_AGENTS_SECRET_RE ]] || return 1
    printf '%s' "$s"
}
# Отпечаток ключа цепочки: в agents.json ложится он, а не сам ключ. Ключ
# печатается один раз при выдаче — как токен панели: сервер сверяет отпечаток, и
# потерянный ключ восстановить нельзя, только перевыпустить.
ga_agents_key_hash() {
    local k="${1:-}" h=""
    if command -v openssl >/dev/null 2>&1; then
        h=$(printf '%s' "$k" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')
    fi
    if ! [[ "$h" =~ $GA_AGENTS_HASH_RE ]] && command -v sha256sum >/dev/null 2>&1; then
        h=$(printf '%s' "$k" | sha256sum 2>/dev/null | awk '{print $1}')
    fi
    if ! [[ "$h" =~ $GA_AGENTS_HASH_RE ]] && command -v shasum >/dev/null 2>&1; then
        h=$(printf '%s' "$k" | shasum -a 256 2>/dev/null | awk '{print $1}')
    fi
    [[ "$h" =~ $GA_AGENTS_HASH_RE ]] || return 1
    printf '%s' "$h"
}
# Код привязки переходника (MCP_ROTATION §7): GA-XXXXX-XXXXX-XXXXX-XXXXX из алфавита без
# похожих знаков (нет I, L, O, U, 0, 1): его читают с экрана и набирают руками. 20 знаков
# по ~4,9 бита — около 98 бит; живёт 10 минут и сгорает с первой привязкой.
GA_AGENTS_ENROLL_TTL=600
ga_agents_enroll_code() {
    local alphabet="ABCDEFGHJKMNPQRSTVWXYZ23456789" out="" b
    for b in $(od -An -N80 -tu1 /dev/urandom 2>/dev/null); do
        [ "$b" -lt 240 ] || continue          # 240 = 8 × 30: без перекоса по модулю
        out="${out}${alphabet:$(( b % 30 )):1}"
        [ "${#out}" -ge 20 ] && break
    done
    [ "${#out}" -eq 20 ] || return 1
    printf 'GA-%s-%s-%s-%s' "${out:0:5}" "${out:5:5}" "${out:10:5}" "${out:15:5}"
}
# Отпечаток кода — путь привязки. Та же формула, что у goamnezia-connect и сервера: код
# без пробелов и дефисов, заглавными; sha256("goamnezia-enroll|"+код) в base64url. Код
# уходит в openssl и python через stdin: аргументы процесса видит любой локальный пользователь.
ga_agents_enroll_path() {
    local norm p=""
    norm=$(printf '%s' "${1:-}" | tr -d ' \t-' | tr '[:lower:]' '[:upper:]')
    [ -n "$norm" ] || return 1
    if command -v openssl >/dev/null 2>&1; then
        p=$(printf '%s' "goamnezia-enroll|$norm" | openssl dgst -sha256 -binary 2>/dev/null \
            | base64 | tr '+/' '-_' | tr -d '=\n' | cut -c1-43)
    fi
    if ! [[ "$p" =~ $GA_AGENTS_SECRET_RE ]] && command -v python3 >/dev/null 2>&1; then
        p=$(printf '%s' "$norm" | python3 -c 'import sys,hashlib,base64
c=sys.stdin.read().encode()
print(base64.urlsafe_b64encode(hashlib.sha256(b"goamnezia-enroll|"+c).digest()).decode().rstrip("=")[:43])' 2>/dev/null)
    fi
    [[ "$p" =~ $GA_AGENTS_SECRET_RE ]] || return 1
    printf '%s' "$p"
}
# Момент через N секунд в ISO UTC (GNU date и BSD date)
ga_agents_iso_in_seconds() {
    local at=$(( $(date +%s) + ${1:-0} ))
    date -u -d "@$at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$at" +%Y-%m-%dT%H:%M:%SZ
}
# a-<4 hex>; при совпадении — длиннее (до 8), чтобы имя оставалось коротким для чата
ga_agents_new_id() {
    local n id
    for n in 4 6 8; do
        id="a-$(generate_hex "$n")"
        [[ "$id" =~ $GA_AGENTS_ID_RE ]] || continue
        agents_exists "$id" && continue
        printf '%s' "$id"
        return 0
    done
    return 1
}
# Срок: дни от сегодня → ISO-8601 UTC; 0 → пусто (бессрочно). GNU date и BSD date.
ga_agents_iso_in_days() {
    local days="${1:-0}" epoch
    [[ "$days" =~ ^[0-9]+$ ]] && [ "$days" -gt 0 ] || { printf ''; return 0; }
    epoch=$(( $(date -u +%s) + days * 86400 ))
    date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}
# ISO-8601 UTC → epoch; неразбираемая дата и пусто → пусто (rc 1). GNU и BSD date.
ga_agents_iso_epoch() {
    local iso="${1:-}" e=""
    [ -n "$iso" ] || { printf ''; return 1; }
    e=$(date -u -d "$iso" +%s 2>/dev/null) \
        || e=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null) || e=""
    [[ "$e" =~ ^[0-9]+$ ]] || { printf ''; return 1; }
    printf '%s' "$e"
}
# Продление: дни ОТ ТЕКУЩЕЙ даты окончания, а не «заново от сегодня». Иначе
# продление действующего доступа на 30 дней укорачивало бы его, если до конца
# оставалось больше. Истёкший и бессрочный считаются от «сейчас».
ga_agents_iso_extend() {
    local iso="${1:-}" days="${2:-0}" now base epoch
    [[ "$days" =~ ^[0-9]+$ ]] && [ "$days" -gt 0 ] || { printf ''; return 0; }
    now=$(date -u +%s)
    base=$(ga_agents_iso_epoch "$iso") || base=""
    [ -n "$base" ] && [ "$base" -gt "$now" ] 2>/dev/null || base="$now"
    epoch=$(( base + days * 86400 ))
    date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# ── Проверки входа ────────────────────────────────────────────────────────────
# Длина — в символах при любой локали (ga_char_len): бот, панель и MCP зовут мост без LANG (L1-15 / TAIL-8).
ga_agents_label_valid() {
    local n
    [ -n "${1:-}" ] || return 1
    if type ga_char_len >/dev/null 2>&1; then n=$(ga_char_len "$1"); else n=${#1}; fi
    [ "$n" -le 48 ] && [[ "$1" != *[[:cntrl:]]* ]]
}
ga_agents_scope_valid() { case "${1:-}" in read|write|admin) return 0 ;; *) return 1 ;; esac; }
ga_agents_mode_valid() { case "${1:-}" in static|rolling|connect) return 0 ;; *) return 1 ;; esac; }
# on/off из моста и меню → true/false для jq; пусто = off (умолчание привязки)
ga_agents_onoff_json() {
    case "${1:-}" in
        on|true|1|yes)  printf 'true' ;;
        ""|off|false|0|no) printf 'false' ;;
        *) return 1 ;;
    esac
}
# Список IPv4/подсетей через запятую. Адрес — единственной проверкой продукта
# _valid_ip (§0.8 договора), а не своей регуляркой «по виду»: та пропускала
# 010.0.0.1, потому что `[ 010 -le 255 ]` читает ведущий ноль как восьмеричное.
# Запись доезжала до agents.json, а там её разбирает python ipaddress, который на
# ведущем нуле падает, — и агент оказывался заперт собственным белым списком, ни
# разу об этом не услышав. Правило обязано совпадать с образцом ip_list в
# lib/actions.json, а не быть слабее его.
ga_agents_ips_valid() {
    local list="${1:-}" item
    local -a parts=()
    [ -n "$list" ] || return 0
    IFS=',' read -ra parts <<< "$list"
    for item in "${parts[@]}"; do
        item="${item// /}"
        _valid_ip "${item%%/*}" || return 1
        if [[ "$item" == */* ]]; then
            [[ "${item#*/}" =~ $GA_AGENTS_PREFIX_RE ]] || return 1
        fi
    done
    return 0
}
ga_agents_ips_json() {
    local list="${1:-}"
    [ -n "$list" ] || { printf '[]'; return 0; }
    printf '%s' "$list" | jq -Rc 'split(",") | map(gsub(" "; "")) | map(select(length > 0))' 2>/dev/null || printf '[]'
}
# TCP-порт свободен? docker_port_free (dry-run → свободен), иначе ss напрямую. Без lib/docker.sh в сухом
# прогоне настоящий ss не спрашиваем (TAIL-9), как и docker_port_free: слушатели — из сохранённого вывода
# (GOAMNEZIA_SS_FIXTURE_TCP / GOAMNEZIA_SS_FIXTURE, ga_pf_listeners из preflight.sh), нет его — порт свободен.
ga_agents_port_free() {
    local port="$1" listeners
    if type docker_port_free >/dev/null 2>&1; then docker_port_free "$port" tcp; return $?; fi
    if ga_dry; then
        type ga_pf_listeners >/dev/null 2>&1 || { ga_dry_echo "ss -ltn | grep :$port"; return 0; }
        listeners=$(ga_pf_listeners tcp) || return 0
        ! printf '%s\n' "$listeners" | awk -F'|' -v p="$port" '$2 == p { found = 1 } END { exit !found }'
        return
    fi
    command -v ss >/dev/null 2>&1 || return 0
    ! grep -qE "[:.]${port}[[:space:]]" <<<"$(ss -ltn 2>/dev/null)"
}
# Порт годится для публичного слушателя или персонального порта доступа:
# число ≥ 1024, не порт панели/петли MCP/сайта, не занят другим доступом, свободен.
# $2 = id доступа, чей прежний порт не считается занятым (перевыпуск того же),
# или «public» — проверяем публичный порт транспорта.
ga_agents_check_port() {
    local port="${1:-}" own="${2:-}" used p lp pp
    if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || [ "$port" -lt "$GA_AGENTS_PORT_MIN" ] || [ "$port" -gt 65535 ]; then
        ga_err invalid_port "$(tf agents_err_port "$port")" 2
        return 2
    fi
    lp=$(ga_agents_loopback_port); pp=$(ga_agents_public_port)
    if [ "$port" = "$lp" ] || [ "$port" = "${ADMIN_PORT:-1985}" ] || [ "$port" = 443 ] || [ "$port" = 80 ] || [ "$port" = 22 ]; then
        ga_err port_busy "$(tf agents_err_port_reserved "$port")"
        return 1
    fi
    if [ -n "$pp" ] && [ "$port" = "$pp" ] && [ "$own" != "public" ]; then
        ga_err port_busy "$(tf agents_err_port_reserved "$port")"
        return 1
    fi
    used=$(ga_agents_json | jq -r --arg own "$own" '.agents[]? | select(.id != $own) | .port // 0 | select(. > 0)' 2>/dev/null)
    for p in $used; do
        if [ "$p" = "$port" ]; then ga_err port_busy "$(tf agents_err_port_grant "$port")"; return 1; fi
    done
    # Порт, который уже слушает наш же юнит (повтор mcp-http-on с тем же портом), — не конфликт
    if [ "$own" = "public" ] && [ "$port" = "$pp" ]; then return 0; fi
    if ! ga_agents_port_free "$port"; then
        ga_err port_busy "$(tf agents_err_port_busy "$port")"
        return 1
    fi
    return 0
}
# Случайный свободный порт из НИЗКОГО диапазона (GA_PORT_LOW_MIN..MAX, 1024–9999)
# — тот же, что предлагает мастер для профилей. Прежние 30000–49999 выше десяти
# тысяч: решение владельца — предлагать порт ближе к трём-пяти тысячам, потому что
# высокие номера у части провайдеров и корпоративных сетей режутся целым блоком, и
# человек получал доступ, который у него же и не открывается. Общеизвестные порты
# пропускаем: занять 3128 или 8080 значит подраться с прокси на том же сервере.
ga_agents_random_port() {
    local p="" i lo="${GA_PORT_LOW_MIN:-1024}" hi="${GA_PORT_LOW_MAX:-9999}"
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if type ga_port_random >/dev/null 2>&1; then p=$(ga_port_random "$lo" "$hi"); else p=""; fi
        [ -n "$p" ] || p=$(( lo + ((RANDOM << 15 | RANDOM) % (hi - lo + 1)) ))
        type ga_port_wellknown >/dev/null 2>&1 && ga_port_wellknown "$p" && continue
        ga_agents_check_port "$p" public >/dev/null 2>&1 && { printf '%s' "$p"; return 0; }
    done
    return 1
}

# ══════════════════════════════════════════════════════════════════════════════
#  Адрес доступа по режиму
# ══════════════════════════════════════════════════════════════════════════════
# ga_agents_endpoint <порт доступа|0> — stdout JSON {base, via, cert_fingerprint_sha256,
# reachable}: где сейчас живёт адрес. via: domain (Pro, nginx), ip (Lite + сайт,
# nginx на IP), port (Lite, публичный TLS-порт), grant_port (персональный порт).
# В lite без единого порта — код needs_site: адреса попросту нет, и выдумывать
# его нельзя (человек скопирует агенту нерабочую ссылку).
ga_agents_endpoint() {
    local gport="${1:-0}" mode ip domain fp="" base="" via="" reach=false pp
    mode=$(ga_agents_mode)
    ip=$(ga_agents_server_ip)
    if [[ "$gport" =~ ^[0-9]+$ ]] && [ "$gport" -gt 0 ]; then
        [ -n "$ip" ] || { ga_err no_server_ip "$(t agents_err_no_ip)"; return 1; }
        base="https://${ip}:${gport}"; via="grant_port"; fp=$(ga_agents_fingerprint)
        ga_agents_http_enabled && reach=true
    else
        case "$mode" in
            pro|lite_site)
                # Домен и настоящий сертификат — вопрос к сайту, а не к названию
                # режима: в lite_site на домене nginx отвечает по server_name
                # <домен>, и ссылка на IP с отпечатком запасного сертификата
                # нерабочая (docs/DEFECTS.md §1.1).
                domain=$(ga_agents_domain)
                if ga_agents_domain_ready; then
                    base="https://${domain}"; via="domain"
                elif [ -n "$ip" ]; then
                    base="https://${ip}"; via="ip"; fp=$(ga_agents_fingerprint)
                elif [ "$mode" = pro ]; then
                    ga_err no_domain "$(t agents_err_no_domain)"; return 1
                else
                    ga_err no_server_ip "$(t agents_err_no_ip)"; return 1
                fi
                ;;
            *)
                pp=$(ga_agents_public_port)
                if [ -z "$pp" ]; then
                    ga_err needs_site "$(t agents_err_needs_site)"
                    return 1
                fi
                [ -n "$ip" ] || { ga_err no_server_ip "$(t agents_err_no_ip)"; return 1; }
                base="https://${ip}:${pp}"; via="port"; fp=$(ga_agents_fingerprint)
                ;;
        esac
        if ga_agents_http_enabled; then
            case "$via" in
                domain|ip) [ "$(ga_config_get .site.mcp_location 2>/dev/null)" = "true" ] && reach=true ;;
                *) reach=true ;;
            esac
        fi
    fi
    jq -cn --arg base "$base" --arg via "$via" --arg fp "$fp" --argjson reach "$reach" \
        '{base: $base, via: $via, cert_fingerprint_sha256: $fp, reachable: $reach}'
}

# Карточка доступа с адресом: stdout JSON (секрет — только в url, токен — в token).
# Общий хвост agents_add / agents_show / agents_rotate / agents_harden.
#
# Что показывать людям. Поле connect — готовая команда подключения; именно её и
# показывают интерфейсы. Отдельной строки «адрес с токеном для пересылки» в
# карточке нет намеренно: такая строка сама просится в чат, а это ровно тот
# сценарий утечки, от которого второй фактор и защищает. Рядом с командой всегда
# идёт warning: это пароль, а не ссылка.
ga_agents_card() {
    local id="$1" key="${2:-}" code="${3:-}" rec ep enabled hint warn="" fp url token req_token weak_warn="" connect \
          mode one_client="" key_hint="" transport base fp_part="" connector_get="" connect_note=""
    rec=$(ga_agents_get "$id"); [ -n "$rec" ] || { ga_err agent_not_found "$(tf agents_err_not_found "$id")"; return 1; }
    ep=$(ga_agents_endpoint "$(printf '%s' "$rec" | jq -r '.port // 0')") || return 1
    enabled=$(ga_agents_http_enabled && printf true || printf false)
    fp=$(printf '%s' "$ep" | jq -r .cert_fingerprint_sha256)
    url="$(printf '%s' "$ep" | jq -r .base)/a-$(printf '%s' "$rec" | jq -r .secret)/mcp"
    token=$(printf '%s' "$rec" | jq -r '.token // ""')
    req_token=$(printf '%s' "$rec" | jq -r 'if .require_token == true then "true" else "false" end')
    mode=$(printf '%s' "$rec" | jq -r 'if .mode == "rolling" then "rolling" else "static" end')
    if [ "$req_token" = true ] && [ -n "$token" ]; then
        connect=$(tf agents_connect_cmd "$url" "$token")
    else
        connect=$(tf agents_connect_cmd_plain "$url")
        weak_warn=$(t agents_warn_weak)
    fi
    if [ "$mode" = rolling ]; then
        # Обычный клиент MCP не умеет менять заголовок между запросами, поэтому
        # готовой команды для rolling нет и выдумывать её нельзя: человек
        # скопировал бы нерабочую строку. Показываем, что нужно уметь клиенту.
        connect=""
        connect_note=$(t agents_connect_rolling)
        weak_warn=""
        one_client=$(t agents_hint_one_client)
        key_hint=$(t agents_hint_key_once)
    fi
    transport=$(printf '%s' "$rec" | jq -r '.transport // ""')
    if [ "$transport" = connect ]; then
        # Переходник: неподвижного адреса у доступа нет (путь плавающий), токен и ключ
        # живут только у переходника. Карточка даёт команду привязки — ровно один раз,
        # пока код жив, — или готовую строку для клиента MCP, если привязка уже была.
        mode=connect
        url=""
        weak_warn=""
        key_hint=""
        one_client=$(t agents_hint_one_client)
        base=$(printf '%s' "$ep" | jq -r '.base // ""')
        [ -n "$fp" ] && [ "$fp" != null ] && fp_part=" --fingerprint $fp"
        # В connect кладётся только то, что можно выполнить; пояснение — отдельным полем:
        # интерфейсы подают connect как команду и дают её скопировать.
        connect=""; connect_note=""
        if [ "$(printf '%s' "$rec" | jq -r '.rot_seed // ""')" != "" ]; then
            connect_note=$(tf agents_connect_bound "$id")
        elif [ -n "$code" ]; then
            connect=$(tf agents_connect_enroll_cmd "$code" "$base" "$fp_part")
        elif [ "$(printf '%s' "$rec" | jq -r '(.enroll_expires // "") as $e
                | if $e != "" and ((try ($e | fromdateiso8601) catch 0) < now) then "yes" else "no" end')" = yes ]; then
            connect_note=$(t agents_connect_code_expired)
        else
            connect_note=$(t agents_connect_pending_nocode)
        fi
        # Эталонная копия продукта — там же, где install.sh (bootstrap кладёт её в
        # GOAMNEZIA_DIR); адрес — тот же, по которому владелец ходит на сервер по SSH.
        local sip
        sip=$(ga_agents_server_ip); [ -n "$sip" ] || sip="<server-ip>"
        connector_get=$(tf agents_connect_get "$sip" "${GOAMNEZIA_DIR:-/opt/goamnezia}/goamnezia-mcp/connect.py")
    fi
    if [ "$enabled" != true ] && [ "$transport" = connect ]; then hint=$(t agents_hint_transport_off_connect)
    elif [ "$enabled" != true ]; then hint=$(t agents_hint_transport_off)
    elif [ -n "$connect" ]; then hint=$(tf agents_hint_connect "$connect")
    else hint="$connect_note"; fi
    [ -n "$fp" ] && warn=$(tf agents_warn_selfsigned "$fp")
    # Адрес с секретом, команда с токеном, одноразовый ключ и код привязки — окружением, не аргументами jq:
    # argv любого процесса виден каждому локальному пользователю в /proc/*/cmdline (находка SR-17).
    # hint тоже содержит команду подключения целиком: перенос одного connect в окружение оставлял
    # токен (или код привязки) в argv через эту человекочитаемую строку.
    printf '%s' "$rec" | GA_S_URL="$url" GA_S_CONNECT="$connect" GA_S_KEY="$key" GA_S_CODE="$code" GA_S_HINT="$hint" \
        jq -c --argjson ep "$ep" --argjson te "$enabled" --arg warn "$warn" \
        --arg weak "$weak_warn" --arg mode "$mode" \
        --arg one "$one_client" --arg keyhint "$key_hint" \
        --arg codehint "$(t agents_enroll_hint)" --arg cget "$connector_get" --arg cnote "$connect_note" \
        --arg slide "$(t agents_hint_sliding)" \
        --arg key_warn "$(t agents_warn_url_is_key)" '
        $ENV.GA_S_URL as $url | $ENV.GA_S_CONNECT as $connect | $ENV.GA_S_KEY as $key | $ENV.GA_S_CODE as $code | $ENV.GA_S_HINT as $hint |
        {id, label: .label, scope, enabled, created, expires, port: (.port // 0), allow_ips: (.allow_ips // []),
         last_used: (.last_used // ""), last_ip: (.last_ip // ""), calls: (.calls // 0),
         require_token: (.require_token == true),
         token: (if .transport == "connect" then "" else (.token // "") end), mode: $mode,
         transport: (.transport // ""), key_storage: (.key_storage // ""),
         enroll_pending: ((.transport // "") == "connect" and (.rot_seed // "") == ""),
         enroll_expired: ((.transport // "") == "connect" and (.rot_seed // "") == "" and (.enroll_expires // "") != "" and ((try ((.enroll_expires) | fromdateiso8601) catch 0) < now)),
         enroll_expires: (.enroll_expires // ""),
         compromised: (.compromised == true), compromised_at: (.compromised_at // ""),
         compromised_ip: (.compromised_ip // ""),
         pin_ip: (.pin_ip == true), pinned_ip: (.pinned_ip // ""),
         url: $url, connect: $connect, via: $ep.via,
         cert_fingerprint_sha256: $ep.cert_fingerprint_sha256, transport_enabled: $te,
         reachable: $ep.reachable, hint: $hint,
         warning: (if (.transport // "") == "connect" then "" else $key_warn end)}
        + (if $warn != "" then {cert_hint: $warn} else {} end)
        + (if $weak != "" then {weak_hint: $weak} else {} end)
        + (if $one != "" then {one_client_hint: $one} else {} end)
        # Про скользящий срок говорим только там, где срок вообще есть:
        # у бессрочного доступа продлевать нечего.
        + (if (.expires // "") != "" and $slide != "" then {sliding_hint: $slide} else {} end)
        + (if $key != "" then {key: $key, key_hint: $keyhint} else {} end)
        + (if $code != "" then {enroll_code: $code, enroll_hint: $codehint} else {} end)
        + (if $cget != "" then {connector_hint: $cget} else {} end)
        + (if $cnote != "" then {connect_note: $cnote} else {} end)'
}

# ══════════════════════════════════════════════════════════════════════════════
#  Действия над доступами
# ══════════════════════════════════════════════════════════════════════════════
# agents_list — stdout JSON-массив без секретов; expired и state (active |
# disabled | expired) считаются здесь, чтобы бот, панель и меню не дублировали правило.
# enabled сравниваем с false явно: «.enabled // true» в jq считает false
# отсутствием значения, и выключенный доступ значился бы действующим.
# weak — доступ без второго фактора: работает по одному адресу, и утечка адреса
# равна угону. Флаг считается здесь, чтобы меню, бот и панель показывали одну и
# ту же пометку, а не выводили её каждый по-своему. У rolling второй фактор —
# сам одноразовый ключ, поэтому слабым он не считается.
# compromised — доступ заморожен: сервер увидел ключ, которого у настоящего
# агента быть уже не может. Это состояние старше всех прочих: замороженный не
# впускает никого, чем бы он ни числился в enabled и expires.
agents_list() {
    ga_agents_json | jq -c --argjson ff "$(_agents_freeze_failed_json)" '
        def exp_ts: (.expires // "") as $e | if $e == "" then null else (try ($e | fromdateiso8601) catch 0) end;
        [.agents[]? | (exp_ts) as $ts
          | del(.secret, .token, .key_hash, .rot_seed, .enroll_path)
          + {port: (.port // 0), allow_ips: (.allow_ips // []), last_used: (.last_used // ""),
             last_ip: (.last_ip // ""), calls: (.calls // 0),
             mode: (if .transport == "connect" then "connect" elif .mode == "rolling" then "rolling" else "static" end),
             transport: (.transport // ""), key_storage: (.key_storage // ""),
             enroll_pending: ((.transport // "") == "connect" and (.rot_seed // "") == ""),
             enroll_expired: ((.transport // "") == "connect" and (.rot_seed // "") == "" and (.enroll_expires // "") != "" and ((try ((.enroll_expires) | fromdateiso8601) catch 0) < now)),
             enroll_expires: (.enroll_expires // ""),
             compromised: (.compromised == true), compromised_at: (.compromised_at // ""),
             compromised_ip: (.compromised_ip // ""),
             freeze_failed: (.compromised != true and $ff[.id] != null),
             freeze_failed_at: (if .compromised != true then ($ff[.id].at // "") else "" end),
             freeze_failed_ip: (if .compromised != true then ($ff[.id].ip // "") else "" end),
             require_token: (.require_token == true),
             weak: (.require_token != true and .mode != "rolling"),
             pin_ip: (.pin_ip == true), pinned_ip: (.pinned_ip // ""),
             expired: ($ts != null and $ts < now),
             state: (if .compromised == true then "compromised"
                     elif .enabled == false then "disabled"
                     elif ($ts != null and $ts < now) then "expired" else "active" end)}]' 2>/dev/null \
        || printf '[]'
}

# agents_add <label> [scope=read] [days=30] [allow_ips] [port] [pin_ip=off] [mode=static]
# — stdout: карточка. Пустой days — это «не указали», и тогда 30 дней; явный 0 —
# бессрочно, осознанный выбор. mode=rolling выдаёт доступ с одноразовым ключом:
# первый ключ печатается ОДИН раз, дальше цепочку ведёт сервер.
agents_add() { ga_with_config_lock _agents_add_locked "$@"; }
_agents_add_locked() {
    local label="${1:-}" scope="${2:-}" days="${3:-}" ips="${4:-}" port="${5:-}" pin="${6:-}" \
          mode="${7:-}" id secret token expires rec doc pin_json key="" key_hash=""
    [ -n "$scope" ] || scope="$GA_AGENTS_DEFAULT_SCOPE"
    [ -n "$days" ] || days="$GA_AGENTS_DEFAULT_DAYS"
    [ -n "$mode" ] || mode="$GA_AGENTS_DEFAULT_MODE"
    if ! ga_agents_label_valid "$label"; then ga_err invalid_label "$(t agents_err_label)" 2; return 2; fi
    if ! ga_agents_scope_valid "$scope"; then ga_err invalid_scope "$(tf agents_err_scope "$scope")" 2; return 2; fi
    if ! ga_agents_mode_valid "$mode"; then ga_err invalid_mode "$(tf agents_err_mode "$mode")" 2; return 2; fi
    if ! [[ "$days" =~ ^[0-9]+$ ]] || [ "$days" -gt "$GA_AGENTS_MAX_DAYS" ]; then
        ga_err invalid_days "$(tf agents_err_days "$days" "$(ga_days "$GA_AGENTS_MAX_DAYS")")" 2; return 2
    fi
    if ! ga_agents_ips_valid "$ips"; then ga_err invalid_ips "$(tf agents_err_ips "$ips")" 2; return 2; fi
    pin_json=$(ga_agents_onoff_json "$pin") || { ga_err invalid_state "$(tf agents_err_state "$pin")" 2; return 2; }
    if [ -n "$port" ] && [ "$port" != 0 ]; then
        ga_agents_check_port "$port" || return $?
    else
        port=0
    fi
    agents_read >/dev/null || return 1
    # Адрес должен существовать ДО записи: в lite без порта доступ было бы некуда
    # подключать, и человек получил бы запись без ссылки.
    ga_agents_endpoint "$port" >/dev/null || return $?
    secret=$(ga_agents_new_secret) || { ga_err secret_failed "$(t agents_err_secret)"; return 1; }
    token=$(ga_agents_new_secret) || { ga_err secret_failed "$(t agents_err_secret)"; return 1; }
    if [ "$mode" = rolling ]; then
        # Первый ключ цепочки. В запись идёт только отпечаток: сам ключ уходит в
        # карточку и больше нигде не хранится — как токен панели.
        key=$(ga_agents_new_secret) || { ga_err secret_failed "$(t agents_err_secret)"; return 1; }
        key_hash=$(ga_agents_key_hash "$key") || { ga_err secret_failed "$(t agents_err_hash)"; return 1; }
    fi
    local code="" enroll_path="" enroll_expires="" transport="" rec_mode="$mode"
    if [ "$mode" = connect ]; then
        # Код живёт 10 минут: выданный при выключенном транспорте, он сгорел бы раньше, чем
        # переходнику станет куда привязываться.
        ga_agents_http_enabled || { ga_err transport_off "$(t agents_err_connect_transport_off)"; return 1; }
        # Переходник: ни токена, ни ключа сейчас не выдаём — их создаст сервер при
        # привязке и отдаст один раз самому переходнику. Здесь только одноразовый
        # код, а в запись ложится его отпечаток. По сети код не едет вовсе.
        token=""
        code=$(ga_agents_enroll_code) || { ga_err secret_failed "$(t agents_err_enroll_code)"; return 1; }
        enroll_path=$(ga_agents_enroll_path "$code") || { ga_err secret_failed "$(t agents_err_enroll_code)"; return 1; }
        enroll_expires=$(ga_agents_iso_in_seconds "$GA_AGENTS_ENROLL_TTL")
        transport=connect
        rec_mode=rolling
    fi
    id=$(ga_agents_new_id) || { ga_err id_failed "$(t agents_err_id_gen)"; return 1; }
    expires=$(ga_agents_iso_in_days "$days")
    # require_token=true у всех новых доступов: адрес без токена бесполезен, и утечка
    # одного лишь адреса (снимок экрана, история браузера, журнал прокси) не даёт управления.
    # Секрет адреса, токен и путь привязки — окружением, запись целиком — тоже: не аргументами jq, argv
    # виден каждому локальному пользователю в /proc/*/cmdline (находка SR-17).
    # label зарезервирован в jq 1.6: agent_label работает и со штатным пакетом Ubuntu 22.04.
    rec=$(GA_S_SECRET="$secret" GA_S_TOKEN="$token" GA_S_EP="$enroll_path" \
        jq -cn --arg id "$id" --arg agent_label "$label" --arg scope "$scope" \
        --arg created "$(ga_now)" --arg expires "$expires" --argjson port "$port" --argjson ips "$(ga_agents_ips_json "$ips")" \
        --argjson pin "$pin_json" --arg mode "$rec_mode" --arg kh "$key_hash" --argjson term "$days" \
        --arg tr "$transport" --arg ee "$enroll_expires" \
        '{id: $id, label: $agent_label, secret: $ENV.GA_S_SECRET, token: $ENV.GA_S_TOKEN, require_token: true, scope: $scope,
          mode: $mode, key_hash: $kh, compromised: false, term_days: $term,
          enabled: true, created: $created, expires: $expires, port: $port, allow_ips: $ips,
          pin_ip: $pin, pinned_ip: "", known_ips: [], last_used: "", last_ip: "", calls: 0}
         + (if $tr != "" then {transport: $tr, enroll_path: $ENV.GA_S_EP, enroll_expires: $ee} else {} end)')
    doc=$(ga_agents_json | GA_S_REC="$rec" jq -c '.agents += [$ENV.GA_S_REC | fromjson]') || { ga_err write_failed "$(t agents_err_json)"; return 1; }
    printf '%s' "$doc" | _agents_write_locked || return 1
    # Свежая запись — свежая цепочка: состояние от прежнего доступа с тем же id
    # (удалённого и выданного заново) не должно её продолжать.
    _agents_state_drop "$id"
    if [ "$port" -gt 0 ]; then
        # Персональный порт — публичный TLS-слушатель: нужен сертификат и перезапуск юнита
        ga_agents_cert_ensure || log_warning "$(t agents_warn_cert_missing)"
        _agents_unit_reconcile_locked force || true
    fi
    ga_agents_audit "agent-add" "id=${id} scope=${scope} mode=${mode} days=${days} port=${port} ips=${ips:--} pin_ip=${pin_json}"
    log_success "$(tf agents_added "$id" "$label" "$scope")"
    [ "$days" = 0 ] && log_warning "$(t agents_warn_forever)"
    if [ "$mode" = rolling ]; then
        log_warning "$(t agents_warn_rolling_new)"
        log_warning "$(t agents_hint_one_client)"
    fi
    [ "$mode" = connect ] && log_warning "$(t agents_enroll_hint)"
    ga_agents_card "$id" "$key" "$code"
}

# agents_harden <id> — выдать токен доступу, выданному до второго фактора.
# Старый адрес после этого перестаёт работать сам по себе: агенту нужно добавить
# заголовок. Это не побочный эффект обновления, а осознанное решение человека —
# поэтому отдельное действие, а не миграция при чтении файла.
agents_harden() { ga_with_config_lock _agents_harden_locked "$@"; }
_agents_harden_locked() {
    local id="${1:-}" token doc
    ga_agents_require "$id" || return $?
    if [ "$(ga_agents_get "$id" | jq -r 'if .require_token == true then "true" else "false" end')" = true ]; then
        ga_err already_strong "$(tf agents_err_already_strong "$id")"
        return 1
    fi
    token=$(ga_agents_new_secret) || { ga_err secret_failed "$(t agents_err_secret)"; return 1; }
    doc=$(ga_agents_json | GA_S_TOKEN="$token" jq -c --arg id "$id" \
        '.agents |= map(if .id == $id then (.token = $ENV.GA_S_TOKEN | .require_token = true) else . end)') \
        || { ga_err write_failed "$(t agents_err_json)"; return 1; }   # токен — не в argv (SR-17)
    printf '%s' "$doc" | _agents_write_locked || return 1
    ga_agents_audit "agent-harden" "id=${id}"
    log_success "$(tf agents_hardened "$id")"
    ga_agents_card "$id"
}

# agents_pin <id> <on|off> — привязка к адресу первого использования.
# on всегда обнуляет pinned_ip: включить привязку и «перепривязать» — одно и то же
# действие, иначе после переезда агента пришлось бы выключать и включать заново.
agents_pin() { ga_with_config_lock _agents_pin_locked "$@"; }
_agents_pin_locked() {
    local id="${1:-}" state="${2:-}" value doc
    ga_agents_require "$id" || return $?
    # Пустое значение здесь — не «off», а забытый аргумент: молча снять привязку
    # значило бы ослабить доступ по недосмотру (в agents_add пусто = «не просили»).
    [ -n "$state" ] || { ga_err invalid_state "$(tf agents_err_state "-")" 2; return 2; }
    value=$(ga_agents_onoff_json "$state") || { ga_err invalid_state "$(tf agents_err_state "$state")" 2; return 2; }
    doc=$(ga_agents_json | jq -c --arg id "$id" --argjson v "$value" \
        '.agents |= map(if .id == $id then (.pin_ip = $v | .pinned_ip = "") else . end)') \
        || { ga_err write_failed "$(t agents_err_json)"; return 1; }
    printf '%s' "$doc" | _agents_write_locked || return 1
    ga_agents_audit "agent-pin" "id=${id} pin_ip=${value}"
    if [ "$value" = true ]; then log_success "$(tf agents_pin_on "$id")"; else log_success "$(tf agents_pin_off "$id")"; fi
    jq -cn --arg id "$id" --argjson v "$value" '{id: $id, pin_ip: $v, pinned_ip: ""}'
}

# agents_extend <id> <days> — продлить срок доступа; stdout {id, expires, old_expires, days}.
#
# Почему отдельное действие, а не «перевыпустить со сроком». Перевыпуск меняет
# секрет и токен, то есть требует перенастроить клиента агента: у облачной сессии
# это значит остановить работу и вручную переписать конфиг. Истечение же — не
# компрометация, а календарь: единственное, что нужно, — сдвинуть дату. Без этого
# действия и руководство, и заголовок модуля обещали продление, а вернуть агента
# можно было только выдав доступ заново.
#
# days=0 — снять срок (бессрочно). Это ослабление, поэтому вызывающий обязан
# спросить человека тем же вопросом, что и при выдаче (agents_warn_forever).
agents_extend() { ga_with_config_lock _agents_extend_locked "$@"; }
_agents_extend_locked() {
    local id="${1:-}" days="${2:-}" old expires doc
    ga_agents_require "$id" || return $?
    # Пустое значение — забытый аргумент, а не «бессрочно»: молча снять срок
    # значило бы ослабить доступ по недосмотру (та же логика, что у agents_pin).
    [ -n "$days" ] || { ga_err invalid_days "$(tf agents_err_days "-" "$(ga_days "$GA_AGENTS_MAX_DAYS")")" 2; return 2; }
    if ! [[ "$days" =~ ^[0-9]+$ ]] || [ "$days" -gt "$GA_AGENTS_MAX_DAYS" ]; then
        ga_err invalid_days "$(tf agents_err_days "$days" "$(ga_days "$GA_AGENTS_MAX_DAYS")")" 2; return 2
    fi
    old=$(ga_agents_get "$id" | jq -r '.expires // ""')
    expires=$(ga_agents_iso_extend "$old" "$days")
    # Длительность меняется ВМЕСТЕ со сроком, иначе скользящее продление тут же
    # вернёт первоначальную: владелец, продливший на неделю по совету тревоги,
    # получал бы год — та самая пара «два источника правды без сверки».
    # days = 0 снимает срок, и длительности у бессрочного быть не должно.
    doc=$(ga_agents_json | jq -c --arg id "$id" --arg e "$expires" --argjson d "$days" \
        '.agents |= map(if .id == $id then (.expires = $e | .term_days = $d) else . end)') \
        || { ga_err write_failed "$(t agents_err_json)"; return 1; }
    printf '%s' "$doc" | _agents_write_locked || return 1
    ga_agents_audit "agent-extend" "id=${id} days=${days} expires=${expires:-never}"
    if [ -n "$expires" ]; then
        log_success "$(tf agents_extended "$id" "$expires")"
    else
        log_success "$(tf agents_extended_forever "$id")"
        log_warning "$(t agents_warn_forever)"
    fi
    jq -cn --arg id "$id" --arg e "$expires" --arg o "$old" --argjson d "$days" \
        '{id: $id, expires: $e, old_expires: $o, days: $d}'
}

# agents_show <id> — карточка с адресом (readonly; сам показ — событие аудита, как user-key)
agents_show() {
    ga_agents_require "$1" || return $?
    ga_agents_audit "agent-show" "id=$1"
    ga_agents_card "$1"
}

# agents_rotate <id> — новые секрет И токен: старый адрес умирает на следующем же
# запросе сервера. Перевыпуск делают, когда доступ считают скомпрометированным, а
# компрометация одного фактора ничего не говорит о втором — меняем оба.
#
# У доступа с одноразовым ключом перевыпуск заодно НАЧИНАЕТ НОВУЮ ЦЕПОЧКУ и
# снимает заморозку: это и есть ответ владельца «это был я» на карточку об
# обнаруженном клоне (MCP_ROTATION §11.3). Второй ответ — отозвать совсем
# (agents_del); молча оживить прежнюю цепочку нельзя, в ней уже двое.
agents_rotate() { ga_with_config_lock _agents_rotate_locked "$@"; }
_agents_rotate_locked() {
    local id="${1:-}" secret token doc mode key="" key_hash="" was_frozen transport code="" enroll_path="" enroll_expires=""
    ga_agents_require "$id" || return $?
    # Адрес должен существовать ДО записи, как при выдаче: в Lite без сайта и порта перевыпуск
    # стирал прежнюю привязку (или цепочку rolling), а карточка потом падала на needs_site —
    # человек видел ошибку и думал, что ничего не изменилось.
    ga_agents_endpoint "$(ga_agents_get "$id" | jq -r '.port // 0')" >/dev/null || return $?
    mode=$(ga_agents_get "$id" | jq -r 'if .mode == "rolling" then "rolling" else "static" end')
    transport=$(ga_agents_get "$id" | jq -r '.transport // ""')
    was_frozen=$(ga_agents_get "$id" | jq -r 'if .compromised == true then "true" else "false" end')
    secret=$(ga_agents_new_secret) || { ga_err secret_failed "$(t agents_err_secret)"; return 1; }
    token=$(ga_agents_new_secret) || { ga_err secret_failed "$(t agents_err_secret)"; return 1; }
    if [ "$transport" = connect ]; then
        ga_agents_http_enabled || { ga_err transport_off "$(t agents_err_connect_transport_off)"; return 1; }
        # Перевыпуск доступа переходника — новая привязка: прежние rot_seed, токен и цепочка
        # перестают действовать разом, а переходнику нужен новый код.
        code=$(ga_agents_enroll_code) || { ga_err secret_failed "$(t agents_err_enroll_code)"; return 1; }
        enroll_path=$(ga_agents_enroll_path "$code") || { ga_err secret_failed "$(t agents_err_enroll_code)"; return 1; }
        enroll_expires=$(ga_agents_iso_in_seconds "$GA_AGENTS_ENROLL_TTL")
    elif [ "$mode" = rolling ]; then
        key=$(ga_agents_new_secret) || { ga_err secret_failed "$(t agents_err_secret)"; return 1; }
        key_hash=$(ga_agents_key_hash "$key") || { ga_err secret_failed "$(t agents_err_hash)"; return 1; }
    fi
    # Новые секрет, токен и путь привязки — окружением, не аргументами jq (SR-17).
    doc=$(ga_agents_json | GA_S_SECRET="$secret" GA_S_TOKEN="$token" GA_S_EP="$enroll_path" \
        jq -c --arg id "$id" --arg kh "$key_hash" --arg ee "$enroll_expires" \
        '$ENV.GA_S_SECRET as $s | $ENV.GA_S_TOKEN as $tk | $ENV.GA_S_EP as $ep
        | .agents |= map(if .id == $id
            then (if .transport == "connect"
                  then (.secret = $s | .token = "" | .require_token = true | .key_hash = ""
                        | .compromised = false | .pinned_ip = ""
                        | del(.compromised_at, .compromised_ip, .rot_seed, .key_storage, .enrolled_at, .enrolled_ip)
                        | .enroll_path = $ep | .enroll_expires = $ee)
                  else (.secret = $s | .token = $tk | .require_token = true
                        | .compromised = false | del(.compromised_at, .compromised_ip)
                        | if .mode == "rolling" then .key_hash = $kh else . end)
                  end)
            else . end)') \
        || { ga_err write_failed "$(t agents_err_json)"; return 1; }
    printf '%s' "$doc" | _agents_write_locked || return 1
    # Прежняя цепочка кончилась вместе со старым ключом. Файл состояния сервер и
    # сам отбросит по несовпадению origin, но оставлять на диске сохранённый
    # ответ прошлой цепочки незачем.
    _agents_state_drop "$id"
    # Перевыпуск — ответ владельца на «заморозить не удалось» тоже: прежний ключ больше не действует
    _agents_freeze_failed_drop "$id"
    ga_agents_audit "agent-rotate" "id=${id} mode=${mode} unfreeze=${was_frozen}"
    if [ "$transport" = connect ]; then
        log_success "$(tf agents_reenrolled "$id")"
    else
        log_success "$(tf agents_rotated "$id")"
    fi
    [ "$was_frozen" = true ] && log_success "$(tf agents_unfrozen "$id")"
    if [ "$transport" = connect ]; then
        log_warning "$(t agents_enroll_hint)"
    elif [ "$mode" = rolling ]; then
        log_warning "$(t agents_warn_rolling_new)"
    fi
    ga_agents_card "$id" "$key" "$code"
}

_agents_set_enabled_locked() {
    local id="${1:-}" value="$2" doc action
    ga_agents_require "$id" || return $?
    doc=$(ga_agents_json | jq -c --arg id "$id" --argjson v "$value" \
        '.agents |= map(if .id == $id then .enabled = $v else . end)') || { ga_err write_failed "$(t agents_err_json)"; return 1; }
    printf '%s' "$doc" | _agents_write_locked || return 1
    # Выключенный доступ никого не впускает — «заморозить не удалось» больше не тревога (L-08)
    [ "$value" = true ] || _agents_freeze_failed_drop "$id"
    if [ "$value" = true ]; then action="agent-enable"; else action="agent-disable"; fi
    ga_agents_audit "$action" "id=${id}"
    if [ "$value" = true ]; then log_success "$(tf agents_enabled "$id")"; else log_success "$(tf agents_disabled "$id")"; fi
    jq -cn --arg id "$id" --argjson v "$value" '{id: $id, enabled: $v}'
}
# agents_enable / agents_disable <id> — stdout {id, enabled}
agents_enable()  { ga_with_config_lock _agents_set_enabled_locked "${1:-}" true; }
agents_disable() { ga_with_config_lock _agents_set_enabled_locked "${1:-}" false; }

# agents_del <id> — stdout {id, deleted: true}
agents_del() { ga_with_config_lock _agents_del_locked "$@"; }
_agents_del_locked() {
    local id="${1:-}" doc port
    ga_agents_require "$id" || return $?
    port=$(ga_agents_get "$id" | jq -r '.port // 0')
    doc=$(ga_agents_json | jq -c --arg id "$id" '.agents |= map(select(.id != $id))') || { ga_err write_failed "$(t agents_err_json)"; return 1; }
    printf '%s' "$doc" | _agents_write_locked || return 1
    # Состояние цепочки — часть доступа: остаться на диске после отзыва оно не
    # должно (в нём лежит и текущий ключ, и сохранённый ответ последнего вызова).
    _agents_state_drop "$id"
    _agents_freeze_failed_drop "$id"
    # Персональный порт закрывается только перезапуском: слушатели открыты при старте
    [ "$port" -gt 0 ] 2>/dev/null && { _agents_unit_reconcile_locked force || true; }
    ga_agents_audit "agent-del" "id=${id}"
    log_success "$(tf agents_deleted "$id")"
    jq -cn --arg id "$id" '{id: $id, deleted: true}'
}

# ══════════════════════════════════════════════════════════════════════════════
#  HTTP-транспорт: юнит goamnezia-mcp-http.service
# ══════════════════════════════════════════════════════════════════════════════
# Как слушает сервер при текущем режиме: «<bind> <port> <tls:0|1>».
# pro / lite_site — 127.0.0.1:1986 за nginx (TLS терминирует nginx); lite с
# публичным портом — 0.0.0.0:<порт> с самоподписанным сертификатом; lite без
# порта, но с персональными портами — петля (основной слушатель никому не виден,
# работают только персональные); иначе — пусто (слушать нечего).
ga_agents_listen_plan() {
    local mode pp
    mode=$(ga_agents_mode)
    case "$mode" in
        pro|lite_site) printf '127.0.0.1 %s 0' "$(ga_agents_loopback_port)" ;;
        *)
            pp=$(ga_agents_public_port)
            if [ -n "$pp" ]; then printf '0.0.0.0 %s 1' "$pp"
            elif ga_agents_has_port_grants; then printf '127.0.0.1 %s 0' "$(ga_agents_loopback_port)"
            else printf ''; fi
            ;;
    esac
}
# Нужен ли самоподписанный сертификат: публичный слушатель или персональные порты
ga_agents_needs_cert() {
    local plan
    plan=$(ga_agents_listen_plan)
    [ "${plan##* }" = 1 ] && return 0
    ga_agents_has_port_grants
}

# Текст юнита для текущего режима (stdout). User=root: мост install.sh требует root.
_agents_unit_render() {
    local plan bind port tls crt key exec_line
    plan=$(ga_agents_listen_plan)
    [ -n "$plan" ] || return 1
    read -r bind port tls <<< "$plan"
    crt=$(ga_agents_ss_crt); key=$(ga_agents_ss_key)
    exec_line="/usr/bin/env python3 $(ga_agents_server_py) --http --bind ${bind} --port ${port}"
    if [ "$tls" = 1 ]; then
        exec_line="${exec_line} --tls ${crt},${key}"
    elif ga_agents_has_port_grants; then
        # Персональные порты публичные всегда, даже когда основной слушатель за nginx
        exec_line="${exec_line} --extra-tls ${crt},${key}"
    fi
    cat <<EOUNIT
[Unit]
Description=goAmnezia pro - MCP server over HTTP (agent access, PLAN 6.10)
Documentation=file://${GOAMNEZIA_DIR}/goamnezia-mcp/README.md
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=GOAMNEZIA_DIR=${GOAMNEZIA_DIR}
Environment=GOAMNEZIA_ACTION_BIN=${GOAMNEZIA_DIR}/install.sh
Environment=GOAMNEZIA_AUDIT_LOG=${AUDIT_LOG:-/var/log/goamnezia-audit.log}
Environment=GOAMNEZIA_MCP_LOG=info
ExecStart=${exec_line}
Restart=always
RestartSec=3
# Секреты агентов и мост — только root; временные файлы процесса не видны другим
PrivateTmp=true
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOUNIT
}

# Записать юнит, если изменился (GA_AGENTS_UNIT_CHANGED=1), и daemon-reload.
_agents_unit_write_locked() {
    local path content tmp
    GA_AGENTS_UNIT_CHANGED=0
    content=$(_agents_unit_render) || { ga_err needs_site "$(t agents_err_needs_site)"; return 1; }
    path=$(ga_agents_unit_path)
    if ! ga_agents_fs_systemd_ok; then
        ga_dry_echo "write $path"
        GA_AGENTS_UNIT_CHANGED=1
        return 0
    fi
    if [ -f "$path" ] && [ "$(cat "$path" 2>/dev/null)" = "$content" ]; then
        return 0
    fi
    mkdir -p "$(dirname "$path")" 2>/dev/null || { ga_err unit_failed "$(tf agents_err_unit "$path")"; return 1; }
    tmp=$(mktemp "${path}.XXXXXX" 2>/dev/null) || { ga_err unit_failed "$(tf agents_err_unit "$path")"; return 1; }
    if ! printf '%s\n' "$content" >"$tmp" || ! chmod 644 "$tmp" || ! mv -f "$tmp" "$path"; then
        rm -f "$tmp"
        ga_err unit_failed "$(tf agents_err_unit "$path")"
        return 1
    fi
    GA_AGENTS_UNIT_CHANGED=1
    ga_agents_run_quiet systemctl daemon-reload || true
    return 0
}
# Снять юнит транспорта. ОТКАЗ ОБЯЗАН БЫТЬ ВИДЕН: все три шага глушились
# «|| true», а флаг «выключено» писался следом — и не снявшийся юнит превращался
# в спокойное «HTTP-транспорт выключен» при живой службе с 53 инструментами
# моста (DEFECTS §4.8). Теперь проверяем по факту: остался ли юнит и работает
# ли он. Возвращаем 1, если снять не удалось, — вызывающий не имеет права
# записывать «выключено».
_agents_unit_remove_locked() {
    local path state
    path=$(ga_agents_unit_path)
    GA_AGENTS_UNIT_DEFERRED=0
    _agents_unit_ctl disable --now || true
    if ga_agents_fs_systemd_ok; then rm -f "$path" 2>/dev/null || true; else ga_dry_echo "rm -f $path"; fi
    ga_agents_run_quiet systemctl daemon-reload || true
    ga_dry && return 0
    # Выключение пришло через сам транспорт (агент по HTTP): остановка назначена на миг после ответа, и
    # «служба ещё работает» здесь — не отказ, а порядок (SR-10).
    [ "$GA_AGENTS_UNIT_DEFERRED" = 1 ] && return 0
    state=$(ga_agents_unit_state)
    case "$state" in
        missing|dry) return 0 ;;
        inactive)
            # Юнит остался на диске, но не работает: слушателя нет, а файл
            # мешает — говорим об этом, не выдавая за успех.
            ga_err unit_failed "$(tf agents_err_unit_left "$GA_AGENTS_UNIT" "$path")"
            return 1 ;;
        *)
            ga_err unit_failed "$(tf agents_err_unit_alive "$GA_AGENTS_UNIT" "$GA_AGENTS_UNIT")"
            return 1 ;;
    esac
}
# Состояние юнита одним словом: active | inactive | missing | dry
ga_agents_unit_state() {
    if ga_dry; then printf 'dry'; return 0; fi
    systemctl cat "$GA_AGENTS_UNIT" >/dev/null 2>&1 || { printf 'missing'; return 0; }
    if systemctl is-active --quiet "$GA_AGENTS_UNIT" 2>/dev/null; then printf 'active'; else printf 'inactive'; fi
}
# Транспорт включён → юнит под текущий режим и (пере)запуск при изменении.
# Зовётся после agent-add/del с портом и из lib/website.sh при смене режима.
# В lite без единого порта слушать нечего: юнит останавливаем, флаг
# mcp.http_enabled оставляем — при возврате сайта транспорт поднимется сам.
# $1 = force: перезапустить и при неизменном тексте юнита — персональные порты
# сервер открывает при старте (--extra-ports auto из agents.json), а сам юнит
# от нового порта не меняется.
# systemctl для службы транспорта агентов. Если нас запустила САМА эта служба (агент по HTTP
# зовёт mode_set / mcp-http-*), мы живём в её cgroup: остановка или перезапуск службы убивали мост
# на полпути — режим записан, страницы не отозваны, агент получает обрыв вместо ответа (находка
# SR-10, 25.09.2026). Тогда остановку и перезапуск откладываем до выхода моста (_agents_unit_defer),
# а ссылки юнита (enable/disable) меняем сразу — службу они не трогают. start работающей службы —
# пустая операция: раз мы внутри неё, она работает.
GA_AGENTS_UNIT_DEFERRED=0
_agents_unit_ctl() {
    local verb="${1:-}" a now=0 later=""
    for a in "$@"; do [ "$a" = --now ] && now=1; done
    if ga_in_unit "$GA_AGENTS_UNIT" 2>/dev/null && { ga_dry || command -v systemd-run >/dev/null 2>&1; }; then
        case "$verb" in
            enable|disable)
                ga_agents_run_quiet systemctl "$verb" "$GA_AGENTS_UNIT" || return 1
                [ "$now" = 1 ] || return 0
                if [ "$verb" = enable ]; then later=start; else later=stop; fi ;;
            *) later="$verb" ;;
        esac
        [ "$later" = start ] && return 0
        _agents_unit_defer "$later" && return 0
    fi
    ga_agents_run_quiet systemctl "$@" "$GA_AGENTS_UNIT"
}

# _agents_unit_defer <stop|restart> — выполнить systemctl над службой транспорта ПОСЛЕ того, как мост
# закончит, а служба отдаст ответ: временная служба systemd (вне нашей cgroup, её перезапуск не заденет)
# ждёт, пока процесс моста ($$ — сам install.sh, и из подоболочек тоже) не выйдет, и ещё две секунды на
# отправку ответа. Прежде ждала ровно 3 секунды от вызова: на медленной машине мост не успевал доделать смену
# режима — отзыв страниц и аудит обрывались (SR-10). Предел ожидания — 15 минут: мост дольше не живёт.
_agents_unit_defer() {
    local what="${1:-}" unit="goamnezia-mcp-http-ctl-$$-$RANDOM"
    case "$what" in stop|restart|try-restart) ;; *) return 1 ;; esac
    if ga_dry; then
        ga_dry_echo "systemd-run --unit=$unit: after bridge pid $$ exits, systemctl $what $GA_AGENTS_UNIT"
        GA_AGENTS_UNIT_DEFERRED=1
        return 0
    fi
    # shellcheck disable=SC2016 # тело — для /bin/sh временной службы, раскрывается там
    systemd-run --quiet --collect --unit="$unit" /bin/sh -c \
        'i=0; while kill -0 "$1" 2>/dev/null && [ "$i" -lt 900 ]; do sleep 1; i=$((i + 1)); done; sleep 2; exec systemctl "$2" "$3"' \
        sh "$$" "$what" "$GA_AGENTS_UNIT" >/dev/null 2>&1 || return 1
    GA_AGENTS_UNIT_DEFERRED=1
    return 0
}

_agents_unit_reconcile_locked() {
    local force="${1:-}"
    ga_agents_http_enabled || return 0
    if [ -z "$(ga_agents_listen_plan)" ]; then
        _agents_unit_ctl disable --now || true
        log_warning "$(t agents_warn_nothing_to_listen)"
        return 0
    fi
    if ga_agents_needs_cert; then
        ga_agents_cert_ensure || return 1
    fi
    _agents_unit_write_locked || return 1
    # Служба стоит, хотя должна работать: уход в «Только VPN» сделал ей disable --now, а при
    # возврате сайта юнит-файл совпадает с прежним, и без этой проверки она так и оставалась
    # лежать — агенты получали 502, а статус писал «включён» (находка LS-03, 25.09.2026).
    local running=1
    if ! ga_dry && ! systemctl is-active --quiet "$GA_AGENTS_UNIT" 2>/dev/null; then running=0; fi
    if [ "${GA_AGENTS_UNIT_CHANGED:-0}" = 1 ] || [ "$force" = force ] || [ "$running" = 0 ]; then
        _agents_unit_ctl enable --now || { ga_err unit_failed "$(tf agents_err_unit_start "$GA_AGENTS_UNIT")"; return 1; }
        _agents_unit_ctl restart || { ga_err unit_failed "$(tf agents_err_unit_start "$GA_AGENTS_UNIT")"; return 1; }
        log_dim "$(t agents_unit_restarted)"
    fi
    return 0
}
agents_http_reconcile() { ga_with_config_lock _agents_unit_reconcile_locked "$@"; }

# Открыть публичный TCP-порт в локальном файрволе, если он закрыт (lib/preflight.sh).
# Файрвол хостинга снаружи мы не видим — подсказка в статусе.
_agents_firewall_open() {
    local port="$1" state
    type ga_pf_firewall_state >/dev/null 2>&1 || return 0
    type preflight_open_local >/dev/null 2>&1 || return 0
    type ga_pf_collect >/dev/null 2>&1 && ga_pf_collect tcp >/dev/null 2>&1
    state=$(ga_pf_firewall_state tcp "$port" 2>/dev/null) || state=""
    case "$state" in
        closed*) preflight_open_local "$port" tcp || log_warning "$(tf agents_warn_fw "$port" "$port")" ;;
    esac
    return 0
}

# agents_http_status — stdout JSON: состояние транспорта для меню, бота, панели и mcp-http-status.
agents_http_status() {
    local enabled=false configured=false available=false reason="" mode plan bind="" port="" tls=0 pp lp domain ip fp="" base="" via="" loc=false unit reach=false hint=""
    local total enabled_n with_port weak_n rolling_n frozen_n listen="none"
    # configured — что записано в конфиге, enabled — что есть на самом деле.
    # Флаг переживает смену режима: включили транспорт в Pro, ушли в Lite — и
    # ответ рапортовал «включено», хотя vhost'а, в котором жил маршрут, больше
    # нет (DEFECTS §1.8). Сначала выясняем, где транспорту жить (listen), и
    # только потом решаем, что отдавать.
    ga_agents_http_enabled && configured=true
    mode=$(ga_agents_mode)
    lp=$(ga_agents_loopback_port); pp=$(ga_agents_public_port)
    domain=$(ga_agents_domain); ip=$(ga_agents_server_ip)
    # Маршрут /a-<secret>/mcp живёт в vhost сайта. В режиме без сайта vhost'а нет
    # вовсе, и site.mcp_location — след прежнего режима, а не факт: отдавать его
    # как факт значило бы врать самим себе о собственном состоянии.
    case "$mode" in
        pro|lite_site) [ "$(ga_config_get .site.mcp_location 2>/dev/null)" = "true" ] && loc=true ;;
    esac
    plan=$(ga_agents_listen_plan)
    [ -n "$plan" ] && read -r bind port tls <<< "$plan"
    case "$mode" in
        pro|lite_site)
            # Тот же вопрос, что в ga_agents_endpoint: домен с настоящим
            # сертификатом или запасной самоподписанный на IP (DEFECTS §1.1).
            if ga_agents_domain_ready; then base="https://${domain}"; via="domain"
            elif [ -n "$ip" ]; then base="https://${ip}"; via="ip"; fp=$(ga_agents_fingerprint); fi
            listen="nginx"
            ;;
        *)
            if [ -n "$pp" ]; then
                [ -n "$ip" ] && { base="https://${ip}:${pp}"; via="port"; fp=$(ga_agents_fingerprint); }
                listen="public_port"
            elif ga_agents_has_port_grants; then
                listen="grant_ports"; fp=$(ga_agents_fingerprint)
            fi
            ;;
    esac
    # Где жить — выяснено; теперь честное состояние. «Включено» без места, где
    # слушать, — это не включено: в Lite без сайта и без своего порта транспорт
    # не отвечает никому, и говорить о нём «работает» нельзя.
    [ "$listen" != none ] && available=true
    [ "$configured" = true ] && [ "$available" = true ] && enabled=true
    [ "$available" = true ] || reason="no_site"
    unit=$(ga_agents_unit_state)
    # Мёртвый юнит — это НЕ достижимый транспорт: nginx-локация есть, а за ней
    # 502. Раньше reachable считался только по конфигу и врал, пока служба
    # падала в цикле рестартов.
    if [ "$enabled" = true ] && { [ "$unit" = active ] || [ "$unit" = dry ]; }; then
        case "$listen" in
            nginx) [ "$loc" = true ] && reach=true ;;
            public_port|grant_ports) reach=true ;;
        esac
    fi
    total=$(ga_agents_json | jq -r '.agents | length' 2>/dev/null || printf 0)
    enabled_n=$(agents_list | jq -r '[.[] | select(.state == "active")] | length' 2>/dev/null || printf 0)
    with_port=$(ga_agents_json | jq -r '[.agents[]? | select((.port // 0) > 0)] | length' 2>/dev/null || printf 0)
    # Сколько доступов живут на одном лишь адресе — это и есть мера риска утечки
    weak_n=$(ga_agents_json | jq -r '[.agents[]? | select(.require_token != true and .mode != "rolling")] | length' 2>/dev/null || printf 0)
    rolling_n=$(ga_agents_json | jq -r '[.agents[]? | select(.mode == "rolling")] | length' 2>/dev/null || printf 0)
    # Замороженные — не статистика, а тревога: доступ не впускает, и владелец
    # обязан решить, перевыпустить его или отозвать.
    frozen_n=$(ga_agents_json | jq -r '[.agents[]? | select(.compromised == true)] | length' 2>/dev/null || printf 0)
    # Подсказка идёт от ЗАПИСАННОГО состояния: «выключен» говорим только тому,
    # у кого он и правда выключен, а включённому без места — почему он молчит.
    if [ "${frozen_n:-0}" -gt 0 ]; then hint=$(tf agents_status_hint_frozen "$frozen_n")
    elif [ "$configured" != true ]; then hint=$(t agents_status_hint_off)
    elif [ "$listen" = none ]; then hint=$(t agents_err_needs_site)
    elif [ "$listen" = nginx ] && [ "$loc" != true ]; then hint=$(t agents_status_hint_location)
    elif [ "$listen" = public_port ] || [ "$listen" = grant_ports ]; then hint=$(t agents_status_hint_firewall)
    fi
    jq -cn --argjson enabled "$enabled" --argjson configured "$configured" \
        --argjson available "$available" --arg reason "$reason" \
        --arg mode "$mode" --arg listen "$listen" --arg bind "$bind" \
        --argjson port "${port:-0}" --argjson tls "$([ "$tls" = 1 ] && printf true || printf false)" \
        --argjson loopback_port "$lp" --argjson public_port "${pp:-0}" --arg domain "$domain" --arg ip "$ip" \
        --arg base "$base" --arg via "$via" --arg fp "$fp" --argjson loc "$loc" --arg unit "$unit" \
        --argjson reach "$reach" --arg hint "$hint" --argjson total "$total" --argjson en "$enabled_n" --argjson wp "$with_port" \
        --argjson weak "$weak_n" --argjson rolling "$rolling_n" --argjson frozen "$frozen_n" \
        --arg unit_name "$GA_AGENTS_UNIT" \
        '{enabled: $enabled, configured: $configured, available: $available, reason: $reason,
          mode: $mode, listen: $listen, bind: $bind, port: $port, tls: $tls,
          http_port: $loopback_port, public_port: $public_port, domain: $domain, server_ip: $ip,
          base_url: $base, via: $via, cert_fingerprint_sha256: $fp, nginx_location: $loc,
          unit: $unit_name, unit_state: $unit, reachable: $reach, hint: $hint,
          agents: $total, agents_active: $en, agents_with_port: $wp, agents_weak: $weak,
          agents_rolling: $rolling, agents_compromised: $frozen}'
}

# agents_http_on [port] — включить транспорт: pro/lite_site — nginx-location + юнит на
# петле; lite — только с портом (свой TLS-слушатель), иначе needs_site. stdout — статус.
# Повторный вызов — ремонт: location, юнит и флаги приводятся к норме.
agents_http_on() { ga_with_config_lock _agents_http_on_locked "$@"; }
_agents_http_on_locked() {
    local port="${1:-}" mode pp
    mode=$(ga_agents_mode)
    agents_read >/dev/null || return 1
    case "$mode" in
        pro|lite_site)
            # Порт в режимах с сайтом не нужен: транспорт идёт через nginx на 443
            [ -n "$port" ] && [ "$port" != 0 ] && log_warning "$(tf agents_warn_port_ignored "$mode")"
            if type website_mcp_location_on >/dev/null 2>&1; then
                website_mcp_location_on || return 1
            else
                ga_config_set .site.mcp_location true || { ga_err config_write_failed "$(t agents_err_config)"; return 1; }
            fi
            ;;
        *)
            pp=$(ga_agents_public_port)
            if [ -n "$port" ] && [ "$port" != 0 ]; then
                ga_agents_check_port "$port" public || return $?
                pp="$port"
            fi
            if [ -z "$pp" ] && ! ga_agents_has_port_grants; then
                ga_err needs_site "$(t agents_err_needs_site)"
                return 1
            fi
            if [ -n "$pp" ]; then
                ga_config_set .mcp.public_port "$pp" || { ga_err config_write_failed "$(t agents_err_config)"; return 1; }
                _agents_firewall_open "$pp"
            fi
            ga_agents_cert_ensure || return 1
            ;;
    esac
    if ga_agents_has_port_grants; then ga_agents_cert_ensure || return 1; fi
    ga_config_set .mcp.http_enabled true || { ga_err config_write_failed "$(t agents_err_config)"; return 1; }
    _agents_unit_write_locked || return 1
    _agents_unit_ctl enable --now || { ga_err unit_failed "$(tf agents_err_unit_start "$GA_AGENTS_UNIT")"; return 1; }
    # Юнит мог работать со старой командой (другой режим) — перезапуск применяет новую
    _agents_unit_ctl restart || { ga_err unit_failed "$(tf agents_err_unit_start "$GA_AGENTS_UNIT")"; return 1; }
    ga_agents_audit "mcp-http-on" "mode=${mode} listen=$(ga_agents_listen_plan | tr ' ' ':')"
    log_success "$(t agents_http_enabled)"
    agents_http_status
}

# agents_http_off — выключить транспорт: доступы остаются, SSH-транспорт работает.
# Идемпотентно: повтор на выключенном транспорте лишь подтверждает состояние.
agents_http_off() { ga_with_config_lock _agents_http_off_locked "$@"; }
_agents_http_off_locked() {
    local mode
    mode=$(ga_agents_mode)
    case "$mode" in
        pro|lite_site)
            if type website_mcp_location_off >/dev/null 2>&1; then website_mcp_location_off || return 1
            else ga_config_set .site.mcp_location false || { ga_err config_write_failed "$(t agents_err_config)"; return 1; }; fi
            ;;
        *)
            # В lite nginx нет — флаг маршрута просто снимаем, без пересборки vhost
            ga_config_set .site.mcp_location false || { ga_err config_write_failed "$(t agents_err_config)"; return 1; }
            ;;
    esac
    # Записать «выключено» можно только если юнита действительно не осталось:
    # иначе продукт говорит «выключен» про работающую службу.
    _agents_unit_remove_locked || return 1
    ga_config_set .mcp.http_enabled false || { ga_err config_write_failed "$(t agents_err_config)"; return 1; }
    ga_agents_audit "mcp-http-off" "mode=${mode}"
    log_success "$(t agents_http_disabled)"
    agents_http_status
}
