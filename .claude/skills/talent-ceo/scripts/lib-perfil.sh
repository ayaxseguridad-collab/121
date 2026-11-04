#!/usr/bin/env bash
# lib-perfil.sh — Lectura y validación del PERFIL DE INSTANCIA de la fábrica (talent-ceo, ref 04).
#
# El perfil es un TSV de 6 columnas que describe la TOPOLOGÍA de una instancia: qué máquinas, torres,
# estaciones, canales, runners, crons, bus, ceo y pm existen. Es DATO, no código: este skill no
# asume ningún nombre, prefijo ni forma. Repo-agnóstico, token-only, sin MCP.
#
# Se "source-ea" (`. lib-perfil.sh`) o se invoca como `lib-perfil.sh --check [ruta]`.
#
# ── CONTRATO ÚNICO DE VALIDACIÓN ───────────────────────────────────────────────────────────────
# `--check` ES `perfil_validate`: la MISMA función, ni una comprobación más ni una menos. Por
# construcción es imposible que un perfil pase el gate y sea rechazado en runtime.
# Autoridad: ENMIENDA-02 al plan maestro de skills ("--check implementa V1-V8; las cuatro reglas
# de ENMIENDA-01 son su NÚCLEO OBLIGATORIO: ninguna puede faltar ni relajarse").
# La cita es LITERAL y por eso dice V1-V8: **V9 se añadió después** (ambigüedad de `acceso=local`) y
# el contrato vigente es V1-V9, como enumera la tabla de aquí abajo y la ref 04. Se deja la cita sin
# retocar —una autoridad citada no se edita— con la diferencia dicha al lado, que es lo que evita
# leerla como el contrato de hoy.
#
#   V1  cabecera exacta de 6 columnas: tipo id maquina contenedor sesion atributos
#   V2  6 columnas en TODA fila de datos                                    [núcleo ENMIENDA-01]
#   V3  tipo en los NUEVE: maquina|torre|estacion|canal|runner|cron|bus|ceo|pm  [núcleo]
#   V4  id único GLOBALMENTE (no solo por (tipo,id))                        [núcleo]
#   V5  la maquina referenciada existe como fila `maquina`                  [núcleo]
#   V6  A LO SUMO UNA fila de cada singleton ceo/pm/bus — la AUSENCIA NO invalida
#   V7  atributos bien formados k=v;k=v
#   V8  sin clave de atributo duplicada dentro de una fila (jamás "gana el último")
#   V9  A LO SUMO UNA fila `maquina` con `acceso=local` — la AUSENCIA NO invalida (igual que V6)
#
# ── rc EXACTOS ─────────────────────────────────────────────────────────────────────────────────
#   perfil_validate / --check : 0 válido · 1 viola V1-V9 · 2 SIN PERFIL (ausente/ilegible)
#   perfil_rows / perfil_row1 : 0 servido · 1 ausente (o >1 en un perfil por lo demás válido)
#                               2 sin perfil O perfil inválido
#
# Por qué una violación da 2 —y no 1— en las APIs consumidoras: ahí rc 1 ya significa "cero filas de
# ese tipo", que es una respuesta NORMAL sobre la que el llamador ramifica. Si un perfil corrupto
# diera 1, `perfil_rows cron` sobre un fichero roto sería indistinguible de "este host no tiene
# crons": fail-open silencioso. Un perfil inválido es input inservible => mismo cubo que ausente.
#
# NUNCA se sirve una fila de un perfil inválido, aunque la fila pedida esté intacta.
set -uo pipefail

PERFIL_TIPOS_VALIDOS='maquina torre estacion canal runner cron bus ceo pm'
PERFIL_SINGLETONS='ceo pm bus'
PERFIL_CABECERA='tipo	id	maquina	contenedor	sesion	atributos'

_perfil_here() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }

# ── perfil_path ────────────────────────────────────────────────────────────────────────────────
# Precedencia (cadena literal): TA_PERFIL > $SECRET_DIR/perfil.tsv > motor
# TA_PERFIL es el override AUTORITATIVO; el del motor es el último recurso.
# TA_PERFIL definida pero rota => rc 2, NUNCA degrada al siguiente escalón: un override que apunta
# a un fichero que no está es un error de operación, no una invitación a usar otro perfil.
#
# DECLARADO, porque parece una excepción a lo anterior y no lo es: `TA_PERFIL=''` —definida y
# VACÍA— cuenta como NO definida y cae al siguiente escalón. Es deliberado: exportar la variable
# vacía es la única forma de ANULAR un override heredado del entorno, y de eso depende que un test
# pueda ejercitar los escalones de abajo sin desexportarla del proceso padre. «Rota» significa
# *apunta a algo que no sirve*; la cadena vacía no apunta a nada. Cambiarlo sería cambiar el
# CONTRATO de precedencia, no arreglar un fallo — y eso no entra por la puerta de un barrido.
# SECRET_DIR, en cambio, TIENE default en la fábrica y es un directorio de propósito general: que no
# contenga la copia opcional del perfil es NORMAL => se cae al motor.
perfil_path() {
  local p
  if [ -n "${TA_PERFIL-}" ]; then
    [ -f "$TA_PERFIL" ] && [ -r "$TA_PERFIL" ] || return 2
    printf '%s\n' "$TA_PERFIL"; return 0
  fi
  if [ -n "${SECRET_DIR-}" ]; then
    p="$SECRET_DIR/perfil.tsv"
    if [ -e "$p" ]; then
      [ -f "$p" ] && [ -r "$p" ] || return 2   # existe pero ilegible => fail-closed
      printf '%s\n' "$p"; return 0
    fi
  fi
  # ── El respaldo NO cuenta niveles: BUSCA hacia arriba ────────────────────────────────────────
  # Contar `../../..` es incorrecto por construcción en un fichero que viaja a dos árboles con
  # PROFUNDIDADES DISTINTAS: en el motor `scripts/` cuelga de `skills/talent-ceo/`, o sea 3
  # niveles hasta la raíz; en un repo de producto cuelga de `.claude/skills/talent-ceo/`, o sea
  # 4. Con `3` fijo, el respaldo resolvía a `.claude/manifiestos/` en producto y NO PODÍA
  # encontrar nada NUNCA — y esto es el fallback del perfil, la fuente de autoridad de la
  # identidad del sellador. Cambiar el 3 por un 4 sólo habría movido el fallo al otro árbol.
  #
  # Tampoco se codifica el nombre de la instancia: el skill es repo-agnóstico, así que se busca
  # el PATRÓN `manifiestos/*.perfil.tsv`. Si hay MÁS DE UNO, no se elige: es ambigüedad y se
  # falla cerrado, igual que con los singletons del perfil — adivinar cuál es "el bueno" sería
  # justo el tipo de suposición que este skill no hace.
  #
  # Y la ambigüedad se mide en TODA LA CADENA, no dentro de cada nivel. Parar en el primer nivel
  # con un candidato convertía «el más cercano gana» en una regla tácita: con un perfil en el repo
  # y otro en un ancestro, se elegía en silencio. Para la fuente de autoridad de la identidad del
  # sellador, elegir en silencio es exactamente lo que este fichero dice no hacer — y el operador
  # no tiene forma de enterarse de que había otro. Se recorre hasta `/` acumulando, y con más de
  # uno se falla cerrado DICIENDO CUÁLES son, que es lo que permite arreglarlo.
  local d cand n=0 hallado='' listado=''
  d="$(_perfil_here)"
  while :; do
    for cand in "$d"/manifiestos/*.perfil.tsv; do
      [ -f "$cand" ] && [ -r "$cand" ] || continue
      n=$((n + 1)); hallado="$cand"; listado="${listado:+$listado
}  - $cand"
    done
    [ "$d" = "/" ] && break
    d="$(dirname -- "$d")"
  done
  if [ "$n" -gt 1 ]; then
    printf 'perfil: AMBIGUO: %s ficheros *.perfil.tsv alcanzables desde %s; no se elige uno:\n%s\n' \
      "$n" "$(_perfil_here)" "$listado" >&2
    return 2
  fi
  [ "$n" -eq 1 ] && { printf '%s\n' "$hallado"; return 0; }
  return 2
}

# ── perfil_validate [ruta] ─────────────────────────────────────────────────────────────────────
# Diagnóstico legible por stderr con la regla violada (V1..V9) y la línea.
perfil_validate() {
  local f="${1-}"
  if [ -z "$f" ]; then f="$(perfil_path)" || return 2; fi
  [ -f "$f" ] && [ -r "$f" ] || return 2

  # NUL: se rechaza ANTES de validar, y fail-closed (rc 2, la banda de «ausente/ilegible»).
  # El motivo NO es estetico: `awk` no tiene contrato definido con el byte NUL —segun la
  # implementacion trunca el registro ahi, lo descarta, o lo arrastra— asi que un perfil con un NUL
  # puede recorrer las nueve reglas y salir VALIDO mientras el consumidor lee una fila distinta de
  # la que se valido. Validar lo que no se sabe leer es peor que no validar: da un visto bueno.
  # Va delante de todo para que ninguna regla llegue a mirar un fichero que no es texto.
  # La tuberia de estas dos lineas NO es la del defecto de esta ronda: `wc -c` consume la entrada
  # ENTERA y no sale al casar, asi que no hay SIGPIPE que `pipefail` convierta en fallo mudo. La
  # regla es «ningun lector que salga antes de tiempo», no «ninguna tuberia».
  local _bytes _sin_nul
  _bytes=$(LC_ALL=C wc -c < "$f") || return 2
  _sin_nul=$(LC_ALL=C tr -d '\0' < "$f" | LC_ALL=C wc -c) || return 2
  if [ "${_bytes// /}" -ne "${_sin_nul// /}" ]; then
    echo "perfil: byte NUL en $f: no es un fichero de texto; no se valida a ciegas" >&2
    return 2
  fi

  awk -F'\t' -v tipos="$PERFIL_TIPOS_VALIDOS" -v singles="$PERFIL_SINGLETONS" '
    function fail(regla, linea, detalle) {
      printf("perfil: %s violado (linea %d): %s\n", regla, linea, detalle) > "/dev/stderr"
      malo = 1; exit 1
    }
    BEGIN {
      # `split(..., " ")` SI usa la regla de racha de awk —colapsa espacios y recorta los extremos—,
      # y aqui eso es justo lo que se quiere: la entrada son dos listas CONSTANTES de este fichero,
      # no dato de nadie, y no hay elementos vacios que perder. Es la unica aparicion legitima del
      # colapso en todo el skill; se deja dicha para que no se confunda con el patron roto.
      n = split(tipos, t, " ");   for (i = 1; i <= n; i++) valido[t[i]] = 1
      m = split(singles, s, " "); for (i = 1; i <= m; i++) es_singleton[s[i]] = 1
      cabecera_vista = 0
    }
    /^#/ { next }
    NF == 0 { next }
    {
      # ── V1: cabecera exacta, y ha de ser la PRIMERA linea no comentario ──────────────────
      if (!cabecera_vista) {
        cabecera_vista = 1
        if (NF != 6 || $1 != "tipo" || $2 != "id" || $3 != "maquina" ||
            $4 != "contenedor" || $5 != "sesion" || $6 != "atributos")
          fail("V1", NR, "cabecera != [tipo id maquina contenedor sesion atributos]")
        next
      }
      # ── V2: 6 columnas en toda fila de datos ────────────────────────────────────────────
      if (NF != 6) fail("V2", NR, "la fila tiene " NF " columnas, no 6")
      tipo = $1; id = $2; maq = $3; atrs = $6
      # ── V3: tipo entre los nueve ────────────────────────────────────────────────────────
      if (!(tipo in valido)) fail("V3", NR, "tipo \"" tipo "\" fuera de los nueve validos")
      # ── V4: id unico GLOBALMENTE (no por (tipo,id)) ─────────────────────────────────────
      if (id in visto_id)
        fail("V4", NR, "id \"" id "\" ya usado en la linea " visto_id[id] \
                       " (tipo \"" visto_tipo[id] "\"); la unicidad es GLOBAL, no por (tipo,id)")
      visto_id[id] = NR; visto_tipo[id] = tipo
      # ── V6: a lo sumo UNA de cada singleton; la ausencia es valida ──────────────────────
      if (tipo in es_singleton) {
        if (tipo in visto_single)
          fail("V6", NR, "segunda fila \"" tipo "\" (la primera en la linea " visto_single[tipo] \
                         "); los singleton admiten a lo sumo una")
        visto_single[tipo] = NR
      }
      # ── V5: se acumula; se cruza al final, cuando ya se conocen todas las filas maquina ──
      if (tipo == "maquina") es_maquina[id] = 1
      if (maq != "-" && maq != "") { ref_maq[maq] = NR }
      # ── V9: a lo sumo UNA maquina con acceso=local ──────────────────────────────────────
      # `acceso=local` es lo que responde "cual de estas maquinas soy yo", y de ahi cuelga la
      # identidad del sellador: `bus-sellar` decide si un rol vive AQUI comparando contra ella.
      # Con DOS filas asi, los consumidores se quedan con la primera que encuentran — es decir,
      # la garantia de identidad se apoyaria en el ORDEN DE LAS LINEAS. Es la misma ambiguedad
      # que el propio paquete cierra en el sellador, aplicada un nivel mas abajo: al validador.
      # La AUSENCIA no invalida (misma doctrina que V6): un perfil puede describir una topologia
      # que no incluye a esta maquina, y los consumidores ya fallan cerrado cuando no la hay.
      if (tipo == "maquina" && $6 ~ /(^|;)acceso=local(;|$)/) {
        if (visto_local)
          fail("V9", NR, "segunda maquina con acceso=local (la primera en la linea " visto_local \
                         "); con dos, quien la use elige por orden de linea, no por dato")
        visto_local = NR
      }

      # ── V7 / V8: gramatica de atributos y claves no duplicadas ──────────────────────────
      # DECLARADO: un fragmento VACIO se ignora, asi que `x=1;;y=2` y un `;` final PASAN V7. Es
      # tolerancia deliberada de separador, no un agujero: no hay clave que validar en un hueco.
      # Endurecerlo cambiaria lo que un perfil valido significa para todos los consumidores, o sea
      # seria cambio de CONTRATO — la misma razon por la que la V10 de campos inertes se escalo en
      # vez de meterse aqui.
      if (atrs != "-" && atrs != "") {
        delete clave_vista
        np = split(atrs, par, ";")
        for (i = 1; i <= np; i++) {
          if (par[i] == "") continue
          if (index(par[i], "=") == 0)
            fail("V7", NR, "fragmento de atributo sin \"=\": \"" par[i] "\"")
          k = substr(par[i], 1, index(par[i], "=") - 1)
          if (k == "") fail("V7", NR, "fragmento de atributo con clave vacia: \"" par[i] "\"")
          if (k in clave_vista)
            fail("V8", NR, "clave de atributo \"" k "\" duplicada en la misma fila")
          clave_vista[k] = 1
        }
      }
      filas++
    }
    END {
      if (malo) exit 1
      if (!cabecera_vista) { print "perfil: V1 violado: no hay cabecera" > "/dev/stderr"; exit 1 }
      for (r in ref_maq)
        if (!(r in es_maquina)) {
          printf("perfil: V5 violado (linea %d): la maquina \"%s\" no existe como fila maquina\n",
                 ref_maq[r], r) > "/dev/stderr"
          exit 1
        }
      exit 0
    }
  ' "$f"
}

# ── TROCEO EN `awk`: correcto, y conviene saber POR QUE ────────────────────────────────────────
# Los `awk -F'\t'` de este fichero —el validador y los dos extractores— NO colapsan separadores:
# solo el FS por defecto (" ") tiene la regla especial de racha en awk. Con `-F'\t'`, la fila
# `a\t\tc` da NF=3 con `$2` vacio, que es justo lo que V2 necesita para contar seis columnas de
# verdad. Lo mismo vale para el `split(a, par, ";")` de `perfil_attr`. Se deja escrito porque el
# patron ROTO (`IFS=$'\t' read`) se parece mucho a estos y ya ha invitado a "arreglarlos".
#
# ── perfil_rows <tipo> [ruta] ──────────────────────────────────────────────────────────────────
# rc 0 + filas · rc 1 CERO filas de ese tipo (respuesta normal) · rc 2 sin perfil O perfil invalido.
perfil_rows() {
  local tipo="${1-}" f="${2-}" salida
  [ -n "$tipo" ] || return 2
  if [ -z "$f" ]; then f="$(perfil_path)" || return 2; fi
  perfil_validate "$f" || return 2          # invalido => 2, jamas 1: 1 significa "cero de ese tipo"
  # `-v` NO, `ENVIRON` SI: ver la nota de `perfil_attr`. `awk -v x=...` procesa escapes de barra
  # invertida en la asignacion, asi que el dato llegaria REINTERPRETADO.
  salida="$(TA_AWK_T="$tipo" awk -F'\t' '!/^#/ && NF==6 && $1==ENVIRON["TA_AWK_T"]' "$f")"
  [ -n "$salida" ] || return 1
  printf '%s\n' "$salida"; return 0
}

# ── perfil_row1 <tipo> [id] [ruta] ─────────────────────────────────────────────────────────────
# rc 0 + LA fila · rc 1 ausente o mas de una (en un perfil por lo demas VALIDO) · rc 2 sin
# perfil o perfil invalido. Para los singleton, ">1" ya viola V6 y por tanto llega como rc 2.
perfil_row1() {
  local tipo="${1-}" id="${2-}" f="${3-}" salida n
  [ -n "$tipo" ] || return 2
  if [ -z "$f" ]; then f="$(perfil_path)" || return 2; fi
  perfil_validate "$f" || return 2
  # `ENVIRON` y no `-v`, por lo mismo: con `-v i=...` el id `\x41` casaria la fila `A`, y dos ids
  # que V4 tiene por distintos —porque lo son como texto— se volverian el mismo al buscarlos.
  salida="$(TA_AWK_T="$tipo" TA_AWK_I="$id" awk -F'\t' \
            '!/^#/ && NF==6 && $1==ENVIRON["TA_AWK_T"] &&
             (ENVIRON["TA_AWK_I"]=="" || $2==ENVIRON["TA_AWK_I"])' "$f")"
  [ -n "$salida" ] || return 1
  n="$(printf '%s\n' "$salida" | wc -l)"
  [ "$n" -eq 1 ] || return 1
  printf '%s\n' "$salida"; return 0
}

# ── perfil_campos <linea> ──────────────────────────────────────────────────────────────────────
# Trocea una linea TSV en campos CONSERVANDO LOS VACIOS y los deja en el array PERFIL_CAMPOS.
#
# NO se usa `IFS=$'\t' read -r a b c ...`, que es lo que pide el cuerpo. El tabulador es
# IFS-WHITESPACE, y con eso el shell colapsa las secuencias de separadores y se come los campos
# vacios. Medido:
#     printf 'a\t\tc\n' | { IFS=$'\t' read -r x y z; }   ->  x=[a] y=[c] z=[]
# Es decir: la celda vacia desaparece y TODO lo que viene detras se corre una columna a la
# izquierda. En un perfil eso no da un error, da una RESPUESTA DISTINTA: `atributos` pasa a leerse
# de `sesion`, y de ahi cuelgan `acceso=local` y `usuario=`, o sea la identidad. Falla en silencio.
#
# El contrato ADMITE celdas vacias: V2 solo exige `NF == 6` —contado con `awk -F'\t'`, que no
# colapsa— y V5 contempla explicitamente `maquina == ""`. Asi que esto no es un caso teorico.
#
# `cut -f` y `awk -F'\t'` SI conservan los vacios (medido igual), y por eso los sitios que ya
# troceaban con ellos estan bien y se quedan como estan.
perfil_campos() {
  local linea="${1-}" tab=$'\t' campo
  PERFIL_CAMPOS=()
  while :; do
    campo="${linea%%"$tab"*}"
    PERFIL_CAMPOS+=("$campo")
    [ "$campo" = "$linea" ] && break      # ya no queda separador: era el ultimo campo
    linea="${linea#*"$tab"}"
  done
}

# ── perfil_attr <atributos> <clave> ────────────────────────────────────────────────────────────
# PURA: recibe la CADENA de atributos, no resuelve perfil ni toca ficheros. rc 0 + valor | rc 1.
perfil_attr() {
  local atrs="${1-}" clave="${2-}"
  [ -n "$clave" ] || return 1
  # ── EL DATO NO VIAJA POR `-v`: `awk` REINTERPRETA LOS ESCAPES DE LA ASIGNACION ────────────────
  # `awk -v a='loc\141l'` deja `a` valiendo `local`. Medido. Y eso no es cosmetico aqui: el
  # validador ve el texto CRUDO —para V9, `acceso=loc\141l` NO es `acceso=local`, asi que dos
  # maquinas escritas asi pasan el limite de "a lo sumo una local"— mientras que este lector
  # devuelve `local` para las dos. El perfil diria una cosa y sus consumidores otra, que es
  # justo el desacuerdo que V9 existe para impedir.
  # `ENVIRON` entrega el valor VERBATIM: no hay paso de escapes.
  TA_AWK_A="$atrs" TA_AWK_K="$clave" awk '
    BEGIN {
      a = ENVIRON["TA_AWK_A"]; k = ENVIRON["TA_AWK_K"]
      n = split(a, par, ";")
      for (i = 1; i <= n; i++) {
        p = index(par[i], "=")
        if (p == 0) continue
        if (substr(par[i], 1, p - 1) == k) { print substr(par[i], p + 1); exit 0 }
      }
      exit 1
    }'
}

# ── CLI: --check ───────────────────────────────────────────────────────────────────────────────
# `--check` ES `perfil_validate`. No añade ni quita comprobaciones.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1-}" in
    --check)
      ruta="${2-}"
      if [ -z "$ruta" ]; then
        ruta="$(perfil_path)" || { echo "perfil: SIN PERFIL (ningun candidato legible)" >&2; exit 2; }
      fi
      if perfil_validate "$ruta"; then echo "perfil: VALIDO ($ruta)"; exit 0
      else rc=$?; [ "$rc" -eq 2 ] && echo "perfil: SIN PERFIL ($ruta)" >&2; exit "$rc"; fi
      ;;
    --help|'')
      sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)
      echo "uso: lib-perfil.sh --check [ruta] | --help" >&2; exit 2 ;;
  esac
fi
