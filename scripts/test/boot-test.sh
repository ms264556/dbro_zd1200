#!/usr/bin/env bash
#
# boot-test.sh — boot the ZD1200 disk and monitor the guest serial console until
# it reaches a boot milestone.  A pass means the bootloader found its filesystem,
# loaded the kernel, and the guest's init got as far as the requested stage.
#
# Steps:
#   1. build the container image with install-zd1200-docker.sh --no-up (which also
#      prepares image/ from the firmware on first run);
#   2. build/patch the synthetic CompactFlash disk in an isolated state dir,
#      using the container's own prepare-vm-disks.sh (never the running
#      container's state volume);
#   3. boot that disk with a direct QEMU: KVM, a software IPMI BMC (the
#      firmware's CLI talks to a BMC over KSM), user-mode networking, and the
#      serial console written straight to a log file;
#   4. watch the log for the milestones grub -> kernel -> init -> controller ->
#      ready and stop at the requested one.
#
# Usage: ./scripts/test/boot-test.sh [options]
#   --firmware PATH   ZD1200 firmware .img (passed to install-zd1200-docker.sh; only
#                     needed when image/ has not been prepared yet)
#   --expect LEVEL    grub | kernel | init | controller | ready  (default: init)
#   --timeout SEC     boot deadline (default: 420)
#   --accel MODE      kvm | tcg | auto  (default: auto)
#   --net MODE        user | none       (default: user)
#   --state-dir DIR   state dir for the disks/log (default: a fresh per-run
#                     ./.boot-test/run.XXXXXX, printed on start; --reuse
#                     requires an explicit --state-dir)
#   --no-build        skip step 1 (use the container image as-is)
#   --reuse           skip step 2 (reuse the disks already in the state dir)
#   --cpu MODEL       QEMU -cpu model (default: $CPU_MODEL or n270)
#   --machine SPEC    QEMU -machine spec (default: $MACHINE or pc; use
#                     pc,acpi=off for the single-CPU/uniprocessor model)
#   --smp N           QEMU -smp N (default: $SMP or 2; the vendor watchdog
#                     cadence assumes two vCPUs)
#   --reboot          after the milestone, reboot the guest over its serial
#                     console and require it to reach the milestone again
#                     (exercises the kernel machine_restart path)
#   -h | --help
#
# Exit status: 0 = reached the requested milestone, or the host cannot run this
# test at all (a tool is missing, the Docker daemon is unreachable, or the
# container image cannot execute on this host's architecture) — printed as a
# `skipped:` line, the same idiom as patch-matrix-test.sh.  1 = did not reach the
# milestone (timeout, QEMU exit, or a fatal guest error).
#
# The state dir holds the disks, the serial log, the QEMU stderr, the debugcon
# log and (with --reboot) the console socket.  With --state-dir it is the
# caller's, and the serial log is always kept at <state-dir>/serial.log exactly
# as before; nothing is ever removed from it.  Without --state-dir each run gets a
# fresh $repo/.boot-test/run.XXXXXX of its own, printed as `== state dir: ...`, so
# two concurrent runs cannot truncate or grep each other's serial log.
#
# What a per-run dir keeps, and what it drops: the synthetic CF disk is the large
# artefact (measured 1919.5 MiB apparent, 418 MiB allocated for a sparse build,
# ~1.9 GiB once copied); the serial/QEMU/debugcon/console-reboot logs are
# kilobytes.  A run that PASSES therefore removes only the disk — after the PASS
# line has named <dir>/serial.log — and keeps the logs, so the printed path is
# still there to read.  A run that FAILS or is interrupted (INT/TERM) exits with
# prune_run_dir unset and keeps the disk as well, so a failure is never left with
# nothing to inspect.  Set ZD_BOOT_TEST_KEEP_RUN_DIR=1 to keep a successful run's
# disk too — which is what you need if you intend to --reuse that run's disk,
# since the default run drops it.
# --reuse means "the disks already prepared", so it has no per-run dir to mean and
# now requires an explicit --state-dir.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo"

