# Ruckus ZoneDirector ZD1200 in Docker

Run the Ruckus ZoneDirector 1200 (ZD1200) wireless controller firmware as a
virtual appliance in a Docker container. QEMU runs the stock ZD1200 kernel and
rootfs inside the container, and the guest attaches to your LAN through a
**macvtap on the host's physical NIC**, so it behaves like the real box: it gets
its own DHCP lease, answers mDNS, and serves the web UI and SSH.

No firmware or vendor binaries are committed. Everything is derived locally from
your firmware archive into `image/` (gitignored) — including the GRUB binaries
that build the boot area — so the host needs nothing but Docker.

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
- **No host compiler.** The container build compiles the guest-side helper
  binaries inside Docker; the host only needs Docker.

### Firmware

This repo does **not** ship firmware. Download the ZD1200 firmware upgrade file
from Ruckus/CommScope support (an account is required), e.g.

```
zd1200_10.5.1.0.282.ap_10.5.1.0.282.img
```

Pass that file to `build-container.sh` as-is. The download is TAC-encrypted, and
`scripts/build/prepare-vendor-image.sh` decrypts it with
`scripts/build/tac-decrypt.py` before extracting. The decrypted payload is a
gzipped tar containing `metadata`, `bzImage`,
`rootfs.i386.ext2.director1200.img`, `restoreinitramfs.gz`, `firmwares/` and the
AP models list.

Any ZD1200 release works — `scripts/build/prepare-vendor-image.sh` validates the
`metadata` (`REQUIRE_PLATFORM=nar5520`, `REQUIRE_SUBPLATFORM=cob7402`) and the
kernel/rootfs MD5s, and does not pin a version. The prepared artifacts land in
`image/` (gitignored).

Pass the file to the build script, or set `ZD_ARCHIVE`. To pin the payload
integrity, set `EXPECTED_ARCHIVE_SHA256`; the 10.5.1.0.282 payload is
`64dfbf4d67cc65cafa0e258e426c664c7387b1219209ec893b9b1e41ab202cb8`.

The GRUB bootloader is taken from the firmware: its factory-restore initramfs
ships `stage1`/`stage2`/`e2fs_stage1_5` (already built for the ZD1200's partition
layout), and `scripts/container/build-bootfs.py` writes them into the boot area together
with `menu.lst` from the firmware archive and a generated saved-default file.
Nothing is compiled and nothing is committed.

### The `image/` directory

`build-container.sh` runs `scripts/build/prepare-vendor-image.sh` once to unpack the
firmware archive into `image/` at the repo root (gitignored). It holds the
vendor-derived `rootfs.ext2`, `bzImage`, `restoreinitramfs.gz`, the signing-cert
payload and the AP firmware payload, and is mounted read-only into the container
at `/opt/zd1200/image`. Later runs reuse it; delete the directory (or re-run
`scripts/build/prepare-vendor-image.sh <archive>`) to extract again.

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
docker exec zd1200 tail -f /tmp/zd1200-console.log     # guest serial console
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
docker exec zd1200 tail -f /tmp/zd1200-console.log

