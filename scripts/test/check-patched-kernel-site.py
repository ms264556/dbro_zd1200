#!/usr/bin/env python3
"""Assert the installed addrconf_dev_config patch sites in a patched bzImage.

Used by patch-kernel-fixture-test.sh.  It reads the *output* bzImage the way
patch-kernel.py does -- find the gzip member that decompresses to the 32-bit
kernel ELF, locate the patch sites in it -- and checks the bytes that the
entries must have written and where their branches land.

This is deliberately independent of the patcher's own reporting: the patcher
printing "-> 8b4c240c..." only proves what it thinks it wrote.  This reads the
bytes back out of the artifact.

The group-B check is anchored to the address the enclosing flow reaches
(match+0x14, the ASSERT_RTNL call), not to the signature's match start: an entry
that writes at the match start is unreachable and corrupts the enclosing
function, and only a check stated in terms of the branch and the anchor can see
that.  The enclosing branch's target is decoded out of the pristine kernel, so
the check does not assume the fixture's layout.

Exit status: 0 and a `site=... ` line on success; 1 otherwise, with a diagnostic
on stdout.

Usage:
  check-patched-kernel-site.py --group-b <patcher.py> <patched.bzImage> \
      <pristine.vmlinux> <expected-site-hex> <enclosing-branch-file-offset>
  check-patched-kernel-site.py --group-a <patcher.py> <patched.bzImage> \
      <pristine.vmlinux> <expected-site-hex>
"""

from __future__ import annotations

import importlib.util
import struct
import sys
from pathlib import Path

ENTRY = "addrconf_dev_config_dhcp0_inlined"

# The group-B geometry, in offsets from the signature's match start.
ANCHOR = 0x14          # the ASSERT_RTNL call: where the enclosing branch lands
MOVZX = "0fb781dc000000"   # the 7-byte device-type load, which must stay stock
MOVZX_OFF = ANCHOR + 0x14  # = 0x28 from the match
STOCK_TAIL = 44        # bytes of stock ARPHRD dispatch after the window
EPILOGUE = -0x6FD      # from the match: the `mov eax,edx` the jump enters
WRITE = 20             # the replacement's width: it must end at the movzx


