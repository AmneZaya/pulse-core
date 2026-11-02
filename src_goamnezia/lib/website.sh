#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# goAmnezia pro — lib/website.sh: режимы с сайтом (PLAN §4.3) — nginx, сайт-маскировка
# из библиотеки шаблонов, сертификат Let's Encrypt (Pro, домен) или самоподписанный
# (Lite + сайт, IP), места для панели и MCP.
#
# Порт lib/website.sh из goTelegram 2.5 (certbot, автопродление, деплой шаблона)
# с отличиями, которые диктует PLAN §4.3–4.4:
#   • nginx сам стоит на TCP/443 — делить порт не с кем, AmneziaWG живёт на
#     UDP/443; другого претендента на этот порт у продукта нет;
#   • три режима: lite (сайта нет), lite_site (nginx на IP: TCP/80 и TCP/443 с
#     самоподписанным сертификатом /opt/goamnezia/tls/site.{key,crt}, чтобы сервер
#     выглядел обычным веб-сервером), pro (домен, Let's Encrypt). Переходы между
#     любыми двумя — website_enable_site_selfsigned / website_enable_pro /
#     website_disable_pro / website_disable_site — трогают только nginx, сертификат
#     и config.json: контейнеры и ключи не пересоздаются;
#   • на домене два «места»: панель по секретному пути (panel.miniapp_path,
#     website_panel_path_set) — только Pro; доступы агентов /a-<secret>/mcp
#     (site.mcp_location, website_mcp_location_on) — Pro и Lite + сайт (PLAN §6.10);
#     страницы подключения /p-<secret>/ и внутренняя локация зеркала сборок
#     (site.pages_location, website_pages_location_on, docs/CLIENTS.md §6) —
#     включает lib/pages.sh вместе с первой страницей; подписки /s-<secret>/<суффикс>
#     (site.subs_location, website_subs_location_on, docs/SUBSCRIPTION.md) — только
#     сайт на домене с Let's Encrypt, включает lib/subs.sh вместе с первой подпиской;
#   • глушилка секретных путей (/p-, /s-, /a-, /r-, /d- + 43 знака, путь панели
#     app-…) без строки в журнале — всегда, в обоих вариантах, на 80 и на 443;
#   • опция Alt-Svc (options.alt_svc), по умолчанию выключена.
#
# Правила модуля (контракт §0):
#   • stdout — только результат и только у функций, где это сказано в шапке
#     (website_check, website_current_template, website_cert_expiry,
#     website_selfsigned_expiry, website_cert_fingerprint, website_deploy_template);
#     всё для человека — в stderr через log_*;
#   • ни одной видимой строки вне t/tf — словарь lib/lang/<lang>.d/website.sh;
#   • мутации — под ga_with_config_lock, пара fn() / _fn_locked(); коды ошибок
#     кладутся через ga_err (GA_ERR_CODE/GA_ERR_MSG), список — docs/PRO.md;
#   • GOAMNEZIA_DRY_RUN=1: ни apt, ни certbot, ни nginx, ни systemctl — команды
#     печатаются в stderr как «DRY: …»; конфиги пишутся в GOAMNEZIA_NGINX_DIR
#     и GOAMNEZIA_SITE_ROOT, если стенд их задал явно — так модуль целиком
#     проверяется на macOS/CI (tests/test_website_dryrun.sh). Самоподписанный
#     сертификат в dry-run создаётся по-настоящему (openssl — базовая
#     зависимость, а каталог GOAMNEZIA_DIR стенд задаёт всегда): так тесты
#     проверяют CN, SAN, права и отпечаток, а не строку «DRY».
#
# Библиотека шаблонов lib/templates_lib.sh и templates_catalog.json взяты из
# навыка site-templates-library как есть (решение владельца: база проверена,
# повторная проверка не нужна); здесь — только обёртки под наш неймспейс,
# config.json и коды причин для моста --action.
# ══════════════════════════════════════════════════════════════════════════════

_GA_WEBSITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Живой сертификат с таким запасом не перевыпускаем: правило владельца про
# лимиты Let's Encrypt (5 дублей в неделю — стенд уже сидел без сертификата).
# Тот же порог — для самоподписанного: его перевыпуск меняет отпечаток, по
# которому агентам MCP разрешён доступ (PLAN §6.10).
GA_SITE_CERT_MIN_DAYS=30
# Срок самоподписанного сертификата Lite + сайт (CONTRACT §3.1): 10 лет — это не
# сайт для людей, продлевать его некому и незачем.
GA_SITE_SELFSIGNED_DAYS=3650

# Сколько места требуем перед клоном шаблона сайта: .git самого тяжёлого
# шаблона каталога плюс распакованная копия, с запасом.
GA_SITE_MIN_DISK_MB=256

# За сколько дней до конца сертификата начинаем тревожить владельца. Порог выше
# GA_SITE_CERT_MIN_DAYS намеренно: certbot пытается продлить за 30 дней, и если
# к 21-му дню срок всё ещё не сдвинулся — автопродление сорвалось, а времени
# починить руками ещё три недели. Без этого сторожа сорвавшееся продление было
# невидимо до дня, когда разом умирают сайт, панель и транспорт агентов.
GA_SITE_CERT_WARN_DAYS=21

# ── Запасные помощники: модуль подключают и без lib/docker.sh ─────────────────
type ga_dry >/dev/null 2>&1 || ga_dry() { [ "${GOAMNEZIA_DRY_RUN:-0}" = "1" ]; }
# Аудит мутаций теми же именами, что у действий моста (как в lib/users.sh);
# секретный путь панели в подробности не попадает никогда.
ga_site_audit() {
    type ga_audit >/dev/null 2>&1 || return 0
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "$1" "${2:-}"
}
type ga_dry_echo >/dev/null 2>&1 || ga_dry_echo() { printf 'DRY: %s\n' "$*" >&2; }
if ! type ga_err >/dev/null 2>&1; then
    # ga_err <код> <сообщение> [rc] — те же поля, что читает _action_run в install.sh
    ga_err() {
        GA_ERR_CODE="$1"
        GA_ERR_MSG="$2"
        if declare -F ga_set_error >/dev/null 2>&1; then
            ga_set_error "$1"
        fi
        log_error "$2"
        return "${3:-1}"
    }
fi

# ── Пути: функциями, а не константами при source ──────────────────────────────
# Тесты и стенды меняют GOAMNEZIA_* уже после подключения модуля; константа,
# вычисленная при source, этого не увидела бы и писала в боевой /etc/nginx.
# Без переменной стенда конфиг и ссылка берутся из lib/common.sh
# (NGINX_SITE_CONF/NGINX_SITE_LINK) — те же пути читает lib/backup.sh.
ga_site_nginx_dir()   { printf '%s' "${GOAMNEZIA_NGINX_DIR:-/etc/nginx}"; }
ga_site_conf_path() {
    if [ -n "${GOAMNEZIA_NGINX_DIR:-}" ]; then
        printf '%s/sites-available/goamnezia' "$GOAMNEZIA_NGINX_DIR"
    else
        printf '%s' "${NGINX_SITE_CONF:-/etc/nginx/sites-available/goamnezia}"
    fi
}
ga_site_link_path() {
    if [ -n "${GOAMNEZIA_NGINX_DIR:-}" ]; then
        printf '%s/sites-enabled/goamnezia' "$GOAMNEZIA_NGINX_DIR"
    else
        printf '%s' "${NGINX_SITE_LINK:-/etc/nginx/sites-enabled/goamnezia}"
    fi
}
# Временный vhost проверки HTTP-01 — ОТДЕЛЬНЫМ файлом рядом с основным, чтобы
# выпуск сертификата на новый домен не трогал работающий конфиг (_ga_site_acme_vhost_on).
# Путь берём от основного, а не собираем заново: у конфига есть запасной путь из
# lib/common.sh (NGINX_SITE_CONF), и временный обязан лечь рядом с ним, а не в /etc/nginx.
ga_site_acme_conf_path() { printf '%s-acme' "$(ga_site_conf_path)"; }
ga_site_acme_link_path() { printf '%s-acme' "$(ga_site_link_path)"; }
ga_site_root()        { printf '%s' "${GOAMNEZIA_SITE_ROOT:-${SITE_ROOT:-/var/www/goamnezia-site}}"; }
ga_site_acme_root()   { printf '%s' "${GOAMNEZIA_ACME_ROOT:-/var/www/goamnezia-acme}"; }
ga_site_le_dir()      { printf '%s' "${GOAMNEZIA_LE_DIR:-/etc/letsencrypt}"; }
ga_site_systemd_dir() { printf '%s' "${GOAMNEZIA_SYSTEMD_DIR:-/etc/systemd/system}"; }
ga_site_tpl_path()    { printf '%s' "${GOAMNEZIA_NGINX_TPL:-$_GA_WEBSITE_DIR/nginx/goamnezia.conf.tpl}"; }
ga_site_catalog()     { printf '%s' "${GOAMNEZIA_CATALOG:-$_GA_WEBSITE_DIR/../templates_catalog.json}"; }
ga_site_cert_file()   { printf '%s/live/%s/fullchain.pem' "$(ga_site_le_dir)" "$1"; }
ga_site_key_file()    { printf '%s/live/%s/privkey.pem' "$(ga_site_le_dir)" "$1"; }
# Самоподписанный сертификат Lite + сайт (CONTRACT §3.1): /opt/goamnezia/tls —
# внутри каталога продукта, потому что это наш секрет, а не системный (бэкап и
# wipe знают только про GOAMNEZIA_DIR). GOAMNEZIA_TLS_DIR — переопределение стенда.
ga_site_tls_dir()     { printf '%s' "${GOAMNEZIA_TLS_DIR:-$GOAMNEZIA_DIR/tls}"; }
ga_site_ss_crt()      { printf '%s/site.crt' "$(ga_site_tls_dir)"; }
ga_site_ss_key()      { printf '%s/site.key' "$(ga_site_tls_dir)"; }

# В dry-run на диск пишем только туда, куда стенд указал явно: иначе прогон на
# машине разработчика создавал бы /etc/nginx, /var/www и /etc/systemd/system.
ga_site_fs_nginx_ok()   { ! ga_dry || [ -n "${GOAMNEZIA_NGINX_DIR:-}" ]; }
ga_site_fs_root_ok()    { ! ga_dry || [ -n "${GOAMNEZIA_SITE_ROOT:-}" ]; }
ga_site_fs_le_ok()      { ! ga_dry || [ -n "${GOAMNEZIA_LE_DIR:-}" ]; }
ga_site_fs_systemd_ok() { ! ga_dry || [ -n "${GOAMNEZIA_SYSTEMD_DIR:-}" ]; }
ga_site_fs_acme_ok()    { ! ga_dry || [ -n "${GOAMNEZIA_ACME_ROOT:-}" ]; }

# ga_site_run <команда…> — системная команда (apt, certbot, nginx, systemctl):
# в dry-run печатается и считается выполненной. ga_site_run_quiet — то же, но
# вывод команды глушится (DRY-строка при этом остаётся видимой).
ga_site_run() {
    if ga_dry; then ga_dry_echo "$*"; return 0; fi
    "$@"
}
ga_site_run_quiet() {
    if ga_dry; then ga_dry_echo "$*"; return 0; fi
    "$@" >/dev/null 2>&1
}

# ── Библиотека шаблонов ───────────────────────────────────────────────────────
if [ -f "$_GA_WEBSITE_DIR/templates_lib.sh" ]; then
    # shellcheck source=lib/templates_lib.sh
    source "$_GA_WEBSITE_DIR/templates_lib.sh"
fi

# CATALOG_FILE / WEBSITE_ROOT / TEMPLATES_LANG библиотека читает при вызове —
# выставляем перед каждым обращением, чтобы они шли за переменными стендов и
# за языком, выбранным уже после source.
ga_site_tpl_env() {
    CATALOG_FILE=$(ga_site_catalog)
    WEBSITE_ROOT=$(ga_site_root)
    TEMPLATES_LANG=ru
    if type get_language >/dev/null 2>&1; then
        TEMPLATES_LANG=$(get_language)
    fi
    [[ "$TEMPLATES_LANG" =~ ^(ru|en)$ ]] || TEMPLATES_LANG=ru
    return 0
}

ga_site_require_lib() {
    if type download_template >/dev/null 2>&1 && type deploy_template_to_nginx >/dev/null 2>&1; then
        return 0
    fi
    ga_err module_missing "$(t website_err_lib_missing)"
}

# ── Проверки входа ────────────────────────────────────────────────────────────
ga_site_check_domain() {
    local d="${1:-}"
    if [ "${#d}" -gt 253 ] || ! validate_domain "$d"; then
        ga_err invalid_domain "$(tf website_err_domain "$d")" 2
        return 2
    fi
    return 0
}

# ga_site_resolve_domain [домен] → GA_SITE_DOMAIN (аргумент или config.json, в
# нижнем регистре — он идёт в server_name и в путь /etc/letsencrypt/live/…).
# Результат в переменной, а не в stdout: через $(…) код ошибки терялся бы.
GA_SITE_DOMAIN=""
ga_site_resolve_domain() {
    local d="${1:-}"
    [ -n "$d" ] || d=$(ga_config_get .domain 2>/dev/null) || d=""
    d="${d,,}"
    if [ -z "$d" ]; then
        ga_err no_domain "$(t website_err_no_domain)" 2
        return 2
    fi
    ga_site_check_domain "$d" || return $?
    GA_SITE_DOMAIN="$d"
    return 0
}

# Путь панели: 6–64 символа латиницы, цифр, «-» и «_»; не начинается с «a-»,
# чтобы не пересечься с regex-локацией доступов агентов /a-<43 символа>/.
# Длина до 160 знаков: путь панели несёт 512 бит и в base64url занимает 86
# знаков плюс «app-», а прежний предел в 64 знака отверг бы его молча — с
# отказом «недопустимый путь» там, где путь сгенерировал сам продукт.
ga_site_panel_path_valid() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{5,159}$ ]] && [[ "${1:-}" != a-* ]]
}
# Идентификатор шаблона — как ID_RE в catalog_tool.py (в каталоге до 80 символов).
# «.» и «..» из набора исключены отдельно: идентификатор становится именем
# каталога в кэше (download_template: rm -rf "<кэш>/<id>"), и «..» означал бы
# снос каталога НАД кэшем. Сегодня до него не доходит только потому, что такого
# идентификатора нет в каталоге шаблонов, — но преграда обязана стоять там, где
# имя проверяется, а не там, где его случайно не нашли.
ga_site_template_id_valid() {
    [[ "${1:-}" =~ ^[A-Za-z0-9_.-]{1,120}$ ]] || return 1
    [ "$1" != "." ] && [ "$1" != ".." ]
}
# Режим из config.json; пусто и мусор читаем как lite — так безопаснее всего
ga_site_mode() {
    local m
    m=$(ga_config_get .mode 2>/dev/null) || m=""
    case "$m" in pro|lite_site) printf '%s' "$m" ;; *) printf 'lite' ;; esac
}
ga_site_pro_active() { [ "$(ga_site_mode)" = "pro" ]; }
# Сайт есть в pro и lite_site — там стоит nginx и есть куда применять настройки vhost
ga_site_has_site() { [ "$(ga_site_mode)" != "lite" ]; }

# Вид сертификата, которым сайт отдаётся СЕЙЧАС: letsencrypt | selfsigned | "".
# Раньше это выводилось из режима (pro → LE, lite_site → самоподписанный), но по
# уточнённому замыслу владельца домен и настоящий сертификат есть в ОБОИХ
# режимах с сайтом, а самоподписанный — запасной путь (домена нет или A-запись
# ещё не указывает на сервер). Поэтому спрашиваем сам признак.
# Пустое поле у режима с сайтом читаем как letsencrypt: так вели себя старые
# установки, где site.cert ещё не писался, и «неизвестно» не должно молча
# превращать домен в запасной путь.
ga_site_cert_kind() {
    local c
    c=$(ga_config_get .site.cert 2>/dev/null) || c=""
    case "$c" in
        letsencrypt|selfsigned) printf '%s' "$c" ;;
        *) if ga_site_has_site; then printf 'letsencrypt'; else printf ''; fi ;;
    esac
}
# Сайт живёт на домене с настоящим сертификатом (а не запасным самоподписанным)?
# По этому признаку решается всё, что требует доверенного TLS: панель на домене,
# адреса агентов на домене, ссылки в боте.
ga_site_domain_ready() {
    [ "$(ga_site_cert_kind)" = "letsencrypt" ] || return 1
    [ -n "$(ga_config_get .domain 2>/dev/null)" ]
}

# IP сервера для самоподписанного сертификата и адреса сайта: из config.json
# (мастер записал), иначе get_server_ip — но в dry-run без GOAMNEZIA_SERVER_IP в
# сеть не ходим (три таймаута curl на каждый вызов на стенде без интернета).
ga_site_server_ip() {
    local ip
    ip=$(ga_config_get .server_ip 2>/dev/null) || ip=""
    if [ -z "$ip" ] && { ! ga_dry || [ -n "${GOAMNEZIA_SERVER_IP:-}" ]; } && type get_server_ip >/dev/null 2>&1; then
        ip=$(get_server_ip 2>/dev/null) || ip=""
    fi
    [ "$ip" = "0.0.0.0" ] && ip=""
    if [ -n "$ip" ] && type _valid_ip >/dev/null 2>&1 && ! _valid_ip "$ip"; then ip=""; fi
    printf '%s' "$ip"
}

# ga_site_dns_a <домен> — первая A-запись домена в stdout (rc 1 — записи нет,
# dig не установлен или ответ не адрес). Отбор — по ЗНАЧЕНИЮ, функцией
# _valid_ip из lib/common.sh (CONTRACT §0.8): своя регулярка
# ^([0-9]{1,3}\.){3}[0-9]{1,3}$ пропускала «999.999.999.999», а сравнение
# такого «адреса» с адресом сервера молча давало вердикт dns_mismatch без
# причины. Отбор нужен и сам по себе: dig +short печатает всю цепочку CNAME.
ga_site_dns_a() {
    local line
    command -v dig >/dev/null 2>&1 || return 1
    while IFS= read -r line; do
        if _valid_ip "$line"; then
            printf '%s' "$line"
            return 0
        fi
    done < <(dig +short A "${1:-}" 2>/dev/null)
    return 1
}

# ── Домен с несколькими A-записями ────────────────────────────────────────────
# Как в goTelegram: у машины несколько внешних адресов, у домена по A-записи на
# каждый, и клиенты расходятся по адресам круговым DNS. Docker публикует порты
# профилей на все адреса машины, nginx слушает 80 и 443 на всех — сервер к этому
# готов без правок. Раньше продукт сравнивал с адресом сервера только ПЕРВУЮ
# A-запись: порядок в ответе DNS произвольный, и домен с двумя адресами этого же
# сервера то проходил проверку, то нет. Хуже того, по этому сравнению решалось,
# выпускать ли Let's Encrypt, и мастер молча уходил на самоподписанный.
#
# Теперь A-записи сравниваются НАБОРОМ с адресами машины: глобальные IPv4 на
# интерфейсах (ga_edge_list) плюс внешний адрес из config.json — за NAT своих
# внешних адресов машина на интерфейсах не видит. Состояние:
#   ok        — все A-записи ведут сюда (одна или несколько);
#   partial   — часть ведёт на чужие адреса: Let's Encrypt и часть клиентов
#               могут попасть на другую машину;
#   elsewhere — ни одна не ведёт сюда;
#   none      — A-записей нет;
#   unknown   — спросить не у кого (нет dig) или DNS не ответил.

# Кэш ответов DNS — для шапки меню и сторожа адресов: шапка перерисовывается раз
# в 30 секунд, и dig на каждом кадре без сети стоил бы секунд ожидания. Строка
# на пару «тип, домен» — у домена в ключах и у домена сайта свои записи, и они
# не вытесняют друг друга. Сбой DNS тоже кэшируется (на минуту), иначе без сети
# каждый кадр ждал бы таймаута. Отдельно хранится последний УДАЧНЫЙ ответ: им
# пользуется сторож адресов, когда DNS не ответил, — иначе на тике со сбоем
# доменные пользователи снова считались бы на каждом адресе и адрес, снятый из
# DNS, давал ложную тревогу «замолчал» (замечание критика).
# Формат строки: тип<TAB>домен<TAB>метка времени<TAB>ok|fail<TAB>адреса через пробел.
ga_site_dns_cache_file() { printf '%s/dns.cache' "${GOAMNEZIA_STATE_DIR:-$GOAMNEZIA_DIR/state}"; }
GA_SITE_DNS_FAIL_TTL="${GA_SITE_DNS_FAIL_TTL:-60}"

# _ga_site_dns_cache_get <ключ типа> <домен> → «метка<TAB>ok|fail<TAB>адреса» или пусто
_ga_site_dns_cache_get() {
    local f
    f=$(ga_site_dns_cache_file)
    [ -r "$f" ] || return 1
    awk -F'\t' -v t="$1" -v d="$2" '$1 == t && $2 == d { print $3 "\t" $4 "\t" $5; found = 1; exit } END { exit !found }' "$f" 2>/dev/null
}

# _ga_site_dns_cache_put <ключ типа> <домен> <ok|fail> <адреса> — атомарно
_ga_site_dns_cache_put() {
    local f tmp
    f=$(ga_site_dns_cache_file)
    [ -d "$(dirname "$f")" ] || return 0
    tmp=$(mktemp "${f}.XXXXXX" 2>/dev/null) || return 0
    {
        [ -r "$f" ] && awk -F'\t' -v t="$1" -v d="$2" '!($1 == t && $2 == d)' "$f" 2>/dev/null
        printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$(date +%s)" "$3" "$4"
    } 2>/dev/null >"$tmp" && chmod 600 "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
    return 0
}

# _ga_site_dig <A|AAAA> <домен> → «ok|fail<TAB>адреса через пробел». ok — сервер
# ответил (NOERROR или NXDOMAIN, адресов может и не быть); fail — SERVFAIL,
# REFUSED, таймаут. Раньше `dig +short` не отличал SERVFAIL от пустого ответа, и
# сбой резолвера выглядел как «у домена нет A-записи». Адреса — по значению:
# цепочка CNAME и мусор отбрасываются.
_ga_site_dig() {
    local type="$1" domain="$2" out rc st line ips=""
    out=$(dig +noall +comments +answer +time=2 +tries=2 "$type" "$domain" 2>/dev/null); rc=$?
    if [ "$rc" -ne 0 ]; then printf 'fail\t'; return 0; fi
    st=$(sed -n 's/.*status: \([A-Z]*\).*/\1/p' <<<"$out" | head -n 1)
    case "$st" in NOERROR|NXDOMAIN) ;; *) printf 'fail\t'; return 0 ;; esac
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ "$type" = A ]; then
            _valid_ip "$line" || continue
        else
            [[ "$line" =~ ^[0-9A-Fa-f:]+$ ]] && [[ "$line" == *:* ]] || continue
            line="${line,,}"
        fi
        ips+="$line"$'\n'
    done < <(awk -v t="$type" '$0 !~ /^;/ && $4 == t { print $5 }' <<<"$out")
    ips=$(printf '%s' "$ips" | sort -u | tr '\n' ' ')
    printf 'ok\t%s' "${ips% }"
}

