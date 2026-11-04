#!/usr/bin/env bash
# CASO: exit 0 (PASS) — espejo completo con todos los checks duros y MANUAL resueltos
# Verifica que el positivo no produce falsos negativos: todos los checks pasan
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

# base-espejo.sh ya construye el espejo válido con 7 receipts correctos y stubs de attest.
# No se necesita ninguna mutación.
run_check 0
