# 08 — Gates locales: runners, receipts y el posteo de `local-gates`

La fábrica **NO usa GitHub Actions** (TAL-2286: presupuesto agotado + independencia
multi-org; ver la firma histórica del agotamiento en ref 02 §10). El gate de tests de
`main` es el commit-status **`local-gates`**, producido por el motor
`talent-factory/scripts/run-local-gates.sh` (v2) corriendo en **runners sin credenciales**
y posteado EXCLUSIVAMENTE por la **estación del Mergeador** vía
`talent-factory/scripts/post-local-gates.sh`. Doctrina de repo (wrappers, registro de
shards, terminal-sola, troubleshooting): runbook canónico `docs/runbooks/local-gates.md`.

## Table of Contents

- [Contrato de evidencia](#contrato-de-evidencia)
- [1. Arquitectura: runner vs estación](#1-arquitectura-runner-vs-estación)
- [2. Perfil RUNNER minimal + dimensionado](#2-perfil-runner-minimal--dimensionado)
- [3. Los canales de producción walled NO son runners](#3-los-canales-de-producción-walled-no-son-runners)
- [4. Cómo llega el motor al runner](#4-cómo-llega-el-motor-al-runner)
- [5. Flujo por PR: asignación → receipts → agregación → post](#5-flujo-por-pr-asignación--receipts--agregación--post)
- [6. Anti-self-report (invariante duro)](#6-anti-self-report-invariante-duro)
- [7. Regla elástica bajo gates locales](#7-regla-elástica-bajo-gates-locales)
- [8. Break-glass (`gh api` manual)](#8-break-glass-gh-api-manual)
- [9. Doctrina de BD compartida/preexistente (apply solo-aditivo)](#9-doctrina-de-bd-compartidapreexistente-apply-solo-aditivo)
- [10. Evidencia persistente al producirse, no al preverla perdida (regla dura 19)](#10-evidencia-persistente-al-producirse-no-al-preverla-perdida-regla-dura-19)
- [HOLD de host / mantenimiento (reboot)](#hold-de-host--mantenimiento-reboot)

## Contrato de evidencia

La evidencia sellada del runner con estado se valida por la tupla
(gate, commit, manifiesto, base, asignación, grupo):

- (a) El agregador nunca acepta evidencia de otra tupla ni un receipt que no
  haya sellado el lanzador. Exige identidad vigente, asignación sellada y respaldo
  del receipt en el journal de la estación.
- (b) Cualquier rechazo o fallo del intento en otro grupo conserva la evidencia
  válida del grupo original, incluso si el llamador comparte el directorio de receipts.
- (c) La evidencia legítima previa de la MISMA tupla sigue siendo válida: un
  reintento rechazado o fallido NO la invalida. La agregación posterior puede
  aceptar esa evidencia original sin una nueva ejecución del gate.

Modelo de amenaza: fallo accidental, no un actor con el mismo UID.
Riesgo residual: un proceso con el mismo UID puede borrar o fabricar marcadores.

Mejora futura: un identificador de intento recibido del llamador permitiría invalidar evidencia previa; no se implementa en 1.7.2.

Este contrato conserva las interfaces de `run-gate-sealed.sh` y
`post-local-gates.sh`. El receipt remoto se retira por grupo antes de la ejecución;
el local se recibe en un temporal del mismo directorio y solo se reemplaza por
renombrado atómico tras recibirlo completo. Un fallo anterior conserva el destino.
El receipt temporal se sella con el nombre final antes de sustituir al anterior; el diagnóstico local sigue sin ser agregable.
Antes de promover se exige releer el sello del temporal; bajo el mismo candado se separa cualquier cola incompleta y el lector ignora líneas rotas, que nunca respaldan evidencia.

## 1. Arquitectura: runner vs estación

Separación de poderes con **límite de confianza base/head**: quien ejecuta código del PR
no tiene credenciales; quien tiene credenciales solo valida DATOS.

**La estación vive a nivel HOST, no dentro de un contenedor**: el modo sellado exige el
cliente `incus` (push/exec sobre los runners) y la identidad `gh` de la fábrica — un
contenedor unprivileged no puede orquestar a otros contenedores. Intentar operar la
estación desde dentro de un canal es un error de topología, no de configuración.

```text
ESTACIÓN del Mergeador (credenciales: gh token, SUPABASE_ACCESS_TOKEN)
  genera run_group IMPREDECIBLE → asigna gates/shards a runners
  → recoge y SELLA receipts al recibirlos (almacenamiento no modificable por el runner)
  → post-local-gates.sh <run_group> <owner/repo> <pr>  → commit-status `local-gates`
        │ (la estación JAMÁS ejecuta código de head_sha; solo compara receipts)
        ▼ incus file push (script + manifiesto)
RUNNERS (perfil minimal, SIN credenciales — hoy vibe-channel-85..88)
  bash /tmp/run-local-gates.sh <repo> --sha X --run-group G --gate <gate-id>
  → worktree desechable + checkout interno + assert HEAD == --sha
  → ejecuta UN gate (wrappers de producto scripts/ci/run-*-local.sh son dueños
    de su stack Supabase efímero) → escribe UN receipt parcial JSON
```

- **El motor corre UN gate por invocación** (`--gate <gate-id>`, validado contra
  manifiesto + registro `scripts/ci/e2e-shards.json`; id desconocido → exit 2) en un
  **worktree desechable** — jamás sobre el repo vivo de un canal (`git clean` destruiría
  el `.env.local` token-por-carril y el trabajo congelado).
- **Receipt parcial** (contrato cerrado): identidad de corrida (`schema_version`, `repo`,
  `pr`, `sha`, `base_sha`, `manifest_digest`, `base_registry_digest`,
  `head_registry_digest`, `run_group`, `run_id`, timestamps) + **exactamente UN
  `gate_id`** + `PASS|FAIL|SKIP` con razón verificable. Cero o >1 gates → la estación lo
  RECHAZA. El conjunto esperado NO vive en el receipt.
- **El agregador es el ÚNICO dueño del conjunto esperado** (manifiesto + registro de
  shards, con **anti-reducción base→head**: el registro de `base_sha` es el mínimo
  confiable; una reducción en head falla y exige ratificación del lead; las adiciones se
  incorporan). Gate sin receipt, duplicado o con clave distinta → NO se postea
  (fail-closed).
- El gate `branch-name` corre el validador canónico del producto
  (`scripts/github/validar-rama-pr.sh`) **desde base_sha, en subprocess sin credenciales**
  (nunca desde head_sha — un PR podría modificarlo y ejecutar código junto al token);
  excepción Dependabot por autor preservada por separado.
- `post-local-gates.sh` agrega por el tuple
  `(repo, pr, head_sha, base_sha, manifest_digest, run_group)`, **relee
  `headRefOid`/`headRefName`/base del PR al final e INVALIDA el run ante cualquier
  cambio** (re-correr). `--context` solo acepta `local-gates` o `local-gates-test`
  (rollout).

## 2. Perfil RUNNER minimal + dimensionado

Perfil (decisión del lead 2026-07-09, CEO 1): contenedores Incus **clonados dedicados**
— ejemplo: `runner-01..04` en host-ejemplo —, **local-only sin Tailscale**, identidad
regenerada, **SIN credenciales**: ni Claude, ni Codex, ni CodeRabbit, ni token `gh`, ni
tokens Linear/Supabase. Solo repo + node + docker + supabase CLI local. El runner
**produce receipts; no puede postear nada** (no tiene con qué — eso es el diseño, no una
limitación).

**"SIN credenciales" es literal y se VERIFICA, no se declara** (audit r4 TAL-2293: los
85..88 clonados del golden aún tenían `~/.config/gh`, `~/.codex/auth.json`,
`~/.claude/.credentials.json`, `credential.helper` y `.env.local` en el repo — todo
legible por el UID que ejecuta el código del PR). El perfil exige un **usuario de gates
dedicado y limpio** (default `runner`, `--runner-user`): home propio sin ningún auth de
gh/Codex/Claude, sin `credential.helper` (global ni de repo) y clon **sin `.env.local`**.
El launcher corre un **preflight fail-closed** ANTES de cada exec y barre el CONTENEDOR
entero: `/root` y todos los `/home/*` (auth de gh/Codex/Claude, `.netrc`,
`.git-credentials`, **`.env.local` en cualquier home**), `credential.helper` de
usuario/repo/sistema, y que el usuario de gates no esté en `sudo`. Runner sucio ⇒ exit 2 sin
ejecutar nada ni sellar. Sanear un runner clonado = contenedor sin credenciales + usuario de
gates limpio + clon propio (la historia llega por bundle desde la estación; el runner NO
fetchea remotos privados — no tiene con qué).

**Causa raíz nueva de preflight rc=2 SUCIO — credencial CLI propagada al runner** (TAL-5170):
un cambio de cuenta CLI en la ESTACIÓN puede propagar `~/.claude/.credentials.json` a los
runners sellados si el push de credencial no los excluye explícitamente — el runner queda
"sucio" (viola el perfil SIN credenciales de arriba) sin que nadie lo tocara a mano. Remedio:
**el push de credencial va a una ALLOWLIST EXPLÍCITA de destinos, y lo que no está en ella no la
recibe.** El conjunto de destinos que deben tener credencial se **declara** (o se deriva del perfil
de instancia, si el perfil ya lo enumera); el push itera esa lista y **nada más**. Un destino que no
figure en la allowlist —un contenedor nuevo, uno renombrado, uno que nadie clasificó— **no recibe la
credencial**: en la duda, se deniega. Y se sanea + **re-preflighta** el runner tras CADA cambio de
cuenta CLI, no solo al aprovisionarlo la primera vez.

**Por qué allowlist y NO exclusión por patrón de nombre** (el diseño anterior excluía con
`grep -vE '8[1-8]$'` y `grep -v runner`): una exclusión por nombre **falla ABIERTA en el peor sitio
posible**. Lo que viaja aquí es una **credencial**: un destino cuyo nombre no case con el patrón de
exclusión —porque se renombró, porque la numeración creció, porque alguien lo llamó de otra forma—
**la recibe por defecto**, y el fallo es silencioso: nadie ve que un runner sellado dejó de estarlo
hasta que el preflight sale sucio. Con la allowlist, el mismo olvido produce el fallo contrario y
barato: un destino legítimo **se queda sin credencial** y lo dice a la primera. *Cuando el dato que
viaja es un secreto, el default tiene que ser no dárselo a nadie que no esté nombrado.*

**Regla de dimensionado**: `runners ≈ profundidad de cola / duración del run` — duración
real medida: **40-60 min para un PR con migración** (~30 min solo los sin migración); usar
la cifra real tanto para dimensionar como para el **umbral de hang** (un gate con migración
a los 45 min NO está colgado; inspeccionar proceso antes de declarar hang). Con gates
100 % locales la estación es el cuello de botella de TODAS las fábricas: si la
cola crece sostenidamente por encima de lo que los runners drenan, se **clonan runners
nuevos dedicados** (aprovisiona `talent-channels`), no se piden prestados canales.

**Supabase huérfano en el runner**: NUNCA matar (SIGTERM/SIGKILL) un gate vivo — deja el
stack Supabase efímero **huérfano** (contenedores docker y puertos tomados) y el siguiente
gate falla raro. Si un gate murió mal o hay que re-correr sobre un runner sospechoso:
`docker rm -f` de los contenedores del stack efímero ANTES de re-lanzar. (Los wrappers ya
convierten un teardown fallido en ROJO; esta limpieza es para el caso en que ni el teardown
llegó a correr.)

**Limpieza de un runner huérfano — SIEMPRE por PID exacto, JAMÁS `pkill -9 -f` sobre un
patrón** (TAL-5170, misma disciplina que "Ceder un PR a MEDIO gate" más abajo): (1) mapear el
`run_group` EN-CONTENEDOR — **un `pgrep -af <patrón>` textual es SOLO una lista de
CANDIDATOS, nunca evidencia de ownership por sí sola** (el mismo patrón textual se envenena
solo — regla dura 17 de §pool más abajo — matchea su propio waiter o un wrapper/watcher que
solo MENCIONA el script sin ejecutarlo): reconstruir el ÁRBOL PID/PPID real dentro del
contenedor (`incus exec <runner> -- ps -eo pid,ppid,cmd` o equivalente) y vincular cada
candidato a SU `run_group` por una marca verificable (el `run_id`/`run_group` que el propio
proceso recibió al lanzarse, no solo que su línea de comando lo mencione) antes de tratarlo
como atribuido; (2) matar por los **PID exactos** ya atribuidos con esa verificación, usando
`kill -TERM`/`kill -KILL <PID>`, nunca una selección por patrón textual; (3) `docker rm -f`
solo del stack Supabase efímero de ESE `run_group`. **"flock
ocupado" puede ser serialización LEGÍTIMA de otra corrida** — no es por sí solo señal de que
hay que limpiar nada. `incus restart --force` mata TODAS las corridas del contenedor, ajenas
incluidas — reservado para cuando el runner entero está irrecuperable, no como limpieza
rutinaria; `incus pause` es el shed correcto ante un fork-storm (congela sin matar, permite
inspeccionar antes de decidir). **`pkill -9 -f` NUNCA es la acción de limpieza aquí, aunque el
patrón esté acotado a `run_group`** — un patrón textual (`pkill -9 -f "supabase.*<run_group>"`
o similar) sigue pudiendo casar wrappers, watchers o procesos ajenos que solo MENCIONEN ese
identificador sin ser parte de la corrida; con el árbol de PIDs ya atribuido en el paso 1, no
hay razón para volver a seleccionar por texto en vez de matar los PID exactos del paso 2.

**Ceder un PR a MEDIO gate = matar en las DOS capas, POR `run_group`** (distinto de la regla de
arriba: aquí SÍ hay que matar, porque se cede). El gate vive en dos capas y matar solo una deja el
gate REAL corriendo: `run-gate-sealed.sh`/`seal-suite.sh` corren en la **ESTACIÓN**, pero dentro del
**runner** corre `run-local-gates.sh` + el motor con su Supabase efímero. Procedimiento: (1)
identificar el árbol de procesos **por `run_group`**; (2) matar los **PID exactos en la ESTACIÓN**
(`seal-suite`/`run-gate-sealed`) **y dentro del runner** (`incus exec <runner>` → `run-local-gates` +
motor), por PID, no `pkill -f` crudo; (3) **confirmar la muerte** en AMBAS capas; (4) `docker rm -f`
**solo** el stack Supabase efímero de ESE `run_group`. Matar solo en la estación deja vivo el
`run-local-gates` del runner, que pisa el siguiente gate. **Fail-closed**: si no puedes vincular con
certeza cada PID y cada stack Supabase a ESE `run_group`, **NO mates a ciegas** — parar y resolver la
identificación primero (matar un PID o borrar un stack de OTRO gate corrompe una corrida ajena).

## 3. Los canales de producción walled NO son runners

Regla dura (CEO 2): los working trees de los canales de producción (walled o no) llevan
**trabajo congelado** (batch mid-impl, ramas entregadas, `.env.local` por canal). Correr
gates ahí (git clean/checkout) lo **destruiría**. Los gates corren SOLO en runners
dedicados del perfil §2 — y aun dentro del runner, siempre en worktree/clon desechable,
jamás sobre un árbol vivo. El Mergeador **no cede ni toma prestados** canales de
producción para gates.

## 4. Cómo llega el motor al runner

Los runners NO ven el path del motor en el host (`/home/<usuario>/Fabrica/...`) y el host NO
tiene la toolchain completa (sin supabase CLI): el motor con
BD corre **DENTRO del runner**, nunca en el host.

```bash
# ÚNICA vía canónica: el launcher sellado de la estación hace TODO en una operación atómica
# (preflight fail-closed del contenedor → asignación con digests del clon limpio → bundle del
# commit → push de asignación+manifiesto+motor con --uid/--gid → incus exec síncrono con rc
# OBSERVADO por la estación → pull del receipt → sellado en journal). Sin pasos manuales.
bash talent-factory/scripts/run-gate-sealed.sh <gate-id> \
  --runner <contenedor-runner> --runner-user runner --runner-repo <ruta-repo-en-runner> \
  --repo <clon-limpio-estación> --run-group <G> --sha <head_sha> --pr <n> \
  --manifest talent-factory/manifiestos/academy.conf --receipts <dir> --repo-slug <owner/repo>
```

Invocar `run-local-gates.sh` a mano dentro del runner (sin `--assignment`) produce un
receipt `inline` que la agregación RECHAZA; `run-gate-sealed.sh --unsafe-local` (subprocess
de la estación) sella `isolation: station-local`, también rechazado — son diagnósticos, no
evidencia. **Quien tiene credenciales jamás ejecuta código de head_sha.**

**Runners REMOTOS por máquina física (TAL-5170, OBJETIVO pendiente de cableado —
verificado contra `run-gate-sealed.sh` real, no asumido)**: con las 5 estaciones (M1-M5)
repartidas entre host/black-alpha/black-delta/black-omega, `<contenedor-runner>` puede vivir
en una máquina remota. **Hoy `run-gate-sealed.sh` NO tiene flag de transporte**: el acceso a
la máquina remota está hardcodeado a `ssh root@<host>` dentro del script (verificado en el
launcher real) — no hay forma de parametrizar QUÉ identidad SSH lo ejecuta. **`--runner-user`
NUNCA significa la identidad de transporte SSH**: significa, SIEMPRE, el usuario interno del
contenedor runner que ejecuta el gate y recibe el preflight/`sudo -u` (confirmado en el
launcher real) — sigue siendo `runner`, el usuario dedicado y SIN credenciales del perfil
minimal (§2), en local Y en remoto por igual. Escribir `--runner-user vivecoder` en la
invocación de `run-gate-sealed.sh` **sería un error que rompe el perímetro SIN-credenciales de
§2** (el gate ejecutaría código del PR bajo una identidad con acceso a
`~/.claude/.credentials.json` y
demás — exactamente lo que el perfil minimal existe para impedir, verificado por el incidente
TAL-2293). **Dónde SÍ aparece la identidad `vivecoder`**: es la cuenta del OPERADOR de la
estación cuando alcanza una máquina remota A MANO, fuera de la automatización de
`seal-suite.sh`/`run-gate-sealed.sh` (p. ej. para inspeccionar un runner o depurar un
cableado roto) — nunca como valor de `--runner-user` ni de ningún flag del launcher; escribir
literalmente `--runner-user vivecoder` en cualquier invocación real sería el error descrito
arriba. **Esta sección describe el DESTINO** (transporte remoto por máquina física); el
cableado real en `seal-suite.sh`/`run-gate-sealed.sh` sigue hardcodeado a `ssh root@<host>` +
contenedores locales, sin flag de transporte parametrizable — fix es hijo 6 de TAL-5160,
fuera de alcance de esta pieza.

## 5. Flujo por PR: asignación → receipts → agregación → post

### Orquestador FAN-OUT de la suite (`seal-suite.sh`, TAL-2706) — vía canónica

La suite completa se lanza con el orquestador paralelo del motor
(`talent-factory/scripts/seal-suite.sh [--plan] [--no-post] <PR> <SHA> <BASE> <RUNGROUP>
[RUNNER...]`), que reemplaza el for-loop serial (~60-90 min/PR):

- **Specs de runner COMPLETOS, nunca shorthand**: los `[RUNNER...]` (y el `--runner` de
  `run-gate-sealed.sh`) exigen el **spec completo del contenedor** (`host/alpha-runner-N`), NO el
  abreviado `-N`. Con el shorthand el fan-out no resuelve el carril e2e → **0 receipts e2e** y el
  `rc2` falla-cerrado **en silencio** (la suite parece "pasar" sin haber corrido e2e).
- **Carril ligero**: el 1er runner corre los gates rápidos (typecheck…integration) en serie.
- **Carril pesado**: los runners restantes corren los shards e2e repartidos round-robin, cada
  runner SERIAL sobre su cola; la concurrencia e2e efectiva la capa `TF_E2E_CONCURRENCY`
  (default 3) — más e2e concurrentes saturan el host y reintroducen los flakes por contención
  (la causa histórica de re-runs de horas).
- **Barrera + agregación**: espera TODOS los carriles y agrega con `post-local-gates.sh` (única
  vía de POST). `--plan` = dry-run del reparto; `--no-post` = validación cronometrada sin status.
- **Medido en producción (#964, 2026-07-14)**: 23 gates en **24m29s** (3-way) vs 60-90 min serial;
  el flake de `unit` de las corridas nocturnas DESAPARECIÓ bajo el cap (era contención, no el test).
- **Fase QUIETA — `unit` no solapa el pico e2e (TAL-4946)**: dentro de un MISMO `seal-suite.sh`,
  `unit` es el 4.º gate del carril ligero — corre TEMPRANO, concurrente con el pico completo de
  e2e en el MISMO host físico → contención CPU/IO → timeouts de `unit` ajenos al cambio (evidencia:
  `tal-2916`, `pricing-crypto-contado`, shards de PRODUCTO). El candado de `run-local-gates.sh`
  (`TF_HEAVY_GATES`, §"Gates pesados…" más abajo) NO cubre esto: es por-CONTENEDOR y excluye `unit`
  a propósito. Fix (in-proceso, sin lib/estado/locks nuevos): `TF_QUIET_GATES` (default `"unit"`,
  best-effort — si el manifiesto no define un gate `unit`, p.ej. proyectos con `test`, se ignora
  en silencio) saca esos gates del carril ligero PARALELO y los corre en una **fase serial tras
  la barrera fan-out**, cuando el host YA NO tiene e2e activo — sin contención por construcción.
  La fase quieta se **OMITE fail-closed** si la fase 1 no terminó 100% limpia (un timeout puede
  dejar un e2e huérfano en el runner, ver gotcha 4 más abajo — nunca se arriesga a solapar).
  `TF_QUIET_GATES=""` (definida vacía) = comportamiento previo íntegro (todo el carril ligero en
  paralelo). Coste ~+`unit` en el camino crítico: **ESTIMADO** (~24.5→~27min), PENDIENTE de
  validación cronometrada en la estación (wall-clock 3-way < ~30min + `unit` sin timeout, contra
  el clon de producto con e2e real — el harness offline del motor valida la SECUENCIA, no
  CPU/IO/duración real). Es el complemento INTER-suite del cap intra-suite de TAL-4919
  (`TA_VITEST_MAX_WORKERS`, en producto).
- **1 suite full por MÁQUINA FÍSICA; 2 suites en paralelo por estación; serializar ENTRE
  flotas/coordinadores** (TAL-5170, sustituye la regla previa del límite a nivel de host
  entero — decisión del lead 2026-08-31, con las 5 estaciones M1-M5 y 4 máquinas físicas host/black-alpha/
  black-delta/black-omega disponibles): el fan-out ES el paralelismo DENTRO de una suite;
  correr 2 seal-suites completas sobre la MISMA máquina física en paralelo re-crea la
  saturación (regla dura, evidencia de la noche del 13-07) — el límite es por máquina física,
  no un límite global de "una suite en todo el sistema". **Advertencia — hoy NO hay mutex de
  host que lo haga cumplir automáticamente**: el único `flock` observado en el motor protege
  el append del journal de la estación, no reserva la máquina física entera; con dos
  estaciones (p. ej. M1 y M2) asignadas a la MISMA máquina física (host), esta regla es
  **disciplina operativa a seguir a mano** — verificar ocupación real (§pool más abajo) antes
  de lanzar, no una garantía mecánica del motor. Cablear un mutex real por máquina física es
  hijo 6 de TAL-5160, fuera de alcance de esta pieza (docs-only, no toca `seal-suite.sh`).
- **La re-run de un FAIL es de la ESTACIÓN**: ante un shard rojo, PROC-M19 (head vigente + log
  real + tabla de decisión) y re-run sellado INDIVIDUAL por el Mergeador. Ningún otro actor
  (orquestador/CEO) lanza re-runs "para ayudar": colisionan en los ficheros `/tmp/lg-$RG` del
  runner (visto en vivo: slate-rm + push ajenos pisando una re-run activa).
- **Fase 1 (build-único / supabase-reuse) NO está desplegada**: choca con el árbol desechable
  sellado (anti-false-green; `supabase db reset --local` es OBLIGATORIO). Cualquier caché por-SHA
  exige verificación de integridad — follow-up, no parche.

1. **Asignación**: la estación genera el `run_group` impredecible y reparte los gates del
   inventario (manifiesto + registro de shards leído en runtime) entre los runners libres.
   La asignación sellada aporta `pr`, `base_sha`, digests y `gate_id` — el runner no los
   inventa (los recomputa y aborta ante divergencia).
2. **Ejecución + sellado (`run-gate-sealed.sh`, operación ATÓMICA)**: la estación lanza
   cada gate con `talent-factory/scripts/run-gate-sealed.sh <gate> --runner <contenedor> …`,
   que en una sola operación hace: **preflight fail-closed** del runner (usuario de gates
   LIMPIO: sin `~/.config/gh`, `~/.codex/auth.json`, `~/.claude/.credentials.json`, sin
   `credential.helper` y clon sin `.env.local` — si algo de eso existe NO se ejecuta nada),
   **transferencia del commit por bundle Git** (el runner no fetchea remotos privados: no
   tiene credenciales, y no debe tenerlas), push de asignación+manifiesto+**motor** con
   `--uid/--gid/--mode` del usuario de gates, `incus exec` síncrono con el **exit code
   OBSERVADO directamente por la estación**, pull del receipt y sellado en `journal.jsonl`
   (sha256 del receipt + sha256 de la asignación + **sha256 del motor ejecutado** + exit +
   aislamiento; el journal lo escribe SOLO la estación). Sin pasos manuales: ni la
   asignación, ni el exit, ni el motor se introducen a mano.
3. **Agregación + post**: `post-local-gates.sh <run_group> <owner/repo> <pr>` EXIGE el
   journal y RECHAZA todo receipt sin respaldo (hash divergente = manipulado; sin entrada
   = fabricado), con `assignment != sealed` (un run inline es trabajo propio, no
   evidencia) o con `result` incoherente con el exit observado. Deriva el estado global
   (conjunto exacto, fail-closed), relee head/base/branch del PR e invalida ante cambio,
   y postea `local-gates` (o `local-gates-test` en rollout).
4. **Verificación del gate 2 del AND**: comandos en ref 02 §7 — el status @head **más** el
   receipt propio de la estación para ese `run_group`.
   - **Cold-container typecheck flake**: un `typecheck` con **rc=2 en ~3 s y SIN
     `node_modules`** en el runner NO es un FAIL del código — es el contenedor frío sin
     dependencias (Ev #885/#899). **Receipt faltante o flakeado ≠ re-correr todo**: el
     agregador fail-cierra por el receipt que falta → **re-run sellado INDIVIDUAL de ese
     gate** (`run-gate-sealed.sh <gate-id> …` con el mismo `run_group`) y **re-agregar**;
     jamás postear "casi completo" ni repetir la tanda entera.
   - **`.next` stale por checkout**: árbol reutilizado entre PRs → `rm -rf .next` tras el
     checkout o typecheck/build fallan con rutas fantasma (TS2307).
5. **Aislamiento del runner**: el árbol desechable ejecuta CÓDIGO DEL PR — el motor
   PROHÍBE `TF_ENV_COPY` en modo sealed (copiar un `.env` no versionado a ese árbol sería
   un canal de exfiltración de tokens); los gates que reproducen Actions no lo necesitan.
   La anti-reducción del registro opera a DOS niveles (shards Y **specs dentro de cada
   shard**) y exige **ratificación durable** (`scripts/ci/REGISTRY-RATIFICACIONES.log`,
   formato cerrado `ref=<aprobación> | items=<tokens exactos>`, append-only verificado en TODO
   PR, en el diff). El `base_tip_sha` viaja sellado de la
   asignación al receipt: si la rama base avanza, la corrida queda invalidada. Los wrappers
   convierten un teardown de Supabase fallido en ROJO (jamás conservan un PASS con el
   runner contaminado), y los gates pesados (`TF_HEAVY_GATES`, default
   `db-guards integration e2e` + todo shard E2E) serializan por flock del runner.

## 6. Anti-self-report (invariante duro)

- **Checkout interno**: el motor hace checkout del `--sha` en el worktree desechable y
  ASSERTA `HEAD == --sha` antes de correr nada — el estado que se postea sobre un SHA es
  el resultado de ejecutar los gates sobre ESE SHA, no sobre "lo que hubiera en el árbol".
- **El receipt es la evidencia**, no la memoria: la estación solo cuenta como corrida lo
  que tiene receipt sellado con la identidad completa del run.
- **Verificación de estación**: antes del merge, el Mergeador verifica que el
  `local-gates=success` @head corresponde a un `run_group`/receipts PROPIOS de la
  estación — un status posteado por otro actor no es evidencia del AND.
- **JAMÁS postear sin corrida real del head exacto**: cada push nuevo cambia el head →
  re-correr los gates y re-postear. Un `local-gates` de un head viejo no dice nada del
  vigente.
- **Defensa en profundidad**: el intake ya re-verifica `PR head == sha gateado`
  (`verify-handoff.sh` puede pasar sobre un head declarado viejo); el mismo criterio
  aplica aquí — el head del receipt debe ser el `headRefOid` REAL del PR al momento del
  post.

## 7. Regla elástica bajo gates locales

Mientras un run largo corre (waiter), la estación **NO cede**: paraleliza los gates de
los PRs **sin migración** en los runners libres (asignación por `run_group` distinto por
PR). Las **migraciones siguen seriales por slot** (diseño: renumeración contra el ledger
y apply a prod serializado — ref 06). Complementa la regla dura 11 (cero ociosidad): el
slot de merge nunca espera a un run si hay otro PR ya evidenciado.

### §pool — Esperar por CAMBIO, no por EXISTENCIA (regla dura 13, 2026-07-28)

**Causa raíz única**: el instrumento no distingue «terminó» de «nunca empezó» — ambos se
ven exactamente igual. Se espera a que una condición se cumpla cuando la condición **ya
era cierta antes de empezar**, o se mide ocupación por el NOMBRE de un proceso en vez de
por su EFECTO. **(a) Nunca esperar por EXISTENCIA**: prohibidos `until [ -f <fichero> ]` y
`until pgrep …`. Esperar siempre a un valor NUEVO conocido de antemano (`run_id` nuevo,
`mtime > T0`, un contador que sube), capturado del log del lanzador ANTES de armar el
waiter. **(b) Nunca medir ocupación por nombre de proceso**: `pgrep -f "<patrón>"` se
cuenta a sí mismo y matchea watchers/wrappers que solo MENCIONAN el script sin ejecutarlo
(regla 17). Sondear el EFECTO: procesos **dentro del contenedor**
(`incus exec <runner> -- ps -eo comm | grep -cE '^(node|npm|next)$'`), receipts del
`run_group`, o el estado del recurso. Evidencia (2026-07-28, 7 instancias medidas):
`pgrep -f "bash scripts/cr-review.sh"` matcheó el propio waiter (CR en vuelo eterno con el
CR ya terminado); `grep -c "seal-suite"` dio conteos falsos con el pool LIBRE (watchers de
horas que solo citaban la cadena); `until [ -f <receipt> ]` con el receipt preexistente
devolvió al instante con datos de 24 min antes y anunció FAIL; comparar `mtime` local
contra `date -u` dio frescura inventada; y en la comprobación de limpieza post-pisotón,
`pgrep` dio falso positivo consigo mismo (salvado con `ps -eo args | grep '[m]1-…'`,
corchetes). **Todo instrumento debe poder distinguir "no ocurrió" de "no lo vi" — si no
puede, no es evidencia.**

### §pool — Liberar y TOMAR son dos actos distintos (regla dura 14, 2026-07-28)

**El sello propio de «POOL LIBRE» NO reserva nada — es una INVITACIÓN a otro.** Antes de
CUALQUIER `seal-suite`, aunque lo hayas liberado tú hace minutos: **(1)** re-verificar
ocupación **por EFECTO dentro de los runners** (regla 13) **y (2)** re-hacer el CLAIM en el
flock con token grepeable (`PRECLAIM`, regla dura 11 del SKILL.md). Evidencia (2026-07-28):
M1 fundió un PR y selló «POOL LIBERADO» a las 17:40; M2 tomó el pool correctamente para su
PR; a las 17:44 M1 lanzó otra suite **sin re-verificar ni re-reclamar**, asumiendo que su
propia liberación seguía vigente → 17 gates intentados, 16 muertos por `flock` ocupado, 0
receipts. **Lo que sí funcionó**: el `flock` rechazó a la intrusa y la corrida ajena quedó
INTACTA — la defensa mecánica aguantó; el barrido posterior fue fail-closed y acotado por
`run_group` (solo PIDs propios, nunca `pkill` por patrón amplio, sin tocar contenedores sin
poder atribuirlos con certeza).

## 8. Break-glass (`gh api` manual)

El `gh api -X POST .../statuses/<sha> -f context=local-gates` manual **queda ELIMINADO
del flujo normal**: omite receipt, conjunto de gates y branch-name. Solo puede existir
como **break-glass explícito y trazado** — registrar en el PR (comentario) y en el
registro de la estación: **motivo + SHA exacto + quién** lo ejecutó, tras haber corrido
los gates de verdad. Un break-glass sin traza se trata como incidente, no como atajo. El `<sha>` de
`gh api … statuses/<sha>` DEBE ser el **SHA completo de 40 chars**: uno abreviado da **422** y el
status NO se crea → el merge queda **BLOCKED sin señal** (el 422 pasa desapercibido si no se lee el
cuerpo de la respuesta).

### base_tip mismatch — excepción ACOTADA (post manual sin re-gate)

Si `main` avanzó entre el `base_tip_sha` sellado del gate y el momento del merge, el run
queda formalmente invalidado. Existe UNA excepción para no re-gatear, con condiciones
estrictas (Ev #885/#942):

- **Condición necesaria (nunca suficiente)**: `git diff <gate_base>..origin/main
  --name-only` ∩ ficheros del PR = **∅** (main no tocó ningún fichero del PR).
- **Condición suficiente (una de dos)**: (a) el avance de main es contenido **estrictamente
  documental/no ejecutable** (docs, skills-content, comentarios), o (b) el **manifiesto
  demuestra** que ninguna superficie/gate aplicable al PR cambió con ese avance.
- **Si el avance toca código, configuración, dependencias, schema o contratos compartidos →
  RE-GATEAR sobre la base nueva, sin excepción**: un cambio de config global/dependencia/
  generador afecta al PR sin tocar sus ficheros — la intersección vacía NO lo detecta.
- La salida es un **post manual break-glass trazado** (motivo = "base_tip benigno" +
  evidencia de la inertness + SHA + quién), nunca un post silencioso.

### Boundary anti-self-report y límites de la excepción

- **(m1) Si el head cambia — re-gatear**: actualizar la rama (para satisfacer
  `required_status_checks.strict: true`, configurado en `scripts/setup-branch-protection.sh`),
  rebasar, o cualquier commit nuevo **cambia el head del PR** → los gates se re-corren sobre
  ese head y se re-postean. PROHIBIDO reutilizar receipts del head anterior: fabrica evidencia
  de gate (AGENTS.md regla 6 / `local-gates.md:302-304`). El «<1 min vs 13» de ev #1321
  logrado así es un **ANTI-PATRÓN**.
- **(m2) La excepción base_tip aplica SOLO al head gateado sin cambiar**: cubre el caso donde
  avanzó la base de main pero el PR head es el mismo que corrieron los gates; el receipt es del
  head realmente gateado, por eso el post trazado es legítimo (`local-gates.md:130-132` + §8:255
  arriba). Si hay que mover el head para mergear → (m1): re-gatear. Las condiciones
  necesaria/suficiente existentes no se extienden.
- **(m3) `gh pr merge --admin` NO es la vía para BEHIND rutinario**: excepcional (infra outage /
  hotfix incidente / bug de workflow); el runbook canónico excluye ahorro de minutos rutinarios —
  ver `docs/runbooks/github-branch-protection.md §Break-glass` (L182-186: «Ahorro de minutos
  rutinarios → no aplica»).

### PR docs-only / skills-only — fast-path carve-out RATIFICADO (TAL-2749)

Desde TAL-2749 (opción A, ratificada por el lead en `manifiestos/RATIFICACIONES.log`) SÍ existe un
fast-path, **gobernado por el mismo principio de antes**: toda reducción del conjunto de gates
exige **ratificación DURABLE en el manifiesto/motor**, nunca una decisión ad-hoc de la estación.
El carve-out ES esa reducción ratificada, no una excepción manual.

- **Cuándo aplica**: SOLO si el diff `base..head` es **100% `.md`** bajo un prefijo permitido del
  manifiesto (`TF_CARVEOUT_PATHS`, hoy `docs/` y `.claude/skills/`). Cualquier otro path —código,
  `scripts/` de skills, assets, yaml/json, rename o submódulo— ⇒ **suite completa**.
- **Qué corre**: los survivors de `TF_CARVEOUT_KEEP_GATES` (hoy `tenant`, `markdownlint`) +
  `branch-name` (agregador). El resto se emite como **SKIP con `skip_reason` token
  `carve-out-docs-only:`** — un SKIP EXPLÍCITO, no un receipt ausente (la ausencia sigue siendo
  NO-GO fail-closed; el agregador distingue ambos).
- **Doble cómputo (sin falsos verdes)**: el motor PROPONE el SKIP clasificando el diff; el
  **agregador lo RECOMPUTA** con su lib aprobada (`scripts/lib/carveout.sh`) y RECHAZA (NO-GO)
  cualquier carve-out SKIP sobre un diff que no sea 100% docs/skills. Mismo patrón que el SKIP de
  db-guards (`TF_DB_GATE`).
- **Más estricto que la clasificación manual**: el clasificador del motor manda a **suite completa**
  ante rename/copy/typechange/submódulo/symlink/diff-vacío, aunque
  `references/02-pipeline-y-gates.md` (clasificación docs-only del design-spike, para elegir el
  artefacto a auditar) los admita — un falso positivo del carve-out omite gates reales, así que el
  motor peca de conservador por mandato de la issue ("ante cualquier duda → suite completa").
- **Habilitación y gobernanza**: `TF_CARVEOUT_DOCS_ONLY="1"` en el manifiesto; habilitarlo, encoger
  los survivors o ampliar los paths inertes lo detecta `motor-go.sh` como reducción y exige
  ratificación durable. El precedente #947/#948 (break-glass trazado) queda SUPERADO: ya no es un
  post manual, sino survivors ejecutados + SKIP recomputado por el agregador.
- **Autoridad de inercia — digest ratificado, no el checker (scope ampliado, ruling del lead vía
  CEO tras auditoría r3-r8)**: que `docs/**`/`.claude/skills/**` sean inertes (que ningún pipeline
  pesado los consuma) es una precondición de seguridad del fast-path completo, separada de la
  clasificación del diff. Se intentó primero con un gate survivor heurístico en Academy
  (`carveout-check`: denylist de tooling MDX + scan AST/regex de imports/lecturas de `.md`); una
  serie de 8 rondas de auditoría (r3→r8) demostró que un scanner de sintaxis es **inherentemente
  incompleto** — cada ronda cerraba una evasión (ruta relativa, template dinámico, `new URL`,
  composición `path.join`/concat, alias de import…) y la siguiente encontraba otra, porque probar
  "ningún consumidor JS arbitrario existe" es **indecidible** (JS es Turing-completo). El ruling
  del lead promovió la autoridad conservadora, hasta entonces un follow-up P2, a mecanismo
  **DEFINITIVO**: `carveout_noncarveout_digest` (`scripts/lib/carveout.sh`) computa un sha256 del
  árbol de Academy en `TF_CARVEOUT_INERT_DIGEST_SHA` **excluyendo** `TF_CARVEOUT_PATHS`, a partir de
  los blob-sha de `git ls-tree` (sin leer contenido ni ejecutar nada). El agregador exige que ese
  digest, **recomputado sobre `BASE_SHA` en cada PR**, coincida con `TF_CARVEOUT_INERT_DIGEST`
  ratificado — si NO coincide (algo cambió fuera de docs/skills desde la ratificación, por
  cualquier vía, incluida una que ningún scanner detectaría), el SKIP de carve-out se **rechaza**
  (suite completa). Esto es decidible (comparación de hashes) y cierra la clase completa de
  evasión de una vez, en vez de patrón por patrón. `carveout-check` **permanece** como gate survivor
  — detección temprana / defensa en profundidad, útil para fallar rápido en el propio PR que
  introduce el consumidor — pero **ya no es la autoridad fail-closed**; esa es el digest.
  Re-ratificar (recomputar + nueva entrada en `RATIFICACIONES.log`) es necesario cada vez que el
  árbol no-carveout de Academy cambie legítimamente; `motor-go.sh` exige `TF_CARVEOUT_INERT_DIGEST`/
  `_SHA` presentes y bien formados cuando el carve-out está habilitado, y trata su cambio como
  clave de enforcement (ratificación obligatoria en el mismo commit).

## 9. Doctrina de BD compartida/preexistente (apply solo-aditivo)

Adición del CEO (TAL-2288, GO 2026-07-09). Cuando el **ledger de prod tiene un linaje de
migraciones que el repo NO puede reconstruir** — caso atlas→CRM: la BD compartida traía
214 migraciones de OTRO repo —, el modelo "repo = fuente del schema" no aplica:

- **El apply es SOLO aditivo**: `supabase db push` aplica lo AUSENTE del ledger; nunca se
  intenta reconciliar el linaje ajeno.
- **PROHIBIDOS contra prod**: `supabase migration repair` y cualquier `db reset` —
  destruirían un linaje irrecuperable (el repo no puede regenerarlo).
- **Pre-flight del Mergeador**: antes de operar, comparar ledger vs
  `supabase/migrations/` del repo; si `ledger > migraciones del repo` (versiones en prod
  que el repo no conoce **más allá del gap normal**) → activar este modo solo-aditivo y
  declararlo en el registro de la sesión. En Academia Ejemplo ese estado sería una anomalía
  a ESCALAR (PROC-M13 paso 2 ya lo detecta con `comm -13`); en repos con BD
  compartida/preexistente es el estado NORMAL de operación.
- El `db reset --local`/efímero de los gates (runners, wrappers) NO se ve afectado: esta
  doctrina es exclusivamente sobre PRODUCCIÓN.

## 10. Evidencia persistente al producirse, no al preverla perdida (regla dura 19, 2026-07-29)

**Todo artefacto de evidencia caro de reproducir se copia a almacenamiento persistente en
el momento en que se produce, no en el momento en que se teme perderlo.** Aplica a:
receipts de `run_group` (`/tmp/lg-<rg>/*.json` + `journal.jsonl`), resultados de CR por
corrida, y cualquier salida cuya reproducción cueste pool, cuota de vendor o tiempo de
estación. El disparador es **la producción del artefacto**, jamás la previsión de un
apagado — un respaldo hecho «porque va a apagarse» solo cubre lo que existía en ese
instante; lo que se produce después queda desnudo igual que sin norma.

Evidencia (2026-07-28/29): perder los receipts de un `run_group` que vivían solo en `/tmp`
costó **re-correr la suite entera** (~28 gates, ~25 min de pool) porque
`post-local-gates.sh` es dueño fail-closed del inventario — sin los receipts no hay
`local-gates` que postear, no hay atajo. Un caso donde SÍ se respaldó por anticipación
(preparando un apagado) dejó igualmente desnuda la re-suite del head FINAL, corrida
DESPUÉS del respaldo — sobrevivió por casualidad, no por norma cumplida: **un respaldo
disparado por previsión cubre el pasado y deja descubierto el futuro; solo el disparador
"al producirse" cierra la ventana**.

**Corrección al comando canónico del Gate 1** (regla 10, §7 de ref 02): el respaldo por
corrida `/tmp/cr-result-<pr>-<sha12>.json` vive DENTRO del volumen que se barre — cumple su
función anti-pisado dentro de la sesión pero no sobrevive a un reinicio. Se reubica FUERA
de `/tmp` con la misma clave (`<sha>`, no el número de PR); esta regla no deroga la regla
10, le corrige el destino.

**Dos pistas durables, no intercambiables**: el commit-status de GitHub (`local-gates`)
sobrevive siempre y prueba que la suite corrió sobre ese sha (nº de gates, `run_group`,
hora) pero nada por gate individual; los receipts respaldados prueban por gate
(`base_tip_sha`, `finished_at`, runner, reintentos) pero son locales, no públicos. Hacen
falta las DOS: el uso de alto valor de los receipts es **exculpar o inculpar `main` por
equivalencia de árbol sin gastar pool** (comparar `base_tip_sha`+`finished_at` contra un
rojo nuevo) — la evidencia respaldada no es archivo muerto, es capacidad de diagnóstico que
sustituye pool.

## HOLD de host / mantenimiento (reboot)

Cuando el lead/CEO pide un **reboot o mantenimiento del host propio de la estación** (parche
de kernel, presión de memoria, reconfiguración), la estación deja el host en estado limpio
ANTES de ceder el control — un reboot con un gate vivo deja stacks Supabase huérfanos y
receipts a medias que contaminan la siguiente corrida. Secuencia HOLD:

1. **Terminar o abortar el gate en curso**: si la corrida está por cerrar, dejarla acabar y
   sellar el receipt. Si el lead espera y el gate es **re-ejecutable** (todo gate sellado lo
   es — se re-lanza INDIVIDUAL con el mismo `run_group`, §5), **abortarlo** en vez de bloquear
   el reboot; se re-corre post-reboot.
2. **Matar motores huérfanos local+remoto — SOLO por PIDs exactos del `run_group`**: barrer
   los procesos del motor sobre ssh/`incus exec` que quedaron sueltos y los stacks Supabase
   efímeros que dejaron, identificando el ÁRBOL del `run_group` abortado y matando
   ÚNICAMENTE esos PIDs (la **receta canónica de §2** — matar en las DOS capas POR
   `run_group`: identificar el árbol por `run_group` → PIDs exactos en estación Y runner →
   confirmar la muerte en ambas capas → `docker rm -f` de SU stack efímero).
   **PROHIBIDO `pkill -u runner` o cualquier terminación por-usuario/patrón**: mata
   gates CONCURRENTES de otras corridas y deja receipts/estados parciales corruptos. Si la
   identidad `run_group`↔PIDs no puede determinarse, **abortar el HOLD fail-closed y
   escalar** — nunca matar a ciegas. Un `incus exec` abortado NO garantiza que el proceso
   hijo dentro del runner muriera: por eso se verifica el árbol, no se barre el usuario.
3. **Confirmar "host limpio" explícito al CEO**: sin gate vivo, sin motor huérfano, sin stack
   efímero tomando puertos. El HOLD no se declara por reloj: se declara tras verificar el
   barrido. Solo entonces el CEO procede con el reboot.
4. **Post-reboot, re-verificar antes de retomar**: los runners deben estar **RUNNING** (los
   contenedores Incus no siempre auto-arrancan tras un reboot del host) y con su **env
   esperado** cargado. **Revalidar EXPLÍCITAMENTE `TF_E2E_CONCURRENCY`** al valor operativo
   CONFIGURADO de esa estación (lo fija su configuración/manifiesto de estación — p. ej. la
   estación fundadora opera a 5): el reboot puede dejar el env sin exportar o en otro valor,
   así que se confirma/re-exporta ESE valor antes de retomar — no se reanuda a ciegas
   (arrancar por debajo desperdicia capacidad; esperar sin confirmar la retrasa). Esto NO
   reescribe el **default doctrinal general 3** de §5: es el valor propio de cada estación,
   que se revalida en cada HOLD. Recién con runners RUNNING + `TF_E2E_CONCURRENCY` revalidado
   al valor de la estación se retoma la cola.

**Runner tocado por un aborto = sucio**: el árbol desechable quedó a mitad y el stack
Supabase efímero puede seguir vivo. Antes de RE-USAR ese runner, limpiar los artefactos del
stack (`docker rm -f` de los contenedores efímeros, §2) — igual que tras cualquier gate
muerto mal. No re-lanzar sobre un runner sucio: falla raro (§2).
