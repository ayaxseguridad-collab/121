# 02 — (DEPRECADO) Herramientas MCP → API GraphQL directa

> **Deprecado (TAL-2294).** Este repositorio es **token-only, NO MCP**: toda operación contra Linear
> va por la **API GraphQL directa** con `LINEAR_API_KEY` (por carril, en `.env.local`), nunca por el
> servidor MCP de Linear. Este documento se conserva solo como puntero histórico; no contiene
> instrucciones operativas.

```text
ANTES (MCP, retirado — TAL-2294)                 AHORA (token directo)
┌──────────────┐  tool call  ┌────────────┐      ┌──────────────┐  GraphQL  ┌─────────────────┐
│ Agente IA     │────────────▶│ Servidor    │      │ Agente IA/    │──────────▶│ api.linear.app   │
│               │◀────────────│ MCP Linear  │      │ script        │◀──────────│ /graphql         │
└──────────────┘  resultado  └────────────┘      └──────────────┘ data/errors └─────────────────┘
       ✗ retirado                                        ✓ vigente (LINEAR_API_KEY)
```

## Dónde está ahora cada cosa

- **Operaciones (crear/buscar/actualizar issues, comentar, mover de estado, batch)** →
  `references/03-graphql-cheatsheet.md` (queries y mutations GraphQL directas) y
  `scripts/linear-client.ts` / `scripts/batch-issues.ts`.
- **Autenticación** → token por carril `LINEAR_API_KEY` en `.env.local` (gitignored). Header
  `Authorization: $LINEAR_API_KEY`, endpoint `https://api.linear.app/graphql`. Verificación mínima:
  una query `{ viewer { id name } }`.
- **Rate limits** → `references/04-rate-limits.md`.
- **Modelo de datos** → `references/01-data-model.md`.

## Equivalencias (tool histórica → operación GraphQL)

| Antes (retirado) | Ahora (GraphQL directo — ver 03) |
|---|---|
| listar/leer issues | query `issues(filter: {...})` / `issue(id:)` |
| crear/actualizar issue | mutation `issueCreate` / `issueUpdate` |
| comentar | mutation `commentCreate` |
| listar/crear project | query `projects` / mutation `projectCreate`/`projectUpdate` |
| búsqueda de issues | query `searchIssues(term: $q)` (full-text + vector search; reemplazo oficial recomendado por Linear de `issueSearch`, que sigue existiendo pero está deprecada) — o `issues(filter: { title: { containsIgnoreCase: $q } })` como filtro manual por título |

No añadir `.mcp.json` ni `claude mcp add` para Linear: la operación es por token.
