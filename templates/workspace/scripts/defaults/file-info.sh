#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" ]] || { echo "usage: file-info.sh <file>" >&2; exit 1; }
command -v file >/dev/null || { echo "file(1) not installed" >&2; exit 1; }
ls -la "$1"
file -b "$1"
if command -v identify >/dev/null 2>&1; then
  identify "$1" 2>/dev/null || true
fi
