#!/usr/bin/env bash
# lib-tablas.sh — Render de las dos tablas periódicas desde capturas (talent-ceo, ref 03).
#
# Se "source-ea" (`. lib-tablas.sh`). Repo-agnóstico, token-only, sin MCP.
#
# ── LA REGLA DE ORO DE ESTE FICHERO ────────────────────────────────────────────────────────────
# Si falta la fuente de una celda se pinta «—». JAMÁS un valor inventado, y jamás un blanco.
# El blanco es peor que el guion: se lee como "cero", "vacío" o "todo bien", según quien mire, y
# nadie pregunta. El «—» dice exactamente una cosa: *aquí no hubo dato*. Una tabla de mando cuyo
# hueco se pueda confundir con un valor es una tabla que miente sin que nadie la acuse.
set -uo pipefail

TABLAS_VACIO='—'

# tabla_celda <valor> — normaliza una celda: vacío o solo espacios => «—».
# Las celdas de estas tablas vienen de CAPTURAS DE PANE, y una captura trae secuencias ANSI. Una
# secuencia es texto que NO se ve pero SI se cuenta: `tabla_pad` mide con `${#s}`, asi que una celda
# coloreada se rellena como si midiera trece caracteres cuando en pantalla mide cuatro, y la fila
# sale desalineada — en la tabla cuyo unico oficio es leerse de un vistazo. Es la capa siguiente del
# mismo sitio que ya paso de contar BYTES a contar CARACTERES: contar caracteres tambien miente
# cuando el caracter es invisible.
# Se limpian, no se rechazan: esto es un renderizador y su regla es pintar algo honesto. Una
# secuencia ANSI no es dato, es presentacion, asi que quitarla no inventa nada; si tras quitarla no
# queda nada, se pinta «—», que es justo lo que la regla de oro pide.
# `ronda-canales.sh` ya limpiaba ANSI antes de clasificar la MISMA captura: aqui faltaba.
tabla_celda() {
  local v="${1-}"
  # La expresion es LA MISMA que usa `ronda-canales.sh` sobre la misma clase de captura, a
  # proposito: dos formas distintas de quitar ANSI en el mismo paquete acaban divergiendo, y la
  # que menos se mira es la que se queda corta. Hay un caso de la suite que lo exige por igualdad
  # de texto, no de intencion.
  #
  # Cubre las TRES clases, no solo el color:
  #   CADENAS  introductor, CARGA y final. Tratarlas como escapes de dos caracteres quitaba el
  #            introductor y **dejaba la carga visible** — `ESC P abc ST` salia como `abc`, texto
  #            que nadie escribio en la celda. Van en DOS reglas y no en una, porque el terminador
  #            NO es el mismo: **solo OSC admite BEL** (extension de xterm); DCS, SOS, PM y APC
  #            terminan **solo con ST**. Con una regla comun, un BEL dentro de la carga de un DCS
  #            cortaba la limpieza antes de tiempo y el resto de la carga salia a la celda.
  #   CSI      `ESC [` + PARAMETROS `0x30-0x3F` + INTERMEDIOS `0x20-0x2F` + FINAL `0x40-0x7E`.
  #            Las clases van por la gramatica de ECMA-48 y no a ojo: la primera version escribio
  #            `[ -\/]` creyendo que era «espacio a barra», pero en un bracket POSIX la `\` NO
  #            escapa, asi que se leia como el rango ` `..`\` MAS `/` — y con `ESC[Afoo` se comia
  #            la `A` de intermedio y la `f` de final, devolviendo `oo`: **borraba texto legitimo
  #            de la celda**. El delimitador de `sed` es `#` para que `/` no necesite escaparse.
  #   nF       `ESC` + INTERMEDIOS `0x20-0x2F` + final `0x30-0x7E` — la seleccion de juego de
  #            caracteres (`ESC ( B`) es de esta familia y **no la cubria ninguna regla**: salia
  #            como `(B` en la celda. No es exotica: la emite cualquier terminal al resetearse.
  #   Fe / Fs  `ESC` + un solo byte `0x40-0x7E` (incluye `ESC c`, el reset)
  # Y TODA secuencia ABORTADA lleva la suya. En ECMA-48, CAN (0x18) y SUB (0x1A) CANCELAN la
  # secuencia abierta: el terminal la descarta y sigue pintando lo que venga DESPUES. Sin regla,
  # `tr -d '[:cntrl:]'` se llevaba el byte de control y dejaba los PARAMETROS de texto en la celda
  # (`ESC[31 CAN m` -> `31m`, cuando lo correcto es `m`). Y en la familia de CADENAS no era residuo
  # sino PERDIDA: la regla de truncado es greedy hasta el final, asi que `ESC]0;titulo CAN rojo` se
  # llevaba tambien `rojo` y la celda salia «—» — la tabla diciendo "aqui no hubo dato" donde SI lo
  # habia, que es justo lo que la regla de oro prohibe. Las tres reglas de aborto van ANTES de sus
  # reglas de truncado por eso: si la greedy corre primero, no queda nada que abortar.
  # Y TODA secuencia TRUNCADA —la captura se corto por medio— lleva su regla: cadena sin BEL/ST,
  # CSI sin byte final (`ESC[31`) y nF sin final (`ESC(`). No es un caso de laboratorio: una
  # captura de pane se corta por donde se corta. Sin esas tres reglas quedaba residuo VISIBLE
  # (`31`, `(`, `0;titulo`), que es la misma mentira contada en trozos mas pequenos: una captura
  # cortada convierte presentacion invisible en contenido visible.
  # Quitar solo el color dejaba `[?25l` y `]0;titulo` VISIBLES: no es que faltara limpieza, es que
  # el texto sobrante falsea el contenido Y el ancho.
  #
  # `LC_ALL=C` NO es adorno: los rangos de las clases se interpretan por COLACION, y bajo
  # `en_US.UTF-8` el rango `[@-~]` no casa `m`. Medido: la misma expresion limpia o no limpia
  # segun el locale de quien llame. Un control que depende del entorno del llamante no es un
  # control. El `tr` posterior barre lo que quede suelto por CLASE, no por enumeracion.
  # `iconv -c` va PRIMERO y no es adorno: descarta lo que no es UTF-8 valido, y ahi caen los
  # controles C1 sueltos (0x80-0x9F) — entre ellos el CSI de 8 bits `0x9B`, que hace de `ESC [`
  # en un terminal que los interprete. `tr -d '[:cntrl:]'` NO los quita: esa clase es C0 mas DEL.
  # Y NO se pueden borrar por rango a lo bruto: en UTF-8 esos bytes son CONTINUACION de caracteres
  # legitimos — el propio «—» es `e2 80 94`, con un 0x80 dentro. Borrarlos partiria el guion que
  # esta funcion existe para pintar. Por eso el corte es «no es UTF-8 valido», no «esta en el rango».
  # Si no hay `iconv`, se sigue sin el: se pierde la cobertura de C1 y se dice, no se finge.
  # Los controles C1 (0x80-0x9F) hacen de introductor igual que sus equivalentes de 7 bits: `0x9B`
  # ES `ESC [`. Quitarlos con `iconv -c` dejaba el INTRODUCTOR fuera y **los parametros dentro**
  # (`0x9B 2 J` salia como `2J`): medio arreglo, que es peor que ninguno porque parece hecho.
  # Tampoco se traducen a ciegas: en UTF-8 esos bytes son CONTINUACION de caracteres legitimos —el
  # guion largo es `e2 80 94`, `ñ` es `c3 b1`—, asi que traducirlos siempre partiria el texto.
  # El corte es la VALIDEZ: si la cadena es UTF-8 valida, un byte 0x80-0x9F no puede estar suelto y
  # no hay nada que traducir; si NO lo es, ahi ese byte no es continuacion de nada y se traduce a su
  # forma de 7 bits para que las reglas de abajo se lleven la secuencia ENTERA.
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
  v="$(printf '%s' "$v" | LC_ALL=C sed -e 's/\xc2\x9b/\x1b[/g; s/\xc2\x9d/\x1b]/g; s/\xc2\x90/\x1bP/g; s/\xc2\x98/\x1bX/g; s/\xc2\x9e/\x1b^/g; s/\xc2\x9f/\x1b_/g; s/\xc2\x9c/\x1b\\/g')"
  # Y LOS C1 CRUDOS (un `0x9b` suelto). Aqui hace falta saber si la cadena es UTF-8 valida, porque
  # en UTF-8 esos bytes son CONTINUACION de caracteres legitimos y traducirlos a ciegas partiria un
  # acento o el propio «—» (`e2 80 94`).
  _c1_crudos=0
  if command -v iconv >/dev/null 2>&1; then
    printf '%s' "$v" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || _c1_crudos=1
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
    v="$(printf '%s' "$v" | LC_ALL=C sed -e 's/\x9b/\x1b[/g; s/\x9d/\x1b]/g; s/\x90/\x1bP/g; s/\x98/\x1bX/g; s/\x9e/\x1b^/g; s/\x9f/\x1b_/g; s/\x9c/\x1b\\/g' -e 's/[\x80-\x9f]//g')"
  fi
  if command -v iconv >/dev/null 2>&1; then v="$(printf '%s' "$v" | iconv -c -f UTF-8 -t UTF-8)"; fi
  v="$(printf '%s' "$v" \
       | LC_ALL=C sed -E 's#\x1b\][^\x07\x1b\x18\x1a]*(\x07|\x1b\\)##g; s#\x1b[PX^_][^\x1b\x18\x1a]*\x1b\\##g; s#\x1b[]PX^_][^\x1b\x18\x1a]*[\x18\x1a]##g; s#\x1b[]PX^_].*$##; s#\x1b\[[0-9:;<=>?]*[ -/]*[@-~]##g; s#\x1b\[[0-9:;<=>?]*[ -/]*[\x18\x1a]##g; s#\x1b\[[0-9:;<=>?]*[ -/]*$##; s#\x1b[ -/]+[0-~]##g; s#\x1b[ -/]*[\x18\x1a]##g; s#\x1b[ -/]+$##; s#\x1b[@-~]##g' \
       | LC_ALL=C sed 's/\xc2[\x80-\x9f]//g' | tr -d '[:cntrl:]' \
       | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  if [ -z "$v" ]; then printf '%s' "$TABLAS_VACIO"; else printf '%s' "$v"; fi
}

