#!/bin/sh
# ZD1200 Network Monitor collector loop.
#
# Derived from dbro/zd1200's runtime S99 hook (upstream revision 10aeb90),
# adapted for this fork: the admin-console menu/bundle patch is applied offline
# to the root partition by scripts/container/patches/50-network-monitor.sh, so
# this hook never edits /web and only schedules collection.
(
    snapshot_dir=/writable/zd1200-ping-monitor/snapshots
    current_client=/writable/zd1200-ping-monitor/current-client.xml
    current_ap_detail=/writable/zd1200-ping-monitor/current-ap-detail.xml
    configured_targets=/writable/zd1200-ping-monitor/client-targets.conf
    intervals=/writable/zd1200-ping-monitor/intervals.conf
    seeded_defaults=/etc/zd1200-ping-monitor-defaults.conf
    settings_status=/writable/zd1200-ping-monitor/settings.json
    target_metadata=/writable/zd1200-ping-monitor/targets.json
    daily_manifest=/writable/zd1200-ping-monitor/daily-manifest.json
    snapshot_manifest=/writable/zd1200-ping-monitor/snapshot-manifest.json
    preference_updated_at=
    # Collection is opt-in on a fresh controller. A saved native preference
    # remains authoritative after the administrator enables monitoring.
    monitoring_enabled=0
    monitoring_interval=60
    last_collection=0
    settings_source=defaults
    mkdir -p /writable/zd1200-ping-monitor "$snapshot_dir"
    # Operator defaults baked into the image by 50-network-monitor.sh (from the
    # ZD_PING_* build/deploy settings).  Seed the writable configuration only
    # while it is absent: an existing file means the administrator has already
    # configured the monitor from the page, and that choice wins from then on.
    if [ -r "$seeded_defaults" ]; then
        if [ ! -e "$intervals" ]; then
            seeded_interval=$(sed -n 's/^MONITOR_INTERVAL_SECONDS=//p' "$seeded_defaults" | head -n 1)
            case "$seeded_interval" in
                ''|*[!0-9]*) ;;
                *) printf 'MONITOR_INTERVAL_SECONDS=%s\n' "$seeded_interval" > "$intervals" ;;
            esac
        fi
        if [ ! -e "$configured_targets" ]; then
            seeded_targets=$(sed -n 's/^CLIENT_TARGETS=//p' "$seeded_defaults" | head -n 1)
            if [ -n "$seeded_targets" ]; then
                printf '%s\n' "$seeded_targets" > "$configured_targets"
            fi
        fi
    fi
    /usr/local/sbin/zd1200-snapshot-index-publish rebuild 2>/dev/null || true
    [ -r "$snapshot_manifest" ] || printf '{"version":1,"generated_at":0,"periods":[]}\n' > "$snapshot_manifest"
    [ -r "$target_metadata" ] || printf '{"status":"waiting","format_version":2,"targets":[]}\n' > "$target_metadata"
    [ -r "$daily_manifest" ] || printf '{"status":"ok","format_version":2,"generated_at":0,"periods":[]}\n' > "$daily_manifest"
    # Remove the obsolete persistent transfer files from the earlier bridge.
    rm -f /writable/zd1200-ping-monitor/native-settings.conf \
        /writable/zd1200-ping-monitor/.settings-session.cookie \
        /writable/zd1200-ping-monitor/.settings-csrf
    rm -rf /writable/zd1200-ping-monitor/getstat-probe
    if [ -r "$intervals" ]; then
        configured_interval=$(sed -n 's/^MONITOR_INTERVAL_SECONDS=//p' "$intervals" | head -n 1)
        [ -n "$configured_interval" ] || configured_interval=$(sed -n 's/^PING_INTERVAL_SECONDS=//p' "$intervals" | head -n 1)
        case "$configured_interval" in ''|*[!0-9]*) ;; *) [ "$configured_interval" -ge 30 ] && [ "$configured_interval" -le 3600 ] && monitoring_interval=$configured_interval;; esac
    fi
    apply_native_settings() {
        native_values=$1
        old_monitoring_enabled=$monitoring_enabled
        if [ -n "$native_values" ]; then
            configured_has_native=$(printf '%s\n' "$native_values" | sed -n 's/^HAS_NATIVE_SETTINGS=//p' | head -n 1)
            configured_monitoring_enabled=$(printf '%s\n' "$native_values" | sed -n 's/^MONITORING_ENABLED=//p' | head -n 1)
            configured_interval=$(printf '%s\n' "$native_values" | sed -n 's/^MONITOR_INTERVAL_SECONDS=//p' | head -n 1)
            configured_updated=$(printf '%s\n' "$native_values" | sed -n 's/^PREFERENCE_UPDATED_AT=//p' | head -n 1)
            valid_native=1
            [ "$configured_has_native" = 1 ] || valid_native=0
            case "$configured_monitoring_enabled" in 0|1) ;; *) valid_native=0;; esac
            case "$configured_updated" in ''|*[!0-9]*) valid_native=0;; esac
            case "$configured_interval" in ''|*[!0-9]*) valid_native=0;; *) [ "$configured_interval" -ge 30 ] && [ "$configured_interval" -le 3600 ] || valid_native=0;; esac
            if [ "$valid_native" = 1 ]; then
                monitoring_enabled=$configured_monitoring_enabled
                monitoring_interval=$configured_interval
                preference_updated_at=$configured_updated
                settings_source=zd-preference
            fi
        fi
        [ "$old_monitoring_enabled" = 0 ] && [ "$monitoring_enabled" = 1 ] && last_collection=0
    }
    publish_settings() {
        monitoring_boolean=false
        [ "$monitoring_enabled" = 1 ] && monitoring_boolean=true
        updated_json=null
        [ -n "$preference_updated_at" ] && updated_json=$preference_updated_at
        temporary="$settings_status.tmp.$$"
        printf '{"status":"ok","monitoring_enabled":%s,"interval":%s,"source":"%s","preference_updated_at":%s,"checked_at":%s}\n' \
            "$monitoring_boolean" "$monitoring_interval" "$settings_source" "$updated_json" \
            "$(date +%s)" > "$temporary"
        mv -f "$temporary" "$settings_status"
    }
    if [ -r "$configured_targets" ]; then
        old_ifs=$IFS
        IFS=';'
        for target in $(cat "$configured_targets"); do
            IFS='|'
            set -- $target
            if [ "$#" -eq 3 ]; then
                /usr/local/sbin/zd1200-ping-monitor add-client "$1" "$2" "$3" 2>/dev/null || true
            fi
        done
        IFS=$old_ifs
    fi
    native_values=$(/usr/local/sbin/zd1200-ping-monitor-settings-sync 2>/dev/null || true)
    apply_native_settings "$native_values"
    publish_settings
    while :; do
        # Read and validate the persistent native ZD preference directly from
        # its root-only configuration. Keep the last valid value in process
        # memory if ZD is temporarily unavailable.
        native_values=$(/usr/local/sbin/zd1200-ping-monitor-settings-sync 2>/dev/null || true)
        apply_native_settings "$native_values"
        publish_settings
        now=$(date +%s)
        if [ "$monitoring_enabled" = 1 ] \
            && [ $((now - last_collection)) -ge "$monitoring_interval" ]; then
            if /usr/local/sbin/zd1200-network-snapshot-collect "$now" 2>/dev/null; then
                /usr/local/sbin/zd1200-snapshot-index-publish add "$now" 2>/dev/null || true
            fi
            /usr/local/sbin/zd1200-ping-monitor prune-snapshots 2>/dev/null || true
            # Fetch the same two bulk views used by the stock UI immediately
            # before every round.  They are parsed once and discarded after
            # compact SNR, airtime and mesh-link values reach SQLite.
            rm -f "$current_client" "$current_ap_detail"
            /usr/local/sbin/zd1200-network-snapshot-collect live 2>/dev/null || true
            /usr/local/sbin/zd1200-ping-monitor tick "$current_client" "$current_ap_detail" 2>/dev/null || true
            telemetry_temporary=/writable/zd1200-ping-monitor/telemetry-status.json.tmp.$$
            if /usr/local/sbin/zd1200-ping-monitor telemetry-status-json > "$telemetry_temporary" 2>/dev/null; then
                chmod 600 "$telemetry_temporary"
                mv -f "$telemetry_temporary" /writable/zd1200-ping-monitor/telemetry-status.json
            else
                rm -f "$telemetry_temporary"
            fi
            # Target synchronization above first maps legacy numeric AP rows
            # onto MAC-primary identities. Backfill only after that migration.
            /usr/local/sbin/zd1200-ping-daily-publish backfill "$now" 2>/dev/null || true
            # Materialize the current UTC day only. Completed daily chunks are
            # immutable and the browser derives every ping metric from these
            # raw one-byte observations.
            /usr/local/sbin/zd1200-ping-daily-publish "$now" 2>/dev/null || true
            last_collection=$now
        fi
        # Sleep only until the next collection is due. A fixed 30-second
        # sleep would add the collection runtime to every configured interval
        # (for example, a 12-second collection would otherwise turn a
        # 30-second configured interval into 42 seconds).
        after=$(date +%s)
        next_delay=30
        if [ "$monitoring_enabled" = 1 ]; then
            remaining=$((last_collection + monitoring_interval - after))
            [ "$remaining" -lt 1 ] && remaining=1
            [ "$remaining" -lt "$next_delay" ] && next_delay=$remaining
        fi
        sleep "$next_delay"
    done
) &
exit 0
