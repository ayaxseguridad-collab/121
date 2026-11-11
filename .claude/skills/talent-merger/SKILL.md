---
name: talent-merger
description: >
  Mergeador — coordinador de la 2ª estación de la fábrica (ADR-0043): consume la cola de
  PR DRAFT + HANDOFF de los canales de producción, corre CodeRabbit como ÚNICO consumidor
  (CLI y App), refactoriza en canales propios los conflictos MECÁNICOS (rebota SIEMPRE el
  fix FUNCIONAL al productor), y mergea 24/7 con gates AND verificables. Rebase +
  renumeración de slots contra el ledger real, apply post-merge + advisors, Done vía
  closes. El CLI limpio AUTORIZA el merge — con CLI aprobado no se gasta App (solo
  fallback); bounce-to-pool ante defecto de diseño; destructivas → GO del lead. 5
  estaciones (M1-M5) con drenaje paralelo. Token-only. «Carril» = «canal».
  Triggers: "mergeador", "merger", "estación de merge", "consumir drafts",
  "validar handoff", "HANDOFF", "intake de PR", "superficie sensible", "ruta A/B",
  "CLI autoriza el merge", "gates AND", "renumerar slot", "slot de migración",
  "bounce to pool", "refactorizar findings", "canales de refactorización", "CR budget",
  "fallback app", "APPROVED at head", "merge-gate", "encargo", "bundle",
  "label cr-review", "cola de merge".
---

# Talent Merger — Manual de vuelo del Mergeador (2ª estación)

Codifica el protocolo **manual** del Mergeador ([ADR-0043](../../../docs/decisions/0043-fabrica-v2-mergeador-posture-cr.md)):
consumir la cola de **PR DRAFT + HANDOFF** que entregan los canales de producción
(`talent-channel-operation` v6.3), pulirlos con CodeRabbit y fundirlos a `main` 24/7. El
Mergeador es el **único consumidor de CodeRabbit** (buckets CLI y App) y el **único actor
que mergea**; los canales de producción no vuelven a ver su PR (fire-and-forget). **No hay
loop automático**: el Mergeador conduce cada PR a mano, con gates objetivos verificables.

**Versión 1.13** (2026-09-06, TAL-5446 — ref 10 estaciones en paralelo: ventana de merge +
batching por disjunción + suite nocturna, `CEO-LEY-BATCHING-20:18`; detalle en `CHANGELOG.md`
§1.13). Base **1.12** (TAL-5170, 2026-09-02 — 5 estaciones M1-M5 con drenaje paralelo [runners
remotos parametrizados: objetivo, pendiente de `seal-suite.sh`], rebote SIEMPRE del fix
funcional al productor, code-gates de money-path; detalle en `CHANGELOG.md` §1.12). Base
**1.11** (TAL-5158, 2026-09-02 — ref 09 trenes; detalle en `CHANGELOG.md` §1.11). Base **1.10**
(TAL-3569, 2026-07-31 — codificación de reglas de guardia 28/29-jul; detalle en `CHANGELOG.md`
§1.10). Base **1.9** (TAL-3394, 2026-07-23 — reconciliación guardia 15-16 jul: preaviso de
draft [«pre-claim» queda reservado al grep del flock], HOLD de host para mantenimiento, PR
bounceado huérfano base-stale; compact-60 canónico en `talent-context`; detalle en
`CHANGELOG.md` §1.9).
Base **1.8** (TAL-3267, 2026-07-21 — loop issue-craft en la estación; detalle en `CHANGELOG.md` §1.8). Base **1.4** (TAL-2658, 2026-07-12 — ola v3 de fábrica): 3ª vía de findings, PROC-M20,
base_tip acotada, anexo mínimo por repo, closes vs refs, árbol REVOKE-vs-baseline — detalle
en `CHANGELOG.md` §1.4. Base **1.3** (TAL-2288/TAL-2286, 2026-07): gates locales — GitHub Actions queda OFF
(presupuesto agotado + independencia multi-org); el Gate 2 del AND pasa de "required
checks de Actions verdes @head" a **`local-gates=success` @head VERIFICADO contra receipt
propio de la estación** (motor `talent-factory` v2: runners sin credenciales + receipts +
posteo desde la estación — ref 08 nueva). Donde una org no tenga CodeRabbit, la
revisión-de-código del AND la aporta el **code-audit adversarial** (variante TAL-2286).
Base 1.2 (TAL-2273, 2026-07): Gate 4 automatizado —
`scripts/crosscheck-migration-slot.sh <pr>` cruza el `migration_slots` del HANDOFF contra el
diff y el tope real (ledger ∪ origin/main ∪ drafts), sustituyendo el cruce manual de PROC-M14.
Base 1.1 (TAL-2253, 2026-07): consolidación post-piloto (TAL-2234) — escalera CR de
doble identidad como método canónico, protocolo flip-flop, cero ociosidad + compact-60, modo
dual manual/torre. Base 1.0 (TAL-2193): skill fundacional de la Fábrica v2 (spec TAL-2192).
Terminología: **«canal»** es el término canónico; **«carril» es sinónimo histórico de
«canal»** — si alguien dice carril se refiere a canal (los paths/flags existentes con
"carril" no se renombran).

## Quick Orientation

