#!/usr/bin/env python3
"""Build the ZD1200 boot area from the GRUB artifacts built by guest-src/grub097_src/.

`make-synthetic-cf.py` calls `build_bootfs()` and writes the returned bytes at
sector 0 of the synthetic CF, so the boot area is derived on the fly — there is no
bootfs image file in the repo.  It is built from the GPL-source GRUB binaries that
`guest-src/grub097_src/build.sh` compiles from upstream GRUB 0.97 + patches, so no vendor
binaries are redistributed.  The layout it produces is the one
`make-synthetic-cf.py` expects:

    sector 0            MBR  = GRUB stage1 (patched) + partition-table area + 0x55AA
    sectors 1..61       the *installed* e2fs_stage1_5, raw (outside any fs)
    sectors 62..84567   hda1 ext2 filesystem (C1 = 84506 sectors, /boot)

`guest-src/grub097_src/out/lib/grub/i386-pc/` holds the build output (plus the
`/boot` config files from `guest-src/grub097_src/config/`): GRUB's uninstalled `stage1` /
`stage1_5` and `stage2`.  Three things have to be done to make it bootable:

1. **stage1 -> MBR.**  Patch stage1's on-disk fields exactly like GRUB's
   `install` does for a stage1_5 (stage1/stage1.h offsets): load address
   0x2000:0x0200 and source sector 1, and NOP out the boot-drive-check `jmp`
   (install does this for hard disks).  The partition-table area is left as the
   reference has it (zeros + boot flag), and board data is not touched — that
   lives in the partition-table-like sector at LBA 3927001, written by
   write-boarddata.py, far outside this boot area.
2. **stage1_5 -> installed stage1_5.**  The shipped `e2fs_stage1_5` is unusable:
   its self-blocklist (`start.S`: `blocklist_default_len: .word 0`) has length
   zero, so it would load nothing.  Patch the first sector's blocklist entry
   (0x1f8) to describe its own remaining sectors, and the second sector's
   embedded "config file" pointer (`STAGE2_VER_STR_OFFS`) with the device
   (hd0,0) and the stage2 path.  This is what GRUB's `install` writes back.
3. **menu.lst geometry.**  The profile ships ZD3000-era geometry
   (`/dev/sda*`, current = root A).  Rewrite the two `kernel` lines to the
   ZD1200 layout (`/dev/hda*`, current = root B = hda3, backup = root A = hda2).

Usage:
    ./build-bootfs.py --check             # build + verify, write nothing
    ./build-bootfs.py --out /tmp/boot.img # also write the gzipped boot area
"""

from pathlib import Path
import argparse
import gzip
import shutil
import struct
import subprocess
import sys
import tempfile

BASE = Path(__file__).resolve().parent
SRC = BASE / "guest-src" / "grub097_src" / "out" / "lib" / "grub" / "i386-pc"

SECTOR = 512
H1, C1 = 62, 84506          # hda1 /boot: first sector, sector count (make-synthetic-cf.py)
GAP_SECTORS = H1 - 1        # sectors 1..61, between the MBR and hda1
BOOT_AREA = (H1 + C1) * SECTOR

# GRUB 0.97 stage1 field offsets (stage1/stage1.h).
STAGE1_STAGE2_ADDRESS = 0x42
STAGE1_STAGE2_SECTOR = 0x44
STAGE1_STAGE2_SEGMENT = 0x48
STAGE1_BOOT_DRIVE_CHECK = 0x4b
STAGE1_NT_MAGIC = 0x1b8
STAGE1_PARTEND = 0x1fe

# stage1_5 install fields (stage2/start.S, stage2/shared.h).
BOOTSEC_LISTSIZE = 8
STAGE1_5_LOAD_ADDR = 0x2000
STAGE1_5_REST_SEG = 0x0220
STAGE1_5_REST_ADDR = STAGE1_5_REST_SEG << 4
STAGE2_VER_STR_OFFS = 0x12

# GRUB internal device id for (hd0,0) on the boot drive: drive 0xFF ("same
# drive") | partition 0x00FFFF (primary partition 0).  Matches the reference
# bootfs's installed stage1_5.
DEVICE_HD0_P0 = 0xFF00FFFF

