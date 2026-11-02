#!/bin/bash
# templates_lib.sh — переносимая библиотека шаблонов сайта-маскировки (goTelegram Pro → серия скриптов).
# Копия scripts/templates_lib.sh из навыка site-templates-library (03.09.2026).
# В goAmnezia pro изменены ТОЛЬКО пути и имена под наш неймспейс (решение
# владельца: база и код проверки шаблонов берутся как есть, без перепроверки):
#   • каталог по умолчанию — ../templates_catalog.json (лежит рядом с install.sh,
#     как в контракте §1), с переопределением через GOAMNEZIA_CATALOG;
#   • корень сайта по умолчанию — GOAMNEZIA_SITE_ROOT / SITE_ROOT
#     (/var/www/goamnezia-site вместо /var/www/site);
#   • маркеры в корне сайта — .goamnezia_template_id / .goamnezia_template_source;
#   • префиксы временных каталогов — goamnezia_* вместо gotelegram_*;
#   • директивы shellcheck на трёх строках, чтобы tests/run_static.sh был чист;
#   • добавлены умолчания CUSTOM_GIT_MAX_SIZE_MB / CUSTOM_GIT_CLONE_TIMEOUT —
#     в навыке их не было вовсе, см. пояснение у объявления (0.4.2, 22.09.2026).
# Логику _tpl_pick_index_dir / _tpl_page_ok / strip_template_service_files /
# deploy_template_to_nginx не менять — это и есть гарантия качества базы.
# Самодостаточна: подключается одним `source`, нужны bash ≥ 4, jq, git, curl.
# Переменные (переопределяйте ДО source или после — читаются при вызове):
#   CATALOG_FILE   — путь к templates_catalog.json (по умолчанию рядом: ../templates_catalog.json)
#   WEBSITE_ROOT   — куда разворачивать сайт (по умолчанию /var/www/goamnezia-site)
#   TEMPLATES_LANG — ru|en для текстов меню (по умолчанию ru)
#   TEMPLATES_CACHE — каталог для скачанных шаблонов (по умолчанию mktemp -d)
#   CUSTOM_GIT_MAX_SIZE_MB / CUSTOM_GIT_CLONE_TIMEOUT — лимит (МБ) и таймаут (с)
#                     для своего шаблона по git URL (по умолчанию 100 / 90)
# Точки входа: interactive_template_selection (меню категорий/списка/поиска → путь к папке шаблона),
#   download_template <id> [dir] (→ путь или код причины в TEMPLATE_DL_ERROR и файле .last_error),
#   deploy_template_to_nginx <dir> [id] (копирует в WEBSITE_ROOT и вычищает служебные файлы),
#   pick_random_template_id, get_categories, get_templates_by_category <cat>, get_template_info <id>.
# Логи/цвета/тексты — заглушки ниже срабатывают только если хост-скрипт их не определил.

