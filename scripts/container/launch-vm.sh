#!/usr/bin/env bash
# NOTE: This is the container's GUEST LAUNCHER. It is invoked by
# entrypoint.sh (the container entrypoint) — do NOT run it directly on the
# host. The supported way to run this project is `sudo ./install-zd1200-docker.sh`
# (= docker compose up -d --build). See README.md.
set -u

work_dir="$(cd "$(dirname "$0")" && pwd)"
kernel="${KERNEL:-$work_dir/image/bzImage}"
rootfs="$work_dir/image/rootfs.ext2"
# No initramfs by default: like the physical appliance, the kernel mounts
# root=/dev/sda2 directly and runs the stock /sbin/init.  Set INITRD to a
# path (or "none", which is ignored) to boot an initramfs instead.
initrd="${INITRD-}"
if [ "$initrd" = "none" ]; then initrd=""; fi
synthetic_disk="$work_dir/synthetic-cf.img"
disk_image="${DISK_IMAGE:-$synthetic_disk}"
disk_format="${DISK_FORMAT:-raw}"
qemu_tmp="$work_dir/qemu-tmp"

if ! command -v qemu-system-i386 >/dev/null 2>&1; then
    echo "qemu-system-i386 is not installed. Install qemu-system-x86 and retry." >&2
    exit 1
fi

for required_file in "$kernel" "$rootfs"; do
    if [ ! -f "$required_file" ]; then
        echo "Missing required file: $required_file" >&2
        exit 1
    fi
done
if [ -n "$initrd" ] && [ ! -f "$initrd" ]; then
    echo "Missing required file: $initrd" >&2
    exit 1
fi

if [ "$disk_image" = "$synthetic_disk" ] && [ ! -f "$synthetic_disk" ]; then
    python3 "$work_dir/build-synthetic-cf.py"
fi
if [ ! -f "$disk_image" ]; then
    echo "Missing disk image: $disk_image" >&2
    exit 1
fi

mkdir -p "$qemu_tmp"
export TMPDIR="$qemu_tmp"

debug_args=()
if [ "${DEBUG:-0}" = "1" ]; then
    gdb_port="${GDB_PORT:-1234}"
    debug_args+=( -S -gdb "tcp::${gdb_port}" )
    echo "QEMU paused; connect GDB to localhost:${gdb_port}" >&2
fi

# --- the guest's MAC is the container's own MAC (shared mode) -----------------
# With sharing the LAN must see exactly the identity the hypervisor allocated, so
# the QEMU NIC carries the container uplink's live MAC.  The live interface is
# the authority, not the stored ZD_MAC1: the container's MAC can be changed in
# Proxmox after install, and then the guest must follow it.
#
# Only when the container is actually configured to share (ZD_SHARE_UPLINK_MAC,
# written at install).  An older container upgraded in place keeps its own
# distinct guest MAC, and in macvtap (Docker) "eth0" is the host's own NIC and
# the guest deliberately uses a separate synthesised identity (ZD_CONTAINER_MAC
# = ZD_MAC1), not the host's MAC.
guest_mac=""
if [ "${NETWORK_MODE:-user}" = bridge ] && [ "${ZD_SHARE_UPLINK_MAC:-0}" = 1 ]; then
    host_if="${ZD_HOST_IF:-eth0}"
    [ -r "/sys/class/net/$host_if/address" ] \
        && guest_mac="$(cat "/sys/class/net/$host_if/address" 2>/dev/null)"
fi
[ -n "$guest_mac" ] || guest_mac="${ZD_MAC1:-}"
guest_mac="$(printf '%s' "$guest_mac" | tr '[:upper:]' '[:lower:]')"
if ! printf '%s' "$guest_mac" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
    echo "warning: no usable container MAC (got '${guest_mac:-}'); the guest keeps its stored board-data MAC" >&2
    guest_mac=""
fi

