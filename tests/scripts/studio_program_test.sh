#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROGRAM="$TEST_ROOT/overlays/nvidia/studio-program"
BUSYBOX="busybox:1.38@sha256:a46257e06c82ad85242d0d38077d0a52d9896389ca60a1a59d3463db586e5fa4"

# render DIR: $WORK_DIR/rendered.json, the kustomization as one JSON list.
render() {
    kubectl kustomize "$1" >"$WORK_DIR/rendered.yaml" || fail "kubectl kustomize $1 failed"
    KUBECONFIG=/dev/null kubectl patch --local -o json --type merge -p '{}' -f "$WORK_DIR/rendered.yaml" |
        python3 -I -c 'import json, sys
decoder, text, items, at = json.JSONDecoder(), sys.stdin.read(), [], 0
while text[at:].strip():
    item, end = decoder.raw_decode(text[at:].lstrip())
    at = len(text) - len(text[at:].lstrip()) + end
    items.extend(item.get("items", [item]) if item.get("kind") == "List" else [item])
json.dump(items, sys.stdout)' >"$WORK_DIR/rendered.json" || fail "could not read $1 as JSON"
}

query() {
    python3 -I -c "import json, sys
items = json.load(open(sys.argv[1]))
$1" "$WORK_DIR/rendered.json"
}

needs_docker() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        return 0
    fi
    [ -z "${CI:-}" ] || fail "docker is required in CI"
    echo "skipped: no docker"
    return 1
}

# sandbox [DOCKER_ARGS...]: what Chromium's namespace sandbox asks for, as the
# program pod's user with every capability dropped.
sandbox() {
    docker run --rm --user 10001:10001 --cap-drop ALL --read-only "$@" "$BUSYBOX" \
        unshare -U -p -n -f -r sh -c 'chroot / true && echo SANDBOX-OK' 2>&1
}

test_the_program_service_account_has_no_roles() {
    render "$TEST_ROOT/base"
    assert_eq "$(query 'print([i.get("automountServiceAccountToken") for i in items if i["kind"] == "ServiceAccount" and i["metadata"]["name"] == "studio-program"])')" "[False]"
    assert_eq "$(query 'print([i["metadata"]["name"] for i in items if i["kind"] in ("RoleBinding", "ClusterRoleBinding") and any(s.get("name") == "studio-program" for s in i.get("subjects", []))])')" "[]"
}

test_the_api_reviews_tokens_and_creates_no_secrets() {
    render "$TEST_ROOT/base"
    rules='[r for i in items if i["kind"] in ("Role", "ClusterRole") and i["metadata"]["name"].startswith("server-creator") for r in i["rules"]]'
    assert_eq "$(query "print([r['verbs'] for r in $rules if 'tokenreviews' in r['resources']])")" "[['create']]"
    assert_eq "$(query "print([r for r in $rules if 'secrets' in r['resources'] and 'create' in r['verbs']])")" "[]"
    assert_eq "$(query "print([r for r in $rules if 'serviceaccounts/token' in r['resources']])")" "[]"
}

test_the_program_pod_reaches_only_dns_the_api_mediamtx_and_public_outputs() {
    render "$TEST_ROOT/base"
    query '
[policy] = [i for i in items if i["kind"] == "NetworkPolicy" and i["metadata"]["name"] == "studio-program"]
spec = policy["spec"]
assert spec["podSelector"]["matchLabels"] == {"app": "game-streamer", "role": "studio-program"}, spec["podSelector"]
assert spec["policyTypes"] == ["Ingress", "Egress"] and spec["ingress"] == [], spec
private = {"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16", "127.0.0.0/8", "10.42.0.0/16", "10.43.0.0/16"}
for rule in spec["egress"]:
    ports = {(p["protocol"], p["port"]) for p in rule["ports"]}
    for peer in rule["to"]:
        block = peer.get("ipBlock")
        if block is None:
            continue
        assert block["cidr"] == "0.0.0.0/0", block
        if ports <= {("UDP", 8890), ("UDP", 8189)}:
            continue
        assert ports <= {("TCP", 443), ("TCP", 1935)}, ports
        assert private <= set(block.get("except", [])), block
api = [r for r in spec["egress"] if any(p.get("podSelector", {}).get("matchLabels") == {"app": "api"} for p in r["to"])]
assert [p["port"] for r in api for p in r["ports"]] == [5585], api
dns = [r for r in spec["egress"] if any(p.get("podSelector", {}).get("matchLabels") == {"k8s-app": "kube-dns"} for p in r["to"])]
assert len(dns) == 1, dns
' || fail "the studio-program NetworkPolicy is wrong"
}

