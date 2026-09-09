#!/usr/bin/env bash
#
# apply-rootfs-patches.sh — the container's guest-image prep / patch coordinator.
#
# This script is the single place that prepares the virtual appliance's disks and
# runs the ordered rootfs patch pipeline, immediately before QEMU boots.  It is
# invoked by run-zd1200-web.sh (the container entrypoint) and is NOT meant to be
# run standalone on the host.  It owns:
#
#   1. building the writable synthetic CompactFlash (make-synthetic-cf.py) and
#      writing the board data (serial/MAC) into it,
#   2. creating the persistent qcow2 overlay (zd1200-vm.qcow2) that backs it,
#   3. deciding WHETHER the rootfs needs patching and running the patches,
#   4. recording the applied rootfs/bootfs/patch-set signature so the next boot
#      knows whether to re-patch.
#
# When does it patch?  Whenever it decides to patch it ALWAYS (1) recreates the
# overlay and then (2) applies the patches — it never patches an existing overlay
# in place.  When the base rootfs changed or is missing it also rebuilds the
# synthetic base disk first.  The patches only ever write into the ROOTFS
# partitions (hda2/hda3); the /writable data partition (hda4) is preserved across
# a re-patch and only initialized on the very first run.
#   * FIRST RUN  — no persistent overlay yet -> build disk + overlay, patch.
#   * NO MARKER  — an overlay exists but there is no patch-tracking marker (first
#                  run of this coordinator over a previous state volume): keep the
#                  base and /writable, recreate the overlay, and re-patch.
#   * UPGRADE    — the base rootfs (image/rootfs.ext2) hash changed since the
#                  patches were last applied (a new firmware archive was prepared
#                  into image/).  The synthetic base disk (which bakes the old
#                  rootfs) and the overlay are rebuilt from the new image, then
#                  re-patched.  (The lab does not support in-guest firmware
#                  upgrades, so a base change resets /writable + board data.)
#   * BOOTFS     — the boot-area inputs (image/restoreinitramfs.gz or build-bootfs.py) changed
#                  -> the boot area is baked into the synthetic base, so rebuild
#                  the base and re-patch.
#   * PATCH SET  — the patches/ set changed (a patch was added or edited) but the
#                  base rootfs is unchanged -> keep the base, recreate the overlay,
#                  preserve /writable, and re-apply the rootfs patches.
#   * otherwise  — nothing to do.
#
# Patches live in ./patches and run in lexical filename order (so "10 - …" runs
# before "20 - …", etc.).  Each patch examines the current rootfs + overlay and
# writes its own changes into the qcow2 overlay; a patch only ever touches the
# ROOTFS partitions (hda2/hda3) — never hda4 (/writable).  The coordinator passes
# ZD_SIGN_CERT_DIR to each patch as $1 (only the license/signing patch consumes
# it; it no-ops if the cert payload is missing).  Board data (serial/MAC) is
# written only when the synthetic base is built (first run / base rebuild), never
# on a re-patch.
#
# Env (all optional, defaults shown):
#   STATE_DIR        scratch/state dir (default: $BASE; the entrypoint passes /var/lib/zd1200)
#   SYNTHETIC_DISK   the writable CF image (default $STATE_DIR/synthetic-cf.img)
#   PERSISTENT_DISK  the qcow2 overlay    (default $STATE_DIR/zd1200-vm.qcow2)
#   WORK             patch scratch dir    (default $STATE_DIR/.rootfs-patch-work)
#   IMAGE_DIR/ROOTFS vendor artifacts      (default $BASE/image, $IMAGE_DIR/rootfs.ext2)
#   PATCHES_DIR      the ordered patches   (default $BASE/patches)
#   MARKER           state file of applied signatures (default $STATE_DIR/.patches-applied)
#   ZD_SERIAL ZD_MAC1 ZD_MODEL ZD_CUSTOMER  board data (written via write-boarddata.py)
#   ZD_SIGN_CERT_DIR   payload for the license/signing patch
#
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-$BASE}"
SYNTHETIC_DISK="${SYNTHETIC_DISK:-$STATE_DIR/synthetic-cf.img}"
PERSISTENT_DISK="${PERSISTENT_DISK:-$STATE_DIR/zd1200-vm.qcow2}"
WORK="${WORK:-$STATE_DIR/.rootfs-patch-work}"
IMAGE_DIR="${IMAGE_DIR:-$BASE/image}"
ROOTFS="${ROOTFS:-$IMAGE_DIR/rootfs.ext2}"
BOOTFS_SRC="${BOOTFS_SRC:-$IMAGE_DIR/restoreinitramfs.gz}"
BOOTFS_BUILDER="$BASE/build-bootfs.py"
PATCHES_DIR="${PATCHES_DIR:-$BASE/patches}"
MARKER="${MARKER:-$STATE_DIR/.patches-applied}"
SIGN_CERT_DIR="${ZD_SIGN_CERT_DIR:-/opt/zd1200/signing-cert}"

