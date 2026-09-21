#!/usr/bin/env bash
#
# patch-lib.sh — shared helpers for the ordered rootfs patches.
#
# Sourced, never executed.  Every rootfs patch uses these helpers for two
# reasons: the debugfs plumbing stays in one place, and every change a patch
# makes is recorded in a per-root rollback store, so a patch set can be
# re-applied to a root that an earlier set already customised.
#
# The store lives inside the root partition it describes:
#
#   /.patchrollback/version         store format version
#   /.patchrollback/sentinel        signature of the patch set last applied
#   /.patchrollback/kernel          hash of the kernel patcher that customised /bzImage
#   /.patchrollback/replaced.list   one mangled path per replaced vendor file
#   /.patchrollback/replaced/<n>        the pristine vendor content
#   /.patchrollback/replaced/<n>.meta   "type mode uid gid"
#   /.patchrollback/added           patch-created paths, deleted on reset
#
# prepare-vm-disks.sh calls pr_reset before re-applying a changed patch set:
# every replaced file is restored from its pristine copy and every added path is
# deleted, so patches always start from the vendor rootfs.  /writable (hda4) is
# never involved.  The kernel is deliberately excluded: it is the largest file
# the pipeline touches, and /bzImage is instead keyed on the kernel patcher that
# produced it (see the kernel step in prepare-vm-disks.sh).
#
# Helpers that write into the root (write_local, symlink_force, mkdir_p,
# remove_path) call pr_save / pr_record_added automatically, so a patch only has
# to use them instead of raw debugfs writes to be rollback-correct.

say() { printf '\n== %s\n' "$*"; }

# --- ext2 primitives ---------------------------------------------------------
# Every caller passes the partition scratch image as the first argument; paths
# are absolute inside that filesystem.

# fs_stat_meta <img> <path> -> "type mode uid gid" (empty output when absent)
fs_stat_meta() {
    debugfs -R "stat $2" "$1" 2>/dev/null \
        | awk '{ for (i = 1; i <= NF; i++) {
                     if ($i == "Type:")  t = $(i+1)
                     else if ($i == "Mode:")  m = $(i+1)
                     else if ($i == "User:")  u = $(i+1)
                     else if ($i == "Group:") g = $(i+1)
                 }} END { if (t != "") print t, m, u, g }'
}

fs_exists() { [ -n "$(fs_stat_meta "$1" "$2")" ]; }

# fs_read <img> <path> <localfile>: nonzero when the file is absent.
fs_read() {
    local img="$1" path="$2" dest="$3"
    rm -f "$dest"
    debugfs -R "dump $path $dest" "$img" >/dev/null 2>&1 || return 1
    [ -f "$dest" ]
}

# fs_write <img> <path> <localfile> <mode> <uid> <gid>: replace a regular file
# and restore the requested metadata (debugfs 'write' lands mode 0644 uid/gid 0).
fs_write() {
    local img="$1" path="$2" src="$3" mode="$4" uid="$5" gid="$6"
    local mode_field
    mode_field="$(printf '010%04o' "$(( 0$mode & 07777 ))")"
    printf 'rm %s\nwrite %s %s\n' "$path" "$src" "$path" > "$WORK/.patchlib.cmds"
    debugfs -w -f "$WORK/.patchlib.cmds" "$img" >/dev/null 2>&1
    rm -f "$WORK/.patchlib.cmds"
    debugfs -w -R "set_inode_field $path mode $mode_field" "$img" >/dev/null 2>&1 || true
    debugfs -w -R "set_inode_field $path uid $uid" "$img" >/dev/null 2>&1 || true
    debugfs -w -R "set_inode_field $path gid $gid" "$img" >/dev/null 2>&1 || true
    if ! fs_read "$img" "$path" "$WORK/.patchlib.verify" \
       || ! cmp -s "$WORK/.patchlib.verify" "$src"; then
        echo "  !! content verification failed for $path; aborting" >&2
        return 1
    fi
    rm -f "$WORK/.patchlib.verify"
    return 0
}

# fs_symlink <img> <linkpath> <target>: force a symlink, replacing anything there.
fs_symlink() {
    debugfs -w -R "rm $2" "$1" >/dev/null 2>&1 || true
    debugfs -w -R "symlink $2 $3" "$1" >/dev/null 2>&1
}

fs_readlink() { # <img> <path>: the target of a fast/long symlink
    debugfs -R "stat $2" "$1" 2>/dev/null \
        | sed -n 's/.*\(Fast link dest\|Symlink\): "\(.*\)".*/\2/p' | head -n1
}

# --- rollback store ----------------------------------------------------------

