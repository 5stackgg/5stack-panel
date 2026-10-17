#!/bin/bash

# The api scopes its session cookie to AUTH_COOKIE_DOMAIN, `.$WEB_DOMAIN` when
# unset. Login hosts named beside the panel rather than under it
# (api-panel.example.com next to panel.example.com) never receive the cookie,
# so every login looks like it failed.
#
# Only a broken login is fixed automatically: the web host (Steam's callback
# sets the cookie there) or the api or ws host outside the cookie domain.
# Widening the cookie leaves the old, narrower one shadowing it for anyone
# already signed in, which is only worth it when login does not work anyway. A
# demos or hls host outside it is warned about instead. The relay is left out:
# only game clients fetch it, never with the session.
ensure_auth_cookie_domain_in_env_file() {
    local env_file=$1
    local web current shared host
    web=$(cookie_host "$WEB_DOMAIN")
    current=$(grep -h "^AUTH_COOKIE_DOMAIN=" "$env_file" 2>/dev/null | tail -n 1 | cut -d '=' -f2-)
    shared=$(cookie_host "${current:-$web}")

    if ! cookie_domain_covers "$shared" "$web" "$API_DOMAIN" "$WS_DOMAIN"; then
        shared=$web
        for host in "$API_DOMAIN" "$WS_DOMAIN"; do
            host=$(cookie_host "$host")
            while [ -n "$shared" ] && ! cookie_domain_covers "$shared" "$host"; do
                if [[ "$shared" == *.* ]]; then
                    shared=${shared#*.}
                else
                    shared=""
                fi
            done

            if [[ "$shared" != *.* ]]; then
                warn "$host shares no parent domain with $web, so logins cannot reach it."
                warn "Name it under the same domain as $web."
                return
            fi
        done

        update_env_var "$env_file" "AUTH_COOKIE_DOMAIN" ".$shared"
        echo "AUTH_COOKIE_DOMAIN set to .$shared${current:+ (was $current)}, so every *.$shared host now"
        echo "receives the session cookie. Anyone already signed in should clear cookies for $web."
    fi

    for host in "$DEMOS_DOMAIN" "$GAME_STREAM_DOMAIN"; do
        if ! cookie_domain_covers "$shared" "$host"; then
            warn "$host is not under .$shared, so it will not receive the session cookie."
            warn "See https://docs.5stack.gg/install/cookie-domain"
        fi
    done
}

# kustomize reads env files line by line and drops a trailing \r.
cookie_host() {
    local host=${1%$'\r'}
    host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
    host=${host#.}
    printf '%s' "${host%.}"
}

cookie_domain_covers() {
    local domain=$1 host
    shift
    for host in "$@"; do
        host=$(cookie_host "$host")
        if [ -n "$host" ] && [ "$host" != "$domain" ] && [[ "$host" != *".$domain" ]]; then
            return 1
        fi
    done
}
