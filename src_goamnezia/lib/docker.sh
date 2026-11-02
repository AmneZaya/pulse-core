#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# goAmnezia pro — lib/docker.sh: Docker на хосте (контракт §4.3)
#
# Зачем отдельный модуль: все обращения к docker идут только через эти функции.
# Тогда один флаг GOAMNEZIA_DRY_RUN=1 превращает любой сценарий (установка
# профиля, смена порта, восстановление из state/) в прогон, который можно
# проверить на машине без Docker (macOS, CI): каждая функция печатает в stderr
# строку `DRY: <команда>` и возвращает 0, ничего не выполняя.
# Исключения по контракту: docker_container_state → «missing»,
# docker_read_file → пусто.
#
# Состояния контейнера: running | exited | missing | docker_unreachable.
# Последнее — «мы НЕ ЗНАЕМ»: демон не отвечает или отказывает по версии API.
# Смешивать его с missing нельзя, см. раздел «Версия API демона» ниже.
#
# Правило subshell-capture: в stdout — только результат функции, весь текст
# для человека — в stderr (log_*). Флаги docker run/network create взяты из
# официальных скриптов клиента Amnezia (client/server_scripts/awg/run_container.sh,
# prepare_host.sh) — так контейнер неотличим от поставленного приложением.
#
# Ошибки. Функция пишет log_error в stderr и возвращает ≠ 0; машинный код для
# моста --action уходит через ga_err в GA_LAST_ERROR_CODE (штатный механизм
# lib/common.sh, ga_set_error) и дублируется в GA_ERR_CODE, сообщение — в
# GA_ERR_MSG. Коды возврата: 1 — не получилось (внешняя команда), 2 — неверный
# ввод, 3 — не найдено, 4 — не реализовано. Переменные живут в текущей
# оболочке: диспетчеру стоит забирать stdout функции в файл (fn >"$tmp"),
# а не через $(…) — подоболочка их теряет.
#
# Зависимости (lib/common.sh, контракт §4.1): log_*, t/tf, apt_install,
# UPSTREAM_DIR (для images.json).
# ══════════════════════════════════════════════════════════════════════════════

# Сеть контейнеров Amnezia — ровно как в prepare_host.sh приложения: одна и та же
# сеть нужна, чтобы контейнер amnezia-dns (если его поставит приложение) видел
# наши контейнеры по фиксированным адресам.
GA_DOCKER_NET="amnezia-dns-net"
GA_DOCKER_NET_SUBNET="172.29.172.0/24"
GA_DOCKER_NET_BRIDGE="amn0"

GA_ERR_CODE=""
GA_ERR_MSG=""

# ── Общие помощники ────────────────────────────────────────────────────────────

ga_dry() { [ "${GOAMNEZIA_DRY_RUN:-0}" = "1" ]; }
ga_dry_echo() { printf 'DRY: %s\n' "$*" >&2; }

# ga_err <код> <сообщение> [rc] — единая точка ошибки: лог + код для моста.
ga_err() {
    GA_ERR_CODE="$1"
    GA_ERR_MSG="$2"
    if declare -F ga_set_error >/dev/null 2>&1; then
        ga_set_error "$1"
    fi
    log_error "$2"
    return "${3:-1}"
}

# ga_capture <переменная> <функция> [аргументы…] — stdout функции в переменную
# БЕЗ подоболочки: `x=$(fn)` выполняет fn в дочернем процессе, и код ошибки,
# который fn положила в GA_ERR_CODE / GA_LAST_ERROR_CODE, наружу не доходит.
# Здесь stdout идёт во временный файл в той же оболочке, переменные остаются.
#
# Временный файл — секретный: через этот захват проходят готовые клиентские
# конфиги и ссылки vpn://, то есть приватные ключи людей. Обычный mktemp клал
# бы их в общий каталог временных файлов, а rm снимает имя, а не содержимое.
# ga_mktemp_secret выбирает каталог в памяти, ga_wipe_file затирает нулями
# перед удалением (lib/common.sh).
ga_capture() {
    local __var="$1"; shift
    local __tmp __rc=0
    if type ga_mktemp_secret >/dev/null 2>&1; then
        __tmp=$(ga_mktemp_secret gacap) || return 1
    else
        __tmp=$(mktemp) || return 1
    fi
    "$@" >"$__tmp" || __rc=$?
    printf -v "$__var" '%s' "$(<"$__tmp")"
    if type ga_wipe_file >/dev/null 2>&1; then
        ga_wipe_file "$__tmp"
    else
        rm -f "$__tmp"
    fi
    return "$__rc"
}

# ── Версия API демона: рассогласование CLI ↔ демон ─────────────────────────────
#
# История, ради которой этот раздел появился (стенд, ночь на 10.09.2026).
# На сервере с unattended-upgrades пакет docker.io обновляется ночью САМ, а
# демон при этом НЕ перезапускается: рестарт уронил бы разом все контейнеры, и
# postinst пакета его сознательно не делает. Это не редкость и не поломка —
# это обычное состояние любого сервера с автообновлениями, и живёт оно до
# ближайшей перезагрузки или до ручного `systemctl restart docker`.
# Наутро новый CLI просит API 1.52, а живой (старый) демон понимает максимум
# 1.43, и КАЖДАЯ команда docker падает:
#     Error response from daemon: client version 1.52 is too new.
#     Maximum supported API version is 1.43
# Контейнеры при этом работают и VPN раздаёт трафик — слепнет только
# управление. Раньше это выглядело как «контейнеров нет»: статус показывал
# missing, сторож каждые два часа звал восстанавливать живой профиль из
# бэкапа, а тик квот отчитывался success с нулями — лимиты и сроки молча
# переставали работать. Второе опаснее первого: ложная тревога видна, а
# молчаливо неработающие лимиты — нет.
#
# Что делаем. Один раз за процесс спрашиваем версию у САМОГО ДЕМОНА (CLI в
# этот момент и есть источник ошибки) через его сокет: GET /version отдаёт
# ApiVersion и MinAPIVersion и рассогласованию не подвержен. Полученное
# закрепляем в DOCKER_API_VERSION — переменную читает клиент docker и все
# наши дочерние процессы. Это заплатка, а не лечение: правильное лечение —
# перезапуск службы Docker. С 04.10.2026 его делает сам сторож, когда к VPN
# никто не подключён, а человек — кнопкой (раздел «Старый демон» ниже, DK-02).

# Имя состояния «про контейнер ничего не известно» — вынесено, чтобы его
# нельзя было перепутать с missing опечаткой.
GA_DOCKER_STATE_UNREACHABLE="docker_unreachable"

GA_DOCKER_API_PINNED=""      # 1 — за этот процесс версию уже определяли
GA_DOCKER_API_DAEMON=""      # версия API, которую понимает демон
GA_DOCKER_API_CLIENT=""      # версия API, которую CLI просит по умолчанию
GA_DOCKER_API_SOURCE=""      # env | socket | error | dry | none — откуда узнали
GA_DOCKER_VERSION_RAW=""     # ответ демона на /version (кэш на процесс)
GA_DOCKER_VERSION_TRIED=""   # 1 — уже ходили за ним

# Путь к сокету демона с оглядкой на DOCKER_HOST: пусто → /var/run/docker.sock,
# unix://… → путь из него; у tcp:// и ssh:// сокета нет вовсе (rc 1).
ga_docker_socket() {
    case "${DOCKER_HOST:-}" in
        "")       printf '%s' "${GOAMNEZIA_DOCKER_SOCK:-/var/run/docker.sock}" ;;
        unix://*) printf '%s' "${DOCKER_HOST#unix://}" ;;
        *)        return 1 ;;
    esac
}

# _ga_docker_version_fixture → файл-фикстура ответа демона на GET /version (стенд), rc 1 — фикстуры нет. После
# перезапуска демона в сухом прогоне (docker_daemon_restart) — GOAMNEZIA_DOCKER_VERSION_JSON_AFTER, если задан:
# демон «поднялся» той версии, что лежит на диске; файла нет — демон не поднялся.
GA_DOCKER_DRY_RESTARTED=""
_ga_docker_version_fixture() {
    [ -n "${GOAMNEZIA_DOCKER_VERSION_JSON:-}" ] || return 1
    if [ -n "$GA_DOCKER_DRY_RESTARTED" ] && [ -n "${GOAMNEZIA_DOCKER_VERSION_JSON_AFTER:-}" ]; then
        printf '%s' "$GOAMNEZIA_DOCKER_VERSION_JSON_AFTER"
    else
        printf '%s' "$GOAMNEZIA_DOCKER_VERSION_JSON"
    fi
}

# ga_docker_version_raw → тело ответа демона на GET /version (кэш на процесс).
# Тестовый крючок GOAMNEZIA_DOCKER_VERSION_JSON — файл с таким ответом: на
# macOS сокета нет вовсе, а проверять разбор надо.
ga_docker_version_raw() {
    if [ -z "$GA_DOCKER_VERSION_TRIED" ]; then
        GA_DOCKER_VERSION_TRIED=1
        local sock url fx
        if fx=$(_ga_docker_version_fixture); then
            [ -r "$fx" ] && GA_DOCKER_VERSION_RAW=$(cat "$fx" 2>/dev/null)
        elif command -v curl >/dev/null 2>&1; then
            if sock=$(ga_docker_socket) && [ -S "$sock" ]; then
                GA_DOCKER_VERSION_RAW=$(curl -s --max-time 5 --unix-socket "$sock" http://localhost/version 2>/dev/null) || GA_DOCKER_VERSION_RAW=""
            else
                case "${DOCKER_HOST:-}" in
                    tcp://*)            url="http://${DOCKER_HOST#tcp://}/version" ;;
                    http://*|https://*) url="${DOCKER_HOST%/}/version" ;;
                    *)                  url="" ;;
                esac
                [ -n "$url" ] && { GA_DOCKER_VERSION_RAW=$(curl -s --max-time 5 "$url" 2>/dev/null) || GA_DOCKER_VERSION_RAW=""; }
            fi
        fi
    fi
    [ -n "$GA_DOCKER_VERSION_RAW" ] || return 1
    printf '%s' "$GA_DOCKER_VERSION_RAW"
}

# Строковое поле верхнего уровня из ответа демона. jq — основной путь; sed —
# запасной: диагностика Docker не должна зависеть от того, поставлен ли jq.
ga_docker_json_field() {
    local raw="$1" key="$2" v=""
    if command -v jq >/dev/null 2>&1; then
        v=$(printf '%s' "$raw" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null)
    fi
    [ -n "$v" ] || v=$(printf '%s' "$raw" | tr ',' '\n' | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | tail -n 1)
    printf '%s' "$v"
}

# ga_docker_api_client → версия API, которую CLI просит по умолчанию. Ответ
# берём даже при ненулевом коде: `docker version` печатает секцию Client и
# падает уже на секции Server — ровно наш случай.
ga_docker_api_client() {
    local v
    v=$(command docker version --format '{{.Client.APIVersion}}' 2>/dev/null | head -n 1 | tr -d '[:space:]')
    [[ "$v" =~ ^[0-9]+\.[0-9]+$ ]] && printf '%s' "$v"
    return 0
}