case "${NETWORK_MODE:-user}" in
    user)
        hostfwd_addr="${HOSTFWD_ADDR:-127.0.0.1}"
        extra=""
        if [ -n "${EXTRA_HOSTFWD:-}" ]; then
            for spec in ${EXTRA_HOSTFWD}; do
                extra="${extra},hostfwd=${spec}"
            done
        fi
        net_args=( -net "user,hostfwd=tcp:${hostfwd_addr}:${HTTP_PORT:-28080}-:80${extra}" )
        if [ -n "${HTTPS_PORT-28443}" ]; then
            net_args[1]="user,hostfwd=tcp:${hostfwd_addr}:${HTTP_PORT:-28080}-:80,hostfwd=tcp:${hostfwd_addr}:${HTTPS_PORT}-:443${extra}"
        fi
        ;;
    tap)
        tap_if="${TAP_IF:-tap-zd}"
        if [ ! -e "/sys/class/net/$tap_if" ]; then
            echo "Missing TAP interface: $tap_if" >&2
            exit 1
        fi
        net_args=( -net "tap,ifname=$tap_if,script=no,downscript=no" )
        ;;
    bridge)
        # LXC/CT mode: the container's uplink is cross-connected (by
        # zd1200-ct-net.sh, as zd1200-net.service) to the bridge br-zd through a
        # veth "wire".  Attach a tap to that bridge and hand it to QEMU.  The
        # uplink is deliberately NOT a bridge port: the guest wears the uplink's
        # MAC, and a bridge port's own MAC would shadow it.  Unlike macvtap this
        # is an ordinary bridge port: the guest is a real L2 neighbour of the
        # container, so the container (and the Proxmox host behind the bridge)
        # can reach it by IP, and no DHCP sniffing is needed.
        tap_if="${TAP_IF:-tap-zd}"
        bridge_if="${ZD_BRIDGE_IF:-br-zd}"
        if [ ! -e "/sys/class/net/$bridge_if" ]; then
            echo "Missing bridge interface: $bridge_if (is the LXC network setup run?)" >&2
            exit 1
        fi
        if [ ! -e "/sys/class/net/$tap_if" ]; then
            ip tuntap add dev "$tap_if" mode tap || exit 1
        fi
        ip link set "$tap_if" master "$bridge_if" || exit 1
        ip link set "$tap_if" up || exit 1
        # Do NOT enslave the uplink here: it stays out of the bridge so its MAC
        # cannot shadow the guest.  zd1200-ct-net.sh owns that topology.
        ip link set "$bridge_if" up 2>/dev/null || true
        net_args=( -net "tap,ifname=$tap_if,script=no,downscript=no" )
        ;;
    macvtap)
        # Inside the macvlan-networked container: create a macvtap in bridge
        # mode on eth0 so the guest shares the LAN L2 with the container
        # (DHCP and mDNS from the LAN reach the guest).  The kernel publishes
        # the tap char device at /sys/class/macvtap/tap<ifindex>/dev; the node
        # itself lands in the host's devtmpfs, so mknod it here.  Requires
        # NET_ADMIN and a device-cgroup rule for the tap major.
        #
        # network_mode: host makes this interface global to the host, so a second
        # ZD1200 container with the same name would find this one and overwrite
        # its MAC (the last container to start would then own the tap and the
        # other's guest would go dark).  ZD_MACVTAP_IF, written per instance by
        # install-zd1200-docker.sh, keeps each container's tap to itself.
        macvtap_if="${ZD_MACVTAP_IF:-mvt0}"
        macvtap_want="$(printf '%s' "${ZD_MAC1:-}" | tr 'A-Z' 'a-z')"
        # This interface lives in the host's network namespace (the container runs
        # with network_mode: host), so a container that was removed rather than
        # stopped cleanly leaves it behind, still carrying the old guest's MAC.
        # Reuse it only when it is already the interface this guest needs;
        # otherwise drop it and start again, so a stale tap cannot silently
        # shadow the guest.  entrypoint.sh removes it on a clean stop.
        if [ -e "/sys/class/net/$macvtap_if" ] && [ -n "$macvtap_want" ]; then
            macvtap_have="$(cat "/sys/class/net/$macvtap_if/address" 2>/dev/null || true)"
            if [ "$macvtap_have" != "$macvtap_want" ]; then
                echo "Replacing stale $macvtap_if ($macvtap_have -> $macvtap_want)"
                ip link del "$macvtap_if" 2>/dev/null || true
            fi
        fi
        if ! ip link show "$macvtap_if" >/dev/null 2>&1; then
            ip link add link eth0 name "$macvtap_if" type macvtap mode bridge
        fi
        # The kernel assigns the macvtap an auto-generated MAC, but the guest NIC
        # carries the board-data MAC1 ($ZD_MAC1).  The macvlan bridge routes
        # inbound frames by destination MAC, so the macvtap MAC MUST equal the
        # guest NIC MAC, otherwise the LAN's DHCP offer/ack (and any unicast to
        # the guest) is dropped before it reaches the guest — the guest never
        # completes DHCP.  Set it before the interface is brought up.
        if [ -n "$macvtap_want" ]; then
            ip link set "$macvtap_if" address "$macvtap_want"
        fi
        ip link set "$macvtap_if" up
        tap_idx="$(cat "/sys/class/net/$macvtap_if/ifindex")"
        dev_t="$(cat "/sys/class/macvtap/tap$tap_idx/dev" 2>/dev/null)"
        if [ -z "$dev_t" ]; then
            echo "Cannot find /sys/class/macvtap/tap$tap_idx/dev (macvtap driver not loaded?)" >&2
            exit 1
        fi
        tap_node="/dev/tap$tap_idx"
        if [ ! -e "$tap_node" ]; then
            mknod "$tap_node" c "${dev_t%%:*}" "${dev_t##*:}"
        fi
        exec 3<>"$tap_node"
        net_args=( -net "tap,fd=3" )
        ;;
    none)
        net_args=( -net none )
        nic_args=()
        ;;
    *)
        echo "NETWORK_MODE must be user, tap, bridge, macvtap or none" >&2
        exit 2
        ;;
