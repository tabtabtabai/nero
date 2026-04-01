#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="nero"
NERO_EDGE_NETWORK="${NERO_EDGE_NETWORK:-nero-edge}"
SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -n "${TARGET_DIR:-}" ]]; then
  TARGET_DIR="${TARGET_DIR}"
elif [[ -d "${SOURCE_DIR}/.git" ]]; then
  TARGET_DIR="${SOURCE_DIR}"
else
  TARGET_DIR="/opt/${PROJECT_NAME}"
fi

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/docker-ubuntu.sh"

DEFAULT_MODEL="openai/gpt-5.4"
OPENCODE_UID="${OPENCODE_UID:-}"
OPENCODE_GID="${OPENCODE_GID:-}"

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

shell_escape() {
  printf '%q' "$1"
}

resolve_workspace_host_dir() {
  if [[ -n "${WORKSPACE_HOST_DIR:-}" ]]; then
    return
  fi

  local install_user="${SUDO_USER:-${USER:-}}"
  local install_home=""

  if [[ -n "${install_user}" ]]; then
    install_home="$(getent passwd "${install_user}" 2>/dev/null | cut -d: -f6 || true)"
  fi

  if [[ -z "${install_home}" ]]; then
    install_home="${HOME:-}"
  fi

  if [[ -z "${install_home}" ]]; then
    install_home="/root"
  fi

  WORKSPACE_HOST_DIR="${install_home}/nero/workspace"
}

# Set OPENCODE_UID/GID from a passwd name or uid that actually exists (getent).
_opencode_try_uid_pair() {
  local want="$1"
  local pw=""
  [[ -n "${want}" ]] || return 1
  pw="$(getent passwd "${want}")" || return 1
  [[ -n "${pw}" ]] || return 1
  OPENCODE_UID="$(printf '%s' "${pw}" | cut -d: -f3)"
  OPENCODE_GID="$(printf '%s' "${pw}" | cut -d: -f4)"
  return 0
}

# Prefer a real Unix account. Workspace may be owned by a numeric uid with no passwd row
# (e.g. copied from another host); then fall back to sudo caller or current user.
resolve_opencode_ids() {
  local workspace_uid=""
  if [[ -d "${WORKSPACE_HOST_DIR}" ]]; then
    workspace_uid="$(stat -c %u "${WORKSPACE_HOST_DIR}")"
  fi

  if [[ -n "${OPENCODE_UID:-}" ]] && _opencode_try_uid_pair "${OPENCODE_UID}"; then
    return 0
  fi
  if _opencode_try_uid_pair "1000"; then
    return 0
  fi
  if [[ -n "${workspace_uid}" ]] && _opencode_try_uid_pair "${workspace_uid}"; then
    return 0
  fi
  if [[ -n "${SUDO_USER:-}" ]]; then
    local suid=""
    suid="$(id -u "${SUDO_USER}" 2>/dev/null || true)"
    if [[ -n "${suid}" ]] && _opencode_try_uid_pair "${suid}"; then
      return 0
    fi
    if _opencode_try_uid_pair "${SUDO_USER}"; then
      return 0
    fi
  fi
  _opencode_try_uid_pair "$(id -u)"
}

port_in_use() {
  local port="$1"
  ss -tuln | grep -Eq ":${port}[[:space:]]"
}

detect_proxy_mode() {
  case "${TRAEFIK_MODE:-self}" in
    self|external)
      TRAEFIK_MODE="${TRAEFIK_MODE:-self}"
      return
      ;;
    auto)
      ;;
    *)
      TRAEFIK_MODE="self"
      return
      ;;
  esac

  if port_in_use 80 || port_in_use 443; then
    if ${SUDO} docker ps --format '{{.Names}}' | grep -qx "${PROJECT_NAME}-traefik"; then
      TRAEFIK_MODE="self"
    else
      TRAEFIK_MODE="external"
    fi
  else
    TRAEFIK_MODE="self"
  fi
}

