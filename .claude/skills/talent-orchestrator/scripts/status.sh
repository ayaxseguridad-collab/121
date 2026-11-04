#!/usr/bin/env bash
# status.sh — Foto read-only del Orquestador: ordenes de coordinacion (estado + #issues)
# y la issue-registro de la flota. No escribe nada.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"; . "$HERE/lib.sh"; . "$HERE/registry.sh"

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  torc_load_tokens
  torc_say "Setup (capa Coordinacion)"
  for v in TORC_COORD_PROJECT_ID TORC_REGISTRY_ISSUE_ID TORC_STATE_TODO TORC_STATE_NEEDS_INPUT \
           TORC_LABEL_AGENT_INSTR TORC_LABEL_VERTICAL TORC_LABEL_ACTOR_AI; do
    [ -n "${!v:-}" ] && printf '   %-26s OK\n' "$v" || printf '   %-26s (pendiente setup gated)\n' "$v"
  done

  if [ -n "${TORC_COORD_PROJECT_ID:-}" ]; then
    torc_say "Ordenes de trabajo (no cerradas)"
    Q='query($pid:ID!,$lbl:ID!){issues(first:200,filter:{project:{id:{eq:$pid}},labels:{some:{id:{eq:$lbl}}},state:{type:{nin:["completed","canceled"]}}},orderBy:updatedAt){nodes{identifier title state{name} description}}}'
    TK="$(torc_linear_team_key)" || exit 1   # [TAL-8037] la clave del team es de la instancia (fail-closed)
    linear_api "$Q" "$(jq -n --arg pid "$TORC_COORD_PROJECT_ID" --arg lbl "${TORC_LABEL_AGENT_INSTR:-}" '{pid:$pid,lbl:$lbl}')" \
      | jq -r --arg k "$TK" '.data.issues.nodes[]? | "  [\(.state.name)] \(.identifier) — \(.title) (issues: \((.description//"")|[scan($k + "-[0-9]+")]|unique|length))"' \
      2>/dev/null || torc_info "(no se pudieron leer las ordenes)"
  fi

  if [ -n "${TORC_REGISTRY_ISSUE_ID:-}" ]; then
    torc_say "Registro de flota"
    printf 'channel_id\tcontainer\tmachine\thwclass\trole\tcoordinador\trepo\n'
    torc_registry_print "" 2>/dev/null || torc_info "(no se pudo leer la issue-registro)"
  fi
fi
