#!/usr/bin/env bash
# torre-compact.sh — Protocolo COMPACT-60 del lead sobre un pane torre-* (TAL-2278).
# Uso: torre-compact.sh check [actor…]
#      torre-compact.sh run <actor> [--threshold N] [--dry-run]
# check: ctx% de cada pane; >= umbral -> "COMPACT-60 REQUERIDO"; sin ctx legible -> UNKNOWN
#   (fail-closed: pide inspeccion manual, jamas asume OK).
#   rc: 0 = nadie requiere · 2 = >=1 requiere compact · 3 = >=1 UNKNOWN (y nadie requiere).
# run: los 4 pasos del protocolo (SKILL §Protocolos del lead + runbook §Operacion) con NONCE
#   unico por ejecucion — invariante: jamas /compact sin handoff YA guardado fuera, y jamas
#   un handoff STALE (extraccion solo del ULTIMO bloque con nonce exacto):
#   (1) relay pidiendo el handoff de regreso entre 'HANDOFF-INICIO <nonce>'/'HANDOFF-FIN <nonce>',
#       ESCRITO con Write en $TORRE_HANDOFF_DIR/<actor>.<ts>.pending.md (TAL-8039: el viewport del
#       TUI en pantalla alternada pierde los handoffs largos; el fichero no)
#   (2) recogida: FICHERO verificado (nonce + mtime >= peticion + bloque completo) primero, pantalla
#       de respaldo, prorroga con tope mientras el turno siga vivo -> $TORRE_HANDOFF_DIR/<actor>.<ts>.md
#       (copia FUERA). Sin handoff verificado: "ABORTO ANTES de /compact", rc != 0.
#   (3) /compact + espera de fin (idle estable)
#   (4) re-relay del handoff (file+lee) para retomar exactamente desde ese estado.
#   Cualquier paso fallido aborta con estado claro y el handoff conservado.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"; . "$HERE/lib.sh"; . "$HERE/lib-torre.sh"
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  CMD="${1:?check|run}"; shift
  case "$CMD" in
    check)
      command -v tmux >/dev/null 2>&1 || torc_die "tmux no esta instalado en el host"
      SESSIONS=()
      if [ $# -gt 0 ]; then
        for a in "$@"; do
          s="$(torc_torre_session "$a")" || torc_die "actor invalido: '$a'"
          torc_torre_has_session "$s" || torc_die "sesion '$s' no existe"
          SESSIONS+=("$s")
        done
      else
        while IFS= read -r s; do [ -n "$s" ] && SESSIONS+=("$s"); done < <(torc_torre_sessions)
        [ ${#SESSIONS[@]} -gt 0 ] || { torc_info "sin sesiones ${TORRE_SESSION_PREFIX}* vivas"; exit 0; }
      fi
      required=0; unknown=0
      for s in "${SESSIONS[@]}"; do
        plain="$(torc_torre_cap "$s")" || { torc_err "$s: captura fallida"; unknown=1; continue; }
        if ctx="$(printf '%s\n' "$plain" | torc_torre_ctx_pct)"; then
          if [ "$ctx" -ge "$TORRE_CTX_THRESHOLD" ]; then
            torc_info "$s: ctx ${ctx}% >= ${TORRE_CTX_THRESHOLD}% -> COMPACT-60 REQUERIDO (torre-compact.sh run ${s#"$TORRE_SESSION_PREFIX"})"
            required=1
          else
            torc_info "$s: ctx ${ctx}% < ${TORRE_CTX_THRESHOLD}% -> OK"
          fi
        else
          torc_info "$s: ctx UNKNOWN (barra sin 'ctx:') — fail-closed: inspeccion manual (torre-sweep.sh)"
          unknown=1
        fi
      done
      [ "$required" = 1 ] && exit 2
      [ "$unknown" = 1 ] && exit 3
      exit 0
      ;;
    run)
      ACTOR="${1:?actor}"; shift
      THRESH="$TORRE_CTX_THRESHOLD"; DRY=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --threshold) THRESH="${2:?--threshold N}"; printf '%s' "$THRESH" | grep -qE '^[0-9]+$' || torc_die "--threshold debe ser numerico"; shift 2 ;;
          --dry-run) DRY=1; shift ;;
          *) torc_die "flag desconocido: $1" ;;
        esac
      done
      S="$(torc_torre_session "$ACTOR")" || torc_die "actor invalido: '$ACTOR'"
      NONCE="$(torc_torre_new_nonce)"
      TS="$(date -u +%Y%m%dT%H%M%SZ)"
      OUT="$TORRE_HANDOFF_DIR/${S#"$TORRE_SESSION_PREFIX"}.${TS}.md"
      PENDING="$TORRE_HANDOFF_DIR/${S#"$TORRE_SESSION_PREFIX"}.${TS}.pending.md"
      REQ="Handoff de regreso (compact-60, nonce $NONCE): escribe AHORA con la herramienta Write el fichero $PENDING con tu handoff completo entre dos lineas exactas y solas 'HANDOFF-INICIO $NONCE' y 'HANDOFF-FIN $NONCE', con: estado exacto, trabajo en vuelo, proximos pasos, IDs/refs (Linear, PR, rama, sha). Si no puedes escribir el fichero, emite el mismo bloque en tu respuesta. Despues NO hagas nada mas y quedate en espera."

      if [ "$DRY" = 1 ]; then
        torc_say "torre-compact DRY-RUN ($S)"
        torc_info "nonce de esta ejecucion: $NONCE"
        torc_info "marcadores: 'HANDOFF-INICIO $NONCE' … 'HANDOFF-FIN $NONCE' (extraccion: ULTIMO bloque con nonce exacto; stale jamas matchea)"
        torc_info "el actor escribiria el handoff en: $PENDING (fichero primero; pantalla de respaldo; prorroga con tope ${TORRE_HANDOFF_HARD_MAX}s mientras el turno viva)"
        torc_info "handoff se guardaria en: $OUT"
        torc_info "paso 1 (peticion): $REQ"
        torc_info "paso 3: /compact tras guardar el handoff FUERA; paso 4: re-relay 'lee $OUT …'"
        exit 0
      fi

      command -v tmux >/dev/null 2>&1 || torc_die "tmux no esta instalado en el host"
      torc_torre_has_session "$S" || torc_die "sesion '$S' no existe — vivas: $(torc_torre_sessions | paste -sd' ' - 2>/dev/null || echo ninguna)"
      # umbral: solo aviso (run explicito es decision del operador; check es quien gatea)
      if ctx="$(torc_torre_cap "$S" | torc_torre_ctx_pct)"; then
        [ "$ctx" -lt "$THRESH" ] && torc_info "$S: ctx ${ctx}% < ${THRESH}% — run explicito del operador, continuo"
      else
        torc_info "$S: ctx UNKNOWN — run explicito del operador, continuo"
      fi

      # (1) pedir el handoff (relay anti-fantasma; token = nonce, el eco de la peticion lo contiene).
      # El dir 0700 se crea ANTES: el actor escribe ahi y jamas /compact sin handoff guardado fuera.
      [ ! -L "$TORRE_HANDOFF_DIR" ] || torc_die "$TORRE_HANDOFF_DIR es un enlace simbolico — NO lo sigo (chmod/escritura caerian fuera) — NADA compactado"
      mkdir -p "$TORRE_HANDOFF_DIR" && chmod 700 "$TORRE_HANDOFF_DIR" && [ -d "$TORRE_HANDOFF_DIR" ] && [ -O "$TORRE_HANDOFF_DIR" ] && [ -w "$TORRE_HANDOFF_DIR" ] \
        || torc_die "no pude preparar $TORRE_HANDOFF_DIR (propio, 0700, escribible) — NADA compactado"
      SINCE="$(torc_torre_now)"   # un fichero con mtime anterior a esta peticion es de OTRA ejecucion
      torc_say "compact-60 $S — paso 1/4: peticion de handoff (nonce $NONCE)"
      torc_torre_relay_line "$S" "$REQ" "$NONCE" || torc_die "no pude entregar la peticion de handoff — NADA compactado"

      # (2) recoger el handoff y copiarlo FUERA (fichero verificado primero; pantalla de respaldo;
      # prorroga con tope mientras el turno viva; anti-stale por nonce; jamas /compact sin esto)
      torc_say "compact-60 $S — paso 2/4: esperando handoff ($TORRE_HANDOFF_MAX s base, tope $TORRE_HANDOFF_HARD_MAX s si el turno sigue vivo)"
      hf=""
      hf="$(torc_torre_collect_handoff "$S" "$NONCE" "$PENDING" "$SINCE")" || hf=""
      [ -n "$hf" ] || torc_die "sin handoff verificado con nonce $NONCE (ni fichero $PENDING ni pantalla; ausente, antiguo, incompleto o turno parado) — ABORTO ANTES de /compact"
      if [ -f "$PENDING" ]; then chmod 600 "$PENDING" 2>/dev/null || true; fi
      ( umask 177; printf '%s\n' "$hf" > "$OUT" ) || torc_die "no pude guardar el handoff en $OUT — ABORTO ANTES de /compact"
      torc_info "handoff guardado FUERA de la sesion: $OUT ($(wc -l < "$OUT") lineas)"

      # (3) /compact y esperar el fin
      torc_say "compact-60 $S — paso 3/4: /compact"
      torc_torre_relay_line "$S" "/compact" "/compact" \
        || torc_die "no pude enviar /compact — handoff conservado en $OUT; reintenta manualmente"
      sleep 10
      torc_torre_wait_idle "$S" "$TORRE_COMPACT_MAX" \
        || torc_die "el /compact no termino en ${TORRE_COMPACT_MAX}s — handoff conservado en $OUT; verifica el pane antes del paso 4"

      # (4) re-relay del handoff para retomar
      torc_say "compact-60 $S — paso 4/4: re-relay del handoff"
      torc_torre_relay_line "$S" "lee $OUT — handoff de regreso (compact-60): retoma EXACTAMENTE desde este estado" "$(basename "$OUT")" \
        || torc_die "no pude re-relevar el handoff — esta en $OUT; entregalo manualmente"
      torc_info "compact-60 completado en $S (handoff: $OUT)"
      ;;
    *) torc_die "subcomando invalido: $CMD (check|run)" ;;
  esac
fi
