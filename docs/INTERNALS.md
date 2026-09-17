# ZD1200 container internals

Technical detail behind `install-zd1200-docker.sh` (Docker) and
`install-zd1200-lxc.sh` (Proxmox LXC). For the quick start, see
[../README.md](../README.md).

## Firmware archive handling

This repo does not ship firmware. `scripts/build/prepare-vendor-image.sh`
accepts a ZD1200 firmware upgrade file from Ruckus/CommScope support (e.g.
`zd1200_10.5.1.0.282.ap_10.5.1.0.282.img`). The download is TAC-encrypted and
`scripts/build/tac-decrypt.py` decrypts it; the decrypted payload is a gzipped
tar containing `metadata`, `bzImage`, `rootfs.i386.ext2.director1200.img`,
`restoreinitramfs.gz`, `menu.lst`, `firmwares/`, `aidfs/` and the AP models
list.

Any ZD1200 release works: the script validates `metadata`
(`REQUIRE_PLATFORM=nar5520`, `REQUIRE_SUBPLATFORM=cob7402`) and the kernel/rootfs
MD5s, and does not pin a version. The tested matrix is 10.5.1.0.282, 10.5.1.0.255,
10.2.1.0.236, 10.1.2.0.318, 9.13.3.0.164 and 9.10.2.0.130.

The archive layout differs between releases, independently of the version: some
payloads carry the web `aidfs` tree and the `signing_cert.pem` / `digital_sig_*`
files (e.g. 10.2.1.0.236 and 10.5.1.0.282), while others carry neither (e.g.
10.5.1.0.255, 10.1.x and 9.x all lack them; those releases serve the admin UI
straight from the rootfs). `prepare-vendor-image.sh` therefore requires only
what every release has (kernel, rootfs, boot menu, AP model list) and stages
`aidfs` and the signing cert only when they are present. The rootfs patches
adapt the same way: `20-signing-license.sh` applies the `check_sign_cert()`
bypass only when the cert exists but always applies the `verify-upload-support`
/ `wget-support-entitlement` shortcuts, which need no cert.

Set `EXPECTED_ARCHIVE_SHA256` to pin the decrypted payload; the 10.5.1.0.282
payload is
`64dfbf4d67cc65cafa0e258e426c664c7387b1219209ec893b9b1e41ab202cb8`.

The GRUB bootloader comes from the firmware's factory-restore initramfs
(`stage1`/`stage2`/`e2fs_stage1_5`, already built for the ZD1200 partition
layout). `scripts/container/build-bootfs.py` writes them into the boot area
together with the vendor `menu.lst` and a generated saved-default file. Nothing
is compiled and nothing is committed.

## CompactFlash dump parsing

A CF dump is a raw 1872 MiB disk (`3931200` × 512-byte sectors) for the ZD1200,
or a larger/smaller disk for other platforms. A Windows ImageUSB dump is the same
image with a 512-byte `imageUSB` header; it is detected and skipped.

Preparation runs inside the container image (which carries e2fsprogs/`debugfs`,
Python, `tar` and `gzip`), so the host needs only Docker. From a dump,
`prepare-vendor-image.sh` takes the boot files
(`/bzImage`, `/restoreinitramfs.gz`, `/restoreinitramfs.ver`,
`/lib/grub/i386-pc/menu.lst`), the rootfs (hda2) and `/writable` (hda4) straight
from the image, plus the board serial from the board-data record. The prepared
artifacts land in `image/`, including `image/writable.raw`.

A real card's `/writable` is reiserfs. No host-side reiserfs code is used: the
partition is copied verbatim and the guest kernel — which has reiserfs built in —
mounts it. `prepare-vm-disks.sh` inspects the filesystem and runs `e2fsck` only
for ext2; a reiserfs `/writable` is left to the guest's journal replay. (For this
reason the container does not depend on `reiserfsprogs`, and
`scripts/build/find-cf-partition.py` identifies partitions by the vendor
partition table plus the reiserfs magic, not by mounting.)

### Reviving a foreign /writable

A dump's `/writable` holds data and configuration only; it contains no ELF
executables, so nothing in it is platform-specific code. It can therefore be
paired with a ZD1200 firmware rootfs of the same version, e.g. to revive a
ZD1100 or ZD3000 card on a ZD1200 container:

```sh
./install-zd1200-docker.sh ~/images/zd1200_9.10.2.0.130.ap_*.img \
    --writable-from ~/images/zd1112_9.10.2.0.84.bin
```

The `/writable` partition is located from the dump's own vendor partition table
(an MBR-style sector ending in `0x55AA` whose entries describe the layout),
validated against the reiserfs superblock at the partition's 64 KiB mark, so the
dump's disk geometry need not match the ZD1200's. `--writable-partition
START:COUNT` overrides the detection. The board serial is used when the dump
carries a ZD1200-style board-data record; otherwise the serial is derived from
`ZD_CONTAINER_MAC` as usual. The data partition must fit the ZD1200 layout; a
smaller one is zero-padded into the partition (the reiserfs filesystem keeps its
own size).

Verified: a ZD1200 10.5.1.0.240 dump boots on its own rootfs and reiserfs
`/writable` (using the serial from its board-data record), and ZD1200 9.10.2.0.130
firmware paired with
a ZD1100 9.10.2.0.84 dump's `/writable` (detected at sectors `1909056 + 2021944`,
zero-padded into the ZD1200 data partition) boots with the ZD1100 AP payloads and
configuration in place.

## The `image/` directory

`install-zd1200-docker.sh` runs `scripts/build/prepare-vendor-image.sh` once to build
`image/` at the repo root (gitignored). It holds the vendor-derived
`rootfs.ext2`, `bzImage`, `restoreinitramfs.gz`, the signing-cert payload, the AP
firmware payload, and (for a dump or `--writable-from`) `writable.raw` and
`dump-boarddata`. It is mounted read-only into the container at
`/opt/zd1200/image`. Later runs reuse it; delete the directory (or re-run
`prepare-vendor-image.sh <input>`) to extract again.

