#!/usr/bin/env bash

# This script configures the defaults for h264_to_h265_transcoder.sh and should
# not be run directly

configure_archive() {
    SCRIPT_VERSION="2026.09-001"
    STATE_SCHEMA_VERSION="1"

    CRF="${CRF:-18}"    #CRF can be set to an integer. FFMPEG defaults to 28
    PRESET="${PRESET=-slow}"    #Can be: medium, slow, slower, veryslow
    TUNE="${TUNE:-}"    #Sets the FFMPEG tune value. Can be: psnr, ssim, grain, zerolatency, fastdecode
    LOSSLESS="${LOSSLESS:-o}"   #Can be 1 or 0, should not be set to 1 unless needed, as this will increase file size
    OVERWRITE="${OVERWRITE:-0}" #Sets wether existing files should be overwritten
    CONTAINER="${CONTAINER:-source}" #Can be source or mkv. Decides output container type
    CHECKSUMS="${CHECKSUMS:-0}" #Can be: 1 or 0. Configures if checksums should be generated
    VERIFY_STRUCTURE="${VERIFY_STRUCTURE:-1}"   # Enables a complete decode pass over output video/audio
    VERIFY_DECODE="${VERIFY_DECODE:-0}"   #Can be 0 or 1; full decode verification is expensive
    FATAL_VERIFY="${FATAL_VERIFY:-1}"     #1 = reject derivative on critical verification failure
    DYNAMIC_HDR="${DYNAMIC_HDR:-transcode}"    #can be copy or transcode. Copy will not transcode HDR content and will just copy the original to the output directory
    HDR_SCAN_PACKETS="${HDR_SCAN_PACKETS:-300}" #Number of packets for quick static HDR cerification
    HDR_HEARTBEAT_SECONDS="${HDR_HEARTBEAT_SECONDS:-5}" #Number of seconds to wait between updates when scanning for HDR content
    PROGRESS_WIDTH="${PROGRESS_WIDTH:-36}"  #Sets progress bar width
    KEEP_ONLY_IF_SMALLER="${KEEP_ONLY_IF_SMALLER:-1}"   #Can be 1 or 0, 1 only keeps files if they are smaller than original
    MIN_SIZE_SAVING_PERCENT="${MIN_SIZE_SAVING_PERCENT:-5}" #Sets the minimum percentage saving for a kept file
    MIN_SIZE_SAVING_MIB="${MIN_SIZE_SAVING_MIB:-100}"   #Sets the minimum byte saving for a kept file
    ABS_SAVING_MIN_SOURCE_MIB="${ABS_SAVING_MIN_SOURCE_MIB:-1024}"  #File size above which percentage saving applies
    FREE_SPACE_CHECK="${FREE_SPACE_CHECK:-1}"   #Sets wether script checks for free space before running. Predictive only
    MIN_FREE_SPACE_GIB="${MIN_FREE_SPACE_GIB:-5}"   #Minimum space requirement
    REPROCESS_ON_TOOL_CHANGE="${REPROCESS_ON_TOOL_CHANGE:-0}"   #When 1, a tool-version fingerprint change invalidates otherwise-current completed state.

    #Check required packages are installed
    for cmd in ffmpeg ffprobe find cp mv rm touch chmod chown id grep awk date mktemp tail sed wc stat python3 flock df sleep; do
        command -v "$cmd" > /dev/null 2>&1 || {
            echo "ERROR: required package not found: $cmd"
            exit 1
        }
    done

    #Check additional packages required if $CHECKSUMS is set to 1
    if [ "$CHECKSUMS" = "1" ]; then
        for cmd in sha256sum sort xargs; do
            command -v "$cmd" >/dev/null 2>&1 || {
                echo "ERROR: CHECKSUMS=1 requires package: $cmd"
                exit 1
            }
        done
    fi

    #Check correct command syntax
    [ "$#" -eq 1 ] || {
        echo "Usage: $0 /path/to/media"
        exit 1
    }

    #Checks specified container is suitable and can be handled
    case "$CONTAINER" in
        source|mkv) ;;
        *)
            echo "ERROR: CONTAINER must be 'source' or 'mkv'."
            exit 1
            ;;
    esac

    #Checks if DYNAMIC_HDR variable is correctly set
    case "$DYNAMIC_HDR" in
        copy|transcode) ;;
        *)
            echo "ERROR: DYNAMIC_HDR must be 'copy' or 'transcode'."
            exit 1
            ;;
    esac

    #Checks booleans are correctly set
    local bool_name bool_value numeric_name numeric_value
    for bool_name in KEEP_ONLY_IF_SMALLER VERIFY_STRUCTURE VERIFY_DECODE FATAL_VERIFY FREE_SPACE_CHECK REPROCESS_ON_TOOL_CHANGE; do
        bool_value="${!bool_name}"
        case "$bool_value" in
            0|1) ;;
            *)
                echo "ERROR: $bool_name must be 0 or 1."
                exit 1
                ;;
        esac
    done

    #Checks minimum percent saving is set correctly
    if ! [[ "$MIN_SIZE_SAVING_PERCENT" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
       ! awk -v v="$MIN_SIZE_SAVING_PERCENT" 'BEGIN { exit (v >= 0 && v < 100) ? 0 : 1 }'; then
        echo "ERROR: MIN_SIZE_SAVING_PERCENT must be a number from 0 up to (but not including) 100."
        exit 1
    fi

    #Checks byte size variables are set correctly
    for byte_name in MIN_SIZE_SAVING_MIB ABS_SAVING_MIN_SOURCE_MIB MIN_FREE_SPACE_GIB; do
        byte_value="${!byte_name}"
        if ! [[ "$byte_value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            echo "ERROR: $byte_name must be a non-negative number."
            exit 1
        fi
    done

    #Checks heartbeat time is set correctly
    if ! [[ "$HDR_HEARTBEAT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: HDR_HEARTBEAT_SECONDS must be a positive whole number."
        exit 1
    fi

    #Checks source directory exists
    SOURCE_ROOT="$1"
    [ -d "$SOURCE_ROOT" ] || {
        echo "ERROR: directory does not exist: $SOURCE_ROOT"
        exit 1
    }

    #Checks destination directory is accessible
    SOURCE_ROOT="$(cd "$SOURCE_ROOT" && pwd -P)"
    DEST_ROOT="${DEST_ROOT:-$SOURCE_ROOT/h265}"
    mkdir -p "$DEST_ROOT" || {
        echo "ERROR: could not create destination directory: $DEST_ROOT"
        exit 1
    }
    DEST_ROOT="$(cd "$DEST_ROOT" && pwd -P)"

    #Checks destination and source are not the same
    if [ "$DEST_ROOT" = "$SOURCE_ROOT" ] || [[ "$SOURCE_ROOT/" == "$DEST_ROOT/"* ]]; then
        echo "ERROR: DEST_ROOT must not be the source directory or an ancestor of it."
        exit 1
    fi

    #Creates log, manifest, state, and lock files
    LOG="$DEST_ROOT/conversion_warnings.log"
    SOURCE_MANIFEST="$DEST_ROOT/source_sha256.txt"
    OUTPUT_MANIFEST="$DEST_ROOT/output_sha256.txt"
    STATE_ROOT="$DEST_ROOT/.h265-state"
    LOCK_FILE="$DEST_ROOT/.conversion.lock"
    mkdir -p "$STATE_ROOT"

    #Keep the lock file descriptor open for the lifetime of the controller.
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo "ERROR: another conversion process is already using: $DEST_ROOT"
        exit 1
    fi

    #set counters etc
    warnings=0
    errors=0
    failed=0
    converted=0
    copied=0
    skipped=0
    size_rejected=0
    verify_rejected=0
    processed=0
    bytes_saved_total=0
    bytes_saved_this_run=0
    CURRENT_PARTIAL=""
    CURRENT_FFMPEG_LOG=""
    CURRENT_WORKDIR=""
    CURRENT_SOURCE_FINGERPRINT=""
    CURRENT_HDR_SCAN_COMPLETE=0
    CURRENT_HAS_DOVI=0
    CURRENT_HAS_HDR10P=0
    CURRENT_HAS_OTHER_DYNAMIC=0
    CURRENT_EXPECTED_TRANSCODE=""
    FORCE_CURRENT_OUTPUT=0
    CURRENT_VERIFY_FATAL=0
    SETTINGS_FINGERPRINT=""
    TOOL_FINGERPRINT=""
    }