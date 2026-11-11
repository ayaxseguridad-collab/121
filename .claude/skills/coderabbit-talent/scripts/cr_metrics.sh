#!/usr/bin/env bash
# cr_metrics.sh (v2 — state-of-the-art 2026-04)
# Uso:
#   ./cr_metrics.sh [<owner/repo>] [--since YYYY-MM-DD] [--pr-limit N]
#                   [--baseline] [--aggregate <repo1,repo2,...>]
#
# Calcula métricas de uso y calidad de CodeRabbit sobre los últimos PRs del repo.
# Genera tabla markdown con:
#   - total comentarios de CR
#   - breakdown por categoría (security/bug/refactor/nitpick/perf/other)
#   - resolve rate (% resueltos)
#   - challenge rate (% con respuesta de usuario)
#   - nitpick ratio (señal de que .coderabbit.yaml necesita tuning)
#   - acceptance rate (proxy: % de threads resueltos SIN reply del usuario).
#     El proxy supone que un thread cerrado sin disagreement explícito
#     indica aceptación del fix. NO verifica commits posteriores al
#     comentario que toquen archivo/línea — eso requeriría queries
#     adicionales de commits+files por PR. Se usa como criterio del paso C
#     del plan v5 (umbral: si acceptance ≤ 35% o nitpick ≥ 40% → bajar a
#     profile: chill).
#
# Flags:
#   --baseline
#     Añade una línea "<!-- baseline snapshot: YYYY-MM-DD -->" al inicio
#     del output. Útil para guardar baseline en .claude/memory/ antes de
#     ajustar config, y comparar después.
#   --aggregate <csv-de-repos>
#     Procesa múltiples repos (separados por coma) y emite tabla
#     comparativa con una fila por repo (total/resolve/nitpick). Útil
#     para seguimiento multi-repo.
#
# Derivación dinámica: si no se pasa <owner/repo>, deriva con
# `gh repo view --json nameWithOwner` en el cwd (con fallback a
# `git remote get-url origin`).
#
# Requiere: gh CLI autenticado, jq.
#
# Nota shellcheck: SC2016 (info) es esperado y no se corrige — la query
# GraphQL de abajo va en comillas simples A PROPOSITO (texto literal para
# -f query=, no debe expandir variables de shell).
#
# last_verified: 2026-09-05

set -euo pipefail

REPO=""
SINCE=""
PR_LIMIT=20
BASELINE=false
AGGREGATE=""

# Parseo de args (soporta que el primer posicional sea opcional)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2;;
    --pr-limit) PR_LIMIT="$2"; shift 2;;
    --baseline) BASELINE=true; shift;;
    --aggregate) AGGREGATE="$2"; shift 2;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) echo "Unknown arg: $1" >&2; exit 1;;
    *)
      if [[ -z "$REPO" ]]; then REPO="$1"; shift
      else echo "Arg extra: $1" >&2; exit 1; fi
      ;;
  esac
done

derive_repo() {
  local repo=""
  if command -v gh >/dev/null 2>&1; then
    repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  fi
  if [[ -z "$repo" ]]; then
    local remote
    remote="$(git remote get-url origin 2>/dev/null || true)"
    [[ -n "$remote" ]] && repo="$(echo "$remote" | sed -E 's#.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#')"
  fi
  echo "$repo"
}

fetch_metrics_for_repo() {
  local repo="$1"
  local owner="${repo%/*}"
  local name="${repo#*/}"

  local query='
  query($owner: String!, $name: String!, $limit: Int!) {
    repository(owner: $owner, name: $name) {
      pullRequests(first: $limit, orderBy: {field: UPDATED_AT, direction: DESC}, states: [OPEN, MERGED, CLOSED]) {
        nodes {
          number
          title
          createdAt
          mergedAt
          reviewThreads(first: 100) {
            nodes {
              id
              isResolved
              comments(first: 20) {
                totalCount
                nodes {
                  author { login }
                  body
                  createdAt
                }
              }
            }
          }
        }
      }
    }
  }'

  local raw
  raw="$(gh api graphql \
    -f query="$query" \
    -F owner="$owner" \
    -F name="$name" \
    -F limit="$PR_LIMIT")"

  echo "$raw" | jq --arg since "$SINCE" '
    def is_cr: .comments.nodes[0].author.login | test("coderabbitai"; "i");
    def has_user_reply:
      (.comments.nodes | length > 1) and
      (.comments.nodes[1:] | any(.author.login | test("coderabbitai"; "i") | not));
    def category:
      .comments.nodes[0].body
      | if test("🛡️|Security"; "i") then "security"
        elif test("⚠️ Potential issue|Potential bug"; "i") then "bug"
        elif test("🛠️ Refactor"; "i") then "refactor"
        elif test("🧹 Nitpick|nitpick \\(optional\\)"; "i") then "nitpick"
        elif test("⚡|Performance"; "i") then "performance"
        elif test("📝 Documentation"; "i") then "docs"
        else "other" end;

    [.data.repository.pullRequests.nodes[]
      | select($since == "" or .createdAt >= $since)
      | .reviewThreads.nodes[]
      | select(is_cr)
      | {
          category: category,
          resolved: .isResolved,
          challenged: has_user_reply
        }
    ] as $threads
    | {
        total: ($threads | length),
        resolved: ($threads | map(select(.resolved)) | length),
        challenged: ($threads | map(select(.challenged)) | length),
        # accepted (proxy): thread resuelto y sin reply del usuario.
        # No verifica commits posteriores — documentado en header.
        accepted: ($threads | map(select(.resolved and (.challenged | not))) | length),
        by_category: ($threads | group_by(.category)
                      | map({category: .[0].category, count: length})
                      | sort_by(-.count))
      }
  '
}

