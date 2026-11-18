#!/usr/bin/env bash

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
  local fetched final_url pem certificate=null
  fetched=$(date -u +%Y-%m-%dT%H:%M:%SZ) || return 1
  final_url=$(jq -er '.url_effective | select(type == "string" and length > 0)' "$curl_metadata") || return 1
  if [[ ${final_url,,} == https://* ]]; then
    if ! pem=$(jq -er '
      select((.num_connects | type) == "number" and (.num_redirects | type) == "number"
             and .num_connects > .num_redirects)
      | .certs
      | capture("(^|\\n)(Cert:)?(?<pem>-----BEGIN CERTIFICATE-----\\r?\\n[A-Za-z0-9+/=\\r\\n]+-----END CERTIFICATE-----)").pem
    ' "$curl_metadata") || ! certificate=$(
      openssl x509 -noout -nameopt RFC2253 -subject -issuer -startdate -enddate -dateopt iso_8601 -sha256 -fingerprint <<< "$pem" |
        jq -eRs '
          [split("\n")[] | capture("^(?<key>[^=]+)=(?<value>.*)$")] | from_entries
          | {
              subject, issuer,
              not_before: (.notBefore | sub(" "; "T")),
              not_after: (.notAfter | sub(" "; "T")),
              sha256_fingerprint: (."sha256 Fingerprint" | gsub(":"; "") | ascii_downcase)
            }
          | select(.sha256_fingerprint | test("^[0-9a-f]{64}$"))
        '
    ); then
      echo "Cannot identify the HTTPS certificate for $final_url" >&2
      return 1
    fi
  fi
  jq -e --arg source "$url" --arg fetched "$fetched" --argjson certificate "$certificate" '
    select((.proxy_used // 0) == 0 and (.remote_ip | type == "string" and length > 0))
    | {source_url:$source, final_url:.url_effective, fetched_at:$fetched,
       connected_peer_ip:.remote_ip, proxy_used:false, tls_certificate:$certificate}
  ' "$curl_metadata" > "$output"
}

copy_if_changed() {
  cmp -s "$1" "$2" || cp "$1" "$2"
}

update_source() {
  local format=$1 name=$2 url=$3 tmp=$4 legacy_state=$5 force_provenance=$6
  local raw meta dest failure legacy_failure now raw_changed=0 list_changed=0 coverage old_ips new_ips old_size=0 new_size provenance changes
  raw="raw-data/$name"; meta="provenance/$name.json"
  dest="lists/$name.json"
  failure="provenance/$name.failure"
  legacy_failure="$legacy_state/${name//\//_}.failure"
  mkdir -p "$(dirname "$raw")" "$(dirname "$meta")" "$(dirname "$dest")" || return 1
  if [[ -f $legacy_failure && ! -f $failure ]]; then
    mv "$legacy_failure" "$failure" || return 1
  fi
  now=$(date -u +%s)
  # A reused connection after redirects can leave curl reporting an earlier peer's certificate.
  if ! curl -q --noproxy '*' --http1.1 --header 'Connection: close' --no-sessionid \
      --fail --location --silent --show-error --max-time 60 --output "$tmp/body" --write-out '%{json}' "$url" > "$tmp/curl.json"; then
    record_download_failure "$name" "$failure" "$now"
    return $?
  fi
  if ! write_provenance "$url" "$tmp/curl.json" "$tmp/meta"; then
    echo "Invalid connection metadata: $name" >&2
    return 1
  fi
  if ! coverage=$(python3 lib/iplist.py "$format" "$tmp/body" "$tmp/result" "$dest"); then
    echo "Validation failed: $name" >&2
    return 1
  fi
  read -r old_ips new_ips <<< "$coverage"
  cmp -s "$tmp/body" "$raw" || raw_changed=1
  cmp -s "$tmp/result" "$dest" || list_changed=1
  if (( raw_changed || list_changed )); then
    [[ ! -f $raw ]] || old_size=$(wc -c < "$raw") || return 1
    new_size=$(wc -c < "$tmp/body") || return 1
  fi
  if (( raw_changed || list_changed || force_provenance )); then
    provenance=$(jq -r '"\(.fetched_at) \(.connected_peer_ip) direct \(.source_url)\(if .final_url != .source_url then " -> \(.final_url)" else "" end)"' "$tmp/meta") || return 1
  fi
  copy_if_changed "$tmp/body" "$raw" && copy_if_changed "$tmp/result" "$dest" || return 1
  if (( raw_changed || list_changed || force_provenance )); then cp "$tmp/meta" "$meta" || return 1; fi
  rm -f "$failure" "$legacy_failure" || return 1
  if (( raw_changed || list_changed )); then
    if (( raw_changed && list_changed )); then changes='raw and list'; elif (( raw_changed )); then changes=raw; else changes=list; fi
    coverage=$(python3 lib/iplist.py --format-coverage "$old_ips" "$new_ips") || return 1
    printf '%s: updated (%s): %s -> %s bytes / %s IPs / %s\n' "$name" "$changes" "$old_size" "$new_size" "$coverage" "$provenance"
  elif (( force_provenance )); then
    printf '%s: updated (provenance): %s\n' "$name" "$provenance"
  else
    printf '%s: no change\n' "$name"
  fi
}

update_main() (
  set -uo pipefail
  cd "$(dirname "${BASH_SOURCE[0]}")" || return 1
  local registry=${REGISTRY_DIR:-registry} legacy_state=${STATE_DIR:-.state}
  local tmp status=0 force_provenance=0 format name url
  if [[ $# == 1 && $1 == --force-update-provenance ]]; then
    force_provenance=1
  elif (( $# )); then
    echo 'Usage: update.sh [--force-update-provenance]' >&2
    return 2
  fi
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' EXIT
  python3 lib/registry.py "$registry" > "$tmp/sources" || status=1
  while IFS=$'\t' read -r format name url; do
    update_source "$format" "$name" "$url" "$tmp" "$legacy_state" "$force_provenance" || status=1
  done < "$tmp/sources" || return 1
  return "$status"
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  update_main "$@"
fi