expect="init"
timeout_s=420
accel="auto"
net_mode="user"
state_dir=""            # --state-dir; an empty value means a fresh per-run dir
state_dir_given=0
per_run_state_dir=0
prune_run_dir=0         # set on the success paths; drops the per-run disk on exit
firmware=""
do_build=1
do_prepare=1
cpu="${CPU_MODEL:-n270}"
# ACPI on so the guest enumerates both vCPUs; see the -machine comment in
# scripts/container/launch-vm.sh.  Override with MACHINE=pc,acpi=off.
machine="${MACHINE:-pc}"
smp="${SMP:-2}"
do_reboot=0

# Milestones in order.  The strings are what the guest actually prints (see a
# known-good boot: GRUB's menu line, GRUB's kernel-load line, the init script
# mounting /writable, the controller init script, and the READY marker the
# container healthcheck also greps).
levels=(grub kernel init controller ready)
patterns=(
  "Booting 'Normal bootup from system image"
  "[Linux-bzImage,"
  "/dev/sda4 on /writable type ext2"
  "Initializing ZoneDirector..."
  "System go into READY status."
)
# Guest-side failures that mean the boot is over.
fatal_patterns=(
  "Kernel panic"
  "No bootable device"
  "VFS: Cannot open root device"
  "GRUB loading, please wait... Error"
  "Error 1[0-9]: "
)

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --firmware) firmware="${2:?--firmware needs a path}"; shift 2 ;;
    --expect) expect="${2:?--expect needs a level}"; shift 2 ;;
    --timeout) timeout_s="${2:?--timeout needs seconds}"; shift 2 ;;
    --accel) accel="${2:?--accel needs a mode}"; shift 2 ;;
    --net) net_mode="${2:?--net needs a mode}"; shift 2 ;;
    --state-dir) state_dir="${2:?--state-dir needs a path}"; state_dir_given=1; shift 2 ;;
    --no-build) do_build=0; shift ;;
    --reuse) do_prepare=0; shift ;;
    --cpu) cpu="${2:?--cpu needs a model}"; shift 2 ;;
    --machine) machine="${2:?--machine needs a spec}"; shift 2 ;;
    --smp) smp="${2:?--smp needs a count}"; shift 2 ;;
    --reboot) do_reboot=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "boot-test: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die() { printf 'boot-test: error: %s\n' "$*" >&2; exit 1; }
say() { printf '== %s\n' "$*"; }
skip() { printf 'skipped: %s\n' "$*"; exit 0; }

# --- validate arguments ------------------------------------------------------
expect_idx=-1
for i in "${!levels[@]}"; do
  [ "${levels[$i]}" = "$expect" ] && expect_idx=$i
done
[ "$expect_idx" -ge 0 ] || die "--expect must be one of: ${levels[*]}"
[[ "$timeout_s" =~ ^[0-9]+$ ]] && [ "$timeout_s" -ge 5 ] || die "--timeout must be an integer >= 5"
case "$net_mode" in user|none) ;; *) die "--net must be user or none" ;; esac
case "$accel" in kvm|tcg|auto) ;; *) die "--accel must be kvm, tcg or auto" ;; esac

# The default state dir is per-run, so "reuse the disks already in the state dir"
# has no directory to mean unless the caller names one.  Say so loudly rather
# than silently switching back to a shared dir that would reintroduce the defect.
if [ "$do_prepare" = 0 ] && [ "$state_dir_given" = 0 ]; then
  die "--reuse needs an explicit --state-dir: the default state directory is now per-run. Pass --state-dir to reuse a cached disk (a run prints its own)."
fi