# ----------------------------------------------------------------------
# Modo --aggregate: tabla multi-repo compacta
# ----------------------------------------------------------------------
if [[ -n "$AGGREGATE" ]]; then
  TS="$(date +%Y-%m-%d)"
  if [[ "$BASELINE" == "true" ]]; then
    echo "<!-- baseline aggregate snapshot: $TS -->"
  fi
  echo "# CodeRabbit Metrics — Multi-repo"
  echo ""
  echo "_Last ${PR_LIMIT} PRs${SINCE:+ (since ${SINCE})}_"
  echo ""
  echo "| Repo | Total | Resolve % | Challenge % | Nitpick % | Acceptance % (proxy) |"
  echo "|---|---|---|---|---|---|"
  IFS=',' read -ra REPOS <<< "$AGGREGATE"
  for R in "${REPOS[@]}"; do
    R="$(echo "$R" | xargs)"  # trim
    [[ -z "$R" ]] && continue
    METRICS="$(fetch_metrics_for_repo "$R" 2>/dev/null || echo '{"total":0,"resolved":0,"challenged":0,"accepted":0,"by_category":[]}')"
    T="$(echo "$METRICS" | jq -r '.total')"
    RES="$(echo "$METRICS" | jq -r '.resolved')"
    CH="$(echo "$METRICS" | jq -r '.challenged')"
    ACC="$(echo "$METRICS" | jq -r '.accepted // 0')"
    NP="$(echo "$METRICS" | jq -r '.by_category[] | select(.category=="nitpick") | .count // 0' || echo 0)"
    NP="${NP:-0}"
    if [[ "$T" == "0" ]]; then
      echo "| $R | 0 | - | - | - | - |"
    else
      RR="$(awk -v a="$RES" -v t="$T" 'BEGIN { printf "%.1f", a*100/t }')"
      CHR="$(awk -v a="$CH" -v t="$T" 'BEGIN { printf "%.1f", a*100/t }')"
      NPR="$(awk -v a="$NP" -v t="$T" 'BEGIN { printf "%.1f", a*100/t }')"
      ACCR="$(awk -v a="$ACC" -v t="$T" 'BEGIN { printf "%.1f", a*100/t }')"
      echo "| $R | $T | ${RR}% | ${CHR}% | ${NPR}% | ${ACCR}% |"
    fi
  done
  exit 0
fi

# ----------------------------------------------------------------------
# Modo single repo (con derivación dinámica si no se pasa)
# ----------------------------------------------------------------------
if [[ -z "$REPO" ]]; then
  REPO="$(derive_repo)"
fi
if [[ -z "$REPO" ]]; then
  echo "Error: no se pudo derivar el slug del repo. Pasa <owner/repo> como argumento." >&2
  exit 1
fi

echo "Fetching metrics for ${REPO} (last ${PR_LIMIT} PRs${SINCE:+, since ${SINCE}})..." >&2

METRICS="$(fetch_metrics_for_repo "$REPO")"

TOTAL=$(echo "$METRICS" | jq -r '.total')
RESOLVED=$(echo "$METRICS" | jq -r '.resolved')
CHALLENGED=$(echo "$METRICS" | jq -r '.challenged')
ACCEPTED=$(echo "$METRICS" | jq -r '.accepted // 0')

if [[ "$TOTAL" == "0" ]]; then
  echo "No CodeRabbit comments found in the last ${PR_LIMIT} PRs."
  exit 0
fi

