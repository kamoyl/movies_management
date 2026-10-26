# Movie management scripts

This repository contains two Bash utilities for working with Matroska video:

- `movies_encoding` collects and updates movie metadata, and can start an AV1 encode.
- `interpolation_nncn` splits a video into one-minute chunks (a video of up to 90 seconds is processed as one chunk), processes the chunks with an NCNN/Vulkan image-processing tool, and merges each chunk's video with its audio and subtitle streams. Audio and subtitle tracks in Polish, Dutch, or English are extracted with `mkvmerge`, keeping their original language tags; if a chunk has audio but none in these languages, all its audio tracks are taken. Audio and subtitles are optional: a chunk without them is still processed, with a warning, and merged without them.

Both scripts load shared functions from `.config` (which loads `.config_colours` and `.config_video`) and use `.var_management` to create working, temporary, and log directories. Run the scripts from a working directory where you have space for the input, intermediate files, and outputs.

## Improvements

The scripts were improved step by step; each group below describes
what changed and why. Speed work has its own section:
[Performance optimization](#performance-optimization).

**Options and help.**

- `movies_encoding` no longer has the nonfunctional `-q` quality-check option, has full help output, reports unknown or incomplete options (exit code 2), and parses `-o` before initializing the workspace so the requested directory takes effect.
- `interpolation_nncn -S` redirects all terminal output to `LOG/interpolation_nncn_silent_<timestamp>.log`; the unused `-n` option was removed, and `-h` documents the per-chunk processing.
- With `-s`, the cleanup deletes the chunks *before* the start chunk (`seq -w 001 <start-1>`), and the per-chunk runtime is assigned correctly (`PART_VIDEO_RUNTIME=${RUNTIME}`).

**Explicit failures.** A run never silently continues after a broken step and never exits with code 0 after an error:

- `failed` (in `.config`) always exits non-zero. It uses `ERROR_CODE` when set, otherwise the last command's status, and logs the file, function, and line.
- `.config_video` provides `require_output FILE STEP` (fails when an expected output file is missing or empty) and `mkvtoolnix_status STATUS STEP` (MKVToolNix: 1 = warning, 2 = error).
- `.config_video` checks the results of MP4→MKV conversion, HDR→SDR tone mapping, stream and frame merging, `mkvmerge`/`mkvpropedit` calls, and OMDb/TheMovieDB responses. `mkvpropedit` output goes to `LOG/<name>_mkvpropedit.log` instead of `/dev/null`. A failed VMAF check is reported and recorded as `error` in the statistics, but does not stop the run. Optional steps (cover download, permissions, tag cleanup) produce warnings only.
- `encoding_process` fails early when the destination directory is not writable. It encodes the eng/pol/dut audio tracks (numbered among audio tracks, as HandBrakeCLI `-a` expects); with no such track it takes all audio tracks, and with no audio at all it uses `-a none`. Without an eng/pol/dut subtitle track it encodes without subtitles (`-s none`). Each fallback is reported with a warning. It reports a HandBrake start-up failure, and otherwise says clearly that the encode was only *started* in the background.
- `movies_encoding` also checks for `mediainfo`, `mkvpropedit`, and, with `-e`, `HandBrakeCLI`.
- `interpolation_nncn` checks the required tools (missing tool: exit 127) and the FFmpeg features it will need (the intermediate codec's encoder; `libplacebo` for an HDR video unless `-T`; `libvmaf` with `-Q`) before doing any work, and accepts only `rife`, `dain`, `cain`, and `realsr`. An invalid `-s` value or unsupported method exits with code 2. It validates the video duration, the `mkvmerge` split result, the last chunk number, and each chunk file. NCNN failures are reported as errors, and Ctrl+C reports the matching method's logs and exits with code 130.

Exit codes: `0` success, `1` processing error, `2` invalid usage or input, `127` missing tool, `130` interrupted. When an external tool fails, its own exit code is shown in the error message, but the script still exits with `1`, so a tool's code (for example `mkvmerge` exit `2`) is never mistaken for invalid usage.

**Quoting and path safety.** Unusual file names (spaces, dots, `$( )`) can never break a command or delete the wrong files:

- `safe_remove_dir DIR` deletes a directory only if it lies *inside* `TMP` or `TMP_OUT`. It refuses empty paths, `..`, and the work roots themselves, so an empty variable can no longer turn `rm -rf "${TMP}/${DIR}"` into a deletion of `/`.
- `remove_numbered_frames DIR FROM TO` replaces `eval rm {N..1}.png`. File names are never evaluated as code, and long ranges no longer hit "argument list too long". Already-deleted frames are tracked, so each frame is removed once.
- Names are derived with parameter expansion (`${FILE_NAME%.mp4}`, `${NAME%.mkv}`) instead of `awk -F.`, so `Movie.Name.2024.mkv` keeps its dots. Single files are removed with `rm -f --`.
- `movie_data_collecting` and `imdb_management` set `MOVIE_NAME` themselves, instead of relying on an unset `VIDEO_FILE_NAME`.
- Both scripts reject an `-i` value that contains `/` (exit 2): `cd` into the movie's directory and pass only the file name, because the scripts create work files next to the input.

**Resumable and predictable runs.**

- `interpolation_nncn -r` resumes an interrupted run. After a chunk finishes, a marker `video_part_minute_NNN_<method>_<fps>_merged.mkv.done` is written next to the merged chunk; it contains the whole movie name. With `-r`, a chunk is skipped only when its marker exists, the marker names the same movie, and the merged `.mkv` is non-empty. Otherwise the chunk is processed again. `-r` can be combined with `-s`. Chunks finished before `-r` existed have no marker and are therefore processed again.
- On exit, error, or Ctrl+C, `interpolation_nncn` stops the background processes it started directly (for example progress monitors), so they do not keep running after the script ends.
- The VMAF progress loop sleeps 2 seconds between checks instead of busy-waiting on one CPU core.
- `movies_encoding` no longer calls `movie_data_collecting` twice, saving duplicate OMDb/TheMovieDB requests.

**ShellCheck and tests.** Real bugs found by [ShellCheck](https://www.shellcheck.net/) were fixed, and safe quoting was added where it cannot change behavior:

- `.config`: the Excel check no longer contains an always-true test; the Acrobat launch passes the program and its arguments as separate words; `BASH_SOURCE[0]` and `"${PYTHON_MODULES[@]}"` are used explicitly.
- `.config_video`: `cd` in `ncnn-release-build` stops on failure instead of building in the wrong directory; NCNN, HandBrake encoder options, and the VMAF filter are passed as quoted arrays or strings; `FUNCNAME[0]` is used explicitly.
- `interpolation_nncn` computes the previous chunk number in Bash arithmetic instead of `bc`.
- Remaining findings are intentional or harmless and are not changed: mostly unquoted variables whose values never contain spaces (SC2086/SC2046), intentional word splitting into arrays (SC2206, marked with `# shellcheck disable` where deliberate), `sudo` with redirects to logs you own (SC2024), and `local VAR=$(...)` (SC2155).

Run the checks from any directory (ShellCheck is needed only for the first command):

```bash
bash tests/shellcheck.sh   # gate: no errors, and none of the fixed warning classes may return
bash tests/run_tests.sh    # behavior tests; no extra test framework needed
```

`tests/run_tests.sh` does not load the full `.config`, because it contacts the network. It checks the command-line options (help, unknown options, missing values), the exit codes of `failed`, and the helpers `require_output`, `mkvtoolnix_status`, `safe_remove_dir`, `remove_numbered_frames`, and `mp4_to_mkv`; for the last one, `ffmpeg` is replaced by a fake script. Its work files go to `tmp/tmp-run_tests_<timestamp>_XXXX` inside the repository (`tmp/` is gitignored) and are removed when the tests finish. `.github/workflows/checks.yml` runs both commands on GitHub Actions for each push and pull request.

## Requirements and configuration

These are Linux-oriented Bash scripts and rely on external command-line tools. The movie script checks for `curl`, `mkvmerge`, `ffprobe`, `jq`, ImageMagick's `convert`, and `wget`. The workflows also use tools including `ffmpeg`, `mediainfo`, `HandBrakeCLI`, `mkvpropedit`, `bc`, `tput`, and `sudo`; the interpolation workflow additionally needs the matching `*-ncnn-vulkan` executable and Vulkan-capable hardware/drivers. `interpolation_nncn` no longer runs `amdmemtweak` (changing the memory refresh made no measurable difference). Install the tools needed for the workflow and selected interpolation method; this repository does not install dependencies.

On macOS the scripts look for GNU `greadlink`, but other commands and options are Linux/GNU-specific. A compatible GNU toolchain may be needed, and macOS execution is not guaranteed.

`.config` sets `LC_NUMERIC=C`, so numbers use a decimal point (as `ffprobe`, `jq`, and `bc` print them) even with a locale such as `nl_NL`, where `printf` would otherwise reject `60.64` as an invalid number. If `LC_ALL` is set, it overrides this setting; leave `LC_ALL` unset.

Metadata and subtitle operations need credentials configured in the shell environment or in your local configuration, as appropriate:

- `OMDB_API_KEY` for OMDb lookups
- `THEMOVIEDB_API3_KEY` for The Movie Database lookups
- `OPENSUBTITLE_TRACKS_PASSWORD` for subtitle downloads

Keep credentials private; do not commit them to this repository. The scripts also use the current directory for some intermediate and output files, and `movies_encoding` currently writes encoded files to `/media/ready` (see [Changing the encode destination](#changing-the-encode-destination)).

## `movies_encoding`

Use this script to inspect a named MKV, look up movie or episode metadata, and optionally update the file or start an encode.

```bash
./movies_encoding -i "Movie Name.mkv" [options]
```

`-i` is required. The input must be an existing, non-empty video file; the script's filename handling is designed around `.mkv` files.

| Option | Argument | Description |
| --- | --- | --- |
| `-i` | `FILE` | Input video path. The filename is also used to derive the movie title. |
| `-I` | `ID` | Supply a lookup ID. IDs beginning with `tt` are treated as IMDb IDs; other values are treated as TheMovieDB IDs by the option parser. |
| `-o` | `DIR` | Set the variable/work directory used for temporary files and logs. Defaults to `$HOME/var`. |
| `-a` | — | Use the animation optimization profile for encoding. |
| `-g` | — | Use the grain optimization profile for encoding. |
| `-H` | — | Use the high-motion optimization profile for encoding. |
| `-u` | — | Update the MKV metadata and perform the update cleanup/permission steps. This can modify the input file and uses `sudo` for some operations. |
| `-e` | — | Start the configured HandBrake encode in the background (`nohup`). |
| `-q` | — | Request VMAF quality analysis. The current script calls the metric helper without its required input arguments, so this option may fail rather than produce a report. |
| `-v` | — | Enable verbose diagnostic output. |
| `-h` | — | Print usage information. |

The encoding profile flags are mutually prioritized in this order: `-a`, `-g`, then `-H`. If more than one is supplied, only the first matching profile is selected. With none supplied, the profile is `film`.

Examples:

```bash
# Inspect and look up a movie by filename
./movies_encoding -i "Arrival (2016).mkv"

# Supply a known IMDb ID and print verbose diagnostics
./movies_encoding -i "Arrival (2016).mkv" -I tt2543164 -v

# Update metadata using a separate workspace directory
./movies_encoding -i "Arrival (2016).mkv" -I tt2543164 -u -o "$HOME/movie-work"

# Start an encode using the grain-tuned profile
./movies_encoding -i "Arrival (2016).mkv" -e -g
```

An update can remove existing tags, chapters, and selected attachments; it can also update the title, poster sidecar, and file ownership/permissions. Review the input and make a backup before using `-u`. Metadata lookups use OMDb and TheMovieDB; network access and valid API keys are required.

### Changing the encode destination

The encode destination defaults to `/media/ready` (`DESTINATION_DIR` in `handbrake_encode_settings`, `.config_video`); set the `DESTINATION_DIR` environment variable to use another directory. Create it and ensure it is writable before using `-e`. `interpolation_nncn -E` uses the same function, so both scripts share the destination and encoder settings. The output is written with the source filename, and the HandBrake log is written beside it. The encoder is currently configured for SVT-AV1 10-bit at quality 22 and preset 5; audio is copied, and selected audio/subtitle tracks depend on language metadata in the input.

## `interpolation_nncn`

Use this script to process a video in one-minute chunks with an NCNN/Vulkan interpolation or upscaling executable.

```bash
./interpolation_nncn -i "Video.mkv" [options]
```

| Option | Argument | Description |
| --- | --- | --- |
| `-i` | `FILE` | Required input video. MP4 input is converted to MKV before processing. |
| `-N` | `METHOD` | NCNN method/executable name. Defaults to `rife`; see method notes below. |
| `-o` | `DIR` | Workspace root for temporary files and logs. Defaults to `$HOME/var`. |
| `-O` | `DIR` | Separate root for extracted/processed frames and related temporary data. Defaults to the `-o` workspace root. |
| `-s` | `NNN` | First three-digit chunk number to process, such as `003`. Defaults to `001`; this lets a run skip earlier chunks. |
| `-r` | — | Resume: skip chunks already finished by an earlier run of the same movie and method in this directory (see "Resumable and predictable runs"). Can be combined with `-s`. |
| `-T` | — | No tone mapping: an HDR video is processed as HDR, without conversion to SDR. A warning is shown, because the colours of the processed frames may differ. Without `-T`, HDR is tone-mapped to SDR automatically. |
| `-k` | — | Keep the intermediate files of finished chunks: the frames-only video in `TMP_OUT` and the chunk's frame directories. Without `-k` they are removed once the chunk is done (its `.done` marker is written). The frames-only video is a full copy of the video track of `_merged.mkv`, so keeping it doubles the space needed per chunk. |
| `-Q` | — | Run the VMAF quality check for each processed chunk (processed chunk = distorted, first input; original chunk = reference, second input). For interpolation (`rife`, `dain`, `cain`) only the frames at original positions are compared, because in-between frames have no reference; the score shows what frame merging and encoding lost, not the quality of the interpolation itself. Uses all CPU cores. Requires an FFmpeg build with `libvmaf`; the model is `/usr/share/model/vmaf_v0.6.1.json` when that file exists (Linux packages), otherwise the `vmaf_v0.6.1` model built into libvmaf (for example Homebrew). An HDR reference is tone-mapped with the same filter as the extracted frames. VMAF runs in the background with lower priority (`nice -n 10`) alongside the next chunk; the source chunk is kept until its VMAF is done, and the last chunk's VMAF is waited for at the end. Off by default. |
| `-E` | — | Final encode of each part: after a chunk is merged, HandBrake encodes it in the background (`nice -n 10`) alongside the next chunk, with the same settings as `movies_encoding` (SVT-AV1 10-bit, quality 22, preset 5, audio copied). The crop is detected once, from the whole input, and passed to every part (HandBrake's automatic crop differs from part to part). After a successful encode the `_merged.mkv` part is removed (kept with `-k`). At the end the encoded parts are joined with `mkvmerge --append-mode track` into `DESTINATION_DIR/<input name>.mkv` (default `/media/ready`) and removed (kept with `-k`). The run stops at start-up if the destination is missing or not writable (exit 1) or the final file already exists (exit 2). With `-Q`, VMAF compares the encoded part (not the merged one) with the source chunk, cropped the same way. A failed encode keeps its merged part and stops the join; run again with `-r -E`. See [Final encode of each part](#final-encode-of-each-part--e). |
| `-a` | — | With `-E`: animation profile (as `movies_encoding -a`). Without `-E`: exit 2. |
| `-g` | — | With `-E`: grain profile (as `movies_encoding -g`). Without `-E`: exit 2. |
| `-H` | — | With `-E`: high-motion profile (as `movies_encoding -H`). Without `-E`: exit 2. |
| `-S` | — | Silent: no terminal output; everything is written to `LOG/interpolation_nncn_silent_<timestamp>.log`. |
| `-v` | — | Enable verbose diagnostics. |
| `-h` | — | Print usage information. |

The script divides input into 60-second MKV chunks in the current working directory. A video of up to 90 seconds (`NO_SPLIT_MAX_SEC`) is not split: it is copied unchanged into one chunk, `video_part_minute_001.mkv`, and processed in one go; `-r`, `-Q`, and the statistics work the same way. It processes chunks from the selected start number, retains per-chunk merged outputs, and removes intermediate chunk data as it completes. Without `-E` the script does **not** create one combined output video. To join the merged parts yourself, use mkvmerge with `--append-mode track`:

```bash
mkvmerge --append-mode track -o joined.mkv video_part_minute_001_rife_50_merged.mkv \
  + video_part_minute_002_rife_50_merged.mkv + video_part_minute_003_rife_50_merged.mkv
```

Without it, mkvmerge starts each part after the longest track of the previous one. A subtitle line that crosses the 60 s split keeps its full length (e.g. until 64 s), so audio and video get a gap at that join, and an encoder later shows a frozen picture there. After each chunk, a `~`-separated row is appended to `TMP/statistics.txt` with stage runtimes, peak space use, the VMAF mean (with `-Q`), and the total chunk runtime. With `-Q` or `-E` a chunk's row is written once its VMAF and encode are done, so after the next chunk; `encoding_runtime` is the HandBrake encode of the part (`-E`), `quality_check_runtime` is VMAF's own runtime, and `runtime` no longer includes it, because VMAF runs alongside the next chunk. Tone mapping has no column of its own: it is part of the frame extraction, so its time is included in `extracting_frames_runtime`. (Files from older versions have an extra second column, `tone_mapping_runtime`, and no `encoding_runtime` column.)

### Final encode of each part (`-E`)

```bash
INTERMEDIATE_CODEC=x264_crf10 ./interpolation_nncn -i "Episode.mkv" -E -Q
DESTINATION_DIR="$HOME/ready" ./interpolation_nncn -i "Episode.mkv" -E -g
```

- Each part is encoded while the next chunk is processed (~100 s per 4K 50 fps minute on the Linux rig, against ~6 min per chunk), so the final encode adds almost no time.
- The merged part is only a short-lived intermediate (HandBrake cannot read PNG frames or a pipe). It is removed right after its encode, so even lossless `x264_lossless` needs space for about two parts only.
- A finished part gets a `<part>_encoded.mkv.done` marker. With `-r -E`, encoded parts are skipped, and a merged part without its encode is encoded again. The join needs every part 001…last to be encoded; otherwise it stops with exit 1.
- HandBrake logs: `LOG/<part>_encoded.mkv_handbrake.log`, crop scan `LOG/handbrake_crop_scan.json` (result) and `.log`, join `LOG/<movie>_joining_encoded_parts.log`.
- Why per part and not one encode of the joined movie: see the measurement in [Performance optimization](#performance-optimization).

The processed frames of each chunk are encoded into an intermediate video. HandBrake (`movies_encoding`) makes the final encode later. Choose its codec with the `INTERMEDIATE_CODEC` environment variable. The script checks the name and the FFmpeg encoder at start-up: an unknown name exits with `2`, and a missing encoder exits with `127`.

| `INTERMEDIATE_CODEC` | FFmpeg settings | Size per 60 s chunk, 4K* | VMAF* |
|---|---|---|---|
| `x264_lossless` (default) | `libx264 -qp 0 -preset ultrafast` | ~10.9 GB | 99.99 (lossless) |
| `ffv1` | `ffv1 -level 3 -slices 24` | about 0.8 × x264 lossless | lossless |
| `x264_crf10` | `libx264 -crf 10 -preset veryfast` | ~900 MB | 97.9 |
| `svtav1_crf10` | `libsvtav1 -crf 10 -preset 8` | ~330 MB | 93.3 |

\* Chunk 029 at its native 3840×1600, interpolated to 50 fps; see [Performance optimization](#performance-optimization) for times and the full comparison. Before this setting existed, the encoder was SVT-AV1 with `rc=1`, which is VBR at only about 2 Mbps (lossy).

The lossless codecs need a lot of disk space. At 4K, that is about 11 GB per minute of output, or ~1.3 TB for a 2-hour movie, because every per-chunk `_merged.mkv` is kept (with `-E` each one is removed after its encode). At 1080p it is roughly a quarter of that. If space is short, use `x264_crf10` (about 12× smaller, VMAF 97.9):

```bash
INTERMEDIATE_CODEC=x264_crf10 ./interpolation_nncn -i "Movie.mkv"
```

The method names listed by the script's help include `cain`, `dain`, `rife`, `ifrnet`, `realsr`, `Real-ESRGAN`, `srmd`, `waifu2x`, `realcugan`, and `zimage`. However, the current processing configuration has explicit parameter sets only for `rife`, `dain`, `cain`, `realsr`, `realesrgan`, and `srmd`. `rife` is the default and doubles the frame rate; `dain` and `cain` also use the interpolation path. `realsr` is configured for 4x scaling, while `realesrgan` and `srmd` use 2x scaling. Other names shown in the help do not currently have equivalent method setup in `.config_video`; do not assume they will run successfully. Method spelling must match the executable name used by the script (for example, `realesrgan`).

Examples:

```bash
# Interpolate with the default RIFE method
./interpolation_nncn -i "Episode.mkv"

# Use DAIN and a separate workspace
./interpolation_nncn -i "Episode.mkv" -N dain -o "$HOME/video-work"

# Start processing from chunk 003 and store frame data on another volume
./interpolation_nncn -i "Episode.mkv" -N rife -s 003 -O "/mnt/fast-storage"

# Also calculate VMAF for each processed chunk
./interpolation_nncn -i "Episode.mkv" -Q
```

### Interpolation reference notes

These notes were moved from the header comments of `interpolation_nncn` (the "Documentation" and "Helpers" sections). The open ToDo list stays in the script.

#### Further reading

- [HDR tone mapping in IPTV: BT.2390 vs BT.2446 vs Hable, explained](https://nightmaretv.net/learn/hdr-tone-mapping)
- [FFmpeg HDR to SDR tone mapping that doesn't look washed out](https://dev.to/masonwritescode/ffmpeg-hdr-to-sdr-tone-mapping-that-doesnt-look-washed-out-2026-24ie)
- [Understanding container formats: MP4, MKV, TS](https://www.shoutcastnet.com/school/understanding-container-formats-mp4-mkv-ts.php)
- [SDR to HDR tone mapping in FFmpeg](https://salivity.github.io/ffmpeg/article/sdr-to-hdr-tone-mapping-in-f-fmpeg)
- [SVT-AV1 parameters](https://github.com/BlueSwordM/SVT-AV1/blob/master/Docs/Parameters.md)
- [Video encoder comparison](https://colinmckellar.com/2024/01/11/video-encoder-comparison/)
- [How to calculate a VMAF score using FFmpeg](https://salivity.github.io/ffmpeg/article/how-to-calculate-vmaf-score-using-f-fmpeg)
- [VMAF: using FFmpeg (Netflix)](https://github.com/Netflix/vmaf/blob/master/resource/doc/ffmpeg.md)

#### AMD GPU monitoring and tuning

```bash
# Show GPU usage
amdgpu_top -n 1 -J | jq

# One line per GPU with its current activity
amdgpu_top --json | jq -c -r '(.devices[] | (.Info | .DeviceName + " (" + .PCI + "): ") + ([.gpu_activity | to_entries[] | .key + ": " + (.value.value|tostring) + .value.unit] | join(", ")))'

# Check memory timings (works only on older cards whose BIOS is not locked)
sudo amdmemtweak --current | grep -E "REF:|GPU [0-9]:" >> "${LOG}/${VIDEO_FILE_NAME}_ncnn_${NCNN_METHOD}.log" 2>&1
```

NCNN thread settings (`-j load:process:save`) measured on the same chunk:

| `-j` value | Time [min] |
| --- | --- |
| `2:2,2:4` | 5:45 |
| `3:2,2:5` | 4:03 |
| `3:3,3:5` | 4:07 |
| `4:2,2:6` | 3:09 |
| `6:2,2:8` (memory REF 5 & 30) | 2:01 |
| `8:2,2:10` | 1:48 |

The GPUs and threads depend on the machine, not on a choice per run, so the script picks them by OS: on Linux `-g 1,2 -j 6:2,2:8` (the two AMD GPUs, tuned above), on macOS `-g 0 -j 1:2:2` (one GPU). A machine with another GPU set can override both with the environment variables `NCNN_GPUS` and `NCNN_THREADS`; `-j` needs one process value per GPU, for example:

```bash
NCNN_GPUS=0,1 NCNN_THREADS=4:2,2:6 ./interpolation_nncn -i "Episode.mkv"
```

With a wrong GPU number, NCNN stops at once (`invalid gpu device` in its log); the script reports it immediately instead of after the frame extraction.

NCNN is started through the real path of its executable (symlinks resolved), because it looks for its models (for example `rife-v4.6`) next to the path it was started with; a symlink such as `/usr/local/bin/rife-ncnn-vulkan` would otherwise make every frame fail.

NCNN and the frame extraction run in parallel, and NCNN sees all input frames from the start (empty placeholder files). If NCNN gets closer than `NCNN_EXTRACTION_MARGIN` input frames (default 50) to the extraction, the script pauses it (`SIGSTOP`) and resumes it (`SIGCONT`) once the extraction is twice the margin ahead or finished, so NCNN never reads a frame that is not written yet. Each pause and resume is logged in `LOG/<chunk>_ncnn_<method>_throttle.log`; no such file means NCNN never had to wait.

#### Blu-ray (BDMV/M2TS) stream details

The `.mpls` playlist describes all streams:

```bash
mediainfo --Output=JSON 00000.mpls | jq -r '.media.track[] | select(.ID == "4769") | .Language + "," + .Format'
```

#### Recognizing HDR and SDR

| Field | HDR | SDR |
| --- | --- | --- |
| Transfer characteristics (`color_transfer`) | PQ (`smpte2084`) or HLG | `bt709` |
| Color primaries (`color_primaries`) | `bt2020` | `bt709` |
| Color space (`color_space`) | `bt2020nc` | `bt709` |
| Bit depth | 10 bits or higher | usually 8 bits |

#### Tone mapping operators

| Operator | FFmpeg filter | Character |
| --- | --- | --- |
| `bt.2390` | `libplacebo` | ITU standard, broadcast-safe default |
| `hable` | `zscale` + `tonemap` | Filmic curve; keeps shadow and highlight detail |
| `reinhard` | `zscale` + `tonemap` | Brighter output if `hable` is too dark |
| `st2094-40` | `libplacebo` | HDR10+ with dynamic per-scene metadata |

#### HDR to SDR (tone mapping)

```bash
# zscale + hable -> 1449 frames in 230.05 s (6.30 fps), 153166.02 kb/s, Avg QP 4.00
ffmpeg -i input.mkv -vf "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p" -c:v libx264 -crf 20 -c:a copy output.mp4

# libplacebo + bt.2390 (used by the script) -> 1449 frames in 216.78 s (6.68 fps), 174360.50 kb/s, Avg QP 3.30
ffmpeg -i "peripheral_video_part_minute_045_for_test-conversion.mkv" -vf "libplacebo=tonemapping=bt.2390:colorspace=bt709:color_primaries=bt709:color_trc=bt709:format=yuv420p" -c:v libx265 -crf 0 -c:a copy "peripheral_video_part_minute_045_for_test-conversion_x265_lossless_libplacebo.mkv"
```

#### SDR to HDR (inverse tone mapping)

```bash
# Simple brightness expansion into BT.2020/PQ
ffmpeg -y -hide_banner -loglevel error -progress pipe:1 -i "${VIDEO_FILE_NAME}.mkv" -vf "zscale=primaries=bt709:transfer=linear,format=gbrpf32le,geq=r='r*2.0':g='g*2.0':b='b*2.0',zscale=primaries=bt2020:transfer=smpte2084:matrix=bt2020nc,format=yuv420p10le" -c:v libx265 -crf 0 -x265-params "hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400" -pix_fmt yuv420p10le "${VIDEO_FILE_NAME}_hdr.mkv"

# With a 3D LUT (open question: how to obtain sdr_to_hdr_upmap.cube in the first place?)
ffmpeg -y -hide_banner -loglevel error -progress pipe:1 -i "${VIDEO_FILE_NAME}.mkv" -vf "lut3d=file=sdr_to_hdr_upmap.cube,zscale=primaries=bt2020:transfer=smpte2084:matrix=bt2020nc,format=yuv420p10le" -c:v libx265 -crf 0 -x265-params "hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400" -pix_fmt yuv420p10le "${VIDEO_FILE_NAME}_hdr.mkv"
```

#### VMAF (encoding quality)

```bash
# Simplest form: prints the VMAF score
ffmpeg -i encoded.mkv -i reference.mkv -lavfi libvmaf -f null -

# Aligned timestamps, JSON log, explicit model and 24 threads
ffmpeg -i reference.mkv -r 20 -i encoded.mkv -lavfi "[0:v]setpts=PTS-STARTPTS[reference];[1:v]setpts=PTS-STARTPTS[distorted];[distorted][reference]libvmaf=log_fmt=json:log_path=/tmp/turniej_rumba.json:model='path=/usr/share/model/vmaf_v0.6.1.json':n_threads=24" -f null -
```

VMAF scores range from 0 to 100, where 0 is the lowest possible quality and 100 means identical to the reference. A score of 93–95 is generally considered the threshold for "broadcast quality" or "visually lossless": the average viewer cannot tell the compressed video from the source.

## Performance optimization

This section records the plan for speeding up `interpolation_nncn`, what has been done, and the measurements behind each decision. Target setup: Linux, AMD GPUs, 64 GB RAM, 1080p movies.

### Baseline (before optimization)

From `statistics.txt` rows for chunks 018–024 (RIFE, 60 s chunks), each chunk took about **1400 s**:

| Stage | Time per chunk | Notes |
|---|---|---|
| HDR → SDR tone mapping | ~250 s | sequential; writes an x265 `-crf 0` `_sdr.mkv` |
| Frame extraction | ~100 s | runs in parallel with NCNN |
| NCNN interpolation | ~290 s | GPU; parameters already tuned (`-j`, `-u`) |
| Merging frames into MKV | ~117 s | SVT-AV1 encode |
| VMAF (`-Q`) | ~700 s | before the VMAF fix below |

Peak space use per chunk was 30–37 GB of PNG frames.

### Done

1. **VMAF compares only the original frames** (commit `aea2e93`).
   - Distorted input first, reference second (checked against the FFmpeg docs).
   - Only frames at original positions are compared (`select='not(mod(n\,TARGET_FRAME_COUNT))'`), so interpolated frames have no reference and are skipped.
   - `n_threads=$(nproc)` uses all CPU cores.
   - Option `-Q` makes VMAF optional, because it is the slowest stage.
2. **Short videos are not split** (commit `b590ff5`): videos of up to 90 s (`NO_SPLIT_MAX_SEC`) are processed in one go.
3. **`-T` turns off tone mapping** (commit `b590ff5`): this skips the ~250 s stage when SDR output is not needed.
4. **Selectable intermediate codec** (`INTERMEDIATE_CODEC`, default `x264_lossless`; see the [`interpolation_nncn`](#interpolation_nncn) section).
   - The old setting was `libsvtav1 -crf 0 -preset 5 -svtav1-params rc=1:...`. In SVT-AV1, `rc=1` means **VBR**: it overrides `-crf`, and the encoder log showed a target bitrate of 2000 kbps. That explains the small files. Despite `-crf 0`, the result was lossy (PSNR ~46.6 dB).
   - Measured on Linux (second machine), chunk 029: merging frames **36 s** (was ~117 s), whole chunk **791 s** (was ~1400 s, together with the VMAF fix).
5. **Disk space and robustness:**
   - The frames-only video in `TMP_OUT` was never removed, so each chunk was stored twice (this filled the disk on Linux). It is now removed with the `_sdr`/`_hdr` chunks and frame directories once a chunk is done; `-k` keeps them.
   - NCNN that stops early (for example a wrong GPU number) is reported at once, before its frame-removal monitor deletes the frames the extraction is still writing.
   - FFmpeg features are checked at start-up (`libplacebo` for HDR unless `-T`, `libvmaf` with `-Q`); GPUs and NCNN threads follow the OS (macOS or the Linux rig) and can be overridden (`NCNN_GPUS`, `NCNN_THREADS`); `amdmemtweak` (no measurable gain) was removed.
6. **Tone mapping inside frame extraction.**
   - The `libplacebo` filter is now applied by the extraction `ffmpeg` (`-vf`), and VMAF applies the same filter to its reference. No `_sdr.mkv`/`_hdr.mkv` copies or symlink are made anymore; the chunk stays as it is.
   - Measured on the Mac, 300 frames of chunk 029 (4K HDR): old flow 186 s (x265 encode 122 s + extraction 64 s), new flow 62 s. `libplacebo` alone took 2.7 s, so the cost was the x265 encode, not the tone mapping. On Linux this should remove most of the ~250–340 s stage and 1.3 GB of disk per chunk.
   - The old `_sdr.mkv` was not lossless: x265 `-crf 0` is not lossless mode (PSNR 49.8 dB against the new frames). The extracted frames are now exact.
   - Extraction uses `-fps_mode passthrough`: one PNG per decoded frame. The image2 default (cfr) duplicated frames at timestamp gaps (260 PNGs from 252 frames in a test clip), so frame counts, NCNN and VMAF would not match.
   - Tested with a local FFmpeg 9.0.2 build on the Mac (Homebrew `libplacebo`, MoltenVK): `./configure --enable-gpl --enable-libplacebo --enable-vulkan --enable-libzimg --enable-libx264 --enable-libx265 --enable-libsvtav1 --enable-libvmaf`.
7. **First complete run on macOS.** A 14 s HDR clip of chunk 029 now runs end to end (VMAF 99.35). It needed:
   - `ps -p` instead of `ps --pid`: macOS `ps` has no `--pid`, so every monitor loop ended at once. The extraction monitor then deleted the empty placeholder frames after 5 s, so NCNN mapped frames wrongly and the merge found no frames.
   - NCNN started through its real path (models next to a symlink were not found).
   - NCNN paused while it is too close to the extraction (`NCNN_EXTRACTION_MARGIN`). On the Mac, extraction with tone mapping shares the GPU with NCNN and was slower, so NCNN read unwritten frames and crashed (exit 139).
   - The VMAF model built into libvmaf when `/usr/share/model/vmaf_v0.6.1.json` does not exist.
8. **VMAF in the background (`-Q`).** VMAF of chunk N runs alongside chunk N+1 instead of before it (on the Linux rig ~74 s per 4K chunk, about 16% of a chunk).
   - `starting_quality_metric` starts it and returns at once; `finishing_quality_metric` collects the result at the end of the next chunk (usually long finished), so only one VMAF runs at a time and statistics rows stay in chunk order.
   - `nice -n 10`: frame extraction and NCNN of the next chunk get the CPU first; VMAF uses what is left and keeps all its threads.
   - The `.done` marker is written right after the merge, before VMAF: an interrupted VMAF loses only its score, not the chunk. The source chunk (VMAF's reference) is removed after VMAF.
   - Ctrl+C or an error stops the background VMAF too (its subshell stops `ffmpeg` on SIGTERM).
   - `encoding_quality_metric` still does both steps in the foreground.
9. **Final encode of each part (`-E`).** Measured first: 5 minutes of 4K 50 fps (interpolated parts, `x264_crf10`), A = join the parts, then one HandBrake encode; B = encode each part, then join with mkvmerge.

   | | A (join, encode) | B (encode, join) |
   |---|---|---|
   | Encode time | 534 s | 541 s |
   | Size | 211.12 MB | 211.16 MB |
   | VMAF mean (frames 0–9000) | 95.20 | 95.24 |
   | VMAF ±5 frames at joins | ~93.6 | ~94.0 |
   | Frames | 15102 (2 lost) | 15104 (all) |

   - Size and quality are the same: SVT-AV1's look-ahead is short, so the longer context of A brings nothing measurable.
   - A lost 2 frames after the third join (HandBrake's sync; its log says "0 dropped"), so VMAF by frame index fails after that point. B kept every frame.
   - B can run in the background alongside the next chunk, so its encode time is hidden; A has to wait for the last chunk.
   - B needs one crop for all parts: HandBrake's auto-crop gave 3840×1596 for one part and 2992×1600 for another. One scan of the whole source takes ~6 s.
   - Audio: the source parts have a 16 ms gap at each join; B keeps them (as the merged parts do), A closed them (80 ms early by the end of 5 minutes).

### Codec benchmark

**Second run, native 4K.** The first run (below) scaled the frames down to 1920×800, a quarter of the pixels of chunk 029 (3840×1600, HDR), so its sizes were about 4× too low. This run used 300 PNG frames at native resolution, encoded as 50 fps, scaled to a 60 s chunk of 3000 frames, on the same Mac. VMAF compares each encode with the source frames. The frames were not tone-mapped (no `libplacebo` on the Mac); VMAF is not made for HDR (PQ) video, so its values are for comparison only.

| Codec / settings | Time (Mac) | Size | VMAF |
|---|---|---|---|
| **x264 `-qp 0 -preset ultrafast`** (default) | 107 s | 10.9 GB | 99.99 |
| x264 `-crf 10 -preset veryfast` | 187 s | 903 MB | 97.90 |
| svtav1 `-crf 5 -preset 8` | 141 s | 742 MB | 93.55 |
| svtav1 `-crf 10 -preset 8` | 141 s | 328 MB | 93.35 |
| svtav1 VBR 40 Mbps (`rc=1`) | 151 s | 296 MB | 92.15 |
| svtav1 VBR 20 Mbps (`rc=1`) | 147 s | 142 MB | 89.52 |

Findings:

- Lossless at 4K is ~11 GB per chunk, which matches the 7–13 GB per chunk seen on Linux.
- VBR is not better than CRF: at about the same size, CRF 10 (328 MB) scores higher than VBR 40 Mbps (296 MB). VBR aims at a size, CRF at a quality, so CRF fits an intermediate file better.
- SVT-AV1 seems to stop near VMAF 93.5 with `tune=0` (visual-quality tuning): CRF 5 is more than twice the size of CRF 10 for +0.2. `x264_crf10` reaches 97.9 at ~0.9 GB per chunk, about 12× smaller than lossless.
- On Linux, the lossless merge took 36 s versus 107 s here, so the Mac times are only relative.

**First run, scaled to 1920×800.** Test material: 500 PNG frames from `video_part_minute_029.mkv`, scaled to 1920×800 and encoded as 50 fps. Times are scaled to a 60 s chunk of 3000 frames. Run on a Mac (Apple M5, 10 cores); Linux numbers will differ. The quality of the encoded frames was compared with the source PNGs using PSNR.

| Codec / settings | Time | Size | Quality |
|---|---|---|---|
| svtav1 `rc=1` (old) | ~80 s | 18 MB | PSNR 46.6 dB |
| svtav1 `-crf 10 -preset 8` | ~20 s | 150 MB | PSNR 48.7 dB |
| x264 `-crf 10 -preset veryfast` | ~31 s | 350 MB | PSNR 51.1 dB |
| **x264 `-qp 0 -preset ultrafast`** | **~14 s** | 3.3 GB | lossless |
| ffv1 `-level 3 -slices 24` | ~32 s | 2.7 GB | lossless |
| x264 `-qp 0 -preset superfast` | ~44 s | 3.0 GB | lossless |
| svtav1 `lossless=1 -preset 8` | ~109 s | 3.1 GB | lossless (111 dB) |

Decision: lossless x264 `ultrafast` is the default because it is the fastest and loses nothing before the final HandBrake encode. The other codecs stay selectable for when disk space is short; at 4K, `x264_crf10` is the best trade-off of the lossy ones.

### Planned (in agreed order)

1. **Predictable deletion of input frames.** Track the highest contiguous output frame *m*. RIFE output frames 2k−1…2k+1 need input frame *k*, so input frames below ~*m*/2 can be deleted safely. This replaces the current log grep with its 300-frame margin. It could also let NCNN run without `-v`, if the NCNN pause (`throttling_ncnn`, which reads the last `done` line) also used the output frames instead of the log. The result is lower peak space use, which makes the next items possible.
2. **Pipe NCNN output into the merge.** Feed output frames in order into the merging `ffmpeg` (`-f image2pipe`) while NCNN is still running, so the merge overlaps with interpolation.
3. **Smaller items:**
   - replace fixed sleeps (`sleep 5` in extraction, `sleep 10` in the chunk loop, other 1–3 s sleeps) with event-based waits;
   - lower the PNG `-compression_level` (faster writes, larger files);
   - frames on tmpfs (RAM disk, `huge=always`) once peak space use is low enough for 64 GB RAM;
   - overlap whole chunks, for example extracting chunk N+1 while chunk N is interpolated (the most complex item).

### How to measure

Process the same chunk before and after a change (for example `-s 029` on `video_part_minute_029.mkv`) and compare the stage runtimes in `TMP/statistics.txt`. Use the same machine and settings for both runs.

## Runtime directories and logs

`.var_management` resolves and creates the workspace directories used by both scripts:

- `-o DIR` sets `VAR`, the workspace root. It defaults to `$HOME/var`.
- `-O DIR` sets `VAR_OUT`, a separate data/output root. It defaults to the same path as `VAR`.
- `TMP` and `LOG` are always created as `tmp-<script>_<timestamp>` and `log-<script>_<timestamp>` beneath `VAR`; values inherited from the environment (for example `TMP=/tmp`) are ignored, so every run gets fresh, private directories.
- Unless already set in the environment, `TMP_OUT` and `LOG_OUT` are created with the same naming pattern beneath `VAR_OUT`.

For `interpolation_nncn`, `-O` is where the large extracted and processed frame files are stored, so a fast volume with ample free space is useful. `-o` holds the script's workspace and logs. With the default settings, both roots point to `$HOME/var`. The script reports the resolved paths and available space in verbose mode. The scripts may also create chunk and merged video files in the current working directory; the `-O` option does not relocate all video outputs. Choose both the current directory and configured roots with enough free space. The helper checks that requested roots can be created, but the scripts' use of `df --block-size G` is GNU/Linux-oriented.

## Notes on option/help mismatches

The help output (`-h`) and the option parsers of both scripts list the same options; unknown options exit with code 2. `interpolation_nncn -h` separates the methods it supports (`rife`, `dain`, `cain`, `realsr`) from those that are listed but not supported yet.
