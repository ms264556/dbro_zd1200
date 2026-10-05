#!/usr/bin/env python3
"""Patch a vendor ELF binary out of the ZD1200 root filesystem.

patch-kernel.py patches the kernel inside its bzImage; this is the same
signature engine (binpatch.py) applied to a plain ELF file.  TARGETS maps a
rootfs path to its patch table, in the tuple format binpatch.py documents, so a
fix to a vendor daemon is located by the bytes around its site and lands on
every release that carries that site, wherever the linker put it.

A rootfs patch (scripts/container/patches/NN-*.sh) reads the file out of a root,
runs this on it, and writes the result back through patch-lib.sh, which keeps
the pristine vendor copy in the root's rollback store.

Every table here must degrade safely.  A release whose binary has no such site
is left byte-for-byte alone and reported, never refused: a root-filesystem patch
that exits non-zero aborts provisioning.  What IS refused is a signature that
matches more than once, or a site whose untouched bytes are not the stock bytes
the signature describes -- writing there would be a guess.

Usage:
  patch-file.py --target /bin/stamgr --in stamgr --out stamgr.patched
  patch-file.py --target /bin/stamgr --in stamgr --self-test
  patch-file.py --list-targets

Exit 0 when the output was written (patched, already patched, or no site in
this release), non-zero when the file is not what the table describes.
"""

import argparse
import sys
from pathlib import Path
from typing import NamedTuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import binpatch  # noqa: E402


class Target(NamedTuple):
    """One rootfs file: what to call it in messages, and its patch table."""
    what: str
    patches: list
    optional: frozenset


# --- /bin/stamgr -------------------------------------------------------------
# stamgr is the vendor station manager: client authentication, PMK/OKC caches,
# 802.11r handover.  Its one worker thread runs stamgr_event_wait(), a timer-
# plus-epoll loop:
#
#     for (;;) {
#         memset(events, 0, sizeof events);            /* 4096 * 12 = 0xC000 */
#         clock_gettime(CLOCK_MONOTONIC, &now);
#         t = <ms until the first timer on the sorted timer list>;
#         if (t > 2) t = 2;
#         n = epoll_wait(epfd, events, 4096, t);
#         <run every timer that is due>
#         for (i = 0; i < n; i++) <call the handler registered for events[i]>
#     }
#
# So an idle controller wakes this thread 500 times a second, and on each pass
# zeroes 49 KB with uClibc's memset -- a byte-wise `rep stosb`.  On hardware
# that is noise.  Under TCG it is most of what an idle guest costs: measured on
# 10.5.1.0.282 (-accel tcg, -smp 2, guest idle after READY, 60 s windows of the
# emulator's utime+stime), the emulator sat at 24-27% of one host core, 19.9%
# with the memset removed, and 6.1% with the cap raised as well -- the same
# 6.2% it measures with the thread SIGSTOPped.  The memset alone was 21-23% of
# the emulator's samples; the rest is the wakeup machinery (timer interrupt,
# idle exit, schedule, two syscalls, timer re-arm) 500 times a second.
#
# Why neither change alters behaviour, from the disassembly of the loop:
#
#   * The 2 ms is only a ceiling on the sleep.  The timeout is min(time to the
#     first timer, cap); the timer list is kept sorted by the registration
#     function, and a due timer is run right after epoll_wait returns.  A timer
#     due in 30 ms fires in 30 ms under either cap.  (On 10.x the registration
#     function rounds every expiry up to the next 100 ms as well, so 100 ms is
#     the daemon's own timer resolution there; 9.x keeps exact expiries, which
#     the min() honours just the same.)
#   * Socket handlers are called only for descriptors epoll_wait returned, so
#     nothing runs on a bare timeout: a message from an AP wakes the loop at
#     once, whatever the cap.
#   * Signals reach the loop through a pipe that is in the epoll set (the
#     handler runs in the main thread, which sits in pause(), and writes the
#     signal number), so they do not depend on the cadence either.
#   * The events array is read only for indices below epoll_wait's return
#     value, so nothing ever reads the bytes the memset zeroed.
#   * The one thing done every pass regardless is a debug-gated, once-a-second
#     append to /tmp/authorizing_info.txt (10.3 and later), which a 100 ms pass
#     still serves.
#
# Not covered by that reading: the individual handlers and timer callbacks were
# not audited, only how they are invoked; and the change has not been exercised
# with clients roaming between APs.
#
# The loop comes in three sizes across the nine supported releases (9.9;
# 9.10-10.2; 10.3-10.5 -- the later ones add the statistics append and a
# "no-wait timer" debug line), but both sites are byte-identical in all of
# them apart from the addresses masked below.

# The cap must fit the `cmp` imm8, which is sign-extended: 1..127.
STAMGR_IDLE_CAP_MS = 100
assert 2 < STAMGR_IDLE_CAP_MS <= 127

