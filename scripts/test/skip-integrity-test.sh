#!/usr/bin/env bash
#
# skip-integrity-test.sh — 40-skip-integrity.sh must rewrite chk_integrity.sh's
# line parsing without changing what the loop does.
#
# The patch replaces the vendor's per-line `echo $line|cut -d: -f1` splitting
# (two fork/execs and a pipe per line — measured in-guest at ~400 s of system
# time over a boot) with shell builtins.  The rewrite splits the line with
# `while IFS=: read -r type data` and the FILE fields with `set -- $data`, and
# `set --` replaces the *function's* positional parameters — which the
# FILE/DIR/LINK/OTHER branches read $3 (the command) and $4 (the copy
# destination) from.  A rewrite that overlooked that would leave clone() copying
# nothing, so the important assertion here is behavioural: drive the real patch
# script against a fixture ext2 root carrying a synthetic vendor-shaped
# /etc/init.d/chk_integrity.sh, then run the patched check_md5sum in clone mode
# and require it to copy exactly what the unpatched loop copies.
#
# Also checked: the md5 no-op survives and the echo|cut parsing is gone, the
# patched script parses (`sh -n`), no `cp -a`/`mkdir -p`/`$3`/`$4` line of the
# vendor text changed, the two parsers agree on a fixture /file_list.txt, and a
# second run is a no-op.
#
# The regression that this file exists to pin down as well: the parsing rewrite
# is strictly best-effort.  The patch runs under `set -euo pipefail` from
# prepare-vm-disks.sh, which aborts provisioning when a patch exits non-zero, and
# the entrypoint reads that as "shut the container down" -- so a patch that
# refuses a vendor script it does not recognise costs the whole customised
# appliance, not just the speed-up.  The md5 no-op is the part that must always
# land.  So a checker whose loop is worded differently, or that matches only some
# of the five vendor lines, or that already carries the builtins, must still get
# the md5 no-op, must have its parsing left alone, must pass the patch's own
# read-back verification, and must exit 0.  Refusal is reserved for the two
# genuinely unsafe md5 states: no md5 line and no marker of ours, and more than
# one md5 line.
#
# The fixture is synthesised: the vendor's checker is vendor material and is not
# in this repository.  AS_CHKINT=<path> runs the same assertions against a real
# /etc/init.d/chk_integrity.sh (one dumped from a guest rootfs); without it that
# half prints a `partial:` line saying so.  `partial:` is the runner's third
# classification (scripts/test/run-suite.sh): the test ran and evaluated its
# synthetic fixture, but not the real vendor script -- so it is counted as run
# rather than as having evaluated nothing.
#
# Usage: ./scripts/test/skip-integrity-test.sh
#        AS_CHKINT=/path/to/chk_integrity.sh ./scripts/test/skip-integrity-test.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATCH="$REPO/scripts/container/patches/40-skip-integrity.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-skipint.XXXXXX")"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }
skipped() { printf 'skipped: %s\n' "$*"; }
# partial: ran, but only against what this test carries itself.  The runner
# counts a partial test as RAN (scripts/test/run-suite.sh's marker contract) so a
# test that evaluated its synthetic fixture is not recorded as having evaluated
# nothing, while the real vendor material it could not carry stays visible.
partial() { printf 'partial: %s\n' "$*"; }

for tool in mke2fs debugfs; do
    command -v "$tool" >/dev/null 2>&1 \
        || { echo "SKIP: $tool not found (e2fsprogs is required)" >&2; exit 0; }
done
# The unpatched loop this test compares against runs the vendor's own
# /usr/bin/md5sum -c; without it every FILE entry would read as corrupted.
[ -x /usr/bin/md5sum ] || { echo "SKIP: /usr/bin/md5sum not found" >&2; exit 0; }
[ -f "$PATCH" ] || fail "missing $PATCH"

MARKER="$(sed -n "s/^MARKER='\(.*\)'$/\1/p" "$PATCH")"
MD5_PATTERN='/usr/bin/md5sum -c'
[ -n "$MARKER" ] || fail "could not read MARKER out of $PATCH"

