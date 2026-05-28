# Design — Deploy do docs-mcp-server no Google Cloud (produção)

> **DevFlow workflow:** gcloud-production-deploy | **Scale:** MEDIUM | **Autonomia:** supervised
> **Data:** 2026-05-28 | **Projeto GCP:** `gen-lang-client-0927668204` | **Região:** `southamerica-east1`

## Objetivo

Publicar o `@arabold/docs-mcp-server` (v2.4.0) em produção no Google Cloud, acessível como **conector remoto no Claude.ai**, com autenticação OAuth2/OIDC, embeddings via Gemini API e persistência do índice SQLite.

## Contexto e restrições

- **Arquitetura multi-serviço** (do `docker-compose.yml` existente): `worker` (processa scrapes e **é o único que escreve** no SQLite em `/data`), `mcp` (endpoint MCP HTTP) e `web` (UI de gestão). `mcp`/`web` são stateless e falam com o `worker` via API tRPC/HTTP (`--server-url .../api`).
- **SQLite (better-sqlite3 + sqlite-vec)** é o store. Sensível a semântica de locking/fsync do filesystem → exige escritor único.
- **OAuth nativo**: `src/auth/ProxyAuthManager.ts` implementa um proxy OAuth2 completo (RFC 8414 AS metadata, RFC 9728 protected-resource metadata, `/oauth/authorize|token|revoke|register`, PKCE S256, validação JWT via JWKS). O `/oauth/register` é **encaminhado ao provedor upstream**, então o upstream precisa suportar **Dynamic Client Registration (DCR, RFC 7591)** para o fluxo automático do Claude.ai.
- **Embeddings**: `src/store/embeddings/EmbeddingFactory.ts` — provider `gemini` requer `GOOGLE_API_KEY` e `DOCS_MCP_EMBEDDINGS_VECTOR_DIMENSION` (obrigatório; usa `FixedDimensionEmbeddings`/MRL). **Modelo e dimensão são imutáveis** após o primeiro índice (`EmbeddingModelChangedError`).

## Decisões (aprovadas pelo usuário)

| Decisão | Escolha | Notas |
|---|---|---|
| Alvo GCloud | **Cloud Run** (3 serviços) | worker fixado em 1 instância |
| Persistência `/data` | **GCS FUSE volume mount** | barato; risco SQLite-sobre-FUSE mitigado por worker single-instance + backup |
| Acesso/Auth | **mcp público + OAuth2/OIDC do app** | worker interno; mcp público com Bearer JWT; **web interno + IAM (via `gcloud run services proxy`)** |
| Provedor OIDC | **Auth0** (free tier) | suporta DCR para o conector Claude.ai |
| Embeddings | **Gemini** `gemini:gemini-embedding-001` | `GOOGLE_API_KEY` no Secret Manager |
| Dimensão embedding | **3072** (imutável) | qualidade máxima |
| Domínio | **URL padrão `*.run.app`** | sem DNS custom |
| Região | **southamerica-east1** (São Paulo) | Gemini API é global |

## Arquitetura

```
                         Internet
                            │
         ┌──────────────────┼───────────────────┐
         ▼                  ▼
   [Cloud Run: mcp]   [Cloud Run: web]    ingress=all (público), HTTPS gerenciado
    /mcp (+ /sse)       UI :8080          ProxyAuthManager → Auth0 (Bearer JWT)
         │                  │
         └────────┬─────────┘   Direct VPC egress
                  ▼
          [Cloud Run: worker]   ingress=internal, min=1, max=1
           API tRPC /api        único escritor do SQLite
                  │
                  ▼  Cloud Run GCS volume mount (FUSE)
            [bucket GCS]  →  /data (SQLite + sqlite-vec)

  Secret Manager:  GOOGLE_API_KEY (Gemini)
  Artifact Registry:  imagem do Dockerfile (multi-stage existente)
  Embeddings:  Gemini API (global)
  Auth:  Auth0 (issuer OIDC + DCR), upstream do proxy OAuth do app
```

### Componentes e responsabilidades

- **worker** — Cloud Run, `ingress=internal`, `min-instances=1`, `max-instances=1`, monta o bucket GCS em `/data`. Comando: `worker --host 0.0.0.0 --port 8080`. Único com acesso de escrita ao SQLite. Mantém a fila de jobs in-memory (por isso single-instance + always-on).
- **mcp** — Cloud Run, `ingress=all`, público. Comando: `mcp --protocol http --host 0.0.0.0 --port <PORT> --server-url <worker-internal>/api --auth-enabled --auth-issuer-url <auth0> --auth-audience <api-id>`. Expõe `/mcp` (Streamable HTTP) e `/sse` (legado) + endpoints OAuth.
- **web** — Cloud Run, **`ingress=internal` + `--no-allow-unauthenticated`** (protegida por IAM; o comando `web` não suporta auth de app). Comando: `web --host 0.0.0.0 --port <PORT> --server-url <worker-internal>/api`. UI de gestão de bibliotecas/jobs. **Acesso pelo usuário via `gcloud run services proxy docs-mcp-web --region=southamerica-east1`** (túnel local autenticado pela conta Google) — sem exposição pública, sem IAP/Load Balancer.
- **GCS bucket** — armazena o arquivo SQLite. Montado via FUSE no worker.
- **Secret Manager** — `GOOGLE_API_KEY`.
- **Artifact Registry** — repositório Docker com a imagem buildada.

## Fluxo de dados

### Scrape/index (escrita)
`web` ou MCP tool `scrape_docs` → chamada tRPC ao `worker` → `worker` faz scrape, split, embeddings (Gemini), grava no SQLite em `/data` (GCS FUSE).

