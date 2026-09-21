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

# guest_mac_seed() used to live here too, XORing 1 into the last octet of the
# container's MAC, and it had no callers.  That rule is gone.  The live rules are
# in zd1200-ct-bootstrap.sh:
#   * shared (LXC default): the guest wears the container's own uplink MAC, and
#     the container cross-connects the uplink instead of enslaving it, so no
#     bridge port's own-MAC FDB entry can shadow the guest;
#   * unshared: guest_mac_seed() clears the low bit of a fresh random draw.
# Do not reintroduce a copy here.

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

# --- install inputs ----------------------------------------------------------
# The installers take their input(s) positionally: a firmware upgrade file (the
# classic single-argument install), a ZD configuration backup, or a ZoneDirector
# card/disk dump; and, when the input is a backup or a non-ZD1200 dump, the
# firmware upgrade file as a second argument.  --source/--firmware, --backup and
# --writable-from remain accepted as named aliases.
#
# resolve_inputs reads the caller's POSITIONALS array and OPT_* variables and
# sets:
#   INPUT_KIND     firmware-only | backup | zd1200-dump | foreign-dump
#   INPUT_PATH     the backup or dump (empty for firmware-only)
#   FIRMWARE_PATH  the firmware upgrade file (empty for a bare ZD1200 dump)
# It dies with one of the three documented errors otherwise.

COMMON_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The vendor's compatibility unit: releases are interchangeable up to their first
# three components (getValidVer/isSameVer in /bin/sys_wrapper.sh).
version_3() { printf '%s' "$1" | awk -F. 'NF >= 3 { print $1 "." $2 "." $3 }'; }

# decrypt_payload <input> <out>: leave a gzip tar in <out>.  A backup and a
# firmware share the TAC container; an already-decrypted *.tgz is copied as-is.
decrypt_payload() {
    local src="$1" out="$2"
    if gzip -t "$src" >/dev/null 2>&1; then cp -f "$src" "$out"; return 0; fi
    command -v python3 >/dev/null 2>&1 || return 1
    python3 "$COMMON_REPO_ROOT/scripts/build/tac-decrypt.py" "$src" "$out" >/dev/null 2>&1
}

# metadata_of <gzip-tar> <key>
metadata_of() {
    tar -xzf "$1" -O metadata 2>/dev/null | awk -F= -v k="$2" '$1 == k { print $2; exit }'
}

# classify_config_input <path>: firmware | backup | zd1200-dump | foreign-dump |
# unknown.  The file's own shape decides, not its name: a card dump by its disk
# geometry, a firmware or backup by decrypting a small TAC/gzip archive and
# reading its metadata (a firmware archive is >100 MB and a backup is under a
# few MB, so only the small one is worth decrypting; the size is itself the
# distinguishing shape).
classify_config_input() {
    local f="$1" size head magic tmp meta offset=0
    [ -f "$f" ] || { printf 'unknown'; return 0; }
    size="$(stat -c%s "$f" 2>/dev/null || echo 0)"
    head="$(dd if="$f" bs=1 count=16 status=none 2>/dev/null | tr -d '\0')"
    # ImageUSB (the Windows dump tool) puts a 512-byte header on the image; it is
    # used for a ZD1200 card and for ZD1100/ZD3000 cards alike, so it decides the
    # offset, not the model.  Only the ZD1200's exact geometry is self-contained.
    [ "${head#imageUSB}" != "$head" ] && offset=512
    if [ "$((size - offset))" = "$CF_DISK_SIZE" ]; then
        printf 'zd1200-dump'; return 0
    fi
    magic="$(dd if="$f" bs=1 count=3 status=none 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    case "$magic" in
        36914a|1f8b08)
            # TAC-encrypted (or already-decrypted gzip) firmware/backup archive.
            if [ "$size" -lt 33554432 ]; then
                tmp="$(mktemp "${TMPDIR:-/tmp}/zd-kind.XXXXXX")"
                if decrypt_payload "$f" "$tmp" && gzip -t "$tmp" >/dev/null 2>&1; then
                    meta="$(tar -xzf "$tmp" -O metadata 2>/dev/null || true)"
                    rm -f "$tmp"
                    case "$meta" in *PURPOSE=backup*)    printf 'backup';   return 0 ;; esac
                    case "$meta" in *REQUIRE_PLATFORM=*) printf 'firmware'; return 0 ;; esac
                    printf 'unknown'; return 0
                fi
                rm -f "$tmp"
                printf 'unknown'; return 0
            fi
            printf 'firmware'; return 0 ;;
    esac
    # A raw disk whose own vendor partition table yields a /writable is a card
    # dump whose geometry is not the ZD1200's (a ZD1100/ZD3000 card).
    if command -v python3 >/dev/null 2>&1 \
       && python3 "$COMMON_REPO_ROOT/scripts/build/find-cf-partition.py" "$f" "$offset" >/dev/null 2>&1; then
        printf 'foreign-dump'; return 0
    fi
    printf 'unknown'
}

