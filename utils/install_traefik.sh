#!/bin/bash

# Everything that installs Traefik lives here and in charts/, as two releases
# applied by k3s's helm-controller: the CRDs, then Traefik with the shared
# Gateway. Two, because a release whose templates define the Gateway API kinds
# cannot also create a GatewayClass or Gateway: Helm resolves every kind before
# it applies anything. The panel's own Gateway and routes are in the panel
# overlay and only need this to have run first.
# An install ingress-nginx still serves can be listening on ports its env file
# doesn't say: the Service edited by hand, or the file lost. Those are the ports
# people reach it on, so Traefik takes them over rather than going back to
# 80/443. Ports set in the file win.
carry_over_ingress_nginx_ports() {
    local ports_env="$1" http https live_http live_https
    local -a kc=()
    [ -n "${KUBECONFIG:-}" ] && kc=(--kubeconfig="$KUBECONFIG")

    live_http="$(kubectl "${kc[@]}" -n ingress-nginx get service ingress-nginx-controller \
        -o jsonpath='{.spec.ports[?(@.name=="http")].port}' 2>/dev/null)"
    live_https="$(kubectl "${kc[@]}" -n ingress-nginx get service ingress-nginx-controller \
        -o jsonpath='{.spec.ports[?(@.name=="https")].port}' 2>/dev/null)"
    if ! [[ "$live_http" =~ ^[0-9]+$ && "$live_https" =~ ^[0-9]+$ ]]; then
        return 0
    fi

    http="$(grep -s '^HTTP_PORT=' "$ports_env" | tail -n 1 | cut -d= -f2- | tr -d '\r" ')"
    https="$(grep -s '^HTTPS_PORT=' "$ports_env" | tail -n 1 | cut -d= -f2- | tr -d '\r" ')"
    if [ "${http:-80}" != 80 ] || [ "${https:-443}" != 443 ]; then
        return 0
    fi
    if [ "$live_http" = 80 ] && [ "$live_https" = 443 ]; then
        return 0
    fi

    update_env_var "$ports_env" HTTP_PORT "$live_http"
    update_env_var "$ports_env" HTTPS_PORT "$live_https"
    warn "ingress-nginx was serving on ports $live_http/$live_https, so Traefik keeps them (saved to $ports_env)"
}

