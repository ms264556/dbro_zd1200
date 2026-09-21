#!/usr/bin/env bash
#
# patch-parts-test.sh — a patch must touch only the roots the caller selected,
# and a malformed or empty selection must abort rather than be half-applied.
#
# prepare-vm-disks.sh decides per root whether it needs customising (each root
# carries its own /.patchrollback/sentinel) and passes exactly that selection in
# ZD_PATCH_PARTS.  Every patch used to hardcode both roots, so a run that had
# selected one root still wrote to the other -- wrong even when the bytes match,
# because that root was deliberately left alone.
#
# Usage: ./scripts/test/patch-parts-test.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../container" && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-parts.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

# patch-lib.sh reads these only inside its functions, but give it sane values.
WORK="$TMP/work"; mkdir -p "$WORK"
QCOW="$TMP/disk.raw"
ALIGN=512
# shellcheck source=../container/patch-lib.sh
. "$BASE/patch-lib.sh"

PAIR='hda2|84568|415152
hda3|499720|415152'
ONE='hda3|499720|415152'

# --- no selection: the full root pair ---------------------------------------
out="$(patch_parts)" || fail "patch_parts with no selection failed"
[ "$out" = "$PAIR" ] || fail "unexpected default selection:
$out"
pass "no selection -> the full root pair (a patch still runs standalone)"

# --- an explicit selection is returned as given -----------------------------
out="$(patch_parts "$ONE")" || fail "an explicit single-root selection failed"
[ "$out" = "$ONE" ] || fail "explicit selection not returned as given: $out"
pass "an explicit selection is returned as given"

# --- ZD_PATCH_PARTS is honoured ---------------------------------------------
out="$(ZD_PATCH_PARTS="$ONE" patch_parts)" || fail "ZD_PATCH_PARTS selection failed"
[ "$out" = "$ONE" ] || fail "ZD_PATCH_PARTS not honoured: $out"
pass "ZD_PATCH_PARTS is honoured (only the selected root is touched)"

# --- a malformed entry is refused, and named --------------------------------
if out="$(patch_parts 'garbage' 2>"$TMP/err1")"; then
    fail "a malformed selection was accepted: $out"
fi
grep -q "malformed partition entry 'garbage'" "$TMP/err1" \
    || fail "no diagnostic for the malformed entry: $(cat "$TMP/err1")"
pass "a malformed entry is refused with a diagnostic"

if patch_parts 'hda2|notanumber|12' >/dev/null 2>"$TMP/err2"; then
    fail "a bad start sector was accepted"
fi
grep -q 'malformed partition entry' "$TMP/err2" || fail "no diagnostic for a bad start sector"
pass "a non-numeric field is refused too"

# --- one bad entry refuses the whole selection ------------------------------
# The good line is still printed, so this holds only because the status is
# non-zero -- which is exactly what load_patch_parts must not discard.
if ( export ZD_PATCH_PARTS=$'hda3|499720|415152\nbroken'; load_patch_parts ) >/dev/null 2>&1; then
    fail "a partially valid selection was applied"
fi
pass "one bad entry refuses the whole selection (nothing is half-applied)"

# --- load_patch_parts fills PARTITIONS from the selection -------------------
( export ZD_PATCH_PARTS="$ONE"; load_patch_parts; printf '%s\n' "${PARTITIONS[@]}" ) \
    > "$TMP/parts1"
[ "$(cat "$TMP/parts1")" = "$ONE" ] || fail "PARTITIONS is not the selection: $(cat "$TMP/parts1")"
pass "load_patch_parts fills PARTITIONS from the selection"

( unset ZD_PATCH_PARTS; load_patch_parts; printf '%s\n' "${PARTITIONS[@]}" ) \
    > "$TMP/parts2"
[ "$(cat "$TMP/parts2")" = "$PAIR" ] || fail "PARTITIONS is not the default pair"
pass "load_patch_parts falls back to the full pair"

# --- load_patch_parts aborts on a malformed selection -----------------------
if ( export ZD_PATCH_PARTS='garbage'; load_patch_parts ) 2>"$TMP/err3"; then
    fail "load_patch_parts accepted a malformed selection"
fi
grep -q 'not a usable partition selection' "$TMP/err3" \
    || fail "no abort message: $(cat "$TMP/err3")"
pass "a malformed selection aborts the patch instead of being applied"

# --- load_patch_parts aborts on a blank selection ---------------------------
# patch_parts skips blank lines, so this passes its own validation; the guard
# that has to catch it is load_patch_parts'.
if ( export ZD_PATCH_PARTS=$'\n\n'; load_patch_parts ) 2>"$TMP/err4"; then
    fail "a blank selection was accepted (mapfile <<< \"\" yields one empty element)"
fi
grep -q 'empty partition selection' "$TMP/err4" \
    || fail "no abort message for the blank selection: $(cat "$TMP/err4")"
pass "a blank selection aborts rather than becoming a nameless partition"

# --- spot_img points at a root this run selected ----------------------------
( export ZD_PATCH_PARTS='hda3|499720|415152'; load_patch_parts; spot_img ) > "$TMP/spot1"
[ "$(cat "$TMP/spot1")" = "$WORK/hda3.verify.img" ] \
    || fail "spot_img did not follow the selection: $(cat "$TMP/spot1")"
pass "spot_img points at a selected root, not at a hardcoded hda2"

( unset ZD_PATCH_PARTS; load_patch_parts; spot_img ) > "$TMP/spot2"
[ "$(cat "$TMP/spot2")" = "$WORK/hda2.verify.img" ] \
    || fail "spot_img did not use the first selected root: $(cat "$TMP/spot2")"
pass "spot_img uses the first selected root"

if ( PARTITIONS=(); spot_img ) >/dev/null 2>&1; then
    fail "spot_img succeeded with no selection"
fi
pass "spot_img fails rather than naming a file that cannot exist"

echo
echo "all patch-parts tests passed"
