# Linear for Agents

Lee este documento cuando vayas a construir o conectar un agente IA propio a Linear como app user (assignable, mentionable, con sesiones de trabajo visibles), o cuando uses Cyrus / Cursor / Codex como agentes de coding integrados.

## ¿Qué es "Linear for Agents"?

Lanzado el 20 de mayo de 2025. Convierte a los agentes IA en **ciudadanos de primera clase** del workspace:

- Aparecen en menús de assign y @-mention como cualquier user
- Tienen perfil propio (nombre, avatar, descripción)
- Reciben webhooks específicos cuando se les asigna trabajo
- Reportan progreso de manera estructurada (Agent Sessions + Activities)
- **No consumen seat facturable**

Filosofía clave de Linear: los agentes son **delegates**, no responsables. Cuando asignas un issue a un agente, el humano sigue siendo `assignee` (responsable) y el agente entra como `delegate` (contributor).

## Modelo conceptual

```text
Issue
├── assignee: <human>              ← el responsable
├── delegate: <agent app user>      ← el agente trabajando
└── AgentSession (1:N)
    ├── status: pending|active|awaitingInput|complete|error|stale
    └── AgentActivity (1:N)
        ├── thought
        ├── action
        ├── elicitation
        ├── prompt
        ├── response
        └── error
```

## Linear Agent nativo + Coding Sessions

`last_verified: 2026-09-05` (changelog oficial). Antes de decidir "cómo delego esto a un agente de código",
ten en cuenta que Linear tiene su **propia oferta nativa**, sin worktree externo ni servidor propio:

- **Linear Agent** (beta pública, lanzado 24-mar-2026): agente conversacional nativo del workspace,
  disponible en **todos los planes**. Se invoca por chat in-app (Cmd/Ctrl+J), @-mención en comments/Slack/
  Teams, o mobile. Sus **Skills** (ver `AgentSkill` en `references/01-data-model.md#agentskill`) son
  workflows guardados invocables por slash-command o auto-trigger. **Automations y Code Intelligence son
  Business/Enterprise-only**.
- **Coding Sessions** (lanzado 11-jun-2026, confirmado vigente): Linear Agent ejecutando **modelos de código
  configurables desde Settings del workspace** directamente dentro de Linear — sin worktree externo, sin
  infraestructura propia. La lista concreta de modelos disponibles **cambia** y no se lista aquí como hecho
  sellado (no verificable con una URL ancla en esta revisión) — **verifica la lista viva en la UI del
  workspace (Settings → AI / Coding sessions) antes de citarla a alguien**, tal como exige la Regla Absoluta
  20 de este repo. Requisitos confirmados: plan **Basic/Business/Enterprise**, **conexión GitHub con acceso a
  código**, consume **AI credits**. Linear lo usa internamente para resolver ~30% de sus propios bug reports
  entrantes.

Esto compite de frente con Cyrus como forma de delegar issues a Claude Code — evalúalo como **opción
primaria** si el plan del workspace lo soporta, precisamente por no requerir infraestructura externa (ver
tabla "Cuál elegir" más abajo).

## Loops

