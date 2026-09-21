#!/usr/bin/env bash
#
# entitlement-payload-test.sh — the patched verify-upload-support must serve
# /tmp/support with THIS appliance's serial, derived at run time.
#
# emfd's checkSupport() loads /tmp/support and requires each <support> child's
# zd-serial-number to equal the contents of /bin/SERIAL (the only other value it
# accepts is the literal "*"); otherwise the upgrade aborts with
# E_InvalidSerialNumber.  The archived payload
# /etc/persistent-scripts/patch-storage/support carries an empty serial, so
# copying it to /tmp/support can never pass.  This test builds the patch's sed,
# applies it to a minimal vendor fixture, then runs the generated case body
# against a sandbox /bin/SERIAL and checks what it writes.
#
# Usage: ./scripts/test/entitlement-payload-test.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../container" && pwd)"
PATCH="$BASE/patches/20-signing-license.sh"
SERIAL="502213767638"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-entitlement.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

[ -f "$PATCH" ] || fail "patch not found: $PATCH"

# --- build the entitlement sed exactly as the patch does ---------------------
WORK="$TMP/work"; mkdir -p "$WORK"
sed -n '/^cat > "\$WORK\/sys_wrapper-entitlement.sed"/,/^SEDEOF$/p' "$PATCH" > "$TMP/build.sed.sh"
grep -q 'verify-upload-support' "$TMP/build.sed.sh" || fail "could not extract the entitlement sed builder"
WORK="$WORK" bash "$TMP/build.sed.sh"
[ -s "$WORK/sys_wrapper-entitlement.sed" ] || fail "the patch produced no sed file"
pass "built the entitlement sed from the patch"

# --- apply it to a minimal vendor fixture ------------------------------------
cat > "$TMP/sw.orig" <<'EOF'
#!/bin/sh
case "$1" in
    verify-upload-support)
        cd /tmp
        cat $1 | gunzip | tar x support
        echo "OK"
        ;;
    wget-support-entitlement)
        wget --no-check-certificate "https://$2" -O /tmp/$1
        ;;
esac
EOF
sed -f "$WORK/sys_wrapper-entitlement.sed" "$TMP/sw.orig" > "$TMP/sw.new"
sh -n "$TMP/sw.new" || fail "the patched script is not valid sh"
pass "the patched script parses"

grep -q '^    verify-upload-support-unpatched)$' "$TMP/sw.new" \
    || fail "the original verify-upload-support body was not preserved"
pass "the vendor body is preserved as verify-upload-support-unpatched"

# The whole bug was serving the archived payload, whose serial is empty.
if grep -q 'patch-storage/support > support' "$TMP/sw.new"; then
    fail "the patched case still copies the empty-serial archived payload"
fi
pass "the case no longer copies the archived payload verbatim"

# --- run the generated case body against a sandbox /bin/SERIAL ---------------
mkdir -p "$TMP/sb/bin" "$TMP/sb/tmp"
printf '%s\n' "$SERIAL" > "$TMP/sb/bin/SERIAL"
awk '/^    verify-upload-support\)$/{f=1;next} f&&/^        ;;$/{exit} f{print}' \
    "$TMP/sw.new" > "$TMP/body.sh"
[ -s "$TMP/body.sh" ] || fail "could not extract the generated case body"
# Point the body's absolute paths at the sandbox.  It must read whatever
# /bin/SERIAL holds at run time, which is the whole point.  Order matters: the
# /bin/SERIAL replacement is applied last so its own /tmp-prefixed result is not
# rewritten a second time.
sed -e "s#/tmp#$TMP/sb/tmp#g" \
    -e "s#/writable#$TMP/sb/writable#g" \
    -e "s#/bin/SERIAL#$TMP/sb/bin/SERIAL#g" "$TMP/body.sh" > "$TMP/body.run.sh"
( cd "$TMP/sb/tmp" && sh "$TMP/body.run.sh" ) >/dev/null 2>&1 \
    || fail "the generated case failed to run"

grep -q "zd-serial-number=\"$SERIAL\"" "$TMP/sb/tmp/support" \
    || fail "/tmp/support does not carry the runtime serial: $(cat "$TMP/sb/tmp/support" 2>/dev/null)"
pass "/tmp/support carries the runtime /bin/SERIAL"

grep -q "zd-serial-number=\"$SERIAL\"" "$TMP/sb/writable/etc/airespider/support-list.xml" \
    || fail "the entitlement record does not carry the runtime serial"
pass "the entitlement record carries the runtime serial"

# A different appliance serial must be picked up on the next run.
printf '599999999999\n' > "$TMP/sb/bin/SERIAL"
( cd "$TMP/sb/tmp" && sh "$TMP/body.run.sh" ) >/dev/null 2>&1 || fail "the second run failed"
grep -q 'zd-serial-number="599999999999"' "$TMP/sb/tmp/support" \
    || fail "/tmp/support did not follow the changed /bin/SERIAL"
pass "/tmp/support follows a changed /bin/SERIAL"

echo
echo "all entitlement-payload tests passed"
