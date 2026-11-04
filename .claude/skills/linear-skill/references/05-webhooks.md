# Linear — Webhooks y eventos

Lee este documento cuando vayas a configurar receivers de eventos de Linear (para automatizaciones, integraciones, agentes IA, dashboards en tiempo real). Linear envía webhooks firmados con HMAC-SHA256 ante eventos de issues, projects, comments, etc.

## Tabla de contenidos

1. [Configuración](#configuración)
2. [Headers y formato del payload](#headers-y-formato-del-payload)
3. [Verificación de seguridad](#verificación-de-seguridad)
4. [Tipos de eventos](#tipos-de-eventos)
5. [Reintentos](#reintentos)
6. [Webhook agentic — AgentSessionEvent](#webhook-agentic--agentsessionevent)
7. [SDK oficial — `LinearWebhookClient`](#sdk-oficial--linearwebhookclient)
8. [Patrones de procesamiento](#patrones-de-procesamiento)
9. [Debugging](#debugging)
10. [Abiertos / no documentados por Linear](#abiertos--no-documentados-por-linear)

```text
Linear event (issue creada, comment, etc.)
        │  headers: Linear-Signature, Linear-Event, Linear-Delivery
        ▼
┌───────────────────────┐    inválida    ┌──────────┐
│ verificación (§3)       │────────────────▶│  401      │
└───────────┬─────────────┘                 └──────────┘
            │ válida
            ▼
┌───────────────────────────────────────────────────┐
│ dispatch por Linear-Event (Issue/Comment/Agent...)  │
└───────────────────────────────────────────────────┘
            │
            ▼
      200 OK rápido — si tarda, Linear reintenta (ver "## Reintentos")
```

## Configuración

**Vía UI**: Settings → API → Webhooks → New webhook (ruta de UI NO reconfirmada el 2026-09-05; verificar en la UI antes de instruir — regla 20)

**Vía API** (mutation):

```graphql
mutation CreateWebhook($input: WebhookCreateInput!) {
  webhookCreate(input: $input) {
    success
    webhook { id secret }
  }
}
```

```json
{
  "input": {
    "url": "https://my-server.com/linear-webhook",
    "teamId": "<uuid del team o null para workspace>",
    "label": "Mi handler",
    "resourceTypes": ["Issue", "Comment", "Project"],
    "allPublicTeams": false
  }
}
```

`WebhookCreateInput.secret` es **opcional** (`String`, no `String!`): si no lo pasas, Linear lo autogenera
("Automatically generated if not provided during creation", SDL vivo, `last_verified: 2026-09-05`). Puedes
pasar el tuyo si necesitas fijarlo de antemano.

**Importante**: la respuesta incluye `secret` — guárdalo. Es el secret usado para verificar la firma HMAC.
Si lo pierdes, **no hace falta regenerar el webhook completo**: usa la mutation dedicada
`webhookRotateSecret(id: String!)`, que rota el secret in-place e invalida el anterior de inmediato (el
webhook conserva su `id`, `url` y `resourceTypes`). Pregunta abierta (no verificada en esta sesión): si
`Webhook.secret` es legible en una query posterior a la creación (`webhooks { nodes { secret } } }`) o si
Linear lo enmascara — trátalo como "solo se ve una vez" hasta confirmarlo con una llamada real.

## Headers y formato del payload

Cada webhook llega como POST con estos headers:

```text
Accept-Charset:       utf-8
Content-Type:        application/json; charset=utf-8
Linear-Delivery:     <UUID único de esta entrega>
Linear-Event:        <Issue | Comment | Project | ... >
Linear-Signature:    <hex HMAC-SHA256 del body>
Linear-Timestamp:    <epoch en milisegundos, cuándo se envió el webhook>
User-Agent:          Linear-Webhook
```

`Linear-Timestamp` (header) y `webhookTimestamp` (campo del body, ver abajo) llevan el mismo dato en
ms desde epoch — no son inconsistentes entre sí, son dos superficies del mismo valor (confirmado contra
`https://linear.app/developers/webhooks`, `last_verified: 2026-09-05`). Para el anti-replay usa SIEMPRE el
campo del body (`webhookTimestamp`, cubierto por la firma); el header NO está firmado y puede falsificarse
(el SDK oficial corrigió justo ese bypass en 2026-05, linear/linear#1140). El helper `isFreshTimestamp` de este
documento usa el campo del body.

**Cuerpo (JSON)**:

```json
{
  "action": "create",          // create | update | remove
  "type": "Issue",             // entidad
  "data": { ... },             // objeto entero
  "updatedFrom": { ... },      // valores anteriores (solo en update)
  "actor": { ... },            // quién disparó el evento — union, ver nota abajo
  "webhookTimestamp": 1746369000000,
  "webhookId": "<uuid>",
  "organizationId": "<uuid>"
}
```

`webhookTimestamp` es ms desde epoch. Úsalo para anti-replay.

**Actor union — variant `external-user` (2026-07-02, `last_verified: 2026-09-05`)**: el campo `actor` del
payload es una unión con varios variants (`User`, apps/integraciones OAuth, y desde el 2 de julio de 2026
también **`external-user`**). Antes de ese fix, las acciones disparadas por un external user (p. ej. vía
Customer Requests / integraciones de soporte) no poblaban correctamente el `actor` de nivel superior del
webhook — ahora sí. Si tu handler distingue "quién hizo esto" para lógica de negocio, contempla este variant
además de `User` e integraciones.

## Verificación de seguridad

**Tres validaciones obligatorias**:

### 1. Verificar firma HMAC-SHA256

```typescript
import * as crypto from "crypto";

function verifySignature(
  rawBody: string | Buffer,
  signatureHeader: string,
  secret: string
): boolean {
  const computed = crypto
    .createHmac("sha256", secret)
    .update(rawBody)
    .digest("hex");

  // timing-safe comparison para prevenir timing attacks
  const a = Buffer.from(computed);
  const b = Buffer.from(signatureHeader);
  // timingSafeEqual lanza RangeError si los buffers difieren en longitud —
  // signatureHeader es input del atacante, así que hay que descartarlo antes.
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}
```

**⚠️ Crítico**: `rawBody` debe ser el body crudo, no el resultado de `JSON.parse(body)`. Frameworks como Express con `body-parser` reemplazan el body por defecto. Configura para preservar el raw:

```typescript
// Express
import express from "express";
const app = express();
app.use(express.raw({ type: "application/json" }));

app.post("/linear-webhook", (req, res) => {
  const rawBody = req.body; // Buffer
  const signature = req.header("Linear-Signature")!;
  if (!verifySignature(rawBody, signature, SECRET)) {
    return res.status(401).end();
  }
  const payload = JSON.parse(rawBody.toString());
  // ...procesar
  res.status(200).end();
});
```

### 2. Validar timestamp (anti-replay)

```typescript
function isFreshTimestamp(webhookTimestampMs: number, toleranceSeconds = 60): boolean {
  const nowMs = Date.now();
  const ageMs = Math.abs(nowMs - webhookTimestampMs);
  return ageMs < toleranceSeconds * 1000;
}
```

Rechaza webhooks de hace más de 60 segundos (atacante podría reenviar uno capturado).

### 3. Validar IP de origen (opcional pero recomendado)

Linear publica IPs de origen fijas para webhooks salientes — usarlas para allowlist de firewall:

```text
35.231.147.226
35.243.134.228
34.140.253.14
34.38.87.206
34.134.222.122
35.222.25.142
```

Lista sujeta a ampliación; fuente <https://linear.app/developers/webhooks>, consultado 2026-09-05.

**Ejemplo combinado** (handler completo) — fail-closed: `Linear-Delivery` es obligatorio (sin él
no hay forma de deduplicar un reintento) y el `200` se responde SOLO tras encolar con éxito
(`await`, no fire-and-forget) — un fallo de cola debe responder 5xx para que Linear reintente, no
un 200 que confirme un evento que en realidad se perdió. **`enqueueForProcessing()` NO está
implementada aquí** — es un placeholder que representa "tu cola/tabla real con constraint UNIQUE
en `deliveryId`". Copiar este handler sin implementar esa función con idempotencia real reproduce
el mismo problema que el ejemplo evita en apariencia: dos entregas concurrentes o un retry tras
perder el ACK ejecutarían los efectos downstream dos veces.

```typescript
async function handleWebhook(req: Request, res: Response) {
  const rawBody = req.body as Buffer;
  const signature = req.header("Linear-Signature");
  const eventType = req.header("Linear-Event");
  const deliveryId = req.header("Linear-Delivery");

  if (!signature || !eventType || !deliveryId) {
    return res.status(400).end("Missing headers (incluye Linear-Delivery, obligatorio)");
  }

  if (!verifySignature(rawBody, signature, process.env.LINEAR_WEBHOOK_SECRET!)) {
    return res.status(401).end("Bad signature");
  }

  const payload = JSON.parse(rawBody.toString());

  if (!isFreshTimestamp(payload.webhookTimestamp)) {
    return res.status(401).end("Stale timestamp");
  }

  // await real: si enqueueForProcessing falla, el catch responde 5xx (Linear reintenta) en vez
  // de un 200 que confirmaría un evento no encolado. "Rápido" no significa "sin esperar" — el
  // presupuesto de Linear son 5s (ver "## Reintentos" abajo), suficiente para una reserva/encolado.
  // enqueueForProcessing() DEBE ser idempotente en deliveryId (p.ej. constraint UNIQUE en la cola/
  // tabla + ON CONFLICT DO NOTHING) — sin eso, un reintento tras un 5xx encola el MISMO evento
  // dos veces en vez de deduplicar contra el intento anterior.
  try {
    await enqueueForProcessing({ deliveryId, eventType, payload });
  } catch (err) {
    console.error("[linear-webhook] enqueue failed:", err);
    return res.status(500).end("enqueue failed");
  }
  res.status(200).end();
}
```

Ver implementación completa lista para usar en `scripts/verify-webhook.ts`.

### 4. Framework: Next.js (App Router / Route Handler)

`verifyLinearWebhook()` de `scripts/verify-webhook.ts` es **framework-agnóstica** — recibe
`rawBody: string` + `headers: Record<string, string>`, no objetos `Request`/`Response` de Express.
Eso significa que el ejemplo Next.js de abajo no requiere ningún cambio de código en
`verify-webhook.ts`, solo mostrar cómo conectarlo a un Route Handler:

```typescript
// app/api/webhooks/linear/route.ts — fragmento MÍNIMO, solo para ilustrar el wiring
// framework-agnóstico. NO es fail-closed completo (falta idempotencia durable y el body-cap
// de streaming) — el esqueleto FAIL-CLOSED de verdad, con esos pasos y sin el import roto de
// más abajo, vive en SKILL.md → "Cross-Skill Integration → nextjs-web". Úsalo a ESE como
// referencia real, este bloque es solo para ver que verifyLinearWebhook() no pide objetos
// Request/Response de Express.
import { NextRequest, NextResponse } from "next/server";
// La lógica real vive en .claude/skills/linear-skill/scripts/verify-webhook.ts — pórtala a
// src/lib/linear/verify-webhook.ts para producción; src/ no importa hoy de .claude/.
// import { verifyLinearWebhook } from "@/lib/linear/verify-webhook";

export async function POST(request: NextRequest) {
  const rawBody = await request.text(); // NextRequest.text() ya da el raw body — no hace
                                         // falta express.raw() ni configuración de body-parser
  const headers = Object.fromEntries(request.headers.entries());

  // const result = verifyLinearWebhook(rawBody, headers, process.env.LINEAR_WEBHOOK_SECRET!);
  // if (!result.valid) return NextResponse.json({ error: result.reason }, { status: 401 });

  // NUNCA 200 incondicional — ver el esqueleto fail-closed completo (idempotencia durable,
  // Linear-Delivery obligatorio, body-cap) en SKILL.md antes de escribir un receptor real.
  throw new Error("fragmento ilustrativo — completa la verificación e idempotencia antes de responder 200");
}
```

A diferencia de Express, `NextRequest.text()` da el raw body nativamente. Ver el patrón completo
y fail-closed (idempotencia durable, Linear-Delivery obligatorio, por qué `DeliveryDeduper` es
solo válido single-instance, y por qué NO se importa directamente desde `.claude/`) en
`SKILL.md` → sección "Cross-Skill Integration → nextjs-web".

## Tipos de eventos

Estos son los `Linear-Event` que Linear puede enviar:

### Eventos de entidades

Tabla espejo del enum vivo `WebhookResourceType` (22 valores; introspección viva del schema,
`last_verified: 2026-09-05` — orden alfabético igual que el enum):

| Type | Acciones | Descripción |
|---|---|---|
| `AgentSessionEvent` | created, (otras acciones no-`created`; ver más abajo) | **Para agentes IA** |
| `AppUserNotification` | create | Notificaciones para tu app |
| `Attachment` | create, update, remove | Adjuntos |
| `Comment` | create, update, remove | Comments en issues |
| `Customer` | create, update, remove | Customers (Customer Requests) |
| `CustomerNeed` | create, update, remove | Customer Needs |
| `Cycle` | create, update | Cycles |
| `Document` | create, update, remove | Documents |
| `Initiative` | create, update, remove | Initiatives |
| `InitiativeUpdate` | create, update, remove | Updates de initiatives |
| `Issue` | create, update, remove | Cambios en issues |
| `IssueLabel` | create, update, remove | Cambios de labels |
| `IssueSLA` | `set`, `highRisk`, `breached` | SLAs — acciones propias, NO las genéricas create/update/remove (corregido 2026-09-05) |
| `OAuthAuthorization` | ligadas a autorización/revocación de tokens OAuth | Autorizaciones OAuth — recurso distinto de `OAuthApp` (ver nota abajo) |
| `PermissionChange` | created | Cambios de permisos |
| `Project` | create, update, remove | Cambios en projects |
| `ProjectLabel` | create, update, remove | Labels de project (nuevo en 2026, feature "Releases") |
| `ProjectUpdate` | create, update, remove | Status updates de projects |
| `Reaction` | create, remove | Reacciones emoji |
| `Release` | — (nuevo 2026, sin detalle documentado aún) | Releases |
| `ReleaseNote` | — (nuevo 2026, añadido en `@linear/sdk@85.0.0`) | Notas de release |
| `User` | create, update, remove | Cambios de miembros |

**Notas sobre recursos que YA NO aparecen arriba (verificado contra el SDL vivo, `last_verified: 2026-09-05`)**:

- **`Team` — quitado**: no existe `TeamWebhookPayload` ni `Team` en el enum `WebhookResourceType`. Suscribirte
  con `resourceTypes: ["Team"]` no trae eventos de team — solo sobreviven referencias anidadas a team
  (`TeamChildWebhookPayload`, etc.) dentro de OTROS payloads (p. ej. dentro de un `IssueWebhookPayload`).
- **`OAuthApp` — no es un recurso suscribible por sí solo**: el payload `OAuthAppWebhookPayload` existe pero
  solo dispara la acción `revoked` (de-autorización), no `create`/`remove`. Es un tipo **distinto** de
  `OAuthAuthorization` (el que sí está en el enum de arriba) — no los confundas.
- **`AuditEntry` — no confirmado como suscribible**: `AuditEntryWebhookPayload` existe en la unión
  `DataWebhookPayload` (el tipo de payload de datos), pero `AuditEntry` **no** aparece en el enum
  `WebhookResourceType` que valida `resourceTypes` al crear el webhook. No está claro si Linear lo acepta hoy
  vía `resourceTypes: ["AuditEntry"]` o lo rechaza/ignora — trátalo como no confirmado hasta probarlo con un
  `webhookCreate` real (Enterprise Audit Log Export es una API distinta, no webhook).

### Subscripción selectiva

Al crear el webhook, especifica solo los `resourceTypes` que te interesan. Reduce ruido y procesamiento.

```text
✓ Para un agente IA: ["AgentSessionEvent", "Issue", "Comment"]
✓ Para sync con CI/CD: ["Issue"]
✓ Para dashboard: ["Issue", "Project", "Cycle"]
```

## Reintentos

Linear reintenta webhooks que no responden con 2xx en **5 segundos**:

| Intento | Delay |
|---|---|
| Original | 0 |
| Retry 1 | +1 minuto |
| Retry 2 | +1 hora |
| Retry 3 | +6 horas |

Tras múltiples fallos consecutivos, Linear puede deshabilitar el webhook automáticamente. Revisar Settings → API → Webhooks para ver estado.

**Implicación**: tu handler debe **responder 200 en menos de 5 segundos**. Si tu procesamiento es más lento, encolar y procesar async:

```typescript
app.post("/linear-webhook", async (req, res) => {
  // 1. Validar firma
  if (!validate(req)) return res.status(401).end();

  // 2. Encolar (rápido)
  await queue.add({ payload: req.body });

  // 3. Responder inmediatamente
  res.status(200).end();
});

// Worker separado procesa la cola con todo el tiempo del mundo
queue.process(async (job) => {
  await handlePayload(job.data.payload);
});
```

**Idempotencia**: usa `Linear-Delivery` (UUID único por entrega) para deduplicar. Si recibes el mismo `Linear-Delivery` dos veces (por reintento), no proceses dos veces.

## Webhook agentic — AgentSessionEvent

`AgentSessionEvent` sigue **vigente** (`last_verified: 2026-09-05`, confirmado contra la documentación de
agentes de Linear y contra el schema en vivo — existen `AgentSession`, `AgentSessionStatus`, `AgentActivity` y
las mutations relacionadas).

Si construyes un agente IA usando "Linear for Agents", recibes eventos especiales `AgentSessionEvent`.

**Acciones**: `created` está confirmada explícitamente en la documentación oficial de agentes — se dispara
al @-mencionar el agente o al delegárselo (asignárselo) en una issue. `prompted` (humano envía un nuevo
prompt a una sesión existente) es consistente con el schema — el comentario del campo `promptContext` dice
"Present only for `created` events", lo que implica que existen otras acciones — pero el string literal
`"prompted"` **no se verificó** contra la documentación oficial en esta revisión; trátalo como plausible, no
como confirmado.

**Nota importante**: el webhook **no distingue** si la sesión nació de una @-mención en un comentario o de
una asignación (delegación) directa — confirmado por Linear ("no way to distinguish... via the webhook",
linear/linear#1076, 2026-03-20). Si tu handler necesita esa distinción, el único workaround reportado es
parsear el texto auto-generado del comentario inicial ("This thread is for an agent session with...").

**Payload real** (introspección viva del schema, `AgentSessionEventWebhookPayload`, `last_verified:
2026-09-05`) — **sin wrapper `data`**, los campos son hermanos al nivel raíz del payload:

```json
{
  "action": "created",
  "type": "AgentSessionEvent",
  "agentSession": {
    "id": "<uuid>",
    "issue": { "id": "...", "identifier": "TAL-42", "title": "..." }
  },
  "agentActivity": null,
  "appUserId": "<uuid del app user del agente>",
  "oauthClientId": "<uuid del OAuth client>",
  "previousComments": null,
  "promptContext": "User has asked you to: <full context formatted for LLM>",
  "guidance": [
    { "body": "<markdown de una regla de guidance>", "origin": "workspace" },
    { "body": "<markdown de otra regla, del team>", "origin": "team" }
  ],
  "createdAt": "2026-09-05T12:00:00.000Z",
  "webhookTimestamp": 1746369000000,
  "webhookId": "<uuid>",
  "organizationId": "..."
}
```

Diferencias clave frente a una versión anterior de este documento (corregidas):

- **No hay wrapper `data`** — `agentSession`, `agentActivity`, `promptContext`, `guidance`, etc. van al nivel
  raíz del payload, no anidados bajo `data`.
- **`guidance` es un ARRAY** de `{ body, origin }` — NO un objeto `{ workspace, team }`. Cada elemento trae su
  propio `origin` (de dónde viene esa regla: workspace, team padre, team actual); "la guía del team más
  cercano tiene prioridad más alta" según el propio schema.
- `promptContext` solo está presente en eventos `created` (confirmado por el schema, no solo por prosa).
- `appUserId` y `oauthClientId` son campos nuevos no documentados en versiones previas de este skill.

`promptContext` viene **ya formateado para LLM** — incluye contexto de la issue, comments recientes, project specs si los hay, etc. Es el mejor punto de partida.

**Restricción crítica**: el agente debe responder con `agentActivityCreate` o `agentSessionUpdate` en
**menos de 10 segundos** (los docs de Linear piden emitir un `thought` en ese plazo para acusar recibo).
No confundir con un estado `unresponsive` — ese nombre **no existe** en `AgentSessionStatus` (verificado
por introspección viva, `last_verified: 2026-09-05`; ver `references/01-data-model.md#agent-session-y-agent-activity`
para los 6 estados reales). El estado real más cercano si la sesión queda sin actividad es `stale`. Nota:
los propios docs oficiales de Linear SÍ usan "unresponsive" de forma **informal** en prosa (para describir la
sesión que no acusa recibo a tiempo) — el hecho técnico (el enum no tiene ese miembro) sigue siendo correcto,
pero no es que el concepto no exista en absoluto, solo que no es un estado formal de `AgentSessionStatus`.

Patrón recomendado:

```typescript
// 1. Recibir webhook
async function handleAgentSession(payload) {
  const sessionId = payload.agentSession.id; // sin wrapper "data"

  // 2. Inmediatamente: emitir un "thought" (cumple los 10s)
  await client.agentActivityCreate({
    agentSessionId: sessionId,
    type: "thought",
    body: "Recibido. Analizando la issue..."
  });

  // 3. Procesar real (puede tardar minutos)
  await processIssueWithLLM(payload);
}
```

Detalles completos en `references/06-agents-sdk.md`.

## SDK oficial — `LinearWebhookClient`

`last_verified: 2026-09-05`. Linear publica una alternativa oficial y tipada a la verificación manual de
este documento: la clase `LinearWebhookClient` de `@linear/sdk/webhooks`
(<https://linear.app/developers/sdk-webhooks>). Expone un handler tipado por evento (`.on("Issue", ...)`,
etc.) y las constantes `LINEAR_WEBHOOK_SIGNATURE_HEADER` / `LINEAR_WEBHOOK_TS_FIELD` para quien prefiera
verificar a mano pero sin hardcodear los nombres de header/campo.

**La verificación manual que documenta este skill (`verifySignature` + `isFreshTimestamp` más arriba) sigue
siendo válida** — es el mismo algoritmo (HMAC-SHA256 hex del raw body, comparación timing-safe) que usa el
SDK por debajo. Usar el SDK es una cuestión de conveniencia/tipado, no una corrección de bug en el patrón
manual.

**Contexto de seguridad relevante**: el propio `@linear/sdk` tuvo un bug de replay corregido el 2026-05-12
(linear/linear#1140, PR oficial de itsmingjie, ing. Linear) — el `createHandler()` del SDK priorizaba el
header `linear-timestamp` (**no firmado**) sobre el `webhookTimestamp` del body (**sí firmado**), lo que
permitía "revivir" un body firmado y caducado adjuntándole un header fresco sin firmar. `verify-webhook.ts`
de este skill **nunca fue vulnerable a esta clase de bug**: lee `webhookTimestamp` del body (campo firmado)
para el chequeo anti-replay, nunca el header — que es el comportamiento correcto y el mismo que el SDK
adoptó tras el fix.

## Patrones de procesamiento

### Patrón 1 — Sync de Linear ↔ herramienta interna

```text
Issue.update → webhook → mi servicio → actualizar mi DB
```

Procesar `updatedFrom` para saber qué cambió:

```typescript
const { data, updatedFrom } = payload;
if (updatedFrom?.stateId && data.state.type === "completed") {
  // Issue se acaba de cerrar
  await markAsCompletedInMyDB(data.id);
}
```

### Patrón 2 — Notificación a Slack/Discord/email

```text
Issue.create con label `urgent` → webhook → Slack DM al lead
```

Filtrar antes de actuar:

```typescript
if (
  payload.action === "create" &&
  payload.type === "Issue" &&
  payload.data.priority === 1
) {
  await slackNotify({ ... });
}
```

### Patrón 3 — Generación de reportes

```text
Cycle.update con state=completed → generar reporte de retro automático
```

### Patrón 4 — Agente IA respondiendo a delegations

```text
Issue.update con delegate=mi_agente → webhook → mi agente arranca
```

Pero la forma correcta para agentes es usar **AgentSessionEvent**, no inferir de Issue webhooks.

## Debugging

**Logs de Linear**: Settings → API → Webhooks → click en el webhook → tab "Deliveries". Ves todas las deliveries con request/response.

**Reintento manual**: en la misma página puedes "redeliver" un webhook fallido.

**Test endpoint** desde local:

- Usar `ngrok`, `Cloudflare Tunnel` o `Hookdeck CLI` para exponer localhost.
- En Settings → Webhooks, configurar la URL pública del tunnel.
- Tras debugging, cambiar a producción.

**Headers esenciales para logging**:

```typescript
console.log({
  delivery: req.header("Linear-Delivery"),  // único, para correlacionar
  event: req.header("Linear-Event"),        // tipo de evento
  size: req.body.length                     // tamaño del payload
});
```

**Errores comunes**:

- 401 por firma inválida → casi siempre por body parser que muta el raw body antes de verificar
- 5 segundos timeout → procesamiento síncrono lento, hay que encolar
- Eventos perdidos → revisar lista de `resourceTypes` configurada
- Reintentos infinitos → tu handler está respondiendo 5xx; revisar logs

## Abiertos / no documentados por Linear

`last_verified: 2026-09-05`. Puntos que esta investigación NO pudo confirmar con una fuente oficial ni de
comunidad concluyente — no los des por sentado al diseñar un handler:

- **Orden de entrega**: no se encontró ninguna garantía oficial de que los webhooks lleguen en el mismo orden
  en que ocurrieron los eventos (dos actualizaciones concurrentes al mismo issue podrían entregarse
  fuera de orden). Si tu lógica depende del orden, no confíes en el orden de llegada del HTTP — usa
  `updatedAt`/`createdAt` del payload para reordenar o detectar el evento más reciente.
- **Tamaño máximo de payload**: no localizado en ninguna fuente oficial ni de comunidad. Si procesas payloads
  con adjuntos o descripciones largas, no asumas un tope sin medirlo.
- **El literal `"prompted"` como acción de `AgentSessionEvent`**: no se encontró el string exacto en las
  páginas oficiales consultadas (`developers/agents`, `developers/sdk-webhooks`) — es plausible por el
  schema, pero valídalo empíricamente contra un delivery real antes de depender de ese string en un `switch`.
- **Legibilidad de `Webhook.secret` en queries posteriores**: el campo existe como `String` nullable en el
  tipo `Webhook`, pero no se confirmó si Linear lo enmascara tras la creación (patrón común de "solo se ve
  una vez"). Este documento asume que sí se enmascara — usa `webhookRotateSecret` si lo perdiste — pero no
  está verificado con una llamada real.
