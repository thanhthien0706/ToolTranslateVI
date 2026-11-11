#!/bin/bash
# Group output/ folders sharing a common prefix (matched by a user-supplied
# regex) into one shared output/<prefix>/ folder, renumbering each source
# folder's files as <index>.<ext> using the number that follows the prefix
# in its folder name (e.g. w1-d1-02-foo -> output/w1-d1/02.mp4).
#
# Usage:
#   ./group_by_prefix.sh '<regex>'
#
# Any output/ folder not matching <regex> is left untouched. Folders that
# match but don't fit the "<prefix>-<NN>-slug" shape (no index number, a
# duplicate index within the same group), or whose target file already
# exists, are left exactly as-is — nothing moved or deleted for those — and
# recorded to output/group-by-prefix.errors.json for manual handling.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -ne 1 ]; then
  echo "Usage: $0 '<regex>'" >&2
  exit 1
fi

python3 "$SCRIPT_DIR/scripts/group_by_prefix.py" "$1"
