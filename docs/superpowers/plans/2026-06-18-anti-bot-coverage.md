# Anti-bot-agnostic Coverage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Maximize scrape coverage agnostically and never index auth/login pages: skip-and-don't-index cross-domain auth redirects (M2), retry transient anti-bot challenges with backoff, and parse every llms.txt link form (M4).

**Architecture:** A pure `isAuthRedirect()` helper gates the HttpFetcher redirect branch — a redirect crossing to a login host/path throws a typed, **retryable** `AUTH_REDIRECT` error (so the existing per-attempt backoff retries transient challenges) and never reads the auth page body. `parseLlmsTxt` gains a bare-`- (url)` pattern.

**Tech Stack:** Node 22 (`export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm use 22` before any node/npm/git command), TypeScript, Vitest, axios. Husky pre-commit runs biome + typecheck — never bypass; if biome flags a long line, `./node_modules/.bin/biome format --write <file>` then re-stage.

**Agents:** backend-specialist → test-writer.

---

## File Structure

- **Create:** `src/scraper/fetcher/authRedirect.ts` — pure `isAuthRedirect(fromUrl, toUrl)`.
- **Create:** `src/scraper/fetcher/authRedirect.test.ts` — unit tests.
- **Modify:** `src/scraper/fetcher/HttpFetcher.ts` — call the guard in the redirect branch (~line 227, before the cyclic check ~231); throw `AUTH_REDIRECT` retryable.
- **Modify:** `src/scraper/fetcher/HttpFetcher.test.ts` — auth-redirect throws + retry recovers (mocked axios via `vi.mock("axios")` / `mockedAxios.get`).
- **Modify:** `src/scraper/utils/llmsTxtParser.ts` + `src/scraper/utils/llmsTxtParser.test.ts` — bare `- (url)` parsing.

---

## Task 1: `isAuthRedirect` helper (M2 core)

**Files:**
- Create: `src/scraper/fetcher/authRedirect.ts`
- Test: `src/scraper/fetcher/authRedirect.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, expect, it } from "vitest";
import { isAuthRedirect } from "./authRedirect";

describe("isAuthRedirect", () => {
  it("flags cross-domain redirects to known login hosts", () => {
    expect(isAuthRedirect(
      "https://ai.google.dev/gemini-api/docs/x.md.txt",
      "https://accounts.google.com/v3/signin/identifier?oauth=1",
    )).toBe(true);
    expect(isAuthRedirect("https://a.dev/p", "https://login.microsoftonline.com/x")).toBe(true);
    expect(isAuthRedirect("https://a.dev/p", "https://tenant.okta.com/login")).toBe(true);
    expect(isAuthRedirect("https://a.dev/p", "https://x.auth0.com/authorize")).toBe(true);
  });

  it("flags cross-domain redirects whose host/path looks like auth", () => {
    expect(isAuthRedirect("https://docs.foo.com/a", "https://auth.bar.com/oauth/authorize")).toBe(true);
    expect(isAuthRedirect("https://docs.foo.com/a", "https://bar.com/sign-in?next=/a")).toBe(true);
  });

  it("does NOT flag same-domain redirects or normal cross-domain ones", () => {
    // same registrable domain — a normal locale/canonical redirect
    expect(isAuthRedirect("https://ai.google.dev/a", "https://ai.google.dev/a/?hl=en")).toBe(false);
    expect(isAuthRedirect("https://foo.com/a", "https://www.foo.com/a")).toBe(false);
    // cross-domain but not auth-looking (e.g. CDN)
    expect(isAuthRedirect("https://docs.foo.com/a", "https://cdn.bar.com/a")).toBe(false);
  });

  it("returns false on unparseable input", () => {
    expect(isAuthRedirect("not a url", "also not")).toBe(false);
  });
});
```

- [ ] **Step 2: Run it — verify it fails**

Run: `export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm use 22 >/dev/null; ./node_modules/.bin/vitest run src/scraper/fetcher/authRedirect.test.ts`
Expected: FAIL — `Cannot find module './authRedirect'`.

- [ ] **Step 3: Implement the helper**

