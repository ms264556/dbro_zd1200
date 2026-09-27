#!/usr/bin/env bash
#
# ct-net-dhclient-test.sh — the DHCP-client stop in zd1200-ct-net.sh must be
# scoped to the interface it is about, and must never match a command line.
#
# Why this exists: at abc0b3a, scripts/container/proxmox/zd1200-ct-net.sh:230
# ran
#     pkill -f "dhclient.*$HOST_IF"
# in the ZD_CT_DHCP branch.  `-f` matches the full command line of EVERY process
# on the host, so any unrelated process whose arguments happened to contain that
# text -- a shell running this very script with --host-if among its arguments,
# for one -- was SIGTERM'd too.  That is the pkill -f hazard this project forbids
# (HANDOFF.md 8.8 item 11, raised by session 8's independent review of a
# different fix).  The kill itself is there for a real reason: Proxmox's DHCP
# client keeps its lease keyed on the interface and re-adds the address to the
# uplink after the lines below it move the address onto the bridge, so the client
# that holds $HOST_IF has to be stopped.
#
# The fix keeps that kill and scopes it: walk /proc, require the process's own
# executable to be dhclient AND $HOST_IF to be one of ITS OWN argv elements, and
# kill those PIDs by number.  No pattern is matched anywhere.  This test is the
# before/after for exactly that.
#
# HOW FAR THIS DRIVES THE REAL SCRIPT.  zd1200-ct-net.sh manipulates tc,
# addresses and bridges on a live host, so the script as a whole is not run here.
# What is run is the ZD_CT_DHCP block itself, extracted verbatim from a staged
# revision (abc0b3a's from git, HEAD's from the working tree), under the same
# `set -euo pipefail` the script sets at :30, with a stub `dhclient` first on
# PATH (the guard at :228) and three decoy processes up:
#     a  a process whose command line merely says "dhclient $IFACE" while its own
#        executable is sleep -- a look-alike, not really dhclient;
#     b  a real-shaped client: its own executable is dhclient and $IFACE is one
#        of its own arguments (the argv is the Proxmox shape, with the interface
#        in the -pf/-lf paths as well);
#     c  the control: the same shape, but for a DIFFERENT interface.
# The two revisions are then required to differ exactly where the defect is: the
# pre-fix block kills (a) and (b); the fixed block kills only (b).  Cleanup is by
# PID; liveness is read with `ps -eo pid=,stat=` and /proc.  If the pre-fix blob
# is not in this clone the discriminating half prints `skipped:` and the fixed
# half is still measured, as in boot-test-runscope-test.sh.
#
# SAFETY, because the pre-fix half is a host-global match by construction:
#   * The interface name is a fresh synthetic token per run (zddhcp<RANDOM><pid>
#     style), never eth0 or the real uplink, so the only command lines on the
#     host that can match it are this test's own decoys.  Deliberate.
#   * The harness's own shell never carries the pattern in its argv: the block
#     under test is written to a file and run as `bash <file>`, so the pattern
#     exists only inside that file.  Before the pre-fix block is allowed to run,
#     assert_only_decoys() scans `ps -eo pid=,args=` with the same regex and
#     REFUSES to run it unless the only matching processes are decoys a and b.
#     (setsid does not help here: pkill signals each PID it matched from its own
#     /proc scan, so a process group bounds nothing.  The gate is the bound.)
#   * A TERM trap records any signal the harness itself receives; the test fails
#     if that file is not empty.
#   * No pgrep -f / pkill -f is run by this test.  The only pattern match is the
#     one inside the staged pre-fix code.
#   * Decoy b is a COPY OF BASH named dhclient, not the dhclient program: it runs
#     `read` from a FIFO and can touch no network state.  Its own executable
#     being dhclient is what makes it the post-fix target; nothing real is
#     signalled, and no real dhclient (which is not installed on this host) is
#     ever executed -- the stub on PATH answers `dhclient -r`.
#
# Runs unprivileged: everything it signals is a process it started itself.
#
# Usage: ./scripts/test/ct-net-dhclient-test.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO/scripts/container/proxmox/zd1200-ct-net.sh"
# The revision whose block carries the defect; the whole point of this harness is
# that it still exhibits it.
PRE_FIX_REV="abc0b3a"

