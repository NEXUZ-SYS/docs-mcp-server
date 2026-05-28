#!/usr/bin/env bash
# Deploy do worker: interno, single-instance, SQLite em GCS FUSE montado em /data.
source "$(dirname "$0")/lib.sh"

log "Deploy worker (interno, single-instance, GCS FUSE em /data)"
gcloud run deploy "$SVC_WORKER" \
  --image="$IMAGE" --region="$REGION" --project="$PROJECT_ID" \
  --service-account="$RUNTIME_SA" \
  --ingress=internal \
  --allow-unauthenticated \
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
echo "Defina para os próximos scripts:  export WORKER_URL=${WORKER_URL}"
