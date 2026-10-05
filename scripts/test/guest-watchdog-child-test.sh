#!/usr/bin/env bash
#
# guest-watchdog-child-test.sh — one flow, one guest watchdog.
#
# Why this exists: entrypoint.sh launches the guest watchdog as a supervised
# child.  That is how the DOCKER flow supervises it (the container has no
# systemd), but the LXC flow runs the same script as zd1200-watchdog.service, so
# without an explicit switch the LXC flow would run two copies: the child's L2
# lookup is the Docker flow's macvtap shape (ZD_WATCHDOG_LINK_KIND=macvtap,
# ZD_WATCHDOG_GUEST_LINK=mvt0) rather than the LXC flow's bridge (br-zd), and
# both copies write the same $STATE_FILE, so recovery would be duplicated and
# one of the two would be looking for the guest in the wrong place.
#
# This pins the switch from both ends:
#   * the entrypoint starts the child by default and does NOT start it when
#     ZD_GUEST_WATCHDOG_CHILD=0, while ZD_GUEST_WATCHDOG=0 still disables it;
#   * the LXC flow's /etc/zd1200.conf sets the key, and the flow really does
#     carry the systemd unit that supervises the watchdog instead.
#
# Fully offline: the "watchdog" is a stub script that records the environment
# the entrypoint handed it, so nothing here needs a container, QEMU or root.
#
# Usage: ./scripts/test/guest-watchdog-child-test.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENTRYPOINT="$REPO/scripts/container/entrypoint.sh"
BOOTSTRAP="$REPO/scripts/container/proxmox/zd1200-ct-bootstrap.sh"

pass() { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -r "$ENTRYPOINT" ] || fail "missing: $ENTRYPOINT"
[ -r "$BOOTSTRAP" ] || fail "missing: $BOOTSTRAP"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-wdchild.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/work" "$TMP/state"

# The launch block, lifted out of the entrypoint rather than re-typed here, so
# this test exercises the code that ships.  It opens with `watchdog_pid=""` at
# column 0 and closes with the first column-0 `fi` (the inner if/else/fi in the
# not-available branch is indented).
awk '/^watchdog_pid=""$/{f=1} f{print} f&&/^fi$/{exit}' "$ENTRYPOINT" > "$TMP/block.sh"
grep -q '^watchdog_pid=""$' "$TMP/block.sh" || fail "could not lift the watchdog launch block out of $ENTRYPOINT"
grep -q 'setsid env' "$TMP/block.sh" || fail "the lifted block is not the watchdog launch"
grep -c '^fi$' "$TMP/block.sh" | grep -qx 1 || fail "the lifted block is truncated (expected one column-0 fi)"

# The stub watchdog: records the environment the entrypoint gave it, then exits.
# STUB_RAN is the marker this test waits on; STUB_ENV carries the environment.
cat > "$TMP/work/zd1200-guest-watchdog" <<'STUB'
#!/usr/bin/env bash
printf 'stub-watchdog-started\n'
{
    printf 'ZD_GUEST_WATCHDOG_INTERVAL=%s\n' "${ZD_GUEST_WATCHDOG_INTERVAL:-}"
    printf 'ZD_GUEST_WATCHDOG_FAILURES=%s\n' "${ZD_GUEST_WATCHDOG_FAILURES:-}"
    printf 'ZD_GUEST_WATCHDOG_SILENT=%s\n' "${ZD_GUEST_WATCHDOG_SILENT:-}"
    printf 'ZD_WATCHDOG_LINK_KIND=%s\n' "${ZD_WATCHDOG_LINK_KIND:-}"
    printf 'ZD_WATCHDOG_GUEST_LINK=%s\n' "${ZD_WATCHDOG_GUEST_LINK:-}"
    printf 'ZD_MAC1=%s\n' "${ZD_MAC1:-}"
    printf 'ZD_CONTROL_SOCK=%s\n' "${ZD_CONTROL_SOCK:-}"
    printf 'STATE_DIR=%s\n' "${STATE_DIR:-}"
} >"${STUB_ENV:?}" 2>/dev/null
: >"${STUB_RAN:?}"
STUB
chmod 755 "$TMP/work/zd1200-guest-watchdog"

