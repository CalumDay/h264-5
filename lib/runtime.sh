 #!/usr/bin/env bash

# This script handles run-level initialisation and top-level attachement for the control script,
# and should not be run directly

#Initialise runtime
initialize_runtime() {
    ffmpeg -hide_banner -encoders 2>/dev/null | grep 'libx265' >/dev/null || {
        log_entry ERROR SCRIPT "FFmpeg does not provide the libx265 encoder."
        echo "ERROR: FFmpeg does not provide libx265."
        exit 1
    }

    X265_HELP="$(ffmpeg -hide_banner -h encoder=libx265 2>&1)"
    HAS_UDU_SEI=0
    HAS_A53CC=0
    HAS_DOLBYVISION=0
    grep -q 'udu_sei' <<< "$X265_HELP" && HAS_UDU_SEI=1
    grep -q 'a53cc' <<< "$X265_HELP" && HAS_A53CC=1
    grep -q 'dolbyvision' <<< "$X265_HELP" && HAS_DOLBYVISION=1

    [ "$HAS_UDU_SEI" -eq 1 ] || log_entry WARNING SCRIPT \
        "This FFmpeg/libx265 build does not expose udu_sei; unregistered SEI cannot be explicitly preserved."
    [ "$HAS_A53CC" -eq 1 ] || log_entry WARNING SCRIPT \
        "This FFmpeg/libx265 build does not expose a53cc; A/53 caption preservation cannot be explicitly requested."

    FFMPEG_VERSION="$(ffmpeg -version 2>/dev/null | sed -n '1p')"
    FFPROBE_VERSION="$(ffprobe -version 2>/dev/null | sed -n '1p')"
    if command -v x265 >/dev/null 2>&1; then
        X265_VERSION="$(x265 --version 2>&1 | sed -n '1p')"
    else
        X265_VERSION="libx265 via FFmpeg (standalone x265 version unavailable)"
    fi
    if command -v hdr10plus_tool >/dev/null 2>&1; then
        HDR10PLUS_VERSION="$(hdr10plus_tool --version 2>&1 | sed -n '1p')"
    else
        HDR10PLUS_VERSION="not installed"
    fi
    if command -v dovi_tool >/dev/null 2>&1; then
        DOVI_VERSION="$(dovi_tool --version 2>&1 | sed -n '1p')"
    else
        DOVI_VERSION="not installed"
    fi

    TOOL_FINGERPRINT="$(fingerprint_values "$FFMPEG_VERSION" "$FFPROBE_VERSION" "$X265_VERSION" "$HDR10PLUS_VERSION" "$DOVI_VERSION")"
    SETTINGS_FINGERPRINT="$(fingerprint_values \
        "$CRF" "$PRESET" "$TUNE" "$LOSSLESS" "$CONTAINER" "$DYNAMIC_HDR" \
        "$HDR_SCAN_PACKETS" "$KEEP_ONLY_IF_SMALLER" "$MIN_SIZE_SAVING_PERCENT" \
        "$MIN_SIZE_SAVING_MIB" "$ABS_SAVING_MIN_SOURCE_MIB" "$VERIFY_STRUCTURE" \
        "$VERIFY_DECODE" "$FATAL_VERIFY" "$HAS_UDU_SEI" "$HAS_A53CC" "$HAS_DOLBYVISION")"

    CPU_NAME="$(awk -F: '/model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
    CPU_THREADS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo unknown)"

    TOTAL_FILES="$(
        find "$SOURCE_ROOT" -path "$DEST_ROOT" -prune -o -type f -printf '.' |
        wc -c | awk '{print $1}'
    )"

    {
        echo
        echo "============================================================"
        echo "Conversion run started: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Script    : $SCRIPT_VERSION"
        echo "Source    : $SOURCE_ROOT"
        echo "Output    : $DEST_ROOT"
        echo "CPU       : ${CPU_NAME:-unknown}"
        echo "Threads   : $CPU_THREADS"
        echo "Preset    : $PRESET"
        echo "Tune      : ${TUNE:-none}"
        echo "Container : $CONTAINER"
        echo "Checksums : $CHECKSUMS"
        echo "Dyn HDR   : $DYNAMIC_HDR"
        echo "Size gate : $KEEP_ONLY_IF_SMALLER"
        echo "Min save  : ${MIN_SIZE_SAVING_PERCENT}% + ${MIN_SIZE_SAVING_MIB} MiB (for sources >= ${ABS_SAVING_MIN_SOURCE_MIB} MiB)"
        echo "Decode chk: $VERIFY_DECODE"
        echo "Fatal ver.: $FATAL_VERIFY"
        echo "Free space: $FREE_SPACE_CHECK (reserve ${MIN_FREE_SPACE_GIB} GiB)"
        echo "FFmpeg    : $FFMPEG_VERSION"
        echo "FFprobe   : $FFPROBE_VERSION"
        echo "x265      : $X265_VERSION"
        echo "HDR10+    : $HDR10PLUS_VERSION"
        echo "dovi_tool : $DOVI_VERSION"
        if [ "$LOSSLESS" = "1" ]; then
            echo "Mode      : x265 lossless"
        else
            echo "Mode      : CRF $CRF"
        fi
        echo "============================================================"
        echo
    } >> "$LOG"

    # Mirror directories, including empty ones.
    local dir
    while IFS= read -r -d '' dir; do
        [ "$dir" = "$SOURCE_ROOT" ] && continue
        mkdir -p "$DEST_ROOT/${dir#"$SOURCE_ROOT"/}"
    done < <(
        find "$SOURCE_ROOT" -path "$DEST_ROOT" -prune -o -type d -print0
    )
}

