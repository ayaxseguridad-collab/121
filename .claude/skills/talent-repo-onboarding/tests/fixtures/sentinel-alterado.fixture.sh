#!/usr/bin/env bash
# CASO: exit 1 (FAIL) — .gitignore no ignora los sentinels de fábrica
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

# Reemplazar .gitignore sin los sentinels
cat > "$ESPEJO_DIR/.gitignore" << 'EOF'
.env.local
node_modules/
EOF

espejo_commit
run_check 1
