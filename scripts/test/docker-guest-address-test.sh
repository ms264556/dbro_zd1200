#!/usr/bin/env bash
#
# docker-guest-address-test.sh — the Docker flow must print the guest's OWN
# address, with the configured GUEST_IP only as the fallback.
#
# The defect: docker/docker-compose.yml:60 always sets GUEST_IP (default
# 192.168.50.10), so the entrypoint consulted the control-channel helper only
# when GUEST_IP was empty — never in the Docker flow — and it printed
# https://192.168.50.10/ while the guest had leased a different LAN address.  A
# wrong printed URL sends an operator chasing a guest that is already up.
#
# This drives the real scripts/container/entrypoint.sh end to end, offline: a
# throwaway staged runtime, stub prepare-vm-disks.sh / launch-vm.sh, and a stub
# address helper.  No Docker daemon, no network, no root, and nothing here reads
# or writes the default control socket /tmp/zd1200-control.sock.
#
# Usage: ./scripts/test/docker-guest-address-test.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-guestaddr.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

ENTRYPOINT="$BASE/scripts/container/entrypoint.sh"
HELPER_REL="scripts/container/zd1200-guest-address"
HELPER="$BASE/$HELPER_REL"
OLD_HELPER_REL="scripts/container/proxmox/zd1200-guest-address"
OLD_HELPER="$BASE/$OLD_HELPER_REL"
GUEST_ADDR=10.222.1.128                   # what the stub guest/helper answers
STATIC_ADDR=192.168.50.10                 # the compose default (docker-compose.yml:60)
NO_SOCKET="$TMP/no-such-control.sock"     # never created: proves no socket is needed

[ -f "$ENTRYPOINT" ] || fail "not found: $ENTRYPOINT"
command -v rg >/dev/null 2>&1 \
    || fail "rg (ripgrep) is required: entrypoint.sh greps the console log with it"

# --- the staged runtime the entrypoint runs from ----------------------------
# entrypoint.sh computes work_dir from its own path and calls its neighbours by
# name, so the staged tree has to have the real tree's shape.  Only the two
# scripts it calls before the readiness loop are needed, and both are stubs:
# this test is about the address printed after the guest's READY marker, not
# about building or booting a disk.
stage() { # stage <dir>
    local run="$1"
    mkdir -p "$run/scripts/container" "$run/image" "$TMP/state"
    cp "$ENTRYPOINT" "$run/scripts/container/entrypoint.sh"
    chmod 0755 "$run/scripts/container/entrypoint.sh"
    cat > "$run/scripts/container/prepare-vm-disks.sh" <<'STUB'
#!/usr/bin/env bash
# The synthetic disk is not this test's subject.
exit 0
STUB
    cat > "$run/scripts/container/launch-vm.sh" <<'STUB'
#!/usr/bin/env bash
# entrypoint.sh starts this with stdout redirected to $LOG_FILE, which is the
# file it greps for the guest's own READY announcement — the readiness authority
# in every mode (entrypoint.sh:487-505).
#
# Record the control-channel path this process was given.  launch-vm.sh creates
# QEMU's ttyS1 chardev at $ZD_CONTROL_SOCK and the address helper connects to
# the same path, so the entrypoint must pass its own value through.  Without the
# pass-through QEMU lands on the default while every client asks the
# per-instance path, so the guest is never reached — no address, and no
# orderly-stop reboot either.  Measured on the Docker flow before this check
# existed: the container printed the static GUEST_IP.
printf '%s\n' "${ZD_CONTROL_SOCK:-}" > "$ZD_CONTROL_SEEN"
echo "System go into READY status."
STUB
    chmod 0755 "$run/scripts/container/prepare-vm-disks.sh" \
               "$run/scripts/container/launch-vm.sh"
    printf 'bzImage\n' > "$run/image/bzImage"
}
printf 'patched kernel\n' > "$TMP/bzImage.patched"

# write_helper <run> <answer|silent|broken> — the helper entrypoint.sh execs at
# "$work_dir/zd1200-guest-address".  "answer" records the ZD_CONTROL_SOCK it was
# given, so case (d) can show no socket was involved.
write_helper() {
    local run="$1" kind="$2"
    local path="$run/scripts/container/zd1200-guest-address"
    case "$kind" in
        answer)
            cat > "$path" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = "--ask" ] || exit 2
