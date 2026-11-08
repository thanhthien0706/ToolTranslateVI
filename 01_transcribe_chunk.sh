#!/bin/bash
# Step 1: Transcribe (mlx-whisper) + chunk into short cues.
#
# Usage:
#   ./01_transcribe_chunk.sh <name>          # one video: folder "<name>" under ./output
#   ./01_transcribe_chunk.sh <data.json>     # batch: all FolderName entries, under ./output
#
# All video/subtitle folders live under ./output (inside this tool), so the
# tool never writes outside its own directory. <name> may also be an
# absolute path if you need to point at a folder elsewhere.
#
# Output per folder: transcript.json, chunks.json
# Skips a folder if it already has an .srt (fully done) or already has
# chunks.json (transcribed, waiting on Vietnamese translation).
#
# First run auto-creates a local Python venv (./.venv-whisper) and installs
# mlx-whisper into it — no manual setup needed. Note: mlx-whisper requires
# Apple Silicon (Metal GPU) and a host `ffmpeg` on PATH — this step cannot
# run in Docker or on non-Apple-Silicon machines. See README.md.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <folder|data.json>" >&2
  exit 1
fi

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV="$SELF_DIR/.venv-whisper"
PY="$VENV/bin/python3"
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

if [[ ! -x "$PY" ]]; then
  echo "Whisper venv not found — creating one-time setup at $VENV ..." >&2
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found on PATH — install it first (e.g. via Xcode CLT or Homebrew)." >&2
    exit 1
  fi
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --upgrade pip
  "$VENV/bin/pip" install -q mlx-whisper
  echo "Done installing mlx-whisper into $VENV" >&2
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
    echo "  skip: no .mp4 in folder (download it first)"
    return 2
  fi

  if [[ -f "$dir/chunks.json" ]]; then
    echo "  skip: already transcribed+chunked, waiting on Vietnamese translation"
    return 3
  fi

  echo "  transcribing: $(basename "$video")"
  "$PY" "$SCRIPTS/transcribe.py" "$video" "$dir/transcript.json"

  echo "  chunking"
  "$PY" "$SCRIPTS/make_chunks.py" "$dir/transcript.json" "$dir/chunks.json"

  return 0
}

ARG="$1"

if [[ "$ARG" == *.json ]]; then
  if [[ ! -f "$ARG" ]]; then
    echo "JSON not found: $ARG" >&2
    exit 1
  fi
  COUNT="$(jq 'length' "$ARG")"
  PROCESSED=0
  DONE=0
  SKIPPED=0
  MISSING=0

  for ((i = 0; i < COUNT; i++)); do
    FOLDER="$(jq -r ".[$i].FolderName" "$ARG")"
    echo "[$((i + 1))/$COUNT] $FOLDER"
    set +e
    process_one "$OUTPUT_DIR/$FOLDER"
    STATUS=$?
    set -e
    case $STATUS in
      0) ((PROCESSED++)) ;;
      1) ((DONE++)) ;;
      2) ((MISSING++)) ;;
      3) ((SKIPPED++)) ;;
    esac
  done

  echo ""
  echo "== Summary =="
  echo "Total entries:        $COUNT"
  echo "Newly transcribed:    $PROCESSED"
  echo "Already had srt:      $DONE"
  echo "Waiting on translation (chunks.json present): $SKIPPED"
  echo "Missing folder/video: $MISSING"
  echo ""
  echo "Next: ask Claude to translate chunks.json -> vi_translations.json for"
  echo "each folder above, then run 02_build_srt.sh."
else
  process_one "$(resolve_dir "$ARG")"
fi
