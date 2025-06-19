#!/bin/bash

if [ -n "$FIVE_STACK_ENV_SETUP" ]; then
    return;
fi

DEBUG=false
FIVE_STACK_ENV_SETUP=true
REVERSE_PROXY=""

# Load environment variables from .5stack-env.config if it exists
if [ -f .5stack-env.config ]; then
    source .5stack-env.config
fi

if [ -z "$KUBECONFIG" ]; then
    KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
fi

if ! [ -f ./kustomize ] || ! [ -x ./kustomize ]
then
    echo "kustomize not found. Installing..."
    curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
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
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ "$DEBUG" = true ]; then
    echo "Debug mode enabled (KUBECONFIG: $KUBECONFIG, REVERSE_PROXY: $REVERSE_PROXY)"
fi

ask_reverse_proxy() {
    while true; do
        read -p "Are you using a reverse proxy? (http://docs.5stack.gg/install/reverse-proxy) (y/n): " use_reverse_proxy
        if [ "$use_reverse_proxy" = "y" ] || [ "$use_reverse_proxy" = "n" ]; then
            break
        fi
        echo "Please enter 'y' or 'n'"
    done

    if [ "$use_reverse_proxy" = "y" ]; then
        REVERSE_PROXY=true
    else
        REVERSE_PROXY=false
    fi
}

update_env_var() {
    local file=$1
    local key=$2
    local value=$3
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|^$key=.*|$key=$value|" "$file"
    else
        sed -i "s|^$key=.*|$key=$value|" "$file"
    fi
}

output_redirect() {
    if [ "$DEBUG" = true ]; then
        "$@"
    else
        "$@" >/dev/null
    fi
}

