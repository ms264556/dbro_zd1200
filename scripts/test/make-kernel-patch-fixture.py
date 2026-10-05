#!/usr/bin/env python3
"""Build a tiny synthetic kernel (vmlinux + bzImage) for the patcher's own tests.

This is a test fixture, not an installer input: it carries no firmware and only
as much code as `patch-kernel.py` needs in order to decide what to do.  It
exists because the property under test is a *patcher contract* -- "every
supported release gets the crash fix, and this one is the shape that used to be
missed" -- and that has to be checkable with no vendor material at all.

It synthesises a 32-bit ELF with one PT_LOAD at 0xc1000000 (file 0x1000) holding
exactly the sites the patcher looks for:

  * `kernel_halt`             `mov eax,2` then the shutdown path's two calls,
  * `cob7402_reset_watchdog`  the 3-byte entry and its `cmp eax,1` / `cmp eax,3`,
  * `wdt_timeout_marker`      the u-watchdog timeout block,
  * the **inlined** (group-B) `addrconf_dev_config` block, and
  * `tsc_read_refs_threshold` the 16-byte SMI-threshold compare in tsc_read_refs()
    (`cmp ecx,0xc34f; ja`) at the real kernel's file offset 0x9ECA (code 0x8ECA).

The inlined block is built at the geometry the five real inlined releases have,
because the previous fixture did not: it laid 20 inert filler bytes in front of
the ASSERT_RTNL call and let the test treat those filler bytes as "the patched
window".  The real kernel has live code there and the ASSERT block 0x14 bytes
further on, so a patch written at the match start (as the old entry was) is
unreachable and corrupts the enclosing function -- and the old fixture could not
see either.  This one therefore models the enclosing `addrconf_notify()` flow:

  * the match starts two bytes into a `jne`'s rel32, exactly as in the real
    kernel, so match+0x00..+0x03 are displacement bytes and match+0x04 is the
    `jne`'s live fall-through target (`mov eax,[esp+0x18]`; `mov edx,ebx`; a
    call; a jmp) -- the code the old entry used to overwrite;
  * match+0x14 is the ASSERT_RTNL call, the address the enclosing flow reaches:
    a real `je <anchor>` in the same enclosing block branches to it, and it is
    the only branch that targets it;
  * the ASSERT-failure WARN block sits at match+0x80, is entered only by the
    stock `je` inside the patched window, and ends by jumping back to
    match+0x24 -- the trap the patcher's window has to keep dead;
  * the stock `movzx eax,[ecx+0xdc]` and the ARPHRD dispatch follow the anchor
    verbatim from the signature, and the inlined function's epilogue
    (`mov edx,1` / `mov eax,edx` / register restore / ret) sits at match-0x702,
    where the patcher's backward jump must land on `mov eax,edx`.

The standalone (group-A) `addrconf_dev_config` block is deliberately absent from
the default shape, so the fixture is exactly the release shape that the old
single signature missed.  That is what makes the committed regression test
discriminate.

Every site is built as the *stock bytes the patch's own signature describes*,
with the signature's masked ("??") bytes taken from this file's FILLER, so a
signature that drifts away from the real kernels stops matching the fixture too.

The bzImage is the vendor layout the patcher documents: [head][gzip member of
the ELF][zero padding][loader tail], with the member region longer than the
stream so the patched payload still recompresses into it.

Neither file is expected to boot; nothing boots it.  Both are deterministic, so
the regression test can pin their sha256 and notice any drift.

Usage: make-kernel-patch-fixture.py <output-dir> [group_b|group_a]
       make-kernel-patch-fixture.py --anchor-offset
       make-kernel-patch-fixture.py --enclosing-branch-offset
       make-kernel-patch-fixture.py --warn-block-offset
       make-kernel-patch-fixture.py --epilogue-offset
"""

from __future__ import annotations

import gzip
import struct
import sys
from pathlib import Path

# File layout of the ELF.
HEAD = 0x1000                  # PT_LOAD file offset
VADDR = 0xC1000000             # PT_LOAD virtual address
CODE_SIZE = 0x40000            # PT_LOAD file/mem size -> 266240-byte file
ELF_HEADER_SIZE = 52
PHDR_SIZE = 32
PHDR_OFF = ELF_HEADER_SIZE     # 88, the only phdr

