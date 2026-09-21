#!/usr/bin/env bash
#
# backup-restore-test.sh — unit test for scripts/container/backup-restore.sh, the
# guest hook that applies a staged Ruckus configuration backup on first boot.
#
# No firmware, no QEMU, no guest: the vendor's /bin/sys_wrapper.sh is replaced by
# a stub that records its arguments and emulates the one effect the hook relies
# on (verify-backup decrypts the file in place and renames it .decrypted), and
# the reboot is a stub that records the call.  The hook's own logic is what is
# under test: which file the two vendor steps see, what happens when each step
# fails, the already-decrypted tar fallback, and that a consumed backup makes the
# next boot a no-op.
#
# Usage: ./scripts/test/backup-restore-test.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../container" && pwd)"
HOOK="$BASE/backup-restore.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-restore.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

RET="$TMP/stub"
DIR="$TMP/writable"
mkdir -p "$RET" "$DIR"

# sys_wrapper stub.  ZD_STUB_VERIFY_FAIL / ZD_STUB_RESTORE_FAIL turn each step
# into the vendor's failure path.  Every invocation is appended to calls.log.
cat > "$RET/sys_wrapper.sh" <<'STUB'
#!/bin/sh
echo "$*" >> "$ZD_STUB_CALLS"
case "$1" in
    verify-backup)
        if [ -e "$ZD_STUB_VERIFY_FAIL" ]; then
            # verify-backup removes the file it was given on rejection.
            rm -f "$2" "$2.decrypted"
            exit 1
        fi
        echo "I_RestoreOptions"
        echo "192.168.1.254"
        if [ -n "${ZD_STUB_PAYLOAD_TAR:-}" ]; then
            # Emulate a decrypted archive carrying a licence list.
            cp -f "$ZD_STUB_PAYLOAD_TAR" "$2.decrypted" || exit 1
            rm -f "$2"
        else
            mv "$2" "$2.decrypted" 2>/dev/null || { echo "no input $2" >&2; exit 1; }
        fi
        ;;
    restore-saved)
        if [ -e "$ZD_STUB_RESTORE_FAIL" ]; then
            exit 1
        fi
        # Emulate restoreSaved moving the configuration in; a switch makes it
        # emulate the silent no-op (the vendor `mv` leaving no system.xml).
        if [ ! -e "$ZD_STUB_NO_SYS_XML" ] && [ -n "${ZD_STUB_SYS_XML:-}" ]; then
            mkdir -p "$(dirname "$ZD_STUB_SYS_XML")"
            printf '<system/>\n' > "$ZD_STUB_SYS_XML"
        fi
        echo "[CONFIG] restore"
        ;;
esac
exit 0
STUB
chmod 755 "$RET/sys_wrapper.sh"

cat > "$RET/reboot" <<'STUB'
#!/bin/sh
echo rebooted >> "$ZD_STUB_REBOOTED"
exit 0
STUB
chmod 755 "$RET/reboot"

export ZD_SYS_WRAPPER="$RET/sys_wrapper.sh"
export ZD_RESTORE_DIR="$DIR"
export ZD_REBOOT="$RET/reboot"
export ZD_WRITABLE_ROOT="$TMP/writable-root"
export ZD_SYS_XML="$TMP/airespider/system.xml"
export ZD_STUB_CALLS="$TMP/calls.log"
export ZD_STUB_REBOOTED="$TMP/rebooted"
export ZD_STUB_VERIFY_FAIL="$TMP/verify.fail"
export ZD_STUB_RESTORE_FAIL="$TMP/restore.fail"
export ZD_STUB_NO_SYS_XML="$TMP/no-sys-xml"
export ZD_STUB_SYS_XML="$ZD_SYS_XML"
export ZD_STUB_PAYLOAD_TAR=""

run_hook() { ZD_SYS_WRAPPER="$ZD_SYS_WRAPPER" ZD_RESTORE_DIR="$DIR" ZD_REBOOT="$ZD_REBOOT" \
    ZD_WRITABLE_ROOT="$ZD_WRITABLE_ROOT" ZD_SYS_XML="$ZD_SYS_XML" sh "$HOOK"; }

reset() {
    rm -f "$DIR"/backup.bak* "$DIR"/.restore-work.bak* "$DIR"/restore.log
    rm -f "$ZD_SYS_XML" "$ZD_STUB_NO_SYS_XML"
    rm -rf "$ZD_WRITABLE_ROOT"
    ZD_STUB_PAYLOAD_TAR=""
    : > "$ZD_STUB_CALLS"
    rm -f "$ZD_STUB_REBOOTED" "$ZD_STUB_VERIFY_FAIL" "$ZD_STUB_RESTORE_FAIL"
}
calls() { cat "$ZD_STUB_CALLS" 2>/dev/null || true; }
rebooted() { [ -f "$ZD_STUB_REBOOTED" ] && echo yes || echo no; }

