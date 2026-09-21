#!/usr/bin/env bash
#
# 20-signing-license.sh — bake the ZD1200 image-signing bypass and upgrade
# entitlement into the lab VM rootfs partitions (hda2/hda3), writing the
# result into the flat disk.  Runs as a standard user: no root, no loop
# devices, no nbd, no mount.
#
# This applies the sys_wrapper.sh patch from the create_zd1200_signing_bypass
# persist.sh verbatim (it already works on real ZD boxes), minus its
# restart()/duplicate-partition persistence hook: prepare-vm-disks.sh
# re-customises an upgraded root from its rollback store on the next container
# start, so the bypass does not persist itself.
#
# Per partition it applies:
#   1. /bin/sys_wrapper.sh — check_sign_cert() bypass (non-"script" images are
#      accepted after extracting the bundled cert), plus short-circuit cases
#      for verify-upload-support and wget-support-entitlement.  The patched
#      verify-upload-support generates, at runtime, both the entitlement file
#      /tmp/support that emfd's checkSupport() parses and the record
#      /writable/etc/airespider/support-list.xml (status="1"), each carrying the
#      serial read from /bin/SERIAL — a symlink to /proc/v54bsp/serial, i.e. the
#      serial from the board data.  The serial cannot be baked at patch time: it
#      is derived from the appliance's own MAC, so a fixed value (or an empty
#      one) is rejected with E_InvalidSerialNumber.  Original bodies are
#      preserved under *_unpatched.
#   2. /etc/persistent-scripts/patch-storage/ — payload dir (SKIPped in
#      file_list.txt): cert.tgz, support, support.spt.
#   3. /etc/init.d/S48zd_ntp_result — seeds /tmp/ntp_result, the NTP-sync marker
#      the upgrade verifier requires before it will look at an image.  The
#      entitlement checks are bypassed above, but the vendor still gates on this
#      marker, which a real box creates from its NTP/entitlement flow and the
#      emulated box does not.
#
# No support-list.xml is pre-populated: the patched sys_wrapper function creates
# the entitlement record when the web UI invokes it.  The one boot script is the
# NTP-marker nudge above.
#
# Usage:  ./"20-signing-license.sh" [CERT_DIR]
#
# CERT_DIR defaults to image/signing-cert, which prepare-vendor-image.sh fills
# from the ZD firmware archive.  It must contain signing_cert.pem +
# digital_sig_sha256.bin + digital_sig_sha384.bin + all_checksums.txt (packed
# into cert.tgz exactly like the create_zd1200_signing_bypass tool does).
#
# Re-patching: /bin/sys_wrapper.sh, the patch-storage payload and
# /etc/init.d/S48zd_ntp_result are recorded in the root's /.patchrollback store by
# write_local, so the pristine vendor sys_wrapper.sh is restored before a changed
# patch set is re-applied (see scripts/container/patch-lib.sh).
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCOW="${QCOW:-$BASE/synthetic-cf.img}"
WORK="${WORK:-$BASE/.rootfs-patch-work}"
ALIGN=512
# shellcheck source=../patch-lib.sh
. "$(dirname "$BASE")/patch-lib.sh"

CERT_DIR="${1:-$(dirname "$BASE")/image/signing-cert}"

# The roots this run may touch: prepare-vm-disks.sh passes its per-root
# selection in ZD_PATCH_PARTS; with none set this is the full root pair
# (patch-lib.sh:patch_parts), which is how the patch tests drive it.
load_patch_parts

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
# from /bin/SERIAL (symlink -> /proc/v54bsp/serial, i.e. the board-data serial).
# `date +%s` keeps the start date fresh on each boot.
#
# verify-upload-support must also serve the entitlement FILE the vendor's own
# parser reads, /tmp/support, and that parser demands the appliance's serial:
# emfd's checkSupport() loads /tmp/support and requires each <support> child's
# zd-serial-number to equal the contents of /bin/SERIAL (the only other value it
# accepts is the literal "*").  Copying the archived payload there cannot work,
# because that payload is a template whose serial is empty -- the upgrade then
# fails with E_InvalidSerialNumber.  So build /tmp/support here, at run time,
# which is the only place the serial is known.  Same for the record.
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
        SERIAL=`cat \/bin\/SERIAL`\
        cat > support <<SUPPORT_EOF\
