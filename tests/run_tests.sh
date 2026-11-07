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
assert_contains "interpolation_nncn -h documents -F (fresh start, resume by default)" "${OUTPUT}" "-F  fresh start: by default a run resumes"
assert_contains "interpolation_nncn -h keeps -r (the default)" "${OUTPUT}" "-r  resume (the default"
assert_contains "interpolation_nncn -h separates unsupported methods" "${OUTPUT}" "not supported yet"
assert_contains "interpolation_nncn -h documents -T (no tone mapping)" "${OUTPUT}" "-T  no tone mapping"
mkdir -p "${WORK_DIR}/cli" && echo x > "${WORK_DIR}/cli/x.mkv"
OUTPUT="$(cd "${WORK_DIR}/cli" && TERM=dumb bash "${REPO_ROOT}/interpolation_nncn" -i x.mkv -o "${WORK_DIR}/cli/v" -F -r 2>&1)"; STATUS=$?
assert_status   "interpolation_nncn -F with -r stops with 2" 2 "${STATUS}"
assert_contains "interpolation_nncn -F with -r says why" "${OUTPUT}" "exclude each other"
OUTPUT="$(cd "${WORK_DIR}/cli" && TERM=dumb bash "${REPO_ROOT}/interpolation_nncn" -i x.mkv -o "${WORK_DIR}/cli/v" -M 20G 2>&1)"; STATUS=$?
assert_status   "interpolation_nncn -M without -S stops with 2" 2 "${STATUS}"
assert_contains "interpolation_nncn -M without -S says why" "${OUTPUT}" "so it needs -S"
OUTPUT="$(cd "${WORK_DIR}/cli" && TERM=dumb bash "${REPO_ROOT}/interpolation_nncn" -i x.mkv -o "${WORK_DIR}/cli/v" -S -M 20GB 2>&1)"; STATUS=$?
assert_status   "interpolation_nncn -M with a wrong size stops with 2" 2 "${STATUS}"
assert_contains "interpolation_nncn -M with a wrong size says why" "${OUTPUT}" "-M expects a size like 20G"

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
OUTPUT="$(PATH="${WORK_DIR}/argsbin:${PATH}" run_with_helpers "${EXTRACT_SETUP}"'; OUT_DIR=out; NCNN_METHOD=rife; OUTPUT_FPS_ROUND=48; OUTPUT_FRAME_RATE=48000/1001; INTERMEDIATE_CODEC_OPTIONS=(-c:v ffv1); merging_frames_mkv c t o; wait; tr "\n" " " < ffmpeg_args.txt' 2>&1)"
assert_contains "frames are merged at the exact rational rate (not a rounded 47.96)" "${OUTPUT}" "-framerate 48000/1001 -i t/out/c_rife_48/%08d.png"

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
assert_contains "frames recovered at an open split (not in the reference) are left out" "${OUTPUT}" "log_fmt=json:shortest=1"
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
# fake ffprobe: keyframes the decoder decodes (-skip_frame nokey) from keyframes.csv,
# otherwise video packets in decode order (pts_time,flags) from packets.csv
if [[ " $* " == *" -skip_frame "* ]]
then
  if [ -f keyframes.csv ]
  then
    cat keyframes.csv
  else
    grep ",K" packets.csv | cut -d, -f1
  fi
else
  cat packets.csv
fi
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
OUTPUT="$(PATH="${WORK_DIR}/splitbin:${PATH}" run_with_helpers "${SPLIT_SETUP}"'; printf "%s\n" 0.000 56.000 60.000 118.000 122.000 126.000 140.000 > keyframes.csv; choosing_split_points film.mkv; echo "POINTS=${SPLIT_TIMESTAMPS}"; rm keyframes.csv' 2>&1)"
assert_contains "a keyframe flag on a frame the decoder cannot start from is ignored" "${OUTPUT}" "POINTS=56.000s,118.000s"
GUARD_SETUP='WHOLE_MOVIE_NAME_ARRAY=(Film); SPLIT_TIMESTAMPS="62.000s"; SPLIT_PART_START=001; rm -f Film_split_points.txt video_part_minute_*.done'
run_with_helpers "${GUARD_SETUP}"'; RESUME=yes; echo "60.000s" > Film_split_points.txt; checking_split_points_file' > /dev/null 2>&1
assert_status "-r with chunks split at other points stops with 2" 2 $?
run_with_helpers "${GUARD_SETUP}"'; RESUME=no; SPLIT_PART_START=005; echo Film > video_part_minute_001_rife_48_merged.mkv.done; checking_split_points_file' > /dev/null 2>&1
assert_status "-s with chunks of an older version (no points file) stops with 2" 2 $?
OUTPUT="$(run_with_helpers "${GUARD_SETUP}"'; RESUME=yes; echo "62.000s" > Film_split_points.txt; checking_split_points_file; echo "SAME=ok"; RESUME=no; echo Film > video_part_minute_001_rife_48_merged.mkv.done; SPLIT_TIMESTAMPS="70.000s"; checking_split_points_file; echo "SAVED=$(cat Film_split_points.txt)"' 2>&1)"
assert_contains "-r with the same split points continues" "${OUTPUT}" "SAME=ok"
assert_contains "a new run saves its split points" "${OUTPUT}" "SAVED=70.000s"
OUTPUT="$(run_with_helpers "${GUARD_SETUP}"'; RESUME=yes; echo "60.000s" > Film_split_points.txt; checking_split_points_file' 2>&1)"
assert_contains "other split points: the run says to start with -F" "${OUTPUT}" "start the movie again with -F"
run_with_helpers "${GUARD_SETUP}"'; RESUME=yes; printf "Film\nfilm\n" > video_part_minute_001_rife_48_encoded.mkv.done; checking_split_points_file' > /dev/null 2>&1
assert_status "an older version's encoded marker (two lines) is recognized" 2 $?

echo "removing_earlier_results (-F)"
FRESH_SETUP='eval "$(sed -n "/^removing_earlier_results()/,/^  }/p" "'"${REPO_ROOT}"'/interpolation_nncn")"; WHOLE_MOVIE_NAME_ARRAY=(My Film); NCNN_METHOD=rife; rm -rf fresh; mkdir fresh; cd fresh || exit 99; for N in 001 002 003; do echo part > video_part_minute_${N}_rife_48_merged.mkv; echo "My Film" > video_part_minute_${N}_rife_48_merged.mkv.done; echo part > video_part_minute_${N}_rife_48_encoded.mkv; printf "My Film\nfilm\n" > video_part_minute_${N}_rife_48_encoded.mkv.done; done; echo Other > video_part_minute_003_rife_48_merged.mkv.done; echo "My Film" > video_part_minute_002_dain_48_merged.mkv.done; echo pts > "My Film_split_points.txt"; echo part > "My Film_rife_48_merged.mkv"; echo "My Film" > "My Film_rife_48_merged.mkv.done"'
OUTPUT="$(run_with_helpers "${FRESH_SETUP}"'; SPLIT_PART_START=001; removing_earlier_results; echo "LEFT: $(ls | tr "\n" " ")"' 2>&1)"
assert_contains "-F removes this movie's parts and markers" "${OUTPUT}" "6 earlier result(s) of My Film removed"
assert_contains "-F keeps markers of other movies and methods, and their parts" "${OUTPUT}" "LEFT: video_part_minute_002_dain_48_merged.mkv.done video_part_minute_003_rife_48_merged.mkv video_part_minute_003_rife_48_merged.mkv.done "
if [[ ${OUTPUT} == *"split_points.txt "* ]]; then fail "-F from chunk 001 removes the split points"; else pass "-F from chunk 001 removes the split points"; fi
OUTPUT="$(run_with_helpers "${FRESH_SETUP}"'; SPLIT_PART_START=002; removing_earlier_results; echo "LEFT: $(ls | tr "\n" " ")"' 2>&1)"
assert_contains "-F -s 002 keeps the chunks before 002 and the split points" "${OUTPUT}" "LEFT: My Film_rife_48_merged.mkv My Film_rife_48_merged.mkv.done My Film_split_points.txt video_part_minute_001_rife_48_encoded.mkv video_part_minute_001_rife_48_encoded.mkv.done video_part_minute_001_rife_48_merged.mkv video_part_minute_001_rife_48_merged.mkv.done video_part_minute_002_dain"

