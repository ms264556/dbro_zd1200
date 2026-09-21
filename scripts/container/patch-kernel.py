#!/usr/bin/env python3
"""Patch the ZD1200 2.6.32 kernel for QEMU and rebuild the bzImage.

The stock kernel talks to the appliance's board hardware: a Super-I/O/BMC
register window at I/O ports 0x2e/0x2f (configuration mode is entered by writing
0x87 twice, the chip identifies itself as 0xa0 in register 0x20, and the driver
programs GPIO and device registers behind that), plus board-specific
reset/watchdog registers.  QEMU's '-machine pc' claims none of it - every read
of port 0x2f returns 0xff - so the driver concludes the board controller is
missing and takes the arms it reserves for a broken appliance: halt the box,
pulse the hardware reset line, skip setting up a hardware interface.  Those arms
have to be patched out before boot; each patch below is one of them.

Patches are located by byte signature, not by address: the kernel is relinked
for every release, so the same function moves.  Each patch carries the entry
sequence of the function it targets, with `??` masking bytes that vary between
releases (embedded absolute addresses and relative displacements).  A patch
must match the kernel ELF exactly once; more than one match (ambiguous) is a
hard error, and so is zero matches.

Board data (serial, MACs) is not patched here: it lives in the board-data
records on the CompactFlash image (write-boarddata.py), which the kernel's
v54bsp driver reads at boot.

Vendor bzImage layout:

    [setup + video table + head code][gzip member = the kernel ELF][loader code]

The gzip member does not span the rest of the file: a second-stage loader is
linked after it and the head code jumps to a baked offset inside that loader,
so the tail must not move.  This script locates the member that decompresses
to the 32-bit kernel ELF, patches the ELF, recompresses it (gzip -9, mtime=0)
and splices it back into exactly that region, zero-padding to the original
member length.  The boot decompressor reads a fixed input size, so the new
stream must not exceed the original member length (inflate ignores the padding).

Some releases have no slack in that region at all, so the patched payload
recompresses past it (9.9.1.0.52 does).  For those, the ELF's section header
table and its name strings are zeroed before the last recompression: the boot ELF
loader reads the program headers, and the section metadata is not part of the
loaded image, so the payload compresses smaller.  A release that already fits is
left byte-for-byte alone.
"""

import argparse
import gzip
import re
import struct
import sys
import zlib
from pathlib import Path

# Each patch is (name, signature_hex, patch_offset, patch_hex, description,
# rel32_exit).  signature_hex is matched against the kernel ELF with "??" as a
# wildcard; patch_hex is written at patch_offset inside the match.
# When rel32_exit is non-zero, patch_hex is only the 0xe9 opcode and the
# displacement is computed from the exit jump at match+rel32_exit.
#
# The signatures describe the *stock* bytes.  A site is located with the bytes
# the patch overwrites masked out, so the same signature finds the site in a
# stock kernel and in one this script already patched; the bytes actually present
# then decide whether there is anything to do.  That makes re-running the patcher
# on an already-patched bzImage a no-op instead of a "NOT FOUND" error.
#
# The comment above each entry says what the target does and when it runs, since
# that is what decides whether the patch is still needed after a firmware bump.
PATCHES = [
    # kernel_halt() is the standard "halt this machine" routine (kernel/sys.c):
    # run the shutdown path, print "System halted.", stop the CPU.  The vendor
    # calls it when the board it expects is missing -- the W627 Super-I/O probe
    # (CR20 != 0xa0) and the BIOS/DMI fingerprint guard in nar5520_hwck -- and
    # QEMU provides neither that chip nor the official BIOS.  Overwriting the
    # entry (mov eax,2 -> ret) makes those checks fall through instead of
    # halting the guest, and does not affect shutdown: reboot goes through
    # machine_restart and poweroff through ACPI, neither via kernel_halt.
    ("kernel_halt",
     "b80200000083ec04e8????????e8????????c70424????????e8????????83c404e9????????",
     0, bytes.fromhex("c3"),
     "kernel_halt(): a failed board-chip probe must not halt the guest", 0),
    # The COB7402 board's hardware reset pulse: for board states 1 and 3 it
    # drives the ICH7 GPIO window (runtime I/O base +0x2a set to 0x40 with a poll
    # of bit 6, then +0x38 pulsed with the port-0x61 handshake).  QEMU provides
    # none of that window, and the BSP reaches the routine through a pointer
    # rather than calling it, so return 0 and let QEMU do reset and termination.
    ("cob7402_reset_watchdog",
     "5383ec08e8????????83f801741283f803",
     0, bytes.fromhex("31c0c3"),
     "COB7402 board reset/watchdog routine -> no-op", 0),
    # This patch exists ONLY to remove an older, buggy patch: a vendor kernel
    # does not need it.  `eb 0a` rewrites the u-watchdog timeout block so it runs
    # again (v54_on_reboot(REBOOT_WATCHDOG) + write_kflags('9')), undoing the
    # older broad skip that lost GRUB's spare-image fallback.  On a stock kernel
    # it only quiets the log line.
    ("wdt_timeout_marker",
     "31c083c4185b5e5fc3" + "??" * 7
     + "e8????????b801000000e8????????b8????????e8????????e9????????",
     9, bytes.fromhex("eb0a"),
     "nar5520_wdt_thread(): undo the older broad skip of the timeout block", 0),
]