| Propiedad | Valor |
|---|---|
| Qué hace | Procesa la cola de PR draft: HANDOFF válido → rebase + slots → CodeRabbit → refacto de findings → gates AND → merge → apply+advisors+ledger → Done |
| Versión | **1.13** (2026-09-06, TAL-5446 — ref 10 estaciones en paralelo: ventana de merge + batching por disjunción + suite nocturna, `CEO-LEY-BATCHING-20:18`; base **1.12** TAL-5170 — 5 estaciones M1-M5, rebote de fix funcional, code-gates money-path; base 1.11 TAL-5158 — ref 09 trenes; base 1.10 TAL-3569 / 1.9 TAL-3394 — reconciliación guardia: preaviso de draft + HOLD de host + huérfano base-stale; base 1.8 TAL-3267 / 1.4 TAL-2658; ADR-0043) |
| Modelo | `Sonnet vigente` + `/effort high` (CLAUDE.md regla 0, rol Coordinación/Mergeador) — re-verificar tras cada resume/loop/compact: el CLI puede revertir al default |
| Entrada | PR **DRAFT** con comentario **HANDOFF** válido (plantilla `docs/templates/handoff-pr-draft.md`; sin él → rechazo, PROC-M01) — **O**, para un lote cohesivo, **N ramas de tren verificadas** en el git log de un PR padre consolidado (HANDOFF único, no por pieza; ref 09) |
| Salida | PR **merged** + migraciones aplicadas + advisors limpios + ledger confirmado + issues **Done** (vía `closes TAL-N`; con apply escalado/manual → `refs` + `apply-pendiente`, anexo §4) |
| CodeRabbit | **ÚNICO consumidor** de ambos buckets (CLI y App); presupuestos y mecánica del sentinel en `docs/runbooks/coderabbit-cli-pre-pr.md`. **Opcional por org (TAL-2286)**: donde la org NO tenga CodeRabbit (p. ej. sin presupuesto), la revisión-de-código del AND la aporta el **code-audit adversarial** (veredicto GO con nonce, archivado en el PR con run_id + artifact_sha@head). Mecánica real desde 1.7.4 (issue 9011), solo con `revisor=code-audit` (`TCO_REVISOR`): `merge-gate.sh` compone `tco_m8_compose_rev` y `verify-code-audit-go.sh` verifica el registro archivado (`--archivar`) contra el head, el run_id, el autor y la hora, fail-closed; con `coderabbit` el GO no se mira. **⚠ Vía NO recomendable**: sin capa externa de revisión (la mitigación es CodeRabbit) |
| Rutas | **A** CLI limpio (CUALQUIER superficie) → ready SIN label → merge — **el CLI limpio autoriza el merge; con aprobación CLI no se gasta App, nunca** · **B (fallback)** CLI no disponible (rate-limit/caído) → label `cr-review`+ready → App APPROVED@head → merge |
| Escalera CR (método canónico) | v1.1: **CLI-A → App-A → cambio de usuario (CLI-B → App-B) → PROC-M18**; descenso por SEÑAL (~2-3 min sin acuse, no por reloj); capacidad nominal Pro+ 10 CLI+10 App/h POR identidad; pipelining ENTRE PRs; findings NUNCA bajan la escalera (ref 04 §1) |
| Gates AND del merge | (revisión-de-código: CLI-limpio trazable ∨ App APPROVED@head solo-fallback ∨ **code-audit adversarial GO verificado** (`verify-code-audit-go.sh`, solo con `revisor=code-audit`) donde la org no tenga CodeRabbit) ∧ **`local-gates=success` @head verificado contra receipt propio de la estación** (anti-self-report, ref 08) ∧ spot-check disjunción/hot-files ∧ slot de migración sin colisión — fail-closed, verificables por API (ref 02 §7) |
| **Gates LOCALES (TAL-2286/TAL-2288, reemplazan GitHub Actions)** | La fábrica **NO usa GitHub Actions** (budget-independiente, clave multi-org). El gate de tests es el commit-status **`local-gates`**: el motor `talent-factory/scripts/run-local-gates.sh` v2 corre **UN gate por invocación** (`--gate <gate-id>`) en un **worktree desechable dentro de un RUNNER sin credenciales** (perfil minimal, hoy vibe-channel-85..88), con checkout interno + assert `HEAD == --sha`, y escribe un **receipt parcial JSON**; la **estación del Mergeador** asigna gates/shards por `run_group` impredecible, sella los receipts y postea con `talent-factory/scripts/post-local-gates.sh <run_group> <owner/repo> <pr>` (agregación fail-closed + anti-reducción del registro de shards). **Anti-self-report**: jamás declarar verde sin corrida real del head exacto; cada push re-corre. `local-gates=failure` → refacto (1 ronda → 1 re-run), nunca bypass. `gh api` manual = SOLO break-glass trazado. Doctrina completa: **ref 08** + runbook `docs/runbooks/local-gates.md` |
| Findings | Conflicto **MECÁNICO** (imports, vecindad, renumeración de slot) → canal de refactorización propio (dev + auditor, contra los invariantes del HANDOFF); fix **FUNCIONAL** (lógica, contrato, semántica) → **se REBOTA SIEMPRE** al productor (ruling CEO-ADJUD-1989, 2026-08-29, TAL-5170); 3ª vía (test-quality/sistémico no explotable) → follow-up + merge, nunca refacto ni bounce (ref 05) |
| Pipeline | Drenaje **paralelo** entre las 5 estaciones (M1-M5); solo el ACTO de merge se serializa — **por GitHub mismo** (`strict=true`, un merge sobre base stale es rechazado por la API, no landea corrompido, ref 02 §3), no un lock propio — la preparación (intake, rebase, CR, refacto) avanza en paralelo, cada estación con su propio slot (ref 02 §3, disciplina sin cambio, ahora 5 instancias en paralelo en vez de 1; el head local por estación es especulativo — `main` sigue global a las 5, un merge de cualquiera invalida a las otras 4). **Los PRs con migraciones NO son la excepción a "cualquiera mergea"**: la Management API no tiene equivalente al `strict=true` de GitHub, así que un token, `SLOT-CLAIM`, sobre el mismo flock evita que dos migraciones compartan número de slot, y OTRO gate, `APPLY-RUN`/`APPLY-DONE`/`APPLY-FAILED` (gana el PRIMER RUN tras el último cierre válido, nunca el más reciente — ronda 15 BLOQUEANTE), serializa la EJECUCIÓN de PROC-M13 (que aplica el gap COMPLETO `main − ledger`, no "mi slot" — slots distintos NO pueden ejecutarse en paralelo sin colisionar, ronda 13 BLOQUEANTE; una dependiente además verifica el ledger de la que depende, ref 06 §2 punto 5) — **CUALQUIER estación (M1-M5) mergea Y aplica** PRs con migraciones, sin estación fija ni turno, como una sola operación indivisible en el mismo turno (nueve diseños previos fallaron auditoría o no describían lo que la fábrica hace — flock local, tokens async, árbitro humano, GO-del-lead, merge-ahora/apply-después, SOLO M1, slots-distintos-en-paralelo-sin-gate, publicar-releer-sin-ganador, más-reciente-gana — rondas 5-15; ratificado por el CEO en la ronda 12, `CEO-DOCTRINA-MIGRACIONES-5-ESTACIONES`); quien mergea, aplica — nunca se delega ni se difiere; una colisión de slot se resuelve renumerando al siguiente libre (ref 01 §2) — **VENTANA DE MERGE Y BATCHING (TAL-5446, ref 10)**: **N estaciones drenan en paralelo; los merges se agrupan por VENTANA** — la abre quien postea verde (`ventana abierta @<tip>`, 15 min) y admite piezas verdes sobre ESE tip. **Fail-closed: el batching está DESACTIVADO (ruling `CEO-RULING-MAJOR4-T05-BATCHING-OFF-PARALELA-NO-ES-BATCHING-1625`) — CADA PR corre su suite COMPLETA sobre su propio head, disjunto o no; fundir por disjunción medida NO es una vía disponible.** Cada merge lleva sello `M*-MERGED` **sin** la línea `batching: disjunto de [...]`, que no se emite; **si trae migraciones**, el apply va en el mismo turno (gate de Done) — **sin migraciones**, se verifica Done vía `closes` y se libera el slot sin apply (ref 02 §8: «Sin migraciones → verificar Done de los issues (via `closes`) y liberar el slot»). Salvaguarda: **suite nocturna completa sobre el tip de `main`, 03:00 CDMX**, sellada `NOCTURNA-<fecha>-<sha>`; rojo main-borne → incidente y **batching suspendido**. Excluidos (van solos y con suite propia): destructivas · money-path SEV · `TF_INPUTS_UNIVERSAL`. Trenes padre = vía preferente. **⚠ BLOQUEANTE ABIERTO**: la ley exige un sello «con las cuatro cosas», un «agregador #50» y una nocturna de «37 gates, procedencia, runners a cota 4» que **NO están definidos en ninguna parte** — hoy **la evidencia de batching NO es auditable**; leer `references/10-estaciones-en-paralelo.md` **§0** ANTES de operar la ventana. **Texto literal y fragmentos: `references/10-estaciones-en-paralelo.md`** (`CEO-LEY-BATCHING-20:18`) |
| Destructivas | Migración destructiva declarada (o detectada) → **GO explícito del lead SIEMPRE** |
| Post-merge | **Si trae migraciones**: apply + advisors + confirmación de ledger en el MISMO turno — es GATE de Done, no cortesía (ref 06 + anexo). **Sin migraciones**: verificar Done vía `closes` y liberar el slot, sin apply (ref 02 §8) |
| Conexión | **Token-only, NO MCP**; los canales de refactorización son contenedores Incus operados por tmux (aprovisiona `talent-channels`, perfil Mergeador) |
| Modo de operación | **Dual**: (manual) el Mergeador corre en una terminal suelta y el lead hace de relay; (Torre) su sesión vive en tmux `torre-mergeador` y la opera el Orquestador con capture-pane/send-keys. La Torre es optimización, no dependencia — runbook `docs/runbooks/torre-de-control.md` |

## Según repo (leer el anexo ANTES de operar)

| | Academia Ejemplo |
|---|---|
| Anexo | el anexo adjudicado (`TCO_ANEXO_FILE`) |
| Required check (fuente: `scripts/setup-branch-protection.sh`) | **`local-gates`** (único; TAL-2286/TAL-2288 — sustituye a los 6 contextos de Actions: `validar-flujo-pr` · `validar-build` · `db-guards` · `e2e-ola3` · `integration` · `e2e-pagos`; inventario check→gate en el anexo §2 y en `docs/runbooks/local-gates.md`) |
| Runners de gates | vibe-channel-85..88 (identidad A, perfil RUNNER minimal — ref 08 §2) |
| Pools por estación (M1-M5) — **OBJETIVO, pendiente de cableado** (ver ref 08 §2/§5) | M1/M2 → host · M3 → black-omega (`omega.tailnet.example`) · M4 → pendiente de reubicar · M5 → black-alpha (`alpha.tailnet.example`). Ley de flota: SOLO host+Alpha+Delta(`delta.tailnet.example`)+Omega — `vibecoder-01/02` PROHIBIDOS; **`black-fenix` = IA local, NO tocar**. `seal-suite.sh` sigue hardcodeado a `--runner-user runner --runner-repo /home/runner/repo` (fix = hijo 6 de TAL-5160, fuera de alcance aquí) — esta fila describe el DESTINO, no el comportamiento actual del script |
| Post-merge | **Si trae migraciones**: PROC-M13 (apply Management API) + PROC-M15 (advisors) + ledger. **Sin migraciones**: verificar Done + liberar el slot, sin apply (ref 02 §8) |

La doctrina de este skill es de la ESTACIÓN, no de un repo: Academia Ejemplo es el anexo
maduro; fuera de TA la estación opera **vía el MOTOR** (`talent-factory`) y exige el
manifiesto del repo (abajo). La propagación del anexo a Bootcamp Cripto es follow-up
(ver Out of scope).

### Anexo mínimo por repo (onboarding multi-repo de la estación)

