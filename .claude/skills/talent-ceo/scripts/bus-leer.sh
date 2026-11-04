#!/usr/bin/env bash
# bus-leer.sh — Lee el BUS desde el cursor PROPIO del lector y lo avanza (talent-ceo, ref 02).
#
# Cada lector tiene su cursor: dos lectores no se pisan y ninguno "consume" el bus para el otro.
# Repo-agnóstico, token-only, sin MCP.
#
# Uso:
#   bus-leer.sh --lector <ID> [--peek]      # --peek emite lo pendiente y NO mueve el cursor
#   bus-leer.sh --help
#
# Entorno: TA_BUS (OBLIGATORIA) · TA_BUS_CURSOR_DIR (por defecto,
# ${XDG_RUNTIME_DIR:-$HOME/.cache}/talent-ceo/cursores).
#
# ── rc EXACTOS ─────────────────────────────────────────────────────────────────────────────────
#   0 = emitido lo pendiente (puede ser vacío) y cursor actualizado
#   2 = PRECONDICIÓN: TA_BUS ausente/ilegible · ID inválido · precreación insegura ·
#       lock no adquirible · CURSOR MAYOR QUE EL BUS (truncado/rotación)
#
# ── QUÉ SIGNIFICA "LEÍDO", DICHO CON PRECISIÓN ─────────────────────────────────────────────────
# El cursor solo avanza si la emisión terminó BIEN. Si la salida se rompe a medias (SIGPIPE, el
# consumidor cierra la tubería, el proceso muere), NO se avanza NADA: el lector volverá a ver ese
# tramo. Es una decisión CONSERVADORA y declarada — preferimos repetir a perder. El contrato es
# "el cursor nunca avanza más allá de lo emitido", y no avanzar lo cumple trivialmente; no se
# afirma medir el byte exacto en el que se rompió la tubería, porque no se mide.
#
# ── CURSOR MAYOR QUE EL BUS: rc 2 ──────────────────────────────────────────────────────────────
# Si el bus se trunca o rota, un cursor viejo apunta más allá del final. Emitir desde ahí daría
# vacío en silencio y el lector creería estar al día: fail-open. Se falla cerrado, SIN tocar el
# cursor (que otro decida si rebobinar), y el diagnóstico imprime cursor y tamaño observados
# PERO NO vuelca contenido del bus: un mensaje de error no es un canal de exfiltración.
# Es una EXTENSIÓN declarada del contrato de la issue, no una exigencia literal suya.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib-bus.sh"


# Un `shift 2` con la opcion como ULTIMO argumento no desplaza nada (rc != 0) y, sin `set -e`, el
# bucle vuelve a leer el mismo `$1`: BUCLE INFINITO. Se exige el valor ANTES de desplazar.
_exige_valor(){ [ "$1" -ge 2 ] || { printf '%s: PRECOND: %s exige un valor\n' "${0##*/}" "$2" >&2; exit 2; }; }

lector=''; peek=0
while [ $# -gt 0 ]; do
  case "$1" in
    --lector) _exige_valor $# "$1"; lector="${2-}"; shift 2 ;;
    --peek)   peek=1;         shift ;;
    --help)   sed -n '2,31p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "bus-leer: argumento desconocido: $1" >&2; exit 2 ;;
  esac
done

bus_valida_id "$lector" || exit 2
bus="${TA_BUS-}"
[ -n "$bus" ] || { echo "bus: PRECOND: TA_BUS no definida" >&2; exit 2; }
[ -f "$bus" ] && [ -r "$bus" ] || { echo "bus: PRECOND: TA_BUS ausente o ilegible: $bus" >&2; exit 2; }

base="$(bus_dir_estado)"
bus_asegura_dir "$base" || exit 2
cdir="${TA_BUS_CURSOR_DIR:-$base/cursores}"
bus_asegura_dir "$cdir" || exit 2

cursor="$cdir/$lector.cursor"
lock="$cdir/$lector.lock"
bus_asegura_regular "$cursor" || exit 2
bus_asegura_regular "$lock"   || exit 2
bus_contenido_en "$cursor" "$cdir" || exit 2
bus_contenido_en "$lock"   "$cdir" || exit 2