# Where each signature's match starts inside the code region.  They are spread
# out so every signature is unique, and so no patch's overwrite lands inside
# another signature's match.
SIG_AT = {
    "kernel_halt": 0x1000,
    "cob7402": 0x2000,
    "wdt": 0x3000,
    "addrconf_a": 0x4000,
    "addrconf_b": 0x5000,
    # The real kernel's `tsc_read_refs_threshold` signature is at file offset
    # 0x9ECA; HEAD is 0x1000, so the code offset is 0x8ECA.
    "tsc": 0x8ECA,
}

# The byte used for every masked ("??") position, and for padding.  It is never
# executed: those positions are exactly the bytes a patch overwrites, or inert
# padding outside every reachable flow.
FILLER = 0x60

# The group-B geometry, all as offsets relative to the signature match start
# `m`.  These are the offsets the five real inlined kernels have; the test and
# the checker both read them back out of the synthesized artifact.
B_ANCHOR = 0x14       # m+0x14: the ASSERT_RTNL call, the address flow reaches
B_ENCLOSE = -0x80     # the enclosing block's head …
B_BRANCH = -0x39      # … and the `je <anchor>` inside it that enters the site
B_WARN = 0x80         # m+0x80: the ASSERT-failure WARN block (after the anchor)
B_CONT = 0x54         # m+0x54: where the stock ARPHRD switch's `je`s converge
B_SINK = 0x200        # m+0x200: a dead-end block for paths that leave the site
B_EPILOGUE = -0x702   # m-0x702: `mov edx,1`; the patch jumps to +5, `mov eax,edx`
# The 7-byte device-type load the group-B patch must not touch.
B_MOVZX = "0fb781dc000000"
# The stock window the group-B patch replaces, at m+0x14 .. m+0x28.  These are
# the bytes the patcher's own signature pins (rel32 fields wildcarded).
B_STOCK_WINDOW = ("e8" + "????????" + "85c0" + "8d7600" + "0f84" + "????????"
                  + "8b4c240c")
# The live fall-through code in front of the anchor, m+0x04 .. m+0x14.  The old
# entry overwrote this; it is stock in every real kernel and must stay stock.
B_LIVE = "8b442418" + "89da" + "e8" + "????????" + "e9" + "????????"

# The `tsc_read_refs_threshold` signature in patch-kernel.py: the stock bytes of
# `sub ecx,edi; sbb ebx,ebp; cmp ebx,0; ja; cmp ecx,0xc34f; ja`.  Every byte is
# pinned (the write's own four, the imm32, are masked only while locating), so the
# fixture carries them verbatim -- and the patch's site is the 4 bytes at +11.
TSC_REFS = "29f919eb83fb00771581f94fc3000077"


def _call(from_va: int, to_va: int) -> bytes:
    return b"\xe8" + struct.pack("<I", (to_va - (from_va + 5)) & 0xFFFFFFFF)


def _jmp(from_va: int, to_va: int) -> bytes:
    return b"\xe9" + struct.pack("<I", (to_va - (from_va + 5)) & 0xFFFFFFFF)


def _jcc(from_va: int, to_va: int, opcode: int = 0x84) -> bytes:
    """A 6-byte near conditional jump (0f 8x)."""
    return b"\x0f" + bytes([opcode]) + struct.pack(
        "<I", (to_va - (from_va + 6)) & 0xFFFFFFFF)


def _matches(pattern_hex: str, blob: bytes) -> bool:
    """Whether `blob` matches a signature-style hex pattern ("??" wildcards)."""
    if len(blob) != len(pattern_hex) // 2:
        return False
    return all(pattern_hex[i * 2:i * 2 + 2] == "??"
               or blob[i] == int(pattern_hex[i * 2:i * 2 + 2], 16)
               for i in range(len(blob)))