# ga_docker_api_error → версия демона из ТЕКСТА его отказа («Maximum supported
# API version is 1.43»). Запасной путь, когда сокета не видно: чужой
# DOCKER_HOST, нет curl, сокет за другим путём.
ga_docker_api_error() {
    local out v
    out=$(command docker version 2>&1 >/dev/null)
    v=$(printf '%s' "$out" | sed -n 's/.*aximum supported API version is \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1)
    [ -n "$v" ] && printf '%s' "$v"
    return 0
}

# ga_docker_api_lt <a> <b> — a строго меньше b (major.minor).
ga_docker_api_lt() {
    local a="$1" b="$2"
    [[ "$a" =~ ^[0-9]+\.[0-9]+$ && "$b" =~ ^[0-9]+\.[0-9]+$ ]] || return 1
    [ "${a%%.*}" -lt "${b%%.*}" ] && return 0
    [ "${a%%.*}" -gt "${b%%.*}" ] && return 1
    [ "${a#*.}" -lt "${b#*.}" ]
}

# docker_api_pin [--probe] — определить и ЗАКРЕПИТЬ версию API демона на весь
# процесс. Идемпотентна и дешева: ходит к сокету ровно один раз, дальше
# возвращается сразу. Заданную снаружи DOCKER_API_VERSION не трогает — это
# может быть решение человека или юнита.
#
# В dry-run по умолчанию не делает ничего: там docker не зовут вовсе, и
# спрашивать его версию не у кого. Исключение — флаг --probe для диагностики
# (quality): она обязана называть настоящее положение дел, а не «мы не
# смотрели», и docker info рядом с ней и так выполняется по-настоящему.
docker_api_pin() {
    local probe=""
    [ "${1:-}" = "--probe" ] && probe=1
    [ -z "$GA_DOCKER_API_PINNED" ] || return 0
    GA_DOCKER_API_PINNED=1
    GA_DOCKER_API_SOURCE="none"
    if [ -n "${DOCKER_API_VERSION:-}" ]; then
        GA_DOCKER_API_DAEMON="$DOCKER_API_VERSION"
        GA_DOCKER_API_SOURCE="env"
        return 0
    fi
    if ga_dry && [ -z "$probe" ]; then
        GA_DOCKER_API_SOURCE="dry"
        return 0
    fi
    command -v docker >/dev/null 2>&1 || return 0
    local daemon="" client pin
    # Ответ /version — в этой оболочке, а не подоболочкой $(…): иначе кэш на процесс оставался в подоболочке, и
    # проверка «старый ли демон» (ниже) ходила к сокету ещё раз.
    ga_docker_version_raw >/dev/null 2>&1 && daemon=$(ga_docker_json_field "$GA_DOCKER_VERSION_RAW" ApiVersion)
    if [[ "$daemon" =~ ^[0-9]+\.[0-9]+$ ]]; then
        GA_DOCKER_API_SOURCE="socket"
    else
        daemon=$(ga_docker_api_error)
        if [[ "$daemon" =~ ^[0-9]+\.[0-9]+$ ]]; then
            GA_DOCKER_API_SOURCE="error"
        else
            daemon=""
        fi
    fi
    client=$(ga_docker_api_client)
    GA_DOCKER_API_CLIENT="$client"
    [ -n "$daemon" ] || return 0
    GA_DOCKER_API_DAEMON="$daemon"
    # Просить у CLI версию, которой он сам не умеет, нельзя: бывает и обратное
    # рассогласование (демон новее клиента — откатили пакет). Берём меньшую.
    pin="$daemon"
    if [ -n "$client" ] && ga_docker_api_lt "$client" "$daemon"; then
        pin="$client"
    fi
    export DOCKER_API_VERSION="$pin"
    # Заплатка держит управление, но сама по себе не пройдёт: пока демон не
    # перезапустят, он остаётся старым. Говорим об этом вслух — но по-разному
    # человеку и журналу. «Один раз за процесс» верно для меню и неверно для
    # таймеров: сторож просыпается каждые две минуты, и за сутки одна и та же
    # строка попадала в журнал 581 раз (стенд, 11.09.2026), раздувая его на
    # десятки мегабайт и топя в себе настоящие события. Человеку за терминалом
    # говорим всегда, в журнал — не чаще раза в шесть часов.
    if [ -n "$client" ] && ga_docker_api_lt "$daemon" "$client"; then
        # Человеку за терминалом — сразу, но один раз на запуск: подоболочка $(…) определяет версию сама и не
        # передаёт закрепление родителю, и строка повторялась (обновление 1.0.2 → 1.0.6 у владельца, 29.09) —
        # отсюда окно в 5 минут; в журнал — не чаще раза в шесть часов.
        # Человеку — словами и без пугающих чисел: владелец читал строку с версиями API и «systemctl restart docker»
        # при каждом обновлении как ошибку (DK-02, 04.10.2026). Лечит её теперь сам продукт (раздел «Старый демон»
        # ниже), а журналу нужны цифры — у него своя строка.
        if [ -t 2 ] && _ga_docker_warn_due tty 300; then
            log_warning "$(t docker_warn_api_mismatch)"
        elif [ ! -t 2 ] && _ga_docker_warn_due journal 21600; then
            log_warning "$(tf docker_log_api_pinned "$client" "$daemon" "$pin")"
        fi
    fi
    return 0
}

# _ga_docker_warn_due <tty|journal> <секунды> — пора ли повторять предупреждение о рассогласовании версий: у
# терминала и журнала отметки свои. Отметка живёт в LOCK_DIR, то есть в /run — после перезагрузки скажем заново, и
# это правильно: перезагрузка могла как вылечить рассогласование, так и оставить его.
_ga_docker_warn_due() {
    local stamp="${LOCK_DIR:-/run/goamnezia}/docker-api-warned" window="${2:-21600}" now=0 was=0
    [ "${1:-journal}" = tty ] && stamp="$stamp-tty"
    now=$(date +%s 2>/dev/null) || return 0
    { mkdir -p "${LOCK_DIR:-/run/goamnezia}"; } 2>/dev/null || return 0
    if [ -f "$stamp" ]; then
        was=$(cat "$stamp" 2>/dev/null) || was=0
        [[ "$was" =~ ^[0-9]+$ ]] || was=0
        [ $(( now - was )) -ge "$window" ] || return 1
    fi
    { printf '%s\n' "$now" >"$stamp"; } 2>/dev/null || true
    return 0
}

# ga_docker <аргументы docker> — единственная точка вызова CLI: перед первым
# вызовом закрепляет версию API. `command` — чтобы обёртка не нашла саму себя,
# если docker когда-нибудь окажется функцией.
ga_docker() {
    docker_api_pin
    command docker "$@"
}

# docker_daemon_alive — демон отвечает? Спрашиваем его собственный /_ping:
# CLI в момент рассогласования отказывает даже на живом демоне.
docker_daemon_alive() {
    local sock code fx
    if fx=$(_ga_docker_version_fixture); then [ -r "$fx" ]; return $?; fi
    if command -v curl >/dev/null 2>&1 && sock=$(ga_docker_socket) && [ -S "$sock" ]; then
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --unix-socket "$sock" http://localhost/_ping 2>/dev/null)
        [ "$code" = "200" ]
        return $?
    fi
    ga_docker version --format '{{.Server.Version}}' >/dev/null 2>&1
}

# Разбор текста отказа docker: «демон не отвечает / отказывает по версии». Отказ бывает и в обратную сторону:
# закрепление старой версии API пережило перезапуск демона, а Docker 29 не понимает API ниже 1.44 («client version
# 1.43 is too old. Minimum supported API version is 1.44») — это тоже «не знаем», а не «контейнера нет».
ga_docker_err_unreachable() {
    printf '%s' "${1:-}" | grep -qiE 'cannot connect to the docker daemon|is the docker daemon running|client version .* is too (new|old)|(maximum|minimum) supported api version|permission denied while trying to connect|connect: no such file or directory|connection refused|context deadline exceeded'
}
# Разбор текста отказа docker: «такого объекта нет» — контейнер правда пропал.
ga_docker_err_no_such() {
    printf '%s' "${1:-}" | grep -qiE 'no such object|no such container'
}
# Разбор текста отказа docker: «строк не отдам» — контейнер запущен с драйвером
# логов, который не умеет читать. У профилей это НАШ выбор: docker_run_awg
# ставит --log-driver none, как и само приложение AmneziaVPN, поэтому docker
# logs для них не заработает никогда — и сказать об этом надо словами, а не
# показывать пустой экран.
ga_docker_err_no_logs() {
    printf '%s' "${1:-}" | grep -qiE 'logging driver does not support reading|does not support reading'
}

# ── Старый демон: пакет обновлён, служба не перезапущена (DK-02) ────────────────
#
# Рассогласование API (раздел выше) — частный случай беды побольше. Ubuntu обновляет пакет docker.io
# автообновлением, а службу не перезапускает (вопрос debconf docker.io/restart, по умолчанию «нет»): на сервере
# владельца с 01.10 по 04.10.2026 работал демон 24.0.7 при пакете 29.1.3. Заплатка с версией API держит управление,
# но обновление безопасности Docker не действует, пока службу не перезапустят. Бывает и без рассогласования API — та
# же версия с исправленной сборкой (29.1.3-0ubuntu3~24.04.1 → ~24.04.2): API прежний, а демон всё равно старый.
# Поэтому сравниваем бинарь на диске — то, что поднимет `systemctl restart docker`, — с работающим демоном:
#   • бинарь — `dockerd --version` («Docker version 29.1.3, build 29.1.3-0ubuntu3~24.04.2»); dockerd не нашёлся —
#     версия пакета (dpkg-query: docker.io, docker-ce, moby-engine), у пакета сборка с демоном не сравнима;
#   • демон — его ответ на GET /version (Version и GitCommit, тот же кэш, что у docker_api_pin);
#   • версии или сборки разные — демон старый; одинаковые — нет, даже при рассогласовании API: клиент тогда из
#     другого пакета, и перезапуск его не вылечит; бинарь или демон не узнать — по рассогласованию API, как раньше.
# Демон не отвечает вовсе — не «старый», а «лежит»: это docker_unreachable у сторожа.
# Лечение — перезапуск службы: сторож делает его сам, когда к VPN никто не подключён (lib/amnezia.sh,
# ga_amn_docker_stale_watch), человек — «Обслуживание → Перезапустить Docker» (мост docker-restart).
# Стенд: GOAMNEZIA_DOCKERD_VERSION — что печатает `dockerd --version`, GOAMNEZIA_DOCKERD_SINCE — когда заменён бинарь
# (секунды с 1970); сухой прогон без них бинаря не знает, а демона — без GOAMNEZIA_DOCKER_VERSION_JSON: машина
# прогона исход не решает.

GA_DOCKER_BIN_TRIED=""      # 1 — бинарь за этот процесс уже смотрели
GA_DOCKER_BIN_VER=""        # версия бинаря на диске («29.1.3»)
GA_DOCKER_BIN_BUILD=""      # его сборка («29.1.3-0ubuntu3~24.04.2»); у версии пакета — пусто
GA_DOCKER_BIN_SINCE=""      # когда бинарь заменён, секунды с 1970 (ctime: пакет кладёт новый файл переименованием)
GA_DOCKER_STALE=""          # 1 — демон старый, 0 — нет, пусто — ещё не смотрели
GA_DOCKER_STALE_REASON=""   # version | build | api
GA_DOCKER_DAEMON_VER=""     # версия работающего демона (Version из /version)
GA_DOCKER_DAEMON_BUILD=""   # его сборка (GitCommit)

# _ga_docker_iso <секунды с 1970> → «2026-10-01T06:12:00Z».
_ga_docker_iso() {
    [[ "${1:-}" =~ ^[0-9]{1,12}$ ]] || return 1
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# docker_label <версия> <сборка> <версия другой стороны> → что показать человеку: версию, а если версии с другой
# стороной совпадают (разница только в сборке) — сборку. «Docker обновлён до 29.1.3, а служба старая (29.1.3)»
# человеку не говорит ничего (живая проверка на test1, 04.10.2026: пакет и служба различались одной сборкой).
docker_label() {
    if [ -n "${2:-}" ] && [ "${1:-}" = "${3:-}" ]; then printf '%s' "$2"; else printf '%s' "${1:-}"; fi
}

# _ga_docker_bin_parse <строка `dockerd --version`> → GA_DOCKER_BIN_VER и GA_DOCKER_BIN_BUILD; rc 1 — не разобрать.
_ga_docker_bin_parse() {
    local re='[Vv]ersion[[:space:]]+([0-9][0-9A-Za-z.+~-]*)(,[[:space:]]*build[[:space:]]+([^[:space:],]+))?'
    [[ "${1:-}" =~ $re ]] || return 1
    GA_DOCKER_BIN_VER="${BASH_REMATCH[1]}"
    GA_DOCKER_BIN_BUILD="${BASH_REMATCH[3]}"
    return 0
}

# _ga_docker_bin_probe [--probe] — версия и сборка бинаря демона на диске (GA_DOCKER_BIN_*), один раз за процесс.
# `dockerd --version` — запуск 80-мегабайтного бинаря, а status зовут часто (Обзор панели раз в 10 с, CPU-03): ответ
# кэшируется в LOCK_DIR/dockerd-version под ключом «путь inode размер mtime ctime» — новый пакет кладёт новый файл, и
# ключ меняется сам. rc 1 — не узнать.
_ga_docker_bin_probe() {
    if [ -n "$GA_DOCKER_BIN_TRIED" ]; then [ -n "$GA_DOCKER_BIN_VER" ]; return $?; fi
    GA_DOCKER_BIN_TRIED=1
    GA_DOCKER_BIN_VER=""; GA_DOCKER_BIN_BUILD=""; GA_DOCKER_BIN_SINCE=""
    local bin st="" key cache line="" raw="" pkg v
    if [ -n "${GOAMNEZIA_DOCKERD_VERSION:-}" ]; then
        GA_DOCKER_BIN_SINCE="${GOAMNEZIA_DOCKERD_SINCE:-}"
        _ga_docker_bin_parse "$GOAMNEZIA_DOCKERD_VERSION"
        return $?
    fi
    ga_dry && [ "${1:-}" != --probe ] && return 1
    if bin=$(command -v dockerd 2>/dev/null) && [ -n "$bin" ]; then
        st=$(stat -L -c '%i %s %Y %Z' "$bin" 2>/dev/null || stat -L -f '%i %z %m %c' "$bin" 2>/dev/null) || st=""
        cache="${LOCK_DIR:-/run/goamnezia}/dockerd-version"
        key="$bin $st"
        [ -n "$st" ] && { IFS= read -r line <"$cache"; } 2>/dev/null
        if [ -n "$st" ] && [ -n "$line" ] && [ "${line%%$'\t'*}" = "$key" ]; then
            raw="${line#*$'\t'}"
        else
            if command -v timeout >/dev/null 2>&1; then
                raw=$(timeout 10 "$bin" --version 2>/dev/null | head -n 1)
            else
                raw=$("$bin" --version 2>/dev/null | head -n 1)
            fi
            if [ -n "$st" ] && [ -n "$raw" ]; then
                { mkdir -p "${cache%/*}" && printf '%s\t%s\n' "$key" "$raw" >"$cache.$$" && mv -f "$cache.$$" "$cache"; } 2>/dev/null \
                    || rm -f "$cache.$$" 2>/dev/null
            fi
        fi
        if _ga_docker_bin_parse "$raw"; then
            [ -n "$st" ] && GA_DOCKER_BIN_SINCE="${st##* }"
            return 0
        fi
    fi
    # dockerd нет в PATH или он не ответил — версия установленного пакета: «5:27.3.1-1~ubuntu…» → «27.3.1».
    command -v dpkg-query >/dev/null 2>&1 || return 1
    for pkg in docker.io docker-ce moby-engine; do
        v=$(dpkg-query -W -f='${Status}|${Version}' "$pkg" 2>/dev/null) || continue
        case "$v" in *" installed|"*) ;; *) continue ;; esac
        v="${v##*|}"; v="${v#*:}"; v="${v%%-*}"
        [[ "$v" =~ ^[0-9][0-9A-Za-z.+~]*$ ]] || continue
        GA_DOCKER_BIN_VER="$v"
        GA_DOCKER_BIN_SINCE=$(stat -c %Y "/var/lib/dpkg/info/$pkg.list" 2>/dev/null || stat -f %m "/var/lib/dpkg/info/$pkg.list" 2>/dev/null) \
            || GA_DOCKER_BIN_SINCE=""
        return 0
    done
    return 1
}

