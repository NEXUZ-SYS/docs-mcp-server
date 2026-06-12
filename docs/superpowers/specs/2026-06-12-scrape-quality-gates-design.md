# Scrape Quality Gates — Design Spec

> **DevFlow workflow:** scrape-quality-gates | **Scale:** LARGE | **Phase:** P (design) → writing-plans
> **Date:** 2026-06-12
> **Status:** approved (design); pending implementation plan

## Problem

`docs-mcp-server` confunde **"o crawl terminou"** com **"indexei doc utilizável"**. Um job é
marcado `COMPLETED` sempre que o scraper retorna sem lançar erro
(`PipelineManager.ts:666`) — não há nenhum gate de qualidade. Resultado: três modos de
falha observados ao indexar a documentação do Gemini, todos reportados como `completed`.

### Modos de falha (com causa-raiz verificada no código + evidência real)

| # | Modo | Causa-raiz **verificada** | Hoje reporta |
|---|------|---------------------------|--------------|
| FM-1 | Vazio/abort — host hostil (SPA, redirect de locale `?hl=`) | Sem normalização de locale; página JS sem conteúdo extraível vira 0 docs sem sinal. `MAX_REDIRECTS=5` já existe, mas não há detecção de `Location` cíclico nem strip de `?hl`. | `completed` |
| FM-2 | Conteúdo errado — crawler indexa subárvore irrelevante | Scrape do **repo root** legitimamente inclui `demos/` como descendentes. Medido em `google/generative-ai-docs`: **679 de 1045 entradas estão sob `demos/`**, afogando os ~50 `.md` reais. Scope `subpages` não ajuda (demos *são* descendentes do root). | `completed` (não-vazio!) |
| FM-3 | No-op silencioso — GitHub `/tree/<branch>/<subPath>` indexa 0 | **A GitHub tree API retorna HTTP 200 com a árvore inteira independentemente do subPath; o subPath é filtrado client-side (`GitHubScraperStrategy.ts:649`).** Um subPath inexistente/typo/case-errado casa **0 arquivos** silenciosamente → discovery devolve só o link de wiki (404) → 0 docs → `completed` em ~0,4s. | `completed` |

**Evidência empírica do spike (snapshot real de `google/generative-ai-docs`, não-truncado, 1045 entradas):**

```
/tree/main/docs              -> 0 arquivos casados   (dir não existe)
/tree/main/gemini-api/docs   -> 0 arquivos casados   (path errado)
/tree/main/Site/en           -> 0 arquivos casados   (case errado)
/tree/main/site/en/gemini-api/docs -> 8 arquivos     (path correto)
```

### Por que o plano-base (rascunho M1–M6) mudou

A investigação do código mostrou que vários "fixes" propostos **já existem**:

| Rascunho assumiu | Realidade no repo | Efeito |
|---|---|---|
| M1: coletar métricas do zero | `pagesScraped`, `documentCount`, `uniqueUrlCount` já existem (`ScraperProgressEvent` `src/scraper/types.ts:163`; `queryLibraryVersions` `DocumentStore.ts:1318`) | M1 encolhe para **classificar + expor** |
| M2: staging→swap | escrita incremental per-page direto na versão viva (`PipelineWorker.ts:113`, `DocumentStore.addDocuments:1651`) | **gate-then-rollback** reusa `removeVersion()` |
| M4: apertar scope | scope `subpages` já restringe a path-prefix (`scope.ts` `isPathDescendant`, sem escape lateral) | scope não é o bug → **denyPaths + relevância** |
| M3: detector de loop de redirect | `MAX_REDIRECTS=5` já existe (`HttpFetcher.ts:28`) | falta só **locale-normalize** + detecção de ciclo |
| M5: render JS + reescrita GitHub p/ API | `ScrapeMode.Auto` já roda Playwright (`HtmlPlaywrightMiddleware:1080`); GitHub já usa a tree API recursiva | **M5 descartado**; FM-3 é subPath inexistente |

## Goal

Promover uma `(library, version)` para consultável **apenas se passar nos quality gates**.
Caso contrário, descartar o que foi indexado e devolver um **erro tipado com remediação**.

## Decisões de design (confirmadas com o usuário)

1. **FM-3:** re-diagnosticado agora (não assumido). Causa-raiz = filtro client-side de subPath sobre resposta 200.
2. **Publish atômico:** **gate-then-rollback** — mantém escrita incremental; ao reprovar no gate ao fim do job, `removeVersion()` descarta tudo. Reusa código existente.
3. **Gate de relevância:** `expectTerms[]` **opcional** no `scrape_docs` **+** heurística automática (coerência path/host + `denyPaths`).
4. **Rollout:** **hard-fail imediato** — gate-fail descarta e devolve erro tipado desde o primeiro release.
5. **Defaults conservadores:** `thin` só bloqueia 0 docs reais inicialmente; `denyPaths` default = `demos`/`examples`. Evita falso-positivo em scrapes legítimos pequenos.
6. **`discover_source`:** **fora de escopo** — anotado como plano futuro.

## Arquitetura

### Ponto de decisão único

Hoje (`PipelineManager.ts:659-668`):

```
executeJob() retorna sem throw  →  status = COMPLETED  →  resolveCompletion()
```

Novo:

```
executeJob() retorna sem throw
  → coleta JobOutcomeMetrics (contadores já existentes)
  → classifica ScrapeOutcome
  → se outcome ∈ {empty, thin, degenerate}:
        removeVersion(library, version)            // rollback
        status = FAILED, errorCode = <typed>       // hard-fail
     senão:
        status = COMPLETED, outcome = indexed
```

### Componentes (unidades isoladas, testáveis)

1. **`ScrapeOutcome` enum** — `src/pipeline/types.ts` (junto de `PipelineJobStatus`).
   `indexed | empty | thin | degenerate | failed`.

2. **`evaluateOutcome(metrics, options)`** — função pura nova (ex.: `src/pipeline/outcomeGate.ts`).
   Entrada: contadores do job + opções (thresholds, expectTerms). Saída:
   `{ outcome, errorCode?, remediation? }`. **Sem I/O** → unit-testável a 100%.

3. **Gate de relevância** — `src/pipeline/relevanceGate.ts`.
   - (a) coerência path/host: fração de URLs indexadas sob o root pedido.
   - (b) `expectTerms`: amostra N chunks via store, checa keyword ou cosine mínimo
     (reusa `embeddings.embedQuery` + `documents_vec`, já existentes).

4. **`denyPaths`** — novo campo em `ScraperOptions` (`src/scraper/types.ts`), default
   `["**/demos/**", "**/examples/**"]`. Aplicado em:
   - `GitHubScraperStrategy.shouldProcessFile` (corta os 679 demos no discovery).
   - `BaseScraperStrategy` scope check (web crawls).

5. **Locale normalization (FM-1)** — `HttpFetcher`.
   - `localeStrategy: "pin-en" | "strip" | "passthrough"` (default `pin-en`).
   - `pin-en`: header `Accept-Language: en` + strip de `hl`/`lang`/`locale` da query.
   - Detecção de `Location` cíclico dentro do cap de 5 hops → `LOCALE_REDIRECT_LOOP`.

6. **FM-3 específico** — `GitHubScraperStrategy`.
   - Quando `/tree/<branch>/<subPath>` filtra a árvore para **0 itens** →
     `GITHUB_SUBPATH_NOT_FOUND`, remediação lista os top-level dirs reais do repo.
   - `treeData.truncated` vira sinal tipado (não só `logger.warn`).

7. **Erros tipados** — `errorCode` em `JobInfo` (`GetJobInfoTool`, `ListJobsTool`) +
   no retorno de `scrape_docs`. Códigos:
   `EMPTY_RESULT | THIN_RESULT | OFF_TOPIC | SCOPE_DRIFT | LOCALE_REDIRECT_LOOP | GITHUB_SUBPATH_NOT_FOUND`.

### Fluxo de dados

```
scrape_docs(url, library, version, expectTerms?, denyPaths?, localeStrategy?)
  → enqueue job
  → PipelineWorker.executeJob: scrape (incremental writes) ──┐
  → ao fim:                                                  │
       metrics = { docs, distinctUrls, pages, sampledChunks }│
       outcome = evaluateOutcome(metrics) + relevanceGate    │
       outcome != indexed → removeVersion + FAILED+errorCode │
       outcome == indexed → COMPLETED                        │
  → get_job_info / list_jobs expõem { status, outcome, errorCode, remediation }
```

## Tratamento de erros

- Gate-fail é um desfecho **esperado**, não exceção: classificado, logado com `❌` + código,
  store limpo via `removeVersion`. Sem half-indexed garbage consultável.
- `removeVersion` já remove documents → pages → versions → (library se vazia).
- Erros de rede/throw continuam virando `FAILED` genérico (comportamento atual preservado).

## Estratégia de testes (TDD, fixtures reais)

| Gate | Teste | Fixture | Nível |
|------|-------|---------|-------|
| Outcome empty | job 0 docs → `empty`, não `completed` | mock store | unit |
| FM-3 | `/tree/main/docs` (inexistente) → `GITHUB_SUBPATH_NOT_FOUND` | snapshot `gh.json` (1045 entries) determinístico, **sem rede** | unit/integration |
| FM-2 denyPaths | root `generative-ai-docs` → demos cortados | snapshot `gh.json` | integration |
| FM-2 relevância | root + `expectTerms:["generateContent"]` → `degenerate`, store vazio | snapshot + mock embeddings | integration |
| FM-1 locale | redirect `?hl=` cíclico → `LOCALE_REDIRECT_LOOP` | mock server | integration |
| Rollback | gate-fail → `search_docs` not-found (não lixo) | e2e | e2e |

Política single-file: testes ao lado do código (`outcomeGate.test.ts`, etc.). E2E system-wide em `test/`.

## Escopo explícito

**Dentro:** outcome enum, gate-then-rollback hard-fail, empty/thin/relevance gates,
denyPaths, locale-normalize, FM-3 typed error, errorCodes expostos.

**Fora (plano futuro):** `discover_source(library)` tool; staging-version real com swap de
ponteiro; paginação de árvores GitHub truncadas (apenas sinalizada como typed error agora).

## Lado consumidor (devflow — secundário, fora deste repo)

Religar a Fase 6 do `scrape-stack-batch`: só marcar `mcpIndexed` em `outcome: indexed`;
em `degenerate/empty/loop` → retry-alt automático. Não faz parte deste plano de implementação.
