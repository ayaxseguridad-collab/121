#!/usr/bin/env bash
# CASO: exit 1 (FAIL) — scripts/lib/handoff.sh ausente (dependencia transitiva de verify-handoff)
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

# Eliminar la dependencia transitiva del manifiesto IDÉNTICO
rm -f "$ESPEJO_DIR/scripts/lib/handoff.sh"

espejo_commit
run_check 1
