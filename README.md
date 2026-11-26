
Provide IPs of known crawlers and other services for decision making in an edge gateway or
for blanking out in web analytics.

## Features

TODO

## Repository layout

- `lists/<vendor>/<specialisation>.json` holds the published Google-compatible lists.
- `registry/<vendor>/<specialisation>.yaml` defines each source.
- `registry/types.yaml` defines the types that sources can use.
- `raw-data/<vendor>/<specialisation>` holds the original publisher bytes.
- `provenance/<vendor>/<specialisation>.json` holds download provenance.

## Source registry

For example, `registry/google/common-crawlers.yaml` contains the following entry.

```yaml
download_url: https://developers.google.com/static/crawling/ipranges/common-crawlers.json
info_url: https://developers.google.com/crawling/docs/crawlers-fetchers/verify-google-requests
format: json
types:
  - search-engine-crawler
  - mixed-pool
  - seo-tool
tier: 1
```

Both URLs must use HTTPS. The updater fetches `download_url`. Use `info_url`
to verify a feed's scope and check for publisher changes.

- `json` publishes Google-compatible downloads verbatim.
- `json-sanitised` consolidates Google-compatible prefixes and emits LF JSON.
- Custom formats use the named parsers `text`, `json-array`, `fastly`, `ahrefs`,
  `amazon-html`, `marginalia-html`, `semrush-html`, `you-html`, and `sail`.

Use a nonempty list of unique kebab-case labels in `types`, each defined with
a description in `registry/types.yaml`. Add a new type there before using it.
For a shared feed, include `mixed-pool` and each documented use. The integer `tier` applies to
the entire feed.

1. Default public website allow tier for mainstream web search, AI search, and
   public user-facing fetches. It includes Google's common crawlers and
   Anthropic's shared crawler pool.
2. Specialist search, SEO tools, site auditing, and advertising crawlers.
3. Dedicated model training and dataset crawlers, CDNs, monitoring, webhooks,
   and broad service pools.

## Updates

Run `bash update.sh` to refresh the data base and fetch new IPs from the known sources.

The process prints what happens with one line per source. Example output:

````
ahrefs/crawler: no change
amazon/amazonbot: updated (raw): 152542 -> 152542 bytes / 1.29 thousand -> 1.29 thousand IPs / 2026-11-26T09:24:45Z 44.215.141.168 direct https://developer.amazon.com/amazonbot/ip-addresses/
amazon/amzn-searchbot: updated (raw): 129548 -> 129548 bytes / 816 -> 816 IPs / 2026-11-26T09:24:49Z 44.215.133.6 direct https://developer.amazon.com/amazonbot/searchbot-ip-addresses/
amazon/amzn-user: updated (raw): 138561 -> 138561 bytes / 1.02 thousand -> 1.02 thousand IPs / 2026-11-26T09:24:53Z 44.215.143.138 direct https://developer.amazon.com/amazonbot/live-ip-addresses/
anthropic/bots: no change
anthropic/claude-agent: updated (raw and list): 719 -> 738 bytes / 9 -> 10 IPs / 2026-11-26T09:24:54Z 160.79.104.10 direct https://claude.com/.well-known/sail
apple/applebot: no change
babbar/barkrowler: no change
betterstack/monitor: no change
bunny/cdn-ipv4: updated (raw and list): 9126 -> 9126 bytes / 594 -> 594 IPs / 2026-11-26T09:24:57Z 138.199.46.65 direct https://api.bunny.net/system/edgeserverlist/plain
bunny/cdn-ipv6: updated (raw and list): 7944 -> 7940 bytes / 339 -> 339 IPs / 2026-11-26T09:24:58Z 156.146.56.170 direct https://api.bunny.net/system/edgeserverlist/ipv6/plain
... truncated ...
````

TODO: Move brief outcome description for normal users. Move rest as implementation notes into updates.sh itself.

Run `bash update.sh` to refresh every source in `registry/`. Set `REGISTRY_DIR`
to use a different registry directory. The updater requires Bash, curl 7.88
or later with a TLS backend that exposes PEM certificates in JSON write-out,
OpenSSL 3 or later, jq, and Python 3.11 or later with PyYAML installed
(`python3 -m pip install PyYAML`). The script can also be sourced from Bash.
Call `update_main` to update without changing the caller's directory or shell
settings. Run the test suite with `knockout.sh`.
To run an individual case, use, for example,
`bash knockout-tests/update.turbo.suite.sh text_download`.

Provenance records each source's source and final URLs, UTC download time,
connected peer IP and proxy use in `provenance/`. For a final HTTPS URL,
`tls_certificate` records the leaf certificate's `subject`, `issuer`,
UTC validity dates (`not_before` and `not_after`), and lowercase hex
`sha256_fingerprint`. The value is `null` for a final URL outside HTTPS.
The updater uses HTTP/1.1 with fresh connections and TLS handshakes across
redirects so the recorded certificate belongs to the peer that served the
download. Missing or invalid HTTPS certificate metadata fails the run and
preserves the last valid files. Updates ignore curl
configuration and proxy settings, resolve publisher hostnames normally, and
connect directly, including after redirects. Historical provenance can still
record a proxy peer or unknown proxy use. Raw downloads retain the exact
publisher bytes, including line endings. Microsoft's processed list is
consolidated and stored with LF endings in `lists/microsoft/bingbot.json`.
Raw downloads and published lists are committed so their changes can be
inspected. IP ranges describe the
published service and do not alone prove the identity of a request.
For converted lists, `creationTime` is retained when the consolidated networks
are unchanged.

