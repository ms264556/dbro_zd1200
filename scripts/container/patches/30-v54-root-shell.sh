#!/usr/bin/env bash
#
# 30-v54-root-shell.sh — bake the vendor "!v54!" root-shell escape fix.
#
# The ZD1200 CLI/login escape `!v54!` verifies a passphrase through the vendor
# passphrase helper and drops to a root shell only if that call succeeds.  The
# helper's name is release-dependent: newer builds ship /usr/sbin/sesame2,
# older ones (e.g. 10.2.1.0.236) ship /usr/sbin/sesame.  We make the escape
# always succeed by replacing whichever helper the release has with a trivial
# executable that exits 0.
#
# Why not a symlink to `true`: in this rootfs /bin/true is a busybox *applet*
# symlink (-> busybox).  busybox dispatches on argv[0], so invoking it through a
# name other than a real applet (here "sesame"/"sesame2") prints `applet not
# found` and exits 127.  A regular `#!/bin/sh` script that just calls `exit 0`
# is argv[0]-independent, so it works however the helper is exec'd.
#
# Applied to the ROOT partitions of the flat disk (hda2/hda3), using the
# same read -> debugfs -> dd channel as the other rootfs patches.  Runs as a
# normal user: dd (read/write), debugfs (userspace ext2 writer)
# (writes only changed byte ranges back to the disk).
#
# Usage:
#   QCOW=<flat-disk> WORK=<workdir> ./"30-v54-root-shell.sh"
#
# Idempotent: a partition whose helper is already the exit-0 script is left
# alone.
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCOW="${QCOW:-$(dirname "$BASE")/synthetic-cf.img}"
# Work dir holds the partition scratch images, so keep it on disk-backed storage.
WORK="${WORK:-$(dirname "$BASE")/.rootfs-patch-work}"
ALIGN=512

# Passphrase helpers, newest name first.  Whichever exists on a partition is
# patched; a release that ships only one of them simply skips the other.
TARGETS=(
    "/usr/sbin/sesame2"   # newer builds (e.g. 10.5.1.0.282)
    "/usr/sbin/sesame"    # older builds (e.g. 10.2.1.0.236)
)
SCRIPT=$'#!/bin/sh\nexit 0\n'

# name|start_sector|sector_count  (mirrors build-synthetic-cf.py)
PARTITIONS=(
    "hda2|84568|415152"
    "hda3|499720|415152"
)

[ -f "$QCOW" ] || { echo "QCOW not found: $QCOW" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"

say() { printf '\n== %s\n' "$*"; }

stat_meta() {
    # Type Mode User Group, matched by field name so line order can't change it.
    debugfs -R "stat $2" "$1" 2>/dev/null \
        | awk '{ for (i = 1; i <= NF; i++) {
                    if ($i == "Type:")  t = $(i+1)
                    else if ($i == "Mode:")  m = $(i+1)
                    else if ($i == "User:")  u = $(i+1)
                    else if ($i == "Group:") g = $(i+1)
                }} END { print t, m, u, g }'
}

say "reading the flat disk $QCOW"
ln -sf "$QCOW" "$WORK/flat.raw"

printf '%s' "$SCRIPT" > "$WORK/helper.new"

patched_any=0
present_any=0
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    say "[$name] extracting partition (sector $start, ${sectors}s)"
    dd if="$WORK/flat.raw" of="$WORK/$name.img" bs=$ALIGN skip="$start" count="$sectors" status=none
    cp "$WORK/$name.img" "$WORK/$name.orig.img"

    part_changed=0
    for TARGET in "${TARGETS[@]}"; do
        read -r type_old _ _ _ <<< "$(stat_meta "$WORK/$name.img" "$TARGET")"
        if [ -z "$type_old" ]; then
            echo "  - $TARGET not present on $name"
            continue
        fi
        present_any=1
        if [ "$type_old" = "regular" ]; then
            # Already patched?  Compare the current content to the exit-0 script.
            if debugfs -R "dump $TARGET $WORK/target.cur" "$WORK/$name.img" >/dev/null 2>&1 \
               && cmp -s "$WORK/target.cur" "$WORK/helper.new"; then
                echo "  $TARGET is already the exit-0 script on $name; leaving as-is"
                continue
            fi
        fi

        echo "  replacing $TARGET (was '$type_old') with an exit-0 script"
        printf 'rm %s\nwrite %s %s\n' "$TARGET" "$WORK/helper.new" "$TARGET" > "$WORK/cmds.txt"
        debugfs -w -f "$WORK/cmds.txt" "$WORK/$name.img" >/dev/null 2>&1
        # debugfs 'write' lands as mode 0100644; restore the vendor file's
        # metadata (regular 0755, root:root) explicitly.
        debugfs -w -R "set_inode_field $TARGET mode 0100755" "$WORK/$name.img" >/dev/null 2>&1
        debugfs -w -R "set_inode_field $TARGET uid 0" "$WORK/$name.img" >/dev/null 2>&1
        debugfs -w -R "set_inode_field $TARGET gid 0" "$WORK/$name.img" >/dev/null 2>&1

        read -r type_new mode_new _ _ <<< "$(stat_meta "$WORK/$name.img" "$TARGET")"
        if [ "$type_new" != "regular" ] || [ "$mode_new" != "0755" ]; then
            echo "  !! unexpected result on $name: type=$type_new mode=$mode_new; aborting" >&2
            exit 1
        fi
        if ! debugfs -R "dump $TARGET $WORK/target.check" "$WORK/$name.img" >/dev/null 2>&1 \
           || ! cmp -s "$WORK/target.check" "$WORK/helper.new"; then
            echo "  !! content verification failed for $TARGET on $name; aborting" >&2
            exit 1
        fi
        part_changed=1
    done

    if [ "$part_changed" = 0 ]; then
        echo "  no byte changes for $name"
        continue
    fi

    # Only changed 512-byte blocks (between the pristine snapshot and now) are
    # written back, so the disk stays small and idempotent.
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
        echo "  no byte changes for $name (already patched on the disk?)"
        continue
    fi

    abs_start=$((start * ALIGN))
    while read -r off len; do
        dd if="$WORK/$name.img" of="$WORK/chunk.bin" bs=$ALIGN \
           skip=$((off / ALIGN)) count=$((len / ALIGN)) status=none
        abs_off=$((abs_start + off))
        echo "  write: $len bytes at offset $abs_off"
        dd if="$WORK/chunk.bin" of="$QCOW" bs=$ALIGN seek=$((abs_off / ALIGN)) count=$((len / ALIGN)) conv=notrunc status=none
    done < "$WORK/$name.runs"
    patched_any=1
done

if [ "$present_any" = 0 ]; then
    say "no passphrase helper (${TARGETS[*]}) found on any root partition; nothing to patch"
    exit 0
fi

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
    for TARGET in "${TARGETS[@]}"; do
        read -r t m _ _ <<< "$(stat_meta "$WORK/$name.verify.img" "$TARGET")"
        [ -z "$t" ] && continue          # helper absent in this release
        if [ "$t" = "regular" ] && [ "$m" = "0755" ] \
           && debugfs -R "dump $TARGET $WORK/target.final" "$WORK/$name.verify.img" >/dev/null 2>&1 \
           && cmp -s "$WORK/target.final" "$WORK/helper.new"; then
            echo "OK   $name: $TARGET is a regular exit-0 script (mode $m)"
        else
            echo "FAIL $name: $TARGET is not the exit-0 script after patch (type '$t' mode '$m')" >&2
            exit 1
        fi
    done
done

say "done — passphrase helper replaced with an exit-0 script in $QCOW"
