#!/usr/bin/env bash
#
# lxc-install-ctid-race-test.sh — two install-zd1200-lxc.sh runs started together
# on one host, neither given --ctid, must not choose the same container id.
#
# Why this exists: the installer scanned for a free id (next_free_ctid), then
# checked /etc/pve/lxc/<id>.conf (and the qemu-server one) and only then let
# `pct create` make the id real.  That is check-then-use on host-global state:
# two installers started together both saw the same id free and the loser died
# loudly -- "container N already exists" at the check, or inside `pct create` --
# after its own summary had already named that id.
#
# It drives the REAL installer offline: stubs for pct/pvesm/pveam/qm/whiptail/
# pveversion on PATH, a private /etc/pve (an overlay of the real /etc, bind-
# mounted over /etc inside a mount namespace, so nothing on the host is touched)
# and a `pct create` stub that takes 3 s to write /etc/pve/lxc/<id>.conf, the way
# Proxmox does.  Both runs are launched together and stop at `pct create`; the id
# each one chose, and when, is the measurement.
#
#   * one run at a time takes the first free id (120), so the lock is invisible
#     when it is not contended, and what the run writes to stderr after taking
#     the lock still reaches its output (an error after that point must show);
#   * the current installer, two runs together: different ids (120 and 121),
#     creations that do not overlap, and the run that arrives second names
#     /run/zd1200-lxc-install.lock before it blocks;
#   * the same installer with a `flock` that always succeeds (so no run ever
#     waits), two runs together: the SAME id and overlapping creations.  If they
#     do not collide, the harness is not discriminating and this test FAILS
#     rather than claiming a pass;
#   * a killed lock holder leaves no stale lock (flock is held on an open file
#     descriptor, so the kernel drops it when the process dies).
#
# Needs root and `unshare -m`.  Run as root, or let it re-execute itself with
# `sudo -n` when that needs no password; otherwise it skips cleanly.  Every case
# stops at `pct create`: what happens after creation is not covered here.
#
# ZD_CTID_RACE_KEEP_DIR=<dir> keeps each run's own output as evidence.
#
# Usage: ./scripts/test/lxc-install-ctid-race-test.sh   (or sudo ...)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$REPO/install-zd1200-lxc.sh"
LOCK_FILE=/run/zd1200-lxc-install.lock
# How long the `pct create` stub takes to write /etc/pve/lxc/<id>.conf.  Long
# enough that the second run's scan lands inside the first run's creation, which
# is exactly the window the lock has to close.
CREATE_DELAY=3

skip() { printf 'skipped: %s\n' "$*"; exit 0; }
pass() { printf 'ok   %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$INSTALLER" ] || fail "missing $INSTALLER"
command -v unshare >/dev/null 2>&1 || skip "needs unshare (mount namespaces)"

# Root is needed for a mount namespace and to write /etc/pve.  Re-enter under
# `sudo -n` when that needs no password; the marker stops the re-execution from
# looping.
if [ "${ZD_CTID_RACE_ROOT:-0}" != 1 ] && [ "$(id -u)" != 0 ]; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        echo "note: not root; re-executing under sudo -n (mount namespace)"
        if [ -n "${ZD_CTID_RACE_KEEP_DIR:-}" ]; then
            exec sudo -n env ZD_CTID_RACE_ROOT=1 ZD_CTID_RACE_KEEP_DIR="$ZD_CTID_RACE_KEEP_DIR" \
                "$(readlink -f "$0")" "$@"
        fi
        exec sudo -n env ZD_CTID_RACE_ROOT=1 "$(readlink -f "$0")" "$@"
    fi
fi
[ "$(id -u)" = 0 ] || skip "needs root (mount namespace; run with sudo)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-ctid-race.XXXXXX")" || skip "cannot create a scratch directory"
KEEP_DIR="${ZD_CTID_RACE_KEEP_DIR:-}"
cleanup_tmp() {
    if [ -n "$KEEP_DIR" ]; then
        mkdir -p "$KEEP_DIR" && cp -a "$TMP/." "$KEEP_DIR/" 2>/dev/null
        echo "kept: $KEEP_DIR"
    fi
    rm -rf "$TMP"
}
trap cleanup_tmp EXIT

# The installer wants an input and reads none of it before `pct create`: a large
# opaque archive with the TAC magic is classified as a firmware by shape alone.
FIRMWARE="$TMP/zd1200_0.0.0.0.0.ap_0.0.0.0.0.img"
truncate -s 40M "$FIRMWARE" || skip "cannot create the firmware fixture"
printf '\x36\x91\x4a' | dd of="$FIRMWARE" bs=1 conv=notrunc status=none

