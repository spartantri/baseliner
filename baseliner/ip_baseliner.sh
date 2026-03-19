#!/bin/bash

set -euo pipefail

########################################
# Defaults
########################################
MODE=""
TARGETS=""
OUTPUT_DIR="."
RATE=10000
WAIT=3
RETRIES=2
PASSES=3
IFACE=""
SHARD=""
SEED=42
NOTIFY_ENABLED=0
PROVIDER_CONFIG="provider.yaml"
PORTS="1-65535"

########################################
# Usage
########################################
usage() {
cat <<EOF
Usage:
  $0 -m <baseline|monitor> -t <targets> [options]

Modes:
  baseline   Generate or refresh the baseline from one or more scan passes
  monitor    Scan current targets and compare against an existing baseline

Required:
  -m  Mode: baseline or monitor
  -t  Targets (CIDR list, comma-separated)

Optional:
  -o  Output directory (default: .)
  -r  Rate in packets per second (default: 10000)
  -w  Wait time in seconds (default: 3)
  -R  Retries (default: 2)
  -p  Passes for baseline mode (default: 3)
  -i  Network interface (optional)
  -s  Shard in X/Y format (optional)
  -S  Seed (default: 42)
  -P  Ports to scan (default: 1-65535)
  -n  Enable notify on anomalies in monitor mode
  -c  Notify provider config file (default: provider.yaml)
  -h  Show this help

Files created in output directory:
  network_baseline.json
  network_baseline.txt
  network_scan_tmp.json
  network_scan_tmp.txt
  network_result.txt
  network_scan.log
  baseline_runs/

Examples:
  Generate baseline:
    $0 -m baseline -t "192.168.0.0/24" -r 10000 -p 3

  Monitor with existing baseline:
    $0 -m monitor -t "192.168.0.0/24" -r 10000

  Monitor with notify enabled:
    $0 -m monitor -t "192.168.0.0/24" -r 10000 -n -c provider.yaml
EOF
exit 1
}

########################################
# Parse arguments
########################################
while getopts "m:t:o:r:w:R:p:i:s:S:P:c:nh" opt; do
  case "$opt" in
    m) MODE="$OPTARG" ;;
    t) TARGETS="$OPTARG" ;;
    o) OUTPUT_DIR="$OPTARG" ;;
    r) RATE="$OPTARG" ;;
    w) WAIT="$OPTARG" ;;
    R) RETRIES="$OPTARG" ;;
    p) PASSES="$OPTARG" ;;
    i) IFACE="$OPTARG" ;;
    s) SHARD="$OPTARG" ;;
    S) SEED="$OPTARG" ;;
    P) PORTS="$OPTARG" ;;
    n) NOTIFY_ENABLED=1 ;;
    c) PROVIDER_CONFIG="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

########################################
# Validate arguments
########################################
if [ -z "$MODE" ] || [ -z "$TARGETS" ]; then
    usage
fi

if [ "$MODE" != "baseline" ] && [ "$MODE" != "monitor" ]; then
    echo "Error: mode must be 'baseline' or 'monitor'"
    exit 1
fi

case "$RATE" in
    ''|*[!0-9]*) echo "Error: rate must be numeric"; exit 1 ;;
esac

case "$WAIT" in
    ''|*[!0-9]*) echo "Error: wait must be numeric"; exit 1 ;;
esac

case "$RETRIES" in
    ''|*[!0-9]*) echo "Error: retries must be numeric"; exit 1 ;;
esac

case "$PASSES" in
    ''|*[!0-9]*) echo "Error: passes must be numeric"; exit 1 ;;
esac

########################################
# Paths
########################################
mkdir -p "$OUTPUT_DIR"

BASELINE_JSON="$OUTPUT_DIR/network_baseline.json"
BASELINE_TXT="$OUTPUT_DIR/network_baseline.txt"
TEMP_JSON="$OUTPUT_DIR/network_scan_tmp.json"
TEMP_TXT="$OUTPUT_DIR/network_scan_tmp.txt"
RESULT_FILE="$OUTPUT_DIR/network_result.txt"
LOG_FILE="$OUTPUT_DIR/network_scan.log"
WORK_DIR="$OUTPUT_DIR/baseline_runs"

mkdir -p "$WORK_DIR"

########################################
# Logging
########################################
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

########################################
# Optional masscan args
########################################
MASSCAN_ARGS=()
if [ -n "$IFACE" ]; then
    MASSCAN_ARGS+=(--interface "$IFACE")
fi
if [ -n "$SHARD" ]; then
    MASSCAN_ARGS+=(--shard "$SHARD")
fi

########################################
# Helpers
########################################
normalize_json_to_txt() {
    local json_file="$1"
    local txt_file="$2"

    if [ ! -s "$json_file" ]; then
        : > "$txt_file"
        return 0
    fi

    jq -r '
        .[]
        | select(.ip != null and .ports != null)
        | .ip as $ip
        | .ports[]
        | select(.port != null)
        | "\($ip):\(.port)"
    ' "$json_file" 2>/dev/null | sort -u > "$txt_file" || : > "$txt_file"
}

