#!/usr/bin/env bash
#
# dump-rootfs-version-test.sh — unit test for
# scripts/build/find-cf-partition.py --roots and
# scripts/build/dump-rootfs-version.sh, using synthetic dumps (no firmware, no
# real card).
#
# It builds a small raw disk with a vendor partition table (the MBR-style
# sector the v54bsp CF reader requires, at the layout's fixed sector) and ext2
# root partitions holding /bin/VERSION, then asserts:
#
#   * --roots prints the two root partitions and not /writable or /boot;
#   * the version helper reads the release from the first readable root;
#   * it falls back to the spare root when the primary root has no version;
#   * it strips whitespace (the on-card file ends in a newline);
#   * an ImageUSB 512-byte header is skipped;
#   * an unrecognisable dump exits 1 with no output.
#
# Usage: ./scripts/test/dump-rootfs-version-test.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../build" && pwd)"
FIND="$BASE/find-cf-partition.py"
VERSION="$BASE/dump-rootfs-version.sh"
# The fixtures are real (if small) filesystem images and the helper copies a
# partition out of the dump, so they go on the working filesystem next to the
# repo rather than under TMPDIR: /tmp is a tmpfs on many hosts and this test
# would fill it.
TMP="$(mktemp -d "${ZD_TEST_TMPDIR:-${HOME:-/tmp}}/.zd-rootver-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

for tool in mke2fs debugfs python3; do
    command -v "$tool" >/dev/null 2>&1 \
        || { echo "SKIP: $tool not found (e2fsprogs and python3 are required)" >&2; exit 0; }
done

SECTOR=512
# Small ext2 fixtures rather than the real 1872 MiB geometry: the helper only
# reads the partition table and /bin/VERSION, so stub-sized partitions exercise
# exactly the same code.
HDA1_START=62
HDA1_SECTORS=2048
HDA2_START=4096
HDA2_SECTORS=2048
HDA3_START=8192
HDA3_SECTORS=2048
HDA4_START=12288
HDA4_SECTORS=2048
ZD_PART_SECTOR=16384              # mirrors write-boarddata.py (ZD1200)

fail=0
check() { # <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1" >&2
        echo "     expected: $2" >&2
        echo "     actual:   $3" >&2
        fail=1
    fi
}

ext2_with_version() { # <image> <version>
    local img="$1" version="$2" stage
    # An empty version means "this root has no /bin/VERSION": leave the blank
    # image the caller already created alone.
    [ -n "$version" ] || return 0
    stage="$TMP/stage.$$"
    rm -rf "$stage"; mkdir -p "$stage/bin"
    printf '%s\n' "$version" > "$stage/bin/VERSION"
    mke2fs -q -t ext2 -F -d "$stage" "$img"
    rm -rf "$stage"
}