# tabla_pad <texto> <ancho> — rellena a la derecha contando CARACTERES, no bytes.
# `printf '%-*s'` cuenta BYTES: con «—» (3 bytes en UTF-8) la columna sale corta y la tabla se
# desalinea justo en las celdas SIN dato, que son las que hay que ver.
#
# Y `${#s}` a secas TAMPOCO vale: cuenta caracteres **según el locale del llamante**, así que bajo
# `LC_ALL=C` —el locale de la propia suite, y el de cualquier cron sin `LANG`— vuelve a contar
# bytes y la tabla se desalinea exactamente igual. Es la MISMA lección que ya está escrita para los
# rangos de la limpieza ANSI: *lo que depende del entorno de quien llama no es un control*. Aquí la
# medida del ancho dependía de él.
# Se cuenta sin depender del locale: bajo `LC_ALL=C` se descartan los bytes de CONTINUACIÓN de
# UTF-8 (`0x80-0xBF`) y se cuenta lo que queda — un byte por carácter. `local LC_ALL=C` se restaura
# al volver, medido. (Lo que se cuenta son CARACTERES, no columnas de pantalla: un glifo de doble
# ancho sigue contando uno. Es el mismo criterio que antes, ahora estable.)
tabla_pad() {
  local s="${1-}" ancho="${2-18}" n
  local LC_ALL=C
  local sin_cont="${s//[$'\x80'-$'\xbf']/}"
  n=${#sin_cont}
  printf '%s' "$s"
  if [ "$n" -lt "$ancho" ]; then printf '%*s' "$((ancho - n))" ''; fi
}

# tabla_cabecera <col...> — imprime la cabecera y su regla.
tabla_cabecera() {
  local col ancho=18 linea=''
  for col in "$@"; do tabla_pad "$col" "$ancho"; printf ' '; linea="$linea$(printf '%*s' "$ancho" '' | tr ' ' '-') "; done
  printf '\n%s\n' "$linea"
}

# tabla_fila <col...> — imprime una fila normalizando CADA celda.
tabla_fila() {
  local col ancho=18
  for col in "$@"; do tabla_pad "$(tabla_celda "$col")" "$ancho"; printf ' '; done
  printf '\n'
}

# tabla_desde_stdin <cabecera...> — lee líneas TSV por stdin y pinta la tabla.
#
#   rc 0 = ninguna fila traía más campos que columnas tiene la cabecera.
#   rc 1 = al menos una sí. La tabla se pinta ENTERA igual; el rc es la señal para quien automatice.
#
# Una línea con MENOS campos que la cabecera NO se descarta: se completa con «—», porque
# descartarla escondería que la captura vino corta, que es justo lo que hay que ver.
#
# ── EL CASO CONTRARIO, QUE ESTUVO ROTO Y ERA EL PEOR DE LOS DOS ────────────────────────────────
# Una línea con MÁS campos que la cabecera se recortaba a la anchura de ésta y lo que sobraba
# desaparecía SIN RUIDO. Medido contra el código anterior:
#     printf 'a\tb\tc\tSECRETO\n' | tabla_desde_stdin UNO DOS TRES
#       ->  «a   b   c»  ·  rc=0  ·  stderr VACIO  ·  `SECRETO` no aparece por ningun sitio
# Eso no es un defecto de formato: es PÉRDIDA SILENCIOSA DE DATOS en el panel con el que se decide,
# y burla la regla de oro de la cabecera de este fichero por la puerta de atrás — la regla cubría el
# HUECO («—») y no cubría el SOBRANTE. Y un campo de más nunca es ruido: significa que la captura no
# tiene la forma que el llamante cree. O la fuente cambió de formato, o la cabecera se quedó corta,
# o hay un tabulador dentro de una celda. Las tres son noticia, y las tres salían con cara de fila
# normal.
#
# Se arregla MOSTRANDO Y AVISANDO, ni recortando ni abortando, y cada pieza tiene su motivo:
#   - la fila se pinta ENTERA, con sus campos de más. Recortar en silencio era el defecto; recortar
#     CON aviso seguiría perdiendo el dato y obligaría a volver a la captura cruda para saber qué
#     decía. Lo que sobra sale más allá de la última columna de la cabecera, que es justo donde se
#     ve que sobra.
#   - el aviso va a STDERR y no a stdout, porque stdout ES la tabla: una queja ahí la deformaría.
#   - el rc se devuelve al FINAL, con la tabla ya pintada. Abortar en la primera fila ancha dejaría
#     sin ver todas las siguientes: cambiar una ceguera por otra no es arreglarlo.
tabla_desde_stdin() {
  local -a cab=("$@")
  local n="${#cab[@]}" linea i nl=0 anchas=0 total
  tabla_cabecera "${cab[@]}"
  # `|| [ -n "$linea" ]`: sin eso, una captura que NO termina en salto de linea PIERDE su ultima
  # fila. `read` carga el texto y devuelve falso al topar con EOF, asi que el cuerpo del bucle no
  # llega a ejecutarse — y la fila desaparece **sin ruido**, que es la peor forma de perder un dato
  # en una tabla de mando. Una captura de pane no tiene por que acabar en LF: depende de donde se
  # corte. Es la misma regla de oro de este fichero: lo que falta se ve o no ha pasado nada.
  while IFS= read -r linea || [ -n "$linea" ]; do
    nl=$((nl + 1))
    local -a campos=()
    # NO se usa `IFS=$'\t' read -r -a`: el tabulador es IFS-WHITESPACE, asi que el shell colapsa
    # las secuencias de separadores y SE COME LAS CELDAS VACIAS. Medido:
    #     printf 'a\t\tc\n' | { IFS=$'\t' read -r x y z; }   ->  x=[a] y=[c] z=[]
    # En una tabla eso no se ve como un error: la fila se corre una columna a la izquierda, el
    # hueco aparece al FINAL —donde esta funcion pinta «—» por campo ausente— y el resultado se lee
    # como una fila legitima. Es exactamente la mentira que la regla de oro de arriba prohibe.
    # Se trocea a mano, conservando los vacios.
    local resto="$linea" campo tab=$'\t'
    while :; do
      campo="${resto%%"$tab"*}"
      campos+=("$campo")
      [ "$campo" = "$resto" ] && break
      resto="${resto#*"$tab"}"
    done
    # Se duplica aqui el troceo que `lib-perfil.sh` expone como `perfil_campos` — a proposito y no
    # por descuido: este fichero pinta capturas CUALESQUIERA y no debe depender del contrato del
    # perfil, ni el perfil de un renderizador. Son ocho lineas y las dos llevan escrito el porque.
    # `total` es el MAYOR de los dos: así el bucle rellena con «—» cuando la fila vino corta y
    # arrastra los sobrantes cuando vino ancha. Con `n` a secas, los sobrantes no se recorrían.
    total="${#campos[@]}"
    [ "$total" -ge "$n" ] || total="$n"
    if [ "${#campos[@]}" -gt "$n" ]; then
      anchas=$((anchas + 1))
      printf 'lib-tablas: FILA %d: %d campos para %d columnas de cabecera; se pintan los %d enteros y se avisa, NO se recorta en silencio\n' \
        "$nl" "${#campos[@]}" "$n" "${#campos[@]}" >&2
    fi
    local -a fila=()
    for ((i = 0; i < total; i++)); do fila+=("${campos[i]-}"); done
    tabla_fila "${fila[@]}"
  done
  # Sin línea-resumen a propósito: el aviso por fila ya lleva el NÚMERO DE FILA, que es lo accionable,
  # y un total repetiría el mensaje en el caso de una sola fila ancha, que es el caso corriente.
  [ "$anchas" -eq 0 ] || return 1
  return 0
}
