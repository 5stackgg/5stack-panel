#!/bin/bash

# Sets up GPU nodes: prompts for the GPU vendor and which cluster nodes have
# GPUs, labels them (`nvidia-gpu=true` for NVIDIA, `5stack-gpu-vendor=amd` for
# AMD, plus `5stack-gpu-integrated=true` on an AMD APU), and runs update.sh,
# which deploys the NVIDIA device plugin once GPU_VENDOR=nvidia. Render pods for
# live streams, demo playback and highlights are spawned by the 5stack API on
# nodes carrying those labels.
#
# Intel (issue #468) is tracked but not yet supported.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_DIR/utils/utils.sh" "$@"
source "$REPO_DIR/utils/gpu_nodes.sh"

PREVIOUS_GPU_VENDOR="${GPU_VENDOR:-}"
PREVIOUS_GPU_NODES="${GPU_NODES:-}"
PREVIOUS_GPU_INTEGRATED_NODES="${GPU_INTEGRATED_NODES:-}"

case "$PREVIOUS_GPU_VENDOR" in
    nvidia) DEFAULT_VENDOR_CHOICE=1 ;;
    amd)    DEFAULT_VENDOR_CHOICE=2 ;;
    intel)  DEFAULT_VENDOR_CHOICE=3 ;;
    *)      DEFAULT_VENDOR_CHOICE=1 ;;
esac

interactive_menu VENDOR_INDEX \
    "Which GPU vendor do your GPU nodes use?" \
    $((DEFAULT_VENDOR_CHOICE - 1)) \
    "NVIDIA" \
    "AMD" \
    "Intel (not yet supported)"

case "$VENDOR_INDEX" in
    0) GPU_VENDOR=nvidia ;;
    1) GPU_VENDOR=amd ;;
    2)
        err "Intel GPUs are not supported yet."
        err "  Tracking issue: https://github.com/5stackgg/5stack-panel/issues/468"
        err "  Docs:           https://docs.5stack.gg/servers/gpu-nodes/intel"
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

GPU_INTEGRATED_NODES=""
if [ "$GPU_VENDOR" = "amd" ] && [ -n "$GPU_NODES" ]; then
    read -r -a GPU_NODES_ARR <<<"$GPU_NODES"
    interactive_checklist GPU_INTEGRATED_NODES \
        "Select nodes that should use the GPU integrated into their CPU (APU) instead of a discrete card. Leave nodes with a discrete Radeon card unticked:" \
        "$PREVIOUS_GPU_INTEGRATED_NODES" \
        "${GPU_NODES_ARR[@]}"
fi

step "Labeling GPU nodes"
label_gpu_nodes "$GPU_VENDOR" "$ALL_NODES" "$GPU_NODES" "$PREVIOUS_GPU_NODES" "$GPU_INTEGRATED_NODES" || exit 1

update_env_var ".5stack-env.config" "GPU_VENDOR" "$GPU_VENDOR"
update_env_var ".5stack-env.config" "GPU_NODES" "\"$GPU_NODES\""
update_env_var ".5stack-env.config" "GPU_INTEGRATED_NODES" "\"$GPU_INTEGRATED_NODES\""

if [ -z "$GPU_NODES" ]; then
    err "no GPU nodes selected; rendering cannot run without a GPU node."
    exit 1
fi

step "Configuring Steam credentials"
SECRETS_OVERLAY="overlays/local-secrets"
STEAM_SECRETS_FILE="$SECRETS_OVERLAY/steam-secrets.env"

STEAM_USER_CURRENT=$(grep -h "^STEAM_USER=" "$STEAM_SECRETS_FILE" | cut -d '=' -f2-)
STEAM_PASSWORD_CURRENT=$(grep -h "^STEAM_PASSWORD=" "$STEAM_SECRETS_FILE" | cut -d '=' -f2-)

if [ -z "$STEAM_USER_CURRENT" ] || [ -z "$STEAM_PASSWORD_CURRENT" ]; then
    echo
    echo "Steam credentials are required for the render pods to download CS2."
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

# Always asked, with the current value as the default -- the same shape as the
# GPU vendor and node prompts above, where re-running this script is how you
# change an answer.
#
# This used to be guarded by `[ "$GAME_STREAM_DOMAIN" = "hls.example.com" ]`,
# which could never be true. That placeholder lives in
# overlays/mediamtx/mediamtx.env.example, and setup-env.sh copies it to
# mediamtx.env when the file is missing -- but GAME_STREAM_DOMAIN is read from
# api-config.env, which setup-env.sh defaults to hls.$WEB_DOMAIN. The check was
# comparing against a placeholder from a file this variable never comes from,
# so the prompt never ran and the playback domain could not be changed here.
DEFAULT_HLS="${GAME_STREAM_DOMAIN:-hls.$WEB_DOMAIN}"
read -p "Enter the playback domain for game streams (default: $DEFAULT_HLS): " GAME_STREAM_DOMAIN_INPUT
GAME_STREAM_DOMAIN_INPUT="${GAME_STREAM_DOMAIN_INPUT:-$DEFAULT_HLS}"

if [ -z "$GAME_STREAM_DOMAIN_INPUT" ] || echo "$GAME_STREAM_DOMAIN_INPUT" | grep -q ' '; then
    err "Invalid domain '$GAME_STREAM_DOMAIN_INPUT'."
    exit 1
fi

if [ "$GAME_STREAM_DOMAIN_INPUT" != "$GAME_STREAM_DOMAIN" ]; then
    GAME_STREAM_DOMAIN="$GAME_STREAM_DOMAIN_INPUT"
    update_env_var "overlays/config/api-config.env" "GAME_STREAM_DOMAIN" "$GAME_STREAM_DOMAIN"
    # api-config.env is the source of truth; mediamtx.env is a mirror kustomize
    # reads as a replacement source. setup-env.sh syncs the two at startup,
    # which has already happened by now, so a change made here has to be
    # written through to both or mediamtx keeps serving the old host.
    update_env_var "overlays/mediamtx/mediamtx.env" "GAME_STREAM_DOMAIN" "$GAME_STREAM_DOMAIN"
    ok "playback domain set to $GAME_STREAM_DOMAIN"
fi

source "$REPO_DIR/update.sh" "$@"

banner "GPU Nodes : Updated"
