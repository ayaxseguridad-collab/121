---
name: talent-context
description: >
  Higiene de contexto autónoma para sesiones de agente de larga duración: auto-compact al 60 % de
  contexto en el siguiente checkpoint limpio, con fichero de regreso escrito ANTES de compactar,
  paso-0 de reanudación y (bajo tmux) un ctx-watcher del propio pane. Modo STANDALONE (una sesión
  sola, cualquier repo, cero deps) y FLOTA (fábricas multi-agente con backup jerárquico
  re-inyectable). Repo-agnóstico, token-only, sin MCP.
  Trigger keywords (ES/EN): "contexto lleno", "se me llena el contexto", "ventana de contexto",
  "higiene de contexto", "context hygiene", "context window full", "running out of context",
  "compact", "/compact", "auto-compact", "compact-60", "compactar sesión", "texto de regreso",
  "fichero de regreso", "handoff de regreso", "relevo de sesión", "session handoff", "checkpoint
  limpio", "clean checkpoint", "ctx-watcher", "ctx: NN%", "paso-0", "step-0", "backup jerárquico",
  "re-inyectar puntero", "watchdog", "sesión de larga duración", "compactar contexto",
  "session relay", "relevo limpio".
---

# Talent Context — Higiene de contexto autónoma (compact-60 + relevo + backup)

## Quick Orientation

| Propiedad | Valor |
|---|---|
| Qué es | Doctrina + recetas para que un agente de larga duración **no pierda estado** al llenarse su ventana de contexto |
| Regla central | **Compact-60**: al cruzar el **60 %** de contexto, compactar en el **siguiente checkpoint limpio** (nunca mid-fix) |
| Invariante | **JAMÁS `/compact` sin el fichero de regreso YA escrito FUERA de la sesión** — el auto-compact del CLI captura de forma imperfecta |
| Dos modos | **STANDALONE** (default, cualquier repo, cero deps) · **FLOTA** (extensión: jerarquía de backup + flock) |
| Origen | Protocolo del lead **2026-07-08** (supersede el >70 % previo). Validado: **7/7 relevos limpios** en torres + 1 rama-backup end-to-end (M4), 2026-07-17. Corte 2026-09-01: 4 duplicados de sesión en 1h por `--continue` en torres del HOST (M2 muerto) — cerrado por TAL-5173 (ver §Cross-Skill Integration y ref 02 §5) |
| Repo/tool | **Repo-agnóstico** · token-only, **NO MCP** · el ctx-watcher requiere **tmux** (sin tmux degrada, ver ref 04) |
| Ámbito | La **doctrina** (umbral, checkpoint limpio, regreso, paso-0) es tool-agnóstica: cubre CUALQUIER sesión de agente de larga duración, dev o auditor, del CLI que sea. Lo NO validado es el **parseo** de `scripts/lib.sh` contra la UI de un CLI distinto al aquí descrito — ver "Fuera de alcance" |
| Fuera de alcance | Runners sellados (sin sesión de agente) · parseo del ctx-watcher para el formato de UI de otro CLI no validado |

**Por qué existe:** la doctrina vivía dispersa y **duplicada** (prosa en varios skills, scripts de
torre, reglas repetidas) con al menos una contradicción de umbral. Este skill es la **fuente de
verdad**; el resto la referencia en vez de re-explicarla.

## Reference Files Table

| Topic | Reference File | When to Read |
|---|---|---|
| Umbral 60 %, por qué 60 y no 70+, definición de "checkpoint limpio" por rol | `references/01-doctrina-y-checkpoint-limpio.md` | Antes de decidir CUÁNDO compactar |
| Los 3 pasos del relevo, plantilla del fichero de regreso, envío scriptado (no automático) del `/compact` bajo tmux | `references/02-protocolo-de-relevo.md` | Al ejecutar un compact-con-relevo |
| Paso-0 canónico de reanudación (loops, identidad, purga de TaskList) | `references/03-paso-0-post-relevo.md` | Como PRIMER acto tras volver del compact |
| ctx-watcher (5º monitor): capture-pane del propio pane, parseo `ctx:`, tmux vs no-tmux | `references/04-ctx-watcher.md` | Al montar la vigilancia automática del contexto |
| Modo FLOTA: jerarquía de backup, flock como bus, puntero re-inyectable | `references/05-modo-flota.md` | Solo en fábricas multi-agente |
| Ley actor-degradado: cuándo DESCARTAR (autoridad fabricada/corrupta) vs COMPACTAR (relevo sano), 5 pasos | `references/06-ley-actor-degradado.md` | Ante indicios de que un actor fabricó/corrompió autoridad |

