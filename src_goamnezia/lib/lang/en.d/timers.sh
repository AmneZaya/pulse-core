#!/bin/bash
# goAmnezia pro — словарь EN, модуль lib/timers.sh (таймеры systemd продукта)
# shellcheck disable=SC2034,SC2148

I18N[timers_desc_quota]="goAmnezia pro - user quotas and expiry (every 5 minutes)"
I18N[timers_desc_watch]="goAmnezia pro - container watchdog (every 2 minutes)"
I18N[timers_desc_stats]="goAmnezia pro - daily traffic statistics (every 10 minutes)"
I18N[timers_desc_upstream]="goAmnezia pro - Amnezia update check (daily, no auto-update)"
I18N[timers_desc_cert]="goAmnezia pro - site certificate expiry (daily)"
I18N[timers_err_write]="Failed to write unit %s"
I18N[timers_err_enable]="Failed to enable timer %s (systemctl enable --now)"
I18N[timers_installed]="goAmnezia timers installed: %s"
I18N[timers_unchanged]="goAmnezia timers are in place, nothing changed"
I18N[timers_removed]="goAmnezia timers removed"
I18N[timers_backup_default]="Daily backup enabled by default (03:20) — configurable in Maintenance → Backup"
I18N[timer_busy_skipped]="%s: busy — skipped, the next run is on schedule (an installation, update or another action is in progress)"
