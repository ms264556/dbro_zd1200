#!/usr/bin/env bash
#
# prepare-vm-disks.sh — build the guest disk and (re)apply the kernel + rootfs
# customisations to the root partitions that need them.
#
# FLAT model: the synthetic CF image ($SYNTHETIC_DISK) *is* the live disk — there
# is no qcow2 overlay.  Each root partition carries a sentinel, /etc/.zd-image,
# holding the signature of the patch set applied to it.  On every start we read
# each root's sentinel and customise only the roots that are missing it or were
# done by an older patch set:
#
#   * fresh disk             -> no sentinel, customise both roots
#   * patch set changed      -> sentinel mismatch, re-customise
#   * in-guest firmware upgrade writes a new rootfs onto the spare partition ->
#     that root has no sentinel so it is customised; the untouched root is skipped
#   * a rollback leaves both roots already customised -> nothing to do
#
# The kernel is applied to each root's *own* /bzImage, because the two roots can
# hold different firmware builds (an upgrade writes its kernel into the target
# root); the archive kernel is only installed when a root has none at all.
#
# Env (all optional, defaults shown):
#   STATE_DIR        scratch/state dir            ($BASE; entrypoint passes /var/lib/zd1200)
#   SYNTHETIC_DISK   the CF image (the live disk) ($STATE_DIR/synthetic-cf.img)
#   WORK             patch scratch dir            ($STATE_DIR/.rootfs-patch-work)
#   IMAGE_DIR/ROOTFS vendor artifacts             ($BASE/image, $IMAGE_DIR/rootfs.ext2)
#   PATCHES_DIR      the ordered patches          ($BASE/patches)
#   ZD_SERIAL ZD_MAC1 ZD_MODEL ZD_CUSTOMER        board data (written when the disk is built)
#   ZD_SIGN_CERT_DIR payload for the license/signing patch
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-$BASE}"
DISK="${SYNTHETIC_DISK:-$STATE_DIR/synthetic-cf.img}"
WORK="${WORK:-$STATE_DIR/.rootfs-patch-work}"
IMAGE_DIR="${IMAGE_DIR:-$BASE/image}"
ROOTFS="${ROOTFS:-$IMAGE_DIR/rootfs.ext2}"
BOOTFS_SRC="${BOOTFS_SRC:-$IMAGE_DIR/restoreinitramfs.gz}"
PATCHES_DIR="${PATCHES_DIR:-$BASE/patches}"
MARKER="${MARKER:-$STATE_DIR/.disk-built}"
SIGN_CERT_DIR="${ZD_SIGN_CERT_DIR:-/opt/zd1200/signing-cert}"
SENTINEL=/etc/.zd-image

say() { printf '\n== %s\n' "$*"; }

SECTOR=512
HDA1_START=62;     HDA1_SECTORS=84506
HDA2_START=84568;  HDA2_SECTORS=415152
HDA3_START=499720; HDA3_SECTORS=415152
HDA4_START=914872; HDA4_SECTORS=3006008
ROOT_PARTS=(
    "hda2|$HDA2_START|$HDA2_SECTORS"
    "hda3|$HDA3_START|$HDA3_SECTORS"
)

for f in "$ROOTFS" "$BOOTFS_SRC" "$IMAGE_DIR/menu.lst" \
         "$IMAGE_DIR/restoreinitramfs.ver" "$IMAGE_DIR/bzImage"; do
    [ -f "$f" ] || { echo "prepare-vm-disks: missing $f — run scripts/build/prepare-vendor-image.sh" >&2; exit 1; }
done
[ -d "$PATCHES_DIR" ] || { echo "prepare-vm-disks: $PATCHES_DIR missing" >&2; exit 1; }

# --- signatures -------------------------------------------------------------
rootfs_sig="$(sha256sum "$ROOTFS" | awk '{print $1}')"
bootfs_sig="$( cd "$BASE" && { sha256sum "$BOOTFS_SRC" "$IMAGE_DIR/menu.lst" \
    "$IMAGE_DIR/restoreinitramfs.ver" build-bootfs.py; } | sha256sum | awk '{print $1}')"
patch_sig="$( cd "$PATCHES_DIR" && for f in *.sh; do [ -f "$f" ] || continue; \
    printf '%s ' "$f"; sha256sum "$f" | awk '{print $1}'; done | sha256sum | awk '{print $1}')"

# --- (re)build the disk when missing or the base firmware changed ------------
rebuild=0; reason=""
if [ ! -f "$DISK" ]; then
    rebuild=1; reason="no disk yet"
else
    stored_rootfs=""; stored_bootfs=""
    if [ -f "$MARKER" ]; then
        stored_rootfs="$(sed -n 's/^rootfs=//p' "$MARKER")"
        stored_bootfs="$(sed -n 's/^bootfs=//p' "$MARKER")"
    fi
    if   [ "$stored_rootfs" != "$rootfs_sig" ]; then rebuild=1; reason="base rootfs changed"
    elif [ "$stored_bootfs" != "$bootfs_sig" ]; then rebuild=1; reason="bootfs inputs changed"
    fi
