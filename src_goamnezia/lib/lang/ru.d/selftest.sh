#!/bin/bash
# goAmnezia pro — русский фрагмент словаря для lib/selftest.sh.
# shellcheck disable=SC2034,SC2148
#
# Фрагмент, а не ядро: строки автопроверки нужны только разработчику и не
# должны раздувать словарь, который читают при каждом запуске меню. Заодно это
# рабочий образец механизма lib/lang/<lang>.d/ для остальных модулей.

# Объявление массива повторяется в каждом файле словаря: так фрагмент можно
# проверить и загрузить отдельно, а shellcheck перестаёт считать I18N[ключ]
# индексом массива и ругаться SC2154 на каждую строку.
declare -gA I18N

# Служебный ключ: по нему selftest убеждается, что фрагменты вообще грузятся.
# Если однажды load_language перестанет их подхватывать, проверка «фрагменты .d»
# увидит здесь имя ключа вместо текста и упадёт.
I18N[selftest_fragment_probe]="фрагменты словаря загружены"

# ── Рамка ────────────────────────────────────────────────────────────────────
I18N[selftest_title]="goAmnezia pro v%s — автопроверка (--selftest)"
I18N[selftest_sandbox]="Ничего не устанавливается и не меняется; всё в %s"
I18N[selftest_expected]="ждали"
I18N[selftest_got]="получили"
I18N[selftest_skipped]="пропуск"
I18N[selftest_total]="Итог"
I18N[selftest_passed]="%s пройдено"
I18N[selftest_failed]="%s провалено"
I18N[selftest_skipped_n]="%s пропущено"

# ── Заголовки разделов ───────────────────────────────────────────────────────
I18N[selftest_head_syntax]="1. Синтаксис"
I18N[selftest_head_i18n]="2. Словари и движок i18n"
I18N[selftest_head_validators]="3. Валидаторы входа"
I18N[selftest_head_arch]="4. Архитектура"
I18N[selftest_head_emit]="5. Ответ моста (ga_emit_json)"
I18N[selftest_head_config]="6. config.json"
I18N[selftest_head_users]="7. users.json"
I18N[selftest_head_lock]="8. Единый замок"
I18N[selftest_head_deps]="9. Зависимости"
I18N[selftest_head_logb]="10. Бюджет логов"
I18N[selftest_head_backup]="11. Бэкап"

# ── Проверки ─────────────────────────────────────────────────────────────────
I18N[selftest_syntax_clean]="bash -n: все скрипты чисты"
I18N[selftest_i18n]="i18n"
I18N[selftest_i18n_unknown_key]="неизвестный ключ печатается как есть"
I18N[selftest_i18n_fragments]="фрагменты lib/lang/<язык>.d/*.sh подхватываются"
I18N[selftest_i18n_parity]="ядро словаря: ru и en симметричны (%s ключей)"

I18N[selftest_valid_name_ok]="validate_name принимает обычное имя"
I18N[selftest_valid_name_space]="validate_name отвергает пробел"
I18N[selftest_valid_name_empty]="validate_name отвергает пустое"
I18N[selftest_valid_name_long]="validate_name отвергает длиннее 32"
I18N[selftest_valid_name_newline]="validate_name отвергает перевод строки"
I18N[selftest_valid_port_ok]="validate_port принимает 443"
I18N[selftest_valid_port_zero]="validate_port отвергает 0"
I18N[selftest_valid_port_big]="validate_port отвергает 70000"
I18N[selftest_valid_port_text]="validate_port отвергает не-число"
I18N[selftest_valid_profile_ok]="validate_profile принимает awg2"
I18N[selftest_valid_profile_bad]="validate_profile отвергает чужой профиль"
I18N[selftest_valid_domain_ok]="validate_domain принимает домен"
I18N[selftest_valid_domain_multi]="validate_domain отвергает многострочное значение"

I18N[selftest_arch_amd64]="get_arch на x86_64 отдаёт amd64"
I18N[selftest_arch_refused]="get_arch отказывает с кодом unsupported_arch"