pass() { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
skip() { printf 'skipped: %s\n' "$*"; exit 0; }

for tool in ps awk grep readlink tr mkfifo cp mktemp; do
    command -v "$tool" >/dev/null 2>&1 || skip "needs $tool"
done
[ -f "$SCRIPT" ] || fail "missing $SCRIPT"
BASH_BIN="$(command -v bash || true)"
[ -n "$BASH_BIN" ] || skip "needs a bash binary to copy as the decoy dhclient"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-ctnet-dhclient.XXXXXX")" \
    || skip "cannot create a scratch directory"

# A fresh interface token per run: unique, alphabetic+digits only (so it is a
# literal in the regex too), and not a substring of the control's token.
IFACE="zddhcp${RANDOM}$$a"
OTHER_IF="zddot${RANDOM}$$b"
case "$OTHER_IF" in *"$IFACE"*) fail "harness bug: control token contains the subject token" ;; esac
[ -n "$IFACE" ] && [ "$IFACE" != "$OTHER_IF" ] || fail "harness bug: no interface token"

FIFO="$TMP/fifo"
STUB_DIR="$TMP/stub"
DECOY_DIR="$TMP/decoy"
MIN_DIR="$TMP/min"
mkdir -p "$STUB_DIR" "$DECOY_DIR" "$MIN_DIR" || fail "cannot create the harness directories"
mkfifo "$FIFO" || fail "cannot create $FIFO"
# The decoys' own executable must be named dhclient; a copy of bash is inert
# (it runs `read` from a FIFO) and is not the dhclient program.
cp "$BASH_BIN" "$DECOY_DIR/dhclient" || fail "cannot copy $BASH_BIN to $DECOY_DIR/dhclient"
# The stub that answers the :228 guard.  It stands in for the real dhclient,
# which is NOT installed on this host and is never run here.
cat > "$STUB_DIR/dhclient" <<'STUB' || fail "cannot write the stub dhclient"
#!/usr/bin/env bash
printf 'stub-dhclient %s\n' "$*" >> "$STUB_LOG"
exit 0
STUB
chmod 755 "$STUB_DIR/dhclient"
ln -s "$(command -v tr)" "$MIN_DIR/tr"
ln -s "$(command -v readlink)" "$MIN_DIR/readlink"

# The harness's own command line is `bash <this file>`, which carries neither
# "dhclient" nor the token; this records any signal that says otherwise.
HARNESS_SIGNALS="$TMP/harness-signals"
: > "$HARNESS_SIGNALS"
trap 'printf "TERM\n" >> "$HARNESS_SIGNALS"' TERM

DECOY_PIDS=""
alive() {  # 0 when that pid is a live, non-zombie process
    local st
    st="$(ps -eo pid=,stat= 2>/dev/null | awk -v P="$1" '$1 == P { print $2 }')"
    [ -n "$st" ] && [ "${st#Z}" = "$st" ]
}

# stop_decoys: TERM (then KILL) every decoy started so far and forget them.
# Called at the end of each phase, not only at exit: a decoy that is meant to
# survive its own phase would otherwise still be alive during the next phase's
# hardening gate and be counted as a bystander there.
stop_decoys() {
    local p i=0 any
    for p in $DECOY_PIDS; do kill -TERM "$p" 2>/dev/null || true; done
    while [ "$i" -lt 30 ]; do
        any=0
        for p in $DECOY_PIDS; do alive "$p" && any=1; done
        [ "$any" = 0 ] && break
        sleep 0.1
        i=$((i + 1))
    done
    for p in $DECOY_PIDS; do kill -KILL "$p" 2>/dev/null || true; done
    wait 2>/dev/null || true
    DECOY_PIDS=""
    return 0
}

cleanup() {
    stop_decoys
    [ -n "${TMP:-}" ] && rm -rf "$TMP"
    return 0
}
trap cleanup EXIT

# ------------------------------------------------------------------ the block
# block_of <script file>: print the ZD_CT_DHCP block, from its `if` line to the
# first column-0 `fi`.  The same anchor is used on both revisions.
block_of() {
    awk '
        $0 == "if [ -n \"${ZD_CT_DHCP:-}\" ]; then" { inblock = 1 }
        inblock { print }
        inblock && $0 == "fi" { exit }
    ' "$1"
}

