#!/usr/bin/env bash
# select-issues.sh — Lee un milestone (o proyecto) de Linear y produce la COLA ordenada de issues
# accionables, aplicando el criterio (excluir Done/Canceled/In-Progress; P0 primero; etc.).
# Imprime una línea por issue: "<identifier>\tP<prio>\t<estado>\t<title>". El coordinador confirma.
# Uso: select-issues.sh --milestone <id> | --project <id> | --issues "TAL-.. TAL-.."
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"; . "$HERE/lib.sh"

tco_linear() { # graphql query (json string en stdin)
  : "${LINEAR_API_KEY:?falta LINEAR_API_KEY}"
  # El token NO va en argv (legible vía /proc/<pid>/cmdline): viaja por un --config temporal 0600.
  local cfg rc; cfg="$(mktemp)" || return 1; chmod 600 "$cfg"
  printf 'header = "Authorization: %s"\n' "$LINEAR_API_KEY" > "$cfg"
  curl -s --connect-timeout "${TCO_LINEAR_CONNECT_TIMEOUT:-10}" --max-time "${TCO_LINEAR_MAX_TIME:-60}" \
    -K "$cfg" -H "Content-Type: application/json" -X POST https://api.linear.app/graphql -d @-; rc=$?
  rm -f "$cfg"
  return $rc
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  tco_load_tokens
  mode="${1:?--milestone|--project|--issues}"; val="${2:?valor}"
  case "$mode" in
    --issues)
      for id in $val; do printf '%s\n' "$id"; done; exit 0;;
    --milestone) filt="projectMilestone:{id:{eq:\\\"$val\\\"}}";;
    --project)   filt="project:{id:{eq:\\\"$val\\\"}}";;
    *) tco_die "modo inválido";;
  esac
  # PAGINACIÓN: un milestone/proyecto puede tener >250 issues. Recorremos pageInfo/endCursor.
  after="null"; nodes="$(mktemp)"; : > "$nodes"; trap 'rm -f "$nodes"' EXIT
  for _ in $(seq 1 50); do
    q="{\"query\":\"query{issues(first:100,after:${after},filter:{$filt}){pageInfo{hasNextPage endCursor} nodes{identifier title priority estimate state{type name} assignee{displayName} projectMilestone{sortOrder}}}}\"}"
    resp="$(printf '%s' "$q" | tco_linear)" || true
    printf '%s' "$resp" | jq -e '.data.issues' >/dev/null 2>&1 || tco_die "fallo consultando Linear (paginación): $(printf '%s' "$resp" | tco_redact | head -c 200)"
    printf '%s' "$resp" | jq -c '.data.issues.nodes[]?' >> "$nodes"
    [ "$(printf '%s' "$resp" | jq -r '.data.issues.pageInfo.hasNextPage // false')" = true ] || break
    after="\"$(printf '%s' "$resp" | jq -r '.data.issues.pageInfo.endCursor')\""
  done
  # Prioridad Linear: 0=No priority, 1=Urgent, 2=High, 3=Medium, 4=Low. Remapeo 0->99 para que
  # Urgent (1) quede PRIMERO y "sin prioridad" al final. sortkey = campo1; prioridad real = campo2.
  jq -r '
    select(.state.type=="backlog" or .state.type=="unstarted")
    | select(.assignee==null)
    | [ (if .priority==0 then 99 else .priority end|tostring),
        (.priority|tostring),
        (.projectMilestone.sortOrder // 99999|tostring),
        .identifier, .state.name, .title ] | @tsv' "$nodes" \
    | sort -t$'\t' -k1,1n -k3,3n \
    | awk -F'\t' '{printf "%s\tP%s\t%s\t%s\n", $4, $2, $5, $6}'
fi
