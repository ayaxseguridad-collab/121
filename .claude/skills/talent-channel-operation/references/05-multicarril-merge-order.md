# 05 — Multi-canal: cola, publicación y estado

> **RECORTADO en v6.0 (ADR-0043 / TAL-2193).** Las secciones de merge de la v5.0
> (merge-gate, equivalencia shaok, go-merge canónico, merges serializados, ventana de merge
> PROC-06, índice compartido PROC-12, renumeración post-merge, aprobación humana,
> verificación post-merge) **salieron de aquí como doctrina**: **el merge no es asunto de esta
> estación**. Doctrina de merge **y ley de batching**: skill del Mergeador (`talent-merger`). El
> tooling compartido, en `SKILL.md`. Aquí queda lo que sigue siendo de la
> 1ª estación: la cola de canales, la disciplina de publicación del dev (PROC-18) y el estado
> durable. El filename se conserva por estabilidad de links.

## Table of Contents

1. [Cola y cap de suscripción](#1-cola-y-cap-de-suscripción)
2. [Disciplina de publicación del dev](#2-disciplina-de-publicación-del-dev) · [PROC-18](#proc-18--dev-rebaseó-local-pero-no-publicó)
   - [Colisión estación↔coordinador sobre un PR cedido (T5)](#colisión-estacióncoordinador-sobre-un-pr-cedido-t5--doctrina-canónica)
   - [Diálogos de confirmación bloquean el push en silencio](#diálogos-de-confirmación-bloquean-el-push-en-silencio-barrer-por-menús)
3. [Estado durable y reentrancia [M5]](#3-estado-durable-y-reentrancia-m5)

## 1. Cola y cap de suscripción

- `select-issues.sh` ordena la cola (ver `references/06-seleccion-de-issues.md`); los
  encargos/bundles los cura el Orquestador (regla 14).
- Asignación 1 encargo ↔ 1 canal de desarrollo libre [M1] (`tco_carril_libre`), **sigue
  decidida por el coordinador** — sin cambio de comportamiento. **[TAL-5172]** El diseño de
  CLAIM autoservicio (asignación cross-coordinador por `flock` sobre un pool de slots) evaluado
  para reemplazar esto quedó fuera de esta issue: falló el code-gate adversarial (sin TTL, sin
  fencing token validado, sin compare-and-delete en el release) y, de fondo, el **pool único de
  flota `fleet-slot-1..4`** (ver `references/09-gotchas.md` §pool de flota) ya arbitra la carga
  PESADA entre coordinadores — el mecanismo de CLAIM queda **SUPERADO, no aplazado**. Un eventual
  CLAIM de TRABAJO (distinto de un claim de CPU) sería issue propia dimensionada sobre ese pool.
  Nota de decisión completa en el amendment de TAL-5172 (Linear, 2026-09-02).
- **[TAL-5172] Cap real y topología, actualizados a la flota vigente** [corregido v7, CR de M2:
  el texto anterior presentaba un TOPE como si fuera un CENSO — son dos números distintos y hay
  que decirlo así]:
  - **INVENTARIO** (censo real, cuántos canales operan HOY): **17 canales, 3 coordinadores**
    (registro de flota vigente).
  - **MÁXIMO** (tope por coordinador, no cuenta real por coordinador — 17 entre 3 no reparte
    igual): **8 canales por coordinador** es el TECHO permitido, no el número que cada uno tiene
    hoy.
  La topología declarada por defecto **"4 dev (01-04) + 2 audit (05-06)"** ya NO describe la
  operación real; se conserva como ejemplo mínimo de arranque, no como inventario. `TCO_MAX_ACTIVE`
  (histórico: cap por suscripción/cuenta compartida de los agentes, no CPU [G33]) queda
  **desfasado** como parámetro frente al MÁXIMO real de 8 canales/coordinador — su valor nuevo (o
  su retirada) es decisión abierta del CEO al primer despacho tras este merge; mientras tanto
  documentar "8 canales por coordinador" en prosa como MÁXIMO y marcar el parámetro como
  desfasado, no como autoritativo.
  Todo el ruteo sigue **driven por `TCO_DEV_CARRILES`**. Para escalar el desarrollo en paralelo:
  aprovisiona **contenedores adicionales** y añádelos a `TCO_DEV_CARRILES`. Reconvertir un canal
  audit-only a desarrollo es una **decisión de topología deliberada** que debe reflejarse también
  en `01-modelo-y-roles.md`; no mezclar roles con un simple override.
- **La monitorización es responsabilidad del coordinador** [Pilar 6], nunca delegada a un
  subagente/monitor fire-and-forget — pero NO como poll foreground de cadencia corta (un comando
  foreground topa a ~2 min y el reaper mata bg-watchers con sleeps largos): el patrón correcto es
  la doctrina de monitores T6 (`references/03` §7 — bg con for-loop de condición terminal;
  foreground puntual con timeout 200-280 s).
- **Auditorías en paralelo — SÍ es válido** (reconciliado con Pilar 6): correr **varios
  `audit-gate.sh` a la vez** (uno por canal, en foreground) mientras el coordinador observa la
  flota y **cosecha cada veredicto JSON** al completar (`tco_parse_verdict` — el resultado se
  LEE, no se descarta). La línea roja de Pilar 6 es **perder visibilidad**, no paralelizar
  auditorías cuyo veredicto se recoge.
- **Entregan drafts y siguen** (v6.0): los coordinadores de producción ya no compiten por el
  merge. La contención de `main` la gestiona el Mergeador (`talent-merger` ref 02 §7).
- **Qué comandos van DENTRO del lock FIFO de host y cuáles NO** (`flock /buildlock/build.lock -c
  '<cmd>'`): DENTRO → `next build`, la suite E2E, `supabase db reset --local` y **`draft-handoff.sh`
  COMPLETO** (arrastra un build). FUERA, libres → `typecheck`, `lint`, `test:unit`,
  `i18n:check`/`flags:check`/`tenant:check` (no compiten por CPU/IO pesado; encolarlos solo añade
  latencia sin proteger nada). El FIFO preserva el orden de llegada, así que **un canal esperando su
  turno en la cola del lock está SANO** — no es un atasco ni motivo de recycle. (El mecanismo del
  build-lock por máquina y el diagnóstico de saturación del host viven en `references/09-gotchas.md`
  §8.)

## 2. Disciplina de publicación del dev

### PROC-18 — Dev rebaseó local pero no publicó

**Síntoma** [E28+E29, patrón recurrente]: HEAD local nuevo en el canal + PR `ahead N, behind 1` +
la rama remota **sin cambiar** — el dev rebaseó/commiteó en local y cree haber publicado.

1. **Verificar**: en el canal, `git rev-parse HEAD` vs `git rev-parse origin/<rama>`. Si
   difieren, el remoto NO tiene el trabajo (y `verify-handoff.sh` fallará por head_sha stale).
2. **Pedir publicación explícita** con `--force-with-lease` (rama ya publicada + rebase = push
   forzado seguro; el push de entrega exige re-emitir el sentinel draft para el SHA nuevo). Ojo
   al fraseo del relevo si el hook del host aplica (PROC-01,
   `references/03-mecanica-tmux-incus.md`).
3. Si el dev **sigue idle** tras el relevo → instruir literalmente: **"usa REALMENTE la
   herramienta Bash"** (el patrón observado es que el dev *describe* el push sin ejecutarlo).
4. **Gotcha del diff con rama BEHIND**: `git diff origin/main..HEAD` **MIENTE** — muestra
   **borrados falsos** de archivos ajenos (los que `main` añadió después del merge-base local). El
   diff real del commit es **`git show <sha>`** (o un diff contra el merge-base correcto).
5. Tras publicar: head remoto nuevo → re-emitir el bloque machine-readable del HANDOFF y
   re-correr `verify-handoff.sh` (regla 13).

### Colisión estación↔coordinador sobre un PR cedido (T5 — doctrina canónica)

El Mergeador puede **avanzar un PR entregado** (rebase, re-stamp, ready) mientras el coordinador
re-dispatchea un re-fix sobre él — dos actores sobre el mismo head es la receta del force-push
destructivo. Reglas:

- **Antes de tocar un PR ya entregado, re-leer su estado VIVO**: `headRefOid` remoto nuevo (≠ el
  que entregaste) y/o `isDraft=false` (la estación lo marcó ready) = **el Mergeador lo tomó** →
  **STAND-DOWN inmediato**: no pushear, no re-stampear, **JAMÁS `--force` encima** del avance de
  la estación. Lo que hubiera en vuelo local se descarta o se re-deriva del head nuevo.
- **La estación ANUNCIA al Orquestador los PRs que toma** (su lado del contrato:
  `talent-merger/references/01` §2) — pero el anuncio puede llegar tarde: el stand-down por
  estado vivo es el control, el anuncio es cortesía.
- **CR "Review skipped" sin label = 0 findings**: si el PR muestra ese estado del App (sin label
  `cr-review`), NO hay findings que fijar — un re-fix "por si acaso" es un **no-op** que solo
  mueve el head y desincroniza a la estación. No re-dispatchear sin findings concretos.

### Diálogos de confirmación bloquean el push en SILENCIO (barrer por MENÚS)

Un dev puede quedar parado en un **diálogo de confirmación** del CLI (checklist R6, permiso sobre
`settings.json`, hooks, guard de `git push`) — el pane parece idle y el push nunca sale (evidencia:
canal 51). Doctrina:

- **Barrer los canales por MENÚS abiertos, no solo por idle**: un idle con diálogo pendiente es un
  canal bloqueado, no un canal libre.
- **Clasificar ANTES de confirmar** (nunca "Yes" a ciegas):
  - push de **rama `feat/*`** propia del encargo → **Yes**;
  - permiso sobre **`settings.json` de hooks de fábrica** → Yes **solo si** está en el scope del
    encargo;
  - **código de producto fuera de scope / `.env.local` / push a `main`** → **No + escalar**.
- Verificar la resolución **por conducta** (el push salió: `git ls-remote` muestra el head nuevo),
  no por haber pulsado la opción.

## 3. Estado durable y reentrancia [M5]

- **Event log + state file** por corrida en `$TCO_RUNS_DIR/<run_id>/state.json`: fase por
  canal, SHAs, veredictos (con su run_id/hash), estado de la entrega.
- **Locks atómicos cross-process** (`tco_lock_acquire` / `tco_lock_release`, mkdir + PID +
  timestamp): un lock por encargo. **Stale-lock por TTL** (`TCO_LOCK_TTL`, default 3600s) o PID
  muerto → se recupera. (El lock global de merge de la v5.0 dejó de aplicar a esta estación.)
- **Idempotencia**: antes de push/PR, consultar el estado real en GitHub (¿ya hay PR? ¿ya está
  el HANDOFF?) para no duplicar. El coordinador anota `state.json` (run_id, fase, pr, sha) por
  canal para reanudar tras una interrupción sin re-hacer trabajo cerrado.
