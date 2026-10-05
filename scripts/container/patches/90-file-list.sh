#!/usr/bin/env bash
#
# 90-file-list.sh — teach the vendor root repair to reproduce a patched root.
#
# /etc/init.d/chk_integrity.sh clone() reproduces a root by copying the paths
# listed in /file_list.txt.  The vendor list (buildroot: ext2root.mk) enumerates
# the vendor rootfs, so a clone already carries every vendor file -- and, with
# 40-skip-integrity's no-op md5 check, the patched ones too -- but it misses what
# this project adds afterwards: the patch-created files and the
# /.patchrollback store.  A cloned root therefore looked uncustomised to
# prepare-vm-disks.sh, which re-applied the whole patch set on top of already
# patched files and never rebuilt the store.
#
# Append the project's paths to /file_list.txt (file_list_append_added()):
# DIR:/LINK:/FILE:<md5> for every path in the store's 'added' list, plus one
# OTHER:./.patchrollback line that cp -a's the store -- including the sentinel
# prepare-vm-disks.sh writes after this patch set.
#
# Runs last so the store's 'added' list is complete.  Applied to the ROOT
# partitions of the flat disk (hda2/hda3) with the same read -> debugfs -> dd
# channel as the other rootfs patches.
#
# Usage:
#   QCOW=<flat-disk> WORK=<workdir> ./"90-file-list.sh"
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../patch-lib.sh
. "$(dirname "$BASE")/patch-lib.sh"
patch_env

apply() { # <name> <img>
    local name="$1" IMG="$2"
    say "[$name] appending the project's paths to $FILE_LIST"
    file_list_append_added "$IMG"
    PATCH_APPLIED=1
}

patch_main apply
