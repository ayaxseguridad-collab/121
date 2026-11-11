#!/usr/bin/env bash
# cr_loop_trigger.sh
# Uso: ./cr_loop_trigger.sh <owner/repo> <pr_number>
#
# Dispara un re-review incremental de CodeRabbit en el PR. Úsalo después
# de pushear fixes para que CR revise solo los cambios nuevos.
#
# Para review completo desde cero, pasa --full:
#   ./cr_loop_trigger.sh <owner/repo> <pr_number> --full

set -euo pipefail

case "${1:-}" in
  -h|--help)
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

REPO="${1:?Usage: $0 <owner/repo> <pr_number> [--full]}"
PR="${2:?Usage: $0 <owner/repo> <pr_number> [--full]}"
MODE="${3:-incremental}"

if [ "$MODE" = "--full" ]; then
  BODY="@coderabbitai full review"
  echo "Triggering FULL review (from scratch, ignores previous reviews)..."
else
  BODY="@coderabbitai review"
  echo "Triggering INCREMENTAL review (only new changes since last review)..."
fi

gh pr comment "$PR" --repo "$REPO" --body "$BODY"

echo ""
echo "CodeRabbit is reviewing. Typical latency: 1-3 min (deliberately 'Slow AI')."
echo "Poll with: gh pr view $PR --repo $REPO --comments"
