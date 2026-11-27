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

The project aims to be an auditable, continuously maintained IP database for
edge gateways, reverse proxies and web application firewalls. Allow and
rate-limit decisions at the edge trust these ranges, so a wrong, truncated or
tampered list either lets unwanted traffic through or blocks legitimate
crawlers and webhooks. The lists are therefore handled as a security-sensitive
supply chain dependency: fetched only from their publishers, kept with their
original bytes and retrieval provenance, validated before they replace earlier
data, and changed only through reviewable commits (see
[Security and data handling](#security-and-data-handling)).

The IP ranges describe the service a publisher has declared. They do not
alone prove the identity of a request; combine them with the user agent and,
where a publisher documents it, reverse DNS verification.

## Features

- **Direct from the publisher.** Every list is downloaded from the
  publisher's own URL. Aggregators such as GoodBots are used only to discover
  new sources.
- **Traceable.** The original download bytes are kept in `raw-data/`, and
  `provenance/` records where, when and from which server and TLS certificate
  each list was retrieved. Everything is committed, so every change shows up
  in the Git history.
- **Safe updates.** Empty or malformed lists and sudden drops in coverage are
  rejected, the last valid data is kept, and persistent download failures
  fail the run (see [Updates](#updates)).
- **Reviewable changes.** Each changed source is committed separately with
  its size and coverage change, and unchanged sources produce no diff, so
  every commit reflects a real upstream change that can be reviewed or
  reverted.
- **One format.** Every list uses Google's crawler IP range JSON. Lists a
  publisher already serves in that format are kept byte-for-byte; other
  formats are converted (see [Data format](#data-format)).
- **Typed and tiered.** Each feed carries types from `registry/types.yaml`,
  such as `search-engine-crawler`, `ai-search-crawler`, `ai-training-crawler`,
  `seo-tool`, `monitor`, `webhook` or `cdn`, plus a tier from 1 to 3, so
  consumers can decide how permissive to be (see [Tier levels](#tier-levels)).
- **Ready to deploy.** Each tier is released as a reproducible ZIP for edge
  proxies (see [Release format](#release-format)).

## Data format

Every list in `lists/` uses the IP range JSON format that Google publishes
for its crawlers. Google, OpenAI, Anthropic and other publishers already
serve their lists in this format, and infrastructure tooling understands it.

```json
{
  "creationTime": "2026-11-26T09:24:54.129593+00:00",
  "prefixes": [
    { "ipv4Prefix": "34.31.25.14/32" },
    { "ipv6Prefix": "2001:4860:4801:10::/64" }
  ]
}
```

- **Original lists are kept.** A list that its publisher already serves in
  this format (`format: json`) is published byte-for-byte as downloaded, so
  it is identical to its file in `raw-data/` and can be checked against the
  publisher. This applies to about half of the feeds.
- **Sanitised lists.** Feeds with `format: json-sanitised`, currently
  Microsoft's Bingbot, have their prefixes consolidated and are written with
  LF line endings.
- **Converted lists.** Other formats, such as plain text, HTML pages and
  vendor JSON, are converted by named parsers (see
  [Source registry](#source-registry)). A converted list keeps its
  `creationTime` while its networks are unchanged.

## Release format

Releases are published on
[GitHub Releases](https://github.com/sensepitch/sensepitch-known-crawlers/releases)
with tags such as `2026.11.26.19` (date and hour of the commit). Each release
contains three ZIP archives, one per tier:

- `sensepitch-known-crawlers-tier1.zip`
- `sensepitch-known-crawlers-tier2.zip`
- `sensepitch-known-crawlers-tier3.zip`

Each archive contains only the feeds of its tier, so a consumer loads the
tiers it wants to allow or label. Feeds keep their own prefixes, so an IP can
match several feeds in one or more tiers.

```
meta.json
lists/<vendor>/<listname>.json   # the list, same bytes as in lists/
info/<vendor>/<listname>.json    # metadata for the list
```

`meta.json` identifies the snapshot: the archive format `version`
(currently 1), the `tier`, the full `git-sha` of the commit and
`last-modified`, that commit's time in UTC.

```json
{
  "version": 1,
  "tier": 1,
  "git-sha": "6f47877768dd8c20565703bb583c348b3bedc8e4",
  "last-modified": "2026-11-26T11:46:48Z"
}
```

Each `info` file describes one list:

- `vendor` and `listname`: the feed's name, as in
  `registry/<vendor>/<listname>.yaml`
- `tier`: the feed's tier, 1 to 3
- `tags`: the feed's types from the registry, in registry order

```json
{
  "vendor": "google",
  "listname": "common-crawlers",
  "tier": 1,
  "tags": [
    "search-engine-crawler",
    "mixed-pool",
    "seo-tool"
  ]
}
```

### Test fixture

`examples/edge-fixture/` holds a static set of synthetic feeds in the same ZIP
format, using documentation address ranges, together with expected matches
for test addresses. Edge proxies can use it in their tests instead of live
data (see its README).

### Tier levels

The tier applies to the entire feed and indicates how readily it can be
allowed.

1. Default public website allow tier for mainstream web search, AI search, and
   public user-facing fetches. It includes Google's common crawlers and
   Anthropic's shared crawler pool.
2. Specialist search, SEO tools, site auditing, and advertising crawlers.
3. Dedicated model training and dataset crawlers, CDNs, monitoring, webhooks,
   and broad service pools.

### Common types

The most common `tags` values are listed below. All types and their
descriptions are defined in `registry/types.yaml`.

- `user-triggered-fetcher`: fetches a page in direct response to a user
  action, such as a chat prompt or an agent task; may not follow robots.txt.
- `ai-search-crawler`: indexes pages for answers and citations in an AI
  assistant or AI search product.
- `search-engine-crawler`: crawls the public web for a search engine index.
- `ai-training-crawler`: collects public web content that may be used to
  train generative AI models.
- `seo-tool`: crawls for an SEO or site auditing product.
- `cdn`: edge network of a CDN or reverse proxy; identifies the network, not
  the client.
- `webhook`: sends event notifications to an endpoint the site operator has
  configured.
- `monitor`: uptime and performance checks.
- `mixed-pool`: the addresses are shared by several services, and a request
  may belong to any of the feed's other types.

See [Building releases](#building-releases) to build the archives locally.

## Security and data handling

An IP list used in an allow path is security-relevant configuration. The
update and release process addresses the following risks.

- **Spoofed or intercepted download.** Registry URLs must use HTTPS, updates
  connect directly without a proxy, and the leaf certificate's subject,
  issuer, validity and SHA-256 fingerprint are recorded (see
  [Provenance](#provenance)).
- **Publisher error, truncated or broken feed.** Malformed and empty lists and
  drops of 50% or more in IPv4 or IPv6 coverage are rejected, and the last
  valid data is kept (see [Failures](#failures)).
- **Silent outage and stale data.** Failed downloads are recorded in
  `.failure` files and fail the run once they persist for 24 hours (see
  [Scheduled updates](#scheduled-updates)).
- **Unnoticed upstream change.** The original bytes are kept in `raw-data/`
  with their `body_sha256`, and each changed source gets its own commit.
- **Over-broad ranges.** Shared feeds are typed `mixed-pool`, company-wide
  ranges are scoped to the services they describe, and tiers separate
  permissive from specialist feeds (see [Tier levels](#tier-levels)).
- **Tampered or inconsistent release.** Tier ZIPs are reproducible and record
  the full `git-sha` in `meta.json`, and release assets are checked against
  local digests before publishing (see `RELEASE.md`).

**Data minimisation.** Provenance keeps the publisher's response headers but
omits cookie-setting headers. The project fetches publisher lists only and
collects nothing about website visitors.

**Limits.** The controls show where data came from and stop obviously broken
updates. They cannot detect a publisher that serves wrong but plausible
ranges over valid TLS. The ranges describe services a publisher has declared,
not the identity of a request; combine them with the user agent and, where
documented, reverse DNS verification.

**Using the data safely.**

- Deploy a specific release or commit rather than following the branch
  blindly, and review the per-source commits when updating.
- Check `last-modified` in each ZIP's `meta.json` to detect stale data.
- Keep the previously loaded lists when a new archive fails to load or
  validate.
- Choose tiers deliberately; tier 3 includes broad service pools and CDNs.

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

### Types

Use a nonempty list of unique kebab-case labels in `types`, each defined with
a description in `registry/types.yaml`. Add a new type there before using it.
For a shared feed, include `mixed-pool` and each documented use. 

### Tiers

The integer `tier`, from 1 to 3, applies to the entire feed. Follow the
definitions in [Tier levels](#tier-levels).

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

## Building releases

Run `bash release.sh` to build all three tier archives from the saved lists
and registry, in the format described in [Release format](#release-format).

- `output/sensepitch-known-crawlers-tier1.zip`
- `output/sensepitch-known-crawlers-tier2.zip`
- `output/sensepitch-known-crawlers-tier3.zip`

The build packages the saved files in the working tree. Builds
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

## Related projects

Several other projects collect crawler IP ranges. Most focus on SEO,
analytics or blocking AI crawlers rather than on providing a reliable data
dependency for network infrastructure.

The comparison below was checked on 2026-11-26 against each project's own
public pages and repository READMEs. It records only what those pages state;
"—" means the topic was not documented there, not that the feature is
missing. Projects change and the table may contain mistakes, so corrections
and updates are welcome.

**Coverage and access**

| Project | Coverage (as stated) | Access and formats | Updates | License |
|---|---|---|---|---|
| Sensepitch Known Crawlers | ~50 feeds, 30 publishers | Git repo, tier ZIPs; Google JSON | Every 6 hours | Apache-2.0 code, CC0 data |
| [Verified Bots](https://verifiedbots.dev/) | 223 bots, 120 verifiable (August 2026) | Files and GitHub repo; JSON, `.ips`, RSS | Daily | MIT code, CC BY 4.0 data |
| [ipverse bot-ip-blocks](https://github.com/ipverse/bot-ip-blocks) | Crawlers and uptime monitors | Git repo; own normalized JSON | — | CC0-1.0 |
| [Trusted IPs whitelist](https://github.com/sefinek/trusted-ips-whitelist) | 39 services | Git repo; TXT, CSV, JSON | Every 6 hours | MIT |
| [GoodBots](https://github.com/AnTheMaker/GoodBots) | 27 services | Git repo; CIDR `.ips` text | Daily | — |
| [AI Bot IP Ranges](https://github.com/rxerium/ai-bot-ip-ranges) | 9 AI providers | Git repo; CIDR text | Weekly (README last updated May 2026) | MIT |
| [CrawlGenius](https://bots.crawlgenius.com/) | 15 verifiable crawlers | Free JSON API, CIDR text | Daily | — (free, including commercial use) |
| [CrawlCheck](https://crawlcheck.io/data/ip-ranges) | 20 feeds | JSON change log (CC BY 4.0) | Daily | CC BY 4.0 data |
| [IPQuery](https://ipquery.io/crawlers) | 15 crawlers | Web preview; full list on request | — | — |
| [is.bot](https://is.bot/) | 35 bots | Free lookup API, JSON | — | — |

**Sourcing and classification**

| Project | Fetched from publishers | Original responses kept | Classification | Granularity |
|---|---|---|---|---|
| Sensepitch Known Crawlers | Yes | Yes | Types and policy tiers 1–3 | Per publisher feed, e.g. `google/common-crawlers`; no merged list |
| Verified Bots | Yes | — | 10 categories; verifiability tiers 1–3 | Per bot; also `all.json`, per category and per tier |
| ipverse bot-ip-blocks | Yes | — | Crawlers vs monitoring; `ip_list_authoritative` flag | Per service within two dataset files |
| Trusted IPs whitelist | Mostly; some via RIPEstat/RADB or custom lists | — | 5 categories (crawlers, AI, monitoring, infrastructure, payments) | Per service; also merged overall and per category |
| GoodBots | — | — | Per-service files | Per service; also merged `all.ips` |
| AI Bot IP Ranges | Yes | — | Per-bot files | Per provider; also merged `all.txt` |
| CrawlGenius | Yes | — | 8 traffic types | Per bot; also merged `ranges.txt` |
| CrawlCheck | Yes | — | Per operator and feed | Per feed |
| IPQuery | — | — | 6 service types | Per crawler |
| is.bot | — | — | 5 bot types | Per bot (lookup result) |

**Provenance and safeguards**

| Project | Provenance | Faulty-data safeguards |
|---|---|---|
| Sensepitch Known Crawlers | Source and final URL, time, peer IP, TLS leaf certificate, headers | Rejects empty, malformed and ≥50% coverage drops; keeps last valid data |
| Verified Bots | — | Sanity checks, diff alarm, last-known-good fallback |
| ipverse bot-ip-blocks | Source URL, last change, generation time | Failed fetches emit empty arrays |
| Trusted IPs whitelist | — | — |
| GoodBots | — | — |
| AI Bot IP Ranges | Source URL per bot | — |
| CrawlGenius | Source URL, check and source-update times; change history | — |
| CrawlCheck | Read time, source URL; change history | — |
| IPQuery | Capture date | Shows degraded or stale feed state instead of an empty list |
| is.bot | — | — |

[BlackoutMap](https://blackoutmap.net/resources/crawler-ips), which
advertises JSON, CSV, NGINX and Apache exports, could not be checked because
its site refused automated access. The verifiedbots.dev site could not be
rendered, so its row is based on the author's
[project write-up](https://www.mayankgupta.com/projects/verifiedbots/). Its
tiers describe how reliably a bot can be verified, whereas the tiers here
describe how permissively a service should be treated. GoodBots inspired this
project (see [Credits](#credits)).

### What sets this project apart

- **Auditable supply chain.** Original publisher responses, retrieval
  provenance and TLS certificate fingerprints are kept and committed (see
  [Security and data handling](#security-and-data-handling)).
- **Defensive data ingestion.** Malformed or empty feeds and unexpected drops
  in IP coverage are rejected and the last valid data is kept (see
  [Security and data handling](#security-and-data-handling)).
- **Policy-oriented classification.** Types and tiers separate AI training
  crawlers, search crawlers, user-triggered fetchers and other services (see
  [Tier levels](#tier-levels)).
- **Matches keep their source.** Each publisher feed stays a separate list,
  and the tier ZIPs carry each feed's vendor, list name, tier and types. An IP
  that appears in several feeds matches all of them, so a proxy can tell, for
  example, Google's crawlers from its user-triggered fetchers instead of
  checking one merged allowlist.
- **Self-contained distribution.** Consumers need no external API at runtime
  (see [Release format](#release-format)).
- **Familiar format.** Every list uses Google's crawler IP range JSON.

## License

The code in this repository is licensed under the
[Apache License 2.0](LICENSE). The registry, provenance records and the lists
converted by this project are dedicated to the public domain under
[CC0 1.0](LICENSE-DATA).

The original publisher downloads in `raw-data/` and the lists copied verbatim
from publishers' `json` feeds remain the publishers' content and are subject
to their terms.

## Credits

Inspired by: https://github.com/AnTheMaker/GoodBots

Unlike GoodBots, this project is intended to fetch lists directly from their
publishers, retain each original download, and record its provenance.
