#!/bin/bash
echo "Setup FileSystem"
mkdir -p /opt/5stack/dev
mkdir -p /opt/5stack/demos
mkdir -p /opt/5stack/steamcmd
mkdir -p /opt/5stack/serverfiles
mkdir -p /opt/5stack/timescaledb
mkdir -p /opt/5stack/typesense
mkdir -p /opt/5stack/minio

echo "Environment files setup complete"

echo "Installing Kustomize ..."
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"  | bash


curl -sfL https://get.k3s.io | sh -s - --disable=traefik

kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/baremetal/deploy.yaml

echo "Updating Node to host services"
kubectl label node $(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') 5stack-api=true 5stack-hasura=true 5stack-minio=true 5stack-timescaledb=true 5stack-redis=true 5stack-typesense=true 5stack-web=true

source setup-env.sh "$@"

echo "Installed 5Stack, setup your env variables"
