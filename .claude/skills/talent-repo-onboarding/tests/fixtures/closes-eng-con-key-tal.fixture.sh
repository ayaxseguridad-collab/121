#!/usr/bin/env bash
# CASO: exit 1 (FAIL) — PR template contiene 'Closes ENG-N' pero la key de la instancia es ABC (TF_LINEAR_TEAM_KEY)
# Verifica que el checker valida POR KEY (falso positivo documentado del repo TA)
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

cat > "$ESPEJO_DIR/.github/PULL_REQUEST_TEMPLATE.md" << 'EOF'
## Descripción

Closes ENG-N
EOF

espejo_commit
run_check 1