say() { printf '\n== %s\n' "$*"; }

# Partition geometry (mirrors make-synthetic-cf.py).
SECTOR=512
HDA1_START=62;     HDA1_SECTORS=84506
HDA2_START=84568;  HDA2_SECTORS=415152
HDA3_START=499720; HDA3_SECTORS=415152
HDA4_START=914872; HDA4_SECTORS=3006008

[ -f "$ROOTFS" ] || { echo "apply-rootfs-patches: missing base rootfs: $ROOTFS" >&2; exit 1; }
[ -f "$BOOTFS_SRC" ] || { echo "apply-rootfs-patches: missing firmware restore initramfs: $BOOTFS_SRC" >&2; exit 1; }
[ -f "$IMAGE_DIR/restoreinitramfs.ver" ] || { echo "apply-rootfs-patches: missing $IMAGE_DIR/restoreinitramfs.ver — run scripts/prepare-vendor-image.sh" >&2; exit 1; }
[ -f "$IMAGE_DIR/menu.lst" ] || { echo "apply-rootfs-patches: missing $IMAGE_DIR/menu.lst — run scripts/prepare-vendor-image.sh" >&2; exit 1; }
[ -f "$BOOTFS_BUILDER" ] || { echo "apply-rootfs-patches: missing bootfs builder: $BOOTFS_BUILDER" >&2; exit 1; }
command -v qemu-img >/dev/null 2>&1 || { echo "apply-rootfs-patches: qemu-img is required" >&2; exit 1; }
[ -d "$PATCHES_DIR" ] || { echo "apply-rootfs-patches: $PATCHES_DIR missing — put the ordered patches there" >&2; exit 1; }

# --- signature of the current base rootfs + bootfs inputs + patch set ---------
# The synthetic base disk bakes both the rootfs and the boot area (built from
# the firmware's GRUB binaries by build-bootfs.py), so a change to either means
# the base must be rebuilt (and the overlay re-patched).
rootfs_sig="$(sha256sum "$ROOTFS" | awk '{print $1}')"
bootfs_sig="$( cd "$BASE" && { sha256sum "$BOOTFS_SRC"; sha256sum "$IMAGE_DIR/restoreinitramfs.ver"; sha256sum "$IMAGE_DIR/menu.lst"; sha256sum build-bootfs.py; } | sha256sum | awk '{print $1}')"
patch_sig="$( cd "$PATCHES_DIR" && for f in *.sh; do [ -f "$f" ] || continue; printf '%s ' "$f"; sha256sum "$f" | awk '{print $1}'; done | sha256sum | awk '{print $1}')"

stored_rootfs=""; stored_bootfs=""; stored_patches=""
if [ -f "$MARKER" ]; then
    stored_rootfs="$(sed -n 's/^rootfs=//p' "$MARKER")"
    stored_bootfs="$(sed -n 's/^bootfs=//p' "$MARKER")"
    stored_patches="$(sed -n 's/^patches=//p' "$MARKER")"
fi

