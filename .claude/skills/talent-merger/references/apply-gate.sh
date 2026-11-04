#!/usr/bin/env bash
# apply-gate.sh — implementación CANÓNICA y ÚNICA de `classify_log` y `publish_close`.
#
# POR QUÉ EXISTE COMO FICHERO REAL (par8-p1, BLOQUEANTE): la receta de `ref 02` §8 INVOCA
# `publish_close`. Mientras la definición vivía solo dentro de un fence de Markdown, la receta
# publicada no la cargaba ni la definía —un comentario que remite a ref 01 no crea alcance de
# función en Bash— y un operador que la copiara obtenía `command not found` con el `APPLY-RUN`
# ya abierto. El selftest, además, la inyectaba concatenándola: acreditaba un programa DISTINTO
# del que se opera. Aquí hay UNA definición, cargable por la receta y ejecutada tal cual por el
# test. No se duplica en ningún .md: ref 01 documenta la doctrina y apunta a este fichero.
#
# Contrato de entrada (el llamador las define): $CLASS_FILE $ESTACION $PR $RUN_ISO $RUN_NONCE
#                                              $FLOCK_FILE $LOG

# LOCALE FIJADO EN EL ÁMBITO DE CADA COMPARACIÓN DE TITULARIDAD — NO al cargar el fichero
# (CLASE 1, ronda 37, BLOQUEANTE B-02, sobre v22). El hallazgo tiene DOS capas de historia: v20/
# ronda 35 parcheó los dos predicados con `local LC_ALL=C`; v22/ronda 36 vio que `TM_RE_TERMINAL`
# se evalúa FUERA de esos predicados (en `titular_vigente`) y "resolvió" exportando `LC_ALL=C` UNA
# vez al cargar el fichero, declarándolo "verdadero por construcción". La pasada 1 de v22 midió que
# NO lo es: un `export` al hacer `source` es una RECOMENDACIÓN que el llamador PISA. Puede reasignar
# `LC_ALL` DESPUÉS del source —`export LC_ALL=en_US.utf8`, una asignación simple `LC_ALL=…`, o un
# prefijo `LC_ALL=… titular_vigente`— y reaparece la aceptación de dígitos unicode que la ronda 36
# creía cerrada: `M[1-5]` bajo `en_US.utf8`/`en_GB.utf8` casa `٣ ۲ ３ ④ ²`, así que `# ✅ M٣ MERGED
# #6` —que NINGÚN emisor canónico produce— cierra una reserva viva bajo ese locale y no bajo C.
# Medido en las TRES vías: el titular del MISMO flock se voltea M2 → NADIE según lo que el llamador
# ponga tras el source. **El ámbito que MANDA es el de la COMPARACIÓN, no el de la carga.**
#
# EL ARREGLO, verificable: cada comparación que decide titularidad fija C en SU PROPIO ámbito.
#   · los dos predicados de forma (`identidad_slot_valida`/`identidad_takeover_valida`):
#     `local LC_ALL=C` — sólo hacen `[[ =~ ]]` (builtin, usa el LC_ALL del ámbito), no lanzan
#     subproceso, así que un `local` a secas basta.
#   · `titular_vigente`: `local -x LC_ALL=C` — cubre el `[[ =~ $TM_RE_TERMINAL ]]` (builtin) Y los
#     subprocesos `sed` que extrae los campos. El `-x` es NECESARIO y MEDIDO: sin el export del
#     módulo, un `local` a secas NO llega al hijo (el `sed` heredaría el locale del llamador);
#     `local -x` exporta C al hijo y se DESHACE al volver la función, sin filtrar C al entorno del
#     llamador como sí hacía el export global. `local`/`local -x` re-establecen C AL ENTRAR en la
#     función, así que pisan cualquier reasignación que el llamador hiciera tras el source.
#
# POR QUÉ SE RETIRA EL `export LC_ALL=C` DEL MÓDULO (no se conserva "por si acaso"): mantenerlo
# TAPARÍA en silencio una función futura que olvidara su `local LC_ALL=C` —el olvido no rompería
# nada y la propiedad dejaría de ser verificable—. Sin él, una comparación de titularidad nueva SIN
# ámbito C ROMPE bajo un llamador con locale hostil. T33 (`proc-m13.selftest.sh`) lo mide como
# mutante: quita `local -x LC_ALL=C` de `titular_vigente` y, con el llamador reasignando el locale
# TRAS el source (tres vías), el terminal forjado `M٣` cierra la cadena y M4 gana. «Si alguien
# añade una comparación sin ámbito C, algo rompe» pasa de deseo a propiedad medida.