ALIGN=512
START=84568                  # the flat disk's hda2 sector, as patch-lib defines it
SECTORS=32768                # 16 MiB, enough for the fixture root
TARGET=/etc/init.d/chk_integrity.sh

# --- the fixture root the clone check copies from ----------------------------
# The list's paths are relative to `/`, because that is how the vendor calls the
# loop in clone mode ($1 is /, $2 the live /file_list.txt, $4 the mounted
# destination) and because the FILE branch copies from `"/$file"`.  Everything
# named here lives inside this test's own temporary directory.
REL="${TMP#/}/root"
mkdir -p "$TMP/root/dirA" "$TMP/root/sub" "$TMP/root/usr/bin" "$TMP/root/store"
printf 'A\n' > "$TMP/root/fileA"
printf 'B\n' > "$TMP/root/sub/fileB"
printf 'S\n' > "$TMP/root/store/s"
ln -s fileA "$TMP/root/linkA"
# A real class from the guest's list: symlinks whose names are glob patterns.
ln -s ../../bin/busybox "$TMP/root/usr/bin/["
MD5A="$(md5sum "$TMP/root/fileA" | awk '{print $1}')"
MD5B="$(md5sum "$TMP/root/sub/fileB" | awk '{print $1}')"
{
    printf 'DIR:%s\n' "$REL/dirA" "$REL/sub" "$REL/usr" "$REL/usr/bin" "$REL/store"
    printf 'FILE:%s  %s\n' "$MD5A" "$REL/fileA"
    printf 'FILE:%s  %s\n' "$MD5B" "$REL/sub/fileB"
    printf 'LINK:%s\n' "$REL/linkA" "$REL/usr/bin/["
    printf 'SKIP:%s\n' "$REL/skipped"
    printf 'OTHER:%s\n' "$REL/store"
    printf '# zd-container generated additions\n'
} > "$TMP/file_list.txt"

# --- the synthetic vendor-shaped checker -------------------------------------
# The vendor's check_md5sum() verbatim, including the two spaces between the
# hash and the path in its md5sum input and the `$3`/`$4` reads the rewrite has
# to preserve.  A function-only file, so a test can source it.
cat > "$TMP/chk.fixture.sh" <<'FIXTURE'
#!/bin/sh
# A synthetic stand-in for the vendor /etc/init.d/chk_integrity.sh, shaped like
# the real check_md5sum() (which is vendor material and is not in this repo).

check_md5sum()
{
    ret=0;
    if [ ! -f $2 ]; then
        echo "No file list founded ...";
        return 1;
    fi

    popd=`pwd`
    cd $1;

    while read line; do
        #TODO: I/O loading detections
        #await=(ruse+wuse)/(rio+wio)

        type=`echo $line|cut -d: -f1`;
        data=`echo $line|cut -d: -f2`;
        case "$type" in
        FILE)
            md5=`echo $data|cut -d' ' -f1`
            file=`echo $data|cut -d' ' -f2`

            #If it is a char or blk dev, skip...
            if [ ! -b "$file" -a ! -c "$file" ]; then
                echo "$md5  $file"|/usr/bin/md5sum -c >/dev/null 2>&1
            fi

            if [ $? -eq 0 ]; then
                if [ "$3" = "clone" ]; then
                    cp -a "/$file" "$4/$file";
                fi
            else
                echo "file:[$file] corrupted"
                ret=`expr $ret + 1`
            fi
        ;;
        DIR)
            if [ -d "$data" ]; then
                if [ "$3" = "clone" ]; then
                    mkdir -p "$4/$data";
                fi
            else
                echo "dir:[$data] corrupted"
                ret=`expr $ret + 1`
            fi
        ;;
        LINK)
            if [ -h "$data" ]; then
                if [ "$3" = "clone" ]; then
                    cp -a "$data" "$4/$data";
                fi
            else
                echo "link:[$data] corrupted"
                ret=`expr $ret + 1`
            fi
        ;;
        OTHER)
            if [ "$3" = "clone" ]; then
                cp -a $data $4/$data;
            fi
        ;;
        esac
    done < $2

    cd $popd
    return $ret;
}
FIXTURE

