#!/usr/bin/env bash
#
# docker-health-test.sh — the Docker health verdict must change when the guest does.
#
# Why this exists: the verdict used to be a grep of the console log for the
# guest's READY marker.  That line is written once and never removed, so after a
# successful boot the container reported healthy forever -- a status that cannot
# change is not a health check.  This pins the three states apart, and in
# particular pins that a guest which has STOPPED answering is reported
# unhealthy, because that is the case the old check could never see.
#
# Fully offline.  The guest is a stub address helper whose answers are chosen per
# case, the emulator's age is a pid file this test sets the mtime of, and nothing
# needs root, a container or a network.
#
# Usage: ./scripts/test/docker-health-test.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HEALTH="$REPO/scripts/container/zd1200-docker-health"

pass() { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -x "$HEALTH" ] || fail "missing or not executable: $HEALTH"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-dockerhealth.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state"

# The stub guest: prints whatever the case file says, and nothing when the file
# is empty (which is how "the guest stopped answering" is expressed).
STUB="$TMP/zd1200-guest-address"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
cat "${GUEST_ANSWER_FILE:-/dev/null}" 2>/dev/null || true
exit 0
STUBEOF
chmod 755 "$STUB"

# run_health <answer-file-content> <emulator-age-seconds|none> -> prints verdict
run_health() {
    local content="$1" age="$2"
    printf '%s\n' "$content" > "$TMP/answer"
    : > "$TMP/state/qemu.pid"
    case "$age" in
        none) rm -f "$TMP/state/qemu.pid" ;;
        *)    touch -d "-${age} seconds" "$TMP/state/qemu.pid" 2>/dev/null \
                  || touch -t "$(date -d "-${age} seconds" +%Y%m%d%H%M.%S)" "$TMP/state/qemu.pid" ;;
    esac
    GUEST_ANSWER_FILE="$TMP/answer" \
    ZD_ADDRESS_HELPER="$STUB" \
    STATE_DIR="$TMP/state" \
    ZD_QEMU_PID_FILE="$TMP/state/qemu.pid" \
    ZD_HEALTH_KEYGEN_GRACE="$GRACE" \
        "$HEALTH" >/dev/null 2>&1
    printf '%s' "$?"
}

GRACE=600

# 1. The guest answers and its service is listening: healthy.
rc="$(run_health 'ZD-GUEST-IP=10.222.1.50
ZD-SERVICE-443=listening' 900)"
[ "$rc" = 0 ] || fail "a listening guest must be healthy (got rc=$rc)"
pass "guest answered + service listening -> healthy"

# 2. The guest answers, service not up yet, container still young: healthy,
#    because first boot generates the appliance's keys.
rc="$(run_health 'ZD-GUEST-IP=10.222.1.50
ZD-SERVICE-443=-' 120)"
[ "$rc" = 0 ] || fail "a young guest still starting up must not be unhealthy (got rc=$rc)"
pass "answered, service not up, ${GRACE}s grace not exceeded -> healthy (no first-boot flapping)"

# 3. The guest answers, service not up, past the grace: unhealthy.  This is the
#    half that makes the grace bounded rather than an excuse.
rc="$(run_health 'ZD-GUEST-IP=10.222.1.50
ZD-SERVICE-443=-' 5000)"
[ "$rc" = 1 ] || fail "a guest whose service never came up, past the grace, must be unhealthy (got rc=$rc)"
pass "answered, service not up, past the grace -> unhealthy"

# 4. The guest has stopped answering: unhealthy.  THIS is the case the old
#    console-log grep reported as healthy forever.
rc="$(run_health '' 5000)"
[ "$rc" = 1 ] || fail "a silent guest must be unhealthy (got rc=$rc)"
pass "guest stopped answering -> unhealthy (the old check called this healthy)"

# 4b. A guest that answers and is young but whose service is not listening yet:
#     healthy, because first boot generates the appliance's keys.  Without the
#     grace this is the case that would flap every fresh install to unhealthy.
rc="$(run_health 'ZD-GUEST-IP=10.222.1.50
ZD-SERVICE-443=-' 30)"
[ "$rc" = 0 ] || fail "a young guest generating its keys must be healthy (got rc=$rc)"
pass "answered, service not up, only 30s since launch -> healthy (key generation)"

# 4c. A BARE address (the helper emits this form too) must count as an answer.
#     The first version of the verdict accepted only the marked form and called a
#     demonstrably answering guest unhealthy, so this is pinned.
rc="$(run_health '10.222.1.50' 5000)"
[ "$rc" = 0 ] || fail "a bare address must count as the guest answering (got rc=$rc)"
pass "bare address (unmarked helper form) -> healthy"

# 5. A guest too old to parse its service state still proves userspace is running.
rc="$(run_health 'ZD-GUEST-IP=10.222.1.50' 5000)"
[ "$rc" = 0 ] || fail "a guest that answers without a service state must be healthy (got rc=$rc)"
pass "answered without a service state -> healthy"

# 6. The verdict must be falsifiable: with no helper there is nothing to ask.
rc="$(ZD_ADDRESS_HELPER="$TMP/nope" STATE_DIR="$TMP/state" "$HEALTH" >/dev/null 2>&1; printf '%s' "$?")"
[ "$rc" = 1 ] || fail "a missing address helper must be unhealthy (got rc=$rc)"
pass "no address helper -> unhealthy (the verdict can fail)"

echo
echo "all docker health-verdict tests passed"
