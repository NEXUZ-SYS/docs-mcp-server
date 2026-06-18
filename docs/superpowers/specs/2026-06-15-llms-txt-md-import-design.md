# llms.txt + .md.txt Import — Design Spec

> **DevFlow workflow:** llms-txt-md-import | **Scale:** MEDIUM | **Phase:** P → writing-plans
> **Date:** 2026-06-15 | **Status:** approved scope (FM-A + FM-B), pending design approval

## Problem

Sites that publish an `llms.txt` index plus a clean markdown variant per page (e.g.
`<page>.md.txt`) cannot be imported, even though `WebScraperStrategy` already has llms.txt
probing and a `.md` variant preference. Real motivating case:
`https://ai.google.dev/gemini-api/docs` — the HTML root is behind an OAuth/anti-bot redirect
wall, but `https://ai.google.dev/gemini-api/docs/llms.txt` (HTTP 200) lists every page as
`https://ai.google.dev/gemini-api/docs/<page>.md.txt` (clean markdown, HTTP 200).

Two verified bugs block this (root causes confirmed in code):

### FM-B — llms.txt as input URL is hard-skipped before queue expansion
`WebScraperStrategy.processItem` (`src/scraper/strategies/WebScraperStrategy.ts:310-313`)
returns early for any llms.txt URL:
```ts
if (isLlmsTxtUrl(url)) {
  return { url, links: [], status: FetchStatus.SUCCESS };
}
```
This early-return happens **before** line 336 (`consumePendingLlmsTxtQueueItems`). So when the
scrape is pointed directly at the llms.txt, the root item is the llms.txt → it returns empty →
the `.md.txt` links the probe already parsed are **never queued** → 0 docs → `EMPTY_RESULT`.
(Pointing at the HTML root instead hits the OAuth redirect loop → `LOCALE_REDIRECT_LOOP`, so
the llms.txt is the only viable entry point for this class of site.)

### FM-A — `.md.txt` variant building produces a broken double extension
`fetchItemContent` (`:132-168`) builds a markdown variant for `fromLlmsTxt` items when
`isMarkdownUrl(item.url)` is false. `isMarkdownUrl` (`:127`) maps `.md.txt` → `text/plain`
(last extension `.txt`) → not markdown → false. So `buildMarkdownVariantUrl` (`:105-120`) sees
the last segment contains a `.` and appends `.md` → `…/text-generation.md.txt.md` → 404.
It does fall back to the original `.md.txt` (`:167`), so it is not strictly fatal, but every
page incurs a wasted 404 round-trip and the double-extension URL is incorrect by construction.

## Goal

`scrape_docs(url=".../gemini-api/docs/llms.txt", library="gemini")` → outcome `indexed` with
the listed `.md.txt` pages, searchable via `search_docs`.

## Scope

**In (MVP, approved):**
- **FM-B:** when the input/root item is an llms.txt URL, expand it — consume the pending
  llms.txt probe and return the listed links as `queueItems` instead of an empty early-return.
- **FM-A:** treat URLs already ending in a markdown variant (`.md`, `.markdown`, `.md.txt`) as
  already-markdown — fetch as-is, skip variant building (no `.md.txt.md`).

**Out (deferred — only affect the HTML-root path, which is OAuth-walled for the Gemini case):**
- FM-C: running the llms.txt probe / queue seeding when the HTML root fetch throws.
- FM-D: re-validating llms.txt URLs against the post-redirect canonical scope.
- Beating the OAuth wall / browser-fallback interaction with `LOCALE_REDIRECT_LOOP`.

## Design

### FM-B — expand llms.txt input
In `processItem`, replace the early-return for `isLlmsTxtUrl(url)` so it consumes the pending
probe (populated by `probeLlmsTxt` in `scrape()`):
```ts
if (isLlmsTxtUrl(url)) {
  const queueItems = this.consumePendingLlmsTxtQueueItems(item, options);
  logger.debug(`llms.txt meta-file ${url}: queued ${queueItems.length} listed page(s)`);
  return { url, links: [], queueItems, status: FetchStatus.SUCCESS };
}
```
`consumePendingLlmsTxtQueueItems` already guards `item.depth !== 0` (returns `[]`), so nested
llms.txt links remain skipped. The probe candidate logic (`getLlmsTxtCandidates`) already
includes the input URL's own path, so when the input IS the llms.txt the probe fetches+parses
it and sets `pendingLlmsTxtProbe` before `processItem` runs.

### FM-A — recognize existing markdown variants
Add a small predicate and use it in the `fetchItemContent` as-is guard so a URL that already
points at markdown text is fetched directly:
```ts
private endsWithMarkdownVariant(url: string): boolean {
  const path = new URL(url).pathname.toLowerCase();
  return path.endsWith(".md") || path.endsWith(".markdown") || path.endsWith(".md.txt");
}
// in fetchItemContent:
if (!item.fromLlmsTxt || this.isMarkdownUrl(item.url) || this.endsWithMarkdownVariant(item.url)) {
  return this.fetcher.fetch(item.url, fetchOptions);
}
```
This avoids the broken `.md.txt.md` request entirely; `.md.txt` is fetched as-is (served
`text/plain`, which the pipeline already indexes — proven by the working single-page scrape).

### Data flow (fixed)
```
scrape_docs(url=.../docs/llms.txt)
  scrape(): probeLlmsTxt → fetch .../docs/llms.txt (200) → parseLlmsTxt → pendingLlmsTxtProbe
  processItem(llms.txt, depth 0): isLlmsTxtUrl → consume pending → queueItems = [.md.txt × N]
  each .md.txt (fromLlmsTxt, endsWithMarkdownVariant) → fetched as-is (200 text/plain) → indexed
  job end → quality gate sees N docs → outcome: indexed
```

## Error handling
No new failure surface. Unreachable `.md.txt` pages fail individually (existing per-page
handling + `abortOnFailureRate`). If the probe finds no llms.txt, behavior is unchanged. The
quality gate (already shipped) still catches a net-empty result as `EMPTY_RESULT`.

## Testing strategy (TDD, deterministic, no network)
| Gate | Test | Level |
|---|---|---|
| FM-A | `endsWithMarkdownVariant` true for `.md`/`.markdown`/`.md.txt`, false otherwise | unit |
| FM-A | `fetchItemContent` for a `fromLlmsTxt` `.md.txt` item fetches the URL as-is (no `.md.txt.md`) — assert via mocked fetcher call args | unit |
| FM-B | `processItem` on an llms.txt URL at depth 0 returns `queueItems` from the pending probe (not empty) | unit |
| FM-B | end-to-end with a mock server: input = llms.txt listing two `.md.txt` pages → both indexed; `search` returns content | integration |
Fixtures use the real Gemini llms.txt shape (links ending in `.md.txt`).

## Out of scope confirmation
No `discover_source`, no OAuth-wall bypass, no FM-C/FM-D. Additive only — no signature changes
to public tools (the fix is internal to `WebScraperStrategy`).

## Upstream
Same two-branch pattern: `feat/llms-txt-md-import` (fork) + a clean `upstream-pr/...` branch
cherry-picked onto `upstream/main`, English PR. Builds on the quality-gates work (PR #439).
