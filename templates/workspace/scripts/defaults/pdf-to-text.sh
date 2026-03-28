#!/usr/bin/env bash
set -euo pipefail
ocr=""
args=()
for a in "$@"; do
  if [[ "$a" == "--ocr" ]]; then ocr=1; else args+=("$a"); fi
done
file="${args[0]:-}"
[[ "$file" ]] || { echo "usage: pdf-to-text.sh <file.pdf> [--ocr]" >&2; exit 1; }
if [[ -n "$ocr" ]]; then
  command -v pdftoppm >/dev/null && command -v tesseract >/dev/null || { echo "need poppler-utils and tesseract-ocr for --ocr" >&2; exit 1; }
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  pdftoppm -png -r 200 "$file" "$tmp/page"
  for img in "$tmp"/*.png; do
    [[ -e "$img" ]] || continue
    tesseract "$img" stdout 2>/dev/null
    echo ""
  done
else
  command -v pdftotext >/dev/null || { echo "pdftotext (poppler-utils) not installed" >&2; exit 1; }
  pdftotext -layout "$file" -
fi