# interactive console (ZD1200 CLI login prompt)
docker exec -it zd1200 python3 /opt/zd1200/attach-console.py
# Ctrl-C (sometimes twice) detaches; the guest keeps running
```

QEMU also exposes an IPMI BMC (`ipmi-bmc-sim` + `isa-ipmi-kcs`), which the
firmware uses for watchdog and power handling, and a debug console
(`isa-debugcon`) on port 0x402, where the firmware's pre-console output
(SeaBIOS) is captured to `/tmp/zd1200-debugcon.log` instead of being dropped.

---

## Boot test without the container

`scripts/test/boot-test.sh` boots the prepared disk under a **direct QEMU** (KVM, a software
IPMI BMC, user-mode networking — no macvtap, no LAN traffic) and watches the
guest serial console until it reaches a milestone. It is the quick way to check
a bootloader/rootfs change without disturbing the running container or the LAN.

```sh
./scripts/test/boot-test.sh                          # build + prepare + boot; pass when init runs
./scripts/test/boot-test.sh --firmware ~/images/zd1200_*.img  # first run: also prepare image/
./scripts/test/boot-test.sh --expect ready --timeout 300      # wait for the controller's READY marker
./scripts/test/boot-test.sh --reuse --no-build                # re-boot the disks already prepared
./scripts/test/boot-test.sh --cpu n270 --machine pc,acpi=off  # pick the QEMU CPU / machine spec
./scripts/test/boot-test.sh --reboot --expect ready           # also reboot the guest and re-check READY
```

Milestones, in order, detected on the guest serial console:

| level | marker | proves |
|---|---|---|
| `grub` | `Booting 'Normal bootup from system image` | GRUB's stage2 ran and read menu.lst |
| `kernel` | `[Linux-bzImage,` | GRUB mounted the ext2 partition and loaded `/bzImage` |
| `init` | `/dev/sda4 on /writable type ext2` | the guest kernel reached user-space init (default) |
| `controller` | `Initializing ZoneDirector...` | the controller init script is running |
| `ready` | `System go into READY status.` | the appliance is up (the healthcheck's marker) |

Exit status 0 means the requested milestone was reached; 1 means it was not
(timeout, QEMU exited, or a fatal guest error such as `Error 17: Cannot mount
selected partition` / `Kernel panic`). The serial log is kept at
`.boot-test/serial.log` (gitignored), the firmware's pre-console debug output
at `.boot-test/debugcon.log`, and each milestone is printed with its elapsed
time.

`--reboot` goes further: once the milestone is reached it drives the guest
serial console (declining the setup wizard and logging in) and runs `reboot`,
then requires the guest to reach the milestone again. That exercises the
kernel's `machine_restart` path, not just boot. The console login comes from
`dropbear-provision/{passwd,shadow}` (a gitignored local input) seeded into
`/writable`; set `ZD_CONSOLE_USER`/`ZD_CONSOLE_PASSWORD` to use another
account. A freshly seeded appliance logs in as `admin`/`admin`.

It runs `build-container.sh --no-up` to build the container image, prepares the
synthetic CF disk in `.boot-test/` using the container's own
`prepare-vm-disks.sh`, then boots that disk on the host. The running
container's state volume is never touched.

---

## How it works

- `docker/Dockerfile` builds a Debian image with QEMU and the guest-image
  tooling; `docker/docker-compose.yml` runs it with `network_mode: host`, the
  `NET_ADMIN`/`MKNOD`/`NET_RAW` capabilities and the `zd1200-state` volume.
- On start, `scripts/container/prepare-vm-disks.sh` builds the synthetic CompactFlash
  (`scripts/container/build-synthetic-cf.py` + `scripts/container/write-boarddata.py`) if it is
  missing or the prepared firmware changed, then applies the QEMU kernel patch and the
  ordered patches in `scripts/container/patches/` to whichever root partitions lack the
  current sentinel (`/etc/.zd-image`). The flat CF image *is* the live disk — there is no
  qcow2 overlay.
- The board data (serial + MACs) is **authoritative**: it is seeded into the CF
  when the base disk is built, and `scripts/container/read-boarddata.py` reads it back from
  the disk on every start. The macvtap, the QEMU NIC and the DHCP sniffer all use
  the value read back, so a MAC changed in the appliance's web UI is honoured on
  the next start.
- The `/boot` bootloader filesystem is built from the firmware's GRUB binaries by
  `scripts/container/build-bootfs.py` and written at sector 0 of the synthetic CF.
- The root partitions are laid down from `image/rootfs.ext2`, `resize2fs`'d to fill
  the partition (as the vendor install does), and `/writable` is seeded the way a
  firmware install leaves it: the AP images + web `aidfs` staged from the `image/`
  payload.
- QEMU boots the guest with a macvtap (`mvt0`) on the host's physical NIC.
- Re-runs are cheap: each root partition records the patch set it was customised
  with in `/etc/.zd-image`, so a start where nothing changed just re-reads two
  sentinels and exits.

## Network Monitor

The image also carries the community **Network Monitor** page, ported from
[`dbro/zd1200`](https://github.com/dbro/zd1200) (see `analytics/README.md`).
After the setup wizard and a reboot it appears as the last item under
**Troubleshooting**. It records one ICMP observation per managed device per
collection interval, together with the controller's own AP telemetry and
opaque AP/client/mesh configuration snapshots, and renders a per-target
latency / loss / SNR / airtime history with an A/B "compare two moments"
workflow and a downloadable analysis prompt.

Collection is **off** on a fresh controller. Enable it, and pick the shared
30–3600 second interval, from the ⚙ menu on the page; the setting is stored
through ZoneDirector's normal authenticated preference mechanism. Runtime state
lives on the writable partition under `/writable/zd1200-ping-monitor/` and
nothing is uploaded off the controller.

Two optional settings in `.env` pre-seed a fresh appliance, so a new deployment
need not be configured by hand. `ZD_PING_INTERVAL_SECONDS` sets the initial
collection interval, and `ZD_PING_CLIENT_TARGETS` adds static ping targets for
devices ZoneDirector does not manage (a gateway, an uplink, a server) as
`MAC|IP|NAME` records separated by `;`:

```sh
ZD_PING_INTERVAL_SECONDS=60
ZD_PING_CLIENT_TARGETS='00:11:22:33:44:55|192.168.1.1|Gateway;00:11:22:33:44:56|1.1.1.1|Internet'
```

`50-network-monitor.sh` validates both, writes `/etc/zd1200-ping-monitor-defaults.conf`
into each root partition, and the collector's init script copies them into
`/writable` **once**. If the file already exists — because an administrator has
since changed the setting from the page — it is left untouched.

Unlike the upstream project, this fork installs the page from the same offline
patch pipeline as everything else
(`scripts/container/patches/50-network-monitor.sh`): the patch writes the i386
helper binaries, the shell collectors and the page into each root partition and
adds the menu entry to both admin bundles. The helpers are built inside the
Docker image by the `analytics-helper` stage (i386/static/musl, SQLite 3.7.17),
so the host still needs no compiler. Because the patch signature now includes
this payload, rebuilding the image with a changed page or binary re-customises
the roots on the next start.

---

## Root SSH on TCP 2222 (optional)

The stock ZD1200 dropbear cannot do public-key auth: it is a Ruckus-modified
build that advertises `password` only and whose custom `-A` option is
mandatory. To get key-based root access, the image can replace it with the
static musl build from
[`ms264556/zd_dropbear`](https://github.com/ms264556/zd_dropbear) (vendored
under `dropbear/`, see `dropbear/README.md`), which adds the Ruckus `-e`/`-A`
options *and* supports ordinary publickey auth.

Pass a public key to enable it:

```sh
./build-container.sh --root-ssh-key ~/.ssh/id_ed25519.pub
```

This is deliberately opt-in: the image build then downloads a ~110 MB musl.cc
cross toolchain and builds dropbear + OpenSSH from source, so the first build
is slow. With a key set, `scripts/container/patches/60-dropbear-static.sh`
installs the replacement and a public-key-only listener on TCP 2222:

```sh
ssh -p 2222 -i ~/.ssh/id_ed25519 root@<guest-ip>
```

The controller's stock host key is RSA/SHA-1, which modern OpenSSH rejects by
default; the **ECDSA host key** added by `scripts/container/patches/80-ecdsa-hostkey.sh`
(see below) means no `-o HostKeyAlgorithms=+ssh-rsa` override is needed. The
vendor binary is kept as `/usr/sbin/dropbear.vendor`, and port 22 keeps its
stock `-A none` + `/bin/login.sh` behaviour untouched. Omitting
`--root-ssh-key` on a later build turns the feature back off and restores the
vendor binary — the patch reverts its own changes.

---

## ECDSA SSH host key

The stock controller presents only an RSA/SHA-1 host key, so every client must
pass `-o HostKeyAlgorithms=+ssh-rsa`. `scripts/container/patches/80-ecdsa-hostkey.sh`
installs `S59zd_ecdsa_hostkey`, which generates a nistp256 key before
`S60dropbear` starts, and adds a second `-r` to `/etc/init.d/dropbear`. RSA is
retained, so legacy clients are unaffected, and the key lives on the writable
partition (`/etc/airespider` → `/writable/etc/airespider`) so it survives
upgrades. The 2222 root listener offers it too. Controlled by `ZD_ECDSA_SSH`
(default `1`); set it to `0` to revert.

---

## AP mesh repair (ap-11n-scorpion / R600 family)

Firmware 10.5.1.0.276 introduced a receive-path bug in the shared
`ap-11n-scorpion` AP image: a wired Root AP looks healthy, but a wireless Mesh
AP shows as connected and passes no ordinary Layer-2 traffic. 10.5.1.0.282 — the
release this project otherwise recommends — still carries it.

The image therefore repairs the AP firmware as it is staged, so the controller
delivers an already-fixed image and the appliance needs no in-guest tooling.
`scripts/container/build-synthetic-cf.py` calls `bl7/patch-scorpion-payload.py`
(ported from [`dbro/zd1200`](https://github.com/dbro/zd1200), see `bl7/README.md`)
on the extracted `/writable` tree: it converts the signed FSI image to unsigned
UI, `unsquashfs`/`mksquashfs`es the AP rootfs to patch `wlan.ko`, rebuilds the
BL7, and rewrites the `*_cntrl.rcks` size fields of every model that aliases
that one image (r600, r500, r310, t300, t300e, t301n, t301s).

Because the AP rootfs is historical LZMA SquashFS, the Dockerfile carries a
`ruckus-squashfs-tools` stage that builds the matching `unsquashfs`/`mksquashfs`
from pinned GPL-2.0 source. **R600 is the validated target**; the other models
are repaired only because they resolve to the identical vendor image, and an AP
still running fully signed FSI firmware must first be moved to a compatible ISI
release through its standalone upgrade page.

---

## Configuration

`build-container.sh` copies `docker/.env.example` to `.env` on first run. The
usual knobs:

| variable | purpose |
|---|---|
| `ZD_GUEST_IP` | guest management IP used for the printed URL (readiness itself is console-based) |
| `ZD_SIGN_CERT_HOST` | host path to the signing-cert payload for the license patch (extracted from the firmware archive by default) |
| `ZD_CONTAINER_MAC` | unique container MAC the guest identity is derived from (auto-generated into `.env` on first run) |
| `ZD_SERIAL`, `ZD_MAC1` | only used if you pin the identity (`ZD_BOARDDATA_FROM_MAC=0`) |
| `ZD_VIRTUAL_BUILD_ID` | seven-character source revision shown as `virtual <rev>` on the admin console; derived from Git unless pinned |
| `ZD_ROOT_SSH_PUBLIC_KEY` | public key (or path to a `.pub` file) enabling the static-dropbear replacement and root SSH on TCP 2222; same as `--root-ssh-key` |
| `ZD_ECDSA_SSH` | add an ECDSA host key alongside RSA on the administrative SSH service (default `1`; `0` reverts) |
| `ZD_PING_INTERVAL_SECONDS` | initial Network Monitor collection interval, 30–3600 seconds; seeded into `/writable` on the first boot only |
| `ZD_PING_CLIENT_TARGETS` | extra static ping targets as `MAC\|IP\|NAME` records separated by `;` |
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
- **The guest reboots by relaunching QEMU.** `launch-vm.sh` runs QEMU once
  per guest boot under `scripts/container/qemu-once.py`, which passes `-no-reboot` and maps
  the QMP `guest-reset` event to exit 10: the loop re-applies the patches and
  relaunches QEMU. A guest poweroff maps to exit 0 and stops the container
  (compose `restart: on-failure`, so a clean exit is not restarted).
- **Stopping the container is graceful.** On `docker compose stop`/`down`, the
  entrypoint asks the guest to shut down over a private second serial port
  (ttyS1) and `S98zd_container_control` runs the stock reboot path, so the
  controller flushes and the kernel unmounts `/writable` before QEMU is torn
  down. That is why `stop_grace_period` is 180s — do not lower it. If the guest
  does not respond within `ZD_STOP_TIMEOUT` (half-seconds), QEMU is killed and
  `prepare-vm-disks.sh` repairs the ext2 data partition on the next start.
  (ACPI is deliberately off to match the cob7402; QMP `system_powerdown` would
  need an ACPI power-button handler that this userspace does not have.)
- **In-guest firmware upgrades work.** A web-UI upgrade writes the new firmware
  onto the spare root partition and reboots. That partition has no sentinel, so
  the next start applies the kernel patch (to *its* `/bzImage`) and the rootfs
  patches to it and records the sentinel; the untouched root is left alone. A
  rollback to the other root needs nothing — it already carries a current
  sentinel. A fresh state volume still starts from whatever firmware you prepared
  into `image/`.
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
analytics/           Network Monitor payload (page, worker, collectors, helper
                     sources) ported from dbro/zd1200; the Dockerfile compiles
                     the i386 helpers from it
dropbear/            vendored zd_dropbear build script + patches for the optional
                     static dropbear replacement (built only with --root-ssh-key)
bl7/                 vendored BL7/SquashFS patch modules for the ap-11n-scorpion
                     (R600) mesh repair, applied while staging /writable
scripts/container/   entrypoint, guest-image prep, console helper, and the ordered
                     rootfs patches (its patches/ subdir) applied before each boot
scripts/build/       host-side vendor-image prep (firmware decrypt + extract)
scripts/test/        boot-test.sh (boot the prepared disk under QEMU) and console-reboot.py
image/               vendor-derived artifacts built from your firmware (gitignored)
```

## License

MIT — see `LICENSE`. The firmware (including the GRUB binaries this repo reuses)
is Ruckus/CommScope's, and is never committed or redistributed here.