PR_DIR="/.patchrollback"
PR_REPLACED="$PR_DIR/replaced"
PR_REPLACED_LIST="$PR_DIR/replaced.list"
PR_ADDED="$PR_DIR/added"
PR_VERSION="$PR_DIR/version"
PR_SENTINEL="$PR_DIR/sentinel"
PR_KERNEL="$PR_DIR/kernel"
PR_FORMAT=1

# The vendor root-repair list: chk_integrity.sh's clone() reproduces a root by
# copying the paths it names.  file_list_append_added() below adds the project's
# own paths to it.
FILE_LIST=/file_list.txt
FILE_LIST_MARKER="# zd-container generated additions"

pr_mangle()   { printf '%s' "$1" | sed 's#/#!#g'; }
pr_unmangle() { printf '%s' "$1" | sed 's#!#/#g'; }

pr_has_store() { fs_exists "$1" "$PR_VERSION"; }

pr_init() { # <img>: create the store skeleton (idempotent)
    local img="$1" marker="$WORK/.patchlib.init"
    fs_exists "$img" "$PR_DIR"      || debugfs -w -R "mkdir $PR_DIR" "$img" >/dev/null 2>&1 || true
    fs_exists "$img" "$PR_REPLACED" || debugfs -w -R "mkdir $PR_REPLACED" "$img" >/dev/null 2>&1 || true
    for f in "$PR_VERSION" "$PR_REPLACED_LIST" "$PR_ADDED"; do
        fs_exists "$img" "$f" && continue
        case "$f" in
            "$PR_VERSION") printf '%s\n' "$PR_FORMAT" > "$marker" ;;
            *)             : > "$marker" ;;
        esac
        debugfs -w -R "write $marker $f" "$img" >/dev/null 2>&1 || true
    done
    rm -f "$marker"
}

# A per-process cache keyed on the partition image, so a patch that touches many
# files does not re-read the lists for each one.  Patches handle one partition at
# a time; switching partitions reloads.
_pr_list_for=""
_pr_added_cache=""
_pr_replaced_cache=""

_pr_added_load() { # <img>
    local img="$1"
    if [ "$_pr_list_for" != "$img" ]; then
        _pr_added_cache="$(debugfs -R "cat $PR_ADDED" "$img" 2>/dev/null || true)"
        _pr_replaced_cache="$(debugfs -R "cat $PR_REPLACED_LIST" "$img" 2>/dev/null || true)"
        _pr_list_for="$img"
    fi
}

pr_is_added() { # <img> <path>
    _pr_added_load "$1"
    printf '%s\n' "$_pr_added_cache" | grep -qxF "$2"
}

_pr_list_write() { # <img> <listpath> <content>
    printf '%s\n' "$3" > "$WORK/.patchlib.list"
    debugfs -w -R "rm $2" "$1" >/dev/null 2>&1 || true
    debugfs -w -R "write $WORK/.patchlib.list $2" "$1" >/dev/null 2>&1
    rm -f "$WORK/.patchlib.list"
}

pr_record_added() { # <img> <path>: remember a patch-created path for reset
    local img="$1" path="$2"
    _pr_added_load "$img"
    printf '%s\n' "$_pr_added_cache" | grep -qxF "$path" && return 0
    _pr_added_cache="${_pr_added_cache:+$_pr_added_cache$'\n'}$path"
    _pr_list_write "$img" "$PR_ADDED" "$_pr_added_cache"
}

