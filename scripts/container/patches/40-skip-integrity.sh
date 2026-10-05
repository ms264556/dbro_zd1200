#!/usr/bin/env bash
#
# 40-skip-integrity.sh — make chk_integrity.sh accept patched files, cheaply.
#
# 1. md5 no-op (required).  The `md5sum -c` line becomes `:` so `check` counts no
#    errors and clone() still copies every listed file.  Rewriting /file_list.txt
#    to SKIP: entries is not an option: clone() copies only entries that pass.
#    Aborts if the line appears twice, or is absent without our marker -- a
#    checker that still hashes would reject the patched root.
# 2. Builtin field splitting (best effort).  The vendor loop forks `echo|cut`
#    four times per list line, ~400 s of system time at boot; it becomes
#    `IFS=: read` and `set -- $data`.  `set --` clobbers the function's $3/$4,
#    which later branches read, so they are saved before the loop and restored
#    after the split.  Applied only when each of the five vendor lines occurs
#    exactly once; otherwise skipped with a warning, never an error.
#
# The halves are independent because a cloned root can carry (1) with no
# rollback store to restore the vendor script from.  Figures and the equivalence
# check: docs/INTERNALS.md, "Notes on individual patches".
#
# Usage: QCOW=<flat-disk> WORK=<workdir> ./40-skip-integrity.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../patch-lib.sh
. "$(dirname "$BASE")/patch-lib.sh"
patch_env

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

apply() { # <name> <img>
    local name="$1" IMG="$2"
    if ! fs_read "$IMG" "$TARGET" "$WORK/chk.orig"; then
        echo "  ! $TARGET not present on $name, skipping"
        return 0
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
        return 0
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
    if [ "$do_parse" = 1 ]; then
        parsed_roots[$name]=1
    fi
    PATCH_APPLIED=1
}

verify() { # <name> <img>: the root as re-read from the disk
    local name="$1"
    rm -f "$WORK/chk.check"
    fs_read "$2" "$TARGET" "$WORK/chk.check" || return 1
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
        return 1
    fi
    return 0
}

patch_main apply verify
