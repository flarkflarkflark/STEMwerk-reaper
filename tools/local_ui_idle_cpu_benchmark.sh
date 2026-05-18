#!/usr/bin/env bash
# local_ui_idle_cpu_benchmark.sh
# Sample REAPER CPU/memory during a STEMwerk UI idle benchmark run.
# Samples the REAPER process only - no Python backend, no audio processing.
#
# Usage:
#   ./tools/local_ui_idle_cpu_benchmark.sh --label flashy [--duration 120] [--pid PID]
#   ./tools/local_ui_idle_cpu_benchmark.sh --label native  [--duration 120] [--pid PID]
#
# If --pid is omitted, the script tries to detect the REAPER PID via pgrep.

set -uo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────

LABEL=""
DURATION=120
PID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --label)    LABEL="$2";    shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --pid)      PID="$2";      shift 2 ;;
        -h|--help)
            echo "Usage: $0 --label <flashy|native> [--duration N] [--pid PID]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: $0 --label <flashy|native> [--duration N] [--pid PID]" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$LABEL" ]]; then
    echo "Error: --label is required (flashy or native)" >&2
    exit 1
fi

# ── PID detection ─────────────────────────────────────────────────────────────

if [[ -z "$PID" ]]; then
    PID=$(pgrep -n -i reaper 2>/dev/null || true)
    if [[ -z "$PID" ]]; then
        echo "Error: Could not detect REAPER PID. Is REAPER running?" >&2
        echo "       Use --pid PID to specify manually." >&2
        exit 1
    fi
    echo "Detected REAPER PID: $PID"
fi

if ! kill -0 "$PID" 2>/dev/null; then
    echo "Error: PID $PID is not running." >&2
    exit 1
fi

CMD_NAME=$(ps -p "$PID" -o comm= 2>/dev/null | tr -d ' ' || echo "unknown")
echo "Process: $CMD_NAME (PID $PID)"

# ── Log file setup ────────────────────────────────────────────────────────────

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOGFILE="/tmp/stemwerk-ui-idle-benchmark-${LABEL}-${TIMESTAMP}.log"

{
    echo "# STEMwerk UI Idle CPU/Memory Benchmark"
    echo "# label=$LABEL"
    echo "# pid=$PID  cmd=$CMD_NAME"
    echo "# duration=${DURATION}s"
    echo "# started=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "#"
    echo "timestamp,elapsed_sec,cpu_pct,mem_pct,rss_kb,command"
} > "$LOGFILE"

# ── Sampler selection ─────────────────────────────────────────────────────────

HAVE_PIDSTAT=false
if command -v pidstat &>/dev/null; then
    HAVE_PIDSTAT=true
    echo "Sampler: pidstat"
else
    echo "Sampler: ps (pidstat not found)"
fi

# ── Sampling loop ─────────────────────────────────────────────────────────────

echo "Sampling PID $PID for ${DURATION}s..."
echo "Log: $LOGFILE"
echo ""
printf "%-10s %-10s %-8s %-8s %-12s\n" "Time" "Elapsed" "CPU%" "MEM%" "RSS(KB)"
echo "------------------------------------------------------"