`last_verified: 2026-09-05`. Lanzado el **20-jul-2026** (<https://linear.app/changelog/2026-07-20-introducing-loops>):
Linear Agent ejecutando trabajo **recurrente**, programado o disparado por evento, en vez de una sesión
puntual iniciada por @-mención o delegación. Plan **Business/Enterprise**; consume **AI credits** (créditos
NO incluidos en el plan, es un consumo aparte). Es la novedad más grande de la capa de agentes desde
Coding Sessions.

**No aplica a esta fábrica**: Loops compite directamente con el rol del Orquestador (`talent-orchestrator`)
y de los coordinadores propios del repo — automatización nativa de Linear haciendo lo que hoy hace
infraestructura propia del repo. Adoptarlo sería una decisión de arquitectura mayor y está sujeta a la
**Regla Absoluta 7** de `CLAUDE.md` (nunca decidir stack/arquitectura mayor sin aprobación explícita del
usuario) — no algo a asumir ni a recomendar sin esa aprobación.

## Agentes ya disponibles — Integrations Directory

`last_verified: 2026-09-05` (corregido tras auditoría de código — la referencia anterior a "Settings → Apps
→ Marketplace" no estaba verificada contra la UI/docs reales, solo heredada del texto previo del skill;
violaba la Regla Absoluta 20 de este repo). Verificado vía `WebFetch` contra dos páginas oficiales de
`linear.app/docs`:

**Cambio de gobernanza (03-sep-2026)**: desde el changelog "Priority Inbox"
(<https://linear.app/changelog/2026-09-03-priority-inbox>), los admins de workspaces en planes de pago deben
**aprobar** las apps OAuth / agentes de terceros antes de que puedan instalarse — instalar un agente del
directorio (Cyrus, Cursor, etc.) ya no es una acción unilateral de cualquier miembro, pasa por aprobación de
admin.

- **Descubrir agentes**: **Integrations Directory** — `https://linear.app/integrations/agents` (no es un
  menú "Marketplace" dentro de la app; es la página/directorio del sitio de Linear). Cita textual de los
  docs: *"Find available agents in the Integrations Directory"*.
- **Gestionar/desinstalar apps y agentes ya instalados**: **Settings → Applications** (según la doc de
  agentes) — cita textual: *"Agents can be uninstalled or managed by admins from **Settings > Applications**
  or suspended from **Settings > Administration > Members**"*. La doc general de integraciones (no
  específica de agentes) usa el path relacionado **Settings → Workspace → Integrations** para instalar/
  gestionar integraciones en general — pueden coexistir ambos paths para superficies algo distintas
  (agentes vs. integraciones); no verificado interactivamente en una sesión viva de la UI (sin screenshot ni
  navegación verbal disponibles en esta sesión), solo contra la documentación oficial citada — si vas a
  instruir esto a un usuario, confírmalo con captura de pantalla o navegación verbal primero, tal como exige
  la Regla Absoluta 20.
- El marketplace de agentes en sí cambia con frecuencia — **verifica la lista viva en
  `linear.app/integrations/agents`** antes de decidir, no confíes solo en la tabla de abajo. Directorio con
  **25 entradas a 2026-09-05** (<https://linear.app/integrations/agents>) — creció frente a revisiones
  anteriores del skill; la tabla de abajo es solo una muestra, no el listado completo:

| Agente | Tipo | Notas |
|---|---|---|
| **Cursor** | Coding | Cloud agents que abren PRs |
| **GitHub Copilot coding agent** | Coding | Integración nativa |
| **OpenAI Codex** | Coding | Requiere ChatGPT pago + GitHub |
| **Devin** | Coding autonomous | Cognition Labs |
| **Factory (Droids)** | Coding | Multi-agente |
| **Sentry Seer** | Debugging | Error analysis |
| **Charlie** | PR review | TypeScript especialista |
| **cto.new** | Coding | Vibe-coding |
| **Cyrus** | Coding (Claude Code) | Open source, BYOK |
| **Pixelesq, Ranger, Reflag, Stilla, Panaptico** | Variados | Nichos específicos |

**Nota importante (corregida, `last_verified: 2026-07-17`)**: hay que distinguir dos cosas distintas que se
prestan a confusión desde que existen Coding Sessions:

- **Linear ejecuta Claude Code internamente** como parte de "Coding Sessions" (ver sección de arriba) — esto
  es una capacidad nativa de la plataforma Linear, no un "agente" instalado desde el marketplace.
- **Anthropic NO tiene un agente propio registrado como app/integración en el marketplace de Linear** — eso
  sigue sin existir. Lo que sí existe es que la plataforma Linear, por debajo, invoca Claude Code como motor
  de ejecución cuando usas Coding Sessions.

Para usar Claude Code como forma de trabajar sobre issues de Linear hay ahora **cuatro** opciones (antes tres):

0. **Linear Agent nativo + Coding Sessions** — sin infraestructura externa, requiere plan Basic+ y GitHub
   conectado (ver sección de arriba)
1. **Cyrus** (open source) — convierte Claude Code en agente assignable de Linear con worktree externo
2. **Construir tu propio agente** con OAuth y este SDK (o con Vercel Eve, ver Opción 2 más abajo)
3. **Usar Claude Code interactivamente por la API GraphQL directa** (lo que hacemos en este skill — token por carril, NO agente assignable, pero funciona perfecto para uso interactivo)

## Opción 1 — Cyrus (alternativa cuando se requiere worktree externo o control fino)

**Repositorio**: <https://github.com/cyrusagents/cyrus>

**Qué hace**:

- Cada issue asignada al agente Cyrus crea un **git worktree aislado** (`worktrees/TAL-42/`)
- Corre Claude Code en ese worktree
- Transmite *thoughts* y *actions* como Agent Activities al issue de Linear
- Abre PR cuando termina

**Modelo BYOK** (bring your own keys):

- Usa tu cuenta Anthropic Pro/Max o API key
- No paga por usuario; el coste es Anthropic + el del runner

**Despliegue**:

- **Managed**: `app.atcyrus.com` — registras y conectas
- **Self-hosted**: clonar repo, configurar `.env`, levantar el server. Para webhooks locales, usar Hookdeck CLI o Cloudflare Tunnel.

**Configuración recomendada para Talent Engine**:

1. Instalar Cyrus desde Settings → Apps → Cyrus
2. Conectar tu cuenta Anthropic (BYOK)
3. Conectar el repo de GitHub que mantenga el equipo
4. Configurar **workflows seleccionables por labels**, siempre con labels que EXISTAN
   en el workspace (hoy el selector vivo es `actor/ai` — ver el recibo
   `examples/label-taxonomy.receipt.json`):
   - Label `actor/ai` → workflow estándar de delegación
   - Si el equipo quiere workflows diferenciados (planificación sola, bugs, features),
     crear PRIMERO esos labels en Linear, re-verificar el recibo
     (`scripts/check-taxonomy-parity.sh --live`) y solo entonces referenciarlos aquí y
     en `talent-engine-config.json`
5. Configurar `CLAUDE.md` global en `~/.cyrus/CLAUDE.md` con convenciones del equipo (ver `examples/claude-md-template.md`)
6. Configurar **agent guidance** en Linear — ruta de UI **NO reconfirmada el 2026-09-05**: el path
   "Settings → Agents → Cyrus → Additional guidance" que citaba una versión anterior de este documento no
   se pudo verificar contra la UI viva ni contra documentación que lo confirme literalmente para un agente
   de terceros instalado. Lo que sí está confirmado y vigente es la navegación del **Linear Agent nativo**:
   `Settings → AI` (guía a nivel workspace) y `Settings → Account → Agent personalization` (guía personal)
   — <https://linear.app/docs/linear-agent>. Si necesitas configurar guidance específicamente para un agente
   de terceros como Cyrus (no el nativo), **verifica primero en la UI** (captura de pantalla o navegación
   verbal) antes de instruir un path a nadie, tal como exige la Regla Absoluta 20 de este repo.

**Cómo lo usas**:

```text
1. Triage: identificas una issue candidata para IA
2. La asignas como delegate a Cyrus, label actor/ai
3. Cyrus recibe webhook AgentSessionEvent
4. Crea worktree, corre Claude Code, comenta progreso en la issue
5. Termina con PR open en GitHub
6. Tú revisas, aprueba, merge → workflow automation cierra issue
```

## Opción 2 — Construir tu propio agente

Si quieres más control (ej: tu propio agente que no es coding, sino algo específico tuyo).

**Framework alternativo — Vercel "Eve"** (`last_verified: 2026-07-17`, soporte añadido 18-jun-2026):
framework open-source TypeScript-native para construir agentes (Vercel Ship London 2026, preview público).
Modela un agente como un directorio de archivos mapeados a capacidades, y se conecta a Linear (delegar
issues / @-mención) sin tener que montar el esqueleto OAuth+webhook de cero. Alternativa moderna a
implementar el flujo manual descrito abajo si prefieres partir de un framework en vez de un handler propio.

`last_verified: 2026-09-05`. `linear.app/developers/agents` (la guía para construir un agente OAuth propio)
sigue marcada **"Developer Preview — Functionality and Agent APIs may change before general availability"**
pese a llevar más de un año desde el lanzamiento de mayo 2025 — trata cualquier integración de esta opción
como sujeta a riesgo de breaking changes, no como API estable.

### Pasos de alto nivel

1. **Crear OAuth app** en Settings → API → OAuth applications
   - Redirect URI: tu callback
   - Scopes: `read`, `write`, `app:assignable`, `app:mentionable`
2. **Configurar webhooks** con resourceType `AgentSessionEvent`
3. **Implementar OAuth flow** (`actor=app` para que las acciones aparezcan como del agente) — **gotcha
   comunitario reproducible**: el exchange OAuth con `actor=app` devuelve **503** en el primer intento en
   varios integradores independientes (n8n-io/n8n#16250 y #19599, 4+ reportes; con `actor=user` funciona sin
   problema). Además, el `authorization_code` puede quedar **consumido internamente por Linear aunque el
   cliente nunca vio éxito** (linear/linear#637): un reintento del exchange tras el 503 puede fallar con
   `invalid_grant: authorization code is invalid` en vez de reintentar limpio. **No reintentes el exchange a
   ciegas** — un `authorization_code` es de un solo uso; si el primer intento con `actor=app` devuelve 503,
   trátalo como un fallo a diagnosticar (¿el code ya se consumió?), no como algo que un retry simple arregla.
4. **Listener de webhooks**: handle `AgentSessionEvent` con action `created` y `prompted`
5. **Responder en <10s** con un primer `agentActivityCreate` (al menos un thought)
6. **Procesar el trabajo real** y emitir actividades incrementales
7. **Cerrar la session** con `agentActivityCreate` type=`response`

### Esqueleto de handler

Forma del payload corregida (`last_verified: 2026-09-05`, ver detalle completo en
`references/05-webhooks.md#webhook-agentic--agentsessionevent`): **sin wrapper `data`**, y `guidance` es un
**array** de `{ body, origin }`, no un objeto `{ workspace, team }`.

```typescript
import { LinearWebhookClient } from "@linear/sdk/webhooks";
import { LinearClient } from "@linear/sdk";

const webhookClient = new LinearWebhookClient(process.env.LINEAR_WEBHOOK_SECRET!);

app.post("/agent-webhook", express.raw({ type: "application/json" }), async (req, res) => {
  // 1. Verificar: la firma cubre el body crudo; el timestamp anti-replay se toma del campo
  //    firmado `webhookTimestamp` del body, NUNCA del header `Linear-Timestamp` (no firmado;
  //    el SDK corrigió ese bypass en 2026-05, linear/linear#1140).
  const signature = req.header("Linear-Signature");
  const payload = JSON.parse(req.body.toString());
  if (!webhookClient.verify(req.body, signature!, payload.webhookTimestamp)) {
    return res.status(401).end();
  }

  if (payload.type !== "AgentSessionEvent") {
    return res.status(200).end();
  }

  // 2. Responder rápido
  res.status(200).end();

  // 3. Procesar async
  await handleAgentSession(payload);
});

async function handleAgentSession(payload: any) {
  const sessionId = payload.agentSession.id; // sin wrapper "data"
  const agentClient = await getAgentClient(payload.organizationId);

  // 3a. Acuse rápido (cumple los 10s)
  await agentClient.agentActivityCreate({
    agentSessionId: sessionId,
    type: "thought",
    body: "Empezando a analizar la issue..."
  });

  // 3b. Trabajo real
  const issue = payload.agentSession.issue;
  // `promptContext` y `previousComments` SOLO llegan en la accion "created" — verificado contra
  // @linear/sdk 94.0.0, tipo `AgentSessionEventWebhookPayload` en dist/index-CDNcaWDM.d.mts, que
  // lo documenta literalmente: «Present only for `created` events». En cualquier otra accion
  // valen undefined, asi que un agente que los use sin comprobarlo trabaja con contexto vacio en
  // vez de fallar: la sesion contesta, pero sin haber leido la peticion.
  //
  // Y el conjunto de acciones NO se puede verificar contra el paquete: en ese mismo tipo,
  // `action` es `Scalars["String"]` --texto libre, sin union de literales-- y el termino
  // "prompted" no aparece ni una vez en todo @linear/sdk 94.0.0. Distinguir acciones por
  // nombre es contrato de la API, no del SDK: comprobalo contra la documentacion de webhooks
  // vigente, no contra los tipos, que aqui no lo acreditan.
  const promptContext = payload.promptContext;
  const previousComments = payload.previousComments ?? []; // idem: solo en "created"
  if (!promptContext) {
    // No es "created": el prompt hay que reconstruirlo del hilo, no darlo por vacio.
    return await atenderSinPromptContext(payload);
  }
  const guidance = payload.guidance ?? []; // array [{ body, origin }], no { workspace, team }

  const result = await myLLM({
    system: guidance.map((rule: { body: string }) => rule.body).join("\n\n"),
    user: promptContext
  });

  // 3c. Reportar progreso intermedio (opcional)
  await agentClient.agentActivityCreate({
    agentSessionId: sessionId,
    type: "action",
    body: `Ejecutando: ${result.actionDescription}`
  });

  // 3d. Si hace falta input humano
  if (result.needsClarification) {
    await agentClient.agentActivityCreate({
      agentSessionId: sessionId,
      type: "elicitation",
      body: `¿Puedes confirmar X?`
    });
    return;  // session entra en awaitingInput
  }

  // 3e. Respuesta final
  await agentClient.agentActivityCreate({
    agentSessionId: sessionId,
    type: "response",
    body: result.summary
  });

  // 3f. Opcional: enlazar a tu dashboard
  await agentClient.agentSessionUpdate(sessionId, {
    externalUrls: [{ label: "Run details", url: `https://my-dashboard.com/run/${runId}` }]
  });
}
```

### Tipos de Agent Activity

`AgentActivityType` tiene **6** miembros (verificado por introspección viva, `last_verified: 2026-09-05`):

- `thought` — razonamiento visible (público en la UI). Ej: "El error parece estar en el cálculo de impuestos"
- `action` — acción ejecutada con su resultado. Ej: "Ejecutando tests... 24/25 pass"
- `elicitation` — pidiendo input al humano. Pone la session en estado `awaitingInput`
- `prompt` — el prompt que recibió (Linear lo pone automáticamente)
- `response` — respuesta final del agente (cierra la session si no hay más actividad)
- `error` — el agente reportó un error durante la ejecución

### Mutaciones y queries `Agent*` vivas no documentadas antes en este skill

`last_verified: 2026-09-05` (introspección viva del schema). Existen en el schema actual y no estaban
cubiertas por revisiones previas de este documento:

- **Mutations**: `agentSessionCreateOnComment`, `agentSessionCreateOnIssue` (crear una sesión explícitamente
  desde un comment/issue, en vez de solo vía @-mención/delegación), `agentSessionRestartWithDefaultModel`
  (añadida en `93.0.0`), `agentActivityCreatePrompt`, `agentActivityDeleteQueued`, `agentActivitySendQueued`
  (gestión de actividades en cola), `agentSkillCreate`/`agentSkillUpdate`/`agentSkillDelete` (gestión de
  `AgentSkill`, ver `references/01-data-model.md#agentskill`).
