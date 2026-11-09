#!/bin/bash

# The passwords of MediaMTX's users (overlays/mediamtx/mediamtx.yml), which the
# api and game streamers sign in with. Generated here, not only from
# mediamtx-secrets.env.example's $(RAND32), because copy_config_or_secrets only
# creates env files that don't exist yet, so an existing install would never
# get them. A password already there is kept: a new one would cut off every
# stream until the api and streamers restart. Hex, like $(RAND32)'s alphabet,
# has no ':' to split the SRT stream id on.
MEDIAMTX_SECRET_KEYS="MEDIAMTX_API_PASSWORD MEDIAMTX_STREAMER_PASSWORD MEDIAMTX_RELAY_PASSWORD MEDIAMTX_VIEWER_PASSWORD"

ensure_mediamtx_secrets_in_env_file() {
    local env_file=$1 key secret tmp_file

    if [ ! -f "$env_file" ]; then
        touch "$env_file" || return
    fi

    for key in $MEDIAMTX_SECRET_KEYS; do
        if grep -q "^$key=." "$env_file"; then
            continue
        fi

        secret=$(openssl rand -hex 16)
        if [ -z "$secret" ]; then
            echo "Warning: unable to generate $key (openssl missing?)" >&2
            return 1
        fi

        tmp_file=$(mktemp)
        grep -v "^$key=" "$env_file" >"$tmp_file"
        mv "$tmp_file" "$env_file"
        if [ -s "$env_file" ] && [ -n "$(tail -c 1 "$env_file")" ]; then
            printf '\n' >>"$env_file"
        fi
        printf '%s=%s\n' "$key" "$secret" >>"$env_file"
        echo "Generated $key"
    done
}
