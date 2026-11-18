#!/usr/bin/env bash

valid_source() {
  local format=$1 name=$2 url=$3
  [[ $name =~ ^[a-z0-9-]+/[a-z0-9-]+$ && $format =~ ^(text|json|fastly|ahrefs)$ && $url == https://* ]]
}

record_download_failure() {
  local name=$1 failure=$2 now=$3 first
  [[ -f $failure ]] || printf '%s\n' "$now" > "$failure"
  read -r first < "$failure"
  [[ $first =~ ^[0-9]+$ ]] || { echo "Invalid failure timestamp: $failure" >&2; return 1; }
  echo "Download failed: $name (since $first)" >&2
  (( now - first < 86400 ))
}

write_provenance() {
  local url=$1 curl_metadata=$2 output=$3
  jq --arg source "$url" --arg fetched "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{source_url:$source, final_url:.url_effective, fetched_at:$fetched, connected_peer_ip:.remote_ip, proxy_used:(if has("proxy_used") then .proxy_used != 0 else null end)}' "$curl_metadata" > "$output"
}

copy_if_changed() {
  cmp -s "$1" "$2" || cp "$1" "$2"
}

update_source() {
  local format=$1 name=$2 url=$3 tmp=$4 legacy_state=$5
  local raw meta dest failure legacy_failure now data_changed=1 coverage old_ips new_ips old_size=0 new_size provenance
  if ! valid_source "$format" "$name" "$url"; then
    echo "Invalid source: $name" >&2
    return 1
  fi
  raw="other/raw/$name"; meta="other/provenance/$name.json"
  if [[ $format == json ]]; then dest="json/$name.json"; else dest="other/json/$name.json"; fi
  failure="other/provenance/$name.failure"
  legacy_failure="$legacy_state/${name//\//_}.failure"
  mkdir -p "$(dirname "$raw")" "$(dirname "$meta")" "$(dirname "$dest")" || return 1
  if [[ -f $legacy_failure && ! -f $failure ]]; then
    mv "$legacy_failure" "$failure" || return 1
  fi
  now=$(date -u +%s)
  if ! curl --fail --location --silent --show-error --max-time 60 --output "$tmp/body" --write-out '%{json}' "$url" > "$tmp/curl.json"; then
    record_download_failure "$name" "$failure" "$now"
    return $?
  fi
  if ! coverage=$(python3 lib/iplist.py "$format" "$tmp/body" "$tmp/result" "$dest"); then
    echo "Validation failed: $name" >&2
    return 1
  fi
  read -r old_ips new_ips <<< "$coverage"
  if cmp -s "$tmp/body" "$raw" && cmp -s "$tmp/result" "$dest"; then
    data_changed=0
  else
    [[ ! -f $raw ]] || old_size=$(wc -c < "$raw") || return 1
    new_size=$(wc -c < "$tmp/body") || return 1
    write_provenance "$url" "$tmp/curl.json" "$tmp/meta" || return 1
    provenance=$(jq -r '"\(.fetched_at) \(.connected_peer_ip) \(if .proxy_used == true then "via proxy" elif .proxy_used == false then "direct" else "proxy unknown" end) \(.source_url) -> \(.final_url)"' "$tmp/meta") || return 1
  fi
  copy_if_changed "$tmp/body" "$raw" && copy_if_changed "$tmp/result" "$dest" || return 1
  if (( data_changed )); then cp "$tmp/meta" "$meta" || return 1; fi
  rm -f "$failure" "$legacy_failure" || return 1
  if (( data_changed )); then
    printf '%s: updated: %s -> %s bytes / %s -> %s IPs / %s\n' "$name" "$old_size" "$new_size" "$old_ips" "$new_ips" "$provenance"
  else
    printf '%s: no change\n' "$name"
  fi
}

update_main() (
  set -uo pipefail
  cd "$(dirname "${BASH_SOURCE[0]}")" || return 1
  local registry=${SOURCES_FILE:-sources.tsv} legacy_state=${STATE_DIR:-.state}
  local tmp status=0 format name url
  mkdir -p other/raw other/provenance json other/json || return 1
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' EXIT
  while read -r format name url; do
    [[ -z $format || $format == \#* ]] && continue
    update_source "$format" "$name" "$url" "$tmp" "$legacy_state" || status=1
  done < "$registry" || return 1
  return "$status"
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  update_main "$@"
fi
