#!/bin/bash

setup_kustomize() {
    if ! [ -f "$(dirname "$0")/kustomize" ] || ! [ -x "$(dirname "$0")/kustomize" ]
    then
        echo "kustomize not found. Installing..."
        curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
    fi
}