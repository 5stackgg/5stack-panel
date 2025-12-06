#!/bin/bash

setup_steam_web_api_key() {
    local secrets_file=${1:-"overlays/local-secrets/steam-secrets.env"}
    
    if [ ! -f "$secrets_file" ]; then
        echo "Warning: Secrets file $secrets_file not found, skipping STEAM_WEB_API_KEY setup..."
        return
    fi
    
    STEAM_WEB_API_KEY=$(grep -h "^STEAM_WEB_API_KEY=" "$secrets_file" | cut -d '=' -f2-)
    
    while [ -z "$STEAM_WEB_API_KEY" ]; do
        echo "Please enter your Steam Web API key (required for Steam authentication). Get one at: https://steamcommunity.com/dev/apikey"
        read STEAM_WEB_API_KEY
    done
    
    update_env_var "$secrets_file" "STEAM_WEB_API_KEY" "$STEAM_WEB_API_KEY"
}