_TPL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG_FILE="${CATALOG_FILE:-${GOAMNEZIA_CATALOG:-$_TPL_LIB_DIR/../templates_catalog.json}}"
WEBSITE_ROOT="${WEBSITE_ROOT:-${GOAMNEZIA_SITE_ROOT:-${SITE_ROOT:-/var/www/goamnezia-site}}}"
TEMPLATES_LANG="${TEMPLATES_LANG:-ru}"
TEMPLATE_DL_ERROR=""
# Свой шаблон по git URL: лимит размера репозитория (МБ) и таймаут клонирования
# (секунды). В goVLESS/goTelegram эти две константы живут в отдельном
# lib/templates_catalog.sh, а в переносимой библиотеке из навыка их не было
# вовсе: под set -u первая же роняла установку своего сайта прямо на строке
# `timeout "$CUSTOM_GIT_CLONE_TIMEOUT" git clone …` («unbound variable») —
# и только на сервере: на macOS нет GNU timeout, ветка другая, локально ошибка
# не проявлялась. Именно `:-`, а не `=`: пустое значение тут не «выключено»,
# а сломанный вызов timeout, поэтому пустое тоже заменяем умолчанием.
# Текст custom_git_too_big в словаре называет лимит «100MB» — менять вместе.
CUSTOM_GIT_MAX_SIZE_MB="${CUSTOM_GIT_MAX_SIZE_MB:-100}"
CUSTOM_GIT_CLONE_TIMEOUT="${CUSTOM_GIT_CLONE_TIMEOUT:-90}"
# Умолчания цветов — ТОЛЬКО для НЕОБЪЯВЛЕННЫХ переменных: `${VAR=…}`, а не
# `${VAR=…}`. Разница в одном двоеточии, но она решающая — `:=`, а оно срабатывает и на ПУСТОМ значении: lib/common.sh выключал
# раскраску (GOAMNEZIA_COLOR=never, NO_COLAR/NO_COLOR, TERM=dumb, вывод не в
# терминал) и присваивал пустые строки, а эти строки тут же возвращали цвета
# обратно. Выключатель не работал вовсе, и `goamnezia > отчёт.txt` давал файл с
# управляющими последовательностями.
: "${RED=$'\033[0;31m'}" "${GREEN=$'\033[0;32m'}" "${YELLOW=$'\033[1;33m'}" "${BLUE=$'\033[0;34m'}" "${MAGENTA=$'\033[0;35m'}" "${CYAN=$'\033[0;36m'}" "${WHITE=$'\033[1;37m'}" "${BOLD=$'\033[1m'}" "${DIM=$'\033[2m'}" "${NC=$'\033[0m'}"
type log_info    >/dev/null 2>&1 || log_info()    { echo -e "  ${CYAN}ℹ${NC} $*" >&2; }
type log_success >/dev/null 2>&1 || log_success() { echo -e "  ${GREEN}✓${NC} $*" >&2; }
type log_warning >/dev/null 2>&1 || log_warning() { echo -e "  ${YELLOW}⚠${NC} $*" >&2; }
type log_error   >/dev/null 2>&1 || log_error()   { echo -e "  ${RED}✗${NC} $*" >&2; }
type log_dim     >/dev/null 2>&1 || log_dim()     { echo -e "  ${DIM}$*${NC}" >&2; }
type log_step    >/dev/null 2>&1 || log_step()    { echo -e "\n  ${BOLD}${WHITE}$*${NC}" >&2; }
if ! type t >/dev/null 2>&1; then
declare -A _TPL_I18N_RU=(
    [custom_git_title]="📎 СВОЙ ШАБЛОН ПО GIT URL"
    [custom_git_requirements]="Требования:"
    [custom_git_req_4]="  • Статический HTML (без серверного кода PHP/Python/Node)"
    [custom_git_req_3]="  • Размер репо не более 100 МБ"
    [custom_git_req_2]="  • Только публичные репозитории"
    [custom_git_req_1]="  • Только HTTPS (ssh:// и git:// блокируются)"
    [custom_git_help_3]="готовый index.html (сборка через npm НЕ выполняется)."
    [custom_git_help_2]="в качестве шаблона. Репозиторий должен быть публичным и содержать"
    [custom_git_help_1]="Вы можете использовать ЛЮБОЙ репозиторий со статическим HTML-сайтом"
    [custom_git_formats]="Поддерживаемые форматы URL:"
    [custom_git_fmt_gitlab]="  • https://gitlab.com/user/repo"
    [custom_git_fmt_github]="  • https://github.com/user/repo"
    [custom_git_fmt_gitext]="  • https://example.com/user/repo.git"
    [custom_git_fmt_branch]="  • https://github.com/user/repo@branch  (ветка после @)"
    [custom_git_examples]="Примеры проверенных репо:"
    [custom_git_ex_2]="  • https://github.com/StartBootstrap/startbootstrap-landing-page"
    [custom_git_ex_1]="  • https://github.com/StartBootstrap/startbootstrap-freelancer"
    [custom_git_auto_detect]="Структура репозитория (авто-определение):"
    [custom_git_auto_4]="  4. Fallback: поиск index.html по всему репозиторию"
    [custom_git_auto_3]="  3. public/ или build/ или _site/ или site/ или docs/"
    [custom_git_auto_2]="  2. dist/index.html (StartBootstrap, Vite, webpack)"
    [custom_git_auto_1]="  1. index.html в корне репозитория"
    [choose]="Выбор"
    [back]="« Назад"
    [custom_git_bad_url]="Недопустимый URL. Принимаются только https:// адреса"
    [custom_git_clone_failed]="Не удалось клонировать репозиторий: %s"
    [custom_git_cloning]="Клонирование репозитория..."
    [custom_git_empty]="URL не указан, отмена"
    [custom_git_enter_url]="Вставьте git URL (или Enter для отмены):"
    [custom_git_found_at]="✓ Найден index.html в: %s"
    [custom_git_installed]="Свой шаблон установлен из %s"
    [custom_git_no_index]="index.html не найден в репозитории"
    [custom_git_scanning]="Поиск index.html в структуре..."
    [custom_git_too_big]="Репозиторий слишком большой: %s (лимит 100MB)"
    [invalid_choice]="Неверный выбор"
    [templates_app_shell]="В шаблоне «%s» страница есть, но это оболочка приложения без содержимого — в браузере будет пустой экран."
    [templates_broken_assets]="В шаблоне «%s» страница ссылается на стили и скрипты, которых в репозитории нет — сайт откроется голым."
    [templates_cat_empty]="В этой категории нет шаблонов"
    [templates_catalog_not_found]="Каталог шаблонов не найден: %s"
    [templates_categories]="📂 Категории шаблонов сайтов:"
    [templates_count_fmt]="(%d шаблонов)"
    [templates_custom_git]="📎 Свой шаблон по git URL"
    [templates_deployed]="Шаблон развёрнут в %s"
    [templates_description]="Описание:"
    [templates_download_failed]="Шаблон «%s» не скачался: репозиторий недоступен или нет связи с GitHub."
    [templates_downloaded]="Шаблон \"%s\" скачан"
    [templates_downloaded_subfolder]="Шаблон \"%s\" скачан (из подпапки)"
    [templates_downloading]="Скачивание шаблона \"%s\"..."
    [templates_err_no_index]="В каталоге шаблона нет index.html: %s"
    [templates_err_repo_url]="Шаблон «%s»: недопустимый repo_url — ожидается адрес https:// без пробелов и служебных символов"
    [templates_err_repo_url_bad]="Небезопасный или пустой repo_url шаблона: %s"
    [templates_filter_line]="Поиск: «%s» — найдено %s"
    [templates_install_this]="Установить этот шаблон?"
    [templates_license]="Лицензия:"
    [templates_list]="📋 %s — доступные шаблоны:"
    [templates_name]="Название:"
    [templates_nav_hint]="номер — выбрать · n / p — дальше / назад · слово — поиск по названию · r — случайный · 0 — назад"
    [templates_not_static]="В шаблоне «%s» нет готовой страницы index.html — в репозитории исходники для сборки, а не сайт."
    [templates_nothing_found]="Ничего не найдено — введите другое слово или 0"
    [templates_page_line]="Страница %s из %s · всего %s"
    [templates_pick_another]="Выберите другой шаблон."
    [templates_preview]="👁  Превью:"
    [templates_preview_hint]="Откройте ссылку в браузере для просмотра шаблона"
    [templates_preview_title]="🔍 Превью шаблона:"
    [templates_random]="🎲 Случайный шаблон"
    [templates_repo]="📦 Репо:"
    [templates_repo_line]="Репозиторий: %s"
    [templates_site_backup]="Прежний сайт сохранён в %s"
    [templates_source]="Источник:"
    [templates_thanks]="💜 Спасибо авторам %s за открытый код!"
    [templates_try_another]="Выбрать другой шаблон из этой категории?"
)
declare -A _TPL_I18N_EN=(
    [custom_git_title]="📎 CUSTOM TEMPLATE FROM GIT URL"
    [custom_git_requirements]="Requirements:"
    [custom_git_req_4]="  • Static HTML (no PHP/Python/Node server code)"
    [custom_git_req_3]="  • Repo size up to 100 MB"
    [custom_git_req_2]="  • Public repositories only"
    [custom_git_req_1]="  • HTTPS only (ssh:// and git:// are blocked)"
    [custom_git_help_3]="index.html (build via npm is NOT performed)."
    [custom_git_help_2]="The repository must be public and contain a ready-made"
    [custom_git_help_1]="You can use ANY public static HTML repository as a template."
    [custom_git_formats]="Supported URL formats:"
    [custom_git_fmt_gitlab]="  • https://gitlab.com/user/repo"
    [custom_git_fmt_github]="  • https://github.com/user/repo"
    [custom_git_fmt_gitext]="  • https://example.com/user/repo.git"
    [custom_git_fmt_branch]="  • https://github.com/user/repo@branch  (branch after @)"
    [custom_git_examples]="Tested example repos:"
    [custom_git_ex_2]="  • https://github.com/StartBootstrap/startbootstrap-landing-page"
    [custom_git_ex_1]="  • https://github.com/StartBootstrap/startbootstrap-freelancer"
    [custom_git_auto_detect]="Repository structure (auto-detection):"
    [custom_git_auto_4]="  4. Fallback: search index.html across whole repo"
    [custom_git_auto_3]="  3. public/ or build/ or _site/ or site/ or docs/"
    [custom_git_auto_2]="  2. dist/index.html (StartBootstrap, Vite, webpack)"
    [custom_git_auto_1]="  1. index.html in repo root"
    [choose]="Choose"
    [back]="« Back"
    [custom_git_bad_url]="Invalid URL. Only https:// addresses are accepted"
    [custom_git_clone_failed]="Failed to clone repository: %s"
    [custom_git_cloning]="Cloning repository..."
    [custom_git_empty]="No URL provided, cancelled"
    [custom_git_enter_url]="Paste git URL (or Enter to cancel):"
    [custom_git_found_at]="✓ Found index.html in: %s"
    [custom_git_installed]="Custom template installed from %s"
    [custom_git_no_index]="index.html not found in the repository"
    [custom_git_scanning]="Scanning for index.html..."
    [custom_git_too_big]="Repository is too large: %s (limit 100MB)"
    [invalid_choice]="Invalid choice"
    [templates_app_shell]="Template "
    [templates_broken_assets]="Template "
    [templates_cat_empty]="No templates in this category"
    [templates_catalog_not_found]="Templates catalog not found: %s"
    [templates_categories]="📂 Site template categories:"
    [templates_count_fmt]="(%d templates)"
    [templates_custom_git]="📎 Custom template from git URL"
    [templates_deployed]="Template deployed to %s"
    [templates_description]="Description:"
    [templates_download_failed]="Template "
    [templates_downloaded]="Template \"%s\" downloaded"
    [templates_downloaded_subfolder]="Template \"%s\" downloaded (from subfolder)"
    [templates_downloading]="Downloading template \"%s\"..."
    [templates_err_no_index]="The template directory has no index.html: %s"
    [templates_err_repo_url]="Template %s: invalid repo_url — an https:// address without spaces or shell characters is expected"
    [templates_err_repo_url_bad]="Unsafe or empty template repo_url: %s"
    [templates_filter_line]="Search: "
    [templates_install_this]="Install this template?"
    [templates_license]="License:"
    [templates_list]="📋 %s — available templates:"
    [templates_name]="Name:"
    [templates_nav_hint]="number — pick · n / p — next / previous · word — search by name · r — random · 0 — back"
    [templates_not_static]="Template "
    [templates_nothing_found]="Nothing found — type another word or 0"
    [templates_page_line]="Page %s of %s · %s total"
    [templates_pick_another]="Pick another template."
    [templates_preview]="👁  Preview:"
    [templates_preview_hint]="Open the link in a browser to preview the template"
    [templates_preview_title]="🔍 Template preview:"
    [templates_random]="🎲 Random template"
    [templates_repo]="📦 Repo:"
    [templates_repo_line]="Repository: %s"
    [templates_site_backup]="The previous site was saved to %s"
    [templates_source]="Source:"
    [templates_thanks]="💜 Thanks to the authors of %s for the open source code!"
    [templates_try_another]="Pick another template from this category?"
)
t()  { local k="$1"; if [ "$TEMPLATES_LANG" = "en" ]; then printf '%s' "${_TPL_I18N_EN[$k]:-${_TPL_I18N_RU[$k]:-$k}}"; else printf '%s' "${_TPL_I18N_RU[$k]:-$k}"; fi; }
tf() { local k="$1"; shift; printf "$(t "$k")" "$@"; }
fi
# _t_or — перевод с запасным текстом (нужен confirm); заглушка, если хоста нет
type _t_or >/dev/null 2>&1 || _t_or() { local v; v=$(t "$1" 2>/dev/null); [ -n "$v" ] && [ "$v" != "$1" ] && printf '%s' "$v" || printf '%s' "$2"; }
# confirm — заглушка, если хост не определил (читает ответ с /dev/tty, как в goTelegram)
if ! type confirm >/dev/null 2>&1; then
confirm() {
    local default_msg
    default_msg=$(_t_or install_continue_anyway 'Continue?')
    local msg="${1:-$default_msg}"
    local ans=""
    echo -ne "  ${msg} [1/0]: " >&2
    # Читаем из управляющего терминала, а не из stdin: при запуске через bootstrap
    # (exec bash) / пайп stdin может не быть tty, и обычный read получал EOF -> пусто
    # -> [Y/n] трактовал как Yes и ставил/менял БЕЗ согласия. Нет tty/ввода -> No.
    if [ -r /dev/tty ]; then
        IFS= read -r ans </dev/tty || ans="n"
    else
        IFS= read -r ans || ans="n"
    fi
    # Согласие только явное y/yes/д/да: «нет»/«н»/«отмена» не матчили ^[Nn] и сходили за ДА при необратимых операциях
    ans="$(printf '%s' "$ans" | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
    # литералы вместо классов [Дд]: класс с кириллицей матчит побайтово и вне UTF-8 локали пропускает «н» как согласие
    case "$ans" in
        1|y|yes|д|да) return 0 ;;
        *) return 1 ;;
    esac
}
fi
# ── ниже — код goTelegram Pro 2.10.45 (lib/templates_catalog.sh, lib/website.sh) без изменений ──
_templates_cache_dir() {
    if [ -z "${TEMPLATES_CACHE:-}" ] || [ ! -d "$TEMPLATES_CACHE" ]; then
        TEMPLATES_CACHE=$(mktemp -d "${TMPDIR:-/tmp}/goamnezia_templates.XXXXXXXX") || return 1
        chmod 700 "$TEMPLATES_CACHE" 2>/dev/null || true
    fi
    printf '%s' "$TEMPLATES_CACHE"
}

