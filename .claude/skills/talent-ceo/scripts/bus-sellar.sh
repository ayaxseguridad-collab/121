#!/usr/bin/env bash
# bus-sellar.sh — Sella un marcador en el BUS de la fábrica (talent-ceo, ref 02).
#
# Unifica los dos selladores históricos (sellar.sh y c1-sellar.sh) en UNO parametrizable: quién
# sella se pasa por argumento, no se deduce del nombre del script ni del host.
# Repo-agnóstico, token-only, sin MCP.
#
# Uso:
#   bus-sellar.sh --marcador <TEXTO> --rol <ID> [--src <fichero>] [--nota <TEXTO>]
#   bus-sellar.sh --help
#
# Entorno: TA_ROL (identidad del sellador, si no se pasa --rol) · TA_BUS (ruta del bus, OBLIGATORIA) · TA_BUS_LOCK (lock; por defecto, bajo
# ${XDG_RUNTIME_DIR:-$HOME/.cache}/talent-ceo/).
#
# ── rc EXACTOS ─────────────────────────────────────────────────────────────────────────────────
#   0 = sello escrito (la hora la mide ESTE script con `date`, no la recibe de nadie)
#   2 = PRECONDICIÓN: TA_BUS ausente/ilegible · `src` ES el bus · lock no adquirible · marcador vacío
#       · SIN identidad de rol (--rol / TA_ROL) o rol fuera del charset
#       · IDENTIDAD NO VERIFICABLE: sin perfil legible · ninguna máquina declara `acceso=local` ·
#         el rol no existe en el perfil · el perfil lo coloca en OTRA máquina · su columna
#         `maquina` es `-` · declara `usuario=` y el usuario real del proceso no coincide
#   3 = MARCADOR REPETIDO (ya sellado antes)
#
# ── DOS DECISIONES QUE PARECEN DETALLE Y NO LO SON ─────────────────────────────────────────────
# (1) `src == bus` se decide por IDENTIDAD (`-ef`, dispositivo+inodo), no comparando cadenas: con
#     comparación textual se evade con ruta relativa, `..`, symlink o hardlink — cuatro puertas.
# (2) La BÚSQUEDA del marcador y el APPEND ocurren dentro de la MISMA sección crítica. Si se busca
#     fuera del lock, dos escritores concurrentes del mismo marcador pueden ver ambos "no está" y
#     sellar los dos: el rc 3 dejaría de significar nada.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib-bus.sh"


# Un `shift 2` con la opcion como ULTIMO argumento no desplaza nada (rc != 0) y, sin `set -e`, el
# bucle vuelve a leer el mismo `$1`: BUCLE INFINITO. Se exige el valor ANTES de desplazar.
_exige_valor(){ [ "$1" -ge 2 ] || { printf '%s: PRECOND: %s exige un valor\n' "${0##*/}" "$2" >&2; exit 2; }; }

marcador=''; src=''; nota=''; rol="${TA_ROL-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --marcador) _exige_valor $# "$1"; marcador="${2-}"; shift 2 ;;
    --src) _exige_valor $# "$1"; src="${2-}";      shift 2 ;;
    --nota) _exige_valor $# "$1"; nota="${2-}";     shift 2 ;;
    --rol) _exige_valor $# "$1"; rol="${2-}";       shift 2 ;;
    --help)     sed -n '2,29p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "bus-sellar: argumento desconocido: $1" >&2; exit 2 ;;
  esac
done

[ -n "$marcador" ] || { echo "bus: PRECOND: --marcador vacío" >&2; exit 2; }

