#!/usr/bin/env bash
#
# boot-test-runscope-test.sh — two concurrent runs of boot-test.sh must not share
# the per-run state directory, and so must not be able to read each other's
# serial log.
#
# Why this exists: boot-test.sh defaulted its state dir to the fixed
# $repo/.boot-test (b48d8ab:54), and everything landed there — the serial log
# (:200), the QEMU stderr (:201), the debugcon log (:205), the console socket
# (:233) and the container bind mount (:190).  Two concurrent runs therefore
# wrote guest console output into one serial.log while each truncated it at `: >
# "$log"` (:206), and the milestone loop greps that one file (:244).  A run could
# report `PASS — reached 'init'` on the other run's guest line, with its own
# guest never booted.
#
# This test runs offline, with no lab: the real script is executed twice per
# revision, concurrently, against recording stub `docker` and
# `qemu-system-i386` on PATH.  The stub docker answers `info`/`image inspect`,
# and for `run` it parses the `-v <state-dir>:/var/lib/zd1200` bind mount and
# creates <state-dir>/synthetic-cf.img, which is what the container's
# prepare-vm-disks.sh would have written.  Run B's stub qemu then writes one
# milestone line tagged with its own name into the serial log it was told to
# write; run A's stub qemu writes nothing, so A is a guest that never booted.
# The two stubs rendezvous after both scripts have launched them — i.e. after
# both have run `: > "$log"` (:206) — so neither truncation can erase the other's
# write.  The defaults are those the script itself uses: --expect init, whose
# pattern is `/dev/sda4 on /writable type ext2` (:73).
#
# The assertions are mechanical:
#   1. the per-run `.boot-test` paths each run names are disjoint;
#   2. the two runs' -serial logfiles differ, and neither file holds the other
#      run's tag;
#   3. the fixed script's run A, whose guest wrote nothing, does NOT pass;
#   4. an explicit --state-dir yields the same path set (relative to it) on the
#      fixed script as on the pre-fix one, so the escape hatch is unchanged;
#   5. a successful run removes its per-run disk but keeps the serial log it just
#      printed; a failed run keeps both; ZD_BOOT_TEST_KEEP_RUN_DIR=1 keeps the disk
#      on success too (the pairs above run with KEEP=1 so their disks survive);
# and the discriminating half requires the pre-fix revision's run A to report a
# FALSE PASS on run B's line, the actual defect mechanism.
#
# The harness sets ZD_BOOT_TEST_KEEP_RUN_DIR=1 for the concurrent pairs: run B
# legitimately passes, and a passing run otherwise removes its own per-run disk
# (1919.5 MiB apparent, 418 MiB allocated), which the path assertions do not need
# but which would make the two runs' named path sets differ between a kept and a
# pruned run.  The per-run *default* is still what is under test — no --state-dir
# is passed — only the post-success disk pruning is held off.  The pruning itself
# is measured separately in section 4.
#
# HOW FAR THIS DRIVES THE REAL SCRIPT.  `--no-build` skips step 1, and a run
# reaches: argument parsing (:112-129), the --reuse guard (:148-150), the tooling
# skip checks (:155-158), the state-dir normalisation (:196-204), the stub
# `docker run` disk-prepare step (:221), the disk and log setup (:240-247), and
# the QEMU launch (:291), then its monitoring loop.  It does
# NOT boot a guest: the qemu stub writes one line and exits, so the run under test
# reaches its own milestone grep and its own PASS/FAIL decision.  That decision is
# the subject on the pre-fix side (a false PASS) and is checked on the fixed side
# (no false PASS).  Section 3 drives `--state-dir`; `--reboot` is not driven, and
# its console socket (boot-test.sh:284) derives from the same state_dir, so it is
# covered by inspection of that default, not by measurement.  The container-side
# disk build is stubbed, so prepare-vm-disks.sh's own refuse-to-rebuild gate is
# not exercised.
#
# It is discriminating: b48d8ab, the revision before the fix, is staged out of
# git and put through the same harness, and ITS run A is required to pass on run
# B's line.  If that blob is not in the clone the harness still checks the
# current script and prints `skipped:` for the discriminating half, the way
# wizard-e2e-runscope-test.sh and patch-kernel-fixture-test.sh do for their
# pre-change revisions.
#
# Usage: ./scripts/test/boot-test-runscope-test.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO/scripts/test/boot-test.sh"
# The last revision whose default state dir is the fixed $repo/.boot-test: the
# harness has to show that revision's run A passing on run B's guest, or it
# proves nothing.
PRE_FIX_REV="b48d8ab"
# The milestone pattern for the script's default --expect init (boot-test.sh:73),
# written by run B's stub guest and searched for by run A's milestone loop.
MILESTONE="/dev/sda4 on /writable type ext2"

