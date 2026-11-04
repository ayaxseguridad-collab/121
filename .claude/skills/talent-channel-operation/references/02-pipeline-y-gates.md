# 02 — Pipeline y gates

Cada carril lo conduce el **coordinador a mano** (A → B → C): despacha, monitoriza en
foreground, releva a auditoría y aplica los gates. Escala ante anomalía, ambigüedad o cambio
irreversible en producción. El estado por carril (fase/SHAs/veredictos) vive en el state file [M5].
El núcleo de este doc es **repo-agnóstico**: lo específico del stack vive en el **anexo del repo**
(tabla «Según repo» del SKILL.md).

## Table of Contents

1. [Gate pre-issue [B4] — obligatorio](#1-gate-pre-issue-b4--obligatorio)
2. [Fase A — Plan](#2-fase-a--plan)
3. [Fase B — Código](#3-fase-b--código) · [PROC-16](#proc-16--escalación-de-scope-mid-código)
4. [Fase C — Entrega (PR DRAFT + HANDOFF)](#4-fase-c--entrega-pr-draft--handoff)
5. [Heurística CI: trasladada al Mergeador](#5-heurística-ci-trasladada-al-mergeador)
6. [Cierre del encargo](#6-cierre-del-encargo)
7. [Modo design-spike / PR docs-only (M5)](#7-modo-design-spike--pr-docs-only-m5)
8. [Ruta directa / release-to-lead (multi-repo)](#8-ruta-directa--release-to-lead-multi-repo)

## 1. Gate pre-issue [B4] — obligatorio

ANTES de despachar cada issue se verifica TODO esto; un fallo de cualquier condición **detiene el
despacho** de ese issue (no se "arregla en caliente"):

- **Working tree limpio** y rama en **`main` actualizado** dentro del carril [M1]
  (`preflight-issue.sh`).
- **Estado Linear del issue no terminal/en-review** [TAL-2275]: `preflight-issue.sh` recibe el
  `<TAL-id>` y consulta el estado real vía API; **aborta fail-closed** si el issue está
  Done/Canceled/Duplicate/In Review (o si no se resuelve el estado). Gotcha TAL-1178: tras
  `claude --resume`/compact el **TaskList del harness** rehidrata intenciones muertas (mostró un
  issue `in_progress` cuando estaba **Done y mergeado**) — el TaskList NO es fuente de verdad,
  Linear sí. Estados bloqueados configurables con `TCO_DISPATCH_BLOCK_STARTED_NAMES`; gate
  desactivable con `TCO_PREFLIGHT_REQUIRE_LINEAR_STATE=no`.
- **Agentes al día**, verificados **al 100% y por comando** (no de memoria, no delegado al
  carril): `claude update` al día + Codex en última versión (`codex --version` vs
  `npm view @openai/codex version`). **NO se retoma ni se despacha un carril sin esto
  verificado** — detalle y comandos en `talent-channels/references/06-operacion-y-launchers.md`
  ("Agentes al día").
- **Modelo del dev verificado/forzado** [A4]: la cuenta puede tener el modelo bueno **agotado** y
  el alias del contenedor **no pasa `--model`** → un panel nuevo caería al default degradado.
  `dispatch.sh` lo garantiza fail-closed: si `TCO_DEV_MODEL` está definido (agents.conf, **Opus vigente**
  — el modelo de arranque/plan), corre `tco_ensure_model` sobre el pane dev y **muere con "ESCALAR"**
  si el modelo no queda confirmado (¿cuenta agotada?) — no se despacha sobre modelo degradado. Este
  gate pre-issue verifica el modelo de **arranque (plan)**; el switch a **Sonnet vigente en el GO de coding**
  (modelo-por-fase, TAL-2675) y su fallback a Opus vigente a la 5ª ronda son un paso POSTERIOR del
  coordinador, no de `dispatch.sh`. Mecánica del diálogo `/model`, resume+auto-compact y recycle de
  modelo en `references/11-modelo-effort-y-recycle.md`.
- **Githooks del carril activados**: con `TCO_BOOTSTRAP_GITHOOKS=yes` (default), `dispatch.sh`
  corre `bash scripts/setup-githooks.sh` en el clon del carril y verifica
  `core.hooksPath=.githooks`. Si falla → **warn-no-die** (defensa en profundidad: el
  enforcement real es la **regla 13 del coordinador** — re-lectura del head == sha GATEADO —
  más los **gates AND del Mergeador** con CR-CLI centralizado; el hook local solo adelanta el
  fallo). Nota: `dispatch.sh` aún traza el texto viejo "backstop = merge-gate M8 + CR App"
  (falso en v3) — fix de .sh en follow-up. **[TAL-8040]** Si `core.hooksPath` queda ≠ `.githooks`
  (típico: `githooks` sin punto → pre-push inactivo en silencio), `tco_githooks_ensure` lo CORRIGE
  solo cuando `.githooks/pre-push` es un fichero ejecutable y lo registra en la salida
  (`[HOOKSPATH] githooks -> .githooks`); sin ese hook NO corrige y mantiene el aviso con la causa.
- **[TAL-8040] Higiene git del manifiesto del canal** (`[TFM-HYGIENE]`): tras el `incus file push`
  de `.claude/tf-manifest.conf`, `dispatch.sh` (también en `--soft`) añade la copia a
  `.git/info/exclude` del clon (`tco_tfm_exclude_ensure`, idempotente) y corre el
  POST_DISPATCH_CHECK fail-closed `tco_tfm_post_dispatch_check` ANTES de crear la sesión tmux:
  (1) el fichero existe · (2) su sha256 == el de `TCO_TF_MANIFEST` · (3) `git check-ignore` PASS
  (un fichero TRACKED muere pidiendo destrackearlo a mano; el despacho nunca hace `git rm`) ·
  (4) `git status --porcelain -- .claude/tf-manifest.conf` vacío. Cada fallo muere nombrando el
  punto. Sin esto `draft-handoff.sh` (árbol limpio exigido) bloquea el primer despacho por un
  fichero que puso la propia fábrica.
- **[TAL-3266] Calidad del issue + control HOLD/RELEASE/SIN-AUDIT** (gate 4 de
  `preflight-issue.sh`): `audit-issue` acredita la calidad (`--issue <TAL-id>
  --min-score 70`) SOLO con `classification_source=marker` **+**
  `operational_gate_eligible=true` **+** exit 0 — los TRES; el exit 0 solo no basta.
  Además se parsean los **comentarios de control** del lead (primera línea del comentario
  Linear):
  - `HOLD id=<uuid>` — **veta el despacho**; un HOLD de no-autoridad también veta y ESCALA.
  - `RELEASE id=<uuid>` — libera SOLO su HOLD si lo emite una autoridad
    (`TCO_CONTROL_AUTHORITY_IDS`) con timestamp **posterior** al HOLD.
  - `SIN-AUDIT rev=<hash>` — bypass atómico **solo para `type=hotfix`** (Sev1): el `rev`
    debe coincidir con el hash canónico del issue (body+propiedades+relaciones) y el
    `comment.id` solo se consume UNA VEZ vía `flock` (claim cross-host en
    `TCO_CONTROL_CLAIM_FILE`). Un tipo distinto de `hotfix` → SIN-AUDIT ignorado + ESCALA.
  - **[TAL-5172] `BRIEF-ACREDITADO desc_sha256=<hash>`** — desbloquea los **briefs** ya curados
    por el Orquestador que `audit-issue` rechazaba (su marcador de calidad no vive en el cuerpo
    de la issue). Vía alternativa de acreditación
    que sustituye a `audit-issue` (no a HOLD/RELEASE/SIN-AUDIT, que se evalúan **primero** y
    siguen intactos: un HOLD activo veta el despacho aunque exista un BRIEF-ACREDITADO
    válido). Solo cuenta si lo emite una autoridad (`TCO_CONTROL_AUTHORITY_IDS`) **y**
    `desc_sha256` coincide con el hash recalculado de `issue.description` en el momento del
    gate (`tco_brief_rev_hash` — hashea SOLO la descripción, no los 9+ campos compuestos de
    `tco_sinaudit_rev_hash`, precisamente para no invalidar el brief ante cualquier edición
    administrativa ajena del issue). Drift (hash vacío o distinto) → **fail-closed idéntico
    a SIN-AUDIT**: el marcador se ignora y el gate exige `audit-issue` con normalidad, nunca
    abre en silencio. Verificado en `tests/run-tests.sh` bloque `[TAL-5172-F]` (determinismo
    del hash, autor no autorizado, drift, y el caso central: HOLD + BRIEF-ACREDITADO válido +
    audit-issue acreditado → sigue BLOQUEADO por el HOLD).
    **Precedencia completa** (fijada tras `veredicto-codex-5172-2d653ab5.txt` MAYOR 1, bug real
    reproducido y corregido — no solo documentado): `HOLD` > `SIN-AUDIT` **vigente-y-pendiente**
    (rev coincide, comment.id NO consumido) > `BRIEF-ACREDITADO` > `audit-issue` > CLEAR. La
    palabra clave es **vigente-y-pendiente**: un `SIN-AUDIT` con `rev` STALE (drift) o cuyo
    `comment.id` ya fue consumido NO es "vigente-y-pendiente" — es un control histórico
    inactivo, y NO debe cortar la evaluación de un `BRIEF-ACREDITADO` que sí sea vigente en el
    mismo hilo. El bug original (`return 0` inmediato dentro del bloque SIN-AUDIT para ambos
    casos drift/consumido) saltaba por completo el bloque BRIEF-ACREDITADO — rechazaba briefs
    válidos por un SIN-AUDIT que ya no aplicaba. Verificado en `tests/run-tests.sh` bloque
    `[TAL-5172-G]` (SIN-AUDIT stale + brief válido → `BRIEF_ACCREDITED`, no `CLEAR`; SIN-AUDIT
    consumido + brief válido → igual; gate completo con la misma combinación → bypass, no
    escalada).
  Escape hatch: `TCO_PREFLIGHT_REQUIRE_AUDIT_ISSUE=no` — SOLO el literal `no` apaga el gate;
  typo (`false`/`off`) → activo + aviso (espejo EXACTO de `TCO_PREFLIGHT_REQUIRE_LINEAR_STATE`).

**Freshness del reciclaje [regla lead]:** el **PRIMER** paso del reset de un canal deja el carril 100%
actualizado, **NUNCA** sobre un `main` viejo del golden (incidente: un carril arrancó **39 commits stale**
por golden viejo + recycle que no hacía pull). `tco_recycle_carril` hace `git fetch origin` +
`git checkout -f main` + `git reset --hard origin/main` + `git clean -fd` (descarta WIP/rama del issue
previo); **`dispatch.sh` verifica fail-closed** que `HEAD == origin/main` tras el reciclaje y **escala** si
no.

**Freshness también en el PLAN-GATE, no solo al pre-issue:** un canal que itera muchas rondas de
plan acumula staleness — su `origin/main` LOCAL queda viejo si no hace `git fetch` (visto: un canal
17 commits detrás, con su `origin/main` pinneado en un `#PR` viejo, mientras el main real había
avanzado tras un cambio de CI). El plan-gate audita el diseño contra el árbol LOCAL del canal → si su
base es vieja y el plan toca un **fichero de CI o un hot-file** (`scripts/ci/**`, `next.config.ts`,
`proxy.ts`, `messages/*.json`…), el auditor razona sobre código obsoleto. **Antes de
gatear un plan que toca CI/hot-files, verificar `HEAD == origin/main` real** (con `git fetch`); si
no, sincronizar (el recycle `--force-reset` lo arregla) y re-validar contra el fichero vigente ANTES
de gatear.

**[TAL-5172] Hot-files vigentes = `scripts/ci/**` + contexto `local-gates`** (Actions OFF,
TAL-2286/2288): el piso real de CI hoy es el motor local-gates, no los workflows heredados de
GitHub Actions en `.github/workflows/` (`ci`/el ex-gate de PR/`docs`) — esos siguen en el repo
como **referencia/fuente de extracción inerte**, no ejecutan nada, y ya no son el hot-file
a proteger aquí.

**[C-ops-i] Prohibido parchear infra compartida en caliente**: los hot-files de CI/infra compartida
(`scripts/ci/**`, el contexto `local-gates`) son el piso de **todos los canales y del Mergeador**.
Un parche directo sobre `main` o la rama del coordinador (fuera del flujo canal + PR) anula el gate
para el resto de la flota en silencio. **Toda modificación a infra compartida entra por PR +
code-gate normal**, nunca in-situ "para desbloquear este canal".

**[TAL-2276] `--force-reset` limpia el git ANTES del preflight:** el reciclaje resetea git, pero corre
DESPUÉS del gate B4; un carril con WIP/rama del issue previo moriría en el gate git del preflight. Con
`--force-reset`, `dispatch.sh` señala a `preflight-issue.sh` (2º arg `--force-reset-git`) que resetee el
carril a `origin/main` (`tco_reset_repo_to_main`, fail-closed en el `fetch`) **entre** su gate BD-sync y
su gate git, y **solo si el gate BD-sync quedó en verde** — jamás se muta el carril si prod no está 100%
sync (regla 24). Excluido en `--soft` (respeta el guard `tco_wait_idle` del recycle suave) y en `--dry-run`.

Los gates previos **específicos del stack** (ledger de migraciones, estado de la base, etc.) NO
viven aquí: los define el **anexo del repo** (tabla «Según repo» del SKILL.md) y la nota de
`preflight-issue.sh`.

## 2. Fase A — Plan

1. `dispatch.sh` lanza al equipo de desarrollo en **bypass + plan mode + `/effort xhigh`** con el
   prompt de contexto (issue Linear vía `linear-skill`).
2. El equipo de desarrollo presenta el plan en pane `.0`.
3. `audit-gate.sh` releva el plan **literal** (con `run_id` + hash del plan) al pane `.1` y
   corre el loop dev ↔ auditoría hasta veredicto.
4. **GO** → aprobar el plan: el dev selecciona **opción 1** de ExitPlanMode y el literal del GO
   (sugerencias no bloqueantes) se releva por archivo. **NO-GO** → **opción 4** (la opción de
   *seguir planificando / pedir cambios*) con el feedback literal por `lee <ruta>`, lo que
   **mantiene al dev en plan mode** revisando (NO aprueba); se itera. Solo el GO de auditoría
   aprueba (invariante 3). **Verificar la posición del cursor `❯` ANTES de seleccionar** cualquier
   opción del diálogo (lección dura de la ráfaga M11: una opción se eligió antes de tiempo).
   **Secuencia canónica completa del NO-GO** (opción 4 → verificar "plan mode on" → relay → git
   limpio): **PROC-17** en `references/03-mecanica-tmux-incus.md`.
5. **AskUserQuestion del dev** durante el plan: enrutar por tipo de decisión — **diseño** (granularidad
   de un enum, mecanismo interno) la decide el **coordinador** con el recomendado del dev;
   **scope/política/disposición-de-datos** (cambio de esquema de datos, migración de datos, composición
   del batch) se **escala al lead**, **una pregunta por turno** (en Academia Ejemplo: regla 22 del CLAUDE.md). El carril **no se mata** ante
   un menú: queda vivo con un `pendiente-decisión` que el coordinador resuelve e inyecta (M4). Tabla de
   enrutado en `references/03-mecanica-tmux-incus.md`.

**Localizar el plan `.md` a gatear por CONTENIDO, nunca por mtime** — **doctrina para usos NO-gating**
(adjuntar el plan a un HANDOFF, archivarlo, revisarlo a posteriori): si hace falta ubicar el fichero
de plan del dev en disco, un contenedor RECICLADO retiene planes `.md` de sesiones previas con **mtime
fresco** — `ls -t plans/*.md | head -1` selecciona el artefacto EQUIVOCADO (se han archivado planes de
otra sesión). Localizar por el contenido del encargo (`grep -l '<TAL-N>' plans/*.md`), no por el más
reciente. **Fail-closed ante coincidencia múltiple**: ese `grep` puede devolver VARIOS ficheros
(reintentos o reciclados de la MISMA issue) — **exigir exactamente UNA coincidencia**; si hay >1, NO
tomar la primera: desambiguar por `run_id`/sesión (y mtime + topic del menú-plan vivo). Coincidencia
múltiple sin desambiguar = se pide reemisión, **nunca usar a ciegas** el primer match.

**Para GATEAR, el `.md` en disco NO es la fuente — manda la regla 17 (SKILL.md): el plan EN VIVO de la
sesión del dev (transcript; pantalla solo de respaldo), extraído y normalizado por el procedimiento de abajo.** El dev puede procesar un NO-GO y avanzar
su razonamiento sin reescribir el fichero; un canal reciclado retiene el `.md` del encargo anterior. La
doctrina de arriba localiza el `.md` para archivarlo o adjuntarlo — nunca para decidir el veredicto.

### Procedimiento determinista de captura del plan (regla 17)

Fail-closed, ejecutado como **script** (nunca sourced): `scripts/extract-plan.sh <carril> <ENC> <OUT>`
(TAL-8039). Localiza la carpeta `scripts/` del skill **desde la raíz Git** del clon del canal
(`git rev-parse --show-toplevel` + la ruta canónica del skill; las dos ubicaciones: motor
`skills/talent-channel-operation/scripts` y espejo `.claude/skills/talent-channel-operation/scripts`) y
**fail-closed** (exit 9) si ninguna resuelve:

```bash
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || { echo "FAIL-CLOSED: fuera de un repo git — corre desde el clon del carril"; exit 9; }
HERE=""
for cand in "$ROOT/skills/talent-channel-operation/scripts" "$ROOT/.claude/skills/talent-channel-operation/scripts"; do
  [ -f "$cand/extract-plan.sh" ] && { HERE="$cand"; break; }
done
[ -n "$HERE" ] || { echo "FAIL-CLOSED: no localizo scripts/ del skill bajo $ROOT"; exit 9; }
bash "$HERE/extract-plan.sh" "$carril" "$ENC" "$OUT"     # carril · TAL-N del encargo · fichero de veredicto
```

`carril`, `ENC` (el `TAL-N` del encargo, el mismo `__ISSUE__` que renderiza el brief) y `OUT` (fichero
de veredicto de salida, igual que `bash scripts/relay.sh <carril> extract-stop-audit <outfile>` en
Fase B) son **argumentos del invocador** — NUNCA hardcodeados a un encargo. Precondición del brief
(`assets/prompt-dispatch.tmpl` paso 3): el dev abre el plan con la ancla literal `PLAN-INICIO <TAL-N>`
en su propia línea y lo cierra con `PLAN-FIN` en línea propia — la misma simetría que `STOP-AUDIT`.

**Fuente del plan, en tres niveles** (cada uno loguea `origen=…` y el motivo del rechazo). Con el TUI
en pantalla alternada la pantalla es solo el viewport: un plan mayor pierde su ancla y el gate abortaba
(exit 12, FAB-OBS-005). El plan viaja ÍNTEGRO en el transcript de la sesión del propio CLI, igual que
STOP-AUDIT viaja por fichero (TAL-3619):

1. **Transcript de la sesión VIVA** del pane dev (`lib.sh` `tco_plan_from_transcript`): PID vivo del
   pane -> `sessions/<pid>.json` -> `sessionId` -> **exactamente** `projects/<slug>/<sessionId>.jsonl`
   (jamás «la más reciente»: mtime no correlaciona pane↔sesión; los registros `isSidechain` de
   subagentes se descartan; las líneas ilegibles conservan su posición mediante un centinela).
   Se lee desde el `ExitPlanMode` número
   `TCO_PLAN_RECORDS` (20) más reciente hasta el final del fichero. Manda el **ExitPlanMode más
   reciente, solo si es VIGENTE**: ningún mensaje humano real (no `tool_result` ni `isMeta:true`) posterior **y** su
   `tool_use` PENDIENTE (sin `tool_result`: el estado normal mientras el dev espera la aprobación).
   Con `tool_result` de **rechazo** (`is_error`, «The user doesn't want to proceed…») el plan está
   RECHAZADO: **exit 19**; con `tool_result` de aprobación («User has approved your plan…») ya
   está APROBADO, nada que gatear: **exit 20**; con un mensaje humano posterior sin `tool_result`
   está OBSOLETO: **exit 19**. Ninguno de los tres cae a la pantalla (mostraría el mismo plan).
   Cualquier centinela POSTERIOR al ExitPlanMode elegido vuelve su **vigencia indeterminada**:
   **exit 19**, «vigencia indeterminada: línea ilegible posterior al ExitPlanMode — re-pedir la
   presentación». No se intenta texto ni pantalla, aunque haya un resultado legible o texto nuevo.
   Un centinela ANTERIOR no afecta. Un registro con `message` de tipo inesperado también deja un
   centinela; no hace fallar la lectura completa.
2. **Texto con ancla del turno vigente** del mismo transcript: los bloques `text` del último turno
   (posteriores al último mensaje humano real y, si hubo un ExitPlanMode no vigente, posteriores a
   él) **si contienen una línea `PLAN-INICIO`**. Una nueva presentación en texto tras un rechazo
   sustituye al ExitPlanMode rechazado.
3. **Pantalla** (`capture-pane -J`, escalera de scrollback 2000/4000/8000): **respaldo** cuando los
   niveles 1-2 NO están disponibles.

**Disponible vs negativo — la regla de caída**: un nivel está **NO disponible** (cae al siguiente) solo
si no puede responder: sin sesión viva resoluble (CLI sin esa superficie —p. ej. Codex—, PID
muerto), `sessionId` inválido, transcript ilegible, o ni un ExitPlanMode legible (esquema alterado:
sin `id`/`plan` string) ni texto de turno con ancla. Un nivel que **responde en negativo NO cae**
(decisión sellada): ExitPlanMode rechazado/aprobado/obsoleto o de vigencia indeterminada (19/20), plan de OTRO encargo (11),
sin `PLAN-FIN` (12), ancla anidada (13) o chrome del TUI (18) se rechazan por contenido, nunca por
tamaño de pantalla ni cayendo a otra fuente hasta que alguna «acepte». Texto de turno **sin** ancla
(un preámbulo) no es una presentación: no hace «disponible» al nivel 2.

**Límite conocido del nivel 2 (N-m4)**: un texto posterior con anclas puede ser una nueva
presentación o una cita de un plan viejo; las anclas no expresan esa intención. La alarma de
staleness (16) detecta el plan idéntico a la última ronda cerrada, pero no todas las citas. Criterio
del ejecutor: no exigir un mensaje humano nuevo, porque excluiría presentaciones legítimas tras
un rechazo sin comentario separado. Resolver esa ambigüedad requiere ampliar el protocolo;
mientras tanto, re-pedir la presentación mediante ExitPlanMode.

Pasos, idénticos para los tres niveles (la fuente es lo único que cambia):

- **(0)** pane dev IDLE o exit 10 — un plan capturado a media presentación no se gatea.
- **(1-2)** delimitar con el awk de anclas, **fence-a-fence**: ancla FUERTE a inicio de línea
  (`PLAN-INICIO <ENC>`/`PLAN-FIN`, patrón de STOP-AUDIT) + guarda de bloque ambiguo (entre la última
  `PLAN-FIN` previa y la `INICIO` elegida, EXACTAMENTE una `INICIO` anclada). Sin ancla de ESTE
  encargo: **exit 11** · sin `PLAN-FIN`: **exit 12** · ambiguo: **exit 13** · fallo inesperado: 14.
  En pantalla, ambos rc de «recorte insuficiente» (1 y 2) suben peldaño de la escalera.
- **(3)** normalizar MÍNIMA y no destructiva (espacio en cola + colapso de líneas en blanco);
  `TCO_BUSY_REGEX` es detector de busy, NUNCA filtro de contenido.
- **(3b)** guarda de chrome del TUI (forma real y completa, anclada `^…$`, estrecha para no disparar con
  una viñeta del plan): si salta, **exit 18** (captura sucia).
- **(4)** anti-vacuo: menos de 10 líneas útiles, **exit 15**.
- **(5-6)** ronda = índice máximo de los `.norm` COMPLETADOS en `$TCO_RUNS_DIR` + 1; plan idéntico al de
  la última ronda completada = **ALARMA DE STALENESS, exit 16** (el gate no se abre).
- **(7)** ledger transaccional `pending -> gate -> completed`: la ronda solo se consume con veredicto
  real; gate sin veredicto = **exit 17** (recuperar con `audit-gate.sh --parse-only`, PROC-03).

Determinismo: el corte es fence-a-fence ⇒ el nivel (y `SB` en pantalla) afecta a si las anclas
*aparecen*, nunca al contenido entre ellas; `-J` neutraliza el ancho del terminal; la normalización no
depende del contenido. Todo error tiene control de flujo real (`case` sobre rc), no comentarios. Tests:
sección «TAL-8039» de `tests/run-tests.sh` (función `tco_extract_plan`, seams inyectables).

Sigue la doctrina de modelo/effort del GO de plan, sin relación con el procedimiento de captura de
arriba:

Las órdenes locales se envían solo desde reposo con compositor vacío y eco propio confirmado.
Si el cambio abre un selector o diálogo sin compositor, el helper acredita su estructura activa,
elige una fila existente y verifica el modelo por selector o el esfuerzo por estado. Una captura
incompleta, otro diálogo o un efecto no confirmado devuelve error y mantiene el gate cerrado.

> **Modelo Y effort por transición de modo — los fija el COORDINADOR vía `tmux send-keys`, los agentes NO
> los cambian solos [Regla 0, modelo-por-fase TAL-2675]:** despacho / entrar a plan mode → **Opus vigente
> `/effort xhigh`** (`dispatch.sh`). **Con el GO de plan, la secuencia es ÚNICA y estricta — NUNCA con
> el menú de ExitPlanMode abierto** (el diálogo de aprobación IGNORA texto tipeado; intentar `/model` o
> `/effort` mientras está abierto los pierde o los deja como texto literal en el composer): (1)
> **aprobar PRIMERO** — el dev selecciona opción 1 y entra en bypass/coding con el modelo/effort
> VIGENTE (si venía de Opus vigente/`xhigh`, el primer tramo corre en ese burst — conocido y aceptado); (2)
> **Escape** para INTERRUMPIR al dev → queda **INTERRUPTED/idle** (NO reanuda solo); (3) SOLO ENTONCES,
> con el dev idle, el coordinador conmuta el modelo con **`model="$(tco_model_for_phase coding)" && [ -n "$model" ] && tco_set_model "$carril" "$pane" "$model" || exit 1`** (picker interactivo — `/model` **SIN** argumento inline: el envío inline es
> un NO-OP silencioso, `Kept model as …`, sin diálogo que confirmar) → confirma **UN** `1` SOLO
> si aparece el diálogo → **verifica el efecto REAL** con `tco_verify_model_effect` (AUTORIDAD en
> disco) o, como mínimo, por el PICKER (`tco_model_is`) — nunca por el eco de un comando; jamás
> `/model` con argumento inline tecleado a mano (p. ej. `Sonnet vigente`) — DOS diálogos modales
> INDEPENDIENTES a partir de aquí; (4)
> LUEGO fija **`/effort high`** → confirma → **verifica** por la línea "Set effort level to high"; (5)
> **relevar el GO y reanudar** con `relay.sh <carril> audit2dev-resume <informe>` — LA manera de ejecutar
> este paso: entrega primero el informe como material no confiable, espera reposo acreditado y envía
> la instrucción fija del coordinador para repetir la orden interrumpida y continuar hasta el informe
> previo a la entrega. Texto único en `tco_relay_plan_go`; texto ajeno, estado desconocido o entrega
> incierta devuelven rc 2 y escalan sin duplicar la orden. El dev reanuda ya en Sonnet vigente/`high`. Nunca dejar al dev codeando en
> Opus vigente/`xhigh`, y nunca instruir el switch "antes de aprobar": el modal lo hace imposible (esta
> secuencia de aprobación y cambio precede al helper de relevo, ver ref 11 §6).
> **NO-GO**
> (el dev vuelve a re-planificar) → **`/effort xhigh`** (el modelo se queda en Opus vigente — plan/re-plan
> siempre es Opus vigente, no hay switch de modelo en el NO-GO). **`/effort max` PROHIBIDO** (nunca).
> **Fallback de la 5ª ronda de code-gate** (contrato de rondas, `references/11-modelo-effort-y-recycle.md`
> §5): el coordinador conmuta el modelo con **`model="$(tco_model_for_phase fallback)" && [ -n "$model" ] && tco_set_model "$carril" "$pane" "$model" || exit 1`**
> (picker interactivo, nunca `/model` con argumento inline a mano) sobre el fix en curso (mismo eje,
> contador de rondas NO se reinicia) — misma coreografía de un diálogo, sobre un pane ya idle
> (el code-gate no tiene menú modal que ignore el comando).
> Toda confirmación exige una fila afirmativa que nombre el modelo o nivel pedido.
> Una fila genérica «Yes» es incompatible: rc 2 sin pulsarla, con título visible y mínima del CLI.
> En el CLI mínimo probado (2.1.289), «Switch model?» nombra el modelo; el esfuerzo se aplica sin diálogo.
> El resume de una sesión baja el effort (y puede perder el modelo forzado) →
> **re-fijar al nivel del modo** (Opus vigente/xhigh en plan, Sonnet vigente/high en coding), nunca max. Helpers:
> `tco_set_effort` y `tco_set_model` (`lib.sh`, mismo tri-estado cada uno).
> **[P2] Confirmación diferida bajo carga:** aun con el dev idle tras el Escape, el diálogo de
> confirmación de `/model`/`/effort` puede tardar en aparecer bajo carga de la cuenta — `tco_set_effort`
> (y `tco_set_model`, mismo contrato) acepta un **4º arg `confirm_max_s`** (default
> `TCO_EFFORT_DOWNSHIFT_MAX=900`) para darle margen sin dar falso negativo antes de declarar rc 2. El
> diálogo se detecta con el predicado puro `tco_effort_dialog_from` ("Change effort level?"); el de
> `/model` con `tco_model_is`/la marca del diálogo (ver ref 11 §2).

Tras **GO de plan y cambio de modelo/esfuerzo** se usa `audit2dev-resume`, nunca el relevo
genérico como sustituto de la reanudación. En el caso distinto de un dev que ya implementa
sin interrupción pendiente, las **sugerencias
no bloqueantes** del GO se relevan por `audit2dev-queue`: espera reposo acreditado
durante `TCO_GO_WAIT_MAX` (900 s); ocupado toda la ventana devuelve rc 3 (diferido),
conserva el literal en cola persistente y el llamador reintenta en su siguiente ciclo
sin intervención (`TCO_GO_RETRY_GAP`, 10 s; `TCO_GO_RETRIES`, 12 ventanas).
El identificador de contenido, canal y panel impide repetir una entrega acreditada;
un envío incierto se conserva y escala sin duplicar. Texto ajeno, anomalía, estado
desconocido o reintentos agotados escalan. El efecto para la fábrica es el mismo:
el GO llega solo, también cuando el dev estaba ocupado al iniciar el relevo.

`watch-carril.sh` comprueba primero el estado esperado en cada sondeo: rc 0 imprime el recorte
del estado, también para `plan-listo`, `pregunta` o `permiso` con diálogo abierto. Si no aparece
y `tco_pane_busy` acredita reposo con pantalla idéntica entre sondeos durante
`TCO_WAIT_IDLE_POLLS` comparaciones consecutivas (default 3: cuatro capturas,
unos 30 s de estabilidad más el coste de captura y confirmación), devuelve rc 3 e imprime
la última respuesta visible. Ocupado, desconocido o pantalla distinta reinician la cuenta;
tiempo agotado sigue siendo rc 1.
La primitiva viva confirma reposo con dos capturas de la región de transcripción separadas
por `TCO_IDLE_STABILITY_GAP` segundos (default 2). Si el texto crece, devuelve ocupado aunque
no exista línea de actividad. Repite también la autoridad de sesión o la clasificación
calibrada después del intervalo; captura fallida o región desconocida impiden confirmar reposo.
Esta confirmación se aplica a esperas, envíos, relevos y reautenticación que usen la primitiva.
La clasificación pura de una captura conserva su contrato y sus calibraciones.
Ante **agente en reposo sin el estado esperado**, el coordinador LEE la última respuesta y
actúa en ese momento: responde la pregunta por la vía del skill, reenvía la instrucción de
reanudar mediante texto verificado desde reposo, o sella el bloqueo en el bus si no puede
resolverlo. Nunca vuelve a esperar sin más; no interpreta la entrega del GO como prueba de
implementación activa.

### Gate de salud post-dispatch (m1)

Tras despachar un carril, antes de seguir con el siguiente, un **health-check** confirma que **ambos
panes** quedaron bien: pane `.0` en **plan mode CON el brief** ingerido (no en splash), y pane `.1`
con el **rol de auditoría completo + effort correcto** (M2/M3). Caza al instante el *rol-no-cargado* y
el *effort-default* en lugar de descubrirlos a mitad de corrida. Un health-check fallido **no orfana** el
carril: se reintenta la inyección puntual de **TODO lo que el health-check valida** — rol/brief **y el
effort** (si el health-check detecta effort-default, el retry **re-fija el effort** además de re-inyectar el
rol/brief; no basta con recuperar el rol) — sin tirar el trabajo válido del otro pane.

**"Despachado" exige EVIDENCIA DE PANE, no la task list.** Un carril cuenta como despachado solo
cuando el coordinador CAPTURA las **últimas líneas del pane dev mostrando el `TAL-N` del brief +
`plan mode`** (o el arranque real del issue). El **TaskList del harness NO es fuente de verdad**
(gotcha TAL-1178: rehidrata intenciones muertas tras `--resume`/compact — un issue `in_progress`
que estaba Done y mergeado). Dos modos de fallo silencioso a cazar en el health-check:

- **Builds viejas del CLI (2.1.110): el bypass NO se auto-acepta con `IS_SANDBOX=1`** — el diálogo de
  permisos queda arriba y el brief no ingesta. Enviar **`Down`+`Enter` explícito** para aceptar el
  bypass y **verificar por captura** que el pane arrancó el issue; no dar por hecho el auto-accept.
- **Sesiones zombis**: matar la sesión previa (`tmux kill-server` dentro del contenedor) **ANTES de
  relanzar**, nunca acumularlas — un pane zombi encima de otro deja dispatches rotos que el
  health-check ve como "pane ocupado" sin brief real.

## 3. Fase B — Código

1. El equipo de desarrollo implementa (bypass + **`Sonnet vigente`** `/effort high` — modelo-por-fase, NUEVO;
   fallback a Opus vigente `/effort high` a la 5ª ronda de code-gate sin converger sobre el mismo fix, ver
   §Circuit-breaker abajo y ref 11 §5), **commitea** y declara **stop-audit**.
2. **stop-audit real = commit nuevo** [Pilar 2]: el coordinador solo releva a auditoría cuando `HEAD`
   cambió respecto al último auditado (un commit ocurrió). No dispara por banner re-dibujado ni por eco;
   el feedback ya no se eca en el pane (va por archivo).
3. La auditoría inspecciona el **diff real** del repo local compartido (no una copia relevada
   del código), guiada por el run_id/sha del commit.
4. Loop hasta **GO** sobre el diff. Cada NO-GO exige **otro commit nuevo** en la ronda siguiente.

**GO-FREEZE del dev en el acto del GO**: al conceder el GO de código, el coordinador **CONGELA** al
dev — el siguiente mensaje al canal es la instrucción de entrega (Fase C), nunca un `continuemos`
genérico. Un nudge genérico post-GO hace que el dev "siga mejorando" y **avance el HEAD más allá
del commit auditado** → la regla 13 del coordinador y el intake del Mergeador (`headSha==auditedSha`) rebotan la entrega, o peor, un nudge a
un canal en STOP-AUDIT se consume como GO de entrega sin code-gate (gotcha vigente en `ref 09` §3).
Regla: entre el GO y la entrega, cada mensaje al dev es EXPLÍCITO sobre qué hacer; verificar el
estado del pane ANTES de nudgear.

### Doctrina COMMIT-ANTES-DE-AUDITAR [B10]

El sha que el dev declara en el STOP-AUDIT es **`git rev-parse HEAD` del carril** — un **commit
REAL**, que será el **head del PR** tras el push. Así el GO de auditoría, la regla 13 del
coordinador y el intake del Mergeador atan al
**mismo objeto** (`headSha == auditedSha`; la **equivalencia B9** — un GO sigue válido tras un
rebase ESTRICTAMENTE mecánico cuyo árbol resultante es idéntico salvo el re-parenting, y la
ejerce la ESTACIÓN, no el canal). Reglas:

- **Commit local pre-push está permitido y es lo canónico** (en Academia Ejemplo: regla 9 del
  CLAUDE.md — el gate de aprobación humana es el **push**, no el commit). No se audita working
  tree "para ahorrar un commit": un GO sobre working tree **no ata la entrega**.
- **Checkpoint-commit local periódico en hosts frágiles (N95 / mini-PC)**: en máquinas propensas a
  crash/restart, el dev commitea localmente al cerrar **cada unidad de trabajo** (no solo en el
  STOP-AUDIT), aunque el eje aún no esté para auditar. Motivo: **los commits sobreviven al
  crash/restart; el working tree NO** — visto: un canal con **2 commits** de checkpoint sobrevivió a
  un reinicio del host mientras otros canales perdieron todo el código sin commitear. El commit
  local es barato y sigue siendo pre-push (regla 9 — el gate humano es el push); el checkpoint no
  releva a auditoría (eso sigue siendo el STOP-AUDIT = commit del head futuro del PR). **Ojo**: un
  host que parece "caído" puede en realidad estar **thrashing** (RED estrangulada / D-state), no
  haber reiniciado de verdad — diagnóstico y recuperación en `references/09-gotchas.md` §8.
- `audit-gate.sh` **valida que el `artifact_sha` existe como commit** (`git cat-file -e` en el
  carril). Si no lo es → warn + instruye a la auditoría "audita el WORKING TREE" con traza
  explícita "este GO NO ata la entrega" (la regla 13 exige re-auditar sobre el commit real);
  `TCO_AUDIT_REQUIRE_COMMIT=yes` lo hace fatal.
- Riesgo acotado por construcción: la regla 13 (coordinador) y el intake del Mergeador exigen
  40-hex == headSha del PR — un GO working-tree jamás cierra una entrega ni aprueba un merge.

### Detección del STOP-AUDIT (informe pre-push)

El coordinador da por válido un STOP-AUDIT cuando, de forma objetiva, se cumplen LAS TRES:
**(1) commit ≠ baseline** (`HEAD` cambió respecto al último auditado), **(2) working tree limpio**
(`git status --porcelain` vacío), y **(3) el dev emitió un bloque STOP-AUDIT REAL** (informe
extraído con el extractor centralizado, anclado al SHA VIVO del carril). Solo la conjunción
dispara la **auditoría de código**: (1)+(2) a secas NUNCA autorizan — un **checkpoint-commit**
de host frágil (arriba) también deja HEAD≠baseline con árbol limpio sin que el eje esté listo
para auditar; sin el bloque (3) el coordinador NO gatea. El veredicto solo se acepta del bloque
JSON con `run_id`/`artifact_sha` esperados (`references/04-protocolo-auditoria.md`).

**[C-ops-g] HEAD-visto vs commits-ahead**: el HEAD capturado por el extractor puede ser STALE si el
carril siguió commiteando entre el snapshot y el relevo. Antes de abrir el gate, re-leer
`git rev-parse HEAD` en VIVO desde el contenedor y comparar con `tco_commits_ahead <carril>` (commits
por delante de `origin/main`): si el HEAD-visto difiere del HEAD vivo, o el número de commits-ahead
es mayor del esperado, el STOP-AUDIT capturado es STALE — pedir reemisión, no gatear sobre el
snapshot viejo.

El **informe pre-push del dev se extrae con el extractor centralizado**, nunca a mano:

```bash
bash scripts/relay.sh <carril> extract-stop-audit <outfile>   # helper: tco_current_stop_audit
```

Los **headers del informe varían entre rondas** (el dev no siempre repite el formato): el extractor
ancla en la línea que **empieza** por `STOP-AUDIT` (alternativa: `informe pre-push`) y corta en el
cromo del compositor; **la frase conversacional del dev "Estoy en el punto correcto de STOP-AUDIT" NO ancla**
(es charla, no informe). Si el extractor no encuentra informe, se pide al dev que lo re-emita — no
se recorta el scrollback a ojo.

**[P2] Ancla el ÚLTIMO marcador (anti-stale r1→r3)**: cuando hay VARIOS informes en el scrollback
(rondas r1, r2, r3), el extractor toma el **más reciente** — `max(header_fuerte, header_alternativo)`
por número de línea, sea cual sea su tipo. Antes el header fuerte ganaba siempre y se extraía el
STOP-AUDIT STALE de r1 aunque r3 fuera un `informe pre-push`. **Además `relay.sh extract-stop-audit`
exige `busy==0`** (pane dev IDLE) antes de extraer: un informe capturado mientras el dev sigue
trabajando puede estar a medio emitir → se espera a idle (fail-closed).

**Sección canónica del informe (contrato del dev — `assets/prompt-dispatch.tmpl`)**: el informe
pre-push DECLARA al final los **comandos de verificación + su exit code**, el **SHA auditado**
(`git rev-parse HEAD`), y el estado del árbol **clean/dirty**. Un comando con exit != 0, árbol `dirty`,
o SHA ≠ `git rev-parse HEAD` → el coordinador NO releva a auditoría (se pide reemisión COMPLETA; la
reemisión SUSTITUYE a la anterior — ver `04` §9).

**El criterio de detección es CONDUCTUAL, no de fraseo — y lo verifica el COORDINADOR, no el script**:
no gatear por frases exactas (el fraseo del dev varía: «esperando el GO», «parked», etc.); el criterio
es **tree limpio + pane sin spinner (idle) + un bloque STOP-AUDIT REAL con su SHA y `migration_slots`**.
Al extraer, anclar en el **ÚLTIMO header REAL** —`STOP-AUDIT — TAL` **o** el header alternativo
`informe pre-push`, el más reciente entre ambos por número de línea (per **[P2]** arriba: el header
fuerte NO gana siempre)—, **jamás en un eco tipo «Status: parked at STOP-AUDIT»**, y acotar hasta
`migration_slots`. Recordar el reparto de responsabilidades:
`relay.sh extract-stop-audit` / `tco_extract_stop_audit` SOLO capturan (fail-closed si el pane está
busy) y anclan/extraen **TEXTO** — **no** comprueban tree-clean, SHA de 40 chars ni slots; esa
verificación de invariantes es del coordinador (los checks de arriba), no del extractor.

**Vigilancia de informes largos y pertenencia al turno**: `watch-carril.sh stop-audit` y
`relay.sh extract-stop-audit` usan `tco_current_stop_audit`: primero el transcript completo
de la sesión viva del panel, solo los textos del último turno humano (sin confundir resultados
de herramientas, órdenes locales o subagentes con turnos); como respaldo, captura estable en
reposo con 800 líneas de historial. Un envío humano posterior invalida lo anterior. Si el disco
está disponible pero el turno no contiene informe, está corrupto o carece de respuesta, **no**
se rescata un informe antiguo del panel. La detección exige cabecera, SHA parseable, estado del
árbol y sección de comandos con códigos; no aprueba sus valores ni sustituye los gates.
Se confirma reposo después de la lectura. Un informe incompleto termina con rc 3 tras el umbral
de reposo, para que el coordinador lea y actúe, sin volver a esperar sin más.
Los estados `pr` y `merge` también usan el texto del turno completo: sus indicadores pueden
quedar sobre la ventana de 16 líneas igual que la cabecera del informe. Los diálogos
`plan-listo`, `pregunta` y `permiso` conservan prioridad en la pantalla del mismo sondeo.

> **CodeRabbit y la detección de STOP-AUDIT (v6.0):** la **detección** (commit nuevo +
> working tree limpio) no depende de CodeRabbit — y el canal YA NO corre CR en ninguna
> fase: la entrega va por `draft-handoff.sh` (Fase C, §4) y todo el consumo de CR es del
> Mergeador (`talent-merger`).
>
> **Encargos multi-issue (regla 14):** en un bundle del Orquestador, el plan de Fase A y el
> code-audit de Fase B cubren el **CONJUNTO** del encargo — un GO por encargo con
> `artifact_sha` = head del conjunto. Si el conjunto deja de ser auditable con rigor
> (creció), PROC-16 aplica sobre el encargo completo.

### PROC-16 — Escalación de scope mid-código

**Síntoma** [E27]: el alcance crece durante la implementación — el patrón real fue "3 bugs" → "7
bugs" → "hay que reconstruir funciones core". El dev, con buena intención, empieza a redefinir la
arquitectura dentro del issue.

1. **HOLD al dev**: instruir que PARE de codear (no se tira lo hecho; se congela).
2. Pedirle un **resumen conciso**: qué es **pre-existente** vs qué **introdujo su propio cambio**,
   y el tamaño real del arreglo mínimo vs el completo.
3. Presentar al lead **opciones A/B/C** (p.ej. A: arreglo mínimo dentro del scope; B: scope
   ampliado en este PR; C: issue nuevo para el resto) con la recomendación del dev y del
   coordinador — **una pregunta por turno** (en Academia Ejemplo: regla 22 del CLAUDE.md).
4. **Arquitectura sobre ruta crítica = decisión del LEAD**, no del coordinador (regla 7). El
   coordinador solo decide dentro del scope ya aprobado en el plan.
5. Con la decisión: re-brief al dev; si el scope cambió de verdad → el plan se re-audita (vuelta a
   Fase A para el delta).

**Circuit-breaker (NO-GO repetido en el mismo eje)**: si un encargo acumula rondas de NO-GO sobre
el MISMO eje (visto: 7 rondas), disparar circuit-breaker en vez de seguir iterando. Al parquear:
(criterio CUALITATIVO del coordinador — "visto: 7 rondas" es la observación histórica que motivó la
doctrina, no un contador operativo con acción automática al llegar a 7; el PARK sigue siendo juicio
del coordinador, sin cambio por TAL-2675. Aparte, modelo-por-fase (`references/11-modelo-effort-y-recycle.md`
§5) SÍ define un umbral operativo distinto y más temprano — 5ª ronda NO-GO → sube el fix a Opus vigente —, que
no sustituye ni redefine este circuit-breaker cualitativo.)

- **Cosechar el root-cause que el dev articula al parquear** — suele contener la partición
  correcta (ejemplo real: "un guardrail estático por AST no puede firmar valores dinámicos en
  runtime → asintótico" → partió limpio en mitad estática decidible + mitad dinámica en RLS/RPC).
  Escalar al Orquestador el **historial de rondas Y ese root-cause**, no solo los veredictos.
- **El re-scope autoritativo debe nombrar lo que queda FUERA**: al re-despachar, sesión fresca +
  brief que diga explícitamente qué NO se hace ("la mitad dinámica es la issue TAL-N, no la
  abordes"). Sin el "qué queda fuera", el dev tiende a re-abrir el scope viejo.

## 4. Fase C — Entrega (PR DRAFT + HANDOFF)

**(v6.0 — ADR-0043)** El pipeline del canal TERMINA aquí. Sin CodeRabbit, sin esperar CI,
sin merge: eso es del Mergeador (`talent-merger`). Columna vertebral:

1. **Con el GO de código**, el dev corre `bash scripts/draft-handoff.sh`: valida working
   tree limpio + rama en minúsculas con prefijo válido + gates locales verdes
   (`typecheck`/`lint`/`build`) y emite el sentinel `.claude/.draft-handoff` (SHA de HEAD,
   one-shot). Es la ÚNICA vía de entrega — el canal NO corre `cr-review.sh` (mecánica
   canónica: runbook `docs/runbooks/coderabbit-cli-pre-pr.md` § «Entrega draft»).
   **AMENDMENT TAL-2820**: en flotas débiles el paso `build` es opt-in-skippable con
   `TA_DRAFT_SKIP_BUILD=1` (opt-in por máquina, activación operativa del lead/coordinador,
   NUNCA en el repo) — el gate oficial de build sigue siendo `local-gates` en runners
   sellados, que lo re-corre SIEMPRE; el skip declara el estado en la sección humana del
   HANDOFF, no en el bloque machine-readable.
2. **Push atómico** del canal (el hook `.githooks/pre-push` acepta el sentinel draft para
   ese SHA y lo consume tras validar el push completo).
3. **PR en DRAFT**: `gh pr create --draft` con `closes TAL-N` por CADA issue del encargo
   (regla 14) — sin el `closes`, Linear no cerrará el issue cuando el Mergeador mergee.
   (`closes` es el régimen por defecto en TA — apply-del-Mergeador-mismo-turno; en repos con
   apply escalado/manual la ESTACIÓN lo ajusta a `refs TAL-N` + label `apply-pendiente`:
   `talent-merger` anexo §closes-vs-refs.)
4. **Comentario HANDOFF** de la plantilla `docs/templates/handoff-pr-draft.md` (todas las
   secciones + bloque machine-readable al final con el head vigente). El HANDOFF es la
   interfaz con la 2ª estación: los invariantes que declara son el contrato contra el que
   el Mergeador auditará cualquier refactor. **OBLIGATORIO-POR-DISCIPLINA rellenar la sección
   "Modelo por fase"** (TAL-2675) con el modelo/effort REAL de cada fase (Plan, Coding,
   Fallback a Opus vigente si aplicó) — git NO graba qué modelo ejecutó cada tramo, así que el switch
   Opus vigente→Sonnet vigente (y el fallback, si el code-gate lo disparó) queda **auditable** solo si el
   coordinador lo declara aquí; no se infiere después. **NO machine-enforced en este PR**
   (ruling del lead: el hard-enforce fail-closed en `verify-handoff.sh` se intentó y se
   **revirtió** por blast-radius — rompía HANDOFF v1 existentes, faltaba test versionado y 5
   referencias del Mergeador aún cuentan "9 secciones") — la auditabilidad hoy depende
   ÚNICAMENTE de la **disciplina del coordinador al validar la entrega (regla 13)**:
   **ningún documento del Mergeador (`talent-merger`) le instruye todavía revisar este campo** —
   un HANDOFF puede omitirlo, pasar `verify-handoff.sh` limpio y no recibir esa revisión. Cerrar
   esa brecha (instrucción al Mergeador + hard-enforce: schema v2 + test + coherencia de refs)
   es **follow-up → TAL-2683**.
   **Alcance**: aplica al flujo Academy (PR draft + HANDOFF, este skill); el **motor-go** de
   `talent-factory` (onboarding de repo nuevo, ref `talent-orchestrator` §Supervisión
   multi-repo) **NO lleva HANDOFF** — no aplica ahí.
   **Scope ledger (AC/NG) — OBLIGATORIO-POR-DISCIPLINA (paquete v1 · préstamo m2)**: el
   HANDOFF incluye la sección `### Scope ledger (AC/NG)` de la plantilla con UNA línea de
   evidencia por cada `AC-N` de la issue (comando/salida que lo demuestra), UNA línea de
   preservación por cada `NG-N` («no se tocó; lo prueba: …») y el cierre literal
   `Otros cambios de comportamiento: ninguno` — si esa frase NO fuera cierta, el canal PARA
   y pide enmendar la issue ANTES de entregar (jamás se entrega alcance no contratado).
   `verify-handoff.sh` tolera la sección (presencia-de-requeridas, verificado); su
   hard-enforce viaja con el follow-up de endurecimiento (placeholder de backlog).
5. **Validación (regla 13)**: `bash scripts/verify-handoff.sh <pr>` con exit 0 — corre el
   dev al entregar y el coordinador al cerrar. Commit nuevo post-entrega ⇒ re-emitir
   sentinel Y bloque (head_sha) y re-validar.
6. Issues a **In Review** (`linear-skill`) → cierre del encargo (§6). Dev rebaseó sin
   publicar → PROC-18 (ref 05).

**Monitorizar la entrega por `closes TAL-N` / `head_sha`, NUNCA por nombre de rama**: un dev
puede **renombrar su rama en la entrega** (visto: `youtube-attendance-signal` → `feat/tal-1800-…`)
→ un monitor keyed al nombre viejo no ve el PR (timeout falso). El monitor de entrega busca el PR
por `closes TAL-N` en el body (o por `head_sha`), que son estables.

**[P2] Detalles operativos de la entrega:**

- **Las 9 cabeceras del HANDOFF machine-enforced** (la enumeración canónica vive SOLO en
  `docs/templates/handoff-pr-draft.md`; aquí solo se nombran para el checklist): Resumen ·
  Issues del encargo (`closes TAL-N`) · Superficie/archivos · Invariantes · Verificación
  (comandos + exit) · `migration_slots` · Riesgos/notas al Mergeador · head_sha vigente ·
  bloque machine-readable. **+ "Modelo por fase" (TAL-2675) — OBLIGATORIA-POR-DISCIPLINA,
  NO machine-enforced** (hard-enforce revertido; el Mergeador aún NO tiene instrucción de
  revisarla — follow-up TAL-2683). Un HANDOFF con una cabecera vacía o un invariante vago =
  entrega **rebotable** por el Mergeador.
- **Comentario > 256 KB (límite de la API de GitHub)**: si el HANDOFF/plantilla excede el
  límite del `gh pr comment`, postearlo con un **script de Node** (`gh api` + payload por
  fichero) en vez del argv — el argv trunca y rompe el bloque machine-readable.
- **Volver un PR a DRAFT**: `gh pr ready --undo <pr>` (si un draft se marcó "ready" por error
  antes de que el Mergeador lo consuma).
- **Validación de la entrega por el coordinador (regla 13, `tco_verify_delivery`)**:
  `verify-handoff.sh <pr>` == 0 y **DESPUÉS** re-leer que `head del PR == sha GATEADO`
  (el head auditado) — orden **anti-TOCTOU**: verificar primero, releer el head después, para
  cazar un head movido tras el verify. rc 127 = ruta del script mal (≠ entrega inválida).
- **`verify-handoff == 0` es NECESARIO, no SUFICIENTE** — con precisión sobre qué cubre ya el
  script: `verify-handoff.sh` **SÍ valida** `head_sha` declarado == `headRefOid` (en la
  instantánea del PR que consulta) y el **formato** de `migration_slots`. Lo que NO cubre y el
  coordinador añade: (a) la **re-lectura POSTERIOR del head** como fence **anti-TOCTOU** (un
  push entre el verify y el cierre deja el exit 0 obsoleto — es el orden verificar→releer del
  bullet anterior), y (b) el **cruce `migration_slots` declarados ↔ ficheros REALES de la rama**
  (`git ls-files supabase/migrations` sobre el head — el script solo valida el patrón
  `^[0-9]{14}$`, no la existencia). Evidencia C2/#899: HANDOFF declaraba el
  slot `…845…` con el fichero real en `…853…` — verify pasó (formato válido), el Mergeador se
  encontró la discrepancia en intake.
- **[B2] HANDOFF-fresco — no copiar de PR anterior**: el bloque machine-readable del HANDOFF
  incluye `head_sha` y `migration_slots` específicos del encargo actual — copiar de un HANDOFF
  previo deja valores stale que `verify-handoff.sh` no siempre detecta. Emitir el HANDOFF
  desde cero en CADA entrega; si se usa la plantilla, limpiar todos los campos del bloque
  machine-readable antes de rellenar.
- **[C-ops-j] Contraste `headRefOid` fresco ANTES de postear el HANDOFF**: leer
  `gh pr view <N> --json headRefOid` en VIVO justo antes del comentario HANDOFF — si difiere
  del SHA auditado (`artifact_sha` del GO), el PR avanzó entre el GO y la entrega (carrera
  estación↔coordinador; T5 de `references/12-refix-bounced.md`). En ese caso: stand-down +
  investigar quién avanzó el head.
- **[tabla-vendor PRE-entrega]**: cuando el encargo toca un skill que expone acciones de
  API-vendor al agente ejecutor, verificar los criterios DoD de tabla-vendor del **perfil de
  issue-craft del REPO OBJETIVO** (`docs/reference/issue-craft-perfil*.md`; sus secciones de
  DoD/gate de calidad) como gate de calidad de la entrega — declarar el estado ("cumple
  tabla-vendor" / "n/a") en la sección riesgos/notas del HANDOFF. El glob debe resolver a
  **EXACTAMENTE UN** archivo: cero coincidencias → PARAR e instruir crearlo desde
  `talent-issue-craft/templates/perfil-de-repo.md`; más de una → PARAR y pedir la adjudicación
  del perfil vigente (nunca elegir uno en silencio) — jamás usar el perfil de otro repo como
  default.

## 5. Heurística CI: trasladada al Mergeador

**(v6.0)** El canal de producción NO espera los checks de CI del PR — la heurística
flake-vs-real y su tabla de decisión viven ahora en `talent-merger`
(`references/02-protocolo-por-pr.md` §9, PROC-M19). Si el Mergeador detecta una regresión
real del dominio del encargo, vuelve como micro-encargo de refactorización suyo o como
bounce-to-pool — nunca como re-apertura de este canal.

## 6. Cierre del encargo

**(v6.0)** El cierre del coordinador es la **entrega validada**, no el merge:

- `verify-handoff.sh <pr>` == 0 (regla 13) + working tree del canal limpio.
- Issues del encargo en **In Review**; el **Done lo produce el merge del Mergeador** vía
  `closes TAL-N` — el coordinador NO espera el merge ni verifica applies (ADR-0043; el
  post-merge de migraciones es del Mergeador, `talent-merger` ref 06 + anexo).
- `git pull` operativo del coordinador + **reciclar el canal** (`tco_recycle_carril`)
  [Pilar 7] → despachar el siguiente encargo.
- Un bounce del Mergeador (draft rechazado en intake / defecto de diseño) vuelve SIEMPRE
  vía pool del Orquestador como **re-entrada por la Decisión 6** (las issues del bundle →
  `Backlog` + label `bounced` + comentario; NO issues nuevas, NO trabajo nuevo) — nunca
  como diálogo con el canal ya
  reciclado. Cuando esa re-entrada es un **re-fix code-only del PR rebotado**, el flujo
  abreviado (sin plan mode) está en `references/12-refix-bounced.md`.

## 7. Modo design-spike / PR docs-only (M5)

El pipeline asume **implementación** (stop-audit = commit con diff de código). Pero los
**spikes de diseño** entregan **ADR/working-spec** (PR docs-only). Para esos:

- El **artefacto a auditar es el ADR/spec** (el diff de Markdown), no un diff de código; la auditoría
  juzga completitud/coherencia/decisión, no corrección de código.
- Para clasificar **PR docs-only** se examina el **set COMPLETO de archivos tocados** — `git diff
  --name-only main...HEAD`, estados **A+M+D+R** (añadidos, **modificados**, borrados, renombrados): es
  docs-only **solo si TODOS** son docs (`.md`/ADR/spec). **NUNCA** clasificar por "no toca código
  productivo" de oídas: un PR que **MODIFICA código** (sin añadir archivos) **NO** es docs-only y
  **debe** pasar por los gates normales de código.
- **Recursos numerados** (ADR `NNNN`): el coordinador los **asigna al despachar** para evitar colisión
  entre carriles en vuelo (M7) — asignación y curación post-merge en
  `references/05-multicarril-merge-order.md` ("Renumeración de recursos numerados").
- El resto del pipeline (relevo literal, STOP-AUDIT = commit nuevo con sha real [B10], entrega
  draft + HANDOFF) **se mantiene igual**. El merge y CodeRabbit NO son de este canal (v6.0):
  para docs-only, el code-audit del artefacto (ADR/spec) ES el gate fuerte de esta estación.

## 8. Ruta directa / release-to-lead (multi-repo)

Dos situaciones sacan un encargo del pipeline normal de esta estación:

- **Onboarding de un repo nuevo a la fábrica (ruta directa)**: la entrega NO es un draft para el
  Mergeador (que aún no opera ese repo) — es un **PR normal** con los **gates corridos y sus
  resultados en el BODY** (comando + exit code, verificables), sujeto a **doble spot-check**
  (coordinador + CEO/lead) y **merge del CEO**. El canal NO mergea nunca, tampoco aquí.
- **Release-to-lead (liberar un canal con trabajo en vuelo al lead)**: antes de liberar, dejar en
  el issue Linear el **plan vigente + los FLAGS/estado VERBATIM** (comentario vía
  `tco_linear_gql`/`commentCreate`), no un resumen interpretado — el lead retoma con el estado
  exacto, sin re-derivar. Un canal liberado sin ese volcado es un canal perdido para el retome.

Registro de modelos: `~/.config/talent-channel-operation/modelos.conf` del usuario del rol; CEO y plan/fallback usan Opus vigente, los demás roles y salud Sonnet vigente. Resolver tras acreditar Claude con `talent-channel-operation/scripts/resolver-modelos.sh`.
