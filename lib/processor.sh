 #!/usr/bin/env bash

# This script handles the proccessing of each file for the control script,
# and should not be run directly

process_file() {
    local input="$1"
    local relative="${input#"$SOURCE_ROOT"/}"
    local copy_output="$DEST_ROOT/$relative"
    local output probe probe_status h264_found=0 hevc_found=0 line
    local -a video_streams ffmpeg_args output_streams structure_warnings
    local -a convert src_w src_h src_sar src_dar src_pix src_trc src_prim src_space
    local -a check_hdr check_master check_light
    local unsafe=0 i bit_depth hdr mastering content_light source_codec
    local x265_params duration_us tmp encode_ok out_probe out_status
    local out_master out_light fmt src_hash out_hash partial
    local has_dovi=0 has_hdr10p=0 has_other_dynamic=0 dynamic_transcode=0
    local workdir="" source_raw="" hdr10_json="" out_hdr10_json="" out_raw=""
    local dovi_profile=0 dovi_el=0 dovi_rpu_present=0 dovi_compat=-1
    local dovi_native=0 dovi_p7_mel=0 dovi_rpu="" dovi_orig_rpu="" dovi_subprofile=""
    local dovi_frames_in="" dovi_frames_out="" verify_rpu=""
    local encoded_raw="" injected_raw="" remuxed="" avg_fps="" r_fps="" start_time="" disposition=""
    local source_size="" encoded_size="" savings_pct="" saved_bytes=0
    local state hdr_cache=0 hdr_flags="" hdr_scan_status=0
    local scan_seconds=0 encode_seconds=0 verify_seconds=0 phase_started=0 file_started=$SECONDS

    CURRENT_VERIFY_FATAL=0
    FORCE_CURRENT_OUTPUT=0
    CURRENT_HDR_SCAN_COMPLETE=0
    CURRENT_HAS_DOVI=0
    CURRENT_HAS_HDR10P=0
    CURRENT_HAS_OTHER_DYNAMIC=0

    output="$(transcode_output_path "$relative")"
    CURRENT_EXPECTED_TRANSCODE="$output"
    state="$(state_path_for "$relative")"

    CURRENT_SOURCE_FINGERPRINT="$(source_fingerprint "$input")"
    source_size="$(stat -c '%s' -- "$input" 2>/dev/null || true)"
    if [ -z "$CURRENT_SOURCE_FINGERPRINT" ] || ! [[ "$source_size" =~ ^[0-9]+$ ]]; then
        log_entry ERROR "$relative" "Could not read source filesystem fingerprint/size."
        ((failed+=1))
        return
    fi

    # A file is skipped only when its state record proves that the same source,
    # relevant settings, and (optionally) toolchain already produced a verified
    # final output.  Mere output-file existence is no longer trusted.
    if [ "$OVERWRITE" != "1" ] && state_is_current "$state" "$copy_output" "$output"; then
        echo "SKIP : $relative (verified state)"
        ((skipped+=1))
        bytes_saved_total=$((bytes_saved_total + STATE_SAVED_BYTES))
        return
    fi

    # Even when settings changed and the file must be reconsidered, a prior
    # exhaustive HDR scan can be reused safely as long as the source fingerprint
    # is unchanged.
    if load_hdr_cache "$state"; then
        hdr_cache=1
        has_dovi="$CURRENT_HAS_DOVI"
        has_hdr10p="$CURRENT_HAS_HDR10P"
        has_other_dynamic="$CURRENT_HAS_OTHER_DYNAMIC"
    fi

    # Existing outputs without a matching completed state are treated as stale.
    # They are not deleted now; the atomic workflow replaces them only after a
    # successful new copy/transcode, so a failed rerun cannot destroy old data.
    if [ -e "$copy_output" ] || { [ "$output" != "$copy_output" ] && [ -e "$output" ]; }; then
        FORCE_CURRENT_OUTPUT=1
        log_entry WARNING "$relative" \
            "Existing destination file does not match the current processing state/settings." \
            "It will be replaced only if this run completes safely."
    fi

    probe="$(
        ffprobe -v error -select_streams v \
            -show_entries stream=codec_name,pix_fmt,width,height,sample_aspect_ratio,display_aspect_ratio,color_range,color_space,color_transfer,color_primaries \
            -of compact=p=0:nk=0 "$input" 2>/dev/null
    )"
    probe_status=$?

    if [ "$probe_status" -ne 0 ] || [ -z "$probe" ]; then
        copy_file "$input" "$copy_output" "$relative"
        return
    fi

    mapfile -t video_streams <<< "$probe"

    for line in "${video_streams[@]}"; do
        parse_stream "$line"
        [ "$codec" = "h264" ] && h264_found=1
        [ "$codec" = "hevc" ] && hevc_found=1
    done

    # Before any exhaustive HDR scan or encode, verify that the destination has
    # enough free space to hold a source-sized temporary result plus reserve.
    if [ "$h264_found" -eq 1 ] || { [ "$DYNAMIC_HDR" = "transcode" ] && [ "$hevc_found" -eq 1 ]; }; then
        if ! check_free_space "$input" "$(dirname "$output")" "$relative"; then
            echo "FAILED (free space): $relative"
            ((failed+=1))
            return
        fi
    fi

    # H.264 must be screened for dynamic HDR before re-encoding. In opt-in
    # dynamic-HDR mode, HEVC is screened too.  Reuse a cached exhaustive result
    # when the source fingerprint proves the file has not changed.
    if [ "$h264_found" -eq 1 ] || { [ "$DYNAMIC_HDR" = "transcode" ] && [ "$hevc_found" -eq 1 ]; }; then

    # If a valid scan result already exists for this exact source,
    # reuse it even when SKIP_HDR_SCAN=1. Reusing cached results
    # does not require scanning the media again.
    if [ "$hdr_cache" -eq 1 ]; then

        echo "HDR scan: $relative (cached)"

    # Explicitly skip the expensive exhaustive scan.
    elif [ "$SKIP_HDR_SCAN" = "1" ]; then

        echo "HDR scan: $relative (skipped)"

        log_entry WARNING "$relative" \
            "Exhaustive dynamic-HDR scan skipped because SKIP_HDR_SCAN=1." \
            "Dolby Vision/HDR10+ metadata may therefore go undetected."

        # No dynamic HDR has been detected because no scan was performed.
        has_dovi=0
        has_hdr10p=0
        has_other_dynamic=0

        # Do NOT mark this as a completed HDR scan.
        # This ensures that if HDR scanning is enabled later,
        # the file can still receive a real exhaustive scan.
        CURRENT_HDR_SCAN_COMPLETE=0
        CURRENT_HAS_DOVI=0
        CURRENT_HAS_HDR10P=0
        CURRENT_HAS_OTHER_DYNAMIC=0

    else

        phase_started=$SECONDS

        hdr_flags="$(get_dynamic_hdr_flags "$input" "$relative")"
        hdr_scan_status=$?

        scan_seconds=$((SECONDS - phase_started))

        if [ "$hdr_scan_status" -ne 0 ] ||
           ! [[ "$hdr_flags" =~ ^[01][[:space:]][01][[:space:]][01]$ ]]; then

            log_entry WARNING "$relative" \
                "Exhaustive dynamic-HDR scan failed or returned an invalid result." \
                "The source was copied unchanged rather than risking dynamic-metadata loss."

            copy_file "$input" "$copy_output" "$relative"
            return
        fi

        read -r has_dovi has_hdr10p has_other_dynamic <<< "$hdr_flags"

        CURRENT_HDR_SCAN_COMPLETE=1
        CURRENT_HAS_DOVI="$has_dovi"
        CURRENT_HAS_HDR10P="$has_hdr10p"
        CURRENT_HAS_OTHER_DYNAMIC="$has_other_dynamic"

        write_scan_state "$input" "$relative" "$scan_seconds"
    fi
