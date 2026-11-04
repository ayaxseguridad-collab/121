#!/usr/bin/env bash
# proc-m13.selftest.sh — verificación empírica del bloque ejecutable canónico de PROC-M13
# (§4 de anexo-<proyecto>.md). TAL-2031 round-8 code-gate: el auditor no pudo confirmar
# los asserts porque el harness no estaba en el artefacto — este archivo LO ES.
#
# QUÉ HACE. Extrae el bloque `bash` de PROC-M13 del `.md` HERMANO (no una copia), lo corre
# contra un `curl`/`git` MOCKEADOS y un gate de Vault stub, y verifica el comportamiento
# fail-closed de la secuencia de apply: orden del gap, no-phantom en EOF, no-reaplicar
# históricas, y validación de forma de TODAS las respuestas HTTP (ledger, POST, advisors).
# NO toca red ni prod. Correr: `bash proc-m13.selftest.sh` (exit 0 = todo verde).
#
# Cubre los hallazgos de code-gate: round-6/7 (orden/gap/bucle), round-7 MAYOR 2 (ledger
# sin validar), round-8 MAYOR 1 (POST fail-open), round-8 MAYOR 2 (advisors `.lints[]?`).
set -uo pipefail
export TF_PAQUETE_ESTADO=distribucion
# La copia congelada solo se crea tras adjudicar una instancia supabase. El hijo
# vuelve a leer su identidad congelada; nunca cae al SKIP de distribución.
[ -z "${TM_SELFTEST_CONGELADO:-}" ] || export TF_PAQUETE_ESTADO=instancia
if [ $# -gt 0 ]; then
  [ $# -eq 2 ] && [ "$1" = --estado ] || exit 2
  export TF_PAQUETE_ESTADO="$2"
fi

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ANEXO="$HERE/anexo-*.md"
case "$TF_PAQUETE_ESTADO" in
  distribucion) : ;;
  instancia)
    # shellcheck source=/dev/null
    . "$HERE/../../skill-creator/scripts/lib-package.sh"
    pkg_parse_identity_conf "$HERE/../../talent-channel-operation/scripts/repo-identity.conf" || exit 2
    case "$PKGID_TCO_REPO_STACK" in
      supabase) : ;;
      ninguno|convex) echo "SKIP: PROC-M13 no aplica al stack $PKGID_TCO_REPO_STACK — 0 asserts ejecutados"; exit 0 ;;
      *) echo "FAIL: TCO_REPO_STACK fuera del enum supabase|convex|ninguno ($PKGID_TCO_REPO_STACK)"; exit 2 ;;
    esac
    case "$PKGID_TCO_ANEXO_FILE" in references/anexo-*.md) : ;; *) exit 2 ;; esac
    ANEXO="$HERE/../$PKGID_TCO_ANEXO_FILE" ;;
  *) echo "FAIL: estado inválido ($TF_PAQUETE_ESTADO)"; exit 2 ;;
esac
REF01="$HERE/01-rol-y-fronteras.md"
if [ ! -f "$ANEXO" ]; then
  # El anexo es un OVERLAY por repo: la DISTRIBUCIÓN (sin identidad de casa: no hay repo-identity.conf del
  # coordinador) no lo trae y no hay nada que medir — se declara SKIP-OVERLAY, jamás un verde silencioso.
  # La suite fija distribución; --estado instancia exige el anexo adjudicado.
  # Una instancia sin él sigue siendo error (exit 2), nunca un SKIP.
  case "${TF_PAQUETE_ESTADO:-instancia}" in
    distribucion)
      echo "SKIP-OVERLAY: distribución (TF_PAQUETE_ESTADO=distribucion) sin anexo por repo (anexo-<proyecto>.md) — 0 asserts ejecutados; esta suite corre en la instancia" >&2
      exit 0 ;;
    instancia) : ;;
    *) echo "✗ TF_PAQUETE_ESTADO inválido (${TF_PAQUETE_ESTADO}): distribucion|instancia" >&2; exit 2 ;;
  esac
  echo "✗ no encuentro anexo-<proyecto>.md junto a este script" >&2; exit 2
fi
[ -f "$REF01" ] || { echo "✗ no encuentro 01-rol-y-fronteras.md junto a este script" >&2; exit 2; }

# Los casos sin anexo o sin Supabase declaran su omisión antes de necesitar dobles.
# Una instancia instalada recibe del arnés el mismo contrato del paquete; el hijo
# sigue usando exclusivamente su copia congelada.
if [ -n "${TM_SELFTEST_CONGELADO:-}" ]; then
  # shellcheck source=/dev/null
  . "$TM_SELFTEST_CONGELADO/gh-fixtures/gh-dobles.sh" || exit 2
else
  # shellcheck source=/dev/null
  . "$(dirname "${GH_CONTRATO:-$HERE/../../../tests/fixtures/instalacion/gh_contrato.py}")/gh-dobles.sh" || exit 2
fi

# — PROCEDENCIA DE LA MEDIDA. Un resultado que no dice QUÉ midió no es atribuible: dos corridas
#   sobre contenidos DISTINTOS se leen como una misma corrida «intermitente». Eso pasó de verdad
#   en este encargo (`188 PASS / 1 FAIL` y `190/3` inexplicados durante días): las entradas
#   estaban a medio editar y nadie había registrado su estado, así que la pregunta «¿fue el mismo
#   fichero?» ya no tenía respuesta. La huella cubre el script MÁS todo lo que consume (los `.md`
#   del skill y `apply-gate.sh`), con rutas RELATIVAS para que no dependa de cómo se invoque.
#   Es INFORMATIVA: no decide nada ni cuenta como control — pero sin ella un veredicto no está
#   anclado a un contenido, y una divergencia futura se resuelve comparando huellas, no conjeturas.
# — CONGELAR LA ENTRADA, no fotografiarla dos veces (par10-p1, MAYOR). Comparar la huella al
#   principio y al final solo detecta que los EXTREMOS difieren: un cambio A→B→A pasa entero. El
#   auditor lo reprodujo —calcular A, cambiar el anexo a B, extraer B, restaurar A— y el script
#   mutado corrio 57 veces con la suite verde. Dos fotos de un arbol mutable no acreditan
#   procedencia; congelarlo hace que el objeto no pueda moverse.
#
#   Y EL EJECUTOR VA DENTRO DEL CONGELADO (par11-p1, MAYOR). Congelar los DATOS y seguir
#   ejecutando el fichero VIVO dejaba fuera la entrada mas importante: este mismo script — el
#   auditor muto el harness vivo despues del `cp -a` y su codigo corrio, con la suite en 202/0 y
#   una huella que ya no correspondia a lo ejecutado. Asi que el arranque es un BOOTSTRAP de DOS
#   PROCESOS: el PADRE congela y lanza al HIJO desde la copia; el hijo mide y emite el resultado.
#   NO se usa `exec` (par13-p1): con `exec` el hijo heredaba la responsabilidad de borrar un
#   directorio que le llegaba por variable de entorno, y un invocador podia convertir eso en un
#   borrado recursivo de una ruta ajena. Quien crea el directorio es quien lo borra.
if [ -z "${TM_SELFTEST_CONGELADO:-}" ]; then
  # NO hay mas variables internas que `TM_SELFTEST_CONGELADO`. Antes habia dos mas —el origen
  # declarado y un interruptor anti-recursion— y se rechazaban aqui; pero ese rechazo solo corria
  # en la rama PADRE, asi que un invocador que definiera las TRES entraba directo en la rama hija
  # y se saltaba la comprobacion, dando 205/0 con un control que no habia corrido (par15-p1,
  # MAYOR). Rechazar mas fuerte no era la solucion: la solucion es que esas variables NO EXISTAN.
  # El origen ya no se declara (no se puede verificar) y el anidamiento YA NO SE DETECTA: el
  # unico control que dependia de esa deteccion se corre siempre, porque su recursion esta
  # acotada por construccion (ver la nota junto al «marcador de congelado AJENO»). Este
  # comentario afirmaba «se detecta por la FORMA de la ruta» cuando el codigo ya contaba
  # ancestros, y despues ninguna de las dos cosas: la descripcion se alinea con lo ejecutado.
  SKILL_SRC="$(cd -- "$HERE/.." && pwd)"
  # El trap va ANTES del `mktemp` y cubre tambien las senales capturables (par14-p1, MAYOR): con
  # solo `EXIT`, una senal dirigida al PID del padre podia dejar al hijo huerfano usando una copia
  # que el padre acababa de borrar, o dejar la copia sin dueno. Hoy el padre **no mata a nadie**
  # (decision sellada, ver `_fin_padre`): espera acotado, observa, reporta y solo borra `$WORK` si
  # ha ACREDITADO que ya no queda nadie usandolo. `$WORK` vacio hace inocuo el disparo temprano.
  # `SIGKILL` y la
  # perdida del host no los cubre ningun trap de espacio de usuario: eso se declara, no se finge.
  WORK=""; HIJO=""; HIJO_ST=""
  # POSESION DEL GRUPO DE PROCESOS, no del PID inmediato (par15-p1, MAYOR). Enviar TERM solo al
  # shell hijo y hacer `wait` sin limite no acredita «cero procesos»: si el hijo espera a un
  # descendiente que ignora TERM, el padre se queda bloqueado en `wait`; y si el shell muere, el
  # descendiente queda huerfano. Medir una senal en un instante favorable no demuestra el ciclo.
  # `set -m` da al hijo su PROPIO grupo, y ese grupo es lo que se OBSERVA. El cierre es ACOTADO
  # —espera con tope y `wait` que nunca se cuelga— pero **no senaliza**: ver la decision sellada
  # en `_fin_padre`. Detecta, reporta con sujeto y escala; no mata.
  # Cuenta los procesos que quedan en el grupo del hijo. Mira el GRUPO, no el PID: el hijo puede
  # haber muerto y dejar descendientes vivos, que es justo la fuga que esto persigue.
  # `ps` puede FALLAR y `awk` imprimiria 0 igualmente: el cierre aceptaba «grupo vacio» sin haber
  # podido observarlo — fail-open en la comprobacion que sostiene la garantia (par16-p1, MAYOR).
  # Se separa «no pude mirar» (rc=2) de «hay cero»: un error de observacion NO es un cero.
  # IDENTIDAD, no numero. Un PID se recicla, y senalizar un numero que ya no es el nuestro es como
  # se mata al proceso del vecino en un host compartido (par16-p1, BLOQUEANTE + ruling del lead).
  # La identidad de un proceso es el par (PID, starttime): el campo 22 de `/proc/PID/stat` se fija
  # al arrancar y no se repite al reciclarse el numero. Se captura al lanzar y sirve para
  # ATRIBUIR y REPORTAR con precision: este cierre ya no envia ninguna senal, asi que la identidad
  # no autoriza nada — delimita de quien se habla cuando se escala.
  _starttime() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }
  _sigue_siendo_mio() {
    local ahora; ahora="$(_starttime "$1")" || return 1
    [ -n "$ahora" ] && [ "$ahora" = "$2" ]
  }
  # SUPERVIVIENTES POR GRUPO **UNION** ASCENDENCIA, con cota de identidad por starttime.
  # La version anterior recorria SOLO la cadena de padres, y eso se pierde en el caso que mas
  # importa (par17-p1, MAYOR): si el lider muere tras el TERM y un descendiente lo IGNORA, el
  # kernel reparenta al superviviente a init, la cadena hasta la raiz desaparece y la funcion
  # devolvia 0 — el instrumento declaraba «cero» justo cuando quedaba un huerfano. Medido: con
  # raiz 100 y descendiente 200->100 daba 2; con la raiz muerta y 200->1 daba 0.
  # El PGID SI sobrevive a la muerte del lider, asi que la pertenencia al grupo es el criterio
  # que aguanta el caso; la ascendencia se conserva ADEMAS porque cubre a quien conserva el padre
  # pero cambio de grupo. Se cuenta la UNION, nunca una sola de las dos.
  # Cota de identidad: un superviviente NO puede haber empezado antes que el propio grupo, asi
  # que se descarta todo lo que tenga `starttime` anterior a `$2`. Y la DUDA cuenta como
  # «quedan», nunca como cero: rc=2 = no pude mirar; `/proc/<pid>` presente pero ilegible = QUEDA;
  # `/proc/<pid>` ausente = el proceso se fue de verdad, eso no es duda.
  # `_sujetos` es la ENUMERACION, y `_supervivientes` solo la cuenta. Una orden destructiva
  # necesita SUJETO, no un conteo agregado (par18-p1, BLOQUEANTE): un numero autoriza a matar
  # «algo» sin decir a QUIEN, y esa es la ley de la casa despues de que un build «duplicado»
  # resultara ser el trabajo de otra estacion. Cada linea es `pid:starttime`; el `:?` marca al
  # que EXISTE pero no pude leer — cuenta como QUEDA y NUNCA se le senala, porque la duda
  # obliga a conservar, no autoriza a destruir.
  _sujetos() {
    local raiz="$1" raiz_st="${2:-}" salida cand p st
    salida="$(ps -eo pid= -o ppid= -o pgid= 2>/dev/null)" || return 2
    [ -n "$salida" ] || return 2
    cand="$(printf '%s\n' "$salida" | awk -v r="$raiz" '
      { pd[$1]=$2; pg[$1]=$3; ord[NR]=$1; m=NR }
      END { for (i=1;i<=m;i++) { p=ord[i]
              if (pg[p]==r) { print p; continue }
              q=p; d=0
              while (q>1 && d<64) { if (q==r) { print p; break } q=pd[q]; d++ }
            } }')" || return 2
    for p in $cand; do
      [ -e "/proc/$p" ] || continue
      st="$(_starttime "$p")"
      if [ -z "$st" ]; then printf '%s:?\n' "$p"; continue; fi
      if [ -z "$raiz_st" ] || [ "$st" -ge "$raiz_st" ]; then printf '%s:%s\n' "$p" "$st"; fi
    done
    return 0
  }
  _supervivientes() {
    local _s
    _s="$(_sujetos "$@")" || return 2
    printf '%s' "$(printf '%s' "$_s" | grep -c . || true)"
    return 0
  }
  # LA UNICA PUERTA AL BORRADO. Devuelve 0 solo con evidencia POSITIVA de que no queda nadie:
  # si nunca hubo hijo no hay nada que pueda estar usando el congelado; si lo hubo, se observa
  # su grupo AHORA —no se confia en que `HIJO` este vacio, ni en un flag calculado antes— y
  # cualquier duda (observacion fallida o sujetos presentes) CONSERVA.
  # ⚠ DEUDA DECLARADA (par22-p1, MAYOR 1 — sale por TECHO DE RONDA, no por no haberse visto;
  #   dueno: issue de continuacion abierta por el coordinador tras par22). ESTA PUERTA TIENE UN
  #   FAIL-OPEN CONOCIDO Y MEDIDO: interpreta `_PG_HIJO` vacio como «nunca hubo hijo», pero el
  #   hijo se lanza ANTES de publicar esa variable; una senal en esa ventana deja `_PG_HIJO`
  #   vacio aunque `jobs -p` SI recupere `HIJO`, y entonces la puerta concluye por la razon
  #   equivocada y autoriza el borrado. Es la misma familia que arrastra este encargo: **«no he
  #   medido» leido como «no hay nada»**. Ademas la acreditacion es UN snapshot de `ps`: un
  #   descendiente creado despues del snapshot no aparece. Y ningun control permanente detecta
  #   que esta puerta deje de acreditar — vaciar su cuerpo a `return 0` deja el paquete en 967/0.
  #   **No confies en el comentario de abajo como garantia hasta que esa issue cierre.**
  _acreditado_vacio() {
    [ -z "${_PG_HIJO:-}" ] && return 0
    local _s
    _s="$(_sujetos "$_PG_HIJO" "${HIJO_ST:-}")" || return 1
    [ -z "$_s" ]
  }
  _YA_CERRE=0
  _fin_padre() {
    # UNA SOLA VEZ. Los traps de senal hacen `_fin_padre; exit N`, y ese `exit` DISPARA OTRA VEZ el
    # trap EXIT: con una sola TERM la funcion corria DOS veces (par16-p1, BLOQUEANTE). La segunda
    # entrada reutilizaba el mismo PID/PGID DESPUES del `wait`, y si el numero se ha reciclado eso
    # es mandar TERM/KILL a un proceso AJENO del mismo usuario en un host compartido. Tambien
    # repetia `rm -rf` sobre un nombre ya liberado.
    [ "$_YA_CERRE" -eq 1 ] && return 0
    _YA_CERRE=1
    trap - EXIT
    # Ventana de publicacion de identidad: entre el `&` y `HIJO=$!` una senal veia `HIJO` vacio,
    # limpiaba `$WORK` y dejaba al hijo fuera de la propiedad (par16-p1, MAYOR). `jobs -p` lo ve
    # aunque `$!` no se haya asignado todavia.
    [ -z "$HIJO" ] && HIJO="$(jobs -p 2>/dev/null | tail -1)"
    if [ -n "$HIJO" ]; then
      _pg="$HIJO"
      # …y la identidad tambien se publica AQUI si el trap gano la carrera al `HIJO_ST=` de la
      # linea siguiente al `&` (par17-p1, MAYOR): `jobs -p` recuperaba el PID pero `HIJO_ST`
      # seguia vacio y el `wait` final quedaba sin cota. Recuperarla tarde vale porque **no
      # autoriza nada**: aqui la identidad solo delimita de QUIEN se habla al observar y al
      # escalar. Este cierre no envia senales (par21-p1, MAYOR: quedaba este residuo diciendo
      # que la identidad «autoriza a senalizar»).
      [ -z "${HIJO_ST:-}" ] && HIJO_ST="$(_starttime "$HIJO")"
      if [ -z "${HIJO_ST:-}" ]; then
        # Sin identidad no se puede atribuir el arbol con la cota de `starttime`. Se declara, y
        # la duda cuenta como QUEDAN — nunca se sale en silencio dando el arbol por limpio.
        echo "✗ no pude establecer la identidad de $HIJO: no senalizo a ciegas y la duda" \
             "cuenta como QUEDAN, nunca como cero" >&2
      fi
      # ══ DECISION SELLADA (par19-p1, BLOQUEANTE): ESTE CIERRE NO MATA. DETECTA, REPORTA Y ESCALA.
      #
      # Tres rondas intentando cercar la ventana check/use con un snapshot mejor. No se cierra:
      # verificar `(PID,starttime)` y usar despues ese numero en un syscall SEPARADO deja
      # SIEMPRE el hueco —el lider puede salir entremedias y el identificador negativo se
      # resuelve contra el grupo que exista AL EJECUTAR `kill`—. Anadir otra comprobacion
      # MUEVE la ventana, no la elimina. Hacia falta una identidad que SOBREVIVA hasta la
      # accion (un cgroup propio que imponga el kernel, o un `pidfd` abierto al atribuir), y
      # ninguna de las dos esta disponible aqui: shell puro, sin delegacion de cgroups y sin
      # `pidfd_send_signal`. Asi que se elige la tercera opcion, que no es una rendicion:
      #
      #   **NO SE ENVIA NINGUNA SENAL.** Ni TERM, ni CONT, ni KILL, ni al grupo ni al sujeto.
      #
      # POR QUE, y esto es lo que hace legitima la eleccion: la asimetria del coste no es
      # opinable. Un superviviente cuesta UN RECURSO de nuestro propio codigo y queda REPORTADO
      # con su identidad para que alguien lo recoja. **Y hay que decirlo exacto**: lo ACOTADO son
      # las esperas del PADRE (5 s de gracia + 10 s de espera); el hijo NO tiene timeout global y
      # el `wait` de la rama normal es ilimitado, asi que el coste real es una **fuga REPORTADA
      # potencialmente NO ACOTADA** — cancelaciones repetidas pueden acumular mas de un proceso y
      # mas de un `$WORK`. El canal de escalada es **stderr, que no es durable**: si nadie lee esa
      # salida, el aviso se pierde aunque el proceso siga vivo (par20-p1, MAYOR).
      # Aun asi la eleccion se sostiene, porque la alternativa no es «acotar»: es matar.
      # Matar de mas cuesta EL TRABAJO DE OTRA ESTACION en un host compartido, es
      # irreversible y silencioso. Y no hay evidencia de que haga falta matar: el unico caso
      # que acreditaba el escalado a KILL era un hijo SINTETICO que ignoraba TERM; el hijo
      # real es esta misma suite, que no lo ignora. No se destruye por un caso que no existe.
      #
      # CONTRATO ACOTADO DEL RATCHET QUE PROTEGE ESTA DECISION (par21-p1, MAYOR).
      # ⚠ DEUDA DECLARADA (par22-p1, MAYOR 2 — sale por TECHO DE RONDA; dueno: issue de
      #   continuacion). **Esta redaccion SIGUE SOBRE-AFIRMANDO**: dice «invocaciones» y el
      #   patron no distingue invocaciones — solo distingue **lineas no comentadas** que casan
      #   ciertas grafias, asi que ademas **bloquea datos que no ejecutan `kill`** (p. ej. el
      #   propio patron escrito en `invariants.tsv`). La redaccion correcta describiria lo que
      #   el patron hace de verdad y declararia AMBOS limites: lo que no caza y lo que bloquea
      #   de mas. Se deja escrito aqui en vez de corregirse, por techo de ronda.
      # `INV-ME-215` pretende cubrir **invocaciones literales directas** de `kill` en lineas
      # EJECUTABLES —no en comentarios—. **Modelo de amenaza declarado: error e implementacion perezosa. NO
      # sabotaje.** Una indireccion como `_orden=kill; "$_orden" -s TERM ...` NO la reconoce, y
      # no la va a reconocer: subir el ERE contra un evasor deliberado es una carrera sin final.
      # Quien escribe eso para esquivar un ratchet no se equivoca — lo evade a proposito, y eso
      # es otra clase de problema. Doctrina de casa: **ningun mecanismo dentro del repo se
      # defiende de un autor que puede editar el mecanismo.** Acotar DECLARA el limite; bajar la
      # guardia lo esconde. Aqui queda declarado, no en la cabeza de nadie.
      #
      # Lo que SI se conserva de las tres rondas anteriores, porque nada de eso era el error:
      # la identidad `(PID,starttime)`, los sujetos con nombre, el `wait` ACOTADO y la duda
      # contando como QUEDAN. Ahora sirven para REPORTAR con precision en vez de para matar.
      _i=0
      while _n="$(_supervivientes "$_pg" "${HIJO_ST:-}")" && [ "${_n:-1}" -gt 0 ] && [ "$_i" -lt 20 ]; do
        sleep 0.25; _i=$((_i+1))
      done
      # `wait` ACOTADO (par17-p1, MAYOR): sin cota, este cierre se quedaba bloqueado contra un
      # hijo vivo, que es justo el colgado que existe para evitar. Solo se espera a quien ya
      # no esta; a quien sigue vivo se le DECLARA.
      _w=0
      while kill -0 "$HIJO" 2>/dev/null && [ "$_w" -lt 40 ]; do sleep 0.25; _w=$((_w+1)); done
      if kill -0 "$HIJO" 2>/dev/null; then
        echo "✗ $HIJO sigue vivo tras el cierre: no espero indefinidamente, lo declaro" >&2
      else
        wait "$HIJO" 2>/dev/null || true
      fi
      HIJO=""
      # ESCALADA CON SUJETO, no con un numero: quien tenga que recoger esto necesita saber a
      # QUIEN mirar. La cobertura es GRUPO **union** ASCENDENCIA con cota de identidad por
      # `starttime`; queda fuera quien pierde AMBAS cosas a la vez, y decirlo es mas util que
      # prometerlo (par16-p1 y par17-p1, MAYOR).
      _resto="$(_sujetos "$_pg" "${HIJO_ST:-}")"; _rc_resto=$?
      if [ "$_rc_resto" -ne 0 ]; then
        # LA DUDA CONSERVA (par20-p1, MAYOR). Esta rama escribia el diagnostico pero dejaba
        # `_HUBO_RESTO` a 0, asi que el borrado de mas abajo se ejecutaba **justo cuando no se
        # sabe si hay hijos vivos usando el congelado**: un fail-open dentro del propio
        # instrumento, y en contra del corolario que este cierre dice aplicar. No poder mirar
        # NO es haber comprobado que no queda nadie.
        _HUBO_RESTO=1
        echo "✗ no pude OBSERVAR el arbol de $_pg tras el cierre: la duda cuenta como QUEDAN," \
             "nunca como cero, y por eso tampoco borro el congelado" >&2
      elif [ -n "$_resto" ]; then
        echo "✗ ESCALO: quedan procesos del arbol de $_pg y este cierre NO los mata por" \
             "diseno. Sujetos (pid:starttime): $(printf '%s' "$_resto" | tr '\n' ' ')" >&2
        _HUBO_RESTO=1
      fi
    fi
    # Corolario de la decision de no matar: si quedan supervivientes, ESTAN USANDO `$WORK`.
    # Borrarlo bajo sus pies es la otra mitad del mismo error —destruir sin acreditar que ya
    # nadie depende de ello—, asi que se CONSERVA y se dice donde esta, para que quien recoja
    # los procesos recoja tambien el directorio.
    # ── UN SOLO CAMINO DE BORRADO, Y EXIGE ACREDITACION (par21-p1, MAYOR) ──────────────
    # El fallo anterior no fue una rama olvidada: fue arreglar la rama REPORTADA en vez del
    # MECANISMO. En la via normal el `wait` retorna, `HIJO` se vacia, el cierre se saltaba la
    # observacion entera y `_HUBO_RESTO` valia su default 0, asi que borraba igual — y que el
    # shell hijo haya terminado NO demuestra que no dejara un proceso en background, que es
    # exactamente para lo que existe la observacion por PGID. La garantia escrita («solo borra
    # si ha ACREDITADO») era FALSA en esa via.
    # Salida: no se enumeran las vias de salida —normal, error, trap, cancelacion—, se hace
    # IMPOSIBLE salir sin pasar por la acreditacion. `_acreditado_vacio` es la unica puerta.
    if [ -n "$WORK" ]; then
      if _acreditado_vacio; then
        rm -rf "$WORK"; WORK=""
      else
        echo "✗ ESCALO: NO borro $WORK — no he ACREDITADO que nadie lo este usando" >&2
      fi
    fi
    return 0
  }
  trap _fin_padre EXIT
  # Codigos de salida DISTINGUIBLES por senal (sugerencia de par15-p1): convertir las tres a 143
  # impedia atribuir una cancelacion. HUP=129, INT=130, TERM=143, por convencion 128+n.
  trap '_fin_padre; exit 129' HUP
  trap '_fin_padre; exit 130' INT
  trap '_fin_padre; exit 143' TERM
  WORK="$(mktemp -d)" || { echo "✗ no pude crear el directorio de trabajo" >&2; exit 2; }
  cp -a "$SKILL_SRC" "$WORK/skill" || { echo "✗ no pude congelar el skill bajo $WORK" >&2; exit 2; }
  mkdir -p "$WORK/gh-fixtures" || exit 2
  cp "$GH_CONTRATO" "$(dirname "$GH_CONTRATO")/gh-2.45.0.json" \
    "$(dirname "$GH_CONTRATO")/gh-dobles.sh" "$WORK/gh-fixtures/" || exit 2
  if [ "$TF_PAQUETE_ESTADO" = instancia ]; then
    # El hijo conserva estado, identidad y lector dentro del mismo congelado.
    mkdir -p "$WORK/skill-creator/scripts" "$WORK/talent-channel-operation/scripts" || exit 2
    cp -a "$HERE/../../skill-creator/scripts/lib-package.sh" "$WORK/skill-creator/scripts/" || exit 2
    cp -a "$HERE/../../talent-channel-operation/scripts/repo-identity.conf" "$WORK/talent-channel-operation/scripts/" || exit 2
    [ ! -L "$WORK/skill-creator/scripts/lib-package.sh" ] &&
      [ ! -L "$WORK/talent-channel-operation/scripts/repo-identity.conf" ] || exit 2
  fi
  # Enlaces simbolicos: `cp -a` los CONSERVA, `find -type f` NO los mete en la huella, y los
  # consumidores (`references/*.md`, `[ -f ]`, `awk "$f"`) SI los siguen. Resultado: contenido
  # VIVO y externo dentro de algo que se declara congelado, con la MISMA huella para resultados
  # distintos (par11-p1, MAYOR). No se materializan: se RECHAZAN.
  #
  # Se comprueba la COPIA, no el ORIGEN, y se valida el RC de `find`: un error de recorrido que no
  # produce ruta se leia como «cero enlaces» y volvia fail-open un contrato fail-closed
  # (par14-p1, MAYOR). La busqueda NO lleva tope: acreditar una ausencia con `-print -quit` es
  # acreditarla con un recorte de 1 (doctrina del conjunto recortado).
  _enlaces="$(find "$WORK/skill" -type l -print 2>/dev/null)" || {
    echo "✗ no pude inspeccionar enlaces en el congelado: sin esa garantia no se mide" >&2; exit 2; }
  if [ -n "$_enlaces" ]; then
    echo "✗ el congelado contiene enlaces simbolicos: referencian contenido externo y quedarian" \
         "fuera de la huella" >&2
    exit 2
  fi
  # `set -m` SOLO para el lanzamiento: el hijo estrena grupo de procesos, y ese PGID es lo que
  # permite ATRIBUIR su arbol entero al observarlo. No se usa para senalizar: este cierre no
  # senaliza (ver `_fin_padre`).
  set -m
  TM_SELFTEST_CONGELADO="$WORK" bash "$WORK/skill/references/proc-m13.selftest.sh" &
  HIJO=$!
  # `_PG_HIJO` NO se limpia nunca. `HIJO` si se vacia al terminar el `wait`, y de ahi salia el
  # fail-open de la via normal (par21-p1, MAYOR): con `HIJO` vacio el cierre omitia TODA la
  # observacion y borraba el congelado sin acreditar nada. El grupo se recuerda aparte.
  _PG_HIJO="$HIJO"
  HIJO_ST="$(_starttime "$HIJO")"   # identidad del hijo, fijada al arrancar
  set +m
  wait "$HIJO"; _rc_hijo=$?
  HIJO=""
  exit "$_rc_hijo"
fi
# —— A partir de aqui, HIJO: corre DESDE el congelado. No instala limpieza (no creo `$WORK`) y
#    no se fia del marcador: acredita que EL FICHERO QUE SE ESTA EJECUTANDO vive dentro del
#    congelado que le pasan. Con el marcador puesto a mano sobre el arbol vivo, esto aborta —
#    y aborta ANTES de correr un solo control, no en un control tardio.
WORK="$TM_SELFTEST_CONGELADO"
# El origen NO se hereda: un llamador podria declarar uno falso y el acta lo citaria
# como si fuera verificado. Lo unico que se puede afirmar es QUE se midio: el congelado.
SKILL_SRC="$WORK/skill (congelado; el origen no se declara porque no se puede verificar)"
SKILLROOT="$WORK/skill"
if [ "$HERE" != "$SKILLROOT/references" ] || [ ! -f "$SKILLROOT/references/proc-m13.selftest.sh" ]; then
  echo "✗ marcador de congelado presente, pero este script no se ejecuta desde dentro de" \
       "'$SKILLROOT'. No se toca nada: ni se mide ni se limpia." >&2
  exit 2
fi

# FAIL-CLOSED: la version anterior solo comprobaba que la huella NO estuviera vacia, y un
# `sha256sum` que omite una entrada y sale != 0 produce igual un hash no vacio — huella PARCIAL
# aceptada como buena (par9-p1, MAYOR). Con `pipefail`, manda el rc de la tuberia entera, y aqui
# se comprueba. Una huella que no se puede calcular NO se aproxima: se declara.
huella_de_entradas() {
  local out
  out="$(find "$SKILLROOT" -type f -print0 | LC_ALL=C sort -z | xargs -0r sha256sum \
    | sed "s| $SKILLROOT/| |" | sha256sum | cut -c1-16)" || return 1
  [ -n "${out//[[:space:]]/}" ] || return 1
  printf '%s' "$out"
}
HUELLA="$(huella_de_entradas)" \
  || { echo "✗ no pude calcular la huella de entradas: sin ella el resultado no es atribuible" >&2; exit 2; }
echo "HUELLA DE ENTRADAS: $HUELLA  (congelado de $SKILL_SRC — es lo que se ejecuta)"
SCRIPT="$WORK/proc-m13.sh"
CLASSIFIER="$WORK/wrapper-classifier.sh"

# 1) Extraer el bloque bash canónico (el que empieza con el shebang) del .md hermano.
awk '
  /^```bash$/ { inb=1; buf=""; first=1; next }
  inb && /^```$/ { if (isproc) { printf "%s", buf; exit } inb=0; next }
  inb {
    if (first) { if ($0 ~ /^#!\/usr\/bin\/env bash$/) isproc=1; first=0 }
    buf = buf $0 "\n"
  }
' "$ANEXO" > "$SCRIPT"
[ -s "$SCRIPT" ] || { echo "✗ no pude extraer el bloque bash de PROC-M13 del .md" >&2; exit 2; }
bash -n "$SCRIPT" || { echo "✗ el bloque extraído no pasa bash -n" >&2; exit 2; }

# Las rutas son datos del bloque adjudicado, igual que para su ejecución. No se
# ejecuta el bloque para descubrirlas ni se usa un valor histórico como fallback.
RUTAS="$(python3 - "$SCRIPT" <<'PY'
import re
import sys
from pathlib import Path

block = Path(sys.argv[1]).read_text()
migrations = re.findall(r'^ls ([^\s]+)/(?:\*\.sql) \|', block, re.M)
vault = re.findall(r'^SUPABASE_ACCESS_TOKEN="\$TOKEN" bash ([^\s]+) \|\| \{', block, re.M)
if len(migrations) != 1 or len(vault) != 1:
    sys.exit('No se pueden identificar las rutas únicas de migraciones y Vault en PROC-M13')
for path in migrations + vault:
    if not re.fullmatch(r'[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*', path) or any(
            part in ('.', '..') for part in path.split('/')):
        sys.exit('Ruta de fixture inválida en PROC-M13')
print(migrations[0] + '\t' + vault[0])
PY
)" || exit 2
IFS=$'\t' read -r MIGRACIONES_DIR VAULT_GATE <<< "$RUTAS"
export MOCK_MIGRACIONES_DIR="$MIGRACIONES_DIR"

# 1b) Extraer el bloque bash del CONSUMIDOR real (classify_log/publish_close) de ref01
# (ronda 21 MAYOR: T21 solo probaba el PRODUCTOR — PROC-M13 escribiendo CLASS_FILE — nunca
# invocaba el consumidor documentado; una reversión aislada de classify_log a leer $LOG
# pasaba en verde). Extrae el fence indentado (dentro de una lista numerada) que contiene
# la definición real de classify_log, no una copia mantenida a mano que puede divergir.
awk '
  /^[[:space:]]*```bash[[:space:]]*$/ { inb=1; buf=""; next }
  inb && /^[[:space:]]*```[[:space:]]*$/ { if (buf ~ /classify_log\(\)/) { printf "%s", buf; exit } inb=0; next }
  inb { buf = buf $0 "\n" }
' "$REF01" > "$CLASSIFIER"
[ -s "$CLASSIFIER" ] || { echo "✗ no pude extraer classify_log/publish_close de ref01" >&2; exit 2; }
bash -n "$CLASSIFIER" || { echo "✗ el bloque de classify_log/publish_close extraído no pasa bash -n" >&2; exit 2; }
grep -q 'classify_log()' "$CLASSIFIER" || { echo "✗ el extracto no define classify_log" >&2; exit 2; }
grep -q 'publish_close()' "$CLASSIFIER" || { echo "✗ el extracto no define publish_close" >&2; exit 2; }

# 2) Mocks en un PATH dedicado.
MOCKBIN="$WORK/bin"; mkdir -p "$MOCKBIN"

cat > "$MOCKBIN/curl" <<'CURL'
#!/usr/bin/env bash
# mock curl: emite `body\ncode` (formato -w $'\n%{http_code}'). Estado del ledger en
# $MOCK_STATE (una versión por línea); el apply lo actualiza. FORCE_* fuerza respuestas.
set -uo pipefail
url=""; data_src=""; prev=""
for a in "$@"; do
  case "$prev" in --data-binary) data_src="$a" ;; esac
  case "$a" in https://*) url="$a" ;; esac
  prev="$a"
