#!/bin/bash
# goAmnezia pro — бэкап и восстановление (порт из goTelegram Pro).
#
# Состав архива (PLAN §6.7 + контракт §1):
#   config.json · users.json · state/<container>/… · .language ·
#   .env и user_langs.json бота · nginx-конфиг goamnezia ·
#   Let's Encrypt live/archive/renewal домена · tls/ (самоподписанный
#   сертификат сайта режима lite_site) · subs/ (секреты подписок, lib/subs.sh) ·
#   metadata.json
#
# Смысл именно такого состава: восстановление на ЧИСТОМ сервере обязано поднять
# те же контейнеры с теми же ключами. Ключи пиров лежат в users.json, серверные
# приватные ключи и clientsTable — в state/, поэтому переезд между VPS проходит
# без перевыпуска ни одного клиентского ключа.

# Единая глубина хранения: в goTelegram SSH-меню чистило до 5 и молча удаляло
# архивы, накопленные таймером (у него было 30). Число одно на все интерфейсы.
BACKUP_KEEP_DEFAULT=30

# Сколько места требуем перед копией и перед восстановлением. Копия — это
# config.json, users.json, state/ и сертификаты: десятки мегабайт. Но архив
# собирается через промежуточный каталог, а восстановление ещё и распаковывает
# его целиком, поэтому берём с запасом. Проверка check_disk_space была написана
# и не вызвана ни разу: на забитом диске человек видел «не удалось записать» и
# английскую ошибку системы, а про место продукт не говорил.
GA_BACKUP_MIN_DISK_MB=512
# Куда пишем исход ночного прохода: «когда была последняя копия» не отвечал ни
# один экран, хотя восстановление из копии — рекомендованный выход изо всех
# остальных бед.
ga_backup_last_file() { printf '%s/backup_last.json' "${GOAMNEZIA_DIR:-/opt/goamnezia}"; }

