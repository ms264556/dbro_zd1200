#!/usr/bin/env bash
#
# webs-header-limit-test.sh — 55-webs-header-limit.sh must give a webs.conf that
# lacks the request-field limit exactly the vendor's two directives, and must
# leave everything else alone.
#
# On 10.1.2.0.318 and 10.3.1.0.45 /bin/webs.conf sets no LimitRequestFields, so
# Appweb's compiled-in default of 20 request fields applies: a request carrying
# 21 or more header fields is aborted before the EJS handler runs and the
# connection is closed with no response at all.  Every AJAX call the setup wizard
# makes carries 21, so its Finish chain is dead on those two releases (measured
# live: the same request at 20 fields -> 200 + <ajax-response>, at 21 -> TLS
# closed, SSL_read: unexpected eof).  10.2.1.0.236 and 10.4.1.0.272 set
# `LimitRequestFields 40` themselves.
#
# This drives the real patch script against fixture root filesystems (an ext2
# partition carrying /bin/webs.conf, placed in a flat disk at the sector patch-lib
# uses for hda2) and asserts:
#
#   (a) a 10.1.2.0.318-shaped config: the two lines land immediately after
#       LimitRequests and before ForbidEjsDirs, they are the ONLY difference,
#       the mode and ownership survive, and a second run changes nothing;
#   (b) a 10.2.1.0.236-shaped config (LimitRequestFields 40) and one carrying a
#       release's own different value: byte-identical afterwards, with a skip
#       report -- the patch never overwrites a value a release set itself;
#   (c) /bin/webs.conf absent: exit 0, nothing created on the root;
#   (d) unrecognised input -- a truncated config with no LimitRequests anchor,
#       an anchor not followed by ForbidEjsDirs, and a non-text (NUL-carrying)
#       config: exit 0 and byte-identical, because a patch that cannot place its
#       change must be a no-op for that root rather than abort provisioning.
#
# The fixtures are synthesised: the vendor's webs.conf is vendor material and is
# not in this repository.  AS_WEBS_CONF_DIR=<dir> runs the same harness over the
# real files, named <release>.webs.conf, for every root the documented matrix
# covers -- the nine releases plus the 10.5.1.0.240 CompactFlash-dump root, which
# carries its own /bin/webs.conf -- and pins each input to the sha256 that root's
# own /bin/webs.conf carries and each output to the hash of the same transform
# over that real file.  Three of the ten gain exactly the two lines
# (10.1.2.0.318, 10.3.1.0.45, 9.10.2.0.130); five come out byte-identical
# because they already set the directive (10.2.1.0.236, 10.4.1.0.272,
# 10.5.1.0.240/255/282), and 10.3.1.0.45 comes out equal to the 10.2.1/10.4.1
# hash because its ThreadLimit is already the control's 60; the two remaining
# 9.x roots (9.9.1.0.52, 9.13.3.0.164) come out byte-identical with the shape
# refusal, because their config has no ForbidEjsDirs after LimitRequests and the
# patch does not guess an insertion point.  That refusal is a MEASURED-SAFE
# outcome, not an unknown: on fresh unpatched 9.9.1.0.52 and 9.13.3.0.164
# factory guests the threshold is the same 21 request fields as on 10.x (20 ->
# 200 with the full <ajax-response>, 21 -> `000 0` + SSL_read unexpected eof),
# the 9.x wizard page's own AJAX carries 20 fields -- all five page-load POSTs
# at 20 fields, every one completing, against 21 on the 10.x page -- and the
# guest wizard's later calls, Finish included, use the same Prototype/rico path
# at the same four non-default headers (a code read, not a click-through; the
# margin is one field).  The 9.10.2.0.130 control, patched, answers to 40 and
# closes at 41 (measured on a lab guest; not reproduced here).  Where AS_WEBS_CONF_DIR is set, this is
# the test that would catch a widened anchor changing those two roots without a
# demonstrated defect; the repository carries no vendor configs, so a plain
# `run-suite.sh` run marks that half `partial:` rather than pretending to have
# checked it.  `partial:` is the runner's third classification
# (scripts/test/run-suite.sh): the test ran and evaluated its synthetic fixtures,
# but not the real vendor config files.
#
# AS_WEBS_OUT=<dir> keeps the real-input before/after files and diffs there.
#
# Usage: ./scripts/test/webs-header-limit-test.sh
#        AS_WEBS_CONF_DIR=/path/to/dir ./scripts/test/webs-header-limit-test.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATCH="$REPO/scripts/container/patches/55-webs-header-limit.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zd-webshdr.XXXXXX")"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }
# partial: ran, but only against what this test carries itself.  The runner
# counts a partial test as RAN (scripts/test/run-suite.sh's marker contract), so
# a test that evaluated its synthetic fixtures is not recorded as having
# evaluated nothing, while the real vendor files it could not carry stay visible.
partial() { printf 'partial: %s\n' "$*"; }

