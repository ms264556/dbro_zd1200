#!/usr/bin/env bash
#
# dump-board-serial-test.sh — a card dump's own board serial must reach the guest
# disk on EVERY install path, and must not be invented when there is no record.
#
# A ZD1200 card dump is the appliance's own CompactFlash card, so it carries the
# board serial the dead unit had.  prepare-vendor-image.sh writes that record to
# $IMAGE_DIR/dump-boarddata when the input is a card dump, and the Docker/VM CLI
# path reuses the serial from it (entrypoint.sh:335-340) so the restored
# appliance keeps its identity.  The LXC bootstrap's own disk build did not, so
# the same dump restored through Proxmox came up under a serial derived from the
# container MAC (zd1200-ct-bootstrap.sh's dump_board_serial() closes that).
#
# This is the unit half: the function that reads the record.  What the serial is
# used for is prepare-vm-disks.sh's board-data write, which takes ZD_SERIAL --
# pinned by prepare-vm-disks.sh's own call here.
#
# No firmware, no dump contents, no container: the fixtures are the record's
# shapes.
#
# Usage: ./scripts/test/dump-board-serial-test.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../container" && pwd)"
BOOTSTRAP="$BASE/proxmox/zd1200-ct-bootstrap.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-dumpserial.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

[ -f "$BOOTSTRAP" ] || fail "not found: $BOOTSTRAP"

# The bootstrap carries out its install steps at the top level, so lift the
# helper out rather than sourcing the script (same style as guest-mac-seed-test.sh).
sed -n '/^dump_board_serial() {/,/^}/p' "$BOOTSTRAP" > "$TMP/fn.sh"
grep -q '^dump_board_serial()' "$TMP/fn.sh" \
    || fail "dump_board_serial() not found in $BOOTSTRAP"
# shellcheck source=/dev/null
. "$TMP/fn.sh"

# --- 1. a dump's record is used verbatim -------------------------------------
printf 'SERIAL=987654000321\nMAC1=02:aa:bb:cc:dd:ee\n' > "$TMP/record"
got="$(dump_board_serial "$TMP/record")"
[ "$got" = "987654000321" ] \
    || fail "a dump's serial was not read (got '$got', want 987654000321)"
pass "a card dump's own serial is used ($got)"

# --- 2. a record without a serial invents nothing ----------------------------
printf 'MAC1=02:aa:bb:cc:dd:ee\n' > "$TMP/noserial"
got="$(dump_board_serial "$TMP/noserial")"
[ -z "$got" ] \
    || fail "a record with no SERIAL line produced '$got' (want empty)"
pass "a record with no serial leaves the caller's serial alone"

# --- 3. no record at all is not an error -------------------------------------
got="$(dump_board_serial "$TMP/does-not-exist")"
[ -z "$got" ] || fail "a missing record produced '$got' (want empty)"
pass "no dump record is skipped, not fatal"

# --- 4. the bootstrap actually applies it to ZD_SERIAL -----------------------
# Without this the function could be extracted and tested while the install path
# ignored it -- the exact shape of the defect being fixed.
grep -q 'ZD_SERIAL="\$dump_serial"' "$BOOTSTRAP" \
    || fail "the bootstrap reads the dump serial but never puts it in ZD_SERIAL"
grep -q 'dump_board_serial "\$IMAGE_DIR/dump-boarddata"' "$BOOTSTRAP" \
    || fail "the bootstrap does not read the record prepare-vendor-image.sh writes"
pass "the LXC disk build uses it for ZD_SERIAL, from \$IMAGE_DIR/dump-boarddata"

echo
echo "all dump-board-serial tests passed"
