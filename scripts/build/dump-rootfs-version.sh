#!/usr/bin/env bash
#
# dump-rootfs-version.sh — print the firmware release of a ZD1200-family card
# dump's own rootfs (the "active rootfs" the dump would boot).
#
# A card dump carries the running firmware in its root partitions (hda2/hda3);
# /writable holds configuration only and no version at all.  Pairing such a
# card's /writable with a ZD1200 firmware rootfs of a different release (see
# prepare-vendor-image.sh --writable-from) is not supported: the vendor only
# treats releases as interchangeable up to the first three version components
# (/bin/sys_wrapper.sh getValidVer/isSameVer), which is what the caller
# compares.
#
# The release is read from /bin/VERSION — the file the vendor's own upgrade
# check uses (`curver=`cat /bin/VERSION`` in sys_wrapper.sh verify-upgrade):
# "10.5.1.0" with the build number kept separately in /bin/BUILD.
#
# Both root partitions are tried: after an in-guest upgrade they carry the same
# release, so preferring one only matters for a card whose spare root was left
# behind (the primary rootfs is the dump's own active one).  The first
# readable value is printed.
#
# Prints the release (the version file's contents, whitespace removed), or
# nothing and exit 1 when it cannot be read.  The caller decides whether that
# is fatal: an unknown version is not a proven mismatch.
#
# Usage: dump-rootfs-version.sh <dump> [header_offset_bytes]
set -euo pipefail

dump="${1:?usage: $0 <dump> [header_offset_bytes]}"
offset="${2:-0}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -f "$dump" ] || exit 1
command -v debugfs >/dev/null 2>&1 || exit 1

# The dump's own vendor partition table locates its rootfs partitions
# (find-cf-partition.py --roots).  A dump whose geometry differs from the
# ZD1200's still resolves here, which is the point: --writable-from exists for
# foreign cards.
roots="$(python3 "$here/find-cf-partition.py" --roots "$dump" "$offset" 2>/dev/null)" || exit 1
[ -n "$roots" ] || exit 1

# Only one rootfs is copied at a time and it is deleted before the next is
# tried, so TMPDIR needs room for a single root partition.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/zd-rootver.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

while read -r start count; do
    [ -n "$start" ] && [ -n "$count" ] || continue
    img="$tmp/$start.img"
    # debugfs needs a seekable filesystem, so the partition is copied out
    # first; remove it again before trying the next root.
    dd if="$dump" of="$img" bs=512 skip=$((start + offset / 512)) count="$count" status=none 2>/dev/null || continue
    out="$tmp/$start.version"
    # -R 'dump' takes a path inside the filesystem: no leading slash.
    debugfs -R "dump /bin/VERSION $out" "$img" >/dev/null 2>&1 || { rm -f "$img" "$out"; continue; }
    rm -f "$img"
    [ -s "$out" ] || continue
    version="$(tr -d '[:space:]' < "$out")"
    [ -n "$version" ] || continue
    printf '%s\n' "$version"
    exit 0
done <<< "$roots"

exit 1
