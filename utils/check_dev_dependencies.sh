#!/bin/bash

check_dev_dependencies() {
  local missing_deps=()

  # Check for Docker Desktop
  if ! docker info >/dev/null 2>&1; then
    missing_deps+=("Docker Desktop (docker daemon not running or not installed)")
  fi

  # Check for k3d — auto-install if missing
  if ! command -v k3d >/dev/null 2>&1; then
    echo "k3d not found. Install automatically? [Y/n]"
    read -r response
    if [[ "$response" =~ ^[Nn]$ ]]; then
      missing_deps+=("k3d")
    else
      echo "Installing k3d..."
      if curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash; then
        echo "k3d installed successfully."
      else
        echo "Failed to install k3d."
        missing_deps+=("k3d (auto-install failed)")
      fi
    fi
  fi

  # Check for mkcert — auto-install if missing
  if ! command -v mkcert >/dev/null 2>&1; then
    echo "mkcert not found. Install automatically? [Y/n]"
    read -r response
    if [[ "$response" =~ ^[Nn]$ ]]; then
      missing_deps+=("mkcert")
    else
      if command -v brew >/dev/null 2>&1; then
        echo "Installing mkcert via Homebrew..."
        if brew install mkcert; then
          echo "mkcert installed successfully."
        else
          echo "Failed to install mkcert."
          missing_deps+=("mkcert (auto-install failed)")
        fi
      else
        echo "Homebrew not found. Cannot auto-install mkcert."
        missing_deps+=("mkcert (install Homebrew first or install manually: https://github.com/FiloSottile/mkcert)")
      fi
    fi
  fi

  if [ ${#missing_deps[@]} -gt 0 ]; then
    echo ""
    echo "Error: Missing required development dependencies:"
    for dep in "${missing_deps[@]}"; do
      echo "  - $dep"
    done
    echo ""
    echo "Please install the missing dependencies:"
    if [[ " ${missing_deps[@]} " =~ "Docker Desktop" ]]; then
      echo "  - Docker Desktop: https://www.docker.com/products/docker-desktop/"
    fi
    if [[ " ${missing_deps[@]} " =~ "k3d" ]]; then
      echo "  - k3d: https://k3d.io/stable/#releases"
    fi
    if [[ " ${missing_deps[@]} " =~ "mkcert" ]]; then
      echo "  - mkcert: https://github.com/FiloSottile/mkcert"
    fi
    exit 1
  fi
}