# --- helpers -----------------------------------------------------------------
build_disk() { # <checker> <disk>
    local stage="$TMP/stage.$$"
    rm -rf "$stage"; mkdir -p "$stage/etc/init.d"
    cp "$1" "$stage/etc/init.d/chk_integrity.sh"
    cp "$TMP/file_list.txt" "$stage/file_list.txt"
    ext2_disk_from_stage "$stage" "$2" "$START" "$SECTORS" "$ALIGN" || fail "mke2fs failed"
    rm -rf "$stage"
}

run_patch() { # <disk> <workdir> <log>
    ZD_PATCH_PARTS="hda2|$START|$SECTORS" QCOW="$1" WORK="$2" \
        bash "$PATCH" > "$3" 2>&1
}

read_back() { # <disk> <fspath> <out>
    part_image "$1" "$TMP/part.read.img" "$START" "$SECTORS" "$ALIGN"
    rm -f "$3"
    fs_dump "$TMP/part.read.img" "$2" "$3"
    [ -s "$3" ]
}

fn_of() { sed -n '/^check_md5sum()/,/^}/p' "$1"; }

# md5_line_of <script>: the line carrying the vendor's md5 invocation.
md5_line_of() { grep -F "$MD5_PATTERN" "$1"; }
MD5_LINE="$(md5_line_of "$TMP/chk.fixture.sh")"
[ -n "$MD5_LINE" ] || fail "could not read the vendor md5 line out of the fixture"

# only_md5_changed <src> <patched> <label>: assert the patched script differs
# from the source in the md5 line alone.  This is the sharp form of "its parsing
# was left alone": a skipped parsing rewrite must add or remove no other line,
# because a half-rewritten loop is the failure mode this patch refuses to risk.
# Any line carrying the md5 pattern or the marker is normalised on both sides, so
# the vendor line and our no-op compare equal and everything else is compared
# byte for byte.
only_md5_changed() {
    local src="$1" patched="$2" label="$3" n_src n_patched
    n_src="$(grep -cF "$MD5_PATTERN" "$src" || true)"
    n_patched="$(grep -cF "$MD5_PATTERN" "$patched" || true)"
    [ "$n_src" = 1 ] && [ "$n_patched" = 0 ] \
        || fail "$label: expected exactly one md5 line before and none after (got $n_src then $n_patched)"
    if ! diff -u \
         <(awk -v p="$MD5_PATTERN" -v m="$MARKER" '{ print ((index($0, p) || index($0, m)) ? "MD5LINE" : $0) }' "$src") \
         <(awk -v p="$MD5_PATTERN" -v m="$MARKER" '{ print ((index($0, p) || index($0, m)) ? "MD5LINE" : $0) }' "$patched") \
         > "$TMP/$label.parsing.diff"; then
        fail "$label: the patch changed the parsing, which it was supposed to leave alone:
$(cat "$TMP/$label.parsing.diff")"
    fi
    pass "$label: the md5 line is the only line the patch touched"
}

# clone_tree <script> <dest>: run that script's check_md5sum in clone mode.
clone_tree() {
    local fn="$TMP/fn.$$"
    fn_of "$1" > "$fn"
    [ -s "$fn" ] || fail "no check_md5sum() in $1"
    rm -rf "$2"; mkdir -p "$2"
    # shellcheck disable=SC1090
    ( . "$fn"; check_md5sum / "$TMP/file_list.txt" clone "$2" ) \
        > "$TMP/clone.log" 2>&1 || true
    rm -f "$fn"
}

tree_of() { ( cd "$1" && find . -mindepth 1 | LC_ALL=C sort ); }

