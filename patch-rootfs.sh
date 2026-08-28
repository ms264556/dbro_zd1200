#!/usr/bin/env bash
#
# patch-rootfs.sh — patch files inside the ZD1200 lab VM rootfs partitions,
# writing the result into the qcow2 overlay only.  Runs as a standard user:
# no root, no loop devices, no nbd, no mount.
#
#   read  : qemu-img convert  (overlay + backing file -> flat raw view)
#           debugfs           (userspace ext2 reader/writer)
#   write : qemu-io           (writes only the changed byte ranges into the
#                              qcow2 overlay; the backing file is untouched)
#
# Usage:  ./patch-rootfs.sh
#
# Configure PARTITIONS and PATCHES below.  Each PATCHES entry is
#   <rootfs-path>|<sed-expression>
# and is applied to every listed partition that contains the file.  Only byte
# ranges that actually change are written back, so the overlay stays small and
# re-runs are idempotent (a file that is already patched is left alone).
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCOW="${QCOW:-$BASE/zd1200-vm.qcow2}"
# Work dir holds two ~2 GiB flatten files, so keep it on disk-backed storage
# (a small /tmp tmpfs fills up; the repo dir is on real disk).
WORK="${WORK:-$BASE/.rootfs-patch-work}"
ALIGN=512

# name|start_sector|sector_count   (mirrors make-synthetic-cf.py; hda1 is the
# /boot seed and is deliberately not patched — it never boots as a root fs)
PARTITIONS=(
    "hda2|329728|327680"
    "hda3|657408|327680"
)

# rootfs-path|sed-expression
# Expressions are applied with `sed -e`, so they are pattern-based on purpose:
# the same patch must survive firmware-version differences in whitespace and
# option ordering.  Two comma-anchored substitutions strip a `nolog` mount
# option whether it leads (`nolog,...`), sits mid-list (`...,nolog,...`) or
# trails (`...,nolog`); `\b` keeps them from touching words like "nologin",
# and a bare `nolog` (no comma either side, e.g. in a comment) is left alone.
PATCHES=(
    "/etc/init.d/sys_init|s/,nolog\b//; s/nolog\b,//"
)

rm -rf "$WORK"; mkdir -p "$WORK"

say() { printf '\n== %s\n' "$*"; }

say "flattening overlay+backing to $WORK/flat.raw"
qemu-img convert -f qcow2 -O raw "$QCOW" "$WORK/flat.raw"

patched_any=0
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    say "[$name] extracting partition (sector $start, ${sectors}s)"
    dd if="$WORK/flat.raw" of="$WORK/$name.img" bs=$ALIGN skip="$start" count="$sectors" status=none
    # snapshot of the pristine partition for delta detection
    cp "$WORK/$name.img" "$WORK/$name.orig.img"

    for patch in "${PATCHES[@]}"; do
        IFS='|' read -r fspath sedexpr <<< "$patch"
        say "[$name] patching $fspath"
        if ! debugfs -R "dump $fspath $WORK/file.orig" "$WORK/$name.img" 2>/dev/null \
           || [ ! -s "$WORK/file.orig" ]; then
            echo "  ! $fspath not present on $name, skipping" >&2
            continue
        fi
        sed -e "$sedexpr" "$WORK/file.orig" > "$WORK/file.new"
        if cmp -s "$WORK/file.orig" "$WORK/file.new"; then
            echo "  $fspath already matches the patched form (nothing to do)"
            continue
        fi
        echo "  change:"
        diff -u "$WORK/file.orig" "$WORK/file.new" | sed 's/^/    /' || true

        # inode metadata before/after, so a debugfs quirk can't silently
        # change permissions of a vendor script.  debugfs stat spreads the
        # fields across the "Inode: ..." / "User: ..." lines, so match by
        # field name rather than line position, and carry the Type along.
        stat_meta() { debugfs -R "stat $fspath" "$WORK/$name.img" 2>/dev/null \
            | awk '{ for (i = 1; i <= NF; i++) {
                         if ($i == "Type:")  t = $(i+1)
                         else if ($i == "Mode:")  m = $(i+1)
                         else if ($i == "User:")  u = $(i+1)
                         else if ($i == "Group:") g = $(i+1)
                     }} END { print t, m, u, g }'; }
        read -r type_old mode_old uid_old gid_old <<< "$(stat_meta)"

        # debugfs refuses to overwrite an existing file ("Ext2 file already
        # exists"), so rm + write.  The fresh inode comes back uid/gid 0 and
        # mode 0644; restore the original metadata right after.  Only regular
        # files are supported (the 010 octal prefix carries S_IFREG).
        printf 'rm %s\nwrite %s %s\n' "$fspath" "$WORK/file.new" "$fspath" > "$WORK/cmds.txt"
        debugfs -w -f "$WORK/cmds.txt" "$WORK/$name.img" 2>/dev/null
        if [ "$type_old" = "regular" ]; then
            debugfs -w -R "set_inode_field $fspath mode 010$mode_old" "$WORK/$name.img" >/dev/null 2>&1 || true
        else
            echo "  !! $fspath is not a regular file (type '$type_old'); aborting" >&2
            exit 1
        fi
        debugfs -w -R "set_inode_field $fspath uid $uid_old" "$WORK/$name.img" >/dev/null 2>&1 || true
        debugfs -w -R "set_inode_field $fspath gid $gid_old" "$WORK/$name.img" >/dev/null 2>&1 || true

        read -r type_new mode_new uid_new gid_new <<< "$(stat_meta)"
        if [ "$type_old" != "$type_new" ] || [ "$mode_old" != "$mode_new" ] \
           || [ "$uid_old" != "$uid_new" ] || [ "$gid_old" != "$gid_new" ]; then
            echo "  !! inode metadata mismatch after write: type $type_old->$type_new mode $mode_old->$mode_new uid $uid_old->$uid_new gid $gid_old->$gid_new" >&2
            echo "  !! aborting before writing anything to the overlay" >&2
            exit 1
        fi

        # verify the file content round-trips before anything hits the overlay
        debugfs -R "dump $fspath $WORK/file.check" "$WORK/$name.img" 2>/dev/null
        if ! cmp -s "$WORK/file.check" "$WORK/file.new"; then
            echo "  !! content verification failed for $fspath on $name; aborting" >&2
            exit 1
        fi

        # find changed 512-byte blocks between the pristine snapshot and now
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
            echo "  no byte changes for $fspath (already patched in overlay?)"
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
done

if [ "$patched_any" = 0 ]; then
    say "no patch produced changes; nothing was written to the overlay"
    exit 0
fi

say "verifying: re-flattening overlay and comparing each partition"
qemu-img convert -f qcow2 -O raw "$QCOW" "$WORK/flat.verify.raw"
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    dd if="$WORK/flat.verify.raw" of="$WORK/$name.verify.img" bs=$ALIGN \
       skip="$start" count="$sectors" status=none
    if cmp -s "$WORK/$name.verify.img" "$WORK/$name.img"; then
        echo "OK   $name: overlay now matches the patched partition image"
    else
        echo "FAIL $name: overlay does not match the patched partition image" >&2
        exit 1
    fi
done

for patch in "${PATCHES[@]}"; do
    IFS='|' read -r fspath _ <<< "$patch"
    say "patched content of $fspath (as read back through the overlay):"
    debugfs -R "cat $fspath" "$WORK/hda2.verify.img" 2>/dev/null | grep -n -E 'nolog|mount -o' || true
done

say "done — patches applied to $QCOW; backing file untouched"