# Те же переопределения, что у website.sh, но без зависимости от модуля сайта: ночная копия грузит
# только common/i18n/backup. В сухом прогоне системные файлы нельзя ни восстанавливать, ни забирать
# в тестовый архив: на машине с настоящим доменом это сертификаты и секретные адреса владельца.
_ga_backup_nginx_conf() {
    if [ -n "${GOAMNEZIA_NGINX_DIR:-}" ]; then printf '%s/sites-available/goamnezia' "$GOAMNEZIA_NGINX_DIR"
    else printf '%s' "${NGINX_SITE_CONF:-/etc/nginx/sites-available/goamnezia}"; fi
}
_ga_backup_nginx_link() {
    if [ -n "${GOAMNEZIA_NGINX_DIR:-}" ]; then printf '%s/sites-enabled/goamnezia' "$GOAMNEZIA_NGINX_DIR"
    else printf '%s' "${NGINX_SITE_LINK:-/etc/nginx/sites-enabled/goamnezia}"; fi
}
_ga_backup_le_dir() { printf '%s' "${GOAMNEZIA_LE_DIR:-/etc/letsencrypt}"; }
_ga_backup_external_ok() {
    [ "${GOAMNEZIA_DRY_RUN:-0}" = 1 ] || return 0
    # Даже явный путь в /etc остаётся настоящей машиной; стенд задаёт свои каталоги вне /etc.
    case "${1:-}" in ""|/etc|/etc/*) return 1 ;; esac
    return 0
}

# ── Целостность источников копии ─────────────────────────────────────────────
# Тот же закон, что у config.json и users.json (контракт §0.5, образец —
# _ga_config_intact в lib/common.sh): читатель обязан отличать «файла ещё нет»
# от «файл сломан». Для копии это вопрос жизни ключей. Битый config.json,
# положенный в архив молча, выглядел внутри как обычная установка Lite: карточка
# восстановления подставляла умолчания и про порчу не говорила. Таймер ходит
# ежесуточно при глубине 30 — за месяц незамеченной порчи ротация выносила все
# здоровые архивы, а дальше восстановление клало мусор поверх живой установки.
# Поэтому копия битого источника не создаётся вовсе.

# _ga_backup_fail <код> <сообщение> — отказ туда, где его ждут все интерфейсы:
# мост --action читает GA_ERR_CODE/GA_ERR_MSG и GA_LAST_ERROR_CODE, и без
# сообщения бот с панелью показали бы безликое «Действие не выполнено.».
# Своя функция, а не ga_err из lib/docker.sh: таймер бэкапа грузит только
# common.sh, i18n.sh и этот модуль, docker.sh в его оболочке нет.
_ga_backup_fail() {
    GA_ERR_CODE="${1:-}"
    GA_ERR_MSG="${2:-}"
    ga_set_error "${1:-}"
    return 1
}

# systemctl под dry-run: на стенде команду печатаем, а не выполняем — тот же
# приём, что у ga_timers_run_quiet в lib/timers.sh. Отказ реального systemctl
# пробрасываем: он значит, что таймер не встал.
_ga_backup_systemctl() {
    if type ga_dry >/dev/null 2>&1 && ga_dry; then
        type ga_dry_echo >/dev/null 2>&1 && ga_dry_echo "systemctl $*"
        return 0
    fi
    systemctl "$@" >/dev/null 2>&1
}

# _ga_backup_json_ok <файл> — 0, если файла нет или он разбирается как объект.
_ga_backup_json_ok() {
    local f="${1:-}"
    [ -f "$f" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    jq -e 'type == "object"' "$f" >/dev/null 2>&1
}

# _ga_backup_state <файл> → ok | broken | absent — для metadata.json.
_ga_backup_state() {
    local f="${1:-}"
    if [ ! -f "$f" ]; then printf 'absent'; return 0; fi
    if _ga_backup_json_ok "$f"; then printf 'ok'; else printf 'broken'; fi
}

# _ga_backup_sources_intact — 0, если из текущего состояния можно снять честную
# копию. Иначе спасаем копию каждого битого файла (он не должен стать могилой:
# человек чинит его руками и ошибается ещё раз), называем её вслух и ставим код
# backup_source_corrupt. Зовётся из ТОЙ ЖЕ оболочки, что и мост: сборка архива
# ниже идёт в подоболочке ради umask, а в подоболочке ga_set_error пропадает.
_ga_backup_sources_intact() {
    local f rescue msg first=""
    for f in "$CONFIG_FILE" "$USERS_FILE"; do
        _ga_backup_json_ok "$f" && continue
        rescue=""
        if type _ga_json_rescue >/dev/null 2>&1; then
            rescue=$(_ga_json_rescue "$f") || rescue=""
        fi
        if [ -n "$rescue" ]; then
            msg=$(tf backup_source_corrupt "$f" "$rescue")
        else
            msg=$(tf backup_source_corrupt_nocopy "$f")
        fi
        log_error "$msg"
        # Наружу уходит первый сломанный файл: он и есть причина отказа.
        [ -n "$first" ] || first="$msg"
    done
    [ -n "$first" ] || return 0
    log_error "$(tf backup_source_corrupt_howto "$BACKUP_DIR")"
    _ga_backup_fail backup_source_corrupt "$first"
}

# _ga_backup_need_mb — место под снимок: источники архива (state/, конфиги, сертификаты) вдвое —
# промежуточные файлы и сам архив — плюс 16 МБ запаса. Обычно это единицы мегабайт.
_ga_backup_need_mb() {
    local kb=0 d s le_dir
    le_dir=$(_ga_backup_le_dir)
    for d in "$STATE_DIR" "$CONFIG_FILE" "$USERS_FILE" "$GOAMNEZIA_DIR/tls" "$le_dir/live" "$le_dir/archive"; do
        _ga_backup_external_ok "$d" || continue
        [ -e "$d" ] || continue
        s=$(du -sk "$d" 2>/dev/null | awk '{print $1 + 0}')
        [[ "$s" =~ ^[0-9]+$ ]] && kb=$((kb + s))
    done
    printf '%s' $(( kb * 2 / 1024 + 16 ))
}

# ── Создание бэкапа ──────────────────────────────────────────────────────────
# create_backup [пароль] [каталог] [1 — снимок]
# Обёртка, а не сразу подоболочка: проверка источников обязана ставить код
# ошибки там, где его ждут мост --action и вызывающий модуль.
# Третий аргумент — режим снимка перед восстановлением (_restore_snapshot):
# там копия нужна ИМЕННО потому, что живое состояние может быть уже сломано,
# и отказ означал бы «спасать нечего». Такой архив не притворяется исправным:
# metadata.json помечает каждый источник (sources.config / sources.users).
# Третий аргумент «data» — снимок перед миграцией (snapshot_preupgrade_state): источники должны быть целы,
# как у плановой копии, но место меряется по размеру данных, а не общим порогом 512 МБ.
create_backup() {
    local password="${1:-}" output_dir="${2:-$BACKUP_DIR}" allow_broken="${3:-}" need="$GA_BACKUP_MIN_DISK_MB"
    if [ "$allow_broken" != "1" ]; then
        _ga_backup_sources_intact || return 1
    fi
    if [ "$allow_broken" = "1" ] || [ "$allow_broken" = data ]; then
        # Снимку перед восстановлением — по размеру самих данных: 512 МБ, общий порог плановых копий,
        # на почти полном диске отказывали ровно в той аварии, из которой восстановление вытаскивает (SR-25).
        # Снимку перед миграцией — так же: на VPS, где свободно меньше 512 МБ, миграция не проходила
        # НИКОГДА — версия в config.json оставалась старой, миграция повторялась на каждом действии, а «Что
        # нового» показывалось при каждом входе, хотя снимок весит единицы мегабайт (находка UP-1).
        need=$(_ga_backup_need_mb)
    fi
    # Место — до сборки: иначе tar обрывается на полпути, а в каталоге остаётся
    # обрезанный архив, который выглядит как нормальная копия до самой попытки
    # из него восстановиться.
    # Меряем ТОТ раздел, куда пишем: $BACKUP_DIR на сервере бывает отдельным.
    # Внутри одного прохода backup_tick решение «ротировать» принималось по
    # одной файловой системе, а решение «писать» — по другой.
    if type check_disk_space >/dev/null 2>&1 && ! check_disk_space "$need" "${output_dir:-$BACKUP_DIR}"; then
        # check_disk_space уже сказала вслух, сколько места есть и сколько
        # надо; здесь остаётся только код и сообщение для моста, бота и панели.
        GA_ERR_CODE=low_disk
        GA_ERR_MSG="$(tf backup_err_low_disk "$need")"
        ga_set_error low_disk
        return 1
    fi
    _ga_backup_build "$password" "$output_dir"
}

# Тело — подоболочка "( … )": umask 077 действует только внутри и не
# протекает наружу. Внутри архива лежат users.json с приватными ключами пиров,
# .env бота с токеном BotFather и приватные ключи Let's Encrypt — ни архив, ни
# промежуточные файлы не должны быть доступны никому, кроме root.
_ga_backup_build() (
    umask 077

    local password="${1:-}"
    local output_dir="${2:-$BACKUP_DIR}"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_name tmp_dir stage suffix=0

    mkdir -p "$output_dir"
    chmod 700 "$output_dir" 2>/dev/null || true

    # Приватная песочница со случайным именем: фиксированный /tmp/<имя> позволял
    # локальному пользователю заранее подложить симлинк и подставить root'у путь.
    stage=$(mktemp -d "${TMPDIR:-/tmp}/goamnezia_backup.XXXXXXXX") || return 1
    chmod 700 "$stage" 2>/dev/null || true

    while true; do
        if [ "$suffix" -eq 0 ]; then
            backup_name="goamnezia_backup_${timestamp}"
        else
            backup_name="goamnezia_backup_${timestamp}_${suffix}"
        fi
        tmp_dir="${stage}/${backup_name}"
        if [ ! -e "$tmp_dir" ] && \
           [ ! -e "${output_dir}/${backup_name}.tar.gz" ] && \
           [ ! -e "${output_dir}/${backup_name}.tar.gz.enc" ]; then
            break
        fi
        suffix=$((suffix + 1))
    done
    mkdir -p "$tmp_dir"

    log_info "$(t backup_collecting)"

    # ── Единый источник правды ──
    [ -f "$CONFIG_FILE" ] && cp "$CONFIG_FILE" "$tmp_dir/config.json"
    [ -f "$USERS_FILE" ]  && cp "$USERS_FILE"  "$tmp_dir/users.json"
    # Доступы агентов и статистика. Без agents.json восстановление на чистом
    # сервере отваливало КАЖДЫЙ доступ MCP, и владелец узнавал об этом по отказу
    # у агента: состояние цепочек в state/ уезжало в архив, а сами записи —
    # нет. Живая приёмка это и поймала: файла не было ни в одном из пяти
    # архивов, а замысел в docs/MCP_ROTATION.md утверждал обратное.
    [ -f "$GOAMNEZIA_DIR/agents.json" ] && cp "$GOAMNEZIA_DIR/agents.json" "$tmp_dir/agents.json"
    [ -f "$GOAMNEZIA_DIR/stats.json" ]  && cp "$GOAMNEZIA_DIR/stats.json"  "$tmp_dir/stats.json"
    # Пароль панели. На сервере без бота это ЕДИНСТВЕННЫЙ вход с домена: без
    # него восстановление на чистой машине оставляло владельца без панели
    # вовсе, и завести пароль заново можно было только из SSH.
    if [ -f "${ADMIN_DIR:-/opt/goamnezia-admin}/password.json" ]; then
        mkdir -p "$tmp_dir/admin"
        cp "${ADMIN_DIR:-/opt/goamnezia-admin}/password.json" "$tmp_dir/admin/password.json" 2>/dev/null
    fi
    [ -f "${GOAMNEZIA_DIR}/.language" ] && cp "${GOAMNEZIA_DIR}/.language" "$tmp_dir/.language"
    [ -f "${GOAMNEZIA_DIR}/backup_schedule.json" ] && \
        cp "${GOAMNEZIA_DIR}/backup_schedule.json" "$tmp_dir/backup_schedule.json" 2>/dev/null
    # Подписки (lib/subs.sh, docs/SUBSCRIPTION.md): секреты постоянных ссылок. С ними после переезда на тот же домен
    # роутеры и Clash продолжают забирать ключи по прежним адресам; новых рисков нет — копия и так несёт users.json
    # с приватными ключами. Страницы подключения — нет: их дешевле выдать заново.
    local subs_dir="${GOAMNEZIA_SUBS_DIR:-$GOAMNEZIA_DIR/subs}"
    if [ -d "$subs_dir" ] && [ -n "$(ls -A "$subs_dir" 2>/dev/null)" ]; then
        cp -a "$subs_dir" "$tmp_dir/subs" 2>/dev/null
    fi

    # ── Копия состояния контейнеров ──
    # Здесь лежат awg0.conf, clientsTable, приватные ключи сервера и /opt/warp
    # соседа goWARP. Без этого каталога восстановление означало бы новые
    # серверные ключи и, значит, перевыпуск всех клиентских конфигов.
    # Цепочки одноразовых ключей агентов (state/agents/) в копию НЕ кладём, как и обещает MCP_ROTATION
    # §12.5: в них текущий ключ и сохранённый ответ последнего вызова (там бывает выданный конфиг), а
    # восстановленная цепочка откатывала бы перевыпуск к уже сожжённому ключу (SEC-C1). Раньше каталог
    # уезжал в архив целиком — код расходился с документом.
    if [ -d "$STATE_DIR" ] && [ -n "$(ls -A "$STATE_DIR" 2>/dev/null)" ]; then
        mkdir -p "$tmp_dir/state"
        local _st
        for _st in "$STATE_DIR"/* "$STATE_DIR"/.[!.]* "$STATE_DIR"/..?*; do
            [ -e "$_st" ] || continue
            [ "$(basename "$_st")" = agents ] && continue
            cp -a "$_st" "$tmp_dir/state/" 2>/dev/null
        done
        log_dim "$(t backup_state_included)"
    fi

    # ── nginx (Pro) ──
    local nginx_conf
    nginx_conf=$(_ga_backup_nginx_conf)
    _ga_backup_external_ok "$nginx_conf" && [ -f "$nginx_conf" ] && cp "$nginx_conf" "$tmp_dir/nginx.conf"

    # ── Сертификаты домена для переезда между VPS ──
    local domain le_dir
    domain=$(ga_config_get .domain 2>/dev/null)
    le_dir=$(_ga_backup_le_dir)
    if _ga_backup_external_ok "$le_dir" && [ -n "$domain" ] && [ -d "$le_dir/live/$domain" ]; then
        mkdir -p "$tmp_dir/letsencrypt/live" "$tmp_dir/letsencrypt/archive" "$tmp_dir/letsencrypt/renewal"
        cp -a "$le_dir/live/$domain" "$tmp_dir/letsencrypt/live/" 2>/dev/null
        [ -d "$le_dir/archive/$domain" ] && \
            cp -a "$le_dir/archive/$domain" "$tmp_dir/letsencrypt/archive/" 2>/dev/null
        [ -f "$le_dir/renewal/$domain.conf" ] && \
            cp -a "$le_dir/renewal/$domain.conf" "$tmp_dir/letsencrypt/renewal/" 2>/dev/null
        log_dim "$(t backup_ssl_included)"
    fi

    # ── Самоподписанный сертификат сайта (lite_site, PLAN §4.3) ──
    # Путь тот же, что у lib/website.sh (ga_site_tls_dir), но без зависимости
    # от модуля: бэкап по таймеру грузит только common/i18n/backup. Без этого
    # каталога восстановление на чистом сервере выпустило бы новый сертификат —
    # с новым отпечатком, который агентам MCP пришлось бы доверять заново.
    local tls_dir="${GOAMNEZIA_TLS_DIR:-$GOAMNEZIA_DIR/tls}"
    if [ -d "$tls_dir" ] && [ -n "$(ls -A "$tls_dir" 2>/dev/null)" ]; then
        mkdir -p "$tmp_dir/tls"
        cp -a "$tls_dir/." "$tmp_dir/tls/" 2>/dev/null
        log_dim "$(t backup_tls_included)"
    fi

    # ── Данные бота (.env содержит токен BotFather — шифрование настоятельно) ──
    # Код бота (bot.py, i18n.py) в архив НЕ кладём: бэкап не канал доставки кода,
    # а восстановление чужого архива не должно привозить исполняемое под root.
    if [ -d "$BOT_DIR" ]; then
        mkdir -p "$tmp_dir/bot"
        [ -f "$BOT_DIR/.env" ] && cp "$BOT_DIR/.env" "$tmp_dir/bot/.env" 2>/dev/null
        [ -f "$BOT_DIR/user_langs.json" ] && cp "$BOT_DIR/user_langs.json" "$tmp_dir/bot/user_langs.json" 2>/dev/null
        # Маркер .admin_claimed в копию больше не кладём (HB-8): с 0.4.7 его никто не читает — окно привязки
        # администратора открывают установщик и SSH сколько угодно раз, — а привезённый на новый сервер он
        # запирал бы запасной путь установщика без терминала у прежних версий.
    fi

    # ── Метаданные ──
    # Умолчания здесь — ложь: «mode: lite» на установке, чей config.json не
    # прочитан, делает архив неотличимым от нормальной копии Lite. Неизвестное
    # называем неизвестным («-»), а состояние источников кладём отдельными
    # полями: по ним видно, чему в этом архиве можно верить.
    local ip mode lang profiles cfg_state usr_state ver
    # Версия — та, чьё СОСТОЯНИЕ в архиве (config.json .version), а не версия кода, который снимает копию:
    # снимок перед обновлением делает уже новый код, и архив «до обновления» подписывался новой версией —
    # в списке копий его было не отличить от поздних (находка UP-8). Поля нет или файл не читается — версия кода.
    ver=$(ga_config_get .version 2>/dev/null); [[ "$ver" =~ ^[0-9][0-9A-Za-z.+-]{0,31}$ ]] || ver="$GOAMNEZIA_VERSION"
    ip=$(ga_config_get .server_ip 2>/dev/null); [ -n "$ip" ] || ip="-"
    mode=$(ga_config_get .mode 2>/dev/null); [ -n "$mode" ] || mode="-"
    lang=$(type get_language >/dev/null 2>&1 && get_language 2>/dev/null || echo "")
    [ -n "$lang" ] || lang="-"
    profiles=$(ga_config_get .profiles 2>/dev/null | jq -r 'keys | join(",")' 2>/dev/null)
    cfg_state=$(_ga_backup_state "$CONFIG_FILE")
    usr_state=$(_ga_backup_state "$USERS_FILE")

    # kind — чем снята копия: preupgrade — снимок перед миграцией на новую версию (GA_BACKUP_KIND); пусто — обычная.
    if ! jq -n \
        --arg bv "2" \
        --arg ver "$ver" \
        --arg code "$GOAMNEZIA_VERSION" \
        --arg kind "${GA_BACKUP_KIND:-}" \
        --arg created "$(ga_now)" \
        --arg host "$(hostname 2>/dev/null)" \
        --arg ip "$ip" \
        --arg mode "$mode" \
        --arg lang "$lang" \
        --arg domain "$domain" \
        --arg profiles "${profiles:-}" \
        --arg cfg "$cfg_state" \
        --arg usr "$usr_state" \
        '{backup_version:$bv, goamnezia_version:$ver, created_by:$code, created_at:$created,
          hostname:$host, ip:$ip, mode:$mode, language:$lang,
          domain:$domain, profiles:$profiles,
          sources:{config:$cfg, users:$usr}} + (if $kind != "" then {kind:$kind} else {} end)' > "$tmp_dir/metadata.json" 2>/dev/null; then
        # Архив без карточки — архив без паспорта: восстановление не покажет ни
        # версии, ни режима, ни состояния источников. Лучше отказ.
        log_error "$(t backup_archive_err)"
        rm -rf "$stage"
        return 1
    fi

    # ── Архивируем (в той же приватной песочнице, 0600 благодаря umask 077) ──
    local tar_file="${stage}/${backup_name}.tar.gz"
    if ! tar czf "$tar_file" -C "$stage" "$backup_name" 2>/dev/null; then
        log_error "$(t backup_archive_err)"
        rm -rf "$stage"
        return 1
    fi
    if [ ! -f "$tar_file" ]; then
        log_error "$(t backup_archive_missing)"
        rm -rf "$stage"
        return 1
    fi

    local final_file=""
    if [ -n "$password" ]; then
        final_file="${output_dir}/${backup_name}.tar.gz.enc"
        # Пароль — через файл (0600 благодаря umask 077), не через argv:
        # -pass pass:… читается любым локальным пользователем в /proc/*/cmdline.
        local pass_file="${stage}/.pass"
        printf '%s' "$password" > "$pass_file" || { rm -rf "$stage"; return 1; }
        if ! openssl enc -aes-256-cbc -salt -pbkdf2 -in "$tar_file" -out "$final_file" \
             -pass "file:${pass_file}" 2>/dev/null; then
            log_error "$(t backup_encrypt_err)"
            rm -f "$final_file"
            rm -rf "$stage"
            return 1
        fi
        # Незашифрованный tar и файл пароля не держим ни секунды дольше нужного
        rm -f "$tar_file" "$pass_file"
        log_success "$(t backup_encrypted)"
    else
        final_file="${output_dir}/${backup_name}.tar.gz"
        # /tmp и каталог бэкапов часто на разных ФС: mv здесь превращается в
        # копирование, и при ENOSPC остаётся обрезанный файл. Без проверки rc и
        # сверки суммы «успех» был бы фиктивным.
        local src_sum
        src_sum=$(sha256sum "$tar_file" 2>/dev/null | awk '{print $1}')
        if ! mv "$tar_file" "$final_file"; then
            log_error "$(t backup_archive_err)"
            rm -f "$final_file"; rm -rf "$stage"
            return 1
        fi
        if [ -n "$src_sum" ] && [ "$(sha256sum "$final_file" 2>/dev/null | awk '{print $1}')" != "$src_sum" ]; then
            log_error "$(t backup_archive_err)"
            rm -f "$final_file"; rm -rf "$stage"
            return 1
        fi
    fi

    # Только root: внутри приватные ключи пиров и токен бота
    chmod 600 "$final_file" 2>/dev/null || true
    sha256sum "$final_file" > "${final_file}.sha256" 2>/dev/null
    chmod 600 "${final_file}.sha256" 2>/dev/null || true

    rm -rf "$stage"

    local size
    size=$(du -h "$final_file" 2>/dev/null | cut -f1)
    # GA_BACKUP_QUIET=1 — копию снимает шаг, который сам назовёт её своими словами (снимок перед восстановлением,
    # перед миграцией): иначе на одно действие две строки об одном файле (находка LC-17).
    [ "${GA_BACKUP_QUIET:-0}" = 1 ] || log_success "$(tf backup_created_fmt "$final_file" "${size:-?}")"
    # Действующее лицо — GOAMNEZIA_WHO, как во всех остальных модулях: имени
    # GA_AUDIT_WHO не выставляет никто во всём продукте, и копия, снятая из
    # панели, бота или агентом, ложилась в журнал как «ssh», то есть от рук
    # владельца. Разбирать потом, кто запустил восстановление, было не по чему.
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "backup-create" "$final_file"
    # Результат — только путь: функцию зовут через $( )
    echo "$final_file"
    return 0
)