Antes de operar un repo NUEVO, levantar estos cuatro puntos (Ev: F2 #19-#22 — Done falso —
y talent-factory #7):

- **(a) Branch protection REAL, leída de la API** (no asumida): `conversation-resolution` y
  `linear-history` son muros APARTE del required check (un AND verde puede seguir bloqueado
  por un thread sin resolver); un repo **sin protección** se mergea por `mergeable` + CR —
  el AND concreto **difiere por fábrica** y se lee del manifiesto/protección, no se copia
  de TA (el de F2 es de 4 términos con spot-check del orquestador — verificar en su
  manifiesto, no citable desde aquí).
- **(b) PROCEDENCIA del required check**: un **CheckRun homónimo de Actions residual**
  (workflow viejo aún activo) puede satisfacer la protección SIN cadena sellada — distinguir
  SIEMPRE el commit-**status** del motor (`/commits/<sha>/status`) de los **check-runs**
  (`/check-runs`); si existe el homónimo de Actions, retirarlo (fix tipo TAL-2394: desactivar
  el workflow + segunda identidad del contexto).
- **(c) Régimen de apply**: si el apply de migraciones NO es del Mergeador en el mismo turno
  (F2 = CEO, F4 = manual) → **`refs TAL-N`, NUNCA `closes`** + label `apply-pendiente`
  (anexo §4: el `closes` produciría Done falso).
- **(d) Intake del motor**: `export TF_MANIFEST=<ruta ABSOLUTA>` + `--manifest-sha256` — una
  ruta **relativa se ignora en silencio** y los gates caen al default npm (parecen correr y
  no gatean el stack real).

## Checklist de vuelo (por PR)

### 0 · Foto de la cola

- [ ] `gh pr list --draft --json number,title,headRefName,createdAt` + prioridad de la cola
      (la cura el Orquestador: bugs > mes-objetivo > resto; agrupar por hot-file) → ref 01

### 1 · Intake — validar el HANDOFF

- [ ] `bash scripts/verify-handoff.sh <pr>` (raíz del repo) — exit 0 o **rechazo** → **PROC-M01**
- [ ] Clasificar superficie: verificar la declaración del HANDOFF contra el diff real
      (`gh pr diff <pr> --name-only` vs path-patterns de ref 03) — el Mergeador **verifica, no confía**

### 2 · Rebase + slots de migración

- [ ] Rebase sobre `main` fresco; conflictos mecánicos los resuelve el canal de
      refactorización, conflictos de DISEÑO → bounce (ref 05)
- [ ] Si hay migraciones: renumerar slots contra el **ledger real de prod** (ref 06 + anexo
      PROC-M14) — nunca contra `main` a secas
- [ ] `destructive: true` en el HANDOFF (o detectada en el diff → **PROC-M17**): pedir GO
      del lead ANTES de seguir

### 3 · CodeRabbit (budget-aware)

- [ ] **Pre-CR (doctrina lead 2026-08-29)**: verificar que el HANDOFF declara la
      **convergencia interna a CERO×2** del canal productor (gate de convergencia de
      `talent-channel-operation` Fase C); sin evidencia → rebote al productor SIN gastar
      ronda de CR
- [ ] CR-CLI sobre la rama (`bash scripts/cr-review.sh` desde el clon del canal del
      Mergeador) — programar contra el bucket, no en ráfaga → ref 04
- [ ] Limpio → ruta A (el CLI limpio autoriza el merge, ref 02 §6) · findings → paso 4 ·
      rate-limit → ruta B fallback App → **PROC-M18** si la cola se atasca
- [ ] **CORTAFUEGOS DE RONDA 2 (doctrina lead 2026-08-29)**: si la ronda 1 de CR trae
      **>2 findings reales**, NO se entra al loop refacto→re-CR ronda a ronda — se para el
      forward, el productor repite su auditoría adversarial COMPLETA (converger a CERO×2)
      y solo entonces se re-forwardea a CR. Métrica objetivo: findings reales en ronda 1
      **≤1**; >2 = incidencia de proceso del canal productor (sellar al bus). En trenes,
      el pase del ensamblador es sobre el bundle INTEGRADO (los findings cross-pieza salen
      del ensamblaje, no de las piezas)

### 4 · Findings → clasificar ANTES de despachar (TAL-5170)

- [ ] Clasificar el finding en UNA de tres ramas (ref 05 §1/§3) — el default YA NO es
      refactorizar:
      - **Conflicto MECÁNICO** (imports, vecindad, renumeración de slot) → micro-encargo a
        canal propio (dev implementa, auditor verifica CONTRA los invariantes del HANDOFF) →
        push → volver al paso 2 (re-gate)
      - **Fix FUNCIONAL** (lógica, contrato, semántica) → **se REBOTA SIEMPRE** al productor,
        la estación NO lo implementa — parquear PR + re-entrada por **Decisión 6** del
        Orquestador (issues del bundle → Backlog + label `bounced`; NUNCA issues nuevas) →
        **PROC-M16**
      - **3ª vía** (test-quality/harness o sistémico repo-wide no explotable) → follow-up en
        Linear + merge, sin refacto ni bounce (regla dura 5)
- [ ] Post-bounce: ¿pudo la issue de origen prevenir este defecto? Si sí → comentar gap
      en Linear con label `issue-craft-gap` (ref 05 §4 PROC-M16)

### 5 · Ready + review según ruta

- [ ] **Ruta A** (CLI limpio — cualquier superficie): verificar que NO queda un label
      `cr-review` heredado (de un fallback previo o puesto a mano) y borrarlo si existe
      (`gh api -X DELETE .../issues/<n>/labels/cr-review` + re-lectura) ANTES de
      `gh pr ready <pr>` — con label residual el ready dispararía una review del App y
      rompería el contrato «CLI limpio = sin consumo del App»
- [ ] **Ruta B** (SOLO fallback — CLI rate-limited/caído): label `cr-review` por REST
      verificado ANTES de ready → `gh pr ready` → esperar **APPROVED@head** del App (mudo
      tras rebase → **PROC-M04**; spending cap → **PROC-M05**)

### 6 · Gates AND del merge

- [ ] Verificar los 4 gates por API (comandos en ref 02 §7); cualquier señal débil o
      ambigua = FAIL (fail-closed) — el AND no se negocia
- [ ] **PREFLIGHT DE RUNNERS antes de lanzar cualquier corrida de gates (doctrina lead
      2026-08-29)**: (a) stacks Supabase de los runners FRESCOS (>1h vivos → stop/start o
      reset; una suite entera se perdió por stacks de 8h), (b) `/home/runner/repo` es repo
      git SANO en cada runner (`git -C /home/runner/repo rev-parse --git-dir`), (c) disco
      y sin procesos zombis de corridas previas. Sin preflight verde NO se lanza. Los
      waiters de fin-de-corrida usan señal **FILE-BASED sobre receipts** — NUNCA `pgrep`
      (auto-match entre waiters = deadlock, 3 casos el 29-ago)
- [ ] Gate 2 = `local-gates=success` @head **con receipt propio de la estación** para ese
      `run_group` (ref 08 §6) — el status solo, sin receipt conocido, NO es evidencia
- [ ] `merge-gate.sh` de `talent-channel-operation` como verificador de apoyo en la ruta B
      de fallback (ver Tooling compartido)

### 7 · Merge

- [ ] **Para PRs CON migración, ANTES de mergear — el gate se RECLAMA aquí, no solo se
      comprueba (TAL-5170, ronda 25, BLOQUEANTE — corregido: un releer-y-luego-mergear
      sigue siendo check-then-act sin reserva; dos estaciones pueden ver el gate libre y
      mergear las DOS antes de que ninguna reclame nada, acumulando en `main` dos
      migraciones sin que ninguna haya empezado su apply)**: crear `CLASS_FILE`
      (`mktemp`, misma razón que ronda 21: precondición local barata ANTES de tomar un
      recurso compartido) y un `<nonce>` único por intento (`RUN_NONCE`, ronda 27, BLOQUEANTE:
      `#<PR>`+`<ISO8601>` acreditan FORMA, no unicidad) y publicar el `APPLY-RUN` real —
      `# APPLY-RUN [<estación>] #<PR> <ISO8601> <nonce>` — con el mismo protocolo
      publicar→RELEER→confirmar de siempre (ref 01 §2 punto 4: localizar el ÚLTIMO cierre
      válido correlacionado por `run_id` — un `APPLY-RUN` sin cierre es el titular, sea de
      ESTA estación o de otra, nunca solo "de otra" — y si tras él hay un `APPLY-RUN` activo
      o un `APPLY-FAILED` sin `APPLY-DONE` posterior para ese gap — agnóstico de categoría,
      ver nota abajo — esperar su resolución antes de reintentar el claim). Solo cuando el
      claim propio gana (primero tras el último cierre), mergear. El run_id (`#<PR> <ISO8601>
      <nonce>`, único por el `<nonce>`) identifica el turno aunque PROC-M13 se invoque más
      adelante — el claim cubre TODA la ventana merge→pull→apply como una reserva única, no solo
      el instante de invocar
      PROC-M13. Sin esto, el merge que sigue queda en `main` con su apply pendiente detrás
      de un gap ajeno todavía roto, la misma ventana "`main` por delante de prod" del diseño
      (5) ya rechazado (ref 01 §2).
- [ ] `gh pr merge <pr> --squash --delete-branch --match-head-commit <head-verificado>` — **con
      el gate `APPLY-RUN` YA ganado (arriba), este `gh pr merge` corre DENTRO del turno
      reservado. Un rc ≠ 0 del cliente NO prueba que GitHub no mergeara (la respuesta puede
      perderse tras el efecto remoto; `--delete-branch` es otra op post-merge) — ronda 27,
      BLOQUEANTE: ANTES de cerrar, RECONCILIAR el estado autoritativo con
      `gh pr view <pr> --json state,mergedAt,mergeCommit`:
      · `mergedAt`/`state=MERGED` → el merge OCURRIÓ: conservar el MISMO turno (mismo `<nonce>`),
        NO cerrar, continuar a pull → runbook → apply («cliente con error» ≠ «no mergeado»).
      · confirmado no-mergeado (`state=OPEN`, `mergedAt` nulo — BEHIND o `--match-head-commit`) →
        `TRANSITORIO` en `CLASS_FILE` + `publish_close`, liberar; recuperar con `update-branch` +
        re-ganar el gate (`APPLY-RUN` nuevo, `<nonce>` NUEVO) + reintentar.
      · INDETERMINADO (no se puede confirmar el estado) → FAIL-CLOSED: NO liberar la reserva,
        escalar al CEO/Orquestador. «No sé» ≠ «no ocurrió».
      Tras un no-mergeado CONFIRMADO, NUNCA dejar el gate abierto esperando el timeout de 30 min
      (ese timeout es para estación MUERTA); un INDETERMINADO se escala en el acto — ref 01 §2
      "Turno reservado = un cierre en TODA vía de salida"**
- [ ] **La escritura sobre `main` es serializada** —no se funden dos cosas a la vez—, pero eso
      **no es «un solo PR por turno»**: dentro de una **ventana** abierta sobre el mismo tip
      entran varias piezas. Lo que la ventana **NO** autoriza: fundir una pieza **sin su suite
      completa** por haberla medido disjunta de otra. **Instrucción fail-closed: el batching está
      DESACTIVADO (ruling `CEO-RULING-MAJOR4-T05-BATCHING-OFF-PARALELA-NO-ES-BATCHING-1625`), y CADA PR corre su suite
      COMPLETA sobre su propio head — siempre, disjunto o no.** Con intersección no hay nada que
      decidir: no había atajo que tomar. Ley, literal y el método que queda a la espera:
      `references/10-estaciones-en-paralelo.md`
- [ ] Cada merge lleva su sello `M*-MERGED` **sin** la línea `batching: disjunto de [...]` —esa
      línea **no se emite** mientras la puerta esté cerrada (ruling de arriba)—; **si trae
      migraciones**, el apply va en el mismo turno — **sin migraciones**, verificar Done y liberar
      el slot sin apply (ref 02 §8); el paso 8 se cierra por PR, no bloquea la ventana
- [ ] **GUARD FAIL-CLOSED — el batching está DESACTIVADO** (ruling
      `CEO-RULING-MAJOR4-T05-BATCHING-OFF-PARALELA-NO-ES-BATCHING-1625`). **No se sella ningún
      merge con `batching: disjunto de [...]` y no se usa la ruta `gh pr merge` para agrupar**,
      hasta que existan los contratos que la propia ley invoca: el sello «con las cuatro cosas»,
      el agregador #50, la nocturna de 37 gates y el procedimiento de bisección. Hoy **no están
      definidos en ninguna parte**, así que la evidencia de batching **no es auditable** — y una
      evidencia que no se puede auditar no autoriza un merge. En la duda, **no se batchea**
- [ ] **La ventana paralela NO es batching, y sigue operativa**: cada unidad funde **con su propia
      suite completa sobre su propio head**; lo único paralelo es **el reloj**. Eso es lo que el
      guard de arriba NO apaga. Leer `references/10-estaciones-en-paralelo.md` **§0** antes de
      operar la ventana
- [ ] **Qué serializa el ACTO de merge entre las 5 estaciones (M1-M5, TAL-5170)**: NO un lock
      de aplicación nueva — es GitHub mismo, vía branch protection `strict=true` (ref 02 §3):
      un PR intenta mergear sobre una base que YA no es el tip real de `main` (porque otra
      estación mergeó primero) es rechazado por la API de GitHub como BEHIND, no landea
      corrompido — un rechazo BEHIND es un no-mergeado CONFIRMADO por GitHub (no ambiguo), así que
      la estación afectada, con el gate `APPLY-RUN` YA en mano (ronda 25: el claim es PRE-merge, el
      BEHIND ocurre DENTRO del turno reservado), tras reconciliar (`gh pr view` confirma
      `state=OPEN`, ronda 27) publica su cierre `APPLY-FAILED … TRANSITORIO` para liberar el gate
      (nunca lo deja abierto — ref 01 §2 "Turno reservado = un cierre en TODA vía de salida"),
      luego re-lee `mergeStateStatus`, hace `update-branch` y re-gatea con un `APPLY-RUN` nuevo
      (nonce NUEVO, nunca reutilizando el run_id ya cerrado) antes de reintentar. Esto cubre la
      colisión GIT (dos merges simultáneos); la
      colisión SEMÁNTICA entre PRs relacionados la cubren el Gate 3 (spot-check
      disjunción/hot-files) y la guarda cruzada de invariantes entre encargos (ambos YA
      doctrina, sin cambio por las 5 estaciones).
- [ ] **Para PRs SIN migración**: el siguiente PR de la cola NO espera al paso 8 — su
      preparación (pasos 0-6) avanza en paralelo en otra estación mientras esta cierra el
      post-merge.
- [ ] **Para PRs CON migración (CUALQUIER estación, ref 06 §1)**: el merge+apply a prod (pasos
      7-8) NO se resuelve con un lock, un protocolo async de tokens, un árbitro humano con
      handoff bilateral, una excepción de urgencia tipo GO-del-lead, fijando una sola estación
      como aplicadora, dejando que slots distintos apliquen en paralelo sin un gate de
      ejecución, publicando/releyendo sin un desempate explícito, ni desempatando por
      recencia — los nueve se intentaron y fallaron auditoría o no describían lo que la
      fábrica hace (co-localización no verificada, TOCTOU de relectura, revocación no atómica,
      extensión no autorizada de la excepción única de regla 24, `main` por delante de prod,
      cuello de botella no decidido, PROC-M13 re-aplicando el mismo slot, dos `APPLY-RUN` en
      punto muerto, "más reciente gana" sin revocar al que ya corría — rondas 5-15).
      **CUALQUIER estación (M1-M5) mergea Y aplica**, como una sola operación indivisible en
      el mismo turno (ref 01 §2 "Apply de migraciones: protocolo SLOT-CLAIM del bus"),
      ratificado por el CEO en la ronda 12 (`CEO-DOCTRINA-MIGRACIONES-5-ESTACIONES`).
      `SLOT-CLAIM` (publicado en el flock, con acceso DIRECTO obligatorio — no vale el espejo
      remoto — y confirmado por relectura antes de pushear) garantiza que dos migraciones
      NUNCA compartan número de slot; **no basta para serializar el apply** — PROC-M13 (anexo
      §4) aplica el gap COMPLETO `main − ledger`, no "mi slot", así que ANTES de invocarlo la
      estación adquiere el gate `APPLY-RUN`/`APPLY-DONE`/`APPLY-FAILED` (mismo flock; gana el
      PRIMER `APPLY-RUN` tras el último cierre válido, NUNCA el más reciente — un RUN posterior
      antes de ese cierre es VOID para todos los lectores por definición; los cierres repiten
      el run_id `#<PR>`+timestamp+`<nonce>` EXACTO del RUN que cierran, con el `<nonce>` (UUID
      único por intento) como identidad — ronda 27). Un wrapper EXTERNO protege TODA
      la secuencia con `set +e`/`set -e` — no solo bajo `pipefail`, ni siquiera SIN `pipefail`
      basta si `tee` mismo falla (disco lleno): `set +e; bash proc-m13.sh 2>&1 | tee "$LOG";
      rc="${PIPESTATUS[0]}"; set -e` — leer `PIPESTATUS` ANTES de reactivar `-e`, porque `-e`
      solo también lo pisa a `0`. Publica por código de salida con la categoría YA calculada,
      leyendo `PROC_M13_CLASS_FILE` — un `mktemp` propio del wrapper, exportado ANTES de
      intentar publicar `APPLY-RUN` siquiera (ronda 21, MAYOR: crearlo DESPUÉS de ganar el
      gate deja el token huérfano si `mktemp` falla), fuera del `$WORKDIR` que PROC-M13 borra
      al salir; NUNCA `$LOG` (PROC-M13
      interpola cuerpos HTTP remotos en sus propios mensajes de error, y un tercero podría
      forjar un prefijo TRANSITORIO ajeno — ronda 20, BLOQUEANTE; PROC-M13 declara su clase con
      un literal fijo en su propio canal estructurado, nunca derivado del log): `exit 0` →
      `APPLY-DONE`; cualquier otro código →
      `APPLY-FAILED [<estación>] #<PR> <ISO8601> <nonce> <CATEGORIA>`, `<CATEGORIA>` ∈
      TRANSITORIO/ESCALAR — SOLO estas dos, nunca DEFECTO automáticamente. La recuperación NO
      es siempre "migración nueva": TRANSITORIO (lecturas de solo-consulta — token, Vault,
      `fetch_ledger`, advisors) solo pide corregir la causa y publicar un `APPLY-RUN` normal;
      ESCALAR (el POST que SÍ muta, Paso 1 de contenido — una migración nueva no desbloquea
      una pendiente rota —, divergencia, drift, advisors con `nerr` real, o cualquier mensaje
      sin `class` explícito — default fail-closed) exige una Señal de quiescencia REAL —
      consulta a `pg_locks` sobre el ledger vía el mismo endpoint que `fetch_ledger`, no una
      ventana de tiempo del cliente — antes de decidir. PROC-M13 adquiere ese lock
      EXPLÍCITAMENTE, `lock table ... in exclusive mode;`, INMEDIATAMENTE tras `begin;` —
      ANTES del DDL de la migración, no solo en el `insert` final — para que la señal cubra
      TODA la transacción, no solo su último instante (ronda 20, BLOQUEANTE: antes, un DDL
      largo en curso podía leer lock-count `0` con la mutación TODAVÍA viva). **Conteo `0` NO
      demuestra que ningún POST esté a punto de pedir el lock** (ronda 21, BLOQUEANTE:
      `pg_locks` solo ve lo YA solicitado, nunca lo que un POST aceptado-pero-aún-no-ejecutado
      pedirá después) — el cierre real es que, tras adquirir el lock y ANTES del DDL, el
      payload se revalida DENTRO DE LA MISMA TRANSACCIÓN contra el ledger (`do $$ ... if
      exists (select ... where version = '<TS>') then raise exception ...; end $$;`):
      Postgres serializa el ACCESO al lock, así que un retry que lo gane DESPUÉS de un POST
      antiguo encuentra la versión ya aplicada y se aborta solo, sin repetir el DDL — deja de
      importar quién llegó primero. DEFECTO
      CONFIRMADO solo se alcanza SI, durante esa investigación, se confirma que la terna
      `schema`+`name`+`type` de `.metadata` (las TRES presentes, fail-closed si falta alguna)
      del objeto flageado por advisors coincide con un objeto que el investigador LEE en el
      `.sql` aplicado (paso HUMANO deliberado, no un regex — ronda 20, MAYOR) — recién
      entonces exige `APPLY-RECOVERS` con identidad verificada (SHA de merge
      real vía `gh pr view <PR>` SIN `#`, `git merge-base --is-ancestor`, diff que AÑADE — por
      `status`, con `--paginate` y un check fail-closed, no solo presencia — un fichero en
      `supabase/migrations/`, HANDOFF que cite el PR fallido — nunca un `git log --since` a
      solas), y el siguiente `APPLY-RUN` DEBE llevar EXACTAMENTE el `<nonce-nuevo>` citado por el
      `APPLY-RECOVERS` —y el `<nonce-fallido>` DEBE ser el nonce del `APPLY-FAILED` recuperado—, no
      basta compartir `#<PR-nuevo>` (ronda 29, BLOQUEANTE: transportar el nonce no es vincularlo);
      ambas igualdades las comprueba la ESTACIÓN al publicar —comprobación HUMANA, como las demás
      condiciones de identidad; NO hay gate ejecutable que las imponga, y el ratchet que las
      protege acredita presencia, no fuerza normativa (residuo acotado y declarado en ref 01).
      Si aparece MÁS DE UN `APPLY-RECOVERS` para el mismo `#<PR-nuevo>`, o hay duda sobre si ya
      se consumió, la estación **escala en vez de ejecutar**: la cardinalidad y el consumo son un
      hueco de contrato ABIERTO elevado al lead (TAL-5296, sección «Límite conocido» de ref 01).
      **Que la autorización sea de otra estación NO escala** (CR sobre v18, ronda 30 ya lo
      resuelve): con el GO transferido, la estación NOMBRADA SÍ ejecuta; quien no es la titular
      —ni original sin transferencia, ni nombrada con ella— simplemente cede, sin molestar al
      CEO/Orquestador por un caso que el contrato ya decide —
      ref 01 §2 punto 4, tabla de recuperación. Una migración que depende del cuerpo post-apply de otra del mismo gap (ref
      06 §2 punto 5) además verifica CONTRA EL LEDGER, no solo el `MERGED` de la otra, antes de
      foliar su `CREATE OR REPLACE`. Enumeración COMPLETA contra ledger ∪ `origin/main` ∪
      TODOS los PRs abiertos: `--limit` alto contrastado ÚNICAMENTE contra un recuento
      AUTORITATIVO (`gh api graphql` `issueCount` — ninguna otra alternativa sirve de
      contraste, ronda 13), nunca el default de 30 sin contrastar (ref 01 §2). Sin claim no se
      pushea, y un claim ajeno vivo sobre el mismo slot es colisión → renumerar al siguiente
      libre. Quien mergea, aplica: no se delega ni se difiere para después. El slot de merge de
      un PR CON migración no libera para el
      siguiente PR CON migración hasta cerrar el paso 8 completo (gate de Done, regla dura 8;
      un apply fallido bloquea el slot hasta cerrar el gap, ref 06 §3).

### 8 · Post-merge (gate de Done)

- [ ] **Si trae migraciones**: apply + advisors + confirmación de ledger en el MISMO turno
      (ref 06 + anexo PROC-M13/M15). **Sin migraciones**: no aplica — ver siguiente viñeta
- [ ] Verificar Done de los issues del encargo (los cierra `closes TAL-N` al mergear);
      HANDOFF y PR quedan como evidencia. **`closes` presupone apply-del-Mergeador en el
      MISMO turno**: con apply escalado/manual (otras fábricas, GO pendiente) el body lleva
      `refs TAL-N` + label `apply-pendiente` y el Done se produce tras confirmar el apply
      (anexo §4 — TAL-2643: `closes` ahí = Done FALSO)

### 8-bis · Destilado de findings (analítico, reintentable, no bloqueante)

Después del paso 8, **fuera del gate de Done**: el Mergeador cruza entre PR los findings
`critical|major` de CodeRabbit (ledger del CLI e hilos inline del App) y emite CANDIDATOS a
gotcha. Es analítico y reintentable; un fallo suyo es **no bloqueante**: no retiene el Done, no
libera ni retiene el slot y nunca se convierte en bounce.

- [ ] `bash talent-merger/scripts/distill-findings.sh --limit <N> --markdown` (`--limit` es
      obligatorio; `--since <ISO>`, `--pr <n>` y `--dry-run` acotan o ensayan). Escribe
      `.claude/.gotcha-candidates.jsonl` (un candidato por línea: `candidate_key` estable,
      `count` = vehículos distintos —PR; la rama si no resuelve—, `waived`, `sugerencia_regla`) y
      avanza `.claude/.distill-watermark.json` SOLO después de persistir. El fragmento markdown
      (cabecera `### [fecha] título reducido`) sale por stdout.
- [ ] Si falla (rc 3 entrada inválida · 4 persist · 5 lectura externa), deja
      `.claude/.distill-pending.json` con un código enumerado y se **reintenta en el siguiente
      merge**; el watermark no se mueve.

Reglas del paso: **nunca escribe `gotchas.md`** ni memoria alguna (promover un candidato es decisión
humana: la regla de mejora continua pide 3 vehículos distintos); ninguna salida lleva texto crudo
(se sanean rama y título; el cuerpo del finding no se persiste); la ventana es la que retiene el
ledger del CLI (`CR_REVIEW_HISTORY_RETENTION`, 20 por rama: subirla es decisión de la estación).
La métrica refacto-vs-bounce de `references/05-canales-de-refactorizacion.md` §1 sale de los
tokens del flock, no de este paso.

## Reglas duras (invariantes)

1. **Único consumidor de CodeRabbit**: ni canales de producción ni coordinadores de la 1ª
   estación corren CR (CLI o App). Todo el presupuesto lo programa el Mergeador.
2. **Sin HANDOFF válido no hay intake**: `verify-handoff.sh` exit 0 es la puerta; un draft
   sin HANDOFF (o stale) se rechaza con comentario y aviso al coordinador — nunca se
   "arregla en silencio" (PROC-M01). **Excepción — intake de tren (ref 09)**: las N ramas de
   un tren NO llevan HANDOFF por pieza; la puerta es UN HANDOFF consolidado en el PR padre que
   enumera invariantes, superficies y slots de las N piezas — el mismo `verify-handoff.sh`
   sobre ESE comentario único.
3. **El CLI limpio AUTORIZA el merge — siempre, en cualquier superficie** (ruling del lead
   2026-07-08): con aprobación CLI NO se gasta review del App; el App (label `cr-review`
   por REST verificado + APPROVED@head) es EXCLUSIVAMENTE el fallback ante CLI
   rate-limited/caído. La clasificación de superficie se verifica contra el diff (no se
   hereda del HANDOFF) y gobierna el cuidado operativo (regla 7, spot-checks, prioridad) —
   no la ruta de review.
4. **Gates AND fail-closed** (ref 02 §7): (CLI-limpio trazable ∨ App APPROVED@head ∨
   code-audit adversarial GO donde no haya CodeRabbit) ∧ **`local-gates=success` @head
   verificado contra receipt propio** (ref 08) ∧ spot-check disjunción/hot-files ∧ slot
   sin colisión. Señales débiles (checkrun, comment, "review skipped", un status sin
   receipt conocido) JAMÁS aprueban. **El waiver del lead NO es una cuarta vía** de este
   AND: es una **excepción trazada**, régimen idéntico al break-glass de `local-gates`.
   Cada uso exige, escrito en el PR antes del merge: **motivo · SHA exacto · quién
   autoriza**. Un waiver sin los tres campos no autoriza nada, y un waiver previo **no
   sienta precedente** para el siguiente PR (`CEO-GO-GATE1-WAIVER-EXCEPCION-TRAZADA`,
   2026-07-28 14:50:05Z).
5. **Findings se clasifican en TRES ramas — el fix FUNCIONAL se REBOTA SIEMPRE** (ruling
   CEO-ADJUD-1989, 2026-08-29, TAL-5170 — invierte el default previo de esta regla):
   - **Conflicto MECÁNICO** (imports, vecindad de líneas, renumeración de slot): sigue
     refactorizándose en canal propio auditando contra los **invariantes del HANDOFF** (el
     auditor no re-juzga el diseño) — SIN cambio, esto NO es lo que invierte el ruling.
   - **Fix FUNCIONAL** (el finding exige tocar lógica, contrato o semántica, por acotado que
     parezca el diff): **se REBOTA SIEMPRE** al productor — la estación NUNCA lo implementa
     ella misma, aunque sea "una línea". Bounce-to-pool vía PROC-M16 (ref 05).
   - **3ª vía** (Ev #899→TAL-2652/2653, #942→TAL-2655): un finding de **test-quality/harness**
     o **sistémico repo-wide no-explotable** (patrón que atraviesa todo el repo, no introducido
     por este PR, sin ruta de explotación en producto shipped) NO se refactoriza en el PR NI
     rebota → **follow-up en Linear + merge**. Criterio de las tres preguntas: ¿afecta al
     producto shipped? ¿es explotable? ¿es sistémico (pre-existente repo-wide)? — no/no/sí →
     follow-up; cualquier "sí" en las dos primeras → mecánico (refacto) o funcional (bounce)
     según corresponda.
6. **Slots contra el ledger REAL de prod** (no contra `main`): la renumeración y el gap se
   calculan del ledger vivo; ver ref 06.
7. **Destructivas → GO del lead SIEMPRE** (declaradas en el HANDOFF o detectadas en el
   diff), coherente con la regla 24 de CLAUDE.md.
8. **El post-merge es GATE, no cortesía**: **si el merge trae migraciones**, sin apply + advisors
   limpios + ledger confirmado el trabajo NO está Done, aunque el PR esté merged. **Sin
   migraciones**, Done se verifica vía `closes` y se libera el slot sin apply (ref 02 §8).
9. **Disciplina de presupuesto + protocolo flip-flop**: el CR-CLI es no-determinista → ante
   `findings`, re-correr y exigir **mayoría ≥2/3** ANTES de despachar refacto (supersede el
   "tope 1 re-run" de la v1.0); un finding de un único run = waiver documentado, no defecto.
   Capacidad **nominal** (no defensiva): pipelining ENTRE PRs; la cola se programa contra el
   rate real de los 4 buckets, no contra la ansiedad ni contra el pacing degradado (ref 04 §1).
   **Rama de NO-convergencia** (addendum 2026-07-29, caso #1410): *N* corridas con conjuntos
   de findings **DISJUNTOS** y ningún finding que alcance ≥2/3 significan que **el gate no
   converge** — la salida es **waiver documentado + merge**, **NO una corrida adicional**.
   **Anti-patrón explícito: la 4ª corrida** — no desempata (si el detector es no-determinista,
   produce un cuarto conjunto disjunto, no una mayoría) y gasta bucket de CR, irrecuperable y
   compartido por toda la fábrica. El waiver de no-convergencia debe contener: (a) las **3
   corridas citadas** (run_id + su conjunto de findings) demostrando la disyunción, (b) la
   constatación de que **ningún finding alcanzó ≥2/3**, (c) si aplica, el **invariante que
   protege** el código preexistente (p. ej. equivalencia byte-exacta) y por qué los hallazgos
   no los introduce el PR, (d) confirmación de que **los defectos propios reproducibles están
   corregidos** — el waiver cubre el no-determinismo del detector, jamás un defecto real.
10. **El Mergeador jamás re-desarrolla el encargo ni negocia con el productor**: rebota
    (fix funcional o diseño) o pule solo lo MECÁNICO (regla dura 5); el canal de producción
    ya está en otro encargo y no se le reabre el diálogo.
11. **Cero ociosidad + preaviso de draft**: ningún canal ni el slot de merge quedan parados.
    Al liberar → tirar del siguiente PR/encargo por PULL; cola vacía → avisar al Orquestador
    (que mantiene una ola pre-curada). El slot de merge NUNCA espera al refacto: un PR con
    findings sale a un canal y el slot toma el siguiente. **Preaviso de draft**: el
    CEO/Orquestador avisa a la estación ANTES de que el draft aparezca (canal productor en
    gates locales = preaviso listo), para eliminar la latencia draft→claim — la estación
    pre-prepara el slot en vez de descubrir el draft por PULL tarde (detalle en
    `references/01` §4; «pre-claim» a secas sigue siendo SOLO el grep del flock).
    **El claim anticipado se registra con token**: el preaviso invita a reclamar **antes de
    que el PR exista**, así que el claim, por construcción, no puede contener el número de
    PR. Para que sea encontrable se escribe en el flock con el token literal
    `PRECLAIM <issue> <estación>` (p. ej. `PRECLAIM TAL-3452 M2`). El **pre-claim grep busca
    AMBOS**: el número de PR **y** los issue-ID que trae el preaviso — un claim narrado sin
    token no reserva (evidencia: doble claim sobre #1404, 2026-07-28, M2 nombró `TAL-3452`
    sin PR aún y M1 grepeó `1404` sin encontrar nada). **La regla se define por el TOKEN, no
    por el fichero**: bus y flock son el MISMO fichero (`sellar.sh` escribe
    `/tmp/merge-claims.txt` bajo `flock`) — «regístralo en el flock» sin token es un no-op.
12. **Compact-60 en cascada**: al llegar el contexto (del Mergeador o de un canal) al **60 %**, y
    solo en checkpoint limpio → fichero de regreso escrito FUERA de la sesión y VERIFICADO (nunca
    "copiar fuera→`/compact`→pegar" a secas — ese resumen omite el gate) → `/compact` → al volver,
    **paso-0 como primer acto** (supersede el umbral >70 % previo). En modo Torre lo vigila la
    Torre; el contexto de los canales de refacto lo vigila el Mergeador. **Los shells en
    background sobreviven al `/compact`** (T9): los gates lanzados en bg siguen corriendo — al
    volver, re-pollear los pendientes, no re-lanzarlos (doctrina canónica en `talent-context`;
    cascada en `talent-channel-operation` ref 11 §9).
13. **Guarda cruzada de invariantes entre encargos** (`M2-GUARDA-4-SITIOS-Y-SELLO-OBSOLETO`,
    ratificado por CEO, 2026-07-28): cuando un lote de encargos hermanos comparte un invariante
    de dominio (una fuente única de verdad, un cálculo que no debe duplicarse), el Gate 3 (ref
    02 §7) se amplía: al fundir **cada PR posterior al primero**, verificar el invariante
    **contra lo ya fundido en `main`**, no solo dentro del diff. Un invariante que cada PR
    cumple por separado puede romperse por la SUMA (caso real: una gracia de 72 h aplicada en
    dos capas ⇒ 144 h). El lote y su invariante se declaran al intake del primer PR y se
    arrastran hasta el último.
14. **Eco de cumplimiento** (`CEO-REGLA-ECO-CUMPLIMIENTO-SKILL`, 2026-07-28 14:24:28Z): todo
    despacho o kickoff recibido de una estación o canal se cierra con un **eco del receptor**
    que nombra (a) **el skill cargado** y (b) **las cadencias y gates de ese skill que ha
    armado, corriendo — no prometidos**. Sin ese eco el despacho **no se da por entregado** y
    el emisor lo persigue. Un acuse que dice «recibido» sin nombrar skill ni cadencias **no es
    un eco**.
15. **Prohibido «reserva»/«ligero»/«guardia»/«hold» como estado reportado** (TAL-5170): toda
    estación (M1-M5) declara SIEMPRE una tarea CONCRETA en curso — nunca un estado de espera
    narrado como si fuera trabajo. Sin merge disponible en el slot → la tarea en curso es
    **PREP de cola** (intake, rebase, clasificación de superficie, verificación de HANDOFF del
    siguiente PR), nunca "reserva"/"ligero"/"guardia"/"hold" a secas. Esto NO deroga el HOLD de
    host documentado (ref 08, mantenimiento explícito pedido por el lead/CEO) — ese es un
    procedimiento con inicio/fin y confirmación explícita, no un estado de reporte ambiguo.
16. **Escalado obligatorio al bus** (TAL-8043): todo bloqueo que requiera autoridad superior (un GO del lead,
    un ruling del CEO, una decisión de superficie sensible) se SELLA en el bus ANTES de esperar —
    `ESCALA-<ROL>-<ref>`, nota `BLOQUEO-AUTORIDAD · espera:<rol> · decisión · default` — y el ruling se acusa
    con `ACK-<ROL>-<ref>`. Esperar en un menú del pane sin sellar deja a la capa superior ciega: ella solo lee
    el bus.
17. **`/clear` está prohibido en estaciones** (TAL-8043): tras un `/clear`, un reinicio o una sesión nueva la
    estación queda **NO ACREDITADO hasta re-acreditar** con un sello `ACRED-<ROL>-<nonce>` nuevo en el bus
    (`talent-ceo` `reacreditar.sh`, ref 07). Escribir «SELLO …» en el pane no es sellar: sellar es ejecutar
    `bus-sellar.sh`. Hasta acreditar, la estación no funde.

## Essential Patterns

```text
FÁBRICA — DOS ESTACIONES (ADR-0043)
  1ª estación (talent-channel-operation v6.3)          2ª estación (este skill)
  plan-gate → código → code-audit GO →                 intake(verify-handoff) → rebase+slots
  gates locales → PR DRAFT + HANDOFF ──────entrega──►  → CR-CLI → [findings→clasificar] →
  → canal a SIGUIENTE encargo (se olvida)              ready(±label) → gates AND → merge →
                                                       apply+advisors+ledger → Done
```

> El eje de arriba (1ª vs 2ª estación, ADR-0043) es DISTINTO del de abajo: la 2ª estación
> corre hoy como **5 instancias en paralelo (M1-M5)**, cada una operando el ciclo completo de
> arriba sobre un PR distinto; solo el ACTO de merge se serializa, y lo serializa **GitHub
> mismo** (`strict=true`: un merge sobre base stale es rechazado por la API, no un lock propio
> de la estación — Checklist paso 7). Los PRs con migraciones NO son la excepción: **CUALQUIER
> estación mergea Y aplica** (ratificado por el CEO, `CEO-DOCTRINA-MIGRACIONES-5-ESTACIONES`);
> `SLOT-CLAIM` evita que dos migraciones compartan número de slot, `APPLY-RUN`/`APPLY-DONE`/
> `APPLY-FAILED` (gana el PRIMER RUN tras el último cierre, nunca el más reciente) serializa
> CUÁNDO corre PROC-M13 (que aplica el gap completo, no solo un slot) — no por identidad de
> estación, por ejecución (Checklist paso 7-8). Un wrapper EXTERNO protege TODA la secuencia
> con `set +e`/`set -e` (leer `PIPESTATUS[0]` ANTES de reactivar `-e`) y publica el cierre con
> la categoría YA calculada leyendo `PROC_M13_CLASS_FILE` — NUNCA `$LOG`, que puede traer
> cuerpo HTTP remoto interpolado (`exit 0` → `APPLY-DONE`, cualquier otro →
> `APPLY-FAILED ... <CATEGORIA>` ∈ TRANSITORIO/ESCALAR, durable en el flock, nunca DEFECTO
> automático); la recuperación NO siempre es `APPLY-RECOVERS` — solo si, tras ESCALAR, se
> CONFIRMA que un advisor apunta a un objeto ya aplicado lo exige (identidad verificada
> SHA/ancestría/diff-que-AÑADE-con-`--paginate`/HANDOFF), una lectura transitoria
> (token/Vault/`fetch_ledger`/advisors) solo pide retry, y el POST que SÍ muta o cualquier
> fallo ambiguo/sin prefijo escala con una Señal de quiescencia REAL (`pg_locks` sobre el
> ledger, no una ventana de tiempo del cliente) antes de decidir. Pools
> por máquina física: Según repo (arriba) + ref 08 §2/§5.

```text
RUTAS DEL MERGEADOR (por PR, tras CLI) — el CLI limpio AUTORIZA el merge; App = solo fallback
  CLI limpio? ── sí ──► RUTA A (cualquier superficie): ready SIN label → gates AND → merge
       │                  (con aprobación CLI NO se gasta review del App — nunca)
       ├── finding MECÁNICO ──► canal de refactorización (vs INVARIANTES del HANDOFF) → re-gate
       ├── finding FUNCIONAL ──► se REBOTA SIEMPRE al productor → PROC-M16 bounce-to-pool
       ├── finding 3ª vía (test-quality/sistémico no explotable) ──► follow-up Linear + merge
       └── rate-limit/caído ──► RUTA B (fallback): label cr-review (REST verificado) → ready
                                  → App APPROVED@head → gates AND → merge
```

```text
GATES AND DEL MERGE (fail-closed; todos verificables por API — ref 02 §7)
  (CLI-limpio trazable ∨ App APPROVED@head ∨ code-audit GO si la org no tiene CR)
  ∧ local-gates=success @head VERIFICADO contra receipt propio (motor v2 — ref 08)
  ∧ spot-check disjunción/hot-files ∧ slot de migración sin colisión
  → merge con --match-head-commit <head-verificado>   (destructivas: + GO del lead)
```

```text
GATES LOCALES (TAL-2286/TAL-2288 — Actions OFF; detalle ref 08 + runbook local-gates.md)
  ESTACIÓN (credenciales): run_group impredecible → asigna gates/shards → sella receipts
    → post-local-gates.sh <run_group> <owner/repo> <pr> → commit-status local-gates
  RUNNER (sin credenciales, 85..88): incus file push script+manifiesto
    → bash /tmp/run-local-gates.sh <repo> --sha X --run-group G --gate <id>
    → worktree desechable + assert HEAD==sha → UN receipt parcial (PASS|FAIL|SKIP)
```

## Playbook de incidentes (síntoma → procedimiento)

| Síntoma | PROC | Ref |
|---|---|---|
| Draft sin HANDOFF / bloque inválido / stale | PROC-M01 | 02 |
| App muda tras rebase (skip / comment / solo check) | PROC-M04 | 04 |
| Spending cap del App / taxonomía del waiver | PROC-M05 | 04 |
| Rama con mayúsculas rompe `validar-flujo-pr` | PROC-M07 | 04 |
| Apply de migraciones a prod (TA) | PROC-M13 | anexo-TA |
| Slots de migración en colisión / renumeración | PROC-M14 | anexo-TA |
| Advisor security/perf WARN/ERROR post-apply | PROC-M15 | anexo-TA |
| Finding = defecto de diseño → bounce-to-pool | PROC-M16 | 05 |
| Destructiva detectada en el diff NO declarada | PROC-M17 | 03 |
| Cola atascada por Fair Usage / rate del App | PROC-M18 | 04 |
| Check rojo: ¿flake o regresión real? | PROC-M19 | 02 §9 |
| PR duplicado/stale de una issue YA mergeada (borrado masivo en shortstat) | PROC-M20 | 05 §6 |
| App bloqueando con review stale (CLI-clean autoriza) | PROC-M21 | 04 |
| Typecheck rc=2 en ~3 s sin node_modules / receipt faltante en la agregación | re-run sellado INDIVIDUAL | 08 §5 |
| Gate muerto dejó Supabase efímero huérfano en el runner | `docker rm -f` antes de re-correr | 08 §2 |
| `main` avanzó entre el gate y el merge (base_tip mismatch) | excepción ACOTADA o re-gate | 08 §8 |
| db-guards rojo tras un rebase de PR con baseline (advisor YA aceptado) | union-rebase tragó el accept → re-sembrar verbatim | anexo-TA §7 |
| Finding CLI sin texto (title/desc null) | capturar JSONL crudo primero; App solo si el raw no trae texto | 04 §2 B8 |

## Critical Gotchas

1. **Orden label→ready en la ruta B de fallback** → el App auto-revisa cuando el PR está (a) no-draft y
   (b) con label `cr-review`: poner el label ANTES de `gh pr ready` dispara UNA review al
   ready; marcarlo ready primero y etiquetar después puede perder el trigger o duplicarlo.
   En ruta A, ready SIN label = cero consumo de bucket App.
2. **`gh pr edit --add-label` falla silencioso** → labels de gate SIEMPRE por REST:
   `gh api -X POST .../issues/<n>/labels` + verificación por re-lectura (ref 04 §5).
3. **El App no re-revisa un head rebaseado** → "Review skipped: no new commits" / comment /
   solo check: ninguna aprueba; PR nuevo desde la misma rama (PROC-M04).
4. **Un APPROVED del App puede voltearse** → re-verificar el ÚLTIMO review sobre el head
   EXACTO justo antes del merge; jamás fiarse de un APPROVED cacheado.
5. **El ledger de prod ≠ `main`** → renumerar slots contra `main` a secas produce
   colisiones invisibles con applies en vuelo; el gap se calcula del ledger vivo
   (`comm -3` bidireccional, anexo PROC-M13).
6. **El HANDOFF queda stale tras el refacto propio o un rebase** → cada push cambia el head:
   re-emitir el **HANDOFF COMPLETO (las 9 secciones en el mismo comentario, no solo el bloque
   JSON — un comentario json-only NO valida)** y re-correr `verify-handoff.sh` antes de los
   gates AND. Ramas que predatan #827 → rebasar ANTES de flip a ready (traen el pr-gate
   corregido; si no, la Puerta PR re-dispara).
7. **Colisión de slots DENTRO de la propia cola** → dos drafts en preparación pueden
   declarar el mismo slot; el spot-check de slots compara contra ledger + `main` + los
   drafts en slot de merge (gate 4 del AND).
8. **Findings-state ≠ rate-limit** → si el CLI devolvió findings, NO hay fallback al App:
   se refactorizan o se rebota; la ruta B de fallback es SOLO para rate-limit/error del CLI.
9. **El spending cap del App se resetea por CUOTA de facturación, no por minutos** →
   sondear cada 10 min es inútil; re-triggers cadenciados (~10 min, 1 canal) y si persiste
   ~1 h → lead (PROC-M05/M18).
10. **Verificar la superficie contra el diff, no contra la declaración** → un HANDOFF que
    declara `sensitive: false` con `supabase/migrations/` en el diff es entrega inválida
    (fail-closed, regla 3) — la clasificación errónea se trata como PROC-M01, no se
    corrige en silencio.
11. **El squash pisa el `closes` si se edita el título/body al mergear** → el body del PR
    es la fuente de los `closes TAL-N`; no editarlo en el merge (el `--match-head-commit`
    protege el head, no el body).
12. **`gh pr edit --add-assignee` es NO-OP silencioso** (misma causa raíz que el gotcha 2:
    deprecación de Projects classic/projectCards) → para el despacho cross-host a un satélite,
    el assignee SIEMPRE por REST: `gh api -X POST repos/<o>/<r>/issues/<n>/assignees -f
    "assignees[]=<user>"` + comentario en el PR explicando el despacho + **verificación por
    re-lectura del RECURSO de la issue** (la ruta de COLECCIÓN `.../issues/<n>/assignees` en GET
    no existe en la API de GitHub → 404; el POST de arriba sí es correcto, solo la re-lectura
    va por el recurso): `gh api repos/<o>/<r>/issues/<n> --jq '.assignees[].login'` debe devolver
    **`assignees ≠ []`** — nunca confiar en el rc 0 de `gh pr edit`. Ver `references/04 §5`
    (mismo patrón que labels por REST). Cita: #1856/#1853, no-op de assignee.

## References

| Archivo | Contenido | Cuándo leerlo |
|---|---|---|
| `references/01-rol-y-fronteras.md` | La 2ª estación, fire-and-forget, fronteras con Orquestador/coordinador/lead, cola | Dudas de quién hace qué |
| `references/02-protocolo-por-pr.md` | **El corazón**: intake, rebase, CR, rutas, gates AND con comandos, merge, flake-vs-real | Operar la estación |
| `references/03-superficies-sensibles.md` | Lista canónica de 6 + fail-closed + path-patterns TA + PROC-M17 + §6 (checklist OTP/secretos) | Clasificar un PR |
| `references/04-coderabbit-cli-y-app.md` | Posture v2, presupuestos, PROC-M04/M05/M07/M18, labels REST | Todo lo de CodeRabbit |
| `references/05-canales-de-refactorizacion.md` | Micro-encargos, invariantes del HANDOFF, PROC-M16 bounce | Procesar findings |
| `references/06-migraciones-y-slots.md` | Slot vs ledger real, apply como gate de Done, destructivas | PRs con migraciones |
| `references/07-gotchas.md` | Índice de diagnóstico síntoma→causa→PROC-M | Primer lugar ante un síntoma raro |
| `references/08-gates-locales.md` | Runners minimal, receipts, agregación/post, anti-self-report, regla elástica, break-glass, BD compartida solo-aditiva | Todo lo del gate `local-gates` |
| `references/10-estaciones-en-paralelo.md` | Ventana de merge (15 min, `@<tip>`), batching por disjunción medida y pegada al sello, orden de entrada, suite nocturna 03:00 CDMX + suspensión ante rojo main-borne, exclusiones, relación con trenes, estación sin visibilidad del bus, supervivencia de lanzadores (`CEO-LEY-BATCHING-20:18`) | N estaciones fundiendo dentro de la MISMA ventana (no hay turno: ver ref 01 §2 y la fila `Pipeline`) |
| `references/09-trenes.md` | Lote cohesivo → tren padre, entrada por N ramas, ensamblaje (unión MANIFEST, renumeración de slots), contratos SEMÁNTICOS cross-pieza, CR sobre el bundle integrado, bounce al canal DUEÑO, cierre vía padre, exclusiones absolutas vs. cota de tamaño | PRs padre de tren (2+ encargos cohesivos) |
| el anexo adjudicado (`TCO_ANEXO_FILE`) | Required check + inventario histórico, baseline advisors compartido, hot-files, PROC-M13/M14/M15 | Operando el repo TA |

## Quick Start

En Academia Ejemplo los scripts corren desde la raíz del repo. **Fuera de TA** el tooling vive
en el **MOTOR** (`talent-factory`) y exige `TF_MANIFEST` con ruta ABSOLUTA (ver «Anexo mínimo
por repo» arriba — una ruta relativa se ignora en silencio).

```bash
# 0) Foto de la cola de drafts (prioridad: la curación de la cola es del Orquestador)
gh pr list --draft --json number,title,headRefName,createdAt

# 1) Intake — validar la entrega (fail-closed; rechazo = PROC-M01)
bash scripts/verify-handoff.sh <pr>

# 2) Superficie declarada vs diff real (ref 03)
gh pr diff <pr> --name-only

# 3) Gates AND por API antes del merge (comandos completos en ref 02 §7)
gh pr view <pr> --json mergeStateStatus,reviews,headRefOid
gh api "repos/{owner}/{repo}/commits/<head>/status" \
  --jq '.statuses[] | select(.context=="local-gates") | .state'   # + receipt propio (ref 08)

# RUTA APAGADA (fail-closed) — ruling CEO-RULING-MAJOR4-T05-BATCHING-OFF-PARALELA-NO-ES-BATCHING-1625:
#    el batching esta DESACTIVADO; CADA PR corre su suite COMPLETA sobre su propio head, disjunto
#    o no. El comentario de abajo describe la ventana, no autoriza ahorrarse una suite.
# 4) Merge (escritura serializada, NO «un solo PR por turno»: en ventana abierta sobre el
#    mismo tip, las piezas disjuntas se funden una tras otra, CADA UNA con su suite COMPLETA
#    sobre su propio head. La exención de suite que esta línea prescribía pertenece a la RUTA
#    APAGADA de arriba: queda registrada ahí como lo que la vía preveía, y no es operable —
#    fila Pipeline y §7; ley en references/10. Destructivas → GO del lead antes)
# ALCANCE: SIN MIGRACIONES — este Quick Start (paso 4) cubre SOLO PRs sin
#    `supabase/migrations/*` (slot único; destructivas → GO del lead antes).
#    PR CON migración: este Quick Start NO cubre ese caso y NO vale como receta. Antes de
#    mergear hay que RECLAMAR el gate APPLY-RUN (publicar→RELEER→ganar) y cerrar el turno en
#    TODA vía de salida. Receta completa: ref 02 §8. Contrato: Checklist §7 · ref 01 §2 · ref 06 §1.
gh pr merge <pr> --squash --delete-branch --match-head-commit <head-verificado>
```

*Quick Start bash-only (Acceptable Variation 6 del Gold Standard): este skill ES una
operación de CLI/gh/tmux, no una API multi-lenguaje.* Cambio irreversible en producción:
**siempre escala**.

## Tooling compartido con `talent-channel-operation`

Los scripts `merge-gate.sh`, `approve-merge.sh` y `waive-cr.sh` son **tooling compartido de
la estación de merge — permanece en `talent-channel-operation/scripts/` por acoplamiento a
`lib.sh`; lo ejecuta el Mergeador; su doctrina de uso vive en `talent-merger`**. Uso:
`merge-gate.sh <pr> <sha>` es un verificador de apoyo en la **ruta B de fallback** (sus
señales CLEAN/checks/0-bloqueantes/review-real@head son un subconjunto compatible del
AND); sus salidas `WAIVER_REQUIRED` se leen como diagnóstico y su gate de OK-humano aplica
solo a destructivas (GO del lead). En ruta A los gates se verifican por `gh api` directo
(ref 02 §7) — el AND v2 no exige review del App cuando hay aprobación CLI.

## Cross-Skill Integration

| Skill | Frontera |
|---|---|
| `talent-channel-operation` | 1ª estación: produce los drafts + HANDOFF y valida la entrega (su regla 13); presta el tooling compartido de la estación de merge; los incidentes de producción son suyos |
| `talent-orchestrator` | Cura los encargos/bundles y la prioridad de la cola; **recibe los bounce-to-pool** (PROC-M16); bajo drenaje-a-cero el Mergeador es la última estación viva y el Orquestador nunca mergea (orchestrator ref 06 §Regímenes, ADR-0043) |
| `talent-channels` | Aprovisiona los canales del Mergeador (perfil Mergeador: CON `CODERABBIT_API_KEY`; producción SIN ella) |
| `coderabbit-talent` | Dueño del setup/YAML/plan-detection de CodeRabbit; su norma "CLI solo bajo petición" aplica a sesiones normales — en esta estación el CLI ES protocolo (ADR-0043) |
| `supabase-skill` | Migraciones, RLS, advisors, Management API (apply post-merge) |
| `linear-skill` | Estados del ciclo: el Done lo produce el merge vía `closes TAL-N`; comentarios de cierre con SHA |

## Out of scope

- **Producir los drafts** (plan-gate, código, code-audit, entrega) → `talent-channel-operation`.
- **Curar bundles/encargos y repartir trabajo** → `talent-orchestrator`.
- **Aprovisionar canales/flota** (Incus + Tailscale + credenciales) → `talent-channels`.
- **Setup/YAML/triage de CodeRabbit** → `coderabbit-talent`.
- **Propagación a Bootcamp Cripto**: anexo + defaults cuando la fábrica se extienda (follow-up).
- Automatizar los gates AND en un script propio · sustituir CodeRabbit · cambiar el modelo
  de credenciales.

## Next Steps

- ¿Procesando un PR de la cola? → `references/02-protocolo-por-pr.md`
- ¿Es sensible o no? → `references/03-superficies-sensibles.md`
- ¿CodeRabbit raro (mudo, cap, labels)? → `references/04-coderabbit-cli-y-app.md`
- ¿Findings del review? → `references/05-canales-de-refactorizacion.md`
- ¿El PR trae migraciones? → `references/06-migraciones-y-slots.md` + anexo
- ¿Un síntoma que no ubicas? → `references/07-gotchas.md`
- ¿Gates locales / runners / receipts / `local-gates`? → `references/08-gates-locales.md`
- ¿PR padre de un tren / lote cohesivo? → `references/09-trenes.md`
- ¿Varias estaciones fundiendo a la vez / ventana / batching / suite nocturna? → `references/10-estaciones-en-paralelo.md` — **empezar por su §0: hueco declarado, bloqueante abierto**
- ¿Mecánica del repo? → el anexo adjudicado (`TCO_ANEXO_FILE`)

## Paquete de fábrica

Este skill es miembro del **paquete de skills de fábrica** (13): coderabbit-talent · linear-skill · talent-ceo · talent-channel-operation · talent-channels · talent-context · talent-docs-skill · talent-issue-craft · talent-medidor · talent-merger · talent-orchestrator · talent-pm · talent-sentry-guard. El paquete viaja JUNTO y
**motor-primero**: canónico en el repo motor `talent-factory` (`skills/`), propagado como núcleo
a los repos de producto con `scripts/paquete/sync-package.sh` (overlays por repo intactos)
y validado con `scripts/paquete/validate-package.sh` + `<skill>/invariants.tsv`.
Manifiesto: `scripts/paquete/package.manifest` · doctrina y ratchet (D6): `scripts/paquete/PAQUETE.md`.

Registro de modelos: `~/.config/talent-channel-operation/modelos.conf` del usuario del rol; los roles se resuelven por proveedor con `tco_modelo_read` (tabla en `talent-channel-operation`, ref 11): CEO, PM, plan, re-plan y código sensible usan Opus vigente; código y coordinación, Sonnet vigente; el auditor es de otro proveedor. Resolver tras acreditar Claude con `talent-channel-operation/scripts/resolver-modelos.sh`.
Nunca vuelques el entorno ni ficheros de credenciales; comprueba únicamente nombres y presencia.
