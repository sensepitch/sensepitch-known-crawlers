#!/usr/bin/env bash
set -euo pipefail
source <(knockout.sh fn-suite)
ROOT="$TESTSUITE_DIR/.."

fail() { printf '%s\n' "$*" >&2; return 1; }
assert_file() { [[ -f $1 ]] || fail "missing file: $1"; }
assert_missing() { [[ ! -e $1 ]] || fail "unexpected file: $1"; }
assert_eq() { [[ $1 == "$2" ]] || fail "expected '$1', got '$2'"; }
assert_update_log() {
  local expected=$1 meta=$2 peer=$3 proxy=$4 source=$5 final=$6 timestamp
  timestamp=$(jq -r '.fetched_at' "$meta")
  [[ $source == "$final" ]] || source+=" -> $final"
  assert_eq "$expected / $timestamp $peer $proxy $source" "$(cat "$CASE_DIR/stdout")"
}

setup_case() {
  CASE_DIR=$(mktemp -d)
  trap 'rm -rf "$CASE_DIR"' EXIT
  mkdir -p "$CASE_DIR/repo/lib" "$CASE_DIR/bin"
  cp "$ROOT/update.sh" "$ROOT/release.sh" "$CASE_DIR/repo/"
  cp "$ROOT/lib/iplist.py" "$ROOT/lib/registry.py" "$ROOT/lib/release.py" "$CASE_DIR/repo/lib/"
  export MOCK_CERT="$CASE_DIR/cert.pem"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -noenc \
    -subj /CN=example.test -days 1 -keyout /dev/null -out "$MOCK_CERT" 2>/dev/null
  cat > "$CASE_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
[[ ${1:-} == -q && ${2:-} == --noproxy && ${3:-} == '*' ]] || exit 90
while (($#)); do
  case $1 in --output) out=$2; shift 2;; https://*) url=$1; shift;; *) shift;; esac
done
printf '%s\n' "$url" >> "$CALLS"
case $url in
  */fail) exit 7;;
  */empty) : > "$out";;
  */json) printf '%s\n' '{"prefixes":[{"ipv4Prefix":"192.0.2.0/24"}]}' > "$out";;
  */crlf) printf '{\r\n  "creationTime": "2024-01-01",\r\n  "prefixes": [{"ipv4Prefix":"192.0.2.0/24"}]\r\n}\r\n' > "$out";;
  */equivalent) printf '%s\n' '192.0.2.0/25' '192.0.2.128/25' > "$out";;
  */larger) printf '%s\n' '192.0.2.0/23' > "$out";;
  *) printf '%s\n' "${MOCK_BODY:-192.0.2.0/24}" > "$out";;
esac
final_url="$url/redirected" redirects=1 connections=2 proxy_used=0
case $url in
  */unknown) proxy_used=null;;
  */direct) final_url=$url redirects=0 connections=1;;
  */proxy) proxy_used=1;;
  */plaintext) final_url="http://example.test/redirected";;
  */reused) connections=1;;
esac
jq -n --arg url "$final_url" --arg peer "${MOCK_REMOTE_IP:-192.0.2.1}" \
  --argjson proxy "$proxy_used" --argjson redirects "$redirects" --argjson connections "$connections" \
  --rawfile pem "$MOCK_CERT" '
  {url_effective:$url, remote_ip:$peer, num_redirects:$redirects, num_connects:$connections,
   certs:("Subject:CN=example.test\n" + (if $redirects == 0 then "Cert:" else "" end) + $pem)}
  + (if $proxy == null then {} else {proxy_used:$proxy} end)
  | if $url | endswith("/missing-cert/redirected") then del(.certs) else . end
'
SH
  chmod +x "$CASE_DIR/bin/curl"
  export PATH="$CASE_DIR/bin:$PATH" CALLS="$CASE_DIR/calls"
  cd "$CASE_DIR/repo"
}

