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
# Runs an --apply step and reports it as fixed or failed.
apply_step() {
    local description="$1"
    shift
    if "$@"; then
        fixed "$description"
    else
        fail "could not apply: $description"
    fi
}

# conf_value FILE KEY
# The KEY's value from the container's own section (snapshots follow it).
conf_value() {
    awk -v key="$2" '/^\[/ { exit } index($0, key ": ") == 1 { print substr($0, length(key) + 3); exit }' "$1"
}

# size_gb SIZE
# 128G -> 128, 2T -> 2048, 512M -> 0.
size_gb() {
    local size="$1" number unit
    number="${size%[KMGT]}"
    unit="${size#"$number"}"
    case "$number" in '' | *[!0-9]*) return ;; esac
    case "$unit" in
        T) echo $((number * 1024)) ;;
        G | "") echo "$number" ;;
        *) echo 0 ;;
    esac
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
# the first snapshot section starts. Prints how many it added.
add_lxc_lines() {
    local file="$1" missing tmp
    shift
    missing=$(missing_lines "$file" "$@")
    if [ -n "$missing" ]; then
        tmp=$(mktemp)
        # Blank lines are held back until the next line shows whether they
        # end the container's section.
        LINES="$missing" awk '
            !done && /^$/ { blanks = blanks "\n"; next }
            !done && /^\[/ { print ENVIRON["LINES"]; done = 1 }
            { printf "%s", blanks; blanks = ""; print }
            END { if (!done) print ENVIRON["LINES"]; printf "%s", blanks }
        ' "$file" >"$tmp"
        # Rewrite in place: /etc/pve is a cluster file system that does not
        # take renames over an existing file, and is read-only without quorum.
        if ! cat "$tmp" >"$file"; then
            rm -f "$tmp"
            return 1
        fi
        rm -f "$tmp"
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

    local arg
    for arg in nomodeset amdgpu.modeset=0 amdgpu.dpm=0; do
        if tr ' ' '\n' </proc/cmdline | grep -qx "$arg"; then
            fail "the kernel command line has $arg; remove it"
        fi
    done

    if [ "$VENDOR" = amd ]; then
        check_host_amd
    else
        check_host_nvidia
    fi
}

check_host_amd() {
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

NVIDIA_UNIT=/etc/systemd/system/5stack-nvidia-devices.service

check_host_nvidia() {
    local version
    version=$(head -1 /proc/driver/nvidia/version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
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
    local missing="" node
    for node in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-modeset; do
        [ -c "$node" ] || missing+=" $node"
    done
    if [ -z "$missing" ] && [ -f "$NVIDIA_UNIT" ]; then
        pass "device nodes present, and created at every boot"
    elif [ "$APPLY" = true ] && command -v nvidia-modprobe >/dev/null 2>&1; then
        apply_step "device nodes created, and at every boot ($NVIDIA_UNIT)" install_nvidia_unit
    elif [ -n "$missing" ]; then
        fail "missing device nodes:$missing (--apply creates them at every boot with nvidia-modprobe)"
    else
        warn "nothing creates the NVIDIA device nodes at boot, so a container that starts first misses them (--apply adds a unit)"
    fi
}

install_nvidia_unit() {
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
    systemctl daemon-reload && systemctl enable --now 5stack-nvidia-devices.service >/dev/null 2>&1
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
    governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
    if [ -z "$governor" ] || [ "$governor" = performance ]; then
        pass "CPU governor ${governor:-not exposed}"
    elif [ "$APPLY" = true ]; then
        apply_step "CPU governor set to performance, at every boot" install_governor_unit
    else
        warn "CPU governor is '$governor'; render pods drop frames on a ramping CPU (--apply sets performance at every boot)"
    fi
}

install_governor_unit() {
    cat >/etc/systemd/system/cpu-governor-performance.service <<'UNIT' || return 1
[Unit]
Description=Set the CPU frequency governor to performance for game streaming
After=sysinit.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$g"; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload && systemctl enable --now cpu-governor-performance.service >/dev/null 2>&1
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
    else
        pass "privileged container"
    fi

    local rootfs size gb storage
    rootfs=$(conf_value "$conf" rootfs)
    size=$(echo "$rootfs" | grep -oE 'size=[0-9]+[KMGT]?' | cut -d= -f2)
    gb=$(size_gb "$size")
    if [ -z "$gb" ]; then
        warn "could not read the root disk size from '$rootfs'"
    elif [ "$gb" -ge 120 ]; then
        pass "root disk ${size}"
    else
        fail "root disk is ${size}; the node setup needs 120 GB free (pct resize $CTID rootfs 128G)"
    fi

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
        backup_conf "$conf"
        apply_step "enabled nesting" pct set "$CTID" --features "$(features_with_nesting "$features")"
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
    elif [ "$APPLY" = true ]; then
        backup_conf "$conf"
        apply_step "added ${#missing[@]} LXC lines for k3s and the $VENDOR GPU" locked_add_lxc_lines "$conf" "${lines[@]}"
        RESTART_NEEDED=true
    else
        fail "${#missing[@]} LXC lines for k3s and the $VENDOR GPU are missing (--apply adds them):"
        for line in "${missing[@]}"; do
            hint "$line"
        done
    fi
}

BACKED_UP=false
backup_conf() {
    [ "$BACKED_UP" = true ] && return
    local backup
    backup="/root/5stack-lxc-$CTID.conf.$(date +%Y%m%d-%H%M%S)"
    cp "$1" "$backup" && BACKED_UP=true && info "backed up the container config to $backup"
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
    check_host_gpu
    check_host_kernel
    check_container

    echo
    if [ "$RESTART_NEEDED" = true ]; then
        echo "${C_WARN}Restart the container to apply its new settings: pct reboot $CTID${C_RESET}"
    fi
    if [ "$FAILS" -gt 0 ]; then
        echo "${C_ERR}$FAILS failed, $WARNS warnings${C_RESET}"
        [ "$APPLY" = false ] && echo "Run with --apply to fix what this script can, then run it again."
        exit 1
    fi
    echo "${C_OK}host and container $CTID ready ($WARNS warnings)${C_RESET}"
    echo "Next, inside the container: gpu-node-check.sh --apply, then the panel's node setup command."
}

# The tests source this file for its functions. Comparing BASH_SOURCE with $0
# cannot tell that apart from "curl ... | bash", where both differ.
if [ -z "${PROXMOX_GPU_LXC_LIB:-}" ]; then
    main "$@"
fi
