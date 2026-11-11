#!/bin/bash
# Step 3: Burn-in (hard-sub) the .srt onto the .mp4, producing "<name>.sub.mp4"
# next to the original (original mp4 is never modified). Runs ffmpeg natively
# and encodes with Apple's hardware encoder (h264_videotoolbox), so the CPU
# stays mostly idle and the Mac stays cool.
#
# Usage:
#   ./03_burn_sub.sh <name>               # one video: folder "<name>" under ./output
#   ./03_burn_sub.sh <data.json>          # batch: all FolderName entries, under ./output
#   ./03_burn_sub.sh --group <name|data.json>
#                                         # (--group may also go last)
#                                         # group mode: burn EVERY <x>.srt/<x>.mp4
#                                         # pair in each folder (e.g. folders made
#                                         # by group-by-prefix: 01.mp4/01.srt, 02...)
#                                         # Burned videos go into a "sub/" subfolder:
#                                         #   w1-d1/01.mp4 -> w1-d1/sub/01.mp4
#
# Without --group, only the first .srt found in a folder is burned (one video
# per folder, the layout produced by 00_download.sh), into "<name>.sub.mp4"
# next to the original.
#
# In --group mode, a "<x>.sub.mp4" left next to the original by an older run
# is moved into sub/<x>.mp4 instead of being burned again.
#
# All video/subtitle folders live under ./output (inside this tool). <name>
# may also be an absolute path if you need to point at a folder elsewhere.
#
# Skips a folder if it has no .srt yet, and skips each video that already has
# a burned output.
# Output is written to a temp file and renamed only on success, so an
# interrupted run never leaves a half-written .sub.mp4 that would be skipped.
#
# Requirement: an ffmpeg build with libass (the `subtitles` filter). The
# regular Homebrew `ffmpeg` formula lacks it; install the keg-only
# `ffmpeg-full` (does not replace the regular ffmpeg used by step 1):
#   brew install ffmpeg-full
# Override the binary with FFMPEG=/path/to/ffmpeg if needed.

set -euo pipefail

usage() {
  echo "Usage: $0 [--group] <folder|data.json>" >&2
  exit 1
}
# --group may come before or after the folder/json argument.
GROUP=0
ARG=""
for a in "$@"; do
  case "$a" in
    --group) GROUP=1 ;;
    -*) usage ;;
    *)
      [[ -n "$ARG" ]] && usage
      ARG="$a"
      ;;
  esac
done
[[ -z "$ARG" ]] && usage

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SELF_DIR/output"
mkdir -p "$OUTPUT_DIR"

# VideoToolbox constant quality, 1-100 (higher = better/bigger). 40 keeps
# subtitles and slide text crisp; override with BURN_QUALITY=<n>.
QUALITY="${BURN_QUALITY:-40}"
if ! [[ "$QUALITY" =~ ^[0-9]+$ ]] || ((QUALITY < 1 || QUALITY > 100)); then
  echo "BURN_QUALITY must be an integer 1-100 (got: $QUALITY)" >&2
  exit 1
fi

# Capture output first: piping into `grep -q` makes ffmpeg die of SIGPIPE,
# which pipefail would report as a failure even when the filter exists.
has_subtitles_filter() {
  local filters
  filters="$("$1" -hide_banner -filters 2>/dev/null)" || return 1
  grep -qE '^ *[^ ]+ +subtitles ' <<<"$filters"
}

