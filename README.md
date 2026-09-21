# Virtualizing a dead Ruckus ZoneDirector

When a ZoneDirector dies (ZD1100, ZD1200 or ZD3000) and an RMA is not an option,
its configuration can still run on a virtual ZD1200. This project boots ZD1200
firmware under QEMU, on Proxmox VE or in Docker. The guest joins your LAN as its
own device, and your APs connect to it as they did to the physical box.

The recipes below are alternatives, not steps: pick the one matching what
survived. You need a ZD1200 firmware upgrade file from Ruckus/CommScope support,
except when installing from a dead ZD1200's own storage.

Clone the project first:

```sh
git clone https://github.com/ms264556/dbro_zd1200 && cd dbro_zd1200
```

## Recipe 1: you have a configuration backup

A backup (`ruckus_db_*.bak`) holds the configuration and certificates, so the
appliance comes up as the dead one was. It does not hold any firmware, so pass a
ZD1200 firmware upgrade file of the same release; the first three version
components must match, and the build number does not.

> Not sure which release? Run the installer with only the backup and it names
> the firmware to download.

Proxmox VE (as root):

```sh
./install-zd1200-lxc.sh ruckus_db_052323_14_06.bak zd1200_10.5.1.0.282.ap_10.5.1.0.282.img
```

Docker:

```sh
./install-zd1200-docker.sh ruckus_db_052323_14_06.bak zd1200_10.5.1.0.282.ap_10.5.1.0.282.img
```

The backup restores on the first boot.

> Later you can upgrade from the Web UI, beyond what the dead unit ran. See the
> [Firmware Guide](https://ms264556.net/ruckus/FirmwareGuide?p=ZoneDirector&q=ZD1200) for AP support.

## Recipe 2: you have the storage from the dead unit

Take the storage out of the dead appliance and image it byte-for-byte:

* **ZD1200**: CompactFlash card
* **ZD1100**: internal USB flash drive
* **ZD3000**: internal hard disk

```sh
sudo dd if=/dev/sdX of=dump.img bs=4M status=progress
```

On Windows, use PassMark's **ImageUSB** to read the storage into an image.

### If the dead unit was a ZD1200

The card holds the firmware as well as the configuration, so this needs no
firmware download at all.

Proxmox VE (as root):

```sh
./install-zd1200-lxc.sh dump.img
```

Docker:

```sh
./install-zd1200-docker.sh dump.img
```

### If the dead unit was a ZD1100 or ZD3000

Its storage holds the configuration but not ZD1200 firmware, so pass a ZD1200
firmware upgrade file of the same release; the first three version components
must match.

> Not sure which release? Run the installer with only the dump and it names the
> firmware to download.

Proxmox VE (as root):

```sh
./install-zd1200-lxc.sh dump.img zd1200_10.5.1.0.130.ap_10.5.1.0.130.img
```

Docker:

```sh
./install-zd1200-docker.sh dump.img zd1200_10.5.1.0.130.ap_10.5.1.0.130.img
```

> Later you can upgrade from the Web UI, beyond what the dead unit ran. See the
> [Firmware Guide](https://ms264556.net/ruckus/FirmwareGuide?p=ZoneDirector&q=ZD1200) for AP support.

## Recipe 3: you don't have a backup or dump

Start from a firmware upgrade file and set the controller up by hand.

Proxmox VE (as root):

```sh
./install-zd1200-lxc.sh zd1200_10.5.1.0.282.ap_10.5.1.0.282.img
```

Docker:

```sh
./install-zd1200-docker.sh zd1200_10.5.1.0.282.ap_10.5.1.0.282.img
```

Complete the setup wizard, reboot once, then re-add your WLANs, APs and licences.

## Then

Open `https://<guest-ip>/` from another LAN machine (the Docker host cannot reach
its own guest). Read the lease from your DHCP server, or on Proxmox VE from the
container's **Summary** tab or
`pct exec <id> -- cat /var/lib/zd1200/guest-ip`. `--help` lists every installer
option; if it does not come up, see
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

MIT. See `LICENSE`.
