#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERSION="$(sed -n 's/^CF_NODE_VERSION="\(.*\)"$/\1/p' "$TEST_ROOT/utils/cloudflare_workers.sh")"

# A PATH of the tools cf_require_node may use and nothing else, so the
# machine's own Node.js can't answer for it, ahead of which go the stubs.
machine() {
    local system="$1" cpu="$2" tool path
    mkdir -p "$WORK_DIR/tools" "$WORK_DIR/stub" "$WORK_DIR/release"
    for tool in bash cat cp cut dirname mkdir mktemp rm mv find tar gzip sha256sum id; do
        if path="$(command -v "$tool")" && [ "${path#/}" != "$path" ]; then
            ln -sf "$path" "$WORK_DIR/tools/$tool"
        fi
    done
    cat >"$WORK_DIR/stub/uname" <<EOF
#!/bin/bash
case "\$1" in
    -s) echo "$system" ;;
    -m) echo "$cpu" ;;
esac
EOF
    # Serves the fake release in \$WORK_DIR/release by its file name, or fails
    # the way curl does when \$CURL_FAILS is set.
    cat >"$WORK_DIR/stub/curl" <<'EOF'
#!/bin/bash
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        http*) url="$1" ;;
    esac
    shift
done
echo "$url" >>"$WORK_DIR/curl-calls"
if [ -n "$CURL_FAILS" ]; then
    printf 'partial' >"$out"
    echo "curl: (6) Could not resolve host: nodejs.org" >&2
    exit 6
fi
cp "$WORK_DIR/release/${url##*/}" "$out" || exit 22
EOF
    chmod +x "$WORK_DIR/stub/uname" "$WORK_DIR/stub/curl"
}

# A Node.js of VERSION on the machine's PATH.
system_node() {
    cat >"$WORK_DIR/stub/node" <<EOF
#!/bin/bash
case "\$1" in
    --version) echo "v$1" ;;
    -p) echo "${1%%.*}" ;;
esac
EOF
    printf '#!/bin/bash\n' >"$WORK_DIR/stub/npx"
    chmod +x "$WORK_DIR/stub/node" "$WORK_DIR/stub/npx"
}

# A small stand-in for nodejs.org's tarball for ARCH; prints its sha256.
release() {
    local name="node-v$VERSION-linux-$1"
    mkdir -p "$WORK_DIR/build/$name/bin"
    cat >"$WORK_DIR/build/$name/bin/node" <<EOF
#!/bin/bash
case "\$1" in
    --version) echo "v$VERSION" ;;
    -p) echo "${VERSION%%.*}" ;;
esac
EOF
    printf '#!/bin/bash\n' >"$WORK_DIR/build/$name/bin/npx"
    chmod +x "$WORK_DIR/build/$name/bin/node" "$WORK_DIR/build/$name/bin/npx"
    tar -czf "$WORK_DIR/release/$name.tar.gz" -C "$WORK_DIR/build" "$name"
    sha256sum "$WORK_DIR/release/$name.tar.gz" | cut -d ' ' -f 1
}

# Runs cf_require_node with PIN as both pinned sums, caching in the test's own
# directory (or by HOME alone with NO_XDG), then says which node the rest of
# the script would run.
require() {
    (
        export PATH="$WORK_DIR/stub:$WORK_DIR/tools" PANEL_DIR="$WORK_DIR/panel" XDG_CACHE_HOME="$WORK_DIR/cache"
        if [ -n "$NO_XDG" ]; then
            unset XDG_CACHE_HOME
        fi
        # shellcheck source=utils/colors.sh
        source "$TEST_ROOT/utils/colors.sh"
        # shellcheck source=utils/cloudflare_workers.sh
        source "$TEST_ROOT/utils/cloudflare_workers.sh"
        CF_NODE_SHA256_X64="$PIN"
        CF_NODE_SHA256_ARM64="$PIN"
        cf_require_node
        echo "NODE $(command -v node) $(node --version)"
    )
}

cached() {
    echo "$WORK_DIR/cache/5stack/node-v$VERSION-linux-$1"
}

test_the_pinned_release_is_node_22_with_both_sums() {
    [[ "$VERSION" =~ ^22\.[0-9]+\.[0-9]+$ ]] || fail "not a Node.js 22 release: $VERSION"
    local sums
    sums="$(grep -cE '^CF_NODE_SHA256_(X64|ARM64)="[0-9a-f]{64}"$' "$TEST_ROOT/utils/cloudflare_workers.sh")"
    assert_eq "$sums" "2"
}

test_a_machine_with_node_22_keeps_it_and_fetches_nothing() {
    machine Linux x86_64
    system_node 22.11.0
    local out
    out="$(PIN="$(release x64)" require 2>&1)" || fail "it stopped: $out"

    assert_contains "$out" "NODE $WORK_DIR/stub/node v22.11.0"
    assert_not_contains "$out" "Fetching"
    [ ! -f "$WORK_DIR/curl-calls" ] || fail "it downloaded: $(cat "$WORK_DIR/curl-calls")"
}

