#!/bin/bash

watch_ssl_status() {
    echo "--------------------------------"
    echo "Watching SSL certificate and ACME challenge status (will exit when all certs are valid, Ctrl+C to stop)..."
    echo "If you're using Cloudflare make sure to add a page rule (https://docs.5stack.gg/install/reverse-proxy#cloudflare-required-page-rule) to filter the ACME challenge."
    local interval="${WATCH_SSL_INTERVAL:-10}"
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
        date
        echo
        echo "=== Certificates (namespace: 5stack) ==="
        kubectl --kubeconfig=$KUBECONFIG get certificates.cert-manager.io -n 5stack || true
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
            latest_event=$(kubectl --kubeconfig=$KUBECONFIG get events -n 5stack \
                --field-selector involvedObject.kind=Challenge,involvedObject.name="$ch" \
                --sort-by=.lastTimestamp -o json 2>/dev/null | \
                jq -r 'if (.items | length) > 0 then .items[-1] | "\(.type) \(.reason): \(.message)" else "" end' 2>/dev/null)
            if [ -n "$latest_event" ] && [ "$latest_event" != "null" ]; then
                echo "$latest_event"
            fi
            echo
        done
        echo
        
        # Check if all certificates are valid and exit if so
        certs_json=$(kubectl --kubeconfig=$KUBECONFIG get certificates.cert-manager.io -n 5stack -o json 2>/dev/null || echo '{"items":[]}')
        cert_count=$(echo "$certs_json" | jq -r '.items | length' 2>/dev/null || echo "0")
        
        if [ "$cert_count" -gt 0 ]; then
            # Check if all certificates are ready
            all_ready=$(echo "$certs_json" | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True")) | .metadata.name' 2>/dev/null | wc -l | tr -d ' ')
            if [ "$all_ready" -eq "$cert_count" ]; then
                echo "✓ All certificates are valid!"
                echo "Exiting..."
                break
            fi
        fi
        
        sleep "$interval"
    done
}


