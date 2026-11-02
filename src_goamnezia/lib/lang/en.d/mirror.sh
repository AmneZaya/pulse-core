#!/bin/bash
# goAmnezia pro — EN dictionary, module lib/mirror.sh (app build mirror)
# shellcheck disable=SC2034,SC2148

declare -gA I18N

# ── Failures ─────────────────────────────────────────────────────────────────
I18N[mirror_err_no_jq]="jq is missing — the build mirror cannot work"
I18N[mirror_err_no_curl]="curl is missing — there is nothing to download the build with"
I18N[mirror_err_target]="Invalid app or platform: %s / %s (platforms: android, android_tv, windows, macos, linux)"
I18N[mirror_err_unknown_app]="App %s is not in the catalog lib/clients.json"
I18N[mirror_err_not_mirrorable]="The %s build for %s cannot be mirrored: the app is closed or store-only"
I18N[mirror_err_busy]="The %s build for %s is already downloading — wait for it to finish"
I18N[mirror_err_catalog]="The app catalog %s is missing"
I18N[mirror_err_dry_network]="Offline test bench: the build is not downloaded (set GOAMNEZIA_MIRROR_CURL)"
I18N[mirror_err_fetch]="Failed to download %s"
I18N[mirror_err_no_release]="Repository %s has no published release"
I18N[mirror_err_no_asset]="Release %s %s has no file matching %s"
I18N[mirror_err_no_digest]="The source gave no checksum for %s from release %s — the build is not published"
I18N[mirror_err_too_big]="File %s is %s MB — above the %s MB limit (mirror.max_file_mb)"
I18N[mirror_err_total]="The mirror would take %s MB — above the %s MB limit (mirror.max_total_mb); remove unneeded builds"
I18N[mirror_err_disk]="%s MB free, at least %s MB needed (file size plus a gigabyte of headroom)"
I18N[mirror_err_size]="The size of the downloaded %s does not match what the source announced — the file was discarded"
I18N[mirror_err_sha]="The checksum of the downloaded %s does not match what the source announced — the file was discarded"
I18N[mirror_err_write]="Failed to write %s"
I18N[mirror_err_tmp]="Failed to create a temporary file"

# ── Progress ─────────────────────────────────────────────────────────────────
I18N[mirror_warn_license]="The license file from %s (%s) did not download — LICENSE holds the license name and a link"
I18N[mirror_warn_stale]="The %s download for %s was abandoned (the process is gone) — marked as failed, a new request is accepted"
I18N[mirror_queued]="Download of the %s build for %s queued"
I18N[mirror_started]="Downloading %s for %s: version %s, %s MB"
I18N[mirror_ready]="The %s build for %s is published: version %s"
I18N[mirror_current]="The %s build for %s is already current: version %s"
I18N[mirror_removed]="The %s build for %s was removed from the mirror"
I18N[mirror_tick_done]="Requests: %s, downloads started: %s, deferred by limits: %s; copies checked: %s, updates: %s"
