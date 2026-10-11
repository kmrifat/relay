#!/usr/bin/env bash
# Measures Relay against the ADR-0001 performance budget.
#
#   tool/perf_check.sh [seconds, default 60]
#
# Samples the running Relay app and relayd: average CPU over the window and
# resident memory at the end. Run it with the app open on a board and no
# agent working (the "idle" row of the budget).
set -euo pipefail
secs="${1:-60}"

ui_pid="$(pgrep -f 'Relay.app/Contents/MacOS/Relay' | head -1 || true)"
d_pid="$(pgrep -f 'Helpers/relay daemon|relay daemon' | head -1 || true)"
[[ -z "$ui_pid" ]] && { echo "Relay app is not running"; exit 1; }
[[ -z "$d_pid" ]] && { echo "relayd is not running"; exit 1; }

cpu_seconds() { ps -o time= -p "$1" | awk -F'[:.]' '{ if (NF==4) print $1*3600+$2*60+$3+$4/100; else print $1*60+$2+$3/100 }'; }
rss_mb() { ps -o rss= -p "$1" | awk '{ printf "%.0f", $1/1024 }'; }

ui0=$(cpu_seconds "$ui_pid"); d0=$(cpu_seconds "$d_pid")
sleep "$secs"
ui1=$(cpu_seconds "$ui_pid"); d1=$(cpu_seconds "$d_pid")

ui_cpu=$(awk -v a="$ui0" -v b="$ui1" -v s="$secs" 'BEGIN { printf "%.2f", (b-a)/s*100 }')
d_cpu=$(awk -v a="$d0" -v b="$d1" -v s="$secs" 'BEGIN { printf "%.2f", (b-a)/s*100 }')
ui_rss=$(rss_mb "$ui_pid"); d_rss=$(rss_mb "$d_pid")

ok() { awk -v v="$1" -v max="$2" 'BEGIN { exit !(v < max) }' && echo "ok" || echo "OVER"; }
printf "%-22s %8s %8s   %s\n" "process" "CPU %" "RSS MB" "budget"
printf "%-22s %8s %8s   %s / %s\n" "Relay app (idle)" "$ui_cpu" "$ui_rss" "cpu<1 $(ok "$ui_cpu" 1)" "rss<150 $(ok "$ui_rss" 150)"
printf "%-22s %8s %8s   %s / %s\n" "relayd (idle)" "$d_cpu" "$d_rss" "cpu<1 $(ok "$d_cpu" 1)" "rss<30 $(ok "$d_rss" 30)"