# ── titular_vigente — resolución EJECUTABLE de la cadena de sucesión de un slot.
#
# POR QUÉ EXISTE: la cadena `SLOT-CLAIM` → `SLOT-CLAIM-TAKEOVER` → … estaba descrita en ref 01 y
# protegida SOLO por invariantes de presencia de texto: cero cobertura ejecutable en el arnés y en
# este fichero. Un invariante que no EJECUTA lo que dice vigilar no vigila — la doctrina podía
# quedar bien escrita y mal implementada sin que nada enrojeciera.
#
# REGLA (ref 01, «Autoridad del takeover»): la titular vigente NO es el primer takeover publicado,
# es el resultado de RECORRER la cadena en el orden del flock, donde cada eslabón cita el
# `<nonce-anterior>` EXACTO — la generación, no el nombre — Y (CLASE 3 v22, ronda 36, MAYOR) el
# MISMO `#<PR>` que abrió la cadena y la MISMA `<estación-anterior>` que de verdad la ostentaba:
# el nonce ata la GENERACIÓN, pero no ata por sí solo el takeover al RECLAMO (PR) ni acredita que
# quien se cita como sucedido sea real — un takeover con PR ajeno o con estación-anterior ajena
# pero el nonce real copiado sucedía igual antes de esta ronda.
#   · takeover que cita la generación VIGENTE, el MISMO PR y la MISMA estación → sucesión legítima
#   · takeover con el nonce correcto pero PR o estación distintos → inválido, se descarta
#   · dos takeovers que citan el MISMO nonce   → colisión: gana el PRIMERO, el resto son VOID
#   · takeover que cita un nonce inexistente
#     o ya superado                            → inválido, se descarta (no rompe la cadena)
#
# Entrada: $1 = ruta al flock · $2 = slot OBLIGATORIO y NUMÉRICO (1-6 dígitos; sin modo sin filtro,
# CLASE 2 v23 B-01). Salida: "<estación> <nonce>" de la titular vigente, o vacío si no hay
# `SLOT-CLAIM` inicial. Salida vacía NO es "libre": es "sin cadena", y el llamador decide.
#
# ILEGIBLE NO ES «SIN CADENA» (ronda 33, clase del inventario `set -e`). Abrir el flock es una
# REDIRECCION, y una redirección que no puede abrir el fichero hace fallar la línea entera: bajo
# el `set -e` del llamador eso ABORTA EL SHELL ahí mismo —el `return 0` del final no llega a
# existir, y tampoco ningún rc—, y con `errexit` apagado se caía hasta el final devolviendo VACÍO,
# que significa otra cosa. La apertura se hace ANTES del bucle, con `exec 8< "$f" || return 2` —en
# la forma que `errexit` no mata—, y se contesta con un rc PROPIO: **rc 2 = NO SABER**, que no se
# confunde con **rc 0 + salida vacía = NADIE**. Es la misma lección que la ronda 30 fijó en
# `publish_close`: VOID no es NEGATIVO, y un fichero ilegible no produce una ausencia.
# ── identidad_slot_valida — forma canónica del SLOT-CLAIM, MISMA FORMA que RE_EST/RE_PR/RE_ISO/
# RE_NONCE de `02-protocolo-por-pr.md` §8.0 (`identidad_canonica`). Dos recetas que no comparten
# proceso no pueden compartir variable — pero SI comparten la FORMA, citada aquí, no reinventada.
#
# CLASE 1 (ronda 34, BLOQUEANTE x2, CR sobre v19): la receta del SLOT-CLAIM interpolaba
# `ESTACION`/`SLOT`/`PR`/`RUN_ISO`/`NONCE`/`ARCHIVO` en `claim_line` SIN VALIDAR NINGUNO, y
# `printf` conserva los saltos de línea. Medido: un `$ARCHIVO` con un salto embebido publicaba
# TRES líneas en el flock, una de ellas un `# APPLY-RUN […]` FORJADO — el dato volvía a ser
# código, la MISMA clase que la ronda 28 cerró en `publish_close` y que aquí nadie había mirado.
# Y un `ESTACION=M9` —una estación que no existe— entraba en contrato con rc 0 y ADMITIDA: nada
# validaba la forma. «Lo que el contrato ya resolvió no se vuelve a resolver: se invoca» — el
# remedio (estas cinco ERE) ya estaba escrito en ref 02 §8.0; el error fue no citarlo.
#
# Y la lectura tiene que validar IGUAL que la escritura: `titular_vigente`, más abajo, rechaza
# ahora cualquier `[<estación>]`/`<nonce>` que no case con la forma canónica al recorrer la
# cadena — un valor que no case RECHAZA, no «se limpia» (limpiar decide en silencio qué se
# descarta; rechazar hace visible que algo no encajó).
TM_RE_EST='^[[]M[1-5][]]$'
TM_RE_PR='^#[1-9][0-9]*$'
TM_RE_ISO='^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$'
TM_RE_NONCE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
# LÍMITE DE LONGITUD (MENOR, p1 M-02, ronda 35): `[0-9]+`/`[A-Za-z0-9_.-]+` sin cota aceptaban un
# SLOT de 10.000 dígitos con rc 0 — no es una vía de ataque conocida (no hay backtracking
# catastrófico posible en estos patrones: sin cuantificadores anidados), pero un campo que termina
# en un nombre de fichero/línea de log/argumento de proceso no debería aceptar una longitud
# arbitraria solo porque la forma es correcta. Cotas generosas frente a lo real (migraciones reales
# rondan 50-60 caracteres, el tope de slots la baja centena) sin inventar un límite ajustado que
# rompa con el próximo nombre largo legítimo.
TM_RE_SLOT='^[0-9]{1,6}$'
# `ARCHIVO`: WHITELIST estricta, no una lista de caracteres prohibidos — enumerar lo que se
# prohíbe siempre deja algo fuera (el salto de línea del ataque medido, un paréntesis que
# cerraría el campo antes de tiempo, un espacio). Prohibir la CAPACIDAD —solo alfanumérico, `._-`,
# termina en `.sql`— es lo único que cierra la clase, la misma lección del ARGV de `publish_close`.
# La cota de 200 es del STEM (todo lo que precede a `.sql`), no del nombre completo — aclarado
# ronda 36, MENOR p1-M02: el nombre completo puede llegar a 204 bytes (200 + los 4 de `.sql`), no
# 200. Es la misma cota que la doctrina describe como "200 caracteres de nombre" (ref 01/acta):
# ese "de nombre" se refiere al STEM significativo, código y doctrina dicen lo mismo.
TM_RE_ARCHIVO='^[A-Za-z0-9_.-]{1,200}\.sql$'
# TM_RE_TERMINAL — LOS TRES TERMINALES DEL CICLO DE VIDA DEL SLOT, EN UN SOLO SITIO (CLASE 2,
# ronda 35, BLOQUEANTE x2, dos pasadas independientes convergentes sobre v20): la doctrina (ref 01
# §2, "Ciclo de vida del SLOT-CLAIM") ya declara que `MERGED`, `BOUNCED` y `CEO RESUELTO` cierran
# la cadena — el automata de `titular_vigente` solo conocía `SLOT-CLAIM`/`SLOT-CLAIM-TAKEOVER` y
# los ignoraba: el claim viejo seguía gobernando y un `SLOT-CLAIM` nuevo sobre el mismo slot
# reutilizado se descartaba. UN SOLO regex, no una lista de `case` separados: declarar un CUARTO
# terminal mañana es añadir UNA alternativa aquí, no localizar y replicar un `case` nuevo en cada
# sitio que lo comprueba — la MISMA razón que ya vale para TM_RE_EST/PR/ISO/NONCE/ARCHIVO/SLOT.
TM_RE_TERMINAL='^# (✅ M[1-5] MERGED|✅ CEO RESUELTO|🔴 BOUNCED) #([1-9][0-9]*)$'

identidad_slot_valida() {  # $1=ESTACION $2=SLOT $3=PR $4=RUN_ISO $5=NONCE $6=ARCHIVO
  # LC_ALL=C, SOLO EN ESTE ÁMBITO (CLASE 1, ronda 35, BLOQUEANTE — hallazgo propio al medir el
  # ataque "ARCHIVO unicode"): bajo un locale con colación (`en_US.UTF-8` medido), el bracket
  # expression `[A-Za-z0-9_.-]` de `TM_RE_ARCHIVO` NO es un rango ASCII — la colación del locale
  # mete ahí letras acentuadas/unicode ("archívo.sql" CASABA). Un predicado de forma que cambia de
  # significado según el locale del proceso que lo invoca no es un predicado, es una lotería. `local
  # LC_ALL=C` fija la semántica de los brackets a bytes ASCII para esta función exclusivamente, sin
  # exportar ni afectar al llamador.
  local LC_ALL=C
  [[ "[${1:-}]" =~ $TM_RE_EST ]]     || return 1
  [[ "${2:-}"   =~ $TM_RE_SLOT ]]    || return 1
  [[ "#${3:-}"  =~ $TM_RE_PR ]]      || return 1
  [[ "${4:-}"   =~ $TM_RE_ISO ]]     || return 1
  [[ "${5:-}"   =~ $TM_RE_NONCE ]]   || return 1
  [[ "${6:-}"   =~ $TM_RE_ARCHIVO ]] || return 1
}
# ── identidad_takeover_valida — MISMOS átomos TM_RE_*, forma distinta (CLASE 1, ronda 35, sobre
# v20): un `SLOT-CLAIM-TAKEOVER` no tiene `ARCHIVO`, tiene DOS campos de estación/nonce (el nuevo
# y el que sucede) — comparte los átomos de forma con `identidad_slot_valida`, no los reinventa;
# lo que cambia es la FORMA DEL REGISTRO, que es un hecho de la doctrina (ref 01), no una segunda
# definición de «línea válida» para el MISMO tipo de registro.
identidad_takeover_valida() {  # $1=EST_NUEVA $2=SLOT $3=PR $4=RUN_ISO $5=NONCE_NUEVO $6=EST_ANTERIOR $7=NONCE_ANTERIOR
  local LC_ALL=C   # mismo motivo que identidad_slot_valida — bracket expressions ASCII, no colación del locale
  [[ "[${1:-}]" =~ $TM_RE_EST ]]     || return 1
  [[ "${2:-}"   =~ $TM_RE_SLOT ]]    || return 1
  [[ "#${3:-}"  =~ $TM_RE_PR ]]      || return 1
  [[ "${4:-}"   =~ $TM_RE_ISO ]]     || return 1
  [[ "${5:-}"   =~ $TM_RE_NONCE ]]   || return 1
  [[ "[${6:-}]" =~ $TM_RE_EST ]]     || return 1
  [[ "${7:-}"   =~ $TM_RE_NONCE ]]   || return 1
}

