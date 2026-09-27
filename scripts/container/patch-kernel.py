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
hard error, and so is zero matches for a patch that every release carries.  A
zero match for an entry in OPTIONAL_PATCHES is reported and skipped: the two
dhcp0 signatures between them cover all nine supported releases, so a release
matching neither installs without that fix.  Two entries may be alternative
shapes of one fix (see the `group` field below): the member that matches is
applied and a sibling that matches nothing is reported as not applying rather
than as a skipped patch.

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
from typing import NamedTuple

# Each patch is (name, signature_hex, patch_offset, patch_hex, description,
# rel32_exit, group).  signature_hex is matched against the kernel ELF with "??"
# as a wildcard; patch_hex is written at patch_offset inside the match.
# When rel32_exit is non-zero, patch_hex is only the 0xe9 opcode of a jump and
# its target is the jump at match+rel32_exit inside the same match: the label
# that jump reaches is the exit of the block being skipped, so the displacement
# is read from the match and written for the patch's own jump.
# `group` names a set of patches that are alternative shapes of one fix: entries
# in the same non-empty group apply at most one per kernel.  A member that
# matches nothing while a sibling matched is reported as not applying here -- it
# is not a partially patched release -- and only a group with *no* member
# matched is a real "this release has no such site" case.
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
     "kernel_halt(): a failed board-chip probe must not halt the guest", 0, ""),
    # The COB7402 board's hardware reset pulse: for board states 1 and 3 it
    # drives the ICH7 GPIO window (runtime I/O base +0x2a set to 0x40 with a poll
    # of bit 6, then +0x38 pulsed with the port-0x61 handshake).  QEMU provides
    # none of that window, and the BSP reaches the routine through a pointer
    # rather than calling it, so return 0 and let QEMU do reset and termination.
    ("cob7402_reset_watchdog",
     "5383ec08e8????????83f801741283f803",
     0, bytes.fromhex("31c0c3"),
     "COB7402 board reset/watchdog routine -> no-op", 0, ""),
    # This patch exists ONLY to remove an older, buggy patch: a vendor kernel
    # does not need it.  `eb 0a` rewrites the u-watchdog timeout block so it runs
    # again (v54_on_reboot(REBOOT_WATCHDOG) + write_kflags('9')), undoing the
    # older broad skip that lost GRUB's spare-image fallback.  On a stock kernel
    # it only quiets the log line.
    ("wdt_timeout_marker",
     "31c083c4185b5e5fc3" + "??" * 7
     + "e8????????b801000000e8????????b8????????e8????????e9????????",
     9, bytes.fromhex("eb0a"),
     "nar5520_wdt_thread(): undo the older broad skip of the timeout block", 0, ""),
    # addrconf_dev_config() must not configure the vendor's `dhcp0` interface.
    #
    # The `af` module builds dhcp0 in create_dhcp(): register_netdevice()
    # (dhcp.c:314), dev_open() (dhcp.c:319), then `dev_dhcp = dev` (dhcp.c:328).
    # dev_open() fires the IPv6 addrconf notifier's NETDEV_UP case, which reaches
    # addrconf_dev_config() and adds dhcp0's link-local address.  That address
    # joins its solicited-node multicast group, and igmp6_group_added() responds
    # with mld_ifc_event() -> mld_ifc_start_timer(idev, 1), i.e. a timer 2 jiffies
    # out.  When it expires it transmits an MLD report over dhcp0, whose
    # ndo_start_xmit is the module's dhcp_xmit().  dhcp_xmit() loads the module
    # global `dev_dhcp` and dereferences it with no NULL check, and at that moment
    # dev_dhcp is still NULL because create_dhcp() has not reached dhcp.c:328:
    #
    #     BUG: unable to handle kernel NULL pointer dereference at 000003b8
    #     IP: [<...>] dhcp_xmit+0x9e/0x210 [af]
    #     ... mld_ifc_timer_expire -> mld_sendpack -> ... -> dhcp_xmit ...
    #     [<...>] ? create_dhcp+0x130/0x1c0 [af]   (the dev_open() call site)
    #
    # The vendor's oops guard then reboots the guest, so the boot loops forever
    # instead of reaching READY.  The shape: a vendor virtual net_device,
    # IPv6 MLD, and a half-built device.
    #
    # Suppressing only dhcp0's IPv6 configuration removes the trigger, because
    # with no link-local address there is no solicited-node group and therefore
    # no MLD timer -- measured against 2.6.32's addrconf.c/mcast.c:
    # ipv6_add_dev() joins only the all-nodes group, which mca_alloc() flags
    # MAF_NOREPORT, and igmp6_group_added() returns early for it (and again while
    # !(dev->flags & IFF_UP), which is the case during NETDEV_REGISTER anyway).
    # Every other interface keeps byte-identical behaviour.
    #
    # The IPv6 stack itself stays available, which is the point: disabling it
    # wholesale (`ipv6.disable=1`) was measured to work but breaks the vendor's
    # TAC/RADIUS-proxy components with "Address family not supported by protocol".
    #
    # An in-module fix was tried and abandoned: the faulting site needs a NULL
    # guard that does not fit.  dhcp_xmit's window is .text+0x116ac..0x116bd (18
    # bytes) and its layout is pinned by two existing R_386_32 relocations
    # (outdev at +0x8c, dev_dhcp at +0x94, with the dev_dhcp->ifindex store at
    # +0x91), so a guard that keeps that store needs 21 bytes.
    #
    # The replacement here was 20 bytes once, and the 20-byte version was
    # defective: it was not only the ASSERT_RTNL block.  The stock `movzx
    # eax,word [ebx+0xdc]` (the device type the ARPHRD switch dispatches on)
    # sits at sig_start+0x0d..+0x13, so the six nops of that version overwrote
    # its last six bytes.  The `jne` landed on the dispatch at +0x14, which
    # then compared `ax` against 1/0x306/0x320/7/0x20 using whatever eax the
    # ASSERT_RTNL helper left there -- and that helper (0xc125d440: `mov
    # eax,[global]; sub eax,1; setne al; movzx eax,al; ret`) returns 0 or 1, so
    # `cmp ax,1` matched for a healthy lock and every interface was treated as
    # ARPHRD_ETHER.  That was a silent IPv6 address-configuration change for
    # non-Ethernet devices on the four group-A releases, and no boot test could
    # see it (the guest still came up).  Disassembling the patched kernels is
    # what found it.
    #
    # The 13-byte replacement below is the fix.  It stops before +0x0d, so the
    # `movzx` and the dispatch at +0x14 stay byte-for-byte intact, and dhcp0
    # alone is branched past them to the epilogue at +0x33.  13 bytes cannot
    # also carry the old 10-byte name test: a 2-byte conditional plus the
    # 5-byte near jump that exit uses plus that test is 17 bytes, so the entry
    # below tests only the first four bytes of the name.
    #
    # The signature still locates the site by masking the 20 bytes the old patch
    # replaced, but this entry writes only the first 13 of them, so
    # sig_start+0x0d..+0x13 -- the whole 7-byte `movzx` -- stays byte-for-byte
    # stock.  That is the control-flow change: a non-dhcp0 device takes
    # `jne +0x05` to the untouched `movzx` and runs the stock ARPHRD switch
    # verbatim, while dhcp0 takes `jmp +0x26` to the function's own epilogue at
    # +0x33 without configuring anything.
    ("addrconf_dev_config_dhcp0",
     "??" * 20 + "6683f8017431663d0603742b663d200374256683f80790741e6683f82074188b",
     0, bytes.fromhex("813b64686370"     # cmp dword [ebx], "dhcp"
                      "7505"             # jne +0x05  -> +0x0d, the stock movzx
                      "e926000000"),     # jmp +0x26  -> +0x33, the epilogue (dhcp0)
     "addrconf_dev_config(): do not configure IPv6 on the vendor dhcp0 interface",
     0, "dhcp0_variant"),
    # The same fix for the releases whose compiler inlined addrconf_dev_config()
    # into addrconf_notify() instead of emitting it as a function: the code has
    # no prologue, prologue stores or epilogue of its own, and everything from
    # the stock `movzx eax,[ecx+0xdc]` on is byte-identical to the standalone
    # shape (the movzx sits at +0x14 here, not +0x0d).
    #
    # The geometry, and why the write is at +0x14 and nowhere else.  The match
    # starts at a `jne`'s rel32 displacement -- the instruction containing the
    # match begins two bytes before it -- so the first four matched bytes are
    # displacement bytes, not an instruction boundary, and match+0x04 is the
    # fall-through target of that `jne`, i.e. LIVE code (`mov eax,[esp+0x18]`;
    # `mov edx,ebx`; a call; a jmp).  The address this code path actually
    # reaches is match+0x14, where the ASSERT_RTNL call sits: on all five
    # releases exactly one branch targets it (`je <match+0x14>` inside the
    # enclosing addrconf_notify), and it is an instruction boundary.  The stock
    # block there is:
    #
    #   +0x00 call <ASSERT_RTNL helper>   } ASSERT_RTNL, whose result the caller
    #   +0x05 test eax,eax                } discards (addrconf_dev_config returns
    #   +0x07 lea esi,[esi]               } void), plus its failure path
    #   +0x0a je  <WARN block>            }
    #   +0x10 mov ecx,[esp+0xc]           <- the device pointer reloaded after
    #   +0x14 movzx eax,word [ecx+0xdc]   <- the device type, STOCK, not touched
    #   +0x19 (stock ARPHRD dispatch)
    #
    # An earlier version of this entry wrote its 20 bytes at match+0x00 instead.
    # Nothing branches there, so its first instruction was unreachable; the
    # fall-through of the `jne` at match+0x02 landed in the middle of it; and
    # the ASSERT block, the device reload and the dispatch were left stock, so
    # dhcp0 was still configured.  It also overwrote the live fall-through code
    # at match+0x04..+0x13.  patch_off is therefore 0x14: the write lands on the
    # block the enclosing flow actually reaches.
    #
    # The replacement, 20 bytes ending exactly where the stock `movzx` begins:
    #
    #   +0x00 mov ecx,[esp+0xc]       } the device pointer, loaded HERE rather
    #                                 } than assumed to be live in ecx
    #   +0x04 cmp dword [ecx],"dhcp"  }
    #   +0x0a jne +0x08               -> +0x14, the stock movzx (non-dhcp0)
    #   +0x0c nop; nop; nop           } pad
    #   +0x0f jmp match-0x6fd         <- dhcp0 leaves HERE, for the epilogue
    #   +0x14 (stock movzx: every other device enters here)
    #
    # ecx is loaded rather than assumed.  It is not a free choice: the compiler
    # reloads the device pointer after the ASSERT_RTNL call precisely because a
    # call clobbers the caller-saved registers, and whether ecx happens to hold
    # it at the anchor is a control-flow property of the vendor binary that this
    # byte-signature cannot check at patch time.  `mov ecx,[esp+0xc]` is the
    # same instruction, on the same esp, that stock runs at +0x10, so a
    # non-dhcp0 device sees stock behaviour bit-for-bit: `jne` reaches the
    # untouched movzx and the stock ARPHRD switch runs on dev->type.  The cost
    # is 4 bytes, which leaves room for only the first four name bytes: 4 + 6
    # (the name compare) + 2 (the branch) + 5 (the jump) = 17, and a fifth-byte
    # compare plus a second branch would need 23.  (On 10.2.1.0.236 ecx CAN be
    # shown to hold the device: the anchor's only incoming branch is inside a
    # straight run whose head is `mov ecx,[esp+0xc]` and whose interior has no
    # other entry and no call.  That invariant is not used -- group A's 13-byte
    # entry accepts the same four-byte test, so both shapes now mean the same
    # thing.)
    #
    # The `jne` must land on the stock `movzx` at +0x14, so the jump has to be
    # the last instruction and has to END at +0x14: a non-dhcp0 device enters
    # the stock code there, the last byte the locator masks at mask width 20, so
    # anything at or after +0x14 would either be entered mid-instruction or
    # never run.  That is why the pad sits before the jump.
    #
    # dhcp0's exit is the inlined function's own epilogue at match-0x6fd, the
    # `mov eax,edx` that follows `mov edx,1` -- the jump deliberately skips the
    # `mov edx,1` and the return value is whatever edx already held (the caller
    # ignores it: addrconf_dev_config returns void).  This is the same
    # convergence point the group-A patch uses, so both shapes mean the same
    # thing.  The displacement is position-dependent and re-derived from THIS
    # anchor: the jump is at match+0x23 and ends at match+0x28, so the
    # displacement to match-0x6fd is -0x725, not the -0x711 a write at +0x0f
    # needed.
    #
    # The old write also covered match+0x24, the stock `mov ecx,[esp+0xc]`, and
    # that address has an incoming branch: the ASSERT-failure WARN block (the
    # `je +0x0a` target) ends with `jmp match+0x24`.  That is safe because the
    # WARN block's only entry is that `je` -- the instruction this entry
    # overwrites -- and the instruction before the block is an unconditional
    # jmp, so there is no fall-through either: with the `je` gone the whole
    # block is unreachable and its back-jump never runs.  Measured on all five
    # releases; if a release ever showed a second entry into the block, the
    # patch would have to keep match+0x24 an instruction boundary, which 20
    # bytes cannot do alongside the 5-byte backward jump, and that release
    # would have to be escalated rather than patched.
    #
    # Do NOT "simplify" the target back to the caller's tail at match-0x4ba.
    # That tail is not a safe exit: ebp is live there (`test ebp,ebp` / `je`, and
    # the fall-through does `cmp [ebp+0x98],...`).  The anchor's only entry is
    # the `je` taken when `[0xc14b8e68]+0x54` is NULL, while ebp was set from
    # `[ecx+0x13c]` -- so arriving at the tail runs IPv6 code for whatever ebp
    # points at, instead of returning.
    #
    # Size-neutral (20 for 20).  The 20 bytes written are the ASSERT block, its
    # failure path and the device reload -- all of them replaced by the name
    # test and the exit -- and the stock `movzx` and ARPHRD dispatch from +0x14
    # are untouched, so every non-dhcp0 device is unaffected.
    #
    # The signature's first four bytes stay wildcards (the containing `jne`'s
    # rel32), but match+0x04..+0x13 are pinned to the live fall-through code the
    # old entry used to clobber: all five releases carry `mov eax,[esp+0x18]`,
    # `mov edx,ebx`, a call and a jmp there, identical apart from the two
    # displacements, which stay wildcards per this file's convention.
    ("addrconf_dev_config_dhcp0_inlined",
     "??" * 4 + "8b442418" + "89da" + "e8" + "????????" + "e9" + "????????"
     + "e8" + "????????" + "85c0" + "8d7600" + "0f84" + "????????"
     + "8b4c240c"
     + "0fb781dc0000006683f801741f663d06037419663d200374136683f807740d6683f820"
     + "8d7600" + "0f85" + "????????",
     0x14, bytes.fromhex("8b4c240c"    # mov ecx,[esp+0xc] (the device pointer)
                         "813964686370"  # cmp dword [ecx], "dhcp"
                         "7508"          # jne +0x08 -> +0x14, the stock movzx
                         "909090"        # pad; the jump must end at +0x14
                         "e9dbf8ffff"),  # jmp match-0x6fd (the epilogue)
     "addrconf_dev_config() (inlined): do not configure IPv6 on the vendor "
     "dhcp0 interface", 0, "dhcp0_variant"),
]