STAMGR_PATCHES = [
    # memset(events, 0, 0xC000) at the head of the loop -> a zero-length memset.
    # The call stays, so the frame and every later instruction are untouched;
    # only the length immediate changes.  The signature runs on into the second
    # memset (the 8-byte timespec the loop clears next), which is what ties this
    # push to the loop head rather than to any other 0xC000-byte clear.
    ("stamgr_event_memset",
     "83ec04"                       # sub  esp,4
     "6800c00000"                   # push 0xC000          <- patched
     "6a00"                         # push 0
     "8d85b43fffff"                 # lea  eax,[ebp-0xc04c]   (events)
     "50"                           # push eax
     "e8????????"                   # call memset
     "83c410"                       # add  esp,0x10
     "83ec04"                       # sub  esp,4
     "6a08"                         # push 8
     "6a00"                         # push 0
     "8d45b4"                       # lea  eax,[ebp-0x4c]     (timespec)
     "50",                          # push eax
     3, bytes.fromhex("6800000000"),
     "stamgr_event_wait(): do not zero the 49 KB epoll event buffer every pass",
     0, ""),
    # `if (timeout > 2) timeout = 2;` -> the same clamp at STAMGR_IDLE_CAP_MS.
    # Both immediates are written as one 13-byte patch so they cannot disagree.
    # The signature carries the code from the clamp to the epoll_wait call --
    # the empty-timer-list test, the two timeout stores, and the argument
    # pushes with maxevents 0x1000 and the same events buffer -- so it can only
    # be the timeout of this loop's epoll_wait.
    ("stamgr_event_wait_cap",
     "8945cc"                       # mov  [ebp-0x34],eax     (timeout)
     "837dcc02"                     # cmp  dword [ebp-0x34],2 <- patched
     "7e07"                         # jle  +7                 <- (unchanged)
     "c745cc02000000"               # mov  dword [ebp-0x34],2 <- patched
     "a1????????"                   # mov  eax,[timer_list]
     "3d????????"                   # cmp  eax,&timer_list
     "740b"                         # je   -> timeout 0 (no timers)
     "8b5dcc"                       # mov  ebx,[ebp-0x34]
     "899d983fffff"                 # mov  [ebp-0xc068],ebx
     "eb0a"                         # jmp
     "c785983fffff00000000"         # mov  dword [ebp-0xc068],0
     "a1????????"                   # mov  eax,[ctx]
     "8b5004"                       # mov  edx,[eax+4]        (epfd)
     "ffb5983fffff"                 # push dword [ebp-0xc068] (timeout)
     "6800100000"                   # push 0x1000             (maxevents)
     "8d85b43fffff"                 # lea  eax,[ebp-0xc04c]   (events)
     "50"                           # push eax
     "52"                           # push edx
     "e8????????",                  # call epoll_wait
     3, bytes([0x83, 0x7d, 0xcc, STAMGR_IDLE_CAP_MS,
               0x7e, 0x07,
               0xc7, 0x45, 0xcc, STAMGR_IDLE_CAP_MS, 0x00, 0x00, 0x00]),
     f"stamgr_event_wait(): cap the idle epoll timeout at "
     f"{STAMGR_IDLE_CAP_MS} ms instead of 2 ms",
     0, ""),
]

TARGETS = {
    "/bin/stamgr": Target("stamgr", STAMGR_PATCHES,
                          frozenset({"stamgr_event_memset",
                                     "stamgr_event_wait_cap"})),
}


def read_elf(path: str) -> bytes:
    """The file's bytes, refusing anything that is not a 32-bit ELF."""
    p = Path(path)
    if not p.exists():
        raise SystemExit(f"{path} not found")
    data = p.read_bytes()
    if not data.startswith(b"\x7fELF") or data[4:5] != b"\x01":
        raise SystemExit(f"{path} is not a 32-bit ELF")
    return data


def self_test(target: Target, path: str) -> int:
    """Offline signature check of `target`'s table against a pristine file."""
    elf = read_elf(path)
    print(f"self-test against {path} ({len(elf)} bytes)")
    failures = binpatch.self_test(elf, target.patches, target.optional,
                                  what=target.what)
    if failures:
        print(f"self-test: {failures} failure(s)", file=sys.stderr)
        return 1
    print("self-test: every signature that matches locates exactly one site")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--target", help="rootfs path of the file (a key of TARGETS)")
    ap.add_argument("--in", dest="src", help="the file as read out of the root")
    ap.add_argument("--out", dest="out", help="where to write the patched file")
    ap.add_argument("--self-test", action="store_true",
                    help="offline signature check against a pristine --in: every "
                         "patch that matches must locate exactly one site inside "
                         "its own match and must not already be applied.  Writes "
                         "nothing.")
    ap.add_argument("--list-targets", action="store_true",
                    help="print the rootfs paths this tool has a table for")
    args = ap.parse_args()

    if args.list_targets:
        for path in TARGETS:
            print(path)
        return 0
    if args.target not in TARGETS:
        ap.error(f"--target must be one of: {', '.join(TARGETS)}")
    target = TARGETS[args.target]
    if not args.src:
        ap.error("--in is required")
    if args.self_test:
        return self_test(target, args.src)
    if not args.out:
        ap.error("--out is required")

    elf = bytearray(read_elf(args.src))
    print(f"{args.target}: {len(elf)} bytes")
    missing, changed = binpatch.apply(elf, target.patches)
    required_missing = [m for m in missing if m not in target.optional]
    if required_missing:
        raise SystemExit(
            f"missing patches for this release: {', '.join(required_missing)}")
    if missing:
        print(f"note: patches not applicable to this release (skipped): "
              f"{', '.join(missing)}")
    Path(args.out).write_bytes(bytes(elf))
    print(f"wrote {args.out} ({len(elf)} bytes, "
          f"{'patched' if changed else 'unchanged'})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
