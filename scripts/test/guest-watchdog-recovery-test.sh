#!/usr/bin/env bash
#
# guest-watchdog-recovery-test.sh — what zd1200-guest-watchdog does once the
# guest stops answering.  Offline: the healthcheck, `bridge` and the emulator are
# stubs, and the macvtap's transmit counter is a file in a sysfs fixture.
#
#   (a) a guest that ignores the reboot request gets the emulator reset
#       (SIGUSR1 to the emulator's parent, i.e. qemu-once.py);
#   (b) a guest that reboots on request is not reset as well;
#   (c) Docker (macvtap): a guest that keeps transmitting is left alone even
#       though it does not answer; a guest whose transmit counter has been flat for
#       the limit is rebooted, and one that is merely quiet for less than the limit
#       is not (the default limit is ten minutes -- an idle appliance goes quiet
#       for minutes); a guest that was busy only while it still answered is judged
#       by when it LAST sent; an unreadable counter is "cannot tell" (reboot) and a
#       missing macvtap is not blamed on the guest;
#   (d) Proxmox (bridge): a guest whose MAC is in the bridge's FDB is left alone,
#       one that is gone is rebooted, and an unknown MAC is "cannot tell" (reboot);
#   (e) a launch mode with no layer-2 evidence ("none") reboots a silent guest;
#   (f) an emulator that was relaunched while the guest was failing (the guest
#       restarted itself) is booting, not wedged.
#
# Usage: ./scripts/test/guest-watchdog-recovery-test.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WATCHDOG="$REPO/scripts/container/zd1200-guest-watchdog"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-wdrec.XXXXXX")"
PIDS=()
cleanup() {
    local p
    # Children first: each fake emulator is a `sleep` under a parent in PIDS.
    for p in "${PIDS[@]:-}"; do
        [ -n "$p" ] || continue
        pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null
    done
    rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }
[ -x "$WATCHDOG" ] || fail "missing or not executable: $WATCHDOG"

MAC=02:aa:bb:cc:dd:ee
mkdir -p "$TMP/bin" "$TMP/sys/mvt9/statistics" "$TMP/sys/br9"
TXFILE="$TMP/sys/mvt9/statistics/tx_packets"
set_tx() { printf '%s\n' "$1" > "$TXFILE.new" && mv "$TXFILE.new" "$TXFILE"; }

# The guest: healthy while $TMP/alive exists.  Every probe is also a deterministic
# tick of the guest's life: with $TMP/bump_ok the counter moves on a healthy probe,
# with $TMP/bump_fail it moves on a failing one (a guest that is alive but does not
# answer), so no test depends on a background loop getting scheduled in time.
cat > "$TMP/health" <<EOF
#!/bin/sh
bump() { n=\$(cat "$TXFILE" 2>/dev/null || echo 0); echo \$((n + 1)) > "$TXFILE.new" && mv "$TXFILE.new" "$TXFILE"; }
if [ -e "$TMP/alive" ]; then
    [ -e "$TMP/bump_ok" ] && bump
    exit 0
fi
[ -e "$TMP/bump_fail" ] && bump
exit 1
EOF
# `bridge fdb show br br9`: whatever $TMP/fdb holds.
cat > "$TMP/bin/bridge" <<EOF
#!/bin/sh
cat "$TMP/fdb" 2>/dev/null
EOF
chmod +x "$TMP/health" "$TMP/bin/bridge"

# start_emulator: a parent that records SIGUSR1 and a child whose pid is the
# "emulator" in the pid file -- the shape qemu-once.py and QEMU have.
start_emulator() {
    rm -f "$TMP/usr1" "$TMP/qemu.pid"
    bash -c 'trap "echo reset > \"$1/usr1\"" USR1
             sleep 300 & echo $! > "$1/qemu.pid"
             while :; do wait; done' _ "$TMP" >/dev/null 2>&1 &
    PIDS+=("$!")
    local i
    for i in $(seq 1 50); do [ -s "$TMP/qemu.pid" ] && return 0; sleep 0.1; done
    fail "the fake emulator did not start"
}

