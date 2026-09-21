#!/usr/bin/env bash
#
# 40-skip-integrity.sh — stop the ZD1200 rootfs integrity checker rejecting the
# project's patched files, without breaking the vendor's root repair.
#
# /etc/init.d/chk_integrity.sh md5-verifies every FILE entry in /file_list.txt.
# The project's deliberately-patched files (the kernel, the v54 escape helper,
# dropbear, sys_wrapper's signing bypass, ...) do not match the vendor hashes, so
# the checker reports "file:[./...] corrupted" and counts an error for each.
#
# The md5 verification is replaced with a no-op, which keeps every listed file
# acceptable:
#
#   * `check` and `check-rootfs` count no errors, so the vendor warnings are
#     gone;
#   * `clone` copies the whole listed tree, patched files included, so
#     flag_reset's repair of the primary root after a watchdog fallback works.
#
# Rewriting /file_list.txt itself is not an option: check_md5sum() copies exactly
# the entries whose md5 matches, so a list of SKIP: entries makes clone() copy
# nothing and the "repaired" partition holds only /bzImage and /file_list.txt.
#
# Applied to the ROOT partitions of the flat disk (hda2/hda3) with the same
# read -> debugfs -> dd channel as the other rootfs patches.
#
# Usage:
#   QCOW=<flat-disk> WORK=<workdir> ./"40-skip-integrity.sh"
#
# Re-patching: the pristine /etc/init.d/chk_integrity.sh and /file_list.txt are
# kept in the root's /.patchrollback store (pr_save), so prepare-vm-disks.sh
# restores both before a changed patch set is re-applied.  The patch is a no-op
# once its marker line is present, so applying it to a root that has no rollback
# store (a repaired clone) is safe.
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCOW="${QCOW:-$(dirname "$BASE")/synthetic-cf.img}"
WORK="${WORK:-$(dirname "$BASE")/.rootfs-patch-work}"
ALIGN=512
# shellcheck source=../patch-lib.sh
. "$(dirname "$BASE")/patch-lib.sh"

TARGET="/etc/init.d/chk_integrity.sh"
MD5_PATTERN='/usr/bin/md5sum -c'
MARKER='zd-container: accept patched files'
REPLACEMENT="                : # $MARKER (so clone still copies them)"

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

    if ! fs_read "$IMG" "$TARGET" "$WORK/chk.orig"; then
        echo "  ! $TARGET not present on $name, skipping"
        continue
    fi

    md5_lines=$(grep -cF "$MD5_PATTERN" "$WORK/chk.orig" || true)
    if [ "$md5_lines" = "0" ]; then
        if grep -qF "$MARKER" "$WORK/chk.orig"; then
            echo "  $TARGET on $name is already patched (nothing to do)"
            continue
        fi
        echo "  !! $TARGET on $name has neither the md5 check nor our marker; aborting" >&2
        exit 1
    fi
    if [ "$md5_lines" != "1" ]; then
        echo "  !! $TARGET on $name has $md5_lines md5 check lines; expected 1; aborting" >&2
        exit 1
    fi

    # Replace the whole md5 line with a successful no-op.  The following
    # `if [ $? -eq 0 ]` then always takes the "ok" branch: clone copies the file,
    # check counts no error.
    awk -v rep="$REPLACEMENT" \
        'index($0, "/usr/bin/md5sum -c") { print rep; next } { print }' \
        "$WORK/chk.orig" > "$WORK/chk.new"

    echo "  replacing the md5 verification in $TARGET with a no-op"
    write_local "$IMG" "$TARGET" "$WORK/chk.new"

    if write_deltas "$name" "$start"; then
        patched_any=1
    else
        echo "  no byte changes for $TARGET on $name (already patched on the disk?)"
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
    fs_read "$WORK/$name.verify.img" "$TARGET" "$WORK/chk.check" || true
    if grep -qF "$MARKER" "$WORK/chk.check" \
       && ! grep -qF "$MD5_PATTERN" "$WORK/chk.check"; then
        echo "OK   $name: $TARGET md5 check disabled, marker present"
    else
        echo "FAIL $name: $TARGET was not patched as expected" >&2
        exit 1
    fi
done

say "done — integrity check bypassed in $QCOW (clone still copies)"
