# H.264 / Dynamic HDR to H.265 Archival Converter

A Linux Bash script that recursively converts H.264 video streams to H.265/HEVC using CPU-based `libx265`. It can also opt in to metadata-aware re-encoding of supported HDR10+ and Dolby Vision HEVC sources while preserving directory layout, audio, subtitles, chapters, metadata, and other streams wherever the destination container supports them.

The script is intended for **high-quality archival derivatives**. For strict archival preservation, retain the original H.264 files separately.

## Highlights

- Recursively scans a complete directory tree.
- Creates a mirrored `h265/` tree beneath the source directory.
- Uses CPU-based `libx265`; no GPU/VA-API encoding is used.
- Defaults to `CRF=14` and `PRESET=slow`.
- Stream-copies audio, subtitles, attachments, data streams, and non-H.264 video streams.
- Preserves global metadata and chapters.
- Preserves resolution, SAR, DAR, bit depth, HDR10/HLG colour signalling, and static HDR metadata where FFmpeg exposes it.
- Defaults to copying Dolby Vision/HDR10+ unchanged; `DYNAMIC_HDR=transcode` enables metadata-aware re-encoding for supported dynamic-HDR sources.
- Avoids automatically converting 4:2:2, 4:4:4, RGB, and greater-than-10-bit H.264 sources.
- Uses atomic temporary output files so interrupted encodes do not appear as completed files.
- Cleans the current temporary output on interruption (`SIGINT`, `SIGTERM`, `SIGHUP`).
- Verifies the complete stream structure after conversion: stream counts/types/codecs, audio properties, selected stream metadata, dispositions, chapters, attachments, and selected container metadata.
- Explicitly enables A/53 caption and unregistered SEI preservation when supported by the installed FFmpeg/libx265 build.
- Supports optional x265 tuning such as `TUNE=grain`.
- Supports `CONTAINER=source` or `CONTAINER=mkv`.
- Optionally writes SHA-256 manifests for the source and output trees.
- Uses stronger Linux filesystem metadata preservation for copied and transcoded files.
- Displays per-file encoding progress and overall dataset progress.
- Stores every warning/error in one persistent log: `h265/conversion_warnings.log`.

