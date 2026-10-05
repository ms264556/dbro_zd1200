#!/usr/bin/env bash
#
# prepare-vm-disks-test.sh — drives scripts/container/prepare-vm-disks.sh itself,
# offline, against a fixture disk with real ext2 root partitions (debugfs) and
# stubbed vendor machinery.  No firmware, no QEMU, no root, no network.
#
# It pins three contracts of the script:
#
#   SIGNATURES        the patch-set signature (patches, patch-lib.sh, the kernel
#                     patcher, the external payload dirs and the ZD_* knobs that
#                     feed the patches) is what gets written as the sentinel, and
#                     a change in any one of them -- but nothing else -- makes a
#                     root look stale; an unchanged set is a byte-for-byte no-op.
#
#   SENTINEL          each root partition is judged on its own
#   SELECTION         /.patchrollback/sentinel.  Only roots missing the sentinel
#                     (fresh / in-guest upgrade / rollback) or carrying an older
#                     one are customised and passed to the patches in
#                     ZD_PATCH_PARTS; a current root is left alone, and a root
#                     with only the pre-rollback /etc/.zd-image sentinel is
#                     refused rather than patched a second time.
#
#   RESET BEFORE      when the patch set changed, the root is restored from its
#   RE-PATCH          rollback store first, so every patch sees pristine vendor
#                     files: nothing is applied twice and a dropped patch's
#                     additions disappear.  The kernel is keyed on the patcher
#                     hash instead and is never patched twice.
#
# Stubbed: build-synthetic-cf.py (writes ext2 roots from a prebuilt fixture),
# write-boarddata.py and grub-effective-entry.sh (no-ops), patch-kernel.py (appends
# a marker line), and the ordered patches (one tiny patch built on patch-lib.sh).
# Everything else -- the script under test, patch-lib.sh, debugfs -- is real.
#
# Usage: ./scripts/test/prepare-vm-disks-test.sh
set -euo pipefail
[ -z "${ZD_TEST_TRACE:-}" ] || { PS4='+${SECONDS}s '; set -x; }

REPO_CONTAINER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../container" && pwd)"

