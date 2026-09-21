#!/usr/bin/env bash
#
# grub-effective-entry.sh — print the menu.lst entry the vendor GRUB will boot.
#
# The vendor patches GRUB (buildroot: grub-recovery.patch) so that `default
# saved` reads /lib/grub/i386-pc/default and then adjusts that entry by the
# boot-status byte ("kflag") at offset 0 of both root partitions:
#
#     entry = saved
#     if ((kflag_sda2 | kflag_sda3) < '7' && entry != 0) entry -= 1
#
# '7' is the boundary: below it the last boot did not finish, so GRUB decrements
# the saved entry and retries the image it just booted; '8' (system ready) and
# '9' (watchdog reboot) let it advance to the next entry.  Entries 0 and 1 are
# the two root images; entry 2 is the factory-restore initramfs ("System rescue
# from image") and entry 3 the USB restore tool.
#
# The decrement matters to callers: a saved entry of 2 with a marker below '7'
# is the normal "the spare root failed early, retry it" state, not the rescue
# entry.  Only a saved entry of 2 with a marker of at least '7', or a saved
# entry of 3 or more, actually reaches a rescue entry.
#
# Prints the effective entry number as decimal, or `unknown` when the saved
# default cannot be read (a caller must not treat that as the rescue entry).
#
# Usage: grub-effective-entry.sh <disk> [hda1_start hda1_sectors hda2_start hda3_start]
set -euo pipefail

disk="${1:?usage: $0 <disk> [hda1_start hda1_sectors hda2_start hda3_start]}"
# Defaults are the ZD1200 CompactFlash layout (build-synthetic-cf.py).
hda1_start="${2:-62}"
hda1_sectors="${3:-84506}"
hda2_start="${4:-84568}"
hda3_start="${5:-499720}"
sector=512

[ -f "$disk" ] || { echo unknown; exit 0; }
command -v debugfs >/dev/null 2>&1 || { echo unknown; exit 0; }

tmp="$(mktemp "${TMPDIR:-/tmp}/zd-grub.XXXXXX")"
out="$tmp.default"
trap 'rm -f "$tmp" "$out"' EXIT

# The saved-default file lives inside hda1's ext2; read it with debugfs rather
# than mounting (the container and the LXC flow run without loop devices).
if ! dd if="$disk" of="$tmp" bs="$sector" skip="$hda1_start" count="$hda1_sectors" \
        status=none 2>/dev/null; then
    echo unknown; exit 0
fi
if ! debugfs -R "dump /lib/grub/i386-pc/default $out" "$tmp" >/dev/null 2>&1 \
   || [ ! -f "$out" ]; then
    echo unknown; exit 0
fi

saved="$(head -n1 "$out" | tr -d '[:space:]')"
case "$saved" in
    ''|*[!0-9]*) echo unknown; exit 0 ;;
esac

# kflag: one ASCII digit at offset 0 of each root partition.
kflag_byte() {
    dd if="$disk" bs=1 skip="$1" count=1 status=none 2>/dev/null \
        | od -An -tu1 | tr -d ' \n'
}
k2="$(kflag_byte $((hda2_start * sector)))" || k2=0
k3="$(kflag_byte $((hda3_start * sector)))" || k3=0
k2="${k2:-0}"
k3="${k3:-0}"

kretry=$(( k2 | k3 ))
entry="$saved"
if (( kretry < 0x37 && entry != 0 )); then   # 0x37 == ASCII '7'
    entry=$(( entry - 1 ))
fi
printf '%s\n' "$entry"
