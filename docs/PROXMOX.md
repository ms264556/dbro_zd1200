# ZD1200 on Proxmox VE (LXC)

Detail behind `install-zd1200-lxc.sh`. For the quick start, see
[../README.md](../README.md).

The appliance runs in a **Proxmox LXC container** rather than Docker: the
container carries the project's toolchain and rootfs-patch pipeline directly, and
the guest joins your LAN as an ordinary Layer-2 device with its own MAC and DHCP
lease — reachable from the Proxmox host, from the container, and from any other
machine on the LAN.

If you already run the Docker flavour, nothing here changes it: `install-zd1200-docker.sh`
and `docker/` are unaffected.

## Requirements

- Proxmox VE 8.2+ (the installer uses the `dev0:` device-passthrough syntax; a
  privileged CT works on older versions as well).
- A Debian 13 LXC template. The installer fetches one itself if you have none
  (`pveam download local debian-13-standard_...`); Debian 13 is required because
  the guest needs QEMU's `igb` NIC model, which Debian 12's QEMU 7.2 lacks. If
  you pass a template that cannot work, the install stops before provisioning
  rather than leaving a container that boot-loops.
- `/dev/kvm` on the host for sensible boot times (the wizard warns when it is
  missing and falls back to TCG).
- A bridge with your LAN uplink, normally `vmbr0`.
- One of the firmware/CF-dump inputs described in the top-level `README.md`.

## Quick start

As root on the Proxmox host:

```sh
git clone https://github.com/ms264556/dbro_zd1200
cd dbro_zd1200
./install-zd1200-lxc.sh /path/to/zd1200_10.5.1.0.282.ap_10.5.1.0.282.img
```

The wizard asks as little as it can:

1. **Which input** — it lists the firmware/dump files it finds on the host (PVE
   storages, `/root`, `/root/zd-inputs`), classifies each, and offers a path
   entry and an "Advanced" entry.
2. **Which bridge** — only when the host has more than one, because that decides
   which LAN the guest and your access points join. The menu shows each bridge's
   address and flags the one carrying the default route.
3. **Confirm** — a summary of everything that will be created, including the
   defaults it chose (CT ID, hostname, storage, cores, memory, disk, the optional
   pieces) and the guest's MAC.

Everything not asked has a default derived from the host: CT ID (first free),
hostname `zd1200`, storage (first with room), Debian 13 template (fetched if
absent), DHCP, ECDSA host key, Network Monitor and the R600 repair on, and:

| size | default | why |
|---|---|---|
| cores | 4 | the guest itself is `-smp 1`; the rest is headroom for QEMU's I/O and the guest's own threads |
| memory | 4096 MiB | the guest's QEMU is configured for 2048 MiB, plus QEMU and the `debugfs`/`dd` work on the images; 4 GiB is the tested floor |
| disk | 20 GiB | userland + QEMU ~0.5, prepared artifacts ~1.1, the synthetic CF ~1.9 and briefly duplicated while built (a CF-dump build also extracts a writable); thin storage only allocates what is used | `--advanced` asks for those, and every one is a flag
(`--help`).

Then it creates the container, copies the project in, installs packages, decrypts
the firmware, builds the payloads, builds and patches the guest disk, installs the
systemd units, starts the appliance and waits for the guest's `READY` marker.

Unattended installs are supported:

```sh
./install-zd1200-lxc.sh \
    --ctid 120 --hostname zd1200 --storage local-lvm --bridge vmbr0 \
    --source /root/zd-inputs/zd1200_10.5.1.0.282.ap_10.5.1.0.282.img \
    --root-ssh-key ~/.ssh/id_ed25519.pub \
    --yes --non-interactive
```

`./install-zd1200-lxc.sh --help` lists every flag, including
`--writable-from` for reviving a foreign card's `/writable` (see
"Reviving a foreign /writable" in `docs/INTERNALS.md`) and `--no-*` switches for
the optional pieces.

## Reaching the appliance

Inside the container:

```sh
pct exec 120 -- cat /var/lib/zd1200/guest-ip      # the guest's DHCP lease
pct exec 120 -- tail -f /tmp/zd1200-console.log   # guest serial console
pct exec 120 -- python3 /opt/zd1200/scripts/container/attach-console.py
```

Open `https://<guest-ip>/` from any LAN machine. The first boot runs the factory
setup wizard; complete it, reboot the guest once so it generates its SSH host
key, then log in. The Proxmox host itself can reach the guest (unlike the Docker
macvtap setup) — `curl -kI https://<guest-ip>/admin10/login.jsp`.

