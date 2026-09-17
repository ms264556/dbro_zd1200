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