# $2 = SLOT a filtrar (CLASE 2, ronda 34, BLOQUEANTE — CR sobre v19): esta función caminaba la
# cadena del FLOCK ENTERO, tomando el PRIMER `SLOT-CLAIM` que encontraba sin mirar A QUÉ SLOT
# pertenecía. Un flock compartido por MÚLTIPLES slots concurrentes (el caso real: el bus lleva
# los `SLOT-CLAIM` de TODAS las migraciones en vuelo, no una por fichero) hacía que un claim
# histórico de OTRO slot decidiera la titularidad de ESTE — falso rechazo (M2 cede por figurar
# en la cadena del slot 100 cuando pedía el 101) y falsa admisión (M1 admitida en el 101 porque
# esa cadena, mal filtrada, seguía viendo su claim del 100) al mismo tiempo. El caller que SÍ
# conoce su slot —como el cableado de `ref 01` §2 punto 3— filtra pasándolo, y la función resuelve
# el recurso que de verdad gobierna: EL SLOT, no el flock entero. El `$2` es OBLIGATORIO y NUMÉRICO
# (CLASE 2 v23 B-01): ya NO hay «`$2` vacío = sin filtro» —esa escapatoria, controlable por el
# llamador, era el hueco de B-01—; un slot vacío/sólo-espacios/no-numérico es rc 3, y el filtro
# por slot SIEMPRE se aplica.
#
# CLASE 1 (ronda 35, BLOQUEANTE x2, dos pasadas independientes convergentes sobre v20): esta
# función validaba SOLO `[<estación>]` y `<nonce>` — dos de los seis campos que la ESCRITURA
# exige con `identidad_slot_valida`. Medido sobre el sujeto real: `PR=0`, un `RUN_ISO` no-ISO,
# `ARCHIVO` vacío/unicode/con barra invertida/con retorno de carro, y una línea con doble espacio
# antes del slot, ENTRABAN por lectura aunque la escritura los habría rechazado — «lo que el
# escritor rechaza, el lector lo admite como autoridad». Dos definiciones de «línea válida»
# divergen tarde o temprano; el arreglo NO añade casos sueltos, HACE que lectura y escritura
# invoquen el MISMO predicado: se extraen los SEIS campos de la línea y se llama
# `identidad_slot_valida`/`identidad_takeover_valida` —la MISMA función que usa la escritura—,
# y además se RECONSTRUYE la línea canónica a partir de los campos ya validados y se exige que
# coincida BYTE A BYTE con la línea leída (`recon = line`): eso cierra cualquier separador extra,
# campo insertado o reordenado que una validación campo-a-campo por posición fija podría no
# notar. LÍMITE DECLARADO, simétrico y no un hueco de este arreglo: un byte NUL sufijado a una
# línea por lo demás canónica es indistinguible para `read` de Bash de la misma línea sin el NUL
# —Bash no puede representar NUL en una variable de shell, ni al leer ni al escribir (el mismo
# `identidad_slot_valida` que valida en escritura tampoco podría verlo)— así que ambos lados
# comparten el punto ciego, no divergen en él; detectarlo exigiría un escáner de bytes fuera de
# Bash, fuera del alcance de este predicado.
titular_vigente() {  # $1 = ruta al flock · $2 = slot — OBLIGATORIO Y NUMÉRICO en la llamada
                      # (CLASE 2 v23, ronda 37, BLOQUEANTE B-01 — pasada 1 sobre v22): CONTAR
                      # ARGUMENTOS NO ES FILTRAR. La guarda de v22 exigía `$#=2` pero ACEPTABA el
                      # slot VACÍO, y con `$slot` vacío el recorrido volvía a ser SIN FILTRO para
                      # CUALQUIER llamador —`titular_vigente(f, "")` caminaba el flock entero igual
                      # que la vieja llamada de un argumento, y `intake_slot(f, EST, "")` heredaba
                      # ese hueco—. El "modo sin filtro declarando `""` explícito" era una
                      # ESCAPATORIA que el LLAMADOR controla: cualquiera podía pasar `""` y
                      # recuperar el hueco que la CLASE 2 debía cerrar; una diferencia que el
                      # llamador puede poner no es una guarda, es una nota con `if`. El arreglo
                      # RETIRA la escapatoria entera: el slot es OBLIGATORIO y NUMÉRICO (mismo
                      # `TM_RE_SLOT` que valida la ESCRITURA del claim), NO existe modo sin filtro,
                      # y arnés y consumidor pasan un slot real IGUAL — no se distinguen por ninguna
                      # bandera. `$#` de 1 (slot OMITIDO) → rc 3; slot vacío, sólo espacios o
                      # no-numérico → rc 3 también: «LLAMADA MAL FORMADA», el mismo valor que ningún
                      # `if rc -eq 0/1` confunde con una decisión operativa (0 titular / 2 ilegible).
  local -x LC_ALL=C   # B-02 (ronda 37): C en ESTE ámbito y EXPORTADO al `sed` — pisa cualquier LC_ALL que el llamador reasigne tras el source; ver cabecera del fichero. También fija C para el `[[ =~ $TM_RE_SLOT ]]` de la guarda de abajo (bracket ASCII, no colación).
  [ "$#" -eq 2 ] || { echo "titular_vigente: se requieren 2 argumentos (flock, slot NUMÉRICO) — el slot es obligatorio, nunca lo omitas (CLASE 2 v23)" >&2; return 3; }
  [[ "$2" =~ $TM_RE_SLOT ]] || { echo "titular_vigente: slot vacío/no-numérico ('$2') — el slot es un entero de 1-6 dígitos y es OBLIGATORIO; no existe modo «sin filtro» (CLASE 2 v23 B-01)" >&2; return 3; }
  local f="$1" slot="$2" est="" nonce="" pr="" line cand_est cand_nonce cand_slot
  local _m cand_pr cand_iso cand_archivo cand_prev_est cand_prev_nonce recon
  # NO SE COMPRUEBA `-r` Y SE CONFÍA EN QUE LA REDIRECCIÓN LO RESPETE (ronda 33, SUGERENCIA — mi
  # pasada 1 sobre v18): `-r` acredita el bit de permiso, no que abrir vaya a funcionar. Es la
  # misma familia que todo lo de arriba: comprobar una cosa y confiar en otra.
  #
  # Y NI SIQUIERA ABRIR BASTA — MEDIDO, no supuesto: sobre un DIRECTORIO, `exec 8< "$dir"` linux
  # da **rc 0** (el `open()` tiene éxito), y es el `read` DE DENTRO el que falla con la primera
  # línea vacía — indistinguible de EOF, así que la función devolvía **rc 0 + vacío** ("NADIE"),
  # justo el caso contrario al que este bloque existe para evitar: un ILEGIBLE leído como ausencia.
  # `[ -f ]` distingue eso ANTES del `exec`: no cierra el TOCTOU teórico entre el check y el
  # `open()` (inherente a cualquier check-then-open sin primitivas atómicas, y desproporcionado
  # para un flock cooperativo entre estaciones, no un adversario activo) — cierra el caso REAL que
  # la sugerencia señaló y que se acaba de medir arriba.
  [ -f "$f" ] || return 2
  exec 8< "$f" || return 2
  # `|| [ -n "$line" ]`: un flock cuyo ÚLTIMA línea no acabe en salto se perdería
  # entera con el idiom corriente — y sería justo el token más reciente.
  while IFS= read -r line <&8 || [ -n "$line" ]; do
    case "$line" in
      '# SLOT-CLAIM '*)
        # Sólo la PRIMERA reserva abre la cadena; una segunda sobre el mismo slot no la reabre.
        [ -n "$nonce" ] && continue
        # CLASE 1: se extraen los SEIS campos (no solo estación+nonce) y se validan con el MISMO
        # predicado que la escritura — `identidad_slot_valida`, invocada, no reimplementada — y
        # se exige que reconstruir la línea canónica a partir de esos campos reproduzca BYTE A
        # BYTE la línea leída. Cualquier separador extra, campo insertado o forma que no case
        # (PR=0, ISO no-ISO, ARCHIVO vacío/unicode/con barra invertida/con CR, doble espacio antes
        # del slot) rompe la extracción, el predicado o el round-trip — nunca los tres a la vez
        # por azar — y la línea se descarta como si no existiera, igual que antes lo hacía una
        # forma sin corchetes.
        _m="$(printf '%s\n' "$line" | sed -n 's/^# SLOT-CLAIM \(.*\) = #\(.*\) \[\(.*\)\] \(.*\) \(.*\) (\(.*\))$/\1\x1f\2\x1f\3\x1f\4\x1f\5\x1f\6/p')"
        IFS=$'\x1f' read -r cand_slot cand_pr cand_est cand_iso cand_nonce cand_archivo <<<"$_m"
        identidad_slot_valida "$cand_est" "$cand_slot" "$cand_pr" "$cand_iso" "$cand_nonce" "$cand_archivo" || continue
        recon="# SLOT-CLAIM $cand_slot = #$cand_pr [$cand_est] $cand_iso $cand_nonce ($cand_archivo)"
        [ "$recon" = "$line" ] || continue
        # FILTRO POR SLOT — sin esto, el claim histórico de OTRO slot abre (o cierra) la cadena de
        # ESTE. El slot ya viene validado NUMÉRICO por la guarda de arriba y SIEMPRE filtra: ya no
        # hay modo `""` sin filtro (CLASE 2 v23 B-01). `$cand_slot` ya viene validado por forma.
        [ "$cand_slot" = "$slot" ] || continue
        est="$cand_est"; nonce="$cand_nonce"; pr="$cand_pr"
        ;;
      '# SLOT-CLAIM-TAKEOVER '*)
        [ -n "$nonce" ] || continue          # sin cadena abierta no hay nada que suceder
        # Mismo tratamiento CLASE 1, con la forma propia del TAKEOVER (7 campos, sin ARCHIVO):
        # `identidad_takeover_valida` comparte los átomos TM_RE_* con la escritura del SLOT-CLAIM,
        # y el round-trip cierra la misma clase de forma inválida que arriba.
        _m="$(printf '%s\n' "$line" | sed -n 's/^# SLOT-CLAIM-TAKEOVER \(.*\) = #\(.*\) \[\(.*\)\] \(.*\) \(.*\) (supersede \(.*\) \(.*\))$/\1\x1f\2\x1f\3\x1f\4\x1f\5\x1f\6\x1f\7/p')"
        IFS=$'\x1f' read -r cand_slot cand_pr cand_est cand_iso cand_nonce cand_prev_est cand_prev_nonce <<<"$_m"
        identidad_takeover_valida "$cand_est" "$cand_slot" "$cand_pr" "$cand_iso" "$cand_nonce" "$cand_prev_est" "$cand_prev_nonce" || continue
        recon="# SLOT-CLAIM-TAKEOVER $cand_slot = #$cand_pr [$cand_est] $cand_iso $cand_nonce (supersede $cand_prev_est $cand_prev_nonce)"
        [ "$recon" = "$line" ] || continue
        [ "$cand_slot" = "$slot" ] || continue    # SIEMPRE filtra — ya no hay modo `""` sin filtro (CLASE 2 v23 B-01)
        # CLASE 3 v22 (ronda 36, MAYOR — dos pasadas convergentes): la forma completa (7 campos +
        # round-trip) da una apariencia de identidad completa mientras DOS relaciones esenciales
        # no se comprobaban — la forma dice CÓMO se escribe, la relación dice A QUÉ sucede. Medido:
        # un takeover con PR AJENO (#999, citando el nonce real de M2 sobre el #6 abierto) o con
        # `supersede` a una ESTACIÓN AJENA (M5, mismo nonce real de M2) se aceptaba igual — el
        # nonce por sí solo no ata el takeover al MISMO reclamo (mismo PR) ni a QUIEN de verdad lo
        # ostentaba (misma estación). Efecto de segundo orden: al asignar el PR del candidato
        # (`pr="$cand_pr"`, más abajo) sin validar, un `MERGED #6` legítimo posterior dejaba de
        # poder cerrar la cadena — quedaba esperando el PR forjado.
        [ "$cand_pr" = "$pr" ] || continue                # el takeover sucede al MISMO reclamo (PR), no a otro
        [ "$cand_prev_est" = "$est" ] || continue         # cita a quien REALMENTE la ostentaba, no a cualquiera
        [ "$cand_prev_nonce" = "$nonce" ] || continue    # cita una generación que NO es la vigente → VOID
        est="$cand_est"; nonce="$cand_nonce"; pr="$cand_pr"
        ;;
      '# ✅ '*|'# 🔴 '*)
        # CLASE 2 (ronda 35, BLOQUEANTE x2, dos pasadas independientes convergentes sobre v20): el
        # automata solo conocía SLOT-CLAIM/-TAKEOVER — MERGED/BOUNCED/CEO RESUELTO, que la doctrina
        # (ref 01 §2, "Ciclo de vida del SLOT-CLAIM") YA declara terminales, se ignoraban: el claim
        # viejo seguía gobernando y un SLOT-CLAIM nuevo sobre el slot reutilizado se descartaba
        # (`[ -n "$nonce" ] && continue` de arriba lo bloqueaba creyendo la cadena aún abierta).
        # El terminal se correlaciona por `#<PR>` —estos tokens no llevan slot— contra el `$pr` de
        # la cadena que ESTE recorrido ya tiene abierta: si no hay cadena abierta o el PR no es el
        # suyo, es ruido de otro ciclo y se ignora sin tocar el estado.
        [[ "$line" =~ $TM_RE_TERMINAL ]] || continue
        [ -n "$pr" ] && [ "${BASH_REMATCH[2]}" = "$pr" ] || continue
        est=""; nonce=""; pr=""    # la cadena se CIERRA — un SLOT-CLAIM posterior reabre limpio
        ;;
    esac
  done
  exec 8<&-
  # «NADIE» NO es un error. Con `[ -n … ] && printf …` como ÚLTIMA orden, la función devolvía 1
  # cuando la respuesta era «no hay titular» — indistinguible de un fallo, y bajo `set -e` mataba
  # al llamante justo en el caso que más necesita seguir vivo: el slot está libre.
  if [ -n "$nonce" ]; then printf '%s %s\n' "$est" "$nonce"; fi
  return 0
}