# --- no staged backup: nothing at all happens --------------------------------
reset
run_hook
[ ! -s "$ZD_STUB_CALLS" ] || fail "no backup: the vendor wrapper was called"
[ "$(rebooted)" = no ] || fail "no backup: the guest was rebooted"
pass "no staged backup is a no-op"

# --- the normal path: verify then restore, then consume + reboot -------------
reset
printf 'TAC-ish bytes\x36\x91\x4a' > "$DIR/backup.bak"
out="$(run_hook)"
grep -q '^verify-backup .*\.restore-work\.bak$' "$ZD_STUB_CALLS" \
    || fail "TAC backup: verify-backup did not see backup.bak ($(calls))"
grep -q '^restore-saved .*\.restore-work\.bak$' "$ZD_STUB_CALLS" \
    || fail "TAC backup: restore-saved did not see backup.bak ($(calls))"
[ -f "$DIR/backup.bak.applied" ] || fail "TAC backup: not marked applied"
[ -e "$DIR/backup.bak" ] && fail "TAC backup: backup.bak was left in place"
[ -e "$DIR/.restore-work.bak.decrypted" ] && fail "TAC backup: work file left behind"
[ "$(rebooted)" = yes ] || fail "TAC backup: the guest was not rebooted"
printf '%s\n' "$out" | grep -qF 'ZD-CONFIG-RESTORED=applied' \
    || fail "TAC backup: the container was not told the restore applied"
grep -q 'restore complete' "$DIR/restore.log" 2>/dev/null \
    || fail "TAC backup: restore.log missing the completion line"
pass "a TAC .bak is verified, restored, consumed, reported and rebooted"

# --- the backup's AP licence list is reinstated ------------------------------
# restoreSaved drops the backup's license*.xml on purpose; a container clone wants
# the source's APs, so the hook puts the archive's list back for patch 25 to
# repair.  `.bak.xml` is the form this backup stores (the live name is a symlink).
reset
printf 'TAC-ish bytes\x36\x91\x4a' > "$DIR/backup.bak"
mkdir -p "$TMP/lic/etc/airespider"
printf '<license-list max-ap="150"><license id="1" inc-ap="145" serial-number="271508002401" /></license-list>\n' \
    > "$TMP/lic/etc/airespider/license-list.bak.xml"
tar czf "$TMP/lic.tar.gz" -C "$TMP/lic" etc
ZD_STUB_PAYLOAD_TAR="$TMP/lic.tar.gz"
out="$(run_hook)"
[ -f "$ZD_WRITABLE_ROOT/etc/airespider-images/license-list.xml" ] \
    || fail "licence: the backup's list was not reinstated"
grep -q 'inc-ap="145"' "$ZD_WRITABLE_ROOT/etc/airespider-images/license-list.xml" \
    || fail "licence: the reinstated list is not the backup's"
[ -L "$ZD_WRITABLE_ROOT/etc/airespider/license-list.xml" ] \
    || fail "licence: the vendor symlink layout was not restored"
printf '%s\n' "$out" | grep -qF 'licence list' || fail "licence: the run did not log the reinstatement"
pass "the backup's AP licence list is reinstated for patch 25 to repair"

# --- an empty backup licence list is left alone ------------------------------
# A factory box that never had a licence written (e.g. a 9.9 backup) stores an
# empty <license-list>.  Reinstating it would drop the container's built-ins, so
# the hook must keep the container's own list.
reset
printf 'TAC-ish bytes\x36\x91\x4a' > "$DIR/backup.bak"
mkdir -p "$TMP/empty/etc/airespider"
printf '<license-list>\n</license-list>\n' > "$TMP/empty/etc/airespider/license-list.bak.xml"
tar czf "$TMP/empty.tar.gz" -C "$TMP/empty" etc
ZD_STUB_PAYLOAD_TAR="$TMP/empty.tar.gz"
out="$(run_hook)"
[ -e "$ZD_WRITABLE_ROOT/etc/airespider-images/license-list.xml" ] \
    && fail "empty licence: reinstated a list that names no APs"
printf '%s\n' "$out" | grep -qF 'licence list' && fail "empty licence: logged a reinstatement"
pass "an empty backup licence list is not reinstated"

# --- verify-backup rejection: keep the factory config, no reboot -------------
reset
printf 'TAC-ish bytes\x36\x91\x4a' > "$DIR/backup.bak"
: > "$ZD_STUB_VERIFY_FAIL"
out="$(run_hook)"
[ -f "$DIR/backup.bak.failed" ] || fail "rejected backup: not marked failed"
grep -q '^restore-saved' "$ZD_STUB_CALLS" && fail "rejected backup: restore-saved still ran"
[ "$(rebooted)" = no ] || fail "rejected backup: the guest was rebooted"
printf '%s\n' "$out" | grep -qF 'ZD-CONFIG-RESTORED=failed' \
    || fail "rejected backup: the container was not told it failed"
