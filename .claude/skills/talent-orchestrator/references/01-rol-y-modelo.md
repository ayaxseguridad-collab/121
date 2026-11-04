# 01 — Rol y modelo

## Table of Contents

- [El Orquestador es delgado](#el-orquestador-es-delgado)
- [Frontera Orquestador ↔ Coordinador](#frontera-orquestador--coordinador)
- [Por qué Linear como bus (modelo "Open Engine")](#por-qué-linear-como-bus-modelo-open-engine)
- [Cadencia](#cadencia)

## El Orquestador es delgado

Su único trabajo: **leer Linear de producto → curar un batch → crear una orden de trabajo**. No
clona repos, no maneja paneles tmux, no corre merge-gates, no aplica migraciones. Todo eso es del
**Coordinador** (`talent-channel-operation`). El Orquestador **solo escribe en Linear**.

```text
Orquestador (delgado — SOLO estas 3 acciones)

  leer Linear (producto)
        │
        ▼
  curar UN batch (issue_ids + precedence)
        │
        ▼
  crear UNA orden en Linear (Coordinación Multi Canal)
        │
        ▼
  STOP — no clona repos, no maneja paneles, no mergea (eso es del Coordinador/Mergeador)
```

## Frontera Orquestador ↔ Coordinador

| | Orquestador (este skill) | Coordinador (`talent-channel-operation`) |
|---|---|---|
| Decide | Qué issues y en qué orden (batch) | Qué encargo va a qué canal (el merge es del **Mergeador**, ADR-0043) |
| Escala | Proyecto / batch | Encargo / canal / repo |
| Toca | Solo Linear (capa Coordinación) | Repos de producto (clona, entrega **PR drafts + HANDOFF**; NUNCA mergea) |
| Invariante | Puede alimentar a varios coordinadores | **Uno por proyecto/repo** (dueño único de la cuadrilla) |

La contención de `main` la resuelve la **estación de merge ÚNICA** (el Mergeador es su propio
serializador — ADR-0043); *un coordinador = un repo* mantiene ordenada la producción de drafts.
El Orquestador respeta esa frontera entregando **una orden por coordinador**.

## Por qué Linear como bus (modelo "Open Engine")

El cuello de botella entre agentes es el **handoff**. En vez de inventar un store propio, la
**cola de Linear es el estado, el handoff y el cierre trazable**: la orden de trabajo es el lugar donde
Orquestador y Coordinador "hablan", con dueño, DoD y cierre verificable (Done) — sin copiar/pegar ni
chats. Ver `references/04-orden-de-trabajo.md`.

## Cadencia

El Orquestador compone el **siguiente** batch cuando el Coordinador marca la orden anterior como
`Done` (su cuadrilla se liberó). Ver `references/06-handoff-y-cadencia.md`.