# _ga_site_dns_lookup <A|AAAA> <домен> [кэш, секунд] [stale] — адреса по одному в
# строке. rc 0 — есть адреса; 1 — ответ получен, адресов нет; 2 — dig нет;
# 3 — DNS не ответил (с «stale» — отдаём последний удачный ответ, если был).
_ga_site_dns_lookup() {
    local type="$1" domain="${2:-}" ttl="${3:-0}" stale="${4:-}" c ts st list now res
    domain="${domain,,}"
    [ -n "$domain" ] || return 1
    # Стенд (dry-run) в сеть не ходит: ответ DNS — из GOAMNEZIA_DNS_STUB (A) и
    # GOAMNEZIA_DNS_STUB_AAAA (адреса через пробел, пусто — записей нет), а без
    # подставного ответа — «не знаем».
    if ga_dry; then
        if [ "$type" = A ]; then
            [ -n "${GOAMNEZIA_DNS_STUB+x}" ] || return 3
            list="$GOAMNEZIA_DNS_STUB"
        else
            [ -n "${GOAMNEZIA_DNS_STUB_AAAA+x}" ] || return 1
            list="$GOAMNEZIA_DNS_STUB_AAAA"
        fi
        [ -n "${list// /}" ] || return 1
        tr ' ' '\n' <<<"$list" | while IFS= read -r c; do
            [ -n "$c" ] || continue
            if [ "$type" = A ]; then _valid_ip "$c" && printf '%s\n' "$c"; else printf '%s\n' "${c,,}"; fi
        done | sort -u
        return 0
    fi
    command -v dig >/dev/null 2>&1 || return 2
    [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=0
    now=$(date +%s)
    if [ "$ttl" -gt 0 ] && c=$(_ga_site_dns_cache_get "$type" "$domain"); then
        IFS=$'\t' read -r ts st list <<<"$c"
        if [[ "$ts" =~ ^[0-9]+$ ]]; then
            if [ "$st" = ok ] && [ $((now - ts)) -lt "$ttl" ]; then
                [ -n "$list" ] || return 1
                tr ' ' '\n' <<<"$list"; return 0
            fi
            if [ "$st" = fail ] && [ $((now - ts)) -lt "$GA_SITE_DNS_FAIL_TTL" ]; then
                res=fail
            fi
        fi
    fi
    if [ "${res:-}" != fail ]; then
        res=$(_ga_site_dig "$type" "$domain")
        IFS=$'\t' read -r st list <<<"$res"
        if [ "$ttl" -gt 0 ] || [ "$type" = A ]; then
            _ga_site_dns_cache_put "$type" "$domain" "$st" "$list"
            [ "$st" = ok ] && _ga_site_dns_cache_put "${type}+ok" "$domain" ok "$list"
        fi
        if [ "$st" = ok ]; then
            [ -n "$list" ] || return 1
            tr ' ' '\n' <<<"$list"; return 0
        fi
    fi
    # DNS не ответил
    if [ "$stale" = stale ] && c=$(_ga_site_dns_cache_get "${type}+ok" "$domain"); then
        IFS=$'\t' read -r ts st list <<<"$c"
        [ -n "$list" ] || return 1
        tr ' ' '\n' <<<"$list"; return 0
    fi
    return 3
}

# ga_site_dns_a_all <домен> [кэш, секунд] [stale] — все A-записи домена, по одной
# в строке. Коды — как у _ga_site_dns_lookup.
ga_site_dns_a_all() { _ga_site_dns_lookup A "$@"; }

# ga_site_own_ips — внешние адреса машины, по одному в строке: глобальные IPv4 на
# интерфейсах и адрес сервера из config.json (за NAT своих внешних адресов
# машина на интерфейсах не видит).
ga_site_own_ips() {
    local ip
    {
        type ga_edge_list >/dev/null 2>&1 && ga_edge_list
        ga_site_server_ip
        echo
    } | while IFS= read -r ip; do
        [ -n "$ip" ] && _valid_ip "$ip" && printf '%s\n' "$ip"
    done | sort -u
}

# ga_site_own_ips6 — глобальные IPv6 машины (без ULA fc00::/7), по одному в строке
ga_site_own_ips6() {
    ga_dry && { printf '%s' "${GOAMNEZIA_OWN_IPS6_STUB:-}" | tr ' ' '\n' | sed '/^$/d'; return 0; }
    command -v ip >/dev/null 2>&1 || return 0
    ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
        | tr 'A-F' 'a-f' | grep -viE '^f[cd]' | sort -u
}

# Адреса Cloudflare (cloudflare.com/ips-v4). A-записи домена с включённым
# проксированием («оранжевое облако») показывают адреса Cloudflare, а не
# сервера: для VPN и сертификата запись должна быть «DNS only».
GA_SITE_CF_NETS="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
# IPv6 Cloudflare (cloudflare.com/ips-v6): у домена за прокси AAAA-записи — адреса самого Cloudflare, а не чужой
# сервер; считать их «AAAA не сюда» — ложная тревога (находка LZ-03 живой проверки 0.6.0).
GA_SITE_CF_NETS6="2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32"
_ga_site_ip2int() { local IFS=.; set -- $1; printf '%s' $(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 )); }
# ga_site_ip6_is_cloudflare <IPv6> — сети Cloudflare не короче /16 и не длиннее /32: первая группа — целиком,
# вторая — по маске. «2606::1» (вторая группа сжата) — это 2606:0:….
ga_site_ip6_is_cloudflare() {
    local ip="${1,,}" rest h1 h2 net nh1 nh2 len mask
    [[ "$ip" == *:* ]] || return 1
    h1="${ip%%:*}"; rest="${ip#*:}"; h2="${rest%%:*}"
    [ -n "$h2" ] || h2=0
    [[ "$h1" =~ ^[0-9a-f]{1,4}$ ]] && [[ "$h2" =~ ^[0-9a-f]{1,4}$ ]] || return 1
    for net in $GA_SITE_CF_NETS6; do
        len="${net#*/}"; nh1="${net%%:*}"; nh2="${net#*:}"; nh2="${nh2%%:*}"
        [ $((16#$h1)) -eq $((16#$nh1)) ] || continue
        mask=$(( (0xFFFF << (32 - len)) & 0xFFFF ))
        [ $(( 16#$h2 & mask )) -eq $(( 16#$nh2 & mask )) ] && return 0
    done
    return 1
}
ga_site_ip_is_cloudflare() {
    local ip="$1" n net len base mask
    _valid_ip "$ip" || return 1
    n=$(_ga_site_ip2int "$ip")
    for net in $GA_SITE_CF_NETS; do
        base=$(_ga_site_ip2int "${net%/*}"); len="${net#*/}"
        mask=$(( (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF ))
        [ $(( n & mask )) -eq $(( base & mask )) ] && return 0
    done
    return 1
}

# ga_site_dns_state <домен> [кэш, секунд] [stale] — stdout: JSON
# {domain, state, a, own, ours, foreign, unpublished, cloudflare, aaaa, aaaa_foreign}
# unpublished — адреса машины, которых нет в DNS домена (им клиенты по домену не
# достанутся); cloudflare — чужие адреса сплошь из сетей Cloudflare (включено
# проксирование); aaaa_foreign — AAAA-записи не на IPv6 этой машины (Let's Encrypt
# сначала пробует IPv6; у домена за прокси Cloudflare его IPv6 — не чужие). Своих адресов не узнать (NAT без
# внешнего адреса) — state unknown: сравнивать не с чем.
ga_site_dns_state() {
    local domain="${1:-}" ttl="${2:-0}" stale="${3:-}" a="" own own6 aaaa="" rc=0 f cf=true nf=0 cf6=""
    domain="${domain,,}"
    a=$(ga_site_dns_a_all "$domain" "$ttl" "$stale") || rc=$?
    own=$(ga_site_own_ips)
    [ -n "$own" ] || rc=3
    aaaa=$(_ga_site_dns_lookup AAAA "$domain" "$ttl") || aaaa=""
    own6=$(ga_site_own_ips6)
    # Все чужие A-записи из сетей Cloudflare — включено проксирование
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        grep -qxF -- "$f" <<<"$own" && continue
        nf=$((nf + 1))
        ga_site_ip_is_cloudflare "$f" || cf=false
    done <<<"$a"
    [ "$nf" -gt 0 ] || cf=false
    # За прокси Cloudflare его же IPv6 в AAAA — свои для прокси, не «AAAA не сюда» (LZ-03).
    if [ "$cf" = true ]; then
        while IFS= read -r f; do
            [ -n "$f" ] && ga_site_ip6_is_cloudflare "$f" && cf6+="$f"$'\n'
        done <<<"$aaaa"
    fi
    jq -cn --arg d "$domain" --arg a "$a" --arg own "$own" --argjson rc "$rc" --argjson cf "$cf" \
        --arg aaaa "$aaaa" --arg own6 "$own6" --arg cf6 "$cf6" '
        ($a | split("\n") | map(select(. != ""))) as $A
        | ($own | split("\n") | map(select(. != ""))) as $O
        | ($aaaa | split("\n") | map(select(. != ""))) as $A6
        | (($own6 | split("\n")) + ($cf6 | split("\n")) | map(select(. != ""))) as $O6
        | [$A[] | select(. as $x | any($O[]; . == $x))] as $ours
        | {domain: $d, a: $A, own: $O, ours: $ours,
           foreign: [$A[] | select(. as $x | any($ours[]; . == $x) | not)],
           unpublished: [$O[] | select(. as $x | any($A[]; . == $x) | not)],
           cloudflare: $cf,
           aaaa: $A6,
           aaaa_foreign: [$A6[] | select(. as $x | any($O6[]; . == $x) | not)],
           state: (if $rc == 2 or $rc == 3 then "unknown"
                   elif ($A | length) == 0 then "none"
                   elif ($ours | length) == 0 then "elsewhere"
                   elif ($ours | length) < ($A | length) then "partial"
                   else "ok" end)}'
}

# Список адресов для текста: «1.2.3.4, 5.6.7.8» (из JSON-массива в поле <поле>)
ga_site_dns_list() { jq -r "(${2:-.a}) | join(\", \")" <<<"${1:-}" 2>/dev/null; }

# website_dns_hint <домен> — подсказка про DNS словами (stderr), не отказ: DNS мог
# не разойтись, а certbot скажет точно. Одна на мастер, экран режима, смену
# домена и включение сайта — раньше в четырёх местах жили четыре копии сравнения
# «первая A-запись против адреса сервера». rc 0 — хоть одна A-запись ведёт сюда.
website_dns_hint() {
    local domain="${1:-}" js st rc=1
    [ -n "$domain" ] || return 1
    js=$(ga_site_dns_state "$domain") || return 1
    st=$(jq -r '.state' <<<"$js" 2>/dev/null)
    case "$st" in
        ok)
            if [ "$(jq -r '.a | length' <<<"$js" 2>/dev/null)" -gt 1 ]; then
                log_dim "$(tf website_dns_multi "$domain" "$(ga_site_dns_list "$js" .a)")"
            fi
            rc=0 ;;
        partial|elsewhere)
            if [ "$(jq -r '.cloudflare' <<<"$js" 2>/dev/null)" = true ]; then
                log_warning "$(tf website_dns_cloudflare "$domain")"
            elif [ "$st" = partial ]; then
                log_warning "$(tf website_dns_partial "$domain" "$(ga_site_dns_list "$js" .foreign)" "$(ga_site_dns_list "$js" .own)")"
            else
                log_warning "$(tf website_dns_warn "$domain" "$(ga_site_dns_list "$js" .a)" "$(ga_site_dns_list "$js" .own)")"
            fi
            [ "$st" = partial ] && rc=0 ;;
        none)
            log_warning "$(tf website_dns_none "$domain")" ;;
        *)
            log_dim "$(tf website_dns_unknown "$domain")" ;;
    esac
    # AAAA на чужой IPv6: Let's Encrypt сначала пробует IPv6 и откажет, а
    # A-записи при этом могут быть в полном порядке (замечание критика).
    if [ "$(jq -r '(.aaaa_foreign // []) | length' <<<"$js" 2>/dev/null)" -gt 0 ]; then
        log_warning "$(tf website_dns_aaaa "$domain" "$(ga_site_dns_list "$js" .aaaa_foreign)")"
    fi
    # Про этот домен уже сказано: включение сайта следом (тот же процесс SSH-меню) второй раз не повторяет
    # (TAIL-2: «Домен … указывает на несколько адресов» шло дважды — до вопроса и после «Поднимаю сайт»).
    GA_SITE_DNS_HINTED="$domain"
    return $rc
}
GA_SITE_DNS_HINTED=""

# _website_dns_words <JSON ga_site_dns_state> — подсказка про DNS одной строкой: те же слова (ключи словаря), что
# website_dns_hint печатает в SSH, но без печати — для ответа моста.
_website_dns_words() {
    local js="$1" domain st out=""
    domain=$(jq -r '.domain // ""' <<<"$js" 2>/dev/null)
    st=$(jq -r '.state // "unknown"' <<<"$js" 2>/dev/null)
    case "$st" in
        ok)
            if [ "$(jq -r '.a | length' <<<"$js" 2>/dev/null)" -gt 1 ]; then
                out=$(tf website_dns_multi "$domain" "$(ga_site_dns_list "$js" .a)")
            fi ;;
        partial|elsewhere)
            if [ "$(jq -r '.cloudflare' <<<"$js" 2>/dev/null)" = true ]; then
                out=$(tf website_dns_cloudflare "$domain")
            elif [ "$st" = partial ]; then
                out=$(tf website_dns_partial "$domain" "$(ga_site_dns_list "$js" .foreign)" "$(ga_site_dns_list "$js" .own)")
            else
                out=$(tf website_dns_warn "$domain" "$(ga_site_dns_list "$js" .a)" "$(ga_site_dns_list "$js" .own)")
            fi ;;
        none) out=$(tf website_dns_none "$domain") ;;
        *)    out=$(tf website_dns_unknown "$domain") ;;
    esac
    if [ "$(jq -r '(.aaaa_foreign // []) | length' <<<"$js" 2>/dev/null)" -gt 0 ]; then
        out="${out:+$out }$(tf website_dns_aaaa "$domain" "$(ga_site_dns_list "$js" .aaaa_foreign)")"
    fi
    printf '%s' "$out"
}

# website_domain_check <домен> — A и AAAA НОВОГО домена против адресов машины ДО смены режима или домена (L-09):
# мастер «Режим и сайт» и экраны редизайна проверяют домен, пока ничего не изменено. Только чтение — DNS-запрос,
# ничего не пишет и не выпускает (site-check проверяет только уже записанный домен). stdout: ga_site_dns_state
# ({domain, state, a, own, ours, foreign, unpublished, cloudflare, aaaa, aaaa_foreign}) + ready — домен годится
# для Let's Encrypt прямо сейчас (все A-записи сюда, без проксирования Cloudflare, без AAAA на чужой IPv6) — и
# hint (слова website_dns_hint). Недопустимый домен — invalid_domain.
website_domain_check() {
    local domain="${1:-}" js
    domain="${domain,,}"
    if ! validate_domain "$domain"; then
        ga_err invalid_domain "$(tf website_err_domain "$domain")" 2
        return 2
    fi
    js=$(ga_site_dns_state "$domain") || js=""
    if [ -z "$js" ] || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$js"; then
        ga_err dns_failed "$(tf website_dns_unknown "$domain")"
        return 1
    fi
    jq -c --arg hint "$(_website_dns_words "$js")" \
        '. + {ready: (.state == "ok" and .cloudflare != true and ((.aaaa_foreign // []) | length) == 0), hint: $hint}' \
        <<<"$js"
}

# on/off/true/false/1/0 → true|false (в config.json храним булево)
_ga_site_toggle() {
    case "${1,,}" in
        on|true|1|yes)  printf 'true' ;;
        off|false|0|no) printf 'false' ;;
        *) return 1 ;;
    esac
}
_ga_site_onoff() { if [ "${1:-}" = "true" ]; then t website_on; else t website_off; fi; }

# ══════════════════════════════════════════════════════════════════════════════
#  nginx: установка, проверка конфига, перезагрузка
# ══════════════════════════════════════════════════════════════════════════════
website_ensure_nginx() {
    if ! command -v nginx >/dev/null 2>&1 || { type _deps_check_cmd >/dev/null 2>&1 && ! _deps_check_cmd nginx; }; then
        log_info "$(t website_nginx_installing)"
        if ga_dry; then
            ga_dry_echo "apt-get install -y nginx"
        elif type deps_install_missing >/dev/null 2>&1; then
            # Профиль web из lib/deps.sh: тот же путь, что у мастера установки
            deps_install_missing --yes web || { ga_err nginx_install_failed "$(t website_err_nginx_install)"; return 1; }
        else
            apt_install nginx || { ga_err nginx_install_failed "$(t website_err_nginx_install)"; return 1; }
        fi
        if ! ga_dry && ! command -v nginx >/dev/null 2>&1; then
            ga_err nginx_install_failed "$(t website_err_nginx_install)"
            return 1
        fi
    fi
    local ndir
    ndir=$(ga_site_nginx_dir)
    if ga_site_fs_nginx_ok; then
        mkdir -p "$ndir/sites-available" "$ndir/sites-enabled" 2>/dev/null \
            || { ga_err nginx_dir_failed "$(tf website_err_nginx_dir "$ndir")"; return 1; }
        # default-сайт Debian слушает 80 как default_server и перехватывал бы
        # проверку Let's Encrypt для домена, пока наш vhost ещё не записан.
        rm -f "$ndir/sites-enabled/default" 2>/dev/null || true
    else
        ga_dry_echo "mkdir -p $ndir/sites-available $ndir/sites-enabled; rm -f $ndir/sites-enabled/default"
    fi
    ga_site_run_quiet systemctl enable --now nginx || log_warning "$(t website_warn_nginx_enable)"
    return 0
}

website_ensure_certbot() {
    if command -v certbot >/dev/null 2>&1; then
        if ! type _deps_check_cmd >/dev/null 2>&1 || _deps_check_cmd certbot; then return 0; fi
    fi
    log_info "$(t website_certbot_installing)"
    if ga_dry; then
        ga_dry_echo "apt-get install -y certbot"
        return 0
    fi
    if type deps_install_missing >/dev/null 2>&1; then
        deps_install_missing --yes tls || { ga_err certbot_install_failed "$(t website_err_certbot_install)"; return 1; }
    else
        apt_install certbot || { ga_err certbot_install_failed "$(t website_err_certbot_install)"; return 1; }
    fi
    command -v certbot >/dev/null 2>&1 || { ga_err certbot_install_failed "$(t website_err_certbot_install)"; return 1; }
    return 0
}

ga_site_nginx_test() {
    if ga_dry; then ga_dry_echo "nginx -t"; return 0; fi
    command -v nginx >/dev/null 2>&1 || return 1
    local err
    err=$(mktemp "${TMPDIR:-/tmp}/goamnezia_nginx_t.XXXXXXXX" 2>/dev/null) || err=/dev/null
    if nginx -t >"$err" 2>&1; then
        [ "$err" = /dev/null ] || rm -f "$err"
        return 0
    fi
    # Причину показываем сразу: «nginx -t отверг конфиг» без хвоста вывода
    # заставляло идти на сервер и повторять команду руками.
    if [ -s "$err" ]; then tail -n 5 "$err" | sed 's/^/      /' >&2; fi
    [ "$err" = /dev/null ] || rm -f "$err"
    return 1
}

ga_site_nginx_reload() {
    if ga_dry; then ga_dry_echo "systemctl reload nginx"; return 0; fi
    if systemctl is-active --quiet nginx 2>/dev/null; then
        systemctl reload nginx >/dev/null 2>&1 && return 0
    else
        systemctl start nginx >/dev/null 2>&1 && return 0
    fi
    ga_err nginx_reload_failed "$(t website_err_nginx_reload)"
}

# nginx «жив»: в dry-run — когда наш vhost записан (детерминированно для тестов)
ga_site_nginx_active() {
    if ga_dry; then
        [ -f "$(ga_site_conf_path)" ]
        return $?
    fi
    systemctl is-active --quiet nginx 2>/dev/null
}

# IPv6-слушатели только там, где стек включён: на VPS с disable_ipv6=1 nginx
# не поднимается вовсе («Address family not supported» на [::]:80). В dry-run
# (macOS, /proc нет) — без них, чтобы конфиг в тестах был воспроизводимым.
_ga_site_ipv6() {
    ga_dry && return 1
    [ -s /proc/net/if_inet6 ]
}

