#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" ]] || { echo "usage: extract-archive.sh <file> [dest_dir]" >&2; exit 1; }
src="$1"
dest="${2:-.}"
mkdir -p "$dest"
case "$src" in
  *.zip) unzip -o -d "$dest" "$src" ;;
  *.tar|*.tar.gz|*.tgz|*.tar.bz2|*.tbz2)
    tar -xf "$src" -C "$dest"
    ;;
  *.7z)
    command -v 7z >/dev/null || { echo "7z not installed" >&2; exit 1; }
    7z x -y "-o${dest}" "$src"
    ;;
  *.rar)
    command -v 7z >/dev/null || { echo "7z not installed (needed for rar)" >&2; exit 1; }
    7z x -y "-o${dest}" "$src"
    ;;
  *)
    echo "unsupported archive: $src" >&2
    exit 1
    ;;
esac
echo "extracted to: $dest"