def find_elf_member(data: bytes):
    """Return (member_start, member_end, payload) for the gzip member inside
    `data` that decompresses to the 32-bit kernel ELF.

    member_end is found by locating the gzip trailer (crc32 + ISIZE of the
    decompressed ELF) and confirming that region decompresses cleanly.
    """
    magic = b"\x1f\x8b\x08"
    start = 0
    while True:
        i = data.find(magic, start)
        if i < 0:
            break
        try:
            payload = zlib.decompress(data[i:], 16 + zlib.MAX_WBITS)
        except zlib.error:
            start = i + 1
            continue
        if not (payload.startswith(b"\x7fELF") and payload[4:5] == b"\x01"):
            start = i + 1
            continue
        # Locate this stream's trailer (it may not be at EOF: a second-stage
        # boot loader is linked after the member).
        pat = struct.pack("<II", zlib.crc32(payload) & 0xffffffff,
                          len(payload) & 0xffffffff)
        hit = data.find(pat, i + 10, i + len(data))
        if hit < 0:
            raise SystemExit(f"gzip member at 0x{i:x} decompresses to an ELF "
                             "but its trailer was not found")
        end = hit + 8
        # The region the boot decompressor reads extends past this gzip stream to
        # the second-stage loader: the member is written zero-padded to the
        # region length, so a stream can be shorter than the space it occupies.
        # Fold that trailing zero padding back into the region -- it is the
        # headroom available before the loader.  Padding is written back as
        # zeros, so even a loader that begins with zeros cannot be overwritten.
        while end < len(data) and data[end] == 0:
            end += 1
        try:
            again = zlib.decompress(data[i:end], 16 + zlib.MAX_WBITS)
        except zlib.error:
            raise SystemExit(f"trailer at 0x{hit:x} does not delimit the member")
        assert again == payload
        return i, end, payload
    raise SystemExit("no gzip member inside the bzImage decompresses to a 32-bit ELF")


