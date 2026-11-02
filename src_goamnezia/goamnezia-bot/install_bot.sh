#!/bin/bash
# goAmnezia pro — автономный установщик Telegram-бота (порт install_gotelegram_bot.sh).
#
# Делает всё, что нужно юниту goamnezia-bot.service: python3 + venv, копия файлов
# бота в /opt/goamnezia-bot, .env с токеном и ID админов (0600), systemd-юнит от
# root с Restart=always. Запускается и руками, и из SSH-меню (bot_install в
# install.sh зовёт `install_bot.sh --auto`, контракт docs/BOT.md).
#
#   install_bot.sh            интерактивно: спросит токен (проверка формата и getMe)
#                             и кто администратор, если .env ещё нет; главный путь —
#                             привязка сообщением сразу после запуска бота (см. ниже)
#   install_bot.sh --auto     без вопросов: .env должен уже существовать либо
#                             BOT_TOKEN и ALLOWED_IDS заданы в окружении; пустой
#                             ALLOWED_IDS — только с GOAMNEZIA_ADMIN_CLAIM=1 (установка
#                             без терминала: администратора назначит одноразовый код)
#                             или с GOAMNEZIA_ADMIN_PAIR=1 (его привяжет сообщением
#                             SSH-меню сразу после установки — вызовом --pair)
#   install_bot.sh --pair     только окно привязки сообщением для уже установленного
#                             бота (SSH-меню «Telegram-бот → Администраторы →
#                             Привязать по сообщению»)
#   install_bot.sh --lang=en  язык сообщений установщика (по умолчанию — язык
#                             goAmnezia из config.json / .language, иначе ru)
#
# Первый администратор — НЕ «первый, кто напишет боту»: имя бота видно всем, и любой, кто
# нашёл его раньше владельца, получал root-управление сервером (находка SEC-B00). Доверие
# даёт терминал сервера (docs/BOT.md «Контракт привязки»): установщик открывает окно
# привязки, человек пишет боту любое сообщение, бот записывает написавших в кандидаты, а
# здесь человек выбирает себя и подтверждает — у постороннего этого терминала нет. Установка
# без терминала (goInstaller) — ALLOWED_IDS в окружении или запасной одноразовый код: он виден
# в выводе установщика и принимается, только пока открыто окно, которое установщик пишет
# вместе с ним (на каждое окно — новый код).
#
# Правила серии: set -uo pipefail без -e (каждая ошибка обрабатывается явно),
# PATH задан явно, ни одной видимой строки вне словаря t/tf, секреты не в логах.
# Токен не печатается и НЕ попадает в аргументы команд вовсе: адрес Bot API с ним
# curl получает конфигом из stdin (-K -) — argv любого процесса виден всем локальным
# пользователям в /proc/*/cmdline, а printf — встроенная команда bash (SEC-B1).
#
# Тесты (tests/test_bot_features.py) подключают файл через source: всё до строки
# «── Установка ──» — определения без побочных эффектов, сама установка — после неё.
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
GOAMNEZIA_DIR="${GOAMNEZIA_DIR:-/opt/goamnezia}"
BOT_DIR="${GOAMNEZIA_BOT_DIR:-/opt/goamnezia-bot}"
SERVICE_NAME="goamnezia-bot"
ACTION_BIN="${GOAMNEZIA_ACTION_BIN:-$GOAMNEZIA_DIR/install.sh}"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ENV_FILE="$BOT_DIR/.env"
# Файлы привязки администратора — те же, что у бота (bot.py ADMIN_CLAIM_CODE_FILE,
# ADMIN_PAIRING_UNTIL_FILE, …; договор — docs/BOT.md «Контракт привязки»): одноразовый код (пишет
# установщик без терминала), окно (пишут установщик и SSH), кандидаты (пишет бот), подтверждение
# (пишет SSH) и ответ бота на него — «принято» или «не принято».
# Маркер .admin_claimed установщик больше не читает (HB-8): «окно первого администратора
# открывается один раз» — правило прежних версий, с 0.4.7 окно открывают установщик и SSH сколько
# угодно раз, а маркер запирал запасной путь без терминала и после восстановления из бэкапа.
CLAIM_CODE_FILE="$BOT_DIR/.admin_claim_code"
PAIRING_UNTIL_FILE="$BOT_DIR/.admin_pairing_until"
CANDIDATES_FILE="$BOT_DIR/.admin_candidates.json"
CONFIRMED_FILE="$BOT_DIR/.admin_confirmed"
REJECTED_FILE="$BOT_DIR/.admin_confirmed.rejected"
PAIRING_DONE_FILE="$BOT_DIR/.admin_pairing_done"
PAIRING_WINDOW=600          # окно привязки — 10 минут (docs/MODES_047.md)
PAIRING_MAX_CANDIDATES=10   # бот записывает первых десять написавших, дальше — никого (bot.py, SEC50-01)
# Ответа бота на подтверждение ждём чуть дольше минуты: он смотрит раз в 2 секунды, а «не принято»
# из-за .env (id так и не появился в ALLOWED_IDS) пишет, когда подтверждению исполнится минута.
PAIRING_REPLY_WAIT=75
AUTO=0
PAIR_ONLY=0         # --pair: только окно привязки, без установки
PAIR_AFTER_START=0  # 1 — после запуска бота открыть окно привязки сообщением (интерактивная установка)
BOT_USERNAME=""     # имя бота из getMe — для «Напишите боту @…»
LANG_CODE=""
CLAIM_PENDING=0     # 1 — администратора назначит код: подсказка в конце о нём, а не про /start
CLAIM_UNTIL=""      # конец окна, в котором годится выданный код (epoch)
PAIR_STAGE=""       # где привязка: wait — ждём и выбираем, written — .env и подтверждение записаны
PAIR_TTY=0          # 1 — строка состояния переписывается на месте (stderr — терминал)

TOKEN_RE='^[0-9]{6,12}:[A-Za-z0-9_-]{30,50}$'
IDS_RE='^[0-9]+(,[0-9]+)*$'
# Код первого администратора — ровно восемь цифр, как у бота (bot.py CLAIM_CODE_RE).
CLAIM_CODE_RE='^[0-9]{8}$'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