## Quick Start (STANDALONE — una sesión sola)

Cuando notes (o el ctx-watcher avise) que cruzas el **60 %** de contexto, en tu **siguiente
checkpoint limpio** (idle, sin edición a medias, sin menú abierto):

```bash
# 1) ESCRIBE el fichero de regreso FUERA del repo (temporal 0600 + rename atómico — nunca un
#    regreso truncado a medio escribir) y VERIFÍCALO (nunca committeado). Contenido autocontenido:
#    tarea inmediata al volver · estado en-vuelo · próximos pasos · IDs/refs (rama, PR, issue, sha)
#    · loops armados (id + propósito) · paso-0 embebido.
REGRESO="$HOME/regreso.md"
TMP="$(mktemp "${REGRESO}.XXXXXX")" || { echo "FALLO al crear temporal — NO compactar"; exit 1; }
if ! cat > "$TMP" <<'EOF'
# Regreso — <tarea>
TAREA INMEDIATA AL VOLVER: <una, explícita>
Estado en-vuelo: <...>
Próximos pasos: <...>
IDs/refs: rama <...> · PR <...> · issue <...> · sha <...>
Loops armados (re-armar los muertos): <id: propósito> ...
PASO-0: (1) verifica loops (adopta vivos, re-arma muertos) (2) relee fuentes de estado del repo (3) retoma de este fichero
REGRESO-FIN
EOF
then
  echo "FALLO al escribir el temporal — NO compactar"; rm -f "$TMP"; exit 1
fi
# marcador ANTES del rename (no basta "no vacío": un cat truncado a mitad también deja algo no-vacío)
tail -1 "$TMP" | grep -qF 'REGRESO-FIN' || { echo "FALLO — temporal truncado (sin marcador) — NO compactar"; rm -f "$TMP"; exit 1; }
if ! mv -f "$TMP" "$REGRESO"; then
  echo "FALLO al mover a destino ('$REGRESO' previo SIN TOCAR; temporal en $TMP) — NO compactar"; exit 1
fi
tail -1 "$REGRESO" | grep -qF 'REGRESO-FIN' && echo "regreso OK ($(wc -l < "$REGRESO") líneas)" \
  || { echo "FALLO — regreso no verificado tras mv — NO compactar"; exit 1; }   # verifica ANTES de seguir

# 2) COMPACTA. El ctx-watcher SOLO avisa — NUNCA auto-encola el /compact (ref 04): ejecuta
#    /compact en el prompt del CLI TÚ MISMO, o vía envío scriptado bajo tmux (ref 02 §5),
#    SOLO en checkpoint limpio, SIN menú abierto.

# 3) Al volver: PRIMER acto = paso-0 (ref 03). Relee el fichero y retoma EXACTAMENTE.
```

Sin tmux, el protocolo **degrada** a "fichero de regreso listo + pedir el `/compact` al humano en el
checkpoint" — que ya es el 80 % del valor: **nunca compactar sin un regreso escrito** (ref 04).

## Essential Patterns

**(a) Decisión: cuándo compactar** (el % se lee de la barra `ctx:`, no de `/context`):

```text
ctx% < 60 ──────────────► seguir trabajando
ctx% ≥ 60 ─┬─ ¿checkpoint limpio? ─ no ─► terminar el paso limpio primero (NUNCA mid-fix)
           └──────────────────────  sí ─► escribir regreso ─► verificar Write ─► /compact ─► paso-0
ctx% ILEGIBLE ─────────► UNKNOWN fail-closed: inspección manual, jamás asumir 0 ni 100
```

**(b) Los 3 pasos del relevo** (invariante: nada se encola antes de tener el regreso escrito):

```text
① escribir regreso FUERA + verificar   ②  /compact           ③ paso-0 (PRIMER acto al volver)
   (estado autocontenido)          ──►  (checkpoint limpio) ──►  (retoma del fichero, ref 03)
   ─ jamás ② sin ① ─                          si el puntero ("lee <ruta> y retoma") se pierde en la
                                               cola post-compact, el nivel superior lo re-inyecta —
                                               backup, no un paso previo al paso-0 (ref 05 §3)
```

