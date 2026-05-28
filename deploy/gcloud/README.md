# Deploy do docs-mcp-server no Google Cloud (Cloud Run)

Runbook para publicar em produção como **conector remoto do Claude.ai**.
Detalhes e justificativas: `docs/superpowers/specs/2026-05-28-gcloud-production-deploy-design.md`.
Plano passo-a-passo: `docs/superpowers/plans/2026-05-28-gcloud-production-deploy.md`.

## Arquitetura

```
Internet → [mcp] (público, OAuth Auth0) ─┐
           [web] (interno + IAM)         ├─ Direct VPC egress → [worker] (interno, 1 instância)
                                          │                          └─ GCS FUSE → /data (SQLite)
Secret Manager: GOOGLE_API_KEY (Gemini)   Embeddings: gemini:gemini-embedding-001 (3072d)
```

| Serviço | Ingress | Auth | Notas |
|---|---|---|---|
| `docs-mcp-worker` | internal | IAM | único escritor do SQLite; min=max=1 |
| `docs-mcp-mcp` | all (público) | OAuth2/OIDC (Auth0) do app | endpoint do conector: `<url>/mcp` |
| `docs-mcp-web` | internal | IAM | UI via `gcloud run services proxy` |

## Pré-requisitos manuais (Task 0)

1. **Billing** habilitado: `gcloud billing projects describe gen-lang-client-0927668204 --format="value(billingEnabled)"` → `True`.
2. **Gemini API key** (Google AI Studio): guardar para `02-secrets.sh` (não commitar).
3. **Auth0**:
   - Criar uma **API** com um *Identifier* (= audience), ex: `https://docs-mcp-server`.
   - Habilitar **Dynamic Client Registration** (necessário p/ o Claude.ai registrar-se).
   - Anotar `AUTH0_ISSUER_URL=https://<tenant>.auth0.com/` (com barra final) e `AUTH0_AUDIENCE`.

## Ordem de execução

```bash
cd deploy/gcloud

bash 01-prereqs.sh                                   # APIs, Artifact Registry, buckets, SA, IAM
GOOGLE_API_KEY="<key>" bash 02-secrets.sh            # secret Gemini
bash 03-build-push.sh                                # build & push da imagem
bash 04-deploy-worker.sh                             # → imprime WORKER_URL
export WORKER_URL="<url impressa acima>"
export AUTH0_ISSUER_URL="https://<tenant>.auth0.com/"
export AUTH0_AUDIENCE="https://docs-mcp-server"
bash 05-deploy-mcp.sh                                # → imprime <MCP_URL>/mcp
bash 06-deploy-web.sh                                # UI interna
# após o 1º scrape (validação), configurar backup:
bash 07-backup.sh
```

Todos os scripts são **idempotentes** (reexecutáveis). Config central: `00-config.env`.

## Validação

1. `gcloud run services list --region=southamerica-east1 --format="table(metadata.name, status.conditions[0].status)"` → todos `True`.
2. UI: `gcloud run services proxy docs-mcp-web --region=southamerica-east1 --port=8080` → `http://localhost:8080`.
3. Scrape pequeno pela UI + `search_docs`. Conferir o nome do `.db` em `gs://<PROJECT_ID>-docs-mcp-data` (ajustar `DB_OBJECT` em `07-backup.sh` se ≠ `documents.db`).
4. `curl -s <MCP_URL>/.well-known/oauth-protected-resource` → `authorization_servers` = Auth0.
5. **Claude.ai** → Connectors → Add custom connector → `<MCP_URL>/mcp` → completar OAuth → testar.
6. Persistência: forçar nova revision do worker e confirmar que os dados sobrevivem.

## Restore do backup

```bash
# pare o worker (escala a 0), restaure e suba de novo
gcloud run services update docs-mcp-worker --region=southamerica-east1 --min-instances=0 --max-instances=0
gsutil cp gs://<PROJECT_ID>-docs-mcp-backup/<arquivo> gs://<PROJECT_ID>-docs-mcp-data/documents.db
gcloud run services update docs-mcp-worker --region=southamerica-east1 --min-instances=1 --max-instances=1
```

## Troubleshooting

- **mcp/web não alcançam o worker (`/api` timeout / "Failed to connect to server"):** dois requisitos (ambos cobertos por `01-prereqs.sh` e `04-deploy-worker.sh`):
  1. **Private Google Access** habilitado na sub-rede `default` da região (sem ele, o tráfego do Direct VPC egress para a URL do worker não tem rota). Conferir: `gcloud compute networks subnets describe default --region=southamerica-east1 --format='value(privateIpGoogleAccess)'` → `True`.
  2. Worker com `--ingress=internal --allow-unauthenticated`: o ingress interno é a proteção de rede; o cliente tRPC do mcp/web não envia token IAM, então o worker não pode exigir auth IAM.
- **Claude.ai falha no registro OAuth (`/oauth/register`):** confirmar DCR habilitado no Auth0.
- **`SQLITE_IOERR` nos logs do worker:** indício de problema do GCS FUSE; verificar backup e considerar Filestore (ver spec, seção riscos).