text_checks() { # <patched-script> <label>
    local f="$1" label="$2"
    grep -qF 'while IFS=: read -r type data; do' "$f" \
        || fail "$label: the builtin read loop is not in the patched script"
    grep -qF 'set -- $data' "$f" \
        || fail "$label: the FILE fields are not split with set --"
    grep -qF "$MARKER" "$f" || fail "$label: the md5 no-op marker is gone"
    grep -qF '_have4' "$f" \
        || fail "$label: the positional parameters are not captured/restored"
    if grep -qF "$MD5_PATTERN" "$f"; then
        fail "$label: the md5 check is still present"
    fi
    if grep -qF 'echo $line|cut' "$f" || grep -qF 'echo $data|cut' "$f"; then
        fail "$label: the echo|cut parsing survives"
    fi
    sh -n "$f" || fail "$label: the patched script does not parse"
    pass "$label: builtin parsing present, md5 no-op kept, script parses"
}

# expect_clone <unpatched-script> <patched-script> <label>
expect_clone() {
    local before="$TMP/$3.clone.before" after="$TMP/$3.clone.after" bt at
    clone_tree "$1" "$before"
    clone_tree "$2" "$after"
    bt="$(tree_of "$before")"
    at="$(tree_of "$after")"
    [ -n "$bt" ] \
        || fail "$3: the unpatched loop copied nothing, so the fixture is wrong"
    [ "$bt" = "$at" ] || fail "$3: clone mode copied a different tree after the rewrite:
--- unpatched
$bt
--- patched
$at"
    cmp -s "$before/$REL/fileA" "$after/$REL/fileA" \
        || fail "$3: the copied FILE contents differ"
    cmp -s "$before/$REL/sub/fileB" "$after/$REL/sub/fileB" \
        || fail "$3: the copied nested FILE contents differ"
    pass "$3: clone copies the same $(printf '%s\n' "$at" | wc -l | tr -d ' ')-entry tree as before the rewrite"

    # check mode passes no $4, so exercise the three-argument path too, under
    # `set -u`, which the restore's ${4-}/${4+1} forms have to tolerate.
    fn_of "$2" > "$TMP/fn.check"
    # shellcheck disable=SC1090
    ( set -u; . "$TMP/fn.check"; check_md5sum / "$TMP/file_list.txt" check ) \
        > "$TMP/check.log" 2>&1 || fail "$3: check mode failed after the rewrite:
$(cat "$TMP/check.log")"
    if grep -q 'corrupted' "$TMP/check.log"; then
        fail "$3: check mode reported corruption:
$(cat "$TMP/check.log")"
    fi
    pass "$3: check mode (no \$4) still succeeds under set -u"
}

# parse_records <vendor|builtin>: one "type|data|md5|file" record per list line.
parse_records() {
    if [ "$1" = vendor ]; then
        while read line; do
            type=`echo $line|cut -d: -f1`
            data=`echo $line|cut -d: -f2`
            case "$type" in
            FILE) md5=`echo $data|cut -d' ' -f1`; file=`echo $data|cut -d' ' -f2`;;
            *) md5=""; file="";;
            esac
            printf '%s|%s|%s|%s\n' "$type" "$data" "$md5" "$file"
        done
    else
        while IFS=: read -r type data; do
            case "$type" in
            FILE) set -- $data; md5="$1"; file="$2";;
            *) md5=""; file="";;
            esac
            printf '%s|%s|%s|%s\n' "$type" "$data" "$md5" "$file"
        done
    fi
}

expect_same_parsing() { # <label>
    parse_records vendor  < "$TMP/file_list.txt" > "$TMP/rec.vendor"
    parse_records builtin < "$TMP/file_list.txt" > "$TMP/rec.builtin"
    if awk -F'|' '
        NR == FNR { vt[FNR]=$1; vd[FNR]=$2; vm[FNR]=$3; vf[FNR]=$4; n=FNR; next }
        {
            if ($1 != vt[FNR] || $3 != vm[FNR] || $4 != vf[FNR]) { bad++; next }
            if ($1 == "DIR" || $1 == "LINK" || $1 == "OTHER") {
                if ($2 != vd[FNR]) bad++
                next
            }
            if ($1 != "FILE") next        # no branch reads $data
            a = vd[FNR]; b = $2
            gsub(/[ \t]+/, " ", a); gsub(/[ \t]+/, " ", b)
            if (a != b) bad++
        }
        END { exit (bad ? 1 : 0) }
    ' "$TMP/rec.vendor" "$TMP/rec.builtin"; then
        pass "$1: the two parsers agree on all $(wc -l < "$TMP/file_list.txt" | tr -d ' ') fixture lines"
    else
        fail "$1: the vendor and builtin parsers disagree on the fixture list:
$(diff "$TMP/rec.vendor" "$TMP/rec.builtin" | head -10)"
    fi
}

