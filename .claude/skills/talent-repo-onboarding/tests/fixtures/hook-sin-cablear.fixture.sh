#!/usr/bin/env bash
# CASO: exit 1 (FAIL) — check-skill.sh presente pero no referenciado en settings.json
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

# Sobreescribir settings.json sin referencia a check-skill
cat > "$ESPEJO_DIR/.claude/settings.json" << 'EOF'
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash scripts/check-push-audit.sh"}]}
    ]
  }
}
EOF

espejo_commit
run_check 1
