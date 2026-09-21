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

# The specific regression: the tcp-table detail must not print to stdout.
if grep -nE '(echo|printf).*ZD-NET-TCP' "$TMP/S98zd_container_control" | grep -v '/dev/ttyS1' >"$TMP/net"; then
    cat "$TMP/net" >&2
    fail "a ZD-NET-TCP-* line is written without a /dev/ttyS1 redirect"
fi
pass "the ZD-NET-TCP-* detail lines are redirected"

echo
echo "all guest control-hook tests passed"
