#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# utils.sh reassigns SCRIPT_DIR to utils/, so keep our own copy of the repo root
PANEL_DIR="$SCRIPT_DIR"
source "$SCRIPT_DIR/utils/utils.sh" "$@"

CUSTOM_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kubeconfig)
            # flag consumed by setup-env.sh; skip it and its value
            shift 2
            continue
            ;;
        -*)
            ;;
        *)
            if [[ -z "$CUSTOM_DIR" ]]; then
                CUSTOM_DIR="$1"
            fi
            ;;
    esac
    shift
done

select_custom_dir() {
    local dirs=() dir index
    for dir in "$PANEL_DIR"/custom/*/; do
        [ -f "$dir/kustomization.yaml" ] || [ -f "$dir/kustomization.yml" ] || continue
        dirs+=("$(basename "$dir")")
    done

    if [ ${#dirs[@]} -eq 0 ]; then
        echo "Error: no custom directories found in ./custom."
        exit 1
    fi

    interactive_menu index "Select the custom resource to deploy:" 0 "${dirs[@]}"
    CUSTOM_DIR=${dirs[$index]}
    echo "Selected custom resource: $CUSTOM_DIR"
}

if [ -z "$CUSTOM_DIR" ]; then
    select_custom_dir
elif [ ! -d "$PANEL_DIR/custom/$CUSTOM_DIR" ]; then
    echo "Error: ./custom/$CUSTOM_DIR does not exist."
    exit 1
fi

NODE_NAME=""

get_all_nodes() {
    kubectl --kubeconfig=$KUBECONFIG get nodes -o jsonpath='{.items[*].metadata.name}'
}

select_node() {
    ALL_NODES=$(get_all_nodes)
    echo "Select the node to deploy the custom resource to:"
    IFS=' ' read -r -a NODE_ARRAY <<< "$ALL_NODES"
    for i in "${!NODE_ARRAY[@]}"; do
        echo "$((i+1)). ${NODE_ARRAY[$i]}"
    done
    read -p "Enter the number of the node: " NODE_INDEX
    NODE_NAME=${NODE_ARRAY[$((NODE_INDEX-1))]}
    echo "Selected node: $NODE_NAME"
}

add_node_selector() {
    kubectl --kubeconfig=$KUBECONFIG label node $NODE_NAME 5stack-$CUSTOM_DIR=true --overwrite
}

# The node label IS the memory: if a node is already labeled for this custom dir
# from a previous deploy, reuse it instead of prompting again.
EXISTING_NODE=$(kubectl --kubeconfig=$KUBECONFIG get nodes -l 5stack-$CUSTOM_DIR=true -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "$EXISTING_NODE" ]; then
    NODE_NAME=$EXISTING_NODE
    echo "Reusing node from a previous deploy: $NODE_NAME (labeled 5stack-$CUSTOM_DIR=true)"
    echo "To pick a different node: kubectl label node $NODE_NAME 5stack-$CUSTOM_DIR- && ./custom.sh $CUSTOM_DIR"
else
    select_node
    add_node_selector
fi

./kustomize build ./custom/$CUSTOM_DIR | kubectl --kubeconfig=$KUBECONFIG apply -f - --kubeconfig=$KUBECONFIG

echo "Custom resource deployed successfully"