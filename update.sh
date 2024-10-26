#!/bin/bash

source setup-env.sh "$@"

if [ "$REVERSE_PROXY" = true ]; then
    ./kustomize build base | kubectl --kubeconfig=$KUBECONFIG apply -f -
else 
    kubectl --kubeconfig=$KUBECONFIG apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.1/cert-manager.yaml
    ./kustomize build overlays/cert-manager | kubectl --kubeconfig=$KUBECONFIG apply -f -
fi

echo "5stack Updated"