```ts
import { extractPrimaryDomain } from "../../utils/url";

/** Known third-party identity/login hosts (exact host or registrable-domain suffix). */
const AUTH_HOST_SUFFIXES = [
  "accounts.google.com",
  "login.microsoftonline.com",
  "login.live.com",
  "okta.com",
  "auth0.com",
  "signin.aws.amazon.com",
  "login.okta.com",
];

/** Path/host substrings that signal an auth/login flow. */
const AUTH_PATTERN = /(?:^|[./-])(?:oauth2?|sign-?in|signin|login|sso|authorize)(?:$|[./?-])/i;

/**
 * True when a redirect goes from one registrable domain to a DIFFERENT one that looks like an
 * identity/login provider. Used to refuse following (and indexing) auth walls on any site.
 * Same-domain redirects (locale, canonical, www) are never flagged.
 */
export function isAuthRedirect(fromUrl: string, toUrl: string): boolean {
  let from: URL;
  let to: URL;
  try {
    from = new URL(fromUrl);
    to = new URL(toUrl);
  } catch {
    return false;
  }
  if (extractPrimaryDomain(from.hostname) === extractPrimaryDomain(to.hostname)) {
    return false; // same registrable domain — not a cross-site auth wall
  }
  const host = to.hostname.toLowerCase();
  const inKnownHosts = AUTH_HOST_SUFFIXES.some(
    (s) => host === s || host.endsWith(`.${s}`),
  );
  if (inKnownHosts) return true;
  return AUTH_PATTERN.test(host) || AUTH_PATTERN.test(to.pathname);
}
```

(Confirm `extractPrimaryDomain` is exported from `src/utils/url.ts`. If `okta.com`/`auth0.com`
are listed both as bare and `login.okta.com`, dedupe — the suffix check already covers subdomains.)

- [ ] **Step 4: Run it — verify it passes**

Run: `./node_modules/.bin/vitest run src/scraper/fetcher/authRedirect.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm use 22 >/dev/null
git add src/scraper/fetcher/authRedirect.ts src/scraper/fetcher/authRedirect.test.ts
git commit -m "feat(fetcher): add isAuthRedirect guard helper for cross-site auth walls"
```

---

## Task 2: Wire the guard into HttpFetcher + make AUTH_REDIRECT retryable

**Files:**
- Modify: `src/scraper/fetcher/HttpFetcher.ts` (redirect branch ~227-231)
- Test: `src/scraper/fetcher/HttpFetcher.test.ts`

- [ ] **Step 1: Write the failing tests**

