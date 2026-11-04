#!/usr/bin/env bash
# perfil-render.sh — Pinta tablas legibles a partir del perfil (talent-ceo, ref 03).
#
# Repo-agnóstico, token-only, sin MCP.
#
# Uso:
#   perfil-render.sh --tabla players
#   perfil-render.sh --tabla <tipo>        # cualquiera de los nueve tipos
#   perfil-render.sh --help
#
# rc: 0 = tabla emitida · 1 = falta una fila EXIGIDA por la tabla pedida (p.ej. `pm` en players)
#     2 = PRECONDICIÓN: sin perfil o perfil inválido.
#
# ── EL PM SE LEE DE SU FILA. NUNCA SE INFIERE. ─────────────────────────────────────────────────
# La fila `ceo` puede declarar `roles=...pm_interino...`, y es tentador deducir de ahí quién es el
# PM cuando falta la fila `pm`. Está PROHIBIDO: quién ejerce un rol es un hecho de la topología,
# no una deducción sobre una cadena de texto. Sin fila `pm` => rc 1 y el consumidor aborta.
# Un PM inferido es un mando inventado.
#
# El PM legítimamente puede no tener pane (`sesion` = `-` o `ninguna`): eso se pinta «sin pane»,
# que NO es lo mismo que "no hay PM".
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib-perfil.sh"


# Un `shift 2` con la opcion como ULTIMO argumento no desplaza nada (rc != 0) y, sin `set -e`, el
# bucle vuelve a leer el mismo `$1`: BUCLE INFINITO. Se exige el valor ANTES de desplazar.
_exige_valor(){ [ "$1" -ge 2 ] || { printf '%s: PRECOND: %s exige un valor\n' "${0##*/}" "$2" >&2; exit 2; }; }

tabla=''
while [ $# -gt 0 ]; do
  case "$1" in
    --tabla) _exige_valor $# "$1"; tabla="${2-}"; shift 2 ;;
    --help)  sed -n '2,21p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "perfil-render: argumento desconocido: $1" >&2; exit 2 ;;
  esac
done
[ -n "$tabla" ] || { echo "perfil-render: PRECOND: falta --tabla" >&2; exit 2; }

pinta_sesion() {  # «sin pane» explícito: un hueco ambiguo se lee como dato que falta
  case "${1-}" in ''|'-'|ninguna) printf 'sin pane' ;; *) printf '%s' "$1" ;; esac
}

