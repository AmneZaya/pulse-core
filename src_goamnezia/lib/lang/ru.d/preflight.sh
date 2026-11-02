#!/bin/bash
# goAmnezia pro — словарь RU, модуль lib/preflight.sh (предполётная проверка
# портов 80/443 перед выбором режима, PLAN §4.3.1).
# Метки портов («TCP/443») и команды-подсказки собирает код — они одинаковы в
# обоих языках; здесь только человеческие фразы вокруг них.
# Строки для tf содержат только %s — иначе printf споткнётся.
# shellcheck disable=SC2034,SC2148
declare -gA I18N

# ── экран выбора режима ──
I18N[preflight_title]="Режим установки"
I18N[preflight_mode_lazy]="Ленивый Pro"
I18N[preflight_desc_lazy]="Только домен, остальное сделаю сам: сертификат, сайт, AmneziaWG 2.0 на UDP 443 и 3.1, панель и 5 ключей со страницами подключения."
I18N[preflight_lazy_installed]="Здесь уже стоит goAmnezia: Ленивый Pro доставит недостающее и пользователей не тронет."
I18N[preflight_lazy_udp443_busy]="UDP 443 занят — встанет Semi-Pro."
I18N[preflight_mode_lite]="Lite"
I18N[preflight_mode_lite_site]="Semi-Pro"
I18N[preflight_mode_pro]="Pro"
I18N[preflight_desc_lite]="Только VPN: AmneziaWG на своих портах, домена и сайта нет, снаружи 80 и 443 закрыты."
I18N[preflight_desc_lite_site]="VPN и сайт: домен, сайт-заглушка и панель на 443/tcp с настоящим сертификатом; VPN на своих портах."
I18N[preflight_desc_pro]="Сайт и VPN на 443: сайт на TCP 443, AmneziaWG на UDP 443 — снаружи это обычный сайт. Какая линия встанет на 443, выбираете вы."
I18N[preflight_available]="доступен"
I18N[preflight_unavailable]="недоступен"
# Итог по портам справа от режима: раньше здесь стояло «доступен / недоступен»,
# и человек не понимал ни кому доступен, ни что мешает второму режиму.
I18N[preflight_ports_free]="порты свободны"
I18N[preflight_ports_ours_one]="порт %s — наш же, всё в порядке"
I18N[preflight_ports_ours_many]="порты %s — наши же, всё в порядке"
I18N[preflight_udp443_ours]="UDP 443 — наша линия %s, всё в порядке."
I18N[preflight_udp443_ours_other]="UDP 443 — наш профиль %s, всё в порядке."
I18N[preflight_ports_busy]="порт %s занят"
I18N[preflight_ports_closed]="порт %s закрыт файрволом"
I18N[preflight_ports_unknown]="состояние портов неизвестно"
I18N[preflight_legend_marks]="Значки: ✓ — режим можно выбрать, ✗ — сначала освободите названный порт."
I18N[preflight_legend_pick]="Как выбрать: 1 — есть домен, и пусть всё сделается само; 2 и 3 — домен есть, разница только в том, где стоит VPN; 4 — домена нет."
I18N[preflight_prompt]="Повторить проверку — %s, выбрать доступный режим — цифра, выйти — 0."
I18N[preflight_prompt_brief]="Повторить проверку портов — %s."
I18N[preflight_rechecking]="Повторяю проверку портов…"
I18N[preflight_mode_blocked]="Режим «%s» сейчас недоступен: %s"
I18N[preflight_mode_blocked_hint]="Освободите порт и выберите режим снова — проверка портов повторится сама."

