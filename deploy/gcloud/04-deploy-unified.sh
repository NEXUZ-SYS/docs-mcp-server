#!/usr/bin/env bash
# Deploy do servidor em MODO UNIFICADO (MCP + web + API + worker embutido) num único
# serviço Cloud Run. Internet direta (sem VPC/NAT): resolve scraping, Gemini e OAuth.
# SQLite em GCS FUSE montado em /data. min=max=1 (SQLite single-writer).
# Uso: AUTH_ISSUER_URL=<...> AUTH_AUDIENCE=<...> bash deploy/gcloud/04-deploy-unified.sh
source "$(dirname "$0")/lib.sh"
: "${AUTH_ISSUER_URL:?Defina AUTH_ISSUER_URL (ex: https://accounts.google.com ou https://<tenant>.auth0.com/)}"
: "${AUTH_AUDIENCE:?Defina AUTH_AUDIENCE (client_id do Google, ou identifier da API Auth0)}"

# A metadata OAuth é config-driven (não usa o header Host). Atrás do proxy do
# Cloud Run, precisamos informar a URL pública via DOCS_MCP_AUTH_PUBLIC_URL.
# Auto-resolve a URL do próprio serviço em re-execuções; na 1ª vez fica em branco
# (fallback localhost) e a 2ª execução já preenche corretamente.
PUBLIC_URL="${PUBLIC_URL:-$(gcloud run services describe "$SVC_UNIFIED" --region "$REGION" --project "$PROJECT_ID" --format='value(status.url)' 2>/dev/null || true)}"
ENV_VARS="DOCS_MCP_STORE_PATH=/data,DOCS_MCP_EMBEDDING_MODEL=${EMBEDDING_MODEL},DOCS_MCP_EMBEDDINGS_VECTOR_DIMENSION=${VECTOR_DIMENSION}"
if [ -n "$PUBLIC_URL" ]; then
  ENV_VARS="${ENV_VARS},DOCS_MCP_AUTH_PUBLIC_URL=${PUBLIC_URL}"
  log "URL pública para metadata OAuth: ${PUBLIC_URL}"
else
  log "AVISO: URL pública ainda desconhecida (1ª execução). Rode o script novamente após o deploy para gravar DOCS_MCP_AUTH_PUBLIC_URL."
fi

log "Deploy unificado (MCP+web+worker), público + OAuth, GCS FUSE em /data"
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
  --args="--enable-source-maps,dist/index.js,--protocol,http,--host,0.0.0.0,--port,8080,--auth-enabled,--auth-issuer-url,${AUTH_ISSUER_URL},--auth-audience,${AUTH_AUDIENCE}"

URL="$(gcloud run services describe "$SVC_UNIFIED" --region "$REGION" --project "$PROJECT_ID" --format='value(status.url)')"
ok "Servidor unificado em ${URL}"
echo "  • UI web:           ${URL}/"
echo "  • Conector Claude.ai: ${URL}/mcp"
