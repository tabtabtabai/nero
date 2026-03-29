#!/usr/bin/env bash
set -euo pipefail

REPO_SLUG="${NERO_REPO_SLUG:-PatrickRogg/nero}"
REF="${NERO_REF:-main}"
TARGET_DIR="${TARGET_DIR:-/opt/nero}"
COMMAND="${1:-install}"

usage() {
  cat <<EOF
Usage: install-remote.sh [install|update]

Downloads the latest Nero source archive from GitHub and runs the installer.

Environment overrides:
  NERO_REPO_SLUG  GitHub owner/repo (default: PatrickRogg/nero)
  NERO_REF        Git ref to download (default: main)
  TARGET_DIR      Install directory (default: /opt/nero)
EOF
}

case "${COMMAND}" in
  install|update)
    ;;
  help|-h|--help)
    usage
    exit 0
    ;;
  *)
    printf 'Unknown command: %s\n\n' "${COMMAND}" >&2
    usage >&2
    exit 1
    ;;
esac

if [[ ! -t 0 ]]; then
  if [[ -r /dev/tty ]]; then
    exec < /dev/tty
  else
    printf 'Nero install requires an interactive terminal for onboarding prompts.\n' >&2
    exit 1
  fi
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

for cmd in curl tar mktemp; do
  if ! need_cmd "${cmd}"; then
    printf 'Missing required command: %s\n' "${cmd}" >&2
    exit 1
  fi
done

ARCHIVE_URL="https://codeload.github.com/${REPO_SLUG}/tar.gz/refs/heads/${REF}"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

printf '%s Nero from %s (%s)\n' "$( [[ "${COMMAND}" == "update" ]] && printf 'Updating' || printf 'Installing' )" "${REPO_SLUG}" "${REF}"

curl -fsSL "${ARCHIVE_URL}" | tar -xzf - --strip-components=1 -C "${TMP_DIR}"

if [[ ! -f "${TMP_DIR}/scripts/install.sh" ]]; then
  printf 'Downloaded archive is missing scripts/install.sh\n' >&2
  exit 1
fi

export NERO_REMOTE_COMMAND="${COMMAND}"
TARGET_DIR="${TARGET_DIR}" bash "${TMP_DIR}/scripts/install.sh"
