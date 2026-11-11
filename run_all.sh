#!/bin/bash
# Run the whole pipeline for one data.json, start to finish:
#
#   download  00_download.sh            data.json
#   transcribe 01_transcribe_chunk.sh   data.json
#   translate  claude -p "/translate-chunks-vi <folder>"   (one call per folder)
#   srt       02_build_srt.sh           data.json
#   burn      03_burn_sub.sh            data.json
#   collect   03b_collect_sub.sh        data.json '<regex>'   (only with --prefix)
#   concat    04_concat.sh              <group>-concat         (only with --concat,
#                                                             asks before running)
#
# Usage:
#   ./run_all.sh <data.json> [--prefix '<regex>'] [--concat] [--from <step>]
#
#   --prefix '<regex>'  after burning, collect each prefix group's burned
#                       videos into output/<prefix>-concat/01.mp4, 02.mp4, ...
#                       e.g. --prefix '^w\d+-d\d+'
#   --concat            then join each <prefix>-concat folder into one video
#                       (needs --prefix). Stops and asks for confirmation
#                       first; skipped when there is no terminal to ask on.
#   --from <step>       start at this step (download, transcribe, translate,
#                       srt, burn, collect, concat) — earlier ones are skipped.
#
# Every step is idempotent, so after an interruption just run the same
# command again. A failing entry never aborts the batch: it is recorded in
# output/<json-basename>.errors.json and later steps skip that folder.
#
# Env: CLAUDE_BIN (default: claude), TRANSLATE_MODEL (optional --model for
# the translation calls), plus whatever the individual steps read
# (BURN_QUALITY, FFMPEG, ...).
set -uo pipefail

usage() {
  echo "Usage: $0 <data.json> [--prefix '<regex>'] [--concat] [--from <step>]" >&2
  exit 1
}

STEPS=(download transcribe translate srt burn collect concat)
JSON=""
PREFIX=""
CONCAT=0
FROM="download"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) [[ $# -ge 2 ]] || usage; PREFIX="$2"; shift 2 ;;
    --concat) CONCAT=1; shift ;;
    --from) [[ $# -ge 2 ]] || usage; FROM="$2"; shift 2 ;;
    -*) usage ;;
    *) [[ -z "$JSON" ]] || usage; JSON="$1"; shift ;;
  esac
done
[[ -n "$JSON" ]] || usage
[[ -f "$JSON" ]] || { echo "JSON not found: $JSON" >&2; exit 1; }
JSON="$(cd "$(dirname "$JSON")" && pwd)/$(basename "$JSON")"
if [[ $CONCAT -eq 1 && -z "$PREFIX" ]]; then
  echo "--concat needs --prefix '<regex>' (it joins the <prefix>-concat folders)" >&2
  exit 1
fi

FROM_IDX=-1
for i in "${!STEPS[@]}"; do
  [[ "${STEPS[$i]}" == "$FROM" ]] && FROM_IDX=$i
done
if [[ $FROM_IDX -lt 0 ]]; then
  echo "Unknown --from step: $FROM (one of: ${STEPS[*]})" >&2
  exit 1
fi

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SELF_DIR/output"
ERROR_FILE="$OUTPUT_DIR/$(basename "$JSON" .json).errors.json"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
mkdir -p "$OUTPUT_DIR"
cd "$SELF_DIR" || exit 1

# should_run <step>: true if <step> is at or after --from.
should_run() {
  local i
  for i in "${!STEPS[@]}"; do
    [[ "${STEPS[$i]}" == "$1" ]] && { [[ $i -ge $FROM_IDX ]]; return; }
  done
  return 1
}

STEP_WARNINGS=()
banner() {
  echo ""
  echo "================================================================"
  echo "== $1"
  echo "================================================================"
}
# run_step <label> <cmd...>: run a step script; a non-zero exit is noted
# (the step already reported which entries failed) but never stops the run.
run_step() {
  local label="$1"
  shift
  banner "$label"
  "$@"
  local status=$?
  [[ $status -ne 0 ]] && STEP_WARNINGS+=("$label exited with status $status")
  return 0
}

add_error() {  # add_error <entry-index> <step> <message>
  [[ -f "$ERROR_FILE" ]] || echo "[]" >"$ERROR_FILE"
  local entry
  entry="$(jq --arg s "$2" --arg e "$3" ".[$1] + {Step: \$s, Error: \$e}" "$JSON")"
  jq --argjson obj "$entry" '. + [$obj]' "$ERROR_FILE" >"$ERROR_FILE.tmp" &&
    mv "$ERROR_FILE.tmp" "$ERROR_FILE"
}