done
emit() { printf '%s\n%s' "$1" "$2"; }
if [[ "$url" == *"/advisors/"* ]]; then
  abody="${FORCE_ADVISOR_BODY:-}"; [ -n "$abody" ] || abody='{"lints":[]}'
  emit "$abody" "${FORCE_ADVISOR_CODE:-200}"; exit 0
fi
if [ "$data_src" = "@-" ]; then payload="$(cat)"; elif [ -n "$data_src" ]; then payload="$(cat "${data_src#@}")"; else payload=""; fi
if grep -q -- 'order by version' <<<"$payload"; then
  if [ -n "${FORCE_LEDGER_BODY:-}" ]; then emit "$FORCE_LEDGER_BODY" "${FORCE_LEDGER_CODE:-200}"; exit 0; fi
  arr="$(if [ -s "$MOCK_STATE" ]; then jq -R . "$MOCK_STATE" | jq -s 'map({version:.})'; else echo '[]'; fi)"
  emit "$arr" "200"; exit 0
fi
if grep -q -- 'begin;' <<<"$payload"; then
  [ -n "${MOCK_DUMP_PAYLOAD:-}" ] && printf '%s' "$payload" >> "$MOCK_DUMP_PAYLOAD"
  ver="$(printf '%s' "$payload" | grep -oE "values\('[0-9]{14}'" | head -1 | grep -oE '[0-9]{14}')"
  [ -n "$ver" ] && echo "$ver" >> "$MOCK_STATE"
  if [ -n "${FORCE_APPLY_BODY:-}" ]; then emit "$FORCE_APPLY_BODY" "${FORCE_APPLY_CODE:-200}"; exit 0; fi
  emit '[]' "200"; exit 0
fi
emit '{"message":"payload inesperado"}' "400"
CURL

cat > "$MOCKBIN/git" <<'GIT'
#!/usr/bin/env bash
case "$1" in
  fetch) exit 0 ;;
  ls-tree) ls "$MOCK_MIGRACIONES_DIR"/*.sql 2>/dev/null ;;
  *) exit 0 ;;
esac
GIT
chmod +x "$MOCKBIN/curl" "$MOCKBIN/git"

# 3) Sandbox por caso + runner + asserts.
setup() {  # $1 = "TS_name ..." locales
  local box; box="$(mktemp -d "$WORK/setup.XXXXXX")"; mkdir -p "$box/$MIGRACIONES_DIR" "$(dirname "$box/$VAULT_GATE")"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$box/$VAULT_GATE"
  chmod +x "$box/$VAULT_GATE"
  local f
  for f in $1; do printf 'create table t_%s (id int);\n' "${f%%_*}" > "$box/$MIGRACIONES_DIR/${f}.sql"; done
  : > "$box/.ledger"
  echo "$box"
}
run() { local box="$1"; shift; ( cd "$box" && PATH="$MOCKBIN:$PATH" SUPABASE_ACCESS_TOKEN="sbp_fake" MOCK_STATE="$box/.ledger" "$@" bash "$SCRIPT" ) 2>&1; echo "EXIT=$?"; }
pass=0; fail=0; nomedido=0
ck() { local ok=1; if [ -z "$2" ]; then [ -z "$3" ] && ok=0; else grep -qF -- "$2" <<<"$3" && ok=0; fi
  if [ "$ok" -eq 0 ]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (esperaba '$2')"; echo "$3" | sed 's/^/      /'; fail=$((fail+1)); fi; }

echo "== T1: gap múltiple aplicado EN ORDEN, dentro del bucle =="
b="$(setup "20270101000000_a 20270105000000_b 20270712093000_c")"
o="$(run "$b")"
ck "aplica a,b,c en orden" "$(printf 'a)\n✓ aplicada 20270105000000 (b)\n✓ aplicada 20270712093000 (c)')" "$o"
ck "sin phantom empty-TS" "" "$(printf '%s' "$o" | grep 'aplicada  ' || true)"
ck "EXIT 0" "EXIT=0" "$o"

echo "== T2: históricas ya en ledger NO se reaplican =="
b="$(setup "20270101000000_a 20270105000000_b 20270712093000_c")"; printf '20270101000000\n20270105000000\n' > "$b/.ledger"
o="$(run "$b")"
ck "no reaplica a" "" "$(printf '%s' "$o" | grep 'aplicada 20270101000000' || true)"
ck "aplica solo c" "✓ aplicada 20270712093000 (c)" "$o"; ck "EXIT 0" "EXIT=0" "$o"

echo "== T3: ledger objeto @200 → ABORTA (round-7 MAYOR 2) =="
b="$(setup "20270101000000_a")"; o="$(run "$b" env FORCE_LEDGER_BODY='{"message":"Unauthorized"}' FORCE_LEDGER_CODE=200)"
ck "no-array aborta" "no es un array" "$o"; ck "no aplica" "" "$(printf '%s' "$o" | grep '✓ aplicada' || true)"; ck "EXIT!=0" "EXIT=1" "$o"

echo "== T4: ledger HTTP 401 → ABORTA =="
b="$(setup "20270101000000_a")"; o="$(run "$b" env FORCE_LEDGER_BODY='x' FORCE_LEDGER_CODE=401)"
ck "HTTP no-2xx aborta" "HTTP 401" "$o"; ck "EXIT!=0" "EXIT=1" "$o"

echo "== T5: POST objeto-error → ABORTA a mitad (round-8 MAYOR 1) =="
b="$(setup "20270101000000_a")"; o="$(run "$b" env FORCE_APPLY_BODY='{"error":"relation already exists"}')"
ck "tx no confirmada" "fuera de contrato" "$o"; ck "EXIT!=0" "EXIT=1" "$o"

echo "== T6: divergencia (prod con versión que main no conoce) → ABORTA =="
b="$(setup "20270101000000_a")"; printf '20270101000000\n20279999999999\n' > "$b/.ledger"; o="$(run "$b")"
ck "detecta divergencia" "DIVERGENCIA" "$o"; ck "versión exacta" "20279999999999" "$o"; ck "EXIT!=0" "EXIT=1" "$o"

echo "== T7: sin gap → no aplica, Paso 5 OK =="
b="$(setup "20270101000000_a")"; printf '20270101000000\n' > "$b/.ledger"; o="$(run "$b")"
ck "sin gap" "sin gap" "$o"; ck "sincronía OK" "sincronía main↔prod confirmada" "$o"; ck "EXIT 0" "EXIT=0" "$o"

echo "== T8: Paso 1 fail-closed (BEGIN/COMMIT top-level) → ABORTA =="
b="$(setup "20270101000000_x")"; printf 'BEGIN;\ncreate table x (id int);\nCOMMIT;\n' > "$b/$MIGRACIONES_DIR/20270101000000_x.sql"
o="$(run "$b")"; ck "detecta tx top-level" "control de transacción top-level" "$o"; ck "no aplica" "" "$(printf '%s' "$o" | grep '✓ aplicada' || true)"; ck "EXIT!=0" "EXIT=1" "$o"

echo "== T8b: Paso 1 lexer (TAL-3111) — FALSOS POSITIVOS del regex viejo que el lexer DEBE dejar aplicar =="
b="$(setup "20270201000001_x")"; printf -- '-- commit;\ncreate table x (id int);\n' > "$b/$MIGRACIONES_DIR/20270201000001_x.sql"
o="$(run "$b")"; ck "commit en comentario de línea aplica" "✓ aplicada 20270201000001" "$o"; ck "EXIT 0" "EXIT=0" "$o"

b="$(setup "20270201000002_x")"; printf '/* blah commit; blah */\ncreate table x (id int);\n' > "$b/$MIGRACIONES_DIR/20270201000002_x.sql"
o="$(run "$b")"; ck "commit en comentario de bloque aplica" "✓ aplicada 20270201000002" "$o"; ck "EXIT 0" "EXIT=0" "$o"

b="$(setup "20270201000003_x")"
printf 'create or replace function f_20270201000003() returns void as $$\nbegin\n  commit;\nend;\n$$ language plpgsql;\n' > "$b/$MIGRACIONES_DIR/20270201000003_x.sql"
o="$(run "$b")"; ck "begin/commit en cuerpo \$\$…\$\$ aplica" "✓ aplicada 20270201000003" "$o"; ck "EXIT 0" "EXIT=0" "$o"

b="$(setup "20270201000004_x")"; printf -- '-- abort;\ncreate table x (id int);\n' > "$b/$MIGRACIONES_DIR/20270201000004_x.sql"
o="$(run "$b")"; ck "abort en comentario de línea aplica" "✓ aplicada 20270201000004" "$o"; ck "EXIT 0" "EXIT=0" "$o"

# TAL-3111 NO-GO r1 (mayor): el tag dollar-quoted con dígito tras el primer carácter
# ($body1$) es gramática REAL de Postgres — el regex viejo [A-Za-z_]* lo rechazaba y el
# lexer caía a escanear el cuerpo de la función como top-level, abortando un apply
# legítimo. Confirma que $body1$...$body1$ se trata como delimitador de bloque.
b="$(setup "20270201000005_x")"
printf 'create or replace function f_20270201000005() returns void as $body1$\nbegin\n  commit;\nend;\n$body1$ language plpgsql;\n' > "$b/$MIGRACIONES_DIR/20270201000005_x.sql"
o="$(run "$b")"; ck "begin/commit en cuerpo \$body1\$…\$body1\$ aplica" "✓ aplicada 20270201000005" "$o"; ck "EXIT 0" "EXIT=0" "$o"

echo "== T8c: Paso 1 lexer (TAL-3111) — POSITIVOS REALES que el regex viejo dejaba pasar (DEBEN abortar) =="
b="$(setup "20270202000001_x")"; printf 'create table x (id int);\nEND;\n' > "$b/$MIGRACIONES_DIR/20270202000001_x.sql"
o="$(run "$b")"; ck "END; bare detecta tx top-level" "control de transacción top-level" "$o"; ck "EXIT!=0" "EXIT=1" "$o"; ck "  no aplica" "" "$(printf '%s' "$o" | grep '✓ aplicada' || true)"

b="$(setup "20270202000002_x")"; printf 'COMMIT AND CHAIN;\n' > "$b/$MIGRACIONES_DIR/20270202000002_x.sql"
o="$(run "$b")"; ck "COMMIT AND CHAIN; detecta tx top-level" "control de transacción top-level" "$o"; ck "EXIT!=0" "EXIT=1" "$o"; ck "  no aplica" "" "$(printf '%s' "$o" | grep '✓ aplicada' || true)"

b="$(setup "20270202000003_x")"; printf 'START TRANSACTION ISOLATION LEVEL SERIALIZABLE;\n' > "$b/$MIGRACIONES_DIR/20270202000003_x.sql"
o="$(run "$b")"; ck "START TRANSACTION ISOLATION LEVEL... detecta tx top-level" "control de transacción top-level" "$o"; ck "EXIT!=0" "EXIT=1" "$o"; ck "  no aplica" "" "$(printf '%s' "$o" | grep '✓ aplicada' || true)"

b="$(setup "20270202000004_x")"; printf 'commit work;\n' > "$b/$MIGRACIONES_DIR/20270202000004_x.sql"
o="$(run "$b")"; ck "commit work; detecta tx top-level" "control de transacción top-level" "$o"; ck "EXIT!=0" "EXIT=1" "$o"; ck "  no aplica" "" "$(printf '%s' "$o" | grep '✓ aplicada' || true)"

b="$(setup "20270202000005_x")"; printf 'ABORT;\n' > "$b/$MIGRACIONES_DIR/20270202000005_x.sql"
o="$(run "$b")"; ck "ABORT; (sinónimo ROLLBACK, NO-GO r1) detecta tx top-level" "control de transacción top-level" "$o"; ck "EXIT!=0" "EXIT=1" "$o"; ck "  no aplica" "" "$(printf '%s' "$o" | grep '✓ aplicada' || true)"

echo "== T8d: Paso 1 lexer (TAL-3111 CR round2) — escape-string E'…\\'…' con backslash-escape =="
# FALSO POSITIVO que el lexer viejo abortaba: un `commit;` DENTRO de un E-string tras un \'.
# El lexer viejo cerraba la cadena en el \' y leía `commit;` como control top-level.
b="$(setup "20270203000001_x")"
printf '%s\n' "insert into t(msg) values (E'done\'; commit;');" > "$b/$MIGRACIONES_DIR/20270203000001_x.sql"
o="$(run "$b")"; ck "commit dentro de E-string escapado aplica" "✓ aplicada 20270203000001" "$o"; ck "EXIT 0" "EXIT=0" "$o"

# El fix NO debe cegar la detección: un commit REAL top-level tras un E-string SÍ aborta.
b="$(setup "20270203000002_x")"
printf '%s\n' "insert into t(msg) values (E'x\'y');" "commit;" > "$b/$MIGRACIONES_DIR/20270203000002_x.sql"
o="$(run "$b")"; ck "commit top-level tras E-string detecta control" "control de transacción top-level" "$o"; ck "EXIT!=0" "EXIT=1" "$o"; ck "  no aplica" "" "$(printf '%s' "$o" | grep '✓ aplicada' || true)"

# String REGULAR (no E): con standard_conforming_strings=on el backslash es LITERAL, así que
# 'a\' cierra en la 2ª comilla y el commit; siguiente ES top-level → DEBE abortar (no tratar
# el backslash como escape, que ocultaría el commit = fail-open).
b="$(setup "20270203000003_x")"
printf '%s\n' "insert into t(msg) values ('a\');" "commit;" > "$b/$MIGRACIONES_DIR/20270203000003_x.sql"
o="$(run "$b")"; ck "backslash en string regular NO escapa (commit; top-level detecta)" "control de transacción top-level" "$o"; ck "EXIT!=0" "EXIT=1" "$o"; ck "  no aplica" "" "$(printf '%s' "$o" | grep '✓ aplicada' || true)"

echo "== T9-12: POST fail-open (round-8 MAYOR 1) — null/objeto/array-error/JSON-inválido → ABORTAN =="
for bodycase in 'null' '{"unexpected":true}' '[{"error":"tx failed"}]' 'no soy json'; do
  b="$(setup "20270101000000_a")"; o="$(run "$b" env FORCE_APPLY_BODY="$bodycase")"
  ck "rechaza [$bodycase]" "fuera de contrato" "$o"; ck "  EXIT!=0" "EXIT=1" "$o"
done

echo "== T9b: POST whitelist (round-9 MAYOR 1) — arrays fuera de [] / [{schedule:num}] → ABORTAN =="
for bc in '[{"unexpected":true}]' '[{"message":"tx failed"}]' '[null]' '["garbage"]' '[{"schedule":"x"}]'; do
  b="$(setup "20270101000000_a")"; o="$(run "$b" env FORCE_APPLY_BODY="$bc")"
  ck "rechaza $bc" "no confirma commit" "$o"; ck "  EXIT!=0 ($bc)" "EXIT=1" "$o"
  ck "  no aplica ($bc)" "" "$(printf '%s' "$o" | grep '✓ aplicada' || true)"
done

echo "== T9c: POST positivo [{schedule:5}] (cron.schedule) → aplica OK =="
b="$(setup "20270101000000_a")"; o="$(run "$b" env FORCE_APPLY_BODY='[{"schedule":5}]')"
ck "acepta schedule row" "✓ aplicada 20270101000000" "$o"; ck "EXIT 0" "EXIT=0" "$o"

echo "== T13-14: advisors fail-open (round-8 MAYOR 2) — {} / {message} → ABORTAN =="
for adv in '{}' '{"message":"upstream schema changed"}'; do
  b="$(setup "20270101000000_a")"; printf '20270101000000\n' > "$b/.ledger"
  o="$(run "$b" env FORCE_ADVISOR_BODY="$adv")"
  ck "rechaza advisors [$adv]" "fuera de contrato" "$o"; ck "  EXIT!=0" "EXIT=1" "$o"
done

echo "== T14b: advisors whitelist (round-9 MAYOR 2) — elementos sin contrato → ABORTAN =="
for adv in '{"lints":[{"severity":"ERROR"}]}' '{"lints":[{}]}' '{"lints":[null]}' '{"lints":[{"level":"FATAL"}]}'; do
  b="$(setup "20270101000000_a")"; printf '20270101000000\n' > "$b/.ledger"
  o="$(run "$b" env FORCE_ADVISOR_BODY="$adv")"
  ck "rechaza advisors $adv" "fuera del contrato de lints" "$o"; ck "  EXIT!=0 ($adv)" "EXIT=1" "$o"
done

echo "== T14c: advisors WARN/INFO válidos, 0 ERROR → pasa =="
b="$(setup "20270101000000_a")"; printf '20270101000000\n' > "$b/.ledger"
o="$(run "$b" env FORCE_ADVISOR_BODY='{"lints":[{"level":"WARN","name":"x"},{"level":"INFO","name":"y"}]}')"
ck "0 ERROR pasa" "PROC-M13 completo" "$o"; ck "EXIT 0" "EXIT=0" "$o"

echo "== T15: advisors con ERROR real → bloquea =="
b="$(setup "20270101000000_a")"; printf '20270101000000\n' > "$b/.ledger"
o="$(run "$b" env FORCE_ADVISOR_BODY='{"lints":[{"level":"ERROR","name":"rls_disabled"}]}')"
ck "cuenta ERROR real" "1 ERROR" "$o"; ck "bloquea" "bloquea" "$o"; ck "EXIT!=0" "EXIT=1" "$o"

echo "== T16: advisors HTTP 500 → ABORTA =="
b="$(setup "20270101000000_a")"; printf '20270101000000\n' > "$b/.ledger"
o="$(run "$b" env FORCE_ADVISOR_CODE=500)"; ck "HTTP no-200 aborta" "HTTP 500" "$o"; ck "EXIT!=0" "EXIT=1" "$o"

echo "== T17: TMPDIR con espacios → mktemp -d hereda el espacio; las rutas \"\$WORKDIR/…\" entre"
echo "        comillas deben aplicar el gap sin 'ambiguous redirect' (review PR #1240 finding #3) =="
b="$(setup "20270101000000_a 20270105000000_b")"
mkdir -p "$b/tmp dir con espacios"
o="$(run "$b" env "TMPDIR=$b/tmp dir con espacios")"
ck "aplica a con TMPDIR espaciado" "✓ aplicada 20270101000000 (a)" "$o"
ck "aplica b en orden" "✓ aplicada 20270105000000 (b)" "$o"
ck "sin ambiguous redirect" "" "$(printf '%s' "$o" | grep -i 'ambiguous redirect' || true)"
ck "EXIT 0" "EXIT=0" "$o"

echo "== T18: Paso 1 lexer roto (rc≠0,1) → FAIL-CLOSED aborta (TAL-3111 CR round2, fail-open del \`if\`) =="
# El \`if has_toplevel_txcontrol\` previo trataba CUALQUIER rc≠0 como «limpio» → un awk
# ausente/roto (rc=2) caía al else y APLICABA sin gate (fail-open). Stub de awk que sale 2.
b="$(setup "20270101000000_a")"
# Bajo `$WORK`, no en el TMPDIR global: el trap de arriba solo alcanza `$WORK`, asi que este
# `mktemp -d` suelto dejaba dos nodos por corrida (par9-p1, MAYOR). Una suite que mide fugas no
# puede fugar ella misma.
awkstub="$(mktemp -d "$WORK/awkstub.XXXXXX")"; printf '#!/usr/bin/env bash\nexit 2\n' > "$awkstub/awk"; chmod +x "$awkstub/awk"
o="$(run "$b" env "PATH=$awkstub:$MOCKBIN:$PATH")"
ck "lexer roto (rc=2) aborta fail-closed" "FAIL-CLOSED" "$o"
ck "no aplica con lexer roto" "" "$(printf '%s' "$o" | grep '✓ aplicada' || true)"
ck "EXIT!=0" "EXIT=1" "$o"

echo "== T19: Paso 1 lexer (TAL-3116) — EOF dentro de string/comentario/dollar sin cerrar → rc=2 FAIL-CLOSED =="
# Antes de TAL-3116 el END del lexer ignoraba el estado final y devolvía 1 («limpio») aunque
# la tokenización terminara dentro de una región sin cerrar — fail-open silencioso. Con el fix,
# EOF en cualquiera de los cuatro estados incompletos produce rc=2 → el Paso 1 aborta
# fail-closed (rama elif _tx_rc≠1). Ejercitamos los cuatro estados para cobertura completa.

# T19a: squote sin cerrar (E-string oculta un commit;) — estado más frecuente en práctica
b="$(setup "20270204000001_x")"
printf '%s\n' "insert into t(msg) values (E'oops; commit;" > "$b/$MIGRACIONES_DIR/20270204000001_x.sql"
o="$(run "$b")"
ck "T19a squote sin cerrar → FAIL-CLOSED" "FAIL-CLOSED" "$o"
ck "T19a no aplica" "" "$(printf '%s' "$o" | grep '✓ aplicada' || true)"
ck "T19a EXIT!=0" "EXIT=1" "$o"

# T19b: dquote sin cerrar (identificador sin cerrar oculta un rollback;)
b="$(setup "20270204000002_x")"
printf '%s\n' 'alter table "my_table_rollback; rollback;' > "$b/$MIGRACIONES_DIR/20270204000002_x.sql"
o="$(run "$b")"
ck "T19b dquote sin cerrar → FAIL-CLOSED" "FAIL-CLOSED" "$o"
ck "T19b no aplica" "" "$(printf '%s' "$o" | grep '✓ aplicada' || true)"
ck "T19b EXIT!=0" "EXIT=1" "$o"

# T19c: blockcomment sin cerrar (/* oculta un commit;)
b="$(setup "20270204000003_x")"
printf '%s\n' "/* comment that never closes; commit;" > "$b/$MIGRACIONES_DIR/20270204000003_x.sql"
o="$(run "$b")"
ck "T19c blockcomment sin cerrar → FAIL-CLOSED" "FAIL-CLOSED" "$o"
ck "T19c no aplica" "" "$(printf '%s' "$o" | grep '✓ aplicada' || true)"
ck "T19c EXIT!=0" "EXIT=1" "$o"

# T19d: dollar body sin cerrar ($$ sin closing tag oculta un commit;)
b="$(setup "20270204000004_x")"
printf '%s\n' "create function f() returns void as \$\$" "begin" "  commit;" > "$b/$MIGRACIONES_DIR/20270204000004_x.sql"
o="$(run "$b")"
ck "T19d dollar sin cerrar → FAIL-CLOSED" "FAIL-CLOSED" "$o"
ck "T19d no aplica" "" "$(printf '%s' "$o" | grep '✓ aplicada' || true)"
ck "T19d EXIT!=0" "EXIT=1" "$o"

# Paso 1 ignora cuerpos dollar-quoted; aquí interesa el código PL/pgSQL del DO.
# El payload es JSON: las posiciones y sentencias se miden tras decodificarlo.
payload_sql() {
  python3 - "$1" <<'PY'
import json
import re
import sys

TAG = re.compile(r'\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$')
WORD = re.compile(r'[A-Za-z_\u0080-\uffff][A-Za-z_0-9$\u0080-\uffff]*|[0-9]+')
QUOTED = {"'": re.compile(r"[^']+"), '"': re.compile(r'[^"]+')}
ESCAPED = re.compile(r"[^'\\]+")

def tokens(sql):
    result = []
    i = 0
    while i < len(sql):
        # Solo espacio SQL ASCII; un espacio Unicode puede ser un identificador.
        if sql[i] in ' \t\n\r\f':
            i += 1
            continue
        if sql.startswith('--', i):
            end = sql.find('\n', i)
            i = len(sql) if end < 0 else end + 1
            continue
        if sql.startswith('/*', i):
            depth = 1
            i += 2
            while depth:
                if i >= len(sql):
                    raise ValueError('comentario sin cerrar')
                if sql.startswith('/*', i):
                    depth += 1
                    i += 2
                elif sql.startswith('*/', i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            continue
        start = i
        escape = sql[i:i+2].lower() == "e'"
        if escape or sql[i] in "'\"":
            if escape:
                i += 1
            quote = sql[i]
            i += 1
            parts = []
            span = ESCAPED if escape else QUOTED[quote]
            while True:
                if i >= len(sql):
                    raise ValueError('cadena sin cerrar')
                if escape and sql[i] == '\\':
                    if i + 1 >= len(sql):
                        raise ValueError('escape sin cerrar')
                    escaped = sql[i+1]
                    # No confundir escapes numéricos/Unicode con sus caracteres:
                    # si no se interpreta su valor SQL, se rechaza todo el payload.
                    if escaped in '01234567xuU':
                        raise ValueError('escape SQL no reconocido')
                    parts.append({'b': '\b', 'f': '\f', 'n': '\n',
                                  'r': '\r', 't': '\t'}.get(escaped, escaped))
                    i += 2
                elif sql[i] == quote:
                    i += 1
                    if i < len(sql) and sql[i] == quote:
                        parts.append(quote)
                        i += 1
                    else:
                        break
                else:
                    chunk = span.match(sql, i)
                    parts.append(chunk[0])
                    i = chunk.end()
            value = ''.join(parts)
            result.append(('string' if quote == "'" else 'identifier', value, start))
            continue
        tag = TAG.match(sql, i)
        if tag:
            delimiter = tag[0]
            body = i + len(delimiter)
            end = sql.find(delimiter, body)
            if end < 0:
                raise ValueError('cuerpo sin cerrar')
            result.append(('body', sql[body:end], start))
            i = end + len(delimiter)
            continue
        word = WORD.match(sql, i)
        if word and sql[i] in '0123456789' and word.end() < len(sql):
            end = word.end()
            if WORD.match(sql, end) or sql[end] == '$':
                raise ValueError('frontera numérica SQL no reconocida')
        if not word and sql[i] not in '(),;.[]=:+-*/<>~!@#%^&|?':
            raise ValueError('símbolo SQL no reconocido')
        value = word[0] if word else sql[i]
        if word and value.isascii():
            value = value.lower()
        i = word.end() if word else i + 1
        result.append(('code', value, start))
    return result

def sequence(ts, values, start=0):
    expected = [('code', value) for value in values.split()]
    for i in range(start, len(ts) - len(expected) + 1):
        if ts[i][:2] != expected[0]:
            continue
        if [(kind, value) for kind, value, _ in ts[i:i+len(expected)]] == expected:
            yield i

def position(ts, values):
    # Solo comienzos de sentencia; los datos entrecomillados no son código.
    return next((ts[i][2] for i in sequence(ts, values)
                 if i == 0 or ts[i-1][:2] == ('code', ';')), -1)

try:
    with open(sys.argv[1]) as payload:
        sql = json.load(payload)['query']
    ts = tokens(sql)
    begin = position(ts, 'begin ;')
    lock = position(ts, 'lock table supabase_migrations . schema_migrations in exclusive mode ;')
    ddl = position(ts, 'create table t_20270101000000')
    guard = -1
    version = exception = 0
    first = None
    for i in sequence(ts, 'do'):
        if (i and ts[i-1][:2] != ('code', ';')) or i+2 >= len(ts):
            continue
        if ts[i+1][0] != 'body' or ts[i+2][:2] != ('code', ';'):
            continue
        inner = tokens(ts[i+1][1])
        # Exige el guard pertinente, no una mención dentro de otra sentencia.
        prefix = 'begin if exists ( select 1 from supabase_migrations . schema_migrations where version ='
        for j in sequence(inner, prefix):
            if j != 0:
                continue
            k = j + len(prefix.split())
            candidate = ts[i][2]
            current_version = current_exception = 0
            if (inner[k:k+1] and inner[k][:2] == ('string', '20270101000000')
                    and [t[:2] for t in inner[k+1:k+3]] == [('code', ')'), ('code', 'then')]):
                current_version = 1
                # Forma completa emitida por proc-m13-supabase.md.tmpl:
                # sin sentencias adicionales ni ramas; el último END no lleva ;.
                r = k + 3
                tail = [('code', value) for value in '; end if ; end'.split()]
                if (inner[r:r+2] and [t[:2] for t in inner[r:r+2]]
                        == [('code', 'raise'), ('code', 'exception')]
                        and r+2 < len(inner) and inner[r+2][0] in ('string', 'body')
                        and [t[:2] for t in inner[r+3:]] == tail
                        and re.fullmatch(r'.*version 20270101000000 ya aplicada(?:[ :].*)?',
                                         inner[r+2][1], re.S)):
                    current_exception = 1
            # Los tres datos siempre pertenecen a un único DO pertinente.
            found = (candidate, current_version, current_exception)
            if first is None:
                first = found
            if lock >= 0 and lock < candidate < ddl and current_version and current_exception:
                guard, version, exception = found
                break
        if guard >= 0:
            break
    if guard < 0 and first is not None:
        guard, version, exception = first
    print(begin, lock, ddl, guard, version, exception)
except (OSError, ValueError, KeyError, TypeError, IndexError):
    # Ningún fallo del analizador puede acreditar un assert.
    print('-1 -1 -1 -1 0 0')
PY
}

echo "== T20: Paso 3 payload incluye lock explícito sobre el ledger ANTES del DDL (ronda 20 BLOQUEANTE 1) =="
b="$(setup "20270101000000_a")"; dump="$b/.payload"
o="$(run "$b" env MOCK_DUMP_PAYLOAD="$dump")"
ck "aplica OK" "✓ aplicada 20270101000000 (a)" "$o"; ck "EXIT 0" "EXIT=0" "$o"
lockline='lock table supabase_migrations.schema_migrations in exclusive mode;'
read -r begin_pos lock_pos ddl_pos guard_pos where_ok raise_ok <<< "$(payload_sql "$dump")"
ck "el payload contiene el lock explícito" "$lockline" "$(if [ "$lock_pos" -ge 0 ]; then printf '%s' "$lockline"; fi)"
if [ "$begin_pos" -ge 0 ] && [ "$lock_pos" -ge 0 ] && [ "$ddl_pos" -ge 0 ] && [ "$begin_pos" -lt "$lock_pos" ] && [ "$lock_pos" -lt "$ddl_pos" ]; then
  echo "  ✓ orden begin < lock < DDL"; pass=$((pass+1))
else
  echo "  ✗ orden begin < lock < DDL (begin=$begin_pos lock=$lock_pos ddl=$ddl_pos)"; fail=$((fail+1))
fi

echo "== T21: PROC_M13_CLASS_FILE — clasificación estructurada por PROC-M13, nunca por grep del log (ronda 20 BLOQUEANTE 2) =="

echo "-- T21a: Paso 0 (token ausente) -> TRANSITORIO --"
b="$(setup "20270101000000_a")"; cf="$b/.class"
o="$(run "$b" env SUPABASE_ACCESS_TOKEN= PROC_M13_CLASS_FILE="$cf")"
ck "Paso 0 detecta token ausente" "SUPABASE_ACCESS_TOKEN ausente" "$o"
ck "  clase=TRANSITORIO" "TRANSITORIO" "$(cat "$cf" 2>/dev/null)"

echo "-- T21b: ledger no-array (T3) -> TRANSITORIO --"
b="$(setup "20270101000000_a")"; cf="$b/.class"
o="$(run "$b" env FORCE_LEDGER_BODY='{"message":"Unauthorized"}' FORCE_LEDGER_CODE=200 PROC_M13_CLASS_FILE="$cf")"
ck "  clase=TRANSITORIO" "TRANSITORIO" "$(cat "$cf" 2>/dev/null)"

echo "-- T21c: POST objeto-error (T5) -> ESCALAR --"
b="$(setup "20270101000000_a")"; cf="$b/.class"
o="$(run "$b" env FORCE_APPLY_BODY='{"error":"relation already exists"}' PROC_M13_CLASS_FILE="$cf")"
ck "  clase=ESCALAR" "ESCALAR" "$(cat "$cf" 2>/dev/null)"

echo "-- T21d: Paso 1 control top-level (T8) -> ESCALAR --"
b="$(setup "20270101000000_x")"; printf 'BEGIN;\ncreate table x (id int);\nCOMMIT;\n' > "$b/$MIGRACIONES_DIR/20270101000000_x.sql"
cf="$b/.class"
o="$(run "$b" env PROC_M13_CLASS_FILE="$cf")"
ck "  clase=ESCALAR" "ESCALAR" "$(cat "$cf" 2>/dev/null)"

echo "-- T21e: advisors HTTP 500 (T16) -> TRANSITORIO --"
b="$(setup "20270101000000_a")"; printf '20270101000000\n' > "$b/.ledger"; cf="$b/.class"
o="$(run "$b" env FORCE_ADVISOR_CODE=500 PROC_M13_CLASS_FILE="$cf")"
ck "  clase=TRANSITORIO" "TRANSITORIO" "$(cat "$cf" 2>/dev/null)"

echo "-- T21f: advisors con ERROR real (T15) -> ESCALAR (DEFECTO ya NO se auto-publica, ronda 19) --"
b="$(setup "20270101000000_a")"; printf '20270101000000\n' > "$b/.ledger"; cf="$b/.class"
o="$(run "$b" env FORCE_ADVISOR_BODY='{"lints":[{"level":"ERROR","name":"rls_disabled"}]}' PROC_M13_CLASS_FILE="$cf")"
ck "  clase=ESCALAR" "ESCALAR" "$(cat "$cf" 2>/dev/null)"

echo "-- T21g: advisors fuera de contrato (T13, '{}') -> TRANSITORIO (doc y wrapper ahora COINCIDEN, ronda 20 nota) --"
b="$(setup "20270101000000_a")"; printf '20270101000000\n' > "$b/.ledger"; cf="$b/.class"
o="$(run "$b" env FORCE_ADVISOR_BODY='{}' PROC_M13_CLASS_FILE="$cf")"
ck "  clase=TRANSITORIO" "TRANSITORIO" "$(cat "$cf" 2>/dev/null)"

echo "-- T21h (ADVERSARIAL — reproduce el hallazgo real del auditor ronda 20): Paso 4 HTTP con cuerpo"
echo "   FORJADO que contiene un prefijo TRANSITORIO ajeno ('✗ ledger: HTTP forged') -> DEBE seguir ESCALAR --"
b="$(setup "20270101000000_a")"; cf="$b/.class"
o="$(run "$b" env FORCE_APPLY_BODY='{"detail":"✗ ledger: HTTP forged"}' FORCE_APPLY_CODE=500 PROC_M13_CLASS_FILE="$cf")"
ck "  el log SIGUE conteniendo el cuerpo forjado (streaming normal, no se censura)" '✗ ledger: HTTP forged' "$o"
ck "  clase=ESCALAR pese al cuerpo forjado (la clase NO se deriva del log)" "ESCALAR" "$(cat "$cf" 2>/dev/null)"
if grep -q '^TRANSITORIO$' "$cf" 2>/dev/null; then
  echo "  ✗ REGRESIÓN: el cuerpo remoto forjó la clase (ronda 20 BLOQUEANTE 2 reabierto)"; fail=$((fail+1))
else
  echo "  ✓ el cuerpo remoto NO pudo forjar la clase"; pass=$((pass+1))
fi

echo "-- T21j (ronda 21 MAYOR — prueba el CONSUMIDOR real, no solo el productor): fuente"
echo "   classify_log/publish_close EXTRAÍDOS de ref01 (no una copia a mano) y ejecútalos"
echo "   extremo a extremo contra el MISMO log forjado -- una reversión aislada de"
echo "   classify_log a leer \$LOG debe hacer FALLAR este bloque --"
oc="$(
  set -u
  # shellcheck source=/dev/null
  . "$CLASSIFIER"
  wj="$(mktemp -d)"; trap 'rm -rf "$wj"' EXIT
  log_j="$wj/log"; class_j="$wj/class"; FLOCK_FILE="$wj/flock" TM_FLOCK_CANONICO_TRUSTED="$wj/flock"
  printf '%s\n' '✗ Paso 4 (x): HTTP 500 — {"detail":"✗ ledger: HTTP forged"}' > "$log_j"
  printf '%s' 'ESCALAR' > "$class_j"   # lo que PROC-M13 REAL escribe en este punto de salida
  CLASS_FILE="$class_j"; ESTACION=M3; PR=9999; RUN_ISO=2026-09-02T12:00:00Z; RUN_NONCE=T21J-NONCE
  # El flock arranca con MI `APPLY-RUN`, no vacio: desde la ronda 28 `publish_close` no publica
  # cierre alguno si su propio RUN no esta en el flock (el gate solo lo libera quien lo tomo).
  # Sembrarlo es ademas lo FIEL —un cierre real siempre sigue a su RUN—; con el `: > $FLOCK_FILE`
  # anterior este bloque mediria la guarda nueva en vez de la clasificacion, que es su razon de ser.
  printf '%s\n' "# APPLY-RUN [M3] #9999 2026-09-02T12:00:00Z T21J-NONCE" > "$FLOCK_FILE"
  printf 'consumer-classification=%s\n' "$(classify_log "$CLASS_FILE")"
  publish_close 1
  printf 'consumer-token=%s\n' "$(tail -n1 "$FLOCK_FILE")"
)"
ck "  classify_log() real da ESCALAR (leyendo CLASS_FILE, no el log forjado)" \
  "consumer-classification=ESCALAR" "$oc"
