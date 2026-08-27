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
the data partition is real ReiserFS (so the stock `sys_init` mount works), and
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
  (`qemu-system-i386`, `qemu-img`) and reiserfsprogs (`mkreiserfs`); KVM is
  optional.
- A dedicated Layer-2 path for the guest if it will manage real APs. The host
  must not have an IP address on that adapter, bridge, or TAP interface.
- Host tools for preparation: Bash, Python 3, `tar`, `gzip`, `cpio`,
  `openssl`, GNU binutils (`as`, `ld`), `md5sum`, and `sha256sum`.

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
  the CompactFlash at boot, exactly like a physical ZD1200. Change it with
  `ZD_SERIAL` / `ZD_MAC1`. Do not run two instances on the same Layer-2
  network with the same MAC.
- The generated state volume contains controller configuration and AP state.
  Back it up before experiments; deleting it returns the VM to factory setup.

## Security warning

This is a lab proof of concept, not a hardened appliance. Do not expose the
VM's HTTPS, SSH, FTP, management network, or host Docker API to untrusted
networks. Use a dedicated management VLAN and firewall rules.

## Repository contents

The source-only public repository should contain these files:

```text
Dockerfile                    docker-compose.yml             .env.example
make-synthetic-cf.py          patch-kernel.py                write-boarddata.py
run-zd1200-qemu.sh            run-zd1200-lab.sh              run-zd1200-web.sh
prepare-vendor-image.sh       limit-process-cpu.py
host/zd1200-bridge            host/zd1200-bridge.service     host/zd1200-bridge.env.example
README.md                     LICENSE                         .gitignore                     .dockerignore
ZD1200-LAB-GUIDE.md
```

Historical artifacts no longer used by the boot (kept for reference):
`boot-initrd-handoff`, `boot-initrd-init`, `boot-initrd-inittab`,
`make-boot-initrd.sh`, `make-runtime-initrd.sh`, `pivot-exec.S`,
`zd-controller-wrapper.sh`, `zd-memory-snapshot.sh`, `zd1200-patch.gdb`,
`zd-dropbear2222/`.  `limit-process-cpu.py` is retained for the automatic TCG
fallback only.

## Known limitation

Do not use the ZoneDirector web-upgrade workflow inside this VM. QEMU boots an
external kernel, so an in-guest upgrade would create a mixed version unless
this port is updated and rebuilt for that release.