build_disk() { # <out> [version-a] [version-b]
    local out="$1"
    # `${2-DEFAULT}`, not `${2:-DEFAULT}`: an explicit empty string means "this
    # root has no /bin/VERSION" and must stay empty.
    local va="${2-VERSION-A}" vb="${3-VERSION-B}"
    local a="$TMP/a.img" b="$TMP/b.img" d="$TMP/d.img" boot="$TMP/boot.img"
    rm -f "$out" "$a" "$b" "$d" "$boot"
    # hda1 is a valid ext2 Linux partition here, so --roots must still skip it:
    # it holds no rootfs (on a real card it carries GRUB and the kernel).
    truncate -s $((HDA1_SECTORS * SECTOR)) "$boot"
    mke2fs -q -t ext2 -F "$boot"
    truncate -s $((HDA2_SECTORS * SECTOR)) "$a"
    ext2_with_version "$a" "$va"
    truncate -s $((HDA3_SECTORS * SECTOR)) "$b"
    ext2_with_version "$b" "$vb"
    truncate -s $((HDA4_SECTORS * SECTOR)) "$d"
    # The /writable partition is only located by the partition table here, so a
    # blank (non-reiserfs) partition is enough: --roots never looks at it.
    truncate -s $(( (HDA4_START + HDA4_SECTORS + 8) * SECTOR )) "$out"
    dd if="$boot" of="$out" bs="$SECTOR" seek="$HDA1_START" conv=notrunc status=none
    dd if="$a" of="$out" bs="$SECTOR" seek="$HDA2_START" conv=notrunc status=none
    dd if="$b" of="$out" bs="$SECTOR" seek="$HDA3_START" conv=notrunc status=none
    dd if="$d" of="$out" bs="$SECTOR" seek="$HDA4_START" conv=notrunc status=none
    # The vendor partition-table-like sector the CF reader requires.
    python3 - "$out" <<'PY'
import struct, sys
path = sys.argv[1]
SECTOR, ZD_PART_SECTOR = 512, 3927001
parts = [(0x00, 62, 2048), (0x80, 4096, 2048), (0x00, 8192, 2048), (0x00, 12288, 2048)]
b = bytearray([0xFF] * SECTOR)
for i, (boot, start, count) in enumerate(parts):
    e = 446 + i * 16
    b[e] = boot
    b[e + 1:e + 4] = b"\xfe\xff\xff"
    b[e + 4] = 0x83
    b[e + 5:e + 8] = b"\xfe\xff\xff"
    struct.pack_into("<II", b, e + 8, start, count)
b[510:512] = b"\x55\xaa"
with open(path, "r+b") as fh:
    fh.seek(ZD_PART_SECTOR * SECTOR)
    fh.write(b)
PY
}

# ---- --roots: the two root partitions, in table order ----------------------
DISK="$TMP/disk.img"
build_disk "$DISK" "9.10.2.0" "9.10.2.0"
check "--roots finds both roots" \
    "$HDA2_START $HDA2_SECTORS
$HDA3_START $HDA3_SECTORS" \
    "$(python3 "$FIND" --roots "$DISK")"
check "--roots ignores /writable" \
    "yes" \
    "$(python3 "$FIND" --roots "$DISK" | grep -q "$HDA4_START" && echo no || echo yes)"
check "default still finds /writable" "$HDA4_START $HDA4_SECTORS" "$(python3 "$FIND" "$DISK")"

# ---- the release is read from the rootfs, not guessed ----------------------
check "reads the primary root's release" "9.10.2.0" "$("$VERSION" "$DISK")"

build_disk "$TMP/newer.img" "10.5.1.0" "10.5.1.0"
check "reads a 10.x release" "10.5.1.0" "$("$VERSION" "$TMP/newer.img")"

# ---- whitespace is not part of the version ---------------------------------
build_disk "$TMP/tabbed.img" "$(printf '9.13.3.0\t')" "9.13.3.0"
check "strips whitespace" "9.13.3.0" "$("$VERSION" "$TMP/tabbed.img")"

# ---- a primary root without a version falls back to the spare --------------
build_disk "$TMP/spare.img" "" "9.10.2.0"
check "falls back to the spare root" "9.10.2.0" "$("$VERSION" "$TMP/spare.img")"

# ---- an ImageUSB header is skipped -----------------------------------------
# A Windows ImageUSB dump is the same image behind a 512-byte "imageUSB"
# header, so everything (the vendor table at its fixed absolute sector, and the
# roots' superblocks) sits 512 bytes later.
{ printf 'imageUSB'; dd if=/dev/zero bs=1 count=504 status=none; cat "$DISK"; } > "$TMP/imageusb.bin"
check "skips an ImageUSB header" "9.10.2.0" "$("$VERSION" "$TMP/imageusb.bin" 512)"

# ---- no vendor partition table: unknown, and that is a soft failure --------
truncate -s $((1024 * 1024)) "$TMP/blank.img"
if out="$("$VERSION" "$TMP/blank.img" 2>/dev/null)"; then
    check "blank dump reports nothing" "" "$out"
else
    check "blank dump reports nothing" "" ""
fi

if [ "$fail" = 0 ]; then
    echo "PASS dump-rootfs-version-test"
else
    echo "FAIL dump-rootfs-version-test" >&2
    exit 1
fi
