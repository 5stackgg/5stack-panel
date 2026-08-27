#!/bin/bash

# The Certificate 5Stack itself is served on. Everything else in the namespace
# -- the mediamtx streaming cert, anything a plugin installs -- is best effort:
# see the exit rules in watch_ssl_status.
PRIMARY_CERTIFICATE="5stack-ssl"

# What the operator sees while Let's Encrypt does its thing. It used to loop
# forever on whatever `kubectl get` returned, which meant the one failure mode
# that actually needed explaining -- no Certificate resource at all, because the
# apply that should have created it was rejected -- rendered as three empty
# tables refreshing every ten seconds with no hint of what to do. Now it names
# that case, and it gives up eventually instead of hanging an install script.
#
# It exits successfully as soon as $PRIMARY_CERTIFICATE is valid and the others
# have had a short grace period, rather than holding out for every Certificate
# in the namespace. Waiting for all of them sounds stricter but is unreachable
# in practice: 5stack-mediamtx-ssl is created on every https install, for
# hls.$WEB_DOMAIN, a host most operators never point DNS at. Blocking on it
# would make a routine ./update.sh fail, and send the operator to fix-ssl.sh to
# re-request a certificate that cannot be issued -- burning a Let's Encrypt
# failed-validation slot on every pass.
watch_ssl_status() {
    local interval="${WATCH_SSL_INTERVAL:-10}"
    local grace="${WATCH_SSL_GRACE:-60}"
    local extra="${WATCH_SSL_EXTRA:-120}"
    local timeout="${WATCH_SSL_TIMEOUT:-900}"
    local started=$SECONDS
    local elapsed certs total ready primary_ready
    local primary_ready_at=""
    local challenges line latest_event ch
    local cert_name cert_status cert_message

    echo "--------------------------------"
    echo "Watching SSL certificate and ACME challenge status (will exit when $PRIMARY_CERTIFICATE is valid, Ctrl+C to stop)..."
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

        # One query, rendered as the table *and* used for the exit decision.
        # Fetching twice meant the table an operator was reading could describe
        # a different moment than the check that acted on it -- and at a 10s
        # interval over a 15 minute timeout it was ~90 needless round trips.
        certs="$(list_certificate_status)"

        echo "=== Certificates (namespace: 5stack) ==="
        if [ -z "$certs" ]; then
            echo "  (none)"
        else
            printf "  %-24s %-8s %s\n" "NAME" "READY" "STATUS"
            # cert-manager puts the useful part -- "Issuer not found", a rate
            # limit, the failed order -- in the Ready condition's message, which
            # the plain `kubectl get` table truncates away.
            while IFS=$'\t' read -r cert_name cert_status cert_message; do
                [ -z "$cert_name" ] && continue
                printf "  %-24s %-8s %s\n" "$cert_name" "${cert_status:-Unknown}" "$cert_message"
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

        primary_ready=false
        if [ -n "$certs" ]; then
            # NF >= 2 rather than a plain line count: a Ready message spanning
            # more than one line would otherwise be counted as its own
            # certificate, and continuation lines carry no tabs.
            total=$(echo "$certs" | awk -F'\t' 'NF >= 2 && $1 != ""' | wc -l | tr -d ' ')
            ready=$(echo "$certs" | awk -F'\t' 'NF >= 2 && $2 == "True"' | wc -l | tr -d ' ')
            if echo "$certs" | awk -F'\t' -v p="$PRIMARY_CERTIFICATE" '$1 == p && $2 == "True" { found = 1 } END { exit !found }'; then
                primary_ready=true
            fi

            if [ "$total" -gt 0 ] && [ "$ready" -eq "$total" ]; then
                echo "✓ all certificates are ready ($ready/$total)"
                echo "Exiting..."
                return 0
            fi

            # The primary is up; give the rest a short grace period, then report
            # what is still outstanding and let the install finish.
            if [ "$primary_ready" = true ]; then
                if [ -z "$primary_ready_at" ]; then
                    primary_ready_at=$SECONDS
                elif [ $((SECONDS - primary_ready_at)) -ge "$extra" ]; then
                    ssl_outstanding_warning "$certs"
                    return 0
                fi
            fi
        fi

        if [ "$elapsed" -ge "$timeout" ]; then
            echo
            # Checked before failing, not after: with the timeout and the grace
            # period evaluated in the same iteration, a primary that went valid
            # within $extra of the deadline used to fall through to a failure
            # that aborted the install -- for a certificate that had been
            # issued successfully.
            if [ "$primary_ready" = true ]; then
                ssl_outstanding_warning "$certs"
                return 0
            fi
            err "$PRIMARY_CERTIFICATE was not issued after $((timeout / 60)) minutes"
            err "run ./debug.sh for a full report, or ./fix-ssl.sh to retry issuance"
            return 1
        fi

        sleep "$interval"
    done
}

ssl_outstanding_warning() {
    warn "$PRIMARY_CERTIFICATE is ready, but these are not:"
    echo "$1" | awk -F'\t' 'NF >= 2 && $2 != "True" { print "      " $1 }'
    warn "if you use those hosts, check their DNS points at this server and re-run ./fix-ssl.sh"
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
