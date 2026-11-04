#!/usr/bin/env bash
# relay-ceo.sh — Entrega un relevo a un destino de la fábrica (talent-ceo, ref 01).
#
# Repo-agnóstico, token-only, sin MCP.
#
# Uso:
#   relay-ceo.sh --a <tipo>:<id> --fichero <ruta> [--dry-run]
#   relay-ceo.sh --help
#
# rc: 0 = entregado (o comando impreso con --dry-run) · 1 = el destino no existe en el perfil
#     3 = FALLO DE TRANSPORTE (tmux/incus/ssh): el destino existe, la via fallo — NO es un
#         veredicto sobre el perfil, y por eso no comparte codigo con el 1
#     2 = PRECONDICIÓN: sin perfil válido, fichero ausente, destino sin sesión.
#
# ── LOCAL O REMOTO SE DECIDE DESDE EL PERFIL, NO DEL NOMBRE ────────────────────────────────────
# La ruta de entrega sale de las columnas `maquina`, `contenedor` y `sesion` de la fila destino:
#   maquina == la máquina local  y sin contenedor  -> tmux directo
#   maquina == la máquina local  y con contenedor  -> ejecutar dentro del contenedor
#   maquina != la máquina local                    -> ssh a esa máquina y luego lo anterior
#
# **`contenedor` es un IDENTIFICADOR OPACO**: está PROHIBIDO deducir nada de su forma —ni prefijo,
# ni sufijo, ni numeración—. El tipo lo dice la columna `tipo`; dónde vive, las columnas de
# topología. Lo prueba el perfil de una instancia real: hay filas `runner` cuyo contenedor sigue el
# patrón de nombre de los canales. Un `case "$contenedor" in <prefijo-de-canal>*)` habría
# clasificado mal esas filas, y el fallo habría sido SILENCIOSO.
#
# (Ni siquiera se escribe aquí un prefijo de ejemplo: este fichero vive DENTRO del árbol que
# barre el gate anti-nombres, así que un literal de muestra en un comentario lo rompería igual
# que uno de verdad. El ejemplo concreto vive en el anexo, que es el overlay.)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib-perfil.sh"


# Un `shift 2` con la opcion como ULTIMO argumento no desplaza nada (rc != 0) y, sin `set -e`, el
# bucle vuelve a leer el mismo `$1`: BUCLE INFINITO. Se exige el valor ANTES de desplazar.
_exige_valor(){ [ "$1" -ge 2 ] || { printf '%s: PRECOND: %s exige un valor\n' "${0##*/}" "$2" >&2; exit 2; }; }

destino=''; fichero=''; dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --a) _exige_valor $# "$1"; destino="${2-}"; shift 2 ;;
    --fichero) _exige_valor $# "$1"; fichero="${2-}"; shift 2 ;;
    --dry-run) dry=1;           shift ;;
    --help)    sed -n '2,29p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "relay-ceo: argumento desconocido: $1" >&2; exit 2 ;;
  esac
done
[ -n "$destino" ] || { echo "relay-ceo: PRECOND: falta --a <tipo>:<id>" >&2; exit 2; }
[ -n "$fichero" ] || { echo "relay-ceo: PRECOND: falta --fichero" >&2; exit 2; }
[ -f "$fichero" ] && [ -r "$fichero" ] || { echo "relay-ceo: PRECOND: fichero ausente o ilegible: $fichero" >&2; exit 2; }
# Un NUL en el fichero NO llega: la sustitucion de comandos lo descarta —bash avisa por stderr y
# sigue— y el relevo se entregaria ALTERADO con rc 0. Entregar un texto distinto del que alguien
# escribio, y decir que fue bien, es la peor combinacion posible.
# Va AQUI, con las demas precondiciones del FICHERO, y no mas abajo: es una propiedad del fichero,
# no del destino. Colocado despues de resolver el destino, un fichero con NUL hacia rc 1 —«el
# destino no existe»— y el diagnostico apuntaba al sitio equivocado.
# SE LEE UNA SOLA VEZ, Y SE VALIDA LO LEIDO. La version anterior comprobaba el FICHERO aqui y lo
# volvia a leer mas abajo para entregarlo: dos instantaneas distintas del mismo camino, o sea un
# TOCTOU. Medido: dejando terminar la comparacion y sustituyendo el fichero justo despues por
# `ab\0cd`, la lectura de abajo cogia la version NUEVA, bash descartaba el NUL y el relay entregaba
# `abcd` con **rc 0** — texto distinto del que nadie escribio, declarado entregado.
# Ahora el contenido se captura aqui, en `contenido`, y todo lo que sigue trabaja sobre ESA copia.
# El NUL no se puede detectar mirando `$contenido` —la sustitucion de comandos ya lo habria
# descartado— asi que se compara el TAMANO leido con el del fichero en el momento de leerlo: si
# bash descarto algo, no cuadran. Lo que se entrega es exactamente lo que se valido.
# INSTANTANEA UNICA. Se copia el fichero UNA vez, se valida LA COPIA y se entrega LA COPIA: asi no
# hay dos lecturas que puedan diferir. Comparar tamanos —que fue el primer intento— no vale: la
# sustitucion de comandos recorta los saltos finales, asi que hay que tolerar diferencia, y esa
# tolerancia se traga justo el caso de UN NUL. Medido: con `ab\0cd` (5 bytes) el contenido leido son
# 4 y la tolerancia de +1 lo daba por bueno. Un arreglo cuya holgura cubre exactamente el defecto
# que persigue no es un arreglo.
_snap="$(mktemp "${TMPDIR:-/tmp}/.relay-ceo.XXXXXX")" || {
  echo "relay-ceo: no se pudo crear la instantanea del relevo" >&2; exit 2; }
