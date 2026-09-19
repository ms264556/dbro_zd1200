#!/usr/bin/env bash
#
# patch-lib-test.sh — unit test for scripts/container/patch-lib.sh's rollback
# store, without a firmware image or QEMU.
#
# It builds a small ext2 filesystem that looks like a vendor rootfs, applies a
# "patch set", re-applies a changed one (what prepare-vm-disks.sh does after the
# sentinel changes), and asserts that:
#
#   * pr_reset restores every replaced vendor file (content and metadata) and
#     deletes every patch-created path;
#   * a repeat patch run is deterministic;
#   * a vendor symlink that a patch replaced is restored as a symlink.
#
# Usage: ./scripts/test/patch-lib-test.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../container" && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-patchlib.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

WORK="$TMP/work"
mkdir -p "$WORK"
IMG="$WORK/hda2.img"
QCOW="$TMP/disk.raw"          # patch-lib expects these two in the environment
ALIGN=512
# shellcheck source=../container/patch-lib.sh
. "$BASE/patch-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

# read <path>: print a file from the image (empty when absent)
read_img() {
    local out="$TMP/read.$$"
    rm -f "$out"
    debugfs -R "dump $1 $out" "$IMG" >/dev/null 2>&1 || { echo "<absent>"; return; }
    [ -f "$out" ] || { echo "<absent>"; return; }
    cat "$out"; rm -f "$out"
}
type_of() { fs_stat_meta "$IMG" "$1" | awk '{print $1}'; }
mode_of() { fs_stat_meta "$IMG" "$1" | awk '{print $2}'; }

# --- build a vendor rootfs ---------------------------------------------------
stage="$TMP/stage"
mkdir -p "$stage/etc/init.d" "$stage/usr/sbin"
printf 'mount -o nolog,rw /dev/sda4\n' > "$stage/etc/init.d/sys_init"
printf 'FILE:md5 /usr/sbin/sesame2\n' > "$stage/file_list.txt"
printf 'vendor dropbear binary\n' > "$stage/usr/sbin/dropbear"
printf '/bin/sh\n/bin/bash\n' > "$stage/etc/shells"
printf 'remove me\n' > "$stage/etc/remove-me"
truncate -s 16M "$IMG"
mke2fs -q -t ext2 -F -d "$stage" "$IMG"
debugfs -w -R "set_inode_field /etc/init.d/sys_init mode 0100755" "$IMG" >/dev/null 2>&1
debugfs -w -R "symlink /usr/sbin/dropbearkey ../sbin/dropbear" "$IMG" >/dev/null 2>&1

[ "$(type_of /usr/sbin/dropbearkey)" = "symlink" ] || fail "fixture symlink missing"

# --- apply patch set A -------------------------------------------------------
apply_set() {
    local tag="$1" new="$TMP/new"
    pr_init "$IMG"
    printf '%s sys_init\n' "$tag" > "$new"
    write_local "$IMG" /etc/init.d/sys_init "$new"
    printf '%s file_list\n' "$tag" > "$new"
    write_local "$IMG" /file_list.txt "$new"
    printf '%s dropbearkey\n' "$tag" > "$new"
    write_local "$IMG" /usr/sbin/dropbearkey "$new" 0755
    printf '%s newfile\n' "$tag" > "$new"
    write_local "$IMG" /etc/newfile "$new" 0755
    symlink_force "$IMG" /etc/link /writable/data/dropbear
    remove_path "$IMG" /etc/remove-me
    mkdir_p "$IMG" /etc/persistent-scripts/patch-storage
    printf '%s support\n' "$tag" > "$new"
    write_local "$IMG" /etc/persistent-scripts/patch-storage/support "$new"
    printf '%s\n' "$tag" > "$TMP/sentinel"
    debugfs -w -R "write $TMP/sentinel $PR_SENTINEL" "$IMG" >/dev/null 2>&1
}

apply_set A