# stage_block <script file> <dir>: write that revision's block, with the same
# set -euo pipefail the script itself runs under (zd1200-ct-net.sh:30), to
# <dir>/block.sh so that the pattern never reaches any invoking command line.
stage_block() {
    local src="$1" dir="$2"
    mkdir -p "$dir" || fail "cannot create $dir"
    block_of "$src" > "$dir/block.body" || fail "cannot extract the block from $src"
    grep -q 'ZD_CT_DHCP' "$dir/block.body" \
        || fail "the extracted block of $src does not contain the ZD_CT_DHCP guard; the harness anchor is wrong"
    { printf 'set -euo pipefail\n'; cat "$dir/block.body"; } > "$dir/block.sh"
}

# ----------------------------------------------------------------- the decoys
launch_decoys() {  # <dir>
    local dir="$1" p
    # (a) cmdline-only look-alike: argv0 is "dhclient $IFACE", the executable is
    #     sleep.  Not really dhclient.
    "$BASH_BIN" -c "exec -a \"dhclient $IFACE\" sleep 300" &
    p=$!; printf '%s\n' "$p" > "$dir/pid-a"; DECOY_PIDS="$DECOY_PIDS $p"
    # (b)/(c) real-shaped clients: the executable itself is dhclient (a copy of
    #     bash), the Proxmox argv, the interface as its own final argument.
    "$DECOY_DIR/dhclient" -c "read _ < $FIFO" \
        dhclient -4 -v -i -pf "/run/dhclient.$IFACE.pid" \
        -lf "/var/lib/dhcp/dhclient.$IFACE.leases" -I \
        -df "/var/lib/dhcp/dhclient6.$IFACE.leases" "$IFACE" &
    p=$!; printf '%s\n' "$p" > "$dir/pid-b"; DECOY_PIDS="$DECOY_PIDS $p"
    "$DECOY_DIR/dhclient" -c "read _ < $FIFO" \
        dhclient -4 -v -i -pf "/run/dhclient.$OTHER_IF.pid" \
        -lf "/var/lib/dhcp/dhclient.$OTHER_IF.leases" -I \
        -df "/var/lib/dhcp/dhclient6.$OTHER_IF.leases" "$OTHER_IF" &
    p=$!; printf '%s\n' "$p" > "$dir/pid-c"; DECOY_PIDS="$DECOY_PIDS $p"
}

# await_shape <pid> <comm> <argv element>: bounded wait until that pid has run
# its exec (so /proc/<pid>/comm is <comm>) and its command line holds that exact
# argument.  This is what makes a decoy the shape the case is about.
await_shape() {
    local pid="$1" comm="$2" argv="$3" i=0
    while [ "$i" -lt 100 ]; do
        if [ "$(cat "/proc/$pid/comm" 2>/dev/null || true)" = "$comm" ] \
           && tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep -qxF "$argv"; then
            return 0
        fi
        sleep 0.05
        i=$((i + 1))
    done
    return 1
}

# assert_only_decoys <dir> <label>: the hardening gate.  Same regex pkill -f
# uses (ERE over the space-joined command line), over `ps -eo`, and the pre-fix
# block is not allowed to run unless the ONLY matching processes are decoys a and
# b -- the two it is meant to signal.  Anything else, including this harness, and
# we stop before running a host-global match.
assert_only_decoys() {
    local dir="$1" label="$2" want pid args
    want=" $(tr '\n' ' ' < "$dir/pid-a") $(tr '\n' ' ' < "$dir/pid-b") "   # space-delimited
    : > "$dir/matchers.txt"
    : > "$dir/matchers-extra.txt"
    while read -r pid args; do
        [[ "$args" =~ dhclient.*$IFACE ]] || continue
        printf '%s %s\n' "$pid" "$args" >> "$dir/matchers.txt"
        case "$want" in *" $pid "*) continue ;; esac
        printf '%s %s\n' "$pid" "$args" >> "$dir/matchers-extra.txt"
    done < <(ps -eo pid=,args=)
    [ -s "$dir/matchers-extra.txt" ] && { sed -e 's/^/     /' "$dir/matchers-extra.txt" >&2
        fail "$label: refusing to run the block: processes other than this test's own"
    }
    return 0
}

