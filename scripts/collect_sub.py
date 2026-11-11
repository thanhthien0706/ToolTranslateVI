#!/usr/bin/env python3
"""Step 3b: collect the burned videos (<name>.sub.mp4, from 03_burn_sub.sh)
of every data.json entry into output/<prefix>-concat/<index>.mp4, ready for
04_concat.sh.

Usage: collect_sub.py <data.json> '<regex>'

- <regex> is matched at the START of each entry's FolderName; the matched
  text is the group name, so the target folder is output/<group>-concat/.
- <index> is the number right after the prefix (same rule as
  group_by_prefix.py), leading zeros kept: w1-d1-02-foo -> 02.mp4.
- Files are hard-linked (no extra disk space, source folders untouched, so
  steps 00-03 still see their work as done); falls back to a copy if a hard
  link isn't possible.
- Never overwrites: an existing target that is the same file is skipped,
  a different one is reported as an error and left alone.
- Entries without a burned video yet are reported as missing, so the user
  sees that the -concat folder is incomplete before running step 4.

Errors are appended (Step: "collect") to output/<json-basename>.errors.json.
Prints one line per created group folder as "GROUP_DIR\t<path>" at the end,
for run_all.sh to pick up.
"""
import json
import os
import re
import shutil
import sys
from pathlib import Path

OUTPUT_DIR = Path(__file__).resolve().parent.parent / "output"


def find_burned(folder: Path):
    """The burned copy 03_burn_sub.sh produced in normal mode."""
    hits = sorted(p for p in folder.glob("*.sub.mp4") if p.is_file())
    return hits[0] if hits else None


def main():
    if len(sys.argv) != 3:
        print("Usage: collect_sub.py <data.json> '<regex>'", file=sys.stderr)
        sys.exit(1)
    json_path = Path(sys.argv[1])
    try:
        pattern = re.compile(sys.argv[2])
    except re.error as e:
        print(f"Invalid regex: {e}", file=sys.stderr)
        sys.exit(1)
    try:
        entries = json.loads(json_path.read_text())
    except (OSError, json.JSONDecodeError) as e:
        print(f"Cannot read {json_path}: {e}", file=sys.stderr)
        sys.exit(1)

    error_file = OUTPUT_DIR / f"{json_path.stem}.errors.json"
    errors = []

    def add_error(entry, msg):
        errors.append({**entry, "Step": "collect", "Error": msg})
        print(f"  ERROR: {msg}")

    # group -> {index: (entry, folder)}
    groups = {}
    not_matched = 0
    for entry in entries:
        name = entry.get("FolderName", "")
        m = pattern.match(name)
        if not m or not m.group(0):
            not_matched += 1
            continue
        prefix = m.group(0)
        idx = re.match(r"^[-_.\s]*(\d+)", name[len(prefix):])
        if not idx:
            add_error(entry, f"{name}: no index number right after prefix {prefix!r}")
            continue
        by_index = groups.setdefault(prefix, {})
        if idx.group(1) in by_index:
            add_error(entry, f"{name}: duplicate index {idx.group(1)} in group "
                             f"{prefix!r} (also {by_index[idx.group(1)][0]['FolderName']})")
            continue
        by_index[idx.group(1)] = (entry, OUTPUT_DIR / name)

    linked = done = missing = failed = 0
    group_dirs = []
    for prefix, by_index in groups.items():
        target_dir = OUTPUT_DIR / f"{prefix}-concat"
        print(f"[{prefix}] -> output/{target_dir.name}/ ({len(by_index)} entries)")
        for index in sorted(by_index, key=int):
            entry, folder = by_index[index]
            src = find_burned(folder) if folder.is_dir() else None
            if src is None:
                print(f"  missing: {index} ({folder.name}) has no .sub.mp4 yet")
                missing += 1
                continue
            target = target_dir / f"{index}.mp4"
            if target.exists():
                if os.path.samefile(src, target) or target.stat().st_size == src.stat().st_size:
                    done += 1
                    continue
                add_error(entry, f"{target_dir.name}/{target.name} already exists "
                                 f"and differs from {src.name}; left as-is")
                failed += 1
                continue
            target_dir.mkdir(parents=True, exist_ok=True)
            try:
                try:
                    os.link(src, target)
                except OSError:
                    shutil.copy2(src, target)
                print(f"  added: {index}.mp4 <- {folder.name}/{src.name}")
                linked += 1
            except OSError as e:
                add_error(entry, f"cannot place {src.name} as {target.name}: {e}")
                failed += 1
        if target_dir.is_dir():
            group_dirs.append(target_dir)

    if errors:
        existing = []
        if error_file.exists():
            try:
                existing = json.loads(error_file.read_text())
            except json.JSONDecodeError:
                existing = []
        existing = [e for e in existing if e.get("Step") != "collect"] + errors
        error_file.write_text(json.dumps(existing, indent=2, ensure_ascii=False) + "\n")

    print("")
    print("== Summary (collect) ==")
    print(f"Groups:                  {len(groups)}")
    print(f"Newly added:             {linked}")
    print(f"Already in -concat:      {done}")
    print(f"Missing (not burned yet):{missing:>3}")
    print(f"Errors:                  {len(errors)}")
    print(f"Entries not matching regex: {not_matched}")
    if errors:
        print(f"See {error_file} for details.")
    for d in group_dirs:
        print(f"GROUP_DIR\t{d}")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