[ "$(read_img /etc/init.d/sys_init)" = "A sys_init" ] || fail "A: sys_init not patched"
[ "$(type_of /usr/sbin/dropbearkey)" = "regular" ]     || fail "A: dropbearkey not replaced by a file"
[ "$(type_of /etc/link)" = "symlink" ]                 || fail "A: link not created"
[ "$(fs_readlink "$IMG" /etc/link)" = "/writable/data/dropbear" ] || fail "A: link target wrong"
[ "$(type_of /etc/newfile)" = "regular" ]              || fail "A: newfile missing"
[ "$(type_of /etc/remove-me)" = "" ]                   || fail "A: remove-me still present"
[ "$(type_of /etc/persistent-scripts/patch-storage/support)" = "regular" ] || fail "A: support missing"
pass "patch set A applied"

# Snapshot A's outcome for the determinism check later.
snapshot() { # <outfile>
    {
        for p in /etc/init.d/sys_init /file_list.txt /usr/sbin/dropbearkey \
                 /etc/newfile /etc/link /etc/remove-me \
                 /etc/persistent-scripts/patch-storage/support; do
            printf '%s type=%s mode=%s target=%s\n' "$p" \
                "$(type_of "$p")" "$(mode_of "$p")" "$(fs_readlink "$IMG" "$p")"
            read_img "$p"
        done
    } > "$1"
}
snapshot "$TMP/after-A"

# --- reset (as prepare-vm-disks.sh does before a changed patch set) ----------
pr_reset "$IMG"

[ "$(read_img /etc/init.d/sys_init)" = "mount -o nolog,rw /dev/sda4" ] \
    || fail "reset: sys_init not restored"
[ "$(mode_of /etc/init.d/sys_init)" = "0755" ] || fail "reset: sys_init mode lost"
[ "$(read_img /file_list.txt)" = "FILE:md5 /usr/sbin/sesame2" ] \
    || fail "reset: file_list.txt not restored"
[ "$(type_of /usr/sbin/dropbearkey)" = "symlink" ] || fail "reset: dropbearkey not a symlink again"
[ "$(fs_readlink "$IMG" /usr/sbin/dropbearkey)" = "../sbin/dropbear" ] \
    || fail "reset: dropbearkey target wrong"
[ "$(type_of /etc/newfile)" = "" ] || fail "reset: newfile not removed"
[ "$(type_of /etc/link)" = "" ]    || fail "reset: link not removed"
[ "$(read_img /etc/remove-me)" = "remove me" ] || fail "reset: remove-me not restored"
[ "$(type_of /etc/persistent-scripts/patch-storage/support)" = "" ] \
    || fail "reset: support not removed"
[ "$(pr_has_store "$IMG" && echo yes)" = "yes" ] || fail "reset: store was destroyed"
pass "pr_reset restored the vendor rootfs"

# --- apply a changed set B, then repeat it -----------------------------------
apply_set B
snapshot "$TMP/after-B1"

pr_reset "$IMG"
apply_set B
snapshot "$TMP/after-B2"

if ! cmp -s "$TMP/after-B1" "$TMP/after-B2"; then
    echo "--- after B1 ---"; cat "$TMP/after-B1"
    echo "--- after B2 ---"; cat "$TMP/after-B2"
    fail "repeat patch run is not deterministic"
fi
pass "repeat patch run is deterministic"

# --- a removed patch's additions are reverted too ----------------------------
# Reset + apply a set that no longer installs /etc/newfile: the stale file must
# stay gone.
pr_reset "$IMG"
pr_init "$IMG"
printf 'C sys_init\n' > "$TMP/new"
write_local "$IMG" /etc/init.d/sys_init "$TMP/new"
printf 'C\n' > "$TMP/sentinel"
debugfs -w -R "rm $PR_SENTINEL" "$IMG" >/dev/null 2>&1 || true
debugfs -w -R "write $TMP/sentinel $PR_SENTINEL" "$IMG" >/dev/null 2>&1
[ "$(type_of /etc/newfile)" = "" ] || fail "dropped patch left /etc/newfile behind"
[ "$(read_img /etc/init.d/sys_init)" = "C sys_init" ] || fail "set C did not apply"
pass "paths from a dropped patch are reverted"

echo
echo "all patch-lib tests passed"