skip() { printf 'skipped: %s\n' "$*"; exit 0; }
pass() { printf 'ok   %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$SCRIPT" ] || fail "missing $SCRIPT"
command -v mktemp >/dev/null 2>&1 || skip "needs mktemp"
command -v setsid >/dev/null 2>&1 || skip "needs setsid (the script detaches QEMU with it)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-boot-runscope.XXXXXX")" || skip "cannot create a scratch directory"
trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------------- the stubs
# `docker`: record the whole command line, answer `info`/`image` success, and for
# `run` create the disk in the bind-mounted state dir.  `qemu-system-i386`:
# record the command line and its own stderr path, rendezvous with the other run,
# write the tagged milestone line if this run is the one with a guest, and exit.
write_stubs() {
    cat > "$1/docker" <<'STUB'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$FAKE_CMD_LOG"
case "${1:-}" in
    info|image) exit 0 ;;
    run)
        sd=""
        for a in "$@"; do
            case "$a" in
                *:/var/lib/zd1200) sd="${a%:/var/lib/zd1200}" ;;
            esac
        done
        [ -n "$sd" ] || { echo "stub docker: no -v <dir>:/var/lib/zd1200 mount" >&2; exit 1; }
        : > "$sd/synthetic-cf.img" || exit 1
        exit 0 ;;
esac
exit 0
STUB
    cat > "$1/qemu-system-i386" <<'STUB'
#!/usr/bin/env bash
printf 'qemu %s\n' "$*" >> "$FAKE_CMD_LOG"
err="$(readlink -f "/proc/$$/fd/2" 2>/dev/null || true)"
[ -n "$err" ] && printf 'qemu-stderr %s\n' "$err" >> "$FAKE_CMD_LOG"
serial=""
for a in "$@"; do
    case "$a" in
        file:*) serial="${a#file:}" ;;
    esac
done
# Rendezvous: mark ourselves started, then wait until both runs' QEMU stubs are
# up.  Both scripts have already truncated their serial log by then (boot-test.sh
# does `: > "$log"` before it launches QEMU), so the write below cannot be erased
# by the other run's truncation.
: > "$FAKE_RV_DIR/started.${FAKE_RUN_TAG}"
i=0
while [ "$i" -lt 100 ]; do
    all=1
    for p in ${FAKE_RV_PEERS:-A B}; do
        [ -f "$FAKE_RV_DIR/started.$p" ] || all=0
    done
    [ "$all" = 1 ] && break
    sleep 0.1
    i=$((i + 1))
done
if [ "${FAKE_GUEST_WRITES:-0}" = 1 ] && [ -n "$serial" ]; then
    printf '%s (GUEST %s)\n' "$FAKE_MILESTONE" "$FAKE_RUN_TAG" >> "$serial"
fi
# Stay alive long enough for the other run's milestone loop to grep the log.
sleep 3
exit 0
STUB
    chmod 755 "$1/docker" "$1/qemu-system-i386"
}

# ----------------------------------------------------------------- the harness
# prepare <root>: an instance root with its own recording stubs and a minimal
# script tree — just the script and the two prepare-step inputs it checks for
# (boot-test.sh:200-202) — so nothing here depends on the repo's own image/ state.
prepare() {
    mkdir -p "$1/tree/scripts/test" "$1/bin" "$1/rv" "$1/tree/image/signing-cert" \
        || fail "could not stage $1"
    : > "$1/tree/image/rootfs.ext2" || fail "could not seed $1/image/rootfs.ext2"
    write_stubs "$1/bin"
}

