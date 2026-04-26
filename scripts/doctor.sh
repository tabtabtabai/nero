#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

if [[ -f "${PROJECT_DIR}/.env" ]]; then
  set -a
  . "${PROJECT_DIR}/.env"
  set +a
fi

WORKSPACE_ROOT="${WORKSPACE_HOST_DIR:-${PROJECT_DIR}/workspace}"
OPENCODE_HOME_ROOT="${OPENCODE_HOME_DIR:-${HOME}/.opencode}"

compose_config_hash() {
  local -a inputs=()
  local f
  for f in \
    "${PROJECT_DIR}/compose.yaml" \
    "${PROJECT_DIR}/.env" \
    "${PROJECT_DIR}/scripts/install.sh" \
    "${PROJECT_DIR}/scripts/run-opencode-host.sh"; do
    if [[ -f "${f}" ]]; then
      inputs+=("${f}")
    fi
  done
  if [[ "${#inputs[@]}" -eq 0 ]]; then
    printf '0\n'
    return
  fi
  sha256sum "${inputs[@]}" 2>/dev/null | sha256sum | awk '{print $1}'
}

get_latest_opencode_version() {
  if ! command -v npm >/dev/null 2>&1; then
    return 1
  fi
  npm view opencode-ai version 2>/dev/null
}

read_compose_stamp() {
  local stamp="$1"
  [[ -f "${stamp}" ]] || return 1
  if [[ -r "${stamp}" ]]; then
    cat "${stamp}"
    return 0
  fi
  ${SUDO} cat "${stamp}" 2>/dev/null
}

printf 'Nero doctor\n\n'
printf 'Project dir: %s\n' "${PROJECT_DIR}"
printf 'Proxy mode: %s\n' "${TRAEFIK_MODE:-self}"
printf 'Domain: %s\n' "${OPENCODE_DOMAIN:-unset}"
printf 'Bind port: %s\n' "${OPENCODE_BIND_PORT:-4096}"
printf 'Edge network: %s\n' "${NERO_EDGE_NETWORK:-nero-edge}"
printf 'Workspace dir: %s\n' "${WORKSPACE_ROOT}"
printf 'OpenCode home: %s\n' "${OPENCODE_HOME_ROOT}"

stamp_path="${PROJECT_DIR}/data/.nero-compose-signature"
current_hash="$(compose_config_hash)"
printf '\nCompose stack signature\n'
printf 'Current hash: %s\n' "${current_hash}"
stored=""
if [[ -f "${stamp_path}" ]]; then
  stored="$(read_compose_stamp "${stamp_path}" 2>/dev/null)" || true
  if [[ -n "${stored}" ]]; then
    printf 'Stored stamp: %s\n' "${stored}"
  else
    printf 'Stored stamp: (empty or unreadable)\n'
  fi
else
  printf 'Stored stamp: (none)\n'
fi
if [[ ! -f "${stamp_path}" ]]; then
  printf 'Signature status: no stamp\n'
elif [[ -z "${stored}" ]]; then
  printf 'Signature status: stamp unreadable\n'
elif [[ "${stored}" == "${current_hash}" ]]; then
  printf 'Signature status: match\n'
else
  printf 'Signature status: mismatch\n'
fi

printf '\nDocker (Traefik)\n'
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | (grep -E 'NAMES|traefik' || true)

printf '\nOpenCode (systemd)\n'
if ${SUDO} test -f /etc/systemd/system/nero-opencode.service; then
  ${SUDO} systemctl is-active nero-opencode.service 2>/dev/null || printf 'unit: inactive or failed\n'
  ${SUDO} systemctl --no-pager -l status nero-opencode.service 2>/dev/null | head -n 12 || true
else
  printf 'nero-opencode.service not installed\n'
fi
installed_opencode_version=""
if command -v opencode >/dev/null 2>&1; then
  printf 'opencode CLI: %s\n' "$(command -v opencode)"
  installed_opencode_version="$(opencode --version 2>/dev/null || true)"
  if [[ -n "${installed_opencode_version}" ]]; then
    printf 'Installed version: %s\n' "${installed_opencode_version}"
  fi
fi
latest_opencode_version="$(get_latest_opencode_version || true)"
if [[ -n "${latest_opencode_version}" ]]; then
  printf 'Latest npm version: %s\n' "${latest_opencode_version}"
  if [[ -n "${installed_opencode_version}" ]]; then
    if [[ "${installed_opencode_version}" == "${latest_opencode_version}" ]]; then
      printf 'Version status: up to date\n'
    else
      printf 'Version status: update available\n'
    fi
  fi
else
  printf 'Latest npm version: unavailable\n'
fi

printf '\nWorkspace\n'
for path in \
  "${WORKSPACE_ROOT}/drop" \
  "${WORKSPACE_ROOT}/knowledge" \
  "${WORKSPACE_ROOT}/memory" \
  "${WORKSPACE_ROOT}/output" \
  "${WORKSPACE_ROOT}/code" \
  "${WORKSPACE_ROOT}/scripts" \
  "${WORKSPACE_ROOT}/.agents"; do
  if [[ -e "${path}" ]]; then
    printf 'ok  %s\n' "${path}"
  else
    printf 'miss %s\n' "${path}"
  fi
done

if [[ -n "${OPENCODE_DOMAIN:-}" ]]; then
  printf '\nHTTP check\n'
  curl -k -I --max-time 10 "https://${OPENCODE_DOMAIN}" || true
fi