class Block:
    """A byte buffer that knows its own code offset and checks its own layout.

    Every `at()` is an assertion about where the flow is, so a change to one
    instruction cannot silently shift the offsets the geometry depends on.
    """

    def __init__(self, start_off: int):
        self.start = start_off
        self.buf = bytearray()

    @property
    def here(self) -> int:
        return self.start + len(self.buf)

    def la(self) -> int:
        return VADDR + self.here

    def emit(self, blob: bytes) -> None:
        self.buf += blob

    def call(self, target_off: int) -> None:
        self.emit(_call(self.la(), VADDR + target_off))

    def jmp(self, target_off: int) -> None:
        self.emit(_jmp(self.la(), VADDR + target_off))

    def jcc(self, target_off: int, opcode: int = 0x84) -> None:
        self.emit(_jcc(self.la(), VADDR + target_off, opcode))

    def nops_to(self, off: int) -> None:
        self.emit(b"\x90" * (off - self.here))

    def at(self, off: int) -> None:
        assert self.here == off, (
            f"fixture layout drifted: {self.here:#x} != expected {off:#x}")


def kernel_halt_block() -> bytes:
    """The bytes `kernel_halt`'s 38-byte signature describes."""
    va = VADDR + SIG_AT["kernel_halt"]
    return (b"\xb8\x02\x00\x00\x00"                     # mov eax,2  <- patched
            + b"\x83\xec\x04"                           # sub esp,4
            + _call(va + 8, va + 0x100)                 # call <vprintk>
            + _call(va + 13, va + 0x200)                # call <func>
            + b"\xc7\x04\x24" + bytes([FILLER]) * 4     # mov [esp],imm32 ("??")
            + _call(va + 23, va + 0x300)                # call <func>
            + b"\x83\xc4\x04"                           # add esp,4
            + _jmp(va + 28, va + 0x400)                 # jmp  ("????" displ)
            + b"\x90" * 4)


def cob7402_block() -> bytes:
    """The bytes `cob7402_reset_watchdog`'s 23-byte signature describes.

    The signature starts at +0x03 (its needle is `??`x6 + `??` + `08 e8 ?? ?? ??
    ?? 83 f8 01 74 12 83 f8 03`), so the three masked bytes in front are filler.
    """
    va = VADDR + SIG_AT["cob7402"]
    return (bytes([FILLER]) * 3                         # `??`x3 before the entry
            + b"\x53\x83\xec"                           # push ebx; sub esp, (masked)
            + b"\x08"                                   # the 0x08 the signature pins
            + _call(va + 6, va + 0x100)                 # call <board probe>
            + b"\x83\xf8\x01"                           # cmp eax,1
            + b"\x74\x12"                               # je +0x12
            + b"\x83\xf8\x03"                           # cmp eax,3
            + b"\xb8\x00\x00\x00\x00"                   # mov eax,0 (the 0-path)
            + b"\xc3")                                  # ret


def wdt_block() -> bytes:
    """The bytes `wdt_timeout_marker`'s signature describes."""
    va = VADDR + SIG_AT["wdt"]
    return (b"\x31\xc0\x83\xc4\x18\x5b\x5e\x5f\xc3"     # restore + ret
            + bytes([FILLER]) * 7                       # `??`x7 padding
            + _call(va + 16, va + 0x100)                # call <v54_on_reboot>
            + b"\xb8\x01\x00\x00\x00"                   # mov eax,1
            + _call(va + 25, va + 0x200)                # call <write_kflags>
            + b"\xb8" + bytes([FILLER]) * 4             # mov eax,imm32 ("??")
            + _call(va + 34, va + 0x300)                # call <func>
            + _jmp(va + 39, va + 0x400))                # jmp


def tsc_block() -> bytes:
    """The 16 bytes `tsc_read_refs_threshold`'s signature describes, stock."""
    return bytes.fromhex(TSC_REFS)


