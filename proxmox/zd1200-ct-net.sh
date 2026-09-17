#!/usr/bin/env bash
#
# proxmox/zd1200-ct-net.sh — create the container-side LAN bridge.
#
# Runs inside the ZD1200 LXC container (installed as zd1200-net.service by
# proxmox/zd1200-ct-bootstrap.sh).  It puts the container's uplink interface into
# its own bridge, so the QEMU guest can attach a tap to that bridge and become an
# ordinary L2 neighbour: the guest keeps its own MAC and DHCP lease, and — unlike
# the macvtap/Docker layout — the container and the Proxmox host can reach it.
#
# The uplink is taken from ZD_HOST_IF (default eth0) unless it is renamed in the
# LXC configuration.  The bridge is created with the kernel's default forward
# delay, which is harmless here: the only member that matters is the guest tap.
#
# The container's own address, if it has one (ip=dhcp in the CT config), is moved
# from the uplink onto the bridge.  Set ZD_CT_DHCP=1 or ZD_CT_ADDRESS=<cidr> in
# /etc/zd1200.conf so the wait above knows an address is expected.
#
# Options: --host-if IFACE, --bridge IFACE
set -euo pipefail

HOST_IF="${ZD_HOST_IF:-eth0}"
BRIDGE_IF="${ZD_BRIDGE_IF:-br-zd}"
# The display interface carries the guest's address so Proxmox can show it (see
# "Displaying the guest's address" below).  It is created here, before the
# bridge, because that is what puts it in front of the bridge in the enumeration
# Proxmox reads.
DISPLAY_IF="${ZD_DISPLAY_IF:-zd0}"

while [ $# -gt 0 ]; do
    case "$1" in
        --host-if) HOST_IF="${2:?}"; shift 2 ;;
        --bridge)  BRIDGE_IF="${2:?}"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

log() { printf 'zd1200-net: %s\n' "$*"; }

# Wait for the uplink: PVE creates the veth around container start and the name
# can briefly be a temporary "eth0" or a renamed interface's placeholder.
for _ in $(seq 1 30); do
    [ -e "/sys/class/net/$HOST_IF" ] && break
    sleep 1
done
[ -e "/sys/class/net/$HOST_IF" ] || { log "uplink $HOST_IF not found"; exit 1; }

# Proxmox puts the container's own address (ip=dhcp or ip=static in the CT
# configuration) on the uplink.  A bridge port must not carry an address, so
# move it onto the bridge.  Two ordering hazards are handled here:
#   * the unit may run before the uplink's DHCP lease arrives, so wait briefly
#     for an address rather than creating an addressless bridge and leaving the
#     container without a route; and
#   * the uplink may hold the address even though the bridge already exists
#     (a re-run, or PVE re-applying the configuration), so always flush it.
STATE_FILE=/run/zd1200-net.address

# Does the CT configuration ask for an address on this interface?
WANT_ADDRESS=0
if [ -n "${ZD_CT_ADDRESS:-}" ] || [ "${ZD_CT_DHCP:-0}" = "1" ]; then
    WANT_ADDRESS=1
elif [ -r /etc/zd1200-net.want-address ]; then
    WANT_ADDRESS=1
fi

if [ "$WANT_ADDRESS" = 1 ]; then
    for _ in $(seq 1 60); do
        ip -4 -o addr show dev "$HOST_IF" 2>/dev/null | grep -q ' inet ' && break
        [ -r "$STATE_FILE" ] && break
        sleep 1
    done
fi

GATEWAY=""; ROUTE_DEV=""
ROUTE_LINE="$(ip -4 route show default 2>/dev/null | head -1)"
if [ -n "$ROUTE_LINE" ]; then
    GATEWAY="$(printf '%s\n' "$ROUTE_LINE" | awk '{for (i=1;i<NF;i++) if ($i=="via") print $(i+1)}')"
    ROUTE_DEV="$(printf '%s\n' "$ROUTE_LINE" | awk '{for (i=1;i<NF;i++) if ($i=="dev") print $(i+1)}')"
fi

mapfile -t ADDRS < <(ip -4 -o addr show dev "$HOST_IF" 2>/dev/null | awk '{print $4}')
if [ "${#ADDRS[@]}" -gt 0 ]; then
    log "moving ${ADDRS[*]} from $HOST_IF to $BRIDGE_IF"
    # Remember the address: if the bridge is torn down and this script re-runs,
    # the uplink no longer has it to hand back.
    { printf 'ADDRS=%s\n' "${ADDRS[*]}"; printf 'GATEWAY=%s\n' "$GATEWAY"; } > "$STATE_FILE"
