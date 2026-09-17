#!/usr/bin/env bash
#
# 70-container-control.sh — install the guest side of the container's orderly
# shutdown channel.
#
# QEMU exposes a second serial port (ttyS1) as a private, non-networked channel.
# When the container is stopped, entrypoint.sh writes "reboot" on it (see
# scripts/container/entrypoint.sh) and launch-vm.sh exits after the resulting
# guest reset instead of relaunching QEMU.  This hook performs the guest half:
# it reads that one command and runs the stock reboot path, so the controller
# flushes its databases and the kernel unmounts /writable before the reset.
#
# Why not ACPI: the guest is booted with `-machine pc,acpi=off` to match the
# real cob7402 hardware, and QMP system_powerdown is an ACPI power-*button*
# event that needs a userspace handler (there is no acpid here), so it would be
# ignored.  The reboot path already works and is exercised by boot-test.sh.
#
# Applied with the same read -> debugfs -> dd channel as the other rootfs
# patches; only changed 512-byte blocks reach the disk.
#
# Usage: QCOW=<flat-disk> WORK=<workdir> ./70-container-control.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCOW="${QCOW:-$(dirname "$BASE")/synthetic-cf.img}"
WORK="${WORK:-$(dirname "$BASE")/.rootfs-patch-work}"
ALIGN=512

TARGET="/etc/init.d/S98zd_container_control"

# name|start_sector|sector_count  (mirrors build-synthetic-cf.py)
PARTITIONS=(
    "hda2|84568|415152"
    "hda3|499720|415152"
)

[ -f "$QCOW" ] || { echo "QCOW not found: $QCOW" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"
say() { printf '\n== %s\n' "$*"; }

cat > "$WORK/S98zd_container_control" <<'ZD_CONTAINER_CONTROL'
#!/bin/sh
# Container lifecycle control over the second serial port (ttyS1), a private
# non-networked channel.  Two commands are understood:
#
#   reboot   the container is stopping: run the stock reboot path so the
#            controller flushes its databases and the kernel unmounts /writable.
#   address  report this guest's own address.  The guest is the authority on its
#            lease -- asking it avoids the container having to sniff DHCP or
#            sweep the LAN for a matching MAC.
#
# Replies are written back on the same port as "ZD-<KEY>=<value>".
# Runs in the background and never blocks init.
(
    # devtmpfs normally provides this; fall back to a static node (ttyS 4:65).
    [ -c /dev/ttyS1 ] || mknod /dev/ttyS1 c 4 65 2>/dev/null || exit 0

    # Report the network state: which interfaces exist, what addresses they hold
    # and which driver each one is bound to.  This is what makes a NIC experiment
    # observable without logging into the appliance, whose console needs credentials
    # the operator may not have.
    guest_diag() {
        for dev in $(ls /sys/class/net 2>/dev/null); do
            [ "$dev" = lo ] && continue
            addr=$(ip -4 -o addr show dev "$dev" 2>/dev/null \
                   | awk '{print $4}' | cut -d/ -f1 | head -n1)
            drv=$(basename "$(readlink /sys/class/net/$dev/device/driver 2>/dev/null)" 2>/dev/null)
            echo "ZD-IF=$dev addr=${addr:-none} driver=${drv:-none}" > /dev/ttyS1
        done
        for m in igb2 igb e1000e e1000; do
            if [ -d "/sys/module/$m" ]; then
                echo "ZD-MODULE=$m loaded" > /dev/ttyS1
            fi
        done
        echo "ZD-END=diag" > /dev/ttyS1
    }

    guest_address() {
        # The stock stack manages the interface it created for the management
        # address; report whatever address that interface holds now.
        for dev in br0 uif0 eth0; do
            addr=$(ip -4 -o addr show dev "$dev" 2>/dev/null \
                   | awk '{print $4}' | cut -d/ -f1 | head -n1)
            [ -n "$addr" ] && { echo "$addr"; return; }
        done
    }

    while IFS= read -r command; do
        case "$command" in
            reboot)
                echo "ZD-CONTAINER-CONTROL: orderly shutdown requested" >/dev/console
                sync
                exec /sbin/reboot
                ;;
            diag)
                guest_diag
                ;;
            address)
                addr=$(guest_address)
                if [ -n "$addr" ]; then
                    echo "ZD-GUEST-IP=$addr" > /dev/ttyS1
                else
                    echo "ZD-GUEST-IP=" > /dev/ttyS1
                fi
                ;;
        esac
    done < /dev/ttyS1
) &
exit 0
ZD_CONTAINER_CONTROL
chmod 755 "$WORK/S98zd_container_control"
printf '%s\n' "$TARGET" > /dev/null

stat_meta() {
    debugfs -R "stat $2" "$1" 2>/dev/null \
        | awk '{ for (i = 1; i <= NF; i++) {
                     if ($i == "Type:")  t = $(i+1)
                     else if ($i == "Mode:")  m = $(i+1)
                     else if ($i == "User:")  u = $(i+1)
                     else if ($i == "Group:") g = $(i+1)
                 }} END { if (t != "") print t, m, u, g }'
}

