---
name: video-sub-pipeline
description: Use when the user gives the path to the course JSON data file (e.g. data-AI-Coder.json) and asks to download the videos and/or generate Vietnamese subtitles for them. Downloads any missing mp4 per entry (Name/FolderName/Url) via yt-dlp, then transcribes with mlx-whisper, translates to natural Vietnamese, and writes a matching .srt next to each mp4. Idempotent — skips videos/subs that already exist, safe to re-run after interruption.
---

# Video → Vietnamese Subtitle Pipeline

Turns a JSON list of `{Name, FolderName, Url}` into, for every entry:
`<BASE_DIR>/<FolderName>/<Name>.mp4` + `<BASE_DIR>/<FolderName>/<Name>.srt`

Input: a path to a JSON file shaped like:
```json
[{"Name": "...", "FolderName": "w1-d2-04-...", "Url": "https://..."}]
```
`BASE_DIR` is the directory containing that JSON file.

## Prerequisites (check once per session, don't re-check per video)

- `ffmpeg`, `ffprobe`, `yt-dlp` on PATH.
- A venv with `mlx-whisper` installed. Look for `.venv-whisper` in `BASE_DIR` first; if missing, create it:
  ```
  python3 -m venv BASE_DIR/.venv-whisper
  source BASE_DIR/.venv-whisper/bin/activate
  pip install -q --upgrade pip
  pip install -q mlx-whisper
  ```
- The three helper scripts live next to this SKILL.md, in `scripts/`:
  `transcribe.py`, `make_chunks.py`, `build_srt.py`. Run them with the venv's python, e.g.:
  `BASE_DIR/.venv-whisper/bin/python3 <skill_dir>/scripts/transcribe.py ...`

## Error tracking

`ERROR_FILE = BASE_DIR/<json-basename-without-ext>.errors.json` (e.g. for `data-AI-Coder.json` it's `BASE_DIR/data-AI-Coder.errors.json`). Same convention as `download_all.sh`.

At the **start of the run**, reset it to an empty array: `echo "[]" > ERROR_FILE`.

Whenever an entry fails at step 1 or step 2 below, append the original JSON object plus `Step` (`"download"` or `"subtitle"`) and `Error` (short reason) to that array, then continue to the next entry — never abort the whole batch over one failure:
```
jq --argjson obj '<original-object-with-Step-and-Error-fields>' '. + [$obj]' ERROR_FILE > ERROR_FILE.tmp && mv ERROR_FILE.tmp ERROR_FILE
```

## Procedure

Parse the JSON (python/jq), then loop over every entry **in order**. For each entry do steps 1–2. Keep a running count (downloaded / transcribed / skipped / failed) and print it as you go — this can be a long batch job, the user needs visible progress.

### Step 1 — Download (skip if already present)

`target_dir = BASE_DIR/FolderName`, create if missing.

If `target_dir` already contains any `*.mp4`, skip downloading (treat the existing file as the video for this entry, whatever its exact name — don't re-download or rename it).

Otherwise download with the filename coming from `Name`, not yt-dlp's own title and not prefixed with FolderName:
```
yt-dlp -o "target_dir/${safe_name}.%(ext)s" "$url"
```
where `safe_name` is `Name` with any literal `%` escaped to `%%` (yt-dlp output-template escaping). If yt-dlp exits non-zero (bad URL, network, region-locked, etc.), append the entry to `ERROR_FILE` with `Step: "download"` and a short `Error` message, then continue to the next entry.

### Step 2 — Subtitle (skip if already present)

Let `video = the mp4 found/downloaded in target_dir` and `srt = same path with .srt extension`.

If `srt` already exists, skip (already done).

Otherwise, run the pipeline for this one video:

1. **Transcribe** (slowest step — a 10-20 min video takes a few minutes on Apple Silicon with the `medium` model):
   ```
   <venv-python> scripts/transcribe.py "<video>" "<target_dir>/transcript.json"
   ```
2. **Chunk** into short, naturally-broken cues (≤ ~11 words, ≤ ~6.5s, breaking at punctuation/conjunctions — this is what keeps subtitle lines from overflowing in CapCut/Premiere):
   ```
   <venv-python> scripts/make_chunks.py "<target_dir>/transcript.json" "<target_dir>/chunks.json"
   ```
3. **Translate to Vietnamese** — read `chunks.json`, and for the `text` field of every chunk (in order), produce a natural, spoken-register Vietnamese translation. This step is done by you (the agent), not a script — there is no local MT model installed. Rules:
   - Keep file names, tool/product names, and tech acronyms in English as-is: `agents.md`, `Claude.md`, `Gemini.md`, `README`, `Markdown`, `LLM`, `AI`, `API`, `MCP`, `PR`, `UV`, `Python`, `HTML`, `H1/H2/H3`, `Q&A`, names of tools (`Claude Code`, `Cursor`, `Codex`, `GitHub Copilot`, `Antigravity`, `OpenRouter`, `Docker`, `FastAPI`, `Next.js`, etc).
   - Translate everything else into natural conversational Vietnamese — don't translate word-for-word; read a few chunks of surrounding context so pronouns/continuations make sense across cue boundaries.
   - Fix obvious ASR mis-hearings using context (e.g. a mis-transcribed tool name) rather than translating the garbled word literally.
   - Output a **plain JSON array of strings**, same length and same order as `chunks.json`, to `<target_dir>/vi_translations.json`.
4. **Build the final SRT**:
   ```
   <venv-python> scripts/build_srt.py "<target_dir>/chunks.json" "<target_dir>/vi_translations.json" "<srt>"
   ```
   The script hard-fails if the translation count doesn't match the chunk count — if that happens, fix `vi_translations.json` and re-run this step only.
5. **Cleanup**: delete `transcript.json`, `chunks.json`, `vi_translations.json` from `target_dir` — only the `.mp4` and `.srt` should remain as the final artifacts.

If any of steps 1–4 fails (script error, mismatched counts that can't be fixed, etc.), append the entry to `ERROR_FILE` with `Step: "subtitle"` and a short `Error` message, leave any partial intermediate files in place for debugging, and move on to the next entry.

### Step 3 — Summary

After the loop, report: total entries, how many videos were downloaded this run vs already present, how many subtitles were generated this run vs already present, and `jq length ERROR_FILE` failures. If `ERROR_FILE` is non-empty, point the user at it and offer to retry just those entries (filter the original JSON down to the objects listed in `ERROR_FILE` and re-run the loop over that subset).

## Notes

- This is designed to be safely re-run on the same JSON after a partial run (crash, interrupt, or a deliberate "do the rest later") — step 1 and step 2 both skip work that's already done.
- Don't parallelize transcription across multiple videos — `mlx-whisper` already uses the GPU/ANE fully for one job; running several at once will just thrash and slow everything down. Process entries one at a time.
- If the user only wants a subset (e.g. "just the next 5" or one specific FolderName), filter the parsed JSON before the loop instead of touching the scripts.