# ── NI LF NI CR EN LOS CAMPOS LIBRES: el separador de registro no puede viajar dentro del dato ──
# El bus es UNA LÍNEA POR SELLO. Un salto de línea dentro de `--nota` (o de `--marcador`) no rompe
# la verificación de identidad de más abajo: **la esquiva por debajo**, porque escribe una línea
# NUEVA que ya nace del otro lado del control. Quien pueda sellar UNA vez con su identidad real
# podría así forjar un sello atribuido a cualquier rol —incluido el CEO— y anular justo la
# comprobación contra el perfil que este script hace.
# Se RECHAZA, no se escapa ni se sustituye: escapar deja el dato dentro y traslada el problema a
# cada lector; sustituir altera en silencio lo que alguien quiso sellar. Misma disciplina de
# charset cerrado que `--rol`. La comprobación va ANTES de construir la estampa y ANTES del `grep`
# de duplicados, para que un valor con LF no pueda influir tampoco en la detección de repetidos.
_sin_saltos(){   # <nombre-del-campo> <valor>
  # `LC_ALL=C` para TODA la funcion, y no es cosmetico: `[[:cntrl:]]` NO significa lo mismo en cada
  # localizacion. MEDIDO en este host con la nota `a \xc2\x9b 2J b`: bajo `LC_ALL=C` la clase NO casa
  # el C1 —cntrl es C0 mas DEL, por bytes— y decide la guarda especifica de mas abajo; bajo
  # `LC_ALL=C.utf8` la clase SI lo casa —cntrl incluye U+0080..U+009F— y decide ESTA. Las dos
  # rechazan, pero el operador lee un diagnostico distinto segun la localizacion del que llamo, y el
  # bueno es el especifico: dice que el byte esta BIEN CODIFICADO, que es justo lo que despista.
  # Con `local` el cambio vale ya y se deshace al volver, sin tocar el resto del script.
  # (El rango de bytes `[\x80-\x9f]` de la guarda C1, en cambio, casa igual en las cuatro
  # localizaciones instaladas aqui: la que cambia de significado es la CLASE, no el rango.)
  local LC_ALL=C
  case "$2" in
    *$'\n'*) echo "bus: PRECOND: --$1 contiene un salto de línea (LF); el bus es UNA LÍNEA POR SELLO" >&2; exit 2 ;;
    *$'\r'*) echo "bus: PRECOND: --$1 contiene un retorno de carro (CR); el bus es UNA LÍNEA POR SELLO" >&2; exit 2 ;;
  esac
  # Y CUALQUIER otro carácter de control, no sólo los dos separadores. Rechazar LF y CR era
  # enumerar lo prohibido, y lo prohibido es infinito: quedaban ESC (0x1B) y con él las secuencias
  # ANSI/OSC, que reescriben lo que ve quien hace `cat` del bus —incluido borrar o falsear líneas
  # en pantalla—, más NUL, backspace y compañía. Se acota por CLASE (`[[:cntrl:]]`), que es el
  # complemento de lo legible, en vez de ir añadiendo caracteres a una lista negra.
  case "$2" in
    *[[:cntrl:]]*)
      echo "bus: PRECOND: --$1 contiene un carácter de CONTROL; el bus se lee en terminal y sólo admite texto legible" >&2
      exit 2 ;;
  esac
  # `[[:cntrl:]]` es C0 y DEL. NO cubre los C1 (0x80-0x9F), y ahí vive el CSI de 8 bits `0x9B`, que
  # hace de `ESC [` en un terminal que los interprete: escribirlo en el bus deja a quien haga `cat`
  # a merced del sello. No se filtran por rango —en UTF-8 esos bytes son CONTINUACIÓN de caracteres
  # legítimos y el campo `nota` es prosa con acentos—, se rechaza lo que NO ES UTF-8 VÁLIDO, que es
  # la única condición bajo la que un 0x9B puede estar suelto. De paso cierra cualquier otra
  # basura binaria, sin enumerarla.
  # SIN `iconv` esta comprobación NO SE PUEDE HACER, y antes eso significaba **saltársela**: el
  # `if` no entraba y el sello seguía adelante. Medido con un PATH funcional pero sin `iconv`: una
  # nota con el C1 crudo `0x9b 2J` se sellaba con **rc 0** y el byte quedaba escrito en el bus, que
  # es un fichero que alguien lee en su terminal. Un guardia que desaparece cuando falta una
  # herramienta no es un guardia. «No he podido comprobarlo» NO es «está bien»: se falla cerrado.
  command -v iconv >/dev/null 2>&1 || {
    # OJO CON LA REDACCION: «PRECOND: falta X» es una frase CONTRACTUAL en este paquete — la suite
    # la parsea para deducir los argumentos obligatorios de cada script ([r8-16]). Escribirla aqui
    # convertia `iconv` (y cualquier flag citado en la frase) en un obligatorio inventado y ponia
    # rojos ejemplos de la doc que estaban bien. Se dice lo mismo sin esa formula.
    echo "bus: PRECOND: no hay \`iconv\` en el PATH; no se puede validar que --$1 sea UTF-8 y NO se sella a ciegas" >&2
    exit 2; }
  printf '%s' "$2" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || {
    echo "bus: PRECOND: --$1 no es UTF-8 válido; el bus se lee en terminal y sólo admite texto legible" >&2
    exit 2; }
  # Y «UTF-8 válido» NO implica «sin controles»: los C1 tienen forma UTF-8 legítima —U+009B, que es
  # CSI, se codifica `c2 9b`— así que pasaban el filtro de arriba y un terminal en UTF-8 los
  # interpreta igual. Se rechaza el RANGO DE CODEPOINTS U+0080..U+009F, que no aparece en prosa
  # ninguna: es la banda de control, no letras.
  # Gemela EXACTA de la de `tablas-cron.sh`: sin tuberia. Con `pipefail`, un `grep -q` que casa
  # pronto cierra el descriptor, `printf` muere por SIGPIPE (141) y el `if` NO dispara — el control
  # C1 se cuela en el bus. Se resuelve con `case`, que no tiene estado de tuberia que interpretar.
  case "$2" in
    *$'\xc2'[$'\x80'-$'\x9f']*)
    echo "bus: PRECOND: --$1 contiene un control C1 (U+0080..U+009F) aunque esté bien codificado" >&2
      exit 2 ;;
  esac
}
_sin_saltos marcador "$marcador"
_sin_saltos nota     "$nota"

