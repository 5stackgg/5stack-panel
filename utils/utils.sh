#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all utility functions
source "$SCRIPT_DIR/update_env_var.sh"
source "$SCRIPT_DIR/copy_config_or_secrets.sh"
source "$SCRIPT_DIR/replace_rand32_in_env_files.sh"
source "$SCRIPT_DIR/setup_postgres_connection_string.sh"
source "$SCRIPT_DIR/setup_steam_web_api_key.sh"
source "$SCRIPT_DIR/setup_k3s_token.sh"
source "$SCRIPT_DIR/install_ingress_nginx.sh"
source "$SCRIPT_DIR/choose_k8s_context.sh"
source "$SCRIPT_DIR/checkout_repos.sh"
source "$SCRIPT_DIR/check_dev_dependencies.sh"
source "$SCRIPT_DIR/watch_ssl_status.sh"
