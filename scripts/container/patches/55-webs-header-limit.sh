#!/usr/bin/env bash
#
# 55-webs-header-limit.sh — give the two releases that omit it the HTTP
# request-field limit the other releases set.
#
# The guest's admin web UI is the vendor's /bin/webs (Embedthis Appweb/EJS), and
# its config is /bin/webs.conf.  10.2.1.0.236 and 10.4.1.0.272 set
#
#     LimitRequestFields 40
#     LimitRequestFieldSize 4096
#
# there; 10.1.2.0.318 and 10.3.1.0.45 do not, so Appweb's compiled-in default of
# 20 request fields applies to them.  A request carrying 21 or more header fields
# is then aborted before the EJS handler runs, and the connection is closed with
# no response at all.  Every AJAX call the setup wizard makes carries 21 fields
# (16 browser defaults plus the page's X-CSRF-Token, X-Prototype-Version,
# X-Requested-With and X-Rico-Version, and a Content-Type override), so on those
# two releases a modern browser can never complete the wizard: its Finish chain
# dies with an empty reply.
#
# Measured live on 10.1.2.0.318: the same AJAX request padded with dummy headers
# returns 200 with the full <ajax-response> at 20 fields, and at 21 the TLS
# connection closes with no response (curl: SSL_read: unexpected eof).  Header
# *size* is irrelevant -- 4 fields of 400 bytes each still return 200 -- so the
# limit that bites is the field count, not LimitRequestFieldSize.  The 20 is
# Appweb's compiled-in default: it is not written in the rootfs (the string
# LimitRequestFields is present in /bin/webs on every release, but no numeric
# default is), which is why this patch states the vendor's own pair rather than
# deriving a value.
#
# The fix is the vendor's own two directives in the vendor's own position:
# immediately after LimitRequests 500 and before ForbidEjsDirs, which is exactly
# where the two control releases carry them.  Nothing else is touched --
# ThreadLimit stays as the release set it (10 on both of these, 60 on the
# controls) -- so the diff is those two added lines and no more.
#
# A file that already carries a LimitRequestFields directive is left
# byte-for-byte alone whatever its value, so a release that sets its own limit
# keeps it.  A file this patch does not recognise -- no LimitRequests anchor to
# place the pair after, no ForbidEjsDirs following it, not the plain-text config
# the vendor's own runtime sed edits, or absent entirely -- is skipped and left
# alone.
#
# The two roots that take the "no ForbidEjsDirs following it" skip -- 9.9.1.0.52
# and 9.13.3.0.164, whose LimitRequests line is followed by a blank line and
# which contain no ForbidEjsDirs anywhere -- were measured on 2026-09-26 and
# are safe to skip, so their insertion point is deliberately NOT guessed:
#   * the unpatched 9.9.1.0.52 and 9.13.3.0.164 factory guests stop answering
#     at the same 21 request fields as the 10.x releases do (20 -> 200 284 with
#     the real lease, 21 -> 000 0 + SSL_read unexpected eof), so their
#     compiled-in default is the same 20;
#   * the 9.x wizard page's own AJAX carries 20 fields -- all five of its
#     page-load POSTs measured at 20, every one loadingFinished, against 21 on
#     the 10.x page -- because 9.x prototype.js sets no X-CSRF-Token (the code
#     read is in HANDOFF.md 10.2 and session10/fix/matrix/matrix-findings.txt);
#   * and the guest wizard's later calls, Finish included, go through the same
#     Prototype/rico path with the same four non-default headers, so they sit at
#     the same 20.  That last step is a code read, not a click-through: an
#     observe-only probe cannot reach Finish without clicking.  The margin is
#     exactly one field, so a future 9.x failure would show up there first.
# Widening the anchor to those roots would change two working releases with no
# measured defect to fix.  If a 9.x failure is ever demonstrated, the insertion
# point there must be CHOSEN deliberately and re-measured, not pattern-matched.
#
# The patch runs under `set -euo pipefail` from prepare-vm-disks.sh,
# which aborts provisioning when a patch exits non-zero, and the entrypoint reads
# that as "shut the container down"; so an input it cannot place must be a no-op
# for that root rather than a cost to the whole appliance.
#
# Usage: QCOW=<flat-disk> WORK=<workdir> ./55-webs-header-limit.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCOW="${QCOW:-$(dirname "$BASE")/synthetic-cf.img}"
WORK="${WORK:-$(dirname "$BASE")/.rootfs-patch-work}"
ALIGN=512
# shellcheck source=../patch-lib.sh
. "$(dirname "$BASE")/patch-lib.sh"

TARGET="/bin/webs.conf"
FIELDS=40
FIELD_SIZE=4096

# Both roots carry the admin server (A/B failover), and a firmware upgrade
# installs a fresh vendor rootfs into the spare one, so both are candidates.
# The roots this run may touch: prepare-vm-disks.sh passes its per-root
# selection in ZD_PATCH_PARTS; with none set this is the full root pair
# (patch-lib.sh:patch_parts), which is how the patch tests drive it.
load_patch_parts

