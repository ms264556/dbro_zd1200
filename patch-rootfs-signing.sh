#!/usr/bin/env bash
#
# patch-rootfs-signing.sh — bake the ZD1200 image-signing bypass and upgrade
# entitlement into the lab VM rootfs partitions (hda2/hda3), writing the
# result into the qcow2 overlay only.  Runs as a standard user: no root, no
# loop devices, no nbd, no mount.
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
#   3. /file_list.txt — MD5 entry refreshed for ./bin/sys_wrapper.sh only
#      (patch-storage files are under SKIP and need none).
#
# No support-list.xml is pre-populated and no boot script is touched: the
# patched sys_wrapper function creates the entitlement record when the web
# UI invokes it.
#
# Usage:  ./patch-rootfs-signing.sh [CERT_DIR]
#
# CERT_DIR defaults to the create_zd1200_signing_bypass cert directory and
# must contain signing_cert.pem + digital_sig_sha256.bin +
# digital_sig_sha384.bin + all_checksums.txt (they are packed into cert.tgz
# exactly like 1_generate_cert_uu.sh does).
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCOW="${QCOW:-$BASE/zd1200-vm.qcow2}"
WORK="${WORK:-$BASE/.rootfs-patch-work}"
ALIGN=512

CERT_DIR="${1:-$HOME/dev/ms264556.net/scripts/create_zd1200_signing_bypass/cert}"

# name|start_sector|sector_count   (mirrors make-synthetic-cf.py / patch-rootfs.sh)
PARTITIONS=(
    "hda2|329728|327680"
    "hda3|657408|327680"
)

for c in signing_cert.pem digital_sig_sha256.bin digital_sig_sha384.bin all_checksums.txt; do
    [ -f "$CERT_DIR/$c" ] || { echo "missing $CERT_DIR/$c (set CERT_DIR)" >&2; exit 1; }
done

rm -rf "$WORK"; mkdir -p "$WORK"

say() { printf '\n== %s\n' "$*"; }

say "flattening overlay+backing to $WORK/flat.raw"
qemu-img convert -f qcow2 -O raw "$QCOW" "$WORK/flat.raw"

# Pack the cert payload once (content identical on every partition).
( cd "$CERT_DIR" && tar -czf "$WORK/cert.tgz" . )

# The sys_wrapper.sh injection, copied verbatim from persist.sh, minus the
# restart() persistence hook.  The verify-upload-support / wget-support-
# entitlement cases additionally write the runtime entitlement record
# /writable/etc/airespider/support-list.xml with status="1" and the serial
# from /bin/SERIAL (symlink -> /proc/v54bsp/serial, i.e. the board-data /
# MAC-derived serial).  `date +%s` keeps the start date fresh on each boot.
cat > "$WORK/sys_wrapper.sed" <<'SEDEOF'
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

patched_any=0
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    say "[$name] extracting partition (sector $start, ${sectors}s)"
    dd if="$WORK/flat.raw" of="$WORK/$name.img" bs=$ALIGN skip="$start" count="$sectors" status=none
    cp "$WORK/$name.img" "$WORK/$name.orig.img"

    # inode metadata preservation (debugfs rm+write resets mode/uid/gid)
    stat_meta() { debugfs -R "stat $1" "$WORK/$name.img" 2>/dev/null \
        | awk '{ for (i = 1; i <= NF; i++) {
                     if ($i == "Type:")  t = $(i+1)
                     else if ($i == "Mode:")  m = $(i+1)
                     else if ($i == "User:")  u = $(i+1)
                     else if ($i == "Group:") g = $(i+1)
                 }} END { print t, m, u, g }'; }

    replace_file() { # $1 = fspath, $2 = local new content
        local fspath="$1" local_new="$2"
        local type_old mode_old uid_old gid_old
        read -r type_old mode_old uid_old gid_old <<< "$(stat_meta "$fspath")"
        printf 'rm %s\nwrite %s %s\n' "$fspath" "$local_new" "$fspath" > "$WORK/cmds.txt"
        debugfs -w -f "$WORK/cmds.txt" "$WORK/$name.img" 2>/dev/null
        if [ "$type_old" = "regular" ]; then
            debugfs -w -R "set_inode_field $fspath mode 010$mode_old" "$WORK/$name.img" >/dev/null 2>&1 || true
        else
            echo "  !! $fspath is not a regular file; aborting" >&2; exit 1
        fi
        debugfs -w -R "set_inode_field $fspath uid $uid_old" "$WORK/$name.img" >/dev/null 2>&1 || true
        debugfs -w -R "set_inode_field $fspath gid $gid_old" "$WORK/$name.img" >/dev/null 2>&1 || true
        read -r type_new mode_new uid_new gid_new <<< "$(stat_meta "$fspath")"
        if [ "$type_old" != "$type_new" ] || [ "$mode_old" != "$mode_new" ] \
           || [ "$uid_old" != "$uid_new" ] || [ "$gid_old" != "$gid_new" ]; then
            echo "  !! inode metadata mismatch for $fspath; aborting" >&2; exit 1
        fi
    }

    # ---- 1. /bin/sys_wrapper.sh ----
    say "[$name] patching /bin/sys_wrapper.sh"
    if ! debugfs -R "dump /bin/sys_wrapper.sh $WORK/sys_wrapper.orig" "$WORK/$name.img" 2>/dev/null \
       || [ ! -s "$WORK/sys_wrapper.orig" ]; then
        echo "  ! /bin/sys_wrapper.sh not present, skipping partition" >&2
        continue
    fi
    if grep -q '^check_sign_cert_unpatched()' "$WORK/sys_wrapper.orig"; then
        echo "  /bin/sys_wrapper.sh already patched (nothing to do)"
    else
        sed -f "$WORK/sys_wrapper.sed" "$WORK/sys_wrapper.orig" > "$WORK/sys_wrapper.new"
        diff -u "$WORK/sys_wrapper.orig" "$WORK/sys_wrapper.new" | sed 's/^/    /' || true
        replace_file /bin/sys_wrapper.sh "$WORK/sys_wrapper.new"
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

    debugfs -w -R "mkdir /etc/persistent-scripts/patch-storage" "$WORK/$name.img" 2>/dev/null || true
    : > "$WORK/cmds2.txt"
    for f in cert.tgz support support.spt; do
        debugfs -w -R "rm /etc/persistent-scripts/patch-storage/$f" "$WORK/$name.img" >/dev/null 2>&1 || true
        printf 'write %s /etc/persistent-scripts/patch-storage/%s\n' "$WORK/$f" "$f" >> "$WORK/cmds2.txt"
    done
    debugfs -w -f "$WORK/cmds2.txt" "$WORK/$name.img" 2>/dev/null

    # ---- 3. /file_list.txt MD5 refresh (sys_wrapper.sh only) ----
    say "[$name] refreshing /file_list.txt MD5"
    debugfs -R "dump /file_list.txt $WORK/file_list.orig" "$WORK/$name.img" 2>/dev/null
    cp "$WORK/file_list.orig" "$WORK/file_list.new"
    f=./bin/sys_wrapper.sh
    debugfs -R "dump $f $WORK/md5src" "$WORK/$name.img" 2>/dev/null
    new_md5="$(md5sum "$WORK/md5src" | awk '{print $1}')"
    old_md5="$(awk -v p="$f" '$1 ~ /^FILE:/ && $2 == p { sub(/^FILE:/, "", $1); print $1 }' "$WORK/file_list.new")"
    if [ -n "$old_md5" ]; then
        sed -i "s/$old_md5/$new_md5/" "$WORK/file_list.new"
        echo "  $f: $old_md5 -> $new_md5"
    else
        echo "  ! $f not tracked in file_list.txt (nothing to refresh)"
    fi
    replace_file /file_list.txt "$WORK/file_list.new"

    # ---- delta: only changed 512-byte blocks reach the overlay ----
    say "[$name] writing changed blocks into the overlay"
    python3 - "$WORK/$name.orig.img" "$WORK/$name.img" "$ALIGN" > "$WORK/$name.runs" <<'PYEOF'