# --- the transformation itself ----------------------------------------------
exercise() { # <label> <checker>
    local label="$1" src="$2" disk="$TMP/$1.disk" work="$TMP/$1.work" hash
    build_disk "$src" "$disk"
    run_patch "$disk" "$work" "$TMP/$label.patch1.log" \
        || fail "$label: the patch failed:
$(cat "$TMP/$label.patch1.log")"
    read_back "$disk" "$TARGET" "$TMP/$label.patched" \
        || fail "$label: $TARGET is unreadable after patching"
    text_checks "$TMP/$label.patched" "$label"

    # Every line the rewrite did not have to touch must be byte-identical.  The
    # FILE/DIR/LINK/OTHER branches carry the writes, so a diff that removed one
    # of their lines — a `cp -a`, a `mkdir -p`, or a `$3`/`$4` read — is a
    # failure even when this run's fixture happens to behave the same.  The only
    # added lines allowed to name `$3`/`$4` are the argument capture and the
    # restore, which are the whole point of the patch.
    diff "$src" "$TMP/$label.patched" > "$TMP/$label.diff" || true
    if grep -E '^< ' "$TMP/$label.diff" | grep -qE 'cp -a|mkdir -p|\[ -d |\[ -h |"\$3"|"\$4"'; then
        fail "$label: the rewrite removed a vendor branch line:
$(grep -E '^< ' "$TMP/$label.diff" | grep -E 'cp -a|mkdir -p|\[ -d |\[ -h |"\$3"|"\$4"')"
    fi
    if grep -E '^> ' "$TMP/$label.diff" | grep -qE 'cp -a|mkdir -p|\[ -d |\[ -h '; then
        fail "$label: the rewrite added a write or a directory test:
$(grep -E '^> ' "$TMP/$label.diff" | grep -E 'cp -a|mkdir -p|\[ -d |\[ -h ')"
    fi
    if grep -E '^> ' "$TMP/$label.diff" | grep -E '"\$3"|"\$4"' | grep -qvE '_arg1=|_have4:'; then
        fail "$label: the rewrite added an unexpected \$3/\$4 line:
$(grep -E '^> ' "$TMP/$label.diff" | grep -E '"\$3"|"\$4"' | grep -vE '_arg1=|_have4:')"
    fi
    pass "$label: every branch line of the vendor loop is unchanged"

    expect_clone "$src" "$TMP/$label.patched" "$label"
    expect_same_parsing "$label"

    # The rewrite must be idempotent: a second run over the patched disk reports
    # it as already patched and writes nothing.
    hash="$(sha256sum "$disk" | awk '{print $1}')"
    run_patch "$disk" "$work" "$TMP/$label.patch2.log" \
        || fail "$label: the second run failed:
$(cat "$TMP/$label.patch2.log")"
    grep -q 'already patched (nothing to do)' "$TMP/$label.patch2.log" \
        || fail "$label: the second run did not recognise the patched root:
$(cat "$TMP/$label.patch2.log")"
    [ "$hash" = "$(sha256sum "$disk" | awk '{print $1}')" ] \
        || fail "$label: a second run rewrote the disk"
    pass "$label: a second run is a no-op and leaves the disk byte-identical"
}

echo "=== a synthetic vendor-shaped $TARGET ==="
exercise fixture "$TMP/chk.fixture.sh"