migrate_secrets_to_vault() {
    local secret_file=$1
    local vault_path=$2
    
    if [ ! -f "$secret_file" ]; then
        echo "Warning: $secret_file not found, skipping..."
        return
    fi
    
    # Create backup if it doesn't exist
    if [ ! -f "${secret_file}.backup" ]; then
        cp "$secret_file" "${secret_file}.backup"
    fi
    
    # Replace the original file with VAULT placeholder
    echo "# Secrets migrated to Vault at path: $vault_path" > "$secret_file"
    echo "# Original file backed up as: ${secret_file}.backup" >> "$secret_file"
    echo "# Use ExternalSecret to retrieve from Vault" >> "$secret_file"
    
    while IFS='=' read -r key value || [ -n "$key" ]; do
        # Skip comments and empty lines
        if [[ $key =~ ^[[:space:]]*# ]] || [[ -z "$key" ]]; then
            continue
        fi
        
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        
        if [ "$value" = "VAULT" ]; then
            echo "$key=VAULT" >> "$secret_file"
            continue
        fi
        
        # Update Vault and add to .env file
        if [ -n "$key" ] && [ -n "$value" ]; then
            local json_data=$(jq -n --arg k "$key" --arg v "$value" '{($k): $v}')
            echo "$json_data" | vault kv patch "$vault_path" -
            
            if [ $? -eq 0 ]; then
                echo "  ✓ Migrated $key to Vault"
                echo "$key=VAULT" >> "$secret_file"
            else
                echo "  ✗ Failed to migrate $key to Vault"
                echo "$key=$value" >> "$secret_file"
            fi
        fi
    done < "${secret_file}.backup"
}


if [ -z "$REVERSE_PROXY" ]; then
    ask_reverse_proxy   
fi

if [ ! -f .5stack-env.config ]; then
    echo "Saving environment variables to .5stack-env.config";

    # Save environment variables to .5stack-env.config
    cat > .5stack-env.config << EOF
REVERSE_PROXY=$REVERSE_PROXY
KUBECONFIG=$KUBECONFIG
EOF
fi

for file in base/secrets/*.env.example; do
    env_file="${file%.example}"
    if [ ! -f "$env_file" ]; then
        cp "$file" "$env_file"
    fi
done

for file in base/properties/*.env.example; do
    env_file="${file%.example}"
    if [ ! -f "$env_file" ]; then
        cp "$file" "$env_file"
    fi
done

# Replace $(RAND32) with a random base64 encoded string in all non-example env files
for env_file in base/secrets/*.env; do
    if [[ -f "$env_file" && ! "$env_file" == *.example ]]; then

        # Generate a random base64 encoded string
        random_string=$(openssl rand -base64 32 | tr '/' '_' | tr '=' '_')
        
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s/\$(RAND32)/$random_string/g" "$env_file"
        else
            sed -i "s/\$(RAND32)/$random_string/g" "$env_file"
        fi
    fi
done

POSTGRES_PASSWORD=$(grep "^POSTGRES_PASSWORD=" base/secrets/timescaledb-secrets.env | cut -d '=' -f2-)

if [ "$POSTGRES_PASSWORD" != "VAULT" ]; then
    POSTGRES_CONNECTION_STRING="postgres://hasura:$POSTGRES_PASSWORD@timescaledb:5432/hasura"
    if grep -q "^POSTGRES_CONNECTION_STRING=" base/secrets/timescaledb-secrets.env; then
        update_env_var "base/secrets/timescaledb-secrets.env" "POSTGRES_CONNECTION_STRING" "$POSTGRES_CONNECTION_STRING"
    else
        echo "" >> base/secrets/timescaledb-secrets.env
        echo "POSTGRES_CONNECTION_STRING=$POSTGRES_CONNECTION_STRING" >> base/secrets/timescaledb-secrets.env
    fi
fi

if [ -f "/var/lib/rancher/k3s/server/node-token" ]; then
    K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
fi

if [ -n "$K3S_TOKEN" ]; then
    if grep -q "^K3S_TOKEN=" base/secrets/api-secrets.env; then
        echo "K3S_TOKEN already set"
        update_env_var "base/secrets/api-secrets.env" "K3S_TOKEN" "$K3S_TOKEN"
    else
        echo "K3S_TOKEN not set, setting it"
        echo "K3S_TOKEN=$K3S_TOKEN" >> base/secrets/api-secrets.env
    fi
fi

# Using -h to suppress filename headers in grep output for Linux compatibility
WEB_DOMAIN=$(grep -h "^WEB_DOMAIN=" base/properties/api-config.env | cut -d '=' -f2-)
WS_DOMAIN=$(grep -h "^WS_DOMAIN=" base/properties/api-config.env | cut -d '=' -f2-)
API_DOMAIN=$(grep -h "^API_DOMAIN=" base/properties/api-config.env | cut -d '=' -f2-)
DEMOS_DOMAIN=$(grep -h "^DEMOS_DOMAIN=" base/properties/api-config.env | cut -d '=' -f2-)
MAIL_FROM=$(grep -h "^MAIL_FROM=" base/properties/api-config.env | cut -d '=' -f2-)
S3_CONSOLE_HOST=$(grep -h "^S3_CONSOLE_HOST=" base/properties/s3-config.env | cut -d '=' -f2-)
TYPESENSE_HOST=$(grep -h "^TYPESENSE_HOST=" base/properties/typesense-config.env | cut -d '=' -f2-)

if [ -z "$WEB_DOMAIN" ] || [ -z "$WS_DOMAIN" ] || [ -z "$API_DOMAIN" ] || [ -z "$DEMOS_DOMAIN" ] || [ -z "$MAIL_FROM" ] || [ -z "$S3_CONSOLE_HOST" ] || [ -z "$TYPESENSE_HOST" ]; then
    echo -e "\n\n\n\033[1;36mEnter your base domain (e.g. example.com):\033[0m"

    read BASE_DOMAIN
    while [ -z "$BASE_DOMAIN" ]; do
        echo "Base domain cannot be empty. Please enter your base domain (e.g. example.com):"
        read BASE_DOMAIN
    done
    
    if [ -z "$WEB_DOMAIN" ]; then
        WEB_DOMAIN=$BASE_DOMAIN
        update_env_var "base/properties/api-config.env" "WEB_DOMAIN" "$WEB_DOMAIN"
    fi

    if [ -z "$WS_DOMAIN" ]; then
        WS_DOMAIN="ws.$BASE_DOMAIN"
        update_env_var "base/properties/api-config.env" "WS_DOMAIN" "$WS_DOMAIN"
    fi

    if [ -z "$API_DOMAIN" ]; then
        API_DOMAIN="api.$BASE_DOMAIN"
        update_env_var "base/properties/api-config.env" "API_DOMAIN" "$API_DOMAIN"
    fi

    if [ -z "$DEMOS_DOMAIN" ]; then
        DEMOS_DOMAIN="demos.$BASE_DOMAIN"
        update_env_var "base/properties/api-config.env" "DEMOS_DOMAIN" "$DEMOS_DOMAIN"
    fi

    if [ -z "$MAIL_FROM" ]; then
        MAIL_FROM="hello@$BASE_DOMAIN"
        update_env_var "base/properties/api-config.env" "MAIL_FROM" "$MAIL_FROM"
    fi

    if [ -z "$S3_CONSOLE_HOST" ]; then
        S3_CONSOLE_HOST="console.$BASE_DOMAIN"
        update_env_var "base/properties/s3-config.env" "S3_CONSOLE_HOST" "$S3_CONSOLE_HOST"
    fi

    if [ -z "$TYPESENSE_HOST" ]; then
        TYPESENSE_HOST="search.$BASE_DOMAIN"
        update_env_var "base/properties/typesense-config.env" "TYPESENSE_HOST" "$TYPESENSE_HOST"
    fi
fi

STEAM_WEB_API_KEY=$(grep -h "^STEAM_WEB_API_KEY=" base/secrets/steam-secrets.env | cut -d '=' -f2-)

while [ -z "$STEAM_WEB_API_KEY" ]; do
    echo "Please enter your Steam Web API key (required for Steam authentication). Get one at: https://steamcommunity.com/dev/apikey"
    read STEAM_WEB_API_KEY
done

update_env_var "base/secrets/steam-secrets.env" "STEAM_WEB_API_KEY" "$STEAM_WEB_API_KEY"


if [ "$VAULT_MANAGER" = true ]; then
    if ! command -v vault &> /dev/null; then
        echo "Error: vault CLI is not installed. Please install it first."
        exit 1
    fi
    
    if ! vault status &> /dev/null; then
        echo "Error: Not logged into vault. Please run 'vault login' first"
        exit 1
    fi
    
    migrate_secrets_to_vault "base/secrets/api-secrets.env" "kv/api"
    migrate_secrets_to_vault "base/secrets/steam-secrets.env" "kv/steam"
    migrate_secrets_to_vault "base/secrets/timescaledb-secrets.env" "kv/timescaledb"
    migrate_secrets_to_vault "base/secrets/typesense-secrets.env" "kv/typesense"
    migrate_secrets_to_vault "base/secrets/tailscale-secrets.env" "kv/tailscale"
    migrate_secrets_to_vault "base/secrets/s3-secrets.env" "kv/s3"
    migrate_secrets_to_vault "base/secrets/redis-secrets.env" "kv/redis"
    migrate_secrets_to_vault "base/secrets/minio-secrets.env" "kv/minio"
    migrate_secrets_to_vault "base/secrets/hasura-secrets.env" "kv/hasura"
    migrate_secrets_to_vault "base/secrets/faceit-secrets.env" "kv/faceit"
    migrate_secrets_to_vault "base/secrets/discord-secrets.env" "kv/discord"
fi

echo "Domains and Hosts Configuration:"
echo "--------------------------------"
echo "WEB_DOMAIN: $WEB_DOMAIN"
echo "WS_DOMAIN: $WS_DOMAIN" 
echo "API_DOMAIN: $API_DOMAIN"
echo "DEMOS_DOMAIN: $DEMOS_DOMAIN"
echo "MAIL_FROM: $MAIL_FROM"
echo "S3_CONSOLE_HOST: $S3_CONSOLE_HOST"
echo "TYPESENSE_HOST: $TYPESENSE_HOST"
echo "--------------------------------"


