#!/usr/bin/env bash
# Build dist/sensepitch-verified-ips-tier<N>-<version>.zip for each tier and
# dist/sensepitch-verified-ips-all-tiers-<version>.zip with every tier from the committed lists.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
if (( $# > 1 )); then
  echo 'Usage: release.sh [YYYY.MM.DD[.N]]' >&2
  exit 2
fi
version=${1:-$(date -u +%Y.%m.%d)}
exec python3 lib/release.py "${REGISTRY_DIR:-registry}" "$version" dist
