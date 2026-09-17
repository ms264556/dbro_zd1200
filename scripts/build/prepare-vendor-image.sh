#!/usr/bin/env bash
# Build the locally ignored runtime image/ directory from either:
#   * a ZD1200 firmware upgrade file downloaded from Ruckus/CommScope (any
#     version/build of the ZD1200 platform) -- TAC-encrypted, decrypted here; or
#   * a CompactFlash card dump: a raw dd .img, or a Windows ImageUSB .bin (its
#     512-byte header is detected and skipped).  The dump's boot files, rootfs,
#     board serial and reiserfs /writable are taken from the image as-is.
# No vendor material is redistributed.
#
# This runs inside the image built from docker/Dockerfile (which carries
# e2fsprogs/debugfs, python3, tar and gzip), so the host needs no filesystem
# tooling.  install-zd1200-docker.sh invokes it there.
set -euo pipefail

work_dir="$(cd "$(dirname "$0")/../.." && pwd)"   # repo root
# Where the prepared artifacts land.  Defaults to the repo's image/ (the Docker
# flow mounts it read-only into the container); the LXC flow sets IMAGE_DIR to a
# state directory.  Both the early setup and the extraction below must agree.
IMAGE_DIR="${IMAGE_DIR:-$work_dir/image}"
archive_path=""
writable_from=""
writable_partition=""
# Optional payload-integrity gate: set EXPECTED_ARCHIVE_SHA256 to enforce a
# specific (decrypted payload) hash; leave empty to accept any compatible build.
expected_sha256="${EXPECTED_ARCHIVE_SHA256:-}"

fail() {
    echo "prepare-vendor-image: $*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --writable-from)
            [ $# -ge 2 ] || fail "--writable-from needs a dump path"
            writable_from="$2"; shift 2 ;;
        --writable-from=*) writable_from="${1#*=}"; shift ;;
        --writable-partition)
            [ $# -ge 2 ] || fail "--writable-partition needs START:COUNT"
            writable_partition="$2"; shift 2 ;;
        --writable-partition=*) writable_partition="${1#*=}"; shift ;;
        -h|--help)
            echo "usage: $0 <firmware.img|cfcard-dump> [--writable-from <dump> [--writable-partition START:COUNT]]"
            exit 0 ;;
        *) archive_path="$1"; shift ;;
    esac
done

[ -n "$archive_path" ] || fail "usage: $0 /path/to/zd1200_<version>.img"
[ -f "$archive_path" ] || fail "firmware file not found: $archive_path"
for command in tar gzip python3 md5sum sha256sum; do
    command -v "$command" >/dev/null || fail "$command is required"
done

# A ZD1200 CompactFlash dump is a raw 1872 MiB disk; a Windows ImageUSB dump is
# the same disk with a 512-byte header.  Partition offsets mirror
# scripts/container/build-synthetic-cf.py.
DISK_SIZE=$((3931200 * 512))
CF_H1=62;     CF_C1=84506
CF_H2=84568;  CF_C2=415152
CF_H4=914872; CF_C4=3006008

is_cf_dump() {
    local f="$1" size
    size="$(stat -c%s "$f" 2>/dev/null || echo 0)"
    [ "$size" = "$DISK_SIZE" ] && return 0
    [ "$size" = "$((DISK_SIZE + 512))" ] && return 0
    [ "$(dd if="$f" bs=1 count=16 status=none 2>/dev/null | tr -d '\0')" = "imageUSB" ] && return 0
    return 1
}

# The compressed ELF begins at a variable offset inside the x86 bzImage.
extract_vmlinux() {
    python3 - "$1" "$2" <<'PY'
import sys
import zlib

source, destination = sys.argv[1:]
data = open(source, "rb").read()
for offset in range(len(data) - 2):
    if data[offset:offset + 3] != b"\x1f\x8b\x08":
        continue
    try:
        candidate = zlib.decompress(data[offset:], 16 + zlib.MAX_WBITS)
    except zlib.error:
        continue
    if candidate.startswith(b"\x7fELF") and candidate[4:5] == b"\x01":
        open(destination, "wb").write(candidate)
        break
else:
    raise SystemExit("could not locate an ELF kernel inside bzImage")
PY
}