Provenance includes `size_bytes` and `body_sha256` for the saved raw download.
The `headers` object holds the final response headers as arrays under lowercase
names, including `etag`, `last-modified` and any publisher checksum headers
when supplied. Cookie-setting headers are omitted. A validated full download
backfills older records and refreshes provenance when the data or publisher
URLs change. Header changes alone, including rotating ETags or per-server
Last-Modified values for identical bytes, do not trigger a refresh.

Set `volatile_raw: true` on a source whose page embeds per-request values such
as CSRF tokens or trace IDs. Its saved raw bytes and provenance are then kept
until the parsed list changes or `--force-update-provenance` is used.

Updates use the saved ETag, or Last-Modified when an ETag is unavailable,
to make a conditional GET to the resource that supplied the saved raw bytes.
On HTTP 304, the updater validates the saved raw bytes with the current parser
and retains the recorded download time. Run `bash update.sh --force-update-provenance`
or pass the flag to `update_main` to fetch full bodies and refresh provenance
for every successfully validated source.

Each successful source reports `no change` or an update identifying whether
the raw download, the published list, or both changed. Updates show download
size and total unique IPv4 and IPv6 coverage before and after, followed by
the UTC download time, connected peer, direct status and source URL. A final
URL is shown when a redirect changes it. Large address counts are abbreviated;
exact counts are included when rounding would hide a change. A refresh of
provenance alone is logged as `updated (provenance)`.

Updates reject malformed or empty lists, and reductions of at least 50% in
unique IPv4 or IPv6 coverage compared with the previous valid list. Other
sources are still attempted. Invalid registry entries and list validation
errors cause a failing exit status in the same run. Download failures are
recorded alongside provenance as
`provenance/<vendor>/<specialisation>.failure`, containing the Unix
timestamp of the first failure. They fail the run once they persist for 24
hours. Commit these records to track failures. A successful update removes
the active record, with its history retained in Git. Existing `.state/` records
are moved to `provenance/` on the next update.

## Edge proxy distribution

Run `bash release.sh` to build all three tier archives from the saved lists
and registry.

- `output/sensepitch-known-crawlers-tier1.zip`
- `output/sensepitch-known-crawlers-tier2.zip`
- `output/sensepitch-known-crawlers-tier3.zip`

Each archive includes the feeds assigned to that tier. For each feed it
contains the original published bytes at `lists/<vendor>/<listname>.json`
and proxy metadata at `info/<vendor>/<listname>.json`. The metadata contains
`vendor`, `listname`, the integer `tier`, and `tags` copied from the registry's
`types` array. Feeds keep their own prefixes, so an IP can match multiple
feeds across one or more tiers.

Every ZIP includes a root `meta.json` with `version` (currently 1), the integer
`tier`, the full `git-sha` of HEAD, and `last-modified` (that commit's committer
time in UTC). The build packages the saved files in the working tree. Builds
with the same HEAD, saved inputs, and compression toolchain produce
byte-identical ZIPs.

A tier with no feeds contains only `meta.json`. The build warns and skips
sources that have never been retrieved and warns when it includes a saved
list for a source with an active retrieval failure. Other missing or invalid
lists fail the build. All inputs are validated and the ZIPs are staged before
replacing the previous output. The `output/` directory is ignored by Git.

## Regular checks

- **Every six hours**, run `bash update.sh` from a runner with direct access to
  the publishers. This allows several attempts within the 24-hour retrieval
  failure window. Review the exit status and any active `.failure` records.
- **Weekly**, review Cloudflare Radar for new or newly verified crawlers. Check
  Known Agents and the ai.robots.txt registry for new user agents and publisher
  documentation. [Cloudflare Radar Bots Directory](https://radar.cloudflare.com/bots/directory),
  [Radar Bots API](https://developers.cloudflare.com/api/resources/radar/subresources/bots/methods/list/),
  [Known Agents](https://knownagents.com/agents),
  [ai.robots.txt registry](https://github.com/ai-robots-txt/ai.robots.txt/blob/main/robots.json)
- **Monthly**, review GoodBots for monitoring, CDN and service leads and
  CrawlCheck for newly tracked feeds and changes in their history. Confirm
  each candidate using its publisher page and fetch from the publisher.
  [GoodBots](https://github.com/AnTheMaker/GoodBots),
  [CrawlCheck IP-range history](https://crawlcheck.io/data/ip-ranges)

See `TODO.md` for sources still to be investigated. Keep company-wide network
ranges scoped to the services they describe.

## Credits

Inspired by: https://github.com/AnTheMaker/GoodBots

Unlike GoodBots, this project is intended to fetch lists directly from their
publishers, retain each original download, and record its provenance.
