#!/usr/bin/env bash
# CASO: exit 2 (ERROR) — manifiesto con fila duplicada para 'pre-push'
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

# Crear manifiesto temporal con fila duplicada
DUPE_MANIFEST="$(mktemp)"
cat "$SKILL_ROOT/assets/parity-manifest.tsv" > "$DUPE_MANIFEST"
printf 'pre-push\tIDENTICO\t.githooks/pre-push\t100755\thash|tipo|modo|exec\n' \
  >> "$DUPE_MANIFEST"

# Ejecutar checker con el manifiesto duplicado (sin usar run_check que no tiene TRO_MANIFEST)
actual=0
TRO_REPO_SLUG="$TEST_SLUG" \
TRO_PROTECTION_JSON="$ESPEJO_PROTECTION" \
TRO_REPO_JSON="$ESPEJO_REPO_JSON" \
TRO_RECEIPTS_DIR="$ESPEJO_RECEIPTS" \
TRO_ATTEST_DIR="$ESPEJO_ATTEST" \
TRO_RECEIPT_AUTHORITIES="$AUTH_UID" \
TRO_MANIFEST="$DUPE_MANIFEST" \
  bash "$CHECKER" "$ESPEJO_DIR" > /dev/null 2>&1 || actual=$?

rm -f "$DUPE_MANIFEST"

if [ "$actual" -eq 2 ]; then
  printf 'PASS: exit=%d (esperado=2)\n' "$actual"
else
  printf 'FAIL: exit=%d (esperado=2)\n' "$actual"
  exit 1
fi