echo "-S starts a systemd service (sudo, systemd-run and id replaced by fakes)"
mkdir -p "${WORK_DIR}/servicebin"
cat > "${WORK_DIR}/servicebin/sudo" <<'EOF'
#!/usr/bin/env bash
# fake sudo: -v fails with sudo_denied, other commands run as given (and are recorded)
if [ "$1" = "-v" ]
then
  if [ -e sudo_denied ]
  then
    exit 1
  fi
  exit 0
fi
echo sudo >> service_args.txt
exec "$@"
EOF
cat > "${WORK_DIR}/servicebin/systemd-run" <<'EOF'
#!/usr/bin/env bash
# fake systemd-run: records its arguments, one per line
printf '%s\n' "$@" >> service_args.txt
EOF
cat > "${WORK_DIR}/servicebin/id" <<'EOF'
#!/usr/bin/env bash
echo 1000
EOF
chmod +x "${WORK_DIR}/servicebin/"*
SERVICE_SETUP='eval "$(sed -n "/^starting_as_service()/,/^  }/p" "'"${REPO_ROOT}"'/interpolation_nncn")"; rm -rf svc; mkdir svc; cd svc || exit 99; FILE_NAME="Smokin'"'"' Aces (2006).mkv"; CURRENT_TIMESTAMP=2026.11.02-16.50.33; LOG=/var/log-x; SCRIPT=/repo/interpolation_nncn; ORIGINAL_ARGUMENTS=(-i "${FILE_NAME}" -E -g -S); MEMORY_HIGH=""'
OUTPUT="$(PATH="${WORK_DIR}/servicebin:${PATH}" run_with_helpers "${SERVICE_SETUP}"'; MEMORY_HIGH=20G; trap '"'"'echo "STATUS=$?"; echo "ARGS: $(tr "\n" "|" < service_args.txt)"'"'"' EXIT; starting_as_service' 2>&1)"
assert_contains "-S exits 0 once the service is started" "${OUTPUT}" "STATUS=0"
assert_contains "-S starts it through sudo, as the calling user, in the current directory" "${OUTPUT}" "ARGS: sudo|--quiet|--collect|--unit=interpolation-Smokin_Aces_2006_-2026.11.02-16.50.33|--description=interpolation_nncn: Smokin' Aces (2006).mkv|--uid=1000|--gid=1000|--working-directory=${WORK_DIR}/svc|"
assert_contains "-S: systemctl stop sends SIGINT, as Ctrl+C (the cleanup runs)" "${OUTPUT}" "|-p|KillSignal=SIGINT|-p|TimeoutStopSec=120|-p|MemoryHigh=20G|"
assert_contains "-S: the service gets the launcher's timestamp and the same arguments" "${OUTPUT}" "|--setenv=INTERPOLATION_NNCN_SERVICE=yes|--setenv=SERVICE_RUN_TIMESTAMP=2026.11.02-16.50.33|/usr/bin/env|bash|/repo/interpolation_nncn|-i|Smokin' Aces (2006).mkv|-E|-g|-S|"
assert_contains "-S prints the log of the service" "${OUTPUT}" "/var/log-x/interpolation_nncn_silent_2026.11.02-16.50.33.log"
assert_contains "-S prints how to stop it" "${OUTPUT}" "sudo systemctl stop 'interpolation-Smokin_Aces_2006_-2026.11.02-16.50.33'"
OUTPUT="$(PATH="${WORK_DIR}/servicebin:${PATH}" run_with_helpers "${SERVICE_SETUP}"'; trap '"'"'echo "ARGS: $(tr "\n" "|" < service_args.txt)"'"'"' EXIT; starting_as_service' 2>&1)"
if [[ ${OUTPUT} == *MemoryHigh* ]]; then fail "-S without -M sets no MemoryHigh"; else pass "-S without -M sets no MemoryHigh"; fi
OUTPUT="$(PATH="${WORK_DIR}/servicebin:${PATH}" run_with_helpers "${SERVICE_SETUP}"'; touch sudo_denied; trap '"'"'echo "STATUS=$?"; if [ -e service_args.txt ]; then echo STARTED; fi'"'"' EXIT; starting_as_service' 2>&1)"
assert_contains "-S without sudo stops with 1" "${OUTPUT}" "STATUS=1"
assert_contains "-S without sudo suggests an interactive run" "${OUTPUT}" "run it interactively (without -S)"
if [[ ${OUTPUT} == *STARTED* ]]; then fail "-S without sudo starts nothing"; else pass "-S without sudo starts nothing"; fi

echo "sampling_frames (real ffmpeg on a generated video)"
OUTPUT="$(run_with_helpers 'rm -rf smp; mkdir smp; cd smp || exit 99; ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=320x240:rate=24 -t 6 -c:v libx264 -g 48 v.mkv; sampling_frames v.mkv 6.000 fa; echo "STATUS=$?"; echo "FILES: $(ls fa | tr "\n" " ")"; sampling_frames v.mkv N/A fb; echo "BAD=$?"' 2>&1)"
assert_contains "sampling_frames writes 7 evenly spread frames" "${OUTPUT}" "STATUS=0"
assert_contains "sampling_frames names them like the old analysis (output0001.png first)" "${OUTPUT}" "FILES: output0001.png output0002.png output0003.png output0004.png output0005.png output0006.png output0007.png "
assert_contains "sampling_frames fails on an unknown duration" "${OUTPUT}" "BAD=1"

echo "compressing_logs (.config)"
OUTPUT="$(run_with_helpers 'eval "$(sed -n "/^compressing_logs()/,/^  }/p" "'"${REPO_ROOT}"'/.config")"; rm -rf cmp; mkdir -p cmp/sub; cd cmp || exit 99; echo log > "a b.log"; echo "{}" > v.json; echo old | gzip > c.log.gz; ln -s v.json link.json; compressing_logs * missing.log; echo "STATUS=$?"; echo "LEFT: $(ls | tr "\n" " ")"; echo "READ: $(zcat "a b.log.gz")"' 2>&1)"
assert_contains "compressing_logs compresses files, skips .gz, symlinks, directories and missing files" "${OUTPUT}" "LEFT: a b.log.gz c.log.gz link.json sub v.json.gz "
assert_contains "compressing_logs keeps the content" "${OUTPUT}" "READ: log"
assert_contains "compressing_logs returns 0" "${OUTPUT}" "STATUS=0"