# docker_stale_probe [--probe] → rc 0 — демон старый: пакет обновлён, служба не перезапущена. Причина и версии — в
# GA_DOCKER_STALE_REASON, GA_DOCKER_BIN_*, GA_DOCKER_DAEMON_*, GA_DOCKER_API_*. Один раз за процесс; после
# перезапуска демона — заново (docker_stale_reset). --probe — как у docker_api_pin: смотреть и в сухом прогоне.
docker_stale_probe() {
    local probe="" raw
    [ "${1:-}" = --probe ] && probe=--probe
    if [ -n "$GA_DOCKER_STALE" ]; then [ "$GA_DOCKER_STALE" = 1 ]; return $?; fi
    GA_DOCKER_STALE=0; GA_DOCKER_STALE_REASON=""; GA_DOCKER_DAEMON_VER=""; GA_DOCKER_DAEMON_BUILD=""
    docker_api_pin ${probe:+"$probe"}
    if ! ga_dry || [ -n "$probe" ] || _ga_docker_version_fixture >/dev/null; then
        if ga_docker_version_raw >/dev/null 2>&1; then
            raw="$GA_DOCKER_VERSION_RAW"
            # Оба поля одним jq: status зовут часто (CPU-03). Без jq — запасной разбор по полю (GitCommit верхнего
            # уровня в ответе идёт последним, после вложенных Components).
            if command -v jq >/dev/null 2>&1; then
                IFS=$'\x1f' read -r GA_DOCKER_DAEMON_VER GA_DOCKER_DAEMON_BUILD \
                    <<<"$(jq -r '[(.Version // "" | tostring), (.GitCommit // "" | tostring)] | join("\u001f")' <<<"$raw" 2>/dev/null)" || true
            else
                GA_DOCKER_DAEMON_VER=$(ga_docker_json_field "$raw" Version)
                GA_DOCKER_DAEMON_BUILD=$(ga_docker_json_field "$raw" GitCommit)
            fi
        fi
    fi
    _ga_docker_bin_probe ${probe:+"$probe"}
    if [ -n "$GA_DOCKER_BIN_VER" ] && [ -n "$GA_DOCKER_DAEMON_VER" ]; then
        if [ "$GA_DOCKER_BIN_VER" != "$GA_DOCKER_DAEMON_VER" ]; then
            GA_DOCKER_STALE_REASON=version
        elif [ -n "$GA_DOCKER_BIN_BUILD" ] && [ -n "$GA_DOCKER_DAEMON_BUILD" ] \
             && [ "$GA_DOCKER_BIN_BUILD" != "$GA_DOCKER_DAEMON_BUILD" ]; then
            GA_DOCKER_STALE_REASON=build
        fi
    elif [ -n "$GA_DOCKER_API_CLIENT" ] && [ -n "$GA_DOCKER_API_DAEMON" ] \
         && ga_docker_api_lt "$GA_DOCKER_API_DAEMON" "$GA_DOCKER_API_CLIENT"; then
        GA_DOCKER_STALE_REASON=api
    fi
    [ -n "$GA_DOCKER_STALE_REASON" ] || return 1
    GA_DOCKER_STALE=1
    return 0
}

# docker_stale_sig → подпись «этого» старого демона (демон, бинарь, API): сторож говорит о каждом обнаружении один
# раз, а новая подпись — пакет обновили ещё раз — это новое обнаружение.
docker_stale_sig() {
    printf '%s/%s>%s/%s|%s>%s' "${GA_DOCKER_DAEMON_VER:--}" "${GA_DOCKER_DAEMON_BUILD:--}" "${GA_DOCKER_BIN_VER:--}" \
        "${GA_DOCKER_BIN_BUILD:--}" "${GA_DOCKER_API_DAEMON:--}" "${GA_DOCKER_API_CLIENT:--}"
}

# docker_stale_json [--probe] → поле docker_stale (status, quality): null — демон не старый или не узнать, иначе
# {reason, binary_version, binary_build, daemon_version, daemon_build, client_api, daemon_api, since, binary_label,
# daemon_label}; since — когда заменён бинарь (ISO-8601 UTC), пусто — не узнать; *_label — что показать человеку
# (docker_label: при одной версии — сборка), пусто — версии не узнать (тогда — версии API).
docker_stale_json() {
    docker_stale_probe "$@" || { printf 'null'; return 0; }
    local since=""
    since=$(_ga_docker_iso "$GA_DOCKER_BIN_SINCE") || since=""
    jq -cn --arg r "$GA_DOCKER_STALE_REASON" --arg bv "$GA_DOCKER_BIN_VER" --arg bb "$GA_DOCKER_BIN_BUILD" \
           --arg dv "$GA_DOCKER_DAEMON_VER" --arg db "$GA_DOCKER_DAEMON_BUILD" --arg ca "$GA_DOCKER_API_CLIENT" \
           --arg da "$GA_DOCKER_API_DAEMON" --arg s "$since" \
           --arg bl "$(docker_label "$GA_DOCKER_BIN_VER" "$GA_DOCKER_BIN_BUILD" "$GA_DOCKER_DAEMON_VER")" \
           --arg dl "$(docker_label "$GA_DOCKER_DAEMON_VER" "$GA_DOCKER_DAEMON_BUILD" "$GA_DOCKER_BIN_VER")" \
        '{reason: $r, binary_version: $bv, binary_build: $bb, daemon_version: $dv, daemon_build: $db,
          client_api: $ca, daemon_api: $da, since: $s, binary_label: $bl, daemon_label: $dl}'
}

# docker_stale_reset — забыть всё, что процесс знал о демоне: версию API и своё закрепление (заданную снаружи
# DOCKER_API_VERSION не трогаем), ответ /version, бинарь и вердикт «старый». Нужна после перезапуска демона:
# прежнее закрепление новый демон может и не принять — Docker 29 не понимает API ниже 1.44.
docker_stale_reset() {
    case "$GA_DOCKER_API_SOURCE" in socket|error) unset DOCKER_API_VERSION ;; esac
    GA_DOCKER_API_PINNED=""; GA_DOCKER_API_DAEMON=""; GA_DOCKER_API_CLIENT=""; GA_DOCKER_API_SOURCE=""
    GA_DOCKER_VERSION_RAW=""; GA_DOCKER_VERSION_TRIED=""
    GA_DOCKER_BIN_TRIED=""; GA_DOCKER_BIN_VER=""; GA_DOCKER_BIN_BUILD=""; GA_DOCKER_BIN_SINCE=""
    GA_DOCKER_STALE=""; GA_DOCKER_STALE_REASON=""; GA_DOCKER_DAEMON_VER=""; GA_DOCKER_DAEMON_BUILD=""
    return 0
}

# docker_pin_refresh — долгоживущему процессу (SSH-меню): демон перезапустили без него (сторож, человек) — всё о
# демоне заново, иначе закрепление старой версии API отказывало бы новому демону, а шапка твердила бы «служба
# старая». Один запрос к сокету: ответ /version у живого демона не меняется, и сравнить его можно строкой. Бинарь и
# вердикт — заново всегда (stat и кэш в LOCK_DIR): пакет могли обновить, пока меню открыто.
docker_pin_refresh() {
    local sock now_raw=""
    GA_DOCKER_BIN_TRIED=""; GA_DOCKER_STALE=""
    [ -n "$GA_DOCKER_VERSION_TRIED" ] || return 0
    _ga_docker_version_fixture >/dev/null && return 0
    command -v curl >/dev/null 2>&1 && sock=$(ga_docker_socket) && [ -S "$sock" ] || return 0
    now_raw=$(curl -s --max-time 3 --unix-socket "$sock" http://localhost/version 2>/dev/null) || now_raw=""
    [ -n "$now_raw" ] && [ "$now_raw" != "$GA_DOCKER_VERSION_RAW" ] || return 0
    docker_stale_reset
}

# docker_pkg_busy → rc 0, если прямо сейчас идёт apt/dpkg (автообновление могло как раз ставить docker.io или
# containerd): перезапускать службу посреди установки пакета нельзя, сторож подождёт следующего тика. Стенд:
# GOAMNEZIA_DPKG_BUSY=1.
docker_pkg_busy() {
    [ "${GOAMNEZIA_DPKG_BUSY:-0}" = 1 ] && return 0
    ga_dry && return 1
    if command -v fuser >/dev/null 2>&1; then
        fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && return 0
        fuser /var/lib/dpkg/lock >/dev/null 2>&1 && return 0
    fi
    command -v pgrep >/dev/null 2>&1 && pgrep -x dpkg >/dev/null 2>&1 && return 0
    return 1
}

# docker_daemon_restart — перезапустить службу Docker (`systemctl restart docker`) и дождаться, пока демон ответит
# (GOAMNEZIA_DOCKER_RESTART_WAIT, по умолчанию 90 с). Контейнеры с --restart always (профили, соседи) Docker поднимает
# сам, ждать их — дело вызывающего (amnezia_docker_restart). Дальше всё о демоне — заново: прежнее закрепление API
# новый демон может не принять. Коды: docker_restart_failed — systemctl отказал (его слова в сообщении),
# docker_restart_timeout — служба перезапущена, а демон не ответил. Сухой прогон демон не трогает: «DRY: systemctl
# restart docker», а «поднявшийся» демон отвечает фикстурой GOAMNEZIA_DOCKER_VERSION_JSON_AFTER.
docker_daemon_restart() {
    local out="" wait="${GOAMNEZIA_DOCKER_RESTART_WAIT:-90}" i
    [[ "$wait" =~ ^[0-9]{1,4}$ ]] || wait=90
    if ga_dry; then
        ga_dry_echo "systemctl restart docker"
        docker_stale_reset
        GA_DOCKER_DRY_RESTARTED=1
        # Демона стенда изображает фикстура ответа /version; без неё — «поднялся»: машину прогона не спрашиваем.
        if _ga_docker_version_fixture >/dev/null && ! docker_daemon_alive; then
            ga_err docker_restart_timeout "$(tf docker_err_restart_timeout "$wait")"
            return 1
        fi
        return 0
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        ga_err docker_restart_failed "$(tf docker_err_restart_daemon "systemctl: not found")"
        return 1
    fi
    if command -v timeout >/dev/null 2>&1; then
        out=$(timeout 300 systemctl restart docker 2>&1 </dev/null) || i=$?
    else
        out=$(systemctl restart docker 2>&1 </dev/null) || i=$?
    fi
    docker_stale_reset
    if [ -n "${i:-}" ]; then
        out=$(printf '%s' "$out" | tr '\n' ' ' | head -c 300)
        ga_err docker_restart_failed "$(tf docker_err_restart_daemon "${out:-rc $i}")"
        return 1
    fi
    for ((i = 0; i < wait; i++)); do
        docker_daemon_alive && break
        sleep 1
    done
    docker_stale_reset
    if ! docker_daemon_alive; then
        ga_err docker_restart_timeout "$(tf docker_err_restart_timeout "$wait")"
        return 1
    fi
    docker_api_pin
    return 0
}

# docker_diag_json → JSON для диагностики (действие quality):
# {installed, reachable, client_version, client_api, daemon_version, daemon_api,
#  daemon_min_api, api_pinned, api_source, mismatch, restart_required,
#  stale, stale_reason, binary_version, binary_build, daemon_build, stale_since,
#  binary_label, daemon_label}.
# mismatch=true — CLI просит API новее, чем понимает демон: пакет обновили, а
# демон не перезапускали. stale=true — демон старый по сравнению с бинарём на
# диске (раздел «Старый демон»); restart_required — то или другое. Лечится
# перезапуском службы: сторож — сам, человек — «Перезапустить Docker».
docker_diag_json() {
    local installed=false reachable=false raw="" cli_ver="" cli_api="" d_ver="" d_api="" d_min="" pinned="" mismatch=false
    local stale=false since="" b_label="" d_label=""
    if command -v docker >/dev/null 2>&1; then
        installed=true
        docker_api_pin --probe
        cli_ver=$(command docker version --format '{{.Client.Version}}' 2>/dev/null | head -n 1 | tr -d '[:space:]')
        cli_api="$GA_DOCKER_API_CLIENT"
        [ -n "$cli_api" ] || cli_api=$(ga_docker_api_client)
        if ga_docker_version_raw >/dev/null 2>&1; then
            raw="$GA_DOCKER_VERSION_RAW"
            d_ver=$(ga_docker_json_field "$raw" Version)
            d_api=$(ga_docker_json_field "$raw" ApiVersion)
            d_min=$(ga_docker_json_field "$raw" MinAPIVersion)
        fi
        [ -n "$d_api" ] || d_api="$GA_DOCKER_API_DAEMON"
        docker_daemon_alive && reachable=true
        pinned="${DOCKER_API_VERSION:-}"
        if [ -n "$cli_api" ] && [ -n "$d_api" ] && ga_docker_api_lt "$d_api" "$cli_api"; then
            mismatch=true
        fi
        if docker_stale_probe --probe; then
            stale=true
            since=$(_ga_docker_iso "$GA_DOCKER_BIN_SINCE") || since=""
            b_label=$(docker_label "$GA_DOCKER_BIN_VER" "$GA_DOCKER_BIN_BUILD" "$GA_DOCKER_DAEMON_VER")
            d_label=$(docker_label "$GA_DOCKER_DAEMON_VER" "$GA_DOCKER_DAEMON_BUILD" "$GA_DOCKER_BIN_VER")
        fi
    fi
    if command -v jq >/dev/null 2>&1; then
        jq -cn --argjson installed "$installed" --argjson reachable "$reachable" \
               --arg cv "$cli_ver" --arg ca "$cli_api" --arg dv "$d_ver" --arg da "$d_api" \
               --arg dm "$d_min" --arg pin "$pinned" --arg src "$GA_DOCKER_API_SOURCE" \
               --argjson mismatch "$mismatch" --argjson stale "$stale" --arg why "$GA_DOCKER_STALE_REASON" \
               --arg bv "$GA_DOCKER_BIN_VER" --arg bb "$GA_DOCKER_BIN_BUILD" --arg db "$GA_DOCKER_DAEMON_BUILD" \
               --arg since "$since" --arg bl "$b_label" --arg dl "$d_label" \
            '{installed: $installed, reachable: $reachable, client_version: $cv, client_api: $ca,
              daemon_version: $dv, daemon_api: $da, daemon_min_api: $dm, api_pinned: $pin,
              api_source: $src, mismatch: $mismatch, restart_required: ($mismatch or $stale),
              stale: $stale, stale_reason: $why, binary_version: $bv, binary_build: $bb,
              daemon_build: $db, stale_since: $since, binary_label: $bl, daemon_label: $dl}'
    else
        local rr="$mismatch"; [ "$stale" = true ] && rr=true
        printf '{"installed":%s,"reachable":%s,"mismatch":%s,"restart_required":%s,"stale":%s}' \
            "$installed" "$reachable" "$mismatch" "$rr" "$stale"
    fi
}

