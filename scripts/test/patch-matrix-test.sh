#!/usr/bin/env bash
#
# patch-matrix-test.sh — apply the whole patch set to every ZD1200 release we
# have, offline, and report which releases the project can currently install.
#
# Why this exists: the project documents a nine-release firmware matrix
# (docs/INTERNALS.md) and the patch set is only ever verified against a member or
# two of it.  A patch that exits non-zero aborts provisioning (prepare-vm-disks.sh
# runs every patch with `bash "$patch"` under `set -euo pipefail`, and the
# entrypoint reads that as "shut the container down"), so "does this release
# still install?" is a per-release question that needs a per-release answer.
#
# For each firmware image it:
#   1. runs the project's own scripts/build/prepare-vendor-image.sh to produce
#      the per-release image/ inputs (rootfs.ext2, bzImage, vmlinux, ...);
#   2. runs scripts/container/patch-kernel.py --self-test against that release's
#      vmlinux, and the real patch (--in/--out).  A refusal here is fatal to
#      provisioning: build-synthetic-cf.py SystemExits when the patcher fails;
#   3. builds a fresh synthetic CF disk with scripts/container/build-synthetic-cf.py
#      and applies every scripts/container/patches/*.sh exactly as
#      prepare-vm-disks.sh:415-428 does, recording each exit code.  A failure does
#      not stop the sweep, so the table shows every patch's outcome.
#
# The vendor firmware images are not in this repository.  Without
# AS_FIRMWARE_DIR the test prints a visible skipped: line and exits 0.
#
# Deterministic: the per-patch exit codes and the kernel-patcher verdict.
# Host-dependent: the wall clock.  The synthetic disk is ~1.9 GiB and each
# release takes several minutes, so point AS_SCRATCH at disk-backed storage.
# A scratch directory this script creates itself is removed on exit, logs and
# all -- on every path, including the skips below -- so AS_SCRATCH is also how
# a run keeps its logs (and any file named below is only still there because
# the caller set it).
#
# Usage:
#   AS_FIRMWARE_DIR=~/images ./scripts/test/patch-matrix-test.sh
#   AS_FIRMWARE_DIR=~/images AS_RELEASES="10.5.1.0.282 9.9.1.0.52" \
#       ./scripts/test/patch-matrix-test.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FW_DIR="${AS_FIRMWARE_DIR:-}"
SELECT="${AS_RELEASES:-}"
# A scratch directory this script creates itself belongs to this run and is
# removed on exit, on every path.  A caller-supplied AS_SCRATCH is the
# operator's directory -- it may hold an earlier run's logs -- and is never
# removed; AS_SCRATCH="" counts as unset, so it gets an owned scratch instead.
SCRATCH_OWNED=0
SCRATCH="${AS_SCRATCH:-}"
if [ -z "$SCRATCH" ]; then
    SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/zd-patchmatrix.XXXXXX")"
    SCRATCH_OWNED=1
fi
SKIP_KERNEL="${AS_SKIP_KERNEL_GATE:-0}"
# Every line that names a file inside $SCRATCH carries this, because that file
# is gone once this script exits unless the caller supplied the directory.
if [ "$SCRATCH_OWNED" = 1 ]; then
    KEEP_HINT="; scratch removed on exit unless AS_SCRATCH is set"
else
    KEEP_HINT=""
fi

# cleanup() runs from the EXIT trap, so it covers every exit path: the early
# skips, the `exit 1` on a bad AS_FIRMWARE_DIR, a failure under `set -e`, and
# the normal end of the sweep.  `trap ... EXIT` alone also fires when bash is
# killed by SIGINT or SIGTERM and the status the caller sees stays 130/143
# (measured), so no signal trap is installed: one would have to re-raise the
# signal itself to avoid turning a signal death into an exit 0.  The guard
# keeps cleanup safe under `set -e` and when SCRATCH is empty or unset, and
# `return 0` keeps a cleanup failure from becoming the script's exit status.
cleanup() {
    if [ "$SCRATCH_OWNED" = 1 ] && [ -n "${SCRATCH:-}" ]; then
        rm -rf -- "$SCRATCH" || true
    fi
    return 0
}
trap cleanup EXIT

