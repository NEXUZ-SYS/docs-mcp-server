# llms.txt + .md.txt Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `scrape_docs` import sites that publish an `llms.txt` index + per-page `.md.txt` markdown variants (e.g. the Gemini API docs) by (FM-B) expanding an llms.txt given as the input URL and (FM-A) fetching `.md.txt` URLs as-is instead of building a broken `.md.txt.md` variant.

**Architecture:** Two surgical, additive changes inside `src/scraper/strategies/WebScraperStrategy.ts`. No public tool/signature changes. The existing `probeLlmsTxt` / `parseLlmsTxt` / `consumePendingLlmsTxtQueueItems` machinery is reused — we only stop the two places that drop the work on the floor.

**Tech Stack:** Node 22 (run `export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm use 22` before any node/npm/git command), TypeScript, Vitest. Husky pre-commit runs biome + typecheck — never bypass.

**Agents:** backend-specialist → test-writer.

---

## File Structure

- **Modify:** `src/scraper/strategies/WebScraperStrategy.ts`
  - **FM-A:** add private `endsWithMarkdownVariant(url)`; extend the as-is guard in `fetchItemContent` (~line 139).
  - **FM-B:** in `processItem`, make the `isLlmsTxtUrl(url)` branch (~lines 310-313) return the consumed pending llms.txt queue items.
  - **FM-E (added in Review R1 — scope anchor):** in that same `isLlmsTxtUrl` branch, when `item.depth === 0`, set `this.canonicalBaseUrl` to the llms.txt's **parent directory** so the listed sibling `.md.txt` pages pass `subpages` scope. Without this, `computeBaseDirectory("/docs/llms.txt")` → `"/docs/llms.txt/"` and the `.md.txt` siblings are rejected by `isInScope` → FM-B queues nothing. (Verified empirically: parent-dir anchor makes them in-scope.)
- **Test:** `src/scraper/strategies/WebScraperStrategy.test.ts` (already exists).

### Real test harness (mirror exactly — do NOT invent config/fetcher)
```ts
import { type AppConfig, loadConfig } from "../../utils/config";
import { FetchStatus } from "../fetcher/types";
import { ScrapeMode } from "../types";
import { HttpFetcher } from "../fetcher/HttpFetcher";
import type { ProgressCallback } from "../../types";
import type { ScraperProgressEvent } from "../types";
const mockFetchFn = vi.spyOn(HttpFetcher.prototype, "fetch");
// beforeEach: appConfig = loadConfig(); strategy = new WebScraperStrategy(appConfig);
//   options = { url, library:"test", version:"1.0", maxPages:99, maxDepth:3, scope:"subpages",
//               followRedirects:true, scrapeMode: ScrapeMode.Fetch };
// Drive fetches with mockFetchFn.mockImplementation(async (url) => ({content, mimeType, source:url, status}))
// Assert indexed pages via: progressCallback.mock.calls.find(c => c[0].result?.url === <url>)
```
The existing `describe("llms.txt discovery")` block (~lines 1369-1664) is the template — but note every existing llms.txt test uses `scope:"hostname"` or a trailing-slash root, never an llms.txt URL under `subpages`. Our integration test (Task 3) deliberately uses the `subpages` + llms.txt-input shape, which is what exercises FM-E.

No new files. Single production file touched (keeps the upstream PR diff minimal).

---

## Task 1: FM-A — recognize existing markdown variants (no `.md.txt.md`)

**Files:**
- Modify: `src/scraper/strategies/WebScraperStrategy.ts` (add `endsWithMarkdownVariant`, extend `fetchItemContent` guard ~line 139)
- Test: `src/scraper/strategies/WebScraperStrategy.test.ts`

- [ ] **Step 1: Write the failing unit test for the predicate**

