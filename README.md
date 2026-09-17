# Ruckus ZoneDirector ZD1200 as a virtual appliance

Run the Ruckus ZoneDirector ZD1200 controller as a virtual appliance, on a Proxmox
VE host or in Docker. It joins your network like the physical box would, and your
access points connect to it directly.

You supply the input: a firmware upgrade file downloaded from Ruckus/CommScope
support, or a dump of a real appliance's CompactFlash card. Nothing vendor-owned is
committed here, and the recipes below show which path to pass.

Two entry points, both in the repository root:

| installer | platform |
|---|---|
| `install-zd1200-docker.sh` | Docker |
| `install-zd1200-lxc.sh` | Proxmox VE (LXC) |

If something goes wrong, **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** has
the symptom-by-symptom fixes.

## Recipe: Docker

```sh
# Linux host with Docker Engine + Compose v2, and a NIC that can pass foreign
# MACs. /dev/kvm optional (fast boots).
git clone https://github.com/ms264556/dbro_zd1200 && cd dbro_zd1200

./install-zd1200-docker.sh /path/to/zd1200_10.5.1.0.282.ap_10.5.1.0.282.img

docker logs -f zd1200                             # boot progress
docker exec zd1200 cat /var/lib/zd1200/guest-ip   # the guest's address
```

Open `https://<guest-ip>/` from another LAN machine.

## Recipe: Proxmox VE (LXC)

```sh
# As root on the PVE host (8.2+). The installer fetches a Debian 13 template
# itself; /dev/kvm gives sensible boot times.
git clone https://github.com/ms264556/dbro_zd1200 && cd dbro_zd1200

./install-zd1200-lxc.sh /path/to/zd1200_10.5.1.0.282.ap_10.5.1.0.282.img

pct exec <id> -- journalctl -fu zd1200            # boot progress
pct exec <id> -- cat /var/lib/zd1200/guest-ip     # the guest's address
```

Open `https://<guest-ip>/` from any LAN machine — including the PVE host itself.

## Alternatives

Pass a different input, or drop a repair you do not need. The Docker entry point is
`./install-zd1200-docker.sh`; the Proxmox one is `./install-zd1200-lxc.sh`.
Both take the same flags.

```sh
# A CompactFlash dump of a real ZD1200: rootfs, /writable and serial all come
# from the card, so the appliance arrives with its own configuration.
./install-zd1200-docker.sh /path/to/zd1200_10.5.1.0.240_cfcard_dump.img
./install-zd1200-lxc.sh /path/to/zd1200_10.5.1.0.240_cfcard_dump.img

# Firmware for the kernel/rootfs plus a foreign card's /writable and serial: here
# a ZD3000 card on ZD1200 firmware of the same version, which revives the card's
# AP payloads and configuration.
./install-zd1200-docker.sh /path/to/zd1200_9.10.2.0.130.ap_9.10.2.0.130.img \
    --writable-from /path/to/zd3000_9.10.2.0.130_cfcard_dump.bin
./install-zd1200-lxc.sh /path/to/zd1200_9.10.2.0.130.ap_9.10.2.0.130.img \
    --writable-from /path/to/zd3000_9.10.2.0.130_cfcard_dump.bin

# Ship the vendor AP images exactly as they came, without the R600 /
# ap-11n-scorpion mesh repair. Useful when comparing against stock behaviour.
./install-zd1200-docker.sh --no-r600-repair /path/to/zd1200_10.5.1.0.282.ap_10.5.1.0.282.img
./install-zd1200-lxc.sh --no-r600-repair /path/to/zd1200_10.5.1.0.282.ap_10.5.1.0.282.img
```

> **If the mesh repair is applied, the APs must already be running Solo 104 or 106
> firmware or they will not join.** The repair delivers an unsigned AP image, and
> an AP on older firmware will not accept it — upgrade the APs to Solo 104/106
> through their own standalone upgrade page first.

## Inputs

| input | example | notes |
|---|---|---|
| firmware upgrade file | `zd1200_10.5.1.0.282.ap_*.img` | TAC-encrypted; decrypted during preparation |
| CF card dump | `*_cfcard_dump.img`, ImageUSB `.bin` | raw `dd` or Windows ImageUSB dump |
| firmware + a foreign card's data | `--writable-from <dump>` | reuses another card's `/writable` + serial (e.g. a ZD1100 card) |

