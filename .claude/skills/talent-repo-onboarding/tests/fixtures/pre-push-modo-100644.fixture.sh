#!/usr/bin/env bash
# CASO: exit 1 (FAIL) — .githooks/pre-push tiene modo 100644 en lugar de 100755
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

# Quitar bit ejecutable → modo 100644 en el índice tras re-add
chmod -x "$ESPEJO_DIR/.githooks/pre-push"

espejo_commit
run_check 1
