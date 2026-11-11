#!/usr/bin/env bash
# detect_project_type.sh
# Uso: ./detect_project_type.sh [repo_path]
#
# Detecta el tipo de proyecto leyendo archivos indicadores y sugiere
# la plantilla apropiada de assets/coderabbit-templates/.
#
# Output: nombre de la plantilla recomendada (sin extensión)

set -euo pipefail

case "${1:-}" in
  -h|--help)
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

REPO_PATH="${1:-.}"
cd "$REPO_PATH"

# Detect all signals
HAS_PKG_JSON=$([ -f package.json ] && echo 1 || echo 0)
HAS_PYPROJECT=$([ -f pyproject.toml ] || [ -f requirements.txt ] || [ -f setup.py ] && echo 1 || echo 0)
HAS_CARGO=$([ -f Cargo.toml ] && echo 1 || echo 0)
HAS_GO_MOD=$([ -f go.mod ] && echo 1 || echo 0)
HAS_SOLIDITY=$([ -f hardhat.config.js ] || [ -f hardhat.config.ts ] || [ -f foundry.toml ] || [ -f truffle-config.js ] && echo 1 || echo 0)
HAS_MONOREPO=$([ -f pnpm-workspace.yaml ] || [ -f turbo.json ] || [ -f lerna.json ] || [ -f nx.json ] && echo 1 || echo 0)

# Docs-only: only markdown files at top level plus maybe config
MD_COUNT=$(find . -maxdepth 3 -name "*.md" -not -path "./node_modules/*" -not -path "./.git/*" 2>/dev/null | wc -l | tr -d ' ')
CODE_COUNT=$(find . -maxdepth 3 \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" -o -name "*.py" -o -name "*.go" -o -name "*.rs" -o -name "*.sol" \) -not -path "./node_modules/*" -not -path "./.git/*" 2>/dev/null | wc -l | tr -d ' ')

# Detect Example Stack specific signals
IS_EXAMPLE_STACK=0
if grep -qE "example-network|example-stack|examplestack|Example Stack|exampleproject|example-project" \
   README.md 2>/dev/null || \
   grep -qE "example-network|example-stack|examplestack" \
   package.json pyproject.toml Cargo.toml go.mod 2>/dev/null; then
  IS_EXAMPLE_STACK=1
fi

# Decision tree
if [ "$MD_COUNT" -gt 5 ] && [ "$CODE_COUNT" -lt 3 ]; then
  echo "docs-only"
elif [ "$HAS_SOLIDITY" = "1" ]; then
  echo "solidity-defi"
elif [ "$IS_EXAMPLE_STACK" = "1" ]; then
  echo "stack-internals"
elif [ "$HAS_MONOREPO" = "1" ]; then
  echo "monorepo"
elif [ "$HAS_PKG_JSON" = "1" ]; then
  echo "node-typescript"
elif [ "$HAS_PYPROJECT" = "1" ]; then
  echo "python"
elif [ "$HAS_CARGO" = "1" ]; then
  echo "rust"
elif [ "$HAS_GO_MOD" = "1" ]; then
  echo "go"
else
  echo "base-talent"
fi