echo "metrics (metrics_sampling, waiting_for_chunk_steps, checking_memory_headroom, metrics_to_excel.py)"
OUTPUT="$(run_with_helpers 'eval "$(sed -n "/^metrics_sampling()/,/^  }/p" "'"${REPO_ROOT}"'/.config")"; rm -rf met; mkdir met; cd met || exit 99; METRICS_INTERVAL_SEC=1; metrics_sampling m.csv sleep bash & P=$!; sleep 2.6; kill $P; echo "ROWS=$(($(wc -l < m.csv) - 1))"; echo "COLUMNS=$(awk -F"~" "{print NF}" m.csv | sort -u | tr "\n" " ")"; head -1 m.csv' 2>&1)"
assert_contains "metrics_sampling writes a row per interval after the first sample" "${OUTPUT}" "ROWS=2"
assert_contains "metrics_sampling rows have as many columns as the header" "${OUTPUT}" "COLUMNS=$(awk -F'~' '{print NF}' <<< "$(grep '^time~' <<< "${OUTPUT}")") "
assert_contains "metrics_sampling has system and per-tool columns" "${OUTPUT}" "time~epoch~cpu_busy [%]~cpu_iowait [%]~mem_used [GB]"
assert_contains "metrics_sampling ends with the tools and their sum" "${OUTPUT}" "~sleep_rss [GB]~bash_rss [GB]~tools_rss [GB]"
OUTPUT="$(run_with_helpers 'sleep 30 & METRICS_SAMPLING_PID=$!; sleep 0.2 & START=$SECONDS; waiting_for_chunk_steps; if [ $((SECONDS - START)) -lt 5 ]; then echo "NOT WAITED"; fi; kill $METRICS_SAMPLING_PID' 2>&1)"
assert_contains "waiting_for_chunk_steps does not wait for the metrics sampling (30 s)" "${OUTPUT}" "NOT WAITED"
MEMORY_SETUP='rm -rf mem; mkdir mem; cd mem || exit 99; TMP=$PWD; MEMINFO_FILE=$PWD/meminfo; printf "time~epoch~tools_rss [GB]\na~1~9.00\nb~2~20.00\nc~3~6.00\n" > metrics.csv'
OUTPUT="$(run_with_helpers "${MEMORY_SETUP}"'; printf "MemTotal: 65000000 kB\nMemAvailable: 12582912 kB\n" > meminfo; checking_memory_headroom' 2>&1)"
assert_contains "memory check warns when available + held is below the run's peak + 10 %" "${OUTPUT}" "12.0 GB available + 6.0 GB held by the run, its peak is 20.0 GB (measured) + 10 %"
OUTPUT="$(run_with_helpers "${MEMORY_SETUP}"'; printf "MemAvailable: 20971520 kB\n" > meminfo; checking_memory_headroom; echo END' 2>&1)"
if [[ ${OUTPUT} == *"may run short"* ]]; then fail "memory check is silent when the peak fits"; else pass "memory check is silent when the peak fits"; fi
OUTPUT="$(run_with_helpers "${MEMORY_SETUP}"'; printf "time~epoch~tools_rss [GB]\n" > metrics.csv; printf "MemAvailable: 10485760 kB\n" > meminfo; checking_memory_headroom' 2>&1)"
assert_contains "memory check uses the default peak before anything was measured" "${OUTPUT}" "its peak is 16.0 GB (assumed, RUN_MEMORY_PEAK_DEFAULT_GB)"
# row a is before the check (its 20 GB is the peak), rows b and c during the encode (the reality)
OUTPUT="$(run_with_helpers "${MEMORY_SETUP}"'; printf "time~epoch~mem_available [GB]~swap_used [GB]~HandBrakeCLI_rss [GB]~tools_rss [GB]\na~1~30.00~0.00~0.00~20.00\nb~9999999998~2.50~3.00~15.00~18.00\nc~9999999999~0.80~8.00~16.00~19.00\n" > metrics.csv; printf "MemAvailable: 12582912 kB\n" > meminfo; checking_memory_headroom; memory_entry 137; memory_entry 0; cat memory.csv' 2>&1)"
assert_contains "memory.csv has its header" "${OUTPUT}" "video_id~checked~epoch~available [GB]~held [GB]~can get [GB]~peak [GB]~peak source~needed [GB]~warned~encode status~min available [GB]~max swap [GB]~max tools_rss [GB]~max HandBrakeCLI [GB]"
assert_contains "memory.csv: estimate, encode status and what was used after the check" "${OUTPUT}" "~12.0~19.0~31.0~20.0~measured~22.0~no~137~0.80~8.00~19.00~16.00"
if [ "$(grep -c '~137~' <<< "${OUTPUT}")" -eq 1 ] && [[ ${OUTPUT} != *"~0~"* ]]; then pass "memory.csv: one row per check"; else fail "memory.csv: one row per check"; fi
if [ -x "${REPO_ROOT}/.venv/bin/python3" ] && "${REPO_ROOT}/.venv/bin/python3" -c "import xlsxwriter" 2>/dev/null
then
  mkdir -p "${WORK_DIR}/report"
  printf 'time~epoch~cpu_busy [%%]~mem_used [GB]~card0_busy [%%]~ffmpeg_rss [GB]~tools_rss [GB]\n2026-11-05 10:00:00~1.0~50.0~10.00~~1.00~1.00\n2026-11-05 10:00:05~6.0~60.0~11.00~90~2.00~2.00\n' > "${WORK_DIR}/report/metrics.csv"
  printf 'video_id~step~start~end~start_epoch~end_epoch~duration [s]~chunk [%%]\n021~interpolating~a~b~1~2~300.0~60\n021~encoding~a~b~1~2~290.0~\nall~whole_run~a~b~1~2~900.0~\n' > "${WORK_DIR}/report/timeline.csv"
  printf 'video_id~runtime\n021~500.1[s]\n' > "${WORK_DIR}/report/statistics.txt"
  printf 'video_id~checked~epoch~available [GB]~held [GB]~can get [GB]~peak [GB]~peak source~needed [GB]~warned~encode status~min available [GB]~max swap [GB]~max tools_rss [GB]~max HandBrakeCLI [GB]\n021~a~1~12.0~0.1~12.1~19.5~measured~21.5~yes~0~0.90~8.00~19.53~16.15\n' > "${WORK_DIR}/report/memory.csv"
  OUTPUT="$("${REPO_ROOT}/.venv/bin/python3" "${REPO_ROOT}/metrics_to_excel.py" "${WORK_DIR}/report" "${WORK_DIR}/report/r.xlsx" 2>&1; echo "STATUS=$?"; "${REPO_ROOT}/.venv/bin/python3" -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); n=z.namelist(); print('SHEETS=%d CHARTS=%d' % (sum(x.startswith('xl/worksheets/sheet') for x in n), sum(x.startswith('xl/charts/chart') for x in n))); print('CHUNK=' + str('<t>021</t>' in z.read('xl/sharedStrings.xml').decode()))" "${WORK_DIR}/report/r.xlsx")"
  assert_contains "metrics_to_excel.py writes the workbook" "${OUTPUT}" "STATUS=0"
  assert_contains "metrics_to_excel.py: charts, metrics, timeline, steps per chunk, memory, statistics; 7 charts" "${OUTPUT}" "SHEETS=6 CHARTS=7"
  assert_contains "metrics_to_excel.py keeps chunk numbers as text" "${OUTPUT}" "CHUNK=True"
