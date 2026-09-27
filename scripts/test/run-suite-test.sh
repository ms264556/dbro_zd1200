#!/usr/bin/env bash
#
# run-suite-test.sh — the offline self-test for run-suite.sh.
#
# Why this exists: run-suite.sh is the only thing that turns test exit codes into
# a `ran N of M` claim, so a wrong count would recreate the defect it is there to
# expose -- a green suite that hides tests which skipped their own subject
# (HANDOFF.md 7.4).  This test drives the real runner over synthetic fixture
# directories of stub tests and never touches the real suite.
#
# Three suites are run: `ZD_SUITE_DIR` points the runner at a fixture directory,
# and the pre-fix runner is driven over a third.
#
#   green fixture   a `*.sh` pass stub, a `*.sh` stub that prints `skipped:`, a
#                   silent `*.sh` stub, a `*-test.py` that passes, a `*-test.py`
#                   that prints `skipped:`, a `*-test.py` that prints `partial:`,
#                   and run-suite.sh and run-suite-test.sh stubs that must never
#                   execute.  Every stub drops a marker file through
#                   $ZD_STUB_MARKERS, so execution (not just counting) is proved
#   bad fixture     the green fixture plus a `*-test.py` stub that exits 1
#   pre-fix grid    one `*.sh` pass stub and one passing `*-test.py` stub, run by
#                   the runner as it was at abc0b3a (staged out of git with `git
#                   show`) and by the runner under test
#   no-room dir     a *copy* of wizard-http-test.py plus an unwritable
#                   `.boot-test`, run with $TMPDIR on a small filesystem: the
#                   environmental shortfall must print `skipped:` and exit 0, not
#                   fail with a `FAIL:` line
#   no-python PATH  a PATH carrying the runner's own tools but no python3: every
#                   `*-test.py` must be recorded not run, and the aggregate must
#                   stay 0 rather than counting the interpreter's exit 127
#   upper fixture   two stubs for the all-caps `SKIP:` pre-tool gate: one whose
#                   first line is `SKIP:` (counted NOT RUN) and one that prints a
#                   verdict first and its `SKIP:` after (must stay RAN)
#
# It asserts the counts, the skip/partial/failure naming, the self-exclusion, the
# *.py invocation, the exit contract, and the five discriminating facts: that the
# `*-test.py` tests are now RUN rather than named as a coverage gap (the pre-fix
# runner named them and ran none -- this test fails against it), that a
# `partial:` test is counted in the numerator but named under its own summary
# section, that an environmental shortfall in a *.py test skips rather than
# failing, that a missing interpreter skips rather than failing, and that an
# all-caps `SKIP:` is a not-run verdict only as the test's first line of output
# (the runner at 2043850 counted it RAN -- see the upper fixture below).
# Offline: no network, no lab, no real test.
#
# Usage: ./scripts/test/run-suite-test.sh
#

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$REPO/scripts/test/run-suite.sh"
# The pre-fix runner this test must fail against: the revision whose suite loop
# never ran a *-test.py (HANDOFF.md 8.8 item 6).
PRE_FIX_REV="abc0b3a"
# The runner as it was before the all-caps `SKIP:` first-line rule: it recognised
# only the lowercase markers, so a test whose pre-tool gate printed `SKIP:` and
# exited 0 counted as RAN (HANDOFF.md 9.2, 9.8 item 6).
UPPER_PRE_FIX_REV="2043850"

skip() { printf 'skipped: %s\n' "$*"; exit 0; }
pass() { printf 'ok   %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$RUNNER" ] || skip "scripts/test/run-suite.sh is not present"
command -v mktemp >/dev/null 2>&1 || skip "needs mktemp"
command -v python3 >/dev/null 2>&1 || fail "this test needs python3 (it drives the *-test.py tests)"
command -v git >/dev/null 2>&1 || fail "this test needs git (it stages the pre-fix runner)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-run-suite-test.XXXXXX")" \
    || skip "cannot create a scratch directory"
trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------------ fixtures
# The two run-suite* stubs exit 1 and drop a marker file: if the runner ever
# executes them, both the aggregate and the marker file say so.
#
# Every other stub drops a marker file too, through $ZD_STUB_MARKERS, so the test
# can assert which stubs the runner *executed* -- a stub the runner merely
# counted would not leave one.
make_fixture() {
    local dir="$1"
    cat > "$dir/a-pass-test.sh" <<'STUB'
#!/usr/bin/env bash
: > "$ZD_STUB_MARKERS/a-pass-test.sh"
echo "ok   the green fixture's pass stub ran"
STUB
    cat > "$dir/b-skip-test.sh" <<'STUB'
#!/usr/bin/env bash
: > "$ZD_STUB_MARKERS/b-skip-test.sh"
printf 'skipped: %s\n' "the skip stub has no lab"
STUB
    : > "$dir/c-quiet-test.sh"
    cat > "$dir/d2-py-pass-test.py" <<'STUB'
#!/usr/bin/env python3
"""A passing *-test.py: the runner must invoke it as python3."""
import os
open(os.path.join(os.environ["ZD_STUB_MARKERS"], "d2-py-pass-test.py"), "w").close()
print("ok   the green fixture's python stub ran")
STUB
    cat > "$dir/d3-py-skip-test.py" <<'STUB'
#!/usr/bin/env python3
"""A *-test.py that cannot evaluate its subject in this environment."""
import os
open(os.path.join(os.environ["ZD_STUB_MARKERS"], "d3-py-skip-test.py"), "w").close()
print("skipped: the python skip stub has no PVE host")
STUB
    cat > "$dir/d4-py-partial-test.py" <<'STUB'
#!/usr/bin/env python3
"""A *-test.py that exercises a synthetic fixture but not the vendor material."""
import os
open(os.path.join(os.environ["ZD_STUB_MARKERS"], "d4-py-partial-test.py"), "w").close()
print("ok   the python partial stub exercised its synthetic fixture")
print("partial: the real vendor material is not carried, so only the fixture ran")
STUB
    cat > "$dir/run-suite.sh" <<STUB
#!/usr/bin/env bash
: > "$TMP/self-ran"
exit 1
STUB
    cat > "$dir/run-suite-test.sh" <<STUB
#!/usr/bin/env bash
: > "$TMP/own-test-ran"
exit 1
STUB
}

green="$TMP/green"
bad="$TMP/bad"
markers="$TMP/markers"
mkdir -p "$green" "$bad" "$markers"
make_fixture "$green"
make_fixture "$bad"
cat > "$bad/e-fail-test.py" <<'STUB'
#!/usr/bin/env python3
import os
open(os.path.join(os.environ["ZD_STUB_MARKERS"], "e-fail-test.py"), "w").close()
print("FAIL: the python fail stub always fails", file=__import__("sys").stderr)
raise SystemExit(1)
STUB

# ------------------------------------------------------------ the green fixture
green_out="$(ZD_SUITE_DIR="$green" ZD_STUB_MARKERS="$markers" bash "$RUNNER" 2>&1)" || {
    printf '%s\n' "$green_out" >&2
    fail "the all-green fixture must aggregate to exit 0"
}
pass "the all-green fixture aggregates to exit 0"

# Six stubs run (the two run-suite* stubs are excluded), two of them skip: 4 of
# 6 evaluated their subject.  The partial stub is in the numerator (it ran, on
# its own fixture) and is named separately; only a `skipped:` test is not run.
grep -qx 'ran 4 of 6 tests' <<<"$green_out" || {
    printf '%s\n' "$green_out" >&2
    fail "expected 'ran 4 of 6 tests' (the two skips did not run; the partial did)"
}
pass "the pass, silent, partial and python stubs give 'ran 4 of 6 tests'"

# The brief's contract for the summary line: exactly this shape, nothing else.
grep -qE '^ran [0-9]+ of [0-9]+ tests$' <<<"$green_out" \
    || fail "the summary line does not match '^ran [0-9]* of [0-9]* tests\$'"
[ "$(grep -c '^ran ' <<<"$green_out")" = 1 ] \
    || fail "expected exactly one 'ran N of M tests' line"
pass "the summary carries exactly one 'ran N of M tests' line"