fi
if [ "$rebuild" = 1 ]; then
    say "Building the synthetic CF disk — $reason"
    rm -f "$DISK"
    SYNTHETIC_DISK="$DISK" python3 "$BASE/build-synthetic-cf.py"
    say "Writing board data (serial=${ZD_SERIAL:-123456000789}, MAC1=${ZD_MAC1:-00:0c:e6:12:00:01})"
    python3 "$BASE/write-boarddata.py" --disk "$DISK" \
        --serial "${ZD_SERIAL:-123456000789}" --mac "${ZD_MAC1:-00:0c:e6:12:00:01}" \
        --model "${ZD_MODEL:-ZD1200}" --customer "${ZD_CUSTOMER:-ruckus}"
    printf 'rootfs=%s\nbootfs=%s\n' "$rootfs_sig" "$bootfs_sig" > "$MARKER"
fi

# --- helpers ----------------------------------------------------------------
is_ext2()  { [ "$(dd if="$1" bs=1 skip=1080 count=2 status=none 2>/dev/null \
                  | od -An -tx1 | tr -d ' ')" = "53ef" ]; }
sentinel_of() { debugfs -R "cat $SENTINEL" "$1" 2>/dev/null | head -n1; }
extract_part() { dd if="$DISK" of="$WORK/$1.img" bs=$SECTOR skip="$2" count="$3" status=none; }
write_part()   { dd if="$WORK/$1.img" of="$DISK" bs=$SECTOR seek="$2" count="$3" conv=notrunc status=none; }

# --- which root partitions need (re)customising? ----------------------------
rm -rf "$WORK"; mkdir -p "$WORK"
patch_parts=()
for part in "${ROOT_PARTS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    extract_part "$name" "$start" "$sectors"
    if ! is_ext2 "$WORK/$name.img"; then
        say "[$name] no ext2 filesystem here; skipping"
        continue
    fi
    have="$(sentinel_of "$WORK/$name.img")"
    if [ "$have" = "$patch_sig" ]; then
        say "[$name] already customised (sentinel $patch_sig); skipping"
    else
        say "[$name] needs customising (sentinel: ${have:-<none>})"
        patch_parts+=("$part")
    fi
done

if [ ${#patch_parts[@]} -eq 0 ]; then
    say "every root partition is already customised; nothing to do"
    exit 0
fi

# --- apply the QEMU kernel patch to each root's own /bzImage -----------------
# The vendor install drops the archive kernel at /bzImage in the root it writes;
# a guest firmware upgrade drops *its* kernel there.  Patch whatever kernel the
# root already carries, and only install the archive kernel when a root has none.
for part in "${patch_parts[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    say "[$name] applying the QEMU kernel patch"
    debugfs -R "dump /bzImage $WORK/$name.kernel" "$WORK/$name.img" 2>/dev/null || true
    if [ ! -s "$WORK/$name.kernel" ]; then
        say "[$name] no /bzImage in this root; installing the archive kernel"
        cp "$IMAGE_DIR/bzImage" "$WORK/$name.kernel"
    fi
    python3 "$BASE/patch-kernel.py" --in "$WORK/$name.kernel" \
        --out "$WORK/$name.kernel.patched" >"$WORK/$name.patch-kernel.log" 2>&1 || true
    if [ -s "$WORK/$name.kernel.patched" ] \
        && ! cmp -s "$WORK/$name.kernel" "$WORK/$name.kernel.patched"; then
        debugfs -w -R "rm /bzImage" "$WORK/$name.img" 2>/dev/null || true
        debugfs -w -R "write $WORK/$name.kernel.patched /bzImage" "$WORK/$name.img"
        write_part "$name" "$start" "$sectors"
        say "[$name] /bzImage patched"
    else
        say "[$name] /bzImage already carries the QEMU patches; leaving it"
    fi
done

# --- run the ordered customisation patches (they read/rewrite the flat disk) -
for patch in "$PATCHES_DIR"/*.sh; do
    [ -f "$patch" ] || continue
    say "running patch: $(basename "$patch")"
    QCOW="$DISK" WORK="$WORK" bash "$patch" "$SIGN_CERT_DIR"
done

# --- stamp each customised root with the sentinel ---------------------------
mkdir -p "$WORK"
for part in "${patch_parts[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    extract_part "$name" "$start" "$sectors"
    printf '%s\n' "$patch_sig" > "$WORK/sentinel.$name"
    debugfs -w -R "rm $SENTINEL" "$WORK/$name.img" 2>/dev/null || true
    debugfs -w -R "write $WORK/sentinel.$name $SENTINEL" "$WORK/$name.img"
    write_part "$name" "$start" "$sectors"
    say "[$name] sentinel written"
done

say "done — customised roots: ${patch_parts[*]}"
