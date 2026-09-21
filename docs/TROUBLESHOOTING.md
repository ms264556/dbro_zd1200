# Troubleshooting the ZD1200 appliance

Symptom-to-fix for both the Docker and Proxmox flavours. For the quick start and
the installation constraints, see [../README.md](../README.md).

## First steps for any failure

The guest's own console is where the reason usually is:

```sh
docker logs zd1200 | tail -80                                  # Docker
docker exec zd1200 tail -80 /tmp/zd1200-console.log

pct exec <id> -- journalctl -u zd1200 -n 80                    # Proxmox
pct exec <id> -- tail -80 /tmp/zd1200-console.log
```

The container reports healthy only once the guest answers on the network, so a
container that stays `health: starting` (Docker) or a guest that never leases is
the common shape of a problem.

On Proxmox the installer's own console output is deliberately short: the rootfs
patch pipeline narrates every changed block, so it is written to a log instead.

```sh
pct exec <id> -- tail -50 /var/lib/zd1200/install.log    # the whole install, in detail
```

A step that fails prints the end of that log to the console, and the install stops
there rather than continuing.

## Problems starting

| symptom | cause and fix |
|---|---|
| `Cannot reach the Docker daemon`, or socket `permission denied` | add yourself to the `docker` group (`sudo usermod -aG docker $USER`, re-login) or run with `sudo` |
| container restart-loops | read the real error with the commands above. A missing `/dev/kvm` is not fatal (TCG is just slow), but a failed disk patch or a bad input is |
| `firmware file not found`, or `vendor archive lacks ...` | wrong path, or the file is not a ZD1200 upgrade image / CF dump |
| `no valid board-data record with a MAC found` | the dump's board data is outside the ZD1200 offsets; the container derives its identity from `ZD_CONTAINER_MAC` instead (see `docs/INTERNALS.md`) |
| `could not detect the /writable partition` | pass `--writable-partition START:COUNT`, from `scripts/build/find-cf-partition.py <dump> <header-offset>` (header offset is 512 for ImageUSB, else 0) |
| `image/writable.raw is ... larger than the data partition` | the foreign `/writable` is bigger than the ZD1200 layout; use a same-version ZD1200 firmware, or a smaller card |
| `the dump's rootfs is release X but the firmware is release Y` / `the backup is release X but the firmware is release Y` | the backup or dump and the firmware are different releases. The first three version components must match (any build), because `/writable` is only interchangeable within a release; the message names the firmware to pass |
| `pass a backup or a dump, not both` | two configuration inputs were given (e.g. a ZD1200 card dump and a ZD1100/ZD3000 dump, or a dump and a `ruckus_db_*.bak`). Pass one |
| `... is a ZD configuration backup of release X: a firmware (version X) must also be passed` | a backup or a ZD1100/ZD3000 dump carries the configuration but not a ZD1200 kernel/rootfs. Pass the matching firmware as the second argument (a ZD1200 card dump needs none) |
| *(Proxmox)* `Unsupported NIC model: igb` | the container's QEMU is too old for the guest's NIC. Use a Debian 13 template; the installer checks this before provisioning |
| *(Proxmox)* installer refuses the template | it is not Debian 13. The installer fetches Debian 13 when none is present |
| *(Proxmox)* `could not install QEMU in container <id>` | the container has no working outbound network for apt |
| `refusing to rebuild an existing appliance` (the firmware changed, or a configuration backup was added) | `image/` no longer matches what the disk was built from, and rebuilding would discard `/writable`. Put the old `image/` back, or upgrade with `--upgrade` (which never re-prepares `image/`), or accept a factory reset (see [Clean state](#clean-state)) / set `ZD_ALLOW_DISK_REBUILD=1` |
| `was customised by an older version ... no /.patchrollback store` | the rootfs was patched before the rollback store existed, so it cannot be re-patched safely. Reset the state and install again from firmware |
| `the kernel patcher failed for hda2/hda3` | the kernel no longer matches `patch-kernel.py` (unexpected firmware, or a kernel patch set that changed after the root was built). The tail of the log is printed; a kernel patch-set change needs a factory reset |

## Restoring a configuration backup

Passing a `ruckus_db_*.bak` (with a ZD1200 firmware of the same release) creates
the appliance with a ZD configuration already in place (see
[../README.md](../README.md)). The guest applies it on its
first boot through the vendor restore and reboots once; the run is echoed on the
serial console, which the container captures, and written to
`/writable/zd1200-restore/restore.log` inside the guest. On success the guest
prints `ZD-CONFIG-RESTORED=applied` there, and the container records it in
`/var/lib/zd1200/.backup-seeded` and retires its own copy of the backup:

```sh
docker logs zd1200 | grep -E 'zd1200-restore|ZD-CONFIG-RESTORED'   # Docker
pct exec <id> -- grep zd1200-restore /tmp/zd1200-console.log       # Proxmox
pct exec <id> -- cat /var/lib/zd1200/.backup-seeded                # the seed record
```

| symptom | cause and fix |
|---|---|
| the install fails with `the backup is release X but the firmware is Y` | the backup and firmware releases differ. Only the first three version components need to match (any build); install the firmware release the backup came from |
| the install fails with `not a configuration backup` | the file is not a `PURPOSE=backup` archive (a firmware image, say). Use a `ruckus_db_*.bak` |
| the install says `refusing to rebuild an existing appliance (configuration backup added or changed)` | the appliance was created before the backup was supplied, and rebuilding would discard its current `/writable`. Reset the state (factory reset) and install again, or set `ZD_ALLOW_DISK_REBUILD=1` deliberately |
| the appliance comes up with a factory configuration, not the backup | the guest's vendor check rejected it. The console shows `ZD-CONFIG-RESTORED=failed` (and `verify-backup rejected` or a restore error), and the guest keeps the file as `/writable/zd1200-restore/backup.bak.failed` with the reason in `restore.log`; the usual cause is a release the vendor will not migrate |
| the appliance never reboots and stays factory-default | the hook is a no-op when no backup is staged. Look for `zd1200-restore:` lines in the console; if there are none, the staged file is missing from the built `/writable`, so reinstall with `--backup` |
| I want to apply a different backup | the container seeds a backup only while it builds a fresh `/writable`, and the guest hook consumes what it applied, so a second restore never happens by itself. Reinstall with `--backup` and a factory reset (remove the state), or restore the backup yourself from the running appliance's Web UI |
| the backup seems to have applied twice, or wiped a change | it should not: the container never re-seeds a live `/writable`, the hook renames its staged file to `backup.bak.applied`, and `launch-vm.sh` only retires the container's copy after the guest reports `ZD-CONFIG-RESTORED=applied`. Check `.backup-seeded` for `restored=applied` and the console for two restore runs |
| the AP count is the factory 5, or the licence serial is wrong | a backup archives the live `license-list.xml` only when the source stored it as a file; for a symlinked one the hook falls back to `license-list.bak.xml`. If the source had neither, the appliance keeps its own list. Otherwise check the guest console for `reinstated the backup's AP licence list` and that patch 25's `S49zd_license` ran on the second boot (the first boot reboots before it) |
| the appliance's management address changed after the restore | expected: the restored `system.xml` replaces the current configuration. It sets the appliance's address only if the backup set one; otherwise the appliance takes a DHCP lease |

## Problems reaching the appliance

| symptom | cause and fix |
|---|---|
| web UI unreachable from the **Docker host** | expected: the guest is a macvtap sibling, so the host cannot reach it. Test from another LAN machine |
| web UI unreachable from anywhere | the guest has no lease yet, or the LAN interface cannot pass foreign MACs. Read the lease from your DHCP server; *(Proxmox)* `pct exec <id> -- cat /var/lib/zd1200/guest-ip` has it too |
| *(Docker)* a second ZD1200 container starts and an existing guest goes dark | `network_mode: host` shares the host netns, so both containers used the same `mvt0` and `/tmp` sockets (the second overwrote the first's macvtap MAC). Give each instance its own `ZD_CONTAINER_NAME` in its own checkout; `install-zd1200-docker.sh` writes per-instance `ZD_MACVTAP_IF`, `ZD_CONTROL_SOCK`, `ZD_CONSOLE_SOCK` and `LOG_FILE` into `.env`. Recreate the containers (`compose up -d --force-recreate`) for the new names to take effect |
| *(Proxmox)* `cat: /var/lib/zd1200/guest-ip: No such file` | no lease has been recorded yet: the guest has not taken one, or it cannot be asked over the control channel. `pct exec <id> -- /usr/local/sbin/zd1200-guest-address --ask` queries it directly; the LAN must have a DHCP server |
| web UI redirects to the setup wizard | expected on a fresh volume. Complete the wizard, then reboot the guest |
| `ssh admin@<ip>` refused after the first boot | finish the wizard and reboot once, so the appliance generates its SSH host key |
| `Permission denied (publickey)` on port 2222 | rebuild with `--root-ssh-key` and use that key. On 9.x both `admin` and `root` work |
| *(Proxmox)* guest has no lease or is unreachable | `pct exec <id> -- ip -br a`: `eth0` carries the container's MAC and must have no address; `br-zd` holds the container's own address (while the guest is down) and the guest's tap. The container and guest deliberately share the container's uplink MAC, and the uplink is cross-connected to `br-zd` rather than enslaved so the shared MAC is not shadowed. `pct exec <id> -- bridge link show` (no `eth0`) and `pct exec <id> -- tc filter show dev eth0 ingress` (one `mirred` redirect) show the topology |
| *(Proxmox)* the Summary shows the wrong address, or the container's instead of the guest's | `pct exec <id> -- /usr/local/sbin/zd1200-guest-display --check` prints what is displayed (`--clear` removes it). Proxmox shows the first two addresses in interface order, so if IPv6 came back (`sysctl net.ipv6.conf.all.disable_ipv6` should be 1) its link-local addresses take a slot. Re-run `pct exec <id> -- systemctl restart zd1200-net` |
| *(Proxmox)* the displayed guest address is stale after a lease change | the healthcheck reconciles it every 60s; check one tick with `pct exec <id> -- /usr/local/sbin/zd1200-guest-healthcheck`. If the guest cannot be asked, the old value is left in place rather than replaced by a guess |
| *(Proxmox)* guest is up but the healthcheck says its service is not answering | `pct exec <id> -- /usr/local/sbin/zd1200-guest-address --probe` shows the guest's own answer, and `--diag` adds the raw listening-socket view. The guest checks itself with a local HTTPS request to `127.0.0.1`; a service that accepts the connection but never replies is reported as down after the request times out |
| *(Proxmox)* the container's own address appears in the Summary | expected only with `--keep-ct-address`; by default the container releases its address while the guest runs (see `docs/PROXMOX.md`). If it is showing and you did not ask for it, something ran `zd1200-ct-address up` — `pct exec <id> -- zd1200-ct-address down` hands it back |
| *(Proxmox)* `apt`/`git`/`ssh` fails inside the container while the guest runs | expected: the container gives its address back for as long as the appliance runs. `pct exec <id> -- zd1200-ct-address up` acquires one on demand (a fresh lease); `--keep-ct-address` installs the old always-up behaviour. `pct exec`/`pct enter` work either way |
| *(Proxmox)* the container has no address and the guest is down | it should have reacquired one when QEMU exited. `pct exec <id> -- zd1200-ct-address status`; `... up` retries, and `journalctl -u zd1200 \| grep ct-address` shows what happened. If DHCP never answers, check `br-zd` is still a LAN port (`ip -br a`) |
| *(Proxmox)* the Console tab shows a `... login:` prompt, not the appliance | the console bridge is not on tty1. Check `pct exec <id> -- systemctl status zd1200-console-tty` and `journalctl -u zd1200-console-tty`. `container-getty@1` must be masked and `/tmp/zd1200-console.qemu.sock` must exist (i.e. QEMU is up). A console session opened *before* the bridge started is still attached to what was there; close and reopen the tab, or `pkill -f 'dtach -A /var/run/dtach/vzctlconsole<id>'` on the host |
| *(Proxmox)* the Console tab is blank or shows old output | expected when the tab has been closed: the tty buffer is drained only while a client is attached, and the bridge drops output rather than stall the guest while nobody is. Press Enter and the guest reprints its prompt. The complete record is always `pct exec <id> -- tail -f /tmp/zd1200-console.log` |
| *(Proxmox)* I want the container's own login prompt back | run the installer or bootstrap with `--no-console-tty`; tty1 returns to a getty and QEMU keeps binding the public console socket. `pct enter <id>` also gives a container shell without using a tty |

## Upgrading

`--upgrade` rebuilds the container/CT from the current checkout and re-customises
the roots in place, keeping `/writable` and the provisioned keys. Docker:
`./install-zd1200-docker.sh --upgrade`. Proxmox: `./install-zd1200-lxc.sh
--upgrade` (it finds the container this installer made, or pass `--ctid`).

| symptom | cause and fix |
|---|---|
| the upgrade finishes suspiciously fast | expected if the patch signature is unchanged: the start reads the two sentinels and does nothing. It only re-customises after a patch, feature or environment value changes |
| after an upgrade the guest boots but a change is missing | check `pct exec <id> -- tail -50 /var/lib/zd1200/install.log` (Docker: `docker logs zd1200`). A patch that fails aborts the run rather than half-applying |
| `--upgrade` says the container cannot be found | the container description marker is missing. Pass `--ctid <id>` explicitly |
| root SSH stopped working after an upgrade | it should not: an existing `provision/authorized_keys` is reused. Check `pct exec <id> -- cat /var/lib/zd1200/provision/authorized_keys`; re-run with `--root-ssh-key <file>` to replace it deliberately |

## Clean state

Reset an appliance back to a fresh install, discarding its configuration:

```sh
# Docker: container + state volume (the next install boots a fresh appliance)
docker compose --project-directory . -f docker/docker-compose.yml down -v

# Proxmox: the container's whole state
pct exec <id> -- rm -rf /var/lib/zd1200 && pct reboot <id>
```

## Recovering from the rescue entry

GRUB's menu has four entries: 0 and 1 are the two root images, 2 is the
factory-restore initramfs ("System rescue from image") and 3 the USB restore
tool. The vendor restore tool cannot drive this guest — it expects a TFTP server
and `/dev/hda*` — and it would write vendor images over the patched roots, so a
rescue entry is always a dead end. Two things can select one:

1. **The saved entry.** The vendor failover ladder is current root → spare root
   → rescue, and a guest firmware upgrade can rewrite the menu. Before each QEMU
   launch `prepare-vm-disks.sh` works out which entry GRUB would actually boot
   (the saved default adjusted by the kflag, so a spare-root retry is not
   mistaken for the rescue) and, if it is a rescue entry, logs the condition and
   stops the container instead of starting QEMU.
2. **GRUB's own `fallback 1 2`, inside QEMU.** If both root entries fail to
   *load* — a missing or corrupt `/bzImage`, a damaged root filesystem — GRUB
   falls through them to entry 2 while QEMU is already running. The pre-QEMU
   check only sees the saved entry, so it cannot catch this.

### What you will see

* **Console** (Proxmox **Console** tab; Docker `sudo docker exec -it zd1200
  python3 /opt/zd1200/attach-console.py`; the raw log is `/tmp/zd1200-console.log`
  in either flavour): GRUB prints
  `Booting 'Normal bootup from system image (current)'`, then `Error 25: Disk
  read error`, then the backup entry, then `Booting 'System rescue from image'`
  and `initrd (hd0,0)/restoreinitramfs.gz`. If the rescue image loads it prints
  `System Rescue Tool Started` and starts asking interactive questions
  (`Current server and image info:`, `Use current setting? (y/n)`); if even that
  fails to load, GRUB stops at `Press any key to continue...`.
* **SSH:** nothing answers on 22 or 2222 — the controller never starts.
* **Web UI:** unreachable.
* **Container:** still `active`/`Up` (QEMU is running), not stopped. The
  probe-based guest watchdog may reset the guest after repeated failures, which
  falls back the same way, so the console shows the sequence repeat.

Do not try to repair it from the rescue prompt.

### Recovery

Rebuild the container machinery from a ZD1200 firmware image; the appliance's
configuration lives in `/writable` and is carried over.

Docker:

```sh
docker cp zd1200:/var/lib/zd1200/synthetic-cf.img ./zd1200-disk.img
rm -rf image
docker compose --project-directory . -f docker/docker-compose.yml down -v
./install-zd1200-docker.sh ./zd1200-disk.img <zd1200_*.img> \
    --writable-partition 914872:3006008
```

Proxmox:

```sh
pct pull <id> /var/lib/zd1200/synthetic-cf.img ./zd1200-disk.img
pct exec <id> -- rm -rf /var/lib/zd1200
./install-zd1200-lxc.sh ./zd1200-disk.img <zd1200_*.img> \
    --writable-partition 914872:3006008
```

`914872:3006008` is the ZD1200 `/writable` partition. Removing `image/` (Docker)
is what makes the installer re-run the vendor preparation and pick up the disk;
the Proxmox state reset removes it. To accept a factory reset instead, drop the
disk and reset the state the same way. The same guidance is printed in the
container log when the condition is detected.

## Slow, unhealthy or stuck

| symptom | cause and fix |
|---|---|
| `Up (unhealthy)` for a long time | no usable `/dev/kvm`, so the guest runs under TCG. Enable KVM or wait longer |
| boot is very slow, host fans spin up | as above, or the CPU duty-cycle cap is in effect (`CPU_LIMIT` / `ZD_CPU_GUARD`) |
| the guest stopped answering | it may have wedged (QEMU alive, guest silent). On Proxmox: `pct exec <id> -- /usr/local/sbin/zd1200-guest-healthcheck`; the watchdog reboots it after repeated failures (see `docs/PROXMOX.md`) |
| the guest only ever has one CPU | ACPI must be on (`-machine pc`) for the second vCPU to be enumerated; `ZD_MACHINE=pc,acpi=off` (or `ZD_SMP=1`) forces the single-CPU model. With one CPU the vendor watchdog's tick collapses and every boot looks like a fault |
| the guest boots the backup image after a reboot | the kernel watchdog timed out (the `'9'` kflag) and the in-box IPMI BMC reset the guest, so GRUB advanced to the spare and that boot's `flag_reset` cloned the spare back over the primary. A healthy guest with two vCPUs leaves the kflag at `'8'` |
| the container logs `the saved GRUB entry is a rescue entry` and stops | the failover ladder reached the vendor rescue image. Rebuild from a firmware image keeping `/writable`: see [Recovering from the rescue entry](#recovering-from-the-rescue-entry) |
| the container is `Up` but the appliance is unreachable, and the console shows `Error 25: Disk read error` / `Booting 'System rescue from image'` | both root entries failed to load and GRUB's `fallback 1 2` reached the rescue inside QEMU (the pre-QEMU guard cannot see this). Rebuild from firmware keeping `/writable`: see [Recovering from the rescue entry](#recovering-from-the-rescue-entry) |
| container stops taking a long time | expected: the guest is asked to flush `/writable` before QEMU is torn down. Do not lower the grace period |

## APs and firmware

| symptom | cause and fix |
|---|---|
| APs will not join after the mesh repair | they must already run **Solo 104 or 106** firmware — the repair delivers an unsigned AP image that older firmware rejects. Upgrade the APs through their own standalone upgrade page, or build with `--no-r600-repair` |
| an AP still runs fully signed FSI firmware | it must first be moved to a compatible ISI release through its own standalone upgrade page |
| R600 mesh APs pass no Layer-2 traffic | the AP image has the 10.5.1.0.276+ receive-path bug; rebuild **without** `--no-r600-repair` so the image is repaired (see `packages/mesh-patch/README.md`) |
| the web UI offers an upgrade but the guest never applies it | check the console log; a guest firmware upgrade writes the new rootfs to the spare partition and is customised on the next container start. If it stops at `E_FailUpgradeNTP`, the entitlement NTP marker `/tmp/ntp_result` is missing (`S48zd_ntp_result`, patch 20, seeds it at boot) |
