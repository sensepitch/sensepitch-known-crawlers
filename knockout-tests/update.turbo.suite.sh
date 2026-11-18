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
  cp "$ROOT/update.sh" "$CASE_DIR/repo/"
  cp "$ROOT/lib/iplist.py" "$CASE_DIR/repo/lib/"
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
case $url in
  */unknown) printf '{"url_effective":"%s/redirected","remote_ip":"192.0.2.1"}' "$url";;
  */direct) printf '{"url_effective":"%s","remote_ip":"192.0.2.1","proxy_used":0}' "$url";;
  */proxy) printf '{"url_effective":"%s","remote_ip":"192.0.2.1","proxy_used":1}' "$url";;
  *) printf '{"url_effective":"%s/redirected","remote_ip":"%s","proxy_used":0}' "$url" "${MOCK_REMOTE_IP:-192.0.2.1}";;
esac
SH
  chmod +x "$CASE_DIR/bin/curl"
  export PATH="$CASE_DIR/bin:$PATH" CALLS="$CASE_DIR/calls"
  cd "$CASE_DIR/repo"
}

run_update() { bash update.sh > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr"; }
expect_failure() { if run_update; then fail 'update unexpectedly succeeded'; fi; }
registry() { printf '%s\n' "$@" > sources.tsv; }
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
    [[ ! -e other && ! -e json && ! -e "$CALLS" ]]
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
  assert_file "$CASE_DIR/repo/other/json/one/good.json"
}

t_text_download() {
  echo '# text downloads retain the original and produce Google-format JSON'
  setup_case
  registry 'text one/good https://example.test/good'
  run_update
  assert_update_log 'one/good: updated (raw and list): 0 -> 13 bytes / 0 -> 256 IPs' other/provenance/one/good.json '192.0.2.1' 'direct' 'https://example.test/good' 'https://example.test/good/redirected'
  assert_eq '192.0.2.0/24' "$(cat other/raw/one/good)"
  jq -e '.prefixes[0].ipv4Prefix == "192.0.2.0/24"' other/json/one/good.json >/dev/null || fail 'incorrect converted list'
}

t_json_download() {
  echo '# Google-format downloads are preserved unchanged in the JSON destination'
  setup_case
  registry 'json one/good https://example.test/json'
  run_update
  cmp other/raw/one/good json/one/good.json || fail 'JSON download changed'
  assert_missing other/json/one/good.json
}

t_unchanged_downloads() {
  echo '# unchanged downloads retain data and provenance and clear failures'
  setup_case
  registry 'text one/text https://example.test/good' 'json one/json https://example.test/json'
  run_update
  touch -t 200001010000 other/raw/one/text other/json/one/text.json other/raw/one/json json/one/json.json
  touch "$CASE_DIR/marker"
  for name in text json; do
    jq '.fetched_at = "2000-01-01T00:00:00Z"' "other/provenance/one/$name.json" > "$CASE_DIR/meta"
    cp "$CASE_DIR/meta" "other/provenance/one/$name.json"
    touch -t 200001010000 "other/provenance/one/$name.json"
    printf '0\n' > "other/provenance/one/$name.failure"
  done
  run_update
  assert_eq $'one/text: no change\none/json: no change' "$(cat "$CASE_DIR/stdout")"
  for file in other/raw/one/text other/json/one/text.json other/raw/one/json json/one/json.json other/provenance/one/text.json other/provenance/one/json.json; do
    [[ $file -ot $CASE_DIR/marker ]] || fail "unchanged file was rewritten: $file"
  done
  for name in text json; do
    jq -e '.fetched_at == "2000-01-01T00:00:00Z"' "other/provenance/one/$name.json" >/dev/null || fail "provenance changed: $name"
    assert_missing "other/provenance/one/$name.failure"
  done
  assert_eq 4 "$(wc -l < "$CALLS" | tr -d ' ')"
}

t_changed_connection_provenance() {
  echo '# changed connection details leave provenance unchanged when data is unchanged'
  setup_case
  registry 'text one/good https://example.test/good'
  run_update
  jq '.fetched_at = "2000-01-01T00:00:00Z"' other/provenance/one/good.json > "$CASE_DIR/meta"
  cp "$CASE_DIR/meta" other/provenance/one/good.json
  export MOCK_REMOTE_IP=192.0.2.2
  run_update
  assert_eq 'one/good: no change' "$(cat "$CASE_DIR/stdout")"
  cmp "$CASE_DIR/meta" other/provenance/one/good.json || fail 'provenance changed without data changes'
}

