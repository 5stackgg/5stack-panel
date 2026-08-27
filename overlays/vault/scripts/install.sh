#!/bin/bash

PANEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# every path below is relative to the repo root
cd "$PANEL_DIR" || exit 1

source "$PANEL_DIR/overlays/vault/scripts/setup-vault.sh" "$@"

source "$PANEL_DIR/utils/utils.sh" "$@"

echo "Installing external-secrets..."

if ! command -v helm &> /dev/null; then
    echo "Error: helm CLI is not installed. Please install it first (https://helm.sh/docs/intro/install/)."
    exit 1
fi

helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets \
   external-secrets/external-secrets \
    -n external-secrets \
    --create-namespace \
    --kubeconfig "$KUBECONFIG"

echo -e "\nVAULT_MANAGER=true" >> .5stack-env.config