# Patches that a release may legitimately not carry at all.  A zero match for
# one of these is reported and skipped; a zero match for any other patch means
# its signature changed and is still a hard error.
#
# addrconf_dev_config_dhcp0 belongs here, and getting that wrong was a real
# regression: the signature matches 10.5.1.0.282, 10.5.1.0.255, 10.4.1.0.272 and
# 10.3.1.0.45, and does not match 10.2.1.0.236, 10.1.2.0.318, 9.13.3.0.164,
# 9.10.2.0.130 or 9.9.1.0.52.  While it was required, build-synthetic-cf.py raised
# on those five and prepare-vm-disks.sh could not build a disk at all: nine
# installable releases became four.
#
# The signature is absent there; the FUNCTION is not.  Disassembly shows the same
# code inlined into addrconf_notify(): the ARPHRD switch onward is byte-identical
# to the standalone shape, while the bytes before it and the exit differ -- the
# inlined copy has no epilogue of its own and leaves through the enclosing
# function's, and the ASSERT_RTNL block the patch has to reach sits 0x14 bytes
# after the match (see the entry for why the device pointer is loaded rather than
# read out of ecx).  Both shapes are now in PATCHES, in the `dhcp0_variant`
# group: every one of the nine supported releases matches exactly one of the two,
# so all nine get the crash fix.  (The group field is what keeps a release that
# matched the standalone shape from being reported as having skipped the inlined
# one.)
# A release built a third way would match neither, and that is the case the
# entries in OPTIONAL_PATCHES still cover -- it installs without the fix instead
# of aborting the install.
#
# A patch must degrade safely -- a missing site must skip, never abort the
# install -- so an unrecognised release installs without this fix rather than not
# installing at all.  The skip is printed, so it is never silently unpatched.
OPTIONAL_PATCHES = {"addrconf_dev_config_dhcp0",
                    "addrconf_dev_config_dhcp0_inlined"}


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


