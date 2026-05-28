#!/usr/bin/env bash
# Build & push da imagem via Cloud Build usando o Dockerfile multi-stage existente.
source "$(dirname "$0")/lib.sh"

log "Build & push via Cloud Build: ${IMAGE}"
gcloud builds submit --tag "$IMAGE" --project "$PROJECT_ID" .

ok "Imagem publicada: ${IMAGE}"
