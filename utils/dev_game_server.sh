#!/bin/bash

# CS2 ships no arm64 server, so on a machine whose Docker runs arm64 (Apple
# Silicon) the dev cluster plays its matches on the simulated game server.
# --simulator or --cs2 (or DEV_GAME_SERVER) chooses either way.
dev_game_server() {
    local choice="${DEV_GAME_SERVER:-}" arg arch

    for arg in "$@"; do
        case "$arg" in
            --simulator) choice=simulator ;;
            --cs2) choice=cs2 ;;
        esac
    done

    if [ -z "$choice" ]; then
        arch="$(docker info --format '{{.Architecture}}' 2>/dev/null)" || arch=""
        [ -n "$arch" ] || arch="$(uname -m)"

        case "$arch" in
            arm64|aarch64) choice=simulator ;;
            *) choice=cs2 ;;
        esac
    fi

    echo "$choice"
}