skip() { printf 'skipped: %s\n' "$*"; }
if [ -z "$FW_DIR" ]; then
    skip "AS_FIRMWARE_DIR is not set; point it at a directory of zd1200_*.img"
    exit 0
fi
[ -d "$FW_DIR" ] || { echo "FAIL: AS_FIRMWARE_DIR=$FW_DIR is not a directory" >&2; exit 1; }
for tool in python3 debugfs mke2fs resize2fs tar gzip md5sum sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || { skip "$tool not found"; exit 0; }
done

shopt -s nullglob
IMAGES=("$FW_DIR"/zd1200_*.img)
shopt -u nullglob
[ "${#IMAGES[@]}" -gt 0 ] || { skip "no zd1200_*.img in $FW_DIR"; exit 0; }

release_of() { basename "$1" | sed 's/^zd1200_//; s/\.ap_.*$//'; }

selected() { # <release>
    [ -z "$SELECT" ] && return 0
    local r
    for r in $SELECT; do [ "$r" = "$1" ] && return 0; done
    return 1
}

stage_layout() { # <rt>: the Docker/LXC layout (scripts at top level, image/ beside)
    local rt="$1"
    mkdir -p "$rt"
    cp -a "$REPO/scripts/container/patch-lib.sh" "$REPO/scripts/container/patch-kernel.py" \
          "$REPO/scripts/container/binpatch.py" "$REPO/scripts/container/patch-file.py" \
          "$REPO/scripts/container/build-synthetic-cf.py" "$REPO/scripts/container/build-bootfs.py" \
          "$REPO/scripts/container/write-boarddata.py" \
          "$REPO/scripts/container/license-fix.awk" "$REPO/scripts/container/backup-restore.sh" \
          "$rt/"
    rm -rf "$rt/patches"; cp -a "$REPO/scripts/container/patches" "$rt/patches"
    [ -e "$rt/packages" ] || ln -s "$REPO/packages" "$rt/packages"
}

mkdir -p "$SCRATCH/tmp"
export TMPDIR="$SCRATCH/tmp"
: > "$SCRATCH/summary.tsv"

