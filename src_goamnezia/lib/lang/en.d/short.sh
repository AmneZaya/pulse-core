#!/bin/bash
# goAmnezia pro — EN dictionary: subscription short links with 2FA via the Telegram bot (lib/shortlinks.py, short-*
# wrappers in lib/subs.sh, docs/SUBSCRIPTION.md §11)
# shellcheck disable=SC2034,SC2148

declare -gA I18N

# ── Refusals of short-* actions ──────────────────────────────────────────────
I18N[short_err_need_bot]="Short links work only with 2FA via the Telegram bot, and the bot is not set up: it needs a token and at least one administrator. Set up the bot — the Telegram bot item of the main menu"
I18N[short_err_not_found]="%s has no short link for %s yet — show it first"
I18N[short_err_pending]="A confirmation for this short link is already pending in the bot — try again in %s min"
I18N[short_err_limit]="This short link already had 5 requests this hour — try again in %s min"
I18N[short_err_request]="Confirmation request not found: there was none or it was closed more than an hour ago"
I18N[short_err_answer]="The answer does not fit: a number 10–99, deny (Not me) or swap (Replace the link, sign-ins only)"
I18N[short_err_suffix]="The subscription has no such address for a short link: %s"
I18N[short_err_target]="Not clear what to lift: an address (IPv4, IPv6 or a /64 subnet) or a short code is needed"
I18N[short_err_busy]="Short links are busy with another action — repeat in a few seconds"
I18N[short_err_no_line]="%s has no key of line %s on the server — there will be no short link for it"
I18N[short_err_failed]="Short links: the action failed."
