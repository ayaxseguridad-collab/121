# Prompt — Crear issue (con dedupe)

Plantilla para crear una nueva issue en Linear, asegurando dedupe previo y triage completo. Úsala cuando el humano pida "crea una issue para X" o pegue un fragmento que se debe convertir en issue.

## Flow recomendado

### Paso 1 — Buscar duplicados ANTES de crear

Query GraphQL `issues(filter:)` con `or` sobre title+description (ver `buscar-y-deduplicar.md` §A):

```graphql
query Dedupe($q: String!, $after: String) {
  issues(
    filter: { team: { key: { eq: "TAL" } }, or: [ { title: { containsIgnoreCase: $q } }, { description: { containsIgnoreCase: $q } }, { comments: { body: { containsIgnoreCase: $q } } } ] }
    first: 50, after: $after
  ) { pageInfo { hasNextPage endCursor } nodes { identifier title state { name } priority url attachments { nodes { url title } } } }
}
```

**Abortar si la respuesta trae `errors`** — no seguir con los `nodes` que hayan venido. Una consulta que falla devuelve vacio, y ese vacio se lee como «no hay duplicados»: se crea la issue igual y el dedupe no ha ocurrido nunca. Un cero por no haber mirado se lee exactamente igual que un cero bueno, y aqui el precio es una issue duplicada en el tracker.

**Leer los `attachments` de cada candidato antes de decidir**: un mockup o captura adjunta en el sidebar
de la issue similar puede ser la única señal real de que es (o no es) el mismo trabajo — el `body`/
`description` puede no mencionarlo textualmente (ver "Attachment" en `references/01-data-model.md`).

Mostrar al humano los matches:

```text
Antes de crear, encontré estas issues similares:
- TAL-87 "Implementar export PDF" (Backlog, prioridad medium)
- TAL-65 "Export del dashboard" (Done, hace 2 meses)

¿Crear nueva o relacionar con alguna existente?
```

Esperar respuesta antes de proceder.

### Paso 2 — Recoger inputs mínimos

Si faltan, pedir explícitamente. Inputs requeridos:

| Campo | Default si no se da |
|---|---|
| `title` | OBLIGATORIO — pedir |
| `description` | Estructurar con plantilla (abajo) |
| `vertical` | OBLIGATORIO — pedir si no es inferible |
| `type` | Inferir o pedir |
| `priority` | Default: 3 (Normal) — pedir confirmación |
| `estimate` | Pedir o sugerir |
| `assignee` | Default: nadie en backlog, pedir si va al cycle |
| `cycle` | Default: null (backlog), pedir si es esta semana |
| `project` | OBLIGATORIO — pedir nombre; ver Paso 10 (fail-closed si no encaja en ningún project de la initiative) |

### Paso 3 — Estructurar el title

Patrón **imperativo + qué + dónde (si aplica)**:

```text
✓ "Implementar OAuth en login (frontend)"
✓ "Corregir cálculo de descuento en checkout"
✓ "Migrar API de payments a Stripe v2"

✗ "Bug en checkout"
✗ "OAuth"
✗ "necesidad: hacer un dashboard"
```

### Paso 4 — Estructurar la description

Plantilla universal (adaptar según type):

```markdown
## Contexto
[Por qué esta issue importa. 1-2 párrafos de contexto.
Si es feature: a quién sirve. Si es bug: qué está roto.]

## Comportamiento esperado / criterios de aceptación
- [ ] Criterio 1 (verificable)
- [ ] Criterio 2 (verificable)
- [ ] ...

## Información adicional
[Links a Figma, docs, threads de Slack, etc.]

## Out of scope
[Lo que explícitamente NO entra en esta issue]
```

Para bugs, ver plantilla específica en `examples/issue-templates/bug.md`.

Para features, ver `examples/issue-templates/feature.md`.

### Paso 5 — Decidir vertical label

La lista AUTORITATIVA vive en `examples/label-taxonomy.json` (grupo `vertical`, 8 vivos —
verificados contra la API; recibo en `examples/label-taxonomy.receipt.json`). Mapping:

| Plataforma del trabajo | Label |
|---|---|
| academia.example.invalid (academy) | `vertical/academy` |
| bootcamp.cripto / similar | `vertical/bootcamp` |
| Capa meta: fábrica portátil, motor talent-factory, skills de estaciones | `vertical/fabrica` (POR TEAM — duplicado TAL/BUG: resolver el UUID del team de la issue) |
| Plataforma Genius Arena (SaaS de hackathones) | `vertical/genius-arena` |
| Talent Land España | `vertical/land-es` (POR TEAM — duplicado TAL/BUG: resolver el UUID del team de la issue) |
| talent-land.com (web evento MX) | `vertical/land-mx` |
| Plataforma "Netflix de conferencias" | `vertical/land-online` |
| Tools internos para Media (dashboards, autom.) | `vertical/media` |

Los dos duplicados por team son FAIL-CLOSED: nunca elegir un UUID al azar — si el team de la
issue no tiene ese label, parar y consultar (ver `duplicates` en la autoridad).

Si toca varios verticals (ej: refactor compartido), poner solo el principal y mencionar otros en description.

### Paso 6 — Decidir kind label

(last_verified: 2026-07-24, confirmado vía issueLabels API — no existe `kind:security`)

| Si es... | Label |
|---|---|
| Funcionalidad nueva | `kind:feat` |
| Bug en algo existente | `kind:fix` |
| Mantenimiento, deps, CI | `kind:chore` |
| Mejora interna sin cambio funcional | `kind:refactor` |
| Vulnerabilidad, hardening | `kind:fix` (o `kind:chore` si es preventivo) + label `sev:*` |
| Documentación | `kind:docs` |

### Paso 7 — Decidir priority

```text
Urgent (1) → bloqueando producción/revenue HOY
High (2) → del cycle actual, debe entregarse esta semana
Normal (3) → priorizado, próximo cycle
Low (4) → nice-to-have, sin compromiso
```

Si se decide en planning del cycle, usar al menos `Normal`.

### Paso 8 — Estimar

Escala (convención de la casa — el team TAL tiene la estimación nativa desactivada, `issueEstimationType=notUsed`):

```text
1 = trabajo trivial, < 2h          (typo, log fix, dep update)
2 = pequeño, ~medio día            (función nueva acotada, refactor pequeño)
3 = mediano, 1 día                 (feature de tamaño chico, bug normal)
5 = grande, 2-3 días               (feature significativa, refactor moderado)
```

La escala de la casa es **1, 2, 3, 5** y el maximo por issue es **5** — asi esta declarado en
`examples/talent-engine-config.json` (`scale`, `max_per_issue`), que manda. **No existe el 8.**
Un trabajo que no cabe en 5 no se estima mas alto: se descompone en sub-issues antes de crearlo,
que es justo lo que el tope existe para forzar. Ofrecer un 8 "para casos excepcionales" convierte
el tope en una sugerencia y deja pasar sin dividir exactamente lo que habia que dividir.

### Paso 9 — Considerar si va a IA

Antes de cerrar el formulario, pregúntate:

```text
¿Esta issue cumple criterios de delegable a IA?
(ver workflows/02-triage-y-delegar.md sección 1.4)
  Sí → añadir label actor/ai
  No → seguir adelante (no añadir actor/human, es default)
```

### Paso 10 — Crear

**`projectId` es OBLIGATORIO** (regla del repo, no del schema de Linear — `issueCreate` acepta issues sin
project, pero esta casa no lo permite): toda issue debe pertenecer a un `project` que a su vez pertenezca
a una de las initiatives del workspace. Catálogo de initiatives relevante para este repo (medido
2026-09-05, ver `references/01-data-model.md` sección Initiative para el listado completo de las 10
activas):

| Capa | Initiative | id |
|---|---|---|
| Meta (orquestación/coordinación de la fábrica) | Talent Engine | `e445b88c-292b-4a7f-a4bd-0866b635e075` |
| Producto | Academia Ejemplo 2026 | `cfcbfe90-efd4-4faa-a702-d2532d64d9db` |