# ── Установка и служба ─────────────────────────────────────────────────────────

# Docker из репозитория дистрибутива (docker.io + containerd), как делает
# install_docker.sh приложения. podman-docker подсовывает бинарник `docker`,
# но Amnezia на podman не работает (privileged + /lib/modules + сеть) —
# отказываем сразу с кодом docker_unsupported_runtime, как и приложение.
docker_ensure_installed() {
    if ga_dry; then
        ga_dry_echo "apt-get install -y docker.io containerd && systemctl enable --now docker"
        return 0
    fi
    if command -v docker >/dev/null 2>&1; then
        if docker --version 2>/dev/null | grep -qi podman; then
            ga_err docker_unsupported_runtime "$(t docker_err_podman)"
            return 1
        fi
    fi
    if ! command -v docker >/dev/null 2>&1 || { type _deps_check_cmd >/dev/null 2>&1 && ! _deps_check_cmd docker; }; then
        log_info "$(t docker_installing)"
        if type deps_install_missing >/dev/null 2>&1; then
            deps_install_missing --yes docker || { ga_err docker_install_failed "$(t docker_err_install)"; return 1; }
        elif ! apt_install docker.io containerd; then
            ga_err docker_install_failed "$(t docker_err_install)"
            return 1
        fi
    fi
    if [ "$(systemctl is-active docker 2>/dev/null)" != "active" ]; then
        systemctl enable --now docker >/dev/null 2>&1
        sleep 3
        if [ "$(systemctl is-active docker 2>/dev/null)" != "active" ]; then
            ga_err docker_not_running "$(t docker_err_not_running)"
            return 1
        fi
    fi
    if ! ga_docker info >/dev/null 2>&1; then
        ga_err docker_not_running "$(t docker_err_not_running)"
        return 1
    fi
    return 0
}

docker_ensure_network() {
    local -a cmd=(docker network create --driver bridge "--subnet=$GA_DOCKER_NET_SUBNET"
                  --opt "com.docker.network.bridge.name=$GA_DOCKER_NET_BRIDGE" "$GA_DOCKER_NET")
    if ga_dry; then
        ga_dry_echo "${cmd[*]}"
        return 0
    fi
    if grep -qx "$GA_DOCKER_NET" <<<"$(ga_docker network ls --format '{{.Name}}' 2>/dev/null)"; then
        return 0
    fi
    # Массив зовём напрямую (в нём флаги приложения Amnezia дословно), поэтому
    # версию API закрепляем отдельным вызовом — обёртки ga_docker тут нет.
    docker_api_pin
    if ! "${cmd[@]}" >/dev/null 2>&1; then
        ga_err docker_network_failed "$(tf docker_err_network "$GA_DOCKER_NET")"
        return 1
    fi
    return 0
}

# ── Образы ─────────────────────────────────────────────────────────────────────

# docker_image_field <ключ> <поле> — поле записи из lib/upstream/images.json
# (repo, tag, digest, checked). stdout: значение или пусто.
docker_image_field() {
    local key="$1" field="$2" images="${UPSTREAM_DIR:-}/images.json"
    [[ "$key" =~ ^[a-z0-9-]+$ && "$field" =~ ^[a-z_]+$ ]] || return 2
    [ -f "$images" ] || return 3
    jq -r --arg k "$key" --arg f "$field" '.[$k][$f] // empty' "$images" 2>/dev/null
}

# docker_image_ref <ключ> — ссылка для pull/FROM: repo@sha256:… (по дайджесту),
# без дайджеста — repo:tag. Только дайджест воспроизводим: тег latest у Amnezia
# молча переезжает на новую версию демона (решение D8 плана).
docker_image_ref() {
    local key="$1" repo tag digest
    repo=$(docker_image_field "$key" repo) || return $?
    [ -n "$repo" ] || return 3
    tag=$(docker_image_field "$key" tag)
    digest=$(docker_image_field "$key" digest)
    if [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        echo "$repo@$digest"
    else
        echo "$repo:${tag:-latest}"
    fi
}

# docker_pull_pinned <ключ> — pull по дайджесту из images.json, три попытки.
# Docker Hub отвечает «toomanyrequests» при исчерпании анонимного лимита —
# у приложения Amnezia под это отдельная ошибка, у нас код rate_limit
# (подсказка про docker login — в тексте).
docker_pull_pinned() {
    local key="$1" images="${UPSTREAM_DIR:-}/images.json" ref repo
    if ! [[ "$key" =~ ^[a-z0-9-]+$ ]]; then
        ga_err invalid_image_key "$(tf docker_err_image_key "$key")" 2
        return 2
    fi
    if [ ! -f "$images" ]; then
        ga_err images_json_missing "$(tf docker_err_images_json "$images")" 3
        return 3
    fi
    repo=$(docker_image_field "$key" repo)
    if [ -z "$repo" ]; then
        ga_err images_json_missing "$(tf docker_err_image_unknown "$key")" 3
        return 3
    fi
    ref=$(docker_image_ref "$key")
    if [[ "$ref" != *@sha256:* ]]; then
        log_warning "$(tf docker_warn_unpinned "$ref")"
    fi
    docker_pull_ref "$ref"
}

# docker_pull_ref <repo@sha256:…|repo:tag> — pull готовой ссылки, три попытки.
# Вынесено из docker_pull_pinned ради обновления ядра (lib/upstream.sh): там
# ссылка приходит не из images.json, а из ответа Docker Hub — новый дайджест,
# который в images.json попадёт только после удачного обновления и проверки.
docker_pull_ref() {
    local ref="$1"
    if ! [[ "$ref" =~ ^[a-z0-9][a-z0-9._/-]{0,127}(:[A-Za-z0-9._-]{1,128}|@sha256:[0-9a-f]{64})?$ ]]; then
        ga_err invalid_image_name "$(tf docker_err_image_name "$ref")" 2
        return 2
    fi
    if ga_dry; then
        ga_dry_echo "docker pull $ref"
        return 0
    fi
    local attempt out rate=0
    for attempt in 1 2 3; do
        if out=$(ga_docker pull "$ref" 2>&1); then
            return 0
        fi
        if grep -qiE 'toomanyrequests|rate ?limit' <<<"$out"; then
            rate=1
        fi
        log_warning "$(tf docker_warn_pull_retry "$attempt" "$ref")"
        sleep $((attempt * 10))
    done
    if [ "$rate" = 1 ]; then
        ga_err rate_limit "$(t docker_err_rate_limit)"
    else
        ga_err pull_failed "$(tf docker_err_pull "$ref")"
    fi
    return 1
}

# docker_build <образ> <каталог> — без --pull: базовый образ уже вытянут по
# дайджесту, а --pull подтянул бы latest поверх (см. D8). Вывод сборки уходит
# в файл: на успехе он никому не нужен, при ошибке показываем хвост.
docker_build() {
    local image="$1" dir="$2"
    if ! [[ "$image" =~ ^[a-z0-9][a-z0-9._/-]{0,127}$ ]]; then
        ga_err invalid_image_name "$(tf docker_err_image_name "$image")" 2
        return 2
    fi
    if ga_dry; then
        ga_dry_echo "docker build -t $image $dir"
        return 0
    fi
    [ -f "$dir/Dockerfile" ] || { ga_err build_failed "$(tf docker_err_dockerfile "$dir")" 3; return 3; }
    local out
    out=$(mktemp) || return 1
    if ! ga_docker build -t "$image" "$dir" >"$out" 2>&1; then
        # Сначала строки с причиной: шаг мастера показывает только первые три
        # строки ошибки, и хвост сборки из «Running in …» и пустых строк ничего
        # не объяснял (живой прогон 24.09.2026). Цветовые коды сборщика снимаем.
        { grep -aE 'ERROR|WARNING|error:|returned a non-zero code' "$out" | tail -n 6
          tail -n 15 "$out"; } | sed -e 's/\x1b\[[0-9;]*m//g' -e '/^[[:space:]]*$/d' -e 's/^/    /' | awk '!seen[$0]++' >&2
        rm -f "$out"
        ga_err build_failed "$(tf docker_err_build "$image")"
        return 1
    fi
    rm -f "$out"
    return 0
}

docker_image_exists() {
    if ga_dry; then ga_dry_echo "docker image inspect $1"; return 0; fi
    ga_docker image inspect "$1" >/dev/null 2>&1
}

# docker_image_repo_digest <образ> — дайджест репозитория (sha256:…) локально
# вытянутого образа, stdout пусто, если образ не тянули из реестра (собран
# локально) или его нет. Нужен импорту: приложение Amnezia собирает образ из
# FROM …:latest, и единственный след того, ЧТО именно было скачано, — RepoDigests
# базового образа. В dry-run — пусто: тесты выставляют дайджест фикстурами.
docker_image_repo_digest() {
    local ref="$1" out
    if ga_dry; then ga_dry_echo "docker image inspect $ref --format {{.RepoDigests}}"; return 0; fi
    out=$(ga_docker image inspect "$ref" --format '{{join .RepoDigests "\n"}}' 2>/dev/null | head -n 1) || out=""
    out="${out##*@}"
    [[ "$out" =~ ^sha256:[0-9a-f]{64}$ ]] && printf '%s\n' "$out"
    return 0
}

# ── Стенд без Docker: фикстуры для dry-run ────────────────────────────────────
# GOAMNEZIA_CONTAINER_FS_DIR=<каталог> — «файловая система» контейнеров на
# стенде: <каталог>/<имя контейнера>/<путь внутри контейнера>. С ним в dry-run
# docker_read_file читает файл оттуда, а docker_container_state считает такой
# контейнер работающим. Без него dry-run ведёт себя как прежде (пусто/missing):
# на этом стоят прогоны установки, где контейнера ещё нет. Нужен импорту
# существующей установки (tests/test_import_dryrun.sh) и сторожу.
# GOAMNEZIA_DOCKER_PS_FIXTURE=<файл> — сохранённый `docker ps --format
# '{{.Names}} {{.Ports}}'`, та же переменная, что у lib/preflight.sh.
ga_docker_fs_path() {
    local name="$1" path="$2"
    [ -n "${GOAMNEZIA_CONTAINER_FS_DIR:-}" ] || return 1
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || return 1
    case "$path" in *..*) return 1 ;; esac
    printf '%s/%s/%s' "$GOAMNEZIA_CONTAINER_FS_DIR" "$name" "${path#/}"
}