fi

    if [ "$has_dovi" -eq 1 ] || [ "$has_hdr10p" -eq 1 ] || [ "$has_other_dynamic" -eq 1 ]; then
        if [ "$DYNAMIC_HDR" = "copy" ]; then
            log_entry WARNING "$relative" \
                "Dynamic HDR metadata detected (Dolby Vision/HDR10+ or related metadata)." \
                "DYNAMIC_HDR=copy: file was copied unchanged for archival safety."
            copy_file "$input" "$copy_output" "$relative"
            return
        fi

        # Dynamic metadata is currently handled only when it belongs to one
        # primary HEVC video stream. Ambiguous multi-video files are preserved.
        if [ "${#video_streams[@]}" -ne 1 ]; then
            log_entry WARNING "$relative" \
                "Dynamic HDR was detected in a file with ${#video_streams[@]} video streams." \
                "Automatic metadata mapping would be ambiguous; file was copied unchanged."
            copy_file "$input" "$copy_output" "$relative"
            return
        fi

        parse_stream "${video_streams[0]}"
        source_codec="$codec"

        if [ "$source_codec" != "hevc" ]; then
            log_entry WARNING "$relative" \
                "Dynamic HDR re-encoding currently supports HEVC sources only; source codec is $source_codec." \
                "File was copied unchanged."
            copy_file "$input" "$copy_output" "$relative"
            return
        fi

        workdir="$(mktemp -d)" || {
            log_entry ERROR "$relative" "Could not create dynamic-HDR working directory."
            ((failed+=1))
            return
        }
        CURRENT_WORKDIR="$workdir"
        source_raw="$workdir/source.hevc"

        # HDR10+ metadata is extracted once and passed directly to x265 during
        # encoding so timestamps and all other container streams remain in the
        # normal FFmpeg workflow.
        if [ "$has_hdr10p" -eq 1 ]; then
            if ! command -v hdr10plus_tool >/dev/null 2>&1; then
                log_entry WARNING "$relative" \
                    "HDR10+ detected, but hdr10plus_tool is not installed." \
                    "File was copied unchanged."
                rm -rf -- "$workdir"; CURRENT_WORKDIR=""
                copy_file "$input" "$copy_output" "$relative"
                return
            fi

            if ! extract_hevc_raw "$input" "$source_raw"; then
                log_entry WARNING "$relative" \
                    "HDR10+ source HEVC could not be extracted for metadata processing." \
                    "File was copied unchanged."
                rm -rf -- "$workdir"; CURRENT_WORKDIR=""
                copy_file "$input" "$copy_output" "$relative"
                return
            fi

            hdr10_json="$workdir/hdr10plus.json"
            if ! extract_hdr10plus_json "$source_raw" "$hdr10_json"; then
                log_entry WARNING "$relative" \
                    "HDR10+ metadata was detected but hdr10plus_tool could not extract it." \
                    "File was copied unchanged."
                rm -rf -- "$workdir"; CURRENT_WORKDIR=""
                copy_file "$input" "$copy_output" "$relative"
                return
            fi
        fi

        # Dolby Vision Profiles 5 and 8 use FFmpeg/libx265's native RPU coding.
        # Profile 7 needs special treatment because its enhancement-layer
        # profile cannot be directly encoded by libx265.
        if [ "$has_dovi" -eq 1 ]; then
            read -r dovi_profile dovi_el dovi_rpu_present dovi_compat < <(get_dovi_info "$input")

            case "$dovi_profile" in
                5|8)
                    if [ "$HAS_DOLBYVISION" -ne 1 ]; then
                        log_entry WARNING "$relative" \
                            "Dolby Vision Profile $dovi_profile detected, but this FFmpeg/libx265 build does not expose Dolby Vision RPU coding." \
                            "File was copied unchanged."
                        rm -rf -- "$workdir"; CURRENT_WORKDIR=""
                        copy_file "$input" "$copy_output" "$relative"
                        return
                    fi
                    dovi_native=1

                    # dovi_tool is optional for Profiles 5/8. When present,
                    # preserve an independent source RPU snapshot so the
                    # regenerated output RPU can be semantically compared.
                    if command -v dovi_tool >/dev/null 2>&1; then
                        [ -s "$source_raw" ] || extract_hevc_raw "$input" "$source_raw" || true
                        if [ -s "$source_raw" ]; then
                            dovi_orig_rpu="$workdir/RPU_original.bin"
                            if dovi_tool extract-rpu "$source_raw" -o "$dovi_orig_rpu" >/dev/null 2>&1 && [ -s "$dovi_orig_rpu" ]; then
                                dovi_frames_in="$(get_dovi_frame_count "$dovi_orig_rpu")"
                            else
                                dovi_orig_rpu=""
                            fi
                        fi
                    fi
                    ;;

                7)
                    if ! command -v dovi_tool >/dev/null 2>&1; then
                        log_entry WARNING "$relative" \
                            "Dolby Vision Profile 7 detected, but dovi_tool is not installed." \
                            "File was copied unchanged."
                        rm -rf -- "$workdir"; CURRENT_WORKDIR=""
                        copy_file "$input" "$copy_output" "$relative"
                        return
                    fi

                    if ! command -v cmp >/dev/null 2>&1; then
                        log_entry WARNING "$relative" \
                            "Dolby Vision Profile 7 processing requires cmp for RPU verification." \
                            "File was copied unchanged."
                        rm -rf -- "$workdir"; CURRENT_WORKDIR=""
                        copy_file "$input" "$copy_output" "$relative"
                        return
                    fi

                    if [ "$CONTAINER" != "mkv" ]; then
                        log_entry WARNING "$relative" \
                            "Dolby Vision Profile 7 MEL conversion requires CONTAINER=mkv in this script." \
                            "File was copied unchanged."
                        rm -rf -- "$workdir"; CURRENT_WORKDIR=""
                        copy_file "$input" "$copy_output" "$relative"
                        return
                    fi

                    [ -s "$source_raw" ] || extract_hevc_raw "$input" "$source_raw" || {
                        log_entry WARNING "$relative" "Could not extract Profile 7 HEVC; file was copied unchanged."
                        rm -rf -- "$workdir"; CURRENT_WORKDIR=""
                        copy_file "$input" "$copy_output" "$relative"
                        return
                    }

                    dovi_orig_rpu="$workdir/RPU_original.bin"
                    if ! dovi_tool extract-rpu "$source_raw" -o "$dovi_orig_rpu" >/dev/null 2>&1 || [ ! -s "$dovi_orig_rpu" ]; then
                        log_entry WARNING "$relative" "Could not extract Dolby Vision Profile 7 RPU; file was copied unchanged."
                        rm -rf -- "$workdir"; CURRENT_WORKDIR=""
                        copy_file "$input" "$copy_output" "$relative"
                        return
                    fi

                    dovi_subprofile="$(get_dovi_subprofile "$dovi_orig_rpu")"
                    if [ "$dovi_subprofile" = "FEL" ]; then
                        log_entry WARNING "$relative" \
                            "Dolby Vision Profile 7 FEL detected." \
                            "The FEL residual contribution cannot be safely preserved by this generic re-encode, so the file was copied unchanged."
                        rm -rf -- "$workdir"; CURRENT_WORKDIR=""
                        copy_file "$input" "$copy_output" "$relative"
                        return
                    elif [ "$dovi_subprofile" != "MEL" ]; then
                        log_entry WARNING "$relative" \
                            "Dolby Vision Profile 7 was detected, but MEL/FEL could not be identified confidently." \
                            "File was copied unchanged."
                        rm -rf -- "$workdir"; CURRENT_WORKDIR=""
                        copy_file "$input" "$copy_output" "$relative"
                        return
                    fi

                    # Restrict the P7 MEL path to CFR/zero-start material so
                    # regenerating timestamps from the injected raw HEVC cannot
                    # silently create A/V sync changes.
                    read -r avg_fps r_fps start_time < <(get_video_timing "$input")
                    if [ -z "$avg_fps" ] || [ "$avg_fps" = "0/0" ] || [ "$avg_fps" != "$r_fps" ]; then
                        log_entry WARNING "$relative" \
                            "Dolby Vision Profile 7 MEL source is not confidently CFR." \
                            "File was copied unchanged to avoid timestamp/sync changes."
                        rm -rf -- "$workdir"; CURRENT_WORKDIR=""
                        copy_file "$input" "$copy_output" "$relative"
                        return
                    fi
                    if [[ "$start_time" =~ ^-?[0-9]+([.][0-9]+)?$ ]] && ! awk -v x="$start_time" 'BEGIN{exit (x > -0.001 && x < 0.001) ? 0 : 1}'; then
                        log_entry WARNING "$relative" \
                            "Dolby Vision Profile 7 MEL video has non-zero start time $start_time." \
                            "File was copied unchanged to avoid A/V sync changes."
                        rm -rf -- "$workdir"; CURRENT_WORKDIR=""
                        copy_file "$input" "$copy_output" "$relative"
                        return
                    fi

                    dovi_rpu="$workdir/RPU_P81.bin"
                    if ! dovi_tool -m 2 extract-rpu "$source_raw" -o "$dovi_rpu" >/dev/null 2>&1 || [ ! -s "$dovi_rpu" ]; then
                        log_entry WARNING "$relative" \
                            "Could not convert Profile 7 MEL RPU to Profile 8.1." \
                            "File was copied unchanged."
                        rm -rf -- "$workdir"; CURRENT_WORKDIR=""
                        copy_file "$input" "$copy_output" "$relative"
                        return
                    fi
                    dovi_p7_mel=1
                    ;;

                *)
                    log_entry WARNING "$relative" \
                        "Dolby Vision was detected, but profile $dovi_profile is not supported by the automatic re-encode path." \
                        "File was copied unchanged."
                    rm -rf -- "$workdir"; CURRENT_WORKDIR=""
                    copy_file "$input" "$copy_output" "$relative"
                    return
                    ;;
            esac
        fi

        # If the scan saw only an unrecognized dynamic-HDR type, don't guess.
        if [ "$has_dovi" -eq 0 ] && [ "$has_hdr10p" -eq 0 ] && [ "$has_other_dynamic" -eq 1 ]; then
            log_entry WARNING "$relative" \
                "Unrecognized dynamic HDR metadata detected." \
                "File was copied unchanged because no safe metadata-aware workflow was identified."
            rm -rf -- "$workdir"; CURRENT_WORKDIR=""
            copy_file "$input" "$copy_output" "$relative"
            return
        fi

        dynamic_transcode=1
    elif [ "$h264_found" -eq 0 ]; then
        copy_file "$input" "$copy_output" "$relative"
        return
    fi

    # $output was resolved and checked before probing/HDR scanning.
    mkdir -p "$(dirname "$output")"

    echo
    if [ "$dynamic_transcode" -eq 1 ]; then
        echo "CONVERT DYNAMIC HDR: $relative"
    else
        echo "CONVERT: $relative"
    fi

    ffmpeg_args=(
        -hide_banner -y
        -i "$input"
        -map 0
        -c copy
        -map_metadata 0
        -map_chapters 0
        -copy_unknown
    )

    for i in "${!video_streams[@]}"; do
        parse_stream "${video_streams[$i]}"

        convert[$i]=0
        src_w[$i]="$width"; src_h[$i]="$height"
        src_sar[$i]="$sar"; src_dar[$i]="$dar"
        src_pix[$i]="$pix_fmt"; src_trc[$i]="$color_transfer"
        src_prim[$i]="$color_primaries"; src_space[$i]="$color_space"
        check_hdr[$i]=0; check_master[$i]=0; check_light[$i]=0

        if [ "$dynamic_transcode" -eq 1 ]; then
            [ "$i" -eq 0 ] || continue
        else
            [ "$codec" = "h264" ] || continue
        fi
        convert[$i]=1
        source_codec="$codec"

        case "$pix_fmt" in
            *422*|*444*|gbr*)
                log_entry WARNING "$relative" \
                    "Video stream v:$i uses $pix_fmt." \
                    "File was copied unchanged to avoid chroma loss."
                unsafe=1; break ;;
            *12*|*14*|*16*)
                log_entry WARNING "$relative" \
                    "Video stream v:$i uses $pix_fmt." \
                    "File was copied unchanged to avoid bit-depth loss."
                unsafe=1; break ;;
        esac

        bit_depth=8
        case "$pix_fmt" in *9*|*10*|p010*) bit_depth=10 ;; esac

        hdr=0
        case "$color_transfer" in smpte2084|arib-std-b67) hdr=1 ;; esac
        if [ "$color_primaries" = "bt2020" ] && [ "$bit_depth" -eq 10 ]; then hdr=1; fi
        read -r mastering content_light < <(get_hdr_side_data "$input" "$i")
        if [ "$mastering" -eq 1 ] || [ "$content_light" -eq 1 ]; then hdr=1; fi
        [ "$dynamic_transcode" -eq 1 ] && hdr=1

        check_hdr[$i]="$hdr"; check_master[$i]="$mastering"; check_light[$i]="$content_light"

        if [ "$hdr" -eq 1 ] && [ "$bit_depth" -ne 10 ]; then
            log_entry WARNING "$relative" \
                "HDR signalling detected on v:$i, but source pixel format is $pix_fmt." \
                "File was copied unchanged for archival safety."
            unsafe=1; break
        fi

        echo "  v:$i ${source_codec^^} ${bit_depth}-bit -> libx265 (${width}x${height})"

        ffmpeg_args+=("-c:v:$i" libx265 "-preset:v:$i" "$PRESET")
        [ -n "$TUNE" ] && ffmpeg_args+=("-tune:v:$i" "$TUNE")
        [ "$HAS_A53CC" -eq 1 ] && ffmpeg_args+=("-a53cc:v:$i" 1)
        [ "$HAS_UDU_SEI" -eq 1 ] && ffmpeg_args+=("-udu_sei:v:$i" 1)
        [ "$dovi_native" -eq 1 ] && [ "$i" -eq 0 ] && ffmpeg_args+=("-dolbyvision:v:$i" 1)

        if [ "$bit_depth" -eq 10 ]; then
            ffmpeg_args+=("-pix_fmt:v:$i" yuv420p10le "-profile:v:$i" main10)
        else
            ffmpeg_args+=("-pix_fmt:v:$i" yuv420p "-profile:v:$i" main)
        fi

        x265_params="repeat-headers=1"
        if [ "$LOSSLESS" = "1" ]; then
            x265_params="${x265_params}:lossless=1"
        else
            ffmpeg_args+=("-crf:v:$i" "$CRF")
        fi

        # Profile 5 is Dolby Vision IPT-PQ rather than an HDR10-compatible
        # base layer, so don't force x265's HDR10 flag for Profile 5.
        if [ "$hdr" -eq 1 ] && [ "$color_transfer" = "smpte2084" ] && [ "$dovi_profile" -ne 5 ]; then
            x265_params="${x265_params}:hdr10=1"
            [ "$LOSSLESS" != "1" ] && x265_params="${x265_params}:hdr10-opt=1"
        fi

        if [ "$has_hdr10p" -eq 1 ] && [ "$i" -eq 0 ]; then
            x265_params="${x265_params}:dhdr10-info=${hdr10_json}"
            [ "$LOSSLESS" != "1" ] && x265_params="${x265_params}:dhdr10-opt=1"
        fi

        ffmpeg_args+=("-x265-params:v:$i" "$x265_params")

        valid_colour "$color_primaries" && ffmpeg_args+=("-color_primaries:v:$i" "$color_primaries")
        valid_colour "$color_transfer" && ffmpeg_args+=("-color_trc:v:$i" "$color_transfer")
        valid_colour "$color_space" && ffmpeg_args+=("-colorspace:v:$i" "$color_space")
        valid_colour "$color_range" && ffmpeg_args+=("-color_range:v:$i" "$color_range")
    done

    if [ "$unsafe" -eq 1 ]; then
        [ -n "$workdir" ] && rm -rf -- "$workdir"
        CURRENT_WORKDIR=""
        copy_file "$input" "$copy_output" "$relative"
        return
    fi

    partial="$(make_partial_path "$output")" || {
        log_entry ERROR "$relative" "Could not create temporary output for atomic conversion."
        [ -n "$workdir" ] && rm -rf -- "$workdir"
        CURRENT_WORKDIR=""
        ((failed+=1)); return
    }
    CURRENT_PARTIAL="$partial"

    duration_us="$(get_duration_us "$input")"
    ffmpeg_args+=( -max_muxing_queue_size 4096 -nostdin -nostats -stats_period 0.5 -progress pipe:1 "$partial" )

    tmp="$(mktemp)"
    CURRENT_FFMPEG_LOG="$tmp"
    phase_started=$SECONDS

    if [ "$duration_us" -gt 0 ]; then
        if ffmpeg "${ffmpeg_args[@]}" 2>"$tmp" | render_ffmpeg_progress "$duration_us"; then
            encode_ok=1
        else
            encode_ok=0; printf '\n'
        fi
    else
        echo "Encoding: duration unavailable"
        if ffmpeg "${ffmpeg_args[@]}" >/dev/null 2>"$tmp"; then encode_ok=1; else encode_ok=0; fi
    fi

    encode_seconds=$((SECONDS - phase_started))

    if [ "$encode_ok" -ne 1 ]; then
        echo "FAILED: $relative"
        log_ffmpeg_error "$relative" "$tmp"
        rm -f -- "$tmp" "$partial"
        [ -n "$workdir" ] && rm -rf -- "$workdir"
        CURRENT_FFMPEG_LOG=""; CURRENT_PARTIAL=""; CURRENT_WORKDIR=""
        ((failed+=1)); return
    fi
    rm -f -- "$tmp"; CURRENT_FFMPEG_LOG=""

    # Profile 7 MEL: convert the RPU to Profile 8.1, inject it into the newly
    # encoded HEVC stream, then rebuild the MKV while copying every non-video
    # stream, chapters and metadata from the preliminary encode.
    if [ "$dovi_p7_mel" -eq 1 ]; then
        encoded_raw="$workdir/encoded.hevc"
        injected_raw="$workdir/injected_p81.hevc"
        remuxed="$workdir/remuxed.mkv"

        if ! extract_hevc_raw "$partial" "$encoded_raw" ||
           ! dovi_tool inject-rpu -i "$encoded_raw" --rpu-in "$dovi_rpu" -o "$injected_raw" >/dev/null 2>&1; then
            verification_issue "$relative" \
                "Profile 7 MEL video encoded, but Profile 8.1 RPU injection failed." \
                "Dolby Vision preservation could not be verified."
        else
            disposition="$(get_video_disposition "$partial")"
            if ffmpeg -v error -nostdin -y -r "$avg_fps" -i "$injected_raw" -i "$partial" \
                -map 0:v:0 -map 1 -map -1:v \
                -c copy -map_metadata 1 -map_chapters 1 \
                -map_metadata:s:v:0 1:s:v:0 -disposition:v:0 "$disposition" \
                -copy_unknown "$remuxed"; then
                mv -f -- "$remuxed" "$partial"

                verify_rpu="$workdir/RPU_verify.bin"
                out_raw="$workdir/output_p81.hevc"
                if extract_hevc_raw "$partial" "$out_raw" &&
                   dovi_tool extract-rpu "$out_raw" -o "$verify_rpu" >/dev/null 2>&1 &&
                   [ -s "$verify_rpu" ]; then
                    if ! cmp -s "$dovi_rpu" "$verify_rpu"; then
                        verification_issue "$relative" \
                            "Profile 8.1 RPU was present after remux, but its binary payload differs from the converted source RPU."
                    fi
                else
                    verification_issue "$relative" \
                        "Profile 8.1 RPU could not be re-extracted from the final temporary output."
                fi
            else
                verification_issue "$relative" \
                    "Profile 8.1 RPU injection succeeded, but rebuilding the MKV failed." \
                    "Dolby Vision metadata could not be guaranteed."
            fi
        fi
    fi

    # Measure the completed candidate before expensive verification.  This size
    # is also used for cumulative storage-saved accounting even when the size
    # gate itself is disabled.
    if ! encoded_size="$(stat -c '%s' -- "$partial" 2>/dev/null)" || ! [[ "$encoded_size" =~ ^[0-9]+$ ]]; then
        log_entry WARNING "$relative" \
            "Could not determine the transcoded file size." \
            "The transcode was discarded and the original was copied unchanged."
        rm -f -- "$partial"
        CURRENT_PARTIAL=""
        [ -n "$workdir" ] && rm -rf -- "$workdir"
        CURRENT_WORKDIR=""
        ((size_rejected+=1))
        copy_file "$input" "$copy_output" "$relative"
        return
    fi

    saved_bytes=$((source_size - encoded_size))
    savings_pct="$(size_saving_percent "$source_size" "$encoded_size")"

    # Discard a successful transcode when it does not save enough storage.
    # For sources at least ABS_SAVING_MIN_SOURCE_MIB MiB in size, both the
    # percentage target and the absolute MiB target must be satisfied.
    if [ "$KEEP_ONLY_IF_SMALLER" = "1" ]; then
        if ! meets_size_saving_target "$source_size" "$encoded_size" \
            "$MIN_SIZE_SAVING_PERCENT" "$MIN_SIZE_SAVING_MIB" "$ABS_SAVING_MIN_SOURCE_MIB"; then
            echo
            echo "SIZE GATE: $relative"
            echo "  Original : $(human_bytes "$source_size") ($source_size bytes)"
            echo "  H.265    : $(human_bytes "$encoded_size") ($encoded_size bytes)"
            echo "  Saving   : ${savings_pct}% ($(human_bytes "$saved_bytes"))"
            echo "  Required : ${MIN_SIZE_SAVING_PERCENT}%"
            if awk -v b="$source_size" -v mib="$ABS_SAVING_MIN_SOURCE_MIB" 'BEGIN { exit (b >= mib * 1048576) ? 0 : 1 }'; then
                echo "  Also need: ${MIN_SIZE_SAVING_MIB} MiB absolute saving"
            fi
            echo "  Keeping original instead."

            log_entry WARNING "$relative" \
                "H.265 conversion did not meet the storage-saving threshold." \
                "Original size: $source_size bytes" \
                "H.265 size: $encoded_size bytes" \
                "Actual saving: ${savings_pct}% ($(human_bytes "$saved_bytes"))" \
                "Required percentage saving: ${MIN_SIZE_SAVING_PERCENT}%" \
                "Absolute saving requirement for sources >= ${ABS_SAVING_MIN_SOURCE_MIB} MiB: ${MIN_SIZE_SAVING_MIB} MiB" \
                "The H.265 transcode was discarded and the original was copied unchanged."

            rm -f -- "$partial"
            CURRENT_PARTIAL=""
            [ -n "$workdir" ] && rm -rf -- "$workdir"
            CURRENT_WORKDIR=""
            ((size_rejected+=1))
            copy_file "$input" "$copy_output" "$relative"
            return
        fi

        echo "SIZE OK: ${savings_pct}% smaller ($(human_bytes "$saved_bytes") saved)"
    fi

    phase_started=$SECONDS

    # Dynamic-HDR verification is deliberately independent of the encode path.
    if [ "$has_hdr10p" -eq 1 ]; then
        out_raw="$workdir/output_hdr10plus.hevc"
        out_hdr10_json="$workdir/hdr10plus_output.json"
        if extract_hevc_raw "$partial" "$out_raw" && extract_hdr10plus_json "$out_raw" "$out_hdr10_json"; then
            if ! compare_hdr10plus_json "$hdr10_json" "$out_hdr10_json"; then
                verification_issue "$relative" \
                    "HDR10+ metadata is present after encoding, but extracted dynamic metadata differs from the source."
            fi
        else
            verification_issue "$relative" \
                "HDR10+ metadata could not be extracted from the encoded output; preservation is not confirmed."
        fi
    fi

    if [ "$has_dovi" -eq 1 ] && [ "$dovi_p7_mel" -eq 0 ]; then
        local out_dp out_de out_dr out_dc
        read -r out_dp out_de out_dr out_dc < <(get_dovi_info "$partial")
        if [ "$out_dp" -eq 0 ] || [ "$out_dr" -ne 1 ]; then
            verification_issue "$relative" \
                "Dolby Vision configuration/RPU was not detected in the encoded output."
        elif [ "$dovi_profile" -eq 5 ] && [ "$out_dp" -ne 5 ]; then
            verification_issue "$relative" "Dolby Vision profile changed unexpectedly: 5 -> $out_dp."
        elif [ "$dovi_profile" -eq 8 ] && [ "$out_dp" -ne 8 ]; then
            verification_issue "$relative" "Dolby Vision profile changed unexpectedly: 8 -> $out_dp."
        fi

        if [ -n "$dovi_orig_rpu" ] && command -v dovi_tool >/dev/null 2>&1; then
            out_raw="$workdir/output_dovi.hevc"
            verify_rpu="$workdir/RPU_output.bin"
            if extract_hevc_raw "$partial" "$out_raw" &&
               dovi_tool extract-rpu "$out_raw" -o "$verify_rpu" >/dev/null 2>&1 &&
               [ -s "$verify_rpu" ]; then
                dovi_frames_out="$(get_dovi_frame_count "$verify_rpu")"
                if [ -n "$dovi_frames_in" ] && [ -n "$dovi_frames_out" ] && [ "$dovi_frames_in" != "$dovi_frames_out" ]; then
                    verification_issue "$relative" \
                        "Dolby Vision RPU frame count changed: $dovi_frames_in -> $dovi_frames_out."
                fi
                compare_dovi_rpu_semantic "$dovi_orig_rpu" "$verify_rpu" "$workdir"
                local dovi_compare_status=$?
                case "$dovi_compare_status" in
                    0) ;;
                    1) verification_issue "$relative" \
                           "Dolby Vision RPU is present, but its exported metadata differs from the source RPU." ;;
                    *) verification_issue "$relative" \
                           "Dolby Vision RPU semantic comparison could not be completed." ;;
                esac
            else
                verification_issue "$relative" \
                    "Dolby Vision output RPU could not be independently extracted with dovi_tool."
            fi
        fi
    elif [ "$dovi_p7_mel" -eq 1 ]; then
        local out_dp out_de out_dr out_dc
        read -r out_dp out_de out_dr out_dc < <(get_dovi_info "$partial")
        if [ "$out_dp" -ne 8 ] || [ "$out_dr" -ne 1 ]; then
            verification_issue "$relative" \
                "Profile 7 MEL conversion did not verify as single-layer Dolby Vision Profile 8 with RPU present."
        fi
    fi

    out_probe="$(
        ffprobe -v error -select_streams v \
            -show_entries stream=codec_name,pix_fmt,width,height,sample_aspect_ratio,display_aspect_ratio,color_range,color_space,color_transfer,color_primaries \
            -of compact=p=0:nk=0 "$partial" 2>/dev/null
    )"
    out_status=$?

    if [ "$out_status" -ne 0 ] || [ -z "$out_probe" ]; then
        verification_issue "$relative" "ffprobe could not inspect the completed temporary output."
    else
        mapfile -t output_streams <<< "$out_probe"
        for i in "${!video_streams[@]}"; do
            [ "${convert[$i]:-0}" -eq 1 ] || continue
            if [ "$i" -ge "${#output_streams[@]}" ]; then
                verification_issue "$relative" "Output video stream v:$i is missing."
                continue
            fi
            parse_stream "${output_streams[$i]}"
            [ "$codec" = "hevc" ] || verification_issue "$relative" \
                "v:$i codec mismatch: expected hevc, got ${codec:-unknown}."
            if [ "$width" != "${src_w[$i]}" ] || [ "$height" != "${src_h[$i]}" ]; then
                verification_issue "$relative" \
                    "v:$i resolution changed: ${src_w[$i]}x${src_h[$i]} -> ${width}x${height}."
            fi
            [ "$sar" = "${src_sar[$i]}" ] || verification_issue "$relative" \
                "v:$i SAR changed: ${src_sar[$i]} -> $sar."
            [ "$dar" = "${src_dar[$i]}" ] || verification_issue "$relative" \
                "v:$i DAR changed: ${src_dar[$i]} -> $dar."

            if [ "${check_hdr[$i]:-0}" -eq 1 ]; then
                case "$pix_fmt" in
                    *10*|p010*) ;;
                    *) verification_issue "$relative" "HDR v:$i is no longer 10-bit; output pixel format is $pix_fmt." ;;
                esac
                if valid_colour "${src_prim[$i]}" && [ "$color_primaries" != "${src_prim[$i]}" ]; then
                    verification_issue "$relative" "HDR v:$i primaries changed: ${src_prim[$i]} -> $color_primaries."
                fi
                if valid_colour "${src_trc[$i]}" && [ "$color_transfer" != "${src_trc[$i]}" ]; then
                    verification_issue "$relative" "HDR v:$i transfer changed: ${src_trc[$i]} -> $color_transfer."
                fi
                if valid_colour "${src_space[$i]}" && [ "$color_space" != "${src_space[$i]}" ]; then
                    verification_issue "$relative" "HDR v:$i colour matrix changed: ${src_space[$i]} -> $color_space."
                fi
                read -r out_master out_light < <(get_hdr_side_data "$partial" "$i")
                if [ "${check_master[$i]:-0}" -eq 1 ] && [ "$out_master" -ne 1 ]; then
                    verification_issue "$relative" "HDR mastering-display metadata appears to be missing on v:$i."
                fi
                if [ "${check_light[$i]:-0}" -eq 1 ] && [ "$out_light" -ne 1 ]; then
                    verification_issue "$relative" "HDR MaxCLL/MaxFALL metadata appears to be missing on v:$i."
                fi
            fi
        done
    fi

    if [ "$VERIFY_STRUCTURE" = "1" ]; then
        mapfile -t structure_warnings < <(verify_media_structure "$input" "$partial")
        if [ "${#structure_warnings[@]}" -gt 0 ]; then
            local structure_message
            for structure_message in "${structure_warnings[@]}"; do
                if [[ "$structure_message" =~ (Full\ media-structure\ verification\ could\ not\ run|Stream\ count\ changed|stream\ count\ changed|type\ changed|codec\ changed\ unexpectedly|Audio\ stream.*(sample_rate|channels|channel_layout)\ changed|Copied\ video\ stream.*(width|height|pix_fmt)\ changed|disposition.*changed|Chapter\ count\ changed|Chapter.*(start_time|end_time)\ changed) ]]; then
                    verification_issue "$relative" "$structure_message"
                else
                    log_entry WARNING "$relative" "$structure_message"
                fi
            done
        fi
    fi

    if [ "$LOSSLESS" = "1" ]; then
        echo "Verifying decoded pixels..."
        for i in "${!video_streams[@]}"; do
            [ "${convert[$i]:-0}" -eq 1 ] || continue
            fmt="${src_pix[$i]}"
            src_hash="$(raw_video_hash "$input" "$i" "$fmt")"
            out_hash="$(raw_video_hash "$partial" "$i" "$fmt")"
            if [ -z "$src_hash" ] || [ -z "$out_hash" ]; then
                verification_issue "$relative" "Could not complete decoded-pixel SHA-256 verification for v:$i."
            elif [ "$src_hash" != "$out_hash" ]; then
                verification_issue "$relative" \
                    "Lossless decoded-picture verification failed for v:$i." \
                    "Source SHA256: $src_hash" "Output SHA256: $out_hash"
            else
                echo "  PASS: v:$i decoded pixels are bit-exact"
            fi
        done
    fi

    if [ "$VERIFY_DECODE" = "1" ]; then
        local decode_log decode_tail
        echo "Verifying full decode integrity..."
        decode_log="$(mktemp)"
        if ! ffmpeg -v error -xerror -nostdin -i "$partial" \
            -map '0:v?' -map '0:a?' -f null - >/dev/null 2>"$decode_log"; then
            decode_tail="$(tail -n 20 "$decode_log" | sed 's/[[:space:]]*$//' | awk 'NF {printf "%s%s", sep, $0; sep=" | "}')"
            verification_issue "$relative" \
                "Full decode-integrity verification failed." \
                "${decode_tail:-FFmpeg reported a decode error.}"
        fi
        rm -f -- "$decode_log"
    fi

    verify_seconds=$((SECONDS - phase_started))

    # In fail-safe mode, any critical verification issue rejects the derivative.
    if [ "$CURRENT_VERIFY_FATAL" -eq 1 ]; then
        echo "VERIFY REJECT: $relative"
        log_entry FATAL_VERIFY "$relative" \
            "The temporary derivative failed one or more critical archival checks." \
            "It was discarded and the original file was retained unchanged."
        rm -f -- "$partial"
        CURRENT_PARTIAL=""
        [ -n "$workdir" ] && rm -rf -- "$workdir"
        CURRENT_WORKDIR=""
        ((verify_rejected+=1))
        copy_file "$input" "$copy_output" "$relative"
        return
    fi

    preserve_file_metadata "$input" "$partial" "$relative"

    if mv -f -- "$partial" "$output"; then
        CURRENT_PARTIAL=""
        [ -n "$workdir" ] && rm -rf -- "$workdir"
        CURRENT_WORKDIR=""

        # Remove a stale original-copy outcome when MKV mode now successfully
        # produced a derivative for the same source/settings.
        if [ "$output" != "$copy_output" ] && [ -e "$copy_output" ] &&
           { [ "$FORCE_CURRENT_OUTPUT" = "1" ] || [ "$OVERWRITE" = "1" ]; }; then
            rm -f -- "$copy_output" 2>/dev/null || true
        fi

        bytes_saved_total=$((bytes_saved_total + saved_bytes))
        bytes_saved_this_run=$((bytes_saved_this_run + saved_bytes))
        echo "SUCCESS: $relative | saved $(human_bytes "$saved_bytes")"
        ((converted+=1))
        write_completed_state "$input" "$output" "$relative" "transcoded" "$saved_bytes" \
            "$scan_seconds" "$encode_seconds" "$verify_seconds"
        log_result "$relative" "transcoded" "$source_size" "$encoded_size" "$saved_bytes" \
            "$scan_seconds" "$encode_seconds" "$verify_seconds"
    else
        log_entry ERROR "$relative" "Atomic rename into the final destination failed."
        rm -f -- "$partial"
        [ -n "$workdir" ] && rm -rf -- "$workdir"
        CURRENT_PARTIAL=""; CURRENT_WORKDIR=""
        ((failed+=1))
    fi

}
