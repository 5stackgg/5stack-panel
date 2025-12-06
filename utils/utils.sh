#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all utility functions
source "$SCRIPT_DIR/update_env_var.sh"
source "$SCRIPT_DIR/copy_config_or_secrets.sh"
source "$SCRIPT_DIR/replace_rand32_in_env_files.sh"
source "$SCRIPT_DIR/setup_postgres_connection_string.sh"
source "$SCRIPT_DIR/install_ingress_nginx.sh"
source "$SCRIPT_DIR/choose_k8s_context.sh"