# ── Восстановление из бэкапа ─────────────────────────────────────────────────
# _restore_archive_intact <каталог распакованного архива> — 0, если архиву
# можно верить. Смотрим на сами файлы, а не на metadata.json: карточку пишет
# тот же процесс, что и файлы, и на сломанной установке она соврала бы вместе
# с ними. Проверка идёт ДО первой записи — после неё спасать уже нечего.
_restore_archive_intact() {
    local dir="${1:-}" f
    command -v jq >/dev/null 2>&1 || return 0
    # config.json — единственный источник правды установки. Архива без него не
    # бывает; если его нет, это обрезанный или чужой файл, а не наша копия.
    if [ ! -f "$dir/config.json" ]; then
        log_error "$(tf backup_archive_no_file "config.json")"
        log_error "$(t backup_archive_corrupt_howto)"
        _ga_backup_fail backup_corrupt "$(tf backup_archive_no_file "config.json")"
        return 1
    fi
    for f in config.json users.json; do
        [ -f "$dir/$f" ] || continue
        jq -e 'type == "object"' "$dir/$f" >/dev/null 2>&1 && continue
        # Называем ИМЕННО тот файл, который не разбирается: иначе человек ищет
        # причину в пароле, в диске и в чём угодно, кроме содержимого архива.
        log_error "$(tf backup_archive_corrupt "$f")"
        log_error "$(t backup_archive_corrupt_howto)"
        _ga_backup_fail backup_corrupt "$(tf backup_archive_corrupt "$f")"
        return 1
    done
    return 0
}

# _restore_snapshot — копия текущего состояния ДО первой записи. Без неё
# восстановление необратимо: первый же cp кладёт users.json из архива поверх
# живого, вместе с приватными ключами всех пиров.
# Снимаем в режиме allow_broken: живое состояние может быть уже сломано — за
# этим человек и пришёл восстанавливаться, и отказ здесь означал бы «спасать
# нечего». Архиву-снимку metadata.json честно скажет, что внутри.
_restore_snapshot() {
    # Терять нечего — и спасать нечего: чистый сервер, переезд из архива.
    if [ ! -f "$CONFIG_FILE" ] && [ ! -f "$USERS_FILE" ] && \
       { [ ! -d "$STATE_DIR" ] || [ -z "$(ls -A "$STATE_DIR" 2>/dev/null)" ]; }; then
        log_dim "$(t backup_snapshot_skipped)"
        return 0
    fi
    local snap=""
    # ga_capture, а не $( ): код low_disk из подоболочки не доходил, и бот с панелью получали
    # безликое «не удалось снять копию» вместо «места нет» (SR-25).
    GA_ERR_CODE=""; GA_ERR_MSG=""
    GA_BACKUP_QUIET=1 ga_capture snap create_backup "" "$BACKUP_DIR" 1 || snap=""
    snap=$(printf '%s' "$snap" | tail -n 1)
    if [ -z "$snap" ] || [ ! -f "$snap" ]; then
        log_error "$(t backup_snapshot_failed)"
        if [ "${GA_ERR_CODE:-}" = low_disk ]; then
            _ga_backup_fail low_disk "${GA_ERR_MSG} — $(t backup_snapshot_failed)"
        else
            _ga_backup_fail backup_snapshot_failed "$(t backup_snapshot_failed)"
        fi
        return 1
    fi
    log_success "$(tf backup_snapshot_made "$snap")"
    return 0
}

# _restore_wipe_tmp <каталог> — убрать распакованный архив НАСОВСЕМ.
# Внутри каталога лежат users.json с приватными ключами всех клиентов,
# приватный ключ сервера из state/, приватный ключ сертификата и .env с токеном
# бота. `rm -rf` снимает только имя, содержимое остаётся в блоках; договор §0.7
# написан ровно про такие файлы — каталог в памяти и затирание нулями.
_restore_wipe_tmp() {
    local d="${1:-}"
    [ -n "$d" ] && [ -d "$d" ] || return 0
    if type ga_wipe_dir >/dev/null 2>&1; then
        ga_wipe_dir "$d"
    else
        rm -rf "$d"
    fi
    return 0
}

# _restore_abort <каталог> — единственный выход из сорвавшегося восстановления
# ПОСЛЕ того, как службы остановлены. Раньше обе ветки отказа копирования
# уходили голым `return 1`: бот и панель оставались выключенными (человек терял
# и данные, и управление разом), а распакованный архив со всеми ключами —
# лежать в общем каталоге временных файлов. Теперь обе вещи делаются в одном
# месте, и забыть их в новой ветке нельзя.
_restore_abort() {
    local tmp_dir="${1:-}" _f
    # Живые config.json и users.json на место: запись могла сорваться после того, как один из них уже
    # приехал из копии, и сервер остался бы наполовину из копии, наполовину живым (SR-29). Код и слова
    # исходного отказа сохраняем — откат не должен их подменять.
    local _code="${GA_ERR_CODE:-}" _msg="${GA_ERR_MSG:-}" _last="${GA_LAST_ERROR_CODE:-}"
    for _f in config.json users.json; do
        [ -f "$tmp_dir/.live/$_f" ] || continue
        case "$_f" in
            config.json) ga_put_json_file "$tmp_dir/.live/$_f" "$CONFIG_FILE" >/dev/null 2>&1 || true ;;
            users.json)  ga_put_json_file "$tmp_dir/.live/$_f" "$USERS_FILE" >/dev/null 2>&1 || true ;;
        esac
    done
    [ -d "$tmp_dir/.live" ] && log_warning "$(t backup_restore_rolled_back)"
    GA_ERR_CODE="$_code"; GA_ERR_MSG="$_msg"; GA_LAST_ERROR_CODE="$_last"
    # ── Контейнеры ──────────────────────────────────────────────────────────
    # Восстановление возвращало ДАННЫЕ, но не поднимало контейнеры: на чистом
    # сервере после него не работало ничего, и об этом не говорилось ни слова.
    # Всё нужное для подъёма уже здесь — state/ с ключами сервера и awg0.conf,
    # и закреплённый образ в config.json; ключи при этом НЕ перевыпускаются.
    local _p _cont _up=0 _fail=0
    if type ga_profiles_installed >/dev/null 2>&1 && type amnezia_state_restore >/dev/null 2>&1; then
        for _p in $(ga_profiles_installed 2>/dev/null); do
            _cont=$(ga_profile_field "$_p" container 2>/dev/null) || _cont=""
            [ -n "$_cont" ] || continue
            # Уже работает — не трогаем: перезапуск рвал бы связь без нужды.
            if type docker_container_state >/dev/null 2>&1 &&
               [ "$(docker_container_state "$_cont" 2>/dev/null)" = running ]; then
                continue
            fi
            if amnezia_state_restore "$_p" >/dev/null 2>&1; then
                _up=$((_up + 1))
            else
                _fail=$((_fail + 1))
                log_warning "$(tf backup_container_manual "$_p")"
            fi
        done
    fi
    [ "$_up" -gt 0 ] && log_success "$(tf backup_containers_up "$_up")"

    _ga_backup_systemctl start "$BOT_SERVICE" || true
    _ga_backup_systemctl start "$ADMIN_SERVICE" || true
    if [ "${GA_RESTORE_MCP_WAS_ACTIVE:-0}" = 1 ]; then
        _ga_backup_systemctl start "$(_ga_restore_mcp_unit)" || true
    fi
    _restore_wipe_tmp "$tmp_dir"
    trap - TERM HUP INT
    return 1
}

# Юнит HTTP-транспорта MCP (lib/agents.sh; модуль при восстановлении может быть не загружен).
_ga_restore_mcp_unit() { printf '%s' "${GA_AGENTS_UNIT:-goamnezia-mcp-http.service}"; }

# _restore_wipe_layout <каталог распакованного архива> — каталог продукта внутри архива «Удалить всё»
# (tar каталога /opt/goamnezia целиком, с путём от корня). Пусто и код 1 — это не архив сноса. Имена внутри
# те же, что в копии (config.json, users.json, state/, agents.json, tls/…), поэтому дальше он
# восстанавливается общим путём; бота, панели и сертификатов в нём нет — снос их не архивировал.
_restore_wipe_layout() {
    local tmp="${1:-}" d
    for d in "$tmp/${GOAMNEZIA_DIR#/}" "$tmp/opt/goamnezia"; do
        [ -f "$d/config.json" ] || continue
        printf '%s' "$d"
        return 0
    done
    return 1
}

# _restore_server_ip_check — сразу после восстановления сверить адрес сервера. Копия несёт server_ip (и
# вписанный в ключи адрес) СТАРОЙ машины, а часовая проверка сторожа дошла бы до них не раньше чем через час:
# всё это время новые ключи уходили бы на прежний адрес (находка SR-45). Результат — в GA_RESTORE_IP_JSON
# для ответа моста. Стенд в сеть не ходит: без GOAMNEZIA_SERVER_IP проверка пропускается.
GA_RESTORE_IP_JSON=""
_restore_server_ip_check() {
    GA_RESTORE_IP_JSON=""
    type amnezia_server_ip_check >/dev/null 2>&1 || return 0
    if type ga_dry >/dev/null 2>&1 && ga_dry && [ -z "${GOAMNEZIA_SERVER_IP:-}" ]; then return 0; fi
    GA_RESTORE_IP_JSON=$(amnezia_server_ip_check) || GA_RESTORE_IP_JSON=""
    # Сторож не повторяет проверку на ближайшем тике: адрес только что сверен.
    type ga_amn_watch_remember >/dev/null 2>&1 && ga_amn_watch_remember ip probe
    return 0
}

# _restore_kept <что> — запомнить, что восстановление оставило действующим (bot, panel_password, agents):
# мост отдаёт список полем kept_current, SSH говорит строкой на каждое.
_restore_kept() {
    case " ${GA_RESTORE_KEPT:-} " in *" $1 "*) ;; *) GA_RESTORE_KEPT="${GA_RESTORE_KEPT:+$GA_RESTORE_KEPT }$1" ;; esac
}

# _restore_agents_merge <agents.json из копии> — доступы агентов после восстановления.
# Копия снята раньше, чем владелец отозвал, перевыпустил или заморозил доступ, — и прежде она клала свой
# agents.json поверх действующего: отозванный доступ снова впускал, перевыпущенный принимал прежний
# секрет и токен, замороженный клон размораживался (находка аудита безопасности SEC-C1, 25.09.2026).
#   • доступов на сервере ещё не было (файла нет: чистый сервер, переезд) — берём из копии как есть;
#   • действующий файл цел — он и остаётся: каждый доступ в нём новее копии, а доступа, которого в нём
#     нет, владелец удалил (или копия с другого сервера) — такой не возвращаем, а называем;
#   • действующий файл не читается — что удалено после копии, не узнать: доступы из копии возвращаются
#     ВЫКЛЮЧЕННЫМИ, включает их владелец сам.
_restore_agents_merge() {
    local arch="${1:-}" live doc
    live="${GOAMNEZIA_AGENTS_JSON:-$GOAMNEZIA_DIR/agents.json}"
    command -v jq >/dev/null 2>&1 || return 0
    if ! jq -e '(.agents | type) == "array"' "$arch" >/dev/null 2>&1; then
        log_warning "$(t backup_agents_archive_bad)"
        return 0
    fi
    if [ ! -e "$live" ]; then
        if ga_put_json_file "$arch" "$live"; then
            chmod 600 "$live" 2>/dev/null || true
            log_success "$(t backup_restored_agents)"
        fi
        return 0
    fi
    if ! jq -e '(.agents | type) == "array"' "$live" >/dev/null 2>&1; then
        type _ga_json_rescue >/dev/null 2>&1 && _ga_json_rescue "$live" >/dev/null 2>&1
        doc=$(jq -c '.agents |= map(.enabled = false)' "$arch" 2>/dev/null) || return 0
        if _ga_write_json "$live" <<<"$doc"; then
            chmod 600 "$live" 2>/dev/null || true
            log_warning "$(t backup_agents_restored_disabled)"
        fi
        return 0
    fi
    _restore_kept agents
    GA_RESTORE_AGENTS_DROPPED=$(jq -r --slurpfile L "$live" \
        '([.agents[]?.id // empty] - [$L[0].agents[]?.id // empty]) | join(" ")' "$arch" 2>/dev/null) || GA_RESTORE_AGENTS_DROPPED=""
    log_info "$(t backup_kept_agents)"
    if [ -n "$GA_RESTORE_AGENTS_DROPPED" ]; then
        log_warning "$(tf backup_agents_not_resurrected "$(printf '%s' "$GA_RESTORE_AGENTS_DROPPED" | sed 's/ /, /g')")"
    fi
    return 0
}

