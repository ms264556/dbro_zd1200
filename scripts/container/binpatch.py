#!/usr/bin/env python3
"""Signature-located binary patches: the engine behind patch-kernel.py and
patch-file.py.

A patch is located by byte signature, never by address: vendor binaries are
relinked for every release, so the same code moves.  Each patch carries the
bytes around the site it targets, with `??` masking the bytes that vary between
releases (embedded absolute addresses and relative displacements).  A patch must
match its file exactly once; more than one match (ambiguous) is a hard error.
What a zero match means is the caller's decision -- it passes the set of patch
names a release may legitimately not carry.

This module holds no patch tables and knows nothing about containers.  The
callers own those: patch-kernel.py unwraps the bzImage's gzip member and applies
the kernel table to the ELF inside it, and patch-file.py applies a table to a
plain ELF file out of the root filesystem.  Both go through locate_sites(), so
the writer and the offline self-test cannot drift apart in what they match or in
how wide the mask is.

A patch table is a list of tuples:

    (name, signature_hex, patch_offset, patch_bytes, description, rel32_exit,
     group)

signature_hex is matched with "??" as a wildcard; patch_bytes is written at
patch_offset inside the match.  When rel32_exit is non-zero, patch_bytes is only
the 0xe9 opcode of a jump and its target is the jump at match+rel32_exit inside
the same match: the label that jump reaches is the exit of the block being
skipped, so the displacement is read from the match and written for the patch's
own jump.  `group` names a set of patches that are alternative shapes of one
fix: entries in the same non-empty group apply at most one per file.  A member
that matches nothing while a sibling matched is reported as not applying here --
it is not a partially patched release -- and only a group with *no* member
matched is a real "this release has no such site" case.

The signatures describe the *stock* bytes.  A site is located with the bytes the
patch overwrites masked out, so the same signature finds the site in a stock
file and in one already patched; the bytes actually present then decide whether
there is anything to do.  That makes re-running a patcher on its own output a
no-op instead of a "NOT FOUND" error.
"""

import re
import struct
import sys
from typing import NamedTuple


class Site(NamedTuple):
    """One patch's signature, its match, and everything needed to write it.

    Held as a record rather than a bare tuple because the locate pass and the
    write pass are separate loops: a field the write pass uses but the record
    does not carry is then a construction-time TypeError instead of a stale loop
    variable.  That mistake shipped twice -- first `patch_off`, then the match
    width -- and each time wrote at the wrong offset.
    """
    name: str
    sig_hex: str
    group: str
    patch: bytes
    rel32_exit: int
    patch_off: int
    sig_len: int
    written: int              # bytes reported as overwritten (5 for a rel32 jump)
    write_width: int          # bytes the locator masks: the whole write
    hits: list                # file offsets of every match in the payload



def _locator(sig_hex: str, patch_off: int, width: int) -> str:
    """The match pattern: `width` bytes at patch_off masked out."""
    return (sig_hex[:patch_off * 2] + "??" * width
            + sig_hex[(patch_off + width) * 2:])



def locate_sites(payload: bytes, patches):
    """Match every patch's signature against `payload` once, for both callers.

    Returns (sites, matched_groups): one Site per entry of the `patches` table,
    in order, each holding its hits and every field the readers need, plus the
    group -> member map that says which shape of each group this file carries.

    Both the writer (main) and the offline checker (self_test) go through here,
    so they cannot drift apart in what they match or in how wide the mask is.
    """
    sites = []
    matched_groups = {}
    for entry in patches:
        name, sig_hex, patch_off, patch, desc, rel32_exit, group = entry
        # The locator masks every byte the patch writes, so the same signature
        # finds the site whether or not the patch is already there.  The width is
        # the whole write -- the 5-byte `e9 rel32` jump of a rel32_exit entry, or
        # the literal patch bytes -- which for a patch_off 0 entry like kernel_halt
        # is wider than the declared patch (it replaces a 5-byte `mov eax,imm32`,
        # but `patch` is just the 1-byte `ret`).
        write_width = max(5 if rel32_exit else 0, len(patch))
        hits = find_signature(payload, _locator(sig_hex, patch_off, write_width))
        sites.append(Site(name, sig_hex, group, patch, rel32_exit, patch_off,
                          len(sig_hex) // 2, 5 if rel32_exit else len(patch),
                          write_width, hits))
        if len(hits) == 1 and group:
            matched_groups[group] = name
    return sites, matched_groups



