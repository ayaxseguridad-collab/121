# 02 — Convenciones Linear (setup gated)

## Table of Contents

- [Qué crear (una vez, con OK del lead)](#qué-crear-una-vez-con-ok-del-lead)
- [IDs base (ejemplos; adjudicar en la instancia)](#ids-base-ejemplos-adjudicar-en-la-instancia)
- [Tipos GraphQL (gotcha)](#tipos-graphql-gotcha)
- [Límites de la API (rate-limiting, verificado 2026-07-18)](#límites-de-la-api-rate-limiting-verificado-2026-07-18)
- [agents.conf (ejemplo, gitignored)](#agentsconf-ejemplo-gitignored)

El setup lo crea **el lead** (acción sensible: cambiar workflow states / crear proyecto). El skill
**no auto-crea nada**. `orchestrate.sh` corre un **preflight** que valida y **falla ruidoso** si
falta. Los IDs reales se guardan en el escrow `~/.config/talent-orchestrator/agents.conf`.

```text
Dos capas de Linear (detalle completo en SKILL.md §Dos capas)

  Producto Ejemplo (producto)        Fabrica Ejemplo (meta) — este archivo
  ─────────────────────────────         ──────────────────────────────────
  issues ABC-… reales                   proyecto "Coordinación Multi Canal"
  las mueve el Coordinador                ├─ órdenes de trabajo (Orquestador crea)
  + su cuadrilla                          └─ issue-registro de la flota (config lenta)

                    el setup de la capa META lo crea el LEAD (gated) ──►
```

## Qué crear (una vez, con OK del lead)

- **Proyecto "Coordinación Multi Canal"** dentro de la initiative META `Fabrica Ejemplo`
  `00000000-0000-4000-8000-000000000001` (excepción formalizada en CLAUDE.md/AGENTS.md: la capa de
  orquestación NO va en la initiative de producto Producto Ejemplo). → `TORC_COORD_PROJECT_ID`.
  El preflight valida que el proyecto pertenece a `TORC_INITIATIVE_ID`.
- **Estados** de las órdenes: `To Do` (unstarted) → `In Progress` (started) → `Needs Input` →
  `Done` (completed). En el setup actual se **reusaron** los estados del team; `Needs Input` se
  mapeó al estado existente **`Blocked`** (unstarted) — no se creó un estado nuevo. →
  `TORC_STATE_TODO`, `TORC_STATE_WORKING`, `TORC_STATE_NEEDS_INPUT`, `TORC_STATE_DONE`.
- **Labels**: `agent-instructions` (`TORC_LABEL_AGENT_INSTR`), `registry` (`TORC_LABEL_REGISTRY`),
  `coord-<nombre>` por coordinador (`TORC_LABEL_COORD`), y los obligatorios `vertical/*`
  (`TORC_LABEL_VERTICAL`, p.ej. `vertical/academy`) + `actor/ai` (`TORC_LABEL_ACTOR_AI`).
- **Issue-registro** (siempre In Progress, label `registry`) → `TORC_REGISTRY_ISSUE_ID`.

## IDs base (ejemplos; adjudicar en la instancia)

Los UUID siguientes son sintéticos; sustituirlos por los adjudicados en la configuración.

- Team Fabrica Ejemplo `00000000-0000-4000-8000-000000000002`
- Initiative META de coordinación `Fabrica Ejemplo` `00000000-0000-4000-8000-000000000001` (`TORC_INITIATIVE_ID`)
- State "In Progress" `00000000-0000-4000-8000-000000000003` · "Needs Input" → estado `Blocked` `00000000-0000-4000-8000-000000000004`

## Tipos GraphQL (gotcha)

El filtro `project:{id:{eq:$pid}}` exige `$pid:ID!` (no `String!`). El argumento `project(id:)` y
`issue(id:)` sí son `String!`. Toda llamada usa **variables** (`jq -n`), nunca interpolación.

## Límites de la API (rate-limiting, verificado 2026-07-18)

Fuente oficial: <https://linear.app/developers/rate-limiting> (fetch 2026-07-18) +
<https://linear.app/developers/graphql> (fetch 2026-07-18).

- **Endpoint**: `https://api.linear.app/graphql` — único público, sin versión en el path. Coincide
  con `scripts/lib.sh` (`linear_api`).
- **Modelo real que usa este skill: complejidad de query**, no conteo de requests. Techo **10.000
  puntos por query**; cuota **3.000.000 puntos/hora** para requests autenticadas con API key.
  Los guards de paginación fail-closed del skill (`hasNextPage`/`endCursor`, truncación en
  `relations(first:50)` de `select-work.sh`, `torc_fetch_open_orders`) dependen de ESTE modelo —
  no hay máximo documentado para `first:`, pero tampoco evidencia de que los tamaños de página
  usados (100-250) lo violen.
- **Contradicción real en la fuente oficial, NO resuelta — no se publica como hecho verificado**:
  el límite de *conteo de requests/hora* para API key aparece inconsistente en la misma página —
  la **prosa** dice "5.000 requests per hour" y la **tabla** dice "2.500 per user per hour". Este
  skill **no depende de esa cifra** (sus guards son de complejidad, no de conteo de requests), así
  que la discrepancia no bloquea nada operativo, pero queda documentada para que ningún PR futuro
  la cite como hecho confirmado sin re-chequear la fuente primero.

## agents.conf (ejemplo, gitignored)

```sh
TORC_COORD_PROJECT_ID=...
TORC_REGISTRY_ISSUE_ID=...
TORC_STATE_TODO=...; TORC_STATE_WORKING=...; TORC_STATE_NEEDS_INPUT=...; TORC_STATE_DONE=...
TORC_LABEL_AGENT_INSTR=...; TORC_LABEL_REGISTRY=...
TORC_LABEL_VERTICAL=...; TORC_LABEL_ACTOR_AI=...; TORC_LABEL_COORD=...
```