esac

if [ "${NETWORK_MODE:-user}" != none ]; then
    # The synthetic board reports COB7402, so the stock network script loads
    # the igb2 driver.  QEMU's `igb` model emulates the Intel 82576 (PCI
    # 0x10C9) which igb2.ko supports, so the stock driver binds and brings up
    # eth0/br0 exactly like real hardware.
    if { [ "${NETWORK_MODE:-user}" = macvtap ] || [ "${NETWORK_MODE:-user}" = bridge ]; } \
       && [ -n "$guest_mac" ]; then
        # The QEMU NIC must carry the guest's base MAC (board-data MAC1, the one
        # the vendor v54bsp driver forces onto NIC[0]).  In bridge mode this is
        # the container's own uplink MAC -- the network setup cross-connects the
        # uplink instead of enslaving it, so the LAN sees exactly the identity
        # Proxmox allocated and the guest is not shadowed by a bridge port's own
        # FDB entry.  In macvtap mode it is the separate Docker identity.
        nic_args=( -net "nic,model=igb,macaddr=$guest_mac" )
    else
        nic_args=( -net nic,model=igb,macaddr=52:54:00:12:00:01 )
    fi
fi

snapshot_args=()
if [ "${SNAPSHOT:-1}" = "1" ]; then
    snapshot_args+=( -snapshot )
fi

# Reboot/upgrade loop: QEMU runs once per guest boot under qemu-once.py, which
# passes -no-reboot and reports a guest reset as exit 10 and a guest poweroff as
# exit 0.  Before each launch prepare-vm-disks.sh re-applies the kernel and
# rootfs patches when the guest upgraded (or the base/patch set changed); it
# no-ops otherwise.  A poweroff ends the loop and the container.

pacing_args=()
if [ "${PACE_GUEST:-0}" = "auto" ]; then
    pacing_args+=( -icount auto,sleep=on )
elif [[ "${PACE_GUEST:-0}" =~ ^shift=[0-9]+$ ]]; then
    pacing_args+=( -icount "${PACE_GUEST},sleep=on" )
fi

accel_args=()
# TCG speedups: a larger translation-block cache (TB cache) reduces re-translation
# churn for big workloads; set TCG_TB_SIZE in MiB (e.g. 1024) to raise it.
tcg_accel="tcg"
if [ -n "${TCG_TB_SIZE:-}" ]; then
    tcg_accel="tcg,tb-size=${TCG_TB_SIZE}"
fi
case "${ACCEL:-auto}" in
    kvm)
        accel_args+=( -accel kvm )
        ;;
    tcg)
        accel_args+=( -accel "$tcg_accel" )
        ;;
    auto)
        if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
            accel_args+=( -accel kvm )
        else
            accel_args+=( -accel "$tcg_accel" )
        fi
        ;;
    *)
        echo "ACCEL must be auto, kvm, or tcg" >&2
        exit 2
        ;;
