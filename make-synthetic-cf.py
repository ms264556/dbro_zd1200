#!/usr/bin/env python3
"""Build a disposable, partitioned disk around the extracted ZD rootfs.

The layout mirrors the physical ZD1200 CompactFlash: hda1 is the boot area
(seeded with the root tree so sys_init can mount it at /boot), hda2/hda3 are
the dual root images, and hda4 is the **ext2** writable/data partition.  The
stock appliance ships hda4 as ReiserFS and mounts it with `-o …,nolog` (a
ReiserFS-only option), but the lab rootfs is patched to drop `nolog`
(`patch-rootfs.sh`), so a plain ext2 hda4 mounts fine at /writable.

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

mke2fs = os.environ.get("MKE2FS") or shutil.which("mke2fs")
if not mke2fs:
    raise SystemExit(
        "mke2fs not found: e2fsprogs is required to build the "
        "ext2 data partition (apt install e2fsprogs, or set MKE2FS)"
    )

def seed_writable_config(ext2_path):
    """Populate the /writable data partition (hda4) with the passwd/shadow that
    the rootfs /etc/passwd symlink resolves to.

    The vendor /etc/passwd is a symlink -> /writable/etc/config/passwd and
    /etc/shadow is a regular vendor file in the rootfs.  On a factory-fresh
    volume the controller only writes /writable/etc/config/passwd at first boot,
    so a port-2222 dropbear (static musl getpwnam) could not resolve 'root'
    before that.  Seeding the target makes root resolvable on the very first
    boot; the first-run wizard overwrites these files later.
    """
    passwd_src = base / "dropbear-provision" / "passwd"
    shadow_src = base / "dropbear-provision" / "shadow"
    if not passwd_src.exists() or not shadow_src.exists():
        # The /writable passwd/shadow seed is an optional dropbear prep step
        # (inject-dropbear.sh).  In the container these files are not present,
        # and a factory-virgin /writable is exactly the vendor default, so skip
        # rather than abort (doing so would break every `docker compose up`).
        print("  dropbear-provision/passwd/shadow missing; leaving /writable unseeded")
        return
    cmds = [
        "mkdir /etc",
        "mkdir /etc/config",
        f"write {passwd_src} /etc/config/passwd",
        f"write {shadow_src} /etc/config/shadow",
        "set_inode_field /etc/config/shadow mode 0100640",
    ]
    cmdfile = base / ".seed-writable.cmds"
    cmdfile.write_text("\n".join(cmds) + "\n")
    try:
        subprocess.run(["debugfs", "-w", "-f", str(cmdfile), ext2_path],
                       check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
    finally:
        cmdfile.unlink()


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

    # hda4: a fresh ext2 filesystem.  The rootfs on hda2/hda3 is patched
    # (patch-rootfs.sh) to drop the ReiserFS-only `nolog` mount option from
    # sys_init, so a plain ext2 volume mounts fine at /writable.
    with tempfile.NamedTemporaryFile(suffix=".img", delete=False) as tf:
        tf_path = tf.name
    try:
        os.truncate(tf_path, p4_sectors * SECTOR)
        subprocess.run([mke2fs, "-F", "-q", "-t", "ext2", tf_path], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        seed_writable_config(tf_path)
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
print(f"  hda4 data : sectors {p4_start}..{p4_start + p4_sectors} (ext2)")