for tool in mke2fs debugfs cmp diff; do
    command -v "$tool" >/dev/null 2>&1 \
        || { echo "SKIP: $tool not found (e2fsprogs and diffutils are required)" >&2; exit 0; }
done
[ -f "$PATCH" ] || fail "missing $PATCH"

ALIGN=512
START=84568                 # the flat disk's hda2 sector, as patch-lib defines it
SECTORS=32768               # 16 MiB, enough for the fixture root
TARGET=/bin/webs.conf
FIELDS_LINE='LimitRequestFields 40'
FIELD_SIZE_LINE='LimitRequestFieldSize 4096'

# --- the fixture roots -------------------------------------------------------
# build_disk <conf|NONE> <disk> [mode]: an ext2 root with /bin/webs.conf (or an
# empty /bin), written into a flat disk at the hda2 sector the patch extracts.
build_disk() {
    local conf="$1" disk="$2" mode="${3:-0640}"
    local stage="$TMP/stage.$$"
    rm -rf "$stage"; mkdir -p "$stage/bin"
    if [ "$conf" != NONE ]; then
        cp "$conf" "$stage/bin/webs.conf"
        chmod "$mode" "$stage/bin/webs.conf"
    fi
    ext2_disk_from_stage "$stage" "$disk" "$START" "$SECTORS" "$ALIGN" || fail "mke2fs failed"
    rm -rf "$stage"
}

read_conf() { # <disk> <out>: nonzero when $TARGET is not on the root
    local part="$TMP/read.$$.img"
    part_image "$1" "$part" "$START" "$SECTORS" "$ALIGN"
    rm -f "$2"
    fs_dump "$part" "$TARGET" "$2"
    rm -f "$part"
    [ -f "$2" ]
}

conf_meta() { # <disk> -> "type mode uid gid" (empty when absent)
    local part="$TMP/meta.$$.img"
    part_image "$1" "$part" "$START" "$SECTORS" "$ALIGN"
    debugfs -R "stat $TARGET" "$part" 2>/dev/null \
        | awk '{ for (i = 1; i <= NF; i++) {
                     if ($i == "Type:")  t = $(i+1)
                     else if ($i == "Mode:")  m = $(i+1)
                     else if ($i == "User:")  u = $(i+1)
                     else if ($i == "Group:") g = $(i+1)
                 }} END { if (t != "") print t, m, u, g }'
    rm -f "$part"
}

run_patch() { # <disk> <workdir> <log>
    ZD_PATCH_PARTS="hda2|$START|$SECTORS" QCOW="$1" WORK="$2" \
        bash "$PATCH" > "$3" 2>&1
}

# diff_counts <before> <after> -> "added removed"
diff_counts() {
    local d
    d="$(diff "$1" "$2" || true)"
    printf '%s %s' \
        "$(printf '%s\n' "$d" | grep -c '^> ' || true)" \
        "$(printf '%s\n' "$d" | grep -c '^< ' || true)"
}

# expect_unchanged <conf|NONE> <label> <log-pattern>: run the patch over a root
# built from <conf> and require exit 0, no change to the file, and the report.
expect_unchanged() {
    local conf="$1" label="$2" pattern="$3"
    local disk="$TMP/$label.disk.raw" work="$TMP/$label.work" log="$TMP/$label.log"
    build_disk "$conf" "$disk"
    run_patch "$disk" "$work" "$log" || fail "$label: the patch exited non-zero:
$(cat "$log")"
    if [ "$conf" = NONE ]; then
        if read_conf "$disk" "$TMP/$label.after"; then
            fail "$label: the patch created $TARGET on a root that had none"
        fi
    else
        read_conf "$disk" "$TMP/$label.after" || fail "$label: $TARGET vanished from the root"
        cmp -s "$conf" "$TMP/$label.after" || fail "$label: the config changed, which it must not:
$(diff -u "$conf" "$TMP/$label.after" || true)"
    fi
    grep -q "$pattern" "$log" || fail "$label: no '$pattern' in the report:
$(cat "$log")"
}

