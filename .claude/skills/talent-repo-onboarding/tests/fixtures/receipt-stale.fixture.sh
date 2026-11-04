#!/usr/bin/env bash
# CASO: exit 3 (MANUAL-PENDING) — receipt de linear-integration expirado
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

# Sobrescribir receipt linear-integration con fechas en el pasado (expirado hace 1 día)
now="$(date +%s)"
past_issued="$(_iso_ts "$(( now - 864000 ))")"  # hace 10 días
past_expires="$(_iso_ts "$(( now - 259200 ))")" # hace 3 días (TTL=604800 desde issued)

jq -n \
  --arg issued "$past_issued" \
  --arg expires "$past_expires" \
  --arg repo "$TEST_SLUG" \
  --arg sha_c "$CANON_SHA_TEST" \
  '{
    receipt_version: "1",
    check_id: "linear-integration",
    repo: $repo,
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
