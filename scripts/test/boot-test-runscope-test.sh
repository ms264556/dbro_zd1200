#!/usr/bin/env bash
#
# boot-test-runscope-test.sh — two concurrent runs of boot-test.sh must not share
# the per-run state directory, and so must not be able to read each other's
# serial log.
#
# Why this exists: boot-test.sh used to default its state dir to the fixed
# $repo/.boot-test, and everything landed there: the serial log, the QEMU stderr,
# the debugcon log, the console socket and the container bind mount.  Two
# concurrent runs wrote guest console output into one serial.log while each
# truncated it at start, and the milestone loop greps that one file.  A run could
# report `PASS - reached 'init'` on the other run's guest line, with its own guest
# never booted.  Each run now gets its own $repo/.boot-test/run.XXXXXX.
#
# This test runs offline, with no lab: the real script is executed twice,
# concurrently, against recording stub `docker` and `qemu-system-i386` on PATH.
# The stub docker answers `info`/`image inspect`, and for `run` it parses the
# `-v <state-dir>:/var/lib/zd1200` bind mount and creates
# <state-dir>/synthetic-cf.img, which is what the container's prepare-vm-disks.sh
# would have written.  Run B's stub qemu then writes one milestone line tagged
# with its own name into the serial log it was told to write; run A's writes
# nothing, so A is a guest that never booted.  The two stubs rendezvous after
# both scripts have launched them, i.e. after both have truncated their serial
# log, so neither truncation can erase the other's write.  The defaults are the
# script's own: --expect init, whose pattern is `/dev/sda4 on /writable type ext2`.
#
# The assertions:
#   1. the per-run `.boot-test` paths each run names are disjoint;
#   2. the two runs' -serial logfiles differ, and neither holds the other's tag;
#   3. run A, whose guest wrote nothing, does NOT pass;
#   4. an explicit --state-dir is honoured exactly;
#   5. a successful run removes its per-run disk but keeps the serial log it just
#      printed; a failed run keeps both; ZD_BOOT_TEST_KEEP_RUN_DIR=1 keeps the disk
#      on success too (the concurrent pairs run with it so their disks survive);
#   6. the discriminating half: a copy of the script with its per-run state dir
#      forced back to the shared $repo/.boot-test must give run A a FALSE PASS on
#      run B's line.  If it does not, the harness cannot detect the defect it
#      exists for and the test fails rather than claiming a pass.
#
# How far this drives the real script: `--no-build` skips the image build, and a
# run reaches argument parsing, the --reuse guard, the tooling skip checks, the
# state-dir setup, the stub `docker run` disk-prepare step, the disk and log
# setup, the QEMU launch and then its monitoring loop.  It does not boot a guest:
# the qemu stub writes one line and exits, so the run reaches its own milestone
# grep and its own PASS/FAIL decision.  `--reboot` is not driven; its console
# socket derives from the same state dir.  The container-side disk build is
# stubbed, so prepare-vm-disks.sh's own refuse-to-rebuild gate is not exercised.
#
# Usage: ./scripts/test/boot-test-runscope-test.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO/scripts/test/boot-test.sh"
# The milestone pattern for the script's default --expect init,
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
LAUNCHED_PIDS=""
# Run A's guest writes nothing; run B's writes the milestone line.  With a shared
# serial.log, A's milestone loop would match B's line.
for tag in A B; do
    case "$tag" in A) w=0 ;; B) w=1 ;; esac
    launch "$TMP/fixed" "$tag" "$w" "A B" 1
done
reap "current script" "$TMP/fixed" A B

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

# --------------- 3. --state-dir is honoured exactly
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
pass "--state-dir is honoured exactly"

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

# ------------- 6. the discriminating half: the shared state dir gives a false PASS
# A copy of the script whose per-run mktemp is replaced by the fixed
# $repo/.boot-test is the defect itself.  Run A's guest wrote nothing, so a PASS
# for run A can only come from matching run B's line in the one shared serial.log.
prepare "$TMP/shared"
stage "$TMP/shared" "$SCRIPT"
BOOT="$TMP/shared/tree/scripts/test/boot-test.sh"
[ "$(grep -c 'state_dir="$(mktemp -d "$repo/.boot-test/run.XXXXXX")" \\$' "$BOOT")" = 1 ] \
    || fail "boot-test.sh no longer has the per-run mktemp line; update this test's shared-state-dir mutation"
awk '/state_dir="\$\(mktemp -d "\$repo\/\.boot-test\/run\.XXXXXX"\)" \\$/ { print "  state_dir=\"$repo/.boot-test\""; skip = 1; next }
     skip { skip = 0; next }
     { print }' "$BOOT" > "$BOOT.new" && mv "$BOOT.new" "$BOOT" && chmod 755 "$BOOT"
grep -q '^  state_dir="$repo/.boot-test"$' "$BOOT" || fail "could not build the shared-state-dir copy of boot-test.sh"
LAUNCHED_PIDS=""
for tag in A B; do
    case "$tag" in A) w=0 ;; B) w=1 ;; esac
    launch "$TMP/shared" "$tag" "$w" "A B" 1
done
reap "shared-state-dir copy" "$TMP/shared" A B
for tag in A B; do drive_ok "shared-state-dir copy" "$TMP/shared" "$tag"; done
[ "$(serial_path "$TMP/shared" A)" = "$(serial_path "$TMP/shared" B)" ] \
    || fail "the shared-state-dir copy gave the two runs different serial logs: the mutation did not reproduce the defect"
[ "$(cat "$TMP/shared/rc-A")" = 0 ] \
    || { cat "$TMP/shared/out-A.txt" >&2
         fail "with a shared state dir run A did not falsely pass (exit $(cat "$TMP/shared/rc-A")): this harness cannot detect the defect it exists for"; }
pass "with the state dir forced shared, run A falsely passes on run B's line (the harness can fail)"

echo
echo "all boot-test run-scope tests passed"
