#!/bin/bash

PANEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# every path below is relative to the repo root
cd "$PANEL_DIR" || exit 1

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

source "$PANEL_DIR/utils/utils.sh" "$@"

host=$(kubectl --kubeconfig=$KUBECONFIG config view --minify -o jsonpath='{.clusters[0].cluster.server}')
certificate=$(kubectl --kubeconfig=$KUBECONFIG config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 --decode)

echo "Checking Kubernetes auth method..."
if ! vault auth list | grep -q "^kubernetes/"; then
    echo "Enabling Kubernetes auth method..."
    vault auth enable kubernetes
else
    echo "Kubernetes auth method already enabled"
fi

echo "Configuring Kubernetes auth method..."
# token_reviewer_jwt is deliberately left empty so Vault reviews the caller's
# own service account token instead of a stored one. `kubectl create token`
# issues a 1h token, so storing it here meant Kubernetes auth broke an hour
# after every install or update -- every login 403ing while Vault itself was
# perfectly healthy. The 5stack service account is bound to
# system:auth-delegator (see rbac/cluster-role.yaml), which is what makes
# reviewing the caller's token possible, and nothing about it expires.
vault write auth/kubernetes/config \
    token_reviewer_jwt="" \
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
path "kv/data/api" {
  capabilities = ["read", "list"]
}
path "kv/data/steam" {
  capabilities = ["read", "list"]
}
path "kv/data/timescaledb" {
  capabilities = ["read", "list"]
}
path "kv/data/typesense" {
  capabilities = ["read", "list"]
}
path "kv/data/tailscale" {
  capabilities = ["read", "list"]
}
path "kv/data/s3" {
  capabilities = ["read", "list"]
}
path "kv/data/redis" {
  capabilities = ["read", "list"]
}
path "kv/data/minio" {
  capabilities = ["read", "list"]
}
path "kv/data/hasura" {
  capabilities = ["read", "list"]
}
path "kv/data/faceit" {
  capabilities = ["read", "list"]
}
path "kv/data/discord" {
  capabilities = ["read", "list"]
}
path "kv/metadata/*" {
  capabilities = ["read", "list"]
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
