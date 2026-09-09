#!/usr/bin/env bash
#
# Build GRUB 0.97 (i386-pc stage1/stage2/stage1_5) for the ZD1200 boot area and
# stage it in out/lib/grub/i386-pc/ for scripts/build-bootfs.py.
#
# Usage: ./build.sh [--clean] [--force] [--jobs N]
#   --clean   drop build/ and out/
#   --force   rebuild even when the signature says the artifacts are current
#   --jobs N  run make with N jobs
#
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DL_DIR="$BASE/dl"
BUILD_DIR="$BASE/build"
OUT_DIR="$BASE/out"
SRC_DIR="$BUILD_DIR/grub-0.97"
OUT_GRUB="$OUT_DIR/lib/grub/i386-pc"
CONFIG_SRC="$BASE/config"

SRC_URL="https://alpha.gnu.org/gnu/grub/grub-0.97.tar.gz"
SRC_SHA256="4e1d15d12dbd3e9208111d6b806ad5a9857ca8850c47877d36575b904559260b"

# Ruckus patch level: BR2_PACKAGE_GRUB_BUILD="1.39".
GRUB_VERSION="0.97"
GRUB_BUILD="1.39"

# Ruckus GRUB_FLAG from buildroot/package/grub/grub.mk: ext2fs only.
CONFIGURE_FLAGS=(
  --prefix=/usr
  --libdir=/usr/lib
  --bindir=/usr/bin
  --sbindir=/usr/bin
  --mandir=/usr/share/man
  --infodir=/usr/share/info
  --disable-auto-linux-mem-opt
  --disable-ffs
  --disable-ufs2
  --disable-minix
  --disable-vstafs
  --disable-jfs
  --disable-xfs
  --disable-iso9660
  --disable-hercules
  --without-curses
  --disable-fat
  --disable-reiserfs
)

JOBS=1
FORCE=0
die() { printf 'grub097: error: %s\n' "$*" >&2; exit 1; }
log() { printf 'grub097: %s\n' "$*"; }

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --clean)
      rm -rf "$BUILD_DIR" "$OUT_DIR"
      log "removed build/ and out/"
      exit 0
      ;;
    --force) FORCE=1 ;;
    --jobs) JOBS="${2:?--jobs needs an argument}"; shift ;;
    -h|--help) usage 0 ;;
    *) usage 2 ;;
  esac
  shift
done

