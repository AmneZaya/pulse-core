#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# goAmnezia pro — lib/upstream.sh: обновления из официального репозитория
# Amnezia (PLAN §6.8, CONTRACT §4.9)
#
# Что это. Два официальных источника: GitHub amnezia-vpn/amnezia-client (серверные
# скрипты контейнеров, каталог client/server_scripts/awg/) и Docker Hub
# (образы ядра amneziavpn/amneziawg-go и amneziavpn/amnezia-wg). Модуль умеет
# сравнить наше с новым (upstream_check), обновить ядро одного профиля с бэкапом,
# проверкой и откатом (upstream_update), вернуть предыдущее (upstream_rollback),
# пересоздать контейнер на закреплённом образе без смены скриптов
# (upstream_core_update) и раз в сутки сообщить боту, что есть новое
# (upstream_tick). Автообновления нет намеренно: обновление ядра — всегда по
# кнопке человека (решение владельца PLAN §10 п.8).
#
# Откуда «новое»:
#   • тег релиза клиента — СПИСОК релизов (api …/releases?per_page=15), первый
#     не-draft. Не releases/latest: тот эндпоинт пропускает пре-релизы, а текущий
#     5.0.2.1 помечен pre-release (lib/upstream/README.md);
#   • образ — новейший ВЕРСИОННЫЙ тег Docker Hub (вида 3.1.20260828, сортировка
#     sort -V); тег latest — только справка, куда он указывает. У legacy-образа
#     amnezia-wg версионных тегов нет — там сравнивается дайджест latest;
#   • скрипты — sha256 raw-файлов по тегу релиза против вендоренных копий
#     (awg/start.sh сверяется с awg/start.sh.upstream — наш start.sh отличается
#     идемпотентными iptables и заново собирается из нового upstream патчем
#     ga_up_patch_start_sh);
#   • плейсхолдеры $… в template.conf / configure_container.sh: новый — это
#     новый параметр протокола, генератор его не знает → в отчёте «не поддержан»,
#     поддержку добавляем релизом goAmnezia. Молча подставлять пусто нельзя —
#     так ломается совместимость линейки.
#
# Сеть. Все обращения — только здесь, только через ga_up_fetch и только с
# таймаутами (connect 8 с, всего 20 с). GitHub и Docker Hub доступны не с
# каждого хостинга: обе точки недоступны → код unreachable с советом, меню и
# бот не падают; недоступна одна — ответ с warning и sources.<имя>=unreachable.
# В dry-run сеть не трогается вовсе: GOAMNEZIA_UPSTREAM_FIXTURE_DIR — каталог с
# сохранёнными ответами (releases.json, hub_<образ>_tags.json,
# hub_<образ>_tag_<тег>.json, raw/<тег>/awg/<файл>), без него dry-run
# отвечает unreachable.
#
# Где что лежит (всё в рабочем каталоге, репозиторий не трогаем):
#   $UPSTREAM_DIR/images.json            — закреплённые образы (docker_pull_pinned
#                                          читает отсюда); после удачного
#                                          обновления сюда пишется новый дайджест
#   $UPSTREAM_DIR/awg/<тег>/              — скачанные скрипты релиза (как есть)
#   $UPSTREAM_DIR/awg/previous/           — вендоренные файлы до обновления + previous.json
#   $GOAMNEZIA_DIR/upstream/last_check.json, notified.json — память таймера
#   config.json .profiles.<p>.previous    — {image_tag, image_digest, client_release,
#                                          updated_at} для upstream_rollback (один шаг назад)
#
# Правила серии: stdout — только результат (JSON), всё для человека — в stderr;
# коды ошибок через ga_err (unreachable, tag_not_found, already_current,
# no_previous, backup_failed, download_failed, update_failed…); ни одной
# видимой строки вне t/tf (словарь lib/lang/<lang>.d/upstream.sh).
# Зависимости: lib/common.sh, lib/docker.sh (docker_pull_ref, docker_image_*),
# lib/amnezia.sh (amnezia_core_update, ga_amn_image_key), lib/backup.sh
# (create_backup — если подключён).
# ══════════════════════════════════════════════════════════════════════════════

GA_UP_GH_REPO="amnezia-vpn/amnezia-client"
GA_UP_GH_API="https://api.github.com/repos/${GA_UP_GH_REPO}/releases?per_page=15"
GA_UP_RAW="https://raw.githubusercontent.com/${GA_UP_GH_REPO}"
GA_UP_HUB="https://hub.docker.com/v2/repositories"
GA_UP_SCRIPTS_PATH="client/server_scripts"
GA_UP_TIMEOUT="${GOAMNEZIA_UPSTREAM_TIMEOUT:-20}"
GA_UP_CONNECT_TIMEOUT=8
# Вендоренные файлы по каталогам upstream (CONTRACT §1). start.sh у awg — наш,
# сверяется и обновляется через start.sh.upstream.
GA_UP_FILES_AWG="Dockerfile configure_container.sh run_container.sh start.sh template.conf"
# Файлы, в которых считаем плейсхолдеры $… (новые = новые параметры протокола).
GA_UP_PLACEHOLDER_FILES="template.conf configure_container.sh"
# Профиль → каталог upstream и ключ образа по умолчанию.
GA_UP_TAG_RE='^[0-9]+(\.[0-9]+){1,3}$'

# ga_up_tag_safe <тег> — тег годится в путь и в адрес? Спрашивают ВСЕ теги, а
# не только введённые человеком: тег релиза приходит из ответа GitHub и
# попадает и в каталог ($UPSTREAM_DIR/awg/<тег>/), и в URL raw-файлов. Своей
# формы у него нет (сегодня 5.0.3.0, завтра может быть с буквой), поэтому
# проверяем набор символов, а «.» и «..» исключаем отдельно: каталог «..» — это
# запись файлов релиза этажом выше, поверх вендоренных скриптов.
ga_up_tag_safe() {
    [[ "${1:-}" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || return 1
    [ "$1" != "." ] && [ "$1" != ".." ]
}

# ga_up_tag_newer <тег A> <тег B> → 0, если A — версия строго новее B («3.2.20260915» против «3.1.20260828»).
# Только версионные теги (цифры и точки): «latest» и пустое не сравниваются — не новее.
ga_up_tag_newer() {
    local a="${1:-}" b="${2:-}"
    [[ "$a" =~ ^[0-9]+(\.[0-9]+)*$ ]] && [[ "$b" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
    [ "$a" != "$b" ] || return 1
    [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n 1)" = "$a" ]
}

# ── Пути ─────────────────────────────────────────────────────────────────────

ga_up_dir()         { printf '%s' "${UPSTREAM_DIR:-${GOAMNEZIA_DIR:-/opt/goamnezia}/lib/upstream}"; }
ga_up_images_file() { printf '%s/images.json' "$(ga_up_dir)"; }
ga_up_work_dir()    { printf '%s' "${GOAMNEZIA_UPSTREAM_WORK:-${GOAMNEZIA_DIR:-/opt/goamnezia}/upstream}"; }
ga_up_last_check()  { printf '%s/last_check.json' "$(ga_up_work_dir)"; }
ga_up_notified()    { printf '%s/notified.json' "$(ga_up_work_dir)"; }
# Последняя ПОПЫТКА суточной проверки (и удачная, и «сеть недоступна») — last_check.json хранит только удачную.
ga_up_last_tick()   { printf '%s/last_tick.json' "$(ga_up_work_dir)"; }

# Каталог upstream для профиля. Он один: все профили продукта — AmneziaWG.
# (Аргумент оставлен, чтобы вызовы читались как «каталог этого профиля».)
ga_up_profile_dir() { echo awg; }

# sha256 файла: sha256sum на сервере, shasum на macOS-стенде.
ga_up_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | awk '{print $1}'
    else shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; fi
}

# JSON-поле из images.json (пусто, если нет).
ga_up_images_get() {
    local f
    f=$(ga_up_images_file)
    [ -f "$f" ] || return 1
    jq -r "$1 // empty" "$f" 2>/dev/null
}

# Ключ и каталог образа профиля (ga_amn_image_key из lib/amnezia.sh; без него —
# образ наших профилей).
ga_up_image_key() {
    if type ga_amn_image_key >/dev/null 2>&1; then ga_amn_image_key "$1"; else echo "amneziawg-go"; fi
}

# ── Сеть: единственная точка выхода наружу ───────────────────────────────────

# ga_up_fixture_path <url> → путь к сохранённому ответу в
# GOAMNEZIA_UPSTREAM_FIXTURE_DIR (stdout), 1 — URL неизвестной формы.
ga_up_fixture_path() {
    local url="$1" d="${GOAMNEZIA_UPSTREAM_FIXTURE_DIR:-}" img tag rest
    [ -n "$d" ] || return 1
    case "$url" in
        "${GA_UP_GH_API}")
            printf '%s/releases.json' "$d" ;;
        "${GA_UP_HUB}"/amneziavpn/*/tags\?page_size=*)
            img="${url#"${GA_UP_HUB}"/amneziavpn/}"; img="${img%%/*}"
            printf '%s/hub_%s_tags.json' "$d" "$img" ;;
        "${GA_UP_HUB}"/amneziavpn/*/tags/*)
            rest="${url#"${GA_UP_HUB}"/amneziavpn/}"
            img="${rest%%/*}"; tag="${rest##*/}"
            printf '%s/hub_%s_tag_%s.json' "$d" "$img" "$tag" ;;
        "${GA_UP_RAW}"/*/"${GA_UP_SCRIPTS_PATH}"/*)
            rest="${url#"${GA_UP_RAW}"/}"
            tag="${rest%%/*}"
            rest="${rest#*/"${GA_UP_SCRIPTS_PATH}"/}"
            printf '%s/raw/%s/%s' "$d" "$tag" "$rest" ;;
        *) return 1 ;;
    esac
}