# --- decide: rebuild the synthetic base? patch? -----------------------------
# Whenever we decide the rootfs needs patching we ALWAYS recreate the overlay
# first (a clean copy-on-write layer) and THEN run the patches — never patch an
# existing overlay in place.  We additionally rebuild the underlying synthetic
# disk when the base rootfs itself changed (firmware upgrade) or is missing.
# A "patch set changed" re-patch keeps the base and only re-creates the overlay.
rebuild_synthetic=0; patch_needed=0; reason=""
if [ ! -f "$PERSISTENT_DISK" ]; then
    reason="first run (no persistent overlay)"; rebuild_synthetic=1; patch_needed=1
elif [ ! -f "$SYNTHETIC_DISK" ]; then
    reason="overlay present but its backing synthetic disk is missing"; rebuild_synthetic=1; patch_needed=1
elif [ -z "$stored_rootfs" ] || [ -z "$stored_patches" ]; then
    # No patch-tracking marker (e.g. first run of this coordinator over a
    # previously-created state volume).  Keep the existing base and /writable, and
    # re-patch the rootfs overlay cleanly; a baseline marker is then recorded.
    reason="no prior patch marker (re-patching the existing state)"; rebuild_synthetic=0; patch_needed=1
elif [ "$stored_rootfs" != "$rootfs_sig" ]; then
    reason="base rootfs changed (firmware upgrade)"; rebuild_synthetic=1; patch_needed=1
elif [ "$stored_bootfs" != "$bootfs_sig" ]; then
    # Checked before the patch set: the bootfs is baked into the synthetic base,
    # so it needs a rebuild (which also re-patches).
    reason="bootfs changed"; rebuild_synthetic=1; patch_needed=1
elif [ "$stored_patches" != "$patch_sig" ]; then
    reason="patch set changed"; rebuild_synthetic=0; patch_needed=1
fi

# --- detect a completed in-guest upgrade in the existing overlay -------------
# ac_upg.sh records the partition it wrote in /writable/etc/airespider-images/
# duplicate; that file survives until the next boot's flag_reset validates and
# clones it.  Seeing it here means the overlay holds the upgraded rootfs: fold
# the upgrade into the base (boot area, /writable and the newly active root
# partition), then recreate the overlay and re-patch it below.
folded=0
if [ -f "$PERSISTENT_DISK" ]; then
    mkdir -p "$WORK"
    # Cheap gate before the full flatten: an in-guest upgrade writes the whole
    # new rootfs (~150 MB) into the spare root partition, while the patch
    # pipeline writes only a few small files there.  qemu-img map reads just the
    # qcow2 metadata, so this is fast; only a large allocation triggers the
    # ~1.9 GB flatten+scan below.
    upgrade_alloc="$(python3 - "$PERSISTENT_DISK" "$SECTOR" \
        "$HDA2_START" "$HDA2_SECTORS" "$HDA3_START" "$HDA3_SECTORS" <<'PY'
import json, subprocess, sys
disk = sys.argv[1]
sector, s2, c2, s3, c3 = (int(x) for x in sys.argv[2:])
ranges = [(s2 * sector, (s2 + c2) * sector), (s3 * sector, (s3 + c3) * sector)]
try:
    out = subprocess.run(["qemu-img", "map", "--output=json", "-f", "qcow2", disk],
                         capture_output=True, text=True, check=True).stdout
except Exception as exc:
    print(f"upgrade gate: qemu-img map failed: {exc}", file=sys.stderr)
    print(-1)
    raise SystemExit
total = 0
for r in json.loads(out):
    if r.get("depth", 0) != 0 or not r.get("data", False):
        continue
    start, end = r["start"], r["start"] + r["length"]
    for lo, hi in ranges:
        total += max(0, min(end, hi) - max(start, lo))
