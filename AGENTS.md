
- Publish every IP list in Google-compatible JSON at `lists/<vendor>/<specialisation>.json`. Copy compatible publisher JSON verbatim for `json` feeds and use the configured parser for other formats.
- Define each source in `registry/<vendor>/<specialisation>.yaml` with `download_url`, `info_url`, `format`, `types`, and `tier`. Use a list of types and tag shared feeds with `mixed-pool` plus the documented uses. Follow the README's tier definitions.
- Keep and commit the original download bytes in `other/raw/<vendor>/<specialisation>` so changes can be tracked.
- Fetch lists directly from their publishers, rather than importing GoodBots data.
- Record the source URL, final URL, UTC download time, connected peer IP, and proxy use for each download; identify proxy peers accurately.
- Reject empty lists and lists whose unique IPv4 or IPv6 address coverage falls to 50% or less of the previous valid coverage. Preserve the last valid data on failure.
- Attempt every source on each update. Validation failures must fail the run immediately in its final status. Record retrieval failures alongside provenance in `other/provenance/` and fail the run if one persists for 24 hours; clear the failure on successful retrieval and validation.

