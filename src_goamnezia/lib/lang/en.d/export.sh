#!/bin/bash
# goAmnezia pro — EN dictionary, module lib/export.sh
# shellcheck disable=SC2034,SC2148

I18N[export_err_peer]="User %s has no key on profile %s"
I18N[export_err_no_privkey]="The key of %s on profile %s was issued in the Amnezia app and is stored only there — it cannot be shown or sent from here. It keeps working for the user. Attach the old key (the vpn:// link or .conf you once sent them) or reissue it — then the old one stops connecting."
I18N[export_err_profile]="Profile %s is incomplete (missing server key, port or address)"
I18N[export_err_conf]="Failed to build the .conf for %s (%s)"
I18N[export_err_vpn]="Failed to build the vpn:// key for %s (%s)"
I18N[export_err_qrencode]="qrencode is missing — install the qrencode package to get QR codes"
I18N[export_err_qr]="Failed to create the QR code: %s"
I18N[export_err_outdir]="Invalid directory for QR files: %s"
I18N[export_err_chunks]="Failed to split the vpn:// key into QR chunks"
I18N[export_err_format]="Unknown key format: %s (conf, vpn, qr-conf, qr-vpn, all)"
I18N[export_vpn_description]="%s · AmneziaWG %s"
I18N[export_warn_dns]="DNS %s from config.json is not a valid IPv4 — it will not go into the key"
I18N[export_err_endpoint]="The server address is unknown — a key with such an address will never connect. Set endpoint_host or server_ip in config.json"
# A key for a disabled user is issued, but never silently (see GA_EXPORT_DISABLED).
I18N[export_warn_disabled]="%s is currently disabled — the %s profile key has been issued, but it cannot connect until the user is enabled (user card → Enable)"
I18N[export_err_address_gone]="Address %s set for user %s is no longer on the server — the key would not connect. Give the user another address or return the common one."
I18N[export_vpn_description_at]="%s · AmneziaWG %s · %s"
I18N[export_err_key_host_invalid]="Address «%s» cannot go into a key: use an IPv4 of this server or its domain."
I18N[export_err_key_host_not_here]="This server has no address %s — a key with it would not connect. Available: %s."
I18N[export_err_key_host_unknown]="The server cannot see its external addresses (it looks to be behind NAT), so address %s cannot be checked. Available: %s."