# --- (a) a 10.1.2.0.318-shaped config ----------------------------------------
# The head is the broken release's own (ThreadLimit 10, no directive); the tail
# carries a decoy LimitRequestBody, which must not be mistaken for the anchor.
CONF_A="$TMP/broken-318.webs.conf"
cat > "$CONF_A" <<'EOF'
DocumentRoot "../web"
# ErrorLog pathName[:level][[,moduleName[:level]]...][.maxSize]
ErrorLog /var/log/webs-error.log:2.1
LogLevel 0
LogRotate 2048
StartThreads 10
ThreadLimit 10
LimitClients 500
LimitChunkSize 500000
LimitRequests 500
ForbidEjsDirs /help;/uploaded

<if CHUNK_MODULE>
    LoadModule chunkFilter mod_chunk
    AddOutputFilter chunkFilter
</if>

AddHandler dirHandler
LimitRequestBody 200000000
LimitUploadSize 200000000
EOF

DISK_A="$TMP/a.disk.raw"
build_disk "$CONF_A" "$DISK_A" 0640
meta_before="$(conf_meta "$DISK_A")"
run_patch "$DISK_A" "$TMP/a.work" "$TMP/a.log" || fail "(a) the patch exited non-zero:
$(cat "$TMP/a.log")"
grep -q "LimitRequestFields 40 and LimitRequestFieldSize 4096 added" "$TMP/a.log" \
    || fail "(a) the patch did not report adding the pair:
$(cat "$TMP/a.log")"
read_conf "$DISK_A" "$TMP/a.after" || fail "(a) no $TARGET on the patched root"
cmp -s "$CONF_A" "$TMP/a.after" && fail "(a) the config was not changed at all"

# The anchor: the pair must sit immediately after LimitRequests and before
# ForbidEjsDirs, which is where the control releases carry them.
anchor="$(grep -nE '^LimitRequests([[:space:]]|$)' "$CONF_A" | cut -d: -f1)"
[ "$anchor" = 10 ] || fail "(a) the fixture anchor moved to line $anchor"
[ "$(sed -n "$((anchor + 1))p" "$TMP/a.after")" = "$FIELDS_LINE" ] \
    || fail "(a) $FIELDS_LINE is not on the line after LimitRequests"
[ "$(sed -n "$((anchor + 2))p" "$TMP/a.after")" = "$FIELD_SIZE_LINE" ] \
    || fail "(a) $FIELD_SIZE_LINE is not on the second line after LimitRequests"
[ "$(sed -n "$((anchor + 3))p" "$TMP/a.after")" = 'ForbidEjsDirs /help;/uploaded' ] \
    || fail "(a) ForbidEjsDirs no longer follows the pair"
[ "$(sed -n "$((anchor - 1))p" "$TMP/a.after")" = 'LimitChunkSize 500000' ] \
    || fail "(a) the line before LimitRequests moved"
pass "(a) the two directives land between LimitRequests and ForbidEjsDirs"

# ... and they are the only difference: two added lines, nothing removed or
# changed.  ThreadLimit 10 (the broken release's own value) must still be there.
[ "$(diff_counts "$CONF_A" "$TMP/a.after")" = "2 0" ] \
    || fail "(a) the diff is not exactly two added lines: $(diff_counts "$CONF_A" "$TMP/a.after")"
[ "$(printf '%s\n' "$(diff "$CONF_A" "$TMP/a.after" | grep '^> ' | sed 's/^> //')")" \
    = "$(printf '%s\n%s' "$FIELDS_LINE" "$FIELD_SIZE_LINE")" ] \
    || fail "(a) the added lines are not the expected pair:
$(diff -u "$CONF_A" "$TMP/a.after" || true)"
grep -qxF 'ThreadLimit 10' "$TMP/a.after" || fail "(a) ThreadLimit was touched"
pass "(a) the two added lines are the only difference; ThreadLimit is untouched"

