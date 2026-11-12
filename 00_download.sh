#!/bin/bash
# Step 0: Download video(s) with yt-dlp, run inside Docker — no yt-dlp needs
# to be installed on the host.
#
# Usage:
#   ./00_download.sh <data.json>                  # batch: download every entry's Url into ./output/<FolderName>
#   ./00_download.sh <url> <name> [filename]       # single: download one video by its own URL into ./output/<name>
#
# All downloaded videos live under ./output (inside this tool). <name> may
# also be an absolute path if you need to point at a folder elsewhere.
#
# In batch mode, each entry's FolderName is created under ./output if
# missing. Skips an entry if its folder already contains an .mp4. Failed
# downloads are recorded to "<json-basename>.errors.json" in ./output
# (Step: "download"), and the batch continues with the next entry rather
# than aborting.
#
# In single mode, [filename] sets the output filename (defaults to the
# video's own title from yt-dlp if omitted). Skips if the folder already has
# an .mp4.
#
# Requirement: Docker installed and running. The local-yt-dlp image is
# built automatically on first run via docker-compose (no manual setup).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="local-yt-dlp"
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

# Download with fallbacks. Some sources (e.g. Bilibili) drop the connection
# on the top-quality stream mid-download, while lower-quality streams work.
# Tries best quality first (1080p), then caps at 720p. Leftover partial
# files from a failed attempt are removed before the next one.
# Usage: download_with_fallback <host-dir> <output-template> <url>
# On failure, LAST_ERROR holds yt-dlp's last ERROR line.
LAST_ERROR=""
download_with_fallback() {
  local dir="$1" template="$2" url="$3"
  local log; log="$(mktemp)"
  local formats=(
    ""
    "bv*[height<=720]+ba/b[height<=720]"
  )
  local fmt
  for fmt in "${formats[@]}"; do
    local args=()
    if [[ -n "$fmt" ]]; then
      echo "  retrying with format: $fmt" >&2
      args=(-f "$fmt")
    fi
    # pipefail is on, so a docker failure makes this whole pipeline fail.
    if docker run --rm -v "$dir":/data "$IMAGE" ${args[@]+"${args[@]}"} -o "$template" "$url" 2>&1 | tee "$log"; then
      rm -f "$log"
      return 0
    fi
    LAST_ERROR="$(grep -E '^ERROR' "$log" | tail -n 1)"
    find "$dir" -maxdepth 1 \( -name '*.part' -o -name '*.ytdl' -o -name '*.f[0-9]*.*' \) -delete
  done
  rm -f "$log"
  return 1
}

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found on PATH" >&2
  exit 1
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "Building $IMAGE Docker image (one-time setup)..." >&2
  docker compose -f "$SELF_DIR/docker-compose.yml" build yt-dlp
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <data.json>" >&2
  echo "   or: $0 <url> <folder> [name]" >&2
  exit 1
fi

if [[ "$1" == *.json ]]; then
  JSON="$1"
  if [[ ! -f "$JSON" ]]; then
    echo "JSON not found: $JSON" >&2
    exit 1
  fi

  ERROR_FILE="$OUTPUT_DIR/$(basename "$JSON" .json).errors.json"
  echo "[]" > "$ERROR_FILE"

  COUNT="$(jq 'length' "$JSON")"
  DOWNLOADED=0
  SKIPPED=0
  FAILED=0

  for ((i = 0; i < COUNT; i++)); do
    NAME="$(jq -r ".[$i].Name" "$JSON")"
    FOLDER="$(jq -r ".[$i].FolderName" "$JSON")"
    URL="$(jq -r ".[$i].Url" "$JSON")"
    TARGET_DIR="$OUTPUT_DIR/$FOLDER"
    mkdir -p "$TARGET_DIR"

    echo "[$((i + 1))/$COUNT] $FOLDER"

    if [[ -n "$(find "$TARGET_DIR" -maxdepth 1 -iname '*.mp4' | head -n 1)" ]]; then
      echo "  skip: already has an .mp4"
      ((SKIPPED++))
      continue
    fi

    SAFE_NAME="${NAME//%/%%}"
    echo "  downloading: $NAME"
    if download_with_fallback "$TARGET_DIR" "/data/${SAFE_NAME}.%(ext)s" "$URL"; then
      ((DOWNLOADED++))
    else
      echo "  FAILED: $URL"
      ((FAILED++))
      ENTRY="$(jq --arg err "${LAST_ERROR:-yt-dlp exited non-zero}" ".[$i] + {Step: \"download\", Error: \$err}" "$JSON")"
      jq --argjson obj "$ENTRY" '. + [$obj]' "$ERROR_FILE" > "$ERROR_FILE.tmp" && mv "$ERROR_FILE.tmp" "$ERROR_FILE"
    fi
  done

  echo ""
  echo "== Summary =="
  echo "Total entries:     $COUNT"
  echo "Newly downloaded:  $DOWNLOADED"
  echo "Already had mp4:   $SKIPPED"
  echo "Failed:            $FAILED"
  [[ $FAILED -gt 0 ]] && echo "See $ERROR_FILE for failed entries."

else
  URL="$1"
  FOLDER="${2:-}"
  NAME="${3:-}"

  if [[ -z "$FOLDER" ]]; then
    echo "Usage: $0 <url> <name> [filename]" >&2
    exit 1
  fi

  TARGET_DIR="$(resolve_dir "$FOLDER")"
  mkdir -p "$TARGET_DIR"
  FOLDER_ABS="$(cd "$TARGET_DIR" && pwd)"

  if [[ -n "$(find "$FOLDER_ABS" -maxdepth 1 -iname '*.mp4' | head -n 1)" ]]; then
    echo "skip: folder already has an .mp4 ($FOLDER_ABS)"
    exit 0
  fi

  if [[ -n "$NAME" ]]; then
    SAFE_NAME="${NAME//%/%%}"
    echo "downloading: $NAME -> $FOLDER_ABS"
    download_with_fallback "$FOLDER_ABS" "/data/${SAFE_NAME}.%(ext)s" "$URL"
  else
    echo "downloading (using video's own title) -> $FOLDER_ABS"
    download_with_fallback "$FOLDER_ABS" "/data/%(title)s.%(ext)s" "$URL"
  fi
fi
