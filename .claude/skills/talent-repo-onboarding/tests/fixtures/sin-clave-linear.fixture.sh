#!/usr/bin/env bash
# CASO: exit 2 (ERROR) — sin TF_LINEAR_TEAM_KEY (ni env, ni TRO_LINEAR_KEY, ni manifiesto): jamás se asume una clave (TAL-8037)
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

unset TF_LINEAR_TEAM_KEY TRO_LINEAR_KEY TF_MANIFEST
espejo_commit
run_check 2
