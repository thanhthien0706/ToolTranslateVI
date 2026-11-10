#!/bin/bash
# Loop over every video folder in this directory and build its .srt via
# TranslateVITool's 02_build_srt.sh (which accepts an absolute folder path).
#
# Usage:
#   ./run_build_srt_all.sh

set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_SRT="/Users/thanhthien/Personal/Tools/TranslateVITool/02_build_srt.sh"

if [[ ! -x "$BUILD_SRT" ]]; then
  echo "Not found or not executable: $BUILD_SRT" >&2
  exit 1
fi

BUILT=0
DONE=0
NOT_READY=0
MISSING=0
TOTAL=0

for dir in "$SELF_DIR"/*/; do
  dir="${dir%/}"
  name="$(basename "$dir")"
  ((TOTAL++))
  echo "[$TOTAL] $name"

  "$BUILD_SRT" "$dir"
  STATUS=$?

  case $STATUS in
    0) ((BUILT++)) ;;
    1) ((DONE++)) ;;
    2) ((MISSING++)) ;;
    3) ((NOT_READY++)) ;;
    *) echo "  unexpected exit code: $STATUS" ;;
  esac
  echo ""
done

echo "== Summary =="
echo "Total folders:    $TOTAL"
echo "Newly built srt:  $BUILT"
echo "Already had srt:  $DONE"
echo "Not ready yet:    $NOT_READY"
echo "Missing mp4/folder: $MISSING"
