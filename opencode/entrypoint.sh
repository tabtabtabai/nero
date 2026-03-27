#!/usr/bin/env bash
set -euo pipefail

mkdir -p /config/opencode /data/opencode /workspace/agent
mkdir -p /home/opencode/.config/gh /home/opencode/.ssh
chmod 700 /home/opencode/.ssh || true

exec opencode web --hostname 0.0.0.0 --port 4096
