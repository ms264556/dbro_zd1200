#!/usr/bin/env bash
#
# installer-options-test.sh — each installer's option parser and its --help agree,
# and a bad command line fails at the parse, before the installer does any work.
#
# The docs send users to options by name (--no-r600-repair, --writable-partition,
# --container-mac ...), and an option the parser accepts but --help never lists is
# one nobody can find.  So every `--option` the parser's case patterns name must
# appear in that installer's --help.  A bad command line (an unknown option, an
# option missing its value, --upgrade given an input) must exit non-zero with a
# message and must not get as far as touching Docker or Proxmox: these runs have
# no Docker, no pct and no input files, so reaching any of that would fail
# differently.
#
# Usage: ./scripts/test/installer-options-test.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-options.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

# parsed_options <installer>: the --options its argument loop names, one per line.
parsed_options() {
    awk '/^while \[ \$# -gt 0 \]/,/^done/' "$1" | grep -o -- '--[a-z0-9][a-z0-9-]*' | sort -u
}

# run <installer> <args...>: stdout+stderr to $TMP/out, status to $RC.  stdin is
# closed so nothing can wait on a prompt.
RC=0
run() {
    local installer="$1"; shift
    RC=0
    "$installer" "$@" > "$TMP/out" 2>&1 < /dev/null || RC=$?
}
expect_refused() { # <label> <message substring> <installer> <args...>
    local label="$1" sub="$2"; shift 2
    run "$@"
    [ "$RC" != 0 ] || { cat "$TMP/out" >&2; fail "$label: expected a failure, got exit 0"; }
    grep -qF -- "$sub" "$TMP/out" || { cat "$TMP/out" >&2; fail "$label: no '$sub' in the output (exit $RC)"; }
}

for name in docker lxc; do
    installer="$REPO/install-zd1200-$name.sh"
    [ -x "$installer" ] || fail "missing or not executable: $installer"

    # --- every parsed option is in --help ------------------------------------
    run "$installer" --help
    [ "$RC" = 0 ] || { cat "$TMP/out" >&2; fail "$name: --help exited $RC"; }
    help="$(cat "$TMP/out")"
    options="$(parsed_options "$installer")"
    [ "$(printf '%s\n' "$options" | wc -l)" -ge 10 ] \
        || fail "$name: found fewer than 10 parsed options; the extraction no longer matches the parser"
    missing=""
    for opt in $options; do
        grep -qF -- "$opt" <<<"$help" || missing+=" $opt"
    done
    [ -z "$missing" ] || fail "$name: --help does not mention:$missing"
    pass "$name: every option the parser accepts is in --help ($(printf '%s\n' "$options" | wc -l) options)"

    # --- bad command lines fail at the parse ----------------------------------
    expect_refused "$name unknown option" "unknown option" "$installer" --no-such-option
    expect_refused "$name unknown option after a valid one" "unknown option" \
        "$installer" --no-up --no-such-option
    expect_refused "$name option missing its value" "--root-ssh-key" "$installer" --root-ssh-key
    pass "$name: an unknown option and an option without its value are refused"
done

# pct() forwards `pct exec` into the container with this shell's TMPDIR removed:
# the container does not have the host's directories.  Run the real function
# against a fake `pct` that prints what it was called with and which TMPDIR it saw.
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/pct" <<'FAKE'
#!/usr/bin/env bash
printf 'args:'; printf ' [%s]' "$@"; printf '\n'
printf 'TMPDIR=[%s]\n' "${TMPDIR-unset}"
FAKE
chmod 755 "$TMP/fakebin/pct"
awk '/^pct\(\) \{/,/^}/' "$REPO/install-zd1200-lxc.sh" > "$TMP/pct-wrapper.sh"
grep -q 'env -u TMPDIR' "$TMP/pct-wrapper.sh" || fail "the installer no longer defines the pct() TMPDIR wrapper"
out="$(PATH="$TMP/fakebin:$PATH" TMPDIR=/host/only bash -c '. "$1"; pct exec 910 -- printenv "a b" "c"' _ "$TMP/pct-wrapper.sh" 2>&1)"
grep -qF 'args: [exec] [910] [--] [env] [-u] [TMPDIR] [printenv] [a b] [c]' <<<"$out" \
    || { printf '%s\n' "$out" >&2; fail "pct exec was not forwarded with TMPDIR scrubbed and its arguments intact"; }