write_local() {
    local img="$1" fspath="$2" localfile="$3"
    local dmode="${4:-0644}" duid="${5:-0}" dgid="${6:-0}"
    local t m u g mode_field
    read -r t m u g <<< "$(stat_meta "$img" "$fspath")"
    if [ -z "$t" ]; then
        m="$dmode"; u="$duid"; g="$dgid"
    elif [ "$t" != "regular" ]; then
        echo "  ! $fspath was not a regular file (type '$t'); replacing it" >&2
        m="$dmode"; u="$duid"; g="$dgid"
    fi
    mode_field="$(printf '010%04o' "$(( 0$m & 07777 ))")"
    printf 'rm %s\nwrite %s %s\n' "$fspath" "$localfile" "$fspath" > "$WORK/cmds.$$"
    debugfs -w -f "$WORK/cmds.$$" "$img" >/dev/null 2>&1
    rm -f "$WORK/cmds.$$"
    debugfs -w -R "set_inode_field $fspath mode $mode_field" "$img" >/dev/null 2>&1 || true
    debugfs -w -R "set_inode_field $fspath uid $u" "$img" >/dev/null 2>&1 || true
    debugfs -w -R "set_inode_field $fspath gid $g" "$img" >/dev/null 2>&1 || true
    if ! debugfs -R "dump $fspath $WORK/verify.$$" "$img" >/dev/null 2>&1 \
       || ! cmp -s "$WORK/verify.$$" "$localfile"; then
        echo "  !! content verification failed for $fspath; aborting" >&2
        rm -f "$WORK/verify.$$"
        return 1
    fi
    rm -f "$WORK/verify.$$"
    return 0
}

write_deltas() {
    local name="$1" start="$2" off len abs_start
    python3 - "$WORK/$name.orig.img" "$WORK/$name.img" "$ALIGN" > "$WORK/$name.runs" <<'PYEOF'
import sys
orig = open(sys.argv[1], 'rb').read()
new  = open(sys.argv[2], 'rb').read()
al   = int(sys.argv[3])
assert len(orig) == len(new), "partition size changed"
blocks = [i for i in range(0, len(orig), al) if orig[i:i + al] != new[i:i + al]]
runs = []
for b in blocks:
    if runs and b == runs[-1][1]:
        runs[-1] = (runs[-1][0], b + al)
    else:
        runs.append((b, b + al))
for s, e in runs:
    print(s, e - s)
PYEOF
    if [ ! -s "$WORK/$name.runs" ]; then
        return 1
    fi
    abs_start=$((start * ALIGN))
    while read -r off len; do
        dd if="$WORK/$name.img" of="$WORK/chunk.bin" bs=$ALIGN \
           skip=$((off / ALIGN)) count=$((len / ALIGN)) status=none
        dd if="$WORK/chunk.bin" of="$QCOW" bs=$ALIGN \
           seek=$(((abs_start + off) / ALIGN)) count=$((len / ALIGN)) conv=notrunc status=none
    done < "$WORK/$name.runs"
    return 0
}

say "reading the flat disk $QCOW"
ln -sf "$QCOW" "$WORK/flat.raw"

patched_any=0
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    say "[$name] extracting partition (sector $start, ${sectors}s)"
    dd if="$WORK/flat.raw" of="$WORK/$name.img" bs=$ALIGN skip="$start" count="$sectors" status=none
    cp "$WORK/$name.img" "$WORK/$name.orig.img"

    say "[$name] installing $TARGET"
    write_local "$WORK/$name.img" "$TARGET" "$WORK/S98zd_container_control" 0755

    if write_deltas "$name" "$start"; then
        patched_any=1
    else
        echo "  no byte changes for $name"
    fi
done

if [ "$patched_any" = 0 ]; then
    say "no patch produced changes; nothing written to the disk"
    exit 0
fi

say "verifying: re-reading the disk and comparing each partition"
ln -sf "$QCOW" "$WORK/flat.verify.raw"
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    dd if="$WORK/flat.verify.raw" of="$WORK/$name.verify.img" bs=$ALIGN \
       skip="$start" count="$sectors" status=none
    if cmp -s "$WORK/$name.verify.img" "$WORK/$name.img"; then
        echo "OK   $name: disk matches the patched partition image"
    else
        echo "FAIL $name: disk does not match the patched partition image" >&2
        exit 1
    fi
    read -r t _ _ _ <<< "$(stat_meta "$WORK/$name.verify.img" "$TARGET")"
    [ "$t" = "regular" ] || { echo "FAIL $name: $TARGET missing" >&2; exit 1; }
    echo "OK   $name: $TARGET installed"
done

say "done — container control hook installed in $QCOW"
