#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_URL="https://get.test/agent"

setup_host() {
    mkdir -p "$WORK_DIR/bin" "$WORK_DIR/srv" "$WORK_DIR/k3s" "$WORK_DIR/keys"
    touch "$WORK_DIR/k3s/token" "$WORK_DIR/k3s/k3s.yaml"

    cat >"$WORK_DIR/bin/id" <<'EOF'
#!/bin/bash
echo "${FAKE_UID:-0}"
EOF
    cat >"$WORK_DIR/bin/uname" <<'EOF'
#!/bin/bash
case "$1" in
    -s) echo "${FAKE_UNAME_S:-Linux}" ;;
    -m) echo "${FAKE_UNAME_M:-x86_64}" ;;
esac
EOF
    cat >"$WORK_DIR/bin/curl" <<'EOF'
#!/bin/bash
out=""
url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        -*) ;;
        *) url="$1" ;;
    esac
    shift
done
echo "$url" >>"$WORK_DIR/curl.log"
file="$WORK_DIR/srv/${url#https://get.test/agent/}"
[ -f "$file" ] || exit 22
cp "$file" "$out"
chmod 0644 "$out"
EOF
    chmod +x "$WORK_DIR/bin/id" "$WORK_DIR/bin/uname" "$WORK_DIR/bin/curl"

    cat >"$WORK_DIR/agent" <<'EOF'
#!/bin/bash
if [ "$1" = "version" ]; then
    echo "${FAKE_AGENT_VERSION:-1.0.0}"
    exit 0
fi
echo "$*" >>"$WORK_DIR/agent.log"
EOF
    chmod +x "$WORK_DIR/agent"

    openssl genpkey -algorithm ed25519 -out "$WORK_DIR/keys/release.pem" 2>/dev/null
    openssl pkey -in "$WORK_DIR/keys/release.pem" -pubout -out "$WORK_DIR/keys/release.pub" 2>/dev/null
    openssl genpkey -algorithm ed25519 -out "$WORK_DIR/keys/other.pem" 2>/dev/null
}

publish() {
    local channel="$1" arch="$2" key="${3:-release}" signed_channel="${4:-$1}" version="${5-1.0.0}"
    local dir="$WORK_DIR/srv/$channel"
    mkdir -p "$dir"
    cp "$WORK_DIR/agent" "$dir/5stack-linux-$arch"
    {
        printf 'channel %s\n' "$signed_channel"
        [ -z "$version" ] || printf 'version %s\n' "$version"
        printf '%s  %s\n' "$(openssl dgst -sha256 -r "$dir/5stack-linux-$arch" | awk '{ print $1 }')" "5stack-linux-$arch"
    } >"$dir/SHA256SUMS"
    openssl pkeyutl -sign -inkey "$WORK_DIR/keys/$key.pem" -rawin -in "$dir/SHA256SUMS" -out "$dir/SHA256SUMS.sig" 2>/dev/null
}

run_service() {
    PATH="$WORK_DIR/bin:$PATH" \
        AGENT_BASE_URL="$BASE_URL" \
        AGENT_INSTALL_DIR="$WORK_DIR/install" \
        AGENT_SIGNING_KEY="${SIGNING_KEY:-$WORK_DIR/keys/release.pub}" \
        K3S_SERVER_TOKEN="$WORK_DIR/k3s/token" \
        K3S_KUBECONFIG="$WORK_DIR/k3s/k3s.yaml" \
        bash "$TEST_ROOT/service.sh" "$@" >"$WORK_DIR/output" 2>&1
    STATUS=$?
}

agent_calls() {
    cat "$WORK_DIR/agent.log" 2>/dev/null
}

test_a_verified_agent_is_installed_and_adopts_the_checkout() {
    setup_host
    publish stable amd64
    run_service --to QX4-71M
    assert_eq "$STATUS" "0"
    cmp -s "$WORK_DIR/agent" "$WORK_DIR/install/5stack" || fail "installed agent differs from the published one"
    [ -x "$WORK_DIR/install/5stack" ] || fail "installed agent is not executable"
    assert_eq "$(agent_calls)" "adopt --checkout $TEST_ROOT --to QX4-71M"
    assert_contains "$(cat "$WORK_DIR/output")" "SHA256SUMS signature valid"
}

test_a_tampered_binary_is_not_installed() {
    setup_host
    publish stable amd64
    echo "echo owned" >>"$WORK_DIR/srv/stable/5stack-linux-amd64"
    run_service
    assert_eq "$STATUS" "1"
    [ ! -e "$WORK_DIR/install/5stack" ] || fail "a tampered agent was installed"
    assert_eq "$(agent_calls)" ""
    assert_contains "$(cat "$WORK_DIR/output")" "checksum does not match"
}

test_checksums_signed_by_another_key_are_refused() {
    setup_host
    publish stable amd64 other
    run_service
    assert_eq "$STATUS" "1"
    [ ! -e "$WORK_DIR/install/5stack" ] || fail "an agent signed by the wrong key was installed"
    assert_contains "$(cat "$WORK_DIR/output")" "signature is not valid"
}

