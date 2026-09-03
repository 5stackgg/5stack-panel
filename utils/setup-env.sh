#!/bin/bash

if [ -n "$FIVE_STACK_ENV_SETUP" ]; then
    return;
fi

source "$(dirname "${BASH_SOURCE[0]}")/colors.sh"

DEBUG=false
FIVE_STACK_ENV_SETUP=true
REVERSE_PROXY=""
CLOUDFLARE=""

CLOUDFLARE_DOCS="https://docs.5stack.gg/install/cloudflare/"

# Every path below -- and in update.sh, custom.sh and the kustomize overlays --
# is relative to the checkout, so anchor the cwd there once. Running
# `/opt/5stack/5stack-panel/install.sh` from anywhere else used to render an
# empty overlay into `kubectl apply`, which then reported nothing to do.
#
# The emptiness check is not redundant: `cd ""` is a silent no-op that returns
# 0, so an unset PANEL_DIR would sail past `cd ... || exit 1` and leave the cwd
# wherever it was -- reintroducing the exact failure this exists to prevent.
# PANEL_DIR is set by utils/utils.sh; running this file on its own has none.
if [ -z "$PANEL_DIR" ]; then
    echo "Error: PANEL_DIR is not set. Source utils/utils.sh rather than this file directly." >&2
    exit 1
fi
cd "$PANEL_DIR" || exit 1

# Load environment variables from .5stack-env.config if it exists
if [ -f .5stack-env.config ]; then
    source .5stack-env.config
fi

if [ -z "$KUBECONFIG" ]; then
    KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
fi
# Exported so the calls that don't pass --kubeconfig explicitly (install.sh,
# install_ingress_nginx) talk to the same cluster as the ones that do.
export KUBECONFIG

setup_kustomize

if ! command -v curl &> /dev/null; then
    echo "Error: curl is not installed. Please install it first."
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --kubeconfig)
            KUBECONFIG="$2"
            shift 2
            ;;
        --debug)
            DEBUG=true
            shift
            ;;
        --reverse-proxy=*)
            REVERSE_PROXY="${1#*=}"
            if [ "$REVERSE_PROXY" = "0" ] || [ "$REVERSE_PROXY" = "n" ]; then
                REVERSE_PROXY=false
            else
                REVERSE_PROXY=true
            fi
            shift
            ;;
        --cloudflare=*)
            CLOUDFLARE="${1#*=}"
            if [ "$CLOUDFLARE" = "0" ] || [ "$CLOUDFLARE" = "n" ]; then
                CLOUDFLARE=false
            else
                CLOUDFLARE=true
            fi
            shift
            ;;
        *)
            shift
            ;;
    esac
done

if [ "$DEBUG" = true ]; then
    echo "Debug mode enabled (KUBECONFIG: $KUBECONFIG, REVERSE_PROXY: $REVERSE_PROXY, CLOUDFLARE: $CLOUDFLARE)"
fi

ask_yes_no() {
    local prompt="$1" answer
    while true; do
        read -p "$prompt (y/n): " answer
        if [ "$answer" = "y" ] || [ "$answer" = "n" ]; then
            break
        fi
        echo "Please enter 'y' or 'n'"
    done
    [ "$answer" = "y" ]
}

ask_cloudflare() {
    if ask_yes_no "Is your domain's DNS managed by Cloudflare?"; then
        CLOUDFLARE=true
    else
        CLOUDFLARE=false
        return
    fi

    step "Cloudflare Setup"
    warn "Cloudflare needs a few 5Stack specific settings — SSL/TLS mode, an ACME"
    warn "challenge rule, and tunnel routes. Follow the guide before continuing:"
    open_docs "$CLOUDFLARE_DOCS" "Cloudflare"
    echo
}

ask_reverse_proxy() {
    if [ "$CLOUDFLARE" = true ]; then
        if ask_yes_no "Are you using the Cloudflare proxy (orange cloud) or a Cloudflare Tunnel?"; then
            REVERSE_PROXY=true
        else
            REVERSE_PROXY=false
        fi
        return
    fi

    if ask_yes_no "Are you using a reverse proxy? (https://docs.5stack.gg/install/reverse-proxy)"; then
        REVERSE_PROXY=true
    else
        REVERSE_PROXY=false
    fi
}


