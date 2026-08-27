#!/bin/bash

# What the operator sees while Let's Encrypt does its thing. It used to loop
# forever on whatever `kubectl get` returned, which meant the one failure mode
# that actually needed explaining -- no Certificate resource at all, because the
# apply that should have created it was rejected -- rendered as three empty
# tables refreshing every ten seconds with no hint of what to do. Now it names
# that case, and it gives up eventually instead of hanging an install script.
watch_ssl_status() {
    local interval="${WATCH_SSL_INTERVAL:-10}"
    local grace="${WATCH_SSL_GRACE:-60}"
    local timeout="${WATCH_SSL_TIMEOUT:-900}"
    local started=$SECONDS
    local elapsed certs total ready
    local primary_ready_at=""

    echo "--------------------------------"
    echo "Watching SSL certificate and ACME challenge status (will exit when all certs are valid, Ctrl+C to stop)..."
    if [ "$CLOUDFLARE" != false ]; then
        echo "If you're using Cloudflare make sure to add a redirect rule to exclude the ACME challenge:"
        echo "  https://docs.5stack.gg/install/cloudflare/dns-and-ssl"
    fi

    # Save the cursor position so we can redraw the status section in-place
    if [ -t 1 ]; then
        tput sc
    fi

    while true; do
        # Restore cursor and clear everything below, so we only refresh the
        # status area while keeping everything printed above intact.
        if [ -t 1 ]; then
            tput rc
            tput ed
        fi
        elapsed=$((SECONDS - started))
        date
        echo
        echo "=== Certificates (namespace: 5stack) ==="
        kubectl --kubeconfig=$KUBECONFIG get certificates.cert-manager.io -n 5stack || true

        certs="$(kubectl --kubeconfig=$KUBECONFIG get certificates.cert-manager.io -n 5stack \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\t"}{.status.conditions[?(@.type=="Ready")].message}{"\n"}{end}' 2>/dev/null)"

        # cert-manager puts the useful part -- "Issuer not found", a rate limit,
        # the failed order -- in the Ready condition's message, which the plain
        # `get` output above truncates away.
        if [ -n "$certs" ]; then
            echo
            while IFS=$'\t' read -r name status message; do
                [ -z "$name" ] && continue
                [ "$status" = "True" ] && continue
                [ -n "$message" ] && echo "  $name: $message"
            done <<< "$certs"
        fi

        echo
        echo "=== Orders (namespace: 5stack) ==="
        kubectl --kubeconfig=$KUBECONFIG get orders.acme.cert-manager.io -n 5stack || true
        echo
        echo "=== Challenges (namespace: 5stack) ==="
        echo "NAME                                STATE     DOMAIN              AGE"
        challenges=$(kubectl --kubeconfig=$KUBECONFIG get challenges.acme.cert-manager.io -n 5stack -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        for ch in $challenges; do
            # Single line with the standard challenge info (no header)
            line=$(kubectl --kubeconfig=$KUBECONFIG get challenge "$ch" -n 5stack --no-headers 2>/dev/null || true)
            [ -z "$line" ] && continue
            echo "$line"

            # Latest event for this specific challenge
            if command -v jq &>/dev/null; then
                latest_event=$(kubectl --kubeconfig=$KUBECONFIG get events -n 5stack \
                    --field-selector involvedObject.kind=Challenge,involvedObject.name="$ch" \
                    --sort-by=.lastTimestamp -o json 2>/dev/null | \
                    jq -r 'if (.items | length) > 0 then .items[-1] | "\(.type) \(.reason): \(.message)" else "" end' 2>/dev/null)
                if [ -n "$latest_event" ] && [ "$latest_event" != "null" ]; then
                    echo "$latest_event"
                fi
            fi
            echo
        done
        echo

        # An empty namespace is not "still working" -- nothing is going to
        # create a Certificate on its own. Say so, and show the two things that
        # explain it.
        if [ -z "$certs" ] && [ "$elapsed" -ge "$grace" ]; then
            ssl_no_certificates_hint
        fi

        if [ -n "$certs" ]; then
            total=$(echo "$certs" | grep -c .)
            ready=$(echo "$certs" | awk -F'\t' '$2 == "True"' | grep -c .)
            if [ "$total" -gt 0 ] && [ "$ready" -eq "$total" ]; then
                echo "✓ all certificates are ready ($ready/$total)"
                echo "Exiting..."
                return 0
            fi

            # 5stack-ssl covers the panel itself; 5stack-mediamtx-ssl covers the
            # streaming host, which plenty of installs never point DNS at. Don't
            # hold an otherwise-finished install hostage to that one -- give it a
            # short grace period, then say what's still outstanding and move on.
            if echo "$certs" | grep -q "^5stack-ssl"$'\t'"True"; then
                if [ -z "$primary_ready_at" ]; then
                    primary_ready_at=$SECONDS
                elif [ $((SECONDS - primary_ready_at)) -ge "${WATCH_SSL_EXTRA:-120}" ]; then
                    warn "5stack-ssl is ready, but these are not:"
                    echo "$certs" | awk -F'\t' '$2 != "True" { print "      " $1 }'
                    warn "check that their DNS points at this server, then re-run ./fix-ssl.sh"
                    return 0
                fi
            fi
        fi

        if [ "$elapsed" -ge "$timeout" ]; then
            echo
            err "certificates were not issued after $((timeout / 60)) minutes"
            err "run ./debug.sh for a full report, or ./fix-ssl.sh to retry issuance"
            return 1
        fi

        sleep "$interval"
    done
}

ssl_no_certificates_hint() {
    echo "No Certificate resources exist in the 5stack namespace."
    echo "They are declared in overlays/cert-manager, so this means the apply was"
    echo "rejected -- usually because cert-manager was not serving yet."
    echo
    echo "cert-manager pods:"
    kubectl --kubeconfig=$KUBECONFIG -n cert-manager get pods 2>&1 | sed 's/^/  /'
    echo
    echo "Issuer:"
    kubectl --kubeconfig=$KUBECONFIG -n 5stack get issuers.cert-manager.io 2>&1 | sed 's/^/  /'
    echo
    echo "Once the cert-manager pods are Running, re-run ./update.sh."
    echo
}
