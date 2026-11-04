#!/usr/bin/env bash
# Crear sentinel .claude/.audit-go autorizando push del HEAD actual.
# Ejecutar SOLO tras GO explícito del lead post-auditoría.
#
# El sentinel es one-shot: el hook check-push-audit.sh lo consume tras
# allow del próximo `git push`. Pushes subsequentes requieren nuevo GO
# + re-ejecución de este script. Si haces commits adicionales entre
# audit-go y push, re-ejecutar con el nuevo SHA.
set -euo pipefail

head_sha=$(git rev-parse HEAD)
branch=$(git branch --show-current 2>/dev/null || echo "detached")
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p .claude
cat > .claude/.audit-go <<EOF
$head_sha
$branch
$timestamp
EOF

echo "✓ Audit GO registered:"
echo "  SHA:       $head_sha"
echo "  Branch:    $branch"
echo "  Timestamp: $timestamp"
echo ""
echo "Sentinel: .claude/.audit-go (one-shot — se consume en próximo git push)."
echo "Si haces nuevo commit antes del push, re-ejecutar este script con el nuevo SHA."
