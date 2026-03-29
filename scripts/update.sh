#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -d "${PROJECT_DIR}/.git" ]]; then
  git -C "${PROJECT_DIR}" pull --ff-only
fi

exec bash "${PROJECT_DIR}/scripts/install.sh"