# Ruckus's grub-partition.patch makes GRUB read the partition table from a fixed
# "ZD pt sector" instead of the MBR (disk_io.c: next_partition()).  The GPL
# source hard-codes the platform-0 value, which lies past the end of the
# ZD1200's 3,931,200-sector CF, so GRUB would fall back to the (empty) MBR
# partition table and fail to mount hda1 with "Error 17".  The ZD1200
# (CONFIG_V54_ZD_PLATFORM=1) and write-boarddata.py both use the platform-1
# value, so patch the compiled-in immediate in the two binaries that parse the
# partition table.
ZD_PART_SECTOR_BUILT = 3982101      # platform 0 — what the GPL source builds
ZD_PART_SECTOR_ZD1200 = 3927001     # platform 1 — ZD1200 / write-boarddata.py

# GRUB's stage2 finds its config file by path; the source-built stage2 has
# "/boot/grub/menu.lst" compiled in, and the installed stage1_5 is pointed at
# /lib/grub/i386-pc/stage2.  Populate both trees so either resolves.
GRUB_DIRS = ("/lib/grub/i386-pc", "/boot/grub")
FILES = ("stage1", "stage2", "e2fs_stage1_5", "menu.lst", "default")

# The ZD1200 boot geometry (BOOTFS.md): current = root B, backup = root A, and
# the guest enumerates the CF as hda (IDE).  The profile ships the ZD3000-era
# /dev/sda + root-A-current variant.
MENU_CURRENT_OLD = "\tkernel (hd0,1)/bzImage console=ttyS0,115200n8 root=/dev/sda2 ro quiet"
MENU_CURRENT_NEW = "\tkernel (hd0,2)/bzImage console=ttyS0,115200n8 root=/dev/hda3 ro quiet"
MENU_BACKUP_OLD = "\tkernel (hd0,2)/bzImage console=ttyS0,115200n8 root=/dev/sda3 ro quiet"
MENU_BACKUP_NEW = "\tkernel (hd0,1)/bzImage console=ttyS0,115200n8 root=/dev/hda2 ro quiet"


def fail(msg: str) -> "None":
    print(f"build-bootfs: {msg}", file=sys.stderr)
    raise SystemExit(1)


def check(condition: bool, msg: str) -> None:
    if not condition:
        fail(msg)


def require_tools() -> None:
    for tool in ("mke2fs", "debugfs"):
        if not shutil.which(tool):
            fail(f"{tool} not found — e2fsprogs is required")


def read_sources() -> dict:
    check(SRC.is_dir(), f"missing {SRC}")
    out = {}
    for name in FILES:
        path = SRC / name
        check(path.is_file(), f"missing source artifact: {path}")
        out[name] = path.read_bytes()
    return out


def patch_menu_lst(raw: bytes) -> bytes:
    """Rewrite the two normal-boot kernel lines to the ZD1200 geometry."""
    text = raw.decode("ascii")
    check(MENU_CURRENT_OLD in text, "menu.lst: expected current-boot line not found")
    check(MENU_BACKUP_OLD in text, "menu.lst: expected backup-boot line not found")
    text = text.replace(MENU_CURRENT_OLD, "@@current@@").replace(MENU_BACKUP_OLD, "@@backup@@")
    text = text.replace("@@current@@", MENU_CURRENT_NEW).replace("@@backup@@", MENU_BACKUP_NEW)
    check("root=/dev/sda" not in text.split("device (hd0)")[-1].split("title System rescue")[0],
          "menu.lst: /dev/sda survived the geometry rewrite")
    check(text.count("root=/dev/hda3") == 1 and text.count("root=/dev/hda2") == 1,
          "menu.lst: expected exactly one hda3 (current) and one hda2 (backup) kernel line")
    return text.encode("ascii")


def patch_zd_part_sector(data: bytes, name: str) -> bytes:
    """Point GRUB's compiled-in ZD pt sector at the ZD1200's board-data sector."""
    built = struct.pack("<I", ZD_PART_SECTOR_BUILT)
    zd1200 = struct.pack("<I", ZD_PART_SECTOR_ZD1200)
    if data.count(zd1200) == 1 and built not in data:
        return data  # already built for platform 1
    check(data.count(built) == 1,
          f"{name}: expected exactly one ZD_PART_SECTOR={ZD_PART_SECTOR_BUILT} constant, "
          f"found {data.count(built)}")
    return data.replace(built, zd1200)


