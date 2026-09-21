#!/usr/bin/env bash
#
# 90-file-list.sh — teach the vendor root repair to reproduce a patched root.
#
# /etc/init.d/chk_integrity.sh clone() reproduces a root by copying the paths
# listed in /file_list.txt.  The vendor list (buildroot: ext2root.mk) enumerates
# the vendor rootfs, so a clone already carries every vendor file -- and, with
# 40-skip-integrity's no-op md5 check, the patched ones too -- but it misses what
# this project adds afterwards: the patch-created files and the
# /.patchrollback store.  A cloned root therefore looked uncustomised to
# prepare-vm-disks.sh, which re-applied the whole patch set on top of already
# patched files and never rebuilt the store.
#
# Append the project's paths to /file_list.txt (file_list_append_added()):
# DIR:/LINK:/FILE:<md5> for every path in the store's 'added' list, plus one
# OTHER:./.patchrollback line that cp -a's the store -- including the sentinel
# prepare-vm-disks.sh writes after this patch set.
#
# Runs last so the store's 'added' list is complete.  Applied to the ROOT
# partitions of the flat disk (hda2/hda3) with the same read -> debugfs -> dd
# channel as the other rootfs patches.
#
# Usage:
#   QCOW=<flat-disk> WORK=<workdir> ./"90-file-list.sh"
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCOW="${QCOW:-$(dirname "$BASE")/synthetic-cf.img}"
WORK="${WORK:-$(dirname "$BASE")/.rootfs-patch-work}"
ALIGN=512
# shellcheck source=../patch-lib.sh
. "$(dirname "$BASE")/patch-lib.sh"

# The roots this run may touch: prepare-vm-disks.sh passes its per-root
# selection in ZD_PATCH_PARTS; with none set this is the full root pair
# (patch-lib.sh:patch_parts), which is how the patch tests drive it.
load_patch_parts

[ -f "$QCOW" ] || { echo "QCOW not found: $QCOW" >&2; exit 1; }

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

    say "[$name] appending the project's paths to $FILE_LIST"
    file_list_append_added "$IMG"

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
    if fs_read "$WORK/$name.verify.img" "$FILE_LIST" "$WORK/flist.check" \
       && grep -qF "$FILE_LIST_MARKER" "$WORK/flist.check" \
       && grep -qF "OTHER:.$PR_DIR" "$WORK/flist.check"; then
        echo "OK   $name: $FILE_LIST carries the project's paths and the store"
    else
        echo "FAIL $name: $FILE_LIST does not carry the project's paths" >&2
        exit 1
    fi
done

say "done — root repair now reproduces a patched root in $QCOW"