print(total)
PY
)"
    if [ "${upgrade_alloc:--1}" -ge 0 ] && [ "${upgrade_alloc:-0}" -le $((64 * 1024 * 1024)) ]; then
        say "No in-guest upgrade signature in the overlay (root-partition allocation ${upgrade_alloc} bytes); skipping the scan"
    else
    say "Checking the existing overlay for an in-guest upgrade (root-partition allocation ${upgrade_alloc} bytes)"
    qemu-img convert -f qcow2 -O raw "$PERSISTENT_DISK" "$WORK/upgrade.flat.raw"
    dd if="$WORK/upgrade.flat.raw" of="$WORK/upgrade.writable.img" bs=$SECTOR \
        skip="$HDA4_START" count="$HDA4_SECTORS" status=none
    upgrade_part="$(debugfs -R "cat /etc/airespider-images/duplicate" \
        "$WORK/upgrade.writable.img" 2>/dev/null | tr -d ' \n')"
    case "$upgrade_part" in
        *2) up_start=$HDA2_START; up_count=$HDA2_SECTORS ;;
        *3) up_start=$HDA3_START; up_count=$HDA3_SECTORS ;;
        *)  up_start="" ;;
    esac
    if [ -n "$up_start" ]; then
        say "In-guest upgrade detected ($upgrade_part) — folding it into the base"
        for spec in "boot:$HDA1_START:$HDA1_SECTORS" \
                    "writable:$HDA4_START:$HDA4_SECTORS" \
                    "root:$up_start:$up_count"; do
            start="${spec#*:}"; start="${start%%:*}"
            count="${spec##*:}"
            dd if="$WORK/upgrade.flat.raw" of="$SYNTHETIC_DISK" bs=$SECTOR \
                skip="$start" count="$count" seek="$start" conv=notrunc status=none
        done
        # The folded partition carries the vendor kernel; re-apply the QEMU
        # kernel patches to its /bzImage.
        dd if="$SYNTHETIC_DISK" of="$WORK/upgrade.root.img" bs=$SECTOR \
            skip="$up_start" count="$up_count" status=none
        debugfs -R "dump /bzImage $WORK/upgrade.bzImage" "$WORK/upgrade.root.img" 2>/dev/null || true
        if [ -s "$WORK/upgrade.bzImage" ] \
            && python3 "$BASE/patch-kernel.py" --in "$WORK/upgrade.bzImage" \
               --out "$WORK/upgrade.bzImage.patched" >"$WORK/patch-kernel.log" 2>&1; then
            debugfs -w -R "rm /bzImage" "$WORK/upgrade.root.img" 2>/dev/null || true
            debugfs -w -R "write $WORK/upgrade.bzImage.patched /bzImage" "$WORK/upgrade.root.img" 2>/dev/null || true
            dd if="$WORK/upgrade.root.img" of="$SYNTHETIC_DISK" bs=$SECTOR \
                seek="$up_start" count="$up_count" conv=notrunc status=none
        else
            say "warning: could not re-patch the upgraded kernel; see $WORK/patch-kernel.log"
        fi
        rm -f "$WORK/upgrade.root.img" "$WORK/upgrade.bzImage" "$WORK/upgrade.bzImage.patched"
        rebuild_synthetic=0
        patch_needed=1
        reason="in-guest upgrade folded into the base"
        folded=1
    fi
    rm -f "$WORK/upgrade.flat.raw" "$WORK/upgrade.writable.img"
    fi
fi

if [ "$rebuild_synthetic" = 1 ]; then
    say "Rebuilding synthetic base disk — $reason"
    rm -f "$SYNTHETIC_DISK"
fi

