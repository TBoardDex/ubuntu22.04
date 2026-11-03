#!/bin/bash
# Standalone Ubuntu rootfs entry; build.sh also packs the ext4 image.
set -euo pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
exec "$SCRIPT_DIR/build.sh" "$@"
