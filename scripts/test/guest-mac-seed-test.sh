#!/usr/bin/env bash
#
# guest-mac-seed-test.sh — the guest's MAC1 must be even, and MAC2 = MAC1 + 1
# must be the next odd number in the same prefix.
#
# The old rule XORed the last octet of the *container's* MAC with 1.  That made
# MAC1 even only when the container's was odd, and in exactly that half of cases
# it put MAC2 on the container's own port MAC -- a bridge delivers traffic
# addressed to a port's own MAC to that port, so the guest's traffic is dropped
# before it reaches the guest.
#
# Usage: ./scripts/test/guest-mac-seed-test.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../container" && pwd)"
BOOTSTRAP="$BASE/proxmox/zd1200-ct-bootstrap.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-guestmac.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

[ -f "$BOOTSTRAP" ] || fail "not found: $BOOTSTRAP"

# The bootstrap carries out its install steps at the top level, so lift the
# helpers out rather than sourcing the script.
sed -n '/^localise_mac() {/,/^}/p;/^random_local_mac() {/,/^}/p;/^guest_mac_seed() {/,/^}/p' \
    "$BOOTSTRAP" > "$TMP/fn.sh"
for fn in localise_mac random_local_mac guest_mac_seed; do
    grep -q "^$fn()" "$TMP/fn.sh" || fail "$fn() not found in $BOOTSTRAP"
done
# shellcheck source=/dev/null
. "$TMP/fn.sh"

is_mac() { printf '%s' "$1" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; }
mac2_of() {
    local v
    v=$((0x$(printf '%s' "$1" | tr -d ':')))
    v=$(((v + 1) & 0xFFFFFFFFFFFF))
    printf '%012x' "$v" | sed 's/\(..\)/\1:/g;s/:$//'
}

# --- guest_mac_seed, over every possible last octet -------------------------
for d in $(seq 0 255); do
    seed="bc:24:11:2e:c9:$(printf '%02x' "$d")"
    m1="$(guest_mac_seed "$seed")"
    is_mac "$m1" || fail "guest_mac_seed $seed -> '$m1' is not a MAC"

    # MAC1 even, so MAC2 = MAC1 + 1 is odd and cannot carry.
    [ "$(( 0x${m1##*:} & 1 ))" = 0 ] || fail "MAC1 is odd for seed $seed -> $m1"

    m2="$(mac2_of "$m1")"
    is_mac "$m2" || fail "MAC2 '$m2' is not a MAC for seed $seed"
    [ "${m1%:*}" = "${m2%:*}" ] \
        || fail "MAC2 left MAC1's prefix for seed $seed: $m1 / $m2"
    [ "$m2" != "$m1" ] || fail "MAC2 equals MAC1 for seed $seed"

    # The rule is exactly "clear the low bit of the last octet".
    want="$(printf '%s:%02x' "${seed%:*}" "$(( 0x${seed##*:} & 0xFE ))")"
    [ "$m1" = "$want" ] || fail "guest_mac_seed $seed -> $m1, want $want"
done
pass "all 256 last octets: MAC1 even, MAC2 = MAC1 + 1 in the same prefix"

# --- an already-even seed is used exactly as drawn --------------------------
for seed in bc:24:11:2e:c9:90 bc:24:11:2e:c9:00 bc:24:11:2e:c9:fe; do
    [ "$(guest_mac_seed "$seed")" = "$seed" ] \
        || fail "an already-even seed was altered: $seed -> $(guest_mac_seed "$seed")"
done
pass "an already-even seed is left untouched (one draw, no re-drawing)"

# --- a last octet of 0xff cannot carry into MAC2 ----------------------------
[ "$(guest_mac_seed bc:24:11:2e:c9:ff)" = "bc:24:11:2e:c9:fe" ] \
    || fail "0xff did not round down to 0xfe"
[ "$(mac2_of bc:24:11:2e:c9:fe)" = "bc:24:11:2e:c9:ff" ] \
    || fail "MAC2 of the 0xfe case is wrong"
pass "the 0xff case stays in the fifth octet"

# --- random_local_mac, the no-seed fallback ---------------------------------
for _ in 1 2 3 4 5 6; do
    m="$(random_local_mac)"
    is_mac "$m" || fail "random_local_mac -> '$m' is not a MAC"
    [ "$(( 0x${m%%:*} & 0x02 ))" = 2 ] || fail "random_local_mac $m is not locally administered"
    [ "$(( 0x${m%%:*} & 0x01 ))" = 0 ] || fail "random_local_mac $m is multicast"
    [ "$(( 0x${m##*:} & 1 ))" = 0 ] || fail "random_local_mac $m has an odd last octet"
done
pass "random_local_mac: locally administered, unicast, even last octet"

a="$(random_local_mac)"; b="$(random_local_mac)"
[ "$a" != "$b" ] || fail "random_local_mac repeated itself"
pass "random_local_mac does not repeat"

echo
echo "all guest-MAC tests passed"
