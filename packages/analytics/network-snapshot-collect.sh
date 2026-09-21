#!/bin/sh
# Collect stock read-only views through ZoneDirector's vendor-supplied,
# root-local getstatd socket. Snapshot mode retains opaque XML; live mode keeps
# only the two transient inputs needed by a ping round; events are deduplicated
# immediately into SQLite.
set -eu

state_dir=/writable/zd1200-ping-monitor
snapshot_dir="$state_dir/snapshots"
bb=/usr/local/sbin/busybox

mkdir -p "$snapshot_dir"
umask 077

collect() {
    kind=$1
    temporary="$snapshot_dir/.${now}-${kind}.xml.$$"
    compressed="$snapshot_dir/.${now}-${kind}.xml.gz.$$"
    destination="$snapshot_dir/${now}-${kind}.xml.gz"
    /usr/local/sbin/zd1200-local-getstat "$kind" "$temporary"
    if ! grep -q '<ajax-response>' "$temporary"; then
        rm -f "$temporary" "$compressed"
        return 1
    fi
    # Actual key material is never retained. Device and DPSK identifiers are
    # intentionally preserved because they are useful when comparing state.
    "$bb" sed -i \
        -e 's/ preSharedKey="[^"]*"//g' \
        -e 's/ x-psk="[^"]*"//g' \
        -e 's/ psk-hash="[^"]*"//g' \
        -e 's/ psk_hash="[^"]*"//g' \
        "$temporary"
    if "$bb" gzip -c "$temporary" > "$compressed"; then
        chmod 600 "$compressed"
        mv -f "$compressed" "$destination"
        rm -f "$temporary"
    else
        rm -f "$temporary" "$compressed"
        return 1
    fi
}

collect_live() {
    kind=$1
    destination=$2
    temporary="$destination.tmp.$$"
    rm -f "$temporary"
    if /usr/local/sbin/zd1200-local-getstat "$kind" "$temporary" \
        && grep -q '<ajax-response>' "$temporary"; then
        chmod 600 "$temporary"
        mv -f "$temporary" "$destination"
    else
        rm -f "$temporary" "$destination"
        return 1
    fi
}

collect_events() {
    watermark=$(/usr/local/sbin/zd1200-ping-monitor event-watermark 2>/dev/null || echo 0)
    case "$watermark" in ''|*[!0-9]*) watermark=0;; esac
    start=0
    pages=0
    total_seen=0
    total_inserted=0
    newest=0
    cutoff=$(($(date +%s) - 2592000))
    while [ "$pages" -lt 100 ]; do
        temporary="$state_dir/.events-$start.xml.$$"
        rm -f "$temporary"
        if ! /usr/local/sbin/zd1200-local-getstat event "$start" "$temporary" \
            || ! grep -q '<ajax-response>' "$temporary"; then
            rm -f "$temporary"
            return 1
        fi
        result=$(/usr/local/sbin/zd1200-ping-monitor ingest-events "$temporary") || {
            rm -f "$temporary"
            return 1
        }
        rm -f "$temporary"
        count=$(printf '%s\n' "$result" | sed -n 's/^COUNT=//p')
        inserted=$(printf '%s\n' "$result" | sed -n 's/^INSERTED=//p')
        oldest=$(printf '%s\n' "$result" | sed -n 's/^OLDEST=//p')
        page_newest=$(printf '%s\n' "$result" | sed -n 's/^NEWEST=//p')
        case "$count:$inserted:$oldest:$page_newest" in *[!0-9:]*) return 1;; esac
        [ "$newest" -eq 0 ] && newest=$page_newest
        total_seen=$((total_seen + count))
        total_inserted=$((total_inserted + inserted))
        pages=$((pages + 1))
        [ "$count" -lt 300 ] && break
        [ "$oldest" -le "$cutoff" ] && break
        # Pages are newest-first. Once a page overlaps the previous high-water
        # mark, all remaining pages are already present.
        [ "$watermark" -gt 0 ] && [ "$oldest" -lt "$watermark" ] && break
        start=$((start + count))
    done
    temporary="$state_dir/events-status.json.tmp.$$"
    printf '{"status":"ok","collected_at":%s,"pages":%s,"seen":%s,"inserted":%s,"newest_event_at":%s}\n' \
        "$(date +%s)" "$pages" "$total_seen" "$total_inserted" "$newest" > "$temporary"
    chmod 600 "$temporary"
    mv -f "$temporary" "$state_dir/events-status.json"
}

if [ "${1:-}" = live ]; then
    collect_live client-live "$state_dir/current-client.xml"
    collect_live ap-detail "$state_dir/current-ap-detail.xml"
    temporary="$state_dir/live-status.json.tmp.$$"
    printf '{"status":"ok","collected_at":%s}\n' "$(date +%s)" > "$temporary"
    chmod 600 "$temporary"
    mv -f "$temporary" "$state_dir/live-status.json"
    exit 0
fi

if [ "${1:-}" = events ]; then
    collect_events
    exit 0
fi

now=${1:-$(date +%s)}
case "$now" in ''|*[!0-9]*) exit 2;; esac
collect ap
collect client
collect mesh