# swap_emulator: the emulator is relaunched -- a new child, a new pid in the file.
swap_emulator() {
    ( sleep 300 & echo $! > "$TMP/qemu.pid.new"; mv "$TMP/qemu.pid.new" "$TMP/qemu.pid"; wait ) >/dev/null 2>&1 &
    PIDS+=("$!")
}

# wait_log <regex> <seconds>: until the watchdog's log has the line.
wait_log() {
    local i
    for i in $(seq 1 $(( $2 * 5 ))); do grep -q -- "$1" "$TMP/log" 2>/dev/null && return 0; sleep 0.2; done
    return 1
}

# start_watchdog: one watchdog over a guest that answers; KIND, LINK and MAC1 select
# the evidence, its log is $TMP/log.  stop_watchdog ends it.
WD=""
start_watchdog() {
    : > "$TMP/log"; rm -rf "$TMP/run"; mkdir -p "$TMP/run"
    touch "$TMP/alive"
    PATH="$TMP/bin:$PATH" \
    ZD_WATCHDOG_RUN_DIR="$TMP/run" ZD_WATCHDOG_LOG="$TMP/log" STATE_DIR="$TMP" \
    ZD_GUEST_WATCHDOG_INTERVAL=1 ZD_GUEST_WATCHDOG_FAILURES=2 \
    ZD_GUEST_WATCHDOG_COOLDOWN=60 ZD_GUEST_WATCHDOG_SOFT_WAIT=5 \
    ZD_GUEST_WATCHDOG_SILENT="${SILENT:-3}" \
    ZD_HEALTHCHECK_HELPER="$TMP/health" ZD_CONTROL_SOCK="$TMP/no.sock" \
    ZD_WATCHDOG_LINK_KIND="${KIND:-macvtap}" ZD_WATCHDOG_GUEST_LINK="${LINK:-mvt9}" \
    ZD_WATCHDOG_SYSFS="$TMP/sys" ZD_MAC1="${MAC1-$MAC}" \
        "$WATCHDOG" >/dev/null 2>&1 &
    WD=$!
    PIDS+=("$WD")
}
stop_watchdog() { [ -n "$WD" ] && { kill "$WD" 2>/dev/null; wait "$WD" 2>/dev/null; }; WD=""; }

# run_watchdog <seconds>: a guest that answers once and then goes silent.
run_watchdog() {
    start_watchdog
    sleep 2; rm -f "$TMP/alive"
    sleep "$1"
    stop_watchdog
}

# --- (a) the request is ignored ----------------------------------------------
set_tx 100
start_emulator
run_watchdog 12
[ -e "$TMP/usr1" ] || fail "(a) the emulator's parent was never signalled:
$(cat "$TMP/log")"
grep -q 'ignored the reboot request .* resetting the emulator' "$TMP/log" \
    || fail "(a) the reset was not logged:
$(cat "$TMP/log")"
pass "(a) a guest that ignores the reboot request gets the emulator reset"

# --- (b) the request works ---------------------------------------------------
# The emulator's pid changes once the watchdog has recorded the old one and logged
# that it cannot request a reboot (there is no control socket), so the swap cannot
# race the watchdog's own bookkeeping on a slow machine.
set_tx 100
start_emulator
start_watchdog
sleep 2; rm -f "$TMP/alive"
wait_log 'cannot request a guest reboot' 20 || fail "(b) the watchdog never reached the reboot request:
$(cat "$TMP/log")"
swap_emulator
sleep 8
stop_watchdog
[ ! -e "$TMP/usr1" ] || fail "(b) the emulator was reset although the guest rebooted:
$(cat "$TMP/log")"
grep -q 'the guest rebooted on request' "$TMP/log" || fail "(b) the reboot was not noticed:
$(cat "$TMP/log")"
pass "(b) a guest that reboots on request is not reset as well"

