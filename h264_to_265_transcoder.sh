#!/usr/bin/env bash

# A recursive H264 > H265 transcoder script that uses ffmpeg to preserve
# metadata, audio tracks, subtitles, and HDR whilst minimising filesize,
# without reducing quality at a visual level.
# This script is not lossless, but aims to maintain a VMAF score of above 95

set -u
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MODULE_DIR="$SCRIPT_DIR/lib"

# Load modules in dependancy order
for module in \
    variables.sh \
    logs.sh \
    state.sh \
    progress.sh \
    media_probe.sh \
    dyn_hdr.sh \
    filesystem.sh \
    verification.sh \
    processor.sh \
    runtime.sh
do
    if [ ! -r "$MODULE_DIR/$module" ]; then
        echo "ERROR: required module is missing or cannot be read: $MODULE_DIR/$module" >&2
        exit 1
    fi
    source "$MODULE_DIR/$module" || {
        echo "ERROR: failed to load module: $MODULE_DIR/$module" >&2
        exit 1
    }
done

configure_archive "$@"

trap cleanup_temp EXIT
trap handle_signal INT TERM HUP

initialize_runtime
run_archive