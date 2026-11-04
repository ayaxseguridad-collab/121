#!/usr/bin/env bash
# CASO: exit 1 (FAIL) — pre-push vacío: hash difiere del canónico
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

# Vaciar .githooks/pre-push → hash difiere
: > "$ESPEJO_DIR/.githooks/pre-push"

espejo_commit
run_check 1
