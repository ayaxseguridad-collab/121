#!/usr/bin/env bash
# ronda-canales.sh — Clasifica el estado del composer de un canal (talent-ceo, ref 03).
#
# Repo-agnóstico, token-only, sin MCP. El parser es PURO: recibe la captura por stdin y no habla
# con tmux — así se puede probar sin una terminal viva, que es la única forma de probarlo de verdad.
#
# Uso:
#   ronda-canales.sh --clasificar < captura.txt
#   ronda-canales.sh --help
#
# Emite UNA palabra: empty | ghost | text | queued
# rc: 0 = clasificado · 2 = precondición (sin stdin).
#
# ── LOS CUATRO ESTADOS, Y POR QUÉ «ghost» NO ES «text» ─────────────────────────────────────────
#   empty   composer vacío: el canal está libre.
#   ghost   hay texto, pero es el PLACEHOLDER del composer — tramo en atenuado (\e[2m). No es una
#           orden de nadie: es el texto gris que la propia interfaz pinta cuando no hay nada.
#           Confundirlo con `text` hace creer que un canal tiene trabajo cuando está ocioso; y peor,
#           invita a "obedecer" un texto que nadie escribió.
#   text    hay texto real escrito y sin enviar.
#   queued  hay texto y además señal de envío/ejecución en curso.
# Criterio de `ghost` tomado de talent-context (ref 04): el tramo atenuado, no la ausencia de letras.
set -uo pipefail

