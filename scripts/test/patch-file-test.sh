#!/usr/bin/env bash
#
# patch-file-test.sh — patch-file.py must place the /bin/stamgr idle-loop patch
# on the site its signatures describe, refuse what it cannot place, and be a
# no-op on its own output; and 47-stamgr-idle.sh must carry that through a root
# filesystem without costing a root it cannot patch.
#
# What is checked, on an ELF synthesised here (no vendor material):
#
#   (a) a binary carrying both sites: --self-test finds each exactly once; the
#       patch changes exactly three bytes -- the memset length's 0xc0 and the
#       two cap immediates -- and nothing else; a second run is byte-identical
#       and reports both sites as already patched;
#   (b) a binary carrying neither site is written back unchanged with exit 0
#       (an unrecognised release must install without the fix, not fail);
#   (c) a signature that matches twice is refused, and so is a site whose two
#       cap immediates are neither the stock 2 nor the patched value;
#   (d) a file that is not a 32-bit ELF is refused;
#   (e) 47-stamgr-idle.sh on an ext2 root: the patched binary reaches the disk
#       with its vendor mode, the pristine copy is in the rollback store, a
#       second run writes nothing, and a root with no stamgr, or with one the
#       tool refuses, is left byte-for-byte alone with exit 0.
#
# With AS_STAMGR_DIR=<dir> every file named `stamgr` under <dir> is also
# checked as a real vendor binary: both sites must match exactly once and the
# patch must change exactly three bytes.  The vendor binaries are not in this
# repository, so without it the test reports partial:.
#
# Usage: ./scripts/test/patch-file-test.sh
#        AS_STAMGR_DIR=/path/to/extracted ./scripts/test/patch-file-test.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$REPO/scripts/container/patch-file.py"
PATCH="$REPO/scripts/container/patches/47-stamgr-idle.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-patchfile.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }
partial() { printf 'partial: %s\n' "$*"; }

[ -f "$TOOL" ] || fail "missing $TOOL"
[ -f "$PATCH" ] || fail "missing $PATCH"
T=/bin/stamgr

# --- the fixture binaries ----------------------------------------------------
# make_elf <out> <shape>: a minimal ELF32 with one PT_LOAD covering the file.
# The two sites are written with concrete values where the signatures have
# wildcards, separated by filler that matches neither.
#   both      the memset site and the cap site, stock
#   none      filler only
#   twocaps   both sites, and a second copy of the cap site
#   oddcap    both sites, but the cap immediates are 3 (not stock, not patched)
make_elf() {
    python3 - "$1" "$2" <<'PYEOF'
import struct, sys
out, shape = sys.argv[1], sys.argv[2]
memset = bytes.fromhex("83ec04" "6800c00000" "6a00" "8d85b43fffff" "50"
                       "e8d2cde4ff" "83c410" "83ec04" "6a08" "6a00" "8d45b4" "50")
def cap(n):
    return (bytes.fromhex("8945cc") + bytes([0x83, 0x7d, 0xcc, n, 0x7e, 0x07,
                                             0xc7, 0x45, 0xcc, n, 0, 0, 0])
            + bytes.fromhex("a1c8f74408" "3dc8f74408" "740b" "8b5dcc"
                            "899d983fffff" "eb0a" "c785983fffff00000000"
                            "a18ccf3408" "8b5004" "ffb5983fffff" "6800100000"
                            "8d85b43fffff" "50" "52" "e879bde4ff"))
fill = bytes(range(1, 200)) * 3
body = fill
if shape != "none":
    body += memset + fill + cap(3 if shape == "oddcap" else 2) + fill
if shape == "twocaps":
    body += cap(2) + fill
base = 0x08048000
ehdr = struct.pack("<16sHHIIIIIHHHHHH", b"\x7fELF\x01\x01\x01" + b"\0" * 9,
                   2, 3, 1, base + 0x54, 0x34, 0, 0, 0x34, 0x20, 1, 0, 0, 0)
size = 0x54 + len(body)
phdr = struct.pack("<IIIIIIII", 1, 0, base, base, size, size, 5, 0x1000)
open(out, "wb").write(ehdr + phdr + body)
PYEOF
}

# changed_bytes <a> <b> -> "offset old new" lines (cmp -l, octal values)
changed_bytes() { cmp -l "$1" "$2" || true; }

run_tool() { # <in> <out> <log>
    python3 "$TOOL" --target "$T" --in "$1" --out "$2" > "$3" 2>&1
}

# --- (a) both sites ----------------------------------------------------------
make_elf "$TMP/both" both
python3 "$TOOL" --target "$T" --in "$TMP/both" --self-test > "$TMP/both.self" 2>&1 \
    || fail "(a) --self-test rejected the fixture:
$(cat "$TMP/both.self")"
[ "$(grep -cE '^  ok +stamgr_event_(memset|wait_cap) +unique at ' "$TMP/both.self")" = 2 ] \
    || fail "(a) --self-test did not find both sites exactly once:
$(cat "$TMP/both.self")"
pass "(a) --self-test finds each site exactly once"

