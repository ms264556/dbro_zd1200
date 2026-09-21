#!/usr/bin/env bash
#
# 25-writable-license.sh — install the guest hook that reconciles a foreign
# /writable AP license list with this ZD1200.
#
# When the installer takes /writable from another ZoneDirector (--writable-from,
# e.g. a ZD1100 or ZD3000 dump), that box's license list comes with it: its
# <license-list max-ap="..."> counts that model's built-in APs (6 or 11 for a
# ZD1100, 50 or 100 for a ZD3000) plus its add-on <license> inc-ap values, and
# every <license> serial-number still names the source box.  The vendor license
# manager adds the built-in APs to the sum of the inc-ap values, so on this
# ZD1200 — 5 built-ins — the difference is silently lost, and the serials no
# longer match the box.
#
# The fix has to run in the guest: /writable is usually reiserfs, for which
# there is no userspace writer, and the guest kernel mounts it read-write.  So
# this patch installs two files into the ext2 root partitions (hda2/hda3) with
# the same read -> debugfs -> dd channel as the other rootfs patches, and never
# touches hda4 itself:
#
#   /etc/init.d/S49zd_license   the hook; rcS runs it (twice, on both roots)
#                               after sys_init has mounted /writable and before
#                               S50controller reads the license list
#   /etc/zd-license-fix.awk     the text transform (see that file's header)
#
# The hook finds the list at /etc/airespider/license-list.xml, which the vendor
# may have turned into a symlink to /etc/airespider-images/license-list.xml (and
# both of those resolve onto /writable); it rewrites through the link, never
# over it, and is idempotent by the compensating license's generated-by stamp.
# That element is also stamped DELETABLE="false" — the attribute the web UI's
# Delete button honours — so it cannot be removed by hand.  A native ZD1200 list
# already satisfies the arithmetic, so the hook is a no-op there — it only bites
# for a foreign /writable.
#
# Usage:  QCOW=<flat-disk> WORK=<workdir> ./"25-writable-license.sh"
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCOW="${QCOW:-$(dirname "$BASE")/synthetic-cf.img}"
WORK="${WORK:-$(dirname "$BASE")/.rootfs-patch-work}"
SRC_AWK="$(dirname "$BASE")/license-fix.awk"
INIT_DST=/etc/init.d/S49zd_license
AWK_DST=/etc/zd-license-fix.awk
ALIGN=512
# shellcheck source=../patch-lib.sh
. "$(dirname "$BASE")/patch-lib.sh"

# The roots this run may touch: prepare-vm-disks.sh passes its per-root
# selection in ZD_PATCH_PARTS; with none set this is the full root pair
# (patch-lib.sh:patch_parts), which is how the patch tests drive it.
load_patch_parts

