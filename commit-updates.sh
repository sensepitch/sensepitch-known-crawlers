#!/usr/bin/env bash
#
# Commit the files changed by update.sh, one commit per source. See README.md.
#
# Usage: commit-updates.sh [UPDATE_LOG]
#
# UPDATE_LOG is the standard output of update.sh; its line for a source becomes
# that source's commit message. Only changes below raw-data/, lists/ and
# provenance/ are committed. A retrieval failure record is written once and
# kept unchanged while the failure persists, so it is committed when it appears
# and when it is cleared, never in between.

set -euo pipefail
updates=$(cat -- "${1:-/dev/null}")
cd "$(dirname "${BASH_SOURCE[0]}")"

declare -A paths=()
while IFS= read -r -d '' entry; do
  status=${entry:0:2} path=${entry:3}
  sources=("$path")
  # Renames and copies are followed by their original path.
  if [[ $status == [RC]* ]]; then IFS= read -r -d '' original; sources+=("$original"); fi
  for path in "${sources[@]}"; do
    case $path in
      raw-data/*) name=${path#raw-data/} ;;
      lists/*.json) name=${path#lists/}; name=${name%.json} ;;
      provenance/*.json) name=${path#provenance/}; name=${name%.json} ;;
      provenance/*.failure) name=${path#provenance/}; name=${name%.failure} ;;
      *) name= ;;
    esac
    if [[ ! $name =~ ^[^/]+/[^/]+$ ]]; then
      echo "Not committing unexpected path: $path" >&2
      continue
    fi
    paths[$name]+="$path"$'\n'
  done
done < <(git status --porcelain=v1 -z --untracked-files=all -- raw-data lists provenance)

in_head() { git cat-file -e "HEAD:$1" 2>/dev/null; }

commits=0
while IFS= read -r name; do
  [[ -n $name ]] || continue
  mapfile -t files < <(printf '%s' "${paths[$name]}" | sort -u)
  failure="provenance/$name.failure"
  failure_added=0 failure_cleared=0
  if [[ -f $failure ]] && ! in_head "$failure"; then failure_added=1; fi
  if [[ ! -e $failure ]] && in_head "$failure"; then failure_cleared=1; fi
  subject=$(awk -v prefix="$name: updated (" 'index($0, prefix) == 1 { print; exit }' <<< "$updates")
  if [[ -n $subject ]]; then
    (( ! failure_cleared )) || subject+='; retrieval failure cleared'
  elif (( failure_added )); then
    read -r since < "$failure" || since=
    since=$(date -u -d "@$since" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || true
    subject="$name: retrieval failed (since ${since:-unknown})"
  elif (( failure_cleared )); then
    subject="$name: retrieval recovered"
  else
    subject="$name: update"
  fi
  git add -A -- "${files[@]}"
  git commit --quiet -m "$subject" -- "${files[@]}"
  echo "$subject"
  commits=$((commits + 1))
done < <(printf '%s\n' "${!paths[@]}" | LC_ALL=C sort)

echo "$commits commit(s)" >&2
