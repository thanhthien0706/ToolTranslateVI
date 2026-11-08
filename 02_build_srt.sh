#!/bin/bash
# Step 2: Build the final .srt from chunks.json + vi_translations.json
# (vi_translations.json is produced by Claude — see README.md), then clean
# up the temp files.
#
# Usage:
#   ./02_build_srt.sh <name>          # one video: folder "<name>" under ./output
#   ./02_build_srt.sh <data.json>     # batch: all FolderName entries, under ./output
#
# All video/subtitle folders live under ./output (inside this tool). <name>
# may also be an absolute path if you need to point at a folder elsewhere.
#
# Skips a folder if it already has an .srt, isn't transcribed yet, or
# doesn't have vi_translations.json yet.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <folder|data.json>" >&2
  exit 1
fi

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$SELF_DIR/scripts"
OUTPUT_DIR="$SELF_DIR/output"
mkdir -p "$OUTPUT_DIR"

# Resolve a bare folder name under ./output; absolute paths pass through.
resolve_dir() {
  if [[ "$1" == /* ]]; then
    printf '%s' "$1"
  else
    printf '%s' "$OUTPUT_DIR/$1"
  fi
}

if command -v python3 >/dev/null 2>&1; then
  PY="python3"
else
  echo "python3 not found on PATH — install it first (e.g. via Xcode CLT or Homebrew)." >&2
  exit 1
fi

process_one() {
  local dir="$1"

  if [[ ! -d "$dir" ]]; then
    echo "  skip: folder not found ($dir)"
    return 2
  fi

  if [[ -n "$(find "$dir" -maxdepth 1 -iname '*.srt' | head -n 1)" ]]; then
    echo "  skip: folder already has an .srt"
    return 1
  fi

  local video
  video="$(find "$dir" -maxdepth 1 -iname '*.mp4' | head -n 1)"
  if [[ -z "$video" ]]; then
    echo "  skip: no .mp4 in folder"
    return 2
  fi

  if [[ ! -f "$dir/chunks.json" ]]; then
    echo "  skip: not transcribed yet (run 01_transcribe_chunk.sh first)"
    return 3
  fi

  if [[ ! -f "$dir/vi_translations.json" ]]; then
    echo "  skip: waiting on Vietnamese translation (ask Claude)"
    return 3
  fi

  local srt="${video%.*}.srt"
  echo "  building srt"
  "$PY" "$SCRIPTS/build_srt.py" "$dir/chunks.json" "$dir/vi_translations.json" "$srt"

  echo "  cleanup"
  rm -f "$dir/transcript.json" "$dir/chunks.json" "$dir/vi_translations.json"

  return 0
}

ARG="$1"

if [[ "$ARG" == *.json ]]; then
  if [[ ! -f "$ARG" ]]; then
    echo "JSON not found: $ARG" >&2
    exit 1
  fi
  COUNT="$(jq 'length' "$ARG")"
  BUILT=0
  DONE=0
  NOT_READY=0
  MISSING=0

  for ((i = 0; i < COUNT; i++)); do
    FOLDER="$(jq -r ".[$i].FolderName" "$ARG")"
    echo "[$((i + 1))/$COUNT] $FOLDER"
    set +e
    process_one "$OUTPUT_DIR/$FOLDER"
    STATUS=$?
    set -e
    case $STATUS in
      0) ((BUILT++)) ;;
      1) ((DONE++)) ;;
      2) ((MISSING++)) ;;
      3) ((NOT_READY++)) ;;
    esac
  done

  echo ""
  echo "== Summary =="
  echo "Total entries:   $COUNT"
  echo "Newly built srt: $BUILT"
  echo "Already had srt: $DONE"
  echo "Not ready yet:   $NOT_READY"
  echo "Missing folder/video: $MISSING"
else
  process_one "$(resolve_dir "$ARG")"
fi
