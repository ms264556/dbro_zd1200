#!/usr/bin/env bash
#
# xlink-mac-test.sh — the LXC uplink cross-connect must carry a guest that wears
# the uplink's own MAC.
#
# zd1200-ct-net.sh joins the container's uplink to br-zd through a veth "wire"
# and a two-way `tc` redirect, instead of enslaving the uplink.  Enslaving it
# would make the bridge install a permanent local FDB entry for the uplink's own
# MAC and deliver the guest's frames to the addressless uplink, so a guest that
# shares the hypervisor's MAC (the default) would never get its DHCP reply.
#
# This builds the real topology in network namespaces — the LAN end and the guest
# end in separate namespaces, so the two really do exchange frames at L2 — runs
# the real zd1200-ct-net.sh, and checks that a guest whose NIC MAC equals the
# uplink's MAC can reach the LAN and be reached.  A control (distinct MACs) and a
# second run (idempotency) are included.
#
# Needs root, `ip netns`, `tc` and `unshare`; skips with a message otherwise.
#
# Usage: sudo ./scripts/test/xlink-mac-test.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../container" && pwd)"
SCRIPT="$BASE/proxmox/zd1200-ct-net.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

[ -f "$SCRIPT" ] || fail "not found: $SCRIPT"

skip() { printf 'skip: %s\n' "$*"; exit 0; }
[ "$(id -u)" = 0 ] || skip "needs root (run with sudo)"
command -v ip >/dev/null 2>&1 || skip "ip is missing"
command -v tc >/dev/null 2>&1 || skip "tc is missing"
command -v unshare >/dev/null 2>&1 || skip "unshare is missing"
ip netns list >/dev/null 2>&1 || skip "network namespaces are unavailable"

# The names the real script uses inside the container namespace.
LAN="zd-xlink-lan"; CT="zd-xlink-ct"; GUEST="zd-xlink-guest"; PROBE="zd-xlink-probe"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-xlink.XXXXXX")"
cleanup() {
    for ns in "$LAN" "$CT" "$GUEST" "$PROBE"; do ip netns del "$ns" 2>/dev/null || true; done
    rm -rf "$TMP"
}
trap cleanup EXIT

X=bc:24:11:2e:c9:91        # the container's (hypervisor-allocated) MAC
Y=bc:24:11:2e:c9:92        # a distinct guest MAC for the control
LANGW=198.18.10.1; GUESTIP=198.18.10.2; CTIP=198.18.10.3

# --- preflight: is tc mirred usable here? -----------------------------------
ip netns add "$PROBE"
ip -n "$PROBE" link add pa type veth peer name pb
ip -n "$PROBE" link set pa up
ip -n "$PROBE" link set pb up
if ! ip netns exec "$PROBE" tc qdisc add dev pa clsact 2>/dev/null \
   || ! ip netns exec "$PROBE" tc filter add dev pa ingress matchall \
        action mirred egress redirect dev pb 2>/dev/null; then
    skip "tc mirred (act_mirred) is unavailable on this kernel"
fi
ip netns del "$PROBE"

# --- build the topology ------------------------------------------------------
for ns in "$LAN" "$CT" "$GUEST"; do
    ip netns add "$ns"
    ip -n "$ns" link set lo up
done
ip link add lanp netns "$LAN" type veth peer name eth0 netns "$CT"
ip link add tap-zd netns "$CT" type veth peer name geth0 netns "$GUEST"

ip -n "$LAN" addr add "$LANGW/24" dev lanp
ip -n "$LAN" link set lanp up
# PVE brings the container-side veth up with the allocated MAC and hands the CT
# a DHCP address that the network script then moves onto the bridge.
ip -n "$CT" link set eth0 address "$X"
ip -n "$CT" addr add "$CTIP/24" dev eth0
ip -n "$CT" link set eth0 up
ip -n "$CT" link set tap-zd up

# Run the REAL script with /etc/sysctl.d masked and its state file redirected, so
# nothing on the host is touched.  ZD_DISPLAY_IPV6=1 skips the IPv6 sysctls.
cat > "$TMP/run-net.sh" <<EOF
#!/usr/bin/env bash
mount -t tmpfs none /etc/sysctl.d 2>/dev/null || true
exec ip netns exec $CT env \
    ZD_HOST_IF=eth0 ZD_CT_DHCP=1 ZD_DISPLAY_IPV6=1 \
    ZD_NET_STATE_FILE="$TMP/address" \
    bash "$SCRIPT"
EOF

run_script() {
    unshare -m bash "$TMP/run-net.sh" >"$TMP/net.log" 2>&1 \
        || { cat "$TMP/net.log" >&2; fail "zd1200-ct-net.sh exited non-zero"; }
}
guest_mac() {
    ip -n "$GUEST" link set geth0 address "$1"
    ip -n "$GUEST" addr add "$GUESTIP/24" dev geth0 2>/dev/null || true
    ip -n "$GUEST" link set geth0 up
}
attach_tap() {   # launch-vm.sh attaches the tap to the bridge
    ip -n "$CT" link set tap-zd master br-zd
    ip -n "$CT" link set tap-zd up
}
ping_ok() { ip netns exec "$1" ping -c2 -W2 -q "$2" >/dev/null 2>&1; }

run_script
pass "zd1200-ct-net.sh completes"

# Shared MAC: the guest wears the uplink's MAC and must still reach the LAN.
guest_mac "$X"
attach_tap
sleep 1

# The uplink must NOT be a bridge port, and the wire and tap must be.
bridge_ports="$(ip -n "$CT" -o link show master br-zd | awk -F': ' '{print $2}' | tr '\n' ' ')"
case "$bridge_ports" in
    *"eth0"*) fail "the uplink is still a bridge port: $bridge_ports" ;;
esac
case "$bridge_ports" in
    *"tap-zd"*) ;;
    *) fail "the guest tap is not on the bridge: $bridge_ports" ;;
esac
pass "uplink is not a bridge port; bridge ports: ${bridge_ports% }"

ping_ok "$GUEST" "$LANGW" || fail "shared MAC: guest cannot reach the LAN"
ping_ok "$LAN" "$GUESTIP" || fail "shared MAC: LAN cannot reach the guest"
ping_ok "$CT" "$LANGW" || fail "shared MAC: the container cannot reach the LAN"
fdb="$(ip netns exec "$CT" bridge fdb show br br-zd | grep -i "$X" | tr '\n' '|')"
case "$fdb" in
    *"dev tap-zd"*) ;;
    *) fail "shared MAC $X is not on the guest tap: ${fdb:-no entry}" ;;
esac
case "$fdb" in
    *"dev eth0"*) fail "shared MAC $X is shadowed by the uplink: $fdb" ;;
esac
pass "shared MAC reaches the guest and is not shadowed by the uplink"

# Idempotency: a second run (every container boot) must not break it.
run_script
sleep 1
ping_ok "$GUEST" "$LANGW" || fail "second run broke the shared-MAC path"
ping_ok "$LAN" "$GUESTIP" || fail "second run broke the return path"
pass "a second run leaves the cross-connect working"

# Control: a distinct guest MAC also works (--no-shared-mac stays valid).
ip -n "$GUEST" link set geth0 down
ip -n "$GUEST" addr flush dev geth0 2>/dev/null || true
guest_mac "$Y"
sleep 1
ping_ok "$GUEST" "$LANGW" || fail "control: a distinct guest MAC cannot reach the LAN"
ping_ok "$LAN" "$GUESTIP" || fail "control: the LAN cannot reach a distinct-MAC guest"
pass "control: a distinct guest MAC still works"

echo
echo "all uplink cross-connect tests passed"