run_tool "$TMP/both" "$TMP/both.p" "$TMP/both.log" || fail "(a) the patch failed:
$(cat "$TMP/both.log")"
CH="$(changed_bytes "$TMP/both" "$TMP/both.p")"
[ "$(printf '%s\n' "$CH" | grep -c .)" = 3 ] || fail "(a) expected 3 changed bytes, got:
$CH"
# cmp -l prints octal: 0xc0 = 300 -> 0, and 2 -> the cap the tool is built with.
CAP_OCT="$(python3 - "$TOOL" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pf", sys.argv[1])
pf = importlib.util.module_from_spec(spec); spec.loader.exec_module(pf)
print("%o" % pf.STAMGR_IDLE_CAP_MS)
PYEOF
)"
[ "$(printf '%s\n' "$CH" | awk '{print $2 ">" $3}' | tr '\n' ' ')" = "300>0 2>$CAP_OCT 2>$CAP_OCT " ] \
    || fail "(a) the three changed bytes are not the memset length and the two caps:
$CH"
pass "(a) exactly three bytes change: the memset length and both cap immediates"

run_tool "$TMP/both.p" "$TMP/both.p2" "$TMP/both.log2" || fail "(a) the re-run failed:
$(cat "$TMP/both.log2")"
cmp -s "$TMP/both.p" "$TMP/both.p2" || fail "(a) the re-run changed its own output"
[ "$(grep -c 'already patched' "$TMP/both.log2")" = 2 ] \
    || fail "(a) the re-run did not report both sites as already patched:
$(cat "$TMP/both.log2")"
pass "(a) re-running on the patched binary is a byte-identical no-op"

# --- (b) neither site --------------------------------------------------------
make_elf "$TMP/none" none
run_tool "$TMP/none" "$TMP/none.p" "$TMP/none.log" \
    || fail "(b) a binary with no site must not fail:
$(cat "$TMP/none.log")"
cmp -s "$TMP/none" "$TMP/none.p" || fail "(b) a binary with no site was changed"
grep -q 'note: patches not applicable to this release (skipped)' "$TMP/none.log" \
    || fail "(b) the skip was not reported:
$(cat "$TMP/none.log")"
pass "(b) a binary with no site is written back unchanged, exit 0, skip reported"

# --- (c) refusals ------------------------------------------------------------
make_elf "$TMP/twocaps" twocaps
if run_tool "$TMP/twocaps" "$TMP/twocaps.p" "$TMP/twocaps.log"; then
    fail "(c) an ambiguous signature was accepted"
fi
grep -q 'matched 2 places; refusing to patch (ambiguous)' "$TMP/twocaps.log" \
    || fail "(c) wrong refusal for the ambiguous signature:
$(cat "$TMP/twocaps.log")"
[ ! -e "$TMP/twocaps.p" ] || fail "(c) an output was written for a refused binary"
pass "(c) a signature matching twice is refused and nothing is written"

make_elf "$TMP/oddcap" oddcap
if run_tool "$TMP/oddcap" "$TMP/oddcap.p" "$TMP/oddcap.log"; then
    fail "(c) a non-stock cap site was accepted"
fi
grep -q 'is not the stock site its signature describes' "$TMP/oddcap.log" \
    || fail "(c) wrong refusal for the non-stock site:
$(cat "$TMP/oddcap.log")"
[ ! -e "$TMP/oddcap.p" ] || fail "(c) an output was written for a refused binary"
pass "(c) a cap site that is neither stock nor patched is refused"

# --- (d) not an ELF ----------------------------------------------------------
printf 'not an elf\n' > "$TMP/text"
if run_tool "$TMP/text" "$TMP/text.p" "$TMP/text.log"; then
    fail "(d) a non-ELF file was accepted"
fi
grep -q 'is not a 32-bit ELF' "$TMP/text.log" || fail "(d) wrong refusal:
$(cat "$TMP/text.log")"
pass "(d) a file that is not a 32-bit ELF is refused"

# --- (e) through a root filesystem -------------------------------------------
have_fs=1
for tool in mke2fs debugfs; do
    command -v "$tool" >/dev/null 2>&1 || have_fs=0
done
if [ "$have_fs" = 0 ]; then
    partial "(e) skipped: mke2fs/debugfs (e2fsprogs) not found, so the rootfs patch was not run"
