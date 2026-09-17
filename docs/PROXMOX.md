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

## Safeguards

Three independent mechanisms keep a bad guest from going unnoticed, and they cover
different failure modes:

| mechanism | catches | behaviour |
|---|---|---|
| `ZD_GUEST_WATCHDOG` (default on) | the guest wedging inside QEMU | the timer probes the guest; after 5 consecutive failures it reboots it over the guest control channel, then waits a 15-minute cooldown |
| `ZD_CPU_GUARD` (default 24) | a guest spinning at 100% CPU | the entrypoint stops QEMU after 120s of continuous >95% CPU; systemd restarts the stack, which reboots the guest |
| the installer's QEMU pre-flight | a template whose QEMU cannot run the guest | aborts the install **before** the container can enter a boot loop |

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
  bridges the uplink and moves the CT's address onto the bridge.
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
