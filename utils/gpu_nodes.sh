#!/bin/bash

label_gpu_nodes() {
    local vendor="$1" all_nodes="$2" gpu_nodes="$3" previous_nodes="$4" integrated_nodes="$5"
    local node add remove output
    for node in $all_nodes; do
        if [[ " $gpu_nodes " == *" $node "* ]]; then
            add=(5stack-game-streamer=true)
            if [ "$vendor" = "amd" ]; then
                add+=(5stack-gpu-vendor=amd)
                # The API and the connector keep a node that still has nvidia-gpu on the NVIDIA path.
                remove=(nvidia-gpu-)
                if [[ " $integrated_nodes " == *" $node "* ]]; then
                    add+=(5stack-gpu-integrated=true)
                else
                    remove+=(5stack-gpu-integrated-)
                fi
            else
                add+=(nvidia-gpu=true)
                remove=(5stack-gpu-vendor- 5stack-gpu-integrated-)
            fi
            if ! output="$(kubectl --kubeconfig="$KUBECONFIG" label node "$node" "${add[@]}" "${remove[@]}" --overwrite 2>&1)"; then
                err "$node: $output"
                return 1
            fi
            ok "$node: labeled as GPU node"
        elif [[ " $previous_nodes " == *" $node "* ]]; then
            kubectl --kubeconfig="$KUBECONFIG" label node "$node" nvidia-gpu- 5stack-gpu-vendor- 5stack-gpu-integrated- 5stack-game-streamer- >/dev/null 2>&1 || true
            warn "$node: GPU labels removed"
        fi
    done
}
