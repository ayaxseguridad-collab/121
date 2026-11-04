#!/usr/bin/env bash
# CASO: exit 1 (FAIL) — el PR template cierra con la clave de OTRA casa (Closes TAL-N) y la clave de la instancia es ABC (TAL-8037)
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

cat > "$ESPEJO_DIR/.github/PULL_REQUEST_TEMPLATE.md" << 'EOF2'
## Descripción

Closes TAL-N
EOF2

espejo_commit
run_check 1