# _restore_subs_merge <каталог subs/ из копии> — подписки после восстановления (lib/subs.sh). Правило — как у
# доступов агентов (SEC-C1): копия снята раньше, чем владелец перевыпустил или отозвал подписку, и поверх действующих
# она вернула бы утёкший адрес.
#   • подписок на сервере ещё не было (каталога нет: чистый сервер, переезд) — берём из копии как есть: роутеры и
#     Clash забирают ключи по прежним адресам, как только сайт встанет на тот же домен (обвязку включит тик);
#   • каталог есть — действующие подписки остаются как есть: каждая новее копии, а отозванную копия не воскрешает.
# Подписка человека, которого в восстановленном users.json нет (или под его именем другой человек), снимется
# сторожем тика (owner_gone) — ключей по ней не выдаст и служба.
_restore_subs_merge() {
    local arch="${1:-}" live
    [ -d "$arch" ] || return 0
    live="${GOAMNEZIA_SUBS_DIR:-$GOAMNEZIA_DIR/subs}"
    if [ -e "$live" ]; then
        _restore_kept subs
        log_info "$(t backup_kept_subs)"
        return 0
    fi
    if ! cp -a "$arch" "$live" 2>/dev/null; then
        log_warning "$(tf backup_restore_write_failed "$live")"
        return 0
    fi
    # tar распакован с --no-same-permissions: секреты — снова 0600, каталоги — 0700.
    find "$live" -type d -exec chmod 700 {} + 2>/dev/null || true
    find "$live" -type f -exec chmod 600 {} + 2>/dev/null || true
    log_success "$(t backup_restored_subs)"
    return 0
}

# _restore_wipe_inner_backups <каталог продукта из архива сноса> — копии, лежавшие в каталоге бэкапов на
# момент сноса, возвращаются туда же: снос унёс их вместе с каталогом продукта. Уже лежащие не трогаем.
_restore_wipe_inner_backups() {
    local src="${1:-}/backups" f name n=0
    [ -d "$src" ] || return 0
    mkdir -p "$BACKUP_DIR" 2>/dev/null && chmod 700 "$BACKUP_DIR" 2>/dev/null
    for f in "$src"/goamnezia_backup_*.tar.gz "$src"/goamnezia_backup_*.tar.gz.enc; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        [ -e "$BACKUP_DIR/$name" ] && continue
        cp "$f" "$BACKUP_DIR/$name" 2>/dev/null || continue
        [ -f "$f.sha256" ] && cp "$f.sha256" "$BACKUP_DIR/$name.sha256" 2>/dev/null
        chmod 600 "$BACKUP_DIR/$name" "$BACKUP_DIR/$name.sha256" 2>/dev/null
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] && log_success "$(tf backup_restored_inner_backups "$n" "$BACKUP_DIR")"
    return 0
}

# Обрыв посреди восстановления — бот и панель убивают вызов по таймауту (600 с, а пересборка образа при
# недоступном CDN длится дольше), обрывается SSH. Раньше после сигнала бот, панель и MCP оставались
# остановленными до ручного захода по SSH, а распакованный архив — users.json со всеми приватными
# ключами — лежал в /dev/shm до перезагрузки (находка SR-24). Ловушка поднимает службы и затирает архив.
GA_RESTORE_TMP=""
_restore_on_signal() {
    trap - TERM HUP INT
    _ga_backup_systemctl start "$BOT_SERVICE" || true
    _ga_backup_systemctl start "$ADMIN_SERVICE" || true
    if [ "${GA_RESTORE_MCP_WAS_ACTIVE:-0}" = 1 ]; then
        _ga_backup_systemctl start "$(_ga_restore_mcp_unit)" || true
    fi
    _restore_wipe_tmp "${GA_RESTORE_TMP:-}"
    exit 143
}

# _ga_restore_in_unit <юнит> — идёт ли текущий процесс внутри этого юнита systemd (его control group). Путь к
# файлу cgroup подменяется для проверок (GA_PROC_CGROUP); файла нет (не Linux) — не внутри.
_ga_restore_in_unit() {
    if type ga_in_unit >/dev/null 2>&1; then ga_in_unit "$@"; return $?; fi
    local unit="${1:-}" f="${GA_PROC_CGROUP:-/proc/self/cgroup}"
    [ -n "$unit" ] && [ -r "$f" ] || return 1
    unit="${unit%.service}.service"
    grep -qE "/${unit//./\\.}(/|$)" "$f" 2>/dev/null
}

# _restore_drop_unlisted_profiles <профили до восстановления, JSON> — профиль, которого нет в архиве, но который
# работал до восстановления: его контейнер обслуживал бы пиров, о которых продукт больше не знает, — ни удалить
# пользователя, ни применить лимит. Снимаем контейнер и копию состояния; ключи остались в снимке перед
# восстановлением.
_restore_drop_unlisted_profiles() {
    local live="${1:-}" p c
    [ -n "$live" ] && [ "$live" != '{}' ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    while IFS=$'\t' read -r p c; do
        [ -n "$p" ] && [ -n "$c" ] || continue
        # Сверяем КОНТЕЙНЕР, а не имя профиля: в копии awg1 мог жить в другом контейнере (подхваченный
        # amnezia-awg), и живой amnezia-awg1 с пирами оставался работать без управления (находка SR-29).
        # Поля container у профиля старой копии может не быть — тогда имя по умолчанию (amnezia-<профиль>).
        jq -e --arg c "$c" '[(.profiles // {}) | to_entries[] | (.value.container // ("amnezia-" + .key))] | index($c) != null' \
            "$CONFIG_FILE" >/dev/null 2>&1 && continue
        [[ "$c" =~ ^amnezia-[a-z0-9-]{2,32}$ ]] || continue
        # Демон не отвечает или контейнер не снялся — ничего не трогаем: снятая копия состояния при живом
        # контейнере и есть «пиры без управления», ради которых эта уборка заведена.
        if type docker_container_state >/dev/null 2>&1 \
                && [ "$(docker_container_state "$c" 2>/dev/null)" = "${GA_DOCKER_STATE_UNREACHABLE:-docker_unreachable}" ]; then
            log_warning "$(tf backup_profile_drop_skipped "$p" "$c")"
            continue
        fi
        if type docker_rm >/dev/null 2>&1 && ! docker_rm "$c"; then
            log_warning "$(tf backup_profile_drop_skipped "$p" "$c")"
            continue
        fi
        log_warning "$(tf backup_profile_dropped "$p" "$c")"
        rm -rf "${STATE_DIR:?}/$c"
    done < <(jq -r 'to_entries[] | select((.value.container // "") != "") | "\(.key)\t\(.value.container)"' <<<"$live" 2>/dev/null)
    return 0
}

# _restore_site_template — сайт-заглушка по записи архива. Файлов сайта в архиве нет (ради размера),
# и после восстановления на диске оставался шаблон, поставленный уже ПОСЛЕ бэкапа, а на чистом
# сервере — пустой корень, при том что config.json и status называли шаблон из архива (находка
# LS-12, 25.09.2026). Шаблон каталога разворачиваем заново; свой по git URL так не развернуть — говорим,
# где это сделать.
_restore_site_template() {
    local tid root cur
    tid=$(jq -r '.site.template_id // ""' "$CONFIG_FILE" 2>/dev/null) || return 0
    [ -n "$tid" ] || return 0
    type ga_site_root >/dev/null 2>&1 || return 0
    root=$(ga_site_root)
    cur=$(head -n 1 "$root/.goamnezia_template_id" 2>/dev/null) || cur=""
    [ "$cur" = "$tid" ] && [ -f "$root/index.html" ] && return 0
    case "$tid" in
        custom_*)
            log_warning "$(tf backup_restore_site_custom "$tid")"
            ;;
        *)
            if type website_deploy_template >/dev/null 2>&1 && website_deploy_template "$tid" >/dev/null 2>&1; then
                log_success "$(tf backup_restore_site_redeployed "$tid")"
            else
                log_warning "$(tf backup_restore_site_failed "$tid")"
            fi
            ;;
    esac
    return 0
}

# _restore_converge_mode — режим архива и то, что стоит на сервере, могли разойтись (переезд из pro на чистую
# lite-установку и обратно). Сайт, которого по архиву нет, снимаем: это локально и без сети. Режим с сайтом, для
# которого на сервере нет nginx, сами не поднимаем (установка пакетов, выпуск сертификата), а говорим, что
# сделать, — в ответе моста (mode_hint) и на экране.
_restore_converge_mode() {
    local arch_mode
    GA_RESTORE_MODE_HINT=""
    command -v jq >/dev/null 2>&1 || return 0
    arch_mode=$(jq -r '.mode // "lite"' "$CONFIG_FILE" 2>/dev/null) || return 0
    case "$arch_mode" in
        pro|lite_site)
            if ! command -v nginx >/dev/null 2>&1; then
                # Человеку — название режима, а не код из config.json («в режиме
                # lite_site» — находка T3, 25.09.2026). Ключи буквально: их видит
                # tests/check_i18n_ssh.py.
                local mode_label
                if [ "$arch_mode" = pro ]; then mode_label="$(t ms_mode_name_pro)"; else mode_label="$(t ms_mode_name_lite_site)"; fi
                GA_RESTORE_MODE_HINT="$(tf backup_restore_mode_hint "«${mode_label}»")"
                log_warning "$GA_RESTORE_MODE_HINT"
            else
                _restore_site_template
            fi
            ;;
        *)
            if [ -f "$NGINX_SITE_CONF" ] && type website_disable_site >/dev/null 2>&1; then
                log_info "$(t backup_restore_site_off)"
                website_disable_site >/dev/null 2>&1 || true
            fi
            ;;
    esac
    return 0
}