# --- keep /writable (hda4) across a re-patch ---------------------------------
# The qcow2 overlay COWs the whole disk, so recreating it would reset the
# persistent /writable data partition.  On a RE-PATCH (base rootfs unchanged) we
# preserve the current hda4 from the overlay and restore it into the base right
# after, so re-patching only ever modifies the rootfs (hda2/hda3).  /writable is
# (re)initialised only when the base is built (first run / base rebuild).
#   hda4 geometry mirrors make-synthetic-cf.py.
preserved_hda4=""
if [ "$patch_needed" = 1 ] && [ "$rebuild_synthetic" = 0 ] && [ "$folded" != 1 ] && [ -f "$PERSISTENT_DISK" ]; then
    mkdir -p "$WORK"
    say "Preserving /writable (hda4) from the current overlay (re-patch will not reset it)"
    qemu-img convert -f qcow2 -O raw "$PERSISTENT_DISK" "$WORK/hda4.flat.raw"
    dd if="$WORK/hda4.flat.raw" of="$WORK/hda4.preserve.img" bs=$SECTOR \
        skip="$HDA4_START" count="$HDA4_SECTORS" status=none
    rm -f "$WORK/hda4.flat.raw"
    preserved_hda4="$WORK/hda4.preserve.img"
fi

if [ "$patch_needed" = 1 ]; then
    say "(Re)creating persistent VM disk overlay — $reason"
    rm -f "$PERSISTENT_DISK"
fi

# --- build the writable synthetic CompactFlash ------------------------------
built_synthetic=0
if [ ! -f "$SYNTHETIC_DISK" ]; then
    say "Building writable synthetic CompactFlash: $SYNTHETIC_DISK"
    SYNTHETIC_DISK="$SYNTHETIC_DISK" python3 "$BASE/make-synthetic-cf.py"
    built_synthetic=1
fi

# Board data (serial/MAC) is preserved like /writable: it is initialised only when
# the synthetic base is built (very first run, or a base rebuild after a firmware
# change).  On a re-patch the current board data — including any changes made by
# the guest/firmware or other processes — is preserved along with /writable and
# is never rewritten or reset by a re-patch.
if [ "$built_synthetic" = 1 ]; then
    say "Writing board data (serial=${ZD_SERIAL:-123456000789}, MAC1=${ZD_MAC1:-00:0c:e6:12:00:01})"
    python3 "$BASE/write-boarddata.py" \
        --disk "$SYNTHETIC_DISK" \
        --serial "${ZD_SERIAL:-123456000789}" \
        --mac "${ZD_MAC1:-00:0c:e6:12:00:01}" \
        --model "${ZD_MODEL:-ZD1200}" \
        --customer "${ZD_CUSTOMER:-ruckus}"
fi

# --- create the persistent qcow2 overlay ------------------------------------
if [ ! -f "$PERSISTENT_DISK" ]; then
    say "Creating persistent VM disk overlay: $PERSISTENT_DISK"
    qemu-img create -q -f qcow2 -F raw -b "$SYNTHETIC_DISK" "$PERSISTENT_DISK"
fi

# --- restore the preserved /writable partition into the base -----------------
if [ -n "$preserved_hda4" ] && [ -s "$preserved_hda4" ]; then
    say "Restoring preserved /writable (hda4) into the synthetic base"
    dd if="$preserved_hda4" of="$SYNTHETIC_DISK" bs=$SECTOR \
        seek="$HDA4_START" count="$HDA4_SECTORS" conv=notrunc status=none
    rm -f "$preserved_hda4"
fi

# --- run the ordered patch pipeline (rootfs only) ----------------------------
if [ "$patch_needed" = 1 ]; then
    say "Rootfs patches needed: $reason"
    for patch in "$PATCHES_DIR"/*.sh; do
        [ -f "$patch" ] || continue
        say "running patch: $(basename "$patch")"
        QCOW="$PERSISTENT_DISK" WORK="$WORK" bash "$patch" "$SIGN_CERT_DIR"
    done
    say "Recording patch signature in $MARKER"
    printf 'rootfs=%s\nbootfs=%s\npatches=%s\n' "$rootfs_sig" "$bootfs_sig" "$patch_sig" > "$MARKER"
else
    say "Rootfs patches already current (rootfs + patch set unchanged)."
fi

if [ ! -f "$PERSISTENT_DISK" ]; then
    echo "apply-rootfs-patches: no overlay produced; aborting" >&2
    exit 1
fi

say "done — overlay prepared at $PERSISTENT_DISK"