# --- up-to-date check --------------------------------------------------------
# Signature covers this script, the tarball, every patch and the /boot config.
signature() {
  {
    sha256sum "$BASE/build.sh"
    sha256sum "$CONFIG_SRC"/*
    printf 'tarball %s\n' "$SRC_SHA256"
    for series in aur local ruckus; do
      printf 'series %s\n' "$series"
      sha256sum "$BASE/patches/$series/series"
      while read -r p; do
        case "$p" in ''|'#'*) continue ;; esac
        sha256sum "$BASE/patches/$series/$p"
      done < "$BASE/patches/$series/series"
    done
  } | sha256sum | cut -d' ' -f1
}

want_sig="$(signature)"
if [ "$FORCE" = 0 ] && [ -f "$OUT_DIR/.build-stamp" ] \
   && [ "$(cat "$OUT_DIR/.build-stamp")" = "$want_sig" ] \
   && [ -s "$OUT_GRUB/stage1" ] && [ -s "$OUT_GRUB/stage2" ] \
   && [ -s "$OUT_GRUB/e2fs_stage1_5" ]; then
  log "artifacts up to date ($want_sig) — nothing to do"
  exit 0
fi

# ---------------------------------------------------------------- prerequisites
mkdir -p "$DL_DIR" "$BUILD_DIR"
need_tool() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found${2:+ — $2}"
}
need_tool gcc
need_tool make
need_tool patch
need_tool objcopy
need_tool tar
need_tool sha256sum
need_tool python3 "needed for the post-build self-check"
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  die "neither curl nor wget is available to download $SRC_URL"
fi

# configure adds -m32 on x86_64, so 32-bit headers/libs are required.
if [ "$(uname -m)" = x86_64 ]; then
  printf 'int main(void){return 0;}\n' > "$BUILD_DIR/.m32.c"
  if ! gcc -m32 "$BUILD_DIR/.m32.c" -o "$BUILD_DIR/.m32" >/dev/null 2>&1; then
    rm -f "$BUILD_DIR/.m32.c" "$BUILD_DIR/.m32"
    die "gcc cannot build 32-bit code — install gcc-multilib and libc6-dev-i386"
  fi
  rm -f "$BUILD_DIR/.m32.c" "$BUILD_DIR/.m32"
fi

# ------------------------------------------------------------------ source tree
TARBALL="$DL_DIR/grub-0.97.tar.gz"

if [ ! -f "$TARBALL" ]; then
  log "downloading $SRC_URL"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$TARBALL.part" "$SRC_URL"
  else
    wget -q -O "$TARBALL.part" "$SRC_URL"
  fi
  mv "$TARBALL.part" "$TARBALL"
fi

actual="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
[ "$actual" = "$SRC_SHA256" ] \
  || die "$TARBALL: sha256 $actual, expected $SRC_SHA256 (delete it and retry)"
log "tarball sha256 ok ($SRC_SHA256)"

log "extracting to build/grub-0.97"
rm -rf "$SRC_DIR"
tar xzf "$TARBALL" -C "$BUILD_DIR"
[ -d "$SRC_DIR" ] || die "extraction did not produce $SRC_DIR"

# ---------------------------------------------------------------------- patching
apply_series() {
  local dir="$1" label="$2" p
  [ -f "$dir/series" ] || die "missing series file: $dir/series"
  while read -r p; do
    case "$p" in ''|'#'*) continue ;; esac
    [ -f "$dir/$p" ] || die "series references missing patch: $dir/$p"
    log "  $label: $p"
    patch -Np1 --no-backup-if-mismatch -d "$SRC_DIR" -i "$dir/$p" >"$BUILD_DIR/patch.log" 2>&1 \
      || { cat "$BUILD_DIR/patch.log" >&2; die "$label patch failed: $p"; }
  done < "$dir/series"
}

log "applying patches"
apply_series "$BASE/patches/aur" aur
apply_series "$BASE/patches/local" local
apply_series "$BASE/patches/ruckus" ruckus

if find "$SRC_DIR" -name '*.rej' -o -name '*.orig' | grep -q .; then
  find "$SRC_DIR" -name '*.rej' -o -name '*.orig' >&2
  die "patches left rejects/backups behind"
fi

# ------------------------------------------------------------------- configure
grep -q "PACKAGE_VERSION='$GRUB_VERSION.$GRUB_BUILD'" "$SRC_DIR/configure" \
  || die "configure is not $GRUB_VERSION.$GRUB_BUILD (is patches/local/0002 applied?)"

log "configure (${CONFIGURE_FLAGS[*]})"
# -no-pie: stage1/2 link at fixed addresses. --build-id=none: a build id makes
# objcopy emit huge binaries.
(cd "$SRC_DIR" && CFLAGS= LDFLAGS="-no-pie -Wl,--build-id=none" \
   ./configure "${CONFIGURE_FLAGS[@]}" >"$BUILD_DIR/configure.log" 2>&1) \
  || { tail -30 "$BUILD_DIR/configure.log" >&2; die "configure failed"; }

# ------------------------------------------------------------------------ make
run_make() {
  local sub="$1"; shift
  log "make -C $sub${*:+ $*}"
  (cd "$SRC_DIR" && make -C "$sub" -j"$JOBS" "$@" >"$BUILD_DIR/make-$sub.log" 2>&1) \
    || { tail -40 "$BUILD_DIR/make-$sub.log" >&2; die "make in $sub failed"; }
}
# Only what the boot area needs; stage2 links ../netboot/libdrivers.a.
run_make netboot
run_make stage2 stage2 e2fs_stage1_5
run_make stage1 stage1

# --------------------------------------------------------------------- staging
rm -rf "$OUT_DIR"
mkdir -p "$OUT_GRUB"

for f in stage1/stage1 \
         stage2/stage2 \
         stage2/e2fs_stage1_5; do
  [ -f "$SRC_DIR/$f" ] || die "build did not produce $f"
  install -m 644 "$SRC_DIR/$f" "$OUT_GRUB/$(basename "$f")"
done

for f in menu.lst default; do
  if [ -f "$CONFIG_SRC/$f" ]; then
    install -m 644 "$CONFIG_SRC/$f" "$OUT_GRUB/$f"
    log "  copied config $f from config/"
  fi
done

# ------------------------------------------------------------------- self-check
log "verifying the build options took effect"
fsys="$(grep -m1 '^FSYS_CFLAGS = ' "$SRC_DIR/stage2/Makefile")"
case "$fsys" in
  *-DFSYS_EXT2FS=1*) ;;
  *) die "stage2 was built without ext2fs support: $fsys" ;;
esac
case "$fsys" in
  *-DFSYS_REISERFS=1*) die "stage2 still has reiserfs support: $fsys" ;;
esac
log "  stage2 filesystems: $fsys"

log "verifying the Ruckus patches are compiled in"
python3 - "$OUT_GRUB" <<'PY'
import struct, sys
from pathlib import Path

out = Path(sys.argv[1])
ZD_PART_SECTOR = 3982101                      # grub-partition.patch
needle = struct.pack("<I", ZD_PART_SECTOR)
stage2 = (out / "stage2").read_bytes()
st15 = (out / "e2fs_stage1_5").read_bytes()
for name, data in (("stage2", stage2), ("e2fs_stage1_5", st15)):
    if data.count(needle) != 1:
        sys.exit(f"{name}: expected one ZD_PART_SECTOR={ZD_PART_SECTOR}, "
                 f"found {data.count(needle)}")
if b"PREVIOUS BOOTUP STATUS" not in stage2:   # grub-recovery.patch
    sys.exit("stage2: recovery status banner missing — grub-recovery.patch not built in")
if b"0.97.1.39" not in stage2 or b"0.97.1.39" not in st15:
    sys.exit("stage2/stage1_5: expected version string 0.97.1.39")
print("  ZD_PART_SECTOR=3982101 in stage2 + e2fs_stage1_5")
print("  recovery banner + version 0.97.1.39 in stage2")
PY

log "built artifacts in out/lib/grub/i386-pc/:"
( cd "$OUT_GRUB" && sha256sum * | sed 's/^/  /' )
( cd "$OUT_GRUB" && stat -c '  %10s bytes  %n' * )

printf '%s\n' "$want_sig" > "$OUT_DIR/.build-stamp"
log "done (signature $want_sig)"
