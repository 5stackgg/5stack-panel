#!/bin/bash

setup_fixtures() {
    local config_file=${1:-"overlays/dev/config/api-config.env"}

    if [ ! -f "$config_file" ]; then
        echo "Warning: Config file $config_file not found, skipping fixture setup..."
        return
    fi

    LOAD_FIXTURES=$(grep -h "^LOAD_FIXTURES=" "$config_file" 2>/dev/null | cut -d '=' -f2-)

    if [ -n "$LOAD_FIXTURES" ]; then
        return
    fi

    echo ""
    echo "Would you like to load fixture data? (sample players, matches, tournaments)"
    echo "This is useful for testing but can be skipped for a clean database."
    read -p "(y/n): " answer

    if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
        update_env_var "$config_file" "LOAD_FIXTURES" "true"
    else
        update_env_var "$config_file" "LOAD_FIXTURES" "false"
    fi
}
