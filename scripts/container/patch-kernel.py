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
import os
import struct
import sys
import zlib
from pathlib import Path

# The signature engine lives beside this script (binpatch.py) and is shared with
# patch-file.py.  The directory is put on the path explicitly because the tests
# load this file by path (importlib), where sys.path[0] is not this directory.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import binpatch  # noqa: E402

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
    # addrconf_dev_config() must not configure the vendor's `dhcp0` interface, or
    # the guest crash-loops before it ever reaches READY.
    #
    # The `af` module's create_dhcp() register_netdevice()s dhcp0 and dev_open()s
    # it (dhcp.c:314,319) before it sets the module global `dev_dhcp = dev`
    # (dhcp.c:328).  dev_open() fires the IPv6 addrconf NETDEV_UP notifier, which
    # reaches addrconf_dev_config() and adds dhcp0's link-local address; that
    # address joins its solicited-node group, igmp6_group_added() arms an MLD
    # timer 2 jiffies out, and when it fires it transmits an MLD report through
    # dhcp0's ndo_start_xmit (the module's dhcp_xmit()).  dhcp_xmit() dereferences
    # the still-NULL dev_dhcp -- create_dhcp() has not reached line 328 yet:
    #     BUG: ... NULL pointer dereference ... dhcp_xmit+0x9e/0x210 [af]
    #     mld_ifc_timer_expire -> mld_sendpack -> ... -> dhcp_xmit
    # and the vendor's oops guard reboots the guest, forever.
    #
    # Suppressing only dhcp0's IPv6 configuration removes the trigger: with no
    # link-local address there is no solicited-node group and so no MLD timer.
    # Measured against 2.6.32's addrconf.c/mcast.c, ipv6_add_dev() otherwise joins
    # only the all-nodes group, which mca_alloc() flags MAF_NOREPORT and
    # igmp6_group_added() skips -- so every other interface stays byte-identical,
    # and the IPv6 stack itself stays up.  Two blunter fixes were rejected:
    # `ipv6.disable=1` works but breaks the vendor's TAC/RADIUS proxy ("Address
    # family not supported by protocol"), and an in-module NULL guard does not fit
    # (dhcp_xmit's 18-byte window is pinned by two R_386_32 relocations, so a guard
    # that keeps the dev_dhcp->ifindex store needs 21 bytes).
    #
    # The write must stop before +0x0d so the stock 7-byte `movzx eax,[ebx+0xdc]`
    # -- the device type the ARPHRD switch dispatches on -- survives untouched: a
    # wider write that nops its tail leaves the switch running on the ASSERT_RTNL
    # helper's return value (0 or 1), so every device looks like ARPHRD_ETHER.
    # That is a silent IPv6-config change for non-Ethernet devices that no boot
    # test can see; only disassembly catches it.  13 bytes is what fits before
    # +0x0d -- too few for a full name test (10 bytes + a 2-byte branch + the
    # 5-byte jump = 17), so only dhcp0's first four name bytes are compared.
    #
    # The signature masks the 20 bytes the site spans but this entry writes only
    # 13, leaving +0x0d..+0x13 stock: a non-dhcp0 device takes `jne +0x05` to that
    # untouched `movzx` and runs the stock ARPHRD switch, while dhcp0 takes
    # `jmp +0x26` to the function's own epilogue at +0x33, configuring nothing.
    ("addrconf_dev_config_dhcp0",
     "??" * 20 + "6683f8017431663d0603742b663d200374256683f80790741e6683f82074188b",
     0, bytes.fromhex("813b64686370"     # cmp dword [ebx], "dhcp"
                      "7505"             # jne +0x05  -> +0x0d, the stock movzx
                      "e926000000"),     # jmp +0x26  -> +0x33, the epilogue (dhcp0)
     "addrconf_dev_config(): do not configure IPv6 on the vendor dhcp0 interface",
     0, "dhcp0_variant"),
    # The same fix for the releases whose compiler inlined addrconf_dev_config()
    # into addrconf_notify() instead of emitting it as a function: no prologue or
    # epilogue of its own, and everything from the stock `movzx eax,[ecx+0xdc]` on
    # is byte-identical to the standalone shape -- but the movzx sits at +0x14
    # here, not +0x0d.
    #
    # Geometry, and why the write is at +0x14.  The match starts at a `jne`'s rel32
    # (the instruction begins two bytes before it), so match+0x00..+0x03 are
    # displacement bytes and match+0x04 is that `jne`'s fall-through -- LIVE code
    # (`mov eax,[esp+0x18]`; `mov edx,ebx`; a call; a jmp).  The address the path
    # actually reaches is match+0x14, the ASSERT_RTNL call: on all five releases
    # exactly one branch (`je <match+0x14>` in the enclosing addrconf_notify)
    # targets it, and it is an instruction boundary.  The stock block there:
    #
    #   +0x00 call <ASSERT_RTNL helper>   } ASSERT_RTNL (result discarded;
    #   +0x05 test eax,eax                } addrconf_dev_config returns void) and
    #   +0x07 lea esi,[esi]               } its failure path
    #   +0x0a je  <WARN block>            }
    #   +0x10 mov ecx,[esp+0xc]           <- device pointer reloaded after the call
    #   +0x14 movzx eax,word [ecx+0xdc]   <- device type, STOCK, not touched
    #   +0x19 (stock ARPHRD dispatch)
    #
    # patch_off is 0x14 because that is the block the enclosing flow reaches.  A
    # write at match+0x00 is unreachable (nothing branches there): its first
    # instruction never runs, the `jne` fall-through lands mid-instruction, the
    # ASSERT block / reload / dispatch stay stock so dhcp0 is still configured, and
    # it clobbers the live code at +0x04..+0x13.
    #
    # The 20-byte replacement, ending exactly where the stock `movzx` begins:
    #
    #   +0x00 mov ecx,[esp+0xc]       } the device pointer, loaded HERE, not
    #                                 } assumed live in ecx
    #   +0x04 cmp dword [ecx],"dhcp"  }
    #   +0x0a jne +0x08               -> +0x14, the stock movzx (non-dhcp0)
    #   +0x0c nop; nop; nop           } pad, so the jump ENDS at +0x14
    #   +0x0f jmp match-0x6fd         <- dhcp0 leaves here, for the epilogue
    #   +0x14 (stock movzx: every other device enters here)
    #
    # ecx is loaded, not assumed: the compiler reloads the device pointer after the
    # call precisely because a call clobbers caller-saved registers, and whether
    # ecx holds it at the anchor is a property this byte-signature cannot check.
    # `mov ecx,[esp+0xc]` is the same instruction on the same esp that stock runs
    # at +0x10, so a non-dhcp0 device sees stock behaviour bit-for-bit.  Those 4
    # bytes leave room for only the first four name bytes (4 + 6 name-compare + 2
    # branch + 5 jump = 17; a fifth byte would need 23).  The `jne` must END at
    # +0x14 so a non-dhcp0 device enters the stock code on an instruction boundary
    # (the locator masks through +0x13 at width 20), which is why the pad precedes
    # the jump.
    #
    # dhcp0's exit is the inlined function's own epilogue at match-0x6fd, the `mov
    # eax,edx` after `mov edx,1` -- the jump skips `mov edx,1` and returns whatever
    # edx held (the caller ignores it: void).  Unlike every other jump this file
    # writes, the -0x725 displacement is a CONSTANT in the patch bytes, not one
    # re-derived from the match or pinned by the signature (which covers only
    # match+0 on): the epilogue sits 0x702 bytes before the match.  All five
    # inlined releases carry the same bytes there, so it is correct for them, and
    # inlined_dhcp0_landing_error() re-checks the landing before any write, so a
    # release with different geometry is refused rather than silently miswritten.
    #
    # The write also covers match+0x24, the stock `mov ecx,[esp+0xc]`, whose only
    # incoming branch is the ASSERT-failure WARN block's back-jump (`jmp
    # match+0x24`).  That is safe only because the WARN block's sole entry is the
    # `je +0x0a` this entry overwrites and the instruction before it is an
    # unconditional jmp: with the `je` gone the block is unreachable and its
    # back-jump never runs.  A release that showed a second entry into the block
    # would have to keep match+0x24 an instruction boundary (20 bytes cannot,
    # alongside the 5-byte back-jump) and would have to be escalated.
    #
    # Do NOT "simplify" the target to the caller's tail at match-0x4ba: ebp is live
    # there (`test ebp,ebp`/`je`, then `cmp [ebp+0x98],...`), so arriving runs IPv6
    # code for whatever ebp points at instead of returning.
    #
    # Size-neutral (20 for 20): the ASSERT block, its failure path and the device
    # reload are replaced by the name test and the exit; the stock `movzx` and
    # ARPHRD dispatch from +0x14 are untouched.  The signature's first four bytes
    # stay wildcards (the `jne`'s rel32), but match+0x04..+0x13 pin the live
    # fall-through (`mov eax,[esp+0x18]`, `mov edx,ebx`, a call, a jmp -- identical
    # across the five apart from the two masked displacements) the old entry used
    # to clobber.
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
    # Not patched: rks_pkt_trace_init().  Returning 0 there stops the vendor "tif0"
    # interface being created, which removes a rare cold-TCG-boot oops (tif_xmit
    # dereferences NULL when an MLD timer fires on the half-built interface; the
    # readiness deadline restarts the guest and the next boot usually wins the race).
    # The price is too high: with tif0 absent a restored configuration (WLANs, AP
    # groups) makes apmgr stop answering and the controller restarts about every
    # two minutes, on every release and under KVM.  Found by bisecting a restored
    # backup install; a factory install does not show it.
    #
    # tsc_read_refs() is native_calibrate_tsc()'s reference read: it samples the
    # TSC either side of one HPET (or PM-timer) read, and throws the sample away
    # when the two TSC reads are SMI_TRESHOLD = 50000 cycles (~15 us) or more apart,
    # on the theory that an SMI landed in between.  In a nested guest the HPET read
    # is an exit through two hypervisors and takes longer than that every time, so
    # every sample is discarded, calibration returns 0, tsc_init() marks the TSC
    # unstable and the guest clocks off the HPET instead -- an exit per ktime_get(),
    # which is the "idle guest burns half a core" report on a nested host (13% of a
    # core against 5% with a calibrated TSC, measured on the same nested host).
    # Raising the limit to 0xfffff cycles (~0.3 ms) admits those samples and still
    # rejects a real stall; calibration then succeeds ("TSC: using HPET reference
    # calibration").  On the lab's nested host the smallest limit that works lies
    # between 100000 and 150000 cycles, so 0xfffff leaves about 7x headroom for a
    # slower or busier host; one that still fails keeps today's HPET fallback.
    # The pinned bytes are `sub ecx,edi; sbb ebx,ebp; cmp ebx,0; ja;
    # cmp ecx,imm32; ja` -- the 64-bit "difference >= limit" test -- and the write is
    # the imm32 (0xc34f, 49999).  Direct KVM and TCG already end up on the TSC
    # without it (measured: clocksource tsc, 1.5% of a core idle on direct KVM and
    # 6% on TCG), so it changes nothing that matters there.
    #
    # An earlier version of this fix asked KVM for the frequency instead (it wrote
    # MSR 0x4b564d01 from a code cave and read a pvclock page).  That was exact but
    # KVM-only -- under TCG it replaced the stock PIT calibration with a failure and
    # left the guest on the HPET -- and it needed a page of guest RAM that nothing
    # reserves.  This is four bytes, runs wherever the guest does, and lands within
    # ~0.007% of the hypervisor's figure.
    ("tsc_read_refs_threshold",
     "29f919eb83fb00771581f94fc3000077",
     11, bytes.fromhex("ffff0f00"),
     "tsc_read_refs(): accept reference reads up to 0xfffff cycles apart (was 49999)",
     0, ""),
]