# El MARCADOR no es prosa: es un identificador, y con los identificadores se puede cerrar el
# alfabeto del todo en vez de conformarse con excluir controles. Misma disciplina que `--rol`.
# La `nota` sí es prosa —lleva acentos y puntuación— y por eso allí el contrato es «legible»,
# no una lista blanca de caracteres: dos campos distintos, dos contratos distintos, dicho aquí
# para que nadie los unifique creyendo que simplifica.
printf '%s' "$marcador" | grep -Eq '^[A-Za-z0-9._:+-]{1,64}$' || {
  echo "bus: PRECOND: marcador inválido (sólo [A-Za-z0-9._:+-], 1..64): $marcador" >&2; exit 2; }
# La ref 02 promete que "cada rol sella con su identidad": si el sello no dice QUIEN, esa promesa
# es falsa y el bus deja de servir para lo unico que lo hace util. Fail-closed: sin --rol ni TA_ROL
# no se sella. Charset cerrado, porque el valor va al fichero compartido que leen todos.
[ -n "$rol" ] || { echo "bus: PRECOND: falta --rol (o TA_ROL): un sello sin identidad no acredita nada" >&2; exit 2; }
printf '%s' "$rol" | grep -Eq '^[A-Za-z0-9_-]{1,32}$' || {
  echo "bus: PRECOND: rol inválido (solo [A-Za-z0-9_-], 1..32): $rol" >&2; exit 2; }