restore_backup() {
    local backup_file="$1"
    # ${2:-}/${3:-} обязательны: interactive_restore зовёт с одним аргументом,
    # под set -u голый $2 ронял бы весь install.sh.
    local password="${2:-}"
    local assume_yes="${3:-}"

    if [ ! -f "$backup_file" ]; then
        ga_set_error backup_not_found
        log_error "$(tf backup_file_not_found_fmt "$backup_file")"
        return 1
    fi

    # Место — до распаковки. Восстановление разворачивает архив целиком во
    # временный каталог и только потом раскладывает файлы: на забитом диске оно
    # обрывалось посередине, и человек получал английскую ошибку tar вместо
    # честного «места нет» — а это ровно та беда, из которой восстановление и
    # должно вытаскивать.
    # Восстановлению столько места на ДИСКЕ больше не нужно: распаковка переехала
    # в ga_mktemp_secret_dir, то есть в память (договор §0.7), и обоснование
    # «оно распаковывает архив целиком» отменено этой же правкой. Требовать
    # полгигабайта на корне значило отказывать ровно в той аварии, из которой
    # восстановление и вытаскивает: диск забился, конфиг обрезался, человек
    # делает то, что советует каждый экран, и получает low_disk.
    #
    # Проверяем не корень, а то, куда пишем, и ровно столько, сколько ляжет на
    # диск: сами восстановленные файлы. Их размер известен — это архив.
    if type check_disk_space >/dev/null 2>&1; then
        local _need_mb
        # 2>/dev/null ПЕРЕД перенаправлением: иначе неудачу открытия файла
        # печатает сама оболочка, и подавление у команды её не гасит.
        _need_mb=$(( $(wc -c 2>/dev/null <"$backup_file" || echo 0) / 1048576 + 32 ))
        [ "$_need_mb" -lt 32 ] && _need_mb=32
        if ! check_disk_space "$_need_mb" "$GOAMNEZIA_DIR"; then
            GA_ERR_CODE=low_disk
            GA_ERR_MSG="$(tf backup_err_low_disk "$_need_mb")"
            ga_set_error low_disk
            return 1
        fi
    fi

    # Целостность: если рядом лежит .sha256 — сверяем ДО распаковки
    if [ -f "${backup_file}.sha256" ] && command -v sha256sum >/dev/null 2>&1; then
        local want_sum got_sum
        want_sum=$(grep -oiE '[0-9a-fA-F]{64}' "${backup_file}.sha256" 2>/dev/null | head -1 | tr 'A-F' 'a-f')
        got_sum=$(sha256sum "$backup_file" 2>/dev/null | awk '{print tolower($1)}')
        if [ -n "$want_sum" ] && [ "$want_sum" != "$got_sum" ]; then
            ga_set_error backup_corrupt
            log_error "$(t backup_sha_mismatch)"
            log_dim "$(tf backup_sha_expected "$want_sum")"
            log_dim "$(tf backup_sha_got "${got_sum:-—}")"
            return 1
        fi
        [ -n "$want_sum" ] && log_dim "$(t backup_sha_ok)"
    fi

    # mktemp: фиксированный /tmp/goamnezia_restore_$$ предсказуем — локальный
    # пользователь мог подложить симлинк и подставить root'у произвольный путь.
    # Каталог — секретный (ga_mktemp_secret_dir, договор §0.7): сюда
    # распаковывается архив с приватными ключами ВСЕХ клиентов, ключом сервера и
    # токеном бота, и на tmpfs это содержимое вообще не доезжает до носителя.
    local tmp_dir
    if type ga_mktemp_secret_dir >/dev/null 2>&1; then
        tmp_dir=$(ga_mktemp_secret_dir garestore) || return 1
    else
        tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/goamnezia_restore.XXXXXXXX") || return 1
    fi
    chmod 700 "$tmp_dir" 2>/dev/null || true

    local tar_file=""
    case "$backup_file" in
        *.enc)
            if [ -z "$password" ]; then
                # Бот, панель и агент зовут мост без терминала (stdin — /dev/null): спросить пароль
                # некому, и раньше человек получал «неверный пароль», хотя его не спрашивали
                # (находка SR-26, 25.09.2026). Честный отказ с путём: зашифрованный архив — в SSH.
                if [ ! -t 0 ]; then
                    ga_err backup_encrypted_needs_ssh "$(t backup_encrypted_needs_ssh)"
                    _restore_wipe_tmp "$tmp_dir"
                    return 1
                fi
                echo -ne "  $(t backup_enter_pass): " >&2
                read -rs password
                echo "" >&2
            fi
            tar_file=$(mktemp "${tmp_dir}/restore.XXXXXXXX.tar.gz") || { _restore_wipe_tmp "$tmp_dir"; return 1; }
            # Пароль через файл (mktemp даёт 0600), не через argv: иначе он виден
            # в ps всё время расшифровки.
            local pass_file
            pass_file=$(mktemp "${tmp_dir}/.pass.XXXXXXXX") || { _restore_wipe_tmp "$tmp_dir"; return 1; }
            printf '%s' "$password" > "$pass_file"
            if ! openssl enc -aes-256-cbc -d -pbkdf2 -in "$backup_file" -out "$tar_file" \
                 -pass "file:${pass_file}" 2>/dev/null; then
                ga_set_error backup_bad_password
                log_error "$(t backup_bad_pass)"
                _restore_wipe_tmp "$tmp_dir"
                return 1
            fi
            # Пароль тоже затираем, а не просто удаляем (тот же §0.7); страж
            # `type` — как в _restore_wipe_tmp: модуль обязан работать и там,
            # где lib/common.sh урезан.
            if type ga_wipe_file >/dev/null 2>&1; then ga_wipe_file "$pass_file"; else rm -f "$pass_file"; fi
            ;;
        *)
            tar_file="$backup_file"
            ;;
    esac

    # Архив может быть присланным «чужим», а разворачиваем мы его от root:
    # --no-same-owner/--no-same-permissions не дают внести в систему setuid-root
    # файлы и чужих владельцев.
    if ! tar xzf "$tar_file" -C "$tmp_dir" --no-same-owner --no-same-permissions 2>/dev/null; then
        ga_set_error backup_extract_failed
        log_error "$(t backup_extract_err)"
        _restore_wipe_tmp "$tmp_dir"
        return 1
    fi

    local backup_dir
    GA_RESTORE_WIPE=0
    backup_dir=$(find "$tmp_dir" -maxdepth 1 -type d -name "goamnezia_backup_*" 2>/dev/null | head -1)
    if [ -z "$backup_dir" ] && [ ! -f "$tmp_dir/config.json" ] && backup_dir=$(_restore_wipe_layout "$tmp_dir"); then
        GA_RESTORE_WIPE=1
    fi
    [ -z "$backup_dir" ] && backup_dir="$tmp_dir"

    # Первым делом — пригодность архива, и только потом карточка и вопрос
    # человеку: спрашивать согласие на заведомо невозможное восстановление
    # значит подвести его к «успеху» на пустом месте.
    if ! _restore_archive_intact "$backup_dir"; then
        _restore_wipe_tmp "$tmp_dir"
        return 1
    fi

    if [ -f "$backup_dir/metadata.json" ] && command -v jq >/dev/null 2>&1; then
        local bk_version bk_mode bk_ip bk_lang bk_date bk_src
        bk_version=$(jq -r '.goamnezia_version // "-"' "$backup_dir/metadata.json")
        bk_mode=$(jq -r '.mode // "-"' "$backup_dir/metadata.json")
        bk_ip=$(jq -r '.ip // "-"' "$backup_dir/metadata.json")
        bk_lang=$(jq -r '.language // "-"' "$backup_dir/metadata.json")
        bk_date=$(jq -r '.created_at // "-"' "$backup_dir/metadata.json")
        # Снимок перед восстановлением снимается и с поломанного состояния —
        # карточка обязана это показать, иначе такой архив снова выдадут за
        # обычную копию.
        bk_src=$(jq -r '[(.sources.config // "?"), (.sources.users // "?")] | join("/")' "$backup_dir/metadata.json")
        echo "" >&2
        echo -e "  ${BOLD}${WHITE}📦 $(t backup_label):${NC}" >&2
        echo -e "  $(t backup_version_label): $bk_version | $(t backup_mode_label): $bk_mode | IP: $bk_ip | $(t backup_lang_label): $bk_lang" >&2
        # Дата копии — как везде на экране: «2 ч назад (… по времени сервера)», а не сырой ISO (NC-11)
        type ga_human_ts >/dev/null 2>&1 && [ "$bk_date" != "-" ] && bk_date=$(ga_human_ts "$bk_date")
        echo -e "  $(t backup_date_label): $bk_date" >&2
        [ "$bk_src" = "ok/ok" ] || echo -e "  $(tf backup_sources_label "$bk_src")" >&2
        echo "" >&2
    elif [ "$GA_RESTORE_WIPE" = 1 ]; then
        # Карточки у архива сноса нет — говорим, что он такое и чего в нём нет, до вопроса о восстановлении.
        echo "" >&2
        echo -e "  ${BOLD}${WHITE}📦 $(t backup_label):${NC}" >&2
        echo -e "  $(ga_win_wrap "$(t backup_wipe_archive_card)" 2)" >&2
        echo "" >&2
    fi

    # Самое разрушительное действие продукта — подтверждение набором слова, как у удаления и
    # сноса, а не одной цифрой (находка LS-13, 25.09.2026; бот и панель уже просят фразу).
    local _ok=0 _said=0
    if [ "$assume_yes" = "yes" ]; then
        _ok=1
    elif type confirm_phrase >/dev/null 2>&1; then
        # confirm_phrase сам говорит об отказе одной строкой (LH-3)
        confirm_phrase "$(t backup_restore_phrase)" "$(t backup_confirm_restore)" && _ok=1
        _said=1
    else
        confirm "$(t backup_confirm_restore)" && _ok=1
    fi
    if [ "$_ok" != 1 ]; then
        _restore_wipe_tmp "$tmp_dir"
        [ "$_said" = 1 ] || log_info "$(t cancelled)"
        return 0
    fi

    # Вся фаза записи — под общим замком конфигурации. Таймер лимитов и HTTP-транспорт MCP читают и целиком
    # переписывают users.json, и запись восстановления, попавшая между их чтением и записью, откатывалась бы к
    # состоянию до восстановления — при ответе «успешно». Замок реентрантный: модули внутри берут его сами.
    local apply_rc=0
    ga_with_config_lock _restore_apply_locked "$backup_file" "$tmp_dir" "$backup_dir" || apply_rc=$?
    # Замок не взялся (lock_timeout) — фаза записи не началась, а распакованный архив с ключами всех клиентов,
    # ключом сервера и токеном бота остался бы в памяти до перезагрузки (договор §0.7). Внутри фазы архив
    # затирается сам; повторное затирание пустого каталога безвредно.
    if [ "$apply_rc" != 0 ]; then
        _restore_wipe_tmp "$tmp_dir"
    fi
    return "$apply_rc"
}

# _restore_state_conf_canon <каталог контейнера в архиве> <он же в state/> — копия конфига в state/
# называется awg0.conf (находка ACC-4). В архивах прежних версий у подхваченного legacy-контейнера
# (amnezia-awg, wg0) она лежит под wg0.conf, а cp -a кладёт архив ПОВЕРХ живого каталога: живая awg0.conf
# оставалась рядом, и профиль поднимался бы с конфигом «после копии» — с людьми, которых восстановленный
# users.json уже не знает. Побеждает конфиг архива: его wg<N>.conf становится awg0.conf, дублей прежнего
# имени не остаётся. Без lib/amnezia.sh: имя интерфейса здесь не спросить, берём любое wg<N>.conf.
_restore_state_conf_canon() {
    local src="${1:-}" dst="${2:-}" f
    [ -d "$src" ] && [ -d "$dst" ] || return 0
    if [ ! -f "$src/awg0.conf" ]; then
        for f in "$src"/wg[0-9].conf; do
            [ -f "$f" ] || continue
            # Живую awg0.conf убираем и тогда, когда переименование не выйдет: лучше честный отказ
            # state_missing при подъёме, чем профиль с людьми, которых восстановление убрало.
            rm -f "$dst/awg0.conf"
            mv -f "$dst/${f##*/}" "$dst/awg0.conf" 2>/dev/null && chmod 600 "$dst/awg0.conf" 2>/dev/null
            break
        done
    fi
    [ -f "$dst/awg0.conf" ] && rm -f "$dst"/wg[0-9].conf 2>/dev/null
    return 0
}