# stage <root> <script file>: put a revision's script into that tree.
stage() {
    cp "$2" "$1/tree/scripts/test/boot-test.sh" || fail "could not stage $2"
    chmod 755 "$1/tree/scripts/test/boot-test.sh"
}

# launch <root> <tag> <guest-writes 0|1> <rv-peers> <keep 0|1>: one run of the
# staged script, detached, with the stubs in front of the real docker/qemu.  No
# --state-dir is passed, so the default state dir is what is under test;
# --no-build keeps step 1 offline.  keep sets ZD_BOOT_TEST_KEEP_RUN_DIR.
launch() {
    ( cd "$1/tree" && env PATH="$1/bin:$PATH" \
        FAKE_CMD_LOG="$1/cmds-$2.log" FAKE_RUN_TAG="$2" \
        FAKE_RV_DIR="$1/rv" FAKE_MILESTONE="$MILESTONE" \
        FAKE_GUEST_WRITES="$3" FAKE_RV_PEERS="$4" \
        ZD_BOOT_TEST_KEEP_RUN_DIR="$5" \
        ./scripts/test/boot-test.sh --no-build > "$1/out-$2.txt" 2>&1
      echo $? > "$1/rc-$2" ) &
    LAUNCHED_PIDS="$LAUNCHED_PIDS $!"
}

# reap <label> <root> <tag> <tag>: wait (bounded) for both runs of a pair.
reap() {
    local label="$1" root="$2"; shift 2
    local deadline=$((SECONDS + 120)) all
    while [ $SECONDS -lt $deadline ]; do
        all=1
        for tag in "$@"; do [ -f "$root/rc-$tag" ] || all=0; done
        [ "$all" = 1 ] && return 0
        sleep 1
    done
    for pid in $LAUNCHED_PIDS; do kill "$pid" 2>/dev/null; done
    fail "$label: the stubbed runs did not finish within 120 s (harness problem, not a defect in the script under test)"
}

# state_paths <root> <tag>: the per-run state paths that run named — the disk,
# the serial log, the QEMU stderr, the debugcon log and the bind mount — sorted,
# unique.  Only paths under .boot-test are compared: the read-only inputs
# ($tree/image, the signing cert) are legitimately the same for both runs.
state_paths() {
    grep -oE '/[^ :,]*/\.boot-test[^ :,]*' "$1/cmds-$2.log" 2>/dev/null \
        | sed -e 's#/*$##' | sort -u
}

# state_paths_under <root> <tag> <dir>: the same, but for an explicit --state-dir,
# which need not be under .boot-test.
state_paths_under() {
    grep -oE '/[^ :,]*' "$1/cmds-$2.log" 2>/dev/null | grep -F "$3" | sort -u
}

# serial_path <root> <tag>: the -serial logfile that run's QEMU was told to write.
serial_path() {
    grep -oE 'file:[^ ]*' "$1/cmds-$2.log" 2>/dev/null | sed -n 's/^file://p' | head -1
}

# drive_ok <label> <root> <tag>: the harness must have driven the real script
# past its environment skips and into its own QEMU launch, or it measured nothing.
drive_ok() {
    local label="$1" root="$2" tag="$3"
    grep -q '^qemu ' "$root/cmds-$tag.log" 2>/dev/null \
        || { echo "--- out-$tag.txt ---" >&2; cat "$root/out-$tag.txt" >&2
             fail "$label: run $tag never reached the QEMU launch; the harness did not drive the script (not a defect in the script under test)"; }
}

# --------------------------------------------------------------- stage it all
prepare "$TMP/fixed"
stage "$TMP/fixed" "$SCRIPT"
prepare "$TMP/prefix"
LAUNCHED_PIDS=""
# Run A's guest writes nothing; run B's writes the milestone line.  Under the
# pre-fix default both A and B append to the same serial.log, so A's milestone
# loop matches B's line.
for tag in A B; do
    case "$tag" in A) w=0 ;; B) w=1 ;; esac
    launch "$TMP/fixed" "$tag" "$w" "A B" 1
