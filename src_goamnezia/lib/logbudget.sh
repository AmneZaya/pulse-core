#!/usr/bin/env bash
# lib/logbudget.sh — жёсткий бюджет логов: не более 300 МБ на компонент, из них
# половина — живой несжатый слой, половина — сжатый архив с постоянной ротацией.
# Порт из goTelegram Pro, источники данных заменены на наши.
#
# Зачем это вообще. На боевом сервере goTelegram /var/log разросся до 552 МБ.
# Это не косметика: когда раздел забивается, nginx и sshd встают на записи в лог —
# принимают TCP и молчат, а уже поднятые туннели продолжают работать. Снаружи
# выглядит как «VPN жив, а сервер недоступен», и по SSH на машину уже не зайти.
# Ротация тут — не гигиена, а доступность.
#
# Два слоя, по убыванию отдачи:
#   1) объявленные потолки — journald + logrotate, ротация по РАЗМЕРУ, не по дате;
#   2) сторож              — таймер считает ФАКТ и подрезает, если вышли за бюджет.
#
# Второй слой нужен именно потому, что logrotate ходит раз в сутки: между
# запусками всплеск трафика успевает выесть диск, и «объявленный» потолок не
# спасает. Сторож ходит каждые 15 минут и смотрит на реальные байты.
#
# Слоя «резать в источнике» (в goTelegram это была правка RUST_LOG у telemt) здесь
# нет по-хорошему: наши контейнеры запускаются с `--log-driver none` (это делает
# lib/docker.sh), то есть источник вырезан ещё до появления файла. Компонент
# docker ниже оставлен для контейнеров, подхваченных через import-adopt, —
# их поставило приложение Amnezia со стандартным json-file.

# ── Бюджеты ──────────────────────────────────────────────────────────────────
LOGB_COMPONENT_MB="${LOGB_COMPONENT_MB:-300}"   # потолок на КАЖДЫЙ компонент
LOGB_LIVE_MB="${LOGB_LIVE_MB:-150}"             # из них живой (несжатый) слой
LOGB_KEEP_FREE_MB="${LOGB_KEEP_FREE_MB:-1024}"  # аварийный порог свободного места
LOGB_FILE_MB="${LOGB_FILE_MB:-50}"              # размер, на котором файл ротируется
LOGB_SWEEP_SVC="goamnezia-logbudget"
LOGB_STATE="${LOGB_STATE:-/run/goamnezia-logbudget.state}"

# ── Пути наружу ──────────────────────────────────────────────────────────────
# На живом сервере это ровно /etc/logrotate.d, /var/log/nginx и
# /etc/systemd/system. Переменными они сделаны затем, чтобы набор проверок мог
# прогнать применение настроек в песочнице, а не в живом /etc: правила ротации
# трогают ВЕСЬ сервер, и проверять их «на глаз» после этого дефекта нельзя.
LOGB_LOGROTATE_DIR="${LOGB_LOGROTATE_DIR:-/etc/logrotate.d}"
LOGB_NGINX_LOG_DIR="${LOGB_NGINX_LOG_DIR:-/var/log/nginx}"
# Каталоги, которые сторож меряет и подрезает. Были вшиты в _logb_components, и переопределение
# LOGB_NGINX_LOG_DIR на них не действовало: проверки мерили и резали настоящий /var/log машины (находка L1-02).
LOGB_JOURNAL_DIR="${LOGB_JOURNAL_DIR:-/var/log/journal}"
LOGB_VAR_LOG_DIR="${LOGB_VAR_LOG_DIR:-/var/log}"
LOGB_UNIT_DIR="${LOGB_UNIT_DIR:-${GOAMNEZIA_SYSTEMD_DIR:-/etc/systemd/system}}"
# Хвост, которым ПРЕЖНИЕ версии «выключали» чужой конфиг прямо в каталоге.
# Оставлен ровно для одного — подобрать этот хвост на старых установках.
LOGB_LEGACY_SUFFIX=".goamnezia-disabled"

if ! type t >/dev/null 2>&1; then t() { printf '%s\n' "${1:-}"; }; fi
if ! type tf >/dev/null 2>&1; then tf() { local k="${1:-}"; shift; printf '%s %s\n' "$k" "$*"; }; fi