import sys
orig = open(sys.argv[1], 'rb').read()
new  = open(sys.argv[2], 'rb').read()
al   = int(sys.argv[3])
assert len(orig) == len(new), "partition size changed"
blocks = [i for i in range(0, len(orig), al) if orig[i:i + al] != new[i:i + al]]
runs = []
for b in blocks:
    if runs and b == runs[-1][1]:
        runs[-1] = (runs[-1][0], b + al)
    else:
        runs.append((b, b + al))
for s, e in runs:
    print(s, e - s)
PYEOF

    if [ ! -s "$WORK/$name.runs" ]; then
        echo "  no byte changes (already patched in overlay?)"
        continue
    fi
    abs_start=$((start * ALIGN))
    while read -r off len; do
        dd if="$WORK/$name.img" of="$WORK/chunk.bin" bs=$ALIGN \
           skip=$((off / ALIGN)) count=$((len / ALIGN)) status=none
        abs_off=$((abs_start + off))
        echo "  qemu-io: $len bytes at offset $abs_off"
        qemu-io -f qcow2 -c "write -s $WORK/chunk.bin $abs_off $len" "$QCOW" >/dev/null
    done < "$WORK/$name.runs"
    patched_any=1
done

if [ "$patched_any" = 0 ]; then
    say "no patch produced changes; nothing was written to the overlay"
    exit 0
fi

say "verifying: re-flattening overlay and comparing each partition"
qemu-img convert -f qcow2 -O raw "$QCOW" "$WORK/flat.verify.raw"
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    dd if="$WORK/flat.verify.raw" of="$WORK/$name.verify.img" bs=$ALIGN \
       skip="$start" count="$sectors" status=none
    if cmp -s "$WORK/$name.verify.img" "$WORK/$name.img"; then
        echo "OK   $name: overlay now matches the patched partition image"
    else
        echo "FAIL $name: overlay does not match the patched partition image" >&2
        exit 1
    fi
done

say "patched content spot-checks (hda2):"
echo "--- /bin/sys_wrapper.sh (patched anchors) ---"
debugfs -R "cat /bin/sys_wrapper.sh" "$WORK/hda2.verify.img" 2>/dev/null | grep -n -E "check_sign_cert_unpatched|verify-upload-support-unpatched|wget-support-entitlement-unpatched|Have signed|support-list.xml" | head
echo "--- patch-storage payload ---"
debugfs -R "ls -l /etc/persistent-scripts/patch-storage" "$WORK/hda2.verify.img" 2>/dev/null | grep -v "^debugfs"
echo "--- file_list.txt sys_wrapper entry ---"
debugfs -R "cat /file_list.txt" "$WORK/hda2.verify.img" 2>/dev/null | grep "sys_wrapper"

say "done — signing bypass + upgrade entitlement baked into $QCOW; backing file untouched"