translate_all() {
  banner "translate (claude -p /translate-chunks-vi, one folder at a time)"
  if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    echo "claude CLI not found (set CLAUDE_BIN) — skipping translation." >&2
    STEP_WARNINGS+=("translate: claude CLI not found")
    return
  fi
  local model_args=()
  [[ -n "${TRANSLATE_MODEL:-}" ]] && model_args=(--model "$TRANSLATE_MODEL")

  local count i folder dir done_n=0 skip_n=0 fail_n=0 want got
  count="$(jq 'length' "$JSON")"
  for ((i = 0; i < count; i++)); do
    folder="$(jq -r ".[$i].FolderName" "$JSON")"
    dir="$OUTPUT_DIR/$folder"
    if [[ ! -f "$dir/chunks.json" || -f "$dir/vi_translations.json" ]] ||
      [[ -n "$(find "$dir" -maxdepth 1 -iname '*.srt' 2>/dev/null | head -n 1)" ]]; then
      skip_n=$((skip_n + 1))
      continue
    fi
    echo "[$((i + 1))/$count] $folder"
    "$CLAUDE_BIN" -p "/translate-chunks-vi $dir" \
      --permission-mode acceptEdits \
      --allowedTools "Read" "Write" "Edit" "Glob" "Grep" "Bash(ls:*)" "Bash(jq:*)" \
      ${model_args[@]+"${model_args[@]}"} </dev/null | tail -n 5

    # Trust the file, not the agent's report: it must exist and line up 1:1
    # with chunks.json, or 02_build_srt.sh would fail on it.
    want="$(jq 'length' "$dir/chunks.json")"
    got="$(jq 'if type == "array" then length else -1 end' "$dir/vi_translations.json" 2>/dev/null || echo -1)"
    if [[ "$got" == "$want" ]]; then
      echo "  ok: $got lines"
      done_n=$((done_n + 1))
    else
      echo "  FAILED: vi_translations.json has ${got/-1/no valid} entries, chunks.json has $want"
      [[ -f "$dir/vi_translations.json" ]] &&
        mv -f "$dir/vi_translations.json" "$dir/vi_translations.invalid.json"
      add_error "$i" "translate" "vi_translations.json missing or $got != $want entries"
      fail_n=$((fail_n + 1))
    fi
  done
  echo ""
  echo "== Summary (translate) =="
  echo "Newly translated: $done_n"
  echo "Skipped (done / not transcribed): $skip_n"
  echo "Failed: $fail_n"
  [[ $fail_n -gt 0 ]] && STEP_WARNINGS+=("translate: $fail_n folder(s) failed")
}

GROUP_DIRS=()
collect() {
  banner "collect burned videos into <prefix>-concat (regex: $PREFIX)"
  local out line status
  out="$("$SELF_DIR/03b_collect_sub.sh" "$JSON" "$PREFIX")"
  status=$?
  while IFS= read -r line; do
    if [[ "$line" == GROUP_DIR$'\t'* ]]; then
      GROUP_DIRS+=("${line#GROUP_DIR$'\t'}")
    else
      echo "$line"
    fi
  done <<<"$out"
  [[ $status -ne 0 ]] && STEP_WARNINGS+=("collect exited with status $status")
}

concat_groups() {
  banner "concat"
  if [[ ${#GROUP_DIRS[@]} -eq 0 ]]; then
    echo "No <prefix>-concat folder to join."
    return
  fi
  local d n
  echo "Will join these folders into one video each:"
  for d in "${GROUP_DIRS[@]}"; do
    n="$(find "$d" -maxdepth 1 -type f -iname '*.mp4' ! -iname '*.full.mp4' ! -iname '*.partial.mp4' | wc -l | tr -d ' ')"
    echo "  $(basename "$d")/  ($n parts: $(cd "$d" && ls ./*.mp4 2>/dev/null | grep -v -e '\.full\.mp4$' -e '\.partial\.mp4$' | sed 's|^\./||' | tr '\n' ' '))"
  done
  echo "(check the collect summary above for missing parts first)"
  if ! { : </dev/tty; } 2>/dev/null; then
    echo "No terminal to confirm on — skipping concat. Run later with:"
    for d in "${GROUP_DIRS[@]}"; do echo "  ./04_concat.sh $(basename "$d")"; done
    return
  fi
  local answer
  read -r -p "Run 04_concat.sh on these now? [y/N] " answer </dev/tty
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    echo "Skipped concat."
    return
  fi
  for d in "${GROUP_DIRS[@]}"; do
    run_step "concat $(basename "$d")" "$SELF_DIR/04_concat.sh" "$d"
  done
}

echo "Data: $JSON"
echo "Steps from: $FROM${PREFIX:+, prefix: $PREFIX}$([[ $CONCAT -eq 1 ]] && echo ', concat: ask')"

should_run download && run_step "download" "$SELF_DIR/00_download.sh" "$JSON"
should_run transcribe && run_step "transcribe" "$SELF_DIR/01_transcribe_chunk.sh" "$JSON"
should_run translate && translate_all
should_run srt && run_step "build srt" "$SELF_DIR/02_build_srt.sh" "$JSON"
should_run burn && run_step "burn subtitles" "$SELF_DIR/03_burn_sub.sh" "$JSON"
if [[ -n "$PREFIX" ]] && should_run collect; then
  collect
elif [[ -n "$PREFIX" ]]; then
  # --from concat: still need the group folder list, collecting is idempotent.
  collect >/dev/null
fi
[[ $CONCAT -eq 1 ]] && should_run concat && concat_groups

banner "done"
if [[ ${#STEP_WARNINGS[@]} -gt 0 ]]; then
  echo "Finished with warnings:"
  printf '  - %s\n' "${STEP_WARNINGS[@]}"
  [[ -f "$ERROR_FILE" ]] && echo "Failed entries: $ERROR_FILE"
  exit 1
fi
echo "All steps finished without errors."
