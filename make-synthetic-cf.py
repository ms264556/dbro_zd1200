#!/usr/bin/env python3
"""Build a synthetic CF disk that BIOS-boots like the real ZD1200.

Layout mirrors the physical ZD1200 CompactFlash (see write-boarddata.py /
HANDOFF):
    hda1  start 62    count 84506    boot  (GRUB boots this, /boot)
    hda2  start 84568 count 415152   root A
    hda3  start 499720 count 415152  root B
    hda4  start 914872 count 3006008 data  (/writable, ext2)
    disk  3931200 sectors (1872 MiB), partition table at ZD_PART_SECTOR=3927001.

The whole boot area — MBR (stage1 at the stage1_5 load address) + the embedded
stage1_5 (self-load count baked in) + the /boot filesystem (stage2 / menu.lst /
default) — is pre-built and shipped as `bootfs.img.gz` (fixed geometry, so it's
baked once).  make-synthetic-cf.py just writes `bootfs.img.gz` (decompressed,
with the patched kernel placed on /boot as /bzImage) at sector 0, then lays down
hda2/hda3 (rootfs) and hda4 (/writable) from `image/`.  No per-build repatching.

Bootfs/GRUB binaries are the only vendor-provided pieces; kernel / rootfs /
/writable come from `image/`.
"""

from pathlib import Path
import os
import gzip
from shutil import which
import struct
import subprocess
import tempfile

base = Path(__file__).resolve().parent
rootfs = base / "image" / "rootfs.ext2"
bootfs_gz = base / "bootfs.img.gz"
kernel_src = base / "image" / "bzImage"     # raw; patch below for QEMU
disk = Path(os.environ.get("SYNTHETIC_DISK", base / "synthetic-cf.img"))
disk.parent.mkdir(parents=True, exist_ok=True)

SECTOR = 512
H1, C1 = 62, 84506          # boot (/boot)
H2, C2 = 84568, 415152      # root A
H3, C3 = 499720, 415152     # root B
H4, C4 = 914872, 3006008    # data (/writable)
DISK_SIZE = 3931200 * SECTOR

if not bootfs_gz.exists():
    raise SystemExit(f"missing {bootfs_gz} (pre-built GRUB bootloader fs)")
if rootfs.stat().st_size > C2 * SECTOR:
    raise SystemExit("rootfs does not fit in root partition")

mke2fs = os.environ.get("MKE2FS") or which("mke2fs")
if not mke2fs:
    raise SystemExit("mke2fs not found: e2fsprogs is required to build the ext2 data partition")

# Patch the kernel for QEMU (the same patch build-cf-image.sh uses); the raw
# bzImage triggers a kernel `BUG: scheduling while atomic` early in init.
with tempfile.TemporaryDirectory() as _kp:
    _kp = Path(_kp)
    patched = _kp / "bzImage.patched"
    subprocess.run(["python3", str(base / "patch-kernel.py"),
                    "--in", str(kernel_src), "--out", str(patched)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    kernel = patched.read_bytes()
    # persist the patched kernel to a temp file so debugfs can reference it.
    _kf = tempfile.NamedTemporaryFile(prefix="bzImage.patched.", suffix=".bin", delete=False)
    _kf.write(kernel); _kf.close()
    kernel_file = Path(_kf.name)


def seed_writable_config(ext2_path):
    passwd_src = base / "dropbear-provision" / "passwd"
    shadow_src = base / "dropbear-provision" / "shadow"
    if not passwd_src.exists() or not shadow_src.exists():
        print("  dropbear-provision/passwd/shadow missing; leaving /writable unseeded")
        return
    cmds = ["mkdir /etc", "mkdir /etc/config",
            f"write {passwd_src} /etc/config/passwd",
            f"write {shadow_src} /etc/config/shadow",
            "set_inode_field /etc/config/shadow mode 0100640"]
    cmdfile = base / ".seed-writable.cmds"
    cmdfile.write_text("\n".join(cmds) + "\n")
    try:
        subprocess.run(["debugfs", "-w", "-f", str(cmdfile), ext2_path],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    finally:
        cmdfile.unlink()


with disk.open("wb") as handle:
    handle.truncate(DISK_SIZE)

# ---- boot area (MBR + embedded stage1_5 + /boot) from bootfs.img.gz ---------
with tempfile.TemporaryDirectory() as td:
    td = Path(td)
    bootfs_img = td / "bootfs.img"
    with gzip.open(bootfs_gz, "rb") as gz, open(bootfs_img, "wb") as out:
        out.write(gz.read())

    # kernel onto /boot: the bootfs is the whole boot area (MBR+gap+hda1 fs),
    # so debugfs the hda1 filesystem portion only (its superblock is at sector H1).
    kb = bootfs_img.read_bytes()
    h1_fs = kb[H1 * SECTOR:H1 * SECTOR + C1 * SECTOR]
    h1_tmp = td / "h1_fs.img"
    open(h1_tmp, "wb").write(h1_fs)
    ker_cmds = td / "ker.cmds"
    ker_cmds.write_text(f"write {kernel_file} /bzImage\n")
    subprocess.run(["debugfs", "-w", "-f", str(ker_cmds), str(h1_tmp)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    h1_fs = open(h1_tmp, "rb").read()
    kb = kb[:H1 * SECTOR] + h1_fs + kb[H1 * SECTOR + len(h1_fs):]
    bootfs_bytes = kb

    with disk.open("r+b") as h:
        h.write(bootfs_bytes)                                # sectors 0..H1+C1-1

# ---- hda2/hda3 rootfs (with kernel at /bzImage, as build-cf-image.sh does) ----
rfs = rootfs.read_bytes()
with tempfile.TemporaryDirectory() as td2:
    td2 = Path(td2)
    # add /bzImage to the rootfs copy via debugfs (matches build-cf-image.sh)
    rt = td2 / "rt.img"
    open(rt, "wb").write(rfs)
    cmds = td2 / "r.cmds"
    cmds.write_text(f"write {kernel_file} /bzImage\n")
    subprocess.run(["debugfs", "-w", "-f", str(cmds), str(rt)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    rfs = open(rt, "rb").read()
with disk.open("r+b") as h:
    for start in (H2, H3):
        h.seek(start * SECTOR)
        h.write(rfs)

# ---- hda4 /writable (ext2) ---------------------------------------------------
with tempfile.NamedTemporaryFile(suffix=".img", delete=False) as tf:
    tf_path = tf.name
try:
    os.truncate(tf_path, C4 * SECTOR)
    subprocess.run([mke2fs, "-F", "-q", "-t", "ext2", tf_path],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    seed_writable_config(tf_path)
    with open(tf_path, "rb") as rf, disk.open("r+b") as h:
        h.seek(H4 * SECTOR)
        while True:
            chunk = rf.read(4 * 1024 * 1024)
            if not chunk:
                break
            h.write(chunk)
finally:
    os.unlink(tf_path)

print(f"created {disk} ({DISK_SIZE // (1024 * 1024)} MiB)")
print(f"  hda1 boot : sectors {H1}..{H1 + C1} (bootfs + kernel)")
print(f"  hda2 rootA: sectors {H2}..{H2 + C2} (rootfs)")
print(f"  hda3 rootB: sectors {H3}..{H3 + C3} (rootfs)")
print(f"  hda4 data : sectors {H4}..{H4 + C4} (ext2)")
