#!/usr/bin/env bash
set -euo pipefail

mkdir -p /config/opencode /data/opencode /workspace/agent
mkdir -p /home/node/.config/gh /home/node/.ssh
chmod 700 /home/node/.ssh || true

exec opencode web --hostname 0.0.0.0 --port 4096