# Компоненты: имя|путь|маска. Пустая маска = каталог принадлежит компоненту
# целиком. Непустая = каталог ОБЩИЙ, и трогать в нём можно только своё.
#
# Это не мелочь: /var/log общий с системой, и без маски сюда попадут syslog.1,
# auth.log.2 и прочее чужое — а сторож их сожмёт и удалит. Маска покрывает и
# живые файлы, и ротированные (goamnezia-audit.log.3.gz тоже начинается с
# goamnezia), поэтому она задаётся префиксом, а не полным именем.
# Компонент docker обрабатывается отдельно (см. _logb_docker_files): там
# границу задаёт не маска имени, а список НАШИХ контейнеров.
_logb_components() {
    printf 'journal|%s|\n' "$LOGB_JOURNAL_DIR"
    printf 'nginx|%s|access.log* error.log*\n' "$LOGB_NGINX_LOG_DIR"
    printf 'goamnezia|%s|goamnezia*\n' "$LOGB_VAR_LOG_DIR"
}

# _logb_run <команда> … — мутация сторожа. В сухом прогоне только строка «DRY: …»: journalctl --vacuum-size,
# сжатие и удаление файлов в /var/log и обрезка журналов Docker — это машина, где идёт прогон, а у logb_enforce
# проверки сухого прогона не было вовсе (находка L1-02).
_logb_dry() { [ "${GOAMNEZIA_DRY_RUN:-0}" = 1 ]; }
_logb_run() {
    if _logb_dry; then printf 'DRY: %s\n' "$*" >&2; return 0; fi
    "$@"
}
_logb_vacuum() { journalctl --vacuum-size="$1" >/dev/null 2>&1 || true; }

_logb_mb() { echo $(( ${1:-0} / 1024 / 1024 )); }

# _logb_bytes <путь> [маска] — размер в байтах. С маской считаем только своё,
# без неё — каталог целиком. du -sb есть не везде (busybox), отсюда запасной путь.
# Маска может содержать НЕСКОЛЬКО шаблонов через пробел. Одного не хватало для
# общего каталога вроде /var/log/nginx, где рядом лежат логи чужих сайтов:
# сожительство с goTelegram Pro на одном сервере — штатный сценарий серии, и
# сносить архивы соседа мы права не имеем. Собираем для find выражение вида
#   \( -name a -o -name b \)
_LOGB_NAME_ARGS=()
_logb_set_name_args() {
    local mask="${1:-}" pat first=1
    local -a pats=()
    _LOGB_NAME_ARGS=()
    [ -n "$mask" ] || return 0
    _LOGB_NAME_ARGS=( '(' )
    # Шаблоны — через read -a, а не `for pat in $mask`: без кавычек «goamnezia*» раскрывался по ТЕКУЩЕМУ
    # каталогу, и из /root (там лежат копии сноса goamnezia_backup_*) сторож искал в /var/log файлы с их
    # именами — бюджет своих журналов выходил нулём.
    read -r -a pats <<<"$mask"
    for pat in "${pats[@]}"; do
        [ "$first" = "1" ] || _LOGB_NAME_ARGS+=( -o )
        _LOGB_NAME_ARGS+=( -name "$pat" )
        first=0
    done
    _LOGB_NAME_ARGS+=( ')' )
}