test_the_profiles_daemonset_runs_on_nvidia_nodes() {
    render "$TEST_ROOT/overlays/nvidia"
    query '
[ds] = [i for i in items if i["kind"] == "DaemonSet" and i["metadata"]["name"] == "studio-program-profiles"]
spec = ds["spec"]["template"]["spec"]
assert ds["metadata"]["namespace"] == "5stack"
assert spec["nodeSelector"] == {"nvidia-gpu": "true"}, spec["nodeSelector"]
assert spec["automountServiceAccountToken"] is False
[install] = spec["initContainers"]
assert install["securityContext"] == {"privileged": True}
[hold] = spec["containers"]
assert hold["securityContext"]["capabilities"] == {"drop": ["ALL"]} and "privileged" not in hold["securityContext"]
[volume] = [v for v in spec["volumes"] if v["name"] == "profiles"]
[config] = [i for i in items if i["kind"] == "ConfigMap" and i["metadata"]["name"] == volume["configMap"]["name"]]
assert sorted(config["data"]) == ["apparmor", "install.sh", "seccomp.json"], sorted(config["data"])
' || fail "the studio-program-profiles DaemonSet is wrong"
}

# Bumping the upstream profile means replacing upstream-default.json with
# moby/profiles' seccomp/default.json, updating this sum, and regenerating.
test_the_seccomp_profile_is_made_from_the_vendored_upstream() {
    assert_eq "$(sha256sum "$PROGRAM/upstream-default.json" | cut -d' ' -f1)" "3320527d4568265ac97a077609b1bfd4cfd0d789eeb9239b7e094b1526675406"
    python3 -I "$PROGRAM/make-seccomp.py" "$PROGRAM/upstream-default.json" >"$WORK_DIR/seccomp.json" || fail "make-seccomp.py failed"
    diff -u "$PROGRAM/seccomp.json" "$WORK_DIR/seccomp.json" || fail "seccomp.json is stale: rerun make-seccomp.py"
}

test_the_seccomp_profile_lets_only_the_sandbox_namespaces_through() {
    needs_docker || return 0
    assert_not_contains "$(sandbox)" "SANDBOX-OK"
    assert_contains "$(sandbox --security-opt "seccomp=$PROGRAM/seccomp.json")" "SANDBOX-OK"
    for flags in -m -u -i; do
        output="$(docker run --rm --user 10001:10001 --cap-drop ALL --security-opt "seccomp=$PROGRAM/seccomp.json" "$BUSYBOX" unshare -U -r "$flags" true 2>&1)" &&
            fail "unshare $flags passed: $output"
        assert_contains "$output" "Operation not permitted"
    done
}

