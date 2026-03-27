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

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"

install_oh_my_zsh() {
  local user="$1"
  local home_dir="$2"

  if [[ "${user}" == "root" || ! -d "${home_dir}" ]]; then
    return
  fi

  if [[ ! -d "${home_dir}/.oh-my-zsh" ]]; then
    su - "${user}" -c "RUNZSH=no CHSH=yes KEEP_ZSHRC=yes sh -c '\$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)' ''" || true
  fi

  if command -v zsh >/dev/null 2>&1; then
    chsh -s "$(command -v zsh)" "${user}" || true
  fi
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

install -m 0755 -d /etc/apt/keyrings

if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi

arch="$(dpkg --print-architecture)"
codename="$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")"

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
systemctl start docker

ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

install_oh_my_zsh "${TARGET_USER}" "${TARGET_HOME}"

printf '\nUbuntu 24.04 bootstrap complete.\n'
printf 'Installed: Docker Engine, Docker Compose plugin, gh, git, curl, rsync, nano, ufw, zsh, Oh My Zsh.\n'
printf 'Firewall: OpenSSH, 80/tcp, and 443/tcp allowed.\n'
printf 'Next: cp .env.example .env && ./nero install\n'
