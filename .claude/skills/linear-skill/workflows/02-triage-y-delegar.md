# Workflow — Triage y delegación a agentes IA

Este es el flujo más crítico del skill. Cuando llegan issues nuevas (de cualquier fuente: el equipo de Media, ideas internas, bugs reportados, customer feedback), tienen que pasar por triage humano antes de cualquier acción. Y cuando se delega a un agente IA, hay que hacerlo con un patrón muy específico para mantener trazabilidad.

## Cuándo usar este workflow

- Cuando el humano dice "vamos a hacer triage del backlog"
- Cuando el humano pega contenido (Slack thread, email, mensaje de Notion) y dice "convierte esto en issues"
- Cuando hay issues en estado `Triage` esperando clasificación
- Cuando el humano dice "delega esto a Claude" / "que lo haga Cursor" / "que lo haga el agente"

## Parte 1 — Triage humano

### Paso 1.1 — Recoger inputs en Triage

Listar todo lo que está en estado Triage:

```text
query($after: String) { issues(filter: { team: { key: { eq: "TAL" } }, state: { type: { eq: "triage" } } }, first: 50, after: $after) { pageInfo { hasNextPage endCursor } nodes { identifier title } } }
# paginar con after hasta hasNextPage=false, acumulando nodes
```

O si el humano va a triagear contenido que aún no está en Linear:

```text
1. Pídele que pegue el contenido (Slack thread, email, lo que sea)
2. Para cada item de trabajo identificable, ejecutar paso 1.2 en bucle
```

### Paso 1.2 — Para cada issue, decidir 6 cosas

Para cada issue a triagear, completa estos 6 campos antes de salir de Triage:

1. **¿Es real?** O cancelar (state = `canceled` o `Duplicate`)
2. **¿Existe ya?** Buscar duplicados con la query paginada de `buscar-y-deduplicar.md` §A — incluye `team: { key: { eq: "TAL" } }` + `pageInfo`/`after` recorriendo TODAS las páginas. Solo tras revisarlas, marcar `duplicateOf` la existente y cancelar la nueva.
3. **¿A qué initiative pertenece?** Asignar label `vertical/<X>` correspondiente.
4. **¿Tipo de trabajo?** Label `kind:feat` | `kind:fix` | `kind:chore` | `kind:refactor` | `kind:docs` | `kind:hotfix` | `kind:adr` | `kind:decision-pending`.
5. **¿Prioridad?** `Urgent` (1) | `High` (2) | `Normal` (3) | `Low` (4).
6. **¿Estimate?** Convención de la casa 1, 2, 3, 5 (el team TAL no usa estimación nativa: `issueEstimationType=notUsed`). Si >5, romper en sub-issues.

### Paso 1.3 — Mover al estado correcto

Después de triagear, la issue va a uno de estos estados:

- `Backlog` — clasificada pero sin compromiso de cycle. Es donde vive el 80% del trabajo.
- `Todo` — priorizada, comprometida para un cycle (este o siguiente).
- `In Progress` — alguien ya está trabajando.

NUNCA dejar issues en `Triage` después de la sesión de triage. Si no se puede decidir, cancelar y reabrir cuando haya más info.

### Paso 1.4 — Decidir: ¿humano o IA?

Esta es la decisión clave del triage moderno. Para cada issue priorizada, pregúntate:

```text
✓ Sí delegable a IA (label actor/ai):
  - Scope < 1 día de trabajo
  - Tiene tests existentes en el repo
  - No toca infra crítica (DB migrations, auth, payments)
  - No hay ambigüedad de producto/UX
  - El "qué hacer" está claramente definido en la description
  - Es repetitivo (refactors mecánicos, type updates, doc updates)
  - Bug bien aislado con repro claro

✗ No delegable a IA (label actor/human):
  - Decisión arquitectónica
  - Decisión de UX o de producto
  - Debugging exploratorio profundo
  - Cambios de configuración de infra
  - Cualquier cosa con ambigüedad significativa
  - Trabajo que requiere conversación con stakeholders
```

## Parte 2 — Delegación a agente IA

Cuando una issue se ha decidido como delegable, el patrón estricto es:

### Paso 2.1 — Validar prerequisites

- [ ] La issue tiene description con criterios de aceptación claros
- [ ] La issue tiene `vertical/*` y `kind:*` labels
- [ ] Estimate está puesto y es ≤ 5
- [ ] Si el agente es de coding, sabes a qué repo aplica
- [ ] Si la issue requiere acceso a credenciales/secrets, hay un mecanismo seguro

Si falta cualquiera, **rellenar antes de delegar**. Un agente con contexto incompleto produce ruido.

### Paso 2.2 — Asignar al agente

Mantener al humano como `assignee` (responsable). El agente entra como `delegate`:

```graphql
mutation Delegar { issueUpdate(id: "<uuid de TAL-X>", input: {
  assigneeId: "<uuid del humano que revisa>",   # NO el agente (assignee = responsable humano)
  stateId:    "<uuid de In Progress>",
  labelIds:   ["<...labelIds actuales>", "<uuid de actor/ai>"]
}) { success } }
# El agente entra como DELEGATE vía la mutation de delegación del Agents SDK (ver 06-agents-sdk.md),
# no como assignee.
```

### Paso 2.3 — Documentar el plan inicial

Comentario que orienta al agente:

```text
# mutation commentCreate(input: { issueId: "<uuid de TAL-X>", body: <el texto de abajo> }) { success }
body:
`Delegada a @<agente>.

## Contexto adicional
[Lo que el agente necesita saber pero no está en la description]

## Plan inicial sugerido
1. [Primer paso concreto]
2. [Segundo]
3. [...]

## Branch
Usa: \`<prefijo>/tal-x-{slug}\` (prefijo válido del flujo: feat/, fix/, refactor/, docs/, chore/ o hotfix/, según el tipo de trabajo)

## Definición de hecho
- [ ] Tests existentes pasan
- [ ] PR abierto vinculado a esta issue
- [ ] Descripción de PR con resumen de cambios

## Reviewer
@<humano que revisa>`
```

### Paso 2.4 — El agente ejecuta

Si el agente es Cyrus / Cursor / Codex:

- Recibe el webhook AgentSessionEvent
- Crea worktree, abre rama
- Trabaja, commitea, pushea
- Abre PR con `Closes TAL-X`
- La integración GitHub mueve la issue a "In Review" automáticamente

Si el agente es Claude Code interactivo (este skill):

- El humano (tú) pide a Claude Code "trabaja en TAL-X"
- Claude Code lee la issue, abre branch, trabaja, abre PR
- Comenta progreso en la issue

### Paso 2.5 — Review humano

Cuando la issue llega a `In Review`:

1. El humano `assignee` revisa el PR en GitHub
2. Si todo bien → aprobar y mergear → automation cierra la issue
3. Si hay cambios pequeños → comentar en PR, el agente itera
4. Si hay cambios mayores → comentar en la issue, mover a `In Progress` con `actor:needs-review` (label por team: resolver el UUID del team de la issue)

### Paso 2.6 — Auditoría post-merge

Una vez al cycle (viernes), revisar las issues con `actor/ai`:

- ¿Qué % se mergearon directamente?
- ¿Qué % requirió cambios significativos?
- ¿Hubo regresiones?

Si una issue marcada `actor/ai` tuvo problemas:

- Añadir el label `actor:needs-review` post-mortem (por team: UUID del team de la issue)
- Comentar qué falló para futuras delegations
- Considerar si ese tipo de trabajo es realmente delegable

## Parte 3 — Patrones específicos

### Patrón A — Bug delegado a agente

Bugs son los mejores candidatos a IA porque son acotados. Plantilla:

```markdown
## Repro
1. Pasos exactos
2. Resultado esperado
3. Resultado observado

## Donde mirar
- archivo.ts línea 42
- otro-archivo.ts función xyz

## Test que debería pasar
[código del test que actualmente falla]
```

### Patrón B — Refactor mecánico delegado

Refactors deterministas (rename, type updates, deprecation removals) son ideales:

```markdown
## Cambio
Reemplazar todas las llamadas a `oldFunction` por `newFunction(opts)`.

## Archivos afectados
[Lista preliminar; el agente puede expandir]
- src/api/user.ts
- src/api/team.ts
- ...

## Verificación
- [ ] Tests existentes pasan
- [ ] No queda ninguna ref a `oldFunction` (`grep -r`)
```

### Patrón C — Feature pequeña delegada

Solo si la spec es muy clara y el scope es chico:

```markdown
## Comportamiento esperado
[Descripción precisa de lo que el usuario debe ver/hacer]

## Criterios de aceptación
- [ ] Endpoint devuelve <X> cuando <Y>
- [ ] Si error, devuelve <Z>
- [ ] Test de integración cubriendo flow happy path

## Diseño / mockup
[Link a Figma si hay]
```

### Patrón D — Investigación NO delegada

Cuando una issue es para entender algo (debugging exploratorio, análisis de logs):

```text
NO delegar. El agente sin guía produce explicaciones plausibles pero falsas.
Asignar a humano. Si después se identifica el bug, ESE puede ser delegado.
```

## Parte 4 — Anti-patrones

❌ **Asignar al agente como assignee primario**: pierdes la responsabilidad humana. Siempre como delegate.

❌ **Delegar issues con criterios de aceptación vagos**: el agente inventa los criterios y no son los que esperabas.

❌ **No marcar `actor/ai`**: pierdes la capacidad de auditar trabajo de IA después.

❌ **Permitir que el agente cierre la issue directamente**: solo PR + automation de GitHub. Si el agente cierra issues, perderás el step de review.

❌ **Delegar cosas críticas para validar a IA**: NO. El primer review siempre humano para tareas en categorías nuevas.

❌ **Multi-delegate**: Linear permite un delegate; si quieres dos agentes, romper en sub-issues, una para cada agente.

❌ **No comunicar el plan inicial al agente**: el agente sin plan inventa. Comentario con plan reduce divergencia.

## Parte 5 — Checklist final del workflow

Antes de mover una issue de Triage:

```text
[ ] Assignee humano asignado
[ ] Vertical label puesto
[ ] Type label puesto
[ ] Priority puesta
[ ] Estimate puesto (≤5)
[ ] Si va a IA: actor/ai puesto
[ ] Si va a IA: delegate asignado
[ ] Si va a IA: comentario con plan inicial publicado
[ ] State = Backlog (si no esta semana) o Todo/In Progress (si esta semana)
[ ] Si esta semana: cycle = current
[ ] Si pertenece a project: projectId puesto
[ ] Si pertenece a milestone: projectMilestoneId puesto
```

Si todos los checks pasan, la issue está lista para arrancar.
