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
backup_file=""
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
        --backup)
            [ $# -ge 2 ] || fail "--backup needs a ruckus_db_*.bak path"
            backup_file="$2"; shift 2 ;;
        --backup=*) backup_file="${1#*=}"; shift ;;
        -h|--help)
            echo "usage: $0 <firmware.img|cfcard-dump> [--writable-from <dump> [--writable-partition START:COUNT]] [--backup <ruckus_db_*.bak>]"
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

# A Windows ImageUSB dump is the same disk behind a 512-byte "imageUSB" header,
# so everything in it sits that much later.  Prints the header size in bytes.
dump_header_offset() {
    if [ "$(dd if="$1" bs=1 count=16 status=none 2>/dev/null | tr -d '\0')" = "imageUSB" ]; then
        echo 512
    else
        echo 0
    fi
}

is_cf_dump() {
    local f="$1" size
    size="$(stat -c%s "$f" 2>/dev/null || echo 0)"
    [ "$size" = "$DISK_SIZE" ] && return 0
    [ "$size" = "$((DISK_SIZE + 512))" ] && return 0
    [ "$(dump_header_offset "$f")" = 512 ] && return 0
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

# A ZD1200 release is "<major>.<minor>.<patch>.<build>", e.g. 10.5.1.0 with
# build 282.  The vendor's own tools treat releases as interchangeable only up
# to the first three components (getValidVer/isSameVer/compare_vernum in
# /bin/sys_wrapper.sh: VER_CHECK_POS="1 2 3"), so that prefix is also this
# project's compatibility unit: 9.10.2.0.84 and 9.10.2.0.130 are
# interchangeable, 9.10.2 and 9.13.3 are not.  The first three components are
# read as numbers, so the vendor's `3rd.4th == 99` placeholder is not a
# version.
version_3() {
    printf '%s' "$1" | awk -F. 'NF >= 3 { print $1 "." $2 "." $3 }'
}

# Print the release (the first three components) of the firmware archive
# metadata, or fail: only releases that carry one can gate a /writable pairing.
require_firmware_version() {
    local raw v
    raw="$(metadata_value VERSION | tr -d ' \t\r')"
    [ -n "$raw" ] || fail "vendor metadata has no VERSION"
    v="$(version_3 "$raw")"
    [ -n "$v" ] && [ "$(printf '%s' "$v" | tr -cd '0-9.')" = "$v" ] \
        || fail "vendor metadata VERSION is not a release number: $raw"
    printf '%s\n' "$v"
}

# Refuse to pair a captured /writable with a firmware rootfs of a different
# release.  The dump's own rootfs carries the release it was running
# (/bin/VERSION, the file sys_wrapper.sh verify-upgrade compares as `curver`),
# while /writable holds data and configuration only -- nothing in it names the
# release, so without this check a mismatched pairing is only discovered after
# the disk is built and the guest has booted.  A dump whose version cannot be
# read is not a proven mismatch, so it only warns.
check_dump_version_match() {
    local dump="$1" offset="$2" firmware="$3" prefix found
    prefix="$(version_3 "$firmware")"
    echo "== Checking the dump rootfs release against the firmware =="
    if ! found="$("$work_dir/scripts/build/dump-rootfs-version.sh" "$dump" "$offset")"; then
        echo "prepare-vendor-image: warning: could not read /bin/VERSION from $dump;" >&2
        echo "  cannot confirm it matches firmware $firmware" >&2
        return 0
    fi
    if [ "$(version_3 "$found")" != "$prefix" ]; then
        fail "the dump's rootfs is release $(version_3 "$found") but the firmware is release $(version_3 "$firmware"): pass a $(version_3 "$found") ZD1200 firmware upgrade file (the first three version components must match; any build)"
    fi
    echo "== Dump rootfs release $found matches firmware $firmware =="
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
    offset="$(dump_header_offset "$dump")"
    [ "$offset" = 512 ] && echo "== ImageUSB writable dump: skipping its 512-byte header =="
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

# A configuration backup (`ruckus_db_*.bak`) is the appliance's XML configuration
# and certificates packed by sys_wrapper.sh save-backup: a gzip tar encrypted with
# the same TAC container as a firmware archive.  Stage the operator's original
# file (the guest's verify-backup decrypts it) after checking host-side that its
# release matches the firmware's.  The vendor accepts a restore only for the same
# release unless it ships a migration path, and this project's
# --writable-from rule is the same first-three-components match, so refusing
# early turns a boot-time E_BackupFromFuture into a clear install-time error.
validate_backup() {
    local backup="$1" firmware="$2" payload purpose version mgmt check
    [ -f "$backup" ] || fail "configuration backup not found: $backup"
    payload="$staging/backup-payload.tgz"
    if gzip -t "$backup" >/dev/null 2>&1; then
        cp -f "$backup" "$payload"
    else
        python3 "$work_dir/scripts/build/tac-decrypt.py" "$backup" "$payload" \
            || fail "could not decrypt the configuration backup (is it a ZD ruckus_db_*.bak?): $backup"
    fi
    gzip -t "$payload" >/dev/null 2>&1 \
        || fail "the configuration backup is not a gzip tar: $backup"

    rm -rf "$staging/backup-check"; mkdir -p "$staging/backup-check"
    tar -xzf "$payload" -C "$staging/backup-check" metadata 2>/dev/null \
        || fail "the configuration backup carries no metadata: $backup"
    check="$staging/backup-check/metadata"
    meta() { awk -F= -v k="$1" '$1 == k { print $2; exit }' "$check" | tr -d ' \t\r'; }
    purpose="$(meta PURPOSE)"
    [ "$purpose" = "backup" ] \
        || fail "not a configuration backup (metadata PURPOSE='${purpose:-<none>}'): $backup"
    version="$(meta VERSION)"
    [ -n "$version" ] || fail "the configuration backup metadata has no VERSION: $backup"

    # Only the release is gated: the backup may come from any ZoneDirector model
    # (ZD1100, ZD1200, ZD3000).  unlock-backup.py rewrites the vendor's
    # PLATFORM/APMODEL gate so the guest's verify-backup accepts it.
    if [ "$(version_3 "$version")" != "$(version_3 "$firmware")" ]; then
        fail "the backup is release $(version_3 "$version") but the firmware is release $(version_3 "$firmware"): pass a $(version_3 "$version") ZD1200 firmware upgrade file (the first three version components must match; any build)"
    fi

    # The appliance's management address, for the installer's report.  Best
    # effort: the restore also restores the address itself.
    mgmt=""
    tar -xzf "$payload" -C "$staging/backup-check" etc/airespider/system.xml 2>/dev/null || true
    if [ -f "$staging/backup-check/etc/airespider/system.xml" ]; then
        mgmt="$(sed -n 's/.*<mgmt-ip[^>]* ip="\([0-9.]*\)".*/\1/p' \
            "$staging/backup-check/etc/airespider/system.xml" | head -n1)"
    fi
    # Stage the platform-unlocked, re-encrypted backup: the guest's verify-backup
    # decrypts it exactly as it would the Web UI's original, then re-checks the
    # release before restoring.
    python3 "$work_dir/scripts/build/unlock-backup.py" "$payload" "$output_dir/backup.bak" \
        || fail "could not rewrite the configuration backup for the ZD1200: $backup"
    printf '%s\n' "${mgmt:-unknown}" > "$output_dir/backup-management-ip"

    if [ -n "$mgmt" ]; then
        echo "== Configuration backup $version accepted (management address $mgmt) =="
        echo "prepare-vendor-image: the appliance will use $mgmt after the first-boot restore" >&2
    else
        echo "== Configuration backup $version accepted (no management address in system.xml) =="
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
    local dump="$1" offset size board serial
    command -v debugfs >/dev/null || fail "debugfs (e2fsprogs) is required for a CF dump"
    offset="$(dump_header_offset "$dump")"
    [ "$offset" = 512 ] && echo "== ImageUSB dump: skipping its 512-byte header =="
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
    [ -n "$backup_file" ] \
        && fail "--backup needs a firmware upgrade file as the source: a CF dump already carries the appliance's configuration"
    # The dump carries its own /writable; drop any backup staged by a previous run.
    rm -f "$output_dir/backup.bak" "$output_dir/backup-management-ip"
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

# The release gates the /writable compatibility check below, so resolve it once
# here.
firmware_version="$(require_firmware_version)"

kernel_md5="$(md5sum "$source_dir/bzImage" | awk '{print $1}')"
rootfs_md5="$(md5sum "$source_dir/rootfs.i386.ext2.director1200.img" | awk '{print $1}')"
[ "$kernel_md5" = "$(metadata_value KERNEL_MD5SUM)" ] || fail "bzImage MD5 mismatch"
[ "$rootfs_md5" = "$(metadata_value ROOTFS_MD5SUM)" ] || fail "rootfs MD5 mismatch"

output_dir="$IMAGE_DIR"
mkdir -p "$output_dir"
# A configuration backup and a captured /writable both seed the appliance's
# configuration, and they cannot both win.
if [ -n "$backup_file" ] && [ -n "$writable_from" ]; then
    fail "--backup and --writable-from both supply the appliance's configuration; pass only one"
fi
if [ -n "$backup_file" ]; then
    validate_backup "$backup_file" "$firmware_version"
else
    # Never let a backup staged by an earlier run (or a different install) be
    # picked up silently by the disk build.
    rm -f "$output_dir/backup.bak" "$output_dir/backup-management-ip"
fi
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
    # /writable comes from the captured card instead of the archive payload, so
    # it must belong to the same release as the firmware rootfs it is paired
    # with.
    writable_offset="$(dump_header_offset "$writable_from")"
    check_dump_version_match "$writable_from" "$writable_offset" "$firmware_version"
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
