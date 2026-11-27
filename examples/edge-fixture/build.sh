#!/usr/bin/env bash
# Rebuild the fixture tier ZIPs with the unchanged release code. The release
# runs in a throwaway Git repository whose single commit has a fixed author,
# date and message, so meta.json and the ZIP bytes are reproducible.
set -euo pipefail
fixture=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
release=$fixture/../../lib/release.py
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cp -r "$fixture/registry" "$fixture/lists" "$work/"
cd "$work"
git init -q
GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' \
  git -c user.name=Fixture -c user.email=fixture@example.com -c commit.gpgsign=false \
  commit -q --allow-empty -m 'sensepitch-known-crawlers edge fixture'
python3 "$release" registry output
for tier in 1 2 3; do
  cp output/sensepitch-known-crawlers-tier$tier.zip "$fixture/"
done