- **Queries**: `agentSessionSandbox` (info del sandbox de ejecución de una sesión), `delegatedIssues` (issues
  delegadas a un agente).
- **Modelo `Diff` sustituye a `AgentSession.workspaceDiff*`**: `AgentSession.workspaceDiff` y
  `workspaceDiffFiles` están **deprecados desde `91.0.0`** ("Use the session's Diff model instead") a favor
  del tipo `Diff` de primera clase (`Query.diff`, `Diff.files`) — si vas a leer el diff de trabajo de una
  sesión, usa `Diff`, no los campos deprecados de `workspaceDiff*`.

Ninguna de estas mutations/queries aplica a un flujo token-only sin OAuth app — solo tienen sentido para un
app user autenticado como agente (misma razón por la que `agentSessionRestartWithDefaultModel` y las
queries de sandbox no aparecen en el resto de este skill).

### Estados de Agent Session

Linear gestiona el estado automáticamente según la última actividad:

| Estado | Cuándo |
|---|---|
| `pending` | Session creada, agente aún no respondió |
| `active` | Agente trabajando (último activity reciente) |
| `awaitingInput` | Última activity fue `elicitation` |
| `complete` | Última activity fue `response` y no hubo más prompts |
| `error` | El agente reportó error o lleva mucho tiempo sin activity |
| `stale` | La sesión quedó sin activity por más del threshold |

