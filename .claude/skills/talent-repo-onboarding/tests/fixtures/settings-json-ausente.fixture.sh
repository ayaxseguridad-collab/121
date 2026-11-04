#!/usr/bin/env bash
# CASO: exit 1 (FAIL) — .claude/settings.json ausente
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

rm -f "$ESPEJO_DIR/.claude/settings.json"

espejo_commit
run_check 1
