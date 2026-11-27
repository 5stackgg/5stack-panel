#!/bin/sh
# Runs in a privileged init container with the host's PID namespace. Its
# termination message is what the api reads before it schedules a program on
# this node: "seccomp=installed apparmor=loaded|unavailable|absent".
# AppArmor 4 hosts that restrict unprivileged user namespaces (Ubuntu 23.10+)
# need the userns rule; older parsers reject it, and their kernels don't
# restrict, so it is dropped there.
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
        if host test -e "$ROOT/proc/sys/kernel/apparmor_restrict_unprivileged_userns"; then
            cat "$PROFILES/apparmor" >"$profile"
        else
            grep -v -e '^abi <abi/4.0>,$' -e '^  userns,$' "$PROFILES/apparmor" >"$profile"
        fi
        host sh -c "mkdir -p '$ROOT/etc/apparmor.d' && cat > '$ROOT/etc/apparmor.d/5stack-studio-program' && apparmor_parser -r -W '$ROOT/etc/apparmor.d/5stack-studio-program'" <"$profile"
        apparmor=loaded
    fi
fi

echo "seccomp=installed apparmor=${apparmor}" | tee "${TERMINATION_LOG:-/dev/termination-log}"
