#!/bin/bash
# Step 4 (optional): Join every .mp4 in a folder into one long video, with
# one chapter marker per part. Whatever folder you pass is what gets joined —
# originals, burned copies, anything: e.g.
#   ./04_concat.sh w1-d1/sub   -> output/w1-d1/sub/w1-d1.full.mp4
#   ./04_concat.sh w1-d1       -> output/w1-d1/w1-d1.full.mp4
#   ./04_concat.sh w1-d1-concat -> output/w1-d1-concat/w1-d1.full.mp4
#
# Usage:
#   ./04_concat.sh <name>          # one folder under ./output (or absolute path)
#   ./04_concat.sh <data.json>     # batch: every distinct FolderName, under ./output
#
# Parts are joined in file-name order (01, 02, ...). Only that folder's own
# files are used (subfolders are ignored). Output is "<folder-name>.full.mp4"
# inside the folder; for a folder named "sub" the parent's name is used
# instead (w1-d1/sub -> w1-d1.full.mp4). Skips a folder with fewer than 2
# videos, or one that already has its .full.mp4. Output is written to a
# .partial.mp4 and renamed only on success.
#
# Parts with identical codec/resolution/fps/audio are joined with stream
# copy — no re-encode, takes seconds, barely touches the CPU. If they differ
# (e.g. one part is 720p, the rest 1080p), it re-encodes with the hardware
# encoder (h264_videotoolbox), scaling every part to the first part's size;
# that takes about as long as burning subtitles.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <folder|data.json>" >&2
  exit 1
fi

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SELF_DIR/output"
mkdir -p "$OUTPUT_DIR"

QUALITY="${BURN_QUALITY:-40}"

# Prefer Homebrew's ffmpeg-full (same build 03_burn_sub.sh uses), else PATH.
FFMPEG_BIN=""
for p in "${FFMPEG:-}" /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg \
  /usr/local/opt/ffmpeg-full/bin/ffmpeg "$(command -v ffmpeg || true)"; do
  if [[ -n "$p" && -x "$p" ]]; then
    FFMPEG_BIN="$p"
    break
  fi
done
if [[ -z "$FFMPEG_BIN" ]]; then
  echo "ffmpeg not found (brew install ffmpeg-full)" >&2
  exit 1
fi
FFPROBE_BIN="$(dirname "$FFMPEG_BIN")/ffprobe"
[[ -x "$FFPROBE_BIN" ]] || FFPROBE_BIN="$(command -v ffprobe || true)"
if [[ -z "$FFPROBE_BIN" ]]; then
  echo "ffprobe not found next to $FFMPEG_BIN or on PATH" >&2
  exit 1
fi

