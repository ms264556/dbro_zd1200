#!/usr/bin/env python3
"""Learn the ZD guest's dynamic DHCP lease from inside the container.

The macvtap guest shares the LAN L2 with the container's macvlan eth0.  Because
macvlan isolates sibling devices on the same parent, the container cannot reach
the guest by IP directly (nor ARP-scan a sibling), so the only reliable way to
learn the guest's dynamic lease is to watch the DHCP exchange on the L2.

A DHCP client that does not yet have an IP sets the broadcast flag, so the
server's BOOTREPLY (offer/ack) is sent to 255.255.255.255 and the macvlan
bridge delivers it to every child — including this container's eth0.  This
helper captures those replies on eth0 (AF_PACKET, needs CAP_NET_RAW granted via
cap_add: NET_RAW), and for any reply whose client MAC (chaddr) equals the
guest's MAC it writes the leased IP (yiaddr) to <out-file> and echoes the IP.

Usage:
    sniff-guest-dhcp.py <guest-mac> <out-file> [window-secs]

Prints `guest leased IP: <ip>` on stdout when found and writes the bare IP to
<out-file>.  Exits 0 once found, or after the window (default 900s) if no lease
is observed.  Intended to run in the background from run-zd1200-web.sh.
"""
import socket
import struct
import sys
import time


def mac_str(b):
    return ":".join("%02x" % x for x in b)


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    guest_mac = sys.argv[1].strip().lower()
    out_file = sys.argv[2]
    window = float(sys.argv[3]) if len(sys.argv) > 3 else 900.0
    iface = "eth0"

    target = bytes(int(x, 16) for x in guest_mac.split(":"))

    # AF_PACKET raw socket; CAP_NET_RAW is required (granted via NET_RAW).
    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003))
    sock.bind((iface, 0))
    sock.settimeout(1.0)

    deadline = time.time() + window
    while time.time() < deadline:
        try:
            data, _ = sock.recvfrom(2048)
        except socket.timeout:
            continue
        except OSError:
            continue
        if len(data) < 14 + 20 + 8 + 34:  # eth + min IP + UDP + min BOOTP
            continue
        ihl = (data[14] & 0x0F) * 4
        if ihl < 20:
            continue
        if data[23] != 17:                 # UDP only
            continue
        udp = 14 + ihl
        sport = struct.unpack("!H", data[udp:udp + 2])[0]
        dport = struct.unpack("!H", data[udp + 2:udp + 4])[0]
        if sport != 67 or dport != 68:     # server -> client
            continue
        dhcp = udp + 8
        if len(data) < dhcp + 236:
            continue
        if data[dhcp] != 2:                # BOOTREPLY
            continue
        yiaddr = socket.inet_ntoa(data[dhcp + 16:dhcp + 20])
        chaddr = data[dhcp + 28:dhcp + 34]
        if mac_str(chaddr) != guest_mac:
            continue
        print("guest leased IP: %s" % yiaddr)
        with open(out_file, "w") as f:
            f.write(yiaddr + "\n")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
