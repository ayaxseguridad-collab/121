# Prompt — Buscar y deduplicar

Plantilla para encontrar issues en el workspace antes de crear, modificar o reportar. La búsqueda eficiente es el cimiento del trabajo limpio en Linear. **Todo por la API GraphQL directa** (token-only, `LINEAR_API_KEY`); ver `references/03-graphql-cheatsheet.md` para el esqueleto de request.

## Cuándo usar

- Antes de crear cualquier issue (dedupe)
- Cuando el humano pregunta "¿hay algo sobre X?"
- Cuando reportes el estado de un área
- Para auditoría de un tema (ej: "todos los bugs de auth")

## Estrategias de búsqueda

### A — Búsqueda por texto (title + description)

`issues(filter:)` filtra sobre `title`/`description` **y también sobre `comments.body`** con
`containsIgnoreCase` (el `IssueFilter` soporta `comments: { body: {...} }`). Para no dejar fuera el
cuerpo del issue ni sus comentarios, combinar los tres campos con `or`:

```graphql
query Search($q: String!, $after: String) {
  issues(
    filter: {
      team: { key: { eq: "TAL" } }
      or: [
        { title:       { containsIgnoreCase: $q } }
        { description: { containsIgnoreCase: $q } }
        { comments:    { body: { containsIgnoreCase: $q } } }
      ]
    }
    first: 50
    after: $after
  ) {
    pageInfo { hasNextPage endCursor }
    nodes { identifier title state { name type } priority url }
  }
}
```

**Abortar si la respuesta trae `errors`** — no seguir con los `nodes` que hayan venido. Una consulta que falla devuelve vacio, y ese vacio se lee como «no hay duplicados»: se crea la issue igual y el dedupe no ha ocurrido nunca. Un cero por no haber mirado se lee exactamente igual que un cero bueno, y aqui el precio es una issue duplicada en el tracker.

**Paginar SIEMPRE** (una sola página omite resultados y produce duplicados en dedupe): `first` es el
tamaño de página; repetir la query pasando `after: <endCursor>` mientras `pageInfo.hasNextPage` sea
`true`, acumulando `nodes`. Este patrón (pageInfo + cursor + `team: { key: { eq: "TAL" } }`) es el
canónico para TODA búsqueda/lista del skill; los workflows lo referencian.

Para varios términos, repetir el patrón `or` por keyword (Linear soporta `or`/`and` anidados).
Buscar por **3-5 keywords** distintas en pasadas separadas es más fiable que una sola frase larga.

### B — Búsqueda por filtro estructurado

```graphql
query Filtered {
  issues(
    filter: {
      team:     { key: { eq: "TAL" } }
      labels:   { name: { eq: "vertical/media" } }
      state:    { type: { eq: "started" } }
      priority: { eq: 2 }
    }
    first: 50
  ) {
    nodes { identifier title priority state { name } assignee { name } }
  }
}
```

### C — Búsqueda por relación

```graphql
# Sub-issues de una issue                → filter: { parent: { id: { eq: "<uuid-TAL-100>" } } }
# Issues de un project                   → filter: { project: { name: { eq: "Auth v2" } } }
# Issues de un milestone                 → filter: { projectMilestone: { id: { eq: "<uuid>" } } }
# Issues del cycle activo                → filter: { cycle: { isActive: { eq: true } } }
# Issues del cycle nº 12                  → filter: { cycle: { number: { eq: 12 } } }
# Issues de una initiative (vía projects) → filter: { project: { initiatives: { name: { eq: "Talent Land Online 2026" } } } }
```

Todos como el `filter:` de la query de la sección B (mismo esqueleto, cambia el objeto `filter`).

## Patrones de deduplicación

### Patrón 1 — Antes de crear una issue nueva

Workflow recomendado:

```text
1. Extraer 3-5 keywords del title propuesto
2. Buscar con la query de la sección A (or sobre title+description), first: 10, por keyword
3. Filtrar mentalmente:
   - Same intent + state abierto → potencial duplicado
   - Same intent + state cerrado → potencial regresión
   - Related pero distinto → relacionar al crear
4. Decidir:
   a) Si claro duplicado → comentar en existente (mutation commentCreate), no crear
   b) Si potencial duplicado → preguntar al humano
   c) Si solo relacionado → crear nueva con relation
   d) Si nada parecido → crear nueva (mutation issueCreate)
```

Mostrar al humano:

```text
Encontré estas issues similares al pedido:

🟢 TAL-87 "Implementar export PDF dashboard" — Backlog, prioridad medium, 3 puntos
🟡 TAL-65 "Export del dashboard en Excel" — Done hace 2 meses
⚫ TAL-23 "Dashboard exports varios" — Canceled hace 6 meses

Opciones:
A) Comentar y subir prioridad de TAL-87 (parece exactamente lo pedido)
B) Crear nueva, relacionada con TAL-87 (si es feature distinta)
C) No es nada de lo anterior, crear nueva sin relación

¿Cuál?
```