else
  echo "  skipped: metrics_to_excel.py (no .venv with xlsxwriter; a run prepares it)"
fi

echo "Ctrl+C cleanup (exit_function, cleaning_after_interrupt)"
INTERRUPT_SETUP='for FUNC in exit_function stop_background_jobs cleaning_after_interrupt compressing_run_logs; do eval "$(sed -n "/^${FUNC}()/,/^  }/p" "'"${REPO_ROOT}"'/interpolation_nncn")"; done; eval "$(sed -n "/^compressing_logs()/,/^  }/p" "'"${REPO_ROOT}"'/.config")"; tput() { :; }; NCNN_METHOD=rife; KEEP_INTERMEDIATES=no; MOVIE_NAME_ARRAY=(video_part_minute_003); rm -rf intr; mkdir intr; cd intr || exit 99; LOG="$PWD/log"; TMP="$PWD/tmp"; TMP_OUT="$PWD/tmp_out"; mkdir -p "$LOG" "$TMP/frame_analysis" "$TMP/in_003/f" "$TMP/out_003" "$TMP_OUT/in_003" "$TMP_OUT/out_003"; echo s > "$TMP/statistics.txt"; echo t > "$TMP/timeline.csv"; echo a > "$TMP/video_part_minute_003.mka"; echo s > "$TMP/video_part_minute_003_subtitles.mkv"; echo v > "$TMP_OUT/video_part_minute_003_rife_48.mkv"; for N in 001 002 003 004; do echo src > video_part_minute_${N}.mkv; done; echo p > video_part_minute_001_rife_48_merged.mkv; echo F > video_part_minute_001_rife_48_merged.mkv.done; echo p > video_part_minute_001_rife_48_encoded.mkv; echo F > video_part_minute_001_rife_48_encoded.mkv.done; echo p > video_part_minute_002_rife_48_merged.mkv; echo F > video_part_minute_002_rife_48_merged.mkv.done; echo p > video_part_minute_002_rife_48_encoded.mkv; echo p > video_part_minute_002_rife_48_encoded_video_only.mkv; echo p > video_part_minute_003_rife_48_merged.mkv; echo src > Film.mkv; sleep 30 > /dev/null 2>&1 & SLEEP_PID=$!'
# exit_function exits, so the results are printed by an EXIT trap (in a subshell, $$ is not its PID)
OUTPUT="$(run_with_helpers "${INTERRUPT_SETUP}"'; trap '"'"'echo "STATUS=$?"; if kill -0 "${SLEEP_PID}" 2>/dev/null; then echo "CHILD RUNNING"; fi; echo "LEFT: $(ls | tr "\n" " ")"; echo "TMP: $(ls tmp tmp_out | tr "\n" " ")"'"'"' EXIT; exit_function' 2>&1)"
assert_contains "Ctrl+C exits with 130" "${OUTPUT}" "STATUS=130"
assert_contains "Ctrl+C says what it does" "${OUTPUT}" "closing processes and cleaning"
if [[ ${OUTPUT} == *"CHILD RUNNING"* ]]; then fail "Ctrl+C stops the processes of the run"; else pass "Ctrl+C stops the processes of the run"; fi
assert_contains "Ctrl+C keeps finished parts and markers, removes source chunks and unfinished parts" "${OUTPUT}" "LEFT: Film.mkv log tmp tmp_out video_part_minute_001_rife_48_encoded.mkv video_part_minute_001_rife_48_encoded.mkv.done video_part_minute_001_rife_48_merged.mkv video_part_minute_001_rife_48_merged.mkv.done video_part_minute_002_rife_48_merged.mkv video_part_minute_002_rife_48_merged.mkv.done "
assert_contains "Ctrl+C removes frames and extracts, keeps statistics and timeline" "${OUTPUT}" "TMP: tmp: statistics.txt timeline.csv  tmp_out: "
assert_contains "Ctrl+C counts what it removed" "${OUTPUT}" "removed ${YELLOW:-}15"
OUTPUT="$(run_with_helpers "${INTERRUPT_SETUP}"'; KEEP_INTERMEDIATES=yes; trap '"'"'echo "LEFT: $(ls | wc -l) $(ls tmp tmp_out | wc -l)"'"'"' EXIT; exit_function' 2>&1)"
assert_contains "Ctrl+C with -k removes nothing" "${OUTPUT}" "LEFT: 17 13"
assert_contains "Ctrl+C with -k says so" "${OUTPUT}" "-k: intermediate files are kept"
OUTPUT="$(run_with_helpers "${INTERRUPT_SETUP}"'; MOVIE_NAME_ARRAY=("Short Film"); echo p > "Short Film_rife_48_merged.mkv"; echo p > "Short Film_rife_48_encoded.mkv"; echo F > "Short Film_rife_48_encoded.mkv.done"; trap '"'"'echo "LEFT: $(ls | grep Short | tr "\n" " ")"'"'"' EXIT; exit_function' 2>&1)"
assert_contains "Ctrl+C on an unsplit movie removes only its unfinished part" "${OUTPUT}" "LEFT: Short Film_rife_48_encoded.mkv Short Film_rife_48_encoded.mkv.done "

OUTPUT="$(run_with_helpers "${INTERRUPT_SETUP}"'; printf "a fail\nb fail\n" | gzip > "$LOG/video_part_minute_001_ncnn_rife.log.gz"; printf "c fail\nok\n" > "$LOG/video_part_minute_002_ncnn_rife.log"; trap "" EXIT; exit_function' 2>&1)"
assert_contains "Ctrl+C counts NCNN errors in compressed logs of finished chunks" "${OUTPUT}" "001_ncnn_rife.log.gz${WINE:-}, errors=2"
assert_contains "Ctrl+C counts NCNN errors in the log of the current chunk" "${OUTPUT}" "002_ncnn_rife.log${WINE:-}, errors=1"
OUTPUT="$(run_with_helpers "${INTERRUPT_SETUP}"'; SILENT_LOG="$LOG/interpolation_nncn_silent_x.log"; echo s > "$SILENT_LOG"; echo m > "$LOG/Film_splitting_video.log"; echo c > "$LOG/video_part_minute_003_inter_inframes.log"; trap '"'"'echo "LOGS: $(ls "$LOG" | tr "\n" " ")"'"'"' EXIT; exit_function' 2>&1)"
assert_contains "Ctrl+C compresses the remaining logs, the silent log stays plain" "${OUTPUT}" "LOGS: Film_splitting_video.log.gz interpolation_nncn_silent_x.log video_part_minute_003_inter_inframes.log.gz "

echo "frames lost at an open-GOP split are recovered (ffprobe and ffmpeg replaced by fakes)"
mkdir -p "${WORK_DIR}/recoverbin"
cat > "${WORK_DIR}/recoverbin/ffprobe" <<'EOF'
#!/usr/bin/env bash
# fake ffprobe of the next chunk: packets (decode order) from next_packets.csv, first frame from next_first.txt
if [[ " $* " == *"packet=pts_time,flags"* ]]
then
  cat next_packets.csv
