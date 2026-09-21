#!/usr/bin/env bash
#
# 45-zd-bmc-watchdog.sh — give the guest kernel's watchdog a real reset vector.
#
# The appliance's watchdog chain is:
#
#   /bin/wd_feeder  --kicks-->  /dev/watchdog (nar5520_watchdog)
#       |                             |
#       | can't read /etc/inittab     | userspace counter expires
#       '-> stops kicking             '-> nar5520_wdt_thread() writes kflag '9'
#                                         and stops calling nar5520_wdt_refresh()
#                                              |
#                                              v
#                                    W627 Super-I/O watchdog fires -> reset
#
# QEMU's '-machine pc' has no W627 (and patch 'cob7402_reset_watchdog' makes the
# board routine a no-op), so the refresh writes go to unassigned ports and the
# last link is missing: the guest writes the '9' marker but nothing resets it,
# and GRUB's default_func() therefore keeps retrying the same root.
#
# QEMU does provide an in-box IPMI BMC (launch-vm.sh attaches ipmi-bmc-sim +
# isa-ipmi-kcs).  Its watchdog is a real machine reset driven from outside the
# guest CPU (IPMI_CMD_SET_WATCHDOG_TIMER with action=hard reset ->
# qemu_system_reset_request()).  The guest already has /dev/ipmi0 and
# /usr/sbin/ipmitool, so this patch installs a small daemon that:
#
#   * arms the BMC watchdog,
#   * feeds it while the guest is healthy,
#   * stops feeding as soon as the kernel has written the KFLAG_WDT_REBOOT '9'
#     marker to byte 0 of the root partition -- which is exactly the moment the
#     driver stopped refreshing the W627.  The BMC then resets the machine, the
#     next boot sees '9' + GRUB's saved entry 1 and takes the backup root, and
#     flag_reset repairs the primary.
#
# A hard hang that never reaches the kernel's timeout block writes no '9'; the
# daemon dies with the rest of userspace and the BMC still resets, which is also
# what the hardware does when the kernel cannot mark the failure.
#
# The kflag is read from the running root device with dd.  That is a raw block
# read of byte 0, the same byte the kernel's write_kflags() writes, so it does
# not depend on the filesystem being consistent.
#
# Applied to the ROOT partitions of the flat disk (hda2/hda3), using the same
# read -> debugfs -> dd channel as the other rootfs patches.
#
# Usage:
#   QCOW=<flat-disk> WORK=<workdir> ./"45-zd-bmc-watchdog.sh"
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCOW="${QCOW:-$(dirname "$BASE")/synthetic-cf.img}"
WORK="${WORK:-$(dirname "$BASE")/.rootfs-patch-work}"
ALIGN=512
# shellcheck source=../patch-lib.sh
. "$(dirname "$BASE")/patch-lib.sh"

TARGET="/etc/init.d/S46zd_bmc_watchdog"

# The roots this run may touch: prepare-vm-disks.sh passes its per-root
# selection in ZD_PATCH_PARTS; with none set this is the full root pair
# (patch-lib.sh:patch_parts), which is how the patch tests drive it.
load_patch_parts