# ── Словарь установщика ──────────────────────────────────────────────────────
# Свой, а не lib/lang/*: установщик обязан работать из любого каталога, куда его
# скопировали, без ядра goAmnezia рядом. Ключи те же в обоих языках.
declare -A I18N_RU I18N_EN
I18N_RU[title]="goAmnezia pro — установка Telegram-бота"
I18N_EN[title]="goAmnezia pro — Telegram bot install"
I18N_RU[need_root]="Запустите от root или через sudo."
I18N_EN[need_root]="Run as root or with sudo."
I18N_RU[bad_option]="Неизвестный ключ: %s"
I18N_EN[bad_option]="Unknown option: %s"
I18N_RU[src_missing]="Файлы бота не найдены рядом с установщиком: %s"
I18N_EN[src_missing]="Bot files not found next to the installer: %s"
I18N_RU[python_install]="Ставлю python3 и python3-venv…"
I18N_EN[python_install]="Installing python3 and python3-venv…"
I18N_RU[python_missing]="python3 не установлен и поставить его не удалось. Установите вручную: apt install python3 python3-venv"
I18N_EN[python_missing]="python3 is missing and could not be installed. Install it manually: apt install python3 python3-venv"
I18N_RU[copying]="Копирую файлы бота в %s"
I18N_EN[copying]="Copying bot files to %s"
I18N_RU[venv_broken]="Прежнее окружение неполное — пересоздаю"
I18N_EN[venv_broken]="Previous virtualenv is incomplete — recreating"
I18N_RU[venv_create]="Создаю виртуальное окружение…"
I18N_EN[venv_create]="Creating the virtual environment…"
I18N_RU[venv_failed]="Не удалось создать venv. Поставьте пакет вручную: apt install python3-venv"
I18N_EN[venv_failed]="Could not create the venv. Install the package manually: apt install python3-venv"
I18N_RU[deps_install]="Ставлю зависимости (python-telegram-bot)…"
I18N_EN[deps_install]="Installing dependencies (python-telegram-bot)…"
I18N_RU[deps_failed]="pip не смог поставить зависимости. Проверьте доступ к PyPI и повторите."
I18N_EN[deps_failed]="pip could not install the dependencies. Check PyPI access and retry."
I18N_RU[env_exists]=".env уже есть — токен и админов не спрашиваю"
I18N_EN[env_exists]=".env already exists — not asking for the token and admins"
I18N_RU[env_from_environment]=".env создан из переменных окружения"
I18N_EN[env_from_environment]=".env created from environment variables"
I18N_RU[env_auto_missing]="Режим --auto: нет %s и не заданы BOT_TOKEN и ALLOWED_IDS в окружении (пустой ALLOWED_IDS — только вместе с GOAMNEZIA_ADMIN_CLAIM=1 или GOAMNEZIA_ADMIN_PAIR=1)."
I18N_EN[env_auto_missing]="--auto mode: %s is missing and BOT_TOKEN / ALLOWED_IDS are not set in the environment (an empty ALLOWED_IDS needs GOAMNEZIA_ADMIN_CLAIM=1 or GOAMNEZIA_ADMIN_PAIR=1)."
I18N_RU[ask_token]="Введите BOT_TOKEN от @BotFather (вид 123456789:AAAA…):"
I18N_EN[ask_token]="Enter the BOT_TOKEN from @BotFather (looks like 123456789:AAAA…):"
# Инструкция «где взять токен»: голый вопрос про токен на живой установке
# оказался тупиком (замечание владельца 10.09.2026).
I18N_RU[token_help_title]="Где взять токен бота:"
I18N_EN[token_help_title]="Where to get the bot token:"
I18N_RU[token_help_1]="1. Откройте %s в Telegram и нажмите «Запустить»."
I18N_EN[token_help_1]="1. Open %s in Telegram and press Start."
I18N_RU[token_help_2]="2. Отправьте команду /newbot."
I18N_EN[token_help_2]="2. Send the /newbot command."
I18N_RU[token_help_3]="3. Придумайте имя бота и его адрес — адрес должен заканчиваться на bot."
I18N_EN[token_help_3]="3. Pick a name and a username for the bot — the username must end with bot."
I18N_RU[token_help_4]="4. BotFather пришлёт строку вида 1234567890:AA… — это и есть токен."
I18N_EN[token_help_4]="4. BotFather replies with a string like 1234567890:AA… — that is the token."
# Кто администратор. Главный путь — привязка сообщением: бот запустится, откроется окно привязки,
# человек пишет боту любое сообщение и подтверждает себя здесь (docs/BOT.md «Контракт привязки»).
# Ручной ввод ID остался запасным путём.
I18N_RU[admin_title]="Кто будет администратором бота?"
I18N_EN[admin_title]="Who will be the bot administrator?"
I18N_RU[admin_auto]="1) Напишу боту и подтвержу здесь, в терминале"
I18N_EN[admin_auto]="1) I will message the bot and confirm it here, in the terminal"
I18N_RU[admin_manual]="2) Ввести Telegram ID вручную"
I18N_EN[admin_manual]="2) Type the Telegram ID by hand"
I18N_RU[admin_legend]="Enter — вариант 1 (проще всего), цифра — другой вариант."
I18N_EN[admin_legend]="Enter — option 1 (the easy one), a digit — another option."
I18N_RU[admin_pick_bad]="Выберите 1 или 2 (Enter — 1)."
I18N_EN[admin_pick_bad]="Pick 1 or 2 (Enter — 1)."
I18N_RU[admin_pair_after]="Бот запустится — и откроется окно привязки: напишите ему любое сообщение и подтвердите себя здесь."
I18N_EN[admin_pair_after]="Once the bot starts, the binding window opens: send it any message and confirm yourself here."
# Запасной путь установки без терминала — одноразовый код в окне привязки.
I18N_RU[admin_code]="Одноразовый код администратора: %s"
I18N_EN[admin_code]="One-time administrator code: %s"
I18N_RU[admin_open]="Откройте ссылку %s и нажмите «Запустить» — или отправьте боту этот код сообщением."
I18N_EN[admin_open]="Open %s and press Start — or send the bot this code as a message."
I18N_RU[admin_open_generic]="Откройте своего бота в Telegram и отправьте ему этот код одним сообщением."
I18N_EN[admin_open_generic]="Open your bot in Telegram and send it this code as one message."
I18N_RU[admin_code_why]="Администратором станет только тот, кто пришлёт код: имя бота может знать кто угодно, а код видит лишь этот экран."
I18N_EN[admin_code_why]="Only whoever sends the code becomes the administrator: anyone may know the bot's name, but only this screen shows the code."
I18N_RU[admin_claim_note]="Код действует до %s (окно привязки — 10 минут) и только до назначения администратора; лежит в %s (читает только root). Не успели — запустите установщик ещё раз: он откроет новое окно с новым кодом. С терминалом проще без кода: SSH-меню «Telegram-бот → Администраторы → Привязать по сообщению»."
I18N_EN[admin_claim_note]="The code works until %s (the binding window is 10 minutes) and only until an administrator is assigned; it is kept in %s (root only). Too late — run the installer again: it opens a new window with a new code. With a terminal it is simpler without a code: SSH menu «Telegram bot → Administrators → Bind by message»."
I18N_RU[env_claim_window]="В .env нет ALLOWED_IDS — администратора назначит одноразовый код."
I18N_EN[env_claim_window]=".env has no ALLOWED_IDS — the one-time code will assign the administrator."
I18N_RU[env_pair_window]="В .env нет ALLOWED_IDS — администратора привяжут сообщением из SSH сразу после установки."
I18N_EN[env_pair_window]=".env has no ALLOWED_IDS — the administrator is bound by message from SSH right after the install."
I18N_RU[claim_code_failed]="Не удалось записать код администратора в %s"
I18N_EN[claim_code_failed]="Could not write the administrator code to %s"
# Привязка сообщением (--pair и после интерактивной установки; docs/BOT.md «Контракт привязки»)
I18N_RU[pair_title]="Привязка администратора бота"
I18N_EN[pair_title]="Bot administrator binding"
I18N_RU[pair_write]="Напишите боту @%s любое сообщение — хоть «привет»: %s"
I18N_EN[pair_write]="Send the bot @%s any message — even «hi»: %s"
I18N_RU[pair_write_generic]="Напишите своему боту в Telegram любое сообщение — хоть «привет»."
I18N_EN[pair_write_generic]="Send your bot any message in Telegram — even «hi»."
I18N_RU[pair_why]="Кто напишет — появится здесь. Администратором станет только тот, кого вы подтвердите в этом терминале: у постороннего его нет."
I18N_EN[pair_why]="Whoever writes shows up here. Only the one you confirm in this terminal becomes the administrator: a stranger has no terminal."
I18N_RU[pair_status_wait]="⏳ Жду сообщение · окно открыто ещё %s · 0 — отмена: "
I18N_EN[pair_status_wait]="⏳ Waiting for a message · the window is open for %s more · 0 — cancel: "
I18N_RU[pair_status_pick]="⏳ Окно открыто ещё %s · номер — это вы, Enter — ждать дальше, 0 — отмена: "
I18N_EN[pair_status_pick]="⏳ The window is open for %s more · a number — that is you, Enter — keep waiting, 0 — cancel: "
I18N_RU[pair_list_title]="Боту написали:"
I18N_EN[pair_list_title]="The bot got messages from:"
I18N_RU[pair_row]="%s) %s — %s, id %s, %s"
I18N_EN[pair_row]="%s) %s — %s, id %s, %s"
I18N_RU[pair_no_username]="без @имени"
I18N_EN[pair_no_username]="no @username"
I18N_RU[pair_warn_many]="Писали несколько человек. Выбирайте только по @username и времени; если писали только вы — отмените (0) и повторите позже: кто-то пытается перехватить привязку."
I18N_EN[pair_warn_many]="Several people wrote. Choose only by @username and time; if only you wrote, cancel (0) and try again later: someone is trying to hijack the binding."
I18N_RU[pair_warn_same_name]="Одинаковые имена у №%s — имя подделать легко: отличайте их по @username, ID и времени."
I18N_EN[pair_warn_same_name]="Numbers %s have the same name — a name is easy to fake: tell them apart by @username, ID and time."
I18N_RU[pair_warn_full]="Список заполнен: записаны первые %s написавших, новых бот не добавит. Вас в нём нет — отмените (0) и повторите позже."
I18N_EN[pair_warn_full]="The list is full: the first %s people who wrote are recorded, the bot adds no more. You are not on it — cancel (0) and try again later."
I18N_RU[pair_pick_bad]="Нет такого номера — выберите себя из списка или 0 — отмена."
I18N_EN[pair_pick_bad]="No such number — pick yourself from the list, or 0 to cancel."
I18N_RU[pair_ask]="Написал %s (%s, id %s, %s). Это вы? 1 — да, это я · 0 — отмена: "
I18N_EN[pair_ask]="Written by %s (%s, id %s, %s). Is this you? 1 — yes, it's me · 0 — cancel: "
I18N_RU[pair_owner_missing]="Владелец не назначен: управлять админами из бота сейчас никто не может. Назначьте его: SSH-меню «Telegram-бот → Администраторы → Назначить владельца»."
I18N_EN[pair_owner_missing]="No owner is set: nobody can manage admins from the bot right now. Set one: SSH menu «Telegram bot → Administrators → Set the owner»."
I18N_RU[pair_not_you]="Не подтверждено — жду дальше: напишите боту сами и выберите себя по номеру."
I18N_EN[pair_not_you]="Not confirmed — still waiting: send the bot a message yourself and pick yourself by number."
I18N_RU[pair_env_written]="Администратор записан в %s (ALLOWED_IDS=%s)."
I18N_EN[pair_env_written]="The administrator is written to %s (ALLOWED_IDS=%s)."
I18N_RU[pair_waiting_bot]="Жду подтверждения от бота (до минуты)…"
I18N_EN[pair_waiting_bot]="Waiting for the bot to confirm (up to a minute)…"
I18N_RU[pair_done]="Администратор: %s. Бот прислал ему «✓ Вы администратор сервера» и главное меню."
I18N_EN[pair_done]="Administrator: %s. The bot sent them «✓ You are the server administrator» and the main menu."
I18N_RU[pair_rejected]="Бот не принял привязку: %s. Подробности — journalctl -u %s"
I18N_EN[pair_rejected]="The bot did not accept the binding: %s. Details — journalctl -u %s"
I18N_RU[pair_reason_empty]="файл подтверждения оказался пустым"
I18N_EN[pair_reason_empty]="the confirmation file was empty"
I18N_RU[pair_reason_bad_id]="в подтверждении не Telegram ID"
I18N_EN[pair_reason_bad_id]="the confirmation holds no Telegram ID"
I18N_RU[pair_reason_not_in_env]="id так и не появился в ALLOWED_IDS в %s"
I18N_EN[pair_reason_not_in_env]="the id never showed up in ALLOWED_IDS in %s"
I18N_RU[pair_no_reply]="Бот не ответил за минуту — похоже, он не запущен. Администратор уже записан в %s: бот подхватит его при старте (systemctl restart %s)."
I18N_EN[pair_no_reply]="The bot did not answer within a minute — it seems not to be running. The administrator is already in %s: the bot picks them up when it starts (systemctl restart %s)."
I18N_RU[pair_timeout]="Окно привязки закрылось: за 10 минут никто не написал боту."
I18N_EN[pair_timeout]="The binding window closed: nobody wrote to the bot in 10 minutes."
I18N_RU[pair_cancelled]="Привязка отменена, окно закрыто."
I18N_EN[pair_cancelled]="Binding cancelled, the window is closed."
I18N_RU[pair_later]="Привязать администратора позже: SSH-меню «Telegram-бот → Администраторы → Привязать по сообщению» или %s --pair"
I18N_EN[pair_later]="Bind the administrator later: SSH menu «Telegram bot → Administrators → Bind by message», or %s --pair"
I18N_RU[pair_no_bot]="Бот не установлен: нет %s. Сначала установите его — «Telegram-бот → Установить / обновить бота»."
I18N_EN[pair_no_bot]="The bot is not installed: %s is missing. Install it first — «Telegram bot → Install / update the bot»."
I18N_RU[pair_window_failed]="Не удалось открыть окно привязки: нет записи в %s."
I18N_EN[pair_window_failed]="Could not open the binding window: %s is not writable."
I18N_RU[pair_bot_down]="Служба %s не запущена — бот не увидит сообщение. Запустите её: systemctl start %s"
I18N_EN[pair_bot_down]="The %s service is not running — the bot will not see the message. Start it: systemctl start %s"
I18N_RU[pair_no_python]="Нет python3 — список написавших прочитать нечем."
I18N_EN[pair_no_python]="python3 is missing — there is nothing to read the list of senders with."
I18N_RU[pair_env_failed]="Не удалось записать администратора в %s — привязка не состоялась."
I18N_EN[pair_env_failed]="Could not write the administrator to %s — the binding did not happen."
I18N_RU[pair_confirm_failed]="Администратор записан в .env, а файл подтверждения %s — нет: перезапустите бота, он подхватит администратора при старте (systemctl restart %s)."
I18N_EN[pair_confirm_failed]="The administrator is in .env, but the confirmation file %s is not written: restart the bot, it picks the administrator up when it starts (systemctl restart %s)."
I18N_RU[pair_interrupted]="Ожидание прервано. Администратор уже записан в %s — бот подхватит его сам."
I18N_EN[pair_interrupted]="Waiting interrupted. The administrator is already in %s — the bot picks them up by itself."
I18N_RU[token_empty]="Токен не может быть пустым."
I18N_EN[token_empty]="The token cannot be empty."
I18N_RU[token_badfmt]="Не похоже на токен бота: нужно <цифры>:<35 символов латиницы, цифр, _ и ->."
I18N_EN[token_badfmt]="That does not look like a bot token: <digits>:<35 letters, digits, _ and -> expected."
I18N_RU[token_check]="Проверяю токен через getMe…"
I18N_EN[token_check]="Checking the token via getMe…"
I18N_RU[token_ok]="Токен принят: бот @%s"
I18N_EN[token_ok]="Token accepted: bot @%s"
I18N_RU[token_rejected]="Telegram не принял токен (401). Проверьте его у @BotFather и введите заново."
I18N_EN[token_rejected]="Telegram rejected the token (401). Check it with @BotFather and enter it again."
I18N_RU[token_unreachable]="api.telegram.org недоступен с этого сервера — проверить токен не удалось."
I18N_EN[token_unreachable]="api.telegram.org is unreachable from this server — the token could not be verified."
I18N_RU[token_continue_anyway]="Продолжить с непроверенным токеном? [y/N]: "
I18N_EN[token_continue_anyway]="Continue with the unverified token? [y/N]: "
I18N_RU[ask_admins]="Telegram ID администратора. Узнать свой ID можно у бота @userinfobot — он отвечает числом на любое сообщение. Несколько — через запятую: 123456789,987654321"
I18N_EN[ask_admins]="Administrator Telegram ID. The @userinfobot bot tells you yours — it answers any message with a number. Several — comma-separated: 123456789,987654321"
I18N_RU[admins_prompt]="ID: "
I18N_EN[admins_prompt]="ID: "
I18N_RU[admins_empty]="ID обязателен: без него бот никого не пустит."
I18N_EN[admins_empty]="The ID is required: without it the bot lets nobody in."
I18N_RU[admins_badfmt]="Только цифры (несколько ID — через запятую)."
I18N_EN[admins_badfmt]="Digits only (several IDs — comma-separated)."
I18N_RU[no_tty]="Нет ввода: запустите установщик в терминале либо создайте %s вручную (BOT_TOKEN=… и ALLOWED_IDS=…)."
I18N_EN[no_tty]="No input: run the installer in a terminal or create %s by hand (BOT_TOKEN=… and ALLOWED_IDS=…)."
I18N_RU[env_created]=".env создан (0600)"
I18N_EN[env_created]=".env created (0600)"
I18N_RU[env_lock_timeout]="Настройки бота заняты другой записью дольше 30 секунд (замок %s) — повторите позже."
I18N_EN[env_lock_timeout]="The bot settings have been busy with another write for over 30 seconds (lock %s) — try again later."
I18N_RU[env_write_failed]="Не удалось записать %s"
I18N_EN[env_write_failed]="Could not write %s"
I18N_RU[unit_written]="Юнит %s записан"
I18N_EN[unit_written]="Unit %s written"
I18N_RU[unit_failed]="systemd не запустил %s — смотрите journalctl -u %s"
I18N_EN[unit_failed]="systemd did not start %s — see journalctl -u %s"
I18N_RU[no_systemd]="systemctl не найден: юнит записан, но запустить службу нечем."
I18N_EN[no_systemd]="systemctl not found: the unit is written, but there is nothing to start the service with."
I18N_RU[bridge_missing]="Мост %s не найден: бот запустится, но действия будут отвечать ошибкой transport, пока не установлен goAmnezia."
I18N_EN[bridge_missing]="Bridge %s not found: the bot starts, but actions answer with a transport error until goAmnezia is installed."
I18N_RU[done_title]="Бот установлен и запущен"
I18N_EN[done_title]="Bot installed and running"
I18N_RU[done_check]="Проверка:"
I18N_EN[done_check]="Check:"
I18N_RU[done_logs]="Логи:"
I18N_EN[done_logs]="Logs:"
I18N_RU[done_env]="Настройки:"
I18N_EN[done_env]="Settings:"
I18N_RU[done_hint]="Откройте бота в Telegram и нажмите /start."
I18N_EN[done_hint]="Open the bot in Telegram and press /start."
I18N_RU[done_hint_claim]="Пришлите боту код администратора (выше) до %s — пока открыто окно привязки."
I18N_EN[done_hint_claim]="Send the bot the administrator code (above) before %s — while the binding window is open."

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

