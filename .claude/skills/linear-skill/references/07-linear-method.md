# The Linear Method — Filosofía y prácticas

> **Alcance**: contenido de uso libre para cualquier equipo que instale este skill. La fábrica de Talent Engine NO lo usa hoy (cycles desactivados en el team TAL; el trabajo se despacha por batches/encargos con `talent-orchestrator` y las issues se redactan con `talent-issue-craft`). Verificado 2026-09-05.

Lee este documento cuando necesites justificar una decisión de organización, cuando estés tentado a "personalizar" Linear con configuraciones complejas, o cuando alguien del equipo proponga prácticas que rompan la filosofía base.

Linear no es solo una herramienta — es una **opinión articulada** sobre cómo construir software. Su CEO Karri Saarinen y equipo publicaron *The Linear Method* (<https://linear.app/method>) como manifiesto. Este documento condensa los principios y los aplica al contexto de Talent Engine.

## Los 8 principios

### 1. Build for the creators

La herramienta sirve a los que construyen, no a los que reportan. Si una feature optimiza reporting a costa de la productividad del developer, Linear no la implementa. **Aplicación**: no metas campos custom, workflows complejos o automations que ralenticen al equipo solo porque facilitan métricas.

### 2. Purpose-built, not flexible

Linear elige tener **opciones limitadas pero correctas**, no flexibilidad infinita. Es la antítesis de Jira. **Aplicación**: cuando dudes entre dos formas de hacer algo, elige la que Linear hace por defecto. Hay razón detrás.

### 3. Create momentum, don't sprint

Sprints crean ansiedad y caídas de productividad. Linear prefiere *cycles* — ritmo constante. **Aplicación**: cycles de 1 semana en un equipo pequeño (el team TAL los tiene desactivados y trabaja por encargos; ver nota de alcance). Sin "crunches" pre-cycle. Si una semana no entregas, rebota al siguiente cycle sin drama.

### 4. Meaningful direction

Initiatives agrupan un conjunto de Projects atados a un objetivo compartido; los Milestones NO son un nivel jerárquico propio que cruza Issues globalmente — son una subdivisión dentro de un único Project (se definen por-Project, no se comparten entre projects), y los Issues cuelgan de su Project y, opcionalmente, de un Milestone de ese mismo Project. Cada nivel responde a un "por qué" del nivel superior. **Aplicación**: si una issue no se puede ubicar en una initiative o project, probablemente no debería existir todavía.

### 5. Aim for clarity

Llamar las cosas por su nombre. Sin jerga inventada. **Aplicación**: cuando el equipo invente nombres ("epics", "spikes"), pregúntate si es por motivo real o por tradición. Linear se llama Project a un project; no necesitas llamarlo "epic".

### 6. Say no to busywork

Cualquier proceso que requiera mantenimiento manual sin generar valor → eliminar. **Aplicación**: no añadas campos custom obligatorios "para tener trazabilidad" si nadie va a leerlos. No metas standups en Linear si ya los tienes en Slack.

### 7. Simple first, then powerful

Empezar simple, añadir complejidad solo cuando duela no tenerla. **Aplicación**: arrancas con pocos estados (TAL usa 9 hoy), taxonomía de labels mínima, un solo team. Si más adelante una decisión de mayor complejidad se justifica con dolor concreto, la añades.

### 8. Decide and move on

Mejor decidir mal y corregir que paralizarse. **Aplicación**: en triage, decide en 30 segundos. Si la decisión es errónea, será fácil revertirla.

## Las 12 prácticas operativas

### a. Set strategic product initiatives

Initiatives son los objetivos a largo plazo. Cada Project debe vivir bajo una. **Ejemplo**: una initiative por plataforma o negocio (TAL tiene 10 activas a 2026-09-05). Cada Project que crees, vincúlalo a una.

### b. Connect daily work to larger goals with projects

Los Projects son el puente entre el trabajo diario (Issues) y el objetivo compartido (Initiative). **TAL**: toda Issue vive dentro de un Project; si no encaja en ninguno, probablemente aún no debería crearse (ver principio 4).

### c. Work in n-week cycles

Cycles cortos y constantes. **Ejemplo**: 1 semana, lunes-domingo, con auto-add de started/completed (TAL: cycles desactivados).

### d. Manageable backlog

El backlog NO es cementerio de ideas. Si algo lleva ahí 3 meses sin moverse, archívalo. **TAL**: revisión mensual del backlog para limpiar.

### e. Mix feature and quality work

Cada cycle debe tener un mix. No te pases tres cycles solo en features (deuda técnica) ni solo en bugs (paras innovación). **TAL**: aspirar a 70% feature / 20% bug-quality / 10% chore por cycle.

### f. Specify project and issue owners

Sin "co-owners". Una persona rinde cuentas por Project (Lead) y por Issue (Assignee); el resto colabora como `members` del Project. **TAL**: regla absoluta. Si dos personas pelean por ownership, asignar a una y la otra revisa. (Nota: `delegate` es un término real de Linear pero acotado a delegar una Issue a un Agente IA manteniendo un humano como assignee responsable — no es un rol genérico de co-ownership humano.)

### g. Write project specs (kept short)

El spec del project es el norte del trabajo. **Brevedad sobre exhaustividad**. **TAL**: máximo 1 página markdown. Si necesitas más, usa Documents adjuntos.

### h. Understand your users

Las decisiones de producto parten de necesidades reales, no de intuición aislada. **TAL**: toda Issue originada en feedback de alumnos/usuarios debe enlazar el Customer Request de origen (ver Anti-jargón más abajo).

### i. Scope issues to be as small as possible

Idealmente varias terminadas por semana por persona. Si tarda una semana entera, descomponer. **TAL**: estimate ≤ 5 (convención de la casa). >5 = sub-issues. >8 = Project con milestones.

### j. Measure progress with actual work

No con story points abstractos como proxy único. **TAL**: el diff del PR es la verdad. Insights de Linear permite medir por conteo de issues completadas O por Effort (estimate total) — usamos conteo/diff como señal primaria, no ambas cosas como ritual.

### k. Run cross-functional teams

Designer + engineer en el mismo team. **TAL**: nuestro team TAL es naturalmente cross-functional (somos pocos).

### l. Write a changelog

El changelog es para usuarios. **TAL**: cada release significativa de cada plataforma debe ir a un changelog público (al menos para Talent Land Online y bootcamp.cripto si tienen usuarios externos).

## Cómo se traduce esto al skill

```text
┌──────────┐   lunes    ┌───────────┐  1-2 semanas  ┌─────────┐  viernes  ┌─────────┐
│ Backlog   │───────────▶│ Cycle N    │──────────────▶│ Review   │──────────▶│ Retro   │
└──────────┘  planning   └───────────┘   trabajo      └─────────┘           └────┬────┘
      ▲                                                                          │
      └───────── issues no completadas vuelven al backlog / próximo cycle ───────┘
```

### Decisiones que el skill toma SIN preguntar (porque siguen el método)

- Crear issue con estimate >5 → preguntar antes de crear "¿quieres que la divida en sub-issues?"
- Project sin initiative → preguntar a cuál pertenece
- Issue sin label vertical/* → asignar uno o preguntar
- Issue con assignee múltiple → asignar al primero, otros como members
- Issue muy similar a otra existente → comentar en lugar de crear

### Decisiones que el skill DELEGA al humano

- Cuándo cerrar una initiative
- Cuándo retirar un team
- Cambios en workflow states
- Cambios en agent guidance
- Borrado de cualquier entidad
- Asignaciones a personas específicas (siempre proponer, humano confirma)

### Antipatrones que el skill rechaza

- "Vamos a usar story points y no estimates" → estimates son el sistema de Linear
- "Vamos a crear un team por proyecto" → no, projects son projects
- "Vamos a tener custom fields para tracking de stakeholder" → labels o Customer Requests
- "El project Q1 será un project anual" → no, eso es initiative
- "Cierro el cycle a mitad de semana porque nadie hizo nada" → no, deja que rebote
- "Reasignar issues no completadas a otra persona automáticamente" → el rebote conserva owner, intencional

## Cómo escribir un Project Spec a la Linear

Plantilla recomendada (lo verás también en `prompts/`):

```markdown
## Why
[1-2 párrafos: por qué este proyecto importa, a qué initiative sirve]

## What
[Lista corta de lo que entrega este project. NO la spec completa, solo el "shape"]

## How
[Approach high-level. Sin código, sin diseños detallados. Solo dirección]

## Success criteria
- [ ] Criterio medible 1
- [ ] Criterio medible 2

## Out of scope
[Lo que explícitamente NO entra en este project, para gestionar expectativas]

## Risks
[Lo que podría hacer descarrilar el project]

## Milestones
- M1: [...] — fecha
- M2: [...] — fecha
- M3: [...] — fecha
```

**Brevedad**: idealmente 1 pantalla. Si necesitas más detalle, va en Documents adjuntos al project, no en la description.

## Cómo escribir un Project Update semanal

Plantilla (config: viernes, weekly):

```markdown
## Esta semana
- [Lo entregado, con links a PRs si hay]
- ...

## Próxima semana
- [Lo planeado]
- ...

## Bloqueos / riesgos
- [Si hay; si no, "ninguno"]

## Health
[Justificación si es atRisk u offTrack; si onTrack, omitir]
```

Linear pone health (onTrack/atRisk/offTrack) en la UI; tú añades el contexto.

## Cómo retro de cycle

Después de cerrar el cycle de viernes:

```markdown
## Cycle W19 — Retro

### Entregado
- [X issues completadas, total estimate Y]
- Highlights: ...

### No entregado
- [Issues que rebotaron al siguiente cycle, con razón]

### Velocidad
- Estimate planificado: Z
- Estimate completado: W
- Ratio: W/Z

### Lecciones
- [1-2 cosas a cambiar la próxima]

### Reconocimientos
- @persona por X
```

NO hace falta meeting; basta con que el lead lo escriba como Project Update o Document, y los demás reaccionen.

## Anti-jargón

Linear evita términos heredados de Jira/Scrum. Equivalencias:

| Término que NO usar | Término correcto en Linear |
|---|---|
| Epic | Project |
| Story | Issue |
| Task | Issue (o sub-issue si está dentro de otra) |
| Sprint | Cycle |
| Story points | Estimate |
| Backlog grooming | Triage / cycle planning |
| Sprint planning | Cycle planning |
| Sprint review | Cycle review / retro |
| Epic owner | Project lead |
| Bug ticket | Issue (with label `kind:fix`) |
| Feature request | Customer Request + Issue (el objeto interno de API se llama `CustomerNeed`, pero la feature de cara al usuario se llama "Customer Requests") |

Cuando alguien diga "epic", traduce a Project en tu cabeza. Cuando alguien diga "story points", traduce a estimate.

## Cuándo violar el método

Las reglas existen para servir, no para tiranizar. Casos donde es OK desviarse:

- **Cliente requiere algo específico**: si una entidad legal exige campos custom o flujos diferentes (ej: compliance), añade lo mínimo necesario.
- **Integración externa fuerza una práctica**: si Slack/Jira/Notion impone una estructura, adapta hasta donde haga falta.
- **El equipo crece**: a 10+ personas algunas reglas se relajan (ej: múltiples teams especializados).

Mientras seamos 2-3, **todas las reglas aplican estrictas**. La velocidad de un equipo pequeño viene de no negociar el método.
