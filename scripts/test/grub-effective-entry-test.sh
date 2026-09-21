#!/usr/bin/env bash
#
# grub-effective-entry-test.sh — unit test for
# scripts/container/grub-effective-entry.sh, without firmware or QEMU.
#
# It builds a sparse disk with the ZD1200 layout (an ext2 hda1 holding
# /lib/grub/i386-pc/default, plus the two root partitions' boot-status bytes)
# and asserts the entry the vendor GRUB would boot, including the kflag
# decrement that separates "retry the spare root" from "boot the rescue image".
#
# Usage: ./scripts/test/grub-effective-entry-test.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../container" && pwd)"
HELPER="$BASE/grub-effective-entry.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-grub-entry.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

for tool in mke2fs debugfs; do
    command -v "$tool" >/dev/null 2>&1 \
        || { echo "SKIP: $tool not found (e2fsprogs is required)" >&2; exit 0; }
done

HDA1_START=62
# The helper takes the geometry as arguments, so the fixture can use a small
# hda1 and still exercise the real HDA2/HDA3 kflag offsets.
HDA1_SECTORS=8192
HDA2_START=84568
HDA3_START=499720
SECTOR=512

DISK="$TMP/disk.img"
HDA1="$TMP/hda1.img"
STAGE="$TMP/stage"

mkdir -p "$STAGE/lib/grub/i386-pc"
printf '0\n#\n' > "$STAGE/lib/grub/i386-pc/default"
truncate -s $((HDA1_SECTORS * SECTOR)) "$HDA1"
mke2fs -q -t ext2 -F -d "$STAGE" "$HDA1"

# The disk only needs to cover hda1 and the two kflag bytes.
truncate -s $(((HDA3_START + 2) * SECTOR)) "$DISK"
dd if="$HDA1" of="$DISK" bs="$SECTOR" seek="$HDA1_START" conv=notrunc status=none

set_default() { # <value> — rewrite the saved-default file inside hda1
    printf '%s\n#\n#\n' "$1" > "$TMP/default"
    debugfs -w -R "rm /lib/grub/i386-pc/default" "$HDA1" >/dev/null 2>&1 || true
    debugfs -w -R "write $TMP/default /lib/grub/i386-pc/default" "$HDA1" >/dev/null 2>&1
    dd if="$HDA1" of="$DISK" bs="$SECTOR" seek="$HDA1_START" conv=notrunc status=none
}

set_kflags() { # <sda2> <sda3>
    printf '%s' "$1" | dd of="$DISK" bs=1 seek=$((HDA2_START * SECTOR)) conv=notrunc status=none
    printf '%s' "$2" | dd of="$DISK" bs=1 seek=$((HDA3_START * SECTOR)) conv=notrunc status=none
}

fail() { echo "FAIL: $*" >&2; exit 1; }

check() { # <expected> <saved> <k2> <k3> <label>
    set_default "$2"
    set_kflags "$3" "$4"
    local got
    got="$(bash "$HELPER" "$DISK" "$HDA1_START" "$HDA1_SECTORS" "$HDA2_START" "$HDA3_START")"
    [ "$got" = "$1" ] || fail "$5: expected entry $1, got $got"
    printf 'ok   %s (saved=%s kflag=%s/%s -> entry %s)\n' "$5" "$2" "$3" "$4" "$got"
}

# Root images: entries 0 and 1.
check 0 0 8 8 "healthy current root"
check 1 1 8 8 "healthy spare root"
check 0 1 2 2 "early failure on the spare retries the current root"
check 1 2 5 5 "early failure on the spare retries the spare root"
check 1 2 6 6 "OOM marker still retries the spare root"
check 0 1 6 6 "OOM marker on the spare retries the current root"

# Rescue: entry 2 (image) and entry 3 (USB).
check 2 2 9 9 "watchdog marker advances to the rescue image"
check 2 2 8 8 "system-ready marker advances to the rescue image"
check 2 3 2 2 "saved entry 3 decrements into the rescue image"
check 3 3 9 9 "watchdog marker advances to the USB rescue"

# Ambiguous/failed reads must not be reported as the rescue entry.
rm -f "$TMP/default"
debugfs -w -R "rm /lib/grub/i386-pc/default" "$HDA1" >/dev/null 2>&1 || true
dd if="$HDA1" of="$DISK" bs="$SECTOR" seek="$HDA1_START" conv=notrunc status=none
got="$(bash "$HELPER" "$DISK" "$HDA1_START" "$HDA1_SECTORS" "$HDA2_START" "$HDA3_START")"
[ "$got" = "unknown" ] || fail "missing default: expected unknown, got $got"
printf 'ok   missing default -> %s\n' "$got"

echo
echo "all grub-effective-entry tests passed"