migrate_secrets_to_vault() {
    local secret_file=$1
    local vault_path=$2
    
    if [ ! -f "$secret_file" ]; then
        echo "Warning: $secret_file not found, skipping..."
        return
    fi
    
    # Check if the secret already exists in Vault
    local secret_exists=false
    if vault kv get "$vault_path" &>/dev/null; then
        secret_exists=true
    fi

    if [ "$secret_exists" = false ]; then
        echo '{}' | vault kv put "$vault_path" -
    fi
    
    # Read current file and migrate non-VAULT values
    while IFS='=' read -r key value || [ -n "$key" ]; do
        # Skip comments and empty lines
        if [[ $key =~ ^[[:space:]]*# ]] || [[ -z "$key" ]]; then
            continue
        fi
        
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        
        # Skip if already VAULT or empty
        if [ "$value" = "VAULT" ] || [ -z "$key" ] || [ -z "$value" ]; then
            continue
        fi

        echo "Migrating $key to Vault"
        
        # Upload to Vault
        local json_data=$(jq -n --arg k "$key" --arg v "$value" '{($k): $v}')
        echo "$json_data" | vault kv patch "$vault_path" -

        if [ $? -eq 0 ]; then
            echo "  ✓ Migrated $key to Vault"
            # Append to backup after successful upload
            echo "$key=$value" >> "${secret_file}.backup"
            # Update current file to VAULT
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' "s|^$key=.*|$key=VAULT|" "$secret_file"
            else
                sed -i "s|^$key=.*|$key=VAULT|" "$secret_file"
            fi
        else
            echo "  ✗ Failed to migrate $key to Vault"
        fi
    done < "$secret_file"
}

if [ -z "$REVERSE_PROXY" ]; then
    if [ -z "$CLOUDFLARE" ]; then
        ask_cloudflare
    fi
    ask_reverse_proxy
fi

if [ ! -f .5stack-env.config ]; then
    echo "Saving environment variables to .5stack-env.config";

    # Save environment variables to .5stack-env.config
    cat > .5stack-env.config << EOF
REVERSE_PROXY=$REVERSE_PROXY
CLOUDFLARE=$CLOUDFLARE
KUBECONFIG=$KUBECONFIG
EOF
fi

if [ -d "base/secrets" ]; then
    echo "base/secrets directory found, moving to overlays/local-secrets"
    mv base/secrets/* overlays/local-secrets
    rm -rf base/secrets
fi

if [ -d "overlays/secrets" ]; then
    mv overlays/secrets/* overlays/local-secrets
    rm -rf overlays/secrets
fi

if [ -d "base/properties" ]; then
    echo "base/properties directory found, moving to overlays/config"
    mv base/properties/* overlays/config
    rm -rf base/properties
fi

copy_config_or_secrets "overlays/local-secrets" "overlays/local-secrets"
copy_config_or_secrets "overlays/config" "overlays/config"
copy_config_or_secrets "overlays/mediamtx" "overlays/mediamtx"
copy_config_or_secrets "overlays/coturn" "overlays/coturn"

# Replace $(RAND32) with a random base64 encoded string in all non-example env files
replace_rand32_in_env_files "overlays/local-secrets"

# Web Push (VAPID) keys. Added here rather than via the .env.example because
# copy_config_or_secrets only creates env files that don't already exist, so an
# existing install would never pick a new key up. Only fills in what's missing,
# so an update never rotates a working keypair out from under its subscribers.
ensure_vapid_keys_in_env_file "overlays/local-secrets/push-secrets.env"

# Same reasoning as the VAPID keys above: an existing install never picks up a
# newly added key, and coturn refuses to start without this one.
ensure_turn_secret_in_env_file "overlays/local-secrets/coturn-secrets.env"

# Setup POSTGRES_CONNECTION_STRING based on POSTGRES_PASSWORD
setup_postgres_connection_string "overlays/local-secrets/timescaledb-secrets.env"

if [ -f "/var/lib/rancher/k3s/server/node-token" ]; then
    K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
fi

if [ -n "$K3S_TOKEN" ]; then
    if grep -q "^K3S_TOKEN=" overlays/local-secrets/api-secrets.env; then
        echo "K3S_TOKEN already set"
        update_env_var "overlays/local-secrets/api-secrets.env" "K3S_TOKEN" "$K3S_TOKEN"
    else
        echo "K3S_TOKEN not set, setting it"
        echo "K3S_TOKEN=$K3S_TOKEN" >> overlays/local-secrets/api-secrets.env
    fi
fi

load_domains_and_hosts

if [ -z "$WEB_DOMAIN" ] || [ -z "$WS_DOMAIN" ] || [ -z "$API_DOMAIN" ] || [ -z "$RELAY_DOMAIN" ] || [ -z "$DEMOS_DOMAIN" ] || [ -z "$GAME_STREAM_DOMAIN" ] || [ -z "$MAIL_FROM" ] || [ -z "$S3_CONSOLE_HOST" ] || [ -z "$TYPESENSE_HOST" ]; then
    if [ -z "$WEB_DOMAIN" ]; then
        echo "Base domain cannot be empty. Please enter your base domain (e.g. example.com):"
        read WEB_DOMAIN
    fi

    if [ -z "$WEB_DOMAIN" ] || echo "$WEB_DOMAIN" | grep -q ' '; then
        echo "ERROR: Invalid domain '$WEB_DOMAIN'. Domain must be non-empty and contain no spaces."
        exit 1
    fi
    
    echo "WEB_DOMAIN: $WEB_DOMAIN"
    update_env_var "overlays/config/api-config.env" "WEB_DOMAIN" "$WEB_DOMAIN"

    if [ -z "$WS_DOMAIN" ]; then
        WS_DOMAIN="ws.$WEB_DOMAIN"
        update_env_var "overlays/config/api-config.env" "WS_DOMAIN" "$WS_DOMAIN"
    fi

    if [ -z "$API_DOMAIN" ]; then
        API_DOMAIN="api.$WEB_DOMAIN"
        update_env_var "overlays/config/api-config.env" "API_DOMAIN" "$API_DOMAIN"
    fi

    if [ -z "$RELAY_DOMAIN" ]; then
        RELAY_DOMAIN="tv.$WEB_DOMAIN"
        update_env_var "overlays/config/api-config.env" "RELAY_DOMAIN" "$RELAY_DOMAIN"
    fi

    if [ -z "$DEMOS_DOMAIN" ]; then
        DEMOS_DOMAIN="demos.$WEB_DOMAIN"
        update_env_var "overlays/config/api-config.env" "DEMOS_DOMAIN" "$DEMOS_DOMAIN"
    fi

    if [ -z "$GAME_STREAM_DOMAIN" ]; then
        GAME_STREAM_DOMAIN="hls.$WEB_DOMAIN"
        update_env_var "overlays/config/api-config.env" "GAME_STREAM_DOMAIN" "$GAME_STREAM_DOMAIN"
    fi

    if [ -z "$MAIL_FROM" ]; then
        MAIL_FROM="hello@$WEB_DOMAIN"
        update_env_var "overlays/config/api-config.env" "MAIL_FROM" "$MAIL_FROM"
    fi

    if [ -z "$ACME_EMAIL" ]; then
        ACME_EMAIL="$MAIL_FROM"
        update_env_var "overlays/config/api-config.env" "ACME_EMAIL" "$ACME_EMAIL"
    fi

    if [ -z "$S3_CONSOLE_HOST" ]; then
        S3_CONSOLE_HOST="console.$WEB_DOMAIN"
        update_env_var "overlays/config/s3-config.env" "S3_CONSOLE_HOST" "$S3_CONSOLE_HOST"
    fi

    if [ -z "$TYPESENSE_HOST" ]; then
        TYPESENSE_HOST="search.$WEB_DOMAIN"
        update_env_var "overlays/config/typesense-config.env" "TYPESENSE_HOST" "$TYPESENSE_HOST"
    fi
fi

# mirror api-config -> mediamtx.env (kustomize replacement source)
if [ -n "$GAME_STREAM_DOMAIN" ] && [ -f overlays/mediamtx/mediamtx.env ]; then
    update_env_var "overlays/mediamtx/mediamtx.env" "GAME_STREAM_DOMAIN" "$GAME_STREAM_DOMAIN"
fi

setup_steam_web_api_key "overlays/local-secrets/steam-secrets.env"

if [ "$VAULT_MANAGER" = true ]; then
    if ! command -v vault &> /dev/null; then
        echo "Error: vault CLI is not installed. Please install it first (https://developer.hashicorp.com/vault/install)."
        exit 1
    fi
    
    if ! vault status &> /dev/null; then
        echo "Error: Not logged into vault. Please run 'vault login' first"
        exit 1
    fi
    
    migrate_secrets_to_vault "overlays/local-secrets/api-secrets.env" "kv/api"
    migrate_secrets_to_vault "overlays/local-secrets/push-secrets.env" "kv/push"
    migrate_secrets_to_vault "overlays/local-secrets/steam-secrets.env" "kv/steam"
    migrate_secrets_to_vault "overlays/local-secrets/timescaledb-secrets.env" "kv/timescaledb"
    migrate_secrets_to_vault "overlays/local-secrets/typesense-secrets.env" "kv/typesense"
    migrate_secrets_to_vault "overlays/local-secrets/tailscale-secrets.env" "kv/tailscale"
    migrate_secrets_to_vault "overlays/local-secrets/s3-secrets.env" "kv/s3"
    migrate_secrets_to_vault "overlays/local-secrets/redis-secrets.env" "kv/redis"
    migrate_secrets_to_vault "overlays/local-secrets/rustfs-secrets.env" "kv/rustfs"
    migrate_secrets_to_vault "overlays/local-secrets/hasura-secrets.env" "kv/hasura"
    migrate_secrets_to_vault "overlays/local-secrets/faceit-secrets.env" "kv/faceit"
    migrate_secrets_to_vault "overlays/local-secrets/discord-secrets.env" "kv/discord"
    migrate_secrets_to_vault "overlays/local-secrets/coturn-secrets.env" "kv/coturn"
fi

print_domains_and_hosts


