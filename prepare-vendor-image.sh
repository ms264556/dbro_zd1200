#!/usr/bin/env bash
# Build the locally ignored runtime image/ directory from a user-supplied,
# decrypted ZD1200 archive (any version/build of the ZD1200 platform). No vendor
# material is redistributed.
set -euo pipefail

work_dir="$(cd "$(dirname "$0")" && pwd)"
archive_path="${1:-}"
# Optional archive-integrity gate: set EXPECTED_ARCHIVE_SHA256 to enforce a
# specific archive hash; leave empty to accept any (compatible) archive version.
expected_sha256="${EXPECTED_ARCHIVE_SHA256:-}"

fail() {
    echo "prepare-vendor-image: $*" >&2
    exit 1
}

[ -n "$archive_path" ] || fail "usage: $0 /path/to/<zd1200 archive>.img.tgz"
[ -f "$archive_path" ] || fail "archive not found: $archive_path"
for command in tar gzip python3 md5sum sha256sum; do
    command -v "$command" >/dev/null || fail "$command is required"
done

if [ -n "$expected_sha256" ]; then
    actual_sha256="$(sha256sum "$archive_path" | awk '{print $1}')"
    [ "$actual_sha256" = "$expected_sha256" ] || fail "unexpected archive SHA-256: $actual_sha256"
fi

# Refuse paths that would escape the temporary extraction directory.
if tar -tzf "$archive_path" | awk '/^\// || /(^|\/)\.\.($|\/)/ { bad = 1 } END { exit bad ? 0 : 1 }'; then
    fail "archive contains an unsafe path"
fi

staging="$(mktemp -d "${TMPDIR:-/tmp}/zd1051-vendor.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
tar -xzf "$archive_path" -C "$staging"
metadata="$(find "$staging" -type f -name metadata -print -quit)"
[ -n "$metadata" ] || fail "vendor metadata file not found"
source_dir="$(dirname "$metadata")"

require_file() {
    [ -f "$source_dir/$1" ] || fail "vendor archive lacks $1"
}
for required in bzImage restoreinitramfs.gz rootfs.i386.ext2.director1200.img metadata aidfs/file_list.txt file_list.txt ap-models; do
    require_file "$required"
done
[ -d "$source_dir/firmwares" ] || fail "vendor archive lacks firmwares/"

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

output_dir="$work_dir/image"
mkdir -p "$output_dir"
cp -f "$source_dir/bzImage" "$output_dir/bzImage"
cp -f "$source_dir/restoreinitramfs.gz" "$output_dir/restoreinitramfs.gz"
# The vendor archive stores the rootfs gzip-compressed.  The dockerized run
# seeds the synthetic CF partitions from image/rootfs.ext2, and the controller
# needs a RAW ext2 filesystem (superblock
# magic 0xEF53 at byte 1080), so decompress it here.  Idempotent: an
# already-raw ext2 file is left untouched.
cp -f "$source_dir/rootfs.i386.ext2.director1200.img" "$output_dir/rootfs.ext2"

# The ZD1200 firmware-signing cert payload (image-signing / upgrade-entitlement
# bypass cert) ships in the vendor archive.  Extract it into image/signing-cert/
# so the container can mount it at /opt/zd1200/signing-cert for
# patches/20 - PatchSigningLicense.sh (the license).  Override with ZD_SIGN_CERT_HOST if you
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
# read them during patches/20 - PatchSigningLicense.sh.  Public signing material, not a secret.
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
python3 - "$output_dir/bzImage" "$output_dir/vmlinux" <<'PY'
import sys
import zlib

source, destination = sys.argv[1:]
data = open(source, "rb").read()
for offset in range(len(data) - 2):
    if data[offset:offset + 3] != b"\x1f\x8b\x08":
        continue
    try:
        # bzImage puts non-gzip bytes immediately after the compressed member.
        # zlib stops cleanly at the member boundary; gzip.GzipFile rejects that
        # normal trailing kernel data.
        candidate = zlib.decompress(data[offset:], 16 + zlib.MAX_WBITS)
    except zlib.error:
        continue
    if candidate.startswith(b"\x7fELF") and candidate[4:5] == b"\x01":
        open(destination, "wb").write(candidate)
        break
else:
    raise SystemExit("could not locate an ELF kernel inside bzImage")
PY

tar -C "$source_dir" -czf "$output_dir/zd1051-payload.tar.gz" \
    firmwares aidfs ap-models file_list.txt

echo "Prepared local vendor-derived artifacts in $output_dir"
sha256sum "$output_dir/bzImage" "$output_dir/vmlinux" "$output_dir/rootfs.ext2" \
    "$output_dir/restoreinitramfs.gz" "$output_dir/zd1051-payload.tar.gz"
