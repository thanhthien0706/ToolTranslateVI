# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A self-contained CLI pipeline that takes a JSON list of `{Name, FolderName, Url}`
course-video entries, downloads each video, transcribes it, translates the
transcript to natural Vietnamese, and produces a hard-subbed `.mp4`. The tool
is meant to be copied wholesale to another machine and just work — all state
(videos, subtitles, venv) lives inside this folder under `output/` and
`.venv-whisper/`, never outside it. The input JSON itself may live anywhere.

Read `README.md` (Vietnamese) first — it's the authoritative spec for the
pipeline's behavior, idempotency rules, and the "self-contained" guarantees.
Anything below summarizes it for quick orientation; README.md wins on conflict.

## Pipeline architecture

4 independent shell scripts (numbered `00_`–`03_`) plus one step done by
Claude directly (no script — no local translation model exists):

```
00_download.sh  → 01_transcribe_chunk.sh → [Claude translates] → 02_build_srt.sh → 03_burn_sub.sh
   (yt-dlp,          (mlx-whisper,              chunks.json →         (merge +         (ffmpeg,
    Docker)           native venv)              vi_translations.json   cleanup)         Docker)
```

Each script accepts either a single folder name/absolute path, or a `.json`
data file (batch mode, driven by `jq`, one folder per `FolderName` entry).
All four are idempotent — re-running on the same input skips completed work;
this is load-bearing for resuming interrupted batches, so don't "simplify"
away the skip checks.

Per-video folder under `output/<FolderName>/`, files appear/disappear in this
order as the pipeline progresses: `<name>.mp4` → `transcript.json` +
`chunks.json` (step 1) → `vi_translations.json` (Claude) → `<name>.srt` (step
2 deletes the three intermediate JSON files) → `<name>.sub.mp4` (step 3,
original `.mp4` is never modified).

Batch failures (step 0) are recorded to `output/<json-basename>.errors.json`
with `Step`/`Error` fields added to the original entry — the batch continues
past individual failures rather than aborting.

### Why Docker for steps 0 and 3, native venv for step 1

- Step 0 (`00_download.sh`) and step 3 (`03_burn_sub.sh`) run inside Docker
  (`docker-compose.yml` + `docker/yt-dlp.Dockerfile`, and
  `jrottenberg/ffmpeg:6-ubuntu` for burn-in, which has `libass`/`subtitles`
  filter support that Homebrew ffmpeg lacks). Images build/pull automatically
  on first run.
- Step 1 (`01_transcribe_chunk.sh`) **cannot** run in Docker: `mlx-whisper`
  needs Metal GPU access, which Docker's Linux VM on Mac can't provide. It
  must run natively on Apple Silicon, and auto-bootstraps its own venv at
  `./.venv-whisper` on first run (gitignored). This is the one hard
  environment requirement the tool can't paper over — see README.md
  "Mức độ độc lập" for the full constraint and the workaround (transcribe on
  an Apple Silicon machine, copy `chunks.json` elsewhere, if the target
  machine isn't one).
- Step 2 (`02_build_srt.sh`) is pure stdlib `python3`, no dependencies.

### The translation step is deliberately not a script

There is no local MT model. The "Bước giữa" (middle step) between 01 and 02
is done by an agent reading `chunks.json` (array of `{start, end, text}`) and
writing `vi_translations.json` (plain array of strings, same length/order) —
invoked via the `translate-chunks-vi` skill (`.claude/skills/translate-chunks-vi/`).
Translation rules (keep English tool/product/file names as-is, translate the
rest naturally, fix obvious ASR mis-hearings from context) are spelled out in
that skill file and in `video-sub-pipeline` — both already encode the rules,
don't restate ad hoc ones that drift from them. `02_build_srt.sh` hard-fails
if `chunks.json` and `vi_translations.json` lengths mismatch.

### `scripts/` (Python helpers, called by the shell scripts, not run directly)

- `transcribe.py` — runs `mlx_whisper.transcribe` (model
  `mlx-community/whisper-medium`, English, word-level timestamps) → JSON.
- `make_chunks.py` — splits word-timestamped transcript into short subtitle
  cues: sentence-boundary split, then re-split any sentence over ~11 words or
  ~6.5s at punctuation/conjunction boundaries, then merges any trailing
  ≤2-word fragment into the previous cue. Tune `MAX_WORDS`/`MAX_DUR`/
  `BREAK_CONJ` here if subtitle pacing needs adjusting.
- `build_srt.py` — zips `chunks.json` timings with translated strings into
  standard `.srt` timecodes; exits non-zero on count mismatch.

## Running the pipeline

```bash
./00_download.sh "<data.json>"            # or: ./00_download.sh "<url>" "<folder>" ["<filename>"]
./01_transcribe_chunk.sh "<data.json>"     # or: ./01_transcribe_chunk.sh "<folder-name>"
# then: /translate-chunks-vi  [optional: folder name or data.json to scope it]
./02_build_srt.sh "<data.json>"
./03_burn_sub.sh "<data.json>"
```

Single-video mode takes a bare folder name (resolved under `./output/`) or an
absolute path (used as-is, for output living outside this tool). There is no
build/lint/test suite in this repo — verification is running a step and
checking its skip/summary counts, or inspecting the resulting file in
`output/<folder>/`.

`run_build_srt_all.sh` is a convenience wrapper that loops `02_build_srt.sh`
over every subfolder of its own directory (hardcodes the path to this tool's
`02_build_srt.sh` — it's meant to be dropped into some other
already-downloaded video directory, not run from inside this repo).

## Requirements on the host

`jq`, Docker (running), `python3`. Apple Silicon + host `ffmpeg` on PATH only
for step 1 (mlx-whisper's own audio decode — unrelated to the Dockerized
ffmpeg used for burn-in). Never run transcription or burn-in concurrently
across multiple videos — both saturate the Mac's GPU/ANE or make everything
slower; the batch loops are intentionally sequential.

## Data files

`data/*.json` (per-week course entries, e.g. `w1-d1.json`) are the typical
input files for this pipeline, but the `data/` directory itself is gitignored
(along with `output/`, `.venv-whisper/`, `*.errors.json`) — treat its
contents as local working data, not tracked source.
