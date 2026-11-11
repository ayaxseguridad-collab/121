#!/usr/bin/env bash
# detect_plan.sh — Paso 0 del skill: detectar la org del repo y el plan CodeRabbit aplicable.
# Uso:
#   ./detect_plan.sh                  # deriva el repo del cwd (gh/git) y resuelve el plan
#   ./detect_plan.sh --plan <plan>    # fuerza el plan (repo/org quedan sin resolver)
#   ./detect_plan.sh --help
#
# Vocabulario 2026-08-13: CodeRabbit renombró los planes Pro -> Essentials y
# Pro+ -> Team, y anadio Advanced entre Team y Enterprise. Los sinonimos legacy
# "pro"/"pro-plus" se siguen aceptando como ENTRADA de --plan (se normalizan a
# essentials/team); la SALIDA de este script nunca imprime el vocabulario viejo.
#
# NO existe API publica de subscription/plan (`metrics/reviews` es Enterprise-only;
# verificado 2026-09-05 contra docs.coderabbit.ai/openapi.json), asi que el plan se
# resuelve con el mapping org->plan mantenido abajo (verificado 2026-09-05: los PRs
# #2260/#2243 de este repo declaran "Plan: Team" en la review de CodeRabbit).
# Verificacion viva de cuota: comentar "@coderabbitai rate limit" en un PR (no
# consume review) o el dashboard Review Usage (app.coderabbit.ai, desde 2026-09-01).
# Detalle completo de limites y fair usage: ../references/rate-limits.md
#
# last_verified: 2026-09-05
set -euo pipefail

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//'; }

FORCED_PLAN=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --plan)
      FORCED_PLAN="${2:?--plan requiere un valor: essentials|team|advanced|enterprise (o legacy pro|pro-plus)}"
      shift 2
      ;;
    *)
      echo "ERROR: argumento desconocido: $1 (usa --help)" >&2
      exit 1
      ;;
  esac
done

# Normaliza un nombre de plan legacy o vigente a vocabulario vigente.
normalize_plan() {
  case "$1" in
    pro) echo "essentials" ;;
    pro-plus | pro_plus | "pro+") echo "team" ;;
    essentials | team | advanced | enterprise) echo "$1" ;;
    *)
      echo "ERROR: plan desconocido '$1' (usa essentials|team|advanced|enterprise, o los legacy pro|pro-plus)" >&2
      exit 1
      ;;
  esac
}

UNKNOWN_ORG=0
if [ -n "$FORCED_PLAN" ]; then
  PLAN="$(normalize_plan "$FORCED_PLAN")"
  REPO="(forzado por --plan, sin resolver)"
  ORG="(forzado por --plan, sin resolver)"
else
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  if [ -z "$REPO" ]; then
    REMOTE="$(git remote get-url origin 2>/dev/null || true)"
    if [ -n "$REMOTE" ]; then
      REMOTE="${REMOTE%.git}"
      # Todo lo que va despues de "github.com/" o "github.com:" es "owner/repo"
      # (el repo puede llevar puntos, p.ej. "repo.v2": no restringir a [^.]).
      REPO="$(echo "$REMOTE" | sed -E 's#.*github\.com[:/]##')"
    fi
  fi
  if [ -z "$REPO" ]; then
    echo "ERROR: no se pudo derivar el repo (gh sin auth y sin remote origin); usa --plan <plan> para forzarlo" >&2
    exit 1
  fi
  ORG="${REPO%%/*}"

  # Mapping org->plan — verificado 2026-09-05 (PR #2260/#2243 "Plan: Team").
  # Si cambia una suscripcion: actualizar este case Y la tabla de references/rate-limits.md.
  case "$ORG" in
    ejemplo) PLAN="team" ;;
    example-network-org | example-stack-org | example-engine-org | example-engine-2) PLAN="essentials" ;;
    *)
      PLAN="essentials"
      UNKNOWN_ORG=1
      ;;
  esac
fi

# Cuotas estandar por plan (rate-limits.md tiene la tabla completa con fuente).
case "$PLAN" in
  enterprise)
    PR_REVIEWS=12
    CHAT="— (no republicado)"   # Enterprise: sin cifra publicada de chat (ver rate-limits.md)
    MCP=20
    LINKED_REPOS=20
    CUSTOM_CHECKS=20
    FILES_PER_REVIEW=300   # techo global documentado: 300 ficheros/review (changelog 2026-07-15; ver rate-limits.md)
    ;;
  advanced)
    PR_REVIEWS=10
    CHAT=100
    MCP=15
    LINKED_REPOS=10
    CUSTOM_CHECKS=20
    FILES_PER_REVIEW=300
    ;;
  team)
    PR_REVIEWS=8
    CHAT=75
    MCP=10
    LINKED_REPOS=5
    CUSTOM_CHECKS=10
    FILES_PER_REVIEW=300
    ;;
  essentials)
    PR_REVIEWS=5
    CHAT=50
    MCP=5
    LINKED_REPOS=1
    CUSTOM_CHECKS="no disponible en Essentials"
    FILES_PER_REVIEW=150
    ;;
esac

echo "repo=$REPO"
echo "org=$ORG"
echo "plan=$PLAN"
echo "pr_reviews_per_dev_hour=$PR_REVIEWS"
echo "chat_per_dev_hour=$CHAT"
echo "mcp_connections_max=$MCP"
echo "linked_repos_max=$LINKED_REPOS"
echo "custom_checks_max=$CUSTOM_CHECKS"
echo "files_per_review=$FILES_PER_REVIEW"

if [ "$PLAN" = "team" ]; then
  echo "note=Team: 8/h es el estandar; hasta 10/h SOLO si la org quedo 'grandfathered' desde Pro+ tras el rename 2026-08-13 — confirmar con '@coderabbitai rate limit' en un PR (no consume review) o el dashboard Review Usage (app.coderabbit.ai)."
elif [ "$PLAN" = "advanced" ]; then
  echo "note=Advanced: 10/h es el estandar (no depende de grandfathering)."
fi
if [ "$UNKNOWN_ORG" = "1" ]; then
  # Salida estructurada key=value: va por stdout como el resto del contrato (stderr queda para errores).
  echo "warning=org '$ORG' no mapeada; asumido essentials (conservador, ex Pro). Verificar plan real en app.coderabbit.ai/settings/subscription o '@coderabbitai rate limit' y actualizar el mapping."
fi
