# AGENTS.md — read this first

## This is a Docker Compose project. Do NOT run QEMU directly. Do NOT rebuild the network.

The ZoneDirector guest runs **inside a Docker container**. QEMU is only the
emulator process *inside* that container. The network stack (host netns +
macvtap on the host's physical NIC) is **already built and verified** here.
Your job is to **use it**, not to re-implement or "fix" it.

## The ONLY supported way to run this

```sh
sudo ./build-container.sh     # prepares image/ (once), creates .env, then: docker compose up -d --build
```

- `build-container.sh` is the single entry point. It auto-prefixes `sudo` if the
  user is not in the docker group.
- It invokes the documented `docker compose up -d --build` — nothing else.

## Networking is DONE — do not touch it

- **Default** (`docker-compose.yml`): host network namespace + **macvtap on the
  host's physical NIC**. This is the correct, verified recipe (RUNBOOK.md §7b).
  The guest is a real LAN device with its own DHCP lease.
- The docker host/container **cannot reach this macvtap guest** (a macvlan
  parent does not loop frames back to its sibling). That is documented and
  expected — RUNBOOK.md §6. Verify the guest from a **separate LAN host**. It
  is NOT a bug and NOT something to "fix."
- Host lacks MAC-spoofing/KVM? The documented fallback is the `docker-compose.user.yml`
  **override** (QEMU user-mode NAT + host port forwards) — not a hand-rolled network:
  ```sh
  docker compose -f docker-compose.yml -f docker-compose.user.yml up -d
  ```

## What you must NOT do

- Do **not** run `run-zd1200-qemu.sh` or `run-zd1200-web.sh` directly as the
  primary path. These are the container's **guest launcher / entrypoint**;
  the container calls them. Running them standalone on the host is QEMU hackery.
- Do **not** re-implement macvlan, macvtap, TAP bridges, or any network setup.
  RUNBOOK.md §7b documents the (already-fixed) host-netns requirement. Follow it.
- Do **not** "fix" guest reachability with network/route/iptables hacks.
- Do **not** rebuild dropbear/rootfs by hand: `inject-dropbear.sh` is the repo
  script (host-side prep, run **before** `up`).
- Do **not** re-add `-no-reboot` to QEMU.  The guest reboots **in place** (its
  patched `machine_restart()` issues a QEMU i8042 system reset), so a guest reboot
  does not tear the container down.  Any firmware-upgrade workflow that wants QEMU
  to exit per reboot must use its own harness, not the normal container path.

## How the guest image is prepared, and reboot

Before QEMU boots, the entrypoint runs `apply-rootfs-patches.sh` (the **only**
place that builds the disk/overlay or patches the rootfs).  It builds the writable
synthetic disk + `/writable` (hda4), writes the board data, creates the qcow2
overlay, then runs every patch in `patches/` in lexical order.  The patches only
ever modify the **rootfs** (hda2/hda3) — **never** `/writable`.

The coordinator reconciles state against a signature file
(`/var/lib/zd1200/.patches-applied`, holding the base-rootfs + patch-set hashes):

| state | what it does |
|---|---|
| first run (no overlay) | build base + overlay, write board data, patch |
| overlay exists, no marker | keep base + `/writable`, recreate overlay, re-patch |
| base rootfs hash changed (upgrade) | rebuild base + overlay, re-patch |
| patch set changed | keep base, recreate overlay, re-patch |
| nothing changed | no-op |

Whenever it patches it **recreates the overlay first** (never patches in place).
**`/writable` (hda4) and board data are preserved across a re-patch** (the current
hda4 is copied out and restored), and board data is written **only** when the base
is built (first run / base rebuild).  So re-patching changes only the rootfs, never
the controller config or the serial/MAC.

The running guest reboots cleanly from inside (kernel `machine_restart()` →
i8042 reset), so the container stays `Up (healthy)` across a guest reboot.

## Where things live

| path | role |
|------|------|
| `Dockerfile`, `docker-compose.yml`, `docker-compose.user.yml`, `.env.example` | the container + its network |
| `run-zd1200-web.sh` | the container **entrypoint** (build kernel, prep disk+overlay+patches, boot guest, healthcheck) |
| `run-zd1200-qemu.sh` | launches QEMU; **only ever called by the entrypoint**; never passes `-no-reboot` (guest reboots in place) |
| `host/zd1200-bridge*` | optional host TAP bridge for the `tap` path; NOT the default |
| `inject-dropbear.sh` | optional port-2222 dropbear injection into `image/rootfs.ext2` (host-side, before `up`) |
| `apply-rootfs-patches.sh` | guest-image prep / patch **coordinator**: builds synthetic disk + overlay, decides first-run vs upgrade vs patch-set vs no-op, runs `patches/` in order; preserves `/writable` + board data across re-patches |
| `patches/` (NN - Name.sh) | ordered rootfs patches run into the qcow2 overlay before QEMU; **rootfs only**, never `/writable` |
| `patch-kernel.py` | signature-matches and bytes-patches the kernel for QEMU (incl. `machine_restart()` → i8042 reset so reboot works) |
| `make-synthetic-cf.py`, `write-boarddata.py` | guest image prep; run **inside** the container |
| `build-container.sh` | the one command everyone should run |

## Read these before doing anything

1. `RUNBOOK.md` — the authoritative Docker launch recipe + all gotchas.
2. `README.md` — overview + prerequisites.

## Verify

- `sudo docker ps` → `zd1200 Up (healthy)`.
- Guest console / boot: `sudo docker logs -f zd1200` and
  `sudo docker exec zd1200 tail -f /tmp/zd1200-web.log`.
- Guest IP: `sudo docker exec zd1200 cat /var/lib/zd1200/guest-ip`.
- Patch state / whether a re-patch is queued: `sudo docker exec zd1200 cat /var/lib/zd1200/.patches-applied`.
- Reach it from a **LAN host**, not from the docker host.  The guest reboots in
  place (its `machine_restart()` → i8042 reset), so a guest reboot leaves the
  container running; you do **not** need to `docker restart` it.
