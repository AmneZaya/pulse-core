#!/bin/bash
# goAmnezia pro — EN dictionary, module lib/preflight.sh (pre-flight check of
# ports 80/443 before choosing a mode, PLAN §4.3.1).
# Port labels ("TCP/443") and hint commands are built by the code — they are the
# same in both languages; only the human phrases around them live here.
# Strings used with tf contain only %s — printf would trip otherwise.
# shellcheck disable=SC2034,SC2148
declare -gA I18N

# ── mode selection screen ──
I18N[preflight_title]="Installation mode"
I18N[preflight_mode_lazy]="Lazy Pro"
I18N[preflight_desc_lazy]="Just a domain, I do the rest: certificate, site, AmneziaWG 2.0 on UDP 443 and 3.1, the panel and 5 keys with connection pages."
I18N[preflight_lazy_installed]="goAmnezia is already here: Lazy Pro adds what is missing and leaves users alone."
I18N[preflight_lazy_udp443_busy]="UDP 443 taken — it becomes Semi-Pro."
I18N[preflight_mode_lite]="Lite"
I18N[preflight_mode_lite_site]="Semi-Pro"
I18N[preflight_mode_pro]="Pro"
I18N[preflight_desc_lite]="VPN only: AmneziaWG on ports of its own, no domain and no site, 80 and 443 closed from outside."
I18N[preflight_desc_lite_site]="VPN and site: a domain, a cover site and the panel on 443/tcp with a real certificate; the VPN on ports of its own."
I18N[preflight_desc_pro]="Site and VPN on 443: the site on TCP 443, AmneziaWG on UDP 443 — from outside it is an ordinary site. You choose which line sits on 443."
I18N[preflight_available]="available"
I18N[preflight_unavailable]="unavailable"
# Port verdict on the right of a mode: it used to say "available / unavailable",
# which explained neither who it was available to nor what blocked the others.
I18N[preflight_ports_free]="ports are free"
I18N[preflight_ports_ours_one]="port %s is ours, all fine"
I18N[preflight_ports_ours_many]="ports %s are ours, all fine"
I18N[preflight_udp443_ours]="UDP 443 is our line %s, all fine."
I18N[preflight_udp443_ours_other]="UDP 443 is our profile %s, all fine."
I18N[preflight_ports_busy]="port %s is busy"
I18N[preflight_ports_closed]="port %s is closed by the firewall"
I18N[preflight_ports_unknown]="port state unknown"
I18N[preflight_legend_marks]="Marks: ✓ — the mode can be chosen, ✗ — free the named port first."
I18N[preflight_legend_pick]="How to pick: 1 — you have a domain and want everything done for you; 2 and 3 — you have a domain, and they differ only in where the VPN sits; 4 — no domain."
I18N[preflight_prompt]="Re-check — %s, pick an available mode by its number, leave — 0."
I18N[preflight_prompt_brief]="Re-check the ports — %s."
I18N[preflight_rechecking]="Re-checking ports…"
I18N[preflight_mode_blocked]="Mode \"%s\" is not available right now: %s"
I18N[preflight_mode_blocked_hint]="Free the port and pick the mode again — the port check re-runs by itself."

# ── reasons and warnings ──
I18N[preflight_reason_busy]="%s is busy: %s"
I18N[preflight_reason_closed]="%s is closed by the local firewall (%s)"
I18N[preflight_warn_udp443]="UDP/443 is busy: %s — the profiles get ports of their own, and the Pro mode (the VPN on UDP/443) is unavailable while the port is busy"
I18N[preflight_warn_unknown]="%s: could not check (%s) — assuming free, verify manually"
I18N[preflight_warn_fw_unknown]="%s: local firewall state undetermined (%s) — if the site does not open, check it manually"
I18N[preflight_note_no_ss]="no ss command — install iproute2"
I18N[preflight_who_pid]="PID %s"
I18N[preflight_who_unit]="unit %s"
I18N[preflight_who_container]="container %s"
I18N[preflight_who_unknown]="process not visible — run the check as root"
I18N[preflight_looks_like]="looks like %s"
I18N[preflight_hint_free]="Free the port (for example: %s) or use a clean server."
I18N[preflight_hint_free_generic]="Free the port or use a clean server."
I18N[preflight_hint_closed]="The port is closed locally: the wizard will offer to open it (%s)."
I18N[preflight_ask_open]="Open %s in the local firewall (%s)?"

# ── firewall information sources ──
I18N[preflight_fw_src_ufw]="ufw is active, no rule for the port"
I18N[preflight_fw_src_iptables]="iptables rule in the INPUT chain"
I18N[preflight_fw_src_nft]="nftables rule in the input chain"
I18N[preflight_fw_src_none]="no firewall detected"

# ── products of the series (human names) ──
I18N[preflight_product_gotelegram]="goTelegram Pro"
I18N[preflight_product_govless]="goVLESS Pro"
I18N[preflight_product_godns]="goDNS"
I18N[preflight_product_gowarp]="goWARP PRO"
I18N[preflight_product_gokaskad]="goKaskad PRO"
I18N[preflight_product_xui]="the 3x-ui panel"
I18N[preflight_product_amnezia]="the Amnezia app (container not in our config.json)"
I18N[preflight_product_goamnezia]="goAmnezia pro (our own installation)"

# ── opening a port in the local firewall ──
I18N[preflight_open_ufw]="Opening %s/%s in ufw…"
I18N[preflight_open_iptables]="ufw is not active — adding an iptables rule for %s/%s…"
I18N[preflight_open_done]="Port %s/%s is open in the local firewall (%s). Check the hosting firewall (security group, provider panel) separately"
I18N[preflight_open_failed]="Failed to open %s/%s: the command \"%s\" exited with an error"
I18N[preflight_open_no_tool]="Neither ufw nor iptables found — open port %s/%s manually (nftables: an accept rule in the input chain)"
I18N[preflight_open_nft]="Port %s/%s is closed by an nftables table of its own — an iptables rule would not open it, so I leave it alone. Open it in that table, for example: %s (table and chain names as in your nft list ruleset) and save it to /etc/nftables.conf"
I18N[preflight_open_persist_warn]="The iptables rule was not persisted (no netfilter-persistent) — the port will close again after a reboot"

# ── call errors ──
I18N[preflight_err_args]="preflight: expected protocol tcp|udp and port 1–65535, got: %s %s"
I18N[preflight_err_no_jq]="preflight: jq is missing — cannot build the check JSON without it"
I18N[preflight_err_json]="preflight: screen not rendered — the input is not preflight_modes JSON"
# The «if you are not sure» line: without it the choice between the second and
# the third mode is guesswork — they differ only in where the VPN lives.
I18N[preflight_legend_unsure]="Not sure and no domain of your own — press Enter (Lite). Have a domain — take Lazy Pro: you enter only the domain, the script does the rest."
I18N[preflight_again_item]="Re-check the ports"
