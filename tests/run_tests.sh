#!/usr/bin/env bash
# shellcheck disable=SC2016  # code passed to run_with_helpers is single-quoted on purpose (expanded in the child bash)
# Step 5: dependency-free tests for the scripts.
#
# Run from anywhere:  bash tests/run_tests.sh
#
# The tests never load the full .config (it contacts the network and expects
# Linux video tools). Instead they:
#   - run the scripts only for paths that exit before .config is loaded (-h, bad options);
#   - load helper functions from .config_video with stubbed logging (error/warn/inf/debug);
#   - replace external tools such as ffmpeg with tiny fake scripts put first on PATH.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# work files stay inside the repository (tmp/ is gitignored), named like the scripts' log directories
mkdir -p "${REPO_ROOT}/tmp"
WORK_DIR="$(mktemp -d "${REPO_ROOT}/tmp/tmp-run_tests_$(date "+%Y.%m.%d-%H.%M.%S")_XXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

# assert_status NAME EXPECTED ACTUAL
assert_status()
{
  if [ "$2" -eq "$3" ]
  then
    pass "$1"
  else
    fail "$1" "expected exit status $2, got $3"
  fi
}

# assert_contains NAME TEXT EXPECTED_SUBSTRING
assert_contains()
{
  if [[ $2 == *"$3"* ]]
  then
    pass "$1"
  else
    fail "$1" "expected output to contain: $3"
  fi
}

# Plain logging stubs used instead of the coloured versions from .config
STUBS='
error() { printf "ERROR:%s\n" "$*"; }
warn()  { printf "WARN:%s\n" "$*"; }
inf()   { printf "INFO:%s\n" "$*"; }
debug() { :; }
start_time_collecting() { :; }
end_time_collecting()   { RUNTIME="0s"; }
'
FAILED_FUNCTION="$(sed -n '/^function failed {/,/^}/p' "${REPO_ROOT}/.config")"

# run_with_helpers 'BASH CODE' - runs code in a fresh bash (inside WORK_DIR)
# with the stubs, the real failed() and .config_video loaded
run_with_helpers()
{
  bash -c "${STUBS}
${FAILED_FUNCTION}
source '${REPO_ROOT}/.config_video'
cd '${WORK_DIR}' || exit 99
$1"
}

echo "command-line options"
for SCRIPT_NAME in interpolation_nncn movies_encoding
do
  OUTPUT="$(TERM=dumb bash "${REPO_ROOT}/${SCRIPT_NAME}" -h 2>&1)"; STATUS=$?
  assert_status   "${SCRIPT_NAME} -h exits 0" 0 "${STATUS}"
  assert_contains "${SCRIPT_NAME} -h shows its own name" "${OUTPUT}" "${SCRIPT_NAME} -i FILE"
  TERM=dumb bash "${REPO_ROOT}/${SCRIPT_NAME}" -z > /dev/null 2>&1
  assert_status   "${SCRIPT_NAME} rejects an unknown option with 2" 2 $?
  TERM=dumb bash "${REPO_ROOT}/${SCRIPT_NAME}" -i > /dev/null 2>&1
  assert_status   "${SCRIPT_NAME} rejects -i without a value with 2" 2 $?
done
OUTPUT="$(TERM=dumb bash "${REPO_ROOT}/interpolation_nncn" -h 2>&1)"
assert_contains "interpolation_nncn -h documents -r (resume)" "${OUTPUT}" "-r  resume"
assert_contains "interpolation_nncn -h separates unsupported methods" "${OUTPUT}" "not supported yet"
assert_contains "interpolation_nncn -h documents -T (no tone mapping)" "${OUTPUT}" "-T  no tone mapping"

echo "failed: never exits 0"
run_with_helpers 'ERROR_CODE=2; failed' > /dev/null
assert_status "uses ERROR_CODE when set" 2 $?
run_with_helpers 'error "boom"; failed' > /dev/null
assert_status "exits 1 when the last status was 0" 1 $?
run_with_helpers '(exit 7); failed' > /dev/null
assert_status "falls back to the last command status" 7 $?

echo "require_output"
run_with_helpers 'echo data > present.mkv; require_output present.mkv "test step"' > /dev/null
assert_status "accepts a non-empty file" 0 $?
OUTPUT="$(run_with_helpers ': > empty.mkv; require_output empty.mkv "test step" some.log; echo continued')"; STATUS=$?
assert_status   "stops on an empty file" 1 "${STATUS}"
assert_contains "names the log to read" "${OUTPUT}" "see log: some.log"

echo "mkvtoolnix_status (0 ok, 1 warnings, 2 error)"
OUTPUT="$(run_with_helpers 'mkvtoolnix_status 1 "split"; echo continued')"; STATUS=$?
assert_status   "status 1 continues" 0 "${STATUS}"
assert_contains "status 1 warns" "${OUTPUT}" "WARN:"
run_with_helpers 'mkvtoolnix_status 2 "split"; echo continued' > /dev/null
assert_status "status 2 stops with 1 (processing error)" 1 $?

