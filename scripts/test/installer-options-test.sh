#!/usr/bin/env bash
#
# installer-options-test.sh — each installer's option parser and its --help agree,
# and a bad command line fails at the parse, before the installer does any work.
#
# The docs send users to options by name (--r600-repair, --writable-partition,
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

# --- the R600 AP mesh repair is opt-in --------------------------------------
# The repair bootlooped APs, so it must not be applied unless it was asked for:
# every entry point defaults it off, and --r600-repair is what turns it on.  The
# default is a shell assignment an argument-less run reaches before any of the
# work, and the installers cannot be driven that far offline, so it is checked
# statically here.  The gate that consumes ZD_R600_REPAIR is exercised
# behaviourally by build-synthetic-cf-debugfs-test.py.
grep -qE '(^|; )R600_REPAIR=0(;|$)' "$REPO/install-zd1200-lxc.sh" \
    || fail "install-zd1200-lxc.sh does not default the R600 mesh repair off"
grep -qF 'r600_repair="${ZD_R600_REPAIR:-0}"' "$REPO/install-zd1200-docker.sh" \
    || fail "install-zd1200-docker.sh does not default the R600 mesh repair off"
grep -qE '(^|; )R600_REPAIR=0(;|$)' "$REPO/scripts/container/proxmox/zd1200-ct-bootstrap.sh" \
    || fail "zd1200-ct-bootstrap.sh does not default the R600 mesh repair off"
grep -qF '${ZD_R600_REPAIR:-0}' "$REPO/docker/docker-compose.yml" \
    || fail "docker-compose.yml does not default ZD_R600_REPAIR off"
for f in install-zd1200-lxc.sh install-zd1200-docker.sh \
         scripts/container/proxmox/zd1200-ct-bootstrap.sh; do
    grep -q -- '--r600-repair)' "$REPO/$f" \
        || fail "$f has no --r600-repair to opt in to the R600 mesh repair"
done
pass "the R600 mesh repair is opt-in: every entry point defaults it off and --r600-repair enables it"

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

# --uninstall is the inverse of an install: it stops and destroys the containers
# this installer made, and also removes the obsolete host-global summary timer an
# older version left behind.  Its awkward case is a container already removed by
# hand -- nothing in Proxmox runs on `pct destroy` (hookscripts cover start/stop
# only), so a hand-run destroy leaves that timer running with nothing to publish.
#
# The functions are driven directly against a fixture.  Without a Proxmox host the
# installer dies at its host check long before the uninstall path (the same reason
# only Docker is driven for --upgrade above), so the real script cannot be run here.
eval "$(grep -E '^CT_MARKER=' "$REPO/install-zd1200-lxc.sh")"
eval "$(grep -E '^LEGACY_SUMMARY_[A-Z_]+=' "$REPO/install-zd1200-lxc.sh")"
[ -n "$CT_MARKER" ] && [ -n "$LEGACY_SUMMARY_HELPER" ] && [ -n "$LEGACY_SUMMARY_UNIT" ] && [ -n "$LEGACY_SUMMARY_UNIT_DIR" ] \
    || fail "could not read CT_MARKER / LEGACY_SUMMARY_* out of the installer"

# The summary updater itself is gone: the guest's address is shown from the
# container's own zd0 interface, so only the cleanup of an older copy remains.
[ ! -e "$REPO/scripts/build/proxmox/zd1200-pve-summary-host.sh" ] \
    || fail "the removed Proxmox summary helper is still in the tree"
grep -q 'remove_legacy_pve_summary_helper' "$REPO/install-zd1200-lxc.sh" \
    || fail "the installer no longer cleans up the obsolete summary timer"
pass "the Proxmox summary updater is removed, with a legacy cleanup left in its place"

{
    awk '/^find_zd1200_ctids\(\) \{/,/^}/' "$REPO/install-zd1200-lxc.sh"
    awk '/^remove_legacy_pve_summary_helper\(\) \{/,/^}/' "$REPO/install-zd1200-lxc.sh"
    awk '/^uninstall_zd1200_container\(\) \{/,/^}/' "$REPO/install-zd1200-lxc.sh"
} > "$TMP/uninstall-fns.sh"
for fn in find_zd1200_ctids remove_legacy_pve_summary_helper uninstall_zd1200_container; do
    grep -q "^$fn()" "$TMP/uninstall-fns.sh" || fail "the installer no longer defines $fn()"
done

# Everything the uninstall path calls has to be defined *above* its dispatch, since
# the installer runs top to bottom and exits from there.  lock_host was not, and
# --uninstall died with "lock_host: command not found" on a real Proxmox host while
# this test passed -- the harness above stubs whatever it extracts, so only a
# static ordering check catches that class of bug.
dispatch="$(grep -n '^if \[ "\$UNINSTALL" = 1 \]; then$' "$REPO/install-zd1200-lxc.sh" | cut -d: -f1)"
[ -n "$dispatch" ] || fail "could not find the --uninstall dispatch in the installer"
[ "$(printf '%s\n' "$dispatch" | wc -l)" = 1 ] || fail "expected one --uninstall dispatch, found lines: $(printf '%s ' $dispatch)"
for fn in pct lock_host unlock_host find_zd1200_ctids remove_legacy_pve_summary_helper \
          uninstall_zd1200_container; do
    def="$(grep -n "^$fn()" "$REPO/install-zd1200-lxc.sh" | cut -d: -f1)"
    [ -n "$def" ] || fail "$fn() is not defined in the installer"
    [ "$(printf '%s\n' "$def" | wc -l)" = 1 ] || fail "$fn() is defined more than once, at lines: $(printf '%s ' $def)"
    [ "$def" -lt "$dispatch" ] \
        || fail "$fn() is defined at line $def, after the --uninstall dispatch at line $dispatch: --uninstall would fail with '$fn: command not found'"