# Ubuntu 23.10+ hands an unconfined or docker-default process's new user
# namespace no capabilities; only a profile with the userns rule escapes that.
test_the_apparmor_profile_lets_the_sandbox_make_user_namespaces() {
    needs_docker || return 0
    if [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" != "1" ] || ! command -v apparmor_parser >/dev/null 2>&1; then
        [ -z "${CI:-}" ] || fail "CI's runner should restrict unprivileged user namespaces"
        echo "skipped: this host does not restrict unprivileged user namespaces"
        return 0
    fi
    sed 's/5stack-studio-program/5stack-studio-program-nouserns/g; /^  userns,$/d' "$PROGRAM/apparmor" >"$WORK_DIR/nouserns"
    sudo apparmor_parser -r "$PROGRAM/apparmor" || fail "the profile does not load"
    sudo apparmor_parser -r "$WORK_DIR/nouserns" || fail "the userns-less profile does not load"
    seccomp="seccomp=$PROGRAM/seccomp.json"
    assert_not_contains "$(sandbox --security-opt "$seccomp" --security-opt apparmor=5stack-studio-program-nouserns)" "SANDBOX-OK"
    assert_contains "$(sandbox --security-opt "$seccomp" --security-opt apparmor=5stack-studio-program)" "SANDBOX-OK"
}

# fake_host [apparmor] [parser] [restricted]: a host for install.sh under
# $WORK_DIR/host, with nsenter running its command here.
# shellcheck disable=SC2016 # the stubs expand their own arguments
fake_host() {
    HOST="$WORK_DIR/host"
    mkdir -p "$HOST" "$WORK_DIR/bin"
    for part in "$@"; do
        case "$part" in
            apparmor) mkdir -p "$HOST/sys/kernel/security/apparmor" ;;
            restricted) mkdir -p "$HOST/proc/sys/kernel" && echo 1 >"$HOST/proc/sys/kernel/apparmor_restrict_unprivileged_userns" ;;
            parser) printf '#!/bin/sh\necho "$@" >>"%s/parser-calls"\n' "$WORK_DIR" >"$WORK_DIR/bin/apparmor_parser" && chmod +x "$WORK_DIR/bin/apparmor_parser" ;;
        esac
    done
    printf '#!/bin/sh\nwhile [ "$1" != "--" ]; do shift; done\nshift\nexec "$@"\n' >"$WORK_DIR/bin/nsenter"
    chmod +x "$WORK_DIR/bin/nsenter"
}

install_profiles() {
    PATH="$WORK_DIR/bin:/usr/bin:/bin" HOST_ROOT="$HOST" PROFILES_DIR="$PROGRAM" TERMINATION_LOG="$WORK_DIR/termination" \
        sh "$PROGRAM/install.sh" >"$WORK_DIR/install-output" 2>&1 || fail "install.sh failed: $(cat "$WORK_DIR/install-output")"
    cmp -s "$PROGRAM/seccomp.json" "$HOST/var/lib/kubelet/seccomp/profiles/5stack-studio-program.json" || fail "the seccomp profile was not installed"
}

test_install_reports_no_apparmor_where_the_host_has_none() {
    fake_host
    install_profiles
    assert_eq "$(cat "$WORK_DIR/termination")" "seccomp=installed apparmor=absent"
    [ ! -e "$HOST/etc/apparmor.d" ] || fail "wrote AppArmor policy to a host without AppArmor"
}

test_install_reports_apparmor_unavailable_without_a_parser() {
    fake_host apparmor
    install_profiles
    assert_eq "$(cat "$WORK_DIR/termination")" "seccomp=installed apparmor=unavailable"
}

test_install_loads_the_userns_rule_where_user_namespaces_are_restricted() {
    fake_host apparmor parser restricted
    install_profiles
    assert_eq "$(cat "$WORK_DIR/termination")" "seccomp=installed apparmor=loaded"
    cmp -s "$PROGRAM/apparmor" "$HOST/etc/apparmor.d/5stack-studio-program" || fail "the profile was not installed as is"
    assert_eq "$(cat "$WORK_DIR/parser-calls")" "-r -W $HOST/etc/apparmor.d/5stack-studio-program"
}

test_install_drops_the_userns_rule_for_older_parsers() {
    fake_host apparmor parser
    install_profiles
    assert_eq "$(cat "$WORK_DIR/termination")" "seccomp=installed apparmor=loaded"
    installed="$(cat "$HOST/etc/apparmor.d/5stack-studio-program")"
    assert_not_contains "$installed" "userns"
    assert_not_contains "$installed" "abi <abi/4.0>"
    assert_contains "$installed" "profile 5stack-studio-program"
}

run_tests
