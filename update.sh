#!/bin/bash

source setup-env.sh "$@"

if [ "$REVERSE_PROXY" = true ]; then
    kubectl --kubeconfig=$KUBECONFIG delete certificate 5stack-ssl -n 5stack 2>/dev/null
fi

if [ "$REVERSE_PROXY" != true ]; then
    # Apply cert-manager CRDs and controller first to avoid race conditions with Certificate/Issuer
    ./kustomize build overlays/cert-manager-crds | output_redirect kubectl --kubeconfig=$KUBECONFIG apply -f -

    output_redirect kubectl --kubeconfig=$KUBECONFIG wait --for=condition=Established crd/certificates.cert-manager.io --timeout=120s 
    output_redirect kubectl --kubeconfig=$KUBECONFIG wait --for=condition=Established crd/issuers.cert-manager.io --timeout=120s
    output_redirect kubectl --kubeconfig=$KUBECONFIG wait --for=condition=Established crd/clusterissuers.cert-manager.io --timeout=120s
fi

HTTP_REPLACEMENTS="$(dirname "$0")/overlays/http/http-replacements.yaml"
HTTPS_REPLACEMENTS="$(dirname "$0")/overlays/http/https-replacements.yaml"

OVERLAY_BASES=("vault" "local-secrets")
for BASE in "${OVERLAY_BASES[@]}"; do
    for PROTOCOL in "http" "https"; do
        OVERLAY="overlays/${BASE}-${PROTOCOL}"
        mkdir -p "$OVERLAY"

        cat > "$OVERLAY/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../$BASE
- ../config
$(if [[ "$PROTOCOL" == "https" ]]; then echo "- ../cert-manager"; fi)
EOF
        if [ "$PROTOCOL" = "https" ]; then
            cp overlays/http/ingress-patch.yaml "$OVERLAY/ingress-patch.yaml"
            cat "$HTTPS_REPLACEMENTS" >> "$OVERLAY/kustomization.yaml"
        else
            cat "$HTTP_REPLACEMENTS" >> "$OVERLAY/kustomization.yaml"
        fi
    done
done

if [ "$VAULT_MANAGER" = true ]; then
    if [ "$REVERSE_PROXY" = true ]; then
        ./kustomize build overlays/vault-http | output_redirect kubectl --kubeconfig=$KUBECONFIG apply -f -
    else
        ./kustomize build overlays/vault-https | output_redirect kubectl --kubeconfig=$KUBECONFIG apply -f -
    fi
else
    if [ "$REVERSE_PROXY" = true ]; then
        ./kustomize build overlays/local-secrets-http | output_redirect kubectl --kubeconfig=$KUBECONFIG apply -f -
    else
        ./kustomize build overlays/local-secrets-https | output_redirect kubectl --kubeconfig=$KUBECONFIG apply -f -
    fi
fi

kubectl --kubeconfig=$KUBECONFIG delete deployment minio -n 5stack 2>/dev/null
kubectl --kubeconfig=$KUBECONFIG delete deployment timescaledb -n 5stack  2>/dev/null
kubectl --kubeconfig=$KUBECONFIG delete deployment typesense -n 5stack  2>/dev/null
kubectl --kubeconfig=$KUBECONFIG delete deployment redis -n 5stack  2>/dev/null

GIT_SHA=$(git rev-parse HEAD)

kubectl --kubeconfig=$KUBECONFIG label node $(kubectl --kubeconfig=$KUBECONFIG get nodes --selector='node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}') 5stack-panel-version=$GIT_SHA --overwrite

if [ "$REVERSE_PROXY" = false ]; then
    watch_ssl_status
fi

echo "5Stack : Updated"