**Review R1 corrections to the harness (verified against the real file):** the file uses
`vi.mock("axios")` + `const mockedAxios = vi.mocked(axios, true)`, and a factory
`const createFetcher = () => new HttpFetcher(DEFAULT_CONFIG.scraper)` — **each `it` declares its
own `const fetcher = createFetcher();`** (there is NO shared `fetcher`, and it uses `DEFAULT_CONFIG`,
not `loadConfig()`). Also **`FetchStatus` is NOT imported** in this test file — assert the status
string `"success"` (the file's existing convention, e.g. its 304 test compares to `"not_modified"`).
Append:

```ts
it("throws AUTH_REDIRECT and never returns content when redirected to a login host", async () => {
  const fetcher = createFetcher();
  mockedAxios.get.mockResolvedValueOnce({
    status: 302,
    headers: { location: "https://accounts.google.com/v3/signin/identifier?oauth=1" },
    data: Buffer.from(""),
  } as any);
  await expect(
    fetcher.fetch("https://ai.google.dev/gemini-api/docs/x.md.txt", { maxRetries: 0 }),
  ).rejects.toMatchObject({ code: "AUTH_REDIRECT" });
});

it("retries a transient auth redirect and succeeds on the next attempt", async () => {
  const fetcher = createFetcher();
  mockedAxios.get
    .mockResolvedValueOnce({
      status: 302,
      headers: { location: "https://accounts.google.com/v3/signin/identifier?oauth=1" },
      data: Buffer.from(""),
    } as any)
    .mockResolvedValueOnce({
      status: 200,
      headers: { "content-type": "text/plain" },
      data: Buffer.from("# Page\nUsable content."),
    } as any);
  const res = await fetcher.fetch("https://ai.google.dev/gemini-api/docs/x.md.txt", {
    maxRetries: 1,
    retryDelay: 0,
  });
  expect(res.status).toBe("success");
  expect(res.content.toString()).toContain("Usable content");
});
```

- [ ] **Step 2: Run — verify it fails**

Run: `./node_modules/.bin/vitest run src/scraper/fetcher/HttpFetcher.test.ts -t "AUTH_REDIRECT|transient auth"`
Expected: FAIL — first test: no AUTH_REDIRECT (the code follows the redirect to accounts.google.com); second: rejects instead of recovering.

- [ ] **Step 3: Implement the guard in the redirect branch**

In `HttpFetcher.ts`, add the import at top: `import { isAuthRedirect } from "./authRedirect";`

In the redirect branch, right after `const redirectUrl = new URL(location, currentUrl).href;`
(~line 227) and BEFORE the `if (seenLocations.has(redirectUrl))` cyclic check (~line 231):

```ts
            // Refuse to follow (or index) a cross-site auth/login wall. Retryable because
            // these are commonly transient anti-bot challenges that clear on a later attempt.
            if (isAuthRedirect(currentUrl, redirectUrl)) {
              const authErr = new ScraperError(
                `Blocked by an auth/login redirect: ${currentUrl} -> ${redirectUrl}`,
                true,
              );
              authErr.code = "AUTH_REDIRECT";
              throw authErr;
            }
```

This throws before the body is read or returned, so the auth page is never indexed. The
`true` (isRetryable) means the per-attempt catch (`if (error instanceof ScraperError &&
!error.isRetryable) throw error;` ~line 309) does NOT re-throw it — it falls through to the
`for (let attempt = 0; attempt <= maxRetries; attempt++)` backoff loop (~line 142), so it is
retried up to `maxRetries` with `delay()`. `LOCALE_REDIRECT_LOOP` stays `false` (non-retryable)
— a genuine same-site ping-pong won't clear on retry.

- [ ] **Step 4: Run — verify it passes**

Run: `./node_modules/.bin/vitest run src/scraper/fetcher/HttpFetcher.test.ts -t "AUTH_REDIRECT|transient auth"`
Expected: PASS.

- [ ] **Step 5: Run the whole fetcher suite (no regressions)**

Run: `./node_modules/.bin/vitest run src/scraper/fetcher/`
Expected: PASS (existing redirect/loop/locale tests unaffected — the guard only adds a branch for cross-site auth targets).

- [ ] **Step 6: Commit**

```bash
export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm use 22 >/dev/null
git add src/scraper/fetcher/HttpFetcher.ts src/scraper/fetcher/HttpFetcher.test.ts
git commit -m "feat(fetcher): refuse and retry cross-site auth-wall redirects (AUTH_REDIRECT)"
```

---

## Task 3: Total llms.txt parse — bare `- (url)` links (M4)

**Files:**
- Modify: `src/scraper/utils/llmsTxtParser.ts`
- Test: `src/scraper/utils/llmsTxtParser.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
it("parses bare list URLs '- (url)' in addition to '[label](url)' (gemini mix), deduped", () => {
  const result = parseLlmsTxt(`Gemini API Docs

## Docs

- (https://ai.google.dev/gemini-api/docs/a.md.txt): bare entry
- [Labeled](https://ai.google.dev/gemini-api/docs/b.md.txt): labeled entry
- (https://ai.google.dev/gemini-api/docs/a.md.txt): duplicate, should not double
`);
  expect(result.links.map((l) => l.url)).toEqual([
    "https://ai.google.dev/gemini-api/docs/a.md.txt",
    "https://ai.google.dev/gemini-api/docs/b.md.txt",
  ]);
});
```

- [ ] **Step 2: Run — verify it fails**

Run: `./node_modules/.bin/vitest run src/scraper/utils/llmsTxtParser.test.ts -t "bare list URLs"`
Expected: FAIL — only the labeled URL is parsed (bare `- (url)` ignored; or the dup is double-counted).

- [ ] **Step 3: Implement**

In `llmsTxtParser.ts`, add a bare-URL pattern next to `markdownLinkPattern`:

```ts
const bareLinkPattern = /^\s*[-*+]\s+\(?(https?:\/\/[^)\s]+)\)?\s*(?::\s*(.+?)\s*)?$/;
```

In the per-line loop, after the existing `const linkMatch = markdownLinkPattern.exec(line);`
block, when `linkMatch` is null, try the bare pattern and build a link with the URL as title:

```ts
    const linkMatch = markdownLinkPattern.exec(line);
    const bareMatch = linkMatch ? null : bareLinkPattern.exec(line);
    const match = linkMatch ?? bareMatch;
    if (!match) {
      continue;
    }
    const url = (linkMatch ? match[2] : match[1]).trim();
    const title = (linkMatch ? match[1] : url).trim();
    const description = (linkMatch ? match[3] : match[2])?.trim();
    const link: LlmsTxtLink = {
      title,
      url,
      optional: currentSection?.optional ?? false,
      ...(currentSection ? { section: currentSection.title } : {}),
      ...(description ? { description } : {}),
    };
```

Then de-dup by URL before pushing (replace the direct pushes):

```ts
    if (result.links.some((l) => l.url === link.url)) {
      continue;
    }
    currentSection?.links.push(link);
    result.links.push(link);
```

Keep the HTML-rejection guard, the no-H1 acceptance, and the final `result.links.length === 0`
guard untouched.

- [ ] **Step 4: Run — verify it passes + no regressions**

Run: `./node_modules/.bin/vitest run src/scraper/utils/llmsTxtParser.test.ts`
Expected: PASS (the new test + all existing parser tests; the dedup must not break the "complete
content" test — verify its expected `links` array is still exact).

- [ ] **Step 5: Commit**

```bash
export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm use 22 >/dev/null
git add src/scraper/utils/llmsTxtParser.ts src/scraper/utils/llmsTxtParser.test.ts
git commit -m "feat(scraper): parse bare '- (url)' llms.txt links and dedupe by url"
```

---

## Task 4: Full verification + docs

**Files:**
- Modify: `README.md` (one line)

- [ ] **Step 1: Run the scraper suite**

Run: `./node_modules/.bin/vitest run src/scraper/`
Expected: PASS, no regressions.

- [ ] **Step 2: Lint + typecheck**

Run: `npm run lint && npm run typecheck`
Expected: both exit 0 (if lint flags formatting, `./node_modules/.bin/biome format --write` the
changed files, re-stage, re-run).

- [ ] **Step 3: Full default suite**

Run: `npm test`
Expected: only the known pre-existing env failures (`cli-e2e` locale ×3, `vector-persistence` ×1).
Zero failures in `src/scraper/` or the new files.

- [ ] **Step 4: Document + commit**

Add a one-line note under the scrape section of `README.md` (auth/login redirects are skipped,
never indexed; transient challenges are retried), then:
```bash
git add README.md
git commit -m "docs(scrape): note auth-wall skipping and transient-challenge retry"
```

- [ ] **Step 5 (live, after deploy):** re-import `ai.google.dev/gemini-api/docs/llms.txt`; verify via
the production sqlite (`kubectl exec ... node`) that **no `accounts.google.com` URL is indexed**
and coverage is materially above 30/169.

---

## Self-Review

**Spec coverage:**
- M2 anti-auth guard → Task 1 (`isAuthRedirect`) + Task 2 (wired in HttpFetcher, throws before body). ✓
- Retry for transient challenge → Task 2 (`AUTH_REDIRECT` retryable → reaches the attempt loop). ✓
- Probe inherits retry → it uses the same `HttpFetcher.fetch`, so no extra code; covered by Task 2. ✓
- M4 total parse → Task 3 (bare `- (url)` + dedup). ✓
- Never index auth pages → Task 2 throws before reading/returning content. ✓
- Additive / PR-shaped → 1 new file + 3 modified; no signature changes. ✓
- Out of scope (M1, M3, proxy) → no task. ✓

**Placeholder scan:** no TODO/TBD; every code step shows exact before/after; tests are complete.
Test bodies that say "mirror the existing harness" point to a concrete, existing construction in
the file the implementer copies verbatim (inventing it would diverge).

**Type consistency:** `isAuthRedirect(fromUrl, toUrl): boolean` (Task 1, used in Task 2),
`ScraperError.code = "AUTH_REDIRECT"` + `isRetryable=true` (Task 2), `LlmsTxtLink {title,url,optional,
section?,description?}` (Task 3, matches the existing interface), `markdownLinkPattern`/`bareLinkPattern`
(Task 3) — consistent and matched to real code. `extractPrimaryDomain` confirmed exported from
`src/utils/url.ts`.