def addrconf_a_blocks():
    """The standalone (group-A) shape, at the geometry the real kernels have.

    Returns ((code_offset, blob), ...).  `addrconf_dev_config()` is a real
    function here, so the site is 13 bytes into its prologue (the compiler put
    `sub esp,0x2c` / register saves in front of it); the device pointer is in
    ebx.  The 7-byte `movzx eax,[ebx+0xdc]` sits at site+0x0d and the function's
    own epilogue at site+0x33 -- the two offsets the group-A patch depends on.
    """
    site_off = SIG_AT["addrconf_a"]
    site_va = VADDR + site_off
    prologue = b"\x83\xec\x2c" + b"\x89\x5c\x24\x1c" + b"\x89\xc3"
    body = bytearray()
    body += _call(site_va, site_va + 0x500)             # call ASSERT_RTNL
    body += b"\x85\xc0"                                 # test eax,eax
    body += _jcc(site_va + 7, site_va + 0x300)          # je <epilogue>
    body += b"\x0f\xb7\x83\xdc\x00\x00\x00"       # movzx eax,word [ebx+0xdc]
    body += b"\x66\x83\xf8\x01" + b"\x74\x31"       # cmp ax,1 / je
    body += b"\x66\x3d\x06\x03" + b"\x74\x2b"       # cmp ax,0x306 / je
    body += b"\x66\x3d\x20\x03" + b"\x74\x25"       # cmp ax,0x320 / je
    body += b"\x66\x83\xf8\x07" + b"\x90" + b"\x74\x1e"
    body += b"\x66\x83\xf8\x20" + b"\x74\x18"
    body += b"\x8b"                                     # the `8b` the sig ends on
    disp = (site_off + 0x33) - (site_off + 0x0F + 5)     # jmp at +0x0f..+0x13
    body += b"\x90" * ((0x33 - 0x0F) - 5) + b"\xe9" + struct.pack("<i", disp)
    epilogue = (b"\x8b\x5c\x24\x1c"                   # mov ebx,[esp+0x1c]
                + b"\x8b\x74\x24\x20"                   # mov esi,[esp+0x20]
                + b"\x8b\x7c\x24\x24"                   # mov edi,[esp+0x24]
                + b"\x8b\x6c\x24\x28"                   # mov ebp,[esp+0x28]
                + b"\x83\xc4\x2c"                        # add esp,0x2c
                + b"\xc3")                                 # ret
    return ((site_off - len(prologue), prologue + bytes(body)),
            (site_off + 0x33, epilogue))


def addrconf_a_geometry() -> dict:
    """The group-A offsets the patch and the test depend on."""
    return {"site": SIG_AT["addrconf_a"], "movzx": SIG_AT["addrconf_a"] + 0x0D,
            "epilogue": SIG_AT["addrconf_a"] + 0x33, "needle": 13}