# ── IDENTIDAD REAL: el rol se VERIFICA contra el perfil, no vale porque se afirme ───────────────
# Comprobar el CHARSET de `--rol` no es comprobar la IDENTIDAD de quien sella: con solo eso,
# cualquiera podía sellar como cualquiera y la promesa de la ref 02 ("cada rol sella con su
# identidad") era falsa. Se sube el CÓDIGO hasta la promesa, no se baja la promesa hasta el código.
#
# El perfil es la autoridad sobre la topología, así que la identidad se DERIVA de él:
#   (1) esta máquina = la fila `maquina` que declara `acceso=local` (fail-closed si ninguna);
#   (2) el rol debe EXISTIR como fila del perfil y estar COLOCADO en esta máquina;
#   (3) si esa fila declara `usuario=`, el usuario real del proceso debe coincidir.
#
# LÍMITE DECLARADO, no disimulado: esto cierra la suplantación ENTRE MÁQUINAS (un canal ya no
# puede sellar como el CEO que el perfil coloca en otro host). Dos roles en la MISMA máquina que no
# se distingan por `usuario=` **ya no pasan**: el gate de ambigüedad de más abajo los rechaza con
# rc 2 en vez de dejar sellar a cualquiera de los dos — este párrafo lo anunciaba como agujero
# cuando ya estaba cerrado, y un límite declarado de más miente igual que uno declarado de menos.
# Lo que SIGUE fuera del alcance es quien escriba el fichero del bus directamente: eso no lo
# impide esta herramienta y se detecta por formato, no por permisos.
# shellcheck source=/dev/null
. "$HERE/lib-perfil.sh"

perfil_path >/dev/null 2>&1 || {
  echo "bus: PRECOND: sin perfil de instancia legible: la identidad del sellador no se puede verificar" >&2
  echo "bus: un sello cuya identidad no se puede comprobar no acredita nada; no se sella" >&2; exit 2; }

# Se trocea con `perfil_campos` y NO con `IFS=$'\t' read`: el tabulador es IFS-whitespace y el
# shell se come las celdas vacias, corriendo el resto una columna. Aqui eso seria grave de un modo
# muy concreto: `atributos` se leeria de `sesion`, y de `atributos` cuelga la IDENTIDAD del
# sellador. Un sello firmado con la identidad equivocada no se distingue de uno bueno.
# Quedarse con la PRIMERA fila `acceso=local` es correcto porque `perfil_rows` valida antes de
# devolver, y V9 rechaza el perfil que declare dos: la ambiguedad se cierra en el validador.
sellar_local_id=''
while IFS= read -r _fila; do
  perfil_campos "$_fila"
  mid="${PERFIL_CAMPOS[1]-}"; attrs="${PERFIL_CAMPOS[5]-}"
  if [ "$(perfil_attr "$attrs" acceso || true)" = local ]; then sellar_local_id="$mid"; break; fi
done <<EOF
$(perfil_rows maquina 2>/dev/null || true)
EOF
[ -n "$sellar_local_id" ] || {
  echo "bus: PRECOND: ninguna fila 'maquina' declara acceso=local; no se sabe qué máquina es ésta" >&2; exit 2; }

sellar_fila=''
for _tipo in torre estacion canal runner ceo pm; do
  sellar_fila="$(perfil_row1 "$_tipo" "$rol" 2>/dev/null)" && [ -n "$sellar_fila" ] && break
  sellar_fila=''
done
[ -n "$sellar_fila" ] || {
  echo "bus: PRECOND: el rol \"$rol\" no existe en el perfil como torre/estacion/canal/runner/ceo/pm" >&2; exit 2; }

# `cut -f` SI conserva las celdas vacias —delimita por cada tabulador, sin colapsar—, asi que estas
# dos lecturas son correctas aunque el perfil traiga columnas vacias, que V2 admite. El que colapsa
# es `IFS=$'\t' read`, y por eso los bucles de arriba usan `perfil_campos`. Medido en `lib-perfil.sh`.
sellar_maquina="$(printf '%s' "$sellar_fila" | cut -f3)"
case "$sellar_maquina" in
  ''|'-')
    echo "bus: PRECOND: el perfil no declara en qué máquina vive el rol \"$rol\" (columna maquina = \"$sellar_maquina\")" >&2
    echo "bus: sin ubicación declarada no hay identidad que verificar; no se sella" >&2; exit 2 ;;