# nginx ≥ 1.25.1 хочет отдельную директиву «http2 on;» и ругается на параметр
# listen … http2 (deprecated); Ubuntu 24.04 несёт 1.24, где директивы ещё нет.
_ga_site_http2_directive() {
    ga_dry && return 1
    command -v nginx >/dev/null 2>&1 || return 1
    local v
    v=$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9][0-9.]*\).*|\1|p')
    [[ "$v" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 1
    local maj="${BASH_REMATCH[1]}" min="${BASH_REMATCH[2]}" pat="${BASH_REMATCH[3]}"
    [ "$maj" -gt 1 ] && return 0
    [ "$maj" -eq 1 ] || return 1
    [ "$min" -gt 25 ] && return 0
    [ "$min" -eq 25 ] && [ "$pat" -ge 1 ]
}

# ══════════════════════════════════════════════════════════════════════════════
#  Сборка vhost из шаблона
# ══════════════════════════════════════════════════════════════════════════════
# _ga_site_listen_block — блок listen HTTPS-сервера. Режим один: публичный
# TCP/443 (и [::]:443, если есть IPv6). Прятать сайт на localhost не для кого:
# TCP-протоколов, которым понадобился бы публичный 443, у продукта нет.
_ga_site_listen_block() {
    local h2="" post=""
    if _ga_site_http2_directive; then
        post=$'\n    http2 on;'
    else
        h2=" http2"
    fi
    printf '    listen 443 ssl%s;' "$h2"
    if _ga_site_ipv6; then printf '\n    listen [::]:443 ssl%s;' "$h2"; fi
    printf '%s' "$post"
}

_ga_site_alt_svc_block() {
    [ "$(ga_config_get .options.alt_svc 2>/dev/null)" = "true" ] || return 0
    printf "    add_header Alt-Svc 'h3=\":443\"; ma=86400' always;"
}

_ga_site_panel_block() {
    local path port
    path=$(ga_config_get .panel.miniapp_path 2>/dev/null) || path=""
    [ -n "$path" ] || return 0
    # Испорченное значение в config.json не должно ронять nginx -t всего сервера
    ga_site_panel_path_valid "$path" || return 0
    port=$(ga_config_get .panel.port 2>/dev/null) || port=""
    [[ "$port" =~ ^[0-9]{2,5}$ ]] || port="${ADMIN_PORT:-1985}"
    cat <<EOPANEL
    location ^~ /${path}/ {
        proxy_pass http://127.0.0.1:${port}/;
        # Панель держит строгий allowlist Host (защита от DNS-rebinding при
        # прямом обращении): проксируем под её собственным именем, а реальный
        # домен отдаём отдельным заголовком — иначе она отвечает 403.
        proxy_set_header Host 127.0.0.1:${port};
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_http_version 1.1;
        # Долгие действия панели (установка профиля, обновление ядра) идут до
        # 900 с, и браузер ждёт их 920 с. С прежними 60 с nginx отвечал 504,
        # пока действие продолжалось на сервере (найдено при составлении карты
        # проекта 24.09.2026).
        proxy_read_timeout 930s;
        proxy_send_timeout 930s;
        # Telegram Web открывает мини-апп в iframe — SAMEORIGIN его убьёт
        proxy_hide_header X-Frame-Options;
        add_header X-Frame-Options "" always;
        access_log off;
        # access_log off не закрывает error_log: при перезапуске службы nginx писал бы
        # «connect() failed … request: GET /app-<секрет>/» (находка SR-12, как у страниц).
        error_log /dev/null crit;
    }
EOPANEL
}

_ga_site_mcp_block() {
    local port
    [ "$(ga_config_get .site.mcp_location 2>/dev/null)" = "true" ] || return 0
    port=$(ga_config_get .mcp.http_port 2>/dev/null) || port=""
    [[ "$port" =~ ^[0-9]{2,5}$ ]] || port="${MCP_HTTP_PORT:-1986}"
    # Регулярку ОБЯЗАТЕЛЬНО в кавычках: `{` и `}` для nginx — границы блока, и
    # незакавыченный квантификатор {43} обрывал директиву — «unknown directive
    # "43}/"», nginx -t отвергал конфиг, и mcp-http-on не включался вовсе.
    # /a- — неподвижные адреса доступов и привязка переходника (/a-<отпечаток кода>/enroll),
    # /r- — плавающий путь переходника (docs/MCP_ROTATION.md §2).
    cat <<EOMCP
    location ~ "^/[ar]-[A-Za-z0-9_-]{43}/" {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        # Адрес агента сервер читает из этих заголовков только с петли (CONTRACT §5.1)
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        # tools/call ждёт ответа моста до 300 с
        proxy_read_timeout 310s;
        client_max_body_size 1m;
        access_log off;
        # У доступа без токена путь /a-<43>/ и есть весь ключ — в error.log ему не место (SR-12).
        error_log /dev/null crit;
        # Служба агентов лежит — снаружи обычный 404 сайта, а не 502 nginx: по нему одним
        # запросом было видно, что за сайтом стоит goAmnezia (находка LS-05). Сам сервер MCP
        # кодов 502 и 504 не отдаёт, поэтому перехват не прячет его ответов. 503 здесь нет нарочно:
        # его отдаёт сервер MCP «замок занят, повторите» — и только после верного пути и ключа
        # (SEC46-01); сам nginx в этой локации 503 не шлёт. В 404 он превращался бы в «доступ отозван».
        proxy_intercept_errors on;
        error_page 502 504 =404 @ga_mcp_down;
    }
    location @ga_mcp_down {
        # Запрос, закончившийся здесь, nginx пишет в access.log ЭТОЙ локации — с секретным путём
        # (/p-…, /a-…). Без access_log off адрес-ключ оседал в системном журнале при каждом сбое службы.
        access_log off;
        error_log /dev/null crit;
        return 404;
    }
EOMCP
}

# Страницы подключения (docs/CLIENTS.md §6, lib/pages.sh): путь /p-<секрет>/
# проксируется на службу goamnezia-pages (pages.port, по умолчанию 1987).
# Регулярка в кавычках по той же причине, что у _ga_site_mcp_block: `{43}`
# без кавычек nginx читает как конец блока. 404 службы и ошибки 502/504
# перехватываются и отдаются как 404 сайта — остановленная служба и чужой
# секрет не должны отличаться от «такого пути нет». Именованная локация
# @ga_pages_down нужна ради этого: `return 404` в ней отдаёт стандартную
# страницу nginx, а своих add_header у неё нет — заголовки те же, что у 404
# сайта (SEC-G4). /_ga_mirror/ — только internal: сюда попадают лишь по
# X-Accel-Redirect от службы (сам файл отдаёт nginx, а решает, кому и что, —
# служба), снаружи путь отвечает 404. Каталог зеркала — тот же, что у
# lib/mirror.sh (GOAMNEZIA_MIRROR_DIR на стенде). Первый аргумент — вариант
# vhost (pro | selfsigned): HSTS только на доверенном сертификате, как у сайта.
_ga_site_pages_block() {
    local port variant="${1:-pro}" hsts=""
    [ "$(ga_config_get .site.pages_location 2>/dev/null)" = "true" ] || return 0
    port=$(ga_config_get .pages.port 2>/dev/null) || port=""
    [[ "$port" =~ ^[0-9]{2,5}$ ]] || port="${GA_PAGES_PORT_DEFAULT:-1987}"
    [ "$variant" = "pro" ] && hsts=$'\n        add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;'
    cat <<EOPAGES
    location ~ "^/p-[A-Za-z0-9_-]{43}(/.*)?$" {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        # Адрес посетителя служба читает из этих заголовков только с петли
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_intercept_errors on;
        # 404 службы (чужой секрет, отозванная страница, бан) nginx заменяет своим: тело, заголовки и их
        # порядок — как у 404 любого пути сайта. Своими add_header ниже (DENY, no-referrer) 404 службы
        # выделялся среди 404 сайта (SAMEORIGIN, strict-origin-when-cross-origin) — находка SEC-G4.
        # 503 здесь нет нарочно: его отдаёт служба «мост занят, попробуйте ещё раз» и только после верного
        # секрета; сам nginx 503 не шлёт — отказы limit_req/limit_conn ниже сделаны 404.
        error_page 404 502 504 =404 @ga_pages_down;
        # Всплеск запросов (перебор секретов, чужой скрипт по живой ссылке) гасит сам nginx, не доходя до
        # службы и её моста: зоны — в начале vhost (goamnezia_pages, goamnezia_pages_conn). Отказ — тот же
        # 404, что у сайта. Запас рассчитан на человека: страница, app.js, keys.json и пачка QR разом.
        limit_req zone=goamnezia_pages burst=40 nodelay;
        limit_req_status 404;
        limit_conn goamnezia_pages_conn 16;
        limit_conn_status 404;
        proxy_read_timeout 120s;
        client_max_body_size 4k;
        # Заголовки безопасности — ровно по одному и строже, чем у сайта (docs/CLIENTS.md §7): служба
        # шлёт свои, а серверные add_header наследовались поверх — по два противоречивых X-Frame-Options и
        # Referrer-Policy, и браузер брал мягкий (находка LS-15). Свой add_header здесь отключает наследование.
        # К 404 они не относятся: его отдаёт @ga_pages_down с заголовками сайта.
        proxy_hide_header X-Frame-Options;
        proxy_hide_header Referrer-Policy;
        proxy_hide_header X-Content-Type-Options;
        add_header X-Frame-Options "DENY" always;
        add_header Referrer-Policy "no-referrer" always;
        add_header X-Content-Type-Options "nosniff" always;${hsts}
        access_log off;
        # access_log off не закрывает error_log: при упавшей службе nginx
        # писал бы «connect() failed … request: GET /p-<секрет>/» в error.log
        error_log /dev/null crit;
    }
    location @ga_pages_down {
        # Запрос, закончившийся здесь, nginx пишет в access.log ЭТОЙ локации — с секретным путём
        # (/p-…, /a-…). Без access_log off адрес-ключ оседал в системном журнале при каждом сбое службы.
        # Ни add_header, ни expires здесь быть не должно: заголовки 404 наследуются с уровня server —
        # ровно те же, что у 404 сайта (SEC-G4, проверяет tests/test_pages_dryrun.sh).
        access_log off;
        error_log /dev/null crit;
        return 404;
    }
    location ^~ /_ga_mirror/ {
        internal;
        alias ${GOAMNEZIA_MIRROR_DIR:-$GOAMNEZIA_DIR/mirror}/;
        access_log off;
        error_log /dev/null crit;
    }
EOPAGES
}

# Зоны для limit_req/limit_conn локации страниц (SEC-G1): только уровень http, поэтому — отдельной
# вставкой в начало vhost, а не в блок локации. Пишутся лишь вместе с самой локацией: без неё
# зоны не нужны, а limit_req без зоны nginx -t не пропустит. 5 запросов в секунду с адреса с запасом
# 40 (в локации) — человеку с телефона хватает с избытком, перебору и чужому скрипту — нет.
_ga_site_pages_zones() {
    [ "$(ga_config_get .site.pages_location 2>/dev/null)" = "true" ] || return 0
    cat <<'EOZONES'
limit_req_zone $binary_remote_addr zone=goamnezia_pages:1m rate=5r/s;
limit_conn_zone $binary_remote_addr zone=goamnezia_pages_conn:1m;
EOZONES
}

# Подписки (docs/SUBSCRIPTION.md, lib/subs.sh): /s-<секрет>/<суффикс> → та же служба goamnezia-pages
# (pages.port). Только вариант pro — домен с сертификатом Let's Encrypt: адрес забирают роутер и приложение
# (Clash, WG Tunnel, Keenetic), исключение для сертификата им не сделать. Суффиксы — белым списком уже здесь
# (служба проверяет его ещё раз); новый суффикс доезжает до поставленных серверов сам: vhost из шаблона пересобирает
# миграция (_migrate_site_vhost в install.sh) — и при новой версии, и при новом коде той же версии по отпечатку (UP-7).
# Остальное — как у страниц: 404, 502 и 504 службы → 404 сайта (@ga_subs_down,
# заголовки уровня server — SEC-G4), 503 «мост занят» проходит как есть (только после верного секрета); свой предел
# запросов — роутеры и клиенты забирают подписку раз в часы, человек в браузере — несколько адресов подряд, а
# перебору и чужому скрипту хватит и этого. Любой другой путь под /s-<43> (и все они, пока подписок нет) — глушилка
# секретных путей ниже (_ga_site_secret_paths_block).
_ga_site_subs_block() {
    if [ "$(ga_config_get .site.subs_location 2>/dev/null)" = "true" ] && [ "${1:-pro}" = "pro" ]; then
        _ga_site_subs_proxy_block
    fi
    return 0
}

# Глушилка секретных путей. Сам путь — ключ: страницы /p-, подписки /s-, доступы агентов /a- и плавающий путь
# переходника /r-, временная раздача /d- (у неё свой порт, но ссылку, набранную без порта, nginx получит здесь) —
# 43 знака base64url; панель — app-<86 знаков> (ga_site_panel_path_new), app-<128 hex> (его запасной генератор) и
# app-<12 hex> прежних версий. Живой маршрут есть не всегда: страниц, подписок и агентов может не быть, панель
# выключают, адрес отзывают и перевыпускают, а секрет бывает чужим. Такой путь без живого маршрута раньше доходил до
# location / сайта и ложился в access.log с ключом (живая проверка подписки 03.10.2026: забор по отозванному адресу),
# а по http:// — ещё и при живом маршруте: редирект на HTTPS пишется в журнал с полным путём, и роутер с адресом
# http://… оставлял бы его там при каждом обновлении. Теперь в vhost всегда, в обоих вариантах и в обоих server,
# стоит одна локация на все эти пути: ответ тот же, что у любого пути этого server (на 80 в pro — редирект на HTTPS,
# как location / там; иначе — 404 сайта: своих add_header нет, заголовки уровня server — SEC-G4), и ни строки в
# журнале. На 443 она стоит ПОСЛЕ живых регулярных локаций агентов, страниц и подписок (nginx проверяет регулярки по
# порядку) и ДО регулярок сайта; живой путь панели — префикс ^~, до регулярок не доходит. Хвост (/|$) — чтобы не
# задеть файлы шаблона сайта с длинными именами вроде /a-…-photography-and-lighting.html.
GA_SITE_SECRET_PATHS_RE='^/([adprs]-[A-Za-z0-9_-]{43}|app-([A-Za-z0-9_-]{86}|[0-9a-f]{128}|[0-9a-f]{12}))(/|$)'
# _ga_site_secret_paths_block <pro|selfsigned|http> <80|443>
_ga_site_secret_paths_block() {
    local answer='return 404;'
    if [ "${1:-pro}" = "pro" ] && [ "${2:-443}" = "80" ]; then
        # shellcheck disable=SC2016  # переменные nginx, не bash
        answer='return 301 https://$server_name$request_uri;'
    fi
    printf '    location ~ "%s" {\n        access_log off;\n        error_log /dev/null crit;\n        %s\n    }\n' \
        "$GA_SITE_SECRET_PATHS_RE" "$answer"
}
_ga_site_subs_proxy_block() {
    local port
    port=$(ga_config_get .pages.port 2>/dev/null) || port=""
    [[ "$port" =~ ^[0-9]{2,5}$ ]] || port="${GA_PAGES_PORT_DEFAULT:-1987}"
    cat <<EOSUBS
    location ~ "^/s-[A-Za-z0-9_-]{43}/((awg(10|15|20|31)|awgv(15|2|3))\.(conf|vpn)|all\.(vpn|txt|yaml)|mihomo\.yaml)$" {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        # Адрес забиравшего служба читает из этих заголовков только с петли (бан перебора, без записи на диск)
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_intercept_errors on;
        error_page 404 502 504 =404 @ga_subs_down;
        limit_req zone=goamnezia_subs burst=10 nodelay;
        limit_req_status 404;
        limit_conn goamnezia_subs_conn 4;
        limit_conn_status 404;
        proxy_read_timeout 120s;
        client_max_body_size 1k;
        # Заголовки безопасности — по одному: свои add_header отключают наследование серверных (LS-15).
        proxy_hide_header X-Frame-Options;
        proxy_hide_header Referrer-Policy;
        proxy_hide_header X-Content-Type-Options;
        add_header X-Frame-Options "DENY" always;
        add_header Referrer-Policy "no-referrer" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
        access_log off;
        # access_log off не закрывает error_log: отказ limit_req и упавшая служба оставили бы путь с секретом там.
        error_log /dev/null crit;
    }
    location @ga_subs_down {
        # Без своих add_header: заголовки 404 — уровня server, как у 404 сайта (SEC-G4).
        access_log off;
        error_log /dev/null crit;
        return 404;
    }
EOSUBS
    _ga_site_short_block "$port"
}

# Короткие ссылки подписки с 2FA через Telegram-бота (lib/shortlinks.py, docs/SUBSCRIPTION.md §11): путь /<КОД> —
# 8–14 знаков [0-9A-Za-z -] (8 знаков кода и до 3 тире при показе — или пробелов, %20, если человек набрал их вместо
# тире; без учёта регистра) в обрамлении копирования из мессенджера и разметки: до 3 знаков в начале и до 6 в конце
# («(КОД)», «[КОД]», ««КОД»», «“КОД”», «*КОД*», «_КОД_», «`КОД`», «<КОД>», «:КОД», «КОД.», «КОД%20», «КОД%09», «КОД•»
# — GA_SITE_SHORT_FRAME, набор shortlinks.FRAME; nginx сравнивает раскодированный путь побайтно и без UTF-8, поэтому
# неразрывный пробел, « и » — C2 A0/AB/BB, – — ‘ ’ “ ” „ • … — E2 80 93/94/98/99/9C/9D/9E/A2/A6; кавычки, таб и
# обратный апостроф — \x22 \x27 \x09 \x60, чтобы не спорить с разбором строк nginx), можно с косой в конце: такой код
# не уходит в location / с полной строкой в access.log, а служба снимает обрамление при нормализации. «/.КОД» — своя
# локация (GA_SITE_SHORT_DOT_RE): скрытые файлы сайт не отдаёт (location ~ /\. — 403 и строка в error.log), поэтому
# точки снимает rewrite и путь ищется заново — try_files не дойдёт до скрытого файла. Хотя бы одна цифра и не меньше двух букв, которые остаются буквами
# после нормализации (без O, I, L — они читаются как 0 и 1 — и без U, которой в алфавите нет). У выданного кода цифр и
# букв всегда не меньше двух, и честный ввод их не теряет; слова сайта (/download, /wp-admin), даты и номера
# (/2024-10-01, /12345678) уходят в location / как любой путь сайта, служба их и не видит (а дошедшие — решает она:
# shortlinks.as_code). Сначала — файлы сайта-маскировки (try_files, как у location /: страница сайта с таким именем
# отдаётся как прежде), и только потом — служба страниц.
# Стоит вместе с маршрутом подписок: без подписок кодов нет. Работают ли короткие ссылки (бот настроен), решает служба —
# иначе 404, как у любого пути сайта. Код — тот же секрет, что адрес: ни строки в журналах (access_log off и в
# именованных локациях — запрос пишется в журнал той, где закончился); роботам превью — 404 сразу (карта
# $ga_short_bot в начале vhost, правило — PREVIEW_RE службы); 404, 502 и 504 службы → 404 сайта (@ga_short_down,
# заголовки уровня server — SEC-G4); свой предел запросов. Регулярка не задевает ни секретные пути (/p-, /s-, /a-…
# — 45 знаков и длиннее), ни файлы с расширением (/index.html, /logo.png: после точки — буквы, а не хвост).
GA_SITE_SHORT_FRAME='(?:[\x09 !\x22\x27(),.:;<>?\[\]_\x60{}~*+]|\xC2[\xA0\xAB\xBB]|\xE2\x80[\x93\x94\x98\x99\x9C\x9D\x9E\xA2\xA6])'
GA_SITE_SHORT_CODE_RE="${GA_SITE_SHORT_FRAME}{0,3}"'(?=[A-Za-z -]*[0-9])'\
'(?=(?:[^A-HJKMNP-TV-Za-hjkmnp-tv-z]*[A-HJKMNP-TV-Za-hjkmnp-tv-z]){2})[0-9A-Za-z -]{8,14}'"${GA_SITE_SHORT_FRAME}"'{0,6}/?$'
GA_SITE_SHORT_PATH_RE='^/(?!\.)'"$GA_SITE_SHORT_CODE_RE"     # 443: код — сначала файлы сайта, потом служба
GA_SITE_SHORT_DOT_RE='^/\.'"$GA_SITE_SHORT_CODE_RE"          # 443: «/.КОД» — точки снимает rewrite
GA_SITE_SHORT_HTTP_RE='^/\.?'"$GA_SITE_SHORT_CODE_RE"        # 80: всё это — редирект на HTTPS без журнала
_ga_site_short_block() {
    local port="${1:-${GA_PAGES_PORT_DEFAULT:-1987}}"
    cat <<EOSHORT
    location ~ "${GA_SITE_SHORT_PATH_RE}" {
        access_log off;
        error_log /dev/null crit;
        try_files \$uri \$uri/ @ga_short;
        expires -1;
    }
    location ~ "${GA_SITE_SHORT_DOT_RE}" {
        access_log off;
        error_log /dev/null crit;
        rewrite "^/\.+(.*)\$" "/\$1" last;
    }
    location @ga_short {
        # Робот превью мессенджера сам открыл ссылку — 404 до службы. if здесь, а не рядом с try_files: в одной локации
        # с try_files if ломает её (nginx «If is Evil»), а return внутри if безопасен.
        if (\$ga_short_bot) {
            return 404;
        }
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        # Адрес для банов и доверия служба читает из X-Real-IP, и только с петли (lib/shortlinks.py)
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_intercept_errors on;
        error_page 404 502 504 =404 @ga_short_down;
        limit_req zone=goamnezia_short burst=20 nodelay;
        limit_req_status 404;
        limit_conn goamnezia_short_conn 8;
        limit_conn_status 404;
        proxy_read_timeout 120s;
        client_max_body_size 1k;
        proxy_hide_header X-Frame-Options;
        proxy_hide_header Referrer-Policy;
        proxy_hide_header X-Content-Type-Options;
        add_header X-Frame-Options "DENY" always;
        add_header Referrer-Policy "no-referrer" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
        access_log off;
        error_log /dev/null crit;
    }
    location @ga_short_down {
        # Без своих add_header: заголовки 404 — уровня server, как у 404 сайта (SEC-G4).
        access_log off;
        error_log /dev/null crit;
        return 404;
    }
EOSHORT
}

# На 80 в Pro короткий путь, как и любой, уходит редиректом на HTTPS — но без строки в журнале: код, набранный руками
# как http://домен/КОД, не должен лечь в access.log (как глушилка секретных путей). Только вместе с маршрутом подписок.
_ga_site_short_http_block() {
    [ "$(ga_config_get .site.subs_location 2>/dev/null)" = "true" ] && [ "${1:-pro}" = "pro" ] || return 0
    # shellcheck disable=SC2016  # переменные nginx, не bash
    printf '    location ~ "%s" {\n        access_log off;\n        error_log /dev/null crit;\n        %s\n    }\n' \
        "$GA_SITE_SHORT_HTTP_RE" 'return 301 https://$server_name$request_uri;'
}

# Зоны предела запросов подписок — уровень http, вставляются вместе с локацией (как _ga_site_pages_zones):
# секунда на запрос с адреса и запас 10 сразу. Там же — зоны коротких ссылок (страница подтверждения опрашивает
# статус раз в 2 секунды) и карта роботов превью для них (map — тоже только уровень http).
_ga_site_subs_zones() {
    [ "$(ga_config_get .site.subs_location 2>/dev/null)" = "true" ] || return 0
    cat <<'EOZONES'
limit_req_zone $binary_remote_addr zone=goamnezia_subs:1m rate=1r/s;
limit_conn_zone $binary_remote_addr zone=goamnezia_subs_conn:1m;
limit_req_zone $binary_remote_addr zone=goamnezia_short:1m rate=2r/s;
limit_conn_zone $binary_remote_addr zone=goamnezia_short_conn:1m;
map $http_user_agent $ga_short_bot {
    default 0;
    "~*(telegrambot|vkshare|facebookexternalhit|facebot|slackbot|slack-imgproxy|discordbot|twitterbot|linkedinbot|skypeuripreview|mail\.ru_bot|googlebot|bingbot|yandex[a-z]*bot|redditbot|pinterestbot|embedly|iframely)" 1;
    "~*^whatsapp/" 1;
}
EOZONES
}

# Подстановка в шаблон: bash-замена с заблокированным «&» (в bash ≥ 5.2 с
# patsub_replacement незакавыченный & в замене раскрылся бы в найденный текст).
_ga_site_subst() {
    local text="$1" from="$2" to="$3"
    printf '%s' "${text//"$from"/"$to"}"
}

# _ga_site_tpl_variant <текст> <pro|selfsigned> — оставить в шаблоне блоки своего
# режима. Блоки размечены строками «# GOAMNEZIA_ONLY_<РЕЖИМ>_BEGIN … _END» в начале
# строки; чужой блок уходит вместе с маркерами, свой — остаётся без них. Так оба
# варианта nginx-директив живут в одном читаемом файле, а не в bash-heredoc.
_ga_site_tpl_variant() {
    awk -v keep="$2" '
        /^# GOAMNEZIA_ONLY_[A-Z]+_BEGIN$/ {
            v = $0; sub(/^# GOAMNEZIA_ONLY_/, "", v); sub(/_BEGIN$/, "", v)
            skip = (tolower(v) != keep); next
        }
        /^# GOAMNEZIA_ONLY_[A-Z]+_END$/ { skip = 0; next }
        !skip { print }' <<<"$1"
}

# _ga_site_render_vhost <pro|selfsigned> [домен] — полный vhost из шаблона.
#   pro        — server_name = домен, сертификат Let's Encrypt, ACME-локация и
#                редирект на 80, HSTS, панель по секретному пути;
#   selfsigned — server_name _ (ответ по IP), сертификат tls/site.{crt,key},
#                тот же сайт по 80 без редиректа, без HSTS и без панели.
# Маршрут агентов MCP и Alt-Svc — в обоих (PLAN §6.10).
_ga_site_render_vhost() {
    local variant="${1:-pro}" domain="${2:-}" tpl nl=$'\n' listen alt panel="" mcp pages zones subs szones="" v6="" sname cert key
    local hide80 hide443 short80
    tpl=$(<"$(ga_site_tpl_path)") || return 1
    tpl=$(_ga_site_tpl_variant "$tpl" "$variant")
    if [ "$variant" = "pro" ]; then
        sname="$domain"
        cert=$(ga_site_cert_file "$domain")
        key=$(ga_site_key_file "$domain")
        # Панель на домене — везде, где есть доверенный сертификат: её allowlist Host и код входа из бота
        # рассчитаны на домен, на голом IP location не собираем даже при заданном пути.
        panel=$(_ga_site_panel_block)
    else
        sname="_"
        cert=$(ga_site_ss_crt)
        key=$(ga_site_ss_key)
    fi
    listen=$(_ga_site_listen_block)
    alt=$(_ga_site_alt_svc_block)
    mcp=$(_ga_site_mcp_block)
    pages=$(_ga_site_pages_block "$variant")
    zones=""
    [ -n "$pages" ] && zones=$(_ga_site_pages_zones)
    subs=$(_ga_site_subs_block "$variant")
    [ -n "$subs" ] && szones=$(_ga_site_subs_zones)
    hide80=$(_ga_site_secret_paths_block "$variant" 80)
    hide443=$(_ga_site_secret_paths_block "$variant" 443)
    short80=""
    [ -n "$subs" ] && short80=$(_ga_site_short_http_block "$variant")
    if _ga_site_ipv6; then v6="    listen [::]:80;"; fi
    tpl=$(_ga_site_subst "$tpl" "LISTEN_PLACEHOLDER" "$listen")
    tpl=$(_ga_site_subst "$tpl" "LISTEN80_V6_PLACEHOLDER" "$v6")
    tpl=$(_ga_site_subst "$tpl" "ALT_SVC_PLACEHOLDER" "$alt")
    # Якоря остаются в готовом файле: по ним видно, где место панели и MCP
    tpl=$(_ga_site_subst "$tpl" "# GOAMNEZIA_PANEL_LOCATION" "# GOAMNEZIA_PANEL_LOCATION${panel:+$nl$panel}")
    tpl=$(_ga_site_subst "$tpl" "# GOAMNEZIA_MCP_LOCATION" "# GOAMNEZIA_MCP_LOCATION${mcp:+$nl$mcp}")
    tpl=$(_ga_site_subst "$tpl" "# GOAMNEZIA_PAGES_LOCATION" "# GOAMNEZIA_PAGES_LOCATION${pages:+$nl$pages}")
    tpl=$(_ga_site_subst "$tpl" "# GOAMNEZIA_PAGES_ZONES" "# GOAMNEZIA_PAGES_ZONES${zones:+$nl$zones}")
    tpl=$(_ga_site_subst "$tpl" "# GOAMNEZIA_SUBS_LOCATION" "# GOAMNEZIA_SUBS_LOCATION${subs:+$nl$subs}")
    tpl=$(_ga_site_subst "$tpl" "# GOAMNEZIA_SUBS_ZONES" "# GOAMNEZIA_SUBS_ZONES${szones:+$nl$szones}")
    # Имена якорей глушилки не начало друг друга и других якорей: подстановка заменяет каждое вхождение строки.
    tpl=$(_ga_site_subst "$tpl" "# GOAMNEZIA_SECRET_PATHS_80" "# GOAMNEZIA_SECRET_PATHS_80${hide80:+$nl$hide80}")
    tpl=$(_ga_site_subst "$tpl" "# GOAMNEZIA_SECRET_PATHS_443" "# GOAMNEZIA_SECRET_PATHS_443${hide443:+$nl$hide443}")
    tpl=$(_ga_site_subst "$tpl" "# GOAMNEZIA_SHORT_HTTP" "# GOAMNEZIA_SHORT_HTTP${short80:+$nl$short80}")
    tpl=$(_ga_site_subst "$tpl" "SERVER_NAME_PLACEHOLDER" "$sname")
    tpl=$(_ga_site_subst "$tpl" "SSL_CERT_PLACEHOLDER" "$cert")
    tpl=$(_ga_site_subst "$tpl" "SSL_KEY_PLACEHOLDER" "$key")
    tpl=$(_ga_site_subst "$tpl" "SITE_ROOT_PLACEHOLDER" "$(ga_site_root)")
    tpl=$(_ga_site_subst "$tpl" "ACME_ROOT_PLACEHOLDER" "$(ga_site_acme_root)")
    printf '%s\n' "$tpl"
}

# Временный vhost до выпуска сертификата: полный ссылается на файлы
# сертификата, и nginx -t без них падает. Этого хватает для HTTP-01.
_ga_site_render_http() {
    local domain="$1" v6=""
    if _ga_site_ipv6; then v6=$'\n    listen [::]:80;'; fi
    cat <<EOHTTP
# goAmnezia pro — временный конфиг до выпуска сертификата (website_write_conf http).
# Нужен ровно для проверки HTTP-01 Let's Encrypt; после certbot его заменяет полный vhost.
server {
    listen 80;${v6}
    server_name ${domain};

    location ^~ /.well-known/acme-challenge/ {
        root $(ga_site_acme_root);
        default_type text/plain;
        allow all;
    }

    # Секретные пути и здесь не пишутся в журнал (_ga_site_secret_paths_block): 404, как у любого пути
$(_ga_site_secret_paths_block http 80)

    root $(ga_site_root);
    index index.html;
    location ~ /\\. { deny all; }
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOHTTP
}

# website_write_conf <домен> [auto|full|http|selfsigned] — собрать vhost, включить
# его, nginx -t с откатом на прежний файл, reload. stdout пуст.
#   auto       — полный vhost Pro, если сертификат домена есть, иначе временный http;
#   full       — полный vhost Pro (домен, Let's Encrypt);
#   http       — временный vhost только для HTTP-01 (до выпуска сертификата);
#   selfsigned — vhost Lite + сайт на IP (домен не нужен, аргумент игнорируется).
website_write_conf() { ga_with_config_lock _website_write_conf_locked "$@"; }
_website_write_conf_locked() {
    local domain="${1:-}" kind="${2:-auto}" conf link tmp bak="" content label
    domain="${domain,,}"
    case "$kind" in
        auto|full|http) ga_site_check_domain "$domain" || return $? ;;
        selfsigned)     domain="" ;;
        *) ga_err invalid_conf_kind "$(tf website_err_conf_kind "$kind")" 2; return 2 ;;
    esac
    if [ ! -f "$(ga_site_tpl_path)" ]; then
        ga_err nginx_template_missing "$(tf website_err_tpl_missing "$(ga_site_tpl_path)")"
        return 1
    fi
    if [ "$kind" = "auto" ]; then
        # dry-run считает сертификат выпущенным — так тест видит полный конфиг
        if ga_dry || [ -f "$(ga_site_cert_file "$domain")" ]; then
            kind=full
        else
            kind=http
            log_warning "$(tf website_conf_http_only "$domain")"
        fi
    fi
    conf=$(ga_site_conf_path)
    link=$(ga_site_link_path)
    if ! ga_site_fs_nginx_ok; then
        ga_dry_echo "write $conf ($kind)"
        return 0
    fi
    mkdir -p "$(dirname "$conf")" "$(dirname "$link")" 2>/dev/null \
        || { ga_err nginx_dir_failed "$(tf website_err_nginx_dir "$(ga_site_nginx_dir)")"; return 1; }
    case "$kind" in
        full)       content=$(_ga_site_render_vhost pro "$domain") ;;
        selfsigned) content=$(_ga_site_render_vhost selfsigned) ;;
        *)          content=$(_ga_site_render_http "$domain") ;;
    esac
    # Подпись в итоговом сообщении: домен, а в Lite + сайт — IP сервера
    label="$domain"
    [ -n "$label" ] || label=$(ga_site_server_ip)
    [ -n "$content" ] || { ga_err nginx_render_failed "$(t website_err_render)"; return 1; }
    # Прежний конфиг — в резерв: nginx -t проверяет весь набор, и при ошибке
    # возвращаем старый файл, чтобы reload не оставил домен без сайта.
    #
    # Копия обязательна, пока прежний конфиг есть. Раньше пустая переменная
    # означала две разные вещи — «конфига не было» и «копию снять не удалось», —
    # и во втором случае откат УДАЛЯЛ работавший vhost: на сервере с полным или
    # доступным только для чтения /tmp человек менял шаблон, nginx -t отвергал
    # новый конфиг, и сайт вместе с панелью на 443 пропадал целиком. Поэтому
    # копию сначала пробуем рядом с целью (туда мы всё равно обязаны писать —
    # ниже там же создаётся tmp), потом в TMPDIR, и только если не вышло ни
    # там, ни там — отказываемся ДО первой записи: несделанная смена шаблона
    # несравнимо лучше снесённого сайта.
    if [ -f "$conf" ]; then
        bak=$(mktemp "${conf}.prev.XXXXXX" 2>/dev/null) \
            || bak=$(mktemp "${TMPDIR:-/tmp}/goamnezia_nginx_prev.XXXXXXXX" 2>/dev/null) \
            || bak=""
        if [ -n "$bak" ] && ! cp "$conf" "$bak" 2>/dev/null; then rm -f "$bak"; bak=""; fi
        if [ -z "$bak" ]; then
            ga_err nginx_backup_failed "$(tf website_err_conf_backup "$conf")"
            return 1
        fi
    fi
    tmp=$(mktemp "${conf}.XXXXXX" 2>/dev/null) || { rm -f "$bak"; ga_err write_failed "$(tf website_err_write "$conf")"; return 1; }
    if ! printf '%s\n' "$content" >"$tmp"; then
        rm -f "$tmp" "$bak"
        ga_err write_failed "$(tf website_err_write "$conf")"
        return 1
    fi
    # 0600, а не 0644: в vhost — секретные пути панели (/app-<секрет>/) и доступов агентов, которые продукт
    # везде держит в тайне (config.json 0600), а sites-available читает любой локальный пользователь и любая
    # служба соседа (находка SR-20). Мастер-процесс nginx читает конфиги от root, ему хватает. Установкам
    # прежних версий права сменит миграция: она перечитывает vhost через эту же функцию.
    chmod 600 "$tmp" 2>/dev/null || true
    if ! mv "$tmp" "$conf"; then
        rm -f "$tmp" "$bak"
        ga_err write_failed "$(tf website_err_write "$conf")"
        return 1
    fi
    ln -sfn "$conf" "$link"
    if ! ga_site_nginx_test; then
        if [ -n "$bak" ]; then cp "$bak" "$conf"; else rm -f "$conf" "$link"; fi
        rm -f "$bak"
        ga_err nginx_conf_invalid "$(t website_err_nginx_test)"
        return 1
    fi
    if [ -n "$bak" ]; then rm -f "$bak"; fi
    ga_site_nginx_reload || return 1
    # GA_SITE_QUIET_CONF=1 — вызывающий скажет сам: панель на домене включается сразу после полного vhost, и
    # «Конфиг nginx … записан (full)» шло вторым разом подряд (TAIL-2).
    [ "${GA_SITE_QUIET_CONF:-0}" = 1 ] || log_success "$(tf website_conf_written "${label:--}" "$kind")"
    return 0
}