[ -f "$QCOW" ] || { echo "QCOW not found: $QCOW" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"

cat > "$WORK/S46zd_bmc_watchdog" <<'ZD_BMC_WATCHDOG'
#!/bin/sh
# S46zd_bmc_watchdog -- emulated W627 feeder for the container (see
# scripts/container/patches/45-zd-bmc-watchdog.sh for the full explanation).
#
# Arms the in-box IPMI BMC watchdog and feeds it until the kernel signals a
# userspace-watchdog timeout by writing '9' to byte 0 of the root partition.
# Then it stops feeding and the BMC hard-resets the machine.

# BMC countdown, in seconds.  Long enough that a slow boot or a firmware upgrade
# cannot trip it, short enough that a real hang is caught promptly.  0x24 only
# initialises the timer; 0x22 starts/feeds it.
WATCHDOG_TIMEOUT_S=60
FEED_INTERVAL_S=10
IPMITOOL=/usr/sbin/ipmitool
LOG=/dev/console

logmsg() {
    echo "zd_bmc_watchdog: $*" > "$LOG" 2>/dev/null
}

# The in-box BMC and the client may not be present (e.g. the container was
# launched with ZD_IPMI=0); then there is no hardware watchdog to feed.
wait_ready() {
    i=0
    while [ "$i" -lt 60 ]; do
        [ -x "$IPMITOOL" ] && [ -c /dev/ipmi0 ] && return 0
        i=$((i + 1))
        sleep 1
    done
    return 1
}

# KFLAG_WDT_REBOOT.  The kernel writes it to both roots when its u-watchdog
# expires, i.e. when it stops kicking the (emulated) W627.  Read the partitions
# directly: this 2.6.32 kernel's /proc/mounts reports the root device as
# "rootfs", not the block device it was mounted from, so resolving "/" does not
# give /dev/sda2 here.
watchdog_expired() {
    for dev in /dev/sda2 /dev/sda3; do
        [ -b "$dev" ] || continue
        flag="$(dd if="$dev" bs=1 count=1 2>/dev/null)"
        [ "$flag" = "9" ] && return 0
    done
    return 1
}

# /etc/init.d/flag_reset resets the saved boot entry to the running one on every
# healthy boot, so by the time a watchdog expires the flag points at the root
# that just failed and GRUB would boot it again.  Point it at the other root
# first: that boot's flag_reset clones the spare back over the failed root, and
# its own reset makes this self-correcting if the reset never happens.  This is
# the vendor's own mechanism -- the same grub-set-default + move that ac_upg.sh
# and flag_reset use.
BOOT_FLAG=/boot/lib/grub/i386-pc/default
GRUB_SET_CMD=/boot/sbin/grub-set-default
MENU_LST=/boot/lib/grub/i386-pc/menu.lst

point_next_boot_at_spare() {
    [ -x "$GRUB_SET_CMD" ] || { logmsg "no grub-set-default; boot entry not moved"; return 0; }
    [ -f "$MENU_LST" ] || { logmsg "no menu.lst; boot entry not moved"; return 0; }
    running="$(mount | awk '$3 == "/" { print $1; exit }')"
    [ -n "$running" ] || { logmsg "cannot resolve the running root; boot entry not moved"; return 0; }
    # The vendor menu's first two entries carry "root=/dev/sdaX"; the rescue
    # entries that follow have no root= at all, so the spare is whichever of the
    # two is not the running root.
    first="$(sed -n 's/.*root=\([^ ]*\).*/\1/p' "$MENU_LST" | head -n 1)"
    if [ "$first" = "$running" ]; then
        spare=1
    else
        spare=0
    fi
    if "$GRUB_SET_CMD" --root-directory=/boot/lib/ "$spare"; then
        mv /boot/lib/grub/default "$BOOT_FLAG"
        logmsg "next boot: entry $spare (spare root); flag_reset will repair the failed root"
    else
        logmsg "grub-set-default failed; next boot stays on the failed root"
    fi
}

arm_bmc() {
    ticks=$((WATCHDOG_TIMEOUT_S * 10))
    lsb=$(printf '0x%02x' $((ticks & 0xff)))
    msb=$(printf '0x%02x' $(((ticks >> 8) & 0xff)))
    "$IPMITOOL" raw 0x06 0x24 0x04 0x01 0x00 0x00 "$lsb" "$msb" >/dev/null 2>&1
}

feed_bmc() {
    "$IPMITOOL" raw 0x06 0x22 >/dev/null 2>&1
}

# Best effort: disable the countdown so a deliberately long orderly shutdown is
# not cut short by a stale timer.  Not all BMCs accept this; harmless if not.
disarm_bmc() {
    "$IPMITOOL" raw 0x06 0x24 0x00 0x00 0x00 0x00 0x00 0x00 >/dev/null 2>&1
}

run() {
    wait_ready || { logmsg "no IPMI BMC; not arming"; return 0; }

    i=0
    while [ "$i" -lt 5 ]; do
        arm_bmc && break
        i=$((i + 1))
        sleep 1
    done
    feed_bmc
    logmsg "armed BMC watchdog (${WATCHDOG_TIMEOUT_S}s), feeding every ${FEED_INTERVAL_S}s"

    while :; do
        if watchdog_expired; then
            point_next_boot_at_spare
            logmsg "kernel u-watchdog expired (kflag '9'); stopped feeding, BMC will reset"
            return 0
        fi
        if [ ! -c /dev/ipmi0 ]; then
            logmsg "/dev/ipmi0 gone; stopped feeding"
            return 0
        fi
        feed_bmc
        sleep "$FEED_INTERVAL_S"
    done
}

case "$1" in
    start)
        trap 'disarm_bmc; exit 0' TERM INT
        run &
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
ZD_BMC_WATCHDOG
chmod 755 "$WORK/S46zd_bmc_watchdog"

say "reading the flat disk $QCOW"
ln -sf "$QCOW" "$WORK/flat.raw"

patched_any=0
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    say "[$name] extracting partition (sector $start, ${sectors}s)"
    extract_part "$name" "$start" "$sectors"
    snapshot_orig "$name"
    IMG="$WORK/$name.img"
    pr_init "$IMG"

    say "[$name] installing $TARGET"
    write_local "$IMG" "$TARGET" "$WORK/S46zd_bmc_watchdog" 0755

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
    read -r t _ _ _ <<< "$(fs_stat_meta "$WORK/$name.verify.img" "$TARGET")"
    [ "$t" = "regular" ] || { echo "FAIL $name: $TARGET missing" >&2; exit 1; }
    echo "OK   $name: $TARGET installed"
done

say "done — BMC watchdog feeder installed in $QCOW"