resolve_dir() {
  if [[ "$1" == /* ]]; then
    printf '%s' "$1"
  else
    printf '%s' "$OUTPUT_DIR/$1"
  fi
}

# One line describing everything that must match for a stream-copy join.
stream_signature() {
  local v a
  v="$("$FFPROBE_BIN" -v error -select_streams v:0 \
    -show_entries stream=codec_name,profile,width,height,pix_fmt,r_frame_rate,time_base \
    -of csv=p=0 "$1")"
  a="$("$FFPROBE_BIN" -v error -select_streams a:0 \
    -show_entries stream=codec_name,profile,sample_rate,channels \
    -of csv=p=0 "$1")"
  printf '%s|%s' "$v" "$a"
}

has_audio() {
  [[ -n "$("$FFPROBE_BIN" -v error -select_streams a:0 \
    -show_entries stream=index -of csv=p=0 "$1")" ]]
}

duration_ms() {
  "$FFPROBE_BIN" -v error -show_entries format=duration -of csv=p=0 "$1" |
    awk '{ printf "%d", $1 * 1000 }'
}

# Returns: 0 joined, 1 already joined, 2 missing folder / too few parts,
#          4 ffmpeg failed.
process_one() {
  local dir="$1"

  if [[ ! -d "$dir" ]]; then
    echo "  skip: folder not found ($dir)"
    return 2
  fi

  local dir_abs name out tmp
  dir_abs="$(cd "$dir" && pwd)"
  name="$(basename "$dir_abs")"
  # A "sub" folder is named after its parent: w1-d1/sub -> w1-d1.full.mp4
  [[ "$name" == "sub" ]] && name="$(basename "$(dirname "$dir_abs")")"
  # A "<prefix>-concat" folder (from 03b_collect_sub.sh) drops the suffix:
  # w1-d1-concat -> w1-d1.full.mp4
  name="${name%-concat}"
  out="$dir_abs/$name.full.mp4"
  tmp="$dir_abs/$name.full.partial.mp4"

  if [[ -f "$out" ]]; then
    echo "  skip: already joined ($(basename "$out"))"
    return 1
  fi

  # Every .mp4 directly in the folder, except this script's own outputs.
  local parts=() f
  while IFS= read -r f; do
    parts+=("$f")
  done < <(find "$dir_abs" -maxdepth 1 -type f -iname '*.mp4' \
    ! -iname '*.partial.mp4' ! -iname '*.full.mp4' | sort)

  if [[ ${#parts[@]} -lt 2 ]]; then
    echo "  skip: fewer than 2 videos in folder (nothing to join)"
    return 2
  fi

  local work
  work="$(mktemp -d "${TMPDIR:-/tmp}/concat.XXXXXX")"

  # Chapter markers: one per part, titled by its file name ("01", "02", ...).
  local meta="$work/chapters.txt" start=0 dur part title
  echo ";FFMETADATA1" >"$meta"
  echo "title=$name" >>"$meta"
  for part in "${parts[@]}"; do
    dur="$(duration_ms "$part")"
    {
      echo "[CHAPTER]"
      echo "TIMEBASE=1/1000"
      echo "START=$start"
      echo "END=$((start + dur))"
      title="$(basename "$part")"
      title="${title%.mp4}"
      title="${title%.sub}"
      echo "title=$title"
    } >>"$meta"
    start=$((start + dur))
  done

  # Same format everywhere -> stream copy; otherwise re-encode.
  local first_sig sig same=1
  first_sig="$(stream_signature "${parts[0]}")"
  for part in "${parts[@]:1}"; do
    sig="$(stream_signature "$part")"
    if [[ "$sig" != "$first_sig" ]]; then
      same=0
      echo "  note: $(basename "$part") differs from $(basename "${parts[0]}"), re-encoding"
      break
    fi
  done

  # (errexit is already off: the caller runs process_one under `set +e`.)
  local status
  if [[ $same -eq 1 ]]; then
    local list="$work/list.txt" q="'\\''"
    : >"$list"
    for part in "${parts[@]}"; do
      echo "file '${part//\'/$q}'" >>"$list"
    done
    echo "  joining ${#parts[@]} parts (stream copy, no re-encode)"
    "$FFMPEG_BIN" -nostdin -hide_banner -loglevel warning -stats -y \
      -f concat -safe 0 -i "$list" -i "$meta" \
      -map 0 -map_metadata 1 -map_chapters 1 -c copy -movflags +faststart \
      "$tmp"
    status=$?
  else
    local inputs=() filter="" n=${#parts[@]} i w h fps
    for part in "${parts[@]}"; do
      if ! has_audio "$part"; then
        echo "  FAILED: $(basename "$part") has no audio track; can't re-encode-join"
        rm -rf "$work"
        return 4
      fi
      inputs+=(-i "$part")
    done
    IFS=, read -r w h fps < <("$FFPROBE_BIN" -v error -select_streams v:0 \
      -show_entries stream=width,height,r_frame_rate -of csv=p=0 "${parts[0]}")
    for ((i = 0; i < n; i++)); do
      filter+="[$i:v:0]scale=$w:$h:force_original_aspect_ratio=decrease,"
      filter+="pad=$w:$h:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=$fps,format=yuv420p[v$i];"
      filter+="[$i:a:0]aresample=48000,aformat=channel_layouts=stereo[a$i];"
    done
    for ((i = 0; i < n; i++)); do
      filter+="[v$i][a$i]"
    done
    filter+="concat=n=$n:v=1:a=1[v][a]"
    echo "  joining ${#parts[@]} parts (re-encode, h264_videotoolbox quality $QUALITY)"
    "$FFMPEG_BIN" -nostdin -hide_banner -loglevel warning -stats -y \
      "${inputs[@]}" -i "$meta" \
      -filter_complex "$filter" -map "[v]" -map "[a]" \
      -map_metadata "$n" -map_chapters "$n" \
      -c:v h264_videotoolbox -q:v "$QUALITY" -tag:v avc1 \
      -c:a aac -b:a 160k -movflags +faststart \
      "$tmp"
    status=$?
  fi
  rm -rf "$work"

  if [[ $status -eq 0 ]]; then
    mv -f "$tmp" "$out"
    echo "  done: $(basename "$out")"
    return 0
  fi
  rm -f "$tmp"
  echo "  FAILED: ffmpeg exited with an error"
  return 4
}

ARG="$1"
JOINED=0
DONE=0
SKIPPED=0
FAILED=0
tally() {
  case $1 in
    0) JOINED=$((JOINED + 1)) ;;
    1) DONE=$((DONE + 1)) ;;
    2) SKIPPED=$((SKIPPED + 1)) ;;
    *) FAILED=$((FAILED + 1)) ;;
  esac
}

set +e
if [[ "$ARG" == *.json ]]; then
  if [[ ! -f "$ARG" ]]; then
    echo "JSON not found: $ARG" >&2
    exit 1
  fi
  COUNT="$(jq 'length' "$ARG")"
  # Several entries can share one folder (after group-by-prefix): visit each
  # distinct folder once, in first-seen order.
  SEEN=$'\n'
  for ((i = 0; i < COUNT; i++)); do
    FOLDER="$(jq -r ".[$i].FolderName" "$ARG")"
    [[ "$SEEN" == *$'\n'"$FOLDER"$'\n'* ]] && continue
    SEEN+="$FOLDER"$'\n'
    echo "[$((i + 1))/$COUNT] $FOLDER"
    process_one "$OUTPUT_DIR/$FOLDER"
    tally $?
  done
  echo ""
  echo "== Summary =="
  echo "Newly joined:    $JOINED"
  echo "Already joined:  $DONE"
  echo "Skipped (missing / <2 videos):    $SKIPPED"
  echo "Failed (ffmpeg error):            $FAILED"
else
  process_one "$(resolve_dir "$ARG")"
  tally $?
fi
set -e

[[ $FAILED -gt 0 ]] && exit 1
exit 0
