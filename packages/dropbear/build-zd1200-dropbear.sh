#!/bin/sh
#
# build-zd1200-dropbear.sh
#
# Reproducible STATIC build of the ZD1200 dropbear package:
#   dropbear 2026.94 (sshd) + dropbearkey + dropbearconvert
#   sftp-server (OpenSSH 9.9p2)
#
# Everything is statically linked against musl libc and built as classic
# non-PIE (ET_EXEC) i386 ELF, so the binaries run on the ZD1200's kernel
# (2.6.32.24) with no dependency on the controller rootfs libs.
#
# This is fully static and self-contained (CI-friendly):
#
#   - no dependency on the controller's rootfs libraries
#   - one cross toolchain tarball (musl.cc GitHub release mirror) + dropbear
#     + OpenSSH + zlib
#   - "none" compression only: build with --disable-zlib / no zlib use
#
# Usage:
#   ./build-zd1200-dropbear.sh [options]
#
# Options:
#   --work DIR       work directory (default: ./zd1200-work)
#   --out DIR        copy final stripped binaries here (default: ./out)
#   --keep           reuse an existing work dir / downloads
#   -h, --help       this message
#
# Requirements on the build host (gitlab / github ubuntu runner):
#   curl, tar, make, gcc (host), file, readelf, strip.  No root needed.
#   The musl cross toolchain is downloaded by the script; if you already
#   have a musl cross gcc on PATH, set MUSLCC to its basename to skip the
#   download.
#
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORK=${WORK:-"$PWD/zd1200-work"}
OUT=${OUT:-"$PWD/out"}
KEEP=0
MUSLCC=${MUSLCC:-}

while [ $# -gt 0 ]; do
    case "$1" in
        --work) WORK="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        -h|--help) sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