# _ga_site_conf_serves <файл> <домен> — стоит ли домен среди server_name конфига.
# nginx выбирает server ТОЧНЫМ совпадением имени; всё, что не совпало ни с одним,
# уходит в default_server. Поэтому «в конфиге есть ACME-локация» само по себе
# ничего не значит: важно, отдаст ли её nginx запросу ИМЕННО этого домена.
_ga_site_conf_serves() {
    local conf="$1" domain="$2" names
    [ -n "$domain" ] || return 1
    names=$(sed -n 's/^[[:space:]]*server_name[[:space:]]\{1,\}\([^;]*\);.*$/\1/p' "$conf" 2>/dev/null | tr '\n' ' ')
    case " ${names} " in *" ${domain} "*) return 0 ;; esac
    return 1
}

# _ga_site_vhost_has_acme [домен] — 0, если СЕЙЧАС на сервере лежит наш vhost,
# который отдаст проверку HTTP-01 для этого домена. Такой vhost проведёт выпуск
# сертификата сам, и заменять его временным (а вместе с ним ронять 443) не нужно.
# Смотрим в сами файлы, а не в config.json: конфиг говорит, чего мы хотим, а
# вопрос здесь — что у nginx на руках прямо сейчас.
#
# Имя проверяем обязательно. Прежняя проверка смотрела только на слово
# acme-challenge и на смене домена ошибалась: в живом конфиге стоит ПРЕЖНИЙ
# домен, а проверка владения приходит с именем НОВОГО. Точного совпадения нет,
# запрос уходит в default_server — то есть в первый по алфавиту конфиг из
# sites-enabled, и попадал к нам лишь потому, что «goamnezia» обычно первый.
# Сосед, сортирующийся раньше, забирал проверку себе, и выпуск получал отказ.
_ga_site_vhost_has_acme() {
    local domain="${1:-}" conf
    ga_site_fs_nginx_ok || return 1
    for conf in "$(ga_site_conf_path)" "$(ga_site_acme_conf_path)"; do
        grep -q "acme-challenge" "$conf" 2>/dev/null || continue
        # Без имени (старый вызов) — как раньше: достаточно самой локации.
        [ -n "$domain" ] && ! _ga_site_conf_serves "$conf" "$domain" && continue
        return 0
    done
    return 1
}

# Отдельный vhost ТОЛЬКО на время выпуска: один server на 80 с точным именем
# нужного домена и одной локацией проверки. Нужен там, где живой vhost есть, но
# имя в нём другое (смена домена). Точное имя бьёт любой default_server, каким бы
# ни был порядок файлов у соседей, а живой конфиг не трогается вовсе — сайт,
# панель и доступы агентов всё это время работают на прежнем домене и 443.
_ga_site_render_acme() {
    local domain="$1" v6=""
    if _ga_site_ipv6; then v6=$'\n    listen [::]:80;'; fi
    cat <<EOACME
# goAmnezia pro — временный конфиг ТОЛЬКО для проверки HTTP-01 (домен $domain).
# Поднимается перед выпуском сертификата и снимается сразу после него; рабочий
# vhost сайта при этом не меняется. Правки руками здесь бессмысленны.
server {
    listen 80;$v6
    server_name $domain;

    location ^~ /.well-known/acme-challenge/ {
        root $(ga_site_acme_root);
        default_type text/plain;
        allow all;
    }

    location / { return 404; }
}
EOACME
}

_ga_site_acme_vhost_on() {
    local domain="$1" conf link tmp
    ga_site_ensure_acme_root || return 1
    conf=$(ga_site_acme_conf_path)
    link=$(ga_site_acme_link_path)
    if ! ga_site_fs_nginx_ok; then
        ga_dry_echo "write $conf (acme $domain)"
        return 0
    fi
    mkdir -p "$(dirname "$conf")" "$(dirname "$link")" 2>/dev/null \
        || { ga_err nginx_dir_failed "$(tf website_err_nginx_dir "$(ga_site_nginx_dir)")"; return 1; }
    tmp=$(mktemp "${conf}.XXXXXX" 2>/dev/null) || { ga_err write_failed "$(tf website_err_write "$conf")"; return 1; }
    if ! _ga_site_render_acme "$domain" >"$tmp" || ! mv "$tmp" "$conf"; then
        rm -f "$tmp"
        ga_err write_failed "$(tf website_err_write "$conf")"
        return 1
    fi
    chmod 644 "$conf" 2>/dev/null || true
    ln -sfn "$conf" "$link"
    # Откат полный: свой же файл, отвергнутый nginx -t, нельзя оставлять лежать —
    # следующий reload по любому поводу уронил бы весь nginx, а с ним сайт.
    if ! ga_site_nginx_test; then
        rm -f "$conf" "$link" 2>/dev/null || true
        ga_err nginx_conf_invalid "$(t website_err_nginx_test)"
        return 1
    fi
    if ! ga_site_nginx_reload; then
        _ga_site_acme_vhost_off
        return 1
    fi
    log_dim "$(tf website_acme_vhost_up "$domain")"
    return 0
}

_ga_site_acme_vhost_off() {
    local conf link
    conf=$(ga_site_acme_conf_path)
    link=$(ga_site_acme_link_path)
    if ! ga_site_fs_nginx_ok; then
        ga_dry_echo "rm -f $link $conf"
        return 0
    fi
    [ -e "$conf" ] || [ -e "$link" ] || return 0
    rm -f "$link" "$conf" 2>/dev/null || true
    if ga_dry || command -v nginx >/dev/null 2>&1; then
        if ga_site_nginx_test; then
            ga_site_nginx_reload || true
        else
            log_warning "$(t website_warn_nginx_after_disable)"
        fi
    fi
    return 0
}

# Снять vhost: файл и симлинк убрать, nginx -t (чужие сайты остаются) и reload.
# Общий хвост website_disable_pro lite и website_disable_site.
# --or-refuse: nginx -t после снятия отказал (сломан чужой конфиг в том же nginx) — vhost
# возвращается на место, rc 3 и код nginx_conf_invalid. Без этого продукт писал «Сайт снят, порты
# 80/443 больше не отвечают», а nginx до первой удачной перезагрузки отдавал прежний сайт, панель и
# маршрут агентов (находка SR-18). Снос и откат включения зовут без флага: там снять нужно всё равно.
_website_remove_vhost_locked() {
    local conf link keep=""
    conf=$(ga_site_conf_path)
    link=$(ga_site_link_path)
    # Временный конфиг проверки сносим тем же движением: сорвавшийся выпуск мог
    # оставить его лежать, и «сайта нет» соседствовало бы с нашим же живым 80-м
    # портом — тем самым, который предполётная проверка принимает за чужой.
    if ga_site_fs_nginx_ok; then
        if [ "${1:-}" = "--or-refuse" ] && [ -f "$conf" ]; then
            keep=$(cat "$conf" 2>/dev/null) || keep=""
        fi
        rm -f "$link" "$conf" "$(ga_site_acme_link_path)" "$(ga_site_acme_conf_path)" 2>/dev/null || true
    else
        ga_dry_echo "rm -f $link $conf $(ga_site_acme_link_path) $(ga_site_acme_conf_path)"
    fi
    if ga_dry || command -v nginx >/dev/null 2>&1; then
        if ga_site_nginx_test; then
            ga_site_nginx_reload || true
        elif [ -n "$keep" ]; then
            # Возвращаем тем же 0600, что и при записи (SR-20): файл к этому моменту удалён, и printf
            # создавал его заново по umask — 0644, то есть секретный путь панели и маршруты агентов снова
            # читал любой локальный пользователь (находка SEC46-05).
            ( umask 077; { printf '%s\n' "$keep"; } 2>/dev/null >"$conf" ) && chmod 600 "$conf" 2>/dev/null \
                && ln -sfn "$conf" "$link" 2>/dev/null
            ga_err nginx_conf_invalid "$(t website_err_disable_nginx)"
            return 3
        else
            log_warning "$(t website_warn_nginx_after_disable)"
        fi
    fi
    return 0
}

# _ga_site_autorenew <домен> on|off — автопродление сертификата домена в renewal-конфиге certbot.
# Сайт снят («Только VPN») — проверка HTTP-01 идти некуда, и продление падало бы дважды в сутки,
# пока сайт не вернётся (находка LC-15, 25.09.2026). Вернулся сайт — строку снимаем.
_ga_site_autorenew() {
    local domain="${1:-}" want="${2:-on}"
    [ -n "$domain" ] || return 0
    ga_site_fs_le_ok || return 0
    _ga_site_renewal_autorenew "$(ga_site_le_dir)/renewal/${domain}.conf" "$want"
}

# _ga_site_renewal_autorenew <renewal.conf> on|off — сама правка файла. certbot читает флаг
# только из секции [renewalparams] (storage.autorenewal_is_enabled): строка первой в файле, вне
# секции, продление не останавливала (находка SR-55). Ставим её сразу за заголовком секции —
# до вложенной [[webroot_map]], иначе она уйдёт туда. Повтор не плодит строк.
_ga_site_renewal_autorenew() {
    local conf="${1:-}" want="${2:-on}" tmp
    [ -f "$conf" ] || return 0
    tmp="${conf}.goamnezia-tmp"
    if [ "$want" = off ]; then
        awk '/^autorenew *=/ {next}
             {print}
             /^\[renewalparams\][[:space:]]*$/ && !done {print "autorenew = False"; done=1}
             END {if (!done) {print "[renewalparams]"; print "autorenew = False"}}' \
            "$conf" 2>/dev/null >"$tmp" && mv -f "$tmp" "$conf" 2>/dev/null
    else
        grep -qE '^autorenew *= *False' "$conf" 2>/dev/null || return 0
        grep -vE '^autorenew *= *False' "$conf" 2>/dev/null >"$tmp" && mv -f "$tmp" "$conf" 2>/dev/null
    fi
    rm -f "$tmp" 2>/dev/null
    return 0
}

