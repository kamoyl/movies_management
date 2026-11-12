# Movie management scripts

This repository contains two Bash utilities for working with Matroska video:

- `movies_encoding` collects and updates movie metadata, and can start an AV1 encode.
- `interpolation_nncn` splits a video into chunks of about one minute, at closed-GOP keyframes (a video of up to 90 seconds is processed as one chunk), processes the chunks with an NCNN/Vulkan image-processing tool, and merges each chunk's video with its audio and subtitle streams. Audio and subtitle tracks in Polish, Dutch, or English are extracted with `mkvmerge`, keeping their original language tags; if a chunk has audio but none in these languages, all its audio tracks are taken. Audio and subtitles are optional: a chunk without them is still processed, with a warning, and merged without them.

Both scripts load shared functions from `.config` (which loads `.config_colours` and `.config_video`) and use `.var_management` to create working, temporary, and log directories. Run the scripts from a working directory where you have space for the input, intermediate files, and outputs.

## Pitfalls the scripts handle

The idea is simple: split, interpolate, merge, encode, join. But
real movies break many quiet assumptions, and most of them show up
only on full-length films, never on short test clips. Each item
below cost a failed or out-of-sync run; the details are in
[Done](#done) and the sections linked.

**Splitting and frame counts**

- *Open-GOP keyframes.* A split at an open keyframe (CRA) leaves
  the frames shown just before it in the next chunk, which cannot
  decode them: NCNN crashed on empty frames, or video lost frames
  against audio. Splits prefer closed-GOP keyframes, and the frames
  lost at open splits are decoded from the whole movie
  ([Split points](#split-points); Done 10, 13).
- *False keyframe flags.* Some sources flag ordinary HEVC frames
  as keyframes; only keyframes that really decode alone are used
  (Done 10).
- *Sparse closed GOPs.* Some sources have closed GOPs minutes
  apart, so many splits must be open (Done 13).
- *Packets are not frames.* Frame counts come from decoding, not
  from packets (Done 10).
- *Timestamp gaps.* FFmpeg's image2 default duplicated frames at
  gaps; extraction writes one PNG per decoded frame (Done 6).

**Timing and sync**

- *Rounded frame rate.* ffprobe's text says `23.98 fps`; the
  exact rate is `24000/1001`. The rounded value drifted ~1.2 s
  over 2 hours (Done 13).
- *Joining parts.* `--append-mode track` closes gaps, so any
  part whose video is shorter than its audio shifts every later
  part (Done 13). It also adds each part's audio start offset
  again at every join, so the join takes only the parts' video,
  and the audio and subtitles from the source (Done 14).
- *Video start offset.* A chunk's video may not start at 0;
  HandBrake's output always does, so the mux re-applies the offset
  (Done 13).

**HandBrake**

- *TrueHD.* With TrueHD copied, HandBrake silently dropped a video
  frame per part and once hung; it now encodes video only, and
  `mkvmerge` adds audio and subtitles (Done 12).
- *Auto-crop per part.* Different parts got different crops; one
  crop is computed for the whole source (Done 9).
- *A/V sync on a joined file.* Encoding one joined file lost
  frames at joins; parts are encoded separately (Done 9).
- *Out of memory.* The kernel killed HandBrake (exit 137) with
  `-g` on 4K, and the run went on, leaving 13 GB merged parts
  until the disk was full; it now stops (Done 16).
- *Profile changed on resume.* Continuing with `-g` mixed two
  profiles in one movie; markers record it and a resumed run warns
  (Done 16).
- *Hang at 99.96 %.* SVT-AV1 `enable-overlays=1` deadlocked at
  the end of some parts; overlays are off, with the same quality
  (Done 28).

**Tools and encoders**

- *NCNN works on 8-bit images.* rife-ncnn-vulkan reads and writes
  8-bit images only, so HDR is tone mapped to SDR before
  interpolation (Planned item 5 is the research on more than
  8 bits).
- *NCNN racing the extraction.* NCNN could read frames not yet
  written, and a monitor could delete them; NCNN keeps a margin
  and early stops are detected (Done 5, 7).
- *"Lossless" settings that are not.* SVT-AV1 `rc=1` is VBR and
  overrides `-crf`; x265 `-crf 0` is not lossless (Done 4, 6).
- *VMAF pairs frames by number.* Only original frames are
  compared, and frames without a reference are skipped
  (Done 1, 12, 13).

**Shell and system**

- *Bare `wait`* waits for every background job, so background
  encodes and VMAF silently ran in series (Done 11).
- *Locale.* With a decimal comma (e.g. `nl_NL`), `printf` rejects
  `60.64`; `.config` sets `LC_NUMERIC=C`.
- *macOS.* `ps` has no `--pid`, so monitor loops ended at once
  (Done 7).
- *File names.* Dots, spaces and `$( )` in names; names are
  never split with `awk -F.` or evaluated ([Improvements](#improvements)).
- *Missing tracks.* No audio or subtitles in the wanted languages
  falls back with a warning instead of failing.

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

- `interpolation_nncn` resumes an interrupted run by default (before Done item 17 only with `-r`, which is still accepted). After a chunk finishes, a marker `video_part_minute_NNN_<method>_<fps>_merged.mkv.done` is written next to the merged chunk; it contains the whole movie name. A chunk is skipped only when its marker exists, the marker names the same movie, and the merged `.mkv` is non-empty. Otherwise the chunk is processed again. Resuming works with `-s`. Chunks finished before markers existed have no marker and are therefore processed again.
- `-F` starts from scratch: before splitting, it removes the results of an earlier run of the same movie and method in the current directory (each removal is listed): the merged and encoded parts whose marker names this movie, with their markers, and the split points file. With `-s`, only the chunks from that number on are removed, and the split points stay (the earlier chunks are joined with the new ones). Other files (chunks, unfinished parts) have generic names and are overwritten as the chunks are processed again. `-F` with `-r` exits 2.
- On exit, error, or Ctrl+C, `interpolation_nncn` stops the background processes it started, also the indirect ones (for example HandBrake in the encoding subshell), so they do not keep running after the script ends. The cleanup waits for exactly those processes, because one whose parent already ended is no longer a child of the script (before 8 Nov HandBrake ended after the cleanup and left a 0-byte `_video_only.mkv`).
- After a chunk's final encode (`-E`), its merged `.mkv` is removed together with its `.done` marker (kept with `-k`); the encoded part's own marker is written first.
- Ctrl+C, and since Done item 29 also a failed run (exit 1), cleans up (see Done item 18): it waits up to 10 seconds for those processes to end, then removes what the interrupted work left behind, with a count: the frame directories, the frame samples (`frame_analysis`), frames-only videos and audio/subtitle extracts in the run's TMP/TMP_OUT directories, the source chunks in the current directory (every run splits the movie again), and the parts without a `.done` marker (an unfinished merge or encode). Finished parts, their markers, `statistics.txt`, `timeline.csv` and the logs stay, so the next run resumes. With `-k`, nothing is removed. A second Ctrl+C stops the cleanup at once. Ctrl+C exits with 130, a failed run keeps its 1. At start-up a run also removes the frames and intermediate videos that earlier runs left when they could not clean up (`kill -9`), see Done item 29.
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

These are Linux-oriented Bash scripts and rely on external command-line tools. The movie script checks for `curl`, `mkvmerge`, `ffprobe`, `jq`, ImageMagick's `convert`, and `wget`. The workflows also use tools including `ffmpeg`, `mediainfo`, `HandBrakeCLI`, `mkvpropedit`, `bc`, `tput`, and `sudo`; the interpolation workflow additionally needs the matching `*-ncnn-vulkan` executable and Vulkan-capable hardware/drivers. `interpolation_nncn` no longer runs `amdmemtweak` (changing the memory refresh made no measurable difference). Install the tools needed for the workflow and selected interpolation method; this repository does not install dependencies. The one exception is the Excel run report of `interpolation_nncn`: on first use it creates a Python virtual environment `.venv` in the scripts' directory (gitignored) and installs `xlsxwriter` into it, which needs `python3` with the `venv` module and network access once.

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
| `-F` | — | Fresh start. By default a run resumes: it skips chunks already finished by an earlier run of the same movie and method in this directory (see "Resumable and predictable runs"). `-F` removes those results and processes the movie again; with `-s`, only from that chunk on. |
| `-r` | — | Resume. The default; still accepted so that existing commands work. Cannot be combined with `-F` (exit 2). |
| `-T` | — | No tone mapping: an HDR video is processed as HDR, without conversion to SDR. A warning is shown, because the colours of the processed frames may differ. Without `-T`, HDR is tone-mapped to SDR automatically. |
| `-k` | — | Keep the intermediate files of finished chunks: the frames-only video in `TMP_OUT` and the chunk's frame directories. Without `-k` they are removed once the chunk is done (its `.done` marker is written). The frames-only video is a full copy of the video track of `_merged.mkv`, so keeping it doubles the space needed per chunk. |
| `-Q` | — | Run the VMAF quality check for each processed chunk (processed chunk = distorted, first input; original chunk = reference, second input). For interpolation (`rife`, `dain`, `cain`) only the frames at original positions are compared, because in-between frames have no reference; the score shows what frame merging and encoding lost, not the quality of the interpolation itself. Uses all CPU cores. Requires an FFmpeg build with `libvmaf`; the model is `/usr/share/model/vmaf_v0.6.1.json` when that file exists (Linux packages), otherwise the `vmaf_v0.6.1` model built into libvmaf (for example Homebrew). An HDR reference is tone-mapped with the same filter as the extracted frames. VMAF runs in the background with lower priority (`nice -n 10`) alongside the next chunk; the source chunk is kept until its VMAF is done, and the last chunk's VMAF is waited for at the end. Off by default. |
| `-E` | — | Final encode of each part: after a chunk is merged, HandBrake encodes it in the background (`nice -n 10`) alongside the next chunk, with the same settings as `movies_encoding` (SVT-AV1 10-bit, quality 22, preset 5, audio copied). The crop is detected once, from the whole input, and passed to every part (HandBrake's automatic crop differs from part to part). After a successful encode the `_merged.mkv` part is removed (kept with `-k`). At the end the video of the encoded parts is joined with `mkvmerge --append-mode track`, with the audio and subtitle tracks taken from the source movie (the same tracks as the chunks), into `DESTINATION_DIR/<input name>.mkv` (default `/media/ready`) and removed (kept with `-k`). The run stops at start-up if the destination is missing or not writable (exit 1) or the final file already exists (exit 2). With `-Q`, VMAF compares the encoded part (not the merged one) with the source chunk, cropped the same way. A failed encode keeps its merged part and stops the run (exit 1) once the chunk processed alongside it is finished; run again with `-E`. See [Final encode of each part](#final-encode-of-each-part--e). |
| `-a` | — | With `-E`: animation profile (as `movies_encoding -a`). Without `-E`: exit 2. |
| `-g` | — | With `-E`: grain profile (as `movies_encoding -g`). Without `-E`: exit 2. |
| `-H` | — | With `-E`: high-motion profile (as `movies_encoding -H`). Without `-E`: exit 2. |
| `-S` | — | Silent, as a background service: the same command is started again as a transient systemd service `interpolation-<movie>-<timestamp>` in the system slice, run as your user in the current directory, and the launcher exits 0. All output goes to `LOG/interpolation_nncn_silent_<timestamp>.log`. Needs root or `sudo` (it may ask for your password); otherwise it exits (1, or 127 without `sudo`/`systemd-run`) and suggests running interactively. See [Silent run as a service](#silent-run-as-a-service--s). |
| `-M` | `SIZE` | With `-S`: `MemoryHigh` of the service, e.g. `20G`, `512M` or `50%`. Above it the kernel reclaims memory from the service's processes and slows them down, instead of letting memory run out. No limit by default. Without `-S` or with another format: exit 2. |
| `-v` | — | Enable verbose diagnostics. |
| `-h` | — | Print usage information. |

The script divides input into MKV chunks of about 60 seconds (`SPLIT_TIME_SEC`) in the current working directory, see [Split points](#split-points). A video of up to 90 seconds (`NO_SPLIT_MAX_SEC`) is not split: it is copied unchanged into one chunk, `video_part_minute_001.mkv`, and processed in one go; `-r`, `-Q`, and the statistics work the same way. It processes chunks from the selected start number, retains per-chunk merged outputs, and removes intermediate chunk data as it completes. Without `-E` the script does **not** create one combined output video. To join the merged parts yourself, take only their video (in `--append-mode track`) and the audio and subtitles from the source movie (add `--audio-tracks`/`--subtitle-tracks` IDs from `mkvmerge -i movie.mkv` to choose them):

```bash
mkvmerge --append-mode track -o joined.mkv \
  --no-audio --no-subtitles video_part_minute_001_rife_50_merged.mkv \
  + --no-audio --no-subtitles video_part_minute_002_rife_50_merged.mkv \
  + --no-audio --no-subtitles video_part_minute_003_rife_50_merged.mkv \
  --no-video --no-chapters movie.mkv
```

Joining the parts' own audio drifts: each part's audio starts at the source's first audio frame after the split (e.g. 20 ms after its video), and mkvmerge adds that start again at every join, see [Done](#done) item 14. Without `--append-mode track`, mkvmerge starts each part after the longest track of the previous one. A subtitle line that crosses the 60 s split keeps its full length (e.g. until 64 s), so the video gets a gap at that join, and an encoder later shows a frozen picture there. After each chunk, a `~`-separated row is appended to `TMP/statistics.txt` with stage runtimes, the chunk's peak space use (`max_space`, in GB, and as a percent of the estimate), the VMAF mean (with `-Q`), and the total chunk runtime. With `-Q` or `-E` a chunk's row is written once its VMAF and encode are done, so after the next chunk; `encoding_runtime` is the HandBrake encode of the part (`-E`), `quality_check_runtime` is VMAF's own runtime, and `runtime` no longer includes it, because VMAF runs alongside the next chunk. Tone mapping has no column of its own: it is part of the frame extraction, so its time is included in `extracting_frames_runtime`. The columns follow the order the steps run in: `extracting_streams`, `extracting_frames`, `interpolating`, `merging_frames`, `merging_streams`. (Files from older versions have `merging_streams_runtime` before `merging_frames_runtime`; even older ones have an extra second column, `tone_mapping_runtime`, and no `encoding_runtime` column.)

Each step of each chunk also gets a row in `TMP/timeline.csv` (`~`-separated), so the overlap of the steps can be charted:

| Column | Content |
|---|---|
| `video_id` | chunk number; `all` for `joining` (`-E`) and `whole_run` |
| `step` | `preparation`, `extracting_streams`, `extracting_frames`, `interpolating`, `merging_frames`, `merging_streams`, `encoding` (`-E`, HandBrake and mkvmerge), `quality_check` (`-Q`), `chunk` (the chunk's own wall time), `joining`, `whole_run` |
| `start`, `end` | wall clock time to 0.1 s, e.g. `2026-10-29 14:05:07.3` |
| `start_epoch`, `end_epoch` | the same as seconds since 1970, for calculations |
| `duration [s]` | to 0.1 s |
| `chunk [%]` | the duration as a percent of the chunk's `chunk` row, filled in at the end of the run (empty for an interrupted run) |

`encoding` and `quality_check` run in the background alongside the next chunk, so they can end after their chunk and exceed 100 %. Rows are in the order the steps ended. The sum of the step durations (without the `chunk` and `whole_run` rows) divided by `whole_run` is the average number of steps running at the same time.

### Silent run as a service (`-S`)

```bash
./interpolation_nncn -i "Movie.mkv" -E -g -S -M 24G
```

The launcher checks the options, the input and the tools as an interactive run does, so such errors show at once. Then it starts the same command with `sudo systemd-run` and prints:

- the unit name, e.g. `interpolation-Smokin_Aces_2006_-2026.11.02-16.50.33` (the movie name with characters systemd does not allow replaced by `_`, and the run's timestamp, the same as in its log directory);
- the log, and how to follow it: `tail -f '<log>'`;
- `systemctl status '<unit>'`, `sudo systemctl stop '<unit>'` and `systemctl list-units 'interpolation-*'`.

Why a system service:

- It survives closing the terminal, an SSH disconnect or a logout.
- It runs in the system slice, not in the user slice that `systemd-oomd` watches under memory pressure.
- It does **not** protect against the kernel's OOM killer, which chooses by memory use, whatever the slice (as with Smokin' Aces, Done item 16). `OOMScoreAdjust` was left out on purpose: protecting the run means the kernel kills something else (e.g. a VM). `-M` (`MemoryHigh`) slows the run down before memory runs out instead.

Details:

- Root or `sudo` is required, by choice: then the service has what an interactive run has (your user and groups, so the GPU, and `PATH`, `HOME`, `LANG`, `TERM`), and no fallbacks are needed. Run as root, it runs as root.
- `systemctl stop` sends SIGINT to every process of the service, as Ctrl+C does in a terminal, so the Ctrl+C cleanup runs (Done item 18) and finished chunks are kept; the run exits 130. Not to the script alone: bash runs its trap only after its current tool (NCNN, ffmpeg) ends. Whatever still runs after 120 s is killed.
- `--collect`: the unit disappears when it ends, also after a failure; its exit code is in the log.
- To resume, run the same command again (with or without `-S`).
- SELinux (enforcing) works without a policy change or `setenforce`: the service starts `/usr/bin/env bash <script>`, not the script itself. systemd (`init_t`) may not execute a script with a label such as `httpd_sys_content_t` (Smokin' Aces: `Permission denied` at step EXEC), but `/usr/bin/env` is `bin_t`, so the policy's transition `init_t → unconfined_service_t` applies, and that domain may read the script.

### Split points

- Splits are made at closed-GOP keyframes, so every chunk decodes on its own and no frame is lost. An open-GOP keyframe (HEVC CRA, for example) has frames before it in display order that need the previous chunk; with a plain 60 s split those frames were lost and NCNN crashed (see item 10 in [Performance optimization](#performance-optimization)).
- For each split the script takes the closed-GOP keyframe nearest to 60 s after the previous split, within ±`SPLIT_KEYFRAME_WINDOW_SEC` (default 10), so chunks are 50–70 s long. If there is none, it uses the first keyframe after 60 s and warns. The points are listed in `LOG/<movie>_split_points.log` (`pts closed|open`).
- At such an open split the frames shown just before the keyframe are stored after it, so they land in the next chunk, which cannot decode them. They are **recovered**: while the chunk before the split is prepared, the script finds them in the next chunk (packets shown before its first decoded frame), decodes them from the whole movie (`ffmpeg -copyts -ss`, from a keyframe before them, tone-mapped like the extracted frames), and adds them after the chunk's own frames. Then each part's video ends exactly where its audio ends, and the parts join without drift. It takes ~3 s per open split; log `LOG/<chunk>_recovering_frames.log`. If the recovery fails, the run warns and continues without those frames. See [Done](#done) item 13.
- Only keyframes the decoder can really start from count. A container may flag ordinary frames as keyframes (Edge of Tomorrow: 239 of 1948 flags, HEVC `TRAIL_R` frames), so the script decodes only the keyframes of the whole video (`ffprobe -skip_frame nokey`, ~22 s for a 2-hour 1080p movie, log `LOG/<movie>_decoded_keyframes.log`) and ignores every other keyframe flag.
- Each chunk's frame count is the number of decoded frames, not packets, so the count always matches the extracted frames.
- A chunk that starts after an open split has no video for its first frames (they were recovered into the previous chunk), so its processed video is placed at the time of its first decoded frame (`mkvmerge --sync`), and picture and sound stay in sync. This also fixes a source whose video does not start at 0 (for example 83 ms), which before led the sound by that much.
- The chosen points are saved in `<movie>_split_points.txt` in the current directory. With `-r`, or `-s` other than `001`, the run stops with exit 2 if the existing chunks were split at other points, or by an older version (chunks marked `.done` but no points file). Then start the movie again with `-F`. Without `-k` the file is removed after the `-E` join.
- Line 2 of that file is a fingerprint: the input's size and modification time and the split settings (`SPLIT_TIME_SEC`, `SPLIT_KEYFRAME_WINDOW_SEC`). A resumed run whose fingerprint still matches reuses the saved points and skips the scan (about 90 s for a 4K episode). With `-F`, a changed input or changed settings, or a file of an older version (one line), the points are chosen again.
- The movie is split by `mkvmerge --split timestamps:` in the background (log `LOG/<movie>_splitting_video.log`). Chunk N starts once `video_part_minute_(N+2).mkv` exists, so chunk N+1 is complete for the open-GOP recovery (mkvmerge closes a chunk before it opens the next one), or once mkvmerge has ended. Then the run checks mkvmerge's exit code and that the last chunk written is the expected one (one more than the split points); otherwise it stops with exit 1. Source chunks of an earlier run are removed before the split starts. With `-s`, each chunk before it is removed as soon as it is complete. Ctrl+C also stops mkvmerge and removes the chunks.

### Final encode of each part (`-E`)

```bash
INTERMEDIATE_CODEC=x264_crf10 ./interpolation_nncn -i "Episode.mkv" -E -Q
DESTINATION_DIR="$HOME/ready" ./interpolation_nncn -i "Episode.mkv" -E -g
```

- Each part is encoded while the next chunk is processed (~100 s per 4K 50 fps minute on the Linux rig, against ~6 min per chunk), so the final encode adds almost no time.
- The merged part is only a short-lived intermediate (HandBrake cannot read PNG frames or a pipe). It is removed right after its encode, so even lossless `x264_lossless` needs space for about two parts only.
- A finished part gets a `<part>_encoded.mkv.done` marker: the movie name, and on line 2 the profile (`film`, `grain`, `animation`, `highmotion`). With `-E`, encoded parts are skipped, and a merged part without its encode is encoded again. The join needs every part 001…last to be encoded; otherwise it stops with exit 1.
- A failed encode stops the run (exit 1), but only after the chunk processed alongside it is finished and marked, so no interpolation is lost; that chunk gets no row in `statistics.txt`. Going on would leave one merged part after another (13 GB each at 4K) when the encodes keep failing. Exit code 137 means HandBrake was killed (SIGKILL), most likely by the out-of-memory killer; the run says so (check `journalctl -k | grep -i oom`). Free memory (or encode without `-g` on 4K) and run again with `-E`.
- When resuming, a skipped part encoded with another profile than this run's (e.g. the run continued with `-g`) gets a warning, and the join lists such parts; markers of older versions have no profile (`unknown`). To encode such a part with the current profile, remove its `_encoded.mkv.done` marker: chunks are split again on every run, so the next run with `-E` processes it again.
- HandBrake logs: `LOG/<part>_encoded.mkv_handbrake.log`, crop scan `LOG/handbrake_crop_scan.json` (result) and `.log`, join `LOG/<movie>_joining_encoded_parts.log`.
- HandBrake encodes only the video of a part (`-a none -s none`). `mkvmerge` then copies the chosen audio and subtitle tracks (the same language choice as `movies_encoding`) from the merged part; its output follows HandBrake's in the same log. Copying a TrueHD track through HandBrake made it drop one video frame near the start of every part, without a message, see [Done](#done) item 12. HandBrake's video starts at 0, so the mux places it at the start of the merged part's video (`--sync`), as `merging_streams_mkv` does.
- Copying the audio through HandBrake again would not help with sync: the drift found in a joined movie came from frames lost at open-GOP splits, from a rounded frame rate, and from audio start offsets added at every join, the same with either audio path, see [Done](#done) items 13 and 14.
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

# Start the movie again from scratch (an earlier run's results are removed)
./interpolation_nncn -i "Episode.mkv" -E -F

# Also calculate VMAF for each processed chunk
./interpolation_nncn -i "Episode.mkv" -Q
```

### Interpolation reference notes

These notes were moved from the header comments of `interpolation_nncn` (the "Documentation" and "Helpers" sections). The open ToDo list stays in the script.

#### Further reading

- [HDR tone mapping in IPTV: BT.2390 vs BT.2446 vs Hable, explained](https://nightmaretv.net/learn/hdr-tone-mapping)
- [FFmpeg HDR to SDR tone mapping that doesn't look washed out](https://dev.to/masonwritescode/ffmpeg-hdr-to-sdr-tone-mapping-that-doesnt-look-washed-out-2026-24ie)
- [Understanding container formats: MP4, MKV, TS](https://www.shoutcastnet.com/school/understanding-container-formats-mp4-mkv-ts.php)
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

NCNN and the frame extraction run in parallel, and NCNN sees all input frames from the start (empty placeholder files). If NCNN gets closer than `NCNN_EXTRACTION_MARGIN` input frames (default 50) to the extraction, the script pauses it (`SIGSTOP`) and resumes it (`SIGCONT`) once the extraction is twice the margin ahead or finished, so NCNN never reads a frame that is not written yet. Each pause and resume is logged in `LOG/<chunk>_ncnn_<method>_throttle.log`. NCNN starts with the extraction, so one pause at the start of each chunk is normal; more pauses mean the extraction is slower than NCNN.

Between chunks the summary stays on screen for `CHUNK_SUMMARY_PAUSE_SEC` seconds (default 10, `0` = no pause; never under `-S`), for example `CHUNK_SUMMARY_PAUSE_SEC=0 ./interpolation_nncn -i "Movie.mkv"`.

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

#### SDR to HDR (dropped)

Inverse tone mapping was considered and dropped: it cannot restore highlight and color detail that the SDR master never had, so the result only looks brighter. Keeping an HDR source as HDR (`-T`) is the better path.

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
   - Audio: the source parts have a 16 ms gap at each join; B keeps them (as the merged parts do), A closed them (80 ms early by the end of 5 minutes). These gaps were a bug, fixed in item 14.
10. **Split at closed-GOP keyframes.** "Edge of Tomorrow" (HEVC 1080p) crashed NCNN (exit 139, segfault) at 99% of chunk 005, also with `-r` and `-s 005`.
    - The 60 s split fell on an open-GOP keyframe (CRA). The 3 frames before it in display order need the previous chunk to decode, so chunk 005 had 1522 packets but only 1519 decodable frames.
    - The frame count came from packets (`-c copy`), so 3 placeholder PNGs stayed empty and NCNN crashed reading them. Without the crash, 3 frames (125 ms) would be lost and the picture would lead the sound by 125 ms.
    - In the whole movie, plain 60 s splits hit 25 open keyframes of 107; the closed-GOP choice hits 6 of 113 (4 in the end credits, where every keyframe is open), with chunks of 50.9–69.5 s.
    - Checked: 6 chunks cut at the chosen points have packets = decoded frames, 8460 in total, the same as the source.
    - Cost: the packet scan of the 7.8 GB source takes ~3 s; counting decoded frames takes ~2 s per 1080p chunk and ~8 s per 4K HDR chunk.
    - The first full run then stopped at chunk 026 (exit 1): 239 of the 1948 keyframe flags in the source are on ordinary HEVC frames (`TRAIL_R`), and chunks 013 and 026 began at such a frame. Chunk 026 had 1433 packets but 1268 decodable frames (~7 s lost; 013 also lost frames but finished). Fix: only keyframes decoded by `-skip_frame nokey` count (22 s for the whole movie), and the time of a chunk's first decoded frame is read without the old 5 s limit.
    - Checked on the whole movie: 114 chunks, 107 decode completely; the 7 after the 7 warned open splits lose 1–4 frames each (20 of 163264), which the decoded frame count and the sync offset handle.
11. **Background encode and VMAF really in the background.** Each chunk waited for its own steps with a bare `wait`, which also waits for every other background job, so for the previous chunk's encode (`-E`) and VMAF (`-Q`) too. They ran alongside the next chunk only on paper.
    - Seen in the statistics: on the 1080p Edge of Tomorrow run, the analysis of chunk 002 took 36.8 s, about chunk 001's encode time. On Smokin' Aces (4K HDR, `-Q -E`) chunk 001, with nothing in the background, took 297 s; the later chunks averaged 568 s with the encode (145 s) and VMAF (62 s) of the previous chunk inside.
    - Fix: `waiting_for_chunk_steps` waits for all background jobs except the encode and VMAF job (`PART_ENCODING_PID`, `QUALITY_METRIC_CHECK_PID`), which `finishing_previous_chunk` collects as before.
    - Also: the "preparation … done" message showed the previous chunk's runtime.
    - `timeline.csv` (see [`interpolation_nncn`](#interpolation_nncn)) makes such overlap visible.
    - Checked on a 5:20 cut of the 4K HDR Edge of Tomorrow (6 chunks, `-Q -E`, `INTERMEDIATE_CODEC=x264_crf10`): the whole run took 2485 s. In the timeline each part's encode and VMAF now finish during the next chunk's interpolation. Chunks 002–005 took 384–456 s, against 468–512 s before the fix.
    - Overlap is not free: with an encode next to it, NCNN takes 315–375 s instead of 240–276 s and the encode 246–260 s instead of 111–127 s, as both share the CPU. The gain is about 10–15 % of wall time.
12. **TrueHD and per-part encodes (`-E`).** On a 4K HDR source with a TrueHD (Atmos) track, VMAF of the encoded parts fell to 40–63 (chunk 001: 95).
    - HandBrake's A/V sync, with the TrueHD track copied (`-E copy`), dropped one video frame near the start of each part (e.g. frame 9 of 480), without a message. AC3, DTS-HD and subtitles did not; converting the TrueHD to AC3 or `--align-av` kept all frames, but neither keeps the lossless track.
    - VMAF pairs frames by number, so after the drop it compared interpolated frames with the originals: PSNR 27 dB, 47 dB with the frame shift undone. Joined with `--append-mode track`, every part would also be one frame (21 ms) short against its audio.
    - Fix: HandBrake encodes the video only; `mkvmerge` copies the audio and subtitle tracks from the merged part. Checked: all frames kept, all 3 audio and 3 subtitle tracks present; VMAF of the same 6 parts is now 91.8–95.7.
    - With TrueHD copied, HandBrake also hung once at the end of a part ("audio time went backwards", 99.9 % for 2 h, process idle). The video-only encode avoids that path too.
    - Sources without TrueHD (the 1080p Edge of Tomorrow, Smokin' Aces with DTS/E-AC3/AC3) were not affected. `movies_encoding` still copies audio through HandBrake; there one frame of a whole movie does not matter.
13. **Joined movie in sync: frames recovered at open-GOP splits, exact frame rate.** The 4K HDR Edge of Tomorrow, run with `-Q -E` and its 71 encoded parts joined with `--append-mode track`, drifted more and more out of sync. Each part played fine on its own.
    - Cause 1, open splits: this source has a keyframe every ~10 s, but only 150 of its 681 keyframes start a closed GOP, with gaps of up to 420 s. So 68 of 113 splits had to be at open keyframes. At each, the 1–5 frames shown just before the split were stored after it, in the next chunk, which cannot decode them. For example, chunk 033 decoded 1437 of 1440 frames. The audio of the chunk went up to the split, but its video ended earlier, and the track-mode join (no gaps) moved all later video earlier by that much: 4.17 s by part 71. The `--sync` of the next chunk keeps a single part in sync, but cannot help the join.
    - HandBrake was not the cause. On a cut around one open split, the old (audio through HandBrake) and the current (video only + mkvmerge) parts joined with the same 42 ms shift.
    - Fix: `recovering_lost_frames` decodes the lost frames from the whole movie and adds them to the end of the chunk before the split, see [Split points](#split-points). The recovered frame was bit-identical to the same frame decoded from the whole movie, ~3 s per open split. VMAF ignores them (`libvmaf` `shortest=1`), as the reference chunk does not have them.
    - Cause 2, frame rate: it was read from ffprobe's text, `23.98 fps`, so the frames were merged at 47.96 instead of 47.952 fps. Each part was ~10 ms per minute too short, ~1.2 s over 2 hours. Now the exact `r_frame_rate` (`24000/1001`, so `48000/1001`) is used.
    - Also: the `-E` mux now places HandBrake's video (which starts at 0) at the start of the merged part's video (`--sync`).
    - Checked: a 200 s 1080p HDR cut with open GOPs (x265, keyframe every 10 s), 4 chunks, one split open, `-Q -E`. 3 frames were recovered. The joined movie has 9592 = 2 × 4796 frames, its video is as long as the source's (200.033 s), and every frame is within 1 ms of its source time (before the frame-rate fix: −32 ms at the end). Frames after the open split match their source frames (PSNR 43–45 dB, the neighbours 18–24 dB). VMAF of the parts: 93.5–99.7.
    - Parts encoded before this fix are short by those frames, so the movie has to be processed again.
14. **Joined movie in sync: audio and subtitles from the source.** "The Ball" (HEVC 1080p, 25 fps, 45:21, E-AC3), run with `-Q -E`, still drifted slowly after the fixes of item 13, although all 45 of its splits were closed.
    - The video was exact: 136072 = 2 × 68036 frames, every one at its source time. The audio had 45 gaps of exactly 20 ms, one at each join, 0.9 s at the end.
    - Cause: the source's audio starts 20 ms after its video (`start_time=0.020`, E-AC3 frames of 32 ms), so after each split at a whole minute the chunk's audio also starts 20 ms after its video. That is right for the part alone. But `--append-mode track` continues each track from its own end, and then adds the appended part's start offset again: the audio of the previous part already ends 20 ms after its video, and the next part's audio is placed 20 ms later still. The offset is the time from the split to the next audio frame, so it differs from source to source and from split to split.
    - The same gaps were in the Edge of Tomorrow join of item 13: 69 gaps, 4.54 s in total on its AC-3 track, on top of the 4.17 s of lost frames. Item 9 had already measured them (16 ms per join) without seeing them as a bug, and the check of item 13 compared only video frame times.
    - Subtitles were exact (all 5 tracks, every line at its source time).
    - Fix: `joining_encoded_parts` takes only the video of the encoded parts, and the audio and subtitles straight from the source movie, chosen like the chunk tracks (`tracks_by_language`, otherwise all audio). The source audio is one continuous stream without join points, and the joined video has the source's timeline. The encoded parts keep their own audio, so each still plays (and is checked by VMAF) on its own.
    - Copying the audio through HandBrake would have had the same gaps: they come from the split, not from the encoder.
    - Checked: the joined Ball with the source's audio has no audio gaps, and its audio timestamps are identical to the source's (85046 packets). A real `mkvmerge` join of three parts (0–180 s) has no gaps, all 4500 frames at their source times, and the same 7 tracks with their names.
    - A movie joined before this fix, whose video is right (made after item 13), needs no new run. Replace its audio and subtitles with the source's, as was done for The Ball (track IDs from `mkvmerge -i movie.mkv`):
      `mkvmerge -o fixed.mkv --no-audio --no-subtitles joined.mkv --no-video --no-chapters --audio-tracks 1 --subtitle-tracks 2,3,4,30,31 movie.mkv`

15. **Space monitor: divide by zero and a run-wide peak.** On The Ball, chunks 044 and 046 (dark end credits) printed `Runtime error (func=(main), adr=5): Divide by zero` and `printf: : invalid number`.
    - The space estimates were rounded to whole GB. They come from the average size of every 100th frame, and the PNGs of a dark chunk are small, so the estimate of its extracted frames became 0 GB, and the percent of it a division by 0.
    - Also, the peak space was carried from chunk to chunk: each new monitor read the peak file left by the previous one. So `max_space` in `statistics.txt` was the peak of the run so far (36 GB with 1800–3600 % on the small last chunks), not of the chunk.
    - Fix: the estimates keep two decimals; a percent is shown only for an estimate above 0 (otherwise `-`); an empty `du` result (a frame directory not created yet) counts as 0; the peak files and values are reset after each chunk's statistics row.

16. **Failed encode stops the run; the profile is recorded.** Smokin' Aces (4K HDR), started with `-Q -E -r` and continued with `-Q -E -g -r`: parts 025, 026, 028 and 029 kept their `_merged.mkv` (13 GB each) without an encode, and the disk later ran full.
    - HandBrake ended with exit code 137 (SIGKILL) at about 20 %: `dmesg` showed the kernel's out-of-memory killer at 11:59 and 12:13, killing HandBrakeCLI with about 14 GB in use. The machine has 62 GB, but its VMs held about 43 GB, swap was full, and the grain profile (`nlmeans`) on 4K needs a lot of memory. Parts 024 and 027 were encoded fine.
    - Keeping the merged part of a failed encode was by design (`-r -E` encodes it again), but the run went on, so every next failure left another 13 GB part.
    - Fix: `finishing_part_encoding` flags the failure (exit 137 is reported as most likely out of memory), and `stopping_after_failed_encode` stops the run with exit 1 once the chunk processed alongside is finished and marked, so no interpolation is lost. The failure is not retried at once: memory pressure from outside would most likely kill the retry too.
    - Also, `-r` did not know which profile a part had been encoded with, so continuing with `-g` gave parts 001–023 `film` and 024+ `grain`. The `_encoded.mkv.done` marker now has the profile on line 2 (only line 1, the movie name, is compared); `-r` warns for a skipped part of another profile, and the join lists them. Older markers count as `unknown`.
    - Planned next: running the background jobs through `systemd-run` with memory limits (done differently, see Done item 19).

17. **Resume by default; `-F` for a fresh start.** The user's idea: runs were almost always continued with `-r`, and a run without it processes finished chunks again (hours at 4K). A fresh start should be the explicit choice.
    - Resuming is safe as a default: a chunk is skipped only when its `.done` marker names the same movie and its part is non-empty, and a run stops with exit 2 when the chunks were split at other points.
    - `-F` (the user chose to remove, not to ignore, earlier results) removes this movie's finished parts and their markers for the chosen method, and the split points, before splitting, with a list. Only ignoring them, as without `-r` before, would let a later default run reuse parts of an interrupted fresh run, with possibly other settings. Chunk names are the same for every movie, so only parts whose marker names this movie are removed.
    - `-F -s 029` removes the results from chunk 029 on and keeps the split points, so it redoes one part of a movie (e.g. to measure a change, see [How to measure](#how-to-measure)); the first proposal rejected `-F` with `-s`, but then `-s 029` alone would just skip a finished chunk 029.
    - `-r` is still accepted, as the default, so existing commands keep working; `-F -r` exits 2. Messages say "run again with `-E`" instead of `-r -E`.
    - Also fixed: the check for chunks of an older version (no split points file) compared the whole marker with the movie name, so it missed the two-line encoded markers of Done item 16; it now compares line 1.

18. **Ctrl+C cleans up.** The user's idea: an interrupted run left gigabytes behind (frames of the current chunk, half-written parts, all source chunks), to be removed by hand.
    - Ctrl+C stops this run's processes, waits up to 10 seconds for them, and removes only what cannot be resumed: frame directories, frames-only videos and stream extracts in TMP/TMP_OUT, the source chunks, and parts without a `.done` marker. Only `in_NNN`/`out_NNN` directories, videos and extracts are removed from TMP/TMP_OUT; `statistics.txt` and `timeline.csv` live there too.
    - With `-k` (the user's choice), nothing is removed, as `-k` is for inspecting intermediates.
    - The `_merged.mkv.done` marker is now written before waiting for the previous chunk's encode and VMAF, so a Ctrl+C during that wait keeps the chunk which is already finished (before, it was processed again).
    - The chunk's audio and subtitle extracts in TMP are now removed when the chunk is done (they are in `_merged.mkv`), like its frames; before, they stayed until the end of the run.
    - Joining the parts encoded so far after Ctrl+C (a partial movie) is left for later.

19. **`-S` runs as a systemd service.** The user's idea: the silent run should be a background service started by `systemd-run`, in the system slice instead of a user one. See [Silent run as a service](#silent-run-as-a-service--s).
    - Before, `-S` only sent the output to a log; the script still ran in the terminal and ended with it.
    - The system slice keeps it out of the user slice that `systemd-oomd` watches, and the run survives a logout. The kernel OOM killer, which killed HandBrake in Done item 16, chooses by memory use whatever the slice; `OOMScoreAdjust` was left out (the user's choice), because then something else would be killed. `-M` adds `MemoryHigh` (throttling instead of killing).
    - Only with root or `sudo` (the user's simplification): no user-slice fallback, linger or permission checks; without them `-S` suggests an interactive run and exits.
    - The service gets the launcher's timestamp (`SERVICE_RUN_TIMESTAMP`, read by `.config`), so the log printed by the launcher is the one the service writes.
    - First design: `KillMode=mixed` (SIGINT to the script only). I caught this before committing: bash runs a trap only after its foreground tool ends, possibly after the stop timeout, so the cleanup would not run. SIGINT now goes to every process, as Ctrl+C does.
    - Not tested with a real `sudo systemd-run` here (no sudo or user manager in the test environment); the tests check the command line with fakes.

20. **Fixes after the first `-S` runs.**
    - SELinux: the service failed under enforcing SELinux (`Permission denied` at step EXEC; the user's workaround was `setenforce 0`). Options discussed: a permanent policy module, temporary permissive mode, a temporary module. Chosen: start the script through `/usr/bin/env bash`, which needs no policy change (see [Silent run as a service](#silent-run-as-a-service--s)).
    - Recovery of frames lost at an open-GOP split stalled: `select` ran before the tone mapping (`libplacebo`), which keeps a frame until the next one arrives, so `ffmpeg` decoded the rest of the movie. Smokin' Aces chunks with recovered frames spent ~490–500 s in preparation instead of ~12 s. Now the tone mapping runs first: a test seek took 3.5 s instead of more than 200 s, with the same frame (`pts_time` checked with `showinfo`). This was my bug from the recovery commit.
    - Frame analysis (the PNG size for the space estimate and the bit depth) decoded the whole chunk and kept every 100th frame. Now `sampling_frames` seeks to 7 evenly spaced points. On an idle machine (4K 10-bit, 60 s chunk) it is not faster (10.0 s vs 7.9 s), but it uses ~29 CPU-seconds instead of ~103, which matters when NCNN, HandBrake and VMAF run alongside; the average PNG size stayed within 0.1 %. My first estimate (~130 s saved per chunk) was wrong.
    - The Ctrl+C cleanup also removes `frame_analysis` (~300 MB at 4K), the only leftover in the user's test.
    - Logs are compressed with gzip, about 10 times smaller (one run: 9.5 MB → 0.9 MB): a chunk's logs when the chunk is done (also its encode and VMAF), the rest at the end of the run or after Ctrl+C / `systemctl stop` (the latter added after the user's test: I had missed that path). The silent log stays plain, as it is still being written. Read them with `zless`, `zgrep` or `vim`. Generic helper `compressing_logs` in `.config`.
    - The ToDo list from the script header moved to [Planned](#planned-in-agreed-order).
21. **Metrics, memory warning and Excel report** (first part of Planned item 1).
    - `metrics_sampling` (generic, in `.config`) writes one row every `METRICS_INTERVAL_SEC` (default 5) to `TMP/metrics.csv`, `~`-separated: CPU busy and iowait, memory used/available, swap, the run's cgroup memory (with page cache), disk read/write, per AMD GPU busy and VRAM, and the memory (RSS) of NCNN, `ffmpeg`, HandBrake and `mkvmerge`, plus their sum `tools_rss`. One `awk` per sample reads `/proc`, so the sampler costs almost nothing.
    - Before each background encode (`-E`), `checking_memory_headroom` compares the run's peak `tools_rss` with `MemAvailable` plus what the run holds now, with a 10 % margin. If it may not fit, it only warns (the OOM killer stopped HandBrake on Smokin' Aces twice: Done item 16, and 3 Nov). Before anything is measured the peak is `RUN_MEMORY_PEAK_DEFAULT_GB` (default 16 GB, a guess to tune after measured runs).
    - At the end of the run (and after a stop or an error exit, if `.venv` already exists; see item 22) `metrics_to_excel.py` writes `TMP/report.xlsx`: sheets with the metrics, timeline, steps per chunk and statistics, and charts (CPU, memory, memory per tool, GPU busy, VRAM, disks, chunk steps, background encode and VMAF). A failed report only warns. It follows the style of the user's `report_conversion.py` (xlsxwriter, `~`-separated input), which is Azure-specific and so was not reused directly.
    - The logs are now also compressed after Ctrl+C or `systemctl stop` (see item 20).
22. **HandBrake watchdog, leftover processes, memory estimate log** (after Smokin' Aces hung on chunk 097, 6 Nov, and Carnival Row, 7 Nov).
    - Watchdog: on chunk 097 HandBrake printed "99.96 %" from 10:58 on (52,395 progress lines against ~746 for a normal chunk) while the encoder was stuck. Now the encode is checked every 5 s; progress means a changed percentage or output size, not a growing log. After `HANDBRAKE_STALL_SEC` (default 600) without progress HandBrake gets SIGTERM, SIGKILL 10 s later, and the encode fails with 124 ("stopped by the watchdog"): the merged part is kept and the run stops with 1, so `-E` encodes it again. A `watchdog:` line in the HandBrake log tells why.
    - After Ctrl+C or `systemctl stop`, the user's processes still matching HandBrake, NCNN or `interpolation_nncn` are listed (PID, time, command) with how to stop them, so no new run is started beside a hung one. Nothing is killed automatically; another movie's run is listed too.
    - `TMP/memory.csv`: one row per final encode (also a failed one) with the estimate of `checking_memory_headroom` (available, held, can get, peak, needed, warned) and what was used meanwhile, from `metrics.csv` (min available, max swap, max `tools_rss`, max HandBrake). The report has a "memory" sheet and a chart per chunk. Carnival Row (7 Nov) showed the warning was not too pessimistic: it warned with ~18.8 GB to get against ~21.5 GB needed, and available memory fell to 0.00 GB at 08:46 (zram swap full, 8/8 GB) until the user stopped a VM; later it stayed at ~0.9 GB. HandBrake alone reached 16 GB. My first guess (summed RSS counting shared pages twice) was wrong: the cgroup's peak (21.3 GB) was even higher.
    - `report.xlsx` is now also written after an error exit (for example a failed encode, exit 1), by the EXIT trap (`exiting_function`), after the background jobs are stopped, so `metrics.csv` is complete; only if `.venv` exists and the metrics had started. A plain `kill` (SIGTERM) also runs the trap, but with `$?` 0, the same as a successful end, so it still gets no report (tested; nor does `kill -9`).
23. **Safe to edit during a run, GPU-lost message, report name** (after the Kindred runs of 2026-11-08).
    - The Kindred run broke after chunk 052 with `line 1180: syntax error near unexpected token 'in'`, although the code was valid. The cause was editing `interpolation_nncn` during the run (indentation cleanup, `#fi` and a dead commented block removed; the edit itself was correct). Bash reads a running script from the file piece by piece: the main loop had been read whole at the start, so all chunks ran, but after the loop bash continued at its old byte offset in the now shorter file, in the middle of a line. A simulation with the edited file landed exactly on `for RESULT_SUFFIX in`. The script body is now inside `{ ... exit; }`, so bash reads the whole file before running anything. The body is deliberately not indented, so the diff stays small and the tests that cut functions out with `^name()` keep working. Sourced files (`.config`, `.config_video`) are read whole by `source` anyway. A test puts a syntax error just before the final `exit` and checks that even `-h` reports it (without the braces `-h` exits before reaching it).
    - When NCNN fails with a Vulkan `failed -4` (`VK_ERROR_DEVICE_LOST`, as on chunk 041: 897 failures, with `amdgpu` errors in the kernel log), the error now adds that the GPU was lost and to check `journalctl -k`; a reboot may be needed before `-r`.
    - The report is named after the movie: `TMP/<movie>_report.xlsx` (plain `report.xlsx` if the run stopped before the movie name was known).
    - Decided against: keeping the `.done` state in the mkv metadata instead of marker files. A marker is written at once, is cheap to check and easy to see, and also holds the movie name and the profile; tagging would rewrite a 1–2 GB part in place.
    - Checked, no change: the shrinking available memory was not a leak. HandBrake stayed at about 16 GB for 5 hours; the 11 qemu VMs on the host (39 GB configured) grow towards their full size after a boot, which left about 19 GB for HandBrake, NCNN and ffmpeg.
24. **Split points reused on resume** (the user noticed the scan ran again on every resume).
    - `choosing_split_points` read all video packets and decoded all keyframes of the whole movie on every run, about 90 s for a 4K episode, although `<movie>_split_points.txt` was only used as a check. Now `checking_split_points_file` also writes a fingerprint (input size, modification time, `SPLIT_TIME_SEC`, `SPLIT_KEYFRAME_WINDOW_SEC`) as line 2, and `reusing_split_points` takes the saved points when it still matches. Size and mtime were chosen over a checksum: hashing a 20–60 GB movie would cost more time than the scan it saves. Files of older versions have no line 2, so they are scanned once more and then rewritten.
    - The whole movie is still split by mkvmerge on every run; starting the first chunk while the split is still running was done next, see item 25.
25. **Chunk 001 starts while the movie is still being split** (decided 2026-11-09, option A).
    - Before, `mkvmerge --split timestamps:` cut the whole movie into chunks before chunk 001 started: 104 s for a 20 GB movie, 2.8 s for a cached 2.8 GB episode, on every run. Now `starting_split` runs the same command in the background, `waiting_for_split_chunk` at the top of the chunk loop waits until `video_part_minute_(N+2).mkv` exists or mkvmerge has ended, and `finishing_split` reaps mkvmerge, checks its exit code and the last chunk name in its log (expected: number of split points + 1), and only then removes the chunks before `-s`. The chunks are byte-for-byte the same as before, as the command did not change.
    - Why N+2: chunk N+1 must be complete, because the open-GOP recovery of chunk N reads the first packets of chunk N+1. strace showed that mkvmerge closes a chunk before it opens the next one, so the existence of N+2 proves N+1 is complete.
    - The wait is at the top of the loop, also for chunks already done, because a skipped chunk removes its source file, which must exist first.
    - `waiting_for_chunk_steps` no longer waits on mkvmerge's PID (a bare `wait` would reap it, and its exit code would be lost).
    - Checked on Kindred with the real mkvmerge v102: chunk 001 was ready after 2 s, the whole split took 5 s. Tests use a fake mkvmerge: chunk 001 starts during the split, the last chunk waits for its end, `-s` cleanup, a failed split (exit code in the message, run stops with 1), a wrong number of chunks.
    - Rejected: cutting each chunk on demand with `mkvmerge --split parts:` (identical packets, but mkvmerge reads the movie from the start for every cut: 74 s at 90 % of a 20 GB movie) and `ffmpeg -ss … -c copy` (fast, but other packets).
    - Not gained: on a resume, chunks already done still wait for the split to reach them.
26. **Slow preparation explained, memory default raised** (Kindred runs of 2026-11-08, Planned item 1).
    - Preparation took ~119 s per chunk in the first run (chunks 002–041) and ~16 s in the rerun (041–052), with the same code (no commit between the runs). The frame count (a full decode, 6.7 s for a 60 s 4K chunk on an idle host) and the frame sampling (9.6 s) were not the cause, and the CPU was busy in both runs (77 % and 91 %).
    - `metrics.csv` showed the cause: in the first run, while the previous chunk's HandBrake encode ran (~16 GB), available memory fell to 0 and the 8 GB swap was full, with ~100 MB/s of disk reads (thrashing). Each preparation ended ~10 s after that encode ended, when ~14.7 GB came free. In the rerun ~12.5 GB stayed available. The memory warning (Done item 21) had warned in the first run (`memory.csv`: `warned yes`).
    - `RUN_MEMORY_PEAK_DEFAULT_GB`, used until the run has measured its own peak, is now 20 GB instead of 16: the measured 4K HDR peaks were 16.1 and 19.2 GB (Kindred) and 19.5 GB (Carnival Row).
    - Open: lowering HandBrake's memory (Planned item 1).
27. **Background split: stale chunks and leftovers** (Edge of Tomorrow runs of 9–10 Nov, the user's notes in `questions.txt`).
    - `-s 007` and `-s 008` stopped with `chunk 008 not found` a few seconds after the start, although `video_part_minute_008.mkv` was there. It was a chunk of an earlier run: `waiting_for_split_chunk` took the existing N+2 as "written", but the chunk's name was not in the split log yet. The 14 KB `video_part_minute_001.mkv` was mkvmerge rewriting chunk 001 when the run stopped. Now `starting_split` removes the source chunks first; they are split again on every run anyway.
    - The chunks before `-s` (e.g. 001–039 with `-s 040`, ~25 GB of the source) stayed until the end of the movie: `finishing_split` ran only when chunk N+2 did not exist, so in practice only at the last chunks. Now an ended mkvmerge is checked before the chunk, so the first wait after the split runs `finishing_split`, and `removing_chunks_before_start` also removes each complete chunk before `-s` while the split still runs.
    - Not a bug: `-s 029` started with chunk 030, because 029 had been interpolated by the run before (killed by the lost GPU while encoding); only its final encode was missing, which ran alongside 030.
    - Not changed here: the encodes of chunks 006 and 040 hung at 99.96 % (the last frame; the watchdog stopped them; fixed in Done item 28), and the encode of 051 was killed by the OOM killer (exit 137) with the 11 VMs using ~39 GB; see Planned item 4.
28. **HandBrake hang at 99.96 %: SVT-AV1 overlays off** (Edge of Tomorrow chunks 006 and 040, 9–10 Nov; probably also chunk 097 in Done item 22's watchdog note).
    - Reproduced outside the script: the full chunk 006 hung again at 99.96 % with exactly the same output size (30,670,848 bytes) as in the run, so the hang is deterministic, not memory or load.
    - Stack traces (`eu-stack`) of the hung HandBrakeCLI: HandBrake waited in `svt_av1_enc_get_packet` while all 125 SVT-AV1 threads waited in `svt_get_full_object`, a deadlock while SVT-AV1 flushes the end of the stream.
    - The cause is `enable-overlays=1` in `VIDEO_ENCODER` (HandBrakeCLI build 2024-06-21 with the system's SVT-AV1 3.1.2). With `enable-overlays=0` chunks 006 and 040 finished normally.
    - Turning overlays off costs nothing measurable: chunk 052 encoded both ways had VMAF 87.978 (on) and 87.972 (off) against the merged part, was 0.13 % smaller (162.9 vs 163.1 MB) and ~2 % faster (128–129 s vs 130–131 s, two runs each, one after another on an idle machine; a first measurement showed ~32 %, but a VMAF check ran alongside the overlays-on encode).
    - Chosen: `enable-overlays=0`. A newer HandBrake was not tried: the setting brings no gain, so removing it is the simpler fix.
29. **Cleanup after a failed run, and of earlier runs** (the user found extracted and interpolated PNGs left behind, 10 Nov).
    - Only Ctrl+C cleaned up (Done item 18). A run that stopped with an error (exit 1: a lost GPU, an encode stopped by the watchdog or killed by the OOM killer) only stopped its processes, so the frames of its current chunk stayed. Now a failed exit runs the same cleanup; finished parts and their markers stay.
    - A run killed with `kill -9` (or a lost machine) can run no cleanup, and each run has its own TMP, so a later run never saw those frames. Now every run writes `run.pid` into its TMP/TMP_OUT (not with `-k`), and at start-up removes the frame directories and intermediate videos of earlier runs whose `run.pid` names a process that has ended. A running run, a `-k` run and directories of runs before this change (no `run.pid`) are left alone; their logs, CSVs and reports always stay.
    - Discussed with the user and dropped from the plan (10 Nov): reusing the split chunks (the split runs in the background now, and reusing old chunks caused the "chunk 008 not found" of Done item 27), waiting for memory before NCNN, GPU-loss handling and lowering HandBrake's memory: the warnings say enough, the user decides.
30. **Faster frame extraction: PNG compression level 1** (first performance item of the order agreed on 10 Nov).
    - The extracted frames were written with ffmpeg's default zlib level (6). `PNG_COMPRESSION_LEVEL` (`.config_video`, default 1) is now passed to the extraction and to the frame recovery at open-GOP splits; PNG is lossless at every level, so the frames are the same.
    - Measured on 240 4K HDR frames of Edge of Tomorrow with the tone-mapping filter, levels alternated, on the NVMe drive of `VAR`: level 1 took 8.4–9.2 s for 1509 MB, level 6 13.5 s for 1314 MB, so ~35 % faster for ~15 % more space. For a 60 s chunk (~1440 frames) that is ~28 s less extraction and ~1.2 GB more peak space. Level 0 (no compression) was slower than level 1, as its 3.7× larger files made the disk the limit. Reading the frames back took the same time at every level.
    - NCNN's output PNGs are written by rife-ncnn-vulkan itself and cannot be changed without rebuilding it.
    - **Measured in a real run** (Edge of Tomorrow, 4K HDR, same options; the user's estimate was ~25 %). `timeline.csv` steps that started 9 Nov 11:11 – 10 Nov 11:41 (before overlays off, Done item 28) against 10 Nov 12:37–20:00 (with overlays off and PNG level 1), the run with the end credits left out. Averages per chunk, ~50 chunks each:

      | Step | Before | After |
      |---|---|---|
      | Preparation | 59 s | 23 s |
      | Extracting frames | 115 s | 63 s |
      | Interpolating (NCNN) | 349 s | 319 s |
      | Encoding (background) | 292 s (median 285 s) | 208 s (median 212 s) |
      | **Chunk** | **474 s** | **397 s (−16 %)** |

      Time between finished parts (the throughput, background work included): median 518 s → 398 s, **~23 % faster**.
    - The gain is larger than the idle measurements predicted (~28 s for extraction, ~2 % for overlays). Probable reason, not proven: the background encode runs alongside the next chunk's extraction, and zlib level 6 took CPU from HandBrake and NCNN. Freeing it shortened the encode, which also took less memory away from the next chunk's preparation (see Done item 26). Three "before" encodes (686–832 s) were the hang of Done item 28. Before and after cover different parts of the film, so scene content may account for part of the difference.

31. **No fixed waits on the main path of a chunk** (12 Nov, Planned item 4).
    - The 10 s pause between chunks only kept the summary on screen. It is now `CHUNK_SUMMARY_PAUSE_SEC` (`.config_video`, default 10, `0` = no pause, a whole number of seconds or exit 2), and a `-S` service, which has no screen, never pauses. For Edge of Tomorrow (118 chunks) that is ~20 min per film under `-S`.
    - The 5 s wait after the frame extraction starts held up every chunk. It now runs inside the background progress monitor. NCNN no longer gets a 5 s head start; `throttling_ncnn` pauses it until the extraction is `2 × NCNN_EXTRACTION_MARGIN` frames ahead, so a `_throttle.log` with one pause at the start of each chunk is now expected.
    - Saved per chunk: ~15 s (~4 % of ~400 s) under `-S` or with `CHUNK_SUMMARY_PAUSE_SEC=0`, ~5 s on the screen with the default pause.

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

Order agreed on 10 Nov: performance first (the fixed sleeps and PNG compression of item 4, then items 2 and 3), then `-N none` as the first step of combining `interpolation_nncn` with `movies_encoding`, then hardening the `-S` service. Dropped: see Done item 29.

State over time, Smokin' Aces (4K HDR, 23.976 → 47.952 fps, `-Q -E`), average per chunk without chunk 001:

- **Baseline:** see [Baseline](#baseline-before-optimization).
- **≤ 29 Oct:** `statistics.txt` rows of chunks 002–041, before Done item 11. The encode was probably without `-g` (the profile was not recorded yet), which explains the faster encode.
- **3–5 Nov:** `timeline.csv` of the runs of 3 and 5 Nov (34–36 chunks), after Done item 20, with `-g`.

| Step | Baseline | ≤ 29 Oct | 3–5 Nov |
|---|---|---|---|
| Preparation (probes, frame analysis, frame count, recovery) | — | — | ~59 s |
| Extracting frames (including tone mapping) | ~350 s (tone mapping 250 + extraction 100) | ~101 s | ~114 s |
| NCNN interpolation | ~290 s | ~304 s | ~379 s |
| Merging frames | ~117 s | ~35 s | ~35 s |
| Merging streams | — | ~29 s | ~35 s |
| Final encode (`-E`, background) | — | ~145 s | ~293 s (`-g`) |
| VMAF (background) | ~700 s | ~62 s | ~96 s |
| **Chunk total** | **~1400 s** | **~568 s** | **~515 s** |

- In the ≤ 29 Oct runs, chunk 001, with nothing in the background yet, took 297 s; the gap to 568 s was mostly the serialized encode and VMAF (Done item 11).
- Between them, the runs of 1–2 Nov averaged ~851 s per chunk: frame recovery at open-GOP splits stalled (preparation ~441 s, up to 700 s), fixed in Done item 20.
- 3–5 Nov: NCNN is ~75 s slower than before, probably because the slower `-g` encode now overlaps it; the metrics (item 1) should show it.
- Carnival Row (4K HDR, same options) spent ~120–135 s per chunk in preparation, against ~59 s for Smokin' Aces. Explained in Done item 26: the host was out of memory while the previous chunk's encode ran, not the code; with free memory it took 16–20 s.

1. **Metrics, before further optimization.** The sampling, the memory warning and the Excel report are done (Done item 21). Still open, once a real run has collected metrics:
   - explain the slower NCNN (Carnival Row's preparation and `RUN_MEMORY_PEAK_DEFAULT_GB` are done, see Done item 26);
2. **Predictable deletion of input frames.** Track the highest contiguous output frame *m*. RIFE output frames 2k−1…2k+1 need input frame *k*, so input frames below ~*m*/2 can be deleted safely. This replaces the current log grep with its 300-frame margin. It could also let NCNN run without `-v`, if the NCNN pause (`throttling_ncnn`, which reads the last `done` line) also used the output frames instead of the log. The result is lower peak space use, which makes the next items possible.
3. **Pipe NCNN output into the merge.** Feed output frames in order into the merging `ffmpeg` (`-f image2pipe`) while NCNN is still running, so the merge overlaps with interpolation.
4. **Smaller items:**
   - replace the remaining fixed sleeps (1–3 s polling intervals in the progress loops) with event-based waits; the `sleep 5` and `sleep 10` on the main path are done (Done item 31);
   - `-S` passes only `PATH`, `HOME`, `USER`, `LANG` and `TERM` to the service, so `INTERMEDIATE_CODEC`, `PNG_COMPRESSION_LEVEL` and the other variables are ignored there (found 12 Nov; part of hardening the `-S` service);
   - overlap whole chunks, for example extracting chunk N+1 while chunk N is interpolated (the most complex item);
   - encode-only mode with `-N none` (no interpolation), so `movies_encoding`-style encodes use the same chunked pipeline; compare chunked and whole-file encoding once. The first step of combining `interpolation_nncn` with `movies_encoding`.
5. **Research: interpolation above 8 bits (keep HDR without tone mapping).** Today an HDR source must be tone mapped to 8-bit SDR before NCNN. The limit is in rife-ncnn-vulkan's input/output, not in the network:
   - `main.cpp` loads images with `stbi_load_from_memory(…, 3)` (8 bits per channel), so a 10/16-bit PNG is cut to 8 bits on load; `stbi_write_png` writes 8 bits;
   - the GPU shaders convert `uint8` ↔ float: `rife_preproc.comp` multiplies by `1/255`, `rife_postproc.comp` by `255` and clamps to `0..255`;
   - the network itself works on floats `0.0…1.0`, stored as fp16 on the GPU (~11 bits of precision, enough for 10-bit video).

   Options to check:
   - a fork of rife-ncnn-vulkan: `stbi_load_16`, `uint16`/`65535` in both shaders, and 16-bit PNG output via libpng (`stb_image_write` cannot write 16 bits);
   - vs-mlrt (VapourSynth): runs the same RIFE models on 32-bit float RGB frames, with a Vulkan (ncnn) backend usable on the RX580s; frames stay in memory, so the PNG pipeline would change.

   Open risk: RIFE was trained on 8-bit SDR images; HDR in PQ encoding has a different brightness distribution, so the quality has to be measured (VMAF, visual check) before it is used.

**Early ToDo list** (moved from the header of `interpolation_nncn`; new ideas start as drafts in `questions.txt`):

- Open:
  - more `-v` (verbose) diagnostics where needed;
  - least priority: let every `ffmpeg` call use `FFMPEG_GLOBAL_OPTIONS`.
- Done:
  - the `in`/`out` directories carry `CURRENT_TIMESTAMP`;
  - `-o`/`-O` (var, var_out) are picked up correctly;
  - help and documentation moved into the script, later into this README;
  - quality analysis (VMAF, `-Q`);
  - failed interpolation moments shown after a run, also after Ctrl+C;
  - HDR converted to SDR (tone mapping), unless `-T`;
  - a video up to `NO_SPLIT_MAX_SEC` is processed without splitting;
  - silent version (`-S`, now a systemd service);
  - the parts are joined only when all of them exist (`-E`).

Dropped after measuring: **frames on tmpfs.** An 83 s 1080p clip (one chunk, `x264_crf10`), run twice with `-o`/`-O` on NVMe and twice on `/dev/shm`, took 115.6–115.7 s in every run (stages: extraction 21.1 s, NCNN 85.7–87.7 s, frame merge 17.7–18.2 s). PNG writing and reading are CPU work and NVMe keeps up, so RAM adds nothing; a 4K chunk (30–37 GB) would not fit anyway.

### How to measure

Process the same chunk before and after a change (for example `-F -s 029` on `video_part_minute_029.mkv`; without `-F` a finished chunk is skipped) and compare the stage runtimes in `TMP/statistics.txt`. Use the same machine and settings for both runs. `TMP/metrics.csv` and `TMP/<movie>_report.xlsx` (Done items 21 and 23) show what the machine was doing meanwhile.

## Runtime directories and logs

`.var_management` resolves and creates the workspace directories used by both scripts:

- `-o DIR` sets `VAR`, the workspace root. It defaults to `$HOME/var`.
- `-O DIR` sets `VAR_OUT`, a separate data/output root. It defaults to the same path as `VAR`.
- `TMP` and `LOG` are always created as `tmp-<script>_<timestamp>` and `log-<script>_<timestamp>` beneath `VAR`; values inherited from the environment (for example `TMP=/tmp`) are ignored, so every run gets fresh, private directories.
- Unless already set in the environment, `TMP_OUT` and `LOG_OUT` are created with the same naming pattern beneath `VAR_OUT`.

Logs of `interpolation_nncn` are compressed with gzip (`name.log.gz`) when nothing writes to them anymore: a chunk's logs when the chunk is done, the rest at the end of the run or after Ctrl+C / `systemctl stop`. Read them with `zless`, `zgrep` or `zcat`. The silent log (`-S`) stays plain; after an error exit, the logs of the last chunk stay plain too (its processes may still be ending).

Next to `timeline.csv`, `TMP` of `interpolation_nncn` holds `metrics.csv` (machine and tool metrics every 5 s), `memory.csv` (memory estimate and use per final encode, Done item 22) and, at the end of the run (also after Ctrl+C or an error exit), `<movie>_report.xlsx` with charts; see Done items 21 and 23.

For `interpolation_nncn`, `-O` is where the large extracted and processed frame files are stored, so a fast volume with ample free space is useful. `-o` holds the script's workspace and logs. With the default settings, both roots point to `$HOME/var`. The script reports the resolved paths and available space in verbose mode. The scripts may also create chunk and merged video files in the current working directory; the `-O` option does not relocate all video outputs. Choose both the current directory and configured roots with enough free space. The helper checks that requested roots can be created, but the scripts' use of `df --block-size G` is GNU/Linux-oriented.

## Notes on option/help mismatches

The help output (`-h`) and the option parsers of both scripts list the same options; unknown options exit with code 2. `interpolation_nncn -h` separates the methods it supports (`rife`, `dain`, `cain`, `realsr`) from those that are listed but not supported yet.
