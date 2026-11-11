#!/usr/bin/env bash
# vigia-bus.sh — UN tick: emite los pedidos o los rojos NUEVOS del bus (talent-ceo, ref 08).
#
# Repo-agnóstico, token-only, sin MCP. Un vigía es un tick que sale con rc 0; el bucle vive en
# `vigias.sh`. Contrato común y razones en `lib-vigias.sh`.
#
# Uso:
#   vigia-bus.sh --modo pedidos|rojos --lector <ID> [--patron <ERE>] [--excluir-rol <ROL>]...
#   vigia-bus.sh --help
#
# Entorno: TA_BUS (OBLIGATORIA) · TA_BUS_STATE_DIR (ver `lib-bus.sh`).
#
# Salida: `PEDIDO <rol> <marcador> <texto>` o `ROJO <rol> <marcador> <texto>`, una línea por sello
# nuevo cuyo marcador+texto casa con el patrón y cuyo rol no está excluido. Si no se pudo leer el bus
# (ausente, cursor mayor que el bus, ilegible) o lo nuevo no trae ninguna línea con el formato del
# paquete: `PEDIDO-NO-MEDIDO` / `ROJO-NO-MEDIDO`, una vez por transición.
#
# rc: 0 = tick hecho (con o sin eventos) · 2 = PRECONDICIÓN (argumentos, TA_BUS sin definir, estado
#     inseguro) o la emisión de un evento falló.
#
# ── LO ESCRITO MIENTRAS NADIE VIGILA SALE EN EL TICK SIGUIENTE ─────────────────────────────────
# El vigía lleva su PROPIO cursor de bytes (uno por --lector; los dos modos necesitan lectores
# distintos), con la identidad del bus. No avanza si la lectura o la emisión fallan, y un bus
# truncado, rotado o cambiado sale como `…-NO-MEDIDO`: nunca como calma.
#
# Patrones: vocabulario INICIAL de las fuentes vivas del CEO; `--patron` lo sustituye. Las
# exclusiones de una instancia concreta no se heredan: se dan con `--patron` y `--excluir-rol`.
# `pedidos` casa sin distinguir mayúsculas; `rojos`, distinguiéndolas.
#
# El cursor avanza DESPUÉS de entregar y solo sobre la instantánea entregada: si la emisión falla o el
# proceso muere antes, el tramo se repite; lo que se selle entretanto sale en el tick siguiente.
#
# ── CONTRATO DEL BUS (decisión del CEO): SOLO-AÑADIR ───────────────────────────────────────────
# El bus es solo-añadir: quien sella escribe con O_APPEND y la identidad va por inodo, así que lo ya
# entregado no cambia nunca. Una diferencia en lo ya entregado es una VIOLACIÓN del contrato, no un caso
# normal: da `…-NO-MEDIDO` y obliga a resincronizar, que decide quien opera. Antes de avanzar el cursor
# se relee el tramo entero y se compara con lo entregado (red de seguridad: la declaración no la sustituye);
# y el cursor guarda la suma del tramo entregado ENTERO, de modo que un cambio que ocurra entre esa
# comparación y el guardado del cursor —o después— se detecta en el tick siguiente (`…-NO-MEDIDO`, sin
# avanzar), nunca en silencio. Solo queda sin vigilar lo anterior al último tramo entregado.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib-vigias.sh"

modo=''; lector=''; patron=''; excl=()
while [ $# -gt 0 ]; do
  case "$1" in
    --modo)         _exige_valor $# "$1"; modo="${2-}";     shift 2 ;;
    --lector)       _exige_valor $# "$1"; lector="${2-}";   shift 2 ;;
    --patron)       _exige_valor $# "$1"; patron="${2-}";   shift 2 ;;
    --excluir-rol)  _exige_valor $# "$1"; excl+=("${2-}");  shift 2 ;;
    --help)         sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "vigia-bus: argumento desconocido: $1" >&2; exit 2 ;;
  esac
done
case "$modo" in
  pedidos) clase=PEDIDO
           [ -n "$patron" ] || patron='PIDO|PREGUNTA|PIDE RULING|re-GO|PROPUESTA|¿SÍ|¿me das|¿quieres|¿paro|espero tu|a la espera de tu|CEO decide|RECUERDO|RECORDATORIO|¿Lanzo'
           shopt -s nocasematch ;;
  rojos)   clase=ROJO
           [ -n "$patron" ] || patron='ROJO|FALLO|CAID|URGENTE|INCIDENTE|ALERTA|PARADA|MUERT|ABORT|-SOS' ;;
  *) vig_precond "--modo debe ser pedidos o rojos" ;;
