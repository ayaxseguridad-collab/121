---
name: talent-channels
description: >
  Aprovisionar, recrear y operar el sistema de "canales/carriles" de desarrollo en una
  máquina Ubuntu 24.04+ NUEVA: contenedores Incus unprivileged sobre pool btrfs (CoW) +
  red NAT + un contenedor golden con toolchain completa (Node, Claude Code, Codex, gh, tmux,
  docker, playwright) clonado en N canales `vibe-channel-<maquina><channel>` unidos a Tailscale,
  con autostart y lanzadores v<XY>. Autosuficiente, parametrizado y REPO-AGNÓSTICO; el skill
  PREGUNTA (nº de máquina, repo y credenciales: Linear/Supabase/Convex/GitHub/Tailscale/...).
  Token-only, NO MCP. Trigger keywords (ES/EN): "carriles", "canales", "channels", "vibechannel",
  "golden", "incus", "aprovisionar máquina nueva", "montar los carriles", "recrear los canales",
  "provision channels", "setup carriles", "tailscale carril", "clonar carril", "v11",
  "claude-root", "codex-root", "maquina nueva carriles", "enable-gpu carril",
  "provisioning ubuntu", "incus container", "btrfs pool", "claude code parallel",
  "aprovisionamiento flota".
---

# Talent Channels — Aprovisionar canales de desarrollo (Incus + Tailscale) — julio 2026

## Quick Orientation

| Propiedad | Valor |
|---|---|
| Qué monta | Incus (contenedores **unprivileged**) · pool **btrfs CoW** en disco dedicado · red **NAT** · **golden** plantilla · N clones `vibe-channel-<x><y>` · **Tailscale** (userspace) · autostart · lanzadores `v<XY>` |
| Para qué | Correr varios **Claude Code + Codex** en paralelo, cada carril aislado, sobre un repo |
| Repo | **Repo-agnóstico**: el repo objetivo es un parámetro (`REPO_URL`) |
| Identidad | Canales `vibe-channel-<MÁQUINA><CHANNEL>` → **únicos en el tailnet** entre máquinas (el skill pregunta el nº de máquina) |
| Credenciales | El skill **PREGUNTA** (intake): nº máquina, repo, y tokens Linear/Supabase/Convex/GitHub/Tailscale/… **Token-only, NO MCP** |
| Rol del agente | Provisioner con **barra de seguridad** en acciones destructivas (formateo de disco con confirmación re-tecleando el device) |
| Plataforma | Ubuntu/Linux (Incus de sistema). Fuera: Windows/macOS |

**Dos flujos, no confundir:**

- **Flujo B — runtime del skill (`provision.sh`)**: aprovisiona la infra **local**. NO toca Linear/Supabase/prod. Es lo que corres en la máquina nueva.
- **Flujo A — entrega del PR de este skill** (gates de repo: BD sync, Linear, CodeRabbit): solo para *meter el skill al repo*, no para usarlo.

**Terminología (Fábrica v2, ADR-0043)**: «canal» es el término canónico; **«carril» es
sinónimo histórico de «canal»** — los nombres existentes (`vibe-channel-*`, scripts
`*-carril-*`, `$SECRET_DIR/env/<canal>.env`) no cambian. Los canales tienen **perfil** por
credenciales: **producción** (sin `CODERABBIT_API_KEY`, sin token Supabase) vs **Mergeador**
(con ambos) vs **piloto** ([TAL-5142] canal de LABORATORIO: mismas credenciales/reglas que
Mergeador, separado por NOMBRE para no confundirlo con una estación de merge real) vs **runner
sellado** (SIN credenciales; local-gates v2) — ver `references/05-credenciales-por-carril.md`
§Perfiles y `references/08-runners-del-mergeador.md`.

## Patrones esenciales

Fases de `provision.sh` (array `PHASES[]`, idempotente y reentrante) — los dos preflights
host-side son **run-once** y disparan la primera vez que aplican, en cualquier ruta de entrada
(`--from`/`--only`/reanudar):

```text
intake → disk → network → golden → golden-ts → clone → env → autostart → launchers → verify

  preflight(logins) → antes de 'disk' o 'golden' (verifica login Claude/Codex del HOST)
  preflight(tokens) → antes de 'env' (verifica GITHUB_TOKEN/LINEAR_API_KEY/SUPABASE_ACCESS_TOKEN)
```

Identidad de canal — de dónde sale cada dígito de `vibe-channel-<MÁQUINA><CANAL>`:

```text
vibe-channel-<MÁQUINA><CANAL>
              │        └─ nº de canal (1..COUNT) en ESTA máquina
              └─ nº de máquina (MACHINE_NUM, 0-9, intake) → único en el tailnet entre máquinas
```

## Reference Files (leer según necesidad)

| Necesito… | Reference File |
|---|---|
| Arquitectura + config/autodetección | `references/01-arquitectura-y-config.md` |
| Elegir disco + crear pool (destructivo) | `references/02-disco-y-pool.md` |
| Construir el golden | `references/03-golden.md` |
| Clonar canales + Tailscale | `references/04-clonado-y-tailscale.md` |
| Credenciales por carril + acreditación de agentes | `references/05-credenciales-por-carril.md` |
| Operación diaria + lanzadores + GPU | `references/06-operacion-y-launchers.md` |
| Verificación + gotchas + troubleshooting | `references/07-verificacion-y-gotchas.md` |
| Runners sellados del Mergeador (local-gates v2) | `references/08-runners-del-mergeador.md` |

## Quick Start (máquina nueva)

```bash
# 1) (opcional) ver discos candidatos para el pool
sudo bash scripts/disk-scan.sh

# 2) aprovisionar TODO (intake interactivo: pregunta máquina, repo, credenciales)
sudo bash scripts/provision.sh --disk /dev/XXX
#   o paso a paso:  --only intake | --from golden | --count N | --repo URL | --dry-run

# 3) tras el provision: acreditar por PROPAGACIÓN (canónico) — Claude: refresh-claude-auth.sh all
#    (automatizado, cosecha del HOST); Codex: auth-move.sh move (un-login-un-lugar, desde el host).
#    'claude login'/'codex login' per-carril quedan como último recurso (ver references/05).
v11             # entra al canal 1 de la máquina 1 (tmux: Claude izq | Codex der)
```

`provision.sh` ejecuta, en orden: **intake → preflight → disco → red → golden → golden-ts → clone → env-por-carril → autostart → launchers → verify**, idempotente y reentrante. Las credenciales y el nº de máquina se piden en el **intake** (`00-intake.sh`).

## Config & autodetección

- **Autodetecta**: usuario host (vía `SUDO_USER`/`getent`, nunca root directo), repo actual (default de `REPO_URL`), `REPO_DIR` limpio (https/`git@`/`.git`/espacios).
- **Pregunta (intake)**: `MACHINE_NUM` (x), `REPO_URL`, `COUNT`, password del contenedor, `TS_AUTHKEY`, git-bootstrap-token, y credenciales por carril (manifest `assets/creds.manifest` + descubrimiento de `.env.example`).
- **Defaults overridables**: `POOL=carriles`, `BRIDGE=incusbr0`, `IMG=images:ubuntu/24.04`, `GOLDEN=golden`, `PREFIX=vibe-channel-`, `CUSER=vivecoder`, `TS_PORT_BASE=41640`, `ENV_DEST=.env.local`. Node = versión del repo (`.nvmrc`/`engines`) o LTS.
- **Secretos**: runtime-only en `$SECRET_DIR=~/.config/talent-channels` (0700) + ficheros 0600. **Nunca** en el repo.

## Critical Gotchas

