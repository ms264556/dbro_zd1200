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
must match the kernel ELF exactly once; zero matches (the release lacks the
function) or more than one (ambiguous) is a hard error.

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
"""

import argparse
import gzip
import re
import struct
import sys
import zlib
from pathlib import Path

# Each patch is (name, signature_hex, patch_offset, patch_hex, description,
# rel32_exit).  signature_hex is matched against the unpatched kernel ELF with
# "??" as a wildcard; patch_hex is written at patch_offset inside the match.
# When rel32_exit is non-zero, patch_hex is only the 0xe9 opcode and the
# displacement is computed from the exit jump at match+rel32_exit.
#
# The signatures describe the *stock* bytes, so they match a vendor kernel only:
# re-running this against an already patched bzImage reports every site as NOT
# FOUND.  (To locate a site in a patched image, mask the bytes patch_hex
# overwrites, as the board_data_retry comment notes.)
#
# The comment above each entry says what the target does and when it runs, since
# that is what decides whether the patch is still needed after a firmware bump.
PATCHES = [
    # kernel_halt() is the vendor's "halt the appliance" routine, exported under
    # that name: it stores a halt state, walks the reboot-notifier list and
    # prints "<0>System halted." before tail-calling the platform halt hook.
    # Most of its call sites are the failure arm of the board chip probe -
    #     out 0x2e,0x87 twice / out 0x2e,0x20 / in 0x2f / cmp al,0xa0 / call kernel_halt
    # plus a couple in .init.text - so under QEMU, where that probe always reads
    # 0xff, the guest would halt during early init.  (It dies of "BUG: scheduling
    # while atomic" first: the halt path schedules while the driver still holds
    # its board lock.)  Overwriting the entry (mov eax,2 -> ret) makes a failed
    # probe fall through to the driver's "chip absent" continuation instead.
    ("kernel_halt",
     "b80200000083ec04e8????????e8????????c70424????????e8????????83c404e9????????",
     0, bytes.fromhex("c3"),
     "kernel_halt(): a failed board-chip probe must not halt the guest", 0),
    # rks_pkt_trace_init() is the init-time hook that creates the Ruckus "tif0"
    # packet-trace/fastpath interface; it logs "<3>%s failed to create tif0." or
    # "<3>%s create tif0 successfully."  Returning 0 straight away leaves the
    # interface uncreated, which is what the emulated box wants.
    ("rks_pkt_trace_init",
     "83ec08e8????????85c0741fc7442404????????c70424????????e8????????e8????????31c083c408c3",
     0, bytes.fromhex("31c0c3"),
     "rks_pkt_trace_init(): do not create the tif0 interface", 0),
    # The COB7402 board's physical reset/watchdog routine.  It reads the board
    # state and, for states 1 and 3, drives the board's device window - a runtime
    # I/O base: +0x2a gets 0x40 with a poll of bit 6, +0x38 gets a reset pulse
    # with the port-0x61 handshake.  It has no direct callers (the BSP reaches it
    # through a pointer), and none of that window exists under QEMU, so make it a
    # no-op that returns 0 and let QEMU supervise reset/termination.
    ("cob7402_reset_watchdog",
     "5383ec08e8????????83f801741283f803",
     0, bytes.fromhex("31c0c3"),
     "COB7402 board reset/watchdog routine -> no-op", 0),
    # The "u-watchdog timeout" block inside nar5520_wdt_thread().  The thread
    # runs the block whenever a per-loop `jle` finds the driver's u-watchdog
    # counter (a plain .data counter, re-armed to 0x7a by the driver's own kick
    # entry points) expired: on a real appliance that means nothing kicked it in
    # time and the board data is about to be refreshed to the CF card.  Under
    # QEMU nothing kicks it, so the counter sits at or below zero for the whole
    # run and, unpatched, every loop iteration prints "warning: u-watchdog
    # timeout, system may reboot", calls through the driver's function-pointer
    # hook with 1, and calls the CF-card board-data helper for device "9" -
    # roughly 22 log entries a second, and all of it invisible on the console
    # because GRUB boots with "quiet" and the message is a bare printk (level 4).
    # patch_offset 9 is the block's first instruction (mov dword [esp],<warning
    # string>); rewriting it as a jmp to the target of the block's own exit jump
    # (hence rel32_exit) skips the warning and both calls.
    ("board_data_retry",
     "31c083c4185b5e5fc3c70424????????e8????????b801000000e8????????b8????????e8????????e9????????",
     9, bytes.fromhex("e9"),
     "nar5520_wdt_thread(): skip the u-watchdog timeout retry block", 41),
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
        try:
            again = zlib.decompress(data[i:end], 16 + zlib.MAX_WBITS)
        except zlib.error:
            raise SystemExit(f"trailer at 0x{hit:x} does not delimit the member")
        assert again == payload
        return i, end, payload
    raise SystemExit("no gzip member inside the bzImage decompresses to a 32-bit ELF")


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
        for j in range(0, len(sig_hex), 2)))
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
        hits = find_signature(bytes(elf), sig_hex)
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
            # displacement is read from the exit jump inside the signature.
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

    # Recompress; keep the member region the same length (inflate stops at the
    # trailer, so zero padding after it is harmless).
    new_member = gzip.compress(bytes(elf), compresslevel=9, mtime=0)
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