for img in "${IMAGES[@]}"; do
    rel="$(release_of "$img")"
    selected "$rel" || continue
    echo "================================================================"
    echo "== $rel ($img)"
    RT="$SCRATCH/$rel/rt"; mkdir -p "$RT"
    stage_layout "$RT"

    if ! IMAGE_DIR="$RT/image" bash "$REPO/scripts/build/prepare-vendor-image.sh" "$img" \
            > "$SCRATCH/$rel.prepare.log" 2>&1; then
        echo "   prepare-vendor-image: FAILED (see $SCRATCH/$rel.prepare.log$KEEP_HINT)"
        printf '%s\tprepare=FAILED\tkernel=NA\tpatches=NA\n' "$rel" >> "$SCRATCH/summary.tsv"
        continue
    fi
    echo "   prepare-vendor-image: ok"

    kst=0
    python3 "$RT/patch-kernel.py" --self-test --vmlinux "$RT/image/vmlinux" \
        > "$SCRATCH/$rel.selftest.log" 2>&1 || kst=$?
    kpk=0
    python3 "$RT/patch-kernel.py" --in "$RT/image/bzImage" --out "$SCRATCH/$rel.bzImage.patched" \
        > "$SCRATCH/$rel.patchkernel.log" 2>&1 || kpk=$?
    if [ "$kst" = 0 ] && [ "$kpk" = 0 ]; then
        echo "   patch-kernel: self-test ok, patch ok"
        kverdict=ok
    else
        kverdict="REFUSED"
        echo "   patch-kernel: self-test=$kst patch=$kpk -> REFUSED"
        grep -E 'FAIL|missing patches|NOT FOUND' "$SCRATCH/$rel.selftest.log" "$SCRATCH/$rel.patchkernel.log" \
            | sed 's/^/      /' || true
    fi

    if [ "$kverdict" != ok ] && [ "$SKIP_KERNEL" != 1 ]; then
        echo "   patch set: not run (the kernel patcher refuses this release and"
        echo "              build-synthetic-cf.py exits non-zero, so provisioning"
        echo "              cannot reach the patches at all)"
        printf '%s\tprepare=ok\tkernel=REFUSED\tpatches=not-run\n' "$rel" >> "$SCRATCH/summary.tsv"
        continue
    fi

    if ! SYNTHETIC_DISK="$SCRATCH/$rel/synthetic-cf.img" ZD_R600_REPAIR=0 \
            python3 "$RT/build-synthetic-cf.py" > "$SCRATCH/$rel.build.log" 2>&1; then
        echo "   build-synthetic-cf: FAILED (see $SCRATCH/$rel.build.log$KEEP_HINT)"
        printf '%s\tprepare=ok\tkernel=%s\tpatches=BUILD-FAILED\n' "$rel" "$kverdict" >> "$SCRATCH/summary.tsv"
        continue
    fi
    python3 "$RT/write-boarddata.py" --disk "$SCRATCH/$rel/synthetic-cf.img" \
        --serial 123456000789 --mac 00:0c:e6:12:00:01 --model ZD1200 --customer ruckus \
        >> "$SCRATCH/$rel.build.log" 2>&1

    worst=0
    for patch in "$RT"/patches/*.sh; do
        name="$(basename "$patch")"
        rc=0
        QCOW="$SCRATCH/$rel/synthetic-cf.img" WORK="$SCRATCH/$rel/work" \
            ANALYTICS_DIR="$REPO/packages/analytics" DROPBEAR_DIR="$REPO/packages/dropbear" \
            ZD_PATCH_PARTS=$'hda2|84568|415152\nhda3|499720|415152' \
            ZD_ROOT_SSH_AUTHORIZED_KEYS="${ZD_ROOT_SSH_AUTHORIZED_KEYS:-/nonexistent/authorized_keys}" \
            ZD_ECDSA_SSH=1 ZD_NETWORK_MONITOR=1 \
            bash "$patch" "$RT/image/signing-cert" > "$SCRATCH/$rel.$name.log" 2>&1 || rc=$?
        verdict=applied
        [ "$rc" != 0 ] && { verdict=ABORTED; worst=1; }
        printf '   %-26s %-8s exit=%s\n' "$name" "$verdict" "$rc"
    done
    if [ "$worst" = 0 ]; then
        printf '%s\tprepare=ok\tkernel=%s\tpatches=ok\n' "$rel" "$kverdict" >> "$SCRATCH/summary.tsv"
    else
        printf '%s\tprepare=ok\tkernel=%s\tpatches=ABORT\n' "$rel" "$kverdict" >> "$SCRATCH/summary.tsv"
    fi
    rm -f "$SCRATCH/$rel/synthetic-cf.img"
done

echo "================================================================"
echo "== coverage: $(grep -c . "$SCRATCH/summary.tsv" || true) release(s) prepared"
[ -n "$SELECT" ] && echo "== AS_RELEASES selected: $SELECT"
column -t -s $'\t' "$SCRATCH/summary.tsv" 2>/dev/null || cat "$SCRATCH/summary.tsv"
if [ "$SCRATCH_OWNED" = 1 ]; then
    echo "== scratch: $SCRATCH (removed on exit; set AS_SCRATCH to keep this run's logs)"
else
    echo "== scratch: $SCRATCH (caller-supplied AS_SCRATCH; kept)"
fi
