#!/bin/bash

source setup-env.sh "$@"

echo "Updating 5Stack"

if [ "$REVERSE_PROXY" = true ]; then
    ./kustomize build base | kubectl --kubeconfig=$KUBECONFIG apply -f - $(if [ "$DEBUG" = false ]; then echo ">/dev/null"; fi)
    kubectl --kubeconfig=$KUBECONFIG delete certificate 5stack-ssl -n 5stack 2>/dev/null
else 
    ./kustomize build overlays/cert-manager | output_redirect kubectl --kubeconfig=$KUBECONFIG apply -f -
fi

output_redirect kubectl --kubeconfig=$KUBECONFIG delete deployment minio -n 5stack
output_redirect kubectl --kubeconfig=$KUBECONFIG delete deployment timescaledb -n 5stack
output_redirect kubectl --kubeconfig=$KUBECONFIG delete deployment typesense -n 5stack

echo "5stack Updated"
