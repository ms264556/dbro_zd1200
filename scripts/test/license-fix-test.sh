#!/usr/bin/env bash
#
# license-fix-test.sh — unit test for scripts/container/license-fix.awk, the text
# transform the guest hook /etc/init.d/S49zd_license runs against a /writable AP
# license list.  No firmware, no QEMU, no image.
#
# It covers the two list shapes the vendor ships (a self-closing root with no
# children, and a root with <license> children), serial repair, the built-in
# compensation for a foreign model, and the generated-by stamp that keeps the
# element from being added twice.
#
# Usage: ./scripts/test/license-fix-test.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../container" && pwd)"
AWK="$BASE/license-fix.awk"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-license.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

SERIAL=502880175163
MARKER=zd1200-container
BUILTIN=5

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

run() { # <in> <out>
    awk -v serial="$SERIAL" -v marker="$MARKER" -v builtin="$BUILTIN" \
        -f "$AWK" "$1" > "$2"
}

licences() { grep -oF '<license ' "$1" | wc -l | tr -d ' '; }
inc_of() { # <file> <generated-by>: the inc-ap of that stamped element
    sed -n "s/.*inc-ap=\"\([0-9]*\)\".*generated-by=\"$2\".*/\1/p" "$1"
}

# --- a native ZD1200 list: serials repaired, nothing compensated -------------
cat > "$TMP/zd1200.xml" <<'EOF'
<license-list name="8 AP Management" max-ap="8" max-client="4000" value="0x0000000f" urlfiltering-ap-license="0">
    <license id="1" name="2 AP Management (ID:cuf0FVdp)" inc-ap="2" generated-by="114126" serial-number="441408000009" status="0" detail="" />
    <license id="2" name="1 AP Management (ID:p76X03Mz)" inc-ap="1" generated-by="114143" serial-number="441408000009" status="0" detail="" />
</license-list>
EOF
run "$TMP/zd1200.xml" "$TMP/zd1200.out"
[ "$(licences "$TMP/zd1200.out")" = 2 ] || fail "ZD1200: licence count changed"
grep -q "serial-number=\"$SERIAL\"" "$TMP/zd1200.out" || fail "ZD1200: serial not repaired"
grep -q '441408000009' "$TMP/zd1200.out" && fail "ZD1200: source serial left behind"
grep -q "generated-by=\"$MARKER\"" "$TMP/zd1200.out" && fail "ZD1200: compensated a native list"
grep -q 'max-ap="8"' "$TMP/zd1200.out" || fail "ZD1200: max-ap changed"
pass "native ZD1200 list: serials repaired, 5 + 3 add-ons left alone"

# --- a foreign ZD1100 (12 built-in, no add-ons): compensate +7 --------------
printf '%s\n' '<license-list name="12 AP Management" max-ap="12" max-client="1250" value="0x0000000f" />' \
    > "$TMP/zd1100.xml"
run "$TMP/zd1100.xml" "$TMP/zd1100.out"
[ "$(licences "$TMP/zd1100.out")" = 1 ] || fail "ZD1100: expected one compensating licence"
[ "$(inc_of "$TMP/zd1100.out" "$MARKER")" = 7 ] || fail "ZD1100: expected inc-ap 7"
grep -q "serial-number=\"$SERIAL\"" "$TMP/zd1100.out" || fail "ZD1100: serial not stamped"
grep -q '</license-list>' "$TMP/zd1100.out" || fail "ZD1100: self-closing root not expanded"
grep -q 'max-ap="12"' "$TMP/zd1100.out" || fail "ZD1100: max-ap changed"
marker_line="$(grep "generated-by=\"$MARKER\"" "$TMP/zd1100.out")"
case "$marker_line" in
    *'DELETABLE="false"'*) ;;
    *) fail "ZD1100: compensating licence is not marked DELETABLE=false" ;;
esac
pass "foreign ZD1100 (12 built-in): compensating inc-ap=12-5=7, DELETABLE=false"

# --- and again: the stamp makes the second run a no-op ----------------------
run "$TMP/zd1100.out" "$TMP/zd1100.again"
cmp -s "$TMP/zd1100.out" "$TMP/zd1100.again" || fail "ZD1100: second run was not idempotent"
pass "second run over the stamped list changes nothing"

# --- a ZD3000-ish list (50 built-in): compensate +45 ------------------------
printf '%s\n' '<license-list name="50 AP Management" max-ap="50" max-client="5000" value="0x0000000f" />' \
    > "$TMP/zd3000.xml"
