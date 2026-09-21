#!/usr/bin/env bash
#
# install-inputs-test.sh — unit test for the installers' input rules
# (resolve_inputs in scripts/install-common.sh).
#
# The installers take their inputs positionally and classify each by its
# contents: a firmware upgrade file, a ZD configuration backup (whose metadata
# says PURPOSE=backup), a ZD1200 card dump (the card's exact disk size), or a
# foreign dump.  A backup or a foreign dump needs a firmware of the same release;
# a ZD1200 dump is self-contained; and two configuration inputs are refused.
# No firmware, no dump contents and no Docker/Proxmox are needed: the fixtures
# are the shapes the classifier reads.
#
# Usage: ./scripts/test/install-inputs-test.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-inputs.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../install-common.sh
. "$BASE/install-common.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

# --- fixtures ----------------------------------------------------------------
# A configuration backup: a gzip tar whose metadata says PURPOSE=backup.
mkdir -p "$TMP/bak/etc/airespider"
printf 'PURPOSE=backup\nVERSION=10.4.1.0\nBUILD=272\nPLATFORM=COB7402\nAPMODEL=ZD1200\n' > "$TMP/bak/metadata"
printf '<system/>\n' > "$TMP/bak/etc/airespider/system.xml"
tar -C "$TMP/bak" -czf "$TMP/ruckus_db_040623.bak" metadata etc

# A firmware upgrade file: a gzip tar whose metadata describes a firmware.
mkdir -p "$TMP/fw"
printf 'REQUIRE_PLATFORM=nar5520\nREQUIRE_SUBPLATFORM=cob7402\nVERSION=10.5.1.0\nBUILD=282\n' > "$TMP/fw/metadata"
tar -C "$TMP/fw" -czf "$TMP/zd1200_10.5.1.0.282.img" metadata

# A ZD1200 card dump: the classifier's signature is the card's exact size.
dump="$TMP/zd1200_10.5.1.0.240_cfcard_dump.img"
truncate -s "$CF_DISK_SIZE" "$dump"

# A large opaque archive is taken as a firmware (a backup is never this big).
large="$TMP/opaque-firmware.img"
truncate -s 40M "$large"
printf '\x36\x91\x4a' | dd of="$large" bs=1 conv=notrunc status=none

# An ImageUSB header does not make a dump a ZD1200 one: the Windows tool writes
# it for every card, and only the ZD1200's own geometry is self-contained.  This
# foreign-sized image with no vendor partition table is therefore unrecognised,
# not a ZD1200 dump.
foreignish="$TMP/foreign_imageusb.bin"
truncate -s 10M "$foreignish"
printf 'imageUSB' | dd of="$foreignish" bs=1 conv=notrunc status=none

unknown="$TMP/notes.txt"
printf 'not an installer input\n' > "$unknown"

# --- resolver ----------------------------------------------------------------
# resolve <description> <positionals...>: run resolve_inputs in a subshell and
# print either "OK kind|input|firmware" or the error.  OPT_* are cleared.
resolve() {
    local label="$1"; shift
    local out rc
    out="$( { POSITIONALS=("$@"); OPT_FIRMWARE=""; OPT_BACKUP=""; OPT_WRITABLE=""; \
              resolve_inputs; printf 'OK %s|%s|%s' "$INPUT_KIND" "${INPUT_PATH##*/}" "${FIRMWARE_PATH##*/}"; } 2>&1 )"
    rc=$?
    printf '%-26s rc=%s %s\n' "$label" "$rc" "$out"
}
expect_ok() { # expect_ok <label> <want-fields> <positionals...>
    local label="$1" want="$2"; shift 2
    local got; got="$(resolve "$label" "$@")"
    case "$got" in *"rc=0 OK $want") ;; *) fail "$label: $got" ;; esac
}
expect_err() { # expect_err <label> <substring> <positionals...>
    local label="$1" sub="$2"; shift 2
    local got; got="$(resolve "$label" "$@")"
    case "$got" in
        *"rc=0 "*) fail "$label: expected an error, got: $got" ;;
        *"$sub"*)  ;;
        *) fail "$label: error did not mention '$sub': $got" ;;
    esac
}

# --- firmware alone is still the classic install -----------------------------
expect_ok "firmware only" "firmware-only||zd1200_10.5.1.0.282.img" "$TMP/zd1200_10.5.1.0.282.img"
pass "a firmware alone is a complete appliance"

expect_ok "large opaque = firmware" "firmware-only||opaque-firmware.img" "$large"
pass "a large opaque TAC archive is taken as a firmware"

# --- a backup or a foreign dump needs its firmware ---------------------------
expect_err "backup without firmware" "of release 10.4.1" "$TMP/ruckus_db_040623.bak"
expect_err "backup without firmware" "must also be passed" "$TMP/ruckus_db_040623.bak"
pass "a backup without a firmware names the release to pass"

expect_ok "backup + firmware" "backup|ruckus_db_040623.bak|zd1200_10.5.1.0.282.img" \
    "$TMP/ruckus_db_040623.bak" "$TMP/zd1200_10.5.1.0.282.img"
expect_ok "firmware + backup (order free)" "backup|ruckus_db_040623.bak|zd1200_10.5.1.0.282.img" \
    "$TMP/zd1200_10.5.1.0.282.img" "$TMP/ruckus_db_040623.bak"
pass "a backup pairs with a firmware in either order"

# --- a ZD1200 dump carries its own rootfs ------------------------------------
expect_ok "zd1200 dump only" "zd1200-dump|zd1200_10.5.1.0.240_cfcard_dump.img|" "$dump"
expect_ok "zd1200 dump + firmware" "zd1200-dump|zd1200_10.5.1.0.240_cfcard_dump.img|zd1200_10.5.1.0.282.img" \
    "$dump" "$TMP/zd1200_10.5.1.0.282.img"
pass "a ZD1200 dump needs no firmware, and pairs with one when given"

# --- the rules' errors -------------------------------------------------------
expect_err "backup + dump" "pass a backup or a dump, not both" \
    "$TMP/ruckus_db_040623.bak" "$dump"
expect_err "two firmwares" "only one firmware" \
    "$TMP/zd1200_10.5.1.0.282.img" "$large"
expect_err "unknown input" "is not a ZD1200 firmware" "$unknown"
expect_err "foreign imageUSB header" "is not a ZD1200 firmware" "$foreignish"
pass "both-inputs, two-firmwares and unrecognised inputs are refused"

# --- the --backup/--writable-from aliases feed the same rules ----------------
aliased="$( { POSITIONALS=("$dump"); OPT_FIRMWARE=""; OPT_BACKUP="$TMP/ruckus_db_040623.bak"; OPT_WRITABLE=""; \
              resolve_inputs; printf 'OK %s' "$INPUT_KIND"; } 2>&1 )" || true
case "$aliased" in *"pass a backup or a dump"*) ;; *) fail "alias: wrong result: $aliased" ;; esac
pass "the named aliases feed the same both-inputs rule"

echo
echo "all install-inputs tests passed"