t_changed_data_provenance() {
  echo '# changed raw data updates provenance even when connection details and networks are unchanged'
  setup_case
  registry 'text one/good https://example.test/good'
  run_update
  jq '.fetched_at = "2000-01-01T00:00:00Z"' other/provenance/one/good.json > "$CASE_DIR/meta"
  cp "$CASE_DIR/meta" other/provenance/one/good.json
  cp other/json/one/good.json "$CASE_DIR/list"
  export MOCK_BODY=$'192.0.2.0/25\n192.0.2.128/25'
  run_update
  assert_update_log 'one/good: updated (raw): 13 -> 28 bytes / 256 -> 256 IPs' other/provenance/one/good.json '192.0.2.1' 'direct' 'https://example.test/good' 'https://example.test/good/redirected'
  cmp "$CASE_DIR/list" other/json/one/good.json || fail 'equivalent list changed'
  jq -e '.fetched_at != "2000-01-01T00:00:00Z"' other/provenance/one/good.json >/dev/null || fail 'changed data not recorded'
}

t_equivalent_converted_list() {
  echo '# equivalent consolidated networks retain the list while raw data and provenance change'
  setup_case
  registry 'text one/good https://example.test/good'
  run_update
  cp other/json/one/good.json "$CASE_DIR/previous"
  registry 'text one/good https://example.test/equivalent'
  run_update
  cmp "$CASE_DIR/previous" other/json/one/good.json || fail 'equivalent list changed'
  assert_eq 2 "$(wc -l < other/raw/one/good | tr -d ' ')"
  jq -e '.source_url == "https://example.test/equivalent"' other/provenance/one/good.json >/dev/null || fail 'provenance not refreshed'
}

t_changed_converted_list() {
  echo '# changed consolidated networks produce a new converted list'
  setup_case
  registry 'text one/good https://example.test/good'
  run_update
  cp other/json/one/good.json "$CASE_DIR/previous"
  registry 'text one/good https://example.test/larger'
  run_update
  assert_update_log 'one/good: updated (raw and list): 13 -> 13 bytes / 256 -> 512 IPs' other/provenance/one/good.json '192.0.2.1' 'direct' 'https://example.test/larger' 'https://example.test/larger/redirected'
  if cmp -s "$CASE_DIR/previous" other/json/one/good.json; then fail 'changed list was retained'; fi
  jq -e '.prefixes[0].ipv4Prefix == "192.0.2.0/23"' other/json/one/good.json >/dev/null || fail 'changed network missing'
}

t_coverage_log() {
  echo '# update logs count unique IPv4 and IPv6 addresses without integer overflow'
  setup_case
  registry 'text one/good https://example.test/good'
  export MOCK_BODY=$'192.0.2.0/24\n192.0.2.0/25\n2001:db8::/64\n2001:db8::/65'
  run_update
  assert_update_log 'one/good: updated (raw and list): 0 -> 54 bytes / 0 -> 18.45 quintillion IPs' other/provenance/one/good.json '192.0.2.1' 'direct' 'https://example.test/good' 'https://example.test/good/redirected'
  export MOCK_BODY=$'192.0.2.0/23\n2001:db8::/63'
  run_update
  assert_update_log 'one/good: updated (raw and list): 54 -> 27 bytes / 18.45 quintillion -> 36.89 quintillion IPs' other/provenance/one/good.json '192.0.2.1' 'direct' 'https://example.test/good' 'https://example.test/good/redirected'
}

t_same_size_changes() {
  echo '# same-size changes are distinguished even when coverage is identical'
  setup_case
  registry 'text one/good https://example.test/good'
  run_update
  export MOCK_BODY='192.0.3.0/24'
  run_update
  assert_update_log 'one/good: updated (raw and list): 13 -> 13 bytes / 256 -> 256 IPs' other/provenance/one/good.json '192.0.2.1' 'direct' 'https://example.test/good' 'https://example.test/good/redirected'
  export MOCK_BODY='192.0.3.1/24'
  run_update
  assert_update_log 'one/good: updated (raw): 13 -> 13 bytes / 256 -> 256 IPs' other/provenance/one/good.json '192.0.2.1' 'direct' 'https://example.test/good' 'https://example.test/good/redirected'
}

