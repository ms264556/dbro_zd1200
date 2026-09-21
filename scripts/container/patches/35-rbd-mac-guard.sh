#!/usr/bin/env bash
#
# 35-rbd-mac-guard.sh — stop the guest's own board-data tool from changing the MAC.
#
# /bin/rbd.sh is the vendor CLI for rewriting board data (serial, model, MACs).
# It pipes a canned answer set to /usr/sbin/rbd, whose `change` command calls
# bsp_set/bsp_commit and persists the result to the CF.  It is the documented
# way to restore a dead unit's serial and MAC onto a replacement
# (see the "rbd.sh {board} {model} {serial} {OUI} {mac1} {mac2}" usage).
#
# Under the one-address-per-port design the guest's MAC is the container's own
# uplink MAC, so letting the guest move it is a foot-gun: the guest would come
# back on an address the hypervisor's port does not expect.  The container is
# the authority -- launch-vm.sh rewrites the MAC fields in the board data before
# every launch -- so this patch only has to close the guest-side door and say
# why, rather than try to restore values it cannot know.
#
# What still works: every invocation that does not move the MAC, i.e. a
# serial/model/customer update such as
#     rbd.sh "" "" 123456000789 "" "" "" ""
# What now fails loudly: an invocation that supplies a MAC, with a message
# pointing at the container's own MAC as the thing to change instead.
#
# Usage: QCOW=<flat-disk> WORK=<workdir> ./35-rbd-mac-guard.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCOW="${QCOW:-$(dirname "$BASE")/synthetic-cf.img}"
WORK="${WORK:-$(dirname "$BASE")/.rootfs-patch-work}"
ALIGN=512
# shellcheck source=../patch-lib.sh
. "$(dirname "$BASE")/patch-lib.sh"

TARGET="/bin/rbd.sh"

# Both roots carry a copy (A/B failover), and a firmware upgrade installs a
# fresh vendor rootfs into the spare one, so guard both.
# The roots this run may touch: prepare-vm-disks.sh passes its per-root
# selection in ZD_PATCH_PARTS; with none set this is the full root pair
# (patch-lib.sh:patch_parts), which is how the patch tests drive it.
load_patch_parts

