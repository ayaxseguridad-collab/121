# 05 — Canales de refactorización y bounce-to-pool

Cómo la estación procesa findings (de CLI o App) sin reabrir diálogo con el productor:
micro-encargos a canales propios para el conflicto MECÁNICO, auditados contra los invariantes
del HANDOFF; y los DOS casos en que un PR sale de la estación (defecto de diseño, o fix
FUNCIONAL — TAL-5170, ver §3).

## Table of Contents

- [1. El micro-encargo de refactorización](#1-el-micro-encargo-de-refactorización)
- [2. Auditar contra los invariantes del HANDOFF](#2-auditar-contra-los-invariantes-del-handoff)
- [3. Qué es (y qué NO es) defecto de diseño](#3-qué-es-y-qué-no-es-defecto-de-diseño)
- [4. PROC-M16 — Bounce-to-pool](#4-proc-m16--bounce-to-pool)
- [5. Higiene post-refacto](#5-higiene-post-refacto)
- [6. PROC-M20 — PR duplicado/stale de una issue ya mergeada](#6-proc-m20--pr-duplicadostale-de-una-issue-ya-mergeada)

## 1. El micro-encargo de refactorización

**Clasificar PRIMERO, despachar después** (TAL-5170 — invierte el default previo de esta
sección): todo finding cae en UNA de tres ramas (criterio completo en §3):

- **Conflicto MECÁNICO** (imports, vecindad de líneas, renumeración de slot, resolución de
  rebase) — **ÚNICA** rama que sigue yendo al micro-encargo de este §1.
- **Fix FUNCIONAL** (el finding exige tocar lógica, contrato o semántica, por acotado que
  parezca el diff) — **se REBOTA SIEMPRE** al productor (ruling CEO-ADJUD-1989, 2026-08-29):
  la estación NUNCA lo implementa ella misma, sin importar el tamaño del diff. Va directo a
  §4 PROC-M16, sin pasar por el micro-encargo.
- **3ª vía** (test-quality/harness o sistémico repo-wide no explotable) — follow-up en
  Linear más merge (regla dura 5 de SKILL.md), tampoco pasa por aquí.

Un finding MECÁNICO (critical/major del CLI, o cualquier finding del App en la ruta B de
fallback, que sea de esta clase) se despacha como **micro-encargo** a un canal propio del
Mergeador (pane dev + pane auditor, misma mecánica adversarial que producción, en pequeño):

1. **Brief al dev**: el finding literal (redactado si trae secretos) + los INVARIANTES del
   HANDOFF + la instrucción de alcance: «arregla EXACTAMENTE este finding; no
   refactorices nada más; no toques los invariantes». **Los findings del CR-CLI viven SOLO
   en local** (el JSONL del canal de la estación): el brief — y cualquier bounce — los lleva
   **VERBATIM en el cuerpo**, en TODAS las rondas; nunca "ver los inline del review" (no
   existen posteados) ni disparar el App para "hacerlos visibles".
2. El dev implementa + commitea → el **auditor** verifica (§2) → GO.
3. Push del canal de refactorización (con `draft-handoff.sh` — sus gates locales aplican
   igual) → el head del PR cambia → **re-emitir el HANDOFF COMPLETO (9 secciones en el mismo
   comentario, no solo el bloque JSON)** + `verify-handoff.sh` → re-gate (ref 02 §5-§7).

Es **parte del proceso, no excepción, para la rama MECÁNICA**: el throughput de la fábrica
asume que la mayoría de conflictos mecánicos se resuelven aquí (métrica del piloto: %
findings mecánicos resueltos por refacto vs bounce por defecto de diseño). Los findings
FUNCIONALES ya NO cuentan en esa métrica de refacto — **se REBOTA SIEMPRE**.

## 2. Auditar contra los invariantes del HANDOFF

El auditor del canal de refactorización **NO re-juzga el diseño** (eso ya lo selló el
code-audit de la 1ª estación). Su contrato:

- **Verifica el fix**: resuelve el finding señalado, sin efectos colaterales.
- **Verifica los invariantes**: cada invariante del HANDOFF sigue siendo cierto tras el
  fix. Un refactor que rompe un invariante NO es un fix válido — se rechaza al dev.
- **Detecta el desborde**: si el fix "necesita" tocar decisiones del plan (contratos,
  esquema, semántica declarada) → no es refactorizable → §3.

El HANDOFF es el artefacto de referencia único: si un invariante es ambiguo o inverificable,
eso es un defecto de la entrega (PROC-M01 retroactivo — cuenta como bounce de calidad,
avisar al coordinador productor).

## 3. Qué es (y qué NO es) defecto de diseño

**PROC-M16 bounce-to-pool tiene HOY dos disparadores DISTINTOS, no uno** (TAL-5170): (a)
**defecto de diseño**, definido en esta sección con umbral ALTO (el default histórico era
refactorizar) — la tabla de abajo sigue siendo el criterio para ESTE disparador; (b) **fix
FUNCIONAL** (regla dura 5 de SKILL.md, §1 arriba) — bounce SIEMPRE, incluso cuando el fix NO
califica como defecto de diseño por esta tabla (un finding funcional acotado, sin romper
ningún invariante ni contrato, igual se rebota — el umbral alto de "defecto de diseño" ya NO
es el único filtro de entrada a PROC-M16). Solo el conflicto MECÁNICO (columna derecha) sigue
yendo a refacto normal.

| Es defecto de DISEÑO (bounce) | NO lo es (refacto normal — SOLO si además es MECÁNICO) |
|---|---|
| El fix exige cambiar decisiones del plan aprobado (contrato de una RPC, shape de datos, semántica de un flag) | Cambiar líneas/estructura manteniendo el contrato |
| El fix rompería un invariante sellado del HANDOFF | El fix respeta los invariantes |
| El rebase revela que otra rama pisó el dominio con OTRA semántica (conflicto conceptual) | Conflicto mecánico de merge (vecindad, imports) |
| El finding demuestra que el approach es inviable (seguridad estructural, N+1 de arquitectura) | — (ver fila siguiente: un bug puntual YA NO es refacto normal desde TAL-5170) |
| Cualquier finding sobre `supabase/migrations/**` que toque lógica/schema (backfill, DEFAULT/NOT NULL, o cualquier statement de la migración) — TAL-5170: subsume la vieja excepción de "independencia de contexto", ver nota abajo | Renumeración PURA de slot (mecánica, ref 06 §2) — el ÚNICO caso migración que sigue en refacto normal |
| **Fix FUNCIONAL aunque sea acotado** (lógica, contrato o semántica) — se REBOTA SIEMPRE, aunque no rompa ningún invariante ni sea "un bug grave" (disparador (b) arriba, TAL-5170) — **esto incluye "un bug puntual, aunque sea grave"**: ya NO es refacto normal, es fix funcional | Conflicto MECÁNICO de merge (vecindad, imports, renumeración de slot) — única categoría que sigue en refacto normal |

**Límite del inline-fix en migraciones — SUBSUMIDO por la regla general de fix funcional desde
TAL-5170 (histórico: 23-ago-2026, TREN E, CRITICAL, "independencia de contexto")**: la regla
original decía que un finding sobre `backfill`/`DEFAULT`/`NOT NULL` NO era quirúrgico aunque el
diff fuera "una línea", con el eje de decisión en la **INDEPENDENCIA DE CONTEXTO, no tamaño del diff**
(histórico, preservado literal). Desde el ruling CEO-ADJUD-1989 (SKILL.md regla dura 5), ese eje ya NO
hace falta para llegar al bounce: **cualquier fix de LÓGICA/SCHEMA sobre una migración es un fix
FUNCIONAL** (toca el contrato de lo que la migración hace), así que se rebota SIEMPRE — sea o no
independiente del resto del `backfill`/`DEFAULT`/`NOT NULL`. La única categoría de cambio sobre
`supabase/migrations/**` que sigue en refacto normal es la renumeración PURA de slot (mecánica,
sin tocar el statement SQL en sí — ref 06 §2). Salida ante un finding de lógica/schema: bounce
con la **secuencia prescrita** — `nullable` → `backfill` → `NOT NULL` + `default` — nunca un
`ALTER COLUMN ... NOT NULL DEFAULT ...` inline que salte el backfill, y nunca un inline-fix de la
estación por acotado que parezca el diff. Ver `references/06-migraciones-y-slots.md` para el
detalle de slots/ledger de la migración corregida. No confundir con el "cambio quirúrgico" de
`references/02-protocolo-por-pr.md` (flake-vs-real, PROC-M19) — es un concepto distinto
(identidad de un shard de test, no el fix-funcional-siempre-rebota de una migración).

### Deuda conocida gated (rechazo de cableado prematuro)

Un PR puede entregar **deuda conocida** gated por otra issue (p. ej. "paridad interim; la
integridad server-only queda diferida a TAL-N"). Si el PR **cablea un consumidor antes de su
gate** (p. ej. premios/puntos enganchados a una señal cuya integridad depende de una issue
aún abierta), el Mergeador puede **rechazar el merge** aunque el diff esté limpio: mergear
adelantaría un consumidor gated. Doctrina: el HANDOFF debe **declarar la deuda conocida y su
gate** para que el Mergeador la vea estructuralmente; sin gate satisfecho, el PR espera o
vuelve a la cadena. *(Un campo `known_debt: [{note, tracked_by, gates}]` machine-readable en
el HANDOFF es issue follow-up a crear por el Orquestador; hoy la deuda gated se declara en
prosa en la sección de riesgos/contexto del HANDOFF y se verifica a mano.)*

### Taxonomía de bounces (tres motivos)

Cuando el PR sale de la estación, el motivo cae en uno de tres tipos — cada uno con salida
distinta. El arbitraje dev↔estación se dirime siempre contra el **HEAD REMOTO VIVO**
(`git fetch` + `gh pr view --json headRefOid`), nunca contra la foto local:

| Tipo | Síntoma | Salida |
|---|---|---|
| **(a) heavy-lift / diseño** | El fix exige re-diseñar contrato, esquema o approach — §3 | Bounce a pool (PROC-M16). La estación NO desarrolla el rediseño |
| **(b) stale-content** | El diff revertiría doctrina que `main` YA tiene (rama nacida antes de un merge que la supersede) | Bounce **con evidencia textual**: citar `git log origin/main -- <fichero>` y la línea de `main` que el PR pisaría |
| **(c) subset-de-merged** | Parte del PR ya entró por otro merge; solo un delta sigue siendo novedad | Re-entrega **recortada**: pedir al autor un PR fresco solo con el delta vivo vía Orquestador (nunca recortar desde la estación) |

**Cautela ante órdenes destructivas con evidencia contradictoria**: si el coordinador u
Orquestador ordena una acción irreversible (force-push, cierre, `--admin`) y el HEAD remoto
vivo contradice la premisa, la estación **PARA y lo señala** antes de ejecutar (ev
#1176/#1091/#1186: órdenes emitidas sobre una foto ya superada por el remoto).

## 4. PROC-M16 — Bounce-to-pool

La mecánica canónica del bounce es la **Decisión 6 del Orquestador** (dueño del pool:
`talent-orchestrator` ref 08 §Bounce-to-pool) — este PROC es la cara de la estación:

1. **Parquear el PR**: comentario con el finding + por qué es defecto de diseño (2-4
   líneas, citando el invariante o la decisión afectada), con el **finding LITERAL en el
   cuerpo** (los findings CLI no existen posteados en ningún otro sitio — un bounce que
   referencia "los inline" es ilegible). El PR queda en draft, sin slot.
2. **Re-entrada por Decisión 6, ATÓMICA AL BUNDLE — NO se crean issues nuevas**: TODAS las
   issues del bundle rebotado se mueven a **`Backlog`** + label **`bounced`** (añadido al
   array existente, sin perder los `vertical/*`) + comentario con el motivo (finding + link
   al PR parqueado — con **marcador idempotente por ocurrencia** `bounce:PR-<n>@<oid>` para
   que un re-bounce del mismo PR no se salte por el marcador viejo). Como Linear no da
   transacción multi-issue, la mecánica es **reentrante con reconciliación** (inventario del
   conjunto → mutación idempotente por issue de estado+label+comentario → relectura de los
   TRES invariantes + retry antes de re-encolar; ninguna es elegible hasta que las N pasan
   — `talent-orchestrator` ref 08 §Bounce-to-pool). **Ninguna queda In Review**. Es
   re-entrada al pool, no trabajo nuevo — el Orquestador las re-pickea en su siguiente
   pasada de curación (posiblemente al mismo canal productor — pero vía pool, nunca por
   diálogo directo).
3. Registrar el bounce (métrica del piloto). Re-diseñar NO es acabados: la estación nunca
   "arregla el diseño" por su cuenta, por bueno que parezca el atajo.
4. **Post-bounce — loop issue-craft**: formular UNA pregunta: «¿la issue de origen pudo haber
   prevenido este defecto?». Si la respuesta es sí, añadir un comentario en la issue Linear con
   el gap concreto y el label `issue-craft-gap` (lo consume el barrido semanal del Orquestador).
   El **bounce debe estar estructurado en 4 campos**: `{ancla archivo:línea | tipo (bug
   real / test-quality / doc) | causa raíz probada | fix concreto}` — un bounce vago es
   ilegible para el Orquestador y para el canal que lo re-recibe. El bounce cita archivos y
   hunks **del head exacto** en el momento del bounce (foto point-in-time, C2-estación): no
   referencias a "los inline del review" ni a un diff abstracto. Si es bounce de diseño, el
   re-despacho pasa por **`audit-issue`** (marcador + tabla de decisiones selladas) antes de
   re-entrar a la fábrica (ev #1108/TAL-2066).

### PR bounceado huérfano (base-stale con productor reciclado) = scope de estación

Si un PR bounceado **solo necesita rebase-sobre-`main`** y el canal productor **ya se recicló**, el
PR queda **huérfano** (nadie lo retoma por diálogo directo). El Mergeador lo **re-adjudica como
scope de estación** en su siguiente barrido — **jamás parkear horas** esperando un productor que ya
no existe. **ÚNICA AUTORIDAD — esto NO es una excepción a la regla `BOUNCED` de ref 01 §2**: el
estado `BOUNCED` del flock sigue vetando el intake de ESE PR para TODAS las estaciones, siempre
(los tokens canónicos del flock y el pre-claim grep `(CLAIM|BOUNCED)` NO cambian y no se
reinterpretan). La re-adjudicación del huérfano se materializa como **ENTREGA FRESCA de
estación**: rama NUEVA cortada de `main` con los commits del PR huérfano rebasados + **PR
NUEVO** (que entra por el intake normal — sin historia en el flock, pasa el pre-claim grep
limpio) + cierre del PR viejo con comentario de reemplazo (referencia cruzada al PR nuevo y al
TAL-N; los `closes` viajan al PR nuevo). El `BOUNCED` histórico del PR viejo queda ÍNTEGRO y
correcto para siempre — nadie re-intakea ese número. Sin doble ownership posible: el PR nuevo
nace claimeado por la estación que lo abre, y el viejo permanece vetado.

**PERO verificar primero que el conflicto es realmente MECÁNICO.** Un rebase que aplica **sin
conflicto** puede seguir siendo una **colisión de diseño**: si el rebase silencioso reintroduciría
contenido que `main` ya **retiró** (caso #1025 vs #1007: un embed buggy que rebasa sin conflicto),
conformarse a la dirección ya aterrizada en `main` **NO** es trabajo mecánico → requiere
**autorización explícita del CEO/lead**, o **bounce**. Cross-ref: base_tip mismatch en `08` §8.

## 5. Higiene post-refacto

- Cada ciclo de refacto termina con: head nuevo + **HANDOFF completo re-emitido (9
  secciones)** + `verify-handoff.sh` exit 0 + re-gate completo (los gates AND se corren sobre
  el head final, nunca sobre fotos).
- El canal de refactorización se recicla entre micro-encargos (misma doctrina de recycle
  que producción); un canal con contexto contaminado de un finding anterior produce fixes
  con arrastre.
- Si el MISMO PR acumula 3+ ciclos de refacto sin converger → tratar como señal de defecto
  de diseño encubierto (§3) y evaluar bounce — la convergencia lenta también quema bucket.

## 6. PROC-M20 — PR duplicado/stale de una issue ya mergeada

**Fence de dos-deliveries** (Ev: #935 vs #925 — dos entregas del mismo `TAL-N`; la segunda,
brutalmente stale, casi se "reconcilia" encima del merge bueno). Detección en intake:

- El `TAL-N` del PR **ya está mergeado en main** (el `closes` de otro PR lo cerró), **Y**
- el `git diff --shortstat` contra main muestra **borrado masivo** (miles de deleciones /
  200+ ficheros) — firma de una rama **cientos de commits behind**, no de un cambio real.

Procedimiento:

1. **NO rebasar, NO reconciliar**: rebasear una rama así "resucita" borrados de todo lo que
   main añadió después — no hay diff legítimo que preservar por esa vía.
2. **Escalar superseded-vs-residual** (ruling consolidado del lead —
   `talent-orchestrator` ref 08): el default es **cerrar el PR como superseded** con nota.
3. Si hay **valor residual** (algo del PR stale que main no tiene): NO se rescata rebasando —
   se pide **PR fresco del autor sobre el main actual** vía nota al Orquestador.
4. Registrar el fence (el par de PRs, cuál ganó, el residual si lo hay).

### PR rebotado frente a PR abierto sobre la misma issue

Cuando un PR es **bounced** (regresó al pool, PROC-M16) y mientras estaba en el pool llega
**otro PR** de la misma issue (re-entrega del canal), pueden estar en vuelo simultáneamente:

- **Solape mayoritario (el nuevo cubre ≥80% del diff del bounced)**: el bounced queda
  **superseded** — cerrar con nota que señale el nuevo PR y el motivo (cuenta como "resuelto",
  no como bounce doble). La traza queda en los comentarios de ambos PRs y en la issue Linear.
- **Sin solape mayoritario**: los dos PRs son trabajo distinto. Ordenar por proximidad al
  merge: el más cercano a CLEAN entra al slot primero; el otro rebasa encima una vez mergeado
  el primero (ev #1111×#1187, #1211/#1229, #1125/#1159). Registrar la dependencia de orden en
  la issue Linear para que el Orquestador la cuente.
