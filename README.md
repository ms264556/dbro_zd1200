# Virtual ZoneDirector 1200 — 10.5.1.0.282 proof of concept

This project boots the x86 ZoneDirector 1200 software in QEMU/KVM and exposes
it through the web UI (and the stock administrative SSH once configured). It
is an experimental, unsupported lab port; it is not affiliated with or
endorsed by Ruckus.

The guest runs the **stock vendor userspace with no initramfs and no boot
handoff**: QEMU loads the patched kernel, the kernel mounts `root=/dev/hda2`
from the synthetic CompactFlash directly, and the vendor userspace boots
unmodified — exactly like the physical appliance. The kernel is patched only
where QEMU hardware differs (watchdog, power controller, board-data retry),
the data partition is plain ext2 (the rootfs patch drops the ReiserFS-only
`nolog` mount option, so the stock `sys_init` mount works), and
the serial number / MACs come from the board-data records on the CF image,
just like a real ZD1200. A root shell on the guest sees a real appliance.

## Firmware and licensing boundary

This repository intentionally contains **no Ruckus binaries, firmware, root
filesystems, keys, or AP images**. Obtain the matching ZD1200 10.5.1.0.282
package yourself from [Ruckus Support](https://support.ruckuswireless.com/software/4537-zd1200-10-5-1-ga-refresh-9-software-release), and ensure that your download, decryption and use comply with the applicable terms.

The included [MIT License](LICENSE) applies only to this repository's original
glue code and documentation. It grants no rights to Ruckus materials.

`prepare-vendor-image.sh` accepts a user-supplied *decrypted* archive and
creates the ignored `image/` directory locally. An online decryption tool
is [here](https://ms264556.net/ruckus/DecryptRuckusBackups). It expects
this exact archive SHA-256:

```
64dfbf4d67cc65cafa0e258e426c664c7387b1219209ec893b9b1e41ab202cb8
```

The script verifies the archive identity, vendor metadata and vendor kernel/
rootfs MD5 values before extracting `bzImage`, `vmlinux`, `rootfs.ext2`, the
base initramfs, and the complete AP/aidfs payload. Generated output is ignored
by Git and must never be committed.

## Prerequisites

- x86_64 (or aarch64 — see ZD1200-LAB-GUIDE.md) Linux host with QEMU
  (`qemu-system-i386`, `qemu-img`) and e2fsprogs (`mke2fs`); KVM is
  optional.
- For the host-TAP path (`host/zd1200-bridge`): a dedicated Layer-2 interface
  for the guest if it will manage real APs; the host must not have an IP
  address on that adapter, bridge, or TAP interface.  (The macvlan path uses
  the host's normal LAN interface instead.)
- Host tools for preparation: Bash, Python 3, `tar`, `gzip`, `md5sum`, and
  `sha256sum`.

## Build the local image

```sh
cp .env.example .env
./prepare-vendor-image.sh /absolute/path/to/zd1200_10.5.1.0.282.ap_10.5.1.0.282.img.tgz
docker compose up -d --build
```

`ZD_IMAGE_DIR` in `.env` defaults to `./image`. Set it to an external absolute
path if the large, generated files should live elsewhere. `.env`, `image/`, VM
disks, logs and state are excluded by `.gitignore`.

For a physical Ethernet attachment, configure the dedicated adapter in
`host/zd1200-bridge.env.example`, then install the files as follows:

```sh
sudo install -m 0755 host/zd1200-bridge /usr/local/sbin/zd1200-bridge
sudo install -m 0644 host/zd1200-bridge.service /etc/systemd/system/
sudo install -m 0600 host/zd1200-bridge.env.example /etc/default/zd1200-bridge
sudoedit /etc/default/zd1200-bridge
sudo systemctl daemon-reload
sudo systemctl enable --now zd1200-bridge.service
```

The bridge service refuses to repurpose an interface carrying the host default
route. Set `ZD_USB_MAC` in its configuration to the dedicated adapter's MAC as
an additional guard.

Alternatively, the container itself can run on a **macvlan** network: it gets
its own MAC and a DHCP-allocated IP on the LAN (so mDNS works), and the QEMU
guest shares that LAN segment through a macvtap, exactly like a real appliance
plugged into the network. No host-side bridge or systemd service is needed:

```sh
cp .env.example .env       # set ZD_MACVLAN_PARENT to the host's LAN interface
docker compose up -d --build
```

The parent interface must be on the LAN the appliance should join: a real NIC,
or a vSwitch/bridge port with MAC spoofing enabled (macvlan uses MACs other
than the host's; Hyper-V vSwitch ports need "Enable MAC address spoofing").
The DHCP server on that LAN hands the container its IP (the entrypoint runs
`udhcpc`), and the guest gets its own lease through the macvtap.  (Docker also
pools a vestigial subnet on the macvlan network; udhcpc's deconfig flushes
that address when the lease arrives, so the DHCP address is the container's
real LAN identity.)

With macvlan the appliance identity is derived from the container's allocated
MAC: `boarddata-from-mac.sh` hashes the eth0 MAC into the serial number
("5" + 11 digits) and feeds MAC + serial into the board data
(`write-boarddata.py`), so every instance is unique on the LAN. Set
`ZD_BOARDDATA_FROM_MAC=0` to fall back to the fixed `ZD_SERIAL`/`ZD_MAC1`
values.

**Running under WSL2:** the WSL2 vSwitch drops frames from foreign MACs and
has no MAC-spoofing toggle (microsoft/WSL#7192, #11616), so a macvlan
container gets no DHCP lease — verified in both the default NAT mode and
with `networkingMode=mirrored` in `%USERPROFILE%\.wslconfig` (the gateway
never answers ARP from the macvlan interface).  macvlan therefore needs a
real VM or host whose vSwitch/NIC passes foreign MACs.  Under WSL2 (or on
any host without `/dev/kvm`), merge the `docker-compose.user.yml` override
(user-mode networking, no device passthrough) instead of using the base
file alone:

```sh
docker compose -f docker-compose.yml -f docker-compose.user.yml up -d
```

After the first factory-wizard completion, restart the container once. That
allows the configured system to generate its persistent Dropbear host key and
start the stock administrative SSH (port 22), exactly like a real appliance.

## Runtime notes

- Keep `KERNEL_EXTRA: nohz=off`. The 2.6.32 guest's tickless-idle path spins a
  host CPU while idle; this option reduced observed KVM QEMU CPU use from about
  25% to about 2% of one host CPU.
- `CPU_LIMIT` is intentionally absent for KVM. The old duty-cycle limiter only
  added SIGSTOP/SIGCONT pauses and delayed useful work. `nice -n 10` remains
  and only lowers scheduling priority under contention.
- The board data (serial + unicast MAC, MAC2 = MAC1 + 1) is written into the
  CF image by `write-boarddata.py`; the kernel's v54bsp driver reads it from
  the CompactFlash at boot, exactly like a physical ZD1200. In macvlan mode
  the values are derived from the container's eth0 MAC
  (`boarddata-from-mac.sh`), so every instance is unique; otherwise change
  them with `ZD_SERIAL` / `ZD_MAC1`. Do not run two instances on the same
  Layer-2 network with the same MAC.
- The generated state volume contains controller configuration and AP state.
  Back it up before experiments; deleting it returns the VM to factory setup.

## Security warning

This is a lab proof of concept, not a hardened appliance. Do not expose the
VM's HTTPS, SSH, FTP, management network, or host Docker API to untrusted
networks. Use a dedicated management VLAN and firewall rules.

## Repository contents

The source-only public repository should contain these files:

```text
Dockerfile                    docker-compose.yml             docker-compose.user.yml
.env.example                  make-synthetic-cf.py           patch-kernel.py
patch-rootfs.sh               write-boarddata.py             run-zd1200-qemu.sh
run-zd1200-lab.sh             run-zd1200-web.sh              boarddata-from-mac.sh
limit-process-cpu.py          prepare-vendor-image.sh
host/zd1200-bridge            host/zd1200-bridge.service     host/zd1200-bridge.env.example
README.md                     WRITABLE_PARTITION.md          ZD1200-LAB-GUIDE.md
LICENSE                       .gitignore                     .dockerignore
```

`limit-process-cpu.py` is retained for the automatic TCG fallback only.

## Known limitation

Do not use the ZoneDirector web-upgrade workflow inside this VM. QEMU boots an
external kernel, so an in-guest upgrade would create a mixed version unless
this port is updated and rebuilt for that release.