# Opt-in patches: left out of PATCHES unless named in ZD_KERNEL_OPT_IN (comma
# separated).  The two addrconf_dev_config dhcp0 shapes fix a crash-loop seen only on
# the abandoned VM path (the guest never reached READY).  The Docker and LXC flows
# never needed them, and they do harm there: with them applied, restoring a
# configured backup on every 9.x release (9.9.1, 9.10.2, 9.13.3) makes apmgr stop
# answering and the controller restart about every two minutes; without them, or on
# `main`, the same restore is stable.  Measured by swapping the kernel patcher and then
# removing just these two entries.  They stay in the table, with their tests, for a
# path that can show it needs them, and are enabled with
#   ZD_KERNEL_OPT_IN=addrconf_dev_config_dhcp0,addrconf_dev_config_dhcp0_inlined
OPT_IN_PATCHES = {"addrconf_dev_config_dhcp0", "addrconf_dev_config_dhcp0_inlined"}
_OPTED_IN = {n.strip() for n in os.environ.get("ZD_KERNEL_OPT_IN", "").split(",")}
PATCHES = [e for e in PATCHES if e[0] not in OPT_IN_PATCHES or e[0] in _OPTED_IN]

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


def locate_sites(payload: bytes):
    """The kernel table's sites in `payload` (see binpatch.locate_sites)."""
    return binpatch.locate_sites(payload, PATCHES)