[ -f "$SRC_AWK" ] || { echo "25-writable-license: $SRC_AWK missing" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"

say "reading the flat disk $QCOW"
ln -sf "$QCOW" "$WORK/flat.raw"

# The guest hook.  Constants and comments live here, not in the patch, so the
# installed file is self-describing.  Single-quoted heredoc: nothing expands.
cat > "$WORK/S49zd_license" <<'ZD_LICENSE'
#!/bin/sh
#
# S49zd_license — reconcile /writable's AP license list with this ZD1200.
#
# Installed by scripts/container/patches/25-writable-license.sh (dbro_zd1200).
#
# rcS runs this after sys_init has mounted /writable read-write and before
# S50controller reads the license list.  See the patch header for why a foreign
# /writable needs it; in short:
#
#   * every <license> serial-number is set to this box's serial (/bin/SERIAL),
#     and
#   * a compensating <license> is added so that
#         sum(inc-ap) == max-ap - 5
#     the ZD1200's built-in AP count.  It is stamped generated-by=zd1200-container
#     (a string, not a number: the field is the UI's "Sales Order Number", so a
#     token that cannot be a real order number is deliberate), so a
#     later boot finds it and leaves the element alone (only the serials are
#     re-repaired): buying a license adds its own element and raises max-ap by
#     the same amount, so the compensation must not be re-derived.  It also
#     carries DELETABLE="false", which disables the web UI's Delete button for
#     it — re-added on every boot if something strips it.
#
# A native ZD1200 list already satisfies the arithmetic, so this is a no-op
# there.  /etc/airespider/license-list.xml may be a symlink to
# /etc/airespider-images/license-list.xml, so each list is rewritten through its
# own path (following the link), never by replacing the path.
#
# Best effort: it never fails the boot.

PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

BUILTIN_AP=5
# generated-by is the UI's "Sales Order Number" column.  A non-numeric token,
# because a made-up number could collide with a real Ruckus order number.
MARKER=zd1200-container
FIX_AWK=/etc/zd-license-fix.awk
LISTS="/writable/etc/airespider/license-list.xml
/writable/etc/airespider-images/license-list.xml"

[ -r "$FIX_AWK" ] || exit 0

# sys_init's board-data rescan has usually published the serial by now; wait a
# moment if it has not.
serial=""
tries=0
while [ "$tries" -lt 10 ]; do
    serial="$(cat /bin/SERIAL 2>/dev/null)"
    [ -n "$serial" ] && break
    tries=$((tries + 1))
    sleep 1
done
if [ -z "$serial" ]; then
    echo "zd-license: board serial not available; leaving the license list alone"
    exit 0
fi

new=/tmp/zd-license.new
for list in $LISTS; do
    [ -f "$list" ] || continue
    if ! awk -v serial="$serial" -v marker="$MARKER" -v builtin="$BUILTIN_AP" \
             -f "$FIX_AWK" "$list" > "$new" 2>/dev/null; then
        echo "zd-license: cannot read $list"
        continue
    fi
    # The two names can be the same file (symlink); the transform is idempotent,
    # so the second pass computes no change and this skips it.
    if cmp -s "$new" "$list"; then
        continue
    fi
    if cat "$new" > "$list" 2>/dev/null; then
        echo "zd-license: reconciled $list (built-in APs $BUILTIN_AP, serial $serial)"
    else
        echo "zd-license: cannot write $list"
    fi
done
rm -f "$new"
exit 0
ZD_LICENSE
chmod 755 "$WORK/S49zd_license"

patched_any=0
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    say "[$name] extracting partition (sector $start, ${sectors}s)"
    extract_part "$name" "$start" "$sectors"
    snapshot_orig "$name"
    IMG="$WORK/$name.img"
    pr_init "$IMG"

    say "[$name] installing $INIT_DST"
    write_local "$IMG" "$INIT_DST" "$WORK/S49zd_license" 0755
    say "[$name] installing $AWK_DST"
    write_local "$IMG" "$AWK_DST" "$SRC_AWK" 0644

    if write_deltas "$name" "$start"; then
        patched_any=1
    else
        echo "  no byte changes for $name"
    fi
done

if [ "$patched_any" = 0 ]; then
    say "no patch produced changes; nothing written to the disk"
    exit 0
fi

say "verifying: re-reading the disk and comparing each partition"
ln -sf "$QCOW" "$WORK/flat.verify.raw"
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    dd if="$WORK/flat.verify.raw" of="$WORK/$name.verify.img" bs=$ALIGN \
       skip="$start" count="$sectors" status=none
    if cmp -s "$WORK/$name.verify.img" "$WORK/$name.img"; then
        echo "OK   $name: disk matches the patched partition image"
    else
        echo "FAIL $name: disk does not match the patched partition image" >&2
        exit 1
    fi
done

say "patched content spot-checks ($(basename "$(spot_img)" .verify.img)):"
echo "--- $INIT_DST ---"
debugfs -R "cat $INIT_DST" "$(spot_img)" 2>/dev/null \
    | grep -n -E "MARKER=|BUILTIN_AP=|license-fix.awk|LISTS=" | head || true
echo "--- $AWK_DST ---"
debugfs -R "cat $AWK_DST" "$(spot_img)" 2>/dev/null \
    | grep -n -E "generated-by|max-ap|inc-ap" | head || true

say "done — /writable license hook installed in $QCOW"
