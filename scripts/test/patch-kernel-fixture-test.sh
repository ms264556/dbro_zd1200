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
# The 4th entry, `tsc_read_refs_threshold`, rewrites one imm32: the fixture carries
# the stock compare at the real kernel's file offset 0x9ECA, and the test reads the
# patched artifact back to see that only those four bytes changed and now hold the
# new limit, with the expected value pinned in the checker, not taken from the patcher.
#
# Deterministic and offline: the fixture is synthesised by
# make-kernel-patch-fixture.py, and the two fixture files' sha256 are printed so
# that a signature or generator drift is visible rather than silently skipped.
#
# Usage: ./scripts/test/patch-kernel-fixture-test.sh
set -euo pipefail
# The dhcp0 kernel patches are opt-in (see OPT_IN_PATCHES in patch-kernel.py); this
# test covers them, so its patcher runs have them on.
export ZD_KERNEL_OPT_IN=addrconf_dev_config_dhcp0,addrconf_dev_config_dhcp0_inlined

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATCHER="$REPO/scripts/container/patch-kernel.py"
GEN="$REPO/scripts/test/make-kernel-patch-fixture.py"
CHECK="$REPO/scripts/test/check-patched-kernel-site.py"
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

# By default the table holds neither dhcp0 shape nor rks_pkt_trace_init: the dhcp0
# patches are opt-in because they make every 9.x restored configuration restart its
# controller about every two minutes (see OPT_IN_PATCHES in patch-kernel.py).  This
# test's own runs enable them (ZD_KERNEL_OPT_IN, exported near the top) so the
# patches stay covered; here the default, with the variable unset, is pinned.
env -u ZD_KERNEL_OPT_IN python3 - "$PATCHER" <<'PYEOF3' || fail "the default kernel patch table is not main's three patches plus the TSC one"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pk", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
names = [e[0] for e in mod.PATCHES]
want = ["kernel_halt", "cob7402_reset_watchdog", "wdt_timeout_marker", "tsc_read_refs_threshold"]
if names != want:
    print("table is %s, expected %s" % (names, want), file=sys.stderr)
    raise SystemExit(1)
PYEOF3
pass "by default the table holds only kernel_halt, the two watchdog patches and the TSC threshold patch"

# rks_pkt_trace_init() must NOT be patched.  Returning 0 from it stops the vendor
# tif0 interface being created, which avoids a rare cold-TCG-boot oops -- and makes
# apmgr stop answering once a configuration with WLANs and AP groups is restored,
# so the controller restarts about every two minutes on every release, under KVM
# too (found by bisecting a restored backup install; factory installs do not show
# it).  A patch for the oops has to keep tif0 and guard tif_xmit instead.
python3 - "$PATCHER" <<'PYEOF2' || fail "the kernel patch table contains an rks_pkt_trace_init entry again"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pk", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
raise SystemExit(1 if any(e[0] == "rks_pkt_trace_init" for e in mod.PATCHES) else 0)
PYEOF2
pass "the table has no rks_pkt_trace_init patch (it breaks restored configurations)"

# --- 6. the TSC threshold patch, read back out of the artifact ---------------
# Exactly the imm32 at +11 of the 16-byte compare changes, to 0xfffff, and nothing
# beside it.  Read from the output of step 4 and again from the re-run of step 5, so
# the no-op property is asserted for this patch specifically as well as for the file.
EXPECT_TSC="site=29f919eb83fb00771581f9ffff0f0077 limit=0xfffff"
rc=0
TSC_OUT="$(python3 "$CHECK" --tsc-threshold "$PATCHER" "$OUT" "$FIX/fixture.vmlinux")" || rc=$?
[ "$rc" = 0 ] || fail "the tsc_read_refs_threshold patch is not what was written:
$TSC_OUT"
[ "$TSC_OUT" = "$EXPECT_TSC" ] || fail "unexpected tsc threshold check: $TSC_OUT"
pass "the TSC patch rewrites only the 4-byte limit, to 0xfffff (was 0xc34f)"
rc=0
TSC_OUT2="$(python3 "$CHECK" --tsc-threshold "$PATCHER" "$OUT2" "$FIX/fixture.vmlinux")" || rc=$?
[ "$rc" = 0 ] && [ "$TSC_OUT2" = "$EXPECT_TSC" ] \
    || fail "the TSC patch did not survive a re-run of the patcher: $TSC_OUT2"
pass "the TSC patch survives a re-run of the patcher (no-op)"

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

# --- a drifted TSC site is refused, not patched ------------------------------
# The compare's other bytes are pinned by the signature, and the patch is required:
# a release whose compare is not the stock one (here the `ja`'s displacement, +8)
# must fail the install rather than boot a kernel whose idle cost nobody measured.
DRIFT="$TMP/drift-tsc.bzImage"
python3 - "$FIX/fixture.bzImage" "$DRIFT" "$PATCHER" <<'PY'
import sys, importlib.util
bz_in, bz_out, patcher = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("pk", patcher)
pk = importlib.util.module_from_spec(spec); spec.loader.exec_module(pk)
data = bytearray(open(bz_in, "rb").read())
start, end, payload = pk.find_elf_member(data)
elf = bytearray(payload)
site = next(s for s in pk.locate_sites(bytes(elf))[0]
            if s.name == "tsc_read_refs_threshold" and len(s.hits) == 1)