ck "  publish_close() real publica el token ESCALAR (no TRANSITORIO), con el <nonce> en la línea" \
  "consumer-token=# APPLY-FAILED [M3] #9999 2026-09-02T12:00:00Z T21J-NONCE ESCALAR" "$oc"
if grep -q -- 'consumer-classification=TRANSITORIO\|consumer-token=.*TRANSITORIO' <<<"$oc"; then
  echo "  ✗ REGRESIÓN: el consumidor real clasificó TRANSITORIO (ronda 20/21 reabierto)"; fail=$((fail+1))
else
  echo "  ✓ el consumidor real (fuente desde ref01) resiste el cuerpo forjado"; pass=$((pass+1))
fi

echo "-- T21k (ronda 27 BLOQUEANTE — el <nonce> hace la identidad ÚNICA por intento): dos APPLY-RUN"
echo "   del MISMO #PR con el MISMO RUN_ISO pero nonce DISTINTO NO se tragan el cierre entre sí; un"
echo "   retry REAL de la MISMA generación (mismo nonce) SÍ deduplica. Sin el <nonce> en la línea"
echo "   de publish_close, el 2º cierre lo tragaría el grep -qxF — la colisión reproducida en R26 --"
okk="$(
  set -u
  # shellcheck source=/dev/null
  . "$CLASSIFIER"
  wk="$(mktemp -d)"; trap 'rm -rf "$wk"' EXIT
  FLOCK_FILE="$wk/flock" TM_FLOCK_CANONICO_TRUSTED="$wk/flock"; LOG="$wk/log"; CLASS_FILE="$wk/class"
  printf '%s' 'TRANSITORIO' > "$CLASS_FILE"
  ESTACION=M1; PR=2178; RUN_ISO=2026-09-03T07:32:11Z
  # Generación A: APPLY-RUN + dos publish_close (el 2º es un retry REAL de la MISMA generación)
  RUN_NONCE=AAAA-1111
  printf '%s\n' "# APPLY-RUN [M1] #2178 2026-09-03T07:32:11Z AAAA-1111" > "$FLOCK_FILE"
  publish_close 1 >/dev/null 2>&1
  publish_close 1 >/dev/null 2>&1
  printf 'cierres_A=%s\n' "$(grep -Fc '# APPLY-FAILED [M1] #2178 2026-09-03T07:32:11Z AAAA-1111 TRANSITORIO' "$FLOCK_FILE")"
  # Generación B: MISMO #PR y MISMO RUN_ISO, nonce DISTINTO
  RUN_NONCE=BBBB-2222
  printf '%s\n' "# APPLY-RUN [M1] #2178 2026-09-03T07:32:11Z BBBB-2222" >> "$FLOCK_FILE"
  publish_close 1 >/dev/null 2>&1
  printf 'cierres_B_tras_2o_RUN=%s\n' "$(awk '/^# APPLY-RUN \[M1\] #2178 2026-09-03T07:32:11Z BBBB-2222$/{s=1;next} s&&/ BBBB-2222 TRANSITORIO$/{n++} END{print n+0}' "$FLOCK_FILE")"
)"
ck "  retry REAL de la MISMA generación (mismo nonce) deduplica: EXACTAMENTE 1 cierre para A" \
  "cierres_A=1" "$okk"
ck "  el <nonce> distingue generaciones: el cierre de B (mismo #PR+ISO, otro nonce) SÍ aparece tras su 2o RUN" \
  "cierres_B_tras_2o_RUN=1" "$okk"

echo "-- T21l (ronda 28 CRITICAL — DATO RE-EVALUADO COMO CODIGO): un \$line con \`;\` y \`\$( )\`"
echo "   dentro debe publicarse VERBATIM sin ejecutar nada. Con el \`flock … -c \"…\$line…\"\` anterior"
echo "   el shell INTERIOR reevaluaba la cadena y el \$( ) corria con el turno YA abierto --"
ol="$(
  set -u
  # shellcheck source=/dev/null
  . "$CLASSIFIER"
  wl="$(mktemp -d)"; trap 'rm -rf "$wl"' EXIT
  FLOCK_FILE="$wl/flock" TM_FLOCK_CANONICO_TRUSTED="$wl/flock"; LOG="$wl/log"; CLASS_FILE="$wl/class"
  printf '%s' 'TRANSITORIO' > "$CLASS_FILE"
  EVID="$wl/EJECUTADO"
  ESTACION=M1; PR=42; RUN_ISO=2026-09-08T18:00:00Z
  RUN_NONCE='A;$(touch '"$EVID"');B'   # las DOS formas a la vez: separador y sustitucion
  printf '%s\n' "# APPLY-RUN [$ESTACION] #$PR $RUN_ISO $RUN_NONCE" > "$FLOCK_FILE"
  publish_close 1 >/dev/null 2>&1
  if [ -e "$EVID" ]; then printf 'ejecutado=SI\n'; else printf 'ejecutado=NO\n'; fi
  printf 'verbatim=%s\n' "$(grep -cF -- "$RUN_NONCE TRANSITORIO" "$FLOCK_FILE")"
)"
ck "  el dato con \`;\` y \`\$( )\` NO se ejecuta" "ejecutado=NO" "$ol"
ck "  y la linea se publica VERBATIM: el dato se queda en dato" "verbatim=1" "$ol"

echo "-- T21m (ronda 28 CRITICAL — EL GATE SOLO LO LIBERA QUIEN LO TOMO): los DOS brazos. Sin"
echo "   ambos no hay discriminacion: publicar siempre y no publicar nunca pasan un solo brazo --"
om="$(
  set -u
  # shellcheck source=/dev/null
  . "$CLASSIFIER"
  wm="$(mktemp -d)"; trap 'rm -rf "$wm"' EXIT
  brazo() {  # $1 = etiqueta   $2 = contenido inicial del flock
    local d; d="$(mktemp -d "$wm/b.XXXX")" || return 1
    FLOCK_FILE="$d/flock" TM_FLOCK_CANONICO_TRUSTED="$d/flock"; LOG="$d/log"; CLASS_FILE="$d/class"
    printf '%s' 'TRANSITORIO' > "$CLASS_FILE"
    ESTACION=M1; PR=42; RUN_ISO=2026-09-08T18:00:00Z
    RUN_NONCE=00000000-0000-4000-8000-000000000007
    printf '%s' "$2" > "$FLOCK_FILE"
    local rc nc
    publish_close 1 >/dev/null 2>&1
    rc=$?
    nc="$(grep -c '^# APPLY-FAILED ' "$FLOCK_FILE" 2>/dev/null)"; nc="${nc:-0}"
    printf '%s=rc%s/%s\n' "$1" "$rc" "$nc"
  }
  brazo ajeno '# APPLY-RUN [M5] #77 2026-09-08T17:00:00Z 00000000-0000-4000-8000-000000000011
'
  brazo dueno '# APPLY-RUN [M1] #42 2026-09-08T18:00:00Z 00000000-0000-4000-8000-000000000007
'
)"
ck "  turno AJENO: NO publica cierre y lo dice (rc 1, cero cierres)" "ajeno=rc1/0" "$om"
ck "  turno PROPIO: el dueno legitimo SI publica su cierre (rc 0, uno)" "dueno=rc0/1" "$om"

echo "-- T21i: sin PROC_M13_CLASS_FILE (ejecución manual/sin wrapper) -> default /dev/null, no revienta --"
b="$(setup "20270101000000_a")"
o="$(run "$b" env FORCE_APPLY_BODY='{"error":"x"}')"
ck "  aborta igual (comportamiento normal)" "fuera de contrato" "$o"
ck "  EXIT!=0" "EXIT=1" "$o"
ck "  sin error de escritura al class file" "" "$(printf '%s' "$o" | grep -i 'no such file\|permission denied' || true)"

echo "== T22: Paso 3 payload incluye la revalidación DENTRO de la transacción, entre el lock y el DDL"
echo "   (ronda 21 BLOQUEANTE: cierra la carrera de un POST anterior aceptado-pero-aún-no-lockeado) =="
b="$(setup "20270101000000_a")"; dump="$b/.payload22"
o="$(run "$b" env MOCK_DUMP_PAYLOAD="$dump")"
ck "aplica OK" "✓ aplicada 20270101000000 (a)" "$o"; ck "EXIT 0" "EXIT=0" "$o"
read -r begin_pos lock_pos ddl_pos guard_pos where_ok raise_ok <<< "$(payload_sql "$dump")"
ck "el payload contiene el guard do \$\$ ... end \$\$" 'do $$' "$(if [ "$guard_pos" -ge 0 ]; then printf '%s' 'do $$'; fi)"
ck "el guard referencia el version exacto de este gap" '1' "$where_ok"
ck "el guard aborta con raise exception nombrando la version" '1' "$raise_ok"
if [ "$lock_pos" -ge 0 ] && [ "$guard_pos" -ge 0 ] && [ "$ddl_pos" -ge 0 ] && [ "$lock_pos" -lt "$guard_pos" ] && [ "$guard_pos" -lt "$ddl_pos" ]; then
  echo "  ✓ orden lock < guard < DDL"; pass=$((pass+1))
else
  echo "  ✗ orden lock < guard < DDL (lock=$lock_pos guard=$guard_pos ddl=$ddl_pos)"; fail=$((fail+1))
fi

echo "== T23: ninguna receta EJECUTABLE llega a 'gh pr merge' sin acotar el caso con migración"
echo "   ni exigir el gate APPLY-RUN (poda3-p2 MAYOR: el Quick Start y ref02 §8 iban de los"
echo "   gates AND directos al merge, reproduciendo la carrera que TAL-5170 cierra)."
echo "   El predicado mira COMANDOS EFECTIVOS, no cadenas: los comentarios se descartan antes"
echo "   de decidir (final-p1 M1: la receta solo MENCIONABA el gate y la guarda la aprobaba,"
echo "   contradiciendo su propio principio de que mencionar no es reclamar). Fences de"
echo "   CUALQUIER info-string, continuaciones de línea unidas, y el merge por API exige"
echo "   MÉTODO MUTANTE explícito — un GET de estado NO es un merge y no rompe nada (M3)."
echo "   Residuo VIVO declarado: 'curl', 'hub' o un script propio siguen evadiéndola (M2) =="
# SKILLROOT ya apunta al CONGELADO bajo `$WORK` (arriba). Reasignarlo aqui al arbol vivo era
# justo el hueco del ABA: el escaneo y la extraccion miraban un objeto que podia moverse.
scan_fences() {  # $1 = 'offenders' | 'covered'
  local f
  for f in "$SKILLROOT"/SKILL.md "$SKILLROOT"/references/*.md; do
    [ -f "$f" ] || continue
    awk -v F="$f" -v MODE="$1" '
      # Un comentario DE COLA no es un comando. El descarte de abajo solo tira la línea ENTERA
      # (`^#`), así que `… "$OTRA" >&9   # no es RUN_LINE` entraba completo en `eff` y el predicado
      # leía la cola como si fuera código: bastaba NOMBRAR el token en un comentario para acreditar
      # una receta que no lo publica. Se recorta la cola SOLO cuando el `#` cae FUERA de comillas —
      # un `#` dentro de una cadena es DATO, y recortar ahí mutilaría el comando.
      # La comilla simple se compara por su código (39): el programa viaja dentro de un literal
      # entrecomillado simple del shell, así que escribirla tal cual lo partiría en dos.
      function sin_comentario(s,   i, c, ins, ind, q) {
        q = sprintf("%c", 39); ins = 0; ind = 0
        for (i = 1; i <= length(s); i++) {
          c = substr(s, i, 1)
          if (c == "\"" && !ins) ind = !ind
          else if (c == q && !ind) ins = !ins
          else if (c == "#" && !ins && !ind && (i == 1 || substr(s, i-1, 1) ~ /[[:space:]]/))
            return substr(s, 1, i-1)
        }
        return s
      }
      # Abrir/cerrar con CUALQUIER info-string (```bash title="x" es Markdown válido, M2), y
      # solo abrir si NO estamos ya dentro: apertura y cierre comparten patrón.
      !inb && /^[[:space:]]*(```|~~~)/ { inb=1; raw=""; eff=""; cont=""; hd=""; start=NR; next }
      inb && /^[[:space:]]*(```|~~~)/ {
        # --- merge EFECTIVO: por comando, no por aparición del literal en cualquier sitio.
        mergea = 0
        n = split(eff, L, "\n")
        for (i = 1; i <= n; i++) {
          li = L[i]; sub(/^[[:space:]]+/, "", li)
          # Texto LITERAL pasado a un comando no es una ejecución… pero una SUSTITUCIÓN sí lo
          # es: `echo "$(gh pr merge …)"` MERGEA (par2-p1 M5). Así que la excepción de
          # echo/printf solo vale si la línea NO contiene `$(` ni comillas invertidas —
          # descartar por PREFIJO de línea era medir un proxy de "no ejecuta".
          if (li ~ /^(echo|printf)[[:space:]]/ && li !~ /\$\(/ && li !~ /`/) continue
          # `gh` admite flags globales entre medias, CON su valor: `gh --repo owner/repo pr
          # merge`. Ceñirse a tokens que empiecen por `-` dejaba escapar el valor del flag.
          if (li ~ /gh([[:space:]]+[^[:space:];|&]+)*[[:space:]]+pr[[:space:]]+merge/) mergea = 1
          # API: solo con MÉTODO MUTANTE explícito, en TODAS sus formas (`--method PUT`,
          # `--method=PUT`, `-X PUT`). `gh api ".../merge"` a secas es un GET que CONSULTA si
          # el PR se mergeó — contarlo rompía el gate con una consulta legítima (M3).
          if (li ~ /gh([[:space:]]+[^[:space:];|&]+)*[[:space:]]+api/ \
              && li ~ /(--method[[:space:]=]+|-X[[:space:]]+)(PUT|POST)/ \
              && li ~ /\/merge/) mergea = 1
        }
        if (mergea) {
          # --- ADQUISICIÓN EFECTIVA: tiene que haber un `flock` Y una escritura del token,
          # ambos como COMANDOS. Una mención dentro de un comentario ya no cuenta (M1).
          hay_flock = 0; escribe_run = 0
          for (i = 1; i <= n; i++) {
            # AMBOS términos se miden sobre la línea SIN su comentario de cola: la fuga era de
            # CLASE, no de un término — mencionar `flock` en un comentario acreditaba igual que
            # mencionar el token. Arreglar solo el que sale en el fixture habría dejado viva la
            # otra mitad de la misma fuga.
            ef = sin_comentario(L[i])
            if (ef ~ /flock/) hay_flock = 1
            # SE EXIGE LA ESCRITURA DEL DATO, no la coincidencia del literal con un emisor.
            # La versión anterior acreditaba cualquier línea que juntara `APPLY-RUN` con un
            # emisor o una redirección, y fallaba en LOS DOS SENTIDOS (sonda de M2, reproducida):
            #   (A) receta HONESTA — `printf … "$RUN_LINE" >&9` con `# APPLY-RUN` en OTRA línea
            #       (la asignación) -> reclama=0, RECHAZADA: exigía literal y emisor JUNTOS.
            #   (B) receta FALSA — `echo "APPLY-RUN: reclamando…" >&2`, que no escribe NADA al
            #       bus -> reclama=1, ACEPTADA. Éste es el decisivo.
            # Un predicado MÁS FUERTE que el anterior puede seguir sin ser el correcto: el
            # comentario de arriba cerró la mención-en-comentario y dejó abierto el diagnóstico.
            # Ancla en `RUN_LINE` —la variable que LLEVA el token publicado—, así que el literal y
            # la escritura pueden vivir en líneas distintas, que es como está escrita la receta
            # real. Y se excluye `>&2`: volcar el dato a la terminal no es publicarlo en el bus (la
            # receta real publica a `>&9`, el fd del flock).
            #
            # Y se exige la EXPANSIÓN, no la PALABRA (ronda 29, hallazgo del par): anclar en el
            # nombre desnudo acreditaba dos recetas que NO publican el dato —una que escribe OTRA
            # variable y solo nombra `RUN_LINE` en un comentario, y otra que escribe la CADENA
            # LITERAL "RUN_LINE"—. Lo que publica el token es `$RUN_LINE` o `${RUN_LINE}`; el
            # nombre a secas es texto. `[$]` y `[{]` en clase en vez de escapados: la misma
            # precaución que la ronda 25 pagó con `awk -v`, aplicada por defecto.
            # El borde derecho impide que `${RUN_LINE_OTRA}` cuele como si fuera ésta.
            if (ef ~ /[$][{]?RUN_LINE([^A-Za-z0-9_]|$)/ \
                && (ef ~ /printf|echo|tee/ || ef ~ />>|>&/) && ef !~ />&2/) escribe_run = 1
          }
          reclama = (hay_flock && escribe_run)
          # Una receta que SÍ cubre el caso con migración no se acredita leyéndola: se acredita
          # EJECUTÁNDOLA (T24). El marcador solo vale porque T24 comprueba que hay EXACTAMENTE
          # UNA receta marcada y que es la que él extrae y corre contra mocks — si alguien lo
          # copia a otra, T24 enrojece.
          verificada = (raw ~ /ADQUISICIÓN VERIFICADA POR EJECUCIÓN/)
          # El ACOTAMIENTO sí es una declaración, así que vale en comentario: se busca en crudo.
          acotada = (raw ~ /ALCANCE: SIN MIGRACIONES/ || verificada)
          if (MODE == "covered")            print F ":" start
          else if (!acotada && !reclama)    print F ":" start
        }
        inb = 0; next
      }
      inb {
        raw = raw $0 "\n"
        # Cuerpo de here-doc: es DATO, no comandos. Un here-doc cuyo texto cita el comando se
        # marcaba como infractor (par2-p1 M5) — eso es medir sintaxis, no lo que el shell corre.
        if (hd != "") { tt = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", tt); if (tt == hd) hd = ""; next }
        linea = cont $0
        # Unir continuaciones: `gh \` + `api --method PUT .../merge` es UN comando (M2).
        if (linea ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", linea); cont = linea; next }
        cont = ""
        t = linea; sub(/^[[:space:]]+/, "", t)
        if (t ~ /^#/) next          # comentario puro: NO es comando efectivo
        # Apertura de here-doc: la línea SÍ es un comando, pero su cuerpo no lo es.
        if (match(linea, /<<-?[[:space:]]*[^[:space:]|;&()]+/)) {
          d = substr(linea, RSTART, RLENGTH); sub(/^<<-?[[:space:]]*/, "", d)
          gsub(/[^A-Za-z0-9_]/, "", d); if (d != "") hd = d
        }
        eff = eff linea "\n"
      }
    ' "$f"
  done
}
covered="$(scan_fences covered)"; n_covered="$(printf '%s' "$covered" | grep -c . || true)"
offenders="$(scan_fences offenders)"
# 23a — la guarda tiene que estar MIDIENDO algo: si un renombrado deja 0 fences que inspeccionar,
# el check pasaría en verde sin comprobar nada (falso verde ya visto en este encargo).
if [ "$n_covered" -ge 2 ]; then
  echo "  ✓ la guarda inspecciona $n_covered recetas ejecutables que mergean"; pass=$((pass+1))
else
  echo "  ✗ la guarda solo ve $n_covered recetas (esperadas >=2): no está midiendo nada"; fail=$((fail+1))
fi
# 23b — y ninguna de ellas puede omitir a la vez el acotamiento y el gate.
if [ -z "$offenders" ]; then
  echo "  ✓ toda receta que mergea acota el caso con migración o exige APPLY-RUN"; pass=$((pass+1))
else
  echo "  ✗ recetas que mergean sin acotar ni exigir el gate:"
  printf '%s\n' "$offenders" | sed 's/^/      /'; fail=$((fail+1))
fi

