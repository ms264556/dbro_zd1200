# Review: the VM-support attempt (`feature/vm-failed-attempt`)

A code review of the 83 commits that attempted to add a bootable VM image to a project that
supported Docker and Proxmox LXC. **This is a review, not a salvage plan.** Nothing has been
carried onto `main`, and nothing here should be read as a recommendation to continue the work.

## 1. Repository operations performed

| step | result |
|---|---|
| `feature/vm-failed-attempt` | `7dcfb23`, the tip of the abandoned work, holding **all 83 commits** that were previously reachable only from local `main`. |
| local `main` | reset to `origin/main` = `d896a24` "Install from a ZD configuration backup or disk dump" (2026-09-21). It now matches GitHub exactly: 0 ahead, 0 behind. |
| `vm-attempt-review` | created off `d896a24`; this document is committed here. |

Nothing was pushed, and nothing was lost: all 83 commits are still reachable from
`feature/vm-failed-attempt`, and the pre-existing worktrees at `7a8090b` (session14) and
`306a173` (session15) are untouched.

**Correction to the premise this session started from.** Local `main` was *not* "pushed to
GitHub" with these changes: it was 83 commits ahead of `origin/main` and 0 behind, and a `git
fetch --prune` confirmed `origin/main` really was `d896a24`. GitHub had none of this work.

## 2. Scope reviewed

`git diff main feature/vm-failed-attempt` = **103 files, 24 914 insertions, 607 deletions**.

| area | files | diff |
|---|---|---|
| test suite and harness (`scripts/test/`) | 41 | +13 101, −43 |
| documentation (`README.md`, `docs/`) | 6 | +4 867, −34 |
| first-run web wizard | 5 | +2 251 |
| kernel/firmware patches | 4 | +1 091, −59 |
| VM deliverable (`mkosi/`, `build-vm-image.sh`, `scripts/container/vm/`) | 17 | +1 655 |
| container runtime (`entrypoint.sh`, `launch-vm.sh`, `qemu-once.py`, guest-address, attach-console) | 5 | +711, −59 |
| installers | 3 | +506, −65 |
| canonical systemd units | 11 | +374 |
| Proxmox/LXC helpers | 4 | +165, −290 |
| Docker flow | 5 | +182, −18 |

Two figures mislead if read alone. The `docs/` total is dominated by one 324 KB file that should
not be in the tree at all (§7). And the Proxmox/LXC line is net-negative only because
`scripts/container/proxmox/zd1200-guest-address` became a symlink — the helper moved to
`scripts/container/zd1200-guest-address` with a symlink left behind (§5.2).

## 3. Measurements taken for this review

Run on this workstation against a clean detached checkout of `7dcfb23` with nothing else running.

| measurement | result |
|---|---|
| `bash -n` / `py_compile` over all 63 added or changed shell and Python files | 13 python + 50 shell, **0 failures** |
| `scripts/test/run-suite.sh` (the branch's whole offline suite) | **`ran 46 of 51 tests`, `0 of 51 tests failed`** |
| `scripts/test/run-suite-test.sh` | all checks pass, including the arms that drive the *pre-fix* runner over a fixture and require the count to change |
| `scripts/test/patch-kernel-fixture-test.sh` | all checks pass, including the arms proving the pre-change patcher `35e4dfe` reports the dhcp0 fix as skipped and the wrong-geometry patcher `79eb4b8` fails the reachability check |
| `scripts/test/wizard-http-test.py` in isolation at `7dcfb23` | **48 of 48 checks pass** |
| the `main` CPU-guard defect, reproduced with `main`'s own launch construct | wrapper process **1 own tick over 3 s** while its child accumulated **352 ticks** (~100% of a core) — the wrapper the guard sampled and the cap throttled owns none of the guest's CPU |

Why five tests did not run, and three ran fixture-only — each with the branch's own stated reason:

* `boot-test.sh` — this aarch64 host cannot execute the image's i386 stage;
* `patch-matrix-test.sh` — `AS_FIRMWARE_DIR` is not set;
* `quick-docker-check.sh` — needs a release and a tree argument;
* `wizard-e2e-lxc.sh` — needs the PVE host;
* `xlink-mac-test.sh` — needs root;
* `chk-integrity-cost-test.sh`, `skip-integrity-test.sh`, `webs-header-limit-test.sh` — ran against a synthetic fixture or a subset of matrix roots and said so in a `partial:` line.

Two facts follow, and they frame everything else:

1. **The tree is not broken.** 24 914 inserted lines, 46 of 51 tests passing, the rest skipping
   cleanly rather than aborting. The failure in this branch is scope, not craft.
2. **The firmware matrix was not covered.** No vendor firmware was involved in any run above, so
   every claim about a specific ZD1200 release remains a code read, a synthetic fixture, or the
   author's own recorded lab measurement until someone runs the documented matrix. That is the
   largest single gap in the evidence behind this branch.

A false alarm of my own, recorded because it is instructive: I first measured 25 of 48 wizard
checks failing. That was an artefact of running the wizard test twice plus the full suite
concurrently on a host whose `/tmp` is a 3.8 GB tmpfs, while the test stages ~8 GB. Re-run
cleanly at the same revision it passes 48/48, and it passes at every revision in the window I
suspected (`f141a12`, `39fd6fa`, `881e483`, `8c75566`, `2043850`, `f02ca0c`, `7dcfb23`). There is
no regression there.

## 4. What the review found, in short

**No unsound change was found in the areas reviewed at the branch tip.** The categories:

| category | meaning |
|---|---|
| **SOUND-FIX** | fixes a defect that is real in `main` today, and would be worth having regardless of the VM work. |
| **SOUND-ENHANCEMENT** | a genuinely useful new capability or test, not required by the VM work. |
| **SOUND-BUT-VM-ONLY** | correct, but exists only to serve the VM deliverable. |
| **CHURN** | scope expansion or refactor with no defect behind it; changes files the request did not cover. |
| **UNPROVEN** | plausible, asserted in a comment, not evidenced by anything in the tree. |

The headline results:

1. **The change set is two-way entangled, and that is the real problem.** The VM tree cannot be
   lifted onto `main` on its own — `mkosi/mkosi.postinst.chroot:38,89-92` dies without
   `scripts/container/wizard/*`, and the wizard commit `603fd41` is an ancestor of the VM commit
   `447de92` but **not** of `main`. Conversely, `docker/Dockerfile:268-274` globs
   `/opt/zd1200/scripts/container/vm/*.sh` inside a bare `RUN chmod`, with no `|| true` and no
   `2>/dev/null`; an unmatched glob therefore fails that layer. **Deleting the VM tree breaks
   `docker build` until that one line changes.** There is no clean cut point.
2. **The branch is honest about its own defects.** The one outright wrong thing it produced — a
   second, already-drifted hand-written copy of two shared systemd units (`mkosi.extra`'s
   `zd1200.service` and `zd1200-net.service`, from `447de92`) — was found and removed *inside* the
   branch by `6553afa`, replaced by one canonical unit set.
3. **Most "fixes" here fix the branch's own code, not `main`.** The wizard is new code, so
   `_Part.read`'s dropped-buffer bug, the missing closing-boundary check and the torn-delimiter
   bug were all introduced and then fixed within this branch. They are sound fixes to code that
   should not exist on `main`.
4. **The genuinely independent `main` defects are a short list** (§5.1) — and they are real,
   measured, and none of them needs the VM deliverable.
5. **Several changes alter behaviour for existing Docker/LXC users** even though the request was to
   add a third deliverable: the Docker image layout (`9f57d9d`), the systemd-unit refactor
   (`6553afa`), the Docker compose `ZD_CPU_GUARD` threshold (`73f54e1`), the Docker image volume
   replacing the `./image` bind mount (`603fd41`/`83472c8`), and the default instance name
   (`93a913e`).

Verdict counts across the five reviewed scopes, as reported and then checked here:

| verdict | count | notes |
|---|---|---|
| SOUND-FIX | ~45 | includes the twelve independent `main` fixes in §5.1 and the test-harness isolation fixes in §5.5 |
| SOUND-ENHANCEMENT / SOUND | ~20 | new tests and fixtures, the suite runner, additive helper arms |
| SOUND-BUT-VM-ONLY | ~25 | the mkosi tree, `build-vm-image.sh`, the VM helpers, the wizard and its server |
| CHURN | ~12 | scope expansion and self-inflicted repairs with no `main` defect behind them |
| UNPROVEN | ~12 | see §5.4 and §6 — the firmware-matrix and lab measurements |
| UNSOUND | 2 | one fixed inside the branch (`mkosi.extra`'s duplicate units); one left standing (`/api/manual` is inert) |
| Test-only quality findings | 6 | §5.5 and §6 item 8 |

## 5. Per-area verdicts

### 5.1 The independent `main` fixes

These are real defects in `main`, verified by reading both sides and, where noted, by running the
branch's own test.

| # | fix | the defect in `main` | verdict |
|---|---|---|---|
| 1 | `52e556a` — `scripts/container/proxmox/zd1200-ct-net.sh` stops `dhclient` by PID | `main:230` runs `pkill -f "dhclient.*$HOST_IF"`, a full-command-line ERE match. The replacement walks `/proc`, requires the process's own `exe` to be `dhclient` *and* `$HOST_IF` to be one of its own `argv` elements, and kills by PID; unreadable or vanished `/proc` entries are skipped and a no-match run is a silent no-op. | **SOUND-FIX** (measured before/after by `ct-net-dhclient-test.sh` — the look-alike is killed before, spared after). Two caveats found in review: the branch's own comment and test header say `-f` matches "every process on the host", but the script is installed and executed *inside* the container (`zd1200-ct-bootstrap.sh:677` → `/usr/local/sbin/zd1200-ct-net`), so the real blast radius was that container's PID namespace — the claim is overstated even though the fix is strictly narrower. And the exact-argv match no longer stops a `dhclient` whose interface appears only in `-pf`/`-lf` paths or a config file, a narrowing the test cannot detect because its decoy always carries a bare interface token. |
| 2 | `c247379` + `8c3e11b` — the CPU guard samples the emulator's pid | `main:295-296` sets `qemu_pid=$!` for the `launch-vm.sh` wrapper and then samples `/proc/$qemu_pid/stat` (`main:468`) and hands the same pid to `limit-process-cpu.py` (`main:311`). QEMU is a grandchild (`launch-vm.sh` → `qemu-once.py` → `qemu-system-i386`) and `utime+stime` exclude children, so `main` shipped a duty-cycle cap and a `>95% CPU` trip that were both **inert**. I reproduced the mechanism with `main`'s own launch construct (`setsid env … nice -n 10 <wrapper>` whose real work is a child): the wrapper accumulated **1 own tick over 3 s** while its child accumulated **352 ticks** (~100% of a core). The branch publishes the real emulator pid via `ZD_QEMU_PID_FILE` and verifies the pid still belongs to a `qemu-system-*` before sampling it. | **SOUND-FIX**, with one residual: arming the trip for the first time makes the threshold load-bearing, and the Docker compose bump from 4 to 24 samples (`docker-compose.yml:107`, absent in `main`) is an unmeasured mitigation — what would settle it is one KVM first boot logged through the branch's own `High-CPU watchdog record:` lines showing `longest_run < cpu_guard`. **Resolved 2026-09-27, many times over**: the matrix shows `longest_run=0` in every KVM arm across three releases (bare-metal peaks ~4% of one core, nested ~58%), so the threshold is not load-bearing in any measured boot; see "What the CPU guard is now for" in `docs/TROUBLESHOOTING.md` and the session handoff's before/after index. |
| 3 | `059279a` — `ACCEL` is honoured | `main:45-49` probes `/dev/kvm` unconditionally and `main:275` overwrites `ACCEL` when launching, so the knob was dead on both flows. The branch resolves `auto\|kvm\|tcg`, rejects anything else with exit 2, and passes the result through. No flow sets `ACCEL` today, so the default path is byte-for-byte unchanged. | **SOUND-FIX** |
| 4 | `86b9204` — the Docker flow can find the guest's address | Two independent causes in `main`: `main:343` only consults the helper when `GUEST_IP` is empty, and Docker always sets one (`docker-compose.yml:53`, `.env.example:4`, `Dockerfile:239`); *and* `address_helper` defaults to `$work_dir/zd1200-guest-address` (`main:32`) where no such file exists — the only copy is under `scripts/container/proxmox/`, which `docker/Dockerfile.dockerignore` excludes. So the Docker flow printed the static `GUEST_IP` and never asked the guest. The branch moves the helper to `scripts/container/`, leaves the old path a symlink, and makes `GUEST_IP` the fallback. | **SOUND-FIX** (measured in `main`'s real Docker layout; `docker-guest-address-test.sh` passes 10/10) |
| 5 | `37dfe5`-family kernel patch work — see §5.4 | two vendor NULL-pointer races that kill PID 1 | **SOUND-FIX** |
| 6 | `4371292` — the printed admin URL | `/admin10/login.jsp` is 10.x-only and 500s on 9.x; the entrypoint now prints `https://<ip>/`, which redirects into the release's own admin tree. | **SOUND-FIX** |
| 7 | `a2817f7` — removes `KERNEL_EXTRA=nohz=off` | `git grep KERNEL_EXTRA main` finds two write sites and **zero** read sites. A dead setting. | **SOUND-FIX** |
| 8 | `7dcfb23` — a dump's own serial reaches every path | `main`'s CLI path already reuses `$IMAGE_DIR/dump-boarddata`, but the LXC bootstrap and the wizard's disk build derived the serial from the container MAC instead, so the same dump restored two ways came up as two different appliances. The MAC still comes from this instance's seed, so clones do not collide on the LAN. | **SOUND-FIX** |
| 9 | `fdecd88` — LXC container-id allocation | A genuine check-then-use race on host-global state: two concurrent installs both scanned, both chose the same free id, and the loser died on `pct create`. The branch takes an `flock` across allocation and create, released before the slow install. With no `flock` it warns and continues unlocked. | **SOUND-FIX** (measured: pre-fix both runs chose 120) |
| 10 | `93a913e` — Docker instance naming | `.env` was created *after* the names were read from it, so a first run in a second checkout computed the same seven names and the second run's publish replaced the first's guest. | **SOUND-FIX** (measured) |
| 11 | Harness isolation and honesty — see §5.5 | a `pkill`-class family of defects *inside the tests* | **SOUND-FIX/ENHANCEMENT** |

### 5.2 The Docker / Proxmox / LXC flow

| change | verdict | note |
|---|---|---|
| `86b9204` helper move + `GUEST_IP`-as-fallback | SOUND-FIX | the symlink left at `scripts/container/proxmox/zd1200-guest-address` keeps every existing caller working (LXC bootstrap `install`s it to `/usr/local/sbin/`, healthcheck and display default to that path). Residual risk: a build that copy-dereferences or an archive that flattens symlinks loses it silently, and no test covers that. |
| `9f57d9d` Docker image checkout shape | SOUND-BUT-COUPLED | `main:205` `COPY scripts/container/ /opt/zd1200/` becomes `…/opt/zd1200/scripts/container/`. This is not VM-only — it changes the plain Docker image — and it is tightly coupled to `boot-test.sh`'s entrypoint path in the same commit. Applying either half alone breaks the other. |
| `757b815`, `83472c8`, `73f54e1`, `b48bcd9` compose/volume corrections | SOUND-FIX / CHURN | `73f54e1` raises Docker's `ZD_CPU_GUARD` from the shared default to 24 samples because a fresh KVM guest false-tripped 4 samples (20 s) after READY — justified by its own commit record, unmeasured here. `83472c8` moves `image/` to the named volume `zd1200-image`, and `603fd41` had already put it there: `main` mounted the host's `./image` directly, so a Docker user loses a live mount in exchange for a published volume, and `.env.example:17` still ships `ZD_SIGN_CERT_HOST=./image/signing-cert` while the compose comment says the volume is the default. The "empty image/" defect those commits fix was created by the named-volume change itself, not by `main`. |
| `6553afa` one canonical unit set | SOUND, behaviour-preserving — measured | The replacement of the bootstrap's six unit heredocs by `units-install.sh` is the highest-blast-radius change in the whole branch: it rewrites unit installation for **every** LXC install, wizard or not. It was checked by rendering the `--platform lxc` output and comparing it byte-for-byte against `main`'s heredocs (all six identical; the enable set identical; `zd1200-wizard.service` identical to the wizard's old heredoc). The only deltas are stderr noise on a failed enable with the exit status preserved, and a `daemon-reload` skipped when `/run/systemd/system` is absent. |
| `zd1200-ct-net.sh` + `ct-net-dhclient-test.sh` | SOUND-FIX / ENHANCEMENT | see §5.1 item 1. The test is a good example of the branch's harness discipline: it refuses to run the host-global pre-fix path unless the only matching processes are its own decoys. |
| `docker-image-reuse-test.sh` | SOUND | **not** an isolation fix despite its neighbours: it is a stub-model update coupled to `83472c8`, and is meaningless without it. |

### 5.3 The VM deliverable and its entanglement

| change | verdict |
|---|---|
| `mkosi/` tree, `scripts/build/build-vm-image.sh`, `scripts/container/vm/*` | SOUND-BUT-VM-ONLY |
| `mkosi.extra`'s hand-written `zd1200.service` / `zd1200-net.service` (`447de92` only) | **UNSOUND** — a second definition of two shared units, already drifted from the LXC heredocs. Removed inside the branch by `6553afa`. |
| `6553afa` units refactor | SOUND (measured behaviour-preserving, §5.2) |
| `a2817f7`, `059279a`, `c162b3d` VM doc/comments | SOUND-BUT-VM-ONLY |
| `39ca069` `patches/15-zd-early-watchdog.sh` | **CHURN** — see §6.3 |
| `9f57d9d`'s `chmod … /opt/zd1200/scripts/container/vm/*.sh` | **CHURN with teeth** — see §4 item 1 and §6.1 |

Two brief assumptions were wrong and are corrected here: `launch-vm.sh`'s only change
(`86b9204`) is in the **Docker** macvtap path, not the VM's; and `boot-test-runscope-test.sh`
belongs to the Docker `boot-test.sh` scope, not the VM's.

### 5.4 The guest-boot fixes (the strongest content in the branch)

`scripts/container/patch-kernel.py` gains two firmware patches and the machinery to apply them
safely:

* **`addrconf_dev_config_dhcp0`** — the vendor `af` module builds `dhcp0` by
  `register_netdevice()` → `dev_open()` → `dev_dhcp = dev`. The `dev_open()` fires the IPv6
  addrconf notifier, which adds dhcp0's link-local address and so joins a solicited-node
  multicast group; `igmp6_group_added()` arms an MLD timer ~2 jiffies out, and when it fires
  `dhcp_xmit()` dereferences the module-global `dev_dhcp`, which is still NULL because
  `create_dhcp()` has not reached the store. The vendor's oops guard then reboots the guest, so
  the boot loops instead of reaching READY. The patch stops `addrconf_dev_config()` from
  configuring dhcp0 at all — which removes the trigger entirely, because with no link-local
  address there is no group and therefore no MLD timer — while leaving every other interface's
  behaviour byte-identical. Two shapes are needed (the standalone function, and the releases whose
  compiler inlined it into `addrconf_notify()`), expressed as one `group` so exactly one member
  applies per release.
* **`rks_pkt_trace_init`** — restored; suppressing creation of the vendor `tif0` interface. The
  same shape of bug: `create_tif()` registers and opens the interface during init, `dev_open()`
  fires addrconf, and an MLD transmit reaches `tif_xmit` on a half-built device and kills PID 1.

What makes these trustworthy rather than merely plausible:

* the patches are checked against a **synthesised kernel fixture** with the real geometry, and
  `scripts/test/patch-kernel-fixture-test.sh` passes here — including the arms that require the
  pre-change patcher (`35e4dfe`) to report the fix as skipped, and the wrong-geometry patcher
  (`79eb4b8`) to **fail** the reachability check. That test can fail, which is the point.
* `scripts/test/check-patched-kernel-site.py` reads the result back out of the patched image
  rather than believing the patcher's own log.
* the patcher was taught to **degrade safely**: `OPTIONAL_PATCHES` and the `group` field mean an
  unrecognised kernel is reported and skipped, not aborted. The commit that added this
  (`35e4dfe`) is a real fix to an installability defect — before it, five of the nine supported
  releases failed to build a disk at all. The project's own rule ("a patch must skip rather than
  abort") is met, and the skip is printed so it is never silently unpatched.
* the comment block records a *previously shipped wrong patch*: an earlier 20-byte replacement
  overwrote the device-type load, so every non-Ethernet device was dispatched as
  `ARPHRD_ETHER` on four releases — a silent behaviour change no boot test could see, found by
  disassembling the patched kernels.

The branch also adds `patches/55-webs-header-limit.sh` (SOUND but not VM-related): two releases
omit `LimitRequestFields` from `/bin/webs.conf`, so Appweb's compiled-in default of 20 applies and
the admin wizard's 21-field AJAX calls are aborted with an empty reply. The patch inserts the
vendor's own two directives in the vendor's own position, leaves a file that already carries the
directive byte-for-byte alone, and skips any file it does not recognise. Two roots are
deliberately **not** patched, with the reasoning and the measurement recorded, rather than
pattern-matching an insertion point.

And `40-skip-integrity.sh` gains a best-effort parsing rewrite: the vendor's five
`echo|cut` parsing lines per `/file_list.txt` entry are replaced with shell builtins, gated so
that anything short of a certain match leaves the vendor parsing in place and still applies the
md5 no-op. Safe degradation, with the "already patched" and "unexpectedly modified" states
distinguished by counting rather than by a version marker.

**This is the part of the branch that reads like the project's own standard, and the part most
worth keeping** — with two claims that rest on the author's word rather than on anything in the
tree:

* **`rks_pkt_trace_init` is UNPROVEN, and it has a cost.** Its justification (6 of 20 TCG boots
  oopsed without the patch, 0 of 20 with it) exists only in the commit message; `main` has no such
  patch; `docs/INTERNALS.md` documents the dhcp0 fix in depth and this one only in passing. It is
  also unconditional, so on a KVM host — where the crash was never observed — it still removes the
  guest's packet-trace interface. A non-ancestor commit (`27257bc`) had previously *removed* this
  patch after concluding `tif0` "stays healthy" on 10.5.1.0.282. What would settle it: a recorded
  before/after on a named release under `-accel tcg`, oops counts plus `tif0` absence, and a
  statement of what is lost when the interface never exists.
* **`patches/15-zd-early-watchdog.sh` is UNPROVEN and has no test at all.** Its argument is a
  careful code read of the vendor kernel's ~61 s userspace-watchdog budget, but nothing in the
  repo measures the counter expiring without it, and the nine-release VM matrix in the archived
  history is consistent with the patch simply being present. It is applied by `prepare-vm-disks.sh`
  to **every** flow's guest disk, with no accelerator gate (§6.2).

A third claim is correctly labelled by the branch itself: the `55-webs-header-limit` insertion on
`9.10.2.0.130` is **preventive** — no 9.x failure has been measured there, the 9.x page sits one
field under the limit, and the docs say so rather than implying a fix.

The **dhcp0** work, by contrast, is the best-evidenced change in the branch: an offline
discriminator that requires the old patcher to fail, a fixture that rejects the wrong anchor, an
abort→skip transition reproduced independently, and a before/after outer-TCG rig recorded in the
archive with oops events going 2 → 0 and kernel hashes verified on both root partitions by offline
`debugfs`. `40-skip-integrity.sh`'s rewrite is similarly honest: `do_parse` requires all five
vendor parsing lines to match exactly once, and anything short of that skips the rewrite with a
warning while the md5 no-op still lands.

Small quality faults found in this area: the read-back verification in `40-skip-integrity.sh`
greps for `_have4`, an implementation-private name, so the check only passes while that name
survives; `count_fixed()`'s `grep -cF … || true` yields an empty count on a grep *error*, and
`[ "" -gt 1 ]` would then abort under `set -e` — an abort path in a patch built to skip; and the
entrypoint's own comment describes the TCG measurement as "a single-vCPU emulator" while
`launch-vm.sh` defaults to `-smp 2` and no flow sets `ZD_SMP`.

### 5.5 The test harness, the installers and the docs

The harness work is the largest single block (41 files, 13 101 lines) and it is unusually honest:
**every isolation claim I checked is backed by a test that stages the actual pre-fix revision out
of git and requires it to exhibit the defect.** For example:

* `boot-test.sh`'s per-run state dir (`51678b9`) fixes a shared `$repo/.boot-test` whose
  `serial.log` each run truncated — so one run could PASS on another's guest line. The test
  requires the pre-fix revision to false-PASS.
* `console-bridge-test.py` (`3061603`) fixes a fixed `/tmp/zd1200-console-bridge-test` path that
  two runs unlinked out from under each other.
* `xlink-mac-test.sh` (`50a17ec`) fixes host-global netns names where each run's cleanup deleted
  the other's live topology.
* `quick-docker-check.sh` (`b6f2534`, `62a5af3`) fixes four measured defects at once, including
  teardown that removed volumes it *computed* rather than the ones the container mounts.
* `patch-matrix-test.sh` (`c6fdfc1`) fixes a scratch directory that leaked on every run — 35 had
  accumulated — and removes only a scratch it owns, never a caller's `AS_SCRATCH`.
* `run-suite.sh` (new) is the piece that makes all of the above visible: it reports
  `ran N of M` and names each test that skipped or ran fixture-only. Its first-line-only
  `SKIP:` rule is not cosmetic — six members gate on a missing tool with `SKIP:` and `exit 0`
  before doing any work, and the pre-fix rule counted each of them as RAN.

Test-quality findings a reader should know:

* `console-bridge-concurrency-test.sh` turns a *loss of discrimination* into a `skipped:` line and
  still prints a green summary — inconsistent with the branch's own stated rule
  (`patch-matrix-scratch-test.sh`: "a fixture that cannot reproduce the defect would make every
  check above worthless, so that is a loud FAIL, not a skip").
* `wizard-e2e-lxc.sh` removes its remote run directory only on the normal path; every
  `bad … exit 1` path leaks `/root/.zd-wizard-e2e-*` on the PVE host — the same leak class the
  branch fixes elsewhere. Its staging tarball is also written *inside* the tree it archives and
  only pattern-excluded, and `.zd-wizard-e2e.*.tgz` is not in `.gitignore`.
* `skipped()` is left defined and never called in both integrity tests.
* `run-suite.sh` is described as "the offline suite", but members are invoked with no arguments
  and `boot-test.sh` with no arguments will build the Docker image and boot QEMU; two members
  self-escalate to root when `sudo -n` succeeds. On a lab-like host, "offline" is optimistic.

Installer fixes (`fdecd88`, `93a913e`) are genuine and measured; both degrade safely when their
tools are absent.

The documentation is bimodal and should not be judged as a block. Real corrections, statically
verifiable: `stop_grace_period` quoted as 180 s where compose says 260 s; a four-cell row in a
three-column table; "asks the guest two questions in one round trip" where the helper opens two
connections; the Docker-parity paragraph that the branch had got wrong one commit earlier and
fixed in the next; and a dead `KERNEL_EXTRA` confirmed by grep. Against that, one table sentence
about `55-webs-header-limit` was rewritten four times, with its measurement claim removed
(`aef5b41`) and then restored (`8c75566`) — a settled finding re-litigated in-doc.

### 5.6 The wizard

The wizard is a new deliverable, not a fix, and it is **opt-in**: `ZD_WIZARD=1` plus an override
compose file, with a one-shot condition so it cannot come back and fight the guest for the LAN.
Default Docker/LXC runs never enter it. Within the wizard, the upload-reader fixes
(`ff45898`, `f141a12`, `f02ca0c`, `d2b4465`) are real and well tested (29/29, 38/38, and a
discriminating 48/48 end-to-end), but they repair code the branch itself introduced, so they have
no value to `main`.

Quality findings inside it:

* `ZD_WIZARD_STATE_DIR` is written into the config and exported, but `wizard.py` never reads it
  (it reads `STATE_DIR` or `/var/lib/zd1200`). Inert today only because every caller happens to
  use the default.
* `wizard-port.sh` documents a safe degradation for an unusable pin (`ZD_WIZARD_PORT=nonsense` or
  `auto`), but the wired path never calls the helper with an argument and never calls it when the
  variable is set — so a nonsense pin still reaches `int()` in `wizard.py` and aborts with a
  traceback, the exact behaviour the helper's header claims to have replaced.
* `/api/manual` ("Set up manually") sets `selected="manual"`, but the page never reads
  `selected` and the staging code ignores it: the button re-renders the same page.
* `classify.sh` claims the browser is told "exactly what `resolve_inputs` would have decided" in
  "the installer's wording"; the release-pairing refusal is not in `resolve_inputs` at all, and
  the wording is adapted.
* The `pairing` field `classify.sh` emits is consumed by nothing in production except its own
  test, and it contradicts the upload rule: `accept_upload` evicts a firmware when a
  self-contained ZD1200 dump arrives, though `classify.sh` says a ZD1200 dump pairs with a
  firmware. Firmware-then-dump and dump-then-firmware therefore yield different input sets.
* The entrypoint decides "the wizard built a disk" by testing `$image_dir/rootfs.ext2`, while the
  Docker installer waits on a `prepared` marker — because `rootfs.ext2` exists mid-build, which
  is precisely why the marker was added.
* The LXC wizard token is derived as `random_mac | tr -d ':'` (~40 bits) where the wizard's own
  installer uses ~120 bits, and it is visible in `pct exec` argv.
* `State._save` swallows `OSError`, so state loss is silent; `handle_one_request` collapses every
  exception into a 500, which also hides programming errors; `_classify_cache` is never pruned.

## 6. Defects found in the reviewed code

1. **`docker/Dockerfile:268-274` globs a directory the branch's own work would delete.** The
   `/opt/zd1200/scripts/container/vm/*.sh` (and `units/*.sh`, `wizard/*.sh`) patterns sit in a
   bare `RUN chmod` with no guard. An unmatched glob fails that layer, so removing the VM tree
   breaks `docker build` — the mkosi equivalent escapes this with `2>/dev/null || true`, the
   Dockerfile does not.
2. **`patches/15-zd-early-watchdog.sh` lands in every flow's guest disk.** `prepare-vm-disks.sh`
   runs every `$PATCHES_DIR/*.sh` unconditionally, with no accelerator gate, so Docker and LXC
   guests get an extra mutation of the vendor rootfs (`S10bootup.sh`) that their KVM boots do not
   need. It is reversible through the rollback store and its own argument is sound for a
   TCG-inside-TCG guest, but it changes flows nobody asked to change.
3. **`build-vm-image.sh --help` truncates its own header** — `sed -n '2,89p'` against a 114-line
   header, so it prints the "Notes" heading and none of the notes. Reproduced by running it.
4. **`build-vm-image.sh:479`** `[ -e "$tap_node" ] || mknod …` is unguarded: a non-root run dies
   with a raw `mknod: Permission denied` instead of a message naming the cause. Reproduced.
5. **`mkosi/mkosi.postinst.chroot`** claims to check "that everything the runtime calls is
   actually present", but its list omits the address helper the image itself configures — the
   same class of omission as the `main` Docker bug it was written next to.
6. **The upload rule and the classifier disagree** about whether a firmware can pair with a
   self-contained ZD1200 dump (§5.6), and the entrypoint and the Docker installer disagree about
   how "the wizard finished" is detected.
7. **`ZD_WIZARD_PORT=nonsense` still aborts** rather than degrading, against the helper's own
   documented contract.
8. **Two tests can under-report**: `console-bridge-concurrency-test.sh` counts a loss of
   discrimination as a skip, and `wizard-e2e-lxc.sh` leaks its remote run dir on any failure
   path.
9. **`install-zd1200-docker.sh` contains the same renamed-instance volume warning twice**
   (`:563-572` to stdout, `:589-598` to stderr with an extra hint), so a renamed instance prints it
   twice in two different formats. Present at `603fd41` and still at the branch tip.
10. **`docs/TROUBLESHOOTING.md` still hard-codes the container name** (`docker logs zd1200`,
    `docker exec zd1200` at `:11`, `:12`, `:66`, `:116`, `:153`, `:252`) while `93a913e` made a
    fresh install's container name derive from its checkout directory. `93a913e` updated one row.
11. **The Docker image build now depends on directories the same branch added**
    (`scripts/container/vm/*.sh`, `units/*.sh`, `wizard/*.sh`). The chmod list is deliberately
    strict — its comment says a build that lost the address helper should fail there rather than
    ship an image whose entrypoint prints a static address — but the effect is that dropping any of
    those trees breaks `docker build` (§4 item 1).

### 6a. Two `main` defects found while porting, not visible from the diff review

Both were exposed by the attempt to port the guest-address fix onto `main`, and both are real
defects in `main` that the branch happened to fix as a side effect. They are recorded here because
the review's per-area verdicts were taken from the diff, and a diff cannot show a path that is
wrong in both revisions only where no test runs.

1. **The entrypoint resolved `image/` relative to the current working directory, not its own
   directory.** `git diff` shows nothing, because the branch uses `$image_dir` (its own
   `IMAGE_DIR` variable) on both sides of the change. On `main`, `entrypoint.sh` does
   `cd "$work_dir"` and then tests `image/bzImage`, so it works only when the process's working
   directory is the checkout root — which is true under Docker's `WORKDIR /opt/zd1200`, and false
   for anything that starts the script from elsewhere, including the project's own test harness.
   The fix derives `image_dir="${IMAGE_DIR:-$work_dir/image}"` from the script's own directory and
   uses it for `bzImage` and `dump-boarddata`.
2. **`ZD_CONTROL_SOCK` was never exported to the QEMU launcher.** `main`'s entrypoint computes
   `control_sock="${ZD_CONTROL_SOCK:-/tmp/zd1200-control.sock}"` and uses it for the orderly-stop
   reboot, but the `setsid env …` block that starts `launch-vm.sh` does not pass it. Both sides
   default to the same path, so a single-instance install behaves — but
   `install-zd1200-docker.sh` writes a per-instance control-socket path into `.env` for any
   non-default `ZD_CONTAINER_NAME`, and `launch-vm.sh` then creates QEMU's ttyS1 chardev at *its*
   default while the entrypoint and the address helper ask at the per-instance path. The guest
   address query and the orderly-stop reboot are both lost silently. This is the same class of
   defect as §5.1 item 4 and survives that fix unless the pass-through is ported with it — which
   is why the ported fix carries it.

## 7. What should not be in the product tree

`docs/history/SESSIONS-RECOVERED.md` — **4207 lines, 324 449 bytes**, added whole by `b6f2534`
alongside `docs/history/README.md`. It is not a document: it is `HANDOFF.md` text recovered from
agent session transcripts, each line prefixed with its original line number, split by 20
`===== RECOVERED CHUNK BOUNDARY =====` markers, with chunks that **overlap** rather than
partition (including 101 duplicated non-blank lines).

What it carries: the lab topology, container ids, fixture paths, 34 absolute `/root/...` paths,
per-arm measurement records, and notes about the author's own harness mistakes. It contains 43
distinct IPv4 literals (8 of which are firmware release prefixes, not hosts), `lab1pve` 16 times,
`ubuntuserver` 7 times, and an `ssh-rsa … root@lab1pve` reference twice (elided in prose with a
literal ellipsis — not key material). I found **no** password, API key, private key or token
*value* in it. It does record a credential-adjacent fact: that `root@lab1pve`'s public key was
appended to an account's `authorized_keys` on a named host, together with that key's SHA256
fingerprint — not a secret, but an access-posture disclosure naming a host and an account.

The commit that ignores `HANDOFF.md` (`65741cc`) does so precisely because the baton holds
internal lab hosts and paths — and one commit later the same material was committed into the tree
in bulk. Nothing in the file is needed to understand or operate the product; the product docs
carry zero `10.222.1.` references on either branch. It is a duplicate of gitignored material.
**Verdict: CHURN, with a disclosure problem for a repo described as public.** If that knowledge is
to be kept it belongs in the gitignored baton; if it is to be published, the addresses, the key
fingerprint and the external evidence paths need stripping first.

## 8. What is genuinely worth keeping

Stated as review findings, not as a work plan. The short answer: **the independent `main` defects
are worth fixing; almost nothing else is.**

**Worth keeping on its own merits** (each fixes a defect that exists in `main` today, is
independent of the VM deliverable, and is verified here):

1. `52e556a` — `zd1200-ct-net.sh`: stop `dhclient` by PID, never `pkill -f`. The most clearly
   justified single change in the branch.
2. `c247379` + `8c3e11b` — sample the emulator's own pid in the CPU guard, and arm the trip only
   for a KVM-accelerated guest.
3. `7dcfb23` — a card dump's own serial on every path (LXC and wizard, matching the CLI path).
4. `4371292` — an admin URL that works on 9.x and 10.x.
5. `a2817f7` — delete the dead `KERNEL_EXTRA` setting.
6. `fdecd88` — serialise the LXC container-id allocation.
7. `93a913e` — name a first Docker instance after its own checkout.
8. `86b9204` — make the Docker flow able to reach the guest's real address. Requires a decision:
   the helper move and the `GUEST_IP`-as-fallback change are one fix with two causes, and the
   move is what makes the Docker image depend on the file's new location.
9. The `patch-kernel.py` dhcp0/`tif0` fixes and `55-webs-header-limit.sh`, together with
   `patch-kernel-fixture-test.sh` / `check-patched-kernel-site.py` and the `OPTIONAL_PATCHES`
   safe-degradation machinery. The strongest technical work in the branch.
10. The harness isolation fixes and `run-suite.sh`, which are independent of every deliverable.
11. The genuinely stale documentation corrections.

**Not worth keeping** (correct but VM-only, or churn): the `mkosi/` tree, `build-vm-image.sh`, the
`scripts/container/vm/` helpers, `patches/15-zd-early-watchdog.sh`, `docs/history/`, the
`55-webs-header-limit` document churn, and the wizard and its server — which is ~2 251 lines of
new surface plus its tests, added without being asked for, and which `main` does not need.

**The two-way coupling is the thing to weigh in any decision**: the VM tree requires the wizard
tree (not in `main`), and the Docker image requires the VM tree until `Dockerfile:268-274`
changes. There is no clean cut that leaves both `docker build` and the LXC flow working without a
hand edit.

## 9. What this review did not do

* No attempt was made to build, boot or repair the VM deliverable, and no change has been carried
  onto `main`. This is a review, not a salvage.
* The firmware matrix was not exercised: no vendor firmware, no `AS_FIRMWARE_DIR`, no
  `AS_WEBS_CONF_DIR`, no lab hosts, no PVE. Every per-release claim in the branch — the nine-release
  dhcp0 coverage, the 9.x request-field margins, the TCG-vs-nested-KVM readiness numbers — is
  **unproven here** and needs a real matrix run to settle.
* The dhcp0 and `tif0` signatures were validated against a **synthesised** kernel fixture, not
  against real vendor kernels. A wrong reading of the real byte geometry would still pass that
  test, so the fixture is evidence for the patcher's internal consistency, not for the vendor
  layouts.

  **The dhcp0 half of this was settled afterwards against all nine real vendor kernels** (a later
  session, on the test host: each release's vendor image prepared the way the flows prepare it, and
  the ported patcher's own log read back):

  | release | dhcp0 shape matched | patcher |
  |---|---|---|
  | 9.9.1.0.52 | inlined | rc=0 |
  | 9.10.2.0.130 | inlined | rc=0 |
  | 9.13.3.0.164 | inlined | rc=0 |
  | 10.1.2.0.318 | inlined | rc=0 |
  | 10.2.1.0.236 | inlined | rc=0 |
  | 10.3.1.0.45 | standalone | rc=0 |
  | 10.4.1.0.272 | standalone | rc=0 |
  | 10.5.1.0.255 | standalone | rc=0 |
  | 10.5.1.0.282 | standalone | rc=0 |

  ```
  shapes seen:  standalone 4   inlined 5   NONE 0   BOTH-ERROR 0
  ```

  Every supported release matches exactly one shape and receives the fix. None matches both (which
  the `group` field treats as an error) and none matches neither (which would install with no crash
  fix). That confirms the branch's own coverage claim — "the two dhcp0 signatures between them cover
  all nine supported releases" — from the patcher's report on real vendor binaries rather than from
  the comment that asserted it. The `tif0` entry remains unproven, as does every per-release claim
  that needs a boot rather than a patch.
* Nothing was booted: no QEMU guest, no Docker container, no LXC container, no VM. Every
  claim about runtime behaviour is a code read, an offline harness, or a measurement recorded
  by the branch author.
* `wizard-e2e-lxc.sh` and `quick-docker-check.sh` were read but never run (they need the PVE host
  and lab fixtures).
* The mkosi build was not run: `mkosi` is absent on this host, there is no `/dev/kvm`, and this is
  an aarch64 workstation. Claims that depend on mkosi ≥26, on the foreign-architecture behaviour,
  or on a real VM boot are labelled UNPROVEN in this review, not wrong.
* `mkosi.build`'s architecture probe and the TCG-in-TCG readiness timings are the author's
  recorded lab measurements; `docs/PROXMOX.md` itself honestly qualifies the latter as a
  mechanism "not established".
* The guest-address symlink's survivability through `mkosi`'s `ExtraTrees` copy and through
  archive-based distribution is unverified.
* One workspace mishap of mine, recorded for honesty: a `git bisect` command I meant to run in a
  scratch worktree resolved its `cd` and ran in the main repository instead, leaving this
  worktree on a detached HEAD at `7a8090b` for about fifteen minutes. It was reverted to
  `vm-attempt-review`; no branch or commit was harmed, and the untracked review document
  survived the checkout. The bisect itself found nothing — the wizard failures I was chasing
  were my own resource contention (§3).
