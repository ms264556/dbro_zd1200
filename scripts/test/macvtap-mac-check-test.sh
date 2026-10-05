#!/usr/bin/env bash
#
# macvtap-mac-check-test.sh — a refused macvtap address must stop the launch.
#
# launch-vm.sh gives the macvtap the guest's board-data MAC1 so the LAN's DHCP
# reply is delivered to the guest (a macvlan bridge routes by destination MAC,
# not by flooding every port).  When another interface on the same parent already
# owns that MAC the kernel refuses the address with
# "RTNETLINK answers: Address already in use", the macvtap keeps its
# auto-generated MAC, and the guest boots to READY and passes its own healthcheck
# while being unreachable: every unicast frame addressed to the guest's MAC is
# delivered to the other interface.  launch-vm.sh did not check that the address
# took, so that one RTNETLINK console line was the only symptom.
#
# The test drives the real launch-vm.sh from a throwaway tree with a stub `ip` on
# PATH: this workstation has no macvtap, no NET_ADMIN and no Docker daemon.  The
# readback launch-vm.sh performs is not stubbed — it is a real read of
# /sys/class/net/<if>/address — so the refused cases use an interface name that
# does not exist (the readback stays different from the wanted MAC) and the
# accepted case uses one that does.
#
# Usage: ./scripts/test/macvtap-mac-check-test.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-macvtap-mac.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

LAUNCH="$BASE/scripts/container/launch-vm.sh"
[ -f "$LAUNCH" ] || fail "not found: $LAUNCH"

# The diagnostic the launcher must print when the address does not take, and the
# step it reaches next when the MAC is fine (there is no /sys/class/macvtap here,
# so the launcher stops at the tap-device check unless it gets all the way to
# QEMU).
CONFLICT='did not take the guest MAC'
UNKNOWN_OWNER='could not identify'
NEXT_STEP='Cannot find /sys/class/macvtap/'
QEMU_MARKER='ZD-QEMU-STUB-RAN'

# --- a throwaway guest-launcher tree -----------------------------------------
# launch-vm.sh runs from its own directory (work_dir) and requires image/bzImage
# and image/rootfs.ext2 next to it.
WS="$TMP/ws"
mkdir -p "$WS/image" "$TMP/bin"
cp "$LAUNCH" "$WS/launch-vm.sh"
chmod +x "$WS/launch-vm.sh"
: > "$WS/image/bzImage"
: > "$WS/image/rootfs.ext2"
: > "$TMP/disk.img"      # DISK_IMAGE: never let it run build-synthetic-cf.py
cat > "$WS/qemu-once.py" <<'PY'
print("ZD-QEMU-STUB-RAN")
PY

# The stub stands in for ip(8).  It logs every call, refuses the address the way
# the kernel does when another interface owns it, and reports the macvtap as
# absent so the launcher takes its "create it" branch.
cat > "$TMP/bin/ip" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$ZD_STUB_IP_LOG"
case "$*" in
    "link show "*)
        exit "${ZD_STUB_SHOW_RC:-1}" ;;
    *" addrgenmode "*)
        exit "${ZD_STUB_AGM_RC:-0}" ;;
    *" address "*)
        if [ "${ZD_STUB_SETADDR_RC:-0}" != 0 ]; then
            echo "RTNETLINK answers: Address already in use" >&2
            exit 1
        fi
        exit 0 ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/ip"
export PATH="$TMP/bin:$PATH"
export ZD_STUB_IP_LOG="$TMP/ip.log"

# --- run_launch <iface> <wanted-mac> [setaddr-rc] -----------------------------
# Runs the real launcher and records its exit status in RUN_RC and its combined
# output in $TMP/out.
RUN_RC=0
run_launch() {
    local iface="$1" want="$2" setaddr_rc="${3:-1}"
    : > "$TMP/ip.log"
    RUN_RC=0
    env PATH="$PATH" \
        KERNEL="$WS/image/bzImage" \
        DISK_IMAGE="$TMP/disk.img" \
        NETWORK_MODE=macvtap \
        ZD_MAC1="$want" \
        ZD_MACVTAP_IF="$iface" \
        ZD_STUB_IP_LOG="$ZD_STUB_IP_LOG" \
        ZD_STUB_SHOW_RC=1 \
        ZD_STUB_SETADDR_RC="$setaddr_rc" \
        ZD_STUB_AGM_RC="${ZD_STUB_AGM_RC:-0}" \
        "$WS/launch-vm.sh" > "$TMP/out" 2>&1 || RUN_RC=$?
}

# A real interface whose address can stand in for "the interface that already
# owns the guest's MAC".  The launcher scans /sys/class/net for it.
owner_if=""; owner_mac=""
for d in /sys/class/net/*; do
    n="${d##*/}"
    a="$(cat "$d/address" 2>/dev/null || true)"
    printf '%s' "$a" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || continue
    owner_if="$n"; owner_mac="$a"; break
done
[ -n "$owner_if" ] || fail "no interface in /sys/class/net can stand in as the MAC owner"

# An interface that does not exist: the readback of its address cannot equal the
# wanted MAC, which is exactly the post-refusal state.
MISSING_IF="zd-no-such-if"

# --- 1. refused, owner determinable: stop and name the owner -----------------
run_launch "$MISSING_IF" "$owner_mac" 1
[ "$RUN_RC" -ne 0 ] || fail "a refused macvtap address did not stop the launch (rc=0)"
grep -qF "$CONFLICT" "$TMP/out" \
    || fail "the refused address was not reported: $(tr '\n' '|' < "$TMP/out")"
