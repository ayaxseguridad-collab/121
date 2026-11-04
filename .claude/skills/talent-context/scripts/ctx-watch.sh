#!/usr/bin/env bash
# ctx-watch.sh — Un tick READ-ONLY del ctx-watcher (talent-context, ref 04).
#
# Vigila el ctx% del PROPIO pane y reporta si cruza el umbral. NO compacta: solo avisa; el relevo lo
# ejecuta la sesión en su checkpoint limpio (ref 02). Encadenar a un wakeup/cron ~300s es del operador
# (en flota, del nivel superior). Repo-agnóstico, token-only, sin MCP.
#
# Uso:
#   ctx-watch.sh --pane <target> [--threshold N]   # captura el pane con tmux (target OBLIGATORIO
#                                                   # con '=', ej. '=sesion:' — fija la sesión EXACTA)
#   ctx-watch.sh --stdin [--threshold N]           # lee la captura de stdin (para tests / sin tmux)
#   ctx-watch.sh --help
#
# Salida (stdout = resumen legible; stderr = logs). rc EXACTOS:
#   0 = ctx < umbral (OK) · 2 = ctx >= umbral (COMPACT-60 REQUERIDO) · 3 = ctx UNKNOWN (fail-closed).
# Umbral por defecto: 60 (protocolo compact-60 del lead). '=nombre:' fija la sesión EXACTA (sin '='
# tmux puede matchear otra sesión — gotcha 2 de ref 04).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

tc_watch_usage() {
  sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Evalúa una captura (ya en una variable) contra el umbral e imprime el resumen. Devuelve 0/2/3.
tc_watch_eval() { # threshold capture
  local thr="$1" cap="$2" pct rc flags="" st
  pct="$(printf '%s\n' "$cap" | tc_ctx_over "$thr")"; rc=$?
  # flags de input desde la MISMA captura (útil solo si venía con -e; inofensivo si no)
  st="$(printf '%s\n' "$cap" | tc_input_state 2>/dev/null || echo empty)"
  case "$st" in queued|ghost|text) flags=" · input:$st" ;; esac
  case "$rc" in
    0) printf 'OK · ctx: %s%% < %s%%%s\n' "$pct" "$thr" "$flags" ;;
    2) printf 'COMPACT-60 REQUERIDO · ctx: %s%% >= %s%%%s\n' "$pct" "$thr" "$flags"
       tc_info "compacta en el próximo checkpoint limpio: escribe el regreso FUERA, luego /compact (ref 02)" ;;
    3) printf 'UNKNOWN · barra sin "ctx:" — fail-closed: inspección manual%s\n' "$flags" ;;
  esac
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  PANE=""; THRESH=60; SRC=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pane)
        [ -z "$SRC" ] || { tc_err "--pane y --stdin son mutuamente excluyentes"; exit 3; }
        [ $# -ge 2 ] || { tc_err "--pane requiere <target>"; exit 3; }
        PANE="$2"
        case "$PANE" in
          =*) ;;
          *) tc_err "--pane target inválido: debe empezar con '=' para fijar la sesión EXACTA (sin '=' tmux puede matchear otra sesión — gotcha 2 de ref 04; recibido: '$PANE')"; exit 3 ;;
        esac
        SRC="tmux"; shift 2 ;;
      --stdin)
        [ -z "$SRC" ] || { tc_err "--pane y --stdin son mutuamente excluyentes"; exit 3; }
        SRC="stdin"; shift ;;
      --threshold)
        [ $# -ge 2 ] || { tc_err "--threshold requiere N"; exit 3; }
        THRESH="$2"
        printf '%s' "$THRESH" | grep -qE '^[0-9]+$' || { tc_err "--threshold debe ser numérico"; exit 3; }
        [ "$THRESH" -ge 0 ] && [ "$THRESH" -le 100 ] || { tc_err "--threshold debe estar en el rango 0-100 (recibido: $THRESH)"; exit 3; }
        shift 2 ;;
      -h|--help) tc_watch_usage; exit 0 ;;
      *) tc_err "flag desconocido: $1 (uso: --pane <target> | --stdin [--threshold N])"; exit 3 ;;
    esac
  done

  case "$SRC" in
    stdin)
      CAP="$(cat)"
      ;;
    tmux)
      command -v tmux >/dev/null 2>&1 || { tc_err "tmux no está instalado (sin tmux: ver ref 04 §sin-tmux)"; exit 3; }
      # -J reúne soft-wraps; -e conserva ANSI (permite clasificar ghost vs cola real). '=' = exacto.
      CAP="$(tmux capture-pane -t "$PANE" -p -J -e 2>/dev/null)" || { tc_err "captura fallida del pane '$PANE' — fail-closed"; exit 3; }
      [ -n "$CAP" ] || { tc_err "captura vacía del pane '$PANE' — fail-closed"; exit 3; }
      ;;
    *)
      tc_err "falta origen: --pane <target> o --stdin"; tc_watch_usage; exit 3 ;;
  esac

  tc_watch_eval "$THRESH" "$CAP"
  exit $?
fi