# ── Контейнеры ─────────────────────────────────────────────────────────────────

# stdout: running|exited|missing|docker_unreachable. Все прочие статусы docker
# (created, paused, restarting, dead) для нас «не работает» → exited.
#
# Неудача inspect — это ДВА разных мира, и раньше оба назывались «missing».
# «No such object» — контейнер правда пропал, надо восстанавливать. «Демон не
# отвечает» или «версия API слишком новая» — про контейнер мы не знаем НИЧЕГО,
# и врать про пропажу нельзя: именно на этом сторож ночью звал восстанавливать
# из бэкапа три живых профиля (см. раздел «Версия API демона» выше).
docker_container_state() {
    local name="$1" st fs errf err
    if ga_dry; then
        ga_dry_echo "docker inspect -f {{.State.Status}} $name"
        # Контейнер «есть» на стенде, если у него есть каталог-фикстура; файл
        # .state внутри задаёт состояние (exited для проверки сторожа).
        if fs=$(ga_docker_fs_path "$name" "") && [ -d "$fs" ]; then
            st=$(cat "$fs/.state" 2>/dev/null | tr -d '[:space:]')
            case "$st" in exited|missing) echo "$st" ;; *) echo "running" ;; esac
            return 0
        fi
        echo "missing"
        return 0
    fi
    docker_api_pin
    errf=$(mktemp 2>/dev/null) || errf=""
    if st=$(command docker inspect -f '{{.State.Status}}' "$name" 2>"${errf:-/dev/null}"); then
        [ -n "$errf" ] && rm -f "$errf"
        case "$st" in
            running) echo "running" ;;
            *)       echo "exited" ;;
        esac
        return 0
    fi
    err=""
    if [ -n "$errf" ]; then
        err=$(cat "$errf" 2>/dev/null)
        rm -f "$errf"
    fi
    if ga_docker_err_no_such "$err"; then
        echo "missing"
    elif ga_docker_err_unreachable "$err" || ! docker_daemon_alive; then
        # Пустой или незнакомый текст ошибки — спрашиваем сам демон: молчание
        # клиента не повод объявлять контейнер пропавшим.
        echo "$GA_DOCKER_STATE_UNREACHABLE"
    else
        echo "missing"
    fi
}

# docker_run_awg <контейнер> <порт> <образ> — флаги run_container.sh приложения
# один к одному (privileged, NET_ADMIN, SYS_MODULE, /lib/modules, src_valid_mark,
# --log-driver none, --restart always), затем подключение к amnezia-dns-net.
docker_run_awg() {
    local name="$1" port="$2" image="$3"
    if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        ga_err invalid_port "$(tf docker_err_port "$port")" 2
        return 2
    fi
    local -a cmd=(docker run -d --log-driver none --restart always --privileged
                  --cap-add=NET_ADMIN --cap-add=SYS_MODULE -p "$port:$port/udp"
                  -v /lib/modules:/lib/modules --sysctl=net.ipv4.conf.all.src_valid_mark=1
                  --name "$name" "$image")
    if ga_dry; then
        ga_dry_echo "${cmd[*]}"
        ga_dry_echo "docker network connect $GA_DOCKER_NET $name"
        # Стенд: новый docker run публикует порт заново — снимаем пометку «порт не опубликован» (LC-20).
        local fs
        if fs=$(ga_docker_fs_path "$name" ".unpublished") && [ -f "$fs" ]; then rm -f "$fs" 2>/dev/null || true; fi
        # …и это новый контейнер: другой ID и новое сетевое пространство (соседи в его сети, см. ниже).
        _ga_dry_container_started "$name" new
        return 0
    fi
    docker_api_pin
    if ! "${cmd[@]}" >/dev/null 2>&1; then
        ga_err run_failed "$(tf docker_err_run "$name")"
        return 1
    fi
    if ! ga_docker network connect "$GA_DOCKER_NET" "$name" >/dev/null 2>&1; then
        ga_err docker_network_failed "$(tf docker_err_network_connect "$name")"
        return 1
    fi
    return 0
}

# docker_exec <контейнер> <команда…> — sh -c внутри контейнера.
# stdin ЗАКРЫВАЕМ (</dev/null): `docker exec -i` читает stdin вызывающего, и
# вызов внутри `while IFS= read -r … done < <(docker ps …)` съедал остаток
# списка — import_scan видел только первый контейнер. Тем, кому stdin правда
# нужен, служит docker_write_file / docker_append_file.
docker_exec() {
    local name="$1"; shift
    if ga_dry; then ga_dry_echo "docker exec -i $name sh -c '$*'"; return 0; fi
    ga_docker exec -i "$name" sh -c "$*" </dev/null
}

# Вариант с bash: нужен для process substitution `<(awg-quick strip …)` в
# syncconf — busybox sh его не умеет, а bash в образ ставит официальный Dockerfile.
docker_exec_bash() {
    local name="$1"; shift
    if ga_dry; then ga_dry_echo "docker exec -i $name bash -c '$*'"; return 0; fi
    ga_docker exec -i "$name" bash -c "$*" </dev/null
}

# Отсоединённый запуск (docker exec -d) — так приложение Amnezia стартует
# start.sh после загрузки в контейнер.
docker_exec_bg() {
    local name="$1"; shift
    if ga_dry; then ga_dry_echo "docker exec -d $name sh -c '$*'"; return 0; fi
    ga_docker exec -d "$name" sh -c "$*"
}

# docker_events_starts — имена контейнеров по мере их старта (docker events), пока жив демон: по строке на
# старт. Нужен службе изоляции (lib/amnezia.sh ga_amn_isolation_watch, находка OPS-05). Стенд:
# GOAMNEZIA_DOCKER_EVENTS_FIXTURE=<файл> — готовые имена построчно, и на этом события кончаются.
docker_events_starts() {
    if ga_dry; then
        ga_dry_echo "docker events --filter type=container --filter event=start --format {{.Actor.Attributes.name}}"
        if [ -n "${GOAMNEZIA_DOCKER_EVENTS_FIXTURE:-}" ] && [ -f "$GOAMNEZIA_DOCKER_EVENTS_FIXTURE" ]; then
            cat "$GOAMNEZIA_DOCKER_EVENTS_FIXTURE"
        fi
        return 0
    fi
    ga_docker events --filter type=container --filter event=start --format '{{.Actor.Attributes.name}}'
}

docker_read_file() {
    local name="$1" path="$2" fs
    if ga_dry; then
        ga_dry_echo "docker exec -i $name cat $path"
        # Стенд: файл контейнера из каталога-фикстуры (см. ga_docker_fs_path);
        # нет файла — как у настоящего docker exec cat: пусто и код 1.
        if fs=$(ga_docker_fs_path "$name" "$path"); then
            [ -f "$fs" ] && cat "$fs"
            [ -f "$fs" ]
            return $?
        fi
        return 0
    fi
    ga_docker exec -i "$name" cat "$path" </dev/null 2>/dev/null
}

# docker_read_file_any <контейнер> <путь> — как docker_read_file, но и у
# остановленного контейнера: docker exec в нём не работает, а docker cp
# работает (на stdout — поток tar с одним файлом). Нужен стражу установки
# профиля: остановленный контейнер приложения с людьми сносить так же нельзя,
# как работающий.
docker_read_file_any() {
    local name="$1" path="$2"
    if ga_dry; then docker_read_file "$name" "$path"; return $?; fi
    ga_docker exec -i "$name" cat "$path" </dev/null 2>/dev/null && return 0
    ga_docker cp "$name:$path" - 2>/dev/null | tar -xO 2>/dev/null
}

# docker_container_image <контейнер> — образ, из которого запущен контейнер
# (Config.Image: у контейнеров приложения Amnezia это имя собранного образа,
# совпадающее с именем контейнера). Стенд: файл .image в каталоге-фикстуре.
docker_container_image() {
    local name="$1" fs
    if ga_dry; then
        ga_dry_echo "docker inspect -f {{.Config.Image}} $name"
        if fs=$(ga_docker_fs_path "$name" ".image") && [ -f "$fs" ]; then
            tr -d '[:space:]' <"$fs"; echo
        fi
        return 0
    fi
    ga_docker inspect -f '{{.Config.Image}}' "$name" 2>/dev/null
}

# docker_write_file <контейнер> <путь> [режим] — stdin → файл в контейнере через
# временный файл + docker cp (docker exec с heredoc ломается на бинарных данных
# и кавычках). Режим по умолчанию 0600: конфиг с приватным ключом.
#
# Временный файл секретный по той же причине, что у ga_capture: этим путём в
# контейнер уезжают приватный ключ сервера, общий секрет и серверный конфиг со
# всеми пирами. На диске они задерживаться не должны.
docker_write_file() {
    local name="$1" path="$2" mode="${3:-0600}" tmp dir
    if ga_dry; then
        cat >/dev/null
        ga_dry_echo "docker cp <stdin> $name:$path (chmod $mode)"
        return 0
    fi
    tmp=$(ga_mktemp_secret dockerwrite) || return 1
    cat >"$tmp" || { ga_wipe_file "$tmp"; return 1; }
    dir=$(dirname "$path")
    ga_docker exec -i "$name" sh -c "mkdir -p '$dir'" </dev/null >/dev/null 2>&1
    if ! ga_docker cp "$tmp" "$name:$path" >/dev/null 2>&1; then
        ga_wipe_file "$tmp"
        ga_err container_write_failed "$(tf docker_err_write "$name" "$path")"
        return 1
    fi
    ga_wipe_file "$tmp"
    ga_docker exec -i "$name" sh -c "chmod $mode '$path'" </dev/null >/dev/null 2>&1
    return 0
}

docker_append_file() {
    local name="$1" path="$2"
    if ga_dry; then
        cat >/dev/null
        ga_dry_echo "docker exec -i $name sh -c 'cat >> $path'"
        return 0
    fi
    ga_docker exec -i "$name" sh -c "cat >> '$path'"
}

# docker_cp_from <контейнер> <путь-в-контейнере> <путь-на-хосте> — для каталогов
# и бинарных файлов (state_sync).
docker_cp_from() {
    local name="$1" src="$2" dst="$3"
    if ga_dry; then ga_dry_echo "docker cp $name:$src $dst"; return 0; fi
    ga_docker cp "$name:$src" "$dst" >/dev/null 2>&1
}

docker_cp_to() {
    local name="$1" src="$2" dst="$3"
    if ga_dry; then ga_dry_echo "docker cp $src $name:$dst"; return 0; fi
    ga_docker cp "$src" "$name:$dst" >/dev/null 2>&1
}

# stop + rm -fv, как remove_container.sh приложения, но образ не трогаем:
# он общий для трёх профилей и пригодится при переустановке.
docker_rm() {
    local name="$1"
    # ID — до сноса: соседи в сети контейнера держат ссылку на него, и после пересоздания их узнают по нему.
    docker_netdeps_remember "$name"
    if ga_dry; then ga_dry_echo "docker stop $name && docker rm -fv $name"; return 0; fi
    ga_docker stop "$name" >/dev/null 2>&1
    ga_docker rm -fv "$name" >/dev/null 2>&1
    # Снялся ли на самом деле. Отказ rm (демон, права) раньше глотался, и вызывающий удалял ключи при живом
    # контейнере. Контейнера не было вовсе — это тоже «снят». Судим по отсутствию контейнера, а не по коду ответа
    # rm (docker_container_gone).
    if ! docker_container_gone "$name"; then
        ga_err rm_failed "$(tf docker_err_rm "$name")"
        return 1
    fi
    return 0
}

# docker_container_gone <имя> — контейнера с таким именем нет. Спрашиваем именно КОНТЕЙНЕР (docker container
# inspect): образ профиля собирается под тем же именем, что контейнер (docker build -t amnezia-awg3), и голый
# `docker inspect` находил образ — «Удалить всё» объявляло «контейнер не снялся» и останавливало снос на полпути,
# хотя контейнеров уже не было (находка NC-25 критика-новичка, 28.09.2026). «Нет» — только когда Docker так и
# ответил («No such container»): демон молчит или отказывает — про контейнер ничего не известно, rc 1.
# Стенд: контейнер «есть», пока есть его каталог-фикстура и в .state не «missing».
docker_container_gone() {
    local name="$1" fs err
    if ga_dry; then
        fs=$(ga_docker_fs_path "$name" "") && [ -d "$fs" ] || return 0
        [ "$( { tr -d '[:space:]' <"$fs/.state"; } 2>/dev/null)" = missing ]
        return $?
    fi
    err=$(ga_docker container inspect --format '{{.Id}}' "$name" 2>&1 >/dev/null) && return 1
    ga_docker_err_no_such "$err"
}