echo "== T24: la adquisición de ref 02 §8 se acredita EJECUTÁNDOLA contra mocks, no leyéndola."
echo "   Controles negativos PERMANENTES (par-p1 BLOQUEANTES 1 y 2): un fallo hallado por"
echo "   inyección que no se vuelve control fijo lo reabre el siguiente refactor =="
REF02="$SKILLROOT/references/02-protocolo-por-pr.md"
ACQ="$WORK/acq.sh"
awk '!inb && /^[[:space:]]*```/ { inb=1; buf=""; next }
     inb && /^[[:space:]]*```/  { if (buf ~ /8\.0\)/) { printf "%s", buf; exit } inb=0; next }
     inb { buf = buf $0 "\n" }' "$REF02" > "$ACQ"
# La receta se ejecuta TAL CUAL: ella misma carga `apply-gate.sh` con su propio `source`
# (par8-p1 BLOQUEANTE: concatenarle la funcion delante acreditaba un programa DISTINTO del que
# opera un humano). Solo se le indica DONDE esta el fichero, no COMO cargarlo.
ACQ_RUN="$ACQ"
GATE_LIB="$SKILLROOT/references/apply-gate.sh"
if [ -f "$GATE_LIB" ] && bash -n "$GATE_LIB" 2>/dev/null; then
  echo "  ✓ apply-gate.sh existe y es sintacticamente valido"; pass=$((pass+1))
else
  echo "  ✗ falta o no parsea apply-gate.sh (la receta no podria cargarlo)"; fail=$((fail+1))
fi
# UNA sola definicion: el fence de ref 01 documenta, pero debe ser IDENTICO al fichero real.
if diff -q <(sed 's/^      //' "$CLASSIFIER") <(sed -n '/^classify_log()/,$p' "$GATE_LIB") >/dev/null 2>&1; then
  echo "  ✓ el fence de ref 01 y apply-gate.sh son IDENTICOS (una sola definicion)"; pass=$((pass+1))
else
  echo "  ✗ ref 01 y apply-gate.sh DIVERGEN: dos definiciones de lo mismo"; fail=$((fail+1))
fi
if [ -s "$ACQ" ] && bash -n "$ACQ" 2>/dev/null; then
  echo "  ✓ fence de ref 02 §8 extraído del .md real y sintácticamente válido"; pass=$((pass+1))
else
  echo "  ✗ no pude extraer/parsear el fence de ref 02 §8"; fail=$((fail+1))
fi

# Las cajas corren la receta con `cwd` = caja, y la receta ACREDITA la biblioteca contra su ruta
# CANONICA relativa (par9-p1 BLOQUEANTE: `TM_GATE_LIB` ya no puede sustituir el cuerpo del gate).
# Sembrar esa ruta dentro de la caja reproduce lo que un operador tiene en su repo; sin ella la
# receta abortaria por falta de canon y todos los controles medirian ESA ausencia en vez de lo
# que buscan — un verde/rojo por la razon equivocada.
sembrar_canon() {  # $1 = caja
  mkdir -p "$1/.claude/skills/talent-merger/references"
  cp "$GATE_LIB" "$1/.claude/skills/talent-merger/references/apply-gate.sh"
}

acq_case() {  # $1=escenario  $2=log inicial  $3=ESTACION  →  "MERGE|NO-MERGE LOCK|NOLOCK"
  local box bin; box="$(mktemp -d "$WORK/box.XXXXXX")"; bin="$box/bin"; mkdir -p "$bin"
  sembrar_canon "$box"
  printf '%s' "$2" > "$box/flock.log"; : > "$box/merge.calls"; : > "$box/lock.calls"
  cat > "$bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "merge" ]; then echo MERGE >> "$MERGE_CALLS"; exit "${MERGE_RC:-0}"; fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then printf '%s\n' "${PR_VIEW_OUT-MERGED 2026-01-01T00:00:00Z}"; exit "${PR_VIEW_RC:-0}"; fi
exit 0
GH
  chmod +x "$bin/gh"
  cerrar_doble_gh "$bin/gh" || exit 1
  # La receta toma el nonce de /proc/sys/kernel/random/uuid y solo cae a `uuidgen` si eso falla
  # (misma expresion que ref 01). Mockear solo `uuidgen` dejaba los controles PUENTEADOS en
  # cualquier maquina con /proc: hay que interceptar la fuente REAL para gobernar el nonce.
  case "$1" in
    uuidgen_fail) printf '#!/usr/bin/env bash\nexit 1\n' > "$bin/uuidgen"
                  printf '#!/usr/bin/env bash\nif [ "${1:-}" = "/proc/sys/kernel/random/uuid" ]; then exit 1; fi\nexec /bin/cat "$@"\n' > "$bin/cat" ;;
    nonce_basura) printf '#!/usr/bin/env bash\necho "no-es-un-uuid"\n' > "$bin/uuidgen"
                  printf '#!/usr/bin/env bash\nif [ "${1:-}" = "/proc/sys/kernel/random/uuid" ]; then echo "no-es-un-uuid"; exit 0; fi\nexec /bin/cat "$@"\n' > "$bin/cat" ;;
    *)            printf '#!/usr/bin/env bash\necho 00000000-0000-4000-8000-000000000007\n' > "$bin/uuidgen"
                  printf '#!/usr/bin/env bash\nif [ "${1:-}" = "/proc/sys/kernel/random/uuid" ]; then echo 00000000-0000-4000-8000-000000000007; exit 0; fi\nexec /bin/cat "$@"\n' > "$bin/cat" ;;
  esac
  case "$1" in
    date_vacio)   printf '#!/usr/bin/env bash\necho ""\n' > "$bin/date" ;;
    iso_fijo)     printf '#!/usr/bin/env bash\necho "2026-01-01T00:00:00Z"\n' > "$bin/date" ;;
    date_basura)  printf '#!/usr/bin/env bash\necho "not-a-timestamp"\n' > "$bin/date" ;;
    fecha_imposible) printf '#!/usr/bin/env bash\necho "2026-99-99T99:99:99Z"\n' > "$bin/date" ;;
    # ALPINE REPRODUCIDO (ronda 30, M2): un `date` SIN la extension GNU `-d`, que es lo que hay
    # en BusyBox — y la fabrica corre en contenedores. Genera el sello igual que el real, pero
    # rechaza `-d` con rc 1, exactamente como busybox. Si `identidad_canonica` volviera a validar
    # el calendario con `date -d`, la comparacion no cuajaria NI PARA UN SELLO VALIDO y la
    # adquisicion no podria completarse NUNCA: indisponibilidad total, no degradacion.
    date_sin_d) printf '%s\n' '#!/usr/bin/env bash' \
                  'for a in "$@"; do [ "$a" = "-d" ] && exit 1; done' \
                  'exec /bin/date "$@"' > "$bin/date" ;;
  esac
  case "$1" in
    mktemp_vacio) printf '#!/usr/bin/env bash\necho ""\n' > "$bin/mktemp" ;;
  esac
  # ── El predicado de §8.0 tiene TRES ramas y la caja solo ejercitaba UNA. Sin `git` en el box,
  # `rev-parse --git-dir` falla siempre ⇒ N_MIG=-1 ⇒ reserva: la rama de diagnóstico. Con una
  # sola rama, «se comporta bien» es INDISTINGUIBLE de «no se ejecuta nunca» — que es exactamente
  # como se coló el BLOQUEANTE de la ronda anterior. Estos mocks gobiernan las otras dos.
  # Se mockea `git` por la MISMA razón que `gh`/`date`/`uuidgen`: el control observa el MECANISMO
  # del predicado, no el estado accidental del árbol donde corra el arnés.
  case "$1" in
    nmig_cero)  printf '%s\n' '#!/usr/bin/env bash' \
                  'case "${1:-}" in rev-parse) exit 0 ;; merge-base) echo base0000 ;; diff) exit 0 ;; *) exit 0 ;; esac' \
                  > "$bin/git" ;;
    nmig_uno)   printf '%s\n' '#!/usr/bin/env bash' \
                  'case "${1:-}" in rev-parse) exit 0 ;; merge-base) echo base0000 ;; diff) echo supabase/migrations/20260101000000_x.sql ;; *) exit 0 ;; esac' \
                  > "$bin/git" ;;
    nmig_degenerado) printf '%s\n' '#!/usr/bin/env bash' \
                  'case "${1:-}" in rev-parse) exit 0 ;; merge-base) echo deadbeef ;; diff) exit 0 ;; *) exit 0 ;; esac' \
                  > "$bin/git" ;;
    nmig_cero_diag) printf '%s\n' '#!/usr/bin/env bash' \
                  'case "${1:-}" in rev-parse) exit 0 ;; merge-base) echo base0000 ;; diff) exit 0 ;; *) exit 0 ;; esac' \
                  > "$bin/git" ;;
    nmig_uno_diag)  printf '%s\n' '#!/usr/bin/env bash' \
                  'case "${1:-}" in rev-parse) exit 0 ;; merge-base) echo base0000 ;; diff) echo supabase/migrations/20260101000000_x.sql ;; *) exit 0 ;; esac' \
                  > "$bin/git" ;;
  esac
  # La rama de DIAGNOSTICO (cliente falla + PR OPEN) es la que toca `CLASS_FILE` DESPUES del
  # bloque de reserva. Sin ejercitarla solo se prueba el camino feliz — y el camino feliz no
  # revienta bajo `set -u` aunque la variable no exista.
  local merge_rc=0 pr_view="MERGED 2026-01-01T00:00:00Z"
  case "$1" in
    nmig_cero_diag|nmig_uno_diag) merge_rc=1; pr_view="OPEN null" ;;
  esac
  # El mock de flock REGISTRA su invocación: así el control observa el MECANISMO (¿se tomó el
  # lock?) y no solo el desenlace del escenario. Un control que pasa con el mutex arrancado no
  # protege el mutex (par2-p1 M3: sustituir `flock -x 9` por `true` dejaba todo en verde).
  if [ "$1" = "flock_fail" ]; then
    printf '#!/usr/bin/env bash\necho CALL >> "$LOCK_CALLS"\nexit 1\n' > "$bin/flock"
  else
    # El mock ejecuta el comando POR ARGV, que es la forma que usa el gate desde que `$line`
    # dejo de interpolarse dentro de un `-c` (ronda 28, CRITICAL). Reconocer solo `$2 = -c`
    # habria dejado este mock midiendo una forma QUE YA NO EXISTE: devolveria 0 sin ejecutar
    # nada y `publish_close` pareceria publicar sin escribir una sola linea — verde y sin
    # valor. Y es simetrico: si alguien reintroduce `flock FILE -c "…$var…"`, aqui no hay
    # rama que lo ejecute y el control enrojece por MECANISMO, no por opinion.
    printf '%s\n' '#!/usr/bin/env bash' 'echo CALL >> "$LOCK_CALLS"' \
      'case "${1:-}" in -*) case "${3:-}" in "") exit 0 ;; *) echo "flock-mock: forma no reconocida: $*" >&2; exit 99 ;; esac ;; esac' \
      'shift' '[ "$#" -gt 0 ] || exit 0' 'exec "$@"' \
      > "$bin/flock"
  fi
  local hd_val; if [ "$1" = "sin_head" ]; then hd_val=""; else hd_val=deadbeef; fi
  chmod +x "$bin"/* 2>/dev/null || true
  # TMPDIR del box: el `mktemp` de la receta crea su CLASS_FILE DENTRO del sandbox, no en /tmp.
  ( cd "$box" && PATH="$bin:$PATH" MERGE_CALLS="$box/merge.calls" LOCK_CALLS="$box/lock.calls" \
FLOCK_FILE="$box/flock.log" TM_FLOCK_CANONICO_TRUSTED="$box/flock.log" ESTACION="${3-M1}" PR="42" TMPDIR="$box" \
      HEAD="$hd_val" MERGE_RC="$merge_rc" PR_VIEW_OUT="$pr_view" \
      LC_ALL=C LANG=C \
      bash "$ACQ_RUN" ) >/dev/null 2>"$box/err.log"; echo "$?" > "$box/rc"
  ACQ_LAST_BOX="$box"
  local m l
  if [ -s "$box/merge.calls" ]; then m=MERGE; else m=NO-MERGE; fi
  if [ -s "$box/lock.calls" ];  then l=LOCK;  else l=NOLOCK;  fi
  echo "$m $l"
}
AJENO='# APPLY-RUN [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011
'
CIERRE_AJENO="$AJENO"'# APPLY-DONE [M5] #88 2026-01-02T00:00:00Z 00000000-0000-4000-8000-000000000014
'
DONE_ANTES='# APPLY-DONE [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011
'"$AJENO"
FAILED_TRUNC="$AJENO"'# APPLY-FAILED [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011
'
FAILED_ESCALAR="$AJENO"'# APPLY-FAILED [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011 ESCALAR
'
# RUN A (titular) · RUN B (perdedor ⇒ VOID para siempre) · DONE A (cierra A). B NO puede
# promocionarse: si lo hiciera, quedaría de titular permanente esperando un cierre que nunca
# publicará y bloquearía todos los merges con migración.
VOID_Y_CIERRE="$AJENO"'# APPLY-RUN [M5] #88 2026-01-01T00:00:01Z 00000000-0000-4000-8000-000000000015
# APPLY-DONE [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011
'
# Ciclo ESCALAR→GO del CEO→RECOVERS→RUN recuperador→DONE: legítimo y COMPLETO ⇒ el gate queda LIBRE.
# Que un bloqueo no tenga salida por ninguna secuencia legal NO es fail-closed, es un bug.
# EL `APPLY-ESCALAR-GO` LO AÑADE EL RULING DEL CEO (ronda 29), y este fixture SE ACTUALIZA porque
# codificaba el contrato ANTERIOR — no para hacer pasar nada: sin el GO, la secuencia ya NO es
# legal, así que un fixture que la llamara «legítima y COMPLETA» estaría describiendo un protocolo
# que dejó de existir. La INTENCIÓN del caso no cambia —una recuperación legítima completa deja el
# gate LIBRE—; lo que cambia es qué secuencia es legítima. Medido con el resolvedor real: sin GO da
# `BLOQUEADO: APPLY-RECOVERS sin APPLY-ESCALAR-GO previo`; con él, `estado=LIBRE`.
RECUP_COMPLETA="$AJENO"'# APPLY-FAILED [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011 ESCALAR
# APPLY-ESCALAR-GO #77 00000000-0000-4000-8000-000000000011 [CEO] 2026-01-01T00:05:00Z
# APPLY-RECOVERS #77 00000000-0000-4000-8000-000000000011 #78 00000000-0000-4000-8000-000000000016 [M4]
# APPLY-RUN [M4] #78 2026-01-01T00:10:00Z 00000000-0000-4000-8000-000000000016
# APPLY-DONE [M4] #78 2026-01-01T00:10:00Z 00000000-0000-4000-8000-000000000016
'
ESCALAR_SIN_REC="$AJENO"'# APPLY-FAILED [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011 ESCALAR
'
TRANSITORIO_ABIERTO="$AJENO"'# APPLY-FAILED [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011 TRANSITORIO
'
REPLAY="$AJENO"'# APPLY-DONE [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011
'"$AJENO"
CIERRE_OTRA_EST="$AJENO"'# APPLY-DONE [M5] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011
'
ESPACIO_INICIAL='   # APPLY-RUN [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011
'
REPLAY_Y_DONE="$REPLAY"'# APPLY-DONE [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011
'
# A titular · B perdedor (VOID) · DONE A · replay idéntico de B ⇒ B NO puede ganar ahora.
VOID_REPLAY="$AJENO"'# APPLY-RUN [M5] #88 2026-01-01T00:00:01Z 00000000-0000-4000-8000-000000000015
# APPLY-DONE [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011
# APPLY-RUN [M5] #88 2026-01-01T00:00:01Z 00000000-0000-4000-8000-000000000015
'
# Gap TRANSITORIO en el PR 77: el claim propio es del PR 42 ⇒ no puede colarse.
TRANS_OTRO_PR="$TRANSITORIO_ABIERTO"
# Gap TRANSITORIO en el PR 42 (el del claim propio) publicado por M4: el retry lo hace M1.
# ref 01 autoriza el retry TRANSITORIO por CUALQUIER estación — la propiedad es el GAP.
TRANS_MISMO_PR='# APPLY-RUN [M4] #42 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011
# APPLY-FAILED [M4] #42 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011 TRANSITORIO
'
# Perdedor que reintenta. Con identidad NUEVA (nonce nuevo) DEBE poder adquirir; reusando la
# identidad VOID no adquiere JAMAS — por eso ref 01 paso 3 manda repetir desde el paso 0.
PERDEDOR_NONCE_NUEVO="$AJENO"'# APPLY-RUN [M1] #42 2026-01-01T00:00:01Z 99999999-9999-9999-9999-999999999999
# APPLY-DONE [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011
'
PERDEDOR_MISMO_NONCE="$AJENO"'# APPLY-RUN [M1] #42 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000007
# APPLY-DONE [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011
'
# Ciclo con sello FUERA DE RANGO (mes 19, día 39, hora 29): con un parser permisivo se daba por
# válido, dejaba el gate LIBRE y permitía el merge siguiente. Un dato no canónico DEBE caer en
# el default BLOQUEAR — y esto es lo que obliga a que parser y productor compartan la ERE.
SELLO_FUERA_RANGO='# APPLY-RUN [M4] #77 2026-19-39T29:00:00Z 00000000-0000-4000-8000-000000000011
# APPLY-DONE [M4] #77 2026-19-39T29:00:00Z 00000000-0000-4000-8000-000000000011
'
# Nonce con longitudes de grupo NO canónicas: el productor las rechazaba y el parser no.
# Cadena con MAS DE UN fallo: A y B fallan, C cierra el gap. Ni A ni B pueden resucitar.
CADENA_DOS_FALLOS='# APPLY-RUN [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011
# APPLY-FAILED [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011 TRANSITORIO
# APPLY-RUN [M4] #77 2026-01-01T00:01:00Z 00000000-0000-4000-8000-000000000015
# APPLY-FAILED [M4] #77 2026-01-01T00:01:00Z 00000000-0000-4000-8000-000000000015 TRANSITORIO
# APPLY-RUN [M4] #77 2026-01-01T00:02:00Z 00000000-0000-4000-8000-000000000016
# APPLY-DONE [M4] #77 2026-01-01T00:02:00Z 00000000-0000-4000-8000-000000000016
# APPLY-RUN [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011
'
# Historial CONTRADICTORIO: la misma identidad cerrada como DONE y luego como FAILED ESCALAR.
CIERRE_CONTRADICTORIO='# APPLY-RUN [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011
# APPLY-DONE [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011
# APPLY-FAILED [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011 ESCALAR
'
NONCE_LONGITUD='# APPLY-RUN [M4] #77 2026-01-01T00:00:00Z aaaa-bb-cc-dd-ee
# APPLY-DONE [M4] #77 2026-01-01T00:00:00Z aaaa-bb-cc-dd-ee
'
# El desenlace MERGE/LOCK no distingue «terminó limpio» de «murió a mitad»: el mock de `gh`
# registra la llamada ANTES de devolver su rc, así que un crash POSTERIOR deja la misma huella.
# `acq_u` mira el observable que sí lo distingue: el stderr real de la receta.
# EL DISCRIMINANTE YA NO ES SÓLO EL RC: el mensaje discrimina TAMBIÉN, de forma INDEPENDIENTE.
# La redacción anterior decía «el discriminante es el mensaje, NO el rc», y una auditoría externa
# la midió por los DOS lados: mutar sólo el mensaje enrojece los tres brazos (el mensaje discrimina)
# **y** mutar sólo el rc también los enrojece (el rc SIGUE discriminando, en la rama `rc != $3`, que
# se evalúa antes). O sea: la afirmación no era falsa, era MÁS FUERTE de lo que el mecanismo
# sostiene — y sobrevender un discriminante es un defecto DISTINTO de no tenerlo, porque manda el
# arreglo en la dirección equivocada. Aquí se corrige LA AFIRMACIÓN y no el mecanismo: hacer cierta
# la frase original exigiría RETIRAR la comprobación del rc, que es estrictamente peor. Lo que el
# mensaje aporta es cubrir el hueco que el rc solo no cubre: un rc correcto alcanzado por otro
# camino —o una guarda retirada cuyo rc coincide por casualidad— pasaba en verde sin que nadie
# ejecutara lo que se dice vigilar.
acq_u() {  # $1=etiqueta  $2=escenario  $3=rc esperado  $4=mensaje propio de la guarda  $5=estación
  acq_case "$2" "" "${5-M1}" >/dev/null
  local rc err; rc="$(cat "$ACQ_LAST_BOX/rc")"; err="$(cat "$ACQ_LAST_BOX/err.log")"
  if grep -q "unbound variable" <<<"$err"; then
    echo "  ✗ $1 → la receta murió por variable NO DEFINIDA bajo set -u"; fail=$((fail+1))
  elif [ "$rc" != "$3" ]; then
    echo "  ✗ $1 → rc=$rc (esperado $3)"; fail=$((fail+1))
  elif ! grep -qF "$4" <<<"$err"; then
    echo "  ✗ $1 → rc=$rc correcto pero SIN el mensaje de la guarda ('$4'): el brazo pasa por otro camino"; fail=$((fail+1))
  else
    echo "  ✓ $1 → rc=$rc, sin unbound, con el mensaje de la guarda"; pass=$((pass+1))
  fi; }
acq_ck() { local got; got="$(acq_case "$2" "$3" "${5-M1}")"
  if [ "$got" = "$4" ]; then echo "  ✓ $1 → $got"; pass=$((pass+1))
  else echo "  ✗ $1 → $got (esperado $4)"; fail=$((fail+1)); fi; }

# — el gate ARRANCA LIBRE en los casos de identidad: así el NO-MERGE prueba que abortó por la
#   validación, no porque el turno estuviera ocupado de todas formas (par2-p1 M3).
acq_ck "uuidgen rc=1: aborta ANTES de tocar el recurso compartido"    uuidgen_fail "" "NO-MERGE NOLOCK"
acq_ck "nonce con rc=0 pero basura: se valida el VALOR, no el rc"     nonce_basura "" "NO-MERGE NOLOCK"
acq_ck "date rc=0 con salida VACÍA"                                  date_vacio   "" "NO-MERGE NOLOCK"
acq_ck "date rc=0 con sello malformado"                              date_basura  "" "NO-MERGE NOLOCK"
acq_ck "mktemp rc=0 con salida VACÍA: sin canal de clasificación"    mktemp_vacio "" "NO-MERGE NOLOCK"
acq_ck "ESTACION vacía: '# APPLY-RUN [] …' es un token incorrelacionable" \
       ok "" "NO-MERGE NOLOCK" ""
# — LAS TRES RAMAS DEL PREDICADO DE §8.0, ejecutadas. El par que DISCRIMINA es cero-vs-uno: si
#   los dos reservaran, «-1 reserva» sería indistinguible de «reserva siempre» y el cierre pasaría
#   matando el propósito del gate. El degenerado (BASE == HEAD) es un PR ya fundido que SÍ puede
#   traer migración: su vacío no es legítimo y por eso reserva.
acq_ck "§8.0 N_MIG=0 (repo, sin migraciones): NO reserva y mergea"   nmig_cero "" "MERGE NOLOCK"
# O1 (deuda declarada en v7, cerrada aquí): el camino feliz con N_MIG=0 también recorre código
# que fuera del bloque de reserva podría referenciar variables sin definir. Su desenlace
# (MERGE NOLOCK) NO lo detectaría — el mock de `gh` ya habría registrado la llamada —, así que
# se afirma también su stderr y su rc, igual que en la rama de diagnóstico.
acq_u  "§8.0 N_MIG=0 camino feliz: lo DICE y sale 0"                 nmig_cero 0 "NO se reclama APPLY-RUN"
acq_ck "§8.0 N_MIG=1 (repo, con migración): reserva y mergea"        nmig_uno  "" "MERGE LOCK"
acq_ck "§8.0 N_MIG=-1 fuera de un repo git: reserva (fail-closed)"   ok        "" "MERGE LOCK"
acq_ck "§8.0 N_MIG=-1 con BASE == HEAD (diff degenerado): reserva"   nmig_degenerado "" "MERGE LOCK"
# — LA RAMA DE DIAGNOSTICO, la que toca CLASS_FILE fuera del bloque de reserva. Con N_MIG=0 esa
#   variable NO existe: sin guarda, `set -u` mata la receta AQUI y no en el camino feliz.
acq_u  "§8.0 N_MIG=0 + merge falla: lo DICE y sale 1"                nmig_cero_diag 1 "no hay gate que cerrar"
# La MISMA afinación sobre la guarda de identidad canónica: hasta ahora sólo se afirmaba su
# desenlace (NO-MERGE NOLOCK), que es alcanzable por otros caminos. Ahora se exige SU mensaje.
acq_u  "identidad NO canónica: lo DICE y aborta con 2"              ok 2 "identidad NO canónica" ""
acq_ck "§8.0 N_MIG=1 + merge falla + PR OPEN: diagnostica y cierra" nmig_uno_diag  "" "MERGE LOCK"
acq_ck "flock rc=1 con gate LIBRE: sin lock no hay reserva"          flock_fail   "" "NO-MERGE LOCK"
acq_ck "RUN ajeno abierto: el turno es suyo"                         ok "$AJENO" "NO-MERGE LOCK"
acq_ck "cierre de OTRO run_id NO libera el turno ajeno"              ok "$CIERRE_AJENO" "NO-MERGE LOCK"
acq_ck "DONE ANTERIOR al RUN no lo cierra (orden, no pertenencia)"   ok "$DONE_ANTES" "NO-MERGE LOCK"
acq_ck "APPLY-FAILED truncado sin categoría NO es un cierre"         ok "$FAILED_TRUNC" "NO-MERGE LOCK"
acq_ck "APPLY-FAILED ESCALAR del titular: gap roto, nadie mergea"    ok "$FAILED_ESCALAR" "NO-MERGE LOCK"
acq_ck "perdedor VOID no se promueve al cerrar el titular: el claim nuevo gana" \
       ok "$VOID_Y_CIERRE" "MERGE LOCK"
# — positivo: además de mergear, EXIGE que el lock se haya invocado de verdad.
acq_ck "gate libre y claim propio único: se gana el turno Y se tomó el lock" \
       ok "" "MERGE LOCK"
# — par3-p1: los cinco huecos de ENUMERACIÓN del autómata, cada uno con su secuencia.
acq_ck "recuperación ESCALAR COMPLETA libera el gate (no bloquea la flota para siempre)" \
       ok "$RECUP_COMPLETA" "MERGE LOCK"
acq_ck "ESCALAR sin RECOVERS: el gap sigue roto, nadie mergea"        ok "$ESCALAR_SIN_REC" "NO-MERGE LOCK"
acq_ck "FAILED TRANSITORIO NO resuelve el gap: otro PR no puede colarse" ok "$TRANSITORIO_ABIERTO" "NO-MERGE LOCK"
# Muere la IDENTIDAD, no el GATE: el replay de una identidad terminal se IGNORA y el parseo
# CONTINÚA (abortar dejaba inalcanzable todo token legal posterior en un flock append-only).
acq_ck "replay de un RUN cerrado: se ignora y NO congela el gate"     ok "$REPLAY" "MERGE LOCK"
acq_ck "replay terminal seguido de un DONE posterior: sigue sin congelar" ok "$REPLAY_Y_DONE" "MERGE LOCK"
acq_ck "replay de un PERDEDOR (VOID registrado) no puede ganar después"  ok "$VOID_REPLAY" "MERGE LOCK"
acq_ck "gap TRANSITORIO pendiente: la MISMA estación no cuela otro PR"   ok "$TRANS_OTRO_PR" "NO-MERGE LOCK"
acq_ck "retry TRANSITORIO del MISMO gap por OTRA estación es legal"      ok "$TRANS_MISMO_PR" "MERGE LOCK"
acq_ck "sello del LOG fuera de rango: dato no canonico cae en el default BLOQUEAR" ok "$SELLO_FUERA_RANGO" "NO-MERGE LOCK"
acq_ck "nonce del LOG con longitudes no canonicas: mismo default"     ok "$NONCE_LONGITUD" "NO-MERGE LOCK"
acq_ck "cadena con DOS fallos: ninguna identidad fallida resucita"     ok "$CADENA_DOS_FALLOS" "MERGE LOCK"
acq_ck "cierre CONTRADICTORIO (DONE y luego FAILED) cae en BLOQUEAR"  ok "$CIERRE_CONTRADICTORIO" "NO-MERGE LOCK"
acq_ck "perdedor que reintenta con identidad NUEVA: adquiere el turno"  ok "$PERDEDOR_NONCE_NUEVO" "MERGE LOCK"
acq_ck "perdedor que REUSA su identidad VOID (mismo nonce Y mismo sello)"  iso_fijo "$PERDEDOR_MISMO_NONCE" "NO-MERGE LOCK"
acq_ck "un DONE de OTRA estación no cierra el turno (identidad completa)" ok "$CIERRE_OTRA_EST" "NO-MERGE LOCK"
acq_ck "token activo con espacio inicial NO es invisible"            ok "$ESPACIO_INICIAL" "NO-MERGE LOCK"
acq_ck "HEAD ausente: se rechaza ANTES del claim, no tras ganarlo"    sin_head "" "NO-MERGE NOLOCK"

# — LO ACREDITADO Y LO EJECUTADO SON EL MISMO OBJETO (par10-p1, BLOQUEANTE). Este bloque fallo
#   dos veces por acreditar un PROXY: primero el HECHO de cargar (par9), luego DOS `declare -f`
#   mientras se cargaba UN PROGRAMA (par10) — y encima la acreditacion EJECUTABA la candidata
#   para poder mirarla. Ya no hay candidata: la receta lee UNA vez la ruta canonica, acredita esa
#   cadena por sha256 contra su ancla y evalua ESA MISMA cadena. Asi que aqui se mutan los BYTES
#   del canon dentro de la caja y se exige que la receta ABORTE ANTES de reservar.
lib_ck() {  # $1=nombre  $2=contenido que REEMPLAZA al canon ('' = vacio; __SIN__ = borrarlo)
  local lbox canon; lbox="$(mktemp -d "$WORK/lib.XXXXXX")"
  : > "$lbox/flock.log"; : > "$lbox/merge.calls"
  sembrar_canon "$lbox"
  canon="$lbox/.claude/skills/talent-merger/references/apply-gate.sh"
  if [ "$2" = __SIN__ ]; then rm -f "$canon"; else printf '%s' "$2" > "$canon"; fi
  ( cd "$lbox" && MERGE_CALLS="$lbox/merge.calls" FLOCK_FILE="$lbox/flock.log" TM_FLOCK_CANONICO_TRUSTED="$lbox/flock.log" \
      ESTACION="M1" PR="42" HEAD="deadbeef" TMPDIR="$lbox" bash "$ACQ_RUN" ) >/dev/null 2>&1
  if [ ! -s "$lbox/merge.calls" ] && [ ! -s "$lbox/flock.log" ]; then
    echo "  ✓ $1: aborta ANTES de reservar (ni merge ni APPLY-RUN)"; pass=$((pass+1))
  else
    echo "  ✗ $1: reservo y/o mergeo con un artefacto NO acreditado"; fail=$((fail+1))
  fi
}
lib_ck "canon AUSENTE" __SIN__
lib_ck "canon VACIO" ''
lib_ck "canon TRUNCADO (solo classify_log)" 'classify_log() { :; }
'
lib_ck "canon con los dos cuerpos, pero NO-OP" 'classify_log() { :; }
publish_close() { :; }
'
# EL caso de par10-p1: los dos cuerpos canonicos INTACTOS mas un `readonly FLOCK_FILE` de nivel
# superior que secuestra el recurso compartido. Comparando funciones pasaba —y el APPLY-RUN
# acababa en OTRO flock, dejando el previsto sin RUN—; con identidad del fichero entero, no.
lib_ck "canon canonico + PREFIJO de nivel superior que reasigna la ruta del flock" \
  "readonly FLOCK_FILE=/tmp/secuestrado-por-el-prefijo
$(cat "$GATE_LIB")"
# Y el mas fino de todos: un COMENTARIO anadido. NO cambia lo que el programa hace, pero cambia
# el objeto. Si esto pasara, la acreditacion seguiria siendo de un proxy del comportamiento y no
# del artefacto — y ahi es donde se colaron las dos rondas anteriores.
lib_ck "canon con un COMENTARIO anadido (mismo comportamiento, OTRO objeto)" \
  "$(cat "$GATE_LIB")
# comentario inocuo anadido por el control"

# Cinco «aborta» seguidos serian un verde vacio si la receta abortara SIEMPRE: hace falta ver que
# la MISMA via reserva cuando el canon esta intacto.
canon_box="$(mktemp -d "$WORK/canon.XXXXXX")"; : > "$canon_box/flock.log"; : > "$canon_box/merge.calls"
canon_bin="$canon_box/bin"; mkdir -p "$canon_bin"; sembrar_canon "$canon_box"
printf '#!/usr/bin/env bash\n[ "${1:-}" = pr ] && [ "${2:-}" = merge ] && echo MERGE >> "$MERGE_CALLS"\nexit 0\n' > "$canon_bin/gh"
chmod +x "$canon_bin/gh"
cerrar_doble_gh "$canon_bin/gh" || exit 1
( cd "$canon_box" && PATH="$canon_bin:$PATH" MERGE_CALLS="$canon_box/merge.calls" \
    FLOCK_FILE="$canon_box/flock.log" TM_FLOCK_CANONICO_TRUSTED="$canon_box/flock.log" ESTACION="M1" PR="42" HEAD="deadbeef" TMPDIR="$canon_box" \
    bash "$ACQ_RUN" ) >/dev/null 2>&1
if [ -s "$canon_box/merge.calls" ] && grep -q '^# APPLY-RUN ' "$canon_box/flock.log"; then
  echo "  ✓ con el canon INTACTO la misma via SI reserva y mergea (el gate no bloquea todo)"
  pass=$((pass+1))
else
  echo "  ✗ ni con el canon intacto reserva: la acreditacion bloquea el caso legitimo"
  fail=$((fail+1))
fi
# El ancla de ref 02 tiene que corresponder al fichero REAL: si alguien edita `apply-gate.sh` y no
# actualiza el ancla, la receta abortaria en produccion y aqui nadie se habria enterado. Este
# control es el que convierte el ancla en mantenible en vez de en una bomba de relojeria.
_ancla="$(grep -oE "^TM_GATE_SHA='[0-9a-f]{64}'" "$ACQ" | cut -d"'" -f2)"
_crudo="$(sha256sum < "$GATE_LIB" | cut -d' ' -f1)"
_normalizado="$(printf '%s\n' "$(cat "$GATE_LIB")" | sha256sum | cut -d' ' -f1)"
# El ancla se contrasta contra el sha CRUDO del fichero, que es lo que la receta hashea desde su
# copia materializada. La version anterior lo comparaba contra el sha NORMALIZADO —la MISMA
# formula que usaba la receta—, o sea la formula contra si misma: `$(cat)` descarta NUL y saltos
# finales, asi que cuatro ficheros DISTINTOS daban el mismo digest y el control no veia nada
# (par11-p1, MAYOR). `_normalizado` se sigue calculando SOLO para poder DECIRLO en la salida
# cuando ambos divergen: es diagnostico, no criterio. Quien decide es el crudo.
if [ -n "$_ancla" ] && [ "$_ancla" = "$_crudo" ]; then
  echo "  ✓ el ancla de ref 02 es el sha256 CRUDO de apply-gate.sh (bytes tal cual)"
  pass=$((pass+1))
else
  echo "  ✗ ancla: ref 02 dice '${_ancla:-<ninguna>}', crudo '$_crudo', normalizado '$_normalizado'"
  fail=$((fail+1))
fi
# El congelado no puede contener enlaces simbolicos: el bootstrap los rechaza antes de copiar,
# pero eso es una decision de ARRANQUE que un refactor podria quitar sin que nada enrojezca.
# El RC de `find` decide junto con su salida: un error de recorrido que no imprime ruta se leia
# como «cero enlaces» y volvia fail-open un contrato fail-closed (par14-p1, MAYOR).
_enl_tardio="$(find "$SKILLROOT" -type l -print 2>/dev/null)"; _rc_enl=$?
if [ "$_rc_enl" -eq 0 ] && [ -z "$_enl_tardio" ]; then
  echo "  ✓ el congelado no contiene enlaces simbolicos (nada apunta a contenido vivo)"
  pass=$((pass+1))
else
  echo "  ✗ hay enlaces simbolicos dentro del congelado: leen contenido VIVO fuera de la huella"
  fail=$((fail+1))
fi
# Y el ejecutor tiene que estar DENTRO del congelado: si este fichero se corriera desde el arbol
# vivo, la huella cubriria una copia y el resultado lo emitiria otro objeto (par11-p1, MAYOR).
if [ "${BASH_SOURCE[0]}" = "$SKILLROOT/references/proc-m13.selftest.sh" ]; then
  echo "  ✓ el propio harness se ejecuta DESDE el congelado que mide"; pass=$((pass+1))
else
  echo "  ✗ el harness corre desde '${BASH_SOURCE[0]}', fuera de lo congelado: mide una copia y ejecuta otra"
  fail=$((fail+1))
fi
# El marcador de congelado NO se cree por si solo (par13-p1, BLOQUEANTE). Antes bastaba con que
# la variable no estuviera vacia para dar por hecho el congelado Y para instalar un
# `trap 'rm -rf "$WORK"'` sobre esa ruta: un invocador podia convertirlo en un borrado recursivo
# de un directorio ajeno. Se comprueban las DOS mitades: que aborte, y que NO borre. La segunda
# es la que importa — un rechazo que ya destruyo lo ajeno no es un rechazo.
#
# El directorio ajeno lleva un congelado PLAUSIBLE dentro. Sin eso, el rechazo lo producia otra
# cosa —no hay skill que medir, la huella falla, sale 2— y el control pasaba con la validacion
# QUITADA: verde por la razon equivocada, cazado mutando. Con una copia valida dentro, lo unico
# que puede rechazarla es la comprobacion de ubicacion, que es lo que se quiere medir.
# La recursion la corta la FORMA de la ruta, no una variable: un mutante que quite la
# validacion haria que el hijo corriese la suite entera, incluido ESTE control, sin fondo.
_ajeno="$(mktemp -d "$WORK/ajeno.XXXXXX")"; : > "$_ajeno/testigo"
cp -a "$SKILLROOT" "$_ajeno/skill" || {
  # Sin comprobar ESTE rc, una copia fallida daba igualmente rc=2 al invocar —por no
  # encontrar ubicacion valida— y el control pasaba sin haber probado nada (par14-p1, MAYOR).
  echo "  ✗ no pude preparar la caja del control del marcador: no se mide"; fail=$((fail+1));
  _ajeno=""; }
if [ -n "$_ajeno" ]; then
# El anidamiento se detecta por la FORMA de la ruta congelada —una caja `ajeno.*` creada por
# este mismo control—, no por una variable de entorno: la variable la podia poner el invocador y
# el control se daba por bueno con rc=2 SIN haber ejecutado la validacion (par15-p1, MAYOR). Y en
# la corrida anidada el control se OMITE, no se da por verde: un atajo que suma un PASS sin medir
# es justo el falso verde que este control existe para cazar.
# ESTE CONTROL NO SE OMITE NUNCA, Y POR ESO NO HAY NADA QUE FABRICAR (par17-p1, MAYOR).
# Hubo dos intentos de decidir «estoy anidado, me salto el control»: primero por la FORMA de la
# ruta congelada (`*/ajeno.*/skill`, falsificable con `TMPDIR=/tmp/ajeno.X`, par16-p1) y despues
# contando ANCESTROS cuyo `argv[1]` terminara en el nombre de este script — que un envoltorio
# benigno HOMONIMO tambien falsifica: la suite terminaba 204/0 con rc=0 y el control ausente,
# verde y sin haber medido (par17-p1). Afinar el detector no arregla la clase: **si el veredicto
# depende de algo que el sujeto controla, no mide**.
# La salida no es un detector mejor: es que la decision SOBRA. La sub-invocacion de este control
# lleva `TM_SELFTEST_CONGELADO` definida, asi que entra por la rama HIJA y aborta con rc=2 sin
# volver aqui — la recursion esta acotada a profundidad 1 POR CONSTRUCCION, no por una
# comprobacion. Se corre siempre, en cualquier contexto de invocacion, y el recuento no puede
# variar en silencio: ya no existe ninguna rama que no sume ni PASS ni FAIL.
TM_SELFTEST_CONGELADO="$_ajeno" \
  timeout 120 bash "$SKILLROOT/references/proc-m13.selftest.sh" "$@" >/dev/null 2>&1
_rc_marcador=$?
if [ "$_rc_marcador" -eq 2 ] && [ -f "$_ajeno/testigo" ]; then
  echo "  ✓ marcador de congelado AJENO: aborta (rc=2) y NO borra el directorio que no creo"
  pass=$((pass+1))
else
  echo "  ✗ marcador ajeno: rc=$_rc_marcador y el testigo quedo" \
       "$([ -f "$_ajeno/testigo" ] && echo intacto || echo BORRADO)"
  fail=$((fail+1))
fi
fi

# — LIMPIEZA PRE-CLAIM, OBSERVABLE (par10-p1, MAYOR: `INV-ME-207` solo exigia que apareciera el
#   identificador, asi que borrar la linea del trap dejaba los dos gates en verde). Aqui se
#   comprueba el EFECTO en las dos polaridades: una salida ANTERIOR al claim no deja temporales,
#   y un turno GANADO SI conserva su CLASS_FILE, que a partir de ahi es evidencia.
claim_box="$(mktemp -d "$WORK/claim.XXXXXX")"; claim_bin="$claim_box/bin"; mkdir -p "$claim_bin"
: > "$claim_box/flock.log"; : > "$claim_box/merge.calls"; sembrar_canon "$claim_box"
printf '#!/usr/bin/env bash\n[ "${1:-}" = pr ] && [ "${2:-}" = merge ] && echo MERGE >> "$MERGE_CALLS"\nexit 0\n' > "$claim_bin/gh"
chmod +x "$claim_bin/gh"
cerrar_doble_gh "$claim_bin/gh" || exit 1
pre_box="$(mktemp -d "$WORK/pre.XXXXXX")"; : > "$pre_box/flock.log"; sembrar_canon "$pre_box"
( cd "$pre_box" && FLOCK_FILE="$pre_box/flock.log" TM_FLOCK_CANONICO_TRUSTED="$pre_box/flock.log" ESTACION="NO-CANONICA" PR="42" \
    HEAD="deadbeef" TMPDIR="$pre_box" bash "$ACQ_RUN" ) >/dev/null 2>&1
n_pre="$(find "$pre_box" -maxdepth 1 -name 'tmp.*' | wc -l)"
if [ "$n_pre" -eq 0 ]; then
  echo "  ✓ salida PRE-claim (estacion no canonica): cero temporales en el TMPDIR del operador"
  pass=$((pass+1))
else
  echo "  ✗ salida PRE-claim dejo $n_pre temporal(es): la limpieza no cubre esa via"; fail=$((fail+1))
fi
( cd "$claim_box" && PATH="$claim_bin:$PATH" MERGE_CALLS="$claim_box/merge.calls" \
    FLOCK_FILE="$claim_box/flock.log" TM_FLOCK_CANONICO_TRUSTED="$claim_box/flock.log" ESTACION="M1" PR="42" HEAD="deadbeef" TMPDIR="$claim_box" \
    bash "$ACQ_RUN" ) >/dev/null 2>&1
n_post="$(find "$claim_box" -maxdepth 1 -name 'tmp.*' -not -name '*.log' | wc -l)"
if [ "$n_post" -ge 1 ]; then
  echo "  ✓ turno GANADO: el CLASS_FILE se CONSERVA (es evidencia, no scratch)"; pass=$((pass+1))
else
  echo "  ✗ turno ganado pero el CLASS_FILE se borro: la limpieza se pasa de frenada"; fail=$((fail+1))
fi

# — RECONCILIACIÓN tras el merge. Bajo `set -e`, un `gh pr merge` con rc != 0 mataba el shell
#   en esa línea y este bloque —su única razón de existir— no se ejecutaba nunca (par6-p1 B1).
recon_case() {  # $1=MERGE_RC $2=PR_VIEW_OUT $3=PR_VIEW_RC → imprime el rc de la receta
  local box bin rc; box="$(mktemp -d "$WORK/box.XXXXXX")"; bin="$box/bin"; mkdir -p "$bin"
  sembrar_canon "$box"
  : > "$box/flock.log"; : > "$box/merge.calls"; : > "$box/lock.calls"
  printf '#!/usr/bin/env bash\nif [ "${1:-}" = "pr" ] && [ "${2:-}" = "merge" ]; then echo MERGE >> "$MERGE_CALLS"; exit "${MERGE_RC:-0}"; fi\nif [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then printf "%%s\\n" "${PR_VIEW_OUT-}"; exit "${PR_VIEW_RC:-0}"; fi\nexit 0\n' > "$bin/gh"
  printf '#!/usr/bin/env bash\necho 00000000-0000-4000-8000-000000000007\n' > "$bin/uuidgen"
  printf '#!/usr/bin/env bash\nif [ "${1:-}" = "/proc/sys/kernel/random/uuid" ]; then echo 00000000-0000-4000-8000-000000000007; exit 0; fi\nexec /bin/cat "$@"\n' > "$bin/cat"
  # Mismo mock por ARGV que en `acq_case` (ronda 28): dos mocks distintos del mismo binario
  # es la divergencia que este bloque dice cerrar.
  printf '%s\n' '#!/usr/bin/env bash' 'echo CALL >> "$LOCK_CALLS"' \
    'case "${1:-}" in -*) case "${3:-}" in "") exit 0 ;; *) echo "flock-mock: forma no reconocida: $*" >&2; exit 99 ;; esac ;; esac' \
      'shift' '[ "$#" -gt 0 ] || exit 0' 'exec "$@"' \
    > "$bin/flock"
  chmod +x "$bin"/gh "$bin"/uuidgen "$bin"/flock
  cerrar_doble_gh "$bin/gh" || exit 1
  # TMPDIR del box: el `mktemp` de la receta crea su CLASS_FILE DENTRO del sandbox, no en /tmp.
  ( cd "$box" && PATH="$bin:$PATH" MERGE_CALLS="$box/merge.calls" LOCK_CALLS="$box/lock.calls" \
FLOCK_FILE="$box/flock.log" TM_FLOCK_CANONICO_TRUSTED="$box/flock.log" ESTACION="M1" PR="42" HEAD="deadbeef" TMPDIR="$box" \
      MERGE_RC="$1" PR_VIEW_OUT="$2" PR_VIEW_RC="$3" bash "$ACQ_RUN" ) >/dev/null 2>&1
  rc=$?
  # No basta el codigo de salida: se comprueba que el CIERRE se PUBLICO en el flock. Escribir
  # la clase no equivale a publicar el cierre — sin APPLY-FAILED el APPLY-RUN queda abierto y
  # la flota ve el gate ocupado hasta el timeout de estacion muerta (par7-p1 BLOQUEANTE).
  # `grep -c` imprime 0 Y devuelve rc=1 cuando no hay coincidencias: el `|| echo 0` anadia un
  # SEGUNDO cero y la comparacion se hacia contra una cadena de dos lineas.
  local nf; nf="$(grep -c "^# APPLY-FAILED " "$box/flock.log" 2>/dev/null)"; nf="${nf:-0}"
  echo "$rc $nf"
}
recon_ck() { local got; got="$(recon_case "$2" "$3" "$4")"
  if [ "$got" = "$5" ]; then echo "  ✓ $1 → rc=$got"; pass=$((pass+1))
  else echo "  ✗ $1 → rc=$got (esperado $5)"; fail=$((fail+1)); fi; }
recon_ck "merge rc=0 y PR MERGED: turno conservado, NO se cierra" \
         0 "MERGED 2026-01-01T00:00:00Z" 0 "0 0"
recon_ck "merge rc!=0 pero GitHub SÍ mergeó: se reconcilia y NO se cierra el turno" \
         1 "MERGED 2026-01-01T00:00:00Z" 0 "0 0"
recon_ck "no-mergeado CONFIRMADO: se PUBLICA el APPLY-FAILED que libera el turno" \
         1 "OPEN null" 0 "1 1"
recon_ck "merge rc=0 pero PR OPEN: combinacion CONTRADICTORIA es INDETERMINADO" \
         0 "OPEN null" 0 "4 0"
recon_ck "estado INDETERMINADO (vista ilegible): fail-closed, NO se libera la reserva" \
         1 "" 1 "4 0"

# — FUGA DEL CLASS_FILE CUANDO EL CIERRE FALLA (ronda 28, MAYOR — hallazgo de revision externa).
#   El hallazgo ES el camino de FALLO: un ratchet mas la via de exito deja sin testigo justo el
#   brazo que se denuncia. Aqui el fallo se STUBEA en la dependencia —igual que `curl`/`git`/`gh`—:
#   el mock de `flock` hace fallar el APPEND del cierre (la invocacion que lleva `printf`) y deja
#   pasar la guarda, asi que `publish_close` agota sus cinco intentos y devuelve 1 DE VERDAD. Con
#   `CLAIM_GANADO=1` el trap de salida ya esta desarmado: si el wrapper no limpia por su propia via,
#   el temporal se queda. Dos brazos, porque «no limpiar nunca» y «limpiar siempre» pasan uno solo.
fuga_case() {  # $1 = normal|publish_fail  ->  "rc nleft"
  local box bin rc; box="$(mktemp -d "$WORK/fuga.XXXXXX")"; bin="$box/bin"; mkdir -p "$bin"
  sembrar_canon "$box"
  : > "$box/flock.log"; : > "$box/merge.calls"; : > "$box/lock.calls"
  printf '#!/usr/bin/env bash\nif [ "${1:-}" = "pr" ] && [ "${2:-}" = "merge" ]; then echo MERGE >> "$MERGE_CALLS"; exit 1; fi\nif [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then printf "%%s\\n" "OPEN null"; exit 0; fi\nexit 0\n' > "$bin/gh"
  printf '#!/usr/bin/env bash\necho 00000000-0000-4000-8000-000000000007\n' > "$bin/uuidgen"
  printf '#!/usr/bin/env bash\nif [ "${1:-}" = "/proc/sys/kernel/random/uuid" ]; then echo 00000000-0000-4000-8000-000000000007; exit 0; fi\nexec /bin/cat "$@"\n' > "$bin/cat"
  if [ "$1" = "publish_fail" ]; then
    printf '%s\n' '#!/usr/bin/env bash' 'echo CALL >> "$LOCK_CALLS"' \
      'case "${1:-}" in -*) case "${3:-}" in "") exit 0 ;; *) exit 99 ;; esac ;; esac' \
      'shift' '[ "$#" -gt 0 ] || exit 0' \
      'case "$*" in *printf*) exit 1 ;; esac' 'exec "$@"' > "$bin/flock"
  else
    printf '%s\n' '#!/usr/bin/env bash' 'echo CALL >> "$LOCK_CALLS"' \
      'case "${1:-}" in -*) case "${3:-}" in "") exit 0 ;; *) exit 99 ;; esac ;; esac' \
      'shift' '[ "$#" -gt 0 ] || exit 0' 'exec "$@"' > "$bin/flock"
  fi
  chmod +x "$bin"/gh "$bin"/uuidgen "$bin"/cat "$bin"/flock
  cerrar_doble_gh "$bin/gh" || exit 1
  ( cd "$box" && PATH="$bin:$PATH" MERGE_CALLS="$box/merge.calls" LOCK_CALLS="$box/lock.calls" \
      FLOCK_FILE="$box/flock.log" TM_FLOCK_CANONICO_TRUSTED="$box/flock.log" ESTACION="M1" PR="42" HEAD="deadbeef" TMPDIR="$box" \
      bash "$ACQ_RUN" ) >/dev/null 2>&1
  rc=$?
  # MISMO conteo que la limpieza PRE-claim: el `.log` que abre el wrapper no es el CLASS_FILE.
  echo "$rc $(find "$box" -maxdepth 1 -name 'tmp.*' -not -name '*.log' | wc -l)"
}
fuga_ck() { local got; got="$(fuga_case "$2")"
  if [ "$got" = "$3" ]; then echo "  ✓ $1 → rc/nleft=$got"; pass=$((pass+1))
  else echo "  ✗ $1 → rc/nleft=$got (esperado $3)"; fail=$((fail+1)); fi; }
echo "== T25: la CADENA DE SUCESIÓN del slot se acredita EJECUTÁNDOLA (dos takeovers)."
echo "   Antes tenía CERO cobertura ejecutable: la protegían invariantes de presencia de texto,"
echo "   que no distinguen una doctrina bien escrita de una mal implementada =="
# shellcheck source=apply-gate.sh
. "$SKILLROOT/references/apply-gate.sh"
N1=11111111-1111-1111-1111-111111111111
N2=22222222-2222-2222-2222-222222222222
N3=33333333-3333-3333-3333-333333333333
NX=99999999-9999-9999-9999-999999999999
tk() { printf '# SLOT-CLAIM-TAKEOVER 42 = #7 [%s] 2026-01-01T00:00:00Z %s (supersede %s %s)\n' "$1" "$2" "$3" "$4"; }
cadena() { local f; f="$(mktemp "$WORK/chain.XXXXXX")"
  printf '# SLOT-CLAIM 42 = #7 [M1] 2026-01-01T00:00:00Z %s (x.sql)\n' "$N1" > "$f"
  # Cada eslabón en su PROPIA línea: `$(...)` se come el salto final, así que pasarlos
  # concatenados los pegaba en una sola y la cadena dejaba de existir como cadena.
  [ "$#" -gt 0 ] && printf '%s\n' "$@" >> "$f"
  printf '%s\n' "$f"; }
tv_ck() { local d f got; d="$1"; local esp="$2"; shift 2; f="$(cadena "$@")"; got="$(titular_vigente "$f" 42)"
  if [ "$got" = "$esp" ]; then echo "  ✓ $d → $got"; pass=$((pass+1))
  else echo "  ✗ $d → '$got' (esperado '$esp')"; fail=$((fail+1)); fi; }

tv_ck "sin takeover: la titular es la del SLOT-CLAIM"        "M1 $N1"
tv_ck "UN takeover legítimo cita la generación vigente"      "M2 $N2" "$(tk M2 "$N2" M1 "$N1")"
# CADA CASO MATA UNA INGENUIDAD DISTINTA, y conviene no confundirlas (corrección del par de la
# ronda 7): contra un resolvedor PERMISIVO —que acepta cualquier cita— «UN takeover», «DOS
# encadenados» y «tras DOS relevos» pasan LOS TRES igual, así que el encadenado NO es el
# discriminante de la permisividad. Quien discrimina eso son las dos variantes VOID. El
# encadenado sigue haciendo falta porque mata OTRA ingenuidad: «gana el primer takeover y ya».
# Contarlo como el discriminante sería contar cobertura donde no la hay.
tv_ck "DOS encadenados (mata: «gana el primero y ya»)"       "M3 $N3" "$(tk M2 "$N2" M1 "$N1")" "$(tk M3 "$N3" M2 "$N2")"
tv_ck "cita al ORIGINAL superado → VOID (mata: permisivo)"   "M2 $N2" "$(tk M2 "$N2" M1 "$N1")" "$(tk M3 "$N3" M1 "$N1")"
tv_ck "dos sobre la MISMA muerte → 1.º (mata: permisivo)"    "M2 $N2" "$(tk M2 "$N2" M1 "$N1")" "$(tk M4 "$NX" M1 "$N1")"
tv_ck "nonce inexistente → descartado (mata: permisivo)"     "M1 $N1" "$(tk M2 "$NX" M1 "$N3")"
# DRAIN-DISJOINT: ref 01 («Transferencia del CLAIM») es explícita en que el takeover mueve el
# `CLAIM #<PR>` en el MISMO acto y SIN publicar un `CLAIM` aparte — «nunca esperando un CLAIM
# explícito adicional que este protocolo no exige». Por eso el titular del CLAIM tras DOS relevos
# no se lee de un token nuevo: se RESUELVE por la cadena. Este caso fija esa lectura, que es la
# que impide que un tercero se cuele por creer que el CLAIM sigue en la estación muerta.
tv_ck "tras DOS relevos el CLAIM es del ÚLTIMO, resuelto por cadena" "M3 $N3" "$(tk M2 "$N2" M1 "$N1")" "$(tk M3 "$N3" M2 "$N2")"