else
  cat next_first.txt
fi
EOF
cat > "${WORK_DIR}/recoverbin/ffmpeg" <<'EOF'
#!/usr/bin/env bash
# fake ffmpeg: records its arguments, writes -frames:v PNGs from -start_number (exits 1 with fail_ffmpeg)
printf '%s\n' "$@" > recover_args.txt
while [ $# -gt 1 ]
do
  case "$1" in
    -frames:v) COUNT="$2" ;;
    -start_number) FIRST="$2" ;;
  esac
  OUT="$2"
  shift
done
for N in $(seq "${FIRST}" $((FIRST + COUNT - 1)))
do
  echo png > "$(printf "${OUT}" "${N}")"
done
if [ -e fail_ffmpeg ]
then
  exit 1
fi
EOF
chmod +x "${WORK_DIR}/recoverbin/ffprobe" "${WORK_DIR}/recoverbin/ffmpeg"
# K of the next chunk at 0.042 in the chunk (= 120.120 s in the movie); 0.000 and -0.042 lost, 0.042 first decoded
RECOVER_SETUP='LOG="$PWD/log"; mkdir -p "$LOG" fr; rm -f fr/* recover_args.txt fail_ffmpeg; WHOLE_MOVIE_NAME_ARRAY=(Film); SPLIT_TIMESTAMPS="60.060s,120.120s"; TONE_MAPPING_FILTER="libplacebo=tm"; echo next > video_part_minute_003.mkv
printf "%s\n" 0.042000,K__ 0.000000,___ -0.042000,___ 0.209000,___ 0.125000,___ > next_packets.csv; echo 0.042000 > next_first.txt'
OUTPUT="$(PATH="${WORK_DIR}/recoverbin:${PATH}" run_with_helpers "${RECOVER_SETUP}"'; recovering_lost_frames video_part_minute_002 fr 1437; echo "RECOVERED=${RECOVERED_FRAMES_COUNT} FILES=$(ls fr | tr "\n" " ")"; tr "\n" " " < recover_args.txt' 2>&1)"
assert_contains "lost frames of the next chunk are recovered after the decoded ones" "${OUTPUT}" "RECOVERED=2 FILES=00001438.png 00001439.png"
assert_contains "they are tone-mapped, then selected by their movie timestamps (libplacebo after select waited for the movie's end)" "${OUTPUT}" "libplacebo=tm,select='lt(abs(t-120.036000),0.005)+lt(abs(t-120.078000),0.005)'"
assert_contains "the movie is decoded from before them, with its own timestamps" "${OUTPUT}" "-copyts -ss 119.036 -i Film.mkv"
OUTPUT="$(PATH="${WORK_DIR}/recoverbin:${PATH}" run_with_helpers "${RECOVER_SETUP}"'; touch fail_ffmpeg; recovering_lost_frames video_part_minute_002 fr 1437; echo "RECOVERED=${RECOVERED_FRAMES_COUNT} FILES=[$(ls fr)]"' 2>&1)"; STATUS=$?
assert_status   "a failed recovery does not stop the run" 0 "${STATUS}"
assert_contains "a failed recovery warns and removes its frames" "${OUTPUT}" "RECOVERED=0 FILES=[]"
assert_contains "a failed recovery says the part is short" "${OUTPUT}" "this part is 2 frame(s) short"
OUTPUT="$(PATH="${WORK_DIR}/recoverbin:${PATH}" run_with_helpers "${RECOVER_SETUP}"'; printf "%s\n" 0.000000,K__ 0.167000,___ > next_packets.csv; echo 0.000000 > next_first.txt; recovering_lost_frames video_part_minute_002 fr 1440; echo "CLOSED=${RECOVERED_FRAMES_COUNT}"; recovering_lost_frames video_part_minute_003 fr 1440; echo "LAST=${RECOVERED_FRAMES_COUNT}"; if [ -e recover_args.txt ]; then echo DECODED; fi' 2>&1)"
assert_contains "a closed-GOP split loses nothing" "${OUTPUT}" "CLOSED=0"
assert_contains "the last chunk has no next chunk to recover from" "${OUTPUT}" "LAST=0"
if [[ ${OUTPUT} == *DECODED* ]]; then fail "nothing is decoded when nothing is lost"; else pass "nothing is decoded when nothing is lost"; fi

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
# niceness and arguments, takes 2 s and writes the -o file (or fails when fail_hb exists, and is
# killed with SIGKILL like by the out-of-memory killer when fail_hb contains "kill")
if [[ " $* " == *" --scan "* ]]
then
  printf 'Version: {\n}\nJSON Title Set: {"TitleList": [{"Crop": [%s]}]}\n' "$(cat crop.txt)"
  echo "HandBrake has exited." >&2
  exit 0
fi
ps -o ni= -p $$ | tr -d ' ' > hb_nice.txt
printf '%s\n' "$@" > hb_args.txt
# "hang": the same percentage forever, like the hung encode of chunk 097 ("hang_noterm" also
# ignores SIGTERM)
if [[ $(cat fail_hb 2>/dev/null) == hang* ]]
then
  if [[ $(cat fail_hb) == hang_noterm ]]
  then
    trap '' TERM
  fi
  while true
  do
    printf 'Encoding: task 1 of 1, 99.96 %% (1.00 fps, avg 1.00 fps, ETA 00h00m01s)\r'
    sleep 0.2
  done
fi
sleep 2
if [ -e fail_hb ]
then
  if [[ $(cat fail_hb) == kill ]]
  then
    kill -9 $$
  fi
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
# the time of the first frame of the merged part from start.txt (default 0), otherwise its streams
if [[ " $* " == *"best_effort_timestamp_time"* ]]
then
  cat start.txt 2>/dev/null || echo "0.000000"
  exit 0
fi
printf '{"streams":[{"index":0,"codec_type":"video"},{"index":1,"codec_type":"audio","tags":{"language":"eng"}},{"index":2,"codec_type":"subtitle","tags":{"language":"pol"}}]}\n'
EOF
cat > "${WORK_DIR}/hbbin/mkvmerge" <<'EOF'
#!/usr/bin/env bash
# fake mkvmerge: records its arguments and writes the -o file (fails with 2 when fail_mux exists)
printf '%s\n' "$@" > mux_args.txt
if [ -e fail_mux ]
then
  exit 2
fi
if [ "$1" = "-o" ]
then
  echo "fake muxed" > "$2"
