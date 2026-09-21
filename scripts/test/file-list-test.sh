#!/usr/bin/env bash
#
# file-list-test.sh — unit test for file_list_append_added() in
# scripts/container/patch-lib.sh, without firmware or QEMU.
#
# Builds an ext2 image that looks like a patched vendor root (a vendor
# /file_list.txt, a rollback store, and paths a patch created) and asserts that
# the function appends exactly the project's paths -- dirs before files, with
# real md5s, the store as an OTHER line -- that it is idempotent, and that a
# reset restores the vendor list so a re-patch appends once.
#
# Usage: ./scripts/test/file-list-test.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../container" && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-flist.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

for tool in mke2fs debugfs; do
    command -v "$tool" >/dev/null 2>&1 \
        || { echo "SKIP: $tool not found (e2fsprogs is required)" >&2; exit 0; }
done

WORK="$TMP/work"
mkdir -p "$WORK"
IMG="$WORK/hda2.img"
QCOW="$TMP/disk.raw"          # patch-lib expects these in the environment
ALIGN=512
# shellcheck source=../container/patch-lib.sh
. "$BASE/patch-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

read_img() { # <path>
    local out="$TMP/read.$$"
    rm -f "$out"
    debugfs -R "dump $1 $out" "$IMG" >/dev/null 2>&1 || { echo "<absent>"; return; }
    [ -f "$out" ] || { echo "<absent>"; return; }
    cat "$out"; rm -f "$out"
}

# --- a vendor root with a vendor /file_list.txt ------------------------------
stage="$TMP/stage"
mkdir -p "$stage/etc/init.d"
printf 'vendor init\n' > "$stage/etc/init.d/sys_init"
printf '/bin/sh\n' > "$stage/etc/shells"
truncate -s 16M "$IMG"
mke2fs -q -t ext2 -F -d "$stage" "$IMG"
debugfs -w -R "symlink /fl ../writable" "$IMG" >/dev/null 2>&1

vendor_sys_md5="$(md5sum "$stage/etc/init.d/sys_init" | awk '{print $1}')"
{
    printf 'SKIP:./etc\n'
    printf 'DIR:./etc\n'
    printf 'DIR:./etc/init.d\n'
    printf 'FILE:%s  ./etc/init.d/sys_init\n' "$vendor_sys_md5"
    printf 'LINK:./fl\n'
} > "$TMP/vendor.list"
debugfs -w -R "write $TMP/vendor.list /file_list.txt" "$IMG" >/dev/null 2>&1
[ "$(read_img /file_list.txt)" = "$(cat "$TMP/vendor.list")" ] \
    || fail "fixture /file_list.txt not written"

# --- what a patch set does to that root --------------------------------------
printf 'patch storage\n' > "$TMP/support"
printf 'patched init\n' > "$TMP/sys_init"
support_md5="$(md5sum "$TMP/support" | awk '{print $1}')"

apply_fixture() {
    mkdir_p "$IMG" /etc/persistent-scripts/patch-storage
    write_local "$IMG" /etc/persistent-scripts/patch-storage/support "$TMP/support"
    symlink_force "$IMG" /etc/newlink /etc/persistent-scripts/patch-storage/support
    # A vendor file the patch replaces: it must NOT be re-listed (the vendor list
    # already has it).
    write_local "$IMG" /etc/init.d/sys_init "$TMP/sys_init"
}

pr_init "$IMG"
apply_fixture

# --- append the project's paths ----------------------------------------------
file_list_append_added "$IMG"
list="$(read_img /file_list.txt)"

[ "$(printf '%s\n' "$list" | head -n 5)" = "$(cat "$TMP/vendor.list")" ] \
    || fail "vendor entries were not kept first"
printf '%s\n' "$list" | grep -qxF "$FILE_LIST_MARKER" || fail "marker missing"
printf '%s\n' "$list" | grep -qxF 'DIR:./etc/persistent-scripts' || fail "dir entry missing"
printf '%s\n' "$list" | grep -qxF 'DIR:./etc/persistent-scripts/patch-storage' || fail "deep dir entry missing"
printf '%s\n' "$list" | grep -qxF "FILE:$support_md5  ./etc/persistent-scripts/patch-storage/support" \
    || fail "file entry missing or md5 wrong"
printf '%s\n' "$list" | grep -qxF 'LINK:./etc/newlink' || fail "link entry missing"
printf '%s\n' "$list" | grep -qxF 'OTHER:./.patchrollback' || fail "store entry missing"
# sys_init is a replaced vendor file: it is already in the vendor list, so it
# must appear exactly once, never re-appended.
[ "$(printf '%s\n' "$list" | grep -c 'FILE:.*sys_init')" = "1" ] \
    || fail "replaced vendor file was re-listed"
pass "appended the project's paths (dirs, files with md5, links, store)"

marker_line="$(printf '%s\n' "$list" | grep -nF "$FILE_LIST_MARKER" | cut -d: -f1)"
app_dir_last="$(printf '%s\n' "$list" | awk -v m="$marker_line" 'NR>m && /^DIR:/{n=NR} END{print n+0}')"
app_copy_first="$(printf '%s\n' "$list" | awk -v m="$marker_line" 'NR>m && /^(FILE|LINK|OTHER):/{print NR; exit}')"
[ "$app_dir_last" -lt "$app_copy_first" ] || fail "an appended DIR entry follows a copy entry"
pass "directories are listed before files"

# The entries must parse the way chk_integrity.sh's check_md5sum parses them:
#   data=$(echo $line|cut -d: -f2); md5=$(echo $data|cut -d' ' -f1); file=... -f2
# The unquoted `echo $data` is what collapses the two spaces before the path.
file_line="$(printf '%s\n' "$list" | grep -F "  ./etc/persistent-scripts/patch-storage/support")"
data="$(printf '%s' "$file_line" | cut -d: -f2)"
parsed_md5="$(echo $data | cut -d' ' -f1)"
parsed_path="$(echo $data | cut -d' ' -f2)"
[ "$parsed_md5" = "$support_md5" ] || fail "parser md5 mismatch"
[ "$parsed_path" = "./etc/persistent-scripts/patch-storage/support" ] || fail "parser path mismatch"
pass "entries parse like check_md5sum()"

# --- idempotent, and the vendor list is restorable ---------------------------
file_list_append_added "$IMG"
[ "$(read_img /file_list.txt)" = "$list" ] || fail "second append changed the list"
pass "second append is a no-op"

# pr_reset restores the vendor list only because the append saved it (pr_save).
pr_reset "$IMG"
[ "$(read_img /file_list.txt)" = "$(cat "$TMP/vendor.list")" ] \
    || fail "reset did not restore the vendor /file_list.txt"
pass "reset restores the vendor list"

# A reset is followed by the patch set again; appending must reproduce the list.
apply_fixture
file_list_append_added "$IMG"
[ "$(read_img /file_list.txt)" = "$list" ] || fail "re-append after reset differs"
pass "re-append after reset reproduces the same list"

echo
echo "all file-list tests passed"