### Busca (leitura)
Cliente MCP (Claude.ai) → `mcp` `/mcp` → valida Bearer JWT → tRPC ao `worker` → busca híbrida (vetorial + FTS/RRF) no SQLite → resposta.

### OAuth (conector Claude.ai)
1. Conector aponta para `https://<mcp>.run.app/mcp`.
2. Claude.ai lê `/.well-known/oauth-protected-resource` → descobre o AS (proxy do app).
3. Claude.ai faz DCR via `/oauth/register` → proxy encaminha ao Auth0.
4. `authorization_code` + PKCE S256: `/oauth/authorize` → Auth0 login → `/oauth/token` (proxy → Auth0).
5. Claude.ai recebe Bearer JWT; o app valida via JWKS do Auth0 (`verifyAccessToken`). Auth binária: token válido = acesso total.

## Configuração (env vars / flags)

**Comum a worker/mcp/web** (embeddings — devem ser idênticos nos 3):
- `DOCS_MCP_EMBEDDING_MODEL=gemini:gemini-embedding-001`
- `DOCS_MCP_EMBEDDINGS_VECTOR_DIMENSION=3072`
- `DOCS_MCP_STORE_PATH=/data`
- `GOOGLE_API_KEY` → referência ao Secret Manager (`--set-secrets`)

**mcp/web**:
- `--server-url=https://<worker-internal>.run.app/api`

**mcp** (auth):
- `--auth-enabled`
- `--auth-issuer-url=https://<tenant>.auth0.com/`
- `--auth-audience=<auth0-api-identifier>`

> Nota: `auth-enabled/issuer/audience` também aceitam env vars equivalentes via `loadConfig` (`appConfig.auth.*`). O plano confirmará os nomes exatos das env vars de auth em `src/utils/config.ts`.

## Networking

- **worker** `ingress=internal`: só aceita tráfego originado da VPC do projeto. Protege a API tRPC (que não tem auth própria) sem expô-la à internet.
- **mcp/web** usam **Direct VPC egress** para alcançar a URL interna do worker. Sem necessidade de token IAM entre serviços (a proteção é o ingress interno + roteamento VPC).
- **Fallback documentado (NÃO recomendado p/ prod)**: worker `ingress=all` + `--allow-unauthenticated` deixaria a API tRPC pública. Evitar.
- Ordem de deploy: worker primeiro (para obter sua URL) → mcp/web com `--server-url` apontando para ela.

## Persistência & backup

- worker monta o bucket GCS em `/data` (gen2, `--add-volume type=cloud-storage` + `--add-volume-mount`).
- **Risco**: SQLite sobre GCS FUSE tem semântica de locking/fsync imperfeita. Mitigação:
  1. worker **single-instance** (`max-instances=1`) → escritor único, sem contenção multi-processo.
  2. **Backup periódico** do arquivo `.db` para um bucket versionado (Cloud Scheduler + job, ou cópia no boot/shutdown). Corrupção do FUSE é o risco residual real.
- Documentar passo de **restauração** a partir do backup.

## Build & deploy

- Build da imagem via `Dockerfile` multi-stage existente → push para **Artifact Registry** (`southamerica-east1-docker.pkg.dev/...`).
- Deploy via **scripts idempotentes** versionados em `deploy/gcloud/` (um `gcloud run deploy` por serviço + setup de bucket, secret, Artifact Registry, APIs).
- Habilitar APIs: `run`, `artifactregistry`, `secretmanager`, `cloudbuild` (se usar Cloud Build), `compute`/`vpcaccess` (para VPC egress).
- Os scripts servem de documentação executável e base para futura automação no CI (`release.yml`).

## Custo estimado

Cloud Run (3 svc, baixo tráfego) ~US$5–15/mês • GCS ~US$1–5 • Auth0/Gemini free tier • Artifact Registry centavos → **~US$10–25/mês**.

## Riscos & mitigações

| Risco | Severidade | Mitigação |
|---|---|---|
| Corrupção SQLite no GCS FUSE | Alta | worker single-instance + backup periódico versionado + procedimento de restore |
| `min-instances=1` no worker gera custo always-on | Baixa | aceitável (~poucos US$/mês); necessário p/ fila in-memory + store |
| Auth0 DCR não habilitado por padrão | Média | habilitar Dynamic Client Registration no tenant Auth0; validar fluxo end-to-end |
| baseUrl/host do OAuth incorreto atrás do proxy Cloud Run | Média | Cloud Run preserva Host; validar metadata `/.well-known/*` apontando para a URL pública correta |
| Cold start do worker quebra jobs | Baixa | `min-instances=1` evita cold start do worker |
| Custo de embeddings Gemini em scrapes grandes | Baixa | free tier inicial; monitorar uso |

## Validação (fase V)

1. Health/readiness dos 3 serviços (Cloud Run revisions `Ready`).
2. `web` UI acessível **via `gcloud run services proxy`** (autenticada por IAM, não pública) e lista bibliotecas.
3. Smoke do MCP: handshake em `/mcp` retornando as 10 tools.
4. Fluxo OAuth completo (metadata discovery → DCR no Auth0 → token → chamada autenticada).
5. E2E funcional: 1 `scrape_docs` de uma lib pequena → 1 `search_docs` retornando resultados.
6. **Conexão real como conector no Claude.ai** (critério de aceite final).
7. Persistência: reiniciar o worker e confirmar que o índice sobrevive (dados no GCS).

## Fora de escopo (YAGNI)

- Migrar o store de SQLite para Cloud SQL/Postgres.
- Custom domain / Cloud Load Balancer / Cloud Armor.
- Autoscaling do worker (incompatível com SQLite single-writer).
- CI/CD automatizado do deploy (os scripts ficam prontos para isso, mas a automação no `release.yml` não entra agora).
- Domínio customizado e certificados gerenciados além do `*.run.app`.
