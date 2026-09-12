# H.264 to H.265 Archival Converter
Handles HDR content, and maintains metadata, chapters, and audio/subtitle streams

This is a set of Linux-only scripts that utilises FFMPEG to transcode H.264 media to H.265 with an aim of minimising file size without meaningful degredation in quality. It utilises CPU-based 'libx265'.

The script mirrors the source tree into a configurable destination, preserves non-video streams and metadata unchanged, and has optional HDR handling. Outputs are verified, and a configurable minimum size saving retains original files where the new copy is not meaningfully smaller.

It is important to note that when operating as intended, this is not lossless. Some loss in image quality is to be expected, however the default setting target a minimum VMAF score of 95.

## Installation
Download h264_to_h265_transcoder.sh and the lib folder. place them together in a convenient directory.

Make the script executable
```bash
chmod +x h264_to_h265_transcoder.sh
```
## Basic usage
Run the script:

```bash
./h264_to_h265_archive.sh /path/to/media
```

By default the destination is:

```text
/path/to/media/h265
```

A typical high-quality run is therefore simply:

```bash
./h264_to_h265_archive.sh /path/to/media
```

Variables can be specified by calling them before the above command:

```bash
CRF=18 PRESET=slow TUNE=grain ./h264_to_h265_archive.sh /path/to/media
```

## Separate destination filesystem

The destination can be overridden with `DEST_ROOT`:

```bash
DEST_ROOT=/mnt/hevc-archive ./h264_to_h265_archive.sh /mnt/source-archive
```

The destination can be inside the source tree or on another filesystem. It must not be the source directory itself or an ancestor of the source directory.

The script mirrors source subdirectories, including empty directories, into the destination.

## Defaults

| Variable  | Description   |
|---|---|
| CRF=18    | CRF can be set to an integer. FFMPEG defaults to 28 |
| PRESET=slow    | Can be: medium, slow, slower, veryslow   |
| TUNE=  | Enables transcode tuning. Can be: psnr, ssim, grain, zerolatency, fastdecode |
| LOSSLESS=0 | Enables lossless image handling. Should not be set to 1 unless needed, as this will increase file size   |
| OVERWRITE=0    | Sets if output files should overwrite previous output files  |
| CONTAINER=source   | Sets output container. Change to mkv if needed   |
| CHECKSUMS=0    | Sets checksum generation |
| VERIFY_STRUCTURE=1 | Sets if output structure should be verified. |
| VERIFY_DECODE=0    | Sets if full decode verification should be performed |
| FATAL_VERIFY=1 | Sets if fatal errors should result in transcode rejection    |
| DYNAMIC_HDR=transcode  | Sets if HDR content should be transcoded or copied.  |
| HDR_SCAN_PACKETS=300   | Sets number of packages for fast scan of static HDR  |
| HDR_HEARTBEAT_SECONDS=5    | Sets how often to update the progress hearbeat when scanning HDR content in seconds  |
| PROGRESS_WIDTH=36  | Sets the width of the progress bar   |
| KEEP_ONLY_IF_SMALLER=1 | Enables keeping output files only if meaningfully smaller than original  |
| MIN_SIZE_SAVING_PERCENT=5  | Sets the minimum file size saving in %   |
| MIN_SIZE_SAVING_MIB=100    | Sets the minimum file size saving in MiB |
| ABS_SAVING_MIN_SOURCE_MIB=1024 | Sets the minimum file size for the percentage based file size check to apply |
| FREE_SPACE_CHECK=1 | Enables pre-processing free space check  |
| MIN_FREE_SPACE_GIB=5   | Minimum available space required if FREE_SPACE_CHECK=1   |
| REPROCESS_ON_TOOL_CHANGE=0 | Reprocess files when the script is updated or variables are changed  |

### Lossless mode

```bash
LOSSLESS=1 PRESET=slow ./h264_to_h265_archive.sh /path/to/media
```

When `LOSSLESS=1`, CRF is not used and x265 lossless mode is enabled. The script additionally hashes decoded raw video pixels from source and output. A mismatch is a critical verification failure when `FATAL_VERIFY=1`. This will massively increase filesize, and makes the process pointless, as it cannot exceed the quality of the original stream. If maximum quality and not optimising quality to filesize is important to you, then you should keep the originals.