test_checksums_signed_for_another_channel_are_refused() {
    setup_host
    publish stable amd64 release branch/feature-x
    run_service
    assert_eq "$STATUS" "1"
    [ ! -e "$WORK_DIR/install/5stack" ] || fail "a build signed for another channel was installed"
    assert_contains "$(cat "$WORK_DIR/output")" "signed for channel 'branch/feature-x'"
}

install_agent_reporting() {
    mkdir -p "$WORK_DIR/install"
    printf '%s\n' "$1" >"$WORK_DIR/reported-version"
    cat >"$WORK_DIR/install/5stack" <<'EOF'
#!/bin/bash
if [ "$1" = version ]; then
    cat "$WORK_DIR/reported-version"
    exit 0
fi
echo "installed $*" >>"$WORK_DIR/agent.log"
EOF
    chmod +x "$WORK_DIR/install/5stack"
    cp "$WORK_DIR/install/5stack" "$WORK_DIR/installed-before"
}

test_an_older_version_than_the_installed_agent_is_refused() {
    setup_host
    publish stable amd64 release stable 1.2.0
    install_agent_reporting 1.10.0
    run_service
    assert_eq "$STATUS" "1"
    assert_contains "$(cat "$WORK_DIR/output")" "older than the installed 1.10.0"
    assert_contains "$(cat "$WORK_DIR/output")" "--allow-downgrade"
    cmp -s "$WORK_DIR/installed-before" "$WORK_DIR/install/5stack" || fail "the installed agent was replaced"
    assert_eq "$(agent_calls)" ""
}

test_allow_downgrade_installs_an_older_signed_build() {
    setup_host
    publish stable amd64 release stable 1.2.0
    install_agent_reporting 1.10.0
    run_service --allow-downgrade
    assert_eq "$STATUS" "0"
    cmp -s "$WORK_DIR/agent" "$WORK_DIR/install/5stack" || fail "the signed build was not installed"
}

test_a_prerelease_is_older_than_its_release() {
    setup_host
    publish stable amd64 release stable 1.2.0-rc.1
    install_agent_reporting 1.2.0
    run_service
    assert_eq "$STATUS" "1"
    assert_contains "$(cat "$WORK_DIR/output")" "older than the installed 1.2.0"
}

test_a_release_upgrades_its_prerelease() {
    setup_host
    publish stable amd64 release stable 1.2.0
    install_agent_reporting 1.2.0-rc.1
    run_service
    assert_eq "$STATUS" "0"
    cmp -s "$WORK_DIR/agent" "$WORK_DIR/install/5stack" || fail "the release did not replace the prerelease"
}

test_an_unreadable_installed_version_is_refused() {
    setup_host
    publish stable amd64 release stable 1.0.0
    install_agent_reporting "5stack 9.9.9"
    run_service
    assert_eq "$STATUS" "1"
    assert_contains "$(cat "$WORK_DIR/output")" "did not report its version"
    cmp -s "$WORK_DIR/installed-before" "$WORK_DIR/install/5stack" || fail "the installed agent was replaced"
}

test_allow_downgrade_replaces_an_agent_with_an_unreadable_version() {
    setup_host
    publish stable amd64 release stable 1.0.0
    install_agent_reporting "5stack 9.9.9"
    run_service --allow-downgrade
    assert_eq "$STATUS" "0"
    cmp -s "$WORK_DIR/agent" "$WORK_DIR/install/5stack" || fail "the signed build was not installed"
}

test_a_signed_version_that_is_not_a_version_is_refused() {
    setup_host
    publish stable amd64 release stable latest
    run_service
    assert_eq "$STATUS" "1"
    assert_contains "$(cat "$WORK_DIR/output")" "not a version number"
    [ ! -e "$WORK_DIR/install/5stack" ] || fail "installed a build with a malformed version"
}

test_checksums_without_a_version_are_refused() {
    setup_host
    publish stable amd64 release stable ""
    run_service
    assert_eq "$STATUS" "1"
    assert_contains "$(cat "$WORK_DIR/output")" "names no version"
    [ ! -e "$WORK_DIR/install/5stack" ] || fail "installed a build with no signed version"
}

test_a_downloaded_agent_is_installed_executable() {
    setup_host
    publish stable amd64
    run_service
    assert_eq "$STATUS" "0"
    [ -x "$WORK_DIR/install/5stack" ] || fail "the installed agent is not executable"
    [ ! -e "$WORK_DIR/install/5stack.new" ] || fail "the temporary copy was left behind"
}

test_a_local_binary_that_does_not_run_is_refused() {
    setup_host
    install_agent_reporting 1.0.0
    printf 'not a program\n' >"$WORK_DIR/broken"
    run_service --binary "$WORK_DIR/broken"
    assert_eq "$STATUS" "1"
    assert_contains "$(cat "$WORK_DIR/output")" "linux/amd64 build"
    cmp -s "$WORK_DIR/installed-before" "$WORK_DIR/install/5stack" || fail "a broken binary replaced the agent"
}

