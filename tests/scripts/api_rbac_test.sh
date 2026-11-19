#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROLE="$TEST_ROOT/base/api/rbac/role.yaml"

# The verbs the api's Role grants on a core resource, sorted, one line.
verbs() {
    awk -v want="$1" '
        function flush() {
            if (core && (" " res " ") ~ (" " want " ") && !names) {
                out = out vb
            }
        }
        /^  - apiGroups:/ { flush(); section = "g"; core = 0; res = ""; vb = ""; names = 0; next }
        /^    resources:/ { section = "r"; next }
        /^    verbs:/ { section = "v"; next }
        /^    resourceNames:/ { section = "n"; names = 1; next }
        /^      - / {
            item = $2
            gsub(/[\047"]/, "", item)
            if (section == "g" && item == "") { core = 1 }
            if (section == "r") { res = res " " item }
            if (section == "v") { vb = vb " " item }
            next
        }
        END { flush(); print out }
    ' "$ROLE" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# A stream sent to Twitch reads its key from a Secret its Job owns, so the key
# is never in the Job spec. The api creates that Secret; Kubernetes deletes it
# with the Job.
test_the_api_creates_a_secret_for_a_job() {
    assert_eq "$(verbs secrets)" "create get list"
}

test_the_api_still_cannot_change_or_delete_a_secret() {
    assert_not_contains "$(verbs secrets)" "update"
    assert_not_contains "$(verbs secrets)" "patch"
    assert_not_contains "$(verbs secrets)" "delete"
}

run_tests