grep -qE '^===== .*a-pass-test\.sh$' <<<"$green_out" \
    || fail "the transcript does not carry the '===== <script>' separator"
grep -q '^ok   the green fixture.s pass stub ran$' <<<"$green_out" \
    || fail "the pass stub's own output was not streamed to stdout"
grep -q '^exit=0$' <<<"$green_out" \
    || fail "the transcript does not carry the bare 'exit=N' separator"
pass "the transcript keeps the '===== <script>' / 'exit=N' format"

# The summary must not look like a test: `^===== ` and `^exit=` must each still
# count exactly the tests that ran, so a transcript can be diffed and its
# membership counted by the recorded method.
[ "$(grep -c '^===== ' <<<"$green_out")" = 6 ] \
    || fail "expected exactly 6 '===== ' header lines, got $(grep -c '^===== ' <<<"$green_out")"
[ "$(grep -c '^exit=' <<<"$green_out")" = 6 ] \
    || fail "expected exactly 6 'exit=' lines, got $(grep -c '^exit=' <<<"$green_out")"
grep -q '^##### suite summary$' <<<"$green_out" \
    || fail "the summary banner is missing or is confusable with a test header"
pass "the summary adds no '===== '/exit= lines of its own (membership still countable)"

grep -qE '^not run  .*b-skip-test\.sh: skipped: the skip stub has no lab$' <<<"$green_out" \
    || {
        printf '%s\n' "$green_out" >&2
        fail "the skipped test must be named in the summary with its marker text"
    }
grep -qE '^not run  .*d3-py-skip-test\.py: skipped: the python skip stub has no PVE host$' <<<"$green_out" \
    || {
        printf '%s\n' "$green_out" >&2
        fail "a skipped *-test.py must be named in the summary with its marker text"
    }
pass "the skipped stubs are named in the summary with their marker text"

grep -qE '^not run  .*a-pass-test\.sh' <<<"$green_out" \
    && fail "the passing stub must not be listed as not run"
grep -qE '^not run  .*c-quiet-test\.sh' <<<"$green_out" \
    && fail "a silent test is not a skipped test and must not be listed as not run"
pass "neither the passer nor the silent test is listed as not run"

# --------------------------------------------------- the *.py tests now RUN
# Discriminating fact 1: the *.py stubs were invoked (their marker files exist)
# and their output is in the transcript.  This is what the pre-fix runner did not
# do -- see the pre-fix grid below.
for stub in d2-py-pass-test.py d3-py-skip-test.py d4-py-partial-test.py; do
    [ -e "$markers/$stub" ] \
        || fail "$stub was not executed by the runner (no marker file)"
    grep -qE "^===== .*$stub\$" <<<"$green_out" \
        || fail "$stub has no '===== ' header in the transcript"
done
grep -q '^ok   the green fixture.s python stub ran$' <<<"$green_out" \
    || fail "the *-test.py pass stub's own output was not streamed to stdout"
pass "the *-test.py stubs are run by the runner (python3) and their output is streamed"

# The obsolete coverage-gap notice must be gone: the runner runs the *.py tests
# now, so naming them as a gap would be a lie.
grep -q '^coverage gap: ' <<<"$green_out" \
    && fail "the obsolete 'coverage gap:' notice is still printed although the *.py tests now run"
pass "the obsolete 'coverage gap:' notice is gone"

# ---------------------------------------------------- the partial classification
# Discriminating fact 2: the partial stub is counted as RAN (it is in the 7 of 10
# numerator, not the not-run list) and named under its own summary section.
grep -qE '^partial  .*d4-py-partial-test\.py: partial: the real vendor material is not carried' <<<"$green_out" \
    || {
        printf '%s\n' "$green_out" >&2
        fail "the partial test must be named under a 'partial  ' summary line with its marker"
    }
pass "a 'partial:' test is named under its own 'partial  ' summary section"

grep -qE '^not run  .*d4-py-partial-test\.py' <<<"$green_out" \
    && fail "a partial test must not be listed as not run"
grep -qE '^partial  .*a-pass-test\.sh' <<<"$green_out" \
    && fail "a fully-run test must not be listed as partial"