fi
EOF
chmod +x "${WORK_DIR}/hbbin/HandBrakeCLI" "${WORK_DIR}/hbbin/ffprobe" "${WORK_DIR}/hbbin/mkvmerge"
PART_SETUP='TMP="$PWD/t"; LOG="$PWD/log"; mkdir -p "$TMP" "$LOG"; rm -f "$LOG"/* *.done fail_hb fail_mux start.txt; WHOLE_MOVIE_NAME_ARRAY=(My Movie); NCNN_METHOD=rife; KEEP_INTERMEDIATES=no; VERBOSE=yes; TARGET_FRAME_COUNT=2; INTER_FRAMES_COUNT=3000; INPUT_FPS=25; echo merged > p_merged.mkv; handbrake_encode_settings; HANDBRAKE_CROP=8:4:0:0'
OUTPUT="$(PATH="${WORK_DIR}/hbbin:${PATH}" run_with_helpers 'LOG="$PWD/log"; mkdir -p "$LOG"; echo "8, 4, 0, 0" > crop.txt; detecting_crop whole.mkv; echo "CROP=${HANDBRAKE_CROP}"' 2>&1)"
assert_contains "the crop is read from one scan of the whole video" "${OUTPUT}" "CROP=8:4:0:0"
PATH="${WORK_DIR}/hbbin:${PATH}" run_with_helpers 'LOG="$PWD/log"; mkdir -p "$LOG"; echo "" > crop.txt; detecting_crop whole.mkv' > /dev/null 2>&1
assert_status "an unreadable crop stops the run with 1" 1 $?
OUTPUT="$(PATH="${WORK_DIR}/hbbin:${PATH}" run_with_helpers "${PART_SETUP}"'; S=$(date +%s); starting_part_encoding p_merged.mkv p_encoded.mkv ""; echo "RETURNED_AFTER=$(( $(date +%s) - S ))"; finishing_part_encoding; echo "DONE=$(head -n1 p_encoded.mkv.done) PROFILE=$(sed -n 2p p_encoded.mkv.done) RUNTIME=${ENCODING_RUNTIME} NICE=$(cat hb_nice.txt) CONTENT=$(cat p_encoded.mkv)"; if [ -e p_merged.mkv ]; then echo MERGED_KEPT; fi; if [ -e p_encoded_video_only.mkv ]; then echo VIDEO_ONLY_KEPT; fi; tr "\n" " " < hb_args.txt; echo; echo "MUX: $(tr "\n" " " < mux_args.txt)"' 2>&1)"
assert_contains "starting returns at once (the encode keeps running)" "${OUTPUT}" "RETURNED_AFTER=0"
assert_contains "finishing marks the encoded part with the movie name and profile" "${OUTPUT}" "DONE=My Movie PROFILE=film RUNTIME=0s"
assert_contains "the encode runs with lower priority (nice 10)" "${OUTPUT}" "NICE=10"
assert_contains "every part gets the crop of the whole video" "${OUTPUT}" "--crop 8:4:0:0"
assert_contains "the movies_encoding encoder settings are used" "${OUTPUT}" "--encoder svt_av1_10bit --quality 22"
assert_contains "HandBrake encodes the video only (no frames dropped for A/V sync)" "${OUTPUT}" "-o p_encoded_video_only.mkv"
assert_contains "HandBrake gets no audio or subtitles" "${OUTPUT}" "--no-markers -a none -s none"
assert_contains "mkvmerge copies the chosen audio and subtitles from the part" "${OUTPUT}" "MUX: -o p_encoded.mkv p_encoded_video_only.mkv -D --no-chapters --no-attachments --no-global-tags --audio-tracks 1 --subtitle-tracks 2 p_merged.mkv"
assert_contains "the muxed file is the encoded part" "${OUTPUT}" "CONTENT=fake muxed"
OUTPUT="$(PATH="${WORK_DIR}/hbbin:${PATH}" run_with_helpers "${PART_SETUP}"'; echo 0.042000 > start.txt; starting_part_encoding p_merged.mkv p_encoded.mkv ""; finishing_part_encoding; echo "MUX: $(tr "\n" " " < mux_args.txt)"' 2>&1)"
assert_contains "the encoded video starts where the merged part's video starts" "${OUTPUT}" "MUX: -o p_encoded.mkv --sync 0:42 p_encoded_video_only.mkv -D"
if [[ ${OUTPUT} == *VIDEO_ONLY_KEPT* ]]; then fail "the video-only encode is removed after muxing"; else pass "the video-only encode is removed after muxing"; fi
if [[ ${OUTPUT} == *MERGED_KEPT* ]]; then fail "the merged part is removed after its encode"; else pass "the merged part is removed after its encode"; fi
OUTPUT="$(PATH="${WORK_DIR}/hbbin:${PATH}" run_with_helpers "${PART_SETUP}"'; KEEP_INTERMEDIATES=yes; starting_part_encoding p_merged.mkv p_encoded.mkv ""; finishing_part_encoding; if [ -e p_merged.mkv ]; then echo MERGED_KEPT; fi' 2>&1)"
assert_contains "-k keeps the merged part" "${OUTPUT}" "MERGED_KEPT"
OUTPUT="$(PATH="${WORK_DIR}/hbbin:${WORK_DIR}/vmafbin:${PATH}" run_with_helpers "${PART_SETUP}"'; touch fail_hb; QUALITY_METRIC_CHECK_PID=""; starting_part_encoding p_merged.mkv p_encoded.mkv o.mkv; finishing_part_encoding; echo "FLAG=${PART_ENCODING_FAILED}"; finishing_quality_metric; echo "MEAN=${VMAF_MEAN}"; if [ -e p_merged.mkv ]; then echo MERGED_KEPT; fi; if [ -e p_encoded.mkv.done ]; then echo MARKED; fi' 2>&1)"; STATUS=$?
assert_status   "finishing a failed encode returns, the caller stops the run" 0 "${STATUS}"
assert_contains "a failed encode is flagged for the caller" "${OUTPUT}" "FLAG=yes"
assert_contains "a failed encode is reported with HandBrake's exit code" "${OUTPUT}" "failed with exit code 4"
assert_contains "a failed encode keeps the merged part, VMAF is error" "${OUTPUT}" "MEAN=error"
assert_contains "a failed encode keeps its merged part" "${OUTPUT}" "MERGED_KEPT"
if [[ ${OUTPUT} == *MARKED* ]]; then fail "a failed encode is not marked as finished"; else pass "a failed encode is not marked as finished"; fi
OUTPUT="$(PATH="${WORK_DIR}/hbbin:${PATH}" run_with_helpers "${PART_SETUP}"'; touch fail_mux; starting_part_encoding p_merged.mkv p_encoded.mkv ""; finishing_part_encoding; if [ -e p_merged.mkv ]; then echo MERGED_KEPT; fi; if [ -e p_encoded.mkv.done ]; then echo MARKED; fi' 2>&1)"
assert_contains "a failed mux is reported with mkvmerge's exit code" "${OUTPUT}" "failed with exit code 2"
if [[ ${OUTPUT} == *"out-of-memory"* ]]; then fail "only exit code 137 is reported as out of memory"; else pass "only exit code 137 is reported as out of memory"; fi
assert_contains "a failed mux keeps its merged part" "${OUTPUT}" "MERGED_KEPT"
if [[ ${OUTPUT} == *MARKED* ]]; then fail "a failed mux is not marked as finished"; else pass "a failed mux is not marked as finished"; fi
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

