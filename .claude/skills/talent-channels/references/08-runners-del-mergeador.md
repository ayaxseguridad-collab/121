# 08 — Runners del Mergeador (3er perfil: runner sellado de local-gates v2)

## Table of Contents

- [Perfil Mergeador — estación a nivel host](#perfil-mergeador--estación-a-nivel-host)
  - [Seat CR — binario `coderabbit` (golden verificado, pin 0.6.5)](#seat-cr--binario-coderabbit-golden-verificado-pin-065)
  - [Buzón espejo del flock](#buzón-espejo-del-flock)
- [Contrato del perfil (runner sellado)](#contrato-del-perfil)
- [Aprovisionamiento (deltas sobre el flujo normal de este skill)](#aprovisionamiento-deltas-sobre-el-flujo-normal-de-este-skill)
  - [Provisión por RÉPLICA de un runner sano (validado en vivo, R88 2026-07-14)](#provisión-por-réplica-de-un-runner-sano-validado-en-vivo-r88-2026-07-14)
- [Gotchas operativos del runner](#gotchas-operativos-del-runner)

Tercer perfil de canal junto a producción y Mergeador (`05-credenciales-por-carril.md` §Perfiles):
contenedores **runner** donde el motor `talent-factory` corre los gates de `local-gates` de forma
**sellada** (patrón desplegado: `vibe-channel-85..88` / usuario `runner`, alias R85). Este fichero
cubre el **APROVISIONAMIENTO**; el flujo por PR (asignación → receipts → agregación → post) es del
Mergeador: `talent-merger/references/08-gates-locales.md`.

## Perfil Mergeador — estación a nivel host

La **estación del Mergeador** corre en el HOST (no en un contenedor): necesita el cliente `incus`,
identidad `gh` con permisos de merge, y dos recursos propios del perfil: el **seat CR** y el
**buzón espejo del flock**.

**[TAL-3318] Env de estación SIN `GITHUB_TOKEN`/`GH_TOKEN` genéricos**: `gh` da PRECEDENCIA al
token del entorno sobre el login persistido — un `GITHUB_TOKEN` ambiente exportado en la estación
PISA la escalera de identidades A/B del Mergeador (todas las llamadas salen con la misma
identidad, el switch anti-rate-limit deja de operar y el bucket equivocado se agota en silencio).
Los tokens de la escalera van con nombres namespaceados (`GH_TOKEN_MERGER_A`/`_B`, patrón
`merger-escalera.env` del escrow) y se cargan SOLO al seleccionar identidad — nunca como export
ambiente de la sesión; si la estación necesita un token genérico para otra cosa, renombrarlo
(p. ej. `GH_TOKEN_FABRICA`) para que `gh` no lo capture.

### Seat CR — binario `coderabbit` (golden verificado, pin 0.6.5)

El CLI de CodeRabbit es el **único consumidor de CR** en la fábrica (ADR-0043). Se trata como
artefacto golden: **nunca `curl | sh` del vendor**, sino binario descargado y sha256 verificado,
gestionado por `scripts/02-golden.sh`.

- **Pin duro**: versión `CR_CLI_VERSION="0.6.5"` (L156 de `02-golden.sh`) con hashes sha256
  declarados en L157-158. El procedimiento de subida de versión vive en la cabecera del script
  (L150-151) — al actualizar el pin, seguir ese procedimiento y actualizar AMBOS hashes; nunca
  reemplazar los hashes sin verificar el binario.
- **`~/.coderabbit/auth.json`** — la identidad CR se escribe con `printf` (sin leak en argv ni
  en `/proc/*/cmdline`) de forma **atómica y 0600 desde su creación**: el directorio se fuerza
  a `0700` propio del usuario, `mktemp` (bajo `umask 077`) crea un temporal de **nombre no
  predecible y modo 0600** dentro de ese directorio — evita el path fijo `auth.json.tmp` (que
  podría ser un fichero/symlink preexistente o colisionar entre invocaciones concurrentes) y la
  ventana world-readable de un `> auth.json` + `chmod` posterior; el `mv` atómico publica el
  fichero final y se limpia el temporal si algo falla:

  ```bash
  install -d -m 0700 ~/.coderabbit
  tmp=$(umask 077 && mktemp ~/.coderabbit/auth.XXXXXX) || exit 1
  printf '{"type":"api_key","apiKey":"%s"}\n' "$CODERABBIT_API_KEY" > "$tmp" \
    && mv -f "$tmp" ~/.coderabbit/auth.json \
    || { rm -f "$tmp"; exit 1; }
  ```

  **Nunca `coderabbit auth login --api-key <key>`**: expone la key en argv y en
  `/proc/*/cmdline`. `push-carril-env.sh` ya usa este patrón para los canales del Mergeador
  (ref 05 §Perfiles).
- **La `CODERABBIT_API_KEY` NO la lee el CLI del entorno**: el escrow la entrega y
  `push-carril-env.sh` la escribe en `auth.json`; tenerla solo como variable de entorno del
  shell no es suficiente (el CLI lee exclusivamente el fichero).
- **[TAL-3318] Dejar el CLI AUTENTICADO es parte del MONTAJE de la estación**, no un paso
  diferible a la primera corrida: una estación con la key solo exportada llega "lista" y falla su
  primer review real (lección del arranque CRM). La aceptación del montaje incluye `auth.json`
  escrito (patrón printf de arriba) + verificación de identidad por digest (ref 05 §Imposición
  del perfil) — sin correr un review de verdad.
- **Verificar la identidad sin imprimir la key**: pasar el patrón por stdin —
  `printf '%s' "$k" | grep -Fqf - ~/.coderabbit/auth.json` (`-F`: literal, no regex) con `k`
  extraído del env por nombre (ver ref 05 §Perfiles §Verificar identidad).
- Cross-refs: seat CR, mutex por PR y contrato de revisión → `talent-merger`
  `references/04-coderabbit-cli-y-app.md`; superficies sensibles + política de severidad →
  `talent-merger` ref 03; `verify.sh` impone la identidad CR por canal fail-closed (ref 05
  §Imposición del perfil — md5 del `apiKey` de `auth.json` == md5 de la key del escrow,
  calculado dentro del contenedor, solo cruza el digest).

### Buzón espejo del flock

Cada pane del Mergeador mantiene un **mailbox local append-only** que se espeja al flock de
coordinación. Contrato:

- **Fichero local**: `m<N>-flock-out.txt` (donde `<N>` es el número de canal del Mergeador,
  p. ej. `91`) dentro de un **directorio privado del usuario `0700`** (p. ej.
  `mkdir -p -m 0700 "$XDG_RUNTIME_DIR/mrg"` o un `mktemp -d`), **no** un nombre predecible suelto
  bajo `/tmp` (que otro usuario local podría precrear como fichero/symlink para inyectar líneas o
  romper la escritura). Crear el fichero de forma exclusiva y `0600` (`O_EXCL` / `set -o noclobber`
  con `>` la primera vez, o `install -m 0600 /dev/null <ruta>`), **validar el propietario** antes
  de espejar, y escribir en modo append (`>>`); **nunca se trunca** durante la sesión — facilita
  auditoría y replay.
- **Espejo al flock**: las líneas nuevas se transportan **byte-a-byte** (sin reinterpretación de
  escapados ni re-encoding) con **dedupe por línea** — una línea ya enviada no se reenvía aunque
  el fichero se reprocese desde el inicio.
- **Límite no-CAS (escritura asíncrona)**: el buzón es de escritura directa, no atómica; el espejo
  es best-effort asíncrono. Los **claims atómicos** del Mergeador (p. ej. "tomo el PR X") van por
  **write directo al canal del flock** — no a través del buzón — porque requieren la garantía de
  entrega ordenada del transporte del flock.
- Cross-refs: formato del flock (cabecera, campos, delimitadores) → `talent-merger`
  `references/01-rol-y-fronteras.md` §2 (Actores y fronteras); claims y mutex por PR →
  `talent-merger` `references/04-coderabbit-cli-y-app.md`; contrato de despacho al flock →
  `talent-channel-operation`.

## Contrato del perfil (runner sellado)

- **Usuario `runner` limpio y SIN credenciales de ningún tipo** — ni logins de agente, ni tokens
  gh/linear/supabase. El **preflight del motor barre TODO el contenedor** buscando credenciales y
  aborta si encuentra alguna (anti-self-report: el runner no puede postear su propio status).
- **[TAL-3318/F4] El usuario `runner` NUNCA pertenece al grupo `docker` ni escribe en
  `/var/run/docker.sock`**: el runner ejecuta código de PR NO confiable, y la membresía docker es
  root-equivalente dentro del contenedor (docker.sock ⇒ contenedores privilegiados ⇒ escape del
  sellado: leer todo el contenedor y manipular receipts/journal del gate = self-report). Los
  wrappers que necesitan docker (Supabase efímero de db-guards/e2e) usan **docker rootless del
  propio usuario `runner`** (dockerd-rootless en su sesión;
  `DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock`), nunca el daemon root del contenedor.
  **Aceptación (manual, fail-closed — patrón §6)**: `incus exec <runner> -- id -nG runner` NO
  contiene `docker` (membresía ⇒ FAIL: el runner NO entra al pool) Y el socket root
  `/var/run/docker.sock` no es escribible por `runner`. Flotas ya desplegadas con el runner en el
  grupo docker: retirar la membresía (`deluser runner docker`), habilitar rootless y re-correr la
  aceptación ANTES de la siguiente tanda; automatizar este check en el preflight del motor =
  mismo follow-up §6.
  **[TAL-2630]** `verify.sh` de este skill lo verifica también, fail-closed: un canal declarado
  `runner` (mapa `channel-profiles.list` / `TC_RUNNER_CHANNELS`) debe estar limpio de credencial
  EFECTIVA en **cualquier home real incl. `/home/runner`** — artefactos de auth canónicos ausentes
  (`.coderabbit/auth.json`, `.claude/.credentials.json`, `.codex/auth.json`, `.config/gh/hosts.yml`)
  y ningún `.env.local` con asignación sensible. Reutiliza el scanner sellado del motor si
  `TC_CRED_SCANNER` apunta a su entrypoint; si no, el fallback canónico. Declarar los runners en el
  mapa es parte del rollout (`channel-profiles.sh set vibe-channel-85 runner … 88`).
- **Checkout interno + assert `HEAD == sha`**: el runner clona/checkoutea él mismo el SHA a gatear
  y aborta si el HEAD resultante no coincide — nunca confía en un árbol que le empujaron.
- **La estación vive a nivel HOST, no dentro de un contenedor**: el modo sellado exige el cliente
  `incus` (push de ficheros, exec) y la identidad `gh` de la fábrica — un contenedor unprivileged
  no puede orquestar a otros. El Mergeador orquesta desde el host; los runners solo ejecutan.
- **Motor v2 = UN gate por invocación** (`run-local-gates.sh --gate <id>`) que emite **receipts
  parciales**; los agrega y postea `post-local-gates.sh` (fail-closed: receipt faltante = rojo).
- **Wrappers de producto dueños de su stack efímero**: `run-db-guards-local.sh` /
  `run-e2e-shard-local.sh` / `run-integration-local.sh` levantan y destruyen su propio Supabase
  efímero; el registro canónico de shards es `scripts/ci/e2e-shards.json` (con
  **anti-reducción base→head**: el registro de `base_sha` es el mínimo confiable).

## Aprovisionamiento (deltas sobre el flujo normal de este skill)

1. Clonar del golden como cualquier canal; crear el usuario `runner` limpio (sin herencia de
   `vivecoder` ni de sus dotfiles de agente).
2. **[TAL-3318] De-sudo del canal — con el `$CUSER` RESUELTO de la fábrica**: el golden da a
   `$CUSER` sudo NOPASSWD y crea el drop-in `/etc/sudoers.d/90-$CUSER` (`02-golden.sh` paso 3), y
   el clon lo HEREDA — en un runner sellado esa escalada es inaceptable y el preflight del motor
   lo rechaza. Hornear con el usuario CONFIGURADO de la fábrica (default `vivecoder`, pero `CUSER`
   es configurable — de-sudar un nombre hardcodeado deja al usuario real con sudo):
   `deluser "$CUSER" sudo` + `rm -f "/etc/sudoers.d/90-$CUSER" /etc/sudoers.d/90-cloud-init-users`
   (los drop-ins otorgan por sí solos; borrarlos, no solo sacar del grupo). La red fail-closed es
   el preflight del punto 5: barre la escalada residual sea cual sea el usuario.
3. **Instalar `psql`** — lo exige el shard `e2e-ola3` (no viene en la toolchain mínima del golden).
4. En el intake, dejar **TODAS** las credenciales vacías para estos canales — el env por carril de
   un runner no existe o está vacío por diseño.
5. **[TAL-3318] El preflight del motor ES el test de aceptación del runner**: correrlo COMPLETO
   (barrido de credenciales + ausencia de sudo/sudoers + entorno del gate) contra CADA runner
   recién horneado, ANTES de declararlo en el pool — no al primer PR real. Un runner que falla el
   preflight en producción bloquea la cola del Mergeador; el mismo fallo en el smoke de
   aprovisionamiento cuesta minutos.

### Provisión por RÉPLICA de un runner sano (validado en vivo, R88 2026-07-14)

El repo es **privado** y el runner no tiene credenciales → NO puede clonarse el repo desde dentro.
La provisión correcta de un runner nuevo sobre un canal existente:

1. Crear usuario `runner` (uid 1002, **SIN grupo `docker`** — F4: docker rootless propio, ver
   Contrato del perfil), SIN dotfiles de agente.
2. **REPLICAR `/home/runner` desde un runner sano vía tar** (repo + `node_modules` ~1.5G + caché de
   playwright) — no `git clone` (sin creds), no npm-install desde cero (lento y con drift).
3. **Limpiar el resto del contenedor**: si el canal tenía perfil producción, el preflight FALLARÁ
   por las credenciales de `vivecoder` (gh/codex/claude/`.env.local`) — retirarlas y matar sesiones
   idle de `vivecoder`.
4. **Reasignar `/tmp/local-gates` y el lock del runner** (`/tmp/local-gates-runner.lock`) al usuario
   `runner` si existían de una vida anterior (owned por `vivecoder` = fallos raros de journal).
5. Smoke: un gate rápido (typecheck) + un shard e2e sellados y VERDES antes de declararlo en el pool.

## Gotchas operativos del runner

1. **`incus file push` = overwrite-denied**: hacer `rm` del fichero destino ENTRE pushes (motor,
   manifiesto) o el push falla en silencio operativo.
2. **Motor + manifiesto se pushean y van STALE**: lo que corre el runner es la copia pusheada, no
   el repo del host — verificar por **sha-check** que la copia es la esperada antes de cada tanda.
3. **1 PR por runner, serial**: los gates compiten por CPU/RAM/docker del host — paralelizar PRs
   en el mismo runner produce flakes de contención, no throughput. Con el fan-out de `seal-suite`
   (TAL-2706) la concurrencia entre RUNNERS sí es segura, pero **capada** (`TF_E2E_CONCURRENCY`,
   default 3): más e2e concurrentes que el cap satura el host y reintroduce los flakes.
4. **NUNCA SIGTERM a un gate vivo**: matarlo deja el stack Supabase efímero **huérfano** (puertos y
   contenedores docker tomados) → el siguiente gate falla raro. Si hay que abortar: dejar terminar
   o limpiar con `docker rm -f` de los contenedores del stack ANTES de re-correr.
5. **Typecheck en contenedor frío**: un rc=2 en ~3 s **sin `node_modules`** no es un FAIL del
   código — es el cold-container sin dependencias; re-correr ese gate sellado individual (doctrina
   de la estación en `talent-merger` ref 08 §5).
6. **`.next` stale por checkout**: el runner reutiliza el árbol entre PRs — `rm -rf .next` tras el
   checkout o typecheck/build fallan con rutas fantasma (TS2307).