grep -qE '^partial  .*b-skip-test\.sh' <<<"$green_out" \
    && fail "a skipped test must be listed as not run, not as partial"
pass "the partial marker does not leak onto tests that ran fully or skipped"

# The whole point of the marker: the partial test is inside the numerator.  Two
# of the six did not run, so 4 did -- and the partial stub is one of the 4, not a
# silent fifth exclusion.
grep -qx 'ran 4 of 6 tests' <<<"$green_out" \
    || fail "the partial test is missing from the 'ran N of M' numerator"
pass "the partial test is counted in the 'ran N of M' numerator"

# The markers must stay unambiguous to grep: each summary line carries the
# `not run  ` or `partial  ` prefix, so neither can be read as a test's own
# `ok`/`FAIL` output, and the markers themselves are line-anchored.
[ "$(grep -c '^partial  ' <<<"$green_out")" = 1 ] \
    || fail "expected exactly one 'partial  ' summary line"
[ "$(grep -cE '^partial:' <<<"$green_out")" = 1 ] \
    || fail "expected exactly one 'partial:' marker line"
grep -qE '^(ok|FAIL)' <<<"$(grep '^partial  ' <<<"$green_out")" \
    && fail "a summary line looks like a test's own ok/FAIL output"
pass "the partial marker and its summary line are unambiguous to grep"

# ------------------------------------- an all-caps SKIP: pre-tool gate
# HANDOFF.md 9.2's open item / 9.8 item 6: six tests' own tool gates print
# `SKIP: <tool> not found` (all caps) and exit 0 having evaluated nothing, and
# the runner's case-sensitive `^(skipped|skip):` rule matched only the lowercase
# form, so those tests counted as RAN.  The all-caps form is a test-level
# verdict only as the test's FIRST non-blank line of output: a gate exits before
# printing anything else.  ct-address-test.py prints one for a single optional
# section it then continues without, and the two integrity tests write
# `SKIP:<path>` lines into a fixture /file_list.txt, so a `SKIP:` emitted after
# the test began reporting must not reclassify a test that ran.
upper="$TMP/upper"
mkdir -p "$upper"
cat > "$upper/a-upper-gate-test.sh" <<'STUB'
#!/usr/bin/env bash
: > "$ZD_STUB_MARKERS/a-upper-gate-test.sh"
printf 'SKIP: %s\n' "the uppercase gate stub has no mke2fs"
STUB
cat > "$upper/b-upper-section-skip-test.sh" <<'STUB'
#!/usr/bin/env bash
: > "$ZD_STUB_MARKERS/b-upper-section-skip-test.sh"
echo "ok   the uppercase section stub reported a verdict first"
printf 'SKIP: %s\n' "one optional section is unavailable, but the test ran"
echo "ok   the uppercase section stub finished its other checks"
STUB

upper_out="$(ZD_SUITE_DIR="$upper" ZD_STUB_MARKERS="$markers" bash "$RUNNER" 2>&1)" \
    || fail "the all-caps SKIP: fixture must aggregate to exit 0"
grep -qx 'ran 1 of 2 tests' <<<"$upper_out" || {
    printf '%s\n' "$upper_out" >&2
    fail "a first-line all-caps SKIP: must reduce the numerator: expected 'ran 1 of 2 tests'"
}
grep -qE '^not run  .*a-upper-gate-test\.sh: SKIP: the uppercase gate stub has no mke2fs$' <<<"$upper_out" \
    || {
        printf '%s\n' "$upper_out" >&2
        fail "an all-caps SKIP: pre-tool gate must be named not run with its marker text"
    }
grep -qE '^(not run|partial)  .*b-upper-section-skip-test\.sh' <<<"$upper_out" \
    && fail "a SKIP: printed after the test began reporting must not reclassify it"
[ -e "$markers/a-upper-gate-test.sh" ] && [ -e "$markers/b-upper-section-skip-test.sh" ] \
    || fail "the all-caps SKIP: fixture stubs were not both executed"
pass "an all-caps SKIP: is a not-run verdict only as the test's first line"

