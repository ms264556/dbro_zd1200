#!/usr/bin/env bash
#
# lxc-dump-stage-test.sh — the Proxmox installer caps a staged dump, and caps
# only a dump.
#
# Unlike Docker (which bind-mounts its inputs read-only), the Proxmox installer
# copies the input into the container with pct push, into a 20 GiB rootfs.  A
# disk physically larger than its own appliance layout would therefore not fit,
# so a dump is staged through its first 8 GiB only.  stage_cap_for decides which
# staged input gets that cap: the dump does, a firmware or a configuration
# backup must never be truncated.
#
# The function is extracted from the installer rather than sourced, because the
# installer has no main guard -- running it would create a container.  The same
# text-extraction shape as installer-options-test.sh's parsed_options.
#
# Usage: ./scripts/test/lxc-dump-stage-test.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$REPO/install-zd1200-lxc.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

[ -f "$INSTALLER" ] || fail "missing $INSTALLER"

# --- the cap -----------------------------------------------------------------
# Evaluated rather than matched, so reformatting the literal does not break it.
cap_line="$(grep -m1 '^DUMP_STAGE_BYTES=' "$INSTALLER")"
[ -n "$cap_line" ] || fail "no DUMP_STAGE_BYTES in the installer; was it renamed?"
( eval "$cap_line"; [ "$DUMP_STAGE_BYTES" = "$((8 * 1024 * 1024 * 1024))" ] ) \
    || fail "the dump staging cap is not 8 GiB"
pass "the staging cap is 8 GiB"

# --- the per-input decision --------------------------------------------------
body="$(sed -n '/^stage_cap_for() {/,/^}/p' "$INSTALLER")"
[ -n "$body" ] || fail "could not extract stage_cap_for; was it renamed?"
eval "$body"

eval "$cap_line"
DUMP=/x/zd3000_dump.img
INPUT_PATH="$DUMP"
rc=0
check() { # check <kind> <path> <expected>
    INPUT_KIND="$1"
    local got
    got="$(stage_cap_for "$2")"
    if [ "$got" != "$3" ]; then
        echo "FAIL $1 $2: got '$got', expected '$3'" >&2
        rc=1
    fi
}
# The dump carries the cap, however it is passed (a bare ZD1200 dump is the
# positional; a foreign dump is --writable-from).
check zd1200-dump   "$DUMP"            8589934592
check foreign-dump  "$DUMP"            8589934592
# The firmware that accompanies a foreign dump is staged whole.
check foreign-dump  /x/firmware.img    0
check zd1200-dump   /x/firmware.img    0
check firmware-only /x/firmware.img    0
# So is a configuration backup.
check backup        /x/ruckus_db.bak   0
# No dump at all is the firmware-only shape.
INPUT_PATH=""
check zd1200-dump   /x/zd3000_dump.img 0
[ "$rc" = 0 ] || exit 1
pass "only the dump is capped"

echo
echo "all lxc-dump-stage tests passed"
