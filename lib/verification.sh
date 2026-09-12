 #!/usr/bin/env bash

# This script handles verification, hashing, and structure comparison for the control script,
# and should not be run directly

#Handle verification issues
verification_issue() {
    local relative="$1"
    shift
    if [ "$FATAL_VERIFY" = "1" ]; then
        CURRENT_VERIFY_FATAL=1
        log_entry FATAL_VERIFY "$relative" "$@"
    else
        log_entry WARNING "$relative" "$@"
    fi
}

#Hash raw video
raw_video_hash() {
    ffmpeg -v error -nostdin -i "$1" \
        -map "0:v:$2" \
        -c:v rawvideo \
        -pix_fmt "$3" \
        -fps_mode passthrough \
        -f hash -hash sha256 - 2>/dev/null |
        awk -F= '/SHA256=/ {print $2}'
}

#Verify structures are correct
verify_media_structure() {
    python3 - "$1" "$2" <<'PY'
import collections
import json
import subprocess
import sys

src_path, dst_path = sys.argv[1], sys.argv[2]

def probe(path):
    p = subprocess.run(
        ["ffprobe", "-v", "error", "-show_streams", "-show_chapters", "-show_format", "-of", "json", path],
        text=True, capture_output=True
    )
    if p.returncode:
        raise RuntimeError(p.stderr.strip() or "ffprobe failed")
    return json.loads(p.stdout)

def clean(value):
    return str(value).replace("\r", "\\r").replace("\n", "\\n")

def tags_lower(obj):
    return {str(k).lower(): str(v) for k, v in (obj or {}).items()}

def warn(msg):
    print(clean(msg))

try:
    src = probe(src_path)
    dst = probe(dst_path)
except Exception as exc:
    warn(f"Full media-structure verification could not run: {exc}")
    raise SystemExit(0)

ss = src.get("streams", [])
ds = dst.get("streams", [])

if len(ss) != len(ds):
    warn(f"Stream count changed: source={len(ss)}, output={len(ds)}.")

sc = collections.Counter(s.get("codec_type", "unknown") for s in ss)
dc = collections.Counter(s.get("codec_type", "unknown") for s in ds)
for kind in sorted(set(sc) | set(dc)):
    if sc[kind] != dc[kind]:
        warn(f"{kind} stream count changed: source={sc[kind]}, output={dc[kind]}.")

important_stream_tags = ("language", "title", "filename", "mimetype", "handler_name", "comment")

for i, (s, d) in enumerate(zip(ss, ds)):
    st = s.get("codec_type", "unknown")
    dt = d.get("codec_type", "unknown")
    if st != dt:
        warn(f"Stream {i} type changed: {st} -> {dt}.")
        continue

    expected_codec = "hevc" if st == "video" and s.get("codec_name") == "h264" else s.get("codec_name")
    if d.get("codec_name") != expected_codec:
        warn(f"Stream {i} ({st}) codec changed unexpectedly: expected={expected_codec}, output={d.get('codec_name')}.")

    if st == "audio":
        for key in ("sample_rate", "channels", "channel_layout"):
            if s.get(key) is not None and s.get(key) != d.get(key):
                warn(f"Audio stream {i} {key} changed: {s.get(key)} -> {d.get(key)}.")

    if st != "video" or s.get("codec_name") != "h264":
        if st == "video":
            for key in ("width", "height", "pix_fmt"):
                if s.get(key) is not None and s.get(key) != d.get(key):
                    warn(f"Copied video stream {i} {key} changed: {s.get(key)} -> {d.get(key)}.")

    stag = tags_lower(s.get("tags"))
    dtag = tags_lower(d.get("tags"))
    for key in important_stream_tags:
        if key in stag and stag.get(key) != dtag.get(key):
            warn(f"Stream {i} metadata '{key}' changed: {stag.get(key)!r} -> {dtag.get(key)!r}.")

    sdisp = {k: int(v) for k, v in (s.get("disposition") or {}).items()}
    ddisp = {k: int(v) for k, v in (d.get("disposition") or {}).items()}
    for key in sorted(set(sdisp) | set(ddisp)):
        if sdisp.get(key, 0) != ddisp.get(key, 0):
            warn(f"Stream {i} disposition '{key}' changed: {sdisp.get(key, 0)} -> {ddisp.get(key, 0)}.")

sch = src.get("chapters", [])
dch = dst.get("chapters", [])
if len(sch) != len(dch):
    warn(f"Chapter count changed: source={len(sch)}, output={len(dch)}.")

for i, (s, d) in enumerate(zip(sch, dch)):
    for key in ("start_time", "end_time"):
        try:
            a, b = float(s.get(key, 0)), float(d.get(key, 0))
            if abs(a - b) > 0.005:
                warn(f"Chapter {i} {key} changed: {a:.6f} -> {b:.6f}.")
        except (TypeError, ValueError):
            pass
    stag = tags_lower(s.get("tags"))
    dtag = tags_lower(d.get("tags"))
    for key, value in stag.items():
        if dtag.get(key) != value:
            warn(f"Chapter {i} metadata '{key}' changed: {value!r} -> {dtag.get(key)!r}.")

source_format_tags = tags_lower((src.get("format") or {}).get("tags"))
output_format_tags = tags_lower((dst.get("format") or {}).get("tags"))
important_format_tags = {
    "title", "artist", "album", "album_artist", "composer", "genre", "date",
    "creation_time", "comment", "description", "synopsis", "copyright", "publisher"
}
for key in sorted(important_format_tags):
    if key in source_format_tags and source_format_tags.get(key) != output_format_tags.get(key):
        warn(f"Container metadata '{key}' changed: {source_format_tags.get(key)!r} -> {output_format_tags.get(key)!r}.")
PY
}