elf[site.hits[0] + 8] ^= 0xFF
member, _ = pk.encode_member(bytes(elf), end - start)
member += b"\x00" * ((end - start) - len(member))
open(bz_out, "wb").write(bytes(data[:start]) + member + bytes(data[end:]))
PY
rc=0
python3 "$PATCHER" --in "$DRIFT" --out "$TMP/drift-out.bzImage" \
    >"$TMP/drift.log" 2>&1 || rc=$?
[ "$rc" != 0 ] || { cat "$TMP/drift.log" >&2
    fail "the patcher accepted a kernel whose TSC compare is not the stock one"; }
grep -q 'tsc_read_refs_threshold' "$TMP/drift.log" \
    || { cat "$TMP/drift.log" >&2; fail "the refusal did not name the TSC patch"; }
[ ! -e "$TMP/drift-out.bzImage" ] || fail "an output was written for a drifted TSC site"
pass "a kernel whose TSC compare drifted is refused, with no output written"

# --- the inlined dhcp0 fixed-jump landing guard is live ---------------------
# The inlined dhcp0 patch jumps a *constant* -0x725 to the epilogue at
# match-0x6fd; nothing in the signature covers that landing, so the patcher
# re-checks it against the stock bytes the five inlined releases share
# (`mov edx,1; mov eax,edx; mov ebx,[esp+0xf0]` at match-0x702).  Move the
# epilogue and the fixed jump would land mid-instruction -- a silent kernel
# corruption -- so the patcher must refuse, from both the writer and the
# offline self-test, rather than write the jump.
CORRUPT_EPI="$TMP/corrupt-epilogue.bzImage"
CORRUPT_EPI_ELF="$TMP/corrupt-epilogue.vmlinux"
python3 - "$FIX/fixture.bzImage" "$CORRUPT_EPI" "$CORRUPT_EPI_ELF" "$PATCHER" <<'PY'
import sys, importlib.util
bz_in, bz_out, elf_out, patcher = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("pk", patcher)
pk = importlib.util.module_from_spec(spec); spec.loader.exec_module(pk)
data = bytearray(open(bz_in, "rb").read())
start, end, payload = pk.find_elf_member(data)
elf = bytearray(payload)
site = next(s for s in pk.locate_sites(bytes(elf))[0]
            if s.name == pk.DHCP0_INLINED and len(s.hits) == 1)
off = site.hits[0] + pk.DHCP0_INLINED_EPILOGUE_OFF
# Shift the epilogue's `mov edx,1` by a byte: the fixed jump would now land in
# the middle of what is no longer `mov eax,edx`.
elf[off] ^= 0xFF
open(elf_out, "wb").write(bytes(elf))
member, _ = pk.encode_member(bytes(elf), end - start)
member += b"\x00" * ((end - start) - len(member))
open(bz_out, "wb").write(bytes(data[:start]) + member + bytes(data[end:]))
PY
rc=0
python3 "$PATCHER" --in "$CORRUPT_EPI" --out "$TMP/corrupt-epi-out.bzImage" \
    >"$TMP/corrupt-epi.log" 2>&1 || rc=$?
[ "$rc" != 0 ] || { cat "$TMP/corrupt-epi.log" >&2
    fail "the patcher wrote the fixed jump though the epilogue had moved (the landing guard is dead)"; }
grep -q 'would not land on' "$TMP/corrupt-epi.log" \
    || { cat "$TMP/corrupt-epi.log" >&2; fail "the refusal was not the epilogue-landing check"; }
[ ! -e "$TMP/corrupt-epi-out.bzImage" ] || fail "an output was written for a refused landing"
rc=0
python3 "$PATCHER" --self-test --vmlinux "$CORRUPT_EPI_ELF" \
    >"$TMP/corrupt-epi-self.log" 2>&1 || rc=$?
[ "$rc" != 0 ] || { cat "$TMP/corrupt-epi-self.log" >&2
    fail "--self-test accepted a moved inlined epilogue"; }
grep -qE '^  FAIL +addrconf_dev_config_dhcp0_inlined .*would not land on' \
    "$TMP/corrupt-epi-self.log" \
    || { cat "$TMP/corrupt-epi-self.log" >&2; fail "--self-test did not flag the moved epilogue"; }
pass "a moved inlined epilogue is refused by both the writer and the self-test"

# --- the whole-patch re-run is a no-op ---------------------------------------
# The group-A re-run above covers only that shape; this one covers every entry of
# the full table.
rc=0
python3 "$PATCHER" --in "$OUT" --out "$TMP/out-2.bzImage" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] && cmp -s "$OUT" "$TMP/out-2.bzImage" \
    || fail "re-running the patcher on the full output is not a no-op (rc=$rc)"
pass "re-running the patcher on the full output is byte-identical"

echo
echo "all patch-kernel fixture tests passed"