The script writes wherever `IMAGE_DIR` points (default: the repo's `image/`), so
the LXC flow keeps the same contents under `/var/lib/zd1200/image` instead.

## Disk model

`docker/Dockerfile` builds a Debian image with QEMU and the guest-image tooling;
`docker/docker-compose.yml` runs it with `network_mode: host`, the
`NET_ADMIN`/`MKNOD`/`NET_RAW` capabilities and the `zd1200-state` volume.

The **Proxmox LXC** flavour runs the same guest-image tooling directly in a
Debian 13 container (`proxmox/`, see its README): no Docker image, no
`NET_ADMIN`-capable privileged CT, and the guest's tap is a port of a bridge
inside the CT rather than a macvtap. The differences are only in the launcher and
the layout:

| | Docker | Proxmox LXC |
|---|---|---|
| toolchain | inside the image | apt packages in the CT |
| `scripts/container/` | copied to `/opt/zd1200/` | stays a checkout at `/opt/zd1200/` |
| derived artifacts | bind-mounted `image/` + `zd1200-state` volume | `/var/lib/zd1200/` (image, disk, scratch) |
| guest NIC | macvtap on the host NIC (`NETWORK_MODE=macvtap`) | tap on a bridge inside the CT (`NETWORK_MODE=bridge`) |
| supervisor | the container entrypoint (compose restart policy) | `zd1200.service` (systemd) |
| host can reach guest | no (macvlan sibling isolation) | yes (ordinary bridge port) |

`scripts/container/build-synthetic-cf.py` takes its artifact directory from
`RUNTIME_DIR` and `scripts/build/prepare-vendor-image.sh` from `IMAGE_DIR`, both
defaulting to the Docker layout; the LXC bootstrap points them at the state
directory, which is why `scripts/container/` needs no copies in the LXC flow.

The synthetic CompactFlash is a flat raw image (there is no qcow2 overlay):

```
sda1  start 62     count 84506    /boot  (GRUB + kernel)
sda2  start 84568  count 415152   root A
sda3  start 499720 count 415152   root B
sda4  start 914872 count 3006008  /writable
```

`scripts/container/build-synthetic-cf.py` writes the boot area
(`build-bootfs.py`), the root partitions (from `image/rootfs.ext2`, with the
QEMU-patched kernel at `/bzImage`), and `/writable` — either seeded from the
archive payload (AP images + `aidfs`) as an ext2, or copied verbatim from
`image/writable.raw`. `scripts/container/write-boarddata.py` writes the board
data records and a partition-table-like sector at `3927001`, which the vendor
`v54bsp` CF reader requires before it will read the board data.

The rootfs is `resize2fs`'d to fill its partition only when it is genuinely
smaller (a dump's rootfs is already partition-sized and e2fsprogs refuses to
resize an unfsck'd `resize_inode` filesystem).

## Rootfs patch pipeline

`scripts/container/prepare-vm-disks.sh` builds the disk when it is missing or
the prepared input changed, then applies the QEMU kernel patch and the ordered
patches in `scripts/container/patches/` to whichever root partitions lack the
current patch-set sentinel (`/etc/.zd-image`). Re-runs are cheap: a start where
nothing changed just reads two sentinels. A guest firmware upgrade writes a new
rootfs to the spare root; that root has no sentinel and is customised on the next
start, while the untouched root is left alone.

The patches, in order:

| patch | effect |
|---|---|
| `10-rootfs-nolog.sh` | drop the reiserfs `nolog` mount option from `sys_init` |
| `20-signing-license.sh` | signing/entitlement bypass (`check_sign_cert()` when the cert exists, plus the `verify-upload-support` / `wget-support-entitlement` shortcuts) |
| `30-v54-root-shell.sh` | replace the `!v54!` passphrase helper (`sesame2` or `sesame`) with an exit-0 stub |
| `40-skip-integrity.sh` | rewrite `/file_list.txt` to `SKIP:` so the vendor integrity check reports nothing |
| `50-network-monitor.sh` | install the Network Monitor page, collectors and menu entry |
| `60-dropbear-static.sh` | optional static dropbear + public-key root SSH on 2222 |
| `70-container-control.sh` | `S98zd_container_control` orderly-shutdown hook |
| `80-ecdsa-hostkey.sh` | ECDSA host key alongside RSA |

Every patch decides from the files and patterns it finds (`sesame`/`sesame2`,
`check_sign_cert`/entitlement cases, `/web/admin10` vs the 9.x consoles, …)
rather than from a version number. The kernel patcher matches byte signatures,
with `rks_pkt_trace_init` optional because the 9.x kernels predate tif0. The one
exception is the R600 repair below.

## Network Monitor

The image carries the community **Network Monitor** page, ported from
[`dbro/zd1200`](https://github.com/dbro/zd1200) (see `analytics/README.md`). It
records one ICMP observation per managed device per collection interval, together
with the controller's own AP telemetry and opaque AP/client/mesh configuration
snapshots, and renders a per-target latency / loss / SNR / airtime history with
an A/B "compare two moments" workflow and a downloadable analysis prompt.

Collection is off on a fresh controller. Enable it, and pick the 30–3600 second
interval, from the ⚙ menu; the setting is stored through ZoneDirector's normal
authenticated preference mechanism. Runtime state lives on the writable
partition under `/writable/zd1200-ping-monitor/` and nothing is uploaded off the
controller.

`ZD_PING_INTERVAL_SECONDS` and `ZD_PING_CLIENT_TARGETS` pre-seed a fresh
appliance. `50-network-monitor.sh` validates both, writes
`/etc/zd1200-ping-monitor-defaults.conf` into each root partition, and the
collector's init script copies it into `/writable` once. If the file already
exists — because an administrator has since changed the setting — it is left
untouched.

The page, collectors and helpers are installed from the same offline patch
pipeline as everything else. The helpers are built inside the Docker image by the
`analytics-helper` stage (i386/static/musl, SQLite 3.7.17), so the host needs no
compiler; the page and binaries are part of the patch signature, so rebuilding
with a changed payload re-customises the roots.

The menu integration is version-aware. 10.x installs the page at `/web/admin10/`
and appends the entry to the Troubleshooting node of the `app.js` / `ruckus.js`
webpack bundles. 9.12/9.13 (the "Edison" console) installs it at `/web/admin/`,
adds a **Network Monitor** item under the Monitor menu in
`edison/js/common/systemMenu.js`, and loads a small module that iframes the page;
because `login.jsp` lands on the classic `dashboard.jsp`, the classic hook is
installed on those releases too. 9.9–9.11 (the classic console, whose menu is
compiled into `admin_template.mod`) appends a DOM hook to the plain
`/web/scripts/util.js`. The page derives its `/admin10` vs `/admin` URL base from
its own path, so its data-endpoint symlinks and its ZoneDirector preference
(`_conf.jsp`) call follow the console it is served from.

## Root SSH on TCP 2222

The stock ZD1200 dropbear cannot do public-key auth: it is a Ruckus-modified
build that advertises `password` only and whose custom `-A` option is mandatory.
With `--root-ssh-key`, the image replaces it with the static musl build from
[`ms264556/zd_dropbear`](https://github.com/ms264556/zd_dropbear) (vendored under
`dropbear/`), which adds the Ruckus `-e`/`-A` options and supports ordinary
publickey auth. The first build then downloads a ~110 MB musl.cc cross toolchain
and builds dropbear + OpenSSH from source, so it is slow.

`60-dropbear-static.sh` installs the replacement and a public-key-only listener
on TCP 2222 (`ssh -p 2222 -i <key> root@<guest-ip>`). The vendor binary is kept
as `/usr/sbin/dropbear.vendor` and port 22 keeps its stock `-A none` +
`/bin/login.sh` behaviour. Omitting `--root-ssh-key` on a later build restores
the vendor binary.

The 9.x releases have no `root` account (uid 0 is `admin`, home `/`), so the
`S61zd_root_ssh` boot hook synthesises a passwordless `root` (shadow entry `*`,
so only the public-key listener can use it) before starting the listener. On 10.x
`root` already exists and the step is a no-op. Logging in as either `root` or
`admin` yields a uid-0 shell.

## ECDSA SSH host key

The stock controller presents only an RSA/SHA-1 host key, so every client must
pass `-o HostKeyAlgorithms=+ssh-rsa`. `80-ecdsa-hostkey.sh` installs
`S59zd_ecdsa_hostkey`, which generates a nistp256 key before `S60dropbear`
starts, and adds a second `-r` to `/etc/init.d/dropbear`. RSA is retained, and
the key lives on the writable partition (`/etc/airespider` →
`/writable/etc/airespider`) so it survives upgrades. The 2222 listener offers it
too. Controlled by `ZD_ECDSA_SSH` (default `1`); set it to `0` to revert.

## AP mesh repair (ap-11n-scorpion / R600 family)

Firmware 10.5.1.0.276 introduced a receive-path bug in the shared
`ap-11n-scorpion` AP image: a wired Root AP looks healthy, but a wireless Mesh AP
shows as connected and passes no ordinary Layer-2 traffic. 10.5.1.0.282 — the
release this project otherwise recommends — still carries it.

The image repairs the AP firmware as it is staged, so the controller delivers an
already-fixed image and the appliance needs no in-guest tooling.
`scripts/container/build-synthetic-cf.py` calls `bl7/patch-scorpion-payload.py`
(ported from [`dbro/zd1200`](https://github.com/dbro/zd1200), see `bl7/README.md`)
on the extracted `/writable` tree: it converts the signed FSI image to unsigned
UI, `unsquashfs`/`mksquashfs`es the AP rootfs to patch `wlan.ko`, rebuilds the
BL7, and rewrites the `*_cntrl.rcks` size fields of every model that aliases that
image (r600, r500, r310, t300, t300e, t301n, t301s). Because the AP rootfs is
historical LZMA SquashFS, the Dockerfile carries a `ruckus-squashfs-tools` stage
that builds the matching `unsquashfs`/`mksquashfs` from pinned GPL-2.0 source.

**R600 is the validated target**; the other models are repaired only because they
resolve to the identical vendor image. **A repaired image requires the AP to
already run Solo 104 or 106 firmware**: the repair produces an unsigned image, and
an AP on anything older will not accept it, so the APs must be moved to Solo
104/106 through their own standalone upgrade page first. An AP still on fully
signed FSI firmware has the same prerequisite.

This is the one repair that keys off a version number: the helper reads the AP
image's own BL7 version and applies the fix only to a 10.5.1 build at or after
**10.5.1.0.276**, printing
`ap-11n-scorpion payload <ver> is not a 10.5.1 build >= 276; mesh repair skipped`
otherwise. Earlier 10.5.1 builds (.255 and before) are unaffected, and the image
is not touched at all when the payload has no `r600/` directory.

## Board data and identity

The board data (serial + MACs) is authoritative. `ZD_CONTAINER_MAC` (a unique,
locally-administered MAC generated into `.env` on first run) seeds the identity
when the base disk is built; from then on the board data on the disk wins. Every
start runs `scripts/container/read-boarddata.py` and uses the value read back for
the macvtap, the QEMU NIC and the DHCP sniffer, so a MAC changed in the
appliance's web UI is honoured on the next start. Re-seeding (a new
`ZD_CONTAINER_MAC`, or `ZD_BOARDDATA_FROM_MAC=0` with `ZD_SERIAL`/`ZD_MAC1`)
needs a fresh state volume. A CF dump's serial is used when present.

## Boot, restart and shutdown

`launch-vm.sh` runs QEMU once per guest boot under `scripts/container/qemu-once.py`,
which passes `-no-reboot` and maps the QMP `guest-reset` event to exit 10: the
loop re-applies the patches and relaunches QEMU. A guest poweroff maps to exit 0
and stops the container (compose `restart: on-failure`, so a clean exit is not
restarted).

On `docker compose stop`/`down`, the entrypoint asks the guest to shut down over
a private second serial port (ttyS1) and `S98zd_container_control` runs the stock
reboot path, so the controller flushes and the kernel unmounts `/writable` before
QEMU is torn down. That is why `stop_grace_period` is 180s — do not lower it. If
the guest does not respond within `ZD_STOP_TIMEOUT` (half-seconds), QEMU is killed
and `prepare-vm-disks.sh` repairs an ext2 data partition on the next start. ACPI
is deliberately off to match the cob7402, so QMP `system_powerdown` is not used.

QEMU also exposes an IPMI BMC (`ipmi-bmc-sim` + `isa-ipmi-kcs`), which the
firmware uses for watchdog and power handling, and a debug console
(`isa-debugcon`) on port 0x402, where pre-console output (SeaBIOS) is captured to
`/tmp/zd1200-debugcon.log`.

The LXC flow reuses the same entrypoint and launcher under systemd
(`zd1200.service` runs `scripts/container/entrypoint.sh` with `/etc/zd1200.conf`
in the environment). `systemctl stop zd1200` therefore takes the identical
orderly-shutdown path, and `TimeoutStopSec=300` gives the guest the same grace the
compose file's `stop_grace_period` does. The `NETWORK_MODE=bridge` case in
`launch-vm.sh` creates `tap-zd`, enslaves it to the bridge `zd1200-net.service`
built (`br-zd`), and hands it to QEMU; because the guest's tap and the CT's
uplink are ports of the same bridge, the CT can `curl` the guest directly and the
DHCP sniffer is not needed for reachability (it still records the lease for
`/var/lib/zd1200/guest-ip`).

## Boot test without the container

`scripts/test/boot-test.sh` boots the prepared disk under a direct QEMU (KVM, a
software IPMI BMC, user-mode networking — no macvtap, no LAN traffic) and watches
the serial console until it reaches a milestone. It is the quick way to check a
bootloader/rootfs change without disturbing the running container or the LAN.

```sh
./scripts/test/boot-test.sh                          # build + prepare + boot; pass when init runs
./scripts/test/boot-test.sh --firmware ~/images/zd1200_*.img  # first run: also prepare image/
./scripts/test/boot-test.sh --expect ready --timeout 300      # wait for the controller's READY marker
./scripts/test/boot-test.sh --reuse --no-build                # re-boot the disks already prepared
./scripts/test/boot-test.sh --reboot --expect ready           # reboot and re-check READY
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
`.boot-test/serial.log` (gitignored), the firmware's pre-console debug output at
`.boot-test/debugcon.log`, and each milestone is printed with its elapsed time.

`--reboot` drives the guest console (declining the setup wizard and logging in)
and runs `reboot`, then requires the milestone again — exercising the kernel's
`machine_restart` path. The console login comes from
`dropbear-provision/{passwd,shadow}` (a gitignored local input) seeded into
`/writable`; set `ZD_CONSOLE_USER`/`ZD_CONSOLE_PASSWORD` to use another account.
A freshly seeded appliance logs in as `admin`/`admin`.

The boot test never touches the running container's state volume.