# Фаза записи восстановления (зовётся из restore_backup под замком конфигурации).
_restore_apply_locked() {
    local backup_file="$1" tmp_dir="$2" backup_dir="$3"
    # Профили, что работали ДО восстановления: тех из них, которых нет в архиве, снимаем ниже.
    local live_profiles='{}'
    if command -v jq >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
        live_profiles=$(jq -c '.profiles // {}' "$CONFIG_FILE" 2>/dev/null) || live_profiles='{}'
    fi
    [ -n "$live_profiles" ] || live_profiles='{}'

    # Снимок текущего состояния — строго до первой записи и до остановки служб.
    # Не удалось снять — не восстанавливаем: перезапись без обратного пути
    # стоила бы приватных ключей всех пиров.
    if ! _restore_snapshot; then
        _restore_wipe_tmp "$tmp_dir"
        return 1
    fi

    # Останавливаем то, что читает конфиги. Контейнеры не трогаем здесь:
    # их пересоздаст amnezia_state_restore из восстановленного state/.
    # Службу, ВНУТРИ которой идёт само восстановление (его позвали бот, панель или агент по HTTP), не
    # останавливаем: systemctl stop убивает все процессы юнита, и восстановление обрывалось посередине — с
    # остановленными службами и незатёртым архивом. Её обращения к мосту и так ждут общего замка.
    GA_RESTORE_TMP="$tmp_dir"
    trap '_restore_on_signal' TERM HUP INT
    # Все вызовы systemctl восстановления — через _ga_backup_systemctl: в сухом прогоне это строка DRY, а не
    # остановка и запуск бота и панели машины, где идёт прогон (находка L1-20: под root на Linux тесты дёргали
    # живые службы десятки раз, и start-limit-hit мог оставить их остановленными).
    _ga_restore_in_unit "$BOT_SERVICE" || _ga_backup_systemctl stop "$BOT_SERVICE" || true
    _ga_restore_in_unit "$ADMIN_SERVICE" || _ga_backup_systemctl stop "$ADMIN_SERVICE" || true
    # HTTP-транспорт MCP тоже меняет данные через мост: на время записи останавливаем и поднимаем обратно,
    # только если он работал.
    GA_RESTORE_MCP_WAS_ACTIVE=0
    if ! _ga_restore_in_unit "$(_ga_restore_mcp_unit)" \
            && _ga_backup_systemctl is-active --quiet "$(_ga_restore_mcp_unit)"; then
        GA_RESTORE_MCP_WAS_ACTIVE=1
        _ga_backup_systemctl stop "$(_ga_restore_mcp_unit)" || true
    fi

    mkdir -p "$GOAMNEZIA_DIR" 2>/dev/null
    GA_RESTORE_KEPT=""; GA_RESTORE_AGENTS_DROPPED=""

    # Живые config.json и users.json — рядом с распакованным архивом (каталог в памяти, затирается вместе с
    # ним): сорвись запись users.json после config.json, прежде оставался config.json из копии (порт архива)
    # при контейнере на живом порту, и новые ключи уходили на неверный порт (находка SR-29). Теперь отказ
    # записи возвращает оба файла такими, какими они были (_restore_abort).
    mkdir -p "$tmp_dir/.live" 2>/dev/null && chmod 700 "$tmp_dir/.live" 2>/dev/null
    [ -f "$CONFIG_FILE" ] && cp -p "$CONFIG_FILE" "$tmp_dir/.live/config.json" 2>/dev/null
    [ -f "$USERS_FILE" ] && cp -p "$USERS_FILE" "$tmp_dir/.live/users.json" 2>/dev/null

    # Отказ записи (нет места, права, только-чтение) не должен уходить в
    # «успех»: без config.json или users.json установка не работает, а человек
    # считал бы, что всё вернулось.
    #
    # Кладём НЕ голым cp: он сначала обрезает цель, и сбой на середине оставлял
    # бы обрезанный config.json или users.json — ровно то состояние, из-за
    # которого человек и пришёл восстанавливаться. ga_put_json_file пишет тем же
    # атомарным писателем, что и остальной продукт (проверка jq, временный файл
    # рядом с целью, chmod 600 до переименования, fsync файла и каталога).
    #
    # И у обоих отказов один выход — _restore_abort: бот с панелью подняты
    # обратно, распакованный архив с ключами затёрт. Голый `return 1` оставлял
    # сервер и без данных, и без управления.
    if ! ga_put_json_file "$backup_dir/config.json" "$CONFIG_FILE"; then
        log_error "$(tf backup_restore_write_failed "$CONFIG_FILE")"
        _ga_backup_fail restore_write_failed "$(tf backup_restore_write_failed "$CONFIG_FILE")"
        _restore_abort "$tmp_dir"
        return 1
    fi
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    log_success "$(t backup_restored_config)"
    if [ -f "$backup_dir/users.json" ]; then
        if ! ga_put_json_file "$backup_dir/users.json" "$USERS_FILE"; then
            log_error "$(tf backup_restore_write_failed "$USERS_FILE")"
            _ga_backup_fail restore_write_failed "$(tf backup_restore_write_failed "$USERS_FILE")"
            _restore_abort "$tmp_dir"
            return 1
        fi
        chmod 600 "$USERS_FILE" 2>/dev/null || true
        log_success "$(t backup_restored_users)"
    elif [ -f "$USERS_FILE" ]; then
        # Копия снята до первого пользователя: users.json в ней нет. Живой список оставался, а конфиги
        # контейнеров приезжали из копии без пиров — ответ «Восстановлено», выдача ключей «успешна», а
        # подключиться не мог никто (находка SR-29). Состояние копии — «пользователей нет»; прежний список
        # лежит в снимке перед восстановлением.
        if ! _ga_write_json "$USERS_FILE" <<<'{"schema":1,"users":[]}' 2>/dev/null; then
            log_error "$(tf backup_restore_write_failed "$USERS_FILE")"
            _ga_backup_fail restore_write_failed "$(tf backup_restore_write_failed "$USERS_FILE")"
            _restore_abort "$tmp_dir"
            return 1
        fi
        chmod 600 "$USERS_FILE" 2>/dev/null || true
        log_warning "$(t backup_restored_no_users)"
    fi
    # Доступы агентов. Старый архив их не содержит — тогда просто не трогаем то, что есть на сервере.
    # Копия не воскрешает удалённые доступы и не откатывает перевыпуск и заморозку (SEC-C1).
    if [ -f "$backup_dir/agents.json" ]; then
        _restore_agents_merge "$backup_dir/agents.json"
    fi
    # Подписки — тем же правилом: только на сервер, где их ещё не было (SEC-C1).
    _restore_subs_merge "$backup_dir/subs"
    if [ -f "$backup_dir/stats.json" ]; then
        cp "$backup_dir/stats.json" "${GOAMNEZIA_DIR}/stats.json" 2>/dev/null
        chmod 600 "${GOAMNEZIA_DIR}/stats.json" 2>/dev/null || true
    fi
    # Пароль панели — из копии только на чистом сервере. Поверх действующего он откатывал вход к паролю
    # на момент копии: сменённый после утечки пароль снова начинал работать, а владелец, забывший старый,
    # оставался без панели (находка аудита безопасности SEC-C1, 25.09.2026).
    if [ -f "$backup_dir/admin/password.json" ] && [ -d "${ADMIN_DIR:-/opt/goamnezia-admin}" ]; then
        if [ -f "${ADMIN_DIR:-/opt/goamnezia-admin}/password.json" ]; then
            _restore_kept panel_password
            log_info "$(t backup_kept_password)"
        else
            cp "$backup_dir/admin/password.json" "${ADMIN_DIR:-/opt/goamnezia-admin}/password.json" 2>/dev/null
            chmod 600 "${ADMIN_DIR:-/opt/goamnezia-admin}/password.json" 2>/dev/null || true
            log_success "$(t backup_restored_password)"
        fi
    fi
    if [ -f "$backup_dir/.language" ]; then
        cp "$backup_dir/.language" "${GOAMNEZIA_DIR}/.language"
        log_success "$(t backup_restored_lang)"
    fi
    if [ -f "$backup_dir/backup_schedule.json" ]; then
        cp "$backup_dir/backup_schedule.json" "${GOAMNEZIA_DIR}/backup_schedule.json" 2>/dev/null
        chmod 600 "${GOAMNEZIA_DIR}/backup_schedule.json" 2>/dev/null || true
        if command -v jq >/dev/null 2>&1; then
            local restored_schedule
            restored_schedule=$(jq -r '.frequency // "off"' "${GOAMNEZIA_DIR}/backup_schedule.json" 2>/dev/null || echo "off")
            case "$restored_schedule" in
                off|daily|weekly|monthly) set_backup_schedule "$restored_schedule" >/dev/null 2>&1 || true ;;
            esac
        fi
    fi

    if [ -d "$backup_dir/state" ]; then
        mkdir -p "$STATE_DIR"
        # Всё, кроме цепочек одноразовых ключей агентов (state/agents/): состояние цепочки из копии
        # возвращало бы уже сожжённый ключ и откатывало перевыпуск (SEC-C1; MCP_ROTATION §12.5 — цепочка в
        # копию не входит). Копии прежних версий её ещё содержат — пропускаем при разборе.
        local _st
        for _st in "$backup_dir/state/"* "$backup_dir/state/".[!.]* "$backup_dir/state/"..?*; do
            [ -e "$_st" ] || continue
            [ "$(basename "$_st")" = agents ] && continue
            cp -a "$_st" "$STATE_DIR/" 2>/dev/null
            _restore_state_conf_canon "$_st" "$STATE_DIR/$(basename "$_st")"
        done
        chmod 700 "$STATE_DIR" 2>/dev/null || true
        log_success "$(t backup_restored_state)"
    fi

    if [ -f "$backup_dir/nginx.conf" ]; then
        local nginx_conf nginx_link
        nginx_conf=$(_ga_backup_nginx_conf); nginx_link=$(_ga_backup_nginx_link)
        if _ga_backup_external_ok "$nginx_conf" && _ga_backup_external_ok "$nginx_link"; then
            mkdir -p "$(dirname "$nginx_conf")" "$(dirname "$nginx_link")" 2>/dev/null
            cp "$backup_dir/nginx.conf" "$nginx_conf"
            chmod 600 "$nginx_conf" 2>/dev/null || true
            ln -sf "$nginx_conf" "$nginx_link"
            log_success "$(t backup_restored_nginx)"
        else
            printf 'DRY: restore nginx %s\n' "$nginx_conf" >&2
        fi
    fi

    if [ -d "$backup_dir/letsencrypt" ]; then
        local le_dir part
        le_dir=$(_ga_backup_le_dir)
        if _ga_backup_external_ok "$le_dir"; then
            for part in live archive renewal; do
                mkdir -p "$le_dir/$part" 2>/dev/null
                [ -d "$backup_dir/letsencrypt/$part" ] && cp -a "$backup_dir/letsencrypt/$part/." "$le_dir/$part/" 2>/dev/null
            done
            log_success "$(t backup_restored_ssl)"
        else
            printf 'DRY: restore certificates %s\n' "$le_dir" >&2
        fi
    fi

    # Самоподписанный сертификат сайта — на прежнее место и с прежними правами:
    # tar распакован с --no-same-permissions, а приватный ключ обязан быть 0600
    # (каталог 0700), иначе его прочитает любой локальный пользователь.
    if [ -d "$backup_dir/tls" ]; then
        local tls_dir="${GOAMNEZIA_TLS_DIR:-$GOAMNEZIA_DIR/tls}"
        mkdir -p "$tls_dir" 2>/dev/null
        cp -a "$backup_dir/tls/." "$tls_dir/" 2>/dev/null
        chmod 700 "$tls_dir" 2>/dev/null || true
        find "$tls_dir" -type f -exec chmod 600 {} + 2>/dev/null || true
        log_success "$(t backup_restored_tls)"
    fi

    # Только данные бота. Код (bot.py, i18n.py, lang/) кладёт установщик из
    # дистрибутива: подменённый bot.py из «чужого» архива исполнился бы от root.
    # Настройки бота (.env: токен, владелец и список админов) — из копии только туда, где их нет: поверх
    # действующих они возвращали админа, которого владелец уже убрал, и прежний токен (SEC-C1).
    if [ -d "$backup_dir/bot" ]; then
        mkdir -p "$BOT_DIR" 2>/dev/null
        chmod 700 "$BOT_DIR" 2>/dev/null || true
        if [ -f "$BOT_DIR/.env" ]; then
            _restore_kept bot
            log_info "$(t backup_kept_bot)"
        else
            if [ -f "$backup_dir/bot/.env" ]; then
                cp "$backup_dir/bot/.env" "$BOT_DIR/.env" 2>/dev/null && chmod 600 "$BOT_DIR/.env" 2>/dev/null
            fi
            log_success "$(t backup_restored_bot)"
        fi
        [ -f "$backup_dir/bot/user_langs.json" ] && [ ! -f "$BOT_DIR/user_langs.json" ] \
            && cp "$backup_dir/bot/user_langs.json" "$BOT_DIR/user_langs.json" 2>/dev/null
    fi
    # Архив сноса: копии, что лежали в каталоге бэкапов на момент сноса, — обратно (LC-19).
    [ "${GA_RESTORE_WIPE:-0}" = 1 ] && _restore_wipe_inner_backups "$backup_dir"

    # Режим архива и то, что стоит на сервере (переезд между режимами).
    _restore_converge_mode
    # Профили, которых нет в архиве, но которые работали до восстановления.
    _restore_drop_unlisted_profiles "$live_profiles"
    # Адрес этой машины против адреса из копии (переезд) — до подъёма профилей и до первых ключей.
    _restore_server_ip_check

    # ── Контейнеры из восстановленного state/ ──
    # Это и есть сценарий переезда: ключи не перевыпускаются, контейнер
    # поднимается из сохранённых awg0.conf и clientsTable.
    local prof_rc=0 prof_code="" prof_msg=""
    restore_profiles_from_state || { prof_rc=$?; prof_code="${GA_ERR_CODE:-}"; prof_msg="${GA_ERR_MSG:-}"; }

    _ga_backup_systemctl start "$BOT_SERVICE" || true
    _ga_backup_systemctl start "$ADMIN_SERVICE" || true
    if [ "${GA_RESTORE_MCP_WAS_ACTIVE:-0}" = 1 ]; then
        _ga_backup_systemctl start "$(_ga_restore_mcp_unit)" || true
    fi
    command -v nginx >/dev/null 2>&1 && _ga_backup_systemctl reload nginx

    _restore_wipe_tmp "$tmp_dir"
    trap - TERM HUP INT

    # Данные разложены, но профиль не поднялся — это не «успех»: код и названные профили доходят до бота,
    # панели и агента, а не остаются строкой в stderr.
    if [ "$prof_rc" != 0 ]; then
        ga_audit "${GOAMNEZIA_WHO:-ssh}" "backup-restore" "$backup_file profiles=failed"
        GA_ERR_CODE="$prof_code"; GA_ERR_MSG="$prof_msg"; GA_LAST_ERROR_CODE="$prof_code"
        return 1
    fi
    log_success "$(t backup_restore_done)"
    # Восстановление — самое разрушительное действие продукта, и именно у него
    # действующее лицо обязано быть настоящим (см. backup-create выше).
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "backup-restore" "$backup_file"
    return 0
}

