#!/usr/bin/env bash
# Build one edge proxy ZIP per tier under output/.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
if (( $# )); then
  echo 'Usage: release.sh' >&2
  exit 2
fi
exec python3 lib/release.py "${REGISTRY_DIR:-registry}" output