def _patched_bytes(site, elf: bytes, sig_start: int):
    """The exact bytes a Site writes at its match."""
    fo = sig_start + site.patch_off
    if not site.rel32_exit:
        return site.patch
    # Re-target the patch's jump to the exit of the block being skipped, whose
    # displacement is read from the exit jump at match+rel32_exit.  Both sites are
    # in one PT_LOAD segment, so file offsets and VAs share a delta.
    exit_rel32 = struct.unpack_from("<i", elf, sig_start + site.rel32_exit + 1)[0]
    target = (sig_start + site.rel32_exit + 5 + exit_rel32) & 0xffffffff
    return b"\xe9" + struct.pack("<I", (target - (fo + 5)) & 0xffffffff)


def _site_error(site, pristine: bytes, sig_start: int):
    """Why this Site must not be written at `sig_start`, or None if it is safe.

    The site has to lie inside the one match, and the bytes it leaves alone have
    to be the stock bytes its signature describes.  That is what catches a site
    that is inside the match but is not the site the patch was derived from -- a
    drifted offset passes a bounds check and fails this one.  A site that is
    already fully patched is not an error: that is the patcher being re-run on
    its own output, which must be a no-op.
    """
    fo = sig_start + site.patch_off
    if not (0 <= site.patch_off
            and fo + site.write_width <= sig_start + site.sig_len):
        return (f"patch site for {site.name} at file 0x{fo:x} does not lie "
                "inside its own match; refusing to write")
    # What the write will put down: the literal patch, or (for a rel32_exit patch)
    # a computed `e9 rel32` jump.  `already` means the file already carries it --
    # a re-run, which must be a no-op.
    entry = _patched_bytes(site, pristine, sig_start)
    if bytes(pristine[fo:fo + len(entry)]) == entry:
        return None
    # Not patched: the bytes the entry overwrites that the signature pins (not
    # the wildcards) must be the stock bytes, so a drifted or wrong site fails.
    wrong = [i for i in range(site.patch_off, site.patch_off + site.write_width)
             if site.sig_hex[i * 2:i * 2 + 2] != "??"
             and pristine[sig_start + i] != int(site.sig_hex[i * 2:i * 2 + 2], 16)]
    if wrong:
        return (f"patch site for {site.name} at file 0x{fo:x} is not the stock "
                f"site its signature describes (byte(s) {wrong[:4]} differ); "
                "refusing to write")
    return None


def off_to_va(data: bytes, off: int) -> int:
    """Map a file offset in the ELF payload back to a virtual address via the
    ELF32 PT_LOAD segments (for reporting)."""
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



