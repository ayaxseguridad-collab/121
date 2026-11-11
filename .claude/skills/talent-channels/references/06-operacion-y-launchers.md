# 06 — Operación diaria, lanzadores y GPU

## Table of Contents

- [Autostart (`scripts/04-autostart.sh`)](#autostart-scripts04-autostartsh)
- [Lanzadores (`scripts/install-launchers.sh`)](#lanzadores-scriptsinstall-launcherssh)
- [Agentes al día: golden neutro y preparación obligatoria del canal](#agentes-al-día-golden-neutro-y-preparación-obligatoria-del-canal)
  - [Mantenimiento periódico de binarios en TODA la flota (mandato del lead)](#mantenimiento-periódico-de-binarios-en-toda-la-flota-mandato-del-lead)
- [Gestión de context window (compact)](#gestión-de-context-window-compact)
- [Sizing — crear muchos, correr pocos (por HOST y por CUENTA)](#sizing--crear-muchos-correr-pocos-por-host-y-por-cuenta)
- [Host degradado — diagnóstico y recuperación 4+4](#host-degradado--diagnóstico-y-recuperación-44)
- [Build-lock por máquina (serializar los builds pesados)](#build-lock-por-máquina-serializar-los-builds-pesados)
- [GPU opcional (`scripts/enable-gpu.sh <canal>`)](#gpu-opcional-scriptsenable-gpush-canal)
- [Estado](#estado)

## Autostart (`scripts/04-autostart.sh`)

Activa `boot.autostart` en los canales con escalonado real (prioridad decreciente para el orden + `boot.autostart.delay` constante de 8s — en Incus ese delay es la espera tras arrancar cada instancia antes de la siguiente, así que no arrancan en bloque); **golden NO**. Tras corte de luz/reboot vuelven solos y tailscaled reconecta (estado guardado). Verifica `incus-startup`/`incus.socket`/`incus-forward` enabled.

**Clones de RESERVA/parkeados: SIEMPRE `boot.autostart=false`.** Un reboot del host despierta a los clones dormidos y duplica bloques de nombres en el tailnet (visto: v05 arrancó **16 contenedores** — su flota real + los `ch21-28` fantasma parkeados — colisionando numeración). Al parkear un clon: **`incus stop` + `incus config set <canal> boot.autostart=false`** + **anotar el bloque en el inventario** para evitar colisión de numeración entre máquinas. Solo los canales de la flota ACTIVA llevan `boot.autostart=true`.

## Lanzadores (`scripts/install-launchers.sh`)

Genera en `~HOST/.local/bin` desde `assets/launcher-*.tmpl`:

- `v <XY>` → tmux con 2 paneles (Claude `claude-root` izq | auditor der: el lanzador declarado en `agents.conf` (`TCO_AUDIT_CLI`), `codex` con su sandbox si no hay declaración), en el repo. Re-acopla si la sesión existe (no duplica). `LEFT_CMD`/`RIGHT_CMD` overridables.
  El launcher añade a Claude el identificador del registro del usuario lanzador: dev según
  `TC_CLAUDE_PHASE` (por defecto `coding`), auditor según `audit`. Otro proveedor conserva su orden.
  `refresh-claude-auth.sh --restart` recupera la fase del panel en `~/.claude/tf-phase-<pane>.json`,
  escrita por el launcher o al confirmar el picker. En canales anteriores lee la familia de
  `.model` en `~/.claude/settings.json` (Opus → plan/fallback; Sonnet → coding).
  `TC_CLAUDE_PHASE` es una anulación explícita; sin fuente válida se detiene antes de matar.
  Bajo `sudo`, el registro se obtiene del usuario invocador y el panel de la configuración persistente;
  para una anulación, conservarla explícitamente con `sudo --preserve-env=TC_CLAUDE_PHASE`.
  Para un lote con fases diferentes, invocarlo una vez por canal con su fase resuelta.
- `vk <XY>` → mata la sesión tmux del canal.
- Wrappers por canal: `v<XY>` / `v<XY>k` (sin guion; `XY` = máquina+canal, ej. `v11`/`v11k`).

**Acceso con fallback automático**: `v`/`vk` intentan **Tailscale SSH** y, si la ACL del tailnet no lo permite (probe con `ConnectTimeout`/`BatchMode`), caen a **acceso LOCAL** `incus exec` (sin `sudo` si el usuario está en `incus-admin`, con `sudo` si no). El fallback solo funciona desde el host que hospeda los canales.

**`claude-root` / `codex-root`** (aliases del golden, `scripts/02-golden.sh`): expanden a
`IS_SANDBOX=1 claude --dangerously-skip-permissions` y `IS_SANDBOX=1 codex …` respectivamente —
arrancan el CLI en **bypass de permisos confinado al contenedor unprivileged** (el sandbox es el
contenedor; nunca en el host). Los lanzadores `v`/`vk` los usan directo; `LEFT_CMD`/`RIGHT_CMD`
overridables. Además el golden instala **lanzadores ejecutables** `~/.local/bin/claude-root` y `codex-root` (`IS_SANDBOX=1 exec <cli> <flags> "$@"`): el despacho arranca el CLI con `tmux respawn-pane` (`bash -c`, sin `.bashrc`, donde viven los alias) y comprueba antes de lanzar que el lanzador resuelve a un ejecutable DENTRO del pane (misma shell y mismo PATH con que tmux lo arranca) y que el agente al que hace `exec` también resuelve; si no, se detiene con el remedio (reprovisionar el golden). `TCO_DEV_CLI` y `TCO_AUDIT_CLI` de `agents.conf` son UN solo ejecutable (`claude-root`, `codex-root` o una ruta absoluta): los flags van en `TCO_*_FLAGS` y las variables de entorno dentro de estos lanzadores, no en la variable del CLI.

**Renderer clásico (TAL-8038)**: todo `claude` de canal arrancado desde un shell NUEVO hereda `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1`
del `.bashrc` (`claude-root` y los lanzadores `v`/`vk`). Los relanzamientos de `pozos-install-token*.sh` hacen `send-keys` sobre un
shell YA abierto que no relee el bashrc: en un canal ya clonado quedan cubiertos por `"tui":"default"` de `settings.json` y por
`alternate-screen off` de tmux (que `apply-renderer.sh` aplica en caliente), y heredan también el env en cuanto el shell se reabre.
El resultado: el pane conserva scrollback (`#{alternate_on}`=0) y la barra `ctx: NN%` está instalada. Un canal clonado ANTES de esto
se arregla sin parar nada con `bash scripts/apply-renderer.sh`; `verify.sh` lo exige.

**Lanzadores torre-\* (Torre de Control — SCRIPT-IFICADOS, TAL-2278)**: para operar los actores
de la fábrica (Mergeador / coordinadores) bajo la Torre, sus sesiones viven en tmux con `--resume`
en el HOST (no dentro de un canal). El lanzador canónico es
`.claude/skills/talent-orchestrator/scripts/torre-resume.sh <actor> --cwd <pwd-exacto>`
(detección de la sesión viva por `mtime==ahora`, UUID validado, lanzamiento shell-safe con
bypass; `--list`/`--uuid`/`--dry-run`), junto a `torre-sweep.sh` / `torre-relay.sh` para la operación. El compact vivo se instala
con talent-context/scripts/install-compact-vivo.sh; banco por hooks y lectura obligatoria. Receta manual (fallback; los aliases NO están en
`install-launchers.sh` — se invocan por ruta del repo):

```bash
# HOST (una sesión por actor): NUNCA --continue con varias sesiones del mismo dir
tmux new -s torre-mergeador   # o torre-c1 / torre-c2
cd "<pwd exacto del actor>"
# Tras cargar lib-modelos.sh del paquete; rol=ceo para CEO, coordinador para el resto.
model="$(tco_modelo_read "$rol")" && [ -n "$model" ] || exit 1
IS_SANDBOX=1 claude --dangerously-skip-permissions --resume <session-id> --model "$model"
# c1 remoto: ssh -t de SISTEMA (no `tailscale ssh -t`, que NO existe): ssh -t <user>@<host> '…'
```

Mecánica completa (detección de sesión por `mtime`, checklist post-resume) en el runbook
`docs/runbooks/torre-de-control.md`.

**Codex = rol auditor, arranque inmediato**: el panel derecho lanza el CLI con el argumento completo de `~/.codex/role-prompt.txt` serializado mediante `printf %q` (incluidos saltos finales y texto que empieza por guion), de modo que Codex arranca ya en su rol de **auditor/analista** (nunca escribe código ni sube a GitHub; da GO/NO-GO por bloqueantes+mayores y revisa a nivel code-review profesional). El rol vive en `assets/codex-role.txt` → el golden lo escribe en `~/.codex/role-prompt.txt` (prompt inicial) y `~/.codex/AGENTS.md` (rol persistente, también si arrancas `codex` a mano).

Uso diario:

```bash
v11             # entrar/retomar el canal 1 de la máquina 1 (cerrar terminal NO mata el trabajo; tmux persiste)
v11k            # cerrar la sesión de ese canal
```

Copiar en tmux: **Shift+arrastrar**. Plan mode en Claude: **shift+tab** (funciona por `extended-keys`).

## Agentes al día: golden neutro y preparación obligatoria del canal

El golden se actualiza y se detiene con el modelo neutro. Cada clon exige preparación con el
registro de su instancia antes del primer arranque, como indica `03-golden.md`. Tras aprovisionar
(y periódicamente al operar), en CADA canal libre:

1. **`claude update`** primero — el CLI del canal debe estar en la última versión antes de sembrar el modelo.
2. **Modelo por canal en `~/.claude/settings.json`** (identificador completo de Sonnet vigente leído del registro — ID completo del tier de coding; regla 0 con GO doctrinal 2026-07-25, supersede la orden del 2026-07-08).
   El paso `[6b/9]` de `02-golden.sh` hornea `hasCompletedOnboarding` y un modelo vacío.
   La preparación del clon aplica obligatoriamente el identificador completo del registro;
   después se verifica y se actualiza al cambiar el registro. Es default de las sesiones del canal sin
   depender del `--model` del alias — y **jamás Fable** (fuera de la política rodante,
   `doctrina-modelos-multifabrica`). El effort NO se toca aquí: lo fija el coordinador por transición
   de modo (plan `xhigh` / coding `high`, regla 0). **Nota modelo-por-fase (TAL-2675; IDs completos por la regla 0)**:
   el baseline sembrado es `Sonnet vigente` (el canal dev es CODING — la fase que consume el default).
   El modelo de **arranque/plan** (`Opus vigente` `xhigh`) NO sale de esta siembra: lo garantiza el
   despacho (gate de modelo + `TCO_DEV_MODEL_ARGS`/`/model`) al abrir la fase de plan, y el
   coordinador conmuta de vuelta a `Sonnet vigente` en el GO de coding (con fallback a
   `Opus vigente` a la 5.ª ronda de code-gate) — switches SOBRE la sesión
   (`talent-channel-operation` ref 11 §5/§6), nunca cambios del baseline sembrado aquí.
3. **Verificar que el modelo por defecto está VIVO** (check de primera clase): una cuenta puede tener
   un modelo **agotado/muerto** — `claude-root` arrancaría en un modelo muerto y el pane se cuelga en
   silencio. No declarar un canal listo con un default muerto (histórico: la cuenta de la flota tenía
   **Fable agotado** → los canales arrancaban en un modelo muerto por defecto; por eso el check
   verifica que el baseline sembrado — `Sonnet vigente`, regla 0 — responde de verdad, sea cual sea).
4. **Codex también actualizado**: `npm install -g @openai/codex@latest` (o el mecanismo con el que se instaló en el golden) y verificar con `codex --version`.

**Gate de reanudación (no negociable): NO se retoma ni se despacha un carril sin esto 100%
verificado por el coordinador** — no se asume ni se delega al carril. Verificación por comando
dentro del contenedor (no de memoria): `claude update` reporta al día, el default de modelo del
canal está sembrado Y VIVO (`grep -i model ~/.claude/settings.json` → `Sonnet vigente` — el baseline es CODING
por la regla 0; plan/fallback usan `Opus vigente` vía switches del coordinador, nunca el baseline —, y una sesión de prueba
responde — no arranca en un modelo agotado), y `codex --version` coincide con la última publicada
(`npm view @openai/codex version`).

### Mantenimiento periódico de binarios en TODA la flota (mandato del lead)

Actualizar Claude Code, Codex y Node es tarea **periódica de flota**, no un acto puntual por canal:

1. **Codex: `npm install -g @openai/codex` como ROOT** — el auto-update lanzado como no-root
   **crashea con exit 243** (histórico verificado); instalar/actualizar siempre como root dentro
   del contenedor.
2. **Claude: por el instalador del contenedor** (el mecanismo con el que se instaló en el golden).
   El aviso **"Auto-update failed" de la status-bar es RUIDO**, no la vía fiable de update — no
   diagnosticar por él ni esperar que se resuelva solo.
3. **`hash -r` tras el swap** en cada pane de larga vida, o el pane sigue lanzando el binario
   viejo (Gotcha 13 de `07-verificacion-y-gotchas.md`).
4. **Una sesión viva NO toma el binario nuevo hasta RESTART** — programar el update en una
   **ventana sin trabajo en vuelo** (o aceptar el re-brief post-restart por canal).
5. **Alcance del install global**: `npm i -g` como root toca **todos los canales del host que
   compartan ese árbol** — hacerlo de forma controlada, **nunca mid-batch**.
6. **Orden**: actualizar el **GOLDEN** primero (clones futuros nacen al día) → re-propagar/barrer
   los **contenedores y hosts vivos**.
7. **Verificación post-update por host**: `claude --version` / `codex --version` en cada host y
   canal tocado → registrar en un **manifiesto comprobable** (qué versión quedó dónde), no "se
   actualizó" de memoria. **[TAL-3318/F3] Gate de consistencia cross-flota**: la tanda NO se
   cierra verificando canales sueltos — al final, comparar el manifiesto de TODA la flota + el
   GOLDEN (misma versión/hash en todos); cualquier divergencia = tanda ABIERTA (fail-closed):
   re-propagar al que diverge antes de volver a operar.
8. **[TAL-3318] Generalización a TODO artefacto de carga (no solo binarios)**: scripts, configs,
   manifiestos, motor, paquetes de skills — cualquier artefacto que se propaga a la flota se
   instala en **TODOS los canales + el GOLDEN en la misma tanda**, nunca solo en el canal que lo
   pidió o donde algo falló. Un canal "parcheado a mano" diverge en silencio y el fallo reaparece,
   irreproducible, en el siguiente canal — o renace con cada clon si el golden quedó fuera de la
   tanda (lección del arranque CRM 2026-07-22).
9. **Node al parche más reciente de su mayor (host, golden, canales y runner)**: el suelo de parche vive en
   `assets/node-suelos.tsv` y sube con cada aviso de seguridad de Node; una instancia ya montada queda por debajo
   cuando el suelo sube, y el doctor lo marca. Se sube con una operación propia, de dos pasos y con confirmación
   (`$PKG` es la carpeta del paquete): primero el plan, que no escribe nada y termina con `CONFIRMACION=<código>`;
   después la ejecución con ese código:

   ```bash
   bash "$PKG/skills/talent-channels/scripts/node-al-dia.sh" --plan
   sudo bash "$PKG/skills/talent-channels/scripts/node-al-dia.sh" --ejecutar "$CODIGO"
   ```

   Sube al parche más reciente de la MISMA mayor (nunca cambia de mayor ni baja) desde el repositorio de
   NodeSource que apt ya tiene configurado y autentica, golden primero, y comprueba el suelo al terminar. Un canal
   con tmux, claude o codex vivos, o con un proceso con el directorio actual dentro del motor, se SALTA, se nombra y
   el resultado final no es 0: ninguna sesión se para sola, y se repite después de cerrarla. El host no pasa por esa
   guarda (el operador corre dentro de una sesión) y apt no reinicia servicios. Una mayor sin suelo (la 18 de apt)
   no se toca: instálala con el procedimiento de NodeSource de `EMPIEZA-AQUI.md`. Los pozos de cuentas no están
   cubiertos. El paquete anterior no se borra y se declara. Los procesos de Node ya arrancados siguen con el binario
   anterior hasta que se reinicien. La identidad de la instancia (golden, máquina, usuario) sale de
   `instalacion/estado/contexto.conf` del paquete y de las respuestas que cita, no del entorno (`sudo` lo limpia).
   En una instancia sin ese fichero, el entorno con los tres valores (`sudo env GOLDEN=golden-<proyecto>
   MACHINE_NUM=<n> CUSER=<usuario> bash …` con las mismas dos órdenes de arriba); si falta algo, termina con rc 2 y
   dice qué falta. La golden y el runner de la instancia son obligatorios: si no existen, rc 1. `apt-get update` se
   limita al fichero de fuentes de NodeSource, de modo que un repositorio ajeno roto no impide subir Node.

## Gestión de context window (compact)

> Doctrina canónica (umbral, checkpoint limpio, fichero de regreso, paso-0, ctx-watcher, modos
> standalone/flota): skill **`talent-context`**. Aquí queda solo la operación dentro del canal.

Cuando el uso de contexto de una sesión dentro del canal (Claude o Codex) supere el **60%**
(protocolo compact-60 del lead 2026-07-08, supersede el >70% previo; en la fábrica lo vigila el
coordinador/Torre en cascada — ver `talent-channel-operation` ref 11 §9), antes de perder
continuidad de la tarea en curso:

1. Esperar el **checkpoint LIMPIO** de la sesión (idle, sin edición a medias, sin menú abierto) —
   JAMÁS compactar mid-fix ni con el árbol de trabajo sucio a medio guardar.
2. Pedirle explícitamente a la sesión que ESCRIBA su fichero de regreso FUERA del repo (temporal +
   rename atómico, autocontenido: tarea inmediata al volver, estado en-vuelo, próximos pasos,
   IDs/refs, loops armados) y VERIFICAR el Write antes de seguir — un resumen solo copiado al
   portapapeles NO cuenta como regreso escrito.
3. Ejecutar `/compact` — SOLO una vez el fichero de regreso quedó escrito y verificado en disco
   (nunca `/compact` antes de ese gate).
4. Al volver, el siguiente mensaje/acto es el **paso-0 canónico** (releer el fichero de regreso,
   verificar loops armados —adoptar vivos, re-armar muertos—, releer las fuentes de estado del
   canal, retomar), NO un simple pegado del resumen como si fuera el final del proceso.

## Sizing — crear muchos, correr pocos (por HOST y por CUENTA)

Dos ejes **independientes** gobiernan cuántos canales corren a la vez (crea N — CoW es barato —
y rota cuáles tienen sesión `v`):

- **Por HOST (capacidad de la máquina)**: un host **N95 + 32 GB RAM sostiene 8 pares dev+audit
  concurrentes SIN régimen de throttling** (verificado en producción en vibecoder-05).
  Supersede el "~4 concurrentes" previo. El régimen **4+4 (pause-rotation) + checkpoint-commit +
  gates throttled** NO es el límite del N95: es la mitigación de un host **DEGRADADO** (§Host
  degradado abajo).
- **Por CUENTA (cuota del proveedor)**: guía de reparto **≤4-5 canales activos por CUENTA** a la
  vez (por cuenta, distinto de los pares por host), **SUBORDINADA a la ley de pozos**
  (`talent-orchestrator/references/10-cuentas-y-pozos.md` manda el reparto cuentas↔canales).
  Sobrecarga de una cuenta → **canary reforzado** antes de escalar
  (`05-credenciales-por-carril.md` §"SAFETY canary — recycle-one-first"). El escalado acredita los
  canales nuevos por **propagación** (Claude COPY / Codex MOVE, método canónico #1087/TAL-2279),
  nunca por login por canal. Más activos = más cuentas Claude.

**Fan-out ESCALONADO en cualquier cambio de credenciales de flota (companion del eje por CUENTA)**:
cosecha, migración de pozo o revival de una credencial se propaga a los canales **un canal cada
30-60 segundos, NUNCA en burst** — un fan-out de golpe sobre N canales dispara el rate-limit de la
API del proveedor por N clientes refrescando/reconectando a la vez (mismo patrón que el
re-despacho escalonado del muro 4 en `05-credenciales-por-carril.md` §Muros de cuenta).
`scripts/refresh-claude-auth.sh` implementa el stagger (`TC_FANOUT_STAGGER_SEC`, default
`30-60`, override `0` para tests/CI); cualquier script nuevo que haga fan-out de credenciales debe
seguir el mismo patrón.

## Host degradado — diagnóstico y recuperación 4+4

El régimen 4+4 NO es el techo de sizing del N95 (§Sizing) — es la **mitigación de un host
DEGRADADO**. Antes de asumir "host muerto/ahogado" y rebootar, diagnosticar: la causa de
vibecoder-10 fue de **RED, no de capacidad** (tailscale relay-only DERP con `rx=0`, uplink
caído → `loadavg` 242 con `1/2755` runnable = cientos de procesos en **D-state** esperando red,
NO CPU saturada).

**Diagnóstico "host muerto/ahogado":**

1. **`uptime` ANTES de asumir reboot**: un timeout de ssh puede ser load alto, no un host
   caído — mira el uptime real y el loadavg antes de tocar el botón.
2. **`runnable/total` del loadavg**: load alto con **~1 runnable** (el `1/2755` de arriba) =
   procesos en **D-state** por I/O o **RED estrangulada**, NO saturación de CPU. Un load de 242
   con 1 runnable no es "demasiados canales": es todo el mundo bloqueado esperando algo.
3. **`tailscale status` del host**: relay (DERP) en vez de direct y **`rx=0`** delatan el uplink
   caído. Comparar contra un host gemelo sano (mismo perfil, red buena) para aislar
   red-vs-capacidad.

**Recuperación 4+4 (ejecutable):**

1. **Pausar todo salvo 1** canal (drain de los pares en vuelo con checkpoint-commit — el trabajo
   local queda a salvo).
2. Esperar a **load < 4**.
3. **Matar la causa raíz** (reparar el uplink / reiniciar tailscaled del host / restablecer la
   ruta direct — ver `04-clonado-y-tailscale.md` §"Verificación de ruta de red"), **no** los
   canales.
4. **Re-despacho gradual 2 → 4**, verificando que el load se mantiene sano en cada escalón.

Es mitigación de host DEGRADADO, no un límite de sizing: en un host sano (N95/32 GB) el techo
son 8 pares (§Sizing).

**Cross-ref (checkpoint-commit + diagnóstico thrashing-no-crash)**: el paso 1 de arriba (drain con
checkpoint-commit) y el diagnóstico completo de "thrashing sin llegar a crashear" del canal en
vuelo son detalle operativo de `talent-channel-operation` — este régimen 4+4 es el que lo consume
del lado de infraestructura del host.

## Build-lock por máquina (serializar los builds pesados)

En un host con N canales (sobre todo N95), **una ráfaga de builds/gates concurrentes satura
CPU/IO/red** y el pico tumba NICs débiles (§"Host degradado", gotcha r8169 de `07`). Los devs
codean en paralelo sin restricción — **solo las compilaciones se serializan a nivel de MÁQUINA**:
1 build pesado a la vez por host, el resto **bloqueado esperando** (no en paralelo). Distinto de la
serialización de gates del motor `local-gates` (`talent-merger` `references/08-gates-locales.md`
§5, que es de runners de la estación de merge): éste aplica a los **canales de producción en su
propio host, SIEMPRE**. Desplegado en
v05 (torre C3) y v10 (torre C4).

**El lock DEBE vivir en el HOST, no en el contenedor.** Un `flock` sobre un path local del
contenedor (`/run/lock/*`, `/tmp/*`) NO cruza contenedores: cada canal bloquearía un inode
DISTINTO en su propio namespace de montaje → los builds seguirían corriendo en paralelo. Para que
el lock serialice de verdad, el fichero de lock tiene que ser el **MISMO inode del host** visto por
todos los canales — vía un **directorio del host bind-mounteado en cada contenedor**:

**Permiso del lock en unprivileged (constraint DURA — si se ignora, `flock` aborta el build):**
en Incus unprivileged el `vivecoder` del contenedor (uid 1001) está **MAPEADO** a otro uid en el
host (base idmap del host + 1001). Un fichero creado como **ROOT** en el host y bind-mounteado
aparece dentro del contenedor como `nobody:nogroup` → el `vivecoder` no lo puede abrir → `flock`
falla y **aborta el build**. El fichero de lock DEBE ser **abrible por el `vivecoder` unprivileged
del contenedor**. Receta robusta e **independiente del mapeo de uid**: pre-crear el `build.lock`
**legible por todos** — un lock advisory solo necesita un fd abierto (basta LECTURA, no escritura),
así cualquier canal lo abre sea cual sea su uid mapeado:

```bash
# 1) Host: crear el dir y PRE-CREAR el lock world-readable (mapeo-agnóstico).
sudo mkdir -p /var/lib/vibe/locks
sudo touch  /var/lib/vibe/locks/build.lock
sudo chmod 0644 /var/lib/vibe/locks/build.lock   # abrible por cualquier vivecoder mapeado

# 2) Montar el MISMO dir del host en cada canal (mismo source → mismo inode = serialización real):
incus config device add <canal> buildlock disk \
  source=/var/lib/vibe/locks path=/var/lib/vibe/locks   # repetir para cada canal del host

# 3) Envolver el build/gate pesado en un flock sobre el fichero compartido (bloqueante):
flock /var/lib/vibe/locks/build.lock npm run build      # 1 build a la vez por host
```

Si tu wrapper abre el lock en modo O_RDWR (no solo advisory), lo que debe ser escribible es el
**FICHERO** (no basta tocar el dir: un `touch` sobre el `build.lock` root-owned 0644 del paso 1
falla porque el `vivecoder` mapeado no tiene escritura sobre ese fichero existente). **NO** hagas el
**dir** `0777`: un dir escribible permite **reemplazar el inode** del lock y **partir la exclusión**
entre el inode viejo (que aún sostiene un build) y el nuevo. En su lugar, **al provisionar (sin
builds en curso)** cambia la propiedad/permisos del **fichero**, dejando el dir root `0755`:

```bash
sudo chmod 0666 /var/lib/vibe/locks/build.lock   # FICHERO rw para cualquier vivecoder mapeado; dir 0755 intacto
# (equivalente: sudo chown <uid-mapeado>:<gid-mapeado> /var/lib/vibe/locks/build.lock — uid del
#  contenedor visto desde el host = base idmap del host + 1001)
```

Con el dir en `0755`, el inode del lock **no se puede reemplazar** → la exclusión es única. La receta
**primaria** (paso 1, world-readable) NO necesita nada de esto: un lock advisory se toma sobre un fd
de solo lectura.

**Caveat de idmap**: la serialización compartida asume que los canales del host comparten el mismo
rango idmap (default Incus **no-aislado**); con `security.idmap.isolated=true` cada canal mapea a un
uid distinto → usar SIEMPRE el lock **world-readable** del paso 1 (independiente del uid).
**Caveat de orden**: `flock` serializa (1 a la vez) pero **NO garantiza orden FIFO** — el kernel
despierta a un waiter arbitrario; para el objetivo real (no saturar el host) basta.

## GPU opcional (`scripts/enable-gpu.sh <canal>`)

**Off por defecto** (no lo corre `provision.sh`). A demanda, cuando un canal necesite la GPU (transcripción/ML):

- Preflight (`nvidia-smi` en host) + instala `nvidia-container-toolkit` si falta + `nvidia.runtime=true` + `incus config device add <canal> gpu gpu` + verifica `nvidia-smi` dentro.
- Quitar: `enable-gpu.sh --off <canal>`.
- **Caveat**: RTX de consumo **sin MIG** → GPU **compartida** (VRAM se reparte). Actívala solo donde haga falta.

## Estado

`scripts/status.sh` — foto rápida: contenedores, tailnet, GPU (off por defecto), sesiones tmux.

Registro de modelos: `~/.config/talent-channel-operation/modelos.conf` del usuario del rol; los roles se resuelven por proveedor con `tco_modelo_read` (tabla en `talent-channel-operation`, ref 11): CEO, PM, plan, re-plan y código sensible usan Opus vigente; código y coordinación, Sonnet vigente; el auditor es de otro proveedor. Resolver tras acreditar Claude con `talent-channel-operation/scripts/resolver-modelos.sh`.

La generación de lanzadores guarda la selección de sesión en
`~/.config/talent-channels/panel.conf`, con permiso 0600. La carga de configuración
y el reciclado leen esa misma selección. `TMUX_SESSION` y `TC_CLAUDE_PANE` son
anulaciones explícitas; la receta normal no necesita conservarlas bajo sudo.
Para una instalación anterior con sesión personalizada, regenera los lanzadores
con la selección de esa instancia antes de rotar. El reciclado acredita que el
panel existe y resuelve fase y modelo antes de matar; cualquier fallo de esa
acreditación conserva el agente y devuelve un error. Antes del relanzamiento se mantiene además la
comprobación de autoridad vigente, sin modelos de respaldo.
