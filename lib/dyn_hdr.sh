 #!/usr/bin/env bash

# This script extract dynamic HDR data for the control script,
# and should not be run directly

#Extract raw HEVC stream
extract_hevc_raw() {
    ffmpeg -v error -nostdin -y -i "$1" \
        -map 0:v:0 -c:v copy -bsf:v hevc_mp4toannexb \
        -f hevc "$2"
}

#Extract HDR10+ infor to json
extract_hdr10plus_json() {
    hdr10plus_tool extract "$1" -o "$2" >/dev/null 2>&1 && [ -s "$2" ]
}

#Compare HDR10+ json
compare_hdr10plus_json() {
    python3 - "$1" "$2" <<'PY2'
import json, sys

def normalize(x):
    if isinstance(x, dict):
        out = {}
        for k, v in x.items():
            lk = str(k).lower()
            if "datetime" in lk or "lastmodified" in lk:
                continue
            out[k] = normalize(v)
        return out
    if isinstance(x, list):
        return [normalize(v) for v in x]
    return x

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f: a = normalize(json.load(f))
    with open(sys.argv[2], "r", encoding="utf-8") as f: b = normalize(json.load(f))
except Exception:
    raise SystemExit(2)
raise SystemExit(0 if a == b else 1)
PY2
}

#Extract Dolby Vision subprofile
get_dovi_subprofile() {
    dovi_tool info -s -i "$1" 2>/dev/null |
        awk '
            /Profile:[[:space:]]*7[[:space:]]*\(FEL\)/ { print "FEL"; exit }
            /Profile:[[:space:]]*7[[:space:]]*\(MEL\)/ { print "MEL"; exit }
        '
}

#Get DV framecount
get_dovi_frame_count() {
    dovi_tool info -s -i "$1" 2>/dev/null |
        awk -F: '/^[[:space:]]*Frames:/ { gsub(/[[:space:]]/, "", $2); print $2; exit }'
}

#DV Compare
compare_dovi_rpu_semantic() {
    local a="$1" b="$2" dir="$3"
    local ja="$dir/dovi_source.json" jb="$dir/dovi_output.json"
    dovi_tool export -i "$a" -d "all=$ja" >/dev/null 2>&1 || return 2
    dovi_tool export -i "$b" -d "all=$jb" >/dev/null 2>&1 || return 2
    python3 - "$ja" "$jb" <<'PY2'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f: a = json.load(f)
    with open(sys.argv[2], encoding="utf-8") as f: b = json.load(f)
except Exception:
    raise SystemExit(2)
raise SystemExit(0 if a == b else 1)
PY2
}