[ -f "$QCOW" ] || { echo "QCOW not found: $QCOW" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"

# build_limited_conf <name>: write the config this root should carry to
# $WORK/webs.conf.new and return 0, or set WEBS_ACTION (missing|already|odd) and
# return 1 when this root needs no write.
build_limited_conf() {
    local name="$1" img="$WORK/$name.img"
    local conf="$WORK/webs.conf.orig" new="$WORK/webs.conf.new"
    local limit_n next_line diff_out added removed
    WEBS_ACTION=""

    rm -f "$new"
    if ! fs_read "$img" "$TARGET" "$conf"; then
        WEBS_ACTION="missing"
        echo "  [$name] no $TARGET in this root; nothing to patch here"
        return 1
    fi

    # A release's own value, whatever it is, is never overwritten with ours.
    if grep -qE '^[[:space:]]*LimitRequestFields([[:space:]]|$)' "$conf"; then
        WEBS_ACTION="already"
        echo "  [$name] $TARGET already sets LimitRequestFields; left byte-for-byte unchanged"
        return 1
    fi

    # A NUL byte means this is not the plain-text config the vendor's own
    # run-time `sed -i 's/SSLProtocol.*/& -TLSv1/g' /bin/webs.conf` edits.
    if [ "$(wc -c < "$conf")" != "$(tr -d '\000' < "$conf" | wc -c)" ]; then
        WEBS_ACTION="odd"
        echo "  [$name] unexpected $TARGET: not plain text; left unchanged" >&2
        return 1
    fi

    # The anchor, and the line the pair must sit before.  LimitRequestBody and
    # LimitRequestFieldSize do not match `LimitRequests` followed by space/EOL.
    limit_n="$(grep -nE '^LimitRequests([[:space:]]|$)' "$conf" | cut -d: -f1 || true)"
    if [ "$(printf '%s\n' "$limit_n" | grep -c . || true)" != 1 ]; then
        WEBS_ACTION="odd"
        echo "  [$name] unexpected $TARGET: no single LimitRequests line; left unchanged" >&2
        return 1
    fi
    next_line="$(sed -n "$((limit_n + 1))p" "$conf")"
    if ! printf '%s' "$next_line" | grep -qE '^ForbidEjsDirs([[:space:]]|$)'; then
        WEBS_ACTION="odd"
        echo "  [$name] unexpected $TARGET: the line after LimitRequests is not ForbidEjsDirs; left unchanged" >&2
        return 1
    fi

    # Insert after the anchor, exactly as the controls carry the pair.  GNU sed
    # copies every other byte through, a missing final newline included.
    printf '/^LimitRequests[[:space:]]/a\\\nLimitRequestFields %s\\\nLimitRequestFieldSize %s\n' \
        "$FIELDS" "$FIELD_SIZE" > "$WORK/webs.conf.sed"
    if ! sed -f "$WORK/webs.conf.sed" "$conf" > "$new"; then
        WEBS_ACTION="odd"
        rm -f "$new"
        echo "  [$name] sed failed on $TARGET; left unchanged" >&2
        return 1
    fi

    # Self-check before writing: the diff must be those two added lines and
    # nothing else.  If it is not, this is not the shape the anchor validation
    # said it was, so this root is left alone rather than written.
    diff_out="$(diff "$conf" "$new" || true)"
    added="$(printf '%s\n' "$diff_out" | grep -c '^> ' || true)"
    removed="$(printf '%s\n' "$diff_out" | grep -c '^< ' || true)"
    if [ "$added" != 2 ] || [ "$removed" != 0 ] \
       || [ "$(printf '%s\n' "$diff_out" | grep '^> ' | sed 's/^> //')" \
            != "$(printf 'LimitRequestFields %s\nLimitRequestFieldSize %s' "$FIELDS" "$FIELD_SIZE")" ]; then
        WEBS_ACTION="odd"
        rm -f "$new"
        echo "  [$name] unexpected $TARGET: the insertion is not exactly the two directives; left unchanged" >&2
        return 1
    fi

    WEBS_ACTION="ok"
    return 0
}

patched_any=0
patched_parts=()
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    say "[$name] installing the request-field limit into $TARGET"
    extract_part "$name" "$start" "$sectors"
    if ! build_limited_conf "$name"; then
        continue
    fi

    snapshot_orig "$name"
    cp "$WORK/webs.conf.new" "$WORK/$name.webs.conf.new"
    IMG="$WORK/$name.img"
    pr_init "$IMG"
    # write_local keeps the file's vendor mode and ownership (and saves the
    # pristine copy in the rollback store).
    write_local "$IMG" "$TARGET" "$WORK/webs.conf.new"
    if write_deltas "$name" "$start"; then
        patched_any=1
        patched_parts+=("$part")
        echo "  OK   $name: LimitRequestFields $FIELDS and LimitRequestFieldSize $FIELD_SIZE added"
    else
        echo "  no byte changes for $name"
    fi
done

if [ "$patched_any" = 0 ]; then
    say "nothing written: no selected root needed the two directives (see the notes above)"
    exit 0
fi

say "verifying: re-reading the disk and comparing each patched partition"
ln -sf "$QCOW" "$WORK/flat.verify.raw"
for part in "${patched_parts[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    dd if="$WORK/flat.verify.raw" of="$WORK/$name.verify.img" bs=$ALIGN \
       skip="$start" count="$sectors" status=none
    fs_read "$WORK/$name.verify.img" "$TARGET" "$WORK/$name.conf.disk" \
        || { echo "FAIL $name: $TARGET is not on the disk" >&2; exit 1; }
    if cmp -s "$WORK/$name.conf.disk" "$WORK/$name.webs.conf.new"; then
        echo "OK   $name: $TARGET on the disk is the patched config"
    else
        echo "FAIL $name: $TARGET on the disk is not the patched config" >&2
        exit 1
    fi
done

say "done — request-field limit installed in $QCOW"
