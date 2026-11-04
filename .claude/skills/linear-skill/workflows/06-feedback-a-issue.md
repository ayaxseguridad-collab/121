# Workflow — Feedback a Issue

Convertir feedback de equipos internos (Media, Land, Academy) o de usuarios externos en issues bien estructuradas en Linear, conservando trazabilidad al origen via Customer Needs.

## Cuándo ejecutar

- El humano pega un thread de Slack del equipo de Media
- El humano forwarda un email de un partner
- El humano dice "mira lo que me preguntó X, hay que hacer algo"
- Llega un ticket de support
- Hay un comentario en el changelog público

## Paso 1 — Identificar items de trabajo

Un thread de Slack puede contener:

- 0 items (solo conversación)
- 1 item (un pedido claro)
- N items (múltiples pedidos en la misma conversación)

Para cada item identificable:

1. ¿Es **petición de feature**, **reporte de bug**, o **pregunta**?
2. ¿Tiene scope claro o necesita aclaración?

Si necesita aclaración:

- **NO crear issue todavía**
- Pedir al humano que aclare con el reporter
- Cuando vuelva con info → seguir paso 2

## Paso 2 — Crear Customer si no existe

En Talent Network, los "customers" internos son los equipos verticales (Media, Land MX, etc.). El flujo es **idempotente por `externalId` estable** (NO por nombre): busca por una clave determinista y **reutiliza** el customer si existe; solo llama a `customerCreate` cuando NO hay coincidencia.

**⚠️ TOCTOU**: Linear no impone unicidad de nombre, así que un get-or-create por nombre tiene una carrera (dos ejecuciones concurrentes → dos customers). Mitigación: usar un **`externalId` determinista** (p. ej. `team-media`) como clave de idempotencia — filtra por él y ponlo en `externalIds` al crear; un `externalIds: []` NO da clave estable.

```graphql
# 1) buscar existente por la clave estable externalId (no por nombre):
query BuscarCustomer($extId: String!) {
  customers(filter: { externalIds: { contains: $extId } }, first: 10) { nodes { id name externalIds } }
}
# 2) SOLO si nodes está vacío, crear (con el externalId determinista):
mutation CrearCustomer {
  customerCreate(input: {
    name: "Equipo Media",          # o "Equipo Land MX", etc.
    domains: [],                   # no aplica para internos
    externalIds: ["team-media"]    # clave estable de idempotencia (determinista, no vacía)
  }) { success customer { id name } }
}
```

(Usa GraphQL directo o `scripts/linear-client.ts`)

Customers externos (sponsors, partners de Talent Land) sí pueden tener domain.

## Paso 3 — Decidir: ¿Customer Need o Issue directa?

**Customer Need** — si:

- El feedback viene de un canal/persona externa al equipo Talent Engine
- Quieres preservar la fuente para mostrar al stakeholder "te escuchamos"
- Hay potencial de varios feedbacks similares para bundlear

**Issue directa** — si:

- El feedback viene de alguien dentro de Talent Engine
- Es un follow-up técnico interno (de un retro, de un debug session)
- No hay valor en preservar el "quién pidió"

En el 80% de casos del equipo Talent Engine: Customer Need.

## Paso 4 — Crear el Customer Need + Issue

Patrón "from need to ticket":

### Si va a ser una issue nueva

> **`issueId` es el UUID del issue** (el `id` que devuelve `issueCreate`, o `issue(id:)`), **NO** el identificador `TAL-N`. Pasar `TAL-N` no vincula (falla o queda huérfano). Igual en los ejemplos de bundle de abajo (`A`/`B`/`C` son UUIDs).

```text
1. Crear el issue (bien estructurado, con todo el triage hecho)
2. Crear el Customer Need vinculado al issue:

mutation CrearNeed {
  customerNeedCreate(input: {
    customerId: "<uuid del customer>",
    body: "<texto del feedback original, casi literal>",
    issueId: "<uuid del issue creado>",
    priority: 1   # escala de Customer Need: 0 = sin prioridad, 1 = importante (NO la escala 1-4 de issues)
  }) { success need { id } }
}
```

### Si vincular a issue existente

```graphql
mutation VincularNeed {
  customerNeedCreate(input: {
    customerId: "<uuid del customer>",
    body: "<feedback>",
    issueId: "<uuid del issue existente>",
    priority: 1   # escala de Customer Need: 0 = sin prioridad, 1 = importante (NO la escala 1-4 de issues)
  }) { success need { id } }
}
```

Esto incrementa el contador de Customer Needs en esa issue → **señal fuerte de demanda**.

## Paso 5 — Si el feedback genera múltiples issues

A veces un thread genera 3-5 issues. Patrón (`CustomerNeedCreateInput` **no** tiene un campo para
agrupar — no existe `bundleId`; los needs se agrupan por su `customer` común en la UI):