Any ZD1200 release works; the tested matrix is 9.10.2.0.130, 9.13.3.0.164,
10.1.2.0.318, 10.2.1.0.236, 10.5.1.0.255 and 10.5.1.0.282. Prepared artifacts land
in `image/` (Docker) or `/var/lib/zd1200/image` (LXC) and are reused.

## Optional features

| flag (both entry points) | effect |
|---|---|
| `--root-ssh-key <key\|file>` | static-dropbear replacement + public-key root SSH on 2222 (first build is slow) |
| `--writable-from <dump>` | take `/writable` + serial from a CF dump |
| `--writable-partition START:COUNT` | override the detected dump geometry |
| `--no-up` (Docker) / `--no-*` (LXC) | build without booting / skip individual pieces |

The guest also gets an ECDSA SSH host key, the community Network Monitor page and
the R600/`ap-11n-scorpion` mesh repair by default. Details:
[`docs/INTERNALS.md`](docs/INTERNALS.md).

## Reach the appliance

```sh
docker exec zd1200 cat /var/lib/zd1200/guest-ip     # Docker
pct exec <id> -- cat /var/lib/zd1200/guest-ip       # Proxmox
```

Open `https://<guest-ip>/`. The first boot runs the factory setup wizard; finish
it, reboot the guest once so it generates its SSH host key, then `ssh admin@<ip>`.
At the ZD CLI, `!v54! <any word>` drops to a root shell.

Serial console (the same prompt as on the physical box):

```sh
docker exec -it zd1200 python3 /opt/zd1200/attach-console.py
pct exec <id> -- python3 /opt/zd1200/scripts/container/attach-console.py
```

## Constraints

- **The Docker host cannot reach its own guest.** macvtap is a macvlan sibling, so
  frames never loop back — test from another LAN machine. The Proxmox LXC layout
  has no such limitation: the PVE host can reach its guest.
- **The LAN interface must pass foreign MACs** (MAC spoofing, or an unfiltered
  bridge port). There is no NAT/user-mode fallback; WSL2 is not supported.
- **Proxmox needs a Debian 13 template.** The installer fetches one if you have
  none, and refuses a template that cannot run the guest.
- **`/dev/kvm` matters**: ~1–2 minutes to boot with it, several minutes without.
- **Do not lower the stop grace period** (Docker 180s, systemd `TimeoutStopSec`):
  the guest needs it to flush `/writable`.
- **First boot is a factory appliance**: complete the wizard, reboot once, then
  `ssh admin@<ip>` works.
- **Applying the R600 mesh repair needs Solo 104 or 106 on the APs first.** The
  repair delivers an unsigned AP image, and newer AP firmware will not accept it —
  so the APs will not join. Upgrade them through their own standalone upgrade page
  before pointing them at the controller, or build with `--no-r600-repair`.

## If it does not work

The guest's console tells you why:

```sh
docker logs zd1200 | tail -80                       # Docker
pct exec <id> -- journalctl -u zd1200 -n 80         # Proxmox
```

Symptom-by-symptom fixes, including the common installation failures, are in
[`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

## Clean state

```sh
# Docker: container + state volume (the next build boots a factory appliance)
docker compose --project-directory . -f docker/docker-compose.yml down -v

# Proxmox: the container's whole state
pct exec <id> -- rm -rf /var/lib/zd1200 && pct reboot <id>
```

## Documentation

| document | contents |
|---|---|
| [`docs/INTERNALS.md`](docs/INTERNALS.md) | disk model, rootfs patch pipeline, board data/identity, boot/shutdown, boot test |
| [`docs/PROXMOX.md`](docs/PROXMOX.md) | LXC layout, MAC rules, network unit, safeguards, rebuilding |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | symptom-to-fix for starting, reaching, slow/unhealthy guests, APs and firmware |
| `install-zd1200-lxc.sh --help` | every installer flag |
| `docker/Dockerfile`, `docker/docker-compose.yml` | the Docker runtime |
| [`analytics/README.md`](analytics/README.md), [`bl7/README.md`](bl7/README.md) | Network Monitor, R600 mesh repair |

## License

MIT — see `LICENSE`. The firmware (including the GRUB binaries this repo reuses)
is Ruckus/CommScope's and is never committed or redistributed here.
