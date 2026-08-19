#!/bin/bash

# Installs the 5stack image-prune script and its systemd timer on the host.
# Idempotent: safe to re-run on every update. The schedule honors the
# IMAGE_PRUNE_ON_CALENDAR env var (a systemd OnCalendar= value, default
# "weekly") so it can be tuned per-deployment without code changes.
setup_image_prune() {
    if [ "$EUID" -ne 0 ]; then
        warn "skipping image prune timer setup (needs root)"
        return 0
    fi

    step "Installing 5stack image prune timer"

    local util_dir
    util_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    install -m 0755 "$util_dir/5stack-image-prune.sh" /usr/local/bin/5stack-image-prune.sh

    cat >/etc/systemd/system/5stack-image-prune.service <<'UNIT'
[Unit]
Description=5stack prune superseded container images

[Service]
Type=oneshot
ExecStart=/usr/local/bin/5stack-image-prune.sh
NoNewPrivileges=yes
UNIT

    cat >/etc/systemd/system/5stack-image-prune.timer <<EOF
[Unit]
Description=Run 5stack image prune

[Timer]
OnCalendar=${IMAGE_PRUNE_ON_CALENDAR:-weekly}
Persistent=true
RandomizedDelaySec=30min
Unit=5stack-image-prune.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now 5stack-image-prune.timer >/dev/null 2>&1
    ok "image prune timer enabled (OnCalendar=${IMAGE_PRUNE_ON_CALENDAR:-weekly})"
}
