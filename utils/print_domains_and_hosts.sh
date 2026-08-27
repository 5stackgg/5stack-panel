#!/bin/bash

# Prints the resolved domains and hosts.
#
# Shared by setup-env.sh, which shows it as the install/update summary, and
# debug.sh, which appends it to the debug dump. Colors are resolved per call
# rather than taken from colors.sh once at source time, so the copy debug.sh
# redirects into a file lands there as plain text.
#
# Pass --all to include GAME_STREAM_DOMAIN even when it is still the unset
# placeholder: the install summary hides it until game streaming is actually
# configured, but the debug dump wants it either way.
print_domains_and_hosts() {
    local show_all=false
    [ "$1" = "--all" ] && show_all=true

    local c_step="" c_ok="" c_reset=""
    if [ -t 1 ]; then
        c_step="$C_STEP"
        c_ok="$C_OK"
        c_reset="$C_RESET"
    fi

    echo
    echo "${c_step}==> Domains and Hosts Configuration${c_reset}"
    printf "    %-20s ${c_ok}%s${c_reset}\n" "WEB_DOMAIN:"      "$WEB_DOMAIN"
    printf "    %-20s ${c_ok}%s${c_reset}\n" "WS_DOMAIN:"       "$WS_DOMAIN"
    printf "    %-20s ${c_ok}%s${c_reset}\n" "API_DOMAIN:"      "$API_DOMAIN"
    printf "    %-20s ${c_ok}%s${c_reset}\n" "RELAY_DOMAIN:"    "$RELAY_DOMAIN"
    printf "    %-20s ${c_ok}%s${c_reset}\n" "DEMOS_DOMAIN:"    "$DEMOS_DOMAIN"
    printf "    %-20s ${c_ok}%s${c_reset}\n" "MAIL_FROM:"       "$MAIL_FROM"
    printf "    %-20s ${c_ok}%s${c_reset}\n" "S3_CONSOLE_HOST:" "$S3_CONSOLE_HOST"
    printf "    %-20s ${c_ok}%s${c_reset}\n" "TYPESENSE_HOST:"  "$TYPESENSE_HOST"
    if [ "$show_all" = true ] || { [ -n "$GAME_STREAM_DOMAIN" ] && [ "$GAME_STREAM_DOMAIN" != "hls.example.com" ]; }; then
        printf "    %-20s ${c_ok}%s${c_reset}\n" "GAME_STREAM_DOMAIN:" "$GAME_STREAM_DOMAIN"
    fi
}