esac
[ "$sellar_maquina" = "$sellar_local_id" ] || {
  echo "bus: PRECOND: el perfil coloca el rol \"$rol\" en la máquina \"$sellar_maquina\", y ésta es \"$sellar_local_id\"" >&2
  echo "bus: no se sella en nombre de un rol que vive en otra máquina" >&2; exit 2; }

sellar_usuario="$(perfil_attr "$(printf '%s' "$sellar_fila" | cut -f6)" usuario || true)"
if [ -n "$sellar_usuario" ]; then
  sellar_yo="$(id -un 2>/dev/null || true)"
  [ "$sellar_yo" = "$sellar_usuario" ] || {
    echo "bus: PRECOND: el perfil exige que \"$rol\" selle como usuario \"$sellar_usuario\"; este proceso es \"$sellar_yo\"" >&2
    exit 2; }
fi

# ── AMBIGÜEDAD EN LA MISMA MÁQUINA: fail-closed, no "límite declarado" ─────────────────────────
# Hasta aquí la verificación cierra la suplantación ENTRE máquinas. Faltaba el caso de dos roles
# colocados en la MISMA máquina: si el perfil no los distingue, cualquiera de ellos podía sellar
# como el otro y la comprobación de arriba pasaba sin protestar. Antes esto figuraba como «límite
# declarado» en la ref 02 — y declarar un agujero no lo cierra: sólo avisa de que está ahí.
#
# Se cierra por AMBIGÜEDAD, que es la única salida honesta sin inventarse una identidad que el
# sistema no da: si otro rol vive en esta máquina y NO se distingue del nuestro por `usuario=`,
# no se sella. La vía de arreglo para quien opera es declarar `usuario=` distintos en el perfil,
# no relajar el gate.
sellar_ambiguo=''
for _tipo in torre estacion canal runner ceo pm; do
  # Mismo motivo que arriba: `perfil_campos`, no `IFS=$'\t' read`. Aqui el desplazamiento seria
  # todavia mas traicionero — `rmaq` se leeria de `id` y la comparacion contra la maquina local
  # fallaria SIEMPRE, con lo que este gate de ambiguedad dejaria de detectar nada y seguiria
  # pareciendo que corre.
  while IFS= read -r _rfila; do
    perfil_campos "$_rfila"
    rid="${PERFIL_CAMPOS[1]-}"; rmaq="${PERFIL_CAMPOS[2]-}"; rattrs="${PERFIL_CAMPOS[5]-}"
    [ -n "${rid:-}" ] || continue
    [ "$rid" = "$rol" ] && continue
    [ "$rmaq" = "$sellar_local_id" ] || continue
    rusuario="$(perfil_attr "$rattrs" usuario || true)"
    if [ -z "$sellar_usuario" ] || [ -z "$rusuario" ] || [ "$rusuario" = "$sellar_usuario" ]; then
      sellar_ambiguo="$rid"
      break
    fi
  done <<EOF
$(perfil_rows "$_tipo" 2>/dev/null || true)
EOF
  [ -n "$sellar_ambiguo" ] && break
done
[ -z "$sellar_ambiguo" ] || {
  echo "bus: PRECOND: el perfil coloca \"$rol\" y \"$sellar_ambiguo\" en la MISMA máquina sin distinguirlos por usuario=" >&2
  echo "bus: un sello firmado por cualquiera de los dos no acredita cuál fue; declara usuario= distintos en el perfil" >&2
  exit 2; }
bus="${TA_BUS-}"
[ -n "$bus" ] || { echo "bus: PRECOND: TA_BUS no definida" >&2; exit 2; }
[ -f "$bus" ] && [ -r "$bus" ] && [ -w "$bus" ] || { echo "bus: PRECOND: TA_BUS ausente o no escribible: $bus" >&2; exit 2; }