echo "safe_remove_dir"
run_with_helpers 'TMP="$PWD/tmp"; TMP_OUT="$PWD/out"; mkdir -p "$TMP/in_001/My Movie.v2"; safe_remove_dir "$TMP/in_001/My Movie.v2"; [ ! -e "$TMP/in_001/My Movie.v2" ]' > /dev/null
assert_status "removes a directory (spaces and dots) inside TMP" 0 $?
for BAD_PATH in '/etc/x' '' '$TMP' '$TMP/' '$TMP/../x'
do
  run_with_helpers "TMP=\"\$PWD/tmp\"; TMP_OUT=\"\$PWD/out\"; safe_remove_dir \"${BAD_PATH}\"" > /dev/null
  assert_status "refuses '${BAD_PATH}'" 1 $?
done
run_with_helpers 'TMP=""; TMP_OUT=""; safe_remove_dir "/in_001/x"' > /dev/null
assert_status "refuses everything when TMP and TMP_OUT are empty" 1 $?

echo "remove_numbered_frames"
OUTPUT="$(run_with_helpers 'mkdir f; for n in 1 2 3 4 5 6; do printf -v x "f/%08d.png" $n; touch "$x"; done
touch "f/\$(touch PWNED).png"
remove_numbered_frames f 1 4; ls f | tr "\n" " "; [ -e PWNED ] && echo EXECUTED')"
assert_contains "keeps frames after the range" "${OUTPUT}" '00000005.png 00000006.png'
if [[ ${OUTPUT} == *00000001.png* || ${OUTPUT} == *00000004.png* ]]; then fail "removes frames 1-4" "left: ${OUTPUT}"; else pass "removes frames 1-4"; fi
assert_contains "keeps unrelated files" "${OUTPUT}" '$(touch PWNED).png'
if [[ ${OUTPUT} == *EXECUTED* ]]; then fail "file names are never executed"; else pass "file names are never executed"; fi
run_with_helpers 'mkdir g; touch g/00000001.png; remove_numbered_frames g 1 abc; [ -e g/00000001.png ]' > /dev/null
assert_status "does nothing for a non-numeric range" 0 $?

echo "mp4_to_mkv (ffmpeg replaced by a fake)"
mkdir -p "${WORK_DIR}/bin"
cat > "${WORK_DIR}/bin/ffmpeg" <<'EOF'
#!/usr/bin/env bash
# fake ffmpeg: writes something to its last argument (the output file)
echo "fake mkv" > "${@: -1}"
EOF
chmod +x "${WORK_DIR}/bin/ffmpeg"
OUTPUT="$(PATH="${WORK_DIR}/bin:${PATH}" run_with_helpers 'LOG="$PWD/log"; mkdir -p "$LOG"; echo x > "My.Movie 2024.mp4"; FILE_NAME="My.Movie 2024.mp4"; mp4_to_mkv; echo "RESULT=$FILE_NAME"')"; STATUS=$?
assert_status   "converts a dotted, spaced name" 0 "${STATUS}"
assert_contains "keeps every dot in the name" "${OUTPUT}" "RESULT=My.Movie 2024.mkv"