# run_block <dir> <PATH value>: run a staged block with the ZD_CT_DHCP branch
# armed.  Invoked as `<bash> <file>`, so the pattern stays inside the file.
run_block() {
    local dir="$1" path="$2"
    env ZD_CT_DHCP=1 HOST_IF="$IFACE" STUB_LOG="$dir/stub.log" PATH="$path" \
        "$BASH_BIN" "$dir/block.sh" > "$dir/block.out" 2>&1
    return $?
}

# measure <dir> <label>: three decoys, shaped and gated, then that revision's
# block.  Leaves state-{a,b,c} (alive|killed), rc, block.out, stub.log and the
# observed exe/cmdline of each decoy in <dir>.
measure() {
    local dir="$1" label="$2" c p
    mkdir -p "$dir" || fail "cannot create $dir"
    launch_decoys "$dir"
    await_shape "$(cat "$dir/pid-a")" sleep "dhclient $IFACE" \
        || fail "$label: decoy a never reached its exec'd shape (harness problem)"
    await_shape "$(cat "$dir/pid-b")" dhclient "$IFACE" \
        || fail "$label: decoy b never came up as the dhclient for $IFACE (harness problem)"
    await_shape "$(cat "$dir/pid-c")" dhclient "$OTHER_IF" \
        || fail "$label: decoy c never came up as the dhclient for $OTHER_IF (harness problem)"
    for c in a b c; do
        p="$(cat "$dir/pid-$c")"
        readlink "/proc/$p/exe" 2>/dev/null > "$dir/exe-$c" || printf '?\n' > "$dir/exe-$c"
        tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null > "$dir/cmd-$c" || true
        printf '     %s decoy %s: exe %s | %s\n' "$label" "$c" \
            "$(cat "$dir/exe-$c")" "$(cat "$dir/cmd-$c")"
    done
    assert_only_decoys "$dir" "$label"
    printf '     %s: only %s match "dhclient.*%s" on this host (the two decoys)\n' \
        "$label" "$(wc -l < "$dir/matchers.txt")" "$IFACE"
    run_block "$dir" "$STUB_DIR:$PATH"
    printf '%s\n' "$?" > "$dir/rc"
    for c in a b c; do
        if alive "$(cat "$dir/pid-$c")"; then printf 'alive\n' > "$dir/state-$c"
        else printf 'killed\n' > "$dir/state-$c"; fi
    done
    stop_decoys
}

# ------------------------------------------------------------------ the stages
FIXED="$TMP/fixed"
stage_block "$SCRIPT" "$FIXED"
# The fix must be a kill by PID, not a pattern match, and must leave the release
# call, the guard and the address move that follows it alone.
grep -nE '^[[:space:]]*pkill' "$SCRIPT" >/dev/null 2>&1 \
    && fail "$SCRIPT still runs pkill as a command"
grep -qF 'dhclient -r "$HOST_IF"' "$SCRIPT" || fail "the dhclient -r release is gone from $SCRIPT"
grep -qF 'if [ -n "${ZD_CT_DHCP:-}" ]; then' "$SCRIPT" || fail "the ZD_CT_DHCP guard is gone from $SCRIPT"
grep -qF 'ip addr flush dev "$HOST_IF"' "$SCRIPT" || fail "the address move that follows the kill is gone from $SCRIPT"
grep -qF 'kill -TERM' "$FIXED/block.body" || fail "the fixed block does not kill anything by PID"
pass "the fixed block kills by PID and keeps the guard, the dhclient -r release and the address move"

PREFIX="$TMP/prefix"
mkdir -p "$PREFIX" || fail "cannot create $PREFIX"
HAVE_PRE_FIX=0
if command -v git >/dev/null 2>&1 \
        && git -C "$REPO" cat-file -e "$PRE_FIX_REV:scripts/container/proxmox/zd1200-ct-net.sh" 2>/dev/null; then
    git -C "$REPO" show "$PRE_FIX_REV:scripts/container/proxmox/zd1200-ct-net.sh" \
        > "$PREFIX/script.sh" 2>/dev/null || true
