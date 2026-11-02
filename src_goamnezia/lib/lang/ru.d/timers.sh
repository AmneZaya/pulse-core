#!/bin/bash
# goAmnezia pro — словарь RU, модуль lib/timers.sh (таймеры systemd продукта)
# shellcheck disable=SC2034,SC2148

I18N[timers_desc_quota]="goAmnezia pro — лимиты и сроки пользователей (каждые 5 минут)"
I18N[timers_desc_watch]="goAmnezia pro — сторож контейнеров (каждые 2 минуты)"
I18N[timers_desc_stats]="goAmnezia pro — статистика трафика по суткам (каждые 10 минут)"
I18N[timers_desc_upstream]="goAmnezia pro — проверка обновлений Amnezia (раз в сутки, без автообновления)"
I18N[timers_desc_cert]="goAmnezia pro — срок сертификата сайта (раз в сутки)"
I18N[timers_err_write]="Не удалось записать юнит %s"
I18N[timers_err_enable]="Не удалось включить таймер %s (systemctl enable --now)"
I18N[timers_installed]="Таймеры goAmnezia установлены: %s"
I18N[timers_unchanged]="Таймеры goAmnezia на месте, изменений нет"
I18N[timers_removed]="Таймеры goAmnezia удалены"
I18N[timers_backup_default]="Ежедневный бэкап включён по умолчанию (03:20) — настраивается в «Обслуживание → Бэкап»"
I18N[timer_busy_skipped]="%s: занято — пропущено, следующий запуск по таймеру (идёт установка, обновление или другое действие)"