else
    if [ -r "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE"
        # shellcheck disable=SC2206
        ADDRS=(${ADDRS:-})
        log "restoring recorded address(es) ${ADDRS[*]:-none}"
    fi
fi

# --------------------------------------------------------------------------
# Displaying the guest's address in the Proxmox GUI
# --------------------------------------------------------------------------
# Proxmox reads the container's addresses from this network namespace (the
# "interfaces" endpoint behind the Summary and Network views) and shows the first
# two it finds, in interface order.  The guest is the appliance the operator
# cares about, so its address should be one of those two -- which means the
# container's own lease on the bridge must not fill both slots with its IPv4 and
# IPv6 addresses.
#
# Two things make that work:
#   * this interface is created BEFORE the bridge, so it enumerates first; and
#   * IPv6 is disabled, so no link-local address competes for a slot.
#
# The address itself is not known here -- the guest leases it from the LAN later
# -- so this only creates the interface.  zd1200-guest-display fills it in and
# keeps it current as the lease changes.
if [ -e "/sys/class/net/$DISPLAY_IF" ]; then
    log "display interface $DISPLAY_IF already exists; reusing it"
else
    ip link add name "$DISPLAY_IF" type dummy
    log "created display interface $DISPLAY_IF"
fi
ip link set "$DISPLAY_IF" up
# The guest must remain the only thing that answers ARP for its own address.
# zd1200-guest-display sets the arp_ignore/arp_announce sysctls that enforce
# that; `arp off` here is not enough on its own (it only sets the NOARP flag).
ip link set "$DISPLAY_IF" arp off 2>/dev/null || true

# One address per family is enough for a display interface, and the container
# needs no IPv6: a link-local address there is noise in the Summary, and the
# appliance is reached over IPv4.  Disabling it here also keeps the container's
# IPv4 address in the second displayed slot.  Persist the same settings through
# /etc/sysctl.d so a re-run of Proxmox's own network setup cannot bring the
# link-local addresses back behind our back.
if [ "${ZD_DISPLAY_IPV6:-0}" != "1" ]; then
    sysctl -qw net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
    sysctl -qw net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true
fi

if [ -e "/sys/class/net/$BRIDGE_IF" ]; then
    log "bridge $BRIDGE_IF already exists; reusing it"
else
    ip link add name "$BRIDGE_IF" type bridge
    log "created bridge $BRIDGE_IF"
fi

# The interface-scoped half of the IPv6 decision above.  `all.disable_ipv6` only
# affects interfaces created after it is set, so the ones that already exist (the
# uplink Proxmox made, the display interface and the bridge) need it named
# explicitly.  This runs before the container's address moves onto the bridge;
# disabling IPv6 does not disturb IPv4 addresses.
if [ "${ZD_DISPLAY_IPV6:-0}" != "1" ]; then
    for dev in lo "$HOST_IF" "$DISPLAY_IF" "$BRIDGE_IF"; do
        [ -e "/proc/sys/net/ipv6/conf/$dev/disable_ipv6" ] || continue
        sysctl -qw "net.ipv6.conf.$dev.disable_ipv6=1" 2>/dev/null || true
    done
    log "IPv6 disabled on the container interfaces (keeps the Summary tidy)"
fi

ip link set "$HOST_IF" master "$BRIDGE_IF" 2>/dev/null || true
ip link set "$BRIDGE_IF" up
ip link set "$HOST_IF" up

# A port must never carry an address.  This matters twice over:
#   * with the same address on the bridge and on its port the kernel keeps
#     preferring the port's route and traffic silently black-holes; and
#   * Proxmox's DHCP client keeps its lease keyed on the interface and re-adds
#     the address to the uplink after this script has moved it.
# So flush the uplink, move the address onto the bridge, and stop the
# container's DHCP client from re-acquiring a lease on the port.  The guest
# requests its own lease from the LAN's DHCP server, as on real hardware.
if [ -n "${ZD_CT_DHCP:-}" ]; then
    if command -v dhclient >/dev/null 2>&1; then
        dhclient -r "$HOST_IF" >/dev/null 2>&1 || true
        pkill -f "dhclient.*$HOST_IF" 2>/dev/null || true
    fi
fi
ip addr flush dev "$HOST_IF" 2>/dev/null || true
for a in "${ADDRS[@]}"; do
    ip addr replace "$a" dev "$BRIDGE_IF"
done
if [ -z "$GATEWAY" ] && [ -r "$STATE_FILE" ]; then
    # The uplink no longer has the route (a re-run after the move): reuse the
    # gateway recorded when the address was moved.
    recorded_gw="$(sed -n 's/^GATEWAY=//p' "$STATE_FILE" | head -1)"
    [ -n "$recorded_gw" ] && GATEWAY="$recorded_gw"
fi
if [ -n "$GATEWAY" ]; then
    ip route replace default via "$GATEWAY" dev "$BRIDGE_IF" 2>/dev/null || true
fi

# The guest's board-data MAC1 is derived from the uplink MAC, so the bridge must
# NOT also present that MAC: with the same MAC on the bridge and in the guest the
# LAN's DHCP replies are ambiguous and the guest never configures its lease
# (verified).  Give the bridge its own locally-administered address.
if [ "${ZD_BRIDGE_MAC:-1}" != "0" ]; then
    current="$(cat "/sys/class/net/$BRIDGE_IF/address" 2>/dev/null || true)"
    want="${ZD_BRIDGE_MAC_ADDRESS:-02:00:00:00:00:01}"
    if [ "$current" != "$want" ]; then
        ip link set "$BRIDGE_IF" address "$want" 2>/dev/null || true
        log "bridge MAC $current -> $want (keeps the guest's board MAC unique)"
    fi
fi

# ARP policy for the display address.  The guest's address is held locally on
# $DISPLAY_IF so Proxmox can display it, and a Linux host answers ARP for any
# address it holds locally.  Left alone, this container would therefore answer
# ARP for the appliance's own address and race the guest for its traffic -- the
# failure Gemini's recipe warns about, except that `ip link set ... arp off` does
# NOT prevent it (it only sets the NOARP flag; verified: the container still
# replied, presenting the bridge MAC).
#
# arp_ignore=1 is what actually prevents it: reply only when the target address
# is on the interface the request arrived on.  The request arrives on the uplink,
# the address lives on the display interface, so no reply is sent, while the
# bridge keeps answering for the container's own address (its own subnet).
# announce=2 keeps the container from advertising the display address as a source
# when it talks on the LAN.
#
# Written to /etc/sysctl.d as well, so the policy survives reboots and Proxmox's
# own network re-application.  This is required, not optional: without it the
# install creates exactly the duplicate-ARP outage it is trying to avoid.
{
    printf '# ZD1200 LXC: the guest must be the only thing answering for its own\n'
    printf '# address (see proxmox/zd1200-ct-net.sh).  Do not remove.\n'
    printf 'net.ipv4.conf.all.arp_ignore = 1\n'
    printf 'net.ipv4.conf.all.arp_announce = 2\n'
    if [ "${ZD_DISPLAY_IPV6:-0}" != "1" ]; then
        printf '# Container interfaces carry IPv4 only; IPv6 link-locals are noise in\n'
        printf '# the Proxmox Summary and consume one of its two address slots.\n'
        printf 'net.ipv6.conf.all.disable_ipv6 = 1\n'
        printf 'net.ipv6.conf.default.disable_ipv6 = 1\n'
    fi
} > /etc/sysctl.d/99-zd1200-display.conf 2>/dev/null || true
sysctl -qw net.ipv4.conf.all.arp_ignore=1 2>/dev/null || true
sysctl -qw net.ipv4.conf.all.arp_announce=2 2>/dev/null || true

# Address-collision guard.  The container's own lease and the guest's are handed
# out by the same LAN DHCP server, and Proxmox re-applies the CT configuration
# (address on the uplink) on its own schedule.  If the container has taken the
# address the guest is using, every packet for the guest is delivered to the
# container instead, and the appliance looks dead while the container looks fine
# -- the exact failure mode observed while bringing this up.  Release the
# container's address so the guest owns it, as it would on real hardware.
if [ -s "$STATE_FILE" ] && [ -n "${ZD_GUEST_IP_FILE:-}" ] && [ -r "$ZD_GUEST_IP_FILE" ]; then
    guest_addr="$(head -n1 "$ZD_GUEST_IP_FILE" 2>/dev/null || true)"
    if [ -n "$guest_addr" ] && ip -o -4 addr show dev "$BRIDGE_IF" | grep -qw "$guest_addr"; then
        log "address conflict: $BRIDGE_IF holds $guest_addr, which belongs to the guest; releasing it"
        ip addr del "$guest_addr/32" dev "$BRIDGE_IF" 2>/dev/null || true
        # The lease is recorded in the state file; drop the matching entry so a
        # later run does not put it straight back (keeping the gateway).
        recorded="$(sed -n 's/^ADDRS=//p' "$STATE_FILE" | head -1)"
        gp="$(sed -n 's/^GATEWAY=//p' "$STATE_FILE" | head -1)"
        kept=""
        for a in $recorded; do
            case "$a" in "$guest_addr"/*) ;; *) kept="$kept $a" ;; esac
        done
        {
            printf 'ADDRS=%s\n' "${kept# }"
            [ -n "$gp" ] && printf 'GATEWAY=%s\n' "$gp"
        } > "$STATE_FILE"
    fi
fi

# Bridge netfilter is irrelevant (and can drop frames) for a plain L2 bridge;
# write the sysctl where the module exposes it.
if [ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
    echo 0 > /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || true
fi

log "uplink $HOST_IF is now a port of $BRIDGE_IF"
ip -o link show "$BRIDGE_IF" | sed 's/^/zd1200-net:   /'