# Discriminating fact 5: the case above is only a discrimination if the runner
# before this change classifies the gate stub RAN.  That is the runner at
# 2043850, the revision whose `^(skipped|skip):` rule was case-sensitive.
if ! git -C "$REPO" cat-file -e "$UPPER_PRE_FIX_REV:scripts/test/run-suite.sh" 2>/dev/null; then
    fail "cannot read scripts/test/run-suite.sh at $UPPER_PRE_FIX_REV (shallow or missing history)"
fi
git -C "$REPO" show "$UPPER_PRE_FIX_REV:scripts/test/run-suite.sh" > "$TMP/upper-pre-run-suite.sh" \
    || fail "could not stage the pre-change runner out of git"
bash -n "$TMP/upper-pre-run-suite.sh" || fail "the staged pre-change runner does not parse"
upper_pre_out="$(ZD_SUITE_DIR="$upper" ZD_STUB_MARKERS="$markers" bash "$TMP/upper-pre-run-suite.sh" 2>&1)"
grep -qx 'ran 2 of 2 tests' <<<"$upper_pre_out" || {
    printf '%s\n' "$upper_pre_out" >&2
    fail "the runner at $UPPER_PRE_FIX_REV was expected to count the all-caps SKIP: gate as RAN"
}
pass "the runner at $UPPER_PRE_FIX_REV counts the all-caps SKIP: gate as RAN"

[ ! -e "$TMP/self-ran" ] || fail "run-suite.sh was executed from the fixture (recursion)"
[ ! -e "$TMP/own-test-ran" ] || fail "run-suite-test.sh was executed from the fixture"
pass "run-suite.sh and run-suite-test.sh are excluded from the run"

# -------------------------------------------------------------- the bad fixture
bad_out="$(ZD_SUITE_DIR="$bad" ZD_STUB_MARKERS="$markers" bash "$RUNNER" 2>&1)" && bad_rc=0 || bad_rc=$?
[ "$bad_rc" -ne 0 ] || {
    printf '%s\n' "$bad_out" >&2
    fail "a fixture with a failing test must aggregate non-zero"
}
[ "$bad_rc" = 1 ] || fail "a failing test must give exit 1 (got $bad_rc)"
pass "the fixture with a failing test aggregates to exit 1"

grep -qx 'ran 5 of 7 tests' <<<"$bad_out" || {
    printf '%s\n' "$bad_out" >&2
    fail "expected 'ran 5 of 7 tests' with one failing stub"
}
pass "the failing fixture gives 'ran 5 of 7 tests'"

grep -qE '^failed  .*e-fail-test\.py \(exit 1\)$' <<<"$bad_out" \
    || {
        printf '%s\n' "$bad_out" >&2
        fail "the failing test must be named in the summary"
    }
[ -e "$markers/e-fail-test.py" ] \
    || fail "the failing *-test.py stub was never executed"
pass "the failing *-test.py is executed and named in the summary"

# ------------------------------------------------------- the pre-fix runner
# Discriminating fact 3, the sharp one: at abc0b3a the runner never ran a
# *.py test.  Given the same mixed fixture it must run only the *.sh stub and
# name the *.py test as a coverage gap; the runner under test must run both and
# print no gap notice.  This test therefore fails against the pre-fix revision.
prefix_dir="$TMP/prefix"
mkdir -p "$prefix_dir"
cat > "$prefix_dir/a-pass-test.sh" <<'STUB'
#!/usr/bin/env bash
echo "ok   the pre-fix grid's shell stub ran"
STUB
cat > "$prefix_dir/b-py-pass-test.py" <<STUB
#!/usr/bin/env python3
"""Must be run by the fixed runner and only named by the pre-fix one."""
open("$TMP/prefix-py-ran", "w").close()
print("ok   the pre-fix grid's python stub ran")
STUB

if ! git -C "$REPO" cat-file -e "$PRE_FIX_REV:scripts/test/run-suite.sh" 2>/dev/null; then
    # Not a skip: without the pre-fix runner the discrimination this test exists
    # for cannot be shown, and a silent pass would hide that.
    fail "cannot read scripts/test/run-suite.sh at $PRE_FIX_REV (shallow or missing history)"
