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
    Docker)           native venv)              vi_translations.json   cleanup)         native)
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
original `.mp4` is never modified). Optional step 4 (`04_concat.sh <folder>`) joins every `.mp4` directly in
the given folder (originals or burned copies — whatever is there; subfolders
ignored) into `<folder>/<folder-name>.full.mp4` with one chapter per part; a
folder named `sub` takes its parent's name (`w1-d1/sub` → `w1-d1.full.mp4`).
Stream copy when all parts share a format, VideoToolbox re-encode otherwise.
A `<x>-concat` folder drops the suffix (`w1-d1-concat` → `w1-d1.full.mp4`).

Optional step 3b (`03b_collect_sub.sh <data.json> '<regex>'`, logic in
`scripts/collect_sub.py`) hard-links each entry's `<name>.sub.mp4` into
`output/<prefix>-concat/<NN>.mp4` (prefix = regex match at the start of
`FolderName`, `NN` = number right after it, same rule as `group_by_prefix.py`)
so step 4 has a folder of only burned videos. Source folders stay untouched,
never overwrites, unburned entries are reported as missing.

`run_all.sh <data.json> [--prefix '<regex>'] [--concat] [--from <step>]`
chains every step for one JSON. Translation is done there by
`claude -p "/translate-chunks-vi <folder>"`, one headless call per folder,
restricted to file tools. The result is length-checked against `chunks.json`,
and a bad file is renamed to `vi_translations.invalid.json` and logged with
`Step: "translate"`. `--concat` always stops for a `[y/N]` on `/dev/tty`
before step 4, and skips it when there is no terminal. Keep it that way:
the user asked for that confirmation.

Batch failures (step 0) are recorded to `output/<json-basename>.errors.json`
with `Step`/`Error` fields added to the original entry — the batch continues
past individual failures rather than aborting.

### Why Docker for step 0, native for steps 1 and 3

- Step 0 (`00_download.sh`) runs inside Docker (`docker-compose.yml` +
  `docker/yt-dlp.Dockerfile`); the image builds automatically on first run.
- Step 3 (`03_burn_sub.sh`) runs ffmpeg natively and encodes with Apple's
  hardware encoder (`h264_videotoolbox`) at constant quality `-q:v 40`
  (`BURN_QUALITY` env overrides). Hardware encoding is less efficient than
  x264, so outputs of low-bitrate screen recordings run ~2–3x the source size. It used to run in Docker (`jrottenberg/ffmpeg`), but that
  image is amd64-only, so on Apple Silicon it ran under emulation with
  CPU-only libx264 — slow and hot. It needs an ffmpeg with `libass` (the
  `subtitles` filter), which the regular Homebrew `ffmpeg` lacks: install
  keg-only `ffmpeg-full` (`brew install ffmpeg-full`), which does not
  replace the regular ffmpeg. The script picks `$FFMPEG`, then
  `ffmpeg-full`, then PATH ffmpeg, whichever has `subtitles`. Output goes to
  `<name>.sub.partial.mp4` and is renamed only on success, so an
  interrupted burn is redone rather than wrongly skipped. By default only
  the first `.srt` per folder is burned; pass `--group`
  (`./03_burn_sub.sh --group <folder|data.json>`, or with `--group` last) to burn every
  `<x>.srt`/`<x>.mp4` pair in the folder (folders produced by the
  `group-by-prefix` skill hold many videos). Skips are then per video, and
  burned videos go to `<folder>/sub/<x>.mp4` instead of `<x>.sub.mp4`; a
  legacy `<x>.sub.mp4` found in group mode is moved into `sub/` rather than
  re-burned. A hand-moved `sub/<x>.sub.mp4` also counts as burned.
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
./03b_collect_sub.sh "<data.json>" '<regex>'  # optional: burned videos -> output/<prefix>-concat/
./04_concat.sh "<folder|data.json>"      # optional: join every .mp4 in that folder (e.g. w1-d1-concat)

# or all of the above in one go:
./run_all.sh "<data.json>" --prefix '^w\d+-d\d+' --concat
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

`jq`, Docker (running, step 0 only), `python3`. Apple Silicon + host
`ffmpeg` on PATH for step 1 (mlx-whisper's own audio decode). Homebrew
`ffmpeg-full` (has libass) on macOS for step 3. Never run transcription or burn-in concurrently
across multiple videos — both saturate the Mac's GPU/ANE or make everything
slower; the batch loops are intentionally sequential.

## Data files

`data/*.json` (per-week course entries, e.g. `w1-d1.json`) are the typical
input files for this pipeline, but the `data/` directory itself is gitignored
(along with `output/`, `.venv-whisper/`, `*.errors.json`) — treat its
contents as local working data, not tracked source.
