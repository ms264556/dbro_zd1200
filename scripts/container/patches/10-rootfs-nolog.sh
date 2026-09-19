#!/usr/bin/env bash
#
# 10-rootfs-nolog.sh — patch files inside the ZD1200 lab VM rootfs partitions,
# writing the result into the flat disk.  Runs as a standard user:
# no root, no loop devices, no nbd, no mount.
#
#   read  : dd                (the flat disk is read directly)
#           debugfs           (userspace ext2 reader/writer)
#   write : dd                (writes only the changed byte ranges back to the
#                              disk)
#
# Usage:  run from the patches/ pipeline via prepare-vm-disks.sh
# (QCOW=<flat-disk> WORK=<workdir> ./"10-rootfs-nolog.sh")
#
# Configure PARTITIONS and PATCHES below.  Each PATCHES entry is
#   <rootfs-path>|<sed-expression>
# and is applied to every listed partition that contains the file.  Only byte
# ranges that actually change are written back, so the disk stays small.
#
# Idempotency and re-patching: write_local stores the pristine vendor copy of
# every file it replaces in the root's /.patchrollback store (see
# scripts/container/patch-lib.sh), so prepare-vm-disks.sh can restore the root
# and re-run this patch after the patch set changes.  A file that already
# matches the patched form is left alone.
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCOW="${QCOW:-$(dirname "$BASE")/synthetic-cf.img}"
# Work dir holds the partition scratch images, so keep it on disk-backed storage
# (a small /tmp tmpfs fills up; the repo dir is on real disk).
WORK="${WORK:-$(dirname "$BASE")/.rootfs-patch-work}"
ALIGN=512
# shellcheck source=../patch-lib.sh
. "$(dirname "$BASE")/patch-lib.sh"

# name|start_sector|sector_count   (mirrors build-synthetic-cf.py; hda1 is the
# /boot seed and is deliberately not patched — it never boots as a root fs)
PARTITIONS=(
    "hda2|84568|415152"
    "hda3|499720|415152"
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

    part_changed=0
    for patch in "${PATCHES[@]}"; do
        IFS='|' read -r fspath sedexpr <<< "$patch"
        say "[$name] patching $fspath"
        if ! fs_read "$IMG" "$fspath" "$WORK/file.orig"; then
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
        # write_local stores the pristine vendor copy first, preserves the file's
        # metadata and verifies the content round-trips before returning.
        write_local "$IMG" "$fspath" "$WORK/file.new"
        part_changed=1
    done

    if [ "$part_changed" = 0 ]; then
        echo "  no byte changes for $name"
        continue
    fi
    if write_deltas "$name" "$start"; then
        patched_any=1
    else
        echo "  no byte changes for $name (already patched on the disk?)"
    fi
done

if [ "$patched_any" = 0 ]; then
    say "no patch produced changes; nothing was written to the disk"
    exit 0
fi

say "verifying: re-reading the disk and comparing each partition"
ln -sf "$QCOW" "$WORK/flat.verify.raw"
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    dd if="$WORK/flat.verify.raw" of="$WORK/$name.verify.img" bs=$ALIGN \
       skip="$start" count="$sectors" status=none
    if cmp -s "$WORK/$name.verify.img" "$WORK/$name.img"; then
        echo "OK   $name: disk now matches the patched partition image"
    else
        echo "FAIL $name: disk does not match the patched partition image" >&2
        exit 1
    fi
done

for patch in "${PATCHES[@]}"; do
    IFS='|' read -r fspath _ <<< "$patch"
    say "patched content of $fspath (as read back through the disk):"
    debugfs -R "cat $fspath" "$WORK/hda2.verify.img" 2>/dev/null | grep -n -E 'nolog|mount -o' || true
done

say "done — patches applied to $QCOW"
