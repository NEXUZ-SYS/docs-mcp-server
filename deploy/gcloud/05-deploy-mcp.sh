#!/usr/bin/env bash
# Deploy do mcp: público, OAuth (Auth0), alcança o worker interno via Direct VPC egress.
# Uso: WORKER_URL=<...> AUTH0_ISSUER_URL=<...> AUTH0_AUDIENCE=<...> bash deploy/gcloud/05-deploy-mcp.sh
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
ok "mcp público em ${MCP_URL}"
echo "Endpoint do conector Claude.ai:  ${MCP_URL}/mcp"
