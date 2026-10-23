# Movie management scripts

This repository contains two Bash utilities for working with Matroska video:

- `movies_encoding` collects and updates movie metadata, and can start an AV1 encode.
- `interpolation_nncn` splits a video into one-minute chunks, processes the chunks with an NCNN/Vulkan image-processing tool, and merges each chunk's video with its audio and subtitle streams. Audio and subtitle tracks in Polish, Dutch, or English are extracted with `mkvmerge`, keeping their original language tags; if a chunk has audio but none in these languages, all its audio tracks are taken. Audio and subtitles are optional: a chunk without them is still processed, with a warning, and merged without them.

Both scripts load shared functions from `.config` (which loads `.config_colours` and `.config_video`) and use `.var_management` to create working, temporary, and log directories. Run the scripts from a working directory where you have space for the input, intermediate files, and outputs.

## Improvements

The scripts were improved step by step; each group below describes
what changed and why.

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
- `interpolation_nncn` checks the required tools (missing tool: exit 127) before doing any work, and accepts only `rife`, `dain`, `cain`, and `realsr`. An invalid `-s` value or unsupported method exits with code 2. It validates the video duration, the `mkvmerge` split result, the last chunk number, and each chunk file. NCNN failures are reported as errors, and Ctrl+C reports the matching method's logs and exits with code 130.

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

These are Linux-oriented Bash scripts and rely on external command-line tools. The movie script checks for `curl`, `mkvmerge`, `ffprobe`, `jq`, ImageMagick's `convert`, and `wget`. The workflows also use tools including `ffmpeg`, `mediainfo`, `HandBrakeCLI`, `mkvpropedit`, `bc`, `tput`, and `sudo`; the interpolation workflow additionally needs the matching `*-ncnn-vulkan` executable, Vulkan-capable hardware/drivers, and `amdmemtweak`. Install the tools needed for the workflow and selected interpolation method; this repository does not install dependencies.

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

The encode destination is currently hard-coded as `/media/ready` in `.config_video` (`DESTINATION_DIR`). Create that directory and ensure it is writable, or change the setting locally before using `-e`. The output is written with the source filename, and the HandBrake log is written beside it. The encoder is currently configured for SVT-AV1 10-bit at quality 22 and preset 5; audio is copied, and selected audio/subtitle tracks depend on language metadata in the input.

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
| `-Q` | — | Run the VMAF quality check for each processed chunk. Requires an FFmpeg build with `libvmaf` and the configured VMAF model. |
| `-S` | — | Sets an internal silent-mode variable. The current script does not consistently use it to suppress output, so normal progress output may still appear. |
| `-v` | — | Enable verbose diagnostics. |
| `-h` | — | Print usage information. |
| `-n` | `VALUE` | Accepted by the option parser but currently unused. |

The script divides input into 60-second MKV chunks in the current working directory. It processes chunks from the selected start number, retains per-chunk merged outputs, and removes intermediate chunk data as it completes. The final whole-video concatenation code is currently commented out, so the script does **not** automatically create one combined output video. After each chunk, a `~`-separated row is appended to `TMP/statistics.txt` with stage runtimes, peak space use, the VMAF mean (with `-Q`), and the total chunk runtime.

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

## Runtime directories and logs

`.var_management` resolves and creates the workspace directories used by both scripts:

- `-o DIR` sets `VAR`, the workspace root. It defaults to `$HOME/var`.
- `-O DIR` sets `VAR_OUT`, a separate data/output root. It defaults to the same path as `VAR`.
- `TMP` and `LOG` are always created as `tmp-<script>_<timestamp>` and `log-<script>_<timestamp>` beneath `VAR`; values inherited from the environment (for example `TMP=/tmp`) are ignored, so every run gets fresh, private directories.
- Unless already set in the environment, `TMP_OUT` and `LOG_OUT` are created with the same naming pattern beneath `VAR_OUT`.

For `interpolation_nncn`, `-O` is where the large extracted and processed frame files are stored, so a fast volume with ample free space is useful. `-o` holds the script's workspace and logs. With the default settings, both roots point to `$HOME/var`. The script reports the resolved paths and available space in verbose mode. The scripts may also create chunk and merged video files in the current working directory; the `-O` option does not relocate all video outputs. Choose both the current directory and configured roots with enough free space. The helper checks that requested roots can be created, but the scripts' use of `df --block-size G` is GNU/Linux-oriented.

## Notes on option/help mismatches

The parsers in the scripts are the authoritative list of accepted options. Some help text is stale: `interpolation_nncn` mentions `-f`, but does not accept it; `-n` is accepted but unused; and `-S` does not currently silence all output. The interpolation script's processing of chunk starts and its method support are also narrower than the help text suggests. These behaviors are documented here as implemented, not as intended future functionality.
