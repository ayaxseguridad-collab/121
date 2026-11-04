#!/usr/bin/env bash
# CASO: exit 1 (FAIL) — A2 enforce_admins=true (campo 3/12 incorrecto)
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

cat > "$ESPEJO_PROTECTION" << 'PJSON'
{
  "required_status_checks": {
    "checks": [{"context": "local-gates"}],
    "strict": true
  },
  "enforce_admins": {"enabled": true},
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
  "required_conversation_resolution": {"enabled": true}
}
PJSON

run_check 1