printf '%s\n' "$GUEST_ADDR"
printf '%s\n' "\${ZD_CONTROL_SOCK:-}" > "$TMP/helper-sock.txt"
STUB
            ;;
        answer2)
            # Answers only on its SECOND call: the shape the real guest has, its
            # control hook still starting when the READY marker is printed.
            cat > "$path" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = "--ask" ] || exit 2
n=0
[ -r "$TMP/helper-calls.txt" ] && n="\$(cat "$TMP/helper-calls.txt")"
n=\$((n + 1))
printf '%s\n' "\$n" > "$TMP/helper-calls.txt"
[ "\$n" -ge 2 ] && printf '%s\n' "$GUEST_ADDR"
printf '%s\n' "\${ZD_CONTROL_SOCK:-}" > "$TMP/helper-sock.txt"
STUB
            ;;
        *)
            printf '#!/usr/bin/env bash\nexit 1\n' > "$path"
            ;;
    esac
    chmod 0755 "$path"
    if [ "$kind" = broken ]; then chmod 0644 "$path"; fi
    return 0
}

OUT=""
RC=0
run_entrypoint() { # run_entrypoint <run> <GUEST_IP or -> [address-retry seconds]
    local run="$1" guest="$2" ipwait="${3:-0}"
    local -a cmd=(
        env -i
        PATH="$PATH"
        HOME="${HOME:-/tmp}"
        TMPDIR="${TMPDIR:-/tmp}"
        NETWORK_MODE=tap ACCEL=tcg ZD_CPU_GUARD=0 WEB_WAIT_SECONDS=30
        IMAGE_DIR="$run/image"
        STATE_DIR="$TMP/state"
        PATCHED_KERNEL="$TMP/bzImage.patched"
        LOG_FILE="$TMP/console.log"
        ZD_SERIAL=123456000789 ZD_MAC1=00:0c:e6:12:00:01
        ZD_CONTROL_SOCK="$NO_SOCKET"
        ZD_CONTROL_SEEN="$TMP/control-sock-seen.txt"
        # No display-path retry: these cases are about what is printed when
        # the helper answers, is absent, or is silent, and the retry would
        # only add its window to each of them.  The retry itself is covered
        # by its own case below.
        ZD_ADDRESS_WAIT="$ipwait"
    )
    [ "$guest" = "-" ] || cmd+=("GUEST_IP=$guest")
    set +e
    OUT="$( cd "$run/scripts/container" && "${cmd[@]}" ./entrypoint.sh 2>&1 )"
    RC=$?
    set -e
}

# --- (a) the guest's answer is the authority --------------------------------
stage "$TMP/a"
write_helper "$TMP/a" answer
run_entrypoint "$TMP/a" "$STATIC_ADDR"
[ "$RC" -eq 0 ] || fail "(a) the entrypoint exited $RC: $(printf '%s\n' "$OUT" | tail -3)"
grep -qxF "HTTPS: https://$GUEST_ADDR/" <<<"$OUT" \
    || fail "(a) the guest's own address was not printed (wanted https://$GUEST_ADDR/): $(printf '%s\n' "$OUT" | tail -4)"
if grep -qF "$STATIC_ADDR" <<<"$OUT"; then
    fail "(a) the static GUEST_IP $STATIC_ADDR was printed even though the guest answered $GUEST_ADDR"
fi
pass "(a) helper answers -> the guest's own address is printed, not the configured GUEST_IP"

# --- (a2) the control channel's path reaches the emulator -------------------
# launch-vm.sh builds QEMU's ttyS1 chardev from ZD_CONTROL_SOCK and the helper
# connects to the same path, so the entrypoint has to pass its own value on.  A
# missing pass-through is invisible here but fatal in the real container: QEMU
# defaults to /tmp/zd1200-control.sock while the per-instance value governs every
# client, so no address is ever retrieved and an orderly stop cannot reboot the
# guest.  This is the regression that made (a) print correctly in this test and
# the static GUEST_IP in the real Docker container.
seen_sock="$(cat "$TMP/control-sock-seen.txt" 2>/dev/null || true)"
[ "$seen_sock" = "$NO_SOCKET" ] \
    || fail "(a2) the entrypoint started launch-vm.sh with ZD_CONTROL_SOCK='$seen_sock', not its own '$NO_SOCKET' (QEMU would create the channel at the default path and never be reached)"
