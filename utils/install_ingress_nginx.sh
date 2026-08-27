#!/bin/bash

INGRESS_NGINX_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.2/deploy/static/provider/baremetal/deploy.yaml"

# Exit codes are load bearing: install.sh treats a failed install (1) as fatal
# and a webhook that is merely slow (2) as a warning, because the first means
# there is no ingress layer at all and the second usually resolves during the
# apply that follows.
install_ingress_nginx() {
    local quiet=${1:-false}
    local timeout="${2:-600}"
    local deadline=$((SECONDS + timeout))
    # Was bare `kubectl` here and `--kubeconfig` in the webhook wait, two calls
    # in the same function reaching the cluster by different routes. Same array
    # pattern as apply_overlay; empty when KUBECONFIG is unset.
    local -a kc=()
    [ -n "$KUBECONFIG" ] && kc=(--kubeconfig="$KUBECONFIG")

    echo "Installing Ingress Nginx..."

    # The status of this apply used to be discarded by output_redirect, so a
    # missing cluster or a GitHub outage fell straight through to the wait loop
    # below -- which then polled forever for pods that were never created.
    if [ "$quiet" = true ] && type output_redirect &> /dev/null; then
        if ! output_redirect kubectl "${kc[@]}" apply -f "$INGRESS_NGINX_MANIFEST"; then
            echo "Failed to apply the Ingress Nginx manifest from $INGRESS_NGINX_MANIFEST" >&2
            return 1
        fi
    else
        if ! kubectl "${kc[@]}" apply -f "$INGRESS_NGINX_MANIFEST"; then
            echo "Failed to apply the Ingress Nginx manifest from $INGRESS_NGINX_MANIFEST" >&2
            return 1
        fi
    fi

    echo "Waiting for Ingress Nginx to be ready..."
    while true; do
        PODS=$(kubectl "${kc[@]}" get pods -n ingress-nginx -l app.kubernetes.io/component=controller -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        if [[ -n "$PODS" ]]; then
            if kubectl "${kc[@]}" wait --namespace ingress-nginx \
                --for=condition=Ready pod \
                --selector=app.kubernetes.io/component=controller \
                --timeout=60s 2>/dev/null; then
                echo "Ingress Nginx is ready!"
                break
            fi
        fi

        # Bounded, unlike the original. An unbounded wait here meant install.sh
        # hung silently instead of ever reaching the error handling below it.
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "Ingress Nginx controller did not become ready after ${timeout}s:" >&2
            kubectl "${kc[@]}" get pods -n ingress-nginx >&2
            return 1
        fi

        sleep 5
    done

    wait_for_ingress_admission || return 2
}

# A Ready controller is not the same thing as a usable cluster. ingress-nginx
# installs a ValidatingWebhookConfiguration with failurePolicy: Fail, and its
# caBundle is filled in by a separate `ingress-nginx-admission-patch` Job that
# can still be running once the controller reports Ready. In that window every
# Ingress creation is rejected -- "x509: certificate signed by unknown
# authority" -- which silently drops the entire ingress layer out of an apply
# that otherwise looks like it worked.
wait_for_ingress_admission() {
    local timeout="${1:-180}"
    local probe

    probe="$(cat <<'YAML'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ingress-nginx-admission-probe
  namespace: default
spec:
  ingressClassName: nginx
  rules:
    - host: admission-probe.5stack.invalid
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: admission-probe
                port:
                  number: 80
YAML
)"

    wait_for_webhook "Ingress Nginx admission webhook" "$probe" "$timeout"
}