# --- (c) Docker: the macvtap's transmit counter -------------------------------
# The guest does not answer the probe, but every failed probe is a tick of its life
# (the counter moves): it is on the LAN, not wedged -- on any VLAN.
set_tx 100
touch "$TMP/bump_fail"
start_emulator
run_watchdog 6
rm -f "$TMP/bump_fail"
grep -q 'the guest last sent a frame on mvt9 .*not wedged; not rebooting' "$TMP/log" \
    || fail "(c) a transmitting guest was not recognised:
$(cat "$TMP/log")"
[ ! -e "$TMP/usr1" ] || fail "(c) a guest that is still transmitting was reset"
pass "(c) a guest that keeps transmitting is left alone"

# Flat counter for longer than the limit (3 s here): silent.
set_tx 100
start_emulator
run_watchdog 12
grep -q 'the guest has sent nothing on mvt9 for [0-9]*s (limit 3s)' "$TMP/log" \
    || fail "(c) a silent guest was not recognised:
$(cat "$TMP/log")"
[ -e "$TMP/usr1" ] || fail "(c) a guest whose transmit counter was flat for the limit was not reset:
$(cat "$TMP/log")"
pass "(c) a guest whose transmit counter has been flat for the limit is rebooted"

# Quiet, but not for as long as the limit: an idle appliance can go quiet for minutes,
# and the default limit (ten minutes) is the whole point.  Flat for the ~10 s of this
# run, with the default limit: not wedged.
set_tx 100
start_emulator
SILENT=600 run_watchdog 8
grep -q 'the guest last sent a frame on mvt9 .*(limit 600s): it is on the LAN, not wedged; not rebooting' "$TMP/log" \
    || fail "(c) a quiet guest within the limit was not left alone:
$(cat "$TMP/log")"
[ ! -e "$TMP/usr1" ] || fail "(c) a guest that was only quiet for less than the limit was reset:
$(cat "$TMP/log")"
pass "(c) a guest that is merely quiet for less than the limit is left alone"

# A guest that was busy while it still answered and went quiet when the failures began
# is judged by when it LAST sent, not by when the failures began: first "not wedged"
# (it sent a moment ago), later -- once the limit has passed -- rebooted.
set_tx 100
touch "$TMP/bump_ok"
start_emulator
run_watchdog 12
rm -f "$TMP/bump_ok"
grep -q 'the guest last sent a frame on mvt9 .*not wedged; not rebooting' "$TMP/log" \
    || fail "(c) a guest that sent until a moment ago was not given the benefit of that:
$(cat "$TMP/log")"
[ -e "$TMP/usr1" ] || fail "(c) a guest that went silent after being busy was never rebooted:
$(cat "$TMP/log")"
grep -q 'the guest has sent nothing on mvt9 for' "$TMP/log" \
    || fail "(c) the later verdict was not the silent one:
$(cat "$TMP/log")"
pass "(c) a guest is judged by when it last sent: left alone at first, rebooted once the limit passes"

# An "alive" verdict leaves nothing behind that hides a later wedge: the guest keeps
# transmitting (not wedged), then goes flat -- the time since it last moved decides.
set_tx 100
touch "$TMP/bump_fail"
start_emulator
start_watchdog
sleep 2; rm -f "$TMP/alive"
wait_log 'not wedged; not rebooting' 20 || fail "(c) the transmitting phase never produced its verdict:
$(cat "$TMP/log")"
rm -f "$TMP/bump_fail"
sleep 12
stop_watchdog
[ -e "$TMP/usr1" ] || fail "(c) a guest that went silent after an alive verdict was never rebooted:
$(cat "$TMP/log")"
pass "(c) a guest that goes silent after an alive verdict is rebooted"

