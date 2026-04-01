#!/usr/bin/env bash
set -euo pipefail

install_or_update_docker_ubuntu() {
  if [[ ! -f /etc/os-release ]]; then
    printf 'Cannot detect operating system.\n' >&2
    return 1
  fi

  . /etc/os-release

  if [[ "${ID:-}" != "ubuntu" ]]; then
    printf 'Automatic Docker setup currently supports Ubuntu only.\n' >&2
    return 1
  fi

  export DEBIAN_FRONTEND=noninteractive

  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl gnupg

  install -m 0755 -d /etc/apt/keyrings

  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi

  local arch
  local codename
  arch="$(dpkg --print-architecture)"
  codename="${VERSION_CODENAME}"

  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable
EOF

  apt-get update
  apt-get install -y --no-install-recommends \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  systemctl enable docker
  systemctl restart docker
}

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
  printf 'Please run this script as root.\n' >&2
  exit 1
fi

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
  jq \
  lsb-release \
  nano \
  openssl \
  rsync \
  software-properties-common \
  sqlite3 \
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
printf 'Installed: Docker Engine, Docker Compose plugin, gh, git, curl, jq, rsync, nano, sqlite3, ufw, zsh, Oh My Zsh.\n'
printf 'Firewall: OpenSSH, 80/tcp, and 443/tcp allowed.\n'
printf 'Next: curl -fsSL https://raw.githubusercontent.com/PatrickRogg/nero/main/scripts/install-remote.sh -o /tmp/install-remote.sh && bash /tmp/install-remote.sh\n'

launch_default_shell