install_traefik() {
    local ports_env="${1:-$PANEL_DIR/overlays/config/traefik-config.env}"
    local minor http_port https_port crd binding nginx crds_values left_out held object deadline
    local -a kc=() handed=()
    [ -n "${KUBECONFIG:-}" ] && kc=(--kubeconfig="$KUBECONFIG")

    # Gateway API v1.6's CRDs validate with CEL's isIP(), which the API server
    # only has from Kubernetes 1.31; older servers reject the CRDs outright.
    minor="$(kubectl "${kc[@]}" version -o json 2>/dev/null | sed -n 's/.*"minor": *"\([0-9]*\).*/\1/p' | tail -n 1)"
    if [ -n "$minor" ] && [ "$minor" -lt 31 ]; then
        err "Kubernetes 1.$minor is too old for the Gateway API; upgrade k3s to 1.31 or newer first"
        return 1
    fi

    carry_over_ingress_nginx_ports "$ports_env"

    http_port="$(grep -s '^HTTP_PORT=' "$ports_env" | tail -n 1 | cut -d= -f2- | tr -d '\r" ')"
    https_port="$(grep -s '^HTTPS_PORT=' "$ports_env" | tail -n 1 | cut -d= -f2- | tr -d '\r" ')"
    http_port="${http_port:-80}"
    https_port="${https_port:-443}"
    if ! [[ "$http_port" =~ ^[0-9]+$ && "$https_port" =~ ^[0-9]+$ ]]; then
        err "HTTP_PORT and HTTPS_PORT in $ports_env must be port numbers"
        return 1
    fi

    # Where k3s installs the Gateway API itself, gateway-crds brings only
    # Traefik's CRDs. One that still holds k3s's objects, from before k3s was
    # upgraded to 1.37, hands them over: Helm deletes what a release drops
    # unless the live object is marked keep, which before gateway-crds 0.2.0
    # the safe-upgrades policy and its binding weren't.
    crds_values=""
    left_out=""
    handed=()
    if k3s_installs_gateway_api; then
        crds_values="gatewayApi: false"
        left_out=gateway-api.yaml
        held="$(gateway_api_held_by_gateway_crds)" || {
            err "could not read the cluster's Gateway API CRDs before installing gateway-crds"
            return 1
        }
        while IFS= read -r object; do
            [ -n "$object" ] && handed+=("$object")
        done <<<"$held"
        if [ "${#handed[@]}" -gt 0 ]; then
            output_redirect kubectl "${kc[@]}" annotate --overwrite "${handed[@]}" helm.sh/resource-policy=keep || return 1
        fi
    fi

    adopt_orphaned_chart_objects "$PANEL_DIR/charts/gateway-crds" gateway-crds traefik "$left_out" || return 1
    install_helm_chart gateway-crds "$PANEL_DIR/charts/gateway-crds" "$crds_values" || return 1

    if [ "${#handed[@]}" -gt 0 ]; then
        warn "k3s installs the Gateway API CRDs now; handing ${#handed[@]} of gateway-crds' objects to its gateway-api-crd release"
        output_redirect kubectl "${kc[@]}" annotate --overwrite "${handed[@]}" \
            meta.helm.sh/release-name=gateway-api-crd meta.helm.sh/release-namespace=kube-system || return 1
    fi

    # k3s's gateway-api-crd release can still be on its way, and kubectl wait
    # gives up at once on a CRD that doesn't exist yet.
    deadline=$((SECONDS + 300))
    for crd in gatewayclasses.gateway.networking.k8s.io gateways.gateway.networking.k8s.io \
        httproutes.gateway.networking.k8s.io middlewares.traefik.io; do
        until kubectl "${kc[@]}" get "crd/$crd" >/dev/null 2>&1; do
            if [ "$SECONDS" -ge "$deadline" ]; then
                err "CRD $crd was never created"
                return 1
            fi
            sleep 2
        done
        if ! output_redirect kubectl "${kc[@]}" wait --for=condition=Established "crd/$crd" --timeout=120s; then
            err "CRD $crd never became established"
            return 1
        fi
    done

    # While ingress-nginx's ServiceLB pods hold the ports, Traefik waits behind
    # its own until retire_ingress_nginx hands them over, so a stalled handover
    # can still give them back; move_traefik_to_host_ports finishes the move.
    nginx="$(kubectl "${kc[@]}" -n ingress-nginx get service ingress-nginx-controller --ignore-not-found -o name)" || return 1
    if [ -n "$nginx" ]; then
        binding="  ports:
    web: {exposedPort: $http_port}
    websecure: {exposedPort: $https_port}
  service:
    spec: {type: LoadBalancer, externalTrafficPolicy: Local}"
    else
        binding="  ports:
    web: {exposedPort: $http_port, hostPort: $http_port}
    websecure: {exposedPort: $https_port, hostPort: $https_port}"
    fi

    pull_traefik_image || return 1

    # Only the node running Traefik listens on these ports, and DNS points at
    # the server node, not at a game node that joined later.
    install_helm_chart gateway "$PANEL_DIR/charts/gateway" "$(cat <<EOF
traefik:
$binding
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

# A rollout stops the running pod before its replacement exists, so a new
# image is pulled onto Traefik's node first: a slow or refused pull would
# otherwise leave nothing serving.
pull_traefik_image() {
    local image node
    local -a kc=()
    [ -n "${KUBECONFIG:-}" ] && kc=(--kubeconfig="$KUBECONFIG")

    image="docker.io/traefik@$(sed -n 's/^ *digest: *\(sha256:[0-9a-f]*\).*/\1/p' "$PANEL_DIR/charts/gateway/values.yaml" | head -n 1)"
    if [ "$(kubectl "${kc[@]}" -n traefik get deployment traefik -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)" = "$image" ]; then
        return 0
    fi
    node="$(kubectl "${kc[@]}" -n traefik get pods -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)"
    if [ -z "$node" ]; then
        return 0
    fi

    echo "Pulling $image onto $node..."
    output_redirect kubectl "${kc[@]}" -n traefik delete pod traefik-pull --ignore-not-found --wait=true
    if ! output_redirect kubectl "${kc[@]}" -n traefik run traefik-pull --image="$image" --restart=Never \
        --overrides="{\"spec\":{\"nodeName\":\"$node\",\"tolerations\":[{\"operator\":\"Exists\"}]}}" \
        --command -- traefik version ||
        ! output_redirect kubectl "${kc[@]}" -n traefik wait pod/traefik-pull --timeout=300s \
            --for=jsonpath='{.status.phase}'=Succeeded; then
        err "could not pull $image onto $node; Traefik keeps running its current image"
        output_redirect kubectl "${kc[@]}" -n traefik delete pod traefik-pull --ignore-not-found --wait=false
        return 1
    fi
    output_redirect kubectl "${kc[@]}" -n traefik delete pod traefik-pull --wait=false
}

move_traefik_to_host_ports() {
    local type
    local -a kc=()
    [ -n "${KUBECONFIG:-}" ] && kc=(--kubeconfig="$KUBECONFIG")

    type="$(kubectl "${kc[@]}" -n traefik get service traefik -o jsonpath='{.spec.type}')" || return 1
    if [ "$type" != LoadBalancer ]; then
        return 0
    fi
    install_traefik "$@"
}

# The cluster-scoped objects the given chart templates define, as kind/name.
chart_objects() {
    awk '/^kind: / { kind = $2; next }
        kind && /^  name: / { name = $2; gsub(/"/, "", name); print tolower(kind) "/" name; kind = "" }' "$@"
}

# The cluster's CRDs, admission policies and bindings with Helm's marks, as
# kind/name|release|release namespace.
marked_objects() {
    local listed
    local -a kc=()
    [ -n "${KUBECONFIG:-}" ] && kc=(--kubeconfig="$KUBECONFIG")

    listed="$(kubectl "${kc[@]}" get customresourcedefinitions,validatingadmissionpolicies,validatingadmissionpolicybindings \
        -o jsonpath='{range .items[*]}{.kind}/{.metadata.name}|{.metadata.annotations.meta\.helm\.sh/release-name}|{.metadata.annotations.meta\.helm\.sh/release-namespace}{"\n"}{end}')" || return 1
    awk -F'|' -v OFS='|' 'NF { $1 = tolower($1); print }' <<<"$listed"
}

# From 1.37 k3s installs the Gateway API CRDs and the safe-upgrades policy
# itself, as its gateway-api-crd chart, whatever --disable=traefik says, and
# takes them over from any release that holds them. Turned off with
# --disable=gateway-api-crd, the chart isn't there.
k3s_installs_gateway_api() {
    local -a kc=()
    [ -n "${KUBECONFIG:-}" ] && kc=(--kubeconfig="$KUBECONFIG")

    [ -n "$(kubectl "${kc[@]}" get helmcharts.helm.cattle.io -A --field-selector metadata.name=gateway-api-crd -o name 2>/dev/null)" ]
}

# The Gateway API objects marked as gateway-crds' own, as kind/name.
gateway_api_held_by_gateway_crds() {
    local objects existing object owner owner_namespace

    objects="$(chart_objects "$PANEL_DIR/charts/gateway-crds/templates/gateway-api.yaml")"
    existing="$(marked_objects)" || return 1
    while IFS='|' read -r object owner owner_namespace; do
        if [ "$owner|$owner_namespace" = "gateway-crds|traefik" ] && grep -qxF "$object" <<<"$objects"; then
            echo "$object"
        fi
    done <<<"$existing"
}

helm_release_gone() {
    local charts records
    local -a kc=()
    [ -n "${KUBECONFIG:-}" ] && kc=(--kubeconfig="$KUBECONFIG")

    charts="$(kubectl "${kc[@]}" get helmcharts.helm.cattle.io -A --field-selector "metadata.name=$1" -o name)" || return 1
    records="$(kubectl "${kc[@]}" -n "$2" get secrets -l "owner=helm,name=$1" -o name)" || return 1
    [ -z "$charts$records" ]
}

helm_release_recorded() {
    local records
    local -a kc=()
    [ -n "${KUBECONFIG:-}" ] && kc=(--kubeconfig="$KUBECONFIG")

    records="$(kubectl "${kc[@]}" -n "$2" get secrets -l "owner=helm,name=$1" -o name 2>/dev/null)" && [ -n "$records" ]
}

# k3s's bundled Traefik installs the Gateway API CRDs as its traefik-crd
# release with helm.sh/resource-policy: keep, so turning it off with
# --disable=traefik deletes the release but leaves the CRDs marked as its, and
# Helm won't install over objects another release claims. Ones whose release
# is gone are handed to this one; anything a live release, or no release, owns
# stops the install. Once the release exists, Helm upgrades what it holds
# whatever the marks say, and the Traefik chart's own crds/ strips them from
# the traefik.io CRDs the two charts share, so only objects a removed release
# left are handed over: the Gateway API's, after k3s's gateway-api-crd chart
# that gateway-crds stepped aside for is turned off. A template left out (its
# file name) is one the install won't render.
adopt_orphaned_chart_objects() {
    local chart_dir="$1" release="$2" release_namespace="$3" left_out="${4:-}"
    local objects existing object owner owner_namespace template recorded=false refused=false
    local -a kc=() orphaned=() templates=()
    [ -n "${KUBECONFIG:-}" ] && kc=(--kubeconfig="$KUBECONFIG")

    if helm_release_recorded "$release" "$release_namespace"; then
        recorded=true
    fi

    for template in "$chart_dir"/templates/*.yaml; do
        [ "$(basename "$template")" = "$left_out" ] || templates+=("$template")
    done
    objects="$(chart_objects "${templates[@]}")"
    if ! existing="$(marked_objects)"; then
        err "could not read the cluster's CRDs before installing $release"
        return 1
    fi

    while IFS='|' read -r object owner owner_namespace; do
        [ -n "$object" ] || continue
        grep -qxF "$object" <<<"$objects" || continue
        if [ "$owner" = "$release" ] && [ "$owner_namespace" = "$release_namespace" ]; then
            continue
        fi
        if [ "$recorded" = true ]; then
            if [ -n "$owner" ] && helm_release_gone "$owner" "$owner_namespace"; then
                orphaned+=("$object")
            fi
            continue
        fi
        if [ -z "$owner" ]; then
            err "$object was created outside Helm, so $release can't install it; delete it, or label it app.kubernetes.io/managed-by=Helm and annotate it meta.helm.sh/release-name=$release meta.helm.sh/release-namespace=$release_namespace"
            refused=true
        elif ! helm_release_gone "$owner" "$owner_namespace"; then
            if [ "$owner" = traefik-crd ]; then
                err "k3s's bundled Traefik owns $object; add --disable=traefik to k3s's server flags, restart k3s, and run this again"
            else
                err "$object belongs to the Helm release $owner in $owner_namespace, so $release can't install it; uninstall that release first"
            fi
            refused=true
        else
            orphaned+=("$object")
        fi
    done <<<"$existing"

    if [ "$refused" = true ]; then
        return 1
    fi
    if [ "${#orphaned[@]}" -eq 0 ]; then
        return 0
    fi

    warn "Handing ${#orphaned[@]} objects left by a removed Helm release to $release"
    output_redirect kubectl "${kc[@]}" annotate --overwrite "${orphaned[@]}" \
        "meta.helm.sh/release-name=$release" "meta.helm.sh/release-namespace=$release_namespace" || return 1
    output_redirect kubectl "${kc[@]}" label --overwrite "${orphaned[@]}" app.kubernetes.io/managed-by=Helm
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
        # macOS tar otherwise adds ._ AppleDouble entries, which Helm rejects.
        COPYFILE_DISABLE=1 tar --exclude='.*' -cf - -C "$parent" "$name" | gzip -n
    fi
}

# Applies a chart from this checkout as a k3s HelmChart (no registry, no helm
# binary) and waits on the helm-install Job that helm-controller runs for it.
# That Job keeps its name across changes; a changed HelmChart gets a new Job,
# so a Job with the old UID is the previous config's and is not waited on.
# helm-controller never re-runs a failed Job for a HelmChart that hasn't
# changed, so a re-run of update.sh has to start one. A release that failed under
# failurePolicy abort refuses every new attempt until someone intervenes, and
# without a helm binary the only way out is a reinstall: done on the re-run, not
# the run that failed, so a failed upgrade never takes Traefik down on its own.
# helm-controller turns a release left pending (other than an upgrade, which it
# retries) into a failed one before it gives up on it.
retry_helm_chart() {
    local name="$1" status
    local -a kc=()
    [ -n "${KUBECONFIG:-}" ] && kc=(--kubeconfig="$KUBECONFIG")

    status="$(kubectl "${kc[@]}" -n traefik get secrets -l "owner=helm,name=$name" \
        -o jsonpath='{range .items[*]}{.metadata.labels.version}{" "}{.metadata.labels.status}{"\n"}{end}' 2>/dev/null |
        sort -n | tail -n 1 | cut -d' ' -f2)"
    if [[ "$status" =~ ^(failed|pending-install|pending-rollback|uninstalling)$ ]]; then
        warn "The last $name release failed; reinstalling it, so the panel is offline for a few seconds"
        output_redirect kubectl "${kc[@]}" patch helmchart "$name" -n kube-system --type merge \
            -p '{"spec":{"failurePolicy":"reinstall"}}' || return 1
    else
        output_redirect kubectl "${kc[@]}" delete job "helm-install-$name" -n kube-system || return 1
    fi
}

install_helm_chart() {
    local name="$1" dir="$2" values="$3"
    local manifest old_generation new_generation old_uid uid complete failed deadline last_failed logs helm_error=""
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
    last_failed="$(kubectl "${kc[@]}" get job "helm-install-$name" -n kube-system \
        -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null)"

    # Server-side: chartContent is far past the 256KiB a client-side apply can
    # keep in its last-applied annotation.
    if ! output_redirect kubectl "${kc[@]}" apply --server-side --force-conflicts --field-manager=5stack-panel -f "$manifest"; then
        err "could not apply HelmChart $name (k3s's helm-controller is required)"
        return 1
    fi
    new_generation="$(kubectl "${kc[@]}" get helmchart "$name" -n kube-system -o jsonpath='{.metadata.generation}')"
    if [ "$new_generation" = "$old_generation" ]; then
        if [ "$last_failed" = "True" ]; then
            retry_helm_chart "$name" || return 1
        else
            old_uid=""
        fi
    fi

    echo "Waiting for helm-controller to apply $name..."
    deadline=$((SECONDS + 600))
    while true; do
        IFS='|' read -r uid complete failed < <(kubectl "${kc[@]}" get job "helm-install-$name" -n kube-system \
            -o jsonpath='{.metadata.uid}{"|"}{.status.conditions[?(@.type=="Complete")].status}{"|"}{.status.conditions[?(@.type=="Failed")].status}{"\n"}' 2>/dev/null)
        if [ -n "$uid" ] && [ "$uid" != "$old_uid" ]; then
            if [ "$complete" = "True" ]; then
                return 0
            fi
            if [ "$failed" = "True" ]; then
                err "helm-controller could not apply $name:"
                show_helm_error "$name" "$helm_error"
                err "Run ./update.sh again to retry it"
                return 1
            fi
            # The Job restarts helm inside its pod and deletes the pod when it
            # gives up, so helm's error is read while the pod is still there.
            logs="$(kubectl "${kc[@]}" logs -n kube-system -l "batch.kubernetes.io/controller-uid=$uid" --previous --tail=30 2>/dev/null)"
            [ -n "$logs" ] && helm_error="$logs"
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
            err "helm-controller did not apply $name in time:"
            show_helm_error "$name" "$helm_error"
            return 1
        fi
        sleep 3
    done
}

show_helm_error() {
    local -a kc=()
    [ -n "${KUBECONFIG:-}" ] && kc=(--kubeconfig="$KUBECONFIG")

    if [ -n "$2" ]; then
        printf '%s\n' "$2" >&2
    elif ! kubectl "${kc[@]}" logs "job/helm-install-$1" -n kube-system --tail=30 --pod-running-timeout=5s >&2 2>/dev/null; then
        err "helm-install-$1 left no logs: its pod is already gone"
    fi
}