esac
bus_valida_id "$lector" || exit 2
for r in "${excl[@]}"; do bus_valida_id "$r" || exit 2; done
# Un ERE inválido es rc 2 de `[[ =~ ]]`: se prueba ANTES de leer nada, o el cursor avanzaría en vano.
[[ x =~ $patron ]]; [ $? -ne 2 ] || vig_precond "--patron no es una expresión regular válida"
[ -n "${TA_BUS-}" ] || vig_precond "TA_BUS no definida"
vig_estado_dir || exit 2

clave="bus-$lector-$modo"
tmp="$(mktemp "$VIG_DIR/.bus-$lector.t.XXXXXX")" || vig_precond "no se pudo crear el temporal"
snap="$tmp.cur"
trap 'rm -f -- "$tmp" "$snap" "${ctmp-}"' EXIT

# Un solo tick por lector a la vez: el candado abarca leer, emitir y avanzar el cursor, así que dos
# vigías con el mismo --lector no pueden entregar el mismo tramo dos veces ni pisarse el cursor.
ciclo="$VIG_DIR/bus-$lector.ciclo"
bus_asegura_regular "$ciclo" || exit 2
exec 6>>"$ciclo" || vig_precond "no se pudo abrir el candado del lector: $ciclo"
flock -x -w "${TA_VIG_ESPERA:-10}" 6 || vig_precond "candado del lector no adquirible: $ciclo"
rm -f -- "$VIG_DIR/.bus-$lector.c."* "$tmp.cur"   # restos de un tick que murió a medias

# ── EL CURSOR ES DEL VIGÍA Y SOLO AVANZA SOBRE LO QUE SE HA ENTREGADO ──────────────────────────
# `bus-leer.sh` solo sabe leer-sin-mover (`--peek`) o leer-todo-y-avanzar: no confirma hasta un
# byte, así que cualquier confirmación posterior a la entrega consumiría también lo que se selló (o
# cambió) entre las dos lecturas y aún no se entregó. Este vigía lleva su PROPIO cursor, en su
# directorio de estado, y lee el bus por desplazamiento y en modo solo lectura:
#   v2 <dispositivo:inodo> <desplazamiento> <m> <sha256 del último tramo entregado, de m bytes>
# (un cursor sin «v2», con la suma de solo 64 bytes, es ilegible: falla cerrado y se resincroniza)
# Se toma UNA instantánea (solo líneas completas), se emiten sus eventos y el cursor avanza
# EXACTAMENTE la longitud de esa instantánea, y solo si todos los eventos salieron. Si la emisión
# falla o el proceso muere antes, el cursor no se movió y el tramo se repite (repetir, nunca perder);
# lo que se selle mientras tanto no está en la instantánea y se entrega en el tick siguiente.
# Falla cerrado, sin avanzar y como `…-NO-MEDIDO`: bus ausente o ilegible, otra identidad (rotado o
# sustituido), cursor mayor que el bus (truncado), cursor ilegible o lo ya entregado distinto de lo
# que se entregó. Nada de eso se arregla solo: el cursor no se reescribe.
cursor="$VIG_DIR/bus-$lector.cursor"
bus_asegura_regular "$cursor" || exit 2
nm() { vig_no_medido "$clave" "$clase-NO-MEDIDO" "lector $lector: $1" || exit 2; exit 0; }
bus="$TA_BUS"
[ -f "$bus" ] && [ -r "$bus" ] || nm "bus ausente o ilegible"
id="$(stat -c '%d:%i' "$bus" 2>/dev/null)"
[ -n "$id" ] || nm "no se pudo leer la identidad del bus"
tam="$(wc -c < "$bus" 2>/dev/null | tr -d ' ')"
vig_ent_acotado "$tam" || nm "no se pudo medir el tamaño del bus"
off=0; m=0; sum=''
if [ -f "$cursor" ]; then
  lin="$(cat -- "$cursor" 2>/dev/null)"
  # Formato v2: la suma cubre el ÚLTIMO TRAMO entregado entero. Un cursor viejo (sin «v2», suma de solo 64
  # bytes) NO se interpreta ni se migra: es ilegible, falla cerrado y lo resincroniza quien opera.
  [[ $lin =~ ^v2\ ([0-9]+:[0-9]+)\ ([0-9]{1,18})\ ([0-9]{1,18})\ ([0-9a-f]{64})$ ]] || nm "el cursor del vigía no es legible (formato v2 de tramo entero; un cursor viejo se resincroniza); decide quien opera"
  off="${BASH_REMATCH[2]}"; m="${BASH_REMATCH[3]}"; sum="${BASH_REMATCH[4]}"
  [ "$m" -le "$off" ] || nm "el cursor del vigía no es legible; decide quien opera"
  [ "${BASH_REMATCH[1]}" = "$id" ] || nm "el bus no es el mismo que leyó este cursor (rotado o sustituido); decide quien opera"
  [ "$off" -le "$tam" ] || nm "el cursor ($off) supera el bus ($tam bytes): truncado o rotado; decide quien opera"
  if [ "$m" -gt 0 ]; then
    cur="$(tail -c +$((off - m + 1)) -- "$bus" | head -c "$m" | sha256sum)"; cur="${cur%% *}"
    [ "$cur" = "$sum" ] || nm "lo ya entregado ha cambiado en el bus; decide quien opera"
  fi
