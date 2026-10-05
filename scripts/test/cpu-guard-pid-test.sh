#!/usr/bin/env bash
#
# cpu-guard-pid-test.sh — the CPU supervisor must work on the emulator, not on
# the launcher the entrypoint starts.
#
# entrypoint.sh starts launch-vm.sh (=$qemu_pid), which runs qemu-once.py, which
# runs qemu-system-i386.  /proc/<pid>/stat's utime+stime count a process's own
# CPU time and exclude its children, so sampling $qemu_pid reads ~0% however
# hard QEMU works, and the ZD_CPU_GUARD watchdog could never fire.  qemu-once.py
# now publishes the emulator's pid in $ZD_QEMU_PID_FILE and the guard samples
# that.  CPU_LIMIT, which capped the same wrong process, is gone: a stale setting
# must still be reported and must cap nothing.
#
# This checks the plumbing behaviourally: the file is published and removed, the
# reader trusts only a live emulator (not a recycled pid), the sampling
# arithmetic reports the emulator's CPU where the wrapper's reads 0%, and the
# guard loop is wired to the pid file rather than to the wrapper.
#
# It also covers the two things that keep the guard honest now: the trip is armed
# only for a KVM-accelerated guest (under TCG a healthy boot crosses 95% of its
# own accord, so arming there can only cost a boot -- see entrypoint.sh's arming
# block, whose older justification was the vendor integrity storm), and every
# guest launch leaves one greppable accounting line, so "has this backstop ever
# been needed?" is answerable from the archived console log alone.
#
# Usage: ./scripts/test/cpu-guard-pid-test.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../container" && pwd)"
ENTRYPOINT="$BASE/entrypoint.sh"
QEMU_ONCE="$BASE/qemu-once.py"


. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-cpupid.XXXXXX")"
# qemu-once.py binds its QMP socket under tempfile.gettempdir(), and a long
# TMPDIR overflows sun_path, so the emulator gets its own short directory.
SOCK_DIR="$(short_sock_dir)"
pids=()
cleanup() {
    if (( ${#pids[@]} )); then
        kill -KILL "${pids[@]}" 2>/dev/null || true
    fi
    rm -rf "$TMP" "$SOCK_DIR"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }
skip() { printf 'skipped: %s\n' "$*"; exit 0; }

[ -f "$ENTRYPOINT" ] || fail "not found: $ENTRYPOINT"
[ -f "$QEMU_ONCE" ] || fail "not found: $QEMU_ONCE"

clock_ticks="$(getconf CLK_TCK)"
ticks() { awk '{print $14 + $15}' "/proc/$1/stat" 2>/dev/null || echo 0; }

# Poll a condition until it holds, or the budget runs out.  Every wait in this
# test is for a condition rather than a fixed sleep: a fixed sleep is what makes
# a test flaky on a loaded machine, and this suite runs on one.
wait_for() { # $1 = seconds, $2 = what we are waiting for, rest = the condition
    local seconds="$1" label="$2"
    shift 2
    local deadline=$((SECONDS + seconds))
    until "$@"; do
        if (( SECONDS >= deadline )); then
            echo "     (waited ${seconds}s for $label)" >&2
            return 1
        fi
        sleep 0.1
    done
}
has_cmdline() { # $1 = pid, $2 = substring of its cmdline
    case "$(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null)" in
        *"$2"*) return 0 ;;
        *) return 1 ;;
    esac
}
reader_names() { [ "$(read_emulator_pid || true)" = "$1" ]; }
reader_ready() { # sets published_pid when the reader answers
    published_pid="$(read_emulator_pid || true)"
    [ -n "$published_pid" ]
}
start_busy() { # $1 = the argv[0] the process wears; sets busy_pid
    bash -c "exec -a $1 python3 -c 'while True: pass'" &
    busy_pid=$!
    # A forked-but-not-yet-exec'd child still carries its parent's cmdline, so
    # wait for the exec: nothing else here is meaningful before it.
    wait_for 5 "pid $busy_pid to exec as $1" has_cmdline "$busy_pid" "$1" \
        || fail "the busy stand-in for '$1' never started"
}
cpu_percent() { # $1 = pid, $2 = seconds
    local before after
    before="$(ticks "$1")"
    sleep "$2"
    after="$(ticks "$1")"
    printf '%s' "$(( (after - before) * 100 / clock_ticks / $2 ))"
}

# --- 1. the guard's reader only trusts a live emulator -----------------------
# entrypoint.sh cannot be sourced (it builds disks and starts QEMU), so lift the
# reader out of it; the pid file path is the variable it reads.
sed -n '/^read_emulator_pid() {/,/^}/p' "$ENTRYPOINT" > "$TMP/reader.sh"
grep -q '^read_emulator_pid()' "$TMP/reader.sh" || fail "read_emulator_pid() not found in $ENTRYPOINT"
qemu_pid_file="$TMP/reader.pid"
# shellcheck source=/dev/null
. "$TMP/reader.sh"

read_emulator_pid >/dev/null 2>&1 && fail "a missing pid file must yield no pid"
pass "a missing pid file yields no pid"

printf 'not-a-pid\n' > "$qemu_pid_file"
read_emulator_pid >/dev/null 2>&1 && fail "unparsable content must yield no pid"
printf '999999999\n' > "$qemu_pid_file"
read_emulator_pid >/dev/null 2>&1 && fail "a pid that is not running must yield no pid"
pass "garbage and dead pids yield no pid"

# A live process that is not the emulator is what a recycled pid looks like: it
# must be rejected, or the guard would sample an unrelated process.
sleep 60 &
recycled=$!
pids+=("$recycled")
printf '%s\n' "$recycled" > "$qemu_pid_file"
read_emulator_pid >/dev/null 2>&1 && fail "a recycled pid ($recycled, not qemu) must yield no pid"
pass "a live pid that is not a qemu-system process yields no pid"

# An emulator-shaped descendant: saturated, with argv[0] qemu-system-i386,
# which is what qemu-once.py publishes.
start_busy qemu-system-i386
emulator="$busy_pid"
pids+=("$emulator")
printf '%s\n' "$emulator" > "$qemu_pid_file"
wait_for 5 "the reader to accept emulator pid $emulator" reader_names "$emulator" \
    || fail "a live emulator pid must be returned"
pass "a live emulator pid is returned"

# --- 2. the published pid is the process that burns the CPU ------------------
# The wrapper stands in for launch-vm.sh and qemu-once.py: it owns no CPU while
# its descendant saturates a core, and it publishes that descendant's pid in the
# format qemu-once.py writes.
cat > "$TMP/wrapper.py" <<'PY'
import subprocess
import sys
import time

child = subprocess.Popen(
    ["bash", "-c", 'exec -a qemu-system-i386 python3 -c "while True: pass"'],
    close_fds=False,
)
with open(sys.argv[1], "w") as f:
    f.write(f"{child.pid}\n")
time.sleep(30)
child.kill()
PY

qemu_pid_file="$TMP/sample.pid"
python3 "$TMP/wrapper.py" "$qemu_pid_file" &
wrapper=$!
pids+=("$wrapper")
wait_for 5 "the wrapper to publish a pid" test -s "$qemu_pid_file" \
    || fail "the wrapper never published a pid"
# The wrapper writes the pid straight after Popen, so the reader may briefly see
# a child that has not exec'd yet; wait for it to answer rather than racing it.
wait_for 5 "the reader to accept the published pid" reader_ready \
    || fail "the reader rejected the published pid"
sample_pid="$published_pid"
pids+=("$sample_pid")

wrapper_cpu="$(cpu_percent "$wrapper" 2)"
sample_cpu="$(cpu_percent "$sample_pid" 2)"
printf '     wrapper pid %s: %s%% CPU   published emulator pid %s: %s%% CPU\n' \
    "$wrapper" "$wrapper_cpu" "$sample_pid" "$sample_cpu"
(( wrapper_cpu <= 20 )) || fail "the wrapper should sit at ~0% CPU, measured ${wrapper_cpu}%"
(( sample_cpu >= 80 )) || fail "the published pid should be saturated, measured ${sample_cpu}%"
pass "sampling the published pid reports the emulator's CPU, not the wrapper's"

kill -KILL "$sample_pid" "$wrapper" 2>/dev/null || true
wait "$wrapper" 2>/dev/null || true

# --- 3. qemu-once.py publishes a real emulator pid, and removes it ----------
command -v qemu-system-i386 >/dev/null 2>&1 || skip "qemu-system-i386 is not installed"
qemu_pid_file="$TMP/real.pid"
TMPDIR="$SOCK_DIR" ZD_QEMU_PID_FILE="$qemu_pid_file" python3 "$QEMU_ONCE" -machine none -display none \
    >"$TMP/qemu-once.log" 2>&1 &
once_pid=$!
pids+=("$once_pid")
wait_for 10 "qemu-once.py to publish $qemu_pid_file" test -s "$qemu_pid_file" \
    || { cat "$TMP/qemu-once.log" >&2; fail "qemu-once.py did not publish $qemu_pid_file"; }
real_pid="$(cat "$qemu_pid_file")"
pids+=("$real_pid")
[[ "$real_pid" =~ ^[0-9]+$ ]] || fail "the published pid is not a number: $real_pid"
kill -0 "$real_pid" 2>/dev/null || fail "the published pid $real_pid is not running"
has_cmdline "$real_pid" qemu-system- || fail "the published pid $real_pid is not the emulator"
# The file is written straight after Popen, so the reader may briefly see QEMU
# before it has exec'd; wait for it to answer rather than racing it.
wait_for 5 "the reader to accept the real emulator pid" reader_names "$real_pid" \
    || fail "the entrypoint's reader rejected the real published pid"
pass "qemu-once.py published the live emulator pid $real_pid"

# QEMU must reach its QMP handshake before it is pulled down: a QEMU that never
# connected is only noticed when qemu-once.py's accept() times out (120s), and
# the pid file legitimately lives until then.  The handshake shows up as a
# second /proc/net/unix entry for qemu-once.py's own socket path.
qmp_connected() {
    [ "$(grep -c "zd1200-qmp.$once_pid.sock" /proc/net/unix 2>/dev/null || true)" -ge 2 ]
}
wait_for 10 "QEMU to reach qemu-once.py's QMP handshake" qmp_connected \
    || fail "QEMU $real_pid never reached qemu-once.py's QMP handshake"

# Whatever the pid file is doing, the reader must never hand out a pid that is
# not a live emulator.  That invariant is what makes the removal window below
# harmless, so it is asserted across the window rather than at one instant.
kill -KILL "$real_pid" 2>/dev/null || true
for _ in $(seq 1 30); do
    got="$(read_emulator_pid || true)"
    if [ -n "$got" ]; then
        kill -0 "$got" 2>/dev/null || fail "the reader returned the dead pid $got"
        has_cmdline "$got" qemu-system- || fail "the reader returned pid $got, which is not the emulator"
    fi
    sleep 0.05
done

# QEMU exiting (what a guest reset does) must take the file with it: a stale
# file naming a dead pid must never read as a live emulator.  Poll for it --
# qemu-once.py unlinks the file after reaping QEMU, and a loaded machine widens
# that window -- but a file that is genuinely never removed still fails here.
if ! wait_for 10 "the pid file to be removed" test ! -e "$qemu_pid_file"; then
    echo "--- qemu-once.py log ---" >&2
    cat "$TMP/qemu-once.log" >&2
    fail "$qemu_pid_file still exists 10s after the emulator was killed"
fi
read_emulator_pid >/dev/null 2>&1 && fail "the reader still yields a pid after QEMU exited"
pass "the pid file is removed when the emulator exits"

# --- 4. CPU_LIMIT is gone, and a stale setting is loud and inert ------------
# The knob used to duty-cycle the CPU: at its call site it throttled the
# launch-vm.sh wrapper, which owns none of QEMU's CPU.  It is removed, but an
# operator may still carry CPU_LIMIT in /etc/zd1200.conf, so the entrypoint must
# report it once and act on none of it.  entrypoint.sh cannot be sourced (it
# builds disks and starts QEMU), so lift the compatibility block out and run it.
awk '/^if \[ -n "\$\{CPU_LIMIT:-\}" \]; then$/,/^fi$/' "$ENTRYPOINT" > "$TMP/cpu-limit-block.sh"
grep -q 'CPU_LIMIT is set but no longer supported' "$TMP/cpu-limit-block.sh" \
    || fail "no CPU_LIMIT compatibility warning found in $ENTRYPOINT"

# A canary at full tilt, to show nothing throttles it while the block runs.
start_busy python3
canary="$busy_pid"
pids+=("$canary")
canary_before="$(cpu_percent "$canary" 1)"
# jobs -p makes the block's spawned background jobs observable: there must be
# none, which is the behavioural half of "no limiter is started any more".
CPU_LIMIT=50 bash -c '. "$1"; jobs -p' _ "$TMP/cpu-limit-block.sh" \
    >"$TMP/cpu-limit.out" 2>"$TMP/cpu-limit.err" || cpu_limit_rc=$?
cpu_limit_rc="${cpu_limit_rc:-0}"
canary_after="$(cpu_percent "$canary" 1)"
kill -KILL "$canary" 2>/dev/null || true

[ "$cpu_limit_rc" = 0 ] || { cat "$TMP/cpu-limit.err" >&2; fail "a stale CPU_LIMIT must not fail the entrypoint (exit $cpu_limit_rc)"; }
[ "$(grep -c 'CPU_LIMIT' "$TMP/cpu-limit.err")" = 1 ] \
    || { cat "$TMP/cpu-limit.err" >&2; fail "a stale CPU_LIMIT must be reported exactly once, on stderr"; }
[ -s "$TMP/cpu-limit.out" ] && { cat "$TMP/cpu-limit.out" >&2; fail "the CPU_LIMIT block started a background job"; }
pgrep -f 'limit-process-cp[u]' >/dev/null 2>&1 && fail "a CPU limiter is running"
(( canary_before >= 80 )) || fail "the canary was not saturated before the block (${canary_before}%)"
(( canary_after >= 80 )) || fail "a stale CPU_LIMIT throttled the canary (${canary_after}%)"
pass "a stale CPU_LIMIT is warned about once, starts nothing, and throttles nothing (${canary_before}% -> ${canary_after}%)"

# The only non-comment use of CPU_LIMIT left in the entrypoint is that warning.
code_refs="$(grep -nE 'CPU_LIMIT' "$ENTRYPOINT" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
[ "$(printf '%s' "$code_refs" | grep -c 'CPU_LIMIT')" = 2 ] \
    || { printf '%s\n' "$code_refs" >&2; fail "CPU_LIMIT is still used in code outside the compatibility warning"; }
pass "CPU_LIMIT survives only as the compatibility warning"

# --- 5. the supervisor is wired to the pid file -----------------------------
# The guard loop needs the whole entrypoint around it, so assert on its own
# lines: sampling /proc/$qemu_pid/stat is the defect.
awk '/^clock_ticks="\$\(getconf CLK_TCK\)"$/,/exit 3/' "$ENTRYPOINT" > "$TMP/guard.txt"
grep -q 'read_emulator_pid' "$TMP/guard.txt" || fail "the guard loop does not read the emulator pid file"
grep -q '/proc/\$qemu_pid/stat' "$TMP/guard.txt" && fail "the guard loop still samples the wrapper's /proc stat"
grep -q 'ZD_QEMU_PID_FILE="\$qemu_pid_file"' "$ENTRYPOINT" || fail "the launcher is not given the pid file path"
# Only code counts here: the entrypoint keeps a comment naming the removed
# limiter as part of the record of why it is gone.
if grep -nE 'limit-process-cpu|limiter_pid' "$ENTRYPOINT" | grep -vE '^[0-9]+:[[:space:]]*#' > "$TMP/limiter-refs.txt"; then
    cat "$TMP/limiter-refs.txt" >&2
    fail "the entrypoint still launches a CPU limiter"
fi
pass "the guard works from the emulator pid, and no limiter is launched"

# --- 6. ZD_CPU_GUARD did not change ----------------------------------------
grep -q 'cpu_guard="${ZD_CPU_GUARD:-4}"' "$ENTRYPOINT" || fail "ZD_CPU_GUARD's default changed"
pass "ZD_CPU_GUARD still defaults to 4"

# --- 7. the trip is armed only for a KVM guest ------------------------------
# The >=95% metric only discriminates where the guest can both run fast and still
# saturate: a KVM guest of this appliance settles near 50% of a core, so 95%
# there is abnormal, while a TCG emulator holding a full core is in its normal
# steady state.  entrypoint.sh cannot be sourced, so lift the arming block out
# and run it in a subshell.  vm_accel and cpu_guard are set for real, so this exercises the
# decision the entrypoint actually makes rather than a copy of it.
awk 'f && index($0, "echo \"ZD1200 is starting; waiting for the web service") == 1 { exit }
     index($0, "case \"$cpu_guard\" in") == 1 { f = 1 }
     f { print }' "$ENTRYPOINT" > "$TMP/arm.txt"
grep -q '^cpu_guard_armed=0$' "$TMP/arm.txt" \
    || fail "could not lift the ZD_CPU_GUARD arming block out of $ENTRYPOINT"
grep -q '^fi$' "$TMP/arm.txt" \
    || fail "the lifted ZD_CPU_GUARD arming block is truncated"

# arm_accel <accel> <ZD_CPU_GUARD> -- source the block with those settings and
# print "rc=<rc> armed=<cpu_guard_armed>"; its stderr is left in $TMP/arm.err for
# the caller, and $TMP/arm.out holds the armed line on its own.
arm_accel() {
    local accel="$1" guard="$2" rc=0
    (
        set -euo pipefail
        vm_accel="$accel"
        cpu_guard="$guard"
        # shellcheck source=/dev/null
        . "$TMP/arm.txt"
        printf 'armed=%s\n' "${cpu_guard_armed:-unset}"
    ) >"$TMP/arm.out" 2>"$TMP/arm.err" || rc=$?
    printf 'rc=%s %s' "$rc" "$(cat "$TMP/arm.out")"
}

# A KVM guest keeps the trip, and says what it will do.  The armed message has
# always gone to stdout, so it is the stdout half that carries it; only the "not
# armed" explanation is a stderr line.
arm_accel kvm 24 >"$TMP/arm.kvm"
grep -q 'armed=1' "$TMP/arm.kvm" \
    || { cat "$TMP/arm.err" >&2; fail "the trip is not armed for a KVM guest ($(cat "$TMP/arm.kvm"))"; }
grep -q 'stopping QEMU after 24 samples' "$TMP/arm.kvm" \
    || { cat "$TMP/arm.kvm" >&2; fail "an armed guard no longer says it will stop QEMU"; }
pass "a KVM guest arms the trip at 24 samples"

# A TCG guest must not arm it, and must say why exactly once, naming the docs
# section that holds the figures.
arm_accel tcg 24 >"$TMP/arm.tcg"
grep -q 'armed=0' "$TMP/arm.tcg" \
    || { cat "$TMP/arm.err" >&2; fail "the trip is armed for a TCG guest ($(cat "$TMP/arm.tcg"))"; }
[ "$(wc -l < "$TMP/arm.err")" = 1 ] \
    || { cat "$TMP/arm.err" >&2; fail "a TCG guest must get exactly one explanatory line, got $(wc -l < "$TMP/arm.err")"; }
grep -q 'TCG' "$TMP/arm.err" || fail "the TCG explanation does not name TCG"
grep -q '"CPU guard" in docs/TROUBLESHOOTING.md' "$TMP/arm.err" \
    || fail "the TCG explanation does not point at the docs section"
# ...and the section it names has to exist, or the pointer is worse than none.
grep -qE '^## CPU guard \(`ZD_CPU_GUARD`\)$' "$BASE/../../docs/TROUBLESHOOTING.md" \
    || fail "the docs section the TCG explanation names does not exist"
pass "a TCG guest leaves the trip unarmed, with one line naming the docs"

# Disabled stays disabled, with no chatter, on either accelerator.
for guard in 0 off none; do
    for accel in kvm tcg; do
        arm_accel "$accel" "$guard" >"$TMP/arm.off"
        grep -q 'armed=0' "$TMP/arm.off" \
            || { cat "$TMP/arm.err" >&2; fail "ZD_CPU_GUARD=$guard with vm_accel=$accel armed the trip"; }
        if [ -s "$TMP/arm.err" ]; then
            cat "$TMP/arm.err" >&2
            fail "ZD_CPU_GUARD=$guard with vm_accel=$accel printed something"
        fi
    done
done
pass "ZD_CPU_GUARD=0/off/none keeps the guard off under KVM and TCG alike"

# An unusable value is still refused whichever the accelerator.
arm_accel tcg bogus >"$TMP/arm.bad"
grep -q 'rc=2' "$TMP/arm.bad" \
    || { cat "$TMP/arm.err" >&2; fail "ZD_CPU_GUARD=bogus must exit 2 (got $(cat "$TMP/arm.bad"))"; }
pass "an unusable ZD_CPU_GUARD is still refused under TCG"

# --- 8. the trip honours that decision, and every launch is accounted for ----
# A wider lift than section 5's: from the supervisor's first line to the exit-status
# handling, so the accounting line after the loop is inside it too.
awk 'f && index($0, "qemu_rc=0") == 1 { exit }
     index($0, "clock_ticks=\"$(getconf CLK_TCK)\"") == 1 { f = 1 }
     f { print }' "$ENTRYPOINT" > "$TMP/supervisor.txt"
grep -qE '^[[:space:]]*exit 3$' "$TMP/supervisor.txt" || fail "the supervisor fragment has no trip"

# The block test above shows the decision is made; this shows the loop consults
# it.  Arming a variable the trip ignores would pass the first and still stop a
# TCG guest, so the exact gate is pinned.
grep -q '\[ "\$cpu_guard_armed" = 1 \] && (( high_cpu_samples >= cpu_guard ))' "$TMP/supervisor.txt" \
    || fail "the trip is not gated on cpu_guard_armed inside the guard loop"

# The record line is the only way to answer "has this backstop ever been needed?"
# from the archived console log, so its content is asserted from the function's
# own output rather than from a grep of the source.  Lift the counters and the
# two functions (up to the loop's own variables) and run them.
awk 'f && index($0, "sample_pid=\"\"") == 1 { exit }
     index($0, "guard_peak_cpu=-1") == 1 { f = 1 }
     f { print }' "$ENTRYPOINT" > "$TMP/record.txt"
grep -q '^cpu_guard_record() {' "$TMP/record.txt" \
    || fail "could not lift cpu_guard_record() out of $ENTRYPOINT"
grep -q '^cpu_guard_reset() {' "$TMP/record.txt" \
    || fail "could not lift cpu_guard_reset() out of $ENTRYPOINT"

# record_line <accel> <armed> <cpu_guard> [samples] -- stand the counters where a
# launch would have left them and print what cpu_guard_record() writes for pid
# 4242.
record_line() {
    local accel="$1" armed="$2" guard="$3" samples="${4:-82}"
    (
        set -euo pipefail
        vm_accel="$accel"
        cpu_guard_armed="$armed"
        cpu_guard="$guard"
        # shellcheck source=/dev/null
        . "$TMP/record.txt"
        guard_samples="$samples"
        if (( samples > 0 )); then
            guard_peak_cpu=101
            guard_samples_high="$samples"
            guard_longest_run="$samples"
            guard_would_trip=1
            guard_trips=0
        fi
        cpu_guard_record 4242
    )
}

want='High-CPU watchdog record: accel=tcg armed=no emulator_pid=4242 samples=82 peak=101% longest_run=82 samples (410s) samples_above_95=82 would_have_tripped=1 trips=0'
got="$(record_line tcg 0 24)"
[ "$got" = "$want" ] \
    || { printf 'got:  %s\nwant: %s\n' "$got" "$want" >&2; fail "the accounting line changed"; }
pass "the accounting line reports peak, longest run, and trip counts"

# With the guard disabled there is no threshold, so the would-have-fired count
# must read as inapplicable rather than as a zero that looks like a measurement.
got="$(record_line tcg 0 "")"
case "$got" in
    *'armed=no'*'would_have_tripped=n/a'*) ;;
    *) fail "a disabled guard must report would_have_tripped=n/a: $got" ;;
