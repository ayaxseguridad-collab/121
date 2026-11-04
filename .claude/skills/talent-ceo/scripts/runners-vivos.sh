#!/usr/bin/env bash
# runners-vivos.sh — Runners vivos y su antigüedad, sin inferir nada del nombre (talent-ceo, ref 04).
#
# Repo-agnóstico, token-only, sin MCP.
#
# Uso:
#   runners-vivos.sh --patron <ERE>       # ERE de selección sobre la línea de proceso (OBLIGATORIO:
#                                         # el skill no adivina qué es un runner)
#   runners-vivos.sh --etime <ETIME>      # convierte UN etime a segundos (modo puro, para tests)
#   runners-vivos.sh --help
#
# rc: 0 = listado emitido (puede ir vacío) · 1 = etime no parseable · 2 = precondición.
#
# ── POR QUÉ ESTO TIENE UN PARSER PROPIO ────────────────────────────────────────────────────────
# `ps -o etime` emite TRES formas y la tercera es la que rompe a casi todo el mundo:
#     MM:SS        (menos de una hora)
#     HH:MM:SS     (menos de un día)
#     D-HH:MM:SS   (un día o más)   <-- el guion, no los dos puntos
# Un parser que solo parta por ":" lee "5-03" como minutos y devuelve una antigüedad absurda,
# justo para los procesos MÁS viejos, que son los que interesan. Se parsea de derecha a izquierda
# y el tramo de días se separa por "-" ANTES de tocar los dos puntos.
set -uo pipefail

# etime_a_segundos <ETIME> — PURA. rc 0 + segundos | rc 1 si no parsea.
etime_a_segundos() {
  local e="${1-}" dias=0 resto h m s
  [ -n "$e" ] || return 1
  case "$e" in
    *-*) dias="${e%%-*}"; resto="${e#*-}" ;;
    *)   resto="$e" ;;
  esac
  # `dias` vacio NO es valido: `-12:00:00` deja `${e%%-*}` vacio y la guarda de charset lo
  # dejaba pasar (una cadena vacia no contiene ningun no-digito). Antes "funcionaba" porque
  # una variable vacia vale 0 en aritmetica; con `10#` de abajo seria `10#` y un error de
  # sintaxis. Se rechaza aqui, que es donde se puede explicar.
  case "$dias" in (''|*[!0-9]*) return 1 ;; esac
  # `*:*:*` casa TAMBIEN con cuatro o mas componentes, y el troceo se comia el sobrante en
  # silencio: medido, `--etime 1:02:03:04` devolvia **3724** con rc 0 —el `03` desaparecia— cuando
  # esa cadena no pertenece a ninguna de las tres gramaticas que el fichero documenta. Y `99:99`
  # devolvia 6039 pese a que 99 no es ni un minuto ni un segundo. Un parser que acepta lo que no
  # entiende devuelve una antiguedad INVENTADA, y de esa antiguedad cuelga la decision de matar un
  # proceso. Se exige la forma exacta y se acota el RANGO de minutos y segundos.
  case "$resto" in
    *:*:*:*) return 1 ;;
    *:*:*)   h="${resto%%:*}"; m="${resto#*:}"; m="${m%%:*}"; s="${resto##*:}" ;;
    *:*)     h=0;              m="${resto%%:*}";              s="${resto##*:}" ;;
    *)       return 1 ;;
  esac
  case "$h" in (*[!0-9]*|'') return 1 ;; esac
  case "$m" in (*[!0-9]*|'') return 1 ;; esac
  case "$s" in (*[!0-9]*|'') return 1 ;; esac
  # Longitud acotada ANTES de la aritmetica: `10#` sobre veinte digitos desborda el entero de 64
  # bits y da un numero cualquiera. Misma leccion que en `tablas-cron.sh` y en el cursor del bus.
  # LOS CUATRO, no dos. La cota estaba en `dias` y `h` y NO en `m` ni `s` — la puerta de al lado sin
  # cerrar, en el mismo `&&`. Y el motivo por el que faltaba es una suposicion falsa: se creia que el
  # `-le 59` de abajo ya acotaba los minutos y segundos. NO lo hace, porque `10#` sobre un numero que
  # no cabe **NO desborda ni falla: ENVUELVE**. Medido: `10#18446744073709551621` (2^64+5) da **5**,
  # asi que un valor astronomico pasa el `-le 59` tan tranquilo y entra en la suma como cinco.
  # `--etime 00:18446744073709551621` devolvia **rc 0 y "5"**: una antiguedad inventada, y de ella
  # cuelga la decision de matar un proceso.
  [ "${#dias}" -le 18 ] && [ "${#h}" -le 18 ] && [ "${#m}" -le 18 ] && [ "${#s}" -le 18 ] || return 1
  # Minutos y segundos son sexagesimales en las TRES formas. `ps` nunca emite 60+ ahi: pasa a la
  # forma siguiente. Las horas NO se acotan a 23 a proposito: sin tramo de dias, un `ps` ajeno
  # puede emitir horas acumuladas, y rechazarlas seria inventar una restriccion que nadie promete.
  [ "$((10#$m))" -le 59 ] && [ "$((10#$s))" -le 59 ] || return 1
  # `10#` TAMBIEN en dias: `ps -o etime` rellena con ceros a la izquierda y bash interpreta
  # "08"/"09" como OCTAL, abortando con "value too great for base". `h`/`m`/`s` ya lo llevaban;
  # `dias` se habia quedado fuera — el unico campo de los cuatro que no se normalizaba.
  printf '%s\n' "$(( 10#$dias * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1-}" in
    --etime)
      shift; etime_a_segundos "${1-}" || { echo "runners-vivos: etime no parseable: ${1-}" >&2; exit 1; }
      exit 0 ;;
    --help) sed -n '2,21p' "${BASH_SOURCE[0]}"; exit 0 ;;
  esac

