#!/usr/bin/env bash
# CASO: exit 2 (ERROR) — TF_LINEAR_TEAM_KEY multilínea ($'X2Y\n.*') se rechaza: se valida la cadena COMPLETA (TAL-8037, acta m1)
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

export TF_LINEAR_TEAM_KEY=$'X2Y\n.*'
espejo_commit
run_check 2
