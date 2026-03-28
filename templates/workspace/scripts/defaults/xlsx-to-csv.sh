#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" ]] || { echo "usage: xlsx-to-csv.sh <file.xlsx> [sheet_name]" >&2; exit 1; }
file="$1"
sheet="${2:-}"
python3 - "$file" "$sheet" <<'PY'
import csv, sys
from pathlib import Path
path = Path(sys.argv[1])
sheet_name = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None
try:
    import openpyxl
except ImportError:
    print("python3-openpyxl required (openpyxl)", file=sys.stderr)
    sys.exit(1)
wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
if sheet_name:
    ws = wb[sheet_name]
else:
    ws = wb.active
w = csv.writer(sys.stdout)
for row in ws.iter_rows(values_only=True):
    w.writerow(["" if c is None else c for c in row])
PY
