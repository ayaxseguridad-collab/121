# Linear — Modelo de datos

Referencia completa de las entidades de Linear y sus relaciones. Lee este documento cuando necesites entender qué campo va dónde, qué relaciones existen entre entidades, o qué propiedades soporta cada objeto.

## Tabla de contenidos

1. [Jerarquía conceptual](#jerarquía-conceptual)
2. [Workspace](#workspace)
3. [Team](#team)
4. [Initiative](#initiative)
5. [Project](#project)
6. [Milestone](#milestone)
7. [Cycle](#cycle)
8. [Release](#release)
9. [Issue](#issue) ← entidad central
10. [Sub-issues e issue relations](#sub-issues-e-issue-relations)
11. [Workflow State](#workflow-state)
12. [Label](#label)
13. [Comment](#comment)
14. [Attachment](#attachment)
15. [Document](#document)
16. [Customer y Customer Need](#customer-y-customer-need)
17. [User vs App User (agente)](#user-vs-app-user-agente)
18. [Agent Session y Agent Activity](#agent-session-y-agent-activity)
19. [AgentSkill](#agentskill)
20. [Otras entidades](#otras-entidades-relevantes)

## Jerarquía conceptual

```text
Workspace (Talent Engine)
├── Initiatives (workspace-level, atraviesan teams; 10 activas, medido 2026-09-05)
│   ├── Talent Engine (meta — capa de orquestación/coordinación de la fábrica)
│   ├── Talent Portafolio
│   ├── Genius Arena
│   ├── Talent Sales Suite 2026
│   ├── Event Engine 2026
│   ├── Academia Ejemplo 2026 (producto — TODO issue de producto de este repo va aquí)
│   ├── Talent Land
│   ├── Bootcamp Cripto 2026
│   ├── Talent Land Online 2026
│   └── Talent Media 2026
│
├── Teams
│   └── Talent Engine (TAL)
│       ├── Cycles (desactivados en TAL — ver sección Cycle)
│       ├── Workflow States (Backlog → Todo → In Progress/In Review/Awaiting push approval →
│       │   Done/Canceled/Duplicate; TAL no tiene estado `triage` hoy — ver sección Workflow State)
│       ├── Issues
│       │   ├── Sub-issues
│       │   ├── Comments
│       │   ├── Attachments
│       │   ├── Labels
│       │   └── Estimate, Priority, Assignee, Delegate
│       └── Templates
│
└── Workspace-level features
    ├── Customers + Customer Needs
    ├── Asks
    ├── Pulse
    ├── Insights / Dashboards
    ├── Agents (app users)
    └── Documents
```

Un **Project** vive dentro de una o varias Initiatives (puede compartirse entre teams). Las **issues** pertenecen a exactamente un Team, opcionalmente a un Project, opcionalmente a un Milestone, opcionalmente a un Cycle.

## Workspace

La cuenta de la organización. Contiene todo lo demás. Es la **unidad de facturación** y de identidad.

**Propiedades clave**:

- `id` (UUID), `name` ("Talent Engine"), `urlKey` ("talent-engine")
- `gitBranchFormat` — patrón de branch names que Linear genera
- Configuración de Initiatives, Customers, Pulse, agentes, Asks, etc. (todas son workspace-level)

**Decisiones operativas**:

- Solo Talent Network usa **un** workspace. NO crear workspaces separados por vertical.
- Los miembros se invitan al workspace; luego se añaden a teams individuales.

## Team

Grupo que trabaja junto frecuentemente. Cada team tiene su propio ritmo (cycles, triage, backlog).

**Propiedades clave**:

- `id`, `name` ("Talent Engine"), `key` ("TAL") — el prefix de los issues (TAL-1, TAL-2…)
- `cyclesEnabled`, `cycleDuration`, `cycleStartDay`, `cycleCooldownTime`
- `triageEnabled` — si el team tiene bandeja Triage activa
- `defaultIssueState`, `defaultIssueEstimate`
- `timezone` — relevante para cycles
- `visibility` (`TeamVisibility` = `public | restricted | private`) — reemplaza al campo `private`
  (`Boolean`, **deprecado** "Use `Team.visibility` instead", NO eliminado del schema — verificado por
  introspección con `includeDeprecated:true`, re-verificado vivo `last_verified: 2026-09-05`). No usar
  `private` en queries nuevas.
- Configuración por team: workflow states, templates, agents asignables, agent guidance

**Configuración actual del team TAL** (medido 2026-09-05, `team.json` vivo):

- `cyclesEnabled: false` — cycles DESACTIVADOS en TAL. La descripción genérica de Cycle (más abajo) es
  de uso libre para otros teams/instalaciones de este skill; no la usa la fábrica hoy.
- `issueEstimationType: notUsed` — TAL no usa estimates nativos de Linear. `estimate` 1-5 se rellena
  igualmente por API como convención propia de la casa (regla del repo: tope 5 por issue, bundles ≤5;
  no es la escala Fibonacci nativa de Linear, que este team tiene desactivada).

**Cuándo crear otro team**:

- Solo si un grupo nuevo necesita SU PROPIO backlog y SU PROPIO ritmo de cycles
- 2-3 humanos no necesitan más teams. Mantenerlo así.

## Initiative

Concepto **workspace-level** introducido en julio 2024. Agrupa Projects bajo un objetivo estratégico. **Atraviesan teams** y duran meses/años. Visible para todos los miembros por defecto, **pero desde el
changelog "Team initiatives" (2026-08-13, <https://linear.app/changelog/2026-08-13-team-initiatives>) una
Initiative puede tener un `leadTeam` asignado, y una initiative liderada por un team privado queda
restringida a los miembros de ese team** — corrige la afirmación anterior de "no soporta privacidad por
team".

**Propiedades clave**:

- `id`, `name`, `description` (Markdown)
- `owner` (User) — único responsable, no múltiples
- `status` (`InitiativeStatus`) — enum **`Proposed | Planned | Active | Completed | Canceled`** (ampliado
  2026-07-02: se añadieron `Proposed` y `Canceled` a los tres originales `Planned/Active/Completed`).
  Verificado por introspección viva, `last_verified: 2026-07-20`. **Se setea vía `status:` (el enum), NO
  existe `statusId`** — a diferencia de un Workflow State de team, el status de Initiative es un enum fijo
  del schema (confirmado en `InitiativeCreateInput`/`InitiativeUpdateInput`).
- `priority` (`Int`) — campo nuevo (2026-07-02), presente en `InitiativeCreateInput`/`InitiativeUpdateInput`.
- `labels` (`InitiativeLabelConnection`) / `labelIds` — labels a nivel de initiative, campo nuevo (2026-07-02).
- `visibility` (`InitiativeVisibility` = `public | restricted | private`).
- `leadTeam` — team líder de la initiative (campo nuevo, 2026-08-13). Si el `leadTeam` es privado, la
  initiative queda restringida a sus miembros (ver nota de privacidad arriba).
- `targetDate` — puede ser day/month/quarter/half/year
- `health` — calculado de los project updates
- `subInitiatives` — sí, soportadas (parent/child)

**Las 10 initiatives activas** (medido 2026-09-05, `initiatives(first:N)` — `organization { initiatives }`
NO existe como query, se consulta desde la raíz):

| Nombre | Capa | Target |
|---|---|---|
| Talent Engine | meta (orquestación/coordinación de la fábrica, id `e445b88c-292b-4a7f-a4bd-0866b635e075`) | — |
| Talent Portafolio | producto | — |
| Genius Arena | producto | — |
| Talent Sales Suite 2026 | producto | 2026 |
| Event Engine 2026 | producto | 2026 |
| Academia Ejemplo 2026 | producto (id `cfcbfe90-efd4-4faa-a702-d2532d64d9db`) | 2026 |
| Talent Land | producto | — |
| Bootcamp Cripto 2026 | producto | 2026 |
| Talent Land Online 2026 | producto | 2026 |
| Talent Media 2026 | producto | 2026 |

**Regla del repo Academia Ejemplo 2026 (`academia-ejemplo-2-0`)**: todo issue de PRODUCTO va exclusivamente en
la initiative `Academia Ejemplo 2026`, en un project que pertenezca a ella. La capa META de
orquestación/coordinación de la fábrica (proyecto "Coordinación Multi Canal", órdenes de trabajo del
Orquestador, registro de flota) es la única excepción y vive en `Talent Engine`. Esta regla es específica
de ese repo; otras instalaciones de este skill pueden no tener esta separación producto/meta.

Cuando una issue pertenece a un Project, hereda implícitamente la Initiative del project. **No marques la initiative directamente en el issue** — déjala derivar del project.

## Project

Esfuerzo entregable acotado en el tiempo. Tiene fecha de entrega y un único `lead`.

**Propiedades clave**:

- `id`, `name`, `description`, `summary` (campo TL;DR), `icon`, `color`
- `identifier` — id corto con shape `P-<team>-<n>` (campo vivo, `last_verified: 2026-09-05`), distinto del
  `id` (UUID)
- `state` — `backlog`, `planned`, `started`, `paused`, `completed`, `canceled`
- `lead` (User) — único
- `members` — colaboradores, opt-in para notificaciones
- `startDate`, `targetDate` — pueden ser día concreto, mes, quarter, half o year
- `priority`, `health` (`onTrack`, `atRisk`, `offTrack`), `progress` (0-1)
- `teams` — uno o varios (raro tener varios)
- `initiatives` — uno o varios
- `milestones`, `documents`, `projectUpdates`
- `gitBranchFormat`

**Cuándo es Project (vs no serlo)**:

- ✅ Tiene fecha de entrega y se acaba
- ✅ Tiene un único entregable identificable
- ✅ Tiene lead único
- ❌ Trabajo continuo sin fin → no es project, es backlog del team
- ❌ Sin fecha clara → no es project todavía, todavía es idea

**Naming**: imperativo + objeto + versión, sin año:

- ✓ "Lanzar Dashboard de Métricas v1"
- ✓ "Migrar autenticación a OAuth"
- ✓ "Refactor del módulo de pagos"
- ✗ "Dashboard 2026" (el año va en la initiative)

## Milestone

Fase intermedia dentro de un Project. NO es un mini-project — es un checkpoint.

**Propiedades clave**:

- `id`, `name`, `description`, `targetDate`
- `project` (parent), `sortOrder`
- `progress` (0-1), `state`

**Patrón típico** (3-5 milestones por project, no más):

```text
Project: "Lanzar Dashboard de Métricas v1"
├── M1: Diseño y wireframes aprobados
├── M2: Backend con datos reales
├── M3: Frontend funcional
├── M4: Beta cerrada con feedback
└── M5: Lanzamiento público
```

Cada Issue del project se asigna a 0 o 1 milestone. Los milestones dan la **barra de progreso por fase**.

## Cycle

> **Estado en TAL (medido 2026-09-05)**: `cyclesEnabled: false` — el team TAL tiene los cycles
> DESACTIVADOS; la fábrica despacha trabajo por batches/encargos (`talent-orchestrator`), no por cycles.
> La descripción que sigue es la doctrina genérica de Linear, de uso libre para cualquier team/instalación
> de este skill que sí active cycles — no la usa la fábrica hoy.

Periodo de tiempo (1 semana es un valor típico, configurable por team). Cuando un team los activa, Linear los crea automáticamente y los issues no completados se mueven al siguiente cycle.

**Propiedades clave**:

- `id`, `number` (1, 2, 3…), `name` (opcional)
- `team` (parent)
- `startsAt`, `endsAt` — fechas inmutables una vez en el pasado
- `progress`, `completedAt`, `autoArchivedAt`
- `issues` (las del cycle), `uncompletedIssuesUponClose`

**Ciclo de vida**:

1. Linear crea el cycle automáticamente (auto-create 2 ahead)
2. El equipo lo planifica el lunes (mover issues del backlog al cycle)
3. Trabajo durante la semana; los started issues se auto-añaden si no estaban
4. El viernes/domingo se cierra; los incompletos rebotan al siguiente
5. Linear archiva el cycle cerrado

**Reglas**:

- Las fechas pasadas no se pueden cambiar
- Un cycle activo puede cerrarse anticipadamente
- El día de inicio se elige una vez por team, no por cycle individual

## Release

Entidad de **tracking de despliegue CI/CD** (lanzada 30-abr-2026, extendida con "release pipeline
changelogs" 18-jun-2026). Confirmada por introspección viva del schema real, `last_verified: 2026-07-20`.

**Propiedades clave** (verificadas por introspección; nombres exactos del schema):

- `id`, `name` (String!), `description`, `version`, `commitSha` — identifica el despliegue
- `pipeline` (`ReleasePipeline!`) — a qué pipeline CI/CD pertenece
- `stage` (`ReleaseStage!`) — el eje de progreso del release (ver más abajo, **NO existe un enum
  `ReleaseStatus`**)
- `releaseNote`, `releaseNotes` — notas de release (generables por Linear Agent)
- `startDate`, `targetDate`, `startedAt`, `completedAt`, `canceledAt`, `autoArchivedAt`
- `issues`, `issueCount` — issues vinculadas al release
- `creator`, `url`, `documents`, `links`, `progressHistory`, `currentProgress`, `history`

**Estado — vía `stage`, no `ReleaseStatus`**: el campo de estado es `stage (ReleaseStage!)`, cuyo tipo
`.type` es el enum **`ReleaseStageType` = `planned | started | completed | canceled`** (minúsculas). Una
búsqueda de `__type(name: "ReleaseStatus")` en el schema real devuelve `null` — ese nombre de enum **no
existe**; no inventarlo en ejemplos.

**Mutations reales** (verificadas por introspección de `mutationType.fields`, nombres exactos):
`releaseCreate`, `releaseUpdate`, `releaseComplete`, `releaseDelete`, `releaseArchive`, `releaseUnarchive`,
`releaseSync`, `releaseUpdateByPipeline` (+ variantes `releaseSyncByAccessKey` /
`releaseCompleteByAccessKey` / `releaseUpdateByPipelineByAccessKey` para integraciones CI/CD sin sesión de
usuario). Familias relacionadas: `releasePipeline{Create,Update,Archive,Unarchive,Delete}`,
`releaseStage{Create,Update,Archive,Unarchive}`, `releaseNote{Create,Update,Delete}`,
`issueToRelease{Create,Delete,DeleteByIssueAndRelease}`.

`ReleaseCreateInput` **requiere** `name: String!` y `pipelineId: String!`; opcionales: `description`,
`version`, `commitSha`, `stageId`, `startDate`, `targetDate` (verificado por introspección de
`ReleaseCreateInput.inputFields`). Cualquier ejemplo de `releaseCreate` DEBE incluir `pipelineId`.

Ver ejemplos GraphQL ejecutables en `references/03-graphql-cheatsheet.md`.

## Issue

**Entidad central** de Linear. Todo gira en torno a issues.

**Propiedades obligatorias al crear**:

- `title` (string)
- `teamId` — el team al que pertenece

**Propiedades opcionales pero importantes**:

- `description` — Markdown, puede ser largo
- `assigneeId` — humano responsable principal (NO un agente)
- `delegateId` — agente delegado (entró en Linear for Agents 2025)
- `stateId` — workflow state actual
- `projectId`, `cycleId`, `projectMilestoneId` — vinculación
- `parentId` — para sub-issues
- `labelIds` — array de UUIDs de labels (workspace o team)
- `priority` — entero: 0 None, 1 Urgent, 2 High, 3 Normal/Medium, 4 Low
- `estimate` — número entero; en TAL es una CONVENCIÓN de la casa (1, 2, 3, 5; tope 5) porque el team tiene la estimación nativa en `notUsed` (verificado 2026-09-05)
- `dueDate` — ISO date
- `templateId` — si se crea desde un template

**Propiedades derivadas / read-only**:

- `id` (UUID), `identifier` ("TAL-123") — Linear te permite usar el identifier en lugar del UUID en muchas mutations
- `branchName` — generado automáticamente; usable para crear branches
- `url` — link directo a la issue
- `createdAt`, `updatedAt`, `completedAt`, `canceledAt`, `archivedAt`
- `customerTicketCount` (`Int!`) — cuántos tickets de soporte/customer están vinculados (campo vivo,
  `last_verified: 2026-09-05`)
- `activitySummary` (`JSONObject`) — resumen agregado de actividad de la issue (campo vivo,
  `last_verified: 2026-09-05`)
- `stateHistory` — historial de transiciones de `WorkflowState` de la issue. La fábrica lo usa para
  verificar que el flujo real fue `In Progress → In Review → Done` (no solo que el estado final es
  `Done`) — ver `talent-coordination/references/05-verificacion-independiente.md`. Útil en cualquier
  auditoría/verificación independiente de cierre, no solo dentro de la fábrica.

**Importante**:

- Las modificaciones en los **primeros 3 minutos** se consideran parte de la creación y NO aparecen en activity feed.
- Para añadir/quitar labels existen `issueAddLabel(id, labelId)` / `issueRemoveLabel(id, labelId)` (verificado
  vivo en el schema, `last_verified: 2026-09-05`) y, de forma nativa dentro de `issueUpdate`, los campos
  `addedLabelIds: [String!]` / `removedLabelIds: [String!]` de `IssueUpdateInput` — ambos evitan el patrón
  read-then-write-completo. `labelIds` sigue existiendo en `IssueUpdateInput` y, cuando se envía, **reemplaza
  el array completo** (sigue siendo válido para un set-completo intencional; para un add/remove puntual,
  preferir `addedLabelIds`/`removedLabelIds` — menos superficie de condición de carrera).

**Priority — convención de uso en TAL**:

- `Urgent` (1) — bloqueando producción, hay revenue/usuarios afectados
- `High` (2) — del cycle actual, debe entregarse esta semana
- `Normal/Medium` (3) — del backlog priorizado, próximo cycle
- `Low` (4) — nice-to-have, sin compromiso de fecha
- `None` (0) — sin priorizar todavía

## Sub-issues e issue relations

**Sub-issues** (parent/child):

- Una issue puede tener un `parent` y/o varias `children`
- Cada sub-issue es **independiente**: tiene su propio state, assignee, estimate, cycle
- Casos de uso: descomponer una feature grande, dividir trabajo entre humano e IA, fasear un bug fix complejo

**Issue relations** (no jerárquico). El enum real de `IssueRelationCreateInput.type` (`IssueRelationType`,
verificado vivo, `last_verified: 2026-09-05`) tiene **4 valores en minúsculas**: `blocks | duplicate |
related | similar`. Los nombres `blockedBy` / `relatedTo` / `duplicateOf` que siguen abajo son **alias
conceptuales de lectura** (cómo se lee la relación desde el lado inverso), no valores del enum — no los
envíes como `type:` en una mutation:

- `blocks` (leído desde el otro lado: `blockedBy`) — A bloquea a B
- `related` (leído: `relatedTo`) — relacionado, sin dirección
- `duplicate` (leído: `duplicateOf`) — A es duplicado de B (cierra A, mantiene B)
- `similar` — parecido pero no bloqueante ni duplicado; no se documentaba en versiones previas de este skill

**Regla operativa**: Si una issue tiene estimate >5, divídela en sub-issues. Si tiene >3 sub-issues complejas, conviértela en Project.

## Workflow State

Estado en el flujo de trabajo. **Cada team define los suyos**. `WorkflowState.type` es un campo
`String!` — **NO existe ningún enum GraphQL nombrado para este campo** en el schema real (una
introspección `__type(name: ...)` sobre el nombre que usa internamente `scripts/linear-client.ts` como
vista local devuelve `null`; ese nombre no es un tipo del schema). Su *description* en el SDL documenta
**7 literales fijos**: `triage, backlog, unstarted, started, completed, canceled, duplicate` (verificado
vivo, `last_verified: 2026-09-05`) — `duplicate` es su propio type, no una sub-variante de `canceled`.

| Type | Significado | Ejemplo en TAL (medido 2026-09-05) |
|---|---|---|
| `triage` | bandeja de entrada, sin clasificar | **TAL no tiene hoy ningún estado de este type** |
| `backlog` | clasificada, sin priorizar | "Backlog" |
| `unstarted` | priorizada, lista para arrancar | "Todo", "Blocked" (la fábrica reutiliza "Blocked" como "Needs Input" de las órdenes de trabajo) |
| `started` | en progreso | "In Progress", "In Review", "Awaiting push approval" |
| `completed` | terminada | "Done" |
| `canceled` | abandonada | "Canceled" |
| `duplicate` | marcada como duplicado de otra issue | "Duplicate" — **NO** es `type: canceled` |

**Estados vivos del team TAL** (9, `team.json`, medido 2026-09-05): Backlog(`backlog`), Todo(`unstarted`),
Blocked(`unstarted`), In Progress(`started`), In Review(`started`), Awaiting push
approval(`started`), Done(`completed`), Canceled(`canceled`), Duplicate(`duplicate`).

**Propiedades**:

- `id`, `name`, `type` (uno de los 7 literales), `color`, `position`
- `team` (parent)

**Reglas**:

- Un team puede tener múltiples states del mismo type (ej: "In Progress" e "In Review" ambos type=`started`)
- Triage es opcional; TAL no lo tiene activo hoy
- Auto-archivo: states `completed` y `canceled` archivan automáticamente tras N días configurable
- **Filtros de estados "terminales"**: deben incluir `duplicate` explícitamente además de `completed`/
  `canceled` — un filtro `state: { type: { in: ["completed", "canceled"] } }` se deja fuera las issues
  marcadas `Duplicate`.

## Label

Etiqueta para filtrar y organizar. Pueden ser de **workspace** (compartidas por todos los teams) o de **team** (solo ese team las ve).

**Propiedades**:

- `id`, `name`, `color`, `description`
- `team` (null si es workspace label)
- `parent` — soporta jerarquía (label groups)

**Scope fijo al crear**: el scope de un label (workspace o team) se decide en `issueLabelCreate` y **no
cambia después** — un label de team no se convierte en workspace ni viceversa. Los nombres son únicos
**dentro de su scope** (dos teams distintos pueden tener cada uno un label `kind:test` propio; un label de
workspace `kind:feat` es único en toda la organización). Ejemplo vivo: `kind:test` existe **POR TEAM**
(uno en TAL, otro en BUG) a diferencia del resto de la familia `kind:*`, que es de workspace (medido
2026-09-05).

**Taxonomía viva del workspace** (verificada contra la API — autoridad interna
`examples/label-taxonomy.json`, recibo `examples/label-taxonomy.receipt.json`, gate
`scripts/check-taxonomy-parity.sh`; last_verified: 2026-07-24):

```text
vertical/  (agrupa por producto; OBLIGATORIO en toda issue)
├── vertical/academy        (workspace)
├── vertical/bootcamp       (workspace)
├── vertical/fabrica        (por team — duplicado TAL/BUG, ver duplicates de la autoridad)
├── vertical/genius-arena   (workspace)
├── vertical/land-es        (por team — duplicado TAL/BUG)
├── vertical/land-mx        (workspace)
├── vertical/land-online    (workspace)
└── vertical/media          (workspace)

kind:      (workspace; tipo de trabajo)
├── kind:feat
├── kind:fix
├── kind:refactor
├── kind:docs
├── kind:chore
├── kind:hotfix
├── kind:adr
└── kind:decision-pending

actor      — clave para distinguir trabajo de agente vs humano
├── actor/human             (workspace)
├── actor/ai                (workspace)
└── actor:needs-review      (por team TAL/BUG, namespace de dos puntos — unificación
                             con la familia actor/* pendiente, decisión del workspace)

sev:       (workspace; severidad del defecto/incidente — opcional)
├── sev:bloqueante
├── sev:capital
├── sev:degradado
└── sev:cosmetico

(legacy del onboarding de Linear — existen; su limpieza es decisión del workspace):
├── Bug
├── Feature
└── Improvement
```

Existen además grupos de otros teams/procesos fuera del contrato de este skill
(familias con namespace de dos puntos y otras del team de evento): consultarlos en el
recibo antes de referenciarlos — un label que no aparece en el recibo NO se usa.

**Reglas**:

- Toda issue debe tener al menos un `vertical/*`
- Una issue tocada por un agente debe tener `actor/ai`
- No duplicar `priority` con labels (Linear ya tiene priority como campo)

## Comment

Mensaje en una issue. Soporta threads, menciones, reacciones, sync con Slack/GitHub.

**Propiedades**:

- `id`, `body` (Markdown), `user` (autor), `issue` (parent)
- `parent` — si es respuesta en un thread
- `editedAt`, `reactions`
- `botActor` — si el comment lo creó una integración
- `documentContent` / `documentContentId` — vínculo del comment a un `Document` (campos vivos de
  `Comment`/`CommentCreateInput`, `last_verified: 2026-09-05`)

**Buenas prácticas**:

- Si un comment describe trabajo a hacer, conviértelo en sub-issue.
- Para conversaciones largas, usa threads (`parent`) en vez de comments planos.

**Menciones — comportamiento verificado 2026-09-05 con un `commentCreate` de prueba en TAL-5432** (leyendo
`bodyData`, el JSON ProseMirror devuelto por la API):

- La **URL plana** de una issue (`https://linear.app/<workspace>/issue/TAL-5428`) se convierte en un nodo
  `issueMention` — mención enlazada.
- Un **enlace Markdown** `[TAL-5428](url)` **también** se convierte en `issueMention` (contradice a
  cualquier fuente externa que afirme que solo la URL plana genera mención).
- El texto plano `@Nombre Apellido` (ej. `@Raul Martin`) **sí** se resuelve a un nodo
  `suggestion_userMentions` con el UUID del usuario cuando el nombre coincide exactamente con un miembro
  del workspace — genera notificación de mención de persona.
- Un identificador suelto sin URL ni `@` (ej. `TAL-5428` a secas) **se queda como texto plano** — NO crea
  mención ni notificación.
- **Regla operativa**: para mencionar una issue, usa su URL (plana o dentro de un enlace Markdown); para
  mencionar a una persona, `@Nombre Apellido` exacto tal como aparece en el workspace; un identificador
  `ABC-123` suelto no basta.

## Attachment

Adjunto en una issue. Puede ser archivo (subido a GCS de Linear) o URL externa (PR de GitHub, ticket de Zendesk, doc).

**Propiedades**:

- `id`, `title`, `subtitle`, `url`, `metadata` (JSON con info del source)
- `source` — string identificando origen ("github", "figma", custom...)
- `issue` (parent)

**Patrones**:

- PRs de GitHub se adjuntan automáticamente cuando el commit/PR menciona el issue
- Para subir archivos se usa `attachmentLinkURL` o flow de signed URL

**Adjunto lateral vs. imagen inline — dos flujos distintos, no intercambiables**:

- **Lateral (sidebar)**: `fileUpload` (pide un signed URL a GCS) → PUT del archivo → `attachmentCreate`
  con `issueId`/`title`/`url` (ver `scripts/upload-attachment.ts`). El resultado aparece en la barra
  lateral "Attachments" de la issue, **NO se ve embebido en el cuerpo del comment/descripción**.
- **Inline**: mismo `fileUpload` para obtener el `assetUrl`, pero en vez de `attachmentCreate` se
  **embebe `![nombre](assetUrl)` directamente en el Markdown de un comment o de la descripción** —
  ahí sí se renderiza inline como imagen dentro del texto.
- **Gotcha — un agente no "ve" capturas sin fetch explícito**: al triar o dedupear una issue, pedir
  siempre `attachments { nodes { url title } }` en la query. El cuerpo (`body`/`description`) puede no
  contener ningún indicio textual de que existan mockups/capturas adjuntas en el sidebar — si no se pide
  el campo `attachments`, el agente puede perder contexto crítico sin darse cuenta.

## Document

Doc Markdown enriquecido vinculado a un Project, Initiative o Issue.

**Propiedades**:

- `id`, `title`, `content` (Markdown), `icon`
- `project` o `initiative` (uno de los dos como parent)
- Soporta secciones colapsables `+++ Title ... +++`

**Cuándo usarlo**:

- Specs de un project
- Notas de retrospectiva
- Decision records
- Documentación operativa que evoluciona

## Customer y Customer Need

**Customer Requests** lanzados en diciembre 2024. Permiten ligar feedback de usuarios reales a issues/projects.

**Customer**:

- `id`, `name`, `domain`, `tier`, `revenue`, `size`
- Sincronizable desde Salesforce, HubSpot, Intercom

**Customer Need** (también llamado Customer Request):

- `id`, `body`, `customer`, `attachment` (la fuente — Slack thread, Intercom, email...)
- `issue` o `project` — a qué se vincula
- `priority` (escala propia: 0 = sin prioridad, 1 = importante; NO la escala 1-4 de issues)
- Agrupación: por el `customer` común (no existe un `bundleId` en `CustomerNeedCreateInput`)

**Uso en Talent Engine**: si un equipo de operación de Talent Network nos pide algo (ej: "necesitamos endpoint para reportes"), se crea un Customer Need vinculado al issue de desarrollo. Esto preserva trazabilidad sin meter operación en Linear.

## User vs App User (agente)

**User**: persona humana. `id`, `name`, `displayName`, `email`, `avatarUrl`.

**App User** (agente IA, lanzado mayo 2025 en "Linear for Agents"):

- Es un user con `isApp: true`
- Tiene perfil completo, claramente identificado como app
- Se @-menciona, se asigna, comenta como cualquier user
- **No es seat facturable** — instalado y gestionado por admins
- Visible en menús de assignment si la app tiene scope `app:assignable`
- Visible en menciones si tiene scope `app:mentionable`

**Cuando una issue se asigna a un agente**:

- El humano sigue siendo `assignee` primario (responsabilidad)
- El agente se pone como `delegate` (contributor)
- Hay un campo distinto **Delegate** que permite filtrar e Insights por agente

## Agent Session y Agent Activity

Sistema introducido con Linear for Agents para que los agentes IA reporten progreso de manera estructurada.

**AgentSession**:

- Unidad de trabajo entre agente y workspace
- 6 estados: `pending`, `active`, `error`, `awaitingInput`, `complete`, `stale`
- Linear los gestiona automáticamente según la última `AgentActivity` emitida
- Se asocia a una issue + un agente

**AgentActivity** (tipos — `AgentActivityType`, 6 miembros verificados por introspección viva,
`last_verified: 2026-07-20`):

- `thought` — razonamiento interno visible
- `action` — acción ejecutada (con resultado)
- `elicitation` — pidiendo input al humano
- `prompt` — entrada original
- `response` — respuesta del agente
- `error` — el agente reportó un error

**Restricción crítica**: el agente debe responder con `agentActivityCreate` o `agentSessionUpdate` en
**<10 segundos** (los docs de Linear piden emitir un `thought` en ese plazo para acusar recibo). No hay
confirmación de un estado `unresponsive` — ese nombre **no existe** en `AgentSessionStatus` (verificado
por introspección viva, `last_verified: 2026-07-20`; ver los 6 estados reales arriba). El estado real más
cercano si la sesión queda sin actividad es `stale`; no inventar `unresponsive` en ejemplos.

Detalles completos en `references/06-agents-sdk.md`.

## AgentSkill

Entidad para instrucciones de agente reutilizables ("system prompt" guardado). Sustituye a `AiPrompt`
(**retirado del schema**, no solo deprecado — `__type(name: "AiPrompt")` devuelve `null` en introspección
viva; los tipos GraphQL no se ocultan por deprecación, así que esto es retiro real, 21-may-2026). Modelo de
campos corregido tras auditoría de código (el primer intento infería semántica incorrecta de `teamId`/
`shared`/`inheritedFrom` sin leer sus descriptions de schema) — confirmado por introspección incluyendo
`description` de cada campo, `last_verified: 2026-07-20`.

**Propiedades clave** (verificadas por introspección de `AgentSkill.fields`, con la `description` exacta
del schema entre comillas donde aplica):

- `id`, `title`, `body` (el contenido de la instrucción, markdown), `description` (auto-generada, puede ser
  `null`), `icon`, `color`, `slugId`
- `owner`, `creator`, `lastUpdatedBy`
- `teamId` (nullable, `String`) — **"The identifier of the team this skill is shared with"**. NO significa
  "null = skill de workspace"; identifica CON QUÉ team está compartida la skill cuando aplica.
- `shared` (`Boolean!`) — **"Whether the skill is shared with everyone in the workspace. When false, only
  the owner can use the skill."** Es un eje **personal vs. todo-el-workspace** (no significa "compartida
  entre teams"). Su **relación exacta con `teamId` no está confirmada** — que ambos campos existan por
  separado no demuestra que sean independientes; no asumir ortogonalidad sin evidencia. **`shared` NO
  aparece en `AgentSkillCreateInput` ni
  `AgentSkillUpdateInput`** (verificado por introspección) — es un campo derivado/read-only desde estas dos
  mutations; no hay mutation dedicada de "compartir" en el schema (`agentSkillCreate`, `agentSkillUpdate`,
  `agentSkillDelete` son las únicas `agentSkill*`). El mecanismo exacto que produce `shared: true` no está
  confirmado — no inventar uno.
- `inheritedFrom` (`AgentSkill`, nullable) — **"The parent-team skill this skill was inherited from. Null if
  the skill is not inherited."** La herencia es **específicamente parent-team → sub-team** (Team tiene
  `parent`/`children`, ver sección Team), NO herencia arbitraria entre teams cualesquiera.
- `lastUsedAt`, `recentUsageCount`

`AgentSkillCreateInput` acepta: `id`, `teamId`, `title`, `body` (requerido), `icon`, `color`.
`AgentSkillUpdateInput` acepta los mismos salvo `id`. Ninguno de los dos acepta `shared` ni `inheritedFrom`.

Relacionado con Linear Agent — ver "Agent Skills — workspace-wide vs. herencia parent-team → sub-team" en
`references/06-agents-sdk.md`. Tools de solo-lectura `list_agent_skills` / `get_agent_skill` existen desde
julio 2026 (nota informativa; este repo es token-only, NO MCP — ver `references/02-mcp-tools.md`).

## Otras entidades relevantes

- **IssueLabel** — relación many-to-many entre Issue y Label
- **IssueRelation** — relación many-to-many entre Issues; enum real `blocks | duplicate | related | similar`
  (ver [Sub-issues e issue relations](#sub-issues-e-issue-relations))
- **ReleasePipeline** — pipeline CI/CD al que pertenecen los Release (ver [Release](#release))
- **ReleaseStage** — etapa de un Release; su `.type` es el enum `ReleaseStageType`
  (`planned/started/completed/canceled`)
- **AgentSkill** — instrucciones de agente reutilizables, sustituye a `AiPrompt` (ver [AgentSkill](#agentskill))
- **Reaction** — emoji reaction a comments o issues
- **ProjectUpdate** — status update semanal (text + health)
- **InitiativeUpdate** — equivalente a project update, a nivel initiative
- **IssueSLA** — para tracking de tiempos de respuesta
- **Reminder** — recordatorios programados sobre issues
- **Favorite** — items favoriteados por un user
- **View** (custom view) — filtros guardados, list/board/timeline
- **Template** — plantillas de issue/project con valores por defecto
- **Webhook** — config de webhooks salientes
- **OAuthApp** — apps OAuth instaladas en el workspace
- **AuditEntry** — entrada de log de auditoría (Enterprise)
- **PermissionChange** — cambio de permisos

Para detalles GraphQL de cualquiera de estas entidades, ver `references/03-graphql-cheatsheet.md` o el schema vivo en <https://studio.apollographql.com/public/Linear-API/variant/current/schema/reference>