echo "-- T24f (ronda 28 MAYOR): el CLASS_FILE no se fuga cuando el cierre FALLA --"
fuga_ck "cierre AGOTADO (publish_close devuelve 1): escala rc=4 y NO deja temporal" \
        publish_fail "4 0"
fuga_ck "control — cierre PUBLICADO (publish_close devuelve 0): rc=1 y tampoco deja temporal" \
        normal "1 0"

# — EXCLUSIÓN REAL, no invocación: dos intentos CONCURRENTES con el gate LIBRE y flock de
#   verdad. Que el lock se invoque no prueba que excluya (par3-p1 M6). Exactamente UN ganador.
excl_box="$(mktemp -d "$WORK/excl.XXXXXX")"; excl_bin="$excl_box/bin"; mkdir -p "$excl_bin"
sembrar_canon "$excl_box"
: > "$excl_box/flock.log"; : > "$excl_box/merge.calls"
cat > "$excl_bin/gh" <<'GH2'
#!/usr/bin/env bash
[ "${1:-}" = "pr" ] && [ "${2:-}" = "merge" ] && echo MERGE >> "$MERGE_CALLS"
exit 0
GH2
cat > "$excl_bin/uuidgen" <<'UU'
#!/usr/bin/env bash
printf '%08x-1111-2222-3333-444444444444\n' "$$"
UU
chmod +x "$excl_bin/gh" "$excl_bin/uuidgen"
cerrar_doble_gh "$excl_bin/gh" || exit 1
for _i in 1 2 3 4; do
  ( cd "$excl_box" && PATH="$excl_bin:$PATH" MERGE_CALLS="$excl_box/merge.calls" \
FLOCK_FILE="$excl_box/flock.log" TM_FLOCK_CANONICO_TRUSTED="$excl_box/flock.log" ESTACION="M1" PR="42" HEAD="deadbeef" TMPDIR="$excl_box" \
      bash "$ACQ_RUN" ) >/dev/null 2>&1 &
done
wait
# Mismo defecto que ya se corrigió arriba, superviviente aquí: `grep -c` imprime 0 Y devuelve
# rc=1 sin coincidencias, así que el `|| echo 0` añadía un SEGUNDO cero y la comparación se
# hacía contra una cadena de DOS líneas — que no es un entero, así que el `[ -eq ]` moría con
# «integer expression expected» y caía al else por la razón equivocada: rojo correcto, causa
# falsa. Un control que acierta por el motivo que no es, no mide.
n_ganadores="$(grep -c . "$excl_box/merge.calls" 2>/dev/null)"; n_ganadores="${n_ganadores:-0}"
if [ "$n_ganadores" -eq 1 ]; then
  echo "  ✓ 4 intentos concurrentes con flock REAL y gate libre: exactamente 1 ganador"
  pass=$((pass+1))
else
  echo "  ✗ exclusión rota: $n_ganadores ganadores de 4 intentos concurrentes (se exige 1)"
  fail=$((fail+1))
fi
# Chequeo del MODO declarado del lock. Se etiqueta como lo que es —TEXTUAL, no una prueba de
# exclusión— porque el test de arriba NO distingue `-x` de `-s`: la exclusión de este algoritmo
# la da el ORDEN en el fichero (gana el primer RUN) más la atomicidad del append, no el modo del
# lock; con `-s` sigue habiendo un solo ganador. `-x` es defensa en profundidad contra lecturas
# rasgadas, y esta línea impide que se degrade en silencio.
if grep -q 'flock -x 9' "$ACQ"; then
  echo "  ✓ [textual, no prueba de exclusión] la receta pide lock EXCLUSIVO (-x), no compartido"
  pass=$((pass+1))
else
  echo "  ✗ la receta ya no pide lock exclusivo (-x): degradación silenciosa del modo"
  fail=$((fail+1))
fi

# El marcador de T23 solo es legítimo si SOLO lo lleva la receta que T24 ejecuta de verdad.
# Sin esto, copiar el marcador a otra receta la daría por acreditada sin haberla probado.
# Se cuentan OCURRENCIAS, no ficheros: `grep -rl | wc -l` contaba ficheros, así que un SEGUNDO
# fence inseguro dentro del MISMO fichero se apropiaba de la acreditación ajena (par2-p1 M4).
# Y la única ocurrencia tiene que estar DENTRO del fence que T24 extrae y ejecuta.
n_ocurrencias="$(grep -rhoF 'ADQUISICIÓN VERIFICADA POR EJECUCIÓN' \
  "$SKILLROOT"/SKILL.md "$SKILLROOT"/references/*.md 2>/dev/null | wc -l)"
# Tercer superviviente de la MISMA clase (los otros dos ya corregidos arriba, lineas ~1300 y
# ~1343): `grep -c` imprime `0` Y devuelve rc=1 cuando no hay coincidencias, asi que el
# `|| echo 0` APENDIZABA un segundo cero y dejaba la variable en "0\n0" — una cadena de dos
# lineas que `[ -eq ]` no puede comparar (aborta con «integer expression expected») y que el
# diagnostico del else imprimia partida. El fallback se aplica a la VARIABLE, no a la salida:
# el valor sigue siendo UN solo numero. Misma forma que las otras dos reparaciones, a proposito
# — una tercera forma distinta para el mismo defecto es una cuarta oportunidad de divergir.
n_en_fence="$(grep -coF 'ADQUISICIÓN VERIFICADA POR EJECUCIÓN' "$ACQ" 2>/dev/null)"; n_en_fence="${n_en_fence:-0}"
if [ "$n_ocurrencias" -eq 1 ] && [ "$n_en_fence" -eq 1 ]; then
  echo "  ✓ el marcador aparece UNA sola vez en todo el skill, y dentro del fence que T24 ejecuta"
  pass=$((pass+1))
else
  echo "  ✗ marcador: $n_ocurrencias ocurrencia(s) en el skill, $n_en_fence dentro del fence ejecutado (se exige 1 y 1)"
  fail=$((fail+1))
fi

# Se cuenta la FORMA de la clase de estación (`[[]M[`), no un literal concreto: contar `M[1-5]`
# dejaba pasar un duplicado escrito como `M[1-9]`, que es exactamente la divergencia a cazar.
# La forma cambió en T05 v10: la ERE canónica dejó de usar `\[`/`\]` porque viaja al `awk` por
# `-v` y `busybox awk` BORRA los backslashes. Este contador sigue a la forma vigente; que haya
# tenido que moverse con ella es la prueba de que cuenta la FORMA y no un literal cualquiera.
n_inline="$(grep -o '\[\[\]M\[' "$ACQ" | wc -l)"
if [ "$n_inline" -eq 1 ]; then
  echo "  ✓ la forma del token se define UNA sola vez (sin ERE inline duplicadas)"; pass=$((pass+1))
else
  echo "  ✗ $n_inline definiciones de la forma del token en el fence (se exige 1: la compartida)"; fail=$((fail+1))
fi


# ─────────────────────────────────────────────────────────────────────────────────────────────
# T26 · T27 · T28 — ORÁCULOS DE LA 6.ª RONDA (escritos por la estación de merge, no por el canal).
#
# Ley de la 5.ª ronda: al 5.º rebote sobre el mismo fix, el oráculo lo escribe quien revisa y la
# condición la escribe el canal. Estos tres bloques FIJAN EL CONTRATO en código ejecutable; están
# ROJOS a propósito sobre este árbol y es el arreglo lo que tiene que ponerlos verdes. Cada uno
# lleva sus controles: un rojo que no discrimina no mide, y un verde que pasa por ausencia tampoco.
# ─────────────────────────────────────────────────────────────────────────────────────────────

echo "== T26: la cadena CLAIM -> TAKEOVER se ACREDITA EN EL INTAKE, no solo en un resolvedor suelto."
echo "   titular_vigente() existe, tiene sus siete casos en T25 y NADIE LA LLAMA: ninguna receta ni"
echo "   gate la consulta. Un resolvedor que no gobierna ninguna admisión no gobierna nada =="
# CONTRATO QUE SE EXIGE (lo escribe el canal, aquí solo se mide) — RE-ANCLADO CLASE 2 v22, ronda
# 36, ADDENDUM: la forma de esta prosa ERA `intake_slot <flock> <estacion>` (dos argumentos) hasta
# que un auditor señaló que un fixture/comentario que bendice la forma insegura es PEOR que no
# tenerlo — convierte el defecto en requisito. El contrato real, hoy, es de TRES argumentos:
#   intake_slot <ruta-al-flock> <estacion> <slot>   ->  rc 0 ADMITIDA · rc 1 RECHAZADA
#   (rc 3 = llamada mal formada si se OMITE <slot> O es vacío/sólo-espacios/no-numérico — ver
#    apply-gate.sh, CLASE 2 v23/B-01: el slot es OBLIGATORIO y NUMÉRICO, ya NO existe modo sin filtro)
#   y RESUELVE por `titular_vigente` — no reimplementa la cadena por segunda vez (INV-ME-276:
#   implementación EJECUTABLE ÚNICA; dos copias de una regla divergen, ya pasó en la ronda 25).
# Este bloque usa el slot REAL (42, fijo en `cadena()`) — la forma sin filtro se RETIRÓ en B-01 —
# porque ya no hace falta relajar nada para medir una cadena de un único slot.
#
# LO QUE ESTE BLOQUE NO LEGISLA, dicho para que nadie lo dé por decidido: el flock SIN cadena.
# `titular_vigente` documenta que salida vacía es «sin cadena» y que decide el llamador; el ruling
# pedía distinguir takeover VIGENTE de OBSOLETO/DUPLICADO, y eso es lo único que se fija aquí.
tk_ck() {  # $1 = descripción · $2 = estación · $3 = ADMITIDA|RECHAZADA · $4.. = eslabones
  local d="$2" esp="$3" f got rc; local desc="$1"; shift 3
  f="$(cadena "$@")"
  intake_slot "$f" "$d" 42 >/dev/null 2>&1; rc=$?
  case "$rc" in 0) got=ADMITIDA ;; 1) got=RECHAZADA ;; *) got="rc=$rc (fuera de contrato)" ;; esac
  if [ "$got" = "$esp" ]; then echo "  ✓ $desc -> $got"; pass=$((pass+1))
  else echo "  ✗ $desc -> $got (esperado $esp)"; fail=$((fail+1)); fi
}
if [ "$(type -t intake_slot 2>/dev/null || true)" != "function" ]; then
  # Sin la función no se puede medir NADA: se declara el hueco una vez, con su nombre, y no se
  # simula una corrida. Llamar a un `command not found` habría dado rc 127 y seis rojos por la
  # razón equivocada — un rojo por crash no es un rojo por detección.
  echo "  ✗ apply-gate.sh no define intake_slot(): la cadena de sucesión no gobierna NINGUNA"
  echo "    admisión. T25 acredita el resolvedor; nadie acredita que el intake lo consulte."
  fail=$((fail+1))
else
  tk_ck "sin takeover, la titular del CLAIM opera"            M1 ADMITIDA
  # EL CASO QUE MUERDE: tras un relevo legítimo, la estación SUPERSEDIDA no puede seguir operando.
  tk_ck "tras relevo legítimo, la NUEVA opera"                M2 ADMITIDA  "$(tk M2 "$N2" M1 "$N1")"
  tk_ck "tras relevo legítimo, la SUPERSEDIDA ya NO opera"    M1 RECHAZADA "$(tk M2 "$N2" M1 "$N1")"
  # DUPLICADO sobre la misma muerte: gana el primero, el segundo es VOID y no admite a nadie.
  tk_ck "duplicado sobre la MISMA muerte: el 2.º es VOID"     M4 RECHAZADA \
        "$(tk M2 "$N2" M1 "$N1")" "$(tk M4 "$NX" M1 "$N1")"
  tk_ck "y el 1.º de ese duplicado sí opera (control)"        M2 ADMITIDA \
        "$(tk M2 "$N2" M1 "$N1")" "$(tk M4 "$NX" M1 "$N1")"
  # OBSOLETO: citar un nonce inexistente no relega a la titular ni promueve al que cita.
  tk_ck "takeover con nonce inexistente: no admite"           M2 RECHAZADA "$(tk M2 "$NX" M1 "$N3")"
  tk_ck "y la titular original sigue operando (control)"      M1 ADMITIDA  "$(tk M2 "$NX" M1 "$N3")"
  # Y que resuelva POR la cadena, no por una segunda copia de la regla.
  if declare -f intake_slot | grep -q 'titular_vigente'; then
    echo "  ✓ intake_slot resuelve por titular_vigente (una sola implementación de la cadena)"
    pass=$((pass+1))
  else
    echo "  ✗ intake_slot NO consulta titular_vigente: segunda implementación de la cadena"
    fail=$((fail+1))
  fi
fi

echo "== T29 (ronda 34, CLASE 2 — BLOQUEANTE, CR sobre v19): un flock compartido lleva VARIOS slots"
echo "   a la vez, y T25/T26 solo construían UNA cadena para el slot 42 — fixture cómodo que no"
echo "   discriminaba multiples slots. Aquí el claim HISTÓRICO va A LA IZQUIERDA, en la posición"
echo "   donde el arreglo incomoda =="
# Flock compartido: slot 100 (M1, histórico, a la izquierda) y slot 101 (disputado). El nonce del
# slot 100 NUNCA debe decidir nada sobre el slot 101 — son cadenas independientes.
multi_flock() {  # $@ = líneas SLOT-CLAIM/-TAKEOVER adicionales, tras el histórico del slot 100
  local f; f="$(mktemp "$WORK/multi.XXXXXX")"
  printf '# SLOT-CLAIM 100 = #5 [M1] 2026-09-09T19:00:00Z 11111111-1111-1111-1111-111111111111 (100_ok.sql)\n' > "$f"
  [ "$#" -gt 0 ] && printf '%s\n' "$@" >> "$f"
  printf '%s\n' "$f"
}
_101claim() { printf '# SLOT-CLAIM 101 = #6 [M2] 2026-09-09T19:30:00Z 22222222-2222-2222-2222-222222222222 (101_ok.sql)\n'; }
_101tk()    { printf '# SLOT-CLAIM-TAKEOVER 101 = #6 [M3] 2026-09-09T19:31:00Z 33333333-3333-3333-3333-333333333333 (supersede M2 22222222-2222-2222-2222-222222222222)\n'; }

echo "-- titular_vigente(slot) NO deja que el histórico del 100 decida el 101 --"
f="$(multi_flock "$(_101claim)")"
got="$(titular_vigente "$f" 100)"; [ "$got" = "M1 11111111-1111-1111-1111-111111111111" ] \
  && { echo "  ✓ filtrado por 100 -> $got (el 101 no interfiere)"; pass=$((pass+1)); } \
  || { echo "  ✗ filtrado por 100 -> '$got' (esperado 'M1 …')"; fail=$((fail+1)); }
got="$(titular_vigente "$f" 101)"; [ "$got" = "M2 22222222-2222-2222-2222-222222222222" ] \
  && { echo "  ✓ filtrado por 101 -> $got (el histórico del 100 no interfiere)"; pass=$((pass+1)); } \
  || { echo "  ✗ filtrado por 101 -> '$got' (esperado 'M2 …')"; fail=$((fail+1)); }

echo "-- B-01 (CLASE 2 v23): el slot vacío YA NO recorre sin filtro — la guarda lo RECHAZA con rc 3 --"
rc=0; titular_vigente "$f" "" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] \
  && { echo "  ✓ titular_vigente(f,\"\") -> rc 3 LLAMADA MAL FORMADA (contar argumentos no es filtrar; el slot vacío ya no abre el recorrido sin filtro)"; pass=$((pass+1)); } \
  || { echo "  ✗ titular_vigente(f,\"\") -> rc=$rc (esperado 3: el hueco de B-01 sigue abierto)"; fail=$((fail+1)); }
echo "-- MUTANTE (fichero, revierte B-01: guarda numérica fuera + no-filtro restaurado): con \$slot vacío el 100 histórico SÍ decide el 101 -- CAZADO"
_b01_mut="$WORK/apply-gate-b01-mutante.sh"
sed -e '/slot vacío\/no-numérico/d' \
    -e 's/\[ "$cand_slot" = "$slot" \] || continue/[ -z "$slot" ] || [ "$cand_slot" = "$slot" ] || continue/' \
    "$GATE_LIB" > "$_b01_mut"
got="$(bash -c 'source "$1"; titular_vigente "$2" ""' _ "$_b01_mut" "$f")"
rm -f "$_b01_mut"
[ "$got" = "M1 11111111-1111-1111-1111-111111111111" ] \
  && { echo "  ✓ CONTROL mutante: sin la guarda y con el no-filtro restaurado, el histórico del 100 gana la cadena entera (reproduce el defecto — confirma que guarda+filtro es lo que lo cierra)"; pass=$((pass+1)); } \
  || { echo "  ✗ CONTROL mutante: no reprodujo el defecto conocido ('$got') — el fixture no discrimina"; fail=$((fail+1)); }

echo "-- FALSO RECHAZO (medido por el CR): M2 reclama el 101 con el 100 histórico a la izquierda --"
f="$(multi_flock)"
rc=0; intake_slot "$f" M2 101 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] \
  && { echo "  ✓ intake_slot(f,M2,101) sobre flock SIN claim del 101 -> RECHAZADA (sin cadena, fail-closed: hay que abrir el SLOT-CLAIM primero, no hay «libre → adelante»)"; pass=$((pass+1)); } \
  || { echo "  ✗ intake_slot(f,M2,101) -> rc=$rc (esperado 1: sin SLOT-CLAIM del 101 no hay chain que admita)"; fail=$((fail+1)); }
f="$(multi_flock "$(_101claim)")"
rc=0; intake_slot "$f" M2 101 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] \
  && { echo "  ✓ intake_slot(f,M2,101) tras publicar su SLOT-CLAIM -> ADMITIDA, el histórico del 100 NO la rechaza"; pass=$((pass+1)); } \
  || { echo "  ✗ intake_slot(f,M2,101) -> rc=$rc (esperado 0: FALSO RECHAZO — el defecto que el CR midió)"; fail=$((fail+1)); }

echo "-- FALSA ADMISIÓN (medido por el CR): M1 (dueño del 100) NO hereda el 101 ya ganado por M2 --"
f="$(multi_flock "$(_101claim)")"
rc=0; intake_slot "$f" M1 101 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] \
  && { echo "  ✓ intake_slot(f,M1,101) -> RECHAZADA: el 101 es de M2, figurar en el 100 no admite en otro slot"; pass=$((pass+1)); } \
  || { echo "  ✗ intake_slot(f,M1,101) -> rc=$rc (esperado 1: FALSA ADMISIÓN — el defecto que el CR midió)"; fail=$((fail+1)); }

echo "-- TAKEOVER también respeta el slot: relevo en el 101 no mueve la titularidad del 100 --"
f="$(multi_flock "$(_101claim)" "$(_101tk)")"
got="$(titular_vigente "$f" 100)"; [ "$got" = "M1 11111111-1111-1111-1111-111111111111" ] \
  && { echo "  ✓ el relevo del 101 (M2->M3) no toca el 100 -> sigue M1"; pass=$((pass+1)); } \
  || { echo "  ✗ el 100 cambió tras un relevo AJENO en el 101 -> '$got'"; fail=$((fail+1)); }
got="$(titular_vigente "$f" 101)"; [ "$got" = "M3 33333333-3333-3333-3333-333333333333" ] \
  && { echo "  ✓ el 101 resuelve el relevo correctamente (M3, filtrado, sin ruido del 100)"; pass=$((pass+1)); } \
  || { echo "  ✗ el 101 tras el relevo -> '$got' (esperado M3 …)"; fail=$((fail+1)); }

echo "-- CLASE 1 + multi-slot: una línea con estación FORJADA en el 100 no contamina el 101 --"
f="$(multi_flock "# SLOT-CLAIM 101 = #6 [M9] 2026-09-09T19:30:00Z 22222222-2222-2222-2222-222222222222 (101_ok.sql)")"
rc=0; intake_slot "$f" M2 101 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] \
  && { echo "  ✓ M9 forjada no abre la cadena del 101: nadie la hereda (rc=1, sin cadena válida)"; pass=$((pass+1)); } \
  || { echo "  ✗ M9 forjada en el 101 -> rc=$rc (esperado 1: la forma inválida no debe admitir a nadie)"; fail=$((fail+1)); }

# RETIRADO (CLASE 2 v22, ronda 36, ADDENDUM; AMPLIADO CLASE 2 v23, ronda 37, B-01): este bloque
# medía "intake_slot SIN slot admite en una cadena de un único slot" y lo protegía como REGRESIÓN
# si dejaba de admitir — convertía la forma insegura en un requisito PERMANENTE de la suite. Un
# auditor lo señaló con nombre: "un fixture que bendice la forma equivocada es peor que no tenerlo:
# convierte el defecto en requisito". T25 (`tv_ck`) y T26 (`tk_ck`) ya NO usan la forma sin slot
# —pasan el slot real, 42, fijo en `cadena()`—. En v23, B-01 fue MÁS ALLÁ: el «modo sin filtro
# declarando `""` explícito» era en sí la ESCAPATORIA que el llamador controla, así que se RETIRA
# del código (no sólo su protección en la suite): el slot es obligatorio y numérico, y `""` es
# rc 3 «LLAMADA MAL FORMADA», no un modo válido. Ver el bloque B-01 de T34, más abajo.

echo "== T30 (ronda 35, CLASE 1 — BLOQUEANTE x2, dos pasadas independientes convergentes sobre v20):"
echo "   titular_vigente solo acreditaba estación+nonce — lo que la ESCRITURA rechaza, la LECTURA"
echo "   lo admitía como autoridad. Siete fixtures donde el arreglo INCOMODA, más el MUTANTE que"
echo "   reproduce el comportamiento viejo para acreditar que el arreglo es lo que las cierra =="
# MUTANTE embebido: la forma de titular_vigente ANTES de esta ronda — valida SOLO [estación] y
# nonce (como el `apply-gate.sh` de v20), sin identidad_slot_valida completa, sin round-trip y
# SIN `local LC_ALL=C`. Vive aquí, no en apply-gate.sh: es la calibración de que T30 discrimina,
# no una segunda implementación en producción.
_t30_titular_vieja() {
  local f="$1" slot="${2:-}" est="" nonce="" line lslot cand_est cand_nonce
  [ -f "$f" ] || return 2
  exec 9< "$f" || return 2
  while IFS= read -r line <&9 || [ -n "$line" ]; do
    case "$line" in
      '# SLOT-CLAIM '*)
        [ -n "$nonce" ] && continue
        lslot="$(printf '%s\n' "$line" | awk '{print $3}')"
        [ -z "$slot" ] || [ "$lslot" = "$slot" ] || continue
        cand_est="$(printf '%s\n' "$line" | sed -n 's/.*\[\([^]]*\)\].*/\1/p')"
        cand_nonce="$(printf '%s\n' "$line" | awk '{print $(NF-1)}')"
        [[ "[$cand_est]" =~ $TM_RE_EST ]] && [[ "$cand_nonce" =~ $TM_RE_NONCE ]] || continue
        est="$cand_est"; nonce="$cand_nonce"
        ;;
    esac
  done
  exec 9<&-
  if [ -n "$nonce" ]; then printf '%s %s\n' "$est" "$nonce"; fi
  return 0
}
t30_flock() { local f; f="$(mktemp "$WORK/t30.XXXXXX")"; printf '%s\n' "$1" > "$f"; printf '%s\n' "$f"; }
t30_check() {  # $1=nombre-attack $2=linea-attack
  local f got_real got_vieja
  f="$(t30_flock "$2")"
  got_real="$(titular_vigente "$f" 101)"
  got_vieja="$(_t30_titular_vieja "$f" 101)"
  if [ -z "$got_real" ] && [ -n "$got_vieja" ]; then
    echo "  ✓ $1: real RECHAZA (vacío) — la vieja admitía ('$got_vieja') — el arreglo es lo que cierra esto"; pass=$((pass+1))
  elif [ -z "$got_real" ] && [ -z "$got_vieja" ]; then
    echo "  ✗ $1: real rechaza pero la vieja TAMBIÉN — este fixture no discrimina, no acredita el arreglo"; fail=$((fail+1))
  else
    echo "  ✗ $1: real ADMITIÓ ('$got_real') — el ataque medido por las dos pasadas sigue entrando"; fail=$((fail+1))
  fi
}
t30_check "PR=0" '# SLOT-CLAIM 101 = #0 [M2] 2026-09-09T19:30:00Z 22222222-2222-2222-2222-222222222222 (101_ok.sql)'
t30_check "ISO no-ISO" '# SLOT-CLAIM 101 = #6 [M2] no-es-una-fecha 22222222-2222-2222-2222-222222222222 (101_ok.sql)'
t30_check "ARCHIVO vacío" '# SLOT-CLAIM 101 = #6 [M2] 2026-09-09T19:30:00Z 22222222-2222-2222-2222-222222222222 ()'
t30_check "ARCHIVO unicode (locale)" '# SLOT-CLAIM 101 = #6 [M2] 2026-09-09T19:30:00Z 22222222-2222-2222-2222-222222222222 (archívo.sql)'
printf -v _t30_bs '# SLOT-CLAIM 101 = #6 [M2] 2026-09-09T19:30:00Z 22222222-2222-2222-2222-222222222222 (a\\b.sql)'
t30_check "ARCHIVO con barra invertida" "$_t30_bs"
printf -v _t30_cr '# SLOT-CLAIM 101 = #6 [M2] 2026-09-09T19:30:00Z 22222222-2222-2222-2222-222222222222 (a\rb.sql)'
t30_check "ARCHIVO con CR embebido" "$_t30_cr"
t30_check "doble espacio antes del slot" '# SLOT-CLAIM  101 = #6 [M2] 2026-09-09T19:30:00Z 22222222-2222-2222-2222-222222222222 (101_ok.sql)'

echo "-- CONTROL: una línea canónica de verdad sigue admitiendo (el arreglo no es una mordaza) --"
f="$(t30_flock '# SLOT-CLAIM 101 = #6 [M2] 2026-09-09T19:30:00Z 22222222-2222-2222-2222-222222222222 (101_ok.sql)')"
got="$(titular_vigente "$f" 101)"
[ "$got" = "M2 22222222-2222-2222-2222-222222222222" ] \
  && { echo "  ✓ línea canónica -> $got"; pass=$((pass+1)); } \
  || { echo "  ✗ línea canónica -> '$got' (esperado 'M2 …' — el arreglo rechaza de más)"; fail=$((fail+1)); }

