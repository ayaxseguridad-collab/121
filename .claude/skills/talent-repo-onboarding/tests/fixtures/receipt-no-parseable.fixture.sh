#!/usr/bin/env bash
# CASO: exit 2 (ERROR) — receipt de linear-integration no es JSON válido
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

# Sobreescribir receipt con contenido que no es JSON
printf 'esto no es json valido\n' > "$ESPEJO_RECEIPTS/linear-integration.json"

run_check 2
