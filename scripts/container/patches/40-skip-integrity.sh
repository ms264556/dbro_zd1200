#!/usr/bin/env bash
#
# 40-skip-integrity.sh — stop the ZD1200 rootfs integrity checker rejecting the
# project's patched files, and stop its line parsing from burning the boot.
#
# /etc/init.d/chk_integrity.sh md5-verifies every FILE entry in /file_list.txt.
# The project's deliberately-patched files (the kernel, the v54 escape helper,
# dropbear, sys_wrapper's signing bypass, ...) do not match the vendor hashes, so
# the checker reports "file:[./...] corrupted" and counts an error for each.
#
# The md5 verification is replaced with a no-op, which keeps every listed file
# acceptable:
#
#   * `check` and `check-rootfs` count no errors, so the vendor warnings are
#     gone;
#   * `clone` copies the whole listed tree, patched files included, so
#     flag_reset's repair of the primary root after a watchdog fallback works.
#
# The no-op alone is not enough.  check_md5sum() still splits every list line
# with `type=`echo $line|cut -d: -f1`` and `data=`echo $line|cut -d: -f2` — two
# `echo|cut` pipelines, so four fork/execs and two pipes per line — plus
# `md5=`echo $data|cut -d' ' -f1`` and `file=`echo $data|cut -d' ' -f2`` on every
# FILE line.  Boot's `check` mode runs that loop three times (the root list, the
# firmwares list — empty on the rig — and /writable/aidfs/file_list.txt); at two
# fork/execs per `echo|cut` pipeline that is 25,812 fork/execs and 12,906 pipes
# over the measured lists (3,626 lines, 2,827 of them FILE).  Measured in-guest,
# that is the ~400 s of system time (66.6% sy) that blocks everything after
# S70resetflag — S98zd_container_control and the console getty included.  So the
# splitting is rewritten to shell builtins, `while IFS=: read -r type data` for
# the line and `set -- $data` for the two FILE fields, which removes every one of
# those forks.
#
# The rewrite was measured equivalent before it was written, over every line of
# the real lists (the live root list, 3,080 lines; /writable/aidfs/file_list.txt,
# 546 lines; the firmwares list, 310 lines from the vendor archive — it is empty
# on the rig): the derived type, md5 and file are identical on every line.  Every
# line but the project's own `# zd-container ...` marker carries exactly one
# colon, and every FILE line separates the hash from the path with exactly two
# spaces.  The only difference is the `data` string of a FILE line: the vendor's
# unquoted `echo $data` collapses the two spaces where `read` keeps them, and
# `set -- $data` collapses them again, so `file` — the field clone consumes —
# comes out the same.  That is also why the tempting `${data#* }` / `${data%% *}`
# pair must not be used here: it would leave `file` with a leading space, and on
# a tab it would take the whole line as the hash.
#
# `set --` replaces the *function's* positional parameters, and the vendor's
# FILE/DIR/LINK/OTHER branches read $3 (the command) and $4 (the copy
# destination) from them; a split that clobbered those would make clone() copy
# nothing at all.  The four arguments are therefore captured before the loop and
# restored straight after the FILE split, so $3/$4 are correct for the rest of
# that iteration and for every later one.  check mode passes no fourth argument,
# and the restore keeps its three-argument arity instead of inventing one.
#
# The md5 no-op is the load-bearing half: it is applied wherever exactly one md5
# line is present, and refused only where the checker is genuinely unsafe to
# leave (no md5 line and no marker of ours, or more than one md5 line).  The
# parsing rewrite is only a performance optimisation and is therefore strictly
# *best-effort*: it is applied when the vendor's five loop
# lines are each present exactly once, so the rewrite is certain, and in every
# other case -- a partial set of them, a repeated one, a differently-worded or
# otherwise unfamiliar release, or a script already carrying the builtins -- the
# rewrite is skipped with a warning and the md5 no-op path still proceeds.
#
# That asymmetry is deliberate and must not be "tightened" into an abort.  The
# patch runs under `set -euo pipefail` from prepare-vm-disks.sh, which runs every
# patch with `bash "$patch"` and aborts provisioning on a non-zero exit; the
# entrypoint treats that as "shut the container down", so a patch that refuses an
# unfamiliar vendor script costs the user the whole customised appliance.  An
# unrecognised release must lose the speed-up, not the appliance: worse boot time
# is recoverable, a partition that was never provisioned is not.
#
# The md5 line gone *and* our marker in place is the "already patched" state;
# that is the only state this patch writes nothing for.  Two other states still
# write: the vendor md5 line present (both rewrites may apply), and the md5 line
# gone with the marker present but the vendor parsing still there -- a root an
# earlier patch set no-op'd -- which gets the parsing rewrite and nothing else.
# That second state is why the parsing rewrite cannot hang off do_md5: the
# rollback store is only guaranteed for roots the pipeline has customised, and a
# repaired clone has no store to restore from, so the md5 no-op being present
# must not be read as "nothing left to do".  Restoring the pristine checker from
# the rollback store, which prepare-vm-disks.sh does before a changed patch set
# is re-applied, is the route by which a root can still get both at once.
#
# Rewriting /file_list.txt itself is not an option: check_md5sum() copies exactly
# the entries whose md5 matches, so a list of SKIP: entries makes clone() copy
# nothing and the "repaired" partition holds only /bzImage and /file_list.txt.
#
# Applied to the ROOT partitions of the flat disk (hda2/hda3) with the same
# read -> debugfs -> dd channel as the other rootfs patches.
#
# Usage:
#   QCOW=<flat-disk> WORK=<workdir> ./"40-skip-integrity.sh"
#
# Re-patching: the pristine /etc/init.d/chk_integrity.sh and /file_list.txt are
# kept in the root's /.patchrollback store (pr_save), so prepare-vm-disks.sh
# restores both before a changed patch set is re-applied.  Applying the patch to
# a root that has no rollback store (a repaired clone) is safe: it rewrites only
# the vendor text it recognises.
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCOW="${QCOW:-$(dirname "$BASE")/synthetic-cf.img}"
WORK="${WORK:-$(dirname "$BASE")/.rootfs-patch-work}"
ALIGN=512
# shellcheck source=../patch-lib.sh
. "$(dirname "$BASE")/patch-lib.sh"