txt_to_json() {
    local txt_file="$1"
    local json_file="$2"

    awk -F: '
    BEGIN {
        print "["
    }
    {
        ip=$1
        port=$2
        if (!(ip in seen_ip)) {
            seen_ip[ip]=1
            ips[++ip_count]=ip
        }
        key=ip ":" port
        if (!(key in seen_pair)) {
            seen_pair[key]=1
            ports[ip, ++port_count[ip]]=port
        }
    }
    END {
        for (i=1; i<=ip_count; i++) {
            ip=ips[i]
            printf "%s{\"ip\":\"%s\",\"ports\":[", (i>1?",\n":""), ip
            for (j=1; j<=port_count[ip]; j++) {
                printf "%s{\"port\":%s}", (j>1?",":""), ports[ip, j]
            }
            printf "]}"
        }
        print "\n]"
    }' "$txt_file" > "$json_file"
}

run_masscan() {
    local output_json="$1"

    sudo masscan "$TARGETS" \
        -p"$PORTS" \
        --rate "$RATE" \
        --wait "$WAIT" \
        --retries "$RETRIES" \
        --open-only \
        --seed "$SEED" \
        "${MASSCAN_ARGS[@]}" \
        -oJ "$output_json"
}

generate_baseline() {
    local i
    local found_txt=0

    log "Starting baseline generation"
    log "Targets: $TARGETS"
    log "Ports: $PORTS"
    log "Rate: $RATE | Wait: $WAIT | Retries: $RETRIES | Passes: $PASSES | Shard: ${SHARD:-none} | Interface: ${IFACE:-default}"

    rm -f "$WORK_DIR"/scan_*.json "$WORK_DIR"/scan_*.txt

    for i in $(seq 1 "$PASSES"); do
        log "Baseline pass $i/$PASSES"
        run_masscan "$WORK_DIR/scan_$i.json"

        normalize_json_to_txt "$WORK_DIR/scan_$i.json" "$WORK_DIR/scan_$i.txt"

        if [ -s "$WORK_DIR/scan_$i.txt" ]; then
            found_txt=1
        else
            log "Warning: no open ports found on pass $i"
        fi
    done

    if [ "$found_txt" -eq 0 ]; then
        log "No results found in any baseline pass; creating empty baseline"
        : > "$BASELINE_TXT"
        echo "[]" > "$BASELINE_JSON"
        return 0
    fi

    cat "$WORK_DIR"/scan_*.txt 2>/dev/null | sort -u > "$BASELINE_TXT"
    txt_to_json "$BASELINE_TXT" "$BASELINE_JSON"

    log "Baseline generated"
    log "Baseline TXT: $BASELINE_TXT"
    log "Baseline JSON: $BASELINE_JSON"
}

monitor_anomalies() {
    local new_entries=""
    local missing_entries=""

    if [ ! -f "$BASELINE_JSON" ] && [ ! -f "$BASELINE_TXT" ]; then
        log "Error: baseline not found. Run baseline mode first."
        exit 1
    fi

    if [ ! -f "$BASELINE_TXT" ]; then
        normalize_json_to_txt "$BASELINE_JSON" "$BASELINE_TXT"
    fi

    if [ ! -f "$BASELINE_JSON" ]; then
        txt_to_json "$BASELINE_TXT" "$BASELINE_JSON"
    fi

    log "Starting monitor scan"
    log "Targets: $TARGETS"
    log "Ports: $PORTS"
    log "Rate: $RATE | Wait: $WAIT | Retries: $RETRIES | Shard: ${SHARD:-none} | Interface: ${IFACE:-default}"

    run_masscan "$TEMP_JSON"
    normalize_json_to_txt "$TEMP_JSON" "$TEMP_TXT"

    log "Comparing current scan to baseline"

    new_entries="$(comm -23 "$TEMP_TXT" "$BASELINE_TXT" || true)"
    missing_entries="$(comm -13 "$TEMP_TXT" "$BASELINE_TXT" || true)"

    if [ -z "$new_entries" ] && [ -z "$missing_entries" ]; then
        log "No anomalies found"
        rm -f "$TEMP_JSON" "$TEMP_TXT"
        return 0
    fi

    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Network anomalies detected"
        echo

        if [ -n "$new_entries" ]; then
            echo "[NEW OPEN PORTS]"
            echo "$new_entries"
            echo
        fi

        if [ -n "$missing_entries" ]; then
            echo "[MISSING PREVIOUSLY OPEN PORTS]"
            echo "$missing_entries"
            echo
        fi

        echo "Current scan: $TEMP_JSON"
        echo "Baseline: $BASELINE_JSON"
        echo "------------------------------------------------"
    } | tee "$RESULT_FILE" >> "$LOG_FILE"

    if [ "$NOTIFY_ENABLED" -eq 1 ]; then
        if command -v notify >/dev/null 2>&1; then
            notify -data "$RESULT_FILE" -provider-config "$PROVIDER_CONFIG" -bulk
            log "Notification sent"
        else
            log "Warning: notify command not found; skipping notification"
        fi
    fi

    rm -f "$TEMP_JSON" "$TEMP_TXT"
}

########################################
# Main
########################################
case "$MODE" in
    baseline)
        generate_baseline
        ;;
    monitor)
        monitor_anomalies
        ;;
esac

log "Done"
log "------------------------------------------------"

