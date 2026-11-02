#!/bin/bash

# Prepares a Proxmox host and one of its LXC containers to run a 5stack GPU
# node: k3s inside the container, rendering on the host's NVIDIA or AMD GPU.
# Run it as root on the Proxmox host. With --apply it also fixes what it can;
# it backs up the container's config first and never restarts the container.
#
#   proxmox-gpu-lxc.sh CTID [--apply] [--vendor nvidia|amd]
#
# Then, inside the container, run gpu-node/gpu-node-check.sh.
#
# Exit code: 0 when nothing failed, 1 when a check failed, 2 on bad usage.

CTID=""
APPLY=false
VENDOR=""
PVE_LXC_DIR="${PVE_LXC_DIR:-/etc/pve/lxc}"
BACKUP_DIR="${BACKUP_DIR:-/root}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
GOVERNOR_SCRIPT="${GOVERNOR_SCRIPT:-/usr/local/bin/5stack-cpu-governor.sh}"
CPU_SYSFS="${CPU_SYSFS:-/sys/devices/system/cpu}"
CPUFREQUTILS_DEFAULT="${CPUFREQUTILS_DEFAULT:-/etc/default/cpufrequtils}"
PROC_CMDLINE="${PROC_CMDLINE:-/proc/cmdline}"
NVIDIA_PROC_VERSION="${NVIDIA_PROC_VERSION:-/proc/driver/nvidia/version}"

# The node setup command stops unless / has this much free (df -BG): the
# panel's "Required disk space - fresh install" setting before CS2 is
# installed, "Required disk space - existing install" once it is. These are
# their defaults. The system, k3s and the render images need room on top.
REQUIRED_FREE_GB=120
REQUIRED_FREE_EXISTING_GB=60
SYSTEM_HEADROOM_GB=20
CS2_DIR=/opt/5stack/serverfiles/game/csgo

# The kernel modules k3s, flannel and kube-proxy load. A container cannot load
# modules, so the host loads them, now and at every boot.
K3S_MODULES="overlay br_netfilter nf_conntrack vxlan ip_tables iptable_nat iptable_filter iptable_mangle xt_conntrack xt_mark xt_comment nf_tables tun"
MODULES_FILE=/etc/modules-load.d/5stack-k3s.conf

if [ -t 1 ]; then
    C_RESET=$'\033[0m' C_STEP=$'\033[1;36m' C_OK=$'\033[0;32m' C_WARN=$'\033[1;33m' C_ERR=$'\033[0;31m'
else
    C_RESET='' C_STEP='' C_OK='' C_WARN='' C_ERR=''
fi

FAILS=0
WARNS=0
step() { echo; echo "${C_STEP}==> $1${C_RESET}"; }
pass() { echo "${C_OK}  [PASS] $1${C_RESET}"; }
info() { echo "  [INFO] $1"; }
warn() { WARNS=$((WARNS + 1)); echo "${C_WARN}  [WARN] $1${C_RESET}"; }
fail() { FAILS=$((FAILS + 1)); echo "${C_ERR}  [FAIL] $1${C_RESET}"; }
fixed() { echo "${C_OK}  [FIX ] $1${C_RESET}"; }
hint() { echo "         $1"; }

usage() {
    echo "usage: proxmox-gpu-lxc.sh CTID [--apply] [--vendor nvidia|amd]" >&2
    exit 2
}

# apply_step DESCRIPTION COMMAND...
# Runs an --apply step and reports it as fixed or failed, returning 1 when it
# failed.
apply_step() {
    local description="$1"
    shift
    if "$@"; then
        fixed "$description"
    else
        fail "could not apply: $description"
        return 1
    fi
}

# conf_value FILE KEY
# The KEY's value from the container's own section (snapshots follow it).
conf_value() {
    awk -v key="$2" '/^\[/ { exit } index($0, key ": ") == 1 { print substr($0, length(key) + 3); exit }' "$1"
}

