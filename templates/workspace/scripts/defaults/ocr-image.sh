#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" ]] || { echo "usage: ocr-image.sh <image> [lang]" >&2; exit 1; }
lang="${2:-eng}"
command -v tesseract >/dev/null || { echo "tesseract not installed" >&2; exit 1; }
tesseract "$1" stdout -l "$lang" 2>/dev/null