load_catalog() {
    if [ ! -f "$CATALOG_FILE" ]; then
        # Без развилки «есть ли tf»: если её нет у хоста, библиотека определила
        # свою выше — а английская строка прямо здесь означала бы ответ мимо
        # словаря (в русском интерфейсе — по-английски).
        log_error "$(tf templates_catalog_not_found "$CATALOG_FILE")"
        return 1
    fi
    return 0
}

get_categories() {
    jq -r '.categories[] | "\(.id)|\(.name)|\(.icon)|\(.templates | length)"' "$CATALOG_FILE" 2>/dev/null
}

get_category_name() {
    local cat_id="$1"
    jq -r --arg id "$cat_id" '.categories[] | select(.id == $id) | .name' "$CATALOG_FILE" 2>/dev/null
}

get_templates_by_category() {
    local cat_id="$1"
    jq -r --arg id "$cat_id" '.categories[] | select(.id == $id) | .templates[] | "\(.id)|\(.name)|\(.source)|\(.preview_url)"' "$CATALOG_FILE" 2>/dev/null
}

get_template_info() {
    local tpl_id="$1"
    jq --arg id "$tpl_id" '.categories[].templates[] | select(.id == $id)' "$CATALOG_FILE" 2>/dev/null
}

get_template_field() {
    local tpl_id="$1"
    local field="$2"
    jq -r --arg id "$tpl_id" --arg f "$field" '.categories[].templates[] | select(.id == $id) | .[$f]' "$CATALOG_FILE" 2>/dev/null
}

