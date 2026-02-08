#!/bin/bash

migrate_to_traefik() {
    echo "Starting migration from nginx-ingress to Traefik..."

    # Check if already migrated
    if [ -f .5stack-env.config ]; then
        source .5stack-env.config
        if [ "$INGRESS_CONTROLLER" = "traefik" ]; then
            echo "Already using Traefik. Skipping migration."
            return 0
        fi
    fi

    # Step 1: Detect Tailscale configuration
    TAILSCALE_AUTH_KEY=""
    if [ -f "overlays/local-secrets/tailscale-secrets.env" ]; then
        echo "Detected Tailscale configuration"
        source overlays/local-secrets/tailscale-secrets.env
        TAILSCALE_AUTH_KEY="$TAILSCALE_SECRET_ID"
    fi

    # Step 2: Upgrade K3s to enable Traefik
    echo "Step 1/6: Upgrading K3s to enable Traefik..."
    if [ -n "$TAILSCALE_AUTH_KEY" ]; then
        echo "  Upgrading K3s with Tailscale VPN integration..."
        curl -sfL https://get.k3s.io | sh -s - --vpn-auth="name=tailscale,joinKey=${TAILSCALE_AUTH_KEY}"
    else
        echo "  Upgrading K3s (standard installation)..."
        curl -sfL https://get.k3s.io | sh -s -
    fi

    # Step 3: Wait for Traefik to be ready
    echo "Step 2/6: Waiting for Traefik to be ready..."
    kubectl wait --namespace kube-system \
        --for=condition=Ready pod \
        --selector=app.kubernetes.io/name=traefik \
        --timeout=180s

    if [ $? -ne 0 ]; then
        echo "Error: Traefik failed to become ready"
        return 1
    fi

    echo "  Traefik is ready!"

    # Step 4: Apply Traefik middlewares
    echo "Step 3/6: Applying Traefik middlewares..."
    kubectl apply -f base/traefik/middlewares.yaml

    # Step 5: Delete old nginx ingress resources
    echo "Step 4/6: Removing old nginx ingress resources..."
    kubectl delete ingress --all -n 5stack 2>/dev/null || true
    kubectl delete ingress --all -n ingress-nginx 2>/dev/null || true

    # Step 6: Uninstall nginx-ingress controller
    echo "Step 5/6: Uninstalling nginx-ingress controller..."
    kubectl delete namespace ingress-nginx --timeout=60s 2>/dev/null || true

    # Step 7: Update .5stack-env.config
    echo "Step 6/6: Updating configuration marker..."
    if [ -f .5stack-env.config ]; then
        if grep -q "^INGRESS_CONTROLLER=" .5stack-env.config; then
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' "s|^INGRESS_CONTROLLER=.*|INGRESS_CONTROLLER=traefik|" .5stack-env.config
            else
                sed -i "s|^INGRESS_CONTROLLER=.*|INGRESS_CONTROLLER=traefik|" .5stack-env.config
            fi
        else
            echo "INGRESS_CONTROLLER=traefik" >> .5stack-env.config
        fi
    else
        echo "INGRESS_CONTROLLER=traefik" >> .5stack-env.config
    fi

    echo ""
    echo "=========================================="
    echo "Migration to Traefik completed successfully!"
    echo "=========================================="
    echo ""
    echo "Next steps:"
    echo "1. Run './update.sh' to apply new IngressRoute configuration"
    echo "2. Run './utils/verify_traefik.sh' to verify migration"
    echo "3. Test all endpoints to ensure proper routing"
}

# If script is run directly (not sourced), execute the function
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    migrate_to_traefik
fi
