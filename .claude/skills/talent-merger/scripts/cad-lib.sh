#!/usr/bin/env bash
# cad-lib.sh — Librería de CADUCIDAD por insumos y CLI compatible con el uso histórico.
#
# CLI:      cad-lib.sh <fichero-rutas> <dir-receipts>     (gates que CADUCARÍAN si main avanza con esas rutas)
#           cad-lib.sh --help
# Librería: `. cad-lib.sh` NO ejecuta nada ni cambia set -e/-u/-f del llamante. Funciones:
#   cad_cargar                          carga el mapa de insumos del motor (scripts/lib/insumos-por-gate.sh)
#   cad_universal <fichero-rutas>       rc 0 si el avance toca un insumo universal (caducan TODOS)
#   cad_gate_caduca <gate> <fich-rutas> imprime el motivo; rc 0 caduca por insumo · 3 SIN-MAPA (caduca) ·
#                                       4 siempre re-corre (caduca) · 1 conserva
#   cad_gates_de_manifiesto <manifiesto> imprime los TF_GATE_IDS del manifiesto (rc 1 si no los declara)
#
# Un gate SIN entrada en el mapa de insumos JAMÁS se conserva: caduca («un mapa incompleto cuesta tiempo,
# nunca falsos verdes»). La semántica del mapa es la de scripts/lib/insumos-por-gate.sh; aquí solo se consume.
# Entorno: LG_INSUMOS_CONF (mapa alternativo), TF_MOTOR_PIN (motor pinado). Salida del CLI, una línea por gate:
#   <gate> CADUCA (<primera ruta>) · <gate> SIN-MAPA(caduca) · <gate> CADUCA (siempre re-corre) ·
#   UNIVERSAL: caducan TODOS (si el avance toca un insumo universal)
#
# ── rc EXACTOS del CLI ─────────────────────────────────────────────────────────────────────────
#   0 = medido (incluye «no caduca nada»)
#   2 = uso o precondición: argumentos, fichero de rutas ilegible, directorio de receipts ausente,
#       sin jq o sin mapa de insumos en el motor

EST_CAD_AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib-estacion.sh
. "$EST_CAD_AQUI/lib-estacion.sh" || { echo "cad-lib.sh: no se pudo cargar lib-estacion.sh" >&2; return 2 2>/dev/null || exit 2; }

cad_cargar() {
  local m
  m="$(est_motor)" || { echo "cad-lib.sh: sin motor con scripts/lib/insumos-por-gate.sh" >&2; return 2; }
  # shellcheck source=/dev/null
  . "$m/scripts/lib/insumos-por-gate.sh" || { echo "cad-lib.sh: no se pudo cargar el mapa de insumos" >&2; return 2; }
}

cad_universal() {
  local u
  u="$(insumos_universales)"
  [ -n "$u" ] || return 1
  grep -qE -f <(printf '%s\n' "$u") "$1"
}

cad_gate_caduca() {
  local g="$1" f="$2" inc exc m
  if siempre_recorre "$g"; then printf 'siempre-re-corre\n'; return 4; fi
  inc="$(insumos_de_gate "$g")" || { printf 'sin-mapa\n'; return 3; }
  exc="$(no_insumos_de_gate "$g")"
  m="$(grep -E -f <(printf '%s\n' "$inc") "$f" || true)"
  if [ -n "$exc" ] && [ -n "$m" ]; then
    m="$(printf '%s\n' "$m" | grep -vE -f <(printf '%s\n' "$exc") || true)"
  fi
  [ -n "$m" ] || return 1
  printf '%s\n' "${m%%$'\n'*}"
  return 0
}

cad_gates_de_manifiesto() {
  local g
  g="$(grep -o 'TF_GATE_IDS="[^"]*"' "$1" | head -n 1 | cut -d'"' -f2)"
  [ -n "${g//[[:space:]]/}" ] || return 1
  printf '%s\n' "$g"
}

cad_main() {
  local j g motivo rc
  case "${1-}" in --help | -h) est_ayuda "${BASH_SOURCE[0]}"; return 0 ;; esac
  [ $# -eq 2 ] || { echo "uso: cad-lib.sh <fichero-rutas> <dir-receipts>  (--help)" >&2; return 2; }
  [ -f "$1" ] && [ -r "$1" ] || { echo "cad-lib.sh: fichero de rutas ilegible: $1" >&2; return 2; }
  [ -d "$2" ] || { echo "cad-lib.sh: directorio de receipts ausente: $2" >&2; return 2; }
  command -v jq >/dev/null 2>&1 || { echo "cad-lib.sh: falta jq" >&2; return 2; }
  cad_cargar || return 2
  if cad_universal "$1"; then echo "UNIVERSAL: caducan TODOS"; return 0; fi
  for j in "$2"/*.json; do
    [ -f "$j" ] || continue
    g="$(jq -r '.gate_id // .gate // empty' "$j" 2>/dev/null)"
    [ -n "$g" ] || continue
    motivo="$(cad_gate_caduca "$g" "$1")"; rc=$?
    case "$rc" in
      0) printf '%s CADUCA (%s)\n' "$g" "$motivo" ;;
      3) printf '%s SIN-MAPA(caduca)\n' "$g" ;;
      4) printf '%s CADUCA (siempre re-corre)\n' "$g" ;;
    esac
  done | sort -u
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cad_main "$@"
  exit $?
fi
