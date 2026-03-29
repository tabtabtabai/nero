#!/usr/bin/env bash
set -euo pipefail

mkdir -p /config/opencode /data/opencode /workspace
mkdir -p /home/node/.config/gh /home/node/.ssh

exec opencode web --hostname 0.0.0.0 --port 4096