# --- the best-effort half: the md5 no-op always lands, the rewrite may not ----
# The regression this file guards: a checker the patch cannot rewrite *with
# certainty* must still come out of the patch with the md5 no-op applied, its own
# parsing untouched, a clean read-back verification, and exit status 0.  Anything
# else and a foreign vendor release fails to provision at all.
best_effort() { # <label> <checker> <warning-substring-or-empty>
    local label="$1" src="$2" want="${3:-}" disk="$TMP/$1.disk" work="$TMP/$1.work" hash
    run_patch_logged "$label" "$src"
    read_back "$TMP/$label.disk" "$TARGET" "$TMP/$label.patched" \
        || fail "$label: $TARGET is unreadable after patching"
    grep -qF "$MARKER" "$TMP/$label.patched" \
        || fail "$label: the md5 no-op marker is missing from the patched script"
    if grep -qF "$MD5_PATTERN" "$TMP/$label.patched"; then
        fail "$label: the md5 check survived the patch"
    fi
    sh -n "$TMP/$label.patched" || fail "$label: the patched script does not parse"
    only_md5_changed "$src" "$TMP/$label.patched" "$label"
    if [ -n "$want" ]; then
        [ "$(grep -cF "$want" "$TMP/$label.patch1.log")" = 1 ] \
            || fail "$label: expected exactly one warning matching '$want' (got $(grep -cF "$want" "$TMP/$label.patch1.log")):
$(cat "$TMP/$label.patch1.log")"
        pass "$label: warned exactly once that the parsing rewrite was skipped"
    fi

    # The rewritten half must behave: clone mode copies the same tree as the
    # unpatched script, and check mode still succeeds with no $4 under set -u.
    expect_clone "$src" "$TMP/$label.patched" "$label"

    # A second run recognises the root as already patched and writes nothing.
    hash="$(sha256sum "$TMP/$label.disk" | awk '{print $1}')"
    run_patch "$TMP/$label.disk" "$TMP/$label.work" "$TMP/$label.patch2.log" \
        || fail "$label: the second run failed:
$(cat "$TMP/$label.patch2.log")"
    grep -q 'already patched (nothing to do)' "$TMP/$label.patch2.log" \
        || fail "$label: the second run did not recognise the patched root:
$(cat "$TMP/$label.patch2.log")"
    [ "$hash" = "$(sha256sum "$TMP/$label.disk" | awk '{print $1}')" ] \
        || fail "$label: a second run rewrote the disk"
    pass "$label: a second run is a no-op and leaves the disk byte-identical"
}

run_patch_logged() { # <label> <checker>
    local label="$1" src="$2" disk="$TMP/$1.disk"
    build_disk "$src" "$disk"
    before="$(sha256sum "$disk" | awk '{print $1}')"
    if run_patch "$disk" "$TMP/$1.work" "$TMP/$1.patch1.log"; then
        return 0
    fi
    fail "$label: the patch exited non-zero, which would abort provisioning:
$(cat "$TMP/$1.patch1.log")"
}

echo
echo "=== checkers the parsing rewrite cannot be applied to with certainty ==="

# A "foreign release": a loop worded differently from the 10.5.1.0.282 vendor
# script -- the read header and the two line-splitting lines use their own
# spacing, quoting and flags, while the two FILE-branch lines happen to match
# ours.  Only two of the five fragments match, so the rewrite is not certain and
# must be skipped; the md5 line itself is still the vendor's and must be no-op'd.
# Before the fix this was one of the abort conditions ("builtin parsing with the
# vendor md5 line"), and a non-zero exit from a patch aborts provisioning of the
# whole appliance.
sed \
    -e "s/^    while read line; do\$/    while IFS= read -r line; do/" \
    -e 's/^        type=`echo $line|cut -d: -f1`;$/        type=`echo "$line" | cut -d: -f1`;/' \
    -e 's/^        data=`echo $line|cut -d: -f2`;$/        data=`echo "$line" | cut -d: -f2`;/' \
    "$TMP/chk.fixture.sh" > "$TMP/chk.foreign.sh"