# No counter: cannot tell, so recover rather than silently never recovering.
rm -f "$TXFILE"
start_emulator
run_watchdog 12
grep -q 'cannot inspect mvt9 .*rebooting anyway' "$TMP/log" \
    || fail "(c) an unreadable counter was not reported:
$(cat "$TMP/log")"
[ -e "$TMP/usr1" ] || fail "(c) an unreadable counter did not lead to a reboot"
pass "(c) an unreadable transmit counter is \"cannot tell\" and reboots"

# A macvtap that does not exist is a broken host LAN, not a wedged guest.
set_tx 100
start_emulator
LINK=mvt-gone run_watchdog 6
grep -q 'is missing: the container-side LAN is down' "$TMP/log" \
    || fail "(c) a missing macvtap was not reported:
$(cat "$TMP/log")"
[ ! -e "$TMP/usr1" ] || fail "(c) a guest was reset although its macvtap is missing"
pass "(c) a missing macvtap is not blamed on the guest"

# --- (d) Proxmox: the bridge's FDB ----------------------------------------------
printf '02:11:22:33:44:55 dev tap1 master br9\n%s dev tap0 master br9\n' "$MAC" > "$TMP/fdb"
start_emulator
KIND=bridge LINK=br9 run_watchdog 6
grep -q "MAC ($MAC) is still present on br9" "$TMP/log" \
    || fail "(d) a guest in the FDB was not recognised:
$(cat "$TMP/log")"
[ ! -e "$TMP/usr1" ] || fail "(d) a guest that is in the FDB was reset"
pass "(d) a guest whose MAC is in the bridge FDB is left alone"

printf '02:11:22:33:44:55 dev tap1 master br9\n' > "$TMP/fdb"
start_emulator
KIND=bridge LINK=br9 run_watchdog 12
[ -e "$TMP/usr1" ] || fail "(d) a guest that left the FDB was not reset:
$(cat "$TMP/log")"
pass "(d) a guest whose MAC is gone from the bridge FDB is rebooted"

start_emulator
MAC1= KIND=bridge LINK=br9 run_watchdog 12
grep -q 'no ZD_MAC1); rebooting anyway' "$TMP/log" \
    || fail "(d) an unknown MAC was not reported:
$(cat "$TMP/log")"
[ -e "$TMP/usr1" ] || fail "(d) an unknown MAC did not lead to a reboot"
pass "(d) with no known MAC the bridge shape cannot tell and reboots"

# --- (e) no layer-2 evidence --------------------------------------------------
start_emulator
KIND=none LINK=whatever run_watchdog 12
grep -q 'no layer-2 evidence in this network mode; rebooting anyway' "$TMP/log" \
    || fail "(e) the no-evidence mode did not say so:
$(cat "$TMP/log")"
[ -e "$TMP/usr1" ] || fail "(e) a silent guest with no layer-2 evidence was not reset:
$(cat "$TMP/log")"
pass "(e) a launch mode with no layer-2 evidence still recovers a silent guest"

# --- (f) the emulator was relaunched: the guest is booting ---------------------
# The guest restarted itself (a VLAN change, an upgrade, a reboot from the UI): QEMU
# exits and is relaunched, and the guest is silent until its NIC is back.  The pid
# is swapped once the first failure has been logged, i.e. after the baseline.
set_tx 100
start_emulator
start_watchdog
sleep 2; rm -f "$TMP/alive"
wait_log 'failure 1/2' 20 || fail "(f) the watchdog never counted a failure:
$(cat "$TMP/log")"
swap_emulator
sleep 5
stop_watchdog
grep -q 'the emulator was restarted since the failures began' "$TMP/log" \
    || fail "(f) a relaunched emulator was not recognised:
$(cat "$TMP/log")"
[ ! -e "$TMP/usr1" ] || fail "(f) a guest that was booting was reset"
pass "(f) a relaunched emulator means the guest is booting, not wedged"

echo
echo "all guest-watchdog recovery tests passed"
