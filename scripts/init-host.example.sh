#!/usr/bin/env bash
set -euo pipefail

# Nero copies this template to scripts/init-host.local.sh on first install.
# Keep the local file safe to rerun because Nero executes it on install/update.

printf 'Nero host init: nothing custom configured yet.\n'
printf 'Edit %s/scripts/init-host.local.sh to add host-specific setup.\n' "${TARGET_DIR:-$(pwd)}"