# Наружу всегда уходит ЧИСЛО. Раньше запасной путь был недостижим: код возврата
# конвейера — это код последней команды, а awk выходит нулём и на пустом вводе,
# поэтому `du … | awk … && return 0` срабатывало всегда. А `du -sb` на busybox
# и на BSD не существует вовсе: stdout пуст, awk без записей не печатает
# ничего — и наружу уходила пустая строка. Дальше `[ "$used" -le "$budget" ]`
# роняло «integer expression expected», отказ трактовался как «в бюджете», и
# сторож не подрезал ничего именно там, где это было нужно.
_logb_bytes() {
    local p="${1:-}" mask="${2:-}" out
    [ -e "$p" ] || { echo 0; return 0; }
    if [ -n "$mask" ]; then
        # Без -printf: его нет у BSD и busybox find, и там размер своих файлов в общем каталоге
        # выходил нулём — сторож не подрезал ничего.
        out=$(_logb_files "$p" "$mask" | _logb_sum_sizes)
        [[ "$out" =~ ^[0-9]+$ ]] || out=0
        echo "$out"
        return 0
    fi
    out=$(du -sb "$p" 2>/dev/null | awk '{print $1+0; exit}')
    if ! [[ "$out" =~ ^[0-9]+$ ]]; then
        out=$(find "$p" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')
    fi
    [[ "$out" =~ ^[0-9]+$ ]] || out=0
    echo "$out"
    return 0
}

# Свободные мегабайты на /var/log. Пусто здесь означает «не знаем» и НЕ должно
# превращаться в ноль: ноль свободного места включает аварийный режим, и сбой
# df резал бы логи на ровном месте. Вызывающие обязаны проверять на пустоту.
_logb_free_mb() {
    # Фикстура GOAMNEZIA_DF_FIXTURE (ga_df_mb, TAIL-12) — вместо диска машины прогона
    if [ -n "${GOAMNEZIA_DF_FIXTURE:-}" ] && type ga_df_mb >/dev/null 2>&1; then
        ga_df_mb /var/log | awk 'NF {print $3+0; exit}'
        return 0
    fi
    df -Pm /var/log 2>/dev/null | awk 'NR==2 {print $4+0; exit}'
}

# ── Компонент docker: только НАШИ контейнеры ─────────────────────────────────
# Границу задаёт config.json, а не маска имени файла: имена json-логов Docker —
# это идентификаторы контейнеров, по ним «своё» от «чужого» не отличить, а в
# /var/lib/docker/containers лежат логи всех контейнеров машины, включая соседей
# по серверу. Список контейнеров берём из наших профилей; если docker недоступен
# или config.json ещё нет — список пуст, и компонент просто ничего не трогает.
_logb_our_containers() {
    local cfg="${CONFIG_FILE:-${GOAMNEZIA_DIR:-/opt/goamnezia}/config.json}"
    [ -f "$cfg" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    jq -r '.profiles // {} | to_entries[] | .value.container // empty' "$cfg" 2>/dev/null
}

# Печатает пути к файлам json-логов наших контейнеров (живой + ротированные).
#
# Версия API демона закрепляется ЗАРАНЕЕ (тот же урок, что в
# lib/preflight.sh:ga_pf_docker_ps). На сервере с автообновлениями пакет docker
# обновляется ночью сам, а демон не перезапускается — и каждая команда нового
# CLI падает на старом демоне. Голый вызов возвращал пустую строку, комментарий
# ниже трактовал её как «драйвера нет», и журналы подхваченных контейнеров
# выпадали из бюджета совсем — ровно тот сценарий, ради которого модуль
# написан. docker.sh в юните сторожа загружается рядом (logb_install_timer).
_logb_docker_files() {
    command -v docker >/dev/null 2>&1 || return 0
    type docker_api_pin >/dev/null 2>&1 && docker_api_pin
    local name logpath rc warned=0
    while read -r name; do
        [ -n "$name" ] || continue
        # Код возврата снимаем ДО любого отрицания: `if ! cmd; then rc=$?` дал бы
        # код инвертированного условия, а не docker.
        logpath=$(docker inspect --format '{{.LogPath}}' "$name" 2>/dev/null); rc=$?
        if [ "$rc" != 0 ]; then
            # Контейнера просто нет (профиль в config.json, а контейнер снят) — его журналов нет, считать нечего,
            # и это не «демон недоступен» (находка L3-14 / TAIL-11). Различает docker_container_state
            # (lib/docker.sh): missing — дальше молча, о пропавшем контейнере скажет сторож; без docker.sh — как прежде.
            if type docker_container_state >/dev/null 2>&1 \
               && [ "$(docker_container_state "$name" 2>/dev/null)" = missing ]; then
                continue
            fi
            # Демон не ответил. Это НЕ «логов нет»: молчать нельзя, иначе
            # бюджет считает чужой рост своим отсутствием.
            if [ "$warned" = 0 ] && type log_warning >/dev/null 2>&1; then
                log_warning "$(tf logb_docker_unreachable "$name")"
                warned=1
            fi
            continue
        fi
        # Пустой LogPath = драйвер none, то есть файла нет вовсе — так и должно быть
        [ -n "$logpath" ] || continue
        # Ходим только по каталогу самого контейнера и только по его же логам
        local d base f
        d=$(dirname "$logpath"); base=$(basename "$logpath")
        [ -d "$d" ] || continue
        for f in "$d/$base" "$d/$base".*; do
            [ -f "$f" ] || continue
            printf '%s\n' "$f"
        done
    done <<< "$(_logb_our_containers)"
    return 0
}

_logb_docker_bytes() {
    _logb_docker_files | while read -r f; do
        [ -f "$f" ] || continue
        { wc -c < "$f"; } 2>/dev/null
    done | awk '{s+=$1} END{print s+0}'
}

# Подрезка docker-логов. Активный файл (<id>-json.log без числового хвоста) не
# трогаем никогда: обрезать файл под открытым дескриптором значит получить дыру
# в логе и разъехавшийся offset у пишущего демона.
_logb_docker_trim() {
    local budget_b="${1:-0}" used f
    used=$(_logb_docker_bytes)
    [ "${used:-0}" -le "$budget_b" ] && return 0

    _logb_docker_files | grep -E '\.[0-9]+$' 2>/dev/null | while read -r f; do
        [ -f "$f" ] || continue
        gzip -9 "$f" 2>/dev/null || true
    done

    used=$(_logb_docker_bytes)
    while [ "${used:-0}" -gt "$budget_b" ]; do
        f=$(_logb_docker_files | grep -E '\.(gz|xz|zst)$' 2>/dev/null | head -1)
        [ -n "$f" ] || break
        rm -f "$f" 2>/dev/null || break
        used=$(_logb_docker_bytes)
    done
    return 0
}

# ── Слой 1: объявленные потолки ──────────────────────────────────────────────
logb_apply_journald() {
    local jd="/etc/systemd/journald.conf.d/99-goamnezia.conf"
    # SystemMaxUse — жёсткий потолок на активные+архивные вместе.
    # SystemMaxFileSize — ротация по размеру, не по дате: всплеск режется сразу.
    # SystemKeepFree — главная защита: journald отступает, не добивая раздел.
    local want="[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=${LOGB_COMPONENT_MB}M
SystemMaxFileSize=${LOGB_FILE_MB}M
SystemMaxFiles=$(( LOGB_COMPONENT_MB / LOGB_FILE_MB ))
SystemKeepFree=${LOGB_KEEP_FREE_MB}M
MaxFileSec=1day
RateLimitIntervalSec=30s
RateLimitBurst=5000"
    if [ ! -f "$jd" ] || [ "$(cat "$jd" 2>/dev/null)" != "$want" ]; then
        mkdir -p /etc/systemd/journald.conf.d 2>/dev/null
        { printf '%s\n' "$want" > "$jd"; } 2>/dev/null || return 1
        systemctl restart systemd-journald 2>/dev/null || true
        journalctl --vacuum-size="${LOGB_COMPONENT_MB}M" >/dev/null 2>&1 || true
        return 1
    fi
    return 0
}

# ── Чужие конфиги logrotate ──────────────────────────────────────────────────
# Наш goamnezia-nginx и дебиановский /etc/logrotate.d/nginx описывают ОДИН И ТОТ
# ЖЕ /var/log/nginx/*.log, а двух хозяев у файла logrotate не признаёт: он
# ругается «duplicate log entry», бросает разбор и выходит с ошибкой — вместе с
# ЧУЖИМИ конфигами, до которых не дошёл. То есть продукт ломает ротацию всему
# серверу, а не только себе, и logrotate.service висит в failed.
#
# Прежние версии уводили файл переименованием ВНУТРИ каталога
# (nginx.goamnezia-disabled). Это не работает: logrotate читает каталог целиком,
# а хвост .goamnezia-disabled в его список игнорируемых (tabooext) не входит —
# старый конфиг продолжал разбираться. Поймано на стенде 11.09.2026:
#   error: nginx.goamnezia-disabled:1 duplicate log entry for /var/log/nginx/access.log
#
# ВЫБРАН ПЕРЕНОС ФАЙЛА ИЗ КАТАЛОГА, а не хвост `.disabled`. Хвост logrotate
# игнорирует лишь потому, что так настроен tabooext, а он правится в
# /etc/logrotate.conf на конкретной машине — чужая правка вернула бы конфликт,
# и мы снова узнали бы об этом только по упавшему юниту. Из каталога файл не
# виден ни при каких настройках. Копия лежит в состоянии продукта: переживает
# обновление, попадает в бэкап и возвращается на место при сносе.
_logb_stash_dir() {
    printf '%s/logrotate-foreign' "${STATE_DIR:-${GOAMNEZIA_DIR:-/opt/goamnezia}/state}"
}

# _logb_stash_foreign <имя> — увести чужой конфиг из каталога logrotate в наше
# состояние. Имя файла в хранилище = имя в каталоге, по нему же идёт возврат.
_logb_stash_foreign() {
    local name="${1:-}" dir stash legacy
    [ -n "$name" ] || return 1
    dir="$LOGB_LOGROTATE_DIR"
    stash="$(_logb_stash_dir)"
    legacy="$dir/${name}${LOGB_LEGACY_SUFFIX}"
    [ -f "$dir/$name" ] || [ -f "$legacy" ] || return 0
    mkdir -p "$stash" 2>/dev/null || return 1
    if [ -f "$dir/$name" ]; then
        # Оба сразу — это хвост прошлой версии продукта плюс конфиг, который
        # вернул пакетный менеджер при обновлении nginx. Возвращать потом надо
        # СВЕЖИЙ, но и старый не затираем: чужое мы уносим, а не уничтожаем.
        [ -f "$legacy" ] && mv -f "$legacy" "$stash/${name}.prev" 2>/dev/null
        mv -f "$dir/$name" "$stash/$name" 2>/dev/null || return 1
    else
        mv -f "$legacy" "$stash/$name" 2>/dev/null || return 1
    fi
    return 0
}

# _logb_restore_foreign <имя> — вернуть чужой конфиг на место. 0 — вернули.
_logb_restore_foreign() {
    local name="${1:-}" dir stash
    [ -n "$name" ] || return 1
    dir="$LOGB_LOGROTATE_DIR"
    stash="$(_logb_stash_dir)"
    [ -f "$stash/$name" ] || return 1
    # Пакет успел положить свой файл обратно — наш экземпляр лишний. Затирать
    # чужое новое нашей копией нельзя: это снова два хозяина у одного лога.
    [ -f "$dir/$name" ] && { rm -f "$stash/$name" 2>/dev/null; return 1; }
    mkdir -p "$dir" 2>/dev/null || return 1
    mv -f "$stash/$name" "$dir/$name" 2>/dev/null || return 1
    return 0
}

# logb_remove_logrotate — снять наши правила ротации и вернуть чужие на место.
# Зовётся при сносе продукта. Без этого /var/log/nginx остаётся БЕЗ ротации
# вовсе: наш конфиг уезжает вместе с каталогом продукта, а дебиановский так и
# лежит уведённым — то есть снос оставляет за собой ту же беду, ради которой
# модуль написан. Идемпотентна: второй вызов ничего не делает.
logb_remove_logrotate() {
    rm -f "$LOGB_LOGROTATE_DIR/goamnezia-nginx" "$LOGB_LOGROTATE_DIR/goamnezia" 2>/dev/null || true
    _logb_restore_foreign nginx || true
    return 0
}

logb_apply_logrotate() {
    local changed=0 f want rot
    # Живой слой ≤ LOGB_LIVE_MB, архив — остальное. При файле в LOGB_FILE_MB это
    # (300-150)/50*10 поколений: сжатые весят примерно вдесятеро меньше исходных.
    rot=$(( (LOGB_COMPONENT_MB - LOGB_LIVE_MB) / LOGB_FILE_MB * 10 ))
    [ "$rot" -lt 3 ] && rot=3

    f="$LOGB_LOGROTATE_DIR/goamnezia-nginx"
    if [ -d "$LOGB_NGINX_LOG_DIR" ]; then
        want="$LOGB_NGINX_LOG_DIR/*.log {
    su root adm
    hourly
    maxsize ${LOGB_FILE_MB}M
    rotate ${rot}
    missingok
    notifempty
    compress
    delaycompress
    create 0640 www-data adm
    sharedscripts
    postrotate
        [ -f /run/nginx.pid ] && kill -USR1 \$(cat /run/nginx.pid) 2>/dev/null || true
    endscript
}"
        if [ ! -f "$f" ] || [ "$(cat "$f" 2>/dev/null)" != "$want" ]; then
            { printf '%s\n' "$want" > "$f"; } 2>/dev/null && changed=1
        fi
        # Дебиановский дефолт (14 суток, без потолка по размеру) уводим с дороги
        # ТОЛЬКО когда наш конфиг лёг: иначе логи nginx остались бы без ротации.
        # Вне сравнения содержимого нарочно — на сервере прошлой версии наш файл
        # уже совпадает, и внутри «если изменилось» починка не доехала бы туда,
        # где как раз и лежит хвост .goamnezia-disabled.
        [ -f "$f" ] && _logb_stash_foreign nginx
    fi

    # Собственные логи продукта. goamnezia-audit.log содержит имена
    # пользователей и Telegram ID — 0600 и su root, как и живой файл.
    f="$LOGB_LOGROTATE_DIR/goamnezia"
    want="/var/log/goamnezia*.log {
    su root root
    hourly
    maxsize ${LOGB_FILE_MB}M
    rotate ${rot}
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 0600 root root
}"
    if [ ! -f "$f" ] || [ "$(cat "$f" 2>/dev/null)" != "$want" ]; then
        { printf '%s\n' "$want" > "$f"; } 2>/dev/null && changed=1
    fi

    # Нет каталога /etc/logrotate.d (logrotate не стоит — в зависимостях его нет) — наш конфиг не лёг, и юнит с
    # ним в ExecStart падал бы каждый час и висел в failed: тот же случай, что 0.4.3 чинил для nginx (находка
    # SR-37). Юнит и таймер тогда не ставим, а прежние снимаем.
    if [ ! -f "$LOGB_LOGROTATE_DIR/goamnezia" ]; then
        if [ -f "$LOGB_UNIT_DIR/goamnezia-logrotate.timer" ] || [ -f "$LOGB_UNIT_DIR/goamnezia-logrotate.service" ]; then
            systemctl disable --now goamnezia-logrotate.timer >/dev/null 2>&1 || true
            rm -f "$LOGB_UNIT_DIR/goamnezia-logrotate.timer" "$LOGB_UNIT_DIR/goamnezia-logrotate.service" 2>/dev/null
            systemctl daemon-reload 2>/dev/null || true
            systemctl reset-failed goamnezia-logrotate.service >/dev/null 2>&1 || true
        fi
        return 0
    fi
    # logrotate по умолчанию ходит раз в сутки — для «maxsize» этого мало.
    # Свой таймер раз в час: тогда hourly+maxsize действительно работают.
    local lt="$LOGB_UNIT_DIR/goamnezia-logrotate.timer"
    want="[Unit]
Description=$(t logb_unit_desc_rotate_timer)
[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
AccuracySec=1min
[Install]
WantedBy=timers.target"
    if [ ! -f "$lt" ] || [ "$(cat "$lt" 2>/dev/null)" != "$want" ]; then
        { printf '%s\n' "$want" > "$lt"; } 2>/dev/null && changed=1
    fi
    # В юнит — только конфиги, которые лежат на диске. logrotate с именем
    # несуществующего файла выходит с ошибкой, а goamnezia-nginx пишется лишь
    # там, где есть nginx: на сервере «Только VPN» юнит падал каждый час и висел
    # в failed (поймано на живом стенде 24.09.2026). Появится nginx — следующий
    # прогон (меню, мастер, таймеры) допишет его конфиг и сюда: юнит сравнивается
    # целиком.
    local ls_="$LOGB_UNIT_DIR/goamnezia-logrotate.service" confs="$LOGB_LOGROTATE_DIR/goamnezia" unit_changed=0
    [ -f "$LOGB_LOGROTATE_DIR/goamnezia-nginx" ] && confs="$confs $LOGB_LOGROTATE_DIR/goamnezia-nginx"
    want="[Unit]
Description=$(t logb_unit_desc_rotate)
[Service]
Type=oneshot
ExecStart=/usr/sbin/logrotate $confs"
    if [ ! -f "$ls_" ] || [ "$(cat "$ls_" 2>/dev/null)" != "$want" ]; then
        { printf '%s\n' "$want" > "$ls_"; } 2>/dev/null && changed=1 && unit_changed=1
    fi

    if [ "$changed" = "1" ]; then
        systemctl daemon-reload 2>/dev/null || true
        # Прежний провал (юнит со ссылкой на отсутствующий конфиг) иначе висел бы
        # в failed до следующего часа — снимаем его вместе с починкой юнита.
        [ "$unit_changed" = 1 ] && { systemctl reset-failed goamnezia-logrotate.service >/dev/null 2>&1 || true; }
        systemctl enable --now goamnezia-logrotate.timer >/dev/null 2>&1 || true
    fi
    return 0
}

# ── Слой 2: сторож ───────────────────────────────────────────────────────────
# Считает реальные байты и подрезает. Порядок: сначала жмём то, что ещё не сжато,
# потом раздутый живой файл отдаём ротации, и только потом удаляем самые старые
# архивы — СВЕРХ бюджета архивов. Активный файл не трогаем никогда — его отдаёт
# ротация, а не мы.
#
# Живой файл в счёт удаления архивов не идёт. Раньше считался весь goamnezia* в
# /var/log вместе с живым goamnezia-audit.log, и поток записей в журнал действий
# (сотни мегабайт за час) стирал сжатые архивы того же журнала — журнал
# безопасности вычищался потоком, который мог устроить сам нарушитель (находка
# аудита безопасности SEC-C2, 25.09.2026). Теперь архивы сносятся, только когда
# их САМИХ больше своей доли бюджета, и архивы журнала действий — последними.

# _logb_files <каталог> [маска] — файлы компонента, по одному в строке. Без -printf:
# его нет у BSD и busybox find.
_logb_files() {
    local dir="${1:-}" mask="${2:-}"
    local scope=( -maxdepth 1 -type f )
    if [ -n "$mask" ]; then
        _logb_set_name_args "$mask"
        scope=( "${scope[@]}" "${_LOGB_NAME_ARGS[@]}" )
    fi
    find "$dir" "${scope[@]}" 2>/dev/null
}
# stdin: пути → сумма размеров в байтах (всегда число)
_logb_sum_sizes() {
    local f n s=0
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        n=$( { wc -c <"$f"; } 2>/dev/null | tr -d ' ')
        [[ "$n" =~ ^[0-9]+$ ]] && s=$((s + n))
    done
    echo "$s"
}
_logb_is_archive() { case "${1:-}" in *.gz|*.xz|*.zst) return 0 ;; esac; return 1; }
_logb_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# _logb_rotate_oversize <каталог> <маска> — живой файл вырос больше двух порций ротации (поток записей
# между часовыми проходами logrotate) — ротируем его НАШИМ конфигом сейчас, а не сносим архивы ради него.
_logb_rotate_oversize() {
    local dir="${1:-}" mask="${2:-}" f n need=0 conf
    command -v logrotate >/dev/null 2>&1 || return 0
    if [ "$dir" = "$LOGB_NGINX_LOG_DIR" ]; then conf="$LOGB_LOGROTATE_DIR/goamnezia-nginx"; else conf="$LOGB_LOGROTATE_DIR/goamnezia"; fi
    [ -f "$conf" ] || return 0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        _logb_is_archive "$f" && continue
        [[ "$f" =~ \.[0-9]+$ ]] && continue
        n=$( { wc -c <"$f"; } 2>/dev/null | tr -d ' ')
        [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt $(( LOGB_FILE_MB * 2 * 1024 * 1024 )) ] && need=1
    done <<<"$(_logb_files "$dir" "$mask")"
    [ "$need" = 1 ] || return 0
    logrotate -f "$conf" >/dev/null 2>&1 || true
    return 0
}

