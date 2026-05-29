#!/usr/bin/env bash
# Deploy do servidor em MODO UNIFICADO (MCP + web + API + worker embutido) num único
# serviço Cloud Run. Internet direta (sem VPC/NAT): resolve scraping, Gemini e OAuth.
# SQLite em GCS FUSE montado em /data. min=max=1 (SQLite single-writer).
# Auth é OPCIONAL: defina AUTH_ISSUER_URL + AUTH_AUDIENCE para ligar OAuth/OIDC.
# Sem essas vars, sobe SEM auth (endpoint MCP público — ver caveat no README).
# Uso c/ auth:  AUTH_ISSUER_URL=<...> AUTH_AUDIENCE=<...> bash deploy/gcloud/04-deploy-unified.sh
# Uso s/ auth:  bash deploy/gcloud/04-deploy-unified.sh
source "$(dirname "$0")/lib.sh"

BASE_ARGS="--enable-source-maps,dist/index.js,--protocol,http,--host,0.0.0.0,--port,8080"
ENV_VARS="DOCS_MCP_STORE_PATH=/data,DOCS_MCP_EMBEDDING_MODEL=${EMBEDDING_MODEL},DOCS_MCP_EMBEDDINGS_VECTOR_DIMENSION=${VECTOR_DIMENSION}"

if [ -n "${AUTH_ISSUER_URL:-}" ] && [ -n "${AUTH_AUDIENCE:-}" ]; then
  # A metadata OAuth é config-driven (não usa o header Host). Atrás do proxy do
  # Cloud Run, informamos a URL pública via DOCS_MCP_AUTH_PUBLIC_URL (auto-resolvida
  # em re-execuções; na 1ª vez fica em branco e a 2ª execução preenche).
  PUBLIC_URL="${PUBLIC_URL:-$(gcloud run services describe "$SVC_UNIFIED" --region "$REGION" --project "$PROJECT_ID" --format='value(status.url)' 2>/dev/null || true)}"
  [ -n "$PUBLIC_URL" ] && ENV_VARS="${ENV_VARS},DOCS_MCP_AUTH_PUBLIC_URL=${PUBLIC_URL}"
  ARGS="${BASE_ARGS},--auth-enabled,--auth-issuer-url,${AUTH_ISSUER_URL},--auth-audience,${AUTH_AUDIENCE}"
  log "Deploy unificado COM OAuth (issuer=${AUTH_ISSUER_URL})"
else
  ARGS="$BASE_ARGS"
  log "Deploy unificado SEM auth — endpoint MCP público (ver caveat no README.md)"
fi

gcloud run deploy "$SVC_UNIFIED" \
  --image="$IMAGE" --region="$REGION" --project="$PROJECT_ID" \
  --service-account="$RUNTIME_SA" \
  --ingress=all --allow-unauthenticated \
  --min-instances=1 --max-instances=1 --concurrency=40 \
  --cpu=2 --memory=2Gi --timeout=3600 \
  --add-volume=name=data,type=cloud-storage,bucket="$BUCKET" \
  --add-volume-mount=volume=data,mount-path=/data \
  --set-env-vars="$ENV_VARS" \
  --set-secrets=GOOGLE_API_KEY="${SECRET_GOOGLE_API_KEY}:latest" \
  --command=node \
  --args="$ARGS"

URL="$(gcloud run services describe "$SVC_UNIFIED" --region "$REGION" --project "$PROJECT_ID" --format='value(status.url)')"
ok "Servidor unificado em ${URL}"
echo "  • UI web:           ${URL}/"
echo "  • Conector Claude.ai: ${URL}/mcp"