t_coverage_rounding() {
  echo '# rounded coverage changes retain their exact values'
  setup_case
  assert_eq '1 million (1,000,000) -> 1 million (1,000,001)' "$(python3 lib/iplist.py --format-coverage 1000000 1000001)"
}

t_json_migration() {
  echo '# migration retains CRLF raw bytes and writes consolidated LF JSON'
  setup_case
  registry 'json one/good https://example.test/crlf'
  run_update
  cp other/raw/one/good "$CASE_DIR/original"
  registry 'json-converted one/good https://example.test/crlf'
  run_update
  cmp "$CASE_DIR/original" other/raw/one/good || fail 'raw bytes changed'
  assert_missing json/one/good.json
  assert_file other/json/one/good.json
  if LC_ALL=C grep -q $'\r' other/json/one/good.json; then fail 'converted JSON contains CRLF'; fi
  jq -e '.creationTime == "2024-01-01" and .prefixes[0].ipv4Prefix == "192.0.2.0/24"' other/json/one/good.json >/dev/null || fail 'incorrect migrated list'
  run_update
  assert_eq 'one/good: no change' "$(cat "$CASE_DIR/stdout")"
}

t_json_migration_rejection() {
  echo '# invalid migration retains the previous list and continues other sources'
  setup_case
  registry 'json one/good https://example.test/crlf'
  run_update
  cp json/one/good.json "$CASE_DIR/previous"
  registry 'json-converted one/good https://example.test/empty' 'text two/good https://example.test/good'
  expect_failure
  cmp "$CASE_DIR/previous" json/one/good.json || fail 'old list changed'
  assert_missing other/json/one/good.json
  assert_file other/json/two/good.json
}

t_direct_with_proxy_environment() {
  echo '# proxy environment variables cannot override forced direct access'
  setup_case
  export https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9
  registry 'text one/good https://example.test/unknown'
  run_update
  jq -e '.proxy_used == false' other/provenance/one/good.json >/dev/null || fail 'connection was not direct'
}

t_unexpected_proxy() {
  echo '# contradictory proxy metadata is rejected'
  setup_case
  registry 'text one/good https://example.test/proxy' 'text two/good https://example.test/good'
  expect_failure
  assert_missing other/raw/one/good
  assert_file other/raw/two/good
}

t_git_raw_crlf() {
  echo '# Git stores raw CRLF bytes without line-ending or whitespace warnings'
  setup_case
  cp "$ROOT/.gitattributes" .
  mkdir -p other/raw/one
  printf '192.0.2.0/24\r\n' > other/raw/one/good
  git init -q
  git config core.autocrlf input
  git add .gitattributes other/raw/one/good 2> "$CASE_DIR/git-stderr"
  [[ ! -s $CASE_DIR/git-stderr ]] || fail 'Git warned while adding raw bytes'
  git show :other/raw/one/good > "$CASE_DIR/staged"
  cmp other/raw/one/good "$CASE_DIR/staged" || fail 'Git altered raw bytes'
  git diff --cached --check || fail 'Git reported CRLF as trailing whitespace'
}

t_invalid_previous_list() {
  echo '# invalid previous data fails validation and does not prevent later sources'
  setup_case
  registry 'text one/good https://example.test/good'
  run_update
  cp other/raw/one/good "$CASE_DIR/raw"
  cp other/provenance/one/good.json "$CASE_DIR/meta"
  printf '%s\n' '{"prefixes":[]}' > other/json/one/good.json
  cp other/json/one/good.json "$CASE_DIR/invalid"
  registry 'text one/good https://example.test/equivalent' 'text two/good https://example.test/good'
  expect_failure
  cmp "$CASE_DIR/raw" other/raw/one/good || fail 'raw data changed after failure'
  cmp "$CASE_DIR/meta" other/provenance/one/good.json || fail 'provenance changed after failure'
  cmp "$CASE_DIR/invalid" other/json/one/good.json || fail 'previous data changed after failure'
  assert_file other/json/two/good.json
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
  echo '# provenance records source, redirect, UTC time, and the directly connected peer'
  setup_case
  registry 'text one/good https://example.test/good'
  run_update
  jq -e '.source_url == "https://example.test/good" and .final_url == "https://example.test/good/redirected" and (.fetched_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and .connected_peer_ip == "192.0.2.1" and .proxy_used == false' other/provenance/one/good.json >/dev/null || fail 'incorrect provenance'
}

