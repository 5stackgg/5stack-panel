#!/bin/bash

# open_docs URL [LABEL] — print a docs link and, when we're on a desktop
# session, try to open it in a browser. Best effort, never fails the install.
open_docs() {
    local url="$1"
    local label="${2:-Docs}"

    echo "${C_STEP}    $label: $url${C_RESET}"

    # Most installs are on headless servers, where there is nothing to open with.
    if [ "$(uname)" != "Darwin" ] && [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ]; then
        return 0
    fi

    local opener=""
    if command -v xdg-open &> /dev/null; then
        opener="xdg-open"
    elif command -v open &> /dev/null; then
        opener="open"
    else
        return 0
    fi

    # install.sh runs under sudo, so open the browser as the desktop user.
    if [ -n "$SUDO_USER" ] && command -v sudo &> /dev/null; then
        sudo -u "$SUDO_USER" "$opener" "$url" &> /dev/null &
    else
        "$opener" "$url" &> /dev/null &
    fi
}