echo "== T31 (ronda 35, CLASE 2 — BLOQUEANTE x2, dos pasadas independientes convergentes sobre v20):"
echo "   el automata solo conocía SLOT-CLAIM/-TAKEOVER; MERGED/BOUNCED/CEO RESUELTO —terminales YA"
echo "   declarados por la doctrina (ref 01 §2)— se ignoraban: el claim viejo seguía gobernando y"
echo "   un SLOT-CLAIM nuevo sobre el slot reutilizado se descartaba. MUTANTE embebido: el automata"
echo "   SIN el brazo de terminales, para acreditar que el arreglo es lo que cierra esto =="
# MUTANTE: titular_vigente tal como quedó tras CLASE 1 de esta misma ronda, SIN el brazo de
# terminales — vive aquí, no en apply-gate.sh, como calibración de que T31 discrimina.
_t31_titular_sin_terminales() {
  local f="$1" slot="${2:-}" est="" nonce="" line cand_est cand_nonce cand_slot
  local _m cand_pr cand_iso cand_archivo cand_prev_est cand_prev_nonce recon
  [ -f "$f" ] || return 2
  exec 9< "$f" || return 2
  while IFS= read -r line <&9 || [ -n "$line" ]; do
    case "$line" in
      '# SLOT-CLAIM '*)
        [ -n "$nonce" ] && continue
        _m="$(printf '%s\n' "$line" | sed -n 's/^# SLOT-CLAIM \(.*\) = #\(.*\) \[\(.*\)\] \(.*\) \(.*\) (\(.*\))$/\1\x1f\2\x1f\3\x1f\4\x1f\5\x1f\6/p')"
        IFS=$'\x1f' read -r cand_slot cand_pr cand_est cand_iso cand_nonce cand_archivo <<<"$_m"
        identidad_slot_valida "$cand_est" "$cand_slot" "$cand_pr" "$cand_iso" "$cand_nonce" "$cand_archivo" || continue
        recon="# SLOT-CLAIM $cand_slot = #$cand_pr [$cand_est] $cand_iso $cand_nonce ($cand_archivo)"
        [ "$recon" = "$line" ] || continue
        [ -z "$slot" ] || [ "$cand_slot" = "$slot" ] || continue
        est="$cand_est"; nonce="$cand_nonce"
        ;;
      # SIN brazo de terminales: MERGED/BOUNCED/CEO RESUELTO caen al default del case (ninguna
      # rama), se ignoran, y la cadena vieja sigue abierta indefinidamente — el defecto medido.
    esac
  done
  exec 9<&-
  if [ -n "$nonce" ]; then printf '%s %s\n' "$est" "$nonce"; fi
  return 0
}
t31_flock() { local f; f="$(mktemp "$WORK/t31.XXXXXX")"; printf '%s\n' "$@" > "$f"; printf '%s\n' "$f"; }
t31_check() {  # $1=nombre $2=esperado-real $3...=líneas del flock
  local nombre="$1" esperado="$2" f got_real got_mut
  shift 2
  f="$(t31_flock "$@")"
  got_real="$(titular_vigente "$f" 101)"
  got_mut="$(_t31_titular_sin_terminales "$f" 101)"
  if [ "$got_real" = "$esperado" ]; then
    echo "  ✓ $nombre: real -> '$got_real'"; pass=$((pass+1))
  else
    echo "  ✗ $nombre: real -> '$got_real' (esperado '$esperado')"; fail=$((fail+1))
  fi
}

CLAIM_M2='# SLOT-CLAIM 101 = #6 [M2] 2026-09-09T19:30:00Z 22222222-2222-2222-2222-222222222222 (101_ok.sql)'
CLAIM_M4='# SLOT-CLAIM 101 = #9 [M4] 2026-09-10T10:00:00Z 44444444-4444-4444-4444-444444444444 (101_reuse.sql)'
t31_check "reuso tras MERGED: M4 gana la cadena NUEVA" \
  "M4 44444444-4444-4444-4444-444444444444" "$CLAIM_M2" '# ✅ M2 MERGED #6' "$CLAIM_M4"
t31_check "reuso tras BOUNCED: M4 gana la cadena NUEVA" \
  "M4 44444444-4444-4444-4444-444444444444" "$CLAIM_M2" '# 🔴 BOUNCED #6' "$CLAIM_M4"
t31_check "reuso tras CEO RESUELTO: M4 gana la cadena NUEVA" \
  "M4 44444444-4444-4444-4444-444444444444" "$CLAIM_M2" '# ✅ CEO RESUELTO #6' "$CLAIM_M4"
t31_check "CONTROL NEGATIVO: sin terminal, la cadena vieja SIGUE gobernando" \
  "M2 22222222-2222-2222-2222-222222222222" "$CLAIM_M2" "$CLAIM_M4"
t31_check "terminal de OTRO #PR no cierra la cadena vigente" \
  "M2 22222222-2222-2222-2222-222222222222" "$CLAIM_M2" '# ✅ M9 MERGED #999'
t31_check "TAKEOVER tras terminal no sucede a una cadena ya cerrada" \
  "" "$CLAIM_M2" '# ✅ M2 MERGED #6' \
  '# SLOT-CLAIM-TAKEOVER 101 = #6 [M3] 2026-09-10T10:00:00Z 33333333-3333-3333-3333-333333333333 (supersede M2 22222222-2222-2222-2222-222222222222)'

echo "-- MUTANTE embebido: el automata SIN terminales sigue dejando ganar a M2 tras MERGED -- CAZADO"
f="$(t31_flock "$CLAIM_M2" '# ✅ M2 MERGED #6' "$CLAIM_M4")"
got_mut="$(_t31_titular_sin_terminales "$f" 101)"
[ "$got_mut" = "M2 22222222-2222-2222-2222-222222222222" ] \
  && { echo "  ✓ CONTROL: sin el brazo de terminales, M2 (el viejo) sigue ganando pese al MERGED — reproduce el defecto, confirma que el arreglo es lo que lo cierra"; pass=$((pass+1)); } \
  || { echo "  ✗ CONTROL: el mutante no reprodujo el defecto conocido ('$got_mut') — el fixture no discrimina"; fail=$((fail+1)); }

echo "== T32 (ronda 35, MENOR — p1 M-02): SLOT y ARCHIVO sin cota de longitud aceptaban una entrada"
echo "   de tamaño arbitrario con rc 0. MUTANTE embebido: TM_RE_SLOT/TM_RE_ARCHIVO sin cota =="
_t32_slot_largo="$(printf '1%.0s' $(seq 1 10000))"
_t32_archivo_largo="$(printf 'a%.0s' $(seq 1 500))"
f="$(t31_flock "# SLOT-CLAIM $_t32_slot_largo = #6 [M2] 2026-09-09T19:30:00Z 22222222-2222-2222-2222-222222222222 (101_ok.sql)")"
got="$(titular_vigente "$f" "$_t32_slot_largo")"
[ -z "$got" ] \
  && { echo "  ✓ SLOT de 10.000 dígitos -> rechazado (vacío)"; pass=$((pass+1)); } \
  || { echo "  ✗ SLOT de 10.000 dígitos -> '$got' (esperado vacío)"; fail=$((fail+1)); }
f="$(t31_flock "# SLOT-CLAIM 101 = #6 [M2] 2026-09-09T19:30:00Z 22222222-2222-2222-2222-222222222222 (${_t32_archivo_largo}.sql)")"
got="$(titular_vigente "$f" 101)"
[ -z "$got" ] \
  && { echo "  ✓ ARCHIVO de 500 caracteres -> rechazado (vacío)"; pass=$((pass+1)); } \
  || { echo "  ✗ ARCHIVO de 500 caracteres -> '$got' (esperado vacío)"; fail=$((fail+1)); }
f="$(t31_flock '# SLOT-CLAIM 101 = #6 [M2] 2026-09-09T19:30:00Z 22222222-2222-2222-2222-222222222222 (101_ok.sql)')"
got="$(titular_vigente "$f" 101)"
[ "$got" = "M2 22222222-2222-2222-2222-222222222222" ] \
  && { echo "  ✓ CONTROL: slot/archivo de longitud normal siguen admitiendo"; pass=$((pass+1)); } \
  || { echo "  ✗ CONTROL: '$got' (esperado 'M2 …' — la cota rechaza de más)"; fail=$((fail+1)); }
echo "-- MUTANTE embebido: TM_RE_SLOT/TM_RE_ARCHIVO SIN cota siguen admitiendo el SLOT de 10.000 -- CAZADO"
_t32_re_slot_sin_cota='^[0-9]+$'
[[ "$_t32_slot_largo" =~ $_t32_re_slot_sin_cota ]] \
  && { echo "  ✓ CONTROL: el regex viejo (sin cota) SÍ casa el SLOT de 10.000 dígitos — confirma que la cota es lo que lo cierra"; pass=$((pass+1)); } \
  || { echo "  ✗ CONTROL: el regex viejo no reprodujo el caso ('$_t32_slot_largo' no casó) — no discrimina"; fail=$((fail+1)); }

echo "== T33 (ronda 37, CLASE 1 — BLOQUEANTE B-02, sobre v22): el \`export LC_ALL=C\` al CARGAR el"
echo "   fichero NO sobrevive a un llamador que reasigna LC_ALL DESPUÉS del source. El arreglo fija"
echo "   C en el ÁMBITO de cada comparación (local/local -x); [1-5] es RANGO DE COLACIÓN, el mutante"
echo "   cubre la CLASE de dígitos unicode y las TRES vías de reasignación tras el source =="
if locale -a 2>/dev/null | grep -qi '^en_US\.utf8$'; then
  # MUTANTE B-02: quita el ámbito C de titular_vigente (su `local -x LC_ALL=C`). Los `local LC_ALL=C`
  # de los dos predicados quedan INTACTOS (no llevan `-x`, no casa el patrón), así que el mutante
  # aísla EXACTAMENTE la comparación descubierta: el `[[ =~ $TM_RE_TERMINAL ]]` de titular_vigente.
  _t33_gate_mutante="$WORK/apply-gate-t33-mutante.sh"
  sed '/^  local -x LC_ALL=C/d' "$GATE_LIB" > "$_t33_gate_mutante"
  # La CLASE de dígitos unicode que [1-5] colaciona bajo en_US.utf8/en_GB.utf8 en glibc — no UN
  # ejemplo: árabe (p1), árabe extendido, fullwidth, circulado, superíndice (p2). Verificado antes
  # de escribir el test que las CINCO casan bajo este locale en esta máquina (no se asume, se mide).
  _t33_digitos=('٣' '۲' '３' '④' '²')
  _t33_nombres=('árabe (p1)' 'árabe-extendido' 'fullwidth' 'circulado' 'superíndice (p2)')
  # Vía canónica del ataque B-02: el llamador reasigna el locale DESPUÉS del source (por export).
  _t33_reasigna='source "$1"; export LC_ALL=en_US.utf8; titular_vigente "$2" 101'
  for _t33_i in "${!_t33_digitos[@]}"; do
    _t33_d="${_t33_digitos[$_t33_i]}"; _t33_n="${_t33_nombres[$_t33_i]}"
    f="$(t31_flock '# SLOT-CLAIM 101 = #6 [M2] 2026-09-09T19:30:00Z 22222222-2222-2222-2222-222222222222 (101_ok.sql)' \
                   "# ✅ M${_t33_d} MERGED #6" \
                   '# SLOT-CLAIM 101 = #9 [M4] 2026-09-10T10:00:00Z 44444444-4444-4444-4444-444444444444 (101_reuse.sql)')"
    got_real="$(bash -c "$_t33_reasigna" _ "$GATE_LIB" "$f")"
    if [ "$got_real" = "M2 22222222-2222-2222-2222-222222222222" ]; then
      echo "  ✓ real, reasignando tras source, dígito $_t33_n (M${_t33_d}): el MERGED forjado NO cierra la cadena (C manda)"; pass=$((pass+1))
    else
      echo "  ✗ real, dígito $_t33_n (M${_t33_d}): -> '$got_real' (esperado 'M2 …' — C debía mandar pese a la reasignación)"; fail=$((fail+1))
    fi
    got_mut="$(bash -c "$_t33_reasigna" _ "$_t33_gate_mutante" "$f")"
    if [ "$got_mut" = "M4 44444444-4444-4444-4444-444444444444" ]; then
      echo "  ✓ CONTROL mutante, dígito $_t33_n: sin el ámbito C de titular_vigente SÍ cuela (M4 gana) — este ejemplo discrimina"; pass=$((pass+1))
    else
      echo "  ✗ CONTROL mutante, dígito $_t33_n: no reprodujo el defecto ('$got_mut') — este ejemplo NO discrimina"; fail=$((fail+1))
    fi
  done
  # LAS TRES VÍAS de reasignación tras el source (con un dígito): C debe mandar en las tres, y el
  # mutante reproduce en las tres — así ninguna vía queda como vector no medido.
  f="$(t31_flock '# SLOT-CLAIM 101 = #6 [M2] 2026-09-09T19:30:00Z 22222222-2222-2222-2222-222222222222 (101_ok.sql)' \
                 '# ✅ M٣ MERGED #6' \
                 '# SLOT-CLAIM 101 = #9 [M4] 2026-09-10T10:00:00Z 44444444-4444-4444-4444-444444444444 (101_reuse.sql)')"
  _t33_via_nombres=('export tras source' 'asignación simple tras source' 'prefijo del comando')
  _t33_vias=('source "$1"; export LC_ALL=en_US.utf8; titular_vigente "$2" 101'
             'source "$1"; LC_ALL=en_US.utf8; titular_vigente "$2" 101'
             'source "$1"; LC_ALL=en_US.utf8 titular_vigente "$2" 101')
  for _t33_j in "${!_t33_vias[@]}"; do
    got_via="$(bash -c "${_t33_vias[$_t33_j]}" _ "$GATE_LIB" "$f")"
    [ "$got_via" = "M2 22222222-2222-2222-2222-222222222222" ] \
      && { echo "  ✓ vía «${_t33_via_nombres[$_t33_j]}»: C manda, la cadena sigue en M2"; pass=$((pass+1)); } \
      || { echo "  ✗ vía «${_t33_via_nombres[$_t33_j]}»: -> '$got_via' (esperado 'M2 …')"; fail=$((fail+1)); }
    got_via_mut="$(bash -c "${_t33_vias[$_t33_j]}" _ "$_t33_gate_mutante" "$f")"
    [ "$got_via_mut" = "M4 44444444-4444-4444-4444-444444444444" ] \
      && { echo "    · CONTROL mutante, misma vía: M4 gana — la vía es un vector real"; pass=$((pass+1)); } \
      || { echo "    ✗ CONTROL mutante, misma vía: '$got_via_mut' (no reprodujo)"; fail=$((fail+1)); }
  done
  rm -f "$_t33_gate_mutante"
  # CONTROL: un MERGED canónico (dígito ASCII) cierra la cadena IGUAL bajo C y bajo la reasignación.
  f_ascii="$(t31_flock '# SLOT-CLAIM 101 = #6 [M2] 2026-09-09T19:30:00Z 22222222-2222-2222-2222-222222222222 (101_ok.sql)' \
                       '# ✅ M3 MERGED #6' \
                       '# SLOT-CLAIM 101 = #9 [M4] 2026-09-10T10:00:00Z 44444444-4444-4444-4444-444444444444 (101_reuse.sql)')"
  got_c="$(LC_ALL=C bash -c 'source "$1"; titular_vigente "$2" 101' _ "$GATE_LIB" "$f_ascii")"
  got_h="$(bash -c 'source "$1"; export LC_ALL=en_US.utf8; titular_vigente "$2" 101' _ "$GATE_LIB" "$f_ascii")"
  [ "$got_c" = "$got_h" ] && [ "$got_c" = "M4 44444444-4444-4444-4444-444444444444" ] \
    && { echo "  ✓ CONTROL: un MERGED canónico (dígito ASCII) da el MISMO titular (M4) bajo C y bajo reasignación"; pass=$((pass+1)); } \
    || { echo "  ✗ CONTROL: el MERGED canónico difiere: C='$got_c' reasignado='$got_h'"; fail=$((fail+1)); }
else
  echo "  ⚠ SALTADO: locale en_US.utf8 no disponible en esta máquina (\`locale -a\`) — NO MEDIDO en este host, no promovido a verde ni a rojo"
fi

echo "== T34 (ronda 36, CLASE 2 — BLOQUEANTE; AMPLIADO ronda 37, B-01): la restricción de CLASE 4/"
echo "   ronda 35 vivía SOLO en un comentario; v22 la hizo guarda de \$#; v23/B-01 cierra además el"
echo "   slot VACÍO — contar argumentos no es filtrar. \$# != 3 o slot vacío/no-numérico -> rc 3 =="
_t34_mut_intake_slot_sin_guarda() {  # $1=flock $2=estación — reproduce la FALSA ADMISIÓN histórica
  # No basta con quitar la guarda de \$#: tras B-01, titular_vigente RECHAZA el slot vacío (rc 3),
  # así que una llamada de 2 args mutante caería en rc 3 antes de admitir. Para reproducir la falsa
  # admisión hay que revertir AMBAS capas — se hace sobre un mutante de FICHERO (no una copia a mano
  # que diverja): quita la guarda de \$#, quita la guarda numérica y restaura el no-filtro.
  local mut="$WORK/apply-gate-t34-mutante.sh" rc=0
  sed -e '/se requieren 3 argumentos/d' \
      -e '/slot vacío\/no-numérico/d' \
      -e 's/\[ "$cand_slot" = "$slot" \] || continue/[ -z "$slot" ] || [ "$cand_slot" = "$slot" ] || continue/' \
      "$GATE_LIB" > "$mut"
  bash -c 'source "$1"; intake_slot "$2" "$3"' _ "$mut" "$1" "$2"; rc=$?   # intake_slot <flock> <est>, slot OMITIDO
  rm -f "$mut"
  return "$rc"
}
f="$(multi_flock "$(_101claim)")"   # histórico M1/100 (izquierda) + M2/101 — reusa fixture de T29/T31
echo "-- llamada de 2 argumentos (slot OMITIDO, no declarado) --"
rc=0; intake_slot "$f" M1 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] \
  && { echo "  ✓ intake_slot(f,M1) sin slot -> rc 3 LLAMADA MAL FORMADA (ni admite ni cede como si decidiera)"; pass=$((pass+1)); } \
  || { echo "  ✗ intake_slot(f,M1) sin slot -> rc=$rc (esperado 3)"; fail=$((fail+1)); }
rc=0; intake_slot "$f" M2 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] \
  && { echo "  ✓ intake_slot(f,M2) sin slot -> rc 3 LLAMADA MAL FORMADA"; pass=$((pass+1)); } \
  || { echo "  ✗ intake_slot(f,M2) sin slot -> rc=$rc (esperado 3)"; fail=$((fail+1)); }
echo "-- CONTROL: con el slot declarado, la decisión es correcta (no se rompió nada real) --"
rc=0; intake_slot "$f" M1 101 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] \
  && { echo "  ✓ intake_slot(f,M1,101) -> RECHAZADA (correcto: el 101 es de M2)"; pass=$((pass+1)); } \
  || { echo "  ✗ intake_slot(f,M1,101) -> rc=$rc (esperado 1)"; fail=$((fail+1)); }
rc=0; intake_slot "$f" M2 101 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] \
  && { echo "  ✓ intake_slot(f,M2,101) -> ADMITIDA (correcto)"; pass=$((pass+1)); } \
  || { echo "  ✗ intake_slot(f,M2,101) -> rc=$rc (esperado 0)"; fail=$((fail+1)); }
echo "-- B-01: el «modo sin filtro declarando \"\"» se RETIRA — era una escapatoria que el llamador"
echo "   controla. Slot vacío / sólo-espacios / no-numérico -> rc 3, no una operación (las tres"
echo "   incómodas que pidió el coordinador) --"
f_unico="$(multi_flock)"
for _b01_s in "" "  " "1x"; do
  rc=0; intake_slot "$f_unico" M1 "$_b01_s" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 3 ] \
    && { echo "  ✓ intake_slot(f_unico,M1,'$_b01_s') -> rc 3 LLAMADA MAL FORMADA (ya no hay modo sin filtro)"; pass=$((pass+1)); } \
    || { echo "  ✗ intake_slot(f_unico,M1,'$_b01_s') -> rc=$rc (esperado 3: la escapatoria de B-01 sigue abierta)"; fail=$((fail+1)); }
done
echo "-- MUTANTE embebido: la firma vieja (\$3 opcional, sin guarda de \$#) da FALSA ADMISIÓN -- CAZADO"
rc=0; _t34_mut_intake_slot_sin_guarda "$f" M1 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] \
  && { echo "  ✓ CONTROL: la firma vieja admite a M1 sin slot (rc 0, FALSA ADMISIÓN) — confirma que la guarda de \$# es lo que lo cierra"; pass=$((pass+1)); } \
  || { echo "  ✗ CONTROL: la firma vieja no reprodujo la falsa admisión (rc=$rc) — el fixture no discrimina"; fail=$((fail+1)); }

echo "== T35 (ronda 36, CLASE 3 — MAYOR, dos pasadas independientes convergentes sobre v21): el"
echo "   TAKEOVER enlazaba con la cadena SOLO por nonce — la forma completa (7 campos + round-trip)"
echo "   da apariencia de identidad completa mientras dos RELACIONES esenciales (mismo PR, misma"
echo "   estación anterior REAL) no se comprobaban. MUTANTE: enlace solo-por-nonce =="
_t35_titular_solo_nonce() {  # copia de titular_vigente CON el enlace de TAKEOVER solo por nonce
  local f="$1" slot="${2:-}" est="" nonce="" pr="" line cand_est cand_nonce cand_slot
  local _m cand_pr cand_iso cand_archivo cand_prev_est cand_prev_nonce recon
  [ -f "$f" ] || return 2
  exec 9< "$f" || return 2
  while IFS= read -r line <&9 || [ -n "$line" ]; do
    case "$line" in
      '# SLOT-CLAIM '*)
        [ -n "$nonce" ] && continue
        _m="$(printf '%s\n' "$line" | sed -n 's/^# SLOT-CLAIM \(.*\) = #\(.*\) \[\(.*\)\] \(.*\) \(.*\) (\(.*\))$/\1\x1f\2\x1f\3\x1f\4\x1f\5\x1f\6/p')"
        IFS=$'\x1f' read -r cand_slot cand_pr cand_est cand_iso cand_nonce cand_archivo <<<"$_m"
        identidad_slot_valida "$cand_est" "$cand_slot" "$cand_pr" "$cand_iso" "$cand_nonce" "$cand_archivo" || continue
        recon="# SLOT-CLAIM $cand_slot = #$cand_pr [$cand_est] $cand_iso $cand_nonce ($cand_archivo)"
        [ "$recon" = "$line" ] || continue
        [ -z "$slot" ] || [ "$cand_slot" = "$slot" ] || continue
        est="$cand_est"; nonce="$cand_nonce"; pr="$cand_pr"
        ;;
      '# SLOT-CLAIM-TAKEOVER '*)
        [ -n "$nonce" ] || continue
        _m="$(printf '%s\n' "$line" | sed -n 's/^# SLOT-CLAIM-TAKEOVER \(.*\) = #\(.*\) \[\(.*\)\] \(.*\) \(.*\) (supersede \(.*\) \(.*\))$/\1\x1f\2\x1f\3\x1f\4\x1f\5\x1f\6\x1f\7/p')"
        IFS=$'\x1f' read -r cand_slot cand_pr cand_est cand_iso cand_nonce cand_prev_est cand_prev_nonce <<<"$_m"
        identidad_takeover_valida "$cand_est" "$cand_slot" "$cand_pr" "$cand_iso" "$cand_nonce" "$cand_prev_est" "$cand_prev_nonce" || continue
        recon="# SLOT-CLAIM-TAKEOVER $cand_slot = #$cand_pr [$cand_est] $cand_iso $cand_nonce (supersede $cand_prev_est $cand_prev_nonce)"
        [ "$recon" = "$line" ] || continue
        [ -z "$slot" ] || [ "$cand_slot" = "$slot" ] || continue
        # MUTANTE: SIN comprobar cand_pr=pr ni cand_prev_est=est — solo el nonce.
        [ "$cand_prev_nonce" = "$nonce" ] || continue
        est="$cand_est"; nonce="$cand_nonce"; pr="$cand_pr"
        ;;
      '# ✅ '*|'# 🔴 '*)
        [[ "$line" =~ $TM_RE_TERMINAL ]] || continue
        [ -n "$pr" ] && [ "${BASH_REMATCH[2]}" = "$pr" ] || continue
        est=""; nonce=""; pr=""
        ;;
    esac
  done
  exec 9<&-
  if [ -n "$nonce" ]; then printf '%s %s\n' "$est" "$nonce"; fi
  return 0
}
_t35_pr_ajeno="$(t31_flock \
  '# SLOT-CLAIM 101 = #6 [M2] 2026-09-09T19:30:00Z 22222222-2222-2222-2222-222222222222 (101_ok.sql)' \
  '# SLOT-CLAIM-TAKEOVER 101 = #999 [M3] 2026-09-10T10:00:00Z 33333333-3333-3333-3333-333333333333 (supersede M2 22222222-2222-2222-2222-222222222222)' \
  '# ✅ M2 MERGED #6' \
  '# SLOT-CLAIM 101 = #9 [M4] 2026-09-10T11:00:00Z 44444444-4444-4444-4444-444444444444 (101_reuse.sql)')"
got="$(titular_vigente "$_t35_pr_ajeno" 101)"
[ "$got" = "M4 44444444-4444-4444-4444-444444444444" ] \
  && { echo "  ✓ takeover con PR AJENO (#999, nonce real de M2) rechazado -> el MERGED #6 legítimo cierra y M4 gana"; pass=$((pass+1)); } \
  || { echo "  ✗ takeover con PR AJENO -> '$got' (esperado 'M4 …')"; fail=$((fail+1)); }

_t35_est_ajena="$(t31_flock \
  '# SLOT-CLAIM 101 = #6 [M2] 2026-09-09T19:30:00Z 22222222-2222-2222-2222-222222222222 (101_ok.sql)' \
  '# SLOT-CLAIM-TAKEOVER 101 = #6 [M3] 2026-09-10T10:00:00Z 33333333-3333-3333-3333-333333333333 (supersede M5 22222222-2222-2222-2222-222222222222)')"
got="$(titular_vigente "$_t35_est_ajena" 101)"
[ "$got" = "M2 22222222-2222-2222-2222-222222222222" ] \
  && { echo "  ✓ takeover con ESTACIÓN-ANTERIOR AJENA (M5, mismo nonce real) rechazado -> M2 sigue vigente"; pass=$((pass+1)); } \
  || { echo "  ✗ takeover con estación ajena -> '$got' (esperado 'M2 …')"; fail=$((fail+1)); }

_t35_consistente="$(t31_flock \
  '# SLOT-CLAIM 101 = #6 [M2] 2026-09-09T19:30:00Z 22222222-2222-2222-2222-222222222222 (101_ok.sql)' \
  '# SLOT-CLAIM-TAKEOVER 101 = #6 [M3] 2026-09-10T10:00:00Z 33333333-3333-3333-3333-333333333333 (supersede M2 22222222-2222-2222-2222-222222222222)')"
got="$(titular_vigente "$_t35_consistente" 101)"
[ "$got" = "M3 33333333-3333-3333-3333-333333333333" ] \
  && { echo "  ✓ CONTROL: takeover consistente (mismo PR, misma estación) SÍ sucede -> $got"; pass=$((pass+1)); } \
  || { echo "  ✗ CONTROL: takeover consistente -> '$got' (esperado 'M3 …' — el arreglo rechaza de más)"; fail=$((fail+1)); }

echo "-- MUTANTE embebido: el enlace solo-por-nonce acepta AMBOS ataques -- CAZADO"
got_mut="$(_t35_titular_solo_nonce "$_t35_pr_ajeno" 101)"
[ "$got_mut" = "M3 33333333-3333-3333-3333-333333333333" ] \
  && { echo "  ✓ CONTROL: solo-nonce acepta el PR ajeno (M3 gana indebidamente) — confirma que el check de PR es lo que lo cierra"; pass=$((pass+1)); } \
  || { echo "  ✗ CONTROL: solo-nonce no reprodujo el ataque de PR ('$got_mut') — no discrimina"; fail=$((fail+1)); }
got_mut="$(_t35_titular_solo_nonce "$_t35_est_ajena" 101)"
[ "$got_mut" = "M3 33333333-3333-3333-3333-333333333333" ] \
  && { echo "  ✓ CONTROL: solo-nonce acepta la estación ajena (M3 gana indebidamente) — confirma que el check de estación es lo que lo cierra"; pass=$((pass+1)); } \
  || { echo "  ✗ CONTROL: solo-nonce no reprodujo el ataque de estación ('$got_mut') — no discrimina"; fail=$((fail+1)); }

# v27/v28 dieron la medicion behavioral correcta pero el ENUMERADOR reconocia formas literales
# (grep -E, -qE, --extended-regexp...) y cada ronda tapaba unas y dejaba otras (linea continuada,
# grep en variable, awk `-v r=`, eval). Un enumerador de formas literales NUNCA es completo (ronda 17).
# La clase (una): completo-O-fail-closed de VERDAD -> se DEJA DE GREPEAR FORMAS y se DESCUBRE POR
# EJECUCION: se corre el RECORRIDO DE TITULARIDAD real bajo (DEBUG trap para bash `=~` + shim de PATH
# para grep/awk), con el LLAMADOR exportando cada locale hostil; cada comparador que EJECUTA emite su
# propio registro con su LC_ALL EFECTIVO. Es forma-agnostico (variable/continuada/`-v`/eval que
# ejecuta aparecen) y AISLA por sitio (clave linea:seq; dos comparadores en la misma posicion -> dos
# registros). Medicion behavioral (forja/valido) por sitio bajo el locale efectivo capturado.
# Fail-closed VALIDADO (insumos no-vacios + ancla; funcion con comparador NO ejercida -> rc2) y
# EJERCIDO (los controles corren el censo REAL y exigen salida no-cero). rc 2 = NO MEDIDO.
#
# ── AMBITO DEL DETECTOR (T36) — que MIDE y que declara NO MEDIDO ──────────────────────────────
# Igual que el clasificador de gates de main, T36 declara su ambito y clasifica FAIL-CLOSED todo
# lo que quede fuera: dentro del ambito un defecto lo caza el censo; fuera del ambito el resultado
# es NO MEDIDO (rc2), nunca un verde silencioso. La cobertura DENTRO del ambito esta acreditada por
# un ORACULO EXTERNO ejecutable (oraculo-t05, blob ad8b4eb6/cc366a50): 1 control + 5 escenas que
# inyectan el defecto en una copia y leen el veredicto unico de T36. AMBITO CUBIERTO Y ACREDITADO:
#   - descubrimiento POR EJECUCION de los comparadores de titularidad (bash `=~` via DEBUG trap;
#     grep/awk via shim de PATH que registra el LC_ALL EFECTIVO), forma-agnostico (variable,
#     `-v r=`, eval que ejecuta) y AISLADO por sitio (clave linea:seq);
#   - B-01: rama no tomada con `=~` hostil, grep NOPROBE (regex equivalente, NOPROBE != COVERED),
#     awk con `$0~r` sin RE_/sin espacio, y dos comparadores en la MISMA posicion (samepos);
#   - M-01: shim MENTIROSO no-discriminante (declara C siendo hostil) -> acreditacion rc2.
#
# ── FUERA DE AMBITO = NO MEDIDO FAIL-CLOSED (DEUDA CONOCIDA DECLARADA, ruling lead A 11-sep) ─────
# Estas 3 clases NO convergieron con detectores heuristicos (grep/awk) y quedan como deuda
# declarada, NO como bloqueo. No las mide T36 hoy; se clasifican NO MEDIDO. Si algun dia se quiere
# su precision, nacen como issue propia con un parser real (opcion B), sin bloquear la publicacion:
#   1. BLOQ2  — `grep -E` en LINEA CONTINUADA (invocacion partida con `\`): el recorrido la ejecuta,
#               pero la clase de construccion no esta acreditada por el oraculo -> NO MEDIDO.
#   2. M-01'  — shim CON ESTADO / argv-aware (discrimina su comportamiento segun quien lo llama para
#               mentir sobre el LC_ALL): el oraculo solo prueba el shim mentiroso SIMPLE, no el que
#               guarda estado -> un shim con estado derrota la acreditacion -> NO MEDIDO.
#   3. M-02   — `=~` LEXICO PREEXISTENTE no ejercido en el recorrido (comparador presente en codigo
#               anterior pero no ejecutado): el descubrimiento POR EJECUCION no lo observa -> NO MEDIDO.
# ─────────────────────────────────────────────────────────────────────────────────────────────
echo "== T36 (ronda 17 — censo por DESCUBRIMIENTO POR EJECUCION; medicion AISLADA por sitio; fail-closed validado y ejercido):"
_t36_host=""
for _l in en_US.utf8 en_GB.utf8; do locale -a 2>>"$WORK/t36-drv.err" | grep -qix "$_l" && _t36_host="$_t36_host $_l"; done
_t36_host="${_t36_host# }"
: > "$WORK/t36-drv.err"

# --- fences ejecutables (§8 de ref02, §2 de ref01) + identidad_canonica aislada + parser awk ---
_t36_acq="$WORK/t36-acq.sh"; _t36_rec01="$WORK/t36-rec01.sh"; _t36_idc="$WORK/t36-idc.sh"; _t36_awkp="$WORK/t36-awkp.sh"
awk '!inb && /^[[:space:]]*```bash/{inb=1;buf="";next} inb && /^[[:space:]]*```[[:space:]]*$/{if(buf~/8\.0\)/){printf "%s",buf;exit} inb=0;next} inb{buf=buf $0 "\n"}' "$REF02" > "$_t36_acq"
awk '!inb && /^[[:space:]]*```bash/{inb=1;buf="";next} inb && /^[[:space:]]*```[[:space:]]*$/{if(buf~/identidad_slot_valida/ && buf~/intake_slot/){printf "%s",buf;exit} inb=0;next} inb{buf=buf $0 "\n"}' "$REF01" > "$_t36_rec01"
{ grep -E '^RE_[A-Z]+=' "$REF02"; awk '/^identidad_canonica\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$REF02"; } > "$_t36_idc"
if [ -s "$_t36_acq" ] && [ -s "$_t36_rec01" ] && [ -s "$_t36_idc" ]; then
  echo "  ✓ fences ejecutables (ref02 §8, ref01 §2) + idcanon aislada extraidos"; pass=$((pass+1))
else echo "  ✗ no pude extraer los fences/idcanon"; fail=$((fail+1)); fi

# --- flock valido que EJERCITA la cadena entera: SLOT-CLAIM -> TAKEOVER -> TERMINAL ---
_t36_N1=11111111-1111-1111-1111-111111111111; _t36_N2=22222222-2222-2222-2222-222222222222
_t36_flock="$WORK/t36-flock"
{ printf '# SLOT-CLAIM 100 = #42 [M2] 2026-01-01T00:00:00Z %s (f.sql)\n' "$_t36_N1"
  printf '# SLOT-CLAIM-TAKEOVER 100 = #42 [M3] 2026-01-01T00:00:00Z %s (supersede M2 %s)\n' "$_t36_N2" "$_t36_N1"
  printf '# %s M3 MERGED #42\n' "✅"; } > "$_t36_flock"
_t36_classf="$WORK/t36-classf"; printf '# APPLY-RUN\n' > "$_t36_classf"

# --- probes: (valido, forja) por CLAVE de atomo/regex ---
_t36_valid() { case "$1" in
  EST) printf '[M3]';; SLOT) printf '100';; PR) printf '#42';;
  ISO) printf '2026-01-01T00:00:00Z';; NONCE) printf '22222222-2222-2222-2222-222222222222';;
  ARCHIVO) printf 'f.sql';; HEADHEX) printf 'deadbeef';; TERMINAL) printf '# %s M3 MERGED #42' "✅";; *) printf 'NOPROBE';; esac; }
_t36_forge() { case "$1" in
  EST) printf '[M٣]';; SLOT) printf '٣';; PR) printf '#٣';;
  ISO) printf '٢026-01-01T00:00:00Z';; NONCE) printf '٢2222222-2222-2222-2222-222222222222';;
  ARCHIVO) printf 'archívo.sql';; HEADHEX) printf '٢eadbeef';; TERMINAL) printf '# %s M٣ MERGED #42' "✅";; *) printf 'NOPROBE';; esac; }
# regex/atom (token tras `=~`, o pattern) -> CLAVE de probe; NOPROBE si desconocido (=> rc2)
_t36_key() { case "$1" in
  '$TM_RE_EST'|'$RE_EST'|'^[[]M[1-5][]]$') printf EST;;
  '$TM_RE_SLOT'|'^[0-9]{1,6}$') printf SLOT;;
  '$TM_RE_PR'|'$RE_PR'|'^#[1-9][0-9]*$') printf PR;;
  '$TM_RE_ISO'|'$RE_ISO') printf ISO;;
  '$TM_RE_NONCE'|'$RE_NONCE') printf NONCE;;
  '$TM_RE_ARCHIVO'|'^[A-Za-z0-9_.-]{1,200}\.sql$') printf ARCHIVO;;
  '^[0-9a-fA-F]{7,40}$') printf HEADHEX;;
  '$TM_RE_TERMINAL') printf TERMINAL;;
  *) printf 'NOPROBE';; esac; }