START=$(date +%s)
SAMPLE_COUNT=0
TOTAL_CPU_X10=0    # accumulate as integer x10 to avoid bc dependency
MAX_CPU_X10=0
TOTAL_RSS=0
MAX_RSS=0

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START))
    if [[ $ELAPSED -ge $DURATION ]]; then break; fi

    TS=$(date +%H:%M:%S)
    CPU="0.0"
    MEM="0.0"
    RSS="0"

    if [[ "$HAVE_PIDSTAT" == "true" ]]; then
        # pidstat -u: one sample over 1s interval
        RAW=$(pidstat -u -p "$PID" 1 1 2>/dev/null | awk 'NR>3 && NF>0 {print}' | tail -1)
        if [[ -n "$RAW" ]]; then
            # columns: Time UID PID %usr %system %guest %wait %CPU CPU Command
            CPU=$(echo "$RAW" | awk '{print $8}')
        fi
        RSS=$(ps -p "$PID" -o rss= 2>/dev/null | tr -d ' ' || echo "0")
        MEM=$(ps -p "$PID" -o pmem= 2>/dev/null | tr -d ' ' || echo "0.0")
    else
        # ps fallback: not realtime but portable
        RAW=$(ps -p "$PID" -o %cpu,%mem,rss,comm --no-headers 2>/dev/null || echo "0.0 0.0 0 unknown")
        CPU=$(echo "$RAW" | awk '{print $1}')
        MEM=$(echo "$RAW" | awk '{print $2}')
        RSS=$(echo "$RAW" | awk '{print $3}')
        sleep 1
    fi

    # Sanitize
    CPU=${CPU:-0.0}
    MEM=${MEM:-0.0}
    RSS=${RSS:-0}
    [[ "$CPU" =~ ^[0-9.]+$ ]] || CPU="0.0"
    [[ "$MEM" =~ ^[0-9.]+$ ]] || MEM="0.0"
    [[ "$RSS" =~ ^[0-9]+$  ]] || RSS="0"

    echo "$TS,$ELAPSED,$CPU,$MEM,$RSS,$CMD_NAME" >> "$LOGFILE"
    printf "%-10s %-10s %-8s %-8s %-12s\n" "$TS" "${ELAPSED}s" "${CPU}%" "${MEM}%" "${RSS}"

    SAMPLE_COUNT=$((SAMPLE_COUNT + 1))

    # Integer accumulation (strip decimal for simplicity)
    CPU_INT="${CPU%%.*}"
    RSS_INT="$RSS"
    [[ "$CPU_INT" =~ ^[0-9]+$ ]] || CPU_INT=0
    [[ "$RSS_INT" =~ ^[0-9]+$ ]] || RSS_INT=0

    TOTAL_CPU_X10=$((TOTAL_CPU_X10 + CPU_INT))
    TOTAL_RSS=$((TOTAL_RSS + RSS_INT))
    [[ $CPU_INT -gt $MAX_CPU_X10 ]] && MAX_CPU_X10=$CPU_INT
    [[ $RSS_INT -gt $MAX_RSS     ]] && MAX_RSS=$RSS_INT
done

# ── Summary ───────────────────────────────────────────────────────────────────

AVG_CPU=0
AVG_RSS=0
if [[ $SAMPLE_COUNT -gt 0 ]]; then
    AVG_CPU=$((TOTAL_CPU_X10 / SAMPLE_COUNT))
    AVG_RSS=$((TOTAL_RSS / SAMPLE_COUNT))
fi

{
    echo "#"
    echo "# SUMMARY"
    echo "# label=$LABEL"
    echo "# samples=$SAMPLE_COUNT"
    echo "# avg_cpu_pct=$AVG_CPU"
    echo "# max_cpu_pct=$MAX_CPU_X10"
    echo "# avg_rss_kb=$AVG_RSS"
    echo "# max_rss_kb=$MAX_RSS"
    echo "# finished=$(date '+%Y-%m-%d %H:%M:%S')"
} >> "$LOGFILE"

echo ""
echo "=============================="
echo " BENCHMARK COMPLETE: $LABEL"
echo "=============================="
printf "  %-20s %s\n"  "Label:"     "$LABEL"
printf "  %-20s %s\n"  "PID:"       "$PID ($CMD_NAME)"
printf "  %-20s %s\n"  "Samples:"   "$SAMPLE_COUNT"
printf "  %-20s %s%%\n" "Avg CPU:"  "$AVG_CPU"
printf "  %-20s %s%%\n" "Max CPU:"  "$MAX_CPU_X10"
printf "  %-20s %s KB\n" "Avg RSS:" "$AVG_RSS"
printf "  %-20s %s KB\n" "Max RSS:" "$MAX_RSS"
printf "  %-20s %s\n"  "Log:"       "$LOGFILE"
echo ""