_logb_trim_dir() {
    local dir="${1:-}" mask="${2:-}" budget_b="$3" f all arch_budget arch_b
    [ -d "$dir" ] || return 0
    # ПРЕДОХРАНИТЕЛЬ. Маска обязательна для общих каталогов: пустая означает
    # «каталог наш целиком», и тогда границей служит сам путь. В /var/log с
    # пустой маской не заходим никогда — там логи всей системы и соседей.
    if [ -z "$mask" ] && [ "$dir" = "/var/log" ]; then
        return 0
    fi

    all=$(_logb_files "$dir" "$mask")
    [ "$(_logb_sum_sizes <<<"$all")" -le "$budget_b" ] && return 0

    # 1) дожать несжатое из уже ротированных (имена вида *.1, *.log.2 и т.п.).
    #    Активный файл (без числового хвоста) не трогаем: обрезать файл под
    #    открытым дескриптором — это дыра в логе и разъехавшийся offset у писателя.
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        _logb_is_archive "$f" && continue
        [[ "$f" =~ \.[0-9]+$ ]] || continue
        gzip -9 "$f" 2>/dev/null || true
    done <<<"$all"

    # 2) раздутый живой файл — ротации, а не повод сносить архивы
    _logb_rotate_oversize "$dir" "$mask"

    # 3) архивы — сверх СВОЕЙ доли бюджета (бюджет минус живой слой), самые старые первыми; архивы
    #    журнала действий (goamnezia-audit*) — только когда других не осталось.
    local comp="${LOGB_COMPONENT_MB:-300}" live="${LOGB_LIVE_MB:-150}"
    [ "$comp" -gt 0 ] 2>/dev/null || comp=300
    [ "$live" -lt "$comp" ] 2>/dev/null || live=$(( comp / 2 ))
    arch_budget=$(( budget_b * (comp - live) / comp ))
    while :; do
        all=$(_logb_files "$dir" "$mask" | while IFS= read -r f; do _logb_is_archive "$f" && printf '%s\n' "$f"; done)
        arch_b=$(_logb_sum_sizes <<<"$all")
        [ "$arch_b" -gt "$arch_budget" ] || break
        f=$(while IFS= read -r f; do
                [ -n "$f" ] || continue
                case "$(basename "$f")" in *audit*) printf '1 %s %s\n' "$(_logb_mtime "$f")" "$f" ;;
                                           *)       printf '0 %s %s\n' "$(_logb_mtime "$f")" "$f" ;; esac
            done <<<"$all" | sort -k1,1n -k2,2n | head -1 | cut -d' ' -f3-)
        [ -n "$f" ] || break
        rm -f "$f" 2>/dev/null || break
    done
    return 0
}

