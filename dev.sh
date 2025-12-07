#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/utils.sh"

checkout_repos

echo "Setup to use Kubernetes..."
check_dev_dependencies

if k3d cluster list 5stack-dev | grep -q '5stack-dev'; then
  echo "k3d cluster '5stack-dev' already exists. Skipping creation."
else
  k3d cluster create 5stack-dev \
    --k3s-arg "--disable=traefik@server:0" \
    --kubeconfig-switch-context=false \
    --kubeconfig-update-default=false \
    --registry-create 5stack-dev-registry
fi

k3d kubeconfig merge 5stack-dev -o ~/.kube/5stack-dev

export KUBECONFIG=~/.kube/5stack-dev

kubectl config use-context k3d-5stack-dev

install_ingress_nginx

echo "Labeling node..."
kubectl label node $(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') 5stack-api=true 5stack-hasura=true 5stack-minio=true 5stack-timescaledb=true 5stack-redis=true 5stack-typesense=true 5stack-web=true 5stack-dev-server=true

copy_config_or_secrets "overlays/local-secrets" "overlays/dev/secrets"

replace_rand32_in_env_files "overlays/dev/secrets"

setup_postgres_connection_string "overlays/dev/secrets/timescaledb-secrets.env"

setup_steam_web_api_key "overlays/dev/secrets/steam-secrets.env"

docker exec -it k3d-5stack-dev-server-0 sh -c "mkdir -p mkdir -p /opt/5stack/dev /opt/5stack/demos /opt/5stack/steamcmd /opt/5stack/serverfiles /opt/5stack/timescaledb /opt/5stack/typesense /opt/5stack/minio /opt/5stack/custom-plugins /var/lib/rancher/k3s/agent/pod-manifests && echo Directories created successfully"

if ! [ -f overlays/dev/certs/_wildcard.5stack.localhost+1.pem ]; then
  mkcert -install
  mkcert "*.5stack.localhost" 5stack.localhost
fi

tilt up