esac
pass "a disabled guard reports the would-have-fired count as inapplicable"

# A launch that was never sampled gets no line: the record means "this launch was
# measured", so an unmeasured one must not invent one.
got="$(record_line tcg 0 24 0)"
[ -z "$got" ] || fail "a launch with no samples must not emit a record: $got"
pass "no record is emitted for a launch that was never sampled"

# And one line per launch: the line must be written when the sampled pid changes
# (a relaunch) and when the supervisor loop ends -- and before the trip's exit,
# which would otherwise leave the firing launch unaccounted for.
awk '
  index($0, "cpu_guard_record \"$sample_pid\"") > 0 { calls[++n] = NR }
  /^[[:space:]]*exit 3$/ { trip = NR }
  /^done$/ { last_done = NR }
  END {
    before = 0; after = 0
    for (i = 1; i <= n; i++) {
      if (calls[i] < trip) before++
      if (calls[i] > last_done) after++
    }
    exit !(before >= 1 && n >= 2 && after >= 1)
  }' "$TMP/supervisor.txt" \
    || fail "the guard loop does not emit the accounting line both on a relaunch and for the final launch"
pass "the guard loop emits an accounting line per guest launch, trips included"

# --- 9. the record survives an abrupt stop, and is visible mid-run ------------
# The post-loop line alone does not survive a normal container stop: the outer
# SIGTERM is followed by SIGKILL once the runtime's stop timeout expires, and
# cleanup() can be inside its graceful guest-shutdown wait for ZD_STOP_TIMEOUT
# (240s by default) when that lands.  Under TCG, where the trip is unarmed, the
# record is the only signal that the guard would have fired at all, so the line
# must also be written while the launch is still being sampled.
awk 'f && index($0, "done") == 1 { print; exit }
     index($0, "while kill -0 \"$qemu_pid\"") == 1 { f = 1 }
     f { print }' "$ENTRYPOINT" > "$TMP/loop.txt"
