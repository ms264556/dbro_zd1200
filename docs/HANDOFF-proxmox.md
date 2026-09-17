# Handoff: adding Proxmox support

Working notes for a fresh session. Keep the final docs (`README.md`,
`docs/INTERNALS.md`) in sync if behaviour changes.

## Where things are

- Repo: `github.com/ms264556/dbro_zd1200`, branch **`network-monitor`** (tip
  `ced264a`, pushed). Local checkout and the dev server are both on it.
- Dev server: `tony@10.222.1.250`, repo at `~/dbro_zd1200`. Has Docker, QEMU,
  `/dev/kvm`, e2fsprogs and p7zip; is in the `docker` group.
- Inputs on the dev server: `~/images/` (ZD1200 firmware `.img` files and CF
  dumps), plus extracted dumps under `~/cfdump/` and `~/zd1100/`.
- The agent's PC and the dev server are on different subnets (routed). The dev
  server **cannot reach its own guest** (macvtap sibling); test the guest from
  another LAN host.

## What the project is today

A Docker container runs QEMU with the stock ZD1200 kernel/rootfs. The guest
attaches to the LAN via a **macvtap on the host NIC**, so it is a normal L2
device (own MAC, DHCP, mDNS, web/SSH).

- `build-container.sh` builds the image, then runs
  `scripts/build/prepare-vendor-image.sh` **inside that image** (the host needs
  only Docker + Compose) to produce `image/`.
- Inputs: a ZD1200 firmware upgrade file; a CF dump (raw `dd` `.img` or ImageUSB
  `.bin`); or firmware + `--writable-from <dump>` to revive a foreign card
  (ZD1100 etc.) on a same-version ZD1200 rootfs.
- On start, `scripts/container/prepare-vm-disks.sh` builds a **flat synthetic
  CF** (`build-synthetic-cf.py` + `write-boarddata.py`), patches the kernel and
  rootfs on hda2/hda3, and boots it.
- Disk: hda1 `/boot`, hda2/hda3 roots (ext2), hda4 `/writable` (ext2 for a
  firmware build, reiserfs for a dump). 3931200 sectors.
- Tested releases: 10.5.1.0.282, 10.5.1.0.255, 10.2.1.0.236, 10.1.2.0.318,
  9.13.3.0.164, 9.10.2.0.130; ZD1100 dumps parse.

Read `README.md` (user-facing) and `docs/INTERNALS.md` (disk model, patch
pipeline, board data, boot/shutdown) before changing anything.

## Goal: Proxmox support

Most likely shape: run the same appliance as a **Proxmox VM** (native bridged
networking, no macvtap), rather than Docker. Confirm with the user whether they
want (a) the Docker container running inside a Proxmox VM, or (b) Proxmox-native
`qm` VM support. (b) is the interesting one and is assumed below.

Reusable assets: the flat synthetic CF (GRUB + patched kernel on hda1, roots on
hda2/3, `/writable` on hda4), `build-synthetic-cf.py`, `write-boarddata.py`,
`read-boarddata.py`, and the patch set in `scripts/container/patches/`.

Things to work out:

1. **Boot.** Proxmox `qm` has no `-kernel`; the synthetic CF already contains
   GRUB + `/bzImage` + `menu.lst`, so let the VM boot the disk. Verify the
   Stage2 config path and `root=/dev/sda2|sda3` lines match what the VM presents.
2. **Disk controller.** The guest kernel is built for the cob7402; the repo's
   `patch-kernel.py` + `build-bootfs.py` accommodate the emulated controller
   (current QEMU uses AHCI → `/dev/sda`). Confirm IDE vs SATA/SCSI in Proxmox and
   adjust the boot area/`menu.lst` if needed.
3. **Networking.** Attach a NIC to `vmbr0`; the guest then has its own MAC and
   the Proxmox host can reach it (unlike macvtap).
4. **Console.** `menu.lst` already sets `console=ttyS0`; map it to the VM's
   serial (`qm terminal`, or the web console).
5. **Lifecycle.** The current guest runs with ACPI off and uses a ttyS1 hook for
   orderly shutdown (`70-container-control.sh`). Decide how Proxmox stop/reboot
   should drive the guest (QMP/guest agent vs the existing hook).

Suggested first steps:

1. Read `README.md` + `docs/INTERNALS.md`; inspect the running container and the
   prepared `image/` on the dev server.
2. Prototype by hand on the Proxmox host: build the synthetic CF, import it as a
   VM disk (`qm importdisk`/`qm set`), attach a bridged NIC, boot, reach the web
   UI from another host.
3. Turn that into a small helper (e.g. `proxmox/` + a `build-proxmox.sh`) that
   produces the disk and prints/executes the `qm` commands, mirroring how
   `build-container.sh` is the single entry point today.
4. Keep the host-tooling philosophy: do image work in a container/VM, not on the
   Proxmox host.

## Landmines

- **Never commit dump-derived identifiers** (serials/MACs from real appliances).
  `image/`, `.env`, `dropbear-provision/` are gitignored. The history was already
  scrubbed once for a leaked serial.
- The dev server cannot reach its own guest; test from another LAN host.
- `scripts/build/find-cf-partition.py` locates `/writable` from the vendor
  partition table (geometry-agnostic); `--writable-partition START:COUNT`
  overrides it.
- Commit on the dev server, then sync local with
  `git fetch devserver && git reset --hard devserver/network-monitor`, or push
  from the dev server (`git push -u origin network-monitor`).