# website_wipe — снос продукта: сайт уходит целиком, а не «до Lite». vhost и временный конфиг
# проверки (nginx перечитывается), веб-корни сайта и проверки ACME, deploy-хук и наш таймер
# продления. Сертификаты в /etc/letsencrypt остаются: они принадлежат certbot, и повторный
# выпуск на тот же домен упирается в лимиты Let's Encrypt. Раньше «Удалить всё» оставлял
# работающий сайт-заглушку и секретный путь панели с прокси на мёртвый порт, а vhost на
# запасном сертификате ссылался на удалённый /opt/goamnezia/tls — и nginx не поднимался после
# первой же перезагрузки, вместе с чужими сайтами (находки LC-01 и SR-01, 25.09.2026).
website_wipe() {
    local sdir hook unit root
    _website_remove_vhost_locked
    # Подписки — на паузу (маршрут снят, секреты остаются, lib/subs.sh) — до страниц: те при живых страницах
    # пересобирают vhost, и маршрута подписок в нём уже не должно быть.
    if type _subs_mode_off_locked >/dev/null 2>&1; then _subs_mode_off_locked >/dev/null 2>&1 || true; fi
    if type _pages_mode_off_locked >/dev/null 2>&1; then _pages_mode_off_locked >/dev/null 2>&1 || true; fi
    hook="$(ga_site_le_dir)/renewal-hooks/deploy/goamnezia-nginx-reload.sh"
    sdir=$(ga_site_systemd_dir)
    if ga_dry; then
        ga_dry_echo "rm -rf $(ga_site_root) $(ga_site_acme_root) $hook; disable goamnezia-cert-renew.timer"
        return 0
    fi
    for unit in goamnezia-cert-renew.timer goamnezia-cert-renew.service; do
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
        rm -f "$sdir/$unit" 2>/dev/null || true
    done
    rm -f "$hook" 2>/dev/null || true
    # Сертификаты остаются, но их проверка шла через наш веб-корень: без него продление
    # падало бы дважды в сутки (certbot.timer). Выключаем автопродление только у тех, чей
    # webroot — наш каталог проверки ACME (находка LC-01 retest, 25.09.2026).
    local rconf acme
    acme=$(ga_site_acme_root)
    for rconf in "$(ga_site_le_dir)"/renewal/*.conf; do
        [ -f "$rconf" ] || continue
        grep -qE "^webroot_path *= *${acme}(,|$| )" "$rconf" 2>/dev/null || grep -qF "$acme" "$rconf" 2>/dev/null || continue
        _ga_site_renewal_autorenew "$rconf" off
    done
    # Пустая переменная или системный каталог под rm -rf — беда: такие пути не трогаем никогда,
    # остальное — наш каталог (по умолчанию /var/www/goamnezia-site и /var/www/goamnezia-acme).
    for root in "$(ga_site_root)" "$(ga_site_acme_root)"; do
        case "$root" in
            ""|/|/var|/var/www|/etc|/opt|/root|/home|/usr|/srv|/tmp) ;;
            /*/*) rm -rf "$root" 2>/dev/null || true ;;
        esac
    done
    return 0
}

# Пересобрать vhost под текущее состояние сайта (после смены настройки). Ключ
# выбора — ВИД СЕРТИФИКАТА, а не режим: домен и Let's Encrypt есть и в pro, и в
# lite_site (разница между ними только в том, где живёт AmneziaWG), а
# самоподписанный vhost на IP — запасной путь для обоих. В lite сайта нет и
# пересобирать нечего (rc 0, ничего не пишем).
_website_reapply_conf_locked() {
    ga_site_has_site || return 0
    if [ "$(ga_site_cert_kind)" = "letsencrypt" ]; then
        ga_site_resolve_domain || return $?
        _website_write_conf_locked "$GA_SITE_DOMAIN" auto
    else
        _website_write_conf_locked "" selfsigned
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  Настройки vhost: listen, Alt-Svc, панель, доступы агентов
# ══════════════════════════════════════════════════════════════════════════════
# _ga_site_keep_err <команда…> — выполнить откатную команду, сохранив код и слова исходного отказа
# (запись в config.json свои GA_ERR_* не трогает, но откат не должен их подменять и при сбое).
_ga_site_keep_err() {
    local code="${GA_ERR_CODE:-}" msg="${GA_ERR_MSG:-}" last="${GA_LAST_ERROR_CODE:-}"
    "$@" >/dev/null 2>&1 || true
    GA_ERR_CODE="$code"; GA_ERR_MSG="$msg"; GA_LAST_ERROR_CODE="$last"
}

# Общий хвост: записать поле в config.json и, если сайт включён (Pro или
# Lite + сайт), пересобрать vhost. В Lite настройка сохраняется и применится при
# включении режима с сайтом — иначе «Alt-Svc on» в Lite воскрешал бы снятый сайт.
_ga_site_apply_setting() {
    local path="$1" value="$2" prev
    # Прежнее значение — как JSON (null, если ключа не было). Отказ пересборки vhost (nginx -t
    # отверг, например, из-за сломанного конфига соседа) раньше оставлял в config.json новое, а в
    # nginx старое: «маршрут агентов выключен», а nginx его отдаёт; «панель включена», а там 404.
    # Теперь при отказе значение возвращается — настройка и nginx меняются вместе (находка SR-11).
    prev=$(jq -c "(${path})" "$CONFIG_FILE" 2>/dev/null) || prev="null"
    [ -n "$prev" ] || prev="null"
    ga_config_set "$path" "$value" || { ga_err config_write_failed "$(t website_err_config)"; return 1; }
    if ga_site_has_site; then
        if ! _website_reapply_conf_locked; then
            _ga_site_keep_err ga_config_set "$path" "$prev"
            return 1
        fi
    else
        log_dim "$(t website_saved_applies_later)"
    fi
    return 0
}

# website_set_alt_svc on|off — заголовок Alt-Svc h3 (options.alt_svc)
website_set_alt_svc() { ga_with_config_lock _website_set_alt_svc_locked "$@"; }
_website_set_alt_svc_locked() {
    local v
    v=$(_ga_site_toggle "${1:-}") || { ga_err invalid_toggle "$(tf website_err_toggle "${1:-}")" 2; return 2; }
    _ga_site_apply_setting .options.alt_svc "$v" || return 1
    ga_site_audit "site-alt-svc" "$v"
    log_success "$(tf website_alt_svc_set "$(_ga_site_onoff "$v")")"
}

# website_panel_path_set <путь> / website_panel_path_clear — панель на домене
# по секретному пути (panel.miniapp_path); пусто = панель только через туннель.
# ga_site_panel_path_new → новый секретный путь панели.
#
# **512 бит** случайности (решение владельца 12.09.2026; было 48 бит — двенадцать
# шестнадцатеричных знаков). Кодируем не шестнадцатеричным, а base64url: те же
# 512 бит занимают 86 знаков вместо 128, а набор символов (буквы, цифры, «-»,
# «_») законен и в адресе, и в проверке пути. Перебирать такой адрес
# бессмысленно при любых мощностях, а читать его человеку не приходится —
# панель открывают по ссылке.
#
# Генератор один на весь продукт: до этого «app-$(generate_hex 12)» стояло в трёх
# местах, и удлинить путь означало бы не забыть про каждое.
ga_site_panel_path_new() {
    local raw=""
    raw=$(openssl rand -base64 64 2>/dev/null) || raw=""
    [ -n "$raw" ] || raw=$(head -c 64 /dev/urandom 2>/dev/null | base64 2>/dev/null) || raw=""
    # base64 переносит строки и добивает «=»: в адресе им не место.
    raw=$(printf '%s' "$raw" | tr -d '\n\r=' | tr '+/' '-_')
    # Крайний случай — ни openssl, ни base64: шестнадцатеричный запас тех же 512 бит.
    [ -n "$raw" ] || raw=$(generate_hex 128)
    printf 'app-%s' "$raw"
}

# Панель на домене включается сама, как только у сайта есть домен с настоящим сертификатом (решение
# владельца 17.09.2026: «веб-меню автоматически включалось после установки, если есть домен»). Не
# включается только если человек сам её выключил: panel.miniapp_auto=false пишет website_panel_path_clear,
# а включение руками (website_panel_path_set) запрет снимает. Зовётся под замком из website_enable_pro.
_ga_site_panel_autoenable_locked() {
    local domain="${1:-}" path cur auto
    [ -n "$domain" ] || return 0
    cur=$(ga_config_get .panel.miniapp_path 2>/dev/null) || cur=""
    [ "$cur" = null ] && cur=""
    [ -z "$cur" ] || return 0
    auto=$(ga_config_get .panel.miniapp_auto 2>/dev/null) || auto=""
    if [ "$auto" = "false" ]; then
        log_dim "$(t website_panel_auto_skipped)"
        return 0
    fi
    path=$(ga_site_panel_path_new)
    # Одна строка вместо трёх: полный vhost только что записан и объявлен, а «панель доступна по пути …» и
    # «панель включена сама: https://…» говорили одно и то же (TAIL-2). Итог — строкой ниже, с адресом целиком.
    local GA_SITE_QUIET_CONF=1 GA_SITE_QUIET_PANEL=1
    _website_panel_path_set_locked "$path" || return 1
    # Адрес — секрет: печатаем человеку с root и никуда больше (в аудите — только «path set»).
    log_success "$(tf website_panel_auto_enabled "https://${domain}/${path}/")"
}

website_panel_path_set() { ga_with_config_lock _website_panel_path_set_locked "$@"; }
_website_panel_path_set_locked() {
    local path="${1:-}" prev
    ga_site_panel_path_valid "$path" || { ga_err invalid_path "$(tf website_err_path "$path")" 2; return 2; }
    prev=$(ga_config_get .panel.miniapp_path 2>/dev/null) || prev=""
    _ga_site_panel_path_mirror "$path" || return 1
    # Отказ пересборки — зеркало назад вместе с основным полем (SR-11)
    _ga_site_apply_setting .panel.miniapp_path "$path" || { _ga_site_keep_err _ga_site_panel_path_mirror "$prev"; return 1; }
    # Включение руками снимает запрет автовключения (см. _ga_site_panel_autoenable_locked).
    ga_config_set .panel.miniapp_auto true || { ga_err config_write_failed "$(t website_err_config)"; return 1; }
    if [ -n "$prev" ]; then ga_site_audit "miniapp-on" "path rotated"; else ga_site_audit "miniapp-on" "path set"; fi
    [ "${GA_SITE_QUIET_PANEL:-0}" = 1 ] || log_success "$(tf website_panel_path_set "$path")"
}
website_panel_path_clear() { ga_with_config_lock _website_panel_path_clear_locked "$@"; }
_website_panel_path_clear_locked() {
    local prev
    prev=$(ga_config_get .panel.miniapp_path 2>/dev/null) || prev=""
    _ga_site_panel_path_mirror "" || return 1
    _ga_site_apply_setting .panel.miniapp_path "" || { _ga_site_keep_err _ga_site_panel_path_mirror "$prev"; return 1; }
    # Выключил сам — сайт панель больше не включает, пока её не включат руками.
    ga_config_set .panel.miniapp_auto false || { ga_err config_write_failed "$(t website_err_config)"; return 1; }
    ga_site_audit "miniapp-off" ""
    log_success "$(t website_panel_path_cleared)"
}
# Путь панели хранится в двух полях (CONTRACT §3.1): panel.miniapp_path читает
# бот (кнопка WebApp, miniapp_url) и vhost, site.panel_path — блок «сайт» у
# панели и status. Пишем зеркало ДО основного поля: если запись vhost сорвётся,
# оба поля всё равно согласованы, и повтор включения не оставит расхождения.
_ga_site_panel_path_mirror() {
    ga_config_set .site.panel_path "${1:-}" || { ga_err config_write_failed "$(t website_err_config)"; return 1; }
}

# website_mcp_location_on|off — маршрут /a-<secret>/mcp на домене (site.mcp_location).
# Сам HTTP-транспорт (mcp.http_enabled, юнит) включает lib/agents.sh.
website_mcp_location_on()  { ga_with_config_lock _website_mcp_location_locked true; }
website_mcp_location_off() { ga_with_config_lock _website_mcp_location_locked false; }
_website_mcp_location_locked() {
    local v="${1:-false}"
    _ga_site_apply_setting .site.mcp_location "$v" || return 1
    log_success "$(tf website_mcp_location_set "$(_ga_site_onoff "$v")")"
}

# website_pages_location_on|off — маршрут страниц подключения /p-<secret>/ и
# внутренняя локация зеркала сборок (site.pages_location, docs/CLIENTS.md §6).
# Включает lib/pages.sh вместе с первой страницей и снимает, когда страниц не
# осталось; служба goamnezia-pages — тоже его забота, здесь только vhost.
website_pages_location_on()  { ga_with_config_lock _website_pages_location_locked true; }
website_pages_location_off() { ga_with_config_lock _website_pages_location_locked false; }
_website_pages_location_locked() {
    local v="${1:-false}"
    _ga_site_apply_setting .site.pages_location "$v" || return 1
    log_success "$(tf website_pages_location_set "$(_ga_site_onoff "$v")")"
}

# website_subs_location_on|off — маршрут подписок /s-<secret>/<суффикс> (site.subs_location,
# docs/SUBSCRIPTION.md). Включает lib/subs.sh с первой подпиской и снимает, когда подписок не осталось или сайт
# ушёл с домена (пауза); служба goamnezia-pages — общая со страницами, здесь только vhost.
website_subs_location_on()  { ga_with_config_lock _website_subs_location_locked true; }
website_subs_location_off() { ga_with_config_lock _website_subs_location_locked false; }
_website_subs_location_locked() {
    local v="${1:-false}"
    _ga_site_apply_setting .site.subs_location "$v" || return 1
    log_success "$(tf website_subs_location_set "$(_ga_site_onoff "$v")")"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Сертификат Let's Encrypt
# ══════════════════════════════════════════════════════════════════════════════
# website_cert_expiry <домен> — stdout: «<дата ISO-8601 UTC> <дней до истечения>»;
# код 1 и пустой stdout, если сертификата нет.
website_cert_expiry() {
    local domain="${1:-}"
    domain="${domain,,}"
    ga_site_check_domain "$domain" || return $?
    _ga_site_x509_expiry "$(ga_site_cert_file "$domain")"
}

# website_selfsigned_expiry — то же для самоподписанного сертификата Lite + сайт.
website_selfsigned_expiry() { _ga_site_x509_expiry "$(ga_site_ss_crt)"; }

# _ga_site_x509_expiry <файл> — общий расчёт срока для обоих видов сертификата.
_ga_site_x509_expiry() {
    local cert="${1:-}" enddate iso="" days=""
    [ -n "$cert" ] && [ -f "$cert" ] || return 1
    enddate=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | sed 's/^notAfter=//')
    [ -n "$enddate" ] || return 1
    # openssl печатает «Dec  7 10:00:00 2026 GMT»; в ISO и дни переводим
    # python3 — единственный переносимый способ между GNU date и BSD date.
    if command -v python3 >/dev/null 2>&1; then
        read -r iso days < <(python3 - "$enddate" <<'EOPY'
import sys, datetime
s = " ".join(sys.argv[1].split())
try:
    d = datetime.datetime.strptime(s, "%b %d %H:%M:%S %Y %Z")
except ValueError:
    sys.exit(1)
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
print(d.strftime("%Y-%m-%dT%H:%M:%SZ"), (d - now).days)
EOPY
) || { iso=""; days=""; }
    fi
    if [ -z "$iso" ]; then
        # Без python3 — как печатает openssl, дни считает -checkend ниже
        iso="$enddate"
        if openssl x509 -checkend 0 -noout -in "$cert" >/dev/null 2>&1; then days=""; else days="0"; fi
    fi
    printf '%s %s\n' "$iso" "$days"
    return 0
}

# ── Почта центра сертификации ────────────────────────────────────────────────
# Хранится в config.json полем acme_email. Валидация нарочно мягкая (есть «@»,
# есть точка в домене, нет пробелов и управляющих): адрес уходит аргументом
# certbot, а не в шелл, и придираться к экзотическим, но законным адресам
# продукту не по чину.
ga_site_email_valid() {
    [[ "${1:-}" =~ ^[^[:space:][:cntrl:]@]+@[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]]
}
ga_site_acme_email() {
    local e
    e=$(ga_config_get ".acme_email" 2>/dev/null)
    [ -n "$e" ] && [ "$e" != "null" ] && ga_site_email_valid "$e" || return 1
    printf '%s' "$e"
}

# website_set_acme_email <адрес|пусто> — записать почту (пустая строка стирает).
website_set_acme_email() { ga_with_config_lock _website_set_acme_email_locked "$@"; }
_website_set_acme_email_locked() {
    local email="${1:-}"
    if [ -n "$email" ] && ! ga_site_email_valid "$email"; then
        ga_err invalid_email "$(tf website_err_email "$email")" 2
        return 2
    fi
    ga_config_merge "$(jq -cn --arg e "$email" '{acme_email: $e}')" \
        || { ga_err config_write_failed "$(t website_err_config)"; return 1; }
    ga_site_audit "set-acme-email" "${email:+set}"
    log_success "$(tf website_email_saved "${email:--}")"
    return 0
}

# ── Сторож срока сертификата (goamnezia-cert.timer, раз в сутки) ─────────────
# Ни таймера, ни события у срока не было вовсе: сорвавшееся автопродление
# оставалось невидимым до дня, когда разом умирают сайт, панель и транспорт
# агентов. Тик смотрит на ФАКТИЧЕСКИЙ сертификат режима (Let's Encrypt в pro,
# самоподписанный в lite_site) и говорит один раз в сутки, пока не починят.
# stdout: JSON {mode, kind, domain, expires, days, warn, renewed}.
website_cert_tick() {
    local mode kind domain="" exp iso="" days="" warn=false renewed=false
    mode=$(ga_site_mode)
    if [ "$mode" = "lite" ]; then
        jq -cn --arg m "$mode" '{mode: $m, kind: "none", domain: "", expires: "", days: null, warn: false, renewed: false}'
        return 0
    fi
    kind=$(ga_site_cert_kind)
    if [ "$kind" = "letsencrypt" ]; then
        domain=$(ga_config_get ".domain" 2>/dev/null)
        exp=$(website_cert_expiry "$domain" 2>/dev/null) || exp=""
    else
        exp=$(website_selfsigned_expiry 2>/dev/null) || exp=""
    fi
    iso="${exp%% *}"; days="${exp##* }"
    [[ "$days" =~ ^-?[0-9]+$ ]] || days=""
    # Срока не видно вовсе (файла нет, openssl не прочитал) — это не «всё
    # хорошо»: у режима с сайтом сертификат обязан быть, и молчать тут значит
    # повторить ту же беду, из-за которой сторож и появился.
    if [ -z "$days" ]; then
        log_error "$(tf website_cert_tick_unknown "${domain:-$(ga_site_ss_crt)}")"
        type ga_notify >/dev/null 2>&1 && ga_notify cert_unknown \
            "$(jq -cn --arg k "$kind" --arg d "$domain" '{kind: $k, domain: $d}')"
        ga_site_audit "cert-tick" "kind=$kind unknown"
        jq -cn --arg m "$mode" --arg k "$kind" --arg d "$domain" \
            '{mode: $m, kind: $k, domain: $d, expires: "", days: null, warn: true, renewed: false}'
        return 0
    fi
    if [ "$days" -le "$GA_SITE_CERT_WARN_DAYS" ]; then
        warn=true
        # Сначала пробуем починить сами — ровно то, что сделал бы человек:
        # certbot renew у Let's Encrypt, перевыпуск у самоподписанного. Если
        # помогло, тревожить владельца незачем.
        if [ "$kind" = "letsencrypt" ]; then
            if website_renew_cert >/dev/null 2>&1; then
                exp=$(website_cert_expiry "$domain" 2>/dev/null) || exp=""
                iso="${exp%% *}"
                [[ "${exp##* }" =~ ^-?[0-9]+$ ]] && days="${exp##* }"
                [ "$days" -gt "$GA_SITE_CERT_WARN_DAYS" ] && { warn=false; renewed=true; }
            fi
        else
            if website_selfsigned_renew >/dev/null 2>&1; then
                exp=$(website_selfsigned_expiry 2>/dev/null) || exp=""
                iso="${exp%% *}"
                [[ "${exp##* }" =~ ^-?[0-9]+$ ]] && days="${exp##* }"
                [ "$days" -gt "$GA_SITE_CERT_WARN_DAYS" ] && { warn=false; renewed=true; }
            fi
        fi
    fi
    if [ "$warn" = true ]; then
        log_warning "$(tf website_cert_expiring "${domain:-$kind}" "$days")"
        type ga_notify >/dev/null 2>&1 && ga_notify cert_expiring \
            "$(jq -cn --arg k "$kind" --arg d "$domain" --argjson days "$days" --arg at "$iso" \
                '{kind: $k, domain: $d, days: $days, expires: $at}')"
        ga_site_audit "cert-tick" "kind=$kind days=$days warn"
    elif [ "$renewed" = true ]; then
        log_success "$(tf website_cert_tick_renewed "${domain:-$kind}" "$days")"
        ga_site_audit "cert-tick" "kind=$kind days=$days renewed"
    fi
    jq -cn --arg m "$mode" --arg k "$kind" --arg d "$domain" --arg at "$iso" \
        --argjson days "$days" --argjson w "$warn" --argjson r "$renewed" \
        '{mode: $m, kind: $k, domain: $d, expires: $at, days: $days, warn: $w, renewed: $r}'
}

# Сертификат есть и не истекает ближайшие N дней (по умолчанию 30). Тестовый (staging — так
# владелец велит гонять повторы, GOAMNEZIA_LE_STAGING=1) браузеры не признают: вне staging-прогона
# он «не действующий», иначе боевой поверх него так и не выпускался бы (находка SR-21).
ga_site_cert_ok() {
    local domain="$1" min_days="${2:-$GA_SITE_CERT_MIN_DAYS}" cert
    cert=$(ga_site_cert_file "$domain")
    [ -f "$cert" ] || return 1
    if [ "${GOAMNEZIA_LE_STAGING:-0}" != 1 ] && _ga_site_cert_is_staging "$domain"; then
        return 1
    fi
    openssl x509 -checkend "$((min_days * 86400))" -noout -in "$cert" >/dev/null 2>&1
}
# Сертификат домена выпущен тестовым центром Let's Encrypt: «(STAGING)» в издателе.
_ga_site_cert_is_staging() {
    local cert
    cert=$(ga_site_cert_file "${1:-}")
    [ -f "$cert" ] || return 1
    openssl x509 -noout -issuer -in "$cert" 2>/dev/null | grep -q 'STAGING'
}

ga_site_ensure_acme_root() {
    local root
    root=$(ga_site_acme_root)
    if ! ga_site_fs_acme_ok; then
        ga_dry_echo "mkdir -p $root"
        return 0
    fi
    mkdir -p "$root/.well-known/acme-challenge" 2>/dev/null || { ga_err acme_root_failed "$(tf website_err_acme_root "$root")"; return 1; }
    chmod 755 "$root" "$root/.well-known" "$root/.well-known/acme-challenge" 2>/dev/null || true
    return 0
}

ga_site_unit_exists() {
    ga_dry && return 1
    # Сначала весь вывод, потом поиск: под pipefail `… | grep -q` закрывал трубу на первом
    # совпадении, systemctl получал SIGPIPE, и труба отвечала «нет» примерно через раз — продление
    # ставило свой таймер рядом с certbot.timer (находка LC-16, 25.09.2026).
    local units
    units=$(systemctl list-unit-files "$1" 2>/dev/null) || units=""
    grep -q "^$1" <<<"$units"
}

# website_setup_auto_renew — продление: deploy-hook + системный certbot.timer,
# а без него свой goamnezia-cert-renew.timer.
website_setup_auto_renew() {
    local le_dir hook_dir hook sdir
    le_dir=$(ga_site_le_dir)
    hook_dir="$le_dir/renewal-hooks/deploy"
    hook="$hook_dir/goamnezia-nginx-reload.sh"
    # certbot после каждого удачного продления выполняет всё из renewal-hooks/deploy:
    # так новый сертификат подхватывается без рестарта, каким бы способом ни
    # шло продление (таймер certbot, наш таймер, запуск руками).
    if ga_site_fs_le_ok; then
        if ! { mkdir -p "$hook_dir" 2>/dev/null \
               && printf '#!/bin/sh\n# goAmnezia pro: nginx перечитывает продлённый сертификат без рестарта\nsystemctl reload nginx\n' 2>/dev/null >"$hook" \
               && chmod 755 "$hook" 2>/dev/null; }; then
            log_warning "$(tf website_warn_hook "$hook")"
        fi
    else
        ga_dry_echo "write $hook"
    fi
    if ga_site_unit_exists certbot.timer; then
        ga_site_run_quiet systemctl enable --now certbot.timer || true
        # Свой таймер рядом с certbot.timer — дубль от гонки pipefail в ga_site_unit_exists
        # (LC-16): два продления подряд и две записи в журнале. Снимаем его (находка LS-16).
        local dup
        dup="$(ga_site_systemd_dir)/goamnezia-cert-renew.timer"
        if [ -f "$dup" ]; then
            ga_site_run_quiet systemctl disable --now goamnezia-cert-renew.timer || true
            rm -f "$dup" "$(ga_site_systemd_dir)/goamnezia-cert-renew.service" 2>/dev/null || true
            ga_site_run_quiet systemctl daemon-reload || true
        fi
        log_dim "$(t website_renew_timer_certbot)"
        return 0
    fi
    # Пакет без таймера (snap-установка certbot, RHEL): свой таймер с deploy-hook
    sdir=$(ga_site_systemd_dir)
    if ga_site_fs_systemd_ok; then
        if ! { mkdir -p "$sdir" 2>/dev/null \
               && cat >"$sdir/goamnezia-cert-renew.service" <<'EOUNIT' \
               && cat >"$sdir/goamnezia-cert-renew.timer" <<'EOTIMER'; }; then
[Unit]
Description=goAmnezia pro: renew the Let's Encrypt certificate
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env certbot renew --quiet --deploy-hook "systemctl reload nginx"
EOUNIT
[Unit]
Description=goAmnezia pro: daily certificate renewal check

[Timer]
OnCalendar=*-*-* 03:17:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOTIMER
            log_warning "$(tf website_warn_units "$sdir")"
        fi
    else
        ga_dry_echo "write $sdir/goamnezia-cert-renew.service $sdir/goamnezia-cert-renew.timer"
    fi
    ga_site_run_quiet systemctl daemon-reload || true
    ga_site_run_quiet systemctl enable --now goamnezia-cert-renew.timer || true
    log_dim "$(t website_renew_timer_own)"
    return 0
}

# _ga_site_cert_cause <журнал certbot> → net | limit | check — почему не выпустился
# сертификат. Подсказка была одна — «проверьте A-запись и порт 80», — и на живом
# стенде она уводила не туда: домен и порт 80 были в порядке, а сервер не
# достучался до самого Let's Encrypt (исходящее соединение: «No route to host»,
# «Read timed out»). Три причины — три совета: сеть сервера, лимит выдачи,
# проверка домена. Ошибки проверки домена («Timeout during connect», «Connection
# refused» при запросе к нашему :80) приходят от Let's Encrypt и имени его API не
# содержат — они остаются за прежней подсказкой.
_ga_site_cert_cause() {
    local f="${1:-}"
    if [ -n "$f" ] && [ -r "$f" ]; then
        if grep -qiE "too many (certificates|failed authorizations|new orders|registrations)|rateLimited|/rate-limits" "$f" 2>/dev/null; then
            printf 'limit'; return 0
        fi
        if grep -qE "HTTPSConnectionPool\(host='acme|Requesting acme-|acme(-staging)?-v02\.api\.letsencrypt\.org.*(timed out|No route to host|Connection (refused|reset|aborted)|Name or service not known|Temporary failure in name resolution|Network is unreachable|NewConnectionError|SSLError|Max retries)" "$f" 2>/dev/null; then
            printf 'net'; return 0
        fi
    fi
    printf 'check'
}

# _ga_site_cert_retry_after <журнал certbot> → «2026-09-27 10:00» (UTC) из строки «retry after …» или пусто.
_ga_site_cert_retry_after() {
    local line after
    line=$(grep -iE 'retry after' "${1:-}" 2>/dev/null | tail -n 1)
    after=$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}' <<<"${line##*[Rr]etry after}" | head -n 1)
    printf '%s' "${after/T/ }"
}

# _ga_site_cert_hint <журнал certbot> → текст совета по причине провала. У лимита срок разный
# (после неудачных проверок — час, после пяти выпусков за неделю — до недели), а Let's Encrypt
# сам пишет «retry after <время>»: его и называем, вместо «подождите час» на все случаи (SR-22).
# Время у Let's Encrypt — UTC, а голое «10:00 UTC» человек читал как своё (TAIL-21, как NC-11):
# называем его, как прочие сроки, — «через 2 ч (… по времени сервера)». Срок уже прошёл или не
# разобрался — общий совет: «повторить можно 5 минут назад» ничего бы не сказал.
_ga_site_cert_hint() {
    local after e=""
    case "$(_ga_site_cert_cause "${1:-}")" in
        net)   t website_cert_hint_net ;;
        limit)
            # Срок разбирает тот же помощник, что кладёт его боту в cert_retry_after («2026-09-27 10:00», UTC).
            after=$(_ga_site_cert_retry_after "${1:-}")
            [ -z "$after" ] || e=$(ga_iso_epoch "${after/ /T}Z") || e=""
            if [ -n "$e" ] && [ "$e" -gt "$(date +%s)" ]; then
                tf website_cert_hint_limit_until "$(ga_human_ts "${after/ /T}Z")"
            else
                t website_cert_hint_limit
            fi
            ;;
        *)     t website_cert_hint ;;
    esac
}