def locate_sites(payload: bytes):
    """Match every patch's signature against `payload` once, for both callers.

    Returns (sites, matched_groups): one Site per PATCHES entry, in order, each
    holding its hits and every field the readers need, plus the group -> member
    map that says which shape of each group this kernel carries.

    Both the writer (main) and the offline checker (self_test) go through here,
    so they cannot drift apart in what they match or in how wide the mask is.
    """
    sites = []
    matched_groups = {}
    for name, sig_hex, patch_off, patch, desc, rel32_exit, group in PATCHES:
        # The locator masks every byte the patch writes, so the same signature
        # finds the site whether or not the patch is already there.  The width is
        # the whole write -- the 5-byte jump, or the patch bytes -- which for a
        # patch_off 0 entry like kernel_halt is wider than the declared patch (it
        # replaces a 5-byte `mov eax,imm32`, but `patch` is just the 1-byte
        # `ret`).
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
    already = bytes(pristine[fo:fo + len(site.patch)]) == site.patch
    if site.rel32_exit and not already:
        # The jump is computed from the match, so compare against what it will be.
        already = bytes(pristine[fo:fo + 5]) == _patched_bytes(site, pristine,
                                                               sig_start)
    if already:
        return None
    wrong = [i for i in range(site.patch_off, site.patch_off + len(site.patch))
             if site.sig_hex[i * 2:i * 2 + 2] != "??"
             and pristine[sig_start + i] != int(site.sig_hex[i * 2:i * 2 + 2], 16)]
    if wrong:
        return (f"patch site for {site.name} at file 0x{fo:x} is not the stock "
                f"site its signature describes (byte(s) {wrong[:4]} differ); "
                "refusing to write")
    return None


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


