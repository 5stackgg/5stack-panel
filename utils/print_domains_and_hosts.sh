#!/bin/bash

# Read the resolved domains and hosts out of the generated env files into the
# variables the rest of the scripts use.
#
# Absolute paths, so this works from any cwd: debug.sh is run from wherever the
# operator happens to be, and it must not cd or otherwise disturb the machine
# it is collecting a report from.
load_domains_and_hosts() {
    local config="$PANEL_DIR/overlays/config"

    # -h suppresses filename headers in grep output for Linux compatibility
    WEB_DOMAIN=$(grep -h "^WEB_DOMAIN=" "$config/api-config.env" 2>/dev/null | cut -d '=' -f2-)
    WS_DOMAIN=$(grep -h "^WS_DOMAIN=" "$config/api-config.env" 2>/dev/null | cut -d '=' -f2-)
    API_DOMAIN=$(grep -h "^API_DOMAIN=" "$config/api-config.env" 2>/dev/null | cut -d '=' -f2-)
    RELAY_DOMAIN=$(grep -h "^RELAY_DOMAIN=" "$config/api-config.env" 2>/dev/null | cut -d '=' -f2-)
    DEMOS_DOMAIN=$(grep -h "^DEMOS_DOMAIN=" "$config/api-config.env" 2>/dev/null | cut -d '=' -f2-)
    MAIL_FROM=$(grep -h "^MAIL_FROM=" "$config/api-config.env" 2>/dev/null | cut -d '=' -f2-)
    GAME_STREAM_DOMAIN=$(grep -h "^GAME_STREAM_DOMAIN=" "$config/api-config.env" 2>/dev/null | cut -d '=' -f2-)
    S3_CONSOLE_HOST=$(grep -h "^S3_CONSOLE_HOST=" "$config/s3-config.env" 2>/dev/null | cut -d '=' -f2-)
    TYPESENSE_HOST=$(grep -h "^TYPESENSE_HOST=" "$config/typesense-config.env" 2>/dev/null | cut -d '=' -f2-)
}

# Prints the resolved domains and hosts.
#
# Shared by setup-env.sh, which shows it as the install/update summary, and
# debug.sh, which appends it to the debug dump. Colors are resolved per call
# rather than taken from colors.sh once at source time, so the copy debug.sh
# redirects into a file lands there as plain text.
print_domains_and_hosts() {
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
    # Always shown when set, which since setup-env.sh defaults it to
    # hls.$WEB_DOMAIN is every configured install. There used to be a check
    # here for the `hls.example.com` placeholder, meant to hide this until game
    # streaming was configured -- but nothing ever assigns that literal to
    # GAME_STREAM_DOMAIN, so the check never fired and the --all flag that
    # existed to override it never had anything to override.
    if [ -n "$GAME_STREAM_DOMAIN" ]; then
        printf "    %-20s ${c_ok}%s${c_reset}\n" "GAME_STREAM_DOMAIN:" "$GAME_STREAM_DOMAIN"
    fi
}
