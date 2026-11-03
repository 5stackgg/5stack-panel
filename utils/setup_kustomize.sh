#!/bin/bash

setup_kustomize() {
    # $PANEL_DIR, not $(dirname "$0"): when update.sh is sourced from
    # install.sh, $0 is still install.sh, and both depend on the caller's cwd.
    local dir="$PANEL_DIR"
    local version="5.8.3" os arch sum got work
    if [ -f "$dir/kustomize" ] && [ -x "$dir/kustomize" ]; then
        return 0
    fi

    echo "kustomize not found. Installing..."
    case "$(uname -s)" in
        Linux) os=linux ;;
        Darwin) os=darwin ;;
        *)
            echo "kustomize $version has no release for $(uname -s)" >&2
            return 1
            ;;
    esac
    case "$(uname -m)" in
        x86_64 | amd64) arch=amd64 ;;
        aarch64 | arm64) arch=arm64 ;;
        *)
            echo "kustomize $version has no release for $(uname -m)" >&2
            return 1
            ;;
    esac
    # The release's own archive, checked against the sums its checksums.txt
    # published. Kustomize's install script finds the release through GitHub's
    # API instead, which refuses after 60 anonymous requests an hour from one
    # address, as CI runners share theirs.
    case "${os}_${arch}" in
        linux_amd64) sum=cb9e31198d3f63b44848bd0afc4c8efc56e6cfef9c93a4a39a211940e6decd61 ;;
        linux_arm64) sum=9867b76482cfc6d25b546abc1d2b5a32bd137505aba640649b4b378f64f6d68f ;;
        darwin_amd64) sum=d08fb85846c3d977f0e2a66e7ff45f1b5264c294685e5e726e1a8bdfe0da8dee ;;
        darwin_arm64) sum=4cbb08e209d8fff47cd60bfb6407daaf5ee699f9b9295849a1065024fac2d1ef ;;
    esac

    work="$(mktemp -d)"
    if ! curl -fsSL -o "$work/kustomize.tar.gz" \
        "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${version}/kustomize_v${version}_${os}_${arch}.tar.gz"; then
        echo "Failed to download kustomize $version" >&2
        rm -rf "$work"
        return 1
    fi
    got="$( (sha256sum "$work/kustomize.tar.gz" 2>/dev/null || shasum -a 256 "$work/kustomize.tar.gz") | cut -d' ' -f1)"
    if [ "$got" != "$sum" ]; then
        echo "The kustomize $version download doesn't match its published sha256 ($got)" >&2
        rm -rf "$work"
        return 1
    fi
    if ! tar -xzf "$work/kustomize.tar.gz" -C "$work" kustomize || ! mv "$work/kustomize" "$dir/kustomize"; then
        echo "Could not unpack kustomize $version into $dir" >&2
        rm -rf "$work"
        return 1
    fi
    chmod +x "$dir/kustomize"
    rm -rf "$work"
}