**Fail-closed**: si el trabajo a crear no encaja en NINGÚN project de la initiative que corresponda
(producto → `Academia Ejemplo 2026`; meta → `Talent Engine`), **PARAR y consultar al lead** antes de crear
la issue. No asignar a otra initiative ni inventar un project nuevo sin validar con el lead primero.

Mutation `issueCreate` (los nombres de labels/project/cycle se resuelven antes a sus UUIDs — `labelIds`, `projectId`, `cycleId`, `stateId`, `assigneeId`):

```graphql
mutation Create($input: IssueCreateInput!) {
  issueCreate(input: $input) { success issue { identifier url } }
}
# $input = {
#   teamId: "<TAL-team-uuid>", title: "<titulo>", description: "<description>",
#   labelIds: ["<uuid vertical>", "<uuid kind>", "<uuid actor/ai si aplica>"],  # UUIDs, no nombres — issueCreate rechaza labels no-UUID; resuelve nombre→UUID con issueLabels(filter:) antes
#   priority: <N>, estimate: <N>,
#   projectId: "<uuid del project — OBLIGATORIO>", projectMilestoneId: <uuid|null>,
#   cycleId: <uuid del cycle actual|null>, stateId: "<Backlog|Todo uuid>",
#   assigneeId: <uuid|null>
# }
```

### Paso 11 — Confirmar al humano

```text
✅ Issue creada: TAL-X "<titulo>"
   URL: https://linear.app/...

   Labels: vertical/land-online, kind:feat, actor/ai
   Priority: High
   Estimate: 3
   Project: Auth v2
   Cycle: current
   Assignee: @persona

¿Algo que ajustar?
```

## Variantes

### Variante A — Crear varias issues de un golpe

Si el humano pega una lista:

```text
1. Para cada item, ejecutar dedupe + triage independiente
2. Pero crearlas TODAS antes de confirmar
3. Resumen al final con todos los IDs creados
4. Si alguna requiere clarificación → no crearla, listar las que sí se pudo
```

### Variante B — Crear sub-issue

Mismo flow, pero pasando `parentId` (el UUID del parent) en el `input` de `issueCreate`:

```graphql
mutation CreateSub($input: IssueCreateInput!) {
  issueCreate(input: $input) { success issue { identifier url } }
}
# $input = { teamId: "<TAL>", parentId: "<uuid de TAL-100>", title: "Sub-tarea: ...", ... }
```

La sub-issue hereda del parent: project, milestone, cycle (si parent las tiene). Pero puedes overrideearlas.

### Variante C — Crear issue con template de Linear

Si el team tiene templates configurados, pasar `templateId` en el `input` de `issueCreate`:

```graphql
mutation CreateFromTemplate($input: IssueCreateInput!) {
  issueCreate(input: $input) { success issue { identifier url } }
}
# $input = { teamId: "<TAL>", templateId: "<uuid del template 'Bug Report'>", title: "<titulo>", ... }
# los demás campos del input overridean los del template
```

## Anti-patrones

❌ **No buscar duplicados**: causa fragmentación del backlog.

❌ **Description vacía o "ver Slack"**: contexto perdido a futuro.

❌ **Sin vertical label**: imposible filtrar/agrupar por plataforma.

❌ **Estimate aspiracional vs realista**: usa 5 si crees que es 3 — siempre acaba siendo más.

❌ **Asignar issue al cycle actual sin capacidad disponible**: revisa el cycle antes.

❌ **Title que es síntoma en vez de acción**: "Login no funciona" → "Corregir validación de password en login"

❌ **Batchear el cierre de duplicados al final**: si el dedupe del Paso 1 encuentra varios duplicados a
cancelar, resuélvelos **una issue a la vez** — comentario explicando por qué + cambio de estado antes de
pasar al siguiente candidato. Dejarlo todo para un batch final al terminar la sesión pierde trazabilidad
si algo se interrumpe a mitad de camino.