```text
1. Crear cada issue con triage completo (vertical, type, priority, estimate)
2. Crear un Customer Need por issue, TODOS con el MISMO customerId:
   - customerNeedCreate(input: { customerId, body, issueId: A })
   - customerNeedCreate(input: { customerId, body, issueId: B })
   - customerNeedCreate(input: { customerId, body, issueId: C })
3. Al compartir customer, los needs aparecen juntos bajo ese Customer en la UI
```

## Paso 6 — Adjuntar la fuente

El Customer Need por sí mismo es metadata. Para preservar la fuente original (Slack thread, email):

```graphql
mutation AdjuntarFuente {
  attachmentLinkURL(
    issueId: "<uuid>",
    url: "<link al thread de Slack o email>",
    title: "Solicitud original de @<persona>"
  ) { success attachment { id } }
}
# attachmentLinkURL toma args directos (issueId, url, title) — NO existe `subtitle` ni `input:`.
```

Si el thread de Slack es interno y el link no es público fuera del workspace de Slack, está bien — los devs de Talent Engine sí pueden acceder.

## Paso 7 — Confirmar al humano

Resumen para validación:

```text
✅ Procesado feedback de @persona en #canal-X.

Issues creadas:
- TAL-101: "Añadir export PDF a dashboard"
  → vertical/media, kind:feat, priority high, estimate 3
  → vinculado a Customer Need
- TAL-102: "Corregir cálculo de fechas en weekly report"
  → vertical/media, kind:fix, priority medium, estimate 2
  → vinculado a Customer Need

Customer: "Equipo Media"
Customer Needs creados: 2 (customer compartido)

Slack thread adjunto a ambas.
```

## Paso 8 — Comunicar al solicitante

Una buena práctica (humana, no automatizable):

```text
"Gracias por el feedback. Hemos creado las issues TAL-101 y TAL-102.
Esperamos abordar la primera este sprint y la segunda el siguiente.
Te avisamos cuando estén listas."
```

Linear no envía esto automáticamente — es responsabilidad del humano que recibió el feedback.

## Patrones específicos

### Patrón A — El feedback es ambiguo

```text
"Estaría bien que el dashboard fuera más rápido."

→ NO crear issue. Pedir aclaración al humano:
   "Más rápido en qué? Cuál es la página/acción específica? Qué tan rápido?"
```

Cuando vuelva con datos concretos, crear.

### Patrón B — El feedback es duplicado de algo en backlog

```text
query Feedback($q: String!, $after: String) { issues(filter: { team: { key: { eq: "TAL" } }, or: [ { title: { containsIgnoreCase: $q } }, { description: { containsIgnoreCase: $q } }, { comments: { body: { containsIgnoreCase: $q } } } ] }, first: 50, after: $after) { pageInfo { hasNextPage endCursor } nodes { identifier title state { name } } } }
# paginar con after hasta hasNextPage=false; dedup solo dentro del team

→ Si hay match:
   1. NO crear nueva issue
   2. Crear Customer Need vinculado a la EXISTENTE
   3. Considera subir prioridad si era baja (varios needs = más demanda)
```

### Patrón C — El feedback es realmente sobre operación (no desarrollo)

A veces el equipo de Media pregunta cosas que no son de Talent Engine:

```text
"¿Pueden hacer un post sobre X?"

→ NO crear issue en TAL.
→ Recordar al solicitante que Talent Engine solo hace desarrollo.
→ Redirigir al canal/persona correcto.
```

### Patrón D — El feedback es preguntar cómo usar algo existente

```text
"¿Cómo configuro X en el dashboard?"

→ NO crear issue para "implementar X" si X ya existe.
→ Crear issue kind:docs si la docs es ambigua.
→ Responder al solicitante con instrucciones.
```

## Anti-patrones

❌ **Crear una issue por cada mensaje de Slack sin filtrar**: el 90% no es trabajo.

❌ **Issues con descriptions tipo "ver thread"**: si el thread se borra/archiva, pierdes el contexto. Copia lo importante a la description.

❌ **Customer Needs sin Customer**: pierdes la trazabilidad agregada. Crea el Customer primero.

❌ **Vincular Customer Need a Project en lugar de Issue**: para feedback puntual, Issue. Project Customer Needs son para "demanda agregada de algo grande".

❌ **No comunicar al solicitante**: si nadie le dice que se hizo, asume que fue ignorado y deja de reportar.

## Tip — automatización futura

Linear soporta integración nativa con:

- Intercom → Customer Needs auto
- Zendesk → idem
- Slack → webhook personalizado posible

Si el equipo de Media usa Slack intensivamente, considerar configurar:

- Bot de Slack que captura mensajes con cierta sintaxis (ej: `/feedback`)
- Lo manda a un endpoint
- El endpoint crea Customer Need automáticamente vinculado al canal

Pendiente, no urgente. Primero validar que el flujo manual funciona.
