#!/usr/bin/env bash
# Derive the ZD1200 board-data identity from the container's eth0 MAC.
#
# In macvlan mode Docker allocates the container's eth0 (macvlan) interface a
# MAC of its own on the LAN.  That MAC is the identity of this virtual
# appliance: it becomes MAC1 in the board data (MAC2 = MAC1 + 1), and it is
# hashed into the serial number so every container instance is unique.
#
# Serial format (matches the physical appliance): "5" + 11 digits = 12 chars.
# The 11 digits come from the first 8 hex chars of SHA-256(MAC), reduced
# modulo 100000000000.
#
# Prints source-able KEY=VALUE lines:
#   MAC=<base MAC, MAC1>
#   MAC2=<MAC1 + 1>
#   SERIAL=<12-char serial>
set -euo pipefail

mac="$(ip link show eth0 2>/dev/null | awk '/ether/{print $2; exit}')"
if [ -z "$mac" ]; then
    echo "ERROR: cannot read a MAC from eth0 (is the container on a macvlan network?)" >&2
    exit 1
fi
mac="$(printf '%s' "$mac" | tr '[:upper:]' '[:lower:]')"

# Serial: hash the MAC, take the low 32 bits, fit into 11 digits, prefix "5".
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