esac
echo "QEMU accelerator: ${accel_args[1]}" >&2

initrd_args=()
if [ -n "$initrd" ]; then
    initrd_args=( -initrd "$initrd" )
fi

# The ZD1200 CLI login authenticates users through a BMC chip over IPMI (see
# the ipmi_cmdraw_ia / "BMC KCS Initialized" / GetUser/SetPasswd strings in the
# rootfs).  A physical ZD has that BMC; QEMU's '-machine pc' does not, so the
# login gets "No Response from BMC...Exiting".  Attach a software BMC
# (ipmi-bmc-sim) on the ISA KCS interface (default I/O 0xca2) so the guest's
# ipmi_si driver can reach it.  Set ZD_IPMI=0 to disable.
ipmi_args=()
if [ "${ZD_IPMI:-1}" != "0" ]; then
    ipmi_args+=( -device ipmi-bmc-sim,id=bmc0 )
    ipmi_args+=( -device isa-ipmi-kcs,id=isa0,bmc=bmc0 )
fi

# SeaBIOS writes its early debug output to the QEMU debug console port 0x402.
# Nothing claims that port by default, so those writes are dropped and
# firmware-level bring-up failures (before the kernel has a console) leave no
# trace.  Attach an isa-debugcon on 0x402 and append what it prints to a log
# next to the console log.  Set ZD_DEBUGCON=0 to disable.
debugcon_args=()
if [ "${ZD_DEBUGCON:-1}" != "0" ]; then
    debugcon_log="${ZD_DEBUGCON_LOG:-/tmp/zd1200-debugcon.log}"
    debugcon_args=( -chardev "file,id=dbgcon0,path=$debugcon_log,append=on"
                    -device isa-debugcon,iobase=0x402,chardev=dbgcon0 )
fi

# Interactive console (ttyS0).  The guest kernel boots with console=ttyS0 and
# /etc/inittab runs `/dev/console::respawn:/bin/login.sh` on it, so this is the
# SAME console the ZD1200 CLI login is presented on.  We forward it to a QEMU
# chardev that (1) appends every byte to $ZD_CONSOLE_LOG so the entrypoint's
# READY detection (grep on /tmp/zd1200-console.log) and `docker exec … tail -f`
# keep working, and (2) serves an interactive socket so you can attach to the
# login prompt.  Set ZD_CONSOLE=0 for the old -nographic behaviour (console ->
# stdio -> the entrypoint's log only, not interactive).
console_args=()
if [ "${ZD_CONSOLE:-1}" != "0" ]; then
    # QEMU's socket chardev answers exactly one client, and this QEMU has no
    # option to raise that.  The LXC flavour therefore puts the chardev on a
    # private path (ZD_CONSOLE_QEMU_SOCK) owned by the console bridge, which
    # in turn serves the public ZD_CONSOLE_SOCK that attach-console.py uses.
    # Docker sets neither, so it binds ZD_CONSOLE_SOCK directly as before.
    console_sock="${ZD_CONSOLE_QEMU_SOCK:-${ZD_CONSOLE_SOCK:-/tmp/zd1200-console.sock}}"
    console_log="${ZD_CONSOLE_LOG:-/tmp/zd1200-console.log}"
    # 'path=' for a unix socket (default); 'host='/'port=' for a TCP listener
    # when ZD_CONSOLE_SOCK looks like host:port (e.g. 127.0.0.1:5555).
    if [[ "$console_sock" == *":"* && "$console_sock" != *"/"* ]]; then
        _host="${console_sock%%:*}"; _port="${console_sock##*:}"
        _chardev="socket,id=con0,host=$_host,port=$_port"
    else
        _chardev="socket,id=con0,path=$console_sock"
    fi
    # wait=off: QEMU must not block booting until a console client attaches.
    _chardev="$_chardev,server=on,wait=off,logfile=$console_log,logappend=on"
    console_args=( -display none -chardev "$_chardev" -serial chardev:con0 )
else
    console_args=( -nographic )
fi

