#!/bin/bash

choose_node() {
    local nodes=("$@") answer i
    [ "${#nodes[@]}" -gt 0 ] || return 1
    for i in "${!nodes[@]}"; do
        echo "$((i + 1)). ${nodes[$i]}" >&2
    done
    while true; do
        read -r -p "Enter the number of the node: " answer || return 1
        if [[ "$answer" =~ ^[0-9]{1,9}$ ]] && ((10#$answer >= 1 && 10#$answer <= ${#nodes[@]})); then
            echo "${nodes[$((10#$answer - 1))]}"
            return 0
        fi
        echo "Enter a number from 1 to ${#nodes[@]}." >&2
    done
}
