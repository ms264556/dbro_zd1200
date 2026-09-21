# ZD1200 container internals

Technical detail behind `install-zd1200-docker.sh` (Docker) and
`install-zd1200-lxc.sh` (Proxmox LXC). For the quick start, see
[../README.md](../README.md).

## Repository layout

```
packages/           payloads built into the appliance (see packages/README.md)
scripts/build/      host-side image preparation; scripts/build/proxmox/ is the PVE host helper
scripts/container/  the toolchain that runs inside the container/CT, plus its Proxmox units
scripts/test/       unit tests and the QEMU boot test
docker/             the Docker flavour's image and Compose file
docs/               internals, Proxmox and troubleshooting detail
```

`install-zd1200-docker.sh` and `install-zd1200-lxc.sh` at the root are the two
entry points.

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
10.4.1.0.272, 10.3.1.0.45, 10.2.1.0.236, 10.1.2.0.318, 9.13.3.0.164, 9.10.2.0.130
and 9.9.1.0.52.

The oldest release has no slack in its kernel gzip member, so the patched payload
recompresses past the member length (the boot decompressor reads a fixed input
size, so the member cannot grow). `patch-kernel.py` covers that by zeroing the
ELF's section header table and its name strings before the last recompression:
the boot ELF loader reads the program headers, and the section metadata is not
part of the loaded image. A release that already fits is left byte-for-byte
unchanged, so 9.9.1.0.52 is the only one that takes that path.

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
paired with a ZD1200 firmware rootfs of the same release — the first three
components of the version must match while the build number may differ
(`9.10.2.0.84` and `9.10.2.0.130` are interchangeable) — e.g. to revive a
ZD1100 or ZD3000 card on a ZD1200 container. The same rule applies when
restoring a configuration backup made by another build:

```sh
./install-zd1200-docker.sh ~/images/zd1112_9.10.2.0.84.bin \
    ~/images/zd1200_9.10.2.0.130.ap_*.img
```

The `/writable` partition is located from the dump's own vendor partition table
(an MBR-style sector ending in `0x55AA` whose entries describe the layout),
validated against the reiserfs superblock at the partition's 64 KiB mark, so the
dump's disk geometry need not match the ZD1200's. `--writable-partition
START:COUNT` overrides the detection. The board serial is taken from the dump
when one can be read from a known board-data location — the ZD1200 layout
(`REGION2_START` 3920881) or the ZD3000-family layout (3981601), accepting it
only when it is a plain number — otherwise the serial is derived from
`ZD_CONTAINER_MAC` as usual. The data partition must fit the ZD1200 layout; a
smaller one is zero-padded into the partition (the reiserfs filesystem keeps its
own size).

`--writable-from` is **refused unless the dump and the firmware are the same
release**, so the mismatch is caught before the disk is built rather than after
the guest boots. `/writable` itself carries no version (data and configuration
only), so the check reads the release out of the dump's own rootfs — `/bin/VERSION`,
the same file the vendor's upgrade check compares as `curver` (`sys_wrapper.sh`
`verify-upgrade`) — using the root partitions `find-cf-partition.py --roots`
locates from the same vendor partition table. The release is then compared with
the firmware metadata's `VERSION` down to the first three components, the
compatibility unit the vendor tools use (`getValidVer`/`isSameVer` in
`/bin/sys_wrapper.sh`, `VER_CHECK_POS="1 2 3"`), so only the build number may
differ. A dump whose version cannot be read is not a proven mismatch, so it
warns and continues; a CF dump used as the firmware input needs no check at all,
because its rootfs and `/writable` already come from the same card.

Verified: a ZD1200 10.5.1.0.240 dump boots on its own rootfs and reiserfs
`/writable` (using the serial from its board-data record), and ZD1200 9.10.2.0.130
firmware paired with
a ZD1100 9.10.2.0.84 dump's `/writable` (detected at sectors `1909056 + 2021944`,
zero-padded into the ZD1200 data partition) boots with the ZD1100 AP payloads and
configuration in place.

