#!/usr/bin/env bash
# CASO: exit 1 (FAIL) — core.hooksPath no es '.githooks' (vacío)
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

# Borrar core.hooksPath del config local del espejo
git -C "$ESPEJO_DIR" config --unset core.hooksPath

# No es necesario espejo_commit: la mutación es en git config, no en el tree
run_check 1