def encode_member(elf: bytes, member_len: int):
    """Return (member, used_fallback) for the smallest gzip member we can make.

    gzip -9 does not always produce the smallest encoding for a payload that
    differs by a few bytes, and a member inherited from an already-patched kernel
    is already close to its budget, so other zlib strategies are tried while the
    result does not fit.  Any valid gzip stream is acceptable: the boot inflate
    does not care which encoder produced it.
    """
    best = gzip.compress(elf, compresslevel=9, mtime=0)
    fallback = False
    for strategy in (zlib.Z_FILTERED, zlib.Z_RLE, zlib.Z_HUFFMAN_ONLY,
                     zlib.Z_FIXED, zlib.Z_DEFAULT_STRATEGY):
        if len(best) <= member_len:
            break
        for level in (9, 8, 7, 6):
            engine = zlib.compressobj(level, zlib.DEFLATED, 16 + zlib.MAX_WBITS,
                                      zlib.DEF_MEM_LEVEL, strategy)
            candidate = engine.compress(elf) + engine.flush()
            if len(candidate) < len(best):
                best = candidate
                fallback = True
            if len(best) <= member_len:
                break
    return best, fallback


def shrink_payload(elf: bytes):
    """Reclaim compression headroom from ELF metadata the boot path never reads.

    Returns (payload, description); the description is empty when the ELF offers
    nothing to zero.
    """
    e_shoff = struct.unpack_from("<I", elf, 32)[0]
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", elf, 46)
    if not e_shoff or not e_shnum or not e_shentsize:
        return elf, ""
    table_end = e_shoff + e_shnum * e_shentsize
    if table_end > len(elf):
        return elf, ""
    out = bytearray(elf)
    reclaimed = []
    if e_shstrndx < e_shnum:
        sh = e_shoff + e_shstrndx * e_shentsize
        str_off, str_size = struct.unpack_from("<II", out, sh + 16)
        if str_size and str_off + str_size <= len(out):
            out[str_off:str_off + str_size] = b"\x00" * str_size
            reclaimed.append(f"the {str_size}-byte section-name strings")
    out[e_shoff:table_end] = b"\x00" * (table_end - e_shoff)
    reclaimed.append(f"the {table_end - e_shoff}-byte section header table")
    return bytes(out), "zeroed " + " and ".join(reclaimed)


def off_to_va(data: bytes, off: int) -> int:
    """Map a file offset in the ELF payload back to a kernel virtual address
    via the ELF32 PT_LOAD segments (for reporting)."""
    e_phoff = struct.unpack_from("<I", data, 28)[0]
    e_phentsize = struct.unpack_from("<H", data, 42)[0]
    e_phnum = struct.unpack_from("<H", data, 44)[0]
    for i in range(e_phnum):
        o = e_phoff + i * e_phentsize
        p_type, p_offset = struct.unpack_from("<II", data, o)
        p_vaddr = struct.unpack_from("<I", data, o + 8)[0]
        p_filesz = struct.unpack_from("<I", data, o + 16)[0]
        if p_type == 1 and p_offset <= off < p_offset + p_filesz:
            return p_vaddr + (off - p_offset)
    raise SystemExit(f"file offset 0x{off:x} is not in any PT_LOAD segment")


