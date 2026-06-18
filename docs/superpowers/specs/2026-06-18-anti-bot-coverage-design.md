# Anti-bot-agnostic Coverage — Design Spec

> **DevFlow workflow:** anti-bot-coverage | **Scale:** MEDIUM | **Phase:** P → writing-plans
> **Date:** 2026-06-18 | **Status:** scope approved (M2+M4+retry); pending design approval

## Problem & M0 diagnosis

Importing `ai.google.dev/gemini-api/docs/llms.txt` yields poor, dirty coverage. Measured in
production: 169 llms.txt links → `parseLlmsTxt` extracted 116 (53 bare `- (url)` links dropped)
→ **30 legit pages indexed + 1 garbage** (an `accounts.google.com` OAuth login page indexed as
a doc) + ~86 skipped on redirect. Effective coverage ~18%.

**M0 spike (empirical, conclusive):** the redirect into Google's OAuth wall is **NOT triggered
by any request header**. Verified with `axios` from both the dev host and the production pod IP,
varying User-Agent (axios default vs browser), Accept-Language (`en` / absent / `pt`), and the
markdown-preferred Accept header — **all returned HTTP 200, zero redirects**, including a burst
of 20 and 50 distinct sequential pages from the pod. Yet a real scrape minutes later returned
`EMPTY` (the llms.txt probe itself was challenged). Conclusion: **the anti-bot behavior is
intermittent/temporal server-side** — it flips within minutes and cannot be prevented by a
header or code change. This **refutes the original M1** ("avoid the trigger via UA/locale").

## Goal

Maximize coverage **agnostically** (works for any docs site, not just Gemini) and **never index
auth/login pages**. For typical docs sites (no active challenge) this approaches full coverage;
for actively-defended sites (Google) it is best-effort + self-healing via retry. True 100% on
Gemini would require a browser/proxy strategy (out of scope).

## Scope

**In (approved):**
- **M2 — agnostic anti-auth guard:** when a fetch redirects cross-origin to a login/auth host
  (or a generic `signin`/`oauth`/`login` pattern), treat the page as unavailable — never follow
  into it and never index it.
- **M4 — total llms.txt parse:** `parseLlmsTxt` also extracts bare `- (url)` list items and raw
  URLs, not only `[label](url)` (recovers the 53 dropped links).
- **Retry/backoff for transient challenges:** an auth-redirect / redirect-loop on a page (and on
  the llms.txt probe) is retried with backoff; transient challenges recover. The llms.txt probe
  failing must not be a hard dead-end when retry could succeed.

**Out (deferred):**
- M1 (header trigger-avoidance) — refuted by M0.
- M3 (Playwright/browser recovery), residential proxy, alternative Gemini sources.

## Design

### M2 — anti-auth redirect guard (HttpFetcher)
In the redirect branch (`src/scraper/fetcher/HttpFetcher.ts:207-246`), after resolving
`redirectUrl` (line 227) and before following it, classify the target:
```ts
if (isAuthRedirect(currentUrl, redirectUrl)) {
  const err = new ScraperError(
    `Blocked by an auth/login redirect: ${currentUrl} -> ${redirectUrl}`,
    true, // retryable: transient anti-bot challenges often clear on retry
  );
  err.code = "AUTH_REDIRECT";
  throw err;
}
```
New pure helper `isAuthRedirect(fromUrl, toUrl)` in a small module (e.g.
`src/scraper/fetcher/authRedirect.ts`): true when the redirect target's host is a **different
registrable domain** than the source AND matches an auth signal — host in a known login-host set
(`accounts.google.com`, `login.microsoftonline.com`, `login.live.com`, `github.com/login`,
`*.okta.com`, `*.auth0.com`, `signin.aws.amazon.com`, …) OR the path/host contains
`oauth`/`signin`/`sign-in`/`login`/`sso`. Because we throw before returning content, the auth
page is **never indexed** — this kills the garbage on any site.

### Retry/backoff for transient challenges
`HttpFetcher` already retries on transient network errors (config `maxRetries`/`baseDelayMs`).
Extend the retry classifier so a thrown `AUTH_REDIRECT` (and the existing `LOCALE_REDIRECT_LOOP`)
is **retryable**: retried with exponential backoff up to `maxRetries`. After exhausting retries
the error propagates and the page is skipped (the shipped robustness fix skips `fromLlmsTxt`
pages without aborting the run; a non-llms.txt entry-URL failure stays fatal, which is correct).
The **llms.txt probe** (`WebScraperStrategy.probeLlmsTxt`) goes through the same fetcher, so it
inherits the retry — a transient probe challenge no longer instantly dead-ends to `EMPTY`.

### M4 — total llms.txt parse
`parseLlmsTxt` (`src/scraper/utils/llmsTxtParser.ts`) currently matches only
`^\s*[-*+]\s+\[label\]\(url\)`. Add patterns (after the labeled match fails per line):
- bare list URL: `^\s*[-*+]\s+\(?(https?://\S+?)\)?(?::\s*(.+))?$`
- (optional) a raw `https?://` URL on its own line.
De-duplicate by URL. The existing HTML-rejection and zero-link guards stay. This recovers the
53 `- (url)` links.

## Error handling
`AUTH_REDIRECT` is a typed, retryable `ScraperError`; on exhaustion it is handled exactly like
other page errors (skip for llms.txt-listed pages; fatal for the entry URL). No auth page content
ever reaches the pipeline (we throw at the redirect, before reading the body). No new fatal paths.

## Testing strategy (TDD, deterministic, no network)
| Area | Test | Level |
|---|---|---|
| M2 | `isAuthRedirect` true for cross-domain login hosts / `oauth`/`signin` paths; false for same-domain and normal redirects | unit |
| M2 | `HttpFetcher` fetch that 302s to `accounts.google.com/...oauth` throws `AUTH_REDIRECT` and never returns content (mocked axios) | unit |
| Retry | a fetch that returns an auth redirect once then 200 succeeds within `maxRetries` (mocked axios sequence) | unit |
| M4 | `parseLlmsTxt` extracts bare `- (url)` items + labeled, deduped; still rejects HTML/link-less | unit |
| E2E-ish | `WebScraperStrategy.scrape` over an llms.txt whose one page auth-redirects every attempt → that page skipped, others indexed, no auth URL indexed | integration |

## Success criteria
Re-import `ai.google.dev/gemini-api/docs/llms.txt`: parse covers all 169 links; **zero
`accounts.google.com`/auth URLs indexed**; coverage materially above 30/169 on a non-challenged
window (and self-healing via retry). For sites that don't challenge, ~full coverage.

## Upstream
Two-branch pattern: `feat/anti-bot-coverage` (fork) + clean `upstream-pr/...` from `upstream/main`,
English PR. Builds on the shipped llms.txt + robustness work.