# restore_profiles_from_state — поднять контейнеры всех профилей из state/.
# Вызывается после того, как config.json и state/ уже на месте.
# amnezia_state_restore приходит из lib/amnezia.sh; в момент восстановления из
# таймера или из теста модуля может не быть — тогда просто говорим об этом.
restore_profiles_from_state() {
    command -v jq >/dev/null 2>&1 || return 0
    [ -f "$CONFIG_FILE" ] || return 0

    local profiles p
    profiles=$(jq -r '.profiles // {} | keys[]' "$CONFIG_FILE" 2>/dev/null)
    [ -n "$profiles" ] || return 0

    if ! type amnezia_state_restore >/dev/null 2>&1; then
        log_warning "$(t backup_state_restore_missing)"
        return 0
    fi

    local failed="" retry=""
    while read -r p; do
        [ -n "$p" ] || continue
        log_info "$(tf backup_profile_restoring "$p")"
        # recreate: работающий контейнер пересоздаётся из state/ — иначе порт, подсеть и MTU архива не применятся.
        if ! amnezia_state_restore "$p" recreate; then
            retry+=" $p"
        fi
    done <<< "$profiles"
    # Второй проход: порт из архива мог держать ещё не пересозданный контейнер другого профиля (в архиве
    # UDP/443 у awg2, а на сервере — у awg3, который по порядку идёт позже). После первого прохода порты
    # освободились (находка LC-20, 25.09.2026).
    for p in $retry; do
        log_info "$(tf backup_profile_restoring "$p")"
        if ! amnezia_state_restore "$p" recreate; then
            log_warning "$(tf backup_profile_restore_failed "$p")"
            failed+="${failed:+, }$p"
        fi
    done
    if [ -n "$failed" ]; then
        ga_err restore_profiles_failed "$(tf backup_err_profiles_failed "$failed")"
        return 1
    fi
    return 0
}

# ── Список бэкапов ───────────────────────────────────────────────────────────
# Где «Удалить всё» оставляет копию для восстановления и свой архив сноса. Переменная — для стендов:
# проверки не пишут в настоящий /root.
ga_backup_wipe_home() { printf '%s' "${GOAMNEZIA_WIPE_HOME:-/root}"; }