grep -qF 'while IFS= read -r line; do' "$TMP/chk.foreign.sh" \
    || fail "could not build the foreign-release fixture"
grep -qF 'while read line; do' "$TMP/chk.foreign.sh" \
    && fail "the foreign-release fixture still carries the vendor loop header"
for frag in 'type=`echo $line|cut' 'data=`echo $line|cut'; do
    grep -qF "$frag" "$TMP/chk.foreign.sh" \
        && fail "the foreign-release fixture still matches the fragment '$frag'"
done
best_effort foreign "$TMP/chk.foreign.sh" "only 2 of the vendor loop's 5 parsing lines"
pass "an unrecognised vendor release gets the md5 no-op and exits 0 (parsing untouched)"

# A partial set: four of the five vendor lines are there, but the loop header is
# worded differently -- a script that is *almost* the one this rewrite was
# written for.  Rewriting the four and leaving the header would be a half
# rewrite, so the patch must skip the rewrite entirely rather than abort.  The
# script stays syntactically valid, which the loop-intact variant guarantees.
sed 's/^    while read line; do$/    while IFS= read -r line; do/' \
    "$TMP/chk.fixture.sh" > "$TMP/chk.partial.sh"
best_effort partial "$TMP/chk.partial.sh" "only 4 of the vendor loop's 5 parsing lines"

# A script that already carries the builtins but still hashes: the rewrite is
# already there, so it must be skipped, and the md5 line must still be no-op'd.
# Derived from what the patch itself produced for the recognised fixture above --
# with the marker line removed -- so this fixture is a real patched script and
# carries the $3/$4 capture and restore, which a hand-written stand-in would
# more than likely get wrong.
awk -v m="$MARKER" -v back="$MD5_LINE" '
    index($0, m) { print back; next } { print }
' "$TMP/fixture.patched" > "$TMP/chk.builtins.sh"
[ "$(grep -cF "$MD5_PATTERN" "$TMP/chk.builtins.sh")" = 1 ] \
    || fail "could not put the vendor md5 line back into the builtins fixture"
grep -qF 'while IFS=: read -r type data; do' "$TMP/chk.builtins.sh" \
    || fail "could not build the builtins-already-present fixture"
grep -qF '_have4' "$TMP/chk.builtins.sh" \
    || fail "the builtins-already-present fixture lost the argument capture"
if grep -qF "$MARKER" "$TMP/chk.builtins.sh"; then
    fail "the builtins-already-present fixture still carries our marker"
fi
if grep -qE 'echo \$line\|cut|echo \$data\|cut' "$TMP/chk.builtins.sh"; then
    fail "the builtins-already-present fixture still carries echo|cut parsing"
fi
best_effort builtins "$TMP/chk.builtins.sh" "already carries the builtin parsing"
pass "a root already carrying the builtins still gets the md5 no-op and exits 0"

# --- the md5-only root must still upgrade ------------------------------------
# What an earlier patch set leaves behind: the md5 line is already our no-op with
# the marker, and the parsing is still the vendor's.  This root must get the
# parsing rewrite -- not be mistaken for "already patched" -- and the md5 line
# must not be touched a second time.  The repaired-clone case is why: it has no
# rollback store, so there is no pristine checker to restore, and the burn the
# rewrite exists to remove would otherwise stay.
# REPLACEMENT is defined in the patch in terms of $MARKER, so expand that here:
# the literal `$MARKER` text is not what the patch writes to the script.
NOOP="$(sed -n "s/^REPLACEMENT=\"\(.*\)\"$/\1/p" "$PATCH")"
NOOP="${NOOP//'$MARKER'/$MARKER}"
[ -n "$NOOP" ] || fail "could not read REPLACEMENT out of $PATCH"
sed "s|^.*/usr/bin/md5sum -c.*\$|$NOOP|" "$TMP/chk.fixture.sh" > "$TMP/chk.md5only.sh"
grep -qF "$NOOP" "$TMP/chk.md5only.sh" || fail "could not build the md5-only fixture"
if grep -qF "$MD5_PATTERN" "$TMP/chk.md5only.sh"; then
    fail "the md5-only fixture still carries the md5 check"
