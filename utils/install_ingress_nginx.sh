#!/bin/bash

install_ingress_nginx() {
    local quiet=${1:-false}
    
    echo "Installing Ingress Nginx..."
    
    if [ "$quiet" = true ] && type output_redirect &> /dev/null; then
        output_redirect kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.2/deploy/static/provider/baremetal/deploy.yaml
    else
        kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.2/deploy/static/provider/baremetal/deploy.yaml
    fi
    
    echo "Waiting for Ingress Nginx to be ready..."
    while true; do
        PODS=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        if [[ -n "$PODS" ]]; then
            if kubectl wait --namespace ingress-nginx \
                --for=condition=Ready pod \
                --selector=app.kubernetes.io/component=controller \
                --timeout=60s 2>/dev/null; then
                echo "Ingress Nginx is ready!"
                break
            fi
        fi
        sleep 5
    done
}

