#!/bin/bash

if [ -n "$FIVE_STACK_ENV_SETUP" ]; then
    return;
fi

source "$(dirname "${BASH_SOURCE[0]}")/colors.sh"

DEBUG=false
: "${ASSUME_YES:=false}"
FIVE_STACK_ENV_SETUP=true
REVERSE_PROXY=""
CLOUDFLARE=""
CLOUDFLARE_MANAGED=""

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
# install_traefik) talk to the same cluster as the ones that do.
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
        -y|--yes)
            ASSUME_YES=true
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
        --cloudflare-managed)
            CLOUDFLARE=true
            CLOUDFLARE_MANAGED=true
            REVERSE_PROXY=false
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
    local prompt="$1" default="${2:-}" answer hint="y/n"
    if [ "$default" = y ]; then
        hint="Y/n"
    fi
    while true; do
        read -p "$prompt ($hint): " answer
        if [ -z "$answer" ]; then
            answer="$default"
        fi
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

    if ask_yes_no "Set up DNS, proxy and SSL automatically?"; then
        CLOUDFLARE_MANAGED=true
        REVERSE_PROXY=false
        return
    fi

    step "Cloudflare Setup"
    warn "Cloudflare needs a few 5Stack specific settings. Follow the guide before continuing:"
    open_docs "$CLOUDFLARE_DOCS" "Cloudflare"
    echo
}

cloudflare_token_url() {
    local keys='[{"key":"zone","type":"read"},{"key":"dns","type":"edit"},{"key":"zone_settings","type":"edit"},{"key":"ssl_and_certificates","type":"read"},{"key":"config_settings","type":"edit"},{"key":"cache_settings","type":"edit"},{"key":"workers_routes","type":"edit"},{"key":"workers_scripts","type":"edit"},{"key":"bot_management","type":"read"},{"key":"dynamic_url_redirects","type":"edit"},{"key":"page_rules","type":"read"}]'
    printf 'https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=%s&accountId=*&zoneId=all&name=5Stack%%20panel\n' "$(jq -rn --arg k "$keys" '$k | @uri')"
}

ask_cloudflare_token() {
    local file="overlays/local-secrets/cloudflare-secrets.env" token
    if [ -n "$CLOUDFLARE_API_TOKEN" ] || grep -qs '^CLOUDFLARE_API_TOKEN=..*' "$file"; then
        return
    fi
    if [ "$ASSUME_YES" = true ] || [ ! -t 0 ]; then
        warn "Cloudflare is managed for this panel but it has no API token yet. Run ./cloudflare.sh to add one."
        return
    fi
    step "Cloudflare API token"
    echo "    Make a token on Cloudflare's page; the permissions 5Stack needs are filled in:"
    echo "    $(cloudflare_token_url)"
    read -rs -p "    Paste the token: " token
    echo
    if [ -n "$token" ]; then
        update_env_var "$file" CLOUDFLARE_API_TOKEN "$token"
    fi
}

flat_host() {
    printf '%s-%s.%s' "${WEB_DOMAIN%%.*}" "$1" "${WEB_DOMAIN#*.}"
}

panel_host() {
    if [ "$FLAT_HOSTS" = true ]; then
        flat_host "$1"
    else
        printf '%s.%s' "$1" "$WEB_DOMAIN"
    fi
}

ask_cloudflare_plan() {
    local answer
    while true; do
        read -p "Which Cloudflare plan is ${WEB_DOMAIN#*.} on? Free or Pro or Higher (f/p): " answer
        case "$answer" in
            f) CLOUDFLARE_PLAN=free; return ;;
            p) CLOUDFLARE_PLAN=paid; return ;;
        esac
        echo "Please enter 'f' or 'p'"
    done
}

flat_hosts_alert() {
    local parent="${WEB_DOMAIN#*.}" sub names=""
    for sub in api ws tv demos hls console search; do
        names="${names:+$names, }$(flat_host "$sub")"
    done
    warn "Cloudflare's free plan only covers one level below $parent, so the addresses become $names."
    warn "Other sites on $parent will receive the panel's sign-in cookie."
}

