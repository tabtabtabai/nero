#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

docker compose -f "${PROJECT_DIR}/compose.yaml" --env-file "${PROJECT_DIR}/.env" build --pull
docker compose -f "${PROJECT_DIR}/compose.yaml" --env-file "${PROJECT_DIR}/.env" up -d