echo "converting_hdr2sdr (only decides; tone mapping is done by the frames extraction)"
HDR_SETUP='TMP="$PWD/t"; LOG="$PWD/log"; mkdir -p "$TMP" "$LOG"; MOVIE_NAME_ARRAY=(hdr); echo x > hdr.mkv
echo "{\"frames\":[{\"color_space\":\"bt2020nc\",\"color_primaries\":\"bt2020\",\"color_transfer\":\"smpte2084\"}]}" > "$TMP/hdr_mastering_display.json"'
OUTPUT="$(PATH="${WORK_DIR}/bin:${PATH}" run_with_helpers "${HDR_SETUP}"'; TONE_MAPPING=no; converting_hdr2sdr hdr; echo "FILTER=[${TONE_MAPPING_FILTER}]"' 2>&1)"; STATUS=$?
assert_status   "-T: HDR is left as it is" 0 "${STATUS}"
assert_contains "-T: warns that tone mapping is off" "${OUTPUT}" "tone mapping is switched off"
assert_contains "-T: no tone-mapping filter" "${OUTPUT}" "FILTER=[]"
OUTPUT="$(PATH="${WORK_DIR}/bin:${PATH}" run_with_helpers "${HDR_SETUP}"'; converting_hdr2sdr hdr; echo "FILTER=[${TONE_MAPPING_FILTER}]"; ls *.mkv | tr "\n" " "; if [ -L hdr.mkv ]; then echo "LINKED"; fi' 2>&1)"; STATUS=$?
assert_status   "default: HDR is detected" 0 "${STATUS}"
assert_contains "default: libplacebo filter is set" "${OUTPUT}" "FILTER=[libplacebo=tonemapping=bt.2390:"
assert_contains "default: no _sdr/_hdr copies are made" "${OUTPUT}" "hdr.mkv "
if [[ ${OUTPUT} == *_sdr.mkv* || ${OUTPUT} == *_hdr.mkv* || ${OUTPUT} == *LINKED* ]]; then fail "default: chunk is left untouched" "${OUTPUT}"; else pass "default: chunk is left untouched"; fi
OUTPUT="$(PATH="${WORK_DIR}/bin:${PATH}" run_with_helpers 'TMP="$PWD/t"; LOG="$PWD/log"; mkdir -p "$TMP" "$LOG"; MOVIE_NAME_ARRAY=(sdr); echo "{\"frames\":[{\"color_primaries\":\"bt709\"}]}" > "$TMP/sdr_mastering_display.json"; TONE_MAPPING_FILTER=stale; converting_hdr2sdr sdr; echo "FILTER=[${TONE_MAPPING_FILTER}]"' 2>&1)"
assert_contains "SDR: no filter (a previous chunk's filter is cleared)" "${OUTPUT}" "FILTER=[]"

echo "extracting_mkv_frames (ffmpeg replaced by a fake that records its arguments)"
mkdir -p "${WORK_DIR}/argsbin"
cat > "${WORK_DIR}/argsbin/ffmpeg" <<'EOF'
#!/usr/bin/env bash
# fake ffmpeg: saves its arguments, one per line
printf '%s\n' "$@" > ffmpeg_args.txt
EOF
chmod +x "${WORK_DIR}/argsbin/ffmpeg"
EXTRACT_SETUP='TMP="$PWD/t"; LOG="$PWD/log"; IN_DIR=in; TARGET_FRAME_COUNT=2; INPUT_FRAMES_COUNT=10; mkdir -p "$TMP" "$LOG" o/in/c; rm -f ffmpeg_args.txt'
OUTPUT="$(PATH="${WORK_DIR}/argsbin:${PATH}" run_with_helpers "${EXTRACT_SETUP}"'; TONE_MAPPING_FILTER="libplacebo=tm"; extracting_mkv_frames c o t; wait; tr "\n" " " < ffmpeg_args.txt' 2>&1)"
assert_contains "HDR: frames are extracted through the tone-mapping filter" "${OUTPUT}" "-i c.mkv -vf libplacebo=tm -fps_mode passthrough o/in/c/%08d.png"
OUTPUT="$(PATH="${WORK_DIR}/argsbin:${PATH}" run_with_helpers "${EXTRACT_SETUP}"'; TONE_MAPPING_FILTER=""; extracting_mkv_frames c o t; wait; tr "\n" " " < ffmpeg_args.txt' 2>&1)"
assert_contains "SDR: frames are extracted without a filter" "${OUTPUT}" "-i c.mkv -fps_mode passthrough o/in/c/%08d.png"

echo "encoding_quality_metric (ffmpeg replaced by a fake that records the filter graph)"
mkdir -p "${WORK_DIR}/vmafbin"
cat > "${WORK_DIR}/vmafbin/ffmpeg" <<'EOF'
#!/usr/bin/env bash
# fake ffmpeg: saves the -lavfi graph and writes a VMAF result to the graph's log_path
while [ $# -gt 0 ]
do
  if [ "$1" = "-lavfi" ]
  then
    printf '%s\n' "$2" > graph.txt
    LOG_PATH="${2#*log_path=}"
    printf '{"pooled_metrics":{"vmaf":{"min":90,"max":99,"mean":95.5}}}\n' > "${LOG_PATH%%:*}"
  fi
  shift
done
EOF
chmod +x "${WORK_DIR}/vmafbin/ffmpeg"
OUTPUT="$(PATH="${WORK_DIR}/vmafbin:${PATH}" run_with_helpers 'TMP="$PWD/t"; LOG="$PWD/log"; mkdir -p "$TMP" "$LOG"; TARGET_FRAME_COUNT=2; INTER_FRAMES_COUNT=2880; INPUT_FPS=23.976; encoding_quality_metric merged.mkv original.mkv; echo "MEAN=${VMAF_MEAN}"; cat graph.txt' 2>&1)"; STATUS=$?
assert_status   "VMAF run succeeds" 0 "${STATUS}"
assert_contains "reads the VMAF mean" "${OUTPUT}" "MEAN=95.5"
assert_contains "compares only original-position frames" "${OUTPUT}" "[0:v]select='not(mod(n\\,2))',setpts=N/(23.976*TB)[distorted]"
assert_contains "renumbers the reference the same way" "${OUTPUT}" "[1:v]setpts=N/(23.976*TB)[reference]"
assert_contains "distorted first, reference second" "${OUTPUT}" "[distorted][reference]libvmaf"
assert_contains "uses all CPU cores" "${OUTPUT}" "libvmaf=n_threads="
if [ -s /usr/share/model/vmaf_v0.6.1.json ]; then EXPECTED_MODEL="model=path=/usr/share/model/vmaf_v0.6.1.json:"; else EXPECTED_MODEL="model=version=vmaf_v0.6.1:"; fi
assert_contains "VMAF model: package file, otherwise built into libvmaf" "${OUTPUT}" "${EXPECTED_MODEL}"
OUTPUT="$(PATH="${WORK_DIR}/vmafbin:${PATH}" run_with_helpers 'TMP="$PWD/t"; LOG="$PWD/log"; mkdir -p "$TMP" "$LOG"; TARGET_FRAME_COUNT=2; INTER_FRAMES_COUNT=2880; INPUT_FPS=23.976; TONE_MAPPING_FILTER="libplacebo=tm"; encoding_quality_metric merged.mkv original.mkv; cat graph.txt' 2>&1)"
assert_contains "HDR: the reference is tone-mapped like the extracted frames" "${OUTPUT}" "[1:v]libplacebo=tm,setpts=N/(23.976*TB)[reference]"

echo "VMAF in the background (starting_quality_metric / finishing_quality_metric)"
mkdir -p "${WORK_DIR}/slowvmafbin"
cat > "${WORK_DIR}/slowvmafbin/ffmpeg" <<'EOF'
#!/usr/bin/env bash
# fake slow ffmpeg: records its niceness, takes 2 s, then writes a VMAF result (or fails)
ps -o ni= -p $$ | tr -d ' ' > nice.txt
sleep 2
if [ -e fail_vmaf ]
then
  exit 3
fi
while [ $# -gt 0 ]
do
  if [ "$1" = "-lavfi" ]
  then
    LOG_PATH="${2#*log_path=}"
    printf '{"pooled_metrics":{"vmaf":{"min":90,"max":99,"mean":96.5}}}\n' > "${LOG_PATH%%:*}"
  fi
  shift
done
EOF
chmod +x "${WORK_DIR}/slowvmafbin/ffmpeg"
VMAF_BG_SETUP='TMP="$PWD/t"; LOG="$PWD/log"; mkdir -p "$TMP" "$LOG"; rm -f "$LOG"/*; TARGET_FRAME_COUNT=2; INTER_FRAMES_COUNT=2880; INPUT_FPS=25; VERBOSE=yes'
OUTPUT="$(PATH="${WORK_DIR}/slowvmafbin:${PATH}" run_with_helpers "${VMAF_BG_SETUP}"'; S=$(date +%s); starting_quality_metric m.mkv o.mkv; echo "RETURNED_AFTER=$(( $(date +%s) - S ))"; finishing_quality_metric; echo "MEAN=${VMAF_MEAN} PID=[${QUALITY_METRIC_CHECK_PID}] NICE=$(cat nice.txt)"' 2>&1)"
assert_contains "starting returns at once (VMAF keeps running)" "${OUTPUT}" "RETURNED_AFTER=0"
assert_contains "finishing waits and reads the VMAF mean" "${OUTPUT}" "MEAN=96.5 PID=[]"
assert_contains "VMAF runs with lower priority (nice 10)" "${OUTPUT}" "NICE=10"
OUTPUT="$(PATH="${WORK_DIR}/slowvmafbin:${PATH}" run_with_helpers "${VMAF_BG_SETUP}"'; touch fail_vmaf; starting_quality_metric m.mkv o.mkv; finishing_quality_metric; rm -f fail_vmaf; echo "MEAN=${VMAF_MEAN}"' 2>&1)"; STATUS=$?
assert_status   "failed VMAF does not stop the run" 0 "${STATUS}"
assert_contains "failed VMAF is reported with ffmpeg's exit code" "${OUTPUT}" "VMAF check failed with exit code 3"
assert_contains "failed VMAF is recorded as error" "${OUTPUT}" "MEAN=error"
OUTPUT="$(run_with_helpers 'QUALITY_METRIC_CHECK_PID=""; finishing_quality_metric; echo "NOTHING_PENDING=ok"' 2>&1)"
assert_contains "finishing without a started VMAF does nothing" "${OUTPUT}" "NOTHING_PENDING=ok"
# the last chunk's VMAF must end before an unsplit result is renamed
LINE_FINISH="$(grep -n '^finishing_previous_chunk$' "${REPO_ROOT}/interpolation_nncn" | tail -1 | cut -d: -f1)"
LINE_RENAME="$(grep -n 'an unsplit video was processed as chunk 001' "${REPO_ROOT}/interpolation_nncn" | cut -d: -f1)"
if [ -n "${LINE_FINISH}" ] && [ -n "${LINE_RENAME}" ] && [ "${LINE_FINISH}" -lt "${LINE_RENAME}" ]; then pass "last VMAF is waited for before results are renamed"; else fail "last VMAF is waited for before results are renamed"; fi

echo "split points at closed-GOP keyframes (ffprobe replaced by a fake packet list)"
mkdir -p "${WORK_DIR}/splitbin"
cat > "${WORK_DIR}/splitbin/ffprobe" <<'EOF'
#!/usr/bin/env bash
# fake ffprobe: video packets in decode order (pts_time,flags) from packets.csv
cat packets.csv
EOF
chmod +x "${WORK_DIR}/splitbin/ffprobe"
# keyframes: 56 closed, 60 open (59.9 shown before it), 62 closed; around 122 only open ones
SPLIT_SETUP='TMP="$PWD/t"; LOG="$PWD/log"; mkdir -p "$TMP" "$LOG"; SPLIT_TIME_SEC=60
printf "%s\n" 0.000,K__ 0.100,___ N/A,___ 56.000,K__ 56.100,___ 60.000,K__ 59.900,___ 62.000,K__ 62.100,___ 118.000,K__ 117.900,___ 122.000,K__ 121.900,___ 126.000,K__ 125.900,___ 140.000,K__ 139.900,___ 150.000,___ > packets.csv'
OUTPUT="$(PATH="${WORK_DIR}/splitbin:${PATH}" run_with_helpers "${SPLIT_SETUP}"'; choosing_split_points film.mkv; echo "POINTS=${SPLIT_TIMESTAMPS}"' 2>&1)"
assert_contains "the closed-GOP keyframe nearest to 60 s is chosen, not the open one" "${OUTPUT}" "POINTS=62.000s,122.000s"
assert_contains "without a closed-GOP keyframe nearby, the split warns" "${OUTPUT}" "of the split at 122.000s"
OUTPUT="$(PATH="${WORK_DIR}/splitbin:${PATH}" run_with_helpers "${SPLIT_SETUP}"'; printf "%s\n" 0.000,K__ 30.000,___ 95.000,___ > packets.csv; choosing_split_points film.mkv; echo "POINTS=[${SPLIT_TIMESTAMPS}]"' 2>&1)"
assert_contains "no keyframe after 60 s: nothing to split at" "${OUTPUT}" "POINTS=[]"
GUARD_SETUP='WHOLE_MOVIE_NAME_ARRAY=(Film); SPLIT_TIMESTAMPS="62.000s"; SPLIT_PART_START=001; rm -f Film_split_points.txt video_part_minute_*.done'
run_with_helpers "${GUARD_SETUP}"'; RESUME=yes; echo "60.000s" > Film_split_points.txt; checking_split_points_file' > /dev/null 2>&1
assert_status "-r with chunks split at other points stops with 2" 2 $?
run_with_helpers "${GUARD_SETUP}"'; RESUME=no; SPLIT_PART_START=005; echo Film > video_part_minute_001_rife_48_merged.mkv.done; checking_split_points_file' > /dev/null 2>&1
assert_status "-s with chunks of an older version (no points file) stops with 2" 2 $?
OUTPUT="$(run_with_helpers "${GUARD_SETUP}"'; RESUME=yes; echo "62.000s" > Film_split_points.txt; checking_split_points_file; echo "SAME=ok"; RESUME=no; echo Film > video_part_minute_001_rife_48_merged.mkv.done; SPLIT_TIMESTAMPS="70.000s"; checking_split_points_file; echo "SAVED=$(cat Film_split_points.txt)"' 2>&1)"
assert_contains "-r with the same split points continues" "${OUTPUT}" "SAME=ok"
assert_contains "a new run saves its split points" "${OUTPUT}" "SAVED=70.000s"

echo "merging_streams_mkv keeps the video in sync (mkvmerge replaced by a fake)"
mkdir -p "${WORK_DIR}/mkvbin"
cat > "${WORK_DIR}/mkvbin/mkvmerge" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > mkvmerge_args.txt
EOF
chmod +x "${WORK_DIR}/mkvbin/mkvmerge"
OUTPUT="$(PATH="${WORK_DIR}/mkvbin:${PATH}" run_with_helpers 'TMP="$PWD/t"; LOG="$PWD/log"; mkdir -p "$TMP" "$LOG"; NCNN_METHOD=rife; OUTPUT_FPS_ROUND=48; AUDIO_EXTRACTED=yes; VIDEO_START_MS=126; merging_streams_mkv c in out; tr "\n" " " < mkvmerge_args.txt' 2>&1)"
assert_contains "the processed video starts at the time of the first decoded frame" "${OUTPUT}" "--language 0:und --sync 0:126 out/c_rife_48.mkv in/c.mka"

echo "final encode of each part (-E; HandBrakeCLI and ffprobe replaced by fakes)"
mkdir -p "${WORK_DIR}/hbbin"
cat > "${WORK_DIR}/hbbin/HandBrakeCLI" <<'EOF'
#!/usr/bin/env bash
# fake HandBrakeCLI: a scan prints a title with the crop from crop.txt; an encode records its
# niceness and arguments, takes 2 s and writes the -o file (or fails when fail_hb exists)
if [[ " $* " == *" --scan "* ]]
then
  printf 'Version: {\n}\nJSON Title Set: {"TitleList": [{"Crop": [%s]}]}\n' "$(cat crop.txt)"
  echo "HandBrake has exited." >&2
  exit 0
fi
ps -o ni= -p $$ | tr -d ' ' > hb_nice.txt
printf '%s\n' "$@" > hb_args.txt
sleep 2
if [ -e fail_hb ]
then
  exit 4
fi
while [ $# -gt 0 ]
do
  if [ "$1" = "-o" ]
  then
    echo "fake av1" > "$2"
  fi
  shift
done
EOF
cat > "${WORK_DIR}/hbbin/ffprobe" <<'EOF'
#!/usr/bin/env bash
printf '{"streams":[{"index":0,"codec_type":"video"},{"index":1,"codec_type":"audio","tags":{"language":"eng"}},{"index":2,"codec_type":"subtitle","tags":{"language":"pol"}}]}\n'
EOF
chmod +x "${WORK_DIR}/hbbin/HandBrakeCLI" "${WORK_DIR}/hbbin/ffprobe"
PART_SETUP='TMP="$PWD/t"; LOG="$PWD/log"; mkdir -p "$TMP" "$LOG"; rm -f "$LOG"/* *.done fail_hb; WHOLE_MOVIE_NAME_ARRAY=(My Movie); NCNN_METHOD=rife; KEEP_INTERMEDIATES=no; VERBOSE=yes; TARGET_FRAME_COUNT=2; INTER_FRAMES_COUNT=3000; INPUT_FPS=25; echo merged > p_merged.mkv; handbrake_encode_settings; HANDBRAKE_CROP=8:4:0:0'
OUTPUT="$(PATH="${WORK_DIR}/hbbin:${PATH}" run_with_helpers 'LOG="$PWD/log"; mkdir -p "$LOG"; echo "8, 4, 0, 0" > crop.txt; detecting_crop whole.mkv; echo "CROP=${HANDBRAKE_CROP}"' 2>&1)"
assert_contains "the crop is read from one scan of the whole video" "${OUTPUT}" "CROP=8:4:0:0"
PATH="${WORK_DIR}/hbbin:${PATH}" run_with_helpers 'LOG="$PWD/log"; mkdir -p "$LOG"; echo "" > crop.txt; detecting_crop whole.mkv' > /dev/null 2>&1
assert_status "an unreadable crop stops the run with 1" 1 $?
OUTPUT="$(PATH="${WORK_DIR}/hbbin:${PATH}" run_with_helpers "${PART_SETUP}"'; S=$(date +%s); starting_part_encoding p_merged.mkv p_encoded.mkv ""; echo "RETURNED_AFTER=$(( $(date +%s) - S ))"; finishing_part_encoding; echo "DONE=$(cat p_encoded.mkv.done) RUNTIME=${ENCODING_RUNTIME} NICE=$(cat hb_nice.txt)"; if [ -e p_merged.mkv ]; then echo MERGED_KEPT; fi; tr "\n" " " < hb_args.txt' 2>&1)"
assert_contains "starting returns at once (the encode keeps running)" "${OUTPUT}" "RETURNED_AFTER=0"
assert_contains "finishing marks the encoded part with the movie name" "${OUTPUT}" "DONE=My Movie RUNTIME=0s"
assert_contains "the encode runs with lower priority (nice 10)" "${OUTPUT}" "NICE=10"
assert_contains "every part gets the crop of the whole video" "${OUTPUT}" "--crop 8:4:0:0"
assert_contains "the movies_encoding encoder settings are used" "${OUTPUT}" "--encoder svt_av1_10bit --quality 22"
assert_contains "audio and subtitles are chosen from the part" "${OUTPUT}" "-E copy -a 1 --subtitle-lang-list eng,pol,dut --all-subtitles"
if [[ ${OUTPUT} == *MERGED_KEPT* ]]; then fail "the merged part is removed after its encode"; else pass "the merged part is removed after its encode"; fi
OUTPUT="$(PATH="${WORK_DIR}/hbbin:${PATH}" run_with_helpers "${PART_SETUP}"'; KEEP_INTERMEDIATES=yes; starting_part_encoding p_merged.mkv p_encoded.mkv ""; finishing_part_encoding; if [ -e p_merged.mkv ]; then echo MERGED_KEPT; fi' 2>&1)"
assert_contains "-k keeps the merged part" "${OUTPUT}" "MERGED_KEPT"
OUTPUT="$(PATH="${WORK_DIR}/hbbin:${WORK_DIR}/vmafbin:${PATH}" run_with_helpers "${PART_SETUP}"'; touch fail_hb; QUALITY_METRIC_CHECK_PID=""; starting_part_encoding p_merged.mkv p_encoded.mkv o.mkv; finishing_part_encoding; finishing_quality_metric; echo "MEAN=${VMAF_MEAN}"; if [ -e p_merged.mkv ]; then echo MERGED_KEPT; fi; if [ -e p_encoded.mkv.done ]; then echo MARKED; fi' 2>&1)"; STATUS=$?
assert_status   "a failed encode does not stop the run" 0 "${STATUS}"
assert_contains "a failed encode is reported with HandBrake's exit code" "${OUTPUT}" "failed with exit code 4"
assert_contains "a failed encode keeps the merged part, VMAF is error" "${OUTPUT}" "MEAN=error"
assert_contains "a failed encode keeps its merged part" "${OUTPUT}" "MERGED_KEPT"
if [[ ${OUTPUT} == *MARKED* ]]; then fail "a failed encode is not marked as finished"; else pass "a failed encode is not marked as finished"; fi
OUTPUT="$(PATH="${WORK_DIR}/hbbin:${WORK_DIR}/vmafbin:${PATH}" run_with_helpers "${PART_SETUP}"'; QUALITY_METRIC_CHECK_PID=""; starting_part_encoding p_merged.mkv p_encoded.mkv o.mkv; finishing_part_encoding; finishing_quality_metric; echo "MEAN=${VMAF_MEAN}"; cat graph.txt' 2>&1)"
assert_contains "-Q: VMAF of the encoded part follows its encode" "${OUTPUT}" "MEAN=95.5"
assert_contains "-Q: the reference is cropped like the encode" "${OUTPUT}" "[1:v]crop=iw-0-0:ih-8-4:0:8,setpts="
OUTPUT="$(run_with_helpers 'GRAIN=yes; unset DESTINATION_DIR; handbrake_encode_settings; echo "DEST=${DESTINATION_DIR} ${VIDEO_ENCODER[*]}"; DESTINATION_DIR=/x; handbrake_encode_settings; echo "OVERRIDE=${DESTINATION_DIR}"' 2>&1)"
assert_contains "shared settings: profile and default destination" "${OUTPUT}" "DEST=/media/ready svt_av1_10bit --quality 22 --encoder-preset 5 --nlmeans-tune grain"
assert_contains "shared settings: DESTINATION_DIR can be overridden" "${OUTPUT}" "OVERRIDE=/x"
OUTPUT="$(TERM=dumb bash "${REPO_ROOT}/interpolation_nncn" -h 2>&1)"
assert_contains "interpolation_nncn -h documents -E (final encode)" "${OUTPUT}" "-E  final encode"
# the parts must be joined after the last encode is waited for
LINE_JOIN="$(grep -n '^  joining_encoded_parts$' "${REPO_ROOT}/interpolation_nncn" | cut -d: -f1)"
if [ -n "${LINE_FINISH}" ] && [ -n "${LINE_JOIN}" ] && [ "${LINE_FINISH}" -lt "${LINE_JOIN}" ]; then pass "the last encode is waited for before the parts are joined"; else fail "the last encode is waited for before the parts are joined"; fi

echo "intermediate_codec_options (ffmpeg replaced by a fake encoder list)"
mkdir -p "${WORK_DIR}/codecbin"
cat > "${WORK_DIR}/codecbin/ffmpeg" <<'EOF'
#!/usr/bin/env bash
# fake ffmpeg -encoders: lists only libx264 and ffv1 (no libsvtav1)
printf ' V....D libx264              libx264 H.264\n V.S..D ffv1                 FFmpeg video codec #1\n'
EOF
chmod +x "${WORK_DIR}/codecbin/ffmpeg"
OUTPUT="$(unset INTERMEDIATE_CODEC; PATH="${WORK_DIR}/codecbin:${PATH}" run_with_helpers 'intermediate_codec_options; echo "OPTS=${INTERMEDIATE_CODEC_OPTIONS[*]}"' 2>&1)"; STATUS=$?
assert_status   "default codec is accepted" 0 "${STATUS}"
assert_contains "default is lossless x264" "${OUTPUT}" "OPTS=-c:v libx264 -qp 0 -preset ultrafast"
OUTPUT="$(INTERMEDIATE_CODEC=ffv1 PATH="${WORK_DIR}/codecbin:${PATH}" run_with_helpers 'intermediate_codec_options; echo "OPTS=${INTERMEDIATE_CODEC_OPTIONS[*]}"' 2>&1)"
assert_contains "ffv1 can be chosen" "${OUTPUT}" "OPTS=-c:v ffv1"
INTERMEDIATE_CODEC=nonsense PATH="${WORK_DIR}/codecbin:${PATH}" run_with_helpers 'intermediate_codec_options' > /dev/null 2>&1
assert_status   "unknown codec exits 2" 2 $?
INTERMEDIATE_CODEC=svtav1_crf10 PATH="${WORK_DIR}/codecbin:${PATH}" run_with_helpers 'intermediate_codec_options' > /dev/null 2>&1
assert_status   "missing encoder exits 127" 127 $?

echo "ffmpeg_feature_checks (fake ffmpeg filter list without libplacebo and libvmaf)"
mkdir -p "${WORK_DIR}/featurebin"
cat > "${WORK_DIR}/featurebin/ffmpeg" <<'EOF'
#!/usr/bin/env bash
printf ' .S tonemap           V->V       Conversion to/from different dynamic ranges.\n'
EOF
cat > "${WORK_DIR}/featurebin/ffprobe" <<'EOF'
#!/usr/bin/env bash
# the file name decides the colour primaries: hdr* is bt2020, everything else bt709
for ARG in "$@"; do LAST="${ARG}"; done
if [[ ${LAST} == hdr* ]]; then echo bt2020; else echo bt709; fi
EOF
chmod +x "${WORK_DIR}/featurebin/ffmpeg" "${WORK_DIR}/featurebin/ffprobe"
PATH="${WORK_DIR}/featurebin:${PATH}" run_with_helpers 'TONE_MAPPING=yes; ffmpeg_feature_checks hdr.mkv' > /dev/null 2>&1
assert_status   "HDR without libplacebo exits 127" 127 $?
OUTPUT="$(PATH="${WORK_DIR}/featurebin:${PATH}" run_with_helpers 'TONE_MAPPING=yes; ffmpeg_feature_checks hdr.mkv' 2>&1)"
assert_contains "error suggests -T" "${OUTPUT}" "use -T"
PATH="${WORK_DIR}/featurebin:${PATH}" run_with_helpers 'TONE_MAPPING=no; ffmpeg_feature_checks hdr.mkv' > /dev/null 2>&1
assert_status   "HDR with -T needs no libplacebo" 0 $?
PATH="${WORK_DIR}/featurebin:${PATH}" run_with_helpers 'TONE_MAPPING=yes; ffmpeg_feature_checks sdr.mkv' > /dev/null 2>&1
assert_status   "SDR needs no libplacebo" 0 $?
PATH="${WORK_DIR}/featurebin:${PATH}" run_with_helpers 'TONE_MAPPING=yes; QUALITY_CHECK=yes; ffmpeg_feature_checks sdr.mkv' > /dev/null 2>&1
assert_status   "-Q without libvmaf exits 127" 127 $?

echo "NCNN GPUs and threads (fake uname decides the OS)"
mkdir -p "${WORK_DIR}/linuxbin" "${WORK_DIR}/macbin"
printf '#!/usr/bin/env bash\necho Linux\n' > "${WORK_DIR}/linuxbin/uname"
printf '#!/usr/bin/env bash\necho Darwin\n' > "${WORK_DIR}/macbin/uname"
chmod +x "${WORK_DIR}/linuxbin/uname" "${WORK_DIR}/macbin/uname"
OUTPUT="$(unset NCNN_GPUS NCNN_THREADS; PATH="${WORK_DIR}/linuxbin:${PATH}" run_with_helpers 'echo "G=${NCNN_GPUS} J=${NCNN_THREADS}"' 2>&1)"
assert_contains "Linux defaults: two GPUs" "${OUTPUT}" "G=1,2 J=6:2,2:8"
OUTPUT="$(unset NCNN_GPUS NCNN_THREADS; PATH="${WORK_DIR}/macbin:${PATH}" run_with_helpers 'echo "G=${NCNN_GPUS} J=${NCNN_THREADS}"' 2>&1)"
assert_contains "macOS defaults: GPU 0" "${OUTPUT}" "G=0 J=1:2:2"
OUTPUT="$(NCNN_GPUS=0 NCNN_THREADS=1:2:2 run_with_helpers 'echo "G=${NCNN_GPUS} J=${NCNN_THREADS}"' 2>&1)"
assert_contains "environment overrides them" "${OUTPUT}" "G=0 J=1:2:2"

echo "throttling_ncnn (a sleeping process stands in for NCNN)"
THROTTLE_TEST='sleep 60 & PID=$!; mkdir -p l; NCNN_EXTRACTION_MARGIN=50
state() { ps -o stat= -p "$PID" | cut -c1; }
printf "frame=100\n" > l/ex.log; printf "/x/00000060.png /x/00000061.png 0.5 -> /y/00000121.png done\n" > l/nc.log
throttling_ncnn "$PID" l/ex.log l/nc.log; echo "GAP39=$(state) $NCNN_PAUSED"
printf "frame=150\n" >> l/ex.log; throttling_ncnn "$PID" l/ex.log l/nc.log; echo "GAP89=$(state) $NCNN_PAUSED"
printf "frame=161\n" >> l/ex.log; throttling_ncnn "$PID" l/ex.log l/nc.log; echo "GAP100=$(state) $NCNN_PAUSED"
throttling_ncnn "$PID" l/ex.log l/nc.log; echo "AGAIN=$(state) $NCNN_PAUSED"
printf "/x/00000130.png /x/00000131.png 0.5 -> /y/00000261.png done\n" >> l/nc.log; throttling_ncnn "$PID" l/ex.log l/nc.log; echo "CLOSE=$(state) $NCNN_PAUSED"
resuming_ncnn "$PID"; echo "RESUMED=$(state) $NCNN_PAUSED"
: > l/nc.log; printf "frame=0\n" > l/ex.log; throttling_ncnn "$PID" l/ex.log l/nc.log; echo "START=$(state) $NCNN_PAUSED"
resuming_ncnn "$PID"; kill "$PID"'
OUTPUT="$(run_with_helpers "${THROTTLE_TEST}" 2>&1)"
assert_contains "pauses NCNN closer than the margin" "${OUTPUT}" "GAP39=T yes"
assert_contains "keeps it paused below twice the margin" "${OUTPUT}" "GAP89=T yes"
assert_contains "resumes at twice the margin" "${OUTPUT}" "GAP100=S no"
assert_contains "stays running when far enough ahead" "${OUTPUT}" "AGAIN=S no"
assert_contains "pauses again when NCNN catches up" "${OUTPUT}" "CLOSE=T yes"
assert_contains "resuming_ncnn continues it" "${OUTPUT}" "RESUMED=S no"
assert_contains "pauses before anything is extracted" "${OUTPUT}" "START=T yes"

echo "portability"
if grep -n -- "ps --pid" "${REPO_ROOT}/.config_video" "${REPO_ROOT}/interpolation_nncn" "${REPO_ROOT}/movies_encoding" > /dev/null; then fail "no ps --pid (macOS ps has no --pid; use ps -p)"; else pass "no ps --pid (macOS ps has no --pid; use ps -p)"; fi

echo "joining parts"
if grep -A3 '^appending_mkvs()' "${REPO_ROOT}/.config_video" | grep -q -- "mkvmerge --append-mode track"; then pass "parts are joined with --append-mode track (no gaps from long subtitles)"; else fail "parts are joined with --append-mode track (no gaps from long subtitles)"; fi

echo "short chunks"
if grep -q 'frame_analysis/output0002' "${REPO_ROOT}/.config_video"; then fail "frame analysis reads the first sample (a chunk of up to 100 frames has only one)"; else pass "frame analysis reads the first sample (a chunk of up to 100 frames has only one)"; fi

echo
echo "passed: ${PASSED}, failed: ${FAILED}"
[ "${FAILED}" -eq 0 ]
