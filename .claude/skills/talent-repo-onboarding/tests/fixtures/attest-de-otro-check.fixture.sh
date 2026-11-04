#!/usr/bin/env bash
# CASO: exit 3 (MANUAL-PENDING) — binding del comentario tiene check_id equivocado
# El binding de 1001 dice check_id=cr-app-instalada pero el receipt es linear-integration
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

# Reutilizar el mismo stub 1001 pero con binding para otro check_id
jq -n \
  --argjson uid "$AUTH_UID" \
  --arg body "attest v1 check_id=cr-app-instalada repo=${TEST_SLUG} branch=main sha_probado=abc1234567890123456789012345678901234 sha_canonico=${CANON_SHA_TEST} actor=${AUTH_UID} evidencia_sha256=placeholder" \
  '{user: {id: $uid, login: "test-user"}, body: $body}' \
  > "$ESPEJO_ATTEST/1001.json"

run_check 3