# (1) identidad: sellar el bus DESDE el bus corrompería el propio registro
if [ -n "$src" ]; then
  if bus_es_el_bus "$src" "$bus"; then
    echo "bus: PRECOND: --src ES el bus (identidad por inodo, no por nombre): $src" >&2; exit 2
  fi
fi

dir="$(bus_dir_estado)"
bus_asegura_dir "$dir" || exit 2
lock="$(bus_ruta TA_BUS_LOCK "$dir/bus.lock")"
bus_asegura_regular "$lock" || exit 2
: > "$lock" 2>/dev/null || { echo "bus: PRECOND: lock no creable: $lock" >&2; exit 2; }

# La estampa se emite SIN el corchete de cierre: el `printf` de abajo ya envuelve el campo en
# `[...]`. Llevarlo dentro producia `[marcador: X]]` — un campo mal formado que ademas invita a
# parsear por subcadena. El corchete lo pone quien formatea la linea, no el dato.
estampa="marcador: ${marcador}"

exec 9>"$lock" || { echo "bus: PRECOND: lock no abrible: $lock" >&2; exit 2; }
if ! flock -x -w 10 9; then   # exclusivo: flock -x, con espera acotada
  echo "bus: PRECOND: lock no adquirible en 10s: $lock" >&2; exit 2
fi

# (2) BUSCAR y ESCRIBIR, ambos DENTRO del lock
#
# Se compara el CAMPO, no la subcadena. La cabecera decía que buscar `marcador: X]` en vez de `X`
# a secas bastaba «porque X casaría con cualquier mención en una nota». La mitigación era PARCIAL:
# las notas del bus citan marcadores continuamente —«pendiente de [marcador: X]»— y con una
# subcadena esa cita basta para RECHAZAR CON rc 3 un sello legítimo que aún no se ha puesto.
# Reproducido antes de arreglarlo: sellar `MK9` después de una nota que lo citaba daba rc 3.
#
# El marcador propio de una línea vive SIEMPRE en su cabecera, en posición fija:
#     <ts> [rol: R] [marcador: M]
# y la nota va DESPUÉS. Así que se ancla la cabecera al principio de línea y se extrae de ahí:
# lo que haya en la nota queda fuera del alcance por construcción, no por filtrado.
if awk -v m="$marcador" '
    {
      if (match($0, /^[^ ]+ \[rol: [^]]*\] \[marcador: [^]]*\]/)) {
        cab = substr($0, RSTART, RLENGTH)
        val = substr(cab, index(cab, "[marcador: ") + 11)
        sub(/\].*$/, "", val)
        if (val == m) { encontrado = 1; exit }
      }
    }
    END { exit(encontrado ? 0 : 1) }' "$bus"; then
  echo "bus: marcador repetido, no se sella: $marcador" >&2
  exit 3
fi

# La hora la MIDE el sellador, y por eso un `date` que falla no es un detalle de formato: deja el
# sello SIN marca temporal y el bus pierde su única ordenación. Medido con `date` sustituido por un
# stub que devuelve 1: se anadia ` [rol: CEO] [marcador: X]` al bus, stdout cantaba
# `bus: sellado X por CEO @ ` y el rc final era **0**. Un sello sin hora que se declara sellado es
# peor que no sellar: queda en el registro como si fuera bueno. Se falla cerrado ANTES de escribir.
ahora="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
case "$ahora" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) : ;;
  *) echo "bus: PRECOND: no se pudo medir la hora; un sello sin marca temporal no se escribe" >&2
     exit 2 ;;
esac
if [ -n "$nota" ]; then
  printf '%s [rol: %s] [%s] %s\n' "$ahora" "$rol" "$estampa" "$nota" >> "$bus" || { echo "bus: fallo al escribir" >&2; exit 2; }
else
  printf '%s [rol: %s] [%s]\n' "$ahora" "$rol" "$estampa" >> "$bus" || { echo "bus: fallo al escribir" >&2; exit 2; }
fi

echo "bus: sellado $marcador por $rol @ $ahora"
exit 0