# Resolve WORK / OUT to absolute paths: the cross toolchain is put on PATH and
# configure steps cd into source dirs, so a relative PATH entry would break
# ("i486-linux-musl-gcc: not found") once the shell chdir's away from cwd.
case "$WORK" in /*) ;; *) WORK="$PWD/$WORK" ;; esac
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac

# --- versions --------------------------------------------------------------
DROPBEAR_VER=2026.94
OPENSSH_VER=9.9p2
ZLIB_VER=1.2.8
MUSL_TOOLCHAIN_TGZ=i486-linux-musl-cross.tgz
# musl.cc itself flakes from GitHub Actions; use its GitHub release mirror
# (musl-cc/musl.cc).  Override with MUSL_TOOLCHAIN_URL if you want another
# source for the same-named tarball.
MUSL_TOOLCHAIN_URL=${MUSL_TOOLCHAIN_URL:-https://github.com/musl-cc/musl.cc/releases/download/v0.0.1/${MUSL_TOOLCHAIN_TGZ}}

DL="$WORK/dl"
BLD="$WORK/build"
MUSL_TREE="$WORK/$MUSL_TOOLCHAIN_TGZ"
MUSL_BIN="$WORK/i486-linux-musl-cross/bin"
OUT="$OUT"

say()  { printf '\n== %s ==\n' "$*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

mkdir -p "$WORK" "$DL" "$BLD" "$OUT"
[ "$KEEP" = 1 ] || rm -rf "$BLD"/*

have curl || die "curl not found"
have make  || die "make not found"
have gcc   || die "host gcc not found"
have file  || die "file not found"
have readelf || die "readelf not found"

# ---------------------------------------------------------------------------
say "1/6  Cross compiler: i486-linux-musl-cross (musl.cc GitHub release)"
# ---------------------------------------------------------------------------
if [ -n "$MUSLCC" ]; then
    have "$MUSLCC" || die "MUSLCC given but not on PATH: $MUSLCC"
    CC="$MUSLCC"
else
    # Download+extract the toolchain if not already present in the work dir.
    if [ ! -x "$MUSL_BIN/i486-linux-musl-gcc" ]; then
        if [ ! -f "$MUSL_TREE" ]; then
            echo "  downloading $MUSL_TOOLCHAIN_URL"
            curl -fL --retry 3 --retry-delay 2 -o "$MUSL_TREE.tmp" "$MUSL_TOOLCHAIN_URL" \
                || die "toolchain download failed: $MUSL_TOOLCHAIN_URL"
            mv "$MUSL_TREE.tmp" "$MUSL_TREE"
        fi
        tar xzf "$MUSL_TREE" -C "$WORK"
    fi
    CC="i486-linux-musl-gcc"
    PATH="$MUSL_BIN:$PATH"
    export PATH
fi

export CC
# Classic non-PIE static ET_EXEC: matches what was validated on 2.6.32.24.
# (Do NOT use musl's default -static which produces static-PIE / ET_DYN.)
export CFLAGS="-Os -Wall"
export LDFLAGS="-static -no-pie"

# ---------------------------------------------------------------------------
say "2/6  zlib ${ZLIB_VER} (static, only to satisfy OpenSSH's configure gate)"
# ---------------------------------------------------------------------------
# sftp-server references NO zlib symbols, but OpenSSH 7.4/9.x configure hard
# requires zlib.h + libz to be present.  Build a static musl zlib into the
# prefix; it will only be linked if sftp-server actually references it
# (it does not).  A static linker pulls in no zlib code unless referenced.
ZPREFIX="$WORK/zlib-prefix"
ZLIB_SRC="$BLD/zlib-$ZLIB_VER"
ZLIBCFG="$WORK/zlib-cfg"
if [ ! -f "$ZPREFIX/lib/libz.a" ]; then
    rm -rf "$ZLIB_SRC" "$ZPREFIX"   # no stale source or prefix
    [ -f "$DL/zlib-$ZLIB_VER.tar.gz" ] || \
    curl -fL --retry 3 --retry-delay 2 -o "$DL/zlib-$ZLIB_VER.tar.gz" \
        https://zlib.net/fossils/zlib-$ZLIB_VER.tar.gz || die "zlib download failed"
    tar xzf "$DL/zlib-$ZLIB_VER.tar.gz" -C "$BLD"
    # zlib's configure needs a working cross compiler in $CC and on PATH; run
    # it with the toolchain directory on PATH and a clean CFLAGS (no -Wall).
    # zlib's configure compiles test programs with $CFLAGS and treats ANY
    # warning as fatal ("obsessive-compulsive" / -Werror guard), so the
    # globally-exported "-Os -Wall" must NOT leak in here.
    ( cd "$ZLIB_SRC" && \
      PATH="$MUSL_BIN:$PATH" CC="$CC" CFLAGS="-Os" ./configure --static --prefix="$ZPREFIX" && \
      make && make install ) > "$ZLIBCFG" 2>&1 \
        || { echo "--- zlib configure/build log ---" >> "$ZLIBCFG"; die "zlib build failed (see $ZLIBCFG)"; }
fi
echo "  zlib static lib at $ZPREFIX/lib/libz.a"

# ---------------------------------------------------------------------------
say "3/6  dropbear ${DROPBEAR_VER} (static, none compression, non-PIE)"
# ---------------------------------------------------------------------------
DB_SRC="$BLD/dropbear-$DROPBEAR_VER"
DB_LOG="$WORK/dropbear-build.log"
if [ ! -d "$DB_SRC" ]; then
    [ -f "$DL/dropbear-$DROPBEAR_VER.tar.bz2" ] || \
    curl -fL --retry 3 --retry-delay 2 -o "$DL/dropbear-$DROPBEAR_VER.tar.bz2" \
        https://matt.ucc.asn.au/dropbear/releases/dropbear-$DROPBEAR_VER.tar.bz2 \
        || die "dropbear download failed"
    tar xjf "$DL/dropbear-$DROPBEAR_VER.tar.bz2" -C "$BLD"
fi
# Apply the ZD1200 dropbear patches:
#   0001 - point SFTPSERVER_PATH at the controller's persistent data partition
#   0002 - Ruckus custom -e <shell> and -A <authmeth> server options
#   0003 - -A none accepts the SSH 'none' auth method immediately (no SSH auth;
#          the -e login shell then prompts for credentials), matching the stock
#          Ruckus port-22 behavior.
#   0004 - -A none accepts *any* username: if it isn't a real system user,
#          synthesize a root login so the session can start /bin/login.sh
#          (the ruckus CLI), whose own /bin/login does the credential check.
#   0005 - login accounting uses the session user (pw_name) and is non-fatal
#          if a username isn't a real user, so -A none sessions aren't killed
#          by login_init_entry ("Cannot find user").
if [ ! -f "$DB_SRC/.zd-patched" ]; then
    patch -p1 -f -d "$DB_SRC" < "$SCRIPT_DIR"/patches/dropbear/0001-sftpserver-path.patch >/dev/null \
        || die "dropbear patch 0001 failed"
    patch -p1 -f -d "$DB_SRC" < "$SCRIPT_DIR"/patches/dropbear/0002-ruckus-e-and-a-options.patch >/dev/null \
        || die "dropbear patch 0002 failed"
    patch -p1 -f -d "$DB_SRC" < "$SCRIPT_DIR"/patches/dropbear/0003-none-auth-bypass.patch >/dev/null \
        || die "dropbear patch 0003 failed"
    patch -p1 -f -d "$DB_SRC" < "$SCRIPT_DIR"/patches/dropbear/0004-any-user-authnone.patch >/dev/null \
        || die "dropbear patch 0004 failed"
    patch -p1 -f -d "$DB_SRC" < "$SCRIPT_DIR"/patches/dropbear/0005-login-entry-authnone.patch >/dev/null \
        || die "dropbear patch 0005 failed"
    touch "$DB_SRC/.zd-patched"
fi
if [ ! -x "$DB_SRC/dropbear" ]; then
    ( cd "$DB_SRC" && ./configure --host=i486-linux-musl \
        --disable-zlib --disable-pam --disable-lastlog \
        --disable-utmp --disable-wtmp --disable-harden \
        > "$WORK/dropbear-configure.log" 2>&1 ) || die "dropbear configure failed"
    ( cd "$DB_SRC" && make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" \
        > "$DB_LOG" 2>&1 ) || die "dropbear build failed (see $DB_LOG)"
fi
echo "  dropbear built"

# ---------------------------------------------------------------------------
say "4/6  OpenSSH ${OPENSSH_VER} sftp-server (static, without-openssl)"
# ---------------------------------------------------------------------------
OSSH_SRC="$BLD/openssh-$OPENSSH_VER"
OSSH_LOG="$WORK/openssh-build.log"
if [ ! -d "$OSSH_SRC" ]; then
    [ -f "$DL/openssh-$OPENSSH_VER.tar.gz" ] || \
    curl -fL --retry 3 --retry-delay 2 -o "$DL/openssh-$OPENSSH_VER.tar.gz" \
        https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-$OPENSSH_VER.tar.gz \
        || die "openssh download failed"
    tar xzf "$DL/openssh-$OPENSSH_VER.tar.gz" -C "$BLD"
fi
if [ ! -x "$OSSH_SRC/sftp-server" ]; then
    # Use --without-openssl (internal limited crypto) and --with-zlib to
    # satisfy configure.  Force non-PIE (remove -fPIE/-pie) for 2.6.32 compat.
    ( cd "$OSSH_SRC" && ./configure --host=i486-linux-musl --prefix=/usr \
        --without-openssl --with-zlib="$ZPREFIX" \
        --without-pam --without-stackprotect \
        > "$WORK/openssh-configure.log" 2>&1 ) || die "openssh configure failed"
    ( cd "$OSSH_SRC" && make CC=i486-linux-musl-gcc \
        CFLAGS="-Os -Wall -fno-strict-aliasing -fno-builtin-memset" \
        LDFLAGS="-L. -Lopenbsd-compat/ -L$ZPREFIX/lib -static -no-pie" \
        sftp-server > "$OSSH_LOG" 2>&1 ) || die "sftp-server build failed (see $OSSH_LOG)"
fi
echo "  sftp-server built"

# ---------------------------------------------------------------------------
say "5/6  Strip + copy to $OUT"
# ---------------------------------------------------------------------------
if [ -z "$MUSLCC" ]; then
    STRIP="$MUSL_BIN/i486-linux-musl-strip"
else
    STRIP=$(dirname "$(command -v "$CC")")/$(basename "$CC" gcc)strip
    [ -x "$STRIP" ] || STRIP=$(dirname "$(command -v "$CC")")/strip
fi
have "$STRIP" 2>/dev/null || die "strip not found: $STRIP"

"$STRIP" "$DB_SRC/dropbear" "$DB_SRC/dropbearkey" "$DB_SRC/dropbearconvert" "$OSSH_SRC/sftp-server"
cp -f "$DB_SRC/dropbear" "$DB_SRC/dropbearkey" "$DB_SRC/dropbearconvert" "$OSSH_SRC/sftp-server" "$OUT/"
chmod 755 "$OUT/dropbear" "$OUT/dropbearkey" "$OUT/dropbearconvert" "$OUT/sftp-server"

# ---------------------------------------------------------------------------
say "6/6  Verify"
# ---------------------------------------------------------------------------
ok=1
for b in dropbear dropbearkey dropbearconvert sftp-server; do
    f="$OUT/$b"
    # Verify 32-bit i386 (ELF32 / EM_386) straight from the ELF header.  Do NOT
    # rely on `file`'s arch name: it varies by file(1) version ("Intel i386" on
    # newer file, "Intel 80386" on older) and was making this check flaky.
    readelf -h "$f" | grep -q 'Class:.*ELF32' \
        || { echo "FAIL: $b wrong arch/format"; ok=0; }
    readelf -h "$f" | grep -q 'Machine:.*Intel 80386' \
        || { echo "FAIL: $b wrong arch/format"; ok=0; }
    # classic non-PIE ET_EXEC required for 2.6.32 compat (static-PIE is not)
    readelf -h "$f" | grep -q 'EXEC (Executable file)' \
        || { echo "FAIL: $b is not classic non-PIE EXEC (static-PIE won't run on 2.6.32)"; ok=0; }
    # statically linked (no NEEDED libs, no interpreter)
    if readelf -d "$f" 2>/dev/null | grep -qE 'NEEDED|INTERP'; then
        echo "FAIL: $b is dynamically linked or has an interpreter"; ok=0
    fi
done
[ "$ok" = 1 ] || die "verification failed"

echo
echo "Static binaries:"
sha256sum "$OUT/dropbear" "$OUT/dropbearkey" "$OUT/dropbearconvert" "$OUT/sftp-server"
echo
echo "Done.  These are fully static musl i386 binaries (non-PIE) and will run"
echo "on the ZD1200's 2.6.32 kernel.  'dropbear' and 'sftp-server' are the"
echo "runtime executables; 'dropbearkey'/'dropbearconvert' are key helpers."
exit 0
