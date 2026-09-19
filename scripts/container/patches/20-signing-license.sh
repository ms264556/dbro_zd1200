#!/usr/bin/env bash
#
# 20-signing-license.sh — bake the ZD1200 image-signing bypass and upgrade
# entitlement into the lab VM rootfs partitions (hda2/hda3), writing the
# result into the flat disk.  Runs as a standard user: no root, no loop
# devices, no nbd, no mount.
#
# This applies the sys_wrapper.sh patch from the create_zd1200_signing_bypass
# persist.sh verbatim (it already works on real ZD boxes), minus the
# restart()/duplicate-partition persistence hook — upgrades are disabled in
# this lab, so no persist mechanism is needed.
#
# Per partition it applies:
#   1. /bin/sys_wrapper.sh — check_sign_cert() bypass (non-"script" images are
#      accepted after extracting the bundled cert), plus short-circuit cases
#      for verify-upload-support and wget-support-entitlement.  The patched
#      cases also generate /writable/etc/airespider/support-list.xml at
#      runtime (status="1") using `cat /bin/SERIAL` — a symlink to
#      /proc/v54bsp/serial, i.e. the MAC-derived serial from the board data —
#      so the record is created only when the patched function runs, with the
#      serial already set.  Original bodies are preserved under *_unpatched.
#   2. /etc/persistent-scripts/patch-storage/ — payload dir (SKIPped in
#      file_list.txt): cert.tgz, support, support.spt.
#
# No support-list.xml is pre-populated and no boot script is touched: the
# patched sys_wrapper function creates the entitlement record when the web
# UI invokes it.
#
# Usage:  ./"20-signing-license.sh" [CERT_DIR]
#
# CERT_DIR defaults to image/signing-cert, which prepare-vendor-image.sh fills
# from the ZD firmware archive.  It must contain signing_cert.pem +
# digital_sig_sha256.bin + digital_sig_sha384.bin + all_checksums.txt (packed
# into cert.tgz exactly like the create_zd1200_signing_bypass tool does).
#
# Re-patching: /bin/sys_wrapper.sh and the patch-storage payload are recorded in
# the root's /.patchrollback store by write_local, so the pristine vendor
# sys_wrapper.sh is restored before a changed patch set is re-applied (see
# scripts/container/patch-lib.sh).
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCOW="${QCOW:-$BASE/synthetic-cf.img}"
WORK="${WORK:-$BASE/.rootfs-patch-work}"
ALIGN=512
# shellcheck source=../patch-lib.sh
. "$(dirname "$BASE")/patch-lib.sh"

CERT_DIR="${1:-$(dirname "$BASE")/image/signing-cert}"

# name|start_sector|sector_count   (mirrors build-synthetic-cf.py)
PARTITIONS=(
    "hda2|84568|415152"
    "hda3|499720|415152"
)

# The cert payload (signing_cert.pem + the two digital-sig blobs +
# all_checksums.txt) only ships in the 10.2+/10.5 archives.  Releases up to
# 10.1.x/9.x have no check_sign_cert() at all -- they only expose
# verify-upload-support / wget-support-entitlement -- so the cert is not needed
# there.  Patch whatever the release has: the check_sign_cert() bypass only when
# the cert exists, the entitlement shortcuts always.
have_cert=1
for c in signing_cert.pem digital_sig_sha256.bin digital_sig_sha384.bin all_checksums.txt; do
    if [ ! -f "$CERT_DIR/$c" ]; then
        echo "note: $CERT_DIR/$c missing; the check_sign_cert() bypass will be skipped" >&2
        have_cert=0
    fi
done

rm -rf "$WORK"; mkdir -p "$WORK"

say "reading the flat disk $QCOW"
ln -sf "$QCOW" "$WORK/flat.raw"

# Pack the cert payload once (content identical on every partition).  Only
# meaningful when the release ships the cert (see above).
if [ "$have_cert" = 1 ]; then
    ( cd "$CERT_DIR" && tar -czf "$WORK/cert.tgz" . )
fi

# The sys_wrapper.sh injection, copied verbatim from persist.sh, minus the
# restart() persistence hook.  The verify-upload-support / wget-support-
# entitlement cases additionally write the runtime entitlement record
# /writable/etc/airespider/support-list.xml with status="1" and the serial
# from /bin/SERIAL (symlink -> /proc/v54bsp/serial, i.e. the board-data /
# MAC-derived serial).  `date +%s` keeps the start date fresh on each boot.
cat > "$WORK/sys_wrapper-cert.sed" <<'SEDEOF'
/check_sign_cert() {/a \
    if [ "$2" = "script" ] ; then\
       check_sign_cert_unpatched "$1" "$2" "$3"\
    else\
        local cur_dir=`pwd`\
        local tmp_img_dir=\/tmp\/bin_img_sig\
        mkdir -p $tmp_img_dir\
        cd $tmp_img_dir\
        cat \/etc\/persistent-scripts\/patch-storage\/cert.tgz | gunzip | tar x\
        echo "Have signed"\
        sync\
        cd $cur_dir\
    fi\
}\
check_sign_cert_unpatched() {
SEDEOF
cat > "$WORK/sys_wrapper-entitlement.sed" <<'SEDEOF'
/verify-upload-support)/a \
        cd \/tmp\
        cat \/etc\/persistent-scripts\/patch-storage\/support > support\
        mkdir -p \/writable\/etc\/airespider\
        cat > \/writable\/etc\/airespider\/support-list.xml <<SUPPORT_EOF\
