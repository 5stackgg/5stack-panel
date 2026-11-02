#!/bin/bash
#
# Move this panel onto the 5Stack service: install the `5stack` agent and hand
# the checkout to `5stack adopt`.
#
#   sudo ./service.sh                         adopt this checkout in place
#   sudo ./service.sh --to QX4-71M            move this panel onto a new server
#   sudo ./service.sh --channel branch/<name> follow a branch build
#   sudo ./service.sh --binary ./5stack       install a build you copied over
#   sudo ./service.sh --allow-downgrade       install a signed build older than this one
#   sudo ./service.sh --remove                remove the agent again
#
# The checkout, its .env files and ./update.sh are left alone, so both paths
# keep working.
set -euo pipefail

PANEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/colors.sh
source "$PANEL_DIR/utils/colors.sh"

AGENT_BASE_URL="${AGENT_BASE_URL:-https://get.5stack.gg/agent}"
AGENT_INSTALL_DIR="${AGENT_INSTALL_DIR:-/usr/local/bin}"
AGENT_SIGNING_KEY="${AGENT_SIGNING_KEY:-$PANEL_DIR/utils/agent_signing_key.pem}"
K3S_SERVER_TOKEN="${K3S_SERVER_TOKEN:-/var/lib/rancher/k3s/server/token}"
K3S_KUBECONFIG="${K3S_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

AGENT="$AGENT_INSTALL_DIR/5stack"
CHANNEL="stable"
CHANNEL_SET=false
BINARY=""
BINARY_SET=false
ALLOW_DOWNGRADE=false
REMOVE=false
PASSTHROUGH=()

usage() {
    sed -n '3,14p' "$PANEL_DIR/service.sh" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --binary)
            [ $# -ge 2 ] || die "--binary needs a path"
            BINARY="$2"
            BINARY_SET=true
            shift 2
            ;;
        --binary=*)
            BINARY="${1#*=}"
            BINARY_SET=true
            shift
            ;;
        --allow-downgrade)
            ALLOW_DOWNGRADE=true
            shift
            ;;
        --channel)
            [ $# -ge 2 ] || die "--channel needs a name"
            CHANNEL="$2"
            CHANNEL_SET=true
            shift 2
            ;;
        --channel=*)
            CHANNEL="${1#*=}"
            CHANNEL_SET=true
            shift
            ;;
        --remove)
            REMOVE=true
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            PASSTHROUGH+=("$1")
            shift
            ;;
    esac
done

if [ "$BINARY_SET" = true ] && [ -z "$BINARY" ]; then
    die "--binary needs a path"
fi

agent_version() {
    local out
    if command -v timeout >/dev/null 2>&1; then
        out="$(timeout 10 "$1" version 2>/dev/null)" || return 1
    else
        out="$("$1" version 2>/dev/null)" || return 1
    fi
    out="$(printf '%s\n' "$out" | head -n 1 | tr -d '\r')"
    is_version "$out" || return 1
    printf '%s\n' "$out"
}

is_version() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.-]+)?$ ]]
}

version_older() {
    local a_core="${1%%-*}" b_core="${2%%-*}" a_pre="" b_pre=""
    [[ "$1" == *-* ]] && a_pre="${1#*-}"
    [[ "$2" == *-* ]] && b_pre="${2#*-}"
    if [ "$a_core" != "$b_core" ]; then
        [ "$(printf '%s\n%s\n' "$a_core" "$b_core" | sort -V | head -n 1)" = "$a_core" ]
        return
    fi
    if [ -z "$a_pre" ] || [ "$a_pre" = "$b_pre" ]; then
        return 1
    fi
    if [ -z "$b_pre" ]; then
        return 0
    fi
    [ "$(printf '%s\n%s\n' "$a_pre" "$b_pre" | sort -V | head -n 1)" = "$a_pre" ]
}

if [ "$(id -u)" -ne 0 ]; then
    die "Run it as root: sudo ./service.sh"
fi

if [ "$REMOVE" = true ]; then
    step "Removing the 5Stack agent"
    if [ -e "$AGENT" ]; then
        "$AGENT" leave --panel || die "5stack leave --panel failed. The agent is still installed; fix the error above and run this again."
    fi
    rm -f "$AGENT"
    ok "agent removed. ./update.sh and your .env files are unchanged."
    exit 0
fi

step "Checking this host"
ok "running as root"

if [ ! -f "$K3S_SERVER_TOKEN" ] || [ ! -f "$K3S_KUBECONFIG" ]; then
    die "This is not the k3s server for your panel ($K3S_SERVER_TOKEN or $K3S_KUBECONFIG is missing). Run service.sh on the panel host."
fi
ok "k3s server found"

OS="$(uname -s)"
if [ "$OS" != "Linux" ]; then
    die "The 5Stack agent runs on Linux only, not $OS."
fi

case "$(uname -m)" in
    x86_64 | amd64) ARCH=amd64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    *) die "The 5Stack agent has no build for $(uname -m). Supported: x86_64 and aarch64." ;;