**Nota — "unresponsive"**: los docs oficiales de agentes usan informalmente el término "unresponsive" en
prosa para describir la sesión que no acusa recibo a tiempo (<10s) — pero **no existe** un miembro
`unresponsive` en el enum formal `AgentSessionStatus` (6 miembros, tabla de arriba); los estados reales más
cercanos son `stale`/`error`. El hecho técnico (el enum no lo tiene) es correcto; el matiz es que el
concepto sí existe informalmente en la documentación, no que esté ausente por completo.

### Agent Guidance — el "system prompt" del workspace

Se configura como Markdown que Linear pasa automáticamente al agente en cada session vía el webhook
`AgentSessionEvent` — campo `guidance`, que es un **array** de `{ body, origin }` (una regla por
`workspace`/team padre/team actual, ver `references/05-webhooks.md#webhook-agentic--agentsessionevent`),
**no** un objeto plano `{ workspace, team }`. La ruta de UI exacta para escribir esta guidance a nivel
workspace/team para un agente OAuth propio **no está reconfirmada el 2026-09-05** — verifícala en la UI
(regla 20) antes de instruir un path; lo único confirmado hoy es la ruta del Linear Agent **nativo**
(`Settings → AI` / `Settings → Account → Agent personalization`, ver la nota de Cyrus más arriba).

