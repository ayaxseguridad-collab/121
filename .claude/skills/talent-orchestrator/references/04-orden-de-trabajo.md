# 04 — Orden de trabajo

## Table of Contents

- [Higiene Linear obligatoria](#higiene-linear-obligatoria)
- [Cuerpo = prosa + bloque machine-readable](#cuerpo--prosa--bloque-machine-readable)
- [Estados y cierre](#estados-y-cierre)

Una issue del proyecto Coordinación = una **orden de trabajo** para un coordinador. Estilo
"Open Engine": contexto + dueño + DoD + dónde parar + qué mostrar.

```text
Anatomía del cuerpo de la orden (assets/work-order.tmpl — única fuente de verdad, TAL-1974)

  ┌─ prosa legible (humano) ───────────────────────────────────────────┐
  │ Orden para **COORD** (repo REPO). El coordinador LEE y despacha    │
  │ a mano. Issues, respetando precedencia: 1) ABC-x  2) ABC-y …       │
  │ DoD + Cierre (mueve a Done / Needs Input si se bloquea)            │
  └──────────────────────────────────────────────────────────────────┘
  ┌─ bloque ```json (máquina — OBLIGATORIO) ───────────────────────────┐
  │ { schema_version, coordinador, issue_ids, precedence,              │
  │   bundles?, dod, idempotency_key }                                 │
  │        ↑ lo parsea torc_precreate_check / torc_extract_issue_ids   │
  └──────────────────────────────────────────────────────────────────┘
```

## Higiene Linear obligatoria

- **Título imperativo**: `Orquestar batch (coord-talent): ABC-1217,ABC-1238,…`.
- **Labels**: `agent-instructions`, `coord-<nombre>`, `vertical/*`, `actor/ai`.
- **Estado inicial**: `To Do`.

## Cuerpo = prosa + bloque machine-readable

La **prosa** es legible: el coordinador **LEE** la orden y **despacha cada issue a mano**
(`dispatch.sh <carril> <ABC-id>`), respetando la precedencia; incluye DoD y la instrucción de escalado.
El **bloque ```json** es **obligatorio** en las órdenes que crea el Orquestador porque la **reserva/
idempotencia** lo parsea (`select-work` + `torc_precreate_check` → `torc_extract_issue_ids`); es
**opcional** solo para el humano que lo lee (puede extraer `issue_ids` con `jq` si quiere):

```json
{ "schema_version": 1, "coordinador": "coord-talent",
  "coordination_project_id": "<uuid>", "product_project": "org-ejemplo/producto",
  "issue_ids": ["ABC-1217","ABC-1238","ABC-1404"],
  "precedence": [["ABC-1238","ABC-1217"]],
  "bundles": [["ABC-1217","ABC-1238"],["ABC-1404"]],
  "dod": "drafts-entregados+handoff+in-review", "idempotency_key": "<sha1>" }
```

- `issue_ids`: orden topológico ya resuelto → alimenta `--issues` del coordinador.
- `precedence`: pares `[child, parent]` (child depende de parent).
- `bundles` **(opcional, Fábrica v2 — ref 08)**: agrupación en **encargos** (cada
  sub-array = una rama = un PR draft + HANDOFF). Invariantes: la unión de los sub-arrays
  == `issue_ids`, sin solape, y el orden interno respeta `precedence`. Sin `bundles`, cada
  issue es su propio encargo. El campo lo IGNORAN los parsers actuales
  (`torc_extract_issue_ids` solo lee `issue_ids` — backward-compatible, sigue siendo
  `schema_version: 1`); su validación programática es follow-up.
- `idempotency_key`: sha1 de `schema_version + coordinador + issue_ids ordenados` → evita órdenes
  duplicadas.

**Deslinde de templates** — dos tipos de issue con fuente de verdad distinta, NUNCA mezclar:

- **Issues de PRODUCTO que el Orquestador crea/optimiza** (features, fixes, chores…): instanciar
  desde el **Template nativo de workspace** del tipo en Linear (marcador `issue-craft:v1` garantizado
  en 1ª línea; patrón `issueCreate` + `templateId` del `linear-skill`). El Template de workspace es
  la única fuente de verdad del cuerpo del producto.
- **Órdenes-meta de Coordinación** (las que emite `orchestrate.sh`): **conservan
  `assets/work-order.tmpl` + bloque machine-readable como canon** (`torc_render_order_body` en
  `lib.sh`). El script actual **NO cambia** — así se declara textualmente. El `templateId` de
  workspace NO aplica a las órdenes meta, que tienen su propia fuente de verdad versionada.

## Estados y cierre

`To Do → In Progress → (Needs Input) → Done`. "Needs Input" es el **rol**; el **estado real en
Linear** es el configurado en `TORC_STATE_NEEDS_INPUT` (en el setup actual = **`Blocked`**).
`orchestrate.sh` **renderiza el nombre real** del estado en el cuerpo de la orden (consulta su
nombre por id), así que el coordinador siempre ve el estado que existe en Linear. Si el coordinador
se bloquea: mueve a ese estado con la pregunta exacta en la issue; el lead responde ahí; reanuda. El
**cierre es manual** y su DoD es el de Fábrica v2 (ADR-0043): al terminar — **todos los encargos
entregados como PR draft + HANDOFF verificado (`verify-handoff.sh` == 0) + issues In Review** — el
coordinador mueve la orden a **Done** (opcionalmente una línea con los PRs entregados). El merge, el
apply de migraciones y el Done de cada issue de producto los produce el **Mergeador** (vía `closes
ABC-N` al mergear) — la orden NO espera el merge. Ese `Done` de la orden es la señal que el
Orquestador observa para componer el siguiente batch.
