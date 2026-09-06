#!/usr/bin/env bash
# NOTE: This is the container's GUEST LAUNCHER. It is invoked by
# run-zd1200-web.sh (the container entrypoint) — do NOT run it directly on the
# host. The supported way to run this project is `sudo ./build-container.sh`
# (= docker compose up -d --build). See AGENTS.md and RUNBOOK.md.
set -u

work_dir="$(cd "$(dirname "$0")" && pwd)"
kernel="${KERNEL:-$work_dir/image/bzImage}"
rootfs="$work_dir/image/rootfs.ext2"
# No initramfs by default: like the physical appliance, the kernel mounts
# root=/dev/hda2 directly and runs the stock /sbin/init.  Set INITRD to a
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
    python3 "$work_dir/make-synthetic-cf.py"
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
    macvtap)
        # Inside the macvlan-networked container: create a macvtap in bridge
        # mode on eth0 so the guest shares the LAN L2 with the container
        # (DHCP and mDNS from the LAN reach the guest).  The kernel publishes
        # the tap char device at /sys/class/macvtap/tap<ifindex>/dev; the node
        # itself lands in the host's devtmpfs, so mknod it here.  Requires
        # NET_ADMIN and a device-cgroup rule for the tap major.
        macvtap_if="mvt0"
        if ! ip link show "$macvtap_if" >/dev/null 2>&1; then
            ip link add link eth0 name "$macvtap_if" type macvtap mode bridge
        fi
        # The kernel assigns the macvtap an auto-generated MAC, but the guest NIC
        # carries the board-data MAC1 ($ZD_MAC1).  The macvlan bridge routes
        # inbound frames by destination MAC, so the macvtap MAC MUST equal the
        # guest NIC MAC, otherwise the LAN's DHCP offer/ack (and any unicast to
        # the guest) is dropped before it reaches the guest — the guest never
        # completes DHCP.  Set it before the interface is brought up.
        if [ -n "${ZD_MAC1:-}" ]; then
            ip link set "$macvtap_if" address "$ZD_MAC1"
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
        echo "NETWORK_MODE must be user, tap, macvtap or none" >&2
        exit 2
        ;;
esac

if [ "${NETWORK_MODE:-user}" != none ]; then
    # The synthetic board reports COB7402, so the stock network script loads
    # the igb2 driver.  QEMU's `igb` model emulates the Intel 82576 (PCI
    # 0x10C9) which igb2.ko supports, so the stock driver binds and brings up
    # eth0/br0 exactly like real hardware.
    if [ "${NETWORK_MODE:-user}" = macvtap ] && [ -n "${ZD_MAC1:-}" ]; then
        # The QEMU NIC must carry the guest's base MAC (board-data MAC1, the
        # one the vendor v54bsp driver forces onto NIC[0]).  This is derived
        # FROM the container's eth0 MAC but is a distinct value (eth0 + 1), so
        # the guest does NOT share the container's MAC, and both request their
        # own (separate) DHCP lease on the same LAN segment.
        nic_args=( -net "nic,model=igb,macaddr=$ZD_MAC1" )
    else
        nic_args=( -net nic,model=igb,macaddr=52:54:00:12:00:01 )
    fi
fi

snapshot_args=()
if [ "${SNAPSHOT:-1}" = "1" ]; then
    snapshot_args+=( -snapshot )
fi

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

# Interactive console (ttyS0).  The guest kernel boots with console=ttyS0 and
# /etc/inittab runs `/dev/console::respawn:/bin/login.sh` on it, so this is the
# SAME console the ZD1200 CLI login is presented on.  We forward it to a QEMU
# chardev that (1) appends every byte to $ZD_CONSOLE_LOG so the entrypoint's
# READY detection (grep on /tmp/zd1200-web.log) and `docker exec … tail -f`
# keep working, and (2) serves an interactive socket so you can attach to the
# login prompt.  Set ZD_CONSOLE=0 for the old -nographic behaviour (console ->
# stdio -> the entrypoint's log only, not interactive).
console_args=()
if [ "${ZD_CONSOLE:-1}" != "0" ]; then
    console_sock="${ZD_CONSOLE_SOCK:-/tmp/zd1200-console.sock}"
    console_log="${ZD_CONSOLE_LOG:-/tmp/zd1200-web.log}"
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

exec qemu-system-i386 \
    -name zd1200-10.5.1-lab \
    "${accel_args[@]}" \
    -machine pc \
    -cpu "${CPU_MODEL:-pentium3}" \
    -m "${MEMORY_MB:-2048}" \
    -smp 1 \
    -kernel "$kernel" \
    "${initrd_args[@]}" \
    -drive "file=$disk_image,format=$disk_format,if=ide,index=0,media=disk,cache=${DISK_CACHE:-writeback}" \
    -append "root=/dev/hda2 ro console=ttyS0,115200n8 ${KERNEL_EXTRA-}" \
    "${snapshot_args[@]}" \
    "${net_args[@]}" \
    "${nic_args[@]}" \
    "${ipmi_args[@]}" \
    "${console_args[@]}" \
    -no-reboot \
    "${pacing_args[@]}" \
    "${debug_args[@]}"