trap 'rm -f "$_snap"' EXIT
cat -- "$fichero" > "$_snap" || { echo "relay-ceo: no se pudo leer $fichero" >&2; exit 2; }

# El NUL se busca EN LA INSTANTANEA, que es lo que se va a entregar. Un NUL no llega al destino: la
# sustitucion de comandos lo descarta —bash avisa por stderr y sigue— y el relevo se entregaria
# ALTERADO con rc 0. Entregar un texto distinto del que alguien escribio, y decir que fue bien, es
# la peor combinacion posible.
if ! tr -d '\000' < "$_snap" | cmp -s - "$_snap"; then
  echo "relay-ceo: PRECOND: $fichero contiene un byte NUL; el relevo se entregaria alterado" >&2
  exit 2
fi
contenido="$(cat -- "$_snap")" || { echo "relay-ceo: no se pudo leer la instantanea" >&2; exit 2; }

case "$destino" in
  *:*) tipo="${destino%%:*}"; id="${destino#*:}" ;;
  *) echo "relay-ceo: PRECOND: --a debe ser <tipo>:<id>" >&2; exit 2 ;;
esac
# El `case` solo garantiza que HAY dos puntos, no que haya algo a cada lado: `":x"` deja el tipo
# vacio y `"x:"` deja el id vacio, y ambos llegaban a `perfil_row1` como si fueran destinos
# legitimos. Un destino a medias no es un destino: se corta aqui, donde todavia se puede decir
# cual de las dos mitades falta.
[ -n "$tipo" ] || { echo "relay-ceo: PRECOND: --a sin tipo antes de ':' ($destino)" >&2; exit 2; }
[ -n "$id" ]   || { echo "relay-ceo: PRECOND: --a sin id despues de ':' ($destino)" >&2; exit 2; }

fila="$(perfil_row1 "$tipo" "$id")"; rc=$?
case "$rc" in
  0) : ;;
  1) echo "relay-ceo: el destino $tipo:$id no existe en el perfil" >&2; exit 1 ;;
  *) echo "relay-ceo: PRECOND: sin perfil válido" >&2; exit 2 ;;
esac

# Estos `cut -f` SI son correctos con celdas vacias —y el contrato las admite: V2 solo exige
# `NF == 6`—. `cut` delimita por cada tabulador, sin colapsar; el que colapsa es `IFS=$'\t' read`,
# porque el tabulador es IFS-whitespace. Medido y explicado en `perfil_campos` (`lib-perfil.sh`).
# Se deja dicho aqui para que nadie los "arregle" por parecerse al patron roto.
maq="$(printf '%s' "$fila" | cut -f3)"
cont="$(printf '%s' "$fila" | cut -f4)"
ses="$(printf '%s' "$fila" | cut -f5)"
# Una `maquina` VACIA —que V2 admite, porque solo exige seis columnas— no puede leerse como
# "remota": `$maq != $local_id` es cierto para la cadena vacia, y el relevo acababa en `ssh -- ""`.
# Sin saber DONDE vive el destino no se decide nada: rc 2.
[ -n "$maq" ] && [ "$maq" != '-' ] || {
  echo "relay-ceo: PRECOND: el destino $tipo:$id no declara en qué máquina vive (columna maquina = \"$maq\")" >&2
  exit 2; }