# ga_backup_candidates — все архивы, из которых можно восстановиться, полными путями, по одному в строке:
# сперва каталог бэкапов, затем копии в /root, которые оставил снос продукта (goamnezia_backup_* — настоящая
# копия, goamnezia-wipe-* — архив каталога продукта). На чистом сервере после сноса каталог бэкапов пуст, а
# экран «Восстановить из бэкапа» говорил «Бэкапов нет» и уходил — хотя копия лежала рядом (находка LC-19).
# Имя, которое уже есть в каталоге бэкапов, из /root второй раз не показываем.
ga_backup_candidates() {
    local f home name
    for f in "$BACKUP_DIR"/*.tar.gz*; do
        [ -f "$f" ] || continue
        [[ "$f" == *.sha256 ]] && continue
        printf '%s\n' "$f"
    done
    home=$(ga_backup_wipe_home)
    [ -n "$home" ] && [ "$home" != "$BACKUP_DIR" ] || return 0
    for f in "$home"/goamnezia_backup_*.tar.gz* "$home"/goamnezia-wipe-*.tar.gz; do
        [ -f "$f" ] || continue
        [[ "$f" == *.sha256 ]] && continue
        name=$(basename "$f")
        [ -e "$BACKUP_DIR/$name" ] && continue
        printf '%s\n' "$f"
    done
    return 0
}

# ga_backup_resolve_name <имя> — полный путь архива по имени для моста: каталог бэкапов, затем копии сноса в
# /root (только имена вида goamnezia_backup_* и goamnezia-wipe-*: мост не открывает произвольные файлы
# /root). Пусто и код 1 — такого архива нет.
ga_backup_resolve_name() {
    local name="${1:-}" home
    [[ "$name" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || return 1
    case "$name" in .*) return 1 ;; esac
    if [ -f "$BACKUP_DIR/$name" ]; then printf '%s' "$BACKUP_DIR/$name"; return 0; fi
    case "$name" in
        goamnezia_backup_*.tar.gz|goamnezia_backup_*.tar.gz.enc|goamnezia-wipe-*.tar.gz) ;;
        *) return 1 ;;
    esac
    home=$(ga_backup_wipe_home)
    [ -n "$home" ] && [ -f "$home/$name" ] || return 1
    printf '%s' "$home/$name"
}

list_backups() {
    local -a all=()
    mapfile -t all < <(ga_backup_candidates)
    if [ "${#all[@]}" -eq 0 ] || [ -z "${all[0]:-}" ]; then
        log_info "$(t backup_none)"
        return 1
    fi

    echo "" >&2
    echo -e "  ${BOLD}${WHITE}📦 $(t backup_list_title):${NC}" >&2
    echo -e "  ${DIM}$(printf '─%.0s' {1..60})${NC}" >&2

    local i=1 f size shown encrypted
    for f in "${all[@]}"; do
        [ -n "$f" ] || continue
        size=$(du -h "$f" 2>/dev/null | cut -f1)
        # Копия из /root — полным путём: человек должен видеть, что она лежит не в каталоге бэкапов.
        if [ "$(dirname "$f")" = "$BACKUP_DIR" ]; then shown=$(basename "$f"); else shown="$f"; fi
        encrypted=""
        [[ "$f" == *.enc ]] && encrypted=" 🔒"
        echo -e "  ${CYAN}${i})${NC} ${shown} (${size})${encrypted}" >&2
        i=$((i+1))
    done
    echo -e "  ${DIM}$(printf '─%.0s' {1..60})${NC}" >&2
    return 0
}

# backup_list_json — машиночитаемый список для моста, бота и панели. location — где лежит архив: backups
# (каталог бэкапов) или wipe (копия, оставленная сносом продукта в /root); восстанавливается по имени и та, и
# другая (backup-restore --file).
backup_list_json() {
    local f items="" name size mtime loc
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        name=$(basename "$f")
        size=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
        mtime=$(date -u -r "$f" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
        loc=backups
        [ "$(dirname "$f")" = "$BACKUP_DIR" ] || loc=wipe
        [ -n "$items" ] && items="${items},"
        # encrypted — чтобы бот и панель заранее знали, что такой архив восстанавливается только в
        # SSH (там спрашивают пароль), а не узнавали это отказом (SR-26).
        items="${items}$(jq -n --arg n "$name" --argjson s "${size:-0}" --arg m "$mtime" --arg l "$loc" \
                 --argjson e "$([[ "$name" == *.enc ]] && echo true || echo false)" \
                 '{name:$n, size:$s, created:$m, encrypted:$e, location:$l}' 2>/dev/null)"
    done < <(ga_backup_candidates)
    printf '[%s]\n' "$items"
    return 0
}

# ── Очистка старых бэкапов ───────────────────────────────────────────────────
cleanup_old_backups() {
    local keep="${1:-$BACKUP_KEEP_DEFAULT}"
    local count
    # Глубина приходит из окружения юнита (GOAMNEZIA_BACKUP_KEEP) — мусор или
    # ноль означал бы «удалить всё». Непонятное значение = не трогаем ничего.
    [[ "$keep" =~ ^[0-9]+$ ]] && [ "$keep" -ge 1 ] || return 0
    count=$(find "$BACKUP_DIR" -name "*.tar.gz*" ! -name "*.sha256" 2>/dev/null | wc -l | tr -d ' ')
    [[ "${count:-0}" =~ ^[0-9]+$ ]] || return 0

    if [ "$count" -gt "$keep" ]; then
        local to_delete=$((count - keep))
        # sort по имени = сорт по метке времени: имена вида
        # goamnezia_backup_YYYYmmdd_HHMMSS сортируются лексикографически верно.
        find "$BACKUP_DIR" -name "*.tar.gz*" ! -name "*.sha256" 2>/dev/null | sort | head -n "$to_delete" | while read -r f; do
            rm -f "$f" "${f}.sha256"
        done
        log_dim "$(tf backup_cleanup_fmt "$to_delete" "$keep")"
    fi
    return 0
}

# ── Ночной проход таймера ────────────────────────────────────────────────────
# Раньше юнит делал это одной строкой в ExecStart: «create_backup && cleanup».
# Две беды сразу.
#
#   1. Ротация строго ПОСЛЕ удачной копии — значит на забитом диске состояние
#      самозакрепляется: места нет → копия не снялась → ротация не пошла →
#      места по-прежнему нет, и так каждую ночь до конца жизни сервера.
#      Поэтому ротацию при нехватке места делаем ПЕРВОЙ: она и есть
#      единственный способ освободить каталог копий своими силами. В обычную
#      ночь порядок прежний (копия, потом ротация) — иначе глубина хранения
#      просаживалась бы на одну копию каждую ночь.
#   2. Отказ не давал ни события, ни строки нигде, кроме системного журнала:
#      ночная копия могла молча умереть навсегда, а узнавали об этом в день,
#      когда она понадобилась. Теперь исход каждого прохода ложится в
#      backup_last.json (его читают экраны) и отказ уходит событием боту.
#
# stdout: JSON {ok, created, rotated_first, code}.
backup_tick() {
    local keep="${1:-${GOAMNEZIA_BACKUP_KEEP:-$BACKUP_KEEP_DEFAULT}}"
    local rotated_first=false ok=true code="" name=""
    if type check_disk_space >/dev/null 2>&1 && ! check_disk_space "$GA_BACKUP_MIN_DISK_MB" "$BACKUP_DIR" 2>/dev/null; then
        rotated_first=true
        log_warning "$(t backup_rotate_first)"
        # ГЛУБЖЕ обычной глубины, иначе эта ветка не освобождает НИ БАЙТА.
        # Удачная ночь и так приводит каталог ровно к keep, значит при нехватке
        # места count == keep, и обычная ротация не удаляет ничего: состояние
        # самозакрепляется навсегда, а комментарий называл её «единственным
        # способом освободить каталог своими силами».
        #
        # На ОДНУ копию глубже обычного, но не меньше одной: в установившемся
        # состоянии count равен keep, и обычная ротация не удаляет ничего.
        local _deep="$keep"
        [ "$keep" -gt 1 ] && _deep=$(( keep - 1 ))
        cleanup_old_backups "$_deep"
    fi
    GA_ERR_CODE=""; GA_ERR_MSG=""; GA_LAST_ERROR_CODE=""
    # Под общим замком: ночной таймер звал create_backup мимо него, и запись users.json или state/ из бота в ту
    # же секунду давала копию, где users.json и awg0.conf из разных моментов (находка SR-38). Изнутри моста
    # (backup-tick) замок уже взят — ga_with_config_lock реентерабелен.
    local _bk_rc=0 _bk_wait=120
    type ga_timer_lock_wait >/dev/null 2>&1 && _bk_wait=$(ga_timer_lock_wait)
    if type ga_with_config_lock >/dev/null 2>&1; then
        GA_LOCK_WAIT="$_bk_wait" GA_LOCK_QUIET=1 ga_with_config_lock create_backup "" >/dev/null || _bk_rc=$?
    else
        create_backup "" >/dev/null || _bk_rc=$?
    fi
    # Замок так и не освободился (идёт установка или обновление — они держат его минутами): это не отказ копии.
    # Юнит не падает в failed, прошлый итог (backup_last.json) и бот не трогаются — копию снимет следующий запуск
    # по расписанию (жалоба 29.09.2026: goamnezia-backup падал во время установки, «не дождались блокировки»).
    if [ "$_bk_rc" = 75 ]; then
        log_warning "$(tf timer_busy_skipped "goamnezia-backup")"
        GA_ERR_CODE=""; GA_ERR_MSG=""; GA_LAST_ERROR_CODE=""
        jq -cn --argjson rf "$rotated_first" '{ok: true, skipped: "busy", created: "", rotated_first: $rf, code: ""}'
        return 0
    fi
    if [ "$_bk_rc" = 0 ]; then
        cleanup_old_backups "$keep"
        name=$(ga_backup_newest_name)
    else
        ok=false
        code="${GA_ERR_CODE:-${GA_LAST_ERROR_CODE:-backup_failed}}"
    fi
    ga_backup_mark "$ok" "$code"
    if [ "$ok" != true ]; then
        ga_audit "timer" "backup-failed" "code=$code"
        type ga_notify >/dev/null 2>&1 && ga_notify backup_failed \
            "$(jq -cn --arg c "$code" --arg m "${GA_ERR_MSG:-}" '{code: $c, message: $m}')"
        log_error "$(tf backup_tick_failed "${GA_ERR_MSG:-$code}")"
    fi
    jq -cn --argjson ok "$ok" --arg name "$name" --argjson rf "$rotated_first" --arg code "$code" \
        '{ok: $ok, created: $name, rotated_first: $rf, code: $code}'
    [ "$ok" = true ]
}

# ga_backup_mark <true|false> [код] — запомнить исход прохода. Тихая: сорванная
# запись памяти не повод объявлять неудачной удавшуюся копию.
ga_backup_mark() {
    local ok="${1:-false}" code="${2:-}" f tmp
    command -v jq >/dev/null 2>&1 || return 0
    f=$(ga_backup_last_file)
    tmp=$(mktemp "${f}.XXXXXX" 2>/dev/null) || return 0
    if jq -cn --argjson ok "${ok:-false}" --arg code "$code" --arg at "$(ga_now)" \
        '{ok: $ok, code: $code, at: $at}' 2>/dev/null >"$tmp"; then
        chmod 600 "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
    else
        rm -f "$tmp"
    fi
    return 0
}

# ga_backup_newest_name — имя самого свежего архива (по имени: метка времени в
# нём и есть хронология). Пусто, если копий нет.
ga_backup_newest_name() {
    local f newest=""
    for f in "$BACKUP_DIR"/*.tar.gz*; do
        [ -f "$f" ] || continue
        [[ "$f" == *.sha256 ]] && continue
        newest="$f"
    done
    [ -n "$newest" ] || return 1
    basename "$newest"
}

# backup_last_json → {name, created, size, count, tick_ok, tick_code, tick_at, schedule}
# schedule — частота ночной копии из backup_schedule.json (off | daily | weekly | monthly; файла нет — off):
# экран «Бэкапы» панели 0.5.0 показывает её рядом с последней копией.
# — ответ на вопрос «когда была последняя копия». Его не давал ни один экран, а
# восстановление из копии продукт советует при каждой беде.
backup_last_json() {
    local name="" created="" size=0 count=0 f last='{}'
    command -v jq >/dev/null 2>&1 || { printf '{}\n'; return 0; }
    for f in "$BACKUP_DIR"/*.tar.gz*; do
        [ -f "$f" ] || continue
        [[ "$f" == *.sha256 ]] && continue
        count=$((count + 1))
        name=$(basename "$f")
        size=$(wc -c 2>/dev/null <"$f" | tr -d ' ')
        created=$(date -u -r "$f" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    done
    [ -f "$(ga_backup_last_file)" ] && last=$(jq -c '.' "$(ga_backup_last_file)" 2>/dev/null) && [ -n "$last" ] || last='{}'
    local sched="off"
    if [ -f "${GOAMNEZIA_DIR:-/opt/goamnezia}/backup_schedule.json" ]; then
        sched=$(jq -r '.frequency // "off"' "${GOAMNEZIA_DIR:-/opt/goamnezia}/backup_schedule.json" 2>/dev/null) || sched="off"
        case "$sched" in off|daily|weekly|monthly) ;; *) sched="off" ;; esac
    fi
    jq -cn --arg n "$name" --arg c "$created" --argjson s "${size:-0}" --argjson k "$count" --argjson l "$last" --arg sch "$sched" \
        '{name: $n, created: $c, size: $s, count: $k, schedule: $sch,
          tick_ok: (if ($l|type) == "object" and ($l.ok|type) == "boolean" then $l.ok else null end),
          tick_code: ($l.code // ""), tick_at: ($l.at // "")}'
}

# ── Расписание бэкапов ───────────────────────────────────────────────────────
backup_schedule_calendar() {
    case "${1:-off}" in
        off)     echo "" ;;
        daily)   echo "*-*-* 03:20:00" ;;
        weekly)  echo "Sun 03:20:00" ;;
        monthly) echo "*-*-01 03:20:00" ;;
        *) return 1 ;;
    esac
}

set_backup_schedule() {
    # Без умолчания «off»: пустое значение (мост пропустил пустой --frequency=) молча снимало ночные
    # копии — единственную автоматическую страховку продукта (находка SR-47). Пусто — отказ bad_schedule.
    local frequency="${1:-}"
    local calendar
    if [ -z "$frequency" ] || ! calendar=$(backup_schedule_calendar "$frequency"); then
        ga_set_error bad_schedule
        log_error "$(tf backup_schedule_bad "$frequency")"
        return 1
    fi

    mkdir -p "$GOAMNEZIA_DIR" "$BACKUP_DIR" 2>/dev/null

    # Каталог юнитов — переменная, как в lib/timers.sh: раньше здесь стоял
    # литерал /etc/systemd/system, и расписание было единственным местом
    # продукта, которое писало в живую систему даже на стенде. Пока это
    # вызывалось только из первой установки, беда не всплывала; теперь
    # расписание меняют из меню и из моста, и стенд обязан остаться стендом.
    local sdir="${GOAMNEZIA_SYSTEMD_DIR:-/etc/systemd/system}" dry=0
    if type ga_dry >/dev/null 2>&1 && ga_dry; then dry=1; fi
    # В dry-run без явного каталога юнитов на диск не пишем вовсе.
    if [ "$dry" = 1 ] && [ -z "${GOAMNEZIA_SYSTEMD_DIR:-}" ]; then
        type ga_dry_echo >/dev/null 2>&1 && ga_dry_echo "backup schedule $frequency ($calendar)"
        echo "$frequency"
        return 0
    fi

    if [ "$frequency" = "off" ]; then
        _ga_backup_systemctl disable --now goamnezia-backup.timer
        rm -f "$sdir/goamnezia-backup.timer" "$sdir/goamnezia-backup.service"
        _ga_backup_systemctl daemon-reload
    else
        # ExecStart собирает окружение сам: таймер стартует вне меню, и ни
        # common.sh, ни словарь в нём не загружены. Порядок source обязателен —
        # backup.sh опирается на пути и ga_* из common.sh.
        # Вся ночная логика — в backup_tick (порядок ротации, память об исходе,
        # событие при отказе): в строке ExecStart её было не написать и не
        # проверить, а именно там она и ломалась молча.
        local root="${GOAMNEZIA_DIR:-/opt/goamnezia}"
        mkdir -p "$sdir" 2>/dev/null
        cat > "$sdir/goamnezia-backup.service" <<EOSVC
[Unit]
Description=$(t backup_unit_desc)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment=GOAMNEZIA_BACKUP_KEEP=${BACKUP_KEEP_DEFAULT}
ExecStart=/bin/bash -lc 'source ${root}/lib/common.sh; source ${root}/lib/i18n.sh; source ${root}/lib/backup.sh; load_language "\$(detect_language)"; backup_tick "\${GOAMNEZIA_BACKUP_KEEP:-30}" >/dev/null'
EOSVC

        cat > "$sdir/goamnezia-backup.timer" <<EOTIMER
[Unit]
Description=$(t backup_timer_desc)

[Timer]
OnCalendar=${calendar}
Persistent=true
RandomizedDelaySec=15m
Unit=goamnezia-backup.service

[Install]
WantedBy=timers.target
EOTIMER
        _ga_backup_systemctl daemon-reload || return 1
        _ga_backup_systemctl enable --now goamnezia-backup.timer || return 1
    fi

    jq -n --arg f "$frequency" --arg c "$calendar" --argjson k "$BACKUP_KEEP_DEFAULT" --arg u "$(ga_now)" \
        '{frequency:$f, calendar:$c, keep:$k, updated_at:$u}' \
        > "${GOAMNEZIA_DIR}/backup_schedule.json" 2>/dev/null
    chmod 600 "${GOAMNEZIA_DIR}/backup_schedule.json" 2>/dev/null || true
    # Расписание копии — мутация, и снятое расписание особенно: в журнал действий (SR-47).
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "backup-schedule" "$frequency"
    log_success "$(tf backup_schedule_set "$frequency")"
    echo "$frequency"
    return 0
}

backup_schedule_status() {
    local frequency="off" calendar=""
    if [ -f "${GOAMNEZIA_DIR}/backup_schedule.json" ] && command -v jq >/dev/null 2>&1; then
        frequency=$(jq -r '.frequency // "off"' "${GOAMNEZIA_DIR}/backup_schedule.json" 2>/dev/null || echo "off")
        calendar=$(jq -r '.calendar // ""' "${GOAMNEZIA_DIR}/backup_schedule.json" 2>/dev/null || echo "")
    fi
    printf 'frequency=%s calendar=%s\n' "$frequency" "$calendar"
    return 0
}

# ── Интерактивный бэкап ──────────────────────────────────────────────────────
interactive_backup() {
    echo "" >&2
    echo -e "  ${BOLD}${WHITE}💾 $(t backup_create_title)${NC}" >&2

    local password="" password2=""
    if confirm "$(t backup_encrypt_prompt)"; then
        echo -ne "  $(t backup_enter_pass): " >&2
        read -rs password
        echo "" >&2
        echo -ne "  $(t backup_repeat_pass): " >&2
        read -rs password2
        echo "" >&2
        if [ "$password" != "$password2" ]; then
            log_error "$(t backup_pass_mismatch)"
            return 1
        fi
        if [ ${#password} -lt 6 ]; then
            log_error "$(t backup_pass_short)"
            return 1
        fi
    fi

    create_backup "$password" >/dev/null || return 1
    cleanup_old_backups
    return 0
}

# ── Интерактивное восстановление ─────────────────────────────────────────────
# Выхода с этого экрана не было вовсе: единственный вопрос — «номер бэкапа или
# путь», и «0» уходил в разбор как НОМЕР строки. Строки с таким номером нет,
# поэтому человек, который просто передумал, получал красное «✗ Бэкап не
# найден» при полном списке живых копий на экране — продукт обвинял себя в
# пропаже там, где ничего не пропадало. Пустой ввод (Enter) вёл туда же.
# Теперь как на всех остальных экранах: «0» и пустая строка — тихий возврат,
# а сам выход назван словами в приглашении (строка «0) Назад» и легенда).
interactive_restore() {
    # Пустой список — не повод уходить: на чистом сервере восстанавливаются из СВОЕГО файла
    # (скачанного, из архива сноса), и путь к нему спрашивается так же (находка LC-19).
    list_backups || log_dim "$(t backup_none_path_hint)"

    echo -e "  ${CYAN}0${NC}) $(t back)" >&2
    echo -e "  ${DIM}$(ga_win_wrap "$(t backup_pick_legend)" 2)${NC}" >&2
    echo -ne "  $(t backup_pick_prompt): " >&2
    local choice
    # EOF (оборванная SSH-сессия) читаем как «0»: без этого под set -u сюда
    # приезжала бы пустая строка и разбор шёл дальше — ровно та же беда.
    read -r choice || choice=0
    # Пробелы по краям срезаем так же, как ga_ask: « 0 » — это «назад», а не
    # путь к файлу с именем из одних пробелов.
    choice="${choice#"${choice%%[![:space:]]*}"}"
    choice="${choice%"${choice##*[![:space:]]}"}"

    # Передумал — это не ошибка: ни кода ошибки, ни красной строки, ни записи
    # «восстановление не удалось» в журнале.
    case "$choice" in
        0|"") log_info "$(t cancelled)"; return 0 ;;
    esac

    local backup_file="" f i=1
    # Номер — по тому же списку, что на экране (каталог бэкапов и копии сноса в /root). Длина ограничена:
    # число длиннее int64 роняло сравнение и уводило разбор дальше (находка SR-53).
    if [[ "$choice" =~ ^[0-9]{1,4}$ ]]; then
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            if [ "$i" -eq "$((10#$choice))" ]; then
                backup_file="$f"
                break
            fi
            i=$((i+1))
        done < <(ga_backup_candidates)
    elif [ -f "$choice" ]; then
        backup_file="$choice"
    fi

    if [ -z "$backup_file" ]; then
        log_error "$(t backup_not_found)"
        return 1
    fi

    restore_backup "$backup_file"
}
