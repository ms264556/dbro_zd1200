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

## Where things live

| path | role |
|------|------|
| `Dockerfile`, `docker-compose.yml`, `docker-compose.user.yml`, `.env.example` | the container + its network |
| `run-zd1200-web.sh` | the container **entrypoint** (build disk, patch, boot guest, healthcheck) |
| `run-zd1200-qemu.sh` | launches QEMU; **only ever called by the entrypoint** |
| `host/zd1200-bridge*` | optional host TAP bridge for the `tap` path; NOT the default |
| `inject-dropbear.sh` | optional port-2222 dropbear injection into `image/rootfs.ext2` (host-side, before `up`) |
| `make-synthetic-cf.py`, `patch-rootfs.sh`, `patch-rootfs-signing.sh`, `write-boarddata.py` | guest image prep; run **inside** the container |
| `build-container.sh` | the one command everyone should run |

## Read these before doing anything

1. `RUNBOOK.md` — the authoritative Docker launch recipe + all gotchas.
2. `README.md` — overview + prerequisites.

## Verify

- `sudo docker ps` → `zd1200 Up (healthy)`.
- Guest console / boot: `sudo docker logs -f zd1200` and
  `sudo docker exec zd1200 tail -f /tmp/zd1200-web.log`.
- Guest IP: `sudo docker exec zd1200 cat /var/lib/zd1200/guest-ip`.
- Reach it from a **LAN host**, not from the docker host.
