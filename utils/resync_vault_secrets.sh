#!/bin/bash

# Nudges external-secrets back into sync with Vault.
#
# When Vault is sealed, the operator's cached client starts failing and the
# SecretStore goes NotReady. Unsealing does not recover it promptly: each
# ExternalSecret only retries on its own refreshInterval (1h), and the
# Kubernetes auth role issues 1h tokens, so the cached token has usually
# expired too. The result is a cluster that looks broken for up to an hour
# after Vault is perfectly healthy again.
#
# force-sync alone does not fix an expired token -- only restarting the
# controller makes it log in again -- so this escalates.

vault_secret_store_ready() {
    local status
    status=$(kubectl --kubeconfig=$KUBECONFIG -n 5stack get secretstore secretstore-5stack \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)

    [ "$status" = "True" ]
}

force_sync_external_secrets() {
    local stamp
    stamp=$(date +%s)

    kubectl --kubeconfig=$KUBECONFIG -n 5stack get externalsecret -o name 2>/dev/null \
        | while read -r secret; do
            kubectl --kubeconfig=$KUBECONFIG -n 5stack annotate "$secret" \
                force-sync="$stamp" --overwrite >/dev/null 2>&1
        done
}

# ExternalSecrets that haven't produced their Secret yet. This is what actually
# matters -- a store that reports Ready while a secret is still missing would
# leave pods stuck in CreateContainerConfigError.
unsynced_external_secrets() {
    kubectl --kubeconfig=$KUBECONFIG -n 5stack get externalsecret \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
        | awk -F'\t' '$2 != "True" { print $1 }'
}

wait_for_external_secrets() {
    local timeout=$1
    local waited=0

    while [ $waited -lt "$timeout" ]; do
        if [ -z "$(unsynced_external_secrets)" ] && vault_secret_store_ready; then
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done

    return 1
}

resync_vault_secrets() {
    if [ "$VAULT_MANAGER" != true ]; then
        return 0
    fi

    if ! kubectl --kubeconfig=$KUBECONFIG -n 5stack get secretstore secretstore-5stack >/dev/null 2>&1; then
        return 0
    fi

    if vault_secret_store_ready && [ -z "$(unsynced_external_secrets)" ]; then
        force_sync_external_secrets
        ok "vault secrets synced"
        return 0
    fi

    # An unhealthy store is an auth problem, and restarting is the only thing
    # that makes the operator log in again -- a force-sync cannot fix a token
    # that expired while Vault was sealed. Secrets that are merely still
    # reconciling (a fresh install) just need waiting on.
    if vault_secret_store_ready; then
        ok "waiting for secrets to sync"
    else
        warn "vault secret store is not ready (was Vault sealed?), re-authenticating"

        kubectl --kubeconfig=$KUBECONFIG -n external-secrets rollout restart deploy >/dev/null 2>&1
        kubectl --kubeconfig=$KUBECONFIG -n external-secrets rollout status deploy --timeout=120s >/dev/null 2>&1
    fi

    force_sync_external_secrets

    if wait_for_external_secrets 120; then
        ok "vault secrets synced"
        return 0
    fi

    # Deliberately loud and non-zero: the deployment that follows will roll pods
    # that cannot start without these, and a silent pass here turns a clear
    # "Vault is sealed" into a confusing crash loop ten minutes later.
    warn "vault secrets did not sync -- pods that need them will not start"
    warn "unseal Vault, then re-run ./update.sh (or ./fix-vault.sh)"

    local pending
    pending=$(unsynced_external_secrets | tr '\n' ' ')
    if [ -n "$pending" ]; then
        warn "still pending: $pending"
    fi

    warn "  kubectl -n external-secrets logs deploy/external-secrets --tail=50"

    return 1
}
