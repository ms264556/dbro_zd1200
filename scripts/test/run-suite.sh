#!/usr/bin/env bash
#
# run-suite.sh — run the offline suite and say how many tests actually ran.
#
# Why this exists: the suite used to be an ad-hoc shell loop that printed
# `===== <script>` and the exit code per test and nothing else.  Six of the 26
# tests at b48d8ab print a `skipped:`/`skip:` marker and exit 0 having evaluated
# nothing (boot-test.sh, patch-matrix-test.sh, wizard-e2e-lxc.sh,
# xlink-mac-test.sh) or only part of their subject (chk-integrity-cost-test.sh,
# skip-integrity-test.sh; HANDOFF.md 7.4, review-session7/REPORT.md class 3).  A
# transcript in which every exit code is 0 therefore reads green while only 20
# of the 26 evaluated their subject.  This runner keeps the transcript format
# (`===== <script>` ... `exit=N`) and the exit-code contract, and adds the
# missing summary:
#
#     ran 20 of 26 tests
#     not run  scripts/test/boot-test.sh: skipped: this aarch64 host cannot ...
#
# The exit line is the BARE `exit=N` of the most recent recorded transcript
# (wizard-e2e-9x/session7/offline-suite-after-fix.txt), so the two can be
# diffed line-for-line.  The older wizard-e2e-9x/offline-suite-after.txt wrote
# `----- exit=N`; that dashed form is gone and must not be "fixed" back.  The
# runner's own summary is opened by `##### suite summary`, not by another
# `===== ` line, so `grep -c '^===== '` still counts test scripts and nothing
# else, and its lines (`ran ...`, `not run  ...`, `partial  ...`, `failed  ...`)
# cannot be mistaken for a test's own ok/FAIL output.
#
# Membership and order are `scripts/test/*.sh` plus every `scripts/test/*-test.py`
# in LC_ALL=C order over the whole set -- except run-suite.sh itself and
# run-suite-test.sh, which drive this script and would recurse.  No test count is
# hard-coded anywhere: the set is whatever the glob finds at run time.
#
# What this does to the recorded-transcript comparison, stated plainly.  The
# recorded transcript (wizard-e2e-9x/session7/offline-suite-after-fix.txt) has 26
# `===== ` headers, all of them `*.sh`; the runner's own earlier header described
# that run as `ran 20 of 26`, and named the five `*-test.py` tests as a
# `coverage gap:` instead of running them.  This runner's member set is a SUPERSET
# of that one -- the same `*.sh` members, in the same order, plus the
# `*-test.py` members now that they run -- so:
#
#   * `ran 20 of 26` is NOT reproducible by construction any more, and it is not
#     meant to be: M is now the whole globbed set, so the same tree reads a
#     larger M and a larger numerator.  The old number is history, not a target,
#     and no member is excluded to preserve it.
#   * `grep -c '^===== '` still counts members exactly, and `===== <name>` /
#     bare `exit=N` are unchanged, so a transcript can still be diffed against
#     an older one -- the `*.sh` portion of a new transcript is line-for-line the
#     old one, with the `*-test.py` members appended in glob order.
#   * Because a `partial:` test is counted as run (below) and the integrity tests
#     now print `partial:` rather than `skipped:`, a run at a given tree reads a
#     numerator two higher than the same run under the previous runner.
#
# How each test is invoked: a `*.sh` test with `bash`, a `*-test.py` test with
# `python3` -- the interpreter its own shebang (`#!/usr/bin/env python3`) and
# header name, and the same command its Usage line documents (`python3
# scripts/test/<name>`).  A `.py` test whose own output cannot be read is warned
# about below; one that cannot evaluate its subject must print its own
# `skipped:`/`skip:` marker and exit 0, exactly as the shell tests do.  Where
# python3 itself is absent from PATH, every `*-test.py` is recorded not run with
# a `skipped:` line of this runner's own rather than being counted as a failure:
# a missing interpreter is an environment shortfall, not a defect in the test.
# (That is the one interpreter check made here; the `*.sh` members are driven by
# the bash already running this script, and their own tool preconditions are
# theirs to skip on, as they already do.)
#
# Usage:
#   scripts/test/run-suite.sh [TEST ...]
#
#   With no TEST arguments the whole suite runs in order.  Each TEST is a test
#   script's name (resolved in the suite directory) or a path, and restricts the
#   run to those tests -- useful for re-running one test without the suite.
#   -h/--help prints this header.
#
# Environment:
#   ZD_SUITE_DIR   directory to take the *.sh and *-test.py tests from.
#                  Default: the directory holding this script (scripts/test).
#                  The offline self-test run-suite-test.sh points it at a
#                  synthetic fixture directory.
#
# Exit status: 0 when every test that ran exited 0; 1 when any test failed (the
# failing tests are named by the `failed  <script>` lines of the summary); 2 for
# a usage or setup error (no such test, no tests found, no scratch directory).
# A test that skips still exits 0 and does not change the aggregate, exactly as
# before -- it is only the `ran N of M` line that makes it visible.  Output that
# cannot be read is recorded as not run and the suite continues; nothing here
# aborts a run part-way.  The test output and the summary both go to stdout (the
# transcript is one stream); the runner's own warnings and usage errors go to
# stderr with a `run-suite:` prefix.
#
# The three test classifications, as markers a test prints on its own stdout or
# stderr.  For the lowercase markers the first line matching, in this precedence
# order, decides; the all-caps `SKIP:` form is the first-line-only exception
# described below:
#
#   skipped:/skip:  the test evaluated none of its subject (no lab, no root, no
#                   vendor material, no PVE host).  Counted NOT RUN: it is the
#                   only marker that reduces the `ran N of M` numerator, and it
#                   is named under `not run  <test>: <marker line>`.  An
#                   all-caps `SKIP:` is accepted as the same marker, but only as
#                   the test's first non-blank line of output (see below).
#   partial:        the test ran, but only against what it carries itself -- a
#                   synthetic fixture standing in for vendor material it cannot
#                   carry (chk-integrity-cost-test.sh and skip-integrity-test.sh
#                   without AS_CHKINT).  Counted RAN (it does not reduce the
#                   numerator), and named under `partial  <test>: <marker line>`
#                   so what it could not evaluate stays visible.  Before this
#                   marker existed those two tests were counted NOT RUN while
#                   having evaluated a fixture (HANDOFF.md 8.8 item 5).
#   neither         a full run of its subject.
#
# The all-caps `SKIP:` form, and why it is recognised only on the first line.
# Several tests' own tool gates print `SKIP: <tool> not found` and `exit 0`
# before doing any work, so without this the runner counts a test that evaluated
# nothing as RAN (HANDOFF.md 9.2, 9.8 item 6; the gates are in file-list-test.sh,
# dump-rootfs-version-test.sh, grub-effective-entry-test.sh,
# webs-header-limit-test.sh, chk-integrity-cost-test.sh and
# skip-integrity-test.sh).  But `SKIP:` in a test's output is not always a
# verdict about the test: ct-address-test.py prints one for a single optional
# section whose precondition is missing and then evaluates everything else, and
# the integrity tests write `SKIP:<path>` LINES INTO A FIXTURE /file_list.txt,
# where the line is content and not a verdict.  A test-level gate exits before
# printing anything at all, so its `SKIP:` is the first non-blank line of that
# test's output, while a section skip or fixture content is emitted only after
# the test has begun reporting.  An all-caps `SKIP:` therefore counts as a skip
# only when it is that first non-blank line.  The lowercase `skipped:`/`skip:`
# forms are deliberately unchanged: they are still recognised anywhere in the
# output, because tests that print them after their own `ok` lines depend on
# that (and on being counted NOT RUN).
#
# The markers are unambiguous to grep: each is anchored at the start of a line
# (`^skipped: `, `^skip: `, `^partial: `, and `^SKIP: ` in the first-line-only
# form above), and every summary line is prefixed
# with `not run  ` or `partial  `, so neither a marker nor a summary line can be
# mistaken for a test's own `ok`/`FAIL` output.
#