for tool in debugfs mke2fs python3 sha256sum; do
    command -v "$tool" >/dev/null 2>&1 \
        || { echo "SKIP: $tool not found (e2fsprogs and python3 are required)" >&2; exit 0; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-prepdisks.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

SECTOR=512
# The real roots are ~200 MB each, which makes every run copy and diff nearly a
# gigabyte.  The fixture copy of the script gets a small geometry instead (see
# the shim below); nothing under test depends on the sizes.
HDA2_START=2048;  SECTORS=32768
HDA3_START=34816
declare -A START=([hda2]=$HDA2_START [hda3]=$HDA3_START)
export HDA2_START HDA3_START SECTORS

C="$TMP/container"          # the fixture "BASE": copies of the scripts + stubs
STATE="$TMP/state"
IMG_DIR="$C/image"
PATCHES="$C/patches"
DISK="$STATE/synthetic-cf.img"
export PATCH_LOG="$TMP/patch.log"
mkdir -p "$C" "$STATE" "$IMG_DIR" "$PATCHES"

# --- fixture: scripts under test ---------------------------------------------
cp "$REPO_CONTAINER/patch-lib.sh" "$C/"
# The signature engine and the rootfs patch-table module.  prepare-vm-disks.sh
# hashes binpatch.py into kernel_sig and patch-file.py into patch_sig, so both
# must be present even though the fake patch-kernel.py below does not import them.
cp "$REPO_CONTAINER/binpatch.py" "$C/"
cp "$REPO_CONTAINER/patch-file.py" "$C/"
# The script under test, verbatim except for the four partition-geometry lines.
# Each substitution must match exactly one line, so a change to the real
# geometry fails here instead of silently testing something else.
shrink() { # <exact original line> <replacement>
    [ "$(grep -cxF -- "$1" "$TMP/prep.in")" = 1 ] \
        || fail "prepare-vm-disks.sh no longer has the line '$1'; update this test's geometry shim"
    awk -v o="$1" -v n="$2" '$0 == o { print n; next } { print }' "$TMP/prep.in" > "$TMP/prep.out"
    mv "$TMP/prep.out" "$TMP/prep.in"
}
cp "$REPO_CONTAINER/prepare-vm-disks.sh" "$TMP/prep.in"
shrink 'HDA1_START=62;     HDA1_SECTORS=84506'        'HDA1_START=62;     HDA1_SECTORS=1000'
shrink 'HDA2_START=84568;  HDA2_SECTORS=415152'       "HDA2_START=$HDA2_START;  HDA2_SECTORS=$SECTORS"
shrink 'HDA3_START=499720; HDA3_SECTORS=415152'       "HDA3_START=$HDA3_START; HDA3_SECTORS=$SECTORS"
shrink 'HDA4_START=914872; HDA4_SECTORS=3006008'      'HDA4_START=67584; HDA4_SECTORS=2048'
[ "$(diff "$REPO_CONTAINER/prepare-vm-disks.sh" "$TMP/prep.in" | grep -c '^>')" = 4 ] \
    || fail "geometry shim changed more than the four geometry lines"
mv "$TMP/prep.in" "$C/prepare-vm-disks.sh"

# Vendor "firmware" inputs (contents only matter as hash inputs).
printf 'rootfs v1\n'   > "$IMG_DIR/rootfs.ext2"
printf 'initramfs\n'   > "$IMG_DIR/restoreinitramfs.gz"
printf 'menu\n'        > "$IMG_DIR/menu.lst"
printf '1.0\n'         > "$IMG_DIR/restoreinitramfs.ver"
printf 'stock kernel\n' > "$IMG_DIR/bzImage"

# Stubbed collaborators.
printf '0\n' > "$TMP/grub-entry"
cat > "$C/grub-effective-entry.sh" <<EOF
#!/usr/bin/env bash
cat "$TMP/grub-entry"
EOF
# Board data: a no-op, or a failure when ZD_TEST_FAIL_BOARDDATA is set (a rejected
# MAC, say), to exercise a build that dies after the disk exists.
cat > "$C/write-boarddata.py" <<'EOF'
#!/usr/bin/env python3
import os, sys
sys.exit(1 if os.environ.get('ZD_TEST_FAIL_BOARDDATA') else 0)
EOF
cat > "$C/patch-kernel.py" <<'EOF'
#!/usr/bin/env python3
# fake kernel patcher: appends one marker line, so a double patch is visible
import sys
a = sys.argv
src, dst = a[a.index('--in') + 1], a[a.index('--out') + 1]
open(dst, 'wb').write(open(src, 'rb').read() + b'QEMU-PATCHED\n')
EOF
# Fake disk builder: a sparse disk whose hda2/hda3 are copies of the vendor ext2
# root in $ROOT_FIXTURE (hda1/hda4 stay zero: no filesystem, no fsck).
cat > "$C/build-synthetic-cf.py" <<'EOF'
#!/usr/bin/env python3
import os, subprocess
disk, root = os.environ['SYNTHETIC_DISK'], os.environ['ROOT_FIXTURE']
open(disk, 'wb').close()
h2, h3, n = (int(os.environ[k]) for k in ('HDA2_START', 'HDA3_START', 'SECTORS'))
os.truncate(disk, (h3 + n + 2048) * 512)
for start in (h2, h3):
    subprocess.check_call(['dd', 'if=' + root, 'of=' + disk, 'bs=512', 'seek=%d' % start,
                           'conv=notrunc,sparse', 'status=none'])
EOF

# Vendor root fixture, built once.
stage="$TMP/stage"; ROOT_FIXTURE="$TMP/root.ext2"; export ROOT_FIXTURE
mkdir -p "$stage/etc"
printf 'vendor\n' > "$stage/etc/motd"
printf 'stock kernel\n' > "$stage/bzImage"
truncate -s $((SECTORS * SECTOR)) "$ROOT_FIXTURE"
mke2fs -q -t ext2 -F -d "$stage" "$ROOT_FIXTURE"

# The one ordered patch.  mkpatch <tag>: it appends "+<tag>" to /etc/motd (so a
# second application on the same root would show "+A+A"), creates /etc/added-<tag>,
# and logs the selection it was given and the motd it found.  Changing the tag
# changes the patch file's hash, i.e. the patch-set signature.
mkpatch() {
    cat > "$PATCHES/10-fake.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
BASE="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
ALIGN=512
. "\$(dirname "\$BASE")/patch-lib.sh"
load_patch_parts
mkdir -p "\$WORK"
for part in "\${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "\$part"
    extract_part "\$name" "\$start" "\$sectors"
    snapshot_orig "\$name"
    IMG="\$WORK/\$name.img"
    pr_init "\$IMG"
    fs_read "\$IMG" /etc/motd "\$WORK/motd"
    cur="\$(cat "\$WORK/motd")"
    echo "$1 \$name saw=\$cur" >> "\$PATCH_LOG"
    printf '%s+%s\n' "\$cur" "$1" > "\$WORK/motd.new"
    write_local "\$IMG" /etc/motd "\$WORK/motd.new"
    printf '%s\n' "$1" > "\$WORK/added"
    write_local "\$IMG" /etc/added-$1 "\$WORK/added"
    write_deltas "\$name" "\$start" || true
done
EOF
}

# --- helpers -----------------------------------------------------------------
# run_prep [VAR=value ...]: run the script under test in a clean environment.
# Output goes to $TMP/out, status to $RC.
RC=0
run_prep() {
    RC=0
    env -i PATH="$PATH" HOME="$TMP" TMPDIR="$TMP" \
        STATE_DIR="$STATE" PATCH_LOG="$PATCH_LOG" ROOT_FIXTURE="$ROOT_FIXTURE" \
        HDA2_START="$HDA2_START" HDA3_START="$HDA3_START" SECTORS="$SECTORS" \
        ZD_ROOT_SSH_AUTHORIZED_KEYS="$TMP/no-such-key" "$@" \
        bash "$C/prepare-vm-disks.sh" > "$TMP/out" 2>&1 || RC=$?
}
out_has() { grep -qF -- "$1" "$TMP/out"; }
show_out() { sed 's/^/    | /' "$TMP/out" >&2; }
expect_out() { out_has "$1" || { show_out; fail "$2 (missing output: $1)"; }; }
reject_out() { ! out_has "$1" || { show_out; fail "$2 (unexpected output: $1)"; }; }
expect_ok() { [ "$RC" = 0 ] || { show_out; fail "$1 (exit $RC)"; }; }

root_img() { # <name> -> path of a scratch copy of that root partition
    local f="$TMP/view.$1.img"
    dd if="$DISK" of="$f" bs=$SECTOR skip="${START[$1]}" count=$SECTORS status=none
    printf '%s' "$f"
}
root_cat() { # <name> <path>: file content, "<absent>" when missing
    local img; img="$(root_img "$1")"
    if debugfs -R "stat $2" "$img" 2>/dev/null | grep -q 'Type:'; then
        debugfs -R "cat $2" "$img" 2>/dev/null
    else
        echo "<absent>"
    fi
}
sentinel() { root_cat "$1" /.patchrollback/sentinel | head -n1; }
region_sum() { # <name>: hash of the whole root partition
    dd if="$DISK" bs=$SECTOR skip="${START[$1]}" count=$SECTORS status=none | sha256sum | cut -d' ' -f1
}
log_lines() { [ -f "$PATCH_LOG" ] && wc -l < "$PATCH_LOG" || echo 0; }
last_selection() { # the ZD_PATCH_PARTS-derived partition names the patch ran on, last run
    grep -o '^[A-Za-z0-9_.-]* hda[0-9]' "$PATCH_LOG" | awk '{print $2}'
}

# =============================================================================
# 0. a first build that fails part-way leaves nothing behind that blocks the next
#    start: the disk is built beside its final path and moved into place only
#    after the board data is written, so there is no disk without its marker.
#    Section 1's fresh run below is the recovery: it must still see "no disk yet".
# =============================================================================
mkpatch A
run_prep ZD_TEST_FAIL_BOARDDATA=1
[ "$RC" != 0 ] || { show_out; fail "a failing board-data step did not fail the run"; }
[ ! -e "$DISK" ] || fail "a build that failed after the disk was written left the disk in place"
[ ! -e "$STATE/.disk-built" ] || fail "a failed build wrote the .disk-built marker"
reject_out "Refusing to rebuild" "failed first build"
pass "a first build that fails part-way leaves no disk and no marker"

# =============================================================================
# 1. fresh disk: both roots customised, sentinel = the patch-set signature
# =============================================================================
mkpatch A
run_prep
expect_ok "fresh run"
expect_out "Building the synthetic CF disk — no disk yet" "fresh: disk not built"
expect_out "[hda2] needs customising (sentinel: <none>)" "fresh: hda2 not selected"
expect_out "[hda3] needs customising (sentinel: <none>)" "fresh: hda3 not selected"
[ "$(log_lines)" = 2 ] || fail "fresh: patch should run on exactly two roots (log: $(cat "$PATCH_LOG"))"
for p in hda2 hda3; do
    [ "$(root_cat $p /etc/motd)" = "vendor+A" ] || fail "fresh: $p motd = '$(root_cat $p /etc/motd)'"
    grep -qx "A $p saw=vendor" "$PATCH_LOG" || fail "fresh: patch did not see the vendor file on $p"
done
SIG_A="$(sentinel hda2)"
[[ "$SIG_A" =~ ^[0-9a-f]{64}$ ]] || fail "fresh: sentinel is not a sha256 ('$SIG_A')"
[ "$(sentinel hda3)" = "$SIG_A" ] || fail "fresh: the two roots carry different sentinels"
[ -f "$STATE/.disk-built" ] && grep -q '^rootfs=' "$STATE/.disk-built" || fail "fresh: .disk-built marker missing"
pass "fresh disk: both roots customised and stamped with the patch-set signature"

KSIG="$(cat "$C/patch-kernel.py" "$C/binpatch.py" | sha256sum | cut -d' ' -f1)"
[ "$(root_cat hda2 /.patchrollback/kernel | head -n1)" = "$KSIG" ] || fail "kernel marker is not the patch-kernel.py+binpatch.py hash"
[ "$(root_cat hda2 /bzImage | grep -c QEMU-PATCHED)" = 1 ] || fail "kernel not patched exactly once"
pass "kernel keyed on the patcher hash and patched once"

# =============================================================================
# 2. unchanged inputs: nothing selected, nothing written
# =============================================================================
before2="$(region_sum hda2)"; before3="$(region_sum hda3)"; n="$(log_lines)"
run_prep
expect_ok "no-op run"
expect_out "[hda2] already customised (sentinel $SIG_A); skipping" "no-op: hda2 not skipped"
expect_out "[hda3] already customised (sentinel $SIG_A); skipping" "no-op: hda3 not skipped"
expect_out "every root partition is already customised; nothing to do" "no-op: missing summary"
[ "$(log_lines)" = "$n" ] || fail "no-op: a patch ran"
[ "$(region_sum hda2)" = "$before2" ] && [ "$(region_sum hda3)" = "$before3" ] || fail "no-op: root bytes changed"
pass "unchanged signature: both roots skipped, bytes untouched, no patch run"

# =============================================================================
# 3. sentinel selection: only the root that lacks/has a stale sentinel is done
# =============================================================================
vendor_root() { # reinstall a vendor rootfs (no store, no sentinel) on <name>, as an in-guest upgrade does
    dd if="$ROOT_FIXTURE" of="$DISK" bs=$SECTOR seek="${START[$1]}" conv=notrunc status=none
}
vendor_root hda3
before2="$(region_sum hda2)"; n="$(log_lines)"
run_prep
expect_ok "spare-root upgrade"
expect_out "[hda2] already customised" "upgrade: hda2 should be skipped"
expect_out "[hda3] needs customising (sentinel: <none>)" "upgrade: hda3 should be selected"
reject_out "restoring the vendor rootfs" "upgrade: a store-less root must not be 'reset'"
[ "$(( $(log_lines) - n ))" = 1 ] || fail "upgrade: patch should run on one root"
tail -n 1 "$PATCH_LOG" | grep -q '^A hda3 saw=vendor$' || fail "upgrade: patch did not run on hda3 only"
[ "$(region_sum hda2)" = "$before2" ] || fail "upgrade: the current root hda2 was modified"
[ "$(root_cat hda3 /etc/motd)" = "vendor+A" ] && [ "$(sentinel hda3)" = "$SIG_A" ] \
    || fail "upgrade: hda3 not customised/stamped"
pass "only the root without a sentinel is customised; the current root is left alone"

# A stale sentinel on one root selects just that root, and uses the store.
printf 'stale-signature\n' > "$TMP/stale"
img3="$(root_img hda3)"
debugfs -w -R "rm /.patchrollback/sentinel" "$img3" >/dev/null 2>&1
debugfs -w -R "write $TMP/stale /.patchrollback/sentinel" "$img3" >/dev/null 2>&1
dd if="$img3" of="$DISK" bs=$SECTOR seek="$HDA3_START" conv=notrunc status=none
[ "$(sentinel hda3)" = "stale-signature" ] || fail "fixture: could not plant a stale sentinel"
before2="$(region_sum hda2)"; n="$(log_lines)"
run_prep
expect_ok "stale sentinel"
expect_out "[hda3] patch set changed (sentinel: stale-signature); restoring the vendor rootfs" "stale: no reset message"
expect_out "[hda2] already customised" "stale: hda2 should be skipped"
[ "$(( $(log_lines) - n ))" = 1 ] && tail -n 1 "$PATCH_LOG" | grep -q '^A hda3 saw=vendor$' \
    || fail "stale: patch should run on hda3 only, seeing vendor"
[ "$(region_sum hda2)" = "$before2" ] || fail "stale: hda2 modified"
[ "$(sentinel hda3)" = "$SIG_A" ] || fail "stale: sentinel not refreshed"
pass "a stale sentinel selects just that root and restores it from the store"

# Legacy /etc/.zd-image sentinel with no store is refused, nothing written.
vendor_root hda3
img3="$(root_img hda3)"
printf 'old\n' > "$TMP/legacy"
debugfs -w -R "write $TMP/legacy /etc/.zd-image" "$img3" >/dev/null 2>&1
dd if="$img3" of="$DISK" bs=$SECTOR seek="$HDA3_START" conv=notrunc status=none
before3="$(region_sum hda3)"; n="$(log_lines)"
run_prep
[ "$RC" = 1 ] || { show_out; fail "legacy: expected exit 1, got $RC"; }
expect_out "was customised by an older version of this project" "legacy: no refusal message"
[ "$(log_lines)" = "$n" ] && [ "$(region_sum hda3)" = "$before3" ] || fail "legacy: something was written"
pass "a legacy-sentinel root without a store is refused untouched"
vendor_root hda3; run_prep; expect_ok "restore hda3 after legacy case"

# =============================================================================
# 4. signatures: which inputs make roots stale
# =============================================================================
# 4a. a changed patch: reset-before-repatch.  The patch must see the vendor
#     motd (not "vendor+A"), A's additions must be gone, B's present.
n="$(log_lines)"
mkpatch B
run_prep
expect_ok "patch set B"
expect_out "[hda2] patch set changed (sentinel: $SIG_A); restoring the vendor rootfs" "B: hda2 not reset"
expect_out "[hda3] patch set changed (sentinel: $SIG_A); restoring the vendor rootfs" "B: hda3 not reset"
reject_out "Building the synthetic CF disk" "B: a patch change must not rebuild the disk"
for p in hda2 hda3; do
    grep -qx "B $p saw=vendor" "$PATCH_LOG" || fail "B: patch saw a non-pristine /etc/motd on $p"
    [ "$(root_cat $p /etc/motd)" = "vendor+B" ] || fail "B: $p motd = '$(root_cat $p /etc/motd)' (double-patched?)"
    [ "$(root_cat $p /etc/added-A)" = "<absent>" ] || fail "B: A's added file survived the reset on $p"
    [ "$(root_cat $p /etc/added-B)" = "B" ] || fail "B: B's added file missing on $p"
done
SIG_B="$(sentinel hda2)"
[ "$SIG_B" != "$SIG_A" ] && [ "$(sentinel hda3)" = "$SIG_B" ] || fail "B: sentinel not updated on both roots"
[ "$(root_cat hda2 /bzImage | grep -c QEMU-PATCHED)" = 1 ] || fail "B: kernel patched again"
expect_out "/bzImage already carries the QEMU patches; leaving it" "B: kernel should be left alone"
pass "changed patch: roots reset to vendor first, nothing applied twice, kernel untouched"

n="$(log_lines)"; run_prep; expect_ok "rerun B"
[ "$(log_lines)" = "$n" ] || fail "B rerun: a patch ran"
pass "re-running the new set is a no-op"

# 4b. reverting the patch gives the original signature back (deterministic)
mkpatch A
run_prep; expect_ok "back to A"
[ "$(sentinel hda2)" = "$SIG_A" ] || fail "reverting to A did not reproduce the A signature"
[ "$(root_cat hda2 /etc/motd)" = "vendor+A" ] && [ "$(root_cat hda2 /etc/added-B)" = "<absent>" ] \
    || fail "reverting to A left B's changes"
pass "signature is a pure function of the inputs: A -> B -> A restores A exactly"

# 4c. every other input folded into the signature
declare -A SEEN=([A]=1)
expect_changes() { # <label> <setup...>: run with a changed input, expect both roots re-done
    local label="$1" n; shift
    n="$(log_lines)"
    "$@"
    run_prep "${EXTRA[@]}"
    expect_ok "$label"
    expect_out "[hda2] patch set changed" "$label: hda2 not re-customised"
    expect_out "[hda3] patch set changed" "$label: hda3 not re-customised"
    [ "$(( $(log_lines) - n ))" = 2 ] || fail "$label: patch did not run on both roots"
    local s; s="$(sentinel hda2)"
    [ -z "${SEEN[$s]:-}" ] || fail "$label: signature collided with an earlier one"
    SEEN[$s]=1
    [ "$(root_cat hda2 /etc/motd)" = "vendor+A" ] || fail "$label: double patched"
    pass "signature covers: $label"
}
EXTRA=()
noop() { :; }
EXTRA=(ZD_ECDSA_SSH=0);          expect_changes "ZD_ECDSA_SSH" noop
EXTRA=(ZD_ECDSA_SSH=0 ZD_NETWORK_MONITOR=0); expect_changes "ZD_NETWORK_MONITOR" noop
EXTRA=(ZD_ECDSA_SSH=0 ZD_NETWORK_MONITOR=0 ZD_VIRTUAL_BUILD_ID=99); expect_changes "ZD_VIRTUAL_BUILD_ID" noop
EXTRA=(ZD_ECDSA_SSH=0 ZD_NETWORK_MONITOR=0 ZD_VIRTUAL_BUILD_ID=99 ZD_PING_INTERVAL_SECONDS=7)
expect_changes "ZD_PING_INTERVAL_SECONDS" noop
BASE_ENV=("${EXTRA[@]}")
mkdir -p "$C/packages/analytics"; printf 'page v1\n' > "$C/packages/analytics/index.html"
EXTRA=("${BASE_ENV[@]}"); expect_changes "analytics payload added" noop
touch_payload() { printf 'page v2\n' > "$C/packages/analytics/index.html"; }
expect_changes "analytics payload edited" touch_payload
printf 'ssh-ed25519 AAAA test\n' > "$TMP/key"
EXTRA=("${BASE_ENV[@]}" ZD_ROOT_SSH_AUTHORIZED_KEYS="$TMP/key"); expect_changes "root ssh key" noop
bump_lib() { printf '# changed\n' >> "$C/patch-lib.sh"; }
expect_changes "patch-lib.sh" bump_lib
bump_kernel() { printf '# changed\n' >> "$C/patch-kernel.py"; }
expect_changes "patch-kernel.py" bump_kernel
# The kernel patcher changed, so /bzImage is keyed anew: re-patched from the root's own kernel.
[ "$(root_cat hda2 /.patchrollback/kernel | head -n1)" = "$(cat "$C/patch-kernel.py" "$C/binpatch.py" | sha256sum | cut -d' ' -f1)" ] \
    || fail "kernel marker not refreshed after the patcher changed"
pass "kernel marker follows the patcher hash"
# binpatch.py (the shared engine) and patch-file.py are signature inputs too: the
# first feeds kernel_sig, the second patch_sig.  Pin both so a future split or
# rename of the engine cannot silently drop them from the signature.
bump_binpatch() { printf '# changed\n' >> "$C/binpatch.py"; }
expect_changes "binpatch.py" bump_binpatch
bump_patchfile() { printf '# changed\n' >> "$C/patch-file.py"; }
expect_changes "patch-file.py" bump_patchfile

# The same inputs again: back to a no-op (the env above is still being passed).
n="$(log_lines)"; run_prep "${EXTRA[@]}"; expect_ok "final no-op"
[ "$(log_lines)" = "$n" ] || fail "identical inputs re-ran the patches"
pass "identical inputs after all of the above: no-op"

# =============================================================================
# 5. the disk itself: a patch change never rebuilds; a new base rootfs is gated
# =============================================================================
# (5a covered in 4a: no "Building the synthetic CF disk".)
cp "$DISK" "$TMP/disk.before"
printf 'rootfs v2\n' > "$IMG_DIR/rootfs.ext2"
run_prep "${EXTRA[@]}"
[ "$RC" = 1 ] || { show_out; fail "rootfs change: expected refusal, got $RC"; }
expect_out "Refusing to rebuild an existing appliance" "rootfs change: no refusal"
cmp -s "$DISK" "$TMP/disk.before" || fail "rootfs change: disk modified despite the refusal"
pass "a new base rootfs is refused (it would discard /writable) and the disk is untouched"

run_prep "${EXTRA[@]}" ZD_ALLOW_DISK_REBUILD=1
expect_ok "forced rebuild"
expect_out "Building the synthetic CF disk — base rootfs changed" "forced rebuild: not rebuilt"
[ "$(root_cat hda2 /etc/motd)" = "vendor+A" ] && [ "$(sentinel hda2)" != "" ] || fail "forced rebuild: roots not customised"
pass "ZD_ALLOW_DISK_REBUILD=1 rebuilds and re-customises both roots"

echo
echo "all prepare-vm-disks tests passed"