# size_gb SIZE
# A Proxmox disk size in whole GiB, rounded down: 128G -> 128, 2T -> 2048,
# 131072M -> 128, 512M -> 0. Without a unit the size is in bytes, as
# pve-common's parse_size reads it.
size_gb() {
    local size="$1" number unit
    number="${size%[KMGT]}"
    unit="${size#"$number"}"
    case "$number" in
        '' | .* | *. | *.*.* | *[!0-9.]*) return ;;
    esac
    awk -v n="$number" -v unit="$unit" 'BEGIN {
        divisor["T"] = 1 / 1024; divisor["G"] = 1; divisor["M"] = 1024
        divisor["K"] = 1024 * 1024; divisor[""] = 1024 * 1024 * 1024
        printf "%d\n", n / divisor[unit]
    }'
}

# features_with_nesting FEATURES
# keyctl=1,fuse=1 -> keyctl=1,fuse=1,nesting=1, keeping every other feature.
features_with_nesting() {
    local feature out=""
    local IFS=,
    for feature in $1; do
        case "$feature" in nesting=*) continue ;; esac
        out+="${out:+,}$feature"
    done
    echo "${out:+$out,}nesting=1"
}

# lxc_lines VENDOR
# The raw LXC lines that let k3s run in the container and reach the GPU.
lxc_lines() {
    echo "lxc.apparmor.profile: unconfined"
    echo "lxc.cgroup2.devices.allow: a"
    echo "lxc.cap.drop: "
    echo "lxc.mount.auto: proc:rw sys:rw"
    echo "lxc.mount.entry: /dev/kmsg dev/kmsg none bind,optional,create=file"
    echo "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,optional,create=file"
    case "$1" in
        amd)
            echo "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir"
            echo "lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file"
            ;;
        nvidia)
            local node
            for node in /dev/nvidia[0-9]* /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-modeset; do
                case "$node" in '/dev/nvidia[0-9]*') node=/dev/nvidia0 ;; esac
                echo "lxc.mount.entry: $node ${node#/} none bind,optional,create=file"
            done
            echo "lxc.mount.entry: /dev/nvidia-caps dev/nvidia-caps none bind,optional,create=dir"
            ;;
    esac
}

