#!/bin/bash

# Writes the running panel's settings through its Hasura as admin, the same way
# the web's settings pages do. Needs API_DOMAIN, HASURA_ADMIN_SECRET and
# cf_json (utils/cloudflare_workers.sh).

# panel_graphql QUERY VARIABLES -- runs QUERY against the panel's Hasura.
panel_graphql() {
    local body
    body="$(node -p 'JSON.stringify({ query: process.argv[1], variables: JSON.parse(process.argv[2]) })' "$1" "$2")"
    printf 'header = "x-hasura-admin-secret: %s"\n' "$HASURA_ADMIN_SECRET" \
        | curl -sS -K - --max-time 15 -H "Content-Type: application/json" \
            --data "$body" "https://$API_DOMAIN/v1/graphql"
}

# set_panel_setting NAME VALUE -- fails unless the panel took it.
set_panel_setting() {
    local variables
    variables="$(node -p 'JSON.stringify({ name: process.argv[1], value: process.argv[2] })' "$1" "$2")"
    # shellcheck disable=SC2016 # GraphQL variables, not shell ones
    [ -n "$(panel_graphql \
        'mutation ($name: String!, $value: String!) { insert_settings(objects: [{ name: $name, value: $value }], on_conflict: { constraint: settings_pkey, update_columns: [value] }) { affected_rows } }' \
        "$variables" | cf_json 'j.data?.insert_settings ? "ok" : undefined')" ]
}

# The api copies CLOUDFLARE_WORKER_DOMAIN into this setting when it boots;
# writing it here as well means it applies without an ./update.sh.
set_live_worker_url() {
    set_panel_setting cloudflare_worker_url "$1"
}

# Has the api check the worker's version. Hasura sends it no event for the url
# written back unchanged, which a redeploy usually does, so this is the time.
set_worker_deployed_at() {
    set_panel_setting cloudflare_worker_deployed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# Has the running panel serve files through the worker on WORKER_HOST, asking
# first when it serves them through another, then tells it about the deploy.
# Without API_DOMAIN and HASURA_ADMIN_SECRET it can only save the hostname for
# ./update.sh (offer_update, which reads WORKER_URL).
point_panel_at_worker() {
    local WORKER_URL LIVE_URL CURRENT_URL SWITCH
    WORKER_URL="https://$WORKER_HOST"
    LIVE_URL=""
    if [ -n "$API_DOMAIN" ] && [ -n "$HASURA_ADMIN_SECRET" ]; then
        LIVE_URL="$(panel_graphql 'query { settings_by_pk(name: "cloudflare_worker_url") { value } }' '{}' \
            | cf_json 'j.data ? (j.data.settings_by_pk?.value ?? "") : undefined')"
    fi

    CURRENT_URL="$LIVE_URL"
    if [ -n "$CLOUDFLARE_WORKER_DOMAIN" ]; then
        CURRENT_URL="https://$CLOUDFLARE_WORKER_DOMAIN"
    fi
    SWITCH=y
    if [ -n "$CURRENT_URL" ] && [ "$CURRENT_URL" != "$WORKER_URL" ]; then
        ok "The panel serves files through $CURRENT_URL now."
        read -r -p "    Switch it to $WORKER_URL? [Y/n] " SWITCH
        SWITCH="${SWITCH:-y}"
    fi

    if [[ ! "$SWITCH" =~ ^[Yy] ]]; then
        warn "Left it on $CURRENT_URL. Run this again to switch later."
    else
        if [ "$CLOUDFLARE_WORKER_DOMAIN" != "$WORKER_HOST" ]; then
            update_env_var "$PANEL_DIR/overlays/config/api-config.env" CLOUDFLARE_WORKER_DOMAIN "$WORKER_HOST"
        fi
        ok "CLOUDFLARE_WORKER_DOMAIN=$WORKER_HOST is in overlays/config/api-config.env"

        if [ "$LIVE_URL" = "$WORKER_URL" ]; then
            ok "The panel already serves files through $WORKER_URL"
        elif [ -n "$API_DOMAIN" ] && [ -n "$HASURA_ADMIN_SECRET" ] && set_live_worker_url "$WORKER_URL"; then
            ok "The panel now serves demos, clips and media through $WORKER_URL"
        else
            offer_update
        fi
    fi
    if [ -n "$API_DOMAIN" ] && [ -n "$HASURA_ADMIN_SECRET" ] && ! set_worker_deployed_at; then
        warn "Could not tell the panel about this deploy. It checks the worker again when its API restarts."
    fi
}