A dump also carries its source model's AP licensing. `/writable/etc/airespider/
license-list.xml` (usually a symlink to `/etc/airespider-images/license-list.xml`)
holds `<license-list max-ap="N">`, and the vendor license manager reads `N` as the
model's built-in APs plus the sum of the child `<license>` `inc-ap` values. A
ZD1100 carries 6 or 11 built-ins and a ZD3000 50 or 100, while a ZD1200 provides
5, so a foreign list silently loses `(source built-in - 5)` APs — and its
`serial-number` attributes still name the source box. Patch 25 installs the
`S49zd_license` guest hook, which runs on the first boot after `sys_init` has
mounted `/writable` read-write (and before `S50controller` reads the list): every
`<license>` serial-number is set to `/bin/SERIAL`, and one compensating
`<license>` is added so that `sum(inc-ap) == max-ap - 5`. The hook has to run in
the guest because the host has no reiserfs writer; it is stamped
`generated-by=zd1200-container` (the attribute the UI shows as the Sales Order
Number), so a later boot finds the stamp and leaves that element
alone (only the serial repair is re-applied). Buying a license adds its own
`<license>` and raises `max-ap` by the same amount, so the compensation is never
re-derived — shrinking or dropping it would lose the built-in APs for good. The
element also carries `DELETABLE="false"` (the attribute the web UI's Delete
button honours; absent means deletable), re-added on every boot if it is stripped.
A native ZD1200 list already satisfies the arithmetic, so the hook only repairs
its serials; `--writable-from` is the case it exists for.

## Configuration backup restore (`--backup`)

A configuration backup (`ruckus_db_*.bak`) is the appliance's XML configuration
and certificates packed by the vendor's `sys_wrapper.sh save-backup`: the same
TAC-encrypted gzip tar container a firmware archive uses, with a `metadata` file
(`PURPOSE=backup`, `VERSION`, `PLATFORM`, `APMODEL`) plus `etc/airespider/`. Both
installers accept it as an input argument (the named `--backup` alias still
works) alongside a firmware upgrade file, and the appliance arrives with that
configuration instead of a factory one. The installers classify every input from
its contents before anything is created — a card dump by its geometry, and a
TAC/gzip archive by decrypting it and reading its metadata — so the documented
errors name what the operator actually passed (see `resolve_inputs` in
`scripts/install-common.sh`).

Preparation is host-side and inside the runtime
(`scripts/build/prepare-vendor-image.sh --backup`): it decrypts the backup with
`tac-decrypt.py`, requires `PURPOSE=backup`, and requires the backup's release to
match the firmware's first three version components — the same compatibility unit
`--writable-from` uses, and the rule under which the vendor's `verify-backup`
accepts a restore without a migration path. The release is the only gate: Ruckus
only restores a backup onto an equal or larger model, so a ZD3000/ZD5000 backup
would be refused on a ZD1200. `scripts/build/unlock-backup.py` removes that gate
by rewriting the metadata (`PLATFORM=ar7161`, `APMODEL` dropped), and
`tac-encrypt.py` re-encrypts the result, so a backup from any ZoneDirector model
is staged at `image/backup.bak`. It remains TAC-encrypted, so the guest's
`verify-backup` runs as it would for the Web UI's original, including its release
check, and still reports the backup's management address.

`scripts/container/build-synthetic-cf.py` copies `image/backup.bak` into the
`/writable` it seeds, at `/zd1200-restore/backup.bak`. It only does so for a
firmware-derived `/writable`: a CF dump or `--writable-from` already carries a
configuration, and combining either with `--backup` is refused before the disk
is built.

**The container, not the guest, is what makes the restore one-shot.** A
configuration restore overwrites everything the operator has configured since,
so it must never run twice, and the guest's `/writable` cannot be trusted to
remember that it already ran: the vendor can reimage it, and a factory reset
would discard any marker kept there. The container owns the decision instead:

* the backup is a disk-build input, and `prepare-vm-disks.sh` only ever writes a
  fresh `/writable` when it builds a disk. It records the seed — the backup hash
  as `backup=` in the state marker and, explicitly, in `$STATE_DIR/.backup-seeded`
  — so a start can tell that the disk already carries it.
* a live disk is never rebuilt and re-seeded: a newly supplied backup that the
  existing disk was not built with requests a rebuild, which is refused for an
  existing appliance unless the operator accepts the factory reset
  (`ZD_ALLOW_DISK_REBUILD=1`). A factory reset discards `/writable`, so a fresh
  restore there is a new appliance, not a second one.

The guest's half is patch 26: `/etc/zd1200-restore.sh`, run by the
`/etc/init.d/S48zd_restore` rcS entry after `S47migrate` has mounted `/writable`
and before `S50controller` starts. It is a no-op unless a backup is staged, so
the patch set is constant whether or not `--backup` was used. When one is, it
copies it to a work file and drives the vendor path exactly as the Web UI does —
`sys_wrapper.sh verify-backup` (decrypt, platform/model/release checks) then
`sys_wrapper.sh restore-saved` (`restoreSaved`'s factory clean, configuration
move, release migration and AP customisation) — then reboots once, so the
restored management address and every boot-time service take effect. Before
rebooting it renames the staged file to `backup.bak.applied`, so even a second
boot of the same disk finds nothing to do; that consume is the guest's only job
here, and it needs no persistent marker. It also prints
`ZD-CONFIG-RESTORED=applied` (or `failed`) on its serial console, the channel the
container already captures.

The container observes that line in `launch-vm.sh` after each guest boot: on
`applied` it appends `restored=applied` to the state seed marker and retires its
own copy of the backup (`image/backup.bak` → `image/backup.bak.staged`) where the
filesystem allows, so a later rebuild cannot re-stage a backup the appliance has
already consumed. In the Docker flavour `image/` is mounted read-only, so the
copy stays but is inert: the state marker and the refuse-to-rebuild gate are what
prevent a second restore. A backup the vendor rejects (or a failed restore) is
renamed `backup.failed` and the appliance keeps its factory configuration rather
than boot-looping, with the run logged to `/writable/zd1200-restore/restore.log`
and reported to the container as `ZD-CONFIG-RESTORED=failed`.

An already-decrypted gzip tar (a `*.tgz` saved next to a `.bak`) has no TAC layer
to strip, so the hook tells it apart with `gzip -t` and hands it straight to
`restore-saved`; the release check then rests on the installer's host-side
validation.

AP licences get special handling. The vendor's `restoreSaved` deliberately drops
them — it removes the backup's `license*.xml` from the restore set and keeps the
running appliance's, because on real hardware a licence names the box it was
bought for. A clone wants the source's add-on APs, so before restoring the hook
pulls the licence list back out of the archive — the live
`etc/airespider/license-list.xml` when the source stored it as a file, otherwise
the vendor's `etc/airespider/license-list.bak.xml` revision (the live name is
often a symlink, and `save-backup` archives the link, not its target) — and
writes it back into `/writable/etc/airespider-images/license-list.xml` after the
restore, recreating the vendor's `/etc/airespider/license-list.xml` symlink if
needed. Patch 25's `S49zd_license` then repairs its serials and built-in count on
the next boot, exactly as it does for a `--writable-from` dump. An archive with
neither file leaves the appliance's own list alone, and so does one whose only
list is an empty `<license-list>` (a factory box that never had a licence
written, as a 9.9 backup can be): reinstating that would drop the container's
built-in APs. Only a list that names `max-ap` or a `<license>` is applied.

## The `image/` directory

`install-zd1200-docker.sh` runs `scripts/build/prepare-vendor-image.sh` once to build
`image/` at the repo root (gitignored). It holds the vendor-derived
`rootfs.ext2`, `bzImage`, `restoreinitramfs.gz`, the signing-cert payload, the AP
firmware payload, (for a dump or `--writable-from`) `writable.raw` and
`dump-boarddata`, and (for `--backup`) `backup.bak`. It is mounted read-only
into the container at `/opt/zd1200/image`. Later runs reuse it; delete the
directory (or re-run `prepare-vendor-image.sh <input>`) to extract again.

The script writes wherever `IMAGE_DIR` points (default: the repo's `image/`), so
the LXC flow keeps the same contents under `/var/lib/zd1200/image` instead.

## Disk model

`docker/Dockerfile` builds a Debian image with QEMU and the guest-image tooling;
`docker/docker-compose.yml` runs it with `network_mode: host`, the
`NET_ADMIN`/`MKNOD`/`NET_RAW` capabilities and the `zd1200-state` volume.

The **Proxmox LXC** flavour runs the same guest-image tooling directly in a
Debian 13 container (`scripts/container/proxmox/`, see
[docs/PROXMOX.md](PROXMOX.md)): no Docker image, no
`NET_ADMIN`-capable privileged CT, and the guest's tap is a port of a bridge
inside the CT rather than a macvtap. The differences are only in the launcher and
the layout:

| | Docker | Proxmox LXC |
|---|---|---|
| toolchain | inside the image | apt packages in the CT |
| `scripts/container/` | copied to `/opt/zd1200/` | stays a checkout at `/opt/zd1200/` |
| payload packages | `packages/` copied to `/opt/zd1200/packages/` | `scripts/container/packages` links to the checkout's `packages/` |
| derived artifacts | bind-mounted `image/` + `zd1200-state` volume | `/var/lib/zd1200/` (image, disk, scratch) |
| guest NIC | macvtap on the host NIC (`NETWORK_MODE=macvtap`) | tap on a bridge inside the CT whose uplink is cross-connected (`NETWORK_MODE=bridge`) |
| supervisor | the container entrypoint (compose restart policy) | `zd1200.service` (systemd) |
| host can reach guest | no (macvlan sibling isolation) | yes (the tap is an ordinary bridge port) |

`scripts/container/build-synthetic-cf.py` resolves `image/` and `packages/`
relative to its own directory (or `RUNTIME_DIR`), and
`scripts/build/prepare-vendor-image.sh` takes `IMAGE_DIR`; the LXC bootstrap links
those names inside the checkout to the state directory, which is why
`scripts/container/` needs no copies in the LXC flow.

### More than one appliance on a host

The Proxmox flow is already multi-instance: each CT has its own network
namespace and `/tmp`, so its `mvt0`/console/control names are its own.

The Docker flow is not, by default: `network_mode: host` puts every container in
the host's network namespace, so the macvtap interface (`mvt0`) and the QEMU
chardev sockets under `/tmp` are host-global. A second container with the same
names finds the first one's macvtap and sets *its* MAC on it — the last container
to start then owns the tap and the other guest goes dark — and binding the same
chardev socket path fails or replaces the first. `install-zd1200-docker.sh`
therefore derives unique names from `ZD_CONTAINER_NAME` and writes
`ZD_MACVTAP_IF`, `ZD_CONTROL_SOCK`, `ZD_CONSOLE_SOCK` and `LOG_FILE` into `.env`
(compose passes them through; `launch-vm.sh` and `entrypoint.sh` already read
them). The default instance keeps the historical `mvt0` and
`/tmp/zd1200-*.sock` names, so an existing install does not move. Give each
instance its own checkout directory (compose scopes the container name and state
volume to the project name) and a distinct `ZD_CONTAINER_NAME`.

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
current patch-set sentinel. Re-runs are cheap: a start where nothing changed just
reads two sentinels.

Each root partition carries a rollback store at `/.patchrollback/`:

| entry | meaning |
|---|---|
| `sentinel` | signature of the patch set applied to this root |
| `kernel` | hash of `patch-kernel.py` that customised `/bzImage` |
| `replaced.list`, `replaced/<n>`, `replaced/<n>.meta` | the pristine vendor copy (content, plus mode/uid/gid) of every file a patch replaced |
| `added` | paths a patch created, deleted again on reset |

Every patch writes through `scripts/container/patch-lib.sh`, which stores the
vendor copy before replacing a file and records a path before creating one. When
the sentinel no longer matches — a patch was added, edited or removed, or a
feature/environment value in the signature changed — `prepare-vm-disks.sh`
restores every replaced file and deletes every added path *before* re-running the
whole set, so each patch always starts from the vendor rootfs rather than from the
output of an earlier patch set. `/writable` (hda4) is never involved, which is
what lets an upgrade keep the appliance's configuration.

The kernel is the one deliberate exception: it is not copied into the store (it
is the largest file the pipeline touches, and its transform is deterministic).
`/bzImage` is keyed on the hash of `patch-kernel.py` instead, so a root already
carrying the QEMU patches is left alone and the patcher never has to recognise an
already-patched kernel.

A guest firmware upgrade writes a new rootfs to the spare root; that root has no
store and no sentinel, so it is customised normally and the untouched root is
skipped. A root that carries the pre-rollback sentinel (`/etc/.zd-image`) and no
store is refused rather than re-patched: there is no pristine copy to restore, and
re-running the patches against already-patched files is exactly what the store
exists to avoid.

The store itself is unit-tested without firmware or QEMU:
`scripts/test/patch-lib-test.sh` builds a throwaway ext2 "rootfs", applies a patch
set, resets it, re-applies a changed set and asserts that vendor content, modes
and symlinks come back and that a repeat run is byte-for-byte deterministic.

The patches, in order:

| patch | effect |
|---|---|
| `10-rootfs-nolog.sh` | drop the reiserfs `nolog` mount option from `sys_init` |
| `20-signing-license.sh` | signing/entitlement bypass (`check_sign_cert()` when the cert exists, plus the `verify-upload-support` / `wget-support-entitlement` shortcuts). The patched `verify-upload-support` generates `/tmp/support` — the file emfd's `checkSupport()` parses — with the serial read from `/bin/SERIAL` at run time, and writes the matching record; a baked serial can never match, because emfd compares it against that file. `S48zd_ntp_result` seeds the `/tmp/ntp_result` marker the upgrade verifier requires |
| `25-writable-license.sh` | install the `S49zd_license` guest hook that repairs a foreign `/writable` license list: serials from `/bin/SERIAL` and a compensating `<license>`, so its built-in AP count survives on the ZD1200 (see [Reviving a foreign /writable](#reviving-a-foreign-writable)) |
| `26-backup-restore.sh` | install `/etc/zd1200-restore.sh` and its `S48zd_restore` rcS entry, which apply a staged `--backup` configuration on the first boot through the vendor `sys_wrapper.sh` restore (see [Configuration backup restore](#configuration-backup-restore-backup)) |
| `30-v54-root-shell.sh` | replace the `!v54!` passphrase helper (`sesame2` or `sesame`) with an exit-0 stub |
| `35-rbd-mac-guard.sh` | stop the guest's own board-data tool (`/bin/rbd.sh`) from moving the MAC: an invocation that supplies an OUI/MAC1/MAC2 is refused before `rbd change` runs, while serial/model/customer updates still work. The container re-asserts its MAC in the board data before every launch (see [Board data and identity](#board-data-and-identity)) |
| `40-skip-integrity.sh` | disable the md5 verification in `chk_integrity.sh` so the vendor integrity check reports nothing for our patched files; the file list is left intact so `flag_reset`'s `clone` still copies the tree |
| `45-zd-bmc-watchdog.sh` | `S46zd_bmc_watchdog` arms and feeds the in-box IPMI BMC watchdog, stopping when the kernel writes the `'9'` kflag |
| `50-network-monitor.sh` | install the Network Monitor page, collectors and menu entry |
| `60-dropbear-static.sh` | optional static dropbear + public-key root SSH on 2222 |
| `70-container-control.sh` | `S98zd_container_control` orderly-shutdown hook |
| `80-ecdsa-hostkey.sh` | ECDSA host key alongside RSA |
| `90-file-list.sh` | append the patch-created paths and the `/.patchrollback` store to `/file_list.txt`, so the vendor root repair (`flag_reset`'s clone) reproduces a patched root |

Every patch decides from the files and patterns it finds (`sesame`/`sesame2`,
`check_sign_cert`/entitlement cases, `/web/admin10` vs the 9.x consoles, …)
rather than from a version number, and the kernel patcher identifies its sites by
byte signature. The one exception is the R600 repair below, which is gated on the
firmware version.

## Upgrading an existing appliance

Both entry points take `--upgrade`, which rebuilds the container/CT from the
current checkout and re-customises the roots in place:

```sh
./install-zd1200-docker.sh --upgrade        # Docker
./install-zd1200-lxc.sh --upgrade [--ctid N]  # Proxmox (finds the container it made)
```

`--upgrade` takes no firmware argument and never re-prepares `image/` or rebuilds
the CF disk, so `/writable` — the appliance's configuration — is preserved. The
changed patch signature makes the next start restore the roots from their
rollback store and re-apply the whole set. An explicit `--root-ssh-key` replaces
the provisioned key; otherwise the existing one is kept (and the 2222 listener
with it). The LXC flow likewise keeps the feature set and console/address
settings already in `/etc/zd1200.conf`.

Changing the firmware itself is intentionally *not* part of `--upgrade`:
`prepare-vm-disks.sh` refuses to rebuild an existing disk (which would discard
`/writable`) when `image/` no longer matches what the disk was built from. Accept
a factory reset by removing the state volume/directory, or set
`ZD_ALLOW_DISK_REBUILD=1` deliberately.


## Network Monitor

The image carries the community **Network Monitor** page, ported from
[`dbro/zd1200`](https://github.com/dbro/zd1200) (see `packages/analytics/README.md`). It
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
`packages/dropbear/`), which adds the Ruckus `-e`/`-A` options and supports ordinary
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
`scripts/container/build-synthetic-cf.py` calls `packages/mesh-patch/patch-scorpion-payload.py`
(ported from [`dbro/zd1200`](https://github.com/dbro/zd1200), see `packages/mesh-patch/README.md`)
on the extracted `/writable` tree: it converts the signed FSI image to unsigned
UI, `unsquashfs`/`mksquashfs`es the AP rootfs to patch `wlan.ko`, rebuilds the
BL7, and rewrites the `*_cntrl.rcks` size fields of every model that aliases that
image (r600, r500, r310, t300, t300e, t301n, t301s). Because the AP rootfs is
historical LZMA SquashFS, the Dockerfile carries a `ruckus-squashfs-tools` stage
that builds the matching `unsquashfs`/`mksquashfs` from pinned GPL-2.0 source.

**The repair targets AC Wave 1 APs (e.g. R600)**: every model that resolves to
the identical vendor image gets the same repaired image. **A repaired image
requires the AP to already run Solo 104 or 106 firmware**: the repair produces an
unsigned image, and an AP on anything older will not accept it, so the APs must be
moved to Solo 104/106 through their own standalone upgrade page first. An AP still
on fully signed FSI firmware has the same prerequisite.

This is the one repair that keys off a version number: the helper reads the AP
image's own BL7 version and applies the fix only to a 10.5.1 build at or after
**10.5.1.0.276**, printing
`ap-11n-scorpion payload <ver> is not a 10.5.1 build >= 276; mesh repair skipped`
otherwise. Earlier 10.5.1 builds (.255 and before) are unaffected, and the image
is not touched at all when the payload has no `r600/` directory.

## Board data and identity

The board data (serial + MACs) is authoritative for the guest: the vendor
v54bsp driver forces `MAC1` onto NIC[0] at boot. On Docker `ZD_CONTAINER_MAC`
(a unique, locally-administered MAC generated into `.env` on first run) seeds
the identity when the base disk is built; on Proxmox the seed is the container's
own uplink MAC, which the installer shares by default.

The container owns the MAC. Before every launch `launch-vm.sh` resolves it — the
live uplink interface on Proxmox, `ZD_MAC1` on Docker — uses it for the QEMU NIC
and rewrites the MAC fields into the board data with
`write-boarddata.py --mac-only`, which preserves the serial, model and customer
the records carry. `35-rbd-mac-guard.sh` also stops the guest's `/bin/rbd.sh`
from moving the MAC from inside. The LAN therefore always sees the container's
identity, and a MAC changed in the appliance's web UI (or with `rbd.sh`) is
reverted on the next boot. Re-seeding (a new `ZD_CONTAINER_MAC`, or
`ZD_BOARDDATA_FROM_MAC=0` with `ZD_SERIAL`/`ZD_MAC1`) needs a fresh state volume.
A CF dump's serial is used when present.

## Boot, restart and shutdown

`launch-vm.sh` runs QEMU once per guest boot under `scripts/container/qemu-once.py`,
which passes `-no-reboot` and maps the QMP `guest-reset` event to exit 10: the
loop re-applies the patches and relaunches QEMU. A guest poweroff maps to exit 0
and stops the appliance instead of restarting it: under Compose the entrypoint's
exit is the container's (`restart: on-failure` does not restart a clean exit), and
the LXC unit sets `ZD_POWEROFF_CONTAINER=1` so the entrypoint shuts the container
down rather than leaving it running with no appliance in it.

On `docker compose stop`/`down`, the entrypoint asks the guest to shut down over
a private second serial port (ttyS1) and `S98zd_container_control` runs the stock
reboot path, so the controller flushes and the kernel unmounts `/writable` before
QEMU is torn down. That is why `stop_grace_period` is 180s — do not lower it. The
request is resent every 5s until QEMU exits: that init script starts late in the
guest's init, so a stop issued in the first seconds after a boot could otherwise
arrive before anything was reading ttyS1 and cost the whole grace period
(measured: 8s for a running guest, 17s worst case just after READY, against 121s
before the resend). If the guest never responds within `ZD_STOP_TIMEOUT`
(half-seconds), QEMU is killed and `prepare-vm-disks.sh` repairs an ext2 data
partition on the next start.

QEMU is launched with ACPI on (`-machine pc`) and `-smp 2`, even though the real
cob7402 has no ACPI. ACPI is what gives the guest a CPU table it can enumerate a
second vCPU from, and the vendor watchdog driver assumes two: `nar5520_wdt_init()`
starts one `V54_watchdog` thread per online CPU and the loop then sleeps
`HZ*TIMEOUTTRG*(cpu_count/NUM_GCPUS)` with `NUM_GCPUS == 2`. With a single vCPU
that expression is 0, `schedule_timeout(0)` spins, the userspace watchdog counter
collapses and the thread sits in its u-watchdog-timeout block. `ZD_MACHINE` and
`ZD_SMP` override the pair. QMP `system_powerdown` is not used: the guest has no ACPI userspace handler, so an orderly stop goes through the ttyS1 control
channel as described below.

QEMU also exposes an IPMI BMC (`ipmi-bmc-sim` + `isa-ipmi-kcs`), which the
firmware uses for watchdog and power handling, and a debug console
(`isa-debugcon`) on port 0x402, where pre-console output (SeaBIOS) is captured to
`/tmp/zd1200-debugcon.log`.

The BMC watchdog is also the guest's real reset vector. In the vendor chain,
`/bin/wd_feeder` kicks `/dev/watchdog`, `nar5520_wdt_thread()` kicks a W627
Super-I/O watchdog, and if userspace stops feeding, the kernel writes the
`KFLAG_WDT_REBOOT` `'9'` marker to byte 0 of both root partitions and stops
kicking the W627, which then resets the box. `-machine pc` has no W627, so
`S46zd_bmc_watchdog` (installed by the `45-zd-bmc-watchdog` rootfs patch) arms
the in-box IPMI BMC watchdog and feeds it every 10s. As soon as byte 0 of either
root reads `'9'` — the same moment the driver would have stopped refreshing the
W627 — it points the saved GRUB entry at the other root and then stops feeding,
and the BMC hard-resets the machine.

That flag move is what makes the fallback deterministic. `/etc/init.d/flag_reset`
resets the saved entry back to the running root on every healthy boot, so a
watchdog timeout on a long-running guest would otherwise bring that same root up
again; the vendor's GRUB does not reroute on the marker alone. Only this marker
does it: the container's probe-based guest watchdog (`zd1200-guest-watchdog`)
reboots a silent guest without touching the boot entry, so that reboot returns to
the same root. Moving the flag uses the vendor's own `grub-set-default` + `mv`,
exactly as `flag_reset` and `ac_upg.sh` do, and is self-correcting: if the reset
never comes, the next healthy boot's `flag_reset` resets the entry again. GRUB
then boots the other root (`/dev/sda3` for a guest that was on `/dev/sda2`), and
that boot's `flag_reset` clones the running root back over the failed one and
swaps the two roots' menu entries. The clone is driven by `/file_list.txt`; the
`90-file-list.sh` patch appends the paths the project adds — the patch-created
files and the `/.patchrollback` store — so the repaired root is a faithful copy
of the running one, store and sentinel included, and `prepare-vm-disks.sh` skips
it instead of re-applying the whole patch set on top of already-patched files.

The saved entry can also be a rescue entry. GRUB's menu has two root entries
(0/1), the factory-restore initramfs (2) and the USB restore tool (3), and the
vendor's `savedefault` ladder advances current root → spare root → rescue.
Before each QEMU launch `prepare-vm-disks.sh` computes the entry GRUB would
actually boot — `scripts/container/grub-effective-entry.sh`, which applies the
same kflag decrement as the patched `default_func()`, so a spare-root retry is
not mistaken for the rescue — and refuses to start if it is a rescue entry. The
vendor restore tool cannot drive the guest (it expects a TFTP server and
`/dev/hda*`) and would write vendor images over the patched roots. It logs how to
rebuild the machinery from a firmware image while carrying `/writable` over and
exits with status 4, which `launch-vm.sh` propagates and `entrypoint.sh` turns
into a clean container stop (Proxmox: the container powers off). That is a
pre-QEMU check only: if both root images fail to *load*, GRUB's own `fallback 1 2`
still reaches the rescue inside QEMU, which the container cannot see — the
console shows the fallthrough. See
[Recovering from the rescue entry](TROUBLESHOOTING.md#recovering-from-the-rescue-entry)
for both cases, what the operator sees and the recovery procedure.

The LXC flow reuses the same entrypoint and launcher under systemd
(`zd1200.service` runs `scripts/container/entrypoint.sh` with `/etc/zd1200.conf`
in the environment). `systemctl stop zd1200` therefore takes the identical
orderly-shutdown path, and `TimeoutStopSec=300` gives the guest the same grace the
compose file's `stop_grace_period` does. The `NETWORK_MODE=bridge` case in
`launch-vm.sh` creates `tap-zd`, enslaves it to the bridge `zd1200-net.service`
built (`br-zd`), and hands it to QEMU; because the guest's tap and the CT's
uplink are ports of the same bridge, the CT can `curl` the guest directly and the
connectivity is direct: the container asks the guest for its own address over the
control serial channel (the same private port used for the orderly shutdown) and
caches the answer in `/var/lib/zd1200/guest-ip` for display and health checks.
The guest's lease is authoritative, so nothing is sniffed or guessed.

The LXC flow also puts the guest's ttyS0 — the console the stock inittab runs
`/bin/login.sh` on — on the container's `/dev/tty1`, through
`scripts/container/proxmox/zd1200-console-bridge.py` (unit `zd1200-console-tty.service`), so the
Proxmox Console tab lands on the appliance's serial console. QEMU's console
chardev answers a single client, so the bridge owns that socket and re-serves
the public one that `attach-console.py` uses; it writes the tty non-blockingly
so an unattached tab cannot stall the guest. See "The Console tab" in
`docs/PROXMOX.md`.

The container's own address is likewise maintenance-only: the patch pipeline is
local and the periodic healthchecks use the guest's serial control channel, so
`zd1200.service` releases the bridge's address with `scripts/container/proxmox/zd1200-ct-address`
just before QEMU starts and takes a fresh DHCP lease when QEMU exits. The
appliance is then the only thing on the LAN with an address while it runs; see
"The container's own address" in `docs/PROXMOX.md`.

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
