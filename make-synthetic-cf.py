#!/usr/bin/env python3
"""Build a disposable, partitioned disk around the extracted ZD rootfs.

The layout mirrors the physical ZD1200 CompactFlash: hda1 is the boot area
(seeded with the root tree so sys_init can mount it at /boot), hda2/hda3 are
the dual root images, and hda4 is the **ReiserFS** writable/data partition —
exactly the filesystem the vendor's `sys_init` mounts with `-o …,nolog` on a
real appliance.  A plain ext2 hda4 would make that stock mount fail with
"Invalid argument", so a real ReiserFS is created here (requires reiserfsprogs
on the build host: `apt install reiserfsprogs`, or set MKREISERFS).

The data partition starts empty like a factory-fresh volume: `sys_init` and
`rc.pre_ac_init` create /writable/etc, the airespider/config/dump directories,
certs and SSH keys themselves on first boot.
"""

from pathlib import Path
import os
import shutil
import struct
import subprocess
import tempfile

base = Path(__file__).resolve().parent
rootfs = base / "image" / "rootfs.ext2"
disk = Path(os.environ.get("SYNTHETIC_DISK", base / "synthetic-cf.img"))
disk.parent.mkdir(parents=True, exist_ok=True)

SECTOR = 512
DISK_SIZE = 2 * 1024 * 1024 * 1024

# Conservative CF-like layout: three ext2-sized areas. The first area is the
# boarddata/himem partition that the kernel opens through the ext2 layer.
p1_start, p1_sectors = 2048, 327680      # 160 MiB (boot, mounted at /boot)
p2_start, p2_sectors = 329728, 327680    # 160 MiB (root A)
p3_start, p3_sectors = 657408, 327680    # 160 MiB (root B / dual image)
p4_start, p4_sectors = 985088, 3000000   # writable area / remaining CF

if rootfs.stat().st_size > p2_sectors * SECTOR:
    raise SystemExit("rootfs does not fit in synthetic root partition")

mkreiserfs = os.environ.get("MKREISERFS") or shutil.which("mkreiserfs")
if not mkreiserfs:
    raise SystemExit(
        "mkreiserfs not found: reiserfsprogs is required to build the "
        "ReiserFS data partition (apt install reiserfsprogs, or set MKREISERFS)"
    )

with disk.open("wb") as handle:
    handle.truncate(DISK_SIZE)

mbr = bytearray(SECTOR)
entries = [
    (0x00, 0x83, p1_start, p1_sectors),
    (0x80, 0x83, p2_start, p2_sectors),
    (0x00, 0x83, p3_start, p3_sectors),
    (0x00, 0x83, p4_start, p4_sectors),
]

for index, (boot, part_type, start, count) in enumerate(entries):
    # CHS is intentionally saturated; modern kernels use the LBA fields.
    offset = 446 + index * 16
    mbr[offset] = boot
    mbr[offset + 1:offset + 4] = b"\xfe\xff\xff"
    mbr[offset + 4] = part_type
    mbr[offset + 5:offset + 8] = b"\xfe\xff\xff"
    struct.pack_into("<II", mbr, offset + 8, start, count)

mbr[510:512] = b"\x55\xaa"

with disk.open("r+b") as handle:
    handle.write(mbr)
    data = rootfs.read_bytes()
    # Seed the boot area and the two root images with the base filesystem
    # tree, as the physical appliance does.
    for start in (p1_start, p2_start, p3_start):
        handle.seek(start * SECTOR)
        handle.write(data)

    # hda4: a fresh ReiserFS filesystem (the vendor's stock mount command uses
    # the ReiserFS-only `nolog` option, so ext2 would fail with EINVAL).
    with tempfile.NamedTemporaryFile(suffix=".img", delete=False) as tf:
        tf_path = tf.name
    try:
        os.truncate(tf_path, p4_sectors * SECTOR)
        subprocess.run([mkreiserfs, "-f", "-q", tf_path], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with open(tf_path, "rb") as rf:
            handle.seek(p4_start * SECTOR)
            while True:
                chunk = rf.read(4 * 1024 * 1024)
                if not chunk:
                    break
                handle.write(chunk)
    finally:
        os.unlink(tf_path)

    # The boarddata helper reads raw 512-byte sectors. For the first record it
    # adds 0x8000 / 1024 = 32 sectors to 0x3BD3F1; the second starts at the
    # base sector. These are only signatures for the first bring-up attempt;
    # write-boarddata.py overwrites them with the full records.
    base_sector = 0x3BD3F1
    for delta in (16, 32, 64, 128, 0x8000 // 9, 0x8000 // 10,
                  0x8000 // 11, 0x8000 // 12):
        handle.seek((base_sector + delta) * SECTOR)
        handle.write(b"SKCR")
    handle.seek(base_sector * SECTOR)
    handle.write(b"1135")

print(f"created {disk} ({DISK_SIZE // (1024 * 1024)} MiB)")
print(f"  hda1 boot : sectors {p1_start}..{p1_start + p1_sectors} (ext2 seed)")
print(f"  hda2 rootA: sectors {p2_start}..{p2_start + p2_sectors} (ext2 seed)")
print(f"  hda3 rootB: sectors {p3_start}..{p3_start + p3_sectors} (ext2 seed)")
print(f"  hda4 data : sectors {p4_start}..{p4_start + p4_sectors} (ReiserFS)")
