#!/bin/bash
# Step 3: Burn-in (hard-sub) the .srt onto the .mp4, producing "<name>.sub.mp4"
# next to the original (original mp4 is never modified). Runs ffmpeg inside
# Docker (jrottenberg/ffmpeg:6-ubuntu, has libass) — no local ffmpeg with
# subtitle support is required.
#
# Usage:
#   ./03_burn_sub.sh <name>          # one video: folder "<name>" under ./output
#   ./03_burn_sub.sh <data.json>     # batch: all FolderName entries, under ./output
#
# All video/subtitle folders live under ./output (inside this tool). <name>
# may also be an absolute path if you need to point at a folder elsewhere.
#
# Skips a folder if it has no .srt yet, or already has a burned output.
#
# Requirement: Docker installed and running. First run pulls the image:
#   docker pull jrottenberg/ffmpeg:6-ubuntu

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <folder|data.json>" >&2
  exit 1
fi

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="jrottenberg/ffmpeg:6-ubuntu"
OUTPUT_DIR="$SELF_DIR/output"
mkdir -p "$OUTPUT_DIR"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found on PATH" >&2
  exit 1
fi

# Resolve a bare folder name under ./output; absolute paths pass through.
resolve_dir() {
  if [[ "$1" == /* ]]; then
    printf '%s' "$1"
  else
    printf '%s' "$OUTPUT_DIR/$1"
  fi
}

# Escape a path for safe use inside a quoted ffmpeg filtergraph value.
escape_for_filter() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\'/\\\'}"
  printf '%s' "$s"
}

process_one() {
  local dir="$1"

  if [[ ! -d "$dir" ]]; then
    echo "  skip: folder not found ($dir)"
    return 2
  fi

  local srt
  srt="$(find "$dir" -maxdepth 1 -iname '*.srt' | head -n 1)"
  if [[ -z "$srt" ]]; then
    echo "  skip: no .srt yet"
    return 3
  fi

  local video="${srt%.srt}.mp4"
  if [[ ! -f "$video" ]]; then
    echo "  skip: no matching .mp4 for $(basename "$srt")"
    return 2
  fi

  local out="${video%.mp4}.sub.mp4"
  if [[ -f "$out" ]]; then
    echo "  skip: already burned ($(basename "$out"))"
    return 1
  fi

  local dir_abs video_base srt_base out_base srt_escaped
  dir_abs="$(cd "$dir" && pwd)"
  video_base="$(basename "$video")"
  srt_base="$(basename "$srt")"
  out_base="$(basename "$out")"
  srt_escaped="$(escape_for_filter "$srt_base")"

  echo "  burning: $video_base"
  docker run --rm -v "$dir_abs":/data -w /data "$IMAGE" \
    -y -i "$video_base" -vf "subtitles=filename='$srt_escaped'" -c:a copy "$out_base"

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
  echo "Newly burned:    $BUILT"
  echo "Already burned:  $DONE"
  echo "Not ready (no srt yet): $NOT_READY"
  echo "Missing folder/video:   $MISSING"
else
  process_one "$(resolve_dir "$ARG")"
fi
