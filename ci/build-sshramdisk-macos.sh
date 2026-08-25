#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/ci/build-sshramdisk-macos-v2.sh"

if [ ! -f "$SCRIPT" ]; then
    echo "[!] Missing builder: $SCRIPT" >&2
    exit 1
fi

chmod +x "$SCRIPT"
exec /bin/bash "$SCRIPT"