# conf_has_line FILE LINE
# True when the container's own section has LINE. Proxmox rewrites the file on
# every change, so trailing spaces do not count.
conf_has_line() {
    LINE="$2" awk '
        function trim(s) { sub(/[ \t]+$/, "", s); return s }
        /^\[/ { exit }
        trim($0) == trim(ENVIRON["LINE"]) { found = 1; exit }
        END { exit !found }
    ' "$1"
}

# missing_lines FILE LINE...
# Prints the LINEs the container's own section lacks.
missing_lines() {
    local file="$1" line
    shift
    for line in "$@"; do
        conf_has_line "$file" "$line" || echo "$line"
    done
}

# add_lxc_lines FILE LINE...
# Adds the LINEs FILE lacks to the container's own section, which ends where
# the first snapshot section starts. FILE is either replaced whole or left
# as it was.
add_lxc_lines() {
    local file="$1" missing tmp before after added
    shift
    missing=$(missing_lines "$file" "$@") || return 1
    [ -n "$missing" ] || return 0

    # Written the way pve-common's file_set_contents writes a guest config:
    # a temporary file in the same directory, renamed over the old one, so a
    # failed write never leaves a cut-off config behind.
    tmp="$file.tmp.$$"
    rm -f "$tmp"
    # Blank lines are held back until the next line shows whether they end
    # the container's section.
    if ! ADD_LINES="$missing" awk '
        !done && /^$/ { blanks = blanks "\n"; next }
        !done && /^\[/ { print ENVIRON["ADD_LINES"]; done = 1 }
        { printf "%s", blanks; blanks = ""; print }
        END { if (!done) print ENVIRON["ADD_LINES"]; printf "%s", blanks }
    ' "$file" >"$tmp"; then
        hint "could not write $tmp; $file is unchanged"
        rm -f "$tmp"
        return 1
    fi

    # Every old line plus the new ones, or the result is not used.
    before=$(grep -c '' "$file")
    after=$(grep -c '' "$tmp")
    added=$(printf '%s\n' "$missing" | wc -l)
    if [ ! -s "$tmp" ] || [ "$after" -ne $((before + added)) ]; then
        hint "the new config came out wrong ($after lines, expected $((before + added))); $file is unchanged"
        rm -f "$tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$file"; then
        hint "could not rename $tmp over $file; $file is unchanged"
        rm -f "$tmp"
        return 1
    fi
}

# locked_add_lxc_lines FILE LINE...
# add_lxc_lines under the lock pct and backups take on the container's config.
locked_add_lxc_lines() {
    local lock="/run/lock/lxc/pve-config-$CTID.lock"
    mkdir -p "${lock%/*}"
    (
        flock -w 30 9 || exit 1
        add_lxc_lines "$@"
    ) 9>"$lock"
}

check_host_gpu() {
    local dev class driver pci
    local nvidia=() amd=()

    step "Host GPU"

    for dev in /sys/bus/pci/devices/*; do
        class=$(cat "$dev/class" 2>/dev/null)
        case "$class" in 0x0300* | 0x0302* | 0x0380*) ;; *) continue ;; esac
        case "$(cat "$dev/vendor" 2>/dev/null)" in
            0x10de) nvidia+=("$dev") ;;
            0x1002) amd+=("$dev") ;;
        esac
    done

    if [ -z "$VENDOR" ]; then
        if [ ${#nvidia[@]} -gt 0 ] && [ ${#amd[@]} -gt 0 ]; then
            fail "found both NVIDIA and AMD GPUs; pass --vendor nvidia or --vendor amd"
            return
        elif [ ${#nvidia[@]} -gt 0 ]; then
            VENDOR=nvidia
        elif [ ${#amd[@]} -gt 0 ]; then
            VENDOR=amd
        else
            fail "no NVIDIA or AMD GPU found on the PCI bus"
            return
        fi
    fi

    local devices=("${amd[@]}") expected=amdgpu
    [ "$VENDOR" = nvidia ] && devices=("${nvidia[@]}") expected=nvidia

    for dev in "${devices[@]}"; do
        pci=$(basename "$dev")
        driver=$(basename "$(readlink "$dev/driver" 2>/dev/null)" 2>/dev/null)
        if [ "$driver" = "$expected" ]; then
            pass "$pci bound to $driver"
        elif [ "$driver" = vfio-pci ]; then
            fail "$pci is bound to vfio-pci for VM passthrough; a container shares the host's driver instead"
            hint "Remove it from the vfio-pci ids (/etc/modprobe.d) and any VM's hostpci, then reboot."
        else
            fail "$pci is bound to '${driver:-nothing}', not $expected"
        fi
    done

    if [ "$VENDOR" = amd ]; then
        check_host_amd
    else
        check_host_nvidia
    fi
}

check_host_amd() {
    # These turn off what amdgpu needs to render. NVIDIA's driver does not
    # read them, so they are only checked on an AMD host.
    local arg
    for arg in nomodeset amdgpu.modeset=0 amdgpu.dpm=0; do
        if tr ' ' '\n' <"$PROC_CMDLINE" | grep -qx "$arg"; then
            fail "the kernel command line has $arg; remove it"
        fi
    done

    if ls /dev/dri/renderD* >/dev/null 2>&1; then
        pass "render nodes: $(cd /dev/dri && echo renderD*)"
    else
        fail "no /dev/dri/renderD* on the host"
    fi

    local log
    log=$(journalctl -k -b 0 --no-pager 2>/dev/null)
    if echo "$log" | grep -q "Direct firmware load for amdgpu/.* failed"; then
        fail "amdgpu firmware is missing: $(echo "$log" | grep -o "amdgpu/[^ ]*" | head -1)"
        hint "Proxmox ships GPU firmware in pve-firmware; update it ('apt install pve-firmware') and the kernel, then reboot."
    elif echo "$log" | grep -q "amdgpu.*Fatal error during GPU init"; then
        fail "amdgpu failed to start the GPU this boot; see 'journalctl -k -b | grep amdgpu'"
    else
        pass "no amdgpu firmware or init errors this boot"
    fi
}

NVIDIA_UNIT="$SYSTEMD_DIR/5stack-nvidia-devices.service"
NVIDIA_NODES="/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-modeset"

check_host_nvidia() {
    local version
    version=$(head -1 "$NVIDIA_PROC_VERSION" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    if [ -z "$version" ]; then
        fail "the NVIDIA driver is not loaded on the host"
        hint "Install it on the host with the proxmox-headers package and NVIDIA's .run installer, then reboot."
        return
    fi
    pass "NVIDIA driver $version; the container needs the same version's libraries (gpu-node-check.sh --apply installs them)"

    # The NVIDIA module creates no device nodes itself; they appear once
    # something opens the GPU. The container cannot create them, so the host
    # makes them at boot: nvidia-smi the per-GPU nodes and nvidiactl,
    # nvidia-modprobe the uvm and modeset ones.
    local missing
    missing=$(missing_nvidia_nodes)
    if [ -z "$missing" ] && [ -f "$NVIDIA_UNIT" ]; then
        pass "device nodes present, and created at every boot"
    elif [ "$APPLY" = true ] && command -v nvidia-modprobe >/dev/null 2>&1; then
        apply_step "device nodes created, and at every boot ($NVIDIA_UNIT)" install_nvidia_unit
    elif [ "$APPLY" = true ]; then
        if [ -n "$missing" ]; then
            fail "missing device nodes:$missing, and --apply cannot create them without nvidia-modprobe"
        else
            warn "nothing creates the NVIDIA device nodes at boot, and --apply cannot add the unit that does without nvidia-modprobe"
        fi
        hint "NVIDIA's .run installer installs nvidia-modprobe; install the driver with it, then run this again."
    elif [ -n "$missing" ]; then
        fail "missing device nodes:$missing (--apply creates them at every boot with nvidia-modprobe)"
    else
        warn "nothing creates the NVIDIA device nodes at boot, so a container that starts first misses them (--apply adds a unit)"
    fi
}

missing_nvidia_nodes() {
    local node
    for node in $NVIDIA_NODES; do
        [ -c "$node" ] || printf ' %s' "$node"
    done
}

install_nvidia_unit() {
    local missing
    cat >"$NVIDIA_UNIT" <<'UNIT' || return 1
[Unit]
Description=Create the NVIDIA device nodes for 5stack GPU containers
After=systemd-modules-load.service
Before=pve-guests.service

[Service]
Type=oneshot
ExecStart=-/usr/bin/nvidia-smi -L
ExecStart=-/usr/bin/nvidia-modprobe -c0
ExecStart=-/usr/bin/nvidia-modprobe -c0 -u
ExecStart=-/usr/bin/nvidia-modprobe -m
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    # restart, not enable --now, which leaves an active unit alone.
    systemctl daemon-reload &&
        systemctl enable 5stack-nvidia-devices.service >/dev/null 2>&1 &&
        systemctl restart 5stack-nvidia-devices.service >/dev/null 2>&1 || return 1
    missing=$(missing_nvidia_nodes)
    if [ -n "$missing" ]; then
        hint "still missing:$missing"
        return 1
    fi
}

write_modules_file() {
    # shellcheck disable=SC2086 # one module per line
    printf '%s\n' $K3S_MODULES >"$MODULES_FILE"
}

check_host_kernel() {
    step "Host kernel modules"

    local module missing=()
    for module in $K3S_MODULES; do
        [ -d "/sys/module/$module" ] || modinfo "$module" 2>/dev/null | grep -q '^filename:.*(builtin)' || missing+=("$module")
    done
    local persisted=true
    [ -f "$MODULES_FILE" ] || persisted=false

    if [ ${#missing[@]} -eq 0 ] && [ "$persisted" = true ]; then
        pass "k3s modules loaded, and at every boot"
    elif [ "$APPLY" = true ]; then
        apply_step "k3s modules load at every boot ($MODULES_FILE)" write_modules_file
        for module in "${missing[@]}"; do
            apply_step "loaded $module" modprobe "$module"
        done
    elif [ ${#missing[@]} -gt 0 ]; then
        fail "not loaded: ${missing[*]} (--apply loads them, and at every boot)"
    else
        warn "the k3s modules are loaded now but not at every boot (--apply writes $MODULES_FILE)"
    fi

    local governor
    governor=$(cat "$CPU_SYSFS/cpu0/cpufreq/scaling_governor" 2>/dev/null)
    if [ -z "$governor" ] || [ "$governor" = performance ]; then
        pass "CPU governor ${governor:-not exposed}"
    elif [ "$APPLY" = true ]; then
        apply_step "CPU governor set to performance, at every boot (5stack-cpu-governor.service)" install_governor_unit
    else
        warn "CPU governor is '$governor'; render pods drop frames on a ramping CPU (--apply sets performance at every boot)"
    fi
}

# The same script and unit the panel's CPU governor tuning installs on a
# node, so a machine never ends up with two of them, and the same change to
# cpufrequtils's settings, whose boot script would set its own governor.
install_governor_unit() {
    local unit="$SYSTEMD_DIR/5stack-cpu-governor.service" governor
    mkdir -p "${GOVERNOR_SCRIPT%/*}" || return 1
    cat >"$GOVERNOR_SCRIPT.5stack-new" <<'SCRIPT' || return 1
#!/bin/sh
for governor in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance > "$governor"
done
SCRIPT
    chmod 0755 "$GOVERNOR_SCRIPT.5stack-new" && mv -f "$GOVERNOR_SCRIPT.5stack-new" "$GOVERNOR_SCRIPT" || return 1
    cat >"$unit.5stack-new" <<UNIT || return 1
[Unit]
Description=Set the CPU governor to performance for game servers

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$GOVERNOR_SCRIPT

[Install]
WantedBy=multi-user.target
UNIT
    mv -f "$unit.5stack-new" "$unit" || return 1
    if [ -f "$CPUFREQUTILS_DEFAULT" ]; then
        { grep -v '^GOVERNOR=' "$CPUFREQUTILS_DEFAULT" || true; echo 'GOVERNOR="performance"'; } >"$CPUFREQUTILS_DEFAULT.5stack-new" &&
            mv -f "$CPUFREQUTILS_DEFAULT.5stack-new" "$CPUFREQUTILS_DEFAULT" || return 1
    fi
    # restart, not enable --now: --now leaves an active unit alone, and the
    # governor may have been changed since it ran.
    systemctl daemon-reload &&
        systemctl enable 5stack-cpu-governor.service >/dev/null 2>&1 &&
        systemctl restart 5stack-cpu-governor.service >/dev/null 2>&1 || return 1
    for governor in "$CPU_SYSFS"/cpu*/cpufreq/scaling_governor; do
        [ -f "$governor" ] || continue
        if [ "$(cat "$governor")" != performance ]; then
            hint "$governor is still $(cat "$governor")"
            return 1
        fi
    done
}

# container_free_gb
# GB free on / inside the container (df -BG, as the node setup reads it), or
# nothing while the container is not running.
container_free_gb() {
    pct status "$CTID" 2>/dev/null | grep -q 'status: running' || return 0
    pct exec "$CTID" -- df -BG / 2>/dev/null | awk 'NR == 2 { sub(/G$/, "", $4); print $4 }'
}

# container_has_cs2
# True when CS2 is installed in the running container, where the node setup
# looks for it.
container_has_cs2() {
    pct exec "$CTID" -- test -d "$CS2_DIR" 2>/dev/null
}

disk_settings_hint() {
    hint "The panel sets both minimums: \"Required disk space - fresh install\" ($REQUIRED_FREE_GB GB by default) and \"Required disk space - existing install\" ($REQUIRED_FREE_EXISTING_GB GB), under Settings, Application, Servers."
}

# check_disk ROOTFS
# The node setup needs REQUIRED_FREE_GB free on /, or REQUIRED_FREE_EXISTING_GB
# once CS2 is installed, so a running container is judged by its free space,
# and a stopped one by its size.
check_disk() {
    local rootfs="$1" size gb free want
    size=$(echo "$rootfs" | grep -oE 'size=[0-9.]+[KMGT]?' | cut -d= -f2)
    gb=$(size_gb "$size")
    if [ -z "$gb" ]; then
        warn "could not read the root disk size from '$rootfs'"
        return
    fi
    want=$((REQUIRED_FREE_GB + SYSTEM_HEADROOM_GB))
    free=$(container_free_gb)
    case "$free" in *[!0-9]*) free="" ;; esac

    if [ -n "$free" ]; then
        local need=$REQUIRED_FREE_GB when="before CS2 is installed"
        if container_has_cs2; then
            need=$REQUIRED_FREE_EXISTING_GB
            when="with CS2 already installed"
        fi
        if [ "$free" -ge "$need" ]; then
            pass "root disk $size, ${free} GB free ($when the node setup needs $need GB)"
        else
            fail "root disk $size has ${free} GB free; $when the node setup needs $need GB free"
            hint "Grow it: pct resize $CTID rootfs +$((need - free + SYSTEM_HEADROOM_GB))G"
            disk_settings_hint
        fi
    elif [ "$gb" -lt "$REQUIRED_FREE_GB" ]; then
        fail "root disk is $size; before CS2 is installed the node setup needs $REQUIRED_FREE_GB GB free on it"
        hint "Grow it: pct resize $CTID rootfs ${want}G"
        hint "If CS2 is already installed in it, start the container and run this again: $REQUIRED_FREE_EXISTING_GB GB free is then enough."
        disk_settings_hint
    elif [ "$gb" -lt "$want" ]; then
        warn "root disk is $size; the node setup needs $REQUIRED_FREE_GB GB free, which leaves little for the system (${want}G is safer)"
        hint "Start the container and run this again to check its free space."
    else
        pass "root disk $size (start the container to check its free space)"
    fi
}

# proc:rw is what lets the kubelet change kernel values, and the ones it sets
# are not namespaced, so they change the Proxmox host itself.
proc_rw_warning() {
    warn "lxc.mount.auto: proc:rw lets the kubelet set vm.overcommit_memory=1, kernel.panic=10 and kernel.panic_on_oops=1, which apply to the whole host"
    hint "The host then reboots 10 seconds after a kernel oops, taking every guest on it down."
    hint "On a host shared with other guests, decide whether that is acceptable before restarting the container."
}

check_container() {
    local conf="$PVE_LXC_DIR/$CTID.conf"

    step "Container $CTID"

    if [ ! -f "$conf" ]; then
        fail "no container $CTID ($conf)"
        return
    fi

    if [ "$(conf_value "$conf" unprivileged)" = 1 ]; then
        fail "the container is unprivileged; k3s needs a privileged container"
        hint "Back it up and restore it as privileged: vzdump $CTID, then pct restore with --unprivileged 0."
        # Past this point every hint says what --apply would change, and the
        # pre-flight has already refused --apply for this container.
        if [ "$APPLY" = true ] || [ "$APPLY_REFUSED" = true ]; then
            hint "--apply changes nothing in this container until it is privileged."
            return
        fi
    else
        pass "privileged container"
    fi

    local rootfs storage
    rootfs=$(conf_value "$conf" rootfs)
    check_disk "$rootfs"

    storage=${rootfs%%:*}
    if command -v pvesm >/dev/null 2>&1 && pvesm status 2>/dev/null | awk -v s="$storage" '$1 == s { print $2 }' | grep -qx zfspool; then
        local zfs
        zfs=$(zfs version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
        if [ -n "$zfs" ] && [ "$(printf '%s\n' 2.2 "$zfs" | sort -V | head -1)" != 2.2 ]; then
            fail "the root disk is on ZFS $zfs; containerd's overlayfs needs ZFS 2.2 or newer"
        fi
    fi

    local cores host_cpus
    cores=$(conf_value "$conf" cores)
    host_cpus=$(nproc --all)
    if [ -n "$cores" ] && [ "$cores" -lt "$host_cpus" ]; then
        warn "the container is limited to $cores of $host_cpus cores; the kubelet's static CPU manager can pin pods to cores it cannot use"
        hint "Remove the limit: pct set $CTID --delete cores"
    fi

    # A change to a running container waits in its pending section until the
    # next restart; pct config shows it, conf_value does not.
    local features pending
    features=$(conf_value "$conf" features)
    pending=$(pct config "$CTID" 2>/dev/null | sed -n 's/^features: //p')
    if [[ ",$features," == *",nesting=1,"* ]]; then
        pass "nesting enabled"
    elif [[ ",$pending," == *",nesting=1,"* ]]; then
        warn "nesting turns on at the next container restart"
        RESTART_NEEDED=true
    elif [ "$APPLY" = true ]; then
        backup_conf "$conf" || return
        apply_step "enabled nesting" pct set "$CTID" --features "$(features_with_nesting "$features")" &&
            RESTART_NEEDED=true
    else
        fail "nesting is off (--apply turns it on)"
    fi

    [ -z "$VENDOR" ] && return

    local lines=() line missing=()
    mapfile -t lines < <(lxc_lines "$VENDOR")
    mapfile -t missing < <(missing_lines "$conf" "${lines[@]}")
    if [ ${#missing[@]} -eq 0 ]; then
        pass "LXC settings for k3s and the $VENDOR GPU in place"
        return
    fi
    for line in "${missing[@]}"; do
        [ "$line" = "lxc.mount.auto: proc:rw sys:rw" ] && proc_rw_warning
    done
    if [ "$APPLY" = true ]; then
        backup_conf "$conf" || return
        apply_step "added ${#missing[@]} LXC lines for k3s and the $VENDOR GPU" locked_add_lxc_lines "$conf" "${lines[@]}" &&
            RESTART_NEEDED=true
    else
        fail "${#missing[@]} LXC lines for k3s and the $VENDOR GPU are missing (--apply adds them):"
        for line in "${missing[@]}"; do
            hint "$line"
        done
    fi
}

# backup_conf FILE
# Copies FILE to BACKUP_DIR once per run. --apply changes nothing in the
# container without a backup, so a failed copy fails the run.
BACKED_UP=false
backup_conf() {
    [ "$BACKED_UP" = true ] && return 0
    local backup
    backup="$BACKUP_DIR/5stack-lxc-$CTID.conf.$(date +%Y%m%d-%H%M%S)"
    if cp "$1" "$backup" 2>/dev/null && cmp -s "$1" "$backup"; then
        BACKED_UP=true
        info "backed up the container config to $backup"
        return 0
    fi
    fail "could not back up $1 to $backup, so --apply changes nothing in the container"
    return 1
}

# preflight_apply
# --apply changes the host only for a container it can then finish, so a
# missing or unprivileged container turns it off before any host step runs.
APPLY_REFUSED=false
preflight_apply() {
    local conf="$PVE_LXC_DIR/$CTID.conf"
    [ "$APPLY" = true ] || return 0
    if [ -f "$conf" ] && [ "$(conf_value "$conf" unprivileged)" != 1 ]; then
        return 0
    fi
    APPLY=false
    APPLY_REFUSED=true
    echo "${C_WARN}--apply changes nothing on the host or in container $CTID until the container exists and is privileged; only checking${C_RESET}"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --apply) APPLY=true ;;
            --vendor)
                VENDOR="$2"
                shift
                ;;
            -h | --help) usage ;;
            -*)
                echo "unknown option: $1" >&2
                usage
                ;;
            *) CTID="$1" ;;
        esac
        shift
    done

    case "$CTID" in '' | *[!0-9]*) usage ;; esac
    case "$VENDOR" in
        "" | nvidia | amd) ;;
        *)
            echo "--vendor must be nvidia or amd" >&2
            exit 2
            ;;
    esac
    if [ "$(id -u)" -ne 0 ] || ! command -v pct >/dev/null 2>&1; then
        echo "run this as root on the Proxmox host" >&2
        exit 2
    fi

    RESTART_NEEDED=false
    preflight_apply
    check_host_gpu
    check_host_kernel
    check_container

    echo
    if [ "$RESTART_NEEDED" = true ]; then
        echo "${C_WARN}Restart the container to apply its new settings: pct reboot $CTID${C_RESET}"
    fi
    if [ "$FAILS" -gt 0 ]; then
        echo "${C_ERR}$FAILS failed, $WARNS warnings${C_RESET}"
        [ "$APPLY" = false ] && [ "$APPLY_REFUSED" = false ] && echo "Run with --apply to fix what this script can, then run it again."
        exit 1
    fi
    echo "${C_OK}host and container $CTID ready ($WARNS warnings)${C_RESET}"
    echo "Next, inside the container: gpu-node-check.sh --apply, then join it from the panel's Game Server Nodes page."
}

# The tests source this file for its functions. Comparing BASH_SOURCE with $0
# cannot tell that apart from "curl ... | bash", where both differ.
if [ -z "${PROXMOX_GPU_LXC_LIB:-}" ]; then
    main "$@"
fi
