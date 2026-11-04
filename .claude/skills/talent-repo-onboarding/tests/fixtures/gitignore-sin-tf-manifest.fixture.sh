#!/usr/bin/env bash
# CASO: exit 1 (FAIL) — .gitignore con los 3 sentinels clásicos y el resto, pero SIN la regla viva de
# .claude/tf-manifest.conf (solo aparece COMENTADA: una línea comentada no cuenta). TAL-8040.
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

cat > "$ESPEJO_DIR/.gitignore" << 'EOF2'
.env.local
.claude/.cr-review-ok
.claude/.draft-handoff
.claude/.audit-go
# .claude/tf-manifest.conf
.claude/.motor-go
.claude/.cr-review-*
EOF2

espejo_commit
run_check 1
