#!/usr/bin/env bash
# CASO: exit 0 (OK) — sin env, la clave de la instancia sale de la línea TF_LINEAR_TEAM_KEY= del manifiesto (TF_MANIFEST) (TAL-8037)
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

MF="$(mktemp)"; printf 'TF_LINEAR_TEAM_KEY="ABC"\n' > "$MF"
unset TF_LINEAR_TEAM_KEY TRO_LINEAR_KEY
export TF_MANIFEST="$MF"
espejo_commit
run_check 0
rc=$?
rm -f "$MF"
exit "$rc"
