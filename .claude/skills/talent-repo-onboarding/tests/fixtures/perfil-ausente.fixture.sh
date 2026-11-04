#!/usr/bin/env bash
# CASO: exit 1 (FAIL) — docs/reference/issue-craft-perfil*.md ausente
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

rm -f "$ESPEJO_DIR/docs/reference/issue-craft-perfil-espejo.md"

espejo_commit
run_check 1