# ── intake_slot — la ADMISIÓN de una estación al slot, resuelta POR la cadena.
#
# POR QUÉ EXISTE: `titular_vigente` resolvía la cadena correctamente y con siete casos ejecutables
# encima… y NADIE la llamaba. Ni la receta de ref 02 §8 ni el gate APPLY-RUN la consultaban: el
# gate resolvía su titular con un `awk` propio. Un resolvedor que no gobierna ninguna admisión no
# gobierna nada — la cadena quedaba acreditada como función y ausente como CONTROL.
#
# Por eso esta función NO reimplementa la regla: la INVOCA. Dos copias de una misma regla divergen
# —ya ocurrió en la ronda 25— y el invariante de implementación EJECUTABLE ÚNICA existe justo para
# impedirlo. Aquí se traduce «quién es la titular» (cadena) a «puede ésta operar» (admisión), que
# son preguntas distintas y es la segunda la que faltaba.
#
# Entrada: $1 = ruta al flock · $2 = estación que pide operar · $3 = slot OBLIGATORIO y NUMÉRICO
#          (1-6 dígitos; sin modo sin filtro, CLASE 2 v23 B-01).
# Salida:  rc 0 ADMITIDA · rc 1 RECHAZADA · rc 3 LLAMADA MAL FORMADA. No imprime a stdout: es un
#          gate, no un informe (rc 3 sí avisa por stderr).
#
# SIN CADENA (flock sin `SLOT-CLAIM`, o ilegible) → RECHAZADA, y se dice por qué se eligió:
# `titular_vigente` documenta que su salida vacía significa «sin cadena» y que DECIDE EL LLAMADOR.
# Como llamador, esta función decide FAIL-CLOSED: sin cadena no hay slot que operar, y admitir por
# ausencia de reserva es exactamente la carrera que el APPLY-RUN cierra. Quien necesite el caso
# «libre → adelante» tiene que abrir su `SLOT-CLAIM` primero, que es el acto que crea la cadena.
#
# NUNCA SE INVOCA DESNUDA BAJO EL `set -e` DEL LLAMADOR (ronda 33, clase del inventario `set -e`).
# Esta función CONTESTA con el rc —`rc 1` = «cede»—, y una función que devuelve != 0 llamada como
# COMANDO SUELTO mata al shell bajo `errexit`: el «cede» que la doctrina promete NO se ejecuta
# nunca. Y no es un borde: es el caso NORMAL —la estación que pregunta cuando la titular es otra—.
# Medido, en las dos direcciones y sobre un flock REAL con cadena:
#     set -euo pipefail; intake_slot "$f" M3 101; rc=$?          -> el shell MUERE, `rc=$?` no corre
#     set -euo pipefail; rc=0; intake_slot "$f" M3 101 || rc=$?  -> rc=1, la estación cede
# EL ARREGLO NO PUEDE VIVIR DENTRO DE ESTA FUNCIÓN: es semántica de Bash, no un defecto suyo —una
# función que siempre devolviera 0 rompería el contrato `rc 0|1` que el arnés fija—. Vive en la
# FORMA DE LA LLAMADA, y por eso la prescribe ref 01 §2 junto a la regla que la usa.
# Y POR QUÉ NO LO VIO EL ARNÉS: lo mide con `errexit` APAGADO, así que su verde acredita la
# función y NO la forma de invocarla. El contexto del llamador es parte del sujeto.
intake_slot() {  # $1 = ruta al flock · $2 = estación · $3 = slot — OBLIGATORIO Y NUMÉRICO (CLASE 2 v23 B-01)
  # CLASE 2 v22 (ronda 36, BLOQUEANTE — dos pasadas independientes convergentes sobre v21): CLASE 4
  # de ronda 35 ya había dejado escrita esta misma advertencia como COMENTARIO — y un comentario no
  # distingue un arnés de un consumidor real ni impide que una llamada de producción de dos
  # argumentos vuelva a decidir sobre el flock ENTERO. Medido sobre un flock con el histórico M1/
  # slot100 + M2/slot101: `intake_slot(f, M1)` sin slot admitía (rc 0 — FALSA ADMISIÓN si el
  # objetivo real es 101) y `intake_slot(f, M2)` sin slot rechazaba (rc 1 — falso rechazo); con el
  # slot explícito, las dos decisiones se invierten correctamente. CONTAR ARGUMENTOS NO ES FILTRAR
  # (CLASE 2 v23 B-01, pasada 1 sobre v22): la guarda de v22 exigía `$#=3` pero ACEPTABA el slot
  # VACÍO, y con `""` el recorrido volvía a ser SIN FILTRO —`intake_slot(f, EST, "")` caminaba el
  # flock entero igual que la vieja llamada de dos—. El «modo sin filtro declarando `""`» era una
  # ESCAPATORIA que el LLAMADOR controla; se RETIRA entera. El slot es OBLIGATORIO y NUMÉRICO (mismo
  # `TM_RE_SLOT` que la escritura), y ni arnés ni consumidor se distinguen por bandera alguna. `$#`
  # distinto de 3 (slot OMITIDO) o slot vacío/sólo-espacios/no-numérico → rc 3 «LLAMADA MAL
  # FORMADA», valor que ningún `if rc -eq 0 … else CEDE …` confunde con 0 ADMITIDA / 1 RECHAZADA.
  local LC_ALL=C   # B-01: C para el `[[ =~ $TM_RE_SLOT ]]` de la guarda (bracket ASCII, no colación del locale); intake_slot no lanza subproceso propio, `local` a secas basta
  [ "$#" -eq 3 ] || { echo "intake_slot: se requieren 3 argumentos (flock, estación, slot NUMÉRICO) — el slot es obligatorio, nunca lo omitas (CLASE 2 v23)" >&2; return 3; }
  [[ "$3" =~ $TM_RE_SLOT ]] || { echo "intake_slot: slot vacío/no-numérico ('$3') — el slot es un entero de 1-6 dígitos y es OBLIGATORIO; no existe modo «sin filtro» (CLASE 2 v23 B-01)" >&2; return 3; }
  local f="$1" est="$2" slot="$3" titular _tv=0
  # `|| _tv=$?` y NO `_tv=$?` en línea aparte: el `rc 2` (ILEGIBLE) de `titular_vigente` mataría
  # esta función bajo el `set -e` del llamador ANTES de poder contestar RECHAZADA — la misma
  # regresión que la ronda 31 cazó en `publish_close`, en la función de al lado.
  #
  # $slot SE PROPAGA (CLASE 2, ronda 34): sin él, `titular_vigente` resolvía la cadena del flock
  # ENTERO — el caller de `ref 01` §2 punto 3 CONOCE su `$SLOT` y no lo pasaba, así que decidía
  # la admisión con la cadena de OTRO slot. `intake_slot` no reimplementa el filtro: lo REENVÍA.
  titular="$(titular_vigente "$f" "$slot")" || _tv=$?
  # ILEGIBLE (rc 2) y SIN CADENA (rc 0 + vacío) se responden IGUAL —RECHAZADA— porque este gate es
  # fail-closed y ceder es el lado SEGURO; pero se LEEN distinto, no se colapsan en bloque. La
  # asimetría con `publish_close` —que ahí el silencio es el lado caro y aquí el barato— es
  # deliberada: no publicar atasca la flota, ceder solo cuesta un turno.
  [ "$_tv" -eq 0 ] || return 1
  [ -n "$titular" ] || return 1
  # La titular llega como "<estación> <nonce>": se compara el PRIMER campo, no la línea entera —
  # una subcadena («M1» contra «M10») admitiría a quien no es, y el nonce no es de quien pregunta.
  if [ "${titular%% *}" = "$est" ]; then return 0; fi
  return 1
}

