#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${PROJECT_DIR}/.env" ]]; then
  set -a
  . "${PROJECT_DIR}/.env"
  set +a
fi

printf 'Nero doctor\n\n'
printf 'Project dir: %s\n' "${PROJECT_DIR}"
printf 'Proxy mode: %s\n' "${TRAEFIK_MODE:-external}"
printf 'Domain: %s\n' "${OPENCODE_DOMAIN:-unset}"
printf 'Bind port: %s\n' "${OPENCODE_BIND_PORT:-4096}"

printf '\nContainers\n'
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | (grep -E 'NAMES|opencode|traefik' || true)

printf '\nWorkspace\n'
for path in \
  "${PROJECT_DIR}/workspace/agents/drop" \
  "${PROJECT_DIR}/workspace/agents/knowledge" \
  "${PROJECT_DIR}/workspace/agents/memory" \
  "${PROJECT_DIR}/workspace/agents/output" \
  "${PROJECT_DIR}/workspace/agents/code" \
  "${PROJECT_DIR}/workspace/agents/scripts" \
  "${PROJECT_DIR}/workspace/agents/.agents" \
  "${PROJECT_DIR}/workspace/agents/agents"; do
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
