# Prompt — Reporte semanal

> **Alcance**: contenido de uso libre para cualquier equipo que instale este skill. La fábrica de Talent Engine NO lo usa hoy (cycles desactivados en el team TAL; el trabajo se despacha por batches/encargos con `talent-orchestrator` y las issues se redactan con `talent-issue-craft`). Verificado 2026-09-05.

Plantilla para generar el reporte semanal del equipo Talent Engine. Útil viernes para compartir con stakeholders (CEO de Talent Network, leads de los verticales, etc.) lo entregado en la semana.

## Output esperado

Un Markdown que se puede compartir por:

- Slack (canal del equipo o canal directo con CEO)
- Email
- Document en Linear (asociado al workspace)

Estructura:

```markdown
# Talent Engine — Cycle W<N> (semana del <fecha-fecha>)

## TL;DR
[1-2 frases con lo más relevante. Lo que el lector se llevaría
si solo leyera esto.]

## Por initiative

### Talent Land
- Entregado: ...
- En progreso: ...
- Riesgos: ...

### Talent Media 2026
[idem]

### Talent Land Online 2026
[idem]

### Talent Academy 2026
[idem]

### Bootcamp Cripto 2026
[idem]

## Métricas
- Velocity: X/Y puntos completados (Z%)
- Issues cerradas: N
- Bugs detectados: M (de los cuales X críticos)
- PRs mergeados: P

## Highlights
[2-4 cosas notables, con contexto humano. No solo issues.]

## Próxima semana
[Top 3-5 prioridades del próximo cycle]

## Solicitudes / bloqueos
[Cosas que el equipo necesita de fuera]
```

## Cómo generarlo

### Paso 1 — Recoger los datos

```text
# TODAS las listas de abajo se PAGINAN con cursor (pageInfo { hasNextPage endCursor } + after) hasta
# hasNextPage=false, y filtran por team TAL — ver el patrón canónico en buscar-y-deduplicar.md §A.
# Se muestran sin el bucle por brevedad; first es el tamaño de página, NO un tope de resultados.

0. **COMPROBAR PRIMERO que hay cycles.** En un team con los cycles desactivados —el caso de TAL
   hoy— el paso 1 devuelve `nodes: []` **sin error**, y los pasos siguientes se ejecutan con un
   `<cycleId>` vacio: filtran por nada, no fallan, y producen un reporte vacio que parece un
   reporte de una semana sin trabajo. Un cero por no haber mirado se lee igual que un cero bueno.
   Si `nodes` viene vacio, **PARAR** y usar la variante sin cycles de abajo.

1. Identificar el cycle que se cierra (query GraphQL `cycles`):
   query { cycles(filter: { team: { key: { eq: "TAL" } }, isActive: { eq: true } }) { nodes { id number } } }
   (para el pasado: filtrar por número anterior, o isPast/endsAt según el caso)

   **VARIANTE SIN CYCLES** (la que aplica a TAL): el filtro `cycle: { id: { eq: "<cycleId>" } }` se
   cambia por una ventana temporal sobre el team, agrupando por project en vez de por cycle. Pero
   **la ventana NO es la misma para cada consulta**, y confundirlas vacia media pagina del informe:
   en el paso 2 va `completedAt: { gte: "<lunes ISO>", lte: "<domingo ISO>" }`, porque `completedAt` sirve SOLO para las completadas.
   Las issues abiertas del paso 3 no tienen ese campo, asi que filtrarlas por el las deja SIEMPRE vacias: para esas va `updatedAt` en la misma ventana.
   Y una seccion de abiertas vacia no se distingue de una semana sin nada abierto, que es el mismo
   cero mudo que el paso 0 evita en el otro extremo.
   El resto del procedimiento no cambia. Las metricas de velocidad planificada/completada no
   aplican: sin cycle no hay compromiso del lunes contra el que medir, y presentarlas calculadas
   sobre otra cosa seria inventarse la referencia.

2. Issues completadas en el cycle (selecciona la initiative vía el project — es `initiatives`, PLURAL):
   query($after: String) { issues(filter: {
     team: { key: { eq: "TAL" } }, cycle: { id: { eq: "<cycleId>" } }, state: { type: { eq: "completed" } }
   }, first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes {
     identifier title estimate assignee { name }
     project { name initiatives { nodes { name } } }
   } } }

3. Issues en progreso (rebotando o aún activas):
   query($after: String) { issues(filter: {
     team: { key: { eq: "TAL" } }, cycle: { id: { eq: "<cycleId>" } }, state: { type: { in: ["started","unstarted"] } }
   }, first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { identifier title state { name } } } }

4. Bugs nuevos creados esta semana:
   query($after: String) { issues(filter: {
     team: { key: { eq: "TAL" } }, labels: { name: { eq: "kind:fix" } }, createdAt: { gt: "<lunes-de-esta-semana ISO>" }
   }, first: 50, after: $after) { pageInfo { hasNextPage endCursor } nodes { identifier title createdAt } } }

5. Customer Needs procesados (vía GraphQL, paginado igual):
   query CustomerNeedsThisWeek { ... }
```

### Paso 2 — Agrupar por initiative

Para cada issue completada, extraer las initiatives de su project — `project.initiatives.nodes[].name` (el campo es plural; un project puede pertenecer a varias initiatives, normalmente una). Agrupar:

```text
Talent Media 2026:
  - TAL-101 (Done)
  - TAL-103 (Done)
  - TAL-110 (In Review)

Talent Land Online 2026:
  - TAL-87 (Done)
  - TAL-95 (In Progress)
```

### Paso 3 — Generar prosa por sección

