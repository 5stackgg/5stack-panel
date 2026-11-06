#!/bin/bash

# Hasura's default CORS policy echoes back any Origin with credentials allowed,
# so any site the browser counts as same-site with the panel could read a
# signed-in player's GraphQL data. HASURA_GRAPHQL_CORS_DOMAIN narrows it to the
# origins the panel is served from: the web host, the api host (HUD bundles
# under /huds open their own subscriptions) and whatever EXTRA_CORS_ORIGINS
# names for the api. Derived on every run so it follows the domains.
ensure_hasura_cors_domain_in_env_file() {
    local env_file=$1
    local extra origin origins

    if [ ! -f "$env_file" ]; then
        return
    fi

    origins="https://$(cors_host "$WEB_DOMAIN"), https://$(cors_host "$API_DOMAIN")"

    extra=$(grep -h "^EXTRA_CORS_ORIGINS=" "$env_file" 2>/dev/null | tail -n 1 | cut -d '=' -f2-)
    extra=${extra%$'\r'}

    local IFS=','
    for origin in $extra; do
        origin=$(printf '%s' "$origin" | tr -d '[:space:]')
        if [ -n "$origin" ]; then
            origins="$origins, $origin"
        fi
    done

    update_env_var "$env_file" "HASURA_GRAPHQL_CORS_DOMAIN" "$origins"
}

cors_host() {
    local host=${1%$'\r'}
    host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
    printf '%s' "${host%.}"
}