clasificar() {
  local captura="${1-}"
  # Sin contenido visible => empty. Se mira el texto ya SIN secuencias de escape.
  # El `tr -d '[:cntrl:]'` NO sobra: un ESC suelto —sin secuencia detras— no lo quita ninguna
  # sustitucion, y `tr -d '[:space:]'` tampoco, asi que una captura formada solo por eso se
  # clasificaba `text` en vez de `empty`: un canal vacio contado como canal con trabajo.
  # La expresion es LA MISMA que usa `lib-tablas.sh` sobre esta misma clase de captura, y hay un
  # caso de la suite que lo exige por igualdad de TEXTO: dos limpiezas distintas del mismo formato
  # divergen, y la que menos se mira se queda corta. Cubre las CADENAS (`ESC ] P X ^ _` … BEL/ST:
  # OSC, DCS, SOS, PM, APC — si se tratan como escapes de dos caracteres, la CARGA queda visible),
  # el CSI con sus privados, y los escapes sueltos de dos caracteres; `LC_ALL=C` porque los rangos
  # de clase se interpretan por COLACION y bajo `en_US.UTF-8` el rango `[@-~]` no casa `m` (medido).
  # `limpio` conserva los espacios y `plano` no: hacen falta los dos. Las senales de estado
  # ("Pasted Content", "esc to interrupt") LLEVAN espacios, asi que se buscan en `limpio`; para
  # decidir si hay contenido visible se usa `plano`.
  # `iconv -c` descarta lo que no es UTF-8 valido, y ahi caen los C1 sueltos (0x80-0x9F): el CSI de
  # 8 bits `0x9B` hace de `ESC [` y `tr -d '[:cntrl:]'` NO lo quita —esa clase es C0 mas DEL—. No se
  # borran por rango porque en UTF-8 esos bytes son CONTINUACION de caracteres legitimos.
  local limpio plano
  # Mismo corte que en `lib-tablas.sh`: si la captura NO es UTF-8 valida, un byte 0x80-0x9F no es
  # continuacion de nada y se traduce a su forma de 7 bits, para que las reglas se lleven la
  # secuencia ENTERA y no solo el introductor. Si lo es, no hay C1 suelto que traducir.
  # RESIDUO DECLARADO, y es mio por no haberlo escrito antes: la condicion se evalua sobre la
  # cadena ENTERA. Si es invalida por un motivo AJENO —un `0xFF` suelto, por ejemplo— la traduccion
  # se aplica igual y ahi si puede partir un caracter legitimo cuya continuacion caiga en
  # 0x80-0x9F. Se acepta a sabiendas: solo ocurre sobre entrada YA invalida, y la alternativa —no
  # traducir— deja secuencias de escape EJECUTABLES a la vista, que es peor. Cerrarlo del todo pide
  # una pasada consciente de UTF-8 byte a byte, que no cabe en el juego de herramientas de este
  # paquete sin añadir dependencia: esa es su condicion de cierre.
  # LOS C1 EN SU FORMA UTF-8 **VALIDA** (`c2 80`..`c2 9f`) — se traducen SIEMPRE, y van los
  # PRIMEROS. `c2 9b` ES U+009B, o sea el CSI: un terminal en UTF-8 lo ejecuta igual que `ESC [`.
  # `iconv` no los descarta (estan BIEN codificados), `[:cntrl:]` no los ve y las reglas de
  # gramatica de abajo buscan `\x1b`, asi que la secuencia entera pasaba INTACTA a la salida.
  # Medido: `c2 9b 32 4a` llegaba a la celda con sus cuatro bytes. Se traducen ANTES de la
  # gramatica para que esta se lleve la SECUENCIA COMPLETA — quitar el introductor y dejar los
  # parametros es el medio arreglo que ya se colo una vez en este mismo fichero.
  captura="$(printf '%s' "$captura" | LC_ALL=C sed -e 's/\xc2\x9b/\x1b[/g; s/\xc2\x9d/\x1b]/g; s/\xc2\x90/\x1bP/g; s/\xc2\x98/\x1bX/g; s/\xc2\x9e/\x1b^/g; s/\xc2\x9f/\x1b_/g; s/\xc2\x9c/\x1b\\/g')"
  # Y LOS C1 CRUDOS (un `0x9b` suelto). Aqui hace falta saber si la cadena es UTF-8 valida, porque
  # en UTF-8 esos bytes son CONTINUACION de caracteres legitimos y traducirlos a ciegas partiria un
  # acento o el propio «—» (`e2 80 94`).
  _c1_crudos=0
  if command -v iconv >/dev/null 2>&1; then
    printf '%s' "$captura" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || _c1_crudos=1
  else
    # SIN `iconv` no se puede decidir. Antes se seguia SIN traducir y el byte llegaba intacto al
    # terminal, que lo ejecuta: **fail-open silencioso en el renderizador de mando**, y encima
    # dependiente de que una herramienta este instalada. Se traduce igual y se declara el precio:
    # sobre texto valido con bytes en esa banda (`—` entre ellos) la celda puede salir DAÑADA.
    # Es el intercambio deliberado: texto dañado SE VE; un CSI ejecutado, no.
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
    captura="$(printf '%s' "$captura" | LC_ALL=C sed -e 's/\x9b/\x1b[/g; s/\x9d/\x1b]/g; s/\x90/\x1bP/g; s/\x98/\x1bX/g; s/\x9e/\x1b^/g; s/\x9f/\x1b_/g; s/\x9c/\x1b\\/g' -e 's/[\x80-\x9f]//g')"
  fi
  if command -v iconv >/dev/null 2>&1; then captura="$(printf '%s' "$captura" | iconv -c -f UTF-8 -t UTF-8)"; fi
  limpio="$(printf '%s' "$captura" | LC_ALL=C sed -E 's#\x1b\][^\x07\x1b\x18\x1a]*(\x07|\x1b\\)##g; s#\x1b[PX^_][^\x1b\x18\x1a]*\x1b\\##g; s#\x1b[]PX^_][^\x1b\x18\x1a]*[\x18\x1a]##g; s#\x1b[]PX^_].*$##; s#\x1b\[[0-9:;<=>?]*[ -/]*[@-~]##g; s#\x1b\[[0-9:;<=>?]*[ -/]*[\x18\x1a]##g; s#\x1b\[[0-9:;<=>?]*[ -/]*$##; s#\x1b[ -/]+[0-~]##g; s#\x1b[ -/]*[\x18\x1a]##g; s#\x1b[ -/]+$##; s#\x1b[@-~]##g' | LC_ALL=C sed 's/\xc2[\x80-\x9f]//g' | tr -d '[:cntrl:]')"
  plano="$(printf '%s' "$limpio" | tr -d '[:space:]')"
  # TERCERA aparicion del mismo patron, que el hallazgo no nombraba: `printf | grep -q` bajo
  # `set -uo pipefail`. LO QUE ESTA MEDIDO, dicho con precision: el MECANISMO se reproduce en aislado
  # —un `if printf '%s' "$grande" | grep -q <senal>` con 200 KB por delante NO entra aunque la senal
  # este ahi, porque `grep -q` sale al casar, `printf` muere por SIGPIPE (141) y `pipefail` hace que
  # la tuberia devuelva 141—. Lo que NO se ha conseguido reproducir es que aflore por ESTA puerta:
  # con capturas de 300 KB la clasificacion sale correcta. Se cierra igual, por la clase y no por el
  # sintoma, porque el desenlace seria de los caros: un placeholder contado como texto real es
  # «obedecer un texto que no escribio nadie», que es lo que la ref 03 prohibe.
  # (Un intento anterior de este comentario afirmaba haberlo reproducido aqui. Era falso: el fixture
  # ponia 300 KB de texto VISIBLE fuera del tramo atenuado, con lo que `text` era la respuesta
  # correcta. Queda escrito para que nadie lo tome por un rojo que nunca fue.)
  case "$captura" in
    *$'\x1b'\[2m*)
    # Atenuado presente: es el placeholder salvo que haya, ADEMÁS, texto fuera del tramo atenuado.
    local sin_atenuado
    # Primero se recorta el TRAMO atenuado —esa expresion es especifica de este criterio y no se
    # comparte—, y luego se limpia lo que quede con la MISMA limpieza general de arriba.
    sin_atenuado="$(printf '%s' "$captura" | sed -E $'s/\x1b\\[2m[^\x1b]*(\x1b\\[0?m)?//g' \
                    | LC_ALL=C sed -E 's#\x1b\][^\x07\x1b\x18\x1a]*(\x07|\x1b\\)##g; s#\x1b[PX^_][^\x1b\x18\x1a]*\x1b\\##g; s#\x1b[]PX^_][^\x1b\x18\x1a]*[\x18\x1a]##g; s#\x1b[]PX^_].*$##; s#\x1b\[[0-9:;<=>?]*[ -/]*[@-~]##g; s#\x1b\[[0-9:;<=>?]*[ -/]*[\x18\x1a]##g; s#\x1b\[[0-9:;<=>?]*[ -/]*$##; s#\x1b[ -/]+[0-~]##g; s#\x1b[ -/]*[\x18\x1a]##g; s#\x1b[ -/]+$##; s#\x1b[@-~]##g' | LC_ALL=C sed 's/\xc2[\x80-\x9f]//g' | tr -d '[:cntrl:]' | tr -d '[:space:]')"
    if [ -z "$sin_atenuado" ]; then printf 'ghost\n'; return 0; fi
    ;;
  esac
  [ -n "$plano" ] || { printf 'empty\n'; return 0; }
  # Las senales se buscan en el texto LIMPIO, no en la captura cruda. Buscarlas en cruda contaba
  # como senal la carga INVISIBLE de una secuencia: `hola ESC]0;Working BEL` es un pane cuyo unico
  # texto visible es «hola», y salia `queued` porque «Working» iba dentro del titulo de la ventana.
  # Una senal que el operador no puede ver no es una senal: es el titulo de otra cosa.
  # CUARTA aparicion. Aqui no se ha conseguido reproducir el fallo —se dice, no se finge—, pero el
  # constructo es el mismo y su direccion de fallo es la CARA: un canal ocupado leido como `text` se
  # despacha ENCIMA de un trabajo en curso. Se cierra la clase entera, no los dos sitios que se vieron.
  case "$limpio" in
    *Working*|*'Pasted Content'*|*'esc to interrupt'*)
    printf 'queued\n'; return 0 ;;
  esac
  printf 'text\n'
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1-}" in
    --clasificar)
      [ ! -t 0 ] || { echo "ronda-canales: PRECOND: se espera la captura por stdin" >&2; exit 2; }
      clasificar "$(cat)"; exit 0 ;;
    --help|'') sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "ronda-canales: argumento desconocido: ${1}" >&2; exit 2 ;;
  esac
fi