## What happens when settings change?

Changing CRF, preset, tune, container mode, HDR policy, verification policy, or size-gate settings invalidates the completed-state decision and causes the file to be reconsidered.

However, the expensive exhaustive HDR result is cached separately in the same state file. If the source fingerprint is unchanged, the script can print:

```text
HDR scan: Movies/Example.mkv (cached)
```

and proceed without scanning the full media file again.

### Force reprocessing

```bash
OVERWRITE=1 ./h264_to_h265_archive.sh /path/to/media
```

This ignores completed-state skip decisions. A still-valid HDR scan cache may nevertheless be reused because it describes the source rather than the previous encode.

### Toolchain changes

Tool versions are recorded for reproducibility. By default, a tool upgrade alone does not invalidate completed output:

```text
REPROCESS_ON_TOOL_CHANGE=0
```

To force reprocessing when the FFmpeg/x265/HDR-tool fingerprint changes:

```bash
REPROCESS_ON_TOOL_CHANGE=1 ./h264_to_h265_archive.sh /path/to/media

## Transcode workflow
The default workflow is:

```text
source file discovered
        ↓
cheap filesystem/state check
        ↓
already current and verified? ── yes ──→ SKIP
        ↓ no
reuse cached full HDR scan if source is unchanged
        ↓
otherwise run exhaustive dynamic-HDR scan
        ↓
classify source / archival safety checks
        ↓
copy original unchanged OR encode to atomic .partial file
        ↓
whole-file storage-saving gate
        ↓
critical verification
        ↓
verification failure? → yes → discard derivative → copy original
        ↓ no
preserve filesystem metadata
        ↓
atomic rename into final destination
        ↓
