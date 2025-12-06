#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/utils.sh"

checkout_repos

echo "Setup to use Kubernetes..."
choose_k8s_context

install_ingress_nginx

echo "Labeling node..."
kubectl label node $(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') 5stack-api=true 5stack-hasura=true 5stack-minio=true 5stack-timescaledb=true 5stack-redis=true 5stack-typesense=true 5stack-web=true 5stack-dev-server=true

copy_config_or_secrets "overlays/local-secrets" "overlays/dev/secrets"

replace_rand32_in_env_files "overlays/dev/secrets"

setup_postgres_connection_string "overlays/dev/secrets/timescaledb-secrets.env"

setup_steam_web_api_key "overlays/dev/secrets/steam-secrets.env"

echo "Creating 5Stack directories..."
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl run create-5stack-dirs --rm -i --restart=Never --image=busybox \
  --overrides='{
  "spec": {
    "hostNetwork": true,
    "containers": [{
      "name": "create-5stack-dirs",
      "image": "busybox",
      "command": ["sh", "-c", "mkdir -p /opt/5stack/dev /opt/5stack/demos /opt/5stack/steamcmd /opt/5stack/serverfiles /opt/5stack/timescaledb /opt/5stack/typesense /opt/5stack/minio /opt/5stack/custom-plugins /var/lib/rancher/k3s/agent/pod-manifests && echo Directories created successfully"],
      "securityContext": {
        "privileged": true
      },
      "volumeMounts": [{
        "name": "opt",
        "mountPath": "/opt"
      }, {
        "name": "var-lib",
        "mountPath": "/var/lib"
      }]
    }],
    "volumes": [{
      "name": "opt",
      "hostPath": {
        "path": "/opt",
        "type": "Directory"
      }
    }, {
      "name": "var-lib",
      "hostPath": {
        "path": "/var/lib",
        "type": "Directory"
      }
    }],
    "nodeName": "'$NODE_NAME'"
  }
}'


if ! [ -f overlays/dev/certs/_wildcard.5stack.localhost+1.pem ]; then
  mkcert -install
  mkcert "*.5stack.localhost" 5stack.localhost
fi

tilt up