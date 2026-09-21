#!/usr/bin/env bash
#
# rbd-mac-guard-test.sh — the guest's board-data tool must not be able to move
# the MAC the container owns.
#
# 35-rbd-mac-guard.sh rewrites /bin/rbd.sh so an invocation that supplies an
# OUI/MAC1/MAC2 is refused *before* `rbd change` runs (a guard placed after the
# heredoc would let the write happen and then report a failure), while a
# serial/model/customer-only update still works.
#
# This lifts build_guarded_script() out of the patch and drives it with a stand-in
# vendor rbd.sh, then runs the guarded result.  No disk or rootfs is involved.
#
# Usage: ./scripts/test/rbd-mac-guard-test.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../container" && pwd)"
PATCH="$BASE/patches/35-rbd-mac-guard.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-rbdguard.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

[ -f "$PATCH" ] || fail "not found: $PATCH"
grep -q '^build_guarded_script() {' "$PATCH" || fail "build_guarded_script() not found in $PATCH"

WORK="$TMP/work"; mkdir -p "$WORK"
TARGET="/bin/rbd.sh"

# A stand-in for the vendor script: the guard keys on the exact heredoc line.
VENDOR="$TMP/rbd.sh.vendor"
cat > "$VENDOR" <<'STUB'
#!/bin/sh
if [ $# -lt 6 ] ; then
  echo "usage"
  exit 0
fi
OUI=`echo $4|sed "y/abcdef/ABCDEF/"`
MAC1=`echo $5|sed "y/abcdef/ABCDEF/"`
MAC2=`echo $6|sed "y/abcdef/ABCDEF/"`
rbd change > /dev/null <<EOF
board
serial
EOF
echo "vendor rbd.sh completed"
STUB

# Lift the function out; it carries its own comment-free body.
sed -n '/^build_guarded_script() {/,/^}/p' "$PATCH" > "$TMP/fn.sh"
# shellcheck source=/dev/null
. "$TMP/fn.sh"

# The function's only I/O is fs_read (pull the vendor script off a root) and
# fs_stat_meta (its mode); both are stubbed around the stand-in.  Once a run has
# produced the guarded script, fs_read returns that, modelling a root that
# already carries the guard.
fs_read() { if [ -s "$WORK/rbd.sh.patched" ]; then cp "$WORK/rbd.sh.patched" "$3"; else cp "$VENDOR" "$3"; fi; }
fs_stat_meta() { echo "0 0100755"; }

build_guarded_script rootA || fail "build_guarded_script refused to patch the stand-in"
[ -s "$WORK/rbd.sh.patched" ] || fail "no patched script produced"
grep -q 'ZD-MAC-GUARD' "$WORK/rbd.sh.patched" || fail "patched script carries no guard"
[ "$(cat "$WORK/rbd.mode")" = "0100755" ] || fail "vendor mode not preserved: $(cat "$WORK/rbd.mode")"
pass "the vendor script is guarded with its mode preserved"

# The guard must sit before `rbd change`, not after.
guard_line="$(grep -n 'ZD-MAC-GUARD' "$WORK/rbd.sh.patched" | head -1 | cut -d: -f1)"
change_line="$(grep -n '^rbd change > /dev/null <<' "$WORK/rbd.sh.patched" | head -1 | cut -d: -f1)"
[ -n "$guard_line" ] && [ -n "$change_line" ] || fail "guard or rbd invocation missing"
[ "$guard_line" -lt "$change_line" ] || fail "the guard is after 'rbd change' (the write would already have happened)"
pass "the guard precedes the 'rbd change' invocation"

# Stand in for the vendor binary so a run is observable.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/rbd" <<EOF
#!/bin/sh
echo invoked > "$TMP/rbd-was-called"
exit 0
EOF
chmod 755 "$TMP/bin/rbd"

# --- a MAC change is refused, and rbd is never called ------------------------
rm -f "$TMP/rbd-was-called"
if PATH="$TMP/bin:$PATH" sh "$WORK/rbd.sh.patched" shiba ZD1200 12345678 00:13:92 01:01:01 01:01:02 >"$TMP/out" 2>&1; then
    fail "a MAC change was accepted"
fi
grep -qi 'refusing to change the MAC' "$TMP/out" || fail "no refusal message: $(cat "$TMP/out")"
[ ! -e "$TMP/rbd-was-called" ] || fail "rbd ran despite the refusal (write already happened)"
pass "a MAC change is refused before rbd runs"

# --- a serial/model-only update still works ----------------------------------
rm -f "$TMP/rbd-was-called"
PATH="$TMP/bin:$PATH" sh "$WORK/rbd.sh.patched" "" "" 123456000789 "" "" "" >"$TMP/out2" 2>&1 \
    || fail "a serial-only update was refused: $(cat "$TMP/out2")"
[ -e "$TMP/rbd-was-called" ] || fail "rbd did not run for a serial-only update"
pass "a serial/model/customer-only update still reaches rbd"

# --- an already-guarded script is left alone ---------------------------------
if build_guarded_script rootA; then
    fail "an already-guarded script was patched again"
fi
pass "an already-guarded script is detected and skipped"

# --- a script without the expected invocation is refused ---------------------
rm -f "$WORK/rbd.sh.patched"
printf '#!/bin/sh\necho nothing to guard\n' > "$VENDOR"
if build_guarded_script rootA; then
    fail "a script with no 'rbd change' heredoc was patched"
fi
pass "an unexpected script is refused rather than mis-patched"

echo
echo "all rbd MAC-guard tests passed"
