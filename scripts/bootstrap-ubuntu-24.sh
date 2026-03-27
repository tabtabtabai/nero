#!/usr/bin/env bash
set -euo pipefail

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
else
  printf 'Cannot detect operating system.\n' >&2
  exit 1
fi

if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
  printf 'This script is intended for Ubuntu 24.04. Detected %s %s.\n' "${ID:-unknown}" "${VERSION_ID:-unknown}" >&2
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  printf 'Please run this script as root: sudo bash scripts/bootstrap-ubuntu-24.sh\n' >&2
  exit 1
fi

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/docker-ubuntu.sh"

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
ZSH_BIN="$(command -v zsh || true)"

install_oh_my_zsh() {
  local user="$1"
  local home_dir="$2"

  if [[ -z "${home_dir}" || ! -d "${home_dir}" ]]; then
    return
  fi

  if [[ ! -d "${home_dir}/.oh-my-zsh" ]]; then
    if [[ "${user}" == "root" ]]; then
      RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" '' || true
    else
      su - "${user}" -c "RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c '\$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)' ''" || true
    fi
  fi

  if [[ -n "${ZSH_BIN}" ]]; then
    chsh -s "${ZSH_BIN}" "${user}" || true
  fi
}

launch_default_shell() {
  if [[ ! -t 0 || ! -t 1 || "${NERO_AUTO_SHELL:-1}" != "1" || -z "${ZSH_BIN}" ]]; then
    return
  fi

  printf 'Launching zsh for %s...\n' "${TARGET_USER}"

  if [[ "${TARGET_USER}" == "root" ]]; then
    exec "${ZSH_BIN}" -l
  fi

  exec su - "${TARGET_USER}"
}

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get upgrade -y
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  gh \
  git \
  gnupg \
  lsb-release \
  nano \
  openssl \
  rsync \
  software-properties-common \
  tar \
  ufw \
  zsh

install_or_update_docker_ubuntu

ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

install_oh_my_zsh "${TARGET_USER}" "${TARGET_HOME}"

printf '\nUbuntu 24.04 bootstrap complete.\n'
printf 'Installed: Docker Engine, Docker Compose plugin, gh, git, curl, rsync, nano, ufw, zsh, Oh My Zsh.\n'
printf 'Firewall: OpenSSH, 80/tcp, and 443/tcp allowed.\n'
printf 'Next: cp .env.example .env && ./nero install\n'

launch_default_shell
