# ZD1200 dropbear + container handoff

Purpose: a ZD1200 controller guest (run inside the **Docker container**) with an
**additional dropbear on port 2222** that drops to an **ash shell** for
`authorized_keys` users (static musl dropbear + sftp-server). The container
approach is the primary/authoritative path — see RUNBOOK.md and README.md.

> **Current state:** the port-2222 dropbear is **optional** and is **not**
> injected in the default setup — `inject-dropbear.sh` must be run on the host
> before the image is prepared for the 2222 instance to exist. Without it the
> stock controller boots normally, and after the first-run wizard + a reboot the
> stock admin SSH (port 22) comes up.  (The in-guest reboot that follows the
> wizard now completes in place — `-no-reboot` is no longer used.)

---

## 0. Build the container (the obvious entry point)

```sh
# one command; prepares image/ (once), creates .env, then builds + starts:
sudo ./build-container.sh /abs/path/to/zd1200_*.img.tgz
```

`build-container.sh` wraps the documented `docker compose up -d --build` (host
network namespace, macvtap on the host's physical NIC). Use `--no-up` to only
build the image without booting the guest. If the decrypted archive is already
prepared (`image/rootfs.ext2` exists) the archive argument may be omitted.

Container image: `local/zd1200-qemu:10.5.1.0.282`; container name `zd1200`.

---

## 1. Dropbear port 2222 (optional, host-side prep)

The host prepares the vendor rootfs seed `image/rootfs.ext2` before the container
builds the synthetic disk from it (the container mounts `image/` read-only), so
**inject dropbear on the host**:

```sh
# rebuild the static dropbear (once):
cd ~/zd1200_dropbear && ./build-zd1200-dropbear.sh \
    --work "$PWD/work" --out "$PWD/out"     # -> out/dropbear, sftp-server, dropbearkey, dropbearconvert

# then stage the binaries into THIS repo and inject into the rootfs seed:
cd ~/dbro_zd1200
cp ~/zd1200_dropbear/out/* dropbear-provision/bin/   # repo-local binaries (Gitignored)
./prepare-vendor-image.sh /abs/path/to/zd1200_*.img.tgz   # if image/ not yet prepared
./inject-dropbear.sh        # bakes dropbear into image/rootfs.ext2 (reads dropbear-provision/bin)
```

`inject-dropbear.sh` configures an additional dropbear instance on port 2222
with an ash shell, public-key only, using the standard dropbear/OpenSSH file
locations. See §4 for what it lays down. If you do not run it, the container
still builds and boots the stock controller (no port 2222).

---

## 2. Reach dropbear on 2222

- **host-netns / macvlan (default):** the guest is a real LAN device with its
  own lease; the dropbear port 2222 is directly on the guest IP. Find the guest
  IP from `sudo docker exec zd1200 cat /var/lib/zd1200/guest-ip`. Then
  `ssh -i dropbear-provision/id_ed25519 -p 2222 root@<guest-ip>`.
- **user-mode / lab override (`docker-compose.user.yml`):** the guest lives behind
  QEMU user-net NAT; pass `EXTRA_HOSTFWD` to forward host ports, e.g.
  `EXTRA_HOSTFWD="tcp:127.0.0.1:2222-:2222"` in the container env, then
  `ssh -i dropbear-provision/id_ed25519 -p 2222 root@127.0.0.1`.

Client flags needed because the host ssh config has a bad-perms file:
`-F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`.

---

## 3. What the stock controller does vs. our 2222 instance

- The stock administrative SSH (port 22) only comes up **after** the first-run
  wizard completes and the controller is rebooted once (it generates its own
  `/etc/airespider/dropbear` host key). Port 2222 is up on every boot because
  the extra dropbear is baked into the rootfs.

---

## 4. What inject-dropbear.sh lays into the rootfs

- `/usr/sbin/dropbear`, `/usr/sbin/sftp-server` — the static musl binaries
  (the vendor `/usr/sbin/dropbear` is replaced).
- `/usr/bin/dropbearkey`, `/usr/bin/dropbearconvert` — replaced with the real
  static executables. The vendor shipped these as applet symlinks →
  `../sbin/dropbear`; our static dropbear does **not** dispatch by argv[0], so
  the links would otherwise point at an sshd.
- `/root/.ssh/authorized_keys` — the allowed key (standard per-user location).
- `/etc/dropbear/dropbear_ed25519_host_key` — host key for the 2222 instance.
- `/etc/dropbear/ptmx.tar` — baked char-device (5,2) restored by the init at
  boot, because the vendor `/dev` has no `/dev/ptmx` and no `mknod` binary.
- `/etc/init.d/dropbear2222` + `S61dropbear2222` runlevel link — the 2222 daemon.

Deliberately **untouched** (so the vendor layout stays):
- `/etc/passwd` stays the vendor symlink → `/writable/etc/config/passwd`;
- `/etc/shadow` stays the vendor regular file;
- `/etc/dropbear` keeps the vendor FIPS keys.

`make-synthetic-cf.py` optionally seeds the `/writable` data partition (hda4)
with `dropbear-provision/passwd` + `shadow` so `getpwnam("root")` resolves on the very
first boot (the `/etc/passwd` symlink target doesn't exist until the controller
generates it). This is non-fatal: if the seed files aren't present it skips, and
a factory-virgin `/writable` is the vendor default.

---

## 5. Files

```
~/dbro_zd1200/
  build-container.sh          # the docker build/start entry point
  inject-dropbear.sh          # optional dropbear injection (host-side prep)
  make-synthetic-cf.py        # builds the synthetic CF; seeds /writable (optional)
  image/rootfs.ext2           # vendor seed (gitignored); injected if you ran §1
  dropbear-provision/              # provisioning keypair + 2222 init + passwd/shadow (gitignored)
  dropbear-provision/bin/          # repo-local static dropbear binaries (Gitignored; built by ~/zd1200_dropbear, copied in §1)
```