done
HAVE_PRE_FIX=0
if command -v git >/dev/null 2>&1 \
        && git -C "$REPO" cat-file -e "$PRE_FIX_REV:scripts/test/boot-test.sh" 2>/dev/null; then
    git -C "$REPO" show "$PRE_FIX_REV:scripts/test/boot-test.sh" \
        > "$TMP/prefix/tree/scripts/test/boot-test.sh" 2>/dev/null
    if [ -s "$TMP/prefix/tree/scripts/test/boot-test.sh" ]; then
        chmod 755 "$TMP/prefix/tree/scripts/test/boot-test.sh"
        HAVE_PRE_FIX=1
        for tag in A B; do
            case "$tag" in A) w=0 ;; B) w=1 ;; esac
            launch "$TMP/prefix" "$tag" "$w" "A B" 1
        done
    fi
fi
reap "current script" "$TMP/fixed" A B
[ "$HAVE_PRE_FIX" = 1 ] && reap "$PRE_FIX_REV" "$TMP/prefix" A B

# ------------------------------------------------- 1. the current script: clean
for tag in A B; do
    drive_ok "current script" "$TMP/fixed" "$tag"
    grep -q '^skipped:' "$TMP/fixed/out-$tag.txt" && fail "run $tag skipped instead of running"
    state_paths "$TMP/fixed" "$tag" > "$TMP/fixed/paths-$tag.txt"
    n="$(wc -l < "$TMP/fixed/paths-$tag.txt")"
    [ "$n" -ge 3 ] || { sed -e 's/^/     /' "$TMP/fixed/paths-$tag.txt" >&2
        fail "run $tag named only $n per-run state paths; the harness did not reach the disk, the serial log and the QEMU stderr"; }
    echo "     run $tag: exit $(cat "$TMP/fixed/rc-$tag"), $n state paths, serial $(serial_path "$TMP/fixed" "$tag")"
    sed -e "s/^/     $tag: /" "$TMP/fixed/paths-$tag.txt"
done
pass "the harness drives the current script to its own QEMU launch in both runs"
SHARED="$(comm -12 "$TMP/fixed/paths-A.txt" "$TMP/fixed/paths-B.txt")"
[ -z "$SHARED" ] || { printf '%s\n' "$SHARED" | sed -e 's/^/     shared: /' >&2
    fail "two concurrent runs of the current script share per-run state paths (above)"; }
pass "no per-run state path is shared by the two concurrent runs"

SERIAL_A="$(serial_path "$TMP/fixed" A)"
SERIAL_B="$(serial_path "$TMP/fixed" B)"
[ -n "$SERIAL_A" ] && [ -n "$SERIAL_B" ] || fail "could not read both runs' serial log paths from the stub argv"
[ "$SERIAL_A" != "$SERIAL_B" ] || fail "both runs were told to write the same serial log: $SERIAL_A"
grep -qF "GUEST B" "$SERIAL_B" || fail "run B's own serial log ($SERIAL_B) does not hold run B's guest line"
grep -qF "GUEST B" "$SERIAL_A" && fail "run A's serial log contains run B's guest line: $SERIAL_A"
pass "each run's serial log holds only its own guest output"
grep -qF "$MILESTONE" "$SERIAL_A" && fail "run A matched the milestone in its own log although its guest wrote nothing"
RC_A="$(cat "$TMP/fixed/rc-A")"
[ "$RC_A" != 0 ] || fail "run A reported PASS although its own guest never booted (exit $RC_A)"
pass "run A, whose guest wrote nothing, did not pass (exit $RC_A)"

