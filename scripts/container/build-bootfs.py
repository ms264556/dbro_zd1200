#!/usr/bin/env python3
"""Build the ZD1200 boot area from the GRUB binaries the firmware ships.

`build-synthetic-cf.py` calls `build_bootfs()` and writes the returned bytes at
sector 0 of the synthetic CF, so the boot area is derived on the fly — there is no
bootfs image file in the repo.  GRUB's `stage1`/`stage2`/`e2fs_stage1_5` are taken
straight out of the firmware's factory-restore initramfs
(`image/restoreinitramfs.gz`, `lib/grub/i386-pc/`), which already carries the
ZD1200 pt sector; `menu.lst` comes from the firmware archive (`image/menu.lst`)
and the saved-default file is generated.  The layout it produces is the one
`build-synthetic-cf.py` expects:

    sector 0            MBR  = GRUB stage1 (patched) + partition-table area + 0x55AA
    sectors 1..61       the *installed* e2fs_stage1_5, raw (outside any fs)
    sectors 62..84567   hda1 ext2 filesystem (C1 = 84506 sectors, /boot)

Three things have to be done to make it bootable:

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
3. **menu.lst geometry.**  The guest sees the CF as `/dev/sda` (QEMU AHCI), so
   the vendor's own template is used verbatim: current = root A = sda2, backup
   = root B = sda3.  That is the same menu `ac_upg.sh` installs when it rewrites
   the boot area, so an upgrade cannot change which partitions are booted.
4. **stage2 config path + /sbin tools.**  The vendor's upgrade
   (`ac_upg.sh`) swaps `/lib/grub/i386-pc/menu.lst` and rewrites
   `/lib/grub/i386-pc/default` via `/boot/sbin/grub-set-default`.  stage2 is
   patched to read that same config path (`patch_stage2_config`, what the
   vendor's `setup --prefix=/lib/grub/i386-pc` does), the GRUB tree is written
   ONLY under `/lib/grub/i386-pc`, and the `sbin/grub*` tools are installed in
   `/sbin`.

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
INITRAMFS = BASE / "image" / "restoreinitramfs.gz"
MENU_LST = BASE / "image" / "menu.lst"

# Where the firmware's restore initramfs keeps GRUB, and what we take from it.
GRUB_INITRAMFS_DIR = "lib/grub/i386-pc"
CPIO_HEADER = 110
GRUB_FILES = ("stage1", "stage2", "e2fs_stage1_5")
CONFIG_FILES = ("menu.lst", "default")

SECTOR = 512
H1, C1 = 62, 84506          # hda1 /boot: first sector, sector count (build-synthetic-cf.py)
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

# stage2's compiled-in config-file path.  A real ZD1200 installs GRUB with
# `setup --prefix=/lib/grub/i386-pc`, which patches this field; do the same so
# GRUB reads and writes the same menu.lst/default the upgrade edits.
STAGE2_CONFIG_OLD = b"/boot/grub/menu.lst"
STAGE2_CONFIG_NEW = b"/lib/grub/i386-pc/menu.lst"

# Ruckus's grub-partition.patch makes GRUB read the partition table from a fixed
# "ZD pt sector" instead of the MBR (disk_io.c: next_partition()).  The firmware's
# binaries already carry the ZD1200 value; the platform-0 value only shows up in a
# from-source build, which patch_zd_part_sector() rewrites.
ZD_PART_SECTOR_BUILT = 3982101      # platform 0 (from-source builds)
ZD_PART_SECTOR_ZD1200 = 3927001     # platform 1 — ZD1200 / write-boarddata.py

# The firmware's stage2 has "/boot/grub/menu.lst" compiled in, but the vendor's
# own scripts read and write the GRUB tree under /lib/grub/i386-pc: ac_upg.sh
# (ZD_PARTFLAG/ZD_PARTMENU) and /etc/init.d/flag_reset both use
# /boot/lib/grub/i386-pc/{menu.lst,default}, and the upgrade calls
# /boot/sbin/grub-set-default to move the saved default.  A real ZD1200 gets
# that layout because grub-install/`setup --prefix=/lib/grub/i386-pc` patches
# stage2's config-file path.  patch_stage2_config() does the same here, so the
# bootfs is populated ONLY under /lib/grub/i386-pc (no /boot/grub copy) and GRUB
# reads and writes exactly the files the upgrade edits.
GRUB_DIR = "/lib/grub/i386-pc"
GRUB_DIRS = (GRUB_DIR,)
# GRUB's /sbin tools (grub-set-default is a shell script the upgrade runs).
GRUB_SBIN_PREFIX = "sbin/grub"
SBIN_DIR = "/sbin"
FILES = GRUB_FILES + CONFIG_FILES

# The guest enumerates the CF as /dev/sda (QEMU AHCI controller; see
# launch-vm.sh), so the vendor's own menu template is used verbatim:
# current = root A = sda2, backup = root B = sda3.  That is exactly the menu
# ac_upg.sh:_upg_boot installs when it rewrites the boot area, so the bootfs and
# the post-upgrade menu never diverge.
MENU_CURRENT = "\tkernel (hd0,1)/bzImage console=ttyS0,115200n8 root=/dev/sda2 ro quiet"
MENU_BACKUP = "\tkernel (hd0,2)/bzImage console=ttyS0,115200n8 root=/dev/sda3 ro quiet"

# QEMU's PIT/IO-APIC wiring makes the kernel's check_timer() probe fail
# intermittently ("MP-BIOS bug: 8254 timer not connected to IO-APIC" ->
# "IO-APIC + timer doesn't work!" panic, ~3-5% of boots).  This 2.6.32 kernel
# does not add no_timer_check implicitly under KVM, so add it to the kernel
# command line: Documentation/kernel-parameters.txt, "Disables the code which
# tests for broken timer IRQ sources".
TIMER_FIX = " no_timer_check"


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


def extract_grub() -> dict:
    """Pull the GRUB stage files and the /sbin/grub* tools from the initramfs.

    It is an SVR4 (no-CRC) cpio archive under gzip; walk the entries and keep the
    three stage files plus every sbin/grub* tool (the upgrade runs
    /boot/sbin/grub-set-default to move the saved default).
    """
    check(INITRAMFS.is_file(),
          f"missing {INITRAMFS} — run scripts/build/prepare-vendor-image.sh")
    wanted = {f"{GRUB_INITRAMFS_DIR}/{n}": n for n in GRUB_FILES}
    found = {}
    with gzip.open(INITRAMFS, "rb") as fh:
        while True:
            hdr = fh.read(CPIO_HEADER)
            if len(hdr) < CPIO_HEADER or hdr[:6] != b"070701":
                break
            fields = [int(hdr[6 + i * 8:6 + (i + 1) * 8], 16) for i in range(13)]
            namesize, filesize = fields[11], fields[6]
            name = fh.read(namesize).rstrip(b"\x00").decode()
            fh.read((-(CPIO_HEADER + namesize)) % 4)
            data = fh.read(filesize)
            fh.read((-filesize) % 4)
            if name == "TRAILER!!!":
                break
            if name in wanted:
                found[wanted[name]] = data
            elif name.startswith(GRUB_SBIN_PREFIX):
                found[f"{SBIN_DIR}/{name.split('/', 1)[1]}"] = data
    for name in GRUB_FILES:
        check(name in found, f"{INITRAMFS}: {GRUB_INITRAMFS_DIR}/{name} not found")
    check(f"{SBIN_DIR}/grub-set-default" in found,
          f"{INITRAMFS}: sbin/grub-set-default not found")
    return found


def build_default(entry: int = 0) -> bytes:
    """Generate the GRUB saved-default file exactly as grub-set-default writes it."""
    backslash = chr(92)
    lines = [str(entry)] + ["#"] * 10 + [
        "# WARNING: If you want to edit this file directly, do not remove any line",
        f"# from this file, including this warning. Using `grub-set-default{backslash}' is",
        "# strongly recommended.",
    ]
    return ("\n".join(lines) + "\n").encode("ascii")


def read_sources() -> dict:
    out = extract_grub()
    check(MENU_LST.is_file(), f"missing {MENU_LST} — run scripts/build/prepare-vendor-image.sh")
    out["menu.lst"] = MENU_LST.read_bytes()
    out["default"] = build_default()
    return out


def verify_menu_lst(raw: bytes) -> bytes:
    """Check menu.lst is the vendor template for our /dev/sda geometry.

    The guest sees the CF as /dev/sda (QEMU AHCI), so the vendor's menu is used
    as-is: current = root A = sda2, backup = root B = sda3.
    """
    text = raw.decode("ascii")
    check(MENU_CURRENT in text, "menu.lst: current-boot line (root=/dev/sda2) not found")
    check(MENU_BACKUP in text, "menu.lst: backup-boot line (root=/dev/sda3) not found")
    check(text.count("root=/dev/sda2") == 1 and text.count("root=/dev/sda3") == 1,
          "menu.lst: expected exactly one sda2 (current) and one sda3 (backup) kernel line")
    check("root=/dev/hda" not in text, "menu.lst: /dev/hda survived (the guest is /dev/sda)")
    return raw


def patch_menu_cmdline(raw: bytes) -> bytes:
    """Append no_timer_check to every ZD1200 kernel line in menu.lst."""
    lines = []
    patched = 0
    for line in raw.decode("ascii").splitlines(keepends=True):
        if line.startswith("\tkernel (hd0,") and "no_timer_check" not in line:
            line = line.rstrip("\n") + TIMER_FIX + "\n"
            patched += 1
        lines.append(line)
    check(patched >= 2, f"menu.lst: expected ZD1200 kernel lines, patched {patched}")
    return "".join(lines).encode("ascii")


def patch_stage2_config(data: bytes) -> bytes:
    """Point stage2's config file at /lib/grub/i386-pc/menu.lst.

    stage2 carries "/boot/grub/menu.lst" as its compiled-in default and leaves a
    NUL-padded buffer after it.  Overwrite that buffer with the vendor path so
    GRUB reads and writes the files the upgrade edits, instead of a /boot/grub
    copy the upgrade never touches.
    """
    check(data.count(STAGE2_CONFIG_OLD) == 1,
          f"stage2: expected exactly one {STAGE2_CONFIG_OLD!r}, "
          f"found {data.count(STAGE2_CONFIG_OLD)}")
    off = data.index(STAGE2_CONFIG_OLD)
    pad = 0
    while (off + len(STAGE2_CONFIG_OLD) + pad < len(data)
           and data[off + len(STAGE2_CONFIG_OLD) + pad] == 0):
        pad += 1
    need = len(STAGE2_CONFIG_NEW) + 1 - len(STAGE2_CONFIG_OLD)
    check(pad >= need,
          f"stage2: only {pad} bytes of config-file padding, need {need}")
    out = bytearray(data)
    out[off:off + len(STAGE2_CONFIG_NEW)] = STAGE2_CONFIG_NEW
    out[off + len(STAGE2_CONFIG_NEW)] = 0
    return bytes(out)


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


def build_ext2(files: dict) -> bytes:
    """mke2fs an ext2 the size of the boot partition and populate it with the GRUB tree."""
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
            data = files[name]
            p = td / name
            p.write_bytes(data)
            staged[name] = p

        sbin = {k: v for k, v in files.items() if k.startswith(SBIN_DIR + "/")}
        for key, data in sbin.items():
            p = td / key.strip("/").replace("/", "_")
            p.write_bytes(data)
            staged[key] = p

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
        # GRUB's /sbin tools (grub-set-default is a shell script the upgrade runs).
        if sbin:
            cmds.append(f"mkdir {SBIN_DIR}")
            for key in sorted(sbin):
                cmds.append(f"write {staged[key]} {key}")
                cmds.append(f"set_inode_field {key} mode 0100755")
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
        for path in ("/lib/grub/i386-pc/stage2", "/lib/grub/i386-pc/menu.lst",
                     "/lib/grub/i386-pc/default", "/sbin/grub-set-default"):
            r = subprocess.run(["debugfs", "-R", f"stat {path}", str(fs)],
                               capture_output=True, text=True)
            if r.returncode != 0 or "Inode:" not in r.stdout:
                fail(f"verification failed: {path} not present in the built filesystem")
        # The upgrade edits /lib/grub/i386-pc/*, so there must be no /boot/grub
        # copy that GRUB could read instead.
        r = subprocess.run(["debugfs", "-R", "stat /boot/grub", str(fs)],
                           capture_output=True, text=True)
        if r.returncode == 0 and "Inode:" in r.stdout:
            fail("verification failed: /boot/grub exists; GRUB would read it instead "
                 "of the tree the upgrade edits")
        stage2 = Path(td) / "stage2"
        subprocess.run(["debugfs", "-R", f"dump /lib/grub/i386-pc/stage2 {stage2}", str(fs)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        data = stage2.read_bytes()
        checks.append(("stage2 ZD pt sector -> 3927001",
                       struct.pack("<I", ZD_PART_SECTOR_ZD1200) in data
                       and struct.pack("<I", ZD_PART_SECTOR_BUILT) not in data))
        checks.append(("stage2 config file -> /lib/grub/i386-pc/menu.lst",
                       STAGE2_CONFIG_NEW + b"\x00" in data
                       and STAGE2_CONFIG_OLD not in data))
        menu = Path(td) / "menu.lst"
        subprocess.run(["debugfs", "-R", f"dump /lib/grub/i386-pc/menu.lst {menu}", str(fs)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        checks.append(("menu.lst kernel cmdline has no_timer_check",
                       menu.read_bytes().count(b"no_timer_check") >= 2))
    return checks


def build_bootfs() -> bytes:
    """Build and verify the boot area (MBR + embedded stage1_5 + hda1 ext2)."""
    require_tools()
    files = read_sources()
    for name in ("e2fs_stage1_5", "stage2"):
        files[name] = patch_zd_part_sector(files[name], name)
    files["stage2"] = patch_stage2_config(files["stage2"])
    files["menu.lst"] = patch_menu_cmdline(verify_menu_lst(files["menu.lst"]))
    boot = assemble(build_mbr(files["stage1"]),
                    build_stage1_5(files["e2fs_stage1_5"]),
                    build_ext2(files))
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
