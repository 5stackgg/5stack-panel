#!/bin/bash

source setup-env.sh "$@"

source setup-env.sh "$@"


echo "5Stack : Updating..."

return;

if [ "$REVERSE_PROXY" = true ]; then
    ./kustomize build base | output_redirect kubectl --kubeconfig=$KUBECONFIG apply -f -
    kubectl --kubeconfig=$KUBECONFIG delete certificate 5stack-ssl -n 5stack 2>/dev/null
else 
    ./kustomize build overlays/cert-manager | output_redirect kubectl --kubeconfig=$KUBECONFIG apply -f -
fi

kubectl --kubeconfig=$KUBECONFIG delete deployment minio -n 5stack 2>/dev/null
kubectl --kubeconfig=$KUBECONFIG delete deployment timescaledb -n 5stack  2>/dev/null
kubectl --kubeconfig=$KUBECONFIG delete deployment typesense -n 5stack  2>/dev/null

echo "5Stack : Updated"
