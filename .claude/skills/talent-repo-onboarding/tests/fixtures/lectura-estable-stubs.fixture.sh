#!/usr/bin/env bash
# CASO: exit 0 (PASS) — con los stubs TRO_PROTECTION_JSON/TRO_REPO_JSON todo queda como antes: A2/A2b leen los
# ficheros y NO llaman a gh (el doble en el PATH no recibe ninguna orden).
# shellcheck source=tests/fixtures/lectura-estable-base.sh
source "$(dirname "$0")/lectura-estable-base.sh"

DURACION_VIVO=0
RC_VIVO=0
SALIDA_VIVO="$(PATH="$GH_DOBLE_DIR/bin:$PATH" \
  TRO_REPO_SLUG="$TEST_SLUG" \
  TRO_PROTECTION_JSON="$ESPEJO_PROTECTION" \
  TRO_REPO_JSON="$ESPEJO_REPO_JSON" \
  TRO_RECEIPTS_DIR="$ESPEJO_RECEIPTS" \
  TRO_ATTEST_DIR="$ESPEJO_ATTEST" \
  TRO_RECEIPT_AUTHORITIES="$AUTH_UID" \
  bash "$CHECKER" "$ESPEJO_DIR" 2>&1)" || RC_VIVO=$?
exige "rc=$RC_VIVO (esperado 0)" [ "$RC_VIVO" -eq 0 ]
exige "el doble recibió órdenes de gh" [ ! -s "$GH_DOBLE_DIR/llamadas.log" ]
exige "A2 no quedó en 12/12" contiene 'A2: 12/12 valores correctos'
exige "A2b no quedó en 4/4" contiene 'A2b: 4/4 valores correctos'
exige "apareció la lectura estable" no_contiene 'lectura estable'
veredicto "los stubs TRO_*_JSON no pasan por gh"
