# ZD1200 Container Launch RUNBOOK

Purpose: stand up the virtual Ruckus ZoneDirector 1200 (10.5.1.0.282) in a
**host-netns** Docker container that shares the host's network namespace, and run
the QEMU guest with a **macvtap on the host's physical LAN interface** so the
appliance is a real device on the LAN (own DHCP lease, mDNS, web/SSH).  This is
the one authoritative recipe: read it top to bottom before running anything.

> This replaces the earlier **macvlan** approach.  On a macvlan container the
> container's `eth0` is itself a macvlan, and an macvtap layered on it is a
> *nested* macvlan that does **not** forward frames to the physical parent — the
> guest could never reach the LAN (see §7b).  Host-netns puts the macvtap on the
> real interface and fixes that.

---

## 0. Current status (read first)

**Verified working (2026-08-29).**  On a Linux host the container starts, the
guest boots to READY, gets its **own DHCP lease on the LAN**, the web stack
(`Emfd`), `sshd` and `mDNSResponder` come up, and the **"No Support Upgrade
Entitlement" banner is gone** (the signing bypass + a valid serial are baked).
Container reports `Up (healthy)`.

Two things had to be right (both fixed in the repo):

1. **Host-netns networking** — the guest's macvtap must be on the host's physical
   interface, or the guest never gets onto the LAN (§7b).
2. **A valid serial** — the **MAC-derived** serial (from `boarddata-from-mac.sh`)
   is rejected by the firmware's support-entitlement check
   (`E_InvalidSerialNumber` = "serial number mismatch"), which leaves the banner
   up even though the signing bypass works.  Set `ZD_BOARDDATA_FROM_MAC=0` to use
   the known-valid default serial (§7d).

---

## 1. Prerequisites (host)

```sh
# Docker engine + compose v2 (compose v2 REQUIRED; base docker.io lacks `docker compose`).
sudo apt-get install -y docker.io docker-compose-v2
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"         # NEXT login; until then use `sudo docker …`

# Host tooling for prepare-vendor-image.sh and the standalone lab:
sudo apt-get install -y qemu-utils e2fsprogs gzip python3 curl
```

Host requirements:

- Linux x86_64 (or aarch64) with a LAN NIC that carries the target subnet (e.g.
  `eth0`) **and passes foreign MACs** (MAC-spoofing enabled).  WSL2 does **not**
  pass foreign MACs — see §7b and the `docker-compose.user.yml` user-mode fallback.
- `/dev/kvm` optional (KVM accelerates; falls back to TCG).
- The **signing cert payload** (a directory containing `signing_cert.pem`,
  `digital_sig_sha256.bin`, `digital_sig_sha384.bin`, `all_checksums.txt`) from
  the `create_zd1200_signing_bypass` tool (§4).

---

## 2. Required inputs

- The **decrypted** Ruckus archive for the ZD1200 platform (e.g.
  `zd1200_10.5.1.0.282.ap_10.5.1.0.282.img.tgz`).  The firmware version is not
  pinned; optionally set `EXPECTED_ARCHIVE_SHA256` to require a specific hash
  (the 10.5.1.0.282 archive is
  `64dfbf4d67cc65cafa0e258e426c664c7387b1219209ec893b9b1e41ab202cb8`).
- The signing-cert payload directory (`ZD_SIGN_CERT_HOST`, §4).
- The container image builder needs only the repo's scripts + the above.

---

## 3. Prepare the vendor image (once)

```sh
./prepare-vendor-image.sh /abs/path/to/zd1200_10.5.1.0.282.ap_10.5.1.0.282.img.tgz
```

Produces `image/bzImage`, `image/vmlinux`, `image/rootfs.ext2` (decompressed to
RAW ext2), `image/restoreinitramfs.gz`, `image/zd1051-payload.tar.gz`.
`image/` is gitignored and must never be committed.

---

## 4. Configure and launch (host-netns)

```sh
cp .env.example .env
#   ZD_GUEST_IP=192.168.50.10     # guest's mgmt IP (it leases from DHCP; the
#                                 # readiness is console-based, so the exact IP
#                                 # only affects the printed URL)
#   ZD_SIGN_CERT_HOST=/home/<you>/dev/ms264556.net/scripts/create_zd1200_signing_bypass/cert
vim .env

docker compose up -d --build
```

Notes:

- **`network_mode: host`.**  The container shares the host netns.  The entrypoint
  creates `mvt0` (macvtap, bridge mode) on the host's **physical** `eth0` and sets
  its MAC to the guest MAC (`ip link set mvt0 address $ZD_MAC1`), then QEMU
  attaches the guest NIC to it.  Because it is a top-level macvtap on a real NIC,
  the guest forwards to the LAN and leases its own IP.
- **`ZD_HOST_NET=1`.**  In host-netns the container's `eth0` **is the host's**
  (already has the host IP), so the entrypoint does **not** run `udhcpc` on it —
  otherwise it would try to re-lease and disturb the host's connectivity.
- **Board data / serial.**  `ZD_BOARDDATA_FROM_MAC=0` uses the fixed
  `ZD_SERIAL=123456000789` and `ZD_MAC1=00:0c:e6:12:00:01` (a Ruckus-OUI MAC).
  A MAC-derived serial is rejected by the firmware (§7d).  Only one instance may
  run per L2 (fixed MAC); otherwise keep `ZD_BOARDDATA_FROM_MAC=1` and set a
  serial that passes the check.
