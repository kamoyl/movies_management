#!/usr/bin/env bash
# Step 5: ShellCheck gate for the scripts and their configuration.
#
# Run from anywhere:  bash tests/shellcheck.sh
#
# Gate 1 - no ShellCheck "error" findings at all.
# Gate 2 - none of the warning classes fixed in step 5 may come back:
#   SC2078 constant test expression      SC2164 cd without failure handling
#   SC2128 array used without an index   SC2140 broken quoting "A"B"C"
#   SC2048 unquoted ${array[*]} args     SC2288 command name ending in a quote
#   SC2054 commas in arrays (intentional uses carry a disable comment)
# Finally a non-blocking summary of the remaining findings, mostly unquoted
# variables (SC2086) that are harmless for the values these scripts use.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}" || exit 1
FILES=(.config .config_video interpolation_nncn movies_encoding)
GATED_CODES="SC2078,SC2164,SC2128,SC2140,SC2048,SC2288,SC2054"
STATUS=0

if ! command -v shellcheck > /dev/null 2>&1
then
  echo "shellcheck is not installed (macOS: brew install shellcheck, Debian/Ubuntu: apt install shellcheck)" >&2
  exit 127
fi

echo "gate 1: errors"
if shellcheck -s bash -S error "${FILES[@]}"
then
  echo "  ok"
else
  STATUS=1
fi

echo "gate 2: fixed warning classes (${GATED_CODES})"
if shellcheck -s bash -S warning -i "${GATED_CODES}" "${FILES[@]}"
then
  echo "  ok"
else
  STATUS=1
fi

echo "remaining findings (informational, not blocking):"
shellcheck -s bash -f gcc "${FILES[@]}" 2>/dev/null | sed -E 's/.*\[(SC[0-9]+)\]$/\1/' | sort | uniq -c | sort -rn | head -10

exit "${STATUS}"
