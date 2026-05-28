# Deploy docs-mcp-server no GCloud (produção) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publicar o `@arabold/docs-mcp-server` em produção no Google Cloud (Cloud Run, 3 serviços) acessível como conector remoto no Claude.ai, com OAuth via Auth0, embeddings Gemini e SQLite persistido em GCS.

**Architecture:** 3 serviços Cloud Run — `worker` (interno, single-instance, escreve SQLite num bucket GCS montado via FUSE), `mcp` (público, OAuth) e `web` (interno + IAM). Entregável = scripts idempotentes em `deploy/gcloud/` + runbook. Tudo parametrizado por `deploy/gcloud/00-config.env`.

**Tech Stack:** Cloud Run (gen2), Artifact Registry, Cloud Build, GCS (FUSE volume mount), Secret Manager, Cloud Scheduler, Auth0 (OIDC+DCR), Gemini API. Imagem: Dockerfile multi-stage existente.

**Spec:** `docs/superpowers/specs/2026-05-28-gcloud-production-deploy-design.md`

---

## Valores fixos (deste ambiente)

| Chave | Valor |
|---|---|
| PROJECT_ID | `gen-lang-client-0927668204` |
| REGION | `southamerica-east1` |
| Conta | `nexuz@nexuz.com.br` |
| Embedding model | `gemini:gemini-embedding-001` |
| Vector dimension | `3072` (imutável) |
| Imagem | `southamerica-east1-docker.pkg.dev/$PROJECT_ID/docs-mcp/docs-mcp-server:<tag>` |

**Env vars confirmadas no código** (`src/utils/config.ts`, `EmbeddingFactory.ts`):
`DOCS_MCP_EMBEDDING_MODEL`, `DOCS_MCP_EMBEDDINGS_VECTOR_DIMENSION`, `DOCS_MCP_STORE_PATH`, `GOOGLE_API_KEY`, `DOCS_MCP_AUTH_ENABLED`, `DOCS_MCP_AUTH_ISSUER_URL`, `DOCS_MCP_AUTH_AUDIENCE`.

---

## Task 0: Pré-requisitos manuais (BLOQUEANTE — exige o usuário)

**Files:** nenhum (ações externas). Documentar em `deploy/gcloud/README.md` (criado na Task 1).

- [ ] **Step 1: Confirmar billing no projeto**

Run: `gcloud billing projects describe gen-lang-client-0927668204 --format="value(billingEnabled)"`
Expected: `True`. Se `False`, o usuário deve vincular uma conta de faturamento (Cloud Run + GCS exigem billing).

- [ ] **Step 2: Obter a `GOOGLE_API_KEY` do Gemini**

