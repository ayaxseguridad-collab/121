#!/usr/bin/env bash
# CASO: exit 1 — el comodín .cr-review-* cubriría .cr-review-ok pero una negación posterior lo reactiva (TAL-8040)
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

cat > "$ESPEJO_DIR/.gitignore" << 'EOF2'
.env.local
.claude/.draft-handoff
.claude/.audit-go
.claude/tf-manifest.conf
.claude/.motor-go
.claude/.cr-review-*
!.claude/.cr-review-ok
EOF2

espejo_commit
run_check 1
