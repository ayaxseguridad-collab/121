#!/usr/bin/env bash
# auditar-gaps.sh — mapa de gaps de un PRD contra el superset de 27 secciones,
# CONSCIENTE del appetite. SOLO LECTURA por contrato.
#
#   uso: auditar-gaps.sh <prd.md>
#
# Lee el appetite de la cabecera machine-readable y compara las secciones del
# documento contra las EXIGIBLES de ese nivel (tabla canonica en lib.sh, la misma
# de references/03 seccion 2). Una seccion del superset no exigible en tu nivel
# se informa como 'fuera-de-appetite', NO como gap — un Lite completo tiene cero
# gaps aunque le falten 18 secciones del superset.
#
# Salida: 'GAP <seccion>' por exigible ausente · 'INFO fuera-de-appetite: <seccion>'.
# rc: 0 = cero gaps · 1 = hay gaps · 2 = precondicion (fichero/cabecera invalida).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

PRD="${1:-}"
[ -n "$PRD" ] || { morir "uso: auditar-gaps.sh <prd.md>"; exit 2; }
[ -f "$PRD" ] || { morir "prd no existe: $PRD"; exit 2; }
pr_leer_cabecera "$PRD" || { morir "cabecera invalida o ausente en linea 1 — sin appetite declarado no hay auditoria (references/03 seccion 6)"; exit 2; }

rango_doc="$(pr_rango_nivel "$PRD_APPETITE")" || { morir "appetite invalido: $PRD_APPETITE"; exit 2; }

echo "==== auditar-gaps: $PRD (appetite=$PRD_APPETITE) ===="
gaps=0; presentes=0; exigibles=0
while IFS=$'\t' read -r nivel nombre; do
  rango_sec="$(pr_rango_nivel "$nivel")"
  if [ "$rango_sec" -le "$rango_doc" ]; then
    exigibles=$((exigibles+1))
    if pr_tiene_seccion "$PRD" "$nombre"; then
      presentes=$((presentes+1))
    else
      printf 'GAP %s\n' "$nombre"
      gaps=$((gaps+1))
    fi
  else
    if ! pr_tiene_seccion "$PRD" "$nombre"; then
      printf 'INFO fuera-de-appetite: %s\n' "$nombre"
    else
      presentes=$((presentes+1))
    fi
  fi
done < <(pr_superset)

printf '== gaps=%s appetite=%s exigibles=%s presentes=%s ==\n' "$gaps" "$PRD_APPETITE" "$exigibles" "$presentes"
[ "$gaps" -eq 0 ]
