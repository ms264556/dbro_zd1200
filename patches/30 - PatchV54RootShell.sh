#!/usr/bin/env bash
#
# 30 - PatchV54RootShell.sh — bake the vendor "!v54!" root-shell escape fix.
#
# The ZD1200 CLI command `!v54!` verifies a passphrase through /usr/sbin/sesame2
# and drops to a root shell only if that call succeeds.  We make it always
# succeed by replacing sesame2 with a trivial executable that exits 0.
#
# Why not a symlink to `true`: in this rootfs /bin/true is a busybox *applet*
# symlink (-> busybox).  busybox dispatches on argv[0], so invoking it through a
# name other than a real applet (here "sesame2") prints `applet not found` and
# exits 127.  A regular `#!/bin/sh` script that just calls `exit 0` is
# argv[0]-independent, so it works however sesame2 is exec'd.
#
# Applied to the ROOT partitions of the qcow2 overlay (hda2/hda3), using the
# same flatten -> debugfs -> qemu-io channel as patch-rootfs.sh.  Runs as a
# normal user: qemu-img (flatten), debugfs (userspace ext2 writer), qemu-io
# (writes only changed byte ranges into the overlay; the backing file is
# untouched).
#
# Usage:
#   QCOW=<overlay.qcow2> WORK=<workdir> ./"30 - PatchV54RootShell.sh"
#
# Idempotent: a partition whose sesame2 is already the exit-0 script is left
# alone.
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCOW="${QCOW:-$(dirname "$BASE")/zd1200-vm.qcow2}"
# Work dir holds the ~2 GiB flatten file, so keep it on disk-backed storage.
WORK="${WORK:-$(dirname "$BASE")/.rootfs-patch-work}"
ALIGN=512

TARGET="/usr/sbin/sesame2"
SCRIPT=$'#!/bin/sh\nexit 0\n'

# name|start_sector|sector_count  (mirrors make-synthetic-cf.py / patch-rootfs.sh)
PARTITIONS=(
    "hda2|329728|327680"
    "hda3|657408|327680"
)

[ -f "$QCOW" ] || { echo "QCOW not found: $QCOW" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"

say() { printf '\n== %s\n' "$*"; }

stat_meta() {
    # Type Mode User Group, matched by field name so line order can't change it.
    debugfs -R "stat $TARGET" "$1" 2>/dev/null \
        | awk '{ for (i = 1; i <= NF; i++) {
                    if ($i == "Type:")  t = $(i+1)
                    else if ($i == "Mode:")  m = $(i+1)
                    else if ($i == "User:")  u = $(i+1)
                    else if ($i == "Group:") g = $(i+1)
                }} END { print t, m, u, g }'
}

say "flattening $QCOW -> $WORK/flat.raw"
qemu-img convert -f qcow2 -O raw "$QCOW" "$WORK/flat.raw"

printf '%s' "$SCRIPT" > "$WORK/sesame2.new"

patched_any=0
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    say "[$name] extracting partition (sector $start, ${sectors}s)"
    dd if="$WORK/flat.raw" of="$WORK/$name.img" bs=$ALIGN skip="$start" count="$sectors" status=none
    cp "$WORK/$name.img" "$WORK/$name.orig.img"

    read -r type_old _ _ _ <<< "$(stat_meta "$WORK/$name.img")"
    if [ -z "$type_old" ]; then
        echo "  ! $TARGET not present on $name, skipping"
        continue
    fi
    if [ "$type_old" = "regular" ]; then
        # Already patched?  Compare the current content to the exit-0 script.
        if debugfs -R "dump $TARGET $WORK/target.cur" "$WORK/$name.img" >/dev/null 2>&1 \
           && cmp -s "$WORK/target.cur" "$WORK/sesame2.new"; then
            echo "  $TARGET is already the exit-0 script on $name; leaving as-is"
            continue
        fi
    fi

    echo "  replacing $TARGET (was '$type_old') with an exit-0 script"
    printf 'rm %s\nwrite %s %s\n' "$TARGET" "$WORK/sesame2.new" "$TARGET" > "$WORK/cmds.txt"
    debugfs -w -f "$WORK/cmds.txt" "$WORK/$name.img" >/dev/null 2>&1
    # debugfs 'write' lands as mode 0100644; restore the vendor file's metadata
    # (regular 0755, root:root) explicitly.
    debugfs -w -R "set_inode_field $TARGET mode 0100755" "$WORK/$name.img" >/dev/null 2>&1
    debugfs -w -R "set_inode_field $TARGET uid 0" "$WORK/$name.img" >/dev/null 2>&1
    debugfs -w -R "set_inode_field $TARGET gid 0" "$WORK/$name.img" >/dev/null 2>&1

    read -r type_new mode_new _ _ <<< "$(stat_meta "$WORK/$name.img")"
    if [ "$type_new" != "regular" ] || [ "$mode_new" != "0755" ]; then
        echo "  !! unexpected result on $name: type=$type_new mode=$mode_new; aborting" >&2
        exit 1
    fi
    if ! debugfs -R "dump $TARGET $WORK/target.check" "$WORK/$name.img" >/dev/null 2>&1 \
       || ! cmp -s "$WORK/target.check" "$WORK/sesame2.new"; then
        echo "  !! content verification failed for $TARGET on $name; aborting" >&2
        exit 1
    fi

    # Only changed 512-byte blocks (between the pristine snapshot and now) are
    # written back, so the overlay stays small and idempotent.
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
        echo "  no byte changes for $TARGET on $name (already patched in overlay?)"
        continue
    fi

    abs_start=$((start * ALIGN))
    while read -r off len; do
        dd if="$WORK/$name.img" of="$WORK/chunk.bin" bs=$ALIGN \
           skip=$((off / ALIGN)) count=$((len / ALIGN)) status=none
        abs_off=$((abs_start + off))
        echo "  qemu-io: $len bytes at offset $abs_off"
        qemu-io -f qcow2 -c "write -s $WORK/chunk.bin $abs_off $len" "$QCOW" >/dev/null
    done < "$WORK/$name.runs"
    patched_any=1
done

if [ "$patched_any" = 0 ]; then
    say "no patch produced changes; nothing written to the overlay"
    exit 0
fi

say "verifying: re-flattening overlay and comparing each partition"
qemu-img convert -f qcow2 -O raw "$QCOW" "$WORK/flat.verify.raw"
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    dd if="$WORK/flat.verify.raw" of="$WORK/$name.verify.img" bs=$ALIGN \
       skip="$start" count="$sectors" status=none
    if cmp -s "$WORK/$name.verify.img" "$WORK/$name.img"; then
        echo "OK   $name: overlay matches the patched partition image"
    else
        echo "FAIL $name: overlay does not match the patched partition image" >&2
        exit 1
    fi
    read -r t m _ _ <<< "$(stat_meta "$WORK/$name.verify.img")"
    if [ "$t" = "regular" ] && [ "$m" = "0755" ]; then
        echo "OK   $name: $TARGET is a regular exit-0 script (mode $m)"
    else
        echo "FAIL $name: $TARGET is not the exit-0 script after patch (type '$t' mode '$m')" >&2
        exit 1
    fi
done

say "done — $TARGET replaced with an exit-0 script in $QCOW; backing file untouched"
