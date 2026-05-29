# Deploy do docs-mcp-server no Google Cloud (Cloud Run)

Runbook para publicar em produção como **conector remoto do Claude.ai**.
Detalhes/decisões: `docs/superpowers/specs/2026-05-28-gcloud-production-deploy-design.md`.
Plano: `docs/superpowers/plans/2026-05-28-gcloud-production-deploy.md`.

## Arquitetura escolhida: Modo Unificado (1 serviço)

Um único serviço Cloud Run roda **MCP + web + API + worker embutido** no mesmo
processo. Tem internet direta (scraping, Gemini, OAuth) sem precisar de VPC/NAT.
SQLite (single-writer) num bucket GCS montado via FUSE; `min=max=1`.

```
Internet → [Cloud Run: docs-mcp]  (ingress=all, público)
             ├─ /mcp   (Streamable HTTP) — protegido por OAuth (ProxyAuthManager)
             ├─ /      (web UI)          — ⚠️ pública (ver caveat)
             ├─ /api   (tRPC)
             └─ worker embutido
                  └─ GCS FUSE → /data (SQLite + sqlite-vec)
Secret Manager: GOOGLE_API_KEY (Gemini)   Embeddings: gemini:gemini-embedding-001 (3072d)
```

> O split de 3 serviços (worker/mcp/web internos) foi avaliado e descartado: exige
> Cloud NAT (~US$32/mês) para os serviços acessarem a internet, sem ganho real (o
> SQLite já força instância única). Os scripts `05/06` ficam como alternativa.

## Pré-requisitos manuais

1. **Billing** habilitado no projeto.
2. **Gemini API key** (Google AI Studio) → `02-secrets.sh`.
3. **OAuth do conector** (escolha um):
   - **Google manual** (spike atual): `GOOGLE-OAUTH-SETUP.md`
   - **Auth0** (DCR, fallback robusto): `AUTH0-SETUP.md`

## Ordem de execução (Modo Unificado)

```bash
cd deploy/gcloud

bash 01-prereqs.sh                                   # APIs, Artifact Registry, buckets, SA, IAM, PGA
GOOGLE_API_KEY="<key>" bash 02-secrets.sh            # secret Gemini
bash 03-build-push.sh                                # build & push da imagem

export AUTH_ISSUER_URL="https://accounts.google.com" # ou https://<tenant>.auth0.com/
export AUTH_AUDIENCE="https://docs-mcp-server"
bash 04-deploy-unified.sh                            # 1ª vez: deploy
bash 04-deploy-unified.sh                            # 2ª vez: grava DOCS_MCP_AUTH_PUBLIC_URL (auto-resolvido)

# após o 1º scrape (validação), configurar backup:
bash 07-backup.sh
```

Scripts idempotentes. Config central: `00-config.env`. Serviço: `docs-mcp`.

## Trocar o provedor de auth (Google ↔ Auth0)

Só re-deployar com as 2 variáveis trocadas (o serviço já existe, dados preservados):

```bash
export AUTH_ISSUER_URL="https://<tenant>.auth0.com/"
export AUTH_AUDIENCE="https://docs-mcp-server"
bash 04-deploy-unified.sh
```

## ⚠️ Caveat de segurança — UI web pública

No Modo Unificado, **apenas `/mcp` fica atrás do OAuth**. A UI web (`/`) e a API
(`/web/*`, `/api`) **respondem sem autenticação** — quem tiver a URL pode gerenciar
o índice (scrape/remove/search) e consumir quota do Gemini. A URL `*.run.app` é
obscura, mas isso **não** é proteção real. Opções para endurecer (futuro):
- Aceitar (uso pessoal, alvo de baixo valor).
- Colocar o serviço inteiro atrás de IAP (exige Load Balancer externo).
- Voltar ao split com `web` interno + IAM (scripts 06) + Cloud NAT.

## Validação (todas verificadas neste deploy)

1. `gcloud run services describe docs-mcp --region=southamerica-east1 --format='value(status.conditions[0].status)'` → `True`.
2. `curl <URL>/.well-known/oauth-authorization-server` → endpoints na URL pública.
3. `curl -X POST <URL>/mcp` sem token → `401`.
4. Pipeline E2E (validado): scrape de 1 página → `Pages:1 Chunks:1` → busca retorna conteúdo. Confirma internet + embeddings Gemini + SQLite/GCS + busca híbrida.
5. **Claude.ai**: Settings → Connectors → Add custom connector → `<URL>/mcp` + (Google manual) Client ID/Secret nas advanced settings → completar OAuth.

## Backup / restore

`07-backup.sh` cria um Cloud Run Job diário (03:00) que copia o `.db` para o bucket
versionado. Restore (com o serviço parado):

```bash
gcloud run services update docs-mcp --region=southamerica-east1 --min-instances=0 --max-instances=0
gsutil cp gs://<PROJECT_ID>-docs-mcp-backup/<arquivo> gs://<PROJECT_ID>-docs-mcp-data/documents.db
gcloud run services update docs-mcp --region=southamerica-east1 --min-instances=1 --max-instances=1
```

## Troubleshooting

- **Container não sobe / imprime help do CLI:** erro de validação de auth (`audience` deve ser URL/URN absoluto) ou flag inválida. Ver logs: `gcloud run services logs read docs-mcp --region=southamerica-east1`.
- **Metadata OAuth com `localhost`:** faltou `DOCS_MCP_AUTH_PUBLIC_URL` — rode `04-deploy-unified.sh` uma 2ª vez (auto-resolve a URL pública).
- **`SQLITE_IOERR` nos logs:** indício de problema do GCS FUSE; verificar backup e considerar Filestore (ver spec).
- **Claude.ai falha no OAuth:** caminho Google exige client manual no Claude.ai (sem DCR); se não suportar, migrar para Auth0 (troca de 2 env vars).
