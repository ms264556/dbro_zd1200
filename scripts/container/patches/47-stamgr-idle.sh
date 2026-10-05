#!/usr/bin/env bash
#
# 47-stamgr-idle.sh — stop the station manager waking the guest 500 times a
# second while idle.
#
# Three bytes of /bin/stamgr, located by signature in patch-file.py (which also
# holds the reasoning): the event loop's per-pass memset of its 49 KB epoll
# buffer becomes zero-length, and its 2 ms epoll_wait cap becomes 100 ms.  Idle
# emulator cost under TCG drops from 22-27% of a core to 6-7%.
#
# A root whose stamgr cannot be placed -- absent, not an ELF, an ambiguous
# signature, non-stock bytes -- is left alone and reported, never an error.
# 40-skip-integrity.sh is what lets the changed binary pass the boot-time md5
# check.
#
# Usage: QCOW=<flat-disk> WORK=<workdir> ./47-stamgr-idle.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../patch-lib.sh
. "$(dirname "$BASE")/patch-lib.sh"
patch_env

TARGET="/bin/stamgr"
PATCHER="$(dirname "$BASE")/patch-file.py"


[ -f "$PATCHER" ] || { echo "patch-file.py not found: $PATCHER" >&2; exit 1; }

apply() { # <name> <img>
    local name="$1" img="$2" orig="$WORK/stamgr.orig" new="$WORK/stamgr.new"
    rm -f "$new"
    if ! fs_read "$img" "$TARGET" "$orig"; then
        echo "  [$name] no $TARGET in this root; nothing to patch here"
        return 0
    fi
    if ! python3 "$PATCHER" --target "$TARGET" --in "$orig" --out "$new" \
            > "$WORK/patch-file.log" 2>&1; then
        echo "  [$name] $TARGET is not what the patch describes; left unchanged:" >&2
        sed 's/^/      /' "$WORK/patch-file.log" >&2
        return 0
    fi
    sed 's/^/  /' "$WORK/patch-file.log"
    if cmp -s "$orig" "$new"; then
        echo "  [$name] nothing to change in $TARGET"
        return 0
    fi
    # Size-neutral by construction; any other length is not this patch.
    if [ "$(wc -c < "$orig")" != "$(wc -c < "$new")" ]; then
        echo "  [$name] patched $TARGET changed size; left unchanged" >&2
        return 0
    fi
    # write_local keeps the vendor mode and ownership.
    write_local "$img" "$TARGET" "$new"
    PATCH_APPLIED=1
}

verify() { # <name> <img>: still an executable regular file
    local t m
    read -r t m _ _ <<< "$(fs_stat_meta "$2" "$TARGET")"
    [ "$t" = "regular" ] && [ "$(( 0$m & 0111 ))" != 0 ]
}

patch_main apply verify