OUTPUT="$(PATH="${WORK_DIR}/hbbin:${PATH}" run_with_helpers "${PART_SETUP}"'; echo kill > fail_hb; starting_part_encoding p_merged.mkv p_encoded.mkv ""; finishing_part_encoding; if [ -e p_merged.mkv ]; then echo MERGED_KEPT; fi' 2>&1)"
assert_contains "an encode killed with SIGKILL is reported with 137" "${OUTPUT}" "failed with exit code 137"
assert_contains "an encode killed with SIGKILL points at the out-of-memory killer" "${OUTPUT}" "most likely by the out-of-memory killer"
assert_contains "a killed encode keeps its merged part" "${OUTPUT}" "MERGED_KEPT"
for HANG_MODE in hang hang_noterm
do
  OUTPUT="$(PATH="${WORK_DIR}/hbbin:${PATH}" run_with_helpers "${PART_SETUP}"'; echo '"${HANG_MODE}"' > fail_hb; HANDBRAKE_STALL_SEC=2; HANDBRAKE_WATCH_INTERVAL_SEC=1; S=$(date +%s); starting_part_encoding p_merged.mkv p_encoded.mkv ""; finishing_part_encoding; echo "TOOK=$(( $(date +%s) - S )) FLAG=${PART_ENCODING_FAILED}"; if [ -e p_merged.mkv ]; then echo MERGED_KEPT; fi; if pgrep -f "'"${WORK_DIR}"'/[h]bbin/HandBrakeCLI" > /dev/null; then echo HB_LEFT; fi; grep -a "^watchdog:" log/p_encoded.mkv_handbrake.log; tail -n1 t/memory.csv' 2>&1)"
  assert_contains "watchdog (${HANG_MODE}): a hung encode is reported with 124" "${OUTPUT}" "failed with exit code 124"
  assert_contains "watchdog (${HANG_MODE}): the reason is shown" "${OUTPUT}" "stopped by the watchdog"
  assert_contains "watchdog (${HANG_MODE}): the log tells why HandBrake was stopped" "${OUTPUT}" "watchdog: no progress for"
  assert_contains "watchdog (${HANG_MODE}): the run is stopped, the merged part kept" "${OUTPUT}" "FLAG=yes"
  assert_contains "watchdog (${HANG_MODE}): a failed encode gets its memory.csv row" "${OUTPUT}" "~124~"
  if [[ ${OUTPUT} == *HB_LEFT* ]]; then fail "watchdog (${HANG_MODE}): HandBrake does not stay behind"; else pass "watchdog (${HANG_MODE}): HandBrake does not stay behind"; fi
done
mkdir -p "${WORK_DIR}/lobin"
printf '#!/usr/bin/env bash\nsleep 30\n' > "${WORK_DIR}/lobin/HandBrakeCLI"
chmod +x "${WORK_DIR}/lobin/HandBrakeCLI"
"${WORK_DIR}/lobin/HandBrakeCLI" &
LEFTOVER_TEST_PID=$!
OUTPUT="$(run_with_helpers 'eval "$(sed -n "/^warning_leftover_processes()/,/^  }/p" "'"${REPO_ROOT}"'/interpolation_nncn")"; warning_leftover_processes' 2>&1)"
kill "${LEFTOVER_TEST_PID}" 2>/dev/null
assert_contains "after a stop, a still running HandBrake is listed" "${OUTPUT}" "still running (PID, time, command)"
assert_contains "with its PID" "${OUTPUT}" "${LEFTOVER_TEST_PID}"
if grep -B2 'exit 130' "${REPO_ROOT}/interpolation_nncn" | grep -q 'warning_leftover_processes'; then pass "Ctrl+C ends with the leftover check"; else fail "Ctrl+C ends with the leftover check"; fi
mkdir -p "${WORK_DIR}/exitvenv/.venv/bin"
printf '#!/bin/sh\n' > "${WORK_DIR}/exitvenv/.venv/bin/python3"
chmod +x "${WORK_DIR}/exitvenv/.venv/bin/python3"
OUTPUT=""
for EXIT_CASE in "1 123" "0 123" "130 123" "1 "
do
  read -r EXIT_TEST_STATUS EXIT_TEST_PID <<< "${EXIT_CASE}"
  OUTPUT+="${EXIT_TEST_STATUS}/${EXIT_TEST_PID:-none}:$(bash -c 'for FUNC in exiting_function stop_background_jobs; do eval "$(sed -n "/^${FUNC}()/,/^  }/p" "'"${REPO_ROOT}"'/interpolation_nncn")"; done; exporting_run_report() { echo REPORT; }; SCRIPTS_HOME="'"${WORK_DIR}"'/exitvenv"; METRICS_SAMPLING_PID="'"${EXIT_TEST_PID}"'"; trap exiting_function EXIT; exit '"${EXIT_TEST_STATUS}" 2>&1) "
done
assert_contains "an error exit writes the report; success, Ctrl+C and an exit before the metrics do not" "${OUTPUT}" "1/123:REPORT 0/123: 130/123: 1/none: "
if grep -q '^trap "exiting_function" EXIT' "${REPO_ROOT}/interpolation_nncn"; then pass "the EXIT trap is exiting_function"; else fail "the EXIT trap is exiting_function"; fi
STOP_SETUP='eval "$(sed -n "/^stopping_after_failed_encode()/,/^  }/p;/^encoded_part_profile()/,/^  }/p" "'"${REPO_ROOT}"'/interpolation_nncn")"'
run_with_helpers "${STOP_SETUP}"'; PART_ENCODING_FAILED=no; stopping_after_failed_encode' > /dev/null 2>&1
assert_status   "the run goes on after a successful encode" 0 $?
OUTPUT="$(run_with_helpers "${STOP_SETUP}"'; PART_ENCODING_FAILED=yes; stopping_after_failed_encode' 2>&1)"; STATUS=$?
assert_status   "the run stops with 1 after a failed encode" 1 "${STATUS}"
assert_contains "the stop tells how to continue" "${OUTPUT}" "run again with"
OUTPUT="$(run_with_helpers "${STOP_SETUP}"'; printf "M\ngrain\n" > new.done; echo M > old.done; echo "NEW=$(encoded_part_profile new.done) OLD=$(encoded_part_profile old.done)"' 2>&1)"
assert_contains "the profile is read from the marker, unknown for older markers" "${OUTPUT}" "NEW=grain OLD=unknown"
# the run stops only after the chunk processed alongside the failed encode is marked as done
LINE_MARK="$(grep -n '_merged.mkv.done"$' "${REPO_ROOT}/interpolation_nncn" | tail -n1 | cut -d: -f1)"
LINE_STOP="$(grep -n '^    stopping_after_failed_encode$' "${REPO_ROOT}/interpolation_nncn" | cut -d: -f1)"
if [ -n "${LINE_MARK}" ] && [ -n "${LINE_STOP}" ] && [ "${LINE_MARK}" -lt "${LINE_STOP}" ]; then pass "a failed encode stops the run after the current chunk is marked"; else fail "a failed encode stops the run after the current chunk is marked"; fi

