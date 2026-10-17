#!/bin/bash

# The api scopes its session cookie to `.$WEB_DOMAIN` unless AUTH_COOKIE_DOMAIN
# says otherwise. Hosts named beside the panel rather than under it
# (api-panel.example.com next to panel.example.com) never receive that cookie,
# so every login looks like it failed. The relay is left out: only game clients
# fetch it, never with the session.
ensure_auth_cookie_domain_in_env_file() {
    local env_file=$1

    if grep -q "^AUTH_COOKIE_DOMAIN=." "$env_file" 2>/dev/null; then
        return
    fi

    local shared=$WEB_DOMAIN host
    for host in "$API_DOMAIN" "$WS_DOMAIN" "$DEMOS_DOMAIN" "$GAME_STREAM_DOMAIN"; do
        if [ -z "$host" ]; then
            continue
        fi

        while [ -n "$shared" ] && [ "$host" != "$shared" ] && [[ "$host" != *".$shared" ]]; do
            if [[ "$shared" == *.* ]]; then
                shared=${shared#*.}
            else
                shared=""
            fi
        done

        if [[ "$shared" != *.* ]]; then
            warn "$host is not under $WEB_DOMAIN and shares no parent domain with it, so logins"
            warn "will not reach it. Set AUTH_COOKIE_DOMAIN in $env_file by hand."
            return
        fi
    done

    if [ "$shared" = "$WEB_DOMAIN" ]; then
        return
    fi

    update_env_var "$env_file" "AUTH_COOKIE_DOMAIN" ".$shared"
    echo "AUTH_COOKIE_DOMAIN set to .$shared, since the api hosts are not under $WEB_DOMAIN"
}
