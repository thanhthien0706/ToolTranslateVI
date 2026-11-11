#!/usr/bin/env python3
"""Group output/<folder> entries sharing a regex-matched prefix into
output/<prefix>/, renumbering each source folder's files as <index>.<ext>.

Usage: group_by_prefix.py '<regex>'
"""
import json
import re
import shutil
import sys
from pathlib import Path

OUTPUT_DIR = Path(__file__).resolve().parent.parent / "output"
ERROR_FILE = OUTPUT_DIR / "group-by-prefix.errors.json"


def main():
    if len(sys.argv) != 2:
        print("Usage: group_by_prefix.py '<regex>'", file=sys.stderr)
        sys.exit(1)

    try:
        pattern = re.compile(sys.argv[1])
    except re.error as e:
        print(f"Invalid regex: {e}", file=sys.stderr)
        sys.exit(1)

    if not OUTPUT_DIR.is_dir():
        print(f"No output/ directory at {OUTPUT_DIR}", file=sys.stderr)
        sys.exit(1)

    errors = []

    def add_error(folder, group, file, msg):
        errors.append({
            "Folder": folder,
            "Group": group,
            "File": file,
            "Step": "group-by-prefix",
            "Error": msg,
        })

    groups = {}  # prefix -> list of (index_str, folder_path)
    for folder in sorted(p for p in OUTPUT_DIR.iterdir() if p.is_dir()):
        m = pattern.match(folder.name)
        if not m:
            continue
        prefix = m.group(0)
        remainder = folder.name[len(prefix):]
        idx_match = re.match(r"^[-_.\s]*(\d+)", remainder)
        if not idx_match:
            add_error(folder.name, prefix, None,
                      f"No numeric index found right after prefix {prefix!r} "
                      f"(remainder: {remainder!r})")
            continue
        groups.setdefault(prefix, []).append((idx_match.group(1), folder))

    skip_folders = set()
    for prefix, items in groups.items():
        by_index = {}
        for index_str, folder in items:
            by_index.setdefault(index_str, []).append(folder)
        for index_str, folders in by_index.items():
            if len(folders) > 1:
                names = [f.name for f in folders]
                for folder in folders:
                    add_error(folder.name, prefix, None,
                              f"Duplicate index {index_str!r} within group "
                              f"{prefix!r} (also used by: "
                              f"{[n for n in names if n != folder.name]})")
                    skip_folders.add(folder)

    moved_count = 0
    removed_folder_count = 0
    skipped_folder_count = 0

    for prefix, items in groups.items():
        group_dir = OUTPUT_DIR / prefix
        for index_str, folder in items:
            if folder in skip_folders:
                continue

            folder_ok = True
            for f in sorted(p for p in folder.iterdir() if p.is_file()):
                if f.name == ".DS_Store":
                    continue
                ext = f.name[f.name.index("."):] if "." in f.name else ""
                target = group_dir / f"{index_str}{ext}"
                if target.exists():
                    add_error(folder.name, prefix, f.name,
                              f"Destination {prefix}/{target.name} already "
                              f"exists, left source file in place")
                    folder_ok = False
                    continue
                group_dir.mkdir(parents=True, exist_ok=True)
                try:
                    shutil.move(str(f), str(target))
                    moved_count += 1
                except OSError as e:
                    add_error(folder.name, prefix, f.name, f"Move failed: {e}")
                    folder_ok = False

            if folder_ok:
                ds_store = folder / ".DS_Store"
                if ds_store.exists():
                    ds_store.unlink()
                if not any(folder.iterdir()):
                    folder.rmdir()
                    removed_folder_count += 1
            else:
                skipped_folder_count += 1

    if errors:
        ERROR_FILE.write_text(json.dumps(errors, indent=2, ensure_ascii=False) + "\n")
    elif ERROR_FILE.exists():
        ERROR_FILE.unlink()

    print(f"Groups found: {len(groups)}")
    print(f"Files moved: {moved_count}")
    print(f"Source folders fully consolidated and removed: {removed_folder_count}")
    print(f"Source folders left in place due to errors: {skipped_folder_count}")
    if errors:
        print(f"Errors: {len(errors)} -> {ERROR_FILE}")
    else:
        print("Errors: 0")


if __name__ == "__main__":
    main()