docker_restart() {
    local name="$1"
    if ga_dry; then ga_dry_echo "docker restart $name"; _ga_dry_container_started "$name"; return 0; fi
    if ! ga_docker restart "$name" >/dev/null 2>&1; then
        ga_err restart_failed "$(tf docker_err_restart "$name")"
        return 1
    fi
    return 0
}

# docker_start <контейнер> — поднять остановленный контейнер (сторож
# goamnezia-watch: после `docker stop` руками или OOM-kill `--restart always`
# сам его не вернёт). Стенд: контейнер-фикстура считается запущенным.
docker_start() {
    local name="$1" fs
    if ga_dry; then
        ga_dry_echo "docker start $name"
        if fs=$(ga_docker_fs_path "$name" ".state") && [ -f "$fs" ]; then
            rm -f "$fs" 2>/dev/null || true
        fi
        _ga_dry_container_started "$name"
        return 0
    fi
    if ! ga_docker start "$name" >/dev/null 2>&1; then
        ga_err start_failed "$(tf docker_err_start "$name")"
        return 1
    fi
    return 0
}

# docker_port_free <порт> <udp|tcp> — 0 = свободен. Смотрим и на сокеты хоста
# (ss), и на публикации docker: при userland-proxy=false опубликованный порт
# контейнера в ss не виден, а занят.
#
# Разбор вывода ss живёт ровно в одном месте на весь продукт — ga_pf_listeners
# (lib/preflight.sh), как _valid_ip и ga_valid_mtu из lib/common.sh. Своя копия
# здесь читала пятое поле, а при однопротокольном вызове (`ss -H -lun`) колонки
# такие: состояние, две очереди, ЛОКАЛЬНЫЙ адрес, peer. То есть пятое поле —
# peer, в нём всегда `0.0.0.0:*`, цифрой он не кончается, и условие не
# срабатывало никогда: порт, занятый соседом по серверу, считался свободным, а
# docker уводил у него трафик. ga_pf_listeners ищет локальный адрес как поле
# ПЕРЕД «…:*» и потому не зависит ни от номера колонки, ни от заголовка.
docker_port_free() {
    local port="$1" proto="${2:-udp}" flag
    if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 2
    fi
    case "$proto" in
        udp) flag="-lun" ;;
        tcp) flag="-ltn" ;;
        *)   return 2 ;;
    esac
    local listeners="" rc=0
    if type ga_pf_listeners >/dev/null 2>&1; then
        # Код возврата снимаем ДО отрицания: `if ! cmd; then rc=$?` дал бы код
        # уже инвертированного условия. Ненулевой rc — «источник недоступен»
        # (нет ss, dry-run без сохранённого вывода), а не «порт свободен».
        listeners=$(ga_pf_listeners "$proto"); rc=$?
        if [ "$rc" = 0 ] && printf '%s\n' "$listeners" \
             | awk -F'|' -v p="$port" '$2 == p { found = 1 } END { exit !found }'; then
            return 1
        fi
    elif ga_dry; then
        ga_dry_echo "ss -H $flag | grep :$port"
    elif command -v ss >/dev/null 2>&1; then
        # Запасной путь без preflight.sh: тот же разбор, привязки к колонке нет.
        if ss -H "$flag" 2>/dev/null | awk -v p="$port" '
            {
                peer = 0
                for (i = 1; i <= NF; i++) if ($i ~ /:\*$/) { peer = i; break }
                if (peer < 2) next
                loc = $(peer - 1); n = split(loc, a, ":")
                if (a[n] == p) { found = 1 }
            }
            END { exit !found }'; then
            return 1
        fi
    fi
    # Публикации docker спрашивать в dry-run не у кого: демона нет по условию.
    ga_dry && return 0
    if grep -qE "[:]${port}->[0-9]+/${proto}" <<<"$(ga_docker ps --format '{{.Ports}}' 2>/dev/null)"; then
        return 1
    fi
    return 0
}

# docker_port_published <контейнер> <порт> [udp|tcp] — опубликован ли порт профиля у ЭТОГО контейнера
# (NetworkSettings.Ports: есть привязка с таким HostPort). Коды: 0 — да; 1 — нет; 2 — не узнать (демон не
# отвечает, контейнера нет). Нужен, потому что «контейнер работает» ещё не значит «люди доходят»: на
# восстановлении, где порт из копии держал другой профиль, контейнер вставал Up с пустым Ports при
# PortBindings 443/udp, ss порт не слушал, а ремонт, диагностика и шапка показывали «● работает» (находка
# LC-20, 25.09.2026). Стенд: файл .unpublished в каталоге-фикстуре изображает такой контейнер.
docker_port_published() {
    local name="$1" port="$2" proto="${3:-udp}" fs js
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 2
    if ga_dry; then
        ga_dry_echo "docker inspect -f {{json .NetworkSettings.Ports}} $name"
        if fs=$(ga_docker_fs_path "$name" ".unpublished") && [ -f "$fs" ]; then return 1; fi
        return 0
    fi
    js=$(ga_docker inspect -f '{{json .NetworkSettings.Ports}}' "$name" 2>/dev/null) || return 2
    [ -n "$js" ] && [ "$js" != "null" ] || return 1
    jq -e --arg p "$port" --arg k "$port/$proto" '
        (.[$k] // []) as $own
        | ([.[]? // [] | .[]? | .HostPort // empty] | index($p)) != null
          or ($own | length) > 0' >/dev/null 2>&1 <<<"$js"
}

# docker_ps_all — ВСЕ контейнеры машины, и остановленные тоже: «имя<TAB>состояние<TAB>порты» по строке.
# Состояние — running | restarting | exited (created, paused, dead — для нас тоже «не работает»).
# Зачем отдельно от docker_ps_names_ports: поиск контейнеров приложения Amnezia видел только работающие, и
# остановленный amnezia-awg2 с людьми был невидим — установка отказывала («подхватите контейнер»), а подхват
# его не находил (находка TK-4; живая жалоба владельца 25.09.2026 «установщик их не увидел»). Состояние берём
# из {{.Status}} («Up 2 hours», «Exited (0) …», «Restarting (1) …»): это поле есть в docker любых версий, а
# {{.State}} в форматах ps появился не сразу. Порты у остановленного пусты — Docker их не показывает.
# Отказ самого docker (демон не отвечает, нет прав на сокет) — код 1, а не пустой список: «контейнеров нет»
# и «не узнать» различаются. Стенд: сохранённый docker ps (GOAMNEZIA_DOCKER_PS_FIXTURE, работающие; .state
# в каталоге-фикстуре переопределяет состояние) плюс каталоги-фикстуры с .state=exited, которых в docker ps нет.
docker_ps_all() {
    local line name ports st fs d seen=" " out
    if ga_dry; then
        ga_dry_echo "docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'"
        if [ -n "${GOAMNEZIA_DOCKER_PS_FIXTURE:-}" ] && [ -r "$GOAMNEZIA_DOCKER_PS_FIXTURE" ]; then
            while IFS= read -r line || [ -n "$line" ]; do
                [ -n "$line" ] || continue
                name="${line%% *}"; ports=""
                [[ "$line" == *" "* ]] && ports="${line#* }"
                st=""
                if fs=$(ga_docker_fs_path "$name" ".state") && [ -f "$fs" ]; then
                    st=$(tr -d '[:space:]' <"$fs")
                fi
                # Те же значения, что у docker_container_state на стенде: пусто — работает.
                case "$st" in missing) continue ;; ""|running) st=running ;; restarting) ;; *) st=exited; ports="" ;; esac
                printf '%s\t%s\t%s\n' "$name" "$st" "$ports"
                seen+="$name "
            done <"$GOAMNEZIA_DOCKER_PS_FIXTURE"
        fi
        if [ -n "${GOAMNEZIA_CONTAINER_FS_DIR:-}" ] && [ -d "$GOAMNEZIA_CONTAINER_FS_DIR" ]; then
            for d in "$GOAMNEZIA_CONTAINER_FS_DIR"/*/; do
                [ -d "$d" ] || continue
                name=$(basename "$d")
                case "$seen" in *" $name "*) continue ;; esac
                [ "$( { tr -d '[:space:]' <"$d/.state"; } 2>/dev/null)" = exited ] || continue
                printf '%s\t%s\t\n' "$name" exited
            done
        fi
        return 0
    fi
    out=$(ga_docker ps -a --format '{{.Names}}	{{.Status}}	{{.Ports}}' 2>/dev/null) || return 1
    while IFS=$'\t' read -r name st ports; do
        [ -n "$name" ] || continue
        case "$st" in
            Up*Paused*)  st=exited ;;
            Up*)         st=running ;;
            Restarting*) st=restarting ;;
            *)           st=exited; ports="" ;;
        esac
        printf '%s\t%s\t%s\n' "$name" "$st" "$ports"
    done <<<"$out"
    return 0
}

# Список «имя порты» работающих контейнеров — тот же формат, по которому
# приложение Amnezia ищет свои контейнеры (getAlreadyInstalledContainers).
docker_ps_names_ports() {
    if ga_dry; then
        ga_dry_echo "docker ps --format '{{.Names}} {{.Ports}}'"
        # Стенд: сохранённый вывод docker ps (та же фикстура, что у preflight).
        if [ -n "${GOAMNEZIA_DOCKER_PS_FIXTURE:-}" ] && [ -r "$GOAMNEZIA_DOCKER_PS_FIXTURE" ]; then
            cat "$GOAMNEZIA_DOCKER_PS_FIXTURE"
        fi
        return 0
    fi
    ga_docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null
}

# ── Соседи в сети контейнера (NetworkMode=container:…) ─────────────────────────────
#
# Контейнер запускают в сети другого: `docker run --network container:amnezia-awg2 …` — так живут соседи профиля,
# которым нужен его туннель: SOCKS-прокси на 1080 рядом с goWARP PRO (warp-socks) выходит в интернет через интерфейс
# warp, который goWARP держит внутри контейнера профиля. Проверено на Docker 29.1 (test1, 29.09.2026):
#   • в NetworkMode Docker записывает ПОЛНЫЙ ID хозяина, даже если при запуске назвали имя;
#   • сеть хозяина живёт, пока жив он сам. Снесли и подняли заново (смена порта, «Поднять заново», обновление ядра,
#     восстановление из копии) — сосед работает дальше в опустевшем пространстве, где остался один lo, а его перезапуск
#     падает «joining network namespace of container: No such container: <прежний ID>»;
#   • перезапуск хозяина (docker restart, ID тот же) даёт ему новое пространство, а сосед остаётся в прежнем.
# Жалоба 29.09.2026: warp-socks «оторвался» от пересозданного amnezia-awg2, прокси на 1080 не работал.
# Поэтому ID контейнера с соседями запоминается перед сносом (docker_netdeps_remember — её зовёт docker_rm), а после
# подъёма (docker_netdeps_reattach) сосед со ссылкой на нынешний ID и чужим пространством перезапускается, а со ссылкой
# на запомненный прежний ID — пересоздаётся из своего docker inspect с той же конфигурацией и сетью хозяина.
# «Удалить всё» стирает state/ вместе с реестром, поэтому реестр уходит в хранилище вне каталога продукта
# (docker_netdeps_stash), и новая установка узнаёт соседей и по нему (живая проверка 03.10.2026, WRP-06: без этого
# warp-socks оставался в сети удалённого amnezia-awg2, а продукт молчал).
#
# Стенд (GOAMNEZIA_DRY_RUN=1): у контейнера-фикстуры файлы .id и .netns (их меняют docker run/start/restart сухого
# прогона), соседи — строки «имя<TAB>ID<TAB>NetworkMode<TAB>running<TAB>пространство» в GOAMNEZIA_DOCKER_NETDEPS_FIXTURE,
# docker inspect соседа — <фикстура соседа>/.inspect.json; тело создания пересозданного уходит в .create.json рядом.

GA_DOCKER_NAME_RE='^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$'

# Реестр прежних ID контейнера: state/.netdeps/<имя>.ids (0600, не больше 16 строк). В state/ — чтобы пережить
# перезагрузку между сносом и подъёмом (сорвалась смена порта, «Поднять заново» — на следующий день).
docker_netdeps_dir() { printf '%s' "${GOAMNEZIA_NETDEPS_DIR:-${STATE_DIR:-${GOAMNEZIA_DIR:-/opt/goamnezia}/state}/.netdeps}"; }

# Хранилище реестра на время между «Удалить всё» и новой установкой: /var/lib/goamnezia-netdeps (0700, файлы 0600, тот
# же формат <имя>.ids) — вне каталога продукта, который снос стирает целиком. Стенды задают своё
# (GOAMNEZIA_NETDEPS_STASH_DIR); сухой прогон без него хранилища не имеет — /var/lib машины прогона не трогаем. rc 1 — нет.
docker_netdeps_stash_dir() {
    if [ -n "${GOAMNEZIA_NETDEPS_STASH_DIR:-}" ]; then printf '%s' "$GOAMNEZIA_NETDEPS_STASH_DIR"; return 0; fi
    ga_dry && return 1
    printf '%s' /var/lib/goamnezia-netdeps
}

# _ga_hex64 <затравка> — 64 шестнадцатеричных знака (ID контейнера стенда).
_ga_hex64() {
    local h
    h=$(printf '%s' "$1" | { sha256sum 2>/dev/null || shasum -a 256 2>/dev/null; } | cut -c1-64)
    printf '%s' "${h:-0000000000000000000000000000000000000000000000000000000000000000}"
}

# _ga_dry_container_started <имя> [new] — стенд: контейнер стартовал — новое сетевое пространство, с new (docker run)
# — и новый ID. Меняются только файлы, которые завела сама проверка (.netns, .id).
_ga_dry_container_started() {
    local name="$1" fs n
    fs=$(ga_docker_fs_path "$name" "") && [ -d "$fs" ] || return 0
    [ -f "$fs/.netns" ] || [ -f "$fs/.id" ] || return 0
    n=$(cat "$fs/.gen" 2>/dev/null) || n=0
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    n=$((n + 1))
    { printf '%s\n' "$n" >"$fs/.gen"; } 2>/dev/null || return 0
    [ -f "$fs/.netns" ] && printf 'net:[%s]\n' "$((4026532000 + n))" >"$fs/.netns"
    if [ "${2:-}" = new ] && [ -f "$fs/.id" ]; then _ga_hex64 "$name-$n" >"$fs/.id"; fi
    return 0
}

# docker_container_id <имя> → полный ID контейнера; rc 1 — контейнера нет (или Docker не ответил).
docker_container_id() {
    local name="$1" fs id
    [[ "$name" =~ $GA_DOCKER_NAME_RE ]] || return 1
    if ga_dry; then
        fs=$(ga_docker_fs_path "$name" ".id") && [ -f "$fs" ] || return 1
        id=$(tr -d '[:space:]' <"$fs")
    else
        id=$(ga_docker container inspect -f '{{.Id}}' "$name" 2>/dev/null) || return 1
    fi
    [ -n "$id" ] || return 1
    printf '%s' "$id"
}

# docker_netns <имя> → сетевое пространство работающего контейнера («net:[4026532528]»); rc 1 — не работает.
docker_netns() {
    local name="$1" fs pid ns
    [[ "$name" =~ $GA_DOCKER_NAME_RE ]] || return 1
    if ga_dry; then
        fs=$(ga_docker_fs_path "$name" ".netns") && [ -f "$fs" ] || return 1
        ns=$(tr -d '[:space:]' <"$fs")
    else
        pid=$(ga_docker container inspect -f '{{.State.Pid}}' "$name" 2>/dev/null) || return 1
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
        ns=$(readlink "/proc/$pid/ns/net" 2>/dev/null) || return 1
    fi
    [ -n "$ns" ] || return 1
    printf '%s' "$ns"
}

# docker_netdeps_scan → строки «имя<TAB>ID<TAB>NetworkMode<TAB>running<TAB>пространство» всех контейнеров машины,
# живущих в сети другого (остальные не печатаются). rc 1 — Docker не ответил.
docker_netdeps_scan() {
    local ids name id mode run pid ns
    if ga_dry; then
        [ -n "${GOAMNEZIA_DOCKER_NETDEPS_FIXTURE:-}" ] && [ -f "$GOAMNEZIA_DOCKER_NETDEPS_FIXTURE" ] || return 0
        awk -F'\t' '$1 !~ /^#/ && NF >= 4 && $3 ~ /^container:/' "$GOAMNEZIA_DOCKER_NETDEPS_FIXTURE"
        return 0
    fi
    ids=$(ga_docker ps -aq --no-trunc 2>/dev/null) || return 1
    [ -n "$ids" ] || return 0
    # Контейнер мог исчезнуть между ps и inspect — inspect отдаст остальных и код 1; код не смотрим.
    # shellcheck disable=SC2086
    while IFS=$'\t' read -r name id mode run pid; do
        case "$mode" in container:?*) ;; *) continue ;; esac
        ns=""
        if [ "$run" = true ] && [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then ns=$(readlink "/proc/$pid/ns/net" 2>/dev/null) || ns=""; fi
        printf '%s\t%s\t%s\t%s\t%s\n' "${name#/}" "$id" "$mode" "$run" "$ns"
    done < <(ga_docker container inspect -f '{{.Name}}	{{.Id}}	{{.HostConfig.NetworkMode}}	{{.State.Running}}	{{.State.Pid}}' $ids 2>/dev/null)
    return 0
}

# _ga_netdeps_ref_is <ссылка> <ID> — ссылка указывает на этот ID (полностью или префиксом от 12 знаков).
_ga_netdeps_ref_is() {
    local ref="$1" id="$2"
    [ -n "$ref" ] && [ -n "$id" ] || return 1
    [ "$ref" = "$id" ] && return 0
    [ "${#ref}" -ge 12 ] && [ "${id#"$ref"}" != "$id" ]
}

# docker_netdeps_list <хозяин> [ID] → имена контейнеров в сети хозяина (по имени или по ID — нынешнему или данному).
docker_netdeps_list() {
    local host="$1" hid="${2:-}" scan
    [ -n "$hid" ] || hid=$(docker_container_id "$host") || hid=""
    scan=$(docker_netdeps_scan) || return 0
    _ga_netdeps_of "$host" "$hid" "$scan"
}

# _ga_netdeps_of <хозяин> <ID> <скан> — то же по готовому скану (docker_netdeps_scan): без нового обхода машины.
_ga_netdeps_of() {
    local host="$1" hid="$2" name id mode run ns ref
    while IFS=$'\t' read -r name id mode run ns; do
        [ -n "$name" ] && [ "$name" != "$host" ] || continue
        ref="${mode#container:}"
        if [ "$ref" = "$host" ] || _ga_netdeps_ref_is "$ref" "$hid"; then printf '%s\n' "$name"; fi
    done <<<"$3"
    return 0
}

# docker_netdeps_dangling → имена контейнеров, чья сеть — сеть контейнера, которого больше нет (ссылка на ID, не
# найденный ни в реестре, ни в хранилище «Удалить всё», ни среди контейнеров машины). Так остаются соседи профиля,
# пересозданного версиями до 29.09.2026 или снесённого «Удалить всё» до 03.10.2026: их прежний ID нигде не записан, и
# вернуть их в сеть сами мы не можем — только назвать (миграция, конец установки, «Диагностика», сторож).
# rc 1 — Docker не ответил: «висящих нет» сказать нельзя (сторож тогда не снимает отметку «сказано»).
docker_netdeps_dangling() {
    local scan name id mode run ns ref f known="" seen=" " sdir
    scan=$(docker_netdeps_scan) || return 1
    [ -n "$scan" ] || return 0
    for f in "$(docker_netdeps_dir)"/*.ids; do [ -f "$f" ] && known+="$(cat "$f" 2>/dev/null)"$'\n'; done
    if sdir=$(docker_netdeps_stash_dir); then
        for f in "$sdir"/*.ids; do [ -f "$f" ] && known+="$(cat "$f" 2>/dev/null)"$'\n'; done
    fi
    while IFS=$'\t' read -r name id mode run ns; do
        [ -n "$name" ] || continue
        ref="${mode#container:}"
        [[ "$ref" =~ ^[0-9a-f]{12,64}$ ]] || continue
        case "$seen" in *" $ref "*) printf '%s\n' "$name"; continue ;; esac
        grep -qxF -- "$ref" <<<"$known" && continue
        if ga_dry; then
            grep -qxF -- "$ref" < <(cat "${GOAMNEZIA_CONTAINER_FS_DIR:-/nonexistent}"/*/.id 2>/dev/null) && continue
        else
            ga_docker container inspect --format '{{.Id}}' "$ref" >/dev/null 2>&1 && continue
        fi
        seen+="$ref "
        printf '%s\n' "$name"
    done <<<"$scan"
    return 0
}