test_node_20_fetches_the_pinned_release_and_runs_the_rest_on_it() {
    machine Linux x86_64
    system_node 20.18.0
    local out pin
    pin="$(release x64)"
    out="$(PIN="$pin" require 2>&1)" || fail "it stopped: $out"

    assert_eq "$(cat "$WORK_DIR/curl-calls")" "https://nodejs.org/dist/v$VERSION/node-v$VERSION-linux-x64.tar.gz"
    assert_contains "$out" "Fetching Node.js $VERSION for wrangler (once)"
    assert_contains "$out" "NODE $(cached x64)/bin/node v$VERSION"
    assert_eq "$(cat "$(cached x64)/.5stack-sha256")" "$pin"
}

test_no_node_fetches_the_arm64_release_on_an_arm_server() {
    machine Linux aarch64
    local out
    out="$(PIN="$(release arm64)" require 2>&1)" || fail "it stopped: $out"

    assert_eq "$(cat "$WORK_DIR/curl-calls")" "https://nodejs.org/dist/v$VERSION/node-v$VERSION-linux-arm64.tar.gz"
    assert_contains "$out" "NODE $(cached arm64)/bin/node v$VERSION"
}

test_a_download_that_does_not_match_its_sum_is_refused() {
    machine Linux x86_64
    release x64 >/dev/null
    local out status=0
    out="$(PIN="$(printf '0%.0s' {1..64})" require 2>&1)" || status=$?

    assert_eq "$status" "1"
    assert_contains "$out" "does not match the checksum nodejs.org publishes for it, so it was not used"
    assert_not_contains "$out" "NODE "
    [ ! -e "$(cached x64)" ] || fail "the refused release was kept"
    assert_eq "$(find "$WORK_DIR/cache/5stack" -mindepth 1 | wc -l | tr -d ' ')" "0"
}

test_a_verified_cache_is_used_without_downloading() {
    machine Linux x86_64
    local out pin
    pin="$(release x64)"
    PIN="$pin" require >/dev/null 2>&1 || fail "the first run stopped"
    rm -f "$WORK_DIR/curl-calls"

    out="$(PIN="$pin" require 2>&1)" || fail "it stopped: $out"

    [ ! -f "$WORK_DIR/curl-calls" ] || fail "it downloaded again: $(cat "$WORK_DIR/curl-calls")"
    assert_not_contains "$out" "Fetching"
    assert_contains "$out" "NODE $(cached x64)/bin/node v$VERSION"
}

test_a_cache_that_no_longer_verifies_is_fetched_again() {
    machine Linux x86_64
    local pin out
    pin="$(release x64)"
    PIN="$pin" require >/dev/null 2>&1 || fail "the first run stopped"
    rm -f "$WORK_DIR/curl-calls"
    echo "something else" >"$(cached x64)/.5stack-sha256"

    out="$(PIN="$pin" require 2>&1)" || fail "it stopped: $out"

    assert_eq "$(wc -l <"$WORK_DIR/curl-calls" | tr -d ' ')" "1"
    assert_eq "$(cat "$(cached x64)/.5stack-sha256")" "$pin"
}

test_a_download_that_fails_says_so_and_leaves_nothing_behind() {
    machine Linux x86_64
    local out status=0
    out="$(CURL_FAILS=1 PIN="$(release x64)" require 2>&1)" || status=$?

    assert_eq "$status" "1"
    assert_contains "$out" "Could not resolve host: nodejs.org"
    assert_contains "$out" "Could not download Node.js $VERSION from https://nodejs.org/dist/v$VERSION/node-v$VERSION-linux-x64.tar.gz."
    assert_contains "$out" "Check that this server can reach nodejs.org, then run this again."
    assert_eq "$(find "$WORK_DIR/cache/5stack" -mindepth 1 | wc -l | tr -d ' ')" "0"
}

# The service runs scripts as root with no HOME.
test_without_home_the_release_is_kept_under_the_passwd_home() {
    machine Linux x86_64
    cat >"$WORK_DIR/stub/getent" <<EOF
#!/bin/bash
[ "\$1 \$2" = "passwd $(id -u)" ] && echo "root:x:0:0:root:$WORK_DIR/roothome:/bin/bash"
EOF
    chmod +x "$WORK_DIR/stub/getent"
    local out
    out="$(unset HOME; NO_XDG=1 PIN="$(release x64)" require 2>&1)" || fail "it stopped: $out"

    assert_contains "$out" "NODE $WORK_DIR/roothome/.cache/5stack/node-v$VERSION-linux-x64/bin/node v$VERSION"
}

test_other_systems_keep_asking_for_node() {
    local out status
    machine Darwin arm64
    status=0
    out="$(PIN=x require 2>&1)" || status=$?
    assert_eq "$status" "1"
    assert_contains "$out" "Node.js is needed to run wrangler, Cloudflare's deploy tool."

    system_node 20.18.0
    status=0
    out="$(PIN=x require 2>&1)" || status=$?
    assert_eq "$status" "1"
    assert_contains "$out" "wrangler needs Node.js 22 or newer, and this machine has v20.18.0."

    rm -f "$WORK_DIR/stub/node" "$WORK_DIR/stub/npx"
    machine Linux riscv64
    status=0
    out="$(PIN=x require 2>&1)" || status=$?
    assert_eq "$status" "1"
    assert_contains "$out" "Node.js is needed to run wrangler, Cloudflare's deploy tool."
    [ ! -f "$WORK_DIR/curl-calls" ] || fail "it downloaded: $(cat "$WORK_DIR/curl-calls")"
}

run_tests
