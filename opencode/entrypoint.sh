#!/usr/bin/env bash
set -euo pipefail

mkdir -p /config/opencode /data/opencode /workspace/agent

exec opencode web --hostname 0.0.0.0 --port 4096