pass "a backup the vendor rejects is kept as .failed, reported and not rebooted"

# --- restore-saved failure: keep the factory config, no reboot ---------------
reset
printf 'TAC-ish bytes\x36\x91\x4a' > "$DIR/backup.bak"
: > "$ZD_STUB_RESTORE_FAIL"
run_hook
[ -f "$DIR/backup.bak.failed" ] || fail "failed restore: not marked failed"
grep -q '^verify-backup' "$ZD_STUB_CALLS" || fail "failed restore: verify never ran"
[ "$(rebooted)" = no ] || fail "failed restore: the guest was rebooted"
pass "a restore that fails is kept as .failed and not rebooted"

# --- a restore that leaves no system.xml is a failure, not a success ---------
# The vendor restoreSaved swallows the final `mv`, so a missing destination
# directory produces a run that exits 0 with the factory config in place.  The
# hook must catch that and not tell the container it applied.
reset
printf 'TAC-ish bytes\x36\x91\x4a' > "$DIR/backup.bak"
: > "$ZD_STUB_NO_SYS_XML"
out="$(run_hook)"
[ -f "$DIR/backup.bak.failed" ] || fail "silent no-op: not marked failed"
[ -e "$DIR/backup.bak.applied" ] && fail "silent no-op: marked applied"
[ "$(rebooted)" = no ] || fail "silent no-op: the guest was rebooted"
printf '%s\n' "$out" | grep -qF 'ZD-CONFIG-RESTORED=failed' \
    || fail "silent no-op: the container was not told it failed"
pass "a restore that leaves no system.xml is reported as failed"

# --- an already-decrypted gzip tar skips verify-backup -----------------------
reset
printf 'not really a backup payload\n' | gzip -c > "$DIR/backup.bak"
run_hook
grep -q '^verify-backup' "$ZD_STUB_CALLS" && fail "gzip tar: verify-backup should be skipped"
grep -q '^restore-saved .*\.restore-work\.bak$' "$ZD_STUB_CALLS" \
    || fail "gzip tar: restore-saved did not run ($(calls))"
[ -f "$DIR/backup.bak.applied" ] || fail "gzip tar: not marked applied"
[ "$(rebooted)" = yes ] || fail "gzip tar: the guest was not rebooted"
pass "an already-decrypted gzip tar goes straight to restore-saved"

# --- a consumed backup makes the next boot a no-op ---------------------------
reset
: > "$DIR/backup.bak.applied"
run_hook
[ ! -s "$ZD_STUB_CALLS" ] || fail "second boot: the vendor wrapper was called"
[ "$(rebooted)" = no ] || fail "second boot: the guest was rebooted"
pass "a consumed backup is not restored a second time"

# --- the container owns the "never again" decision ---------------------------
# The guest marker cannot be relied on (the vendor can reimage /writable), so the
# authority is the container: prepare-vm-disks.sh records the seeding and refuses
# to rebuild a live appliance.  Assert both halves of that contract are present,
# and that the guest hook consumes the staged file instead of trusting a marker.
DISP="$BASE/prepare-vm-disks.sh"
grep -q 'SEED_MARKER' "$DISP" || fail "prepare-vm-disks.sh does not define the container seed marker"
grep -q 'configuration backup seeded into /writable' "$DISP" \
    || fail "prepare-vm-disks.sh does not record the seeded backup"
grep -q 'SRC.applied' "$HOOK" || fail "the hook does not consume the staged backup"
grep -q 'DIR/restored' "$HOOK" && fail "the hook still relies on a guest-side persistent marker"
grep -qF 'ZD-CONFIG-RESTORED=' "$HOOK" \
    || fail "the hook does not report the restore over the console channel"
# The guest's busybox dd/od do not take GNU options; the gzip test is portable.
grep -q 'gzip -t' "$HOOK" || fail "the hook does not tell TAC from gzip portably"
LAUNCH="$BASE/launch-vm.sh"
grep -q 'retire_applied_backup' "$LAUNCH" || fail "launch-vm.sh does not retire the applied backup"
grep -qF 'ZD-CONFIG-RESTORED=applied' "$LAUNCH" \
    || fail "launch-vm.sh does not observe the guest's restore report"
pass "the container records the seed, observes the report and retires its copy"

# --- the rcS entry runs the hook --------------------------------------------
INIT="$BASE/patches/26-backup-restore.sh"
grep -q '/etc/zd1200-restore.sh' "$INIT" \
    || fail "patch 26 does not install an S48 entry that runs the hook"
grep -q 'S48zd_restore' "$INIT" || fail "patch 26 does not name the rcS entry"
pass "patch 26 installs the S48zd_restore rcS entry"

echo
echo "all backup-restore tests passed"
