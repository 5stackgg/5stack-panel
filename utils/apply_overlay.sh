#!/bin/bash

# Is this failure "an admission webhook isn't serving yet" rather than "the
# manifest is wrong"? Worth telling apart: the first is worth waiting out, the
# second should be reported immediately instead of after a minute of pointless
# retries. Both cert-manager and ingress-nginx front their resources with a
# failurePolicy: Fail webhook, and both produce these strings while starting.
webhook_unavailable_error() {
    case "$1" in
        *"failed calling webhook"*|\
        *"no endpoints available"*|\
        *"x509:"*|\
        *"connection refused"*|\
        *"context deadline exceeded"*|\
        *"the server is currently unable to handle the request"*|\
        *"no matches for kind"*|\
        *"could not find the requested resource"*)
            return 0 ;;
    esac
    return 1
}

# Render a kustomize overlay and apply it, loudly.
#
# The old form -- `./kustomize build overlay | kubectl apply -f -` -- discarded
# the exit status of both halves. A render error, or a resource the API server
# rejected, printed one line into a wall of output and the script went straight
# on to announce success. Every "the certificate never showed up" report starts
# there: the Certificate and Issuer are refused, the remaining ~200 resources
# land fine, and the install ends up watching a namespace that will never grow
# a Certificate.
#
# Applies are idempotent, so a failure is retried a few times before giving up:
# that absorbs the residual admission-webhook flakes on a cluster that is still
# settling without hiding a real, persistent failure.
apply_overlay() {
    local overlay="$1"
    local attempts="${2:-6}"
    local retry_delay="${3:-10}"
    local rendered errors output attempt

    local target="$overlay"
    case "$overlay" in
        /*) ;;
        *) target="$PANEL_DIR/$overlay" ;;
    esac

    rendered="$(mktemp)"
    errors="$(mktemp)"

    if ! "$PANEL_DIR/kustomize" build "$target" >"$rendered" 2>"$errors"; then
        err "failed to render $overlay"
        sed 's/^/    /' "$errors" >&2
        rm -f "$rendered" "$errors"
        return 1
    fi

    if [ ! -s "$rendered" ]; then
        err "$overlay rendered no resources"
        rm -f "$rendered" "$errors"
        return 1
    fi

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if output="$(kubectl --kubeconfig="$KUBECONFIG" apply -f "$rendered" 2>&1)"; then
            if [ "$DEBUG" = true ]; then
                echo "$output"
            fi
            rm -f "$rendered" "$errors"
            return 0
        fi

        if ! webhook_unavailable_error "$output"; then
            break
        fi

        if [ "$attempt" -lt "$attempts" ]; then
            warn "applying $overlay failed (an admission webhook is still starting), retrying in ${retry_delay}s [$attempt/$attempts]"
            if [ "$DEBUG" = true ]; then
                echo "$output" | sed 's/^/    /' >&2
            fi
            sleep "$retry_delay"
        fi
    done

    err "failed to apply $overlay:"
    echo "$output" | sed 's/^/    /' >&2
    rm -f "$rendered" "$errors"
    return 1
}
