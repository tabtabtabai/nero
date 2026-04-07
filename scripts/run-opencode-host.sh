#!/usr/bin/env bash
set -euo pipefail

NERO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${NERO_DIR}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  printf 'Missing %s\n' "${ENV_FILE}" >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null
. "${ENV_FILE}"
set +a

export XDG_CONFIG_HOME="${NERO_DIR}/config"
export XDG_DATA_HOME="${NERO_DIR}/data/opencode"
export GH_CONFIG_DIR="${NERO_DIR}/config/gh"
export GIT_CONFIG_GLOBAL="${NERO_DIR}/config/git/.gitconfig"

opencode_shell="${OPENCODE_SHELL:-${SHELL:-/bin/bash}}"
if [[ ! -x "${opencode_shell}" ]]; then
  printf 'Configured OpenCode shell is not executable: %s\n' "${opencode_shell}" >&2
  exit 1
fi

export SHELL="${opencode_shell}"

exec opencode web \
  --hostname "${OPENCODE_BIND_ADDR}" \
  --port "${OPENCODE_BIND_PORT:-4096}"