RESOLVE_RATE=$(awk -v a="$RESOLVED" -v t="$TOTAL" 'BEGIN { printf "%.1f", a*100/t }')
CHALLENGE_RATE=$(awk -v a="$CHALLENGED" -v t="$TOTAL" 'BEGIN { printf "%.1f", a*100/t }')
ACCEPTANCE_RATE=$(awk -v a="$ACCEPTED" -v t="$TOTAL" 'BEGIN { printf "%.1f", a*100/t }')
NITPICK_COUNT=$(echo "$METRICS" | jq -r '.by_category[] | select(.category=="nitpick") | .count // 0')
NITPICK_COUNT="${NITPICK_COUNT:-0}"
NITPICK_RATIO=$(awk -v a="$NITPICK_COUNT" -v t="$TOTAL" 'BEGIN { printf "%.1f", a*100/t }')

# Marca baseline si procede
if [[ "$BASELINE" == "true" ]]; then
  TS="$(date +%Y-%m-%d)"
  echo "<!-- baseline snapshot: $TS -->"
fi

# Output markdown
cat <<EOF
# CodeRabbit Metrics — ${REPO}

_Last ${PR_LIMIT} PRs${SINCE:+ (since ${SINCE})}_

## Summary

| Metric | Value |
|---|---|
| Total CR comments | ${TOTAL} |
| Resolved | ${RESOLVED} (${RESOLVE_RATE}%) |
| Challenged by user | ${CHALLENGED} (${CHALLENGE_RATE}%) |
| Accepted (proxy: resolved & not challenged) | ${ACCEPTED} (${ACCEPTANCE_RATE}%) |
| Nitpick ratio | ${NITPICK_RATIO}% |

## By category

| Category | Count |
|---|---|
EOF

echo "$METRICS" | jq -r '.by_category[] | "| \(.category) | \(.count) |"'

# Health assessment
cat <<EOF

## Health assessment

EOF

# Nitpick ratio > 40% → tuning recomendado
if awk -v r="$NITPICK_RATIO" 'BEGIN { exit !(r > 40) }'; then
  cat <<EOF
⚠️ **High nitpick ratio (${NITPICK_RATIO}%)**. Consider tuning \`.coderabbit.yaml\`:
- Confirm \`profile: chill\` is set
- Add negative rules in \`reviews.instructions\` (e.g., "Do not comment on naming of internal variables")
- Exclude noisy paths via \`path_filters\`

EOF
else
  echo "✅ Nitpick ratio is healthy (< 40%)."
  echo ""
fi

# Resolve rate < 50% → posible abandono
if awk -v r="$RESOLVE_RATE" 'BEGIN { exit !(r < 50) }'; then
  cat <<EOF
⚠️ **Low resolve rate (${RESOLVE_RATE}%)**. Team may be ignoring CR comments.
Run retrospective: are comments actually useful? Is setup correct?

EOF
else
  echo "✅ Resolve rate is healthy (≥ 50%)."
  echo ""
fi

# Challenge rate: sweet spot entre 5-25%
if awk -v r="$CHALLENGE_RATE" 'BEGIN { exit !(r < 5) }'; then
  printf '%s\n' \
    "ℹ️ **Low challenge rate (${CHALLENGE_RATE}%)**. Team is not pushing back on CR." \
    'Either CR is always right (unlikely) or team is rubber-stamping. Encourage' \
    "active disagreement on wrong comments — it trains CR's learning." \
    ''
elif awk -v r="$CHALLENGE_RATE" 'BEGIN { exit !(r > 25) }'; then
  cat <<EOF
⚠️ **High challenge rate (${CHALLENGE_RATE}%)**. Team is frequently disagreeing with CR.
This suggests the config is off. Review \`reviews.instructions\` and
\`path_instructions\` — consider stricter exclusions.

EOF
else
  echo "✅ Challenge rate is healthy (5-25%)."
  echo ""
fi

# Acceptance rate (proxy): criterio del paso C del plan v5.
# Umbral: si ≤ 35% → considerar bajar profile a chill.
if awk -v r="$ACCEPTANCE_RATE" 'BEGIN { exit !(r <= 35) }'; then
  cat <<EOF
⚠️ **Low acceptance rate (${ACCEPTANCE_RATE}%, proxy)**. Comentarios resueltos
sin disagreement están por debajo del umbral del paso C (35%). Considerar
bajar \`profile\` a \`chill\` en \`.coderabbit.yaml\` para reducir fricción,
o revisar si los comentarios de CR están aportando señal accionable.
Recordar: este rate es un proxy (resolved && !challenged); no verifica
commits posteriores que toquen el archivo/línea comentada.
EOF
else
  echo "✅ Acceptance rate is healthy (> 35%, proxy)."
  echo ""
fi
