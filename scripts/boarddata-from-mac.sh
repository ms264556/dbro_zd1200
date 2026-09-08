#!/usr/bin/env bash
# Derive the ZD1200 guest's board-data identity from ZD_CONTAINER_MAC.
#
# ZD_CONTAINER_MAC is a unique, locally-administered MAC generated into .env by
# build-container.sh when the container is first created.  The guest base MAC
# (MAC1) is that value, so the guest identity is unique per instance and
# stable across container recreates; MAC2 = MAC1 + 1.  The serial is hashed from
# MAC1, so each instance presents its own appliance identity on the LAN.
#
# If ZD_CONTAINER_MAC is unset, fall back to the host's eth0 MAC (which under
# network_mode: host is the only MAC visible here) so the script still works.
#
# Serial format (matches the physical appliance): "5" + 11 digits = 12 chars.
# The 11 digits come from the first 8 hex chars of SHA-256(MAC1), reduced
# modulo 100000000000.
#
# Set ZD_BOARDDATA_FROM_MAC=0 to skip this and use the fixed ZD_SERIAL/ZD_MAC1.
#
# Prints source-able KEY=VALUE lines:
#   MAC=<guest base MAC, MAC1>
#   MAC2=<MAC1 + 1>
#   SERIAL=<12-char serial>
set -euo pipefail

container_mac="${ZD_CONTAINER_MAC:-}"
if [ -z "$container_mac" ]; then
    container_mac="$(ip link show eth0 2>/dev/null | awk '/ether/{print $2; exit}')"
    echo "warning: ZD_CONTAINER_MAC unset; falling back to the host eth0 MAC" >&2
fi
if [ -z "$container_mac" ]; then
    echo "ERROR: no ZD_CONTAINER_MAC and no eth0 MAC" >&2
    exit 1
fi
container_mac="$(printf '%s' "$container_mac" | tr '[:upper:]' '[:lower:]')"
if ! printf '%s' "$container_mac" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
    echo "ERROR: not a MAC address: $container_mac" >&2
    exit 1
fi

# Guest MAC1 is the container MAC itself: nothing on the wire uses
# ZD_CONTAINER_MAC (it is a synthesised identity, not an interface address), so
# there is nothing for the guest to collide with.
mac="$container_mac"

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
