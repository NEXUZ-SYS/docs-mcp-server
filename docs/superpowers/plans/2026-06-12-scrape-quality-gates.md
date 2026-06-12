# Scrape Quality Gates — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `docs-mcp-server` mark a scrape `completed` only when it actually indexed usable docs — classifying the outcome, hard-failing with a typed error code, and rolling back the half-indexed store when a quality gate fails.

**Architecture:** A pure `evaluateOutcome()` classifier plus a `relevanceGate` run at a single seam in `PipelineManager` (the spot that today blindly sets `COMPLETED`). On a failing verdict the manager reuses `removeVersion()` to discard the staged docs (gate-then-rollback) and marks the job `FAILED` with a typed `errorCode`. New behavior is opt-out-safe via additive `ScraperOptions` fields (`denyPaths`, `localeStrategy`, `expectTerms`) and conservative defaults.

**Tech Stack:** Node 22, TypeScript, Vitest, better-sqlite3. Run `nvm use 22` first. Test single file: `npx vitest run <path>`.

**Upstream posture:** PR-shaped for `arabold/docs-mcp-server`. English code + conventional lowercase commits. Logic lives in **new files**; hot files (`PipelineManager.ts`, `GitHubScraperStrategy.ts`, `HttpFetcher.ts`) get a **single minimal seam** each. Every public change is additive.

---

## File Structure

**New files (low merge-conflict risk, easy review):**
- `src/pipeline/outcomeGate.ts` — pure `evaluateOutcome()` + types. No I/O.
- `src/pipeline/outcomeGate.test.ts` — unit tests.
- `src/pipeline/relevanceGate.ts` — path/host coherence + `expectTerms` sampling.
- `src/pipeline/relevanceGate.test.ts` — unit tests.
- `test/fixtures/github-tree-generative-ai-docs.json` — real tree snapshot (deterministic, no network).

**Modified files (additive / single seam):**
- `src/pipeline/types.ts` — add `ScrapeOutcome`, `ScrapeErrorCode`, `JobOutcomeMetrics`; extend `PipelineJob` with `outcome?`, `errorCode?`.
- `src/utils/errors.ts` — add optional `code` to `ScraperError`.
- `src/pipeline/PipelineManager.ts` — **one seam** at the `COMPLETED` block (~line 666): call `applyQualityGate(job)`.
- `src/store/DocumentManagementService.ts` — add `getVersionMetrics(library, version)` (wraps existing count query).
- `src/scraper/types.ts` — add `denyPaths?`, `localeStrategy?`, `expectTerms?` to `ScraperOptions`.
- `src/scraper/strategies/GitHubScraperStrategy.ts` — FM-3 guard + `denyPaths` in `shouldProcessFile`.
- `src/scraper/fetcher/HttpFetcher.ts` — locale normalization + cyclic-Location detection.
- `src/tools/GetJobInfoTool.ts`, `src/tools/ListJobsTool.ts`, `src/tools/ScrapeTool.ts`, `src/mcp/mcpServer.ts` — expose `outcome` + `errorCode`; pass new options through.

---

## Milestone M1 — Outcome classification (pure core)

**Agent:** backend-specialist → test-writer

### Task 1: `ScrapeOutcome` / `ScrapeErrorCode` / `JobOutcomeMetrics` types

**Files:**
- Modify: `src/pipeline/types.ts` (append near `PipelineJobStatus`)

- [ ] **Step 1: Add the enums and metrics type**

```ts
/** Classification of a finished scrape job's usefulness, beyond raw success/failure. */
export enum ScrapeOutcome {
  INDEXED = "indexed",
  EMPTY = "empty",
  THIN = "thin",
  DEGENERATE = "degenerate",
  FAILED = "failed",
}

/** Machine-readable reason a job failed a quality gate, with caller remediation. */
export enum ScrapeErrorCode {
  EMPTY_RESULT = "EMPTY_RESULT",
  THIN_RESULT = "THIN_RESULT",
  OFF_TOPIC = "OFF_TOPIC",
  SCOPE_DRIFT = "SCOPE_DRIFT",
  LOCALE_REDIRECT_LOOP = "LOCALE_REDIRECT_LOOP",
  GITHUB_SUBPATH_NOT_FOUND = "GITHUB_SUBPATH_NOT_FOUND",
}

/** Counters collected when a job finishes, fed into the quality gate. */
export interface JobOutcomeMetrics {
  /** Number of stored chunks for the (library, version). */
  documentCount: number;
  /** Number of distinct indexed URLs. */
  distinctUrls: number;
  /** Pages the scraper reported processing. */
  pagesScraped: number;
  /** Fraction (0..1) of indexed URLs under the requested root path. undefined if not computed. */
  inScopeUrlRatio?: number;
  /** Whether sampled chunks matched `expectTerms`. undefined when no expectTerms given. */
  expectTermsMatched?: boolean;
}
```

- [ ] **Step 2: Extend `PipelineJob` (additive, optional)**

In the `PipelineJob` interface add:

```ts
  /** Quality classification of the finished job (undefined while running). */
  outcome?: ScrapeOutcome;
  /** Typed reason when the job failed a quality gate. */
  errorCode?: ScrapeErrorCode;
```

- [ ] **Step 3: Typecheck**

Run: `npm run typecheck`
Expected: PASS (no consumers reference the new optional fields yet).

- [ ] **Step 4: Commit**

```bash
git add src/pipeline/types.ts
git commit -m "feat(pipeline): add scrape outcome and error-code types"
```

### Task 2: Pure `evaluateOutcome()`