# ------------------------------------------------------------------- the stubs
write_stubs() {
    local d="$1"
    mkdir -p "$d" || fail "cannot create $d"
    cat > "$d/pct" <<'STUB'
#!/usr/bin/env bash
log="${ZD_TEST_PCT_LOG:-/dev/null}"
if [ "${1:-}" = create ]; then
    id="${2:?}"
    printf 'begin %s %s\n' "$id" "$(date +%s.%N)" >> "$log"
    sleep "${ZD_TEST_CREATE_DELAY:-3}"
    mkdir -p /etc/pve/lxc
    : > "/etc/pve/lxc/$id.conf"
    printf 'end %s %s\n' "$id" "$(date +%s.%N)" >> "$log"
    # Stop the run here: the id it chose is the subject, and everything after
    # creation would need a whole container's worth of further stubs.  The
    # message is written to the installer's stderr, which the lock setup must
    # leave intact.
    echo "stub pct: create stopped here on purpose" >&2
    exit 1
fi
exit 0
STUB
    cat > "$d/pvesm" <<'STUB'
#!/usr/bin/env bash
printf 'Name       Type     Status           Total            Used       Available        %%\n'
printf 'local      dir      active    1000000000       500000000        500000000    50.00%%\n'
STUB
    cat > "$d/pveversion" <<'STUB'
#!/usr/bin/env bash
echo 'pve-manager/9.2.0/0f1a2b3c (running kernel: 6.17.0-test)'
STUB
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/pveam"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/qm"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/whiptail"
    chmod 755 "$d"/* || fail "cannot make the stubs executable"
    # A flock that always succeeds: nothing is ever held, so nothing ever waits.
    mkdir -p "$d-nolock" || fail "cannot create $d-nolock"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d-nolock/flock"
    chmod 755 "$d-nolock/flock" || fail "cannot make the flock stub executable"
}

# The wrapper: private /etc/pve, then the run(s).  It is executed by `unshare -m`,
# so every mount it makes disappears with the namespace.  Mode `solo` runs one
# installer; mode `pair` runs two, launched together.
write_wrapper() {
    cat > "$TMP/wrap.sh" <<'WRAP'
#!/usr/bin/env bash
set -uo pipefail
inst="$1"; base="$2"; stub="$3"; delay="$4"; mode="${5:-pair}"; fw="$6"; extra="${7:-}"
tpl="${8:-debian-13-standard_test.tar.zst}"; more="${9:-}"
mkdir -p "$base/upper/pve/lxc" "$base/upper/pve/qemu-server" "$base/work" "$base/merged" \
        "$base/template-dir" || exit 80
: > "$base/template-dir/$tpl"
mount -t overlay overlay -o "lowerdir=/etc,upperdir=$base/upper,workdir=$base/work" \
      "$base/merged" || exit 90
mount --bind "$base/merged" /etc || exit 91
export PATH="${extra:+$extra:}$stub:$PATH"
export ZD_TEST_CREATE_DELAY="$delay"
args=("$fw" --yes --non-interactive --storage local --bridge vmbr0 \
      --template "$base/template-dir/$tpl")
# shellcheck disable=SC2206  # a plain word list from the test, no globs
args+=($more)
if [ "$mode" = solo ]; then
    env ZD_TEST_PCT_LOG="$base/a.pct" "$inst" "${args[@]}" > "$base/a.txt" 2>&1
    printf '%s\n' "$?" > "$base/a.rc"
    exit 0
fi
env ZD_TEST_PCT_LOG="$base/a.pct" "$inst" "${args[@]}" > "$base/a.txt" 2>&1 &
pa=$!
env ZD_TEST_PCT_LOG="$base/b.pct" "$inst" "${args[@]}" > "$base/b.txt" 2>&1 &
pb=$!
wait "$pa"; a=$?
wait "$pb"; b=$?
printf '%s\n' "$a" > "$base/a.rc"
printf '%s\n' "$b" > "$base/b.rc"
exit 0
WRAP
    chmod 755 "$TMP/wrap.sh"
}

write_stubs "$TMP/bin"
write_wrapper

# run_case <installer> <tag> <solo|pair> [<dir prepended to PATH>] [<template file name>] [<more installer args>]
run_case() {
    local inst="$1" tag="$2" mode="$3" extra="${4:-}" tpl="${5:-}" more="${6:-}" base
    base="$TMP/$tag"
    mkdir -p "$base" || fail "cannot create $base"
    ( cd "$TMP" && unshare -m bash "$TMP/wrap.sh" "$inst" "$base" "$TMP/bin" "$CREATE_DELAY" "$mode" "$FIRMWARE" "$extra" "$tpl" "$more" ) \
        > "$TMP/$tag-wrapper.txt" 2>&1
    WRAP_RC=$?
    case "$WRAP_RC" in
        0) ;;
        90|91) cat "$TMP/$tag-wrapper.txt" >&2
               skip "cannot overlay /etc in a mount namespace (overlayfs unavailable?)" ;;
        *) cat "$TMP/$tag-wrapper.txt" >&2
           fail "the harness wrapper exited $WRAP_RC" ;;
    esac
    [ -f "$base/a.rc" ] || fail "$tag: the run did not finish"
    RC_A="$(cat "$base/a.rc")"
    RC_B=""
    if [ "$mode" = pair ]; then
        [ -f "$base/b.rc" ] || fail "$tag: the runs did not finish"
        RC_B="$(cat "$base/b.rc")"
    fi
}

# one_id <case> <side>: the single container id that run chose (empty if it never
# reached `pct create`).
one_id() {
    local f="$TMP/$1/$2.pct" out
    [ -f "$f" ] || return 0
    out="$(sed -n 's/^begin \([0-9][0-9]*\) .*/\1/p' "$f" | sort -u | tr '\n' ' ')"
    printf '%s' "${out% }"
}
one_time() {  # one_time <case> <side> <begin|end>
    local f="$TMP/$1/$2.pct"
    [ -f "$f" ] || return 0
    awk -v k="$3" '$1==k {print $3; exit}' "$f"
}
overlaps() {  # overlaps <a1> <a2> <b1> <b2>
    awk -v a1="$1" -v a2="$2" -v b1="$3" -v b2="$4" \
        'BEGIN { print (a1+0 < b2+0 && b1+0 < a2+0) ? "yes" : "no" }'
}

