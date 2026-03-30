#!/usr/bin/env bash
# Register git worktrees as OpenCode sandboxes for every row in the OpenCode project table.
# Shipped with Nero; host OpenCode data lives under $NERO_DIR/data/opencode (run-opencode-host.sh).
set -euo pipefail

_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NERO_DIR="$(cd -- "${_SCRIPT_DIR}/.." && pwd)"

# Single source of truth: the Nero-managed OpenCode DB used by run-opencode-host.sh.
DB="${NERO_DIR}/data/opencode/opencode/opencode.db"

if [ ! -f "$DB" ]; then
  echo "error: opencode database not found at $DB" >&2
  echo "hint: ensure Nero is installed and OpenCode has been started at least once." >&2
  exit 1
fi

command -v git >/dev/null 2>&1 || { echo "error: git not installed" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq not installed" >&2; exit 1; }
command -v sqlite3 >/dev/null 2>&1 || { echo "error: sqlite3 not installed" >&2; exit 1; }

rows=$(sqlite3 -separator $'\t' "$DB" "SELECT id, worktree, COALESCE(sandboxes, '[]') FROM project ORDER BY worktree;")

if [ -z "$rows" ]; then
  echo "no rows in table \`project\` at $DB (sync only uses this table)."
  echo "table row counts:"
  sqlite3 -column -header "$DB" "SELECT 'project' AS tbl, COUNT(*) AS n FROM project UNION ALL SELECT 'workspace', COUNT(*) FROM workspace UNION ALL SELECT 'session', COUNT(*) FROM session;"
  echo "the .db file can be non-empty from schema alone; open a folder in OpenCode to create project rows."
  exit 0
fi

updated_projects=0
registered_worktrees=0
skipped_projects=0
scanned_projects=0

while IFS=$'\t' read -r project_id project_dir sandboxes; do
  [ -n "$project_id" ] || continue
  scanned_projects=$((scanned_projects + 1))

  if [ ! -d "$project_dir" ]; then
    echo "skip: worktree path missing on disk: $project_dir"
    skipped_projects=$((skipped_projects + 1))
    continue
  fi

  if ! git -C "$project_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "skip: not a git checkout: $project_dir"
    skipped_projects=$((skipped_projects + 1))
    continue
  fi

  mapfile -t worktrees < <(git -C "$project_dir" worktree list --porcelain | sed -n 's/^worktree //p')

  if [ "${#worktrees[@]}" -eq 0 ]; then
    echo "skip: no worktrees from git: $project_dir"
    skipped_projects=$((skipped_projects + 1))
    continue
  fi

  if [ "${#worktrees[@]}" -le 1 ]; then
    echo "ok: no secondary worktrees: $project_dir"
    continue
  fi

  main_worktree="${worktrees[0]}"
  missing=()

  for wt in "${worktrees[@]}"; do
    [ "$wt" = "$main_worktree" ] && continue

    if jq -e --arg wt "$wt" 'index($wt) != null' <<<"$sandboxes" >/dev/null; then
      echo "ok: already registered: $wt"
    else
      echo "add: $wt"
      missing+=("$wt")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    continue
  fi

  new_sandboxes=$(jq -cn --argjson existing "$sandboxes" '$existing + $ARGS.positional' --args "${missing[@]}")
  escaped_id=${project_id//\'/\'\'}
  escaped_json=${new_sandboxes//\'/\'\'}

  sqlite3 "$DB" "UPDATE project SET sandboxes = json('$escaped_json'), time_updated = $(date +%s000) WHERE id = '$escaped_id';"

  updated_projects=$((updated_projects + 1))
  registered_worktrees=$((registered_worktrees + ${#missing[@]}))
done <<< "$rows"

echo
echo "database: $DB"
echo "scanned projects: $scanned_projects"
echo "updated projects: $updated_projects"
echo "registered worktrees: $registered_worktrees"
echo "skipped projects: $skipped_projects"