# Missing tooling or an unreachable daemon is this workstation's environment, not
# a boot failure: say so visibly and leave the suite green.  This is the project's
# skip idiom (patch-matrix-test.sh:43-47, wizard-e2e-lxc.sh:99-115).
for tool in docker qemu-system-i386; do
  command -v "$tool" >/dev/null 2>&1 || skip "$tool not found on PATH"
done
docker info >/dev/null 2>&1 || skip "cannot reach the Docker daemon"

# --- 1. build the container image (and image/ on first run) ------------------
if [ "$do_build" = 1 ]; then
  say "building the container image (install-zd1200-docker.sh --no-up)"
  # The Dockerfile carries a linux/386 stage (docker/Dockerfile:48) that compiles
  # the guest's i386 helpers, so building the image needs a host that can execute
  # i386 containers.  On a host whose Docker has no i386 binfmt/emulation handler
  # — this aarch64 workstation — that stage dies with `exec /bin/sh: no such file
  # or directory` / `exec format error` and the whole build fails for an
  # environment reason, not because the boot test found anything wrong.  Keep the
  # build output so that one signature can be told apart from a real build
  # failure; every other failure still dies below.
  build_log="$(mktemp "${TMPDIR:-/tmp}/zd1200-boot-build.XXXXXX")"
  build_rc=0
  if [ -n "$firmware" ]; then
    ./install-zd1200-docker.sh --no-up "$firmware" 2>&1 | tee "$build_log" || build_rc=$?
  else
    ./install-zd1200-docker.sh --no-up 2>&1 | tee "$build_log" || build_rc=$?
  fi
  if [ "$build_rc" != 0 ]; then
    if grep -qE 'exec /bin/sh: (no such file or directory|exec format error)' "$build_log"; then
      rm -f "$build_log"
      skip "this $(uname -m) host cannot execute the linux/386 (i386) stage the container image is built with — Docker needs an i386 binfmt/emulation handler (the build died on 'exec /bin/sh: no such file or directory')"
    fi
    rm -f "$build_log"
    die "install-zd1200-docker.sh --no-up failed (exit $build_rc); see the output above"
  fi
  rm -f "$build_log"
fi

image="local/zd1200-qemu"
docker image inspect "$image" >/dev/null 2>&1 || die "container image $image is missing (run without --no-build)"

# --- 2. prepare the disks in an isolated state dir ---------------------------
# With no --state-dir each run gets a directory of its own; the fixed
# $repo/.boot-test default let two concurrent runs truncate (: > "$log") and
# grep each other's serial log, so one could PASS on the other's guest.
if [ "$state_dir_given" = 0 ]; then
  mkdir -p "$repo/.boot-test" || die "cannot create $repo/.boot-test"
  state_dir="$(mktemp -d "$repo/.boot-test/run.XXXXXX")" \
    || die "cannot create a per-run state dir under $repo/.boot-test"
  per_run_state_dir=1
  say "state dir: $state_dir (per-run)"
fi
mkdir -p "$state_dir"
state_dir="$(cd "$state_dir" && pwd)"
serial="${ZD_SERIAL:-123456000789}"
mac1="${ZD_MAC1:-00:0c:e6:12:00:01}"
cert_dir="${ZD_SIGN_CERT_HOST:-$repo/image/signing-cert}"

if [ "$do_prepare" = 1 ]; then
  [ -f "$repo/image/rootfs.ext2" ] \
    || die "image/rootfs.ext2 missing — pass --firmware to install-zd1200-docker.sh"
  [ -d "$cert_dir" ] || die "signing cert dir missing: $cert_dir (set ZD_SIGN_CERT_HOST)"

  say "building/patching the synthetic CF disk in $state_dir (container)"
  # Optional login seed: build-synthetic-cf.py seeds /writable/etc/config from
  # dropbear-provision/{passwd,shadow} when present (a gitignored local input).
  # Mounted read-only so the guest console/CLI can be logged into (--reboot).
  seed_args=()
  [ -d "$repo/dropbear-provision" ] \
    && seed_args=( -v "$repo/dropbear-provision:/opt/zd1200/dropbear-provision:ro" )
  docker run --rm --init \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e STATE_DIR=/var/lib/zd1200 \
    -e ZD_SERIAL="$serial" -e ZD_MAC1="$mac1" \
    -e ZD_MODEL=ZD1200 -e ZD_CUSTOMER=ruckus \
    -e ZD_SIGN_CERT_DIR=/opt/zd1200/signing-cert \
    -v "$repo/image:/opt/zd1200/image:ro" \
    -v "$cert_dir:/opt/zd1200/signing-cert:ro" \
    "${seed_args[@]}" \
    -v "$state_dir:/var/lib/zd1200" \
    --entrypoint /opt/zd1200/scripts/container/prepare-vm-disks.sh \
    "$image"
