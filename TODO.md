# Source coverage

- [x] Fetch the published PerplexityBot and Perplexity-User JSON lists directly. Perplexity-User is a user-triggered fetcher and generally ignores robots.txt; published ranges identify declared traffic only.
- [x] Use GoodBots as a discovery reference while fetching and preserving publisher data directly. Update runs are manual; distinct sources remain separate.
- [ ] Investigate remaining GoodBots entries without a verified, directly retrievable source: DuckDuckGo, Facebook, Freshping, ImageKit, Imgix, Marginalia, Mojeek, Semrush, Twitter/X, WebPageTest, Yandex and internal networks. Do not label broad ASN routes as crawler-specific addresses.
- [ ] Investigate Bunny's IPv6 source and any additional Google user-triggered fetcher lists.
- [ ] Consider a more portable way to record actual proxy use when curl is older than 8.7.0; current metadata records it as unknown.
