
Provide IPs of known crawlers and other services for decision making in an edge gateway or
for blanking out in web analytics.

## Credits

Inspired by: https://github.com/AnTheMaker/GoodBots

Unlike GoodBots, this project is intended to fetch lists directly from their
publishers, retain each original download, and record its provenance. Original
downloads belong in `other/raw/`; unchanged Google-compatible lists belong in
`json/`, and converted lists in `other/json/`. Published JSON lists use
`<company>/<specialization>.json` names.

Run `bash update.sh` to refresh the sources in `sources.tsv`. It requires Bash,
curl with JSON write-out support, jq and Python 3. The script can also be
sourced from Bash; call `update_main` to run an update without changing the
caller's directory or shell settings. Run the test suite with `knockout.sh`.
To run an individual case, use, for example,
`bash knockout-tests/update.turbo.suite.sh text_download`.

Provenance records each source's source and final URLs, UTC download time,
connected peer IP and proxy use in `other/provenance/`. Updates ignore curl
configuration and proxy settings, resolve publisher hostnames normally, and
connect directly, including after redirects. Historical provenance can still
record a proxy peer or unknown proxy use. Raw downloads retain the exact
publisher bytes, including line endings; Microsoft's processed list is
consolidated and stored with LF endings in `other/json/`. Raw downloads and derived lists
are committed so their changes can be inspected. IP ranges describe the
published service and do not alone prove the identity of a request.
For converted lists, `creationTime` is retained when the consolidated networks
are unchanged. Provenance is updated when the downloaded data or published
list changes; its timestamp records when that version was downloaded.

Each successful source reports `no change` or an update identifying whether
the raw download, the published list, or both changed. Updates show download
size and total unique IPv4 and IPv6 coverage before and after, followed by
the UTC download time, connected peer, direct status and source URL. A final
URL is shown when a redirect changes it. Large address counts are abbreviated;
exact counts are included when rounding would hide a change. Connection changes
alone do not update provenance.

Updates reject malformed or empty lists, and reductions of at least 50% in
unique IPv4 or IPv6 coverage compared with the previous valid list. Other
sources are still attempted. Validation errors fail the run immediately;
download failures are recorded alongside provenance as
`other/provenance/<company>/<specialization>.failure`, containing the Unix
timestamp of the first failure. They fail the run once they persist for 24
hours. Commit these records to track failures; a successful update removes the
active record, with its history retained in Git. Existing `.state/` records
are moved to the new location on the next update.

The source registry covers Perplexity, Google, Bing, Common Crawl, Apple,
Telegram, UptimeRobot, Stripe, Cloudflare, Fastly, Ahrefs, RSSAPI, Better
Stack, Mollie, Pingdom and Bunny. See `TODO.md` for sources still to be
investigated; broad ASN routes are not treated as crawler-specific IP lists.
