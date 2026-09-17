#!/usr/bin/env python3
"""Unit-test proxmox/zd1200-ct-address without touching real interfaces.

The helper is run with fake `ip`, `dhclient` and `pkill` on its PATH, backed by a
tiny JSON file that plays the bridge's addresses and default route.  That covers
the whole lifecycle -- acquire, idempotent acquire, release, re-acquire, and the
static/recorded fallbacks -- on any machine.

    python3 scripts/test/ct-address-test.py
"""
import json
import os
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HELPER = os.path.join(REPO, "proxmox", "zd1200-ct-address")

IP_FAKE = r'''#!/usr/bin/env python3
import json, os, sys

path = os.environ["FAKE_IP_STATE"]

def load():
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return {"addr": [], "default": ""}

def save(state):
    with open(path, "w") as fh:
        json.dump(state, fh)

a = [x for x in sys.argv[1:] if x not in ("-4", "-o", "-json")]
s = load()

if a[:2] == ["addr", "show"]:
    dev = a[a.index("dev") + 1] if "dev" in a else ""
    for cidr in s["addr"]:
        print("1: %s    inet %s scope global %s" % (dev, cidr, dev))
    sys.exit(0)
if a[:2] == ["addr", "replace"]:
    if a[2] not in s["addr"]:
        s["addr"].append(a[2])
    save(s)
    sys.exit(0)
if a[:2] == ["addr", "flush"]:
    s["addr"] = []
    save(s)
    sys.exit(0)
if a[:1] == ["route"]:
    if "show" in a:
        if s.get("default"):
            print("default via %s dev br-zd" % s["default"])
        sys.exit(0)
    if "replace" in a and "default" in a:
        s["default"] = a[a.index("via") + 1]
        save(s)
        sys.exit(0)
    if "del" in a:
        s["default"] = ""
        save(s)
        sys.exit(0)
sys.exit(0)
'''

DHCLIENT_FAKE = r'''#!/usr/bin/env python3
import json, os, sys

path = os.environ["FAKE_IP_STATE"]

def load():
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return {"addr": [], "default": ""}

def save(state):
    with open(path, "w") as fh:
        json.dump(state, fh)

a = sys.argv[1:]
if os.environ.get("FAKE_DHCLIENT_FAIL") == "1":
    sys.exit(2)
if "-r" in a:
    s = load()
    s["addr"] = []
    save(s)
    sys.exit(0)
s = load()
addr = os.environ.get("FAKE_DHCLIENT_ADDR", "192.0.2.50/24")
if addr not in s["addr"]:
    s["addr"].append(addr)
s["default"] = os.environ.get("FAKE_DHCLIENT_GW", "192.0.2.1")
save(s)
for i, x in enumerate(a):
    if x == "-pf":
        with open(a[i + 1], "w") as fh:
            fh.write(str(os.getpid()))
sys.exit(0)
'''

PKILL_FAKE = "#!/bin/sh\nexit 0\n"

failures = []


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}: {name}{(' -- ' + detail) if detail else ''}")
    if not ok:
        failures.append(name)