set -uo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$self_dir/../.." && pwd)"
suite_dir="${ZD_SUITE_DIR:-$self_dir}"
# Running either of these from the suite would recurse: they drive this runner.
excluded_names="run-suite.sh run-suite-test.sh"

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

is_excluded() {
    case " $excluded_names " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# Repo-relative when the path is inside the repo, so the transcript keeps the
# recorded `scripts/test/<name>` form; otherwise as given (the self-test's
# fixture directories live under /tmp).
display() {
    case "$1" in
        "$repo"/*) printf '%s\n' "${1#"$repo"/}" ;;
        *)         printf '%s\n' "$1" ;;
    esac
}

# A test's interpreter, from its own documented invocation: `python3` for a
# *-test.py (its shebang is `#!/usr/bin/env python3`), `bash` for a *.sh (the
# runner has always driven those with bash, not with their executable bit).
runner_of() {
    case "$1" in
        *.py) printf 'python3\n' ;;
        *)    printf 'bash\n' ;;
    esac
}

# A missing interpreter is an environment shortfall, not a test failure: invoking
# a *-test.py without python3 would give exit 127, which the aggregate would count
# as a failed test and a broken suite.  So a *-test.py on a host with no python3
# is recorded NOT RUN with this marker line instead (nothing here assumes the
# test's own machinery is present either -- see the header).
have_python3=1
command -v python3 >/dev/null 2>&1 || have_python3=0
python3_skip_reason="python3 is not available on PATH, so this *-test.py cannot run"

tests=()
if [ "$#" -gt 0 ]; then
    for arg in "$@"; do
        case "$arg" in
            -h|--help) usage; exit 0 ;;
        esac
    done
    for arg in "$@"; do
        if [ -f "$arg" ]; then
            candidate="$arg"
        elif [ -f "$suite_dir/$arg" ]; then
            candidate="$suite_dir/$arg"
        else
            printf 'run-suite: no such test: %s\n' "$arg" >&2
            exit 2
        fi
        if is_excluded "$(basename "$candidate")"; then
            printf 'run-suite: ignoring %s: it drives this runner (recursion)\n' \
                "$(basename "$candidate")" >&2
            continue
        fi
        tests+=("$candidate")
    done
else
    shopt -s nullglob
    candidates=("$suite_dir"/*.sh "$suite_dir"/*-test.py)
    shopt -u nullglob
    if [ "${#candidates[@]}" -eq 0 ]; then
        printf 'run-suite: no *.sh or *-test.py tests in %s\n' "$suite_dir" >&2
        exit 2
    fi
    # LC_ALL=C so the membership order is the recorded transcript's, whatever
    # the caller's locale is.
    while IFS= read -r f; do
        is_excluded "$(basename "$f")" && continue
        tests+=("$f")
    done < <(printf '%s\n' "${candidates[@]}" | LC_ALL=C sort)
fi

if [ "${#tests[@]}" -eq 0 ]; then
    printf 'run-suite: no tests selected in %s\n' "$suite_dir" >&2
    exit 2
fi

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/zd-run-suite.XXXXXX")" \
    || { printf 'run-suite: cannot create a scratch directory\n' >&2; exit 2; }
trap 'rm -rf "$tmpdir"' EXIT

total=0
failed=0
not_run=0
partial=0
skip_lines=()
partial_lines=()
fail_lines=()

for path in "${tests[@]}"; do
    name="$(display "$path")"
    total=$((total + 1))
    out="$tmpdir/out.$total"
    interpreter="$(runner_of "$path")"
    printf '===== %s\n' "$name"
    # Stream the test's own output through to stdout (so a long suite is
    # observable) while keeping a copy so a marker can be recognised.  stderr is
    # merged: the recorded transcript is one stream, and a test's marker or
    # diagnostics may be written to either.
    "$interpreter" "$path" 2>&1 | tee "$out"
    rc="${PIPESTATUS[0]}"
    printf 'exit=%s\n' "$rc"

    marker=""
    rc_belongs_to_the_test=1
    if [ "$interpreter" = python3 ] && [ "$have_python3" -eq 0 ]; then
        # The interpreter is missing, so exit 127 above is this host's and not the
        # test's: record the test not run rather than failed, say why, and do not
        # let that 127 reach `failed` (a missing interpreter must not fail a run).
        marker="skipped: $python3_skip_reason"
        rc_belongs_to_the_test=0
    elif [ -r "$out" ]; then
        # A skip says the test evaluated none of its subject; a partial says it
        # ran against its synthetic fixture only.  A skip wins if both appear.
        marker="$(grep -m1 -E '^(skipped|skip):' "$out" || true)"
        if [ -z "$marker" ]; then
            # An all-caps `SKIP:` is a test-level verdict only as the test's
            # FIRST non-blank line of output: that is the shape of a pre-tool
            # gate (marker, then exit 0, having evaluated nothing).  A `SKIP:`
            # after the test has begun reporting is not a verdict about the
            # test -- ct-address-test.py prints one for an optional section it
            # then continues without, and the integrity tests write
            # `SKIP:<path>` lines into a fixture list -- so it must not
            # reclassify a test that ran.
            first_line="$(grep -m1 -v '^[[:space:]]*$' "$out" || true)"
            case "$first_line" in
                SKIP:*) marker="$first_line" ;;
            esac
        fi
        if [ -z "$marker" ]; then
            marker="$(grep -m1 -E '^partial:' "$out" || true)"
        fi
    fi
    if [ ! -r "$out" ]; then
        not_run=$((not_run + 1))
        skip_lines+=("$name: output was not readable, so the test is recorded as not run")
        printf 'run-suite: warning: %s produced no readable output\n' "$name" >&2
    elif [ -n "$marker" ]; then
        case "$marker" in
            partial:*)
                # Counted as RUN, so it is deliberately NOT added to not_run:
                # `ran N of M` is `total - not_run`, and a partial test must not
                # be silently dropped from that numerator.  It is named under its
                # own `partial  ` summary section instead.
                partial=$((partial + 1))
                partial_lines+=("$name: $marker")
                ;;
            *)
                not_run=$((not_run + 1))
                skip_lines+=("$name: $marker")
                ;;
        esac
    fi

    if [ "$rc" -ne 0 ] && [ "$rc_belongs_to_the_test" -eq 1 ]; then
        failed=$((failed + 1))
        fail_lines+=("$name (exit $rc)")
    fi
done

printf '\n##### suite summary\n'
printf 'ran %s of %s tests\n' "$((total - not_run))" "$total"
for line in ${skip_lines+"${skip_lines[@]}"}; do
    printf 'not run  %s\n' "$line"
done
for line in ${partial_lines+"${partial_lines[@]}"}; do
    printf 'partial  %s\n' "$line"
done
for line in ${fail_lines+"${fail_lines[@]}"}; do
    printf 'failed  %s\n' "$line"
done
printf '%s of %s tests failed\n' "$failed" "$total"

# There is deliberately no `coverage gap:` line any more: it existed to name the
# *-test.py tests this runner did not drive, and it now drives them, so the line
# would have been a lie.  A test that cannot run is named by `not run  ` instead.
if [ "$partial" -gt 0 ]; then
    printf 'note: %s test(s) ran against a synthetic fixture only (see the partial lines above)\n' \
        "$partial"
fi
if [ "$have_python3" -eq 0 ]; then
    printf 'run-suite: warning: %s (every *-test.py is recorded as not run)\n' \
        "$python3_skip_reason" >&2
fi

if [ "$failed" -gt 0 ]; then
    exit 1
fi
exit 0