<support-list>\
	<support zd-serial-number="$SERIAL" service-purchased="904" date-start="`date +%s`" date-end="2145916799" ap-support-number="licensed" DELETABLE="false"></support>\
</support-list>\
SUPPORT_EOF\
        mkdir -p \/writable\/etc\/airespider\
        cat > \/writable\/etc\/airespider\/support-list.xml <<SUPPORT_EOF\
<support-list status="1">\
	<support zd-serial-number="$SERIAL" service-purchased="904" date-start="`date +%s`" date-end="2145916799" ap-support-number="licensed" DELETABLE="false"></support>\
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

# The upgrade verifier's NTP marker (see the header).  Generated once and
# installed on every partition in the loop below.
cat > "$WORK/S48zd_ntp_result" <<'ZD_NTP_RESULT'
#!/bin/sh
# S48zd_ntp_result -- seed /tmp/ntp_result so an in-guest firmware upgrade can
# run on the emulated box.
#
# The vendor refuses an upgrade unless /tmp/ntp_result exists:
#   sys_wrapper.sh verify-upgrade : [ ! -e /tmp/ntp_result ] -> E_FailUpgradeNTP
#   emfd's upgrade command checks the same file.
# It is the cached result of an NTP sync -- startNtpd() writes "OK" or "FAIL" --
# which a real appliance produces as part of its NTP / Support-Entitlement flow.
# The emulated box runs no such flow, so on a stock container `fw_upgrade` dies
# with E_FailUpgradeNTP before it verifies anything.
#
# Patch 20 bypasses the entitlement checks themselves; this keeps the
# prerequisite they gate on satisfied by attempting the same sync.  Only the
# file's existence is ever checked, so the vendor's own "FAIL" result is fine --
# exactly as on a real box that cannot reach its NTP server at that moment.
(
    /bin/sys_wrapper.sh start-ntpd ntp.ruckuswireless.com >/dev/null 2>&1
    [ -e /tmp/ntp_result ] || echo FAIL > /tmp/ntp_result
) &
exit 0
ZD_NTP_RESULT
chmod 755 "$WORK/S48zd_ntp_result"

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
    # support is the archived persist.sh template, kept as the on-disk template
    # for the support.spt payload.  Its serial is empty and stays empty: the
    # patched sys_wrapper cases generate /tmp/support from it at runtime, with
    # the serial read from /bin/SERIAL (see the header).  Nothing serves this
    # file to the vendor parser as-is.
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

    # ---- 3. /etc/init.d/S48zd_ntp_result ----
    say "[$name] installing /etc/init.d/S48zd_ntp_result"
    write_local "$IMG" /etc/init.d/S48zd_ntp_result "$WORK/S48zd_ntp_result" 0755
    part_changed=1

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

say "patched content spot-checks ($(basename "$(spot_img)" .verify.img)):"
echo "--- /bin/sys_wrapper.sh (patched anchors) ---"
debugfs -R "cat /bin/sys_wrapper.sh" "$(spot_img)" 2>/dev/null | grep -n -E "check_sign_cert_unpatched|verify-upload-support-unpatched|wget-support-entitlement-unpatched|Have signed|support-list.xml" | head || true
echo "--- patch-storage payload ---"
debugfs -R "ls -l /etc/persistent-scripts/patch-storage" "$(spot_img)" 2>/dev/null | grep -v "^debugfs" || true
echo "--- /etc/init.d/S48zd_ntp_result (upgrade NTP marker hook) ---"
debugfs -R "cat /etc/init.d/S48zd_ntp_result" "$(spot_img)" 2>/dev/null | grep -n -E "start-ntpd|ntp_result" | head || true

say "done — signing bypass + upgrade entitlement baked into $QCOW"