# ------------------------- 1. uncontended: one run
run_case "$INSTALLER" solo-current solo
S_CUR="$(one_id solo-current a)"
echo "     solo current: exit $RC_A, id ${S_CUR:-none}"
[ "$S_CUR" = 120 ] || { cat "$TMP/solo-current/a.txt" >&2
    fail "a single uncontended install chose '${S_CUR:-nothing}' instead of the first free id 120"; }
pass "one uncontended install takes the first free id"
grep -qF "stub pct: create stopped here on purpose" "$TMP/solo-current/a.txt" || {
    cat "$TMP/solo-current/a.txt" >&2
    fail "a message written to stderr after the lock was taken never reached the output:
  the lock setup redirected the installer's own stderr, so every later error is invisible"; }
pass "stderr is still the installer's own after the lock is taken"

# --------------------------------------------- 2. the current installer, pair
run_case "$INSTALLER" current pair
ID_A="$(one_id current a)"; ID_B="$(one_id current b)"
echo "     current pair: exit A=$RC_A B=$RC_B, id A=${ID_A:-none}, id B=${ID_B:-none}"
[ -n "$ID_A" ] || { cat "$TMP/current/a.txt" >&2; fail "run A never reached pct create"; }
[ -n "$ID_B" ] || { cat "$TMP/current/b.txt" >&2; fail "run B never reached pct create"; }
[ "$ID_A" != "$ID_B" ] || fail "two concurrent installs with no --ctid both chose container $ID_A:
  the allocation was not serialised (the loser would have died 'already exists')"
pass "the two concurrent installs chose different container ids ($ID_A and $ID_B)"
{ [ "$ID_A" = 120 ] && [ "$ID_B" = 121 ]; } || { [ "$ID_A" = 121 ] && [ "$ID_B" = 120 ]; } \
    || fail "expected the first two free ids (120, 121), got $ID_A and $ID_B"
pass "the ids are the two free ones, so neither installer skipped or reused an id"
OVER="$(overlaps "$(one_time current a begin)" "$(one_time current a end)" \
                  "$(one_time current b begin)" "$(one_time current b end)")"
[ "$OVER" = no ] || {
    cat "$TMP/current/a.pct" "$TMP/current/b.pct" >&2
    fail "the two pct create calls overlapped: creation is still concurrent"
}
pass "the two creations did not overlap -- allocation through creation is serialised"
if grep -qF "holds $LOCK_FILE; waiting for it to release it" "$TMP/current/a.txt" \
        || grep -qF "holds $LOCK_FILE; waiting for it to release it" "$TMP/current/b.txt"; then
    grep -hF "holds $LOCK_FILE; waiting for it to release it" "$TMP/current/a.txt" "$TMP/current/b.txt" \
        | sed -e 's/^/     /'
    pass "the run that arrived second named $LOCK_FILE before it blocked"
else
    cat "$TMP/current/a.txt" "$TMP/current/b.txt" >&2
    fail "neither run reported waiting for $LOCK_FILE; the contended path was not exercised"
fi

# ------------- 3. the same installer with no effective lock: the harness must see the race
run_case "$INSTALLER" nolock pair "$TMP/bin-nolock"
N_A="$(one_id nolock a)"; N_B="$(one_id nolock b)"
echo "     no lock pair: exit A=$RC_A B=$RC_B, id A=${N_A:-none}, id B=${N_B:-none}"
[ -n "$N_A" ] && [ -n "$N_B" ] || { cat "$TMP/nolock/a.txt" "$TMP/nolock/b.txt" >&2
    fail "an unlocked run never reached pct create; the discrimination arm proves nothing"; }
[ "$N_A" = "$N_B" ] || fail "with no effective lock the two runs chose different ids ($N_A, $N_B):
  the harness does not provoke the race, so the passes above prove nothing"
pass "with no effective lock the same two runs collide on container $N_A (the harness can fail)"

# ------------------------------- 4. a killed holder leaves no stale lock
if command -v flock >/dev/null 2>&1; then
    # One process holds the fd (so no child keeps it open): bash opens it, takes
    # the lock, then execs sleep, which inherits both.
    bash -c 'exec 9>"$1" && flock -n 9 || exit 1; exec sleep 30' _ "$LOCK_FILE" &
    HOLDER=$!
    sleep 0.3
    if flock -n "$LOCK_FILE" true 2>/dev/null; then
        kill -9 "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
        fail "the lock was free while a holder was alive -- it is not a real lock"
    fi
    kill -9 "$HOLDER" 2>/dev/null
    wait "$HOLDER" 2>/dev/null
    sleep 0.3
    flock -n "$LOCK_FILE" true 2>/dev/null \
        || fail "the lock outlived its holder: a killed installer would wedge every later install"
    pass "a killed holder leaves no stale lock (flock is released by the kernel, not by cleanup)"
else
    echo "skipped: flock: a killed holder's lock cannot be checked"
fi

# ------------- 5. a Debian 12 template is refused before any container exists
# (its QEMU has no igb NIC model; finding that out after `pct create` leaves a
# half-built container behind)
run_case "$INSTALLER" deb12 solo "" debian-12-standard_test.tar.zst
[ -z "$(one_id deb12 a)" ] || { cat "$TMP/deb12/a.txt" >&2
    fail "a Debian 12 template reached pct create: it was accepted and would fail later, at the igb probe"; }
grep -qF "is Debian 12; the guest needs Debian 13" "$TMP/deb12/a.txt" || { cat "$TMP/deb12/a.txt" >&2
    fail "a Debian 12 template was refused without saying why"; }
[ "$RC_A" != 0 ] || fail "a Debian 12 template did not make the installer fail"
pass "a Debian 12 template is refused with its reason, before pct create"

# ------------- 6. --container-mac: any well-formed value is the container's own MAC
# The pinned value names the container's net0 hwaddr only, so an even or an odd
# last octet are equally fine, shared or not (an unshared guest draws its own MAC
# later, after container creation, which this harness does not reach); a value
# that is not a MAC is refused before anything is created.
for variant in "mac-even:02:aa:bb:cc:dd:ee" "mac-odd:02:aa:bb:cc:dd:ef"; do
    tag="${variant%%:*}"; mac="${variant#*:}"
    run_case "$INSTALLER" "$tag" solo "" "" "--no-shared-mac --container-mac $mac"
    [ "$(one_id "$tag" a)" = 120 ] || { cat "$TMP/$tag/a.txt" >&2
        fail "--no-shared-mac --container-mac $mac did not reach pct create"; }
done
run_case "$INSTALLER" mac-bad solo "" "" "--container-mac not-a-mac"
[ -z "$(one_id mac-bad a)" ] && grep -qF "is not a MAC address" "$TMP/mac-bad/a.txt" || { cat "$TMP/mac-bad/a.txt" >&2
    fail "a malformed --container-mac was not refused before pct create"; }
pass "an even or odd --container-mac reaches pct create; a malformed one is refused before it"

echo
echo "all lxc-install ctid-race tests passed"
