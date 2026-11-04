#!/usr/bin/env bash
# pozos-cuotas.sh [pN ...] — tabla de uso 5h/7d y resets (CDMX) por cuenta, ordenada por reset semanal (la que antes renueva primero).
# Lee la línea OAuth del lector de cada pozo DENTRO de su contenedor. Los tokens largos no sirven para leer uso (la API los rechaza).
# Los ids de pozo pasan por la allowlist de pozos-lib.sh antes de tocar ssh/incus (anti-inyección, M5-BOUNCE).
. "$(dirname "$0")/pozos-lib.sh"
LIST=${*:-$(pozos_list)}
{ for p in $LIST; do pozos_require pozo "$p" "pozos-cuotas" || continue; pozo_usage_row "$p"; sleep 2; done; } | sort -k5,5n | while read -r p s5 r5 s7 r7 fb fbr; do
  fbs=$([ "${fb:--1}" -ge 0 ] && echo "${fb}%" || echo "n/a")
  printf '%-4s %-32s 5h=%4s%% reset %-17s | 7d=%4s%% reset %-17s | Fable7d=%-4s\n' "$p" "$(pozo_cuenta "$p" | cut -c1-32)" "$s5" "$(fmt_cdmx "$r5")" "$s7" "$(fmt_cdmx "$r7")" "$fbs"; done
