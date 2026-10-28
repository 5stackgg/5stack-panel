#!/bin/bash

# Everything that installs Traefik lives here and in charts/, as two releases
# applied by k3s's helm-controller: the CRDs, then Traefik with the shared
# Gateway. Two, because a release whose templates define the Gateway API kinds
# cannot also create a GatewayClass or Gateway: Helm resolves every kind before
# it applies anything. The panel's own Gateway and routes are in the panel
# overlay and only need this to have run first.
install_traefik() {
    local ports_env="${1:-$PANEL_DIR/overlays/config/traefik-config.env}"
    local minor http_port https_port crd
    local -a kc=()
    [ -n "${KUBECONFIG:-}" ] && kc=(--kubeconfig="$KUBECONFIG")

    # Gateway API v1.6's CRDs validate with CEL's isIP(), which the API server
    # only has from Kubernetes 1.31; older servers reject the CRDs outright.
    minor="$(kubectl "${kc[@]}" version -o json 2>/dev/null | sed -n 's/.*"minor": *"\([0-9]*\).*/\1/p' | tail -n 1)"
    if [ -n "$minor" ] && [ "$minor" -lt 31 ]; then
        err "Kubernetes 1.$minor is too old for the Gateway API; upgrade k3s to 1.31 or newer first"
        return 1
    fi

    http_port="$(grep -s '^HTTP_PORT=' "$ports_env" | tail -n 1 | cut -d= -f2- | tr -d '\r" ')"
    https_port="$(grep -s '^HTTPS_PORT=' "$ports_env" | tail -n 1 | cut -d= -f2- | tr -d '\r" ')"
    http_port="${http_port:-80}"
    https_port="${https_port:-443}"
    if ! [[ "$http_port" =~ ^[0-9]+$ && "$https_port" =~ ^[0-9]+$ ]]; then
        err "HTTP_PORT and HTTPS_PORT in $ports_env must be port numbers"
        return 1
    fi

    install_helm_chart gateway-crds "$PANEL_DIR/charts/gateway-crds" "" || return 1

    for crd in gatewayclasses.gateway.networking.k8s.io gateways.gateway.networking.k8s.io \
        httproutes.gateway.networking.k8s.io middlewares.traefik.io; do
        if ! output_redirect kubectl "${kc[@]}" wait --for=condition=Established "crd/$crd" --timeout=120s; then
            err "CRD $crd never became established"
            return 1
        fi
    done

    # The Service is externalTrafficPolicy: Local, so only the node running
    # Traefik answers on these ports -- and DNS points at the server node, not
    # at a game node that joined later.
    install_helm_chart gateway "$PANEL_DIR/charts/gateway" "$(cat <<EOF
traefik:
  ports:
    web:
      exposedPort: $http_port
    websecure:
      exposedPort: $https_port
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
EOF
)" || return 1

    if ! kubectl "${kc[@]}" -n traefik rollout status deployment/traefik --timeout=300s; then
        err "Traefik never became ready"
        kubectl "${kc[@]}" -n traefik get pods >&2
        return 1
    fi
}

# A chart directory as the .tgz Helm expects, byte-identical between runs where
# GNU tar allows it, so an unchanged chart is not reinstalled.
chart_archive() {
    local parent name
    parent="$(dirname "$1")"
    name="$(basename "$1")"
    if tar --version 2>/dev/null | grep -q GNU; then
        tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --exclude='.*' -cf - -C "$parent" "$name" | gzip -n
    else
        tar --exclude='.*' -cf - -C "$parent" "$name" | gzip -n
    fi
}

# Applies a chart from this checkout as a k3s HelmChart (no registry, no helm
# binary) and waits on the helm-install Job that helm-controller runs for it.
# That Job keeps its name across changes; a changed HelmChart gets a new Job,
# so a Job with the old UID is the previous config's and is not waited on.
install_helm_chart() {
    local name="$1" dir="$2" values="$3"
    local manifest old_generation new_generation old_uid uid complete failed deadline
    local -a kc=()
    [ -n "${KUBECONFIG:-}" ] && kc=(--kubeconfig="$KUBECONFIG")

    # A k3s that has just started registers its HelmChart CRD a few seconds in.
    deadline=$((SECONDS + 120))
    until kubectl "${kc[@]}" get crd helmcharts.helm.cattle.io >/dev/null 2>&1; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            err "this cluster has no HelmChart CRD; Traefik is installed through k3s's helm-controller"
            return 1
        fi
        sleep 2
    done

    manifest="$(mktemp)"
    trap 'rm -f "$manifest"' RETURN

    {
        printf 'apiVersion: helm.cattle.io/v1\nkind: HelmChart\nmetadata:\n  name: %s\n  namespace: kube-system\n' "$name"
        printf 'spec:\n  targetNamespace: traefik\n  createNamespace: true\n'
        # abort, not the default reinstall: a failed upgrade must leave the
        # running Traefik alone rather than uninstall it.
        printf '  failurePolicy: abort\n  backOffLimit: 3\n'
        printf '  chartContent: %s\n' "$(chart_archive "$dir" | base64 | tr -d '\n')"
        if [ -n "$values" ]; then
            printf '  valuesContent: |\n'
            printf '%s\n' "$values" | sed 's/^/    /'
        fi
    } >"$manifest"

    old_generation="$(kubectl "${kc[@]}" get helmchart "$name" -n kube-system -o jsonpath='{.metadata.generation}' 2>/dev/null)"
    old_uid="$(kubectl "${kc[@]}" get job "helm-install-$name" -n kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null)"

    # Server-side: chartContent is far past the 256KiB a client-side apply can
    # keep in its last-applied annotation.
    if ! output_redirect kubectl "${kc[@]}" apply --server-side --force-conflicts --field-manager=5stack-panel -f "$manifest"; then
        err "could not apply HelmChart $name (k3s's helm-controller is required)"
        return 1
    fi
    new_generation="$(kubectl "${kc[@]}" get helmchart "$name" -n kube-system -o jsonpath='{.metadata.generation}')"
    if [ "$new_generation" = "$old_generation" ]; then
        old_uid=""
    fi

    echo "Waiting for helm-controller to apply $name..."
    deadline=$((SECONDS + 600))
    while true; do
        IFS=$'\t' read -r uid complete failed < <(kubectl "${kc[@]}" get job "helm-install-$name" -n kube-system \
            -o jsonpath='{.metadata.uid}{"\t"}{.status.conditions[?(@.type=="Complete")].status}{"\t"}{.status.conditions[?(@.type=="Failed")].status}{"\n"}' 2>/dev/null)
        if [ -n "$uid" ] && [ "$uid" != "$old_uid" ]; then
            if [ "$complete" = "True" ]; then
                return 0
            fi
            if [ "$failed" = "True" ]; then
                err "helm-controller could not apply $name:"
                kubectl "${kc[@]}" logs "job/helm-install-$name" -n kube-system --tail=30 >&2
                return 1
            fi
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
            err "helm-controller did not apply $name in time:"
            kubectl "${kc[@]}" logs "job/helm-install-$name" -n kube-system --tail=30 >&2
            return 1
        fi
        sleep 3
    done
}