write completed processing state
```


## Package Requirements

Required commands:

```text
ffmpeg
ffprobe
python3
find
cp
mv
rm
touch
chmod
chown
id
grep
awk
date
mktemp
tail
sed
wc
stat
flock
df
sleep
```

Your FFmpeg build must include `libx265`:

```bash
ffmpeg -hide_banner -encoders | grep libx265
```

When `CHECKSUMS=1`, these are additionally required:

```text
sha256sum
sort
xargs
```

Dynamic-HDR tools are required only when `DYNAMIC_HDR=transcode` encounters matching content:

```text
hdr10plus_tool   HDR10+ extraction and verification
dovi_tool        Dolby Vision RPU extraction/conversion/verification
cmp              Profile 7 MEL binary RPU comparison
```

If a dynamic-HDR workflow requires a tool or encoder capability that is unavailable, the script preserves the source by copying it unchanged.

## Exhaustive dynamic-HDR scanning

Before re-encoding a candidate that could contain dynamic HDR, the script exhaustively inspects video stream, frame, and packet side data over the complete file.

The scan looks for indicators including:

```text
Dolby Vision / DOVI
HDR10+
SMPTE ST 2094-40
HDR Dynamic Metadata
```

The result is cached by source fingerprint.

Long scans display a heartbeat such as:

```text
HDR scan: Movies/Feature.mkv | elapsed 00:02:15
```

Set the heartbeat interval with:

```bash
HDR_HEARTBEAT_SECONDS=10 ./h264_to_h265_archive.sh /path/to/media
```

## Dynamic HDR policy

The safe default is:

```text
DYNAMIC_HDR=copy
```

When dynamic HDR is detected, the original is copied unchanged.

Enable metadata-aware re-encoding explicitly with:

```bash
DYNAMIC_HDR=transcode CONTAINER=mkv ./h264_to_h265_archive.sh /path/to/media
```

### HDR10+

For supported HDR10+ HEVC sources, the script uses `hdr10plus_tool` to extract dynamic metadata, supplies it to x265 during encoding, then extracts metadata from the result and compares it with the source JSON.

A mismatch is a critical verification issue by default.

### Dolby Vision Profile 5 / 8

When the installed FFmpeg/libx265 wrapper exposes Dolby Vision coding, Profile 5 and Profile 8 sources can use native RPU handling.

When `dovi_tool` is installed, the script independently extracts source/output RPU data and compares frame counts and exported semantic metadata.

### Dolby Vision Profile 7 MEL

The script can conservatively convert supported Profile 7 MEL material to single-layer Profile 8.1 when:

- `dovi_tool` is installed;
- `CONTAINER=mkv` is selected;
- the source is confidently constant frame rate;
- video start time is effectively zero;
- RPU conversion/injection succeeds and verifies.

### Dolby Vision Profile 7 FEL

Profile 7 FEL is copied unchanged. The generic workflow deliberately does not discard FEL residual picture information for the sake of an automatic transcode.

### Unknown dynamic HDR

Unknown or ambiguous dynamic-HDR content is copied unchanged rather than guessed at.

## Chroma / bit-depth safeguards

H.264 video using formats that would be reduced by the normal Main/Main10 workflow is copied unchanged, including conservative handling of:

```text
4:2:2
4:4:4
GBR/RGB-style formats
12-bit
14-bit
16-bit
```

HDR signalling on an unsupported source bit depth also causes the source to be copied unchanged.

## Stream and metadata preservation

The normal FFmpeg mapping uses:

```text
-map 0
-c copy
-map_metadata 0
-map_chapters 0
-copy_unknown
```

Only selected video streams are overridden with `libx265`.

This is intended to preserve:

- audio tracks;
- subtitle tracks;
- attachments such as fonts;
- data/unknown streams where FFmpeg supports copying them;
- chapters;
- global metadata;
- stream metadata;
- stream dispositions such as default/forced/hearing-impaired flags.

The script also requests A/53 caption preservation and unregistered SEI preservation when those libx265-wrapper options are exposed by the installed FFmpeg build.

No transcoding/remuxing system can promise preservation of every proprietary container-private field that FFmpeg does not expose. For unsupported/ambiguous cases, this script deliberately favors copying the source unchanged.

## Critical verification policy

Default:

```text
FATAL_VERIFY=1
```

Critical mismatches do not merely produce a warning. They mark the temporary derivative as unsafe, after which it is deleted and the original is copied instead.

Examples treated as critical include:

- output cannot be inspected by FFprobe;
- expected video stream is missing;
- unexpected video codec change;
- resolution/SAR/DAR mismatch;
- HDR bit depth or colour signalling changes;
- static HDR metadata detected on the source is missing;
- HDR10+ verification mismatch/failure;
- Dolby Vision RPU/profile verification mismatch/failure;
- stream counts/types/codecs change unexpectedly;
- audio sample rate/channels/layout change;
- copied-video properties change;
- stream dispositions change;
- chapter count/timing changes;
- lossless decoded-pixel verification fails.

Cosmetic metadata differences such as selected title/comment/container-tag changes are still logged as warnings rather than automatically rejecting the derivative.

Disable fail-safe rejection and retain derivatives while logging critical mismatches as warnings:

```bash
FATAL_VERIFY=0 ./h264_to_h265_archive.sh /path/to/media
```

For an archival workflow, leaving `FATAL_VERIFY=1` is recommended.

## Structure verification

Default:

```text
VERIFY_STRUCTURE=1
```

The script compares source and output stream structure, including:

- total stream count;
- per-type stream counts;
- codecs;
- audio sample rate/channels/channel layout;
- copied-video dimensions/pixel format;
- selected stream metadata;
- dispositions;
- chapter count/timing/metadata;
- selected global container metadata.

Disable it with:

```bash
VERIFY_STRUCTURE=0 ./h264_to_h265_archive.sh /path/to/media
```

## Optional complete decode-integrity verification

A structural probe does not prove every media frame can be decoded. For a full post-encode video/audio decode check:

```bash
VERIFY_DECODE=1 ./h264_to_h265_archive.sh /path/to/media
```

This runs an additional FFmpeg decode-to-null pass with error-to-failure behavior. It is intentionally disabled by default because it can add substantial runtime.

When `FATAL_VERIFY=1`, a decode failure rejects the derivative and keeps the original.

## Atomic output and interruption safety

Transcodes and copies are written to same-directory temporary names similar to:

```text
.h265-partial.<pid>.<random>
```

The final filename appears only after successful processing and verification.

`SIGINT`, `SIGTERM`, and `SIGHUP` trigger cleanup of the active partial output and dynamic-HDR work directory.

This design also means stale completed files are not deleted before a replacement succeeds.