# Container lifecycle control: a second serial port (ttyS1) is a private,
# non-networked channel.  The entrypoint writes "reboot" on it when the
# container is asked to stop; an in-guest init hook runs the stock reboot path,
# which unmounts and flushes /writable before QEMU resets.  Set
# ZD_CONTAINER_CONTROL=0 to disable (then stops fall back to killing QEMU).
control_args=()
control_sock="${ZD_CONTROL_SOCK:-/tmp/zd1200-control.sock}"
if [ "${ZD_CONTAINER_CONTROL:-1}" != "0" ]; then
    control_args=( -chardev "socket,id=ctl0,path=$control_sock,server=on,wait=off"
                   -serial chardev:ctl0 )
fi

# The CF is on QEMU's AHCI controller, not the PIIX IDE controller, so the guest
# enumerates it as /dev/sda (the vendor kernel's libata/ahci/sd drivers are built
# in).  This matters: the firmware upgrade's own menu.lst template uses
# root=/dev/sda2|sda3, so the disk naming has to match for a menu rewrite to
# stay bootable.
qemu_args=(
    -name zd1200-vm
    "${accel_args[@]}"
    # ACPI on.  It is what lets the guest enumerate a second vCPU, and the
    # vendor kernel's watchdog cadence assumes two: nar5520_wdt_init() starts one
    # V54_watchdog thread per online CPU and the loop then sleeps
    # HZ*TIMEOUTTRG*(cpu_count/NUM_GCPUS) with NUM_GCPUS == 2.  With one CPU
    # that expression is 0, schedule_timeout(0) spins, the userspace watchdog
    # counter collapses instantly and nar5520_wdt_thread() sits in its
    # u-watchdog-timeout block (the only writer of the '9' kflag).
    # The cob7402 board itself has no ACPI, but the emulated box needs the CPU
    # table ACPI provides.  Set ZD_MACHINE to override (e.g. pc,acpi=off).
    -machine "${ZD_MACHINE:-pc}"
    # n270: ZD1200's CPU is a similar ATOM E3800 series.
    -cpu "${CPU_MODEL:-n270}"
    -m "${MEMORY_MB:-2048}"
    # Two vCPUs; see the -machine comment above (NUM_GCPUS == 2 in the driver).
    -smp "${ZD_SMP:-2}"
    "${initrd_args[@]}"
    -device ich9-ahci,id=ahci
    -drive "file=$disk_image,format=$disk_format,if=none,id=disk0,cache=${DISK_CACHE:-writeback}"
    -device "ide-hd,drive=disk0,bus=ahci.0"
    "${snapshot_args[@]}"
    "${net_args[@]}"
    "${nic_args[@]}"
    "${ipmi_args[@]}"
    "${debugcon_args[@]}"
    "${console_args[@]}"
    "${control_args[@]}"
    "${pacing_args[@]}"
    "${debug_args[@]}"
)

# --- one-shot configuration backup (--backup) --------------------------------
# A backup is staged into /writable exactly once, when the disk is built.  The
# guest applies it on its first boot and reports the outcome on its serial
# console, which QEMU appends to $console_log.  The container owns the
# "already applied" state: the guest's /writable can be reimaged by the vendor,
# so nothing in it is trusted.  On a reported success, record it in the state
# directory and retire the container's copy of the backup, so no later rebuild
# can re-stage it without the operator supplying it again.
retire_applied_backup() {
    local src="${ZD_BACKUP_IMAGE:-$work_dir/image/backup.bak}"
    local seed="${STATE_DIR:-$work_dir}/.backup-seeded"
    local clog="${console_log:-${ZD_CONSOLE_LOG:-/tmp/zd1200-console.log}}"
    [ -f "$src" ] || return 0
    [ -n "$clog" ] && [ -r "$clog" ] || return 0
    grep -qF 'ZD-CONFIG-RESTORED=applied' "$clog" 2>/dev/null || return 0
    grep -q '^restored=applied' "$seed" 2>/dev/null && return 0
    if [ -f "$seed" ]; then
        cat "$seed" > "$seed.tmp" 2>/dev/null
    else
        : > "$seed.tmp"
    fi
    printf 'restored=applied\nrestored_at=%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" >> "$seed.tmp" 2>/dev/null \
        && mv -f "$seed.tmp" "$seed" 2>/dev/null
    if mv -f "$src" "$src.staged" 2>/dev/null; then
        echo "configuration backup applied by the guest; retired $src" >&2
    else
        echo "configuration backup applied by the guest; $src is read-only, so the container seed marker is the guard" >&2
    fi
}

