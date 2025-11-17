#!/bin/bash

if [ -z "$VAULT_ADDR" ]; then
    echo "ERROR: VAULT_ADDR is not set. Please login to Vault with 'vault login'"
    exit 1
fi

echo "Vault Address: $VAULT_ADDR"

# Check if vault CLI is installed
if ! command -v vault &> /dev/null; then
    echo "Error: vault CLI is not installed. Please install it first (https://developer.hashicorp.com/vault/install)."
    exit 1
fi

# Check if vault is logged in
if ! vault token lookup &> /dev/null; then
    echo "Error: Not logged into vault. Please run 'vault login' first."
    exit 1
fi

EXTERNAL_SECRETS_CONFIG_FILE="overlays/vault/config/external-secrets-config.env"

if [ -f "$EXTERNAL_SECRETS_CONFIG_FILE" ]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|^EXTERNAL_SECRETS_URL=.*|EXTERNAL_SECRETS_URL=$VAULT_ADDR|" "$EXTERNAL_SECRETS_CONFIG_FILE"
    else
        sed -i "s|^EXTERNAL_SECRETS_URL=.*|EXTERNAL_SECRETS_URL=$VAULT_ADDR|" "$EXTERNAL_SECRETS_CONFIG_FILE"
    fi
else
    mkdir -p "$(dirname "$EXTERNAL_SECRETS_CONFIG_FILE")"
    echo "EXTERNAL_SECRETS_URL=$VAULT_ADDR" > "$EXTERNAL_SECRETS_CONFIG_FILE"
fi

if [ ! -f "setup-env.sh" ]; then
    echo "Error: setup-env.sh not found. Please run this script from the root directory of the project."
    exit 1
fi

source setup-env.sh "$@"

host=$(kubectl --kubeconfig=$KUBECONFIG config view --minify -o jsonpath='{.clusters[0].cluster.server}')
certificate=$(kubectl --kubeconfig=$KUBECONFIG config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 --decode)

echo "Getting service account token for external-secrets..."
SA_TOKEN=$(kubectl --kubeconfig=$KUBECONFIG create token 5stack -n 5stack)

echo "Checking Kubernetes auth method..."
if ! vault auth list | grep -q "^kubernetes/"; then
    echo "Enabling Kubernetes auth method..."
    vault auth enable kubernetes
else
    echo "Kubernetes auth method already enabled"
fi

echo "Configuring Kubernetes auth method..."
vault write auth/kubernetes/config \
    token_reviewer_jwt="$SA_TOKEN" \
    kubernetes_host="$host" \
    kubernetes_ca_cert="$certificate" \
    issuer="https://kubernetes.default.svc.cluster.local"

echo "Checking KV secrets engine..."
if ! vault secrets list | grep -q "^kv/"; then
    echo "Enabling KV secrets engine..."
    vault secrets enable -version=2 kv
else
    echo "KV secrets engine already enabled"
fi

echo "Creating Vault policy for external-secrets..."
cat <<EOF | vault policy write external-secrets -
path "*" {
  capabilities = ["read", "list", "create", "update", "delete"]
}
EOF

echo "Checking Vault role for Kubernetes authentication..."
if vault read auth/kubernetes/role/external-secrets &> /dev/null; then
    echo "Role external-secrets already exists, updating with audience parameter..."
    vault write auth/kubernetes/role/external-secrets \
        bound_service_account_names=5stack \
        bound_service_account_namespaces=5stack \
        policies=external-secrets \
        ttl=1h \
        audience="https://kubernetes.default.svc.cluster.local"
else
    echo "Creating Vault role for Kubernetes authentication..."
    vault write auth/kubernetes/role/external-secrets \
        bound_service_account_names=5stack \
        bound_service_account_namespaces=5stack \
        policies=external-secrets \
        ttl=1h \
        audience="https://kubernetes.default.svc.cluster.local"
fi

echo "Vault authentication setup completed successfully!"
