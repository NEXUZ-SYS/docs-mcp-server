#!/usr/bin/env bash
# Backup diário do SQLite: Cloud Run Job (gsutil bucket→backup) disparado por Cloud Scheduler.
# Rode após o primeiro scrape, quando o arquivo .db já existir no bucket.
source "$(dirname "$0")/lib.sh"

# Nome do arquivo SQLite no bucket (confirmar na validação; default do app: documents.db)
DB_OBJECT="${DB_OBJECT:-documents.db}"

log "Cloud Run Job de backup (copia .db para o bucket versionado)"
gcloud run jobs deploy docs-mcp-backup \
  --image="google/cloud-sdk:slim" --region="$REGION" --project="$PROJECT_ID" \
  --service-account="$RUNTIME_SA" \
  --command=/bin/sh \
  --args="-c,gsutil cp gs://${BUCKET}/${DB_OBJECT} gs://${BACKUP_BUCKET}/${DB_OBJECT}.\$(date +%Y%m%d%H%M%S)"

log "Permitir que o SA invoque o job"
gcloud run jobs add-iam-policy-binding docs-mcp-backup \
  --member="serviceAccount:${RUNTIME_SA}" --role="roles/run.invoker" \
  --region="$REGION" --project "$PROJECT_ID"

log "Cloud Scheduler diário (03:00) disparando o job"
create_ok gcloud scheduler jobs create http docs-mcp-backup-daily \
  --location="$REGION" --schedule="0 3 * * *" \
  --uri="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT_ID}/jobs/docs-mcp-backup:run" \
  --http-method=POST \
  --oauth-service-account-email="$RUNTIME_SA" \
  --project "$PROJECT_ID"

ok "Backup diário configurado"
echo "Restore:  gsutil cp gs://${BACKUP_BUCKET}/<arquivo> gs://${BUCKET}/${DB_OBJECT}  (worker parado)"