: > "$lock" 2>/dev/null || { echo "bus: PRECOND: lock no creable: $lock" >&2; exit 2; }
exec 9>"$lock" || { echo "bus: PRECOND: lock no abrible: $lock" >&2; exit 2; }
# Las lecturas del MISMO lector se serializan: dos invocaciones concurrentes no pueden avanzar el
# cursor a la vez y perderse un tramo entre ambas.
if ! flock -w 10 -x 9; then
  echo "bus: PRECOND: lock no adquirible en 10s: $lock" >&2; exit 2
fi

# ── UN CURSOR QUE NO SE ENTIENDE **NO** ES UN CURSOR EN CERO ───────────────────────────────────
# Antes, cualquier contenido que no fuera todo dígitos se convertía en `pos=0` **en silencio**:
# `+1`, `-1`, ` 1`, `1 ` y hasta `abc` re-emitían el bus ENTERO con rc 0 y reescribían el cursor.
# Medido sobre un bus `abcdef`: los cinco casos emitían `abcdef` y dejaban el cursor en 7. Eso es un
# rebobinado silencioso, la misma familia que el cursor mayor que el bus — y la tabla de rc de
# `SKILL.md` promete rc 2 para «cursor inválido». Un cursor ilegible es estado corrupto: se falla
# CERRADO y no se toca, que decida quien opera.
# El fichero AUSENTE sí es `pos=0` legítimo: es la primera lectura de ese lector.
pos=0
if [ -f "$cursor" ]; then
  pos="$(cat "$cursor" 2>/dev/null || echo '')"
  case "$pos" in
    ''|*[!0-9]*)
      echo "bus: PRECOND: el cursor de \"$lector\" no es un entero: $(printf '%s' "$pos" | tr -d '[:cntrl:]' | cut -c1-40)" >&2
      echo "bus: el cursor NO se modifica; un cursor ilegible no es un cursor en cero" >&2
      exit 2 ;;
  esac
fi

# ── EL CURSOR VA ATADO AL BUS, NO SÓLO AL LECTOR ───────────────────────────────────────────────
# El cursor es un desplazamiento en bytes, y un desplazamiento sólo significa algo DENTRO del
# fichero que lo produjo. Estaba indexado únicamente por lector, así que al rotar el bus el cursor
# viejo se aplicaba al fichero nuevo. Medido: leído un bus `AAAA` (cursor→4), leer con el MISMO
# lector otro bus `BBBBBBBB` emitía sólo `BBBB` con rc 0 — **los cuatro primeros bytes del bus
# nuevo se saltaban en silencio**. El caso de «cursor > tamaño» sólo caza la rotación a un fichero
# MÁS PEQUEÑO; a uno igual o mayor entraba por debajo.
# Se guarda la identidad del bus (dispositivo:inodo, la misma noción que usa `-ef` en `lib-bus.sh`,
# no la ruta) junto al cursor. Si cambia ⇒ rc 2 sin tocar nada. Si no hay marca —cursor de antes de
# esta comprobación, o primera lectura— se registra y se sigue: negarse ahí convertiría una mejora
# en una avería para todos los lectores existentes.
marca="$cdir/$lector.bus"
bus_asegura_regular "$marca" || exit 2
bus_contenido_en "$marca" "$cdir" || exit 2
id_bus="$(stat -c '%d:%i' "$bus" 2>/dev/null)"
if [ -z "$id_bus" ]; then
  echo "bus: PRECOND: no se pudo leer la identidad del bus ($bus); no se lee a ciegas" >&2; exit 2
fi
id_previo=''
[ -f "$marca" ] && id_previo="$(cat "$marca" 2>/dev/null || echo '')"
if [ -n "$id_previo" ] && [ "$id_previo" != "$id_bus" ]; then
  echo "bus: PRECOND: el bus NO es el mismo que la última vez que leyó \"$lector\" (rotado o sustituido)" >&2
  echo "bus: el cursor apunta a un fichero que ya no existe; NO se modifica, decide tú si rebobinar" >&2
  exit 2
