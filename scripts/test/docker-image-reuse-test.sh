#!/usr/bin/env bash
#
# docker-image-reuse-test.sh — the Docker installer must re-prepare image/ when
# it is given different inputs, and a bare run must start an existing install.
#
# image/ is prepared once and then reused.  It used to be reused whatever
# firmware the run was given, so passing a different release silently installed
# whatever had been prepared first.  The installer now records what image/ was
# prepared from and re-prepares when that does not match.  Separately, a bare run
# is documented as "already prepared: start", but resolve_inputs() treated no
# input as an error, so it never got that far.
#
# The test drives install-zd1200-docker.sh with a stub `docker` on PATH, so it
# needs no daemon, image or real firmware.
#
# Usage: ./scripts/test/docker-image-reuse-test.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-imgreuse.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

[ -f "$BASE/install-zd1200-docker.sh" ] || fail "not found: $BASE/install-zd1200-docker.sh"

# --- a throwaway copy of what the installer needs ---------------------------
run="$TMP/repo"
mkdir -p "$run/scripts" "$run/docker" "$TMP/bin"
cp "$BASE/install-zd1200-docker.sh" "$run/"
cp "$BASE/scripts/install-common.sh" "$run/scripts/"
cp -r "$BASE/docker/." "$run/docker/"

# The stub stands in for docker: `info` must succeed, and a `run` (the
# prepare-vendor-image step) is what marks image/ as prepared.
cat > "$TMP/bin/docker" <<'STUB'
#!/bin/sh
case "$1" in
    run) mkdir -p image; : > image/rootfs.ext2 ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"

printf 'firmware A\n' > "$TMP/fwA.img"
printf 'firmware B\n' > "$TMP/fwB.img"

# install <args...>: run the installer in its own directory, print its output
install_out() { ( cd "$run" && ./install-zd1200-docker.sh "$@" ) 2>&1; }

# --- first run prepares and records its inputs ------------------------------
out="$(install_out --firmware "$TMP/fwA.img")" || fail "first run failed: $out"
grep -q 'Preparing image/ from' <<<"$out" || fail "first run did not prepare image/"
[ -f "$run/image/.prepared-from" ] || fail "the run did not record what image/ was prepared from"
pass "first run prepares image/ and records its inputs"

# --- the same firmware reuses it -------------------------------------------
out="$(install_out --firmware "$TMP/fwA.img")" || fail "repeat run failed: $out"
grep -q 'already prepared from' <<<"$out" || fail "the same firmware did not reuse image/: $out"
if grep -q 'Preparing image/ from' <<<"$out"; then fail "the same firmware re-prepared image/"; fi
pass "the same firmware reuses image/"

# --- a different firmware re-prepares --------------------------------------
out="$(install_out --firmware "$TMP/fwB.img")" || fail "different-firmware run failed: $out"
grep -q 'prepared from different inputs; re-preparing' <<<"$out" \
    || fail "a different firmware was not detected: $out"
pass "a different firmware re-prepares instead of reusing the old release"

# --- the same firmware at a different path is still the same image ---------
mkdir -p "$TMP/elsewhere"
cp "$TMP/fwB.img" "$TMP/elsewhere/renamed.img"
out="$(install_out --firmware "$TMP/elsewhere/renamed.img")" || fail "renamed-input run failed: $out"
grep -q 'already prepared from' <<<"$out" || fail "a renamed copy was treated as new inputs: $out"
pass "the same firmware at another path is recognised"

# --- an image/ with no record is re-prepared -------------------------------
rm -f "$run/image/.prepared-from"
out="$(install_out --firmware "$TMP/fwA.img")" || fail "no-stamp run failed: $out"
grep -q 'does not record what it was prepared from; re-preparing' <<<"$out" \
    || fail "a missing record did not trigger a re-prepare: $out"
pass "an image/ that does not record its inputs is re-prepared"

# --- a bare run starts the existing install --------------------------------
out="$(install_out)" || fail "a bare run failed: $out"
grep -q 'no input given' <<<"$out" || fail "a bare run did not reuse image/: $out"
if grep -q 'no input: pass a firmware' <<<"$out"; then fail "a bare run was rejected as having no input"; fi
pass "a bare run reuses the prepared image/ (the documented start)"

# --- --upgrade never re-prepares -------------------------------------------
out="$(install_out --upgrade)" || fail "--upgrade run failed: $out"
grep -q -- '--upgrade never re-prepares' <<<"$out" || fail "--upgrade re-prepared image/: $out"
pass "--upgrade never re-prepares"

# --- a bare run with no image/ says what a first run needs -----------------
rm -rf "$run/image"
if out="$(install_out)"; then fail "a bare first run was accepted"; fi
grep -q 'First run needs a ZD1200 firmware upgrade file' <<<"$out" \
    || fail "a bare first run did not explain what it needs: $out"
pass "a bare run with no image/ reports what a first run needs"

echo
echo "all docker image-reuse tests passed"