[ -f "$QCOW" ] || { echo "QCOW not found: $QCOW" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"

# Build the guarded copy of the vendor script from one root's own vendor content.
# Any selected root can supply it: every root in the selection is unpatched by
# construction (a stale sentinel means prepare-vm-disks.sh restored it first),
# but this re-derives it per root rather than assuming, so a partially patched
# pair is detected instead of mis-copied.
#
# Returns non-zero when the root has nothing to do; the caller decides whether
# that is "already guarded" (fine) or "not the script we expect" (a failure).
build_guarded_script() {   # <name> -> $WORK/rbd.sh.patched, $WORK/rbd.mode
    local name="$1"
    if ! fs_read "$WORK/$name.img" "$TARGET" "$WORK/rbd.sh.orig"; then
        echo "  [$name] no $TARGET; nothing to patch here"
        return 1
    fi
    if grep -q 'ZD-MAC-GUARD' "$WORK/rbd.sh.orig"; then
        echo "  [$name] $TARGET already carries the MAC guard"
        return 1
    fi
    if ! grep -q '^rbd change > /dev/null <<EOF$' "$WORK/rbd.sh.orig"; then
        echo "  [$name] unexpected $TARGET: the 'rbd change' heredoc was not found" >&2
        return 1
    fi
    # The guard must go BEFORE the `rbd change` invocation.  Inserting it after
    # the heredoc terminator lets the vendor tool run first, so the board data
    # has already been rewritten by the time the guard exits -- it would look
    # like a refusal while the change had in fact been applied.  The MAC
    # arguments are assigned above this line, so they are known here.
    awk '
        /^rbd change > \/dev\/null <<EOF$/ && !done {
            done = 1
            print "# --- ZD-MAC-GUARD: the MAC belongs to the container, not the guest ---"
            print "# The container writes the MAC fields into the board data before every"
            print "# boot (scripts/container/launch-vm.sh), so a guest-side change would be"
            print "# reverted on the next boot anyway.  Refuse it before rbd runs, rather"
            print "# than let the write happen and then report a failure."
            print "if [ -n \"$OUI\" ] || [ -n \"$MAC1\" ] || [ -n \"$MAC2\" ]; then"
            print "    echo \"rbd.sh: refusing to change the MAC: this appliance uses the\" >&2"
            print "    echo \"        container/VM MAC, and the container re-asserts it in the\" >&2"
            print "    echo \"        board data before every boot.  Change the MAC on the\" >&2"
            print "    echo \"        container or VM instead (Proxmox: Hardware > Network).\" >&2"
            print "    echo \"        Serial, model and customer updates still work: pass \\\"\\\" for\" >&2"
            print "    echo \"        the OUI/mac1/mac2 arguments.\" >&2"
            print "    exit 2"
            print "fi"
            print ""
        }
        { print }
    ' "$WORK/rbd.sh.orig" > "$WORK/rbd.sh.patched"
    if ! grep -q 'ZD-MAC-GUARD' "$WORK/rbd.sh.patched"; then
        echo "  [$name] guard insertion failed" >&2
        return 1
    fi
    # Preserve the vendor mode (0755) and ownership.
    rbd_mode="$(fs_stat_meta "$WORK/$name.img" "$TARGET" | awk '{print $2}')"
    printf '%s' "${rbd_mode:-0100755}" > "$WORK/rbd.mode"
    return 0
}

patched_any=0
missing_any=0
patched_parts=()
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    say "[$name] installing the MAC guard into $TARGET"
    # Check before snapshotting: nothing has been modified yet, so a root with
    # no work to do must not leave a snapshot behind.
    extract_part "$name" "$start" "$sectors"
    if ! build_guarded_script "$name"; then
        # Absent target and an already-guarded root are both "no action", but
        # absent is worth reporting at the end: it means this firmware release
        # has no such script and the guard is not protecting anything.
        fs_exists "$WORK/$name.img" "$TARGET" || missing_any=1
        continue
    fi

    snapshot_orig "$name"
    IMG="$WORK/$name.img"
    pr_init "$IMG"
    # shellcheck disable=SC2046  # mode is a single "0MMM" token
    write_local "$IMG" "$TARGET" "$WORK/rbd.sh.patched" "$(cat "$WORK/rbd.mode")"
    if write_deltas "$name" "$start"; then
        patched_any=1
        patched_parts+=("$part")
        echo "  OK   $name: MAC guard installed"
    else
        echo "  no byte changes for $name"
    fi
done

if [ "$patched_any" = 0 ]; then
    if [ "$missing_any" = 1 ]; then
        say "no $TARGET in any selected root; this firmware release needs no guard"
    else
        say "no patch produced changes; nothing written to the disk"
    fi
    exit 0
fi

say "verifying: re-reading the disk and comparing each patched partition"
ln -sf "$QCOW" "$WORK/flat.verify.raw"
for part in "${patched_parts[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    dd if="$WORK/flat.verify.raw" of="$WORK/$name.verify.img" bs=$ALIGN \
       skip="$start" count="$sectors" status=none
    if cmp -s "$WORK/$name.verify.img" "$WORK/$name.img"; then
        echo "OK   $name: disk matches the patched partition image"
    else
        echo "FAIL $name: disk does not match the patched partition image" >&2
        exit 1
    fi
    fs_read "$WORK/$name.verify.img" "$TARGET" "$WORK/$name.rbd.disk" || true
    if grep -q 'ZD-MAC-GUARD' "$WORK/$name.rbd.disk" 2>/dev/null; then
        echo "OK   $name: $TARGET carries the guard"
    else
        echo "FAIL $name: $TARGET on the disk has no guard" >&2
        exit 1
    fi
done

say "done — MAC guard installed in $QCOW"