### Patrón 2 — Auditoría temática

Cuando el humano pregunta "¿qué tenemos pendiente sobre auth?":

```text
1. Búsqueda amplia: query de la sección A con or sobre keywords (auth, login, oauth, password), first: 50
2. Filtrar por state si tiene sentido:
   añadir al filter: state: { type: { in: ["backlog", "unstarted", "started"] } }
3. Agrupar por: state / initiative-project / owner (en código, sobre los nodes)
4. Reportar resumido, no listado entero.
```

Output esperado:

```text
Issues abiertas relacionadas con auth (12 total):

🚧 In Progress (2):
- TAL-101 "OAuth en login" — @persona, 3 ptos, cycle actual

📋 Todo (3):
- TAL-95, TAL-103, TAL-110 — total 8 ptos

🗂️ Backlog (7):
- 4 features (varias prioridades)
- 3 bugs (priority low/medium)

¿Quieres que profundice en alguno?
```

### Patrón 3 — Búsqueda histórica (regresiones)

Para detectar regresiones, incluir archivadas y estados cerrados:

```graphql
query Historic($q: String!, $after: String) {
  issues(
    filter: {
      team: { key: { eq: "TAL" } }
      or: [ { title: { containsIgnoreCase: $q } }, { description: { containsIgnoreCase: $q } }, { comments: { body: { containsIgnoreCase: $q } } } ]
      state: { type: { eq: "completed" } }
    }
    includeArchived: true
    first: 10
  ) {
    nodes { identifier title state { name } completedAt url }
  }
}
```

Si hay issue cerrada que matchea, evaluar si es regresión:

```text
🔍 TAL-65 "Login falla con caracteres especiales" — Done hace 4 meses

Si el bug actual es similar, es regresión. Crear nuevo bug, relacionar
como `relatedTo` el viejo, mencionar en description que es regresión
y el commit que lo corrigió antes para investigar qué cambió.
```

## Búsqueda en customer needs

A veces lo que pides existe en el contexto de Customer Needs. **`CustomerNeedFilter` NO permite filtrar
por `body`** (solo `id`, fechas, `priority`, `project`, `issue`, `comment`, `customer`) — no hay
búsqueda textual server-side. Dos vías soportadas:

1. **Acotar por relación y filtrar el `body` en código**: trae los needs de un customer/project/issue
   conocido y filtra el texto localmente (paginando con `after`):

   ```graphql
   query CustomerNeedsScoped($customerId: ID!, $after: String) {
     customerNeeds(filter: { customer: { id: { eq: $customerId } } }, first: 50, after: $after) {
       pageInfo { hasNextPage endCursor }
       nodes { id body customer { name } issue { identifier title state { name } } project { name } }
     }
   }
   # luego, en código: nodes.filter(n => n.body.toLowerCase().includes(q.toLowerCase()))
   ```

2. **Buscar por el issue** (que sí es filtrable por texto, ver §A) y leer sus needs: un tema con
   demanda suele tener issue asociado; desde el issue se navega a `needs { nodes { body } }` (el
   campo inverso en `Issue` es **`needs`** / `formerNeeds` — `customerNeeds` es solo la query raíz).

Cualquiera de las dos encuentra **demanda de usuarios** alrededor de un tema.

## Errores comunes en búsqueda

❌ **Buscar por título muy corto**: "auth" devuelve cientos de matches. Usa 3-5 keywords.

❌ **Asumir que una query sin `first` devuelve todo**: la paginación por defecto es limitada. Usa filtros + `first` explícito y pagina con `after`.

❌ **Olvidar `includeArchived: true` cuando buscas histórico**: por defecto solo devuelve no archivadas.

❌ **Buscar solo en `title`**: el `description` (y los comentarios) tienen mucho más contexto. Usa siempre el `or` sobre `title` + `description` + `comments.body` — los tres SON filtrables por `issues(filter:)`.

❌ **No agrupar/resumir resultados**: 30 issues sin estructura es ruido. Agrupa por state/owner/initiative.

❌ **Tomar el primer match como "el correcto"**: revisa los siguientes 3-5 también; las palabras pueden engañar.

## Tip — guardar búsquedas frecuentes

Para queries recurrentes, crear **Custom Views** en Linear UI:

```text
- "Mis issues del cycle actual" — filtros: assignee=me, cycle=current
- "Bugs urgent abiertos" — kind:fix + priority<=2 + state.type IN [unstarted, started]
- "Trabajo IA pendiente review" — label actor/ai + state=In Review
- "Backlog priorizado vertical/media" — vertical/media + state=Backlog + priority<=3
```

Las custom views son colaborativas (las ven todos los del team) o personales.
