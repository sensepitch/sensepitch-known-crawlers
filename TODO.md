# Source coverage

- [x] Fetch the published PerplexityBot and Perplexity-User JSON lists directly. Perplexity-User is a user-triggered fetcher and generally ignores robots.txt; published ranges identify declared traffic only.
- [x] Use GoodBots as a discovery reference while fetching and preserving publisher data directly. Update runs are manual; distinct sources remain separate.
- [x] Add both additional Google user-triggered lists and Bunny's IPv6 edge list.
- [x] Add Mojeek, Marginalia, Semrush Site Audit and ImageKit origin egress from their publishers.
- [ ] Confirm direct runner connectivity for DuckDuckBot and DuckAssistBot.
- [ ] Recheck Meta, Imgix, Twitter/X and WebPageTest for publisher feeds. Track Yandex's documented DNS verification, and revisit Freshping only if a supported service feed is available.
- [ ] Verify that ByteDance's Toutiao documentation can be fetched with its Bytespider address list in the response.
- [ ] Consider a more portable way to record actual proxy use when curl is older than 8.7.0; current metadata records it as unknown.
