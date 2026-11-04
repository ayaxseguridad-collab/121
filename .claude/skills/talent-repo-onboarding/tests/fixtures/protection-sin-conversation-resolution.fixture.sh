#!/usr/bin/env bash
# CASO: exit 1 (FAIL) — A2 sin required_conversation_resolution (campo 12/12 ausente)
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

# Sobrescribir stub de protection con conversation_resolution=false
cat > "$ESPEJO_PROTECTION" << 'PJSON'
{
  "required_status_checks": {
    "checks": [{"context": "local-gates"}],
    "strict": true
  },
  "enforce_admins": {"enabled": false},
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "require_last_push_approval": false
  },
  "restrictions": null,
  "required_linear_history": {"enabled": true},
  "allow_force_pushes": {"enabled": false},
  "allow_deletions": {"enabled": false},
  "block_creations": {"enabled": false},
  "required_conversation_resolution": {"enabled": false}
}
PJSON

# No es necesario espejo_commit: la mutación es en el stub de API, no en el repo
run_check 1