test_an_empty_binary_path_is_refused() {
    setup_host
    publish stable amd64
    run_service --binary=
    assert_eq "$STATUS" "1"
    assert_contains "$(cat "$WORK_DIR/output")" "--binary needs a path"
    [ ! -e "$WORK_DIR/curl.log" ] || fail "fell back to downloading"
}

test_remove_runs_leave_even_when_the_agent_is_not_executable() {
    setup_host
    mkdir -p "$WORK_DIR/install"
    printf '#!/bin/bash\n' >"$WORK_DIR/install/5stack"
    chmod 0644 "$WORK_DIR/install/5stack"
    run_service --remove
    assert_eq "$STATUS" "1"
    [ -e "$WORK_DIR/install/5stack" ] || fail "agent deleted without running leave"
}

test_a_newer_version_upgrades_the_installed_agent() {
    setup_host
    publish stable amd64 release stable 1.10.0
    install_agent_reporting 1.2.0
    run_service
    assert_eq "$STATUS" "0"
    cmp -s "$WORK_DIR/agent" "$WORK_DIR/install/5stack" || fail "the newer build was not installed"
    assert_eq "$(agent_calls)" "adopt --checkout $TEST_ROOT"
}

test_an_unsupported_cpu_is_refused() {
    setup_host
    publish stable amd64
    FAKE_UNAME_M=riscv64 run_service
    assert_eq "$STATUS" "1"
    assert_contains "$(cat "$WORK_DIR/output")" "no build for riscv64"
    [ ! -s "$WORK_DIR/curl.log" ] || fail "downloaded before checking the cpu"
}

test_an_arm_host_downloads_the_arm_build() {
    setup_host
    publish stable arm64
    FAKE_UNAME_M=aarch64 run_service
    assert_eq "$STATUS" "0"
    assert_contains "$(cat "$WORK_DIR/curl.log")" "$BASE_URL/stable/5stack-linux-arm64"
}

test_a_host_without_the_k3s_server_is_refused() {
    setup_host
    publish stable amd64
    rm "$WORK_DIR/k3s/token"
    run_service
    assert_eq "$STATUS" "1"
    assert_contains "$(cat "$WORK_DIR/output")" "not the k3s server"
}

test_it_must_run_as_root() {
    setup_host
    publish stable amd64
    FAKE_UID=1000 run_service
    assert_eq "$STATUS" "1"
    assert_contains "$(cat "$WORK_DIR/output")" "sudo ./service.sh"
    [ ! -e "$WORK_DIR/install/5stack" ] || fail "installed without root"
}

test_a_local_binary_installs_without_downloading() {
    setup_host
    run_service --binary "$WORK_DIR/agent"
    assert_eq "$STATUS" "0"
    cmp -s "$WORK_DIR/agent" "$WORK_DIR/install/5stack" || fail "local binary was not installed"
    [ ! -e "$WORK_DIR/curl.log" ] || fail "curl ran for a local binary"
    assert_eq "$(agent_calls)" "adopt --checkout $TEST_ROOT"
    assert_contains "$(cat "$WORK_DIR/output")" "without checking a signature"
}

test_a_channel_picks_the_download_and_is_passed_to_adopt() {
    setup_host
    publish branch/feature-x amd64
    run_service --channel branch/feature-x
    assert_eq "$STATUS" "0"
    assert_contains "$(cat "$WORK_DIR/curl.log")" "$BASE_URL/branch/feature-x/5stack-linux-amd64"
    assert_eq "$(agent_calls)" "adopt --checkout $TEST_ROOT --channel branch/feature-x"
}

test_no_pinned_key_points_to_a_local_binary() {
    setup_host
    publish stable amd64
    SIGNING_KEY="$WORK_DIR/keys/missing.pub" run_service
    assert_eq "$STATUS" "1"
    assert_contains "$(cat "$WORK_DIR/output")" "--binary <path>"
    [ ! -e "$WORK_DIR/curl.log" ] || fail "downloaded with nothing to verify against"
}

test_remove_leaves_the_panel_and_deletes_the_agent() {
    setup_host
    mkdir -p "$WORK_DIR/install"
    cp "$WORK_DIR/agent" "$WORK_DIR/install/5stack"
    run_service --remove
    assert_eq "$STATUS" "0"
    assert_eq "$(agent_calls)" "leave --panel"
    [ ! -e "$WORK_DIR/install/5stack" ] || fail "agent still installed"
}

test_remove_keeps_the_agent_when_leave_fails() {
    setup_host
    mkdir -p "$WORK_DIR/install"
    printf '#!/bin/bash\nexit 3\n' >"$WORK_DIR/install/5stack"
    chmod +x "$WORK_DIR/install/5stack"
    run_service --remove
    assert_eq "$STATUS" "1"
    [ -e "$WORK_DIR/install/5stack" ] || fail "agent deleted although leave failed"
}

run_tests