**(c) Jerarquía de backup** (el puntero NO lleva estado → perderlo es fallo benigno, se re-inyecta):

```text
STANDALONE:   sesión ──(regreso escrito)──► [ humano opcional re-inyecta el puntero ]
FLOTA:        canal ◄─ coordinador ◄─ CEO ◄─ lead     (cada nivel verifica el paso-0 del inferior;
              la verificación NUNCA se delega al recién compactado)
```

**(d) "Checkpoint limpio" por rol** (nunca compactar en el estado de la derecha):

```text
estación de merge   limpio: gate lanzado + cosecha lejana     sucio: mid-merge / aplicando migración
coordinador          limpio: entre despachos                   sucio: mid-despacho
canal dev            limpio: tras commit / al entregar a audit  sucio: mid-fix / mid-edición
CUALQUIERA           siempre sucio: menú modal abierto (ExitPlanMode), /compact a medio menú
```

**(e)** Decisión: descartar (actor degradado) vs compactar (relevo sano) — eje ORTOGONAL a (a):
compact-60 es para actores **sanos** (llenos de contexto); un actor con **autoridad
fabricada/corrompida** (cita un ACK/verificación/veredicto que nunca ocurrió) se **DESCARTA**
(contener daño → banco verificado desde fuentes externas → kill → alta fresca con brief de reglas
duras → verificar ACK con comandos PROPIOS), NUNCA se compacta — compactar perpetuaría la
autoridad fabricada en el resumen. Orden del lead 23-ago-2026. Detalle completo:
`references/06-ley-actor-degradado.md`.

## Critical Gotchas

1. **Auto-compact "salvaje" del CLI** → El CLI puede auto-compactar por su cuenta a mitad de
   cualquier cosa y **mata la coreografía**. Mitígalo compactando TÚ en checkpoint limpio ANTES de
   llegar al límite duro, con el regreso ya escrito (F1 2026-07-14).
2. **La cola de mensajes post-compact es PROBABILÍSTICA** → Un mensaje encolado antes/durante el
   compact puede **perderse** (caso M4: puntero perdido) o sobrevivir (M3/M2/C1/C2/C3/C6). No
   confíes en que el puntero llegue solo: en flota, el nivel superior lo **re-inyecta** (ref 05).
3. **`/compact`, `/model` y relays con MENÚ ABIERTO están PROHIBIDOS** → El diálogo de ExitPlanMode
   (y similares) es **modal**: un `/compact` o un texto tecleado con el menú arriba se **traga o
   aprueba** algo no deseado. Cierra el menú (**Escape**) antes de cualquier acción.
4. **La vista de tareas puede tapar el prompt post-compact** → Tras el compact el prompt puede
   quedar oculto por un overlay; **Escape** lo restaura antes de pegar el puntero.
5. **El fichero de regreso se escribe ANTES de encolar nada y se VERIFICA el Write** → Escribe a
   un **temporal + rename atómico, GATEANDO el exit code de `cat` Y de `mv`** (un `cat >` directo
   sin gate deja un truncado-NO-vacío que `test -s` no detecta; y si `mv` falla con un regreso
   PREVIO ya en destino, `test -s` sobre el destino validaría ese fichero VIEJO como si fuera el
   nuevo). Marcador final validado ANTES del rename, no solo "no vacío". Invariante duro:
   **jamás `/compact` sin regreso verificado**.
6. **Ghost-text ≠ cola real** → Texto en el input prefijado por dim (`^[[2m`, autocompletado del
   CLI) **no** es un mensaje encolado (no se ejecuta, desaparece al teclear). La cola real se
   distingue por "Press up to edit queued messages" en brillo pleno. Captura con `capture-pane -e`
   ANTES de reaccionar; **no "neutralices" lo que es ghost** (ver `scripts/lib.sh`).
7. **Los shells en background SOBREVIVEN al `/compact`; los wakeups/watchers NO** → Un gate o
   proceso lanzado en bg sigue corriendo tras el compact → **re-pollea**, no lo re-lances (T9).
   Pero los wakeups/monitores programados y **la MEMORIA de qué loops tenías armados se comprimen**
   aunque el proceso viva → por eso el regreso lista los loops (id + propósito) y el paso-0 los
   re-arma.