# The one jump this file writes whose landing nothing else checks.  The inlined
# dhcp0 entry skips dhcp0 to the inlined function's epilogue with a *constant*
# displacement baked into its patch bytes (`e9 dbf8ffff`, -0x725, to match-0x6fd).
# Every other jump here is either re-derived from the match (rel32_exit) or
# lands inside the signature, where the normal site check pins it -- group-A's
# does, at match+0x33.  This one lands 0x702 bytes *before* the match, outside the
# signature entirely, so binpatch validates nothing about it: the write succeeds
# whatever is there.  All five inlined-shape releases carry `mov edx,1; mov
# eax,edx; mov ebx,[esp+0xf0]` at match-0x702, so the fixed jump is correct for
# them, but a release built with different inlined geometry would move the
# epilogue and the jump would land mid-instruction with no error -- the silent
# miswrite the comment history says was only ever caught by disassembly.  This
# guard re-checks the landing against the bytes the five share, so such a release
# is refused (escalated) rather than miswritten.
DHCP0_INLINED = "addrconf_dev_config_dhcp0_inlined"
DHCP0_INLINED_EPILOGUE_OFF = -0x702
DHCP0_INLINED_EPILOGUE = bytes.fromhex("ba0100000089d08b9c24f0000000")


def inlined_dhcp0_landing_error(payload: bytes):
    """Why the inlined dhcp0 patch's fixed jump would miss its epilogue in
    `payload`, or None.  None when the release does not carry the inlined shape
    (its site then has no match and there is no fixed jump to land)."""
    site = next((s for s in locate_sites(payload)[0]
                 if s.name == DHCP0_INLINED and len(s.hits) == 1), None)
    if site is None:
        return None
    off = site.hits[0] + DHCP0_INLINED_EPILOGUE_OFF
    found = bytes(payload[off:off + len(DHCP0_INLINED_EPILOGUE)])
    if found == DHCP0_INLINED_EPILOGUE:
        return None
    return (f"{DHCP0_INLINED}: the inlined epilogue at match{DHCP0_INLINED_EPILOGUE_OFF:#x} "
            f"(file 0x{off:x}) is {found.hex() or '(past end of image)'}, not "
            f"{DHCP0_INLINED_EPILOGUE.hex()}: this release's inlined geometry differs, "
            "so the patch's fixed -0x725 jump would not land on `mov eax,edx`.  "
            "Escalate this release rather than patching it.")


