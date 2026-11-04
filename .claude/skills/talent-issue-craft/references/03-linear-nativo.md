# Linear Nativo — Mapeo, Patrones GraphQL y Flujo de Plantillas

Cómo el sistema de tipos/plantillas aterriza en capacidades NATIVAS de Linear. Todo claim verificado contra el schema GraphQL vivo y la documentación oficial (`last_verified: 2026-07-20`). API: `POST https://api.linear.app/graphql`, header `Authorization: <API key personal>` (sin "Bearer" para keys personales).

## Table of Contents

1. [Mapeo campo → capacidad nativa](#1-mapeo-campo--capacidad-nativa)
2. [Flujo de creación de issues con las plantillas (v1)](#2-flujo-de-creación-de-issues-con-las-plantillas-v1)
3. [Patrones GraphQL verificados](#3-patrones-graphql-verificados)
4. [Solicitudes de cliente (Customer Requests)](#4-solicitudes-de-cliente-customer-requests)
5. [Etiquetas y vistas (patrón documentado, sin código)](#5-etiquetas-y-vistas-patrón-documentado-sin-código)
6. [Qué consulta la auditoría remota (audit-issue --issue)](#6-qué-consulta-la-auditoría-remota-audit-issue---issue)
7. [Gotchas & Cross-References](#7-gotchas--cross-references)

---

## 1. Mapeo campo → capacidad nativa

| Elemento del sistema | Capacidad de Linear | Regla del skill |
|---|---|---|
| Tipo de tarea (9) + variante | **Marcador `issue-craft:v1`** en el body (autoridad) + Template nativo por tipo (conveniencia) | El marcador manda; las etiquetas de tipo del equipo son cross-check 🟡 |
| Madurez `placeholder` | Estado de tipo `backlog` + sin estimate + prioridad None | Placeholder vive en Backlog; prohibido detalle caro |
| Madurez `despachable` | Estado de tipo `unstarted` (p. ej. "Todo") + estimate + prioridad [+ ciclo si el equipo los usa] | La transición Backlog→unstarted ES el gate de despachabilidad |
| Decisión diferida que "Bloquea TODO" | Issue-decisión asignada a quien decide + relación **`blockedBy`** | La decisión tiene dueño que la empuja — nunca bloqueo en prosa |
| Dependencias/precedencia | **Issue relations** `blocks`/`blockedBy` | El gate rechaza bloqueos ACTIVOS (bloqueador no completado/cancelado) |
| Duplicados | Relation `duplicateOf` + estado de tipo `canceled` | El dedupe pre-creación busca título + descripción + comentarios |
| Origen: propuesta de usuario | **Customer Request** vinculada a la issue (§4) | La propuesta cruda vive como solicitud; la issue nace convertida al tipo |
| Origen: PR/hallazgo/decisión | **Attachment** (URL) — no solo texto | Los PR se auto-adjuntan con las magic words del tracker |
| Descomposición | **Sub-issues** (`parentId`) | Estimate sobre el tope del perfil → sub-issues |
| Tamaño | **Estimate** (escala del equipo) | Rangos por tipo en cada plantilla |
| Urgencia | **Priority** nativa (0 None · 1 Urgent · 2 High · 3 Normal · 4 Low) | `fix/sev1` → Urgent (+ SLA si el equipo los usa); nunca duplicar prioridad con etiquetas |
| Superficie/riesgo | Grupos de etiquetas del workspace (p. ej. `area/*`, `risk/*`) | `risk` alto = rúbricas reforzadas (variante `seguridad`, GO explícito) |
| Ejecutor agéntico | **Assignee humano + Delegate agente** (Linear for Agents) | El humano conserva la responsabilidad; el delegate habilita filtros e insights por agente |
| Rúbricas canónicas largas | **Documents** de Linear (o los references de este skill) | La issue referencia, no repite |
| Cierre | Magic words `closes/fixes/resolves <ID>` en el PR | Excepción tipada: `contenido-datos` cierra manual con evidencia |
| Título → rama | `branchName` autogenerado (`gitBranchFormat` del workspace/equipo) | La convención de título alimenta la rama |

Fuentes: docs oficiales de Linear — issues/relations (`linear.app/docs`), API GraphQL (`linear.app/developers`), plantillas (`linear.app/docs/issue-templates`), solicitudes (`linear.app/docs/customer-requests`). `last_verified: 2026-07-20`.

## 2. Flujo de creación de issues con las plantillas (v1)

```text
   ¿Qué tipo/variante? ──── tabla de routing de SKILL.md (14 combinaciones)
            │
            ▼
   Copiar templates/NN-<tipo>.md  →  rellenar  →  body de la issue
            │                                    (el marcador ya viene pre-relleno;
            │                                     ajustar variant= según trigger)
            ▼
   Crear la issue por API (§3.1) con: estimate + prioridad + etiquetas + proyecto
            │
            ▼
   Pre-check de autoría:  audit-issue --file <borrador.md>   (body-only)
            │
            ▼
   Gate de despachabilidad (peldaño del perfil del repo):
   audit-issue --issue <ID>  →  marker + eligible=true + exit 0
```

**Templates nativos de Linear**: Linear soporta plantillas de issue por equipo/workspace con valores por defecto. Hay DOS caminos válidos:

- **Camino A — aprovisionamiento por API** (shape de `templateData` verificado por sonda round-trip; contrato congelado en §3.6): la acción `provision-templates` del helper genera un payload `templateCreate` por cada `templates/0N-*.md` (9 en total, uno por tipo). **Ámbito**: exactamente uno de `--team <key>` (Templates del equipo) o `--global` (Templates de workspace SIN `teamId`, visibles en TODOS los equipos — útil en workspaces multi-equipo para no duplicar 9×N). El contract-check vincula **archivo↔tipo↔marcador**: exige el conjunto canónico EXACTO de 9 archivos (`01-feat` … `09-contenido-datos`; faltante o extra → fail), que el marcador del cuerpo coincida con el tipo del archivo y que nazca `madurez=despachable`. `--dry-run` es el DEFAULT — imprime los payloads GraphQL exactos y corre el contract-check contra el shape congelado SIN red ni credenciales; `--apply` es la ÚNICA vía de escritura: exige credenciales, omite (no pisa) templates ya existentes con el mismo nombre en el MISMO ámbito, **nunca reintenta un `templateCreate` fallido** (mutación no idempotente: ante un fallo ambiguo de transporte deja salida parcial y la SIGUIENTE ejecución reconcilia vía censo+omisión), y queda sujeto a la política de mutación del repo que lo use (GO del responsable antes de aplicar).
- **Camino B — manual UI (oficial)**: crear cada plantilla en **Workspace settings → Templates** (o **Team settings → Templates**) pegando el contenido de `templates/NN-*.md` (fuente: `linear.app/docs/issue-templates`, `last_verified: 2026-07-20`). Sigue vigente para equipos que prefieren no otorgar escritura por API.

## 3. Patrones GraphQL verificados

Todas las mutations/queries existen en el schema vivo (`last_verified: 2026-07-20`). La API key se pasa por header; NUNCA en argv ni en logs.

### 3.1 Crear issue desde plantilla rellenada

```graphql
mutation CreateIssue($i: IssueCreateInput!) {
  issueCreate(input: $i) { success issue { id identifier url } }
}
```

```json
{ "i": { "teamId": "<uuid>", "title": "Imperativo qué (dónde)",
  "description": "<body completo con el marcador issue-craft:v1 en la primera línea>",
  "stateId": "<estado>", "projectId": "<proyecto>", "assigneeId": "<humano>",
  "labelIds": ["<etiquetas>"], "estimate": 3, "priority": 2 } }
```

### 3.2 Dedupe pre-creación (título + descripción + comentarios)

```graphql
query Dedupe($q: String!) {
  issues(first: 15, filter: { or: [
    { title:       { containsIgnoreCase: $q } }
    { description: { containsIgnoreCase: $q } }
    { comments: { body: { containsIgnoreCase: $q } } }
  ]}) { nodes { identifier title state { name } url } }
}
```

### 3.3 Relaciones (bloqueos y duplicados)

```graphql
mutation Rel($i: IssueRelationCreateInput!) {
  issueRelationCreate(input: $i) { success issueRelation { id type } }
}
```

`type` ∈ `blocks` | `related` | `duplicate`. Para "B bloqueada por A": `{ issueId: <A>, relatedIssueId: <B>, type: "blocks" }`.

### 3.4 Actualizar etiquetas — SIEMPRE el array completo

`issueUpdate.labelIds` REEMPLAZA el array: no existe "añadir etiqueta". Leer las actuales, unir, reenviar todas — si no, se pierden las existentes.

### 3.5 Comentar (decisiones, evidencias de cierre manual)

```graphql
mutation Comment($i: CommentCreateInput!) {
  commentCreate(input: $i) { success comment { id url } }
}
```

### 3.6 Templates nativos — shape congelado de `templateData`

Verificado con una sonda reversible `templateCreate → lectura → templateDelete` sobre un workspace real, con censo de templates pre/post idéntico (`last_verified: 2026-07-20`, sonda round-trip).

**Escritura** — lo que `templateCreate` ACEPTA:

```graphql
mutation ProvisionTemplate($input: TemplateCreateInput!) {
  templateCreate(input: $input) { success template { id name } }
}
```

```json
{ "input": {
  "type": "issue",
  "teamId": "<UUID del equipo>",
  "name": "issue-craft: feat",
  "description": "Plantilla 01-feat · variantes: none | db",
  "templateData": {
    "title": "{Imperativo} {qué} ({dónde})",
    "description": "<!-- issue-craft:v1 type=feat variant=none madurez=despachable -->\n…cuerpo markdown completo de la plantilla…"
  },
  "sortOrder": 1 } }
```

- `templateData` se envía como **objeto JSON** con EXACTAMENTE dos claves: `title` (string) y `description` (**markdown plano** — Linear lo interpreta server-side y lo convierte a rich-text).
- `teamId` DEBE ser **UUID**: la validación real rechaza el key del equipo (`teamId must be a UUID`) aunque la introspección describa el campo como "identifier or key of the team" — resolverlo antes con `teams(filter: { key: { eq: $key } }) { nodes { id } }`. Sin `teamId`, el template queda GLOBAL del workspace.
- La primera línea del `templateData.description` DEBE ser el marcador `issue-craft:v1` del tipo: así toda issue creada desde el template nace con la autoridad de clasificación puesta.

**Lectura** — lo que el API DEVUELVE: `templateData` llega como **string JSON-encoded** de `{ "title", "descriptionData": { "type": "doc", … } }`. El markdown enviado en `description` fue normalizado a documento rich-text (headings/párrafos con IDs generados por el servidor) y la clave `description` NO sobrevive a la lectura.

**Regla del contract-test**: el round-trip es **SEMÁNTICO, no textual** — validar los payloads contra el contrato de ESCRITURA (claves exactas de `templateData`, tipos, marcador en la primera línea del cuerpo, `type: "issue"`, nombre no vacío); NUNCA hacer diff textual enviado↔leído.

**Reversión**: `templateDelete(id) { success }` — existe y funciona; es lo que hace reversible la sonda.

## 4. Solicitudes de cliente (Customer Requests)

**Disponibles en todos los planes actuales de Linear** (lo que varía por plan son ciertas integraciones de sincronización) — fuente oficial: `linear.app/docs/customer-requests`, `last_verified: 2026-07-20`. Patrón para el origen "propuesta de usuario":

```graphql
mutation Need($i: CustomerNeedCreateInput!) {
  customerNeedCreate(input: $i) { success need { id } }
}
```

```json
{ "i": { "customerId": "<cliente>", "body": "Propuesta cruda del usuario",
  "issueId": "<issue de desarrollo ya convertida al tipo>", "priority": 1 } }
```

Notas verificadas: el payload expone `need` (no `customerNeed`); la prioridad de la solicitud usa SU escala (0 = sin prioridad, 1 = importante), no la 0-4 de issues. **Probe suave** para tokens restringidos por permisos (las API keys de Linear pueden limitarse por permisos y equipos — `linear.app/docs/api-and-webhooks`): si `customers(first: 1)` responde con error de autorización, registrar la solicitud como attachment + sección de origen en el body, y seguir — la doctrina de origen no depende de esta capacidad.

## 5. Etiquetas y vistas (patrón documentado, sin código)

Operación única de minutos en la UI — este skill NO la automatiza (decisión anti-sobreingeniería):

- **Etiquetas**: crear grupos de workspace para superficie/riesgo si no existen (p. ej. `area/*`, `risk/*`). Las de "tipo" son opcionales: el marcador es la autoridad.
- **Vistas guardadas** sugeridas: "Despachables" (estado unstarted + sin bloqueos activos), "Decisión pendiente" (issues-decisión abiertas), "Rebotadas/Re-entrada" (la marca que el equipo use para re-trabajo).
- Patrón API equivalente (si alguien lo quiere): `issueLabelCreate` y `customViewCreate` existen en el schema (`last_verified: 2026-07-20`); el shape de filtros de vistas es el de `IssueFilter`.

## 6. Qué consulta la auditoría remota (audit-issue --issue)

La corrida remota exige EVIDENCIA COMPLETA. El helper consulta exactamente esto, y si algo falta o el API responde parcial → `operational_gate_eligible=false` + exit ≠ 0:

```graphql
query Audit($id: String!) {
  issue(id: $id) {
    identifier title description
    estimate priority
    state { name type }
    project { name } projectMilestone { name }
    labels { nodes { name } }
    relations        { nodes { type relatedIssue { identifier state { type } } } }
    inverseRelations { nodes { type issue        { identifier state { type } } } }
  }
}
```

- **Body**: marcador + cláusulas del núcleo + overlay del tipo (mismos checks que `--file`).
- **Propiedades**: estimate, prioridad, ≥1 etiqueta, proyecto (duros de despachabilidad; el tipo `contenido-datos` exime el estimate).
- **Relaciones**: bloqueos ACTIVOS = nodos de `inverseRelations` con `type == "blocks"` cuyo bloqueador no esté en estado `completed`/`canceled` → duro: una issue bloqueada NO es despachable, por bien escrita que esté.

## 7. Gotchas & Cross-References

1. **`labelIds` reemplaza, no añade** → leer-unir-reenviar SIEMPRE (§3.4); el error clásico borra las etiquetas existentes.
2. **`issueSearch` está deprecada** → dedupe con `issues(filter:)` y los operadores `containsIgnoreCase` sobre título/descripción/comentarios (§3.2).
3. **El identificador legible sirve como id** → `issue(id: "ABC-123")` acepta el identifier además del UUID; útil para el CLI.
4. **Bloqueo activo ≠ relación presente** → una relación `blocks` con el bloqueador ya completado NO bloquea; el duro mira el ESTADO del bloqueador (§6).
5. **Prioridad de solicitudes ≠ prioridad de issues** → escalas distintas (§4); mezclar produce datos sin sentido.
6. **El shape de `templateData` está congelado por sonda, no por docs** → el contrato de §3.6 sale de un round-trip real (la documentación pública no lo publica). Dos trampas verificadas: `teamId` exige UUID (la introspección promete "identifier or key" — hoy es falso) y el round-trip NO es textual (`description` markdown → `descriptionData` rich-text normalizado). Si el API deja de aceptar el contrato, RE-SONDAR y recongelar §3.6 — nunca "ajustar" el payload a ciegas (AP-11).
7. **API keys restringibles** → una key limitada por permisos/equipos puede leer issues pero no clientes o plantillas; el helper degrada con mensaje claro, nunca con un falso "no existe".
8. **Los primeros ~3 minutos de una issue** → ediciones en ese margen se consideran parte de la creación y no aparecen en el feed de actividad; no confiar en el feed para auditar la creación.
9. **Magic words solo cierran al fusionar** → `closes ABC-123` en el body del PR; el cierre manual desde la UI rompe la trazabilidad salvo en el régimen `contenido-datos` (con evidencia).
10. **Delegate ≠ assignee** → el agente va como delegate; el humano queda assignee (responsabilidad y revisión). Documentado en Linear for Agents.

**Related reference files:**

- Marcador, matriz y gates → `01-nucleo-y-despachabilidad.md`
- Elegibilidad del gate operativo (remoto vs body-only) → `01-nucleo-y-despachabilidad.md` §8
- Baterías y matrices que la issue activa → `02-verificaciones.md`
