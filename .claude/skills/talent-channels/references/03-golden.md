# 03 — Construir el golden

## Table of Contents

- [Guard anti-destrucción + CoW por fábrica (TAL-2296)](#guard-anti-destrucción--cow-por-fábrica-tal-2296)
- [Pasos](#pasos)
- [Vigencias pendientes (decisión de lead requerida)](#vigencias-pendientes-decisión-de-lead-requerida)

`scripts/02-golden.sh` crea el contenedor plantilla `$GOLDEN` (por defecto `golden`). Repo-agnóstico.
**No hornea `.env.local` operacional NI credenciales de agente** (eso es per-carril, ver 05).

## Guard anti-destrucción + CoW por fábrica (TAL-2296)

Recrear un golden EXISTENTE ya **NO es la vía por defecto**: `02-golden.sh` **rehúsa** borrar un
golden que ya existe y exige `--force` (o `TC_GOLDEN_FORCE=yes`). Motivo: la plantilla es cara de
reconstruir y en **multi-fábrica** es la base de clonado de esa fábrica.

- **Reconstruir a propósito**: `sudo bash scripts/02-golden.sh --force` (o `provision.sh
  --force-golden`). Aviso que imprime: los clones ya creados son subvolúmenes **independientes** y
  sobreviven; lo que se pierde es la plantilla y sus retoques.
- **Fábrica NUEVA sin tocar la existente**: exporta un nombre propio `GOLDEN=golden-<proyecto>` — cada
  fábrica clona de SU base CoW (`golden-funnel`, `golden-academia`…), sin pisar la de otra. Combínalo
  con `SECRET_DIR=…-<proyecto>` y (si conviven en el host) `TS_PORT_BASE` distinto (ver `01`).

## Pasos

1. `incus launch $IMG golden` + `security.nesting=true` + espera salida real a internet (TCP).
2. apt base (git, build-essential, tmux, openssh, jq, **unzip** — requisito del CLI de CodeRabbit, ver 5b —, **bubblewrap**, **docker.io**, docker-compose-v2) + **gh** (repo oficial) + **Tailscale** (userspace + override no-fatal desde asset; queda **sin login**).
3. Usuario `$CUSER`: password desde `$SECRET_DIR/cuser-pass` (recuperable), **sudo NOPASSWD** (sandbox) + grupo docker. Crea `~/.claude` y `~/.codex` y **los chownea a `$CUSER`** (críticos: si quedaran de `root`, Codex no puede crear su sqlite `~/.codex/state_5.sqlite`).
4. **Clonar el repo con git-bootstrap-token EFÍMERO**: `GIT_ASKPASS` lee un fichero transitorio; clona `https://x-access-token@…`; deja `origin` **sin token** (`remote set-url` a la URL limpia). **Limpieza garantizada del secreto** con doble `trap` (host-side al `EXIT` del script + dentro del shell del contenedor): `~/.gbt`/`~/.gitaskpass` se borran (`shred`) aunque el clone falle a mitad. Verifica que `origin` no lleva token.
5. **Node** = versión del repo (`.nvmrc`/`engines`) o LTS, **con suelo de parche** (issue 9558): la mayor
   sale del repo, pero el parche que deja nodesource se COMPRUEBA tras instalar. Los suelos viven en UN
   solo sitio, `assets/node-suelos.tsv` (24 → 24.22.1 · 22 → 22.23.4 · 26 → 26.12.1; fuente y fecha en su
   cabecera: aviso de Node del 21-oct-2026). Por debajo del suelo, o con una mayor que no figure en el
   fichero, el golden **FALLA** (rc ≠ 0, mensaje claro): nunca avisa y sigue. Para subir un suelo con un
   aviso nuevo se edita su fila. La prueba (`tests/node-suelo.sh`) usa un doble de `node -v`; el caso de
   la 24 vulnerable queda como check permanente. En el mismo paso se deja `ca-certificates` al día
   (`--only-upgrade` tras instalar nodejs; ya se instala en [2/9]). Luego los CLIs **npm globales instalados como
   ROOT** (`@anthropic-ai/claude-code`, `@openai/codex`, `@railway/cli`, `convex`, `supabase`): el
   **prefix npm es root-managed** a propósito — el usuario del carril NO tiene permiso sobre él, así
   que un self-update lanzado desde el pane fallaría con EACCES y MATARÍA el proceso (el pane caería a
   un shell). Por eso además va `DISABLE_AUTOUPDATER=1` (Claude) + `check_for_update_on_startup=false`
   (Codex): la versión queda **fija a la de instalación** (equivalente a un pin de arranque) y la
   actualización es **explícita** (la última estable con ≥ 72 h, resuelta por `resolver-herramientas.sh` y registrada en `/etc/talent-channels/herramientas.lock`).
   El binario de CodeRabbit (`[5b]`) va por artefacto versionado con sha256 verificado (detalle abajo).
   **[TAL-3318] Node a nivel SISTEMA (no PATH de perfil)**: los gates del motor, los runners y
   cualquier `incus exec` corren en shells **NO interactivas** donde `.bashrc`/nvm/exports de perfil
   no se cargan — si Node solo resuelve vía PATH de perfil, esos entornos fallan con `node: not
   found` y los gates quedan rojos "por entorno" (lección del arranque CRM 2026-07-22). Node/npm
   deben resolver **sin entorno**: instalación root-managed visible en `/usr/local/bin` (patrón
   validado en flota: tarball oficial en `/opt/node24` + symlinks `node`/`npm`/`npx`/`corepack` en
   `/usr/local/bin`). **Aceptación (MANUAL del operador)**: `incus exec <canal> -- env -i
   PATH=/usr/local/bin:/usr/bin:/bin sh -c 'node -v && npm -v'` — mismo entorno no interactivo que
   los gates, con PATH mínimo del sistema porque npm es un script `#!/usr/bin/env node` (con
   `env -i` sin PATH no resuelve node); cubre node Y npm. `verify.sh` hoy valida la toolchain vía
   `bash -lc` (shell de LOGIN que SÍ carga el perfil), así que su verde NO prueba resolución sin
   entorno; automatizar este check es follow-up declarado.
   **Matiz corepack**: `pnpm -v`/`yarn -v` solo
   son señal fiable DENTRO del repo (corepack resuelve el shim por el `packageManager` del
   `package.json` del cwd); fuera del repo pueden fallar sin que nada esté roto.
5b. **CodeRabbit CLI (`coderabbit`/`cr`) — review pre-PR, NO es paquete npm** (TAL-1502/TAL-1512):
   el binario forma parte del **gate pre-PR**, así que su integridad importa. El instalador oficial
   del vendor (`curl | sh`) **no verifica checksum** — por eso NO se usa: en su lugar se descarga el
   **artefacto versionado** directo (`cli.coderabbit.ai/releases/$CR_CLI_VERSION/coderabbit-linux-$ARCH.zip`)
   y se verifica su **sha256 contra un hash pineado por arquitectura** (`CR_CLI_SHA256_X64`/`_ARM64`),
   **FAIL-CLOSED** si no coincide (no se instala). Versión y hashes son pin **duro**, no overrideable
   por env — permitir override dejaría pasar un binario distinto con su propio sha. La auth va
   **per-carril** (`push-carril-env.sh` escribe `~/.coderabbit/auth.json` directo, sin exponer la key
   en argv). **Para subir de versión**: descargar el zip nuevo (x64 y arm64), capturar su sha256 real
   (`sha256sum`), actualizar `CR_CLI_VERSION` + ambos hashes en `02-golden.sh`, y confirmar que el
   formato de `auth.json` no cambió.
6. **[TAL-2294] El golden NO hornea NINGUNA credencial de agente** (ni Claude ni Codex): un login vive en UN solo lugar — hornearlo lo clona a cada carril por CoW y re-arma la cascada de rotación del refresh token (causó la caída F2). Las credenciales llegan **per-carril tras clonar**: Claude por `refresh-claude-auth.sh`, Codex por **`auth-move.sh move`** (MOVE transaccional un-login-un-lugar; `refresh-codex-auth.sh all` queda PROHIBIDO — ver 05). El golden viaja **SIN identidad git** (ni la del host — firmar como el host rompe la trazabilidad de autoría por canal, medido en producción — ni la rama silenciosa «sin gitconfig»): la identidad es **POR CANAL**, escrita en `03-clone` expandiendo el ÚNICO placeholder `{channel}` sobre `TF_CHANNEL_GIT_NAME_TMPL`/`TF_CHANNEL_GIT_EMAIL_TMPL` del manifiesto de la fábrica (los VALORES — nombre y dominio — viven en el manifiesto por fábrica, jamás en el paquete), con abort fail-closed si faltan las claves o el placeholder no resuelve, y verificación de vuelta; `verify.sh` (scope identity) exige la igualdad exacta de ambos valores en producción y mergeador; para flotas EXISTENTES, `migrate-channel-identity.sh` re-bakea con salida literal por canal (la reconciliación de commits/WIP con identidad anterior es un paso SEPARADO del rollout, bajo PARO). El `.gitconfig` completo del host sigue sin viajar JAMÁS (puede arrastrar `credential.helper`/`http.extraHeader`/`insteadOf`/tokens). **Rol de Codex**: escribe `assets/codex-role.txt` en `~/.codex/AGENTS.md` (rol persistente: auditor/analista, nunca escribe código ni sube a GitHub) y en `~/.codex/role-prompt.txt` (prompt de arranque inmediato que lanza `v`) — el rol/config NO son credenciales.
6b. **[TAL-2296] Baseline de Claude (UI + modelo), NO credenciales**: el golden siembra
   `~/.claude.json` con `hasCompletedOnboarding: true` (para que ningún clon quede bloqueado en el
   wizard de onboarding la 1ª vez) y `~/.claude/settings.json` con `{"model":""}` (valor neutro).
   La preparación aplica el identificador completo de Sonnet vigente del registro: `doctrina-modelos-multifabrica` /
   `talent-orchestrator` ref 11). Un **hard check anti-regresión** aborta si aparece
   `~/.claude/.credentials.json` o `~/.codex/auth.json` (el golden NO hornea credenciales, TAL-2294).
   La **verificación de que el default está VIVO** sigue siendo gate per-carril del coordinador (ref
   06 §Agentes al día); aquí solo se hornea la línea base.
   **[TAL-3318] Diálogos trust + bypass — siembra MANUAL post-provision** (mecanismos VERIFICADOS
   en el arranque real de la fábrica CRM, 2026-07-22). **Hoy NO los hornea `02-golden.sh`** — el
   paso `[6b/9]` actual solo escribe `hasCompletedOnboarding` y `model` — **ni los comprueba
   `verify.sh`**; hasta que el provisioning los incorpore (follow-up declarado), los siembra el
   OPERADOR en el golden y/o por barrido a la flota. Sin ellos, el PRIMER arranque de cada clon se
   bloquea en dos diálogos interactivos que ningún coordinador ve (el pane parece colgado). Los
   DOS flags reales:
   - `~/.claude.json` → `projects["<ruta-absoluta-del-repo>"].hasTrustDialogAccepted: true` — es
     **POR PROYECTO**: la clave del objeto `projects` es la ruta exacta del repo dentro del
     contenedor (p. ej. `/home/vivecoder/<REPO_DIR>`); una ruta distinta = diálogo de trust intacto.
   - `~/.claude/settings.json` → `"skipDangerousModePermissionPrompt": true` — suprime el prompt
     del modo bypass que disparan `claude-root`/los lanzadores `v`.
   **Anti-placebo**: `bypassPermissionsModeAccepted` NO es el flag que gobierna ese diálogo — queda
   `null` incluso en canales ya usados; sembrarlo no hace nada. Sembrar SIEMPRE ambos ficheros con
   `incus file push` de un JSON válido pre-escrito (jamás printf con escapes anidados a través de
   SSH/`incus exec` — así nació el bug `x27` que corrompió los baselines de 24 contenedores).
   **Aceptación (manual, fail-closed)**: releer ambos flags con `jq -e` — que falla por sí solo
   ante fichero ausente, clave ausente o valor ≠ `true` — en el golden Y en un clon de muestra
   ANTES de declarar la flota utilizable; **config AUSENTE = FAIL explícito, nunca silencio**:
   `incus exec <c> -- su - "$CUSER" -c 'jq -e ".projects[\"<ruta-repo>\"].hasTrustDialogAccepted == true" ~/.claude.json'`
   y `incus exec <c> -- su - "$CUSER" -c 'jq -e ".skipDangerousModePermissionPrompt == true" ~/.claude/settings.json'`
   (rc≠0 en CUALQUIERA de los dos ⇒ FAIL). El verde de `verify.sh` NO los cubre.
7. tmux (`mouse on`, **`extended-keys on`** + `terminal-features *:extkeys` para shift+tab→plan) + `.bashrc`: alias `claude-root`/`codex-root` **y sus lanzadores ejecutables `~/.local/bin/claude-root` y `codex-root`** (mismos flags, fail-closed: `tmux respawn-pane` ejecuta con `bash -c`, sin `.bashrc`, y un alias no arranca el CLI del despacho), `CLAUDE_CODE_DISABLE_MOUSE=1`, y **tokens loader** (render de `assets/tokens.bashrc.tmpl` con `REPO_DIR`/`ENV_DEST`).
7b. **[TAL-8038] Renderer CLÁSICO + barra `ctx:`** (`[7b/9]`, `scripts/apply-renderer.sh`, fail-closed, idempotente): tres capas
   — `~/.claude/settings.json` con `.tui="default"` + `.statusLine` (barra `[modelo] ctx: NN%`, instalada por
   `talent-context/scripts/install-statusline.sh`, que además exige Claude ≥ `assets/claude-min-version`, hoy 2.1.289) ·
   `export CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1` en `.bashrc` (guard PROPIO: el del alias `claude-root` no sirve) ·
   `set -g alternate-screen off` en `.tmux.conf`. Sin ellas el CLI puede caer en pantalla alternada (el pane no tiene
   scrollback: PLAN y handoff no capturables) y ningún pane emite `ctx:` (compact-60 ciego). `verify.sh` comprueba las tres
   capas y la versión mínima por canal. **Canales YA clonados**: `bash scripts/apply-renderer.sh [--only <canal>] [--force]`
   las aplica sin matar sesiones (las `claude` abiertas conservan su renderer hasta relanzarlas; `--force` pisa una
   `statusLine` ajena, que por defecto se conserva y cuenta como FALLO).
8. **Dependencias del repo con el gestor DETECTADO** (no asumir npm): `corepack enable` + el campo
   `packageManager` de `package.json` → `pnpm`/`yarn` (via corepack) o `bun` si está; `npm` por
   defecto. + Playwright (chromium/firefox) **solo si el repo lo usa** (detecta `@playwright/test`).

**Siembra OPCIONAL del motor `talent-factory`** (`[4b/9]`, multi-fábrica): si `TF_REPO_URL` está
definido, el golden clona el motor junto al repo de producto (mismo patrón de token efímero:
re-push + doble trap + shred garantizado), en `~/$TF_REPO_DIR` — **desambiguado** del repo de
producto (aborta si `TF_REPO_DIR == REPO_DIR`). Así la flota lleva por CoW `run-local-gates.sh` /
`validate-manifest.sh`. **Aviso**: el motor puede ir **detrás de su origin** — `git -C ~/$TF_REPO_DIR
pull` antes de correr gates. Sin `TF_REPO_URL` no se siembra nada (repo-agnóstico).

El software y la config se hornean en el golden y los clones lo heredan por **CoW**. Lo per-carril (tras clonar): **credenciales de agente** (Claude/Codex — nunca horneadas, TAL-2294), env+gh, tailscale (ver 04/05).

**Auto-update de los CLIs DESHABILITADO en el golden** (`02-golden.sh`): el prompt "Update
available!" del CLI (codex) **bloquea el priming del rol de auditoría** al arrancar (síntoma en el
despacho: "CLI auditoría no LISTO 90s"), y el aviso recurrente "npm auto-update failed: no write
permission to npm prefix" ensucia cada pane. El golden fija `DISABLE_AUTOUPDATER=1` (+ silencia el
notifier) y deja el prefix npm gestionado por root, de modo que la actualización es **explícita**
(`claude update` / `npm i -g @openai/codex@latest`, gate de reanudación de la ref 06), nunca un
prompt interactivo que interrumpa el arranque.