# ------------------------------- 2. the pre-fix revision: the required false PASS
if [ "$HAVE_PRE_FIX" = 1 ]; then
    for tag in A B; do
        drive_ok "$PRE_FIX_REV" "$TMP/prefix" "$tag"
        state_paths "$TMP/prefix" "$tag" > "$TMP/prefix/paths-$tag.txt"
    done
    COLLIDED="$(comm -12 "$TMP/prefix/paths-A.txt" "$TMP/prefix/paths-B.txt")"
    [ -n "$COLLIDED" ] || fail "the two runs of $PRE_FIX_REV shared no per-run state path:
  the harness is not discriminating and would not have caught this defect"
    printf '%s\n' "$COLLIDED" | sed -e 's/^/     shared at '"$PRE_FIX_REV"': /'
    pass "the two runs of $PRE_FIX_REV ($(printf '%s\n' "$COLLIDED" | wc -l) paths) collide, as the defect requires"
    PSERIAL_A="$(serial_path "$TMP/prefix" A)"
    PSERIAL_B="$(serial_path "$TMP/prefix" B)"
    [ -n "$PSERIAL_A" ] && [ "$PSERIAL_A" = "$PSERIAL_B" ] \
        || fail "$PRE_FIX_REV: the two runs' serial logs differ ($PSERIAL_A vs $PSERIAL_B); the shared-log defect is not reproduced"
    grep -qF "GUEST B" "$PSERIAL_A" \
        || fail "$PRE_FIX_REV: run B's guest line is not in the log run A greps ($PSERIAL_A)"
    PRC_A="$(cat "$TMP/prefix/rc-A")"
    [ "$PRC_A" = 0 ] \
        || fail "$PRE_FIX_REV: run A (whose own guest wrote nothing) exited $PRC_A, not a false PASS;
  the harness is not reproducing the defect"
    echo "     $PRE_FIX_REV run A exit 0 having matched run B's $(grep -oF "$MILESTONE" "$PSERIAL_A" | head -1)"
    pass "$PRE_FIX_REV run A false-PASSes on run B's guest line in the shared $PSERIAL_A"
else
    echo "skipped: $PRE_FIX_REV:scripts/test/boot-test.sh is not in this clone"
    echo "         (shallow or rewritten history); the current script is still"
    echo "         checked, but the harness is not shown discriminating"
fi

# --------------- 3. --state-dir is honoured exactly, on both revisions
# The escape hatch must be the old behaviour byte for byte, so an explicit dir
# must yield the same path set (relative to it) before and after the fix.
launch_sd() {
    ( cd "$1/tree" && env PATH="$1/bin:$PATH" \
        FAKE_CMD_LOG="$1/cmds-$2.log" FAKE_RUN_TAG="$2" \
        FAKE_RV_DIR="$1/rv" FAKE_MILESTONE="$MILESTONE" \
        FAKE_GUEST_WRITES=1 FAKE_RV_PEERS="$2" ZD_BOOT_TEST_KEEP_RUN_DIR=1 \
        ./scripts/test/boot-test.sh --no-build --state-dir "$3" > "$1/out-$2.txt" 2>&1
      echo $? > "$1/rc-$2" ) &
    LAUNCHED_PIDS="$LAUNCHED_PIDS $!"
}

prepare "$TMP/sd"
stage "$TMP/sd" "$SCRIPT"
mkdir -p "$TMP/sd/state"
launch_sd "$TMP/sd" F "$TMP/sd/state"
reap "--state-dir (current)" "$TMP/sd" F
grep -q 'PASS — reached' "$TMP/sd/out-F.txt" || { cat "$TMP/sd/out-F.txt" >&2
    fail "the --state-dir run of the current script did not reach its PASS"; }
[ "$(serial_path "$TMP/sd" F)" = "$TMP/sd/state/serial.log" ] \
    || fail "the current script ignored --state-dir: serial log is $(serial_path "$TMP/sd" F), not $TMP/sd/state/serial.log"