def self_test(vmlinux_path: str) -> int:
    """Check every PATCHES signature against a pristine kernel ELF.

    Each patch must match exactly once, and the site it would write must fall
    inside that one match -- a signature that drifted, or that matches somewhere
    other than the function it describes, would otherwise write bytes into the
    wrong place and only show up as a guest that will not boot.  This is the
    offline half of the kernel-patch verification; it needs no vendor material
    beyond the kernel ELF, so it can run on every change to PATCHES.

    Returns 0 when every check passes, 1 otherwise.
    """
    path = Path(vmlinux_path)
    if not path.exists():
        print(f"self-test: {vmlinux_path} not found", file=sys.stderr)
        return 1
    elf = path.read_bytes()
    if not elf.startswith(b"\x7fELF") or elf[4:5] != b"\x01":
        print(f"self-test: {vmlinux_path} is not a 32-bit ELF", file=sys.stderr)
        return 1

    failures = 0
    print(f"self-test against {vmlinux_path} ({len(elf)} bytes)")
    # The same location pass the writer uses, so this checks the real thing --
    # including the mask width -- rather than an approximation of it.
    sites, matched_groups = locate_sites(elf)

    for site in sites:
        name = site.name
        optional = name in OPTIONAL_PATCHES
        if len(site.hits) == 0:
            if site.group and site.group in matched_groups:
                # A sibling shape of the same fix matched here, so this one is
                # simply not the shape this kernel was built with.
                print(f"  ok    {name:32s} not this release's shape "
                      f"(already covered by {matched_groups[site.group]})")
            elif optional:
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
        # A pristine kernel must NOT already carry the patch, or the signature is
        # describing our own output rather than the stock bytes.
        fo = site.hits[0] + site.patch_off
        if bytes(elf[fo:fo + len(site.patch)]) == site.patch:
            print(f"  FAIL  {name:32s} already patched in a pristine kernel "
                  "(signature describes the patched bytes)", file=sys.stderr)
            failures += 1
            continue
        va = off_to_va(elf, fo)
        print(f"  ok    {name:32s} unique at {va:#x} "
              f"(file 0x{fo:x}, {site.written} byte(s))")

    if failures:
        print(f"self-test: {failures} failure(s)", file=sys.stderr)
        return 1
    print("self-test: all signatures locate exactly one site")
    return 0


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
    ap.add_argument("--self-test", action="store_true",
                    help="offline signature check against --vmlinux: every patch "
                         "in PATCHES must locate exactly one site inside its own "
                         "match, and every required patch must match.  Writes "
                         "nothing.  Use this against a pristine vmlinux to catch "
                         "a signature that has drifted or become ambiguous.")
    args = ap.parse_args()

    if args.self_test:
        return self_test(args.vmlinux)

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
    pristine = bytes(payload)
    missing = []
    # Every site is located first, because whether a group member's absence is a
    # skipped patch depends on whether a sibling in its group matched -- and that
    # sibling may come later in PATCHES.  A group member that places no site
    # while a sibling does is simply not this release's shape: the fix still
    # landed, and it must not be reported as skipped (which would make a fully
    # patched release look partly unpatched).
    sites, matched_groups = locate_sites(bytes(elf))

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

    if missing:
        required_missing = [m for m in missing if m not in OPTIONAL_PATCHES]
        if required_missing:
            raise SystemExit(
                f"missing patches for this release: {', '.join(required_missing)}")
        print(f"note: patches not applicable to this release (skipped): "
              f"{', '.join(missing)}")

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
