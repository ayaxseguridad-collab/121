#!/usr/bin/env bash
# CASO: exit 3 (MANUAL-PENDING) — atestación firmada por user.id no autorizado
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

# Sobrescribir stub 1001 con user.id que NO está en TRO_RECEIPT_AUTHORITIES
# AUTH_UID=99999999; usamos 00000000 (no autorizado)
jq -n \
  --arg body "attest v1 check_id=linear-integration repo=${TEST_SLUG} branch=main sha_probado=abc1234567890123456789012345678901234 sha_canonico=${CANON_SHA_TEST} actor=00000000 evidencia_sha256=placeholder" \
  '{user: {id: 0, login: "unauthorized-user"}, body: $body}' \
  > "$ESPEJO_ATTEST/1001.json"

run_check 3