fi
# Instantánea: lo que hay desde el cursor, recortado a la última línea COMPLETA (una línea a medio
# escribir se queda para el tick siguiente).
tail -c +$((off + 1)) -- "$bus" > "$tmp" 2>/dev/null || nm "no se pudo leer el bus"
bruto="$(wc -c < "$tmp" | tr -d ' ')"
L=0
if [ "$bruto" -gt 0 ]; then
  resto="$(tail -n 1 -- "$tmp" | wc -c | tr -d ' ')"
  [ "$(tail -c 1 -- "$tmp" | wc -l | tr -d ' ')" -ne 1 ] || resto=0
  L=$((bruto - resto))
  [ "$L" -eq 0 ] || head -c "$L" -- "$tmp" > "$snap"
fi

# avanza: guarda el cursor nuevo (atómico: temporal + rename) sobre exactamente L bytes de la instantánea.
avanza() {
  local mm nsum
  mm=$L        # la suma cubre el tramo entregado ENTERO: un cambio entre el cmp y este rename se detecta en el tick siguiente
  nsum="$(tail -c "$mm" -- "$snap" | sha256sum)"; nsum="${nsum%% *}"
  ctmp="$(mktemp "$VIG_DIR/.bus-$lector.c.XXXXXX")" || { echo "vigia-bus: no se pudo crear el cursor temporal" >&2; exit 2; }
  printf 'v2 %s %s %s %s\n' "$id" "$((off + L))" "$mm" "$nsum" > "$ctmp" \
    && mv -f -- "$ctmp" "$cursor" || { echo "vigia-bus: no se pudo guardar el cursor" >&2; exit 2; }
}

re='^([^ ]+) \[rol: ([^]]*)\] \[marcador: ([^]]*)\]( (.*))?$'
# procesa <fichero>: emite los eventos de un tramo y deja en TOT/FMT cuántas líneas trae y cuántas
# con el formato del paquete. Una emisión fallida es rc 2 SIN confirmar el cursor.
procesa() {
  local l rol marc nota r fuera texto
  TOT=0; FMT=0
  while IFS= read -r l; do
    [ -n "${l//[[:space:]]/}" ] || continue
    TOT=$((TOT + 1))
    [[ $l =~ $re ]] || continue
    FMT=$((FMT + 1))
    rol="${BASH_REMATCH[2]}"; marc="${BASH_REMATCH[3]}"; nota="${BASH_REMATCH[5]-}"
    fuera=0
    for r in "${excl[@]}"; do [ "$r" = "$rol" ] && fuera=1; done
    [ "$fuera" -eq 0 ] || continue
    texto="$marc $nota"
    [[ $texto =~ $patron ]] || continue
    vig_evento "$clase" "$rol $marc $nota" || { echo "vigia-bus: la emisión de un evento falló; el cursor NO avanza y el tramo se repetirá" >&2; exit 2; }
  done < <(tr '\0' ' ' < "$1")
}
if [ "$L" -gt 0 ]; then procesa "$snap"; else TOT=0; FMT=0; fi

# Estado «no medido»: solo cambia con novedades. Un tick sin bytes nuevos NO acredita que el bus
# vuelva a tener formato, así que conserva el estado; se re-arma al ver una línea con formato.
if [ "$TOT" -eq 0 ]; then :
elif [ "$FMT" -eq 0 ]; then
  vig_no_medido "$clave" "$clase-NO-MEDIDO" "lector $lector: lo nuevo no trae ninguna línea con el formato del paquete" || exit 2
else
  vig_medido "$clave" || exit 2
fi

# Red de seguridad del contrato solo-añadir: antes de avanzar se RELEE el tramo [off, off+L) y se compara
# ENTERO con la instantánea entregada. Si difiere, lo entregado ha cambiado en el bus: violación, `…-NO-MEDIDO`
# y el cursor NO avanza (el tick siguiente vuelve a leer el tramo tal como está ahora).
if [ "$L" -gt 0 ]; then
  tail -c +$((off + 1)) -- "$bus" > "$tmp" 2>/dev/null
  cmp -s -n "$L" -- "$tmp" "$snap" || nm "lo entregado ha cambiado en el bus (violación del contrato solo-añadir); decide quien opera"
fi
# Todos los eventos de la instantánea salieron y el tramo sigue siendo el entregado: el cursor avanza esos L bytes y ni uno más.
if [ "$L" -gt 0 ]; then avanza; fi
exit 0
