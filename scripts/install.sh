#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="nero"
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
OPENCODE_UID="1000"
OPENCODE_GID="1000"
INIT_SCRIPT_LOCAL_RELATIVE_PATH="scripts/init-host.local.sh"

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

port_in_use() {
  local port="$1"
  ss -tuln | grep -Eq ":${port}[[:space:]]"
}

detect_proxy_mode() {
  case "${TRAEFIK_MODE:-external}" in
    self|external)
      TRAEFIK_MODE="${TRAEFIK_MODE:-external}"
      return
      ;;
    auto)
      ;;
    *)
      TRAEFIK_MODE="external"
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
  # Stack definition: compose file + env (paths under TARGET_DIR after sync/write).
  sha256sum "${TARGET_DIR}/compose.yaml" "${TARGET_DIR}/.env" 2>/dev/null | sha256sum | awk '{print $1}'
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

compose_down() {
  ${SUDO} docker compose -f "${TARGET_DIR}/compose.yaml" --env-file "${TARGET_DIR}/.env" --profile self-proxy down --remove-orphans || true
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
          - url: http://${PROJECT_NAME}-opencode:4096
EOF
}

migrate_legacy_agent_workspace() {
  local base="${TARGET_DIR}/workspace"
  if [[ -d "${base}/agent" && ! -d "${base}/agents" ]]; then
    ${SUDO} mv "${base}/agent" "${base}/agents"
  fi
}

initialize_workspace_structure() {
  local template_root="${SOURCE_DIR}/templates/workspace"
  local workspace_root="${TARGET_DIR}/workspace/agents"

  migrate_legacy_agent_workspace

  ${SUDO} mkdir -p "${workspace_root}"

  if [[ ! -d "${template_root}" ]]; then
    return
  fi

  ${SUDO} cp -an "${template_root}/." "${workspace_root}/"
  ${SUDO} chmod +x "${workspace_root}/scripts/defaults/"*.sh 2>/dev/null || true
  ${SUDO} chown -R "${OPENCODE_UID}:${OPENCODE_GID}" "${workspace_root}"
}

run_workspace_setup() {
  if [[ "${SKIP_WORKSPACE_SETUP:-}" == "1" ]]; then
    printf 'Skipping workspace setup (SKIP_WORKSPACE_SETUP=1).\n'
    return
  fi

  local workspace_root="${TARGET_DIR}/workspace/agents"
  local script_path="${WORKSPACE_SETUP_SCRIPT:-${TARGET_DIR}/scripts/workspace-setup.sh}"

  [[ -f "${script_path}" ]] || return 0

  printf '\nRunning workspace setup script: %s\n' "${script_path}"

  local git_config_global="${TARGET_DIR}/config/git/.gitconfig"
  local ssh_dir="${TARGET_DIR}/config/ssh"
  local gh_config_dir="${TARGET_DIR}/config/gh"

  local -a envargs=(
    WORKSPACE_ROOT="${workspace_root}"
    NERO_PROJECT_DIR="${TARGET_DIR}"
    NERO_SOURCE_DIR="${SOURCE_DIR}"
    NERO_SSH_DIR="${ssh_dir}"
    NERO_GIT_CONFIG="${git_config_global}"
    GH_CONFIG_DIR="${gh_config_dir}"
    PATH="${PATH}"
    HOME="${workspace_root}"
  )
  if [[ -f "${git_config_global}" ]]; then
    envargs+=(GIT_CONFIG_GLOBAL="${git_config_global}")
  fi
  if [[ -f "${ssh_dir}/id_ed25519" ]]; then
    envargs+=(GIT_SSH_COMMAND="ssh -i ${ssh_dir}/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new")
  fi

  local -a runas=()
  if getent passwd "${OPENCODE_UID}" >/dev/null 2>&1; then
    if [[ "${EUID}" -eq "${OPENCODE_UID}" ]]; then
      runas=()
    elif command -v sudo >/dev/null 2>&1; then
      runas=(sudo -u "#${OPENCODE_UID}")
    else
      printf 'Warning: sudo not found; running workspace setup as the invoking user.\n' >&2
    fi
  else
    printf 'Warning: no passwd entry for UID %s; running workspace setup as the invoking user.\n' "${OPENCODE_UID}" >&2
  fi

  "${runas[@]}" env "${envargs[@]}" \
    bash -s -- "${script_path}" <<'EOS'
set -euo pipefail
cd "${WORKSPACE_ROOT}"
script="$1"
if [[ -x "${script}" ]]; then
  exec "${script}"
else
  exec bash "${script}"
fi
EOS

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

# Container-only bind-mount does not affect `git` on the host (e.g. ssh as root in the repo).
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

WORKSPACE_SETUP_SCRIPT=$(shell_escape "${WORKSPACE_SETUP_SCRIPT:-}")
SKIP_WORKSPACE_SETUP=$(shell_escape "${SKIP_WORKSPACE_SETUP:-}")
EOF

  if [[ "${TARGET_DIR}" != "${SOURCE_DIR}" ]]; then
    ${SUDO} cp "${SOURCE_DIR}/.env" "${TARGET_DIR}/.env"
  fi
}

run_init_script() {
  local init_script="${TARGET_DIR}/${INIT_SCRIPT_LOCAL_RELATIVE_PATH}"

  if [[ ! -f "${init_script}" ]]; then
    return
  fi

  printf 'Running init script: %s\n' "${init_script}"
  ${SUDO} env \
    TARGET_DIR="${TARGET_DIR}" \
    SOURCE_DIR="${SOURCE_DIR}" \
    PROJECT_NAME="${PROJECT_NAME}" \
    bash "${init_script}"
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
    "${TARGET_DIR}/workspace/agents"

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
    "${TARGET_DIR}/workspace/agents"
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

detect_proxy_mode

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
set_model_defaults
prompt_yes_no ENABLE_GITHUB "Enable GitHub integration for repos and PRs? [Y/n]" "y"

install_docker
sync_project
write_env_file
prepare_runtime_dirs
initialize_workspace_structure
resolve_git_identity
setup_github_auth
write_gitconfig
apply_host_git_identity
run_workspace_setup
write_env_file
run_init_script
write_traefik_dynamic_config
install_global_command

refresh_compose_stack

cat <<EOF

nero is installed.

URL: https://${OPENCODE_DOMAIN}
Username: ${OPENCODE_SERVER_USERNAME}
Model: ${OPENCODE_MODEL}
Proxy mode: ${TRAEFIK_MODE}

Project dir: ${TARGET_DIR}
Workspace dir: ${TARGET_DIR}/workspace/agents
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