#Run scripts and produce heartbeat/progress outputs
run_archive() {
    echo
    echo "============================================================"
    echo " H.264 / Dynamic HDR -> H.265 Archival Converter"
    echo "============================================================"
    echo "Version   : $SCRIPT_VERSION"
    echo "CPU       : ${CPU_NAME:-unknown}"
    echo "Threads   : $CPU_THREADS"
    echo "Source    : $SOURCE_ROOT"
    echo "Output    : $DEST_ROOT"
    echo "Files     : $TOTAL_FILES"
    echo "Preset    : $PRESET"
    echo "Tune      : ${TUNE:-none}"
    echo "Container : $CONTAINER"
    echo "Checksums : $CHECKSUMS"
    echo "Dyn HDR   : $DYNAMIC_HDR"
    echo "Size gate : $KEEP_ONLY_IF_SMALLER"
    echo "Min save  : ${MIN_SIZE_SAVING_PERCENT}% + ${MIN_SIZE_SAVING_MIB} MiB (large files)"
    echo "Decode chk: $VERIFY_DECODE"
    echo "Fatal ver.: $FATAL_VERIFY"
    echo "State dir : $STATE_ROOT"
    if [ "$LOSSLESS" = "1" ]; then
        echo "Mode      : x265 lossless"
    else
        echo "Mode      : CRF $CRF"
    fi
    echo "Log       : $LOG"
    echo "============================================================"
    echo

    local input
    while IFS= read -r -d '' input; do
        process_file "$input"
        ((processed+=1))
        draw_bar "Overall" "$processed" "$TOTAL_FILES"
        printf ' | saved %s' "$(human_bytes "$bytes_saved_total")"
        printf '\n'
    done < <(
        find "$SOURCE_ROOT" -path "$DEST_ROOT" -prune -o -type f -print0
    )

    preserve_directory_metadata
    generate_manifests

    {
        echo "============================================================"
        echo "Conversion run completed: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Files     : $TOTAL_FILES"
        echo "Converted : $converted"
        echo "Copied    : $copied"
        echo "Skipped   : $skipped"
        echo "Size reject: $size_rejected"
        echo "Verify reject: $verify_rejected"
        echo "Saved total: $(human_bytes "$bytes_saved_total") ($bytes_saved_total bytes)"
        echo "Saved this run: $(human_bytes "$bytes_saved_this_run") ($bytes_saved_this_run bytes)"
        echo "Warnings  : $warnings"
        echo "Errors    : $errors"
        echo "Failed    : $failed"
        echo "============================================================"
        echo
    } >> "$LOG"

    echo
    echo "============================================================"
    echo " Finished"
    echo "============================================================"
    echo "Processed : $processed"
    echo "Converted : $converted"
    echo "Copied    : $copied"
    echo "Skipped   : $skipped"
    echo "Size reject: $size_rejected"
    echo "Verify reject: $verify_rejected"
    echo "Saved total: $(human_bytes "$bytes_saved_total") ($bytes_saved_total bytes)"
    echo "Saved this run: $(human_bytes "$bytes_saved_this_run") ($bytes_saved_this_run bytes)"
    echo "Warnings  : $warnings"
    echo "Errors    : $errors"
    echo "Failed    : $failed"
    echo "Output    : $DEST_ROOT"
    echo "Log       : $LOG"
    if [ "$CHECKSUMS" = "1" ]; then
        echo "Source SHA: $SOURCE_MANIFEST"
        echo "Output SHA: $OUTPUT_MANIFEST"
    fi
    echo "============================================================"

    [ "$failed" -gt 0 ] && return 1
    return 0
}