# run_block <label> [NAME=VALUE ...] -- source the lifted block in a subshell
# with those knobs set (and the two watchdog keys cleared first, so the caller's
# environment cannot decide the outcome), then wait for the stub's marker.
# Prints the block's own output to $TMP/out.<label> and the stub pid it recorded
# to $TMP/pid.<label>.
run_block() {
    local label="$1"; shift
    local ran="$TMP/ran.$label" envout="$TMP/env.$label" out="$TMP/out.$label" pid="$TMP/pid.$label"
    rm -f "$ran" "$envout" "$pid"
    (
        unset ZD_GUEST_WATCHDOG ZD_GUEST_WATCHDOG_CHILD \
              ZD_MACVTAP_IF ZD_WATCHDOG_LINK_KIND ZD_WATCHDOG_GUEST_LINK
        # The Docker flow runs in macvtap mode (docker-compose.yml); a case that
        # wants another launch mode passes network_mode=... as a knob.
        export network_mode=macvtap
        export work_dir="$TMP/work" log_file="$TMP/console.$label.log" \
               control_sock="$TMP/ctl.sock" zd_mac1="02:00:00:00:00:01" \
               state_dir="$TMP/state" address_helper="$TMP/work/zd1200-guest-address" \
               STUB_RAN="$ran" STUB_ENV="$envout"
        local kv
        for kv in "$@"; do export "$kv"; done
        # shellcheck disable=SC1090
        . "$TMP/block.sh"
        printf 'watchdog_pid=%s\n' "${watchdog_pid:-}" >"$pid"
    ) >"$out" 2>&1
    local i=0
    while [ ! -e "$ran" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
}

# --- 1. the Docker flow: no knob, so the child starts ------------------------
run_block default
[ -e "$TMP/ran.default" ] || fail "the child watchdog did not start with no knob set (Docker flow); output: $(cat "$TMP/out.default")"
grep -qx 'ZD_WATCHDOG_LINK_KIND=macvtap' "$TMP/env.default" \
    || fail "the child was not told to use the macvtap L2 lookup: $(cat "$TMP/env.default" 2>/dev/null)"
grep -qx 'ZD_WATCHDOG_GUEST_LINK=mvt0' "$TMP/env.default" \
    || fail "the child was not told which macvtap to watch: $(cat "$TMP/env.default" 2>/dev/null)"
grep -qx 'ZD_GUEST_WATCHDOG_INTERVAL=60' "$TMP/env.default" \
    || fail "the child's probe interval default changed: $(cat "$TMP/env.default" 2>/dev/null)"
grep -qx 'ZD_GUEST_WATCHDOG_FAILURES=5' "$TMP/env.default" \
    || fail "the child's failure threshold default changed: $(cat "$TMP/env.default" 2>/dev/null)"
grep -qx 'ZD_GUEST_WATCHDOG_SILENT=600' "$TMP/env.default" \
    || fail "the child was not given the ten-minute layer-2 silence limit: $(cat "$TMP/env.default" 2>/dev/null)"
grep -Eq '^watchdog_pid=[0-9]+$' "$TMP/pid.default" \
    || fail "the child was started but not recorded for supervision: $(cat "$TMP/pid.default")"
pass "no knob (Docker flow): the child watchdog starts with the macvtap L2 lookup"

# A second instance on the same host names its own macvtap (ZD_MACVTAP_IF, written
# into .env by the installer); the watchdog must watch that one, not mvt0.
run_block named ZD_MACVTAP_IF=mvt-zdx
grep -qx 'ZD_WATCHDOG_GUEST_LINK=mvt-zdx' "$TMP/env.named" \
    || fail "an instance's own macvtap name did not reach the watchdog: $(cat "$TMP/env.named" 2>/dev/null)"
pass "a non-default ZD_MACVTAP_IF is the interface the watchdog watches"

# Any launch mode other than macvtap has no macvtap to read a counter from.
run_block usermode network_mode=user
grep -qx 'ZD_WATCHDOG_LINK_KIND=none' "$TMP/env.usermode" \
    || fail "a non-macvtap launch mode was not given the no-evidence kind: $(cat "$TMP/env.usermode" 2>/dev/null)"
pass "outside macvtap mode the watchdog is told there is no layer-2 evidence"

# --- 1b. the child's stdout is NOT also piped into the console log -----------
# $log_file is the correlated boot record (board data, the launcher transcript
# and -- deliberately -- the watchdog's own mirror of each line).  The entrypoint
# used to redirect the child's stdout into that same file as well, so every
# watchdog line landed in it twice.  Exactly one writer per destination.
grep -q 'stub-watchdog-started' "$TMP/out.default" \
    || fail "the child's output did not reach the entrypoint's own stdout (docker logs): $(cat "$TMP/out.default")"
if [ -e "$TMP/console.default.log" ] && grep -q 'stub-watchdog-started' "$TMP/console.default.log"; then
    fail "the entrypoint redirected the child's stdout into the console log as well"
fi
pass "the child's stdout stays on the container's stdout: no second writer in the console log"
grep -q 'ZD_WATCHDOG_LOG="\$log_file"' "$ENTRYPOINT" \
    || fail "$ENTRYPOINT no longer tells the watchdog which console log to mirror into, so a non-default instance would mirror into the default file"
pass "the entrypoint tells the watchdog which console log to mirror into"

# --- 2. the LXC flow: the key is set, so the child must NOT start ------------
run_block off ZD_GUEST_WATCHDOG_CHILD=0
[ ! -e "$TMP/ran.off" ] || fail "ZD_GUEST_WATCHDOG_CHILD=0 still started a second watchdog"
grep -qx 'watchdog_pid=' "$TMP/pid.off" || fail "the block left a watchdog pid behind with the child disabled"
grep -qi 'ZD_GUEST_WATCHDOG_CHILD=0' "$TMP/out.off" \
    || fail "the entrypoint disabled the child without saying why: $(cat "$TMP/out.off")"
pass "ZD_GUEST_WATCHDOG_CHILD=0 (LXC flow): no second watchdog, and it says so"

# --- 3. ZD_GUEST_WATCHDOG=0 still disables the child ------------------------
run_block guestoff ZD_GUEST_WATCHDOG=0
[ ! -e "$TMP/ran.guestoff" ] || fail "ZD_GUEST_WATCHDOG=0 still started the child watchdog"
grep -qi 'ZD_GUEST_WATCHDOG=0' "$TMP/out.guestoff" \
    || fail "the entrypoint disabled the watchdog without saying why: $(cat "$TMP/out.guestoff")"
pass "ZD_GUEST_WATCHDOG=0: the child watchdog stays off"

# --- 4. the LXC flow's own config: the key, and the unit it hands over to ----
grep -q "printf 'ZD_GUEST_WATCHDOG_CHILD=0" "$BOOTSTRAP" \
    || fail "$BOOTSTRAP does not write ZD_GUEST_WATCHDOG_CHILD=0, so the LXC flow would run two watchdogs"
pass "the LXC flow writes ZD_GUEST_WATCHDOG_CHILD=0 into /etc/zd1200.conf"
grep -q '/etc/systemd/system/zd1200-watchdog.service' "$BOOTSTRAP" \
    || fail "$BOOTSTRAP no longer installs zd1200-watchdog.service: with the child disabled the LXC flow would have NO watchdog"
grep -q 'ExecStart=/usr/local/sbin/zd1200-guest-watchdog' "$BOOTSTRAP" \
    || fail "the LXC watchdog unit no longer runs zd1200-guest-watchdog"
pass "the LXC flow supervises zd1200-guest-watchdog as a systemd unit instead"

# --- 5. the watchdog itself: stdout only, no file of its own -----------------
# ZD_WATCHDOG_LOG names the console log the watchdog mirrors each line into, and
# that mirror is deliberate (it is what correlates "the guest stopped answering"
# with the last thing the guest printed).  What must not happen is a SECOND copy
# in the same file, which is what the entrypoint's stdout redirect produced.
# Driven with a stub healthcheck that answers, so the watchdog logs at least one
# line before the timeout.
WATCHDOG="$REPO/scripts/container/zd1200-guest-watchdog"
[ -x "$WATCHDOG" ] || fail "missing or not executable: $WATCHDOG"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/healthy"
chmod 755 "$TMP/healthy"
mkdir -p "$TMP/run" "$TMP/state2"
# The entrypoint creates the console log (`: > "$log_file"`) long before it
# starts the watchdog, and log() only mirrors into a file that exists -- so the
# fixture must create it, exactly as the real flow does.
: > "$TMP/console5.log"
wd_out="$(env ZD_GUEST_WATCHDOG_INTERVAL=1 ZD_GUEST_WATCHDOG_FAILURES=99 \
    ZD_HEALTHCHECK_HELPER="$TMP/healthy" ZD_WATCHDOG_RUN_DIR="$TMP/run" \
    STATE_DIR="$TMP/state2" ZD_WATCHDOG_LOG="$TMP/console5.log" ZD_MAC1=02:00:00:00:00:01 \
    timeout 3 bash "$WATCHDOG" 2>&1 || true)"
printf '%s\n' "$wd_out" | grep -q 'zd1200-watchdog:' \
    || fail "the watchdog logged nothing on stdout: $wd_out"
[ -r "$TMP/console5.log" ] \
    || fail "the watchdog did not mirror into ZD_WATCHDOG_LOG, so a wedge would leave no trace in the console record"
wd_out_n="$(printf '%s\n' "$wd_out" | grep -c 'guest is answering; watching')"
wd_log_n="$(grep -c 'guest is answering; watching' "$TMP/console5.log")"
[ "$wd_out_n" = 1 ] && [ "$wd_log_n" = 1 ] \
    || fail "one action must appear once per destination (stdout=$wd_out_n, console log=$wd_log_n)"
pass "the watchdog writes each action exactly once to stdout and once to the console record"

echo
echo "all guest watchdog-child tests passed"
