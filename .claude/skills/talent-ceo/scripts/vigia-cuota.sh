#!/usr/bin/env bash
# vigia-cuota.sh — Avisa cuando la cuota CRUZA un umbral, no mientras siga alta (talent-ceo, ref 04).
#
# Repo-agnóstico, token-only, sin MCP.
#
# Uso:
#   vigia-cuota.sh --valor <N> --estado <fichero> [--umbral N]
#   vigia-cuota.sh --help
#
# rc: 0 = sin transición (nada que decir) · 10 = TRANSICIÓN (se emite el aviso por stdout)
#     2 = PRECONDICIÓN.
#
# ── POR TRANSICIÓN, NO POR NIVEL — y no es un detalle de estilo ────────────────────────────────
# Un vigía que avisa "por nivel" repite el mismo aviso en cada tick mientras el valor siga por
# encima del umbral. Eso entrena a quien lo lee a ignorarlo, y el día que aparece un aviso NUEVO
# ya nadie lo mira: el ruido no es una molestia, es una pérdida de señal.
# Aquí se emite SOLO cuando el lado cambia (bajo->alto o alto->bajo), y el lado anterior se
# persiste en el fichero de estado. Sin estado previo, el primer tick NO grita: se registra el lado
# y se calla — un vigía que nace gritando es indistinguible de uno roto.
set -uo pipefail


# Un `shift 2` con la opcion como ULTIMO argumento no desplaza nada (rc != 0) y, sin `set -e`, el
# bucle vuelve a leer el mismo `$1`: BUCLE INFINITO. Se exige el valor ANTES de desplazar.
_exige_valor(){ [ "$1" -ge 2 ] || { printf '%s: PRECOND: %s exige un valor\n' "${0##*/}" "$2" >&2; exit 2; }; }

valor=''; estado=''; umbral=80
while [ $# -gt 0 ]; do
  case "$1" in
    --valor) _exige_valor $# "$1"; valor="${2-}";  shift 2 ;;
    --estado) _exige_valor $# "$1"; estado="${2-}"; shift 2 ;;
    --umbral) _exige_valor $# "$1"; umbral="${2-}"; shift 2 ;;
    --help)   sed -n '2,19p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "vigia-cuota: argumento desconocido: $1" >&2; exit 2 ;;
  esac
done
# Dígitos Y longitud representable. La guarda de charset sola sólo mira QUÉ caracteres aparecen:
# `999999999999999999999999999999` son todos dígitos y la pasa, pero no cabe en el entero de 64
# bits de bash, así que `[ "$valor" -ge "$umbral" ]` no compara — **erra**. Sin `set -e` el script
# sigue, `lado_actual` se queda en su valor inicial `bajo`, no se emite transición y se devuelve
# **rc 0**. Medido: un valor astronómico con estado previo `bajo` sale «sin cambio», que es el peor
# desenlace posible en un vigía — el único trabajo que tiene es avisar de que se cruzó el umbral, y
# el fallo de comparación se leía como «no se ha cruzado». Fail-open en la pieza que existe para
# cerrar. 18 dígitos entran siempre en 64 bits.
_ent_acotado() { case "${1-}" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 18 ]; }
_ent_acotado "$valor"  || { echo "vigia-cuota: PRECOND: --valor debe ser entero de hasta 18 digitos" >&2; exit 2; }
_ent_acotado "$umbral" || { echo "vigia-cuota: PRECOND: --umbral debe ser entero de hasta 18 digitos" >&2; exit 2; }
[ -n "$estado" ] || { echo "vigia-cuota: PRECOND: falta --estado" >&2; exit 2; }
# ── `--estado` NOMBRA UN FICHERO, Y SU NOMBRE INVITA A CONFUNDIRLO CON UN VALOR ────────────────
# Los dos lados que este vigia distingue se llaman `alto` y `bajo`, asi que `--estado bajo` se lee
# como «el estado es bajo» cuando en realidad dice «escribe el estado en el fichero ./bajo». Con una
# ruta relativa eso deja `bajo` y `bajo.lock` **en el directorio desde el que se llame**, que
# tipicamente es la raiz de un repo. No es una hipotesis: paso DOS veces el mismo dia, a dos
# operadores distintos, y los dos ficheros apareceron sin seguir en el arbol de una entrega.
# Se rechazan EXACTAMENTE los dos literales del vocabulario de estados, que es donde vive el
# equivoco. Quien de verdad quiera un fichero llamado asi escribe `./bajo` y pasa: no se prohibe el
# nombre, se prohibe la forma que se confunde con un valor.
case "$estado" in
  alto|bajo)
    echo "vigia-cuota: PRECOND: --estado nombra un FICHERO de estado, no el valor del estado" >&2
    echo "vigia-cuota: \"$estado\" es uno de los dos lados que este vigia distingue; escribir eso deja" >&2
    echo "vigia-cuota: un fichero llamado \"$estado\" en el directorio actual. Si de verdad lo quieres, usa ./$estado" >&2
    exit 2 ;;
esac
if [ -L "$estado" ]; then echo "vigia-cuota: PRECOND: fichero de estado es symlink: $estado" >&2; exit 2; fi
if [ -e "$estado" ] && [ ! -f "$estado" ]; then
  echo "vigia-cuota: PRECOND: fichero de estado no regular: $estado" >&2; exit 2; fi

lado_actual=bajo
[ "$valor" -ge "$umbral" ] && lado_actual=alto

