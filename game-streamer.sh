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

PREVIOUS_GPU_VENDOR="${GPU_VENDOR:-}"
PREVIOUS_GPU_NODES="${GPU_NODES:-}"

case "$PREVIOUS_GPU_VENDOR" in
    nvidia) DEFAULT_VENDOR_CHOICE=1 ;;
    amd)    DEFAULT_VENDOR_CHOICE=2 ;;
    intel)  DEFAULT_VENDOR_CHOICE=3 ;;
    *)      DEFAULT_VENDOR_CHOICE=1 ;;
esac

interactive_menu VENDOR_INDEX \
    "Which GPU vendor will the streamer nodes use?" \
    $((DEFAULT_VENDOR_CHOICE - 1)) \
    "NVIDIA" \
    "AMD (not yet supported)" \
    "Intel (not yet supported)"

case "$VENDOR_INDEX" in
    0) GPU_VENDOR=nvidia ;;
    1)
        err "AMD GPUs are not supported yet."
        err "  Tracking issue: https://github.com/5stackgg/5stack-panel/issues/467"
        err "  Docs:           https://docs.5stack.gg/advanced/game-streaming/amd"
        exit 1
        ;;
    2)
        err "Intel GPUs are not supported yet."
        err "  Tracking issue: https://github.com/5stackgg/5stack-panel/issues/468"
        err "  Docs:           https://docs.5stack.gg/advanced/game-streaming/intel"
        exit 1
        ;;
esac

step "Discovering cluster nodes"
ALL_NODES=$(kubectl --kubeconfig=$KUBECONFIG get nodes -o jsonpath='{.items[*].metadata.name}')
ALL_NODES_ARR=()
for node in $ALL_NODES; do ALL_NODES_ARR+=("$node"); done

if [ ${#ALL_NODES_ARR[@]} -eq 0 ]; then
    err "no cluster nodes found via kubectl. Check KUBECONFIG=$KUBECONFIG."
    exit 1
fi

interactive_checklist GPU_NODES \
    "Select nodes that have GPUs:" \
    "$PREVIOUS_GPU_NODES" \
    "${ALL_NODES_ARR[@]}"

for node in $GPU_NODES; do
    if ! echo "$ALL_NODES" | tr ' ' '\n' | grep -qx "$node"; then
        err "node '$node' is not in this cluster."
        err "Available: $ALL_NODES"
        exit 1
    fi
done

step "Labeling GPU nodes"
for node in $ALL_NODES; do
    if echo " $GPU_NODES " | grep -q " $node "; then
        kubectl --kubeconfig=$KUBECONFIG label node "$node" nvidia-gpu=true 5stack-game-streamer=true --overwrite >/dev/null
        ok "$node: labeled as GPU node"
    elif echo " $PREVIOUS_GPU_NODES " | grep -q " $node "; then
        kubectl --kubeconfig=$KUBECONFIG label node "$node" nvidia-gpu- 5stack-game-streamer- >/dev/null 2>&1 || true
        warn "$node: GPU labels removed"
    fi
done

update_env_var ".5stack-env.config" "GPU_VENDOR" "$GPU_VENDOR"
update_env_var ".5stack-env.config" "GPU_NODES" "\"$GPU_NODES\""

if [ -z "$GPU_NODES" ]; then
    err "no GPU nodes selected; the streamer cannot run without a GPU node."
    exit 1
fi

step "Configuring Steam credentials"
SECRETS_OVERLAY="overlays/local-secrets"
STEAM_SECRETS_FILE="$SECRETS_OVERLAY/steam-secrets.env"

STEAM_USER_CURRENT=$(grep -h "^STEAM_USER=" "$STEAM_SECRETS_FILE" | cut -d '=' -f2-)
STEAM_PASSWORD_CURRENT=$(grep -h "^STEAM_PASSWORD=" "$STEAM_SECRETS_FILE" | cut -d '=' -f2-)

if [ -z "$STEAM_USER_CURRENT" ] || [ -z "$STEAM_PASSWORD_CURRENT" ]; then
    echo
    echo "Steam credentials are required for the streamer to download CS2."
    warn "This account must NOT have Steam Guard / 2FA enabled."
    warn "  steamcmd cannot prompt for an auth code; the streamer will hang."
    warn "  Use a dedicated Steam account with 2FA disabled."
    echo
fi

while [ -z "$STEAM_USER_CURRENT" ]; do
    read -p "Steam username: " STEAM_USER_CURRENT
done
if [ "$STEAM_USER_CURRENT" != "$(grep -h "^STEAM_USER=" "$STEAM_SECRETS_FILE" | cut -d '=' -f2-)" ]; then
    update_env_var "$STEAM_SECRETS_FILE" "STEAM_USER" "$STEAM_USER_CURRENT"
fi

while [ -z "$STEAM_PASSWORD_CURRENT" ]; do
    read -s -p "Steam password: " STEAM_PASSWORD_CURRENT
    echo ""
done
if [ "$STEAM_PASSWORD_CURRENT" != "$(grep -h "^STEAM_PASSWORD=" "$STEAM_SECRETS_FILE" | cut -d '=' -f2-)" ]; then
    update_env_var "$STEAM_SECRETS_FILE" "STEAM_PASSWORD" "$STEAM_PASSWORD_CURRENT"
fi

if [ -z "$GAME_STREAM_DOMAIN" ] || [ "$GAME_STREAM_DOMAIN" = "hls.example.com" ]; then
    DEFAULT_HLS="hls.$WEB_DOMAIN"
    read -p "Enter the playback domain for game streams (default: $DEFAULT_HLS): " GAME_STREAM_DOMAIN
    GAME_STREAM_DOMAIN=${GAME_STREAM_DOMAIN:-$DEFAULT_HLS}
    if echo "$GAME_STREAM_DOMAIN" | grep -q ' '; then
        err "Invalid domain '$GAME_STREAM_DOMAIN'."
        exit 1
    fi
    update_env_var "overlays/config/api-config.env" "GAME_STREAM_DOMAIN" "$GAME_STREAM_DOMAIN"
    update_env_var "overlays/mediamtx/mediamtx.env" "GAME_STREAM_DOMAIN" "$GAME_STREAM_DOMAIN"
fi

MEDIAMTX_NODE=$(kubectl --kubeconfig=$KUBECONFIG get nodes --selector='5stack-mediamtx=true' -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | head -n1)
if [ -z "$MEDIAMTX_NODE" ]; then
    # Pin MediaMTX to the panel controlplane node (same selector used by update.sh).
    MEDIAMTX_NODE=$(kubectl --kubeconfig=$KUBECONFIG get nodes --selector='node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}')
    if [ -z "$MEDIAMTX_NODE" ]; then
        err "no control-plane node found; cannot place MediaMTX."
        exit 1
    fi
    kubectl --kubeconfig=$KUBECONFIG label node "$MEDIAMTX_NODE" 5stack-mediamtx=true --overwrite >/dev/null
    ok "$MEDIAMTX_NODE: labeled 5stack-mediamtx=true"
fi

source update.sh "$@"

banner "Game Streamer : Updated"