# The marker may already be in the log (a previous container start restored).
retire_applied_backup

# --- re-assert the container's MAC in the guest's board data, every launch ----
# The board data is what the vendor v54bsp driver reads at boot to force MAC1
# onto NIC[0], and the guest can rewrite it from inside: /bin/rbd.sh pipes a
# canned answer set to /usr/sbin/rbd, which calls bsp_set/bsp_commit and
# persists to the CF (that is the documented way to restore a dead unit's MAC
# onto a replacement).  A guest that did that would come back wearing a MAC the
# container does not have, silently losing the shared identity.
#
# So the container is the authority and rewrites the MAC fields before every
# QEMU launch, unconditionally -- but only in shared mode, where the guest's MAC
# must be the container's.  Without it (an upgraded older container, or Docker)
# the board data stays authoritative and a guest-side change is honoured, as
# before.
#
# --mac-only keeps everything else the records carry -- serial, model, customer
# -- so an rbd.sh serial change still survives; only the MACs are forced.  The
# 35-rbd-mac-guard.sh rootfs patch closes the same door from inside the guest so
# the change is refused rather than reverted at the next boot.
#
# Uses this script's own $disk_image, not the DISK_IMAGE env var: the script
# documents SYNTHETIC_DISK as the way to supply a disk, and under `set -u` an
# unset DISK_IMAGE would abort the launcher before QEMU ever starts.
assert_guest_mac() {
    [ "${ZD_SHARE_UPLINK_MAC:-0}" = 1 ] || return 0
    [ -n "$guest_mac" ] || return 0
    [ -f "$disk_image" ] || return 0          # built by prepare-vm-disks.sh
    local writer="$work_dir/write-boarddata.py"
    [ -f "$writer" ] || { echo "write-boarddata.py not found; cannot re-assert MAC" >&2; return 0; }
    if ! python3 "$writer" --disk "$disk_image" --mac "$guest_mac" \
         --platform "${ZD_PLATFORM:-1}" --mac-only; then
        # Not fatal: a disk without board data (e.g. a build still in progress)
        # boots on whatever MAC it already has.  Loud enough to be visible.
        echo "warning: could not re-assert MAC $guest_mac in board data" >&2
        return 0
    fi
}

while :; do
    if [ "${ZD_REPREP:-1}" = "1" ] && [ -x "$work_dir/prepare-vm-disks.sh" ]; then
        prep_rc=0
        "$work_dir/prepare-vm-disks.sh" || prep_rc=$?
        if [ "$prep_rc" -ne 0 ]; then
            # 4: the saved GRUB entry is a rescue entry (prepare-vm-disks.sh has
            # already explained how to rebuild).  Do not boot the vendor restore
            # tool; propagate the status so the entrypoint stops the container
            # rather than restarting it.
            if [ "$prep_rc" -eq 4 ]; then
                echo "the saved GRUB entry is a rescue entry; not starting QEMU" >&2
            fi
            exit "$prep_rc"
        fi
    fi
    # Re-assert AFTER prepare-vm-disks, never before: prep rebuilds the disk and
    # writes board data from ZD_MAC1 when it takes that branch, which would
    # discard a write made first.  Still before every boot -- the guest may have
    # rewritten the records during the run that just ended, and the loop
    # relaunches QEMU on every guest reset.
    assert_guest_mac
    python3 "$work_dir/qemu-once.py" "${qemu_args[@]}"
    rc=$?
    # The guest prints ZD-CONFIG-RESTORED=applied just before it reboots for the
    # restore, so this is where a completed restore is observed.
    retire_applied_backup
    if [ "$rc" -ne 10 ]; then
        exit "$rc"
    fi
    # A guest reboot normally means "relaunch QEMU".  If the entrypoint asked
    # for an orderly stop, this reset is the tail of the guest's shutdown, so
    # exit cleanly instead of booting again.
    if [ -f "${STATE_DIR:-$work_dir}/.stop-after-reset" ]; then
        rm -f "${STATE_DIR:-$work_dir}/.stop-after-reset"
        echo "guest rebooted for an orderly stop; not relaunching QEMU" >&2
        exit 0
    fi
    echo "guest requested a reboot; relaunching QEMU" >&2
done