case "$meta_before" in
    "regular 0640 "*) ;;
    *) fail "(a) the fixture is not the 0640 regular file it should be: '$meta_before'" ;;
esac
[ "$(conf_meta "$DISK_A")" = "$meta_before" ] \
    || fail "(a) mode/ownership changed: '$meta_before' -> '$(conf_meta "$DISK_A")'"
pass "(a) the file's mode (0640) and ownership are preserved"

# A second run over the same disk: nothing to do, nothing written.
cp "$TMP/a.after" "$TMP/a.first"
run_patch "$DISK_A" "$TMP/a.work2" "$TMP/a.log2" || fail "(a) the second run exited non-zero:
$(cat "$TMP/a.log2")"
read_conf "$DISK_A" "$TMP/a.after2" || fail "(a) no $TARGET after the second run"
cmp -s "$TMP/a.first" "$TMP/a.after2" || fail "(a) the second run changed the file"
grep -q 'already sets LimitRequestFields; left byte-for-byte unchanged' "$TMP/a.log2" \
    || fail "(a) the second run did not report the skip:
$(cat "$TMP/a.log2")"
grep -q 'nothing written' "$TMP/a.log2" \
    || fail "(a) the second run reported a write:
$(cat "$TMP/a.log2")"
pass "(a) a second run is a no-op and reports the skip"

# --- (b) a config that already carries the limit -----------------------------
# 10.2.1.0.236/10.4.1.0.272: exactly the control release's head.
CONF_B="$TMP/control-236.webs.conf"
cat > "$CONF_B" <<'EOF'
DocumentRoot "../web"
ErrorLog /var/log/webs-error.log:2.1
LogLevel 0
LogRotate 2048
StartThreads 10
ThreadLimit 60
LimitClients 500
LimitChunkSize 500000
LimitRequests 500
LimitRequestFields 40
LimitRequestFieldSize 4096
ForbidEjsDirs /help;/uploaded
EOF
build_disk "$CONF_B" "$TMP/b.disk.raw" 0640
run_patch "$TMP/b.disk.raw" "$TMP/b.work" "$TMP/b.log" \
    || fail "(b) the patch exited non-zero:
$(cat "$TMP/b.log")"
read_conf "$TMP/b.disk.raw" "$TMP/b.after" || fail "(b) no $TARGET on the root"
cmp -s "$CONF_B" "$TMP/b.after" || fail "(b) a config that already sets the limit was changed:
$(diff -u "$CONF_B" "$TMP/b.after" || true)"
sha_before="$(sha256sum < "$CONF_B" | awk '{print $1}')"
sha_after="$(sha256sum < "$TMP/b.after" | awk '{print $1}')"
[ "$sha_before" = "$sha_after" ] || fail "(b) the file is not byte-identical"
grep -q 'already sets LimitRequestFields; left byte-for-byte unchanged' "$TMP/b.log" \
    || fail "(b) the skip was not reported:
$(cat "$TMP/b.log")"
pass "(b) LimitRequestFields 40 -> byte-identical, skip reported"

# A release's own *different* value is left alone too: the patch must never
# overwrite a value a release set itself.
CONF_B2="$TMP/own-value.webs.conf"
sed 's/^LimitRequestFields 40$/LimitRequestFields 12/' "$CONF_B" > "$CONF_B2"
grep -qxF 'LimitRequestFields 12' "$CONF_B2" || fail "(b) the fixture sed did not apply"
build_disk "$CONF_B2" "$TMP/b2.disk.raw" 0640
run_patch "$TMP/b2.disk.raw" "$TMP/b2.work" "$TMP/b2.log" \
    || fail "(b2) the patch exited non-zero:
$(cat "$TMP/b2.log")"
read_conf "$TMP/b2.disk.raw" "$TMP/b2.after" || fail "(b2) no $TARGET on the root"
cmp -s "$CONF_B2" "$TMP/b2.after" || fail "(b2) LimitRequestFields 12 was overwritten:
$(diff -u "$CONF_B2" "$TMP/b2.after" || true)"
pass "(b2) a release's own LimitRequestFields value is never overwritten"

