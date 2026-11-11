#!/usr/bin/env bash
# status.sh — Foto de los carriles: contenedor, fase/actividad, escalados pendientes, cola, locks.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"; . "$HERE/lib.sh"
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  tco_say "Carriles de desarrollo"
  for nn in $TCO_DEV_CARRILES; do
    c="$(tco_container "$nn")"
    st="$(incus list -f csv -c s "^$c\$" 2>/dev/null | head -1)"
    act="$(tco_cap_pane "$nn" "$(tco_pane_dev)" 2>/dev/null | grep -v '^$' | tail -1 | tr -s ' ' | cut -c1-60)"
    # Columna behavior (SANO | UNKNOWN | PROGRESO-ESTANCADO); SOLO avisa y no cambia el rc del censo.
    beh=''
    if [ "${TCO_BEHAVIOR_WATCH:-1}" != 0 ]; then
      beh="$(bash "$HERE/behavior-watch.sh" "$nn" 2>/dev/null || true)"; beh="${beh#behavior: }"; beh="${beh%% ·*}"
    fi
    printf '  %s [%s] dev: %s%s\n' "$c" "${st:-?}" "${act:-(sin sesión)}" "${beh:+ · behavior: $beh}"
  done
  tco_say "Carriles de auditoría (solo reportan)"
  for nn in $TCO_AUDIT_CARRILES; do
    c="$(tco_container "$nn")"; st="$(incus list -f csv -c s "^$c\$" 2>/dev/null | head -1)"
    printf '  %s [%s]\n' "$c" "${st:-?}"
  done
  tco_say "Locks activos"; ls "$TCO_LOCK_DIR" 2>/dev/null | sed 's/^/  /' || echo "  (ninguno)"
  # [m4] Corridas con MOTIVO inline (lee state.json por issue): visibilidad de escalados sin grep manual.
  tco_say "Corridas"
  runs_found=no
  for d in "$TCO_RUNS_DIR"/*/; do
    [ -d "$d" ] || continue; runs_found=yes
    sj="$d/state.json"
    jq -s -e 'length == 1 and (.[0] | type == "object")' "$sj" >/dev/null 2>&1 || { tco_err "$sj: estado JSON inválido"; exit 1; }
    ph="$(jq -r '.phase // "?"' "$sj" 2>/dev/null || echo '?')"
    rs="$(jq -r '.reason // ""' "$sj" 2>/dev/null || echo '')"
    pr="$(jq -r '.pr // ""' "$sj" 2>/dev/null || echo '')"
    printf '  %s — fase:%s%s%s\n' "$(basename "$d")" "$ph" "${pr:+ PR#$pr}" "${rs:+ · motivo:$rs}"
  done
  [ "$runs_found" = yes ] || echo "  (ninguna)"
  tco_info "merge=humano  migration-policy=$TCO_MIGRATION_POLICY  max-active=$TCO_MAX_ACTIVE"
fi
