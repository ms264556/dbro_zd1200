# Ruckus ZoneDirector ZD1200 in Docker

Run the Ruckus ZoneDirector 1200 (ZD1200) controller firmware as a virtual
appliance in a Docker container. QEMU runs the stock ZD1200 kernel and rootfs,
and the guest joins your LAN as a normal device — its own MAC, DHCP lease, mDNS,
web UI and SSH. Access points connect to it directly.

You supply the firmware or a card dump; nothing vendor-owned is committed or
redistributed.

---

## What you need

- **Linux** with Docker Engine and **Compose v2** (`docker compose`).
- A **LAN interface that can pass foreign MAC addresses** (MAC spoofing, or a
  bridge port that does not filter MACs). The guest is a macvtap on the host NIC
  and must be a real L2 device on the LAN. There is no NAT/user-mode fallback;
  WSL2 is not supported.
- `/dev/kvm` — optional. With it the guest boots in ~1–2 minutes; without it QEMU
  uses TCG and takes several minutes.
- Host tools for the prepare step: `bash`, `tar`, `gzip`, `python3`, `md5sum`,
  `sha256sum`, and (`debugfs`/`e2fsprogs`, only for card dumps). **No compiler** —
  guest helpers are built inside Docker.
- One of the inputs below.

## Inputs

You can build from any of:

1. **A ZD1200 firmware upgrade file** downloaded from Ruckus/CommScope support,
   e.g. `zd1200_10.5.1.0.282.ap_10.5.1.0.282.img`. The download is TAC-encrypted
   and is decrypted while preparing the image.
2. **A CompactFlash card dump** from a real appliance: a raw `dd` `.img`, a
   Windows ImageUSB `.bin` (its 512-byte header is handled automatically), or a
   `.7z` containing either.