_tpl_repo_url_ok() {
    local u="${1:-}"
    [ -n "$u" ] || return 1
    [ "${#u}" -le 512 ] || return 1
    [[ "$u" =~ ^https:// ]] || return 1
    # никаких shell-метасимволов и пробелов в URL
    [[ "$u" =~ [[:space:]\;\`\$\(\)\<\>\|\\\&\'\"] ]] && return 1
    return 0
}

_tpl_git_clone() {
    local url="${1:-}" dest="${2:-}"
    shift 2 2>/dev/null || return 1
    if ! _tpl_repo_url_ok "$url"; then
        log_error "$(tf templates_err_repo_url_bad "${url:--}")"
        return 1
    fi
    if [ "${GOAMNEZIA_DRY_RUN:-0}" != 1 ] && type deps_install_missing >/dev/null 2>&1 \
        && { ! command -v git >/dev/null 2>&1 || { type _deps_check_cmd >/dev/null 2>&1 && ! _deps_check_cmd git; }; }; then
        deps_install_missing --yes templates >&2 || return 1
    fi
    # Ошибку git сохраняем: вызывающие глушат stderr, и человек видел
    # «нет index.html» там, где на самом деле не было связи с GitHub.
    _TPL_GIT_ERR="${_TPL_GIT_ERR:-$(mktemp "${TMPDIR:-/tmp}/goamnezia_git_err.XXXXXXXX" 2>/dev/null)}"
    GIT_TERMINAL_PROMPT=0 git \
        -c protocol.allow=never \
        -c protocol.https.allow=always \
        -c protocol.ext.allow=never \
        -c protocol.file.allow=never \
        clone --depth 1 "$@" -- "$url" "$dest" 2>"${_TPL_GIT_ERR:-/dev/null}"
}

_tpl_pick_index_dir() {
    local base="$1" d
    for d in dist build . html theme live public_html site _site; do
        [ -f "$base/$d/index.html" ] && { printf '%s' "$base/$d"; return 0; }
    done
    # Два прохода: сначала минуя документацию, исходники и примеры; если пусто —
    # ещё раз, разрешив examples/ и docs/ (у части шаблонов страницы лежат там).
    d=$(find "$base" -mindepth 2 -maxdepth 5 -type f -name index.html \
        -not -path '*/documentation/*' -not -path '*/docs/*' -not -path '*/src/*' \
        -not -path '*/public/*' -not -path '*/node_modules/*' -not -path '*/.github/*' \
        -not -path '*/test/*' -not -path '*/tests/*' -not -path '*/example*' -not -path '*/.git/*' 2>/dev/null \
        | awk '{ print gsub("/","/") "\t" $0 }' | sort -n | head -1 | cut -f2-)
    [ -z "$d" ] && d=$(find "$base" -mindepth 2 -maxdepth 5 -type f -name index.html \
        -not -path '*/documentation/*' -not -path '*/src/*' -not -path '*/node_modules/*' \
        -not -path '*/.github/*' -not -path '*/.git/*' 2>/dev/null \
        | awk '{ print gsub("/","/") "\t" $0 }' | sort -n | head -1 | cut -f2-)
    [ -n "$d" ] && { printf '%s' "$(dirname "$d")"; return 0; }
    # index.html нет, но есть home.html / main.html — это та же главная
    for d in home.html main.html Home.html; do
        [ -f "$base/$d" ] && { cp "$base/$d" "$base/index.html" 2>/dev/null && printf '%s' "$base" && return 0; }
    done
    return 1
}

_tpl_page_ok() {
    local dir="$1" idx="$1/index.html" txt refs missing=0 total=0 ref f
    [ -f "$idx" ] || { TEMPLATE_DL_ERROR="no_index"; return 1; }
    if grep -q '%PUBLIC_URL%' "$idx" 2>/dev/null || grep -qE 'src="\.?/?src/[^"]*\.(jsx?|tsx?)"' "$idx" 2>/dev/null; then
        TEMPLATE_DL_ERROR="app_shell"; return 1
    fi
    txt=$(sed -e 's/<script[^>]*>.*<\/script>//g' -e 's/<style[^>]*>.*<\/style>//g' -e 's/<[^>]*>/ /g' "$idx" 2>/dev/null | tr -s ' \t\n' ' ' | wc -c)
    if [ "${txt:-0}" -lt 300 ] && ! grep -qiE '<img|background(-image)?:' "$idx" 2>/dev/null; then
        TEMPLATE_DL_ERROR="app_shell"; return 1
    fi
    # локальные css/js: если их несколько и НИ ОДНОГО нет на месте — вёрстка битая
    refs=$(grep -oiE '(href|src)="[^"#?:]+\.(css|js)(\?[^"]*)?"' "$idx" 2>/dev/null | sed -E 's/^[a-zA-Z]+="//; s/"$//; s/\?.*$//' | grep -vE '^(https?:)?//' | head -20)
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        total=$((total+1)); f="$dir/${ref#/}"
        [ -f "$f" ] || missing=$((missing+1))
    done <<< "$refs"
    if [ "$total" -ge 2 ] && [ "$missing" -eq "$total" ]; then
        TEMPLATE_DL_ERROR="broken_assets"; return 1
    fi
    return 0
}

download_template() {
    local tpl_id="$1"
    local output_dir="${2:-}"
    if [ -z "$output_dir" ]; then
        _templates_cache_dir >/dev/null || return 1
        output_dir="$TEMPLATES_CACHE"
    fi
    local info
    info=$(get_template_info "$tpl_id")

    local repo_url sparse_path source name
    repo_url=$(echo "$info" | jq -r '.repo_url // empty')
    sparse_path=$(echo "$info" | jq -r '.sparse_path // empty')
    source=$(echo "$info" | jq -r '.source // empty')
    name=$(echo "$info" | jq -r '.name // empty')

    # Шаблон обязан иметь https-репозиторий: всё остальное — потенциальный RCE
    if ! _tpl_repo_url_ok "$repo_url"; then
        log_error "$(tf templates_err_repo_url "$tpl_id")"
        return 1
    fi

    local clone_dir="$output_dir/${tpl_id}"
    rm -rf "$clone_dir"
    mkdir -p "$clone_dir"
    # Скачался ли репозиторий вообще — отдельно от «нашлась ли страница»:
    # файлы в clone_dir появляются только когда index.html найден, и по нему
    # клон от отсутствия страницы не отличить.
    _TPL_CLONED=0
    # shellcheck disable=SC2010  # код навыка: имена файлов клона предсказуемы, ls|grep здесь безопасен
    _tpl_mark_cloned() { [ -n "$(ls -A "$1" 2>/dev/null | grep -v '^\.git$')" ] && _TPL_CLONED=1; return 0; }

    log_info "$(tf templates_downloading "$name")"

    # HTML5 UP — one repo with folders
    if [ "$source" = "html5up" ]; then
        local tmp_clone
        tmp_clone=$(mktemp -d "${TMPDIR:-/tmp}/goamnezia_html5up.XXXXXXXX") || return 1

        # Sparse checkout
        if ! _tpl_git_clone "$repo_url" "$tmp_clone" --filter=blob:none --sparse 2>/dev/null; then
            # Fallback: full clone (в уже созданный пустой каталог)
            rm -rf "$tmp_clone"; mkdir -p "$tmp_clone"
            _tpl_git_clone "$repo_url" "$tmp_clone" 2>/dev/null
        fi

        if [ -d "$tmp_clone" ]; then
            git -C "$tmp_clone" sparse-checkout set "$sparse_path" 2>/dev/null
            _tpl_mark_cloned "$tmp_clone"
            if [ -d "$tmp_clone/$sparse_path" ]; then
                cp -r "$tmp_clone/$sparse_path/." "$clone_dir/"
            fi
        fi
        rm -rf "$tmp_clone"

    # learning-zone — one big repo
    elif [ "$source" = "learning-zone" ]; then
        local tmp_clone
        tmp_clone=$(mktemp -d "${TMPDIR:-/tmp}/goamnezia_lz.XXXXXXXX") || return 1

        if ! _tpl_git_clone "$repo_url" "$tmp_clone" --filter=blob:none --sparse 2>/dev/null; then
            rm -rf "$tmp_clone"; mkdir -p "$tmp_clone"
            _tpl_git_clone "$repo_url" "$tmp_clone" 2>/dev/null
        fi

        if [ -d "$tmp_clone" ]; then
            git -C "$tmp_clone" sparse-checkout set "$sparse_path" 2>/dev/null
            _tpl_mark_cloned "$tmp_clone"
            if [ -d "$tmp_clone/$sparse_path" ]; then
                cp -r "$tmp_clone/$sparse_path/." "$clone_dir/"
            fi
        fi
        rm -rf "$tmp_clone"

    # StartBootstrap — each template in its own repo
    elif [ "$source" = "startbootstrap" ]; then
        local sb_tmp
        sb_tmp=$(mktemp -d "${TMPDIR:-/tmp}/goamnezia_sb.XXXXXXXX") || return 1
        _tpl_git_clone "$repo_url" "$sb_tmp" 2>/dev/null
        if [ -d "$sb_tmp" ]; then
            _tpl_mark_cloned "$sb_tmp"
            rm -rf "$sb_tmp/.git"
            local sb_dir
            if sb_dir=$(_tpl_pick_index_dir "$sb_tmp"); then
                cp -r "$sb_dir/." "$clone_dir/"
            fi
        fi
        rm -rf "$sb_tmp"

    # ThemeWagon / ColorlibHQ / github — each template in its own repo.
    # «github» — общий источник для шаблонов, найденных по всему GitHub: клон
    # целиком, страница в корне либо в dist/public/docs/build.
    elif [ "$source" = "themewagon" ] || [ "$source" = "colorlib" ] || [ "$source" = "github" ]; then
        local tw_tmp
        tw_tmp=$(mktemp -d "${TMPDIR:-/tmp}/goamnezia_tw.XXXXXXXX") || return 1
        _tpl_git_clone "$repo_url" "$tw_tmp" 2>/dev/null
        if [ -d "$tw_tmp" ]; then
            _tpl_mark_cloned "$tw_tmp"
            rm -rf "$tw_tmp/.git"
            local tw_dir
            if tw_dir=$(_tpl_pick_index_dir "$tw_tmp"); then
                cp -r "$tw_dir/." "$clone_dir/"
            fi
        fi
        rm -rf "$tw_tmp"

    # dawidolko — one big repo with folders (similar to learning-zone)
    elif [ "$source" = "dawidolko" ]; then
        local tmp_clone
        tmp_clone=$(mktemp -d "${TMPDIR:-/tmp}/goamnezia_dw.XXXXXXXX") || return 1
        if ! _tpl_git_clone "$repo_url" "$tmp_clone" --filter=blob:none --sparse 2>/dev/null; then
            rm -rf "$tmp_clone"; mkdir -p "$tmp_clone"
            _tpl_git_clone "$repo_url" "$tmp_clone" 2>/dev/null
        fi
        if [ -d "$tmp_clone" ]; then
            git -C "$tmp_clone" sparse-checkout set "$sparse_path" 2>/dev/null
            _tpl_mark_cloned "$tmp_clone"
            if [ -d "$tmp_clone/$sparse_path" ]; then
                cp -r "$tmp_clone/$sparse_path/." "$clone_dir/"
            fi
        fi
        rm -rf "$tmp_clone"
    fi

    # Check result: страница не только есть, но и готова (не оболочка, не битая)
    rm -rf "$clone_dir/.git" 2>/dev/null || true
    TEMPLATE_DL_ERROR=""
    if [ -f "$clone_dir/index.html" ] && _tpl_page_ok "$clone_dir"; then
        log_success "$(tf templates_downloaded "$name")"
        echo "$clone_dir"
        return 0
    elif [ -f "$clone_dir/index.html" ]; then
        printf '%s' "$TEMPLATE_DL_ERROR" > "$output_dir/.last_error" 2>/dev/null || true
        case "$TEMPLATE_DL_ERROR" in
            broken_assets) log_error "$(tf templates_broken_assets "$name")" ;;
            *)             log_error "$(tf templates_app_shell "$name")" ;;
        esac
        log_dim "$(t templates_pick_another)"
        rm -rf "$clone_dir" 2>/dev/null || true
        return 1
    else
        # fallback: страница в подпапке (нестандартная структура)
        local fallback_dir
        if fallback_dir=$(_tpl_pick_index_dir "$clone_dir") && [ "$fallback_dir" != "$clone_dir" ] && [ "$fallback_dir" != "$clone_dir/." ]; then
            cp -r "$fallback_dir/." "$clone_dir/"
            if _tpl_page_ok "$clone_dir"; then
                log_success "$(tf templates_downloaded_subfolder "$name")"
                echo "$clone_dir"
                return 0
            fi
        fi
        # Две разные беды под одной надписью «нет index.html» путали людей:
        # пустой каталог — репозиторий не скачался (сеть, GitHub, репозиторий
        # удалён); файлы есть, а страницы нет — в каталог попали исходники для
        # сборки (Next.js, Vite, Tailwind-стартеры), готового сайта там нет.
        TEMPLATE_DL_ERROR="no_index"
        [ "${_TPL_CLONED:-0}" = "1" ] || TEMPLATE_DL_ERROR="download_failed"
        # download_template почти всегда зовут через $(...): переменная из
        # подоболочки не доходит, поэтому код причины дублируем в файл.
        printf '%s' "$TEMPLATE_DL_ERROR" > "$output_dir/.last_error" 2>/dev/null || true
        if [ "$TEMPLATE_DL_ERROR" = "download_failed" ]; then
            log_error "$(tf templates_download_failed "$name")"
            [ -n "${repo_url:-}" ] && log_dim "$(tf templates_repo_line "$repo_url")"
            if [ -s "${_TPL_GIT_ERR:-/nonexistent}" ]; then
                grep -vE '^\s*$|^Cloning into|^Клонирование' "$_TPL_GIT_ERR" | tail -n 3 | sed 's/^/      git: /' >&2
            fi
        else
            log_error "$(tf templates_not_static "$name")"
        fi
        log_dim "$(t templates_pick_another)"
        rm -rf "$clone_dir" 2>/dev/null || true
        return 1
    fi
}

_validate_custom_git_url() {
    local url="$1"
    # Must begin with https://
    [[ "$url" =~ ^https:// ]] || return 1
    # Reject shell metacharacters that could be exploited
    [[ "$url" =~ [[:space:]\;\`\$\(\)\<\>\|\\\&] ]] && return 1
    # Reasonable length limit
    [ "${#url}" -gt 512 ] && return 1
    return 0
}

download_custom_git_template() {
    local url="${1:-}"
    local output_dir="${2:-}"
    if [ -z "$output_dir" ]; then
        _templates_cache_dir >/dev/null || return 1
        output_dir="$TEMPLATES_CACHE"
    fi

    show_custom_git_help

    if [ -z "$url" ]; then
        echo -ne "  ${WHITE}$(t custom_git_enter_url)${NC} " >&2
        read -r url
        url=$(echo "$url" | tr -d '\r\n[:space:]')
    fi

    if [ -z "$url" ]; then
        log_error "$(t custom_git_empty)"
        return 1
    fi

    if ! _validate_custom_git_url "$url"; then
        log_error "$(t custom_git_bad_url)"
        return 1
    fi

    _parse_custom_git_url "$url"
    local clean_url="$CUSTOM_GIT_CLEAN"
    local branch="$CUSTOM_GIT_BRANCH"

    # Stable-ish directory name from a hash of the original URL
    local hash
    hash=$(echo -n "$url" | md5sum 2>/dev/null | awk '{print $1}' | head -c 10)
    [ -z "$hash" ] && hash=$(date +%s)
    local tpl_id="custom_${hash}"
    local clone_dir="$output_dir/${tpl_id}"
    # mktemp вместо предсказуемого /tmp/custom_git_clone_$$ — иначе локальный
    # непривилегированный юзер заранее кладёт симлинк и root пишет куда угодно.
    local tmp_clone err_file
    tmp_clone=$(mktemp -d "${TMPDIR:-/tmp}/goamnezia_custom_git.XXXXXXXX") || return 1
    err_file=$(mktemp "${TMPDIR:-/tmp}/goamnezia_custom_git_err.XXXXXXXX") || { rm -rf "$tmp_clone"; return 1; }

    rm -rf "$clone_dir"
    mkdir -p "$clone_dir"

    log_info "$(t custom_git_cloning)"

    # Clone with timeout so a hung server can't freeze the installer
    local clone_status=0
    # только https, ext::/file:: запрещены явно (иначе URL = выполнение команд от root)
    local git_args=(-c protocol.allow=never -c protocol.https.allow=always
                    -c protocol.ext.allow=never -c protocol.file.allow=never
                    clone --depth 1)
    [ -n "$branch" ] && git_args+=(--branch "$branch")
    git_args+=(-- "$clean_url" "$tmp_clone")

    if command -v timeout &>/dev/null; then
        GIT_TERMINAL_PROMPT=0 timeout "$CUSTOM_GIT_CLONE_TIMEOUT" git "${git_args[@]}" 2>"$err_file"
        clone_status=$?
    else
        GIT_TERMINAL_PROMPT=0 git "${git_args[@]}" 2>"$err_file"
        clone_status=$?
    fi

    if [ $clone_status -ne 0 ] || [ -z "$(ls -A "$tmp_clone" 2>/dev/null)" ]; then
        local err_msg
        err_msg=$(head -3 "$err_file" 2>/dev/null | tr '\n' ' ')
        rm -f "$err_file"
        rm -rf "$tmp_clone" "$clone_dir"
        log_error "$(tf custom_git_clone_failed "${err_msg:-$clone_status}")"
        return 1
    fi
    rm -f "$err_file"

    # Drop .git before measuring size (we only care about payload)
    rm -rf "$tmp_clone/.git"

    # Size guard
    local size_mb
    size_mb=$(_clone_dir_size_mb "$tmp_clone")
    if [ -n "$size_mb" ] && [ "$size_mb" -gt "$CUSTOM_GIT_MAX_SIZE_MB" ]; then
        rm -rf "$tmp_clone" "$clone_dir"
        log_error "$(tf custom_git_too_big "${size_mb}MB")"
        return 1
    fi

    log_info "$(t custom_git_scanning)"

    # Priority list of common static-site output folders
    local candidates=("" "dist" "public" "build" "_site" "site" "docs" "out" "www")
    local found_dir=""
    for sub in "${candidates[@]}"; do
        local try_dir="$tmp_clone"
        [ -n "$sub" ] && try_dir="$tmp_clone/$sub"
        if [ -f "$try_dir/index.html" ]; then
            found_dir="$try_dir"
            break
        fi
    done

    # Fallback: search for any index.html in the repo (shallow depth first)
    if [ -z "$found_dir" ]; then
        local fallback_index
        fallback_index=$(find "$tmp_clone" -maxdepth 4 -name "index.html" -type f 2>/dev/null | head -1)
        if [ -n "$fallback_index" ]; then
            found_dir=$(dirname "$fallback_index")
        fi
    fi

    if [ -z "$found_dir" ] || [ ! -f "$found_dir/index.html" ]; then
        rm -rf "$tmp_clone" "$clone_dir"
        log_error "$(t custom_git_no_index)"
        return 1
    fi

    # Show what we found (human-friendly relative path)
    local rel_path="${found_dir#$tmp_clone}"
    rel_path="${rel_path#/}"
    [ -z "$rel_path" ] && rel_path="(root)"
    log_dim "$(tf custom_git_found_at "$rel_path")"

    # Copy the detected directory as the new template
    cp -r "$found_dir"/* "$clone_dir/" 2>/dev/null
    cp -r "$found_dir"/.[!.]* "$clone_dir/" 2>/dev/null

    rm -rf "$tmp_clone"

    if [ ! -f "$clone_dir/index.html" ]; then
        rm -rf "$clone_dir"
        log_error "$(t custom_git_no_index)"
        return 1
    fi

    # Remember the URL so users can see what template they used
    echo "$url" > "$clone_dir/.custom_git_source" 2>/dev/null

    log_success "$(tf custom_git_installed "$url")"
    echo "$clone_dir"
    return 0
}

select_category() {
    load_catalog || return 1

    echo "" >&2
    echo -e "  ${BOLD}${WHITE}$(t templates_categories)${NC}" >&2
    echo -e "  ${DIM}$(printf '─%.0s' {1..55})${NC}" >&2

    # First item: custom git URL template
    printf "  ${CYAN}%2d)${NC} ${GREEN}%s${NC}\n" 1 "$(t templates_custom_git)" >&2

    local cats=()
    local i=2
    while IFS='|' read -r id name icon count; do
        [ "$count" -eq 0 ] && continue
        local emoji
        case "$icon" in
            briefcase)     emoji="🏢" ;;
            shopping-cart) emoji="🛒" ;;
            heart)         emoji="🏥" ;;
            book)          emoji="🎓" ;;
            palette)       emoji="📸" ;;
            home)          emoji="🏠" ;;
            utensils)      emoji="🍕" ;;
            rocket)        emoji="🎨" ;;
            chart-bar)     emoji="🔧" ;;
            *)             emoji="📄" ;;
        esac
        printf "  ${CYAN}%2d)${NC} ${emoji} %-30s ${DIM}$(tf templates_count_fmt "$count")${NC}\n" "$i" "$name" >&2
        cats+=("$id")
        ((i++))
    done < <(get_categories)

    printf "  ${CYAN}%2d)${NC} %s\n" "$i" "$(t templates_random)" >&2
    # «0 — назад», как на каждом экране меню: без него ноль давал «Неверный
    # выбор» (найдено при составлении карты goAmnezia pro, 24.09.2026)
    printf "  ${CYAN}%2d)${NC} %s\n" 0 "$(t back)" >&2
    echo -e "  ${DIM}$(printf '─%.0s' {1..55})${NC}" >&2
    echo -ne "  ${WHITE}$(t choose):${NC} " >&2
    read -r choice || choice=0
    [ "$choice" = 0 ] && return 1

    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        log_error "$(t invalid_choice)"
        return 1
    fi

    # Custom git URL
    if [ "$choice" -eq 1 ]; then
        echo "__custom_git__"
        return 0
    fi

    # Random
    if [ "$choice" -eq "$i" ]; then
        local random_cat="${cats[$((RANDOM % ${#cats[@]}))]}"
        echo "$random_cat"
        return 0
    fi

    # Regular category (offset by 1 because item 1 is custom git)
    if [ "$choice" -ge 2 ] && [ "$choice" -lt "$i" ]; then
        echo "${cats[$((choice-2))]}"
        return 0
    fi

    log_error "$(t invalid_choice)"
    return 1
}

select_template() {
    local cat_id="$1"
    local cat_name
    cat_name=$(get_category_name "$cat_id")
    # Категории теперь на тысячи шаблонов: список показывается страницами по
    # 25, есть поиск по названию и случайный выбор. Раньше «Лендинги» выводили
    # три тысячи строк одним махом.
    # shellcheck disable=SC2034  # all/preview — поля формата каталога, код навыка читает их для полноты записи
    local all=() ids=() names=() srcs=() id name source preview
    while IFS='|' read -r id name source preview; do
        [ -n "$id" ] || continue
        ids+=("$id"); names+=("$name"); srcs+=("$source")
    done < <(get_templates_by_category "$cat_id")
    if [ ${#ids[@]} -eq 0 ]; then
        log_info "$(t templates_cat_empty)"
        return 1
    fi
    local per=25 page=0 filter="" view=() k choice total pages start end n
    while :; do
        view=()
        for k in "${!ids[@]}"; do
            if [ -n "$filter" ]; then
                [[ "${names[$k],,}" == *"${filter,,}"* || "${ids[$k],,}" == *"${filter,,}"* ]] || continue
            fi
            view+=("$k")
        done
        total=${#view[@]}
        pages=$(( (total + per - 1) / per )); [ "$pages" -lt 1 ] && pages=1
        [ "$page" -ge "$pages" ] && page=$((pages-1))
        [ "$page" -lt 0 ] && page=0
        start=$((page*per)); end=$((start+per)); [ "$end" -gt "$total" ] && end=$total
        echo "" >&2
        echo -e "  ${BOLD}${WHITE}$(tf templates_list "$cat_name")${NC}" >&2
        if [ -n "$filter" ]; then
            echo -e "  ${DIM}$(tf templates_filter_line "$filter" "$total")${NC}" >&2
        fi
        echo -e "  ${DIM}$(printf '─%.0s' {1..60})${NC}" >&2
        if [ "$total" -eq 0 ]; then
            echo -e "  ${DIM}$(t templates_nothing_found)${NC}" >&2
        fi
        n=$start
        while [ "$n" -lt "$end" ]; do
            k=${view[$n]}
            printf "  ${CYAN}%4d)${NC} %-38s ${DIM}[%s]${NC}\n" "$((n+1))" "${names[$k]:0:38}" "${srcs[$k]}" >&2
            n=$((n+1))
        done
        echo -e "  ${DIM}$(printf '─%.0s' {1..60})${NC}" >&2
        echo -e "  ${DIM}$(tf templates_page_line "$((page+1))" "$pages" "$total")${NC}" >&2
        echo -e "  ${DIM}$(t templates_nav_hint)${NC}" >&2
        echo -ne "  ${WHITE}$(t choose):${NC} " >&2
        read -r choice
        case "$choice" in
            0|"") return 1 ;;
            n|N|+|.) [ "$page" -lt $((pages-1)) ] && page=$((page+1)); continue ;;
            p|P|-|,) [ "$page" -gt 0 ] && page=$((page-1)); continue ;;
            r|R)
                [ "$total" -eq 0 ] && continue
                k=${view[$(( RANDOM % total ))]}
                show_template_preview "${ids[$k]}" || continue
                echo "${ids[$k]}"; return 0 ;;
            /*|s\ *|S\ *)
                filter="${choice#/}"; filter="${filter#s }"; filter="${filter#S }"; page=0; continue ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$total" ]; then
                    k=${view[$((choice-1))]}
                    show_template_preview "${ids[$k]}" || continue
                    echo "${ids[$k]}"; return 0
                fi
                # любое другое слово — поиск по названию
                filter="$choice"; page=0; continue ;;
        esac
    done
}

show_template_preview() {
    local tpl_id="$1"
    local info
    info=$(get_template_info "$tpl_id")

    local name source preview_url repo_url description
    name=$(echo "$info" | jq -r '.name')
    source=$(echo "$info" | jq -r '.source')
    preview_url=$(echo "$info" | jq -r '.preview_url // empty')
    repo_url=$(echo "$info" | jq -r '.repo_url // empty')
    description=$(echo "$info" | jq -r '.description // "—"')

    echo "" >&2
    echo -e "  ${BOLD}${WHITE}$(t templates_preview_title)${NC}" >&2
    echo -e "  ${DIM}$(printf '─%.0s' {1..55})${NC}" >&2
    echo -e "  ${WHITE}$(t templates_name)${NC}  $name" >&2
    echo -e "  ${WHITE}$(t templates_source)${NC}  $source" >&2
    echo -e "  ${WHITE}$(t templates_description)${NC}  $description" >&2

    if [ -n "$preview_url" ]; then
        echo "" >&2
        echo -e "  ${GREEN}$(t templates_preview)${NC} ${CYAN}${preview_url}${NC}" >&2
        echo -e "  ${DIM}$(t templates_preview_hint)${NC}" >&2
    fi

    if [ -n "$repo_url" ]; then
        echo -e "  ${DIM}$(t templates_repo)    ${repo_url}${NC}" >&2
    fi
    local license
    license=$(echo "$info" | jq -r '.license // empty')
    [ -n "$license" ] && echo -e "  ${DIM}$(t templates_license)  ${license}${NC}" >&2

    # Thanks
    echo "" >&2
    # Для общего источника github благодарим владельца репозитория, а не «github».
    local _thanks="$source"
    if [ "$source" = "github" ] && [[ "$repo_url" =~ github\.com/([^/]+)/ ]]; then _thanks="${BASH_REMATCH[1]}"; fi
    echo -e "  ${MAGENTA}$(tf templates_thanks "$_thanks")${NC}" >&2

    echo -e "  ${DIM}$(printf '─%.0s' {1..55})${NC}" >&2
    echo "" >&2

    if ! confirm "$(t templates_install_this)"; then
        return 1
    fi
    return 0
}

pick_random_template_id() {
    [ -f "$CATALOG_FILE" ] || return 1
    jq -r '.categories[].templates[].id' "$CATALOG_FILE" 2>/dev/null | shuf -n1
}

interactive_template_selection() {
    load_catalog || return 1

    # Category selection
    local cat_id
    cat_id=$(select_category)
    [ $? -ne 0 ] && return 1

    # Custom git URL path
    if [ "$cat_id" = "__custom_git__" ]; then
        local template_dir
        template_dir=$(download_custom_git_template)
        [ $? -ne 0 ] && return 1
        echo "$template_dir"
        return 0
    fi

    # Выбор и загрузка. Неудачная загрузка (в каталоге попадаются репозитории
    # без готовой страницы) раньше выбрасывала в меню — человек начинал путь с
    # категории заново. Теперь возвращаемся к списку той же категории.
    local tpl_id template_dir attempt=0 again
    while :; do
        tpl_id=$(select_template "$cat_id")
        [ $? -ne 0 ] && return 1
        template_dir=$(download_template "$tpl_id")
        if [ $? -eq 0 ] && [ -n "$template_dir" ]; then
            echo "$template_dir"
            return 0
        fi
        attempt=$((attempt+1))
        [ "$attempt" -ge 5 ] && return 1
        echo -ne "  ${WHITE}$(t templates_try_another) [Y/n]:${NC} " >&2
        read -r again
        case "$again" in n|N|н|Н) return 1 ;; esac
    done
}

strip_template_service_files() {
    local root="$1"
    [ -d "$root" ] || return 0
    local patterns=(README readme Readme LICENSE license License LICENCE CHANGELOG changelog CONTRIBUTING SECURITY CODE_OF_CONDUCT
                    package.json package-lock.json yarn.lock pnpm-lock.yaml composer.json composer.lock
                    gulpfile.js gulpfile.babel.js Gruntfile.js webpack.config.js webpack.mix.js vite.config.js tailwind.config.js postcss.config.js
                    .gitignore .gitattributes .editorconfig .eslintrc .eslintrc.json .prettierrc .stylelintrc .travis.yml .nojekyll .htaccess .DS_Store Thumbs.db)
    local pat
    for pat in "${patterns[@]}"; do
        find "$root" -maxdepth 2 \( -iname "$pat" -o -iname "$pat.*" \) -type f -delete 2>/dev/null || true
    done
    find "$root" -maxdepth 2 -type f -iname '*.md' -delete 2>/dev/null || true
    local dir
    for dir in .git .github .sass-cache node_modules .vscode .idea; do
        # shellcheck disable=SC2115  # root проверен выше ([ -d ]), dir — из фиксированного списка
        rm -rf "$root/$dir" 2>/dev/null || true
    done
}

deploy_template_to_nginx() {
    local template_dir="$1"
    local template_id="${2:-}"
    local source_url=""

    if [ ! -d "$template_dir" ] || [ ! -f "$template_dir/index.html" ]; then
        log_error "$(tf templates_err_no_index "$template_dir")"
        return 1
    fi
    [ -z "$template_id" ] && template_id=$(basename "$template_dir")
    [ -f "$template_dir/.custom_git_source" ] && source_url=$(head -1 "$template_dir/.custom_git_source" 2>/dev/null || echo "")

    # Бекапим старый сайт. Путь — через mktemp -d: предсказуемый /tmp/site_backup_<дата>
    # позволял локальному юзеру заранее подложить симлинк и увести туда каталог сайта
    # (тот же класс, что и остальные /tmp-пути в модулях).
    if [ -d "$WEBSITE_ROOT" ] && [ "$(ls -A "$WEBSITE_ROOT" 2>/dev/null)" ]; then
        local site_bk_dir
        site_bk_dir=$(mktemp -d "${TMPDIR:-/tmp}/site_backup_$(date +%Y%m%d_%H%M%S).XXXXXX" 2>/dev/null)
        if [ -n "$site_bk_dir" ]; then
            # mktemp -d уже создал каталог — переносим содержимое, а не сам каталог
            cp -a "$WEBSITE_ROOT/." "$site_bk_dir/" 2>/dev/null && rm -rf "$WEBSITE_ROOT"
            log_dim "$(tf templates_site_backup "$site_bk_dir")"
        fi
    fi

    mkdir -p "$WEBSITE_ROOT"
    cp -a "$template_dir/." "$WEBSITE_ROOT/"
    # Симлинки из чужого репозитория шаблона — не в корень сайта (находка аудита безопасности 25.09.2026):
    # nginx отдаёт файл по ссылке, и «dl.dat -> /opt/goamnezia/users.json» раздал бы ключи всех людей любому
    # посетителю, а правка .html по ссылке (вырезание счётчиков, метки шаблона ниже) писала бы от root куда
    # угодно. Удаляем до любой записи в корень; в конфиге nginx вдобавок disable_symlinks.
    find "$WEBSITE_ROOT" -type l -delete 2>/dev/null || true
    rm -f "$WEBSITE_ROOT/.custom_git_source" 2>/dev/null || true
    strip_template_service_files "$WEBSITE_ROOT"
    echo "$template_id" > "$WEBSITE_ROOT/.goamnezia_template_id" 2>/dev/null || true
    [ -n "$source_url" ] && echo "$source_url" > "$WEBSITE_ROOT/.goamnezia_template_source" 2>/dev/null || true
    chown -R www-data:www-data "$WEBSITE_ROOT" 2>/dev/null || chown -R nginx:nginx "$WEBSITE_ROOT" 2>/dev/null
    chmod -R 755 "$WEBSITE_ROOT"

    log_success "$(tf templates_deployed "$WEBSITE_ROOT")"
}

_clone_dir_size_mb() {
    local dir="$1"
    du -sm "$dir" 2>/dev/null | awk '{print $1}'
}

_parse_custom_git_url() {
    local url="$1"
    CUSTOM_GIT_CLEAN=""
    CUSTOM_GIT_BRANCH=""
    # Handle trailing @branch
    if [[ "$url" =~ ^(https://[^@]+)@([A-Za-z0-9._/-]+)$ ]]; then
        CUSTOM_GIT_CLEAN="${BASH_REMATCH[1]}"
        CUSTOM_GIT_BRANCH="${BASH_REMATCH[2]}"
    else
        CUSTOM_GIT_CLEAN="$url"
    fi
    # Strip trailing slash
    CUSTOM_GIT_CLEAN="${CUSTOM_GIT_CLEAN%/}"
    # Append .git if missing (works better with git clone on some hosts)
    if [[ ! "$CUSTOM_GIT_CLEAN" =~ \.git$ ]]; then
        CUSTOM_GIT_CLEAN="${CUSTOM_GIT_CLEAN}.git"
    fi
}

show_custom_git_help() {
    local line
    line=$(printf '─%.0s' $(seq 1 60))
    echo "" >&2
    echo -e "  ${BOLD}${GREEN}$(t custom_git_title)${NC}" >&2
    echo -e "  ${DIM}${line}${NC}" >&2
    echo -e "  $(t custom_git_help_1)" >&2
    echo -e "  $(t custom_git_help_2)" >&2
    echo -e "  $(t custom_git_help_3)" >&2
    echo "" >&2
    echo -e "  ${BOLD}${WHITE}$(t custom_git_formats)${NC}" >&2
    echo -e "  ${CYAN}$(t custom_git_fmt_github)${NC}" >&2
    echo -e "  ${CYAN}$(t custom_git_fmt_gitlab)${NC}" >&2
    echo -e "  ${CYAN}$(t custom_git_fmt_gitext)${NC}" >&2
    echo -e "  ${CYAN}$(t custom_git_fmt_branch)${NC}" >&2
    echo "" >&2
    echo -e "  ${BOLD}${WHITE}$(t custom_git_auto_detect)${NC}" >&2
    echo -e "  $(t custom_git_auto_1)" >&2
    echo -e "  $(t custom_git_auto_2)" >&2
    echo -e "  $(t custom_git_auto_3)" >&2
    echo -e "  $(t custom_git_auto_4)" >&2
    echo "" >&2
    echo -e "  ${BOLD}${WHITE}$(t custom_git_requirements)${NC}" >&2
    echo -e "  ${YELLOW}$(t custom_git_req_1)${NC}" >&2
    echo -e "  ${YELLOW}$(t custom_git_req_2)${NC}" >&2
    echo -e "  ${YELLOW}$(t custom_git_req_3)${NC}" >&2
    echo -e "  ${YELLOW}$(t custom_git_req_4)${NC}" >&2
    echo "" >&2
    echo -e "  ${BOLD}${WHITE}$(t custom_git_examples)${NC}" >&2
    echo -e "  ${DIM}$(t custom_git_ex_1)${NC}" >&2
    echo -e "  ${DIM}$(t custom_git_ex_2)${NC}" >&2
    echo -e "  ${DIM}${line}${NC}" >&2
    echo "" >&2
}