fi
# Y la migración NO puede ser un agujero permanente. La primera versión dejaba pasar cualquier
# cursor sin marca «para no romper a los lectores existentes», y eso reabria el defecto entero: con
# un cursor legado en 4 y el bus sustituido por otro inodo, la lectura siguiente devolvia rc 0 y se
# saltaba los cuatro primeros bytes del bus NUEVO — exactamente lo que la marca existe para impedir.
# Truncar la marca a vacio daba el mismo salto.
# El corte correcto no es «hay marca o no»: es si hay algo QUE PERDER. Un cursor en 0 —o ausente— no
# puede saltarse nada, asi que ahi se registra la marca y se sigue. Un cursor >0 SIN marca verificable
# es estado que no se puede acreditar: se falla cerrado UNA vez, y quien opere decide.
if [ -z "$id_previo" ] && [ "$pos" -gt 0 ]; then
  echo "bus: PRECOND: el cursor de \"$lector\" está en $pos pero no hay marca de qué bus lo produjo" >&2
  echo "bus: no se puede acreditar que apunte a ESTE fichero; borra el cursor para rebobinar, o la marca si sabes que es el mismo bus" >&2
  exit 2
fi

# ── La instantánea del bus se toma bajo el candado DEL ESCRITOR ────────────────────────────────
# El lock de arriba serializa a este lector consigo mismo, pero NO con quien sella. Sin este
# segundo candado, un `bus-sellar` que escriba entre el `wc -c` y el `tail` deja al lector con una
# LÍNEA PARTIDA: el tamaño medido y los bytes emitidos son de estados distintos del fichero.
# Se toma el mismo lock que usa el sellador y se suelta en cuanto la instantánea está hecha.
bus_lock="$(bus_ruta TA_BUS_LOCK "$base/bus.lock")"
bus_asegura_regular "$bus_lock" || exit 2
: > "$bus_lock" 2>/dev/null || { echo "bus: PRECOND: lock del bus no creable: $bus_lock" >&2; exit 2; }
exec 8>"$bus_lock" || { echo "bus: PRECOND: lock del bus no abrible: $bus_lock" >&2; exit 2; }
if ! flock -x -w 10 8; then
  echo "bus: PRECOND: lock del bus no adquirible en 10s: $bus_lock" >&2; exit 2
fi

# ── LA IDENTIDAD SE RE-MIDE AQUI, YA BAJO EL CANDADO ───────────────────────────────────────────
# La comprobacion de mas arriba mide `%d:%i` ANTES de tomar el candado y el fichero se lee DESPUES:
# entre las dos cosas hay una ventana, y en ella el bus puede rotarse. Es TOCTOU de manual — se
# comprueba una cosa y se usa otra— y reabre EXACTAMENTE el defecto para el que existe la marca:
# cursor viejo aplicado a fichero nuevo, con el tramo inicial del bus nuevo saltado en silencio.
# La ventana no es teorica: `flock -w 10` puede esperar hasta diez segundos con un sellador dentro,
# y ahi cabe una rotacion entera.
# REPRODUCIDO: con el candado retenido por otro proceso mientras se sustituye el bus por otro inodo,
# la version anterior emitia el tramo equivocado del fichero NUEVO con rc 0. Caso `[r15-1]`.
# La identidad de despues manda: si difiere, mismo `exit 2` que arriba y NO se persiste marca ni
# cursor — no se decide por el operador, se le dice que decida el.
id_bus_ahora="$(stat -c '%d:%i' "$bus" 2>/dev/null)"
if [ -z "$id_bus_ahora" ]; then
  echo "bus: PRECOND: no se pudo releer la identidad del bus ($bus) bajo el candado; no se lee a ciegas" >&2
  exit 2
fi
if [ "$id_bus_ahora" != "$id_bus" ]; then
  echo "bus: PRECOND: el bus cambio de identidad entre la comprobacion y la lectura (rotado o sustituido bajo el candado)" >&2
  echo "bus: el cursor apunta a un fichero que ya no es este; NO se modifica, decide tu si rebobinar" >&2
  exit 2
fi