O usuário fornece a API key do Google AI Studio (https://aistudio.google.com/apikey) para o projeto. Guardar para a Task 3 (vai para Secret Manager). NÃO commitar.

- [ ] **Step 3: Provisionar o tenant Auth0**

O usuário cria (ou informa) um tenant Auth0 e:
1. Cria uma **API** (Applications → APIs) com um *Identifier* (audience), ex: `https://docs-mcp-server`.
2. Habilita **Dynamic Client Registration**: `Settings → Advanced → OIDC Dynamic Application Registration` = ON, e em `Tenant Settings → Advanced` garantir DCR habilitado. (Necessário p/ o Claude.ai registrar-se via `/oauth/register`.)
3. Anota: `issuerUrl = https://<tenant>.auth0.com/` (com barra final) e `audience = <Identifier>`.

Saída desta task: `BILLING=True`, valor de `GOOGLE_API_KEY`, `AUTH0_ISSUER_URL`, `AUTH0_AUDIENCE`.

---

## Task 1: Scaffold de `deploy/gcloud/` (config + runbook)

**Files:**
- Create: `deploy/gcloud/00-config.env`
- Create: `deploy/gcloud/README.md`
- Create: `deploy/gcloud/lib.sh`
- Modify: `.gitignore` (ignorar arquivos de segredo locais)

- [ ] **Step 1: Criar `deploy/gcloud/00-config.env`**

```bash
# Configuração central do deploy GCloud. Sem segredos aqui.
export PROJECT_ID="gen-lang-client-0927668204"
export REGION="southamerica-east1"
export AR_REPO="docs-mcp"                 # Artifact Registry repo
export IMAGE_NAME="docs-mcp-server"
export IMAGE_TAG="${IMAGE_TAG:-v2.4.0}"
export IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${IMAGE_NAME}:${IMAGE_TAG}"

export BUCKET="${PROJECT_ID}-docs-mcp-data"      # SQLite store
export BACKUP_BUCKET="${PROJECT_ID}-docs-mcp-backup"

export SVC_WORKER="docs-mcp-worker"
export SVC_MCP="docs-mcp-mcp"
export SVC_WEB="docs-mcp-web"

export EMBEDDING_MODEL="gemini:gemini-embedding-001"
export VECTOR_DIMENSION="3072"

export RUNTIME_SA="docs-mcp-run@${PROJECT_ID}.iam.gserviceaccount.com"
export SECRET_GOOGLE_API_KEY="docs-mcp-google-api-key"

# Preenchidos após Task 0 (Auth0). NÃO commitar valores reais se sensíveis.
export AUTH0_ISSUER_URL="${AUTH0_ISSUER_URL:-}"   # ex: https://meutenant.auth0.com/
export AUTH0_AUDIENCE="${AUTH0_AUDIENCE:-}"        # ex: https://docs-mcp-server

# Preenchido após deploy do worker (Task 4)
export WORKER_URL="${WORKER_URL:-}"
```

- [ ] **Step 2: Criar `deploy/gcloud/lib.sh` (helpers idempotentes)**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/00-config.env"

log() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }

# Executa um comando "create" tolerando recurso já existente (idempotência).
create_ok() { "$@" 2>/tmp/gc_err || grep -qiE "already exists|alreadyExists" /tmp/gc_err || { cat /tmp/gc_err; exit 1; }; }
```

- [ ] **Step 3: Criar `deploy/gcloud/README.md` (runbook)**

Conteúdo: ordem de execução (`00`→`07`), os pré-requisitos manuais da Task 0, e a seção de validação (Task 9). Incluir o comando de acesso à UI: `gcloud run services proxy docs-mcp-web --region=southamerica-east1`. Documentar o procedimento de restore (Task 7).

- [ ] **Step 4: Atualizar `.gitignore`**

Acrescentar:
```
deploy/gcloud/*.secret
deploy/gcloud/.env.local
```

- [ ] **Step 5: Verificar sintaxe**

Run: `bash -n deploy/gcloud/lib.sh && echo OK`
Expected: `OK`

- [ ] **Step 6: Commit**

```bash
git add deploy/gcloud/00-config.env deploy/gcloud/lib.sh deploy/gcloud/README.md .gitignore
git commit -m "chore(deploy): scaffold gcloud deploy config and runbook"
```

---

## Task 2: Habilitar APIs e criar recursos base (idempotente)

**Files:**
- Create: `deploy/gcloud/01-prereqs.sh`

- [ ] **Step 1: Escrever `01-prereqs.sh`**

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

log "Habilitando APIs"
gcloud services enable \
  run.googleapis.com artifactregistry.googleapis.com secretmanager.googleapis.com \
  cloudbuild.googleapis.com cloudscheduler.googleapis.com compute.googleapis.com \
  --project "$PROJECT_ID"

log "Artifact Registry"
create_ok gcloud artifacts repositories create "$AR_REPO" \
  --repository-format=docker --location="$REGION" --project "$PROJECT_ID"

log "Buckets GCS (uniform access)"
create_ok gcloud storage buckets create "gs://${BUCKET}" \
  --location="$REGION" --uniform-bucket-level-access --project "$PROJECT_ID"
create_ok gcloud storage buckets create "gs://${BACKUP_BUCKET}" \
  --location="$REGION" --uniform-bucket-level-access --project "$PROJECT_ID"
gcloud storage buckets update "gs://${BACKUP_BUCKET}" --versioning --project "$PROJECT_ID"

log "Service Account de runtime"
create_ok gcloud iam service-accounts create docs-mcp-run \
  --display-name="docs-mcp-server runtime" --project "$PROJECT_ID"

ok "Prereqs concluídos"
```

- [ ] **Step 2: Executar**

Run: `bash deploy/gcloud/01-prereqs.sh`
Expected: termina com `✓ Prereqs concluídos`. Reexecução não deve falhar (idempotente).

- [ ] **Step 3: Conceder IAM ao SA de runtime**

```bash
source deploy/gcloud/lib.sh
# Acesso de objeto ao bucket de dados (FUSE precisa de objectAdmin)
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${RUNTIME_SA}" --role="roles/storage.objectAdmin" --project "$PROJECT_ID"
gcloud storage buckets add-iam-policy-binding "gs://${BACKUP_BUCKET}" \
  --member="serviceAccount:${RUNTIME_SA}" --role="roles/storage.objectAdmin" --project "$PROJECT_ID"
```

Expected: bindings aplicados sem erro.

- [ ] **Step 4: Commit**

```bash
git add deploy/gcloud/01-prereqs.sh
git commit -m "feat(deploy): enable apis and create base gcloud resources"
```

---

## Task 3: Criar o secret `GOOGLE_API_KEY`

**Files:**
- Create: `deploy/gcloud/02-secrets.sh`

- [ ] **Step 1: Escrever `02-secrets.sh`**

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
: "${GOOGLE_API_KEY:?Defina GOOGLE_API_KEY no ambiente antes de rodar (não commitar)}"

log "Criando/atualizando secret ${SECRET_GOOGLE_API_KEY}"
if gcloud secrets describe "$SECRET_GOOGLE_API_KEY" --project "$PROJECT_ID" >/dev/null 2>&1; then
  printf '%s' "$GOOGLE_API_KEY" | gcloud secrets versions add "$SECRET_GOOGLE_API_KEY" --data-file=- --project "$PROJECT_ID"
else
  printf '%s' "$GOOGLE_API_KEY" | gcloud secrets create "$SECRET_GOOGLE_API_KEY" --data-file=- --replication-policy=automatic --project "$PROJECT_ID"
fi

gcloud secrets add-iam-policy-binding "$SECRET_GOOGLE_API_KEY" \
  --member="serviceAccount:${RUNTIME_SA}" --role="roles/secretmanager.secretAccessor" --project "$PROJECT_ID"
ok "Secret pronto"
```

- [ ] **Step 2: Executar (com a key fora do histórico)**

Run: `GOOGLE_API_KEY="<key do usuário>" bash deploy/gcloud/02-secrets.sh`
Expected: `✓ Secret pronto`.

- [ ] **Step 3: Commit (somente o script)**

```bash
git add deploy/gcloud/02-secrets.sh
git commit -m "feat(deploy): provision google api key secret script"
```

---

## Task 4: Build & push da imagem + deploy do `worker`

**Files:**
- Create: `deploy/gcloud/03-build-push.sh`
- Create: `deploy/gcloud/04-deploy-worker.sh`

- [ ] **Step 1: Escrever `03-build-push.sh` (Cloud Build)**

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
log "Build & push via Cloud Build: ${IMAGE}"
gcloud builds submit --tag "$IMAGE" --project "$PROJECT_ID" .
ok "Imagem publicada: ${IMAGE}"
```

> Nota: o `Dockerfile` multi-stage existente já instala deps nativas (better-sqlite3, tree-sitter) e Chromium. `.dockerignore` deve excluir `node_modules`/`.git` — verificar na Task 8.

- [ ] **Step 2: Executar build**

Run: `bash deploy/gcloud/03-build-push.sh`
Expected: `✓ Imagem publicada: ...`. (Build pode levar alguns minutos.)

- [ ] **Step 3: Escrever `04-deploy-worker.sh`**

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
log "Deploy worker (interno, single-instance, GCS FUSE em /data)"
gcloud run deploy "$SVC_WORKER" \
  --image="$IMAGE" --region="$REGION" --project="$PROJECT_ID" \
  --service-account="$RUNTIME_SA" \
  --ingress=internal \
  --no-allow-unauthenticated \
  --min-instances=1 --max-instances=1 --concurrency=20 \
  --cpu=1 --memory=2Gi --timeout=3600 \
  --add-volume=name=data,type=cloud-storage,bucket="$BUCKET" \
  --add-volume-mount=volume=data,mount-path=/data \
  --set-env-vars=DOCS_MCP_STORE_PATH=/data,DOCS_MCP_EMBEDDING_MODEL="$EMBEDDING_MODEL",DOCS_MCP_EMBEDDINGS_VECTOR_DIMENSION="$VECTOR_DIMENSION" \
  --set-secrets=GOOGLE_API_KEY="${SECRET_GOOGLE_API_KEY}:latest" \
  --command=node \
  --args="--enable-source-maps,dist/index.js,worker,--host,0.0.0.0,--port,8080"
WORKER_URL="$(gcloud run services describe "$SVC_WORKER" --region "$REGION" --project "$PROJECT_ID" --format='value(status.url)')"
ok "worker em ${WORKER_URL} (interno)"
echo "Defina: export WORKER_URL=${WORKER_URL}"
```

- [ ] **Step 4: Executar deploy do worker**

Run: `bash deploy/gcloud/04-deploy-worker.sh`
Expected: revision `Ready`; imprime `WORKER_URL`. Copiar para `00-config.env` (`WORKER_URL=`) ou exportar no shell.

- [ ] **Step 5: Commit**

```bash
git add deploy/gcloud/03-build-push.sh deploy/gcloud/04-deploy-worker.sh
git commit -m "feat(deploy): build image and deploy internal worker service"
```

---

## Task 5: Deploy do `mcp` (público + OAuth) com VPC egress ao worker

**Files:**
- Create: `deploy/gcloud/05-deploy-mcp.sh`

- [ ] **Step 1: Escrever `05-deploy-mcp.sh`**

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
: "${WORKER_URL:?Exporte WORKER_URL (saída da Task 4)}"
: "${AUTH0_ISSUER_URL:?Defina AUTH0_ISSUER_URL}"
: "${AUTH0_AUDIENCE:?Defina AUTH0_AUDIENCE}"

log "Deploy mcp (público, OAuth, Direct VPC egress → worker interno)"
gcloud run deploy "$SVC_MCP" \
  --image="$IMAGE" --region="$REGION" --project="$PROJECT_ID" \
  --service-account="$RUNTIME_SA" \
  --ingress=all --allow-unauthenticated \
  --min-instances=0 --max-instances=3 --cpu=1 --memory=512Mi \
  --network=default --subnet=default --vpc-egress=all-traffic \
  --set-env-vars=DOCS_MCP_EMBEDDING_MODEL="$EMBEDDING_MODEL",DOCS_MCP_EMBEDDINGS_VECTOR_DIMENSION="$VECTOR_DIMENSION",DOCS_MCP_AUTH_ENABLED=true,DOCS_MCP_AUTH_ISSUER_URL="$AUTH0_ISSUER_URL",DOCS_MCP_AUTH_AUDIENCE="$AUTH0_AUDIENCE" \
  --set-secrets=GOOGLE_API_KEY="${SECRET_GOOGLE_API_KEY}:latest" \
  --command=node \
  --args="--enable-source-maps,dist/index.js,mcp,--protocol,http,--host,0.0.0.0,--port,8080,--server-url,${WORKER_URL}/api,--no-logo"
MCP_URL="$(gcloud run services describe "$SVC_MCP" --region "$REGION" --project "$PROJECT_ID" --format='value(status.url)')"
ok "mcp público em ${MCP_URL}  → conector: ${MCP_URL}/mcp"
```

> O Cloud Run injeta `$PORT=8080`; o app escuta nele. O `--port,8080` mantém consistência com o container. `--vpc-egress=all-traffic` roteia a chamada ao `worker` (ingress interno) pela VPC.

- [ ] **Step 2: Executar deploy do mcp**

Run: `WORKER_URL=<...> AUTH0_ISSUER_URL=<...> AUTH0_AUDIENCE=<...> bash deploy/gcloud/05-deploy-mcp.sh`
Expected: revision `Ready`; imprime URL pública e endpoint `/mcp`.

- [ ] **Step 3: Verificar metadata OAuth**

Run: `curl -s ${MCP_URL}/.well-known/oauth-protected-resource | head`
Expected: JSON com `authorization_servers` apontando para o `AUTH0_ISSUER_URL` e `resource` na URL pública do mcp.

- [ ] **Step 4: Commit**

```bash
git add deploy/gcloud/05-deploy-mcp.sh
git commit -m "feat(deploy): deploy public mcp service with oauth and vpc egress"
```

---

## Task 6: Deploy do `web` (interno + IAM)

**Files:**
- Create: `deploy/gcloud/06-deploy-web.sh`

- [ ] **Step 1: Escrever `06-deploy-web.sh`**

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
: "${WORKER_URL:?Exporte WORKER_URL}"

log "Deploy web (interno + IAM; acesso via 'gcloud run services proxy')"
gcloud run deploy "$SVC_WEB" \
  --image="$IMAGE" --region="$REGION" --project="$PROJECT_ID" \
  --service-account="$RUNTIME_SA" \
  --ingress=internal --no-allow-unauthenticated \
  --min-instances=0 --max-instances=2 --cpu=1 --memory=512Mi \
  --network=default --subnet=default --vpc-egress=all-traffic \
  --set-env-vars=DOCS_MCP_EMBEDDING_MODEL="$EMBEDDING_MODEL",DOCS_MCP_EMBEDDINGS_VECTOR_DIMENSION="$VECTOR_DIMENSION" \
  --set-secrets=GOOGLE_API_KEY="${SECRET_GOOGLE_API_KEY}:latest" \
  --command=node \
  --args="--enable-source-maps,dist/index.js,web,--host,0.0.0.0,--port,8080,--server-url,${WORKER_URL}/api,--no-logo"
ok "web (interno) implantado. Acesse: gcloud run services proxy ${SVC_WEB} --region=${REGION}"
```

- [ ] **Step 2: Executar deploy do web**

Run: `WORKER_URL=<...> bash deploy/gcloud/06-deploy-web.sh`
Expected: revision `Ready`.

- [ ] **Step 3: Commit**

```bash
git add deploy/gcloud/06-deploy-web.sh
git commit -m "feat(deploy): deploy internal web ui behind iam"
```

---

## Task 7: Backup periódico do SQLite (Cloud Scheduler)

**Files:**
- Create: `deploy/gcloud/07-backup.sh`

- [ ] **Step 1: Escrever `07-backup.sh`**

Estratégia: um job Cloud Scheduler diário que copia o `.db` do bucket de dados para o bucket de backup versionado (timestamp no nome). Como o store fica em GCS, a cópia é bucket→bucket (não exige acesso ao container).

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
# Descobrir o nome do arquivo .db usado pelo store (default: documents.db)
DB_OBJECT="${DB_OBJECT:-documents.db}"

log "Job de backup diário (gcloud storage cp bucket→backup)"
# Usa um Cloud Scheduler HTTP job chamando a API do GCS via gcloud não é trivial;
# em vez disso, criamos um Cloud Scheduler que dispara um Cloud Run Job de cópia.
# Cloud Run Job de backup:
gcloud run jobs deploy docs-mcp-backup \
  --image="google/cloud-sdk:slim" --region="$REGION" --project="$PROJECT_ID" \
  --service-account="$RUNTIME_SA" \
  --command=/bin/sh \
  --args="-c,gsutil cp gs://${BUCKET}/${DB_OBJECT} gs://${BACKUP_BUCKET}/${DB_OBJECT}.$(date +%Y%m%d%H%M%S)"

create_ok gcloud scheduler jobs create http docs-mcp-backup-daily \
  --location="$REGION" --schedule="0 3 * * *" \
  --uri="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT_ID}/jobs/docs-mcp-backup:run" \
  --http-method=POST \
  --oauth-service-account-email="$RUNTIME_SA" \
  --project "$PROJECT_ID"
ok "Backup diário configurado (03:00). Restore: gsutil cp gs://${BACKUP_BUCKET}/<arquivo> gs://${BUCKET}/${DB_OBJECT}"
```

> O nome real do arquivo SQLite (`DB_OBJECT`) será confirmado na validação (Task 9, Step 1) inspecionando o bucket após o primeiro scrape. Ajustar `DB_OBJECT` se diferente de `documents.db`.

- [ ] **Step 2: Conceder `roles/run.invoker` ao SA para o job**

```bash
source deploy/gcloud/lib.sh
gcloud run jobs add-iam-policy-binding docs-mcp-backup \
  --member="serviceAccount:${RUNTIME_SA}" --role="roles/run.invoker" \
  --region="$REGION" --project "$PROJECT_ID"
```

- [ ] **Step 3: Executar e testar uma execução manual**

Run: `bash deploy/gcloud/07-backup.sh && gcloud run jobs execute docs-mcp-backup --region=$REGION --project=$PROJECT_ID --wait`
Expected: execução `Succeeded` (após existir o `.db`; rodar depois da Task 9).

- [ ] **Step 4: Commit**

```bash
git add deploy/gcloud/07-backup.sh
git commit -m "feat(deploy): daily sqlite backup via cloud run job + scheduler"
```

---

## Task 8: Verificar `.dockerignore` e Node 22 do build

**Files:**
- Modify/Create: `.dockerignore`

- [ ] **Step 1: Conferir `.dockerignore`**

Run: `cat .dockerignore 2>/dev/null || echo MISSING`
Se faltar `node_modules`, `.git`, `dist`, `*.db`, criar/atualizar para evitar enviar artefatos ao Cloud Build:

```
node_modules
.git
dist
*.db
.env
deploy/gcloud/*.secret
```

- [ ] **Step 2: Confirmar Node 22 no Dockerfile**

Run: `grep -n "FROM node:" Dockerfile`
Expected: `node:22-trixie-slim`. (Build roda no Cloud Build, independente do Node v24 local.)

- [ ] **Step 3: Commit (se alterou)**

```bash
git add .dockerignore
git commit -m "chore(deploy): tighten dockerignore for cloud build"
```

---

## Task 9: Validação end-to-end (fase V)

**Files:** nenhum (verificação). Resultados documentados no PR.

- [ ] **Step 1: Health das 3 revisions**

Run: `gcloud run services list --region=$REGION --project=$PROJECT_ID --format="table(metadata.name, status.conditions[0].status)"`
Expected: worker/mcp/web todos `True` (Ready).

- [ ] **Step 2: UI web via proxy**

Run: `gcloud run services proxy docs-mcp-web --region=$REGION --project=$PROJECT_ID --port=8080`
Expected: abrir `http://localhost:8080` → UI carrega e lista bibliotecas (vazia inicialmente).

- [ ] **Step 3: Scrape + search E2E (pela UI ou MCP)**

Disparar um scrape pequeno (ex: 1 página de docs) via UI; após concluir, fazer um `search_docs`. Expected: resultados retornam. Inspecionar `gs://${BUCKET}` e confirmar o nome do `.db` (ajustar `DB_OBJECT` na Task 7 se necessário).

- [ ] **Step 4: Metadata OAuth + handshake MCP**

Run: `curl -s <MCP_URL>/.well-known/oauth-authorization-server | head` e `curl -s <MCP_URL>/.well-known/oauth-protected-resource | head`
Expected: JSON válido; `authorization_servers` = Auth0 issuer.

- [ ] **Step 5: Conectar como conector no Claude.ai (critério de aceite final)**

No Claude.ai → Settings → Connectors → Add custom connector → URL `<MCP_URL>/mcp`. Esperar o fluxo OAuth (login Auth0, consentimento) completar e as tools aparecerem. Fazer uma busca de teste.
Expected: conector conectado; `search_docs` funciona.

- [ ] **Step 6: Teste de persistência**

Run: `gcloud run services update docs-mcp-worker --region=$REGION --project=$PROJECT_ID --update-env-vars=_NUDGE=1` (força nova revision) e repetir o search.
Expected: dados sobrevivem (estão no GCS).

---

## Task 10: Confirmação (fase C) — docs + PR

**Files:**
- Modify: `README.md` (seção "Deploy no Google Cloud" com link ao runbook)
- Modify: `deploy/gcloud/README.md` (preencher URLs finais e quaisquer ajustes — ex: `DB_OBJECT` real)

- [ ] **Step 1: Documentar no README**

Adicionar seção curta "Deploy no Google Cloud (Cloud Run)" apontando para `deploy/gcloud/README.md` e citando o endpoint do conector Claude.ai.

- [ ] **Step 2: Commit**

```bash
git add README.md deploy/gcloud/README.md
git commit -m "docs(deploy): document gcloud cloud run deployment and claude.ai connector"
```

- [ ] **Step 3: Abrir PR**

```bash
git push -u origin <branch>
gh pr create --title "feat(deploy): gcloud cloud run production deployment" --body "<resumo + checklist de validação da Task 9>"
```

---

## Riscos & validações específicas (do spec)

- **SQLite em GCS FUSE**: worker single-instance mitiga; backup diário (Task 7) é a rede de segurança. Monitorar logs do worker por erros de I/O (`SQLITE_IOERR`).
- **VPC egress → worker interno**: se mcp/web não alcançarem o worker (`/api` timeout), validar `--vpc-egress=all-traffic` e a sub-rede `default` existente na região. *Fallback temporário de diagnóstico*: subir worker com `--ingress=all --no-allow-unauthenticated` e testar; nunca deixar o worker `--allow-unauthenticated` em produção.
- **Auth0 DCR**: se o Claude.ai falhar ao registrar (`/oauth/register` → erro), confirmar DCR habilitado no tenant (Task 0, Step 3).
- **baseUrl do OAuth**: o app deriva o host do request; Cloud Run preserva o Host, então a metadata deve apontar para `<MCP_URL>`. Validar no Step 4 da Task 9.

## Self-review (cobertura do spec)

- Arquitetura 3 serviços → Tasks 4,5,6 ✓
- GCS FUSE persistência → Task 4 ✓ • Backup → Task 7 ✓
- OAuth/Auth0/DCR/conector → Tasks 0,5,9 ✓
- Embeddings Gemini + dimensão 3072 → env vars em 4,5,6 ✓
- web interno + IAM → Task 6 ✓
- Secrets → Task 3 ✓ • Build/AR → Tasks 2,4 ✓
- Validação (incl. conector Claude.ai) → Task 9 ✓ • Docs/PR → Task 10 ✓
- Networking VPC egress → Tasks 5,6 + fallback documentado ✓