TARGET="/etc/init.d/chk_integrity.sh"
MD5_PATTERN='/usr/bin/md5sum -c'
MARKER='zd-container: accept patched files'
REPLACEMENT="                : # $MARKER (so clone still copies them)"

# The vendor loop's parsing, one distinctive fragment per line.  Each is present
# exactly once in an unpatched vendor script and absent once the rewrite has run,
# so the two states are told apart by counting, not by a version marker.  The
# fragments carry no single quotes on purpose: they are matched with index() in
# awk below, inside a single-quoted awk program.
PARSE_LOOP='while read line; do'
PARSE_TYPE='type=`echo $line|cut'
PARSE_DATA='data=`echo $line|cut'
PARSE_MD5='md5=`echo $data|cut'
PARSE_FILE='file=`echo $data|cut'
LOOP_NEW='    while IFS=: read -r type data; do'

# count_fixed <pattern> <file>: lines containing <pattern>, 0 when none.
count_fixed() { grep -cF -- "$1" "$2" || true; }

# check_at_most_once <count> <description>: the one vendor line whose absence and
# duplication are both genuinely unsafe is the md5 check; rewriting one of two
# occurrences would leave the other hashing.
check_at_most_once() {
    if [ "$1" -gt 1 ]; then
        echo "  !! $TARGET has $1 occurrences of $2; expected at most 1; aborting" >&2
        exit 1
    fi
}

