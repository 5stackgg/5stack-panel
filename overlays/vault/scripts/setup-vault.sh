#!/bin/bash

# Check if vault CLI is installed
if ! command -v vault &> /dev/null; then
    echo "Error: vault CLI is not installed"
    exit 1
fi

# Check if vault is logged in
if ! vault status &> /dev/null; then
    echo "Error: Not logged into vault. Please run 'vault login' first"
    exit 1
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

echo "Creating Vault role for Kubernetes authentication..."
vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names=5stack \
    bound_service_account_namespaces=5stack \
    policies=external-secrets \
    ttl=1h

echo "Vault authentication setup completed successfully!"
