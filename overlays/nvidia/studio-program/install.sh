#!/bin/sh
# Runs in a privileged init container with the host's PID namespace. Its
# termination message is what the api reads before it schedules a program on
# this node: "seccomp=installed apparmor=loaded|unavailable|absent", then the
# host's restrict_userns and restrict_unconfined sysctls (or absent).
# Hosts that restrict unprivileged user namespaces (Ubuntu 23.10+) need the
# userns rule, which only an AppArmor 4 parser takes; a 3.0 parser, as on
# Ubuntu 22.04 even with an HWE kernel that has the sysctl, rejects it and
# abi 4.0, so both are dropped where the host has no abi/4.0.
set -eu

ROOT="${HOST_ROOT:-}"
PROFILES="${PROFILES_DIR:-/profiles}"
SECCOMP="$ROOT/var/lib/kubelet/seccomp/profiles"

host() {
    nsenter -t 1 -m -- "$@"
}

host sh -c "mkdir -p '$SECCOMP' && cat > '$SECCOMP/.5stack-studio-program.json' && mv '$SECCOMP/.5stack-studio-program.json' '$SECCOMP/5stack-studio-program.json'" <"$PROFILES/seccomp.json"

apparmor=absent
if host test -d "$ROOT/sys/kernel/security/apparmor"; then
    apparmor=unavailable
    if host sh -c 'command -v apparmor_parser' >/dev/null 2>&1; then
        profile="$(mktemp)"
        if host test -e "$ROOT/etc/apparmor.d/abi/4.0"; then
            cat "$PROFILES/apparmor" >"$profile"
        else
            grep -v -e '^abi <abi/4.0>,$' -e '^  userns,$' "$PROFILES/apparmor" >"$profile"
        fi
        host sh -c "mkdir -p '$ROOT/etc/apparmor.d' && cat > '$ROOT/etc/apparmor.d/5stack-studio-program' && apparmor_parser -r -W '$ROOT/etc/apparmor.d/5stack-studio-program'" <"$profile"
        apparmor=loaded
    fi
fi

restriction() {
    host cat "$ROOT/proc/sys/kernel/apparmor_restrict_unprivileged_$1" 2>/dev/null || echo absent
}

echo "seccomp=installed apparmor=${apparmor} restrict_userns=$(restriction userns) restrict_unconfined=$(restriction unconfined)" |
    tee "${TERMINATION_LOG:-/dev/termination-log}"
