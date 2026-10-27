#!/bin/bash

setup_postgres_connection_string() {
    local secrets_file=$1
    
    if [ ! -f "$secrets_file" ]; then
        echo "Warning: Secrets file $secrets_file not found, skipping POSTGRES_CONNECTION_STRING setup..."
        return
    fi
    
    POSTGRES_PASSWORD=$(grep "^POSTGRES_PASSWORD=" "$secrets_file" | cut -d '=' -f2-)
    
    if [ "$POSTGRES_PASSWORD" != "VAULT" ] && [ -n "$POSTGRES_PASSWORD" ]; then
        # Hasura's connection: it prepares its statements, and a generic plan
        # gets each planned once per connection instead of on every
        # subscription poll (half of Postgres's CPU in the api's load lab).
        POSTGRES_CONNECTION_STRING="postgres://hasura:$POSTGRES_PASSWORD@timescaledb:5432/hasura?options=-c%20plan_cache_mode%3Dforce_generic_plan"
        if grep -q "^POSTGRES_CONNECTION_STRING=" "$secrets_file"; then
            update_env_var "$secrets_file" "POSTGRES_CONNECTION_STRING" "$POSTGRES_CONNECTION_STRING"
        else
            echo "" >> "$secrets_file"
            echo "POSTGRES_CONNECTION_STRING=$POSTGRES_CONNECTION_STRING" >> "$secrets_file"
        fi
    fi
}

# A Vault install keeps the string in Vault, put there before Hasura asked for
# generic plans, so the option is added there. Hasura reads it only when it
# starts: update.sh restarts it once the secrets have synced.
ensure_vault_postgres_connection_options() {
    local current separator="?"
    current=$(vault kv get -field=POSTGRES_CONNECTION_STRING kv/timescaledb 2>/dev/null) || return 0
    case "$current" in
        "" | *plan_cache_mode*) return 0 ;;
        *options=*)
            echo "Warning: POSTGRES_CONNECTION_STRING in Vault already sets options; add -c plan_cache_mode=force_generic_plan to them for Hasura's generic plans" >&2
            return 0
            ;;
        *\?*) separator="&" ;;
    esac
    jq -n --arg v "${current}${separator}options=-c%20plan_cache_mode%3Dforce_generic_plan" '{POSTGRES_CONNECTION_STRING: $v}' |
        vault kv patch kv/timescaledb - >/dev/null || return 1
    echo "  ✓ Hasura's connection string in Vault asks for generic plans"
    RESTART_HASURA_AFTER_SECRETS=true
}
