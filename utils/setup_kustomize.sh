#!/bin/bash

setup_kustomize() {
    local dir
    dir="$(dirname "$0")"
    if ! [ -f "$dir/kustomize" ] || ! [ -x "$dir/kustomize" ]
    then
        echo "kustomize not found. Installing..."
        # Pin the installer to an immutable release tag rather than the moving
        # `master` branch, and download-then-run instead of piping the network
        # straight into bash. The installer itself checksum-verifies the
        # kustomize binary it fetches for the requested version.
        local version="5.5.0"
        local script
        script="$(mktemp)"
        if curl -fsSL "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/kustomize/v${version}/hack/install_kustomize.sh" -o "$script"; then
            bash "$script" "$version" "$dir"
        else
            echo "Failed to download kustomize installer" >&2
            rm -f "$script"
            return 1
        fi
        rm -f "$script"
    fi
}