fi
exercise md5only "$TMP/chk.md5only.sh"
awk -v m="$MARKER" -v n="$NOOP" -v p="$MD5_PATTERN" '
    (index($0, m) || index($0, p)) && $0 != n { bad++ }
    END { exit (bad ? 1 : 0) }
' "$TMP/md5only.patched" \
    || fail "the md5-only root's no-op line was rewritten a second time"
grep -qF "$NOOP" "$TMP/md5only.patched" \
    || fail "the md5-only root lost the md5 no-op its earlier patch set wrote"
pass "an md5-only root is upgraded: parsing rewritten, its existing md5 no-op left alone"

# only_md5_changed is the assertion the three best-effort cases above rest on, so
# check it in both directions: it must accept a script whose md5 line was
# substituted, and reject one whose parsing was disturbed as well.
awk -v n="$NOOP" '{ print (index($0, "/usr/bin/md5sum -c") ? n : $0) }' \
    "$TMP/chk.fixture.sh" > "$TMP/mk.patched"
sed 's/^    while read line; do$/    while IFS=: read -r type data; do/' \
    "$TMP/mk.patched" > "$TMP/mk.tampered"
only_md5_changed "$TMP/chk.fixture.sh" "$TMP/mk.patched" "selfcheck"
if ( only_md5_changed "$TMP/chk.fixture.sh" "$TMP/mk.tampered" "selfcheck-neg" ) 2>/dev/null; then
    fail "only_md5_changed accepted a script whose parsing was disturbed"
fi
pass "only_md5_changed rejects a script whose parsing was disturbed"

# --- the two md5 states that are still refused --------------------------------
refuse() { # <label> <checker> <expected message>
    local label="$1" src="$2" want="$3" disk="$TMP/$1.disk" before
    build_disk "$src" "$disk"
    before="$(sha256sum "$disk" | awk '{print $1}')"
    if run_patch "$disk" "$TMP/$1.work" "$TMP/$1.log"; then
        fail "$label: an unsafe checker was accepted"
    fi
    grep -q "$want" "$TMP/$1.log" \
        || fail "$label: the refusal did not explain itself:
$(cat "$TMP/$1.log")"
    [ "$before" = "$(sha256sum "$disk" | awk '{print $1}')" ] \
        || fail "$label: a refused patch wrote to the disk"
    pass "$label: refused, and the disk was left alone"
}

sed '/usr.bin.md5sum -c/d' "$TMP/chk.fixture.sh" > "$TMP/chk.nomd5.sh"
refuse nomarker "$TMP/chk.nomd5.sh" "no md5 check and not our marker"

# More than one md5 line: rewriting one would leave the other hashing, so this is
# the one md5 state that has always been refused and still is.
sed '/usr.bin.md5sum -c/a\            echo "$md5  $file"|/usr/bin/md5sum -c >/dev/null 2>\&1' \
    "$TMP/chk.fixture.sh" > "$TMP/chk.twomd5.sh"
[ "$(grep -cF "$MD5_PATTERN" "$TMP/chk.twomd5.sh")" = 2 ] \
    || fail "could not build the two-md5-line fixture"
refuse twomd5 "$TMP/chk.twomd5.sh" "occurrences of"

# --- the real vendor script, when one is supplied ----------------------------
if [ -n "${AS_CHKINT:-}" ]; then
    [ -f "$AS_CHKINT" ] || fail "AS_CHKINT=$AS_CHKINT does not exist"
    echo
    echo "=== the real $AS_CHKINT (AS_CHKINT) ==="
    exercise real "$AS_CHKINT"
    pass "the real vendor checker is rewritten with clone parity"
else
    partial "AS_CHKINT is not set, so a real vendor chk_integrity.sh was not exercised; the synthetic fixture above was"
fi

echo
echo "all skip-integrity tests passed"