I18N[selftest_emit_escape]="ga_emit_json экранирует кавычки и слэши"
I18N[selftest_emit_one_line]="ga_emit_json печатает ровно одну строку"
I18N[selftest_emit_at_json]="ga_emit_json вставляет @json: без кавычек"
I18N[selftest_emit_at_json_bad]="ga_emit_json не падает на битом @json:"
I18N[selftest_emit_bad_key]="ga_emit_json отбрасывает небезопасное имя поля"

I18N[selftest_config]="config.json"
I18N[selftest_config_get]="ga_config_get читает значение"
I18N[selftest_config_get_null]="ga_config_get на отсутствующем ключе даёт пусто"
I18N[selftest_config_set]="ga_config_set записывает значение"
I18N[selftest_config_perm]="config.json остаётся 0600"
I18N[selftest_config_merge_keeps]="ga_config_merge не сносит соседний профиль"
I18N[selftest_config_merge_adds]="ga_config_merge добавляет новый профиль"
I18N[selftest_config_bad_path]="ga_config_set отвергает опасный путь jq"
I18N[selftest_config_atomic]="битый JSON не затирает рабочий конфиг"
I18N[selftest_config_no_tmp]="после сбоя не остаётся временных файлов"

I18N[selftest_users]="users.json"
I18N[selftest_users_skeleton]="ga_users_read без файла даёт пустой скелет"
I18N[selftest_users_roundtrip]="ga_users_write и ga_users_read сохраняют данные"
I18N[selftest_users_perm]="users.json остаётся 0600"
I18N[selftest_users_corrupt]="битый users.json не выдаётся за пустой список"

I18N[selftest_lock_reentrant]="ga_with_config_lock реентрантен"
I18N[selftest_lock_probe_written]="запись под вложенным замком дошла до файла"
I18N[selftest_lock_flag_cleared]="флаг замка не протекает наружу"

I18N[selftest_deps]="зависимости"
I18N[selftest_deps_json]="deps_report_json валиден и связен"

I18N[selftest_logb]="бюджет логов"
I18N[selftest_logb_guard]="предохранитель: /var/log без маски не трогаем"
I18N[selftest_logb_mb]="перевод байтов в МБ"

I18N[selftest_backup]="бэкап"
I18N[selftest_backup_daily]="расписание daily даёт календарь systemd"
I18N[selftest_backup_off]="расписание off даёт пустой календарь"
I18N[selftest_backup_bad]="неизвестная периодичность отвергается"
I18N[selftest_backup_restore_soft]="восстановление профилей без lib/amnezia.sh не падает"
I18N[selftest_head_sprint4]="12. Обновления, импорт, таймеры"
I18N[selftest_sprint4]="спринт 4"
I18N[selftest_sprint4_patch]="патч start.sh воспроизводит awg/start.sh из upstream"
I18N[selftest_sprint4_import_name]="имя импортированного пользователя латинизируется"
I18N[selftest_sprint4_import_dup]="занятое имя получает суффикс -2"
I18N[selftest_sprint4_timer]="расписание таймера quota: quota-tick каждые 5 минут"
I18N[selftest_sprint4_timer_bad]="неизвестный таймер отвергается"
I18N[selftest_head_line]="13. Линейка профиля"
I18N[selftest_line]="линейка профиля"
I18N[selftest_line_field]="поле line в config.json — источник правды (awg2 с 3.x-конфигом даёт 3.1)"
I18N[selftest_line_base]="линейка-основание: 1.0 и 1.5 — одно семейство, 3.1 остаётся 3.1"
I18N[selftest_line_derive]="пустое поле line выводится по фактическим параметрам"
I18N[selftest_line_migrate]="миграция записывает выведенную линейку обратно в config.json"
I18N[selftest_line_migrate_idem]="повторная миграция ничего не пишет"
I18N[selftest_line_fresh]="без параметров остаётся умолчание идентификатора"