grep -qF "$owner_mac" "$TMP/out" || fail "the diagnostic does not name the wanted MAC $owner_mac"
grep -qF "$owner_if already owns $owner_mac" "$TMP/out" \
    || fail "the diagnostic does not name $owner_if as the owner of $owner_mac: $(tr '\n' '|' < "$TMP/out")"
if grep -qF "$NEXT_STEP" "$TMP/out" || grep -qF "$QEMU_MARKER" "$TMP/out"; then
    fail "the launch continued past a refused MAC"
fi
pass "a refused macvtap address stops the launch and names $owner_if ($owner_mac)"

# --- 2. refused, owner not determinable: still stop, with the wanted MAC -----
unknown_mac=02:00:00:00:00:5a
for d in /sys/class/net/*; do
    [ "$(cat "$d/address" 2>/dev/null || true)" = "$unknown_mac" ] \
        && fail "$unknown_mac is a real interface address; pick another"
done
run_launch "$MISSING_IF" "$unknown_mac" 1
[ "$RUN_RC" -ne 0 ] || fail "a refused address with no identifiable owner did not stop the launch"
grep -qF "$CONFLICT" "$TMP/out" || fail "the refusal was not reported: $(tr '\n' '|' < "$TMP/out")"
grep -qF "$unknown_mac" "$TMP/out" || fail "the diagnostic does not name the wanted MAC"
grep -qF "$UNKNOWN_OWNER" "$TMP/out" \
    || fail "an unidentifiable owner is not reported as such: $(tr '\n' '|' < "$TMP/out")"
pass "a refusal with no identifiable owner still stops the launch and says so"

# --- 3. accepted address: no false failure, the launch goes on ---------------
# lo really exists and already carries the wanted MAC, so the readback matches
# even though the stub ip "fails" the set: this is the "the address is what we
# need" case, and it must never be reported as a refusal.
lo_mac="$(cat /sys/class/net/lo/address)"
run_launch lo "$lo_mac" 1
if grep -qF "$CONFLICT" "$TMP/out"; then
    fail "a MAC that is already in place was reported as a refusal: $(tr '\n' '|' < "$TMP/out")"
fi
grep -q -- "link set lo address $lo_mac" "$TMP/ip.log" \
    || fail "the launcher never tried to set the address: $(tr '\n' '|' < "$TMP/ip.log")"
if ! grep -qF "$NEXT_STEP" "$TMP/out" && ! grep -qF "$QEMU_MARKER" "$TMP/out"; then
    fail "the launcher did not get past the MAC step: $(tr '\n' '|' < "$TMP/out")"
fi
pass "an address that is already in place is not reported as a refusal"

# --- 4. no ZD_MAC1: the block is skipped, nothing is set or reported ---------
run_launch "$MISSING_IF" "" 1
if grep -qF "$CONFLICT" "$TMP/out"; then
    fail "an empty ZD_MAC1 produced a refusal: $(tr '\n' '|' < "$TMP/out")"
fi
if grep -q -- ' address ' "$TMP/ip.log"; then
    fail "an empty ZD_MAC1 still tried to set an address: $(tr '\n' '|' < "$TMP/ip.log")"
fi
if ! grep -qF "$NEXT_STEP" "$TMP/out" && ! grep -qF "$QEMU_MARKER" "$TMP/out"; then
    fail "an empty ZD_MAC1 did not leave the launch running: $(tr '\n' '|' < "$TMP/out")"
fi
pass "an empty ZD_MAC1 skips the block entirely"


# --- 5. the host's IPv6 is silenced on the macvtap, before it comes up --------
# The macvtap wears the guest's MAC, so the kernel's own link-local address and the
# MLD/neighbour frames it sends are indistinguishable from the guest's.  The guest
# watchdog counts this interface's transmitted frames as proof the guest is alive;
# measured with a frozen guest, one host frame every ~2 minutes made it look alive.
run_launch lo "$lo_mac" 1
agm_line="$(grep -n -- 'link set dev lo addrgenmode none' "$TMP/ip.log" | head -1 | cut -d: -f1 || true)"
flush_line="$(grep -n -- '-6 addr flush dev lo' "$TMP/ip.log" | head -1 | cut -d: -f1 || true)"
up_line="$(grep -n -- 'link set lo up' "$TMP/ip.log" | head -1 | cut -d: -f1 || true)"
[ -n "$agm_line" ] || fail "addrgenmode was never set to none: $(tr '\n' '|' < "$TMP/ip.log")"
[ -n "$flush_line" ] || fail "the macvtap's IPv6 addresses were never flushed: $(tr '\n' '|' < "$TMP/ip.log")"
[ -n "$up_line" ] || fail "the macvtap was never brought up: $(tr '\n' '|' < "$TMP/ip.log")"
[ "$agm_line" -lt "$up_line" ] || fail "addrgenmode was set after the interface came up"
[ "$flush_line" -lt "$up_line" ] || fail "the flush happened after the interface came up"
pass "the host stops generating IPv6 addresses on the macvtap before it comes up"

# A kernel or iproute that cannot do it must not stop the guest, but must say so.
ZD_STUB_AGM_RC=1 run_launch lo "$lo_mac" 1
grep -q "could not stop the host's IPv6" "$TMP/out" \
    || fail "a failed addrgenmode was not reported: $(tr '\n' '|' < "$TMP/out")"
if ! grep -qF "$NEXT_STEP" "$TMP/out" && ! grep -qF "$QEMU_MARKER" "$TMP/out"; then
    fail "a failed addrgenmode stopped the launch: $(tr '\n' '|' < "$TMP/out")"
fi
pass "a failed addrgenmode is reported and does not stop the launch"

echo
echo "all macvtap MAC-check tests passed"
