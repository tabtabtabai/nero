#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" ]] || { echo "usage: docx-to-text.sh <file.docx>" >&2; exit 1; }
command -v pandoc >/dev/null || { echo "pandoc not installed" >&2; exit 1; }
pandoc -f docx -t markdown "$1"