fi
git -C "$REPO" show "$PRE_FIX_REV:scripts/test/run-suite.sh" > "$TMP/prefix-run-suite.sh" \
    || fail "could not stage the pre-fix runner out of git"
bash -n "$TMP/prefix-run-suite.sh" || fail "the staged pre-fix runner does not parse"
rm -f "$TMP/prefix-py-ran"
prefix_out="$(ZD_SUITE_DIR="$prefix_dir" bash "$TMP/prefix-run-suite.sh" 2>&1)"
[ -e "$TMP/prefix-py-ran" ] \
    && fail "the pre-fix runner at $PRE_FIX_REV executed a *-test.py, which contradicts the recorded gap"
grep -qE "^===== .*b-py-pass-test\.py\$" <<<"$prefix_out" \
    && fail "the pre-fix runner at $PRE_FIX_REV ran the *-test.py"
grep -q '^coverage gap: ' <<<"$prefix_out" \
    || {
        printf '%s\n' "$prefix_out" >&2
        fail "the pre-fix runner was expected to name the *-test.py as a coverage gap"
    }
grep -q 'b-py-pass-test\.py' <<<"$prefix_out" \
    || fail "the pre-fix runner's coverage gap does not name the *-test.py"
pass "the pre-fix runner ($PRE_FIX_REV) does NOT run the *-test.py and names it a coverage gap"

rm -f "$TMP/prefix-py-ran"
fixed_out="$(ZD_SUITE_DIR="$prefix_dir" bash "$RUNNER" 2>&1)" \
    || fail "the fixed runner must exit 0 on the mixed pre-fix fixture"
[ -e "$TMP/prefix-py-ran" ] \
    || fail "the fixed runner did not execute the *-test.py"
grep -qx 'ran 2 of 2 tests' <<<"$fixed_out" || {
    printf '%s\n' "$fixed_out" >&2
    fail "the fixed runner must give 'ran 2 of 2 tests' on the mixed pre-fix fixture"
}
grep -q '^coverage gap: ' <<<"$fixed_out" \
    && fail "the fixed runner still prints the obsolete coverage-gap notice"
pass "the fixed runner runs the same *-test.py and counts it (2 of 2, no gap notice)"

# ------------------------------------- an environmental shortfall must skip
# wizard-http-test.py needs ~8 GiB free and used to abort with a `FAIL:` line
# when no filesystem had it, which would fail a whole suite run for a full disk.
# Exercise its real code with both candidate filesystems too small (the copy is
# on a 3.8 GB tmpfs and its .boot-test cannot be created) and require a
# `skipped:` line and exit 0.
WIZ="$REPO/scripts/test/wizard-http-test.py"
if [ -f "$WIZ" ]; then
    small="$(mktemp -d "${TMPDIR:-/tmp}/zd-no-room.XXXXXX")" 2>/dev/null
    if [ -z "$small" ]; then
        skip "cannot create the small-filesystem fixture directory"
    fi
    cp "$WIZ" "$small/wizard-http-test.py"
    mkdir -p "$small/.boot-test"
    chmod 500 "$small/.boot-test"
    noreoom_out="$(cd "$small" && TMPDIR="$small" timeout 120 python3 wizard-http-test.py 2>&1)" \
        && noreoom_rc=0 || noreoom_rc=$?
    chmod 700 "$small/.boot-test"
    if [ "$noreoom_rc" = 0 ] && grep -q '^skipped: ' <<<"$noreoom_out"; then
        pass "no room for the wizard fixtures: wizard-http-test.py prints 'skipped:' and exits 0"
    elif grep -q '^FAIL:.*8 GiB' <<<"$noreoom_out"; then
        printf '%s\n' "$noreoom_out" >&2
        fail "an environmental shortfall still aborts with a FAIL line instead of skipping"
    else
        printf '%s\n' "$noreoom_out" >&2
        fail "unexpected result from the no-room wizard fixture (rc=$noreoom_rc)"
    fi
    rm -rf "$small"