# resuelve un token `$ATOM` a su VALOR leyendo la definicion de la fuente (sin sourcear en este shell)
_t36_resolve() { case "$1" in
  '$'*) local n="${1#\$}" line; line="$( { grep -hE "^$n=" "$GATE_LIB"; grep -hE "^$n=" "$REF02"; } 2>>"$WORK/t36-drv.err" | head -1)"
       [ -n "$line" ] || { printf ''; return; }
       ( eval "_r=${line#*=}" 2>>"$WORK/t36-drv.err"; printf '%s' "${_r-}" );;
  *) printf '%s' "$1";; esac; }

# --- shim de PATH: registra el LC_ALL EFECTIVO del hijo + argv y ejecuta el binario real ---
_t36_mkshim() { local d="$WORK/t36-shim"; mkdir -p "$d"; local rg ra b real
  rg="$(command -v grep)"; ra="$(command -v awk)"
  for b in grep egrep awk gawk mawk; do case "$b" in grep) real="$rg";; egrep) real="$rg -E";; *) real="$ra";; esac
    printf '#!/usr/bin/env bash\nprintf '\''SUB\\x1f%%s\\x1f%%s\\x1f%%s\\n'\'' "%s" "${LC_ALL-<unset>}" "$*" >>"$SHIMLOG"\nexec %s "$@"\n' "$b" "$real" > "$d/$b"
    chmod +x "$d/$b"; done; }

# --- parser awk (fence) a un runnable — extraccion por RANGO (awk...-v RE_EST= -> apertura -> cierre) ---
_t36_mk_awkp() {  # $1=fuente $2=out ; rc1 si no hay parser
  local src="$1" out="$2" astart qopen aend
  astart="$(grep -n 'awk .*-v RE_EST=' "$src" | head -1 | cut -d: -f1)"; [ -n "$astart" ] || return 1
  qopen="$(awk -v s="$astart" 'NR>=s && /'\''[[:space:]]*$/{print NR; exit}' "$src")"; [ -n "$qopen" ] || return 1
  aend="$(awk -v q="$qopen" 'NR>q && /'\''/{print NR; exit}' "$src")"; [ -n "$aend" ] || return 1
  { grep -E '^RE_[A-Z]+=' "$REF02"; printf 'RE_GO=%s\nTM_GATE_DRY=0\nFLOCK_FILE=%s\n' "'^[[](CEO|Orquestador)[]]$'" "$_t36_flock"
    sed -n "${astart},${aend}p" "$src"; } > "$out"; }

# --- DESCUBRIMIENTO: corre $3 (source $2, coma-sep) bajo trap+shim en locale $5; sitios a $4 ---
# emite  BASH\x1f<fn>\x1f<linea:seq>\x1f<LC_ALL_efectivo>\x1f<regextoken>  y  SUB\x1f<bin>\x1f<LC_ALL>\x1f<argv>\x1f<loc>
_t36_discover() { local shimlog="$1" srcs="$2" cmd="$3" sites="$4" loc="$5"; : >"$shimlog"
  LC_ALL="$loc" SHIMLOG="$shimlog" PATH="$WORK/t36-shim:$PATH" bash -c '
    set -T; _seq=0
    IFS="," read -ra _S <<<"'"$srcs"'"; for _f in "${_S[@]}"; do [ -n "$_f" ] && source "$_f"; done
    _t36_dbg() { case "$BASH_COMMAND" in *"=~"*)
        _seq=$((_seq+1)); local a="${BASH_COMMAND#*=~}"; a="${a#"${a%%[![:space:]]*}"}"; a="${a%%]]*}"; a="${a%% *}"
        printf "BASH\x1f%s\x1f%s:%s\x1f%s\x1f%s\n" "${FUNCNAME[1]:-<top>}" "${BASH_LINENO[0]}" "$_seq" "${LC_ALL-<unset>}" "$a" >>"'"$sites"'" ;; esac; }
    trap _t36_dbg DEBUG
    '"$cmd"'
  ' >>"$WORK/t36-drv.err" 2>&1
  awk -F'\037' -v L="$loc" '$1=="SUB"{print $0 "\037" L}' "$shimlog" >>"$sites"; }

# --- medicion behavioral AISLADA por sitio bash `=~` (forja/valido bajo el locale efectivo capturado) ---
_t36_measure_bash() { local loc="$1" tok="$2" key re v f rv rf; key="$(_t36_key "$tok")"
  [ "$key" = NOPROBE ] && { printf 'NOPROBE'; return; }
  re="$(_t36_resolve "$tok")"; [ -z "$re" ] && { printf 'NOPROBE'; return; }
  v="$(_t36_valid "$key")"; f="$(_t36_forge "$key")"
  rv="$(LC_ALL="$loc" bash -c 're="$1";s="$2";[[ "$s" =~ $re ]]' _ "$re" "$v" >/dev/null 2>>"$WORK/t36-drv.err"; echo $?)"
  rf="$(LC_ALL="$loc" bash -c 're="$1";s="$2";[[ "$s" =~ $re ]]' _ "$re" "$f" >/dev/null 2>>"$WORK/t36-drv.err"; echo $?)"
  [ "$rf" != "$rv" ] && printf 'COVERED' || printf 'UNCOVERED(@%s rcv=%s rcf=%s)' "$loc" "$rv" "$rf"; }
# --- medicion grep aislada (glibc colaciona): forja/valido bajo el locale efectivo capturado ---
_t36_measure_grep() { local loc="$1" argv="$2" pat="" key p rv rf v f
  for p in $argv; do case "$p" in -*) ;; *) [ "$(_t36_key "$p")" != NOPROBE ] && pat="$p";; esac; done
  [ -z "$pat" ] && { printf 'NOPROBE'; return; }; key="$(_t36_key "$pat")"
  v="$(_t36_valid "$key")"; f="$(_t36_forge "$key")"
  rv="$(LC_ALL="$loc" grep -qE "$pat" <<<"$v" 2>>"$WORK/t36-drv.err"; echo $?)"
  rf="$(LC_ALL="$loc" grep -qE "$pat" <<<"$f" 2>>"$WORK/t36-drv.err"; echo $?)"
  [ "$rf" != "$rv" ] && printf 'COVERED' || printf 'UNCOVERED(@%s rcv=%s rcf=%s)' "$loc" "$rv" "$rf"; }

# --- backstop de completitud: TODA funcion con bash `=~` real debe haberse DESCUBIERTO (ejercido) ---
_t36_fns_con_cmp() { awk '
  { l=$0; sub(/[[:space:]]+#[[:space:]].*/,"",l) }
  l ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/ { fn=l; sub(/\(\).*/,"",fn) }
  l ~ /^\}/ { fn="" }
  l ~ /^[[:space:]]*#/ { next }
  l ~ /=~/ && fn!="" { print fn }' "$1" | sort -u; }
_t36_cnt_awk() { awk '{l=$0;sub(/[[:space:]]+#[[:space:]].*/,"",l)} l ~ /^[[:space:]]*#/{next} l ~ /(^|[^A-Za-z_.])awk([[:space:]])/ && l ~ /RE_[A-Z]/ {c++} END{print c+0}' "$1"; }
# (B-01) COMPLETITUD A NIVEL DE SITIO, no de NOMBRE de funcion: enumera cada LINEA con `=~` (comentarios
# fuera) atribuida a su funcion, como `fn:linea`. El backstop por funcion no ve un `=~` en una rama NO
# TOMADA de una funcion ya descubierta; el de SITIO exige que ESA linea concreta haya sido ejercida bajo
# C efectivo. Una linea estatica sin registro de descubrimiento = rama muerta / no tomada => fail-closed.
_t36_static_cmp_lines() { awk '
  { l=$0; sub(/[[:space:]]+#[[:space:]].*/,"",l) }
  l ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/ { fn=l; sub(/\(\).*/,"",fn) }
  l ~ /^\}/ { fn="" }
  l ~ /^[[:space:]]*#/ { next }
  l ~ /=~/ && fn!="" { print fn":"NR }' "$1"; }
# (B-01, v31) CLAVE POR SITIO, no por funcion:linea: dos `=~` en la MISMA linea colisionan en la clave
# fn:linea — el comparador ejecutado cubre la clave y un segundo `=~` (p.ej. en rama no tomada, hostil)
# escapa. Se EXIGE <=1 `=~` por linea de comparador en las fuentes reales (que ya cumplen 1/linea), asi
# fn:linea identifica un sitio UNICO. Emite fn:linea:n para toda linea con n>1 => fail-closed (rc2).
_t36_multi_cmp_lines() { awk '
  { l=$0; sub(/[[:space:]]+#[[:space:]].*/,"",l) }
  l ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/ { fn=l; sub(/\(\).*/,"",fn) }
  l ~ /^\}/ { fn="" }
  l ~ /^[[:space:]]*#/ { next }
  fn!="" { n=gsub(/=~/,"=~",l); if(n>1) print fn":"NR":"n }' "$1"; }

# ============ CENSO: descubre por ejecucion, mide aislado, agrega rc 0/1/2 ============
_t36_census_rc() {  # setea _C_unc/_C_nm ; return 0 (COVERED) / 1 (UNCOVERED) / 2 (NO MEDIDO)
  _C_unc=""; _C_nm=""; local src f loc
  # (M-01) VALIDAR insumos: no-vacios + ancla esperada. /dev/null, vacio o sin ancla => rc2.
  { [ -s "$GATE_LIB" ] && grep -q 'identidad_slot_valida()' "$GATE_LIB"; } || _C_nm="$_C_nm gate-lib-invalido"
  { [ -s "$_t36_acq" ] && grep -qE 'awk .*-v RE_EST=' "$_t36_acq"; } || _C_nm="$_C_nm acq-invalido(§8)"
  { [ -s "$_t36_rec01" ] && grep -q 'identidad_slot_valida' "$_t36_rec01" && grep -q 'intake_slot' "$_t36_rec01"; } || _C_nm="$_C_nm rec01-invalido(§2)"
  { [ -s "$_t36_idc" ] && grep -q 'identidad_canonica()' "$_t36_idc"; } || _C_nm="$_C_nm idc-invalido"
  [ -n "${_C_nm// }" ] && return 2
  [ -z "${_t36_host// }" ] && { _C_nm="sin-locales-hostiles"; return 2; }
  # (M-01) ACREDITAR EL INSTRUMENTO ANTES DE CONFIARLE EL GROUND TRUTH. El shim de PATH es la UNICA
  # evidencia del LC_ALL EFECTIVO de awk (mawk es byte-orientado: no hay medicion conductual que lo
  # delate). Un shim que MIENTE —registra C para un hijo que corrio bajo locale hostil— haria pasar un
  # comparador fuera de C con el censo verde. Se le pasa una sonda CONOCIDA por el shim bajo un locale
  # hostil y bajo C: DEBE registrar loc distinto (discrimina). Si no (registra C para el hostil), el
  # instrumento esta comprometido y el censo NO puede certificar nada => NO MEDIDO (rc2), jamas verde.
  local _hl="${_t36_host%% *}" _shcal="$WORK/t36-shimcal.log"; : >"$_shcal"
  LC_ALL="$_hl" SHIMLOG="$_shcal" PATH="$WORK/t36-shim:$PATH" awk 'BEGIN{exit 0}' </dev/null >/dev/null 2>>"$WORK/t36-drv.err"
  LC_ALL=C      SHIMLOG="$_shcal" PATH="$WORK/t36-shim:$PATH" awk 'BEGIN{exit 0}' </dev/null >/dev/null 2>>"$WORK/t36-drv.err"
  local _cal_h _cal_c
  _cal_h="$(awk -F'\037' '$1=="SUB" && ($2=="awk"||$2=="gawk"||$2=="mawk") && $3!="C"{c++} END{print c+0}' "$_shcal")"
  _cal_c="$(awk -F'\037' '$1=="SUB" && ($2=="awk"||$2=="gawk"||$2=="mawk") && $3=="C"{c++} END{print c+0}' "$_shcal")"
  { [ "$_cal_h" -ge 1 ] && [ "$_cal_c" -ge 1 ]; } || { _C_nm="$_C_nm shim-no-discrimina(h=$_cal_h,c=$_cal_c)"; return 2; }
  local SITES="$WORK/t36-sites"; : >"$SITES"
  _t36_mk_awkp "$_t36_acq" "$_t36_awkp" || _C_nm="$_C_nm awk-parser-no-extraible"
  for loc in $_t36_host; do
    _t36_discover "$WORK/t36-s1.log" "$GATE_LIB" "titular_vigente '$_t36_flock' 100" "$SITES" "$loc"
    _t36_discover "$WORK/t36-s2.log" "$GATE_LIB" "intake_slot '$_t36_flock' M3 100" "$SITES" "$loc"
    _t36_discover "$WORK/t36-s3.log" "$_t36_idc" "identidad_canonica '$_t36_classf' M3 42 2026-01-01T00:00:00Z $_t36_N2 deadbeef" "$SITES" "$loc"
    [ -s "$_t36_awkp" ] && _t36_discover "$WORK/t36-s4.log" "" "bash '$_t36_awkp'" "$SITES" "$loc"
  done
  # backstop bash: toda funcion con =~ real en GATE_LIB+idc debe estar entre las descubiertas
  local disc_fns; disc_fns="$(awk -F'\037' '$1=="BASH"{print $2}' "$SITES" | sort -u)"
  for f in $(_t36_fns_con_cmp "$GATE_LIB"; _t36_fns_con_cmp "$_t36_idc"); do
    grep -qx -- "$f" <<<"$disc_fns" || _C_nm="$_C_nm no-ejercida:$f"
  done
  # (B-01) backstop bash a nivel de SITIO: toda LINEA estatica con =~ (fn:linea) debe estar entre las
  # descubiertas. BASH_LINENO de la traza = linea del fichero sourceado, asi que fn:linea estatico
  # casa con fn:linea descubierto. Una linea no descubierta = rama no tomada / sitio muerto => rc2.
  local disc_lines sl; disc_lines="$(awk -F'\037' '$1=="BASH"{split($3,a,":"); print $2":"a[1]}' "$SITES" | sort -u)"
  for sl in $(_t36_static_cmp_lines "$GATE_LIB"; _t36_static_cmp_lines "$_t36_idc"); do
    grep -qxF -- "$sl" <<<"$disc_lines" || _C_nm="$_C_nm sitio-no-ejercido:$sl"
  done
  # (B-01, v31) clave por SITIO: ninguna linea de comparador puede llevar >1 `=~` (colisiona la clave).
  local ml
  for ml in $(_t36_multi_cmp_lines "$GATE_LIB"; _t36_multi_cmp_lines "$_t36_idc"); do
    _C_nm="$_C_nm multi-cmp-en-linea:$ml"
  done
  # backstop conteo awk: sitios awk estaticos de titularidad vs descubiertos por ejecucion
  local awk_stat awk_disc grep_stat grep_disc
  awk_stat=$(( $(_t36_cnt_awk "$_t36_acq") ))
  awk_disc="$(awk -F'\037' '$1=="SUB" && ($2=="awk"||$2=="gawk"||$2=="mawk"){c++} END{print c+0}' "$SITES")"
  [ "$awk_stat" -gt 0 ] && [ "$awk_disc" -eq 0 ] && _C_nm="$_C_nm awk-estatico-no-descubierto(stat=$awk_stat)"
  grep_stat=$(( $(awk '{l=$0;sub(/[[:space:]]+#[[:space:]].*/,"",l)} l ~ /^[[:space:]]*#/{next} l ~ /grep/ && l ~ /(-[A-Za-z]*E[A-Za-z]*|--extended-regexp)/ && l ~ /RE_[A-Z]/{c++} END{print c+0}' "$GATE_LIB") ))
  grep_disc="$(awk -F'\037' '$1=="SUB" && ($2=="grep"||$2=="egrep"){c++} END{print c+0}' "$SITES")"
  [ "$grep_stat" -gt 0 ] && [ "$grep_disc" -lt "$grep_stat" ] && _C_nm="$_C_nm grep-estatico-no-descubierto(stat=$grep_stat disc=$grep_disc)"
  # MEDIR cada sitio BASH descubierto (aislado por clave linea:seq)
  while IFS=$'\x1f' read -r _t _fn _key _loc _tok; do
    [ "$_t" = BASH ] || continue
    local m; m="$(_t36_measure_bash "$_loc" "$_tok")"
    case "$m" in COVERED) : ;; NOPROBE) _C_nm="$_C_nm nomedido:$_fn:$_key($_tok)";; UNCOVERED*) _C_unc="$_C_unc $_fn:$_key$m";; esac
  done < "$SITES"
  # MEDIR sitios SUB: awk por LC_ALL efectivo (mawk byte-orientado -> C efectivo = ground truth);
  # grep-ERE por comportamiento (glibc colaciona)
  while IFS=$'\x1f' read -r _t _bin _loc _argv _rl; do
    [ "$_t" = SUB ] || continue
    case "$_bin" in
      # (B-01) FORMA-AGNOSTICO por el OPERADOR, no por el reconocimiento del patron: un awk DESCUBIERTO
      # con `~` en cualquier forma (`$0~r`, `-v r=`, con o sin espacio) es un comparador; solo el `~ `
      # con espacio O `RE_` en argv NUNCA fue completo (v29). Se exige C efectivo; fuera de C => UNCOVERED.
      awk|gawk|mawk) case "$_argv" in *'~'*|*RE_*) [ "$_loc" = C ] || _C_unc="$_C_unc awk@$_loc:no-C";; *) : ;; esac ;;
      # (B-01) grep-ERE DESCUBIERTO: el LOCALE EFECTIVO decide, no el sondeo del patron. Bajo C efectivo
      # es semantica de bytes (seguro); fuera de C glibc colaciona => UNCOVERED, aunque la regex sea una
      # forma equivalente NO sondeable (antes NOPROBE se descartaba como COVERED — ese era el agujero).
      grep|egrep) case "$_argv" in *-*E*|*--extended-regexp*)
          [ "$_loc" = C ] || _C_unc="$_C_unc grep@$_loc:no-C(argv:$_argv)" ;;
        esac ;;
    esac
  done < "$SITES"
  [ -n "${_C_nm// }" ] && return 2
  [ -n "${_C_unc// }" ] && return 1
  return 0; }

_t36_mkshim
_t36_census_rc; _t36_rc=$?
case "$_t36_rc" in
  0) echo "  ✓ censo COMPLETO por EJECUCION: bash =~ (clave unica linea:seq, incl. TERMINAL) + awk (shim) + grep de las fuentes reales, todos bajo C efectivo"; pass=$((pass+1));;
  1) echo "  ✗ censo (rc1): comparaciones de titularidad FUERA de C:$_C_unc"; fail=$((fail+1));;
  2) echo "  ✗ NO MEDIDO (rc2):$_C_nm — falla cerrado, jamas verde"; nomedido=$((nomedido+1));;
esac

# ================= CONTROLES (mutante causal; DESCUBREN/EJERCEN la ruta real) =================
if [ -n "${_t36_host// }" ]; then
_t36_cp=0; _t36_cf=0
_t36_ok(){ echo "  ✓ $1"; pass=$((pass+1)); }; _t36_kf(){ echo "  ✗ $1"; fail=$((fail+1)); }

# (b-grepvar) grep guardado en VARIABLE, sin C -> el shim lo VE por ejecucion y lo mide UNCOVERED
_fxv="$WORK/t36-fx-grepvar.sh"; printf 'comp_grepvar(){ local g=grep; printf "%%s" "$1" | "$g" -qE "$TM_RE_ARCHIVO"; }\n' > "$_fxv"
_S="$WORK/t36-c1"; : >"$_S"; for loc in $_t36_host; do _t36_discover "$WORK/t36-c1.log" "$GATE_LIB,$_fxv" "comp_grepvar f.sql" "$_S" "$loc"; done
_seen=$(awk -F'\037' '$1=="SUB"&&$2=="grep"{c++}END{print c+0}' "$_S"); _unc=0
while IFS=$'\x1f' read -r t bin loc argv rl; do [ "$t" = SUB ]||continue; m="$(_t36_measure_grep "$loc" "$argv")"; case "$m" in UNCOVERED*) _unc=$((_unc+1));; esac; done < "$_S"
{ [ "$_seen" -ge 2 ] && [ "$_unc" -ge 2 ]; } && _t36_ok "control(b-grepvar): grep en variable sin C -> shim lo VE (x$_seen) y mide UNCOVERED (x$_unc)" || _t36_kf "control(b-grepvar): seen=$_seen unc=$_unc"

# (b-cont) `-E` en la LINEA CONTINUADA siguiente, sin C
_fxc="$WORK/t36-fx-cont.sh"; printf 'comp_cont(){ printf "%%s" "$1" | grep -q \\\n  -E "$TM_RE_ARCHIVO"; }\n' > "$_fxc"
_S="$WORK/t36-c2"; : >"$_S"; for loc in $_t36_host; do _t36_discover "$WORK/t36-c2.log" "$GATE_LIB,$_fxc" "comp_cont f.sql" "$_S" "$loc"; done
_seen=$(awk -F'\037' '$1=="SUB"&&$2=="grep"{c++}END{print c+0}' "$_S"); _unc=0
while IFS=$'\x1f' read -r t bin loc argv rl; do [ "$t" = SUB ]||continue; m="$(_t36_measure_grep "$loc" "$argv")"; case "$m" in UNCOVERED*) _unc=$((_unc+1));; esac; done < "$_S"
{ [ "$_seen" -ge 2 ] && [ "$_unc" -ge 2 ]; } && _t36_ok "control(b-cont): -E en linea continuada sin C -> shim lo VE (x$_seen) y mide UNCOVERED (x$_unc)" || _t36_kf "control(b-cont): seen=$_seen unc=$_unc"

# (b-awkv) awk que recibe el patron por `-v r=`, sin C -> shim lo VE, LC_ALL efectivo != C
_fxa="$WORK/t36-fx-awkv.sh"; printf 'comp_awkv(){ printf "%%s\\n" "$1" | awk -v r="$TM_RE_EST" %s$0 ~ r{f=1} END{exit !f}%s; }\n' "'" "'" > "$_fxa"
_S="$WORK/t36-c3"; : >"$_S"; for loc in $_t36_host; do _t36_discover "$WORK/t36-c3.log" "$GATE_LIB,$_fxa" "comp_awkv '[M3]'" "$_S" "$loc"; done
_seen=$(awk -F'\037' '$1=="SUB"&&($2~/awk/){c++}END{print c+0}' "$_S"); _nonC=$(awk -F'\037' '$1=="SUB"&&($2~/awk/)&&$3!="C"{c++}END{print c+0}' "$_S")
{ [ "$_seen" -ge 2 ] && [ "$_nonC" -ge 2 ]; } && _t36_ok "control(b-awkv): awk -v r= sin C -> shim lo VE (x$_seen), LC_ALL efectivo != C (x$_nonC) -> UNCOVERED" || _t36_kf "control(b-awkv): seen=$_seen nonC=$_nonC"

# (c-samepos) DOS comparadores en la MISMA POSICION -> DOS mediciones aisladas por clave distinta (no colapsan)
_fx2="$WORK/t36-fx-samepos.sh"; printf 'dos_slot(){ [[ "$1" =~ $TM_RE_SLOT ]] && [[ "$1" =~ $TM_RE_SLOT ]]; }\n' > "$_fx2"
_S="$WORK/t36-c4"; : >"$_S"; _t36_discover "$WORK/t36-c4.log" "$GATE_LIB,$_fx2" "dos_slot 100" "$_S" "en_US.utf8"
_nk=$(awk -F'\037' '$1=="BASH"&&$2=="dos_slot"{print $3}' "$_S" | sort -u | wc -l)
[ "$_nk" -eq 2 ] && _t36_ok "control(c-samepos): dos comparadores en \$1 -> $_nk mediciones por clave unica distinta (aisladas, no re-ejecutan la funcion sobre una posicion compartida)" || _t36_kf "control(c-samepos): claves distintas=$_nk (esperado 2)"

# (d-devnull) _t36_acq=/dev/null -> el censo REAL devuelve rc2 (fixture invalido)
_t36_save="$_t36_acq"; _t36_acq=/dev/null; _t36_census_rc; _rcd=$?; _t36_acq="$_t36_save"
[ "$_rcd" -eq 2 ] && _t36_ok "control(d-devnull): _t36_acq=/dev/null -> el censo REAL devuelve rc 2 (insumo invalido, jamas verde)" || _t36_kf "control(d-devnull): rc=$_rcd (esperado 2)"

# (d-empty) _t36_rec01 vacio -> rc2
_t36_save="$_t36_rec01"; : > "$WORK/t36-empty.sh"; _t36_rec01="$WORK/t36-empty.sh"; _t36_census_rc; _rce=$?; _t36_rec01="$_t36_save"
[ "$_rce" -eq 2 ] && _t36_ok "control(d-empty): _t36_rec01 vacio -> rc 2 (insumo validado no-vacio + ancla)" || _t36_kf "control(d-empty): rc=$_rce (esperado 2)"

# (d-nolocales) sin locales hostiles -> el censo REAL devuelve rc2 (ejercido, no un subshell artificial)
( _t36_host=""; _t36_census_rc; exit $? ); _rcn=$?
[ "$_rcn" -eq 2 ] && _t36_ok "control(d-nolocales): sin locales hostiles -> el censo REAL devuelve rc 2 (ejercido)" || _t36_kf "control(d-nolocales): rc=$_rcn (esperado 2)"

# (d-awkmut) parser awk sin prefijo LC_ALL=C -> la MEDICION lo caza (awk descubierto fuera de C) -> no verde
_t36_save="$_t36_acq"; _t36_mutacq="$WORK/t36-acq-mut.sh"; sed 's/LC_ALL=C awk /awk /' "$_t36_acq" > "$_t36_mutacq"; _t36_acq="$_t36_mutacq"
_t36_census_rc; _rcm=$?; _t36_acq="$_t36_save"
[ "$_rcm" -ne 0 ] && _t36_ok "control(d-awkmut): parser awk sin prefijo C -> el censo REAL sale rc=$_rcm (no verde; awk descubierto fuera de C por la medicion)" || _t36_kf "control(d-awkmut): rc=$_rcm (esperaba no-cero)"

# (d-lyingshim) shim NO DISCRIMINANTE (registra C siempre, aunque el hijo corra hostil) -> el censo REAL
# exige rc2: el instrumento que es la UNICA evidencia del LC_ALL efectivo de awk esta comprometido y no
# puede certificar (M-01). El control versionado anterior (d-awkmut) solo probaba con el shim SANO.
_t36_mkshim_orig="$(declare -f _t36_mkshim)"
_t36_mkshim() { local d="$WORK/t36-shim"; mkdir -p "$d"; local rg ra b real
  rg="$(command -v grep)"; ra="$(command -v awk)"
  for b in grep egrep awk gawk mawk; do case "$b" in grep) real="$rg";; egrep) real="$rg -E";; *) real="$ra";; esac
    printf '#!/usr/bin/env bash\nprintf '\''SUB\\x1f%%s\\x1f%%s\\x1f%%s\\n'\'' "%s" "C" "$*" >>"$SHIMLOG"\nexec %s "$@"\n' "$b" "$real" > "$d/$b"
    chmod +x "$d/$b"; done; }
_t36_mkshim   # instala el shim mentiroso
_t36_census_rc; _rcls=$?
eval "$_t36_mkshim_orig"; _t36_mkshim   # restaura el shim sano para los controles siguientes
[ "$_rcls" -eq 2 ] && _t36_ok "control(d-lyingshim): shim que registra C para un hijo hostil -> censo REAL rc 2 (instrumento no acreditado, NO MEDIDO; jamas verde)" || _t36_kf "control(d-lyingshim): rc=$_rcls (esperado 2)"

# (e-newfn) una funcion de titularidad que NINGUN entry point ejercita -> rc2 (fail-closed ante lo no probado)
_t36_save="$GATE_LIB"; _t36_gplus="$WORK/t36-gate-plus.sh"; cp "$GATE_LIB" "$_t36_gplus"
printf '\nnueva_titularidad(){ [[ "$1" =~ $TM_RE_SLOT ]]; }\n' >> "$_t36_gplus"; GATE_LIB="$_t36_gplus"
_t36_census_rc; _rcx=$?; case "$_C_nm" in *no-ejercida:nueva_titularidad*) _hit=1;; *) _hit=0;; esac; GATE_LIB="$_t36_save"
{ [ "$_rcx" -eq 2 ] && [ "$_hit" -eq 1 ]; } && _t36_ok "control(e-newfn): funcion de titularidad NO ejercida por ningun entry point -> rc 2 (descubierta estatica, NO medida por ejecucion => fail-closed)" || _t36_kf "control(e-newfn): rc=$_rcx hit=$_hit"

# (f-oneline) local LC_ALL=C; [[ =~ ]] en la apertura -> COVERED (captura C efectivo; sin regresion v25)
_fxo="$WORK/t36-fx-oneline.sh"; printf 'oneline_conC(){ local LC_ALL=C; [[ "[${1:-}]" =~ $TM_RE_EST ]] || return 1; }\n' > "$_fxo"
_S="$WORK/t36-c5"; : >"$_S"; _cov=1; for loc in $_t36_host; do _t36_discover "$WORK/t36-c5.log" "$GATE_LIB,$_fxo" "oneline_conC M3" "$_S" "$loc"; done
while IFS=$'\x1f' read -r t fn key loc tok; do [ "$t" = BASH ]||continue; m="$(_t36_measure_bash "$loc" "$tok")"; [ "$m" = COVERED ] || _cov=0; done < "$_S"
_nb=$(awk -F'\037' '$1=="BASH"{c++}END{print c+0}' "$_S")
{ [ "$_cov" -eq 1 ] && [ "$_nb" -ge 1 ]; } && _t36_ok "control(f-oneline): local LC_ALL=C; [[ =~ ]] -> COVERED (captura C efectivo; sin regresion del falso positivo v25)" || _t36_kf "control(f-oneline): cov=$_cov sitios=$_nb"

fi   # fin controles (locales hostiles presentes)

echo "== T27: el ratchet de T23 tiene que acreditar LA ESCRITURA DEL DATO, no la aparición de la"
echo "   PALABRA. Hoy basta con nombrar RUN_LINE en un comentario de cola, o con escribir la cadena"
echo "   literal \"RUN_LINE\", para que una receta que NO publica el token se dé por acreditada =="
# Fixtures FUERA de $SKILLROOT (la huella de entradas mide el congelado; escribir dentro lo
# invalidaría). Cada fixture es una receta que MERGEA y que no está acotada, así que la única
# razón para no ser infractora es haber acreditado la adquisición.
FIXR="$WORK/t27-fixtures"; mkdir -p "$FIXR/references"
fix_t27() {  # $1 = nombre · $2 = línea de adquisición · $3 = 'con-flock' | 'sin-flock'
  local f="$FIXR/references/$1.md"
  { printf '# fixture %s\n\n```bash\n' "$1"
    [ "$3" = "con-flock" ] && printf 'flock -x 9\n'
    printf '%s\n' "$2"
    printf 'gh pr merge 42 --squash\n```\n'
  } > "$f"
}
#            nombre            línea de adquisición                                    flock
fix_t27 a-expansion-real    'printf "%s\n" "$RUN_LINE" >&9'                            con-flock
fix_t27 b-expansion-llaves  'printf "%s\n" "${RUN_LINE}" >&9'                          con-flock
fix_t27 c-comentario        'printf "%s\n" "$OTRA_COSA" >&9   # no es RUN_LINE'        con-flock
fix_t27 d-literal           'printf "%s\n" "RUN_LINE" >&9'                             con-flock
fix_t27 e-diagnostico       'echo "APPLY-RUN: reclamando el gate..." >&2'              con-flock
fix_t27 f-sin-flock         'printf "%s\n" "$RUN_LINE" >&9'                            sin-flock
: > "$FIXR/SKILL.md"
# scan_fences lee $SKILLROOT al invocarse: se le da el árbol de fixtures en un SUBSHELL para no
# tocar la variable que usan T23/T24 después.
t27_off="$( SKILLROOT="$FIXR" scan_fences offenders )"
t27_ck() {  # $1 = fixture · $2 = INFRACTORA|ACREDITADA · $3 = por qué importa
  local got=ACREDITADA
  grep -q -- "/$1\.md:" <<<"$t27_off" && got=INFRACTORA
  if [ "$got" = "$2" ]; then echo "  ✓ $1 -> $got · $3"; pass=$((pass+1))
  else echo "  ✗ $1 -> $got (esperado $2) · $3"; fail=$((fail+1)); fi
}
# Controles POSITIVOS: la receta real publica con `printf … "$RUN_LINE" >&9`. Un arreglo que la
# vuelva infractora habría arreglado contra el fixture y roto el sujeto.
t27_ck a-expansion-real   ACREDITADA "control: es como está escrita la receta real (§8.0)"
t27_ck b-expansion-llaves ACREDITADA "control: \${RUN_LINE} es la MISMA escritura del dato"
# LOS DOS QUE MUERDEN (par de ch47, reproducidos con el awk del sujeto).
t27_ck c-comentario       INFRACTORA "escribe OTRA variable; solo NOMBRA RUN_LINE en un comentario"
t27_ck d-literal          INFRACTORA "escribe la CADENA \"RUN_LINE\", no el token que lleva"
# Controles NEGATIVOS: los dos términos que YA discriminaban tienen que seguir discriminando.
t27_ck e-diagnostico      INFRACTORA "control de no-regresión: volcar a >&2 no es publicar en el bus"
t27_ck f-sin-flock        INFRACTORA "control de no-regresión: sin flock no hay adquisición"

