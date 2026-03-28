#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" ]] || { echo "usage: xls-to-csv.sh <file.xls>" >&2; exit 1; }
python3 - "$1" <<'PY'
import csv, sys
from pathlib import Path
path = Path(sys.argv[1])
try:
    import xlrd
except ImportError:
    print("python3-xlrd required for legacy .xls", file=sys.stderr)
    sys.exit(1)
book = xlrd.open_workbook(path)
sh = book.sheet_by_index(0)
w = csv.writer(sys.stdout)
for r in range(sh.nrows):
    w.writerow(sh.row_values(r))
PY