run_update() { bash update.sh "$@" > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr"; }
expect_failure() { if run_update "$@"; then fail 'update unexpectedly succeeded'; fi; }
registry() {
  local directory=${REGISTRY_DIR:-registry} source format name url info_url
  mkdir -p "$directory"
  [[ -f $directory/types.yaml ]] || printf 'search-engine-crawler: >-\n  Crawls for a\n  search engine.\nwebhook: Sends events.\n' > "$directory/types.yaml"
  for source in "$@"; do
    read -r format name url info_url <<< "$source"
    mkdir -p "$directory/${name%/*}"
    printf 'format: %s\ndownload_url: %s\ninfo_url: %s\ntypes: [search-engine-crawler]\ntier: 1\n' \
      "$format" "$url" "${info_url:-https://example.test/info}" > "$directory/$name.yaml"
  done
}
validate() { python3 lib/iplist.py "$@" > "$CASE_DIR/validation-out" 2> "$CASE_DIR/validation-err"; }
expect_invalid() { if validate "$@"; then fail 'invalid list unexpectedly accepted'; fi; }

t_source_is_inert() {
  echo '# sourcing defines functions without changing the caller or updating files'
  setup_case
  bash -c '
    set -eu
    trap "echo original > \"$1/trap-fired\"" EXIT
    before=$(set +o); original=$PWD; old_trap=$(trap -p EXIT)
    source "$2/update.sh"
    [[ $PWD == "$original" && $(set +o) == "$before" && $(trap -p EXIT) == "$old_trap" ]]
    declare -F update_main >/dev/null
    [[ ! -e raw-data && ! -e provenance && ! -e lists && ! -e "$CALLS" ]]
  ' _ "$CASE_DIR" "$CASE_DIR/repo" || fail 'sourcing changed the caller or performed work'
  assert_file "$CASE_DIR/trap-fired"
}

t_sourced_entry_point() {
  echo '# sourced entry point runs against the script directory without changing the caller'
  setup_case
  registry 'text one/good https://example.test/good'
  cd "$CASE_DIR"
  source "$CASE_DIR/repo/update.sh"
  update_main > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr"
  assert_eq "$CASE_DIR" "$PWD"
  assert_file "$CASE_DIR/repo/lists/one/good.json"
}

t_text_download() {
  echo '# text downloads retain the original and produce Google-format JSON'
  setup_case
  registry $'text\tone/good\thttps://example.test/good\thttps://example.test/docs'
  run_update
  assert_eq 'https://example.test/good' "$(cat "$CALLS")"
  assert_update_log 'one/good: updated (raw and list): 0 -> 13 bytes / 0 -> 256 IPs' provenance/one/good.json '192.0.2.1' 'direct' 'https://example.test/good' 'https://example.test/good/redirected'
  assert_eq '192.0.2.0/24' "$(cat raw-data/one/good)"
  jq -e '.prefixes[0].ipv4Prefix == "192.0.2.0/24"' lists/one/good.json >/dev/null || fail 'incorrect converted list'
}

t_json_download() {
  echo '# Google-format downloads are preserved unchanged in the JSON destination'
  setup_case
  registry 'json one/good https://example.test/json'
  run_update
  cmp raw-data/one/good lists/one/good.json || fail 'JSON download changed'
}

t_unchanged_downloads() {
  echo '# unchanged downloads retain data and provenance and clear failures'
  setup_case
  registry 'text one/text https://example.test/good' 'json one/json https://example.test/json'
  run_update
  touch -t 200001010000 raw-data/one/text lists/one/text.json raw-data/one/json lists/one/json.json
  touch "$CASE_DIR/marker"
  for name in text json; do
    jq '.fetched_at = "2000-01-01T00:00:00Z"' "provenance/one/$name.json" > "$CASE_DIR/meta"
    cp "$CASE_DIR/meta" "provenance/one/$name.json"
    touch -t 200001010000 "provenance/one/$name.json"
    printf '0\n' > "provenance/one/$name.failure"
  done
  run_update
  assert_eq $'one/json: no change\none/text: no change' "$(cat "$CASE_DIR/stdout")"
  for file in raw-data/one/text lists/one/text.json raw-data/one/json lists/one/json.json provenance/one/text.json provenance/one/json.json; do
    [[ $file -ot $CASE_DIR/marker ]] || fail "unchanged file was rewritten: $file"
  done
  for name in text json; do
    jq -e '.fetched_at == "2000-01-01T00:00:00Z"' "provenance/one/$name.json" >/dev/null || fail "provenance changed: $name"
    assert_missing "provenance/one/$name.failure"
  done
  assert_eq 4 "$(wc -l < "$CALLS" | tr -d ' ')"
}

t_changed_connection_provenance() {
  echo '# changed connection details leave provenance unchanged when data is unchanged'
  setup_case
  registry 'text one/good https://example.test/good'
  run_update
  jq '.fetched_at = "2000-01-01T00:00:00Z"' provenance/one/good.json > "$CASE_DIR/meta"
  cp "$CASE_DIR/meta" provenance/one/good.json
  export MOCK_REMOTE_IP=192.0.2.2
  run_update
  assert_eq 'one/good: no change' "$(cat "$CASE_DIR/stdout")"
  cmp "$CASE_DIR/meta" provenance/one/good.json || fail 'provenance changed without data changes'
}

t_changed_data_provenance() {
  echo '# changed raw data updates provenance even when connection details and networks are unchanged'
  setup_case
  registry 'text one/good https://example.test/good'
  run_update
  jq '.fetched_at = "2000-01-01T00:00:00Z"' provenance/one/good.json > "$CASE_DIR/meta"
  cp "$CASE_DIR/meta" provenance/one/good.json
  cp lists/one/good.json "$CASE_DIR/list"
  export MOCK_BODY=$'192.0.2.0/25\n192.0.2.128/25'
  run_update
  assert_update_log 'one/good: updated (raw): 13 -> 28 bytes / 256 -> 256 IPs' provenance/one/good.json '192.0.2.1' 'direct' 'https://example.test/good' 'https://example.test/good/redirected'
  cmp "$CASE_DIR/list" lists/one/good.json || fail 'equivalent list changed'
  jq -e '.fetched_at != "2000-01-01T00:00:00Z"' provenance/one/good.json >/dev/null || fail 'changed data not recorded'
}

t_equivalent_converted_list() {
  echo '# equivalent consolidated networks retain the list while raw data and provenance change'
  setup_case
  registry 'text one/good https://example.test/good'
  run_update
  cp lists/one/good.json "$CASE_DIR/previous"
  registry 'text one/good https://example.test/equivalent'
  run_update
  cmp "$CASE_DIR/previous" lists/one/good.json || fail 'equivalent list changed'
  assert_eq 2 "$(wc -l < raw-data/one/good | tr -d ' ')"
  jq -e '.source_url == "https://example.test/equivalent"' provenance/one/good.json >/dev/null || fail 'provenance not refreshed'
}

t_changed_converted_list() {
  echo '# changed consolidated networks produce a new converted list'
  setup_case
  registry 'text one/good https://example.test/good'
  run_update
  cp lists/one/good.json "$CASE_DIR/previous"
  registry 'text one/good https://example.test/larger'
  run_update
  assert_update_log 'one/good: updated (raw and list): 13 -> 13 bytes / 256 -> 512 IPs' provenance/one/good.json '192.0.2.1' 'direct' 'https://example.test/larger' 'https://example.test/larger/redirected'
  if cmp -s "$CASE_DIR/previous" lists/one/good.json; then fail 'changed list was retained'; fi
  jq -e '.prefixes[0].ipv4Prefix == "192.0.2.0/23"' lists/one/good.json >/dev/null || fail 'changed network missing'
}

t_coverage_log() {
  echo '# update logs count unique IPv4 and IPv6 addresses without integer overflow'
  setup_case
  registry 'text one/good https://example.test/good'
  export MOCK_BODY=$'192.0.2.0/24\n192.0.2.0/25\n2001:db8::/64\n2001:db8::/65'
  run_update
  assert_update_log 'one/good: updated (raw and list): 0 -> 54 bytes / 0 -> 18.45 quintillion IPs' provenance/one/good.json '192.0.2.1' 'direct' 'https://example.test/good' 'https://example.test/good/redirected'
  export MOCK_BODY=$'192.0.2.0/23\n2001:db8::/63'
  run_update
  assert_update_log 'one/good: updated (raw and list): 54 -> 27 bytes / 18.45 quintillion -> 36.89 quintillion IPs' provenance/one/good.json '192.0.2.1' 'direct' 'https://example.test/good' 'https://example.test/good/redirected'
}

t_same_size_changes() {
  echo '# same-size changes are distinguished even when coverage is identical'
  setup_case
  registry 'text one/good https://example.test/good'
  run_update
  export MOCK_BODY='192.0.3.0/24'
  run_update
  assert_update_log 'one/good: updated (raw and list): 13 -> 13 bytes / 256 -> 256 IPs' provenance/one/good.json '192.0.2.1' 'direct' 'https://example.test/good' 'https://example.test/good/redirected'
  export MOCK_BODY='192.0.3.1/24'
  run_update
  assert_update_log 'one/good: updated (raw): 13 -> 13 bytes / 256 -> 256 IPs' provenance/one/good.json '192.0.2.1' 'direct' 'https://example.test/good' 'https://example.test/good/redirected'
}

t_coverage_rounding() {
  echo '# rounded coverage changes retain their exact values'
  setup_case
  assert_eq '1 million (1,000,000) -> 1 million (1,000,001)' "$(python3 lib/iplist.py --format-coverage 1000000 1000001)"
}

t_json_sanitisation() {
  echo '# switching to sanitised JSON retains CRLF raw bytes and writes consolidated LF JSON'
  setup_case
  registry 'json one/good https://example.test/crlf'
  run_update
  cp raw-data/one/good "$CASE_DIR/original"
  registry 'json-sanitised one/good https://example.test/crlf'
  run_update
  cmp "$CASE_DIR/original" raw-data/one/good || fail 'raw bytes changed'
  assert_file lists/one/good.json
  if LC_ALL=C grep -q $'\r' lists/one/good.json; then fail 'converted JSON contains CRLF'; fi
  jq -e '.creationTime == "2024-01-01" and .prefixes[0].ipv4Prefix == "192.0.2.0/24"' lists/one/good.json >/dev/null || fail 'incorrect migrated list'
  run_update
  assert_eq 'one/good: no change' "$(cat "$CASE_DIR/stdout")"
}

t_json_sanitisation_rejection() {
  echo '# rejected sanitised download retains the previous list and continues other sources'
  setup_case
  registry 'json one/good https://example.test/crlf'
  run_update
  cp lists/one/good.json "$CASE_DIR/previous"
  registry 'json-sanitised one/good https://example.test/empty' 'text two/good https://example.test/good'
  expect_failure
  cmp "$CASE_DIR/previous" lists/one/good.json || fail 'old list changed'
  assert_file lists/two/good.json
}

t_direct_with_proxy_environment() {
  echo '# proxy environment variables cannot override forced direct access'
  setup_case
  export https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9
  registry 'text one/good https://example.test/unknown'
  run_update
  jq -e '.proxy_used == false' provenance/one/good.json >/dev/null || fail 'connection was not direct'
}

t_unexpected_proxy() {
  echo '# contradictory proxy metadata is rejected'
  setup_case
  registry 'text one/good https://example.test/proxy' 'text two/good https://example.test/good'
  expect_failure
  assert_missing raw-data/one/good
  assert_file raw-data/two/good
}

t_git_raw_crlf() {
  echo '# Git preserves CRLF bytes in raw downloads and published JSON'
  setup_case
  cp "$ROOT/.gitattributes" .
  registry 'json one/good https://example.test/crlf'
  run_update
  git init -q
  git config core.autocrlf input
  git add .gitattributes raw-data/one/good lists/one/good.json 2> "$CASE_DIR/git-stderr"
  [[ ! -s $CASE_DIR/git-stderr ]] || fail 'Git warned while adding publisher bytes'
  git show :raw-data/one/good > "$CASE_DIR/staged"
  cmp raw-data/one/good "$CASE_DIR/staged" || fail 'Git altered raw bytes'
  git show :lists/one/good.json > "$CASE_DIR/staged"
  cmp raw-data/one/good "$CASE_DIR/staged" || fail 'Git altered published bytes'
  git diff --cached --check || fail 'Git reported CRLF as trailing whitespace'
}

t_invalid_previous_list() {
  echo '# invalid previous data fails validation and does not prevent later sources'
  setup_case
  registry 'text one/good https://example.test/good'
  run_update
  cp raw-data/one/good "$CASE_DIR/raw"
  cp provenance/one/good.json "$CASE_DIR/meta"
  printf '%s\n' '{"prefixes":[]}' > lists/one/good.json
  cp lists/one/good.json "$CASE_DIR/invalid"
  registry 'text one/good https://example.test/equivalent' 'text two/good https://example.test/good'
  expect_failure
  cmp "$CASE_DIR/raw" raw-data/one/good || fail 'raw data changed after failure'
  cmp "$CASE_DIR/meta" provenance/one/good.json || fail 'provenance changed after failure'
  cmp "$CASE_DIR/invalid" lists/one/good.json || fail 'previous data changed after failure'
  assert_file lists/two/good.json
}

t_identical_invalid_json() {
  echo '# identical invalid JSON input and previous data are rejected'
  setup_case
  printf '%s\n' '{"prefixes":[]}' > input
  cp input previous
  expect_invalid json input output previous
  assert_missing output
}

t_provenance() {
  echo '# provenance records the final HTTPS peer and leaf certificate'
  setup_case
  registry 'text one/good https://example.test/good'
  run_update
  jq -e '.source_url == "https://example.test/good" and .final_url == "https://example.test/good/redirected" and (.fetched_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and .connected_peer_ip == "192.0.2.1" and .proxy_used == false' provenance/one/good.json >/dev/null || fail 'incorrect provenance'
  local fingerprint
  fingerprint=$(openssl x509 -in "$MOCK_CERT" -outform DER | openssl dgst -sha256 -r)
  jq -e --arg fingerprint "${fingerprint%% *}" '
    .tls_certificate
    | .subject == "CN=example.test" and .issuer == "CN=example.test"
      and .sha256_fingerprint == $fingerprint
      and (.not_before | fromdateiso8601) < (.not_after | fromdateiso8601)
  ' provenance/one/good.json >/dev/null || fail 'incorrect certificate metadata'
}

t_non_https_final_url() {
  echo '# a plaintext final connection has null certificate provenance'
  setup_case
  registry 'text one/good https://example.test/plaintext'
  run_update
  jq -e 'has("tls_certificate") and .tls_certificate == null' provenance/one/good.json >/dev/null
}

t_unusable_certificate_metadata() {
  echo '# missing certificates and connection reuse fail the run without preventing later updates'
  setup_case
  registry 'text one/missing https://example.test/missing-cert' 'text one/reused https://example.test/reused' 'text two/good https://example.test/good'
  expect_failure --force-update-provenance
  for name in missing reused; do
    assert_missing "raw-data/one/$name"
    assert_missing "provenance/one/$name.json"
  done
  assert_file provenance/two/good.json
}

t_force_update_provenance() {
  echo '# a forced update refreshes all valid metadata with byte-identical data'
  setup_case
  registry 'text one/text https://example.test/good' 'json two/json https://example.test/json'
  run_update
  for name in one/text two/json; do
    touch -t 200001010000 "raw-data/$name" "lists/$name.json"
    jq 'del(.tls_certificate) | .fetched_at = "2000-01-01T00:00:00Z"' "provenance/$name.json" > "$CASE_DIR/meta"
    cp "$CASE_DIR/meta" "provenance/$name.json"
  done
  touch "$CASE_DIR/marker"
  source ./update.sh
  update_main --force-update-provenance > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr"
  for name in one/text two/json; do
    [[ "raw-data/$name" -ot "$CASE_DIR/marker" && "lists/$name.json" -ot "$CASE_DIR/marker" ]] || fail "rewrote data for $name"
    jq -e '.fetched_at != "2000-01-01T00:00:00Z" and (.tls_certificate | type == "object")' "provenance/$name.json" >/dev/null
    grep -Fq "$name: updated (provenance)" "$CASE_DIR/stdout"
  done
}

t_proxy_unknown() {
  echo '# forced direct access is recorded even when curl does not report proxy use'
  setup_case
  registry 'text one/good https://example.test/unknown'
  run_update
  assert_update_log 'one/good: updated (raw and list): 0 -> 13 bytes / 0 -> 256 IPs' provenance/one/good.json '192.0.2.1' 'direct' 'https://example.test/unknown' 'https://example.test/unknown/redirected'
  jq -e '.proxy_used == false' provenance/one/good.json >/dev/null || fail 'proxy use should be false'
}

t_proxy_not_used() {
  echo '# provenance records a direct connection when curl reports no proxy'
  setup_case
  registry 'text one/good https://example.test/direct'
  run_update
  assert_update_log 'one/good: updated (raw and list): 0 -> 13 bytes / 0 -> 256 IPs' provenance/one/good.json '192.0.2.1' 'direct' 'https://example.test/direct' 'https://example.test/direct'
  jq -e '.proxy_used == false' provenance/one/good.json >/dev/null || fail 'proxy use should be false'
}

t_new_retrieval_failure() {
  echo '# a new download failure is recorded while other sources are attempted'
  setup_case
  registry 'text one/fail https://example.test/fail' 'text two/good https://example.test/good'
  run_update
  assert_eq 2 "$(wc -l < "$CALLS" | tr -d ' ')"
  assert_file provenance/one/fail.failure
  [[ $(cat provenance/one/fail.failure) =~ ^[0-9]+$ ]] || fail 'invalid failure time'
  assert_file lists/two/good.json
}

t_persistent_failure() {
  echo '# a download failure persisting for 24 hours fails the run'
  setup_case
  mkdir -p provenance/one
  printf '0\n' > provenance/one/fail.failure
  registry 'text one/fail https://example.test/fail' 'text two/good https://example.test/good'
  expect_failure
  assert_eq 0 "$(cat provenance/one/fail.failure)"
  assert_file lists/two/good.json
}

t_recovery() {
  echo '# successful retrieval and validation clear the failure record'
  setup_case
  mkdir -p provenance/one
  printf '0\n' > provenance/one/good.failure
  registry 'text one/good https://example.test/good'
  run_update
  assert_missing provenance/one/good.failure
}

t_legacy_failure() {
  echo '# legacy failure records retain their age when migrated'
  setup_case
  mkdir -p .state
  printf '0\n' > .state/one_fail.failure
  registry 'text one/fail https://example.test/fail'
  expect_failure
  assert_eq 0 "$(cat provenance/one/fail.failure)"
  assert_missing .state/one_fail.failure
}

t_configuration_overrides() {
  echo '# registry and legacy state directory overrides are honored'
  setup_case
  mkdir -p custom-state
  printf '0\n' > custom-state/one_fail.failure
  export REGISTRY_DIR=custom-sources STATE_DIR=custom-state
  registry 'text one/fail https://example.test/fail'
  expect_failure
  assert_eq 0 "$(cat provenance/one/fail.failure)"
  assert_missing custom-state/one_fail.failure
}

t_missing_registry() {
  echo '# a missing source registry fails the update'
  setup_case
  expect_failure
}

t_invalid_source() {
  echo '# invalid registry entries fail the run without preventing later downloads'
  setup_case
  registry 'unknown one/bad https://example.test/unknown' 'text two/good https://example.test/good'
  printf 'types: [\n' > registry/one/malformed.yaml
  registry 'text one/duplicate https://example.test/duplicate'
  printf 'tier: 3\n' >> registry/one/duplicate.yaml
  registry 'text one/wrong-tier https://example.test/wrong-tier'
  sed -i 's/tier: 1/tier: true/' registry/one/wrong-tier.yaml
  sed -i 's/tier: 1/tier: 3/' registry/two/good.yaml
  expect_failure
  assert_eq 'https://example.test/good' "$(cat "$CALLS")"
  for name in bad malformed duplicate wrong-tier; do
    grep -Fq "registry/one/$name.yaml:" "$CASE_DIR/stderr" || fail "missing diagnostic for $name"
  done
  assert_file lists/two/good.json
}

t_validation_preserves_data() {
  echo '# a rejected download preserves the previous files and failure record'
  setup_case
  registry 'text one/good https://example.test/good'
  run_update
  cp raw-data/one/good "$CASE_DIR/raw"
  cp lists/one/good.json "$CASE_DIR/list"
  cp provenance/one/good.json "$CASE_DIR/meta"
  printf '0\n' > provenance/one/good.failure
  registry 'text one/good https://example.test/empty' 'text two/good https://example.test/good'
  expect_failure --force-update-provenance
  cmp "$CASE_DIR/raw" raw-data/one/good || fail 'raw data changed'
  cmp "$CASE_DIR/list" lists/one/good.json || fail 'valid list changed'
  cmp "$CASE_DIR/meta" provenance/one/good.json || fail 'provenance changed'
  assert_eq 0 "$(cat provenance/one/good.failure)"
  assert_file lists/two/good.json
}

t_unique_coverage() {
  echo '# overlapping networks are consolidated before measuring coverage'
  setup_case
  printf '%s\n' '192.0.2.0/24' '192.0.2.0/25' '2001:db8::/64' > input
  validate text input output -
  jq -e '.prefixes | length == 2' output >/dev/null || fail 'networks were not consolidated'
  printf '%s\n' '192.0.2.0/25' '2001:db8::/64' > input
  expect_invalid text input smaller output
}

t_ipv4_threshold() {
  echo '# IPv4 coverage falling to exactly half is rejected'
  setup_case
  printf '192.0.2.0/24\n' > input
  validate text input previous -
  printf '192.0.2.0/25\n' > input
  expect_invalid text input output previous
}

t_ipv6_threshold() {
  echo '# IPv6 coverage falling to exactly half is rejected independently'
  setup_case
  printf '%s\n' '192.0.2.0/24' '2001:db8::/64' > input
  validate text input previous -
  printf '%s\n' '192.0.2.0/24' '2001:db8::/65' > input
  expect_invalid text input output previous
}

t_above_threshold() {
  echo '# coverage greater than half of the previous list is accepted'
  setup_case
  printf '192.0.2.0/24\n' > input
  validate text input previous -
  printf '%s\n' '192.0.2.0/25' '192.0.2.128/26' > input
  validate text input output previous
  assert_file output
}

t_removed_family() {
  echo '# removal of an existing address family is rejected'
  setup_case
  printf '%s\n' '192.0.2.0/24' '2001:db8::/64' > input
  validate text input previous -
  printf '192.0.2.0/24\n' > input
  expect_invalid text input output previous
}

t_empty_list() {
  echo '# empty address lists are rejected'
  setup_case
  : > input
  expect_invalid text input output -
}

t_malformed_list() {
  echo '# malformed addresses and Google-format entries are rejected'
  setup_case
  printf 'not an ip\n' > input
  expect_invalid text input output -
  printf '%s\n' '{"prefixes":[{}]}' > input
  expect_invalid json input output -
}

t_fastly_format() {
  echo '# Fastly IPv4 and IPv6 lists are converted'
  setup_case
  printf '%s\n' '{"addresses":["192.0.2.0/24"],"ipv6_addresses":["2001:db8::/64"]}' > input
  validate fastly input output -
  jq -e '.prefixes | length == 2' output >/dev/null || fail 'incorrect Fastly list'
}

t_ahrefs_format() {
  echo '# Ahrefs addresses are converted to host prefixes'
  setup_case
  printf '%s\n' '{"ips":[{"ip_address":"192.0.2.1"}]}' > input
  validate ahrefs input output -
  jq -e '.prefixes[0].ipv4Prefix == "192.0.2.1/32"' output >/dev/null || fail 'incorrect Ahrefs list'
}

t_amazon_html_format() {
  echo '# Amazon embedded JSON accepts both publisher prefix spellings'
  setup_case
  printf '%s\n' '<pre><code class="container">{"prefixes":[{"ipv4Prefix":"192.0.2.1"},{"ip_prefix":"198.51.100.0/24"}]}</code></pre>' > input
  validate amazon-html input output -
  jq -e '.prefixes == [{"ipv4Prefix":"192.0.2.1/32"},{"ipv4Prefix":"198.51.100.0/24"}]' output >/dev/null
  printf '%s\n' '<p>Our site moved. Contact us at 192.0.2.10.</p>' > input
  expect_invalid amazon-html input output -
}

t_sail_format() {
  echo '# SAIL uses only the prefix sets referenced by Claude-Agent'
  setup_case
  cat > input <<'TOML'
schema = "draft-kelley-webbotauth-sail-00"
[[prefix_sets]]
name = "browser"
ipv4_prefixes = ["192.0.2.1"]
[[prefix_sets]]
name = "other"
ipv4_prefixes = ["198.51.100.0/24"]
[[services]]
name = "Claude-Agent"
prefix_sets = ["browser"]
TOML
  validate sail input output -
  jq -e '.prefixes == [{"ipv4Prefix":"192.0.2.1/32"}]' output >/dev/null
}

t_release() {
  echo '# a release builds a zip per tier and a full zip, each with its lists and an index'
  setup_case
  registry 'text one/good https://example.test/good' 'text two/fail https://example.test/fail' \
    'text three/hook https://example.test/hook'
  sed -i 's/search-engine-crawler/webhook/; s/tier: 1/tier: 3/' registry/three/hook.yaml
  run_update
  bash release.sh 2024.01.02 > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr"
  assert_eq $'dist/sensepitch-verified-ips-tier1-2024.01.02.zip: 1 lists\ndist/sensepitch-verified-ips-tier2-2024.01.02.zip: 0 lists\ndist/sensepitch-verified-ips-tier3-2024.01.02.zip: 1 lists\ndist/sensepitch-verified-ips-all-tiers-2024.01.02.zip: 2 lists' "$(cat "$CASE_DIR/stdout")"
  assert_eq 'Warning: two/fail has never been retrieved, skipped' "$(cat "$CASE_DIR/stderr")"
  members() { python3 -c 'import sys, zipfile; print(*zipfile.ZipFile(sys.argv[1]).namelist(), sep="\n")' "dist/sensepitch-verified-ips-$1.zip"; }
  assert_eq $'index.json\nlists/one/good.json' "$(members tier1-2024.01.02)"
  assert_eq 'index.json' "$(members tier2-2024.01.02)"
  assert_eq $'index.json\nlists/three/hook.json' "$(members tier3-2024.01.02)"
  assert_eq $'index.json\nlists/one/good.json\nlists/three/hook.json' "$(members all-tiers-2024.01.02)"
  unzip -p dist/sensepitch-verified-ips-all-tiers-2024.01.02.zip lists/one/good.json | cmp - lists/one/good.json || fail 'list changed in release'
  unzip -p dist/sensepitch-verified-ips-tier1-2024.01.02.zip index.json | jq -e --slurpfile meta provenance/one/good.json '
    .schema == 1 and .name == "sensepitch-verified-ips-tier1" and .version == "2024.01.02"
    and (.tiers | keys) == ["1"] and .types == {"search-engine-crawler": "Crawls for a search engine."}
    and .lists == [{id:"one/good", path:"lists/one/good.json", vendor:"one", specialisation:"good",
      types:["search-engine-crawler"], tier:1, info_url:"https://example.test/info",
      download_url:"https://example.test/good", fetched_at:$meta[0].fetched_at,
      ipv4_prefixes:1, ipv6_prefixes:0}]' >/dev/null || fail 'incorrect tier 1 index'
  unzip -p dist/sensepitch-verified-ips-tier2-2024.01.02.zip index.json | jq -e '
    .name == "sensepitch-verified-ips-tier2" and (.tiers | keys) == ["2"] and .types == {} and .lists == []' \
    >/dev/null || fail 'incorrect tier 2 index'
  unzip -p dist/sensepitch-verified-ips-all-tiers-2024.01.02.zip index.json | jq -e '
    .name == "sensepitch-verified-ips-all-tiers" and (.tiers | keys) == ["1", "2", "3"]
    and (.types | keys) == ["search-engine-crawler", "webhook"] and ([.lists[].id] == ["one/good", "three/hook"])' \
    >/dev/null || fail 'incorrect full index'
  rm dist/sensepitch-verified-ips-tier1-2024.01.02.zip dist/sensepitch-verified-ips-tier2-2024.01.02.zip
  if bash release.sh 2024.01.02 2>/dev/null; then fail 'existing release overwritten'; fi
  assert_missing dist/sensepitch-verified-ips-tier1-2024.01.02.zip
}

t_undefined_type() {
  echo '# a registry entry with a type missing from types.yaml is invalid'
  setup_case
  registry 'text one/bad https://example.test/bad' 'text two/good https://example.test/good'
  sed -i 's/search-engine-crawler/made-up/' registry/one/bad.yaml
  expect_failure
  assert_eq 'https://example.test/good' "$(cat "$CALLS")"
  grep -Fq 'registry/one/bad.yaml: types not defined in types.yaml: made-up' "$CASE_DIR/stderr" || fail 'missing diagnostic'
}

t_invalid_types_file() {
  echo '# an invalid types.yaml fails the run without preventing downloads'
  setup_case
  registry 'text one/good https://example.test/good'
  printf 'Not-Kebab: text\n' > registry/types.yaml
  expect_failure
  grep -Fq 'registry/types.yaml: expected a mapping' "$CASE_DIR/stderr" || fail 'missing diagnostic'
  assert_file lists/one/good.json
  if bash release.sh 2024.01.02 > /dev/null 2>&1; then fail 'release unexpectedly succeeded'; fi
}

t_release_missing_list() {
  echo '# a release fails when a registered list is missing without a failure record'
  setup_case
  registry 'text one/good https://example.test/good'
  if bash release.sh 2024.01.02 > /dev/null 2>&1; then fail 'release unexpectedly succeeded'; fi
  assert_missing dist
}

testsuite_main "$@"
