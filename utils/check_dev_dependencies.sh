#!/bin/bash

check_dev_dependencies() {
  local missing_deps=()
  
  # Check for Docker Desktop
  if ! docker info >/dev/null 2>&1; then
    missing_deps+=("Docker Desktop (docker daemon not running or not installed)")
  fi
  
  # Check for k3d
  if ! command -v k3d >/dev/null 2>&1; then
    missing_deps+=("k3d")
  fi
  
  # Check for mkcert
  if ! command -v mkcert >/dev/null 2>&1; then
    missing_deps+=("mkcert")
  fi
  
  if [ ${#missing_deps[@]} -gt 0 ]; then
    echo "Error: Missing required development dependencies:"
    for dep in "${missing_deps[@]}"; do
      echo "  - $dep"
    done
    echo ""
    echo "Please install the missing dependencies:"
    if [[ " ${missing_deps[@]} " =~ " Docker Desktop" ]]; then
      echo "  - Docker Desktop: https://www.docker.com/products/docker-desktop/"
    fi
    if [[ " ${missing_deps[@]} " =~ " k3d " ]]; then
      echo "  - k3d: https://k3d.io/stable/#releases"
    fi
    if [[ " ${missing_deps[@]} " =~ " mkcert " ]]; then
      echo "  - mkcert: https://github.com/FiloSottile/mkcert"
    fi
    exit 1
  fi
}

