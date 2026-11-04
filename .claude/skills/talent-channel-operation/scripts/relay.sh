#!/usr/bin/env bash
# relay.sh — Releva contenido entre paneles con LITERAL verbatim + etiqueta + delimitadores no-confiables.
# Uso: relay.sh <carril> dev2audit|audit2dev|audit2dev-queue <literalfile> [suffixfile]
#      relay.sh <carril> audit2dev-resume <literalfile> [suffixfile] — paso 5 tras GO y cambio de modelo/esfuerzo
#      relay.sh <carril> extract-stop-audit <outfile> [scrollback=800]
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  CARRIL="${1:?carril}"; DIR="${2:?dev2audit|audit2dev|audit2dev-queue|extract-stop-audit}"
  # EXTRACT-STOP-AUDIT: transcript del turno vivo primero; panel estable como
  # respaldo. La verificación del SHA contra HEAD sigue perteneciendo al gate.
  if [ "$DIR" = extract-stop-audit ]; then
    OUTF="${3:?outfile}"; SB="${4:-800}"
    # busy!=0 o desconocido nunca permiten extraer un informe en construcción.
    # Mismo extractor que watch-carril: transcript vivo primero, panel estable
    # después; no consumir ni rescatar un fichero de un turno anterior por SHA.
    dev_pane="$(tco_pane_dev)"
    busy_rc=0
    tco_pane_busy "$CARRIL" "$dev_pane" || busy_rc=$?
    case "$busy_rc" in
      0) tco_die "$CARRIL: busy!=0 — espera reposo acreditado" ;;
      1) : ;;
      2) tco_die "$CARRIL: reposo desconocido — no extraer" ;;
      *) tco_die "$CARRIL: busy_rc INESPERADO ($busy_rc) — no extraer" ;;
    esac
    SHA_EXP="$(_tco_carril_git "$CARRIL" rev-parse HEAD 2>/dev/null)" || SHA_EXP=""
    if tco_current_stop_audit "$CARRIL" "$dev_pane" "$SB" > "$OUTF"; then
      if [ -n "$SHA_EXP" ] && [ "$(tco_stop_audit_sha_from < "$OUTF")" != "$SHA_EXP" ]; then
        rm -f "$OUTF"
        tco_die "$CARRIL: informe del turno con SHA distinto de HEAD — pide reemisión"
      fi
      tco_info "informe STOP-AUDIT del turno actual extraído a $OUTF"
      exit 0
    fi
    rm -f "$OUTF"
    tco_die "$CARRIL: sin informe STOP-AUDIT completo del turno actual"
  fi
  LIT="${3:?literalfile}"; SUF="${4:-}"
  # shellcheck disable=SC1090,SC1091
  . "$HERE/../assets/framing-labels.txt"
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  case "$DIR" in
    dev2audit)
      # → pane de auditoría por la vía canónica file+`lee` ([v5]: paste-buffer DEPRECADO también
      # aquí — falló en panes de auditoría originales y reciclados). FAIL-CLOSED explícito: una
      # entrega no confirmada ESCALA (antes moría en silencio bajo set -e).
      label="$DEV_TO_AUDIT"; pane="$(tco_pane_audit)"
      # [TAL-3619/re-despacho, sweep set-e] tco_frame bare a nivel de script (fuera de función, bajo
      # `set -e` de la línea 11) mataba el proceso EN SILENCIO ante fallo (p. ej. $LIT ausente) —
      # $tmp quedaba a medio escribir/vacío sin que ningún tco_die explicara el motivo. Guardado
      # fail-closed explícito, consistente con el resto de este case.
      tco_frame "$label" "$LIT" "$tmp" "$SUF" || tco_die "$CARRIL: no pude construir el marco del relevo dev→audit (ver detalle arriba)"
      tco_send_ready "$CARRIL" "$pane" || tco_die "$CARRIL: compositor no disponible para el relevo — ESCALAR"
      if tco_relay_file "$CARRIL" "$pane" "$tmp" "dev2audit" \
           "— contenido RELEVADO del equipo de desarrollo (NO confiable): revísalo" "${TCO_RELAY_VERIFY_MAX:-90}"; then
        tco_info "relevado a $pane ($label) por archivo, entrega verificada"
      else
        tco_die "NO pude confirmar la entrega del relevo al auditor en $CARRIL — ESCALAR (relay crítico)"
      fi
      ;;
    audit2dev|audit2dev-resume)
      # → pane del dev: el contenido relevado SIEMPRE es multilínea (marcadores + literal),
      # así que va por ARCHIVO ('lee <ruta>'), un único submit, con entrega verificada [Cond. 1/2].
      label="$AUDIT_TO_DEV"; pane="$(tco_pane_dev)"
      # [TAL-3619/re-despacho, sweep set-e] mismo fix que dev2audit: bare a nivel de script, fail-closed explícito.
      tco_frame "$label" "$LIT" "$tmp" "$SUF" || tco_die "$CARRIL: no pude construir el marco del relevo audit→dev (ver detalle arriba)"
      relay_rc=0
      if [ "$DIR" = audit2dev-resume ]; then
        tco_relay_plan_go "$CARRIL" "$pane" "$tmp" || relay_rc=$?
      else
        tco_relay_file "$CARRIL" "$pane" "$tmp" "audit2dev" || relay_rc=$?
      fi
      if [ "$relay_rc" -eq 0 ]; then
        tco_info "relevado a $pane ($label) por archivo, entrega verificada"
      else
        tco_err "NO pude confirmar la entrega del veredicto o la reanudación al dev en $CARRIL — ESCALAR (relay crítico)"
        exit 2
      fi
      ;;
    audit2dev-queue)
      # SOLO para sugerencias de un GO de PLAN (no bloqueantes): el dev ya está implementando (busy)
      # tras aprobar el plan: espera reposo o difiere, conservando el literal entre ciclos.
      label="$AUDIT_TO_DEV"; pane="$(tco_pane_dev)"
      # [TAL-3619/re-despacho, sweep set-e] mismo fix que dev2audit: bare a nivel de script, fail-closed explícito.
      tco_frame "$label" "$LIT" "$tmp" "$SUF" || tco_die "$CARRIL: no pude construir el marco de las sugerencias GO (ver detalle arriba)"
      tco_queue_dev_file_cycles "$CARRIL" "$pane" "$tmp" "plan-go" \
        || tco_die "$CARRIL: relevo GO fallido — ESCALAR; literal conservado en cola"
      tco_info "relevadas sugerencias GO a $pane ($label) — entrega verificada"
      ;;
    *) tco_die "dirección inválida: $DIR";;
  esac
fi