**Files:**
- Create: `src/pipeline/outcomeGate.ts`
- Test: `src/pipeline/outcomeGate.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, expect, it } from "vitest";
import { evaluateOutcome, type QualityGateConfig } from "./outcomeGate";
import { ScrapeErrorCode, ScrapeOutcome } from "./types";

const cfg: QualityGateConfig = { minDocs: 1, minInScopeRatio: 0.5 };

describe("evaluateOutcome", () => {
  it("classifies zero documents as empty", () => {
    const v = evaluateOutcome({ documentCount: 0, distinctUrls: 0, pagesScraped: 0 }, cfg);
    expect(v.outcome).toBe(ScrapeOutcome.EMPTY);
    expect(v.errorCode).toBe(ScrapeErrorCode.EMPTY_RESULT);
    expect(v.remediation).toMatch(/no .*content/i);
  });

  it("classifies below-threshold documents as thin", () => {
    const v = evaluateOutcome(
      { documentCount: 1, distinctUrls: 1, pagesScraped: 1 },
      { minDocs: 3, minInScopeRatio: 0.5 },
    );
    expect(v.outcome).toBe(ScrapeOutcome.THIN);
    expect(v.errorCode).toBe(ScrapeErrorCode.THIN_RESULT);
  });

  it("classifies failed expectTerms as degenerate/off-topic", () => {
    const v = evaluateOutcome(
      { documentCount: 50, distinctUrls: 40, pagesScraped: 40, expectTermsMatched: false },
      cfg,
    );
    expect(v.outcome).toBe(ScrapeOutcome.DEGENERATE);
    expect(v.errorCode).toBe(ScrapeErrorCode.OFF_TOPIC);
  });

  it("classifies low in-scope ratio as degenerate/scope-drift", () => {
    const v = evaluateOutcome(
      { documentCount: 50, distinctUrls: 40, pagesScraped: 40, inScopeUrlRatio: 0.1 },
      cfg,
    );
    expect(v.outcome).toBe(ScrapeOutcome.DEGENERATE);
    expect(v.errorCode).toBe(ScrapeErrorCode.SCOPE_DRIFT);
  });

  it("passes healthy results as indexed", () => {
    const v = evaluateOutcome(
      {
        documentCount: 50,
        distinctUrls: 40,
        pagesScraped: 40,
        inScopeUrlRatio: 0.95,
        expectTermsMatched: true,
      },
      cfg,
    );
    expect(v.outcome).toBe(ScrapeOutcome.INDEXED);
    expect(v.errorCode).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run src/pipeline/outcomeGate.test.ts`
Expected: FAIL with "Cannot find module './outcomeGate'".

- [ ] **Step 3: Write the implementation**

```ts
import { ScrapeErrorCode, type JobOutcomeMetrics, ScrapeOutcome } from "./types";

/** Tunable thresholds for the outcome gate. Conservative defaults avoid false positives. */
export interface QualityGateConfig {
  /** Minimum stored chunks to count as more than "thin". Default 1 (only 0 is blocked). */
  minDocs: number;
  /** Minimum fraction of indexed URLs under the requested root before SCOPE_DRIFT. */
  minInScopeRatio: number;
}

export const DEFAULT_QUALITY_GATE: QualityGateConfig = {
  minDocs: 1,
  minInScopeRatio: 0.25,
};

/** Verdict returned by the quality gate. */
export interface OutcomeVerdict {
  outcome: ScrapeOutcome;
  errorCode?: ScrapeErrorCode;
  /** Human-readable, caller-facing fix suggestion (only when failing). */
  remediation?: string;
}

/**
 * Classifies a finished scrape from its metrics. Pure: no I/O, fully unit-testable.
 * Order: empty -> thin -> relevance (off-topic before scope-drift) -> indexed.
 */
export function evaluateOutcome(
  metrics: JobOutcomeMetrics,
  config: QualityGateConfig = DEFAULT_QUALITY_GATE,
): OutcomeVerdict {
  if (metrics.documentCount === 0) {
    return {
      outcome: ScrapeOutcome.EMPTY,
      errorCode: ScrapeErrorCode.EMPTY_RESULT,
      remediation:
        "The crawl finished but indexed no content. Check the URL is reachable, " +
        "renders without JavaScript gating, and is not a redirect/anti-bot wall.",
    };
  }

  if (metrics.documentCount < config.minDocs) {
    return {
      outcome: ScrapeOutcome.THIN,
      errorCode: ScrapeErrorCode.THIN_RESULT,
      remediation:
        `Only ${metrics.documentCount} chunk(s) indexed (min ${config.minDocs}). ` +
        "Widen maxPages/maxDepth or point at a richer docs root.",
    };
  }

  if (metrics.expectTermsMatched === false) {
    return {
      outcome: ScrapeOutcome.DEGENERATE,
      errorCode: ScrapeErrorCode.OFF_TOPIC,
      remediation:
        "Indexed content did not contain the expected terms. The source likely " +
        "covers a different topic than requested; pick a more specific URL.",
    };
  }

  if (
    metrics.inScopeUrlRatio !== undefined &&
    metrics.inScopeUrlRatio < config.minInScopeRatio
  ) {
    return {
      outcome: ScrapeOutcome.DEGENERATE,
      errorCode: ScrapeErrorCode.SCOPE_DRIFT,
      remediation:
        `Only ${Math.round(metrics.inScopeUrlRatio * 100)}% of indexed URLs are under ` +
        "the requested path. Narrow the URL or set denyPaths/includePatterns.",
    };
  }

  return { outcome: ScrapeOutcome.INDEXED };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run src/pipeline/outcomeGate.test.ts`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add src/pipeline/outcomeGate.ts src/pipeline/outcomeGate.test.ts
