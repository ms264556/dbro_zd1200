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
| *(Proxmox)* `Unsupported NIC model: igb` | the container's QEMU is too old for the guest's NIC. Use a Debian 13 template; the installer checks this before provisioning |
| *(Proxmox)* installer refuses the template | it is not Debian 13. The installer fetches Debian 13 when none is present |
| *(Proxmox)* `could not install QEMU in container <id>` | the container has no working outbound network for apt |
| `refusing to rebuild an existing appliance` (the base firmware changed) | `image/` no longer matches what the disk was built from, and rebuilding would discard `/writable`. Put the old `image/` back, or upgrade with `--upgrade` (which never re-prepares `image/`), or accept a factory reset (see [Clean state](../README.md#clean-state)) / set `ZD_ALLOW_DISK_REBUILD=1` |
| `was customised by an older version ... no /.patchrollback store` | the rootfs was patched before the rollback store existed, so it cannot be re-patched safely. Reset the state and install again from firmware |
| `the kernel patcher failed for hda2/hda3` | the kernel no longer matches `patch-kernel.py` (unexpected firmware, or a kernel patch set that changed after the root was built). The tail of the log is printed; a kernel patch-set change needs a factory reset |

## Problems reaching the appliance

| symptom | cause and fix |
|---|---|
| web UI unreachable from the **Docker host** | expected: the guest is a macvtap sibling, so the host cannot reach it. Test from another LAN machine |
| web UI unreachable from anywhere | the guest has no lease yet (`cat /var/lib/zd1200/guest-ip`), or the LAN interface cannot pass foreign MACs |
| `cat: /var/lib/zd1200/guest-ip: No such file` | no DHCP lease observed yet. Watch the console log for `guest leased IP`; the LAN must have a DHCP server |
| web UI redirects to the setup wizard | expected on a fresh volume. Complete the wizard, then reboot the guest |
| `ssh admin@<ip>` refused after the first boot | finish the wizard and reboot once, so the appliance generates its SSH host key |
| `Permission denied (publickey)` on port 2222 | rebuild with `--root-ssh-key` and use that key. On 9.x both `admin` and `root` work |
| *(Proxmox)* guest has no lease or is unreachable | `pct exec <id> -- ip -br a`: `br-zd` should hold the container's address and `eth0` should be a port carrying none. The container and guest must not share a MAC (the installer enforces this) |
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

## Slow, unhealthy or stuck

| symptom | cause and fix |
|---|---|
| `Up (unhealthy)` for a long time | no usable `/dev/kvm`, so the guest runs under TCG. Enable KVM or wait longer |
| boot is very slow, host fans spin up | as above, or the CPU duty-cycle cap is in effect (`CPU_LIMIT` / `ZD_CPU_GUARD`) |
| the guest stopped answering | it may have wedged (QEMU alive, guest silent). On Proxmox: `pct exec <id> -- /usr/local/sbin/zd1200-guest-healthcheck`; the watchdog reboots it after repeated failures (see `docs/PROXMOX.md`) |
| container stops taking a long time | expected: the guest is asked to flush `/writable` before QEMU is torn down. Do not lower the grace period |

## APs and firmware

| symptom | cause and fix |
|---|---|
| APs will not join after the mesh repair | they must already run **Solo 104 or 106** firmware — the repair delivers an unsigned AP image that older firmware rejects. Upgrade the APs through their own standalone upgrade page, or build with `--no-r600-repair` |
| an AP still runs fully signed FSI firmware | it must first be moved to a compatible ISI release through its own standalone upgrade page |
| R600 mesh APs pass no Layer-2 traffic | the AP image has the 10.5.1.0.276+ receive-path bug; rebuild **without** `--no-r600-repair` so the image is repaired (see `bl7/README.md`) |
| the web UI offers an upgrade but the guest never applies it | check the console log; a guest firmware upgrade writes the new rootfs to the spare partition and is customised on the next container start |
