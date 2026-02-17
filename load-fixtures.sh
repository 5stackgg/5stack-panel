#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/utils.sh"

export KUBECONFIG=~/.kube/5stack-dev

echo "Loading fixture data into dev database..."

# Run cleanup first, then fixtures
kubectl exec -n 5stack deploy/timescaledb -- \
    psql -U postgres -d 5stack -f /dev/stdin < "$SCRIPT_DIR/../api/hasura/fixtures/cleanup.sql"

kubectl exec -n 5stack deploy/timescaledb -- \
    psql -U postgres -d 5stack -f /dev/stdin < "$SCRIPT_DIR/../api/hasura/fixtures/fixtures.sql"

echo "Done. Fixture data loaded."