# The roots whose parsing this run actually rewrote.  The read-back verification
# below checks the builtin half only for these: where the rewrite was skipped on
# purpose, the vendor's own `echo|cut` lines are still there and must not be
# reported as a failure.
declare -A parsed_roots=()

# The roots this run may touch: prepare-vm-disks.sh passes its per-root
# selection in ZD_PATCH_PARTS; with none set this is the full root pair
# (patch-lib.sh:patch_parts), which is how the patch tests drive it.
load_patch_parts

[ -f "$QCOW" ] || { echo "QCOW not found: $QCOW" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"

say "reading the flat disk $QCOW"
ln -sf "$QCOW" "$WORK/flat.raw"

patched_any=0
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    say "[$name] extracting partition (sector $start, ${sectors}s)"
    extract_part "$name" "$start" "$sectors"
    snapshot_orig "$name"
    IMG="$WORK/$name.img"
    pr_init "$IMG"

    if ! fs_read "$IMG" "$TARGET" "$WORK/chk.orig"; then
        echo "  ! $TARGET not present on $name, skipping"
        continue
    fi

    n_md5=$(count_fixed "$MD5_PATTERN" "$WORK/chk.orig")
    n_loop=$(count_fixed "$PARSE_LOOP" "$WORK/chk.orig")
    n_type=$(count_fixed "$PARSE_TYPE" "$WORK/chk.orig")
    n_data=$(count_fixed "$PARSE_DATA" "$WORK/chk.orig")
    n_pmd5=$(count_fixed "$PARSE_MD5" "$WORK/chk.orig")
    n_file=$(count_fixed "$PARSE_FILE" "$WORK/chk.orig")

    # The md5 half keeps the hard checks it has always had: a vendor line
    # repeated, or an md5 line gone without our marker, means the root is in a
    # state this patch cannot reason about, and that is still refused.
    check_at_most_once "$n_md5" "$MD5_PATTERN"

    do_md5=$(( n_md5 == 1 ))

    if [ "$do_md5" = 0 ] && ! grep -qF "$MARKER" "$WORK/chk.orig"; then
        # No md5 line and no marker of ours: the checker is genuinely
        # unrecognisable, and this is one of the two states that must not be
        # left as-is.
        echo "  !! $TARGET on $name has no md5 check and not our marker; aborting" >&2
        exit 1
    fi

    # The parsing rewrite is best-effort, and only applied when it is certain:
    # each of the vendor's five loop lines present exactly once, so the single
    # awk pass below rewrites the whole loop and nothing else.  Anything short of
    # that -- a partial set, a repeated line, or a differently-worded release --
    # loses the rewrite and keeps the vendor parsing; it must not fail the patch,
    # because a non-zero exit here aborts provisioning of the whole appliance.
    n_parse=$(( n_loop + n_type + n_data + n_pmd5 + n_file ))
    if [ "$n_loop" = 1 ] && [ "$n_type" = 1 ] && [ "$n_data" = 1 ] \
       && [ "$n_pmd5" = 1 ] && [ "$n_file" = 1 ]; then
        do_parse=1
    else
        do_parse=0
    fi

    # Both halves already done: the root carries our no-op (do_md5 is 0, which is
    # only reachable above with the marker present) and its parsing is not the
    # vendor's.  There is nothing to write.
    if [ "$do_md5" = 0 ] && [ "$do_parse" = 0 ]; then
        echo "  $TARGET on $name is already patched (nothing to do)"
        continue
    fi

    if [ "$do_parse" = 0 ]; then
        if [ "$n_parse" = 0 ]; then
            echo "  $TARGET on $name already carries the builtin parsing; skipping the rewrite"
        else
            echo "  ! $TARGET on $name matches only $n_parse of the vendor loop's 5 parsing lines; skipping the parsing rewrite and keeping the vendor parsing" >&2
        fi
    fi

    if [ "$do_md5" = 1 ]; then
        echo "  replacing the md5 verification in $TARGET with a no-op"
    else
        echo "  $TARGET on $name already has the md5 no-op; rewriting only its parsing"
    fi
    if [ "$do_parse" = 1 ]; then
        echo "  rewriting $TARGET's field splitting to shell builtins"
    fi

    # One pass, one rule per vendor line, every other line copied byte for byte.
    # The FILE branch prints the split and the restore together because the two
    # vendor lines it replaces are adjacent.  The loop header comes from
    # $LOOP_NEW so the verification below and the text written here cannot drift.
    # The four parsing rules are gated on do_parse: with the rewrite skipped they
    # must copy the vendor's own lines byte for byte, which is the whole point of
    # skipping -- deleting some of them and leaving others would be the
    # half-rewrite that this path exists to avoid.  Only the md5 rule is
    # unconditional.  The comparison is `do_parse == 1` and not bare `do_parse`
    # because awk takes the *string* "0" as true when -v assigns it from the
    # shell, which would let the gate through exactly when it must not.
    awk -v rep="$REPLACEMENT" -v loop_new="$LOOP_NEW" -v do_parse="$do_parse" '
        index($0, "/usr/bin/md5sum -c")   { print rep; next }
        (do_parse == 1) && index($0, "while read line; do")  {
            print "    _arg1=\"$1\"; _arg2=\"$2\"; _cmd=\"$3\"; _have4=${4+1}; _dest=\"${4-}\";"
            print loop_new
            next
        }
        (do_parse == 1) && index($0, "type=`echo $line|cut") { next }
        (do_parse == 1) && index($0, "data=`echo $line|cut") { next }
        (do_parse == 1) && index($0, "md5=`echo $data|cut")  {
            print "            set -- $data"
            print "            md5=$1"
            print "            file=$2"
            print "            set -- \"$_arg1\" \"$_arg2\" \"$_cmd\" ${_have4:+\"$_dest\"}"
            next
        }
        (do_parse == 1) && index($0, "file=`echo $data|cut") { next }
        { print }
    ' "$WORK/chk.orig" > "$WORK/chk.new"

    write_local "$IMG" "$TARGET" "$WORK/chk.new"

    if write_deltas "$name" "$start"; then
        patched_any=1
        if [ "$do_parse" = 1 ]; then
            parsed_roots[$name]=1
        fi
    else
        echo "  no byte changes for $TARGET on $name (already patched on the disk?)"
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
    fs_read "$WORK/$name.verify.img" "$TARGET" "$WORK/chk.check" || true
    # The md5 half is always verified: it is the half every root gets.  The
    # builtin half is verified only on a root whose parsing this run rewrote --
    # where the rewrite was skipped deliberately, the vendor's `echo|cut` lines
    # are still in the script and are exactly what should be there.
    if grep -qF "$MARKER" "$WORK/chk.check" && ! grep -qF "$MD5_PATTERN" "$WORK/chk.check" \
       && { [ -z "${parsed_roots[$name]+set}" ] \
            || { ! grep -qF "$PARSE_TYPE" "$WORK/chk.check" \
                 && ! grep -qF "$PARSE_DATA" "$WORK/chk.check" \
                 && ! grep -qF "$PARSE_MD5" "$WORK/chk.check" \
                 && ! grep -qF "$PARSE_FILE" "$WORK/chk.check" \
                 && grep -qF "$LOOP_NEW" "$WORK/chk.check" \
                 && grep -qF 'set -- $data' "$WORK/chk.check" \
                 && grep -qF '_have4' "$WORK/chk.check"; }; }; then
        echo "OK   $name: $TARGET md5 check disabled, marker present"
    else
        echo "FAIL $name: $TARGET was not patched as expected" >&2
        exit 1
    fi
done

if [ "${#parsed_roots[@]}" -gt 0 ]; then
    say "done — integrity check bypassed and its parsing rewritten in $QCOW (clone still copies)"
else
    say "done — integrity check bypassed in $QCOW (clone still copies; parsing left as the vendor wrote it)"
fi