# ── Python ───────────────────────────────────────────────────────────────────
# На чистой Ubuntu 24.04 python3 есть, а ensurepip — нет: venv приезжает отдельным
# пакетом python3.12-venv; имя пакета зависит от версии интерпретатора.
ensure_python() {
    if [ -f "$GOAMNEZIA_DIR/lib/deps.sh" ]; then
        ( source "$GOAMNEZIA_DIR/lib/deps.sh"
          source "$GOAMNEZIA_DIR/lib/i18n.sh"
          load_language "${LANG_CODE:-ru}" >/dev/null 2>&1
          deps_install_missing --yes botweb )
        return $?
    fi
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys, venv, ensurepip; assert sys.version_info >= (3, 9)' >/dev/null 2>&1; then
        return 0
    fi
    log_info "$(t python_install)"
    if command -v apt-get >/dev/null 2>&1; then
        local py_ver=""
        py_ver="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
        # shellcheck disable=SC2086  # ${py_ver:+…} даёт одно слово или ничего — словоделение намеренное
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 python3-venv python3-pip \
            ${py_ver:+python${py_ver}-venv} >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q python3 python3-pip >/dev/null 2>&1 || true
    fi
    command -v python3 >/dev/null 2>&1 && python3 -c 'import sys, venv, ensurepip; assert sys.version_info >= (3, 9)' >/dev/null 2>&1
}

# -ef: при запуске из уже установленного каталога источник и приёмник — один
# файл, cp на этом падает; сравнение по inode ловит и симлинк.
copy_one() {
    local rel="$1"
    if [ "$SRC_DIR/$rel" -ef "$BOT_DIR/$rel" ] 2>/dev/null; then
        return 0
    fi
    cp -f "$SRC_DIR/$rel" "$BOT_DIR/$rel"
}