# pr_save <img> <path>: keep the pristine vendor copy before a patch changes it.
# A path a patch created earlier (already recorded in 'added') has no pristine
# state and is skipped.
pr_save() {
    local img="$1" path="$2"
    local name meta content target type mode uid gid
    if pr_is_added "$img" "$path"; then return 0; fi
    name="$(pr_mangle "$path")"
    meta="$PR_REPLACED/$name.meta"
    content="$PR_REPLACED/$name"
    if fs_exists "$img" "$meta"; then return 0; fi
    fs_exists "$img" "$path" || return 0
    read -r type mode uid gid <<< "$(fs_stat_meta "$img" "$path")"
    case "$type" in
        regular)
            fs_read "$img" "$path" "$WORK/.patchlib.save" \
                || { echo "  !! rollback: cannot read $path" >&2; return 1; }
            debugfs -w -R "rm $content" "$img" >/dev/null 2>&1 || true
            debugfs -w -R "write $WORK/.patchlib.save $content" "$img" >/dev/null 2>&1 \
                || { echo "  !! rollback: cannot store $path" >&2; return 1; }
            rm -f "$WORK/.patchlib.save"
            ;;
        symlink)
            target="$(fs_readlink "$img" "$path")"
            printf '%s' "$target" > "$WORK/.patchlib.save"
            debugfs -w -R "rm $content" "$img" >/dev/null 2>&1 || true
            debugfs -w -R "write $WORK/.patchlib.save $content" "$img" >/dev/null 2>&1 \
                || { echo "  !! rollback: cannot store symlink $path" >&2; return 1; }
            rm -f "$WORK/.patchlib.save"
            ;;
        *)
            echo "  ! rollback: $path is a $type; not saved" >&2
            return 0
            ;;
    esac
    printf '%s %s %s %s\n' "$type" "$mode" "$uid" "$gid" > "$WORK/.patchlib.meta"
    debugfs -w -R "rm $meta" "$img" >/dev/null 2>&1 || true
    debugfs -w -R "write $WORK/.patchlib.meta $meta" "$img" >/dev/null 2>&1 || true
    rm -f "$WORK/.patchlib.meta"
    _pr_added_load "$img"
    printf '%s\n' "$_pr_replaced_cache" | grep -qxF "$name" && return 0
    _pr_replaced_cache="${_pr_replaced_cache:+$_pr_replaced_cache$'\n'}$name"
    _pr_list_write "$img" "$PR_REPLACED_LIST" "$_pr_replaced_cache"
}

# pr_reset <img>: return the root to its vendor state.  Restores every replaced
# file from its pristine copy and deletes every path a patch created.  The store
# itself is kept (the pristine copies are still valid), so a patch run that
# follows re-records additions and leaves the replaced files alone.
pr_reset() {
    local img="$1" name path type mode uid gid target
    pr_has_store "$img" || return 0
    # Delete patch-created paths, deepest first so directories empty out.
    debugfs -R "cat $PR_ADDED" "$img" 2>/dev/null \
        | awk 'NF { d = gsub("/", "/"); print d, $0 }' | sort -rn | cut -d' ' -f2- \
        | while read -r path; do
              [ -n "$path" ] || continue
              debugfs -w -R "rm $path" "$img" >/dev/null 2>&1 || true
              debugfs -w -R "rmdir $path" "$img" >/dev/null 2>&1 || true
          done
    # Restore replaced vendor files.
    debugfs -R "cat $PR_REPLACED_LIST" "$img" 2>/dev/null | awk 'NF' | while read -r name; do
        path="$(pr_unmangle "$name")"
        read -r type mode uid gid \
            <<< "$(debugfs -R "cat $PR_REPLACED/$name.meta" "$img" 2>/dev/null | head -n1)"
        [ -n "$type" ] || continue
        if [ "$type" = "symlink" ]; then
            target="$(debugfs -R "cat $PR_REPLACED/$name" "$img" 2>/dev/null | head -c 4096)"
            fs_symlink "$img" "$path" "$target"
        else
            fs_read "$img" "$PR_REPLACED/$name" "$WORK/.patchlib.restore" || continue
            fs_write "$img" "$path" "$WORK/.patchlib.restore" "$mode" "$uid" "$gid" || true
            rm -f "$WORK/.patchlib.restore"
        fi
    done
    _pr_list_for=""
}

# --- store-aware filesystem helpers ------------------------------------------
# These are what patches should use: each records the pristine copy (or the
# added path) before it overwrites/creates anything.

# write_local <img> <fspath> <localfile> [mode] [uid] [gid]
# An existing file keeps its vendor metadata; the arguments are defaults for a
# file the patch creates.
write_local() {
    local img="$1" fspath="$2" localfile="$3"
    local dmode="${4:-0644}" duid="${5:-0}" dgid="${6:-0}"
    local type mode uid gid
    read -r type mode uid gid <<< "$(fs_stat_meta "$img" "$fspath")"
    if [ -z "$type" ]; then
        pr_record_added "$img" "$fspath"
        mode="$dmode"; uid="$duid"; gid="$dgid"
    else
        pr_save "$img" "$fspath" || return 1
        if [ "$type" != "regular" ]; then
            echo "  ! $fspath was not a regular file (type '$type'); replacing it" >&2
            mode="$dmode"; uid="$duid"; gid="$dgid"
        fi
    fi
    fs_write "$img" "$fspath" "$localfile" "$mode" "$uid" "$gid"
}

# symlink_force <img> <linkpath> <target>
symlink_force() {
    local img="$1" link="$2" target="$3"
    if fs_exists "$img" "$link"; then
        pr_save "$img" "$link" || return 1
    else
        pr_record_added "$img" "$link"
    fi
    fs_symlink "$img" "$link" "$target"
}

