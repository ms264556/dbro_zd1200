#!/usr/bin/env python3
"""Reboot the ZD1200 guest from its serial console.

`boot-test.sh --reboot` uses this after the guest has reached its milestone: it
connects to QEMU's serial chardev socket, drives the appliance console to a root
shell, and runs `reboot` so the caller can watch the kernel's machine_restart
path reset the machine.

The console is tinylogin (`/bin/login -> tinylogin`, run from /etc/inittab on
ttyS0) and authenticates against /etc/passwd + /etc/shadow.  The stock shadow
carries `rkscli` with an empty password; that account's shell is the ZD1200 CLI,
whose `!v54!` escape drops to the OS shell.  Patch 30 replaces the escape's
passphrase helper with an exit-0 stub, so any passphrase is accepted.  If a
release gives a plain shell instead, that is used directly.

Every byte read is echoed to stdout so the caller can log what happened.

Usage: console-reboot.py <console-socket>

Exit 0 once `reboot` has been sent; 1 if no shell prompt appeared in time.
"""

from __future__ import annotations

import os
import re
import socket
import sys
import time

SHELL_PROMPT = re.compile(rb"[#$] ?$")
LOGIN_PROMPT = re.compile(rb"(login|username)\s*:\s*$", re.I)
PASSWORD_PROMPT = re.compile(rb"[Pp]assword\s*:\s*$")
CLI_PROMPT = re.compile(rb"[>#] ?$")
# A factory-fresh appliance (with a freshly seeded /writable) offers the setup
# wizard on the console before it will show a login prompt.
WIZARD_PROMPT = re.compile(rb"setup wizard\?|\[yes/no\]", re.I)
# The `!v54!` escape's passphrase is irrelevant: patch 30 makes the helper
# always exit 0, so any non-empty word works.
ESCAPE = "!v54! zd1200\r"
# Console accounts to try, in order.  ZD_CONSOLE_USER / ZD_CONSOLE_PASSWORD (set
# on boot-test.sh's environment) name the appliance account directly; the
# built-in fallbacks are the stock shadow accounts, whose passwords are empty.
CREDS = []
if os.environ.get("ZD_CONSOLE_USER"):
    CREDS.append((os.environ["ZD_CONSOLE_USER"],
                  os.environ.get("ZD_CONSOLE_PASSWORD", "")))
CREDS += [("admin", "admin"), ("rkscli", ""), ("root", "")]


class Console:
    """A tolerant reader/writer over the QEMU serial socket."""

    def __init__(self, path: str) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(0.5)
        self.sock.connect(path)
        self.buf = b""

    def send(self, text: str) -> None:
        sys.stderr.write(f"\n>>> {text!r}\n")
        sys.stderr.flush()
        self.sock.sendall(text.encode())

    def drain(self, seconds: float) -> None:
        """Read for up to `seconds`, echoing to stdout."""
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            try:
                chunk = self.sock.recv(4096)
            except socket.timeout:
                continue
            if not chunk:
                return
            sys.stdout.write(chunk.decode("latin-1"))
            sys.stdout.flush()
            self.buf = (self.buf + chunk)[-4096:]

    def wait_for(self, pattern: re.Pattern, seconds: float) -> bool:
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if pattern.search(self.buf):
                return True
            self.drain(0.5)
        return pattern.search(self.buf) is not None


def escape_to_shell(con: Console) -> bool:
    """At a CLI prompt, run the !v54! escape and look for a shell prompt."""
    con.send(ESCAPE)
    con.buf = b""
    con.drain(2.0)
    return con.wait_for(SHELL_PROMPT, 3.0)


def to_shell(con: Console, deadline: float) -> bool:
    """Drive the console to a shell prompt, or give up when `deadline` passes."""
    con.send("\r\n")
    con.drain(2.0)
    while time.monotonic() < deadline:
        if con.wait_for(SHELL_PROMPT, 1.0):
            return True
        # Decline the factory setup wizard so the login prompt appears.
        if WIZARD_PROMPT.search(con.buf):
            con.send("no\r")
            con.buf = b""
            con.drain(3.0)
            continue
        # A CLI prompt without a login prompt: try the shell escape directly.
        if CLI_PROMPT.search(con.buf) and not LOGIN_PROMPT.search(con.buf):
            if escape_to_shell(con):
                return True
        for user, password in CREDS:
            if not con.wait_for(LOGIN_PROMPT, 2.0):
                break
            sys.stderr.write(f"\nconsole-reboot: trying account {user!r}\n")
            con.send(user + "\r")
            con.buf = b""
            if con.wait_for(PASSWORD_PROMPT, 5.0):
                con.send(password + "\r")
                con.buf = b""
                con.drain(2.0)
            if con.wait_for(SHELL_PROMPT, 3.0):
                return True
            if CLI_PROMPT.search(con.buf) and escape_to_shell(con):
                return True
        con.send("\r\n")
        con.drain(1.0)
    return False


def main() -> int:
    if len(sys.argv) != 2:
        sys.exit("usage: console-reboot.py <console-socket>")
    con = Console(sys.argv[1])
    try:
        if not to_shell(con, time.monotonic() + 120.0):
            sys.stderr.write("\nconsole-reboot: no shell prompt appeared\n")
            return 1
        sys.stderr.write("\nconsole-reboot: shell reached, sending reboot\n")
        con.send("reboot\r")
        con.drain(3.0)
        return 0
    finally:
        con.sock.close()


if __name__ == "__main__":
    sys.exit(main())
