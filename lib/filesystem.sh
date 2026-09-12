 #!/usr/bin/env bash

# This script handles free space checks, atomic file handling, etc for the control script,
# and should not be run directly

#Check for free space
check_free_space() {
    local input="$1" output_dir="$2" relative="$3"
    local source_bytes available reserve required
    [ "$FREE_SPACE_CHECK" = "1" ] || return 0

    mkdir -p "$output_dir" || return 1
    source_bytes="$(stat -c '%s' -- "$input" 2>/dev/null)" || return 1
    available="$(df -B1 --output=avail "$output_dir" 2>/dev/null | awk 'NR==2 {gsub(/[[:space:]]/, "", $1); print $1}')"
    reserve="$(awk -v gib="$MIN_FREE_SPACE_GIB" 'BEGIN { printf "%.0f", gib * 1073741824 }')"
    [[ "$available" =~ ^[0-9]+$ ]] || return 1
    [[ "$reserve" =~ ^[0-9]+$ ]] || reserve=0
    required=$((source_bytes + reserve))

    if [ "$available" -lt "$required" ]; then
        log_entry ERROR "$relative" \
            "Insufficient free space for an atomic transcode/copy." \
            "Available: $(human_bytes "$available") ($available bytes)" \
            "Required safety target: $(human_bytes "$required") ($required bytes)" \
            "Source size: $(human_bytes "$source_bytes"); reserve: ${MIN_FREE_SPACE_GIB} GiB."
        return 1
    fi
    return 0
}


#Calculate size saving
size_saving_percent() {
    awk -v original="$1" -v encoded="$2" 'BEGIN {
        if (original <= 0) printf "0.00";
        else printf "%.2f", ((original - encoded) / original) * 100;
    }'
}

#Check if required savings are made
meets_size_saving_target() {
    awk -v original="$1" -v encoded="$2" -v minimum_pct="$3" \
        -v minimum_mib="$4" -v abs_source_mib="$5" 'BEGIN {
        if (original <= 0 || encoded >= original) exit 1;
        saved = original - encoded;
        pct = (saved / original) * 100;
        if (pct < minimum_pct) exit 1;

        # The absolute saving threshold is intentionally waived for smaller
        # sources; otherwise a 100 MiB requirement would reject many useful
        # short clips even when their percentage saving is excellent.
        if (original >= abs_source_mib * 1048576 && saved < minimum_mib * 1048576) exit 1;
        exit 0;
    }'
}

#Create filestems
make_partial_path() {
    local output="$1" dir base suffix=""
    dir="$(dirname "$output")"
    base="$(basename "$output")"
    if [[ "$base" == *.* ]]; then
        suffix=".${base##*.}"
    fi
    mktemp -p "$dir" --suffix="$suffix" ".h265-partial.$$.XXXXXX"
}

#Create output path
transcode_output_path() {
    local relative="$1"
    if [ "$CONTAINER" = "mkv" ]; then
        case "${relative,,}" in
            *.mkv) printf '%s/%s\n' "$DEST_ROOT" "$relative" ;;
            *)     printf '%s/%s.mkv\n' "$DEST_ROOT" "$relative" ;;
        esac
    else
        printf '%s/%s\n' "$DEST_ROOT" "$relative"
    fi
}

#Preserve file metadata
preserve_file_metadata() {
    local source="$1" target="$2" relative="$3"
    if ! cp --attributes-only --preserve=all -- "$source" "$target" 2>/dev/null; then
        log_entry WARNING "$relative" \
            "Could not preserve all Linux filesystem attributes on the transcoded file." \
            "File data was retained; basic timestamp preservation will still be attempted."
        touch -r "$source" "$target" 2>/dev/null || true
        chmod --reference="$source" "$target" 2>/dev/null || true
    fi
}

#Preserve directory metadata
preserve_directory_metadata() {
    local source_dir dest_dir relative
    while IFS= read -r -d '' source_dir; do
        [ "$source_dir" = "$SOURCE_ROOT" ] && continue
        relative="${source_dir#"$SOURCE_ROOT"/}"
        dest_dir="$DEST_ROOT/$relative"
        [ -d "$dest_dir" ] || continue

        chmod --reference="$source_dir" "$dest_dir" 2>/dev/null ||
            log_entry WARNING "$relative/" "Could not preserve directory mode."
        touch -r "$source_dir" "$dest_dir" 2>/dev/null ||
            log_entry WARNING "$relative/" "Could not preserve directory timestamps."

        if [ "$(id -u)" -eq 0 ]; then
            chown --reference="$source_dir" "$dest_dir" 2>/dev/null ||
                log_entry WARNING "$relative/" "Could not preserve directory ownership."
        fi
    done < <(
        find "$SOURCE_ROOT" -path "$DEST_ROOT" -prune -o -type d -print0
    )
}