# website_issue_cert <домен> — сертификат Let's Encrypt. Живой сертификат с
# запасом ≥ 30 дней не трогаем; GOAMNEZIA_LE_STAGING=1 → --staging;
# GOAMNEZIA_LE_EMAIL — почта для уведомлений (иначе без почты). stdout пуст.
#
# Отказ Let's Encrypt (cert_failed) — ещё и причина словом в GA_CERT_CAUSE: dns — Let's Encrypt не проверил домен
# (A-запись не сюда или порт 80 закрыт снаружи), net — сервер не достучался до самого Let's Encrypt, limit — лимит
# выдачи (срок, если Let's Encrypt его назвал, — в GA_CERT_RETRY_AFTER, «2026-09-27 10:00» UTC). Мост кладёт их в
# ответ полями cert_cause и cert_retry_after: у бота на каждую причину свой текст, а не разбор слов ядра (L-26).
GA_CERT_CAUSE=""; GA_CERT_RETRY_AFTER=""
website_issue_cert() { ga_with_config_lock _website_issue_cert_locked "$@"; }
_website_issue_cert_locked() {
    local domain="${1:-}" exp err hint
    GA_CERT_CAUSE=""; GA_CERT_RETRY_AFTER=""
    domain="${domain,,}"
    ga_site_check_domain "$domain" || return $?
    if ga_site_cert_ok "$domain" "$GA_SITE_CERT_MIN_DAYS"; then
        exp=$(website_cert_expiry "$domain" 2>/dev/null) || exp=""
        log_success "$(tf website_cert_kept "$domain" "${exp#* }")"
        _ga_site_autorenew "$domain" on
        website_setup_auto_renew
        return 0
    fi
    website_ensure_certbot || return 1
    # --keep-until-expiring — второй страж от перевыпуска уже в самом certbot;
    # --deploy-hook запоминается в renewal-конфиге и работает при продлениях.
    # На месте тестовый сертификат от прошлого staging-прогона — certbot с --keep-until-expiring
    # оставил бы его («ещё не пора»): боевой выпускаем поверх принудительно (SR-21).
    local keep=--keep-until-expiring
    if [ "${GOAMNEZIA_LE_STAGING:-0}" != 1 ] && _ga_site_cert_is_staging "$domain"; then
        keep=--force-renewal
        log_info "$(tf website_cert_staging_replace "$domain")"
    fi
    local -a args=(certonly --non-interactive --agree-tos "$keep"
                   --cert-name "$domain" -d "$domain" --deploy-hook "systemctl reload nginx")
    # Почта центра сертификации. Раньше её брали только из окружения, а спросить
    # было негде — значит на любой обычной установке шло
    # --register-unsafely-without-email, и Let's Encrypt физически не мог
    # предупредить о сорвавшемся продлении. Теперь адрес живёт в config.json
    # (.acme_email, спрашивает экран сертификата и мастер), окружение его
    # перекрывает — так стенды и CI остаются как были.
    local email="${GOAMNEZIA_LE_EMAIL:-}"
    [ -n "$email" ] || email=$(ga_site_acme_email)
    if [ -n "$email" ]; then
        args+=(--email "$email")
    else
        args+=(--register-unsafely-without-email)
        log_warning "$(t website_cert_no_email)"
    fi
    if [ "${GOAMNEZIA_LE_STAGING:-0}" = "1" ]; then
        args+=(--staging)
        log_warning "$(t website_cert_staging)"
    fi
    # Способ проверки: nginx уже слушает 80 → webroot через наш vhost (nginx не
    # останавливаем); иначе standalone на 80 (первая установка до старта nginx).
    if ga_site_nginx_active; then
        ga_site_ensure_acme_root || return 1
        # vhost с ACME-локацией И С ЭТИМ ИМЕНЕМ обязан быть на месте: без него
        # (или с vhost режима Lite + сайт, где ACME-локации нет — там нет домена,
        # или с vhost прежнего домена) проверка попадёт в сайт, к соседу или в
        # default-страницу и получит 404, а не наш каталог.
        if ga_site_fs_nginx_ok && ! _ga_site_vhost_has_acme "$domain"; then
            _website_write_conf_locked "$domain" http || return 1
        fi
        args+=(--webroot -w "$(ga_site_acme_root)")
    else
        args+=(--standalone --preferred-challenges http)
    fi
    if ga_dry; then
        ga_dry_echo "certbot ${args[*]}"
        website_setup_auto_renew
        return 0
    fi
    log_info "$(tf website_cert_issuing "$domain")"
    err=$(mktemp "${TMPDIR:-/tmp}/goamnezia_certbot.XXXXXXXX" 2>/dev/null) || err=/dev/null
    if ! certbot "${args[@]}" >"$err" 2>&1; then
        hint=$(_ga_site_cert_hint "$err")
        GA_CERT_CAUSE=$(_ga_site_cert_cause "$err")
        [ "$GA_CERT_CAUSE" = check ] && GA_CERT_CAUSE=dns
        [ "$GA_CERT_CAUSE" = limit ] && GA_CERT_RETRY_AFTER=$(_ga_site_cert_retry_after "$err")
        ga_err cert_failed "$(tf website_err_cert "$domain")"
        if [ -s "$err" ]; then tail -n 8 "$err" | sed 's/^/      /' >&2; fi
        log_dim "$hint"
        # Боту, панели и агенту причина нужна не меньше, чем человеку в SSH: в ответ
        # моста уходит сообщение вместе с подсказкой (экран выше напечатал их раздельно).
        GA_ERR_MSG="${GA_ERR_MSG}. ${hint}"
        [ "$err" = /dev/null ] || rm -f "$err"
        return 1
    fi
    [ "$err" = /dev/null ] || rm -f "$err"
    if [ ! -f "$(ga_site_cert_file "$domain")" ]; then
        ga_err cert_missing "$(tf website_err_cert_missing "$domain" "$(ga_site_le_dir)")"
        return 1
    fi
    log_success "$(tf website_cert_issued "$domain")"
    website_setup_auto_renew
    return 0
}

# website_renew_cert — продление по сроку (certbot сам решает, пора ли);
# принудительного перевыпуска нет из-за лимитов Let's Encrypt.
# shellcheck disable=SC2120  # аргументов у продления нет; "$@" здесь — общая
# форма обёртки под замком, одинаковая у всех мутаций модуля (контракт §0.4).
website_renew_cert() { ga_with_config_lock _website_renew_cert_locked "$@"; }
_website_renew_cert_locked() {
    local err
    if ga_dry; then
        ga_dry_echo "certbot renew --quiet --deploy-hook 'systemctl reload nginx'"
        return 0
    fi
    command -v certbot >/dev/null 2>&1 || { ga_err certbot_missing "$(t website_err_certbot_missing)"; return 1; }
    log_info "$(t website_renew_running)"
    err=$(mktemp "${TMPDIR:-/tmp}/goamnezia_renew.XXXXXXXX" 2>/dev/null) || err=/dev/null
    if certbot renew --quiet --deploy-hook "systemctl reload nginx" >"$err" 2>&1; then
        [ "$err" = /dev/null ] || rm -f "$err"
        log_success "$(t website_renew_done)"
        return 0
    fi
    ga_err renew_failed "$(t website_err_renew)"
    if [ -s "$err" ]; then tail -n 5 "$err" | sed 's/^/      /' >&2; fi
    [ "$err" = /dev/null ] || rm -f "$err"
    return 1
}

# ══════════════════════════════════════════════════════════════════════════════
#  Самоподписанный сертификат (режим Lite + сайт, PLAN §4.3, CONTRACT §3.1)
# ══════════════════════════════════════════════════════════════════════════════
# website_cert_fingerprint [файл] — stdout: SHA-256 отпечаток «AA:BB:…» (по
# умолчанию — самоподписанного сертификата сайта); rc 1 без файла. По нему
# клиент MCP и человек убеждаются, что говорят с нашим сервером, а не с
# подменённым: доверять самоподписанному сертификату иначе нечем.
website_cert_fingerprint() {
    local crt="${1:-}" fp
    [ -n "$crt" ] || crt=$(ga_site_ss_crt)
    [ -f "$crt" ] || return 1
    fp=$(openssl x509 -noout -fingerprint -sha256 -in "$crt" 2>/dev/null) || return 1
    fp="${fp#*=}"
    [[ "$fp" =~ ^([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$ ]] || return 1
    printf '%s\n' "${fp^^}"
}

# В SAN сертификата есть этот IP (openssl -text переносим: -ext нет в LibreSSL)
_ga_site_ss_has_ip() {
    local crt="$1" ip="$2"
    openssl x509 -noout -text -in "$crt" 2>/dev/null | grep -qE "IP Address:${ip//./\\.}(,|[[:space:]]|$)"
}

# website_selfsigned_ensure [--force] — ключ EC P-256 и сертификат на 3650 дней в
# $(ga_site_tls_dir)/site.{key,crt}: CN и SAN IP = IP сервера, каталог 0700,
# файлы 0600 (читает их root-процесс nginx, как и ключи Let's Encrypt). Живой
# сертификат (тот же IP, ≥ 30 дней) не трогаем: у агентов MCP он закреплён по
# отпечатку. Перевыпуск — при смене IP, истечении или --force. stdout пуст.
website_selfsigned_ensure() { ga_with_config_lock _website_selfsigned_ensure_locked "$@"; }
_website_selfsigned_ensure_locked() {
    local force=0 ip dir crt key cfg tmpk tmpc exp=""
    [ "${1:-}" = "--force" ] && force=1
    command -v openssl >/dev/null 2>&1 || { ga_err openssl_missing "$(t website_err_openssl_missing)"; return 1; }
    ip=$(ga_site_server_ip)
    [ -n "$ip" ] || { ga_err no_server_ip "$(t website_err_no_server_ip)"; return 1; }
    dir=$(ga_site_tls_dir); crt=$(ga_site_ss_crt); key=$(ga_site_ss_key)
    if [ "$force" = 0 ] && [ -f "$crt" ] && [ -f "$key" ]; then
        if ! _ga_site_ss_has_ip "$crt" "$ip"; then
            log_warning "$(tf website_selfsigned_ip_changed "$ip")"
        elif openssl x509 -checkend "$((GA_SITE_CERT_MIN_DAYS * 86400))" -noout -in "$crt" >/dev/null 2>&1; then
            exp=$(website_selfsigned_expiry 2>/dev/null) || exp=""
            log_dim "$(tf website_selfsigned_kept "$ip" "${exp#* }")"
            return 0
        else
            log_info "$(t website_selfsigned_expiring)"
        fi
    fi
    if ! mkdir -p "$dir" 2>/dev/null; then
        # Каталог продукта недоступен только на чужой машине в dry-run (нет root):
        # там достаточно строки DRY, на сервере это настоящая ошибка.
        if ga_dry; then ga_dry_echo "openssl req -x509 -newkey ec … -subj /CN=$ip -out $crt"; return 0; fi
        ga_err tls_dir_failed "$(tf website_err_tls_dir "$dir")"
        return 1
    fi
    chmod 700 "$dir" 2>/dev/null || true
    log_info "$(tf website_selfsigned_generating "$ip" "$GA_SITE_SELFSIGNED_DAYS")"
    # Расширения — конфигом, а не -addext: так одинаково работают OpenSSL 1.1/3.x
    # на сервере и LibreSSL на macOS-стенде. Ключ EC P-256: короче RSA, и именно
    # такие ключи у большинства современных сайтов — сертификат не выделяется.
    cfg=$(mktemp "${TMPDIR:-/tmp}/goamnezia_ss_cnf.XXXXXXXX" 2>/dev/null) || { ga_err tmp_failed "$(t website_err_tmp)"; return 1; }
    # Временные файлы — в том же каталоге (0700): готовые ключ и сертификат
    # появляются атомарно через mv, полузаписанного site.key не бывает.
    tmpk=$(mktemp "$dir/.site.key.XXXXXX" 2>/dev/null) || { rm -f "$cfg"; ga_err tmp_failed "$(t website_err_tmp)"; return 1; }
    tmpc=$(mktemp "$dir/.site.crt.XXXXXX" 2>/dev/null) || { rm -f "$cfg" "$tmpk"; ga_err tmp_failed "$(t website_err_tmp)"; return 1; }
    printf '[req]\ndistinguished_name = dn\nx509_extensions = v3\nprompt = no\n[dn]\nCN = %s\n[v3]\nsubjectAltName = IP:%s\nbasicConstraints = CA:FALSE\nkeyUsage = digitalSignature, keyEncipherment, keyAgreement\nextendedKeyUsage = serverAuth\n' "$ip" "$ip" >"$cfg"
    if ! openssl req -x509 -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
            -days "$GA_SITE_SELFSIGNED_DAYS" -keyout "$tmpk" -out "$tmpc" -config "$cfg" >/dev/null 2>&1; then
        rm -f "$cfg" "$tmpk" "$tmpc"
        ga_err selfsigned_failed "$(t website_err_selfsigned)"
        return 1
    fi
    rm -f "$cfg"
    chmod 600 "$tmpk" "$tmpc" 2>/dev/null || true
    if ! mv -f "$tmpk" "$key" || ! mv -f "$tmpc" "$crt"; then
        rm -f "$tmpk" "$tmpc"
        ga_err write_failed "$(tf website_err_write "$crt")"
        return 1
    fi
    log_success "$(tf website_selfsigned_created "$ip" "$(website_cert_fingerprint 2>/dev/null || printf '%s' '-')")"
    return 0
}

# website_selfsigned_renew — перевыпустить самоподписанный сертификат (новый
# отпечаток) и, если сайт на нём сейчас, перечитать nginx. stdout пуст.
# shellcheck disable=SC2120  # см. website_renew_cert выше: та же форма обёртки.
website_selfsigned_renew() { ga_with_config_lock _website_selfsigned_renew_locked "$@"; }
_website_selfsigned_renew_locked() {
    _website_selfsigned_ensure_locked --force || return 1
    # Условие по ВИДУ СЕРТИФИКАТА, а не по названию режима: запасной
    # самоподписанный путь бывает и в pro (домена ещё нет), и там nginx после
    # перевыпуска остался бы со старым сертификатом до следующей перезагрузки
    # конфигурации. Проверял по названию режима — пропускал ровно этот случай.
    if [ "$(ga_site_cert_kind)" = "selfsigned" ]; then
        _website_write_conf_locked "" selfsigned || return 1
    fi
    ga_site_audit "selfsigned-renew" ""
    log_warning "$(tf website_selfsigned_renewed "$(website_cert_fingerprint 2>/dev/null || printf '%s' '-')")"
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  Шаблон сайта
# ══════════════════════════════════════════════════════════════════════════════
ga_site_random_template_id() {
    ga_site_tpl_env
    [ -f "$CATALOG_FILE" ] || return 1
    local id=""
    # Случайный сайт-заглушка — не чья-то личная страница. В каталоге тысячи портфолио и
    # резюме живых людей (репозитории <имя>.github.io и категория «Портфолио»): выпав
    # случайно, такая страница публиковала на сервере владельца чужое имя, почту и фото
    # (находка LC-13, 25.09.2026). Выбирать их руками из каталога по-прежнему можно.
    # Индекс из двух $RANDOM: один даёт максимум 32767, а записей в каталоге больше.
    id=$(jq -r --argjson n "$(( RANDOM * 32768 + RANDOM ))" '
        [.categories[] | select(.id != "portfolio") | .templates[].id
         | select((split("_") as $p | ($p | length) == 5 and $p[1] == $p[2] and $p[3] == "github" and $p[4] == "io") | not)]
        | if length > 0 then .[$n % length] else empty end' "$CATALOG_FILE" 2>/dev/null) || id=""
    [ -n "$id" ] && [ "$id" != "null" ] || return 1
    printf '%s\n' "$id"
}

# _ga_site_strip_trackers <корень сайта> — счётчики и ссылки на оригинал из шаблона вон.
# Сайт-заглушка не должен сообщать автору шаблона о каждом посетителе вместе с нашим
# доменом (gtag/GTM/analytics.js/Метрика/пиксель) и выдавать себя сканеру ссылками на
# github.io (canonical, og:url, sitemap.xml) — находка LS-09, 25.09.2026. Остальной код
# страниц не трогаем; без python3 — ничего не делаем.
_ga_site_strip_trackers() {
    local root="${1:-}"
    [ -d "$root" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    python3 - "$root" <<'PYEOF' 2>/dev/null || true
import os, re, sys
root = sys.argv[1]
HOSTS = r'(googletagmanager\.com|google-analytics\.com|mc\.yandex\.ru|connect\.facebook\.net|static\.hotjar\.com|clarity\.ms)'
CALLS = r'(gtag\(|dataLayer\.push|ga\(\s*[\'"]create|ym\(\s*\d|fbq\(|' + HOSTS + r')'
script_src = re.compile(r'<script\b[^>]*\bsrc=["\'][^"\']*' + HOSTS + r'[^"\']*["\'][^>]*>\s*</script>', re.I)
script_inline = re.compile(r'<script\b[^>]*>(?:(?!</script>).)*?' + CALLS + r'(?:(?!</script>).)*?</script>', re.I | re.S)
noscript = re.compile(r'<noscript>(?:(?!</noscript>).)*?(googletagmanager\.com|mc\.yandex\.ru|facebook\.com/tr)(?:(?!</noscript>).)*?</noscript>', re.I | re.S)
meta_url = re.compile(r'<(?:link|meta)\b[^>]*(?:rel=["\']canonical["\']|property=["\']og:url["\'])[^>]*>', re.I)
for d, _, files in os.walk(root):
    for f in files:
        p = os.path.join(d, f)
        # Ссылку из чужого шаблона не читаем и не пишем: запись шла бы от root в её цель.
        if os.path.islink(p):
            continue
        low = f.lower()
        if low == 'sitemap.xml':
            try:
                os.remove(p)
            except OSError:
                pass
            continue
        if not low.endswith(('.html', '.htm')):
            continue
        try:
            with open(p, encoding='utf-8', errors='surrogateescape') as fh:
                s = fh.read()
        except OSError:
            continue
        t = meta_url.sub('', noscript.sub('', script_inline.sub('', script_src.sub('', s))))
        if t != s:
            with open(p, 'w', encoding='utf-8', errors='surrogateescape') as fh:
                fh.write(t)
PYEOF
    return 0
}

# Код причины из библиотеки → ga_err с понятным сообщением
ga_site_tpl_fail() {
    local code="${1:-download_failed}" id="${2:-}"
    case "$code" in
        no_index)      ga_err no_index      "$(tf website_err_tpl_no_index "$id")" ;;
        app_shell)     ga_err app_shell     "$(tf website_err_tpl_app_shell "$id")" ;;
        broken_assets) ga_err broken_assets "$(tf website_err_tpl_broken_assets "$id")" ;;
        *)             ga_err download_failed "$(tf website_err_tpl_download_failed "$id")" ;;
    esac
    return 1
}

# Развёртывание уже скачанного каталога: файлы сайта, маркеры, config.json.
# stdout — JSON website_current_template.
_website_deploy_dir_locked() {
    local dir="$1" id="$2" src="${3:-}" root patch
    root=$(ga_site_root)
    if ! ga_site_fs_root_ok; then
        ga_dry_echo "deploy template $id → $root"
        return 0
    fi
    ga_site_tpl_env
    deploy_template_to_nginx "$dir" "$id" || { ga_err deploy_failed "$(tf website_err_deploy "$id")"; return 1; }
    _ga_site_strip_trackers "$root"
    # Библиотека пишет источник только для своих git-шаблонов; для каталога
    # источник — repo_url записи, чтобы в подвале и в панели было кого благодарить.
    if [ -n "$src" ]; then
        # 2>/dev/null ПЕРЕД перенаправлением: неудачу открытия печатает сама
        # оболочка, и подавление у команды её не гасит (узор §1c).
        printf '%s\n' "$src" 2>/dev/null >"$root/.goamnezia_template_source" || true
    else
        src=$(head -n 1 "$root/.goamnezia_template_source" 2>/dev/null) || src=""
    fi
    patch=$(jq -nc --arg id "$id" --arg src "$src" '{site: {template_id: $id, template_source: $src}}') || patch=""
    [ -n "$patch" ] && ga_config_merge "$patch" || { ga_err config_write_failed "$(t website_err_config)"; return 1; }
    ga_site_audit "change-template" "$id"
    # «Шаблон развёрнут в …» уже сказала библиотека (deploy_template_to_nginx) — вторая строка «Шаблон «id» развёрнут
    # в …» повторяла её (TAIL-2); id назван строкой выбора («Случайный шаблон из каталога: …») и экраном «Режим и сайт».
    website_current_template
}

# website_deploy_template <tpl_id|__random__> — скачать шаблон из каталога и
# развернуть в корень сайта. stdout — JSON website_current_template.
# GOAMNEZIA_TEMPLATE_LOCAL_DIR=<каталог> — явный хук для тестов и офлайн-стендов:
# сайт берётся из локального каталога без клона; проверка готовности страницы
# та же, что у скачанных (_tpl_page_ok) — хук обходит сеть, а не контроль качества.
website_deploy_template() {
    local id="${1:-}" dir="" src="" cache="" code="" rc=0
    ga_site_require_lib || return 1
    ga_site_tpl_env
    # Место — до клона: шаблон едет git clone во временный каталог, а потом
    # раскладывается в корень сайта. На забитом диске клон обрывался, и человек
    # получал английскую ошибку git вместо честного «места нет». 256 МБ — с
    # запасом на .git самого тяжёлого шаблона каталога.
    if type check_disk_space >/dev/null 2>&1 && ! check_disk_space "$GA_SITE_MIN_DISK_MB"; then
        ga_err low_disk "$(tf website_err_low_disk "$GA_SITE_MIN_DISK_MB")"
        return 1
    fi
    if [ "$id" = "__random__" ]; then
        id=$(ga_site_random_template_id) || { ga_err catalog_missing "$(tf website_err_catalog "$CATALOG_FILE")"; return 1; }
        log_info "$(tf website_tpl_random "$id")"
    fi
    ga_site_template_id_valid "$id" || { ga_err unknown_template "$(tf website_err_tpl_unknown "$id")" 2; return 2; }
    if [ -n "${GOAMNEZIA_TEMPLATE_LOCAL_DIR:-}" ]; then
        dir="$GOAMNEZIA_TEMPLATE_LOCAL_DIR"
        [ -d "$dir" ] || { ga_err download_failed "$(tf website_err_local_dir "$dir")"; return 1; }
        TEMPLATE_DL_ERROR=""
        if ! _tpl_page_ok "$dir"; then
            ga_site_tpl_fail "${TEMPLATE_DL_ERROR:-no_index}" "$id"
            return 1
        fi
        if [ -f "$CATALOG_FILE" ]; then
            src=$(get_template_field "$id" repo_url 2>/dev/null) || src=""
            [ "$src" = "null" ] && src=""
        fi
    else
        [ -f "$CATALOG_FILE" ] || { ga_err catalog_missing "$(tf website_err_catalog "$CATALOG_FILE")"; return 1; }
        [ -n "$(get_template_info "$id" 2>/dev/null)" ] || { ga_err unknown_template "$(tf website_err_tpl_unknown "$id")" 2; return 2; }
        # Кэш — свой и известный заранее: download_template зовётся через $(…),
        # переменная TEMPLATE_DL_ERROR из подоболочки не возвращается, и код
        # причины библиотека дублирует в <кэш>/.last_error.
        cache=$(mktemp -d "${TMPDIR:-/tmp}/goamnezia_templates.XXXXXXXX" 2>/dev/null) || { ga_err tmp_failed "$(t website_err_tmp)"; return 1; }
        chmod 700 "$cache" 2>/dev/null || true
        TEMPLATES_CACHE="$cache"
        if ! dir=$(download_template "$id"); then
            code=$(cat "$cache/.last_error" 2>/dev/null) || code=""
            rm -rf "$cache"
            ga_site_tpl_fail "${code:-download_failed}" "$id"
            return 1
        fi
        src=$(get_template_field "$id" repo_url 2>/dev/null) || src=""
        [ "$src" = "null" ] && src=""
    fi
    ga_with_config_lock _website_deploy_dir_locked "$dir" "$id" "$src"
    rc=$?
    if [ -n "$cache" ]; then rm -rf "$cache"; fi
    return $rc
}

# website_change_template_interactive — пункт SSH-меню: категория → список с
# поиском → превью → подтверждение → развёртывание (interactive_template_selection
# библиотеки). Свой git-репозиторий тоже поддерживается. stdout пуст.
website_change_template_interactive() {
    local cache dir id src rc=0
    ga_site_require_lib || return 1
    ga_site_tpl_env
    [ -f "$CATALOG_FILE" ] || { ga_err catalog_missing "$(tf website_err_catalog "$CATALOG_FILE")"; return 1; }
    cache=$(mktemp -d "${TMPDIR:-/tmp}/goamnezia_templates.XXXXXXXX" 2>/dev/null) || { ga_err tmp_failed "$(t website_err_tmp)"; return 1; }
    chmod 700 "$cache" 2>/dev/null || true
    TEMPLATES_CACHE="$cache"
    if ! dir=$(interactive_template_selection); then
        rm -rf "$cache"
        log_dim "$(t cancelled)"
        return 1
    fi
    id=$(basename "$dir")
    src=$(get_template_field "$id" repo_url 2>/dev/null) || src=""
    [ "$src" = "null" ] && src=""
    ga_with_config_lock _website_deploy_dir_locked "$dir" "$id" "$src" >/dev/null
    rc=$?
    rm -rf "$cache"
    return $rc
}

# website_current_template — stdout: JSON {template_id, template_source, name,
# category, license, preview_url, root, deployed, index_present}.
website_current_template() {
    local root id="" src="" name="" cat="" lic="" prev="" deployed=false idx=false
    root=$(ga_site_root)
    id=$(head -n 1 "$root/.goamnezia_template_id" 2>/dev/null) || id=""
    [ -n "$id" ] || id=$(ga_config_get .site.template_id 2>/dev/null) || id=""
    src=$(head -n 1 "$root/.goamnezia_template_source" 2>/dev/null) || src=""
    [ -n "$src" ] || src=$(ga_config_get .site.template_source 2>/dev/null) || src=""
    [ -f "$root/index.html" ] && idx=true
    [ -n "$id" ] && [ "$idx" = true ] && deployed=true
    ga_site_tpl_env
    if [ -n "$id" ] && [ -f "$CATALOG_FILE" ]; then
        IFS=$'\t' read -r name cat lic prev < <(jq -r --arg id "$id" \
            '.categories[] as $c | $c.templates[] | select(.id == $id)
             | [.name, $c.id, (.license // ""), (.preview_url // "")] | @tsv' \
            "$CATALOG_FILE" 2>/dev/null | head -n 1) || true
        [ -n "$src" ] || src=$(get_template_field "$id" repo_url 2>/dev/null) || src=""
        [ "$src" = "null" ] && src=""
    fi
    jq -cn --arg id "$id" --arg src "$src" --arg name "$name" --arg cat "$cat" --arg lic "$lic" \
        --arg prev "$prev" --arg root "$root" --argjson deployed "$deployed" --argjson idx "$idx" \
        '{template_id: $id, template_source: $src, name: $name, category: $cat, license: $lic,
          preview_url: $prev, root: $root, deployed: $deployed, index_present: $idx}'
}

# ══════════════════════════════════════════════════════════════════════════════
#  Внешняя проверка сайта
# ══════════════════════════════════════════════════════════════════════════════
# website_check [домен] — stdout: JSON {domain, mode, server_ip, url, dns_ip, dns_ok,
# dns_ips, dns_foreign, dns_state, dns_aaaa_foreign, dns_cloudflare, listen, http_code, https_code, https_ok,
# nginx_active, index_present, cert,
# cert_fingerprint_sha256, cert_expires, cert_days_left, cert_ok, verdict, dry_run,
# checked_at}. Замок не берёт.
#   pro       — A-запись против IP сервера, HTTPS по домену (--resolve на свой IP),
#               сертификат Let's Encrypt (так проверяются ОБА режима с сайтом:
#               домен и настоящий сертификат есть и в pro, и в lite_site);
#   запасной путь (site.cert=selfsigned) — HTTPS по IP с --insecure (доверять
#               самоподписанному curl не может; подлинность — по отпечатку).
# verdict: ok | not_pro | no_domain | dns_partial | dns_mismatch | dns_unknown | no_cert |
# http_error | no_site | cert_expiring | dry_run. dns_partial — часть A-записей
# домена ведёт на чужие адреса (сайт здесь отвечает, но Let's Encrypt и часть
# клиентов могут попасть на другую машину); dns_ok — ВСЕ A-записи ведут сюда;
# dns_unknown — DNS не ответил (SERVFAIL, таймаут, нет dig): не «поправьте DNS», а
# «проверить не вышло», и ниже сертификатных проверок (находка SR-15).
website_check() {
    local domain="${1:-}" mode ip="" dns_ip="" dns_ok=false code="0" http_code="0" https_ok=false
    local idx=false exp="" exp_date="" days="" cert_ok=false listen verdict dry=false nginx_active=false
    local kind="" fp="" url="" by_ip=false dns_js="" dns_state="" dns_ips_js='[]' dns_foreign_js='[]' dns_aaaa_js='[]' dns_cf=false
    mode=$(ga_site_mode)
    [ -n "$domain" ] || domain=$(ga_config_get .domain 2>/dev/null) || domain=""
    domain="${domain,,}"
    ga_dry && dry=true
    # Поле listen остаётся в ответе ради стабильности контракта, но значение
    # у него теперь одно: сайт всегда сам держит публичный 443.
    listen="public"
    # Адрес сервера — из config.json; в сеть только если поле пусто (как у status)
    ip=$(ga_site_server_ip)
    [ -f "$(ga_site_root)/index.html" ] && idx=true
    # Проверяем то, чем сайт отдаётся СЕЙЧАС. Ключ — вид сертификата, а не режим:
    # домен и Let's Encrypt есть в обоих режимах с сайтом, а самоподписанный на
    # IP — запасной путь, и тогда сохранённый домен к проверке не относится
    # (домен аргументом — явная просьба проверить именно его).
    if [ "$mode" != "lite" ] && [ "$(ga_site_cert_kind)" = "selfsigned" ] && [ -z "${1:-}" ]; then
        by_ip=true; domain=""
    fi
    if [ "$by_ip" = true ]; then
        kind="selfsigned"
        [ -n "$ip" ] && url="https://${ip}/"
        if exp=$(website_selfsigned_expiry 2>/dev/null); then
            exp_date="${exp%% *}"; days="${exp#* }"
            [[ "$days" =~ ^-?[0-9]+$ ]] || days=""
            if [ -n "$days" ] && [ "$days" -ge "$GA_SITE_CERT_MIN_DAYS" ]; then cert_ok=true; fi
        fi
        fp=$(website_cert_fingerprint 2>/dev/null) || fp=""
        if ! ga_dry && [ -n "$ip" ] && command -v curl >/dev/null 2>&1; then
            # --insecure: доверять самоподписанному сертификату curl не может по
            # определению; здесь проверяется, что 443 отвечает сайтом, а не что
            # сертификат доверен (это и есть ожидаемое состояние режима).
            code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 --insecure "https://${ip}/" 2>/dev/null) || code="0"
            [[ "$code" =~ ^[23][0-9][0-9]$ ]] && https_ok=true
            http_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://${ip}/" 2>/dev/null) || http_code="0"
        fi
    elif [ -n "$domain" ] && validate_domain "$domain"; then
        # Вид сертификата — про сайт, который сейчас отдаётся: в Lite сайта нет,
        # и cert пуст даже при сохранённом домене (домен аргументом — проверка
        # именно его сертификата Let's Encrypt).
        if [ "$mode" != "lite" ] || [ -n "${1:-}" ]; then kind="letsencrypt"; url="https://${domain}/"; fi
        if exp=$(website_cert_expiry "$domain" 2>/dev/null); then
            exp_date="${exp%% *}"
            days="${exp#* }"
            [[ "$days" =~ ^-?[0-9]+$ ]] || days=""
            if [ -n "$days" ] && [ "$days" -ge "$GA_SITE_CERT_MIN_DAYS" ]; then cert_ok=true; fi
        fi
        if ! ga_dry; then
            # Набор A-записей против набора адресов машины: у домена их может
            # быть несколько (адрес на каждый интерфейс), и первая в ответе DNS —
            # случайная. dns_ip — первая, ради прежнего контракта.
            dns_js=$(ga_site_dns_state "$domain") || dns_js=""
            dns_ip=$(jq -r '.a[0] // ""' <<<"$dns_js" 2>/dev/null) || dns_ip=""
            dns_state=$(jq -r '.state // "unknown"' <<<"$dns_js" 2>/dev/null) || dns_state="unknown"
            [ "$dns_state" = ok ] && dns_ok=true
            # Запрос «как браузер снаружи»: --resolve прибивает домен к адресу
            # сервера, так что проверка не зависит от DNS-кэша и работает до его
            # обновления.
            if [ -n "$ip" ] && command -v curl >/dev/null 2>&1; then
                code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
                    --resolve "${domain}:443:${ip}" "https://${domain}/" 2>/dev/null) || code="0"
                [[ "$code" =~ ^[23][0-9][0-9]$ ]] && https_ok=true
                http_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
                    --resolve "${domain}:80:${ip}" "http://${domain}/" 2>/dev/null) || http_code="0"
            fi
        fi
    else
        domain=""
    fi
    if ! ga_dry; then systemctl is-active --quiet nginx 2>/dev/null && nginx_active=true; fi
    # not_pro сохранён как код вердикта (его разбирают бот, панель и MCP), но
    # значит он теперь «сайта нет вовсе», а не «режим не Pro»: сайт есть в двух
    # режимах из трёх.
    if [ "$dry" = true ]; then verdict="dry_run"
    elif [ "$mode" = "lite" ]; then verdict="not_pro"
    elif [ "$by_ip" != true ] && [ -z "$domain" ]; then verdict="no_domain"
    elif [ "$by_ip" != true ] && [ "$dns_ok" != true ] && [ "$dns_state" != partial ] && [ "$dns_state" != unknown ]; then verdict="dns_mismatch"
    elif [ -z "$exp_date" ]; then verdict="no_cert"
    elif [ "$https_ok" != true ]; then verdict="http_error"
    elif [ "$idx" != true ]; then verdict="no_site"
    elif [ "$cert_ok" != true ]; then verdict="cert_expiring"
    # Часть A-записей чужая — сайт здесь отвечает, но продление сертификата под
    # угрозой. Этот вердикт — после сертификатных: иначе он заслонял бы
    # истекающий сертификат (замечание критика).
    elif [ "$by_ip" != true ] && [ "$dns_state" = partial ]; then verdict="dns_partial"
    elif [ "$by_ip" != true ] && [ "$dns_state" = unknown ]; then verdict="dns_unknown"
    else verdict="ok"
    fi
    [[ "$code" =~ ^[0-9]+$ ]] || code=0
    [[ "$http_code" =~ ^[0-9]+$ ]] || http_code=0
    if [ -n "$dns_js" ]; then
        dns_ips_js=$(jq -c '.a // []' <<<"$dns_js" 2>/dev/null) || dns_ips_js='[]'
        dns_foreign_js=$(jq -c '.foreign // []' <<<"$dns_js" 2>/dev/null) || dns_foreign_js='[]'
        dns_aaaa_js=$(jq -c '.aaaa_foreign // []' <<<"$dns_js" 2>/dev/null) || dns_aaaa_js='[]'
        dns_cf=$(jq -r '.cloudflare // false' <<<"$dns_js" 2>/dev/null) || dns_cf=false
    fi
    # Развёрнутый шаблон — в ответ проверки: бот рисует «Шаблон сайта» из этого же ответа, а поля не было, и
    # он всегда писал «не развёрнут» (находка SR-48). Тот же источник, что у website_current_template.
    local tpl_id=""
    tpl_id=$(head -n 1 "$(ga_site_root 2>/dev/null)/.goamnezia_template_id" 2>/dev/null) || tpl_id=""
    [ -n "$tpl_id" ] || tpl_id=$(ga_config_get .site.template_id 2>/dev/null) || tpl_id=""
    [ "$tpl_id" = null ] && tpl_id=""
    jq -cn --arg domain "$domain" --arg mode "$mode" --arg ip "$ip" --arg url "$url" --arg dns_ip "$dns_ip" \
        --argjson dns_ok "$dns_ok" --arg listen "$listen" --argjson http_code "$http_code" --argjson code "$code" \
        --argjson https_ok "$https_ok" --argjson nginx_active "$nginx_active" --argjson idx "$idx" \
        --arg kind "$kind" --arg fp "$fp" --arg exp "$exp_date" \
        --argjson days "${days:-null}" --argjson cert_ok "$cert_ok" --arg verdict "$verdict" \
        --argjson dry "$dry" --arg ts "$(ga_now)" --arg dns_state "$dns_state" \
        --argjson dns_ips "$dns_ips_js" --argjson dns_foreign "$dns_foreign_js" \
        --argjson dns_aaaa_foreign "$dns_aaaa_js" --argjson dns_cloudflare "$dns_cf" --arg tpl "$tpl_id" \
        '{domain: $domain, mode: $mode, server_ip: $ip, url: $url, dns_ip: $dns_ip, dns_ok: $dns_ok, template_id: $tpl,
          dns_ips: $dns_ips, dns_foreign: $dns_foreign, dns_state: $dns_state,
          dns_aaaa_foreign: $dns_aaaa_foreign, dns_cloudflare: $dns_cloudflare, listen: $listen,
          http_code: $http_code, https_code: $code, https_ok: $https_ok, nginx_active: $nginx_active, index_present: $idx,
          cert: $kind, cert_fingerprint_sha256: $fp, cert_expires: $exp, cert_days_left: $days, cert_ok: $cert_ok,
          verdict: $verdict, dry_run: $dry, checked_at: $ts}'
}

