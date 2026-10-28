#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

render_base() {
    kubectl kustomize "$TEST_ROOT/base" || fail "kubectl kustomize base failed"
}

# The controller only upgrades nodes a Plan selects, and k3s updates are an
# admin's call from the panel, so a Plan in the manifests would upgrade every
# install the moment update.sh applies it.
test_no_plan_ships_with_the_panel() {
    rendered="$(render_base)"
    assert_contains "$rendered" "name: plans.upgrade.cattle.io"
    assert_contains "$rendered" "image: rancher/system-upgrade-controller:v0.20.2"
    if grep -q '^kind: Plan$' <<<"$rendered"; then
        fail "base renders a Plan"
    fi
}

test_the_api_can_manage_plans() {
    assert_contains "$(render_base)" "name: server-creator-upgrades"
    role="$(cat "$TEST_ROOT/base/system-upgrade/api-role.yaml")"
    assert_contains "$role" "namespace: system-upgrade"
    assert_contains "$role" "'upgrade.cattle.io'"
    assert_contains "$role" "- plans"
    binding="$(cat "$TEST_ROOT/base/system-upgrade/api-role-binding.yaml")"
    assert_contains "$binding" "name: server-creator"
    assert_contains "$binding" "namespace: 5stack"
}

# Bumping the controller means replacing both files with a release's assets
# and updating these sums from its sha256sum-amd64.txt.
test_vendored_manifests_match_the_release() {
    cd "$TEST_ROOT/base/system-upgrade" || fail "no base/system-upgrade"
    assert_eq "$(sha256sum crd.yaml | cut -d' ' -f1)" "1fb061e0d8bf9534da0145e614a9e03ca376cd5d1adcca17d13cfa12e211c48c"
    assert_eq "$(sha256sum system-upgrade-controller.yaml | cut -d' ' -f1)" "fd474b662d1f2b74ab150d95b6482869e1fd1f27ceee54b13e94b92292097969"
}

run_tests