# --- (c) no /bin/webs.conf ----------------------------------------------------
build_disk NONE "$TMP/c.disk.raw"
run_patch "$TMP/c.disk.raw" "$TMP/c.work" "$TMP/c.log" || fail "(c) the patch exited non-zero with no $TARGET:
$(cat "$TMP/c.log")"
if read_conf "$TMP/c.disk.raw" "$TMP/c.after"; then
    fail "(c) the patch created $TARGET"
fi
grep -q "no $TARGET in this root" "$TMP/c.log" || fail "(c) the absence was not reported:
$(cat "$TMP/c.log")"
pass "(c) a root with no $TARGET exits 0 and stays untouched"

# --- (d) input the patch does not recognise ----------------------------------
# d1: a truncated config -- the head only, so there is no LimitRequests anchor.
head -n 5 "$CONF_A" > "$TMP/truncated.webs.conf"
expect_unchanged "$TMP/truncated.webs.conf" d1 'no single LimitRequests line'
pass "(d1) a truncated config (no LimitRequests anchor) is left untouched, exit 0"

# d2: the anchor is there but what follows it is not ForbidEjsDirs, so there is
# no place the vendor carried the pair -- the patch must not guess one.
sed 's/^ForbidEjsDirs .*$/SomethingElse 1/' "$CONF_A" > "$TMP/no-anchor-neighbour.webs.conf"
expect_unchanged "$TMP/no-anchor-neighbour.webs.conf" d2 'is not ForbidEjsDirs'
pass "(d2) an anchor with no ForbidEjsDirs after it is left untouched, exit 0"

# d3: not the plain text config the vendor's own runtime sed edits.
printf 'DocumentRoot "../web"\nLimitRequests 500\n\0binary\nForbidEjsDirs /help;/uploaded\n' \
    > "$TMP/not-text.webs.conf"
expect_unchanged "$TMP/not-text.webs.conf" d3 'not plain text'
pass "(d3) a non-text config is left untouched, exit 0"

# --- the real releases' own config files, when they are available ------------
# <release>.webs.conf for every root this project's documented matrix covers:
# the nine releases plus the 10.5.1.0.240 CompactFlash-dump root, which carries
# its own /bin/webs.conf.  Each input is pinned to the sha256 its own rootfs
# carries, and each expected output is pinned to the hash of the same transform
# run over the real file.  Three roots must gain exactly the two lines, five
# must come out byte-identical because they already set the directive, and two
# must come out byte-identical because their config has no ForbidEjsDirs after
# LimitRequests -- the shape the patch refuses to guess an insertion point for.
# 10.3.1.0.45 is expected to come out equal to the 10.2.1/10.4.1 hash, because
# its ThreadLimit is already the control's 60.
real_expect() { # <release> -> "<kind> <before-sha256> <expected-after-sha256>"
    case "$1" in
        10.1.2.0.318)
            echo "patched 6c44912aeb4ecda002c31516b1a8194895a4038c025a3b3a570901703584ccd7 837334a72f4f229b157b6fb73dcde1f172c8ef1cde949f083761a86c6fa8a7bc" ;;
        10.3.1.0.45)
            echo "patched 1c3be12918f1381eeb3377c488c7d61c26991b8cbb8eb9dd4e54f30c2ba687de f9260f0566b82d798c95a55adb28b8e42d4f6ed1af9f6eae37ac0682b1e337f1" ;;
        9.10.2.0.130)
            echo "patched 641daded94c1e61fb3793fc886fdf25be4d1fb01e695ddcdaa07330282ca730d c78d057bdf0a1b32635c06640c6e70fb4169babb5accf2e85a5c0ee12c32cc2a" ;;
        9.9.1.0.52)
            echo "shape fb6ffbdfd2e71ac3b58c01b70b388b0b2dd611e2037dceb9ba71909ef9ccf22c fb6ffbdfd2e71ac3b58c01b70b388b0b2dd611e2037dceb9ba71909ef9ccf22c" ;;
        9.13.3.0.164)
            echo "shape a3b9152a6d9dbd6f70dd891a1a97c47df7e7c608c696d728146cbf0e0cdf8496 a3b9152a6d9dbd6f70dd891a1a97c47df7e7c608c696d728146cbf0e0cdf8496" ;;
        10.2.1.0.236|10.4.1.0.272)
            echo "already f9260f0566b82d798c95a55adb28b8e42d4f6ed1af9f6eae37ac0682b1e337f1 f9260f0566b82d798c95a55adb28b8e42d4f6ed1af9f6eae37ac0682b1e337f1" ;;
        10.5.1.0.240|10.5.1.0.255|10.5.1.0.282)
            echo "already f8631f2ce878b4eb5ec1f825ff9164b5c41b87d327bcce916b1301bcda99f809 f8631f2ce878b4eb5ec1f825ff9164b5c41b87d327bcce916b1301bcda99f809" ;;
        *) return 1 ;;
    esac
}