# remove_path <img> <path>: remove a file or an emptied directory, preserving a
# vendor file's pristine copy first.
remove_path() {
    local img="$1" path="$2"
    if fs_exists "$img" "$path"; then
        pr_is_added "$img" "$path" || pr_save "$img" "$path" || return 1
    fi
    debugfs -w -R "rm $path" "$img" >/dev/null 2>&1 || true
    debugfs -w -R "rmdir $path" "$img" >/dev/null 2>&1 || true
}

# mkdir_p <img> <path>
mkdir_p() {
    local img="$1" path="$2" p="" part
    local IFS='/'
    for part in $path; do
        [ -n "$part" ] || continue
        p="$p/$part"
        fs_exists "$img" "$p" && continue
        debugfs -w -R "mkdir $p" "$img" >/dev/null 2>&1 || true
        pr_record_added "$img" "$p"
    done
}

# --- root-repair file list ---------------------------------------------------
# chk_integrity.sh clone() reproduces a root from /file_list.txt.  The vendor list
# (buildroot: ext2root.mk) enumerates the vendor rootfs, so a clone already
# carries every vendor file -- 40-skip-integrity makes the md5 check a no-op, so
# patched files are copied too -- but it misses everything the project adds
# afterwards: the patch-created files and the /.patchrollback store.  A cloned
# root then looks uncustomised to prepare-vm-disks.sh, which re-applies the whole
# patch set on top of already patched files.
#
# file_list_append_added() appends those paths after the vendor entries:
#   * DIR:/LINK:/FILE:<md5> for every path in the store's 'added' list -- dirs
#     first, because clone mkdir -p's before copying into them;
#   * one OTHER:./.patchrollback line for the store itself.  check_md5sum's OTHER
#     branch is cp -a with no hash check, so it copies the store recursively and
#     picks up the sentinel prepare-vm-disks.sh writes *after* the patch set, and
#     any store file added later.
#
# The append is idempotent (marker line) and /file_list.txt is saved first, so a
# changed patch set restores the vendor list before re-appending.
file_list_append_added() { # <img>
    local img="$1" path type mode uid gid md5
    local dirs="" files="" store="" flist="$WORK/.patchlib.flist"
    local new="$flist.new"

    if ! fs_exists "$img" "$FILE_LIST"; then
        echo "  ! $FILE_LIST missing; not appending the project's paths" >&2
        return 0
    fi

    if fs_read "$img" "$FILE_LIST" "$flist" \
       && grep -qF "$FILE_LIST_MARKER" "$flist"; then
        rm -f "$flist"
        return 0
    fi

    while read -r path; do
        [ -n "$path" ] || continue
        type=""; mode=""; uid=""; gid=""
        read -r type mode uid gid <<< "$(fs_stat_meta "$img" "$path")" || true
        case "$type" in
            directory)
                dirs="${dirs}DIR:.$path"$'\n' ;;
            symlink)
                files="${files}LINK:.$path"$'\n' ;;
            regular)
                if fs_read "$img" "$path" "$flist.file"; then
                    md5="$(md5sum "$flist.file" | awk '{print $1}')"
                    rm -f "$flist.file"
                    files="${files}FILE:$md5  .$path"$'\n'
                fi ;;
            "") ;;   # a reset already removed it
            *) ;;    # char/block/fifo: the vendor clone cannot reproduce them
        esac
    done < <(debugfs -R "cat $PR_ADDED" "$img" 2>/dev/null | awk 'NF')

    if pr_has_store "$img"; then
        store="OTHER:.$PR_DIR"
    fi

    if [ -z "$dirs$files$store" ]; then
        rm -f "$flist"
        return 0
    fi

    {
        cat "$flist"
        printf '%s\n' "$FILE_LIST_MARKER"
        if [ -n "$dirs" ];  then printf '%s' "$dirs"; fi
        if [ -n "$files" ]; then printf '%s' "$files"; fi
        if [ -n "$store" ]; then printf '%s\n' "$store"; fi
    } > "$new"

    type=""; mode=""; uid=""; gid=""
    read -r type mode uid gid <<< "$(fs_stat_meta "$img" "$FILE_LIST")" || true
    pr_save "$img" "$FILE_LIST" || { rm -f "$flist" "$new"; return 1; }
    fs_write "$img" "$FILE_LIST" "$new" "$mode" "$uid" "$gid"
    rm -f "$flist" "$new"
}