- **Signing bypass / license.**  On first boot `run-zd1200-web.sh` runs
  `patch-rootfs.sh` (strips the ReiserFS-only `nolog` mount option) then
  `patch-rootfs-signing.sh` (patches `/bin/sys_wrapper.sh` check/entitlement,
  writes `/etc/persistent-scripts/patch-storage/`, refreshes `/file_list.txt`).
  **`patch-rootfs-signing.sh` takes its cert dir as `$1` (positional), not an env
  var**; the entrypoint passes `${ZD_SIGN_CERT_DIR}` (default
  `/opt/zd1200/signing-cert`, bind-mounted from `${ZD_SIGN_CERT_HOST}`).
- **Capabilities.**  `CAP_MKNOD` (mknod the tap char node), `CAP_NET_RAW`
  (AF_PACKET for `sniff-guest-dhcp.py`), `NET_ADMIN` (create/bring up the
  macvtap).  `cap_drop: ALL`, `device_cgroup_rules: c *:* rwm`,
  `no-new-privileges: true`.

---

## 5. Watch it boot

The guest boots under KVM/TCG inside the container.  `run-zd1200-web.sh` waits for
readiness and prints the URL.  In `macvtap` mode readiness is detected from the
guest's **serial console** (`System go into READY status.`); in `user`/`tap` mode
it polls the login page.  Default `WEB_WAIT_SECONDS` = 600s.

```sh
docker logs -f zd1200
# Guest serial console (separate from docker logs):
docker exec zd1200 tail -f /tmp/zd1200-web.log
```

`sniff-guest-dhcp.py` watches the LAN (AF_PACKET on `eth0`) for the DHCP reply to
the guest MAC and writes the guest's lease to `/var/lib/zd1200/guest-ip`; the
readiness message prints it once observed.  `docker logs zd1200 | grep "guest leased IP"`
or `docker exec zd1200 cat /var/lib/zd1200/guest-ip`.

The guest console shows the Ruckus board-data block (serial + MAC1/MAC2), then
`System go into READY status.`  First boot completes the factory setup wizard via
the web UI.

---

## 6. Verify

The guest is a normal device on the LAN (it gets its own lease).  The docker
host's netns is shared with the container, but the guest is a sibling macvtap, so
confirm endpoints from a **separate LAN host** on the same subnet:

```sh
curl -kIs https://<guest-ip>/admin10/login.jsp
ssh admin@<guest-ip>          # after the wizard + one restart (Dropbear :22)
```

Find the guest IP from `docker exec zd1200 cat /var/lib/zd1200/guest-ip`, or
`arp-scan --localnet` for the guest MAC (`00:0c:e6:12:00:01` when
`ZD_BOARDDATA_FROM_MAC=0`).

After completing the wizard, restart once so the configured system generates its
persistent Dropbear host key and starts admin SSH.

---

## 7. Known failure / gotchas

### 7a. Container crash-looped waiting for the guest's IP — FIXED

The readiness probe + healthcheck used to `curl` a static `ZD_GUEST_IP`, which
the container can never reach (in macvtap mode the container is isolated from its
guest).  Now readiness is detected from the guest's serial console
(`System go into READY status.`) in `run-zd1200-web.sh` and the
compose/Dockerfile `healthcheck`.

### 7b. The guest never got onto the LAN — FIXED (host-netns)

Layering a macvtap/macvlan on the **container's** macvlan `eth0` is a *nested*
macvlan that does not forward to the physical parent, so the guest's frames never
left the container and it never leased.  Diagnostics: a host capture
(`tcpdump -i eth0 'ether src <guest-mac>'`) showed zero frames.  **Fix:**
`network_mode: host` so the macvtap is created on the host's physical interface
(a top-level macvtap forwards normally).  Also set the macvtap MAC to the guest
MAC (`ip link set mvt0 address $ZD_MAC1`) so the LAN's replies reach the guest.

### 7c. The support banner persists because the serial is invalid — FIXED

The signing bypass (`patch-rootfs-signing.sh`) *works* — the patched
`sys_wrapper.sh` methods write `/writable/etc/airespider/support-list.xml` with
`status="1"`.  But if that record carries a **MAC-derived** serial
(`boarddata-from-mac.sh`) it is rejected by the firmware's support-entitlement
check — `msg="E_InvalidSerialNumber"` ("serial number mismatch on the Support
Entitlement file", from the firmware's own strings) — so the banner stays.
**Fix:** `ZD_BOARDDATA_FROM_MAC=0` bakes the known-valid default serial
(`123456000789` / MAC `00:0c:e6:12:00:01`).

### 7d. Instrumentation

`sniff-guest-dhcp.py` prints the guest's dynamic lease to the container log and
`/var/lib/zd1200/guest-ip` (the container can't see its guest by IP, so it watches
the DHCP exchange on the wire).  `patch-rootfs-signing.sh` takes `CERT_DIR` as a
**positional** `$1`, not an env var; the entrypoint passes
`${ZD_SIGN_CERT_DIR:-/opt/zd1200/signing-cert}`.

---

## 8. Reset / factory

```sh
docker compose down -v       # removes container AND the state volume
                             # -> next `up` is a factory wizard again.
```
