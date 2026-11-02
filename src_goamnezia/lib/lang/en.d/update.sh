#!/bin/bash
# goAmnezia pro — EN dictionary: writing service files, updates and their rollback, disk space
# (lib/update.sh, lib/common.sh — ga_write_file, lib/i18n.sh — save_language; findings OPS-01…05)
# shellcheck disable=SC2034,SC2148

I18N[ops_write_failed]="Could not write %s: the disk is full or not writable"
I18N[ops_lang_write_failed]="Language not saved: could not write %s — the disk is full or not writable"

# The migration is one piece (OPS-03)
I18N[ops_mig_resume]="Finishing the interrupted update %s → %s: the steps are repeated from the same snapshot"
I18N[ops_mig_unfinished]="The migration to %s is not finished — the next run (menu, bot or timer) will complete it from the same snapshot"

# Rolling back a failed update (OPS-02, lib/update.sh)
I18N[ops_upd_failed]="The update to %s failed: %s"
I18N[ops_upd_why_snapshot]="the data snapshot before the update could not be taken"
I18N[ops_upd_why_record]="the update mark could not be written — is the disk full?"
I18N[ops_upd_why_migration]="moving the data to the new version stopped with an error"
I18N[ops_upd_why_check]="the new version did not answer the status check"
I18N[ops_upd_rolling_back]="Restoring the previous version %s: code, settings, keys and users as before the update…"
I18N[ops_upd_data_restored]="Settings, keys and users are as before the update (copy %s)"
I18N[ops_upd_data_failed]="The data could not be restored from the copy %s — restore it: «Maintenance → Restore from a backup»"
I18N[ops_upd_units_restored]="systemd services and timers are as before the update (%s)"
I18N[ops_upd_units_snapshot_failed]="Could not copy the systemd units — a rollback would leave the new version's ones"
I18N[ops_upd_code_restored]="The previous version %s is running. Repeat «Maintenance → Update goAmnezia» later; if it fails again, send the log /var/log/goamnezia.log"
I18N[ops_upd_code_failed]="The previous code could not be put back — install the version again with the install command; the data is in place"
I18N[ops_upd_notify]="The goAmnezia pro update to %s failed (%s). The previous version %s is back — keys, users and settings are as before the update."
I18N[ops_upd_notify_stuck]="The goAmnezia pro update to %s failed (%s), and it could not all be put back — open the server's SSH menu."
I18N[ops_upd_restart_old]="Starting the previous version %s…"
I18N[ops_upd_restart_disk]="The code on disk has changed — starting version %s…"
I18N[ops_upd_done]="Update %s → %s finished, the copy of the previous code is removed"
I18N[ops_upd_header]="The update to %s failed (%s): %s — the previous version %s is running"
I18N[ops_upd_header_stuck]="The update to %s failed (%s): %s, and the previous code could not be put back — install the version again with the install command"
# Disk space in the main menu header (OPS-01)
I18N[ops_disk_low]="The disk is %s%% full, %s MB free — core updates and backups will soon start failing. Details — «Maintenance → Diagnostics»"
I18N[ops_disk_critical]="The disk is almost full: %s%% used, %s MB free — backups will not be taken, updates will fail, a setting may not be saved. Free some space; details — «Maintenance → Diagnostics»"

# Client isolation right after a container starts (OPS-05, lib/timers.sh)
I18N[ops_iso_unit_desc]="goAmnezia pro — client isolation right after a profile container starts"

I18N[ops_upd_check_skipped]="The new version did not answer the status check within 2 minutes — skipping the check (is Docker busy?)"