def build_mbr(stage1: bytes) -> bytes:
    check(len(stage1) == SECTOR, f"stage1 is {len(stage1)} bytes, expected 512")
    mbr = bytearray(stage1)
    # stage1 loads the first sector of stage1_5 from LBA 1 to 0x2000:0x0200.
    struct.pack_into("<H", mbr, STAGE1_STAGE2_ADDRESS, STAGE1_5_LOAD_ADDR)
    struct.pack_into("<I", mbr, STAGE1_STAGE2_SECTOR, 1)
    struct.pack_into("<H", mbr, STAGE1_STAGE2_SEGMENT, STAGE1_5_LOAD_ADDR >> 4)
    # Hard disk: run the buggy-BIOS drive check instead of skipping it (GRUB's
    # install replaces the 2-byte jmp with two nops).
    mbr[STAGE1_BOOT_DRIVE_CHECK:STAGE1_BOOT_DRIVE_CHECK + 2] = b"\x90\x90"
    # Partition-table area: zeros with the boot flag on entry 1, as in the
    # reference image.  GRUB's stage1 does not read it.
    area = bytearray(STAGE1_PARTEND - STAGE1_NT_MAGIC)
    area[6] = 0x80
    mbr[STAGE1_NT_MAGIC:STAGE1_PARTEND] = area
    check(mbr[STAGE1_PARTEND:STAGE1_PARTEND + 2] == b"\x55\xaa", "stage1 lost its 0x55AA signature")
    return bytes(mbr)


def build_stage1_5(stage1_5: bytes) -> bytes:
    check(len(stage1_5) <= GAP_SECTORS * SECTOR,
          f"e2fs_stage1_5 ({len(stage1_5)} B) does not fit in the {GAP_SECTORS}-sector gap")
    total = (len(stage1_5) + SECTOR - 1) // SECTOR
    img = bytearray(stage1_5)
    # firstlist entry at the end of the first sector: sector, length, segment.
    # stage1_5 is embedded contiguously at LBA 1, so the rest starts at LBA 2.
    img[0x1f8:0x200] = struct.pack("<IHH", 2, total - 1, STAGE1_5_REST_SEG)
    # Second sector: the stage2 pointer GRUB's install writes after the version
    # string at STAGE2_VER_STR_OFFS -> 4-byte device id + NUL-terminated path.
    second = 0x200
    ver = bytes(img[second + STAGE2_VER_STR_OFFS:second + SECTOR])
    nul = ver.find(b"\x00")
    check(nul != -1, "stage1_5: no version string at STAGE2_VER_STR_OFFS")
    dev_off = second + STAGE2_VER_STR_OFFS + nul + 1
    payload = struct.pack("<I", DEVICE_HD0_P0) + b"/lib/grub/i386-pc/stage2\x00"
    check(dev_off + len(payload) <= second + SECTOR,
          "stage1_5: stage2 pointer does not fit in the second sector")
    img[dev_off:dev_off + len(payload)] = payload
    return bytes(img)