# ── причины и предупреждения ──
I18N[preflight_reason_busy]="%s занят: %s"
I18N[preflight_reason_closed]="%s закрыт локальным файрволом (%s)"
I18N[preflight_warn_udp443]="UDP/443 занят: %s — профили встанут на свои порты, а режим Pro (VPN на UDP/443) недоступен, пока порт занят"
I18N[preflight_warn_unknown]="%s: проверить не удалось (%s) — считаем свободным, убедитесь вручную"
I18N[preflight_warn_fw_unknown]="%s: состояние локального файрвола не определено (%s) — если сайт не откроется, проверьте его вручную"
I18N[preflight_note_no_ss]="нет команды ss — установите iproute2"
I18N[preflight_who_pid]="PID %s"
I18N[preflight_who_unit]="юнит %s"
I18N[preflight_who_container]="контейнер %s"
I18N[preflight_who_unknown]="процесс не виден — запустите проверку от root"
I18N[preflight_looks_like]="похоже, это %s"
I18N[preflight_hint_free]="Освободите порт (например: %s) или используйте чистый сервер."
I18N[preflight_hint_free_generic]="Освободите порт или используйте чистый сервер."
I18N[preflight_hint_closed]="Порт закрыт локально: мастер предложит открыть его (%s)."
I18N[preflight_ask_open]="Открыть %s в локальном файрволе (%s)?"

# ── источники сведений о файрволе ──
I18N[preflight_fw_src_ufw]="ufw активен, правила для порта нет"
I18N[preflight_fw_src_iptables]="правило iptables в цепочке INPUT"
I18N[preflight_fw_src_nft]="правило nftables в цепочке input"
I18N[preflight_fw_src_none]="файрвол не обнаружен"

# ── продукты серии (человеческие имена) ──
I18N[preflight_product_gotelegram]="goTelegram Pro"
I18N[preflight_product_govless]="goVLESS Pro"
I18N[preflight_product_godns]="goDNS"
I18N[preflight_product_gowarp]="goWARP PRO"
I18N[preflight_product_gokaskad]="goKaskad PRO"
I18N[preflight_product_xui]="панель 3x-ui"
I18N[preflight_product_amnezia]="приложение Amnezia (контейнер не из нашего config.json)"
I18N[preflight_product_goamnezia]="goAmnezia pro (наша установка)"

# ── открытие порта в локальном файрволе ──
I18N[preflight_open_ufw]="Открываю %s/%s в ufw…"
I18N[preflight_open_iptables]="ufw не активен — добавляю правило iptables для %s/%s…"
I18N[preflight_open_done]="Порт %s/%s открыт в локальном файрволе (%s). Файрвол хостинга (security group, панель провайдера) проверьте отдельно"
I18N[preflight_open_failed]="Не удалось открыть %s/%s: команда «%s» завершилась с ошибкой"
I18N[preflight_open_no_tool]="Нет ни ufw, ни iptables — откройте порт %s/%s вручную (nftables: правило accept в цепочке input)"
I18N[preflight_open_nft]="Порт %s/%s закрывает nftables своей таблицей — правило iptables его не откроет, поэтому сам не трогаю. Откройте его в своей таблице, например: %s (имена таблицы и цепочки — как у вас в nft list ruleset) и сохраните в /etc/nftables.conf"
I18N[preflight_open_persist_warn]="Правило iptables не сохранено (нет netfilter-persistent) — после перезагрузки порт снова закроется"

# ── ошибки вызова ──
I18N[preflight_err_args]="preflight: ожидается протокол tcp|udp и порт 1–65535, получено: %s %s"
I18N[preflight_err_no_jq]="preflight: нет jq — без него не собрать JSON проверки"
I18N[preflight_err_json]="preflight: экран не построен — на вход пришёл не JSON preflight_modes"
# Строка «что выбрать, если не уверены»: без неё выбор между вторым и третьим
# режимом остаётся гаданием — они отличаются только местом VPN.
I18N[preflight_legend_unsure]="Не уверены и своего домена нет — жмите Enter (Lite). Есть домен — берите Ленивый Pro: вводите только домен, остальное скрипт сделает сам."
I18N[preflight_again_item]="Повторить проверку портов"
