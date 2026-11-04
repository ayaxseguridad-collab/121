#!/usr/bin/env bash
# registry.sh — Lee la issue-registro de la flota (fuente de verdad de canales) y la imprime.
# [MAYOR no-bloqueante 1] Normaliza canal: expone channel_id (01) Y container (vibe-channel-01).
# CERO secretos: el registro solo mapea canal->coordinador; las creds viven en el escrow del canal.
# Uso: registry.sh [--coordinador coord-X] [--issue <uuid>]
# Salida TSV: channel_id  container  machine  hwclass  role  coordinador  repo
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"; . "$HERE/lib.sh"

# Imprime las filas (TSV con channel_id+container) del registro; uso por orchestrate.sh/CLI.
torc_registry_print() { # [coord_filter]
  local coordf="${1:-}" issue="${TORC_REGISTRY_ISSUE_ID:-}" body
  [ -n "$issue" ] || { torc_err "TORC_REGISTRY_ISSUE_ID no configurado (setup gated)"; return 1; }
  torc_is_uuid "$issue" || torc_is_tal "$issue" || { torc_err "registry issue id invalido"; return 1; }
  local Q='query($id:String!){issue(id:$id){description}}'
  body="$(linear_api "$Q" "$(jq -n --arg id "$issue" '{id:$id}')" | jq -r '.data.issue.description // empty')"
  [ -n "$body" ] || { torc_err "issue-registro sin cuerpo o no encontrada"; return 1; }
  printf '%s' "$body" | torc_registry_rows | while IFS=$'\t' read -r ch machine hw role coord repo; do
    [ -n "$coordf" ] && [ "$coord" != "$coordf" ] && continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(torc_to_channel_id "$ch")" "$(torc_to_container "$ch")" "$machine" "$hw" "$role" "$coord" "$repo"
  done
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  COORD=""; while [ $# -gt 0 ]; do case "$1" in
    --coordinador) COORD="$2"; shift 2;;
    --issue) export TORC_REGISTRY_ISSUE_ID="$2"; shift 2;;
    *) torc_die "flag desconocido: $1";;
  esac; done
  [ -n "$COORD" ] && { torc_is_coord "$COORD" || torc_die "--coordinador invalido"; }
  torc_load_tokens
  printf 'channel_id\tcontainer\tmachine\thwclass\trole\tcoordinador\trepo\n'
  torc_registry_print "$COORD"
fi
