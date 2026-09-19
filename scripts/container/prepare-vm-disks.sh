#!/usr/bin/env bash
#
# prepare-vm-disks.sh — build the guest disk and (re)apply the kernel + rootfs
# customisations to the root partitions that need them.
#
# FLAT model: the synthetic CF image ($SYNTHETIC_DISK) *is* the live disk — there
# is no qcow2 overlay.  Each root partition carries a rollback store,
# /.patchrollback/, holding the signature of the patch set applied to it and the
# pristine vendor copy of every file the patches replaced (see
# scripts/container/patch-lib.sh).  On every start we read each root's sentinel
# and customise only the roots that are missing it or were done by an older
# patch set:
#
#   * fresh disk             -> no sentinel, customise both roots
#   * patch set changed      -> sentinel mismatch, restore the vendor rootfs from
#                               the store and re-apply every patch
#   * in-guest firmware upgrade writes a new rootfs onto the spare partition ->
#     that root has no sentinel so it is customised; the untouched root is skipped
#   * a rollback leaves both roots already customised -> nothing to do
#
# Restoring before re-applying is what makes an upgrade safe: a patch that has
# been edited, or a new patch inserted in the order, always runs against the
# vendor files rather than against the output of an earlier patch set.  /writable
# (hda4) is never involved.
#
# The kernel is deliberately NOT in the rollback store: it is the largest file
# and its transform is deterministic, so /bzImage is keyed on the hash of
# patch-kernel.py instead (/.patchrollback/kernel).  A root already patched by
# the same patcher is left alone.
#
# Env (all optional, defaults shown):
#   STATE_DIR        scratch/state dir            ($BASE; entrypoint passes /var/lib/zd1200)
#   SYNTHETIC_DISK   the CF image (the live disk) ($STATE_DIR/synthetic-cf.img)
#   WORK             patch scratch dir            ($STATE_DIR/.rootfs-patch-work)
#   IMAGE_DIR/ROOTFS vendor artifacts             ($BASE/image, $IMAGE_DIR/rootfs.ext2)
#   PATCHES_DIR      the ordered patches          ($BASE/patches)
#   ZD_SERIAL ZD_MAC1 ZD_MODEL ZD_CUSTOMER        board data (written when the disk is built)
#   ZD_SIGN_CERT_DIR payload for the license/signing patch
#   ZD_ALLOW_DISK_REBUILD=1  allow a rebuild that discards /writable
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-$BASE}"
DISK="${SYNTHETIC_DISK:-$STATE_DIR/synthetic-cf.img}"
WORK="${WORK:-$STATE_DIR/.rootfs-patch-work}"
IMAGE_DIR="${IMAGE_DIR:-$BASE/image}"
ROOTFS="${ROOTFS:-$IMAGE_DIR/rootfs.ext2}"
BOOTFS_SRC="${BOOTFS_SRC:-$IMAGE_DIR/restoreinitramfs.gz}"
PATCHES_DIR="${PATCHES_DIR:-$BASE/patches}"
# External payload installed by the ordered patches (the Network Monitor page,
# its guest shell collectors and the compiled i386 helpers).  It is part of the
# patch signature below so a rebuilt image with changed files re-customises the
# roots instead of serving a stale page.
ANALYTICS_DIR="${ANALYTICS_DIR:-$BASE/analytics}"
# Optional static dropbear replacement payload (dropbear/) and the public key it
# installs.  Both are folded into the signature so enabling/disabling the
# feature or rotating the key re-customises the roots.
DROPBEAR_DIR="${DROPBEAR_DIR:-$BASE/dropbear}"
ZD_ROOT_SSH_AUTHORIZED_KEYS="${ZD_ROOT_SSH_AUTHORIZED_KEYS:-/opt/zd1200/dropbear-provision/authorized_keys}"
# Optional ECDSA host key for the administrative SSH service (patch 80).
ZD_ECDSA_SSH="${ZD_ECDSA_SSH:-1}"
# Optional Network Monitor page + collectors (patch 50); 0 installs nothing.
ZD_NETWORK_MONITOR="${ZD_NETWORK_MONITOR:-1}"
MARKER="${MARKER:-$STATE_DIR/.disk-built}"
SIGN_CERT_DIR="${ZD_SIGN_CERT_DIR:-/opt/zd1200/signing-cert}"

