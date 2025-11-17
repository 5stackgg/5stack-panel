#!/bin/bash

if [ ! -f "setup-env.sh" ]; then
    echo "Error: setup-env.sh not found. Please run this script from the root directory of the project."
    exit 1
fi

source overlays/vault/scripts/setup-vault.sh "$@"

source setup-env.sh "$@"

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