out="$(PATH="$TMP/fakebin:$PATH" TMPDIR=/host/only bash -c '. "$1"; pct status 910' _ "$TMP/pct-wrapper.sh" 2>&1)"
grep -qF 'args: [status] [910]' <<<"$out" && grep -qF 'TMPDIR=[/host/only]' <<<"$out" \
    || { printf '%s\n' "$out" >&2; fail "a pct call other than exec must pass through untouched"; }
pass "pct exec scrubs the host's TMPDIR and keeps its arguments; other pct calls pass through"

# guard_start() is the Docker installer's check that the container stays up after
# `compose up`: a start failure that never clears makes the restart policy loop
# for good while compose reports success.  Run the real function against a fake
# `docker` that reports a chosen state, with the watch shortened to one poll.
cat > "$TMP/fakebin/docker" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
    inspect)
        case "$3" in
            '{{.State.Status}}')   echo "${FAKE_STATE:-running}" ;;
            '{{.RestartCount}}')   echo "${FAKE_RESTARTS:-0}" ;;
        esac ;;
    logs) echo "fake container log: the entrypoint failed" ;;
esac
FAKE
chmod 755 "$TMP/fakebin/docker"
awk '/^guard_start\(\) \{/,/^}/' "$REPO/install-zd1200-docker.sh" > "$TMP/guard-start.sh"
grep -q 'not staying up' "$TMP/guard-start.sh" || fail "the Docker installer no longer defines guard_start()"
run_guard() { # run_guard <state> <restart count>
    FAKE_STATE="$1" FAKE_RESTARTS="$2" ZD_START_GUARD_SECONDS=3 PATH="$TMP/fakebin:$PATH" \
        bash -c 'docker_cmd=(docker); compose_cmd=(docker compose); inst=zdt; . "$1"; guard_start' _ "$TMP/guard-start.sh" \
        > "$TMP/guard.out" 2>&1
    GUARD_RC=$?
}
run_guard running 0
[ "$GUARD_RC" = 0 ] || { cat "$TMP/guard.out" >&2; fail "guard_start failed a container that is running with no restarts"; }
run_guard restarting 4
[ "$GUARD_RC" != 0 ] && grep -qF "not staying up" "$TMP/guard.out" && grep -qF "fake container log" "$TMP/guard.out" \
    || { cat "$TMP/guard.out" >&2; fail "guard_start did not fail a restarting container with its log"; }
run_guard running 2
[ "$GUARD_RC" != 0 ] || fail "guard_start passed a container that has already restarted"
run_guard exited 0
[ "$GUARD_RC" != 0 ] || fail "guard_start passed a container that exited"
pass "docker: a container that is restarting or has restarted fails the start with its log; a steady one passes"

# --upgrade takes no input.  Docker reaches that check straight after the parse;
# the LXC installer needs a Proxmox host to get there, so only Docker is driven.
expect_refused "docker --upgrade with an input" "takes no input" \
    "$REPO/install-zd1200-docker.sh" --upgrade "$TMP/some-firmware.img"
pass "docker: --upgrade given an input is refused"

# A mistyped input is never dropped beside a valid one (resolve_inputs).
expect_refused "docker typo'd input" "input not found" \
    "$REPO/install-zd1200-docker.sh" "$TMP/no-such-backup.bak"
pass "docker: a path that does not exist is reported as not found"

echo
echo "all installer-options tests passed"
