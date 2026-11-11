#!/bin/bash
# Step 3b (optional): collect the burned videos of a data.json batch into one
# folder per prefix, numbered in order, ready for 04_concat.sh:
#
#   output/w1-d1-01-foo/<Name>.sub.mp4  ->  output/w1-d1-concat/01.mp4
#   output/w1-d1-02-bar/<Name>.sub.mp4  ->  output/w1-d1-concat/02.mp4
#
# Usage:
#   ./03b_collect_sub.sh <data.json> '<regex>'      # e.g. '^w\d+-d\d+'
#
# <regex> is matched at the start of each FolderName; the matched text is the
# group, the number right after it is the index. Files are hard-linked (copy
# as a fallback), so the source folders stay as they are and no disk space is
# duplicated. Never overwrites; entries not burned yet are listed as missing.
# Idempotent — re-running only adds what is new.
#
# Then: ./04_concat.sh w1-d1-concat   -> output/w1-d1-concat/w1-d1-concat.full.mp4
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <data.json> '<regex>'" >&2
  exit 1
fi
if [[ ! -f "$1" ]]; then
  echo "JSON not found: $1" >&2
  exit 1
fi

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 "$SELF_DIR/scripts/collect_sub.py" "$1" "$2"
