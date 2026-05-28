#!/usr/bin/env bash
# Helpers compartilhados pelos scripts de deploy. Idempotência e logging.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-config.env
source "${HERE}/00-config.env"

log() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }

# Executa um comando "create" tolerando recurso já existente (idempotência).
create_ok() {
  if "$@" 2>/tmp/gc_err; then
    return 0
  fi
  if grep -qiE "already exists|alreadyExists|already_exists" /tmp/gc_err; then
    return 0
  fi
  cat /tmp/gc_err >&2
  return 1
}
