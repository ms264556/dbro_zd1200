#!/usr/bin/env bash
#
# patch-rootfs-skip-integrity.sh — make the ZD1200 rootfs integrity checker skip
# every entry, so vendor "corrupted" warnings (e.g. `file:[./usr/sbin/sesame2]
# corrupted`) never appear for our patched files.
#
# The checker is /etc/init.d/chk_integrity.sh; it reads /file_list.txt, a list
# of `TYPE:data` lines.  Its case statement only acts on FILE/LINK/DIR/OTHER; a
# SKIP: line matches no branch and is ignored.  So rewriting every FILE/LINK/DIR/
# OTHER entry to SKIP: makes the check a no-op (it finds zero errors).
#
# Applied to the ROOT partitions of the qcow2 overlay (hda2/hda3) with the same
# flatten -> debugfs -> qemu-io channel as patch-rootfs.sh.  Runs as a normal
# user; only changed byte ranges are written to the overlay (backing untouched).
#
# Usage:
#   QCOW=<overlay.qcow2> WORK=<workdir> ./patch-rootfs-skip-integrity.sh
#
# Idempotent: a partition whose /file_list.txt already has no FILE/LINK/DIR/OTHER
# entries (all SKIP) is left alone.
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCOW="${QCOW:-$BASE/zd1200-vm.qcow2}"
WORK="${WORK:-$BASE/.rootfs-patch-work}"
ALIGN=512

TARGET="/file_list.txt"
# Rewrite the leading type token of every non-SKIP entry to SKIP:, keeping the
# rest of the line (for FILE: this keeps the md5 + path) so any other reader that
# parses `<type>:<data>` still sees a well-formed line.
SEDEXPR='s/^(FILE|LINK|DIR|OTHER):/SKIP:/'

# name|start_sector|sector_count  (mirrors make-synthetic-cf.py / patch-rootfs.sh)
PARTITIONS=(
    "hda2|329728|327680"
    "hda3|657408|327680"
)

[ -f "$QCOW" ] || { echo "QCOW not found: $QCOW" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"

say() { printf '\n== %s\n' "$*"; }

file_stat() {
    # Type Mode User Group for a given path, matched by field name.
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

patched_any=0
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    say "[$name] extracting partition (sector $start, ${sectors}s)"
    dd if="$WORK/flat.raw" of="$WORK/$name.img" bs=$ALIGN skip="$start" count="$sectors" status=none
    cp "$WORK/$name.img" "$WORK/$name.orig.img"

    if ! debugfs -R "dump $TARGET $WORK/flist.orig" "$WORK/$name.img" >/dev/null 2>&1 \
       || [ ! -s "$WORK/flist.orig" ]; then
        echo "  ! $TARGET not present on $name, skipping"
        continue
    fi

    sed -E "$SEDEXPR" "$WORK/flist.orig" > "$WORK/flist.new"
    if cmp -s "$WORK/flist.orig" "$WORK/flist.new"; then
        echo "  $TARGET on $name already has no FILE/LINK/DIR/OTHER entries (nothing to do)"
        continue
    fi

    read -r type_old mode_old uid_old gid_old <<< "$(file_stat "$WORK/$name.img")"
    before=$(grep -cE '^(FILE|LINK|DIR|OTHER):' "$WORK/flist.orig" || true)
    after=$(grep -cE '^(FILE|LINK|DIR|OTHER):' "$WORK/flist.new" || true)
    echo "  rewriting $TARGET: $before FILE/LINK/DIR/OTHER entries -> SKIP (now $after remaining)"

    # debugfs 'write' creates mode 0100644 uid/gid 0; restore the vendor file's
    # metadata (0644 group-readable, root:root) explicitly.
    printf 'rm %s\nwrite %s %s\n' "$TARGET" "$WORK/flist.new" "$TARGET" > "$WORK/cmds.txt"
    debugfs -w -f "$WORK/cmds.txt" "$WORK/$name.img" >/dev/null 2>&1
    debugfs -w -R "set_inode_field $TARGET mode 010$mode_old" "$WORK/$name.img" >/dev/null 2>&1
    debugfs -w -R "set_inode_field $TARGET uid $uid_old" "$WORK/$name.img" >/dev/null 2>&1
    debugfs -w -R "set_inode_field $TARGET gid $gid_old" "$WORK/$name.img" >/dev/null 2>&1

    read -r type_new mode_new _ _ <<< "$(file_stat "$WORK/$name.img")"
    if [ "$type_new" != "regular" ] || [ "$mode_new" != "$mode_old" ]; then
        echo "  !! unexpected result on $name: type=$type_new mode=$mode_new (wanted regular/$mode_old); aborting" >&2
        exit 1
    fi
    if ! debugfs -R "dump $TARGET $WORK/flist.check" "$WORK/$name.img" >/dev/null 2>&1 \
       || ! cmp -s "$WORK/flist.check" "$WORK/flist.new"; then
        echo "  !! content verification failed for $TARGET on $name; aborting" >&2
        exit 1
    fi

    # Only changed 512-byte blocks (pristine vs now) are written back.
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
    debugfs -R "dump $TARGET $WORK/flist.check" "$WORK/$name.verify.img" >/dev/null 2>&1
    remaining=$(grep -cE '^(FILE|LINK|DIR|OTHER):' "$WORK/flist.check" || true)
    if [ "$remaining" = "0" ]; then
        echo "OK   $name: $TARGET has no FILE/LINK/DIR/OTHER entries (all SKIP)"
    else
        echo "FAIL $name: $TARGET still has $remaining checkable entries" >&2
        exit 1
    fi
done

say "done — integrity list in $QCOW is all-SKIP; backing file untouched"