ask_flat_hosts() {
    local parent="${WEB_DOMAIN#*.}" interactive=true
    if [[ "$parent" != *.* ]]; then
        FLAT_HOSTS=false
        return
    fi
    if [ -n "$FLAT_HOSTS" ] || [ -n "$API_DOMAIN$WS_DOMAIN$RELAY_DOMAIN$DEMOS_DOMAIN$GAME_STREAM_DOMAIN$S3_CONSOLE_HOST$TYPESENSE_HOST" ]; then
        return
    fi
    if [ "$ASSUME_YES" = true ] || [ ! -t 0 ]; then
        interactive=false
    fi
    FLAT_HOSTS=true
    if [ "$CLOUDFLARE" = true ] && [ -z "$CLOUDFLARE_PLAN" ] && [ "$interactive" = true ]; then
        ask_cloudflare_plan
    fi
    local question
    question="Keep every address one level deep ($(flat_host api) instead of api.$WEB_DOMAIN)?"
    if [ "$CLOUDFLARE" = true ] && [ "$CLOUDFLARE_PLAN" = free ]; then
        flat_hosts_alert
        question="Keep every address one level deep? Recommended on Cloudflare's free plan; n keeps them under the panel, straight to this server"
    else
        echo "Sign-in then covers all of $parent, so other sites on $parent get the panel's sign-in cookie."
    fi
    if [ "$interactive" = true ] && ! ask_yes_no "$question" y; then
        FLAT_HOSTS=false
    fi
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
    if [ "$CLOUDFLARE_MANAGED" != true ]; then
        ask_reverse_proxy
    fi
fi

if [ "$CLOUDFLARE_MANAGED" = true ]; then
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: managing Cloudflare needs jq. Install it with: apt-get install -y jq"
        exit 1
    fi
    if [ "$REVERSE_PROXY" != true ]; then
        REVERSE_PROXY=false
    fi
    CLOUDFLARE=true
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

if [ "$CLOUDFLARE_MANAGED" = true ] && ! grep -qs '^CLOUDFLARE_MANAGED=true' .5stack-env.config; then
    update_env_var .5stack-env.config CLOUDFLARE_MANAGED true
    update_env_var .5stack-env.config CLOUDFLARE true
    update_env_var .5stack-env.config REVERSE_PROXY "$REVERSE_PROXY"
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

# The ports file was nginx-config.env while ingress-nginx served the panel.
if [ -f overlays/config/nginx-config.env ] && [ ! -f overlays/config/traefik-config.env ]; then
    mv overlays/config/nginx-config.env overlays/config/traefik-config.env
fi

copy_config_or_secrets "overlays/local-secrets" "overlays/local-secrets"
copy_config_or_secrets "overlays/config" "overlays/config"
copy_config_or_secrets "overlays/mediamtx" "overlays/mediamtx"
copy_config_or_secrets "overlays/coturn" "overlays/coturn"

if [ "$CLOUDFLARE_MANAGED" = true ] && [ "$VAULT_MANAGER" != true ]; then
    ask_cloudflare_token
fi

# Replace $(RAND32) with a random base64 encoded string in all non-example env files
replace_rand32_in_env_files "overlays/local-secrets"

# Rokkan, the AI service, keeps its secrets in its own overlay so an install
# without AI_ENABLED never generates them.
if [ "$AI_ENABLED" = true ]; then
    if [ "$VAULT_MANAGER" = true ]; then
        copy_config_or_secrets "overlays/ai" "overlays/ai"
        replace_rand32_in_env_files "overlays/ai"
    else
        warn "AI_ENABLED needs VAULT_MANAGER=true; the AI service will not be deployed."
    fi
fi

# Added here rather than via the .env.example because copy_config_or_secrets
# only creates env files that don't already exist, so an existing install would
# never pick a new key up -- and coturn refuses to start without this one.
#
# Web Push (VAPID) keys are deliberately not generated here: the api generates
# its own pair into `settings` on first boot, and env keys override those, so
# writing a pair on an update would orphan every existing push subscription.
ensure_turn_secret_in_env_file "overlays/local-secrets/coturn-secrets.env"
ensure_mediamtx_secrets_in_env_file "overlays/local-secrets/mediamtx-secrets.env"

# Same reasoning again: these two only matter for a remote bucket, and an
# existing install would never see them turn up in its own s3-config.env.
ensure_s3_config_keys_in_env_file "overlays/config/s3-config.env"

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
    ask_flat_hosts

    if [ -z "$WS_DOMAIN" ]; then
        WS_DOMAIN="$(panel_host ws)"
        update_env_var "overlays/config/api-config.env" "WS_DOMAIN" "$WS_DOMAIN"
    fi

    if [ -z "$API_DOMAIN" ]; then
        API_DOMAIN="$(panel_host api)"
        update_env_var "overlays/config/api-config.env" "API_DOMAIN" "$API_DOMAIN"
    fi

    if [ -z "$RELAY_DOMAIN" ]; then
        RELAY_DOMAIN="$(panel_host tv)"
        update_env_var "overlays/config/api-config.env" "RELAY_DOMAIN" "$RELAY_DOMAIN"
    fi

    if [ -z "$DEMOS_DOMAIN" ]; then
        DEMOS_DOMAIN="$(panel_host demos)"
        update_env_var "overlays/config/api-config.env" "DEMOS_DOMAIN" "$DEMOS_DOMAIN"
    fi

    if [ -z "$GAME_STREAM_DOMAIN" ]; then
        GAME_STREAM_DOMAIN="$(panel_host hls)"
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
        S3_CONSOLE_HOST="$(panel_host console)"
        update_env_var "overlays/config/s3-config.env" "S3_CONSOLE_HOST" "$S3_CONSOLE_HOST"
    fi

    if [ -z "$TYPESENSE_HOST" ]; then
        TYPESENSE_HOST="$(panel_host search)"
        update_env_var "overlays/config/typesense-config.env" "TYPESENSE_HOST" "$TYPESENSE_HOST"
    fi
fi

ensure_auth_cookie_domain_in_env_file "overlays/config/api-config.env"

ensure_hasura_cors_domain_in_env_file "overlays/config/api-config.env"

# mirror api-config -> mediamtx.env (kustomize replacement source)
if [ -n "$GAME_STREAM_DOMAIN" ] && [ -f overlays/mediamtx/mediamtx.env ]; then
    update_env_var "overlays/mediamtx/mediamtx.env" "GAME_STREAM_DOMAIN" "$GAME_STREAM_DOMAIN"
fi

setup_steam_web_api_key "overlays/local-secrets/steam-secrets.env"

# The 5Stack service sets FIVESTACK_RELEASE and handles Vault itself; it asks before writing to it.
if [ "$VAULT_MANAGER" = true ] && [ -z "${FIVESTACK_RELEASE:-}" ]; then
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
    migrate_secrets_to_vault "overlays/local-secrets/mediamtx-secrets.env" "kv/mediamtx"
    if [ "$AI_ENABLED" = true ]; then
        migrate_secrets_to_vault "overlays/ai/ai-secrets.env" "kv/ai"
    fi
fi

print_domains_and_hosts