def self_test(elf: bytes, patches, optional=frozenset(), what="kernel") -> int:
    """Check every signature in `patches` against a pristine ELF.

    Each patch must match exactly once, and the site it would write must fall
    inside that one match -- a signature that drifted, or that matches somewhere
    other than the function it describes, would otherwise write bytes into the
    wrong place and only show up as a guest that misbehaves.  This is the offline
    half of the patch verification; it needs no vendor material beyond the ELF
    itself, so it can run on every change to a patch table.

    `optional` names the patches a release may legitimately not carry; `what` is
    the noun the messages use for the file ("kernel", "stamgr", ...).

    Returns the number of failed checks (0 when every check passes).
    """
    failures = 0
    # The same location pass the writer uses, so this checks the real thing --
    # including the mask width -- rather than an approximation of it.
    sites, matched_groups = locate_sites(elf, patches)

    for site in sites:
        name = site.name
        is_optional = name in optional
        if len(site.hits) == 0:
            if site.group and site.group in matched_groups:
                # A sibling shape of the same fix matched here, so this one is
                # simply not the shape this file was built with.
                print(f"  ok    {name:32s} not this release's shape "
                      f"(already covered by {matched_groups[site.group]})")
            elif is_optional:
                print(f"  ok    {name:32s} absent (optional for this release)")
            else:
                print(f"  FAIL  {name:32s} no match (required patch)", file=sys.stderr)
                failures += 1
            continue
        if len(site.hits) > 1:
            print(f"  FAIL  {name:32s} matched {len(site.hits)} places (ambiguous)",
                  file=sys.stderr)
            failures += 1
            continue
        # The site must lie within the match, and the match must be long enough
        # to hold the preimage the description promises.
        if not (0 <= site.patch_off
                and site.patch_off + site.write_width <= site.sig_len):
            print(f"  FAIL  {name:32s} patch_off {site.patch_off}+"
                  f"{site.write_width} outside the {site.sig_len}-byte match",
                  file=sys.stderr)
            failures += 1
            continue
        # A pristine file must NOT already carry the patch, or the signature is
        # describing our own output rather than the stock bytes.  Compare the
        # bytes the write actually puts down (a rel32_exit patch's jump is
        # computed, so site.patch alone is not them).
        fo = site.hits[0] + site.patch_off
        entry_patch = _patched_bytes(site, bytes(elf), site.hits[0])
        if bytes(elf[fo:fo + len(entry_patch)]) == entry_patch:
            print(f"  FAIL  {name:32s} already patched in a pristine {what} "
                  "(signature describes the patched bytes)", file=sys.stderr)
            failures += 1
            continue
        va = off_to_va(elf, fo)
        print(f"  ok    {name:32s} unique at {va:#x} "
              f"(file 0x{fo:x}, {site.written} byte(s))")

    return failures


def apply(elf: bytearray, patches):
    """Write every patch in `patches` that has a site in `elf`, in place.

    Returns (missing, changed): the names of the patches that placed no site
    here, and whether any byte was written.  Whether a missing patch is an error
    is the caller's decision.  An ambiguous signature, or a site that is not the
    stock site its signature describes, raises SystemExit before that patch
    writes anything.
    """
    pristine = bytes(elf)
    missing = []
    changed = False
    # Every site is located first, because whether a group member's absence is a
    # skipped patch depends on whether a sibling in its group matched -- and that
    # sibling may come later in the table.  A group member that places no site
    # while a sibling does is simply not this release's shape: the fix still
    # landed, and it must not be reported as skipped (which would make a fully
    # patched release look partly unpatched).
    sites, matched_groups = locate_sites(pristine, patches)

    for site in sites:
        name = site.name
        if len(site.hits) == 0:
            if site.group and site.group in matched_groups:
                print(f"  {name:22s}: not this release's shape - already "
                      f"covered by {matched_groups[site.group]}")
            else:
                print(f"  {name:22s}: NOT FOUND - no site for this fix")
                missing.append(name)
            continue
        if len(site.hits) > 1:
            raise SystemExit(f"signature for {name} matched {len(site.hits)} "
                             "places; refusing to patch (ambiguous)")
        sig_start = site.hits[0]
        fo = sig_start + site.patch_off
        error = _site_error(site, pristine, sig_start)
        if error:
            raise SystemExit(error)
        patch = _patched_bytes(site, bytes(elf), sig_start)
        va = off_to_va(bytes(elf), fo)
        original = bytes(elf[fo:fo + len(patch)])
        if original == patch:
            print(f"  {name:22s}: already patched at {va:#x} (offset 0x{fo:x})")
        else:
            print(f"  {name:22s}: {original.hex()} -> {patch.hex()} at {va:#x} "
                  f"(offset 0x{fo:x})")
            elf[fo:fo + len(patch)] = patch
            changed = True
    return missing, changed