# Copy hda4 (/writable) and the board serial out of a CF dump.  Used to revive a
# captured /writable onto a firmware-derived ZD1200 rootfs (e.g. a ZD1100 or
# ZD3000 card dump combined with a same-version ZD1200 firmware): /writable is
# data/config only, so nothing in it is platform-specific.  --writable-partition
# START:COUNT overrides the ZD1200 layout for a dump with different geometry.
extract_writable_from_dump() {
    local dump="$1" offset=0 start="" count="" board serial size
    [ -f "$dump" ] || fail "writable dump not found: $dump"
    command -v debugfs >/dev/null || fail "debugfs (e2fsprogs) is required"
    if [ "$(dd if="$dump" bs=1 count=16 status=none | tr -d '\0')" = "imageUSB" ]; then
        offset=512
        echo "== ImageUSB writable dump: skipping its 512-byte header =="
    fi
    if [ -n "$writable_partition" ]; then
        case "$writable_partition" in
            *:*) start="${writable_partition%%:*}"; count="${writable_partition##*:}" ;;
            *) fail "--writable-partition must be START:COUNT" ;;
        esac
    else
        # Take hda4's geometry from the dump's own vendor partition table (the
        # disk size can differ from the ZD1200's).
        echo "== Detecting the /writable partition in $dump =="
        read -r start count <<< "$(python3 "$work_dir/scripts/build/find-cf-partition.py" "$dump" "$offset")" \
            || fail "could not detect the /writable partition; pass --writable-partition START:COUNT"
    fi
    [ -n "$start" ] && [ -n "$count" ] \
        || fail "could not detect the /writable partition; pass --writable-partition START:COUNT"
    size="$(stat -c%s "$dump")"
    [ "$size" -ge "$(((start + count) * 512 + offset))" ] \
        || fail "writable dump is too small for partition $start+$count"
    echo "== Copying /writable (sectors $start+$count) from $dump =="
    dd if="$dump" of="$output_dir/writable.raw" bs=512 \
       skip=$((start + offset / 512)) count="$count" status=none
    board="$(python3 "$work_dir/scripts/container/read-boarddata.py" \
        --offset-bytes "$offset" --allow-empty "$dump" 2>/dev/null || true)"
    if [ -n "$board" ]; then
        printf '%s\n' "$board" > "$output_dir/dump-boarddata"
        serial="$(printf '%s\n' "$board" | sed -n 's/^SERIAL=//p')"
        [ -n "$serial" ] && echo "== Board serial from the writable dump: $serial =="
    fi
}

staging="$(mktemp -d "${TMPDIR:-/tmp}/zd1200-vendor.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
output_dir="$IMAGE_DIR"

# ---- CompactFlash dump input ---------------------------------------------
# A CF dump is a complete appliance (rootfs + /writable + board data).  The
# reiserfs /writable is copied verbatim and left to the guest kernel (which has
# reiserfs built in) rather than converted to ext2.
prepare_from_dump() {
    local dump="$1" offset=0 size board serial
    command -v debugfs >/dev/null || fail "debugfs (e2fsprogs) is required for a CF dump"
    if [ "$(dd if="$dump" bs=1 count=16 status=none | tr -d '\0')" = "imageUSB" ]; then
        offset=512
        echo "== ImageUSB dump: skipping its 512-byte header =="
    fi
    size="$(stat -c%s "$dump")"
    [ "$((size - offset))" = "$DISK_SIZE" ] \
        || fail "CF dump is $size bytes (header $offset); expected $((DISK_SIZE + offset))"

    mkdir -p "$output_dir"
    echo "== Extracting the CF dump partitions =="
    dd if="$dump" of="$output_dir/rootfs.ext2" bs=512 \
       skip=$((CF_H2 + offset / 512)) count="$CF_C2" status=none
    dd if="$dump" of="$output_dir/writable.raw" bs=512 \
       skip=$((CF_H4 + offset / 512)) count="$CF_C4" status=none
    dd if="$dump" of="$staging/hda1.img" bs=512 \
       skip=$((CF_H1 + offset / 512)) count="$CF_C1" status=none

    local boot_file
    for boot_file in bzImage restoreinitramfs.gz restoreinitramfs.ver; do
        debugfs -R "dump /$boot_file $output_dir/$boot_file" "$staging/hda1.img" >/dev/null 2>&1 \
            || fail "CF dump /boot lacks $boot_file"
    done
    debugfs -R "dump /lib/grub/i386-pc/menu.lst $output_dir/menu.lst" "$staging/hda1.img" >/dev/null 2>&1 \
        || fail "CF dump /boot lacks menu.lst"

    # Board serial (and MACs) straight from the image's board-data record.
    board="$(python3 "$work_dir/scripts/container/read-boarddata.py" \
        --offset-bytes "$offset" --allow-empty "$dump" 2>/dev/null || true)"
    printf '%s\n' "$board" > "$output_dir/dump-boarddata"
    serial="$(printf '%s\n' "$board" | sed -n 's/^SERIAL=//p')"
    if [ -n "$serial" ]; then
        echo "== Board serial from the dump: $serial =="
    else
        echo "prepare-vendor-image: warning: the dump carries no board serial" >&2
    fi

    extract_vmlinux "$output_dir/bzImage" "$output_dir/vmlinux"

    echo "Prepared local CF-dump artifacts in $output_dir"
    sha256sum "$output_dir/bzImage" "$output_dir/vmlinux" "$output_dir/rootfs.ext2" \
        "$output_dir/restoreinitramfs.gz" "$output_dir/writable.raw"
}