Útil para codificar:

- Repositorio a usar para cada tipo de cambio
- Convenciones de commits/PRs
- Cómo referenciar issues
- Proceso de review esperado
- Lenguaje y tono

Ver `examples/agent-guidance.md` para una plantilla específica para Talent Engine.

### Agent Skills — workspace-wide vs. herencia parent-team → sub-team

`last_verified: 2026-07-20` (corregido tras auditoría de código — la primera redacción inventaba una
gobernanza de "compartir arbitrariamente entre teams" que el schema no soporta). Lanzado 2026-06-04. Las
skills de Linear Agent (entidad `AgentSkill`, ver `references/01-data-model.md#agentskill`) tienen DOS ejes
de visibilidad **verificados por introspección**, distintos entre sí:

1. **`shared: Boolean!`** — visibilidad **personal vs. todo-el-workspace** ("shared with everyone in the
   workspace" vs. "only the owner can use the skill"). **No es settable** vía `agentSkillCreate`/
   `agentSkillUpdate` (no está en esos inputs) — es derivado, mecanismo exacto no confirmado.
2. **`inheritedFrom`** — una skill de un **sub-team puede heredar de la skill de su parent-team**
   (`Team.parent`/`Team.children`), NO de un team arbitrario cualquiera del workspace.

Si varios teams de Talent Network quieren converger en convenciones de agente comunes (cómo referenciar
issues, tono, proceso de review) sin duplicar guidance, la vía verificada es la jerarquía **parent-team →
sub-team** — no "marcar `shared: true` para que cualquier otro team la herede", que no es lo que el schema
implementa.

### Nota — endpoints del MCP server y Enterprise-Managed Authorization (Okta)

`last_verified: 2026-09-05`. Este repositorio **no usa MCP** (token-only, ver `references/02-mcp-tools.md`
y CLAUDE.md); esta nota es informativa por si se reevalúa la decisión en el futuro.

- **Transporte primario**: `https://mcp.linear.app/mcp` (Streamable HTTP).
- **Solo-lectura dedicado**: `https://mcp.linear.app/mcp/readonly`.
- **SSE — deprecado, NO retirado**: `https://mcp.linear.app/sse` sigue funcionando como **fallback marcado
  "deprecated fallback for clients that do not support Streamable HTTP"** — no fue eliminado. Si en algún
  momento se reevalúa MCP, no asumas que este endpoint desapareció.

Enterprise-Managed Authorization es una extensión del protocolo MCP (no específica de Linear) que se
estabilizó a nivel de ecosistema **~2026-06-18**; Linear está entre los servidores MCP que la soportan
(junto a Asana, Atlassian, Canva, Figma, Granola, Supabase). La página de docs de Linear que cubre la
configuración con Okta (`linear.app/docs/mcp`) **no lleva fecha propia** — no hay changelog dedicado de
Linear para esta feature. Los administradores Okta pueden gestionar centralizadamente el acceso al servidor
MCP de Linear en Claude. **No aplica hoy a Talent Network** (equipo pequeño, sin SSO empresarial) —
relevante solo si el workspace crece a una organización con Okta/SSO centralizado. Nota informativa; este
repo sigue siendo token-only, NO MCP (ver `references/02-mcp-tools.md`).

## Opción 3 — Claude Code interactivo + token/GraphQL directo

Esta es la opción que el skill por defecto cubre (token-only, NO MCP). **No** convierte Claude Code en agente assignable de Linear. Pero es:

- ✅ Más simple (no requiere registrar OAuth app ni servidor MCP)
- ✅ Más barato (no requiere infra adicional)
- ✅ Suficiente para 95% de los casos cuando un humano está conduciendo

**Cómo se ve en uso**:

```text
Tú (en Claude Code): "Ve a Linear, busca las issues de esta semana del project X,
                      empieza con la más urgente, abre branch, etc."

Claude Code:
1. Query GraphQL issues(filter: {...}) con LINEAR_API_KEY
2. Lee la issue elegida
3. Crea branch local con el branchName de Linear
4. Implementa
5. Mutation issueUpdate para mover a "In Progress"
6. Mutation commentCreate para comentar progreso
7. Abre PR
8. Linear automation lo lleva a "In Review" automáticamente
```

**No genera AgentSession** porque no es app user. Pero sí registra los cambios bajo tu user humano. Perfecto para sesiones interactivas.

## Cuál elegir

`last_verified: 2026-07-17` — reordenada para reflejar que Linear ahora ofrece una opción nativa sin
infraestructura externa:

| Caso | Opción |
|---|---|
| Quiero delegar issues a Claude Code/Codex nativamente, sin infra propia (plan Basic+, GitHub conectado) | **Linear Agent nativo + Coding Sessions** |
| Necesito worktree externo, control fino del entorno de ejecución, o el plan no soporta Coding Sessions | **Cyrus** |
| Tengo un agente custom (no coding) que quiero integrar | **OAuth app propia** (o framework **Vercel Eve**) |
| Trabajo interactivamente y solo quiero operar Linear desde Claude Code | **Token/GraphQL directo (default del skill)** |
| Quiero que Cursor/Codex agarren issues asignadas desde el marketplace | Instalar **Cursor / Codex** desde marketplace (verificar disponibilidad viva) |

## Combinaciones

Las opciones no son excluyentes. Talent Engine puede tener:

- **Token/GraphQL directo** en Claude Code de cada developer (uso interactivo, `LINEAR_API_KEY` por carril)
- **Linear Agent nativo + Coding Sessions** para delegations que no necesiten worktree externo (si el plan lo soporta)
- **Cyrus** registrado como agent para delegations async que sí necesiten worktree externo (via labels)
- **Cursor** registrado como otro agente; para enrutarle issues por label, crear antes
  ese label de selección en Linear (hoy no existe ninguno específico por agente — el
  recibo solo registra `actor/ai`) y recogerlo en la autoridad y el config

Cada agente compite limpiamente cuando cada uno va con un label distinto — siempre
labels que existan en el recibo verificado.

## Referencias adicionales

- Documentación oficial: <https://linear.app/developers/agents>
- Agent Interaction SDK overview: <https://linear.app/now/our-approach-to-building-the-agent-interaction-sdk>
- Cyrus repo: <https://github.com/cyrusagents/cyrus>
- Linear for Agents marketplace: <https://linear.app/integrations/agents>
- Introducing Linear Agent (24-mar-2026): <https://linear.app/changelog/2026-03-24-introducing-linear-agent>
- Coding sessions in Linear (11-jun-2026): <https://linear.app/changelog/2026-06-11-coding-sessions>
- Now Linear writes the code, too: <https://linear.app/now/coding-sessions-for-linear-agent>
- Vercel "Eve" agent framework (18-jun-2026): <https://vercel.com/blog/introducing-eve>