def build_ext2(files: dict, menu_lst: bytes) -> bytes:
    """mke2fs an hda1-sized ext2 and populate it with the GRUB tree."""
    with tempfile.TemporaryDirectory(prefix="zd-bootfs.") as td:
        td = Path(td)
        img = td / "hda1.ext2"
        with img.open("wb") as fh:
            fh.truncate(C1 * SECTOR)
        # ext2, 1024-byte blocks, 128-byte inodes, no optional features — what
        # the source-built buildroot image uses and what GRUB 0.97's ext2
        # driver expects (it assumes 128-byte inodes and ignores rev/features).
        subprocess.run(["mke2fs", "-q", "-t", "ext2", "-b", "1024", "-I", "128",
                        "-O", "none", "-m", "0", "-F", str(img)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        staged = {}
        for name in FILES:
            data = menu_lst if name == "menu.lst" else files[name]
            p = td / name
            p.write_bytes(data)
            staged[name] = p

        cmds = []
        seen = set()
        for d in GRUB_DIRS:
            parts = d.strip("/").split("/")
            for i in range(1, len(parts) + 1):
                path = "/" + "/".join(parts[:i])
                if path not in seen:
                    seen.add(path)
                    cmds.append(f"mkdir {path}")
            for name in FILES:
                cmds.append(f"write {staged[name]} {d}/{name}")
        cmdfile = td / "cmds"
        cmdfile.write_text("\n".join(cmds) + "\n")
        subprocess.run(["debugfs", "-w", "-f", str(cmdfile), str(img)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return img.read_bytes()


def assemble(mbr: bytes, stage1_5: bytes, fs: bytes) -> bytes:
    check(len(fs) == C1 * SECTOR, f"filesystem is {len(fs)} bytes, expected {C1 * SECTOR}")
    boot = mbr + stage1_5.ljust(GAP_SECTORS * SECTOR, b"\x00") + fs
    check(len(boot) == BOOT_AREA, f"boot area is {len(boot)} bytes, expected {BOOT_AREA}")
    return boot


def verify(boot: bytes, stage1_5_len: int) -> list:
    mbr = boot[:SECTOR]
    st15 = boot[SECTOR:H1 * SECTOR]
    checks = [
        ("MBR stage2 address 0x2000",
         struct.unpack_from("<H", mbr, STAGE1_STAGE2_ADDRESS)[0] == STAGE1_5_LOAD_ADDR),
        ("MBR stage2 sector 1",
         struct.unpack_from("<I", mbr, STAGE1_STAGE2_SECTOR)[0] == 1),
        ("MBR stage2 segment 0x0200",
         struct.unpack_from("<H", mbr, STAGE1_STAGE2_SEGMENT)[0] == STAGE1_5_LOAD_ADDR >> 4),
        ("MBR boot-drive check nop'ed", mbr[STAGE1_BOOT_DRIVE_CHECK:STAGE1_BOOT_DRIVE_CHECK + 2] == b"\x90\x90"),
        ("MBR signature", mbr[STAGE1_PARTEND:STAGE1_PARTEND + 2] == b"\x55\xaa"),
    ]
    sector, length, segment = struct.unpack_from("<IHH", st15, 0x1f8)
    checks += [
        (f"stage1_5 blocklist sector={sector} len={length} seg={segment:#06x}",
         sector == 2
         and length == (stage1_5_len + SECTOR - 1) // SECTOR - 1
         and segment == STAGE1_5_REST_SEG),
        ("stage1_5 ZD pt sector -> 3927001",
         struct.pack("<I", ZD_PART_SECTOR_ZD1200) in st15
         and struct.pack("<I", ZD_PART_SECTOR_BUILT) not in st15),
    ]
    for msg, ok in checks:
        if not ok:
            fail(f"verification failed: {msg}")

    with tempfile.TemporaryDirectory(prefix="zd-bootfs-verify.") as td:
        fs = Path(td) / "hda1.ext2"
        fs.write_bytes(boot[H1 * SECTOR:])
        for path in ("/lib/grub/i386-pc/stage2", "/boot/grub/menu.lst"):
            r = subprocess.run(["debugfs", "-R", f"stat {path}", str(fs)],
                               capture_output=True, text=True)
            if r.returncode != 0 or "Inode:" not in r.stdout:
                fail(f"verification failed: {path} not present in the built filesystem")
        stage2 = Path(td) / "stage2"
        subprocess.run(["debugfs", "-R", f"dump /lib/grub/i386-pc/stage2 {stage2}", str(fs)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        data = stage2.read_bytes()
        checks.append(("stage2 ZD pt sector -> 3927001",
                       struct.pack("<I", ZD_PART_SECTOR_ZD1200) in data
                       and struct.pack("<I", ZD_PART_SECTOR_BUILT) not in data))
    return checks


def build_bootfs() -> bytes:
    """Build and verify the boot area (MBR + embedded stage1_5 + hda1 ext2)."""
    require_tools()
    files = read_sources()
    for name in ("e2fs_stage1_5", "stage2"):
        files[name] = patch_zd_part_sector(files[name], name)
    menu_lst = patch_menu_lst(files["menu.lst"])
    boot = assemble(build_mbr(files["stage1"]),
                    build_stage1_5(files["e2fs_stage1_5"]),
                    build_ext2(files, menu_lst))
    checks = verify(boot, len(files["e2fs_stage1_5"]))
    for msg, ok in checks:
        if not ok:
            fail(f"verification failed: {msg}")
    for msg, _ in checks:
        print(f"  boot area ok: {msg}")
    return boot


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    group = ap.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true",
                       help="build and verify, write nothing")
    group.add_argument("--out", metavar="PATH",
                       help="also write the gzipped boot area to PATH")
    args = ap.parse_args()

    boot = build_bootfs()
    if args.out:
        out = Path(args.out)
        with gzip.GzipFile(filename="", mode="wb", fileobj=out.open("wb"), mtime=0) as gz:
            gz.write(boot)
        print(f"build-bootfs: wrote {out} ({out.stat().st_size} bytes compressed, "
              f"{len(boot)} bytes uncompressed)")
    else:
        print(f"build-bootfs: boot area OK ({len(boot)} bytes)")


if __name__ == "__main__":
    main()