SECTOR=512
ALIGN=$SECTOR
# shellcheck source=patch-lib.sh
. "$BASE/patch-lib.sh"
# patch-lib.sh's partition helpers use $QCOW; here the flat disk is $DISK.
QCOW="$DISK"
# The pre-rollback pipeline's sentinel.  Its presence means the root was
# customised before /.patchrollback existed, so there is no pristine copy to
# restore from; that combination is refused rather than silently re-patching an
# already-patched rootfs.
LEGACY_SENTINEL=/etc/.zd-image

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
# The vendor inputs that identify the firmware on the disk: the rootfs and the
# boot files.  Only these decide a rebuild — not the scripts that consume them —
# so a project update cannot make an existing appliance look like it needs its
# whole disk (and /writable) rebuilt.
vendor_sig="$(sha256sum "$ROOTFS" "$BOOTFS_SRC" "$IMAGE_DIR/menu.lst" \
    "$IMAGE_DIR/restoreinitramfs.ver" "$IMAGE_DIR/bzImage" | sha256sum | awk '{print $1}')"
kernel_sig="$(sha256sum "$BASE/patch-kernel.py" | awk '{print $1}')"
patch_sig="$( {
    cd "$PATCHES_DIR" && for f in *.sh; do [ -f "$f" ] || continue; \
        printf '%s ' "$f"; sha256sum "$f" | awk '{print $1}'; done | sha256sum | awk '{print $1}'
    printf 'patch-lib=%s\n' "$(sha256sum "$BASE/patch-lib.sh" | awk '{print $1}')"
    printf 'patch-kernel=%s\n' "$kernel_sig"
    printf 'rollback-format=%s\n' "$PR_FORMAT"
    if [ -d "$ANALYTICS_DIR" ]; then
        ( cd "$ANALYTICS_DIR" && find . -type f -print | LC_ALL=C sort | while read -r f; do
              printf '%s ' "$f"; sha256sum "$f" | awk '{print $1}'
          done ) | sha256sum | awk '{print $1}'
    fi
    printf 'ZD_VIRTUAL_BUILD_ID=%s\n' "${ZD_VIRTUAL_BUILD_ID:-}"
    if [ -d "$DROPBEAR_DIR" ]; then
        ( cd "$DROPBEAR_DIR" && find . -type f -print | LC_ALL=C sort | while read -r f; do
              printf '%s ' "$f"; sha256sum "$f" | awk '{print $1}'
          done ) | sha256sum | awk '{print $1}'
    fi
    if [ -r "$ZD_ROOT_SSH_AUTHORIZED_KEYS" ]; then
        printf 'ZD_ROOT_SSH_KEY=%s\n' "$(sha256sum "$ZD_ROOT_SSH_AUTHORIZED_KEYS" | awk '{print $1}')"
    else
        printf 'ZD_ROOT_SSH_KEY=unreadable\n'
    fi
    printf 'ZD_ECDSA_SSH=%s\n' "$ZD_ECDSA_SSH"
    printf 'ZD_NETWORK_MONITOR=%s\n' "$ZD_NETWORK_MONITOR"
    printf 'ZD_PING_INTERVAL_SECONDS=%s\n' "${ZD_PING_INTERVAL_SECONDS:-}"
    printf 'ZD_PING_CLIENT_TARGETS=%s\n' "${ZD_PING_CLIENT_TARGETS:-}"
} | sha256sum | awk '{print $1}')"

# --- (re)build the disk when missing or the base firmware changed ------------
rebuild=0; reason=""
if [ ! -f "$DISK" ]; then
    rebuild=1; reason="no disk yet"
