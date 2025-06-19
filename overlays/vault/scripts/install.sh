#!/bin/bash

if [ ! -f "setup-env.sh" ]; then
    echo "Error: setup-env.sh not found. Please run this script from the root directory of the project."
    exit 1
fi

source setup-env.sh "$@"

echo "Installing external-secrets..."

helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets \
   external-secrets/external-secrets \
    -n external-secrets \
    --create-namespace \
    --kubeconfig "$KUBECONFIG"

echo -e "\nVAULT_MANAGER=true" >> .5stack-env.config