done
pass "everything the uninstall path calls is defined above its dispatch"

# A second `systemctl` (the Docker fake above is the `docker` one) that records
# the calls in a file: the function redirects systemctl's own output to
# /dev/null, as it should, so the log is the only place the order is visible.
cat > "$TMP/fakebin/systemctl" <<'FAKE'
#!/usr/bin/env bash
{ printf 'systemctl'; printf ' [%s]' "$@"; printf '\n'; } >> "$ZD_FAKE_SYSTEMCTL_LOG"
FAKE
chmod 755 "$TMP/fakebin/systemctl"

mkdir -p "$TMP/lxc" "$TMP/units" "$TMP/sbin"
printf '#Ruckus ZD1200 virtual appliance (%s)\n' "$CT_MARKER" > "$TMP/lxc/120.conf"
printf '#Ruckus ZD1200 virtual appliance (%s)\n' "$CT_MARKER" > "$TMP/lxc/121.conf"
printf 'arch: amd64\n' > "$TMP/lxc/200.conf"

run_fns() { # run_fns <function> [arg...]
    CT_MARKER="$CT_MARKER" LEGACY_SUMMARY_UNIT="$LEGACY_SUMMARY_UNIT" \
    LEGACY_SUMMARY_UNIT_DIR="$TMP/units" LEGACY_SUMMARY_HELPER="$TMP/sbin/zd1200-pve-summary-host" \
    ZD_FAKE_SYSTEMCTL_LOG="$TMP/systemctl.log" \
    PATH="$TMP/fakebin:$PATH" bash -c '. "$1"; shift; "$@"' _ "$TMP/uninstall-fns.sh" "$@"
}

got="$(run_fns find_zd1200_ctids "$TMP/lxc" | tr '\n' ' ')"
[ "$got" = "120 121 " ] || { printf '%s\n' "$got" >&2; fail "find_zd1200_ctids should report only the marked containers"; }
pass "a container counts as a ZD1200 one only when it carries the installer's marker"

# The legacy cleanup: silent when there is nothing to remove, and otherwise it
# stops the timer before deleting it and both units, and is safe to repeat.
: > "$TMP/systemctl.log"
out="$(run_fns remove_legacy_pve_summary_helper 2>&1)"
[ -z "$out" ] || { printf '%s\n' "$out" >&2; fail "remove_legacy_pve_summary_helper reported something with no legacy files present"; }
: > "$TMP/sbin/zd1200-pve-summary-host"
: > "$TMP/units/$LEGACY_SUMMARY_UNIT.timer"
: > "$TMP/units/$LEGACY_SUMMARY_UNIT.service"
: > "$TMP/systemctl.log"
run_fns remove_legacy_pve_summary_helper >/dev/null 2>&1
out="$(cat "$TMP/systemctl.log")"
for leftover in "$TMP/sbin/zd1200-pve-summary-host" "$TMP/units/$LEGACY_SUMMARY_UNIT.timer" "$TMP/units/$LEGACY_SUMMARY_UNIT.service"; do
    [ ! -e "$leftover" ] || fail "remove_legacy_pve_summary_helper left $leftover behind"
done
grep -qF "disable] [--now] [$LEGACY_SUMMARY_UNIT.timer]" <<<"$out" \
    || { printf '%s\n' "$out" >&2; fail "the legacy cleanup did not stop and disable the timer first"; }
grep -qF 'daemon-reload' <<<"$out" \
    || { printf '%s\n' "$out" >&2; fail "the legacy cleanup did not reload systemd"; }
run_fns remove_legacy_pve_summary_helper >/dev/null 2>&1 || fail "the legacy cleanup is not safe to repeat"
pass "the legacy cleanup stops the timer, removes the helper and both units, and is safe to repeat"

# The whole flow against a fixture: which containers get destroyed is the part that
# must not be got wrong.  The stubs stand in for what the installer's main body
# provides (die/info/step/warn from install-common.sh, the pct wrapper).
cat > "$TMP/fakebin/pct" <<'FAKE'
#!/usr/bin/env bash
{ printf 'pct'; printf ' [%s]' "$@"; printf '\n'; } >> "$ZD_FAKE_PCT_LOG"
[ "${1:-}" = status ] && echo 'status: running'
# `pct destroy` is what takes the config away, so the fixture has to lose it too.
if [ "${1:-}" = destroy ]; then
    for a in "$@"; do
        case "$a" in ''|*[!0-9]*) ;; *) rm -f "$ZD_LXC_CONF_DIR/$a.conf" ;; esac
    done