8. **Medir el % por la barra `ctx:`, no por `/context`** → `/context` gasta un turno y su valor no
   es el que dispara la doctrina. La barra de estado es la fuente; sin `ctx:` legible →
   **UNKNOWN fail-closed** (jamás asumir 0 ni 100).
9. **La verificación del paso-0 NUNCA se delega al recién compactado** → El agente que acaba de
   compactar es el **menos fiable** para autoevaluar si retomó bien. En flota lo verifica el nivel
   superior; en standalone, un checklist explícito (ref 03), no "me siento bien".
10. **60 %, no 70 % ni pánico al 43 %** → Los agentes tienden a auto-diagnosticarse "crítico"
    demasiado pronto (~43 %) y hay margen real; pero esperar a >70 % dejó gates a medias por
    contexto/RL. El umbral es **60 %**: ni antes por pánico, ni después por optimismo.
11. **Paste-block requiere Enter extra** → Al pegar el puntero de regreso como bloque, el submit
    puede necesitar un Enter adicional; verifica el eco (que el texto llegó) antes de dar por hecho
    el envío — un submit a ciegas sobre pane ocupado se **encola** y duplica.
12. **El fichero de regreso vive FUERA del repo y NUNCA se committea** → `~/regreso.md`, scratchpad
    de sesión, o (flota) el escrow 0600 fuera del árbol. Contiene estado de trabajo, no artefacto;
    committearlo es ruido y fuga.
13. **`ScheduleWakeup` probablemente cierra el turno — OBSERVACIÓN NO VERIFICADA, no doctrina
    sellada** → 3 incidentes narrados el 1-sep sugieren que el texto escrito DESPUÉS de programar un
    wakeup no llega a salir. A diferencia de los gotchas 6 y 7 (ghost-text, shells bg — comprobados
    en producción), este NO tiene contrato de CLI ni fixture que lo confirme, solo relato de
    incidente. Precaución mientras tanto: escribe el texto de cierre ANTES de `ScheduleWakeup`,
    nunca después. Si alguien lo reproduce con evidencia citable, se sella; hasta entonces, marcado
    no verificado.
14. **La barra `ctx:` solo existe si hay una `statusLine`, y el renderer debe ser el clásico** → Claude Code
    no pinta `ctx: NN%` por sí solo: sin una `statusLine` ningún pane lo emite y `tc_ctx_pct` devuelve
    UNKNOWN (sensor ciego, aunque los fixtures de los tests —que SÍ llevan la barra— pasen en verde). Y en
    pantalla alternada (`tui` fullscreen) el pane no tiene scrollback: ni el PLAN ni el handoff se pueden
    capturar. **Instalación única**: `scripts/install-statusline.sh` copia `assets/statusline-ctx.sh`
    (salida `[modelo] ctx: NN%`; sin dato → `ctx: N/A`, nunca un valor inventado) a `~/.claude/` y fusiona
    con `jq` `.tui="default"` + `.statusLine` (deja `settings.json.bak-<UTC>`; idempotente). rc: 0 ok · 1
    uso/entorno · 2 `--check`/`--check-ctx` con diferencia · 3 `statusLine` ajena sin `--force` (no se pisa;
    `--check-ctx` dice si esa barra emite `ctx:`) · 4 Claude menor que `assets/claude-min-version`
    (2.1.289) o ilegible. Complementos: env `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1` y, en tmux,
    `alternate-screen off` (los aplican `talent-channels/scripts/apply-renderer.sh` y las torres de
    `talent-orchestrator`). Las sesiones `claude` ya abiertas no cambian de renderer hasta relanzarlas.
15. **`/clear` está PROHIBIDO en actores persistentes, y tras `/clear`, reinicio o sesión nueva el actor
    queda NO ACREDITADO** → Un `/clear` pierde el contexto sin el ritual de relevo (fichero de regreso +
    paso-0). Tras él —o tras un reinicio o una sesión nueva— el actor NO continúa el pipeline: queda **NO
    ACREDITADO hasta re-acreditar** con un sello nuevo en el bus (`talent-ceo` `reacreditar.sh`, ref 07).
    Escribir «SELLO …» en el pane sin ejecutar `bus-sellar.sh` no acredita nada.