logb_enforce() {
    local name path mask used budget_b trimmed="" free
    budget_b=$(( LOGB_COMPONENT_MB * 1024 * 1024 ))

    # journald подрезаем его же средствами — руками в /var/log/journal лезть нельзя.
    used=$(_logb_bytes "$LOGB_JOURNAL_DIR")
    if [ "$used" -gt "$budget_b" ]; then
        _logb_run _logb_vacuum "${LOGB_COMPONENT_MB}M"
        trimmed="${trimmed}journal "
    fi

    while IFS='|' read -r name path mask; do
        [ -n "$name" ] || continue
        [ "$name" = "journal" ] && continue
        used=$(_logb_bytes "$path" "$mask")
        if [ "$used" -gt "$budget_b" ]; then
            _logb_run _logb_trim_dir "$path" "$mask" "$budget_b"
            trimmed="${trimmed}${name} "
        fi
    done <<< "$(_logb_components)"

    used=$(_logb_docker_bytes)
    if [ "${used:-0}" -gt "$budget_b" ]; then
        _logb_run _logb_docker_trim "$budget_b"
        trimmed="${trimmed}docker "
    fi

    # Аварийный режим: место кончается — режем всех вдвое, не дожидаясь бюджетов.
    # Именно этот сценарий кладёт nginx и sshd, поэтому он важнее любых потолков.
    free=$(_logb_free_mb)
    if [ -n "$free" ] && [ "$free" -lt "$LOGB_KEEP_FREE_MB" ]; then
        _logb_run _logb_vacuum "$(( LOGB_COMPONENT_MB / 2 ))M"
        while IFS='|' read -r name path mask; do
            [ -n "$name" ] || continue
            [ "$name" = "journal" ] && continue
            _logb_run _logb_trim_dir "$path" "$mask" $(( budget_b / 2 ))
        done <<< "$(_logb_components)"
        _logb_run _logb_docker_trim $(( budget_b / 2 ))
        trimmed="${trimmed}$(tf logb_emergency "$free") "
        type log_warning >/dev/null 2>&1 && \
            log_warning "$(tf logb_emergency "$free")"
    fi

    if _logb_dry; then
        printf 'DRY: %s\n' "write $LOGB_STATE" >&2
    else
        { printf '%s %s\n' "$(date -Iseconds 2>/dev/null || date)" "${trimmed:-$(t logb_in_budget)}" \
            > "$LOGB_STATE"; } 2>/dev/null || true
    fi
    # Подрезка журналов — мутация: в журнал действий, как у остальных (находка SR-47).
    if [ -n "$trimmed" ] && type ga_audit >/dev/null 2>&1; then
        ga_audit "${GOAMNEZIA_WHO:-timer}" "logs-enforce" "${trimmed% }"
    fi
    return 0
}

