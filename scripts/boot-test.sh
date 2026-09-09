#!/usr/bin/env bash
#
# boot-test.sh — boot the ZD1200 disk and monitor the guest serial console until
# it reaches a boot milestone.  A pass means the bootloader found its filesystem,
# loaded the kernel, and the guest's init got as far as the requested stage.
#
# Steps:
#   1. build the container image with build-container.sh --no-up (which also
#      prepares image/ from the firmware on first run);
#   2. prepare the synthetic CompactFlash + qcow2 overlay in an isolated state
#      dir, using the container's own apply-rootfs-patches.sh (never the running
#      container's state volume);
#   3. boot that overlay with a direct QEMU: KVM, a software IPMI BMC (the
#      firmware's CLI talks to a BMC over KSM), user-mode networking, and the
#      serial console written straight to a log file;
#   4. watch the log for the milestones grub -> kernel -> init -> controller ->
#      ready and stop at the requested one.
#
# Usage: ./scripts/boot-test.sh [options]
#   --firmware PATH   ZD1200 firmware .img (passed to build-container.sh; only
#                     needed when image/ has not been prepared yet)
#   --expect LEVEL    grub | kernel | init | controller | ready  (default: init)
#   --timeout SEC     boot deadline (default: 420)
#   --accel MODE      kvm | tcg | auto  (default: auto)
#   --net MODE        user | none       (default: user)
#   --state-dir DIR   state dir for the disks/log (default: ./.boot-test)
#   --no-build        skip step 1 (use the container image as-is)
#   --reuse           skip step 2 (reuse the disks already in the state dir)
#   -h | --help
#
# Exit status: 0 = reached the requested milestone, 1 = did not (timeout, QEMU
# exit, or a fatal guest error).  The serial log is always kept at
# <state-dir>/serial.log.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

expect="init"
timeout_s=420
accel="auto"
net_mode="user"
state_dir="$repo/.boot-test"
firmware=""
do_build=1
do_prepare=1

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

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --firmware) firmware="${2:?--firmware needs a path}"; shift 2 ;;
    --expect) expect="${2:?--expect needs a level}"; shift 2 ;;
    --timeout) timeout_s="${2:?--timeout needs seconds}"; shift 2 ;;
    --accel) accel="${2:?--accel needs a mode}"; shift 2 ;;
    --net) net_mode="${2:?--net needs a mode}"; shift 2 ;;
    --state-dir) state_dir="${2:?--state-dir needs a path}"; shift 2 ;;
    --no-build) do_build=0; shift ;;
    --reuse) do_prepare=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "boot-test: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die() { printf 'boot-test: error: %s\n' "$*" >&2; exit 1; }
say() { printf '== %s\n' "$*"; }

# --- validate arguments ------------------------------------------------------
expect_idx=-1
for i in "${!levels[@]}"; do
  [ "${levels[$i]}" = "$expect" ] && expect_idx=$i
done
[ "$expect_idx" -ge 0 ] || die "--expect must be one of: ${levels[*]}"
[[ "$timeout_s" =~ ^[0-9]+$ ]] && [ "$timeout_s" -ge 5 ] || die "--timeout must be an integer >= 5"
case "$net_mode" in user|none) ;; *) die "--net must be user or none" ;; esac
case "$accel" in kvm|tcg|auto) ;; *) die "--accel must be kvm, tcg or auto" ;; esac

for tool in docker qemu-system-i386 qemu-img; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done
docker info >/dev/null 2>&1 || die "cannot reach the Docker daemon"

# --- 1. build the container image (and image/ on first run) ------------------
if [ "$do_build" = 1 ]; then
  say "building the container image (build-container.sh --no-up)"
  if [ -n "$firmware" ]; then
    ./build-container.sh --no-up "$firmware"
  else
    ./build-container.sh --no-up
  fi
fi

image="local/zd1200-qemu"
docker image inspect "$image" >/dev/null 2>&1 || die "container image $image is missing (run without --no-build)"

# --- 2. prepare the disks in an isolated state dir ---------------------------
mkdir -p "$state_dir"
state_dir="$(cd "$state_dir" && pwd)"
serial="${ZD_SERIAL:-123456000789}"
mac1="${ZD_MAC1:-00:0c:e6:12:00:01}"
cert_dir="${ZD_SIGN_CERT_HOST:-$repo/image/signing-cert}"

if [ "$do_prepare" = 1 ]; then
  [ -f "$repo/image/rootfs.ext2" ] \
    || die "image/rootfs.ext2 missing — pass --firmware to build-container.sh"
  [ -d "$cert_dir" ] || die "signing cert dir missing: $cert_dir (set ZD_SIGN_CERT_HOST)"

  say "preparing the synthetic CF + qcow2 overlay in $state_dir (container)"
  docker run --rm --init \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e STATE_DIR=/var/lib/zd1200 \
    -e ZD_SERIAL="$serial" -e ZD_MAC1="$mac1" \
    -e ZD_MODEL=ZD1200 -e ZD_CUSTOMER=ruckus \
    -e ZD_SIGN_CERT_DIR=/opt/zd1200/signing-cert \
    -v "$repo/image:/opt/zd1200/image:ro" \
    -v "$cert_dir:/opt/zd1200/signing-cert:ro" \
    -v "$state_dir:/var/lib/zd1200" \
    --entrypoint /opt/zd1200/apply-rootfs-patches.sh \
    "$image"
fi

overlay="$state_dir/zd1200-vm.qcow2"
[ -f "$overlay" ] || die "no overlay at $overlay (drop --reuse or check the prep step)"

# The overlay is created inside the container, so its backing file is recorded
# with the container path (/var/lib/zd1200/synthetic-cf.img).  Rebase it to the
# host path of the same file; -u rewrites only the header (same backing data).
base_img="$state_dir/synthetic-cf.img"
[ -f "$base_img" ] || die "missing synthetic base disk: $base_img"
current_backing="$(qemu-img info --output=json "$overlay" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("backing-filename",""))')"
if [ "$current_backing" != "$base_img" ]; then
  say "rebasing overlay backing file: $current_backing -> $base_img"
  qemu-img rebase -u -f qcow2 -F raw -b "$base_img" "$overlay"
fi

# --- 3. boot it under QEMU ---------------------------------------------------
log="$state_dir/serial.log"
qemu_err="$state_dir/qemu.stderr.log"
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
}
trap cleanup EXIT INT TERM

say "booting $overlay under QEMU ($accel, net=$net_mode, IPMI BMC, serial -> $log)"
setsid qemu-system-i386 \
  -name zd1200-boot-test \
  -accel "$accel" \
  -machine pc \
  -cpu pentium3 \
  -m "${MEMORY_MB:-2048}" \
  -smp 1 \
  -device ich9-ahci,id=ahci \
  -drive "file=$overlay,format=qcow2,if=none,id=disk0,cache=writeback" \
  -device "ide-hd,drive=disk0,bus=ahci.0" \
  -snapshot \
  "${net_args[@]}" \
  -device ipmi-bmc-sim,id=bmc0 \
  -device isa-ipmi-kcs,id=isa0,bmc=bmc0 \
  -display none \
  -serial "file:$log" \
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
    exit 0
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