else
    ALIGN=512
    START=84568                 # the flat disk's hda2 sector, as patch-lib defines it
    SECTORS=32768               # 16 MiB, enough for the fixture root
    ROOT_KB=$(( SECTORS * ALIGN / 1024 ))

    build_disk() { # <binary|NONE> <disk>
        local stage="$TMP/stage" part="$TMP/part.img"
        rm -rf "$stage"; mkdir -p "$stage/bin"
        if [ "$1" != NONE ]; then
            cp "$1" "$stage/bin/stamgr"; chmod 0750 "$stage/bin/stamgr"
        fi
        rm -f "$part"
        mke2fs -q -t ext2 -b 1024 -I 128 -m 0 -F -d "$stage" "$part" "$ROOT_KB" >/dev/null 2>&1 \
            || fail "mke2fs failed"
        rm -f "$2"; truncate -s $(( (START + SECTORS) * ALIGN )) "$2"
        dd if="$part" of="$2" bs=$ALIGN seek="$START" conv=notrunc status=none
        rm -rf "$stage" "$part"
    }
    part_image() { rm -f "$2"; dd if="$1" of="$2" bs=$ALIGN skip="$START" count=$SECTORS status=none; }
    read_file() { # <disk> <fspath> <out>
        part_image "$1" "$TMP/read.img"; rm -f "$3"
        debugfs -R "dump $2 $3" "$TMP/read.img" >/dev/null 2>&1
        [ -f "$3" ]
    }
    file_mode() { # <disk> <fspath>
        part_image "$1" "$TMP/meta.img"
        debugfs -R "stat $2" "$TMP/meta.img" 2>/dev/null \
            | awk '{ for (i = 1; i <= NF; i++) if ($i == "Mode:") { print $(i+1); exit } }'
    }
    run_patch() { # <disk> <log>
        ZD_PATCH_PARTS="hda2|$START|$SECTORS" QCOW="$1" WORK="$TMP/work" \
            bash "$PATCH" > "$2" 2>&1
    }

    build_disk "$TMP/both" "$TMP/e.disk"
    run_patch "$TMP/e.disk" "$TMP/e.log" || fail "(e) the rootfs patch failed:
$(cat "$TMP/e.log")"
    read_file "$TMP/e.disk" "$T" "$TMP/e.after" || fail "(e) $T vanished from the root"
    cmp -s "$TMP/e.after" "$TMP/both.p" || fail "(e) $T on the disk is not the patched binary"
    [ "$(file_mode "$TMP/e.disk" "$T")" = "0750" ] \
        || fail "(e) $T lost its vendor mode: $(file_mode "$TMP/e.disk" "$T")"
    read_file "$TMP/e.disk" '/.patchrollback/replaced/!bin!stamgr' "$TMP/e.saved" \
        || fail "(e) no pristine copy of $T in the rollback store"
    cmp -s "$TMP/e.saved" "$TMP/both" || fail "(e) the rollback store's copy is not the vendor binary"
    pass "(e) the patched binary is on the disk with its mode, the vendor copy in the store"

    cp "$TMP/e.disk" "$TMP/e.disk.before"
    run_patch "$TMP/e.disk" "$TMP/e.log2" || fail "(e) the second run failed:
$(cat "$TMP/e.log2")"
    cmp -s "$TMP/e.disk" "$TMP/e.disk.before" || fail "(e) the second run wrote to the disk"
    pass "(e) a second run writes nothing"

    for shape in NONE none twocaps oddcap; do
        src="$TMP/$shape"; [ "$shape" = NONE ] && src=NONE
        build_disk "$src" "$TMP/u.disk"
        cp "$TMP/u.disk" "$TMP/u.disk.before"
        run_patch "$TMP/u.disk" "$TMP/u.log" || fail "(e) [$shape] the rootfs patch exited non-zero:
$(cat "$TMP/u.log")"
        cmp -s "$TMP/u.disk" "$TMP/u.disk.before" \
            || fail "(e) [$shape] a root the patch could not place was written to"
        case "$shape" in
            NONE)           want='no /bin/stamgr in this root' ;;
            none)           want='nothing to change in /bin/stamgr' ;;
            twocaps|oddcap) want='is not what the patch describes; left unchanged' ;;
        esac
        grep -qF "$want" "$TMP/u.log" || fail "(e) [$shape] the outcome was not reported ('$want'):
$(cat "$TMP/u.log")"
    done
    pass "(e) a root with no stamgr, no site, or a refused binary is left alone, reported, exit 0"
fi

# --- real vendor binaries ----------------------------------------------------
if [ -z "${AS_STAMGR_DIR:-}" ]; then
    partial "the synthetic checks ran; real stamgr binaries were not checked (set AS_STAMGR_DIR)"
else
    n=0
    while IFS= read -r f; do
        n=$((n + 1))
        python3 "$TOOL" --target "$T" --in "$f" --self-test > "$TMP/real.self" 2>&1 \
            || fail "[$f] --self-test failed:
$(cat "$TMP/real.self")"
        [ "$(grep -cE '^  ok +stamgr_event_(memset|wait_cap) +unique at ' "$TMP/real.self")" = 2 ] \
            || fail "[$f] both sites were not found exactly once:
$(cat "$TMP/real.self")"
        run_tool "$f" "$TMP/real.p" "$TMP/real.log" || fail "[$f] the patch failed:
$(cat "$TMP/real.log")"
        [ "$(changed_bytes "$f" "$TMP/real.p" | grep -c .)" = 3 ] \
            || fail "[$f] expected 3 changed bytes:
$(changed_bytes "$f" "$TMP/real.p")"
        pass "real binary $f: both sites unique, three bytes changed"
    done < <(find "$AS_STAMGR_DIR" -type f -name stamgr | LC_ALL=C sort)
    [ "$n" -gt 0 ] || fail "AS_STAMGR_DIR=$AS_STAMGR_DIR holds no file named stamgr"
fi

echo
echo "all patch-file tests passed"
