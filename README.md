# Sensepitch known crawlers

IP ranges of well-known crawlers, AI agents and fetchers, monitoring services,
webhook senders and CDNs, collected directly from the companies that operate
them. The repository currently tracks about 50 feeds from 30 publishers,
including Google, Microsoft (Bing), Apple, OpenAI, Anthropic, Perplexity,
Mistral, DuckDuckGo, Ahrefs, Semrush, Cloudflare, Fastly, Stripe and
UptimeRobot.

The lists are meant for decision making in an edge gateway, such as
sensepitch, where declared bots and
services can be allowed, rate limited or labelled, and for filtering this
traffic out of web analytics. Whatever format a publisher uses, every list is
published in the same Google-compatible JSON format, and each feed is tagged
with what kind of traffic it describes and a tier that indicates how readily
it can be allowed.

The IP ranges describe the service a publisher has declared. They do not
alone prove the identity of a request; combine them with the user agent and,
where a publisher documents it, reverse DNS verification.

## Features

- **Direct from the publisher.** Every list is downloaded from the
  publisher's own URL. Aggregators such as GoodBots are used only to discover
  new sources.
- **One format.** Lists in `lists/` use Google's crawler IP range JSON.
  Compatible downloads are copied verbatim; other formats (plain text, HTML
  pages, vendor JSON) are converted by dedicated parsers.
- **Typed and tiered.** Each feed carries types from `registry/types.yaml`,
  such as `search-engine-crawler`, `ai-search-crawler`, `ai-training-crawler`,
  `seo-tool`, `monitor`, `webhook` or `cdn`, plus a tier from 1 to 3, so
  consumers can decide how permissive to be (see [Source registry](#source-registry)).
- **Traceable.** The original download bytes are kept in `raw-data/`, and
  `provenance/` records where, when and from which server and TLS certificate
  each list was retrieved. Everything is committed, so every change shows up
  in the Git history.
- **Safe updates.** Empty or malformed lists and sudden drops in coverage are
  rejected, the last valid data is kept, and persistent download failures
  fail the run (see [Updates](#updates)). Unchanged sources produce no diff.
- **Ready to deploy.** `release.sh` packages each tier as a reproducible ZIP
  for edge proxies (see [Edge proxy distribution](#edge-proxy-distribution)).

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

Set `volatile_raw: true` on a source whose page embeds per-request values such
as CSRF tokens or trace IDs. Its saved raw download and provenance are then
kept until the parsed list changes or `--force-update-provenance` is used.

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

Each source reports `no change` or `updated` with what changed: `raw` (the
publisher's download), `list` (the published list), `raw and list`, or
`provenance` (only the download record was refreshed). Updates show the
download size and the total unique IPv4 and IPv6 coverage before and after,
followed by the UTC download time, connected peer, direct status and source
URL, plus the final URL when a redirect changed it.

Unchanged publisher data is re-checked with a conditional request and leaves
the repository untouched. Run `bash update.sh --force-update-provenance` to
fetch every source in full and refresh its provenance.

Set `REGISTRY_DIR` to use a different registry directory. The updater
requires Bash, curl 7.88 or later with a TLS backend that exposes PEM
certificates in JSON write-out, OpenSSL 3 or later, jq, and Python 3.11 or
later with PyYAML installed (`python3 -m pip install PyYAML`). The script can
also be sourced from Bash; call `update_main` to update without changing the
caller's directory or shell settings. Implementation notes are at the top of
`update.sh`.

Run the test suite with `knockout.sh`. To run an individual case, use, for
example, `bash knockout-tests/update.turbo.suite.sh text_download`.

### Provenance

`provenance/<vendor>/<specialisation>.json` describes the download behind the
saved raw data:

- `source_url` and `final_url` (after redirects)
- `fetched_at`, the UTC download time
- `connected_peer_ip` and `proxy_used`; updates always connect directly
- `tls_certificate` with the leaf certificate's `subject`, `issuer`, UTC
  validity (`not_before`, `not_after`) and lowercase hex `sha256_fingerprint`,
  or `null` when the final URL does not use HTTPS
- `headers`, the final response headers as arrays under lowercase names, such
  as `etag` and `last-modified`; cookie-setting headers are omitted
- `size_bytes` and `body_sha256` of the saved raw download

### Failures

Updates reject malformed or empty lists, and reductions of 50% or more in
unique IPv4 or IPv6 coverage compared with the previous valid list. The last
valid files are kept and the other sources are still attempted. Invalid
registry entries, validation errors and missing HTTPS certificate details
make the run exit with a failing status.

A failed download is recorded as `provenance/<vendor>/<specialisation>.failure`
containing the Unix timestamp of the first failure. It fails the run once it
persists for 24 hours. Commit these records to track failures; the next
successful update removes the record.

### Scheduled updates

The GitHub Actions workflow `.github/workflows/update.yml` runs `update.sh`
every six hours and can be started manually, optionally with
`--force-update-provenance`. It then runs `commit-updates.sh`, which commits
each changed source separately, using the source's line from the update
output as the commit message, and pushes the commits. Only files below
`raw-data/`, `lists/` and `provenance/` are committed.

A new retrieval failure is committed as `<name>: retrieval failed (since
<time>)`. The record stays unchanged while the failure persists, so it is not
committed again; clearing it is part of the next update commit for that source,
or `<name>: retrieval recovered` when the data is unchanged. The workflow
commits and pushes before it reports the update's exit status, so validation
errors and failures persisting for 24 hours fail the run with their records
already committed.

To commit a local run the same way, use
`bash update.sh > update.log; bash commit-updates.sh update.log`.

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

- **Every six hours**, the scheduled workflow runs `update.sh` from a GitHub
  runner (see [Scheduled updates](#scheduled-updates)). This allows several
  attempts within the 24-hour retrieval failure window. Review failed runs and
  any active `.failure` records.
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
