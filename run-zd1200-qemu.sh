#!/usr/bin/env bash
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
    none)
        net_args=( -net none )
        nic_args=()
        ;;
    *)
        echo "NETWORK_MODE must be user or tap" >&2
        exit 2
        ;;
esac

if [ "${NETWORK_MODE:-user}" != none ]; then
    # The synthetic board reports COB7402, so the stock network script loads
    # the igb2 driver.  QEMU's `igb` model emulates the Intel 82576 (PCI
    # 0x10C9) which igb2.ko supports, so the stock driver binds and brings up
    # eth0/br0 exactly like real hardware.
    nic_args=( -net nic,model=igb,macaddr=52:54:00:12:00:01 )
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
    -nographic \
    -no-reboot \
    "${pacing_args[@]}" \
    "${debug_args[@]}"
