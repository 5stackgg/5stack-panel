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