# ── Telegram Bot API: токен только в stdin curl ──────────────────────────────
# tg_api <токен> <метод[?запрос]> [секунд] — тело ответа и последней строкой HTTP-код.
# Токен сидит в самом адресе, поэтому адрес уходит curl настройкой `url = "…"` в stdin
# (-K -), а не аргументом (SEC-B1); stderr curl — в /dev/null: в сообщении об ошибке адрес
# с токеном тоже не нужен. В конфиг curl попадает только токен по образцу — без кавычек и
# «\», которые меняли бы его разбор; иначе вызова нет вовсе (код 2, «сети нет»).
tg_api() {
    local token="$1" method="$2" max_time="${3:-10}"
    command -v curl >/dev/null 2>&1 || return 2
    [[ "$token" =~ $TOKEN_RE ]] || return 2
    printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$token" "$method" \
        | curl -sS --max-time "$max_time" -w '\n%{http_code}' -K - 2>/dev/null
}

# getMe: 0 — принят (username в stdout), 1 — отвергнут (401/404), 2 — сети нет.
check_token() {
    local token="$1" body
    body=$(tg_api "$token" getMe 10) || return 2
    case "${body##*$'\n'}" in
        200) printf '%s' "${body%$'\n'*}" \
                 | sed -n 's/.*"username"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_]*\)".*/\1/p' | head -n 1
             return 0 ;;
        401|404) return 1 ;;
        *) return 2 ;;
    esac
}