## Cross-Skill Integration

Este es un skill de **doctrina**: los skills de fábrica lo **referencian** (puntero) en vez de
duplicar la higiene de contexto. La fuente de verdad vive AQUÍ.

- **`talent-channel-operation`** — el coordinador vigila el ctx% de sus panes (dev + auditor) y
  aplica compact-60 en cascada; su §9 y su gotcha de `/compact` remoto apuntan aquí.
- **`talent-coordination`** — su plantilla de handoff entre sesiones (§6) es una instancia del
  fichero de regreso; la regla 12 (compact-60 en cascada) apunta aquí.
- **`talent-merger`** — la estación de merge se auto-releva con el mismo protocolo (invariante 12);
  "shells bg sobreviven al `/compact`, re-pollear" (T9) vive aquí como gotcha 7.
- **`talent-orchestrator`** — implementación ejecutable de referencia (`scripts/torre-*`): el
  ctx-watcher de flota (`torre-compact.sh check`), el relevo con nonce anti-stale (`run`), los
  helpers puros (`lib-torre.sh`). `talent-context` generaliza esa mecánica a standalone.
  **Estado (2026-09-01 18:16 CDMX, orden del lead): `pozos-rotador.sh` y la familia `torre-*`
  quedan PARADOS — la rotación de pozos es MANUAL mientras tanto.** El puntero se conserva con la
  nota (no se borra: romper el linaje documental sería peor); re-verificar el estado al ejecutar.
- **`talent-docs-skill`** — al registrar/sincronizar este skill en CLAUDE.md/AGENTS.md se usa el
  carril docs (Diataxis: SKILL.md=tutorial, references=reference, gotchas=how-to).

## Next Steps

- **¿Decidir cuándo compactar?** → `references/01-doctrina-y-checkpoint-limpio.md`
- **¿Ejecutar el relevo (escribir regreso + /compact)?** → `references/02-protocolo-de-relevo.md`
- **¿Acabas de volver del compact?** → `references/03-paso-0-post-relevo.md`
- **¿Montar la vigilancia automática del contexto?** → `references/04-ctx-watcher.md`
- **¿Operas una fábrica multi-agente?** → `references/05-modo-flota.md`
- **¿Sospechas que un actor fabricó/corrompió autoridad?** → `references/06-ley-actor-degradado.md`
- **¿Correr la vigilancia?** → `scripts/ctx-watch.sh` (helpers puros en `scripts/lib.sh`, tests en `tests/run-tests.sh`)

## Fuera de alcance

- **Runners sellados** (CI sin sesión de agente): no hay ventana de contexto que vigilar.
- **Parseo del ctx-watcher para la UI de OTRO CLI** (p. ej. si el auditor corre un CLI cuya barra
  de estado o composer no siguen el formato `ctx: NN%` / `> …` / `│…│` aquí descrito): la
  **doctrina** (umbral 60 %, checkpoint limpio, fichero de regreso, paso-0) aplica IGUAL a esa
  sesión — es tool-agnóstica, no exclusiva de un CLI —; lo NO validado es que `scripts/lib.sh`
  parsee correctamente ESA UI concreta. No excluye el rol auditor: `talent-channel-operation` y
  `talent-channels` ya aplican Compact-60 al pane auditor con la mecánica aquí descrita cuando su
  CLI comparte el formato. Extensión (nuevo parser, mismos tests) si se valida un formato distinto.

## Paquete de fábrica

Este skill es miembro del **paquete de skills de fábrica** (16): linear-skill · skill-creator · talent-buzz ·
talent-ceo · talent-channel-operation · talent-channels · talent-context · talent-coordination ·
talent-issue-craft · talent-llm-local · talent-memoria · talent-merger · talent-orchestrator · talent-pm · talent-prd · talent-repo-onboarding. El paquete viaja JUNTO y
**motor-primero**: canónico en el repo motor `talent-factory` (`skills/`), propagado como núcleo
a los repos de producto con `skill-creator/scripts/sync-package.sh` (overlays por repo intactos)
y validado con `skill-creator/scripts/validate-package.sh` + `<skill>/invariants.tsv`.
Manifiesto: `skill-creator/assets/package.manifest` · doctrina y ratchet (D6): `skill-creator/references/09-paquete-de-fabrica.md`.
