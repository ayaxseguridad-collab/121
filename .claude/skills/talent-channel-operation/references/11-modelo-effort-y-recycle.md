# 11 — Modelo, effort y recycle

Gestión del MODELO y del EFFORT como gates operativos (Regla 0 ampliada), y los tres
procedimientos de reciclaje/desatasco de un carril.

## Table of Contents

- [1. El modelo es un gate operativo](#1-el-modelo-es-un-gate-operativo)
- [2. Verificar y forzar el modelo](#2-verificar-y-forzar-el-modelo)
- [3. Recycle duro](#3-recycle-duro) → [PROC-08](#proc-08--recycle-fresh-verificado)
- [4. Recycle suave](#4-recycle-suave) → [PROC-09](#proc-09--recycle-suave)
- [5. Dev en loop](#5-dev-en-loop) → [PROC-10](#proc-10--desatascar-un-dev-en-loop)
- [6. Effort residual y contexto degradado](#6-effort-residual-y-contexto-degradado)
- [7. Rotar la cuenta de la flota](#7-rotar-la-cuenta-de-la-flota) → [PROC-19](#proc-19--rotar-la-cuenta-de-la-flota-rate-limit--cuenta-agotada)
  - [7b. Los 4 muros de cuenta — marcador → recovery](#7b-los-4-muros-de-cuenta--marcador--recovery-tal-2294)
  - [7c. Despacho escalonado 2-en-2 bajo cuenta cargada](#7c-despacho-escalonado-2-en-2-bajo-cuenta-cargada-t8)
- [8. Protocolo 529 (error server-side)](#8-protocolo-529-error-server-side)
- [9. Compact-60 (protocolo del lead, en cascada)](#9-compact-60-protocolo-del-lead-en-cascada)

## 1. El modelo es un gate operativo

La cuenta puede **AGOTAR un modelo**. Caso real (sesión batch v14): panel colgado sin
producir output — el CLI arrancó con el modelo agotado y no hay error visible, solo
silencio. Además, el alias del contenedor (`claude-root`) **NO pasa `--model`** → cae al
default de la cuenta, que puede ser justo el agotado. Conclusión: el modelo se **VERIFICA y
FUERZA**, nunca se asume.

Tabla modo → modelo/effort (Regla 0 ampliada — **modelo-por-fase**, TAL-2675, 2026-07-13):

| Modo | Modelo | Effort |
|---|---|---|
| Plan (Fase A, re-plan tras NO-GO) | Opus vigente (`TCO_PLAN_MODEL`, desde el registro) | `xhigh` |
| Coding (Fases B/C) | **`Sonnet vigente`** (ahorro de cuota — decisión del lead 2026-07-13, conservada por la regla 0 vigente) | `high` |
| Fallback — code-gate NO converge en **5 rondas** sobre el mismo fix | sube ESE fix a **Opus vigente** | `high` |
| Auditoría (pane .1) | Sonnet vigente si el CLI auditor es Claude; el modelo de su proveedor en otro caso | según `TCO_AUDIT_EFFORT_CMD` |

El coordinador conmuta el modelo del dev en el GO de plan → coding (Opus vigente→Sonnet vigente) y en el fallback de
la 5ª ronda (Sonnet vigente→Opus vigente, ESE fix), con la coreografía de §6 y el contrato de rondas de §5. **NUNCA**
se baja de fase a mitad de un mismo tramo (plan sigue en Opus vigente hasta el GO; coding sigue en Sonnet vigente
hasta el fallback o el cierre del encargo). **`/effort max` PROHIBIDO** en todos los modos.

**Auditable en la entrega, OBLIGATORIO-POR-DISCIPLINA (NO machine-enforced)**: git no graba qué
modelo ejecutó cada fase — el coordinador declara el modelo REAL de Plan/Coding/Fallback en la
sección "Modelo por fase" del HANDOFF (`docs/templates/handoff-pr-draft.md`) al validar la entrega
(regla 13, `references/02` §4). `scripts/verify-handoff.sh` **NO** lo valida (ruling del lead: el
hard-enforce fail-closed se intentó y se revirtió por blast-radius — HANDOFF v1 existentes, sin
test versionado, refs del Mergeador desalineadas); la auditabilidad hoy depende ÚNICAMENTE de la
disciplina del coordinador — **ningún documento del Mergeador instruye todavía revisar este campo**
(un HANDOFF puede omitirlo y pasar `verify-handoff.sh` limpio sin esa revisión). Cerrar esa brecha
(instrucción al Mergeador + hard-enforce fail-closed) es **follow-up → TAL-2683**.

## 2. Verificar y forzar el modelo

**[TAL-3619] Panel VIVO** — `/model` (**SIN argumento**) abre el PICKER interactivo, conserva el
contexto (re-lee historia):

```text
/model  →  picker numerado  →  tco_model_picker_pick localiza el número del destino  →
dígito + diálogo SI aparece ("Yes, switch…"/"full history gets re-read"→ opción 1) →
verificación FINAL por el picker (marca de activo), NUNCA por el eco de un comando
```

**El envío inline `/model <slug>` es un NO-OP SILENCIOSO** (medido en el binario del CLI 2.1.220
de este canal: el CLI responde `Kept model as …` sin diálogo — el helper viejo esperaba un
diálogo que ese camino jamás produce; causa raíz confirmada de que 3 canales corrieran horas en
el tier caro sin señal de error, TAL-3619). `Kept model as …` por sí solo no acredita éxito:
el helper exige que el picker confirme el modelo solicitado; si ya es el activo, es idempotente.

El diálogo `/model` marca el modelo **activo** con `✔` (marca configurable
`TCO_MODEL_CURRENT_MARK`, calibrada en smoke). Helpers (`lib.sh`):

```bash
tco_ensure_model       <carril> <pane> <modelo>              # idempotente: verifica; cambia solo si difiere (0 = garantizado)
tco_set_model          <carril> <pane> <modelo>              # picker + verificación por picker; tri-estado: 0 confirmado · 1 envío/parseo falló · 2 sin confirmación
tco_model_picker_pick  <modelo>  (stdin = volcado del picker) # PURO: columna de familia y versión derivadas del registro; rc 1 = ausente/ambiguo
tco_verify_model_effect <carril> <pane> <modelo> <submit_uuid> [max_s]  # AUTORIDAD en disco: exige el assistant DESCENDIENTE de ESE submit con .message.model == modelo
```

`tco_verify_model_effect` es la segunda capa de verificación (además del picker): espera a que el
`.jsonl` persistido del CLI (Primitiva A, `references/03` §nuevo) confirme con qué modelo la API
sirvió REALMENTE el turno que siguió al switch — el `uuid` es un argumento OBLIGATORIO (nunca "el
último assistant", que podía ser el turno anterior al switch).

**Panel NUEVO** — el registro genera `TCO_DEV_MODEL_ARGS` y, para auditor Claude,
`TCO_AUDIT_MODEL_ARGS` con el identificador completo Sonnet vigente. `dispatch.sh` los añade al
lanzar y verifica ambos paneles. `audit-gate.sh` vuelve a comprobar el auditor antes de pedir
un veredicto; si difiere, lo cambia o se detiene. El doctor comprueba también ese panel.

El resolutor genera `OPUS_PICKER_ALIAS` y `SONNET_PICKER_ALIAS` junto al par de modelos.
El selector exige la familia en la primera columna y la versión correspondiente; la fila
`Default` no se usa. Una familia ausente o duplicada detiene el cambio. La etiqueta visible
de las torres sigue derivándose del identificador completo.

Cargar `00-config.sh` no exige registro ni inventa modelos. Los consumidores que lanzan,
cambian o verifican modelos lo exigen al usarlos y muestran la orden de resolución si falta.

**Gate de dispatch (fail-closed)**: con `TCO_DEV_MODEL` definido, si `tco_ensure_model` no
confirma el modelo → **NO se despacha** (`tco_die "modelo SIN confirmar (¿cuenta agotada?) —
ESCALAR"`). Un panel sin modelo confirmado es un panel posiblemente agotado: la decisión es
del lead, no del coordinador.

## 3. Recycle duro

El relaunch de un carril puede **RESUMIR + auto-compactar** la sesión previa en lugar de
arrancar fresco. Señales: el scrollback retiene contenido del issue anterior; el resume
**BAJA el effort**.

### PROC-08 — Recycle fresh verificado

1. Tras relanzar, capturar el pane dev y buscar el **placeholder de sesión fresca**
   (`TCO_FRESH_REGEX`, calibrar por TUI; `dispatch.sh` ya lo comprueba y traza si falta).
2. Sin placeholder (o con scrollback del issue previo) → tratar la sesión como **RESUMED**:
   no confiar en modelo ni effort heredados.
3. Re-fijar **SIEMPRE** tras recycle/resume: modelo (`tco_ensure_model`) **Y** effort del
   modo — los dos, porque el resume baja el effort aunque el modelo sobreviva.

**`TCO_AGENT_PROC_PAT` — semántica (TAL-8042).** El recycle duro mata los procesos de agente del canal
con `TCO_AGENT_PROC_PAT` (agents.conf), que es una **ERE ANCLADA (`^(…)$`) sobre el NOMBRE del ejecutable**
—basename de `argv[0]` **o** `comm`—, **no** sobre la línea de comandos: el viejo `pkill -f` alcanzaba
`~/.codex`, `tail -f codex.log` o el lector de stdout, y obligaba a la clase de caracteres anti-self-match
(G32). Recomendado `TCO_AGENT_PROC_PAT="claude|codex"`; los valores viejos `[c]laude|[c]odex` siguen
casando. Se mata solo lo **no protegido** (ancestros, grupo y sesión del shell del reciclaje; un protegido
que es el agente cuenta como vivo) y es *best-effort* como antes: el gate fail-closed del arranque es el
**preflight de identidad del pane** (`tco_pane_identity_preflight`, ref 03 §3c). Vacío = solo `kill-session`.

**Doctrina de credenciales en el recycle (leer ANTES de un hard):**

- **El hard MATA el token en RAM**: una sesión puede estar operando con token vivo en memoria
  sobre una cred on-disk vencida/blanca (T1, `talent-channels/references/05`). El soft (§4)
  preserva la sesión y por tanto ese token; el hard la mata — si la cred del disco no está viva,
  el canal relanza **muerto**.
- **Canary de credencial antes del hard**: verificar la cred on-disk (contenido no vacío + una
  respuesta real) ANTES del kill; hoy `tco_recycle_carril` hard NO lo hace por sí mismo (kill
  incondicional — limitación conocida, fix de código pendiente), así que el paso es del
  coordinador.
- **Alcance real del `git clean -fd` del recycle**: sin `-x` → respeta `.gitignore`, así que el
  `.env.local` (gitignored) del canal **sobrevive**; lo que se borra es cualquier untracked
  **no-ignorado**. No dejar artefactos valiosos untracked-no-ignored en un canal reciclable.
- **Ventana de grant ~7 h**: al acreditar un canal con una cred de grant corto, **reportar el
  expiry** al coordinador/orquestador en el momento de la acreditación — el recycle o el re-brief
  se planifican dentro de esa ventana, no se descubre el vencimiento por el muro 1.

**Un IDLE-CRÍTICO del watchdog JAMÁS se obedece a ciegas (verificación EN VIVO antes de reciclar):**

- El watchdog mide la barra de input, **no el estado real** del canal. ANTES de cualquier recycle
  gatillado por IDLE-CRÍTICO, comprobar EN VIVO cuatro señales: (a) `HEAD` + working-tree sin cambio
  entre dos lecturas; (b) sin proceso `flock`/`npm`/gate en vuelo; (c) sin bloque STOP-AUDIT ya
  emitido esperando relevo; (d) el pane NO está en un menú ni "thinking". Un canal en
  `ExitPlanMode`/mid-deliberación (se han visto 7-18 min legítimos) o esperando su turno en la cola
  FIFO del build-lock está **SANO** — reciclarlo destruye trabajo. Evidencia: en una misma jornada
  varias flotas recibieron IDLE-CRÍTICO en falso repetido; el recycle ciego habría tirado ~20
  planes/entregas en vuelo.
- **La causa-raíz conocida gana sobre la heurística**: si el idle es fleet-wide y tiene una causa
  SISTÉMICA ya en reparación (un muro de auth, el host saturado), **retener los recycles** y
  documentar esa razón en el reporte — no reciclar canal por canal contra un síntoma cuyo origen ya
  se está arreglando arriba.

## 4. Recycle suave

### PROC-09 — Recycle suave

Para un **follow-up trivial en el mismo carril**, conservando la sesión con su modelo bueno
(un relaunch caería al modelo default de la cuenta, quizá agotado):

```bash
bash scripts/dispatch.sh --soft <carril> <TAL-N>   # o: tco_recycle_carril <carril> --soft
```

Qué hace: `/clear` del contexto + repo reset a `origin/main` + limpieza de relay; **NO
relanza CLIs**. Requiere sesión viva con ambos panes y pane dev **idle** (jamás `/clear`
sobre un agente trabajando; si no está idle, el helper falla y se usa el hard).

Cuándo **NO** usarlo (→ recycle hard = dispatch normal):

- cambio de issue **grande** (el contexto residual contamina el follow-up),
- pane **contaminado** (residuos que `/clear` no limpia, diálogos colgados),
- **auditor muerto** (el `--soft` exige ambos panes vivos).

### Park sin trabajo (deja-sesión) — tercer escenario, distinto de los dos de arriba

Un **canal aparcado SIN trabajo siguiente** (orden vacía, invariante 12 de SKILL.md: "orden vacía
→ avisar al Orquestador") es un tercer escenario, ortogonal a los dos de arriba — el eje que los
distingue es **¿hay dispatch detrás?**:

| Escenario | ¿Dispatch detrás? | Qué pasa con la sesión tmux |
|---|---|---|
| Recycle hard (`tco_recycle_carril`, invariante 11) | Sí — re-despacho fresco inmediato | **Mata** sesión+procesos, repo a `origin/main` |
| Recycle suave (PROC-09, `--soft`) | Sí — follow-up trivial mismo carril | **Conserva** sesión y modelo |
| **Park sin trabajo (nuevo)** | **No — orden vacía** | **Conserva** la sesión tmux con dev **idle** |

**Por qué conservar y no matar:** un canal aparcado sin trabajo **CONSERVA la sesión tmux
levantada con dev idle** — un pane **SIN-PANE** (sesión muerta/contenedor caído) es
**indistinguible de un contenedor caído** para el supervisor de flota (`talent-coordination` ref
09 §Supervisor de flota), y matar la sesión por "estar libre" borra esa distinción exactamente
cuando no hay nada urgente que la fuerce. Caso real: SIN-PANE en ch46/ch41 confundido con
contenedor caído, 23-ago-2026.

**Cuidado con `tco_carril_libre`**: el helper que decide si un carril está "libre a reciclar"
considera NO-busy en ambos panes como libre. Un canal park-sin-trabajo (dev idle, sin dispatch
detrás) cae ahí por definición — **no es una señal para matarlo**: la orden vacía se resuelve
esperando al Orquestador, no reciclando duro un canal que no tiene destino de re-despacho.

## 5. Dev en loop

### PROC-10 — Desatascar un dev en loop

Caso real: un dev loopeó **19 rondas** sobre residuos de coherencia documental; reciclado y
re-despachado fresco dio **GO en 2 rondas**. A veces el fix es empezar de cero, no iterar.

Escalera (parar en el primer peldaño que funcione):

1. **Recycle + re-dispatch fresco** (misma issue, brief intacto).
2. Si falla en un **límite real de capacidad** (p. ej. fixtures complejos en un modelo
   débil): **subir de modelo** + dar un **TEMPLATE concreto** (ejemplo mínimo de
   fixture + call + assert que pueda imitar).
3. **Escalar la decisión al lead.**

**NO iterar indefinidamente**: varias rondas sin converger sobre el mismo residuo ya es
señal de loop, no de progreso.

### Contrato de rondas del fallback modelo-por-fase (TAL-2675) — SOLO el peldaño 5.ª-ronda→Opus vigente

Formaliza con un umbral concreto el peldaño 2 de la escalera de arriba ("subir de modelo") para la
política de coding en Sonnet vigente **Alcance ACOTADO al fallback 5.ª-ronda→Opus vigente únicamente — NO endurece ni
redefine el circuit-breaker de NO-GO repetido de `02-pipeline-y-gates.md`**: ese circuit-breaker
sigue siendo un criterio CUALITATIVO del coordinador (la observación "visto: 7 rondas" es histórica,
no un contador con acción automática) y el PARK que dispara queda EXACTAMENTE como estaba, sin
convertirse en política de umbral. Este contrato define, y solo esto, el punto MÁS TEMPRANO en el que
el coordinador sube el fix a Opus vigente

- **1 ronda** := un veredicto **NO-GO de CODE-gate** sobre un **commit nuevo** del **mismo eje/fix**
  ("stop-audit real = commit nuevo", `02-pipeline-y-gates.md` §3). NO cuentan: un plan-gate, un GO, ni
  un re-relay sin commit nuevo.
- **Contador por eje/fix.** Persiste mientras el eje no cambie; **reinicia a 0** cuando el code-gate da
  **GO** sobre ese eje, o cuando hay **re-scope autoritativo** (sesión fresca + brief que renombra
  explícitamente el scope, `02-pipeline-y-gates.md` §3 L236) — un eje nuevo arranca su propio contador.
- **5ª ronda NO-GO sobre el mismo eje (en Sonnet)** → el coordinador sube ESE fix a **`Opus vigente` `high`**
  (`model="$(tco_model_for_phase fallback)" && [ -n "$model" ] && tco_set_model "$carril" "$pane" "$model" || exit 1`, picker interactivo, coreografía de un solo diálogo de §6/§2). El contador de rondas **NO se reinicia**
  al subir de modelo (es escalada dentro del mismo eje, no un eje nuevo).
- Si aun en Opus vigente el eje sigue sin converger, el coordinador sigue aplicando su **criterio cualitativo**
  de circuit-breaker de `02-pipeline-y-gates.md` (PARK + cosechar root-cause + re-scope + escalar al
  Orquestador) — este contrato NO le añade un contador ni una acción automática; 5.ª-ronda→Opus vigente es un peldaño
  ANTERIOR y más temprano, no un reemplazo del juicio del coordinador sobre cuándo parquear.

**Death-spiral de blind-rework (variante a cazar)**: nudges al dev **sin findings concretos**
("revisa de nuevo", "mejora esto") producen no-ops cosméticos de ~6 líneas por ronda, el dev entra
en micro-iteración vacía y los **relays empiezan a timeoutear** (el pane siempre "ocupado" en nada).
Señal = diffs por ronda que no tocan el problema + relays con timeout. Salida: parar los nudges,
volver al loop adversarial (un finding VERBATIM del auditor por ronda — nunca "pase comprehensivo")
o recycle + re-dispatch fresco (peldaño 1).

### Build colgado — `TA_DRAFT_SKIP_BUILD=1` formal (PROC-10 §build)

Un `npm run build` que no avanza NO es necesariamente un loop: puede ser un proceso **colgado**
(hung) — el PID sigue vivo pero sin progreso de CPU. Diagnóstico fiable por CPU-time:

1. **Escape** para interrumpir al dev mientras el build corre (queda idle con el PID del build en bg).
2. **Leer `/proc/<pid>/stat`** dos veces con ~8 s de separación y extraer `utime`+`stime` (campos
   14-15, ticks de CPU usuario+kernel). Si **los ticks no avanzan** entre lecturas → build COLGADO
   (no CPU-bound, no solo lento). Si suben → esperar (progresa).
3. **Primera vez colgado**: matar el build (`kill <pid>`), reintentar una vez en frío.
4. **Segunda vez el MISMO build cuelga**: usar `TA_DRAFT_SKIP_BUILD=1` (escape formal de TAL-2820)
   para la entrega draft de este canal. El gate oficial de build sigue siendo `local-gates` en
   runners sellados — el skip solo traslada un posible fallo de build a un rebote tardío del
   Mergeador, nunca a un merge defectuoso. **Declarar el skip en la sección humana del HANDOFF**.

Esta mecánica de diagnóstico (utime/stime ×2) complementa el escape formal de TAL-2820 ya
documentado en CLAUDE.md regla 12 — aporta el criterio objetivo de "colgado vs lento" que
justifica usar el skip.

## 6. Effort residual y contexto degradado

El `xhigh` que sobrevive del plan (o de un resume) **ralentiza el coding** — visto: 6 min de
"Mulling" en pasos triviales. Re-fijar `high` al despachar código (Regla 0: la secuencia del GO de
plan APRUEBA primero y fija `high` DESPUÉS, con el dev ya en idle vía Escape — nunca con el menú de
ExitPlanMode abierto; secuencia completa en §Trampas más abajo y `02-pipeline-y-gates.md`).

`tco_set_effort` es **tri-estado**: rc 0 = confirmado; rc 1 = envío falló (fatal); rc 2 =
enviado **sin confirmación visual** dentro del deadline (`TCO_EFFORT_CONFIRM_MAX`, 24 s) →
el caller hace verificación **DIFERIDA** (`TCO_EFFORT_DEFER_WAIT`, 20 s; `dispatch.sh` la
ejecuta tras entregar el brief y **muere si también falla**). El rc 2 existe para no matar
un despacho válido por un banner lento bajo carga (falso negativo 3/3 del batch).

**Contexto > 600k tokens → degradación** (respuestas lentas, pérdida de hilo) → **sesión
fresca** (recycle hard + re-dispatch). No hay recuperación in-place.

### Trampas del effort-switch sobre ExitPlanMode

El diálogo de ExitPlanMode es **modal**: no acepta `/effort high` ni el picker de `/model` mientras
está abierto. La secuencia limpia para fijar el modelo-por-fase + `high` en el GO de plan:

1. **Aprobar** el plan (opción 1) → el dev entra en bypass y arranca a codear en el modelo/effort
   vigentes (si era Opus vigente/`xhigh`, el primer tramo corre caro — es el burst conocido).
2. **Escape** para interrumpir → el dev queda **INTERRUPTED/idle** (NO reanuda solo).
3. **[TAL-3619]** `model="$(tco_model_for_phase coding)" && [ -n "$model" ] && tco_set_model "$carril" "$pane" "$model" || exit 1` — internamente abre el picker
   (`/model` SIN argumento), localiza y envía el DÍGITO (`tco_model_picker_pick`), confirma **UN**
   `1` SOLO si aparece el diálogo ("Yes, switch…"/"full history gets re-read"), y **verifica el
   modelo activo por el PICKER** (marca de activo, `tco_model_is`) — nunca por el eco de un
   comando — **ANTES de continuar al paso 4**. rc 2 (sin confirmación visual) → verificación
   diferida (§ tri-estado arriba); rc 1 (envío/parseo falló) → escalar, NO seguir al effort con el
   modelo sin garantizar. Jamás invocar `/model <slug>` a mano con argumento inline: es un NO-OP
   silencioso (`Kept model as …`) que este helper corrige de raíz.
4. `/effort high` (`tco_set_effort`) → confirmar con **UN** `1` en SU PROPIO diálogo — es un diálogo
   **INDEPENDIENTE** del de `/model` en el paso 3, con su propia confirmación (un segundo `1`
   demasiado rápido cae como TEXTO literal en el composer; limpiar con `Escape`+`C-u`).
5. **Verificar por la línea "Set effort level to high"** (no por el badge, que no siempre renderiza
   en idle).
6. **Relevar el GO** (el relay reanuda al dev interrumpido, ya en Sonnet vigente + `high`).

**Orden fijo modelo → effort** (nunca al revés, nunca en un solo paso): son DOS diálogos modales
independientes, cada uno con su propia confirmación y su propia verificación — ejecutar el segundo
comando sin haber verificado el primero puede perder el `/model` o dejarlo como texto literal en el
composer del diálogo equivocado, dejando el canal en Opus vigente/`xhigh` o bloqueado a mitad de switch.

**Fallback 5ª ronda (§5 contrato de rondas)**: el disparo es el **5º veredicto NO-GO** sobre el mismo
eje (code-gate, no un GO de plan — aquí NO hay diálogo de ExitPlanMode que ignore input, así que los
pasos 1-2 de arriba, aprobar/Escape, no aplican). Orden estricto, para que el switch caiga SIEMPRE
sobre un pane idle y no sobre uno ya reanudado a trabajar:

1. El auditor emite el 5º veredicto NO-GO. El pane dev está **idle** en este momento — terminó su
   último commit y espera el veredicto; **el relay del feedback aún NO ha ocurrido**.
2. **CON el pane todavía idle**, el coordinador conmuta el modelo con
   `model="$(tco_model_for_phase fallback)" && [ -n "$model" ] && tco_set_model "$carril" "$pane" "$model" || exit 1` (picker interactivo — `/model` **SIN** argumento
   inline, mismo helper y mismo motivo que el paso 3 de la coreografía de arriba, dirigido a
   `Opus vigente` en vez de `Sonnet vigente`; **nunca** `/model` con argumento inline a mano
   (p. ej. `Opus vigente`) — es el NO-OP silencioso que TAL-3619 corrigió de raíz) → confirmar con **UN** `1` en
   su diálogo si aparece → **verificar el efecto REAL** con `tco_verify_model_effect` (AUTORIDAD
   en disco) o, como mínimo, por el PICKER (`tco_model_is`) — nunca por el eco de un comando. Los
   pasos 4-5 (switch y verificación de `/effort`) **NO aplican** — el effort se queda en
   `high` en ambos modelos, nada que cambiar ahí.
3. **SOLO ENTONCES**, con el modelo ya confirmado en Opus vigente, el coordinador releva al dev el feedback
   del NO-GO — este relay ES el nudge que reanuda el trabajo, así que **nunca antes** de completar el
   paso 2: relevar primero encolaría el switch de modelo (`tco_set_model` hacia `Opus vigente`) sobre
   un pane que ya volvió a estar BUSY, frustrando el fallback (el mismo riesgo de encolado que la coreografía del GO evita con el
   Escape). El dev reanuda el fix ya en Opus vigente

**Nota de alcance — `dispatch.sh` NO implementa esta secuencia (follow-up de código, fuera de este
encargo docs-only)**: la secuencia manual de arriba (aprobar → Escape → `/model` → `/effort`) es la
doctrina VIGENTE que el coordinador ejecuta a mano en el GO de plan. El comentario interno de
`dispatch.sh` (línea ~185, "coding=high... tras el GO de plan y ANTES de aprobar") sigue describiendo
la redacción vieja — `dispatch.sh` es un `.sh` y TAL-2675 es **docs-only**, así que no se toca aquí.
Alinear ese comentario (y cualquier automatización futura del switch) es un **follow-up de código
conocido**, a crear como issue Linear aparte; este doc NO afirma que `dispatch.sh` ya implemente la
secuencia — solo la documenta como el procedimiento manual que el coordinador sigue hoy.

**No existe atajo sin burst**: el menú de ExitPlanMode IGNORA cualquier `/model`/`/effort` tecleado
mientras está abierto — no hay forma de fijar el modelo/effort del canal "antes de aprobar" dentro
del modal. La secuencia de arriba (aprobar → Escape → switch) es la ÚNICA vía; el pequeño burst en
Opus vigente/`xhigh` al inicio del coding se documenta como aceptable, no como algo evitable.

## 7. Rotar la cuenta de la flota

El reinicio lee la fase persistida por panel en `~/.claude/tf-phase-<pane>.json`; en canales
anteriores recupera la familia desde `.model` de `~/.claude/settings.json`. El launcher y
el picker confirmado mantienen ese estado. Sin fuente válida falla antes de matar el agente.
`TC_CLAUDE_PHASE` permite anular explícitamente; conservarla también al usar `sudo`.


Cuando una cuenta de Claude o Codex da **rate-limit** o se agota (§1: panel colgado sin producir),
la salida no es reciclar carril por carril — es **rotar la cuenta de toda la flota** a una cuenta
nueva. La mecánica de credenciales es de `talent-channels` (los scripts de refresh, ref 05); el
coordinador **orquesta** la rotación y **re-briefea** los carriles con trabajo en vuelo.

### PROC-19 — Rotar la cuenta de la flota (rate-limit / cuenta agotada)

1. **El lead acredita la cuenta nueva en el HOST** (checkpoint humano): `claude login` (o
   `codex login`) en el host → queda en `~/.claude/.credentials.json` / `~/.codex/auth.json`. El
   coordinador NO tiene la cuenta; solo la propaga una vez acreditada.
2. **Identificar los carriles a rotar**: los que dan rate-limit / cuelgan (§1). `all` si la cuenta
   agotada alimentaba a toda la flota.
3. **Propagar + reciclar** (script de `talent-channels`, idempotente):

   ```bash
   sudo bash <ruta-talent-channels>/scripts/refresh-claude-auth.sh <canal|all> --restart
   ```

   Sin `--restart` solo copia + verifica el **fingerprint md5** (no destructivo); con `--restart`
   además mata el agente **por PID host-side** (`bash -c`, no `su -c` — evita el exit 137 que aborta
   el bucle) y relanza el alias. El script verifica el md5 en ambos lados: una propagación truncada
   deja el carril corrupto y colgado, y el check lo caza. **[TAL-5172] EXCLUIR runners del push**:
   los canales `runner` (85-88, perfil sellado CERO-credencial de `local-gates` — invariante
   fail-closed de `talent-channels` §Perfil por canal) NUNCA reciben credencial de agente; un
   `--restart` con alcance `all` sin excluirlos violaría ese perfil. Acotar el target a
   `TCO_DEV_CARRILES`/`TCO_AUDIT_CARRILES` (que ya no incluyen los runners) en vez de `all` cuando
   la flota tenga runners desplegados — **CÓMO**, no solo qué: `refresh-claude-auth.sh [canal]`
   toma UN SOLO nombre de canal por invocación (nunca una lista), y ese argumento lo usa TAL CUAL,
   sin resolverlo — así que acotar exige un BUCLE que llame al script una vez por carril,
   resolviendo cada carril al nombre COMPLETO del contenedor con `tc_channel_name()`
   (`talent-channels/scripts/00-config.sh:214`, `PREFIX+MACHINE_NUM+carril`) ANTES de invocarlo:

   ```bash
   . <ruta-talent-channels>/scripts/00-config.sh   # carga PREFIX, MACHINE_NUM, tc_channel_name()
   first=1
   fallos=""   # [TAL-5172 v10, defecto propio corregido] canal:rc por cada fallo — nunca un contador
   for carril in $TCO_DEV_CARRILES $TCO_AUDIT_CARRILES; do
     canal="$(tc_channel_name "$carril")"
     if [ "$first" -eq 1 ]; then
       first=0
     else
       sleep "$(( 30 + RANDOM % 31 ))"   # ver nota de fan-out debajo
     fi
     sudo bash <ruta-talent-channels>/scripts/refresh-claude-auth.sh "$canal" --restart && rc=0 || rc=$?
     [ "$rc" -eq 0 ] || fallos="${fallos}${canal}:rc=${rc}"$'\n'
   done
   if [ -n "$fallos" ]; then
     printf 'ROTACION CON FALLOS:\n%s' "$fallos" >&2
   else
     echo "ROTACION OK: 0 fallos"
   fi
   [ -z "$fallos" ]
   ```

   **Por qué `&& rc=0 || rc=$?` en la MISMA línea** (no `sudo ...; rc=$?` en dos líneas): la misma
   clase de fallo que este skill lleva varias rondas cerrando en otros ficheros — un `rc` legítimo
   no-cero (aquí: un canal que falla la rotación) mataría el bucle bajo `set -e` ANTES de que la
   línea siguiente leyera `$?`, y el resto de la flota quedaría rotada a medias sin que nadie se
   enterase hasta que alguien lo reconciliara a mano horas después. El defecto anterior (bucle sin
   captura de rc, TAL-5172, rebote de C2 v10) era exactamente ese: `sudo ... --restart` desnudo,
   sin `||`, sin acumular fallos, sin resumen. La última línea (`[ -z "$fallos" ]`) deja el rc del
   bloque reflejando si hubo algún fallo, para quien lo invoque desde un script en vez de a mano.

   **Nota de fan-out (por qué el `sleep` explícito)**: el escalonado 30-60s de
   `TC_FANOUT_STAGGER_SEC` que trae el script es INTERNO a su propio bucle sobre `targets[]` — con
   `arg=all` reparte la espera entre los N canales de ESA invocación. Cada llamada de ESTE bucle
   pasa un ÚNICO canal, así que dentro del script siempre es «el primero» (`first=1`, cero espera
   interna): llamarlo N veces seguidas sin más SÍ hace burst, exactamente lo que el escalonado
   existe para evitar. El `sleep` de arriba, ENTRE iteraciones del bucle (nunca antes de la
   primera), es lo que preserva la invariante «nunca en burst» cuando el fan-out se hace acotado
   en vez de con `all`.
4. **El repo se preserva**: el restart resetea el **contexto de conversación** del agente, NO el
   working tree ni los commits. Por eso:
   - Carriles **idle / staged** (sin trabajo en vuelo): no necesitan nada — se briefan al despachar.
   - Carriles **con trabajo en vuelo**: **RE-BRIEFEAR con estado de reanudación** — el punto exacto
     (rama, commit/PR, qué falta), no el brief inicial. El agente reanuda sobre el repo intacto.
5. **Verificar 0 stalls**: tras la rotación, los carriles deben estar procesando con la cuenta nueva
   (fingerprint nuevo confirmado por el script). Un carril que sigue colgado tras el restart →
   revisar a mano (¿el alias relanzó en el pane correcto? ¿la cuenta nueva también topó?).

> El re-briefeo de reanudación es responsabilidad del coordinador: el script deja el carril con la
> cuenta nueva y el repo intacto, pero sin memoria de qué estaba haciendo. Tratar cada carril en
> vuelo como un dispatch de continuación, no de arranque.

### 7b. Los 4 muros de cuenta — marcador → recovery (TAL-2294)

No todo carril parado es lo mismo. Hay **cuatro muros** distintos, cada uno con un **marcador**
propio en el pane y un **recovery DISTINTO** (doctrina canónica de los 4 muros:
`talent-channels/references/05` §Muros de cuenta; esta tabla añade el detalle operativo del
coordinador). Confundirlos cuesta caro: esperar un muro de auth
no lo cura; escalar un muro de 5h gasta otra cuenta para nada. **Leer el marcador antes de actuar.**

| Muro | Marcador en el pane | Qué es | Recovery | NO hacer |
|---|---|---|---|---|
| **1 · Auth caída** | `Not logged in` (Claude) · `refresh token revoked` / `stream error` (Codex) | La credencial murió. **[TAL-5172] El mecanismo VIGENTE de propagación por proveedor (Claude/Codex) vive ÚNICAMENTE en `talent-channels/references/05` §asimetría — este skill NO lo duplica a propósito**: doctrina que vive en dos sitios envejece en silencio en el que no se toca cuando el otro cambia. Antes de operar auth caída, leer esa referencia como fuente única; lo que sigue aquí es solo el helper DEL COORDINADOR (interfaz, no el contrato de mecanismo). | **[P2] Helpers del coordinador** que orquestan la propagación por proveedor (contrato/mecanismo vigente: `talent-channels/references/05` §asimetría): **Claude → `tco_reauth_carril <NN> [donor]`** — verificación FUNCIONAL del donante (request real one-shot, NO `login status`) → propaga por `mv` atómico **por canal** (cada destino individual es atómico; el fan-out a N canales NO es transaccional — si la propagación falla a mitad, la flota queda DIVERGENTE y se reconcilia a mano: el journal/rollback/reanudación es del flujo **Codex**, NO de esta propagación por fan-out) → nudge **"continuemos"** (SIN relaunch; orden estricto propagar→nudge). **Codex → `tco_reauth_carril_codex <NN> [donor]`** — INVOCA `auth-move.sh move` (MOVE un-login-un-lugar; hereda freeze/journal/commit/locks de P1, NUNCA fan-out) y tras COMMIT relanza el TUI (skip update + trust + recarga rol). | Esperar (no es un muro de límites); para **Codex**, `refresh-codex-auth.sh all` (fan-out re-arma la cascada). |
| **2 · Cap de 5 horas** | `usage limit · resets 3pm` (hora, mismo día) | Ventana rodante de 5h agotada. | **Esperar** al reset + **"continuemos"**. Aprovechar: los audits de **Codex sobreviven** el cap de Claude → durante el muro, precorrer gates y **RETENER** los relevos a devs hasta que pase. | Escalar ni cambiar de cuenta (gasta otra sin necesidad). |
| **3 · Cap semanal** | `weekly limit · resets Saturday` (día, no hora) | Cuota de 7 días agotada. | **PARK** del canal (el trabajo local — commits, rama — queda a salvo) o **escalar a otra cuenta** vía pozos. **[TAL-5172] La política de rotación/selección de pozos (qué cuenta usar primero, cuándo cambiar, límites por cuenta) vive ÚNICAMENTE en `talent-orchestrator/references/10-cuentas-y-pozos.md` — este skill NO la duplica a propósito**: es doctrina del Orquestador, no de esta estación; copiarla aquí crearía una segunda fuente que envejece en silencio cuando la primera cambie. Leer esa referencia como fuente única antes de decidir una rotación. | Esperar (son días), nudgear `continuemos` (no revive nada), re-autenticar la misma cuenta, ni decidir la rotación sin consultar la fuente única de política. Aviso: N canales sobre 1 cuenta agotan el semanal aunque cada uno respete su 5h. |
| **4 · 429 transitorio** | `429` / `temporarily limiting` | Sobrecarga transitoria: demasiadas sesiones simultáneas sobre la cuenta. | **RESTART** de la sesión (fuerza releer credencial/estado del disco) + re-despachar **escalonado** (§7c). | Re-despachar N canales de golpe sobre la misma cuenta (re-dispara el 429 y deja devs idle). |

**Refinamiento del muro 1 — sesión YA atascada logged-out exige RESTART (T1)**: el orden
propagar→nudge del recovery aplica a sesiones aún vivas. Una sesión que **ya quedó** logged-out
**no re-lee** la credencial fresca — `continuemos` no la revive; hay que **relanzar**. La
status-bar refleja el DISCO, no la RAM: distinguir por **actividad**, no por status-bar
(doctrina completa en `talent-channels/references/05` §Sesión atascada). **[TAL-5172]
Relanzamiento = `claude --resume <session-uuid>`, NO kill+re-brief desde cero**: el `--resume`
reata la MISMA sesión (preserva el contexto completo del encargo en vuelo — plan, código,
decisiones tomadas) sobre la credencial recién propagada, evitando el coste de re-explicar el
encargo al agente; usar el `uuid` de sesión ya conocido por el coordinador (mismo patrón que
`tco_verify_model_effect` lee del `.jsonl` persistido). Con **varias sesiones sobre el MISMO
cwd** (p.ej. Torre), usar SIEMPRE `--resume <uuid>` explícito — `--continue`/`--resume` sin uuid
puede resumir la sesión AJENA (T11, `talent-channels/references/07`). Si no hay `uuid` de sesión
capturado (sesión nunca corrió con el harness que lo persiste), cae al fallback de siempre: sesión
fresca + re-brief con el estado exacto de reanudación (PROC-19 paso 4).

**[P2] Invariante del MOVE de Codex (no restaurar el donante en post-commit)**: `tco_reauth_carril_codex`
interpreta el rc de `auth-move.sh move` — **rc 0** = commit + salud OK → relaunch; **rc 4** = health
POST-commit falló pero la credencial YA vive en el destino (es el propietario) → **reparar EN destino**
con `auth-move.sh resume <tx>`, **JAMÁS restaurar al donante** (un timeout no prueba que el servidor no
consumiera el refresh); **fallo PRE-commit** = `auth-move` ya reconcilió (donante intacto) → el wrapper
escala sin restaurar ni relanzar. El rollback al donante SOLO ocurre en fallo pre-commit, y lo hace
`auth-move` internamente, nunca el wrapper.

**[P2] Preparación del MOVE cuando la flota Codex viene de una cascada de revocación**: el síntoma de
revocación de Codex es análogo al de Claude, pero la recuperación NO — es MOVE un-login-un-lugar (lo
de arriba), nunca fan-out/COPY. Tres pasos ANTES de mover, aprendidos con 16 auditores revocados en
un día:

1. **`npm install -g @openai/codex@<versión-fijada-en-la-imagen-golden>` como ROOT en TODA la flota
   primero** — versión **APROBADA y trazable**, nunca el tag `latest` mutable: un global-install con
   privilegios root de una dependencia mutable es riesgo de cadena de suministro; la versión sale del
   lock de la imagen golden, no del registro en vivo. El auto-update a mitad de sesión revienta con el
   crash `243`; fijar la versión global de raíz lo mata antes de intentar el MOVE.
2. **Confirmar el donante VIVO, no solo "logueado"**: `codex exec 'PONG'` debe responder de verdad
   (o comparar el `last_refresh` del `id_token` frente al resto) — mover DESDE un donante ya revocado
   propaga la muerte. El host más "viejo" en horas de sesión suele ser el único vivo tras la cascada.
3. **Relanzar los destinos con rol ESCALONADO 30-60 s** entre canales (no en ráfaga): el priming del
   rol en paralelo sobre la cuenta recién movida re-dispara el estrangulamiento.

**Gotcha transversal — días de semana SIEMPRE con `date`**: al leer un `resets Saturday 11am` (u
otro día), convertir SIEMPRE con `TZ=America/Mexico_City date -d '...'` y **verificar la conversión
ANTES** de declarar conflicto entre fuentes o decidir una rotación. Los errores de día/zona ya
causaron falsos conflictos (memoria del lead). El único muro que justifica abrir un pozo es el
semanal; el de 5h se espera, el de auth se propaga (+restart si la sesión ya cayó) y el 429 se
reabsorbe con restart + escalonado.

### 7c. Despacho escalonado 2-en-2 bajo cuenta cargada (T8)

Despachar **N canales simultáneos** sobre una cuenta ya cargada dispara el muro 4 (`429` /
`temporarily limiting`) y deja a los devs **idle en cadena** — se pierde más throughput del que
el burst pretendía ganar. Doctrina:

1. Con señales de cuenta cargada (un 429 reciente, muchas sesiones activas de la misma cuenta),
   despachar **de 2 en 2** con **~15 s** entre parejas.
2. **Verificar por conducta** (el dev arrancó a trabajar de verdad: output nuevo, no solo pane
   abierto — taxonomía de señales en `talent-channels/references/07` §Verificar por conducta)
   antes de soltar la siguiente pareja.
3. Si aun así aparece 429: parar el despacho, restart del canal afectado y espaciar más.

Aplica igual al re-despacho masivo tras una rotación de cuenta (PROC-19 paso 5) — la rotación
recién hecha es justo el momento de mayor carga simultánea.

## 8. Protocolo 529 (error server-side)

Un **529 de Anthropic** ("server-side, not your usage limit") NO es rate-limit de cuenta ni
modelo agotado: es un error transitorio del proveedor. Deja el pane dev parado **en silencio**.

- **No nudgear inmediato ni reiniciar**: esperar **~5 min** y relevar **"continuemos"** (el
  dev reanuda sobre el repo intacto). No re-fijar modelo/effort (no es ese el problema).
- **El pane del auditor (codex, `.1`) es inmune a los 529 de Anthropic** → las auditorías no
  se atascan por esto mientras el dev espera; aprovechar para adelantar gates de auditoría de
  otros canales.
- Distinguir del modelo agotado (§1, silencio SIN error) y del rate-limit de cuenta (§7,
  banner explícito): el 529 se identifica por el mensaje de error server-side en el pane.

## 9. Compact-60 (protocolo del lead, en cascada)

> **Doctrina canónica en `talent-context`** (umbral 60 %, checkpoint limpio, fichero de regreso,
> paso-0, ctx-watcher, modos standalone/flota). Aquí queda solo la aplicación EN CASCADA del
> coordinador sobre sus panes; no duplicar el detalle.

Protocolo del lead (2026-07-08): al llegar el contexto de un pane (dev o auditor) al **60 %**
(supersede el umbral >70 % previo, más conservador para evitar gates a medias por contexto/RL), y
solo en su **checkpoint limpio**:

1. El **coordinador** (supervisor de sus panes) exige al pane el **fichero de regreso** (estado
   exacto, en-vuelo, próximos pasos, IDs/refs) escrito FUERA del pane y VERIFICADO (nunca "copiar
   fuera→`/compact`→pegar" a secas — ese resumen omite el gate).
2. `/compact` en el pane.
3. Al volver, **paso-0 como primer acto**, verificado por el coordinador, nunca autoevaluado por el
   pane recién compactado — retoma del fichero, nunca de un handoff "pegado" en el composer.

En **cascada**: el coordinador vigila el contexto de sus panes; a su vez, la Torre (o el lead
en modo manual) vigila el del coordinador. **Medir el % por el `.jsonl` / la barra `ctx:` del
pane**, no por `/context`. Añadir el umbral 60 % a la vigilancia por canal (complementa la
verificación de identidad y la purga de TaskList stale del post-resume — runbook Torre).

**Los shells en background SOBREVIVEN al `/compact` (T9)**: un gate o watcher lanzado en bg por la
sesión sigue corriendo durante y después del compact — no re-lanzarlo "porque se perdió". Al volver
del compact, **re-pollear** los bg pendientes (estado/resultado) como primer paso del regreso.

Registro de modelos: `~/.config/talent-channel-operation/modelos.conf` del usuario del rol; CEO y plan/fallback usan Opus vigente, los demás roles y salud Sonnet vigente. Resolver tras acreditar Claude con `talent-channel-operation/scripts/resolver-modelos.sh`.

La versión visible se deriva con `tco_modelo_version_visible`: componentes numéricos de uno o dos
dígitos contiguos después de la familia, hasta el primer sufijo. El ID completo se conserva.
Selector, barra de estado y doctor comparan esa versión exacta; los números de la descripción
no completan una versión. El auditor de otro proveedor conserva sus argumentos configurados.

`actualizar-modelos.sh` informa la versión del CLI instalada y la que resolvió el registro.
La actualización del propio CLI es responsabilidad de su actualizador; esta orden no consulta
catálogos ni instala el CLI.