# ── Файлы привязки: запись атомарно и 0600 с первого мгновения ────────────────
# mktemp рядом с целью создаёт файл 0600, mv в пределах каталога атомарен: бот не прочтёт файл
# наполовину записанным (договор: «запись атомарная, tmp рядом + rename»).
write_private() {
    local path="$1" text="$2" tmp
    mkdir -p "$BOT_DIR" || return 1
    tmp=$(mktemp "$BOT_DIR/.pairing.XXXXXX") || return 1
    if printf '%s\n' "$text" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$path"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# Часы и минуты момента (epoch) по часам сервера: GNU date понимает «-d @N», BSD — «-r N».
clock_of() {
    date -d "@$1" +%H:%M 2>/dev/null || date -r "$1" +%H:%M 2>/dev/null || printf '%s' "$1"
}

# Окно привязки (docs/BOT.md «Контракт привязки»): хвосты прошлого окна — кандидаты, подтверждение
# и оба ответа бота — прочь, затем конец окна по часам сервера одной строкой. Каждая запись файла —
# новое окно: промахи по коду и «верные коды» прошлого бот забывает. Печатает конец окна (epoch).
open_pairing_window() {
    local win_end
    rm -f "$CANDIDATES_FILE" "$CONFIRMED_FILE" "$PAIRING_DONE_FILE" "$REJECTED_FILE" 2>/dev/null
    win_end=$(( $(date +%s) + PAIRING_WINDOW ))
    write_private "$PAIRING_UNTIL_FILE" "$win_end" || return 1
    printf '%s' "$win_end"
}

# Окно закрыто: бот больше не пишет кандидатов, а без файла окна «Да» по коду не действует.
close_pairing_window() {
    rm -f "$PAIRING_UNTIL_FILE" "$CANDIDATES_FILE" 2>/dev/null || true
}

# ── Одноразовый код: запасной путь установки без терминала ───────────────────
# Восемь цифр из /dev/urandom — ровно то, что принимает бот (bot.py CLAIM_CODE_RE). Сам бот кода
# не заводит: его выдаёт только этот установщик, и только вместе с окном привязки (prepare_claim).
# Порциями по 512 байт, а не бесконечным потоком `tr </dev/urandom | head -c 8`: тот
# держался на SIGPIPE, и там, где сигнал унаследован игнорируемым (запуск из python,
# часть CI), BSD tr на macOS читал /dev/urandom без конца — установщик висел на выборе
# администратора. Байты '0'…'9' равновероятны — цифры без смещения (не «число % 10^8»).
new_claim_code() {
    local code="" chunk i
    for ((i = 0; i < 16 && ${#code} < 8; i++)); do
        chunk=$(head -c 512 /dev/urandom 2>/dev/null | LC_ALL=C tr -dc '0-9') || chunk=""
        code+="$chunk"
    done
    code="${code:0:8}"
    [[ "$code" =~ ^[0-9]{8}$ ]] || return 1
    printf '%s' "$code"
}

# «48291375» → «4829 1375»: так его читают с экрана и перепечатывают без ошибок.
claim_code_pretty() {
    local code="$1"
    if [[ "$code" =~ ^[0-9]{8}$ ]]; then printf '%s %s' "${code:0:4}" "${code:4}"; else printf '%s' "$code"; fi
}

# Файл кода — атомарно и 0600 (его же читает бот).
write_claim_code() {
    local code="$1"
    [[ "$code" =~ $CLAIM_CODE_RE ]] || return 1
    write_private "$CLAIM_CODE_FILE" "$code"
}

# Администратор назначен записью или его привязывают сообщением — коду открывать больше нечего.
forget_claim_code() {
    rm -f "$CLAIM_CODE_FILE" 2>/dev/null || true
}

# Экран с кодом: сам код крупно и как его прислать. username пусто (сеть не ответила
# на getMe) — без ссылки: «откройте своего бота и отправьте код».
show_claim_code() {
    local username="$1" code="$2"
    echo "" >&2
    echo -e "  ${BOLD}${GREEN}$(tf admin_code "$(claim_code_pretty "$code")")${NC}" >&2
    if [[ "$username" =~ ^[A-Za-z0-9_]{3,64}$ ]]; then
        log_info "$(tf admin_open "https://t.me/${username}?start=${code}")"
    else
        log_info "$(t admin_open_generic)"
    fi
    echo -e "  ${DIM}$(t admin_code_why)${NC}" >&2
}

# Код и окно для установки без терминала: СВЕЖИЙ код и окно привязки рядом (оба 0600) — бот
# принимает код, только пока открыто окно, и только выданный для этого окна (docs/BOT.md «Контракт
# привязки»): код прошлого окна в новом не годится, и на каждое окно — новый код (SEC46-07). Раньше
# код брался из файла, если он там был, а окно открывал сам бот на 10 минут после каждого старта;
# с 0.4.7 бот окон не открывает, и код без окна от установщика не работал вовсе (HB-1).
# Возврат: 0 — код и окно записаны, код показан; 1 — записать не удалось.
prepare_claim() {
    local token="$1" code="" username="" win_end
    code=$(new_claim_code) || code=""
    if [ -z "$code" ] || ! write_claim_code "$code"; then
        log_error "$(tf claim_code_failed "$CLAIM_CODE_FILE")"
        return 1
    fi
    if ! win_end=$(open_pairing_window); then
        forget_claim_code
        log_error "$(tf pair_window_failed "$PAIRING_UNTIL_FILE")"
        return 1
    fi
    CLAIM_UNTIL="$win_end"
    username=$(check_token "$token" 2>/dev/null) || username=""
    show_claim_code "$username" "$code"
    log_info "$(tf admin_claim_note "$(clock_of "$win_end")" "$CLAIM_CODE_FILE")"
    return 0
}

# ── Привязка администратора сообщением (docs/BOT.md «Контракт привязки») ─────
# Разбор .admin_candidates.json — ТОЛЬКО JSON-парсером (договор): строка на человека
# «id<TAB>username<TAB>имя<TAB>ЧЧ:ММ<TAB>двойник» по времени первого сообщения — первые
# PAIRING_MAX_CANDIDATES, как их записывает бот: номер человека в списке не меняется, пока окно
# открыто (SEC50-01). Имя и username присылает Telegram, то есть кто угодно, а печатаем их мы — в
# терминале root: управляющие символы (C0, DEL и C1 — U+009B тоже начинает escape-последовательность),
# разделители строк, «\», кавычки и скобки — пробелом, невидимое (вся категория Unicode Cf — знаки
# направления текста, U+200B–U+200D, U+2060, U+FEFF… — и пустые буквы) — прочь, как у бота (bot.py
# _pairing_clean); username — только по форме Telegram. «Двойник» — 1, если у кого-то ещё в списке то
# же имя с точностью до регистра, совместимых форм Unicode и похожих букв кириллицы и греческого:
# имя подделать легко, и SSH об этом предупреждает. Пустых полей нет («-»): read с IFS=табуляция
# склеивает соседние табуляции. Файл испорчен или не список — пусто.
read -r -d '' PY_CANDIDATES <<'PYEOF' || true
import json, re, sys, time, unicodedata
UNSAFE = re.compile(r'[\x00-\x1f\x7f-\x9f\\"{}\[\]\u2028\u2029]')
INVISIBLE = re.compile(r"[\u034f\u115f\u1160\u17b4\u17b5\u180b-\u180f\u2800\u3164\ufe00-\ufe0f\uffa0\U000e0100-\U000e01ef]")
LOOKALIKE = dict(zip(map(ord, "авекмнорстухіјѕԁһӏԛԝαβεζηικμνορτυχ"), "abekmhopctyxijsdhlqwabezhikmnoptyx"))
MAX = int(sys.argv[2]) if len(sys.argv) > 2 else 10
def clean(value, limit=64):
    text = INVISIBLE.sub("", UNSAFE.sub(" ", str(value or "")))
    text = "".join(ch for ch in text if unicodedata.category(ch) not in ("Cc", "Cf", "Cs"))
    return " ".join(text.split())[:limit]
def look(name):
    return " ".join(unicodedata.normalize("NFKC", name).casefold().translate(LOOKALIKE).split())
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
if not isinstance(data, list):
    sys.exit(0)
rows, seen = [], set()
def when(c):
    ts = c.get("ts")
    ok = isinstance(ts, (int, float)) and not isinstance(ts, bool) and 0 < ts < 10 ** 11
    return (0, ts) if ok else (1, 0)
items = [c for c in data if isinstance(c, dict)]
for c in sorted(items, key=when):
    uid = c.get("id")
    if isinstance(uid, bool) or not isinstance(uid, int) or not 0 < uid < 10 ** 20 or uid in seen:
        continue
    seen.add(uid)
    user = str(c.get("username") or "")
    if not re.fullmatch(r"[A-Za-z0-9_]{1,32}", user):
        user = "-"
    hm = "--:--"
    if when(c)[0] == 0:
        hm = time.strftime("%H:%M", time.localtime(c["ts"]))
    rows.append([uid, user, clean(c.get("first_name")), hm])
    if len(rows) >= MAX:
        break
looks = [look(r[2]) for r in rows]
for r, key in zip(rows, looks):
    twin = 1 if key and looks.count(key) > 1 else 0
    print("%d\t%s\t%s\t%s\t%d" % (r[0], r[1], r[2] or "-", r[3], twin))
PYEOF

# Подтверждённый человек — в .env: ALLOWED_IDS целиком (прежние админы и новый — бот берёт список из
# файла как есть) и OWNER_ID — только если он первый администратор (список был пуст). Админы уже есть, а
# OWNER_ID пуст — владельца не трогаем: раньше им становился новый человек, пришедший вторым (SEC50-02);
# назначить владельца — «Telegram-бот → Администраторы → Назначить владельца». .env читаем так же, как бот (bot.py
# _read_env_values: «export », кавычки, « # комментарий», повтор переменной — побеждает последняя),
# без source; первая такая строка получает новое значение, повторы уходят. Запись — tmp рядом (0600),
# fsync и rename: в .env лежит и токен бота, полузаписанный файл оставил бы бот без доступа вовсе.
# Печатает новый ALLOWED_IDS.
read -r -d '' PY_ENV_ADD_ADMIN <<'PYEOF' || true
import fcntl, os, re, sys, tempfile, time
path, new = sys.argv[1], int(sys.argv[2])
wait = float(os.environ.get("ENV_LOCK_WAIT") or 30)
# Замок .env (SEC50-04): прочитать, изменить и записать — целиком под flock на .env.lock рядом с .env
lock = os.open(path + ".lock", os.O_WRONLY | os.O_CREAT, 0o600)
deadline = time.monotonic() + wait
while True:
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except BlockingIOError:
        if time.monotonic() >= deadline:
            sys.exit("замок %s.lock занят дольше %d с" % (path, wait))
        time.sleep(0.05)
with open(path, encoding="utf-8") as fh:
    lines = fh.read().splitlines()
def key_of(line):
    s = line.strip()
    if s.startswith("export "):
        s = s[len("export "):].lstrip()
    key, sep, value = s.partition("=")
    return (key.strip(), value) if sep else (None, None)
def env_value(raw):
    value = raw.strip()
    if value[:1] in ("'", '"'):
        end = value.find(value[0], 1)
        return value[1:end] if end > 0 else re.sub(r"\s+#.*$", "", value[1:])
    return re.sub(r"\s+#.*$", "", value)
current = {}
for line in lines:
    key, raw = key_of(line)
    if key in ("ALLOWED_IDS", "OWNER_ID"):
        current[key] = env_value(raw)
ids = []
for part in re.split(r"[,\s]+", current.get("ALLOWED_IDS", "")):
    if re.fullmatch(r"[0-9]{1,20}", part) and int(part) > 0 and int(part) not in ids:
        ids.append(int(part))
first = not ids
if new not in ids:
    ids.append(new)
want = {"ALLOWED_IDS": ",".join(str(i) for i in ids)}
if first:
    want["OWNER_ID"] = str(new)
out, done = [], set()
for line in lines:
    key, _ = key_of(line)
    if key in want:
        if key not in done:
            out.append("%s=%s" % (key, want[key]))
            done.add(key)
        continue
    out.append(line)
for key in ("ALLOWED_IDS", "OWNER_ID"):
    if key in want and key not in done:
        out.append("%s=%s" % (key, want[key]))
fd, tmp = tempfile.mkstemp(prefix=".env.", dir=os.path.dirname(os.path.abspath(path)))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out) + "\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
print(want["ALLOWED_IDS"])
PYEOF

# Кандидат для экрана: «@owner» (без username — «без @имени»).
pair_at() {
    if [ "$1" = "-" ]; then t pair_no_username; else printf '@%s' "$1"; fi
}

# Остаток окна «м:сс».
pair_left() {
    local left="$1"
    [ "$left" -gt 0 ] || left=0
    printf '%d:%02d' $((left / 60)) $((left % 60))
}

# Строка состояния — она же приглашение ввода. На терминале переписывается на месте раз в секунду
# (\r и «стереть до конца строки»), пока человек не начал печатать: первая буква снимает таймер
# (pair_by_message). Не на терминале (вывод в журнал) — новой строкой, только когда она изменилась.
pair_status() {
    local text="$1"
    if [ "$PAIR_TTY" = 1 ]; then
        printf '\r\033[K  %s' "$text" >&2
    elif [ "$text" != "${PAIR_LAST_STATUS:-}" ]; then
        printf '  %s\n' "$text" >&2
    fi
    PAIR_LAST_STATUS="$text"
}

pair_status_clear() {
    [ "$PAIR_TTY" = 1 ] && printf '\r\033[K' >&2
    return 0
}

# Ctrl-C, обрыв SSH (HUP) или TERM посреди привязки. До подтверждения — окно закрыть и выйти («0 или
# Ctrl-C — отмена»). После записи .env окно тоже закрываем, а подтверждение оставляем: бот подхватит
# его сам — и сразу, и при старте. Выход из обработчика нужен: без него прерванный read продолжил бы
# ждать ввода. SSH-меню, вызвавшее --pair отдельным процессом, после такого выхода живёт дальше.
pair_interrupted() {
    trap - INT TERM HUP
    pair_status_clear
    echo "" >&2
    close_pairing_window
    if [ "$PAIR_STAGE" = "written" ]; then
        log_warning "$(tf pair_interrupted "$ENV_FILE")"
    else
        log_info "$(t pair_cancelled)"
        log_info "$(tf pair_later "$SCRIPT_DIR/install_bot.sh")"
    fi
    exit 130
}

# Ответ бота на подтверждение (договор): 0 — «принято» (.admin_pairing_done с этим id), 1 — «не
# принято» (.admin_confirmed.rejected; причина — в PAIR_REJECT_REASON), 2 — ответа нет за
# PAIRING_REPLY_WAIT секунд (бот не запущен — подхватит при старте). Пропажа .admin_confirmed сама по
# себе ответом не считается.
pair_await_reply() {
    local id="$1" deadline got first reason
    deadline=$(( $(date +%s) + PAIRING_REPLY_WAIT ))
    PAIR_REJECT_REASON=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if [ -f "$PAIRING_DONE_FILE" ]; then
            got=""
            IFS= read -r got < "$PAIRING_DONE_FILE" || true
            if [ "${got//[[:space:]]/}" = "$id" ]; then
                rm -f "$PAIRING_DONE_FILE"
                return 0
            fi
        fi
        if [ -f "$REJECTED_FILE" ]; then
            first="" reason=""
            { IFS= read -r first; IFS= read -r reason; } < "$REJECTED_FILE" || true
            PAIR_REJECT_REASON="${reason//[^a-z_]/}"
            rm -f "$REJECTED_FILE"
            return 1
        fi
        sleep 1
    done
    return 2
}

# Окно привязки сообщением целиком — для SSH-меню (--pair) и после интерактивной установки:
# окно открыть → «Напишите боту @имя» → живой список написавших → номер себя → «Это вы? 1 — да, это я · 0 — отмена» →
# .env, потом .admin_confirmed → ответ бота → итог; окно закрыть. «0», конец ввода и Ctrl-C — отмена
# с закрытием окна. username — имя бота (пусто — спросим у Telegram по токену из .env).
# Возврат: 0 — администратор привязан (или записан, а бот подхватит его при старте), 1 — нет.
pair_by_message() {
    local username="${1:-}" token win_end now left raw last="-" rc ch rest ans pick i id user name hm twin at why
    local same
    local -a c_id=() c_user=() c_name=() c_time=() c_twin=()
    if [ ! -f "$ENV_FILE" ]; then
        log_error "$(tf pair_no_bot "$ENV_FILE")"
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        log_error "$(t pair_no_python)"
        return 1
    fi
    PAIR_TTY=0
    [ -t 2 ] && [ "${TERM:-dumb}" != "dumb" ] && PAIR_TTY=1
    PAIR_LAST_STATUS=""
    if [ -z "$username" ]; then
        token=$(env_value BOT_TOKEN) || token=""
        token="${token//[[:space:]]/}"
        username=$(check_token "$token" 2>/dev/null) || username=""
    fi
    if command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        log_warning "$(tf pair_bot_down "$SERVICE_NAME" "$SERVICE_NAME")"
    fi
    # Код — путь установки без терминала; в окне, открытом из SSH, он не нужен и работать не должен.
    forget_claim_code
    if ! win_end=$(open_pairing_window); then
        log_error "$(tf pair_window_failed "$PAIRING_UNTIL_FILE")"
        return 1
    fi
    PAIR_STAGE="wait"
    trap 'pair_interrupted' INT TERM HUP
    echo "" >&2
    if [[ "$username" =~ ^[A-Za-z0-9_]{3,64}$ ]]; then
        echo -e "  ${BOLD}$(tf pair_write "$username" "https://t.me/${username}")${NC}" >&2
    else
        echo -e "  ${BOLD}$(t pair_write_generic)${NC}" >&2
    fi
    echo -e "  ${DIM}$(t pair_why)${NC}" >&2
    echo "" >&2
    while true; do
        now=$(date +%s)
        left=$(( win_end - now ))
        if [ "$left" -le 0 ]; then
            pair_status_clear
            trap - INT TERM HUP
            close_pairing_window
            log_warning "$(t pair_timeout)"
            log_info "$(tf pair_later "$SCRIPT_DIR/install_bot.sh")"
            return 1
        fi
        # Кандидаты: файл пишет бот, перечитываем его только когда он изменился.
        raw=""
        if [ -f "$CANDIDATES_FILE" ]; then
            IFS= read -r -d '' raw < "$CANDIDATES_FILE" || true
        fi
        if [ "$raw" != "$last" ]; then
            last="$raw"
            c_id=() c_user=() c_name=() c_time=() c_twin=()
            while IFS=$'\t' read -r id user name hm twin; do
                [[ "$id" =~ ^[0-9]+$ ]] || continue
                c_id+=("$id") c_user+=("$user") c_name+=("$name") c_time+=("$hm") c_twin+=("${twin:-0}")
            done < <(python3 -c "$PY_CANDIDATES" "$CANDIDATES_FILE" "$PAIRING_MAX_CANDIDATES" 2>/dev/null)
            if [ "${#c_id[@]}" -gt 0 ]; then
                pair_status_clear
                [ "$PAIR_TTY" = 1 ] || echo "" >&2
                echo -e "  ${BOLD}$(t pair_list_title)${NC}" >&2
                same=""
                for i in "${!c_id[@]}"; do
                    echo -e "    $(tf pair_row "$((i + 1))" "$(pair_at "${c_user[$i]}")" "${c_name[$i]}" "${c_id[$i]}" "${c_time[$i]}")" >&2
                    [ "${c_twin[$i]}" = 1 ] && same="${same:+$same, }$((i + 1))"
                done
                # Кто угодно может написать боту и назваться как угодно (SEC50-01): несколько написавших,
                # одинаковые имена и заполненный список — повод выбирать осторожно или начать заново.
                [ "${#c_id[@]}" -gt 1 ] && log_warning "$(t pair_warn_many)"
                [ -n "$same" ] && log_warning "$(tf pair_warn_same_name "$same")"
                [ "${#c_id[@]}" -ge "$PAIRING_MAX_CANDIDATES" ] && log_warning "$(tf pair_warn_full "${#c_id[@]}")"
                PAIR_LAST_STATUS=""
            fi
        fi
        if [ "${#c_id[@]}" -gt 0 ]; then
            pair_status "$(tf pair_status_pick "$(pair_left "$left")")"
        else
            # Не на терминале минуты хватит: строка «ещё 9:41» каждую секунду засорила бы журнал.
            if [ "$PAIR_TTY" = 1 ]; then
                pair_status "$(tf pair_status_wait "$(pair_left "$left")")"
            else
                pair_status "$(tf pair_status_wait "$(pair_left $(( (left + 59) / 60 * 60 )))")"
            fi
        fi
        # Первая буква — с таймером, остаток строки — без него: начал человек печатать — строку
        # состояния больше не трогаем (перерисовка стёрла бы набранное с экрана).
        read -t 1 -r -n 1 ch
        rc=$?
        [ "$rc" -gt 128 ] && continue
        if [ "$rc" -ne 0 ]; then
            # Конец ввода (оборванная сессия, запуск без терминала) — отмена, а не вечный цикл
            pair_status_clear
            echo "" >&2
            trap - INT TERM HUP
            close_pairing_window
            log_info "$(t pair_cancelled)"
            log_info "$(tf pair_later "$SCRIPT_DIR/install_bot.sh")"
            return 1
        fi
        ans="$ch"
        if [ -n "$ch" ]; then
            IFS= read -r rest || rest=""
            ans="$ch$rest"
        fi
        ans="${ans//[[:space:]]/}"
        case "$ans" in
            "") PAIR_LAST_STATUS=""; continue ;;
            0)
                trap - INT TERM HUP
                close_pairing_window
                log_info "$(t pair_cancelled)"
                log_info "$(tf pair_later "$SCRIPT_DIR/install_bot.sh")"
                return 1
                ;;
        esac
        pick=0
        [[ "$ans" =~ ^[0-9]{1,3}$ ]] && pick=$((10#$ans))
        if [ "$pick" -lt 1 ] || [ "$pick" -gt "${#c_id[@]}" ]; then
            log_warning "$(t pair_pick_bad)"
            PAIR_LAST_STATUS=""
            continue
        fi
        # Номер — из списка, который человек видел на экране, а не из файла, переписанного после
        i=$((pick - 1))
        id="${c_id[$i]}" name="${c_name[$i]}" hm="${c_time[$i]}"
        at=$(pair_at "${c_user[$i]}")
        [ "$name" = "-" ] && name="—"
        echo -ne "  ${YELLOW}$(tf pair_ask "$at" "$name" "$id" "$hm")${NC}" >&2
        if ! IFS= read -r ans; then
            echo "" >&2
            trap - INT TERM HUP
            close_pairing_window
            log_info "$(t pair_cancelled)"
            log_info "$(tf pair_later "$SCRIPT_DIR/install_bot.sh")"
            return 1
        fi
        # Ответ — цифрой, как везде в SSH-меню (TAIL-15): 1 — да, это я; 0 — отмена привязки с закрытием
        # окна, как «0» в списке. Что угодно другое (Enter, прежние y/N) — не подтверждено: назад к списку,
        # окно открыто — ошибка в номере не стоит заново открытого окна.
        case "$(printf '%s' "$ans" | tr -d '[:space:]')" in
            1) ;;
            0)
                trap - INT TERM HUP
                close_pairing_window
                log_info "$(t pair_cancelled)"
                log_info "$(tf pair_later "$SCRIPT_DIR/install_bot.sh")"
                return 1
                ;;
            *)
                log_info "$(t pair_not_you)"
                PAIR_LAST_STATUS=""
                continue
                ;;
        esac
        # Сначала .env (прежние админы и новый; OWNER_ID — если владельца нет), потом подтверждение:
        # бот, увидев .admin_confirmed, сразу перечитывает .env (договор).
        if ! ans=$(python3 -c "$PY_ENV_ADD_ADMIN" "$ENV_FILE" "$id" 2>/dev/null) || [ -z "$ans" ]; then
            trap - INT TERM HUP
            close_pairing_window
            log_error "$(tf pair_env_failed "$ENV_FILE")"
            return 1
        fi
        PAIR_STAGE="written"
        if ! write_private "$CONFIRMED_FILE" "$id"; then
            trap - INT TERM HUP
            close_pairing_window
            log_error "$(tf pair_confirm_failed "$CONFIRMED_FILE" "$SERVICE_NAME")"
            return 1
        fi
        log_success "$(tf pair_env_written "$ENV_FILE" "$ans")"
        log_info "$(t pair_waiting_bot)"
        pair_await_reply "$id"
        rc=$?
        trap - INT TERM HUP
        close_pairing_window
        case "$rc" in
            0)
                log_success "$(tf pair_done "$at (id $id)")"
                owner_missing && log_warning "$(t pair_owner_missing)"
                return 0
                ;;
            1)
                case "$PAIR_REJECT_REASON" in
                    empty)      why=$(t pair_reason_empty) ;;
                    bad_id)     why=$(t pair_reason_bad_id) ;;
                    not_in_env) why=$(tf pair_reason_not_in_env "$ENV_FILE") ;;
                    *)          why="${PAIR_REJECT_REASON:-?}" ;;
                esac
                log_error "$(tf pair_rejected "$why" "$SERVICE_NAME")"
                return 1
                ;;
            *)
                log_warning "$(tf pair_no_reply "$ENV_FILE" "$SERVICE_NAME")"
                owner_missing && log_warning "$(t pair_owner_missing)"
                return 0
                ;;
        esac
    done
}