fi
if [ -s "$PREFIX/script.sh" ]; then
    stage_block "$PREFIX/script.sh" "$PREFIX"
    grep -q 'pkill -f' "$PREFIX/block.body" \
        || fail "$PRE_FIX_REV: the extracted block has no pkill -f; the harness is not measuring the defect"
    HAVE_PRE_FIX=1
    printf '     measured pre-fix line: %s:%s\n' "$PRE_FIX_REV" \
        "$(grep -n 'pkill -f' "$PREFIX/script.sh" | cut -d: -f1)"
    sed -e 's/^/     /' "$PREFIX/block.body"
fi

# ------------------------------------------------------ the baseline, first
# The pre-fix revision has to exhibit the defect, so it is measured before the
# fixed one and with the gate above in place.
if [ "$HAVE_PRE_FIX" = 1 ]; then
    measure "$PREFIX" "$PRE_FIX_REV"
    [ "$(cat "$PREFIX/rc")" = 0 ] \
        || fail "$PRE_FIX_REV block exited $(cat "$PREFIX/rc"), not 0"
    [ ! -s "$PREFIX/block.out" ] \
        || fail "$PRE_FIX_REV block printed output: $(cat "$PREFIX/block.out")"
    grep -qF -- "-r $IFACE" "$PREFIX/stub.log" \
        || fail "$PRE_FIX_REV: the stubbed dhclient -r was never called; the harness did not drive the branch"
    [ "$(cat "$PREFIX/state-b")" = killed ] \
        || fail "$PRE_FIX_REV: the real-shaped dhclient for $IFACE survived; the harness is not reproducing the kill"
    [ "$(cat "$PREFIX/state-a")" = killed ] \
        || fail "$PRE_FIX_REV: the cmdline-only look-alike survived; the harness is NOT reproducing the defect"
    [ "$(cat "$PREFIX/state-c")" = alive ] \
        || fail "$PRE_FIX_REV: the control dhclient for $OTHER_IF was killed"
    pass "$PRE_FIX_REV: the host-global match kills the look-alike AND the real client, and spares the control"
fi

# ------------------------------------------------------------- the fixed one
measure "$FIXED" "HEAD"
[ "$(cat "$FIXED/rc")" = 0 ] || fail "the fixed block exited $(cat "$FIXED/rc"), not 0"
[ ! -s "$FIXED/block.out" ] || fail "the fixed block printed output: $(cat "$FIXED/block.out")"
grep -qF -- "-r $IFACE" "$FIXED/stub.log" \
    || fail "HEAD: the stubbed dhclient -r was never called; the harness did not drive the branch"
[ "$(cat "$FIXED/state-b")" = killed ] \
    || fail "the fixed block did not stop the dhclient whose own argv names $IFACE"
pass "the fixed block stops the dhclient whose own executable is dhclient and whose argv names $IFACE (by PID)"
[ "$(cat "$FIXED/state-a")" = alive ] \
    || fail "the fixed block killed a process whose cmdline merely says 'dhclient $IFACE' but whose executable is not dhclient"
pass "the fixed block leaves the cmdline-only look-alike alone"
[ "$(cat "$FIXED/state-c")" = alive ] \
    || fail "the fixed block killed the dhclient for $OTHER_IF"
pass "the fixed block leaves another interface's dhclient alone"

# -------------------------------------------------------- before and after
if [ "$HAVE_PRE_FIX" = 1 ]; then
    word() { [ "$1" = killed ] && printf 'decoy killed' || printf 'decoy survived'; }
    printf '     a  cmdline-only look-alike (exe %s, argv0 "dhclient %s"): before: %s; after: %s\n' \
        "$(cat "$PREFIX/exe-a")" "$IFACE" "$(word "$(cat "$PREFIX/state-a")")" "$(word "$(cat "$FIXED/state-a")")"
    printf '     b  dhclient for %s (exe %s, argv names it): before: %s; after: %s\n' \
        "$IFACE" "$(cat "$PREFIX/exe-b")" "$(word "$(cat "$PREFIX/state-b")")" "$(word "$(cat "$FIXED/state-b")")"
    printf '     c  control dhclient for %s (exe %s): before: %s; after: %s\n' \
        "$OTHER_IF" "$(cat "$PREFIX/exe-c")" "$(word "$(cat "$PREFIX/state-c")")" "$(word "$(cat "$FIXED/state-c")")"
    [ "$(cat "$PREFIX/state-a")" = killed ] && [ "$(cat "$FIXED/state-a")" = alive ] \
        || fail "the harness is not discriminating: the look-alike was not killed before the fix and spared after it"
    [ "$(cat "$PREFIX/state-b")" = killed ] && [ "$(cat "$FIXED/state-b")" = killed ] \
        || fail "the fix dropped the kill it exists to make: the real client must die on both revisions"
    [ "$(cat "$FIXED/state-c")" = alive ] \
        || fail "the fix reaches another interface's client"
    pass "before: look-alike killed, real client killed; after: look-alike survived, real client killed, control untouched"
    pass "the harness is discriminating: $PRE_FIX_REV exhibits the defect the fixed revision removes"