def self_test(vmlinux_path: str) -> int:
    """Check every PATCHES signature against a pristine kernel ELF.

    This is the offline half of the kernel-patch verification (see
    binpatch.self_test for what is checked); it needs no vendor material beyond
    the kernel ELF, so it can run on every change to PATCHES.

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
    print(f"self-test against {vmlinux_path} ({len(elf)} bytes)")
    failures = binpatch.self_test(elf, PATCHES, OPTIONAL_PATCHES, what="kernel")
    landing = inlined_dhcp0_landing_error(elf)
    if landing:
        print(f"  FAIL  {DHCP0_INLINED:32s} {landing}", file=sys.stderr)
        failures += 1
    elif any(s.name == DHCP0_INLINED and s.hits for s in locate_sites(elf)[0]):
        print(f"  ok    {DHCP0_INLINED:32s} fixed jump lands on the stock epilogue")
    if failures:
        print(f"self-test: {failures} failure(s)", file=sys.stderr)
        return 1
    print("self-test: all signatures locate exactly one site")
    return 0


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

    # Refuse before writing anything if this release carries the inlined dhcp0
    # shape but not at the geometry the fixed -0x725 jump assumes (see
    # inlined_dhcp0_landing_error): a miss there is a silent kernel corruption.
    landing = inlined_dhcp0_landing_error(payload)
    if landing:
        raise SystemExit(landing)

    elf = bytearray(payload)
    missing, _changed = binpatch.apply(elf, PATCHES)

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
