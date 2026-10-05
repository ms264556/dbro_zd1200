#!/usr/bin/env bash
#
# 30-v54-root-shell.sh — bake the vendor "!v54!" root-shell escape fix.
#
# The ZD1200 CLI/login escape `!v54!` verifies a passphrase through the vendor
# passphrase helper and drops to a root shell only if that call succeeds.  The
# helper's name is release-dependent: newer builds ship /usr/sbin/sesame2,
# older ones (e.g. 10.2.1.0.236) ship /usr/sbin/sesame.  We make the escape
# always succeed by replacing whichever helper the release has with a trivial
# executable that exits 0.
#
# Why not a symlink to `true`: in this rootfs /bin/true is a busybox *applet*
# symlink (-> busybox).  busybox dispatches on argv[0], so invoking it through a
# name other than a real applet (here "sesame"/"sesame2") prints `applet not
# found` and exits 127.  A regular `#!/bin/sh` script that just calls `exit 0`
# is argv[0]-independent, so it works however the helper is exec'd.
#
# Applied to the ROOT partitions of the flat disk (hda2/hda3), using the
# same read -> debugfs -> dd channel as the other rootfs patches.  Runs as a
# normal user: dd (read/write), debugfs (userspace ext2 writer)
# (writes only changed byte ranges back to the disk).
#
# Usage:
#   QCOW=<flat-disk> WORK=<workdir> ./"30-v54-root-shell.sh"
#
# Re-patching: pr_save keeps the pristine vendor helper in the root's
# /.patchrollback store, so prepare-vm-disks.sh can restore it before a changed
# patch set is re-applied (and a later patch can, if needed, hand the vendor
# helper back).
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../patch-lib.sh
. "$(dirname "$BASE")/patch-lib.sh"
patch_env

# Passphrase helpers, newest name first.  Whichever exists on a partition is
# patched; a release that ships only one of them simply skips the other.
TARGETS=(
    "/usr/sbin/sesame2"   # newer builds (e.g. 10.5.1.0.282)
    "/usr/sbin/sesame"    # older builds (e.g. 10.2.1.0.236)
)
SCRIPT=$'#!/bin/sh\nexit 0\n'

printf '%s' "$SCRIPT" > "$WORK/helper.new"

apply() { # <name> <img>
    local name="$1" img="$2" target type_old
    for target in "${TARGETS[@]}"; do
        read -r type_old _ _ _ <<< "$(fs_stat_meta "$img" "$target")"
        if [ -z "$type_old" ]; then
            echo "  - $target not present on $name"
            continue
        fi
        if [ "$type_old" = "regular" ] \
           && fs_read "$img" "$target" "$WORK/target.cur" \
           && cmp -s "$WORK/target.cur" "$WORK/helper.new"; then
            echo "  $target is already the exit-0 script on $name; leaving as-is"
            continue
        fi
        echo "  replacing $target (was '$type_old') with an exit-0 script"
        # Not write_local: the replacement must be a 0755 regular file whatever
        # the vendor helper was, and write_local keeps the vendor's metadata.
        pr_save "$img" "$target"
        fs_write "$img" "$target" "$WORK/helper.new" 0755 0 0
        PATCH_APPLIED=1
    done
}

verify() { # <name> <img>: every helper present is the 0755 exit-0 script
    local img="$2" target t m
    for target in "${TARGETS[@]}"; do
        read -r t m _ _ <<< "$(fs_stat_meta "$img" "$target")"
        [ -n "$t" ] || continue
        [ "$t" = "regular" ] && [ "$m" = "0755" ] \
            && fs_read "$img" "$target" "$WORK/target.final" \
            && cmp -s "$WORK/target.final" "$WORK/helper.new" \
            || { echo "  $target is not the exit-0 script (type '$t' mode '$m')" >&2; return 1; }
    done
}

patch_main apply verify