else
    # This arm exercises wizard-http-test.py because that test is the one with a
    # real environment gate.  The wizard is not part of this branch's scope, so
    # on a tree without it the arm has no subject rather than a failure; the
    # runner's own skip handling is covered by the stub fixtures above.
    skip "wizard-http-test.py is not present on this tree; the environmental-shortfall arm has no subject"
fi

# ------------------------------------------------------------ restricted run
one_out="$(ZD_SUITE_DIR="$green" ZD_STUB_MARKERS="$markers" bash "$RUNNER" a-pass-test.sh 2>&1)" \
    || fail "a restricted run of the passing stub must exit 0"
grep -qx 'ran 1 of 1 tests' <<<"$one_out" || {
    printf '%s\n' "$one_out" >&2
    fail "restricting to one test must give 'ran 1 of 1 tests'"
}
grep -q 'b-skip-test\.sh' <<<"$one_out" \
    && fail "a restricted run must not touch the other tests"
pass "an explicit test argument restricts the run (ran 1 of 1)"

# A restricted run of a *-test.py must also work, by name and by path.
py_one_out="$(ZD_SUITE_DIR="$green" ZD_STUB_MARKERS="$markers" bash "$RUNNER" d2-py-pass-test.py 2>&1)" \
    || fail "a restricted run of a passing *-test.py must exit 0"
grep -qx 'ran 1 of 1 tests' <<<"$py_one_out" || {
    printf '%s\n' "$py_one_out" >&2
    fail "restricting to one *-test.py must give 'ran 1 of 1 tests'"
}
pass "an explicit *-test.py argument restricts the run (ran 1 of 1)"

# ------------------------------------- a missing interpreter must degrade
# On a host with no python3, invoking a *-test.py gives exit 127, which would
# count as a FAILED test and drive the aggregate to 1 -- an environment
# shortfall turned into a suite failure (the class session 7 fixed for
# boot-test.sh in a921a7e).  The runner must instead record every *-test.py as
# not run, with its own marker line, and keep the aggregate at 0.  Force it with
# a PATH that carries the runner's own tools but no python3.
fakebin="$TMP/nopy-bin"
mkdir -p "$fakebin"
for tool in bash sh grep sed wc mktemp tee tail head cat sort tr rm ln cp mkdir dirname basename cut awk printf env; do
    real="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$real" ] && ln -sf "$real" "$fakebin/$tool"
done
[ ! -e "$fakebin/python3" ] || fail "the no-python3 fixture PATH has a python3 in it"
nopy_out="$(PATH="$fakebin" ZD_SUITE_DIR="$green" ZD_STUB_MARKERS="$markers" \
    bash "$RUNNER" d2-py-pass-test.py d3-py-skip-test.py d4-py-partial-test.py \
    a-pass-test.sh 2>&1)" && nopy_rc=0 || nopy_rc=$?
[ "$nopy_rc" = 0 ] || {
    printf '%s\n' "$nopy_out" >&2
    fail "a missing python3 must not fail the suite (exit $nopy_rc)"
}
grep -qx 'ran 1 of 4 tests' <<<"$nopy_out" || {
    printf '%s\n' "$nopy_out" >&2
    fail "with no python3 only the *.sh test ran: expected 'ran 1 of 4 tests'"
}
[ "$(grep -c '^not run  .*: skipped: python3 is not available on PATH' <<<"$nopy_out")" = 3 ] || {
    printf '%s\n' "$nopy_out" >&2
    fail "every *-test.py must be named not run with the runner's own python3 marker"
}
[ "$(grep -c '^exit=127$' <<<"$nopy_out")" = 3 ] \
    || fail "the transcript must still show the *-test.py invocations failing with 127"
grep -q '^0 of 4 tests failed$' <<<"$nopy_out" || {
    printf '%s\n' "$nopy_out" >&2
    fail "the missing interpreter must not be counted as a failed test"
}
if [ -e "$markers/d2-py-pass-test.py" ]; then
    rm -f "$markers/d2-py-pass-test.py"
fi
pass "with no python3 the *-test.py tests are recorded not run and the suite still exits 0"

echo
echo "all run-suite tests passed"