if [ -n "${AS_WEBS_CONF_DIR:-}" ]; then
    [ -d "$AS_WEBS_CONF_DIR" ] || fail "AS_WEBS_CONF_DIR is not a directory: $AS_WEBS_CONF_DIR"
    out_dir="${AS_WEBS_OUT:-$TMP/real}"
    mkdir -p "$out_dir"
    for release in 10.1.2.0.318 10.3.1.0.45 9.10.2.0.130 9.9.1.0.52 9.13.3.0.164 \
                   10.2.1.0.236 10.4.1.0.272 10.5.1.0.240 10.5.1.0.255 10.5.1.0.282; do
        conf="$AS_WEBS_CONF_DIR/$release.webs.conf"
        [ -f "$conf" ] || fail "no $conf (expected <release>.webs.conf for every matrix root)"
        read -r kind want_before want_after <<< "$(real_expect "$release")" \
            || fail "$release: no expectation recorded for this root"
        have_before="$(sha256sum < "$conf" | awk '{print $1}')"
        [ "$have_before" = "$want_before" ] \
            || fail "$release: the input is not the release's own webs.conf (sha256 $have_before, expected $want_before)"
        disk="$TMP/real-$release.disk.raw"; work="$TMP/real-$release.work"; log="$TMP/real-$release.log"
        build_disk "$conf" "$disk" 0644
        run_patch "$disk" "$work" "$log" || fail "$release: the patch exited non-zero:
$(cat "$log")"
        read_conf "$disk" "$out_dir/$release.after" || fail "$release: no $TARGET on the patched root"
        diff -u "$conf" "$out_dir/$release.after" > "$out_dir/$release.diff" || true
        have_after="$(sha256sum < "$out_dir/$release.after" | awk '{print $1}')"
        [ "$have_after" = "$want_after" ] \
            || fail "$release: patched sha256 $have_after, expected $want_after:
$(cat "$out_dir/$release.diff")"
        case "$kind" in
            patched)
                [ "$(diff_counts "$conf" "$out_dir/$release.after")" = "2 0" ] \
                    || fail "$release: the diff is not exactly two added lines: $(diff_counts "$conf" "$out_dir/$release.after")"
                grep -q 'LimitRequestFields 40 and LimitRequestFieldSize 4096 added' "$log" \
                    || fail "$release: the addition was not reported:
$(cat "$log")"
                pass "$release: the two directives added, sha256 $want_before -> $want_after"
                ;;
            already)
                cmp -s "$conf" "$out_dir/$release.after" || fail "$release: a root that sets the directive was changed:
$(cat "$out_dir/$release.diff")"
                grep -q 'already sets LimitRequestFields; left byte-for-byte unchanged' "$log" \
                    || fail "$release: the skip was not reported:
$(cat "$log")"
                pass "$release: byte-identical (sha256 $want_after), already set, skip reported"
                ;;
            shape)
                cmp -s "$conf" "$out_dir/$release.after" || fail "$release: a root the patch cannot place the pair in was changed:
$(cat "$out_dir/$release.diff")"
                grep -q 'is not ForbidEjsDirs' "$log" \
                    || fail "$release: the shape refusal was not reported:
$(cat "$log")"
                pass "$release: byte-identical, no ForbidEjsDirs anchor, skip reported"
                ;;
            *)
                fail "$release: unknown expectation kind '$kind'" ;;
        esac
    done
    echo "     (real inputs and diffs kept in $out_dir)"
else
    partial "the real releases' webs.conf files are not carried; set AS_WEBS_CONF_DIR=<dir> of <release>.webs.conf for the ten matrix roots to check every one"
fi

echo
echo "all webs-header-limit tests passed"
