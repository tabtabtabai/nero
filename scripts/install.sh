#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="nero"
TARGET_DIR="${TARGET_DIR:-/opt/${PROJECT_NAME}}"
SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

DEFAULT_MODEL="openai/gpt-5.4"
OPENCODE_UID="1000"
OPENCODE_GID="1000"

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

port_in_use() {
  local port="$1"
  ss -tuln | grep -Eq ":${port}[[:space:]]"
}

detect_proxy_mode() {
  if port_in_use 80 || port_in_use 443; then
    TRAEFIK_MODE="external"
  else
    TRAEFIK_MODE="self"
  fi
}

compose_up() {
  if [[ "${TRAEFIK_MODE}" == "self" ]]; then
    ${SUDO} docker compose -f "${TARGET_DIR}/compose.yaml" --env-file "${TARGET_DIR}/.env" --profile self-proxy up -d --build
    return
  fi

  ${SUDO} docker compose -f "${TARGET_DIR}/compose.yaml" --env-file "${TARGET_DIR}/.env" up -d --build
}

install_global_command() {
  ${SUDO} ln -sf "${TARGET_DIR}/nero" /usr/local/bin/nero
  ${SUDO} chmod +x "${TARGET_DIR}/nero"
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

clear_unused_provider_envs() {
  local selected_provider="$1"

  case "${selected_provider}" in
    openai)
      ANTHROPIC_API_KEY=""
      OPENROUTER_API_KEY=""
      ;;
    anthropic)
      OPENAI_API_KEY=""
      OPENROUTER_API_KEY=""
      ;;
    openrouter)
      OPENAI_API_KEY=""
      ANTHROPIC_API_KEY=""
      ;;
  esac

  GEMINI_API_KEY=""
  GITHUB_TOKEN=""
  LOCAL_ENDPOINT=""
}

prompt_provider_setup() {
  local provider_choice=""
  local current_model=""
  local model_input=""
  local openai_auth_choice=""

  printf '\n'
  printf 'Choose initial model provider:\n'
  printf '  1) OpenAI (recommended, GPT 5.4)\n'
  printf '  2) Anthropic\n'
  printf '  3) OpenRouter\n'
  read -r -p 'Provider [1]: ' provider_choice

  case "${provider_choice:-1}" in
    1)
      clear_unused_provider_envs openai
      current_model="${OPENCODE_MODEL:-$DEFAULT_MODEL}"
      read -r -p "Model [${current_model}]: " model_input
      OPENCODE_MODEL="${model_input:-$current_model}"
      printf 'OpenAI auth method:\n'
      printf '  1) ChatGPT Plus/Pro subscription via /connect (recommended)\n'
      printf '  2) API key\n'
      read -r -p 'Auth [1]: ' openai_auth_choice
      case "${openai_auth_choice:-1}" in
        1)
          OPENAI_API_KEY=""
          ;;
        2)
          prompt_value OPENAI_API_KEY "OpenAI API key" true
          ;;
        *)
          printf 'Invalid OpenAI auth selection.\n' >&2
          exit 1
          ;;
      esac
      ;;
    2)
      clear_unused_provider_envs anthropic
      current_model="${OPENCODE_MODEL:-anthropic/claude-sonnet-4-5}"
      read -r -p "Model [${current_model}]: " model_input
      OPENCODE_MODEL="${model_input:-$current_model}"
      prompt_value ANTHROPIC_API_KEY "Anthropic API key" true
      ;;
    3)
      clear_unused_provider_envs openrouter
      current_model="${OPENCODE_MODEL:-openrouter/openai/gpt-5.4}"
      read -r -p "Model [${current_model}]: " model_input
      OPENCODE_MODEL="${model_input:-$current_model}"
      prompt_value OPENROUTER_API_KEY "OpenRouter API key" true
      ;;
    *)
      printf 'Invalid provider selection.\n' >&2
      exit 1
      ;;
  esac
}

write_gitconfig() {
  ${SUDO} mkdir -p "${TARGET_DIR}/config/git"
  ${SUDO} tee "${TARGET_DIR}/config/git/.gitconfig" >/dev/null <<EOF
[user]
  name = ${GIT_USER_NAME}
  email = ${GIT_USER_EMAIL}

[credential "https://github.com"]
  helper =
  helper = !/usr/bin/gh auth git-credential
EOF
  ${SUDO} chown "${OPENCODE_UID}:${OPENCODE_GID}" "${TARGET_DIR}/config/git/.gitconfig"
  ${SUDO} chmod 600 "${TARGET_DIR}/config/git/.gitconfig"
}