1. **Docker↔Incus FORWARD DROP**: Docker pone iptables FORWARD a DROP → contenedores sin internet (DNS resuelve, TCP expira). Fix: regla ACCEPT para `incusbr0` + servicio `incus-forward` (01b).
2. **TUN en unprivileged**: no hay `/dev/net/tun` → Tailscale en **`--tun=userspace-networking`**.
3. **tailscaled `--cleanup` no-fatal**: el cleanup falla en unprivileged → override systemd `ExecStartPre=-` (asset `tailscaled-override.conf`).
4. **Puerto Tailscale distinto por carril** (`41640+y`): si comparten 41641 colisionan en la NAT y unos quedan inalcanzables.
5. **gh sin keyring**: en contenedor no hay keyring → `gh auth login --with-token` (token del env por carril), no copiar `hosts.yml` del host.
6. **tmux `extended-keys on`** + `terminal-features *:extkeys`: necesario para que **shift+tab → plan mode** llegue a Claude.
7. **`CLAUDE_CODE_DISABLE_MOUSE=1`**: evita captura de ratón en el panel.
8. **Credenciales de agente (TAL-2294, TAL-2279)**: el golden **NO hornea ninguna**. La **propagación es el método CANÓNICO** de acreditación y re-auth para ambos agentes; el login interactivo per-carril queda como **excepción de último recurso** (solo sin donante con token vivo, p. ej. refresh-token revocado — ver `references/05`). **Claude** (caduca por idle, no fleet-wide) se propaga por **copia**, en dos vías: automatizada host→canales (`refresh-claude-auth.sh all`, cosecha del HOST) o manual hermano→canal (canal activo con token vivo → canal muerto, sin tocar el host). **Codex** (refresh de un solo uso → cascada si se copia en fan-out): canónico es el **MOVE** (`auth-move.sh move`, un-login-un-lugar); `refresh-codex-auth.sh all` está PROHIBIDO — el COPY de un hermano es solo reauth táctico de emergencia, con caveat de cascada, nunca canónico. Ver `references/05`.
9. **NO MCP** (TAL-1490): operación por **tokens** auto-cargados del env por carril; el skill nunca introduce `.mcp.json`.
10. **golden** no autostart y **no se une al tailnet** (plantilla; se detiene tras parchear).
11. **Identidad por clon**: regenerar `hostname`/`machine-id`/ssh host keys/`tailscaled.state` o colisionan en el tailnet.
12. **Rutas con espacios** (`HOST_REPO`) siempre comilladas.
13. **Tailscale SSH remoto** requiere **regla `ssh` en la ACL** del tailnet. Si no está, `v`/`vk` **caen automáticamente** a **acceso LOCAL** `incus exec <canal> -- su - vivecoder` (local-only, NO sustituye el acceso remoto desde otros dispositivos del tailnet).
14. **Un env por carril** (token-por-carril): no compartir tokens entre canales (trazabilidad).
15. **`provision.sh` no toca Linear/Supabase/prod** (eso es Flujo A).
16. **GPU opcional**: `enable-gpu.sh <canal>` (off por defecto). RTX de consumo **sin MIG** → VRAM compartida; activar solo donde haga falta.
17. **Repo privado en golden**: clon con **git-bootstrap-token efímero** (GIT_ASKPASS), `origin` sin token embebido, se limpia `hosts.yml`.
18. **Identidad host bajo sudo**: usar `SUDO_USER` (no `$USER`, que sería root).
19. **Disco con particiones**: rechazado por defecto (puede tener datos aunque desmontadas) — override con confirmación extra.
20. **FS no montable** (LUKS/BitLocker/cifrado): el formateo se **aborta por defecto** (no se asume reformateable) — override `TC_ALLOW_UNMOUNTABLE_FS=yes` + confirmación re-tecleada.
21. **git-bootstrap-token con limpieza garantizada**: doble trap (host + dentro del contenedor) borra `~/.gbt`/`~/.gitaskpass` aunque el clone falle a mitad.
22. **Flags de CLI ganan sobre `intake.conf`**: `--repo/--count/--disk` se reaplican tras recargar el intake y recomputan `REPO_DIR` (contrato reentrante).
23. **Codex = auditor**: el panel der de `v` arranca Codex con rol de auditor/analista inmediato (`~/.codex/role-prompt.txt`) + persistente (`~/.codex/AGENTS.md`); nunca escribe código ni sube a GitHub.
24. **Directorios `~/.codex`/`~/.claude` creados como root**: el golden los crea con `mkdir` como root y solo chownea los ficheros que mete dentro → si no se chownea **el directorio**, Codex no puede crear su sqlite (`~/.codex/state_5.sqlite`, `unable to open database file`). `02-golden.sh` ya chownea el dir; en goldens viejos lo arreglan `refresh-codex-auth.sh`/`refresh-claude-auth.sh`, y `verify.sh` lo comprueba (hard check de propiedad).
25. **Preflight host-side (lo que se va a propagar)**: `provision.sh` verifica en la máquina creadora —antes de cada fase que lo necesita— los logins Claude/Codex del host (antes de golden) y los tokens gh/linear/supabase del env por carril (antes de `env`). Avisa por defecto; gate estricto con `TC_REQUIRE_HOST_LOGINS=yes` / `TC_REQUIRE_OP_TOKENS=yes`.
26. **Perfil por canal (Fábrica v2)**: `CODERABBIT_API_KEY` es `percarril` y SOLO la llevan los canales del **Mergeador**; en canales de PRODUCCIÓN se deja vacía (el aviso "perfil PRODUCCION — correcto" de `push-carril-env.sh` es esperado, no un fallo) y el clean-if-absent borra sesiones CR stale. No repartir la key a toda la flota "por si acaso" — la separación de credenciales ES la separación de estaciones (ADR-0043). **Propagar al escrow NO basta**: re-pushear el env a CADA canal del Mergeador (#819: canales sin la key en su `.env.local`); `push-carril-env.sh` reescribe `~/.coderabbit/auth.json` a la identidad del env → re-override tras cada push si la estación rota identidades (ref 05 §Perfiles). **[TAL-2630] El perfil es GROUND-TRUTH DECLARADA** (mapa `$SECRET_DIR/channel-profiles.list`, sembrable con `channel-profiles.sh set <canal> <perfil>`; **TODO canal debe declararse — sin declarar = FALLO fail-closed**, no se asume `produccion`) y `verify.sh` lo **impone fail-closed** por canal (identidad md5 del env/CR siempre evaluada + ausencia de credencial EFECTIVA container-wide donde no debe estar; runner CERO-credencial; todo error de inspección → FALLO). Al desplegar, declarar TODOS los canales (producción incl., 91-94=mergeador, 85-88=runner) ANTES o `verify.sh` los FALLA — ver ref 05 §Imposición del perfil.
27. **tmux en el HOST = prerequisito de la Torre de Control**: las sesiones `torre-*` corren en el HOST (no dentro de un canal — el golden ya trae tmux para los lanzadores `v`, que sí corren en el contenedor). No venía instalado en ningún host → `apt install tmux` en la máquina antes de operar la Torre. Los lanzadores `torre-*` ya están SCRIPT-IFICADOS (TAL-2278: `torre-resume.sh`/`torre-sweep.sh`/`torre-relay.sh`/`torre-compact.sh` en `talent-orchestrator/scripts/`, ver ref 06 §Lanzadores); lo único vigente de este gotcha es que NO están en `install-launchers.sh` — se invocan por ruta del repo (runbook `docs/runbooks/torre-de-control.md`).
28. **El modelo por defecto del launcher debe estar VIVO**: `claude-root` arranca sin `--model` → cae al default de la cuenta; si ese default está **agotado/muerto** (histórico: **Fable agotado** en la cuenta de la flota), el pane se cuelga en silencio. El golden hornea un modelo vacío y la preparación aplica el Sonnet vigente del registro a `~/.claude/settings.json` (ID completo del tier de coding de la regla 0; Gotcha 30), pero **sembrar Y verificar que responde** sigue siendo gate per-canal del coordinador antes de declararlo listo (ref 06 §Agentes al día). CEO usa Opus vigente; los demás roles usan Sonnet vigente; ningún canal arranca en Fable.
29. **[TAL-2296] Recrear el golden NO es por defecto**: `02-golden.sh` **rehúsa** borrar un golden existente — exige `--force` (o `TC_GOLDEN_FORCE=yes` / `provision.sh --force-golden`). Motivo: la plantilla es cara de reconstruir y en multi-fábrica es la base de clonado de esa fábrica. Para una fábrica NUEVA sin tocar la existente: `GOLDEN=golden-<proyecto>` (base CoW propia). Ver ref 03 §Guard.
30. **[TAL-2296] Baseline de Claude en el golden (NO credencial)**: el golden siembra `~/.claude.json` (`hasCompletedOnboarding:true` → sin wizard de onboarding que bloquee el pane) y `~/.claude/settings.json` (`model:""` neutro; la preparación lo sustituye por el identificador completo de Sonnet vigente del registro). Un hard check aborta si aparece un `~/.claude/.credentials.json` o `~/.codex/auth.json` (el golden NO hornea credenciales, TAL-2294 — construye ENCIMA de eso, no lo revierte). **[TAL-3318] Diálogos trust+bypass, también REQUERIDOS en el baseline — siembra MANUAL hoy** (`02-golden.sh` no los escribe ni `verify.sh` los comprueba; automatizarlos = follow-up): sembrar además `hasTrustDialogAccepted:true` en `~/.claude.json` bajo `projects["<ruta-del-repo>"]` (es POR proyecto) y `"skipDangerousModePermissionPrompt":true` en `~/.claude/settings.json` — sin ambos, el primer arranque de cada clon se bloquea en diálogos interactivos que nadie ve. Anti-placebo verificado: `bypassPermissionsModeAccepted` NO es el flag (queda `null` incluso en canales ya usados). Detalle y aceptación manual fail-closed (`jq -e`; fichero/clave ausente = FAIL, nunca silencio) en ref 03 §6b.
31. **[TAL-2296] `--local-only` + gestor de paquetes del repo**: `provision.sh --local-only` (`TC_LOCAL_ONLY=yes`) monta canales SIN Tailscale (acceso local vía `incus exec`/launchers con fallback); no pide `tailscale-authkey`, salta `golden-ts`, y `verify.sh` marca los ítems de tailnet como SKIP. El golden instala dependencias con el **gestor del repo** (corepack: `packageManager` de `package.json` → pnpm/yarn/bun; npm por defecto), no asume npm.
32. **Buzón espejo del flock — dos gotchas** (TAL-3268): (a) el fichero `/tmp/m<N>-flock-out.txt`
    es **append-only por diseño** (nunca truncar durante la sesión); espejo byte-a-byte con dedupe
    por línea; claims atómicos → write directo al canal del flock, no al buzón. (b) en hosts con
    `fs.protected_regular=1` (Ubuntu 24.04 hardened) root no puede appendear a ficheros de otro
    usuario en `/tmp` — escribir siempre como el usuario dueño. Mecánica completa en
    `references/08-runners-del-mergeador.md` §Buzón espejo del flock; gotcha `protected_regular`
    en `references/07-verificacion-y-gotchas.md` ítem 17.
33. **[TAL-3318] Kernel ≥7.0 deniega `signal` en unprivileged → `raw.apparmor='signal,'`**: en hosts nuevos (Ubuntu 26.04 / kernel 7.0) el perfil AppArmor de Incus deniega la mediación de señales entre procesos del contenedor — `kill(2)` devuelve EACCES, el teardown de vitest no puede matar sus workers y el gate `unit` queda rojo PERMANENTE (parece flake del repo; es el host). Fix SCOPED a la fábrica — NUNCA el perfil `default` global (lo heredan TODOS los contenedores del host): perfil dedicado `incus profile create <fabrica>-signal` + `incus profile set <fabrica>-signal raw.apparmor='signal,'` + `incus profile add <canal> <fabrica>-signal` (o per-canal `incus config set <canal> raw.apparmor='signal,'`) + restart de los afectados + **smoke `kill` de aceptación post-montaje** (manual: `verify.sh` aún no lo corre). Ver ref 07 gotcha 18.
34. **[TAL-3318] Node del stack a nivel SISTEMA, no PATH de perfil**: los gates del motor y cualquier `incus exec` corren en shells NO interactivas donde `.bashrc`/nvm no se cargan — Node/npm deben resolver a nivel sistema (root-managed; patrón validado `/opt/node24` + symlinks en `/usr/local/bin`). Aceptación MANUAL (`verify.sh` hoy valida la toolchain vía `bash -lc`, shell de login que SÍ carga el perfil): `incus exec <canal> -- env -i PATH=/usr/local/bin:/usr/bin:/bin sh -c 'node -v && npm -v'` (PATH mínimo del sistema: npm es un script `#!/usr/bin/env node` — con `env -i` pelado no resuelve node). Matiz corepack: `pnpm -v` solo es señal fiable DENTRO del repo (resuelve por `packageManager` del cwd). Ver ref 03 §5.
35. **[TAL-3318] Guardrails anti-reinicio del HOST**: un host recién instalado trae needrestart, unattended-upgrades y updater gráfico activos — cualquiera puede reiniciar Incus/daemons (o pedir reboot) con la flota en caliente. Al montar el host: needrestart en modo LISTA con Incus excluido, unattended-upgrades a 0, updater gráfico off; las actualizaciones del host pasan a ser explícitas en ventana sin vuelo. Ver ref 07 gotcha 19.
36. **[TAL-3318] Artefacto de carga → SIEMPRE flota completa + golden**: cualquier artefacto que se propaga (script, config, manifiesto, motor, binario) se instala en TODOS los canales + el golden en la misma tanda — nunca solo en el canal que lo pidió. Un canal "parcheado a mano" diverge en silencio y el fallo reaparece, irreproducible, en otro canal o en el próximo clon. Ver ref 06 §Mantenimiento.

37. **Un shim con nombre de herramienta del sistema en PATH compartido puede simular censos falsos de infra** (flotas/contenedores que parecen muertos sin estarlo) — verificar con **rutas absolutas** (`/usr/bin/incus`) o `command -v` antes de creer un censo, nunca fiarse ciegamente de un binario resuelto por PATH. La doctrina completa HOST-GUARD (anti-shim + anti-host-equivocado) vive en `talent-coordination`; este es solo el recordatorio en el skill de provisioning.
38. **Relanzar un canal tras `pkill` exige `echo-probe` + operación pane-scoped** (22-23-ago-2026,
    ch43): un `send-keys` contra un pane cuya sesión tmux sobrevivió a un reset de terminal a
    medias puede llegar **corrompido** — las reset-sequences del terminal dejan el pane en un
    estado donde el TUI parece "fallar" aunque el proceso **headless liga igual** por debajo. Antes
    de relanzar: **echo-probe** del pane (`send-keys 'echo PROBE_<random>' Enter` + verificar el eco
    exacto en la captura) para confirmar que el pane recibe y ejecuta correctamente ANTES de
    confiar en el relanzamiento del CLI. Toda operación de relanzamiento es **SIEMPRE pane-scoped**
    (nunca contra la sesión tmux completa) y se avisa por el bus al reciclar.
39. **Pozo EN USO invalida los CLONES de su escrow** (23-ago-2026, ch44/ch47): el **primer canal
    que usa un pozo** (credencial Claude/Codex cosechada) **rota el refresh token** al primer
    request real — y eso **mata las copias l1/l2 del escrow** que se habían cosechado del mismo
    pozo ANTES de usarse (quedan con el token viejo, ya revocado). Síntoma medido: **stub-logout de
    243 bytes a los 28 s** de arrancar con la copia muerta. **md5/tokLen del fichero de credencial
    NO detectan esto** (el fichero es válido en forma, solo el token que contiene ya está
    revocado server-side). Regla: **el escrow SOLO sirve para pozos VÍRGENES** (nunca usados
    todavía); un pozo ya usado se cosecha del **hermano VIVO** (el canal que lo está usando
    activamente), nunca del escrow. **Probe headless real (`claude --print` u equivalente,
    request autenticada de verdad) es OBLIGATORIO antes de declarar vivo un canal** — ni md5 ni
    tamaño de fichero certifican vida server-side (ver también `references/05` "Lectura DIRECTA
    del estado de un pozo").
40. **Recycle-deja-sesión: un canal aparcado SIN trabajo CONSERVA su sesión tmux** (observación
    de flota, 23-ago-2026, ch46/ch41): cuando un canal se aparca sin dispatch siguiente (orden
    vacía), la sesión tmux se deja VIVA con el pane dev **idle** — nunca se mata. Razón: **SIN-PANE
    (sesión muerta) es indistinguible de un contenedor CAÍDO** para el supervisor de flota
    (`talent-coordination` ref 09 §Supervisor de flota); matar la sesión por "estar libre" borra
    esa distinción justo cuando no hay urgencia que la fuerce. El flujo completo de recycle
    (hard/soft/park-sin-trabajo) vive en `talent-channel-operation` ref 11.
41. **[TAL-8038] Renderer clásico + barra `ctx:` en cada canal**: sin `"tui":"default"`, el env `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1` y `alternate-screen off` de tmux, `claude` puede correr en pantalla alternada (el pane no tiene scrollback: PLAN y handoff irrecuperables, `history_size=0`), y sin una `statusLine` ningún pane emite `ctx: NN%` (compact-60 ciego, un coordinador llegó al 92 % sin aviso). El golden lo aplica en `[7b/9]` (`scripts/apply-renderer.sh`, con `talent-context/scripts/install-statusline.sh` y versión mínima de Claude fail-closed) y `verify.sh` lo exige; un canal ya clonado se arregla con `bash scripts/apply-renderer.sh` sin matar sesiones (las abiertas siguen con su renderer hasta relanzarlas).

## Multi-fábrica (fábrica portátil, TAL-2282/TAL-2296)

Un mismo motor `talent-factory` sirve a **varias fábricas**, cada una apuntando a un proyecto/repo
distinto. Convivencia en un host: `GOLDEN=golden-<proyecto>` (base CoW por fábrica) +
`SECRET_DIR=…-<proyecto>` (escrow) + `TS_PORT_BASE` distinto (puertos tailscale) — todo overridable en
`00-config.sh` (ref 01 §Multi-fábrica). **LÍMITE (nombres NO namespaceados por fábrica)**: los nombres
de contenedor/hostname/launcher los construye `tc_channel_name`/`install-launchers.sh` como
`PREFIX+MACHINE_NUM+y` (y `XY`), **sin** incorporar `TF_PROJECT`/manifiesto — así que dos fábricas en el
**mismo host** con el **mismo `MACHINE_NUM`** se **pisan** contenedores, hostnames y wrappers aunque
`GOLDEN`/`SECRET_DIR`/`TS_PORT_BASE` difieran. Regla operativa hasta namespacear los nombres: **cada
fábrica que comparta host usa un `MACHINE_NUM` DISTINTO** (o cada una en su host). Namespacear
`tc_channel_name` por `TF_PROJECT` es follow-up. El golden puede **sembrar el motor** por CoW si `TF_REPO_URL`
está definido (ref 03 §Siembra del motor), en `~/$TF_REPO_DIR` desambiguado del repo de producto;
`scripts/validate-manifest.sh` valida el manifiesto de esa fábrica (claves consumidas presentes, sin
duplicados, `TF_PROJECT`/repo coinciden). **Retarget** de una fábrica = **drain + recycle +
manifiesto** (cerrar lo en vuelo → reciclar actores → apuntar al manifiesto nuevo).

**Provisioning ADITIVO (una máquina sirve a N fábricas).** Un host de canales puede alojar varias
fábricas a la vez (v01: DeFi + TA; v02: Talent-media + Cripto + TA). Al montar una fábrica nueva se
**clona el repo AL LADO** del existente — **JAMÁS borrar ni mover la fábrica previa**. El **perfil
de canal** (env, creds per-canal) es **per-fábrica**: nada de una fábrica pisa el estado de otra.
**EXCEPCIÓN — la credencial global del host (`~/.claude/.credentials.json`) NO es aislable por
fábrica** (es un recurso ÚNICO del host): durante su MUTACIÓN (sobrescritura/restauración) queda
**PROHIBIDA la simultaneidad entre fábricas** — exclusión mutua explícita (una sola fábrica muta a
la vez, las otras NO operan login/propagación mientras tanto), backup con **modo 0600**,
**restauración atómica** (temporal + `mv` en el mismo filesystem, nunca escribir encima en dos
pasos) y **limpieza del `.bak-<fabrica>` al confirmar** (no acumular copias del secreto en disco).
El namespacing real de la credencial por fábrica (p. ej. `CLAUDE_CONFIG_DIR` per-fábrica) es
follow-up; hasta entonces, la simultaneidad de MUTACIÓN está vetada, no solo desaconsejada.

**Jerarquía y modelos** (`doctrina-modelos-multifabrica`, lead 2026-07-09; **modelo-por-fase de
canales** amplía la doctrina, TAL-2675, 2026-07-13; capa META con PM desde 2026-07-30, TAL-3650):
**capa META: PM ⇄ CEO** (el PM define la carga; el CEO, la fábrica) → **orquestadores** (uno por fábrica) →
**coordinadores + Mergeador** (por fábrica) → **canales**. **CEO usa Opus vigente; PM usa Sonnet vigente**;
orquestador/coordinadores/Mergeador corren **`Sonnet vigente` `high`** (`xhigh` solo para planes), sin
cambio — coordinan, no codean. Los **canales** ya NO corren `Opus vigente` `high` de forma plana: **arrancan
en Opus vigente (plan `xhigh`) y el coordinador los conmuta a Sonnet en coding (`high`)**, con fallback a
`Opus vigente` `high` si el code-gate no converge en 5 rondas sobre el mismo fix. El detalle de la capa de
orquestación vive en `talent-orchestrator` ref 11 (`references/11-multi-fabrica-y-ceo.md`); la
coreografía del switch y el contrato de rondas viven en `talent-channel-operation`
(`references/11-modelo-effort-y-recycle.md` §5/§6).

> **Sync-espejo RESUELTO (paquete v1, 2026-07-23)**: el README del motor ya documenta la doctrina
> multi-fábrica y el paquete de skills (canónico=motor, sync-package/validate-package). La
> coherencia README↔skill es **SUPERFICIE SENSIBLE de revisión** — SIN enforcement mecánico:
> los `invariants.tsv` no alcanzan el README del motor (límite declarado del ratchet).
> Nota histórica original: la doctrina (jerarquía CEO, tabla de
> modelos, retarget = drain+recycle+manifiesto, intake desde la matriz) debe reflejarse también en el
> README del repo motor `talent-factory` — este skill la documenta desde la óptica del
> aprovisionamiento; el README del motor, desde la óptica del operador de la matriz. Mantener
> coherentes.

## Sizing — "crear muchos, correr pocos" (dos ejes: por HOST y por CUENTA)

El intake sugiere `COUNT` por RAM (≈ RAM/8). Dos límites **INDEPENDIENTES** gobiernan cuántos
canales corren de verdad — no confundirlos:

- **Pares por HOST (capacidad de la máquina)**: un host de canales **N95 + 32 GB RAM sostiene
  8 pares dev+audit concurrentes SIN régimen de throttling** (verificado en producción en
  vibecoder-05). Esto **supersede el "~4 concurrentes"** previo — el N95 no necesita throttling
  para 8 pares. El régimen **4+4 (pause-rotation) + checkpoint-commit + gates throttled** NO es
  el límite de sizing del N95: es la **mitigación genérica de un host DEGRADADO** (red/I/O
  ahogada), ver `references/06-operacion-y-launchers.md` §"Host degradado — diagnóstico y
  recuperación 4+4".
- **Activos por CUENTA (cuota del proveedor)**: como guía de reparto, **≤4-5 canales activos
  por CUENTA** a la vez (esto es por cuenta, distinto de los pares por host de arriba). Guía
  **SUBORDINADA a la ley de pozos** — el reparto real cuentas↔canales lo manda
  `talent-orchestrator/references/10-cuentas-y-pozos.md`. Si se sobrecarga una cuenta, **canary
  reforzado** antes de escalar (recycle-one-first, `references/05-credenciales-por-carril.md`
  §"SAFETY canary — recycle-one-first"). Más activos = más cuota/cuentas; la credencial se
  **propaga** a los canales activos (no login per-canal; propagación canónica, TAL-2279).

**Fan-out SIEMPRE escalonado (companion de la ley de clones/pozos de arriba)**: en TODO cambio de
credenciales de flota (cosecha, migración de pozo, revival), la propagación a los canales es
**un canal cada 30-60 segundos, NUNCA en burst** — un fan-out de golpe sobre N canales dispara el
rate-limit de la API del proveedor por N clientes refrescando/reconectando a la vez. Detalle del
mecanismo (script y variable de override) en `references/06-operacion-y-launchers.md` §Sizing.

Crea N canales (CoW es barato) y rota cuáles tienen sesión `v` activa según **ambos** ejes: la
capacidad del host Y la cuota de la cuenta.

## Cross-Skill Integration

- **`talent-coordination`**: usa los carriles para coordinar trabajo (despacho, gates). Reutilizar solo su `scripts/hw-probe.sh` como **asset** para sizing — NO su flujo (menciona MCP, incompatible con token-only).
- **`docs/runbooks/onboarding-pc-nuevo.md`**: legacy (parte MCP obsoleta); este skill es la fuente autoritativa de provisioning de canales.

## Verificación

`sudo bash scripts/verify.sh` (read-only) reporta PASS/FAIL: incus+pool+red+servicios · contenedores (golden STOPPED, N RUNNING) · identidad única · toolchain · **propiedad de `~/.codex`/`~/.claude`** · tailnet+puerto · repo+env · estado. `scripts/status.sh` = foto rápida diaria (incluye GPU off por defecto). Las credenciales a propagar (logins host + tokens) se verifican en el **preflight host-side** de `provision.sh`, no per-carril.

## Fuera de alcance

GPU exclusiva/MIG/VFIO (la compartida on-demand SÍ, vía `enable-gpu`) · clonado dual-boot FS (es `talent-coordination`) · ACL/device-approval del tailnet (consola admin) · config MCP/Linear/Supabase (token-only) · backup/snapshots del pool · multi-host · Windows/macOS.

## Paquete de fábrica

Este skill es miembro del **paquete de skills de fábrica** (16): linear-skill · skill-creator · talent-buzz ·
talent-ceo · talent-channel-operation · talent-channels · talent-context · talent-coordination ·
talent-issue-craft · talent-llm-local · talent-memoria · talent-merger · talent-orchestrator · talent-pm · talent-prd · talent-repo-onboarding. El paquete viaja JUNTO y
**motor-primero**: canónico en el repo motor `talent-factory` (`skills/`), propagado como núcleo
a los repos de producto con `skill-creator/scripts/sync-package.sh` (overlays por repo intactos)
y validado con `skill-creator/scripts/validate-package.sh` + `<skill>/invariants.tsv`.
Manifiesto: `skill-creator/assets/package.manifest` · doctrina y ratchet (D6): `skill-creator/references/09-paquete-de-fabrica.md`.

Registro de modelos: `~/.config/talent-channel-operation/modelos.conf` del usuario del rol; CEO y plan/fallback usan Opus vigente, los demás roles y salud Sonnet vigente. Resolver tras acreditar Claude con `talent-channel-operation/scripts/resolver-modelos.sh`.