def load_patcher(path: str):
    spec = importlib.util.spec_from_file_location("patch_kernel_under_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _exec_seg(elf: bytes, off: int):
    """(offset, vaddr, filesz) of the executable PT_LOAD containing `off`."""
    e_phoff = struct.unpack_from("<I", elf, 28)[0]
    e_phentsize = struct.unpack_from("<H", elf, 42)[0]
    e_phnum = struct.unpack_from("<H", elf, 44)[0]
    for i in range(e_phnum):
        o = e_phoff + i * e_phentsize
        p_type, p_offset = struct.unpack_from("<II", elf, o)
        p_filesz = struct.unpack_from("<I", elf, o + 16)[0]
        p_flags = struct.unpack_from("<I", elf, o + 24)[0]
        if p_type == 1 and (p_flags & 1) and p_offset <= off < p_offset + p_filesz:
            return p_offset, p_filesz
    raise SystemExit(f"no executable segment contains file offset 0x{off:x}")


def _rel32_branches(payload: bytes, src_lo: int, src_hi: int, pred):
    """Direct near branches in [src_lo, src_hi) whose target satisfies `pred`.

    Reads the two encodings the enclosing kernel code uses -- `0f 8x rel32` and
    `e9 rel32` -- at every source offset.  Byte-wise scanning finds encodings
    that are not at an instruction boundary too, which makes the "no other
    entry" assertion below conservative: a spurious hit is a failure, never a
    silent pass.
    """
    seg_off, seg_len = _exec_seg(payload, src_lo)
    end = min(src_hi, seg_off + seg_len - 5)
    hits = []
    for i in range(src_lo, end):
        b0, b1 = payload[i], payload[i + 1]
        if b0 == 0x0F and 0x80 <= b1 <= 0x8F:
            t = i + 6 + struct.unpack_from("<i", payload, i + 2)[0]
        elif b0 == 0xE9:
            t = i + 5 + struct.unpack_from("<i", payload, i + 1)[0]
        else:
            continue
        if pred(t):
            hits.append((i, t))
    return hits


def check_group_b(patcher_path: str, bzimage: str, pristine: str,
                  expected: str, branch_off: int) -> int:
    pk = load_patcher(patcher_path)
    try:
        out = pk.find_elf_member(Path(bzimage).read_bytes())[2]
    except SystemExit as exc:
        print(f"not a patched kernel image: {exc}")
        return 1
    before = Path(pristine).read_bytes()
    want = bytes.fromhex(expected)

    def site_of(payload):
        return next((s for s in pk.locate_sites(payload)[0]
                     if s.name == ENTRY and s.hits), None)

    s_out, s_pre = site_of(out), site_of(before)
    if s_out is None:
        print(f"no site for {ENTRY} in {bzimage} "
              "(its signature does not match the installed payload)")
        return 1
    if s_pre is None:
        print(f"the pristine image has no {ENTRY} site to compare against")
        return 1
    m = s_pre.hits[0]
    if s_out.hits[0] != m:
        print(f"the signature's match moved from 0x{m:x} to 0x{s_out.hits[0]:x}")
        return 1
    if s_out.patch_off != ANCHOR:
        print(f"the group-B entry writes at match+{s_out.patch_off:#x}, not at the "
              f"anchor match+{ANCHOR:#x}: its bytes would not be the code the "
              "enclosing flow reaches")
        return 1
    if s_out.write_width != WRITE:
        print(f"the group-B write width is {s_out.write_width}, expected {WRITE}")
        return 1
    anchor = m + ANCHOR

    # (a) The anchor is the address control reaches: decode the branch that
    # enters it out of the pristine kernel, rather than believing the layout.
    if not (before[branch_off] == 0x0F and 0x80 <= before[branch_off + 1] <= 0x8F):
        print(f"no near conditional branch at 0x{branch_off:x} (found "
              f"{before[branch_off:branch_off + 2].hex()})")
        return 1
    branch_target = (branch_off + 6
                     + struct.unpack_from("<i", before, branch_off + 2)[0])
    if branch_target != anchor:
        print(f"the enclosing branch at 0x{branch_off:x} lands at 0x{branch_target:x}, "
              f"not on the anchor 0x{anchor:x}")
        return 1

    # (b) ... and the anchor is an instruction boundary, not the middle of an
    # instruction: the `jne` at match-0x02 ends exactly at match+0x04, and the
    # live fall-through from there is four whole instructions ending exactly at
    # the anchor.  This is the property the old geometry got wrong.
    if before[m - 2:m] != b"\x0f\x85":
        print(f"no `jne` ending at match+0x04 (match-0x02 is "
              f"{before[m - 2:m].hex()})")
        return 1
    run = ((m + 0x04, b"\x8b\x44\x24\x18"),      # mov eax,[esp+0x18]
           (m + 0x08, b"\x89\xda"),              # mov edx,ebx
           (m + 0x0A, b"\xe8"),                  # call rel32
           (m + 0x0F, b"\xe9"))                  # jmp rel32
    lengths = (4, 2, 5, 5)
    at = m + 0x04
    for (off, opcode), length in zip(run, lengths):
        if before[off:off + len(opcode)] != opcode:
            print(f"the live code at match+{off - m:#x} is not "
                  f"{opcode.hex()} (found {before[off:off + len(opcode)].hex()})")
            return 1
        at += length
    if at != anchor:
        print(f"the enclosing run ends at 0x{at:x}, not at the anchor 0x{anchor:x}: "
              "the write would not start on an instruction boundary")
        return 1

    # (c) The stock WARN block the window's `je` enters, and the back-jump into
    # the window that makes overwriting match+0x24 safe only while it is dead.
    stock_je = anchor + 0x0A
    if before[stock_je:stock_je + 2] != b"\x0f\x84":
        print(f"no stock `je` at the anchor+0x0a (found "
              f"{before[stock_je:stock_je + 2].hex()})")
        return 1
    warn = stock_je + 6 + struct.unpack_from("<i", before, stock_je + 2)[0]
    back = _rel32_branches(before, warn, warn + 0x40,
                           lambda t: t == anchor + 0x10)
    if not back:
        print(f"the block at 0x{warn:x} does not end in a jump back to the "
              f"window (anchor+0x10 = 0x{anchor + 0x10:x})")
        return 1
    warn_end = back[0][0] + 5
    seg_off, seg_len = _exec_seg(before, m)
    entries = _rel32_branches(before, seg_off, seg_off + seg_len,
                              lambda t: warn <= t < warn_end)
    if [i for i, _ in entries] != [stock_je]:
        print(f"the WARN block [0x{warn:x},0x{warn_end:x}) is entered from "
              f"{[hex(i) for i, _ in entries]}, not only from the stock `je` at "
              f"0x{stock_je:x}: removing that `je` would leave a live branch into "
              "the middle of the replacement")
        return 1

    # (d) The window now carries the replacement, and only the replacement.
    blob = out[anchor:anchor + len(want)]
    if blob != want:
        print(f"the bytes at the anchor 0x{anchor:x} are {blob.hex()}, expected "
              f"{expected}: the replacement does not run where control reaches")
        return 1
    if before[anchor:anchor + len(want)] == want:
        print("the pristine kernel already carries the replacement; the check "
              "cannot tell what the patcher wrote")
        return 1

    # (e) The device-type load and the stock ARPHRD dispatch behind it are
    # byte-for-byte stock, so a non-dhcp0 device behaves exactly as before.
    if out[m + MOVZX_OFF:m + MOVZX_OFF + 7].hex() != MOVZX:
        print(f"the movzx at match+{MOVZX_OFF:#x} is "
              f"{out[m + MOVZX_OFF:m + MOVZX_OFF + 7].hex()}, expected {MOVZX}: "
              "the device-type load was clobbered")
        return 1
    after = (m + MOVZX_OFF, m + MOVZX_OFF + STOCK_TAIL)
    if out[after[0]:after[1]] != before[after[0]:after[1]]:
        print(f"the stock ARPHRD dispatch at match+{MOVZX_OFF:#x}.."
              f"+{after[1] - m:#x} is not the pristine kernel's")
        return 1

    # (f) The replacement's own branches: every device other than dhcp0 must
    # reach the stock movzx, and dhcp0 must leave for the epilogue.
    if out[anchor + 0x0A] != 0x75:
        print(f"no `jne` at the anchor+0x0a (found {out[anchor + 0x0A]:#x})")
        return 1
    jne = anchor + 0x0C + struct.unpack_from("<b", out, anchor + 0x0B)[0]
    if jne != anchor + MOVZX_OFF - ANCHOR:
        print(f"the replacement's jne lands at 0x{jne:x}, not on the stock movzx "
              f"0x{anchor + MOVZX_OFF - ANCHOR:x}")
        return 1
    if out[anchor + 0x0C:anchor + 0x0F] != b"\x90" * 3:
        print("dhcp0's fall-through to the exit jump is not a run of nops: "
              f"{out[anchor + 0x0C:anchor + 0x0F].hex()}")
        return 1
    if out[anchor + 0x0F] != 0xE9:
        print(f"no jump at the anchor+0x0f (found {out[anchor + 0x0F]:#x}); dhcp0 "
              "must leave without configuring anything")
        return 1
    jmp_target = (anchor + 0x14
                  + struct.unpack_from("<i", out, anchor + 0x10)[0])
    if jmp_target != m + EPILOGUE:
        print(f"dhcp0's jump lands at 0x{jmp_target:x}, expected 0x{m + EPILOGUE:x} "
              f"(match{EPILOGUE:#x}, the epilogue's `mov eax,edx`)")
        return 1
    if before[m + EPILOGUE - 5:m + EPILOGUE] != b"\xba\x01\x00\x00\x00":
        print(f"match{EPILOGUE - 5:#x} is not `mov edx,1`, so match{EPILOGUE:#x} is "
              "not the epilogue entry the jump is documented to skip")
        return 1
    if out[m + EPILOGUE:m + EPILOGUE + 2] != b"\x89\xd0":
        print(f"the jump target is {out[m + EPILOGUE:m + EPILOGUE + 2].hex()}, "
              "not `mov eax,edx`")
        return 1

    # (g) The device-pointer load is present: the entry does not assume ecx
    # still holds the device across the call it replaced.
    if out[anchor:anchor + 4] != b"\x8b\x4c\x24\x0c":
        print(f"the replacement does not load the device pointer "
              f"(anchor bytes {out[anchor:anchor + 4].hex()})")
        return 1

    # (h) The enclosing function's live code is untouched: the old entry wrote
    # over it, the corrected one must not.
    if out[m:m + ANCHOR] != before[m:m + ANCHOR]:
        print(f"the live code at match..match+{ANCHOR:#x} was overwritten: "
              f"{before[m:m + ANCHOR].hex()} -> {out[m:m + ANCHOR].hex()}")
        return 1

    print(f"site={blob.hex()} anchor=match+{ANCHOR:#x} "
          f"entered_by=0x{branch_off:x} jne=match+{MOVZX_OFF:#x} "
          f"jmp=0x{jmp_target:x} movzx=match+{MOVZX_OFF:#x} stock "
          f"warn=0x{warn:x}(dead) live=match..match+{ANCHOR:#x} stock")
    return 0


ENTRY_A = "addrconf_dev_config_dhcp0"

# The 7 bytes of `movzx eax,[ebx+0xdc]` the group-A patch must leave intact, and
# the offsets the layout depends on.
MOVZX_A = "0fb783dc000000"
A_MOVZX_OFF = 0x0D
A_EPILOGUE_OFF = 0x33
A_WRITE = 13


def check_group_a(patcher_path: str, bzimage: str, pristine: str, expected: str) -> int:
    """The group-A shape: the name test, then two paths, over 13 bytes.

    Asserts what the 20-byte version got wrong: the `movzx` that loads the
    device type survives, so the ARPHRD dispatch runs on the real type rather
    than on whatever the ASSERT_RTNL helper left in eax.
    """
    pk = load_patcher(patcher_path)
    try:
        out = pk.find_elf_member(Path(bzimage).read_bytes())[2]
    except SystemExit as exc:
        print(f"not a patched kernel image: {exc}")
        return 1
    before = Path(pristine).read_bytes()

    site = next((s for s in pk.locate_sites(out)[0]
                 if s.name == ENTRY_A and s.hits), None)
    if site is None:
        print(f"no site for {ENTRY_A} in {bzimage}")
        return 1
    start = site.hits[0]
    blob = out[start:start + len(expected) // 2]
    if blob.hex() != expected:
        print(f"site bytes are {blob.hex()}, expected {expected}")
        return 1
    if site.write_width != A_WRITE:
        print(f"the group-A mask width is {site.write_width}, expected {A_WRITE}: "
              "a wider write clobbers the movzx")
        return 1

    # (b)+(d): the movzx is untouched, and it is the instruction a non-dhcp0
    # device reaches, so the dispatch sees dev->type.
    if out[start + A_MOVZX_OFF:start + A_MOVZX_OFF + 7].hex() != MOVZX_A:
        print(f"the movzx at site+{A_MOVZX_OFF:#x} is "
              f"{out[start + A_MOVZX_OFF:start + A_MOVZX_OFF + 7].hex()}, "
              f"expected {MOVZX_A}: the device-type load was clobbered")
        return 1
    jne = start + 0x06 + 2 + out[start + 0x07]
    if jne - start != A_MOVZX_OFF:
        print(f"the jne lands at site+{jne - start:#x}, expected "
              f"+{A_MOVZX_OFF:#x} (the movzx)")
        return 1
    # (c): dhcp0 falls through the not-taken jne into the jmp and leaves.
    jmp_at = 0x08
    if blob[jmp_at] != 0xE9:
        print(f"no jump at site+{jmp_at:#x} (found {blob[jmp_at]:#x}); dhcp0 "
              "must leave for the epilogue")
        return 1
    target = (start + jmp_at + 5
              + struct.unpack_from("<i", out, start + jmp_at + 1)[0])
    if target - start != A_EPILOGUE_OFF:
        print(f"the fall-through jump lands at site+{target - start:#x}, "
              f"expected +{A_EPILOGUE_OFF:#x} (the epilogue)")
        return 1
    # The epilogue must be the one the pristine kernel carries, located there by
    # the inlined signature's geometry rather than assumed.
    pre_site = next((s for s in pk.locate_sites(before)[0]
                     if s.name == ENTRY_A and s.hits), None)
    if pre_site is None:
        print(f"the pristine image has no {ENTRY_A} site to compare against")
        return 1
    p0 = pre_site.hits[0]
    if out[start + A_EPILOGUE_OFF:start + A_EPILOGUE_OFF + 8] != \
            before[p0 + A_EPILOGUE_OFF:p0 + A_EPILOGUE_OFF + 8]:
        print("the epilogue is not the pristine kernel's")
        return 1
    print(f"site={blob.hex()} jne=+{jne - start:#x} jmp=+{target - start:#x} "
          f"movzx=+{A_MOVZX_OFF:#x}")
    return 0


def main() -> int:
    args = sys.argv[1:]
    if args and args[0] == "--group-a":
        if len(args) != 5:
            print("usage: check-patched-kernel-site.py --group-a <patcher.py> "
                  "<patched.bzImage> <pristine.vmlinux> <expected-site-hex>",
                  file=sys.stderr)
            return 2
        return check_group_a(args[1], args[2], args[3], args[4].lower())
    if args and args[0] == "--group-b":
        args = args[1:]
    if len(args) != 5:
        print("usage: check-patched-kernel-site.py --group-b <patcher.py> "
              "<patched.bzImage> <pristine.vmlinux> <expected-site-hex> "
              "<enclosing-branch-file-offset>", file=sys.stderr)
        return 2
    try:
        branch_off = int(args[4], 0)
    except ValueError:
        print(f"not a file offset: {args[4]!r}", file=sys.stderr)
        return 2
    return check_group_b(args[0], args[1], args[2], args[3].lower(), branch_off)


if __name__ == "__main__":
    sys.exit(main())