# Владелец не назначен: OWNER_ID в .env пуст или не из ALLOWED_IDS — бот тогда не даёт управлять админами
# никому (bot.py owner_id). Привязка второго администратора владельца не назначает (SEC50-02).
owner_missing() {
    local owner ids
    owner=$(env_value OWNER_ID) || owner=""
    owner="${owner//[[:space:]]/}"
    ids=$(env_value ALLOWED_IDS) || ids=""
    ids=",${ids//[[:space:]]/},"
    [ -z "$owner" ] || [[ "$ids" != *",$owner,"* ]]
}

# Замок .env (SEC50-04). Писателей у .env несколько — бот (/invite, удаление админа, владелец по коду),
# SSH-меню (владелец), установщик (создание, привязка сообщением), — и каждый читает файл, меняет строку и
# кладёт весь файл обратно: без общего замка запись одного пропадала под записью другого. Все берут flock
# на .env.lock рядом с .env и держат его на всё «прочитать — изменить — записать»: здесь — flock(1),
# в python (бот, PY_ENV_ADD_ADMIN) — fcntl.flock. Нет flock (стенд на macOS) — без замка, как
# ga_with_config_lock в ядре. Занят дольше ENV_LOCK_WAIT секунд — отказ (75), файл не тронут.
ENV_LOCK_WAIT="${ENV_LOCK_WAIT:-30}"
with_env_lock() {
    local fd rc=0
    command -v flock >/dev/null 2>&1 || { "$@"; return $?; }
    mkdir -p "$BOT_DIR" 2>/dev/null || true
    { exec {fd}>>"$ENV_FILE.lock"; } 2>/dev/null || { "$@"; return $?; }
    chmod 600 "$ENV_FILE.lock" 2>/dev/null || true
    if ! flock -w "$ENV_LOCK_WAIT" "$fd"; then
        { exec {fd}>&-; } 2>/dev/null
        log_error "$(tf env_lock_timeout "$ENV_FILE.lock")"
        return 75
    fi
    "$@" || rc=$?
    { exec {fd}>&-; } 2>/dev/null
    return "$rc"
}