def addrconf_b_blocks():
    """The inlined (group-B) block, its enclosing flow, and its epilogue.

    Returns ((code_offset, blob), ...).  The pieces are separate because the
    epilogue sits 0x702 bytes *before* the site, where the patch's backward jump
    lands on `mov eax,edx`.

    The site piece reproduces the real kernels' geometry byte for byte where the
    patcher's signature pins it, and reproduces the surrounding *control flow*
    where the old fixture only had filler:

      * `m-0x02` is a `jne` whose rel32 occupies `m+0x00..m+0x03`, so the
        signature's match starts inside an instruction and `m+0x04` -- the
        `jne`'s live fall-through target -- is the code the old entry clobbered;
      * `m-0x39` is a `je <anchor>` in the enclosing block: the branch that
        actually enters the site;
      * `m+0x14` is the ASSERT_RTNL call (the anchor), followed verbatim by the
        stock window, the device-type load and the ARPHRD dispatch;
      * `m+0x80` is the ASSERT-failure WARN block, entered only by the stock `je`
        at `m+0x1e`, ending in a jump back to `m+0x24`;
      * `m-0x702` is the inlined function's epilogue.
    """
    m = SIG_AT["addrconf_b"]
    anchor = m + B_ANCHOR
    warn = m + B_WARN
    sink = m + B_SINK
    cont = m + B_CONT
    epi = m + B_EPILOGUE

    # --- the enclosing block: nops, a real `je <anchor>`, and the two pieces of
    # the site's own control flow. -------------------------------------------
    b = Block(m + B_ENCLOSE)
    b.nops_to(m - 0x40)
    b.emit(b"\xa1" + struct.pack("<I", VADDR + m - 0x100))   # mov eax,[global]
    b.emit(b"\x85\xc0")                                      # test eax,eax
    b.at(m + B_BRANCH)
    b.jcc(anchor)                                             # je <anchor>
    b.emit(b"\x8d\x74\x26\x00")                               # lea esi,[esi]
    b.emit(b"\xba\x01\x00\x00\x00")                           # mov edx,1
    b.jmp(epi + 5)                                            # the other path
    # The `jne`'s live fall-through block: the code that was always there.
    b.nops_to(m - 0x12)
    b.emit(b"\x8b\x4c\x24\x0c")                               # mov ecx,[esp+0xc]
    b.emit(b"\x0f\xb7\x81\xdc\x00\x00\x00")                   # movzx eax,[ecx+0xdc]
    b.emit(b"\x66\x83\xf8\x01")                               # cmp ax,1
    b.at(m - 0x03)
    b.emit(b"\x90")                                           # align to m-0x02
    b.at(m - 0x02)
    b.jcc(sink, 0x85)                                         # jne <sink>
    # m+0x04: the fall-through the signature pins, ending exactly at the anchor.
    b.at(m + 0x04)
    b.emit(b"\x8b\x44\x24\x18")                               # mov eax,[esp+0x18]
    b.emit(b"\x89\xda")                                        # mov edx,ebx
    b.call(sink)                                               # call <sink>
    b.jmp(sink)                                                # jmp <sink>
    b.at(anchor)                                               # must land on the anchor
    assert _matches(B_LIVE, bytes(b.buf[m + 0x04 - b.start:
                                           m + 0x14 - b.start])), (
        "the synthesized fall-through code does not match the bytes the group-B "
        "signature pins at match+0x04..match+0x14")
    enclosing = (b.start, bytes(b.buf))

    # --- the site itself: the stock window, then the stock ARPHRD dispatch ----
    s = Block(anchor)
    s.emit(_call(s.la(), VADDR + sink))                        # call ASSERT_RTNL
    s.emit(b"\x85\xc0")                                        # test eax,eax
    s.emit(b"\x8d\x76\x00")                                    # lea esi,[esi]
    s.emit(_jcc(s.la(), VADDR + warn))                         # je <WARN block>
    s.emit(b"\x8b\x4c\x24\x0c")                                # mov ecx,[esp+0xc]
    assert _matches(B_STOCK_WINDOW, bytes(s.buf)), (
        "the synthesized stock window does not match the bytes the group-B "
        "signature pins")
    s.at(m + 0x28)
    s.emit(bytes.fromhex(B_MOVZX))                             # movzx (stock)
    s.emit(b"\x66\x83\xf8\x01" + b"\x74\x1f")                   # cmp ax,1 / je
    s.emit(b"\x66\x3d\x06\x03" + b"\x74\x19")                   # cmp ax,0x306
    s.emit(b"\x66\x3d\x20\x03" + b"\x74\x13")                   # cmp ax,0x320
    s.emit(b"\x66\x83\xf8\x07" + b"\x74\x0d")                   # cmp ax,7
    s.emit(b"\x66\x83\xf8\x20")                                 # cmp ax,0x20
    s.emit(b"\x8d\x76\x00")                                     # lea esi,[esi]
    s.at(m + 0x4E)
    s.jcc(sink, 0x85)                                           # jne <sink>
    s.at(cont)                                                  # where the je's land
    s.emit(b"\x8b\x44\x24\x0c")                                 # mov eax,[esp+0xc]
    s.call(sink)                                                # call <addrconf_...>
    s.emit(b"\x85\xc0")                                         # test eax,eax
    s.jcc(sink)                                                 # je <sink>
    s.emit(b"\xba\x01\x00\x00\x00")                             # mov edx,1
    s.jmp(epi + 5)                                              # jmp <epilogue>
    site = (anchor, bytes(s.buf))

    # --- the ASSERT-failure WARN block, after the anchor ---------------------
    w = Block(warn)
    w.emit(b"\xc7\x44\x24\x08" + struct.pack("<I", 0x92C))     # mov [esp+8],0x92c
    w.emit(b"\xc7\x44\x24\x04" + struct.pack("<I", VADDR + sink))
    w.emit(b"\xc7\x04\x24" + struct.pack("<I", VADDR + sink))
    w.call(sink)                                                # call <printk>
    w.call(sink)                                                # call <dump_stack>
    w.jmp(anchor + 0x10)                     # back to the stock `mov ecx` load
    warn_blob = (warn, bytes(w.buf))

    # --- a dead-end block for the paths that leave the site ------------------
    sink_blob = (sink, b"\x31\xc0\xc3")                         # xor eax,eax; ret

    # --- the inlined function's epilogue ------------------------------------
    # At match-0x702 (`mov edx,1`), so `mov eax,edx` -- the address the patcher's
    # backward jump must reach -- is at match-0x6fd, exactly as on all five real
    # kernels.  The fixture deliberately does NOT place this where the entry's
    # own displacement points: the geometry is the real kernel's, and whether an
    # entry's jump lands on it is the property the checker reads back out of the
    # artifact.  (An entry that computed the wrong displacement used to satisfy
    # a fixture that moved its epilogue to follow it.)
    e = Block(epi)
    e.emit(b"\xba\x01\x00\x00\x00")                             # mov edx,1
    e.at(m - 0x6FD)
    e.emit(b"\x89\xd0")                                         # mov eax,edx <- target
    e.emit(b"\x8b\x9c\x24\xf0\x00\x00\x00")                     # mov ebx,[esp+0xf0]
    e.emit(b"\x8b\xb4\x24\xf4\x00\x00\x00")                     # mov esi,[esp+0xf4]
    e.emit(b"\x8b\xbc\x24\xf8\x00\x00\x00")                     # mov edi,[esp+0xf8]
    e.emit(b"\x8b\xac\x24\xfc\x00\x00\x00")                     # mov ebp,[esp+0xfc]
    e.emit(b"\x81\xc4\x00\x01\x00\x00")                         # add esp,0x100
    e.emit(b"\xc3")                                              # ret
    epilogue_blob = (epi, bytes(e.buf))

    # The WARN block must have no fall-through entry: put the enclosing block's
    # final `ret` immediately before it.
    gap = Block(m + 0x6C)
    gap.nops_to(warn - 1)
    gap.emit(b"\xc3")                                            # ret
    gap_blob = (gap.start, bytes(gap.buf))

    assert gap.here == warn, "the WARN block's predecessor must end at it"
    return enclosing, site, gap_blob, warn_blob, sink_blob, epilogue_blob