# --- delta write -------------------------------------------------------------
# write_deltas <name> <start-sector>: write only the changed 512-byte blocks of
# $WORK/<name>.img (against the $WORK/<name>.orig.img snapshot) to $QCOW.
# Returns 0 when bytes were written, 1 when nothing changed.
write_deltas() {
    local name="$1" start="$2" off len abs_start
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
        return 1
    fi
    abs_start=$((start * ALIGN))
    while read -r off len; do
        dd if="$WORK/$name.img" of="$WORK/chunk.bin" bs=$ALIGN \
           skip=$((off / ALIGN)) count=$((len / ALIGN)) status=none
        dd if="$WORK/chunk.bin" of="$QCOW" bs=$ALIGN \
           seek=$(((abs_start + off) / ALIGN)) count=$((len / ALIGN)) conv=notrunc status=none
    done < "$WORK/$name.runs"
    return 0
}

snapshot_orig() { cp "$WORK/$1.img" "$WORK/$1.orig.img"; }

# --- which roots a patch may touch ------------------------------------------
# prepare-vm-disks.sh decides per root whether it needs customising (each root
# carries its own /.patchrollback/sentinel) and passes exactly that selection in
# ZD_PATCH_PARTS.  A patch must honour it: writing to a root the caller did not
# select is wrong even when the bytes happen to be identical, because that root
# was deliberately left alone (it is either already current, or its vendor
# files have not been restored first -- see pr_reset).
#
# Called with no argument, or with ZD_PATCH_PARTS unset/empty, this returns the
# full root pair so a patch still runs standalone against a whole disk, which is
# how the patch tests drive them.
#
# Every entry is validated: a malformed selection is refused outright rather
# than partially applied, so a mistake in the caller can never turn into writes
# against the wrong partition.
patch_parts() {
    local spec line bad=0
    if [ -n "${1:-}" ]; then
        spec="$1"
    elif [ -n "${ZD_PATCH_PARTS:-}" ]; then
        spec="$ZD_PATCH_PARTS"
    else
        # Mirror of build-synthetic-cf.py's geometry.  hda1 is the /boot seed and
        # is deliberately absent: it never boots as a root filesystem.
        spec="hda2|84568|415152
hda3|499720|415152"
    fi
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if ! printf '%s' "$line" | grep -qE '^[A-Za-z0-9_]+\|[0-9]+\|[0-9]+$'; then
            echo "patch_parts: malformed partition entry '$line' (want name|start|count)" >&2
            bad=1
        fi
        printf '%s\n' "$line"
    done <<< "$spec"
    [ "$bad" = 0 ]
}

# load_patch_parts: fill the PARTITIONS array from patch_parts, aborting the
# patch when the selection cannot be trusted.  Patches call this rather than a
# bare mapfile so the failure mode is identical in all of them.
#
# patch_parts' status must be captured explicitly: `mapfile ... < <(patch_parts)`
# reports mapfile's own success, so the validation result would be discarded and
# a malformed entry would be captured into PARTITIONS and used.
load_patch_parts() {
    local selection
    if ! selection="$(patch_parts)"; then
        echo "aborting: ZD_PATCH_PARTS is not a usable partition selection" >&2
        exit 1
    fi
    mapfile -t PARTITIONS <<< "$selection"
    # `mapfile <<< ""` yields a single empty element, not an empty array, so the
    # content has to be checked as well: a selection of nothing but blank lines
    # passes patch_parts (which skips them) and would otherwise reach the patches
    # as one nameless partition.
    [ "${#PARTITIONS[@]}" -gt 0 ] && [ -n "${PARTITIONS[0]:-}" ] || {
        echo "aborting: empty partition selection" >&2
        exit 1
    }
}

# spot_img: the verify image of a root this run actually patched, for the
# content spot-checks some patches print at the end.
#
# Those checks used to name $WORK/hda2.verify.img unconditionally.  That file
# only exists when hda2 was part of the run, so when the caller selects just the
# other root -- an in-guest firmware upgrade passes only the stale root -- the
# debugfs fails, and under `set -e` with `pipefail` the spot-check aborts the
# whole patch.  Always point them at a root that is in the selection.
spot_img() {
    local first="${PARTITIONS[0]:-}"
    [ -n "$first" ] || return 1
    printf '%s' "$WORK/${first%%|*}.verify.img"
}

# extract_part / write_part are used by prepare-vm-disks.sh rather than by the
# patches (which extract their own copy so they can run standalone).
extract_part() { dd if="$QCOW" of="$WORK/$1.img" bs=$ALIGN skip="$2" count="$3" status=none; }
write_part()   { dd if="$WORK/$1.img" of="$QCOW" bs=$ALIGN seek="$2" count="$3" conv=notrunc status=none; }