tam="$(wc -c < "$bus" 2>/dev/null | tr -d ' ')"
# Si `wc` falla, `tam` queda VACIO y las comparaciones de abajo no comparan: **erran**. Medido con un
# `wc` sustituido por un stub que sale 1 — el script emitia el bus, escribia un cursor VACIO y
# devolvia **rc 0**. O sea: decia "leido y anotado" habiendo dejado el estado corrupto, y el fallo
# solo aparecia en la lectura SIGUIENTE. Se falla cerrado aqui, donde aun se sabe por que.
case "$tam" in ''|*[!0-9]*)
  echo "bus: PRECOND: no se pudo medir el tamano del bus ($bus); no se lee a ciegas" >&2; exit 2 ;;
esac


# La guarda de arriba mira el CHARSET del cursor, no su MAGNITUD — y es la misma lección que ya
# está escrita en `tablas-cron.sh` para el campo de minutos: *una guarda de charset sólo mira QUÉ
# caracteres aparecen, no cómo se combinan*. Aquí la dimensión que faltaba es el TAMAÑO.
# `18446744073709551616` son todos dígitos y la pasa, pero desborda el entero de 64 bits de bash:
# `[ "$pos" -gt "$tam" ]` NO compara, **erra** («integer expression expected»), el `if` sale falso
# y el cursor se cuela hasta `$((pos + 1))`, donde el desbordamiento lo convierte en 1. Resultado
# medido: se re-emite EL BUS ENTERO con **rc 0** y se reescribe el cursor. Un rebobinado silencioso,
# que es exactamente lo que el rc 2 de aquí abajo existe para impedir — el fallo entraba por la
# puerta de al lado de la guarda que lo prohíbe.
# Se acota por LONGITUD y no por comparación aritmética, porque comparar es justo lo que no se
# puede hacer con un valor que no cabe. 18 dígitos entran siempre en un entero de 64 bits, y un bus
# de 10^18 bytes no existe: cualquier cursor más largo es corrupto, y corrupto ⇒ mismo cubo que
# «supera el tamaño».
if [ "${#pos}" -gt 18 ] || [ "$pos" -gt "$tam" ]; then
  echo "bus: PRECOND: el cursor ($pos) no es una posición válida dentro del bus ($tam bytes) — ¿truncado, rotado o corrupto?" >&2
  echo "bus: el cursor NO se modifica; decide tú si rebobinar" >&2
  exit 2
fi

