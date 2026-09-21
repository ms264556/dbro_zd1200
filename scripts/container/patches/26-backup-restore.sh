#!/usr/bin/env bash
#
# 26-backup-restore.sh — install the guest hook that applies a staged Ruckus
# configuration backup on the appliance's first boot.
#
# When the installer is given `--backup <ruckus_db_*.bak>`, the backup is
# decrypted and release-checked host-side and then staged into the freshly built
# /writable at /zd1200-restore/backup.bak (scripts/container/build-synthetic-cf.py).
# This patch installs the guest's half of that feature into both ext2 root
# partitions (hda2/hda3):
#
#   /etc/zd1200-restore.sh       the restore logic (see that file's header)
#   /etc/init.d/S48zd_restore    rcS entry; runs the logic before S50controller
#
# The hook is installed unconditionally and is a no-op unless a backup is staged,
# so the patch set stays constant whether or not --backup was used.  The vendor
# path (sys_wrapper.sh verify-backup / restore-saved) is the same code the web
# UI drives; it does the factory clean, the configuration move, the release
# migration and the AP customisation, then the hook reboots once.
#
# Usage:  QCOW=<flat-disk> WORK=<workdir> ./"26-backup-restore.sh"
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCOW="${QCOW:-$(dirname "$BASE")/synthetic-cf.img}"
WORK="${WORK:-$(dirname "$BASE")/.rootfs-patch-work}"
SRC_SH="$(dirname "$BASE")/backup-restore.sh"
INIT_DST=/etc/init.d/S48zd_restore
HOOK_DST=/etc/zd1200-restore.sh
ALIGN=512
# shellcheck source=../patch-lib.sh
. "$(dirname "$BASE")/patch-lib.sh"

# The roots this run may touch: prepare-vm-disks.sh passes its per-root
# selection in ZD_PATCH_PARTS; with none set this is the full root pair
# (patch-lib.sh:patch_parts), which is how the patch tests drive it.
load_patch_parts

[ -f "$SRC_SH" ] || { echo "26-backup-restore: $SRC_SH missing" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"

say "reading the flat disk $QCOW"
ln -sf "$QCOW" "$WORK/flat.raw"

# The rcS entry.  Constant, so it lives here rather than in the (tested) hook
# script; rcS forks it with a "start" argument, which the hook ignores.
cat > "$WORK/S48zd_restore" <<'ZD_RESTORE_INIT'
#!/bin/sh
#
# S48zd_restore — apply a staged configuration backup on the first boot.
#
# Installed by scripts/container/patches/26-backup-restore.sh (dbro_zd1200).
# rcS runs this after S47migrate has mounted /writable and before S50controller
# starts, so the controller comes up with the restored configuration.  See
# /etc/zd1200-restore.sh for the restore itself; it is a no-op unless the
# installer staged a backup into /writable/zd1200-restore/backup.bak.
[ -x /etc/zd1200-restore.sh ] && /etc/zd1200-restore.sh
exit 0
ZD_RESTORE_INIT
chmod 755 "$WORK/S48zd_restore"

patched_any=0
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    say "[$name] extracting partition (sector $start, ${sectors}s)"
    extract_part "$name" "$start" "$sectors"
    snapshot_orig "$name"
    IMG="$WORK/$name.img"
    pr_init "$IMG"

    say "[$name] installing $HOOK_DST"
    write_local "$IMG" "$HOOK_DST" "$SRC_SH" 0755
    say "[$name] installing $INIT_DST"
    write_local "$IMG" "$INIT_DST" "$WORK/S48zd_restore" 0755

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
done

say "patched content spot-checks ($(basename "$(spot_img)" .verify.img)):"
echo "--- $HOOK_DST ---"
debugfs -R "cat $HOOK_DST" "$(spot_img)" 2>/dev/null \
    | grep -n -E "verify-backup|restore-saved|REBOOT=|SYS_WRAPPER=" | head || true
echo "--- $INIT_DST ---"
debugfs -R "cat $INIT_DST" "$(spot_img)" 2>/dev/null \
    | grep -n -E "zd1200-restore.sh" | head || true

say "done — first-boot configuration-restore hook installed in $QCOW"