<support-list status="1">\
	<support zd-serial-number="`cat \/bin\/SERIAL`" service-purchased="904" date-start="`date +%s`" date-end="2145916799" ap-support-number="licensed" DELETABLE="false"></support>\
</support-list>\
SUPPORT_EOF\
        echo "OK"\
        ;;\
    verify-upload-support-unpatched)
/wget-support-entitlement)/a \
        cat \/etc\/persistent-scripts\/patch-storage\/support\.spt > "\/tmp\/$1"\
        mkdir -p \/writable\/etc\/airespider\
        cat > \/writable\/etc\/airespider\/support-list.xml <<SUPPORT_EOF\
<support-list status="1">\
	<support zd-serial-number="`cat \/bin\/SERIAL`" service-purchased="904" date-start="`date +%s`" date-end="2145916799" ap-support-number="licensed" DELETABLE="false"></support>\
</support-list>\
SUPPORT_EOF\
        echo "OK"\
        ;;\
    wget-support-entitlement-unpatched)
SEDEOF
# The check_sign_cert() bypass needs the cert payload; the entitlement
# shortcuts do not, so keep them independent of a release that has no cert.
: > "$WORK/sys_wrapper.sed"
if [ "$have_cert" = 1 ]; then
    cat "$WORK/sys_wrapper-cert.sed" >> "$WORK/sys_wrapper.sed"
fi
cat "$WORK/sys_wrapper-entitlement.sed" >> "$WORK/sys_wrapper.sed"

patched_any=0
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    say "[$name] extracting partition (sector $start, ${sectors}s)"
    extract_part "$name" "$start" "$sectors"
    snapshot_orig "$name"
    IMG="$WORK/$name.img"
    pr_init "$IMG"

    part_changed=0

    # ---- 1. /bin/sys_wrapper.sh ----
    say "[$name] patching /bin/sys_wrapper.sh"
    if ! fs_read "$IMG" /bin/sys_wrapper.sh "$WORK/sys_wrapper.orig"; then
        echo "  ! /bin/sys_wrapper.sh not present, skipping partition" >&2
        continue
    fi
    # Either marker proves the sed already ran: the entitlement shortcuts always
    # insert theirs, and check_sign_cert() inserts its own on cert-bearing
    # releases.  The pipeline restores the pristine file before it re-applies a
    # changed set, so this is a belt-and-braces check for a direct run.
    if grep -q '^verify-upload-support-unpatched)' "$WORK/sys_wrapper.orig" \
       || grep -q '^check_sign_cert_unpatched()' "$WORK/sys_wrapper.orig"; then
        echo "  /bin/sys_wrapper.sh already patched (nothing to do)"
    else
        sed -f "$WORK/sys_wrapper.sed" "$WORK/sys_wrapper.orig" > "$WORK/sys_wrapper.new"
        diff -u "$WORK/sys_wrapper.orig" "$WORK/sys_wrapper.new" | sed 's/^/    /' || true
        write_local "$IMG" /bin/sys_wrapper.sh "$WORK/sys_wrapper.new"
        part_changed=1
    fi

    # ---- 2. /etc/persistent-scripts/patch-storage/ payload ----
    # support is baked from the persist.sh template (serial left empty here;
    # the patched sys_wrapper cases regenerate the entitlement record with
    # the runtime /bin/SERIAL when invoked).
    say "[$name] writing /etc/persistent-scripts/patch-storage/ payload"
    cat > "$WORK/support" <<'EOF'
<support-list>
	<support zd-serial-number="" service-purchased="904" date-start="1698771540" date-end="1856624340" ap-support-number="licensed" DELETABLE="false"></support>
</support-list>
EOF
    ( cd "$WORK" && tar -czf support.spt support )

    mkdir_p "$IMG" /etc/persistent-scripts/patch-storage
    storage_files=(support support.spt)
    [ "$have_cert" = 1 ] && storage_files+=(cert.tgz)
    for f in "${storage_files[@]}"; do
        write_local "$IMG" "/etc/persistent-scripts/patch-storage/$f" "$WORK/$f"
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

say "patched content spot-checks (hda2):"
echo "--- /bin/sys_wrapper.sh (patched anchors) ---"
debugfs -R "cat /bin/sys_wrapper.sh" "$WORK/hda2.verify.img" 2>/dev/null | grep -n -E "check_sign_cert_unpatched|verify-upload-support-unpatched|wget-support-entitlement-unpatched|Have signed|support-list.xml" | head
echo "--- patch-storage payload ---"
debugfs -R "ls -l /etc/persistent-scripts/patch-storage" "$WORK/hda2.verify.img" 2>/dev/null | grep -v "^debugfs"

say "done — signing bypass + upgrade entitlement baked into $QCOW"
