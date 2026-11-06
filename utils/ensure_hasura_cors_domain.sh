#!/bin/bash

# Hasura's default CORS policy echoes back any Origin with credentials allowed,
# so any site the browser counts as same-site with the panel could read a
# signed-in player's GraphQL data. HASURA_GRAPHQL_CORS_DOMAIN narrows it to the
# origins the panel is served from: the web host, the api host (HUD bundles
# under /huds open their own subscriptions) and whatever EXTRA_CORS_ORIGINS
# names for the api. All three are read from the env file written to, so it
# follows the domains on every run, for the panel's config and dev's alike.
#
# Needs cookie_host from ensure_auth_cookie_domain.sh.
ensure_hasura_cors_domain_in_env_file() {
    local env_file=$1
    local web api extra origin origins

    if [ ! -f "$env_file" ]; then
        return
    fi

    web=$(cookie_host "$(env_file_value "$env_file" WEB_DOMAIN)")
    api=$(cookie_host "$(env_file_value "$env_file" API_DOMAIN)")
    if [ -z "$web" ] || [ -z "$api" ]; then
        return
    fi
    origins="https://$web, https://$api"

    # Browsers send an Origin in lower case and Hasura compares it exactly.
    extra=$(env_file_value "$env_file" EXTRA_CORS_ORIGINS | tr '[:upper:]' '[:lower:]')

    local IFS=','
    for origin in $extra; do
        origin=$(printf '%s' "$origin" | tr -d '[:space:]')
        if [ -n "$origin" ]; then
            origins="$origins, $origin"
        fi
    done

    update_env_var "$env_file" "HASURA_GRAPHQL_CORS_DOMAIN" "$origins"
}

env_file_value() {
    local value
    value=$(grep -h "^$2=" "$1" 2>/dev/null | tail -n 1 | cut -d '=' -f2-)
    printf '%s' "${value%$'\r'}"
}
