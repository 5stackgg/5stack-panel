#!/bin/bash

source setup-env.sh "$@"

./kustomize build overlays/secrets | kubectl --kubeconfig=$KUBECONFIG apply -f -
./kustomize build overlays/dev | kubectl --kubeconfig=$KUBECONFIG apply -f -
./kustomize build overlays/nvidia | kubectl --kubeconfig=$KUBECONFIG apply -f -