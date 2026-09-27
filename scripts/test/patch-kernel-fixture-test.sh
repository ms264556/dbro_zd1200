#!/usr/bin/env bash
#
# patch-kernel-fixture-test.sh — a kernel whose addrconf_dev_config() the
# compiler *inlined* (the group-B shape) must still get the dhcp0 crash fix, the
# patch must write its replacement at the address the enclosing flow actually
# reaches, and the enclosing function's own code must survive.
#
# Why this exists: five of the nine supported ZD1200 releases (10.2.1.0.236,
# 10.1.2.0.318, 9.13.3.0.164, 9.10.2.0.130, 9.9.1.0.52) carry
# addrconf_dev_config() inlined into addrconf_notify(), with the ASSERT_RTNL
# block 0x14 bytes after the bytes the original single signature matched.  Two
# generations of wrong patch live in this history: one that matched none of them
# (they installed with NO crash fix at all), and one that wrote its 20 bytes at
# the *match start* — which nothing branches to, so its first instruction was
# unreachable, the ASSERT block and the dhcp0 dispatch stayed stock, and it
# overwrote the enclosing function's live fall-through code on the way.  The
# fixture synthesizes that geometry (a `jne` whose rel32 the match starts
# inside, live code at match+0x04, a real `je <anchor>` in the enclosing block,
# the ASSERT-failure WARN block entered only by the stock `je`, and the epilogue
# at match-0x702), so a write at the match start cannot pass.
#
# It also pins the exact 20 bytes written at the anchor and where they live, and
# runs scripts/test/check-patched-kernel-site.py to read them back out of the
# artifact rather than believing the patcher's log.
#
# Deterministic and offline: the fixture is synthesised by
# make-kernel-patch-fixture.py, and the two fixture files' sha256 are printed so
# that a signature or generator drift is visible rather than silently skipped.
#
# Usage: ./scripts/test/patch-kernel-fixture-test.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATCHER="$REPO/scripts/container/patch-kernel.py"
GEN="$REPO/scripts/test/make-kernel-patch-fixture.py"
CHECK="$REPO/scripts/test/check-patched-kernel-site.py"
# 35e4dfe is the revision whose only addrconf signature is the standalone one:
# the inlined shape gets no fix at all there.
PRE_CHANGE_REV="35e4dfe"
# 79eb4b8 is the last revision whose inlined entry wrote at the match start
# instead of at the anchor: it "fixes" the fixture while writing into code the
# flow never reaches.  The check at the end requires THAT patcher to fail.
BROKEN_REV="79eb4b8"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-patchfixture.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass() { printf 'ok   %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ -f "$PATCHER" ] || fail "missing $PATCHER"
[ -f "$GEN" ] || fail "missing $GEN"
[ -f "$CHECK" ] || fail "missing $CHECK"

FIX="$TMP/fixture"
OUT="$TMP/out.bzImage"
OUT2="$TMP/out2.bzImage"
SELF="$TMP/selftest.log"

python3 "$GEN" "$FIX" >/dev/null
[ -s "$FIX/fixture.vmlinux" ] || fail "the generator produced no vmlinux"
[ -s "$FIX/fixture.bzImage" ] || fail "the generator produced no bzImage"

# The fixture's own shape must be reproducible, or every assertion below is
# about a file that has quietly changed.  These digests also record that the
# group-A block is absent and the inlined geometry is the one the real kernels
# have, so a generator change that moves the anchor shows up here first.
FIX_ELF_SHA="$(sha256sum "$FIX/fixture.vmlinux" | cut -d' ' -f1)"
FIX_BZ_SHA="$(sha256sum "$FIX/fixture.bzImage" | cut -d' ' -f1)"
echo "fixture vmlinux sha256 $FIX_ELF_SHA"
echo "fixture bzImage sha256 $FIX_BZ_SHA"

# The geometry the test asserts against, as file offsets in the fixture ELF.
ANCHOR_OFF="$(python3 "$GEN" --anchor-offset)"
BRANCH_OFF="$(python3 "$GEN" --enclosing-branch-offset)"
WARN_OFF="$(python3 "$GEN" --warn-block-offset)"
EPI_OFF="$(python3 "$GEN" --epilogue-offset)"
echo "fixture anchor=$ANCHOR_OFF entered_by=$BRANCH_OFF warn=$WARN_OFF epilogue=$EPI_OFF"

# --- 1. the patcher accepts the fixture -------------------------------------
rc=0
python3 "$PATCHER" --in "$FIX/fixture.bzImage" --out "$OUT" >"$TMP/patch.log" 2>&1 || rc=$?
[ "$rc" = 0 ] || { cat "$TMP/patch.log" >&2
    fail "the patcher refused the group-B fixture (rc=$rc)"; }
pass "the patcher accepts an inlined-only kernel (rc=0)"

# --- 2. and says the addrconf fix applied -----------------------------------
# The applied line names the inlined variant and prints a preimage -> postimage
# write; a skipped patch prints NOT FOUND instead and would land in the note.
grep -qE '^  addrconf_dev_config_dhcp0_inlined *: .*->.* at ' "$TMP/patch.log" \
    || { cat "$TMP/patch.log" >&2
         fail "the addrconf fix was not reported as applied"; }
pass "the addrconf fix is reported applied (inlined variant)"

# The honest-wording rule: a release that carries the fix must not be described
# as lacking the function, and must not be listed as a skipped patch.
if grep -q 'addrconf' "$TMP/patch.log" \
        && grep -qE 'note: patches not applicable.*addrconf' "$TMP/patch.log"; then
    cat "$TMP/patch.log" >&2
    fail "the patched release is reported as having skipped the addrconf fix"
fi
grep -q 'release lacks this function' "$TMP/patch.log" \
    && { cat "$TMP/patch.log" >&2; fail "the release is claimed to lack the fix"; }
pass "a release that got the fix is not reported as skipped or as lacking it"

# --- 3. the install really changed the kernel -------------------------------
[ -s "$OUT" ] || fail "no output bzImage was written"
OUT_SHA="$(sha256sum "$OUT" | cut -d' ' -f1)"
[ "$OUT_SHA" != "$FIX_BZ_SHA" ] \
    || fail "the patched bzImage is byte-identical to the fixture (nothing patched)"
pass "the output bzImage differs from the input (the fix landed)"

# --- 3b. the replacement, read back at the address control reaches -----------
# 20 bytes at the anchor: the device-pointer load, the dhcp0 name test, the
# `jne` to the stock movzx, the pad, and the backward jump to the epilogue.  An
# entry that writes at the match start instead -- unreachable, and over the
# enclosing function's live code -- fails every one of these.
EXPECT_SITE="8b4c240c8139646863707508909090e9dbf8ffff"
rc=0
SITE_OUT="$(python3 "$CHECK" --group-b "$PATCHER" "$OUT" "$FIX/fixture.vmlinux" \
    "$EXPECT_SITE" "$BRANCH_OFF")" || rc=$?
[ "$rc" = 0 ] || fail "the patched payload is not the inlined site the enclosing
flow reaches:
$SITE_OUT"
[ "$SITE_OUT" = "site=$EXPECT_SITE anchor=match+0x14 entered_by=$BRANCH_OFF \
jne=match+0x28 jmp=$EPI_OFF movzx=match+0x28 stock warn=$WARN_OFF(dead) \
live=match..match+0x14 stock" ] \
    || fail "unexpected site check: $SITE_OUT"
pass "the replacement runs at the anchor the enclosing branch enters"
pass "the jne reaches the stock movzx at match+0x28; dhcp0 falls through to the jump"
pass "its jump lands on the fixture's epilogue \`mov eax,edx\` ($EPI_OFF)"
pass "the movzx, the ARPHRD dispatch and the enclosing function's live code are stock"

# The patcher's own log must name that same address: the write really landed at
# the anchor, not merely somewhere in the payload.
grep -q -- "-> $EXPECT_SITE at 0x[0-9a-f]* (offset $ANCHOR_OFF)" "$TMP/patch.log" \
    || { cat "$TMP/patch.log" >&2
         fail "the patcher did not report the write at the anchor ($ANCHOR_OFF)"; }
pass "the patcher reports the write at the anchor (offset $ANCHOR_OFF)"

# --- 4. the offline self-test agrees ----------------------------------------
rc=0
python3 "$PATCHER" --self-test --vmlinux "$FIX/fixture.vmlinux" >"$SELF" 2>&1 || rc=$?
[ "$rc" = 0 ] || { cat "$SELF" >&2; fail "--self-test rejected the fixture (rc=$rc)"; }
grep -qE '^  ok +addrconf_dev_config_dhcp0_inlined +unique at ' "$SELF" \
    || { cat "$SELF" >&2; fail "--self-test did not report the inlined site as unique"; }
grep -qE '^  ok +addrconf_dev_config_dhcp0_inlined +absent' "$SELF" \
    && { cat "$SELF" >&2; fail "--self-test reports the inlined variant as absent"; }
pass "--self-test locates the inlined site uniquely (not 'absent')"

# The sibling shape must be reported as not-this-release's-shape, not as a
# skipped optional patch: a group-A kernel must not look partly unpatched, and
# the converse has to hold too.
grep -qE '^  ok +addrconf_dev_config_dhcp0 +not this release.s shape' "$SELF" \
    || { cat "$SELF" >&2; fail "the sibling variant is not reported as covered"; }
pass "the sibling variant is reported as this release's other shape"

# --- 5. re-running the patcher is a no-op -----------------------------------
rc=0
python3 "$PATCHER" --in "$OUT" --out "$OUT2" >"$TMP/patch2.log" 2>&1 || rc=$?
[ "$rc" = 0 ] || { cat "$TMP/patch2.log" >&2
    fail "re-running the patcher on its own output failed (rc=$rc)"; }
cmp -s "$OUT" "$OUT2" || fail "re-patching its own output changed the file"
pass "re-running the patcher on its own output is byte-identical"

# --- 6. the old patcher must NOT fix this kernel ----------------------------
# This is the assertion that makes the test a regression test rather than a
# description: 35e4dfe is the revision whose only addrconf signature is the
# standalone one.  Staged into $TMP -- the worktree is never touched.
if git -C "$REPO" cat-file -e "$PRE_CHANGE_REV:scripts/container/patch-kernel.py" 2>/dev/null; then
    OLD="$TMP/patch-kernel-old.py"
    git -C "$REPO" show "$PRE_CHANGE_REV:scripts/container/patch-kernel.py" > "$OLD"
    rc=0
    python3 "$OLD" --in "$FIX/fixture.bzImage" --out "$TMP/old.bzImage" \
        >"$TMP/old.log" 2>&1 || rc=$?
    grep -qE 'addrconf_dev_config_dhcp0 *: NOT FOUND' "$TMP/old.log" \
        || { cat "$TMP/old.log" >&2
             fail "the pre-change patcher did not report the addrconf patch as
  missing on the inlined-only kernel (rc=$rc); the fixture is not discriminating"; }
    grep -qE 'note: patches not applicable.*addrconf_dev_config_dhcp0' "$TMP/old.log" \
        || { cat "$TMP/old.log" >&2
             fail "the pre-change patcher did not skip-and-report the fix"; }
    [ "$rc" = 0 ] || fail "the pre-change patcher aborted instead of skipping (rc=$rc)"
    pass "the pre-change patcher ($PRE_CHANGE_REV) reports the fix as skipped (the regression)"
else
    echo "skipped: $PRE_CHANGE_REV:scripts/container/patch-kernel.py is not in this"
    echo "         clone (shallow or rewritten history); the discriminating run"
    echo "         needs that blob"
fi

# --- 6b. the wrong-geometry patcher must NOT pass this test -----------------
# 79eb4b8's inlined entry wrote at the match start.  It exits 0 and its log says
# the patch applied, so only a check stated in terms of the branch and the anchor
# can see that its bytes are not the code the flow reaches.  That is the defect
# this fixture shape exists to catch, so the check is required to reject it.
if git -C "$REPO" cat-file -e "$BROKEN_REV:scripts/container/patch-kernel.py" 2>/dev/null; then
    BROKEN="$TMP/patch-kernel-broken.py"
    git -C "$REPO" show "$BROKEN_REV:scripts/container/patch-kernel.py" > "$BROKEN"
    rc=0
    python3 "$BROKEN" --in "$FIX/fixture.bzImage" --out "$TMP/broken.bzImage" \
        >"$TMP/broken.log" 2>&1 || rc=$?
    [ "$rc" = 0 ] || { cat "$TMP/broken.log" >&2
        fail "the wrong-geometry patcher ($BROKEN_REV) refused the fixture (rc=$rc);
  it is supposed to accept it and write into the wrong place"; }
    rc=0
    BROKEN_OUT="$(python3 "$CHECK" --group-b "$BROKEN" "$TMP/broken.bzImage" \
        "$FIX/fixture.vmlinux" "$EXPECT_SITE" "$BRANCH_OFF" 2>&1)" || rc=$?
    [ "$rc" != 0 ] || fail "the wrong-geometry patcher ($BROKEN_REV) PASSED the site
  check ($BROKEN_OUT); the fixture is not discriminating"
    echo "     $BROKEN_REV rejected as expected: $BROKEN_OUT"
    pass "the wrong-geometry patcher ($BROKEN_REV) FAILS the reachability check"
else
    echo "skipped: $BROKEN_REV:scripts/container/patch-kernel.py is not in this"
    echo "         clone; the reachability check cannot be shown discriminating"
    echo "         against the entry that motivated it"
fi

# --- 7. the standalone (group-A) shape --------------------------------------
# The other half of the same fix, and the half with a defect of its own: the
# four group-A releases carry addrconf_dev_config() as a real function whose
# `movzx eax,[ebx+0xdc]` (the device type the ARPHRD switch dispatches on) sits
# inside the bytes the patch used to overwrite.  A 20-byte replacement nops over
# it, and the switch then runs on whatever the ASSERT_RTNL helper left in eax --
# a silent IPv6 configuration change for non-Ethernet devices that no boot test
# can see.  This asserts the 13-byte shape that preserves it.
FIXA="$TMP/fixture-a"
OUTA="$TMP/out-a.bzImage"
python3 "$GEN" "$FIXA" group_a >/dev/null
[ -s "$FIXA/fixture.bzImage" ] || fail "the generator produced no group-A fixture"

rc=0
python3 "$PATCHER" --in "$FIXA/fixture.bzImage" --out "$OUTA" >"$TMP/patcha.log" 2>&1 || rc=$?
[ "$rc" = 0 ] || { cat "$TMP/patcha.log" >&2
    fail "the patcher refused the group-A fixture (rc=$rc)"; }
pass "the patcher accepts a standalone-function kernel (rc=0)"

grep -qE '^  addrconf_dev_config_dhcp0 *: .*->.* at ' "$TMP/patcha.log" \
    || { cat "$TMP/patcha.log" >&2; fail "the group-A fix was not applied"; }

EXPECT_SITE_A="813b646863707505e926000000"
rc=0
SITE_A_OUT="$(python3 "$CHECK" --group-a \
    "$PATCHER" "$OUTA" "$FIXA/fixture.vmlinux" "$EXPECT_SITE_A")" || rc=$?
[ "$rc" = 0 ] || fail "the group-A site check failed:
$SITE_A_OUT"
[ "$SITE_A_OUT" = "site=$EXPECT_SITE_A jne=+0xd jmp=+0x33 movzx=+0xd" ] \
    || fail "unexpected group-A site check: $SITE_A_OUT"
pass "the group-A site is 13 bytes and leaves the device-type load intact"
pass "non-dhcp0 reaches the real movzx at +0x0d; dhcp0 falls through to +0x33"

rc=0
python3 "$PATCHER" --in "$OUTA" --out "$TMP/out-a2.bzImage" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] && cmp -s "$OUTA" "$TMP/out-a2.bzImage" \
    || fail "re-running the patcher on the group-A output failed (rc=$rc)"
pass "re-running the patcher on the group-A output is byte-identical"

echo
echo "all patch-kernel fixture tests passed"