# ── UN CAMPO DEL PERFIL NO PUEDE MANDAR SOBRE EL TERMINAL ──────────────────────────────────────
# El perfil es un fichero de texto que alguien edita, y estas columnas se imprimen TAL CUAL. Un
# `id` que llevara `ESC[2J` pasaba `--check` con rc 0 —el contrato valida ESTRUCTURA, no que los
# campos sean inertes— y al pintar la tabla borraba la pantalla: la propia tabla de mando queda a
# merced del dato que muestra. Se neutraliza el CONTROL, que es lo que ejecuta el terminal; lo que
# quede se pinta tal cual, porque esta herramienta no inventa valores ni los recorta en silencio.
#
# LO QUE ESTO **NO** HACE, y va dicho: no rechaza el perfil. Que el VALIDADOR deba exigir campos
# inertes —una V10— es un cambio del CONTRATO, no de este renderizador. Se escaló en vez de
# decidirse aquí, y el CEO lo zanjó: NO hay V10 en esta pieza. La limitación queda DECLARADA en la
# ref 04 con su condición de cierre; la superficie observable, cerrada aquí.
# `tr -d '[:cntrl:]'` cubre C0 y DEL, NO los C1 (0x80-0x9F) — y entre esos esta el CSI de 8 bits
# `0x9B`, que hace de `ESC [` en un terminal que los interprete. No se borran por rango: en UTF-8
# esos bytes son CONTINUACION de caracteres legitimos, y borrarlos partiria cualquier acento. El
# corte correcto es «no es UTF-8 valido», que es lo que hace `iconv -c`. Sin `iconv` se pierde la
# cobertura de C1 y se dice, no se finge.
inerte() {
  local v="${1-}"
  # Si NO es UTF-8 valido, un byte 0x80-0x9F no es continuacion de nada: se traduce a su forma de
  # 7 bits para que caiga con el resto de los controles. Si lo es, no hay C1 suelto que traducir y
  # traducir a ciegas partiria acentos y guiones. Despues, `iconv -c` barre lo que siga invalido.
  # RESIDUO DECLARADO, y es mio por no haberlo escrito antes: la condicion se evalua sobre la
  # cadena ENTERA. Si es invalida por un motivo AJENO —un `0xFF` suelto, por ejemplo— la traduccion
  # se aplica igual y ahi si puede partir un caracter legitimo cuya continuacion caiga en
  # 0x80-0x9F. Se acepta a sabiendas: solo ocurre sobre entrada YA invalida, y la alternativa —no
  # traducir— deja secuencias de escape EJECUTABLES a la vista, que es peor. Cerrarlo del todo pide
  # una pasada consciente de UTF-8 byte a byte, que no cabe en el juego de herramientas de este
  # paquete sin añadir dependencia: esa es su condicion de cierre.
  # SIN `iconv` esto NO se podia decidir, y lo que se hacia era seguir sin traducir: el `0x9b`
  # crudo llegaba INTACTO a stdout y el terminal lo ejecutaba. Medido con un PATH funcional pero sin
  # `iconv`: `perfil-render --tabla cron` con un `id` que lleva `0x9b 2J` salia con **rc 0** y el
  # byte dentro. Un fail-open silencioso que ademas dependia de que una herramienta estuviera
  # instalada — y esta funcion existe justo para que un campo del perfil no mande sobre el terminal.
  # Ahora, sin `iconv`, se traduce igual, con el precio DECLARADO: sobre texto valido con bytes en
  # esa banda (el «—» es `e2 80 94`) el valor puede salir DAÑADO. Texto dañado SE VE; un CSI
  # ejecutado, no.
  _c1_crudos=0
  if command -v iconv >/dev/null 2>&1; then
    printf '%s' "$v" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || _c1_crudos=1
  else
    _c1_crudos=1
  fi
  if [ "$_c1_crudos" -eq 1 ]; then
    # DOS pasos, y el segundo faltaba. El primero traduce los SIETE C1 que son INTRODUCTORES, para
    # que las reglas de gramatica de abajo se lleven la secuencia entera y no solo el byte. El
    # segundo barre **el resto de la banda 0x80-0x9F**, que la primera version dejaba CRUDA: medido
    # con un PATH sin `iconv`, `X 0x85 Y` salia con sus tres bytes (`58 85 59`) y una captura formada
    # solo por 0x85 se clasificaba **`text`** — NEL es un control de terminal como el CSI, y ahi
    # estaba llegando entero a la salida. Traducir siete y olvidar los otros veinticinco es el medio
    # arreglo de siempre: cerrar la puerta que se esta mirando y dejar la de al lado.
    # Este barrido a lo bruto solo corre en esta rama —entrada YA invalida, o sin `iconv` para
    # decidirlo— donde el precio (texto danado) esta declarado y es el lado bueno del intercambio.
    v="$(printf '%s' "$v" | LC_ALL=C sed -e 's/\x9b/\x1b[/g; s/\x9d/\x1b]/g; s/\x90/\x1bP/g; s/\x98/\x1bX/g; s/\x9e/\x1b^/g; s/\x9f/\x1b_/g; s/\x9c/\x1b\\/g' -e 's/[\x80-\x9f]//g')"
  fi
  if command -v iconv >/dev/null 2>&1; then v="$(printf '%s' "$v" | iconv -c -f UTF-8 -t UTF-8)"; fi
  # Y los C1 en su forma UTF-8 VALIDA (`c2 80`..`c2 9f`): U+009B ES el CSI y un terminal en UTF-8
  # lo interpreta igual, pero `[:cntrl:]` no lo ve y `iconv` no lo descarta porque esta bien
  # codificado. Se quita la banda de codepoints, que no aparece en texto legible.
  printf '%s' "$v" | LC_ALL=C sed 's/\xc2[\x80-\x9f]//g' | tr -d '[:cntrl:]'
}