esac
ok "linux · $ARCH"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [ -n "$BINARY" ]; then
    if [ ! -f "$BINARY" ]; then
        die "$BINARY does not exist."
    fi
    if ! agent_version "$BINARY" >/dev/null; then
        die "$BINARY does not run here or doesn't print its version. Use a linux/$ARCH build of the agent."
    fi
    SOURCE="$BINARY"
    warn "installing $BINARY without checking a signature"
else
    if ! command -v curl >/dev/null 2>&1; then
        die "curl is not installed. Install it and run this again."
    fi
    OPENSSL_VERSION="$(openssl version 2>/dev/null || true)"
    case "$OPENSSL_VERSION" in
        "OpenSSL 3."* | "OpenSSL 4."*) ;;
        *) die "OpenSSL 3 or newer is needed to check the agent's signature (found: ${OPENSSL_VERSION:-none})." ;;
    esac
    ok "curl · ${OPENSSL_VERSION%% (*}"

    if [ ! -f "$AGENT_SIGNING_KEY" ]; then
        die "No agent signing key is pinned in this checkout yet ($AGENT_SIGNING_KEY). Install a build you trust with --binary <path>."
    fi

    step "Downloading 5stack ($CHANNEL)"
    FILE="5stack-linux-$ARCH"
    URL="$AGENT_BASE_URL/$CHANNEL"
    for NAME in "$FILE" SHA256SUMS SHA256SUMS.sig; do
        if ! curl -fsSL "$URL/$NAME" -o "$TMP_DIR/$NAME"; then
            die "Could not download $URL/$NAME"
        fi
    done

    if ! VERIFY_OUTPUT="$(openssl pkeyutl -verify -pubin -inkey "$AGENT_SIGNING_KEY" -rawin \
        -in "$TMP_DIR/SHA256SUMS" -sigfile "$TMP_DIR/SHA256SUMS.sig" 2>&1)"; then
        die "The SHA256SUMS signature is not valid. Nothing was installed. (openssl: $(printf '%s\n' "$VERIFY_OUTPUT" | grep -v '^$' | tail -n 1))"
    fi
    ok "SHA256SUMS signature valid"

    tr -d '\r' <"$TMP_DIR/SHA256SUMS" >"$TMP_DIR/SHA256SUMS.txt"
    SIGNED_CHANNEL="$(awk '$1 == "channel" { print $2; exit }' "$TMP_DIR/SHA256SUMS.txt")"
    SIGNED_VERSION="$(awk '$1 == "version" { print $2; exit }' "$TMP_DIR/SHA256SUMS.txt")"
    if [ "$SIGNED_CHANNEL" != "$CHANNEL" ]; then
        die "The download is signed for channel '${SIGNED_CHANNEL:-none}', not '$CHANNEL'. Nothing was installed."
    fi
    if [ -z "$SIGNED_VERSION" ]; then
        die "The signed SHA256SUMS names no version. Nothing was installed."
    fi
    if ! is_version "$SIGNED_VERSION"; then
        die "The signed SHA256SUMS names version '$SIGNED_VERSION', which is not a version number. Nothing was installed."
    fi
    if [ "$ALLOW_DOWNGRADE" != true ] && [ -x "$AGENT" ]; then
        if INSTALLED_VERSION="$(agent_version "$AGENT")"; then
            if version_older "$SIGNED_VERSION" "$INSTALLED_VERSION"; then
                die "The download is $SIGNED_VERSION, older than the installed $INSTALLED_VERSION. Run with --allow-downgrade to install it anyway."
            fi
        else
            die "The installed agent at $AGENT did not report its version, so this can't confirm the download is newer. Run with --allow-downgrade to install it anyway."
        fi
    fi
    ok "5stack $SIGNED_VERSION · $CHANNEL"

    EXPECTED="$(awk -v f="$FILE" '$2 == f || $2 == "*" f { print $1; exit }' "$TMP_DIR/SHA256SUMS.txt")"
    ACTUAL="$(openssl dgst -sha256 -r "$TMP_DIR/$FILE" | awk '{ print $1 }')"
    if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ]; then
        die "The $FILE checksum does not match SHA256SUMS. Nothing was installed."
    fi
    ok "$FILE checksum matches"
    SOURCE="$TMP_DIR/$FILE"
fi

mkdir -p "$AGENT_INSTALL_DIR"
cp "$SOURCE" "$AGENT.new"
chmod 0755 "$AGENT.new"
mv -f "$AGENT.new" "$AGENT"
ok "installed $AGENT"

ADOPT_ARGS=(adopt --checkout "$PANEL_DIR")
if [ "$CHANNEL_SET" = true ]; then
    ADOPT_ARGS+=(--channel "$CHANNEL")
fi

rm -rf "$TMP_DIR"
trap - EXIT
exec "$AGENT" "${ADOPT_ARGS[@]}" ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