logb_install_timer() {
    local changed=0 want f
    # lib/docker.sh в списке ради docker_api_pin: сторож стартует из таймера, вне
    # меню, и без этого модуля закреплять версию API было бы нечем — а именно
    # там, где CLI разошёлся с демоном, журналы и растут без предела.
    want="[Unit]
Description=$(t logb_unit_desc_sweep)
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'source ${GOAMNEZIA_DIR:-/opt/goamnezia}/lib/common.sh && source ${GOAMNEZIA_DIR:-/opt/goamnezia}/lib/i18n.sh && load_language \"\$(detect_language)\" && source ${GOAMNEZIA_DIR:-/opt/goamnezia}/lib/docker.sh && source ${GOAMNEZIA_DIR:-/opt/goamnezia}/lib/logbudget.sh && logb_enforce'"
    f="$LOGB_UNIT_DIR/${LOGB_SWEEP_SVC}.service"
    if [ ! -f "$f" ] || [ "$(cat "$f" 2>/dev/null)" != "$want" ]; then
        { printf '%s\n' "$want" > "$f"; } 2>/dev/null && changed=1
    fi
    want="[Unit]
Description=$(t logb_unit_desc_sweep_timer)
[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
AccuracySec=1min
[Install]
WantedBy=timers.target"
    f="$LOGB_UNIT_DIR/${LOGB_SWEEP_SVC}.timer"
    if [ ! -f "$f" ] || [ "$(cat "$f" 2>/dev/null)" != "$want" ]; then
        { printf '%s\n' "$want" > "$f"; } 2>/dev/null && changed=1
    fi
    if [ "$changed" = "1" ]; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable --now "${LOGB_SWEEP_SVC}.timer" >/dev/null 2>&1 || true
    fi
    return 0
}

# ── Отчёт (для меню, бота и панели) ──────────────────────────────────────────
# Печатает по строке на компонент: имя, занято МБ, бюджет МБ, доля в процентах.
# Только stdout и только числа — форматирование делает вызывающий.
logb_status() {
    local name path mask used mb pct
    while IFS='|' read -r name path mask; do
        [ -n "$name" ] || continue
        used=$(_logb_bytes "$path" "$mask"); mb=$(_logb_mb "$used")
        pct=$(( mb * 100 / (LOGB_COMPONENT_MB > 0 ? LOGB_COMPONENT_MB : 1) ))
        printf '%s %s %s %s\n' "$name" "$mb" "$LOGB_COMPONENT_MB" "$pct"
    done <<< "$(_logb_components)"
    used=$(_logb_docker_bytes); mb=$(_logb_mb "${used:-0}")
    pct=$(( mb * 100 / (LOGB_COMPONENT_MB > 0 ? LOGB_COMPONENT_MB : 1) ))
    printf 'docker %s %s %s\n' "$mb" "$LOGB_COMPONENT_MB" "$pct"
    # Четыре поля в строке всегда: пустое поле разъехалось бы у разбирающего.
    local free; free=$(_logb_free_mb)
    printf 'free %s - -\n' "${free:--}"
}

# Единая точка входа: применить всё. Идемпотентно.
logb_apply_all() {
    logb_apply_journald || true
    logb_apply_logrotate || true
    logb_install_timer || true
    logb_enforce || true
    return 0
}