3. **Both** — a firmware file for the kernel/rootfs, plus `--writable-from` to
   take `/writable` (the appliance's configuration and AP payloads) and the board
   serial from a card dump. This revives, for example, a ZD1100 or ZD3000 card on
   a same-version ZD1200 container.

The prepared artifacts land in `image/` (gitignored) and are reused on later runs.

## Build and launch

```sh
# 1. from a firmware upgrade file
./build-container.sh /path/to/zd1200_10.5.1.0.282.ap_10.5.1.0.282.img

# 2. from a CompactFlash card dump (dd .img, ImageUSB .bin, or .7z)
./build-container.sh /path/to/zd1200_10.5.1.0.240_cfcard_dump.7z

# 3. firmware kernel/rootfs + a foreign card's /writable and serial
./build-container.sh /path/to/zd1200_9.10.2.0.130.ap_9.10.2.0.130.img \
    --writable-from /path/to/zd1112_9.10.2.0.84.bin

# optional: public-key root SSH on TCP 2222 (makes the first build slow)
./build-container.sh --root-ssh-key ~/.ssh/id_ed25519.pub /path/to/zd1200_*.img
```

The first run prepares `image/`, creates `.env`, builds the container image and
starts it. Later runs can omit the input: `./build-container.sh`.

| flag | effect |
|---|---|
| `--root-ssh-key <key\|file>` | enable the static-dropbear replacement and public-key root SSH on 2222 |
| `--writable-from <dump>` | take `/writable` + serial from a CF dump, kernel/rootfs from the firmware file |
| `--writable-partition START:COUNT` | override the auto-detected `/writable` partition |
| `--no-up` | build the image without booting it |
| `--help` | usage |

## Watch it boot

```sh
docker logs -f zd1200
docker exec zd1200 tail -f /tmp/zd1200-console.log   # guest serial console
```

The container reports `Up (healthy)` once the guest prints
`System go into READY status.` (a minute or two under KVM).

## Reach the appliance

The guest takes a DHCP lease from your LAN:

```sh
docker exec zd1200 cat /var/lib/zd1200/guest-ip
```

Open `https://<guest-ip>/` from a machine on the same LAN. The first boot runs the
factory setup wizard; after completing it, reboot once so the appliance generates
its SSH host key, then `ssh admin@<guest-ip>`.

**The Docker host cannot reach its own guest.** The guest is a macvtap sibling of
the host NIC, and macvlan does not loop frames back, so test from another LAN
machine (`curl -kI https://<guest-ip>/admin10/login.jsp`). This is expected, not
a routing bug.

Serial console (the same prompt you would get on the physical box):

```sh
docker exec -it zd1200 python3 /opt/zd1200/attach-console.py
# Ctrl-C (sometimes twice) detaches; the guest keeps running
```

Log in with the appliance's `admin` credentials. At the ZD CLI, `!v54! <word>`
drops to a root shell — the rootfs patch replaces the passphrase helper with an
exit-0 stub, so any word works.

## Optional features

- **Root SSH on TCP 2222** (`--root-ssh-key`): `ssh -p 2222 -i <key>
  root@<guest-ip>`. On 9.x, `admin@` also works. The stock port-22 service is left
  untouched.
- **ECDSA SSH host key**: added by default so modern clients connect without
  `-o HostKeyAlgorithms=+ssh-rsa`. Set `ZD_ECDSA_SSH=0` to revert.
- **Network Monitor**: a community page (from `dbro/zd1200`) installed into both
  root partitions, with its menu entry added to whichever admin console the
  release ships (10.x Troubleshooting, 9.12/9.13 Monitor menu, 9.9–9.11 classic
  menu). Collection is off until enabled from the page's ⚙ menu.
- **R600 / ap-11n-scorpion mesh repair**: the affected AP firmware is patched as
  it is staged, but only for 10.5.1 builds **≥ 10.5.1.0.276** (the release that
  introduced the bug). Other releases are skipped.

## Configuration

`.env` (created from `docker/.env.example`) holds the common knobs:

| variable | purpose |
|---|---|
| `ZD_GUEST_IP` | guest IP used for the printed URL (readiness is console-based) |
| `ZD_CONTAINER_MAC` | unique container MAC the guest identity is derived from (auto-generated) |
| `ZD_SIGN_CERT_HOST` | signing-cert payload for the license patch |
| `ZD_SERIAL`, `ZD_MAC1` | pin the identity (with `ZD_BOARDDATA_FROM_MAC=0`) |
| `ZD_VIRTUAL_BUILD_ID` | source revision shown as `virtual <rev>` on the console |
| `ZD_ROOT_SSH_PUBLIC_KEY` | same as `--root-ssh-key` |
| `ZD_ECDSA_SSH` | ECDSA host key alongside RSA (default `1`) |
| `ZD_PING_INTERVAL_SECONDS`, `ZD_PING_CLIENT_TARGETS` | Network Monitor defaults |
| `ZD_CONTAINER_NAME`, `ZD_STATE_VOLUME` | container and volume names |

## Troubleshooting

| symptom | fix |
|---|---|
| `Cannot reach the Docker daemon`, or `permission denied` on the Docker socket | add yourself to the `docker` group (`sudo usermod -aG docker $USER`, then re-login) or run with `sudo`. |
| Container restart-loops | find the real error in the guest log: `docker logs zd1200 \| tail -80`, or `docker exec zd1200 tail -80 /tmp/zd1200-console.log`. |
| `Up (unhealthy)` for a long time | no usable `/dev/kvm`; the guest is running under TCG. Enable KVM or wait longer. |
| `cat: /var/lib/zd1200/guest-ip: No such file` | the guest has no DHCP lease yet, or the LAN has no DHCP. Watch the console log for `guest leased IP`. |
| Web UI unreachable from the Docker host | expected: the host cannot reach a macvtap sibling. Test from another LAN machine. |
| Web UI redirects to the setup wizard | expected on a fresh volume; complete the wizard, then reboot. |
| `ssh admin@<ip>` refused after first boot | finish the wizard and reboot once so the appliance generates its SSH host key. |
| `Permission denied (publickey)` on port 2222 | build with `--root-ssh-key` and use that key; on 9.x `admin` and `root` both work. |
| `firmware file not found`, or `vendor archive lacks ...` | wrong path, or the file is not a ZD1200 upgrade image / CF dump. |
| `no valid board-data record with a MAC found` | the dump's board data is outside the ZD1200 offsets; the container then derives its identity from `ZD_CONTAINER_MAC`. |
| `could not detect the /writable partition` | pass `--writable-partition START:COUNT`; the values come from `scripts/build/find-cf-partition.py <dump> <header_offset>` (header offset is 512 for ImageUSB, else 0). |
| `image/writable.raw is ... larger than the ... data partition` | the foreign `/writable` is bigger than the ZD1200 layout; use a same-version ZD1200 firmware, or a smaller card. |
| Boot is very slow / host fans spin up | no KVM, or the CPU duty-cycle cap is in effect; see the compose file's CPU options. |

## Factory reset / clean state

```sh
docker compose --project-directory . -f docker/docker-compose.yml down -v
```

Removes the container **and** the `zd1200-state` volume, so the next
`build-container.sh` boots a factory appliance again.

## Files

```
build-container.sh   the one entry point
docker/              Dockerfile, Compose files, .env.example
scripts/build/       host-side preparation (firmware decrypt, CF-dump parsing)
scripts/container/   in-container guest-image prep + the ordered rootfs patches
scripts/test/        boot-test.sh (boot the prepared disk without the container)
analytics/           Network Monitor payload (from dbro/zd1200)
dropbear/            vendored static dropbear for the optional 2222 listener
bl7/                 vendored AP-firmware patch tooling (R600 mesh repair)
docs/INTERNALS.md    disk model, patch pipeline, board data, boot/shutdown, boot test
image/               artifacts derived from your input (gitignored)
```

## License

MIT — see `LICENSE`. The firmware (including the GRUB binaries this repo reuses)
is Ruckus/CommScope's and is never committed or redistributed here.
