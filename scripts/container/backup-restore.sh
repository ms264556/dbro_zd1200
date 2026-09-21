#!/bin/sh
#
# backup-restore.sh — apply a staged Ruckus configuration backup on first boot.
#
# `install-zd1200-lxc.sh` / `install-zd1200-docker.sh --backup <ruckus_db_*.bak>`
# stage the operator's backup into the freshly built /writable at
# /zd1200-restore/backup.bak (scripts/container/build-synthetic-cf.py), and
# /etc/init.d/S48zd_restore runs this script from rcS — after S47migrate has
# mounted /writable and before S50controller starts, so the controller comes up
# with the restored configuration.  The script then reboots the guest once, so
# the restored management address and every boot-time service take effect: the
# vendor's web-driven restore does the same.
#
# The restore is the vendor's own path, not a reimplementation:
#
#   sys_wrapper.sh verify-backup <file>   decrypt, check PURPOSE/PLATFORM/
#                                         APMODEL/version, decrypt again
#   sys_wrapper.sh restore-saved <base>   restoreSaved(): factory-clean the
#                                         configuration, move the backup's XML
#                                         in, migrate between releases, restore
#                                         the AP customisation
#
# A backup copied straight out of the ZoneDirector's Web UI is TAC-encrypted and
# must go through verify-backup.  An already-decrypted gzip tar (a *.tgz saved
# from a .bak) cannot be decrypted again, so it is handed to restore-saved
# directly; the installer has already validated its release host-side.
#
# The restore runs at most once per built disk.  The container is the authority:
# it stages this file only while it builds a fresh /writable and records that in
# its own state (scripts/container/prepare-vm-disks.sh), so it can never re-stage
# a backup into a live appliance.  This hook's job is the guest half: apply the
# staged file and consume it (rename to backup.applied) in the same breath, so a
# second boot of the same disk finds nothing to do.  A backup that fails
# validation is renamed to backup.failed and the appliance keeps its factory
# configuration rather than boot-looping.
#
# Best effort: it never fails the boot.  Overridable for the unit test:
#   ZD_SYS_WRAPPER, ZD_RESTORE_DIR, ZD_REBOOT
set -u

SYS_WRAPPER="${ZD_SYS_WRAPPER:-/bin/sys_wrapper.sh}"
DIR="${ZD_RESTORE_DIR:-/writable/zd1200-restore}"
REBOOT="${ZD_REBOOT:-/sbin/reboot}"
WROOT="${ZD_WRITABLE_ROOT:-/writable}"
SYS_XML="${ZD_SYS_XML:-/etc/airespider/system.xml}"
SRC="$DIR/backup.bak"
WORK="$DIR/.restore-work.bak"
LOG="$DIR/restore.log"
LIC=/tmp/zd1200-restore-license.xml

PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

log() {
    echo "zd1200-restore: $*"
    echo "zd1200-restore: $*" >> "$LOG" 2>/dev/null
}

# Tell the container the outcome on the guest's serial console.  The container
# captures that console (QEMU's chardev appends it to the console log) and is the
# authority on "already restored": it records the result and retires its own copy
# of the backup.  The guest's /writable is not trusted to remember anything.
notify_container() {
    echo "ZD-CONFIG-RESTORED=$1" > /dev/console 2>/dev/null || true
    echo "ZD-CONFIG-RESTORED=$1"
}

[ -f "$SRC" ] || exit 0
[ -x "$SYS_WRAPPER" ] || { log "$SYS_WRAPPER is missing; cannot restore"; exit 0; }

# Work on a copy: verify-backup consumes the file it is given (it decrypts it in
# place and renames it .decrypted), and a rejected backup should be kept for
# inspection rather than destroyed.
if ! cp "$SRC" "$WORK" 2>/dev/null; then
    log "cannot copy $SRC; leaving the configuration alone"
    exit 0
fi

# Run the vendor wrapper, echoing its output to the console (rcS's stdout, which
# the container captures) and appending it to the restore log.
run_wrapper() {
    out="$("$SYS_WRAPPER" "$@" 2>&1)"
    rc=$?
    printf '%s\n' "$out"
    printf '%s\n' "$out" >> "$LOG" 2>/dev/null
    return $rc
}

# A *.bak from the Web UI is TAC-encrypted; an already-decrypted gzip tar (a
# *.tgz saved next to it) must not go through verify-backup, which would try to
# TAC-decrypt it and reject it.  `gzip -t` tells them apart without relying on
# the guest's busybox applets: a TAC stream is not a gzip member.  (The earlier
# `dd ... status=none` probe failed because busybox dd does not know that GNU
# option, and the `od`-based probe failed because busybox od is not GNU od.)
if gzip -t "$SRC" >/dev/null 2>&1; then
    log "staged backup is an already-decrypted gzip tar; skipping verify-backup"
    mv -f "$WORK" "$WORK.decrypted" 2>/dev/null || true