else
    stored_rootfs=""; stored_vendor=""
    if [ -f "$MARKER" ]; then
        stored_rootfs="$(sed -n 's/^rootfs=//p' "$MARKER")"
        stored_vendor="$(sed -n 's/^vendor=//p' "$MARKER")"
    fi
    # stale_rootfs is written by every version; vendor= only by this one, so an
    # existing marker without it is compared on the rootfs alone (its boot files
    # are not part of the decision and must not trigger a rebuild).
    if   [ "$stored_rootfs" != "$rootfs_sig" ]; then rebuild=1; reason="base rootfs changed"
    elif [ -n "$stored_vendor" ] && [ "$stored_vendor" != "$vendor_sig" ]; then
        rebuild=1; reason="vendor boot files changed"
    fi
fi
if [ "$rebuild" = 1 ]; then
    # Rebuilding replaces the whole CF image, including /writable — i.e. the
    # appliance's configuration.  Never do that to an existing appliance by
    # accident: it must be asked for explicitly (a factory reset), because the
    # whole point of the rollback store is to upgrade without it.
    if [ "$reason" != "no disk yet" ] && [ -f "$DISK" ] \
       && [ "${ZD_ALLOW_DISK_REBUILD:-0}" != "1" ]; then
        cat >&2 <<EOF
