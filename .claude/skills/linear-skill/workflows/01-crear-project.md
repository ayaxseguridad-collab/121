# Workflow — Crear un Project con milestones

Sigue este playbook cuando el humano pida crear un nuevo Project. Asegura que el Project respete el Linear Method y quede bien conectado a la initiative correcta.

## Pre-requisitos a verificar

Antes de tocar nada, valida:

- [ ] **¿A qué initiative pertenece?** Debe ser una de las 10 initiatives activas del workspace (verificado 2026-09-05; IDs en `examples/talent-engine-config.json`): Talent Engine (meta), Talent Portafolio, Genius Arena, Talent Sales Suite 2026, Event Engine 2026, Academia Ejemplo 2026, Talent Land, Bootcamp Cripto 2026, Talent Land Online 2026, Talent Media 2026. Producto de Academia Ejemplo → siempre `Academia Ejemplo 2026`. Si no encaja en ninguna, ¿es realmente un project?
- [ ] **¿Tiene fecha de entrega clara?** Sin targetDate, no es project todavía. Es idea.
- [ ] **¿Tiene un único lead?** Si dos personas pelean por owner, asignar a una.
- [ ] **¿Es realmente acotado?** Si es trabajo continuo sin fin → no project, es backlog del team.
- [ ] **¿Existe ya algo similar?** la query `projects(filter: { name: { containsIgnoreCase: "<texto>" } }, first: 50, after: $after)` con `pageInfo { hasNextPage endCursor }`, **recorriendo todas las páginas** (un duplicado puede estar fuera de la primera), antes de crear.

## Paso 1 — Recoger inputs del humano

Pide explícitamente si no los tienes:

```text
1. Nombre (en imperativo, sin año, sin redundancias):
   ✓ "Lanzar Dashboard de Métricas v1"
   ✗ "Dashboard 2026"
   ✗ "Talent Media Dashboard 2026"

2. Initiative parent (1 de las 10 activas)

3. Lead (humano único, no agente)

4. Target date (día/mes/quarter/half/year)

5. Resumen de 1 línea (campo summary)

6. Descripción más larga (campo description, project spec)
```

Si el humano da info parcial, propón valores razonables y pide confirmación:

```text
Propongo:
- Nombre: "Lanzar Dashboard de Métricas v1"
- Initiative: Talent Media 2026
- Lead: tú
- Target: end of Q3 2026 (30 sept)
- Summary: "Dashboard interno que unifica métricas de las 36 redes sociales"
- Description: a redactar contigo

¿Confirmas o ajustas?
```

## Paso 2 — Redactar el project spec (description)

Usa la plantilla del Linear Method. Mantenla **breve** (1 pantalla).

```markdown
## Why
[Por qué este project importa AHORA. Conexión con la initiative parent.
 1-2 párrafos máximo]

## What
[Lo que entrega este project, en bullets cortos]
- ...
- ...

## How
[Approach high-level — sin código, sin wireframes detallados]

## Success criteria
- [ ] Criterio medible y verificable
- [ ] Otro criterio medible

## Out of scope
[Lo que NO se hace en este project — gestiona expectativas]

## Risks
[Qué podría descarrilar — opcional pero útil]
```

Si el humano no tiene aún claros los criterios de éxito → no crees el project. Pídelo. Un project sin success criteria es vapor.

## Paso 3 — Crear el project en Linear

Usando la API GraphQL directa:

```graphql
mutation CrearProject { projectCreate(input: {
  teamIds: ["<TAL-team-uuid>"],
  name: "<nombre del paso 1>",
  description: "<spec del paso 2>",
  content: "<contenido markdown / resumen largo>",
  leadId: "<uuid del lead>",
  statusId: "<uuid del project status: 'planned' o 'started'>",   # NO existe un campo `state`
  targetDate: "<ISO date>"
}) { success project { id url } } }
```

`ProjectCreateInput` usa `statusId` (UUID de un project status del team; obténlo con `projectStatuses`), **no** un campo `state`. La relación con una initiative **no** es un campo del input: se crea DESPUÉS con `initiativeToProjectCreate`:

```graphql
mutation VincularInitiative {
  initiativeToProjectCreate(input: {
    initiativeId: "<uuid de la initiative>",
    projectId:    "<projectId recién creado>"
  }) { success }
}
```

**Valida CADA mutación antes de seguir**: exige `success: true`, cero `errors[]` y (en `projectCreate`)
un `project.id` no vacío. Encadenar: crear project → (validar) → vincular initiative → (validar) → crear milestones.