t_proxy_unknown() {
  echo '# forced direct access is recorded even when curl does not report proxy use'
  setup_case
  registry 'text one/good https://example.test/unknown'
  run_update
  assert_update_log 'one/good: updated (raw and list): 0 -> 13 bytes / 0 -> 256 IPs' other/provenance/one/good.json '192.0.2.1' 'direct' 'https://example.test/unknown' 'https://example.test/unknown/redirected'
  jq -e '.proxy_used == false' other/provenance/one/good.json >/dev/null || fail 'proxy use should be false'
}

t_proxy_not_used() {
  echo '# provenance records a direct connection when curl reports no proxy'
  setup_case
  registry 'text one/good https://example.test/direct'
  run_update
  assert_update_log 'one/good: updated (raw and list): 0 -> 13 bytes / 0 -> 256 IPs' other/provenance/one/good.json '192.0.2.1' 'direct' 'https://example.test/direct' 'https://example.test/direct'
  jq -e '.proxy_used == false' other/provenance/one/good.json >/dev/null || fail 'proxy use should be false'
}

t_new_retrieval_failure() {
  echo '# a new download failure is recorded while other sources are attempted'
  setup_case
  registry 'text one/fail https://example.test/fail' 'text two/good https://example.test/good'
  run_update
  assert_eq 2 "$(wc -l < "$CALLS" | tr -d ' ')"
  assert_file other/provenance/one/fail.failure
  [[ $(cat other/provenance/one/fail.failure) =~ ^[0-9]+$ ]] || fail 'invalid failure time'
  assert_file other/json/two/good.json
}

t_persistent_failure() {
  echo '# a download failure persisting for 24 hours fails the run'
  setup_case
  mkdir -p other/provenance/one
  printf '0\n' > other/provenance/one/fail.failure
  registry 'text one/fail https://example.test/fail' 'text two/good https://example.test/good'
  expect_failure
  assert_eq 0 "$(cat other/provenance/one/fail.failure)"
  assert_file other/json/two/good.json
}

t_recovery() {
  echo '# successful retrieval and validation clear the failure record'
  setup_case
  mkdir -p other/provenance/one
  printf '0\n' > other/provenance/one/good.failure
  registry 'text one/good https://example.test/good'
  run_update
  assert_missing other/provenance/one/good.failure
}

t_legacy_failure() {
  echo '# legacy failure records retain their age when migrated'
  setup_case
  mkdir -p .state
  printf '0\n' > .state/one_fail.failure
  registry 'text one/fail https://example.test/fail'
  expect_failure
  assert_eq 0 "$(cat other/provenance/one/fail.failure)"
  assert_missing .state/one_fail.failure
}

t_configuration_overrides() {
  echo '# registry and legacy state directory overrides are honored'
  setup_case
  mkdir -p custom-state
  printf '0\n' > custom-state/one_fail.failure
  printf '%s\n' 'text one/fail https://example.test/fail' > custom-sources
  export SOURCES_FILE=custom-sources STATE_DIR=custom-state
  expect_failure
  assert_eq 0 "$(cat other/provenance/one/fail.failure)"
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
  registry 'unknown one/bad https://example.test/good' 'text two/good https://example.test/good'
  expect_failure
  assert_eq 1 "$(wc -l < "$CALLS" | tr -d ' ')"
  assert_file other/json/two/good.json
}

t_validation_preserves_data() {
  echo '# a rejected download preserves the previous files and failure record'
  setup_case
  registry 'text one/good https://example.test/good'
  run_update
  cp other/raw/one/good "$CASE_DIR/raw"
  cp other/json/one/good.json "$CASE_DIR/list"
  cp other/provenance/one/good.json "$CASE_DIR/meta"
  printf '0\n' > other/provenance/one/good.failure
  registry 'text one/good https://example.test/empty' 'text two/good https://example.test/good'
  expect_failure
  cmp "$CASE_DIR/raw" other/raw/one/good || fail 'raw data changed'
  cmp "$CASE_DIR/list" other/json/one/good.json || fail 'valid list changed'
  cmp "$CASE_DIR/meta" other/provenance/one/good.json || fail 'provenance changed'
  assert_eq 0 "$(cat other/provenance/one/good.failure)"
  assert_file other/json/two/good.json
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

testsuite_main "$@"
