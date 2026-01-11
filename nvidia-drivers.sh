#!/bin/bash
set -e
apt install -y nvidia-container-toolkit nvidia-container-runtime cuda-drivers-fabricmanager-570 nvidia-headless-570-server-open nvidia-utils-570-server

kubectl create -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.1/deployments/static/nvidia-device-plugin.yml