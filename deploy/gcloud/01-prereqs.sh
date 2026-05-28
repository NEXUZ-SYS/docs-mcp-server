#!/usr/bin/env bash
# Habilita APIs e cria recursos base (Artifact Registry, buckets, service account).
# Idempotente: pode ser reexecutado.
source "$(dirname "$0")/lib.sh"

log "Habilitando APIs"
gcloud services enable \
  run.googleapis.com artifactregistry.googleapis.com secretmanager.googleapis.com \
  cloudbuild.googleapis.com cloudscheduler.googleapis.com compute.googleapis.com \
  --project "$PROJECT_ID"

log "Artifact Registry (${AR_REPO})"
create_ok gcloud artifacts repositories create "$AR_REPO" \
  --repository-format=docker --location="$REGION" --project "$PROJECT_ID"

log "Buckets GCS (uniform access)"
create_ok gcloud storage buckets create "gs://${BUCKET}" \
  --location="$REGION" --uniform-bucket-level-access --project "$PROJECT_ID"
create_ok gcloud storage buckets create "gs://${BACKUP_BUCKET}" \
  --location="$REGION" --uniform-bucket-level-access --project "$PROJECT_ID"
gcloud storage buckets update "gs://${BACKUP_BUCKET}" --versioning --project "$PROJECT_ID"

log "Service Account de runtime (docs-mcp-run)"
create_ok gcloud iam service-accounts create docs-mcp-run \
  --display-name="docs-mcp-server runtime" --project "$PROJECT_ID"

log "Private Google Access na sub-rede default (necessário p/ mcp/web alcançarem o worker interno via Direct VPC egress)"
gcloud compute networks subnets update default --region="$REGION" \
  --enable-private-ip-google-access --project "$PROJECT_ID"

log "IAM: acesso de objeto aos buckets para o SA de runtime"
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${RUNTIME_SA}" --role="roles/storage.objectAdmin" --project "$PROJECT_ID"
gcloud storage buckets add-iam-policy-binding "gs://${BACKUP_BUCKET}" \
  --member="serviceAccount:${RUNTIME_SA}" --role="roles/storage.objectAdmin" --project "$PROJECT_ID"

ok "Prereqs concluídos"