else
    echo "skipped: $PRE_FIX_REV:scripts/container/proxmox/zd1200-ct-net.sh is not in this clone"
    echo "         (shallow or rewritten history); the fixed block is still checked,"
    echo "         but the harness is not shown discriminating."
fi

# ------------------------------------------------- degrading safely, on the fix
# (d) nothing to stop at all: a silent, successful no-op.
NONE="$TMP/none"
mkdir -p "$NONE" || fail "cannot create $NONE"
cp "$FIXED/block.sh" "$NONE/block.sh" || fail "cannot stage $NONE"
run_block "$NONE" "$STUB_DIR:$PATH" \
    || fail "the fixed block exited non-zero with nothing to stop"
[ ! -s "$NONE/block.out" ] || fail "the fixed block printed output with nothing to stop: $(cat "$NONE/block.out")"
grep -qF -- "-r $IFACE" "$NONE/stub.log" \
    || fail "the stubbed dhclient -r was never called; the harness did not drive the branch"
pass "with nothing to stop, the fixed block is a silent no-op (exit 0)"

# (e) no dhclient binary: the :228 guard skips the whole branch, and nothing is
# signalled.  This is why the defect never fired on this workstation, where
# `command -v dhclient` fails.
GUARD="$TMP/guard"
mkdir -p "$GUARD" || fail "cannot create $GUARD"
cp "$FIXED/block.sh" "$GUARD/block.sh" || fail "cannot stage $GUARD"
launch_decoys "$GUARD"
await_shape "$(cat "$GUARD/pid-b")" dhclient "$IFACE" \
    || fail "guard case: decoy b never came up (harness problem)"
assert_only_decoys "$GUARD" "guard case"
run_block "$GUARD" "$MIN_DIR" || fail "the fixed block exited non-zero with no dhclient on PATH"
[ ! -s "$GUARD/block.out" ] || fail "the fixed block printed output with no dhclient on PATH: $(cat "$GUARD/block.out")"
[ ! -e "$GUARD/stub.log" ] || fail "a dhclient was run although none is on PATH"
for c in a b c; do
    [ "$(if alive "$(cat "$GUARD/pid-$c")"; then echo alive; else echo killed; fi)" = alive ] \
        || fail "the fixed block signalled decoy $c although no dhclient is on PATH"
done
pass "with no dhclient on PATH the branch is skipped and nothing is signalled (exit 0)"
stop_decoys

# (f) /proc entries the walk cannot read.  Every run above already walks the real
# /proc, where other users' processes have an unreadable exe and kernel threads
# have none; those runs exited 0, which is the property under test.  Counted
# here so the coverage is visible rather than assumed.
n=0
for d in /proc/[0-9]*; do readlink "$d/exe" >/dev/null 2>&1 || n=$((n + 1)); done
printf '     the fixed block ran (exit 0, silent) with %s /proc entries whose exe this uid cannot read\n' "$n"
pass "unreadable, non-dhclient and vanished /proc entries are skipped, never errors"

[ ! -s "$HARNESS_SIGNALS" ] || { cat "$HARNESS_SIGNALS" >&2
    fail "the harness itself was signalled by the block under test ($(wc -l < "$HARNESS_SIGNALS") TERM(s))"; }
pass "the block under test signalled no process outside its intended decoys"

echo
echo "all ct-net dhclient-scope tests passed"
