#!/bin/bash

# Sets up the game-streaming feature: prompts for which cluster nodes have
# NVIDIA GPUs, labels them `nvidia-gpu=true`, and deploys MediaMTX (the SRT/HLS
# publish target). Production streamer pods are spawned per-match by the
# 5stack API on nodes carrying that label.
#
# NVIDIA-only today. AMD (issue #467) and Intel (issue #468) are tracked but
# not yet supported.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_DIR/utils/utils.sh" "$@"

# GPU vendor + nodes are stored in .5stack-env.config (sourced by setup-env.sh)
# as $GPU_VENDOR and $GPU_NODES. Re-runs use those as defaults so a user can
# add or remove a GPU node by re-running this script.
PREVIOUS_GPU_VENDOR="${GPU_VENDOR:-}"
PREVIOUS_GPU_NODES="${GPU_NODES:-}"

case "$PREVIOUS_GPU_VENDOR" in
    nvidia) DEFAULT_VENDOR_CHOICE=1 ;;
    amd)    DEFAULT_VENDOR_CHOICE=2 ;;
    intel)  DEFAULT_VENDOR_CHOICE=3 ;;
    *)      DEFAULT_VENDOR_CHOICE=1 ;;
esac

# Pure-bash interactive selectors (utils/interactive_select.sh): arrow keys
# to move, Space to toggle in checklist, Enter to confirm. No external deps.
interactive_menu VENDOR_INDEX \
    "Which GPU vendor will the streamer nodes use?" \
    $((DEFAULT_VENDOR_CHOICE - 1)) \
    "NVIDIA" \
    "AMD (not yet supported)" \
    "Intel (not yet supported)"

case "$VENDOR_INDEX" in
    0) GPU_VENDOR=nvidia ;;
    1)
        echo ""
        echo "ERROR: AMD GPUs are not supported yet."
        echo "  Tracking issue: https://github.com/5stackgg/5stack-panel/issues/467"
        echo "  Docs:           https://docs.5stack.gg/advanced/game-streaming/amd"
        exit 1
        ;;
    2)
        echo ""
        echo "ERROR: Intel GPUs are not supported yet."
        echo "  Tracking issue: https://github.com/5stackgg/5stack-panel/issues/468"
        echo "  Docs:           https://docs.5stack.gg/advanced/game-streaming/intel"
        exit 1
        ;;
esac
echo ""

ALL_NODES=$(kubectl --kubeconfig=$KUBECONFIG get nodes -o jsonpath='{.items[*].metadata.name}')
ALL_NODES_ARR=()
for node in $ALL_NODES; do ALL_NODES_ARR+=("$node"); done

