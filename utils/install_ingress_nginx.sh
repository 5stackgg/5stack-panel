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

    wait_for_ingress_admission
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
    local deadline=$((SECONDS + timeout))
    local probe output

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

    echo "Waiting for the Ingress Nginx admission webhook..."
    while true; do
        # The question is only whether the webhook answers, so a rejection of
        # the probe itself still counts as ready -- keep waiting only while the
        # error says the endpoint or its CA bundle isn't there yet.
        if output="$(echo "$probe" | kubectl apply --dry-run=server -f - 2>&1)" \
            || ! webhook_unavailable_error "$output"; then
            echo "Ingress Nginx admission webhook is ready!"
            return 0
        fi

        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "Ingress Nginx admission webhook did not become available after ${timeout}s:" >&2
            echo "$output" | sed 's/^/    /' >&2
            return 1
        fi

        sleep 5
    done
}