# Un `shift 2` con la opcion como ULTIMO argumento no desplaza nada (rc != 0) y, sin `set -e`, el
# bucle vuelve a leer el mismo `$1`: BUCLE INFINITO. Se exige el valor ANTES de desplazar.
_exige_valor(){ [ "$1" -ge 2 ] || { printf '%s: PRECOND: %s exige un valor\n' "${0##*/}" "$2" >&2; exit 2; }; }

  patron=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --patron) _exige_valor $# "$1"; patron="${2-}"; shift 2 ;;
      *) echo "runners-vivos: argumento desconocido: $1" >&2; exit 2 ;;
    esac
  done
  [ -n "$patron" ] || { echo "runners-vivos: PRECOND: --patron obligatorio (el skill no adivina qué es un runner)" >&2; exit 2; }
  command -v ps >/dev/null 2>&1 || { echo "runners-vivos: PRECOND: falta ps" >&2; exit 2; }
  # Un patron ERE invalido —`[` a secas— hace fallar a `grep`, y como el filtro vive dentro de una
  # tuberia el error se lo tragaba el `exit 0` de mas abajo: salia la cabecera sola con rc 0, que
  # es INDISTINGUIBLE de "no hay ningun runner vivo". Fail-open silencioso, y del peor tipo: el que
  # tranquiliza. Se valida el patron ANTES, contra entrada vacia, y se falla como precondicion.
  printf '' | grep -E -- "$patron" >/dev/null 2>&1
  [ $? -le 1 ] || { echo "runners-vivos: PRECOND: --patron no es una expresion regular valida: $patron" >&2; exit 2; }

  printf '%-10s %-14s %s\n' 'PID' 'ANTIGUEDAD' 'PROCESO'
  # EL FILTRO NO PUEDE ESTAR DENTRO DE LO FILTRADO. Con `ps | grep -E "$patron"`, el propio
  # `grep` ya esta en la tabla de procesos cuando `ps` la lee y su linea de comandos CONTIENE el
  # patron, asi que casa consigo mismo; y si el patron describe a este mismo script, tambien se
  # lista a si mismo. El resultado es un runner fantasma que nadie puede matar porque no existe.
  # Se toma la INSTANTANEA primero —cuando `ps` corre, el filtro aun no ha nacido— y ademas se
  # descarta el PID propio. Ni una cosa ni la otra sobra: la instantanea quita al filtro, el
  # descarte quita al script.
  # No basta con excluir `$$`: la propia sustitucion de comandos `$( ps ... )` FORKA un subshell
  # que HEREDA la linea de comandos de este script, asi que `ps` lo ve y casa igual. Medido:
  # tres procesos casaban el patron —el llamador, este script y ese fork—, y solo uno se filtraba.
  # Se descarta por PID propio Y por PPID propio, que cubre el fork y cualquier hijo del snapshot.
  # El `|| true` de antes convertia un fallo de `ps` en una instantanea VACIA con rc 0: la salida
  # era la cabecera sola, **indistinguible de "no hay ningun runner vivo"**. Es el mismo fail-open
  # que el patron invalido, y del mismo tipo peligroso: el que tranquiliza. Si `ps` no responde,
  # esto no sabe nada y lo dice.
  instantanea="$(ps -eo pid=,ppid=,etime=,args= 2>/dev/null)" \
    || { echo "runners-vivos: PRECOND: \`ps\` fallo; sin tabla de procesos no se puede decir que hay vivo" >&2; exit 2; }
  # ── UN PROCESO PODRIA OCUPAR VARIAS LINEAS — Y AQUI NO SE HA PODIDO REPRODUCIR ────────────────
  # La clase es la de siempre: un campo libre que contiene el separador de registro del formato de
  # destino, igual que el LF dentro de una nota del bus. Aqui el campo libre es la linea de
  # comandos y el formato es la salida de `ps`.
  #
  # LO QUE ESTA MEDIDO, dicho con precision porque la primera version de este comentario afirmaba
  # de mas: el salto de linea SI llega a `/proc/<pid>/cmdline` —comprobado con `tr '\0' '|'`—,
  # pero el `ps` de esta maquina lo SUSTITUYE POR UN ESPACIO y emite UNA sola linea. O sea: en
  # este sistema el defecto NO se reproduce, y los dos casos de la suite que lo rodean son
  # GUARDAS, no mordidas. Se dice asi y no "medido en esta maquina", que es lo que decia antes y
  # era falso: aquellas lineas de mas eran PROCESOS distintos que casaban el texto, no lineas de
  # uno solo.
  #
  # Se sostiene igual, por el mismo motivo que la serializacion POSIX del relay: POSIX no obliga a
  # `ps` a sanear ese campo, el paquete esta hecho para viajar a otras instancias —otro `ps`, otro
  # busybox— y alli fallaria lejos de quien pueda diagnosticarlo. Es endurecimiento por
  # portabilidad, NO el cierre de un defecto observado aqui.
  # Se reensamblan. Y NO por la FORMA de la linea: «empieza por dos numeros» lo cumple tambien un
  # argumento que contenga «\n123 456 loquesea», con lo que la heuristica fabricaria un runner
  # fantasma — que es justo el fallo que se venia a cerrar.
  # Se ata a la TABLA DE PROCESOS REAL: se pide aparte un listado SIN `args`, que por construccion
  # trae una linea por proceso y no puede llevar saltos dentro, y una linea abre registro solo si
  # su par «<pid> <ppid>» existe de verdad ahi.
  #
  # Y lo que NO se atribuye se DESCARTA, no se pega a la fila anterior. Pegar parecia inofensivo y
  # no lo era: si un proceso muere entre las dos fotos, su linea no casa ningun par esperado y
  # acababa concatenada al PID ANTERIOR — o sea, texto de un proceso atribuido a otro. Eso es
  # INVENTAR, que es justo lo que la regla de oro de este skill prohibe. Se descarta.
  #
  # DOS RESIDUOS DECLARADOS, porque ninguno de los dos se cierra del todo con dos fotos:
  #  · si un proceso muere o nace entre ellas, su fila se cae del listado — se OMITE, no se
  #    atribuye mal;
  #  · un patron que solo apareciera en la CONTINUACION de un argumento partido no se encuentra,
  #    porque esa continuacion ya no se pega a nada.
  # Los dos van en la direccion buena: un runner que falta se nota; uno fantasma manda a alguien a
  # matar un proceso que no existe.
  # Y no basta con que el par EXISTA en algun sitio de esa tabla: una continuacion que empiece por
  # un par vivo cualquiera —«200 1 loquesea»— volveria a abrir registro. Se exige que sea el par
  # SIGUIENTE ESPERADO: las dos invocaciones de `ps` recorren la tabla de procesos en el mismo
  # orden, asi que el registro k-esimo tiene que abrir con la fila k-esima. Una continuacion solo
  # colaria si imitase exactamente al proceso que viene detras.
  # ── POR QUE LA CLAVE NO LLEVA EL CGROUP, aunque la ref 05 §4 nombre los tres ─────────────────
  # La doctrina dice «se mira PID, su padre y su cgroup». Se intento meterlo aqui y **se midio que
  # no se puede con `ps`**: la anchura de la columna `cgroup` la decide `ps` segun la invocacion, y
  # las dos de aqui son distintas. Medido en esta maquina: con `pid=,ppid=,cgroup=` las cadenas
  # llegan hasta 102 caracteres; con `pid=,ppid=,cgroup=,etime=,args=` se truncan a 27. Un
  # `cgroup:64=` tampoco lo arregla — el `:N` de `ps` es anchura MINIMA, no maxima. Resultado con la
  # version que lo intentaba: NINGUNA clave casaba y el listado salia con **la cabecera sola**, que
  # es exactamente el fail-open que este bloque existe para cerrar. Un tercer discriminante que
  # vacia la salida es peor que dos que la conservan.
  # Lo que SI discrimina aqui, y es lo que hay que leer al juzgar esta funcion: la clave no es
  # «(pid, ppid)» a secas, sino «(pid, ppid) EN LA POSICION ESPERADA del recorrido». Las dos
  # invocaciones recorren la tabla en el mismo orden y la busqueda va HACIA DELANTE, asi que una
  # linea solo abre registro si su par es el siguiente pendiente. Para que un PID reutilizado
  # colara tendria que reaparecer justo en su hueco del recorrido, y ademas el contador de PIDs
  # tendria que dar la vuelta entre dos `ps` consecutivos: no se ha podido reproducir.
  # CONDICION DE CIERRE, para quien venga: leer `/proc/<pid>/cgroup` en vez de la columna de `ps`
  # —ahi no hay truncado— y unir por PID; cuesta una lectura de fichero por proceso y ata la
  # funcion a Linux de forma explicita, no de refilon.
  estructura="$(ps -eo pid=,ppid= 2>/dev/null)" \
    || { echo "runners-vivos: PRECOND: la segunda lectura de \`ps\` fallo; sin ella no se pueden atribuir los registros" >&2; exit 2; }
  instantanea="$(awk '
    NR == FNR { esperado[++n] = $1 " " $2; next }
    {
      clave = $1 " " $2
      # Se busca HACIA DELANTE desde el ultimo par consumido: las dos capturas recorren la tabla
      # en el mismo orden, asi que un proceso que ya no este solo adelanta el puntero. Buscar
      # hacia delante —y no "que el par exista en algun sitio"— es lo que impide que una
      # continuacion cualquiera abra registro.
      for (j = k + 1; j <= n; j++) if (esperado[j] == clave) { k = j; print; next }
      # sin par atribuible: se descarta
    }
  ' <(printf '%s\n' "$estructura") <(printf '%s\n' "$instantanea"))" \
    || { echo "runners-vivos: PRECOND: fallo al atribuir los registros de \`ps\`; sin eso el listado no significa nada" >&2; exit 2; }
  # Aqui el `read` con IFS por defecto SI es lo correcto, y no es lo mismo que el `IFS=$'\t'` que
  # se come celdas vacias en un TSV: la salida de `ps` esta separada por RACHAS de espacios de
  # ancho variable, no por un delimitador por campo, y no hay campos vacios que perder — `pid`,
  # `ppid` y `etime` siempre traen valor. Colapsar espacios es justo lo que hace falta.
  printf '%s\n' "$instantanea" | grep -E -- "$patron" | while read -r pid ppid etime resto; do
    [ "$pid" = "$$" ] && continue
    [ "$ppid" = "$$" ] && continue
    seg="$(etime_a_segundos "$etime")" || seg='?'
    printf '%-10s %-14s %s\n' "$pid" "${seg}s" "$resto"
  done
  exit 0
fi
