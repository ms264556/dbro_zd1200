#!/usr/bin/env python3
"""Build a synthetic CF disk that BIOS-boots like the real ZD1200.

Layout mirrors the physical ZD1200 CompactFlash (see write-boarddata.py):
    sda1  start 62    count 84506    boot  (GRUB boots this, /boot)
    sda2  start 84568 count 415152   root A
    sda3  start 499720 count 415152  root B
    sda4  start 914872 count 3006008 data  (/writable, ext2)
    disk  3931200 sectors (1872 MiB), partition table at ZD_PART_SECTOR=3927001.

The whole boot area — MBR (stage1 at the stage1_5 load address) + the embedded
stage1_5 (self-load count baked in) + the /boot filesystem (stage2 / menu.lst /
default) — is built in-process by `build-bootfs.py` from the source-built GRUB
artifacts the firmware ships in its restore initramfs, with the patched kernel placed on
/boot as /bzImage.
build-synthetic-cf.py writes those bytes at sector 0, then lays down sda2/sda3
(rootfs) and sda4 (/writable) from `image/`.  No per-build repatching.

kernel / rootfs come from `image/`; /writable is seeded from the payload
tarball (AP images + aidfs) plus the optional dropbear-provision login.
"""

from pathlib import Path
import importlib.util
import os
from shutil import which
import struct
import subprocess
import tempfile

base = Path(__file__).resolve().parent
rootfs = base / "image" / "rootfs.ext2"
kernel_src = base / "image" / "bzImage"     # raw; patch below for QEMU
disk = Path(os.environ.get("SYNTHETIC_DISK", base / "synthetic-cf.img"))
disk.parent.mkdir(parents=True, exist_ok=True)

SECTOR = 512
H1, C1 = 62, 84506          # boot (/boot)
H2, C2 = 84568, 415152      # root A
H3, C3 = 499720, 415152     # root B
H4, C4 = 914872, 3006008    # data (/writable)
DISK_SIZE = 3931200 * SECTOR

if rootfs.stat().st_size > C2 * SECTOR:
    raise SystemExit("rootfs does not fit in root partition")