# input_release <path> <kind>: the release prefix, for the "which firmware"
# error.  Best effort: prints nothing when it cannot be read.
input_release() {
    local f="$1" kind="$2" tmp v offset
    case "$kind" in
        backup)
            tmp="$(mktemp "${TMPDIR:-/tmp}/zd-rel.XXXXXX")"
            if decrypt_payload "$f" "$tmp"; then v="$(metadata_of "$tmp" VERSION)"; fi
            rm -f "$tmp"
            [ -n "${v:-}" ] && version_3 "$v" ;;
        *-dump)
            offset=0
            if [ "$(dd if="$f" bs=1 count=16 status=none 2>/dev/null | tr -d '\0')" = imageUSB ]; then
                offset=512
            fi
            v="$("$COMMON_REPO_ROOT/scripts/build/dump-rootfs-version.sh" "$f" "$offset" 2>/dev/null | head -n1 || true)"
            [ -n "$v" ] && version_3 "$v" ;;
    esac
}

# resolve_inputs: see the block comment above.  Reads POSITIONALS, OPT_FIRMWARE,
# OPT_BACKUP and OPT_WRITABLE from the caller; sets INPUT_KIND, INPUT_PATH and
# FIRMWARE_PATH, or dies.
resolve_inputs() {
    local p kind what rel
    local config_paths=() firmware_paths=() unknown=()
    INPUT_KIND=""; INPUT_PATH=""; FIRMWARE_PATH=""

    for p in "${POSITIONALS[@]}"; do
        kind="$(classify_config_input "$p")"
        case "$kind" in
            backup|zd1200-dump|foreign-dump) config_paths+=("$kind|$p") ;;
            firmware)                        firmware_paths+=("$p") ;;
            *)                               unknown+=("$p") ;;
        esac
    done
    [ -n "${OPT_BACKUP:-}" ]   && config_paths+=("backup|$OPT_BACKUP")
    [ -n "${OPT_WRITABLE:-}" ] && config_paths+=("foreign-dump|$OPT_WRITABLE")
    [ -n "${OPT_FIRMWARE:-}" ] && firmware_paths+=("$OPT_FIRMWARE")

    if [ "${#config_paths[@]}" -gt 1 ]; then
        local list="" p
        for p in "${config_paths[@]}"; do list+="${p##*|} ($(case "${p%%|*}" in backup) echo "backup";; *) echo "dump";; esac)), "; done
        die "pass a backup or a dump, not both: ${list%, }"
    fi
    if [ "${#firmware_paths[@]}" -gt 1 ]; then
        die "pass only one firmware upgrade file"
    fi
    if [ "${#unknown[@]}" -gt 0 ] && [ "${#config_paths[@]}" -eq 0 ] && [ "${#firmware_paths[@]}" -eq 0 ]; then
        die "${unknown[0]} is not a ZD1200 firmware upgrade file, a ZD configuration backup or a ZoneDirector dump"
    fi

    FIRMWARE_PATH="${firmware_paths[0]:-}"
    if [ "${#config_paths[@]}" -eq 1 ]; then
        INPUT_KIND="${config_paths[0]%%|*}"
        INPUT_PATH="${config_paths[0]##*|}"
    else
        INPUT_KIND="firmware-only"
    fi

    if [ "$INPUT_KIND" = "firmware-only" ]; then
        [ -n "$FIRMWARE_PATH" ] \
            || die "no input: pass a firmware upgrade file, a configuration backup or a card dump"
        return 0
    fi

    if [ -z "$FIRMWARE_PATH" ]; then
        case "$INPUT_KIND" in
            backup)       what="a ZD configuration backup" ;;
            foreign-dump) what="a ZoneDirector dump" ;;
            zd1200-dump)  return 0 ;;   # the dump carries its own rootfs
        esac
        rel="$(input_release "$INPUT_PATH" "$INPUT_KIND" || true)"
        if [ -n "$rel" ]; then
            die "$INPUT_PATH is $what of release $rel: a firmware (version $rel) must also be passed to the installer"
        fi
        die "$INPUT_PATH is $what: a ZD1200 firmware upgrade file of the same release must also be passed to the installer"
    fi
    return 0
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
