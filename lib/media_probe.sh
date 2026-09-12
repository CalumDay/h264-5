#!/usr/bin/env bash

# This script probes media for HDR, timing, colour, codex etc
# and should not be run directly

#Parse basic attributes
parse_stream() {
    local line="$1" field key value
    codec=""; pix_fmt=""; width=""; height=""; sar=""; dar=""
    color_range=""; color_space=""; color_transfer=""; color_primaries=""

    IFS='|' read -ra fields <<< "$line"
    for field in "${fields[@]}"; do
        key="${field%%=*}"
        value="${field#*=}"
        case "$key" in
            codec_name) codec="$value" ;;
            pix_fmt) pix_fmt="$value" ;;
            width) width="$value" ;;
            height) height="$value" ;;
            sample_aspect_ratio) sar="$value" ;;
            display_aspect_ratio) dar="$value" ;;
            color_range) color_range="$value" ;;
            color_space) color_space="$value" ;;
            color_transfer) color_transfer="$value" ;;
            color_primaries) color_primaries="$value" ;;
        esac
    done
}

#Parse colour
valid_colour() {
    case "$1" in
        ""|unknown|unspecified|reserved|N/A) return 1 ;;
        *) return 0 ;;
    esac
}

#Quick static HDR scan
get_hdr_side_data() {
    local file="$1" stream="$2" data mastering=0 content_light=0

    data="$(
        ffprobe -v error \
            -select_streams "v:$stream" \
            -read_intervals "%+#${HDR_SCAN_PACKETS}" \
            -show_frames \
            -show_entries frame_side_data=side_data_type \
            -of default=noprint_wrappers=1 \
            "$file" 2>/dev/null || true
    )"

    grep -qi 'mastering display' <<< "$data" && mastering=1
    grep -qi 'content light' <<< "$data" && content_light=1
    echo "$mastering $content_light"
}

#In depth dynamic HDR scan (Dolby Vision/HDR10+)
get_dynamic_hdr_flags() {
    local file="$1" relative="${2:-$(basename "$1")}" tmp pid status started elapsed
    tmp="$(mktemp)" || return 1
    started=$SECONDS

    (
        set -o pipefail
        ffprobe -v error \
            -select_streams v \
            -show_streams \
            -show_frames \
            -show_packets \
            -show_entries \
stream_side_data=side_data_type:frame_side_data=side_data_type:packet_side_data=side_data_type \
            -of default=noprint_wrappers=1 \
            "$file" 2>/dev/null |
            awk '
                BEGIN { IGNORECASE=1; dovi=0; hdr10p=0; other=0 }
                /DOVI|Dolby Vision/ { dovi=1 }
                /SMPTE2094-40|HDR10\+/ { hdr10p=1 }
                /HDR Dynamic Metadata/ { other=1 }
                END { printf "%d %d %d\n", dovi, hdr10p, other }
            '
    ) > "$tmp" &
    pid=$!

    local next_heartbeat="$HDR_HEARTBEAT_SECONDS"
    while kill -0 "$pid" 2>/dev/null; do
        # Poll frequently so a short scan does not wait for the heartbeat period
        # before returning; only print when the configured interval has elapsed.
        sleep 0.2
        elapsed=$((SECONDS - started))
        if [ "$elapsed" -ge "$next_heartbeat" ] && kill -0 "$pid" 2>/dev/null; then
            printf '\rHDR scan: %s | elapsed %s' "$relative" "$(format_seconds "$elapsed")" >&2
            next_heartbeat=$((next_heartbeat + HDR_HEARTBEAT_SECONDS))
        fi
    done

    wait "$pid"
    status=$?
    elapsed=$((SECONDS - started))
    printf '\rHDR scan: %s | completed in %s\n' "$relative" "$(format_seconds "$elapsed")" >&2

    if [ "$status" -eq 0 ]; then
        cat "$tmp"
    fi
    rm -f -- "$tmp"
    return "$status"
}

#Read Dolby Vision information
get_dovi_info() {
    python3 - "$1" <<'PY2'
import json, subprocess, sys
p = subprocess.run(
    ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_streams", "-of", "json", sys.argv[1]],
    text=True, capture_output=True
)
if p.returncode:
    print("0 0 0 -1")
    raise SystemExit
try:
    data = json.loads(p.stdout)
except Exception:
    print("0 0 0 -1")
    raise SystemExit
for st in data.get("streams", []):
    for sd in st.get("side_data_list", []) or []:
        if "DOVI" in str(sd.get("side_data_type", "")).upper() or "DOLBY VISION" in str(sd.get("side_data_type", "")).upper():
            def iv(name, default=0):
                try: return int(sd.get(name, default))
                except Exception: return default
            print(iv("dv_profile"), iv("el_present_flag"), iv("rpu_present_flag"), iv("dv_bl_signal_compatibility_id", -1))
            raise SystemExit
print("0 0 0 -1")
PY2
}

#Probe timing
get_video_timing() {
    python3 - "$1" <<'PY2'
import json, subprocess, sys
p = subprocess.run(
    ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_streams", "-of", "json", sys.argv[1]],
    text=True, capture_output=True
)
try:
    st = json.loads(p.stdout).get("streams", [{}])[0]
except Exception:
    st = {}
print(st.get("avg_frame_rate", ""), st.get("r_frame_rate", ""), st.get("start_time", "0"))
PY2
}

#Probe disposition
get_video_disposition() {
    python3 - "$1" <<'PY2'
import json, subprocess, sys
p = subprocess.run(
    ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_streams", "-of", "json", sys.argv[1]],
    text=True, capture_output=True
)
try:
    d = json.loads(p.stdout).get("streams", [{}])[0].get("disposition", {})
except Exception:
    d = {}
print("+".join(k for k, v in d.items() if int(v or 0) == 1) or "0")
PY2
}

#Read duration
get_duration_us() {
    local d
    d="$(
        ffprobe -v error \
            -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 \
            "$1" 2>/dev/null
    )"

    if [[ "$d" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        awk -v d="$d" 'BEGIN { printf "%.0f", d * 1000000 }'
    else
        echo 0
    fi
}