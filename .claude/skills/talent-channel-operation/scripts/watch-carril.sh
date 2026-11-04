#!/usr/bin/env bash
# watch-carril.sh — Espera diálogos visibles o resultados del turno actual del desarrollador.
# stop-audit, pr y merge: transcript de sesión viva; respaldo estable con historial.
# Estados: plan-listo | pregunta | stop-audit | permiso | pr | merge.
# rc 0: estado detectado; rc 3: agente en reposo sin estado (ambos imprimen recorte);
# rc 1: tiempo agotado; rc 2: configuración inválida.
# Uso: watch-carril.sh <carril> <estado> [intervalo] [max_iter] [reposo_sondeos]
# Reposo vivo: transcripción estable entre dos capturas (TCO_IDLE_STABILITY_GAP, default 2s).
# TCO_WAIT_IDLE_POLLS (default 3) comparaciones de pantalla idéntica entre sondeos;
# ocupado/desconocido/cambio de pantalla reinician cuenta (cuatro capturas para tres comparaciones).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"
tco_watch_pattern() { # estado -> regex del monitor
  local pat
  case "$1" in
    plan-listo) pat='ready to execute|Would you like to proceed|keep planning';;
    # 'pregunta' = el dev abrió un menú AskUserQuestion (NO debe colgar el pipeline → escalar/responder)
    pregunta)   pat='Enter to select|Type something|Chat about this';;
    stop-audit) tco_stop_audit_pattern; return ;;
    permiso)    pat='Do you want to proceed\?|Tab to amend';;
    pr)         pat='github.com/[^ ]+/pull/[0-9]+';;
    merge)      pat='Merged|pull request.*merged|→ Done';;
    *) tco_err "estado desconocido: $1"; return 1;;
  esac
  printf '%s\n' "$pat"
}
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  # 10s = cadencia de monitorización no negociable (lead 2026-06-28)
  CARRIL="${1:?carril}"; STATE="${2:?estado}"; IV="${3:-10}"; MX="${4:-360}"
  pat="$(tco_watch_pattern "$STATE")" || exit 1
  tco_wait_state "$CARRIL" "$(tco_pane_dev)" "$pat" "$IV" "$MX" "${5:-${TCO_WAIT_IDLE_POLLS:-3}}" "$STATE"
fi
