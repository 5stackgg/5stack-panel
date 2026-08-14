#!/bin/bash

# Re-authenticates external-secrets against Vault and re-syncs every
# ExternalSecret, without waiting for the hourly refresh.
#
# Run this after unsealing Vault.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/utils.sh" "$@"

if [ "$VAULT_MANAGER" != true ]; then
    warn "this install does not use Vault; nothing to do"
    exit 0
fi

step "Syncing Vault secrets"
resync_vault_secrets

step "Secret status"
kubectl --kubeconfig=$KUBECONFIG -n 5stack get secretstore secretstore-5stack
kubectl --kubeconfig=$KUBECONFIG -n 5stack get externalsecret