git commit -m "feat(pipeline): add pure evaluateOutcome quality classifier"
```

### Task 3: `getVersionMetrics()` store accessor

**Files:**
- Modify: `src/store/DocumentManagementService.ts`
- Test: `src/store/DocumentManagementService.test.ts` (append a test)

- [ ] **Step 1: Write the failing test**

Append to the existing `DocumentManagementService.test.ts` describe block (reuse its store setup helper):

```ts
it("getVersionMetrics returns document and distinct-url counts", async () => {
  await docService.addScrapeResult("lib", "1.0.0", /* ScrapeResult fixture */ makeResult());
  const m = await docService.getVersionMetrics("lib", "1.0.0");
  expect(m.documentCount).toBeGreaterThan(0);
  expect(m.distinctUrls).toBeGreaterThan(0);
});
```

(Use the file's existing `makeResult()`/fixture helper; if none, build a minimal `ScrapeResult` with one document, mirroring other tests in this file.)

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run src/store/DocumentManagementService.test.ts -t getVersionMetrics`
Expected: FAIL with "getVersionMetrics is not a function".

- [ ] **Step 3: Implement, reusing the existing `queryLibraryVersions` count query**

Add to `DocumentManagementService`:

```ts
  /**
   * Returns chunk and distinct-URL counts for a specific (library, version).
   * Reuses the aggregate computed by the store's version listing.
   */
  async getVersionMetrics(
    library: string,
    version?: string | null,
  ): Promise<{ documentCount: number; distinctUrls: number }> {
    const normalizedVersion = this.normalizeVersion(version);
    const summaries = await this.store.queryLibraryVersions();
    const entry = summaries
      .get(library.toLowerCase())
      ?.find((v) => (v.version ?? "") === (normalizedVersion ?? ""));
    return {
      documentCount: entry?.documentCount ?? 0,
      distinctUrls: entry?.uniqueUrlCount ?? 0,
    };
  }
```