echo "== T28: la RUTA APAGADA no puede seguir PRESCRIBIÉNDOSE. La guarda fail-closed existe y se"
echo "   queda; lo que sobra es la frase de al lado, que sigue diciendo cómo operar la vía apagada."
echo "   La pregunta del revisor no era si la guarda está, sino si el texto la prescribe =="
# El bloque CANDADO —las citas LITERALES de la ley en ref 10, marcadas como blockquote— queda
# EXENTO: si algún día la ley dijera la frase, se cita como está y no se reescribe.
T28_ERE='sin (repetir|volver a correr|correr de nuevo) (la |su )?suites?'
t28_prescribe() {  # $1 = raíz a inspeccionar. Imprime fichero:línea por cada prescripción viva.
  local raiz="$1" f
  for f in "$raiz"/SKILL.md "$raiz"/references/*.md; do
    [ -f "$f" ] || continue
    if [ "$(basename "$f")" = "10-estaciones-en-paralelo.md" ]; then
      grep -nE "$T28_ERE" "$f" | grep -v '^[0-9]*:[[:space:]]*>' | sed "s|^|$f:|"
    else
      grep -nE "$T28_ERE" "$f" | sed "s|^|$f:|"
    fi
  done
  return 0
}
t28_vivas="$(t28_prescribe "$SKILLROOT")"
t28_n="$(printf '%s' "$t28_vivas" | grep -c . || true)"
if [ "$t28_n" -eq 0 ]; then
  echo "  ✓ ninguna prescripción viva de la vía apagada fuera del candado de la ley"; pass=$((pass+1))
else
  echo "  ✗ $t28_n prescripciones de la vía apagada siguen escritas como instrucción:"
  printf '%s\n' "$t28_vivas" | sed 's/^/      /'; fail=$((fail+1))
fi
# CONTROL POSITIVO: el buscador tiene que ENCONTRAR. Un arreglo que reescriba la ERE hasta que no
# case con nada dejaría el 28a en verde sin haber tocado el texto.
T28FIX="$WORK/t28-fixtures"; mkdir -p "$T28FIX/references"
{ echo 'las piezas disjuntas se funden una tras otra sin repetir suites'
  echo 'entran sin volver a correr la suite'
  echo 'se funden sin correr de nuevo su suite'; } > "$T28FIX/references/prescribe.md"
: > "$T28FIX/SKILL.md"
t28_semilla="$(t28_prescribe "$T28FIX" | grep -c . || true)"
if [ "$t28_semilla" -eq 3 ]; then
  echo "  ✓ control positivo: el buscador caza las tres formas de la prescripción"; pass=$((pass+1))
else
  echo "  ✗ control positivo: el buscador solo caza $t28_semilla de 3 formas sembradas"; fail=$((fail+1))
fi
# CONTROL NEGATIVO: la GUARDA no puede caer en la red. Una ERE tan ancha que obligara a borrar el
# fail-closed sería peor que el defecto: dejaría el texto sin la única línea que lo apaga.
{ echo 'el batching esta DESACTIVADO; CADA PR corre su suite COMPLETA sobre su propio head'
  echo 'lo que sigue describe la ventana, no autoriza saltarse una suite'
  echo 'el comentario de abajo describe la ventana, no autoriza ahorrarse una suite'; } \
  > "$T28FIX/references/guarda.md"
rm -f "$T28FIX/references/prescribe.md"
t28_guarda="$(t28_prescribe "$T28FIX" | grep -c . || true)"
if [ "$t28_guarda" -eq 0 ]; then
  echo "  ✓ control negativo: la guarda fail-closed NO cae en la red (no hay que borrarla)"
  pass=$((pass+1))
else
  echo "  ✗ control negativo: la red se come $t28_guarda líneas de la propia guarda"; fail=$((fail+1))
fi

echo "== RULING CEO: un gap ESCALAR se recupera SOLO con GO EXPLICITO del CEO/Orquestador =="
# LO QUE MEDI ANTES DE ESCRIBIR ESTO, porque corrige el diagnostico del revisor: el resolvedor YA
# bloquea en ESCALAR — `estado = ($7=="TRANSITORIO") ? "ROTO_T" : "ROTO_E"`, y un `APPLY-RUN` sobre
# `ROTO_E` cae en `bloq(...)`. **Lo que dice lo contrario es la TABLA de ref 01** («el gate se libera
# mecanicamente»). El texto y el ejecutable no dicen lo mismo, y el que esta bien es el ejecutable.
#
# LO QUE SI FALTA, y es lo que el ruling cierra: `APPLY-RECOVERS` exige `$7 == gest`, o sea que **la
# MISMA estacion cuyo apply dejo el estado remoto incierto se autoriza a si misma a reintentar**. La
# prosa manda escalar al CEO/Orquestador; el contrato ejecutable no pide ninguna acreditacion. Una
# autorizacion que se concede el propio interesado no es una autorizacion.
#
# CONTRATO: un token publicado por el CEO/Orquestador y NUNCA por una estacion, exigido ANTES de
# admitir el `APPLY-RECOVERS` que cita ese gap:
#
#     # APPLY-ESCALAR-GO #<PR-fallido> <nonce-fallido> [<CEO|Orquestador>] <ISO8601>
#
# LIMITE DEL ARNES, DECLARADO EN VEZ DE DISIMULADO — y por eso este bloque tiene DOS asertos y no
# cinco. `acq_case` solo devuelve MERGE/NO-MERGE: **no dice POR QUE**. Escribi primero los cinco
# casos y dos pasaban por el motivo equivocado (la estacion del arnes no era la autorizada), y el
# caso «con GO del CEO SI autoriza» es **inalcanzable**: tras un `APPLY-RECOVERS` el estado queda
# `AUTORIZADO` para una identidad CONCRETA (`#78` + su nonce) que el arnes no puede reproducir,
# porque genera la suya. Un oraculo que exigiera ese verde mandaria al canal a perseguir algo
# imposible. **Lo que falta para poder medirlo es OBSERVABILIDAD del resolvedor** (que publique su
# `estado`, o un modo seco que lo imprima); eso es parte del encargo, no un adorno.
# CONTROL (verde hoy, se queda como no-regresion): sin RECOVERS el gap sigue roto.
acq_ck "ESCALAR sin nada mas: el gap sigue roto"  ok "$FAILED_ESCALAR" "NO-MERGE LOCK"
# EL ROJO: la tabla de ref 01 no puede seguir diciendo que APPLY-FAILED libera el gate
# mecanicamente cuando el ejecutable NO lo libera. Un resumen que contradice al codigo se copia y
# se opera; y es el mismo texto que hizo que una revision externa lo clasificara como CRITICAL.
# NOTA DE METODO, aprendida en este mismo bloque: la primera version de este aserto llamaba a
# `ok`, que es el helper de OTRA suite y aqui NO EXISTE. El shell decia «orden no encontrada» por
# stderr, el aserto NO se ejecutaba, y la suite seguia publicando **0 FAIL**. Un aserto que no corre
# no se distingue de uno que pasa — la clase de toda la noche, dentro del bloque escrito para
# cerrarla. Se usa el idiom LOCAL (pass/fail), y ademas se comprueba que el sujeto es legible: si
# `$REF01` no se pudiera leer, `grep -c` daria 0 y eso NO es «la frase ya no esta».
_ref01_n="$(grep -c 'el gate se libera mecánicamente' "$REF01")"; _ref01_rc=$?
if [ "$_ref01_rc" -ge 2 ]; then
  echo "  ✗ NO SE PUEDE MEDIR: no se pudo leer $REF01 (rc $_ref01_rc)"; fail=$((fail+1))
elif [ "${_ref01_n:-1}" -eq 0 ]; then
  echo "  ✓ la tabla de ref 01 ya no dice que APPLY-FAILED libera el gate mecanicamente"; pass=$((pass+1))
else
  echo "  ✗ la tabla de ref 01 sigue diciendo que el gate se libera mecanicamente ($_ref01_n vez/veces),"
  echo "    y el resolvedor NO lo libera: el resumen contradice al ejecutable"; fail=$((fail+1))
fi
# CONTROL del propio buscador: sobre un texto que SI lleva la frase tiene que contarla. Sin esto,
# un dia que la frase cambie de redaccion el aserto quedaria verde por no encontrar nada.
_ctl="$WORK/ref01-control.md"; printf 'x el gate se libera mecánicamente x\n' > "$_ctl"
if [ "$(grep -c 'el gate se libera mecánicamente' "$_ctl")" = "1" ]; then
  echo "  ✓ CONTROL: el buscador SI encuentra la frase cuando esta"; pass=$((pass+1))
else
  echo "  ✗ CONTROL: el buscador no encuentra la frase ni cuando esta: no mide nada"; fail=$((fail+1))
fi


echo "== ORACULO M2 (ronda 30): la acreditacion del GO tiene que estar MEDIDA, no solo escrita =="
# POR QUE EXISTE ESTE BLOQUE, y lo MEDI antes de escribirlo. El arreglo de [B] es correcto: el
# resolvedor ya exige `APPLY-ESCALAR-GO` antes de admitir un `APPLY-RECOVERS`. Pero le quite al
# resolvedor esa unica linea —`if (!go_ok) bloq(...)`— en una COPIA del arbol y la suite entera
# siguio en **246 PASS / 0 FAIL**. El mutante SOBREVIVE.
#
# El motivo no es un descuido del canal: el fixture `RECUP_COMPLETA` se actualizo para LLEVAR el GO,
# y hacia falta —codificaba el contrato ANTERIOR—, pero al moverlo se quedo cubierto SOLO el camino
# positivo. El caso negativo, que es justo el que el ruling crea, no lo mide nadie.
#
# **Un arreglo que nadie puede ver desaparecer no esta protegido: esta de suerte.** Es la misma
# forma que el `set` lejano de PR-B y que la lista truncada con rc 1 — el sistema se porta bien hoy
# y nada avisaria el dia que deje de hacerlo.
#
# EL PAR ES EL INSTRUMENTO: dos secuencias identicas salvo UNA linea. Si las dos dieran el mismo
# veredicto, el aserto no mediria el GO sino cualquier otra cosa del camino.
RECUP_SIN_GO="$AJENO"'# APPLY-FAILED [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011 ESCALAR
# APPLY-RECOVERS #77 00000000-0000-4000-8000-000000000011 #78 00000000-0000-4000-8000-000000000016 [M4]
# APPLY-RUN [M4] #78 2026-01-01T00:10:00Z 00000000-0000-4000-8000-000000000016
# APPLY-DONE [M4] #78 2026-01-01T00:10:00Z 00000000-0000-4000-8000-000000000016
'
acq_ck "sin GO del CEO, un gap ESCALAR NO se recupera solo" \
       ok "$RECUP_SIN_GO" "NO-MERGE LOCK"
acq_ck "CONTROL DEL PAR: la MISMA secuencia CON el GO si libera el gate" \
       ok "$RECUP_COMPLETA" "MERGE LOCK"

# EL CORAZON DEL RULING: una autorizacion que se concede el propio interesado no es una
# autorizacion. `RE_GO` (CEO|Orquestador) y `RE_EST` (M1-M5) son disjuntos POR CONSTRUCCION, y esto
# lo comprueba en vez de confiarlo.
RECUP_GO_DE_ESTACION="$AJENO"'# APPLY-FAILED [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011 ESCALAR
# APPLY-ESCALAR-GO #77 00000000-0000-4000-8000-000000000011 [M4] 2026-01-01T00:05:00Z
# APPLY-RECOVERS #77 00000000-0000-4000-8000-000000000011 #78 00000000-0000-4000-8000-000000000016 [M4]
# APPLY-RUN [M4] #78 2026-01-01T00:10:00Z 00000000-0000-4000-8000-000000000016
'
acq_ck "un GO firmado por la ESTACION del gap no autoriza nada" \
       ok "$RECUP_GO_DE_ESTACION" "NO-MERGE LOCK"

# Un GO generico autorizaria cualquier gap posterior: tiene que citar ESTE, por identidad.
RECUP_GO_OTRO_GAP="$AJENO"'# APPLY-FAILED [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011 ESCALAR
# APPLY-ESCALAR-GO #99 00000000-0000-4000-8000-000000000014 [CEO] 2026-01-01T00:05:00Z
# APPLY-RECOVERS #77 00000000-0000-4000-8000-000000000011 #78 00000000-0000-4000-8000-000000000016 [M4]
# APPLY-RUN [M4] #78 2026-01-01T00:10:00Z 00000000-0000-4000-8000-000000000016
'
acq_ck "un GO que no cita ESTE gap no lo autoriza" \
       ok "$RECUP_GO_OTRO_GAP" "NO-MERGE LOCK"

# Y no viaja en el tiempo: un GO ya consumido no puede autorizar el gap SIGUIENTE. Es la misma
# clase que el nonce cierra en la sucesion — cuenta la generacion, no el nombre.
GO_GASTADO="$AJENO"'# APPLY-FAILED [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011 ESCALAR
# APPLY-ESCALAR-GO #77 00000000-0000-4000-8000-000000000011 [CEO] 2026-01-01T00:05:00Z
# APPLY-RECOVERS #77 00000000-0000-4000-8000-000000000011 #78 00000000-0000-4000-8000-000000000016 [M4]
# APPLY-RUN [M4] #78 2026-01-01T00:10:00Z 00000000-0000-4000-8000-000000000016
# APPLY-FAILED [M4] #78 2026-01-01T00:10:00Z 00000000-0000-4000-8000-000000000016 ESCALAR
# APPLY-RECOVERS #78 00000000-0000-4000-8000-000000000016 #79 00000000-0000-4000-8000-000000000007 [M4]
'
acq_ck "un GO ya consumido no autoriza el gap POSTERIOR" \
       ok "$GO_GASTADO" "NO-MERGE LOCK"

# — LA RAZON, NO SOLO EL VEREDICTO. Los cuatro rojos de arriba son `NO-MERGE LOCK`, y ese veredicto
#   NO dice por que: «bloqueado porque falta el GO» y «bloqueado porque el gap sigue roto» se ven
#   IGUAL. Ya me pasó en este mismo fichero —dos asertos que pasaban por el motivo equivocado—, y
#   entonces declaré que faltaba OBSERVABILIDAD del resolvedor. El canal la ha construido en esta
#   ronda (`TM_GATE_DRY=1` publica `# GATE-ESTADO … go=…` por stderr), asi que el caso deja de ser
#   inalcanzable y se mide. `acq_ck` corre `acq_case` en una SUSTITUCION —subshell—, asi que
#   `ACQ_LAST_BOX` no llegaria hasta aqui: se usa el idiom de `acq_u`, llamada directa.
_go_dry() {   # $1=log inicial → imprime la linea GATE-ESTADO del stderr real, o vacio
  TM_GATE_DRY=1 acq_case ok "$1" M1 >/dev/null
  grep -m1 'GATE-ESTADO' "$ACQ_LAST_BOX/err.log" 2>/dev/null || true
}
_dry_con="$(_go_dry "$RECUP_COMPLETA")"
_dry_sin="$(_go_dry "$RECUP_SIN_GO")"
# CALIBRACION PRIMERO, y por delante del caso que muerde: si el modo seco no publicara nada, los
# dos asertos siguientes compararian cadenas VACIAS y pasarian sin medir nada.
if [ -n "$_dry_con" ] && [ -n "$_dry_sin" ]; then
  echo "  ✓ CALIBRACION: el modo seco publica su estado (si no, lo de abajo no mediria nada)"; pass=$((pass+1))
else
  echo "  ✗ CALIBRACION: TM_GATE_DRY=1 no publico GATE-ESTADO: sin observabilidad no hay razon que medir"
  echo "    con-GO='$_dry_con'  sin-GO='$_dry_sin'"; fail=$((fail+1))
fi
case "$_dry_sin" in
  *"go=0"*) echo "  ✓ sin GO el resolvedor lo dice: go=0 — bloquea por lo que decimos, no por otra cosa"; pass=$((pass+1)) ;;
  *) echo "  ✗ sin GO el estado no reporta go=0 (fue: '$_dry_sin'): el rojo puede venir de otro camino"; fail=$((fail+1)) ;;
esac
case "$_dry_con" in
  *"go=1"*) echo "  ✓ con GO el resolvedor lo acredita: go=1"; pass=$((pass+1)) ;;
  *) echo "  ✗ con GO el estado no reporta go=1 (fue: '$_dry_con'): el verde puede venir de otro camino"; fail=$((fail+1)) ;;
esac


echo "== ORACULO M2 (ronda 30): la independencia de \`date -d\` tambien tiene que estar MEDIDA =="
# EL ARREGLO [A] ES REAL, Y LO MEDI — no de palabra. El canal lo declaro NO MEDIDO porque en su
# contenedor no hay busybox; en el host de la estacion de merge SI lo hay (1.37.0), asi que la
# elevacion se cierra con una medida en vez de con una promesa:
#
#     busybox date -u -d '2026-01-01T00:00:00Z'   ->  «invalid date», rc 1   (un sello VALIDO)
#     GNU     date -u -d '2026-01-01T00:00:00Z'   ->  rc 0
#
#   implementacion VIEJA (con `date -d`) + date de busybox  ->  RECHAZA todo sello valido
#   implementacion NUEVA (aritmetica)     + date de busybox  ->  9 de 9, incluidos 29-feb de 2024,
#                                                               el secular 1900 vs 2000, y los meses
#                                                               08/09 (la trampa del octal)
#
# PERO el arreglo tenia el mismo hueco que [B]: **nada en la suite lo vigila**. Un `date -d` que
# vuelva manana pasaria en verde en cualquier maquina con GNU coreutils —o sea, en todas las
# nuestras— y solo se veria en produccion, dentro de un contenedor, como una indisponibilidad
# total. El escenario `date_sin_d` reproduce Alpine SIN necesitar busybox instalado: un `date` que
# rechaza `-d` y por lo demas es el real.
acq_ck "con un date SIN -d (BusyBox/Alpine) la adquisicion se completa igual" \
       date_sin_d "" "MERGE LOCK"
# CONTROL DEL PROPIO MOCK, delante de lo que muerde: si el stub no rechazara `-d`, el aserto de
# arriba estaria pasando en un entorno GNU corriente y no mediria absolutamente nada.
_bb="$WORK/date-sin-d"; printf '%s\n' '#!/usr/bin/env bash' \
  'for a in "$@"; do [ "$a" = "-d" ] && exit 1; done' 'exec /bin/date "$@"' > "$_bb"; chmod +x "$_bb"
if "$_bb" -u -d '2026-01-01T00:00:00Z' >/dev/null 2>&1; then
  echo "  ✗ CONTROL: el mock ACEPTA -d: no reproduce BusyBox y el aserto de arriba no mide nada"; fail=$((fail+1))
elif ! "$_bb" -u +%Y >/dev/null 2>&1; then
  echo "  ✗ CONTROL: el mock tampoco sabe dar la hora: rompe por un motivo AJENO al que se mide"; fail=$((fail+1))
else
  echo "  ✓ CONTROL: el mock rechaza -d y sigue dando la hora (reproduce BusyBox, no lo rompe todo)"; pass=$((pass+1))
fi


echo "== ORACULO M2 (v15): el GO puede TRANSFERIR la recuperacion, y una recuperacion tiene UN dueno =="
# RULING DEL CEO (13:05:38Z): «SI, el GO del CEO PUEDE TRANSFERIR la recuperacion a otra estacion».
# Forma ampliada y RETROCOMPATIBLE:
#
#     # APPLY-ESCALAR-GO #<PR> <nonce> [CEO|Orquestador] <ISO8601> [-> <estacion>]
#
#   SIN sufijo  -> `APPLY-RECOVERS` se acepta SOLO de la estacion ORIGINAL (`$7 == gest`, como hoy)
#   CON sufijo  -> SOLO de la estacion NOMBRADA, y **deja de aceptarse de la original**
#
# Lo segundo es lo que hay que medir con cuidado: «una recuperacion tiene un dueno, NUNCA dos». Un
# arreglo que solo ANADIERA la estacion nombrada sin RETIRAR a la original dejaria dos dueños
# legitimos para el mismo gap — que es la carrera que todo este gate existe para impedir.
#
# ESTOS ASERTOS NACEN EN ROJO: el contrato es del ruling, el arreglo lo escribe el canal. Hoy el
# resolvedor exige `NF == 6`, asi que un GO con sufijo cae en «fuera de contrato».

# — EL PAR QUE TRANSFIERE. Mismo gap de [M4]; lo unico que cambia es quien firma el RECOVERS.
GO_TRANSFIERE_A_M5="$AJENO"'# APPLY-FAILED [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011 ESCALAR
# APPLY-ESCALAR-GO #77 00000000-0000-4000-8000-000000000011 [CEO] 2026-01-01T00:05:00Z -> M5
# APPLY-RECOVERS #77 00000000-0000-4000-8000-000000000011 #78 00000000-0000-4000-8000-000000000016 [M5]
# APPLY-RUN [M5] #78 2026-01-01T00:10:00Z 00000000-0000-4000-8000-000000000016
# APPLY-DONE [M5] #78 2026-01-01T00:10:00Z 00000000-0000-4000-8000-000000000016
'
acq_ck "GO con '-> M5': la estacion NOMBRADA recupera y el gate queda libre" \
       ok "$GO_TRANSFIERE_A_M5" "MERGE LOCK"

# — LA OTRA MITAD, y es la que impide DOS dueños: transferido a M5, la ORIGINAL ya no vale.
GO_TRANSFERIDO_LA_ORIGINAL_INSISTE="$AJENO"'# APPLY-FAILED [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011 ESCALAR
# APPLY-ESCALAR-GO #77 00000000-0000-4000-8000-000000000011 [CEO] 2026-01-01T00:05:00Z -> M5
# APPLY-RECOVERS #77 00000000-0000-4000-8000-000000000011 #78 00000000-0000-4000-8000-000000000016 [M4]
# APPLY-RUN [M4] #78 2026-01-01T00:10:00Z 00000000-0000-4000-8000-000000000016
# APPLY-DONE [M4] #78 2026-01-01T00:10:00Z 00000000-0000-4000-8000-000000000016
'
# CUIDADO — ESTE ASERTO PASA HOY POR EL MOTIVO EQUIVOCADO, y por eso NO va solo. Hoy da NO-MERGE
# porque el GO con sufijo se rechaza entero («fuera de contrato»); manana tiene que dar NO-MERGE
# porque la transferencia le quito la titularidad a la original. Mismo veredicto, motivos opuestos:
# exactamente el falso verde que ya me colo dos veces en este fichero. La razon se mide abajo.
acq_ck "transferido a M5, la estacion ORIGINAL ya no puede recuperar (un dueno, no dos)" \
       ok "$GO_TRANSFERIDO_LA_ORIGINAL_INSISTE" "NO-MERGE LOCK"

# — RETROCOMPATIBILIDAD, la mitad que no puede romperse al anadir el sufijo.
GO_SIN_SUFIJO_OTRA_ESTACION="$AJENO"'# APPLY-FAILED [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011 ESCALAR
# APPLY-ESCALAR-GO #77 00000000-0000-4000-8000-000000000011 [CEO] 2026-01-01T00:05:00Z
# APPLY-RECOVERS #77 00000000-0000-4000-8000-000000000011 #78 00000000-0000-4000-8000-000000000016 [M5]
# APPLY-RUN [M5] #78 2026-01-01T00:10:00Z 00000000-0000-4000-8000-000000000016
'
acq_ck "SIN sufijo no hay transferencia: otra estacion NO puede recuperar" \
       ok "$GO_SIN_SUFIJO_OTRA_ESTACION" "NO-MERGE LOCK"
# (el cuarto brazo del cuadro —sin sufijo, la original SI recupera— ya lo mide `RECUP_COMPLETA`
#  unas lineas mas arriba: los cuatro juntos son el cuadro completo, no tres casos sueltos.)

# — EL SUFIJO ES UN DATO, Y SE VALIDA POR FORMA. `M9` no es una estacion; `RE_EST` es M1-M5.
GO_SUFIJO_MALFORMADO="$AJENO"'# APPLY-FAILED [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011 ESCALAR
# APPLY-ESCALAR-GO #77 00000000-0000-4000-8000-000000000011 [CEO] 2026-01-01T00:05:00Z -> M9
# APPLY-RECOVERS #77 00000000-0000-4000-8000-000000000011 #78 00000000-0000-4000-8000-000000000016 [M9]
# APPLY-RUN [M9] #78 2026-01-01T00:10:00Z 00000000-0000-4000-8000-000000000016
'
acq_ck "un sufijo que no nombra una estacion real NO autoriza a nadie" \
       ok "$GO_SUFIJO_MALFORMADO" "NO-MERGE LOCK"

# — LA RAZON. Sin esto, tres de los cuatro rojos de arriba son indistinguibles de «el GO no se
#   entendio», que es como pasan HOY. El modo seco ya publica `go=`; el contrato lo AMPLIA con la
#   estacion autorizada, que es el dato que el ruling introduce:
#
#       # GATE-ESTADO estado=… gap=…/… go=… goest=<estacion|->
#
#   `goest=-` cuando no hay transferencia (GO sin sufijo o sin GO); `goest=M5` cuando la hay. Es
#   barato y es lo unico que hace DISTINGUIBLE «rechazado porque el GO no vale» de «rechazado
#   porque el dueno es otro».
_dry_tr="$(_go_dry "$GO_TRANSFIERE_A_M5")"
_dry_ns="$(_go_dry "$RECUP_COMPLETA")"
if [ -n "$_dry_tr" ] && [ -n "$_dry_ns" ]; then
  echo "  ✓ CALIBRACION: el modo seco sigue publicando estado en los dos escenarios"; pass=$((pass+1))
else
  echo "  ✗ CALIBRACION: sin GATE-ESTADO las comprobaciones de razon no miden nada"; fail=$((fail+1))
fi
case "$_dry_tr" in
  *"goest=M5"*) echo "  ✓ con transferencia el estado nombra al dueno: goest=M5"; pass=$((pass+1)) ;;
  *) echo "  ✗ el estado no publica la estacion autorizada (fue: '$_dry_tr'): «GO invalido» y"
     echo "    «el dueno es otro» siguen siendo el MISMO rojo"; fail=$((fail+1)) ;;
esac
case "$_dry_ns" in
  *"goest=-"*) echo "  ✓ sin transferencia el estado lo dice: goest=-"; pass=$((pass+1)) ;;
  *) echo "  ✗ sin transferencia el estado no publica goest=- (fue: '$_dry_ns')"; fail=$((fail+1)) ;;
esac


echo "-- ORACULO M2 (ronda 31): la guarda de propiedad tiene que sobrevivir al \`set -e\` DEL LLAMADOR --"
# MEDIDO ANTES DE ESCRIBIRLO, y es una REGRESION DEL ARREGLO DE LA RONDA 30. El arreglo del hallazgo
# [6] cambio el `if ! flock …` por:
#
#     flock "$FLOCK_FILE" bash -c 'grep -qxF …' _ "$run_line" "$FLOCK_FILE"
#     _rc=$?
#
# Leido a solas, el fichero es correcto. **Pero `apply-gate.sh` no pone `set -e`: lo pone su
# LLAMADOR** —la receta de ref 02, `set -euo pipefail` en su linea 436—. Y ahi ese `flock` es un
# COMANDO DESNUDO: bajo `set -e` un rc≠0 **aborta el shell en esa misma linea**, `_rc=$?` no llega a
# ejecutarse y toda la clasificacion rc1/rc2 que la ronda 30 acaba de anadir es CODIGO MUERTO
# exactamente en los casos para los que existe. Peor: no se publica el cierre y **no se emite el
# aviso de escalada** — el gate se queda tomado en silencio, que es el fallo caro.
#
#     bash -c 'false; _rc=$?; echo llegue'            -> imprime «llegue»
#     bash -c 'set -e; false; _rc=$?; echo llegue'    -> NO imprime nada: aborto
#
# Es la MISMA clase que el `pipefail` de PR-B: correccion que depende de un `set` puesto lejos.
# **El contexto es parte del sujeto.**
#
# TRAMPA DEL PROPIO ORACULO, declarada: `publish_close` NO puede invocarse dentro de un `if` para
# capturar su rc — bash DESACTIVA `errexit` dentro de una funcion llamada en contexto de condicion,
# y el aserto pasaria en verde enmascarando justo el fallo que mide. Se invoca DESNUDA, como en la
# receta, y se observa su MENSAJE por stderr: si el mensaje esta, la guarda llego a clasificar.
_r31="$(mktemp -d)"
_r31_out="$(
  bash -c '
    set -euo pipefail
    . "$1"
    wj="$2"; FLOCK_FILE="$wj/flock" TM_FLOCK_CANONICO_TRUSTED="$wj/flock"; CLASS_FILE="$wj/class"
    printf "%s" "ESCALAR" > "$CLASS_FILE"
    : > "$FLOCK_FILE"                       # RUN AUSENTE a proposito: la guarda debe decir «no es mi turno»
    ESTACION=M3; PR=9999; RUN_ISO=2026-09-02T12:00:00Z; RUN_NONCE=R31-NONCE
    export ESTACION PR RUN_ISO RUN_NONCE FLOCK_FILE CLASS_FILE
    publish_close 1                          # DESNUDA, como en la receta
    echo "POST-LLAMADA"
  ' _ "$CLASSIFIER" "$_r31" 2>&1 || true
)"
if grep -q -- 'publish_close: NO publico cierre' <<<"$_r31_out"; then
  echo "  ✓ bajo \`set -e\` la guarda LLEGA a clasificar y avisa (no muere en el flock)"; pass=$((pass+1))
else
  echo "  ✗ bajo \`set -e\` la guarda NO llego a clasificar: el shell abortó en el flock y el aviso"
  echo "    de escalada NUNCA se emite — el gate se queda TOMADO en silencio"
  echo "    (salida observada: '$(printf '%s' "$_r31_out" | tr '\n' '|' | cut -c1-90)')"; fail=$((fail+1))
fi
# CONTROL DEL ARNES, delante del caso que muerde: con el RUN PRESENTE el mismo montaje SI publica.
# Sin este control, un fallo de montaje (CLASSIFIER vacio, mktemp roto) daria el mismo rojo de arriba
# y mandaria a arreglar `publish_close` cuando lo roto seria el oraculo.
_r31b="$(mktemp -d)"
_r31_ctl="$(
  bash -c '
    set -euo pipefail
    . "$1"
    wj="$2"; FLOCK_FILE="$wj/flock" TM_FLOCK_CANONICO_TRUSTED="$wj/flock"; CLASS_FILE="$wj/class"
    printf "%s" "ESCALAR" > "$CLASS_FILE"
    printf "%s\n" "# APPLY-RUN [M3] #9999 2026-09-02T12:00:00Z R31-NONCE" > "$FLOCK_FILE"
    ESTACION=M3; PR=9999; RUN_ISO=2026-09-02T12:00:00Z; RUN_NONCE=R31-NONCE
    export ESTACION PR RUN_ISO RUN_NONCE FLOCK_FILE CLASS_FILE
    publish_close 1 >/dev/null 2>&1
    tail -n1 "$FLOCK_FILE"
  ' _ "$CLASSIFIER" "$_r31b" 2>/dev/null || true
)"
case "$_r31_ctl" in
  *"APPLY-FAILED [M3] #9999"*) echo "  ✓ CONTROL: con el RUN presente el mismo montaje publica su cierre"; pass=$((pass+1)) ;;
  *) echo "  ✗ CONTROL: el montaje no publica ni con el RUN presente — el oraculo no mide publish_close"
     echo "    (obtenido: '$_r31_ctl')"; fail=$((fail+1)) ;;
esac
rm -rf "$_r31" "$_r31b"


echo "-- ORACULO ch44 (ronda 32): la PROCEDENCIA del flock, no solo su contenido --"
# POR QUE EXISTE: la 1.a pasada de auditoria dio CERO sobre esta guarda con cuatro fixtures
# —dueno / otro / vacio / ausente— y los cuatro corrian sobre LA MISMA RUTA. Eso acredita que la
# guarda distingue TITULARES; no acredita que la ruta sea la canonica. La 2.a pasada pregunto otra
# cosa —«¿quien decide cual es el flock?»— y publico sobre una ruta local arbitraria presentada
# como espejo. **Un ambito estrecho da un CERO FALSO**, y por eso este bloque mide el ORIGEN de la
# entrada, no su contenido.
# `FLOCK_FILE` llega del llamador y decide una EXCLUSION MUTUA: eso no es un parametro, es una
# CREDENCIAL.
# CAJA NUEVA POR CASO. La primera version compartia el fichero canonico entre los cuatro y el
# CONTROL ya publicaba la linea de cierre; la deduplicacion `grep -qxF` —que funciona BIEN— impedia
# la segunda escritura, y el caso del symlink salia rojo POR EL FIXTURE, no por el sujeto. Estado
# compartido entre casos = un rojo que no es del sujeto.
_pf_run='# APPLY-RUN [M4] #77 2026-01-01T00:00:00Z 00000000-0000-4000-8000-000000000011'
_pf_caja() {   # imprime la ruta de una caja recien hecha, con canonico, ajeno y class
  local b; b="$(mktemp -d "$WORK/proc.XXXXXX")"
  printf '%s\n' "$_pf_run" > "$b/flock.log"
  printf '%s\n' "$_pf_run" > "$b/espejo-local.log"
  printf 'TRANSITORIO' > "$b/class"
  ln -sf "$b/flock.log" "$b/enlace"
  printf '%s\n' "$b"
}
# Se invoca en un subshell con `set -euo pipefail` —el mismo contexto que la receta— y se mide el
# rc Y si el fichero CRECIO. El rc solo no basta: lo que hay que impedir es la ESCRITURA.
_pf() {  # $1 = nombre del canonico ('' = sin declarar) · $2 = nombre del fichero que se pasa
  local b antes despues rc canon target
  b="$(_pf_caja)"; canon="${1:+$b/$1}"; target="$b/$2"
  antes="$(wc -l < "$target")"
  ( set -euo pipefail; . "$SKILLROOT/references/apply-gate.sh"
    TM_FLOCK_CANONICO_TRUSTED="$canon"; FLOCK_FILE="$target"; CLASS_FILE="$b/class"; LOG=/dev/null
    ESTACION=M4; PR=77; RUN_ISO=2026-01-01T00:00:00Z; RUN_NONCE=00000000-0000-4000-8000-000000000011
    publish_close 1 ) >/dev/null 2>&1; rc=$?
  despues="$(wc -l < "$target")"
  printf '%s %s' "$rc" "$([ "$despues" -gt "$antes" ] && echo ESCRIBIO || echo NO-ESCRIBIO)"
}
_pf_ck() {  # $1 = descripcion · $2 = esperado · $3.. = args de _pf
  local got; got="$(_pf "$3" "$4")"
  if [ "$got" = "$2" ]; then echo "  ✓ $1 -> $got"; pass=$((pass+1))
  else echo "  ✗ $1 -> $got (esperado $2)"; fail=$((fail+1)); fi
}
# CONTROL POR DELANTE: si la ruta canonica de verdad no publicara, el rojo de abajo vendria del
# montaje y no de la acreditacion — y mandaria a arreglar lo que no esta roto.
_pf_ck "CONTROL: la ruta canonica de verdad SI publica" "0 ESCRIBIO"      flock.log flock.log
_pf_ck "el ATAQUE: ruta local arbitraria como espejo"   "3 NO-ESCRIBIO"   flock.log espejo-local.log
_pf_ck "sin TM_FLOCK_CANONICO_TRUSTED no hay procedencia"       "3 NO-ESCRIBIO"   "" flock.log
# Un symlink AL canonico ES el canonico: se compara por FICHERO (dispositivo+inodo), no por cadena.
# Comparar texto seria medir un proxy del recurso — dos rutas distintas nombran el mismo fichero.
_pf_ck "symlink al canonico: mismo fichero, se acepta"  "0 ESCRIBIO"      flock.log enlace


# La huella viaja JUNTO al resultado: es la línea que se pega en un acta, y pegar un recuento
# sin decir sobre qué contenido se obtuvo es lo que volvió inexplicable la divergencia anterior.
#
# La entrada esta CONGELADA bajo `$WORK`, asi que la huella del principio ya identifica lo que se
# ejecuto: no hace falta comparar dos fotos de un arbol mutable (eso admitia el ABA que reprodujo
# par10-p1). Lo que SI se comprueba es que la suite no se haya pisado a si misma el congelado —
# nadie mas escribe ahi, pero un `cp` mal dirigido de un control futuro si podria—. Fail-closed:
# rc != 0, para que nadie lea como buena una corrida cuyo objeto medido se movio.
HUELLA_FIN="$(huella_de_entradas)" || HUELLA_FIN="<incalculable>"
if [ "$HUELLA_FIN" != "$HUELLA" ]; then
  echo "RESULTADO: $pass PASS / $fail FAIL  ·  huella NO MEDIDA — la suite modifico su propio" \
       "congelado durante la corrida ($HUELLA → $HUELLA_FIN): el recuento no se acredita"
  exit 3
fi
echo "RESULTADO: $pass PASS / $fail FAIL / $nomedido NO-MEDIDO  ·  huella de entradas $HUELLA"
if [ "$nomedido" -gt 0 ]; then exit 2; fi
[ "$fail" -eq 0 ]
