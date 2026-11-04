#!/usr/bin/env bash
# CASO: exit 3 (MANUAL-PENDING) — receipt de linear-integration tiene repo equivocado
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

now="$(date +%s)"
issued="$(_iso_ts "$now")"
expires="$(_iso_ts "$(( now + 604800 ))")"

jq -n \
  --arg issued "$issued" \
  --arg expires "$expires" \
  --arg sha_c "$CANON_SHA_TEST" \
  '{
    receipt_version: "1",
    check_id: "linear-integration",
    repo: "otro/repo",
    branch: "main",
    sha_probado: "abc1234567890123456789012345678901234",
    sha_canonico: $sha_c,
    actor: "test-user",
    issued_at: $issued,
    expires_at: $expires,
    evidencia: {
      pr_url: "https://github.com/test/espejo/pull/1",
      issue_id: "TST-1",
      attest_comment_id: 1001
    }
  }' > "$ESPEJO_RECEIPTS/linear-integration.json"

run_check 3