def addrconf_b_extent() -> tuple:
    """(lo, hi) code offsets spanning every group-B piece, for the erasers."""
    blocks = addrconf_b_blocks()
    lo = min(off for off, _ in blocks)
    hi = max(off + len(blob) for off, blob in blocks)
    return lo, hi


def build_code() -> bytearray:
    code = bytearray(CODE_SIZE)
    blocks = {
        "kernel_halt": kernel_halt_block(),
        "cob7402": cob7402_block(),
        "wdt": wdt_block(),
        "tsc": tsc_block(),
    }
    for name, blob in blocks.items():
        off = SIG_AT[name]
        code[off:off + len(blob)] = blob
    # Written last: the sites and their epilogues must all survive.
    for off, blob in addrconf_a_blocks():
        code[off:off + len(blob)] = blob
    for off, blob in addrconf_b_blocks():
        code[off:off + len(blob)] = blob
    return code


def build_elf(shape: str = "group_b") -> bytes:
    """`shape` is "group_b" (the inlined-only kernel the regression test builds)
    or "group_a" (the standalone-function kernel)."""
    code = build_code()
    if shape == "group_b":
        # Erase the standalone block: this fixture must be a group-B-only kernel.
        off = SIG_AT["addrconf_a"] - 0x20
        code[off:off + 0x80] = b"\x90" * 0x80
    elif shape == "group_a":
        # Erase every group-B piece, including the epilogue and the enclosing
        # block: a group-A-only kernel must not match the inlined signature.
        lo, hi = addrconf_b_extent()
        code[lo:hi] = b"\x90" * (hi - lo)
    else:
        raise SystemExit(f"unknown fixture shape {shape!r}")
    return _elf_from_code(code)


