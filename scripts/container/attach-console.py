#!/usr/bin/env python3
"""Attach to the ZD1200 guest's interactive serial console.

The container runs QEMU with the guest's primary serial (ttyS0, the console the
stock /etc/inittab runs `/bin/login.sh` on) forwarded to a QEMU chardev socket.
This script bridges your local terminal to that socket so you can log into the
ZD1200 CLI from the host.

Run it inside the container (it needs to reach the unix socket in /tmp):

    sudo docker exec -it zd1200 python3 /opt/zd1200/attach-console.py

A path argument overrides the socket (default /tmp/zd1200-console.sock).  It
works whether or not the socket is a unix socket or a host:port TCP listener
(e.g. 127.0.0.1:5555); pass the latter directly as the argument.

Ctrl-C (sometimes twice) detaches; the guest keeps running.
"""
import os
import select
import socket
import sys
import termios
import tty


def connect_to(target: str) -> socket.socket:
    """target is either a unix socket path (contains '/') or host:port."""
    if "/" in target:
        path = target
        if not os.path.exists(path):
            sys.exit(f"console socket not found: {path}")
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.connect(path)
        except OSError as exc:
            sys.exit(f"connect {path} failed: {exc}")
    else:
        host, _, port = target.rpartition(":")
        if not host or not port:
            sys.exit(f"bad socket target (want unix path or host:port): {target}")
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.connect((host, int(port)))
        except OSError as exc:
            sys.exit(f"connect {target} failed: {exc}")
    return s


def main() -> None:
    target = sys.argv[1] if len(sys.argv) > 1 else "/tmp/zd1200-console.sock"
    s = connect_to(target)
    print(f"attached to {target}; Ctrl-C to detach.", file=sys.stderr)

    fd = sys.stdin.fileno()
    saved = None
    try:
        saved = termios.tcgetattr(fd)
        tty.setraw(fd)
    except (termios.error, OSError):
        saved = None  # not a TTY (piped input); degrade gracefully

    try:
        while True:
            rlist, _, _ = select.select([s, sys.stdin], [], [])
            if s in rlist:
                data = s.recv(4096)
                if not data:
                    break
                os.write(sys.stdout.fileno(), data)
                sys.stdout.flush()
            if sys.stdin in rlist:
                data = os.read(fd, 4096)
                if not data:
                    break
                s.sendall(data)
    except (KeyboardInterrupt, OSError):
        pass
    finally:
        if saved is not None:
            termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        s.close()

    if os.isatty(sys.stdout.fileno()):
        sys.stdout.write("\r\n[detached from console]\r\n")


if __name__ == "__main__":
    main()
