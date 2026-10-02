#!/bin/bash

# Installs the 5stack image-prune script and its systemd timer on the host.
# Idempotent: safe to re-run on every update. Settings, kept in
# .5stack-env.config:
#   IMAGE_PRUNE_ENABLED=false    turns the prune off and removes the timer
#   IMAGE_PRUNE_ON_CALENDAR=...  a systemd OnCalendar= value (default weekly)
# A setting passed on the command line instead is saved there, so the next
# update does not quietly undo it.
setup_image_prune() {
    if [ "$EUID" -ne 0 ]; then
        warn "skipping image prune timer setup (needs root)"
        return 0
    fi

    # update.sh also runs from machines that only hold a kubeconfig for a
    # remote cluster; there is nothing to prune on those.
    if ! command -v k3s >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
        warn "skipping image prune timer setup (no k3s or systemd on this host)"
        return 0
    fi

    save_image_prune_setting IMAGE_PRUNE_ENABLED

    if [ "$IMAGE_PRUNE_ENABLED" = false ]; then
        if [ -f /etc/systemd/system/5stack-image-prune.timer ]; then
            step "Removing 5stack image prune timer"
            systemctl disable --now 5stack-image-prune.timer >/dev/null 2>&1
            rm -f /etc/systemd/system/5stack-image-prune.service \
                /etc/systemd/system/5stack-image-prune.timer \
                /usr/local/bin/5stack-image-prune.sh
            systemctl daemon-reload
            ok "image prune turned off (IMAGE_PRUNE_ENABLED=false)"
        fi
        return 0
    fi

    step "Installing 5stack image prune timer"

    # Checked before it is written: a timer with an invalid OnCalendar= never
    # fires, so a typo would otherwise stop all pruning behind one warning.
    local on_calendar="${IMAGE_PRUNE_ON_CALENDAR:-weekly}"
    if ! systemd-analyze calendar "$on_calendar" >/dev/null 2>&1; then
        warn "IMAGE_PRUNE_ON_CALENDAR=$on_calendar is not a valid systemd calendar value, using weekly"
        on_calendar=weekly
    else
        save_image_prune_setting IMAGE_PRUNE_ON_CALENDAR
    fi

    install -m 0755 "$PANEL_DIR/utils/5stack-image-prune.sh" /usr/local/bin/5stack-image-prune.sh

    cat >/etc/systemd/system/5stack-image-prune.service <<'UNIT'
[Unit]
Description=5stack prune superseded container images
After=k3s.service k3s-agent.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/5stack-image-prune.sh
NoNewPrivileges=yes
UNIT

    cat >/etc/systemd/system/5stack-image-prune.timer <<EOF
[Unit]
Description=Run 5stack image prune

[Timer]
OnCalendar=$on_calendar
Persistent=true
RandomizedDelaySec=30min
Unit=5stack-image-prune.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    if systemctl enable --now 5stack-image-prune.timer >/dev/null 2>&1; then
        ok "image prune timer enabled (OnCalendar=$on_calendar)"
    else
        warn "could not enable 5stack-image-prune.timer (OnCalendar=$on_calendar)"
    fi
}

# Runs the prune once, 15 minutes after an update, so the images it replaced
# go now instead of at the next weekly run. This run also clears old versions
# of non-5stack images (see 5stack-image-prune.sh). The delay lets the new
# pods replace the old ones first; until then the old images are still in use
# and would be kept.
schedule_image_prune_after_update() {
    if [ "$EUID" -ne 0 ] || ! systemctl is-enabled --quiet 5stack-image-prune.timer 2>/dev/null; then
        return 0
    fi

    step "Scheduling post-update image prune"

    local unit=5stack-image-prune-after-update
    # A run still pending from an earlier update is replaced, not doubled up.
    systemctl stop "$unit.timer" "$unit.service" >/dev/null 2>&1
    systemctl reset-failed "$unit.timer" "$unit.service" >/dev/null 2>&1

    if systemd-run --quiet --unit="$unit" --on-active=15min \
        /usr/local/bin/5stack-image-prune.sh --after-update >/dev/null 2>&1; then
        ok "image prune runs in 15 minutes (journalctl -u $unit)"
    else
        warn "could not schedule the post-update image prune"
    fi
}

# Saves a setting given on the command line to .5stack-env.config. Quoted with
# %q so a calendar value with spaces survives being sourced back in.
save_image_prune_setting() {
    local key=$1
    [ -n "${!key}" ] || return 0

    local value
    value="$(printf '%q' "${!key}")"
    if ! grep -qxF "$key=$value" .5stack-env.config 2>/dev/null; then
        update_env_var .5stack-env.config "$key" "$value"
    fi
}
