#!/usr/bin/env bash
# CASO: exit 3 (MANUAL-PENDING) — atestación no encontrada (stub ausente en TRO_ATTEST_DIR)
# El checker llama attest_readback → stub dir configurado, archivo ausente → return 1 → mark_pending
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

# Eliminar el stub del comentario 1001 (linear-integration)
rm -f "$ESPEJO_ATTEST/1001.json"

run_check 3
