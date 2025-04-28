#!/bin/bash

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

# Function to handle output redirection based on DEBUG
output_redirect() {
    if [ "$DEBUG" = true ]; then
        "$@"
    else
        "$@" >/dev/null 2>&1
    fi
}

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

DEBUG=false
REVERSE_PROXY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --kubeconfig)
            KUBECONFIG="$2"
            shift 2
            ;;
        --reverse-proxy)
            REVERSE_PROXY=true
            shift
            ;;
        --debug)
            DEBUG=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ -z "$KUBECONFIG" ]; then
    KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
fi

if ! [ -f ./kustomize ] || ! [ -x ./kustomize ]
then
    echo "kustomize not found. Installing..."
    curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
fi

echo "using kubeconfig: $KUBECONFIG"

POSTGRES_PASSWORD=$(grep "^POSTGRES_PASSWORD=" base/secrets/timescaledb-secrets.env | cut -d '=' -f2-)
POSTGRES_CONNECTION_STRING="postgres://hasura:$POSTGRES_PASSWORD@timescaledb:5432/hasura"

if [ -n "$POSTGRES_CONNECTION_STRING" ]; then
    if grep -q "^POSTGRES_CONNECTION_STRING=" base/secrets/timescaledb-secrets.env; then
        update_env_var "base/secrets/timescaledb-secrets.env" "POSTGRES_CONNECTION_STRING" "$POSTGRES_CONNECTION_STRING"
    else
        echo "" >> base/secrets/timescaledb-secrets.env
        echo "POSTGRES_CONNECTION_STRING=$POSTGRES_CONNECTION_STRING" >> base/secrets/timescaledb-secrets.env
    fi
fi

K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)

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
