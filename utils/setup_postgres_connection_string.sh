#!/bin/bash

# Utility function to setup POSTGRES_CONNECTION_STRING based on POSTGRES_PASSWORD
# Note: This function depends on update_env_var, so source it first if using independently

setup_postgres_connection_string() {
    local secrets_file=$1
    
    if [ ! -f "$secrets_file" ]; then
        echo "Warning: Secrets file $secrets_file not found, skipping POSTGRES_CONNECTION_STRING setup..."
        return
    fi
    
    POSTGRES_PASSWORD=$(grep "^POSTGRES_PASSWORD=" "$secrets_file" | cut -d '=' -f2-)
    
    if [ "$POSTGRES_PASSWORD" != "VAULT" ] && [ -n "$POSTGRES_PASSWORD" ]; then
        POSTGRES_CONNECTION_STRING="postgres://hasura:$POSTGRES_PASSWORD@timescaledb:5432/hasura"
        if grep -q "^POSTGRES_CONNECTION_STRING=" "$secrets_file"; then
            update_env_var "$secrets_file" "POSTGRES_CONNECTION_STRING" "$POSTGRES_CONNECTION_STRING"
        else
            echo "" >> "$secrets_file"
            echo "POSTGRES_CONNECTION_STRING=$POSTGRES_CONNECTION_STRING" >> "$secrets_file"
        fi
    fi
}

