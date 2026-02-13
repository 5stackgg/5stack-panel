#!/bin/bash

source setup-env.sh "$@"
check_sudo

echo "Setup FileSystem"
mkdir -p /opt/5stack/dev
mkdir -p /opt/5stack/demos
mkdir -p /opt/5stack/steamcmd
mkdir -p /opt/5stack/serverfiles
mkdir -p /opt/5stack/timescaledb
mkdir -p /opt/5stack/typesense
mkdir -p /opt/5stack/minio
mkdir -p /opt/5stack/custom-plugins

echo "Environment files setup complete"

echo "Installing K3s"
curl -sfL https://get.k3s.io | sh -s - --disable=traefik

echo "Installing Ingress Nginx, this may take a few minutes..."
install_ingress_nginx true

kubectl label node $(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') 5stack-api=true 5stack-hasura=true 5stack-minio=true 5stack-timescaledb=true 5stack-redis=true 5stack-typesense=true 5stack-web=true

source update.sh "$@"

echo "Installed 5Stack"