# ══════════════════════════════════════════════════════════════════════════════
#  Общие шаги включения сайта (Pro и Lite + сайт)
# ══════════════════════════════════════════════════════════════════════════════
# HTTP-транспорт MCP уже включён (в Lite он жил на своём порту) → маршрут
# /a-<secret>/mcp в vhost нужен сразу, иначе после переключения режима адреса
# агентов перестали бы отвечать.
_ga_site_mcp_route_auto() {
    if [ "$(ga_config_get .mcp.http_enabled 2>/dev/null)" = "true" ] \
       && [ "$(ga_config_get .site.mcp_location 2>/dev/null)" != "true" ]; then
        ga_config_set .site.mcp_location true || { ga_err config_write_failed "$(t website_err_config)"; return 1; }
        log_dim "$(t website_mcp_route_auto)"
    fi
    return 0
}

# Встроенная заглушка — последний рубеж, когда ни один случайный шаблон не развернулся (нет сети до GitHub, каталога
# нет, три шаблона подряд отказали): без неё корень сайта оставался пустым, и nginx отвечал на домене 403 — сразу
# видно, что это не обычный сайт (Ленивый Pro, docs/MODES_047.md: «до 3 попыток, потом встроенная заглушка»). Одна
# страница без внешних запросов, заголовок — домен сайта. id в config.json — builtin_stub; сменить — «Шаблон».
GA_SITE_STUB_ID="builtin_stub"
_ga_site_deploy_stub() {
    local root title="${1:-}" patch
    root=$(ga_site_root)
    ga_site_fs_root_ok || { ga_dry_echo "deploy template $GA_SITE_STUB_ID → $root"; return 0; }
    # Домен проверен (validate_domain: буквы, цифры, точки, дефисы) — в HTML его можно ставить как есть.
    [ -n "$title" ] && validate_domain "$title" || title="Welcome"
    mkdir -p "$root" 2>/dev/null || { ga_err deploy_failed "$(tf website_err_deploy "$GA_SITE_STUB_ID")"; return 1; }
    {
        printf '%s\n' '<!doctype html>' '<html lang="en">' '<head>' '<meta charset="utf-8">' \
            '<meta name="viewport" content="width=device-width, initial-scale=1">'
        printf '<title>%s</title>\n' "$title"
        printf '%s\n' '<style>' \
            'body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#f4f6f8;' \
            'color:#1f2933;font:17px/1.6 -apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}' \
            'main{max-width:34rem;padding:2rem;text-align:center}h1{font-size:2rem;margin:0 0 .75rem;font-weight:600}' \
            'p{margin:0;color:#52606d}' '</style>' '</head>' '<body>' '<main>'
        printf '<h1>%s</h1>\n' "$title"
        printf '%s\n' '<p>We are preparing something new here. Please check back a little later.</p>' \
            '</main>' '</body>' '</html>'
    } 2>/dev/null >"$root/index.html" || { ga_err deploy_failed "$(tf website_err_deploy "$GA_SITE_STUB_ID")"; return 1; }
    chmod 644 "$root/index.html" 2>/dev/null || true
    printf '%s\n' "$GA_SITE_STUB_ID" 2>/dev/null >"$root/.goamnezia_template_id" || true
    rm -f "$root/.goamnezia_template_source" 2>/dev/null || true
    patch=$(jq -nc --arg id "$GA_SITE_STUB_ID" '{site: {template_id: $id, template_source: ""}}') || patch=""
    [ -n "$patch" ] && ga_config_merge "$patch" >/dev/null || { ga_err config_write_failed "$(t website_err_config)"; return 1; }
    ga_site_audit "change-template" "$GA_SITE_STUB_ID"
    return 0
}

