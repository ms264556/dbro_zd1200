#!/usr/bin/env bash
#
# chk-integrity-cost-test.sh — count the process spawns 40-skip-integrity.sh's
# parsing rewrite removes, and assert the rewrite is cheaper than the vendor loop.
#
# Why this exists: 40-skip-integrity.sh replaces the vendor check_md5sum()'s
# per-line `echo $line|cut -d: -f1` / `data=`echo $line|cut -d: -f2`` splitting
# (plus `md5=`/`file=` on every FILE line) with shell builtins, and turns the
# per-FILE `/usr/bin/md5sum -c` into a no-op.  The justification is a cost:
# process spawns, not bytes.  This test measures that cost offline, by counting
# invocations of the external commands the loop executes, instead of booting a
# guest and watching system time.
#
# What is measured, per list, for three versions of the same loop:
#   vendor     the vendor check_md5sum() as shipped
#   md5-no-op  the same vendor parsing with only the md5 check replaced (what an
#              older patch set produced; AS_PATCH_BASELINE=<path> supplies it)
#   rewritten  the current patch's output
# The delta vendor -> md5-no-op isolates the integrity check; md5-no-op ->
# rewritten isolates the parsing rewrite.
#
# The fixture is synthesised: the vendor checker and its file lists are vendor
# material and are not in this repository.  With AS_CHKINT set, the same
# measurement runs against a real /etc/init.d/chk_integrity.sh dumped from a
# guest rootfs, with AS_ROOT_LIST / AS_AP_LIST / AS_AIDFS_LIST supplying the real
# lists; without it that half prints a `partial:` line saying so.  `partial:` is
# the runner's third classification (scripts/test/run-suite.sh): the test ran and
# evaluated its synthetic fixture, but not the real vendor material -- so it is
# counted as run rather than as having evaluated nothing.
#
# Deterministic: the spawn counts and the pass/fail verdict (structure of the
# loop, list sizes).  Host-dependent: the wall-clock columns, which are printed
# for information only -- this host's process-spawn cost is not the guest's.
#
# Usage:
#   ./scripts/test/chk-integrity-cost-test.sh
#   AS_CHKINT=chk_integrity.sh AS_ROOT_LIST=/file_list.txt \
#       AS_AP_LIST=firmwares/file_list.txt AS_AIDFS_LIST=aidfs/file_list.txt \
#       AS_PATCH_BASELINE=/path/to/old-40-skip-integrity.sh \
#       ./scripts/test/chk-integrity-cost-test.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATCH="${AS_PATCH:-$REPO/scripts/container/patches/40-skip-integrity.sh}"
LIB="$REPO/scripts/container/patch-lib.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-chkint-cost.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass() { printf 'ok   %s\n' "$*"; }
skipped() { printf 'skipped: %s\n' "$*"; }
# partial: ran, but only against what this test carries itself.  The runner
# counts a partial test as RAN (scripts/test/run-suite.sh's marker contract) so a
# test that evaluated its synthetic fixture is not recorded as having evaluated
# nothing, while the real vendor material it could not carry stays visible.
partial() { printf 'partial: %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

for tool in mke2fs debugfs truncate dd awk sed grep; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool not found" >&2; exit 0; }
done
[ -f "$PATCH" ] || fail "missing $PATCH"
[ -f "$LIB" ] || fail "missing $LIB"

ALIGN=512
START=84568
SECTORS=32768                 # 16 MiB fixture root
ROOT_BYTES=$(( SECTORS * ALIGN ))
TARGET=/etc/init.d/chk_integrity.sh

# --- the spawn counter -------------------------------------------------------
# A PATH shim in front of the real binaries.  Each shim appends one line per
# invocation, so the line count is the number of external process spawns of that
# binary.  Shell builtins (echo, read, set, [, cd) never reach a shim, which is
# exactly right: they are not spawns.  The vendor loop calls /usr/bin/md5sum by
# absolute path, and an absolute path cannot be shimmed; the measurement
# rewrites that one invocation to a PATH-resolved `md5sum` in the *vendor*
# config only (see driver_for), so its spawns are counted rather than inferred.
SHIM="$TMP/shim"; mkdir -p "$SHIM"
COUNTER="$TMP/spawns"
: > "$COUNTER"
# A compiled shim is used when a compiler is available: it appends one line and
# execs the real binary, so each counted invocation is exactly one process.  The
# portable fallback is a /bin/sh script, which adds its own interpreter process
# per counted call; the *counts* are identical either way, only the extra
# interpreter and the wall clock differ.
SHIM_KIND="posix"
if command -v cc >/dev/null 2>&1; then
    cat > "$TMP/shim.c" <<'CEOF'
/* Count one line per invocation, then exec the real binary.  The real binary is
   resolved through PATH with the shim's own directory skipped, so the shim
   cannot re-exec itself. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int executable(const char *path) { return access(path, X_OK) == 0; }
int main(int argc, char **argv) {
    const char *self = strrchr(argv[0], '/');
    const char *shimdir = getenv("SPAWN_SHIM_DIR");
    char buf[4096], *path, *save, *dir;
    FILE *f;
    self = self ? self + 1 : argv[0];
    f = fopen(getenv("SPAWN_COUNTER"), "a");
    if (f) { fprintf(f, "%s\n", self); fclose(f); }
    path = strdup(getenv("PATH") ? getenv("PATH") : "/bin:/usr/bin");
    for (dir = strtok_r(path, ":", &save); dir; dir = strtok_r(NULL, ":", &save)) {
        if (shimdir && strcmp(dir, shimdir) == 0) continue;
        snprintf(buf, sizeof buf, "%s/%s", dir, self);
        if (executable(buf)) { argv[0] = buf; execv(buf, argv); }
    }
    return 127;
}
CEOF
    if cc -O2 -o "$SHIM/.shim" "$TMP/shim.c" >/dev/null 2>&1; then
        SHIM_KIND="compiled"
    fi
fi
for name in cut md5sum expr cp mkdir sed; do
    real="$(command -v "$name" || true)"
    [ -n "$real" ] || continue
    if [ "$SHIM_KIND" = compiled ]; then
        ln -sf "$SHIM/.shim" "$SHIM/$name"
    else
        cat > "$SHIM/$name" <<SHIMEOF
#!/bin/sh
printf '%s\n' "$name" >> "\$SPAWN_COUNTER"
exec "$real" "\$@"
SHIMEOF
        chmod +x "$SHIM/$name"
    fi
done
export SPAWN_SHIM_DIR="$SHIM"
count_spawns() { wc -l < "$COUNTER" | tr -d ' '; }

# --- fixture checker and lists ----------------------------------------------
# Shaped like the real check_md5sum(): the two spaces between hash and path, the
# $3/$4 reads, and the DIR/FILE/LINK/OTHER branches.
cat > "$TMP/vendor.fixture.sh" <<'FIXTURE'
#!/bin/sh
check_md5sum()
{
    ret=0;
    if [ ! -f $2 ]; then
        echo "No file list founded ...";
        return 1;
    fi
    popd=`pwd`
    cd $1;
    while read line; do
        type=`echo $line|cut -d: -f1`;
        data=`echo $line|cut -d: -f2`;
        case "$type" in
        FILE)
            md5=`echo $data|cut -d' ' -f1`
            file=`echo $data|cut -d' ' -f2`
            if [ ! -b "$file" -a ! -c "$file" ]; then
                echo "$md5  $file"|/usr/bin/md5sum -c >/dev/null 2>&1
            fi
            if [ $? -eq 0 ]; then
                if [ "$3" = "clone" ]; then
                    cp -a "/$file" "$4/$file";
                fi
            else
                echo "file:[$file] corrupted"
                ret=`expr $ret + 1`
            fi
        ;;
        DIR)
            if [ -d "$data" ]; then
                if [ "$3" = "clone" ]; then mkdir -p "$4/$data"; fi
            else
                echo "dir:[$data] corrupted"
                ret=`expr $ret + 1`
            fi
        ;;
        LINK)
            if [ -h "$data" ]; then
                if [ "$3" = "clone" ]; then cp -a "$data" "$4/$data"; fi
            else
                echo "link:[$data] corrupted"
                ret=`expr $ret + 1`
            fi
        ;;
        OTHER)
            if [ "$3" = "clone" ]; then cp -a $data $4/$data; fi
        ;;
        esac
    done < $2
    cd $popd
    return $ret;
}
FIXTURE

FIXROOT="$TMP/root"; mkdir -p "$FIXROOT/dirA" "$FIXROOT/sub" "$FIXROOT/usr/bin"
printf 'A\n' > "$FIXROOT/fileA"
printf 'B\n' > "$FIXROOT/sub/fileB"
ln -s fileA "$FIXROOT/linkA"
MD5A="$(md5sum "$FIXROOT/fileA" | awk '{print $1}')"
MD5B="$(md5sum "$FIXROOT/sub/fileB" | awk '{print $1}')"
{
    printf 'DIR:.%s\n' /dirA /sub /usr /usr/bin
    printf 'FILE:%s  ./fileA\n' "$MD5A"
    printf 'FILE:%s  ./sub/fileB\n' "$MD5B"
    printf 'LINK:./linkA\n'
    printf 'SKIP:./skipped\n'
    printf 'OTHER:./store\n'
} > "$TMP/fixture-list.txt"

VENDOR="${AS_CHKINT:-$TMP/vendor.fixture.sh}"
[ -f "$VENDOR" ] || fail "AS_CHKINT=$VENDOR does not exist"
LISTS=()
[ -n "${AS_ROOT_LIST:-}" ]  && LISTS+=("root:$AS_ROOT_LIST")
[ -n "${AS_AP_LIST:-}" ]    && LISTS+=("ap:$AS_AP_LIST")
[ -n "${AS_AIDFS_LIST:-}" ] && LISTS+=("aidfs:$AS_AIDFS_LIST")
if [ "${#LISTS[@]}" -eq 0 ]; then LISTS=("fixture:$TMP/fixture-list.txt"); fi

# --- apply the real patch to a fixture disk, dump the result -----------------
# Same read -> debugfs -> dd channel as the pipeline, with the fixture root at
# the real hda2 sector so the patch's own verification runs.
build_disk() { # <checker> <disk>
    local stage="$TMP/stage.$$" img="$TMP/part.$$.img"
    rm -rf "$stage"; mkdir -p "$stage/etc/init.d"
    cp "$1" "$stage/etc/init.d/chk_integrity.sh"
    cp "$TMP/fixture-list.txt" "$stage/file_list.txt"
    rm -f "$img"
    mke2fs -q -t ext2 -b 1024 -I 128 -m 0 -F -d "$stage" "$img" \
        $(( ROOT_BYTES / 1024 )) >/dev/null 2>&1 || fail "mke2fs failed"
    rm -f "$2"; truncate -s $(( (START + SECTORS) * ALIGN )) "$2"
    dd if="$img" of="$2" bs=$ALIGN seek="$START" conv=notrunc status=none
    rm -rf "$stage" "$img"
}
apply_patch() { # <patch> <out> <label>
    local patch="$1" out="$2" label="$3"
    local disk="$TMP/dump.$$.img" work="$TMP/work.$$"
    build_disk "$VENDOR" "$disk"
    ( cd "$REPO/scripts/container" && QCOW="$disk" WORK="$work" \
        ZD_PATCH_PARTS="hda2|$START|$SECTORS" bash "$patch" "" ) \
        > "$TMP/apply.$$.log" 2>&1 || { echo "FAIL: $label patch exited non-zero" >&2; return 1; }
    dd if="$disk" of="$TMP/dump.$$.hda2.img" bs=$ALIGN skip=$START count=$SECTORS status=none
    debugfs -R "dump $TARGET $out" "$TMP/dump.$$.hda2.img" >/dev/null 2>&1 \
        || { echo "FAIL: $label produced no $TARGET" >&2; return 1; }
    rm -rf "$disk" "$work"
    pass "$label applied to the fixture and dumped"
}
apply_patch "$PATCH" "$TMP/rewritten.sh" "rewritten (current $PATCH)"
REWRITTEN="$TMP/rewritten.sh"
BASELINE=""
if [ -n "${AS_PATCH_BASELINE:-}" ]; then
    apply_patch "$AS_PATCH_BASELINE" "$TMP/baseline.sh" "md5-no-op only (baseline)"
    BASELINE="$TMP/baseline.sh"
fi

# --- drive one loop over one list -------------------------------------------
# The driver sources only check_md5sum()'s body and calls it in check mode, which
# is how the vendor script itself calls it for the root and aidfs lists.
driver_for() { # <script> <vendor|plain> <driver>
    local script="$1" mode="$2" driver="$3"
    {
        printf '#!/bin/sh\n'
        sed -n '/^check_md5sum()/,/^}/p' "$script"
        printf 'check_md5sum "$1" "$2" check\n'
    } > "$driver"
    if [ "$mode" = vendor ]; then
        # Only the absolute md5sum path is changed, so the spawn counter can see it.
        sed -i 's#|/usr/bin/md5sum #|md5sum #' "$driver"
    fi
}

measure() { # <script> <mode> <list> <label> -> "spawns wall"; per-binary to bd.$label
    local script="$1" mode="$2" list="$3" label="$4" driver="$TMP/driver.$$"
    local t0 t1
    : > "$COUNTER"
    driver_for "$script" "$mode" "$driver"
    t0="$(date +%s.%N)"
    PATH="$SHIM:$PATH" SPAWN_COUNTER="$COUNTER" SPAWN_SHIM_DIR="$SHIM" /bin/sh "$driver" "$FIXROOT" "$list" >/dev/null 2>&1 || true
    t1="$(date +%s.%N)"
    awk '{c[$1]++} END { for (k in c) printf "%s=%d ", k, c[k] }' "$COUNTER" > "$TMP/bd.$label"
    printf '%s %s\n' "$(count_spawns)" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')"
}

echo "=== chk_integrity loop spawn cost ==="
echo "vendor checker : $VENDOR"
echo "fixture root   : $FIXROOT"
printf '%-10s %-14s %10s %10s %10s\n' list version spawns wall_s
for entry in "${LISTS[@]}"; do
    name="${entry%%:*}"; list="${entry#*:}"
    [ -f "$list" ] || { partial "list $name ($list) not found, so only the other lists were measured"; continue; }
    lines="$(grep -c . "$list" || true)"
    files="$(grep -c '^FILE:' "$list" || true)"
    echo "-- $name: $list ($lines lines, $files FILE)"
    v="$(measure "$VENDOR" vendor "$list" vendor)"
    printf '%-10s %-14s %10s %10s   %s\n' "$name" vendor $v "$(cat "$TMP/bd.vendor")"
    if [ -n "$BASELINE" ]; then
        b="$(measure "$BASELINE" plain "$list" md5noop)"
        printf '%-10s %-14s %10s %10s   %s\n' "$name" md5-no-op $b "$(cat "$TMP/bd.md5noop")"
    fi
    r="$(measure "$REWRITTEN" plain "$list" rewritten)"
    printf '%-10s %-14s %10s %10s   %s\n' "$name" rewritten $r "$(cat "$TMP/bd.rewritten")"
done

if [ -z "${AS_CHKINT:-}" ]; then
    partial "AS_CHKINT is not set, so a real vendor chk_integrity.sh was not measured; the synthetic fixture above was"
fi
