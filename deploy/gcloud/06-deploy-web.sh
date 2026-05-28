#!/usr/bin/env bash
# Deploy do web: interno + IAM. Acesso via `gcloud run services proxy`.
# Uso: WORKER_URL=<...> bash deploy/gcloud/06-deploy-web.sh
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

ok "web (interno) implantado"
echo "Acesse a UI:  gcloud run services proxy ${SVC_WEB} --region=${REGION} --project=${PROJECT_ID} --port=8080"