run "$TMP/zd3000.xml" "$TMP/zd3000.out"
[ "$(inc_of "$TMP/zd3000.out" "$MARKER")" = 45 ] || fail "ZD3000: expected inc-ap 45"
pass "foreign ZD3000 (50 built-in): compensating inc-ap=50-5=45"

# --- a foreign list that already has add-ons: only the difference -----------
cat > "$TMP/foreign-addons.xml" <<'EOF'
<license-list name="11 AP Management" max-ap="11" max-client="1250" value="0x0000000f">
    <license id="1" name="2 AP Management (ID:aaa)" inc-ap="2" generated-by="1" serial-number="old" status="0" detail="" />
</license-list>
EOF
run "$TMP/foreign-addons.xml" "$TMP/foreign-addons.out"
[ "$(inc_of "$TMP/foreign-addons.out" "$MARKER")" = 4 ] || fail "foreign add-ons: expected inc-ap 11-5-2=4"
[ "$(licences "$TMP/foreign-addons.out")" = 2 ] || fail "foreign add-ons: expected the original plus one"
grep -q 'serial-number="old"' "$TMP/foreign-addons.out" && fail "foreign add-ons: serial not repaired"
pass "foreign list with add-ons: compensates max-ap - 5 - sum(inc-ap)"

# --- a later purchase must not disturb the stamped element ------------------
# The vendor adds the bought licence and raises max-ap by the same amount, so
# the compensation stays at 7 and 5 + 5 + 7 == 17.  (Re-deriving it would be
# fine here, but it is exactly the case where a mistake shrinks the built-ins.)
# The fixture's stamped element has lost DELETABLE (a vendor rewrite can drop
# it); the hook re-adds it without touching inc-ap.
cat > "$TMP/bought.xml" <<EOF
<license-list name="17 AP Management" max-ap="17" max-client="1250" value="0x0000000f">
    <license id="1" name="5 AP Management (ID:new)" inc-ap="5" generated-by="99" serial-number="old" status="0" detail="" />
    <license id="2" name="7 AP Management" inc-ap="7" generated-by="$MARKER" serial-number="old" status="0" detail="" />
</license-list>
EOF
run "$TMP/bought.xml" "$TMP/bought.out"
[ "$(inc_of "$TMP/bought.out" "$MARKER")" = 7 ] || fail "purchase: compensation moved"
grep -q 'inc-ap="5"' "$TMP/bought.out" || fail "purchase: bought licence lost"
grep -q 'serial-number="old"' "$TMP/bought.out" && fail "purchase: serials not repaired"
case "$(grep "generated-by=\"$MARKER\"" "$TMP/bought.out")" in
    *'DELETABLE="false"'*) ;;
    *) fail "purchase: compensating licence is deletable" ;;
esac
pass "a later purchase keeps the compensation at 7 (5 + 5 + 7 == 17)"

# --- a stamped element is never resized or dropped --------------------------
# Even when the arithmetic says something else: losing the built-in APs is not
# recoverable, so the stamp wins.  Only the protective attribute may be added.
cat > "$TMP/stamped.xml" <<EOF
<license-list name="12 AP Management" max-ap="12" max-client="1250" value="0x0000000f">
    <license id="1" name="3 AP Management" inc-ap="3" generated-by="$MARKER" serial-number="old" status="0" detail="" />
</license-list>
EOF
run "$TMP/stamped.xml" "$TMP/stamped.out"
[ "$(licences "$TMP/stamped.out")" = 1 ] || fail "stamped: added a second compensating licence"
[ "$(inc_of "$TMP/stamped.out" "$MARKER")" = 3 ] || fail "stamped: element was resized"
grep -q 'serial-number="old"' "$TMP/stamped.out" && fail "stamped: serial not repaired"
pass "a stamped element is never resized or dropped (serials still repaired)"

cat > "$TMP/stamped-zero.xml" <<EOF
<license-list name="5 AP Management" max-ap="5" max-client="1250" value="0x0000000f">
    <license id="1" name="7 AP Management" inc-ap="7" generated-by="$MARKER" serial-number="$SERIAL" status="0" detail="" />
</license-list>
EOF
run "$TMP/stamped-zero.xml" "$TMP/stamped-zero.out"
[ "$(inc_of "$TMP/stamped-zero.out" "$MARKER")" = 7 ] || fail "stamped-zero: element was dropped"
pass "a stamped element is never dropped"

# --- a list with no root max-ap is echoed unchanged -------------------------
printf '%s\n' '<something-else id="1" />' > "$TMP/other.xml"
run "$TMP/other.xml" "$TMP/other.out"
cmp -s "$TMP/other.xml" "$TMP/other.out" || fail "unrecognised input was not echoed"
pass "unrecognised input is echoed unchanged"

echo
echo "all license-fix tests passed"