setup_github_auth() {
  local gh_config_dir="${TARGET_DIR}/config/gh"
  local github_auth_choice=""

  if [[ "${ENABLE_GITHUB}" != "yes" ]]; then
    GITHUB_TOKEN=""
    GIT_USER_NAME="${GIT_USER_NAME:-}"
    GIT_USER_EMAIL="${GIT_USER_EMAIL:-}"
    return
  fi

  prompt_value GIT_USER_NAME "Git author name"
  prompt_value GIT_USER_EMAIL "Git author email"

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

  prompt_yes_no GITHUB_SSH_KEY "Generate GitHub SSH key for this VM? [Y/n]" "y"

  ${SUDO} mkdir -p "${TARGET_DIR}/config/gh" "${TARGET_DIR}/config/ssh"
  ${SUDO} chown -R "${OPENCODE_UID}:${OPENCODE_GID}" "${TARGET_DIR}/config/gh" "${TARGET_DIR}/config/ssh"
  ${SUDO} chmod 700 "${TARGET_DIR}/config/ssh"

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    if ! need_cmd gh; then
      printf 'gh CLI is required for GitHub auth setup. Run ./nero bootstrap first.\n' >&2
      exit 1
    fi
    printf '%s\n' "${GITHUB_TOKEN}" | ${SUDO} env GH_CONFIG_DIR="${gh_config_dir}" gh auth login --hostname github.com --git-protocol https --with-token >/dev/null
    ${SUDO} chown -R "${OPENCODE_UID}:${OPENCODE_GID}" "${gh_config_dir}"
  fi

  if [[ "${GITHUB_SSH_KEY}" == "yes" && ! -f "${TARGET_DIR}/config/ssh/id_ed25519" ]]; then
    ${SUDO} ssh-keygen -t ed25519 -N "" -C "nero@$(hostname)" -f "${TARGET_DIR}/config/ssh/id_ed25519" >/dev/null
    ${SUDO} chown -R "${OPENCODE_UID}:${OPENCODE_GID}" "${TARGET_DIR}/config/ssh"
    ${SUDO} chmod 600 "${TARGET_DIR}/config/ssh/id_ed25519"
    ${SUDO} chmod 644 "${TARGET_DIR}/config/ssh/id_ed25519.pub"
  fi

  write_gitconfig
}

write_env_file() {
  cat > "${SOURCE_DIR}/.env" <<EOF
PROJECT_NAME=${PROJECT_NAME}
TZ=${TZ:-UTC}
TRAEFIK_MODE=${TRAEFIK_MODE}
OPENCODE_BIND_PORT=${OPENCODE_BIND_PORT:-4096}

OPENCODE_DOMAIN=${OPENCODE_DOMAIN}
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
CF_DNS_API_TOKEN=${CF_DNS_API_TOKEN}

OPENCODE_SERVER_USERNAME=${OPENCODE_SERVER_USERNAME:-opencode}
OPENCODE_SERVER_PASSWORD=${OPENCODE_SERVER_PASSWORD}
OPENCODE_MODEL=${OPENCODE_MODEL}

ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
OPENAI_API_KEY=${OPENAI_API_KEY:-}
GEMINI_API_KEY=${GEMINI_API_KEY:-}
OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-}
GITHUB_TOKEN=${GITHUB_TOKEN:-}
LOCAL_ENDPOINT=${LOCAL_ENDPOINT:-}
EOF
}

install_docker() {
  if need_cmd docker && docker compose version >/dev/null 2>&1; then
    return
  fi

  curl -fsSL https://get.docker.com | sh
}

sync_project() {
  ${SUDO} mkdir -p "${TARGET_DIR}"

  if [[ "${SOURCE_DIR}" == "${TARGET_DIR}" ]]; then
    return
  fi

  tar \
    --exclude='.git' \
    --exclude='.env' \
    --exclude='data' \
    --exclude='workspace' \
    -cf - -C "${SOURCE_DIR}" . | ${SUDO} tar -xf - -C "${TARGET_DIR}"

  if [[ -f "${SOURCE_DIR}/.env" ]]; then
    ${SUDO} cp "${SOURCE_DIR}/.env" "${TARGET_DIR}/.env"
  fi
}

prepare_runtime_dirs() {
  ${SUDO} mkdir -p \
    "${TARGET_DIR}/config/gh" \
    "${TARGET_DIR}/config/git" \
    "${TARGET_DIR}/config/opencode" \
    "${TARGET_DIR}/config/ssh" \
    "${TARGET_DIR}/data/opencode" \
    "${TARGET_DIR}/data/traefik" \
    "${TARGET_DIR}/workspace/agent"

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
    "${TARGET_DIR}/workspace/agent"
  ${SUDO} chmod 700 "${TARGET_DIR}/config/ssh"
}

if [[ -f "${SOURCE_DIR}/.env" ]]; then
  set -a
  . "${SOURCE_DIR}/.env"
  set +a
fi

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
prompt_provider_setup
prompt_yes_no ENABLE_GITHUB "Enable GitHub integration for repos and PRs? [Y/n]" "y"

install_docker
sync_project
prepare_runtime_dirs
setup_github_auth
write_env_file
install_global_command

compose_up

cat <<EOF

nero is installed.

URL: https://${OPENCODE_DOMAIN}
Username: ${OPENCODE_SERVER_USERNAME}
Model: ${OPENCODE_MODEL}
Proxy mode: ${TRAEFIK_MODE}

Project dir: ${TARGET_DIR}
Workspace dir: ${TARGET_DIR}/workspace/agent
Command: nero

If you chose OpenAI subscription auth, open the UI and run /connect.
Then select OpenAI -> ChatGPT Plus/Pro to finish login in the browser.

EOF

if [[ "${ENABLE_GITHUB}" == "yes" ]]; then
  cat <<EOF

GitHub integration: enabled
Git author: ${GIT_USER_NAME} <${GIT_USER_EMAIL}>
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