#Copy files
copy_file() {
    local input="$1" output="$2" relative="$3" partial
    local scan_seconds="${scan_seconds:-0}" encode_seconds="${encode_seconds:-0}" verify_seconds="${verify_seconds:-0}"

    if [ -e "$output" ] && [ "$OVERWRITE" != "1" ] && [ "$FORCE_CURRENT_OUTPUT" != "1" ]; then
        echo "SKIP : $relative"
        ((skipped+=1))
        return 0
    fi

    mkdir -p "$(dirname "$output")"
    partial="$(make_partial_path "$output")" || {
        log_entry ERROR "$relative" "Could not create a temporary output file."
        ((failed+=1))
        return 1
    }
    CURRENT_PARTIAL="$partial"

    if ! cp --preserve=all -- "$input" "$partial" 2>/dev/null; then
        rm -f -- "$partial"
        partial="$(make_partial_path "$output")" || {
            CURRENT_PARTIAL=""
            log_entry ERROR "$relative" "Could not create a fallback temporary output file."
            ((failed+=1))
            return 1
        }
        CURRENT_PARTIAL="$partial"

        if cp -p -- "$input" "$partial"; then
            log_entry WARNING "$relative" \
                "File was copied, but not all Linux filesystem attributes could be preserved."
        else
            echo "ERROR: copy failed: $relative"
            log_entry ERROR "$relative" \
                "Filesystem copy failed." \
                "Source: $input" \
                "Destination: $output"
            rm -f -- "$partial"
            CURRENT_PARTIAL=""
            ((failed+=1))
            return 1
        fi
    fi

    if mv -f -- "$partial" "$output"; then
        CURRENT_PARTIAL=""

        # If a previous run produced an alternate MKV derivative and this run
        # intentionally kept the original, remove that stale alternate result.
        if [ -n "$CURRENT_EXPECTED_TRANSCODE" ] &&
           [ "$CURRENT_EXPECTED_TRANSCODE" != "$output" ] &&
           { [ "$FORCE_CURRENT_OUTPUT" = "1" ] || [ "$OVERWRITE" = "1" ]; }; then
            rm -f -- "$CURRENT_EXPECTED_TRANSCODE" 2>/dev/null || true
        fi

        echo "COPY : $relative"
        ((copied+=1))
        write_completed_state "$input" "$output" "$relative" "copied-original" 0 \
            "$scan_seconds" "$encode_seconds" "$verify_seconds"
        return 0
    else
        log_entry ERROR "$relative" "Atomic rename into the final destination failed."
        rm -f -- "$partial"
        CURRENT_PARTIAL=""
        ((failed+=1))
        return 1
    fi
}

#Generate manifests
generate_manifests() {
    [ "$CHECKSUMS" = "1" ] || return 0

    local src_tmp out_tmp
    echo "Generating SHA-256 manifests..."

    src_tmp="$(mktemp -p "$DEST_ROOT" ".source-sha256.$$.XXXXXX")" || {
        log_entry ERROR SCRIPT "Could not create temporary source checksum manifest."
        ((failed+=1))
        return
    }

    if (
        cd "$SOURCE_ROOT" || exit 1
        if [[ "$DEST_ROOT/" == "$SOURCE_ROOT/"* ]]; then
            dest_rel="./${DEST_ROOT#"$SOURCE_ROOT"/}"
            find . -path "$dest_rel" -prune -o -type f -print0
        else
            find . -type f -print0
        fi |
            sort -z |
            xargs -0 -r sha256sum
    ) > "$src_tmp"; then
        mv -f -- "$src_tmp" "$SOURCE_MANIFEST"
    else
        rm -f -- "$src_tmp"
        log_entry ERROR SCRIPT "Failed to generate source SHA-256 manifest."
        ((failed+=1))
    fi

    out_tmp="$(mktemp -p "$DEST_ROOT" ".output-sha256.$$.XXXXXX")" || {
        log_entry ERROR SCRIPT "Could not create temporary output checksum manifest."
        ((failed+=1))
        return
    }

    if (
        cd "$DEST_ROOT" &&
        find . -path './.h265-state' -prune -o -type f \
            ! -name 'conversion_warnings.log' \
            ! -name 'source_sha256.txt' \
            ! -name 'output_sha256.txt' \
            ! -name '.conversion.lock' \
            ! -name '.h265-partial.*' \
            ! -name '.source-sha256.*' \
            ! -name '.output-sha256.*' \
            -print0 |
            sort -z |
            xargs -0 -r sha256sum
    ) > "$out_tmp"; then
        mv -f -- "$out_tmp" "$OUTPUT_MANIFEST"
    else
        rm -f -- "$out_tmp"
        log_entry ERROR SCRIPT "Failed to generate output SHA-256 manifest."
        ((failed+=1))
    fi
}