# ga_up_fetch <url> <файл> → 0 скачано; 2 сеть/сервер недоступны; 3 — 404.
# Фикстуры имеют приоритет и в dry-run, и на живом сервере (тесты на стенде);
# dry-run без фикстур сеть не трогает и отвечает «недоступно».
ga_up_fetch() {
    local url="$1" out="$2" fx code
    if [ -n "${GOAMNEZIA_UPSTREAM_FIXTURE_DIR:-}" ]; then
        fx=$(ga_up_fixture_path "$url") || return 2
        [ -f "$fx" ] || return 3
        cp "$fx" "$out" 2>/dev/null || return 2
        return 0
    fi
    if ga_dry; then
        ga_dry_echo "curl --max-time $GA_UP_TIMEOUT $url"
        return 2
    fi
    command -v curl >/dev/null 2>&1 || return 2
    code=$(curl -sSL --connect-timeout "$GA_UP_CONNECT_TIMEOUT" --max-time "$GA_UP_TIMEOUT" \
        -A "goAmnezia/${GOAMNEZIA_VERSION:-0}" -H 'Accept: application/json' \
        -o "$out" -w '%{http_code}' "$url" 2>/dev/null) || { rm -f "$out"; return 2; }
    case "$code" in
        200) return 0 ;;
        404) rm -f "$out"; return 3 ;;
        *)   rm -f "$out"; return 2 ;;
    esac
}

# ── Сбор данных из источников (во временный каталог) ─────────────────────────

# ga_up_collect <каталог> <ключи образов через пробел> — releases.json и
# hub_<ключ>.json в каталог. stdout: «github=ok|unreachable hub=ok|unreachable».
# Не JSON: функцию зовут через ga_capture, а разбор одной строки дешевле.
ga_up_collect() {
    local dir="$1" keys="$2" gh="unreachable" hub="unreachable" k repo rc
    if ga_up_fetch "$GA_UP_GH_API" "$dir/releases.json"; then
        jq -e 'type == "array"' "$dir/releases.json" >/dev/null 2>&1 && gh="ok"
    fi
    for k in $keys; do
        repo=$(ga_up_images_get ".[\"$k\"].repo")
        [ -n "$repo" ] || continue
        rc=0
        ga_up_fetch "${GA_UP_HUB}/${repo}/tags?page_size=100" "$dir/hub_${k}.json" || rc=$?
        if [ "$rc" = 0 ] && jq -e '.results | type == "array"' "$dir/hub_${k}.json" >/dev/null 2>&1; then
            hub="ok"
        else
            rm -f "$dir/hub_${k}.json"
        fi
    done
    printf 'github=%s hub=%s\n' "$gh" "$hub"
}

