#!/bin/bash

# The Ingresses the panel created before it moved to the Gateway API. Named
# rather than selected: plugins keep their own nginx-class Ingresses in the
# same namespace, and Traefik serves those.
PANEL_INGRESSES=(api demos ws relay file-manager hasura web s3-console typesense mediamtx snapshot hasura-dashboard queues)

# Hands ports 80/443 from ingress-nginx to Traefik, then removes ingress-nginx.
# Safe to re-run, and a no-op on an install that never had it.
#
# k3s ServiceLB gives a host port to one LoadBalancer Service only, so
# Traefik's Service sits pending until ingress-nginx's is deleted; traffic is
# down for the seconds in between. The old Ingresses go only after that: until
# then ingress-nginx is what serves them, and Traefik's own copies of them
# route to the same backends as the HTTPRoutes.
retire_ingress_nginx() {
    local deadline
    local -a kc=()
    [ -n "${KUBECONFIG:-}" ] && kc=(--kubeconfig="$KUBECONFIG")

    # First: its failurePolicy is Fail, so once the controller behind it is gone
    # it rejects every Ingress write in the cluster, cert-manager's included.
    output_redirect kubectl "${kc[@]}" delete validatingwebhookconfiguration ingress-nginx-admission --ignore-not-found

    if kubectl "${kc[@]}" get service ingress-nginx-controller -n ingress-nginx >/dev/null 2>&1; then
        echo "Moving ports 80/443 from ingress-nginx to Traefik..."
        output_redirect kubectl "${kc[@]}" delete service ingress-nginx-controller -n ingress-nginx --wait=true
    fi

    deadline=$((SECONDS + 180))
    until [ -n "$(kubectl "${kc[@]}" get service traefik -n traefik -o jsonpath='{.status.loadBalancer.ingress}' 2>/dev/null)" ]; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            err "Traefik's LoadBalancer Service never got an address:"
            kubectl "${kc[@]}" get service traefik -n traefik >&2
            kubectl "${kc[@]}" get pods -A -l svccontroller.k3s.cattle.io/svcname=traefik >&2
            return 1
        fi
        sleep 2
    done

    # Orphaned, not cascaded: on an old install ingress-shim may still own the
    # 5stack-ssl Certificate through one of these.
    output_redirect kubectl "${kc[@]}" delete ingress -n 5stack --ignore-not-found --cascade=orphan "${PANEL_INGRESSES[@]}"
    output_redirect kubectl "${kc[@]}" delete namespace ingress-nginx --ignore-not-found --wait=false
    output_redirect kubectl "${kc[@]}" delete clusterrole,clusterrolebinding ingress-nginx ingress-nginx-admission --ignore-not-found
}