[ -n "$ses" ] && [ "$ses" != '-' ] && [ "$ses" != 'ninguna' ] || {
  echo "relay-ceo: PRECOND: el destino $tipo:$id no tiene sesión donde entregar" >&2; exit 2; }

# La máquina LOCAL se identifica por su fila `maquina` con atributo acceso=local: otra vez el
# perfil decide, no el hostname del proceso.
#
# FAIL-CLOSED: si NINGUNA fila `maquina` declara `acceso=local`, no se asume "todo es local". Esa
# suposición entregaría en la sesión de ESTA máquina un relevo destinado a otra — silenciosamente y
# a la sesión equivocada. Sin saber cuál es la local, no se puede decidir, y no decidir es rc 2.
#
# Se trocea con `perfil_campos` y NO con `IFS=$'\t' read`: el tabulador es IFS-whitespace y el
# shell se come las celdas vacias, con lo que `atributos` acabaria leyendose de `sesion` y este
# bucle buscaria `acceso=local` en la columna equivocada — en silencio. El detalle, medido, en
# `lib-perfil.sh`.
#
# Que aqui valga quedarse con la PRIMERA fila que declare `acceso=local` no es descuido: `perfil_rows`
# valida antes de devolver nada, y V9 rechaza un perfil con dos maquinas `acceso=local`. La
# ambiguedad se cierra en el validador; aqui solo se consume una garantia ya comprobada.
local_id=''
while IFS= read -r _fila; do
  perfil_campos "$_fila"
  mid="${PERFIL_CAMPOS[1]-}"; attrs="${PERFIL_CAMPOS[5]-}"
  if [ "$(perfil_attr "$attrs" acceso || true)" = local ]; then local_id="$mid"; break; fi
done <<EOF
$(perfil_rows maquina 2>/dev/null || true)
EOF
[ -n "$local_id" ] || {
  echo "relay-ceo: PRECOND: ninguna fila 'maquina' declara acceso=local; no se puede decidir si $tipo:$id es local o remoto" >&2
  exit 2; }

# ── SE SERIALIZA PARA UN SHELL POSIX, NO PARA BASH ─────────────────────────────────────────────
# `printf '%q'` es una EXTENSION de bash: en cuanto el argumento lleva un salto de linea emite
# comillas ANSI-C (`$'...\n...'`), y aqui los lleva SIEMPRE porque el payload es un fichero
# entero. El destinatario de esa cadena es el LOGIN SHELL de la maquina remota, que no tiene por
# que ser bash. Medido con `dash` de login shell, el relevo llega asi:
#     $primera linea\nsegunda linea      <- un `$` de mas y el salto vuelto DOS caracteres
# En esta flota los shells remotos son bash y no muerde. Se arregla precisamente por eso: el
# paquete esta hecho para viajar a otras instancias, y alli fallaria lejos de quien pueda
# diagnosticarlo. Lo que viaja no puede depender del arbol en el que nacio.
#
# NO se arregla anteponiendo `bash -lc` al comando remoto. `ssh` JUNTA sus argumentos con espacios
# y NO los vuelve a citar, asi que quien parte la cadena en palabras sigue siendo el login shell,
# ANTES de que bash llegue a existir. Medido: `ssh -- maq bash -lc "<%q>"` le entrega a bash el
# script `tmux` y el resto como parametros posicionales — se rompe INCLUSO con bash de login shell.
# Cualquier salida pasa por citar bien; citar bien es el problema entero.
#
# Se citan con comillas simples POSIX: las entiende igual TODO shell POSIX y admiten saltos de
# linea literales dentro. Se citan TODAS las palabras, tambien las inofensivas — decidir cual
# necesita comillas es una regla mas donde equivocarse, y `--dry-run` debe imprimir el comando
# EXACTO, no uno parecido.
# El limite del contrato, dicho en voz alta: esto vale para un login shell POSIX. Con `csh` o
# `fish` no hay serializacion que valga sin acordar antes el interprete — eso seria otra decision,
# no un escape de esta.
_citar_posix() {
  local s q="'\\''" out=''
  for s in "$@"; do out="$out'${s//\'/$q}' "; done
  printf '%s' "$out"
}

