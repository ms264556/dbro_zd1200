#!/usr/bin/env bash
#
# 26-backup-restore.sh — install the guest hook that applies a staged Ruckus
# configuration backup on the appliance's first boot.
#
# When the installer is given `--backup <ruckus_db_*.bak>`, the backup is
# decrypted and release-checked host-side and then staged into the freshly built
# /writable at /zd1200-restore/backup.bak (scripts/container/build-synthetic-cf.py).
# This patch installs the guest's half of that feature into both ext2 root
# partitions (hda2/hda3):
#
#   /etc/zd1200-restore.sh       the restore logic (see that file's header)
#   /etc/init.d/S48zd_restore    rcS entry; runs the logic before S50controller
#
# The hook is installed unconditionally and is a no-op unless a backup is staged,
# so the patch set stays constant whether or not --backup was used.  The vendor
# path (sys_wrapper.sh verify-backup / restore-saved) is the same code the web
# UI drives; it does the factory clean, the configuration move, the release
# migration and the AP customisation, then the hook reboots once.
#
# Usage:  QCOW=<flat-disk> WORK=<workdir> ./"26-backup-restore.sh"
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../patch-lib.sh
. "$(dirname "$BASE")/patch-lib.sh"
patch_env
SRC_SH="$(dirname "$BASE")/backup-restore.sh"
INIT_DST=/etc/init.d/S48zd_restore
HOOK_DST=/etc/zd1200-restore.sh

[ -f "$SRC_SH" ] || { echo "26-backup-restore: $SRC_SH missing" >&2; exit 1; }

cat > "$WORK/S48zd_restore" <<'ZD_RESTORE_INIT'
#!/bin/sh
#
# S48zd_restore — apply a staged configuration backup on the first boot.
#
# Installed by scripts/container/patches/26-backup-restore.sh (dbro_zd1200).
# rcS runs this after S47migrate has mounted /writable and before S50controller
# starts, so the controller comes up with the restored configuration.  See
# /etc/zd1200-restore.sh for the restore itself; it is a no-op unless the
# installer staged a backup into /writable/zd1200-restore/backup.bak.
[ -x /etc/zd1200-restore.sh ] && /etc/zd1200-restore.sh
exit 0
ZD_RESTORE_INIT

apply() { # <name> <img>
    local img="$2"
    write_local "$img" "$HOOK_DST" "$SRC_SH" 0755
    write_local "$img" "$INIT_DST" "$WORK/S48zd_restore" 0755
    PATCH_APPLIED=1
}

patch_main apply
