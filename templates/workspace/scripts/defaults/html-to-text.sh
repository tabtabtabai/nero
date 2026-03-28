#!/usr/bin/env bash
set -euo pipefail
md=0
args=()
for a in "$@"; do
  if [[ "$a" == "--markdown" ]]; then md=1; else args+=("$a"); fi
done
file="${args[0]:-}"
[[ "$file" ]] || { echo "usage: html-to-text.sh <file.html> [--markdown]" >&2; exit 1; }
command -v pandoc >/dev/null || { echo "pandoc not installed" >&2; exit 1; }
if [[ "$md" -eq 1 ]]; then
  pandoc -f html -t markdown "$file"
else
  pandoc -f html -t plain "$file"
fi