With `--root-ssh-key`: `ssh -p 2222 -i <key> root@<guest-ip>`.

### The Console tab shows the guest, not the container

The Proxmox web **Console** tab for an LXC container runs `lxc-console -n <id>`
(PVE's default `cmode=tty`, with no `-t`), and `lxc-console` attaches to the
container's first tty that no other console client already holds — `/dev/tty1`.
The installer therefore hands `/dev/tty1` to the guest's serial console:

- `container-getty@1` is masked, so no login prompt is printed on tty1.
- `zd1200-console-tty.service` runs `proxmox/zd1200-console-bridge.py` with
  `TTYPath=/dev/tty1`, relaying between that tty and QEMU's console chardev.

Opening the tab now lands on the appliance's own login prompt, the same one the
physical box shows on its serial port, and typing there drives the appliance —
the tab is a full interactive console, not a read-only log.

Three details make this work, and they are why it is a bridge rather than
"run QEMU with `-nographic`":

- **QEMU's console chardev serves exactly one client.** Against the QEMU in a
  Debian 13 container (10.0.x) a second connection is accepted but never
  answered, and there is no `max_connections` option to raise. The bridge is
  that single client and re-serves the public `/tmp/zd1200-console.sock`, so the
  documented `attach-console.py` keeps working beside the web tab.
- **The console log stays QEMU's.** QEMU itself appends every guest byte to
  `/tmp/zd1200-console.log` (the file the entrypoint's READY probe and the
  troubleshooting commands read). The bridge only reads the socket; it changes
  nothing about the log, the `ttyS1` control channel, the health checks or the
  watchdog.
- **The tty is written non-blockingly.** Its pty buffer is drained only while a
  console client is attached, so a blocking write would stall the guest-console
  feed whenever nobody has the tab open (measured). The bridge drops bytes that
  do not fit; the log remains the complete record.

The container keeps its own getty on `/dev/tty2` (`lxc-console -n <id> -t 2` from
the host). `pct enter` and `pct exec` use `lxc-attach` and no console tty at all,
so none of this affects container debugging.

Pass `--no-console-tty` to the installer (or bootstrap) to leave tty1 as a
container login prompt instead; QEMU then keeps binding the public socket and
`attach-console.py` behaves exactly as before.

While a tab has never been opened, the bridge's output sits in the tty's buffer;
if it looks stale, press Enter and the guest reprints its prompt.

### The guest's address in the Proxmox GUI

The container is an implementation detail; the appliance is the guest, so the
guest's address is the one worth showing. Two things put it there:

- **`zd0`, a display interface.** The guest's address is held locally on a dummy
  interface (`ZD_DISPLAY_IF`, default `zd0`) purely so Proxmox can display it.
  Proxmox reads the container's addresses from its network namespace and shows
  **the first two it finds, in interface order** — so `zd1200-ct-net.sh` creates
  `zd0` *before* `br-zd`, which makes the guest's address enumerate first. IPv6
  is disabled on the container's interfaces for the same reason: a link-local
  address would otherwise take one of the two slots.
- **`zd1200-guest-display`, run by the healthcheck every 60s.** The guest's
  address is a DHCP lease and can change on renewal, so the displayed value is
  reconciled rather than set once, and re-asserted as an atomic `/32` replace so
  a change never leaves two addresses behind or a stale one displayed.

Two consequences are deliberate:

- While the address is held locally, **the container cannot itself reach the
  guest at that address** (the kernel answers locally). Nothing needs it to: the
  container's channel to the guest is the serial control port, not IP.
- **The container answers ARP for its own address only.** `zd1200-ct-net.sh`
  sets `arp_ignore=1`/`arp_announce=2` (persisted to
  `/etc/sysctl.d/99-zd1200-display.conf`) so the guest remains the only thing
  that answers for its address. Without this, holding the address locally would
  put two machines on the LAN answering for it — an outage, not a display bug.
  Note `ip link set ... arp off` does **not** prevent this; it only sets the
  `NOARP` flag.

The container keeps its own address, which is what the installer needs for `apt`
and `git`; it shows second. To hide it, see "The container's own address" in
`docs/TROUBLESHOOTING.md`.

### The container's own address

The container keeps an address of its own for maintenance only — `apt`, `git
pull`, an operator shell. Nothing that runs alongside the guest needs it: the
patch pipeline is local, and the healthcheck, watchdog and display helpers use
the guest's serial control channel rather than IP. So by default the container
gives that address back for as long as the appliance runs:

- `zd1200.service` runs `zd1200-ct-address down` just before it starts QEMU, and
  `up` again when QEMU exits (including the "guest powered off, container stays
  up" case).
- While the guest runs, the container-side bridge (`br-zd`) holds no address, so
  the appliance is the only thing on the LAN with one and the Summary shows only
  the guest.
- Reacquiring is always a **fresh DHCP transaction**, never the remembered
  address: the LAN's DHCP server may have handed it to somebody else while the
  guest was up (observed — the same container came back on a different address,
  and nothing renews the lease PVE originally moved onto the bridge).

The trade-off is deliberate: while the guest runs the container has **no
address**, so `apt`, `git pull` and `ssh` into it do not work. Ask for one on
demand, without touching the appliance:

```sh
pct exec <id> -- zd1200-ct-address up      # acquire now (a fresh lease)
pct exec <id> -- zd1200-ct-address status  # what it currently holds
pct exec <id> -- zd1200-ct-address down    # hand it back
```

A manual `up` lasts until the next `zd1200.service` (re)start, which releases it
again. `pct exec` and `pct enter` use `lxc-attach` and need no address at all.

Pass `--keep-ct-address` to the installer (or bootstrap) to keep the old
behaviour: the address stays up whenever the container is up.

## Safeguards

Three independent mechanisms keep a bad guest from going unnoticed, and they cover
different failure modes:

| mechanism | catches | behaviour |
|---|---|---|
| `ZD_GUEST_WATCHDOG` (default on) | the guest wedging inside QEMU | the timer probes the guest; after 5 consecutive failures it reboots it over the guest control channel, then waits a 15-minute cooldown |
| `ZD_CPU_GUARD` (default 24) | a guest spinning at 100% CPU | the entrypoint stops QEMU after 120s of continuous >95% CPU; systemd restarts the stack, which reboots the guest |
| the installer's QEMU pre-flight | a template whose QEMU cannot run the guest | aborts the install **before** the container can enter a boot loop |

Each healthcheck probe uses the **serial control channel and nothing else**. It
asks the guest two questions in one round trip — its current address, and whether
its management service is answering — and the guest performs that service check
on itself with a real HTTPS request to `127.0.0.1` (`/bin/curl` is on the
appliance).

The container deliberately does not probe the guest over the network, for two
reasons. The guest's address is held locally on the display interface so Proxmox
can show it, and an address held locally is answered by this container rather
than the guest — so an ARP or ICMP probe from here tests the container's own
stack and passes even when the guest is dead. And the appliance is the authority
on itself: it knows whether its web service answers, on whatever address and
family it chose to bind. A reply on ttyS1 also proves the guest's kernel, init
and userspace are all still running, because that channel is private and
non-networked.

**Why these exist.** The appliance can wedge solid: QEMU stays running (so Proxmox
still reports the VM as up) while the guest kernel stops answering, its NIC goes
silent, and every LAN address for it goes dark. A container that judges health by
a line in the serial log — which never leaves the log — reports healthy forever
while the appliance is dead. These three turn that into a self-healing event.

Probe it by hand any time:

```sh
pct exec <id> -- /usr/local/sbin/zd1200-guest-healthcheck    # exit 0 = the guest answers
pct exec <id> -- /usr/local/sbin/zd1200-guest-address        # prints its current address
pct exec <id> -- journalctl -u zd1200-watchdog -f            # recovery decisions
```

Tuning is in `/etc/zd1200.conf` inside the container: `ZD_GUEST_WATCHDOG=0`
disables recovery, `ZD_GUEST_WATCHDOG_FAILURES` and `..._COOLDOWN` change its
patience, and `ZD_CPU_GUARD=0` disables the CPU guard.

## Managing the container

| task | command |
|---|---|
| status | `systemctl status zd1200` inside the CT |
| follow logs | `journalctl -fu zd1200` inside the CT |
| stop the guest cleanly | `systemctl stop zd1200` (up to 5 minutes: the guest flushes `/writable`) |
| start | `systemctl start zd1200` |
| reboot the CT | `pct reboot <id>` |
| console | `pct enter <id>` |

The guest is a QEMU process inside the CT, supervised by `zd1200.service`. The
unit stops the guest through the same orderly path the Docker entrypoint uses
(ttyS1 control channel, then the guest's stock reboot), so `pct stop` and host
shutdown do not corrupt `/writable`.

## How it fits together

```
Proxmox host
└── LXC container (Debian)
    ├── eth0 ──────────────┐            (a port of the LAN bridge, no address)
    ├── br-zd ─────────────┘            (container's own address lives here)
    │   └── tap-zd ──────── QEMU guest  (guest MAC + DHCP lease on the LAN)
    ├── zd0                              (the guest's address, for display only)
    ├── tty1 ── console bridge ─┐        (the Proxmox Console tab lands here)
    │                           └──────  QEMU guest ttyS0 (the ZD1200 console)
    ├── tty2                             (container's own login prompt)
    ├── /opt/zd1200                     repo checkout (scripts, patches)
    ├── /var/lib/zd1200/image           decrypted vendor artifacts
    ├── /var/lib/zd1200/synthetic-cf.img  the live guest disk (flat, no overlay)
    └── /etc/zd1200.conf                runtime settings for zd1200.service
```

- `install-zd1200-lxc.sh` — runs on the PVE host: whiptail wizard, `pct`
  plumbing, copies the project in and invokes the bootstrap.
- `proxmox/zd1200-ct-bootstrap.sh` — runs **inside** the CT: packages, payload
  builds, vendor-image preparation, guest-disk preparation, systemd units.
- `proxmox/zd1200-ct-net.sh` — runs inside the CT as `zd1200-net.service`:
  bridges the uplink, moves the CT's address onto the bridge, and creates the
  display interface ahead of it.
- `proxmox/zd1200-guest-display` — keeps the guest's (lease-derived) address on
  the display interface so the Proxmox Summary shows it.
- `proxmox/zd1200-console-bridge.py` — runs inside the CT as
  `zd1200-console-tty.service` with its stdio on `/dev/tty1`: relays the guest's
  ttyS0 between the container console tty and the public console socket, so the
  Proxmox Console tab is the appliance's serial console (see "The Console tab"
  above).
- `proxmox/zd1200-ct-address` — holds or releases the container's own LAN
  address. `zd1200.service` calls it around QEMU, so only the guest has an
  address while the appliance runs (see "The container's own address" above).
- `scripts/container/*` — the shared toolchain (also used by the Docker flow).
  `NETWORK_MODE=bridge` is the LXC-specific mode in `launch-vm.sh`.

### Guest identity and the MAC rules (verified)

The ZD1200 controls its own networking: it transmits with the MAC in its
**board data**, and the LAN identifies the appliance by it. Three MACs are in play
and all three must be distinct, or the guest silently never completes DHCP:

| MAC | what it is | rule |
|---|---|---|
| container uplink (`eth0`) | the veth PVE creates | must differ from the guest's |
| container bridge | the CT's own address lives here | force a distinct one |
| guest board MAC1 | what the guest transmits | derived from a seed, never the uplink's |

The installer picks a random seed and a distinct veth MAC; the guest's MAC is
derived from the seed (as `install-zd1200-docker.sh` does with `ZD_CONTAINER_MAC`). The
bootstrap refuses to proceed if the derived guest MAC equals the container's
uplink MAC, because that failure is otherwise silent.

**Why this matters.** In the Docker flow the container's `eth0` is a macvtap and
is invisible to the LAN, so the container and guest may share the board MAC. In an
LXC the veth *is* a LAN port: when the guest and the container present the same
MAC the LAN's DHCP server treats them as one client, offers the guest the address
the container already holds, and the guest refuses it — it loops on DISCOVER
forever while `guest-ip` stays empty. Observed exactly this on PVE 9.2 with a
Debian 13 CT.

The container bridge is also moved off the uplink MAC (`02:00:00:00:00:01` by
default, `ZD_BRIDGE_MAC_ADDRESS` to change) so the bridge, the uplink and the
guest never collide.

### Why not macvtap?

The Docker flow uses a macvtap on the host NIC, which the host itself cannot
reach. A macvtap **inside** an unprivileged LXC cannot work at all: QEMU has to
`mknod` the `/dev/tapN` node and the container does not hold `CAP_MKNOD`. The tap
on the container's own bridge avoids both problems and gives the guest a normal
bridge port.

### Rebuilding

Re-run `zd1200-ct-bootstrap.sh` inside the CT to rebuild payloads or the disk
after changing configuration; it skips whatever is already current. To start from
a clean appliance:

```sh
pct exec <id> -- rm -rf /var/lib/zd1200 && pct exec <id> -- reboot
# then re-run the bootstrap (or the full installer)
```

`/opt/zd1200` is a plain checkout: `git pull` inside the CT, then re-run the
bootstrap, is enough to pick up project changes.