Para cada initiative con actividad:

```markdown
### Talent Media 2026

**Entregado**:
- Dashboard de métricas v1: M2 completado (TAL-101, TAL-103).
  [Highlight humano si aplica: "Equipo de Media ya está usándolo en daily."]

**En progreso**:
- TAL-110 "Export PDF" en review, merge esperado lunes.

**Riesgos**:
- M3 (frontend) puede retrasarse si no llega diseño esta semana.
```

NO listar issues sin contexto. **Sintetizar**: "varios fixes de auth" es mejor que TAL-87, TAL-91, TAL-95 listados.

### Paso 4 — Calcular métricas

```text
velocity_planned = sum(estimate of all issues in cycle on Monday)
                  // dato del Project Update del lunes

velocity_completed = sum(estimate of all issues in cycle now in state Done)

bugs_new = count(issues created this week with label kind:fix)
bugs_critical = count of those with priority=1

prs_merged = derived from attachments (GitHub PR with state=merged)
```

Algunos datos requieren web_fetch o API de GitHub si no están en Linear.

### Paso 5 — Highlights

Esta es la parte humana. Pregúntate:

```text
- ¿Hubo alguna entrega especialmente impactante?
- ¿Algún bug crítico resuelto rápido (S1)?
- ¿Algún logro del equipo IA destacable?
- ¿Alguna métrica de producto mejorada (si tenemos visibilidad)?
- ¿Algún reconocimiento que merece visibilidad?
```

Escribir 2-4 highlights concretos, no genéricos:

```text
✓ "Lanzamos Dashboard v1 a Media; primer feedback positivo,
    usándose en daily de planning"
✓ "Resuelto S1 de checkout en 23 min (TAL-99). Post-mortem en la issue."
✓ "@persona shipeó 4 PRs incluyendo refactor mayor del payment client."

✗ "Buen trabajo del equipo"  ← genérico, sin sustancia
✗ "Cerramos 11 issues"        ← ya está en métricas
```

### Paso 6 — Próxima semana

Lo que el cycle planificado del lunes contendrá. Para esto:

```text
# 1) resolver el UUID del próximo cycle de TAL:
query { cycles(filter: { team: { key: { eq: "TAL" } }, number: { eq: <nº-del-próximo> } }) { nodes { id } } }
# 2) filtrar issues por cycle.id (no por number) + team, paginando con after hasta hasNextPage=false:
query($after: String) { issues(filter: { team: { key: { eq: "TAL" } }, cycle: { id: { eq: "<nextCycleId>" } } },
  first: 50, after: $after) { pageInfo { hasNextPage endCursor } nodes { identifier title estimate } } }
```

(Si el next cycle aún no se planifica, mejor escribir "TBD lunes".)

### Paso 7 — Solicitudes / bloqueos

Si el equipo necesita algo de fuera:

```text
- "Esperando diseño de M3 (Talent Media). @persona-design"
- "Necesitamos credenciales de API X. CC @stakeholder"
- "Decisión pendiente: ¿migrar BD ahora o post-Talent Land?"
```

Incluir si y solo si hay algo concreto. NO inventar bloqueos por relleno.

### Paso 8 — Output final

Pegar todo el Markdown estructurado.

Opcionalmente, crear como Document en Linear:

```graphql
mutation CrearDoc($title: String!, $content: String!) {
  # content va por VARIABLE $content (NO interpolar el markdown en la query: comillas/backslash/
  # saltos de línea la romperían). El title igual.
  documentCreate(input: { title: $title, content: $content }) { success document { id url } }
}
```

O simplemente devolver el Markdown al humano para que lo copie/pegue.

## Variantes

### Variante A — Reporte para CEO (más alto nivel)

Menos detalle técnico, más impacto:

```text
- Foco en initiatives, no en issues individuales
- Métricas de producto si están disponibles (no solo de Linear)
- Quitar la sección "Bugs nuevos detectados" (irrelevante a nivel ejecutivo)
- Highlights centrados en valor entregado, no en cantidad
```

### Variante B — Reporte interno solo del equipo

Más detalle, más honesto:

```text
- Incluir issues que NO se completaron y por qué
- Lecciones aprendidas (de retro)
- Trabajo IA: % aceptación, casos de fricción
- Comentarios crudos sobre fricción interna (process, herramientas)
```

### Variante C — Reporte mensual

Agregando 4 cycles:

```text
- Velocity trend (4 puntos)
- Initiatives status (cambios significativos)
- Big releases del mes
- Top issues por impacto, no por count
```

## Anti-patrones

❌ **Solo listar identifiers de issues**: ruido, sin valor para el lector.

❌ **Reporte que repite Linear UI**: si el lector ya tiene Linear, ¿por qué leer un dump?

❌ **Métricas sin contexto**: "Velocity 14 puntos" no dice nada sin comparativa.

❌ **Highlights genéricos**: "buen trabajo del equipo" no aporta. Sé específico.

❌ **Reportar todas las initiatives aunque no haya actividad**: si esta semana no hubo movimiento en una, omitirla con "(sin actividad esta semana)" o no listarla.

❌ **Omitir riesgos por miedo a transparentar**: el reporte sin riesgos huele a barniz. Si todo está perfect siempre, nadie te cree.

## Tip — Automatización

Una vez tengas un patrón estable, este reporte puede:

1. Generarse automáticamente en un cron (viernes 5pm)
2. Postearse a Slack #equipo-talent-engine
3. Crearse como Document en Linear automáticamente

Implementación de referencia: usar `scripts/linear-client.ts` con un nuevo script `weekly-report.ts` que ejecute todos los queries y formatee el markdown.
