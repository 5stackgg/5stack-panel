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
        *"the server is currently unable to handle the request"*)
            return 0 ;;
    esac
    return 1
}

# A kind the API server has never heard of. This looks like a startup race and
# is not one: no amount of waiting installs a CRD, so retrying only delays a
# message that names the wrong cause. The realistic trigger is VAULT_MANAGER=true
# without overlays/vault/scripts/install.sh having been run, which leaves
# ExternalSecret undefined -- "wait for the webhook" sends the operator looking
# in entirely the wrong place.
missing_crd_error() {
    case "$1" in
        *"no matches for kind"*|\
        *"could not find the requested resource"*|\
        *"ensure CRDs are installed first"*)
            return 0 ;;
    esac
    return 1
}

# Poll until an admission webhook answers, using a server-side dry run as the
# probe. Shared with wait_for_cert_manager: the two used to be the same loop
# written twice, and had already drifted on error reporting and on whether they
# passed --kubeconfig.
#
# The question is only whether the webhook answers, so a rejection of the probe
# itself still counts as ready -- keep waiting only while the error says the
# endpoint or its CA bundle isn't there yet.
wait_for_webhook() {
    local label="$1"
    local probe="$2"
    local timeout="${3:-180}"
    local deadline=$((SECONDS + timeout))
    local output
    local -a kc=()
    [ -n "$KUBECONFIG" ] && kc=(--kubeconfig="$KUBECONFIG")

    echo "Waiting for the ${label}..."
    while true; do
        if output="$(echo "$probe" | kubectl "${kc[@]}" apply --dry-run=server -f - 2>&1)" \
            || ! webhook_unavailable_error "$output"; then
            echo "${label} is ready!"
            return 0
        fi

        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "${label} did not become available after ${timeout}s:" >&2
            echo "$output" | sed 's/^/    /' >&2
            return 1
        fi

        sleep 5
    done
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
# Applies are idempotent, so a webhook failure is retried a few times before
# giving up: that absorbs the residual admission-webhook flakes on a cluster
# that is still settling without hiding a real, persistent failure.
apply_overlay() {
    local overlay="$1"
    local attempts="${2:-6}"
    local retry_delay="${3:-10}"
    local rendered errors output attempt
    # --kubeconfig only when there is one to pass; see wait_for_webhook.
    local -a kc=()
    [ -n "$KUBECONFIG" ] && kc=(--kubeconfig="$KUBECONFIG")

    local target="$overlay"
    case "$overlay" in
        /*) ;;
        *) target="$PANEL_DIR/$overlay" ;;
    esac

    rendered="$(mktemp)"
    errors="$(mktemp)"
    # One cleanup for all five return paths below, rather than a pair of rm
    # lines before each of them that the next early return will forget.
    trap 'rm -f "$rendered" "$errors"' RETURN

    if ! "$PANEL_DIR/kustomize" build "$target" >"$rendered" 2>"$errors"; then
        err "failed to render $overlay"
        sed 's/^/    /' "$errors" >&2
        return 1
    fi

    # kustomize warns on stderr while still succeeding (deprecated fields, for
    # one). Silently discarding that is how a deprecation becomes a breakage.
    if [ -s "$errors" ] && [ "$DEBUG" = true ]; then
        sed 's/^/    /' "$errors" >&2
    fi

    if [ ! -s "$rendered" ]; then
        err "$overlay rendered no resources"
        return 1
    fi

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if output="$(kubectl "${kc[@]}" apply -f "$rendered" 2>&1)"; then
            if [ "$DEBUG" = true ]; then
                echo "$output"
            fi
            return 0
        fi

        if missing_crd_error "$output"; then
            err "$overlay refers to a resource kind this cluster does not have:"
            echo "$output" | sed 's/^/    /' >&2
            if [ "$VAULT_MANAGER" = true ]; then
                err "if this names ExternalSecret, run overlays/vault/scripts/install.sh first"
            fi
            return 1
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
    return 1
}
