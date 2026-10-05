#!/usr/bin/env bash
#
# control-hook-test.sh — every guest control-channel reply must go to ttyS1.
#
# 70-container-control.sh installs /etc/init.d/S98zd_container_control, a
# background loop that answers commands on ttyS1 (address, ready, diag) and runs
# the stock reboot path.  Its stdout is the container's console (ttyS0), which
# the PVE Console tab shows, so a reply written with a bare echo/printf leaks
# onto the appliance's serial console.  That happened once (service_detail()'s
# ZD-NET-TCP-* lines), and the watchdog's 60s healthcheck probe made it appear
# periodically.
#
# This reads the embedded script out of the patch and asserts that every writer
# of a ZD-* reply redirects to /dev/ttyS1, the only exception being the
# deliberate "orderly shutdown requested" notice on /dev/console.
#
# Usage: ./scripts/test/control-hook-test.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../container" && pwd)"
PATCH="$BASE/patches/70-container-control.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-hook.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

[ -f "$PATCH" ] || fail "not found: $PATCH"

# Lift the heredoc body out of the patch.
awk "/<<'ZD_CONTAINER_CONTROL'/{copy=1; next} /^ZD_CONTAINER_CONTROL\$/{copy=0} copy" \
    "$PATCH" > "$TMP/S98zd_container_control"

[ -s "$TMP/S98zd_container_control" ] || fail "could not extract the embedded hook from $PATCH"
grep -q 'ZD-GUEST-IP=' "$TMP/S98zd_container_control" || fail "extracted hook does not look like the control hook"
grep -q '/dev/ttyS1' "$TMP/S98zd_container_control" || fail "extracted hook never writes to /dev/ttyS1"
pass "the embedded control hook was extracted"

# Writers of a ZD-* reply: echo or printf whose text contains "ZD-".
mapfile -t writers < <(grep -nE '(^|[^[:alnum:]_])(echo|printf)[^|]*"?'"'"'?ZD-' "$TMP/S98zd_container_control" || true)
[ "${#writers[@]}" -gt 0 ] || fail "found no ZD-* writers; the extraction or the matcher is wrong"

leaks=()
for w in "${writers[@]}"; do
    text="${w#*:}"
    case "$text" in
        *'/dev/ttyS1'*) ;;                     # the reply goes where it should
        *'"/dev/console"'*|*' /dev/console'*) ;; # the deliberate notice
        *'ZD-CONTAINER-CONTROL:'*) ;;          # same notice, matched on its text
        *) leaks+=("$w") ;;
    esac
done

if [ "${#leaks[@]}" -gt 0 ]; then
    printf 'FAIL: control reply written without a /dev/ttyS1 redirect:\n' >&2
    printf '  %s\n' "${leaks[@]}" >&2
    exit 1
fi
pass "every ZD-* reply redirects to /dev/ttyS1 (${#writers[@]} writers checked)"

# --- guest_address() follows the controller onto a management VLAN ---------
# With a management VLAN (CLI: config > system > interface > vlan <id>) the stock
# stack moves the controller's address from br0 to the br0.<vid> device and br0
# keeps no IPv4, so a function that only looked at br0/uif0/eth0 answered
# "no address": the host-side healthcheck then reported a healthy guest as not
# responding and the Proxmox display address went stale.  A separate management
# interface (config > system > mgmt-if) is an alias, labelled br0.<vid>:<n>, and
# is not the controller's address.  The fixtures are `ip -4 -o addr show` lines in
# the guest's own iproute format.
awk '/^    guest_address\(\) \{/{copy=1} copy{print} copy && /^    \}$/{exit}' \
    "$TMP/S98zd_container_control" | sed "s#/sys/class/net#$TMP/sysnet#g" > "$TMP/guest_address.sh"
[ -s "$TMP/guest_address.sh" ] || fail "could not extract guest_address() from the hook"

DEV_ADDR='5: br0    inet 10.222.1.129/24 brd 10.222.1.255 scope global br0'
VLAN_DEV='9: br0.300    inet 172.31.30.53/24 brd 172.31.30.255 scope global br0.300'
MGMT_ALIAS='10: br0.100    inet 172.31.100.10/24 brd 172.31.100.255 scope global br0.100:0'

# addr_case <label> <expected> [dev=line ...]: the devices exist in sysfs, and
# each dev=line is what `ip -4 -o addr show dev <dev>` prints for it.
addr_case() {
    local label="$1" want="$2" got spec
    shift 2
    rm -rf "$TMP/sysnet" "$TMP/ipfix"
    mkdir -p "$TMP/sysnet" "$TMP/ipfix"
    touch "$TMP/sysnet/br0" "$TMP/sysnet/uif0" "$TMP/sysnet/eth0"
    for spec in "$@"; do
        touch "$TMP/sysnet/${spec%%=*}"
        printf '%s\n' "${spec#*=}" >> "$TMP/ipfix/${spec%%=*}"
    done
    got="$(
        ip() { cat "$TMP/ipfix/${*: -1}" 2>/dev/null || true; }
        . "$TMP/guest_address.sh"
        guest_address || true
    )"
    [ "$got" = "$want" ] || fail "guest_address ($label): got '${got}', expected '${want}'"
    pass "guest_address: $label"
}

addr_case "address on br0" 10.222.1.129 "br0=$DEV_ADDR"
addr_case "br0's address wins over a management alias" 10.222.1.129 \
    "br0=$DEV_ADDR" "br0.100=$MGMT_ALIAS"
addr_case "controller on a management VLAN (br0 has no IPv4)" 172.31.30.53 \
    "br0.300=$VLAN_DEV"
addr_case "controller on a VLAN, management interface on another" 172.31.30.53 \
    "br0.100=$MGMT_ALIAS" "br0.300=$VLAN_DEV"
addr_case "the alias is skipped even when listed before the primary" 172.31.30.53 \
    "br0.300=9: br0.300    inet 172.31.100.77/24 brd 172.31.100.255 scope global br0.300:1" \
    "br0.300=$VLAN_DEV"
addr_case "the label is not the last field (lifetimes follow it)" 172.31.30.53 \
    "br0.100=10: br0.100    inet 172.31.100.10/24 brd 172.31.100.255 scope global br0.100:0 valid_lft forever preferred_lft forever" \
    "br0.300=9: br0.300    inet 172.31.30.53/24 brd 172.31.30.255 scope global br0.300 valid_lft forever preferred_lft forever"
addr_case "only a management alias exists" 172.31.100.10 "br0.100=$MGMT_ALIAS"
addr_case "an alias on br0 itself is the last resort" 10.222.1.77 \
    "br0=3: br0    inet 10.222.1.77/24 brd 10.222.1.255 scope global br0:0"
addr_case "no address at all" ""

# The specific regression: the tcp-table detail must not print to stdout.
if grep -nE '(echo|printf).*ZD-NET-TCP' "$TMP/S98zd_container_control" | grep -v '/dev/ttyS1' >"$TMP/net"; then
    cat "$TMP/net" >&2
    fail "a ZD-NET-TCP-* line is written without a /dev/ttyS1 redirect"
fi
pass "the ZD-NET-TCP-* detail lines are redirected"

echo
echo "all guest control-hook tests passed"