fi

# Flat model: the synthetic CF image IS the live disk (no qcow2 overlay).
disk_img="$state_dir/synthetic-cf.img"
[ -f "$disk_img" ] || die "missing synthetic CF disk: $disk_img (drop --reuse or check the prep step)"

# --- 3. boot it under QEMU ---------------------------------------------------
log="$state_dir/serial.log"
qemu_err="$state_dir/qemu.stderr.log"
# SeaBIOS writes its early debug output to the QEMU debug console port 0x402.
# Nothing claims that port by default, so those writes are discarded; capture
# them next to the serial log so firmware-level bring-up failures are visible.
debugcon_log="$state_dir/debugcon.log"
: > "$log"

case "$accel" in
  auto) if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then accel=kvm; else accel=tcg; fi ;;
esac

net_args=()
[ "$net_mode" = user ] && net_args=( -net user -net nic,model=igb,macaddr=52:54:00:12:00:01 )

qemu_pid=""
cleanup() {
  trap - EXIT INT TERM
  if [[ "$qemu_pid" =~ ^[0-9]+$ ]] && (( qemu_pid > 1 )); then
    kill -TERM -- "-$qemu_pid" 2>/dev/null || kill -TERM "$qemu_pid" 2>/dev/null || true
    for _ in {1..20}; do kill -0 "$qemu_pid" 2>/dev/null || break; sleep 0.1; done
    kill -KILL -- "-$qemu_pid" 2>/dev/null || kill -KILL "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
  fi
  # Drop the expensive thing, keep the evidence.  A per-run dir's synthetic CF
  # disk is the big artefact (measured 1919.5 MiB apparent, 418 MiB allocated for
  # a sparse build, ~1.9 GiB once copied); the logs are kilobytes.  A successful
  # run therefore removes only the disk, so the `serial log:` path it just printed
  # still exists.  A failed or interrupted run reaches here with prune_run_dir=0
  # and keeps everything.  ZD_BOOT_TEST_KEEP_RUN_DIR=1 keeps the disk too.
  if [ "$per_run_state_dir" = 1 ] && [ "$prune_run_dir" = 1 ] \
     && [ "${ZD_BOOT_TEST_KEEP_RUN_DIR:-0}" != 1 ]; then
    rm -f "$disk_img"
  fi
}
trap cleanup EXIT INT TERM

# --reboot needs an input path to the guest console, so the serial is a socket
# chardev (with the same logfile) instead of a write-only file.  wait=off keeps
# QEMU from blocking until a client attaches.
console_sock=""
serial_args=( -serial "file:$log" )
if [ "$do_reboot" = 1 ]; then
  console_sock="$state_dir/console.sock"
  rm -f "$console_sock"
  serial_args=( -chardev "socket,id=con0,path=$console_sock,server=on,wait=off,logfile=$log,logappend=on"
                -serial chardev:con0 )
fi

