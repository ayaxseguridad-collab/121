#!/usr/bin/env bash
# CASO: exit 1 (FAIL) — draft-handoff.sh no emite el sentinel (.draft-handoff ausente en el script)
# La estructura mínima exige: shebang + validar-rama-pr + sentinel draft-handoff + gate (≥3/4)
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

# Reemplazar draft-handoff.sh sin la referencia al sentinel (solo 2/4 tokens)
cat > "$ESPEJO_DIR/scripts/draft-handoff.sh" << 'EOF'
#!/usr/bin/env bash
bash scripts/github/validar-rama-pr.sh
npm run typecheck
EOF
chmod +x "$ESPEJO_DIR/scripts/draft-handoff.sh"

espejo_commit
run_check 1
