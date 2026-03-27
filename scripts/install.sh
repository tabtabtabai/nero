#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="nero"
TARGET_DIR="${TARGET_DIR:-/opt/${PROJECT_NAME}}"
SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

DEFAULT_MODEL="openai/gpt-5.4"

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1
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
      prompt_value OPENAI_API_KEY "OpenAI API key" true
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

write_env_file() {
  cat > "${SOURCE_DIR}/.env" <<EOF
PROJECT_NAME=${PROJECT_NAME}
TZ=${TZ:-UTC}

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
    "${TARGET_DIR}/config/opencode" \
    "${TARGET_DIR}/data/opencode" \
    "${TARGET_DIR}/data/traefik" \
    "${TARGET_DIR}/workspace/agent"

  ${SUDO} touch "${TARGET_DIR}/data/traefik/acme.json"
  ${SUDO} chmod 600 "${TARGET_DIR}/data/traefik/acme.json"
}

if [[ -f "${SOURCE_DIR}/.env" ]]; then
  set -a
  . "${SOURCE_DIR}/.env"
  set +a
fi

prompt_value OPENCODE_DOMAIN "OpenCode domain"
prompt_value LETSENCRYPT_EMAIL "Let's Encrypt email"
prompt_value CF_DNS_API_TOKEN "Cloudflare DNS API token" true
prompt_value OPENCODE_SERVER_PASSWORD "OpenCode server password" true

OPENCODE_SERVER_USERNAME="${OPENCODE_SERVER_USERNAME:-opencode}"
TZ="${TZ:-UTC}"
prompt_provider_setup

write_env_file
install_docker
sync_project
prepare_runtime_dirs

${SUDO} docker compose -f "${TARGET_DIR}/compose.yaml" --env-file "${TARGET_DIR}/.env" up -d --build

cat <<EOF

nero is installed.

URL: https://${OPENCODE_DOMAIN}
Username: ${OPENCODE_SERVER_USERNAME}
Model: ${OPENCODE_MODEL}

Project dir: ${TARGET_DIR}
Workspace dir: ${TARGET_DIR}/workspace/agent

EOF
