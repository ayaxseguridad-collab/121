#!/usr/bin/env bash
# CASO: exit 3 (MANUAL-PENDING) — evidencia_sha256 del binding no coincide con la evidencia real
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

# Sobrescribir stub 1001 con evidencia_sha256 incorrecto (hash inventado)
jq -n \
  --argjson uid "$AUTH_UID" \
  --arg body "attest v1 check_id=linear-integration repo=${TEST_SLUG} branch=main sha_probado=abc1234567890123456789012345678901234 sha_canonico=${CANON_SHA_TEST} actor=${AUTH_UID} evidencia_sha256=0000000000000000000000000000000000000000000000000000000000000000" \
  '{user: {id: $uid, login: "test-user"}, body: $body}' \
  > "$ESPEJO_ATTEST/1001.json"

run_check 3