def _elf_from_code(code: bytearray) -> bytes:
    ehdr = bytearray(ELF_HEADER_SIZE)
    ehdr[0:4] = b"\x7fELF"
    ehdr[4] = 1                     # ELFCLASS32
    ehdr[5] = 1                     # ELFDATA2LSB
    ehdr[6] = 1                     # EV_CURRENT
    struct.pack_into("<HH", ehdr, 16, 2, 3)      # e_type ET_EXEC, e_machine EM_386
    struct.pack_into("<I", ehdr, 24, VADDR)      # e_entry
    struct.pack_into("<I", ehdr, 28, PHDR_OFF)   # e_phoff
    struct.pack_into("<HH", ehdr, 40, ELF_HEADER_SIZE, PHDR_SIZE)
    struct.pack_into("<HH", ehdr, 44, 1, 0)      # e_phnum 1, e_shentsize 0
    # Section headers are absent (e_shoff/e_shnum/e_shstrndx stay 0): the boot
    # path does not read them, and patch-kernel.py can zero them anyway, so
    # leaving them out keeps this fixture out of that fallback path.
    phdr = struct.pack("<IIIIIIII", 1, HEAD, VADDR, VADDR, CODE_SIZE, CODE_SIZE,
                       5, 0x1000)                # PT_LOAD, R+X, align 0x1000
    elf = bytes(ehdr) + phdr + b"\x00" * (HEAD - ELF_HEADER_SIZE - PHDR_SIZE)
    return elf + bytes(code)


def build_bzimage(elf: bytes, member_capacity: int) -> bytes:
    head = bytearray(1024)
    head[0x1F1:0x1F5] = b"HdrS"          # a plausible boot-protocol magic
    member = gzip.compress(elf, compresslevel=9, mtime=0)
    if len(member) > member_capacity:
        raise SystemExit(f"fixture member is {len(member)} bytes, larger than the "
                         f"{member_capacity}-byte region")
    member += b"\x00" * (member_capacity - len(member))
    loader = b"\xfc\xe8\x00\x00\x00\x00" + bytes(range(16))   # the second stage
    return bytes(head) + member + loader


def _file_off(rel: int) -> int:
    """File offset in the fixture ELF of a code-region offset."""
    return HEAD + SIG_AT["addrconf_b"] + rel


def anchor_file_offset() -> int:
    """File offset of the anchor: the ASSERT_RTNL call the flow reaches.

    This is the byte the group-B patch must start at, and the target of the
    enclosing block's `je`.  Exposed so the test can assert the patched bytes
    are *there* rather than merely present somewhere in the payload.
    """
    return _file_off(B_ANCHOR)


def enclosing_branch_file_offset() -> int:
    """File offset of the enclosing block's `je <anchor>` (a 6-byte insn).

    Exposed so the test can decode the branch out of the artifact and check that
    its target really is the anchor, instead of assuming the fixture's layout.
    """
    return _file_off(B_BRANCH)


def warn_block_file_offset() -> int:
    """File offset of the ASSERT-failure WARN block the stock `je` targets."""
    return _file_off(B_WARN)


def epilogue_file_offset() -> int:
    """File offset of the `mov eax,edx` the group-B patch's jump lands on."""
    return _file_off(B_EPILOGUE) + 5


def main() -> int:
    args = list(sys.argv[1:])
    queries = {
        "--anchor-offset": anchor_file_offset,
        "--enclosing-branch-offset": enclosing_branch_file_offset,
        "--warn-block-offset": warn_block_file_offset,
        "--epilogue-offset": epilogue_file_offset,
    }
    if args and args[0] in queries:
        # The group-B geometry, as file offsets in the fixture ELF.
        print(hex(queries[args[0]]()))
        return 0
    if not args:
        raise SystemExit("usage: make-kernel-patch-fixture.py <output-dir> [shape]\n"
                         "       make-kernel-patch-fixture.py "
                         + "| ".join(queries))
    out = Path(args[0])
    shape = args[1] if len(args) > 1 else "group_b"
    out.mkdir(parents=True, exist_ok=True)
    # "group_b" erases the standalone block: that is the shape the regression
    # test needs, since the old single signature missed it entirely.
    elf = build_elf(shape)
    # The member region is sized with real headroom, so the patched payload --
    # a few bytes longer as a stream -- still recompresses into it.
    bz = build_bzimage(elf, 0x800)
    (out / "fixture.vmlinux").write_bytes(elf)
    (out / "fixture.bzImage").write_bytes(bz)
    print(f"wrote {out / 'fixture.vmlinux'} ({len(elf)} bytes)")
    print(f"wrote {out / 'fixture.bzImage'} ({len(bz)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
