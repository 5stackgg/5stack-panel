#!/bin/bash

setup_k3s_token() {
    local secrets_file=${1:-"overlays/local-secrets/api-secrets.env"}
    
    if [ ! -f "$secrets_file" ]; then
        echo "Warning: Secrets file $secrets_file not found, skipping K3S_TOKEN setup..."
        return
    fi
    
    K3S_TOKEN=$(grep -h "^K3S_TOKEN=" "$secrets_file" | cut -d '=' -f2-)
    
    # If not found in file, try to read from k3s server node-token file
    if [ -z "$K3S_TOKEN" ] && [ -f "/var/lib/rancher/k3s/server/node-token" ]; then
        K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
    fi
    
    # If still not found, prompt the user
    while [ -z "$K3S_TOKEN" ]; do
        echo "Please enter your K3S token (required for Kubernetes node connection)."
        echo "You can find it at: /var/lib/rancher/k3s/server/node-token"
        read K3S_TOKEN
    done
    
    # Update or add the token to the file
    if grep -q "^K3S_TOKEN=" "$secrets_file"; then
        update_env_var "$secrets_file" "K3S_TOKEN" "$K3S_TOKEN"
    else
        echo "K3S_TOKEN=$K3S_TOKEN" >> "$secrets_file"
    fi
}

