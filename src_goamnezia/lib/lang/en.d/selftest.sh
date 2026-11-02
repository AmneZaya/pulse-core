#!/bin/bash
# goAmnezia pro — English dictionary fragment for lib/selftest.sh.
# shellcheck disable=SC2034,SC2148
#
# A fragment rather than core: self-test strings are only for developers and
# should not bloat the dictionary that every menu run loads. It doubles as a
# working example of the lib/lang/<lang>.d/ mechanism for the other modules.

# The array declaration is repeated in every dictionary file: a fragment can
# then be loaded and linted on its own, and shellcheck stops treating
# I18N[key] as an indexed subscript and firing SC2154 on every line.
declare -gA I18N

# Service key: the self-test uses it to prove fragments are loaded at all.
# If load_language ever stops picking them up, the "fragments" check will see
# the key name instead of this text and fail.
I18N[selftest_fragment_probe]="dictionary fragments loaded"

# ── Frame ────────────────────────────────────────────────────────────────────
I18N[selftest_title]="goAmnezia pro v%s — self-test (--selftest)"
I18N[selftest_sandbox]="Nothing is installed or changed; everything happens in %s"
I18N[selftest_expected]="expected"
I18N[selftest_got]="got"
I18N[selftest_skipped]="skipped"
I18N[selftest_total]="Total"
I18N[selftest_passed]="%s passed"
I18N[selftest_failed]="%s failed"
I18N[selftest_skipped_n]="%s skipped"

# ── Section headers ──────────────────────────────────────────────────────────
I18N[selftest_head_syntax]="1. Syntax"
I18N[selftest_head_i18n]="2. Dictionaries and the i18n engine"
I18N[selftest_head_validators]="3. Input validators"
I18N[selftest_head_arch]="4. Architecture"
I18N[selftest_head_emit]="5. Bridge response (ga_emit_json)"
I18N[selftest_head_config]="6. config.json"
I18N[selftest_head_users]="7. users.json"
I18N[selftest_head_lock]="8. Shared lock"
I18N[selftest_head_deps]="9. Dependencies"
I18N[selftest_head_logb]="10. Log budget"
I18N[selftest_head_backup]="11. Backup"

# ── Checks ───────────────────────────────────────────────────────────────────
I18N[selftest_syntax_clean]="bash -n: every script is clean"
I18N[selftest_i18n]="i18n"
I18N[selftest_i18n_unknown_key]="an unknown key prints itself"
I18N[selftest_i18n_fragments]="lib/lang/<lang>.d/*.sh fragments are picked up"
I18N[selftest_i18n_parity]="dictionary core: ru and en are symmetric (%s keys)"

I18N[selftest_valid_name_ok]="validate_name accepts a normal name"
I18N[selftest_valid_name_space]="validate_name rejects a space"
I18N[selftest_valid_name_empty]="validate_name rejects an empty value"
I18N[selftest_valid_name_long]="validate_name rejects longer than 32"
I18N[selftest_valid_name_newline]="validate_name rejects a newline"
I18N[selftest_valid_port_ok]="validate_port accepts 443"
I18N[selftest_valid_port_zero]="validate_port rejects 0"
I18N[selftest_valid_port_big]="validate_port rejects 70000"
I18N[selftest_valid_port_text]="validate_port rejects a non-number"
I18N[selftest_valid_profile_ok]="validate_profile accepts awg2"
I18N[selftest_valid_profile_bad]="validate_profile rejects a foreign profile"
I18N[selftest_valid_domain_ok]="validate_domain accepts a domain"
I18N[selftest_valid_domain_multi]="validate_domain rejects a multiline value"

I18N[selftest_arch_amd64]="get_arch returns amd64 on x86_64"
I18N[selftest_arch_refused]="get_arch refuses with the unsupported_arch code"

I18N[selftest_emit_escape]="ga_emit_json escapes quotes and backslashes"
I18N[selftest_emit_one_line]="ga_emit_json prints exactly one line"
I18N[selftest_emit_at_json]="ga_emit_json inlines @json: without quoting"
I18N[selftest_emit_at_json_bad]="ga_emit_json survives a broken @json:"
I18N[selftest_emit_bad_key]="ga_emit_json drops an unsafe field name"

I18N[selftest_config]="config.json"
I18N[selftest_config_get]="ga_config_get reads a value"
I18N[selftest_config_get_null]="ga_config_get returns empty for a missing key"
I18N[selftest_config_set]="ga_config_set writes a value"
I18N[selftest_config_perm]="config.json stays 0600"
I18N[selftest_config_merge_keeps]="ga_config_merge keeps the neighbouring profile"
I18N[selftest_config_merge_adds]="ga_config_merge adds a new profile"
I18N[selftest_config_bad_path]="ga_config_set rejects a dangerous jq path"
I18N[selftest_config_atomic]="broken JSON does not overwrite a working config"
I18N[selftest_config_no_tmp]="no temporary files are left after a failure"

I18N[selftest_users]="users.json"
I18N[selftest_users_skeleton]="ga_users_read returns an empty skeleton with no file"
I18N[selftest_users_roundtrip]="ga_users_write and ga_users_read keep the data"
I18N[selftest_users_perm]="users.json stays 0600"
I18N[selftest_users_corrupt]="a broken users.json is not passed off as an empty list"

I18N[selftest_lock_reentrant]="ga_with_config_lock is reentrant"
I18N[selftest_lock_probe_written]="a write under the nested lock reached the file"
I18N[selftest_lock_flag_cleared]="the lock flag does not leak out"

I18N[selftest_deps]="dependencies"
I18N[selftest_deps_json]="deps_report_json is valid and self-consistent"

I18N[selftest_logb]="log budget"
I18N[selftest_logb_guard]="safety rail: /var/log without a mask is left alone"
I18N[selftest_logb_mb]="bytes to MB conversion"

I18N[selftest_backup]="backup"
I18N[selftest_backup_daily]="the daily schedule yields a systemd calendar"
I18N[selftest_backup_off]="the off schedule yields an empty calendar"
I18N[selftest_backup_bad]="an unknown frequency is rejected"
I18N[selftest_backup_restore_soft]="profile restore without lib/amnezia.sh does not fail"
I18N[selftest_head_sprint4]="12. Updates, import, timers"
I18N[selftest_sprint4]="sprint 4"
I18N[selftest_sprint4_patch]="the start.sh patch reproduces awg/start.sh from upstream"
I18N[selftest_sprint4_import_name]="an imported user name is transliterated"
I18N[selftest_sprint4_import_dup]="a taken name gets the -2 suffix"
I18N[selftest_sprint4_timer]="quota timer schedule: quota-tick every 5 minutes"
I18N[selftest_sprint4_timer_bad]="an unknown timer is rejected"
I18N[selftest_head_line]="13. Profile line"
I18N[selftest_line]="profile line"
I18N[selftest_line_field]="the config.json line field is the source of truth (awg2 with a 3.x config gives 3.1)"
I18N[selftest_line_base]="base line: 1.0 and 1.5 are one family, 3.1 stays 3.1"
I18N[selftest_line_derive]="an empty line field is derived from the actual parameters"
I18N[selftest_line_migrate]="the migration writes the derived line back into config.json"
I18N[selftest_line_migrate_idem]="a repeated migration writes nothing"
I18N[selftest_line_fresh]="with no parameters the identifier default stands"
