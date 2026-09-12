#!/usr/bin/env bash

# This script handles cleanup and progress management for control process
# and should not be run directly

#Cleanup temp files
cleanup_temp() {
    [ -n "$CURRENT_PARTIAL" ] && rm -f -- "$CURRENT_PARTIAL" 2>/dev/null || true
    [ -n "$CURRENT_FFMPEG_LOG" ] && rm -f -- "$CURRENT_FFMPEG_LOG" 2>/dev/null || true
    [ -n "$CURRENT_WORKDIR" ] && rm -rf -- "$CURRENT_WORKDIR" 2>/dev/null || true
}

#Handle SIGINTS
handle_signal() {
    echo
    echo "Interrupted; temporary output is being removed."
    log_entry WARNING SCRIPT "Conversion run was interrupted; active temporary output was removed."
    exit 130
}

#Draw Progress Bar
draw_bar() {
    local label="$1" current="$2" total="$3"
    local pct filled empty a b

    if [ "$total" -le 0 ]; then
        pct=100
        filled="$PROGRESS_WIDTH"
    else
        pct=$(( current * 100 / total ))
        [ "$pct" -gt 100 ] && pct=100
        filled=$(( current * PROGRESS_WIDTH / total ))
        [ "$filled" -gt "$PROGRESS_WIDTH" ] && filled="$PROGRESS_WIDTH"
    fi

    empty=$(( PROGRESS_WIDTH - filled ))
    printf -v a '%*s' "$filled" ''
    printf -v b '%*s' "$empty" ''
    a="${a// /#}"
    printf '\r%-9s [%s%s] %3d%%' "$label" "$a" "$b" "$pct"
}

#Render FFMPEG progress updates
render_ffmpeg_progress() {
    local total_us="$1" key value
    local current_us=0 frame=0 fps="0" speed="0x" saw_out_time_us=0

    while IFS='=' read -r key value; do
        case "$key" in
            frame)
                frame="$value"
                ;;
            fps)
                fps="$value"
                ;;
            speed)
                speed="$value"
                ;;
            out_time_us)
                if [[ "$value" =~ ^[0-9]+$ ]]; then
                    saw_out_time_us=1
                    current_us="$value"
                    draw_bar "Encoding" "$current_us" "$total_us"
                    printf ' | frame %-8s | %6s fps | speed %-8s' "$frame" "$fps" "$speed"
                fi
                ;;
            out_time_ms)
                # Older FFmpeg builds may expose out_time_ms instead of out_time_us.
                # FFmpeg historically reports this value in microseconds despite the name.
                if [ "$saw_out_time_us" -eq 0 ] && [[ "$value" =~ ^[0-9]+$ ]]; then
                    current_us="$value"
                    draw_bar "Encoding" "$current_us" "$total_us"
                    printf ' | frame %-8s | %6s fps | speed %-8s' "$frame" "$fps" "$speed"
                fi
                ;;
            progress)
                if [ "$value" = "end" ]; then
                    draw_bar "Encoding" "$total_us" "$total_us"
                    printf ' | frame %-8s | %6s fps | speed %-8s\n' "$frame" "$fps" "$speed"
                fi
                ;;
        esac
    done
}