def find_signature(payload: bytes, sig_hex: str):
    """Return all file offsets in `payload` matching the hex signature, where
    "??" masks a byte."""
    rx = re.compile(b"".join(
        (b"." if sig_hex[j:j + 2] == "??"
         else re.escape(bytes([int(sig_hex[j:j + 2], 16)])))
        for j in range(0, len(sig_hex), 2)), re.DOTALL)
    return [m.start() for m in rx.finditer(payload)]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--in", dest="bzimage", default="image/bzImage",
                    help="stock bzImage (default image/bzImage)")
    ap.add_argument("--out", dest="out", default="image/bzImage.patched",
                    help="output patched bzImage (default image/bzImage.patched)")
    ap.add_argument("--vmlinux", default="image/vmlinux",
                    help="pristine kernel ELF for an optional cross-check "
                         "(default image/vmlinux; informational when patching "
                         "a release other than the one it came from)")
    args = ap.parse_args()

    bz = Path(args.bzimage).read_bytes()
    member_start, member_end, payload = find_elf_member(bz)
    member_len = member_end - member_start
    print(f"kernel ELF gzip member: file bytes {member_start}..{member_end} "
          f"(stream {member_len} bytes, decompressed {len(payload)} bytes)")

    # Optional cross-check against a pristine vmlinux; informational only.
    vmlinux = Path(args.vmlinux)
    if vmlinux.exists():
        want = vmlinux.read_bytes()
        if want == payload:
            print(f"payload matches {args.vmlinux}")
        else:
            print(f"note: payload differs from {args.vmlinux} "
                  "(different release? continuing with signatures)")

    elf = bytearray(payload)
    missing = []
    for name, sig_hex, patch_off, patch, desc, rel32_exit in PATCHES:
        # Locate the site with the bytes the patch overwrites masked out: that
        # matches whether or not the patch has already been applied.
        written = 5 if rel32_exit else len(patch)
        locator = (sig_hex[:patch_off * 2]
                   + "??" * written
                   + sig_hex[(patch_off + written) * 2:])
        hits = find_signature(bytes(elf), locator)
        if len(hits) == 0:
            print(f"  {name:22s}: NOT FOUND - release lacks this function")
            missing.append(name)
            continue
        if len(hits) > 1:
            raise SystemExit(f"signature for {name} matched {len(hits)} places; "
                             "refusing to patch (ambiguous)")
        sig_start = hits[0]
        fo = sig_start + patch_off
        va = off_to_va(bytes(elf), fo)
        if rel32_exit:
            # Re-target the jump to the exit of the block being skipped, whose
            # displacement is read from the exit jump inside the match.
            # Both sites are in one PT_LOAD segment, so file offsets and VAs
            # share a delta.
            exit_rel32 = struct.unpack_from("<i", bytes(elf),
                                            sig_start + rel32_exit + 1)[0]
            target = (sig_start + rel32_exit + 5 + exit_rel32) & 0xffffffff
            disp = (target - (fo + 5)) & 0xffffffff
            patch = b"\xe9" + struct.pack("<I", disp)
        original = bytes(elf[fo:fo + len(patch)])
        if original == patch:
            print(f"  {name:22s}: already patched at {va:#x} (offset 0x{fo:x})")
        else:
            print(f"  {name:22s}: {original.hex()} -> {patch.hex()} at {va:#x} "
                  f"(offset 0x{fo:x})")
            elf[fo:fo + len(patch)] = patch

    if missing:
        raise SystemExit(f"missing patches for this release: {', '.join(missing)}")

    # Recompress into the member region's existing length: the boot decompressor
    # reads a fixed input size, so the stream must not spill into the second-stage
    # loader that follows.  Inflate stops at the trailer, so the region is
    # zero-padded after the stream.
    new_member, fallback = encode_member(bytes(elf), member_len)
    if fallback:
        print(f"note: gzip -9 did not fit the {member_len}-byte member; "
              f"an alternative encoding brings it to {len(new_member)} bytes")
    if len(new_member) > member_len:
        # Last resort: the section metadata is not part of the loaded image.
        trimmed, note = shrink_payload(bytes(elf))
        if note:
            elf = bytearray(trimmed)
            before = len(new_member)
            new_member, _ = encode_member(bytes(elf), member_len)
            print(f"note: {note} to fit the member "
                  f"({before} -> {len(new_member)} bytes)")
    if len(new_member) > member_len:
        raise SystemExit(f"patched payload recompresses to {len(new_member)} bytes, "
                         f"larger than the original member ({member_len})")
    new_member = new_member + b"\x00" * (member_len - len(new_member))

    # Replace only the member region; the loader tail must stay in place.
    out = bz[:member_start] + new_member + bz[member_end:]
    Path(args.out).write_bytes(out)
    print(f"wrote {args.out} ({len(out)} bytes, member region kept at {member_len} bytes)")

    import hashlib
    print("sha256:", hashlib.sha256(out).hexdigest())


if __name__ == "__main__":
    sys.exit(main())
