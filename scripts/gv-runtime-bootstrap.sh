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

GV_VM_USER="${GV_VM_USER:-${SUDO_USER:-}}"
if [[ -z "${GV_VM_USER}" ]]; then
  printf 'GV_VM_USER is required\n' >&2
  exit 1
fi

GV_VM_HOME="$(getent passwd "${GV_VM_USER}" | cut -d: -f6)"
if [[ -z "${GV_VM_HOME}" ]]; then
  printf 'Could not resolve home for %s\n' "${GV_VM_USER}" >&2
  exit 1
fi

export GV_VM_USER GV_VM_HOME
export XDG_CONFIG_HOME="${NERO_DIR}/config"
export XDG_DATA_HOME="${NERO_DIR}/data/opencode"

mkdir -p /etc/gv
printf 'GV_ENVIRONMENT=1\n' > /etc/gv/environment

chown -R "${GV_VM_USER}:${GV_VM_USER}" "${GV_VM_HOME}/.codex" "${GV_VM_HOME}/.claude" 2>/dev/null || true
chown "${GV_VM_USER}:${GV_VM_USER}" "${GV_VM_HOME}/.claude.json" 2>/dev/null || true

NPM_ROOT="$(npm root -g)"
command -v devcontainer >/dev/null 2>&1 || npm i -g @devcontainers/cli
test -d "${NPM_ROOT}/@opencode-ai/plugin" || npm i -g @opencode-ai/plugin
ln -sfn "${NPM_ROOT}/@opencode-ai/plugin" "${NERO_DIR}/config/opencode/node_modules/@opencode-ai/plugin"

chmod 755 /opt /opt/nero "${NERO_DIR}/scripts" || true
if getent group docker >/dev/null 2>&1; then usermod -aG docker "${GV_VM_USER}"; fi
chown -R 1000:1000 "${NERO_DIR}/config" "${NERO_DIR}/data/opencode" "${GV_VM_HOME}/.config" "${GV_VM_HOME}/workspace" 2>/dev/null || true

install -d -m 755 -o "${GV_VM_USER}" -g "${GV_VM_USER}" "${GV_VM_HOME}/.npm"
chown -R "${GV_VM_USER}:${GV_VM_USER}" "${GV_VM_HOME}/.npm" || true

if [[ -n "${GV_CLI_INSTALL_SOURCE:-}" ]]; then
  sudo -iu "${GV_VM_USER}" pipx install -f "${GV_CLI_INSTALL_SOURCE}"
else
  sudo -iu "${GV_VM_USER}" pipx install -f gv-cli
fi

sudo -iu "${GV_VM_USER}" env NPM_CONFIG_PREFIX="${GV_VM_HOME}/.local" NPM_CONFIG_CACHE="${GV_VM_HOME}/.npm" npm i -g @openai/codex
sudo -iu "${GV_VM_USER}" bash -lc 'curl -fsSL https://claude.ai/install.sh | bash'
if [[ -d "${GV_VM_HOME}/.npm" ]]; then chown -R "${GV_VM_USER}:${GV_VM_USER}" "${GV_VM_HOME}/.npm"; fi

python3 - <<'PY'
from pathlib import Path

unit = Path('/etc/systemd/system/nero-opencode.service')
if unit.exists():
    text = unit.read_text()
    wanted = 'ExecStart=/bin/bash /opt/nero/scripts/run-opencode-host.sh'
    if 'ExecStart=/opt/nero/scripts/run-opencode-host.sh' in text:
        unit.write_text(text.replace('ExecStart=/opt/nero/scripts/run-opencode-host.sh', wanted))
PY

systemctl daemon-reload
systemctl enable gv-preview-router
systemctl start gv-preview-router
systemctl -q is-active gv-preview-router
chmod +x "${NERO_DIR}/scripts/run-opencode-host.sh" "${NERO_DIR}/scripts/oc-sync-worktrees.sh" || true
systemctl restart nero-opencode.service || true
