#!/usr/bin/env bash

# This script creates fingerprints and state records for control process
# and should not be run directly

#Set Variables
STATE_OUTPUT=""
STATE_SAVED_BYTES=0

#Create fingerprint from variables
fingerprint_values() {
    python3 - "$@" <<'PY2'
import hashlib, sys
h = hashlib.sha256()
for value in sys.argv[1:]:
    h.update(value.encode("utf-8", "surrogateescape"))
    h.update(b"\0")
print(h.hexdigest())
PY2
}

#Create a simple and fast source fingerprint that is cheap enough to be run pre-probing
source_fingerprint() {
    # Fast fingerprint: size + mtime + ctime + device + inode.  This is not a
    # content checksum; it is intentionally cheap enough to run before probing.
    stat -c '%s:%Y:%Z:%d:%i' -- "$1" 2>/dev/null
}

#Calls state path
state_path_for() {
    printf '%s/%s.state\n' "$STATE_ROOT" "$1"
}

#Gets state
state_get() {
    local state="$1" key="$2"
    [ -f "$state" ] || return 1
    awk -v key="$key" '
        index($0, key "=") == 1 {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' "$state"
}

#Create state file
write_state_record() {
    local input="$1" output="$2" relative="$3" status="$4" result="$5"
    local verified="$6" saved_bytes="$7" scan_seconds="$8" encode_seconds="$9" verify_seconds="${10}"
    local state tmp output_size=0 output_fingerprint=""

    state="$(state_path_for "$relative")"
    mkdir -p "$(dirname "$state")" || return 1
    tmp="$(mktemp -p "$(dirname "$state")" ".state.$$.XXXXXX")" || return 1
    if [ -n "$output" ] && [ -e "$output" ]; then
        output_size="$(stat -c '%s' -- "$output" 2>/dev/null || echo 0)"
        output_fingerprint="$(source_fingerprint "$output" 2>/dev/null || true)"
    fi

    {
        echo "schema=$STATE_SCHEMA_VERSION"
        echo "status=$status"
        echo "script_version=$SCRIPT_VERSION"
        echo "source_fingerprint=$CURRENT_SOURCE_FINGERPRINT"
        echo "settings_fingerprint=$SETTINGS_FINGERPRINT"
        echo "tool_fingerprint=$TOOL_FINGERPRINT"
        echo "result=$result"
        echo "output=$output"
        echo "output_size=$output_size"
        echo "output_fingerprint=$output_fingerprint"
        echo "saved_bytes=$saved_bytes"
        echo "verified=$verified"
        echo "hdr_scan_complete=$CURRENT_HDR_SCAN_COMPLETE"
        echo "has_dovi=$CURRENT_HAS_DOVI"
        echo "has_hdr10plus=$CURRENT_HAS_HDR10P"
        echo "has_other_dynamic_hdr=$CURRENT_HAS_OTHER_DYNAMIC"
        echo "scan_seconds=$scan_seconds"
        echo "encode_seconds=$encode_seconds"
        echo "verify_seconds=$verify_seconds"
        echo "completed_at=$(date '+%Y-%m-%dT%H:%M:%S%z')"
    } > "$tmp"

    mv -f -- "$tmp" "$state"
}

#Create a record when HDR scan is performed
write_scan_state() {
    local input="$1" relative="$2" scan_seconds="${3:-0}"
    if ! write_state_record "$input" "" "$relative" "scan" "scan-only" 0 0 "$scan_seconds" 0 0; then
        log_entry WARNING "$relative" "Could not persist the dynamic-HDR scan cache."
    fi
}

#Create a record when encode is completed
write_completed_state() {
    local input="$1" output="$2" relative="$3" result="$4" saved_bytes="$5"
    local scan_seconds="${6:-0}" encode_seconds="${7:-0}" verify_seconds="${8:-0}"
    if ! write_state_record "$input" "$output" "$relative" "complete" "$result" 1 "$saved_bytes" "$scan_seconds" "$encode_seconds" "$verify_seconds"; then
        log_entry WARNING "$relative" \
            "Output completed, but its processing-state record could not be written." \
            "A future run may conservatively process this file again."
    fi
}

#Load HDR scan record
load_hdr_cache() {
    local state="$1"
    [ -f "$state" ] || return 1
    [ "$(state_get "$state" schema 2>/dev/null)" = "$STATE_SCHEMA_VERSION" ] || return 1
    [ "$(state_get "$state" source_fingerprint 2>/dev/null)" = "$CURRENT_SOURCE_FINGERPRINT" ] || return 1
    [ "$(state_get "$state" hdr_scan_complete 2>/dev/null)" = "1" ] || return 1

    CURRENT_HDR_SCAN_COMPLETE=1
    CURRENT_HAS_DOVI="$(state_get "$state" has_dovi 2>/dev/null || echo 0)"
    CURRENT_HAS_HDR10P="$(state_get "$state" has_hdr10plus 2>/dev/null || echo 0)"
    CURRENT_HAS_OTHER_DYNAMIC="$(state_get "$state" has_other_dynamic_hdr 2>/dev/null || echo 0)"
    return 0
}

#Verify file should skip
state_is_current() {
    local state="$1" expected_copy="$2" expected_transcode="$3"
    local state_output state_saved

    [ -f "$state" ] || return 1
    [ "$(state_get "$state" schema 2>/dev/null)" = "$STATE_SCHEMA_VERSION" ] || return 1
    [ "$(state_get "$state" status 2>/dev/null)" = "complete" ] || return 1
    [ "$(state_get "$state" source_fingerprint 2>/dev/null)" = "$CURRENT_SOURCE_FINGERPRINT" ] || return 1
    [ "$(state_get "$state" settings_fingerprint 2>/dev/null)" = "$SETTINGS_FINGERPRINT" ] || return 1
    [ "$(state_get "$state" verified 2>/dev/null)" = "1" ] || return 1

    if [ "$REPROCESS_ON_TOOL_CHANGE" = "1" ] &&
       [ "$(state_get "$state" tool_fingerprint 2>/dev/null)" != "$TOOL_FINGERPRINT" ]; then
        return 1
    fi

    state_output="$(state_get "$state" output 2>/dev/null || true)"
    if [ "$state_output" != "$expected_copy" ] && [ "$state_output" != "$expected_transcode" ]; then
        return 1
    fi
    [ -n "$state_output" ] && [ -e "$state_output" ] || return 1
    local stored_output_fingerprint current_output_fingerprint
    stored_output_fingerprint="$(state_get "$state" output_fingerprint 2>/dev/null || true)"
    current_output_fingerprint="$(source_fingerprint "$state_output" 2>/dev/null || true)"
    [ -n "$stored_output_fingerprint" ] && [ "$stored_output_fingerprint" = "$current_output_fingerprint" ] || return 1

    state_saved="$(state_get "$state" saved_bytes 2>/dev/null || echo 0)"
    [[ "$state_saved" =~ ^-?[0-9]+$ ]] || state_saved=0
    STATE_OUTPUT="$state_output"
    STATE_SAVED_BYTES="$state_saved"
    return 0
}