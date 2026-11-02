#!/bin/bash
# goAmnezia pro — словарь EN, модуль lib/stats.sh (статистика трафика по суткам)
# shellcheck disable=SC2034,SC2148

I18N[stats_err_write]="Failed to write stats.json"
I18N[stats_tick_done]="Traffic statistics: profiles %s, today ↓ %s ↑ %s"
I18N[stats_corrupt]="File %s does not parse — statistics are not being updated. Rescued copy: %s"
I18N[stats_corrupt_nocopy]="File %s does not parse and could not be rescued — statistics are not being updated"
I18N[stats_corrupt_howto]="Remove %s — it is derived data and will be rebuilt from the next count (every 10 minutes)"
I18N[stats_corrupt_short]="File %s does not parse — statistics are not being updated"