pass "(a2) the entrypoint passes its own ZD_CONTROL_SOCK to launch-vm.sh (QEMU's channel path)"

# --- (a3) the display path retries a guest that answers late ----------------
# The real guest prints READY before its control hook is reading ttyS1, so a
# single ask at the marker finds nothing and the static GUEST_IP is printed --
# measured on the Docker flow on six releases in a row, while the same ask
# answered correctly about a minute later.  The entrypoint must retry, bounded,
# and only for the printed URL.
rm -f "$TMP/helper-calls.txt"
stage "$TMP/a3"
write_helper "$TMP/a3" answer2
run_entrypoint "$TMP/a3" "$STATIC_ADDR" 10
calls="$(cat "$TMP/helper-calls.txt" 2>/dev/null || echo 0)"
[ "$calls" -ge 2 ] \
    || fail "(a3) the helper was asked $calls time(s); the display path did not retry a guest that answers late"
grep -qxF "HTTPS: https://$GUEST_ADDR/" <<<"$OUT" \
    || fail "(a3) the retry did not print the guest's own address: $(printf '%s\n' "$OUT" | tail -4)"
pass "(a3) a late-answering guest is retried and its own address is printed"

# --- (b) helper absent: the configured address is the safe fallback ---------
stage "$TMP/b"
run_entrypoint "$TMP/b" "$STATIC_ADDR"
[ "$RC" -eq 0 ] || fail "(b) the entrypoint exited $RC: $(printf '%s\n' "$OUT" | tail -3)"
grep -qxF "HTTPS: https://$STATIC_ADDR/" <<<"$OUT" \
    || fail "(b) with no helper the configured GUEST_IP was not printed: $(printf '%s\n' "$OUT" | tail -4)"
pass "(b) helper absent -> the configured GUEST_IP is still printed (safe degradation)"

# --- (c) helper present but answers nothing: fallback, no abort -------------
stage "$TMP/c"
write_helper "$TMP/c" silent
run_entrypoint "$TMP/c" "$STATIC_ADDR"
[ "$RC" -eq 0 ] || fail "(c) a silent helper aborted the entrypoint (exit $RC): $(printf '%s\n' "$OUT" | tail -3)"
grep -qxF "HTTPS: https://$STATIC_ADDR/" <<<"$OUT" \
    || fail "(c) a silent helper did not fall back to the configured GUEST_IP: $(printf '%s\n' "$OUT" | tail -4)"
pass "(c) helper answers nothing -> GUEST_IP printed, nothing aborted"

# --- (d) no dependence on /tmp/zd1200-control.sock --------------------------
# The staged helper never opens a socket, and this run names a socket path that
# does not exist.  The helper's own record of ZD_CONTROL_SOCK must be that
# absent path — so the printed address cannot have come from a control channel,
# and the default /tmp/zd1200-control.sock is never named, created or read.
rm -f "$TMP/helper-sock.txt"
stage "$TMP/d"
write_helper "$TMP/d" answer
[ ! -e "$NO_SOCKET" ] || fail "(d) the test's own socket path exists: $NO_SOCKET"
run_entrypoint "$TMP/d" "$STATIC_ADDR"
[ "$RC" -eq 0 ] || fail "(d) the entrypoint exited $RC: $(printf '%s\n' "$OUT" | tail -3)"
grep -qxF "HTTPS: https://$GUEST_ADDR/" <<<"$OUT" \
    || fail "(d) the address was not printed with no control socket present: $(printf '%s\n' "$OUT" | tail -4)"
seen_sock="$(cat "$TMP/helper-sock.txt" 2>/dev/null || true)"
[ "$seen_sock" = "$NO_SOCKET" ] \
    || fail "(d) the helper was run with ZD_CONTROL_SOCK='$seen_sock', not the nonexistent '$NO_SOCKET'"
pass "(d) the printed address needs no control socket (helper ran with $NO_SOCKET, which does not exist)"

# --- (e) an unexecutable helper degrades to the fallback --------------------
stage "$TMP/e"
write_helper "$TMP/e" broken
run_entrypoint "$TMP/e" "$STATIC_ADDR"
[ "$RC" -eq 0 ] || fail "(e) an unexecutable helper aborted the entrypoint (exit $RC)"
grep -qxF "HTTPS: https://$STATIC_ADDR/" <<<"$OUT" \
    || fail "(e) an unexecutable helper did not fall back to the configured GUEST_IP"
