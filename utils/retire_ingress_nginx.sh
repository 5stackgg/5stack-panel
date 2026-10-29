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
# Puts ingress-nginx's LoadBalancer Service back as the panel shipped it, on the
# ports it had, so a handover that stalls leaves it serving rather than nothing.
restore_ingress_nginx_service() {
    local -a kc=()
    [ -n "${KUBECONFIG:-}" ] && kc=(--kubeconfig="$KUBECONFIG")

    output_redirect kubectl "${kc[@]}" apply -f - <<YAML
apiVersion: v1
kind: Service
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  ports:
    - name: http
      appProtocol: http
      port: $1
      targetPort: http
    - name: https
      appProtocol: https
      port: $2
      targetPort: https
  selector:
    app.kubernetes.io/component: controller
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
YAML
}

# --immediately skips waiting for Traefik to accept the panel's routes: dev.sh
# retires ingress-nginx before Tilt has applied them, and a dev cluster has no
# visitors to keep serving.
retire_ingress_nginx() {
    local deadline moved="" http_port="" https_port=""
    local -a kc=()
    [ -n "${KUBECONFIG:-}" ] && kc=(--kubeconfig="$KUBECONFIG")

    # First: its failurePolicy is Fail, so once the controller behind it is gone
    # it rejects every Ingress write in the cluster, cert-manager's included.
    output_redirect kubectl "${kc[@]}" delete validatingwebhookconfiguration ingress-nginx-admission --ignore-not-found

    if kubectl "${kc[@]}" get service ingress-nginx-controller -n ingress-nginx >/dev/null 2>&1; then
        # Not before Traefik has taken up the panel's routes, or it would be
        # handed the ports with nothing to serve on them.
        if [ "${1:-}" != --immediately ] && ! output_redirect kubectl "${kc[@]}" wait httproute/api -n 5stack --timeout=120s \
            --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True; then
            err "Traefik has not accepted the panel's routes; ingress-nginx is left serving"
            return 1
        fi
        http_port="$(kubectl "${kc[@]}" get service ingress-nginx-controller -n ingress-nginx \
            -o jsonpath='{.spec.ports[?(@.name=="http")].port}' 2>/dev/null)"
        https_port="$(kubectl "${kc[@]}" get service ingress-nginx-controller -n ingress-nginx \
            -o jsonpath='{.spec.ports[?(@.name=="https")].port}' 2>/dev/null)"
        echo "Moving ports 80/443 from ingress-nginx to Traefik..."
        output_redirect kubectl "${kc[@]}" delete service ingress-nginx-controller -n ingress-nginx --wait=true
        moved=1
    fi

    deadline=$((SECONDS + ${TRAEFIK_ADDRESS_TIMEOUT:-180}))
    until [ -n "$(kubectl "${kc[@]}" get service traefik -n traefik -o jsonpath='{.status.loadBalancer.ingress}' 2>/dev/null)" ]; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            err "Traefik's LoadBalancer Service never got an address:"
            kubectl "${kc[@]}" get service traefik -n traefik >&2
            kubectl "${kc[@]}" get pods -A -l svccontroller.k3s.cattle.io/svcname=traefik >&2
            if [ -n "$moved" ] && restore_ingress_nginx_service "${http_port:-80}" "${https_port:-443}"; then
                err "ingress-nginx has its ports back and keeps serving the panel; re-run ./update.sh once Traefik's Service can get an address"
            fi
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
