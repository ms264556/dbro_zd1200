# lib.sh — ext2 fixture helpers shared by the tests that build a small root
# filesystem with mke2fs and inspect it with debugfs.  Source it, don't run it:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Only the steps the tests genuinely repeat live here.  Each test still owns
# its own stage tree, geometry and tool-presence policy (SKIP vs fail), because
# those differ; the functions take every value as an argument and read no
# globals, so sourcing this file changes nothing by itself.

# fs_dump <image> <fspath> <out>: copy one file out of an ext2 image.  Nonzero
# when debugfs fails; callers still check the output file, since debugfs exits
# 0 for a path that is absent.
fs_dump() {
    debugfs -R "dump $2 $3" "$1" >/dev/null 2>&1
}

# part_image <disk> <out> <start> <sectors> <align>: cut a partition of a flat
# disk out as its own image, so debugfs can open it.
part_image() {
    rm -f "$2"
    dd if="$1" of="$2" bs="$5" skip="$3" count="$4" status=none
}

# ext2_disk_from_stage <stage> <disk> <start> <sectors> <align>: build an ext2
# root from a staged tree and write it into a fresh flat disk at <start>.  The
# 1 KiB block / 128-byte inode / no-reserve layout matches what the patches
# find on the real hda2, so their own verification runs against the fixture.
ext2_disk_from_stage() {
    local stage="$1" disk="$2" start="$3" sectors="$4" align="$5"
    local part="$disk.part.$$"
    rm -f "$part"
    mke2fs -q -t ext2 -b 1024 -I 128 -m 0 -F -d "$stage" "$part" \
        $(( sectors * align / 1024 )) >/dev/null 2>&1 || { rm -f "$part"; return 1; }
    rm -f "$disk"; truncate -s $(( (start + sectors) * align )) "$disk"
    dd if="$part" of="$disk" bs="$align" seek="$start" conv=notrunc status=none
    rm -f "$part"
}

# short_sock_dir: print a fresh private directory whose path is short enough
# to hold an AF_UNIX socket.  sun_path is ~108 bytes, so a socket under a deep
# or long $TMPDIR fails to bind/connect ("AF_UNIX path too long").  $TMPDIR is
# still honoured when it is short; otherwise the directory goes under /tmp.
# The caller removes it.
short_sock_dir() {
    local base="${TMPDIR:-/tmp}"
    [ "${#base}" -le 40 ] || base=/tmp
    mktemp -d "$base/zd-sock.XXXXXX"
}
