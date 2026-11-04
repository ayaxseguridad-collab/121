# 05 — Credenciales por carril (token-only, NO MCP)

## Table of Contents

- [Intake (`scripts/00-intake.sh`) — el skill PREGUNTA](#intake-scripts00-intakesh--el-skill-pregunta)
- [Modelo token-por-carril (AGENTS.md regla 20 — Token-only, NO MCP)](#modelo-token-por-carril-agentsmd-regla-20--token-only-no-mcp)
- [Perfiles de canal: producción vs Mergeador vs runner (Fábrica v2, ADR-0043)](#perfiles-de-canal-producción-vs-mergeador-vs-runner-fábrica-v2-adr-0043)
- [Contrato de secretos](#contrato-de-secretos)
- [Claude / Codex (acreditación por propagación — método canónico; login = último recurso)](#claude--codex-acreditación-por-propagación--método-canónico-login--último-recurso)
  - [Herencia de pozo por `CONFIG_DIR` (sesión sin login propio) — M1/M2](#herencia-de-pozo-por-config_dir-sesión-sin-login-propio--m1m2)
  - [Receta canónica de re-auth (TAL-2279)](#receta-canónica-de-re-auth-tal-2279)
  - [Muros de cuenta — 4, con remedios DISTINTOS](#muros-de-cuenta--4-con-remedios-distintos)
  - [Rotar la cuenta de la flota (rate-limit / cuenta agotada)](#rotar-la-cuenta-de-la-flota-rate-limit--cuenta-agotada)
  - [MOVE transaccional de credenciales (`auth-move.sh`) — un-login-un-lugar (TAL-2294)](#move-transaccional-de-credenciales-auth-movesh--un-login-un-lugar-tal-2294)
- [Doble línea por pozo (sistema de reserva del lead)](#doble-línea-por-pozo-sistema-de-reserva-del-lead)

## Intake (`scripts/00-intake.sh`) — el skill PREGUNTA

1. **Nº de máquina** (x) → naming `vibe-channel-<x><y>`.
2. **Repo** (`REPO_URL`) → descubre claves del `.env.example` del repo (clon superficial temporal).
3. **Nº de canales** (sugerencia por RAM).
4. **Secretos globales** (sin eco, 0600 en `$SECRET_DIR`): `cuser-pass`, `tailscale-authkey` (`tskey-`), `git-bootstrap-token` (`ghp_`/`ghs_`/`github_pat_`).
5. **Credenciales por carril**: itera `assets/creds.manifest` (Linear/Supabase/Convex/GitHub/… + claves descubiertas). `scope=shared` se pregunta una vez; `scope=percarril` por canal → `$SECRET_DIR/env/<canal>.env`.

`assets/creds.manifest` es **declarativo y extensible**: añadir un proveedor = añadir una línea (`ENV_KEY|regex|required|scope|descripción`).

## Modelo token-por-carril (AGENTS.md regla 20 — Token-only, NO MCP)

- El golden **NO** lleva `.env.local` operacional.
- `scripts/push-carril-env.sh <canal>|all`: empuja `$SECRET_DIR/env/<canal>.env` → `~/$REPO_DIR/$ENV_DEST` (0600) y hace **`gh auth login --with-token`** DENTRO del carril con su `GITHUB_TOKEN` + `gh auth setup-git`.
- En el shell del carril, el **tokens loader** (`.bashrc`) auto-exporta las claves del env → CLIs y agentes las toman solas. Operación por **tokens**, nunca MCP.

## Perfiles de canal: producción vs Mergeador vs piloto vs runner (Fábrica v2, ADR-0043)

El "perfil" de un canal ES el contenido de su env por carril (`$SECRET_DIR/env/<canal>.env`)
— mismo golden, mismos clones, distinta credencial. **Cuatro perfiles**: los dos de la tabla, más
**piloto** ([TAL-5142] canal de LABORATORIO: reutiliza EXACTAMENTE la fila `Mergeador` de la tabla
— mismas credenciales, mismas reglas de `verify.sh` — separado por NOMBRE de canal para no afirmar
que es una estación de merge real; no lleva columna propia porque no tiene perfil de credenciales
distinto), más el **runner sellado** de local-gates v2 (usuario `runner` SIN credenciales de ningún
tipo — su contrato de aprovisionamiento completo vive en `08-runners-del-mergeador.md`). Los dos
con credenciales propias:

| | **Producción** (canales de `talent-channel-operation`) | **Mergeador** (canales de `talent-merger`) |
|---|---|---|
| `CODERABBIT_API_KEY` | **NO** (el canal no corre CodeRabbit; entrega PR draft + HANDOFF) | **SÍ** (el Mergeador es el único consumidor del CLI) |
| `GITHUB_TOKEN` | push/PR sobre el repo | además con **permisos de merge** |
| `SUPABASE_ACCESS_TOKEN` | **NO** (mínimo privilegio: el canal no aplica a prod) | **SÍ** (`sbp_` — apply de migraciones + advisors + ledger vía Management API) |
| `LINEAR_API_KEY` | sí (estados/comentarios del encargo) | sí (comentarios de cierre) |

- El mecanismo ya lo implementa `push-carril-env.sh`: **write-if-present / clean-if-absent**
  de `~/.coderabbit/auth.json` — dejar la key vacía en el intake de un canal de producción
  ES configurar su perfil (y limpia cualquier sesión CR stale).
- **Propagar al escrow NO basta — re-pushear a CADA canal del Mergeador** (`push-carril-env.sh
  <canal>` por canal, o `all`): un fallo real (#819) fue tener la key en el escrow pero canales
  de la estación (91/92/94) sin `CODERABBIT_API_KEY` en su `~/$REPO_DIR/$ENV_DEST` → auth CR
  fallida. La key debe llegar al env por canal, no quedarse en el escrow.
- **`push-carril-env.sh` reescribe `~/.coderabbit/auth.json` a la identidad del env** — si la
  estación rota identidades de CR (p. ej. dos keys por rotación), **re-override el `auth.json` a
  la identidad deseada tras cada push** (el push lo deja en la del env). Escritura **atómica y sin
  leak**: `printf` builtin al fichero (formato `{"type":"api_key","apiKey":"…"}`), **NUNCA**
  `coderabbit auth login --api-key` (expone la key en argv/`ps`). Verificar qué identidad quedó
  sin imprimir el valor Y **sin pasar la key por argv** (un `grep -q "$k"` la expone en
  `/proc/*/cmdline`): pasar el patrón por **stdin** — `printf '%s' "$k" | grep -Fqf - ~/.coderabbit/auth.json`  (`-F`: la key es literal, no regex)
  con `k` extraído del env por
  nombre.
- Los sentinels/hooks de la entrega draft (`scripts/draft-handoff.sh`,
  `scripts/verify-handoff.sh`, exención del pre-push) **llegan con el clon del repo** — no
  hay nada que aprovisionar aparte; el bootstrap de githooks del despacho los activa.
- El aprovisionamiento FÍSICO de la máquina/canales del Mergeador es el mismo flujo de este
  skill (intake → golden → clones); solo cambia qué se responde en el intake por canal.

### Imposición del perfil por canal — verify.sh (TAL-2630)

Antes, el perfil era una **convención**: nada impedía que una credencial sensible (`sbp_`, CR key)
aterrizara en un canal de producción, y `verify.sh` declaraba PASS por **presencia de fichero** (señal
débil, no identidad). TAL-2630 lo convierte en un **invariante verificado, fail-closed**:

- **Ground-truth DECLARADA (no inferida — inferir del secreto sería circular):** el perfil de cada
  canal (`produccion` | `mergeador` | `runner`) se declara **por nombre** en el mapa de escrow
  `$SECRET_DIR/channel-profiles.list` (`canal=perfil`, por-fábrica), sembrable con
  `scripts/channel-profiles.sh set <canal> <perfil>`. Overrides ad-hoc por entorno
  `TC_MERGEADOR_CHANNELS` / `TC_RUNNER_CHANNELS`. **Canal SIN declarar = FALLO fail-closed** (NO se asume
  `produccion`: el perfil producción es *lenient* con gh/claude/codex bajo `/home/$CUSER`, así que un
  runner sin declarar se colaría con esos artefactos bajo `/home/runner`) — **TODO canal debe tener
  entrada explícita**; el intake y el rollout siembran TODOS los canales (incl. los de producción). Un
  canal con perfiles DISTINTOS por >1 fuente (mapa vs override), o un valor de perfil corrupto →
  **conflicto/invalid fail-closed** (`verify.sh` lo FALLA).
- **Detección de credencial EFECTIVA, nunca grep de texto del árbol** (el checkout contiene `sbp_`/
  `cr-`/`CODERABBIT_API_KEY` como catálogo/código — `assets/creds.manifest`, `push-carril-env.sh`,
  `.env.example`): se inspecciona **solo** (a) el env OPERACIONAL cargado — asignación no vacía,
  no-comentada, tolerando UNA comilla envolvente (`KEY="sbp_…"`), en el fichero deducido por RUTA
  completa `~/$REPO_DIR/$ENV_DEST` **y** cualquier `.env.local` real bajo un home (`find -path "*/$ENV_DEST"`,
  soporta `ENV_DEST` con ruta tipo `apps/web/.env.local`) — y (b) las **rutas de auth canónicas**
  (`~/.coderabbit/auth.json`, `~/.claude/.credentials.json`, `~/.codex/auth.json`, `~/.config/gh/hosts.yml`).
- **Checks por perfil (todos fail-closed — cualquier error de inspección `incus`/`jq`/`find`/`grep`
  rc≥2 o fichero ilegible → FALLO, NUNCA "ausente"/"limpio"):**
  - **produccion**: identidad del env (md5 `container == escrow`, **siempre evaluada** — both-ways:
    escrow↔env del canal presentes y coinciden, o ambos ausentes) · SIN `sbp_`/CR **efectiva** ni sesión
    CR canónica en **TODO el contenedor** (cualquier home real, no solo `/home/$CUSER`).
  - **mergeador**: identidad del env · **identidad CR** (md5 del `.apiKey` de `~/.coderabbit/auth.json`
    == md5 de la `CODERABBIT_API_KEY` del escrow, des-citada; el apiKey se hashea DENTRO del contenedor,
    solo cruza el digest) · `sbp_` efectiva presente.
  - **runner**: **CERO** credencial en **TODO el contenedor** (cualquier home real incl. `/home/runner`
    y `/root`) — ni artefacto de auth canónico ni `.env.local` con asignación alguna — reutiliza el
    **scanner sellado del motor** si `TC_CRED_SCANNER` apunta a su entrypoint, o el fallback container-wide.
- **Cobertura por-fábrica, TODOS los contenedores:** el pase enumera los contenedores REALES de la
  fábrica (`incus list` filtrado por `MACHINE_NUM`, no todo el `PREFIX` del host — otra fábrica la valida
  su propio `verify.sh`) e incluye los de **fuera de `1..COUNT`** (p. ej. 91-94). El filtro de scope es
  fail-closed (un error de `grep` no se convierte en "enumeración vacía exitosa"). Reconciliación
  fail-closed: cada canal declarado/con-escrow debe existir como contenedor; `incus list` que falla o
  `MACHINE_NUM` vacío → FALLO.
- **Rollout idempotente (obligatorio al desplegar):** declarar el perfil de **TODOS** los canales de la
  fábrica ANTES/junto al deploy (o `verify.sh` los FALLA por no-declarados; y los legítimos Mergeador/
  runner necesitan su perfil o romperían): `channel-profiles.sh set vibe-channel-<N> produccion` para los
  de producción, `… set vibe-channel-91 mergeador … 94` (Mergeador), `… set vibe-channel-85 runner … 88`
  (runner). En máquinas nuevas lo hace el intake. Gate post-apply: `bash scripts/verify.sh` **VERDE** por
  fábrica antes de cerrar el deploy.

## Contrato de secretos

`umask 077`, `set +x` alrededor de secretos, **nunca imprimir valores**, 0600 + chown tras cada `incus file push`, `trap` de limpieza, `$SECRET_DIR` 0700 fuera del repo. **git-bootstrap-token** efímero (solo clon; `origin` sin token; `hosts.yml` limpiado).

**Transporte de secretos host→contenedor: SOLO por STDIN encadenado.** Un secreto que viaja al
contenedor va por **stdin** a un temporal creado con permisos restrictivos DE ENTRADA, y se
promueve al destino **solo tras validar integridad** — jamás en `argv` (visible en
`/proc/*/cmdline`), stdout, historial de shell ni ficheros del host remoto. Mismo contrato
validar-antes-de-promover que la cosecha de pozos de §«Doble línea» (temp→validar→`mv` atómico,
destino intacto ante cualquier fallo):

```bash
h="$(sha256sum fichero | cut -d' ' -f1)"           # hash del ORIGEN, host-side
set -o pipefail                                     # un cat local que falla NO puede pasar por éxito del cat remoto
cat fichero | ssh … "incus exec … -- sh -c '
  d=<destino>                                       # destino final de la credencial
  umask 077                                         # 0600 desde su creación (sin ventana world-readable)
  t=\$(mktemp -p \"\$(dirname \"\$d\")\") || exit 1  # temporal en el MISMO dir/fs que el destino → mv = rename REAL atómico
  trap \"shred -u \\\"\$t\\\" 2>/dev/null\" EXIT    # limpia el temporal ante CUALQUIER salida (aun fallo de chown/mv)
  cat > \"\$t\" || exit 1
  test -s \"\$t\" || exit 1                          # RECHAZA vacío/truncado ANTES de tocar el destino
  [ \"\$(sha256sum \"\$t\" | cut -d\" \" -f1)\" = \"$h\" ] || exit 1   # integridad vs ORIGEN, PRE-promoción
  chown vivecoder:vivecoder \"\$t\" || exit 1
  mv -f \"\$t\" \"\$d\" && trap - EXIT               # promoción ATÓMICA solo tras validar; destino INTACTO ante fallo
'"
```

- **`umask 077` + `mktemp`** (0600 desde su creación, nombre imprevisible) elimina la **exposición
  transitoria** del viejo `cat > /tmp/x && chmod 0600`, que dejaba el fichero world-readable entre el
  `cat` y el `chmod` sobre una ruta predecible expuesta a symlink-race.
- **Validar ANTES de promover** (`pipefail` + `test -s` + hash-vs-origen antes del `mv`): un stream
  parcial o vacío **NO** puede sobrescribir una credencial válida — el `cat` remoto puede salir 0 con
  contenido truncado, y comprobar el hash DESPUÉS del `mv` detectaría el daño ya consumado, sin
  rollback. El `mv -f` deja el destino **INTACTO ante cualquier fallo** — y es **atómico de verdad
  solo si el temporal vive en el MISMO filesystem que el destino**: por eso `mktemp -p "$(dirname
  "$d")"` y no el `/tmp` por defecto (un `mv` cross-fs degrada a copia+borrado, que puede truncar o
  exponer contenido parcial — justo el fallo que este contrato evita).
- El **`trap … EXIT`** shredea el temporal ante CUALQUIER salida (incluido fallo de `chown`/`mv`) y se
  desarma solo tras el `mv` exitoso — sin residuo de secreto persistente (`shred`, no `rm`).
- El patrón **temp+`mv`** esquiva además el gotcha de `incus file push` sobre destinos 0600
  pre-creados (que muere en silencio, ver `09` §2 de channel-operation). **Verificación post**:
  `sha256sum` en destino == origen.

## Claude / Codex (acreditación por propagación — método canónico; login = último recurso)

**[TAL-2294, TAL-2279] La propagación es el método CANÓNICO de acreditación Y de re-auth** para
ambos agentes — activación inicial y rotación de cuenta. El login interactivo (`claude login` /
`codex login`) per-carril queda como **excepción de último recurso**: solo cuando NO existe ningún
donante con token vivo (p. ej. refresh-token revocado — ver «Refresh-token muerto» abajo). El
**donante** de la propagación es el **host** por la vía automatizada (`refresh-claude-auth.sh`,
host-only) **o** un **hermano/pozo ACTIVO** por la receta manual — son dos rutas distintas, no un
origen intercambiable del mismo script (ver «Receta canónica de re-auth» abajo).

**Orden recomendado al crear la flota: acredita el HOST primero.** Haz `claude login` y `codex login`
en el host **antes** de aprovisionar — esto siembra el donante de la propagación automatizada, no es
login per-carril. **El golden NO hornea NINGUNA credencial**: los canales nacen SIN login y se
acreditan per-carril tras clonar — Claude por propagación (`refresh-claude-auth.sh`), Codex por
**MOVE transaccional** (`auth-move.sh move`; NUNCA fan-out).

- **Verificación host-side (la máquina creadora es la que propaga):** `provision.sh` comprueba en el host, **antes** de aprovisionar, que exista el login que se va a propagar; si falta, AVISA (gate estricto opcional `TC_REQUIRE_HOST_LOGINS=yes`). Ninguna credencial se hornea en el golden: la acreditación por carril llega por **propagación** desde ese login del host. Igual para los tokens gh/linear/supabase antes de la fase `env` (`TC_REQUIRE_OP_TOKENS=yes`).
- **gh**: no se hereda del host; queda listo cuando `push-carril-env.sh` ejecuta `gh auth login --with-token` dentro de cada carril (fase `env`).
- **Codex**: **NO se hornea ni se copia en fan-out.** Su refresh token es de un solo uso: clonar el mismo `auth.json` a varios destinos (o dejarlo vivo en host Y canal) invalida el refresh de las copias → `refresh token revoked` en cascada. Un login de Codex se **MUEVE** con `auth-move.sh move <cuenta> <from> <to>` (ver «MOVE transaccional» abajo); `refresh-codex-auth.sh` queda SOLO para el arranque puntual de UN canal desde el host y RECHAZA `all`. **Importante:** `~/.codex`/`~/.claude` se crean en el golden y deben ser del usuario `vivecoder` (no `root`), o Codex no puede abrir su sqlite — ver gotcha en `07-verificacion-y-gotchas.md`.
- **Claude**: la **vía primaria es propagar el login del HOST sin device-flow** — si el host ya
  está acreditado (`claude login` una vez en la máquina creadora), `refresh-claude-auth.sh all`
  copia sus credenciales a los canales y verifica el fingerprint (md5), **sin checkpoint humano por
  canal** (verificado en producción: propagación desde el host logueado a 91/92/93/94 sin
  device-flow). El **device-flow per-carril** (navegador, entrando con `v<XY>`) queda como
  **fallback** de primera vez cuando el host NO está acreditado o la propagación no aplica. Nota:
  clonar la suscripción en el golden NO es fiable (revocación al rotar) — de ahí que Claude se
  **propague post-clon** en vez de hornearse.

### Receta canónica de re-auth (TAL-2279)

Consolida en un solo lugar cómo re-acreditar un canal muerto/expirado. **Claude y Codex NO
comparten receta** — no mezclarlas.

**Claude** (caduca por **idle**, no fleet-wide) — tres vías, **no intercambiables**:

1. **Automatizada host→canales**: `refresh-claude-auth.sh all` cosecha
   **exclusivamente** de `$HOST_HOME/.claude/.credentials.json` (**HOST-ONLY**) y verifica el
   fingerprint (md5) en ambos lados. El gate estricto `TC_REQUIRE_HOST_LOGINS=yes` exige la cred
   **en el HOST** primero — un hermano vivo **no** satisface ese gate; el script no lee de un
   hermano.
2. **Manual hermano→canal** (reauth por idle sin tocar el host): copiar a mano
   `~/.claude/.credentials.json` + merge del bloque `oauthAccount` de `~/.claude.json` desde un
   canal HERMANO ACTIVO (token vivo) directo al canal muerto — `incus file push
   --uid/--gid/--mode` + `jq --slurpfile` (mecánica completa en «Swap por debajo» más abajo). Si
   la sesión sigue trabajando (token en RAM), **sin relaunch** + nudge; si ya quedó
   logged-out/atascada, propagar **+ RESTART** (ver Muro 1 abajo). Es **manual**, fuera de
   `refresh-claude-auth.sh`.
3. **Fallback rápido — pane expirado** ("Login expired" / "Not logged in", pane ya no trabaja
   y el HOST está acreditado): usar el helper:

   ```bash
   bash scripts/refresh-claude-auth.sh <canal-completo> --restart
   ```

   Cosecha **exclusivamente** del HOST (`$HOST_HOME/.claude/.credentials.json`), hace kill
   ACOTADO vía `tc_kill_wait` (casa el **ejecutable** `claude` —basename de argv[0] o `comm`—, nunca
   la línea de comandos; espera fail-closed a que no quede ningún PID) y relanza el alias. Tiempo estimado <30 s. El
   argumento de un canal individual se usa **verbatim** como nombre de contenedor
   (`refresh-claude-auth.sh:38-39`): pasar el nombre **completo** del contenedor
   (`vibe-channel-91`), **nunca un número pelado** (`91`), que apuntaría a un contenedor
   literalmente llamado "91". La convención del prefijo (`vibe-channel-`) vive en `00-config.sh`
   / `tc_channel_name`; solo `all` expande automáticamente.

   Si el HOST no tiene cred viva y hay que hacer el push manualmente (donante = hermano/canal —
   vía 2 manual), usar ownership **por NOMBRE** (`incus exec <canal> -- chown "$CUSER:$CUSER"
   <ruta>`, igual que `tc_push_secret_file`; ver lib.sh:75-80) **o** UID/GID computado
   dinámicamente (`uid="$(incus exec <canal> -- id -u "$CUSER")"`, patrón
   auth-move-lib.sh:442-444) — **nunca `--uid 1001 --gid 1001` literal** (un uid equivocado
   deja el fichero ilegible; síntoma: `norefresh` — §271-278). Para el restart: kill por **PID
   concreto** tras `pgrep` inspeccionado (doctrina G32 en `talent-channel-operation` ref 09),
   **nunca `pkill -f 'claude'`** (§357).

   > **La propagación sigue siendo el canónico** (invariante 8): esta 3ª vía es un fallback
   > rápido post-expiración, no un sustituto de la propagación regular.

**Codex** (`~/.codex/auth.json`, refresh-token **de un solo uso**): el canónico es el **MOVE**
(`auth-move.sh move`, un-login-un-lugar — ver «MOVE transaccional» más abajo), el único método
estructuralmente seguro para un refresh single-use. `refresh-codex-auth.sh all` **PROHIBIDO**. El
**COPY** de un hermano recién logueado (sin vaciar al donante) es **solo reauth táctico de
emergencia** (parche caveateado): `auth.json` **persiste el refresh token**, y dos copias del
mismo token de un solo uso hacen que el primer refresh de cualquiera invalide la otra → **re-arma
la cascada de deslogueos** en la siguiente rotación → obliga a **re-propagar tras la próxima
rotación** (práctica ya documentada como «Puente de credenciales host→canales» T4 más abajo). NO
es equivalente al MOVE ni debe presentarse como canónico.

**Propiedad de directorio**: `chown` del **DIRECTORIO** `~/.codex`/`~/.claude` (no solo los
ficheros) — si queda de `root`, el agente no puede escribir su estado/sqlite (gotcha 24 de
`SKILL.md`, detalle en `07-verificacion-y-gotchas.md`).

**Verificación funcional post-propagación (obligatoria, ambos agentes)**: el fichero en disco NO
basta — confirmar que el access-token está **vigente** (lectura directa, ver más abajo) Y que el
canal **RESPONDE** a una request real (taxonomía T3 en `07-verificacion-y-gotchas.md`).

#### Herencia de pozo por `CONFIG_DIR` (sesión sin login propio) — M1/M2

Una sesión que arranca **sin `CONFIG_DIR`/`CLAUDE_CONFIG_DIR` propio** (ni el equivalente de
Codex) toma `~/.claude`/`~/.codex` **del host** → hereda su login, su cuenta y por tanto su
**pozo**. Caso M1/M2: torres levantadas en el host **sin login separado** infieren contra la
cuenta del `/login` del host, no contra una cuenta propia — consumen su cuota sin que el reparto
lo contabilice. Implicación para el reparto de pozos: **contar a cada host como un bloque** — toda
sesión sin `CONFIG_DIR` propio en ese host pesa sobre la MISMA cuenta. Si se quiere una cuenta
distinta por sesión/torre, darle un `CONFIG_DIR` propio con su login. El reparto canónico
cuentas↔canales lo manda `talent-orchestrator/references/10-cuentas-y-pozos.md`.

### Muros de cuenta — 4, con remedios DISTINTOS

Encuadre: esto es **gestión eficiente de recursos** — continuidad de producción sin desperdicio,
nunca "estirar" nada. Diagnosticar el muro EXACTO antes de actuar; aplicar el remedio equivocado
desperdicia una credencial buena o quema tiempo de flota:

| # | Marcador | Qué es | Remedio | NO hacer |
|---|---|---|---|---|
| 1 | `Not logged in` / `refresh token revoked` | La credencial murió en disco | **Remedio DUAL según el estado de la SESIÓN** (distinguir por ACTIVIDAD/request real, no por status-bar): sesión **VIVA trabajando** (token en RAM) → propagar cred + nudge, **NO relaunch** (matar pierde contexto y exige re-brief); sesión **YA logged-out/atascada** → propagar **+ RESTART obligatorio** (una sesión caída no re-lee el disco — ver «Sesión atascada» abajo) | Relanzar una sesión viva que aún trabaja (pierde contexto sin necesidad); asumir que una sesión YA caída releerá la cred fresca sola |
| 2 | `usage limit · resets <hora>` (horas) | Cap de 5 h | **Esperar** al reset + nudge `continuemos` | Re-loguear ni rotar cuenta (se resuelve solo) |
| 3 | `weekly limit · resets <día>` (días) | Cap semanal (7 d) | **PARK** del canal o escalar a otra cuenta vía pozos. El trabajo local (commits, rama) queda A SALVO | `continuemos` (no revive nada) ni re-autenticar la misma cuenta |
| 4 | `429` / `temporarily limiting` | Sobrecarga transitoria de la cuenta (N sesiones simultáneas) | **RESTART** de la sesión (fuerza releer el disco) + re-despachar **escalonado** (2-en-2; doctrina del coordinador en `talent-channel-operation` ref 11 §7) | Despachar N canales de golpe otra vez sobre la misma cuenta |

- El detalle operativo por muro (asimetría Claude/Codex, re-brief post-restart) vive en
  `talent-channel-operation` ref 11 §7b; esta tabla es la doctrina canónica.
- Aviso del muro 3: N canales sobre 1 cuenta agotan el semanal aunque cada uno respete su 5 h.

#### Sesión atascada logged-out → RESTART (propagar NO basta) — T1

La status-bar del TUI refleja el **DISCO**; el proceso vivo usa el token **EN MEMORIA**:

- Una sesión corriendo puede mostrar `Not logged in` (cred on-disk blanca/vencida) y seguir
  trabajando perfectamente con su token en RAM — **no interrumpirla por la status-bar**.
- La inversa es la trampa: una sesión que YA quedó logged-out **NO re-lee** la credencial fresca
  que acabas de propagar — se queda atascada aunque el disco esté bien. El remedio es
  **kill + relaunch** (p. ej. `refresh-claude-auth.sh <canal> --restart`), no re-propagar.
- **Distinguir por ACTIVIDAD, no por status-bar**: ¿avanza el trabajo (commits nuevos, output
  reciente)? → viva, no tocar. ¿Parada + prompt de login? → restart. Evidencia: canal c1-f2
  atascado en logged-out mientras el orquestador y el Mergeador operaban con la MISMA credencial.

#### Puente de credenciales host→canales (emergencia) — T4

Cuando un pozo muere a MITAD de un lanzamiento y no hay cred de flota viva, se puede **prestar la
credencial VIVA del host** a los N canales para no perder la producción en vuelo. Es un préstamo
**reversible**, no un estado normal:

- **MODO CONSERVADOR obligatorio**: el runway (5 h y 7 d) pasa a ser **COMPARTIDO** entre el host y
  los N canales — dimensionar el trabajo en vuelo a ese presupuesto único.
- **Verificación canal-por-canal por request real** (no por fichero): cada canal debe responder con
  la cred prestada antes de contar con él.
- **Se limpia al reset**: en cuanto hay cuenta de flota viva, se re-propaga la titular y el host
  recupera la suya.
- **Coste conocido**: para agentes de refresh single-use (Codex), el préstamo encadena rotación —
  presupuestar el MOVE de vuelta.

### Rotar la cuenta de la flota (rate-limit / cuenta agotada)

Verificado en producción: cambio de la flota completa a una cuenta Max nueva, 0 stalls. Cuando una
cuenta de Claude o Codex da **rate-limit** o se agota (muros 3-4 de la tabla de arriba; el muro 2
solo se espera), el lead hace `claude login` / `codex login` en
el **host** con la cuenta nueva (queda en `~/.claude/.credentials.json` / `~/.codex/auth.json`) y se
propaga a los carriles que lo necesiten:

```bash
sudo bash scripts/refresh-claude-auth.sh all            # Claude: propaga + verifica fingerprint (md5)
sudo bash scripts/refresh-claude-auth.sh all --restart   # fase por panel; + recicla claude
# Codex: NO fan-out. Un login por destino, MOVIDO (no copiado):
sudo bash scripts/auth-move.sh move <cuenta> host:<host> channel:<canal>
```

> **Claude vs Codex — asimetría deliberada.** Claude admite propagación por **copia** (ruta primaria
> del lead): la misma credencial en N canales es aceptable operativamente. Codex NO: su refresh es de
> un solo uso, así que se **mueve** (un-login-un-lugar). Por eso `refresh-claude-auth.sh all` existe y
> `refresh-codex-auth.sh all` está PROHIBIDO.

- **No destructivo por defecto**: sin `--restart` solo copia las credenciales y **verifica el
  fingerprint (md5) en ambos lados** — una propagación truncada dejaría el carril con credenciales
  corruptas y colgado; el md5 lo caza.
- **`--restart`** recicla el agente para que la cuenta nueva tome efecto: mata el proceso **por PID
  host-side** (`bash -c`, **no** `su - -c`: `su -c` propaga el `exit 137` del kill y aborta el bucle
  — validado en producción) y relanza el alias (`claude-root`/`codex-root`; pane y alias configurables
  con `TC_CLAUDE_PANE`/`TC_CLAUDE_RELAUNCH` y `TC_CODEX_PANE`/`TC_CODEX_RELAUNCH`).
- **El repo se preserva**: kill+relaunch resetea el contexto de conversación del agente, **no** el
  working tree ni los commits (validado con carriles que tenían WIP sin commitear). Por eso los
  carriles con **trabajo en vuelo** necesitan un **re-briefeo de reanudación** (rama, commit/PR, qué
  falta) tras el restart — eso lo orquesta el **coordinador**, no este skill: ver el PROC de rotación
  de cuenta en `talent-channel-operation` → `references/11-modelo-effort-y-recycle.md`.
- **`refresh-*-auth.sh all` NO cubre los canales del Mergeador**: `all` itera `seq 1 COUNT` — los
  **canales de la estación del Mergeador (numerados fuera de `1..COUNT`**; hoy 91/92/93/94, ver
  §Perfiles) **ni se tocan NI se listan como saltados** (el mensaje "no existe (saltado)" solo
  sale para canales dentro de `1..COUNT`).
  Al rotar la flota, nombrarlos **explícitamente** con el nombre **completo** del contenedor
  (`refresh-claude-auth.sh vibe-channel-91`, `… vibe-channel-92`, …) o quedan en silencio
  con la cuenta vieja. El argumento se usa **verbatim** como nombre de contenedor (ver 3ª vía
  §165 — `refresh-claude-auth.sh:38-39`); un número pelado (`91`) apuntaría a un contenedor
  llamado literalmente "91" y el script lo saltaría con falso éxito si no existe.
- **SAFETY canary — recycle-one-first**: antes de un kill/restart MASIVO de la flota con cuenta
  nueva, reciclar UN solo canal y verificar que arranca y responde con esa credencial (request
  real). Si el canary falla, la flota entera sigue viva con la cuenta anterior; si pasa, proceder
  con el resto. Nunca kill masivo asumiendo cred viva.
- **Cred-copy de canal caducada aunque la cuenta VIVA (perdió la carrera de rotación)**: la copia
  de credencial de un canal puede quedar obsoleta (marcador **"Login expired"**) porque **perdió
  la carrera de rotación del refresh** — el pozo/host refrescó y la copia del canal quedó con el
  snapshot viejo, MIENTRAS otras torres de la **misma cuenta** siguen infiriendo sin problema (la
  cuenta está viva; solo esta copia caducó). **Revival: cosechar del ORIGEN** (el contenedor-pozo)
  con **canary**, **NUNCA de los `CONFIG_DIR` de torres ACTIVAS** — 4 clones nuevos colgando de la
  línea de una torre viva la ponen en riesgo de tumbarla (ley de clones ≤4-5 activos/cuenta, ver
  SKILL.md §Sizing).
- **Swap "por debajo" (canal VIVO, sin restart)**: si el agente está vivo (token en RAM), basta el
  push de la cred a disco — la relee al refrescar. Mecánica verificada (F1 2026-07-14): push de
  `.credentials.json` con ownership **por NOMBRE** (preferido, UID-agnóstico — patrón de
  `tc_push_secret_file`):

  ```bash
  incus file push --mode 600 .credentials.json <canal>/home/vivecoder/.claude/.credentials.json
  incus exec <canal> -- chown "vivecoder:vivecoder" /home/vivecoder/.claude/.credentials.json
  ```

  O bien, si se necesita `--uid/--gid`, calcularlos **dinámicamente** (nunca el literal `1001`):

  ```bash
  uid="$(incus exec <canal> -- id -u vivecoder)"
  gid="$(incus exec <canal> -- id -g vivecoder)"
  incus file push --uid "$uid" --gid "$gid" --mode 600 \
    .credentials.json <canal>/home/vivecoder/.claude/.credentials.json
  ```

  Un uid/gid equivocado deja el fichero ilegible y el síntoma es `norefresh`, no un error de push
  (§271-278). Más: merge del `oauthAccount` en `~/.claude.json` vía fichero intermedio y
  `jq --slurpfile` (pasar el JSON por stdin a través de `su -` NO funciona; inline rompe por
  quoting). Verificar post-swap: email correcto en `.claude.json` + refreshToken legible por
  `vivecoder`. Cosechar de donante vivo: verificación funcional (request real) ANTES de pull.

#### Lectura DIRECTA del estado de un pozo/cuenta (NUNCA por `/usage` vía TUI)

El poll de `/usage` en un tmux del pozo es **frágil**: falla tras un login fresco que deja el TUI
a medias, da lecturas parciales o no rinde — un pozo VIVO aparece como "sin lectura / caído"
(incidente torre de mando 2026-07-12: p4 vivo salía "sin lectura"). El estado real se lee de DOS
ficheros, sin TUI y sin gastar `/usage`.

**NUNCA volcar el fichero de credenciales por stdout** (contrato de secretos de este skill: los
valores no se imprimen). `incus file pull … -` escribe el fichero COMPLETO a stdout — el
`accessToken` (y material de refresh) quedaría en transcript/scrollback/logs. El JSON se procesa
**DENTRO del contenedor** con `incus exec` y solo salen **campos DERIVADOS permitidos**
(`at_len`, expiración, tipo, identidad) — jamás el token ni el documento entero:

```bash
# Solo campos derivados salen del contenedor; el token NUNCA cruza a stdout del host.
incus exec <pozo> -- su - vivecoder -c '
  jq -r "{at_len:((.claudeAiOauth.accessToken//\"\")|length),
          expiresAt:(.claudeAiOauth.expiresAt//null),
          sub:(.claudeAiOauth.subscriptionType//null)}
         | \"at_len=\(.at_len) expiresAt=\(.expiresAt) sub=\(.sub)\"" \
     ~/.claude/.credentials.json 2>/dev/null || echo "—"'   # lectura ilegible → "—" honesto
incus exec <pozo> -- su - vivecoder -c '
  jq -r ".oauthAccount.emailAddress // \"—\"" ~/.claude.json 2>/dev/null || echo "—"'
```

- **`.credentials.json` → `claudeAiOauth`**: `at_len` (>0 = hay token en disco; el valor del
  token NUNCA se emite, solo su longitud), `expiresAt` (>ahora = **no expirado localmente**),
  `subscriptionType`.
- **`.claude.json` → `oauthAccount.emailAddress` = la identidad registrada en el ÚLTIMO login
  local.** NUNCA fiarse de etiquetas hardcodeadas de pozos — se quedan obsoletas tras un
  re-login (incidente: pozo etiquetado "gmail" que resultó ser otra organización).
- **Veredicto (estado LOCAL — lo que el disco puede probar)**:
  `at_len>0 && expiresAt>ahora` → **estado local presente y no expirado** ·
  `at_len=0` → **BLANCA** (login fresco: Modo A del árbol de abajo) ·
  `at_len>0 && expiresAt<ahora` → **expirada localmente / refresh pendiente**.
  **Límite honesto**: esta lectura NO demuestra que el servidor no haya revocado el token —
  declarar una cred **"VIVA server-side" exige una request AUTENTICADA real** (taxonomía T3).
  La lectura local decide el ÁRBOL (Modo A/B, propagar-o-login), no sustituye la verificación
  funcional pre-cosecha (`talent-orchestrator` ref 10 §3).
- **NOTA OPERATIVA — 401 masivo del censo ≠ pozos muertos (22-ago-2026)**: los **access tokens
  del escrow caducan por NO-USO** (no por revocación) — un censo que barre todos los pozos de golpe
  puede recibir 401 en cascada simplemente porque esos access tokens llevaban tiempo sin usarse
  (no porque los pozos estén muertos). Consecuencia práctica: **verificar funcional** (request
  autenticada real, punto anterior) **antes de creer un censo con 401 masivo** — un 401 en cascada
  es señal de "tokens fríos, necesitan refresh", no de "pozos muertos". El script del refresh
  automático vive en el motor (`talent-factory`); aquí se documenta el SÍNTOMA y la REGLA, no la
  implementación.
- El `/usage` queda SOLO para los **%-de-uso** (5h/7d) como complemento best-effort: si el TUI
  no rinde, el estado LOCAL de la cred sigue siendo legible por los ficheros.
- Es la aplicación de T3 (verificar por DATO real, no por señal indirecta —
  `07-verificacion-y-gotchas.md` §Verificar por conducta): el email es la identidad del último
  login registrada en disco; la presencia/PONG no prueba nada.

**REGLA DURA — NUNCA publicar un dato inventado, asumido o derivado de una heurística de
relleno.** Si una lectura no rinde de forma fiable, se publica **"—" honesto**: un hueco
honesto es SIEMPRE mejor que un número falso. (Ev.: torre 2026-07-12 — p4 reportado "0%
fresco" cuando estaba al **88% semanal / 100% Fable**; la mentira habría hecho apoyar
producción en una cuenta agotada.)

Reglas del %-de-uso (lo único que aporta `/usage`):

- **%-de-LÍMITE ≠ tokens de la sesión del TUI**: el panel "Session · Total cost · 0 input/0
  output" son los tokens de ESA sesión; el semanal vive en **"Current week (all models) N%
  used"** / **"Todos los modelos N% usado"**. NUNCA derivar el límite de los tokens.
- **Parser robusto del `/usage`** (el TUI es frágil): limpiar el input ANTES
  (`Escape`×2 + `C-u`); parsear **bilingüe** (en: "Current session/week … % used ·
  Resets … (UTC)" / es: "Sesión actual/Todos los modelos … % usado · Se restablece …"); si
  aun así no rinde → **"—"**, jamás un número.
- **Un login fresco NO pone el semanal a 0%**: el consumo semanal es de la CUENTA; el login
  solo revive el access token. Un pozo puede estar **VIVO (token vigente) y al 88%** a la vez
  — las dos lecturas son independientes.

Reparar un TUI de pozo corrupto — **acotado a la sesión objetivo** (nunca al server entero):

```bash
tmux list-sessions                       # 1) INVENTARIO primero: ¿qué más vive en este server?
tmux kill-session -t pozo                # 2) destruir SOLO la sesión objetivo
tmux new-session -d -s pozo -x200 -y50   # 3) recrearla con un shell
tmux send-keys -t pozo 'claude --dangerously-skip-permissions' Enter   # 4) el CLI DENTRO del shell
# (si claude fuera el comando de la sesión, al salir se cierra la sesión) → confirmar trust (1+Enter)
```

- **`tmux kill-server` es destructivo GLOBAL** (mata el servidor, los clientes y TODAS las
  sesiones — trabajo ajeno incluido): solo es aceptable con la **precondición verificada** de
  que `tmux list-sessions` no muestra NINGUNA otra sesión en ese server.
- **`pkill -f 'claude'` PROHIBIDO por su alcance amplio/no acotado**: `-f` matchea el argv
  COMPLETO de cualquier proceso (otros agentes, editores, un shell invocador cuyo comando
  contenga el patrón) — pgrep/pkill nunca se reportan a sí mismos, pero el radio de matcheo
  es incontrolable. Matar por **PID concreto** tras `pgrep` inspeccionado (doctrina G32 en
  `talent-channel-operation` ref 09).
- **`tmux respawn-window -k`**: mata el comando de la ventana OBJETIVO y la relanza (no tumba
  el server) — prohibido operativamente para pozos tras un incidente (condición exacta no
  caracterizada): pierde el proceso en vuelo de esa ventana sin pasar por el inventario;
  usar la receta acotada de arriba.

#### Árbol ante blanqueo: Modo A vs Modo B

Si la credencial de la flota aparece **blanca** (extracción de `accessToken` vacía; sentinel
`68b329da` — ver nota del sentinel abajo), NO
concluir a ciegas — hacer la **lectura directa** de arriba sobre la cred del **POZO** y decidir
por `at_len`/`expiresAt`:

- **`at_len=0` (el pozo también está blanco) → Modo A**: no hay fuente viva por file-copy; la
  ÚNICA vía es **login interactivo del lead** en un punto (host o un canal) y re-cosechar desde
  ahí. Cero atajos.
- **`at_len>0` (el pozo tiene token) → Modo B**: re-cosecha fresca del pozo y propagación normal —
  **cero intervención del lead**.
- **Síntoma-firma del Modo B**: *"pN muere cada ~2 h"* = el **snapshot propagado ya fue ROTADO
  por el pozo** (el pozo refrescó y el snapshot quedó obsoleto) — es re-cosecha fresca (Modo B),
  **no** muerte de la cuenta. No escalar a login del lead por esa firma.

#### Refresh-token muerto = cred blanca fleet-wide (irreparable por file-copy)

Cuando el **refresh token** de la cuenta queda revocado, cada intento de refresh **escribe una
credencial VACÍA en disco** — incluida la FUENTE. A partir de ahí, propagar solo
**esparce blancos** por toda la flota: ninguna combinación de copias la rescata. El único fix es
**`claude login` interactivo fresco** en UN punto y re-cosechar/propagar desde ahí. Detectarlo
antes de propagar: verificar `at_len>0` en la fuente (el fingerprint md5 de los refresh-scripts
prueba que la copia es fiel, no que el contenido sea una credencial viva — ver taxonomía de señales
en `07-verificacion-y-gotchas.md` §Verificación).

**Nota del sentinel `68b329da` (exactitud del procedimiento)**: ese valor NO es el md5 de un
fichero vacío (eso sería `d41d8cd9…`) — es el md5 de **una línea vacía**, producto del
procedimiento de extracción que hashea el campo extraído vía `echo` (que añade `\n`):
`at="$(jq -r '.claudeAiOauth.accessToken // empty' .credentials.json)"; echo "$at" | md5sum`
→ con `at` vacío da `68b329da9893e34099c7d8ad5cb9c940`. El sentinel es válido SOLO para ese
procedimiento exacto: otra vía de extracción (`printf '%s'`, hash del fichero completo)
produce otro valor y NO debe compararse contra `68b329da`.

### MOVE transaccional de credenciales (`auth-move.sh`) — un-login-un-lugar (TAL-2294)

Para **Codex** (y para cualquier login que deba vivir en UN solo lugar) la operación canónica es el
**MOVE**, no la copia. `scripts/auth-move-lib.sh` + `scripts/auth-move.sh` implementan una
transacción con recuperación ante crash. **Endpoints tipados**: `host:<hostname>`,
`channel:<container>`, `pool:<pozo-id>`.

```bash
# Mover el login de una cuenta de un endpoint a otro (extracción de pozo, host→canal, canal→canal):
bash scripts/auth-move.sh move <cuenta> pool:<pozo> channel:<canal> [--agent codex|claude]
bash scripts/auth-move.sh repair <tx_id>    # reconcilia/repara una transacción interrumpida
bash scripts/auth-move.sh resume <tx_id>    # reanuda hacia DONE (o repara)
bash scripts/auth-move.sh status [tx_id]    # lista/detalla transacciones
```

Garantías del protocolo (contrato completo en la cabecera de `auth-move-lib.sh`):

- **3 locks** (cuenta + donante + destino) en orden determinista, posesión probada por **FD flock**.
- **Freeze durable por endpoint** antes de matar procesos: los launchers/entrypoints (`v<XY>`,
  relaunch de refresh) **rechazan arrancar** con freeze presente; la única ejecución bajo freeze es
  la **vía autorizada** del propio MOVE (tx_id + journal + locks simultáneos).
- **Destino inmovilizado y VACÍO**: quiescence verificada de ambos lados; un `auth.json`
  preexistente en el destino → RECHAZO (es otra credencial viva; requiere su propio MOVE).
- **Commit = `mv` atómico** en el destino tras **digest verificado**, ANTES de cualquier request
  (un timeout no prueba que el servidor no consumió el refresh). Post-commit todo se repara **en el
  destino**; jamás se restaura al donante.
- **Journal durable** (temp→fsync→rename→fsync-dir) con fases
  `PREPARED→ORIGIN_RETIRED→INSTALL_INTENT→DEST_INSTALLED(commit)→VERIFIED→DONE` y **reconciliación
  por inspección** (el digest en el destino manda; estado contradictorio → fail-closed/manual).
- **Durabilidad fsync** de las credenciales (no solo del journal); el snapshot (última copia) se
  destruye SOLO tras confirmar durabilidad del auth destino + journal de commit.
- **Propiedad en el ledger al commit**; **guard de coordinador único** (`coordinator_host`).

Cobertura de tests: `tests/run-tests.sh` con shims por PATH y failpoints —
locks/posesión, freeze+vía autorizada, commit, durabilidad, reconciliación (digest→commit /
ausente→restore / contradictorio→fail-closed), **crash kill-9 en fronteras**,
timeout-con-refresh-consumido, dos MOVE concurrentes al mismo destino, y (TAL-8042) quiescencia por
ejecutable, rc por fase y suite hermética (ver abajo).

**Quiescencia por EJECUTABLE, no por línea de comandos (TAL-8042).** `am_ep_quiesce`, `am_ep_quiet` y
`tc_kill_wait` enumeran `pgrep -u <usuario>` (**sin `-f`**) y filtran en `/proc`: un proceso es el agente si
el basename de su `argv[0]` **o** su `comm` íntegro es `codex`/`claude` (zombis fuera). Cada candidato se
vincula a instante de arranque, usuario, ruta real y dispositivo/inodo del ejecutable. Esa identidad y las
protecciones se revalidan inmediatamente antes de señalar: un cambio o dato ilegible se registra, no recibe
señal y devuelve rc 3. El viejo patrón sobre el argv
completo alcanzaba `~/.codex`, `--agent codex`, `tee codex.log` y al **lector de stdout del propio MOVE**: al
morir, la última escritura tras `DONE` daba SIGPIPE → rc 141 con el journal cerrado, y el operador lo leía
como «pre-commit» (copiar el login de vuelta = dos copias de un refresh de un solo uso → cascada de
revocación). Los **ancestros, el grupo y la sesión** del shell que ejecuta el kill son *protegidos* (jamás se
les envía señal; protege del auto-kill TAL-3539) y, si uno de ellos **es** el ejecutable del agente, cuenta
como **vivo** (rc 1: falla cerrado, nunca quiescencia falsa). Las tres copias del snippet
(`lib.sh`, `auth-move-lib.sh` y `talent-channel-operation/scripts/lib.sh`) son idénticas y la paridad la
asserta la suite («duplicar antes que acoplar»); un ratchet falla ante cualquier nuevo `pgrep/pkill -u … -f`.

**rc final del CLI por FASE del journal.** `auth-move.sh move` ignora SIGPIPE, corre el protocolo en un
subshell y deriva el rc del journal del tx de esa ejecución: **`DONE` → 0** (un fallo de escritura a la salida
no cambia que la transacción cerró); **`DEST_INSTALLED`/`VERIFIED` con anomalía → 4** (commit hecho: reparar
**EN destino** con `repair`/`resume`, jamás restaurar al donante); **antes del commit** → el rc original ≠0
(el MOVE ya reconcilió o dejó los freezes fail-closed). `tco_reauth_move_action` (talent-channel-operation)
clasifica igual: por la fase del journal del tx **nuevo**, no por el rc a ciegas.

**Suite hermética.** `tests/fake-incus.sh` ejecuta el payload sobre el host real, así que blinda `pgrep` y
`kill` con una **lista de PIDs creados por el propio test** (`$AM_TEST_CROOT/.allowed-kill-pids`): nada
registrado ⇒ nada visible ni matable; cualquier otra forma de enumeración se rechaza (rc 2). Dos **canarios**
ajenos (argv con `codex-centinela` y `argv[0]` exacto `codex`) se comprueban vivos al final. El 2026-10-03 la
suite, corrida fuera de un espacio de PID propio, mató agentes reales de otras sesiones.

**Cuenta Codex ÚNICA (instalación de un tercero).** Con **una sola cuenta Codex** el login vive en **un solo
lugar a la vez** (refresh de un solo uso): se **MUEVE** `host:<máquina>` → `channel:<canal-auditor>` con
`auth-move.sh move` —nunca se copia a N canales— y hay **un auditor Codex a la vez**. Para los demás canales la
auditoría sigue siendo **Claude con rol adversarial** (`TCO_AUDIT_TOPOLOGY=mismo-adversarial` en
`talent-channel-operation`): la garantía es de **rol**, no de proveedor, y queda declarada y visible en cada
despacho (`AUDITOR: <ejecutable> · topología: <valor>`). Un canal cuyo auditor debía ser de otro agente y
resulta ser el mismo **detiene** el despacho (topología `distinto`, el default).

## Doble línea por pozo (sistema de reserva del lead)

**Vocabulario**: un **pozo** = una **cuenta**; una **línea** = un **login** (cada `claude login`
acuña un refresh token independiente). La cascada de revocación mata por **LÍNEA** (~13 clones que
comparten esa credencial), no por cuenta ⇒ **ley ≤12 clones por línea**. Una cuenta sostiene **2
líneas** (24 clones máx; patrón p2 = 12+12).

Operativa:

- Contenedores de pozo `p1..p6` en el host del CEO. **Línea 1** = perfil `~/.claude` default;
  **línea 2** = `CLAUDE_CONFIG_DIR=~/.claude-l2`. Aliases `pN` / `pN-2` + `pozos-ls` en
  `~/.bash_aliases`.
- **Ciclo de una credencial** (respeta el §Contrato de secretos — **NUNCA a stdout**): el lead
  acuña (login) → el CEO **cosecha DIRECTO a `$SECRET_DIR` con 0600**, sin imprimir el token ni
  dejarlo en scrollback/logs/working-tree:

  ```bash
  umask 077; set +x                                       # sin eco del valor
  dst="$SECRET_DIR/creds-pN-lX.json"                      # $SECRET_DIR 0700, FUERA del repo (nunca 'harvest/' relativa)
  tmp="$(mktemp "$SECRET_DIR/.creds-pN-lX.XXXXXX")" || exit 1   # temporal DEFINIDO en $SECRET_DIR
  trap 'shred -u "$tmp" 2>/dev/null' EXIT                 # DESTRUYE el temporal (contrato de secretos: shred, no rm)
  # Cosechar al TEMPORAL, nunca al destino: un incus exec parcial NO debe truncar una reserva válida.
  incus exec pN -- cat <cred> > "$tmp"   || { echo "harvest FALLÓ — $dst intacto" >&2; exit 1; }
  # Validar el ESQUEMA canónico de Claude Code (claudeAiOauth con access Y refresh) ANTES de promover.
  # OJO: en jq la cadena VACÍA es truthy → hay que exigir strings de longitud > 0, no solo que la
  # clave exista (si no, una cred BLANQUEADA {"accessToken":"","refreshToken":""} pasaría y el mv
  # destruiría una reserva válida; el canary lo detectaría tarde). $dst queda intacto ante cualquier
  # fallo (truncado, esquema distinto, o blanca):
  jq -e '(.claudeAiOauth.accessToken  | type=="string" and length>0)
     and (.claudeAiOauth.refreshToken | type=="string" and length>0)' "$tmp" >/dev/null \
    || { echo "cred inválida/truncada/blanca — $dst intacto" >&2; exit 1; }
  chmod 0600 "$tmp" || exit 1            # permisos EXPLÍCITOS (no dependemos del umask del destino)
  mv -f "$tmp" "$dst" && trap - EXIT || { echo "promoción FALLÓ — se shredea el tmp" >&2; exit 1; }
  # ↑ el trap se limpia SOLO si el mv atómico tuvo éxito; si falla, el trap (shred) sigue armado.
  ```

  → **canary** leyendo `$dst` (no un valor impreso): `curl` a `/api/oauth/usage` (headers
  oauth-beta + UA `claude-code/2.0`; **471 b = viva, 243 b = blanca**) → anotar en el ledger la
  **ruta y el estado** (nunca el token).
- **Escrow SOLO para pozos VÍRGENES (23-ago-2026, ch44/ch47)**: el **primer canal que usa un
  pozo** rota el refresh token de esa línea al primer request real — y eso **mata las copias l1/l2
  del escrow** cosechadas del mismo pozo ANTES de usarse (canary **471 b→243 b**, "stub-logout" a
  los 28 s de arrancar con la copia muerta). **md5/tokLen del fichero NO lo detectan** (el fichero
  es válido en forma; solo el token que contiene ya está revocado server-side). Regla: cosechar al
  escrow SOLO pozos que NADIE está usando todavía; un pozo **ya en uso** se cosecha del **hermano
  VIVO** (el canal que lo está usando activamente ahora mismo), nunca del escrow para ese pozo.
  El probe headless (`claude --print` u otra request autenticada real) es la **instancia
  canónica** de la "request AUTENTICADA real" ya exigida arriba (T3) para declarar un canal vivo
  — ni md5 ni tamaño de fichero certifican vida server-side.
- **Reserva SIEMPRE ≥1 línea por frente**: un relevo propaga el fichero de credencial, y **el
  restart depende del estado de la SESIÓN** (contrato dual del Muro 1 / T1 — NO un "SIN restart"
  incondicional): sesión **VIVA trabajando** (token en RAM) → propagar + nudge, re-lee la cred
  fresca del disco al refrescar, **sin restart**; sesión **YA logged-out/atascada** → propagar
  **+ RESTART obligatorio** (una sesión caída NO re-lee el disco sola — ver «Sesión atascada» y la
  tabla de Muros arriba). Distinguir por ACTIVIDAD real, no por la status-bar. Mantener una línea
  de repuesto viva evita quedar sin cuenta cuando una cae por cascada.