## Requirements

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
```

When `CHECKSUMS=1`, these are also required:

```text
sha256sum
sort
xargs
```

Dynamic-HDR tools are required only when the matching content is encountered with `DYNAMIC_HDR=transcode`:

```text
hdr10plus_tool   # HDR10+ extraction/verification
dovi_tool        # Required for Profile 7 MEL; optional enhanced Profile 5/8 RPU verification
cmp              # Profile 7 RPU binary verification
```

Dolby Vision Profiles 5 and 8 use FFmpeg/libx265's native `dolbyvision` encoder support. If `dovi_tool` is also installed, the script independently extracts the source/output RPUs, compares frame counts, and compares full exported RPU metadata. If a required tool or encoder capability is unavailable, the source is copied unchanged and a warning is logged.

Your FFmpeg build must include `libx265`:

```bash
ffmpeg -hide_banner -encoders | grep libx265
```

The script detects whether the installed `libx265` wrapper exposes `a53cc` and `udu_sei`. If either option is unavailable, the script continues but records a warning.

## Installation

Make the script executable:

```bash
chmod +x h264_to_h265_archive.sh
```

## Basic Usage

```bash
./h264_to_h265_archive.sh /path/to/media
```

Example:

```bash
./h264_to_h265_archive.sh /mnt/archive/videos
```

The output tree is created at:

```text
/mnt/archive/videos/h265/
```

The `h265/` directory is explicitly excluded from future scans.

## Dynamic HDR Mode

The default is the safest behavior:

```text
DYNAMIC_HDR=copy
```

With this setting, any dynamic HDR discovered on a file that would otherwise be transcoded causes that file to be copied unchanged. Ordinary HEVC files are copied unchanged as well.

To opt in to metadata-aware dynamic-HDR re-encoding:

```bash
DYNAMIC_HDR=transcode CONTAINER=mkv ./h264_to_h265_archive.sh /path/to/media
```

`DYNAMIC_HDR=transcode` also inspects HEVC sources so supported HDR10+/Dolby Vision files can be selected for re-encoding. Unsupported or ambiguous cases still fall back to copying the source unchanged.

## Directory and Filename Behaviour

With the default:

```text
CONTAINER=source
```

transcoded files retain the same relative path and filename as the source.

Example:

```text
Movies/Example.mp4
```

becomes:

```text
h265/Movies/Example.mp4
```

If you use:

```bash
CONTAINER=mkv ./h264_to_h265_archive.sh /path/to/media
```

transcoded non-MKV files receive an additional `.mkv` suffix. This deliberately avoids filename collisions while retaining the original filename:

```text
Movies/Example.mp4
```

becomes:

```text
h265/Movies/Example.mp4.mkv
```

An existing `.mkv` source remains `.mkv`.

Files that are copied unchanged keep their original filename and extension regardless of `CONTAINER` mode.

### Which container should I use?

Use `CONTAINER=source` when preserving the exact filename/extension is important and you know the source container supports HEVC plus all copied streams.

Use `CONTAINER=mkv` for heterogeneous archival libraries where broad support for subtitles, attachments, chapters, and arbitrary stream combinations is more important than retaining the original container extension.

## Default Encoding Settings

The defaults are:

```text
Encoder: libx265
CRF:     14
Preset:  slow
Tune:    none
```

Run explicitly with the defaults:

```bash
CRF=14 PRESET=slow ./h264_to_h265_archive.sh /path/to/media
```

## CRF Quality

Set CRF using an environment variable:

```bash
CRF=16 ./h264_to_h265_archive.sh /path/to/media
```

Typical guidance:

| CRF | Intended use |
|---:|---|
| 12 | Extremely high quality, very large files |
| 14 | Very conservative archival derivative; default |
| 16 | Very high quality with better space savings |
| 18 | High quality and smaller output |
| 20+ | Increasing emphasis on storage savings |

Lower CRF means higher quality and larger files.

CRF encoding is still mathematically lossy. Keep the original H.264 file if strict preservation matters.

## x265 Preset

The default preset is:

```text
slow
```

Examples:

```bash
PRESET=medium ./h264_to_h265_archive.sh /path/to/media
```

```bash
PRESET=veryslow ./h264_to_h265_archive.sh /path/to/media
```

Slower presets spend more CPU time for better compression efficiency at the selected quality target.

## Tune Options

`TUNE` is optional and unset by default.

For film grain or naturally noisy material:

```bash
TUNE=grain ./h264_to_h265_archive.sh /path/to/media
```

A useful archival-derivative combination for grain-heavy material is:

```bash
CRF=14 PRESET=slow TUNE=grain ./h264_to_h265_archive.sh /path/to/media
```

Do not apply `grain` automatically to clean digital material; it intentionally changes x265's decisions to favour consistent grain/high-frequency detail.

## Lossless Mode

Use x265 mathematically lossless mode with:

```bash
LOSSLESS=1 ./h264_to_h265_archive.sh /path/to/media
```

In this mode:

- CRF is not used.
- x265 receives `lossless=1`.
- The script decodes both the original H.264 and output HEVC video.
- It calculates SHA-256 hashes of the decoded raw video.
- A mismatch is recorded in the warning log.

Lossless H.265 preserves the **decoded picture**, not the original H.264 compressed bitstream. The resulting file can be larger than the source.

## Atomic Output and Interruption Safety

Transcoded and copied files are first written to temporary files in the destination directory. A final file is created only after the temporary file has been successfully completed.

The final step is a same-directory `mv`, making the commit atomic on a normal Linux filesystem.

If the script is interrupted with `Ctrl+C`, `SIGTERM`, or `SIGHUP`, the currently active temporary output is removed.

A hard power loss or `SIGKILL` can still leave a `.h265-partial.*` temporary file, but such a file does **not** have the final destination filename and therefore will not be mistaken for a completed conversion on the next run.

## Full Media-Structure Verification

After a successful encode, the script verifies the temporary output before moving it into its final name.

The verification compares:

- total stream count;
- counts by stream type (`video`, `audio`, `subtitle`, `attachment`, etc.);
- expected codec changes (`h264` -> `hevc` only);
- codecs of copied streams;
- audio sample rate, channel count, and channel layout;
- selected stream metadata such as language, title, filename, MIME type, handler name, and comments;
- stream disposition flags (`default`, `forced`, accessibility flags, and others exposed by ffprobe);
- chapter count;
- chapter start/end times with a small muxing tolerance;
- chapter metadata;
- selected container metadata such as title, artist, album, date, creation time, comments, description, copyright, and publisher.

Verification warnings do **not** delete an otherwise successful encode. They are written to:

```text
h265/conversion_warnings.log
```

The existing video-specific verification also checks:

- codec;
- resolution;
- sample aspect ratio (SAR);
- display aspect ratio (DAR);
- HDR bit depth;
- HDR colour primaries;
- HDR transfer characteristics;
- HDR matrix coefficients;
- mastering-display metadata;
- MaxCLL/MaxFALL metadata.

Set:

```bash
VERIFY_STRUCTURE=0 ./h264_to_h265_archive.sh /path/to/media
```

only if you explicitly want to skip the broader Python-based structural verification.

## HDR Handling

### HDR10

For HDR10, the script attempts to preserve:

- 10-bit depth;
- HEVC Main10 profile;
- BT.2020 primaries where present;
- SMPTE ST 2084/PQ transfer characteristics;
- colour matrix coefficients;
- full/limited range signalling;
- mastering-display metadata;
- MaxCLL/MaxFALL metadata.

For PQ HDR10, the script also supplies x265's HDR10 signalling and enables `hdr10-opt` in normal CRF mode.

### HLG

HLG is detected through `arib-std-b67`. Its colour signalling is preserved and verified.

### Dolby Vision and HDR10+

Before transcoding a candidate file, the script performs an **exhaustive full-file dynamic-HDR scan**. It inspects stream, frame, and packet side-data across the complete file rather than limiting dynamic-HDR detection to the first `HDR_SCAN_PACKETS` frames/packets. The exhaustive scan is restricted to video streams so audio and subtitle packets are not needlessly enumerated. `HDR_SCAN_PACKETS` remains only for the faster static HDR10/HLG checks.

The default `DYNAMIC_HDR=copy` remains conservative: detected dynamic HDR is copied unchanged.

With `DYNAMIC_HDR=transcode`, supported HEVC dynamic-HDR sources use the following workflows:

| Source | Behavior |
|---|---|
| HDR10+ | Extract frame-level metadata with `hdr10plus_tool`, re-encode with x265 using `dhdr10-info`, re-extract output metadata, and compare it with the source metadata. |
| Dolby Vision Profile 5 | Re-encode with FFmpeg/libx265 native Dolby Vision RPU coding and verify Dolby Vision/RPU signalling. If `dovi_tool` is installed, source/output RPU metadata is also independently compared. |
| Dolby Vision Profile 8.x | Same native FFmpeg/libx265 RPU-aware workflow; compatible HDR10/HLG colour signalling is retained and verified. If `dovi_tool` is installed, source/output RPU metadata is also independently compared. |
| Dolby Vision Profile 7 MEL | Requires `CONTAINER=mkv`. Extract the RPU with `dovi_tool`, convert it to Profile 8.1, encode the HDR10 base layer, inject the converted RPU, rebuild the MKV, and verify the injected RPU. |
| Dolby Vision Profile 7 FEL | **Never automatically re-encoded.** The file is copied unchanged because the FEL residual contribution cannot be faithfully retained by this generic x265 workflow. |
| Unknown/unsupported dynamic HDR | Copied unchanged. |

Profile 7 MEL conversion is additionally limited to sources that the script can identify as constant-frame-rate with a zero video start time. If those timing conditions are not met, the source is copied unchanged to avoid A/V synchronization risk.

For Profile 7 MEL the resulting Dolby Vision stream is a **single-layer Profile 8.1 derivative**. The Profile 7 enhancement layer is not preserved. This is intentional for MEL. Profile 7 FEL remains untouched because discarding its enhancement-layer residual can alter the Dolby Vision presentation.

If `hdr10plus_tool`, `dovi_tool`, `cmp`, or native FFmpeg Dolby Vision support is missing when required, the script does not strip the metadata. It logs a warning and copies the original source unchanged.

Dynamic-HDR verification follows the same non-destructive policy as the rest of the script: a completed encode with a verification mismatch is retained and a detailed warning is added to `h265/conversion_warnings.log`.

## A/53 Captions and Unregistered SEI

When supported by the installed FFmpeg/libx265 wrapper, converted H.264 streams receive:

```text
-a53cc 1
-udu_sei 1
```

This explicitly requests preservation of available A/53 closed-caption data and unregistered user-data SEI.

If the installed FFmpeg does not expose one of these options, the script records a warning and continues.

## Audio, Subtitles, Attachments, and Metadata

Each conversion begins with the equivalent of:

```text
-map 0
-c copy
-map_metadata 0
-map_chapters 0
-copy_unknown
```

Every stream is therefore copied by default. Only H.264 video streams are overridden with `libx265` encoding settings.

The structural verification checks whether expected copied streams, metadata, dispositions, attachments, and chapters survived the muxing process.

Container limitations still apply. If `CONTAINER=source` selects a container that cannot represent HEVC or one of the copied streams, FFmpeg may fail. The failure and FFmpeg diagnostics are recorded in the log.

## Files Copied Unchanged

The script normally copies these instead of transcoding them:

- files without H.264 video;
- audio-only files;
- non-media files;
- already-HEVC files;
- dynamic-HDR files when `DYNAMIC_HDR=copy`, plus unsupported/unsafe dynamic-HDR cases even when `DYNAMIC_HDR=transcode`;
- H.264 4:2:2 or 4:4:4 video;
- RGB H.264 video;
- H.264 sources above 10-bit;
- unusual HDR sources that the safety checks reject.

## Linux Filesystem Metadata

For ordinary copied files, the script first attempts:

```text
cp --preserve=all
```

This requests preservation of mode, ownership, timestamps, links, security context, and extended attributes where the operating system, filesystem, and permissions allow it.

If full preservation fails, it falls back to `cp -p` and records a warning.

For transcoded files, the script uses:

```text
cp --attributes-only --preserve=all
```

against the completed temporary encode before its final atomic rename. This applies source filesystem attributes without replacing the transcoded data.

Directory modes and timestamps are restored on a best-effort basis after processing. Directory ownership is also restored when the script runs as root.

## SHA-256 Manifests

Checksum manifests are disabled by default because hashing an entire large archive can add substantial I/O time.

Enable them with:

```bash
CHECKSUMS=1 ./h264_to_h265_archive.sh /path/to/media
```

The script then creates:

```text
h265/source_sha256.txt
h265/output_sha256.txt
```

`source_sha256.txt` covers the original source tree while excluding the generated `h265/` directory.

`output_sha256.txt` covers the generated output files while excluding the warning log, checksum manifests, and temporary partial files.

To verify the source manifest later:

```bash
cd /path/to/media
sha256sum -c h265/source_sha256.txt
```

To verify the output manifest later:

```bash
cd /path/to/media/h265
sha256sum -c output_sha256.txt
```

These file-level hashes are different from the decoded-pixel hashes used by `LOSSLESS=1`.

## Progress Bars

During a transcode, FFmpeg reports progress every 0.5 seconds and the script shows percentage, encoded frame count, FPS, and speed:

```text
Encoding  [####################                ] 56% | frame 42173    | 18.42 fps | speed 0.768x
```

The main and auxiliary FFmpeg operations use `-nostdin`, which prevents unattended jobs from pausing while waiting for terminal input. If the progress line continues changing, the encoder is active even when a `slow` x265 encode is running well below real time.

After each source file:

```text
Overall   [############################        ] 78%
```

Copied, skipped, converted, and failed files all advance overall progress.

## Warning and Error Log

All runs append to one persistent log:

```text
<source>/h265/conversion_warnings.log
```

It contains:

- failed conversions;
- copy failures;
- the final 80 lines of FFmpeg output for failed encodes;
- HDR preservation warnings;
- resolution/SAR/DAR mismatches;
- stream-count/type/codec mismatches;
- metadata or disposition mismatches;
- chapter mismatches;
- files copied unchanged for archival safety;
- filesystem metadata preservation warnings;
- lossless decoded-picture verification failures;
- checksum manifest generation failures;
- run summaries.

Successful files are not logged individually.

## Overwriting Existing Output

By default, existing destination files are skipped.

To overwrite them:

```bash
OVERWRITE=1 ./h264_to_h265_archive.sh /path/to/media
```

Because output is committed atomically, an active conversion writes to a temporary filename first and replaces the final file only after encoding and verification complete.

## Recommended Archival-Derivative Commands

High-quality general-purpose derivative:

```bash
CRF=14 PRESET=slow ./h264_to_h265_archive.sh /path/to/media
```

Grain-heavy film:

```bash
CRF=14 PRESET=slow TUNE=grain ./h264_to_h265_archive.sh /path/to/media
```

Safer container choice for mixed libraries:

```bash
CRF=14 PRESET=slow CONTAINER=mkv ./h264_to_h265_archive.sh /path/to/media
```

With source/output checksum manifests:

```bash
CRF=14 PRESET=slow CONTAINER=mkv CHECKSUMS=1 ./h264_to_h265_archive.sh /path/to/media
```

Opt in to HDR10+/supported Dolby Vision re-encoding:

```bash
CRF=14 PRESET=slow CONTAINER=mkv DYNAMIC_HDR=transcode CHECKSUMS=1 \
./h264_to_h265_archive.sh /path/to/media
```

The safe default remains `DYNAMIC_HDR=copy`. Use `DYNAMIC_HDR=transcode` only when you have the required metadata tools installed and specifically want dynamic-HDR derivatives.

Mathematically lossless decoded-picture conversion:

```bash
LOSSLESS=1 PRESET=slow CHECKSUMS=1 ./h264_to_h265_archive.sh /path/to/media
```

## Archival Recommendation

For irreplaceable material, treat the original H.264 files as the archival masters and the generated HEVC files as derivatives.

A strong workflow is:

```text
original source
    -> source SHA-256 manifest
    -> H.265 encode to temporary file
    -> video/HDR verification
    -> complete stream/chapter/metadata verification
    -> optional decoded-pixel verification
    -> filesystem attribute preservation
    -> atomic rename to final output
    -> output SHA-256 manifest
```

Even when `LOSSLESS=1`, the output does not preserve the original H.264 compressed bitstream, so retaining the source remains the safest long-term archival policy.