grep -q '^while kill -0 "\$qemu_pid"' "$TMP/loop.txt" \
    || fail "could not lift the guard loop out of $ENTRYPOINT"
grep -q 'guard_samples % guard_record_every == 0' "$TMP/loop.txt" \
    || fail "the guard loop never records a launch that is still running"
grep -q 'cpu_guard_record_current' "$TMP/loop.txt" \
    || fail "the mid-launch record does not write the accounting line"
# A line names an emulator, and the loop samples the launch-vm.sh wrapper when no
# live emulator pid can be read.  Both existing emission points skip that
# fallback, so the mid-launch record must too rather than claim its pid as the
# emulator's.
grep -q '\[ "\$sampled_emulator" = 1 \] || return 0' "$TMP/supervisor.txt" \
    || fail "the mid-launch record can name the wrapper fallback as the emulator"
# The interval bounds how much of a launch an abrupt stop can lose, so its value
# is pinned rather than left to drift.  The periodic path calls the function
# section 8 already runs unarmed, so an unarmed launch records the same line.
grep -q '^guard_record_every=60$' "$ENTRYPOINT" \
    || fail "the mid-launch record interval changed (60 samples ~ 5 minutes)"
pass "the guard records a running launch every 60 samples (~5 minutes)"

# The TERM handler is the exact fix for the ordinary stop rather than a 5-minute
# bound on it: it must record before cleanup()'s long wait, then run the same
# cleanup-and-exit the trap at the top of the script does.  The entrypoint's own
# EXIT trap must stay as it is.
grep -qF "trap 'cpu_guard_record_current \"\$sample_pid\" || true; cleanup 1; exit 0' INT TERM" "$TMP/supervisor.txt" \
    || fail "the TERM handler does not record the launch before cleanup runs"
grep -q "^trap 'cleanup 0' EXIT\$" "$ENTRYPOINT" \
    || fail "the entrypoint's EXIT trap changed"
pass "a TERM records the launch first, then runs the unchanged cleanup"

echo
echo "all CPU-guard pid-file tests passed"
