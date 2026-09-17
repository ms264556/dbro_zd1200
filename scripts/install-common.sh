#!/usr/bin/env bash
#
# scripts/install-common.sh — helpers shared by the two entry points:
#
#   install-zd1200-docker.sh   (Docker)
#   install-zd1200-lxc.sh      (Proxmox VE, LXC)
#
# Sourced, never executed: the installers own argument parsing and platform
# plumbing, and only the things that must behave identically on both platforms
# live here.  Sourcing is done by path, so both entry points must ship this
# directory.

# --- console -----------------------------------------------------------------
# Same wording on both platforms, so a user's notes stay valid.
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
info() { printf '%s\n' "$*"; }

# --- addresses ---------------------------------------------------------------
# The guest's board-data MAC1 is derived from a container MAC seed.  On Docker
# the seed is generated into .env; on LXC it comes from the address Proxmox
# allocates for the container's veth.

is_mac() {
    printf '%s' "${1:-}" | grep -qE '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$'
}

# random_mac [first-octet-hex]: a MAC from independent random octets.  The default
# first octet (0x02) is locally administered and unicast, so the value is valid on
# any LAN.  Two calls never share octets, so the results cannot collapse onto each
# other the way same-bytes-with-flipped-bit schemes do.
random_mac() {
    local first="${1:-02}" hex
    hex="$(od -An -N5 -tx1 /dev/urandom | tr -d ' \n')"
    printf '%s:%s:%s:%s:%s:%s\n' "$first" \
        "${hex:0:2}" "${hex:2:2}" "${hex:4:2}" "${hex:6:2}" "${hex:8:2}"
}

# localise_mac <mac>: set the locally-administered bit.
localise_mac() {
    local mac="$1" o1 rest
    IFS=: read -r o1 rest <<<"$mac"
    printf '%02x:%s\n' "$(( 0x$o1 | 0x02 ))" "$rest"
}

# guest_mac_seed <container-uplink-mac>: the MAC the guest's board data is built
# from.  It must differ from the container's own uplink MAC: on Docker the
# container's interface is a macvtap and invisible to the LAN, but on LXC the
# veth IS a LAN port, and a guest sharing its MAC is offered the address the
# container already holds — which it then refuses, looping on DISCOVER forever.
# Flipping the last octet guarantees a difference while inheriting uniqueness.
guest_mac_seed() {
    local mac="$1" prefix last
    prefix="$(printf '%s' "$mac" | cut -d: -f1-5)"
    last="$(printf '%s' "$mac" | awk -F: '{print $6}')"
    if [ -n "$prefix" ] && [ -n "$last" ]; then
        printf '%s:%02x\n' "$prefix" "$(( 0x$last ^ 0x01 ))"
    else
        localise_mac "$mac"
    fi
}

# --- input classification ----------------------------------------------------
# A ZD1200 CompactFlash is a raw 1872 MiB disk; a Windows ImageUSB dump is the
# same image behind a 512-byte "imageUSB" header.  Mirrors the sizes in
# scripts/container/build-synthetic-cf.py.

CF_DISK_SIZE=$((3931200 * 512))

# classify_input <path>: prints "firmware", "cf-dump" or "unknown".
classify_input() {
    local f="$1" size head magic
    [ -f "$f" ] || { printf 'unknown'; return; }
    size="$(stat -c%s "$f" 2>/dev/null || echo 0)"
    head="$(dd if="$f" bs=1 count=16 status=none 2>/dev/null | tr -d '\0')"
    case "$head" in imageUSB*) printf 'cf-dump'; return ;; esac
    if [ "$size" = "$CF_DISK_SIZE" ] || [ "$size" = "$((CF_DISK_SIZE + 512))" ]; then
        printf 'cf-dump'; return
    fi
    # The TAC-encrypted upgrade files begin 0x36 0x91 0x4a (see
    # scripts/build/tac-decrypt.py); a gzipped payload is accepted too.
    magic="$(dd if="$f" bs=1 count=3 status=none 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    case "$magic" in 36914a|1f8b08) printf 'firmware'; return ;; esac
    case "$(dd if="$f" bs=1 count=3 status=none 2>/dev/null | tr -d '\0')" in
        TAC) printf 'firmware'; return ;;
    esac
    printf 'unknown'
}

# require_input <path> <label>: fail early with a readable message.
require_input() {
    local f="$1" label="${2:-input}"
    [ -e "$f" ] || die "$label not found: $f"
    [ -f "$f" ] || die "$label is not a regular file: $f"
    [ -r "$f" ] || die "$label is not readable: $f"
}

# --- SSH keys ----------------------------------------------------------------
# One accepted-key list for both platforms.  Accepts a key string or a readable
# .pub path.
read_public_key() {
    local value="$1" line
    if [ -r "$value" ]; then
        line="$(head -n1 "$value" | tr -d '\r')"
    else
        line="$value"
    fi
    case "$line" in
        ssh-rsa\ *|ssh-ed25519\ *|ecdsa-sha2-nistp256\ *|ecdsa-sha2-nistp384\ *|ecdsa-sha2-nistp521\ *)
            printf '%s\n' "$line" ;;
        *) return 1 ;;
    esac
}