def build_bootfs() -> bytes:
    """Build the boot area (MBR + stage1_5 + sda1 fs) from the firmware's restore initramfs."""
    spec = importlib.util.spec_from_file_location("zd_build_bootfs", base / "build-bootfs.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.build_bootfs()

mke2fs = os.environ.get("MKE2FS") or which("mke2fs")
if not mke2fs:
    raise SystemExit("mke2fs not found: e2fsprogs is required to build the ext2 data partition")

# Patch the kernel for QEMU (scripts/container/patch-kernel.py); the raw
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
    # /etc already exists (mke2fs -d creates it from the staged tree).
    cmds = ["mkdir /etc/config",
            f"write {passwd_src} /etc/config/passwd",
            f"write {shadow_src} /etc/config/shadow",
            "set_inode_field /etc/config/shadow mode 0100640"]
    # Write the debugfs command file somewhere writable: BASE (/opt/zd1200 in
    # the container) is read-only when this runs as an unprivileged user.
    with tempfile.NamedTemporaryFile("w", suffix=".cmds", delete=False) as handle:
        handle.write("\n".join(cmds) + "\n")
        cmdfile = Path(handle.name)
    try:
        subprocess.run(["debugfs", "-w", "-f", str(cmdfile), ext2_path],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    finally:
        cmdfile.unlink()


with disk.open("wb") as handle:
    handle.truncate(DISK_SIZE)

# ---- boot area (MBR + embedded stage1_5 + /boot) from the firmware's restore initramfs -----
with tempfile.TemporaryDirectory() as td:
    td = Path(td)
    # Build the boot area (MBR + embedded stage1_5 + sda1 ext2) from the firmware's restore initramfs.
    kb = build_bootfs()

    # kernel onto /boot: the boot area is MBR+gap+sda1 fs, so debugfs the sda1
    # filesystem portion only (its superblock is at sector H1).
    h1_fs = kb[H1 * SECTOR:H1 * SECTOR + C1 * SECTOR]
    h1_tmp = td / "h1_fs.img"
    open(h1_tmp, "wb").write(h1_fs)
    ker_cmds = td / "ker.cmds"
    cmds = [f"write {kernel_file} /bzImage"]
    # The vendor /boot also carried the rescue initrd; menu.lst's "System rescue
    # from image" entry needs it at (hd0,0)/restoreinitramfs.gz.
    rescue = base / "image" / "restoreinitramfs.gz"
    if rescue.exists():
        cmds.append(f"write {rescue} /restoreinitramfs.gz")
    # The vendor upgrade compares /boot/restoreinitramfs.ver with the payload's
    # restoreinitramfs.ver (ac_upg.sh:_upg_boot); when they differ it replaces
    # /boot/lib/grub/i386-pc/menu.lst with the vendor template (root=/dev/sda*,
    # wrong for our IDE guest).  Ship the version so a same-version upgrade skips
    # that rewrite.
    ver = base / "image" / "restoreinitramfs.ver"
    if not ver.exists():
        raise SystemExit(f"missing {ver} — run scripts/build/prepare-vendor-image.sh")
    cmds.append(f"write {ver} /restoreinitramfs.ver")
    ker_cmds.write_text("\n".join(cmds) + "\n")
    subprocess.run(["debugfs", "-w", "-f", str(ker_cmds), str(h1_tmp)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    h1_fs = open(h1_tmp, "rb").read()
    kb = kb[:H1 * SECTOR] + h1_fs + kb[H1 * SECTOR + len(h1_fs):]
    bootfs_bytes = kb

    with disk.open("r+b") as h:
        h.write(bootfs_bytes)                                # sectors 0..H1+C1-1

# ---- sda2/sda3 rootfs (with kernel at /bzImage) ----
rfs = rootfs.read_bytes()
with tempfile.TemporaryDirectory() as td2:
    td2 = Path(td2)
    # add /bzImage to the rootfs copy via debugfs
    rt = td2 / "rt.img"
    open(rt, "wb").write(rfs)
    cmds = td2 / "r.cmds"
    cmds.write_text(f"write {kernel_file} /bzImage\n")
    subprocess.run(["debugfs", "-w", "-f", str(cmds), str(rt)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # ac_upg.sh _upg_rootfs resize2fs's the freshly written root to fill its
    # partition; do the same so the guest sees the full partition, not the size
    # of the rootfs.ext2 we were shipped.
    os.truncate(rt, C2 * SECTOR)
    subprocess.run(["resize2fs", str(rt)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    rfs = open(rt, "rb").read()
with disk.open("r+b") as h:
    for start in (H2, H3):
        h.seek(start * SECTOR)
        h.write(rfs)


def stage_payload(stage: Path) -> None:
    """Stage the vendor /writable content a firmware install leaves behind: the
    web-UI aidfs/ (ac_upg.sh _upg_aidfs) and the AP images under
    etc/airespider-images/firmwares/ (_upg_apimg), sourced from the payload
    tarball prepare-vendor-image.sh builds."""
    payloads = sorted((base / "image").glob("*-payload.tar.gz"))
    if not payloads:
        print("  payload tarball (*-payload.tar.gz) missing; /writable left without AP images/aidfs")
        return
    import tarfile
    with tarfile.open(payloads[0], "r:gz") as tar:
        members = [m for m in tar.getmembers()
                   if m.name.split("/", 1)[0] in ("aidfs", "firmwares")]
        try:
            tar.extractall(path=str(stage), members=members, filter="data")
        except TypeError:          # Python < 3.12 has no extract filter
            tar.extractall(path=str(stage), members=members)
    made = stage / "firmwares"
    if made.is_dir():
        target = stage / "etc" / "airespider-images"
        target.mkdir(parents=True, exist_ok=True)
        made.rename(target / "firmwares")


# ---- sda4 /writable (ext2) ---------------------------------------------------
# Mirror the /writable state a firmware install leaves behind: the web-UI aidfs
# (_upg_aidfs) and the AP images + manifest under
# etc/airespider-images/firmwares (_upg_apimg), staged from the payload tarball.
# mke2fs -d seeds the filesystem from the staged tree.
with tempfile.TemporaryDirectory() as sd:
    stage = Path(sd)
    (stage / "etc").mkdir(parents=True, exist_ok=True)
    stage_payload(stage)
    with tempfile.NamedTemporaryFile(suffix=".img", delete=False) as tf:
        tf_path = tf.name
    try:
        os.truncate(tf_path, C4 * SECTOR)
        subprocess.run([mke2fs, "-F", "-q", "-t", "ext2", "-d", str(stage), tf_path],
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
print(f"  sda1 boot : sectors {H1}..{H1 + C1} (bootfs + kernel)")
print(f"  sda2 rootA: sectors {H2}..{H2 + C2} (rootfs)")
print(f"  sda3 rootB: sectors {H3}..{H3 + C3} (rootfs)")
print(f"  sda4 data : sectors {H4}..{H4 + C4} (ext2)")
