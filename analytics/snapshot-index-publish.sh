#!/bin/sh
# Publish a small manifest plus one timestamp-only JSON index per UTC day.
# The active UTC day keeps independently readable .xml.gz captures. After
# rollover, those captures are framed into one stream and compressed together
# at gzip level 6 so repeated XML structure is stored efficiently.
set -eu

state_dir=${ZD_SNAPSHOT_STATE_DIR:-/writable/zd1200-ping-monitor}
index_dir="$state_dir/snapshot-index"
manifest="$state_dir/snapshot-manifest.json"
snapshot_dir="$state_dir/snapshots"
bb=${ZD_BUSYBOX:-/usr/local/sbin/busybox}
monitor=${ZD_PING_MONITOR:-/usr/local/sbin/zd1200-ping-monitor}

mkdir -p "$index_dir"
umask 077

publish_day() {
    day=$1
    source="$index_dir/$day.timestamps"
    destination="$index_dir/$day.json"
    temporary="$destination.tmp.$$"
    [ -r "$source" ] || return 0
    bundle="snapshot-$day.bundle.gz"
    if [ -r "$snapshot_dir/$bundle" ]; then
        "$bb" awk -v day="$day" -v bundle="zd1200-ping-monitor-snapshots/$bundle" 'BEGIN{printf "{\"version\":2,\"day\":%s,\"bundle\":\"%s\",\"snapshots\":[",day,bundle} {if(n++)printf ",";printf "%s",$1} END{print "]}"}' "$source" > "$temporary"
    else
        "$bb" awk -v day="$day" 'BEGIN{printf "{\"version\":2,\"day\":%s,\"snapshots\":[",day} {if(n++)printf ",";printf "%s",$1} END{print "]}"}' "$source" > "$temporary"
    fi
    chmod 644 "$temporary"
    mv -f "$temporary" "$destination"
}

publish_manifest() {
    temporary="$manifest.tmp.$$"
    generated_at=$(date +%s)
    first=1
    printf '{"version":2,"generated_at":%s,"periods":[' "$generated_at" > "$temporary"
    for source in "$index_dir"/*.timestamps; do
        [ -r "$source" ] || continue
        day=${source##*/}; day=${day%.timestamps}
        case "$day" in ''|*[!0-9]*) continue;; esac
        count=$(wc -l < "$source" | tr -d ' ')
        [ "$first" = 1 ] || printf ',' >> "$temporary"
        first=0
        printf '{"start":%s,"end":%s,"count":%s,"file":"zd1200-ping-monitor-snapshot-index/%s.json"}' \
            "$((day * 86400))" "$(((day + 1) * 86400))" "$count" "$day" >> "$temporary"
    done
    printf ']}\n' >> "$temporary"
    chmod 644 "$temporary"
    mv -f "$temporary" "$manifest"
}

bundle_completed_days() {
    active_day=$1
    for source in "$index_dir"/*.timestamps; do
        [ -r "$source" ] || continue
        day=${source##*/}; day=${day%.timestamps}
        case "$day" in ''|*[!0-9]*) continue;; esac
        [ "$day" -lt "$active_day" ] || continue
        destination="$snapshot_dir/snapshot-$day.bundle.gz"
        [ -r "$destination" ] && continue
        archive="$snapshot_dir/.snapshot-$day.bundle.gz.$$"
        complete=1
        while read -r timestamp; do
            for kind in ap client mesh; do
                input="$snapshot_dir/$timestamp-$kind.xml.gz"
                if [ ! -r "$input" ] || ! "$bb" gzip -t "$input"; then
                    complete=0
                    break 2
                fi
            done
        done < "$source"
        if [ "$complete" = 1 ]; then
            {
                printf 'ZDSNAPSHOT1\n'
                while read -r timestamp; do
                    for kind in ap client mesh; do
                        input="$snapshot_dir/$timestamp-$kind.xml.gz"
                        size=$("$bb" gzip -dc "$input" | wc -c | tr -d ' ')
                        printf '%s %s %s\n' "$timestamp" "$kind" "$size"
                        "$bb" gzip -dc "$input"
                        printf '\n'
                    done
                done < "$source"
            } | "$bb" gzip -6 -c > "$archive"
        fi
        if [ "$complete" = 1 ] && "$bb" gzip -t "$archive"; then
            chmod 600 "$archive"
            mv -f "$archive" "$destination"
            while read -r timestamp; do
                rm -f "$snapshot_dir/$timestamp-ap.xml.gz" \
                    "$snapshot_dir/$timestamp-client.xml.gz" \
                    "$snapshot_dir/$timestamp-mesh.xml.gz"
            done < "$source"
            publish_day "$day"
        else
            rm -f "$archive"
        fi
    done
}

prune_index() {
    cutoff=$(($(date +%s) - 30 * 86400))
    for source in "$index_dir"/*.timestamps; do
        [ -r "$source" ] || continue
        day=${source##*/}; day=${day%.timestamps}
        case "$day" in ''|*[!0-9]*) continue;; esac
        if [ $(((day + 1) * 86400)) -le "$cutoff" ]; then
            rm -f "$source" "$index_dir/$day.json"
            rm -f "$snapshot_dir/snapshot-$day.bundle.gz"
        elif [ $((day * 86400)) -lt "$cutoff" ]; then
            temporary="$source.tmp.$$"
            "$bb" awk -v cutoff="$cutoff" '$1 >= cutoff' "$source" > "$temporary"
            mv -f "$temporary" "$source"
            publish_day "$day"
        fi
    done
}

case "${1:-}" in
rebuild)
    # This migration runs once for an existing installation. Grouping by the
    # integer UTC epoch-day avoids thousands of date subprocesses.
    if [ ! -e "$index_dir/.version-1" ]; then
        "$monitor" snapshot-times | \
            "$bb" awk -v dir="$index_dir" '{print $1 >> (dir "/" int($1/86400) ".timestamps")}'
        for source in "$index_dir"/*.timestamps; do
            [ -r "$source" ] || continue
            day=${source##*/}; publish_day "${day%.timestamps}"
        done
        : > "$index_dir/.version-1"
    fi
    prune_index
    publish_manifest
    ;;
add)
    timestamp=${2:-}
    case "$timestamp" in ''|*[!0-9]*) exit 2;; esac
    day=$((timestamp / 86400))
    source="$index_dir/$day.timestamps"
    last=$(tail -n 1 "$source" 2>/dev/null || true)
    [ "$last" = "$timestamp" ] || printf '%s\n' "$timestamp" >> "$source"
    chmod 600 "$source"
    publish_day "$day"
    bundle_completed_days "$day"
    prune_index
    publish_manifest
    ;;
*)
    echo "Usage: $0 {rebuild|add TIMESTAMP}" >&2
    exit 2
    ;;
esac