(Verify the exact return shape of `store.queryLibraryVersions()` — `Map<string, Array<{version, documentCount, uniqueUrlCount, ...}>>` per `DocumentStore.ts:1318`. Adjust key casing to match `normalizeVersion`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run src/store/DocumentManagementService.test.ts -t getVersionMetrics`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/store/DocumentManagementService.ts src/store/DocumentManagementService.test.ts
git commit -m "feat(store): add getVersionMetrics accessor for quality gates"
```

---

## Milestone M2 — Gate-then-rollback seam (hard-fail)

**Agent:** backend-specialist

### Task 4: `applyQualityGate()` seam in PipelineManager

**Files:**
- Modify: `src/pipeline/PipelineManager.ts` (seam at the `COMPLETED` block, ~line 660-668)
- Test: `src/pipeline/PipelineManager.test.ts` (append)

- [ ] **Step 1: Write the failing test**

Append to `PipelineManager.test.ts` (reuse its existing manager+mock-store harness):

```ts
it("rolls back and fails the job when the gate returns empty", async () => {
  // Arrange: a store whose getVersionMetrics reports zero docs after scrape.
  vi.spyOn(docService, "getVersionMetrics").mockResolvedValue({
    documentCount: 0,
    distinctUrls: 0,
  });
  const removeSpy = vi.spyOn(docService, "removeVersion").mockResolvedValue();

  const jobId = await manager.enqueueScrapeJob("lib", "1.0.0", { url: "https://x/tree" });
  await manager.waitForJobCompletion(jobId).catch(() => {}); // gate failure rejects

  const job = await manager.getJob(jobId);
  expect(job?.status).toBe(PipelineJobStatus.FAILED);
  expect(job?.outcome).toBe(ScrapeOutcome.EMPTY);
  expect(job?.errorCode).toBe(ScrapeErrorCode.EMPTY_RESULT);
  expect(removeSpy).toHaveBeenCalledWith("lib", "1.0.0");
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run src/pipeline/PipelineManager.test.ts -t "rolls back"`
Expected: FAIL (job is COMPLETED, `outcome` undefined).

- [ ] **Step 3: Add the private seam method**

Add to `PipelineManager` (new method, keeps the seam tiny):

```ts
  /**
   * Runs quality gates on a finished job. On a failing verdict, discards the staged
   * version (gate-then-rollback) and returns the verdict; otherwise returns null.
   */
  private async applyQualityGate(
    job: InternalPipelineJob,
  ): Promise<OutcomeVerdict | null> {
    const counts = await this.store.getVersionMetrics(job.library, job.version);
    const metrics: JobOutcomeMetrics = {
      documentCount: counts.documentCount,
      distinctUrls: counts.distinctUrls,
      pagesScraped: job.progressPages ?? 0,
      // relevance inputs filled in M4; undefined here means "skip those checks"
    };
    const verdict = evaluateOutcome(metrics);
    if (verdict.outcome === ScrapeOutcome.INDEXED) {
      job.outcome = ScrapeOutcome.INDEXED;
      return null;
    }
    logger.warn(
      `❌ Quality gate failed for ${job.library}@${job.version}: ` +
        `${verdict.outcome} (${verdict.errorCode}) — discarding staged docs`,
    );
    await this.documentManagementService.removeVersion(job.library, job.version);
    job.outcome = verdict.outcome;
    job.errorCode = verdict.errorCode;
    return verdict;
  }
```

(Note: `this.store` here is the `DocumentManagementService` instance the manager already holds — confirm the field name; it exposes both `getVersionMetrics` and `removeVersion`.)

- [ ] **Step 4: Wire the seam into the COMPLETED block**

Replace the success block (currently around lines 659-668):

```ts
      // If executeJob completes without throwing, and we weren't cancelled meanwhile...
      if (signal.aborted) {
        throw new CancellationError("Job cancelled just before completion");
      }

      // Quality gate: only promote to COMPLETED if useful docs were indexed.
      const gateFailure = await this.applyQualityGate(job);
      if (gateFailure) {
        await this.updateJobStatus(
          job,
          PipelineJobStatus.FAILED,
          gateFailure.remediation,
        );
        job.errorCode = gateFailure.errorCode;
        job.finishedAt = new Date();
        const err = new QualityGateError(gateFailure);
        job.error = err;
        logger.info(`❌ Job failed quality gate: ${jobId}: ${gateFailure.errorCode}`);
        job.rejectCompletion(err);
        return;
      }

      // Mark as completed
      await this.updateJobStatus(job, PipelineJobStatus.COMPLETED);
      job.finishedAt = new Date();
      job.resolveCompletion();
      logger.info(`✅ Job completed: ${jobId}`);
```

Add `QualityGateError` to `src/utils/errors.ts`:

```ts
/** Raised when a scrape finished but failed a quality gate (empty/thin/degenerate). */
export class QualityGateError extends Error {
  constructor(public readonly verdict: OutcomeVerdict) {
    super(verdict.remediation ?? `Quality gate failed: ${verdict.outcome}`);
    this.name = "QualityGateError";
  }
}
```

Add imports at the top of `PipelineManager.ts`:

```ts
import { evaluateOutcome, type OutcomeVerdict } from "./outcomeGate";
import { type JobOutcomeMetrics, ScrapeOutcome } from "./types";
import { QualityGateError } from "../utils/errors";
```

- [ ] **Step 5: Run test to verify it passes**

Run: `npx vitest run src/pipeline/PipelineManager.test.ts -t "rolls back"`
Expected: PASS.

- [ ] **Step 6: Run the full pipeline suite for regressions**

Run: `npx vitest run src/pipeline/`
Expected: PASS (existing happy-path jobs still COMPLETE because real stores report > 0 docs).

- [ ] **Step 7: Commit**

```bash
git add src/pipeline/PipelineManager.ts src/pipeline/PipelineManager.test.ts src/utils/errors.ts
git commit -m "feat(pipeline): hard-fail and roll back jobs that fail the quality gate"
```

### Task 5: E2E — failed gate leaves nothing searchable

**Files:**
- Test: `test/quality-gate-e2e.test.ts` (new)

- [ ] **Step 1: Write the failing E2E test**

```ts
import { describe, expect, it } from "vitest";
// Reuse the in-process harness used by vector-search-e2e.test.ts (MSW-mocked embeddings).

describe("quality gate e2e", () => {
  it("a scrape that indexes nothing is not searchable and reports EMPTY_RESULT", async () => {
    const { jobId } = await scrapeAndWait({
      url: "file:///empty-fixture/", // fixture dir with no indexable files
      library: "emptylib",
      version: "1.0.0",
    });
    const info = await getJobInfo(jobId);
    expect(info.status).toBe("failed");
    expect(info.errorCode).toBe("EMPTY_RESULT");

    const results = await searchDocs("emptylib", "1.0.0", "anything");
    expect(results).toHaveLength(0); // rolled back, not garbage
  });
});
```

(Model the harness helpers on `test/vector-search-e2e.test.ts`. Create `test/fixtures/empty-fixture/` containing only a non-indexable file, e.g. an empty `.png`.)

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run test/quality-gate-e2e.test.ts`
Expected: FAIL (today status is `completed`).

- [ ] **Step 3: Make it pass** — no new code; this validates Task 4. If it fails, fix the seam.

- [ ] **Step 4: Commit**

```bash
git add test/quality-gate-e2e.test.ts test/fixtures/empty-fixture/
git commit -m "test(e2e): assert failed quality gate leaves store empty"
```

---

## Milestone M3 — FM-3 (GitHub subpath) + FM-1 (locale)

**Agent:** backend-specialist

### Task 6: Capture the real GitHub tree fixture

**Files:**
- Create: `test/fixtures/github-tree-generative-ai-docs.json`

- [ ] **Step 1: Save the deterministic snapshot** (already fetched during design; re-fetch to refresh)

```bash
curl -s "https://api.github.com/repos/google/generative-ai-docs/git/trees/main?recursive=1" \
  -o test/fixtures/github-tree-generative-ai-docs.json
node -e 'const t=require("./test/fixtures/github-tree-generative-ai-docs.json");console.log("entries",t.tree.length,"truncated",t.truncated)'
```

Expected: `entries 1045 truncated false` (or similar; truncated must be false).

- [ ] **Step 2: Commit the fixture**

```bash
git add test/fixtures/github-tree-generative-ai-docs.json
git commit -m "test(fixtures): add real github tree snapshot for scope tests"
```

### Task 7: FM-3 — typed error on zero-match GitHub subpath

**Files:**
- Modify: `src/utils/errors.ts` (add optional `code` to `ScraperError`)
- Modify: `src/scraper/strategies/GitHubScraperStrategy.ts` (after `fileItems` computed, ~line 650)
- Test: `src/scraper/strategies/GitHubScraperStrategy.test.ts` (append)

- [ ] **Step 1: Write the failing test**

```ts
it("throws GITHUB_SUBPATH_NOT_FOUND when a /tree/ subpath matches no files", async () => {
  const tree = require("../../../test/fixtures/github-tree-generative-ai-docs.json");
  vi.spyOn(strategy as any, "fetchRepositoryTree").mockResolvedValue({
    tree,
    resolvedBranch: "main",
  });
  await expect(
    strategy.processItem(
      { url: "https://github.com/google/generative-ai-docs/tree/main/docs", depth: 0 },
      { url: "https://github.com/google/generative-ai-docs/tree/main/docs" } as any,
    ),
  ).rejects.toMatchObject({ code: "GITHUB_SUBPATH_NOT_FOUND" });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run src/scraper/strategies/GitHubScraperStrategy.test.ts -t GITHUB_SUBPATH`
Expected: FAIL (currently returns SUCCESS with only the wiki link).

- [ ] **Step 3: Add optional `code` to `ScraperError`**

In `src/utils/errors.ts`, extend the `ScraperError` constructor (keep existing positional args; add an optional field):

```ts
export class ScraperError extends Error {
  /** Optional machine-readable code surfaced to callers as errorCode. */
  public code?: string;
  constructor(message: string, isRetryable = false, cause?: Error) {
    super(message);
    this.name = "ScraperError";
    this.isRetryable = isRetryable;
    this.cause = cause;
  }
}
```

(Match the file's actual current field names — `isRetryable`/`cause` — do not rename them.)

- [ ] **Step 4: Add the guard in `GitHubScraperStrategy.processItem`**

Immediately after the `fileItems` filter (line ~650), before building `fileUrls`:

```ts
      if (repoInfo.subPath && fileItems.length === 0) {
        const topDirs = [
          ...new Set(
            tree.tree
              .filter((t) => t.type === "blob")
              .map((t) => t.path.split("/")[0]),
          ),
        ]
          .sort()
          .slice(0, 20);
        const err = new ScraperError(
          `GitHub subpath "${repoInfo.subPath}" matched no files in ` +
            `${owner}/${repo}@${resolvedBranch}. Available top-level paths: ${topDirs.join(", ")}.`,
          false,
        );
        err.code = "GITHUB_SUBPATH_NOT_FOUND";
        throw err;
      }
```

- [ ] **Step 5: Map `ScraperError.code` to the job in the manager catch block**

In `PipelineManager.ts`, inside the existing `else` (other-errors) branch of the catch (~line 685), before `updateJobStatus(... FAILED ...)`:

```ts
        if (error instanceof ScraperError && error.code) {
          job.errorCode = error.code as ScrapeErrorCode;
        }
```

- [ ] **Step 6: Run tests to verify pass**

Run: `npx vitest run src/scraper/strategies/GitHubScraperStrategy.test.ts -t GITHUB_SUBPATH`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/utils/errors.ts src/scraper/strategies/GitHubScraperStrategy.ts src/pipeline/PipelineManager.ts src/scraper/strategies/GitHubScraperStrategy.test.ts
git commit -m "feat(github): fail with GITHUB_SUBPATH_NOT_FOUND on zero-match subpath"
```

### Task 8: FM-1 — locale normalization + cyclic redirect detection

**Files:**
- Modify: `src/scraper/types.ts` (add `localeStrategy?` to `ScraperOptions`)
- Modify: `src/scraper/fetcher/HttpFetcher.ts` (Accept-Language + strip query locale + cycle check)
- Test: `src/scraper/fetcher/HttpFetcher.test.ts` (append)

- [ ] **Step 1: Add the option**

In `ScraperOptions` (`src/scraper/types.ts`), additive:

```ts
  /**
   * Locale handling for fetched URLs.
   * - 'pin-en': send `Accept-Language: en` and strip `hl`/`lang`/`locale` query params (default)
   * - 'strip': strip locale query params, no Accept-Language override
   * - 'passthrough': leave URL and headers unchanged
   * @default 'pin-en'
   */
  localeStrategy?: "pin-en" | "strip" | "passthrough";
```

- [ ] **Step 2: Write the failing tests**

```ts
it("aborts with LOCALE_REDIRECT_LOOP on a cyclic ?hl redirect", async () => {
  // mock server: /docs -> /docs?hl=pt -> /docs?hl=en -> /docs?hl=pt ...
  await expect(fetcher.fetch(`${base}/docs`, { localeStrategy: "passthrough" })).rejects.toMatchObject(
    { code: "LOCALE_REDIRECT_LOOP" },
  );
});

it("pins Accept-Language and strips hl with pin-en", async () => {
  const res = await fetcher.fetch(`${base}/docs?hl=pt-br`, { localeStrategy: "pin-en" });
  expect(res.requestHeaders?.["accept-language"]).toBe("en");
  expect(res.finalUrl).not.toMatch(/hl=/);
});
```

(Use the existing `HttpFetcher.test.ts` mock-server pattern — it already spins up local servers for redirect tests.)

- [ ] **Step 3: Run to verify fail**

Run: `npx vitest run src/scraper/fetcher/HttpFetcher.test.ts -t LOCALE`
Expected: FAIL.

- [ ] **Step 4: Implement**

In `HttpFetcher.fetch`, before issuing the request:

```ts
    const localeStrategy = options?.localeStrategy ?? "pin-en";
    let requestUrl = url;
    if (localeStrategy !== "passthrough") {
      const u = new URL(requestUrl);
      for (const p of ["hl", "lang", "locale"]) u.searchParams.delete(p);
      requestUrl = u.toString();
    }
    const localeHeaders =
      localeStrategy === "pin-en" ? { "Accept-Language": "en" } : {};
```

Merge `localeHeaders` into the axios request headers. In the redirect-follow loop (around line 120-201), track seen locations and detect a cycle within the existing `MAX_REDIRECTS` cap:

```ts
    const seenLocations = new Set<string>();
    // inside the while loop, after resolving `location`:
    const normalizedLoc = new URL(location, currentUrl).toString();
    if (seenLocations.has(normalizedLoc)) {
      const err = new ScraperError(
        `Redirect loop detected at ${normalizedLoc} (cyclic Location).`,
        false,
      );
      err.code = "LOCALE_REDIRECT_LOOP";
      throw err;
    }
    seenLocations.add(normalizedLoc);
```

- [ ] **Step 5: Run to verify pass**

Run: `npx vitest run src/scraper/fetcher/HttpFetcher.test.ts -t LOCALE`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/scraper/types.ts src/scraper/fetcher/HttpFetcher.ts src/scraper/fetcher/HttpFetcher.test.ts
git commit -m "feat(fetcher): pin-en locale normalization and cyclic-redirect detection"
```

---

## Milestone M4 — FM-2 (denyPaths + relevance gate)

**Agent:** backend-specialist → test-writer

### Task 9: `denyPaths` option applied in GitHub + web scope

**Files:**
- Modify: `src/scraper/types.ts` (add `denyPaths?`)
- Modify: `src/scraper/strategies/GitHubScraperStrategy.ts` (`shouldProcessFile`)
- Modify: `src/scraper/utils/scope.ts` or `BaseScraperStrategy.shouldProcessUrl` (web crawl)
- Test: `src/scraper/strategies/GitHubScraperStrategy.test.ts` (append)

- [ ] **Step 1: Add the option with a conservative default**

In `ScraperOptions`:

```ts
  /**
   * Glob patterns (micromatch) whose matching paths are excluded from indexing,
   * even when in scope. Applied on top of scope/includePatterns.
   * @default ["**\/demos/**", "**\/examples/**"]
   */
  denyPaths?: string[];
```

Define the default constant next to the other scraper defaults (e.g. `src/utils/config.ts` scraper block) so it resolves once:

```ts
export const DEFAULT_DENY_PATHS = ["**/demos/**", "**/examples/**"];
```

- [ ] **Step 2: Write the failing test**

```ts
it("denyPaths excludes demos/** from a repo-root crawl", async () => {
  const tree = require("../../../test/fixtures/github-tree-generative-ai-docs.json");
  vi.spyOn(strategy as any, "fetchRepositoryTree").mockResolvedValue({ tree, resolvedBranch: "main" });
  const res = await strategy.processItem(
    { url: "https://github.com/google/generative-ai-docs", depth: 0 },
    { url: "https://github.com/google/generative-ai-docs", denyPaths: ["**/demos/**"] } as any,
  );
  const demoLinks = res.links.filter((l) => l.includes("/demos/"));
  expect(demoLinks).toHaveLength(0);
  expect(res.links.some((l) => l.includes("/site/"))).toBe(true);
});
```

- [ ] **Step 3: Run to verify fail**

Run: `npx vitest run src/scraper/strategies/GitHubScraperStrategy.test.ts -t denyPaths`
Expected: FAIL (demos currently included — 679 of them).

- [ ] **Step 4: Implement in `shouldProcessFile`**

At the top of `shouldProcessFile` (after the `item.type !== "blob"` guard), reuse the existing `micromatch`/`patternMatcher` util:

```ts
    const denyPaths = options.denyPaths ?? DEFAULT_DENY_PATHS;
    if (denyPaths.length > 0 && isMatch(item.path, denyPaths)) {
      return false;
    }
```

(Use the project's existing matcher — check `src/scraper/utils/patternMatcher.ts` for the exported `isMatch`/`shouldIncludeUrl` helper and reuse it rather than importing micromatch directly.)

For web crawls, add the same `denyPaths` check inside `BaseScraperStrategy.shouldProcessUrl` against the URL pathname.

- [ ] **Step 5: Run to verify pass**

Run: `npx vitest run src/scraper/strategies/GitHubScraperStrategy.test.ts -t denyPaths`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/scraper/types.ts src/utils/config.ts src/scraper/strategies/GitHubScraperStrategy.ts src/scraper/strategies/BaseScraperStrategy.ts src/scraper/strategies/GitHubScraperStrategy.test.ts
git commit -m "feat(scraper): add denyPaths to exclude demos/examples from indexing"
```

### Task 10: `relevanceGate` — path coherence + expectTerms sampling

**Files:**
- Create: `src/pipeline/relevanceGate.ts`
- Test: `src/pipeline/relevanceGate.test.ts`
- Modify: `src/scraper/types.ts` (add `expectTerms?`)

- [ ] **Step 1: Add the option**

```ts
  /**
   * Optional terms expected to appear in the indexed docs. When set, the quality gate
   * samples stored chunks and fails as OFF_TOPIC if none match.
   */
  expectTerms?: string[];
```

- [ ] **Step 2: Write the failing test**

```ts
import { describe, expect, it } from "vitest";
import { computeInScopeRatio, sampleExpectTermsMatch } from "./relevanceGate";

describe("relevanceGate", () => {
  it("computes the fraction of URLs under the requested root", () => {
    const ratio = computeInScopeRatio("https://github.com/o/r", [
      "https://github.com/o/r/blob/main/site/a.md",
      "https://github.com/o/r/blob/main/demos/x.js",
      "https://github.com/o/r/blob/main/demos/y.js",
    ]);
    expect(ratio).toBeCloseTo(1.0); // all under /o/r
  });

  it("matches expectTerms against sampled chunk text (keyword path)", () => {
    const matched = sampleExpectTermsMatch(
      ["use generateContent to call the model", "unrelated text"],
      ["generateContent"],
    );
    expect(matched).toBe(true);
  });

  it("reports no match when terms are absent", () => {
    const matched = sampleExpectTermsMatch(["list-it demo", "mood-food demo"], ["generateContent"]);
    expect(matched).toBe(false);
  });
});
```

- [ ] **Step 3: Run to verify fail**

Run: `npx vitest run src/pipeline/relevanceGate.test.ts`
Expected: FAIL ("Cannot find module './relevanceGate'").

- [ ] **Step 4: Implement (keyword path first; cosine optional behind the same fn)**

```ts
/** Fraction (0..1) of `indexedUrls` whose path is under the requested root URL's path. */
export function computeInScopeRatio(rootUrl: string, indexedUrls: string[]): number {
  if (indexedUrls.length === 0) return 0;
  const root = new URL(rootUrl);
  const rootPrefix = root.pathname.replace(/\/+$/, "");
  const inScope = indexedUrls.filter((u) => {
    try {
      const p = new URL(u);
      return p.hostname === root.hostname && p.pathname.startsWith(rootPrefix);
    } catch {
      return false;
    }
  }).length;
  return inScope / indexedUrls.length;
}

/** True if any sampled chunk contains any expected term (case-insensitive substring). */
export function sampleExpectTermsMatch(chunks: string[], expectTerms: string[]): boolean {
  if (expectTerms.length === 0) return true;
  const haystack = chunks.join("\n").toLowerCase();
  return expectTerms.some((t) => haystack.includes(t.toLowerCase()));
}
```

- [ ] **Step 5: Run to verify pass**

Run: `npx vitest run src/pipeline/relevanceGate.test.ts`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/pipeline/relevanceGate.ts src/pipeline/relevanceGate.test.ts src/scraper/types.ts
git commit -m "feat(pipeline): add relevance gate (path coherence + expectTerms match)"
```

### Task 11: Wire relevance signals into the manager seam

**Files:**
- Modify: `src/pipeline/PipelineManager.ts` (`applyQualityGate` — fill relevance inputs)
- Modify: `src/store/DocumentManagementService.ts` (add `sampleChunks(library, version, limit)` + `listIndexedUrls(library, version)`)
- Test: `src/pipeline/PipelineManager.test.ts` (append)

- [ ] **Step 1: Write the failing test**

```ts
it("fails as OFF_TOPIC when expectTerms are absent from sampled chunks", async () => {
  vi.spyOn(docService, "getVersionMetrics").mockResolvedValue({ documentCount: 50, distinctUrls: 40 });
  vi.spyOn(docService, "sampleChunks").mockResolvedValue(["list-it demo", "mood-food demo"]);
  vi.spyOn(docService, "listIndexedUrls").mockResolvedValue([]);
  const removeSpy = vi.spyOn(docService, "removeVersion").mockResolvedValue();

  const jobId = await manager.enqueueScrapeJob("gemini", "1.0.0", {
    url: "https://github.com/google/generative-ai-docs",
    expectTerms: ["generateContent"],
  });
  await manager.waitForJobCompletion(jobId).catch(() => {});
  const job = await manager.getJob(jobId);
  expect(job?.errorCode).toBe(ScrapeErrorCode.OFF_TOPIC);
  expect(removeSpy).toHaveBeenCalled();
});
```

- [ ] **Step 2: Run to verify fail**

Run: `npx vitest run src/pipeline/PipelineManager.test.ts -t OFF_TOPIC`
Expected: FAIL.

- [ ] **Step 3: Add the two store accessors**

In `DocumentManagementService` (reuse existing query patterns; `sampleChunks` selects up to `limit` `content` rows; `listIndexedUrls` selects distinct `pages.url`):

```ts
  /** Returns up to `limit` chunk contents for sampling-based relevance checks. */
  async sampleChunks(library: string, version: string | null, limit = 20): Promise<string[]> {
    return this.store.sampleChunkContents(library, this.normalizeVersion(version), limit);
  }

  /** Returns the distinct indexed URLs for a (library, version). */
  async listIndexedUrls(library: string, version: string | null): Promise<string[]> {
    return this.store.listPageUrls(library, this.normalizeVersion(version));
  }
```

Add the matching prepared statements `sampleChunkContents` / `listPageUrls` to `DocumentStore` (mirror existing `queryLibraryVersions` SQL style; `SELECT content FROM documents JOIN pages ... LIMIT ?` and `SELECT DISTINCT url FROM pages ...`).

- [ ] **Step 4: Fill relevance inputs in `applyQualityGate`**

Extend the metrics built in Task 4:

```ts
    const opts = job.scraperOptions;
    let inScopeUrlRatio: number | undefined;
    let expectTermsMatched: boolean | undefined;
    if (opts.expectTerms?.length || opts.url) {
      const urls = await this.store.listIndexedUrls(job.library, job.version);
      inScopeUrlRatio = urls.length ? computeInScopeRatio(opts.url, urls) : undefined;
    }
    if (opts.expectTerms?.length) {
      const chunks = await this.store.sampleChunks(job.library, job.version, 20);
      expectTermsMatched = sampleExpectTermsMatch(chunks, opts.expectTerms);
    }
    const metrics: JobOutcomeMetrics = {
      documentCount: counts.documentCount,
      distinctUrls: counts.distinctUrls,
      pagesScraped: job.progressPages ?? 0,
      inScopeUrlRatio,
      expectTermsMatched,
    };
```

Add imports: `import { computeInScopeRatio, sampleExpectTermsMatch } from "./relevanceGate";`

- [ ] **Step 5: Run to verify pass**

Run: `npx vitest run src/pipeline/PipelineManager.test.ts -t OFF_TOPIC`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/pipeline/PipelineManager.ts src/store/DocumentManagementService.ts src/store/DocumentStore.ts src/pipeline/PipelineManager.test.ts
git commit -m "feat(pipeline): apply relevance gate (expectTerms, scope drift) at job end"
```

---

## Milestone M5 — Expose outcome + errorCode (DX)

**Agent:** backend-specialist → documentation-writer

### Task 12: Surface `outcome` + `errorCode` in job tools

**Files:**
- Modify: `src/tools/GetJobInfoTool.ts` (`JobInfo` interface + mapping)
- Modify: `src/tools/ListJobsTool.ts` (same mapping)
- Test: `src/tools/GetJobInfoTool.test.ts` (append)

- [ ] **Step 1: Write the failing test**

```ts
it("exposes outcome and errorCode for a gate-failed job", async () => {
  pipeline.getJob = vi.fn().mockResolvedValue({
    id: "j1", library: "x", version: "1", status: PipelineJobStatus.FAILED,
    outcome: ScrapeOutcome.EMPTY, errorCode: ScrapeErrorCode.EMPTY_RESULT,
    createdAt: new Date(), startedAt: null, finishedAt: null, error: null,
  });
  const res = await tool.execute({ jobId: "j1" });
  expect(res.job.outcome).toBe("empty");
  expect(res.job.errorCode).toBe("EMPTY_RESULT");
});
```

- [ ] **Step 2: Run to verify fail**

Run: `npx vitest run src/tools/GetJobInfoTool.test.ts -t errorCode`
Expected: FAIL (`outcome`/`errorCode` not on `JobInfo`).

- [ ] **Step 3: Extend `JobInfo` and the mapping**

Add to the `JobInfo` interface:

```ts
  /** Quality classification of the finished job. */
  outcome?: ScrapeOutcome;
  /** Typed gate-failure reason with remediation in `errorMessage`. */
  errorCode?: ScrapeErrorCode;
```

In the `execute()` mapping (both tools), add:

```ts
    outcome: job.outcome,
    errorCode: job.errorCode,
```

- [ ] **Step 4: Run to verify pass**

Run: `npx vitest run src/tools/GetJobInfoTool.test.ts -t errorCode`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/tools/GetJobInfoTool.ts src/tools/ListJobsTool.ts src/tools/GetJobInfoTool.test.ts
git commit -m "feat(tools): expose scrape outcome and errorCode in job info"
```

### Task 13: Plumb new options through `scrape_docs`

**Files:**
- Modify: `src/tools/ScrapeTool.ts` (accept + forward `denyPaths`, `localeStrategy`, `expectTerms`)
- Modify: `src/mcp/mcpServer.ts` (declare the new optional params in the `scrape_docs` zod schema)
- Test: `src/tools/ScrapeTool.test.ts` (append)

- [ ] **Step 1: Write the failing test**

```ts
it("forwards expectTerms and denyPaths into the scraper options", async () => {
  const enqueue = vi.spyOn(pipeline, "enqueueScrapeJob").mockResolvedValue("j1");
  await tool.execute({
    url: "https://github.com/google/generative-ai-docs",
    library: "gemini",
    waitForCompletion: false,
    options: { expectTerms: ["generateContent"], denyPaths: ["**/demos/**"] },
  });
  expect(enqueue).toHaveBeenCalledWith(
    "gemini", expect.anything(),
    expect.objectContaining({ expectTerms: ["generateContent"], denyPaths: ["**/demos/**"] }),
  );
});
```

- [ ] **Step 2: Run to verify fail**

Run: `npx vitest run src/tools/ScrapeTool.test.ts -t forwards`
Expected: FAIL (options dropped).

- [ ] **Step 3: Thread the options through**

In `ScrapeTool.execute`, include the new fields when building the scraper options passed to `enqueueScrapeJob` (they are optional; spread from `options`). In `mcpServer.ts`, add to the `scrape_docs` zod schema:

```ts
  expectTerms: z.array(z.string()).optional()
    .describe("Terms expected in the docs; off-topic scrapes fail with OFF_TOPIC."),
  denyPaths: z.array(z.string()).optional()
    .describe("Glob paths excluded from indexing (default: demos/examples)."),
  localeStrategy: z.enum(["pin-en", "strip", "passthrough"]).optional()
    .describe("Locale handling for fetched URLs (default pin-en)."),
```

- [ ] **Step 4: Run to verify pass**

Run: `npx vitest run src/tools/ScrapeTool.test.ts -t forwards`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/tools/ScrapeTool.ts src/mcp/mcpServer.ts src/tools/ScrapeTool.test.ts
git commit -m "feat(mcp): accept expectTerms, denyPaths, localeStrategy in scrape_docs"
```

### Task 14: Docs + full suite + PR prep

**Files:**
- Modify: `README.md` (scrape_docs params), `ARCHITECTURE.md` (quality-gate flow)

- [ ] **Step 1: Document the new params and outcome model** in `README.md` (scrape_docs table) and a short "Quality Gates" subsection in `ARCHITECTURE.md` describing the gate-then-rollback flow and the `errorCode` list.

- [ ] **Step 2: Run the full default suite**

Run: `npm test`
Expected: PASS (live/docker suites excluded per AGENTS.md).

- [ ] **Step 3: Lint + typecheck**

Run: `npm run lint && npm run typecheck`
Expected: PASS.

- [ ] **Step 4: Commit docs**

```bash
git add README.md ARCHITECTURE.md
git commit -m "docs(scrape): document quality gates, outcome model, and new options"
```

- [ ] **Step 5: Open the upstream PR** (English, full justification)

Push the branch and open a PR against `arabold/docs-mcp-server` whose description includes: the three failure modes with the real evidence (`679/1045` demos; subpath 0-match table), the gate-then-rollback design, the additive/opt-out-safe API, the milestone-by-milestone implementation walkthrough, and the test matrix. Reference this plan and the spec.

---

## Self-Review

**Spec coverage:**
- FM-1 (locale/empty) → Task 2 (EMPTY), Task 8 (locale + LOCALE_REDIRECT_LOOP). ✓
- FM-2 (off-topic subtree) → Task 9 (denyPaths), Task 10/11 (relevance: OFF_TOPIC, SCOPE_DRIFT). ✓
- FM-3 (silent no-op subpath) → Task 7 (GITHUB_SUBPATH_NOT_FOUND) + Task 4 (EMPTY fallback). ✓
- Gate-then-rollback hard-fail → Task 4 (reuses `removeVersion`). ✓
- Outcome enum + expose → Task 1, Task 12. ✓
- Additive API (`denyPaths`/`localeStrategy`/`expectTerms`) → Task 8/9/10/13. ✓
- Typed errorCodes in get_job_info → Task 12. ✓
- Real fixture, no network → Task 6. ✓
- Upstream PR-shaped → new files + single seams; Task 14 PR. ✓
- Out of scope (discover_source, staging-real, tree pagination) → not in any task. ✓

**Placeholder scan:** Test bodies that reuse existing harnesses (PipelineManager.test, HttpFetcher.test, vector-search-e2e) are marked to mirror those files — acceptable because the harness already exists; the worker must read the neighboring test for the exact setup helper. No "TODO/TBD" in implementation steps.

**Type consistency:** `ScrapeOutcome`, `ScrapeErrorCode`, `JobOutcomeMetrics`, `OutcomeVerdict`, `QualityGateConfig`, `evaluateOutcome`, `computeInScopeRatio`, `sampleExpectTermsMatch`, `getVersionMetrics`, `sampleChunks`, `listIndexedUrls`, `applyQualityGate`, `QualityGateError` — names used consistently across Tasks 1–13. `ScraperError.code` (string) is mapped to `ScrapeErrorCode` at the manager boundary (Task 7 Step 5).