if is_cf_dump "$archive_path"; then
    prepare_from_dump "$archive_path"
    exit 0
fi

# The downloaded firmware is TAC-encrypted; decrypt it to the gzip-TAR payload
# this script consumes.  A payload that is already gzip is used as-is.
payload="$archive_path"
if ! gzip -t "$archive_path" >/dev/null 2>&1; then
    payload="$staging/payload.tgz"
    python3 "$work_dir/scripts/build/tac-decrypt.py" "$archive_path" "$payload" \
        || fail "could not decrypt $archive_path"
fi

if [ -n "$expected_sha256" ]; then
    actual_sha256="$(sha256sum "$payload" | awk '{print $1}')"
    [ "$actual_sha256" = "$expected_sha256" ] || fail "unexpected payload SHA-256: $actual_sha256"
fi

# Refuse paths that would escape the temporary extraction directory.
if tar -tzf "$payload" | awk '/^\// || /(^|\/)\.\.($|\/)/ { bad = 1 } END { exit bad ? 0 : 1 }'; then
    fail "firmware payload contains an unsafe path"
fi

tar -xzf "$payload" -C "$staging"
metadata="$(find "$staging" -type f -name metadata -print -quit)"
[ -n "$metadata" ] || fail "vendor metadata file not found"
source_dir="$(dirname "$metadata")"

require_file() {
    [ -f "$source_dir/$1" ] || fail "vendor archive lacks $1"
}
for required in bzImage restoreinitramfs.gz restoreinitramfs.ver menu.lst rootfs.i386.ext2.director1200.img metadata file_list.txt ap-models; do
    require_file "$required"
done
[ -d "$source_dir/firmwares" ] || fail "vendor archive lacks firmwares/"
# The web-UI aidfs payload only exists in the 10.2+/10.5 archives; 10.1.x and
# 9.x serve the admin UI straight from the rootfs, so it is optional.  When it
# is absent the /writable tree is staged from firmwares/ alone
# (build-synthetic-cf.py).
if [ ! -f "$source_dir/aidfs/file_list.txt" ]; then
    echo "prepare-vendor-image: note: no aidfs/file_list.txt (pre-10.2 release); /writable is staged without the web aidfs" >&2
fi

metadata_value() {
    awk -F= -v key="$1" '$1 == key { print $2; exit }' "$metadata"
}
# The firmware version/build is intentionally NOT pinned so the script is
# portable across ZD1200 releases; only the hardware platform is validated
# (the boot/image layout depends on it).
[ "$(metadata_value REQUIRE_PLATFORM)" = "nar5520" ] || fail "unexpected platform"
[ "$(metadata_value REQUIRE_SUBPLATFORM)" = "cob7402" ] || fail "unexpected subplatform"

kernel_md5="$(md5sum "$source_dir/bzImage" | awk '{print $1}')"
rootfs_md5="$(md5sum "$source_dir/rootfs.i386.ext2.director1200.img" | awk '{print $1}')"
[ "$kernel_md5" = "$(metadata_value KERNEL_MD5SUM)" ] || fail "bzImage MD5 mismatch"
[ "$rootfs_md5" = "$(metadata_value ROOTFS_MD5SUM)" ] || fail "rootfs MD5 mismatch"