else
    log "validating the staged configuration backup"
    if ! run_wrapper verify-backup "$WORK"; then
        log "the backup was rejected; keeping the factory configuration"
        mv -f "$SRC" "$SRC.failed" 2>/dev/null || true
        rm -f "$WORK" "$WORK.decrypted"
        notify_container failed
        exit 0
    fi
fi

# The vendor's restoreSaved deliberately discards the backup's licence list: it
# removes `license*.xml` from the restore set and substitutes the running
# appliance's, because on real hardware a licence names the box it was bought
# for.  For a container clone the operator wants the source's APs, exactly as a
# --writable-from dump keeps them (patch 25's S49zd_license repairs the serial
# and the built-in count there).  So recover the licence list from the archive —
# the live `license-list.xml` when the source stored it as a file, otherwise the
# vendor's `license-list.bak.xml` revision — and install it after the restore.
# Best effort: an archive with neither leaves the appliance's own list alone.
extract_backup_license() {
    local member d
    rm -f "$LIC"
    [ -f "$WORK.decrypted" ] || return 0
    d="/tmp/zd1200-restore-lic.$$"
    rm -rf "$d"; mkdir -p "$d"
    for member in etc/airespider/license-list.xml etc/airespider/license-list.bak.xml; do
        if tar xzf "$WORK.decrypted" -C "$d" "$member" 2>/dev/null \
           && [ -f "$d/$member" ] && [ ! -L "$d/$member" ] && [ -s "$d/$member" ]; then
            cp -f "$d/$member" "$LIC"
            break
        fi
    done
    rm -rf "$d"
    [ -s "$LIC" ]
}
extract_backup_license || true

# The vendor restore moves the backup's XMLs into /etc/airespider and its custom
# AP images into /etc/airespider-images/custom, both symlinks onto /writable.
# This hook runs before S50controller, so on a factory-fresh /writable those
# directories do not exist yet and the vendor's `mv` fails with ENOENT — while
# still exiting 0, which would look like a successful restore.  Create the two
# parents the restore writes into.
mkdir -p "$WROOT/etc/airespider" "$WROOT/etc/airespider-images/custom" 2>/dev/null || true

log "restoring the configuration"
if ! run_wrapper restore-saved "$WORK"; then
    log "the vendor restore failed; keeping the factory configuration"
    mv -f "$SRC" "$SRC.failed" 2>/dev/null || true
    rm -f "$WORK" "$WORK.decrypted" "$LIC"
    notify_container failed
    exit 0
fi

# restoreSaved swallows a failed final `mv`, so verify the configuration really
# landed before promising the container it did: a run that left the factory
# system.xml in place must be reported failed, not applied, or the appliance
# would look seeded and never retry.
if [ ! -f "$SYS_XML" ]; then
    log "the vendor restore left no $SYS_XML; treating it as failed"
    mv -f "$SRC" "$SRC.failed" 2>/dev/null || true
    rm -f "$WORK" "$WORK.decrypted" "$LIC"
    notify_container failed
    exit 0
fi

# Put the backup's licence list back, in the vendor's canonical (images) layout.
# S49zd_license (patch 25) repairs its serials and built-in count on the next
# boot, before S50controller reads it — the same treatment a foreign /writable
# gets.  Written only into /writable, never over the /etc symlink itself.  An
# empty `<license-list>` names no APs (a factory box that never had a licence
# written, e.g. a 9.9 backup), so reinstating it could drop the container's
# built-ins: only a list that names APs or licences is applied.
if [ -s "$LIC" ] && grep -qE '<license |max-ap=' "$LIC" 2>/dev/null; then
    mkdir -p "$WROOT/etc/airespider-images" "$WROOT/etc/airespider" 2>/dev/null || true
    cat "$LIC" > "$WROOT/etc/airespider-images/license-list.xml" 2>/dev/null || true
    if [ -L "$WROOT/etc/airespider/license-list.xml" ]; then
        : # the symlink already resolves to the file just written
    elif [ -f "$WROOT/etc/airespider/license-list.xml" ]; then
        cat "$LIC" > "$WROOT/etc/airespider/license-list.xml" 2>/dev/null || true
    else
        ln -sf /etc/airespider-images/license-list.xml \
            "$WROOT/etc/airespider/license-list.xml" 2>/dev/null || true
    fi
    log "reinstated the backup's AP licence list (patch 25 repairs its serial)"
fi
rm -f "$LIC"

# Consume the staged backup *before* rebooting, so a second boot of this same
# disk finds nothing to apply even if the reboot is interrupted.  The container
# guarantees it will never stage a backup into this /writable again; this rename
# is what makes the guest half of that a one-shot.
mv -f "$SRC" "$SRC.applied" 2>/dev/null || rm -f "$SRC"
rm -f "$WORK" "$WORK.decrypted"
sync
log "restore complete; rebooting so the restored configuration takes effect"
notify_container applied
"$REBOOT"
exit 0