> Statusline de Claude: desde TAL-8038 NO es opcional ni manual — la barra `ctx:` la instala el paso `[7b/9]` (ver arriba). Una statusLine propia del operador no se pisa sin `--force`.

Tras el paso 8, `[9/9] Verificación` imprime un resumen final del golden (paquetes clave, propiedad
de `~/.claude`/`~/.codex`, ausencia de credenciales) antes de detenerlo — el golden no autostartea
ni se une al tailnet (ver gotcha 10 del `SKILL.md`).

## Vigencias pendientes (decisión de lead requerida)

Dos vigencias identificadas en la auditoría de estado del arte julio 2026 son **decisiones de
arquitectura/infraestructura**, no correcciones mecánicas — este skill NO las implementa, solo las
documenta:

- **Ubuntu 26.04 LTS "Resolute Raccoon"** (liberado 2026-04-23, soportado hasta 2031) vs el
  `IMG=images:ubuntu/24.04` actual (`scripts/00-config.sh`): 24.04 sigue soportado hasta 2029 y es
  la base probada de la flota; migrar exige validación empírica en máquina real.
- **Repo Zabbly de Incus** (rama 7.x vigente + UI web, `github.com/zabbly/incus`) vs el paquete
  nativo del repo Ubuntu (`scripts/01-incus-base.sh`), que en 24.04/26.04 solo trae la rama **Incus
  6.0 LTS**: el caso de uso de este skill (contenedores unprivileged + btrfs + NAT) está cubierto
  por 6.0 LTS sin necesitar la UI web ni features de 7.x.

Si el lead decide adoptar cualquiera de las dos, debe salir como issue separada, de mayor esfuerzo,
con validación empírica en máquina real — no como parte de un refresh de vigencia.

Registro de modelos: `~/.config/talent-channel-operation/modelos.conf` del usuario del rol; los roles se resuelven por proveedor con `tco_modelo_read` (tabla en `talent-channel-operation`, ref 11): CEO, PM, plan, re-plan y código sensible usan Opus vigente; código y coordinación, Sonnet vigente; el auditor es de otro proveedor. Resolver tras acreditar Claude con `talent-channel-operation/scripts/resolver-modelos.sh`.