# ── pad <texto> <ancho> — rellenar contando CARACTERES, no bytes ───────────────────────────────
# `printf '%-14s'` mide BYTES. Un `id` con una tilde ocupa dos bytes y una celda visible, así que
# recibe un espacio de menos y **desplaza todas las columnas siguientes de esa fila**: la tabla
# cuyo único oficio es leerse de un vistazo deja de estar alineada justo en las filas con acentos.
# Es el mismo defecto que `lib-tablas.sh` ya tenía resuelto para las tablas por cron; aquí faltaba.
# La cuenta no puede fiarse de `${#s}` a secas porque eso depende del locale DEL LLAMANTE (bajo
# `LC_ALL=C` vuelve a contar bytes). Se descartan los bytes de continuación de UTF-8 (`0x80-0xBF`)
# bajo `LC_ALL=C` y se cuenta lo que queda: un byte por carácter, dé igual quién llame.
# Se duplica aquí en vez de importar `lib-tablas.sh` a propósito: este script sólo necesita rellenar
# y no las reglas de «celda sin fuente» de aquel; hacerlos depender el uno del otro por cuatro
# líneas ataría un renderizador de perfil al renderizador de capturas de pane.
pad() {
  local s="${1-}" ancho="${2-0}" n
  local LC_ALL=C
  local sin_cont="${s//[$'\x80'-$'\xbf']/}"
  n=${#sin_cont}
  printf '%s' "$s"
  [ "$n" -ge "$ancho" ] || printf '%*s' "$((ancho - n))" ''
}

if [ "$tabla" = players ]; then
  perfil_validate >/dev/null 2>&1 || { echo "perfil-render: PRECOND: sin perfil válido" >&2; exit 2; }
  printf '%-8s %-14s %-10s %-24s %s\n' 'ROL' 'ID' 'MAQUINA' 'CONTENEDOR' 'SESION'
  for rol in ceo pm; do
    fila="$(perfil_row1 "$rol")"; rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "perfil-render: falta la fila \"$rol\" en el perfil; NO se infiere de ningún otro rol" >&2
      exit 1
    fi
    # Misma neutralizacion que en la otra rama: estas cuatro columnas tambien salen del perfil.
    pad "$rol" 8; printf ' '
    pad "$(inerte "$(printf '%s' "$fila" | cut -f2)")" 14; printf ' '
    pad "$(inerte "$(printf '%s' "$fila" | cut -f3)")" 10; printf ' '
    pad "$(inerte "$(printf '%s' "$fila" | cut -f4)")" 24; printf ' '
    printf '%s\n' "$(pinta_sesion "$(inerte "$(printf '%s' "$fila" | cut -f5)")")"
  done
  exit 0
fi

filas="$(perfil_rows "$tabla")"; rc=$?
case "$rc" in
  0) : ;;
  1) echo "perfil-render: cero filas de tipo \"$tabla\"" >&2; exit 1 ;;
  *) echo "perfil-render: PRECOND: sin perfil válido" >&2; exit 2 ;;
esac
printf '%-14s %-10s %-24s %s\n' 'ID' 'MAQUINA' 'CONTENEDOR' 'SESION'
# `perfil_campos`, no `IFS=$'\t' read`: el tabulador es IFS-whitespace y las celdas vacias se
# colapsan, corriendo el resto una columna. En una tabla de mando eso no da un error: pinta el
# CONTENEDOR debajo de MAQUINA y la fila se lee como si fuera cierta. El detalle, en `lib-perfil.sh`.
# (Los `cut -f` de la rama `players`, ahi arriba, SI conservan los vacios y por eso se quedan.)
printf '%s\n' "$filas" | while IFS= read -r fila; do
  perfil_campos "$fila"
  pad "$(inerte "${PERFIL_CAMPOS[1]-}")" 14; printf ' '
  pad "$(inerte "${PERFIL_CAMPOS[2]-}")" 10; printf ' '
  pad "$(inerte "${PERFIL_CAMPOS[3]-}")" 24; printf ' '
  printf '%s\n' "$(pinta_sesion "$(inerte "${PERFIL_CAMPOS[4]-}")")"
done
exit 0