pass "(e) helper present but not executable -> GUEST_IP printed, nothing aborted"

# --- (f) a run with no GUEST_IP at all still reports the guest's answer -----
stage "$TMP/f"
write_helper "$TMP/f" answer
run_entrypoint "$TMP/f" -
[ "$RC" -eq 0 ] || fail "(f) the entrypoint exited $RC: $(printf '%s\n' "$OUT" | tail -3)"
grep -qxF "HTTPS: https://$GUEST_ADDR/" <<<"$OUT" \
    || fail "(f) with no GUEST_IP the guest's answer was not printed: $(printf '%s\n' "$OUT" | tail -4)"
pass "(f) no GUEST_IP configured -> the guest's answer is printed (unchanged)"

# --- the helper is where the entrypoint looks, and the old path still works -
# entrypoint.sh:37 computes "$work_dir/zd1200-guest-address"; the Docker image
# copies scripts/container/ minus scripts/container/proxmox/ (Dockerfile:221,
# Dockerfile.dockerignore).  A helper under the excluded directory would leave
# the image without one and every Docker run would fall back to the static
# GUEST_IP — the defect this test exists for.
case "$HELPER_REL" in
    scripts/container/proxmox/*)
        fail "the helper is under $OLD_HELPER_REL, which docker/Dockerfile.dockerignore excludes from the Docker image" ;;
esac
[ -x "$HELPER" ] \
    || fail "no executable helper at $HELPER_REL (the path entrypoint.sh:37 computes): the Docker image would fall back to the static GUEST_IP"
# The old path is what the LXC/VM configuration names (mkosi.extra/etc/
# zd1200.conf:115, zd1200-ct-bootstrap.sh:660, units-install.sh:88 makes it the
# VM's HELPER_DIR), so it must still reach a working helper -- whether that is a
# symlink to the new path or a delegating wrapper.  Comparing behaviour rather
# than file identity keeps both implementations acceptable.
[ -x "$OLD_HELPER" ] \
    || fail "$OLD_HELPER_REL is gone or not executable, but existing LXC/VM callers name it (mkosi.extra/etc/zd1200.conf:115, zd1200-ct-bootstrap.sh:660)"
if ! diff <("$HELPER" --help 2>&1) <("$OLD_HELPER" --help 2>&1) >/dev/null; then
    fail "$OLD_HELPER_REL no longer reaches the same helper as $HELPER_REL"
fi
pass "the helper is at the Docker path and the old LXC/VM path still reaches it"

# --- the moved helper itself still answers over the control channel ---------
# Cases (a)-(f) stub the helper, so this is the only check that the file the
# image will exec is intact.  A UNIX socket the test owns stands in for QEMU's
# ttyS1 chardev; the helper's own protocol is what is exercised.
if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 is required: the helper (and the Docker image) query the guest with it"
fi
sock="$TMP/real-helper.sock"
ready="$TMP/real-helper.ready"
python3 - "$sock" "$ready" "$GUEST_ADDR" <<'PY' &
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.listen(4)
open(sys.argv[2], "w").close()
conn, _ = s.accept()
conn.recv(64)
conn.sendall(b"ZD-GUEST-IP=" + sys.argv[3].encode() + b"\r\n")
conn.close()
s.close()
PY
server=$!
for _ in $(seq 1 100); do
    if [ -e "$ready" ]; then break; fi
    sleep 0.05
done
[ -e "$ready" ] || { kill "$server" 2>/dev/null || true; fail "(g) the test's stub control socket did not come up"; }
answer="$(env -i PATH="$PATH" STATE_DIR="$TMP/state" ZD_CONTROL_SOCK="$sock" \
    "$HELPER" --ask --timeout 5 --file "$TMP/real-lease" 2>/dev/null || true)"
kill "$server" 2>/dev/null || true
wait "$server" 2>/dev/null || true
[ "$answer" = "$GUEST_ADDR" ] \
    || fail "(g) the helper answered '$answer' over the control channel, not '$GUEST_ADDR'"
pass "(g) the helper at the Docker path answers over the control channel"

echo
echo "all docker guest-address tests passed"