# Первый не-draft релиз из releases.json → JSON {tag, published, prerelease, url}.
ga_up_release_latest() {
    jq -c '[.[]? | select(.draft != true)][0] // null
           | if . == null then null else {tag: (.tag_name // ""), published: (.published_at // ""),
                                          prerelease: (.prerelease // false), url: (.html_url // "")} end' "$1" 2>/dev/null
}

# Новейший версионный тег из hub_<ключ>.json → JSON {tag, digest, amd64_digest,
# updated, alias_latest_digest}. Версионных тегов нет (legacy amnezia-wg) →
# берём latest как есть.
ga_up_hub_latest() {
    local f="$1" tag
    tag=$(jq -r --arg re "$GA_UP_TAG_RE" '.results[]? | .name // empty | select(test($re))' "$f" 2>/dev/null | sort -V | tail -n 1)
    [ -n "$tag" ] || tag="latest"
    ga_up_hub_tag_json "$f" "$tag"
}

# Запись тега из списка тегов → JSON (null, если тега в списке нет).
ga_up_hub_tag_json() {
    local f="$1" tag="$2"
    jq -c --arg t "$tag" '
        (.results // []) as $r
        | ([$r[] | select(.name == $t)][0] // null) as $e
        | ([$r[] | select(.name == "latest")][0] // null) as $l
        | if $e == null then null else
            {tag: $t,
             digest: ($e.digest // ($e.images // [] | .[0].digest // "") // ""),
             amd64_digest: ([$e.images[]? | select(.architecture == "amd64") | .digest][0] // ""),
             updated: ($e.tag_last_pushed // $e.last_updated // ""),
             alias_latest_digest: (if $l == null then "" else ($l.digest // ($l.images // [] | .[0].digest // "") // "") end)}
          end' "$f" 2>/dev/null
}

# Тег, которого нет на первой странице списка: отдельный запрос /tags/<тег>.
ga_up_hub_tag_fetch() {
    local key="$1" tag="$2" dir="$3" repo f
    repo=$(ga_up_images_get ".[\"$key\"].repo")
    [ -n "$repo" ] || return 1
    f="$dir/hub_${key}_tag_${tag}.json"
    ga_up_fetch "${GA_UP_HUB}/${repo}/tags/${tag}" "$f" || return $?
    jq -c --arg t "$tag" '{tag: $t, digest: (.digest // (.images // [] | .[0].digest // "") // ""),
                          amd64_digest: ([.images[]? | select(.architecture == "amd64") | .digest][0] // ""),
                          updated: (.tag_last_pushed // .last_updated // ""), alias_latest_digest: ""}' "$f" 2>/dev/null
}

# ── Скрипты: скачивание, хеши, плейсхолдеры ──────────────────────────────────

# ga_up_download_scripts <тег> <awg> <каталог> → скачать все файлы каталога
# upstream по тегу. Код 3 — файла нет по тегу (в отчёт как missing), 2 — сеть.
# stdout: список «файл статус» (ok|missing).
ga_up_download_scripts() {
    local tag="$1" sub="$2" dir="$3" f rc net=0
    mkdir -p "$dir" || return 1
    for f in $GA_UP_FILES_AWG; do
        rc=0
        ga_up_fetch "${GA_UP_RAW}/${tag}/${GA_UP_SCRIPTS_PATH}/${sub}/${f}" "$dir/$f" || rc=$?
        case "$rc" in
            0) printf '%s ok\n' "$f" ;;
            3) printf '%s missing\n' "$f" ;;
            *) net=1; printf '%s unreachable\n' "$f" ;;
        esac
    done
    [ "$net" = 0 ] || return 2
    return 0
}

# Плейсхолдеры $NAME / ${NAME} файла в порядке появления, без повторов.
ga_up_placeholders() {
    [ -f "$1" ] || return 0
    grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' "$1" 2>/dev/null | sed 's/[${}]//g' | awk '!seen[$0]++'
}

# Разница плейсхолдеров между вендоренным файлом и новым → JSON {new, removed}.
ga_up_placeholder_diff() {
    local old="$1" new="$2" a b
    a=$(ga_up_placeholders "$old" | jq -Rn '[inputs]')
    b=$(ga_up_placeholders "$new" | jq -Rn '[inputs]')
    jq -cn --argjson a "${a:-[]}" --argjson b "${b:-[]}" '{new: ($b - $a), removed: ($a - $b)}'
}

# ga_up_scripts_diff <awg> <каталог с новыми файлами> → JSON
# {changed, unchanged, missing, placeholders: {"<файл>": {new, removed}}}.
# Наш awg/start.sh сверяется с awg/start.sh.upstream (дословный оригинал).
ga_up_scripts_diff() {
    local sub="$1" newdir="$2" base f ours theirs changed='[]' unchanged='[]' missing='[]' ph='{}' d
    base="$(ga_up_dir)/$sub"
    for f in $GA_UP_FILES_AWG; do
        ours="$base/$f"
        [ "$sub" = awg ] && [ "$f" = start.sh ] && [ -f "$base/start.sh.upstream" ] && ours="$base/start.sh.upstream"
        theirs="$newdir/$f"
        if [ ! -f "$theirs" ]; then
            missing=$(jq -c --arg f "$f" '. + [$f]' <<<"$missing")
            continue
        fi
        if [ -f "$ours" ] && [ "$(ga_up_sha256 "$ours")" = "$(ga_up_sha256 "$theirs")" ]; then
            unchanged=$(jq -c --arg f "$f" '. + [$f]' <<<"$unchanged")
        else
            changed=$(jq -c --arg f "$f" '. + [$f]' <<<"$changed")
        fi
        case " $GA_UP_PLACEHOLDER_FILES " in
            *" $f "*)
                d=$(ga_up_placeholder_diff "$ours" "$theirs")
                ph=$(jq -c --arg k "$sub/$f" --argjson d "$d" '.[$k] = $d' <<<"$ph")
                ;;
        esac
    done
    jq -cn --argjson c "$changed" --argjson u "$unchanged" --argjson m "$missing" --argjson ph "$ph" \
        '{changed: $c, unchanged: $u, missing: $m, placeholders: $ph}'
}

# Наша правка start.sh поверх дословного upstream: шапка-комментарий (в каждой
# строке слово iptables — так тест «diff без iptables пуст» остаётся верным) и
# `iptables -A …` → `iptables -C … 2>/dev/null || iptables -A …`, в том числе
# для `-t nat`. Применённый к текущему start.sh.upstream, патч даёт байт в
# байт текущий awg/start.sh — это проверяет tests/test_upstream_dryrun.sh.
ga_up_patch_start_sh() {
    local src="$1"
    [ -f "$src" ] || return 1
    awk '
        NR == 1 && /^#!/ {
            print
            print "# goAmnezia: единственная наша правка к upstream — правила iptables ставятся идемпотентно."
            print "# Зачем: upstream делает `iptables -A` при каждом старте, а контейнер стартует не один раз"
            print "#        (--restart always, перезагрузка хоста, core-update), и цепочки iptables распухают"
            print "#        дублями одних и тех же правил iptables после каждого рестарта контейнера;"
            print "#        форма `iptables -C … 2>/dev/null || iptables -A …` добавляет правило, только если его нет."
            next
        }
        /^[[:space:]]*iptables([[:space:]]+-t[[:space:]]+nat)?[[:space:]]+-A[[:space:]]/ {
            line = $0
            check = line
            sub(/-A /, "-C ", check)
            print check " 2>/dev/null || " line
            next
        }
        { print }
    ' "$src"
}

# ── Текущее состояние без сети ───────────────────────────────────────────────

# Профили с текущими версиями и возможностью отката → JSON-массив.
ga_up_profiles_current() {
    local p rows='[]' key tag digest prev container profiles
    # Через загрузчик: на битом config.json подстановка команды отдавала пустой
    # список, и экран обновлений показывал «профилей нет» вместо отказа.
    ga_profiles_load profiles || return 1
    for p in $profiles; do
        key=$(ga_up_image_key "$p")
        container=$(ga_profile_field "$p" container)
        tag=$(ga_config_get ".profiles.$p.image_tag" 2>/dev/null)
        digest=$(ga_config_get ".profiles.$p.image_digest" 2>/dev/null)
        prev=$(ga_config_get ".profiles.$p.previous" 2>/dev/null | jq -c 'if type == "object" then . else null end' 2>/dev/null)
        [ -n "$prev" ] || prev='null'
        rows=$(jq -c --arg p "$p" --arg c "$container" --arg key "$key" --arg tag "$tag" --arg d "$digest" --argjson prev "$prev" \
            '. + [{profile: $p, container: $c, image_key: $key, current_tag: $tag, current_digest: $d,
                   available_tag: "", available_digest: "", update: false,
                   previous_tag: ($prev.image_tag // ""), previous_digest: ($prev.image_digest // ""),
                   rollback_available: ($prev != null and (($prev.image_digest // "") != "" or ($prev.image_tag // "") != ""))}]' <<<"$rows")
    done
    printf '%s' "$rows"
}

# Ключи образов, которыми пользуются установленные профили (+ образ по умолчанию).
ga_up_image_keys_in_use() {
    local p keys="amneziawg-go" k profiles
    ga_profiles_load profiles || return 1
    for p in $profiles; do
        k=$(ga_up_image_key "$p")
        case " $keys " in *" $k "*) ;; *) keys="$keys $k" ;; esac
    done
    echo "$keys"
}

# ── upstream_check ───────────────────────────────────────────────────────────

# upstream_check → stdout JSON (см. шапку и CONTRACT §4.9). Ничего не меняет.
# Обе точки недоступны → код unreachable (rc 1, JSON не печатается — мост
# отвечает ошибкой с текущими версиями профилей из ga_up_profiles_current).
upstream_check() {
    local tmp keys src gh hub rel_cur rel_new release='null' images='{}' scripts='{}' ph='{}' unsupported='[]'
    local k hub_json profiles updates=false warn="" sub newdir sd rc
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/goamnezia-upstream.XXXXXX") || return 1
    chmod 700 "$tmp"
    # ga_capture, а не $( ): на битом config.json функция честно возвращает
    # config_corrupt, но подстановка команды код теряет, и дальше всё падало на
    # сборке ответа. Человеку, боту, панели и агенту печаталось «источники
    # обновлений недоступны» при живых GitHub и Docker Hub — владельца
    # отправляли чинить сеть, а чинить надо было настройки.
    ga_capture keys ga_up_image_keys_in_use || return $?
    ga_capture src ga_up_collect "$tmp" "$keys"
    gh="${src#github=}"; gh="${gh%% *}"; hub="${src##*hub=}"
    if [ "$gh" != ok ] && [ "$hub" != ok ]; then
        rm -rf "$tmp"
        ga_err unreachable "$(t upstream_err_unreachable)"
        return 1
    fi
    [ "$gh" = ok ]  || { warn="$(t upstream_warn_github_unreachable)"; log_warning "$warn"; }
    [ "$hub" = ok ] || { warn="$(t upstream_warn_hub_unreachable)"; log_warning "$warn"; }

    # 1. Релиз клиента и скрипты по его тегу (только если тег новее: одинаковый
    # тег означает те же файлы — незачем качать десять файлов раз в сутки).
    rel_cur=$(ga_up_images_get '.client_release')
    if [ "$gh" = ok ]; then
        release=$(ga_up_release_latest "$tmp/releases.json")
        [ -n "$release" ] && [ "$release" != null ] || release='null'
        rel_new=$(jq -r '.tag // empty' <<<"$release")
        # Тег из ответа GitHub уходит в путь и в URL — проверяем его так же,
        # как введённый человеком. Не прошёл — в отчёт он попадает (это данные,
        # jq их экранирует), но ни качать по нему, ни создавать каталог нельзя.
        if [ -n "$rel_new" ] && ! ga_up_tag_safe "$rel_new"; then
            log_warning "$(tf upstream_warn_tag_unsafe "$rel_new")"
            rel_new=""
        fi
        if [ -n "$rel_new" ]; then
            release=$(jq -c --arg cur "$rel_cur" '. + {current: $cur, update: (.tag != $cur)}' <<<"$release")
            if [ "$rel_new" != "$rel_cur" ]; then
                sub=awg
                newdir="$tmp/raw/$sub"
                rc=0
                ga_up_download_scripts "$rel_new" "$sub" "$newdir" >/dev/null 2>&1 || rc=$?
                if [ "$rc" = 2 ]; then
                    # raw.githubusercontent.com недоступен отдельно от API —
                    # честно говорим «не проверено», а не «все файлы пропали».
                    scripts=$(jq -c --arg s "$sub" --arg tag "$rel_new" '.[$s] = {tag: $tag, checked: false, unreachable: true, changed: [], unchanged: [], missing: []}' <<<"$scripts")
                else
                    sd=$(ga_up_scripts_diff "$sub" "$newdir")
                    scripts=$(jq -c --arg s "$sub" --arg tag "$rel_new" --argjson d "$sd" \
                        '.[$s] = ({tag: $tag, checked: true} + ($d | del(.placeholders)))' <<<"$scripts")
                    ph=$(jq -c --argjson d "$sd" '. + $d.placeholders' <<<"$ph")
                    unsupported=$(jq -c '[to_entries[] | .key as $f | .value.new[]? | {file: $f, name: .}]' <<<"$ph")
                    [ "$(jq -r 'length' <<<"$unsupported")" = 0 ] || log_warning "$(tf upstream_warn_unsupported "$rel_new" "$(jq -r '[.[].name] | unique | join(", ")' <<<"$unsupported")")"
                fi
            else
                scripts=$(jq -c --arg s awg --arg tag "$rel_new" '.[$s] = {tag: $tag, checked: false, changed: [], unchanged: [], missing: []}' <<<"$scripts")
            fi
        fi
    fi

    # 2. Образы: закреплённый тег/дайджест против новейшего версионного тега.
    for k in $keys; do
        if [ -f "$tmp/hub_${k}.json" ]; then
            hub_json=$(ga_up_hub_latest "$tmp/hub_${k}.json")
        else
            hub_json='null'
        fi
        [ -n "$hub_json" ] || hub_json='null'
        images=$(jq -c --arg k "$k" --arg repo "$(ga_up_images_get ".[\"$k\"].repo")" \
            --arg ptag "$(ga_up_images_get ".[\"$k\"].tag")" --arg pdig "$(ga_up_images_get ".[\"$k\"].digest")" \
            --arg checked "$(ga_up_images_get ".[\"$k\"].checked")" --argjson h "$hub_json" '
            .[$k] = {repo: $repo, pinned_tag: $ptag, pinned_digest: $pdig, pinned_checked: $checked,
                     latest_tag: ($h.tag // ""), latest_digest: ($h.digest // ""),
                     latest_amd64_digest: ($h.amd64_digest // ""), latest_updated: ($h.updated // ""),
                     alias_latest_digest: ($h.alias_latest_digest // ""),
                     reachable: ($h != null),
                     update: ($h != null and ($h.digest // "") != "" and ($h.digest // "") != $pdig)}' <<<"$images")
    done

    # 3. Профили: текущий образ контейнера против доступного.
    # Тот же случай: сперва читаем с проверкой кода, потом обрабатываем.
    local _cur
    ga_capture _cur ga_up_profiles_current || return $?
    profiles=$(printf '%s' "$_cur" | jq -c --argjson im "$images" '
        map(. as $p | ($im[$p.image_key] // {}) as $i
            | .available_tag = ($i.latest_tag // "")
            | .available_digest = ($i.latest_digest // "")
            | .update = (($i.latest_digest // "") != "" and ($i.latest_digest // "") != $p.current_digest))')
    # Новый релиз клиента — обновление, только если его скрипты удалось проверить и они другие.
    # Раньше хватало одного нового тега: при недоступном raw.githubusercontent.com экран писал
    # «Есть обновление», бот получал upstream_available, а кнопка падала на скачивании скриптов
    # (находка LS-10, 25.09.2026). Не проверили — так и говорим.
    local rel_new_tag="" hint_key="current"
    rel_new_tag=$(jq -r 'if (.update // false) then (.tag // "") else "" end' <<<"$release" 2>/dev/null) || rel_new_tag=""
    if [ "$(jq -r 'any(.[]; .update)' <<<"$profiles")" = true ]; then
        updates=true
    elif [ -n "$rel_new_tag" ] \
         && [ "$(jq -r '(.awg.checked // false) and ((((.awg.changed // []) | length) + ((.awg.missing // []) | length)) > 0)' <<<"$scripts")" = true ]; then
        updates=true
    elif [ -n "$rel_new_tag" ] && [ "$(jq -r '.awg.unreachable // false' <<<"$scripts")" = true ]; then
        hint_key="unreachable"
    elif [ -n "$rel_new_tag" ]; then
        # Вышло новое приложение Amnezia, а серверу менять нечего (образы и скрипты те же): раньше это
        # называлось «Есть обновление… по профилю», хотя все профили «актуально» (находка LC-21) — обновлять
        # надо приложение у людей.
        hint_key="client_only"
    fi
    rm -rf "$tmp"
    jq -cn --arg now "$(ga_now)" --arg gh "$gh" --arg hub "$hub" --argjson rel "$release" --argjson im "$images" \
        --argjson sc "$scripts" --argjson ph "$ph" --argjson un "$unsupported" --argjson pr "$profiles" \
        --argjson up "$updates" --arg warn "$warn" \
        --arg hk "$( if [ "$updates" = true ]; then echo update; else echo "$hint_key"; fi )" \
        --arg hint "$( if [ "$updates" = true ]; then t upstream_hint_update; elif [ "$hint_key" = unreachable ]; then tf upstream_hint_scripts_unreachable "$rel_new_tag"; elif [ "$hint_key" = client_only ]; then tf upstream_hint_client_only "$rel_new_tag"; else t upstream_hint_current; fi )" '
        {checked: $now, sources: {github: $gh, dockerhub: $hub}, client_release: $rel, images: $im,
         scripts: $sc, placeholders: $ph, unsupported: $un, profiles: $pr,
         updates_available: $up, hint: $hint, hint_key: $hk} + (if $warn == "" then {} else {warning: $warn} end)'
}

# ── Вспомогательное для обновления ───────────────────────────────────────────

# Бэкап перед обновлением ядра: lib/backup.sh подключён — обязателен; нет
# модуля — честное предупреждение (стенд, обрезанная установка).
ga_up_backup() {
    local f=""
    if type create_backup >/dev/null 2>&1; then
        log_step "$(t upstream_step_backup)"
        # В текущей оболочке, а не в $( … ): причина отказа (нет места, битый users.json) раньше терялась, и на
        # любую было одно «бэкап не удался» (находка SR-31).
        GA_ERR_CODE=""; GA_ERR_MSG=""
        if ! ga_capture f create_backup "" 2>/dev/null; then
            ga_err backup_failed "$(tf upstream_err_backup_why "${GA_ERR_MSG:-$(t upstream_err_backup)}")"
            return 1
        fi
        printf '%s' "$(printf '%s' "$f" | tail -n 1)"
        return 0
    fi
    log_warning "$(t upstream_warn_no_backup)"
    return 0
}

# Сохранить вендоренные файлы каталога как «предыдущие» (для отката) и
# положить рядом previous.json.
ga_up_scripts_save_previous() {
    local sub="$1" base prev f
    base="$(ga_up_dir)/$sub"; prev="$base/previous"
    rm -rf "$prev" && mkdir -p "$prev" || return 1
    for f in $GA_UP_FILES_AWG start.sh.upstream; do
        [ -f "$base/$f" ] && cp -p "$base/$f" "$prev/$f"
    done
    jq -cn --arg rel "$(ga_up_images_get '.client_release')" --arg now "$(ga_now)" \
        '{client_release: $rel, saved_at: $now}' >"$prev/previous.json" || return 1
    return 0
}

# Установить скачанные файлы релиза в вендоренный каталог: всё как есть, а
# awg/start.sh — пересобрать нашим патчем из нового start.sh (оригинал —
# в start.sh.upstream). Файла нет в релизе (missing) — старый остаётся.
ga_up_scripts_install() {
    local sub="$1" newdir="$2" base f
    base="$(ga_up_dir)/$sub"
    mkdir -p "$base" || return 1
    for f in $GA_UP_FILES_AWG; do
        [ -f "$newdir/$f" ] || continue
        if [ "$sub" = awg ] && [ "$f" = start.sh ]; then
            cp "$newdir/$f" "$base/start.sh.upstream" || return 1
            ga_up_patch_start_sh "$newdir/$f" >"$base/start.sh" || return 1
        else
            cp "$newdir/$f" "$base/$f" || return 1
        fi
        chmod 644 "$base/$f" 2>/dev/null || true
    done
    return 0
}

# Вернуть вендоренные файлы из previous/ (если есть).
ga_up_scripts_restore_previous() {
    local sub="$1" base prev f
    base="$(ga_up_dir)/$sub"; prev="$base/previous"
    [ -d "$prev" ] || return 0
    for f in $GA_UP_FILES_AWG start.sh.upstream; do
        [ -f "$prev/$f" ] && cp -p "$prev/$f" "$base/$f"
    done
    return 0
}

# Записать образ в рабочий images.json (атомарно, jq → tmp → mv).
ga_up_images_set() {
    local key="$1" tag="$2" digest="$3" amd64="${4:-}" release="${5:-}" f tmp
    f=$(ga_up_images_file)
    [ -f "$f" ] || return 1
    tmp=$(mktemp "${f}.XXXXXX") || return 1
    if jq --arg k "$key" --arg t "$tag" --arg d "$digest" --arg a "$amd64" --arg rel "$release" --arg now "$(ga_now | cut -c1-10)" '
        .[$k] = ((.[$k] // {}) + {tag: $t, digest: $d, checked: $now}
                 + (if $a == "" then {} else {amd64_digest: $a} end))
        | (if $rel == "" then . else .client_release = $rel end)' "$f" 2>/dev/null >"$tmp"; then
        mv -f "$tmp" "$f"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# Целевой образ для профиля: JSON {tag, digest, amd64_digest, updated} по тегу
# (из списка или отдельным запросом) либо новейший версионный. Код 3 — тега нет.
ga_up_target_image() {
    local key="$1" tag="$2" dir="$3" js
    [ -f "$dir/hub_${key}.json" ] || return 2
    if [ -n "$tag" ]; then
        js=$(ga_up_hub_tag_json "$dir/hub_${key}.json" "$tag")
        if [ -z "$js" ] || [ "$js" = null ]; then
            js=$(ga_up_hub_tag_fetch "$key" "$tag" "$dir") || js=""
        fi
        if [ -z "$js" ] || [ "$js" = null ] || [ "$(jq -r '.digest // ""' <<<"$js")" = "" ]; then
            ga_err tag_not_found "$(tf upstream_err_tag_not_found "$tag" "$key")" 3
            return 3
        fi
    else
        js=$(ga_up_hub_latest "$dir/hub_${key}.json")
        [ -n "$js" ] && [ "$js" != null ] || return 2
    fi
    printf '%s' "$js"
}

# ── upstream_update ──────────────────────────────────────────────────────────

# upstream_update <профиль> [тег образа] → stdout JSON {profile, container,
# image_tag, image_digest, previous_tag, previous_digest, client_release,
# scripts: {tag, changed, unsupported}, backup, rolled_back:false}.
# Порядок: источники → цель → бэкап → скрипты (previous/ + установка новых +
# патч start.sh) → pull образа по дайджесту → amnezia_core_update (пересоздание
# из state/, ключи не трогаем, /opt/warp возвращается) → проверка awg show и
# порта (внутри core_update) → при провале откат образа и скриптов.
upstream_update() { ga_with_config_lock _upstream_update_locked "$@"; }
_upstream_update_locked() {
    local profile="$1" want_tag="${2:-}"
    local tmp src gh hub key sub target tag digest amd64 cur_digest cur_tag repo ref rc
    local rel_cur rel_new release scripts_changed='[]' unsupported='[]' scripts_tag="" newdir sd backup="" res prev_json
    local state back_ref rolled startsh="" startsh_saved=0 start_source="" rollback_source=""
    ga_profile_check_installed "$profile" || return $?
    if [ -n "$want_tag" ] && ! ga_up_tag_safe "$want_tag"; then
        ga_err bad_arg "$(tf upstream_err_tag_not_found "$want_tag" "-")" 2
        return 2
    fi
    # Демон Docker — ДО первого изменения (CONTRACT §4.3). Иначе на сервере, где
    # клиент и демон разошлись версиями, человек сначала ждал полную резервную
    # копию и три попытки загрузки со сном, а потом получал код, из которого не
    # следует лечение («перезапустите docker»), — минута тишины впустую.
    ga_capture state docker_container_state "$(ga_profile_field "$profile" container)"
    ga_amn_docker_up "$state" || return 1
    key=$(ga_up_image_key "$profile"); sub=$(ga_up_profile_dir "$profile")
    repo=$(ga_up_images_get ".[\"$key\"].repo")
    cur_tag=$(ga_config_get ".profiles.$profile.image_tag" 2>/dev/null)
    cur_digest=$(ga_config_get ".profiles.$profile.image_digest" 2>/dev/null)
    rel_cur=$(ga_up_images_get '.client_release')
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/goamnezia-upstream.XXXXXX") || return 1
    chmod 700 "$tmp"
    ga_capture src ga_up_collect "$tmp" "$key"
    gh="${src#github=}"; gh="${gh%% *}"; hub="${src##*hub=}"
    if [ "$hub" != ok ]; then
        rm -rf "$tmp"
        ga_err unreachable "$(t upstream_err_unreachable)"
        return 1
    fi
    ga_capture target ga_up_target_image "$key" "$want_tag" "$tmp"; rc=$?
    if [ "$rc" != 0 ]; then
        rm -rf "$tmp"; return "$rc"
    fi
    tag=$(jq -r '.tag // ""' <<<"$target"); digest=$(jq -r '.digest // ""' <<<"$target")
    amd64=$(jq -r '.amd64_digest // ""' <<<"$target")
    if ! [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        rm -rf "$tmp"
        ga_err tag_not_found "$(tf upstream_err_tag_not_found "${tag:-?}" "$key")" 3
        return 3
    fi
    # Скрипты — по тегу первого не-draft релиза (только при доступном GitHub).
    rel_new=""
    if [ "$gh" = ok ]; then
        release=$(ga_up_release_latest "$tmp/releases.json")
        rel_new=$(jq -r '.tag // empty' <<<"${release:-null}")
        # Тег из ответа сервиса — в каталог и в URL только после проверки (как
        # тег от человека выше). Не прошёл — обновляем один образ, без скриптов.
        if [ -n "$rel_new" ] && ! ga_up_tag_safe "$rel_new"; then
            log_warning "$(tf upstream_warn_tag_unsafe "$rel_new")"
            rel_new=""
        fi
    else
        log_warning "$(t upstream_warn_github_unreachable)"
    fi
    if [ "$digest" = "$cur_digest" ] && { [ -z "$rel_new" ] || [ "$rel_new" = "$rel_cur" ]; }; then
        rm -rf "$tmp"
        ga_err already_current "$(tf upstream_err_already_current "$profile" "${cur_tag:-?}")"
        return 1
    fi
    log_step "$(tf upstream_updating "$profile" "${cur_tag:--}" "$tag")"

    # 1. Бэкап.
    ga_capture backup ga_up_backup || { rm -rf "$tmp"; return 1; }

    # 2. Скрипты релиза: previous/ → скачать → diff плейсхолдеров → установить.
    if [ -n "$rel_new" ] && [ "$rel_new" != "$rel_cur" ]; then
        log_step "$(tf upstream_step_scripts "$rel_new")"
        newdir="$(ga_up_dir)/$sub/$rel_new"
        if ! ga_up_download_scripts "$rel_new" "$sub" "$newdir" >/dev/null; then
            rm -rf "$tmp"
            ga_err download_failed "$(tf upstream_err_download "$rel_new")"
            return 1
        fi
        sd=$(ga_up_scripts_diff "$sub" "$newdir")
        scripts_changed=$(jq -c '.changed' <<<"$sd")
        unsupported=$(jq -c '[.placeholders | to_entries[] | .key as $f | .value.new[]? | {file: $f, name: .}]' <<<"$sd")
        if [ "$(jq -r 'length' <<<"$unsupported")" != 0 ]; then
            log_warning "$(tf upstream_warn_unsupported "$rel_new" "$(jq -r '[.[].name] | unique | join(", ")' <<<"$unsupported")")"
        fi
        ga_up_scripts_save_previous "$sub" || { rm -rf "$tmp"; ga_err scripts_failed "$(tf upstream_err_scripts_write "$sub")"; return 1; }
        ga_up_scripts_install "$sub" "$newdir" || {
            ga_up_scripts_restore_previous "$sub"; rm -rf "$tmp"
            ga_err scripts_failed "$(tf upstream_err_scripts_write "$sub")"; return 1; }
        scripts_tag="$rel_new"
        # Новый upstream start.sh → state/start.sh пересобрать: контейнер после
        # core_update стартует уже с ним. goWARP держит свои строки в start.sh
        # контейнера — предупреждаем, восстановление у него своё.
        # Копия для отката живёт вне state/: amnezia_state_sync заменяет весь каталог.
        # Сначала забираем свежие строки контейнера (включая goWARP), затем храним их
        # до конца операции; новый скрипт core_update выбирает после своего снимка.
        startsh="$STATE_DIR/$(ga_profile_field "$profile" container)/start.sh"
        if jq -e 'index("start.sh") != null' <<<"$scripts_changed" >/dev/null 2>&1; then
            if ! amnezia_state_sync "$profile"; then
                ga_up_scripts_restore_previous "$sub"; rm -rf "$tmp"; return 1
            fi
            if [ -f "$startsh" ]; then
                if ! cp -p "$startsh" "$tmp/start.sh.previous"; then
                    ga_up_scripts_restore_previous "$sub"; rm -rf "$tmp"; return 1
                fi
                startsh_saved=1
                rollback_source="$tmp/start.sh.previous"
            else
                rollback_source=template
            fi
            start_source=template
            # Строки goWARP PRO core_update переносит в новый start.sh сам (ga_amn_start_sh_carry_warp) — говорим об этом.
            [ -d "$STATE_DIR/$(ga_profile_field "$profile" container)/warp" ] && log_info "$(tf upstream_warn_warp "$profile")"
        fi
    fi

    # 3. Образ по дайджесту и пересоздание контейнера из state/.
    ref="${repo}@${digest}"
    log_step "$(tf upstream_step_pull "$ref")"
    if ! docker_pull_ref "$ref"; then
        [ -n "$scripts_tag" ] && ga_up_scripts_restore_previous "$sub"
        [ "$startsh_saved" = 1 ] && cp -p "$tmp/start.sh.previous" "$startsh" 2>/dev/null
        rm -rf "$tmp"
        return 1
    fi
    prev_json=$(jq -cn --arg t "$cur_tag" --arg d "$cur_digest" --arg rel "$rel_cur" --arg now "$(ga_now)" \
        '{image_tag: $t, image_digest: $d, client_release: $rel, updated_at: $now}')
    log_step "$(t upstream_step_core)"
    if ! ga_capture res amnezia_core_update "$profile" "$ref" "$tag" "$digest" "$start_source"; then
        # Откат: прежний образ уже локально (мы с него работали), скрипты — из
        # previous/. Ссылка на прежний образ — по дайджесту, а если его нет, по
        # тегу: у подхваченного из приложения профиля дайджест пуст по самому
        # договору импорта, и прежнее условие на таком профиле просто не
        # срабатывало — образ назад не возвращался, а сообщение об откате
        # печаталось всё равно. Контейнер к этому моменту уже снесён, и человек
        # не знал, что нужно вмешаться. Теперь об откате говорим ТОЛЬКО когда он
        # действительно сделан, а иначе называем контейнер и способ поднять его.
        [ -n "$scripts_tag" ] && ga_up_scripts_restore_previous "$sub"
        # Прежний start.sh — на место до отката: откат поднимает контейнер из state/, и без него start.sh
        # собрался бы заново из прежних скриптов уже без строк goWARP (SR-30).
        [ "$startsh_saved" = 1 ] && cp -p "$tmp/start.sh.previous" "$startsh" 2>/dev/null
        back_ref=""
        rolled=false
        if [ "${GA_AMN_CORE_RM_DONE:-0}" != 1 ]; then
            # Отказ до сноса контейнера: прежний работает на прежнем образе, скрипты уже возвращены — это и
            # есть откат, пересоздавать здоровый контейнер незачем.
            rolled=true
        else
            if [[ "$cur_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
                back_ref="${repo}@${cur_digest}"
            elif [ -n "$cur_tag" ] && ga_up_tag_safe "$cur_tag"; then
                back_ref="${repo}:${cur_tag}"
            fi
            if [ -n "$back_ref" ] \
               && amnezia_core_update "$profile" "$back_ref" "$cur_tag" "$cur_digest" "$rollback_source" >/dev/null; then
                rolled=true
            fi
        fi
        rm -rf "$tmp"
        if [ "$rolled" = true ]; then
            # Одним вызовом: ga_err печатает сообщение сам, а прежняя пара
            # log_error + ga_err повторяла одно и то же дважды.
            ga_err update_failed "$(tf upstream_update_failed_rolled_back "$profile")"
        else
            ga_err update_failed_no_rollback \
                "$(tf upstream_update_failed_dirty "$profile" "$(ga_profile_field "$profile" container)")"
        fi
        return 1
    fi
    # 4. Зафиксировать: previous в профиле, новый образ и релиз в images.json. Отложенный прежний start.sh
    # больше не нужен — контейнер поднят с новым.
    ga_config_merge "$(jq -cn --arg p "$profile" --argjson prev "$prev_json" '{profiles: {($p): {previous: $prev}}}')" \
        || { rm -rf "$tmp"; ga_err config_write_failed "$(t amnezia_err_config)"; return 1; }
    ga_up_images_set "$key" "$tag" "$digest" "$amd64" "$scripts_tag" || log_warning "$(tf upstream_warn_images_json "$(ga_up_images_file)")"
    rm -rf "$tmp"
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "upstream-update" "$profile ${cur_tag:--}->${tag} scripts=${scripts_tag:--}"
    log_success "$(tf upstream_updated "$profile" "$tag")"
    jq -cn --arg p "$profile" --arg c "$(ga_profile_field "$profile" container)" --arg tag "$tag" --arg d "$digest" \
        --arg pt "$cur_tag" --arg pd "$cur_digest" --arg rel "${scripts_tag:-$rel_cur}" --arg st "$scripts_tag" \
        --argjson ch "$scripts_changed" --argjson un "$unsupported" --arg b "$(basename "${backup:-}")" '
        {profile: $p, container: $c, image_tag: $tag, image_digest: $d, previous_tag: $pt, previous_digest: $pd,
         client_release: $rel, scripts: {tag: $st, changed: $ch, unsupported: $un}, backup: $b, rolled_back: false}'
}

# ── upstream_rollback ────────────────────────────────────────────────────────

# upstream_rollback <профиль> → stdout JSON {profile, container, image_tag,
# image_digest, rolled_back_from_tag, scripts_restored}. Возвращает предыдущий
# образ (хранится один шаг назад) и, если менялись скрипты, previous/ каталога.
upstream_rollback() { ga_with_config_lock _upstream_rollback_locked "$@"; }
_upstream_rollback_locked() {
    local profile="$1" prev tag digest rel key sub repo ref cur_tag res restored=false state start_source=""
    ga_profile_check_installed "$profile" || return $?
    # Демон Docker — до бэкапа и до подмены скриптов (CONTRACT §4.3): без него
    # откат всё равно не состоится, а брошенный на полпути он хуже несделанного.
    ga_capture state docker_container_state "$(ga_profile_field "$profile" container)"
    ga_amn_docker_up "$state" || return 1
    prev=$(ga_config_get ".profiles.$profile.previous" 2>/dev/null | jq -c 'if type == "object" then . else null end' 2>/dev/null)
    tag=$(jq -r '.image_tag // ""' <<<"${prev:-null}"); digest=$(jq -r '.image_digest // ""' <<<"${prev:-null}")
    rel=$(jq -r '.client_release // ""' <<<"${prev:-null}")
    if [ -z "$prev" ] || [ "$prev" = null ] || { [ -z "$digest" ] && [ -z "$tag" ]; }; then
        ga_err no_previous "$(tf upstream_err_no_previous "$profile")" 3
        return 3
    fi
    key=$(ga_up_image_key "$profile"); sub=$(ga_up_profile_dir "$profile")
    repo=$(ga_up_images_get ".[\"$key\"].repo")
    cur_tag=$(ga_config_get ".profiles.$profile.image_tag" 2>/dev/null)
    if [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then ref="${repo}@${digest}"; else ref="${repo}:${tag:-latest}"; fi
    log_step "$(tf upstream_rolling_back "$profile" "${cur_tag:--}" "${tag:--}")"
    local bk
    ga_capture bk ga_up_backup || return 1
    # Сначала образ, и только потом подмена скриптов. Обратный порядок оставлял
    # после обычного отказа загрузки (нет сети, исчерпан предел Docker Hub)
    # вендоренные скрипты уже старыми, канонический start.sh удалённым — а
    # описания в images.json по-прежнему от новой версии. Следующая установка
    # собирала контейнер старыми скриптами под новый образ; загрузка же ничего
    # на диске не меняет, поэтому её отказ обязан случиться раньше подмены.
    docker_pull_ref "$ref" || return 1
    # Скрипты возвращаем только если обновление их меняло: previous.json помнит релиз.
    if [ -n "$rel" ] && [ "$rel" != "$(ga_up_images_get '.client_release')" ] && [ -f "$(ga_up_dir)/$sub/previous/previous.json" ]; then
        ga_up_scripts_restore_previous "$sub" && restored=true
        [ "$restored" = true ] && start_source=template
    fi
    if ! ga_capture res amnezia_core_update "$profile" "$ref" "$tag" "$digest" "$start_source"; then
        # Отказ до сноса контейнера — профиль работает как работал, прежний совет верен.
        if [ "${GA_AMN_CORE_RM_DONE:-0}" != 1 ]; then
            ga_err rollback_failed "$(tf upstream_err_rollback "$profile")"
            return 1
        fi
        # Контейнер уже снесён. Раньше ответ был тем же «восстановите из бэкапа» — самым разрушительным
        # действием продукта, хотя хватает копии состояния: поднимаем профиль из неё, как «Поднять
        # заново» (находка SR-28). Не вышло — отдельный код и тот же совет словами.
        local cont
        cont=$(ga_profile_field "$profile" container)
        if amnezia_state_restore "$profile" recreate >/dev/null 2>&1 && ga_amn_wait_up "$profile" >/dev/null 2>&1; then
            ga_err rollback_failed "$(tf upstream_err_rollback_restored "$profile")"
        else
            ga_err rollback_failed_no_container "$(tf upstream_err_rollback_down "$profile" "$cont")"
        fi
        return 1
    fi
    ga_config_merge "$(jq -cn --arg p "$profile" '{profiles: {($p): {previous: null}}}')" || true
    # Глобальный закреп в images.json трогаем ТОЛЬКО с настоящим дайджестом.
    # У подхваченного из приложения профиля предыдущий образ — «latest» без
    # дайджеста, и откат такого профиля распинывал образ для ВСЕХ будущих
    # установок: profile-install начинал тянуть :latest по тегу вместо
    # дайджеста. Релиз клиента при этом вернуть надо в любом случае.
    if [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        ga_up_images_set "$key" "$tag" "$digest" "" "$rel" || true
    elif [ -n "$rel" ]; then
        ga_up_images_set "$key" "$(ga_up_images_get ".[\"$key\"].tag")" \
            "$(ga_up_images_get ".[\"$key\"].digest")" "" "$rel" || true
    fi
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "upstream-rollback" "$profile ${cur_tag:--}->${tag:--} scripts=$restored"
    log_success "$(tf upstream_rolled_back "$profile" "${tag:--}")"
    jq -cn --arg p "$profile" --arg c "$(ga_profile_field "$profile" container)" --arg tag "$tag" --arg d "$digest" \
        --arg from "$cur_tag" --argjson sr "$restored" \
        '{profile: $p, container: $c, image_tag: $tag, image_digest: $d, rolled_back_from_tag: $from, scripts_restored: $sr}'
}

# ── upstream_core_update (core-update: без смены скриптов) ───────────────────

# upstream_core_update <профиль> → пересоздать контейнер на закреплённом образе
# из images.json (тот же дайджест = ремонт контейнера без сети; другой = смена
# образа без обновления скриптов). Предыдущий образ запоминается для отката.
upstream_core_update() { ga_with_config_lock _upstream_core_update_locked "$@"; }
_upstream_core_update_locked() {
    local profile="$1" key ref tag digest cur_tag cur_digest res prev_json state
    ga_profile_check_installed "$profile" || return $?
    # Демон Docker — первым делом, ДО бэкапа и трёх попыток загрузки со сном
    # (CONTRACT §4.3). Проверка жила внутри amnezia_core_update, и на сервере,
    # где клиент и демон разошлись версиями, минута ожидания заканчивалась
    # кодом, из которого не следует лечение.
    ga_capture state docker_container_state "$(ga_profile_field "$profile" container)"
    ga_amn_docker_up "$state" || return 1
    key=$(ga_up_image_key "$profile")
    ref=$(docker_image_ref "$key") || { ga_err images_json_missing "$(tf docker_err_image_unknown "$key")" 3; return 3; }
    tag=$(ga_up_images_get ".[\"$key\"].tag"); digest=$(ga_up_images_get ".[\"$key\"].digest")
    cur_tag=$(ga_config_get ".profiles.$profile.image_tag" 2>/dev/null)
    cur_digest=$(ga_config_get ".profiles.$profile.image_digest" 2>/dev/null)
    # Профиль уже на образе НОВЕЕ закреплённого: его обновили (upstream-update), а самообновление продукта
    # вернуло images.json к закрепу своего релиза. «Ремонт» молча откатывал такой профиль назад и отвечал
    # repair:false (находка SR-30). Чиним на нынешнем образе профиля — менять образ и откатывать его
    # положено upstream-update и upstream-rollback, а не ремонту.
    local keep_newer=0
    if [[ "$cur_digest" =~ ^sha256:[0-9a-f]{64}$ ]] && [ "$cur_digest" != "$digest" ] \
       && ga_up_tag_newer "$cur_tag" "$tag"; then
        keep_newer=1
        ref="$(ga_up_images_get ".[\"$key\"].repo")@${cur_digest}"
        log_info "$(tf upstream_core_keeps_newer "$profile" "$cur_tag" "${tag:--}")"
        tag="$cur_tag"; digest="$cur_digest"
    fi
    local bk
    ga_capture bk ga_up_backup || return 1
    if [ "$keep_newer" = 1 ]; then
        # Образ профиля обычно уже лежит на сервере (мы с него работаем) — сеть не нужна.
        docker_image_exists "$ref" || docker_pull_ref "$ref" || return 1
    else
        docker_pull_pinned "$key" || return 1
    fi
    prev_json=$(jq -cn --arg t "$cur_tag" --arg d "$cur_digest" --arg rel "$(ga_up_images_get '.client_release')" --arg now "$(ga_now)" \
        '{image_tag: $t, image_digest: $d, client_release: $rel, updated_at: $now}')
    if ! ga_capture res amnezia_core_update "$profile" "$ref" "$tag" "$digest"; then
        # Отказ ДО сноса контейнера (место, копия состояния, сборка): прежний контейнер работает, откатывать
        # нечего — update_failed с причиной, без пересоздания здорового контейнера.
        if [ "${GA_AMN_CORE_RM_DONE:-0}" != 1 ]; then
            ga_err update_failed "$(tf upstream_err_core "$profile")"
            return 1
        fi
        # Контейнер к этому моменту уже снесён. «update_failed» по договору (AGENT_GUIDE §7) значит «откат
        # сделан, вмешательства не нужно» — и говорился всегда, даже когда профиль лежал и вернуть его было не
        # по чему. Теперь, как у upstream-update: пробуем поднять прежний образ (он локален — мы с него
        # работали), и только если поднялся — update_failed; иначе update_failed_no_rollback с контейнером.
        local back_repo back_ref="" rolled=false
        back_repo=$(ga_up_images_get ".[\"$key\"].repo")
        if [[ "$cur_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
            back_ref="${back_repo}@${cur_digest}"
        elif [ -n "$cur_tag" ] && ga_up_tag_safe "$cur_tag"; then
            back_ref="${back_repo}:${cur_tag}"
        fi
        if [ -n "$back_ref" ] && amnezia_core_update "$profile" "$back_ref" "$cur_tag" "$cur_digest" >/dev/null; then
            rolled=true
        fi
        if [ "$rolled" = true ]; then
            ga_err update_failed "$(tf upstream_update_failed_rolled_back "$profile")"
        else
            ga_err update_failed_no_rollback \
                "$(tf upstream_update_failed_dirty "$profile" "$(ga_profile_field "$profile" container)")"
        fi
        return 1
    fi
    if [ "$digest" != "$cur_digest" ]; then
        ga_config_merge "$(jq -cn --arg p "$profile" --argjson prev "$prev_json" '{profiles: {($p): {previous: $prev}}}')" || true
    fi
    log_success "$(tf upstream_core_done "$profile" "${tag:-?}")"
    jq -c --arg same "$([ "$digest" = "$cur_digest" ] && echo true || echo false)" '. + {repair: ($same == "true")}' <<<"$res"
}

# ── upstream_tick (goamnezia-upstream.timer, раз в сутки) ────────────────────

# upstream_tick → upstream_check, память в $GOAMNEZIA_DIR/upstream/, событие
# боту upstream_available — один раз на каждую новую пару «релиз + дайджесты»
# (notified.json), без автообновления. Сеть недоступна — только запись в лог.
# stdout JSON {checked, updates_available, notified, reachable}.
upstream_tick() {
    local work res sig last notified=false reachable=true tmp
    work=$(ga_up_work_dir)
    mkdir -p "$work" 2>/dev/null && chmod 700 "$work" 2>/dev/null
    if ! ga_capture res upstream_check; then
        reachable=false
        log_warning "$(t upstream_tick_unreachable)"
        _upstream_tick_remember false false false
        jq -cn --arg now "$(ga_now)" '{checked: $now, updates_available: false, notified: false, reachable: false}'
        return 0
    fi
    tmp=$(mktemp "$work/.last.XXXXXX" 2>/dev/null) && { printf '%s\n' "$res" >"$tmp"; chmod 600 "$tmp"; mv -f "$tmp" "$(ga_up_last_check)"; }
    if [ "$(jq -r '.updates_available // false' <<<"$res")" = true ]; then
        sig=$(jq -r '[(.client_release.tag // ""), (.images | to_entries | map(.key + "=" + (.value.latest_digest // "")) | join(","))] | join("|")' <<<"$res")
        last=$(jq -r '.sig // ""' "$(ga_up_notified)" 2>/dev/null)
        if [ "$sig" != "$last" ]; then
            ga_notify upstream_available "$(jq -c '{client_release_current: (.client_release.current // ""),
                client_release_latest: (.client_release.tag // ""),
                profiles: [.profiles[] | {profile, current_tag, available_tag, update}],
                unsupported: [.unsupported[]?.name] | unique}' <<<"$res")" && notified=true
            tmp=$(mktemp "$work/.ntf.XXXXXX" 2>/dev/null) && { jq -cn --arg s "$sig" --arg now "$(ga_now)" '{sig: $s, at: $now}' >"$tmp"; chmod 600 "$tmp"; mv -f "$tmp" "$(ga_up_notified)"; }
            log_info "$(t upstream_tick_notified)"
        fi
    else
        log_dim "$(t upstream_tick_current)"
    fi
    _upstream_tick_remember true "$(jq -c '.updates_available // false' <<<"$res")" "$notified"
    jq -cn --arg now "$(ga_now)" --argjson up "$(jq -c '.updates_available // false' <<<"$res")" --argjson n "$notified" --argjson r "$reachable" \
        '{checked: $now, updates_available: $up, notified: $n, reachable: $r}'
}

# _upstream_tick_remember <reachable> <updates_available> <notified> — итог попытки в last_tick.json (0600,
# атомарно): экранам нужно и «когда проверяли в последний раз», и «удалось ли» (L-07), а last_check.json
# хранит только удачную проверку.
_upstream_tick_remember() {
    local work tmp
    work=$(ga_up_work_dir)
    mkdir -p "$work" 2>/dev/null || return 0
    tmp=$(mktemp "$work/.tick.XXXXXX" 2>/dev/null) || return 0
    # 2>/dev/null ДО перенаправления в файл: иначе ошибку самого перенаправления оболочка печатала бы человеку
    if jq -cn --arg now "$(ga_now)" --argjson r "${1:-false}" --argjson up "${2:-false}" --argjson n "${3:-false}" \
        '{at: $now, reachable: $r, updates_available: $up, notified: $n}' 2>/dev/null >"$tmp"; then
        chmod 600 "$tmp"
        mv -f "$tmp" "$(ga_up_last_tick)"
    else
        rm -f "$tmp"
    fi
    return 0
}

# Последний результат проверки без сети (для экранов) → JSON или null.
upstream_last_check() {
    local f
    f=$(ga_up_last_check)
    if [ -f "$f" ] && jq -e . "$f" >/dev/null 2>&1; then cat "$f"; else echo null; fi
}

# upstream_summary → итог суточной проверки для status (L-07) без сети: null — ни одной попытки ещё не было;
# иначе {checked — время последней УДАЧНОЙ проверки (пусто — удачных не было), attempted и reachable —
# последняя попытка и удалась ли она, updates_available, hint (слова ядра), client_release {current, latest,
# update}, profiles [{profile, current_tag, available_tag, update}], unsupported [имена]}. Полный отчёт —
# upstream-check (сеть) или upstream-check --cached=on (он же, без сети).
upstream_summary() {
    local last tick
    last=$(upstream_last_check 2>/dev/null) || last=null
    tick=null
    [ -f "$(ga_up_last_tick)" ] && tick=$(jq -c 'if type == "object" then . else null end' "$(ga_up_last_tick)" 2>/dev/null)
    [ -n "$tick" ] || tick=null
    jq -cn --argjson l "${last:-null}" --argjson t "$tick" '
        if $l == null and $t == null then null else
        {checked: ($l.checked // ""),
         attempted: ($t.at // $l.checked // ""),
         reachable: (if $t != null then ($t.reachable == true) else ($l != null) end),
         updates_available: ($l.updates_available == true),
         hint: ($l.hint // ""),
         hint_key: ($l.hint_key // ""),
         client_release: (if ($l.client_release | type) == "object"
                          then {current: ($l.client_release.current // ""), latest: ($l.client_release.tag // ""),
                                update: ($l.client_release.update == true)} else null end),
         profiles: [($l.profiles // [])[]? | select(type == "object")
                    | {profile: (.profile // ""), current_tag: (.current_tag // ""),
                       available_tag: (.available_tag // ""), update: (.update == true)}],
         unsupported: [($l.unsupported // [])[]? | (.name? // .) | select(type == "string")] | unique}
        end' 2>/dev/null || printf 'null'
}
