# Linear GraphQL — Cheatsheet

Referencia de queries y mutations GraphQL directas contra el API de Linear. **Esta es la vía operativa canónica del skill** (token-only, NO MCP): toda operación —interactiva o batch— va por la API GraphQL con `LINEAR_API_KEY` (header `Authorization: $LINEAR_API_KEY`, endpoint `https://api.linear.app/graphql`), vía el cliente en `scripts/linear-client.ts` o `curl` **cargando el token de forma segura** (nunca en argv — ver el bloque de autenticación de `SKILL.md`).

## Tabla de contenidos

1. [Endpoint y autenticación](#endpoint-y-autenticación)
2. [Estructura de queries](#estructura-de-queries)
3. [Queries esenciales](#queries-esenciales)
4. [Mutations esenciales](#mutations-esenciales)
5. [Filtros — la sintaxis](#filtros--la-sintaxis)
6. [Paginación con cursor](#paginación-con-cursor)
7. [Manejo de errores](#manejo-de-errores)
8. [SDK oficial @linear/sdk](#sdk-oficial-linearsdk)

## Endpoint y autenticación

**Endpoint**:

```text
POST https://api.linear.app/graphql
Content-Type: application/json
```

**Autenticación**:

```http
# Personal API key (sin "Bearer", único caso especial de Linear)
Authorization: lin_api_xxxxxxxxxxxxxxxxxxx

# OAuth access token (con "Bearer")
Authorization: Bearer <access_token>
```

**Schema vivo y explorable**:

- GraphiQL: navegar al schema
- Apollo Studio: <https://studio.apollographql.com/public/Linear-API/variant/current/schema/reference>

**Para obtener Personal API key**:
Settings → API → Personal API keys → Create new

## Estructura de queries

Linear usa **connections** (estilo Relay) para listas. Toda colección sigue:

```graphql
{
  edges { node { ...fields } }
  nodes { ...fields }   # shortcut, mismo resultado que edges.node
  pageInfo { hasNextPage endCursor hasPreviousPage startCursor }
}
```

**Toda query con muchos resultados debe usar `first: N`** (default 50). Sin `first` explícito Linear pagina 50 y consumes complejidad innecesaria.

## Queries esenciales

### Viewer (yo)

```graphql
query Me {
  viewer {
    id
    name
    email
    displayName
  }
}
```

### Listar teams

```graphql
query Teams {
  teams(first: 10) {
    nodes {
      id
      name
      key
      cyclesEnabled
      cycleDuration
    }
  }
}
```

### Listar issues con filtros (el caballo de batalla)

```graphql
query MyActiveIssues($cycleId: String) {
  issues(
    first: 50,
    filter: {
      assignee: { isMe: { eq: true } }
      state: { type: { in: ["started", "unstarted"] } }
      cycle: { id: { eq: $cycleId } }
    }
    orderBy: priority
  ) {
    nodes {
      id
      identifier
      title
      priority
      estimate
      state { name type }
      project { name }
      cycle { number }
      assignee { displayName }
      labels { nodes { name } }
      url
    }
    pageInfo { hasNextPage endCursor }
  }
}
```

### Issue específica con todo

```graphql
query Issue($id: String!) {
  issue(id: $id) {
    id
    identifier
    title
    description
    priority
    estimate
    state { name type }
    assignee { displayName email }
    project { name }
    cycle { number }
    projectMilestone { name }
    labels { nodes { id name } }
    parent { identifier title }
    children { nodes { identifier title state { name } } }
    branchName
    url
    attachments { nodes { title url } }
    comments(first: 50) {
      nodes {
        id
        body
        user { displayName }
        createdAt
      }
    }
  }
}
```

`$id` puede ser UUID o identifier (`TAL-42`).

### Listar projects de una initiative

```graphql
query InitiativeProjects($initiativeId: String!) {
  initiative(id: $initiativeId) {
    id
    name
    projects(first: 50) {
      nodes {
        id
        name
        state
        progress
        health
        targetDate
        lead { displayName }
        issueCount: issues { totalCount }
      }
    }
  }
}
```

### Initiative — leer y actualizar propiedades nuevas (status/priority/labels)

`last_verified: 2026-07-20` (introspección viva). `status` es un **enum fijo** del schema, no un workflow
state por team — por eso NO hay `statusId`, se envía `status:` directamente.

```graphql
query InitiativeDetail($id: String!) {
  initiative(id: $id) {
    id
    name
    status
    priority
    visibility
    labels(first: 20) { nodes { id name } }
  }
}
```

```graphql
mutation UpdateInitiative($id: String!, $input: InitiativeUpdateInput!) {
  initiativeUpdate(id: $id, input: $input) {
    success
    initiative { id status priority }
  }
}
```

```json
{
  "id": "<uuid o slugId de la initiative>",
  "input": {
    "status": "Active",
    "priority": 2,
    "labelIds": ["<uuid label>"]
  }
}
```

`InitiativeStatus` (enum, valores exactos): `Proposed | Planned | Active | Completed | Canceled`. **NO
confundir** `initiativeUpdate` (mutation que actualiza los CAMPOS de una Initiative — status/priority/labels)
con `initiativeUpdateCreate` (mutation que crea una entidad `InitiativeUpdate`, el status-update de texto
periódico — ver más abajo en "Initiative Update").

### Cycle activo y sus issues

```graphql
query CurrentCycle($teamId: String!) {
  team(id: $teamId) {
    activeCycle {
      id
      number
      startsAt
      endsAt
      progress
      issues(first: 100) {
        nodes {
          identifier
          title
          state { name type }
          assignee { displayName }
          estimate
        }
      }
    }
  }
}
```

### Búsqueda de issues (texto libre y filtros)

`last_verified: 2026-07-20` (introspección viva de `Query.issueSearch` / `Query.searchIssues`).
`issueSearch` está **deprecada** en el API de Linear — su propia `description` de schema lo dice
textualmente: *"[DEPRECATED] Search issues. This endpoint is deprecated and will be removed in the
future – use `searchIssues` instead."* **El reemplazo real es `searchIssues`** (full-text + vector
search, ranking por relevancia, rate-limited a 30 req/min — confirmado por introspección), **NO**
`issues(filter:)`:

```graphql
query FullTextSearch($term: String!) {
  searchIssues(term: $term, first: 20, includeComments: true) {
    nodes {
      identifier
      title
      state { name type }
      url
    }
  }
}
```

Para **filtros estructurados** (exact-match sobre campos concretos, sin ranking por relevancia) sigue
siendo correcto usar `issues(filter: {...})` con los operadores de texto (`contains`,
`containsIgnoreCase`) sobre `title`, `description` **y `comments.body`** (el `IssueFilter` soporta las
tres) — es una técnica distinta y complementaria a `searchIssues`, no un reemplazo de `issueSearch`.
Para no reducir el filtro a solo el título, combina los campos con `or`:

```graphql
query Search($q: String!) {
  issues(
    filter: { or: [
      { title:       { containsIgnoreCase: $q } }
      { description: { containsIgnoreCase: $q } }
      { comments:    { body: { containsIgnoreCase: $q } } }
    ] }
    first: 20
  ) {
    nodes {
      identifier
      title
      state { name type }
      url
    }
  }
}
```

## Mutations esenciales

### Crear issue

```graphql
mutation CreateIssue($input: IssueCreateInput!) {
  issueCreate(input: $input) {
    success
    issue {
      id
      identifier
      url
      branchName
    }
  }
}
```

Variables:

```json
{
  "input": {
    "teamId": "<uuid del team TAL>",
    "title": "Implementar OAuth en login (frontend)",
    "description": "## Contexto\n...\n\n## Criterios de aceptación\n- [ ] ...",
    "stateId": "<uuid del state Todo>",
    "projectId": "<uuid del project>",
    "projectMilestoneId": "<uuid del milestone>",
    "cycleId": "<uuid del cycle current>",
    "assigneeId": "<uuid del user>",
    "labelIds": ["<uuid label vertical/land-online>", "<uuid label kind:feat>"],
    "priority": 2,
    "estimate": 3,
    "parentId": null,
    "dueDate": "2026-05-15"
  }
}
```

### Actualizar issue

```graphql
mutation UpdateIssue($id: String!, $input: IssueUpdateInput!) {
  issueUpdate(id: $id, input: $input) {
    success
    issue { identifier title state { name } }
  }
}
```

`$id` acepta UUID o identifier (TAL-42).

**`labelIds` reemplaza el array completo.** `IssueUpdateInput.labelIds` sigue existiendo y sigue siendo un
reemplazo total del set de labels — enviar un `labelIds` parcial (sin todos los ids actuales) BORRA las
labels omitidas. Para escrituras concurrentemente seguras (añadir/quitar SIN leer primero el estado
actual) hay tres vías nativas verificadas contra el schema vivo (`last_verified: 2026-09-05`), preferibles
al patrón read-then-write-completo cuando dos procesos pueden tocar las labels de la misma issue a la vez:

**1. `issueAddLabel` / `issueRemoveLabel`** — una label a la vez, sin tocar las demás:

```graphql
mutation AddLabel($id: String!, $labelId: String!) {
  issueAddLabel(id: $id, labelId: $labelId) {
    success
    issue { identifier labels { nodes { id name } } }
  }
}

mutation RemoveLabel($id: String!, $labelId: String!) {
  issueRemoveLabel(id: $id, labelId: $labelId) {
    success
    issue { identifier labels { nodes { id name } } }
  }
}
```

**2. `IssueUpdateInput.addedLabelIds` / `.removedLabelIds`** — variante batch dentro de un `issueUpdate`
normal (útil cuando ya estás actualizando otros campos en la misma mutación y quieres añadir/quitar varias
labels a la vez):

```graphql
mutation UpdateIssueLabels($id: String!, $input: IssueUpdateInput!) {
  issueUpdate(id: $id, input: $input) {
    success
    issue { identifier labels { nodes { id name } } }
  }
}
```

```json
{
  "id": "TAL-42",
  "input": {
    "addedLabelIds": ["<uuid label nuevo>"],
    "removedLabelIds": ["<uuid label a quitar>"]
  }
}
```

Las tres formas (`labelIds` completo, `issueAddLabel`/`issueRemoveLabel`, `addedLabelIds`/
`removedLabelIds`) coexisten en el schema. Regla práctica: usa `labelIds` completo solo cuando ya tienes
el set final calculado (p. ej. al crear la issue); usa `issueAddLabel`/`issueRemoveLabel` o
`addedLabelIds`/`removedLabelIds` para cualquier add/remove incremental — evitan la carrera de
leer-el-estado-y-reenviar-el-array-completo (dos procesos que leen el mismo estado viejo y reenvían
arrays distintos, el segundo en escribir pisa al primero).

### Batch — issueBatchUpdate / issueBatchCreate

`last_verified: 2026-09-05`. Para actualizar o crear muchas issues a la vez, Linear expone dos mutations
batch nativas — evitan el loop de N mutations `issueUpdate`/`issueCreate` con throttle manual
(`references/04-rate-limits.md` documenta el throttle como fallback para lo que no cabe en un batch, no
como la vía principal).

**`issueBatchUpdate`** — aplica el MISMO `input: IssueUpdateInput!` a hasta **50 ids** por llamada:

```graphql
mutation BatchUpdate($ids: [UUID!]!, $input: IssueUpdateInput!) {
  issueBatchUpdate(ids: $ids, input: $input) {
    success
    issues { identifier state { name } }
  }
}
```

```json
{
  "ids": ["<uuid 1>", "<uuid 2>", "..."],
  "input": { "stateId": "<uuid state Done>" }
}
```

**`issueBatchCreate`** — crea hasta 50 issues nuevas en una sola mutation:

```graphql
mutation BatchCreate($input: IssueBatchCreateInput!) {
  issueBatchCreate(input: $input) {
    success
    issues { identifier url }
  }
}
```

```json
{
  "input": {
    "issues": [
      { "teamId": "<uuid team>", "projectId": "<uuid project>", "title": "Sub-tarea 1" },
      { "teamId": "<uuid team>", "projectId": "<uuid project>", "title": "Sub-tarea 2" }
    ]
  }
}
```

**⚠️ Gotcha del wrapper — falla en silencio, no en error.** `IssueBatchCreateInput` es un objeto WRAPPER
con un único campo `issues: [IssueCreateInput!]!`. Si la variable GraphQL se tipa mal como
`[IssueCreateInput!]!` directo (el array pelado, sin envolver en `{ issues: [...] }`), la mutation
**responde `success` y `{ issues: [] }` vacío — SIN error en `errors[]`** (fuente:
[gastownhall/beads PR #3703](https://github.com/gastownhall/beads/pull/3703), 2026-05-04, descubierto
dogfooding en prod — 9 issues enviados, 0 creados, sin diagnóstico). Confirmar SIEMPRE la forma
`{"input": {"issues": [...]}}`, y validar `issues.length === expected` tras la llamada, no solo `success`.
La mutation existe y su forma de uso está confirmada por un ingeniero de Linear
([linear/linear#210](https://github.com/linear/linear/issues/210), comentario oficial de sjdemartini,
2025-12-02): "poco más de un año" en el schema a esa fecha.

**`projectId` en CADA entrada, y comprobado antes de mutar.** Toda issue creada desde este
repositorio pertenece a un project de la initiative que le corresponde; una entrada sin `projectId`
crea una issue huerfana. Aqui eso duele especialmente porque es una mutation en LOTE: el descuido no
produce una issue mal puesta, produce hasta 50 de golpe. Y este documento es el que se copia para
operar Linear, asi que un ejemplo incompleto se propaga tal cual. La validacion va ANTES de llamar,
no despues: una vez creadas hay que borrarlas a mano.

```ts
// fail-closed: si a una sola entrada le falta el project, no se manda NINGUNA
const sinProject = issues.filter((i) => !i.projectId);
if (sinProject.length > 0) {
  throw new Error(
    `issueBatchCreate: ${sinProject.length}/${issues.length} entradas sin projectId — ` +
      `no se envia el lote (crearia issues huerfanas)`
  );
}
```

Tope confirmado en ambas direcciones: **50 ids/issues por llamada**. Para lotes mayores, particionar en
llamadas de 50.

### Crear comment

```graphql
mutation CreateComment($input: CommentCreateInput!) {
  commentCreate(input: $input) {
    success
    comment { id body url }
  }
}
```

```json
{
  "input": {
    "issueId": "<uuid de la issue>",
    "body": "Markdown content here",
    "parentId": null
  }
}
```

### Crear project con milestones

Linear requiere crear el project primero, luego los milestones referenciando el `projectId`:

```graphql
mutation CreateProject($input: ProjectCreateInput!) {
  projectCreate(input: $input) {
    success
    project { id name url }
  }
}
```

```json
{
  "input": {
    "teamIds": ["<team uuid>"],
    "name": "Lanzar Dashboard de Métricas v1",
    "description": "...",
    "leadId": "<user uuid>",
    "statusId": "<project status uuid — obtener con projectStatuses>",
    "startDate": "2026-05-11",
    "targetDate": "2026-09-30"
  }
}
```

`ProjectCreateInput` usa `statusId` (no un campo `state`) y **no** acepta `initiativeId(s)`: la
relación con la initiative se crea aparte tras el project, con `initiativeToProjectCreate(input: { initiativeId, projectId })`.

Después, para cada milestone:

```graphql
mutation CreateMilestone($input: ProjectMilestoneCreateInput!) {
  projectMilestoneCreate(input: $input) {
    success
    projectMilestone { id name }
  }
}
```

```json
{
  "input": {
    "projectId": "<project uuid>",
    "name": "M1: Diseño aprobado",
    "description": "...",
    "targetDate": "2026-06-15",
    "sortOrder": 1024
  }
}
```

### Project Update (status update semanal)

```graphql
mutation CreateProjectUpdate($input: ProjectUpdateCreateInput!) {
  projectUpdateCreate(input: $input) {
    success
    projectUpdate { id }
  }
}
```

```json
{
  "input": {
    "projectId": "<project uuid>",
    "body": "## Esta semana\n- ...\n\n## Próxima semana\n- ...\n\n## Bloqueos\n- ninguno",
    "health": "onTrack"
  }
}
```

`health` ∈ `onTrack` | `atRisk` | `offTrack`.

### Initiative Update

Análogo:

```graphql
mutation CreateInitiativeUpdate($input: InitiativeUpdateCreateInput!) {
  initiativeUpdateCreate(input: $input) {
    success
    initiativeUpdate { id }
  }
}
```

### Release — leer, crear y completar

`last_verified: 2026-07-20` (introspección viva de `mutationType.fields` + `Release`/`ReleaseCreateInput`).
Entidad de tracking CI/CD (ver `references/01-data-model.md#release`); el estado vive en `stage`, **no** en
un enum `ReleaseStatus` (ese nombre no existe en el schema).

```text
ReleasePipeline (releasePipelineCreate/Update)
      │ 1:N
      ▼
   Release (releaseCreate → releaseUpdate → releaseComplete)
      │ .stage: ReleaseStage!         ← el eje de estado, NO "ReleaseStatus"
      │      └─ .type: ReleaseStageType = planned | started | completed | canceled
      │ .issues (N)                   ← issueToReleaseCreate/Delete
      └ .releaseNotes (N)             ← releaseNoteCreate/Update/Delete
```

**Leer** (con el estado vía `stage.type`):

```graphql
query ReleasesOfPipeline($pipelineId: String!) {
  releasePipeline(id: $pipelineId) {
    id
    name
    releases(first: 20) {
      nodes {
        id
        name
        version
        commitSha
        stage { name type }
        startedAt
        completedAt
      }
    }
  }
}
```

**Crear** — `ReleaseCreateInput` **requiere `name` y `pipelineId`** (verificado por introspección; un
ejemplo sin `pipelineId` no es válido):

```graphql
mutation CreateRelease($input: ReleaseCreateInput!) {
  releaseCreate(input: $input) {
    success
    release { id name stage { type } }
  }
}
```

```json
{
  "input": {
    "name": "v1.4.0",
    "pipelineId": "<uuid del ReleasePipeline>",
    "version": "1.4.0",
    "commitSha": "<sha del commit desplegado>"
  }
}
```

**Completar** — a diferencia de `releaseUpdate`/`releaseDelete`/`releaseArchive` (que sí toman `id: String!`
del release concreto), `releaseComplete` **NO toma `id`**: solo `input: ReleaseCompleteInput!`, que requiere
`pipelineId: String!` — completa el release activo/actual de ese pipeline, no uno identificado por su propio
id (verificado por introspección de `Mutation.releaseComplete.args` y `ReleaseCompleteInput.inputFields`;
`last_verified: 2026-07-20`):

```graphql
mutation CompleteRelease($input: ReleaseCompleteInput!) {
  releaseComplete(input: $input) {
    success
    release { id stage { type } completedAt }
  }
}
```

```json
{
  "input": {
    "pipelineId": "<uuid del ReleasePipeline>",
    "version": "1.4.0"
  }
}
```

Otras mutations existentes (introspección): `releaseUpdate` (toma `id` + `input`), `releaseDelete`,
`releaseArchive` (toman `id`), `releaseUnarchive`, `releaseSync` (+ variantes `*ByAccessKey` para
integraciones CI/CD sin sesión de usuario), y las familias `releasePipeline*` / `releaseStage*` /
`releaseNote*` / `issueToRelease*`.

### Crear sub-issue

Igual que `issueCreate`, pero pasando `parentId`:

```json
{
  "input": {
    "teamId": "...",
    "title": "Sub-tarea: refactor del cliente HTTP",
    "parentId": "<uuid del issue parent>",
    "labelIds": [...]
  }
}
```

### Issue relations (block / relate / duplicate)

```graphql
mutation CreateIssueRelation($input: IssueRelationCreateInput!) {
  issueRelationCreate(input: $input) {
    success
    issueRelation { id }
  }
}
```

```json
{
  "input": {
    "issueId": "<uuid issue A>",
    "relatedIssueId": "<uuid issue B>",
    "type": "blocks"
  }
}
```

`type` ∈ `blocks` | `duplicate` | `related` | `similar` (enum `IssueRelationType`, **4 valores** —
`similar` marca una issue parecida sin ser bloqueante ni duplicado exacto, `last_verified: 2026-09-05`
contra el SDL vivo).

### Labels — crear (issueLabelCreate)

`last_verified: 2026-09-05`. Da de alta un label nuevo (de team o de workspace) vía API:

```graphql
mutation CreateLabel($input: IssueLabelCreateInput!, $replaceTeamLabels: Boolean) {
  issueLabelCreate(input: $input, replaceTeamLabels: $replaceTeamLabels) {
    success
    issueLabel { id name color teamId }
  }
}
```

```json
{
  "input": {
    "name": "vertical/nuevo-producto",
    "color": "#5E6AD2",
    "description": "Trabajo del vertical Nuevo Producto",
    "teamId": null,
    "parentId": null,
    "isGroup": false
  }
}
```

Campos de `IssueLabelCreateInput`: `name!` (único por scope), `color`, `description`, `parentId` (label
padre, para grupos jerárquicos), `teamId` (omitir/null = label de **workspace**; con uuid = label de
**team**), `isGroup` (crea un label-contenedor sin aplicación directa, solo agrupa hijos).

**Gotchas de scope**: el scope (team vs workspace) queda **fijo al crear** — no existe mutation para
mover un label de team a workspace o viceversa después; hay que borrar y recrear (perdiendo el historial
de aplicación). El nombre debe ser único **dentro de su scope**: dos labels del mismo nombre pueden
coexistir si uno es de team A y otro de team B, pero no dos labels de workspace con el mismo nombre, ni
dos del mismo team (fuente: [linear/linear#159](https://github.com/linear/linear/issues/159),
[#633](https://github.com/linear/linear/pull/633), [#428](https://github.com/linear/linear/issues/428) —
confirmado oficialmente por pauldijou, ingeniero de Linear).

### Customer Need (vincular feedback a issue)

```graphql
mutation CreateCustomerNeed($input: CustomerNeedCreateInput!) {
  customerNeedCreate(input: $input) {
    success
    need { id }
  }
}
```

```json
{
  "input": {
    "customerId": "<uuid del customer interno (ej: equipo Media)>",
    "body": "Descripción del feedback recibido",
    "issueId": "<uuid del issue de desarrollo>",
    "priority": 1
  }
}
```

Nota: el payload de `customerNeedCreate` expone **`need`** (no `customerNeed`), y `priority` usa la
escala de Customer Need (**0 = sin prioridad, 1 = importante**), NO la escala 1-4 de los issues.

### Plantillas (templates)

`last_verified: 2026-09-05`. Una plantilla (`Template`) precarga campos de `IssueCreateInput` (título,
descripción, labels, estimate...) para acelerar la creación de issues repetitivas — el team TAL ya usa 9
plantillas `issue-craft: <tipo>` (gestionadas por `talent-issue-craft`, no por este skill).

```graphql
mutation CreateTemplate($input: TemplateCreateInput!) {
  templateCreate(input: $input) {
    success
    template { id name type }
  }
}
```

```json
{
  "input": {
    "name": "Bug — reproducción mínima",
    "type": "issue",
    "teamId": "<uuid del team, NO el key>",
    "templateData": { "title": "", "description": "## Pasos para reproducir\n1. ...", "priority": 2 }
  }
}
```

Campos requeridos: `name!`, `templateData: JSON!`, `type!` (string libre, p. ej. `"issue"`/`"project"`).
`teamId` es opcional (ausente = plantilla de workspace).

```graphql
mutation DeleteTemplate($id: String!) {
  templateDelete(id: $id) { success }
}
```

**Gotchas**:

- **`teamId` exige el UUID del team**, aunque la introspección del campo lo describa en prosa como
  "identifier or key" — pasar el `key` corto (p. ej. `"TAL"`) falla; usar siempre el uuid devuelto por
  `teams { nodes { id } }`.
- **El round-trip de `templateData` es semántico, no textual.** Lo que se lee de vuelta (`Template.
  templateData`) puede reordenar claves o normalizar valores por defecto respecto a lo enviado — comparar
  por igualdad de campos relevantes, nunca por igualdad de string JSON exacta.
- **`issueCreate` admite `templateId` y `description` en la misma llamada** — cuando ambos están
  presentes, la `description` explícita del input **manda** sobre la de la plantilla (no se fusionan ni
  se concatenan).
- Query nueva `templateSearch(filter: TemplateFilter, first: Int = 50, includeArchived: Boolean = false)`
  (SDK 93.0.0, 2026-09-03) — busca plantillas por texto en vez de listar `templates`/
  `templatesForIntegration` completos.

Contrato completo (incluida la taxonomía de 9 tipos × variantes usada por Talent Engine) en
`talent-issue-craft/references/03-linear-nativo.md` §3.6 — este cheatsheet solo cubre la mutation nativa
de Linear, no la capa de curaduría de plantillas del proyecto.

### Agent activity (solo si construyes un agente propio)

Ver `references/06-agents-sdk.md` para detalle completo.

```graphql
mutation CreateAgentActivity($input: AgentActivityCreateInput!) {
  agentActivityCreate(input: $input) {
    success
    agentActivity { id }
  }
}
```

## Filtros — la sintaxis

Los filtros de Linear son objetos anidados con operadores. La estructura general:

```graphql
filter: {
  <field>: { <operator>: <value> }
}
```

**Lista completa de comparadores** (`last_verified: 2026-09-05`, oficial —
[developers.linear.app/filtering](https://linear.app/developers/filtering)):

- `eq`, `neq` — equals / not equals
- `in`, `nin` — array de valores
- `lt`, `lte`, `gt`, `gte` — comparaciones (numéricos/fecha)
- `eqIgnoreCase`, `neqIgnoreCase` — equals/not-equals sin distinguir mayúsculas
- `startsWith`, `notStartsWith` — string
- `endsWith`, `notEndsWith` — string
- `contains`, `notContains` — substring
- `containsIgnoreCase`, `notContainsIgnoreCase` — substring sin distinguir mayúsculas
- `null` — boolean (true = es null)

No todos los campos aceptan todos los operadores (los numéricos/fecha no exponen `contains`, por
ejemplo) — el set exacto depende del tipo de comparador del campo (`StringComparator`, `IDComparator`,
`DateComparator`, ...).

**Combinadores**: los campos de un mismo objeto `filter: { ... }` se funden con **AND implícito** (no
hace falta escribir `and:` para combinar condiciones sobre campos distintos — ver el segundo ejemplo de
abajo, que usa `and:` explícito de forma equivalente a solo poner ambos campos al mismo nivel). `or:`
es explícito y obligatorio para lógica OR (array de sub-filtros). `and:` también existe como campo de
los tipos `*Filter` cuando se prefiere agrupar explícitamente (por ejemplo, dentro de una rama de un
`or:`).

**Nota de tipo (`@linear/sdk` 90.0.0, 13-ago-2026)**: los filtros `id` de `Initiative`/`Project` (y sus
variantes `*CollectionFilter`/`Nullable*Filter`) cambiaron de `IDComparator` a
**`EntityIdentifierIDComparator { eq: ID, in: [ID!], neq: ID }`** — un comparador más reducido (sin
`nin`/`lt`/etc.) pensado para aceptar tanto el UUID como el `identifier` legible (`P-<team>-<n>`) de
Project. Si filtras `issues(filter: { project: { id: { eq: ... } } })` o `initiative: { id: {...} }`,
usa solo `eq`/`in`/`neq` — los demás operadores de `IDComparator` no están garantizados en este tipo.

**Ejemplos**:

```graphql
# Issues con label vertical/media O vertical/land-online
filter: {
  or: [
    { labels: { name: { eq: "vertical/media" } } }
    { labels: { name: { eq: "vertical/land-online" } } }
  ]
}

# Issues started Y priority high+
filter: {
  and: [
    { state: { type: { eq: "started" } } }
    { priority: { lte: 2 } }
  ]
}

# Issues sin assignee
filter: {
  assignee: { null: true }
}

# Issues asignadas a mí o delegadas a un agente
filter: {
  or: [
    { assignee: { isMe: { eq: true } } }
    { delegate: { id: { eq: "<agente uuid>" } } }
  ]
}

# Issues creadas en los últimos 7 días con label actor/ai
filter: {
  and: [
    { createdAt: { gte: "2026-04-27T00:00:00Z" } }
    { labels: { name: { eq: "actor/ai" } } }
  ]
}
```

**Helper especial**: `assignee: { isMe: { eq: true } }` para filtrar por el viewer actual sin necesidad de su UUID.

## Paginación con cursor

```text
┌──────────────────────────┐   after=null    ┌───────────────────────────┐
│ issues(first:50,          │────────────────▶│ pageInfo.hasNextPage?       │
│ after:$after)              │                  └─────────────┬───────────────┘
└────────────▲──────────────┘                                 │ true
             │        after = endCursor                        │
             └─────────────────────────────────────────────────┘
                                                                │ false
                                                                ▼
                                                     ┌─────────────────────┐
                                                     │ allIssues completo   │
                                                     └─────────────────────┘
```

Para iterar sobre muchas issues:

```graphql
query Page($after: String) {
  issues(first: 50, after: $after, filter: { ... }) {
    nodes { ... }
    pageInfo { hasNextPage endCursor }
  }
}
```

Patrón en código:

```typescript
let after: string | null = null;
const allIssues = [];

while (true) {
  const result = await client.query({ first: 50, after, filter: {...} });
  allIssues.push(...result.nodes);
  if (!result.pageInfo.hasNextPage) break;
  after = result.pageInfo.endCursor;
}
```

**`orderBy` y el tope de `first`** (`last_verified: 2026-09-05`):

- El orden por defecto de toda connection es **`createdAt`**. Pasa `orderBy: updatedAt` cuando lo que
  importa es lo más reciente MODIFICADO, no lo más reciente CREADO — típico en jobs de sync incremental
  (traer solo lo que cambió desde el último `updatedAt` visto, sin repaginar el dataset completo).
- `first` tiene un **máximo de 250** en toda connection (además del default de 50 si se omite). Pasar
  `first: 251` o más devuelve HTTP 400 con `extensions.code: "INVALID_INPUT"` y el mensaje literal
  `"first must not be greater than 250"` (medido en vivo 2026-09-05). Para traer más de 250 resultados,
  pagina con `after`/`endCursor` en vez de subir `first`.

```graphql
query RecentlyUpdated($after: String) {
  issues(first: 250, after: $after, orderBy: updatedAt, filter: { ... }) {
    nodes { id updatedAt }
    pageInfo { hasNextPage endCursor }
  }
}
```

**Campos nuevos útiles para reporting/auditoría** (`last_verified: 2026-09-05`, verificados contra el
SDL vivo):

| Campo | Tipo | Uso |
|---|---|---|
| `Issue.stateHistory` | connection | reconstruir el histórico de cambios de `state` de una issue — útil para auditar flujo (¿cuánto tiempo estuvo en "In Review"?) sin depender de `history` genérico |
| `Project.identifier` | `String!` | identificador legible `P-<team>-<n>` (distinto del UUID), GA (sin `[ALPHA]`) desde `@linear/sdk` 89.0.0/91.0.0 |
| `Issue.customerTicketCount` | `Int!` | nº de Customer Needs vinculados a la issue |
| `Issue.activitySummary` | `JSONObject` | resumen agregado de actividad de la issue |
| `Comment.documentContent` | `DocumentContent` | vínculo comentario↔Document (comentarios anclados a un Document, no solo a una issue) |

Query nueva: `templateSearch` — ver sección "Plantillas (templates)" arriba.

**Nota sobre `issueSearch`**: sigue existiendo en el schema y su introspección estándar (`isDeprecated`)
no lo marca como deprecado — la deprecación real vive solo en el texto libre de su `description`
(`"[DEPRECATED] ... use searchIssues instead."`). Cualquier tooling que filtre deprecaciones solo por el
flag `isDeprecated` se pierde este caso; grepear también las `description` por `[DEPRECATED]`/
`Deprecated` si automatizas un audit de schema.

### Archivar o borrar un project (`projectDelete`)

`projectArchive` está **deprecada** en el schema vivo (`deprecationReason`: «Deprecated in favor of
projectDelete», verificado 2026-09-05). Usa `projectDelete` (el project queda en la papelera y es
recuperable con `projectUnarchive`/restauración desde la UI durante el periodo de retención):

```graphql
mutation ProjectDelete($id: String!) {
  projectDelete(id: $id) { success }
}
```

## Manejo de errores

**Errores de validación** vienen en el array `errors` de la respuesta:

```json
{
  "errors": [
    {
      "message": "Argument 'teamId' is required but was not provided.",
      "extensions": {
        "type": "invalid input",
        "userPresentableMessage": "Team is required to create an issue."
      }
    }
  ]
}
```

**⚠️ HTTP 200 no significa éxito.** Linear devuelve `200 OK` incluso cuando una mutation FALLA — el error
solo aparece en el array `errors[]` del body (fuente:
[commit OmniNode-ai/omniclaude](https://github.com/OmniNode-ai/omniclaude/commit/7b116a607b6d4b172548c6ecabfb64e6e4adbace),
2026-04-18, fix motivado por hallazgo de code review). Comprueba SIEMPRE `errors` antes de leer `data`,
sin importar el status HTTP:

```typescript
const res = await fetch(GRAPHQL_ENDPOINT, { method: "POST", headers, body });
const json = await res.json();
if (json.errors?.length) {
  throw new LinearGraphQLError(json.errors); // NUNCA asumir éxito solo por status 200
}
return json.data;
```

### Tabla de códigos (`extensions.code`)

`last_verified: 2026-09-05`. Distinguir el código es obligatorio antes de decidir si reintentar:

| `extensions.code` | HTTP | Significado | ¿Reintentar? |
|---|---|---|---|
| `RATELIMITED` | 400 | Cuota de requests o complexity agotada | **Sí** — backoff (fijo o `X-RateLimit-*-Reset`, en epoch UTC ms) |
| `INPUT_ERROR` | 400 | Complejidad de la query > 10.000 puntos | **No** — es un bug de diseño de query, no un throttle; reintentar falla siempre igual. Rediseñar (trocear, bajar `first`, quitar niveles de anidamiento; introspección por trozos) |
| `INVALID_INPUT` | 400 | Argumento inválido a nivel de valor (p. ej. `first: 251` → "first must not be greater than 250") | **No** — corregir el argumento |
| `GRAPHQL_VALIDATION_FAILED` | 400 | Campo o tipo inexistente en el schema (query mal formada) | **No** — error de programación, corregir la query |
| — (sin `errors[]`, HTTP 200) | 200 | Éxito real | — |
| — (respuesta vacía o no-JSON) | variable | Fallo transitorio de red/transporte | **Sí** — backoff; si la mutation NO es idempotente (p. ej. `issueCreate`), dedupe por título/clave natural antes de reintentar para no crear duplicados |

`INPUT_ERROR` e `INVALID_INPUT` son **códigos distintos** pese al nombre parecido — no fusionarlos en el
mismo `if`. Un `withRetry()` que solo intercepte `RATELIMITED` (como versiones previas de este cheatsheet)
agota `maxRetries` sin motivo ante `INPUT_ERROR`/`INVALID_INPUT`/`GRAPHQL_VALIDATION_FAILED`, porque el
resultado es idéntico en cada intento.

Manejo recomendado — reintenta SOLO `RATELIMITED` y fallos de transporte, nunca los tres códigos
"no reintentar":

```typescript
// `idempotent` es OPT-IN y por defecto FALSE: un fallo de transporte es AMBIGUO, así que
// sin declaración explícita del caller NO se reintenta. Misma puerta que
// `scripts/linear-client.ts` — aquí se declara en la FIRMA, no solo en la condición.
async function withRetry<T>(
  fn: () => Promise<T>,
  maxRetries = 3,
  idempotent = false,
): Promise<T> {
  const NO_RETRY = new Set(["INPUT_ERROR", "INVALID_INPUT", "GRAPHQL_VALIDATION_FAILED"]);

  for (let i = 0; i < maxRetries; i++) {
    try {
      return await fn();
    } catch (e: any) {
      const code = e.code ?? e.errors?.[0]?.extensions?.code;
      // El codigo lo pone la CLASIFICACION del transporte (`classifyGraphQLFailure` sobre
      // `response.text()`), NO `e instanceof TypeError`: un body vacio o no-JSON llega como
      // respuesta HTTP EXITOSA y no lanza nada, asi que mirar solo lo que lanza el cliente HTTP
      // deja fuera los dos fallos transitorios mas frecuentes. Estos son AMBIGUOS —la operacion
      // pudo aplicarse y perderse la RESPUESTA—, asi que se reintentan solo con la operacion
      // declarada idempotente. Mismo conjunto que `FALLOS_AMBIGUOS` de `scripts/linear-client.ts`:
      // si divergen, este ejemplo ensena otra cosa que la que el cliente hace.
      const AMBIGUOS = new Set(["EMPTY_BODY", "INVALID_JSON", "UNKNOWN"]);
      const isRetryable = code === "RATELIMITED" || (AMBIGUOS.has(code) && idempotent === true);

      if (code && NO_RETRY.has(code)) throw e; // bug de diseño/programación — no insistir
      if (isRetryable && i < maxRetries - 1) {
        const delay = Math.pow(2, i) * 1000; // exponential backoff
        await new Promise(r => setTimeout(r, delay));
        continue;
      }
      throw e;
    }
  }
  throw new Error("max retries reached");
}
```

Las dos polaridades, que es lo que hace legible la puerta:

```typescript
await withRetry(() => client.query(LISTA_ISSUES, vars));                  // lectura: 1 intento ante transporte
await withRetry(() => client.query(ISSUE_BATCH_UPDATE, vars), 3, true);  // idempotente declarado: sí reintenta
```

## SDK oficial @linear/sdk

Para JavaScript/TypeScript hay un SDK que abstrae GraphQL.

**Versión actual: `93.0.1`** (publicada 2026-09-04, no deprecada — `last_verified: 2026-09-05` vía
`npm view @linear/sdk dist-tags version` / `npm view @linear/sdk deprecated`). `engines.node: >=18.x`
(idéntico en todas las versiones intermedias del rango auditado — sin requisito nuevo de Node); publicación
dual **ESM/CJS** vía `exports` del package
(`./dist/index.mjs` / `./dist/index.cjs`) más el subpath **`@linear/sdk/webhooks`** (verificación de
firma HMAC lista para usar, alternativa a implementarla a mano).

**Cadencia de majors medida** (~7-8 días entre versiones, todas con al menos un breaking change de
schema marcado por `graphql-inspector`):

| Versión | Fecha | Breaking relevante para CRUD de issues/projects |
|---|---|---|
| 89.0.0 | 2026-07-30 | No (namespace `*ByAccessKey` de Releases/CD) |
| 90.0.0 | 2026-08-13 | **Sí** — filtros `id` de `Initiative`/`Project` cambian a `EntityIdentifierIDComparator` (ver sección Filtros) |
| 91.0.0 | 2026-08-21 | No (namespace `AiConversation*`/Jira) |
| 92.0.0 | 2026-08-27 | No (`FetchDataPayload` eliminado, campo no usado por este skill) |
| 93.0.0 | 2026-09-03 | No (namespace `AiConversation*`); además **`cycleCreate` deprecada** ("Cycle creation is not supported" — el team TAL no usa cycles, sin impacto práctico hoy) |

**Un major no implica que tu integración se rompió.** La política de versionado del SDK dispara un major
por CUALQUIER cambio marcado `breaking` por su tooling, aunque viva en un namespace que nunca toques
(`AiConversation*`, `*ByAccessKey` de Releases). De los 5 majors del rango 89→93, solo **90.0.0** tiene
probabilidad real de afectar un consumidor típico de issues/projects. Antes de bloquear un upgrade por
"es un major": **leer el CHANGELOG y filtrar por los tipos que realmente consultas**, no descartarlo a
ciegas.

**Re-verifica la versión antes de fijarla en un `package.json`** — no asumas que `93.0.1` sigue siendo la
última en el momento en que leas esto:

```bash
npm view @linear/sdk version   # re-verificar SIEMPRE antes de pinear
```

**Instalación**:

```bash
npm install @linear/sdk@latest
```

**Uso básico**:

```typescript
import { LinearClient } from "@linear/sdk";

const client = new LinearClient({ apiKey: process.env.LINEAR_API_KEY! });
// o: new LinearClient({ accessToken: oauthToken });

const me = await client.viewer;
console.log(me.email);

// Listar issues
const issues = await client.issues({
  first: 50,
  filter: {
    assignee: { isMe: { eq: true } },
    state: { type: { eq: "started" } }
  }
});

for (const issue of issues.nodes) {
  console.log(issue.identifier, issue.title);
}

// Crear issue
const result = await client.createIssue({
  teamId: "<team uuid>",
  title: "Test",
  description: "...",
  priority: 2
});

if (result.success) {
  const created = await result.issue;
  console.log(created.identifier);
}

// Actualizar
await client.updateIssue("TAL-42", {
  stateId: "<uuid>",
  assigneeId: "<uuid>"
});
```

**Iterator pattern** del SDK:

```typescript
let after: string | undefined;
do {
  const page = await client.issues({ first: 50, after });
  for (const issue of page.nodes) {
    // process
  }
  after = page.pageInfo.endCursor;
} while (page.pageInfo.hasNextPage);
```

**Manejo de errores del SDK — `LinearError`/`RatelimitedLinearError`**: si usas el SDK real (no el
cliente `fetch` propio de `scripts/linear-client.ts`), no hace falta re-parsear las cabeceras `X-RateLimit-*`
a mano — `RatelimitedLinearError` ya las expone parseadas:

```typescript
import { RatelimitedLinearError } from "@linear/sdk";

try {
  await client.createIssue({ teamId, title });
} catch (e) {
  if (e instanceof RatelimitedLinearError) {
    console.log(e.retryAfter, e.requestsLimit, e.requestsRemaining, e.complexityRemaining);
  }
  throw e;
}
```

**`rawRequest`**: para necesitar la respuesta cruda (headers/status, no solo `data`), el cliente expone
`client.client.rawRequest(document, variables)` (`LinearGraphQLClient.rawRequest`) — útil para leer
`x-complexity` de una mutation ejecutada con el SDK, en vez de solo con `fetch` directo.

Detalles completos en <https://linear.app/developers/sdk>

Para un cliente listo para usar, ver `scripts/linear-client.ts` en este skill.
