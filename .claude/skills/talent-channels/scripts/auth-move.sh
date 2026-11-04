#!/usr/bin/env bash
# auth-move.sh — CLI del MOVE transaccional de credenciales (TAL-2294).
# Mueve un login (Codex por defecto) de UN endpoint a otro sin dejar copias vivas,
# con freeze durable, journal de crash-recovery, commit por mv atómico y guard de
# coordinador único. Ver auth-move-lib.sh (cabecera) para el contrato completo.
#
# Uso:
#   auth-move.sh move  <cuenta> <from-endpoint> <to-endpoint> [--agent codex|claude]
#   auth-move.sh repair <tx_id>          # reconcilia/repara una transacción interrumpida
#   auth-move.sh resume <tx_id>          # alias de repair (reanuda hacia DONE)
#   auth-move.sh status [tx_id]          # lista journals (o detalla uno)
#
# Endpoints TIPADOS:  host:<hostname>  channel:<container>  pool:<pozo-id>
#   (pool:<id> = el contenedor cuyo nombre es <id>; los pozos son contenedores con login pre-cargado)
#
# Requisitos: correr en la ESTACIÓN COORDINADORA (coordinator_host del ledger) con
#   AM_LEDGER=<path a ledger/cuentas.json> exportado (fail-closed si falta o no escribible).
#   El ledger vive en el repo motor talent-factory.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"
# shellcheck source=/dev/null
. "$HERE/auth-move-lib.sh"

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

cmd="${1:-}"; shift || true
case "$cmd" in
  move)
    cuenta="${1:?falta <cuenta>}"; from="${2:?falta <from-endpoint>}"; to="${3:?falta <to-endpoint>}"; shift 3 || true
    agent=codex
    while [ $# -gt 0 ]; do
      case "$1" in
        --agent) agent="${2:?}"; shift 2 ;;
        --agent=*) agent="${1#*=}"; shift ;;
        *) tc_die "flag desconocido: $1" ;;
      esac
    done
    # TAL-8042 (FAB-OBS-002): SIGPIPE ignorado (un lector que se va NO mata el MOVE a mitad ni tras DONE) y
    # rc FINAL por FASE del journal (am_move_final_rc), no el rc crudo de la función. El protocolo corre en
    # un subshell con `set -e` PROPIO (como antes: una sentencia fallida lo aborta) y SIN `||` alrededor
    # (un `||` desactivaría errexit dentro y relajaría el fail-closed). `am_die` sale del subshell, no del CLI.
    trap '' PIPE
    mv_inicio="$(date -u +%Y%m%dT%H%M%SZ)"
    set +e
    ( set -e; am_move "$cuenta" "$agent" "$from" "$to" )
    mv_rc=$?
    am_move_final_rc "$mv_rc" "$$" "$mv_inicio"
    mv_final=$?
    set -e
    if [ "$mv_final" -ne "$mv_rc" ]; then
      printf 'am: rc del MOVE normalizado por la fase del journal: %s -> %s\n' "$mv_rc" "$mv_final" >&2 || true
    fi
    exit "$mv_final"
    ;;
  repair|resume)
    tx="${1:?falta <tx_id>}"
    trap '' PIPE   # TAL-8042: un lector que se va no debe matar la reparación a mitad
    am_resume "$tx"
    ;;
  status)
    if [ -n "${1:-}" ]; then
      jp="$(am_journal_path "$1")"
      [ -f "$jp" ] || tc_die "no hay journal para '$1'"
      cat "$jp"
    else
      d="$(am_journal_dir)"; [ -d "$d" ] || { echo "(sin transacciones)"; exit 0; }
      shopt -s nullglob
      found=0
      for j in "$d"/*.json; do
        found=1
        tx="$(basename "$j" .json)"
        fase="$(am_journal_field "$tx" fase)"; cta="$(am_journal_field "$tx" cuenta)"
        frm="$(am_journal_field "$tx" donante)"; to="$(am_journal_field "$tx" destino)"
        printf '%-40s %-16s %s  %s→%s\n' "$tx" "$fase" "$cta" "$frm" "$to"
      done
      [ "$found" -eq 1 ] || echo "(sin transacciones)"
    fi
    ;;
  ''|-h|--help|help) usage 0 ;;
  *) tc_die "subcomando desconocido: $cmd (move|repair|resume|status)";;
esac