fi
exit 0
FAKE
chmod 755 "$TMP/fakebin/pct"

cat > "$TMP/uninstall-run.sh" <<'RUN'
die()  { printf 'die: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warn: %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }
step() { printf '== %s\n' "$*"; }
POSITIONALS=(); OPT_FIRMWARE=""; OPT_BACKUP=""; OPT_WRITABLE=""
INTERACTIVE=0; ASSUME_YES=1
. "$UNINSTALL_FNS"
uninstall_zd1200_container
RUN

seed_legacy_helper() {
    mkdir -p "$TMP/units" "$TMP/sbin"
    : > "$TMP/sbin/zd1200-pve-summary-host"
    : > "$TMP/units/$LEGACY_SUMMARY_UNIT.timer"
    : > "$TMP/units/$LEGACY_SUMMARY_UNIT.service"
    : > "$TMP/pct.log"
    : > "$TMP/systemctl.log"
}
legacy_gone() {
    [ ! -e "$TMP/sbin/zd1200-pve-summary-host" ] \
        && [ ! -e "$TMP/units/$LEGACY_SUMMARY_UNIT.timer" ] \
        && [ ! -e "$TMP/units/$LEGACY_SUMMARY_UNIT.service" ]
}
run_uninstall() { # run_uninstall <confdir> [ctid]
    # LXC_CONF_DIR is what the installer derives from ZD_LXC_CONF_DIR; the harness
    # sets it directly, so the sourced functions look in the fixture.
    LXC_CONF_DIR="$1" ZD_LXC_CONF_DIR="$1" CTID="${2:-}" CT_MARKER="$CT_MARKER" \
    LEGACY_SUMMARY_UNIT="$LEGACY_SUMMARY_UNIT" LEGACY_SUMMARY_UNIT_DIR="$TMP/units" \
    LEGACY_SUMMARY_HELPER="$TMP/sbin/zd1200-pve-summary-host" \
    ZD_FAKE_PCT_LOG="$TMP/pct.log" ZD_FAKE_SYSTEMCTL_LOG="$TMP/systemctl.log" \
    UNINSTALL_FNS="$TMP/uninstall-fns.sh" \
    PATH="$TMP/fakebin:$PATH" bash -c '. "$1"' _ "$TMP/uninstall-run.sh"
}

# No --ctid: every ZD1200 container goes, and nothing else.
rm -rf "$TMP/lxc"; mkdir -p "$TMP/lxc"
printf '#Ruckus ZD1200 virtual appliance (%s)\n' "$CT_MARKER" > "$TMP/lxc/120.conf"
printf '#Ruckus ZD1200 virtual appliance (%s)\n' "$CT_MARKER" > "$TMP/lxc/121.conf"
printf 'arch: amd64\n' > "$TMP/lxc/200.conf"
seed_legacy_helper
run_uninstall "$TMP/lxc" || fail "uninstall failed with two ZD1200 containers"
grep -qF 'pct [stop] [120]' "$TMP/pct.log" || { cat "$TMP/pct.log" >&2; fail "a running container was destroyed without being stopped first"; }
for id in 120 121; do
    grep -qF "pct [destroy] [$id] [--purge]" "$TMP/pct.log" || { cat "$TMP/pct.log" >&2; fail "uninstall did not destroy container $id"; }
done
grep -qF 'pct [destroy] [200] [--purge]' "$TMP/pct.log" && fail "uninstall destroyed a container that is not a ZD1200 one"
legacy_gone || fail "uninstall left the obsolete summary timer behind"
pass "uninstall stops and destroys every ZD1200 container, cleans the legacy timer, and leaves other containers alone"

# --ctid names one of two: only it goes.
seed_legacy_helper
printf '#Ruckus ZD1200 virtual appliance (%s)\n' "$CT_MARKER" > "$TMP/lxc/120.conf"
printf '#Ruckus ZD1200 virtual appliance (%s)\n' "$CT_MARKER" > "$TMP/lxc/121.conf"
run_uninstall "$TMP/lxc" 120 || fail "uninstall --ctid 120 failed"
grep -qF 'pct [destroy] [120] [--purge]' "$TMP/pct.log" || fail "uninstall --ctid 120 did not destroy 120"
grep -qF 'pct [destroy] [121] [--purge]' "$TMP/pct.log" && fail "uninstall --ctid 120 destroyed 121 as well"
pass "uninstall --ctid removes only that container"

# The case the legacy cleanup exists for: the container was already removed by hand.
seed_legacy_helper
rm -f "$TMP/lxc/120.conf" "$TMP/lxc/121.conf"
run_uninstall "$TMP/lxc" || fail "uninstall failed with no ZD1200 container left"
grep -q 'pct' "$TMP/pct.log" && { cat "$TMP/pct.log" >&2; fail "uninstall called pct when there was no container to destroy"; }
legacy_gone || fail "uninstall did not clear the obsolete timer an earlier install left behind"
pass "uninstall clears the obsolete timer when the container is already gone"

echo
echo "all installer-options tests passed"