output_dir="$IMAGE_DIR"
mkdir -p "$output_dir"
cp -f "$source_dir/bzImage" "$output_dir/bzImage"
cp -f "$source_dir/restoreinitramfs.gz" "$output_dir/restoreinitramfs.gz"
# The boot menu is the vendor's own template (root=/dev/sda*), used verbatim.
cp -f "$source_dir/menu.lst" "$output_dir/menu.lst"
# Bootloader version the vendor upgrade compares against /boot/restoreinitramfs.ver
# before it rewrites the boot menu (ac_upg.sh:_upg_boot).
cp -f "$source_dir/restoreinitramfs.ver" "$output_dir/restoreinitramfs.ver"
# The vendor archive stores the rootfs gzip-compressed.  The dockerized run
# seeds the synthetic CF partitions from image/rootfs.ext2, and the controller
# needs a RAW ext2 filesystem (superblock
# magic 0xEF53 at byte 1080), so decompress it here.  Idempotent: an
# already-raw ext2 file is left untouched.
cp -f "$source_dir/rootfs.i386.ext2.director1200.img" "$output_dir/rootfs.ext2"

# The ZD1200 firmware-signing cert payload (image-signing / upgrade-entitlement
# bypass cert) ships in the vendor archive.  Extract it into image/signing-cert/
# so the container can mount it at /opt/zd1200/signing-cert for
# scripts/container/patches/20-signing-license.sh (the license).  Override with ZD_SIGN_CERT_HOST if you
# have a specific cert.  Missing files are warned, not fatal (the guest then
# boots without the license).
signing_out="$output_dir/signing-cert"
mkdir -p "$signing_out"
for f in signing_cert.pem digital_sig_sha256.bin digital_sig_sha384.bin all_checksums.txt; do
    if [ -f "$source_dir/$f" ]; then
        cp -f "$source_dir/$f" "$signing_out/"
    else
        echo "prepare-vendor-image: warning: $f not found in vendor archive" >&2
    fi
done
# The vendor ships the two signature blobs 0600 (owner-only); make them readable
# so the container (which runs under user-namespace remap, not host-root) can
# read them during scripts/container/patches/20-signing-license.sh.  Public signing material, not a secret.
chmod 644 "$signing_out"/* 2>/dev/null || true
python3 - "$output_dir/rootfs.ext2" <<'PY'
import sys
from pathlib import Path

p = Path(sys.argv[1])
data = p.read_bytes()
if data[:3] == b"\x1f\x8b\x08":          # gzip
    import gzip as gz
    raw = gz.decompress(data)
    assert raw[1080:1082] == b"\x53\xef", "decompressed rootfs is not ext2"
    p.write_bytes(raw)
    print("image/rootfs.ext2: was gzip, decompressed to raw ext2", len(raw), "bytes")
elif data[1080:1082] == b"\x53\xef":
    print("image/rootfs.ext2: raw ext2 OK")
else:
    print("image/rootfs.ext2: unrecognized format (expected gzip or ext2)")
    raise SystemExit(1)
PY

# The compressed ELF begins at a variable offset inside the x86 bzImage.
# Search gzip members and keep the one that expands to an i386 ELF file.
extract_vmlinux "$output_dir/bzImage" "$output_dir/vmlinux"

if [ -n "$writable_from" ]; then
    # /writable comes from the captured card instead of the archive payload.
    extract_writable_from_dump "$writable_from"
else
    # The web-UI aidfs is only present in newer archives; include it when it
    # exists so the payload tarball (and the /writable staged from it) matches
    # the release.
    payload_members=(firmwares ap-models file_list.txt)
    [ -d "$source_dir/aidfs" ] && payload_members+=(aidfs)
    tar -C "$source_dir" -czf "$output_dir/zd1200-payload.tar.gz" \
        "${payload_members[@]}"
fi

echo "Prepared local vendor-derived artifacts in $output_dir"
if [ -n "$writable_from" ]; then
    files=("$output_dir/bzImage" "$output_dir/vmlinux" "$output_dir/rootfs.ext2" \
           "$output_dir/restoreinitramfs.gz" "$output_dir/writable.raw")
    [ -f "$output_dir/dump-boarddata" ] && files+=("$output_dir/dump-boarddata")
    sha256sum "${files[@]}"
else
    sha256sum "$output_dir/bzImage" "$output_dir/vmlinux" "$output_dir/rootfs.ext2" \
        "$output_dir/restoreinitramfs.gz" "$output_dir/zd1200-payload.tar.gz"
fi