**No es transaccional** — Linear no ofrece atomicidad multi-mutación. Si `projectCreate` tuvo éxito pero
`initiativeToProjectCreate` o un `projectMilestoneCreate` posterior FALLA, queda un **project huérfano**
(sin initiative / sin milestones). Compensa explícitamente: al detectar el fallo, **revierte** lo ya
creado — `projectDelete(id: <projectId>)` (reemplaza a `projectArchive`, deprecada en favor de `projectDelete`) antes de abortar. Guarda los
ids creados en cada paso para poder deshacerlos.

Recoge el `id` del project creado para los siguientes pasos.

## Paso 4 — Diseñar los milestones

Un project típico tiene **3-5 milestones**, no más. Patrón típico:

| Milestone | Significado |
|---|---|
| M1: Diseño / Spec aprobado | Antes de tocar código, hay claridad |
| M2: Backend / núcleo funcional | Lo crítico funciona end-to-end |
| M3: Frontend / UX completa | Lo demás funciona |
| M4: Beta cerrada | Validación con usuarios reales |
| M5: Lanzamiento público | El project termina |

Adaptar al tipo de project. Para refactors:

| Milestone |
|---|
| M1: Audit completo y plan |
| M2: Migración de módulos no críticos |
| M3: Migración de módulos críticos |
| M4: Cleanup y deprecation |

Para integraciones nuevas:

| Milestone |
|---|
| M1: PoC funcionando local |
| M2: Auth y flow real |
| M3: Manejo de errores y retries |
| M4: Lanzamiento a producción |

## Paso 5 — Crear los milestones en Linear

Para cada milestone:

```graphql
mutation CrearMilestone { projectMilestoneCreate(input: {
  projectId: "<projectId>",
  name: "<nombre>",
  description: "<lo que entrega este milestone>",
  targetDate: "<ISO date>",
  sortOrder: 1024   # entero concreto por milestone: 1024, 2048, 3072, ... (calcula 1024*N y pásalo literal; "<1024 * N>" NO parsea)
}) { success } }
```

**Importante**: las fechas de los milestones deben ser monotónicas (M1 < M2 < M3...) y la del último milestone ≤ targetDate del project.

## Paso 6 — Confirmar al humano

Resumen para revisión:

```text
✓ Project creado: TAL → "Lanzar Dashboard de Métricas v1"
  URL: https://linear.app/...
  Initiative: Talent Media 2026
  Lead: <persona>
  Target: 30 sept 2026

  Milestones:
  - M1: Diseño aprobado — 31 may
  - M2: Backend con datos reales — 30 jun
  - M3: Frontend funcional — 31 jul
  - M4: Beta cerrada — 31 ago
  - M5: Lanzamiento público — 30 sept

¿Quieres que arranque a poblar issues bajo M1?
```

## Paso 7 — Opcional: poblar primeras issues

Si el humano dice "sí, poblamos issues":

1. Pide al humano la lista de "primeras 5-10 cosas que harías" para M1
2. Para cada una, sigue el flujo de `prompts/crear-issue.md` (con dedupe)
3. Asigna cada issue a `projectMilestoneId = M1`
4. Asigna cycle = current si M1 termina esta semana, o backlog si después
5. Estima cada una (convención de la casa: 1, 2, 3 o 5; la estimación nativa del team está desactivada)

## Errores a evitar

❌ **Crear el project con fecha "TBD"** — si no hay fecha, no hay project.

❌ **Llamar al project con el año en el nombre** — el año vive en la initiative.

❌ **Crear más de 5-6 milestones** — diluye la barra de progreso. Si necesitas más, considera dos projects.

❌ **No vincular a initiative** — el project queda huérfano y no aparece en la vista estratégica.

❌ **Description larga y exhaustiva** — Linear Method dice brevedad. Specs largas van en Documents adjuntos al project.

❌ **Asignar al equipo entero como lead** — un único lead. Punto.

❌ **Crear el project en estado "started"** sin que realmente esté empezado — usa `planned` hasta que entre al primer cycle.

## Variantes

### Variante A — Project pequeño sin milestones

Si el project es chico (terminable en 1-2 cycles, ~10 issues), saltar milestones está bien. La barra de progreso del project usa todas las issues directamente.

### Variante B — Project compartido entre teams

Cuando creemos un team adicional (ej: Operaciones), un project puede pertenecer a varios teams pasando `teamIds: [...]` en lugar de uno solo. **No aplica hoy** porque solo tenemos team TAL.

### Variante C — Project como sub-effort de uno mayor

Linear no soporta nesting de projects. Si necesitas eso, alternativas:

1. Initiative madre con sub-initiatives → projects bajo cada sub-initiative
2. Un solo project con milestones que reflejen las "sub-fases"

## Después de crear

- Linear pedirá un primer Project Update si has configurado weekly. El primero suele ser "Project arrancado, M1 en progreso".
- Comparte la URL del project con stakeholders relevantes (vía Slack o Linear Asks).
- Si el project tiene impacto visible, planifica un changelog público al lanzamiento.