# docker_netdeps_remember <имя> [ID скан] — перед сносом: если в сети контейнера живут соседи, его ID — в реестр
# (соседи держат ссылку на него, и после пересоздания их узнают по ней). Тихая: отказ записи не повод срывать снос.
# ID и удачный скан, уже снятые вызывающим (docker_netdeps_reattach), — вторым и третьим аргументом: обходить
# машину ещё раз незачем.
docker_netdeps_remember() {
    local name="$1" id dir f deps
    if [ $# -ge 3 ] && [ -n "${2:-}" ]; then
        id="$2"
        deps=$(_ga_netdeps_of "$name" "$id" "$3")
    else
        id=$(docker_container_id "$name") || return 0
        deps=$(docker_netdeps_list "$name" "$id")
    fi
    [ -n "$deps" ] || return 0
    dir=$(docker_netdeps_dir)
    { mkdir -p "$dir" && chmod 700 "$dir"; } 2>/dev/null || return 0
    f="$dir/$name.ids"
    grep -qxF -- "$id" "$f" 2>/dev/null && return 0
    { { cat "$f" 2>/dev/null; printf '%s\n' "$id"; } | tail -n 16 >"$f.tmp" && chmod 600 "$f.tmp" && mv -f "$f.tmp" "$f"; } 2>/dev/null \
        || rm -f "$f.tmp" 2>/dev/null
    return 0
}

# _ga_netdeps_referenced <ID> <скан> — на этот ID ссылается чья-то сеть (полностью или префиксом от 12 знаков).
_ga_netdeps_referenced() {
    awk -F'\t' -v id="$1" '{ r = $3; sub(/^container:/, "", r); if (r == id || (length(r) >= 12 && index(id, r) == 1)) f = 1 } END { exit !f }' <<<"$2"
}

# _ga_netdeps_prune <файл реестра> <скан> — из файла уходят ID, на которые больше никто не ссылается; не осталось ни
# одного — файл снимается.
_ga_netdeps_prune() {
    local f="$1" scan="$2" keep="" id
    [ -f "$f" ] || return 0
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        _ga_netdeps_referenced "$id" "$scan" && keep+="$id"$'\n'
    done <"$f"
    if [ -z "$keep" ]; then rm -f "$f" 2>/dev/null; else { printf '%s' "$keep" >"$f"; } 2>/dev/null; fi
    return 0
}

# docker_netdeps_forget <хозяин> — из реестра хозяина уходят ID, на которые больше никто не ссылается. Из хранилища
# «Удалить всё» — такие же у всех хозяев (соседи вернулись в сеть новых контейнеров или удалены), опустевшее хранилище
# снимается целиком: прежней установки больше ничто не держит.
docker_netdeps_forget() {
    local host="$1" f sdir scan
    f="$(docker_netdeps_dir)/$host.ids"
    sdir=$(docker_netdeps_stash_dir) && [ -d "$sdir" ] || sdir=""
    [ -f "$f" ] || [ -n "$sdir" ] || return 0
    # Удачный скан вызывающего (второй аргумент, пустой — «соседей нет») — без нового обхода машины.
    if [ $# -ge 2 ]; then scan="$2"; else scan=$(docker_netdeps_scan) || return 0; fi
    _ga_netdeps_prune "$f" "$scan"
    [ -n "$sdir" ] || return 0
    for f in "$sdir"/*.ids; do _ga_netdeps_prune "$f" "$scan"; done
    rmdir "$sdir" 2>/dev/null || true
    return 0
}

# docker_netdeps_stash — «Удалить всё», когда контейнеры профилей уже сняты: реестр (state/.netdeps) — в хранилище
# (docker_netdeps_stash_dir), к записанному там раньше. Дальше снос сотрёт state/, а соседи по-прежнему держат ссылку
# на ID снесённых контейнеров: новая установка узнает их по этим ID (docker_netdeps_reattach) и пересоздаст в сети
# нового контейнера профиля. Переносятся ID, на которые кто-то ссылается (Docker не ответил — все); ссылок нет —
# хранилище не заводится. rc 1 — записать не вышло.
docker_netdeps_stash() {
    local sdir scan="" scanned=1 f id keep dst rc=0
    local -a files=()
    sdir=$(docker_netdeps_stash_dir) || return 0
    for f in "$(docker_netdeps_dir)"/*.ids; do [ -f "$f" ] && files+=("$f"); done
    [ "${#files[@]}" -gt 0 ] || return 0
    scan=$(docker_netdeps_scan) || scanned=0
    for f in "${files[@]}"; do
        keep=""
        while IFS= read -r id; do
            [[ "$id" =~ ^[0-9a-f]{12,64}$ ]] || continue
            [ "$scanned" = 0 ] || _ga_netdeps_referenced "$id" "$scan" || continue
            keep+="$id"$'\n'
        done <"$f"
        [ -n "$keep" ] || continue
        { mkdir -p "$sdir" && chmod 700 "$sdir"; } 2>/dev/null || return 1
        dst="$sdir/${f##*/}"
        if ! { { cat "$dst" 2>/dev/null; printf '%s' "$keep"; } | awk 'NF && !seen[$0]++' | tail -n 16 >"$dst.tmp" \
                && chmod 600 "$dst.tmp" && mv -f "$dst.tmp" "$dst"; } 2>/dev/null; then
            rm -f "$dst.tmp" 2>/dev/null
            rc=1
        fi
    done
    return "$rc"
}

# _ga_dry_netdeps_set <имя> <ID|-> <NetworkMode|-> <running|-> <пространство|-> — стенд: поправить строку соседа.
_ga_dry_netdeps_set() {
    local f="${GOAMNEZIA_DOCKER_NETDEPS_FIXTURE:-}"
    [ -n "$f" ] && [ -f "$f" ] || return 0
    awk -F'\t' -v OFS='\t' -v n="$1" -v i="$2" -v m="$3" -v r="$4" -v s="$5" '
        $1 == n { if (i != "-") $2 = i; if (m != "-") $3 = m; if (r != "-") $4 = r; if (s != "-") $5 = s }
        { print }' "$f" >"$f.tmp" && mv -f "$f.tmp" "$f"
}

# docker_api <метод> <путь> [тело] → тело ответа Docker Engine API через сокет демона; rc 0 — ответ 2xx, 1 — отказ
# (текст отказа — в stdout), 2 — сокета нет (DOCKER_HOST по tcp/ssh, нет curl). Тело — через stdin, а не аргументом:
# в нём окружение соседа, а argv любого процесса видят все пользователи машины.
docker_api() {
    local method="$1" path="$2" body="${3:-}" sock code resp
    sock=$(ga_docker_socket) && [ -S "$sock" ] || return 2
    command -v curl >/dev/null 2>&1 || return 2
    resp=$(mktemp 2>/dev/null) || return 1
    if [ -n "$body" ]; then
        code=$(printf '%s' "$body" | curl -s --max-time 60 --unix-socket "$sock" -X "$method" \
            -H 'Content-Type: application/json' --data-binary @- -o "$resp" -w '%{http_code}' "http://localhost$path" 2>/dev/null)
    else
        code=$(curl -s --max-time 60 --unix-socket "$sock" -X "$method" -o "$resp" -w '%{http_code}' "http://localhost$path" 2>/dev/null)
    fi
    cat "$resp" 2>/dev/null
    rm -f "$resp"
    [[ "$code" =~ ^2[0-9][0-9]$ ]]
}

# docker_netdeps_body <docker inspect соседа> <хозяин> <прежний ID> <образ> → тело POST /containers/create: его Config
# без полей, которые Docker запрещает в сети чужого контейнера (имя узла, открытые порты, MAC — их Docker дописал
# сам), и его HostConfig с NetworkMode=container:<хозяин> (и PID/IPC, если они тоже шли за прежним ID). Тома без
# имени в Binds (VOLUME образа) — отдельными Mounts тех же томов: иначе новый контейнер получил бы пустые.
docker_netdeps_body() {
    jq -c --arg host "$2" --arg old "$3" --arg img "$4" '
        .[0] as $c
        | ($c.HostConfig // {}) as $h
        | ([($h.Binds // [])[] | (split(":") | .[1] // empty)] + [($h.Mounts // [])[]? | (.Target // empty)]) as $have
        | ($c.Config // {})
        | del(.Hostname, .Domainname, .ExposedPorts, .MacAddress)
        | .Image = $img
        | .HostConfig = ($h
            | .NetworkMode = ("container:" + $host)
            | (if (.PidMode // "") == ("container:" + $old) then .PidMode = ("container:" + $host) else . end)
            | (if (.IpcMode // "") == ("container:" + $old) then .IpcMode = ("container:" + $host) else . end)
            | del(.PortBindings, .PublishAllPorts, .Links, .Dns, .DnsOptions, .DnsSearch, .ExtraHosts)
            | .Mounts = ((.Mounts // []) + [$c.Mounts[]?
                | select(.Type == "volume" and (.Name // "") != "" and ((.Destination // "") as $d | ($have | any(.[]; . == $d)) | not))
                | {Type: "volume", Source: .Name, Target: .Destination, ReadOnly: (.RW == false)}]))' <<<"$1"
}

# docker_netdeps_recreate <сосед> <хозяин> <прежний ID> — пересоздать соседа из его docker inspect в сети хозяина:
# прежний отодвигается под другим именем, новый создаётся с тем же именем и конфигурацией, прежний удаляется, новый
# стартует, если прежний работал (или упал на входе в пропавшую сеть, или у него --restart always). Не создался —
# прежний возвращается под своё имя. Причина отказа — в GA_NETDEPS_ERR.
GA_NETDEPS_ERR=""
docker_netdeps_recreate() {
    local name="$1" host="$2" old="$3" js body img cfgimg imgid start park out hid hns fs=""
    GA_NETDEPS_ERR=""
    if ga_dry; then
        js='[{"Config": {}, "HostConfig": {}, "State": {"Running": true}}]'
        if fs=$(ga_docker_fs_path "$name" ".inspect.json") && [ -f "$fs" ]; then js=$(cat "$fs"); else fs=""; fi
    else
        js=$(ga_docker container inspect "$name" 2>/dev/null) || { GA_NETDEPS_ERR="inspect"; return 1; }
    fi
    start=$(jq -r '.[0] | if (.State.Running == true) or ((.State.Error // "") != "")
                         or ((.HostConfig.RestartPolicy.Name // "") == "always") then 1 else 0 end' <<<"$js" 2>/dev/null)
    cfgimg=$(jq -r '.[0].Config.Image // ""' <<<"$js" 2>/dev/null); imgid=$(jq -r '.[0].Image // ""' <<<"$js" 2>/dev/null)
    # Образ — тот же, с которого сосед работал: имя, если оно всё ещё указывает на этот образ, иначе его ID.
    img="$imgid"
    if [ -n "$cfgimg" ] && { [ -z "$imgid" ] || ga_dry || [ "$(ga_docker image inspect -f '{{.Id}}' "$cfgimg" 2>/dev/null)" = "$imgid" ]; }; then
        img="$cfgimg"
    fi
    [ -n "$img" ] || img="-"
    body=$(docker_netdeps_body "$js" "$host" "$old" "$img") && [ -n "$body" ] || { GA_NETDEPS_ERR="inspect"; return 1; }
    if ga_dry; then
        ga_dry_echo "docker rename $name $name-ga-old; POST /containers/create?name=$name (NetworkMode container:$host); docker rm -f $name-ga-old$([ "$start" = 1 ] && printf '; docker start %s' "$name")"
        [ -n "$fs" ] && printf '%s\n' "$body" >"${fs%/.inspect.json}/.create.json"
        hid=$(docker_container_id "$host") || hid="-"
        hns=$(docker_netns "$host") || hns="-"
        if [ "$start" = 1 ]; then
            _ga_dry_netdeps_set "$name" "$(_ga_hex64 "$name-$hid")" "container:$hid" true "$hns"
        else
            _ga_dry_netdeps_set "$name" "$(_ga_hex64 "$name-$hid")" "container:$hid" false ""
        fi
        return 0
    fi
    park="$name-ga-old-$$"
    ga_docker rename "$name" "$park" >/dev/null 2>&1 || { GA_NETDEPS_ERR="rename"; return 1; }
    if ! out=$(docker_api POST "/containers/create?name=$name" "$body"); then
        ga_docker rename "$park" "$name" >/dev/null 2>&1
        GA_NETDEPS_ERR=$(jq -r '.message // empty' <<<"$out" 2>/dev/null | head -c 300)
        [ -n "$GA_NETDEPS_ERR" ] || GA_NETDEPS_ERR="api"
        return 1
    fi
    ga_docker rm -f "$park" >/dev/null 2>&1
    [ "$start" = 1 ] || return 0
    if ! ga_docker start "$name" >/dev/null 2>&1; then GA_NETDEPS_ERR="start"; return 1; fi
    return 0
}

# _ga_netdeps_restart <сосед> <пространство хозяина> — перезапуск соседа: он снова входит в сеть хозяина по его ID.
_ga_netdeps_restart() {
    GA_NETDEPS_ERR=""
    if ga_dry; then
        ga_dry_echo "docker restart $1"
        _ga_dry_netdeps_set "$1" - - true "$2"
        return 0
    fi
    ga_docker restart -t 10 "$1" >/dev/null 2>&1 || { GA_NETDEPS_ERR="restart"; return 1; }
}

# docker_netdeps_reattach <хозяин> → stdout: строки «действие<TAB>сосед[<TAB>причина]», действие — restarted |
# recreated | failed. Хозяина нет или он не работает — ничего (подключать некуда, реестр остаётся до его подъёма).
# Прежние ID — из реестра и из хранилища «Удалить всё»: после сноса и новой установки соседи прежней установки
# возвращаются в сеть нового контейнера тем же пересозданием (WRP-06).
# Замок один на машину: после пересоздания сюда почти одновременно приходят сама операция, служба изоляции (событие
# старта контейнера) и сторож.
# _ga_netdeps_host <хозяин> — ID и сетевое пространство работающего хозяина в _GA_NH_ID и _GA_NH_NS одним docker
# inspect (сторож зовёт это каждые две минуты на каждый профиль; раньше — два inspect). rc 1 — нет или не работает.
_GA_NH_ID=""; _GA_NH_NS=""
_ga_netdeps_host() {
    local name="$1" out pid
    _GA_NH_ID=""; _GA_NH_NS=""
    if ga_dry; then
        _GA_NH_ID=$(docker_container_id "$name") || return 1
        _GA_NH_NS=$(docker_netns "$name") || return 1
        return 0
    fi
    [[ "$name" =~ $GA_DOCKER_NAME_RE ]] || return 1
    out=$(ga_docker container inspect -f '{{.Id}} {{.State.Pid}}' "$name" 2>/dev/null) || return 1
    _GA_NH_ID="${out%% *}"; pid="${out##* }"
    [ -n "$_GA_NH_ID" ] && [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    _GA_NH_NS=$(readlink "/proc/$pid/ns/net" 2>/dev/null) && [ -n "$_GA_NH_NS" ]
}

docker_netdeps_reattach() {
    local host="${1:-}" hid hns scan old name id mode run ns ref fd="" lock sdir scan_ok=1 acted=0
    [[ "$host" =~ $GA_DOCKER_NAME_RE ]] || return 0
    _ga_netdeps_host "$host" || return 0
    hid="$_GA_NH_ID"; hns="$_GA_NH_NS"
    scan=$(docker_netdeps_scan) || return 0
    if [ -z "$scan" ]; then docker_netdeps_forget "$host" ""; return 0; fi
    lock="${LOCK_DIR:-/run/goamnezia}/netdeps.lock"
    if command -v flock >/dev/null 2>&1 && mkdir -p "${lock%/*}" 2>/dev/null && { exec {fd}>>"$lock"; } 2>/dev/null; then
        flock -w 90 "$fd" 2>/dev/null || true
        # Под замком — заново: пока ждали, соседа мог подключить другой процесс.
        scan=$(docker_netdeps_scan) || { scan=""; scan_ok=0; }
        hns=$(docker_netns "$host") || hns=""
    fi
    old=$(cat "$(docker_netdeps_dir)/$host.ids" 2>/dev/null) || old=""
    if sdir=$(docker_netdeps_stash_dir) && [ -f "$sdir/$host.ids" ]; then old+=$'\n'"$(cat "$sdir/$host.ids" 2>/dev/null)"; fi
    while IFS=$'\t' read -r name id mode run ns; do
        [ -n "$name" ] && [ -n "$hns" ] && [ "$name" != "$host" ] || continue
        ref="${mode#container:}"
        if [ "$ref" = "$host" ] || _ga_netdeps_ref_is "$ref" "$hid"; then
            # Ссылка на нынешнего хозяина: работает — но в прежнем, уже мёртвом пространстве.
            [ "$run" = true ] && [ -n "$ns" ] && [ "$ns" != "$hns" ] || continue
            acted=1
            if _ga_netdeps_restart "$name" "$hns"; then printf 'restarted\t%s\n' "$name"
            else printf 'failed\t%s\t%s\n' "$name" "$GA_NETDEPS_ERR"; fi
        elif [ -n "$old" ] && grep -qxF -- "$ref" <<<"$old"; then
            acted=1
            if docker_netdeps_recreate "$name" "$host" "$ref"; then printf 'recreated\t%s\n' "$name"
            else printf 'failed\t%s\t%s\n' "$name" "$GA_NETDEPS_ERR"; fi
        fi
    done <<<"$scan"
    # Нынешний ID — в реестр сразу, а не только перед нашим сносом: контейнер могут снести и мимо продукта (docker rm
    # руками, чистка диска), и «Поднять заново» тогда узнаёт соседей по записанному ID. Прежние, на которые никто
    # больше не ссылается, уходят. Скан под замком годится и им — если никого не трогали и он удался; иначе — новый.
    if [ "$acted" = 0 ] && [ "$scan_ok" = 1 ]; then
        docker_netdeps_remember "$host" "$hid" "$scan"
        docker_netdeps_forget "$host" "$scan"
    else
        docker_netdeps_remember "$host"
        docker_netdeps_forget "$host"
    fi
    if [ -n "$fd" ]; then { exec {fd}>&-; } 2>/dev/null; fi
    return 0
}