# Y AHORA, no antes, se normaliza a decimal. `$(( ))` interpreta el cero inicial como OCTAL y ahi
# `08` y `09` no son digitos validos: la expansion falla. Medido sobre un bus `0123456789XYZ` con
# cursor `09` -> `tail -c "+$((pos + 1))"` no llegaba a ejecutarse, la instantanea salia VACIA, se
# escribia el cursor al final y se devolvia **rc 0 SIN EMITIR UN BYTE** — el tramo pendiente entero,
# perdido en silencio. Con `07` (octal valido) si emitia: el defecto dependia del digito, que es la
# peor forma de tenerlo. El `[` de las comparaciones NO tiene este problema, asi que la guarda de
# magnitud de arriba sigue valiendo tal cual.
# EL ORDEN IMPORTA y por eso va aqui: normalizando ANTES, un cursor de 20 digitos desbordaba en el
# `10#` y entraba por debajo de la guarda de magnitud — medido, dos casos de la suite se pusieron
# rojos al ponerlo arriba. Primero se acota, despues se convierte.
pos=$((10#$pos))

if [ "$pos" -eq "$tam" ]; then
  # Nada pendiente. No se toca el cursor: ya está donde debe, y reescribirlo solo añade una
  # ventana en la que puede quedar a medias sin ganar nada.
  exit 0
fi

# ── VOLCAR bajo el candado; EMITIR fuera ───────────────────────────────────────────────────────
# El `tail` escribía directamente al consumidor CON el candado del escritor tomado: un consumidor
# lento (tubería con contrapresión, ssh a otra máquina) bloqueaba a CUALQUIERA que quisiera sellar
# durante todo el volcado. El comentario de arriba ya prometía soltarlo "en cuanto la instantánea
# está hecha" y el código no lo hacía — se cumple ahora la promesa que ya estaba escrita.
snap="$(mktemp "$cdir/.$lector.snap.XXXXXX")" || {
  echo "bus: no se pudo crear el temporal de instantánea" >&2; exit 2; }
trap 'rm -f "$snap"' EXIT
if ! tail -c "+$((pos + 1))" "$bus" > "$snap"; then
  echo "bus: no se pudo volcar el tramo pendiente; el cursor NO avanza" >&2
  exit 2
fi
flock -u 8 2>/dev/null || true      # a partir de aquí, sellar puede continuar
exec 8>&-

# Emitir lo pendiente, ya SIN candados. Si la emisión falla (tubería rota), NO se avanza el cursor.
# Y se sale con rc 2, no con 0. Salir con 0 decía al consumidor «te entregué el tramo y el estado
# quedó consistente» cuando ni una cosa ni la otra: el lector NO sabe cuánto llegó al otro lado y
# el cursor se queda donde estaba. Medido: `bus-leer.sh | head -c 1` sobre un bus de 2 MiB mata al
# `cat` con SIGPIPE, deja el cursor SIN ESCRIBIR y devolvía **0**. Un consumidor automático no
# podía distinguir eso de una lectura completa. Repetir el tramo es seguro; decir «bien» cuando no
# se sabe, no lo es — es la misma clase de fail-open que el rc 2 del cursor de arriba.
if ! cat "$snap"; then
  echo "bus: emisión interrumpida; el cursor NO avanza (se repetirá el tramo)" >&2
  exit 2
fi

if [ "$peek" -eq 0 ]; then
  # Persistencia ATÓMICA: temporal en el MISMO directorio (mismo filesystem, así `mv` es rename(2))
  # y luego `mv`. Escribir en sitio dejaría un cursor a medias si el proceso muere aquí.
  # Nombre IMPREDECIBLE: con `$cursor.tmp.$$` (el PID) un tercero puede precrear esa ruta —fichero
  # o symlink— y desviar la escritura del cursor.
  # ── EL ORDEN: LA MARCA PRIMERO, EL CURSOR DESPUÉS. Y la razón contraria estaba escrita aquí ──
  # La primera versión escribía el cursor primero «porque si muere en medio, la próxima lectura falla
  # cerrada, que es el desenlace seguro». **No lo es: falla cerrada PARA SIEMPRE.** Medido con un `mv`
  # que falla en su segunda invocación: la lectura emite el tramo, devuelve 2 y deja cursor=3 SIN
  # marca; y como un cursor >0 sin marca es rc 2 por contrato, ese lector queda **enclavado** hasta
  # que alguien entre a mano. Un lector que no puede volver a leer nunca no es fail-closed, es una
  # avería.
  # El miedo que justificaba aquel orden —«marca nueva con cursor viejo aplicaría el desplazamiento
  # al fichero nuevo»— NO PUEDE OCURRIR: aquí sólo se llega después de haber verificado arriba que la
  # marca previa coincide con este bus (o de que no hubiera cursor que perder), así que lo único que
  # esta escritura puede poner es **el valor que se acaba de comprobar**.
  # Con este orden, morir en medio deja marca al día y cursor viejo ⇒ se repite el tramo. Repetir es
  # seguro; enclavar no. Es la misma doctrina que el resto del fichero, aplicada al orden de dos
  # escrituras que no pueden ser una sola.
  tmpm="$(mktemp "$cdir/.$lector.bus.XXXXXX")" || {
    echo "bus: fallo al crear la marca temporal de identidad" >&2; exit 2; }
  printf '%s' "$id_bus" > "$tmpm" || { rm -f "$tmpm"; echo "bus: fallo al escribir la marca" >&2; exit 2; }
  mv -f "$tmpm" "$marca" || { rm -f "$tmpm"; echo "bus: fallo al mover la marca" >&2; exit 2; }
  # El cursor va SEGUNDO: si esto falla, el cursor se queda donde estaba y el tramo se repetirá.
  tmp="$(mktemp "$cdir/.$lector.cursor.XXXXXX")" || {
    echo "bus: fallo al crear cursor temporal" >&2; exit 2; }
  printf '%s' "$tam" > "$tmp" || { rm -f "$tmp"; echo "bus: fallo al escribir cursor temporal" >&2; exit 2; }
  mv -f "$tmp" "$cursor" || { rm -f "$tmp"; echo "bus: fallo al mover cursor" >&2; exit 2; }
fi
exit 0
