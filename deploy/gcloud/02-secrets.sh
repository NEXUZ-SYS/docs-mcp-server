#!/usr/bin/env bash
# Cria/atualiza o secret GOOGLE_API_KEY (Gemini) e concede acesso ao SA de runtime.
# Uso: GOOGLE_API_KEY="<sua-key>" bash deploy/gcloud/02-secrets.sh
source "$(dirname "$0")/lib.sh"
: "${GOOGLE_API_KEY:?Defina GOOGLE_API_KEY no ambiente antes de rodar (não commitar)}"

log "Criando/atualizando secret ${SECRET_GOOGLE_API_KEY}"
if gcloud secrets describe "$SECRET_GOOGLE_API_KEY" --project "$PROJECT_ID" >/dev/null 2>&1; then
  printf '%s' "$GOOGLE_API_KEY" | gcloud secrets versions add "$SECRET_GOOGLE_API_KEY" \
    --data-file=- --project "$PROJECT_ID"
else
  printf '%s' "$GOOGLE_API_KEY" | gcloud secrets create "$SECRET_GOOGLE_API_KEY" \
    --data-file=- --replication-policy=automatic --project "$PROJECT_ID"
fi

gcloud secrets add-iam-policy-binding "$SECRET_GOOGLE_API_KEY" \
  --member="serviceAccount:${RUNTIME_SA}" --role="roles/secretmanager.secretAccessor" \
  --project "$PROJECT_ID"

ok "Secret pronto"