class Fixture:
    def __init__(self, tmp):
        self.tmp = tmp
        self.bin = os.path.join(tmp, "bin")
        os.makedirs(self.bin, exist_ok=True)
        self._write("ip", IP_FAKE)
        self._write("dhclient", DHCLIENT_FAKE)
        self._write("pkill", PKILL_FAKE)
        self.ip_state = os.path.join(tmp, "ip.json")
        self.conf_state = os.path.join(tmp, "zd1200-net.address")

    def _write(self, name, body):
        path = os.path.join(self.bin, name)
        with open(path, "w") as fh:
            fh.write(body)
        os.chmod(path, 0o755)

    def run(self, *args, **extra):
        env = dict(os.environ)
        env.update({
            "PATH": self.bin + os.pathsep + env["PATH"],
            "FAKE_IP_STATE": self.ip_state,
            "ZD_BRIDGE_IF": "br-zd",
            "ZD_CT_DHCP": "1",
            "ZD_CT_ADDRESS_STATE": self.conf_state,
            "ZD_CONFIG_FILE": os.path.join(self.tmp, "does-not-exist.conf"),
            "ZD_DHCLIENT_PID": os.path.join(self.tmp, "dhclient.pid"),
            "ZD_DHCLIENT_LEASE": os.path.join(self.tmp, "dhclient.leases"),
            "ZD_CT_ADDRESS_TIMEOUT": "5",
        })
        env.pop("ZD_CT_ADDRESS", None)
        env.update(extra)
        return subprocess.run([HELPER, *args], env=env, capture_output=True, text=True)

    def addrs(self):
        try:
            with open(self.ip_state) as fh:
                return json.load(fh)["addr"]
        except Exception:
            return []

    def default(self):
        try:
            with open(self.ip_state) as fh:
                return json.load(fh).get("default", "")
        except Exception:
            return ""


def main():
    with tempfile.TemporaryDirectory(prefix="zd-ct-address-test.") as tmp:
        fx = Fixture(tmp)

        r = fx.run("status")
        check("status is 1 with no address", r.returncode == 1, f"rc={r.returncode}")

        r = fx.run("up")
        check("up acquires a lease", r.returncode == 0 and fx.addrs() == ["192.0.2.50/24"],
              f"rc={r.returncode} addrs={fx.addrs()}")
        check("up installs the default route", fx.default() == "192.0.2.1", fx.default())
        with open(fx.conf_state) as fh:
            recorded = fh.read()
        check("up records the address and gateway",
              "ADDRS=192.0.2.50/24" in recorded and "GATEWAY=192.0.2.1" in recorded,
              recorded.replace("\n", " "))

        r = fx.run("up")
        check("up is idempotent while up", r.returncode == 0 and fx.addrs() == ["192.0.2.50/24"],
              f"addrs={fx.addrs()}")

        r = fx.run("status")
        check("status prints the address", r.returncode == 0 and "192.0.2.50/24" in r.stdout,
              repr(r.stdout))

        r = fx.run("down")
        check("down releases the address", r.returncode == 0 and fx.addrs() == [],
              f"addrs={fx.addrs()}")
        check("down removes the default route", fx.default() == "", fx.default())
        check("down is idempotent", fx.run("down").returncode == 0 and fx.addrs() == [])

        r = fx.run("up")
        check("up re-acquires after down", fx.addrs() == ["192.0.2.50/24"], f"addrs={fx.addrs()}")

        # static fallback: no DHCP, an address configured
        fx.run("down")
        r = fx.run("up", ZD_CT_DHCP="0", ZD_CT_ADDRESS="10.9.9.9/24")
        check("up falls back to the static address",
              r.returncode == 0 and fx.addrs() == ["10.9.9.9/24"], f"addrs={fx.addrs()}")

        # recorded fallback: no DHCP client success, no static address
        fx.run("down")
        with open(fx.conf_state, "w") as fh:
            fh.write("ADDRS=172.16.0.9/24\nGATEWAY=172.16.0.1\n")
        r = fx.run("up", ZD_CT_DHCP="0", FAKE_DHCLIENT_FAIL="1")
        check("up falls back to the recorded address",
              r.returncode == 0 and fx.addrs() == ["172.16.0.9/24"], f"addrs={fx.addrs()}")

        # a failing DHCP client with a static address must still come up
        fx.run("down")
        r = fx.run("up", ZD_CT_ADDRESS="10.1.1.1/24", FAKE_DHCLIENT_FAIL="1")
        check("up survives a failing dhclient when static is set",
              r.returncode == 0 and "10.1.1.1/24" in fx.addrs(), f"addrs={fx.addrs()}")

    print("----")
    if failures:
        print(f"FAILURES: {failures}")
        return 1
    print("ALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