# Шаблон сайта при включении режима: явный — обязателен; без него случайный,
# если сайта ещё нет (до трёх попыток: сеть или репозиторий могут подвести,
# потом — встроенная заглушка), а уже развёрнутый сайт оставляем — так переходы
# между режимами его не трогают.
_ga_site_ensure_template() {
    local tpl="${1:-}" attempt cur
    if [ -n "$tpl" ]; then
        website_deploy_template "$tpl" >/dev/null || return 1
    elif [ ! -f "$(ga_site_root)/index.html" ]; then
        # dry-run без явного корня сайта: качать случайный шаблон некуда — только DRY-строка
        if ! ga_site_fs_root_ok; then
            ga_dry_echo "deploy template __random__ → $(ga_site_root)"
        fi
        attempt=1
        while ga_site_fs_root_ok; do
            if website_deploy_template __random__ >/dev/null; then break; fi
            if [ "$attempt" -ge 3 ]; then
                if _ga_site_deploy_stub "$(ga_config_get .domain 2>/dev/null)"; then
                    log_warning "$(t website_tpl_stub)"
                else
                    log_warning "$(t website_tpl_random_giveup)"
                fi
                break
            fi
            attempt=$((attempt + 1))
            log_warning "$(tf website_tpl_random_retry "$attempt" 3)"
        done
    else
        cur=$(ga_config_get .site.template_id 2>/dev/null) || cur=""
        [ -n "$cur" ] && log_dim "$(tf website_tpl_kept "$cur")"
    fi
    return 0
}

# Режим и вид сертификата в config.json одной записью — чтобы status не увидел
# «pro» с «selfsigned» между двумя вызовами.
_ga_site_set_mode() {
    ga_config_merge "$(jq -nc --arg m "$1" --arg c "${2:-}" '{mode: $m, site: {cert: $c}}')" \
        || { ga_err config_write_failed "$(t website_err_config)"; return 1; }
    # HTTP-транспорт MCP слушает по-разному: в режимах с сайтом — петлю за nginx,
    # в lite — собственный TLS-порт. После смены режима юнит пересобирает
    # lib/agents.sh (если подключён и транспорт включён); неудача не отменяет
    # смену режима — сайт уже переключён, человек получает подсказку.
    if type _agents_unit_reconcile_locked >/dev/null 2>&1; then
        _agents_unit_reconcile_locked || log_warning "$(t website_warn_agents_unit)"
    fi
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  Включение сайта на домене с настоящим сертификатом (оба режима с сайтом)
# ══════════════════════════════════════════════════════════════════════════════
# website_enable_pro <домен> [tpl_id|__random__] [pro|lite_site]
#   nginx → сертификат Let's Encrypt → vhost → шаблон → config.json
#   (mode = третий аргумент, по умолчанию pro; domain, site.cert=letsencrypt).
#
# Третий аргумент появился, когда владелец уточнил замысел: домен, сайт-заглушка
# и панель на TCP/443 с настоящим сертификатом есть и во ВТОРОМ режиме тоже, а
# отличается он от третьего только тем, что AmneziaWG стоит на своём отдельном
# порту, а не на UDP/443 рядом с сайтом. Работа модуля в обоих случаях
# одинаковая — меняется лишь слово, которое ляжет в mode.
#
# Повторный вызов в том же режиме — ремонт: живой сертификат не перевыпускается
# (лимиты Let's Encrypt — правило владельца; повторы гоняем GOAMNEZIA_LE_STAGING=1),
# шаблон не перекачивается. stdout пуст.
website_enable_pro() { ga_with_config_lock _website_enable_pro_locked "$@"; }
# _ga_site_enable_rollback <домен> <прежний домен> <был vhost 0|1> <прежний вид сертификата> <поднят конфиг проверки 0|1>
# Откат включения сайта на ЛЮБОМ отказе после записи домена в config.json: сертификат не выпустился,
# nginx -t отверг полный vhost или не прошёл reload, не легли маршрут MCP, шаблон или режим. Раньше откат
# стоял только на отказе certbot, и остальные выходы оставляли сервер наполовину: при переходе из lite —
# живой временный vhost на 80 при mode=lite, на смене домена — новый домен в конфиге при nginx на прежнем.
# Состояние возвращается туда, откуда стартовали, и целиком; код и слова исходного отказа сохраняются.
#
# Домен возвращаем первым: пока в config.json стоит домен без сайта, панель и адреса агентов зовут человека
# по адресу, который не отвечает, а следующая попытка чинить сайт берёт домен именно оттуда.
#
# vhost — по тому, что было НА САМОМ ДЕЛЕ: стоял ли наш vhost (had_vhost) и на каком сертификате (вид из
# config.json ДО попытки). Сайт был на Let's Encrypt — полный vhost прежнего домена, пока его сертификат жив,
# иначе запасной самоподписанный, чтобы сайт не остался без 443. Сайт был на самоподписанном — снова
# самоподписанный, даже если на диске жив сертификат прежнего домена: неудачная операция не должна менять
# отдаваемый сертификат (агенты MCP сверяют отпечаток). Сайта не было (первая установка, переход из lite) —
# снимаем всё, что успели записать: иначе продукт врёт сам себе (режим «сайта нет» при живом vhost на 80),
# следующая попытка спотыкается о собственный nginx, а предполётная проверка принимает чужой порт за свой.
_ga_site_enable_rollback() {
    local domain="$1" prev_domain="$2" had_vhost="$3" prev_cert="$4" acme_vhost="$5"
    local code="${GA_ERR_CODE:-}" msg="${GA_ERR_MSG:-}" last="${GA_LAST_ERROR_CODE:-}" rolled=""
    [ "$acme_vhost" = 1 ] && _ga_site_acme_vhost_off
    if [ -n "$prev_domain" ] && [ "$prev_domain" != "$domain" ]; then
        ga_config_merge "$(jq -nc --arg d "$prev_domain" '{domain: $d}')" >/dev/null 2>&1 || true
    fi
    if [ "$had_vhost" = 1 ]; then
        if [ "$prev_cert" = letsencrypt ] && [ -n "$prev_domain" ] && ga_site_cert_ok "$prev_domain" 0; then
            # «Сайт снова отвечает по прежнему домену» — только когда так и есть. Фраза едет и в
            # сообщение отказа: бот, панель и агент иначе видели один отказ certbot и не знали,
            # что живой сайт остался на месте (живая проверка SR-54, 25.09.2026).
            if _website_write_conf_locked "$prev_domain" full && [ "$prev_domain" != "$domain" ]; then
                rolled=$(tf website_domain_rolled_back "$prev_domain")
                log_warning "$rolled"
            fi
        else
            _website_write_conf_locked "" selfsigned || true
        fi
    else
        _website_remove_vhost_locked
    fi
    if [ -n "$rolled" ] && [ -n "$msg" ]; then
        case "$msg" in *[.!?…]) msg="$msg " ;; *) msg="$msg. " ;; esac
    fi
    GA_ERR_CODE="$code"; GA_ERR_MSG="${msg}${rolled}"; GA_LAST_ERROR_CODE="$last"
    return 0
}

_website_enable_pro_locked() {
    local domain="${1:-}" tpl="${2:-}" target="${3:-pro}" ip="" dns_ip="" prev
    local prev_domain="" had_vhost=0 prev_cert=""
    # acme_vhost — подняли ли мы отдельный конфиг проверки (снять обязаны сами);
    # acme_prep=0 — поднять не вышло, выпуск даже не пробуем.
    local acme_vhost=0 acme_prep=1
    domain="${domain,,}"
    case "$target" in pro|lite_site) ;; *) ga_err invalid_mode "$(tf website_err_mode "$target")" 2; return 2 ;; esac
    ga_site_check_domain "$domain" || return $?
    prev=$(ga_site_mode)
    # Что было ДО нас — два разных вопроса, и раньше задавался только первый.
    #
    #   prev_domain — прежний РАБОЧИЙ домен. Новый домен пишется в конфиг сразу
    #   (чтобы сорвавшийся certbot не заставлял проходить опрос заново), и без
    #   этой переменной прежний терялся навсегда: при отказе выпуска панель и
    #   адреса агентов продолжали звать человека на домен, который не отвечает.
    #
    #   had_vhost — стоял ли НА САМОМ ДЕЛЕ наш vhost. Режим из config.json для
    #   этого не годится: мастер пишет желаемый режим ДО установки сайта, то
    #   есть на первой установке prev уже «pro», хотя сайта ещё нет. Ветка
    #   очистки, написанная под `prev = lite`, из мастера не срабатывала
    #   никогда — отказ certbot оставлял живой vhost при mode=lite, продукт
    #   считал, что сайта нет, а nginx держал 80 и 443. Побочно от этого слепла
    #   и предполётная проверка: занятый чужим порт она принимала за свой.
    prev_domain=$(ga_config_get .domain 2>/dev/null) || prev_domain=""
    if ga_site_fs_nginx_ok && [ -f "$(ga_site_conf_path)" ]; then had_vhost=1; fi
    prev_cert=$(ga_site_cert_kind)
    log_step "$(tf website_enable_title "$domain")"
    # DNS-подсказка, не отказ: мастер уже предупреждал, а certbot скажет точно. Если про этот домен экран уже
    # сказал (website_dns_hint перед вопросом) — второй раз не повторяем (TAIL-2).
    if ! ga_dry && command -v dig >/dev/null 2>&1 && [ "${GA_SITE_DNS_HINTED:-}" != "$domain" ]; then
        website_dns_hint "$domain"
    fi
    # 1. nginx
    website_ensure_nginx || return 1
    # 2. Домен — в config.json до сертификата: сорвавшийся certbot не должен
    #    заставлять проходить опрос заново (тот же принцип, что у мастера).
    ga_config_merge "$(jq -nc --arg d "$domain" '{domain: $d}')" || { ga_err config_write_failed "$(t website_err_config)"; return 1; }
    # 3. Место для проверки HTTP-01 → 4. сертификат.
    #
    # Временный vhost вида http знает только про 80: он ЗАМЕНЯЕТ рабочий и уносит
    # с собой 443. На смене домена это и означало «кладёт живой сайт»: домен ещё
    # только проверяется, а сайт, панель и адреса агентов уже недоступны — и если
    # certbot откажет, сами они не вернутся. Поэтому выбираем по тому, что есть:
    #
    #   • живой vhost уже отдаёт проверку И НОСИТ ЭТО ИМЯ (повторный выпуск,
    #     починка того же домена) — не делаем ничего, он проведёт проверку сам;
    #   • живой vhost есть, но имя в нём другое (смена домена) — поднимаем
    #     ОТДЕЛЬНЫЙ конфиг только на 80 с точным именем нового домена. Точное имя
    #     nginx предпочитает любому default_server, поэтому порядок файлов у
    #     соседей больше ничего не решает, а рабочий vhost и 443 не тронуты;
    #   • живого vhost нет вовсе (первая установка) — терять нечего, пишем
    #     временный http как раньше.
    #
    # Прежнее обоснование ссылалось на то, что наш vhost «он же default_server».
    # Слова default_server нет ни в шаблоне, ни в готовом конфиге: проверка на
    # новый домен попадала к нам только потому, что «goamnezia» шёл первым по
    # алфавиту в sites-enabled. Сосед, сортирующийся раньше, забирал её себе.
    if ! ga_site_cert_ok "$domain" "$GA_SITE_CERT_MIN_DAYS" && ! _ga_site_vhost_has_acme "$domain"; then
        if [ "$had_vhost" = 1 ]; then
            if _ga_site_acme_vhost_on "$domain"; then acme_vhost=1; else acme_prep=0; fi
        else
            _website_write_conf_locked "$domain" http \
                || { _ga_site_enable_rollback "$domain" "$prev_domain" "$had_vhost" "$prev_cert" 0; return 1; }
        fi
    fi
    if [ "$acme_prep" = 0 ] || ! _website_issue_cert_locked "$domain"; then
        # Сертификат не выпустился (A-запись ещё не разошлась, лимит выдачи, закрытый 80).
        _ga_site_enable_rollback "$domain" "$prev_domain" "$had_vhost" "$prev_cert" "$acme_vhost"
        return 1
    fi
    # Сертификат на руках — временный конфиг проверки больше не нужен ни секунды. Снимаем и чужой
    # для этой попытки: хвост оборванной прежней смены домена _ga_site_vhost_has_acme принимал за
    # живой vhost, acme_vhost оставался 0, и конфиг лежал навсегда — два server с одним именем на
    # :80 и «conflicting server name» при каждом nginx -t (находка SR-22).
    if [ "$acme_vhost" = 1 ] || [ -e "$(ga_site_acme_conf_path)" ]; then _ga_site_acme_vhost_off; fi
    [ "$(ga_site_cert_kind)" = "selfsigned" ] && log_dim "$(tf website_cert_replaced_le "$domain")"
    # 5–8. Маршрут агентов MCP (если транспорт включён), полный vhost, шаблон, режим. Отказ любого шага —
    # тот же полный откат, что на отказе certbot.
    if ! _ga_site_mcp_route_auto || ! _website_write_conf_locked "$domain" full \
            || ! _ga_site_ensure_template "$tpl" || ! _ga_site_set_mode "$target" letsencrypt; then
        _ga_site_enable_rollback "$domain" "$prev_domain" "$had_vhost" "$prev_cert" 0
        return 1
    fi
    ga_site_audit "change-mode" "$target domain=$domain (from $prev)"
    log_success "$(tf website_enabled "https://${domain}/")"
    # Панель на домене — сама, вместе с сайтом; отказ здесь сайт не откатывает.
    _ga_site_panel_autoenable_locked "$domain" || log_warning "$(t website_panel_auto_failed)"
    return 0
}

# website_switch_site_mode <pro|lite_site> — переключить режим между двумя
# режимами С САЙТОМ, ничего не трогая в nginx и сертификате.
#
# По уточнённому замыслу владельца эти два режима отличаются ТОЛЬКО тем, где
# живёт AmneziaWG (свой порт против UDP/443 рядом с сайтом): сайт, домен,
# сертификат и панель у них одинаковые. Значит и переход между ними — это запись
# одного слова в config.json, а не пересборка сайта, как было раньше (домен
# снимался, сертификат откатывался на самоподписанный — и человек терял и то, и
# другое, просто уводя VPN с 443). Порт профиля меняет вызывающий: модуль сайта
# в контейнеры не лезет. stdout пуст.
website_switch_site_mode() { ga_with_config_lock _website_switch_site_mode_locked "$@"; }
_website_switch_site_mode_locked() {
    local target="${1:-}" prev
    case "$target" in pro|lite_site) ;; *) ga_err invalid_mode "$(tf website_err_mode "$target")" 2; return 2 ;; esac
    prev=$(ga_site_mode)
    if [ "$prev" = "lite" ]; then
        ga_err needs_site "$(t website_err_needs_site)" 2
        return 2
    fi
    _ga_site_set_mode "$target" "$(ga_site_cert_kind)" || return 1
    ga_site_audit "change-mode" "$target (site kept, from $prev)"
    # Название режима человеку печатает вызывающий (у меню и бота свои словари) —
    # модуль говорит только о том, что сайт при этом не пострадал.
    log_success "$(t website_mode_switched)"
    return 0
}

# website_disable_pro [lite_site|lite] — совместимое имя для двух разных дел:
#   lite_site — сайт остаётся как есть, меняется только режим (см.
#               website_switch_site_mode). Домен и сертификат Let's Encrypt
#               НЕ снимаются: они нужны второму режиму ровно так же;
#   lite      — сайт выключается целиком: vhost и симлинк убираются, 80/443
#               перестают отвечать. Сертификат, домен в config.json и файлы сайта
#               остаются на диске — обратное включение не тратит лимит Let's
#               Encrypt и не качает шаблон заново.
# stdout пуст.
website_disable_pro() { ga_with_config_lock _website_disable_pro_locked "$@"; }
_website_disable_pro_locked() {
    local target="${1:-lite_site}"
    case "$target" in
        lite|lite_site) ;;
        *) ga_err invalid_mode "$(tf website_err_mode "$target")" 2; return 2 ;;
    esac
    if [ "$target" = "lite_site" ]; then
        _website_switch_site_mode_locked lite_site || return $?
        return 0
    fi
    log_info "$(tf website_pro_off_note "$(ga_config_get .domain 2>/dev/null || printf '%s' '-')")"
    _website_remove_vhost_locked --or-refuse || return $?
    # Тот же уход в lite, что у website_disable_site: страницы подключения
    # отзываются, служба и флаг маршрута снимаются (lib/pages.sh). ДО записи режима, как там же:
    # запись перестраивает службу агентов, и мост, запущенный агентом, мог не дожить до отзыва (SR-10).
    # Подписки без домена не отдаются, но и не отзываются — пауза до возврата на домен (lib/subs.sh); до страниц,
    # как в website_wipe.
    if type _subs_mode_off_locked >/dev/null 2>&1; then _subs_mode_off_locked || true; fi
    if type _pages_mode_off_locked >/dev/null 2>&1; then _pages_mode_off_locked || true; fi
    _ga_site_set_mode lite "" || return 1
    ga_site_audit "change-mode" "lite (pro off)"
    log_success "$(t website_disabled)"
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  Запасной путь: сайт на IP с самоподписанным сертификатом
# ══════════════════════════════════════════════════════════════════════════════
# website_enable_site_selfsigned [tpl_id|__random__] [lite_site|pro]
#   nginx → самоподписанный сертификат → vhost на IP (server_name _, 80 и 443) →
#   шаблон → config.json (mode = второй аргумент, по умолчанию lite_site;
#   site.cert=selfsigned).
#
# Это НЕ основной путь режимов с сайтом: основной — домен и Let's Encrypt
# (website_enable_pro). Самоподписанный остаётся ровно для двух случаев,
# названных владельцем: домена ещё нет или A-запись ещё не указывает на сервер.
# Браузер такому сертификату не доверяет, поэтому панель на домене здесь не
# работает — только через SSH-туннель. Повторный вызов — ремонт vhost. stdout пуст.
website_enable_site_selfsigned() { ga_with_config_lock _website_enable_site_selfsigned_locked "$@"; }
_website_enable_site_selfsigned_locked() {
    local tpl="${1:-}" target="${2:-lite_site}" ip fp
    case "$target" in pro|lite_site) ;; *) ga_err invalid_mode "$(tf website_err_mode "$target")" 2; return 2 ;; esac
    ip=$(ga_site_server_ip)
    log_step "$(tf website_site_enable_title "${ip:--}")"
    # 1. nginx
    website_ensure_nginx || return 1
    # 2. Сертификат (живой не трогаем: отпечаток закреплён у агентов)
    _website_selfsigned_ensure_locked || return 1
    # 3. Маршрут агентов MCP, если транспорт уже включён
    _ga_site_mcp_route_auto || return 1
    # 4. vhost на IP
    _website_write_conf_locked "" selfsigned || return 1
    # 5. Шаблон
    _ga_site_ensure_template "$tpl" || return 1
    # 6. Режим
    _ga_site_set_mode "$target" selfsigned || return 1
    ga_site_audit "change-mode" "$target selfsigned"
    fp=$(website_cert_fingerprint 2>/dev/null) || fp="-"
    log_success "$(tf website_site_enabled "https://${ip:--}/" "$fp")"
    return 0
}

# website_disable_site — любой режим с сайтом → Lite: vhost убрать, файлы сайта и
# сертификаты оставить на диске (обратный переход не качает шаблон, не меняет
# отпечаток и не тратит лимит Let's Encrypt), mode=lite. stdout пуст.
website_disable_site() { ga_with_config_lock _website_disable_site_locked "$@"; }
_website_disable_site_locked() {
    _website_remove_vhost_locked --or-refuse || return $?
    # Страницы подключения без домена мертвы: отозвать, снять службу и флаг
    # маршрута (lib/pages.sh). Без модуля — нечего снимать. ДО записи режима: запись
    # перезапускает службу агентов, и мост, запущенный агентом, мог не дожить до
    # отзыва страниц (находка SR-10, 25.09.2026).
    # Подписки без домена не отдаются, но и не отзываются — пауза до возврата на домен (lib/subs.sh); до страниц,
    # как в website_wipe.
    if type _subs_mode_off_locked >/dev/null 2>&1; then _subs_mode_off_locked || true; fi
    if type _pages_mode_off_locked >/dev/null 2>&1; then _pages_mode_off_locked || true; fi
    _ga_site_autorenew "$(ga_config_get .domain 2>/dev/null)" off
    _ga_site_set_mode lite "" || return 1
    ga_site_audit "change-mode" "lite (site off)"
    log_success "$(t website_site_disabled)"
    return 0
}
