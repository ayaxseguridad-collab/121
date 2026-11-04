#!/usr/bin/env bash
# CASO: exit 1 (FAIL) — .gitignore con solo 2 de los 3 sentinels clásicos (falta .claude/.audit-go).
# El umbral antiguo (-ge 2 de 3) lo daba por bueno; el verificador exige LOS 6 patrones (TAL-8040).
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

cat > "$ESPEJO_DIR/.gitignore" << 'EOF2'
.env.local
.claude/.cr-review-ok
.claude/.draft-handoff
.claude/tf-manifest.conf
.claude/.motor-go
.claude/.cr-review-*
EOF2

espejo_commit
run_check 1