# Pick an ffmpeg that has the `subtitles` filter: $FFMPEG, then Homebrew's
# keg-only ffmpeg-full, then whatever ffmpeg is on PATH.
find_ffmpeg() {
  local candidates=()
  [[ -n "${FFMPEG:-}" ]] && candidates+=("$FFMPEG")
  local p
  for p in /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg /usr/local/opt/ffmpeg-full/bin/ffmpeg; do
    candidates+=("$p")
  done
  if command -v brew >/dev/null 2>&1; then
    p="$(brew --prefix ffmpeg-full 2>/dev/null)/bin/ffmpeg"
    candidates+=("$p")
  fi
  if command -v ffmpeg >/dev/null 2>&1; then
    candidates+=("$(command -v ffmpeg)")
  fi
  for p in "${candidates[@]}"; do
    if [[ -x "$p" ]] && has_subtitles_filter "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

if ! FFMPEG_BIN="$(find_ffmpeg)"; then
  echo "No ffmpeg with the 'subtitles' filter (libass) found." >&2
  echo "Install it with:  brew install ffmpeg-full" >&2
  echo "(or point FFMPEG=/path/to/ffmpeg at a build that has libass)" >&2
  exit 1
fi

if ! grep -q h264_videotoolbox <<<"$("$FFMPEG_BIN" -hide_banner -encoders 2>/dev/null)"; then
  echo "ffmpeg at $FFMPEG_BIN has no h264_videotoolbox encoder (macOS only)." >&2
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

# Burn one <x>.srt onto its matching <x>.mp4.
#   normal mode: <dir>/<x>.sub.mp4
#   --group:     <dir>/sub/<x>.mp4
# Returns: 0 burned, 1 already burned, 2 no matching mp4, 4 ffmpeg failed.
burn_one() {
  local srt="$1"

  local video="${srt%.*}.mp4"
  if [[ ! -f "$video" ]]; then
    echo "  skip: no matching .mp4 for $(basename "$srt")"
    return 2
  fi

  local dir_abs video_base out_dir out_base out legacy
  dir_abs="$(cd "$(dirname "$video")" && pwd)"
  video_base="$(basename "$video")"
  legacy="$dir_abs/${video_base%.mp4}.sub.mp4"
  if [[ $GROUP -eq 1 ]]; then
    out_dir="$dir_abs/sub"
    out_base="$video_base"
  else
    out_dir="$dir_abs"
    out_base="${video_base%.mp4}.sub.mp4"
  fi
  out="$out_dir/$out_base"

  if [[ -f "$out" ]]; then
    echo "  skip: already burned (${out#"$dir_abs"/})"
    return 1
  fi
  # Also accept sub/<x>.sub.mp4 (burned copies moved into sub/ by hand).
  if [[ $GROUP -eq 1 && -f "$out_dir/${video_base%.mp4}.sub.mp4" ]]; then
    echo "  skip: already burned (sub/${video_base%.mp4}.sub.mp4)"
    return 1
  fi
  if [[ $GROUP -eq 1 && -f "$legacy" ]]; then
    mkdir -p "$out_dir"
    mv "$legacy" "$out"
    echo "  moved: $(basename "$legacy") -> sub/$out_base (already burned)"
    return 1
  fi

  mkdir -p "$out_dir"
  local tmp_base sub_dir status
  tmp_base="${out_base%.mp4}.partial.mp4"
  # The subtitles filter parses its filename through two levels of
  # filtergraph escaping, which breaks on quotes, colons, commas etc. in real
  # video names. Sidestep it: copy the .srt to a temp dir with a safe name.
  sub_dir="$(mktemp -d "${TMPDIR:-/tmp}/burn_sub.XXXXXX")"
  cp "$srt" "$sub_dir/sub.srt"

  echo "  burning: $video_base (h264_videotoolbox, quality $QUALITY)"
  "$FFMPEG_BIN" -nostdin -hide_banner -loglevel warning -stats -y \
    -i "$video" \
    -vf "subtitles=filename=$sub_dir/sub.srt,format=yuv420p" \
    -c:v h264_videotoolbox -q:v "$QUALITY" -tag:v avc1 \
    -c:a copy -movflags +faststart \
    "$out_dir/$tmp_base"
  status=$?
  rm -rf "$sub_dir"
  if [[ $status -eq 0 ]]; then
    mv -f "$out_dir/$tmp_base" "$out"
    return 0
  fi
  rm -f "$out_dir/$tmp_base"
  echo "  FAILED: ffmpeg exited with an error"
  return 4
}

BUILT=0
DONE=0
NOT_READY=0
MISSING=0
FAILED=0

tally() {
  case $1 in
    0) BUILT=$((BUILT + 1)) ;;
    1) DONE=$((DONE + 1)) ;;
    2) MISSING=$((MISSING + 1)) ;;
    3) NOT_READY=$((NOT_READY + 1)) ;;
    *) FAILED=$((FAILED + 1)) ;;
  esac
}

# Burn one folder: its first .srt, or every .srt (sorted) in group mode.
# Each result is tallied into the counters above.
process_dir() {
  local dir="$1"

  if [[ ! -d "$dir" ]]; then
    echo "  skip: folder not found ($dir)"
    tally 2
    return
  fi

  local srts=() srt
  while IFS= read -r srt; do
    srts+=("$srt")
  done < <(find "$dir" -maxdepth 1 -type f -iname '*.srt' | sort)

  if [[ ${#srts[@]} -eq 0 ]]; then
    echo "  skip: no .srt yet"
    tally 3
    return
  fi

  if [[ $GROUP -eq 0 ]]; then
    srts=("${srts[0]}")
  elif [[ ${#srts[@]} -gt 1 ]]; then
    echo "  group: ${#srts[@]} subtitle files"
  fi

  for srt in "${srts[@]}"; do
    burn_one "$srt"
    tally $?
  done
}

print_summary() {
  local unit="$1"
  echo ""
  echo "== Summary =="
  [[ -n "$unit" ]] && echo "$unit"
  echo "Newly burned:    $BUILT"
  echo "Already burned:  $DONE"
  echo "Not ready (no srt yet): $NOT_READY"
  echo "Missing folder/video:   $MISSING"
  echo "Failed (ffmpeg error):  $FAILED"
}

echo "Using ffmpeg: $FFMPEG_BIN"
[[ $GROUP -eq 1 ]] && echo "Mode: group (every .srt/.mp4 pair in each folder)"

set +e
if [[ "$ARG" == *.json ]]; then
  if [[ ! -f "$ARG" ]]; then
    echo "JSON not found: $ARG" >&2
    exit 1
  fi
  COUNT="$(jq 'length' "$ARG")"
  for ((i = 0; i < COUNT; i++)); do
    FOLDER="$(jq -r ".[$i].FolderName" "$ARG")"
    echo "[$((i + 1))/$COUNT] $FOLDER"
    process_dir "$OUTPUT_DIR/$FOLDER"
  done
  print_summary "Total entries:   $COUNT"
else
  process_dir "$(resolve_dir "$ARG")"
  [[ $GROUP -eq 1 ]] && print_summary ""
fi
set -e

[[ $FAILED -gt 0 ]] && exit 1
exit 0
