#!/usr/bin/env bash
# torre-sweep.sh — Cosecha READ-ONLY de los panes torre-* (Torre de Control, TAL-2278).
# Uso: torre-sweep.sh [actor…] [--ansi] [--scrollback N]
#   Sin actores: barre TODAS las sesiones torre-* vivas. --ansi captura con -e (escape codes:
#   la via doctrinal para inspeccionar ghost-text ANTES de reaccionar — ref 09).
# Por actor imprime la captura enmarcada + linea de RESUMEN: busy|idle · ctx% (o UNKNOWN
# fail-closed) · flags queued-msgs / usage-limit / menu-abierto / input:(ghost|text).
# 100% solo lectura (capture-pane). La cadencia es de los wakeups del Orquestador (la Fase 3
# watchdog externa NO existe aun — runbook torre-de-control §Arquitectura).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"; . "$HERE/lib.sh"; . "$HERE/lib-torre.sh"
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  ANSI=0; SB=""; ACTORS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --ansi) ANSI=1; shift ;;
      --scrollback) SB="${2:?--scrollback N}"; printf '%s' "$SB" | grep -qE '^[0-9]+$' || torc_die "--scrollback debe ser numerico"; shift 2 ;;
      -*) torc_die "flag desconocido: $1 (uso: torre-sweep.sh [actor…] [--ansi] [--scrollback N])" ;;
      *) ACTORS+=("$1"); shift ;;
    esac
  done
  command -v tmux >/dev/null 2>&1 || torc_die "tmux no esta instalado en el host (prerequisito Torre — talent-channels gotcha 27)"

  # Resolver sesiones: explicitas (deben existir; fail-closed listando las vivas) o descubiertas.
  SESSIONS=()
  if [ ${#ACTORS[@]} -gt 0 ]; then
    for a in "${ACTORS[@]}"; do
      s="$(torc_torre_session "$a")" || torc_die "actor invalido: '$a' (minusculas/digitos/guiones)"
      torc_torre_has_session "$s" || torc_die "sesion '$s' no existe — vivas: $(torc_torre_sessions | paste -sd' ' - 2>/dev/null || echo ninguna)"
      SESSIONS+=("$s")
    done
  else
    while IFS= read -r s; do [ -n "$s" ] && SESSIONS+=("$s"); done < <(torc_torre_sessions)
    [ ${#SESSIONS[@]} -gt 0 ] || { torc_info "sin sesiones ${TORRE_SESSION_PREFIX}* vivas"; exit 0; }
  fi

  for s in "${SESSIONS[@]}"; do
    torc_say "$s"
    cap="$(torc_torre_cap "$s" "$SB" "$ANSI")" || { torc_err "$s: captura fallida"; continue; }
    printf '%s\n' "$cap"
    # resumen desde capturas dedicadas: plana (busy/ctx/queued/usage) + -e (clasificar el input)
    plain="$(torc_torre_cap "$s")" || plain=""
    raw="$(torc_torre_cap "$s" "" 1)" || raw=""
    busy=idle; printf '%s\n' "$plain" | grep -v '^$' | tail -8 | torc_torre_busy_from && busy=busy
    if ctx="$(printf '%s\n' "$plain" | torc_torre_ctx_pct)"; then ctx="${ctx}%"; else ctx=UNKNOWN; fi
    flags=""
    printf '%s\n' "$plain" | grep -qi 'press up to edit queued messages' && flags="$flags queued-msgs"
    printf '%s\n' "$plain" | torc_torre_usage_warn && flags="$flags usage-limit"
    printf '%s\n' "$plain" | torc_torre_menu_open && flags="$flags menu-abierto"
    st="$(printf '%s\n' "$raw" | torc_torre_input_state)"
    case "$st" in ghost|text) flags="$flags input:$st" ;; esac
    torc_info "resumen: $busy · ctx: $ctx · flags:${flags:- ninguno}"
  done
fi
