# Ruckus ZoneDirector ZD1200 in Docker

Run the Ruckus ZoneDirector 1200 (ZD1200) wireless controller firmware as a
virtual appliance in a Docker container. QEMU runs the stock ZD1200 kernel and
rootfs inside the container, and the guest attaches to your LAN through a
**macvtap on the host's physical NIC**, so it behaves like the real box: it gets
its own DHCP lease, answers mDNS, and serves the web UI and SSH.

No firmware, vendor binaries or compiled GRUB binaries are committed. The
vendor-derived artifacts are built into `image/` locally from your firmware
archive, and the GRUB bootloader is compiled from source **inside the container
image build** (its `grub-build` stage), so the host needs no compiler.

---

## What you need

### Host

- Linux with Docker Engine + **Compose v2** (`docker compose`, not the old
  `docker-compose` script). `build-container.sh` uses `sudo` for Docker only if
  your user is not in the `docker` group.
- A LAN interface that can pass **foreign MAC addresses** (MAC spoofing, or a
  bridge port that doesn't filter MACs). The guest is a macvtap device on the
  host NIC and needs its own MAC on the wire — the appliance must be a real L2
  device on the LAN, because access points connect to it directly.
  There is deliberately **no NAT/user-mode fallback**: it would hide the appliance
  from the APs. WSL2 and other hosts that cannot pass foreign  MACs are not
  supported.
- `/dev/kvm` — optional. Without it QEMU falls back to TCG and the guest takes
  several minutes to boot instead of ~1–2.
- Host tools for the prepare step: `tar`, `gzip`, `python3`, `md5sum`,
  `sha256sum` (coreutils) and `bash`.
- **No compiler or autotools.** GRUB is compiled inside the image build; the
  host only needs Docker.

### Firmware

This repo does **not** ship firmware. Download the ZD1200 firmware upgrade file
from Ruckus/CommScope support (an account is required), e.g.

```
zd1200_10.5.1.0.282.ap_10.5.1.0.282.img
```

Pass that file to `build-container.sh` as-is. The download is TAC-encrypted, and
`scripts/prepare-vendor-image.sh` decrypts it with
`scripts/ruckus_tac_decrypt.py` before extracting. The decrypted payload is a
gzipped tar containing `metadata`, `bzImage`,
`rootfs.i386.ext2.director1200.img`, `restoreinitramfs.gz`, `firmwares/` and the
AP models list.

Any ZD1200 release works — `scripts/prepare-vendor-image.sh` validates the
`metadata` (`REQUIRE_PLATFORM=nar5520`, `REQUIRE_SUBPLATFORM=cob7402`) and the
kernel/rootfs MD5s, and does not pin a version. The prepared artifacts land in
`image/` (gitignored).

Pass the file to the build script, or set `ZD_ARCHIVE`. To pin the payload
integrity, set `EXPECTED_ARCHIVE_SHA256`; the 10.5.1.0.282 payload is
`64dfbf4d67cc65cafa0e258e426c664c7387b1219209ec893b9b1e41ab202cb8`.

The GRUB bootloader is *not* taken from the firmware and is *not* committed as a
binary: the container image build compiles it from the upstream GRUB 0.97 tarball
plus the AUR, local and Ruckus patches (provenance and patch list in
`guest-src/grub097_src/README.md`). It no-ops when nothing changed, so only the first build
and GRUB source changes pay for it.

### The `image/` directory

`build-container.sh` runs `scripts/prepare-vendor-image.sh` once to unpack the
firmware archive into `image/` at the repo root (gitignored). It holds the
vendor-derived `rootfs.ext2`, `bzImage`, `restoreinitramfs.gz`, the signing-cert
payload and the AP firmware payload, and is mounted read-only into the container
at `/opt/zd1200/image`. Later runs reuse it; delete the directory (or re-run
`scripts/prepare-vendor-image.sh <archive>`) to extract again.

---

## Quick start

```sh
sudo ./build-container.sh /path/to/zd1200_10.5.1.0.282.ap_10.5.1.0.282.img
```

That one command prepares `image/` (once), creates `.env`, builds the container
image and starts it. On later runs, omit the archive path.

Watch it boot:

```sh
docker logs -f zd1200
docker exec zd1200 tail -f /tmp/zd1200-web.log     # guest serial console
```

The container reports `Up (healthy)` once the guest prints
`System go into READY status.` on the console — a couple of minutes under KVM,
longer under TCG.

Flags: `--no-up` builds the image without starting it; `--help` prints the usage.

---

## Reaching the appliance

The guest leases an address **from your LAN's DHCP server**. It is a normal
device on the network, not a published container port:

```sh
docker exec zd1200 cat /var/lib/zd1200/guest-ip
```

Open `https://<guest-ip>/` (the entrypoint prints the URL once it has the lease)
from a machine on the same LAN. First boot runs the factory setup wizard. After
the wizard, reboot the appliance once so it generates its SSH host key, then
`ssh admin@<guest-ip>`.

### The guest IP is not reachable from this host

By design. The guest is a macvtap device on the host's NIC, and a macvlan parent
does not loop frames back to its sibling macvtap, so **the Docker host cannot
reach its own guest**. Verify the appliance from another machine on the LAN:

```sh
curl -kI https://<guest-ip>/admin10/login.jsp
```

This is expected behaviour, not a fault — there is nothing to "fix" with routes,
bridges or iptables.

### Serial console

The guest's serial console is the appliance's console (the same prompt you would
get on the physical box). It is logged, and also exposed interactively:

```sh
# raw console log (also what the healthcheck greps)
docker exec zd1200 tail -f /tmp/zd1200-web.log

# interactive console (ZD1200 CLI login prompt)
docker exec -it zd1200 python3 /opt/zd1200/attach-console.py
# Ctrl-C (sometimes twice) detaches; the guest keeps running
```

QEMU also exposes an IPMI BMC (`ipmi-bmc-sim` + `isa-ipmi-kcs`), which the
firmware uses for watchdog and power handling.

---

## Boot test without the container

`scripts/boot-test.sh` boots the prepared disk under a **direct QEMU** (KVM, a software
IPMI BMC, user-mode networking — no macvtap, no LAN traffic) and watches the
guest serial console until it reaches a milestone. It is the quick way to check
a bootloader/rootfs change without disturbing the running container or the LAN.

```sh
./scripts/boot-test.sh                          # build + prepare + boot; pass when init runs
./scripts/boot-test.sh --firmware ~/images/zd1200_*.img  # first run: also prepare image/
./scripts/boot-test.sh --expect ready --timeout 300      # wait for the controller's READY marker
./scripts/boot-test.sh --reuse --no-build                # re-boot the disks already prepared
```

Milestones, in order, detected on the guest serial console:

| level | marker | proves |
|---|---|---|
| `grub` | `Booting 'Normal bootup from system image` | GRUB's stage2 ran and read menu.lst |
| `kernel` | `[Linux-bzImage,` | GRUB mounted the ext2 partition and loaded `/bzImage` |
| `init` | `/dev/hda4 on /writable type ext2` | the guest kernel reached user-space init (default) |
| `controller` | `Initializing ZoneDirector...` | the controller init script is running |
| `ready` | `System go into READY status.` | the appliance is up (the healthcheck's marker) |

Exit status 0 means the requested milestone was reached; 1 means it was not
(timeout, QEMU exited, or a fatal guest error such as `Error 17: Cannot mount
selected partition` / `Kernel panic`). The serial log is kept at
`.boot-test/serial.log` (gitignored), and each milestone is printed with its
elapsed time.

It runs `build-container.sh --no-up` to build the container image, prepares the
synthetic CF + qcow2 overlay in `.boot-test/` using the container's own
`apply-rootfs-patches.sh`, then boots that overlay on the host. The running
container's state volume is never touched.

---

## How it works

- `docker/Dockerfile` builds a Debian image with QEMU and the guest-image
  tooling; `docker/docker-compose.yml` runs it with `network_mode: host`, the
  `NET_ADMIN`/`MKNOD`/`NET_RAW` capabilities and the `zd1200-state` volume.
- On start, the entrypoint (`scripts/run-zd1200-web.sh`) patches the kernel for
  QEMU, then `scripts/apply-rootfs-patches.sh` builds the synthetic CompactFlash
  (`scripts/make-synthetic-cf.py` + `scripts/write-boarddata.py`), creates the
  persistent qcow2 overlay and runs the ordered patches in `patches/`.
- The board data (serial + MACs) is **authoritative**: it is seeded into the CF
  when the base disk is built, and `scripts/read-boarddata.py` reads it back from
  the disk on every start. The macvtap, the QEMU NIC and the DHCP sniffer all use
  the value read back, so a MAC changed in the appliance's web UI is honoured on
  the next start.
- The `/boot` bootloader filesystem is built from `guest-src/grub097_src/out/` by
  `scripts/build-bootfs.py` and written at sector 0 of the synthetic CF.
- QEMU boots the guest with a macvtap (`mvt0`) on the host's physical NIC.
- Re-runs are cheap: the coordinator records a signature (`rootfs`/`bootfs`/
  `patches` hashes) in the state volume and no-ops when nothing changed.

## Configuration

`build-container.sh` copies `docker/.env.example` to `.env` on first run. The
usual knobs:

| variable | purpose |
|---|---|
| `ZD_GUEST_IP` | guest management IP used for the printed URL (readiness itself is console-based) |
| `ZD_SIGN_CERT_HOST` | host path to the signing-cert payload for the license patch (extracted from the firmware archive by default) |
| `ZD_CONTAINER_MAC` | unique container MAC the guest identity is derived from (auto-generated into `.env` on first run) |
| `ZD_SERIAL`, `ZD_MAC1` | only used if you pin the identity (`ZD_BOARDDATA_FROM_MAC=0`) |
| `ZD_CONTAINER_NAME`, `ZD_STATE_VOLUME` | container and volume names |

## Gotchas

- **Board data is authoritative.** `ZD_CONTAINER_MAC` (a unique,
  locally-administered MAC that `build-container.sh` generates into `.env` on
  first run) seeds the identity when the synthetic CF is first built — the guest
  MAC1 is that value and the serial is hashed from it. From then on the board data
  on the disk wins: it is read back on every start, so changing the MAC in the
  appliance's web UI takes effect on the next start. Re-seeding it (new
  `ZD_CONTAINER_MAC`, or pinning `ZD_BOARDDATA_FROM_MAC=0` with
  `ZD_SERIAL`/`ZD_MAC1`) needs a fresh state volume (see *Factory reset*).
- **The guest reboots in place.** Its patched `machine_restart()` issues a QEMU
  i8042 reset, so a reboot from the web UI, CLI or `/sbin/reboot` completes and
  the container stays `Up`. Do not add `-no-reboot`.
- **No in-guest firmware upgrades.** QEMU boots an external kernel, so a web-UI
  upgrade would leave a mixed version. Update the archive/`guest-src/` and
  rebuild instead.
- **No NAT fallback.** The container shares the host's network namespace and the
  guest is a macvtap on the host NIC, so APs reach it directly on the LAN. A
  user-mode NAT setup would hide the appliance from the APs, so there is none —
  the host must be able to pass foreign MACs.

- **First boot is the factory wizard.** The state volume persists the controller
  configuration; `/writable` is preserved across rootfs re-patches.

## Factory reset / clean state

```sh
docker compose --project-directory . -f docker/docker-compose.yml down -v
```

Removes the container **and** the `zd1200-state` volume, so the next
`build-container.sh` boots a factory appliance again.

## Repository layout

```
build-container.sh   the one entry point
docker/              Dockerfile, compose files, .env.example, Dockerfile.dockerignore
scripts/             host prepare step, container entrypoint, guest-image prep, console
                     helper, and boot-test.sh (boot the prepared disk under QEMU)
patches/             ordered rootfs patches applied before each boot
guest-src/           source projects compiled in the image build and placed into the
                     guest disk image — currently grub097_src/ (GRUB 0.97, boot area)
image/               vendor-derived artifacts built from your firmware (gitignored)
```

## License

MIT — see `LICENSE`. The GRUB bootloader built by `guest-src/grub097_src/` is
**GPLv2-or-later**; see `guest-src/grub097_src/COPYING` and
`guest-src/grub097_src/README.md` for the license and the corresponding-source
offer.