if [ ${#ALL_NODES_ARR[@]} -eq 0 ]; then
    echo "ERROR: no cluster nodes found via kubectl. Check KUBECONFIG=$KUBECONFIG."
    exit 1
fi

interactive_checklist GPU_NODES \
    "Select nodes that have GPUs:" \
    "$PREVIOUS_GPU_NODES" \
    "${ALL_NODES_ARR[@]}"

for node in $GPU_NODES; do
    if ! echo "$ALL_NODES" | tr ' ' '\n' | grep -qx "$node"; then
        echo "ERROR: node '$node' is not in this cluster."
        echo "Available: $ALL_NODES"
        exit 1
    fi
done

# nvidia-gpu drives the connector DaemonSet, 5stack-game-streamer drives the
# streamer Deployment. We set both together by default; an operator can later
# strip one with `kubectl label node X nvidia-gpu-` (or 5stack-game-streamer-)
# to opt a node out of one workload while keeping the other.
for node in $ALL_NODES; do
    if echo " $GPU_NODES " | grep -q " $node "; then
        kubectl --kubeconfig=$KUBECONFIG label node "$node" nvidia-gpu=true 5stack-game-streamer=true --overwrite >/dev/null
    elif echo " $PREVIOUS_GPU_NODES " | grep -q " $node "; then
        kubectl --kubeconfig=$KUBECONFIG label node "$node" nvidia-gpu- 5stack-game-streamer- >/dev/null 2>&1 || true
    fi
done

update_env_var ".5stack-env.config" "GPU_VENDOR" "$GPU_VENDOR"
update_env_var ".5stack-env.config" "GPU_NODES" "\"$GPU_NODES\""
echo ""

if [ -z "$GPU_NODES" ]; then
    echo "ERROR: no GPU nodes selected; the streamer cannot run without a GPU node."
    exit 1
fi

SECRETS_OVERLAY="overlays/local-secrets"
STEAM_SECRETS_FILE="$SECRETS_OVERLAY/steam-secrets.env"

# ---------------------------------------------------------------------------
# Steam credentials. The streamer logs into Steam non-interactively via
# steamcmd to download CS2, so we need a username + password that don't sit
# behind Steam Guard / 2FA. If the values are already filled (including a
# `VAULT` placeholder for the HashiCorp Vault integration), we leave them
# alone.
# ---------------------------------------------------------------------------
STEAM_SECRETS_CHANGED=0
STEAM_USER_CURRENT=$(grep -h "^STEAM_USER=" "$STEAM_SECRETS_FILE" | cut -d '=' -f2-)
STEAM_PASSWORD_CURRENT=$(grep -h "^STEAM_PASSWORD=" "$STEAM_SECRETS_FILE" | cut -d '=' -f2-)

if [ -z "$STEAM_USER_CURRENT" ] || [ -z "$STEAM_PASSWORD_CURRENT" ]; then
    echo ""
    echo "Steam credentials are required for the streamer to download CS2."
    echo ""
    echo "WARNING: This account must NOT have Steam Guard / 2FA enabled."
    echo "  steamcmd cannot prompt for an auth code; the streamer will hang."
    echo "  Use a dedicated Steam account with 2FA disabled."
    echo ""
fi

while [ -z "$STEAM_USER_CURRENT" ]; do
    read -p "Steam username: " STEAM_USER_CURRENT
done
if [ "$STEAM_USER_CURRENT" != "$(grep -h "^STEAM_USER=" "$STEAM_SECRETS_FILE" | cut -d '=' -f2-)" ]; then
    update_env_var "$STEAM_SECRETS_FILE" "STEAM_USER" "$STEAM_USER_CURRENT"
    STEAM_SECRETS_CHANGED=1
fi

while [ -z "$STEAM_PASSWORD_CURRENT" ]; do
    read -s -p "Steam password: " STEAM_PASSWORD_CURRENT
    echo ""
done
if [ "$STEAM_PASSWORD_CURRENT" != "$(grep -h "^STEAM_PASSWORD=" "$STEAM_SECRETS_FILE" | cut -d '=' -f2-)" ]; then
    update_env_var "$STEAM_SECRETS_FILE" "STEAM_PASSWORD" "$STEAM_PASSWORD_CURRENT"
    STEAM_SECRETS_CHANGED=1
fi

MEDIAMTX_OVERLAY="overlays/mediamtx"
MEDIAMTX_CONFIG="$MEDIAMTX_OVERLAY/mediamtx.env"

copy_config_or_secrets "$MEDIAMTX_OVERLAY" "$MEDIAMTX_OVERLAY"

GAME_STREAM_DOMAIN=$(grep -h "^GAME_STREAM_DOMAIN=" "$MEDIAMTX_CONFIG" | cut -d '=' -f2-)
if [ -z "$GAME_STREAM_DOMAIN" ] || [ "$GAME_STREAM_DOMAIN" = "hls.example.com" ]; then
    DEFAULT_HLS="hls.$WEB_DOMAIN"
    read -p "Enter the playback domain for game streams (default: $DEFAULT_HLS): " GAME_STREAM_DOMAIN
    GAME_STREAM_DOMAIN=${GAME_STREAM_DOMAIN:-$DEFAULT_HLS}
    if echo "$GAME_STREAM_DOMAIN" | grep -q ' '; then
        echo "ERROR: Invalid domain '$GAME_STREAM_DOMAIN'."
        exit 1
    fi
    update_env_var "$MEDIAMTX_CONFIG" "GAME_STREAM_DOMAIN" "$GAME_STREAM_DOMAIN"
fi

apply_overlay() {
    local overlay="$1"
    local description="$2"
    echo "$description..."
    set -o pipefail
    "$REPO_DIR/kustomize" build "$overlay" | output_redirect kubectl --kubeconfig=$KUBECONFIG apply -f -
    local status=$?
    set +o pipefail
    if [ $status -ne 0 ]; then
        echo ""
        echo "ERROR: $description failed (exit $status)"
        exit $status
    fi
}

case "$GPU_VENDOR" in
    nvidia) apply_overlay "overlays/nvidia" "Installing NVIDIA device plugin and connector" ;;
esac

apply_overlay "$MEDIAMTX_OVERLAY" "Deploying MediaMTX stream server"

if [ "$STEAM_SECRETS_CHANGED" -eq 1 ]; then
    apply_overlay "$SECRETS_OVERLAY" "Updating Steam credentials"
fi

MEDIAMTX_NODE=$(kubectl --kubeconfig=$KUBECONFIG get nodes --selector='5stack-mediamtx=true' -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | head -n1)
if [ -z "$MEDIAMTX_NODE" ]; then
    MEDIAMTX_NODE=$(kubectl --kubeconfig=$KUBECONFIG get nodes -o jsonpath='{.items[0].metadata.name}')
    kubectl --kubeconfig=$KUBECONFIG label node "$MEDIAMTX_NODE" 5stack-mediamtx=true --overwrite
fi

echo ""
echo "Game Streamer : Updated"
