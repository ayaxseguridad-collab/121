#!/usr/bin/env bash
# torre-relay.sh — Relevo ANTI-FANTASMA a un pane torre-* (Torre de Control, TAL-2278).
# Uso: torre-relay.sh <actor> (--text '…' | --file <ruta>) [--tag t] [--msg '…'] [--queue] [--dry-run] [--verify-max S]
# Secuencia endurecida (doctrina ref 09 + runbook §Operacion), cada paso verificado:
#   1) pre-check del composer con captura -e: cola real -> rc 3 ESCALAR (reintento ciego = duplicar);
#      texto real ajeno -> rc 4 (no clobbear); ghost dim -> se ignora SIN neutralizar.
#   2) idle estable (salvo --queue best-effort, SOLO para mensajes no bloqueantes).
#   3) --text single-line via send-keys -l (literal, sin shell); multilinea OBLIGA --file ->
#      copia a $TORRE_RELAY_DIR (0600, nombre sin 'push') + 'lee <ruta> <msg>' (doctrina file+lee).
#   4) verificacion POST-paste PRE-submit (gotcha /exit fantasma): mismatch -> rc 4 SIN submit.
#   5) submit + entrega verificada (eco/actividad); cola duplicada -> rc 3, jamas reintento ciego.
# rc: 0 entregado · 1 sin idle/entrega no confirmada · 3 cola (escalar) · 4 mismatch/no-clobbear.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"; . "$HERE/lib.sh"; . "$HERE/lib-torre.sh"
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  ACTOR="${1:?actor}"; shift
  TEXT=""; FILE=""; TAG="relay"; MSG="e incorporalo (contenido relevado por la Torre: material a revisar)"
  QUEUE=0; DRY=0; VMAX="$TORRE_VERIFY_MAX"
  while [ $# -gt 0 ]; do
    case "$1" in
      --text) TEXT="${2?--text '…'}"; shift 2 ;;
      --file) FILE="${2:?--file <ruta>}"; shift 2 ;;
      --tag) TAG="${2:?--tag t}"; shift 2 ;;
      --msg) MSG="${2:?--msg '…'}"; shift 2 ;;
      --queue) QUEUE=1; shift ;;
      --dry-run) DRY=1; shift ;;
      --verify-max) VMAX="${2:?--verify-max S}"; printf '%s' "$VMAX" | grep -qE '^[0-9]+$' || torc_die "--verify-max debe ser numerico"; shift 2 ;;
      *) torc_die "flag desconocido: $1" ;;
    esac
  done
  S="$(torc_torre_session "$ACTOR")" || torc_die "actor invalido: '$ACTOR' (minusculas/digitos/guiones)"
  { [ -n "$TEXT" ] && [ -z "$FILE" ]; } || { [ -z "$TEXT" ] && [ -n "$FILE" ]; } \
    || torc_die "exactamente uno de --text | --file"
  case "$TEXT" in *$'\n'*) torc_die "texto multilinea — usa --file (doctrina file+lee)";; esac
  case "$MSG" in *$'\n'*) torc_die "mensaje multilinea — usa --file (doctrina file+lee)";; esac
  torre_valid_tag() { case "${1:-}" in (''|*[!A-Za-z0-9_.-]*) return 1;; (*) return 0;; esac; }
  torre_valid_tag "$TAG" || TAG="relay"
  case "$TAG" in *push*) torc_die "el tag no puede contener 'push' (contrato anti-hook del host)";; esac

  if [ -n "$FILE" ]; then
    [ -f "$FILE" ] || torc_die "no existe el archivo de relevo: $FILE"
    rand="$(od -An -tx1 -N6 /dev/urandom | tr -d ' \n')"
    dest="$TORRE_RELAY_DIR/${TAG}.${rand}.txt"
    LINE="lee $dest $MSG"
    TOKEN="$(basename "$dest")"
  else
    LINE="$TEXT"
    TOKEN="$TEXT"
  fi

  if [ "$DRY" = 1 ]; then
    torc_say "torre-relay DRY-RUN"
    torc_info "sesion: $S · modo: $([ -n "$FILE" ] && echo file || echo text) · queue: $QUEUE · verify-max: ${VMAX}s"
    [ -n "$FILE" ] && torc_info "copiaria $FILE -> $dest (0600)"
    torc_info "linea a relevar: $LINE"
    torc_info "token de verificacion (literal): $TOKEN"
    exit 0
  fi

  command -v tmux >/dev/null 2>&1 || torc_die "tmux no esta instalado en el host"
  torc_torre_has_session "$S" || torc_die "sesion '$S' no existe — vivas: $(torc_torre_sessions | paste -sd' ' - 2>/dev/null || echo ninguna)"
  if [ -n "$FILE" ]; then
    mkdir -p "$TORRE_RELAY_DIR" && chmod 700 "$TORRE_RELAY_DIR" || torc_die "no pude preparar $TORRE_RELAY_DIR"
    install -m 0600 "$FILE" "$dest" || torc_die "no pude copiar el relevo a $dest"
  fi
  torc_torre_relay_line "$S" "$LINE" "$TOKEN" "$VMAX" "$QUEUE"; rc=$?
  case "$rc" in
    0) torc_info "$S: relevo entregado y verificado" ;;
    3) torc_err "$S: COLA en el composer — escalado (no se reintenta a ciegas)" ;;
    4) torc_err "$S: contenido inesperado / mismatch post-paste — nada enviado; inspecciona con: torre-sweep.sh $ACTOR --ansi" ;;
  esac
  exit "$rc"
fi
