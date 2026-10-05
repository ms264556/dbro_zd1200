#!/usr/bin/env bash
#
# 55-webs-header-limit.sh — add the request-field limit two releases omit.
#
# Appweb's built-in default is 20 header fields; the 10.x setup wizard's AJAX
# sends 21, so on 10.1.2.0.318 and 10.3.1.0.45 the connection closes with no
# reply and the wizard cannot finish.  Insert the pair the other 10.x releases
# ship, in the same position in /bin/webs.conf:
#
#     LimitRequests 500
#   + LimitRequestFields 40
#   + LimitRequestFieldSize 4096
#     ForbidEjsDirs ...
#
# Skipped, never an error: a file that already sets LimitRequestFields (its own
# value is kept), one without that exact LimitRequests/ForbidEjsDirs pair, one
# that is not plain text, or none at all.  9.9 and 9.13 are in the second group
# on purpose: their wizard sends exactly 20 fields, so they work unpatched and
# the insertion point there is not guessed.  Measurements: docs/INTERNALS.md,
# "Notes on individual patches".
#
# Usage: QCOW=<flat-disk> WORK=<workdir> ./55-webs-header-limit.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../patch-lib.sh
. "$(dirname "$BASE")/patch-lib.sh"
patch_env

TARGET="/bin/webs.conf"
FIELDS=40
FIELD_SIZE=4096

# Both roots carry the admin server (A/B failover), and a firmware upgrade
# installs a fresh vendor rootfs into the spare one, so both are candidates.

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

apply() { # <name> <img>
    build_limited_conf "$1" || return 0
    # write_local keeps the vendor mode and ownership.
    write_local "$2" "$TARGET" "$WORK/webs.conf.new"
    PATCH_APPLIED=1
    echo "  OK   $1: LimitRequestFields $FIELDS and LimitRequestFieldSize $FIELD_SIZE added"
}

patch_main apply