compose_config_hash() {
  # Bump the stamp when compose, env, or host-OpenCode scripts change so `nero update` reapplies Docker + systemd reliably.
  local -a inputs=()
  local f
  for f in \
    "${TARGET_DIR}/compose.yaml" \
    "${TARGET_DIR}/.env" \
    "${TARGET_DIR}/scripts/install.sh" \
    "${TARGET_DIR}/scripts/run-opencode-host.sh" \
    "${TARGET_DIR}/scripts/oc-sync-worktrees.sh"; do
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

read_compose_stamp() {
  local stamp="$1"
  [[ -f "${stamp}" ]] || return 1
  if [[ -r "${stamp}" ]]; then
    cat "${stamp}"
    return 0
  fi
  ${SUDO} cat "${stamp}" 2>/dev/null
}

_compose_up() {
  local force_recreate="$1"
  local recreate_args=()
  if [[ "${force_recreate}" == "yes" ]]; then
    recreate_args=(--force-recreate)
  fi

  if [[ "${TRAEFIK_MODE}" == "self" ]]; then
    ${SUDO} docker compose -f "${TARGET_DIR}/compose.yaml" --env-file "${TARGET_DIR}/.env" --profile self-proxy pull traefik || true
    ${SUDO} docker compose -f "${TARGET_DIR}/compose.yaml" --env-file "${TARGET_DIR}/.env" --profile self-proxy up -d --build "${recreate_args[@]}" --remove-orphans
    return
  fi

  ${SUDO} docker compose -f "${TARGET_DIR}/compose.yaml" --env-file "${TARGET_DIR}/.env" up -d --build "${recreate_args[@]}" --remove-orphans
}

refresh_compose_stack() {
  local stamp="${TARGET_DIR}/data/.nero-compose-signature"
  local h stamped
  h="$(compose_config_hash)"

  stamped=""
  if [[ -f "${stamp}" ]]; then
    stamped="$(read_compose_stamp "${stamp}" 2>/dev/null)" || true
  fi

  if [[ -n "${stamped}" ]] && [[ "${stamped}" == "${h}" ]]; then
    _compose_up no
  else
    compose_down
    remove_managed_containers
    _compose_up yes
  fi

  printf '%s\n' "${h}" | ${SUDO} tee "${stamp}" >/dev/null
  ${SUDO} chmod 644 "${stamp}" 2>/dev/null || true
}

remove_managed_containers() {
  ${SUDO} docker rm -f "${PROJECT_NAME}-traefik" >/dev/null 2>&1 || true
  ${SUDO} docker rm -f "${PROJECT_NAME}-opencode" >/dev/null 2>&1 || true
}

# Idempotent migration from Docker OpenCode to host OpenCode (safe to run every install/update).
cleanup_legacy_docker_opencode() {
  ${SUDO} docker rm -f "${PROJECT_NAME}-opencode" >/dev/null 2>&1 || true
  if [[ -d "${TARGET_DIR}/opencode" ]]; then
    ${SUDO} rm -rf "${TARGET_DIR}/opencode"
  fi
  ${SUDO} docker rmi "${PROJECT_NAME}-opencode" >/dev/null 2>&1 || true
}

ensure_host_opencode_scripts_executable() {
  if [[ -f "${TARGET_DIR}/scripts/run-opencode-host.sh" ]]; then
    ${SUDO} chmod +x "${TARGET_DIR}/scripts/run-opencode-host.sh"
  fi
  if [[ -f "${TARGET_DIR}/scripts/oc-sync-worktrees.sh" ]]; then
    ${SUDO} chmod +x "${TARGET_DIR}/scripts/oc-sync-worktrees.sh"
  fi
}

compose_down() {
  ${SUDO} docker compose -f "${TARGET_DIR}/compose.yaml" --env-file "${TARGET_DIR}/.env" --profile self-proxy down --remove-orphans || true
}

ensure_nodejs() {
  local major=0
  if need_cmd node && need_cmd npm; then
    major="$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)"
    if [[ "${major}" -ge 20 ]]; then
      return 0
    fi
  fi

  if [[ ! -f /etc/apt/sources.list.d/nodesource.list ]]; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | ${SUDO} bash -
  fi
  ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
}

# Host SQLite CLI (e.g. scripts that read OpenCode's opencode.db, jq + sqlite3).
ensure_jq() {
  if need_cmd jq; then
    return 0
  fi
  if ! need_cmd apt-get; then
    printf 'jq is not installed and apt-get was not found; install the jq package manually.\n' >&2
    return 1
  fi
  ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends jq
}

ensure_sqlite3() {
  if need_cmd sqlite3; then
    return 0
  fi
  if ! need_cmd apt-get; then
    printf 'sqlite3 is not installed and apt-get was not found; install the sqlite3 package manually.\n' >&2
    return 1
  fi
  ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends sqlite3
}

resolve_opencode_service_user() {
  OPENCODE_SERVICE_USER="$(getent passwd "${OPENCODE_UID}" | cut -d: -f1 || true)"
  if [[ -z "${OPENCODE_SERVICE_USER}" ]]; then
    printf 'No passwd entry for OPENCODE_UID=%s. Create that user or set OPENCODE_UID to an existing account UID.\n' "${OPENCODE_UID}" >&2
    exit 1
  fi
}

link_opencode_runtime_home() {
  local home_dir=""
  home_dir="$(getent passwd "${OPENCODE_UID}" | cut -d: -f6 || true)"
  if [[ -z "${home_dir}" || ! -d "${home_dir}" ]]; then
    printf 'Skipping gh/git/ssh symlinks: no home directory for UID %s.\n' "${OPENCODE_UID}" >&2
    return 0
  fi

  ${SUDO} mkdir -p "${home_dir}/.config"
  ${SUDO} ln -sfn "${TARGET_DIR}/config/gh" "${home_dir}/.config/gh"
  ${SUDO} ln -sfn "${TARGET_DIR}/config/git/.gitconfig" "${home_dir}/.gitconfig"

  if [[ ! -e "${home_dir}/.ssh" ]]; then
    ${SUDO} ln -sfn "${TARGET_DIR}/config/ssh" "${home_dir}/.ssh"
  elif [[ -L "${home_dir}/.ssh" ]]; then
    ${SUDO} ln -sfn "${TARGET_DIR}/config/ssh" "${home_dir}/.ssh"
  else
    printf 'Note: %s is a real directory; Nero SSH material remains in %s/config/ssh only.\n' "${home_dir}/.ssh" "${TARGET_DIR}" >&2
  fi

  ${SUDO} chown -h "${OPENCODE_UID}:${OPENCODE_GID}" "${home_dir}/.config/gh" "${home_dir}/.gitconfig" 2>/dev/null || true
}

install_opencode_cli_global() {
  ensure_nodejs
  ensure_jq
  ensure_sqlite3
  local ver="${OPENCODE_CLI_VERSION:-latest}"
  ${SUDO} npm install -g --no-fund --no-audit "opencode-ai@${ver}"
}

install_opencode_systemd() {
  resolve_opencode_service_user
  link_opencode_runtime_home

  local unit_path="/etc/systemd/system/nero-opencode.service"
  local run_script="${TARGET_DIR}/scripts/run-opencode-host.sh"
  local svc_group=""

  svc_group="$(id -gn "${OPENCODE_SERVICE_USER}" 2>/dev/null || printf '%s' "${OPENCODE_GID}")"

  ${SUDO} chmod +x "${run_script}"

  ${SUDO} tee "${unit_path}" >/dev/null <<UNIT
[Unit]
Description=Nero OpenCode (host)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5
User=${OPENCODE_SERVICE_USER}
Group=${svc_group}
WorkingDirectory=${WORKSPACE_HOST_DIR}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${run_script}

[Install]
WantedBy=multi-user.target
UNIT

  ${SUDO} systemctl daemon-reload
  ${SUDO} systemctl enable nero-opencode.service
}

restart_host_opencode() {
  if ${SUDO} test -f /etc/systemd/system/nero-opencode.service; then
    ${SUDO} systemctl restart nero-opencode.service
  fi
}

install_global_command() {
  local command_target="${TARGET_DIR}/nero"

  if [[ "${SOURCE_DIR}" == "${TARGET_DIR}" && -f "${SOURCE_DIR}/nero" ]]; then
    command_target="${SOURCE_DIR}/nero"
  fi

  ${SUDO} ln -sf "${command_target}" /usr/local/bin/nero
  ${SUDO} chmod +x "${command_target}"
}

write_traefik_dynamic_config() {
  ${SUDO} mkdir -p "${TARGET_DIR}/traefik/dynamic"
  ${SUDO} tee "${TARGET_DIR}/traefik/dynamic/opencode.yml" >/dev/null <<EOF
http:
  routers:
    opencode:
      rule: Host(\`${OPENCODE_DOMAIN}\`)
      entryPoints:
        - websecure
      service: opencode
      tls:
        certResolver: cloudflare

  services:
    opencode:
      loadBalancer:
        servers:
          - url: http://host.docker.internal:${OPENCODE_BIND_PORT:-4096}
EOF
}

migrate_legacy_agent_workspace() {
  local legacy_agents="${TARGET_DIR}/workspace/agents"
  local legacy_agent="${TARGET_DIR}/workspace/agent"
  local workspace_parent

  workspace_parent="$(dirname "${WORKSPACE_HOST_DIR}")"
  ${SUDO} mkdir -p "${workspace_parent}"

  if [[ -d "${legacy_agents}" && ! -e "${WORKSPACE_HOST_DIR}" ]]; then
    ${SUDO} mv "${legacy_agents}" "${WORKSPACE_HOST_DIR}"
    return
  fi

  if [[ -d "${legacy_agent}" && ! -e "${WORKSPACE_HOST_DIR}" ]]; then
    ${SUDO} mv "${legacy_agent}" "${WORKSPACE_HOST_DIR}"
  fi
}

initialize_workspace_structure() {
  local template_root="${SOURCE_DIR}/templates/workspace"
  local workspace_root="${WORKSPACE_HOST_DIR}"

  migrate_legacy_agent_workspace

  ${SUDO} mkdir -p "${workspace_root}"

  if [[ ! -d "${template_root}" ]]; then
    return
  fi

  ${SUDO} cp -a --update=none "${template_root}/." "${workspace_root}/"
  ${SUDO} chmod +x "${workspace_root}/scripts/defaults/"*.sh 2>/dev/null || true
  ${SUDO} chown -R "${OPENCODE_UID}:${OPENCODE_GID}" "${workspace_root}"
}

prompt_yes_no() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="${3:-y}"
  local current_value="${!var_name:-}"
  local answer=""

  if [[ -n "${current_value}" ]]; then
    return
  fi

  read -r -p "${prompt_text} " answer
  answer="${answer:-${default_value}}"
  case "${answer}" in
    y|Y|yes|YES)
      printf -v "$var_name" '%s' "yes"
      ;;
    n|N|no|NO)
      printf -v "$var_name" '%s' "no"
      ;;
    *)
      printf 'Please answer yes or no.\n' >&2
      exit 1
      ;;
  esac
}

prompt_value() {
  local var_name="$1"
  local prompt_text="$2"
  local secret="${3:-false}"
  local default_value="${4:-}"
  local current_value="${!var_name:-$default_value}"

  if [[ -n "${current_value}" ]]; then
    return
  fi

  if [[ "${secret}" == "true" ]]; then
    read -r -s -p "${prompt_text}: " current_value
    printf '\n'
  else
    read -r -p "${prompt_text}: " current_value
  fi

  printf -v "$var_name" '%s' "$current_value"
}

set_model_defaults() {
  OPENCODE_MODEL="${OPENCODE_MODEL:-$DEFAULT_MODEL}"
  ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
  OPENAI_API_KEY="${OPENAI_API_KEY:-}"
  GEMINI_API_KEY="${GEMINI_API_KEY:-}"
  OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"
  LOCAL_ENDPOINT="${LOCAL_ENDPOINT:-}"
}

resolve_git_identity() {
  if [[ -z "${GIT_USER_NAME:-}" ]]; then
    if need_cmd git && git config --global user.name >/dev/null 2>&1; then
      GIT_USER_NAME="$(git config --global user.name)"
    else
      GIT_USER_NAME="$(id -un)"
    fi
  fi

  if [[ -z "${GIT_USER_EMAIL:-}" ]]; then
    if need_cmd git && git config --global user.email >/dev/null 2>&1; then
      GIT_USER_EMAIL="$(git config --global user.email)"
    else
      local hn
      hn="$(hostname -f 2>/dev/null || hostname)"
      if [[ "${hn}" == *.* ]]; then
        GIT_USER_EMAIL="$(id -un)@${hn}"
      else
        GIT_USER_EMAIL="$(id -un)@${hn}.local"
      fi
    fi
  fi
}

write_gitconfig() {
  ${SUDO} mkdir -p "${TARGET_DIR}/config/git"
  if [[ "${ENABLE_GITHUB:-}" == "yes" ]]; then
    ${SUDO} tee "${TARGET_DIR}/config/git/.gitconfig" >/dev/null <<EOF
[user]
  name = ${GIT_USER_NAME}
  email = ${GIT_USER_EMAIL}

[credential "https://github.com"]
  helper =
  helper = !/usr/bin/gh auth git-credential
EOF
  else
    ${SUDO} tee "${TARGET_DIR}/config/git/.gitconfig" >/dev/null <<EOF
[user]
  name = ${GIT_USER_NAME}
  email = ${GIT_USER_EMAIL}
EOF
  fi
  ${SUDO} chown "${OPENCODE_UID}:${OPENCODE_GID}" "${TARGET_DIR}/config/git/.gitconfig"
  ${SUDO} chmod 600 "${TARGET_DIR}/config/git/.gitconfig"
}

# Nero-managed gitconfig under TARGET_DIR is also symlinked into the OpenCode service user's home.
apply_host_git_identity() {
  if [[ "${SKIP_HOST_GIT_CONFIG:-}" == "1" ]]; then
    return
  fi
  if ! need_cmd git; then
    return
  fi
  git config --global user.name "${GIT_USER_NAME}"
  git config --global user.email "${GIT_USER_EMAIL}"
}

setup_github_auth() {
  local gh_config_dir="${TARGET_DIR}/config/gh"
  local github_auth_choice=""
  local gh_hosts_file="${gh_config_dir}/hosts.yml"

  if [[ "${ENABLE_GITHUB}" != "yes" ]]; then
    GITHUB_TOKEN=""
    return
  fi

  if [[ -z "${GITHUB_TOKEN:-}" && ! -f "${gh_hosts_file}" ]]; then
    printf '\n'
    printf 'GitHub auth method:\n'
    printf '  1) Fine-grained token (recommended)\n'
    printf '  2) Skip token for now\n'
    read -r -p 'Auth [1]: ' github_auth_choice

    case "${github_auth_choice:-1}" in
      1)
        prompt_value GITHUB_TOKEN "GitHub token" true
        ;;
      2)
        GITHUB_TOKEN=""
        ;;
      *)
        printf 'Invalid GitHub auth selection.\n' >&2
        exit 1
        ;;
    esac
  fi

  prompt_yes_no GITHUB_SSH_KEY "Generate GitHub SSH key for this VM? [Y/n]" "y"

  ${SUDO} mkdir -p "${TARGET_DIR}/config/gh" "${TARGET_DIR}/config/ssh"
  ${SUDO} chown -R "${OPENCODE_UID}:${OPENCODE_GID}" "${TARGET_DIR}/config/gh" "${TARGET_DIR}/config/ssh"
  ${SUDO} chmod 700 "${TARGET_DIR}/config/ssh"

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    if ! need_cmd gh; then
      printf 'gh CLI is required for GitHub auth setup. Run ./nero bootstrap first.\n' >&2
      exit 1
    fi
    printf '%s\n' "${GITHUB_TOKEN}" | ${SUDO} env -u GITHUB_TOKEN GH_CONFIG_DIR="${gh_config_dir}" gh auth login --hostname github.com --git-protocol https --with-token >/dev/null
    ${SUDO} chown -R "${OPENCODE_UID}:${OPENCODE_GID}" "${gh_config_dir}"
  fi

  if [[ "${GITHUB_SSH_KEY}" == "yes" && ! -f "${TARGET_DIR}/config/ssh/id_ed25519" ]]; then
    ${SUDO} ssh-keygen -t ed25519 -N "" -C "nero@$(hostname)" -f "${TARGET_DIR}/config/ssh/id_ed25519" >/dev/null
    ${SUDO} chown -R "${OPENCODE_UID}:${OPENCODE_GID}" "${TARGET_DIR}/config/ssh"
    ${SUDO} chmod 600 "${TARGET_DIR}/config/ssh/id_ed25519"
    ${SUDO} chmod 644 "${TARGET_DIR}/config/ssh/id_ed25519.pub"
  fi
}

write_env_file() {
  cat > "${SOURCE_DIR}/.env" <<EOF
PROJECT_NAME=$(shell_escape "${PROJECT_NAME}")
NERO_EDGE_NETWORK=$(shell_escape "${NERO_EDGE_NETWORK}")
TZ=$(shell_escape "${TZ:-UTC}")
TRAEFIK_MODE=$(shell_escape "${TRAEFIK_MODE}")
OPENCODE_BIND_PORT=$(shell_escape "${OPENCODE_BIND_PORT:-4096}")
ENABLE_GITHUB=$(shell_escape "${ENABLE_GITHUB:-yes}")
GITHUB_SSH_KEY=$(shell_escape "${GITHUB_SSH_KEY:-yes}")

OPENCODE_DOMAIN=$(shell_escape "${OPENCODE_DOMAIN}")
LETSENCRYPT_EMAIL=$(shell_escape "${LETSENCRYPT_EMAIL}")
CF_DNS_API_TOKEN=$(shell_escape "${CF_DNS_API_TOKEN}")

OPENCODE_SERVER_USERNAME=$(shell_escape "${OPENCODE_SERVER_USERNAME:-opencode}")
OPENCODE_SERVER_PASSWORD=$(shell_escape "${OPENCODE_SERVER_PASSWORD}")
OPENCODE_MODEL=$(shell_escape "${OPENCODE_MODEL}")
GIT_USER_NAME=$(shell_escape "${GIT_USER_NAME:-}")
GIT_USER_EMAIL=$(shell_escape "${GIT_USER_EMAIL:-}")

ANTHROPIC_API_KEY=$(shell_escape "${ANTHROPIC_API_KEY:-}")
OPENAI_API_KEY=$(shell_escape "${OPENAI_API_KEY:-}")
GEMINI_API_KEY=$(shell_escape "${GEMINI_API_KEY:-}")
OPENROUTER_API_KEY=$(shell_escape "${OPENROUTER_API_KEY:-}")
GITHUB_TOKEN=$(shell_escape "${GITHUB_TOKEN:-}")
LOCAL_ENDPOINT=$(shell_escape "${LOCAL_ENDPOINT:-}")
WORKSPACE_HOST_DIR=$(shell_escape "${WORKSPACE_HOST_DIR}")
OPENCODE_CLI_VERSION=$(shell_escape "${OPENCODE_CLI_VERSION:-latest}")
OPENCODE_BIND_ADDR=$(shell_escape "${OPENCODE_BIND_ADDR}")
OPENCODE_UID=$(shell_escape "${OPENCODE_UID}")
OPENCODE_GID=$(shell_escape "${OPENCODE_GID}")
EOF

  if [[ "${TARGET_DIR}" != "${SOURCE_DIR}" ]]; then
    ${SUDO} cp "${SOURCE_DIR}/.env" "${TARGET_DIR}/.env"
  fi
}

ensure_external_edge_network() {
  if ${SUDO} docker network inspect "${NERO_EDGE_NETWORK}" >/dev/null 2>&1; then
    return
  fi

  ${SUDO} docker network create "${NERO_EDGE_NETWORK}" >/dev/null
}

# UFW default deny blocks Traefik (on the Docker edge network) from connecting to host OpenCode.
ensure_ufw_allows_docker_to_host_opencode() {
  need_cmd ufw || return 0
  [[ "${TRAEFIK_MODE}" == "self" ]] || return 0
  if ! ${SUDO} ufw status 2>/dev/null | grep -qi 'Status: active'; then
    return 0
  fi

  local port="${OPENCODE_BIND_PORT:-4096}"
  local subnet=""

  if need_cmd docker && ${SUDO} docker network inspect "${NERO_EDGE_NETWORK}" >/dev/null 2>&1; then
    subnet="$(${SUDO} docker network inspect "${NERO_EDGE_NETWORK}" -f '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null | tr -d '\r')"
  fi
  if [[ -z "${subnet}" ]]; then
    subnet="172.16.0.0/12"
  fi

  if ${SUDO} ufw status verbose 2>/dev/null | grep -q 'nero-docker-to-opencode'; then
    return 0
  fi

  printf 'UFW: allowing %s -> host tcp/%s (Traefik to OpenCode).\n' "${subnet}" "${port}" >&2
  if ! ${SUDO} ufw allow from "${subnet}" to any port "${port}" proto tcp comment 'nero-docker-to-opencode' 2>/dev/null; then
    ${SUDO} ufw allow from "${subnet}" to any port "${port}" proto tcp
  fi
}

install_docker() {
  if need_cmd docker && docker compose version >/dev/null 2>&1; then
    if [[ -f /etc/os-release ]]; then
      if [[ "${EUID}" -eq 0 ]]; then
        install_or_update_docker_ubuntu
      else
        sudo bash -lc '. "'"${SOURCE_DIR}"'"/scripts/lib/docker-ubuntu.sh" && install_or_update_docker_ubuntu'
      fi
      return
    fi
  fi

  if [[ -f /etc/os-release ]]; then
    if [[ "${EUID}" -eq 0 ]]; then
      install_or_update_docker_ubuntu
    else
      sudo bash -lc '. "'"${SOURCE_DIR}"'"/scripts/lib/docker-ubuntu.sh" && install_or_update_docker_ubuntu'
    fi
    return
  fi

  curl -fsSL https://get.docker.com | sh
}

sync_project() {
  if [[ "${SOURCE_DIR}" == "${TARGET_DIR}" ]]; then
    return
  fi

  ${SUDO} mkdir -p "${TARGET_DIR}"

  tar \
    --exclude='.git' \
    --exclude='.env' \
    --exclude='data' \
    --exclude='workspace' \
    -cf - -C "${SOURCE_DIR}" . | ${SUDO} tar -xf - -C "${TARGET_DIR}"

}

prepare_runtime_dirs() {
  ${SUDO} mkdir -p \
    "${TARGET_DIR}/config/gh" \
    "${TARGET_DIR}/config/git" \
    "${TARGET_DIR}/config/opencode" \
    "${TARGET_DIR}/config/ssh" \
    "${TARGET_DIR}/data/opencode" \
    "${TARGET_DIR}/data/traefik" \
    "${TARGET_DIR}/traefik/dynamic" \
    "${WORKSPACE_HOST_DIR}"

  if [[ -d "${TARGET_DIR}/config/git/.gitconfig" ]]; then
    ${SUDO} rm -rf "${TARGET_DIR}/config/git/.gitconfig"
  fi

  ${SUDO} touch "${TARGET_DIR}/data/traefik/acme.json"
  ${SUDO} touch "${TARGET_DIR}/config/git/.gitconfig"
  ${SUDO} chmod 600 "${TARGET_DIR}/data/traefik/acme.json"
  ${SUDO} chmod 600 "${TARGET_DIR}/config/git/.gitconfig"
  ${SUDO} chown -R "${OPENCODE_UID}:${OPENCODE_GID}" \
    "${TARGET_DIR}/config/gh" \
    "${TARGET_DIR}/config/git" \
    "${TARGET_DIR}/config/opencode" \
    "${TARGET_DIR}/config/ssh" \
    "${TARGET_DIR}/data/opencode" \
    "${WORKSPACE_HOST_DIR}"
  ${SUDO} chmod 700 "${TARGET_DIR}/config/ssh"
  ${SUDO} chmod 755 "${TARGET_DIR}/data/opencode"
}

load_env_file() {
  local env_path="$1"

  if [[ ! -f "${env_path}" ]]; then
    return
  fi

  set -a
  . "${env_path}"
  set +a
}

if [[ "${SOURCE_DIR}" != "${TARGET_DIR}" ]]; then
  load_env_file "${TARGET_DIR}/.env"
fi
load_env_file "${SOURCE_DIR}/.env"

resolve_workspace_host_dir
resolve_opencode_ids
detect_proxy_mode

if [[ "${NERO_REMOTE_COMMAND:-}" == "update" ]]; then
  if [[ ! -f "${TARGET_DIR}/.env" ]] || [[ -z "${OPENCODE_DOMAIN:-}" ]] || [[ -z "${OPENCODE_SERVER_PASSWORD:-}" ]]; then
    printf 'nero update requires an existing install. Ensure %s/.env exists and sets OPENCODE_DOMAIN and OPENCODE_SERVER_PASSWORD. Run `nero install` if this host is not set up yet.\n' "${TARGET_DIR}" >&2
    exit 1
  fi
fi

prompt_value OPENCODE_DOMAIN "OpenCode domain"
prompt_value OPENCODE_SERVER_PASSWORD "OpenCode server password" true

if [[ "${TRAEFIK_MODE}" == "self" ]]; then
  prompt_value LETSENCRYPT_EMAIL "Let's Encrypt email"
  prompt_value CF_DNS_API_TOKEN "Cloudflare DNS API token" true
else
  LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
  CF_DNS_API_TOKEN="${CF_DNS_API_TOKEN:-}"
fi

OPENCODE_SERVER_USERNAME="${OPENCODE_SERVER_USERNAME:-opencode}"
TZ="${TZ:-UTC}"
OPENCODE_BIND_PORT="${OPENCODE_BIND_PORT:-4096}"
OPENCODE_CLI_VERSION="${OPENCODE_CLI_VERSION:-latest}"
if [[ -z "${OPENCODE_BIND_ADDR:-}" ]]; then
  case "${TRAEFIK_MODE}" in
    self)
      OPENCODE_BIND_ADDR="0.0.0.0"
      ;;
    *)
      OPENCODE_BIND_ADDR="127.0.0.1"
      ;;
  esac
fi
set_model_defaults
prompt_yes_no ENABLE_GITHUB "Enable GitHub integration for repos and PRs? [Y/n]" "y"

install_docker
sync_project
ensure_host_opencode_scripts_executable
write_env_file
prepare_runtime_dirs
initialize_workspace_structure
resolve_git_identity
setup_github_auth
write_gitconfig
apply_host_git_identity
write_env_file
write_traefik_dynamic_config
install_global_command
ensure_external_edge_network
ensure_ufw_allows_docker_to_host_opencode

install_opencode_cli_global
install_opencode_systemd
cleanup_legacy_docker_opencode
refresh_compose_stack
restart_host_opencode

cat <<EOF

nero is installed.

URL: https://${OPENCODE_DOMAIN}
Username: ${OPENCODE_SERVER_USERNAME}
Model: ${OPENCODE_MODEL}
Proxy mode: ${TRAEFIK_MODE}

Project dir: ${TARGET_DIR}
Workspace dir: ${WORKSPACE_HOST_DIR}
Command: nero
Git author: ${GIT_USER_NAME} <${GIT_USER_EMAIL}>

If you chose OpenAI subscription auth, open the UI and run /connect.
Then select OpenAI -> ChatGPT Plus/Pro to finish login in the browser.

EOF

if [[ "${ENABLE_GITHUB}" == "yes" ]]; then
  cat <<EOF

GitHub integration: enabled
GH config dir: ${TARGET_DIR}/config/gh
SSH key dir: ${TARGET_DIR}/config/ssh

EOF
  if [[ -f "${TARGET_DIR}/config/ssh/id_ed25519.pub" ]]; then
    printf 'GitHub SSH public key:\n'
    ${SUDO} cat "${TARGET_DIR}/config/ssh/id_ed25519.pub"
    printf '\n'
  fi
fi

if [[ "${TRAEFIK_MODE}" == "external" ]]; then
  cat <<EOF

Detected an existing reverse proxy on ports 80/443.
Nero started without its own Traefik and is listening on 127.0.0.1:${OPENCODE_BIND_PORT}.
Point your existing proxy at that local port for ${OPENCODE_DOMAIN}.

EOF
fi