say "booting $disk_img under QEMU ($accel, net=$net_mode, machine=$machine, cpu=$cpu, smp=$smp, IPMI BMC, serial -> $log)"
setsid qemu-system-i386 \
  -name zd1200-boot-test \
  -accel "$accel" \
  -machine "$machine" \
  -cpu "$cpu" \
  -m "${MEMORY_MB:-2048}" \
  -smp "$smp" \
  -device ich9-ahci,id=ahci \
  -drive "file=$disk_img,format=raw,if=none,id=disk0,cache=writeback" \
  -device "ide-hd,drive=disk0,bus=ahci.0" \
  -snapshot \
  "${net_args[@]}" \
  -device ipmi-bmc-sim,id=bmc0 \
  -device isa-ipmi-kcs,id=isa0,bmc=bmc0 \
  -chardev "file,id=dbgcon0,path=$debugcon_log" \
  -device isa-debugcon,iobase=0x402,chardev=dbgcon0 \
  -display none \
  "${serial_args[@]}" \
  >"$qemu_err" 2>&1 </dev/null &
qemu_pid=$!

# --- 4. monitor the serial console -------------------------------------------
declare -A at
start=$SECONDS
target="${levels[$expect_idx]}"
say "monitoring for '$target' (timeout ${timeout_s}s)"
while :; do
  elapsed=$((SECONDS - start))
  for i in "${!levels[@]}"; do
    [ -n "${at[$i]:-}" ] && continue
    if grep -qF -- "${patterns[$i]}" "$log" 2>/dev/null; then
      at[$i]=$elapsed
      printf '   [%3ss] %-10s %s\n' "$elapsed" "${levels[$i]}" "${patterns[$i]}"
    fi
  done
  if [ -n "${at[$expect_idx]:-}" ]; then
    say "PASS — reached '$target' after ${at[$expect_idx]}s"
    printf '   serial log: %s\n' "$log"
    [ "$do_reboot" = 0 ] && { prune_run_dir=1; exit 0; }

    # Reboot the guest from its own console and require it to reach the target
    # again.  This is what the kernel's machine_restart path drives: a broken
    # machine_restart leaves the guest hung, so the second boot never happens.
    say "rebooting the guest over its serial console (machine_restart)"
    if ! python3 "$repo/scripts/test/console-reboot.py" "$console_sock" \
         >"$state_dir/console-reboot.log" 2>&1; then
      say "FAIL — could not drive the guest console to reboot"
      tail -40 "$state_dir/console-reboot.log" >&2
      exit 1
    fi
    before=$(grep -cF -- "${patterns[$expect_idx]}" "$log" 2>/dev/null || true)
    reboot_start=$SECONDS
    say "waiting for the guest to reboot and reach '$target' again"
    while :; do
      now=$(grep -cF -- "${patterns[$expect_idx]}" "$log" 2>/dev/null || true)
      if [ "${now:-0}" -gt "${before:-0}" ]; then
        say "PASS — guest rebooted and reached '$target' again after $((SECONDS - reboot_start))s"
        prune_run_dir=1
        exit 0
      fi
      if ! kill -0 "$qemu_pid" 2>/dev/null; then
        say "FAIL — QEMU exited during the reboot (stderr: $qemu_err)"
        tail -40 "$log" >&2
        exit 1
      fi
      if (( SECONDS - reboot_start >= timeout_s )); then
        say "FAIL — guest did not come back after the reboot within ${timeout_s}s"
        tail -40 "$log" >&2
        exit 1
      fi
      sleep 0.5
    done
  fi
  for fatal in "${fatal_patterns[@]}"; do
    if grep -qE -- "$fatal" "$log" 2>/dev/null; then
      say "FAIL — guest hit a fatal error: $fatal"
      tail -40 "$log" >&2
      exit 1
    fi
  done
  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    say "FAIL — QEMU exited before '$target' (stderr: $qemu_err)"
    tail -40 "$log" >&2
    exit 1
  fi
  if (( elapsed >= timeout_s )); then
    say "FAIL — timed out after ${timeout_s}s before '$target'"
    tail -40 "$log" >&2
    exit 1
  fi
  sleep 0.5
done
