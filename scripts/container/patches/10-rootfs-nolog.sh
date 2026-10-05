#!/usr/bin/env bash
#
# 10-rootfs-nolog.sh — patch files inside the ZD1200 lab VM rootfs partitions,
# writing the result into the flat disk.  Runs as a standard user:
# no root, no loop devices, no nbd, no mount.
#
#   read  : dd                (the flat disk is read directly)
#           debugfs           (userspace ext2 reader/writer)
#   write : dd                (writes only the changed byte ranges back to the
#                              disk)
#
# Usage:  run from the patches/ pipeline via prepare-vm-disks.sh
# (QCOW=<flat-disk> WORK=<workdir> ./"10-rootfs-nolog.sh")
#
# Configure PARTITIONS and PATCHES below.  Each PATCHES entry is
#   <rootfs-path>|<sed-expression>
# and is applied to every listed partition that contains the file.  Only byte
# ranges that actually change are written back, so the disk stays small.
#
# Idempotency and re-patching: write_local stores the pristine vendor copy of
# every file it replaces in the root's /.patchrollback store (see
# scripts/container/patch-lib.sh), so prepare-vm-disks.sh can restore the root
# and re-run this patch after the patch set changes.  A file that already
# matches the patched form is left alone.
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../patch-lib.sh
. "$(dirname "$BASE")/patch-lib.sh"
patch_env

# rootfs-path|sed-expression
# Pattern-based so the patch survives whitespace and option-order differences
# between releases.  The two comma-anchored substitutions strip a `nolog` mount
# option wherever it sits in the list; `\b` keeps them off words like "nologin",
# and a bare `nolog` with no comma (e.g. in a comment) is left alone.
PATCHES=(
    "/etc/init.d/sys_init|s/,nolog\b//; s/nolog\b,//"
)

apply() { # <name> <img>
    local name="$1" img="$2" patch fspath sedexpr
    for patch in "${PATCHES[@]}"; do
        IFS='|' read -r fspath sedexpr <<< "$patch"
        if ! fs_read "$img" "$fspath" "$WORK/file.orig"; then
            echo "  ! $fspath not present on $name, skipping" >&2
            continue
        fi
        sed -e "$sedexpr" "$WORK/file.orig" > "$WORK/file.new"
        if cmp -s "$WORK/file.orig" "$WORK/file.new"; then
            echo "  $fspath already matches the patched form (nothing to do)"
            continue
        fi
        echo "  change to $fspath:"
        diff -u "$WORK/file.orig" "$WORK/file.new" | sed 's/^/    /' || true
        write_local "$img" "$fspath" "$WORK/file.new"
        PATCH_APPLIED=1
    done
}

patch_main apply
