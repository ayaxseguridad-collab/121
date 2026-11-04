# 10 — Estación de guardia de producción (Analista)

> Canoniza la estación que opera desde el 23-ago-2026 por orden directa del lead
> («monta un agente no-fable permanente revisando sentry, que no pare jamás»).
> Doctrina destilada del brief operativo del mando + evidencia real (TAL-4725,
> TAL-4726, sellos del bus del 23-ago). Molde replicado de
> `references/06-carriles-y-recursos.md` / `references/08-perfilado-fichas-y-clonado.md`.

## Table of Contents

1. [Definición y mandato](#1-definición-y-mandato)
2. [Acceso al vendor de observabilidad](#2-acceso-al-vendor-de-observabilidad)
3. [Ciclo operativo](#3-ciclo-operativo)
4. [Taxonomía de sellos](#4-taxonomía-de-sellos)
5. [Verificaciones post-deploy](#5-verificaciones-post-deploy)
6. [Redes de seguridad](#6-redes-de-seguridad)
7. [Checklist de alta de la estación](#7-checklist-de-alta-de-la-estación)
8. [Gotchas (con fecha)](#8-gotchas-con-fecha)

---

> **PUNTERO (TAL-5157/TAL-5448, adaptado 2026-09-08).** El mandato/modelo de la
> figura Sentry (rol, `Sonnet vigente`+`high`, "solo lee/triaje/sella") vive
> ahora, sin duplicar, en `talent-sentry-guard/SKILL.md` §"Límites". La
> **mecánica de la estación en sí** (ticker §3, PARTE por cron, redes de
> seguridad §6, checklist de alta §7, gotchas §8) sigue siendo ESTA
> referencia — TAL-5448 la mantiene y la endurece; TAL-5157 no la duplica ni
> la toca.
>
> **ANULADO EN SU SITIO** (2026-09-02, TAL-5157): el §1 original decía «[...]
> Cuando un hallazgo requiere fix, lo escala [...] para que el CEO decida
> issue + pase a producción — la estación nunca abre PR.» El Vigía
> (`talent-sentry-guard`) **SÍ crea la issue él mismo** para S0-S2 y para el
> chore de curación de ruido — contrato completo en
> `talent-sentry-guard/references/04-contrato-de-issue.md` §"Autoridad".
> Para S3 propone y espera adjudicación (`SENTRY-CONSULTA-*`), nunca crea
> sin ella. Sigue vigente sin cambio: el Vigía NUNCA abre PR ni mergea ni
> cierra issues de Linear.

## 1. Definición y mandato

> **PUNTERO** — la prosa completa (rol, modelo, mandato acotado, relación con
> `references/09-supervision-activa.md`) vive en `talent-sentry-guard/SKILL.md`
> §"Límites" — ver la nota de cabecera de este fichero para el detalle de qué
> se anuló y por qué. No se reproduce aquí para no mantener dos copias.

## 2. Acceso al vendor de observabilidad

Patrón **header-file 0600** (misma postura que `scripts/cr-review.sh` y
`linear-skill`: la credencial nunca entra en argv, nunca se interpola en `-H`):

```bash
# 1. Fichero destino 0600 ANTES de tocar el token — nunca se crea a posteriori.
cfg=$(mktemp); chmod 600 "$cfg"
# 2. Token del vendor DESDE env del hosting, capturado por SUSTITUCIÓN DE COMANDO
#    (jamás una tubería suelta a terminal: $(...) captura stdout, no lo imprime).
TOKEN=$(railway variables --service <svc> --json | jq -r '.SENTRY_AUTH_TOKEN')
# 3. Header-file con SALIDA REDIRIGIDA directa — el token no pasa por ningún
#    comando intermedio que pudiera volcarlo a la terminal.
printf 'Authorization: Bearer %s\n' "$TOKEN" > "$cfg"
unset TOKEN   # el valor ya vive SOLO en $cfg (0600); no queda en el entorno del shell
# 4. Fichero meta APARTE (no en el mismo fichero que el header): org + proyecto
#    del vendor, para no tener que releer el token al armar cada request.
# 5. curl -H @"$cfg" ...   (NUNCA -H "Authorization: Bearer $TOKEN" con el token
#    interpolado directamente — quedaría visible en /proc/pid/cmdline).
```

**MUST — el token jamás se imprime** en pantalla, logs ni sellos del bus. Ningún
sello de la taxonomía (§4) lleva el valor del token ni un fragmento reconocible de
él — solo metadatos (org/proyecto/grupo/conteo). Este documento no incluye ningún
ejemplo con credencial real (ver el secret-gate del DoD que lo verifica).

## 3. Ciclo operativo

El mecanismo del tick es un **ticker infinito** en background que re-invoca al
agente en CADA eco — nunca un despertador one-shot:

```bash
mkdir -p "$HOME/.analista-produccion"
TICK_LOG="$(mktemp "$HOME/.analista-produccion/tick.XXXXXX.log")" \
  || { echo "FALLO: no se pudo crear el log del ticker (mktemp) — abortando alta"; exit 1; }
    # creación ATÓMICA e INCONDICIONAL de un fichero garantizado-único y VACÍO
    # por invocación — NUNCA un fallback "${VAR:-...}" (esa forma REUTILIZA el
    # valor si la variable ya quedó definida en el shell, p.ej. tras un alta
    # previa en la MISMA sesión, reabriendo la carrera).
    # El '|| { ... exit 1; }' es OBLIGATORIO y no decorativo: el procedimiento
    # NO fija errexit (set -e), así que sin esta comprobación EXPLÍCITA un
    # mktemp fallido (disco lleno, dir no escribible) dejaría $TICK_LOG VACÍO y
    # la secuencia CONTINUARÍA — lanzaría y haría disown de un ticker con
    # 'tee -a ""' y solo abortaría ~10s después por el grep, dejando un proceso
    # defectuoso transitorio. La comprobación detiene el alta EN la asignación.
( while true; do echo TICK | tee -a "$TICK_LOG"; sleep 300; done ) &
TICKER_PID=$!
disown
# VERIFICAR arranque real en background: proceso vivo (ps) Y TICK FRESCO — el
# bucle emite el TICK ANTES del sleep (primer eco inmediato, no a los 5 min),
# así que una ESPERA ACOTADA de segundos basta para verlo en el log recién
# vaciado (mktemp ya lo entrega VACÍO). El '[ -s ]' del bucle solo ACELERA la
# salida — NO decide nada por sí mismo (agotar los 20 intentos sin TICK
# termina el 'for' con normalidad):
for _ in $(seq 1 20); do [ -s "$TICK_LOG" ] && break; sleep 0.5; done
# ASERCIÓN FAIL-CLOSED — la que realmente decide: sin esto, un log vacío tras
# el timeout pasaría desapercibido ('tail -1' sobre vacío también sale con
# éxito sin imprimir nada) y el alta APARENTARÍA verificada sin ningún TICK:
grep -q 'TICK' "$TICK_LOG" || { echo "FALLO: ticker no emitió TICK en 10s — abortando alta"; kill "$TICKER_PID" 2>/dev/null; exit 1; }
ps -p "$TICKER_PID" >/dev/null || { echo "FALLO: ticker murió"; exit 1; }
tail -1 "$TICK_LOG"   # primer TICK de ESTA ejecución (mktemp garantiza que
                      # nadie más pudo haber escrito antes)
```

El `&` (más `disown`, para que el ticker sobreviva si el shell padre cambia de
sesión) es lo que lo hace background REAL — ejecutado sin él, el bucle ocupa el
foreground y bloquea el ciclo de triaje de §3, indistinguible de un colgado.
`$TICK_LOG` se resuelve ANTES del `&`, vía `mktemp` — si `mktemp` falla (disco
lleno, permisos), el `|| { … exit 1; }` EXPLÍCITO que sigue a la asignación
detiene el arranque ahí mismo, nunca con una ruta vacía o reutilizada
silenciosamente. La comprobación es OBLIGATORIA, no confía en un errexit
implícito: el procedimiento no fija `set -e`, así que sin ese `||` el estado de
salida no-cero de `mktemp` se perdería y la secuencia seguiría con `$TICK_LOG`
vacío hasta abortar tarde por el grep — con un ticker defectuoso ya lanzado y
`disown`-ado de por medio.

**NEGATIVO VERIFICABLE — forzar el fallo de `mktemp` y comprobar que el alta
ABORTA en la asignación**: hacer NO ESCRIBIBLE el directorio del log
(`chmod a-w "$HOME/.analista-produccion"`) y correr el bloque de §3. Resultado
EXIGIDO: `mktemp` sale con estado no-cero, el `|| { echo "FALLO: no se pudo
crear el log del ticker …"; exit 1; }` dispara y el alta se detiene EN la
asignación — **antes** de la línea `( while true; … ) &`, de modo que NO se
lanza ni se hace `disown` de ningún ticker y NO queda proceso huérfano. Señal de
paso: se imprime el `FALLO:` del log del ticker y el shell termina con `exit 1`;
señal de REGRESIÓN (el bug que este finding cierra): se ve el `TICK`/`FALLO`
del *grep* ~10 s más tarde en vez del `FALLO:` inmediato de la asignación —
prueba de que la secuencia continuó con `$TICK_LOG` vacío y lanzó el ticker
defectuoso. Restaurar permisos tras la prueba (`chmod u+w`).

**CARRERA ENTRE ESCRITORES — por qué la construcción es INCONDICIONAL, no un
fallback `${VAR:-...}`**: el propio `disown` que hace sobrevivir al ticker
significa que, si el alta se REPITE mientras una instancia anterior sigue viva
(nunca se mató), un log COMPARTIDO tendría DOS escritores simultáneos — el
ticker viejo podría escribir un `TICK` justo después de que el nuevo lo
"limpiara", y la aserción fail-closed de más abajo aceptaría ese eco AJENO
como si fuera del proceso recién arrancado (el `ps -p` solo confirma que el
PID nuevo vive, no que fue ÉL quien escribió). Un intento anterior de esta
doctrina usaba un fallback condicional del estilo `VAR="${VAR:-<ruta con
$$+timestamp>}"` — **defectuoso**: `${VAR:-...}` solo asigna el valor por
defecto SI la variable
está vacía; tras el primer alta en un shell, `$TICK_LOG` queda definido, y
repetir el checklist en la MISMA sesión REUTILIZA exactamente el log anterior
— reabriendo la carrera que se pretendía eliminar. Además `$$` + segundos
puede colisionar entre ejecuciones del mismo shell dentro del mismo segundo.
`mktemp "$HOME/.analista-produccion/tick.XXXXXX.log"` resuelve ambos
problemas por construcción: crea ATÓMICA e INCONDICIONALMENTE un fichero
garantizado-único y vacío en CADA invocación (nunca lee ni reutiliza un valor
previo de `$TICK_LOG`) — el primer-TICK y la aserción fail-closed pasan a ser
inequívocos SIN necesitar correlacionar contenido. Housekeeping: los ficheros
`tick.XXXXXX.log` de altas anteriores se acumulan en
`$HOME/.analista-produccion/` — limpieza periódica opcional, no bloqueante
para el mandato de la estación. El propósito del ticker es DOBLE — no
bloquear Y emitir un **TICK VISIBLE en el pane** para que el monitor externo
(§6) vea liveness — por eso `echo TICK` va por `tee -a "$TICK_LOG"`: el eco
sale al pane (estímulo visible que el monitor externo puede observar) Y se
duplica al log (persistencia para verificar después). Redirigir el bucle
entero a `$TICK_LOG` sin `tee` (log-only) rompe ese propósito: el eco
desaparece del pane y el monitor externo vería staleness aunque el bucle siga
vivo.

El **orden importa**: `echo TICK` va ANTES del `sleep 300` en el bucle — así el
primer TICK llega en segundos, no a los 5 minutos, y la verificación de
arranque puede esperarlo de forma ACOTADA en vez de bloquearse hasta el primer
ciclo completo. `mktemp` entrega el fichero YA VACÍO de forma atómica (sin
paso de truncado aparte que pudiera ejecutarse tarde o sobre el fichero
equivocado): sin esta garantía, verificar `tail -1` inmediatamente después de
arrancar podría (a) fallar sobre un fichero que aún no existe en un alta
limpia, o (b) aceptar como "fresco" un TICK que en realidad viene de una
corrida anterior — ninguno de los dos demuestra que EL PROCESO RECIÉN
INICIADO emitió el eco.

**FAIL-CLOSED, no solo el `for`**: el bucle de espera acotada por sí solo NO
decide nada — agotar los 20 intentos sin TICK termina el `for` con normalidad,
y un `tail -1` sobre un log vacío también sale con éxito sin imprimir nada, así
que la secuencia podría APARENTAR una verificación satisfactoria sin ningún
TICK. La ASERCIÓN posterior al bucle (`grep -q 'TICK' "$TICK_LOG" || { ... exit
1; }` + `ps -p "$TICKER_PID" >/dev/null || { ... exit 1; }`) es la que
realmente decide: sin TICK fresco, **aborta el alta** (mata el proceso
huérfano y sale con error) en vez de continuar sobre una verificación que
nunca ocurrió. El **one-shot queda PROHIBIDO**: murió dos veces la primera
noche (ver gotcha (a) en §8). El ticker es la única forma verificada de
mantener la estación viva sin supervisión humana continua.

Qué mira la estación en CADA ciclo:

1. **Unresolved de las últimas 24h** — grupos de error sin resolver, ordenados por
   frecuencia/impacto.
2. **Frecuencia contra cursor propio** — compara el conteo actual contra el cursor
   que la propia estación mantiene (ver gotcha (c), §8) para detectar SOLO lo nuevo
   desde el último barrido, nunca re-triageando grupos ya vistos.
3. **Grupos nuevos o escalados** — cualquier grupo que no existía en el barrido
   anterior, o que subió de severidad.

Auto-verificación del mecanismo en CADA tick: la estación confirma para sí misma
que el ticker sigue vivo antes de reportar «no paro jamás» — el mecanismo se
re-arma solo, nunca depende de que algo externo lo relance (salvo la red de
seguridad de §6, que es un vigilante ADICIONAL, no el único).

### PARTE por cron

La cadencia del PARTE **no se escribe en esta referencia**: se lee del perfil de instancia.

- **Fila lógica**: id `analista-produccion-parte`, tipo `cron`, atributo `minutos`.
- **Lectura única y fail-closed** con el lector ya existente:

  ```bash
  LECTOR="${SKILLS_ROOT:-}/talent-ceo/scripts/tablas-cron.sh"
  [ -n "${SKILLS_ROOT:-}" ] || { echo "PRECOND: SKILLS_ROOT no definido" >&2; exit 2; }
  [ -r "$LECTOR" ]          || { echo "PRECOND: lector no legible: $LECTOR" >&2; exit 2; }
  [ -n "${TA_PERFIL:-}" ]   || { echo "PRECOND: TA_PERFIL no definido" >&2; exit 2; }
  export TA_PERFIL
  MINUTOS="$(bash "$SKILLS_ROOT/talent-ceo/scripts/tablas-cron.sh" --minutos analista-produccion-parte)" || exit $?
  ```

  **Contrato de `rc`**: `0` = minutos válidos · `1` = fila o atributo ausente/inválido · `2` =
  perfil o precondición inválida. **Las precondiciones se comprueban con guardas EXPLÍCITAS que salen
  con `2`, nunca con `${VAR:?}`**: medido, `${VAR:?}` sale con **`1`** y ese `1` es indistinguible de
  «fila ausente», que es el otro significado del contrato. Y se comprueba que el lector es **legible**,
  no solo que la variable esté definida: una ruta definida pero **muerta** daría `127`, que no
  pertenece a este contrato. **Con `rc` 1 o 2 no se genera ni se emite parte.**
  **No existe minuto por defecto**: la ausencia de la fila es un fallo, no un caso base.

- **`PARTE_CMD` PROPORCIONA `TA_PARTE_REPO`/`TA_PARTE_REPO_ID` — nunca los asume del entorno de
  cron.** `cron` NO hereda el entorno interactivo de quien instaló la crontab: si `PARTE_CMD`
  invoca el lanzador sin más, las dos variables llegan vacías en CADA tick real, y el PARTE sale
  con el sujeto de otro repositorio o incompleto — y en los dos casos **sale**, que es peor que si
  no llegara (nadie sospecha de un informe que se emitió). `PARTE_CMD` las proporciona por una de
  estas dos vías, **fail-closed en las dos** — se comprueba ANTES de construir `PARTE_CMD`, no
  después:

  ```bash
  # (a) EXPLÍCITAS — la instancia las trae ya resueltas en su entorno:
  [ -n "${TA_PARTE_REPO:-}" ]    || { echo "PRECOND: TA_PARTE_REPO no definido" >&2; exit 2; }
  [ -n "${TA_PARTE_REPO_ID:-}" ] || { echo "PRECOND: TA_PARTE_REPO_ID no definido" >&2; exit 2; }
  ```

  ```bash
  # (b) CONFIG DE INSTANCIA VALIDADA — no basta con que el fichero exista: se exige que traiga
  # LAS DOS antes de aceptar nada (que exista y esté vacío, o que solo traiga una, es el mismo
  # fallo que si no existiera):
  [ -n "${TA_PARTE_ENV_FILE:-}" ] || { echo "PRECOND: TA_PARTE_ENV_FILE no definido" >&2; exit 2; }
  [ -r "$TA_PARTE_ENV_FILE" ]     || { echo "PRECOND: TA_PARTE_ENV_FILE ilegible: $TA_PARTE_ENV_FILE" >&2; exit 2; }
  . "$TA_PARTE_ENV_FILE"
  [ -n "${TA_PARTE_REPO:-}" ]    || { echo "PRECOND: $TA_PARTE_ENV_FILE no trae TA_PARTE_REPO" >&2; exit 2; }
  [ -n "${TA_PARTE_REPO_ID:-}" ] || { echo "PRECOND: $TA_PARTE_ENV_FILE no trae TA_PARTE_REPO_ID" >&2; exit 2; }
  ```

  Con cualquiera de las dos vías, si CUALQUIERA de las dos variables falta el paso **aborta con
  `exit 2` aquí** — antes de que exista ningún `PARTE_CMD` que instalar, así que el PARTE **no se
  emite** con el sujeto vacío o ajeno.

  **La misma clase alcanza a `PARTE_LAUNCHER` y `PARTE_SCRIPT`, no solo a las dos de arriba**:
  cualquier variable de la que dependa la línea de cron tiene que quedar RESUELTA e INCRUSTADA al
  generar `PARTE_CMD` — nunca referenciada como `$VAR` para que la expanda el shell que cron
  invoque en el tick, porque ESE shell corre con el entorno mínimo de cron, no con el de quien
  instaló la crontab. `PARTE_LAUNCHER` es aquí el **fichero que `dash` va a cargar como script**
  (su primer argumento posicional, no uno cualquiera): si llega vacío, `dash` intenta abrir `""`
  como fichero y falla **antes de cargar una sola línea del lanzador** — el `[ -r "$PARTE_SCRIPT" ]`
  de más abajo nunca llega a ejecutarse, porque vive DENTRO de un script que nunca se cargó. Esa
  guarda protege al lanzador de un `PARTE_SCRIPT` malo; no protege a la línea de cron de no tener
  ni lanzador. Por eso ambas rutas se validan y se incrustan AQUÍ, junto a las otras dos:

  ```bash
  [ -r "$PARTE_LAUNCHER" ] || { echo "PRECOND: PARTE_LAUNCHER ilegible: $PARTE_LAUNCHER" >&2; exit 2; }
  [ -r "$PARTE_SCRIPT" ]   || { echo "PRECOND: PARTE_SCRIPT ilegible: $PARTE_SCRIPT" >&2; exit 2; }
  ```

  Solo con las cuatro presentes y las dos rutas legibles se arma `PARTE_CMD` incrustando TODOS los
  valores como literales ya resueltos (`printf '%q'` evita que un valor con espacios o
  metacaracteres rompa el parseo de la línea de cron — para las rutas, además, es lo que hace que
  `dash` reciba la ruta real como argumento en vez de un token `$PARTE_LAUNCHER` que el shell de
  cron expandiría a vacío):

  ```bash
  PARTE_CMD="TA_PARTE_REPO=$(printf '%q' "$TA_PARTE_REPO") TA_PARTE_REPO_ID=$(printf '%q' "$TA_PARTE_REPO_ID") /usr/bin/env -u BASH_ENV -u ENV /bin/dash $(printf '%q' "$PARTE_LAUNCHER") $(printf '%q' "$PARTE_SCRIPT")"
  ```

  **Esto no sustituye la validación de `PARTE_LAUNCHER` (más abajo): la complementa.** Son dos
  capas fail-closed independientes — ésta cierra el momento de GENERAR/INSTALAR la línea (si las
  variables no están disponibles ahora, no se instala nada); la del lanzador cierra cada EJECUCIÓN
  real del tick (por si la crontab se editó a mano después, o el entorno de cron cambió). Ninguna
  reemplaza a la otra.

- **La línea de crontab se GENERA con el mismo lector, nunca se escribe a mano.** El lector
  **EMITE la línea por stdout: NO instala nada** — instalar es un paso aparte de la instancia, y
  quien lo ejecute debe comprobar el `rc` antes de usar la salida (un `rc` 2 devuelve stdout vacío
  y, sin comprobarlo, se instalaría una crontab vacía «en verde»):

  ```bash
  [ -n "${SKILLS_ROOT:-}" ] || { echo "PRECOND: SKILLS_ROOT no definido" >&2; exit 2; }
  [ -n "${PARTE_CMD:-}" ]   || { echo "PRECOND: PARTE_CMD no definido" >&2; exit 2; }
  LECTOR="$SKILLS_ROOT/talent-ceo/scripts/tablas-cron.sh"
  [ -r "$LECTOR" ] || { echo "PRECOND: lector no legible: $LECTOR" >&2; exit 2; }
  LINEA="$(bash "$LECTOR" --crontab analista-produccion-parte --comando "$PARTE_CMD")" || exit $?
  [ -n "$LINEA" ] || exit 2   # stdout vacío con rc 0 no existe, pero no se asume: fail-closed
  ```

- **Dos fases: medir el ambiente y ejecutar en hermético.** La orden instalada en cron DEBE ser
  únicamente este lanzador; `PARTE_LAUNCHER` es el script POSIX de abajo y `PARTE_SCRIPT` contiene
  la consulta completa, la guarda y la emisión:

  ```bash
  /usr/bin/env -u BASH_ENV -u ENV /bin/dash "$PARTE_LAUNCHER" "$PARTE_SCRIPT"
  ```

  Contenido de `PARTE_LAUNCHER`:

  ```sh
  #!/bin/dash
  [ -n "${TA_PARTE_REPO:-}" ]    || { echo "PRECOND: TA_PARTE_REPO no definido" >&2; exit 2; }
  [ -n "${TA_PARTE_REPO_ID:-}" ] || { echo "PRECOND: TA_PARTE_REPO_ID no definido" >&2; exit 2; }
  PARTE_SCRIPT="$1"
  [ -r "$PARTE_SCRIPT" ] || { echo "PRECOND: PARTE_SCRIPT no legible" >&2; exit 2; }
  HUELLA_RECIBIDA="$(/usr/bin/git -C "$TA_PARTE_REPO" rev-parse --absolute-git-dir --show-toplevel \
    --path-format=absolute --git-common-dir --git-path objects --git-path index HEAD)" \
    || { echo "PRECOND: Git no resuelve el ambiente recibido" >&2; exit 2; }
  exec /usr/bin/env -i HOME=/nonexistent XDG_CONFIG_HOME=/nonexistent PATH=/usr/bin:/bin \
    GIT_CONFIG_NOSYSTEM=1 \
    TA_PARTE_REPO="$TA_PARTE_REPO" TA_PARTE_REPO_ID="$TA_PARTE_REPO_ID" \
    TA_PARTE_HUELLA_RECIBIDA="$HUELLA_RECIBIDA" \
    /bin/bash --noprofile --norc "$PARTE_SCRIPT"
  ```

  La primera fase hereda las variables Git y captura su **efecto** con `/usr/bin/git`, pero corre
  bajo `/bin/dash`: ni `BASH_ENV` ni funciones exportadas de Bash se importan. La segunda fase
  conserva la huella capturada y arranca la ejecución COMPLETA con `env -i`. `PARTE_CMD` contiene
  la orden de dos fases completa; no invoca `PARTE_SCRIPT` directamente.

- **Procedencia de cada cifra.** Antes de consultar nada, la ejecución captura **una sola**
  procedencia:

  ```bash
  # El repo se FIJA por la instancia. NUNCA se deriva del cwd: un cron corre con cwd=$HOME, y
  # `git rev-parse --show-toplevel` allí o bien aborta, o bien —si el cwd cae en OTRO repo—
  # devuelve rc 0 y sella la cifra con un HEAD AJENO que pasa todos los `test -n`.
  # IDENTIFICACIÓN POSITIVA, no lista negra. La pregunta NO es «¿es alguno de los casos malos
  # conocidos?» —esa lista NUNCA se puede completar y fuga por construcción: cerrados cinco
  # disfraces apareció un sexto (un CLON con la misma raíz y HEAD divergente)—. La pregunta es
  # **«¿este árbol ES el repositorio declarado?»**, y todo lo que no la satisfaga se rechaza,
  # tenga el disfraz que tenga.
  # La identidad es el **inodo** del `.git`, no la ruta ni el commit raíz: la ruta la elige quien
  # llama, y el commit raíz lo comparten todos los clones. (Canon de la flota: identidad por
  # inodo, no por ruta.) La instancia declara `TA_PARTE_REPO_ID` como `stat -c '%d:%i'` de su `.git`.
  # El ambiente también forma parte de la identificación positiva. Se compara la huella que Git
  # ve en el ambiente recibido con la huella hermética declarada: git-dir, work-tree, common-dir,
  # objetos, índice y HEAD deben ser idénticos. Es una comparación de EFECTO, no una lista de
  # variables conocidas. Después, TODA consulta Git se ejecuta con binario, git-dir, work-tree y
  # ambiente fijados por este bloque. Así PATH, funciones de shell, LD_PRELOAD, configuración
  # global o una variable Git futura no pueden cambiar qué árbol responde sin que el control lo sepa.
  # Este cuerpo ya corre bajo el intérprete hermético exigido arriba. Las rutas absolutas son
  # defensa adicional: no dependen de PATH y en este proceso no hay funciones heredadas.
  [ -n "${TA_PARTE_REPO:-}" ]    || { echo "PRECOND: TA_PARTE_REPO no definido" >&2; exit 2; }
  [ -n "${TA_PARTE_REPO_ID:-}" ] || { echo "PRECOND: TA_PARTE_REPO_ID no definido" >&2; exit 2; }
  REPO="$(/usr/bin/readlink -f -- "$TA_PARTE_REPO")" || exit 2
  ID="$(/usr/bin/stat -c '%d:%i' -- "$REPO/.git" 2>/dev/null)" || { echo "PRECOND: sin .git propio" >&2; exit 2; }
  [ "$ID" = "$TA_PARTE_REPO_ID" ] || { echo "PRECOND: NO es el repositorio declarado ($ID)" >&2; exit 2; }
  REPO_GIT() {
    /usr/bin/env -i HOME=/nonexistent XDG_CONFIG_HOME=/nonexistent PATH=/usr/bin:/bin \
      GIT_CONFIG_NOSYSTEM=1 /usr/bin/git --git-dir="$REPO/.git" --work-tree="$REPO" "$@"
  }
  HUELLA_DECLARADA="$(REPO_GIT rev-parse --absolute-git-dir --show-toplevel \
    --path-format=absolute --git-common-dir --git-path objects --git-path index HEAD)" || exit 2
  [ -n "${TA_PARTE_HUELLA_RECIBIDA:-}" ] \
    || { echo "PRECOND: huella del ambiente recibido ausente" >&2; exit 2; }
  HUELLA_AMBIENTE="$TA_PARTE_HUELLA_RECIBIDA"
  unset TA_PARTE_HUELLA_RECIBIDA
  [ "$HUELLA_AMBIENTE" = "$HUELLA_DECLARADA" ] \
    || { echo "PRECOND: Git no resuelve el repositorio declarado" >&2; exit 2; }
  TOP="$(REPO_GIT rev-parse --show-toplevel)" || exit 2
  [ "$(/usr/bin/readlink -f -- "$TOP")" = "$REPO" ] || { echo "PRECOND: work-tree no declarado" >&2; exit 2; }
  TREE="$(REPO_GIT rev-parse HEAD)" || exit 2
  INSTANT="$(/usr/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" || exit 2
  [ -n "$TREE" ] && [ -n "$INSTANT" ] || exit 2
  ```

  y **cada cifra se emite en su propia línea repitiendo ambos campos**, con este formato
  normativo:

  ```bash
  printf 'tree=%s instant=%s metric=%s value=%s\n' \
    "$TREE" "$INSTANT" "$METRIC" "$VALUE"
  ```

  `TREE` identifica el checkout desde el que se ejecutó la consulta; `INSTANT` es el UTC de inicio
  de esa ejecución. **Si una métrica procede de otro árbol o de otro instante, se captura aparte y
  NO reutiliza los campos anteriores.** *Una cifra sin árbol e instante no es una medida.*

## 4. Taxonomía de sellos

> **PUNTERO** — el conjunto cerrado de 5 sellos (`SENTRY-ANALISTA-ALTA-OK`,
> `SENTRY-URGENTE-*`, `SENTRY-CONSULTA-*`, `SENTRY-HEARTBEAT`,
> `SENTRY-VERIFICA-*`) vive, con su tabla completa y ejemplos reales, en
> `talent-sentry-guard/references/01-ciclo-y-sellos.md` §"Sellos al bus". No
> se reproduce aquí para no mantener dos copias.

## 5. Verificaciones post-deploy

> **PUNTERO** — la doctrina "cifra exacta, nunca adjetivos" bajo
> `CEO-SENTRY-VERIFICA-<TAL>`, con el ejemplo real TAL-4725, vive en
> `talent-sentry-guard/scripts/verificar_cese.py` +
> `talent-sentry-guard/references/04-contrato-de-issue.md` §"E/D/5A y
> cierre" — implementación real, no solo doctrina. No se reproduce aquí.

## 6. Redes de seguridad

La estación **NUNCA es su propio único vigilante**. El nivel superior (CEO) arma
un **monitor externo de staleness del pane**: si el pane de la estación lleva
**más de 20 minutos sin cambios**, eso es alerta — señal de que el ticker pudo
haber muerto sin que la propia estación se diera cuenta (coherente con el gotcha
(b) de §8: un pane quieto NO prueba por sí solo que el tick sigue vivo).

Complementos que la estación hereda por puntero, sin reimplementarlos aquí:

- **Ley actor-degradado** (autoridad fabricada/corrupta, descarte del actor):
  canon COMPLETO en **TAL-4731** — esta ref NO la redefine, solo apunta.
- **Compact-60**: la doctrina de auto-compact al 60% de contexto en checkpoint
  limpio + fichero de regreso verificado vive ÍNTEGRA en `talent-context` — esta
  ref NO la duplica, solo apunta a ella cuando la estación necesite aplicarla a
  su propio contexto.

El canon detallado de watchers (mecánica del monitor externo, cadencias, quién lo
opera) vive en **TAL-4731** — cero solape aquí: esta sección solo registra el
requisito sellado («la estación nunca es su único vigilante»), no la
implementación del watcher.

### Contrato del vigía lógico externo

Esta referencia fija **el contrato**, no el inventario: los vigías vivos son **dato de instancia** y
viven en el perfil/anexo, nunca aquí.

| Vigía lógico | Sujeto | Oráculo | Control positivo y restauración | Acreditación | Re-armado |
| -- | -- | -- | -- | -- | -- |
| Monitor externo de staleness del pane | Registro de instancia con PID + PADRE + CGROUP | Edad de la última salida del pane desde la fuente declarada por la instancia | Dos comandos concretos del registro de instancia: forzar rojo de forma segura y restaurar verde | Primera línea de salida + `mtime` del log; umbral explícito de 20 minutos | Ejecutar de nuevo la acreditación completa en paso-0 tras cada relanzamiento |

**Procedimiento de alta**, fail-closed en cada paso:

1. Resolver en el perfil/anexo de instancia **una única fila** para ese vigía lógico. Si hay **cero
   o más de una**, **el alta NO queda acreditada** — no se inventa aquí ningún sello nuevo: la
   taxonomía cerrada de §4 manda, y esta sección no la amplía.
2. Exigir en esa fila **PID, padre y cgroup**; path o fuente; comando de control positivo seguro;
   comando de restauración; log; umbral; y comando de re-armado. **Un campo vacío aborta.**
3. Ejecutar el **control positivo** y **exigir rojo**; capturar **primera línea y `mtime`** del log.
4. Ejecutar la **restauración** y exigir verde **dentro del umbral de 20 minutos**.
5. En **paso-0**, repetir 1–4. **Un PID vivo por sí solo NUNCA acredita el vigía**: dice que el
   proceso existe, no que mire lo que se cree.

Esta referencia **no afirma que exista ningún vigía vivo concreto**: afirma que **el alta queda
fail-closed** hasta que la instancia aporte y acredite exactamente una fila. *Un vigía que no puede
enrojecer no vigila.*

**El SILENCIO también es alerta.** Un parte que no llega no es un parte correcto: la ausencia de
emisión en la ventana esperada es la misma condición de alerta que el staleness del pane descrito
arriba, pero **NO comparte el umbral fijo de 20 minutos del pane**: ese número acredita el ticker
de §3, un mecanismo de cadencia propia y fija, ajeno a la cadencia del PARTE. El PARTE corre con
`$MINUTOS`, leído del perfil de instancia («PARTE por cron» arriba) — **con cadencia > 20 min, el
umbral del pane dispararía antes del siguiente parte esperado**, alertando un silencio que aún no
lo es. El umbral de silencio del parte se **deriva de esa misma cadencia** (p. ej. `2 × $MINUTOS`),
nunca de un número fijo ajeno a ella, para que un cambio futuro de cadencia en el perfil de
instancia no lo vuelva a desalinear. Un contrato que solo protege contra la cifra falsa deja
abierta la puerta del mutismo.

## 7. Checklist de alta de la estación

Pasos numerados y reproducibles para montar la estación desde cero en una
fábrica nueva:

1. Levantar la credencial de pozo propia del vendor de observabilidad (patrón §2:
   `railway variables` → header-file 0600 + fichero meta org/proyecto).
2. Verificar acceso: una consulta mínima al vendor que confirme que el token
   responde (sin imprimir el token — ver el MUST de §2).
3. Resolver `$TICK_LOG` con `mktemp "$HOME/.analista-produccion/tick.XXXXXX.log"`
   (§3) — creación ATÓMICA e INCONDICIONAL, NUNCA un fallback `${VAR:-...}` (esa forma
   reutiliza el valor si la variable ya quedó definida de un alta previa en la
   MISMA sesión, y `$$`+timestamp puede colisionar entre ejecuciones dentro del
   mismo segundo) ni un path fijo/compartido — evita la carrera si una
   instancia anterior del ticker sigue viva por `disown`. Comprobar EXPLÍCITAMENTE
   el estado de `mktemp` con `|| { … exit 1; }` en la MISMA asignación (el
   procedimiento no fija `set -e`): si `mktemp` falla, el alta se detiene AHÍ,
   antes de lanzar el ticker (negativo verificable en §3). Arrancar el ticker
   infinito EN
   BACKGROUND REAL (`&` + `disown`, capturando `$TICKER_PID`; el bucle emite
   `TICK` por `tee` ANTES del `sleep`, visible en el pane Y duplicado al log).
   VERIFICAR con ESPERA ACOTADA (segundos, no el ciclo completo de 5 min) +
   ASERCIÓN FAIL-CLOSED tras el timeout: la espera por sí sola no decide nada
   (agotarla sin TICK termina con normalidad); es la aserción posterior —
   `grep -q 'TICK' "$TICK_LOG"` Y `ps -p "$TICKER_PID"`, ambas con `exit 1` si
   fallan — la que **aborta el alta** si no hay TICK fresco, en vez de dar el
   paso por hecho con solo una de las dos señales o con la espera sola.
4. Primer barrido completo: unresolved 24h + fijar el **cursor propio** en el
   estado actual (línea base para el ciclo siguiente — ver gotcha (c) en §8).
5. Confirmar con el CEO que el **monitor externo de staleness** (§6) está armado
   y vigilando el pane de la estación.
6. **EVIDENCIA DE INSTALACIÓN DEL PARTE — entrada OBLIGATORIA, no un texto.** El
   contrato de §3 **genera** la línea de crontab; **generarla no la instala**. El alta
   exige aquí las dos pruebas, y **sin ellas el alta se RECHAZA**:
   - **(a) la entrada se INSTALA aquí y se comprueba DESPUÉS**: el alta añade la línea a la
     crontab si no está, **vuelve a leer la crontab viva** y exige que contenga, literal, la línea
     que emitió el lector. **El `rc` de `crontab` no prueba el estado final: solo lo prueba
     re-leerlo.** Una discrepancia **aborta el alta**:

     ```bash
     # INSTALAR es un PASO del alta, no una precondición ajena: un alta que solo COMPRUEBA una
     # instalación previa no es un alta, es una verificación disfrazada.
     #
     # DUEÑO ÚNICO DE CONFIGURACIÓN: `crontab` no ofrece compare-and-swap, así que TODA instalación
     # de esta estación pasa por el MISMO path fijo de lock. Un `flock` cualquiera solo coordinaría
     # escritores que voluntariamente lo compartan — por eso el path no es una convención suelta:
     # es la primitiva de coordinación que este checklist declara y exige para SÍ MISMO. NO lo
     # vuelvas por-instancia (un directorio nuevo POR CADA alta, o uno distinto por estación):
     # eso sí rompería la exclusión — dos instalaciones con locks distintos creerían las dos que
     # tienen la exclusión. Lo que SÍ cambia abajo es DÓNDE vive ese único path fijo, no si es
     # único: sigue siendo UN solo fichero, compartido por TODAS las altas de esta estación en
     # este host — la migración fuera de `/tmp` no lo convierte en «uno por estación».
     #
     # DIRECTORIO PROPIO, NO `/tmp`: `/tmp` es escribible por CUALQUIER cuenta del host, así que
     # un path predecible ahí es un blanco de symlink para cualquiera, no solo para un vecino
     # descuidado. `$HOME/.analista-produccion` (mismo directorio que ya usa el ticker de §3) se
     # crea con permisos restringidos — solo el dueño de esta cuenta puede escribir dentro, así
     # que ninguna otra cuenta puede plantar el symlink en primer lugar. Esto CIERRA la vía de
     # symlink por diseño, no la mitiga: no hace falta confiar en que nadie más use este host.
     # ACREDITAR EL CAMINO ANTES DE ABRIR NADA: sacar el lock de `/tmp` cerró el symlink de
     # terceros, pero abrió una superficie nueva — `$HOME/.analista-produccion` puede YA EXISTIR
     # en cualquier máquina que haya corrido esta alta antes, con otro dueño, otros permisos, o
     # ser él mismo un enlace. Cuatro condiciones, fail-closed, ANTES de tocar nada dentro:
     [ -L "$HOME/.analista-produccion" ] && { echo "ALTA RECHAZADA: $HOME/.analista-produccion es un enlace simbólico" >&2; exit 1; }
     mkdir -p "$HOME/.analista-produccion" || exit 2
     # DUEÑO ANTES que permisos: si el directorio es de otra cuenta, un `chmod` aquí fallaría
     # de todas formas (no hay permiso para tocarlo), pero con un "Operation not permitted"
     # generico del sistema — ni siquiera con el error correcto se sabria POR QUE. Comprobar el
     # dueño primero da el diagnostico real (ALTA RECHAZADA con el uid) en vez de un fallo opaco.
     DUENO_DIR="$(/usr/bin/stat -c '%u' "$HOME/.analista-produccion")" || exit 2
     [ "$DUENO_DIR" = "$(id -u)" ] || { echo "ALTA RECHAZADA: $HOME/.analista-produccion no pertenece a esta cuenta (uid $DUENO_DIR)" >&2; exit 1; }
     # `mkdir -m 0700` SOLO fija el permiso al CREAR el directorio — si YA existía (el caso real
     # en cualquier máquina que ya corrió esta alta una vez), `-m` no hace NADA y el permiso
     # heredado (umask de otra sesión, otro proceso) queda tal cual. El 0700 se ESTABLECE aquí
     # INCONDICIONALMENTE cada vez, nunca se asume por haber pasado por `mkdir`.
     chmod 0700 "$HOME/.analista-produccion" || exit 2
     CRON_LOCK="$HOME/.analista-produccion/crontab.lock"
     # El FICHERO puede ser un enlace aunque el DIRECTORIO sea sano — condición APARTE, no la
     # misma comprobación repetida: el directorio protege de que UN TERCERO plante el symlink a
     # partir de ahora, pero no dice nada sobre si YA hay uno (una alta previa a esta doctrina, o
     # un bug propio). Se valida ANTES de `exec`, no después: `exec 9>>` sobre un symlink lo sigue.
     [ -L "$CRON_LOCK" ] && { echo "ALTA RECHAZADA: $CRON_LOCK es un enlace simbólico" >&2; exit 1; }
     # ABRIR SIN TRUNCAR ('>>', no '>') se conserva como defensa en profundidad, no como cierre
     # principal: con el directorio restringido de arriba, un symlink ahí solo podría plantarlo
     # el propio dueño de la cuenta (un bug propio, no un tercero) — igualmente barato de evitar
     # sin truncar nada si algún día apareciera. El lock no necesita contenido, solo un fd
     # bloqueable: abrir en append crea el fichero si falta pero nunca lo trunca.
     exec 9>>"$CRON_LOCK" || exit 2
     flock -w 30 9 || { echo "ALTA RECHAZADA: no se pudo tomar el lock de dueño único de crontab" >&2; exit 1; }
     CRONTAB_VIVA="$(mktemp)" || exit 2            # inicializada SIEMPRE: una variable vacía en un
     CRONTAB_NUEVA="$(mktemp)" || exit 2           # `grep -qxF` compara bien contra casi todo (fail-open)
     # CAPTURAR EL rc SIN NEGACIÓN ('if ! cmd; then rc=$?' captura el rc de la NEGACIÓN
     # —siempre 0 dentro del then—, nunca el de `crontab -l`; con eso `-eq 1` no se cumple
     # jamás y un caso inicial legítimo (sin crontab) se rechaza como si fuera un fallo real).
     # No fija `set -e` este procedimiento (ver arriba): un `crontab -l` con rc 1 fuera de
     # un `if` es seguro aquí, pero SOLO por eso — no reordenar esto sin comprobarlo primero.
     crontab -l > "$CRONTAB_VIVA" 2>/dev/null
     CRON_RC=$?
     if [ "$CRON_RC" -ne 0 ]; then
       if [ "$CRON_RC" -eq 1 ]; then
         : > "$CRONTAB_VIVA"   # rc 1 == "no crontab for user": caso inicial real, no un error
       else
         echo "ALTA RECHAZADA: crontab -l falló con rc=$CRON_RC (no es 'no hay crontab') — fallo cerrado" >&2
         exit 1
       fi
     fi
     if ! /usr/bin/grep -qxF "$LINEA" "$CRONTAB_VIVA"; then
       cat "$CRONTAB_VIVA" > "$CRONTAB_NUEVA" || exit 2
       printf '%s\n' "$LINEA" >> "$CRONTAB_NUEVA" || exit 2
       crontab "$CRONTAB_NUEVA" || { echo "ALTA RECHAZADA: no se pudo instalar la entrada" >&2; exit 1; }
     fi
     # RE-LEER la crontab viva DESPUÉS de instalar: el rc de `crontab` no prueba el estado final.
     crontab -l > "$CRONTAB_VIVA" 2>/dev/null || { echo "ALTA RECHAZADA: crontab ilegible tras instalar" >&2; exit 1; }
     /usr/bin/grep -qxF "$LINEA" "$CRONTAB_VIVA" || { echo "ALTA RECHAZADA: la línea generada NO está instalada" >&2; exit 1; }
     rm -f -- "${CRONTAB_NUEVA:?CRONTAB_NUEVA vacío}"
     flock -u 9   # libera el lock: la ventana read-modify-write completa quedó bajo dueño único
     ```

   - **(b) el vigía queda acreditado por EFECTO**: se ha ejecutado el procedimiento de
     cinco pasos de §6 —control positivo en rojo, restauración en verde dentro del
     umbral, primera línea y `mtime` capturados—. **Un PID vivo no vale como evidencia.**

   **Este paso no es declarativo**: si (a) o (b) no se pueden demostrar, **el alta no
   continúa**. `rc 0` del generador **no es evidencia de instalación**: es evidencia de
   que se imprimió una línea.
7. Solo ENTONCES —tras 1-6, incluida la confirmación del monitor externo **y la
   evidencia de instalación del paso 6**— emitir el sello `SENTRY-ANALISTA-ALTA-OK`.
   El sello es el ÚLTIMO paso: sellar antes daría por terminadas una red de seguridad
   y una cadencia de parte que **aún no existen**. **El sello NO puede emitirse con el
   paso 6 pendiente, ni siquiera con confirmación verbal.**

### Límites con nombre de TAL-5448

- **LÍMITE TAL-5448-INV-EFECTO — `invariants.tsv` no acredita comportamiento.** El motor del
  paquete acepta únicamente `MUST`/`MUST_NOT` como ERE sobre el texto de un fichero; no ejecuta
  el procedimiento. Por ello `INV-CD-039`, `INV-CD-040` e `INV-CD-041` se retiran del inventario
  de invariantes: quedan como doctrina normativa de esta referencia, pero no como garantía
  mecánica. Acreditarlas por efecto exige un harness ejecutable de integración que hoy no forma
  parte del paquete; una cadena presente, incluso en comentario, no sustituye esa prueba.
- **LÍMITE TAL-5448-LECTOR-EXTERNO — dependencia fuera del skill.** El validador confina cada
  target al directorio del propio skill, por lo que no puede acreditar la presencia de
  `talent-ceo/scripts/tablas-cron.sh`. El procedimiento sí falla en runtime con rc 2 si el lector
  no es legible; la disponibilidad cross-skill queda fuera del ratchet textual.
- **LÍMITE TAL-5448-CRONTAB-CONCURRENCIA (cerrado) — dueño único de configuración.** `crontab` no
  ofrece compare-and-swap, así que un `flock` cualquiera solo coordinaría escritores que
  voluntariamente lo compartieran — documentar esa carencia no la impedía. El paso 6(a) del
  checklist cierra la carrera declarando el ÚNICO punto de escritura: toda instalación de crontab
  de esta estación toma `flock -w 30` sobre el path fijo `$HOME/.analista-produccion/crontab.lock`
  (directorio creado `-m 0700`, escribible solo por el dueño de la cuenta — nunca `/tmp`, que
  cualquier cuenta del host puede escribir) ANTES de leer la instantánea y lo libera DESPUÉS de
  re-leer y verificar; si no se puede tomar el lock, el paso aborta con `exit 1` y **el alta no
  queda completa** (el sello de §7 exige el paso 6 cerrado, nunca declarado sobre una carrera sin
  garantizar). El directorio restringido CIERRA el vector de symlink de un tercero (no puede
  escribir ahí); el residuo que queda es solo si la propia cuenta lo plantara por error — cubierto
  igual por abrir en append (`>>`) en vez de truncar. Sigue fuera de alcance un escritor de
  crontab completamente ajeno a este procedimiento (p. ej. una edición manual con `crontab -e`
  fuera de la estación) — eso excede la doctrina de esta estación, no es una carencia del checklist.
- **LÍMITE TAL-5448-CRONTAB-RECONFIGURACIÓN — identidad lógica no gestionada.** La deduplicación
  literal no reconoce como la misma entrada dos cadencias del mismo comando. Borrar por comando
  podría eliminar una entrada ajena legítima; cerrar el caso requiere un bloque gestionado con
  marcador/propietario estable y migración explícita de la entrada anterior.

## 8. Gotchas (con fecha)

Evidencia real del 23-ago-2026 (primera noche de operación de la estación):

**(a) El despertador one-shot muere en silencio.** Un mecanismo de re-invocación
de una sola vez (sin re-armado automático) dejó a la estación muda dos veces la
primera noche: una mudez de 50 minutos y otra de 3h24m. No hubo error visible —
simplemente el despertador no volvió a disparar. Por esto el mecanismo sellado es
el ticker infinito de §3 con auto-verificación en cada tick, nunca un one-shot.

**(b) El pane idle «1 shell running» NO prueba tick vivo.** Un pane que muestra
un único proceso shell en ejecución puede estar así tanto con el ticker vivo
(entre dos ecos de `sleep 300`) como con el ticker muerto (el bucle `while`
terminó y solo queda una shell residual). La única prueba real de tick vivo es
verificar el propio eco `TICK` (o el mtime del artefacto que lo registra), nunca
la apariencia superficial del pane — coherente con el monitor externo de
staleness de §6, que mira el mismo síntoma desde fuera.

**(c) Cursor propio para no re-triagear.** Sin un cursor que la estación
mantenga entre ciclos (§3, paso 2), cada barrido volvería a presentar los mismos
grupos ya triageados en el ciclo anterior, generando ruido y trabajo duplicado.
El cursor se fija en el alta (§7, paso 4) y avanza en cada barrido a lo
efectivamente nuevo.

Registro de modelos: `~/.config/talent-channel-operation/modelos.conf` del usuario del rol; CEO y plan/fallback usan Opus vigente, los demás roles y salud Sonnet vigente. Resolver tras acreditar Claude con `talent-channel-operation/scripts/resolver-modelos.sh`.
