# Ruckus ZoneDirector ZD1200 as a virtual appliance

Run the ZoneDirector ZD1200 controller as a virtual appliance in Docker or on
Proxmox VE. It joins your LAN like the physical box, and your APs connect to it.

You supply a ZD1200 firmware upgrade file from Ruckus/CommScope support, or a dump
of a real appliance's CompactFlash card. Any ZD1200 release >= 9.10 should work.

## Recipe: Docker

Docker Engine + Compose v2, and a host NIC that passes foreign MACs.

```sh
git clone https://github.com/ms264556/dbro_zd1200 && cd dbro_zd1200
./install-zd1200-docker.sh /path/to/zd1200_10.5.1.0.282.ap_10.5.1.0.282.img
```

The guest takes a DHCP lease: read it from your DHCP server, or with
`docker exec zd1200 cat /var/lib/zd1200/guest-ip`, then open `https://<guest-ip>/`
from another LAN machine — the Docker host cannot reach its own guest.

## Recipe: Proxmox VE (LXC)

As root on a PVE 8.2+ host:

```sh
git clone https://github.com/ms264556/dbro_zd1200 && cd dbro_zd1200
./install-zd1200-lxc.sh /path/to/zd1200_10.5.1.0.282.ap_10.5.1.0.282.img
```

The guest takes a DHCP lease: read it from your DHCP server, from the container's
**Summary** tab in the Proxmox web UI, or with
`pct exec <id> -- cat /var/lib/zd1200/guest-ip`, then open `https://<guest-ip>/`
from any LAN machine, including the PVE host.

## Installing from an existing ZD1100/ZD1200/ZD3000 disk dump

> Docker and Proxmox VE installers both take the same arguments: substitute
> `./install-zd1200-lxc.sh` to run the commands below on Proxmox.

### A CompactFlash dump of a real ZD1200

Everything comes from the card dump, so the appliance arrives
with the original device's configuration:

```sh
./install-zd1200-docker.sh /path/to/zd1200_10.5.1.0.240_cfcard_dump.img
```

### A USB flash dump of a real ZD1100, or a disk dump of a real ZD3000

These devices are incompatible with the ZD1200 hardware, so you also need to
supply a ZD1200 firmware upgrade file of the same version:

```sh
./install-zd1200-docker.sh /path/to/zd1200_9.10.2.0.130.ap_9.10.2.0.130.img \
    --writable-from /path/to/zd1106_9.10.2.0.130_flash_dump.bin
```

## Firmware upgrades

Perform ZoneDirector firmware upgrades and downgrades from within its Web UI or CLI.

## Mesh repair

For ZoneDirector 10.5.1.0.276 and later, the container repairs the mesh receive-path
bug in the AC Wave 1 AP image (e.g. R600) by default. The repaired image is
unsigned, so APs must already run Solo 104 or 106 before they can be adopted by the
ZD1200.

Pass `--no-r600-repair` to ship the vendor images untouched.

## Updating the container machinery

To pick up changes to this project's scripts, patches or guest tooling:

```sh
git clone https://github.com/ms264556/dbro_zd1200 && cd dbro_zd1200
./install-zd1200-docker.sh --upgrade
./install-zd1200-lxc.sh --upgrade
```

## Help

* Use the `--help` argument to see all available installer options.
* Visit [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) if you have installer or
  container problems.
* Visit [docs/INTERNALS.md](docs/INTERNALS.md) / [docs/PROXMOX.md](docs/PROXMOX.md) for the
  technical detail.
* The tested matrix is 9.10.2.0.130, 9.13.3.0.164, 10.1.2.0.318, 10.2.1.0.236,
  10.3.1.0.45, 10.4.1.0.272, 10.5.1.0.255 and 10.5.1.0.282.

MIT — see `LICENSE`.
