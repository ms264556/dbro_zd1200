#!/usr/bin/env bash
# Derive the ZD1200 guest's board-data identity from the container's eth0 MAC.
#
# The container runs on a macvlan network: its eth0 has a Docker-assigned MAC
# and, via the entrypoint's udhcpc, its own DHCP lease.  The QEMU guest shares
# that same LAN L2 through a macvtap, and the vendor v54bsp driver forces the
# board-data base MAC (MAC1) onto the guest NIC.  So the guest must use a MAC
# DISTINCT from the container's eth0 MAC, otherwise the guest NIC and eth0 share
# one identity and both grab the same DHCP lease.
#
# To keep the guest unique per container instance without colliding with the
# container's own MAC, the guest base MAC is derived by nudging the container's
# eth0 MAC forward by one (guest MAC1 = container MAC + 1); MAC2 = MAC1 + 1.
# The serial number is hashed from the guest MAC1, so each instance is unique.
#
# Serial format (matches the physical appliance): "5" + 11 digits = 12 chars.
# The 11 digits come from the first 8 hex chars of SHA-256(MAC1), reduced
# modulo 100000000000.
#
# Prints source-able KEY=VALUE lines:
#   MAC=<guest base MAC, MAC1>
#   MAC2=<MAC1 + 1>
#   SERIAL=<12-char serial>
set -euo pipefail

container_mac="$(ip link show eth0 2>/dev/null | awk '/ether/{print $2; exit}')"
if [ -z "$container_mac" ]; then
    echo "ERROR: cannot read a MAC from eth0 (is the container on a macvlan network?)" >&2
    exit 1
fi
container_mac="$(printf '%s' "$container_mac" | tr '[:upper:]' '[:lower:]')"

# Guest MAC1 = container eth0 MAC + 1 (carry over the last octet).  This is a
# locally administered, UNICAST address (macvlan parent MACs are locally
# administered), stays distinct from the container's own eth0 MAC, and is the
# one the vendor v54bsp driver forces onto the guest NIC.
v=$((0x$(printf '%s' "$container_mac" | tr -d ':')))
v=$(((v + 1) & 0xFFFFFFFFFFFF))
mac="$(printf '%012x' "$v" | sed 's/\(..\)/\1:/g;s/:$//')"

# Serial: hash the guest MAC1, take the low 32 bits, fit into 11 digits, prefix "5".
hash="$(printf '%s' "$mac" | sha256sum | awk '{print $1}')"
decimal=$((0x${hash:0:8}))
eleven_digits=$((decimal % 100000000000))
serial="5$(printf '%011d' "$eleven_digits")"

# MAC2 = MAC1 + 1 (carry over the last octet), same rule as write-boarddata.py.
v=$((0x$(printf '%s' "$mac" | tr -d ':')))
v=$(((v + 1) & 0xFFFFFFFFFFFF))
mac2="$(printf '%012x' "$v" | sed 's/\(..\)/\1:/g;s/:$//')"

echo "MAC=$mac"
echo "MAC2=$mac2"
echo "SERIAL=$serial"
