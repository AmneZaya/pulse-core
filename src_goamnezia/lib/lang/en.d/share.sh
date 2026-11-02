#!/bin/bash
# goAmnezia pro — EN dictionary, module lib/share.sh (temporary download link)
# shellcheck disable=SC2034,SC2148

declare -gA I18N

# ── Failures ─────────────────────────────────────────────────────────────────
I18N[share_err_no_jq]="jq is missing — the download link cannot be built"
I18N[share_err_no_python]="python3 is missing — there is nothing to serve the link with"
I18N[share_err_format]="Unknown link format: %s (conf, vpn, qr-conf, qr-vpn, all)"
I18N[share_err_target]="Invalid user or profile for the link: %s / %s"
I18N[share_err_disabled]="User %s is disabled — the file from the link would not connect; enable the user and retry"
I18N[share_err_id]="Invalid share id: %s"
I18N[share_err_not_found]="Share %s not found — it has already expired or been revoked"
I18N[share_err_limit]="Already %s concurrent shares out of %s — wait for them to expire or revoke some in the «Active shares» list (in SSH — the Users section, in the bot — Maintenance, in the panel — Temporary file links)"
I18N[share_err_state_dir]="Failed to create the shares directory %s"
I18N[share_err_write]="Failed to write %s"
I18N[share_err_secret]="Failed to get a random secret for the link address"
I18N[share_err_archive]="Failed to build the archive %s"
I18N[share_err_no_port]="No free port found for the share (attempts: %s)"
I18N[share_err_no_host]="The server address is unknown — there is nothing to hang the link on"
I18N[share_err_cert]="No certificate for HTTPS. A file with a private key is served over HTTPS only, so without a certificate there is no link"
I18N[share_err_start]="The share did not come up on port %s: %s"

# ── Warnings ─────────────────────────────────────────────────────────────────
I18N[share_warn_ttl]="Link lifetime %s is out of bounds — using %s seconds"
I18N[share_warn_selfsigned]="The certificate is self-signed: the browser will warn about it. Check the SHA-256 fingerprint: %s"
I18N[share_warn_firewall]="Port %s is closed by the local firewall and could not be opened — the link will not open from outside"
I18N[share_warn_no_qr]="QR codes are not in the bundle: qrencode is missing. The key itself in the archive is complete"

# ── Progress ─────────────────────────────────────────────────────────────────
I18N[share_fw_opened]="Port %s opened in the local firewall for the share"
I18N[share_fw_closed]="Port %s closed again"
I18N[share_created]="Link to %s created: port %s, lifetime %s seconds"
I18N[share_revoked]="Share %s revoked"
I18N[share_revoked_all]="Shares revoked: %s"
I18N[share_none]="No active shares"
I18N[share_tick_done]="Expired shares removed: %s, active left: %s"

# ── SSH menu screen (user card item and the "Shares" screen) ─────────────────
# These strings live here rather than in the menu dictionary: that way the item
# is added to install.sh without touching lib/lang/*.d/menu.sh — docs/SHARE.md §5.
I18N[share_menu_item]="Download as a file over a link"
I18N[share_menu_title]="Temporary file link"
I18N[share_menu_hint]="The link is for moving the key to your own phone within %s: open it on the phone and the file downloads right away. Anyone with the address gets the key."
I18N[share_menu_friend_page]="For a friend the connection page is handier — the «Connection page» item of the card: the link lives hours or days and holds the app, the key and the steps."
I18N[share_menu_pick_format]="What goes into the file?"
I18N[share_menu_fmt_conf]="AmneziaWG config (.conf) — for the AmneziaWG client and routers"
I18N[share_menu_fmt_vpn]="Amnezia app key (.vpn)"
I18N[share_ui_link]="Link to the file %s — valid for %s:"
I18N[share_ui_expires]="It stops working in %s — at %s server time."
I18N[share_ui_fingerprint]="Certificate fingerprint — for those who check it: %s"
I18N[share_ui_selfsigned_note]="The browser will warn that the connection is not secure: the link has its own certificate, not the domain's. That is expected — tap «Advanced» → «Proceed»."
I18N[share_ui_port_hint]="Does not open? Many hosters have their own firewall in their panel: open inbound TCP port %s there."
# What the person sees at the link and after it expires (NC-12)
I18N[share_ui_friend_conf]="What the user sees: the browser downloads the file %s right away — open it in the AmneziaWG app (import from a file)."
I18N[share_ui_friend_vpn]="What the user sees: the browser downloads the file %s right away — open it in the AmneziaVPN app."
I18N[share_ui_friend_expired]="Once it expires, the link shows «cannot connect» to the user — if it is needed again, make a new one."
I18N[share_ui_open_hint]="Copy the whole address: without its last part it does not work"
I18N[share_ui_endpoint]="Server address in the file: %s"
I18N[share_ui_list_title]="Active shares"
I18N[share_ui_list_empty]="Nothing is being served right now"
I18N[share_ui_list_row]="%s · %s / %s · %s · %s · downloads: %s"
I18N[share_ui_revoke_all]="Revoke all shares"
I18N[share_ui_pick_legend]="A row number revokes that share; %s — revoke all, 0 — back."
I18N[share_ui_revoke_ask]="Revoke share %s? The link stops opening at once."