# ── LEER, COMPARAR y PERSISTIR dentro de la MISMA seccion critica ──────────────────────────────
# Sin candado, dos ticks concurrentes leen el mismo `lado_previo`, ambos ven un cambio de lado y
# ambos emiten la MISMA transicion: la alerta se duplica y el rc 10 deja de significar "esto acaba
# de cruzar el umbral". El candado va junto al fichero de estado, con las mismas guardas que el:
# `-L` ANTES que `-f`, porque un symlink A UN FICHERO satisface `-f`.
lock="$estado.lock"
if [ -L "$lock" ]; then echo "vigia-cuota: PRECOND: el lock es symlink: $lock" >&2; exit 2; fi
if [ -e "$lock" ] && [ ! -f "$lock" ]; then
  echo "vigia-cuota: PRECOND: el lock no es regular: $lock" >&2; exit 2; fi
: > "$lock" 2>/dev/null || { echo "vigia-cuota: PRECOND: lock no creable: $lock" >&2; exit 2; }
exec 9>"$lock" || { echo "vigia-cuota: PRECOND: lock no abrible: $lock" >&2; exit 2; }
if ! flock -x -w 10 9; then
  echo "vigia-cuota: PRECOND: lock no adquirible en 10s: $lock" >&2; exit 2
fi

# Un estado ILEGIBLE no es un estado AUSENTE, y confundirlos costaba la transicion. Antes, cualquier
# contenido distinto de `alto`/`bajo` se normalizaba a '' — o sea, al caso «primer tick» — y el
# primer tick por contrato NO grita: registra y calla. Medido con el fichero conteniendo `basura`:
# `--valor 90 --umbral 80` devolvia **rc 0**, no emitia nada y **sobrescribia el estado con `alto`**,
# con lo que la transicion quedaba borrada y ningun tick posterior podia reconstruirla.
# «No se» y «no habia nada» son cosas distintas: la primera se dice, no se rellena. AUSENTE sigue
# siendo el primer tick legitimo; CORRUPTO falla cerrado sin tocar el fichero.
lado_previo=''
if [ -f "$estado" ]; then
  lado_previo="$(cat "$estado" 2>/dev/null || true)"
  case "$lado_previo" in
    alto|bajo) : ;;
    *) echo "vigia-cuota: PRECOND: el fichero de estado no dice ni \"alto\" ni \"bajo\"; NO se sobrescribe" >&2
       echo "vigia-cuota: un estado ilegible no es un primer tick: borralo tu si quieres empezar de cero" >&2
       exit 2 ;;
  esac
fi

# ── EMITIR ANTES DE PERSISTIR, Y PERSISTIR SOLO SI LA EMISION SALIO ───────────────────────────
# Antes se persistia primero y se emitia despues, fuera del candado. Eso hacia que el estado
# avanzara aunque el aviso NO llegara: medido con stdout en `/dev/full`, partiendo de `bajo`, un
# `--valor 90 --umbral 80` fallaba el `printf`, dejaba el estado en `alto` y devolvia **rc 10** —y
# el tick siguiente, ya con stdout bueno, devolvia rc 0 y **no reemitia nada**. La transicion se
# perdia PARA SIEMPRE. Un vigia que se calla para siempre es peor que no tener vigia, y el rc 10
# mentia ademas diciendo "he avisado".
# Ahora el orden es: decidir -> emitir -> comprobar que la emision salio -> persistir. Si la
# emision falla, NO se persiste y se sale con rc 2: el proximo tick vuelve a ver la misma
# transicion y la reemite. Se prefiere REPETIR a PERDER, que es la misma doctrina que el cursor
# del bus.
# La emision pasa a hacerse DENTRO del candado. Se pierde la propiedad de "no retener el lock
# mientras escribimos a un consumidor lento", y se acepta a sabiendas: es UNA linea corta, y a
# cambio se conserva la garantia de no duplicar la alerta entre dos ticks concurrentes. Soltar el
# lock antes de emitir obligaria a re-adquirirlo para persistir, y en esa ventana dos ticks pueden
# ver el mismo `lado_previo` y avisar los dos.
emitir=0
if [ -n "$lado_previo" ] && [ "$lado_previo" != "$lado_actual" ]; then emitir=1; fi

if [ "$emitir" -eq 1 ]; then
  if [ "$lado_actual" = alto ]; then
    printf 'cuota: TRANSICION bajo->alto (valor %s, umbral %s)\n' "$valor" "$umbral" || {
      echo "vigia-cuota: la emision del aviso FALLO; el estado NO se persiste y la transicion se reemitira" >&2
      exit 2; }
  else
    printf 'cuota: TRANSICION alto->bajo (valor %s, umbral %s)\n' "$valor" "$umbral" || {
      echo "vigia-cuota: la emision del aviso FALLO; el estado NO se persiste y la transicion se reemitira" >&2
      exit 2; }
  fi
fi

# Temporal con nombre IMPREDECIBLE. `$$` es el PID: un tercero puede precrear esa ruta (fichero o
# symlink) y desviar la escritura. `mktemp` en el MISMO directorio mantiene el `mv` como rename(2)
# atomico —un temporal en /tmp cruzaria filesystem y dejaria de serlo—.
tmp="$(mktemp "$(dirname -- "$estado")/.$(basename -- "$estado").XXXXXX")" || {
  echo "vigia-cuota: no se pudo crear el temporal de estado" >&2; exit 2; }
printf '%s' "$lado_actual" > "$tmp" && mv -f "$tmp" "$estado" || {
  rm -f "$tmp"; echo "vigia-cuota: no se pudo persistir el estado" >&2; exit 2; }

flock -u 9 2>/dev/null || true
exec 9>&-

[ "$emitir" -eq 1 ] || exit 0
exit 10
