#!/usr/bin/env bash
# CASO: exit 0 — una negación ANTERIOR a la regla no la anula: el último patrón que casa gana y sigue ignorado (sin falso FAIL) (TAL-8040)
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

cat > "$ESPEJO_DIR/.gitignore" << 'EOF2'
.env.local
!.claude/.audit-go
!.claude/tf-manifest.conf
.claude/.cr-review-ok
.claude/.draft-handoff
.claude/.audit-go
.claude/tf-manifest.conf
.claude/.motor-go
.claude/.cr-review-*
EOF2

espejo_commit
run_check 0