write_env() {
    with_env_lock write_env_locked "$@"
}

write_env_locked() {
    local token="$1" ids="$2" tmp owner="${OWNER_ID:-}"
    [[ ",$ids," == *",$owner,"* ]] && [ -n "$owner" ] || owner="${ids%%,*}"
    mkdir -p "$BOT_DIR" || return 1
    tmp=$(mktemp "$BOT_DIR/.env.XXXXXX") || return 1
    {
        echo "BOT_TOKEN=$token"
        echo "ALLOWED_IDS=$ids"
        # Владелец — ЗАПИСЬЮ, а не догадкой по порядку списка. Прежние версии
        # писали список отсортированным по возрастанию id, и на обновлённой
        # установке «владельцем» оказывался приглашённый со старым аккаунтом:
        # он терял кнопки управления, а сосед мог удалить его самого. Первый из
        # введённых здесь и есть тот, кто ставит сервер. Берём его, если задан
        # снаружи и есть в списке, иначе первый из списка (пусто — владельцем станет
        # первый администратор: его запишет SSH, привязав человека сообщением, или
        # бот, назначив его по одноразовому коду). Владелец не из списка — не
        # владелец вовсе (bot.py owner_id): такой OWNER_ID не пишем (SEC50-02).
        echo "OWNER_ID=$owner"
        echo "GOAMNEZIA_LANG=$LANG_CODE"
        echo "GOAMNEZIA_ACTION_BIN=$ACTION_BIN"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" && mv "$tmp" "$ENV_FILE"
}

# Значение из .env — разбором строк, без source: файл — данные, а не код. Разбор тот же, что у бота
# (bot.py _read_env_values), SSH-меню (install.sh _bot_env_get) и панели: «export » в начале строки,
# пробелы вокруг имени, кавычки, « # комментарий» после значения; повтор переменной — побеждает
# ПОСЛЕДНЯЯ строка, как у systemd (SEC50-03). Раньше здесь побеждала первая.
env_value() {
    local want="$1" line key val q out="" rc=1
    [ -f "$ENV_FILE" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in "export "*) line="${line#export }"; line="${line#"${line%%[![:space:]]*}"}" ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
        key="${line%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        [ "$key" = "$want" ] || continue
        val="${line#*=}"
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        q="${val:0:1}"
        if { [ "$q" = '"' ] || [ "$q" = "'" ]; } && [[ "${val:1}" == *"$q"* ]]; then
            val="${val:1}"
            val="${val%%"$q"*}"
        else
            [ "$q" = '"' ] || [ "$q" = "'" ] && val="${val:1}"
            val=$(printf '%s' "$val" | sed -E 's/[[:space:]]+#.*$//')
        fi
        out="$val" rc=0
    done < "$ENV_FILE"
    printf '%s' "$out"
    return "$rc"
}

# .env уже есть (повторная установка, обновление): его не трогаем. Админы в нём есть — коду
# открывать нечего. Админов нет: SSH-меню (GOAMNEZIA_ADMIN_PAIR=1) откроет окно привязки само сразу
# после установки; в терминале — привязка сообщением, как только бот запустится; без терминала —
# запасной путь: СВЕЖИЙ код и окно (бот сам окон не открывает, и прежний код в новом окне не годится).
env_existing() {
    local ids token
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    log_info "$(t env_exists)"
    ids=$(env_value ALLOWED_IDS) || ids=""
    ids="${ids//[[:space:],]/}"
    forget_claim_code
    [ -n "$ids" ] && return 0
    if [ "${GOAMNEZIA_ADMIN_PAIR:-0}" = "1" ]; then
        log_info "$(t env_pair_window)"
        return 0
    fi
    if [ "$AUTO" -eq 0 ] && [ -t 0 ]; then
        PAIR_AFTER_START=1
        log_info "$(t admin_pair_after)"
        return 0
    fi
    token=$(env_value BOT_TOKEN) || token=""
    token="${token//[[:space:]]/}"
    log_warning "$(t env_claim_window)"
    prepare_claim "$token" && CLAIM_PENDING=1
    return 0
}

# --auto: .env из окружения. Пустой ALLOWED_IDS сам по себе — дыра («первый написавший получает
# root-контроль»), поэтому он проходит только с явным выбором пути: GOAMNEZIA_ADMIN_PAIR=1 — SSH-меню
# привяжет администратора сообщением сразу после установки (install_bot.sh --pair); GOAMNEZIA_ADMIN_CLAIM=1
# — установка без терминала, администратора назначит одноразовый код в окне привязки. Маркер
# .admin_claimed этот путь больше не запирает (HB-8): окна открывают установщик и SSH, а не бот раз в жизни.
env_from_environment() {
    if [[ "${BOT_TOKEN:-}" =~ $TOKEN_RE ]] && [[ "${ALLOWED_IDS:-}" =~ $IDS_RE ]]; then
        write_env "$BOT_TOKEN" "$ALLOWED_IDS" || { log_error "$(tf env_write_failed "$ENV_FILE")"; return 1; }
        forget_claim_code
        log_success "$(t env_from_environment)"
        return 0
    fi
    if [[ "${BOT_TOKEN:-}" =~ $TOKEN_RE ]] && [ -z "${ALLOWED_IDS:-}" ]; then
        if [ "${GOAMNEZIA_ADMIN_PAIR:-0}" = "1" ]; then
            write_env "$BOT_TOKEN" "" || { log_error "$(tf env_write_failed "$ENV_FILE")"; return 1; }
            forget_claim_code
            log_success "$(t env_from_environment)"
            log_info "$(t env_pair_window)"
            return 0
        fi
        if [ "${GOAMNEZIA_ADMIN_CLAIM:-0}" = "1" ]; then
            write_env "$BOT_TOKEN" "" || { log_error "$(tf env_write_failed "$ENV_FILE")"; return 1; }
            log_success "$(t env_from_environment)"
            log_warning "$(t env_claim_window)"
            prepare_claim "$BOT_TOKEN" || return 1
            CLAIM_PENDING=1
            return 0
        fi
    fi
    log_error "$(tf env_auto_missing "$ENV_FILE")"
    return 1
}

# Интерактивно: токен (read -s, формат, getMe) и кто администратор.
env_interactive() {
    local token="" username="" rc ans pick ids="" pair=0
    if [ ! -t 0 ]; then
        log_error "$(tf no_tty "$ENV_FILE")"
        return 1
    fi
    echo "" >&2
    echo -e "  ${CYAN}$(t token_help_title)${NC}" >&2
    echo -e "  $(tf token_help_1 "https://t.me/BotFather")" >&2
    echo -e "  $(t token_help_2)" >&2
    echo -e "  $(t token_help_3)" >&2
    echo -e "  $(t token_help_4)" >&2
    echo "" >&2
    while [ -z "$token" ]; do
        echo -e "  ${YELLOW}$(t ask_token)${NC}" >&2
        echo -ne "  ${DIM}>${NC} " >&2
        # read -s: токен не должен оставаться в истории терминала
        if ! IFS= read -rs token; then
            echo "" >&2
            log_error "$(tf no_tty "$ENV_FILE")"
            return 1
        fi
        echo "" >&2
        token=$(printf '%s' "$token" | tr -d '[:space:]')
        if [ -z "$token" ]; then
            log_warning "$(t token_empty)"
            continue
        fi
        if ! [[ "$token" =~ $TOKEN_RE ]]; then
            log_warning "$(t token_badfmt)"
            token=""
            continue
        fi
        log_info "$(t token_check)"
        username=$(check_token "$token")
        rc=$?
        case "$rc" in
            0) log_success "$(tf token_ok "${username:-?}")" ;;
            1) log_warning "$(t token_rejected)"; token="" ;;
            *)
                username=""
                log_warning "$(t token_unreachable)"
                echo -ne "  ${YELLOW}$(t token_continue_anyway)${NC}" >&2
                IFS= read -r ans || ans=""
                case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in
                    y|yes|д|да) ;;
                    *) token="" ;;
                esac ;;
        esac
    done

    # Кто администратор. Главный путь — привязка сообщением (docs/BOT.md «Контракт привязки»): бот
    # запустится, откроется окно, человек пишет ему любое сообщение и подтверждает себя здесь, в
    # терминале, — у постороннего его нет. Раньше установщик сам ждал в getUpdates сообщение с кодом с
    # этого экрана (а ещё раньше — «первого написавшего», SEC-B00): очередь обновлений держал он, а не
    # бот, на запущенном боте путь не работал вовсе (409), а код жил и после установки. Ручной ввод ID —
    # запасной путь. Пустой Enter — это НЕ «доступ для всех»: .env без админов бот никого не пускает.
    echo "" >&2
    echo -e "  ${YELLOW}$(t admin_title)${NC}" >&2
    echo -e "  $(t admin_auto)" >&2
    echo -e "  $(t admin_manual)" >&2
    echo -e "  ${DIM}$(t admin_legend)${NC}" >&2
    while [ -z "$ids" ] && [ "$pair" -eq 0 ]; do
        echo -ne "  ${DIM}> ${NC}" >&2
        if ! IFS= read -r pick; then
            echo "" >&2
            log_error "$(tf no_tty "$ENV_FILE")"
            return 1
        fi
        case "$(printf '%s' "$pick" | tr -d '[:space:]')" in
            ""|1) pair=1 ;;
            2)
                echo -e "  ${YELLOW}$(t ask_admins)${NC}" >&2
                echo -ne "  ${DIM}$(t admins_prompt)${NC}" >&2
                IFS= read -r ids || ids=""
                ids=$(printf '%s' "$ids" | tr -d '[:space:]')
                if [ -z "$ids" ]; then
                    log_warning "$(t admins_empty)"
                elif ! [[ "$ids" =~ $IDS_RE ]]; then
                    log_warning "$(t admins_badfmt)"
                    ids=""
                fi
                ;;
            *) log_warning "$(t admin_pick_bad)" ;;
        esac
    done
    write_env "$token" "$ids" || { log_error "$(tf env_write_failed "$ENV_FILE")"; return 1; }
    log_success "$(t env_created)"
    forget_claim_code
    if [ "$pair" -eq 1 ]; then
        PAIR_AFTER_START=1
        BOT_USERNAME="$username"
        log_info "$(t admin_pair_after)"
    fi
    return 0
}