Append (uses the real harness — `strategy` is built in `beforeEach` from `loadConfig()`; private method accessed via `(strategy as any)`, the file's existing convention):

```ts
describe("endsWithMarkdownVariant", () => {
  it("recognizes markdown-ish path suffixes", () => {
    expect((strategy as any).endsWithMarkdownVariant("https://x.dev/a.md")).toBe(true);
    expect((strategy as any).endsWithMarkdownVariant("https://x.dev/a.markdown")).toBe(true);
    expect((strategy as any).endsWithMarkdownVariant("https://x.dev/docs/text-generation.md.txt")).toBe(true);
  });
  it("rejects non-markdown paths and bare directories", () => {
    expect((strategy as any).endsWithMarkdownVariant("https://x.dev/docs/quickstart")).toBe(false);
    expect((strategy as any).endsWithMarkdownVariant("https://x.dev/docs/page.html")).toBe(false);
    expect((strategy as any).endsWithMarkdownVariant("https://x.dev/docs/")).toBe(false);
  });
});
```

- [ ] **Step 2: Run it — verify it fails**

Run: `export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm use 22 >/dev/null; npx vitest run src/scraper/strategies/WebScraperStrategy.test.ts -t endsWithMarkdownVariant`
Expected: FAIL — `endsWithMarkdownVariant is not a function`.

- [ ] **Step 3: Add the predicate**

In `WebScraperStrategy`, next to `isMarkdownUrl` (~line 127):

```ts
/**
 * True when the URL path already points at a markdown variant we can fetch as-is
 * (e.g. `.md`, `.markdown`, or the `.md.txt` form some doc sites publish in llms.txt).
 * Prevents building a broken double-extension variant like `page.md.txt.md`.
 */
private endsWithMarkdownVariant(url: string): boolean {
  let path: string;
  try {
    path = new URL(url).pathname.toLowerCase();
  } catch {
    return false;
  }
  return path.endsWith(".md") || path.endsWith(".markdown") || path.endsWith(".md.txt");
}
```

- [ ] **Step 4: Run it — verify it passes**

Run: `npx vitest run src/scraper/strategies/WebScraperStrategy.test.ts -t endsWithMarkdownVariant`
Expected: PASS (2 tests).

> The *behavioral* assertion ("a `fromLlmsTxt` `.md.txt` item is fetched as-is, never `.md.txt.md`") is covered end-to-end in **Task 3** via the real `mockFetchFn` harness — `fetchItemContent`/`fetcher` are private and the file's pattern drives behavior through `scrape()`, not by stubbing the private fetcher. Do not hand-stub `(strategy as any).fetcher`.

- [ ] **Step 5: Extend the as-is guard in `fetchItemContent`**

At `fetchItemContent` (~line 139), change:

```ts
if (!item.fromLlmsTxt || this.isMarkdownUrl(item.url)) {
  return this.fetcher.fetch(item.url, fetchOptions);
}
```
to:
```ts
if (
  !item.fromLlmsTxt ||
  this.isMarkdownUrl(item.url) ||
  this.endsWithMarkdownVariant(item.url)
) {
  return this.fetcher.fetch(item.url, fetchOptions);
}
```

- [ ] **Step 6: Run the predicate test + scraper suite — no regressions**

Run: `npx vitest run src/scraper/strategies/WebScraperStrategy.test.ts`
Expected: PASS (predicate tests pass; existing llms.txt tests unaffected — the new guard only adds an OR branch).

- [ ] **Step 7: Commit**

```bash
export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm use 22 >/dev/null
git add src/scraper/strategies/WebScraperStrategy.ts src/scraper/strategies/WebScraperStrategy.test.ts
git commit -m "fix(scraper): fetch .md.txt llms.txt links as-is instead of building .md.txt.md"
```

---

## Task 2: FM-B — expand an llms.txt given as the input URL

**Files:**
- Modify: `src/scraper/strategies/WebScraperStrategy.ts` (the `isLlmsTxtUrl(url)` branch in `processItem`, ~lines 310-313)
- Test: `src/scraper/strategies/WebScraperStrategy.test.ts`

- [ ] **Step 1: Write the failing unit test**

`processItem` on an llms.txt URL at depth 0 should return the queue items the pending probe produced (not an empty result). Set up a pending probe via the strategy's internal field and assert. Read the existing tests to confirm the exact field name (`pendingLlmsTxtProbe`) and `LlmsTxtProbeResult` shape (`{ url, result: { links: [{ url }] } }`):

```ts
it("processItem on an llms.txt URL queues the listed pages (subpages scope, parent-dir anchored)", async () => {
  // Real harness: `strategy` from beforeEach (loadConfig). Set a pending probe with two
  // sibling .md.txt pages and confirm they are queued under DEFAULT subpages scope —
  // this only passes if FM-E anchors scope to the llms.txt's parent dir (…/docs/).
  (strategy as any).pendingLlmsTxtProbe = {
    url: "https://ai.google.dev/gemini-api/docs/llms.txt",
    result: {
      links: [
        { url: "https://ai.google.dev/gemini-api/docs/text-generation.md.txt" },
        { url: "https://ai.google.dev/gemini-api/docs/quickstart.md.txt" },
      ],
    },
  };
  const result: ProcessItemResult = await (strategy as any).processItem(
    { url: "https://ai.google.dev/gemini-api/docs/llms.txt", depth: 0 },
    { ...options, url: "https://ai.google.dev/gemini-api/docs/llms.txt", scope: "subpages" },
    undefined,
  );
  expect(result.status).toBe(FetchStatus.SUCCESS);
  expect((result.queueItems ?? []).map((q) => q.url)).toEqual([
    "https://ai.google.dev/gemini-api/docs/text-generation.md.txt",
    "https://ai.google.dev/gemini-api/docs/quickstart.md.txt",
  ]);
  expect((result.queueItems ?? []).every((q) => q.fromLlmsTxt === true)).toBe(true);
});
```

> **Review R1 — scope is the trap:** `computeBaseDirectory("/gemini-api/docs/llms.txt")` returns
> `"/gemini-api/docs/llms.txt/"` (the filename is not an index pattern), so the `.md.txt` siblings
> at `/gemini-api/docs/<page>.md.txt` would FAIL `subpages` scope. This test therefore fails until
> FM-E (Step 3) anchors scope to the parent directory. Verified empirically: parent-dir anchor →
> in-scope. (`shouldFollowLinkFn` is undefined by default, so only `shouldProcessUrl`/scope gates.)

- [ ] **Step 2: Run it — verify it fails**

Run: `npx vitest run src/scraper/strategies/WebScraperStrategy.test.ts -t "queues the listed pages"`
Expected: FAIL — `queueItems` is `undefined`/empty (current early-return drops them).

- [ ] **Step 3: Make the llms.txt branch consume the pending probe**

In `processItem` (~lines 310-313), change:

```ts
if (isLlmsTxtUrl(url)) {
  logger.debug(`Skipping llms.txt meta-file: ${url}`);
  return { url, links: [], status: FetchStatus.SUCCESS };
}
```
to (FM-B expand + FM-E scope anchor):
```ts
if (isLlmsTxtUrl(url)) {
  // FM-E: anchor subpages-scope to the llms.txt's parent directory so the listed sibling
  // pages pass shouldProcessUrl. Without this, computeBaseDirectory(".../llms.txt") yields
  // ".../llms.txt/" and the siblings are rejected. The normal path sets canonicalBaseUrl at
  // ~line 334, but this branch returns before that, so set it here.
  if (item.depth === 0) {
    const anchor = new URL(url);
    anchor.pathname = anchor.pathname.replace(/\/[^/]*$/, "/");
    anchor.search = "";
    anchor.hash = "";
    this.canonicalBaseUrl = anchor;
  }
  // FM-B: don't index the llms.txt itself, but DO expand it — seed the listed pages from the
  // pending probe (populated by probeLlmsTxt in scrape()). consumePendingLlmsTxtQueueItems
  // returns [] for depth !== 0, so nested llms.txt links stay skipped.
  const queueItems = this.consumePendingLlmsTxtQueueItems(item, options);
  logger.debug(`llms.txt meta-file ${url}: queued ${queueItems.length} listed page(s)`);
  return { url, links: [], queueItems, status: FetchStatus.SUCCESS };
}
```

> Verify `canonicalBaseUrl` is a mutable field on the strategy (it is — read/written at
> `updateCanonicalBaseUrl` ~line 274/334 and read in `createLlmsTxtQueueItems` ~line 248). The
> regex `/\/[^/]*$/` → `/` strips the final `llms.txt` segment, giving the parent directory.

- [ ] **Step 4: Run it — verify it passes**

Run: `npx vitest run src/scraper/strategies/WebScraperStrategy.test.ts -t "queues the listed pages"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm use 22 >/dev/null
git add src/scraper/strategies/WebScraperStrategy.ts src/scraper/strategies/WebScraperStrategy.test.ts
git commit -m "fix(scraper): expand llms.txt input and anchor scope to its parent dir"
```

---

## Task 3: Integration (MANDATORY GATE) — llms.txt input → both pages indexed via `scrape()`

This is the end-to-end gate proving FM-A + FM-B + FM-E together. It uses the **real** harness
(`mockFetchFn` + `scrape()` + `progressCallback`) — `scrape()` runs fine at this layer (every
existing llms.txt test calls it with no store). Uses `scope: "subpages"` (the real success shape).

**Files:**
- Test: `src/scraper/strategies/WebScraperStrategy.test.ts`

- [ ] **Step 1: Write the failing integration test**

```ts
it("imports all pages listed in an llms.txt given as the input url (gemini shape, subpages)", async () => {
  options.url = "https://ai.google.dev/gemini-api/docs/llms.txt";
  options.scope = "subpages";
  options.maxDepth = 1;
  const pages: Record<string, string> = {
    "https://ai.google.dev/gemini-api/docs/llms.txt":
      "# Gemini API Docs\n\n## Docs\n\n" +
      "- [Text generation](https://ai.google.dev/gemini-api/docs/text-generation.md.txt): gen\n" +
      "- [Quickstart](https://ai.google.dev/gemini-api/docs/quickstart.md.txt): qs\n",
    "https://ai.google.dev/gemini-api/docs/text-generation.md.txt":
      "# Text generation\nUse generateContent to generate text.",
    "https://ai.google.dev/gemini-api/docs/quickstart.md.txt":
      "# Quickstart\nInstall the SDK and call generateContent.",
  };
  mockFetchFn.mockImplementation(async (url: string) => {
    const body = pages[url];
    return body
      ? { content: body, mimeType: "text/plain", source: url, status: FetchStatus.SUCCESS }
      : { content: "", mimeType: "text/plain", source: url, status: FetchStatus.NOT_FOUND };
  });

  const progressCallback = vi.fn<ProgressCallback<ScraperProgressEvent>>();
  await strategy.scrape(options, progressCallback);

  const indexed = progressCallback.mock.calls
    .map((c) => c[0].result?.url)
    .filter(Boolean);
  expect(indexed).toEqual(expect.arrayContaining([
    "https://ai.google.dev/gemini-api/docs/text-generation.md.txt",
    "https://ai.google.dev/gemini-api/docs/quickstart.md.txt",
  ]));
  // FM-A: never requested the broken double-extension variant
  const requested = mockFetchFn.mock.calls.map((c) => c[0] as string);
  expect(requested.some((u) => u.endsWith(".md.txt.md"))).toBe(false);
});
```

- [ ] **Step 2: Run it — verify it passes (after Tasks 1-2)**

Run: `npx vitest run src/scraper/strategies/WebScraperStrategy.test.ts -t "imports all pages listed"`
Expected: PASS. If `indexed` is empty → FM-E scope anchor missing/wrong (links rejected by scope).
If a `.md.txt.md` request appears → FM-A guard missing. Both must be green before commit.

- [ ] **Step 3: Commit**

```bash
export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm use 22 >/dev/null
git add src/scraper/strategies/WebScraperStrategy.test.ts
git commit -m "test(scraper): llms.txt input imports all listed .md.txt pages under subpages"
```

---

## Task 4: Full verification + docs

**Files:**
- Modify: `README.md` (one line under scrape usage: pointing scrape at a site's `llms.txt` imports the listed pages, preferring `.md`/`.md.txt` variants)

- [ ] **Step 1: Run the scraper suite**

Run: `export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm use 22 >/dev/null; npx vitest run src/scraper/`
Expected: PASS (no regressions in existing llms.txt tests).

- [ ] **Step 2: Lint + typecheck**

Run: `npm run lint && npm run typecheck`
Expected: both exit 0.

- [ ] **Step 3: Full default suite**

Run: `npm test`
Expected: only the known-pre-existing env failures (cli-e2e locale ×3, vector-persistence ×1) — zero failures in `src/scraper/` or new tests. If any scraper/new test fails, fix before proceeding.

- [ ] **Step 4: Document + commit**

Add the one-line README note, then:
```bash
git add README.md
git commit -m "docs(scrape): note llms.txt input imports listed .md/.md.txt pages"
```

- [ ] **Step 5 (live, optional, after merge to fork main + deploy):** confirm on production: `scrape_docs(url=".../gemini-api/docs/llms.txt", library="gemini")` → outcome `indexed`, `search_docs` returns generateContent content.

---

## Self-Review (post Review R1)

**Spec coverage:**
- FM-A (.md.txt as-is, no double extension) → Task 1 (predicate + guard) + Task 3 (behavioral). ✓
- FM-B (expand llms.txt input) → Task 2 (consume pending probe in the early-return). ✓
- **FM-E (scope anchor — added in R1)** → Task 2 Step 3 (set `canonicalBaseUrl` to parent dir) + Task 2 Step 1 test (subpages) + Task 3 (end-to-end). ✓
- Success criterion (llms.txt input → listed pages indexed under subpages) → Task 3 MANDATORY gate. ✓
- Additive / single production file / no signature change → only `WebScraperStrategy.ts` touched. ✓
- Out of scope (FM-C/FM-D, OAuth, discover_source) → no task. ✓

**Harness accuracy (R1 fix):** all test snippets now use the file's REAL harness — `strategy` from
`beforeEach`/`loadConfig()`, `mockFetchFn = vi.spyOn(HttpFetcher.prototype,"fetch")`, `options`
object, `progressCallback = vi.fn()`, results via `progressCallback.mock.calls[].0.result?.url`. No
hand-stubbed `(strategy as any).fetcher`, no fake config object.

**Placeholder scan:** no TODO/TBD; all production edits show exact before/after; tests are complete.

**Type consistency:** `endsWithMarkdownVariant`, `consumePendingLlmsTxtQueueItems` (existing),
`pendingLlmsTxtProbe` + `LlmsTxtProbeResult` `{url, result.links[].url}` (existing), `canonicalBaseUrl`
(existing mutable field, read in `createLlmsTxtQueueItems`:248), `queueItems` on `ProcessItemResult`
(existing :349/387), `fromLlmsTxt` on `QueueItem` (existing) — consistent and matched to real code.