state_paths_under "$TMP/sd" F "$TMP/sd/state" | sed -e "s#^$TMP/sd/state#.#" > "$TMP/sd/rel.txt"
[ "$(wc -l < "$TMP/sd/rel.txt")" -ge 3 ] || fail "the current --state-dir run named too few state paths"
echo "     --state-dir (current): $(tr '\n' ' ' < "$TMP/sd/rel.txt")"
HAVE_SD_COMPARE=0
if [ "$HAVE_PRE_FIX" = 1 ]; then
    cp "$TMP/prefix/tree/scripts/test/boot-test.sh" "$TMP/sd/tree/scripts/test/boot-test.sh" \
        || fail "could not stage $PRE_FIX_REV for the --state-dir check"
    mkdir -p "$TMP/sd/state2"
    launch_sd "$TMP/sd" R "$TMP/sd/state2"
    reap "--state-dir ($PRE_FIX_REV)" "$TMP/sd" R
    grep -q 'PASS — reached' "$TMP/sd/out-R.txt" || { cat "$TMP/sd/out-R.txt" >&2
        fail "the --state-dir run of $PRE_FIX_REV did not reach its PASS"; }
    state_paths_under "$TMP/sd" R "$TMP/sd/state2" | sed -e "s#^$TMP/sd/state2#.#" > "$TMP/sd/rel-prefix.txt"
    echo "     --state-dir ($PRE_FIX_REV): $(tr '\n' ' ' < "$TMP/sd/rel-prefix.txt")"
    diff -u "$TMP/sd/rel-prefix.txt" "$TMP/sd/rel.txt" >&2 \
        || fail "--state-dir behaviour changed: the path set under an explicit --state-dir differs from $PRE_FIX_REV (above)"
    HAVE_SD_COMPARE=1
fi
if [ "$HAVE_SD_COMPARE" = 1 ]; then
    pass "--state-dir is honoured exactly, as at $PRE_FIX_REV"
else
    pass "--state-dir is honoured exactly (no $PRE_FIX_REV clone to compare against)"
fi

# --------------------------- 4. the per-run dir lifecycle, measured on the fix
# A successful run removes only the per-run disk (1919.5 MiB apparent, 418 MiB
# allocated); the small logs it just named stay.  A failed run keeps everything.
# The pairs above ran with KEEP=1; these solo runs do not.
prepare "$TMP/life"
stage "$TMP/life" "$SCRIPT"
launch "$TMP/life" P 1 P ""
launch "$TMP/life" F 0 F ""
reap "lifecycle runs" "$TMP/life" P F
for tag in P F; do drive_ok "lifecycle run $tag" "$TMP/life" "$tag"; done
PDIR="$(dirname "$(serial_path "$TMP/life" P)")"
FDIR="$(dirname "$(serial_path "$TMP/life" F)")"
[ -n "$PDIR" ] && [ "$PDIR" != "." ] || fail "could not read the passing run's state dir from the stub argv"
[ -n "$FDIR" ] && [ "$FDIR" != "." ] || fail "could not read the failing run's state dir from the stub argv"
# The passing run: PASS line named <dir>/serial.log, and that file must survive.
grep -q 'PASS — reached' "$TMP/life/out-P.txt" || { cat "$TMP/life/out-P.txt" >&2
    fail "the lifecycle PASS run did not pass"; }
[ "$(cat "$TMP/life/rc-P")" = 0 ] || fail "the lifecycle PASS run exited $(cat "$TMP/life/rc-P"), not 0"
grep -qF "serial log: $PDIR/serial.log" "$TMP/life/out-P.txt" \
    || fail "the PASS run did not print its serial log path ($PDIR/serial.log)"
[ -f "$PDIR/serial.log" ] || fail "the PASS run printed $PDIR/serial.log and then removed it"
[ ! -e "$PDIR/synthetic-cf.img" ] || fail "a successful run kept its per-run disk: $PDIR/synthetic-cf.img"
pass "a successful run keeps its serial log and removes its disk ($PDIR)"
# The failing run keeps the disk as evidence.
[ "$(cat "$TMP/life/rc-F")" != 0 ] || fail "the lifecycle FAIL run exited 0"
[ -f "$FDIR/serial.log" ] || fail "a failed run lost its serial log: $FDIR/serial.log"
[ -e "$FDIR/synthetic-cf.img" ] || fail "a failed run lost its disk, leaving nothing to inspect: $FDIR/synthetic-cf.img"
pass "a failed run keeps its disk and its serial log ($FDIR)"

echo
echo "all boot-test run-scope tests passed"