# .env: взять существующий, создать из окружения (--auto) или спросить в терминале.
setup_env() {
    if [ -f "$ENV_FILE" ]; then
        env_existing
    elif [ "$AUTO" -eq 1 ]; then
        env_from_environment
    else
        env_interactive
    fi
}

# ── Установка ────────────────────────────────────────────────────────────────
# Подключили файл через source (тесты) — дальше установка, ей тут не место.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

for a in "$@"; do
    case "$a" in
        --auto)   AUTO=1 ;;
        --pair)   PAIR_ONLY=1 ;;
        --lang=*) LANG_CODE="${a#--lang=}" ;;
        *)
            LANG_CODE="${LANG_CODE:-$(detect_lang)}"
            log_error "$(tf bad_option "$a")"
            exit 2 ;;
    esac
done
[[ "$LANG_CODE" =~ ^(ru|en)$ ]] || LANG_CODE="$(detect_lang)"

# ── --pair: только окно привязки сообщением (бот уже стоит) ──────────────────
# SSH-меню «Telegram-бот → Администраторы → Привязать по сообщению» и мастер после установки бота.
# Права — по делу, а не по номеру пользователя: .env (0600) и файлы привязки пишет хозяин каталога бота.
if [ "$PAIR_ONLY" -eq 1 ]; then
    echo ""
    echo -e "  ${GREEN}$(t pair_title)${NC}"
    echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if [ ! -f "$ENV_FILE" ]; then
        log_error "$(tf pair_no_bot "$ENV_FILE")"
        exit 1
    fi
    if [ ! -w "$BOT_DIR" ] || [ ! -r "$ENV_FILE" ] || [ ! -w "$ENV_FILE" ]; then
        log_error "$(t need_root)"
        exit 1
    fi
    pair_by_message "" && exit 0
    exit 1
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
# Файлы лежат рядом с установщиком (goamnezia-bot/ в эталоне /opt/goamnezia).
SRC_DIR="$SCRIPT_DIR"
for f in bot.py i18n.py requirements.txt lang/ru.json lang/en.json; do
    if [ ! -f "$SRC_DIR/$f" ]; then
        log_error "$(tf src_missing "$SRC_DIR/$f")"
        exit 1
    fi
done

if ! ensure_python; then
    log_error "$(t python_missing)"
    exit 1
fi

# ── Файлы бота ───────────────────────────────────────────────────────────────
log_info "$(tf copying "$BOT_DIR")"
mkdir -p "$BOT_DIR/lang" || exit 1
chmod 700 "$BOT_DIR"
for f in bot.py i18n.py requirements.txt lang/ru.json lang/en.json; do
    copy_one "$f" || { log_error "$(tf src_missing "$f")"; exit 1; }
done
for f in config.example.env README.md; do
    [ -f "$SRC_DIR/$f" ] && copy_one "$f"
done
chmod 644 "$BOT_DIR"/*.py "$BOT_DIR"/lang/*.json 2>/dev/null || true
rm -rf "$BOT_DIR/__pycache__"

# ── venv ─────────────────────────────────────────────────────────────────────
# Проверяем НАЛИЧИЕ pip, а не каталога: после сорвавшейся попытки остаётся
# пустой venv/, и проверка каталога считала его готовым.
if [ ! -x "$BOT_DIR/venv/bin/pip" ]; then
    if [ -d "$BOT_DIR/venv" ]; then
        log_warning "$(t venv_broken)"
        rm -rf "$BOT_DIR/venv"
    fi
    log_info "$(t venv_create)"
    if ! python3 -m venv "$BOT_DIR/venv"; then
        log_error "$(t venv_failed)"
        exit 1
    fi
fi
log_info "$(t deps_install)"
if ! "$BOT_DIR/venv/bin/pip" install -q -r "$BOT_DIR/requirements.txt" >/dev/null 2>&1; then
    # Один повтор: PyPI иногда отвечает 5xx на первую попытку с нового сервера.
    sleep 3
    if ! "$BOT_DIR/venv/bin/pip" install -q -r "$BOT_DIR/requirements.txt"; then
        log_error "$(t deps_failed)"
        exit 1
    fi
fi

# ── .env ─────────────────────────────────────────────────────────────────────
setup_env || exit 1

# ── systemd ──────────────────────────────────────────────────────────────────
# От root: мост install.sh управляет docker и пишет /opt/goamnezia — тот же
# размен, что в goTelegram (демон по UNIX-сокету — этап упрочнения, PLAN §10).
# PATH явный: на старых установках юнит наследовал PATH без /usr/sbin, и мост
# не находил ss/iptables. EnvironmentFile — секреты не в юните.
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=goAmnezia pro Telegram bot
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$BOT_DIR
EnvironmentFile=$ENV_FILE
Environment=PATH=$BOT_DIR/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=PYTHONUNBUFFERED=1
Environment=GOAMNEZIA_DIR=$GOAMNEZIA_DIR
Environment=GOAMNEZIA_BOT_DIR=$BOT_DIR
ExecStart=$BOT_DIR/venv/bin/python $BOT_DIR/bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "$UNIT_FILE"
log_success "$(tf unit_written "$UNIT_FILE")"

[ -x "$ACTION_BIN" ] || log_warning "$(tf bridge_missing "$ACTION_BIN")"

BOT_RUNNING=0
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    if ! systemctl restart "$SERVICE_NAME" 2>/dev/null; then
        systemctl start "$SERVICE_NAME" 2>/dev/null || true
    fi
    sleep 2
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        log_error "$(tf unit_failed "$SERVICE_NAME" "$SERVICE_NAME")"
        exit 1
    fi
    BOT_RUNNING=1
else
    log_warning "$(t no_systemd)"
fi

echo ""
echo -e "  ${GREEN}✓ $(t done_title)${NC}"
echo ""
echo -e "  $(t done_check)  ${CYAN}systemctl status $SERVICE_NAME${NC}"
echo -e "  $(t done_logs)  ${CYAN}journalctl -u $SERVICE_NAME -f${NC}"
echo -e "  $(t done_env)  ${CYAN}$ENV_FILE${NC}"
echo ""
if [ "$CLAIM_PENDING" -eq 1 ]; then
    echo -e "  ${BOLD}${YELLOW}$(tf done_hint_claim "$(clock_of "$CLAIM_UNTIL")")${NC}"
elif [ "$PAIR_AFTER_START" -eq 1 ]; then
    # Администратора ещё нет: окно привязки — сразу, пока человек у терминала. Бот не запущен (нет
    # systemd) — написать ему некуда, окно откроют потом из SSH-меню.
    echo -e "  ${BOLD}$(t pair_title)${NC}"
    if [ "$BOT_RUNNING" -eq 1 ]; then
        pair_by_message "$BOT_USERNAME" || true
    else
        log_info "$(tf pair_later "$SCRIPT_DIR/install_bot.sh")"
    fi
else
    echo -e "  ${DIM}$(t done_hint)${NC}"
fi
echo ""
exit 0
