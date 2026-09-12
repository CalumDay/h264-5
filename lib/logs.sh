#!/usr/bin/env bash

# This script configures logging and summaries, as well as human formating
# and should not be run directly

#Log entry format
log_entry() {
    local level="$1" file="$2"
    shift 2
    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $level"
        echo "File: $file"
        for msg in "$@"; do echo "  $msg"; done
        echo
    } >> "$LOG"

    case "$level" in
        WARNING)      ((warnings+=1)) ;;
        FATAL_VERIFY) ((warnings+=1)) ;;
        ERROR)        ((errors+=1)) ;;
    esac
    return 0
}

#FFMPEG Error log format
log_ffmpeg_error() {
    local file="$1" tmp="$2"
    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR"
        echo "File: $file"
        echo "  FFmpeg video -> H.265/HEVC conversion failed."
        echo "  Incomplete temporary output was removed."
        if [ -s "$tmp" ]; then
            echo
            echo "  ---- FFmpeg output (last 80 lines) ----"
            tail -n 80 "$tmp" | sed 's/^/  /'
            echo "  ----------------------------------------"
        fi
        echo
    } >> "$LOG"
    ((errors+=1))
}

#Make filesize legible to humans
human_bytes() {
    python3 - "$1" <<'PY2'
import sys
n = int(sys.argv[1])
sign = "-" if n < 0 else ""
n = abs(n)
units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
v = float(n)
unit = units[0]
for unit in units:
    if v < 1024.0 or unit == units[-1]:
        break
    v /= 1024.0
if unit == "B":
    print(f"{sign}{int(v)} {unit}")
elif v >= 100:
    print(f"{sign}{v:.0f} {unit}")
elif v >= 10:
    print(f"{sign}{v:.1f} {unit}")
else:
    print(f"{sign}{v:.2f} {unit}")
PY2
}

#Make time human readable
format_seconds() {
    local total="${1:-0}"
    printf '%02d:%02d:%02d' "$((total / 3600))" "$(((total % 3600) / 60))" "$((total % 60))"
}

#Result format
log_result() {
    local relative="$1" result="$2" source_bytes="$3" output_bytes="$4" saved_bytes="$5"
    local scan_seconds="$6" encode_seconds="$7" verify_seconds="$8"
    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] RESULT"
        echo "File: $relative"
        echo "  Result: $result"
        echo "  Source size: $(human_bytes "$source_bytes") ($source_bytes bytes)"
        echo "  Output size: $(human_bytes "$output_bytes") ($output_bytes bytes)"
        echo "  Space saved: $(human_bytes "$saved_bytes") ($saved_bytes bytes)"
        echo "  HDR scan time: $(format_seconds "$scan_seconds")"
        echo "  Encode time: $(format_seconds "$encode_seconds")"
        echo "  Verification time: $(format_seconds "$verify_seconds")"
        echo
    } >> "$LOG"
}