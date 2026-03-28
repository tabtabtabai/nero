#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" ]] || { echo "usage: pptx-to-text.sh <file.pptx>" >&2; exit 1; }
command -v pandoc >/dev/null || { echo "pandoc not installed" >&2; exit 1; }
pandoc -f pptx -t plain "$1"