classify_log() {  # $1 = ruta a CLASS_FILE — NUNCA $LOG (ronda 20, BLOQUEANTE)
  local class_file="$1" content
  content="$(cat "$class_file" 2>/dev/null || true)"
  case "$content" in
    TRANSITORIO) echo TRANSITORIO ;;
    *) echo ESCALAR ;;   # vacío, corrupto, ausente (SIGKILL antes de clasificar) → fail-closed
  esac
}

# ── flock_acreditado — PROCEDENCIA del flock, no solo su contenido (ronda 32, MAYOR).
#
# EL HALLAZGO, en una frase: **la guarda se portaba bien con el flock QUE LE DABAN, y nadie
# preguntaba quien lo elige**. `FLOCK_FILE` llega del llamador y decide una EXCLUSION MUTUA — eso
# no es un parametro, es una CREDENCIAL. La probe del auditor publico sobre una ruta local
# arbitraria presentada como espejo: la exclusion se evade eligiendo otro fichero, sin tocar
# ninguna de las guardas que si funcionaban.
#
# Por que la primera pasada dio cero y la segunda no: sus cuatro fixtures (dueno/otro/vacio/
# ausente) corrian sobre LA MISMA RUTA. Eso acredita que la guarda distingue TITULARES; no
# acredita que la ruta sea la canonica. **Un ambito estrecho da un CERO FALSO.**
#
# Se compara por FICHERO (`-ef`: mismo dispositivo e inodo), NO por cadena: dos rutas distintas
# pueden nombrar el mismo fichero (symlink, `..`, montaje) y dos cadenas parecidas pueden nombrar
# ficheros distintos. Comparar texto seria medir un proxy del recurso, no el recurso.
#
# SIN `TM_FLOCK_CANONICO_TRUSTED` DECLARADO -> RECHAZA. No hay defecto que valga: si nadie declaro cual es
# el flock canonico, no existe procedencia que acreditar, y admitir «lo que me pasen» es
# exactamente el agujero. Fail-closed de verdad, no fail-closed en el texto. La declaracion vive en
# el anexo por repo (overlay), que es donde el skill pone lo que depende de la instancia.
#
# LIMITE DECLARADO, no disimulado (M-01, ronda 34, MAYOR — CR sobre v19): esta funcion prueba
# ALGO solo si `FLOCK_FILE` y `TM_FLOCK_CANONICO_TRUSTED` pueden discrepar. Si el MISMO acto de
# configuracion mueve las DOS variables juntas hacia el mismo fichero equivocado, `-ef` compara
# el sujeto consigo mismo y da exito — una comprobacion cuya referencia se mueve CON el sujeto
# no comprueba nada. Esta funcion NO PUEDE verificar eso en tiempo de ejecucion: es una propiedad
# del DESPLIEGUE (de donde sale cada variable), no del codigo. El sufijo `_TRUSTED` en el nombre
# es deliberado: marca que su procedencia debe ser de OTRA capa que la que fija `FLOCK_FILE`, para
# que un refactor futuro no la derive sin querer copiando un patron de nombres parecidos. Doctrina
# completa y el porque en el anexo por repo, tabla «Flock canonico».
#
# CLASE 3 (ronda 35, dos pasadas independientes): el renombrado de arriba NO crea un canal de
# confianza — es una convencion de nombre, no una garantia de procedencia. El anexo por repo
# corrigio el titulo de esta doctrina (afirmaba logro donde solo habia intencion) y declara la
# independencia real de origen NO MEDIDA, no cerrada: ningun script de este skill puede verificarla
# ni convertirla en medida, porque vive en la capa de aprovisionamiento/despliegue de la flota.
flock_acreditado() {   # rc 0 = la ruta recibida ES el flock canonico
  [ -n "${TM_FLOCK_CANONICO_TRUSTED:-}" ] || return 1
  [ -n "${FLOCK_FILE:-}" ]        || return 1
  [ "$FLOCK_FILE" -ef "$TM_FLOCK_CANONICO_TRUSTED" ]
}
publish_close() {  # $1 = rc de proc-m13.sh
  local rc="$1" tok extra="" n line run_line
  if [ "$rc" = "0" ]; then tok="APPLY-DONE"
  else tok="APPLY-FAILED"; extra=" $(classify_log "$CLASS_FILE")"; fi
  # línea COMPLETA calculada UNA vez — el retry reintenta EXACTAMENTE este literal, no
  # recalcula tok/extra en cada vuelta (ronda 25, BLOQUEANTE — ver por qué abajo). El
  # `$RUN_NONCE` (único por intento, fijado en Adquisición paso 0) va DENTRO de la línea
  # (ronda 27, BLOQUEANTE): así el cierre de dos generaciones distintas del MISMO #PR con
  # el MISMO $RUN_ISO son líneas DISTINTAS, y el `grep -qxF` de abajo solo deduplica un
  # reintento REAL de la MISMA generación (mismo nonce), nunca traga el cierre de otra.
  line="# $tok [$ESTACION] #$PR $RUN_ISO $RUN_NONCE$extra"
  # LA PROCEDENCIA SE ACREDITA ANTES QUE NADA: si la ruta no es la canonica, no hay turno que
  # cerrar ahi y publicar seria escribir en un fichero que no gobierna nada — o peor, hacer creer
  # que se cerro. Va DELANTE del resto de guardas porque las de abajo razonan sobre el CONTENIDO
  # del flock, y el contenido de un fichero equivocado no es evidencia de nada.
  if ! flock_acreditado; then
    _msg="✗ publish_close: FLOCK_FILE (${FLOCK_FILE:-<vacio>}) NO acredita ser el flock canonico (${TM_FLOCK_CANONICO_TRUSTED:-<sin declarar>}) — NO publico: un cierre sobre un fichero que no gobierna la exclusion no cierra nada y hace creer que si. ESCALAR AL CEO/ORQUESTADOR YA"
    echo "$_msg" >> "${LOG:-/dev/null}" 2>/dev/null || true
    echo "$_msg" >&2
    return 3
  fi
  # EL GATE SOLO LO LIBERA QUIEN LO TOMO (ronda 28, CRITICAL — hallazgo de revision externa).
  # Un cierre acredita DUENO (`[<estacion>]`) y GENERACION (`<nonce>`); publicarlo sin acreditar
  # ninguno de los dos es como se libera —o se atasca— el gate AJENO. Aqui se comprueba lo unico
  # que el productor puede probar POR SI SOLO, y en la unica direccion que es segura: si MI
  # `APPLY-RUN` no esta en el flock, yo no abri este turno y NO publico cierre alguno.
  # LIMITE DECLARADO, no disimulado: la presencia de mi RUN **no** prueba titularidad —puedo ser
  # un perdedor VOID—, y eso lo decide el gate-check del lector correlacionando la identidad
  # COMPLETA (ref 01 §2, parser de ref 02 §8). Por eso la guarda es de AUSENCIA: la ausencia SI
  # prueba «no soy el dueno» —**pero SOLO si la lectura tuvo exito**, precision anyadida en la ronda
  # 30: un flock ilegible no produce una ausencia, produce un NO SABER, y se trata aparte abajo—,
  # y asi ningun turno legitimo puede quedarse sin cerrar por su culpa
  # —que es el fallo caro: un cierre que no se publica atasca la flota hasta el timeout—.
  # HALLAZGO [3] DE REVISION — CERRADO POR CITA, no por cambio (ronda 29). El revisor pidio cerrar
  # exactamente el hueco que las cinco lineas de arriba YA declaran: que la presencia del RUN no
  # prueba titularidad. No se cierra el LIMITE, se cierra el HALLAZGO — el limite estaba declarado,
  # no disimulado, y quien lo resuelve es el gate-check del lector.
  # COSTE de cerrarlo de verdad, para que la decision sea revisable y no un encogimiento de hombros:
  # obligaria a `publish_close` a correlacionar el flock ENTERO bajo lock, es decir a meter el
  # trabajo del parser en el camino que tiene que ser RAPIDO **porque es el que desatasca la flota**.
  # Un cierre que tarda es un cierre que no llega, y un cierre que no llega atasca a todos hasta el
  # timeout: se pagaria disponibilidad de la cola entera por una comprobacion que el lector ya hace.
  # Es ALCANCE, no bug — y si algun dia se toma, va con su propia medida de latencia, no de oficio.
  # El dato viaja por ARGV, igual que en el append: la guarda no reintroduce lo que cierra [7].
  run_line="# APPLY-RUN [$ESTACION] #$PR $RUN_ISO $RUN_NONCE"
  # EL `rc` SE LEE, NO SE NIEGA EN BLOQUE (ronda 30, MAYOR — hallazgo de revision externa). Un
  # `if !` colapsaba TRES desenlaces distintos en uno: `rc 1` = la linea NO esta (lo que se quiere
  # decir), `rc 2` = `grep` NO PUDO LEER el flock, y el fallo del propio `flock`. El comentario de
  # arriba afirma que «la ausencia SI prueba que no soy el dueno» — **y eso solo es cierto si la
  # lectura tuvo exito**. Con el fichero ilegible, una estacion que SI era la duena leia su propio
  # silencio como una medida, no publicaba su cierre, y el gate se quedaba TOMADO.
  # `rc 1` y `rc 2` no son lo mismo: **VOID no es NEGATIVO**. Se distinguen y se responden distinto.
  # `|| _rc=$?` Y NO `_rc=$?` EN LINEA APARTE (ronda 31, CRITICAL — regresion del arreglo de la
  # ronda 30). Este fichero NO pone `set -e`: **lo pone su LLAMADOR**, la receta de ref 02 §8
  # (`set -euo pipefail`). Ahi un `flock` DESNUDO que devuelve != 0 **mata el shell en esa misma
  # linea**: `_rc=$?` no llega a ejecutarse, toda la clasificacion rc1/rc2/rc66 queda como CODIGO
  # MUERTO justo en los casos para los que existe, y —lo caro— **el aviso de escalada NO se emite:
  # el gate se queda TOMADO EN SILENCIO**. Medido:
  #     bash -c 'false; _rc=$?; echo llegue'          -> imprime «llegue»
  #     bash -c 'set -e; false; _rc=$?; echo llegue'  -> NO imprime nada
  # El `||` convierte la orden en una lista, que es la forma que `errexit` NO mata, y `$?` dentro
  # de la rama derecha sigue siendo el de la izquierda.
  # LA LECCION, que es de contexto y no de linea: **una correccion cuya validez depende de un `set`
  # puesto doscientas lineas mas lejos no esta acreditada por leerla a solas.** El contexto es parte
  # del sujeto — la misma clase que el `pipefail` lejano de PR-B.
  _rc=0
  flock "$FLOCK_FILE" bash -c 'grep -qxF -- "$1" "$2"' _ "$run_line" "$FLOCK_FILE" || _rc=$?
  if [ "$_rc" -ge 2 ]; then
    # NO MEDIBLE: no se sabe si el turno es mio. Fail-closed hacia el lado RUIDOSO — no publicar en
    # silencio, porque el fallo caro aqui es un cierre que no llega y atasca la flota hasta el
    # timeout. Se devuelve un rc PROPIO (2) para que el llamador NO lo confunda con «no es mi turno».
    _msg="✗ publish_close: NO SE PUDO LEER $FLOCK_FILE (rc $_rc) — no se si este turno es mio, asi que NO publico a ciegas NI trato el silencio como prueba. El gate puede quedar TOMADO: ESCALAR AL CEO/ORQUESTADOR YA"
    echo "$_msg" >> "${LOG:-/dev/null}" 2>/dev/null || true
    echo "$_msg" >&2
    return 2
  fi
  if [ "$_rc" -ne 0 ]; then
    _msg="✗ publish_close: NO publico cierre — mi APPLY-RUN ($run_line) no esta en $FLOCK_FILE: este turno no es mio. Un cierre sin dueno acreditado corrompe el gate de otra estacion. ESCALAR AL CEO/ORQUESTADOR YA"
    # `${LOG:-/dev/null}`: bajo `set -u` un `$LOG` sin definir abortaria AQUI y se perderia el
    # aviso por stderr, que es el unico canal que sobrevive si el log esta roto (misma leccion
    # de la ronda 24, aplicada al caso «invocacion sin wrapper»).
    echo "$_msg" >> "${LOG:-/dev/null}" 2>/dev/null || true
    echo "$_msg" >&2
    return 1
  fi
  for n in 1 2 3 4 5; do
    # check-then-append ATÓMICO bajo el MISMO flock (idempotente frente a resultado
    # AMBIGUO — ronda 25, BLOQUEANTE — hallazgo de revisión externa): si el intento
    # anterior en realidad SÍ escribió la línea pero `flock`/el subshell fue señalado
    # o devolvió ≠0 DESPUÉS de que el `printf` ya fuera visible (TOCTOU real, no solo
    # teórico — un SIGTERM/OOM puede matar el proceso `flock -c ...` tras el `write()`
    # pero antes de que su código de salida llegue al `&&` de la línea de arriba), el
    # reintento NO debe volver a apendizar: reapendizar produciría un segundo `DONE`/
    # `FAILED` con el MISMO run_id (MISMO nonce), publicado DESPUÉS de que otra estación ya
    # viera el primero como "último cierre" y arrancara su propio `APPLY-RUN` — el gate-check
    # de arriba (paso 1: "último cierre válido") leería ese duplicado tardío como el cierre
    # más reciente del flock ENTERO y declararía libre un gate con un RUN ajeno todavía
    # activo, aunque ese RUN sea posterior en el log al duplicado. El `<nonce>` en la línea
    # es lo que hace este `grep -qxF` CORRECTO y no destructivo (ronda 27): deduplica SOLO
    # cuando la generación es la misma (mismo nonce) — el cierre de OTRA generación (otro
    # nonce) del mismo #PR es una línea distinta y SÍ se apendiza. `grep -qxF` (match de
    # línea COMPLETA, sin interpretar regex) contra el propio `$FLOCK_FILE` bajo el MISMO
    # `flock` que protege el `printf` hace el chequeo y el append una sola operación
    # atómica — ningún otro publicador puede intercalarse entre el grep y el printf.
    # EL DATO NO PUEDE VOLVER A SER CODIGO (ronda 28, BLOQUEANTE — hallazgo de revision
    # externa). La forma anterior era `flock … -c "… \"$line\" …"`: el shell EXTERIOR
    # interpolaba `$line` DENTRO de la cadena que el shell INTERIOR vuelve a evaluar, asi que
    # un `$( )`, un backtick o unas comillas en CUALQUIER campo de la identidad —estacion, PR,
    # sello, nonce, categoria— se ejecutaban con el flock YA TOMADO y con el turno abierto.
    # Aqui `-c` recibe un programa FIJO entre comillas simples (sin una sola expansion) y los
    # datos viajan por ARGV: `$1` es la linea y `$2` el fichero. Sanear los campos no es
    # equivalente: el saneado ENUMERA lo que prohibe y siempre deja fuera algo; pasar por argv
    # RETIRA LA CAPACIDAD de ejecutar, que es lo unico que cierra la clase.
    # `rc 2` DEL `grep` NO ES `rc 1` (ronda 33, REAL — el MISMO fichero ya distingue esto 47 líneas
    # más arriba, y aquí no lo hacía). Antes, `grep -qxF … || printf … >> …`: si `grep` fallaba con
    # `rc>=2` (E/S, señal, OOM) —«NO PUDE VERIFICAR» si la línea ya estaba— el `||` disparaba el
    # `printf` iguales que si `grep` hubiera dicho «no está». Con el fichero aún escribible el
    # `printf` prosperaba, el compuesto devolvía 0 y el `&& return 0` de abajo publicaba «cerrado» —
    # convirtiendo un NO SABER en un ÉXITO. El daño exige las DOS cosas a la vez (si el fallo es de
    # permisos, `printf` también falla, el compuesto da `rc 1` y el bucle escala: ahí no hay daño).
    # Ahora `grep` se lee ANTES de decidir: `rc 0` (ya publicada) es éxito sin reescribir —el `<nonce>`
    # ya dedup a la generación—; `rc>=2` sale por `exit 2` SIN TOCAR el fichero, tratado abajo con la
    # MISMA vara de VOID-no-es-NEGATIVO; solo `rc 1` real dispara el `printf`.
    _rc2=0
    flock "$FLOCK_FILE" bash -c '
      grep -qxF -- "$1" "$2"; g=$?
      [ "$g" -eq 0 ] && exit 0
      [ "$g" -ge 2 ] && exit 2
      printf "%s\n" "$1" >> "$2"
    ' _ "$line" "$FLOCK_FILE" || _rc2=$?
    [ "$_rc2" -eq 0 ] && return 0
    sleep "$n"
  done
  # Los 5 reintentos fallaron (IO del flock roto, no contención — flock ya serializa
  # la contención normal): rc de PROC-M13 SE CONOCE pero no se pudo publicar. Escalar
  # YA, no esperar el timeout de ~30 min pensado para estación MUERTA (ref 01 §2 más
  # abajo) — aquí la estación sigue viva y el dato existe, solo el canal de publicación
  # falló. publish_close() corre DESPUÉS de que la tubería `bash proc-m13.sh | tee
  # "$LOG"` ya cerró (ronda 23, MAYOR — hallazgo de revisión externa: el stderr de esta función NUNCA
  # pasó por ese tee, contra lo que decía la nota anterior) — por eso se escribe
  # DIRECTO a `$LOG` con `>>` aparte de stderr, no se asume capturado por nada previo.
  # `|| true` es OBLIGATORIO en la línea del log (ronda 24, MAYOR — hallazgo de revisión
  # externa, reproducido ejecutando el bloque real con LOG=/dev/full): el wrapper ya
  # reactivó `set -e` antes de llamar a `publish_close` (paso 4 de la secuencia arriba),
  # así que un `$LOG` sin espacio/permiso/desmontado hace que ESA línea aborte la función
  # entera bajo `errexit` — el `2>/dev/null` solo silencia el MENSAJE de error, nunca el
  # código de salida que dispara `set -e` — y el aviso por stderr de la línea siguiente,
  # el único canal que sobrevive si `$LOG` está roto, NUNCA llegaría a ejecutarse.
  _msg="✗ publish_close: 5 intentos de escritura al flock fallaron — RUN #$PR $RUN_ISO $RUN_NONCE ($tok$extra) queda SIN CIERRE, ESCALAR AL CEO/ORQUESTADOR YA (no esperar el timeout de 30 min)"
  echo "$_msg" >> "${LOG:-/dev/null}" 2>/dev/null || true   # canal durable — best-effort; el || true evita que un fallo aquí mate el aviso de abajo bajo set -e. El `:-/dev/null` es el MISMO default que 52 líneas más arriba: `LOG` se define DENTRO del bloque de reserva de ref 02 §8.0, así que en un camino que no reserva NO existe, y bajo `set -u` esta línea moriría — en el aviso de que el flock falló, que es justo cuando no puede fallar nada más
  echo "$_msg" >&2                             # canal inmediato — visible en la terminal del operador YA, sobrevive aunque $LOG esté roto
  return 1
}
