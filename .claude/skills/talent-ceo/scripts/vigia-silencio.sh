#!/usr/bin/env bash
# vigia-silencio.sh — UN tick: avisa si el bus lleva N minutos sin sellos de otros roles (talent-ceo, ref 08).
#
# Repo-agnóstico, token-only, sin MCP. Un vigía es un tick que sale con rc 0; el bucle vive en
# `vigias.sh`. Contrato común y razones en `lib-vigias.sh`.
#
# Uso:
#   vigia-silencio.sh [--minutos N] [--excluir-rol <ROL>]...
#   vigia-silencio.sh --help
#
# Entorno: TA_BUS (OBLIGATORIA) · TA_BUS_STATE_DIR.
#
# Salida:
#   SILENCIO-BUS <min> min sin sellos de otros roles (último: <rol> <marcador> a <ISO>)
#   SILENCIO-BUS-NO-MEDIDO …   bus ausente o ilegible, sin sellos con formato del paquete, sin ningún
#                              sello de otro rol, o último sello fechado en el futuro
#   SIN-ROL-EXCLUIDO …         no se indicó ningún --excluir-rol (una vez); se mide igualmente, pero los
#                              sellos propios cuentan como actividad y esconden el silencio
#
# rc: 0 = tick hecho · 2 = PRECONDICIÓN o la emisión de un evento falló.
#
# ── LA EDAD SE MIDE CON LA HORA ISO COMPLETA DEL PROPIO SELLO ──────────────────────────────────
# El sello lleva fecha y hora UTC (`2026-10-13T03:34:31Z`): la edad es `ahora - sello`, sin
# reconstruir la fecha de hoy a partir de `HH:MM:SS`. Reconstruirla envuelve cada 24 h, y un silencio
# de 30 h se leía como 6.
#
# Por TRANSICIÓN (umbral por defecto: 20 min): avisa al cruzarlo, calla mientras siga y se re-arma
# cuando vuelve a haber sellos de otros roles. Sin estado previo se parte de «bajo».
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib-vigias.sh"

minutos=20; excl=()
while [ $# -gt 0 ]; do
  case "$1" in
    --minutos)     _exige_valor $# "$1"; minutos="${2-}";  shift 2 ;;
    --excluir-rol) _exige_valor $# "$1"; excl+=("${2-}");  shift 2 ;;
    --help)        sed -n '2,28p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "vigia-silencio: argumento desconocido: $1" >&2; exit 2 ;;
  esac
done
vig_ent_acotado "$minutos" && [ "$minutos" -ge 1 ] || vig_precond "--minutos debe ser un entero positivo"
for r in "${excl[@]}"; do bus_valida_id "$r" || exit 2; done
[ -n "${TA_BUS-}" ] || vig_precond "TA_BUS no definida"
vig_estado_dir || exit 2

if [ "${#excl[@]}" -eq 0 ]; then
  vig_avisa_sube sin-rol-excluido 1 1 SIN-ROL-EXCLUIDO "no se indicó --excluir-rol: los sellos propios cuentan como actividad y esconden el silencio" || exit 2
fi

nomedido() { vig_no_medido silencio SILENCIO-BUS-NO-MEDIDO "$1" || exit 2; exit 0; }

bus="$TA_BUS"
[ -f "$bus" ] && [ -r "$bus" ] || nomedido "bus ausente o ilegible"

re='^([^ ]+) \[rol: ([^]]*)\] \[marcador: ([^]]*)\]( (.*))?$'
re_ts='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
pre='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z \[rol: '
ts=''
# Del final hacia atrás: el primer sello con formato cuyo rol no está excluido es «el último».
while IFS= read -r l; do
  [[ $l =~ $re ]] || continue
  t="${BASH_REMATCH[1]}"; rol="${BASH_REMATCH[2]}"; marc="${BASH_REMATCH[3]}"
  [[ $t =~ $re_ts ]] || continue
  fuera=0
  for r in "${excl[@]}"; do [ "$r" = "$rol" ] && fuera=1; done
  [ "$fuera" -eq 0 ] || continue
  ts="$t"; break
done < <(tac -- "$bus" 2>/dev/null | grep -a -E -- "$pre")
[ -n "$ts" ] || nomedido "ningún sello de otro rol con el formato del paquete"

te="$(date -u -d "$ts" +%s 2>/dev/null)" && vig_ent_acotado "$te" || nomedido "hora ilegible en el último sello: $ts"
ahora="$(vig_epoch)" || nomedido "no se pudo medir la hora"
edad=$((ahora - te))
[ "$edad" -ge -300 ] || nomedido "el último sello está fechado en el futuro: $ts"
[ "$edad" -ge 0 ] || edad=0
min=$((edad / 60))

vig_medido silencio || exit 2
vig_avisa_sube silencio "$min" "$minutos" SILENCIO-BUS "$min min sin sellos de otros roles (último: $rol $marc a $ts)" || exit 2
exit 0
