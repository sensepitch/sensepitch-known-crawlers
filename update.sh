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
  final_url=$(jq -er '.transfer.url_effective | select(type == "string" and length > 0)' "$curl_metadata") || return 1
  if [[ ${final_url,,} == https://* ]]; then
    if ! pem=$(jq -er '
      .transfer
      | select((.num_connects | type) == "number" and (.num_redirects | type) == "number"
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
    (.headers | objects | del(."set-cookie", ."set-cookie2")) as $headers
    | .transfer
    | select((.proxy_used // 0) == 0 and (.remote_ip | type == "string" and length > 0))
    | {source_url:$source, final_url:.url_effective, fetched_at:$fetched,
       connected_peer_ip:.remote_ip, proxy_used:false, tls_certificate:$certificate, headers:$headers}
  ' "$curl_metadata" > "$output"
}

body_sha256() {
  local digest
  digest=$(openssl dgst -sha256 -r < "$1") || return 1
  printf '%s\n' "${digest%% *}"
}

saved_validator() {
  jq -er --arg url "$1" '
    def singleton: arrays | select(length == 1) | .[0] | strings;
    select(.source_url == $url)
    | (.headers.etag | singleton | select(test("^(W/)?\"[!#-~\\u0080-\\u00ff]*\"\\z"))) as $etag
    | "If-None-Match: \($etag)"
  ' "$2" 2>/dev/null ||
    LC_ALL=C jq -er --arg url "$1" '
      select(.source_url == $url)
      | .headers["last-modified"] | arrays | select(length == 1) | .[0] | strings
      | select(test("^[A-Za-z]{3}, [0-9]{2} [A-Za-z]{3} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT\\z"))
      | select(try (strptime("%a, %d %b %Y %H:%M:%S GMT") | true) catch false)
      | "If-Modified-Since: \(.)"
    ' "$2" 2>/dev/null
}

download_source() {
  local url=$1 tmp=$2 deadline=$3 cached_url=$4 validator=$5
  local status redirect remaining redirects=0
  local -a conditional
  # Follow each hop separately so validators reach only the resource they describe.
  while (( redirects <= 50 )); do
    remaining=$((deadline - SECONDS))
    (( remaining > 0 )) || return 1
    conditional=()
    if [[ $url == "$cached_url" && -n $validator ]]; then conditional=(--header "$validator"); fi
    : > "$tmp/body" || return 1
    curl -q --noproxy '*' --http1.1 --header 'Connection: close' --no-sessionid \
      --proto '=http,https' --globoff --fail --silent --show-error --max-time "$remaining" \
      --output "$tmp/body" --write-out '{"transfer":%{json},"headers":%{header_json}}' \
      "${conditional[@]}" -- "$url" > "$tmp/curl.json" || return 1
    status=$(jq -er '.transfer.response_code | numbers' "$tmp/curl.json") || return 1
    case $status in
      200) printf '%s\n' "$status"; return 0 ;;
      304)
        if (( ${#conditional[@]} )) &&
          jq -e --arg url "$cached_url" '.transfer.url_effective == $url' "$tmp/curl.json" >/dev/null; then
          printf '%s\n' "$status"
          return 0
        fi
        return 1 ;;
      300|301|302|303|307|308)
        redirect=$(jq -er '.transfer.redirect_url | strings | select(length > 0)' "$tmp/curl.json") || return 1
        url=$redirect
        redirects=$((redirects + 1)) ;;
      *) return 1 ;;
    esac
  done
  return 1
}

file_metadata_matches() {
  jq -se '
    # Compare content identity only: some publishers rotate validators for
    # identical bodies (random ETags, per-server Last-Modified).
    def metadata:
      {source_url, final_url, size_bytes, body_sha256, has_headers: (.headers | type == "object")};
    length == 2 and ((.[0] | metadata) == (.[1] | metadata))
  ' "$1" "$2" >/dev/null 2>&1
}

update_source() {
  local format=$1 name=$2 url=$3 volatile_raw=$4 tmp=$5 legacy_state=$6 force_provenance=$7
  local raw meta dest failure legacy_failure now raw_changed=0 list_changed=0 coverage old_ips new_ips old_size=0 new_size provenance changes
  local validator= cached_url= cached_sha= status deadline body observed refresh=0 digest
  raw="raw-data/$name"; meta="provenance/$name.json"
  dest="lists/$name.json"
  failure="provenance/$name.failure"
  legacy_failure="$legacy_state/${name//\//_}.failure"
  mkdir -p "$(dirname "$raw")" "$(dirname "$meta")" "$(dirname "$dest")" || return 1
  if [[ -f $legacy_failure && ! -f $failure ]]; then
    mv "$legacy_failure" "$failure" || return 1
  fi
  now=$(date -u +%s)
  deadline=$((SECONDS + 60))
  if (( ! force_provenance )) && [[ -f $raw && -f $dest && -f $meta ]] &&
    validator=$(saved_validator "$url" "$meta") &&
    cached_sha=$(jq -er '.body_sha256 | strings | select(test("^[0-9a-f]{64}\\z"))' "$meta" 2>/dev/null) &&
    digest=$(body_sha256 "$raw") && [[ $digest == "$cached_sha" ]]; then
    cached_url=$(jq -er '.final_url | strings' "$meta" 2>/dev/null) || cached_url=
  fi
  if ! status=$(download_source "$url" "$tmp" "$deadline" "$cached_url" "$validator"); then
    record_download_failure "$name" "$failure" "$now"
    return $?
  fi
  body="$tmp/body"
  if [[ $status == 304 ]]; then
    if [[ -f $raw && -f $dest ]] && cp "$raw" "$tmp/cached-body" &&
      digest=$(body_sha256 "$tmp/cached-body") && [[ $digest == "$cached_sha" ]]; then
      body="$tmp/cached-body"
    elif ! status=$(download_source "$url" "$tmp" "$deadline" '' ''); then
      record_download_failure "$name" "$failure" "$now"
      return $?
    fi
  fi
  if ! write_provenance "$url" "$tmp/curl.json" "$tmp/meta"; then
    echo "Invalid connection metadata: $name" >&2
    return 1
  fi
  if ! coverage=$(python3 lib/iplist.py "$format" "$body" "$tmp/result" "$dest"); then
    echo "Validation failed: $name" >&2
    return 1
  fi
  read -r old_ips new_ips <<< "$coverage"
  cmp -s "$tmp/result" "$dest" || list_changed=1
  observed=$meta
  if [[ $status == 200 ]]; then
    cmp -s "$body" "$raw" || raw_changed=1
    # Pages with per-request tokens keep the saved bytes and provenance while the list is unchanged.
    if (( volatile_raw && raw_changed && ! list_changed && ! force_provenance )) && [[ -f $raw && -f $meta ]]; then
      raw_changed=0
    else
      new_size=$(wc -c < "$body") || return 1
      digest=$(body_sha256 "$body") || return 1
      observed="$tmp/observed"
      jq -e --argjson size "$new_size" --arg sha "$digest" \
        '. + {size_bytes:$size, body_sha256:$sha}' "$tmp/meta" > "$observed" || return 1
      if (( raw_changed || list_changed || force_provenance )) ||
        ! file_metadata_matches "$meta" "$observed"; then refresh=1; fi
    fi
  fi
  if (( raw_changed || list_changed )); then
    [[ ! -f $raw ]] || old_size=$(wc -c < "$raw") || return 1
    if [[ $status == 304 ]]; then new_size=$old_size; fi
  fi
  if (( raw_changed || list_changed || refresh )); then
    provenance=$(jq -r '"\(.fetched_at) \(.connected_peer_ip) direct \(.source_url)\(if .final_url != .source_url then " -> \(.final_url)" else "" end)"' "$observed") || return 1
  fi
  if (( raw_changed )); then cp "$body" "$raw" || return 1; fi
  if (( list_changed )); then cp "$tmp/result" "$dest" || return 1; fi
  if (( refresh )); then cp "$observed" "$meta" || return 1; fi
  rm -f "$failure" "$legacy_failure" || return 1
  if (( raw_changed || list_changed )); then
    if (( raw_changed && list_changed )); then changes='raw and list'; elif (( raw_changed )); then changes=raw; else changes=list; fi
    coverage=$(python3 lib/iplist.py --format-coverage "$old_ips" "$new_ips") || return 1
    printf '%s: updated (%s): %s -> %s bytes / %s IPs / %s\n' "$name" "$changes" "$old_size" "$new_size" "$coverage" "$provenance"
  elif (( refresh )); then
    printf '%s: updated (provenance): %s\n' "$name" "$provenance"
  else
    printf '%s: no change\n' "$name"
  fi
}

update_main() (
  set -uo pipefail
  cd "$(dirname "${BASH_SOURCE[0]}")" || return 1
  local registry=${REGISTRY_DIR:-registry} legacy_state=${STATE_DIR:-.state}
  local tmp status=0 force_provenance=0 format name url volatile_raw
  if [[ $# == 1 && $1 == --force-update-provenance ]]; then
    force_provenance=1
  elif (( $# )); then
    echo 'Usage: update.sh [--force-update-provenance]' >&2
    return 2
  fi
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' EXIT
  python3 lib/registry.py "$registry" > "$tmp/sources" || status=1
  while IFS=$'\t' read -r format name url volatile_raw; do
    update_source "$format" "$name" "$url" "$volatile_raw" "$tmp" "$legacy_state" "$force_provenance" || status=1
  done < "$tmp/sources" || return 1
  return "$status"
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  update_main "$@"
fi
