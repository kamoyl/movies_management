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

echo "converting_hdr2sdr (ffmpeg replaced by the same fake)"
HDR_SETUP='TMP="$PWD/t"; LOG="$PWD/log"; mkdir -p "$TMP" "$LOG"; MOVIE_NAME_ARRAY=(hdr); echo x > hdr.mkv
echo "{\"frames\":[{\"color_space\":\"bt2020nc\",\"color_primaries\":\"bt2020\",\"color_transfer\":\"smpte2084\"}]}" > "$TMP/hdr_mastering_display.json"'
OUTPUT="$(PATH="${WORK_DIR}/bin:${PATH}" run_with_helpers "${HDR_SETUP}"'; TONE_MAPPING=no; converting_hdr2sdr hdr; [ ! -e hdr_sdr.mkv ] && echo "NO_SDR"' 2>&1)"; STATUS=$?
assert_status   "-T: HDR is left as it is" 0 "${STATUS}"
assert_contains "-T: warns that tone mapping is off" "${OUTPUT}" "tone mapping is switched off"
assert_contains "-T: ffmpeg is not run" "${OUTPUT}" "NO_SDR"
OUTPUT="$(PATH="${WORK_DIR}/bin:${PATH}" run_with_helpers "${HDR_SETUP}"'; rm -f hdr_sdr.mkv; converting_hdr2sdr hdr; [ -s hdr_sdr.mkv ] && [ -L hdr.mkv ] && echo "SDR_LINKED"' 2>&1)"; STATUS=$?
assert_status   "default: HDR is tone-mapped" 0 "${STATUS}"
assert_contains "default: hdr.mkv points to the SDR version" "${OUTPUT}" "SDR_LINKED"

echo
echo "passed: ${PASSED}, failed: ${FAILED}"
[ "${FAILED}" -eq 0 ]
