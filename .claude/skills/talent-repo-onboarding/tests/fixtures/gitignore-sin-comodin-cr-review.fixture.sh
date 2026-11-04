#!/usr/bin/env bash
# CASO: exit 1 — .gitignore sin el comodín .claude/.cr-review-* (los otros cinco presentes) (TAL-8040)
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

cat > "$ESPEJO_DIR/.gitignore" << 'EOF2'
.env.local
.claude/.cr-review-ok
.claude/.draft-handoff
.claude/.audit-go
.claude/tf-manifest.conf
.claude/.motor-go
EOF2

espejo_commit
run_check 1
