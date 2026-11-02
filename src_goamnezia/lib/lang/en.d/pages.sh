#!/bin/bash
# goAmnezia pro — EN dictionary, module lib/pages.sh (connection page)
# shellcheck disable=SC2034,SC2148

declare -gA I18N

# ── Failures ─────────────────────────────────────────────────────────────────
I18N[pages_err_no_jq]="jq is missing — the connection page cannot be built"
I18N[pages_err_no_python]="python3 is missing — there is nothing to run the connection pages service with"
I18N[pages_err_need_domain]="A connection page opens only on a domain with a trusted certificate, and there is none right now: connect a domain (the Semi-Pro mode) or hand the key over with a temporary file link"
I18N[pages_err_ttl]="Invalid page lifetime: %s (hours 1h…720h, days 1d…365d or forever)"
I18N[pages_err_id]="Invalid page id: %s"
I18N[pages_err_not_found]="Page %s not found — it has expired or been revoked"
I18N[pages_err_limit]="There are already %s connection pages — the limit. Revoke the ones you no longer need in the user cards: in SSH — «Connection page», in the bot — «📑 User's pages», in the panel — «Connection pages»"
I18N[pages_err_profiles]="Invalid profile list: %s (awg1, awg2, awg3 separated by commas)"
I18N[pages_err_peer]="User %s has no key in profile %s — a page for that profile cannot be built"
I18N[pages_err_no_peers]="User %s has no keys at all — there is nothing to build the page from"
I18N[pages_err_no_privkey]="The keys of %s (profiles: %s) were issued in the Amnezia app before the takeover and are not on the server — the page would not show the user a single key. Bring them to the server with «Attach the old key» (the vpn:// link or .conf file you once sent them) — nothing changes for the user; or reissue the key — then the old one stops connecting at once"
I18N[pages_err_toggle]="Expected on or off for the mirror, got: %s"
I18N[pages_err_disabled]="User %s is disabled — the page would not open; enable the user and retry"
I18N[pages_err_name]="Invalid user name: %s"
I18N[pages_err_state_dir]="Failed to create the pages directory %s"
I18N[pages_err_write]="Failed to write %s"
I18N[pages_err_secret]="Failed to get a random secret for the page address"
I18N[pages_err_unit]="Failed to write the pages service unit %s"
I18N[pages_err_unit_start]="Failed to start the pages service %s (systemctl enable --now)"
I18N[pages_err_catalog]="The app catalog %s is missing or unreadable"
I18N[pages_err_platform]="Unknown platform: %s (ios, android, android_tv, tvos, windows, macos, linux, router)"
I18N[pages_err_line]="Unknown line: %s (1.0, 1.5, 2.0, 3.1)"

# ── Progress ─────────────────────────────────────────────────────────────────
I18N[pages_created]="Connection page for %s created, stops working %s"
I18N[pages_created_forever]="Permanent connection page for %s created"
I18N[pages_warn_forever]="Whoever knows the link gets the keys, and the link never expires. If the link leaks, revoke the page"
I18N[pages_warn_imported]="The keys of %s on %s were issued in the Amnezia app and are not on the server — there the page shows an explanation instead of a key. To have that key on the page too, attach the old one: user card → «Key: QR, file, link» → «Attach the old key»"
I18N[pages_revoked]="Page %s revoked"
I18N[pages_revoked_sub]="Subscription of %s reissued: the old subscription address no longer opens, the new one is on the user's other pages and under «Show the addresses»"
I18N[pages_revoked_sub_failed]="The page is revoked, but the subscription of %s could not be reissued — reissue it in the user card"
I18N[pages_revoked_sub_none]="%s has no subscription — nothing to reissue, only the page is revoked"
I18N[pages_revoked_keys]="Keys of %s reissued (%s): the old keys no longer connect — hand the user the new ones"
I18N[pages_revoked_keys_failed]="The page is revoked, but the keys of %s could not be reissued (%s) — reissue them in the user card"
I18N[pages_revoked_keys_none]="%s has no server-held keys on the page profiles — nothing to reissue"
I18N[pages_revoked_all]="Pages revoked: %s"
I18N[pages_revoked_mode]="The site left the domain — connection pages revoked: %s (they do not open without a domain)"
I18N[pages_none]="There are no connection pages"
I18N[pages_tick_done]="Expired pages removed: %s, active: %s"
I18N[pages_unit_restarted]="The connection pages service was restarted"
I18N[pages_unit_removed]="The connection pages and subscriptions service was stopped: it has nothing left to serve on the domain"