echo "checking_space_background (space estimates of a small chunk)"
OUTPUT="$(run_with_helpers 'TMP=.; IN_DIR=in; OUT_DIR=out; MOVIE_NAME_ARRAY=(m); NCNN_METHOD=rife; OUTPUT_FPS_ROUND=50; VERBOSE=no; TERMINAL_HEIGHT=40; mkdir -p in/m; INPUT_FRAMES_MAX_TSPACE=0.00; INTER_FRAMES_MAX_TSPACE=0.40; sleep 4 & checking_space_background $! . .; wait; echo "OVERALL=$(cat MAX_SPACE_TAKEN_OVERALL)"' 2>&1)"
if [[ ${OUTPUT} == *"invalid number"* ]] || [[ ${OUTPUT} == *"Divide by zero"* ]]; then fail "a zero space estimate does not break the space monitor"; else pass "a zero space estimate does not break the space monitor"; fi
assert_contains "the space monitor writes its peak" "${OUTPUT}" "OVERALL=0"
if grep -A3 'PENDING_STATISTICS_SPACE="' "${REPO_ROOT}/interpolation_nncn" | grep -q 'rm -f -- "${TMP}/MAX_SPACE_TAKEN_INPUT_DIR"'; then pass "the peak space is reset after each chunk"; else fail "the peak space is reset after each chunk"; fi

echo "joining_encoded_parts (mkvmerge replaced by a fake that records its arguments)"
mkdir -p "${WORK_DIR}/joinbin"
cat > "${WORK_DIR}/joinbin/mkvmerge" <<'EOF'
#!/usr/bin/env bash
# fake mkvmerge: -J prints the track list in tracks.json, a join records its arguments
if [[ $1 == -J ]]; then cat tracks.json; exit 0; fi
printf '%s\n' "$@" > join_args.txt
EOF
chmod +x "${WORK_DIR}/joinbin/mkvmerge"
JOIN_SETUP='eval "$(sed -n "/^joining_encoded_parts()/,/^  }/p" "'"${REPO_ROOT}"'/interpolation_nncn")"; WHOLE_MOVIE_NAME_ARRAY=(S); NCNN_METHOD=rife; LAST_VIDEO_FRAGMENT_ID=002; LOG=.; TMP=.; FINAL_VIDEO_FILE=final.mkv; KEEP_INTERMEDIATES=yes; for N in 001 002; do echo part > video_part_minute_${N}_rife_50_encoded.mkv; echo S > video_part_minute_${N}_rife_50_encoded.mkv.done; done'
OUTPUT="$(PATH="${WORK_DIR}/joinbin:${PATH}" run_with_helpers "${JOIN_SETUP}"'; echo "{\"tracks\":[{\"id\":0,\"type\":\"video\"},{\"id\":1,\"type\":\"audio\",\"properties\":{\"language\":\"eng\"}},{\"id\":2,\"type\":\"audio\",\"properties\":{\"language\":\"ger\"}},{\"id\":3,\"type\":\"subtitles\",\"properties\":{\"language\":\"pol\"}},{\"id\":4,\"type\":\"subtitles\",\"properties\":{\"language\":\"fre\"}}]}" > tracks.json; joining_encoded_parts; echo "JOIN: $(tr "\n" " " < join_args.txt)"' 2>&1)"
assert_contains "the join takes only the video of the parts" "${OUTPUT}" "-o final.mkv --no-audio --no-subtitles video_part_minute_001_rife_50_encoded.mkv + --no-audio --no-subtitles video_part_minute_002_rife_50_encoded.mkv --no-video"
assert_contains "the join takes the chunks' audio and subtitles from the source" "${OUTPUT}" "--audio-tracks 1 --subtitle-tracks 3 S.mkv"
OUTPUT="$(PATH="${WORK_DIR}/joinbin:${PATH}" run_with_helpers "${JOIN_SETUP}"'; echo "{\"tracks\":[{\"id\":0,\"type\":\"video\"},{\"id\":1,\"type\":\"audio\",\"properties\":{\"language\":\"ger\"}},{\"id\":2,\"type\":\"audio\",\"properties\":{\"language\":\"fre\"}}]}" > tracks.json; joining_encoded_parts; echo "JOIN: $(tr "\n" " " < join_args.txt)"' 2>&1)"
assert_contains "without pl/nl/en audio the join takes all source audio, no subtitles" "${OUTPUT}" "--audio-tracks 1,2 --no-subtitles S.mkv"
OUTPUT="$(PATH="${WORK_DIR}/joinbin:${PATH}" run_with_helpers "${JOIN_SETUP}"'; eval "$(sed -n "/^encoded_part_profile()/,/^  }/p" "'"${REPO_ROOT}"'/interpolation_nncn")"; OPTIMIZATION=grain; printf "S\ngrain\n" > video_part_minute_002_rife_50_encoded.mkv.done; echo "{\"tracks\":[]}" > tracks.json; joining_encoded_parts; echo "JOIN: $(tr "\n" " " < join_args.txt)"' 2>&1)"
assert_contains "the join warns about parts of another profile" "${OUTPUT}" "were encoded with another profile than"
assert_contains "the warning lists the parts and their profiles" "${OUTPUT}" "mixes them: 001 (unknown)"
assert_contains "parts with a profile line are still joined" "${OUTPUT}" "video_part_minute_002_rife_50_encoded.mkv"

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

echo "timeline.csv (steps with wall clock times, percent of their chunk)"
OUTPUT="$(run_with_helpers 'TMP="$PWD/tl"; mkdir -p "$TMP"; echo "video_id~step~start~end~start_epoch~end_epoch~duration [s]~chunk [%]" > "$TMP/timeline.csv"; VIDEO_FRAGMENT_ID=007; START_TIME=1761742800.2500; END_TIME=1761742830.7500; timeline_entry interpolating; START_TIME=1761742800.0000; END_TIME=1761742861.0000; timeline_entry chunk; START_TIME=1761742861.0000; END_TIME=1761742891.5000; timeline_entry encoding; timeline_entry joining all; timeline_percentages; cat "$TMP/timeline.csv"' 2>&1)"
if grep -Eq '^007~interpolating~[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:00\.2~[0-9-]{10} [0-9:]{8}\.7~' <<< "${OUTPUT}"; then pass "a step row has human start/end times to 0.1 s"; else fail "a step row has human start/end times to 0.1 s"; fi
assert_contains "the duration is rounded to 0.1 s" "${OUTPUT}" "~1761742800.2500~1761742830.7500~30.5~"
assert_contains "the percent of the chunk is filled in at the end" "${OUTPUT}" "~30.5~50.0"
assert_contains "a background step is measured against its own chunk" "${OUTPUT}" "007~encoding~"
assert_contains "the chunk row is 100 percent" "${OUTPUT}" "~61.0~100.0"
assert_contains "a run-wide row has no percent" "${OUTPUT}" "all~joining~"
if grep -q '^all~joining~.*~$' <<< "${OUTPUT}"; then pass "a run-wide row keeps the percent empty"; else fail "a run-wide row keeps the percent empty"; fi

echo "joining parts"
if grep -A3 '^appending_mkvs()' "${REPO_ROOT}/.config_video" | grep -q -- "mkvmerge --append-mode track"; then pass "parts are joined with --append-mode track (no gaps from long subtitles)"; else fail "parts are joined with --append-mode track (no gaps from long subtitles)"; fi

echo "short chunks"
if grep -q 'frame_analysis/output0002' "${REPO_ROOT}/.config_video"; then fail "frame analysis reads the first sample (a chunk of up to 100 frames has only one)"; else pass "frame analysis reads the first sample (a chunk of up to 100 frames has only one)"; fi

echo
echo "passed: ${PASSED}, failed: ${FAILED}"
[ "${FAILED}" -eq 0 ]