# ── SIN `eval`: los argumentos viajan COMO ARGUMENTOS ──────────────────────────────────────────
# La versión anterior componía una cadena y la evaluaba. Con eso, una ruta existente del tipo
# `a b; id` —o un campo del perfil con sintaxis de shell en `maquina`/`contenedor`/`sesion`—
# ejecutaba comandos arbitrarios con la identidad del proceso, y por `ssh` también en la máquina
# remota. `perfil_validate` comprueba la ESTRUCTURA del TSV, no que sus campos sean inertes.
# Aquí se construye un vector argv y se ejecuta directamente; solo las capas que EXIGEN una cadena
# (el `-lc` del contenedor y el comando remoto de ssh) se serializan, y con `_citar_posix` —el
# bloque de arriba explica por qué NO con `printf %q`, que es lo que decía esta línea y se quedó
# sin actualizar cuando se retiró el `%q`. Un comentario que nombra el mecanismo retirado manda a
# quien lo lea justo al sitio donde ya no está el problema.
# DECLARADO, porque no es un descuido: la sustitucion de comandos RECORTA los saltos de linea
# FINALES, asi que un relevo que acabe en `\n\n` se entrega sin ellos. Es lo que se quiere —
# `tmux send-keys -l` escribe texto literal, y un salto final ENVIARIA la linea: el relevo se deja
# escrito en el composer del destino, no ejecutado por su cuenta. Lo que NO se quiere es que esto
# viva solo en la cabeza de quien lo escribio, ni que el test lo "compruebe" calculando el esperado
# con la misma sustitucion —eso no prueba nada, se compara un recorte consigo mismo—. El caso de la
# suite afirma el recorte EXPLICITAMENTE, con el esperado escrito a mano.
# `contenido` se leyo y valido ARRIBA, con las precondiciones del fichero. No se vuelve a leer:
# releerlo aqui era justo el TOCTOU que se cerro.

# El `--` NO es decorativo: sin el, un contenido que empiece por guion lo consume `tmux` como
# OPCION. Medido contra tmux 3.4: un relevo cuyo texto es `-l` produce `send-keys -t <pane> -l -l`,
# tmux devuelve **rc 0** y NO escribe ni un caracter — el relay canta entrega y el pane queda vacio.
# Un relevo perdido que se declara entregado es peor que uno que falla. Con `--`, el mismo texto se
# escribe literal (verificado en el mismo tmux).
argv=(tmux send-keys -t "$ses" -l -- "$contenido")
# Esta capa NOMBRA su interprete (`bash -lc`), que es por lo que nunca tuvo el problema de arriba;
# aun asi cita con el MISMO serializador: un solo dialecto en todo el fichero, para que nadie tenga
# que acordarse de cual toca en cada capa.
if [ -n "$cont" ] && [ "$cont" != '-' ]; then
  argv=(incus exec "$cont" -- bash -lc "$(_citar_posix "${argv[@]}")")
fi
# Aqui el interprete NO se elige: es el login shell de la maquina remota, y por eso se cita POSIX.
if [ "$maq" != "$local_id" ]; then
  argv=(ssh -- "$maq" "$(_citar_posix "${argv[@]}")")
fi

# El dry-run imprime con el MISMO serializador: si imprimiera en otro dialecto dejaria de ser "el
# comando exacto" que la ref 01 promete, y quien lo copie a un `sh` obtendria otra cosa.
if [ "$dry" -eq 1 ]; then _citar_posix "${argv[@]}"; printf '\n'; exit 0; fi

# ── UN FALLO DE LA VIA NO ES UN VEREDICTO SOBRE EL DESTINO ─────────────────────────────────────
# Antes el script terminaba con `"${argv[@]}"` a secas, asi que el rc del TRANSPORTE —tmux sin
# servidor, `incus` con el contenedor parado, ssh sin ruta— se convertia en el rc del CONTRATO.
# Y el 1 del contrato significa otra cosa muy concreta: "el destino no existe en el perfil".
# Con eso, un cable caido se leia como "ese canal no existe": el operador va a corregir el perfil,
# que esta bien, en vez de mirar la red. Es PRECONDICION disfrazada de veredicto.
# El transporte tiene ahora su propio rc 3 y el codigo real del transporte viaja en el mensaje,
# que es el dato con el que se diagnostica.
"${argv[@]}"; rc_transporte=$?
[ "$rc_transporte" -eq 0 ] || {
  echo "relay-ceo: FALLO DE TRANSPORTE (rc $rc_transporte) al entregar a $tipo:$id" >&2
  echo "relay-ceo: el destino SI existe en el perfil; lo que fallo es la via (tmux/incus/ssh)" >&2
  exit 3; }
exit 0