prepare-vm-disks: the base firmware changed ($reason) and rebuilding the
synthetic CF would discard /writable (the appliance's configuration).
Refusing to rebuild an existing appliance.

  * To upgrade the project's patches/firmware tooling, keep image/ unchanged and
    re-run the installer with --upgrade (this only re-customises the roots).
  * To accept a factory reset and rebuild from $IMAGE_DIR, remove the state
    (Docker: docker compose --project-directory . -f docker/docker-compose.yml down -v;
     Proxmox: pct exec <id> -- rm -rf $STATE_DIR) or set ZD_ALLOW_DISK_REBUILD=1.
EOF
        exit 1
    fi
    say "Building the synthetic CF disk — $reason"
    rm -f "$DISK"
    SYNTHETIC_DISK="$DISK" ZD_R600_REPAIR="${ZD_R600_REPAIR:-1}" \
        python3 "$BASE/build-synthetic-cf.py"
    say "Writing board data (serial=${ZD_SERIAL:-123456000789}, MAC1=${ZD_MAC1:-00:0c:e6:12:00:01})"
    python3 "$BASE/write-boarddata.py" --disk "$DISK" \
        --serial "${ZD_SERIAL:-123456000789}" --mac "${ZD_MAC1:-00:0c:e6:12:00:01}" \
        --model "${ZD_MODEL:-ZD1200}" --customer "${ZD_CUSTOMER:-ruckus}"
    printf 'rootfs=%s\nvendor=%s\n' "$rootfs_sig" "$vendor_sig" > "$MARKER"
fi

# --- repair the writable data partition if the last stop was not clean ------
# The stock firmware mounts /writable (hda4) read-write, and the container can be
# stopped without a clean guest shutdown.  The vendor's factory-restore path
# fsck'd that partition before mounting it; this fork boots the stock kernel
# directly, so do it here, offline, before QEMU starts.
#
# The filesystem depends on where the image came from: a firmware-archive build
# creates a legacy ext2 (no journal), while a CF-dump build carries the
# appliance's own reiserfs.  Handle each on its own terms:
#   * ext2   -> e2fsck, gated on the superblock clean flag (offset 1024+58,
#               1 = clean, which the kernel sets to "errors" (2) on damage), so
#               a clean start pays only a two-byte read;
#   * reiserfs -> leave it alone: it is journaled and the guest kernel (which
#               has reiserfs built in) replays the journal on mount.
hda4_ext2_magic="$(dd if="$DISK" bs=1 skip=$((HDA4_START * SECTOR + 1080)) count=2 status=none 2>/dev/null \
    | od -An -tx1 | tr -d ' ')"
# 'tr -d "\0"' keeps bash from warning that it dropped null bytes from the
# command substitution; only the ASCII magic is compared.
hda4_reiser_magic="$(dd if="$DISK" bs=1 skip=$((HDA4_START * SECTOR + 0x10034)) count=9 status=none 2>/dev/null | tr -d '\0')"
if [ "$hda4_ext2_magic" = "53ef" ]; then
    hda4_state="$(dd if="$DISK" bs=1 skip=$((HDA4_START * SECTOR + 1024 + 58)) count=2 status=none 2>/dev/null \
        | od -An -tu2 | tr -d ' ')"
    if [ "$hda4_state" != "1" ]; then
        say "data partition (hda4) is not clean (superblock state=${hda4_state:-unknown}); running e2fsck"
        hda4_tmp="$STATE_DIR/.hda4-fsck.img"
        dd if="$DISK" of="$hda4_tmp" bs=$SECTOR skip="$HDA4_START" count="$HDA4_SECTORS" status=none
        hda4_rc=0
        e2fsck -fy "$hda4_tmp" || hda4_rc=$?
        if [ "$hda4_rc" -ge 4 ]; then
            echo "prepare-vm-disks: WARNING: e2fsck could not fully repair hda4 (rc=$hda4_rc)" >&2
        fi
        dd if="$hda4_tmp" of="$DISK" bs=$SECTOR seek="$HDA4_START" count="$HDA4_SECTORS" conv=notrunc status=none
        rm -f "$hda4_tmp"
    fi
elif [ "$hda4_reiser_magic" = "ReIsEr2Fs" ]; then
    say "data partition (hda4) is reiserfs (journaled); the guest kernel replays its journal"
else
    say "data partition (hda4) has no recognized filesystem (ext2 magic '$hda4_ext2_magic'); skipping repair"
fi

# --- helpers ----------------------------------------------------------------
is_ext2()  { [ "$(dd if="$1" bs=1 skip=1080 count=2 status=none 2>/dev/null \
                  | od -An -tx1 | tr -d ' ')" = "53ef" ]; }
sentinel_of()        { debugfs -R "cat $PR_SENTINEL" "$1" 2>/dev/null | head -n1; }
legacy_sentinel_of() { debugfs -R "cat $LEGACY_SENTINEL" "$1" 2>/dev/null | head -n1; }

# apply_kernel <name>: leave the root's own /bzImage carrying the QEMU patches,
# recording which kernel patcher did it.  Idempotent by marker, because
# patch-kernel.py's signatures describe the *stock* bytes and cannot recognise an
# already-patched kernel.
apply_kernel() {
    local name="$1" img="$WORK/$name.img" have=""
    have="$(debugfs -R "cat $PR_KERNEL" "$img" 2>/dev/null | head -n1 || true)"
    if [ "$have" = "$kernel_sig" ]; then
        say "[$name] /bzImage already carries the QEMU patches; leaving it"
        return 0
    fi
    say "[$name] applying the QEMU kernel patch"
    # The vendor install drops the archive kernel at /bzImage in the root it
    # writes; a guest firmware upgrade drops *its* kernel there.  Patch whatever
    # kernel the root already carries, and install the archive kernel only when a
    # root has none at all.
    if ! fs_read "$img" /bzImage "$WORK/$name.kernel"; then
        say "[$name] no /bzImage in this root; installing the archive kernel"
        cp "$IMAGE_DIR/bzImage" "$WORK/$name.kernel"
    fi
    rm -f "$WORK/$name.kernel.patched"
    if ! python3 "$BASE/patch-kernel.py" --in "$WORK/$name.kernel" \
            --out "$WORK/$name.kernel.patched" >"$WORK/$name.patch-kernel.log" 2>&1; then
        echo "prepare-vm-disks: the kernel patcher failed for $name:" >&2
        tail -25 "$WORK/$name.patch-kernel.log" >&2 || true
        exit 1
    fi
    if [ -s "$WORK/$name.kernel.patched" ] \
       && ! cmp -s "$WORK/$name.kernel" "$WORK/$name.kernel.patched"; then
        debugfs -w -R "rm /bzImage" "$img" 2>/dev/null || true
        debugfs -w -R "write $WORK/$name.kernel.patched /bzImage" "$img"
        say "[$name] /bzImage patched"
    else
        say "[$name] /bzImage already carries the QEMU patches; leaving it"
    fi
    printf '%s\n' "$kernel_sig" > "$WORK/kernel.sig"
    fs_write "$img" "$PR_KERNEL" "$WORK/kernel.sig" 0644 0 0
}

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
        continue
    fi
    if ! pr_has_store "$WORK/$name.img" && [ -n "$(legacy_sentinel_of "$WORK/$name.img")" ]; then
        cat >&2 <<EOF
prepare-vm-disks: [$name] was customised by an older version of this project
(sentinel $LEGACY_SENTINEL) and has no /.patchrollback store, so the pristine
vendor files cannot be restored before re-applying the changed patch set.

This build cannot upgrade that rootfs in place.  Reset the state and install
again from a firmware image (Docker: docker compose --project-directory .
-f docker/docker-compose.yml down -v; Proxmox: pct exec <id> -- rm -rf $STATE_DIR
then re-run the installer).
EOF
        exit 1
    fi
    if pr_has_store "$WORK/$name.img"; then
        # The patch set changed: put the vendor files back first, so every patch
        # runs against the rootfs it was written for.
        say "[$name] patch set changed (sentinel: ${have:-<none>}); restoring the vendor rootfs"
        snapshot_orig "$name"
        pr_reset "$WORK/$name.img"
        write_deltas "$name" "$start" || true
    else
        say "[$name] needs customising (sentinel: ${have:-<none>})"
    fi
    patch_parts+=("$part")
done

if [ ${#patch_parts[@]} -eq 0 ]; then
    say "every root partition is already customised; nothing to do"
    exit 0
fi

# --- apply the QEMU kernel patch and seed the store on each such root --------
for part in "${patch_parts[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    extract_part "$name" "$start" "$sectors"
    snapshot_orig "$name"
    pr_init "$WORK/$name.img"
    apply_kernel "$name"
    write_deltas "$name" "$start" || true
done

# --- run the ordered customisation patches (they read/rewrite the flat disk) -
for patch in "$PATCHES_DIR"/*.sh; do
    [ -f "$patch" ] || continue
    say "running patch: $(basename "$patch")"
    QCOW="$DISK" WORK="$WORK" ANALYTICS_DIR="$ANALYTICS_DIR" \
        DROPBEAR_DIR="$DROPBEAR_DIR" \
        ZD_ROOT_SSH_AUTHORIZED_KEYS="$ZD_ROOT_SSH_AUTHORIZED_KEYS" \
        ZD_ECDSA_SSH="$ZD_ECDSA_SSH" \
        ZD_NETWORK_MONITOR="$ZD_NETWORK_MONITOR" \
        ZD_VIRTUAL_BUILD_ID="${ZD_VIRTUAL_BUILD_ID:-}" \
        ZD_PING_INTERVAL_SECONDS="${ZD_PING_INTERVAL_SECONDS:-}" \
        ZD_PING_CLIENT_TARGETS="${ZD_PING_CLIENT_TARGETS:-}" \
        bash "$patch" "$SIGN_CERT_DIR"
done

# --- stamp each customised root with the sentinel ---------------------------
for part in "${patch_parts[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    extract_part "$name" "$start" "$sectors"
    snapshot_orig "$name"
    pr_init "$WORK/$name.img"
    printf '%s\n' "$patch_sig" > "$WORK/sentinel.$name"
    fs_write "$WORK/$name.img" "$PR_SENTINEL" "$WORK/sentinel.$name" 0644 0 0
    # Drop the old pipeline's sentinel if this root somehow carries one.
    debugfs -w -R "rm $LEGACY_SENTINEL" "$WORK/$name.img" >/dev/null 2>&1 || true
    write_deltas "$name" "$start" || true
    say "[$name] sentinel written"
done

say "done — customised roots: ${patch_parts[*]}"
