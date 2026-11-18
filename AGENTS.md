
- unify names of IP lists with, like: <company>/<specialication>.json
- put Google JSON compatible list downloads into json/
- Always keep original download, we want to commit it and track changes, in other/raw/
- put parsed and consolidated lists in Google JSON format into other/json/
- Fetch lists directly from their publishers, rather than importing GoodBots data.
- Record the source URL, final URL, UTC download time, connected peer IP, and proxy use for each download; identify proxy peers accurately.
- Reject empty lists and lists whose unique IPv4 or IPv6 address coverage falls to 50% or less of the previous valid coverage. Preserve the last valid data on failure.
- Attempt every source on each update. Validation failures must fail the run immediately in its final status. Record retrieval failures alongside provenance in `other/provenance/` and fail the run if one persists for 24 hours; clear the failure on successful retrieval and validation.

