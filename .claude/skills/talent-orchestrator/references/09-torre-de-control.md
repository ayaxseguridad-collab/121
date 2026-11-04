# 09 — Torre de Control (operación de la flota en tmux)

## Table of Contents

- [Modo dual (torre ↔ manual)](#modo-dual-torre--manual)
- [Detección de la sesión viva](#detección-de-la-sesión-viva)
- [Sweep de panes (solo lectura)](#sweep-de-panes-solo-lectura)
- [Menú abierto: `menu-abierto` y el escalado obligatorio al bus](#menú-abierto-menu-abierto-y-el-escalado-obligatorio-al-bus)
- [send-keys: doctrina anti-fantasma](#send-keys-doctrina-anti-fantasma)
- [Monitor: panes + Linear + límites de cuenta](#monitor-panes--linear--límites-de-cuenta)
- [Torre de mando: dashboards y publicación de datos](#torre-de-mando-dashboards-y-publicación-de-datos)
- [Supervisión sin interrumpir: trabajo genuino vs idle real](#supervisión-sin-interrumpir-trabajo-genuino-vs-idle-real)
- [Aprobación de prompts](#aprobación-de-prompts)
- [Postura de la Torre: HOST vs contenedor (no confundir)](#postura-de-la-torre-host-vs-contenedor-no-confundir)
- [Regla 0 extendida: modelo VIVO por sesión de actor (`tco_ensure_model`)](#regla-0-extendida-modelo-vivo-por-sesión-de-actor-tco_ensure_model)
- ["Press up" tiene DOS causas — nunca reaccionar sin capturar `-e`](#press-up-tiene-dos-causas--nunca-reaccionar-sin-capturar--e)
- [Doctrinas de monitoreo cross-flota (D1 · D2 · D3)](#doctrinas-de-monitoreo-cross-flota-d1--d2--d3)

La **Torre de Control** es una **capa de operación OPCIONAL** del modelo de fábrica: en vez de
que el lead haga de relay entre actores en terminales sueltas (modo manual), el Orquestador
opera las sesiones de los actores (Mergeador y coordinadores) desde **tmux**, leyéndolas con
`capture-pane` y relevándolas con `send-keys`, y monitorizándolas en background. **La Torre es
optimización, no dependencia**: la fábrica debe poder armarse sin ella (modo manual). La
mecánica completa de migración (arranque de sesiones, checklist post-resume, seguridad) vive
en el runbook `docs/runbooks/torre-de-control.md`; aquí va la doctrina de operación del
Orquestador. **Helpers versionados (TAL-2278)**: la operación torre-\* está script-ificada en
`scripts/` — `torre-sweep.sh`, `torre-relay.sh`, `torre-compact.sh`, `torre-resume.sh` (puras
testeables en `lib-torre.sh`); los comandos manuales quedan como fallback.

## Modo dual (torre ↔ manual)

```text
Modo dual: manual ↔ Torre — switchover en ambos sentidos, nada se pierde (todo durable en Linear+git)

  MANUAL                              TORRE (tmux del HOST)
  actor en terminal suelta            torre-<actor> en tmux
  lead hace de relay          ◄────►  Orquestador cosecha (capture-pane) + releva (send-keys)
  reporta por mensaje                 solo lo DURABLE va a Linear (no duplica el pane)

  Detección de sesión viva: torre-resume.sh <actor> --cwd <exacto>
    0 candidatas o >1 ──► ABORTA (lista, nunca adivina)
    exactamente 1, mtime==AHORA ──► esa es la viva
```

- **Manual**: cada actor corre en su terminal; el lead hace de relay. Los coordinadores
  reportan al lead por mensaje; lo DURABLE (rulings, entregas, veredictos de gate, decisiones
  cross-flota) va a **Linear** por API directa.
- **Torre**: las sesiones viven en tmux (`torre-mergeador` / `torre-c1` / `torre-c2` / …); el
  Orquestador cosecha los reportes leyendo el pane y solo lo **durable** va a Linear (no se
  duplica el estado efímero del pane en Linear).
- **Switchover en ambos sentidos**: a Torre = migrar la sesión a tmux con `--resume` (runbook);
  a manual = `tmux attach` y operar a mano. Ninguno de los dos pierde estado (todo lo durable
  está en Linear + git + los runs-dir de cada estación).

## Detección de la sesión viva

Vía canónica: `scripts/torre-resume.sh <actor> --cwd <pwd-exacto> [--list]` — selecciona la viva
por `mtime==ahora` (0 o >1 candidatas → aborta listando; nunca adivina), valida el UUID
(`torc_is_uuid`, también con `--uuid`) y lanza `torre-<actor>` con bypass por plantilla fija
shell-safe. Doctrina manual (fallback):

Con varias sesiones del MISMO directorio en un host (coordinador, Orquestador, Mergeador),
identificar la sesión correcta por **el transcript cuyo `mtime` es AHORA** (se escribe en
vivo), **NO por "la hora más alta"** (una sesión vieja del mismo dir puede mostrar una hora
del día mayor pero fecha más antigua). El UUID está en la ruta del scratchpad / el `.jsonl`
más fresco de `~/.claude/projects/.../`. Gotcha de zona horaria: `ls` muestra hora LOCAL
(host UTC-6) — comparar contra `date -u`. `claude --resume <uuid>` corre desde el **cwd
exacto** (las sesiones son dir-scoped).

## Sweep de panes (solo lectura)

Vía canónica: `scripts/torre-sweep.sh [actor…] [--ansi] [--scrollback N]` (captura enmarcada +
resumen busy/ctx/flags por actor).

El Orquestador barre los panes con `tmux capture-pane -p` (read-only) para cosechar estado:
qué encargo corre cada canal, gates en curso, veredictos. Cadencia por wakeup/monitor
one-shot (nada persistente que morir). Lo durable de ese sweep (circuit-breaker, decisiones,
cross-flota) se escribe a Linear; lo efímero se queda en el pane.

## Menú abierto: `menu-abierto` y el escalado obligatorio al bus

Un actor que espera una decisión superior **en un menú de su pane** sin sellar nada es invisible para quien
solo lee el bus (un coordinador estuvo así más de una hora y el CEO reportó «sin stall»). `torre-sweep.sh`
añade el flag **`menu-abierto`** al resumen cuando el pane muestra un selector numérico abierto
(`torc_torre_menu_open`, función pura en `lib-torre.sh`: cursor `❯ N.` + otra opción numerada + la pista del
selector — un composer con `> 1. texto` NO lo dispara). El resto del resumen `busy · ctx · flags` no cambia.

Doctrina: **todo bloqueo que requiera autoridad superior se sella en el bus ANTES de esperar** —
`ESCALA-<ROL>-<ref>` con nota `BLOQUEO-AUTORIDAD · espera:<rol> · decisión · default` — y el ruling se acusa con
`ACK-<ROL>-<ref>`. El doctor del CEO (`talent-ceo` ref 07) cruza `menu-abierto` con el último sello del rol:
menú abierto, sello más viejo que `TA_ESCALADO_MIN` (15 min) y sin `ESCALA-<ROL>-*` = `FALLA bloqueo-sin-escalar`.
Un actor que vuelve de un `/clear`, un reinicio o una sesión nueva queda NO ACREDITADO hasta re-acreditar; el
Orquestador no le releva trabajo mientras tanto. `/clear` está prohibido en actores persistentes.

La garantía del detector cubre el selector de tres señales en la región activa (últimas ocho
líneas no vacías; excluye citas explícitas e historial anterior al último prompt). Un encabezado
informativo no anula un selector posterior: solo se excluyen bloques delimitados o rotulados
como cita explícita o «no selector activo», respetando siempre el último prompt. La pregunta
en texto libre es solo una heurística del doctor: pane en reposo con pregunta final y sin
escalado reciente del rol produce `AVISO posible-pregunta-sin-escalar`, informativo y sin
cambiar el rc. No garantiza detectar todas las esperas de autoridad; ni un «?» intermedio
ni una lista numerada bastan para ese aviso.

## send-keys: doctrina anti-fantasma

Vía canónica: `scripts/torre-relay.sh <actor> --text '…'|--file <ruta>` — implementa TODA esta
doctrina (pre-check del composer, post-paste PRE-submit, entrega verificada; rc 3 = cola real
escalar, rc 4 = mismatch/no-clobbear). El protocolo compact-60 va por `scripts/torre-compact.sh`
(`check` gatea por ctx%, `run` ejecuta los 4 pasos con nonce anti-stale). La doctrina (umbral 60 %,
checkpoint limpio, fichero de regreso, paso-0) es canónica en `talent-context`.

**Handoff de compact-60 por FICHERO (TAL-8039)**: con el TUI en pantalla alternada `capture-pane` es solo
el viewport, así que un handoff largo pierde su `HANDOFF-INICIO` (compact-60 de C1 al 92 %: bloque en
~369 s frente a `TORRE_HANDOFF_MAX=300`). `torre-compact.sh run` crea ANTES el dir 0700
`$TORRE_HANDOFF_DIR` y ordena al actor **escribir con Write**
`$TORRE_HANDOFF_DIR/<actor>.<TS>.pending.md` con el bloque entre `HANDOFF-INICIO <nonce>` y
`HANDOFF-FIN <nonce>` (el mismo patrón de STOP-AUDIT, TAL-3619). La recogida
(`lib-torre.sh` `torc_torre_collect_handoff`) lee el **fichero primero** — `torc_torre_read_handoff_file`
verifica el CONTENIDO: nonce exacto, bloque completo (rc 4 si INICIO sin FIN), `mtime` no anterior a la
petición (un fichero de otra ejecución no cuenta), no symlink; rc 2 = ausente/antiguo/otro nonce — y
cae a la **pantalla de respaldo** (el mismo extractor `torc_torre_extract_handoff`, rc 0/2/4). Si el
plazo base (`TORRE_HANDOFF_MAX`, 300 s) vence con el turno **vivo** (`torc_torre_busy`), prorroga
`TORRE_HANDOFF_EXTEND` (60 s) cada vez hasta `TORRE_HANDOFF_HARD_MAX` (1200 s); un turno **parado** o un
pane/sesión muerto (captura fallida: `torc_torre_alive`) no prorroga. El dir de handoffs debe ser propio,
0700 y NO un enlace simbólico (se rechaza antes de pedir). Sin handoff verificado: «ABORTO ANTES de /compact», rc ≠ 0 — jamás `/compact` sin handoff
guardado fuera. Cada nivel loguea `origen=fichero|pantalla`.

- **Distinguir ghost-text de cola real con `capture-pane -e`** (escape codes): un texto en el
  input prefijado por `^[[2m` (dim/gris) es **autocompletado** del CLI, NO un mensaje
  encolado — no se ejecuta solo y desaparece al teclear. La **cola real** se distingue por
  "Press up to edit queued messages" en brillo pleno. Ante CUALQUIER texto inesperado en el
  input: capturar con `-e` ANTES de reaccionar; **no "neutralizar" lo que es ghost**.
- **Verificar el eco** de cada relay antes de dar por entregado (un `send-keys` sobre pane
  ocupado se ENCOLA; reintentar a ciegas DUPLICA). Preferir esperar el eco a reintentar.
- Mensajes de relay que contengan `git push` u órdenes compuestas: crearlos con fichero (no
  heredoc/echo que el hook del host pueda ver como compound) — el push literal en un relay lo
  bloquea el hook.

## Monitor: panes + Linear + límites de cuenta

- **Formato canónico del flock** (fuente de las regex de monitores — dueño del contrato:
  `talent-merger` ref 01 §2; aquí solo puntero): los matchers de monitores se anclan a los 4
  tokens canónicos escritos por el Mergeador en el log de flock:
  - `# ✅ M<N> MERGED #<PR>` — merge completado
  - `# ✅ CEO RESUELTO #<PR>` — revisión CEO aplicada
  - `# 🔴 BOUNCED #<PR>` — PR rebotado
  - `# CR-RUN [host:<name>]` — ronda CodeRabbit iniciada

  Matcher canónico con límite numérico (evita falsos positivos en PRs con número prefijo de otro)
  — **SOLO los 3 tokens que llevan número de PR** (`MERGED` / `CEO RESUELTO` / `BOUNCED`; `CR-RUN`
  no lleva PR, usa `host:<name>` y se matchea aparte, ver abajo). `CLAIM` **NO pertenece a este
  contrato** — es un token de la reserva/idempotencia (`torc_route_precreate`, ref 05), no del
  flock del Mergeador; incluirlo aquí mezclaría dos contratos distintos y produciría falsos
  positivos si `torc_route_precreate` cambia su formato sin coordinarse con este matcher.

  ```bash
  command grep -E "(MERGED|CEO RESUELTO|BOUNCED) #${pr}([^0-9]|$)" "$FLOCK_LOG"
  # CR-RUN no lleva PR — matchear por host cuando aplique:
  command grep -E "CR-RUN \[host:${host}\]" "$FLOCK_LOG"
  ```

  Usar siempre `command grep` (bypass del wrapper `ugrep` del harness) y el ancla `([^0-9]|$)` que
  garantiza que `#123` no case en `#1234` — aplica a los TRES tokens con número de PR; `CR-RUN` no
  necesita esta ancla porque su matcher no incluye número de PR. La definición viva del formato
  vive en `talent-merger`; si cambia, el puntero aquí se actualiza en el MISMO PR que lo cambia.

- **Panes**: monitores one-shot (spawn por ciclo, salen al evento/timeout) mantienen al
  Orquestador en el loop sin `sleep` en foreground.
- **Linear**: el estado durable de la flota se re-deriva de Linear + git (PRs) + los runs-dir,
  nunca del TaskList del harness (que rehidrata stale — ref 06 §Intención-stale).
- **Límite de cuenta del CLI**: el tope de uso (p. ej. 5 h / 7 días) es **por reloj/cuenta, NO
  por sesión** — reciclar la sesión NO lo resetea. El aviso sale en la barra de estado del
  pane; ante ~90 %: reciclar ANTES del reset (contexto fresco + texto de regreso) en vez de
  quemar el margen en un gate que muere a medias.
- **Monitores frágiles/reaper (T6)**: los bg-watchers con un `sleep` largo los mata el reaper y
  el "monitor still running" MIENTE; el foreground topa a ~2 min — patrón correcto (bg con
  for-loop de condición terminal, foreground 200-280 s) en `talent-channel-operation` ref 03 §7.
- **Sesión de actor atascada logged-out → RESTART (T1)**: propagar credencial no revive una
  sesión que ya cayó (no re-lee el disco); distinguir por actividad, no por status-bar —
  doctrina en `talent-channels` ref 05 §Sesión atascada.
- **`claude --continue` colisiona por cwd compartido (T11)**: con varios actores en el mismo
  directorio, `--continue` resume la sesión AJENA — siempre `--resume <uuid>` (lo hace
  `torre-resume.sh`) o sesión fresca + re-brief (gotcha en `talent-channels` ref 07).
- **Verificación por conducta (T3)**: qué prueba cada señal (provisión / integridad de
  propagación / identidad de cuenta / actividad) — taxonomía canónica en `talent-channels`
  ref 07 §Verificar por conducta; las status lines rancias de la Torre son el punto ciego.

## Torre de mando: dashboards y publicación de datos

Cuando el Orquestador/CEO publica estado de la flota (dashboard, tabla en Linear, reporte al
lead), aplican estas reglas (Ev.: torre 2026-07-12 — un pozo al 88% semanal publicado como
"0% fresco"; el screenshot del lead cazó la mentira):

- **Cada celda declara su FUENTE**; si la fuente no rinde → **"—" honesto**, nunca relleno
  (regla dura canónica en `talent-channels` ref 05 §Lectura directa).
- **Jerarquía de fuentes**: **fiables** (estado de cred vía **`incus exec` + `jq` DENTRO del
  contenedor** — solo campos derivados, NUNCA `incus file pull` del fichero de credenciales, que
  volcaría el token; `talent-channels` ref 05 §Lectura directa —, gh API, ledger git) vs
  **frágiles** (scraping de TUI / `/usage`, capture-pane por fraseo). El estado CRÍTICO
  (vivo/expiry/cuenta, colas, migraciones) sale SIEMPRE de fuente fiable; lo frágil entra
  solo como complemento **marcado best-effort**.
- **Verificar el dato contra su formato esperado ANTES de publicarlo** — la verificación es
  del que publica, no del que lee (el screenshot cazó lo que el publicador debió cazar).
- **Semántica de cuota**: 5 h (sesión) y 7 d (semanal) son ventanas DISTINTAS con reset
  propio — no confundirlas; el %-de-límite ≠ tokens de la sesión del TUI; un login fresco NO
  resetea el semanal (detalle en `talent-channels` ref 05).
- **Scraping de TUI robusto** (cuando no queda otra): limpiar input antes, parseo bilingüe,
  timeout explícito; reparaciones SIEMPRE acotadas a la sesión objetivo (inventario
  `list-sessions` + `kill-session -t`; jamás `pkill -f 'claude'` — alcance amplio — ni
  `kill-server` con otras sesiones vivas; receta en `talent-channels` ref 05).

## Supervisión sin interrumpir: trabajo genuino vs idle real

Interrumpir a un actor que SÍ está trabajando cuesta más que un idle corto sin detectar. Antes
de nudgear/inspeccionar, clasificar:

- **Trabajo genuino que PARECE idle**: thinking largo (2-9 min sin output y **0 procesos** hijos
  es normal en razonamiento pesado); un gate e2e con migración tarda **40-60 min** — un pane
  quieto con un gate vivo NO está atascado.
- **Idle real (actuar)**: el disparador correcto NO es "idle > X min" — es **idle sobre un
  watcher/gate MUERTO**: contexto del pane idéntico en **3+ cortes** consecutivos del sweep
  **+ 0 procesos** de trabajo **+ el gate/watch terminó sin acción posterior**.
- **Cola estancada** (cola > 0 sin avance en 3 cortes): inspección de PROCESO, no nudge —
  `ps` del seal-suite/gate + `tail` de su log + `mtime` de los receipts: distingue "gate lento
  pero vivo" de "gate muerto".
- **Cola > 0 × cero actividad del Mergeador** = disparo de **deep-sweep** (neglect de estación,
  no un canal individual): inspeccionar la estación completa antes de tocar canales.

## Aprobación de prompts

En modo Torre, cuando una sesión de actor pide una aprobación interactiva (permisos, prompts
del CLI), la resuelve el operador de la Torre — SIN que ello cambie lo que NO cambia nunca:
los GO del lead, las aprobaciones de plan y la regla de no-push/merge sin gates (ver el
runbook, §Seguridad). El bypass de permisos con que arranca una sesión de Torre es autonomía
operativa, **no** autoridad de merge.

## Postura de la Torre: HOST vs contenedor (no confundir)

Las sesiones `torre-*` (Mergeador / coordinadores / el propio Orquestador) corren en **tmux del
HOST**, NO dentro de un canal. Los canales `vibe-channel-*` son contenedores Incus con sus propios
paneles `v<XY>` (Claude + Codex). Consecuencias que la Torre respeta:

- **`torc_torre_*` capturan/relevan panes del HOST** (`torre-mergeador`/`torre-c1`/…); para mirar
  DENTRO de un canal hay que entrar por su launcher o `incus exec` — no es lo mismo que un pane de la
  Torre. Confundir las dos capas lleva a "relevar" al actor equivocado.
- **Sin MCP heredado**: ni las sesiones de la Torre ni los canales usan MCP (token-only, regla
  TAL-1490 / `feedback-token-only`). Una sesión de Torre que arranque con un `.mcp.json` heredado del
  host es **deriva a limpiar** — el Orquestador opera por API directa con token, nunca por MCP.
- **tmux es prerequisito del HOST** (no del canal): ver `talent-channels` Gotcha 27 (`apt install
  tmux` en la máquina antes de operar la Torre).

## Regla 0 extendida: modelo VIVO por sesión de actor (`tco_ensure_model`)

La Regla 0 del proyecto fija el **effort por modo** (plan `xhigh` / coding `high`). En la Torre se
extiende al **modelo**: cada sesión de actor debe correr en el modelo correcto y **VIVO** antes de
recibir trabajo. El helper de operación `tco_ensure_model` (doctrina; la mecánica de sembrado vive en
`talent-channels` ref 06 §Agentes al día + Gotcha 28) **verifica y, si hace falta, fuerza** el modelo
de la sesión:

- **Doctrina de modelos multi-fábrica** (`doctrina-modelos-multifabrica`, lead 2026-07-09;
  capa META con PM desde 2026-07-30, TAL-3650): **CEO en Opus vigente; PM en Sonnet vigente**; orquestadores, coordinadores y mergeadores corren **`Sonnet vigente` `high`** (`xhigh`
  únicamente para planes), sin cambio. Los **canales** ya NO corren un solo modelo de forma plana:
  **arrancan en `Opus vigente` (plan `xhigh`) y el coordinador los conmuta a `Sonnet vigente` en coding (`high`)**
  (modelo-por-fase, TAL-2675, 2026-07-13; fallback a `Opus vigente` `high` si el code-gate no converge en 5
  rondas — detalle en `talent-channel-operation` ref 11). Un actor que arranca en Fable por herencia
  del default de la cuenta se **corrige** (forzar el ID COMPLETO del modo que corresponda, p. ej. `Opus vigente`; alias desnudos prohibidos — regla 0), no se deja.
- **VIVO, no solo sembrado**: una cuenta puede tener un modelo **agotado/muerto** (histórico: Fable
  agotado en la cuenta de la flota) — un actor con default muerto se cuelga en silencio. `tco_ensure_model`
  no da por listo un actor hasta que una prueba real responde en el modelo correcto.
- Casa con la auditoría del mapa consumidor→cuenta de `references/10` §4 (las status lines rancias
  de la Torre son el punto ciego: confirmar con una request autenticada con identificador de cuenta — taxonomía T3, `talent-channels` ref 07 —, no con la barra del pane).

## "Press up" tiene DOS causas — nunca reaccionar sin capturar `-e`

El texto/aviso "Press up to edit queued messages" (o cualquier texto inesperado en el input) tiene
**dos orígenes distintos** que se distinguen SOLO con `capture-pane -e` (escape codes) — reaccionar
sin capturar corrompe el estado del pane:

1. **Cola REAL**: hay mensajes encolados de verdad. Se ven en **brillo pleno**; `Up` cicla la cola.
   Un `send-keys` sobre este pane se **encola** (no se ejecuta ya) → reintentar a ciegas DUPLICA.
2. **Ghost-text (autocompletado)**: texto en el input prefijado por `^[[2m` (dim/gris) — es una
   **sugerencia del CLI**, NO un mensaje encolado; no se ejecuta solo y desaparece al teclear.
   `torc_torre_input_state` lo clasifica como `ghost`, no `queued` (cubierto por tests). **NO
   "neutralizar"** lo que es ghost: `Escape`/`C-u` sobre una cola real NO la vacían y sobre ghost es
   ruido. Ante CUALQUIER "Press up": capturar con `-e` ANTES de actuar y clasificar.

## Doctrinas de monitoreo cross-flota (D1 · D2 · D3)

- **D1 — Flag cross-flota en el MOMENTO del veredicto, no en la entrega**: cuando el hallazgo
  de un auditor revela que el issue de un canal es cimiento de un issue de OTRA flota (p. ej.
  "la RPC sola no desbloquea la UI porque el portal corta antes en un gate"), esa señal se
  **postea en Linear al instante del GO/NO-GO** — la otra flota necesita saberlo YA, no al
  entregar. El Orquestador propaga la dependencia entre órdenes.
- **D2 — Una ronda con muchos NO-GO = el loop adversarial FUNCIONANDO**: cada NO-GO con un
  agujero real (pérdida de cobertura, deadlock, contrato roto, frase que viola la regla 6…) es
  un bug/merge evitado. Se LEE como calidad, no como bloqueo; el precio es una ronda de
  re-plan. Para NO-GO repetido en el MISMO eje (circuit-breaker del coordinador): re-cura con
  **partición** del encargo (mitad decidible / mitad diferida a una issue nueva) — cosechar el
  root-cause que el dev articula al parquear suele contener la partición correcta.
- **D3 — "GO-bloqueo → una pregunta al lead" es salida VÁLIDA de un encargo de spec/ADR**: si
  un encargo de especificación/ADR se apoya en un contrato ambiguo, el plan correcto es **NO
  redactar sobre base ambigua** y escalar UNA pregunta de contrato al lead (regla 22). El
  Orquestador acepta ese "GO-bloqueo" como resultado legítimo, no fuerza la redacción.
- **D4 — Todo actor de fábrica tiene lado de lectura del bus/entrada, no solo escritura**
  (regla dura 16, 2026-07-28): la Torre que solo publica al bus (censo, dashboards) y nunca
  escucha lo que otras estaciones publican es una ventana ciega estructural. Lado de lectura
  obligatorio: **cursor persistido fuera del proceso**, **latido explícito**, **cobertura
  amplia por defecto**. **Dos canales**, no uno: el bus de coordinación **y** la entrada propia
  del agente — con `send-keys` a torres detached, un Enter que no aterriza en la misma
  llamada deja la orden escrita y sin someter, invisible para quien la recibe. Doble
  salvaguarda: el emisor manda el Enter en llamada SEPARADA y verifica el EFECTO (composer
  vacío); el receptor vigila su propia entrada con **anclaje estructural a la línea del
  prompt** (nunca al pane entero — D5) y guarda de plausibilidad anti-NBSP (`\xc2\xa0`, que
  `[[:space:]]` bajo `LC_ALL=C` no recorta). El muestreo por ticks REDUCE el riesgo, no lo
  elimina: un evento efímero puede aparecer y desaparecer entre dos ticks — no se declara el
  canal "cubierto" solo por tener vigilante.
- **D5 — Un detector cuyo patrón puede aparecer en el contenido que analiza se envenena solo**
  (regla dura 17, 2026-07-28): `pgrep`/guards/watchers de la Torre que buscan su
  propio patrón dentro de contenido donde ese patrón aparece legítimamente se disparan
  consigo mismos (un `pgrep` que matchea su propio waiter, un watcher que suprime bloques
  ajenos que citan su formato en prosa). Donde la disyunción patrón-vs-contenido sea
  imposible, exigir las DOS salvaguardas: **guarda de plausibilidad** (descartar el propio
  invocador — PID/árbol propio, `cwd`/`fdinfo` en vez de la línea de comando) y **anclaje
  estructural, no textual** (una marca que SOLO el emisor legítimo puede producir — un
  delimitador de formato, un campo de fichero estructurado — nunca prosa que cualquiera
  puede citar). Familia completa (clave exacta / efecto / detector disjunto) con evidencia
  medida en `talent-merger/references/07-gotchas.md` §6-7.

Registro de modelos: `~/.config/talent-channel-operation/modelos.conf` del usuario del rol; CEO y plan/fallback usan Opus vigente, los demás roles y salud Sonnet vigente. Resolver tras acreditar Claude con `talent-channel-operation/scripts/resolver-modelos.sh`.
