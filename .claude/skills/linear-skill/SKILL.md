---
name: linear-skill
description: >
  Gestionar Linear (https://linear.app) para el equipo de desarrollo Talent Engine de Talent
  Network — equipo pequeño (2-3 humanos + agentes IA) que mantiene Academia Ejemplo, Talent Land,
  Talent Land Online, Bootcamp Cripto, Talent Media y la fábrica de software. Use este skill
  SIEMPRE que el usuario mencione Linear, issues, cycles/sprints, projects, milestones,
  initiatives, triage, sub-issues, backlog, labels, plantillas (templates), agentes IA en Linear,
  API/GraphQL de Linear, webhooks de Linear, o gestión de tareas/sprints/releases del equipo.
  Triggers: crear/buscar/actualizar issues, añadir o quitar labels, mover de estado, relacionar
  issues, batch, planificar el cycle, retro, reportes, delegar a agentes IA, conectar PRs de GitHub
  con issues, configurar webhooks, escribir project updates. También con frases vagas como "pasa
  esto a Linear", "qué hay en mi backlog", "qué toca esta semana" o "cómo va el proyecto X".
---

# Linear Skill — Talent Engine

Skill de gestión de Linear para el equipo Talent Engine de Talent Network. Implementa **The Linear Method** (de uso libre) adaptado a un equipo pequeño (2-3 humanos + N agentes IA) y documenta cómo lo consume de verdad la fábrica de software de la casa (batches y encargos, no cycles).

## Contexto del workspace (verificado en vivo `2026-09-05`)

```text
Workspace:    Talent Engine (urlKey talent-engine)
Team:         Talent Engine (prefix: TAL, id 6a99ed4d-c2d3-4028-be75-4ff014b49f38)
Auth:         Token por carril (LINEAR_API_KEY en .env.local o en el fichero de TA_OPERATION_ENV) — API GraphQL directa, NO MCP
Cycles:       DESACTIVADOS en el team (cyclesEnabled=false) — los workflows de cycle son de uso libre
Estimates:    el team no usa estimación nativa (issueEstimationType=notUsed); estimate 1-5 se
              escribe por API como CONVENCIÓN de la casa (tope 5 por issue; bundles ≤5)
Initiatives:  10 activas (Talent Engine [meta], Talent Portafolio, Genius Arena, Talent Sales
              Suite 2026, Event Engine 2026, Academia Ejemplo 2026, Talent Land, Bootcamp Cripto
              2026, Talent Land Online 2026, Talent Media 2026) — IDs en examples/talent-engine-config.json
Estados:      9 — Backlog · Todo · Blocked · In Progress · In Review · Awaiting push approval ·
              Done · Canceled · Duplicate (type duplicate, NO canceled). Sin estado de tipo triage.
Labels:       vertical/* + kind:* + actor/* + sev:* (108 labels vivos; recibo 2026-09-05). Dos
              namespaces reales coexisten: actor/ai y actor/human (barra, workspace) y actor:needs-review
              (dos puntos, POR TEAM); kind:test, vertical/fabrica y vertical/land-es también son POR TEAM
```

> **Frontera de identidad (paquete de fábrica)**: el team `TAL`, la initiative meta y el catálogo
> de initiatives que este skill fija son **constantes compartidas del workspace** `Talent Engine`
> (doctrina común a todas las fábricas que operan contra él), **no identidad por repositorio** —
> por eso `linear-skill` viaja como NÚCLEO del paquete, sin overlay. La identidad POR REPO (slug,
> dir, anexo, estados Linear por proyecto) vive en los `repo-identity.conf` de los skills de
> operación (`talent-channel-operation`, `talent-orchestrator`).

Regla del repo (CLAUDE.md 21): el trabajo de PRODUCTO va SIEMPRE a un project de `Academia Ejemplo 2026`
(`cfcbfe90-efd4-4faa-a702-d2532d64d9db`); la capa META de orquestación va a `Talent Engine`
(`e445b88c-292b-4a7f-a4bd-0866b635e075`). `projectId` es obligatorio: sin project afín → parar y preguntar.

## Versiones verificadas (`last_verified: 2026-09-05`)

| Componente | Versión / estado |
|---|---|
| API GraphQL de Linear | Sin versionado propio explícito — la verdad de runtime es el **schema vivo** (introspección por trozos, cap 10.000 puntos por query) + las cabeceras `X-RateLimit-*`/`X-Complexity` de cada respuesta, no la prosa de los docs (ver `references/04-rate-limits.md`) |
| `@linear/sdk` | `93.0.1` (publicada 2026-09-04, `engines >=18.x`). Cadencia semanal con majors casi cada semana (89→93 entre el 30-jul y el 3-sep-2026); un major NO implica rotura — leer el CHANGELOG filtrando por los tipos que consumes. **Re-verificar** con `npm view @linear/sdk version` antes de fijar versión |
| Transporte MCP | **NO se usa** en este repositorio (token-only, API GraphQL directa — ver sección de autenticación abajo). El servidor oficial existe (`https://mcp.linear.app/mcp`; SSE deprecado, no retirado) y se documenta solo como contexto en `references/06-agents-sdk.md` |

### Estados del workflow (referencia rápida)

```text
┌─────────┐   ┌──────────┐   ┌────────────┐   ┌───────────┐   ┌───────────┐
│ triage  │──▶│ backlog  │──▶│ unstarted  │──▶│  started  │──▶│ completed │
└─────────┘   └──────────┘   └────────────┘   └─────┬─────┘   └───────────┘
   (TAL no lo usa)                                    │
                                          ┌───────────┴───────────┐
                                          ▼                       ▼
                                    ┌───────────┐          ┌───────────┐
                                    │ canceled  │          │ duplicate │  (7.º tipo)
                                    └───────────┘          └───────────┘
```

`WorkflowState.type` es un `String!` con 7 literales (`triage, backlog, unstarted, started,
completed, canceled, duplicate`); **no existe un enum GraphQL con nombre propio para ese campo** (el tipo
local que declara `scripts/linear-client.ts` es solo una vista del script). Detalle en `references/01-data-model.md`.

## Quick Start

| Metric | Value | Last verified |
|--------|-------|----------------|
| `@linear/sdk` (npm) | **93.0.1** | `npm view @linear/sdk version` — 2026-09-05 |
| Linear GraphQL API | `https://api.linear.app/graphql`, sin versionado en URL | 2026-09-05 — `references/03-graphql-cheatsheet.md` |
| Node.js (repo) | `>=24.0.0 <25.0.0` (`.nvmrc` → 24.22.1) | 2026-10-22 — `package.json` / `.nvmrc` (TAL-5329); 24.22.1 = suelo de parche del aviso de Node del 21-oct-2026 |
| TypeScript (repo) | 6.0.3 | 2026-07-18 — `package.json` |
| Runner de scripts | `tsx` 4.22.4 (ya en `devDependencies` raíz) | 2026-07-18 — `package.json` |

**Por qué mono-lenguaje**: Linear no publica SDK oficial en Python — solo `@linear/sdk`
(TypeScript/JS) y la API GraphQL directa, consumible desde cualquier lenguaje vía HTTP plano. Este
skill es mono-lenguaje (TypeScript) por variación aceptada del Gold Standard (`skill-creator`,
ítem 6 "Acceptable Variations"), no por omisión.

```bash
npm install -D typescript@6 @types/node@24 tsx@4
npm view @linear/sdk version            # re-verificar SIEMPRE antes de fijar: majors semanales
npm install @linear/sdk@latest
```

```typescript
import { LinearMinClient, loadApiKey } from "./scripts/linear-client";

// La clave se resuelve como en «Autenticación por token» (LINEAR_API_KEY > TA_OPERATION_ENV > .env.local):
// con scripts/linear-client.ts usa loadApiKey() en vez de leer process.env a mano.
const client = new LinearMinClient({ apiKey: loadApiKey() });
const me = await client.query(`{ viewer { id name email } }`);
console.log(me.viewer);
```

Implementación de referencia completa (paginación, clasificación de errores, CircuitBreaker):
`scripts/linear-client.ts` — corre `bash <raíz-del-repo>/scripts/tsx.sh scripts/linear-client.ts --help` y `--action selftest`.

**GraphQL es agnóstico de lenguaje** — no hace falta `@linear/sdk` (ni ningún SDK) para hablar con
Linear, solo HTTP. Ejemplo mínimo con `curl`, mismo patrón que usa este repo de verdad (token-only,
sin MCP — ver `docs/runbooks/mcp-fallbacks.md`):

```bash
# Igual que en "Autenticación por token" abajo: el header va por --config 0600, NUNCA
# interpolado en -H (quedaría visible en argv/proc/pid/cmdline).
[ -n "${LINEAR_API_KEY:-}" ] || { echo "FALTA LINEAR_API_KEY: resuélvela antes con el bloque de «Autenticación por token» (LINEAR_API_KEY > TA_OPERATION_ENV > .env.local)" >&2; return 1 2>/dev/null || exit 1; }
cfg=$(mktemp); chmod 600 "$cfg"; trap 'rm -f "$cfg"' EXIT
printf 'header = "Authorization: %s"\n' "$LINEAR_API_KEY" > "$cfg"
curl -sS --config "$cfg" -H "Content-Type: application/json" \
  -d '{"query":"{ viewer { id name email } }"}' \
  https://api.linear.app/graphql
```

Válido desde cualquier lenguaje con un cliente HTTP (Python `requests`, Ruby `net/http`, Go
`net/http`, etc.) — solo cambia la sintaxis de la petición, no el contrato.

## Filosofía operativa

Este skill hace cumplir cuatro principios no negociables:

1. **Una issue, un dueño, un estado claro**. Si una issue no cabe en un encargo (estimate > 5 por convención de la casa), se descompone en sub-issues. Si no cabe en varios encargos, es un Project con milestones.
2. **Dedupe siempre antes de crear**. Buscar issues similares con búsqueda por filtros (`issues(filter:)`, ver ref 03) y leer sus `attachments`; preferir comentar en una issue existente que crear una nueva.
3. **Trabajo de IA marcado y revisado**. Toda issue tocada por un agente lleva label `actor/ai` y un humano revisa antes de cerrar. Los agentes nunca cierran issues directamente — solo abren PR; el cierre lo hace la automation de GitHub al merge (magic word), salvo las excepciones de cierre de `talent-merger` (ver Cross-Skill).
4. **Sin ruido en el sistema**. No crear issues "por si acaso". Sin templates respetados, vuelve al Backlog. La velocidad de Linear depende de mantener el sistema limpio.

## Cómo usar este skill (decision tree)

```text
                    ┌─────────────────────────────────┐
                    │   ¿Qué necesita el usuario?       │
                    └────────────────┬────────────────┘
        ┌────────────────┬───────────┴────────┬────────────────────┐
        ▼                ▼                    ▼                    ▼
┌───────────────┐ ┌───────────────┐  ┌────────────────┐  ┌─────────────────┐
│ 1-3 issues,    │ │ Batch grande   │  │ Workflow        │  │ Redactar issue/ │
│ operación      │ │ (paginación,   │  │ recurrente      │  │ comment/update  │
│ puntual        │ │ >20 items)     │  │ (planning,      │  │                 │
│                │ │                │  │ retro, triage)  │  │                 │
└───────┬────────┘ └───────┬────────┘  └────────┬────────┘  └────────┬────────┘
        ▼                  ▼                    ▼                    ▼
 references/03-      references/03 +      workflows/*.md       prompts/*.md
 graphql-cheatsheet    scripts/batch-
 .md                   issues.ts (issueBatchUpdate ≤50)
```

¿Algo que no sabes hacer? Consulta `references/` por capa: data model (01) → graphql (03).

### Índice de playbooks (una línea cada uno)

- `workflows/01-crear-project.md` — crear un Project con milestones dentro de una initiative.
- `workflows/02-triage-y-delegar.md` — clasificar el backlog y delegar a un agente (delegate ≠ assignee).
- `workflows/03-cycle-planning.md` — planificar un cycle semanal (de uso libre; TAL no usa cycles).
- `workflows/04-cycle-review.md` — cerrar cycle y retro (de uso libre; TAL no usa cycles).
- `workflows/05-bug-handling.md` — de reporte de bug a fix con labels `kind:fix` + `sev:*`.
- `workflows/06-feedback-a-issue.md` — convertir feedback de cliente en Customer Request + issue.
- `prompts/crear-issue.md` · `buscar-y-deduplicar.md` · `batch-update.md` · `weekly-report.md` (uso libre) · `issue-template-*.md`.

## Capacidades (qué pedirme)

Acciones de alto nivel que entiendo y ejecuto:

- **Crear issue** con dedupe automático, asignación a initiative/project/milestone, labels, estimate, plantilla nativa (`templateId`).
- **Crear sub-issues** descomponiendo un parent grande (orden por `blockedBy`: hojas primero).
- **Buscar issues** por texto, filtros, owner, initiative, vertical; leer sus adjuntos.
- **Mover issues** entre estados, projects; **añadir/quitar labels** sin pisar los demás (`issueAddLabel`/`issueRemoveLabel`).
- **Actualizar en lote** con `issueBatchUpdate` (≤50 ids por llamada).
- **Relacionar** issues (`blocks`, `related`, `duplicate`, `similar`).
- **Delegar a agente IA** (asigna delegate, añade label `actor/ai`, comenta plan inicial).
- **Planificar/cerrar cycle** (de uso libre — no lo ejercita la fábrica).
- **Crear Project con milestones** dentro de una initiative.
- **Escribir Project Update / Initiative Update** (resumen estructurado).
- **Triage del backlog** (clasificar nuevas issues, asignar vertical, priorizar).
- **Reporte de progreso** agrupado por initiative.
- **Auditoría de trabajo IA vs humano** (ratios, % de PRs aceptados, comments por agente).

## Antes de cualquier acción destructiva

Confirmar con el humano explícitamente. Acciones destructivas son:

- Borrar issues, projects, milestones, initiatives, comments
- Cambiar workflow states del team
- Modificar admin settings, OAuth apps, secrets de webhooks
- Archivar/borrar projects o issues en lote (>3)
- Mover issues entre teams en lote
- Eliminar/renombrar labels en uso
- Cualquier `*Delete*` o `*Archive*` mutation a más de 1 entidad

Para acciones no destructivas frecuentes (crear issue, comentar, mover de estado), proceder sin pedir confirmación.

## Convenciones de naming y formato

**Branch names** — SIEMPRE en minúsculas tras el prefijo: tomar el `gitBranchName` literal que
devuelve la API de la issue, nunca inventar el `TAL-NNN` en mayúsculas del título (el required check
de rama del repo rechaza mayúsculas). El prefijo es uno de los válidos de CLAUDE.md regla 10
(`feat/`, `fix/`, `refactor/`, `docs/`, `chore/`, `hotfix/`) según el tipo de trabajo, nunca `ai/`:

```text
feat/tal-{n}-{slug-de-titulo}
```

**Commit/PR magic words** (auto-cierran el issue al merge):

```text
fixes TAL-123      closes TAL-123      resolves TAL-123
```

Para vincular sin auto-cerrar (y cuando el `closes` daría un «Done falso», p. ej. migración
pendiente de aplicar — ver `talent-merger`):

```text
refs TAL-123       relates to TAL-123
```

**Menciones en comentarios** (verificado 2026-09-05 con `commentCreate`): la URL de una issue —
plana o en enlace Markdown — se convierte en mención enlazada; `@Nombre Apellido` exacto de un
miembro se convierte en mención de usuario; un identificador `TAL-123` suelto queda como texto.

**Project name pattern** (dentro de una initiative): `{Verbo} {Cosa} v{N}` → "Lanzar Dashboard v2".
NO incluyas el año en el Project — el año vive en la Initiative parent.

**Issue title pattern**: `{Imperativo} {Qué} ({Dónde si aplica})` — ✓ "Corregir cálculo de
descuentos en checkout" · ✗ "Bug en checkout".

## Estructura de archivos del skill

Las llamadas GraphQL a la API de Linear están protegidas por un `CircuitBreaker` de 3 estados
(definido en `linear-client.ts`) contra fallos sostenidos:

```text
   CLOSED ──5 fallos consecutivos──▶ OPEN ──resetTimeoutMs (30s)──▶ HALF_OPEN
     ▲                                                                  │
     └──────────────────── llamada de prueba OK ───────────────────────┘
                             (halfOpenMax intentos antes de reabrir)
```

Cada script aplica **solo** la política de resiliencia de su propio flujo:

- **`linear-client.ts` / `batch-issues.ts`** — llamadas GraphQL: pasan por el `CircuitBreaker` y reintentan con **`LinearMinClient.queryWithRetry()`** (el método que existe en el cliente y el que `batch-issues.ts` invoca de verdad; `retryWithBackoff` es una función suelta para lo que NO es GraphQL, ver el punto siguiente) SOLO en fallos transitorios (`RATELIMITED`, respuesta vacía/no-JSON, 5xx, 429 desnudo); los errores deterministas (`INPUT_ERROR`, `INVALID_INPUT`, `GRAPHQL_VALIDATION_FAILED`) fallan de inmediato.
- **`upload-attachment.ts`** — la subida del archivo es un `PUT` idempotente a una signed URL, protegido con `retryWithBackoff` (no por el breaker); solo la mutation `fileUpload` pasa por el `CircuitBreaker`.
- **`verify-webhook.ts`** — verificación HMAC-SHA256 puramente local con anti-replay (lee `webhookTimestamp` del body firmado, nunca el header) y deduplicación por delivery ID: **sin llamadas salientes, sin `CircuitBreaker`**.

```text
linear-skill/
├── SKILL.md                    ← este archivo
├── CHANGELOG.md · README.md · invariants.tsv (ratchets del paquete de fábrica)
├── references/                 ← documentación cargada bajo demanda
│   ├── 01-data-model.md        ← entidades de Linear y sus relaciones
│   ├── 02-mcp-tools.md         ← (DEPRECADO) puntero a 03 (GraphQL)
│   ├── 03-graphql-cheatsheet.md ← queries/mutations directas (labels, batch, templates, errores)
│   ├── 04-rate-limits.md       ← rate limits, complejidad y códigos de error
│   ├── 05-webhooks.md          ← eventos en tiempo real (22 recursos, firma, rotación)
│   ├── 06-agents-sdk.md        ← Linear for Agents, Coding Sessions, Loops, MCP (contexto)
│   └── 07-linear-method.md     ← The Linear Method (uso libre)
├── workflows/                  ← procedimientos paso a paso (01-06, ver índice de playbooks)
├── prompts/                    ← plantillas listas para usar (crear-issue, dedupe, batch, report)
├── scripts/                    ← código ejecutable
│   ├── linear-client.ts        ← cliente GraphQL minimal + clasificación de errores + selftest
│   ├── verify-webhook.ts       ← verificación HMAC + replay
│   ├── batch-issues.ts         ← lotes con issueBatchUpdate (≤50) + addedLabelIds/removedLabelIds
│   ├── check-taxonomy-parity.sh ← gate: autoridad/proyección == Linear vivo (--live)
│   └── upload-attachment.ts    ← signed URL + PUT + attachmentCreate
├── evals/                      ← escenarios con baseline con/sin skill (skill-creator)
└── examples/                   ← configuración concreta del workspace
    ├── talent-engine-config.json   ← proyección de UUIDs (team, 9 estados, 10 initiatives, projects, labels)
    ├── label-taxonomy.json         ← AUTORIDAD interna de nombres/grupos de labels
    ├── label-taxonomy.receipt.json ← recibo sanitizado de la consulta viva (issueLabels, 108)
    ├── agent-guidance.md · claude-md-template.md
    └── issue-templates/ (feature.md, bug.md, tarea-delegable-a-ia.md — uso libre)
```

## Autenticación por token (token-only, NO MCP)

```text
┌──────────────┐   Authorization: <LINEAR_API_KEY>    ┌────────────────────────┐
│ Script /      │─────────────────────────────────────▶│ https://api.linear.app │
│ agente IA     │      POST GraphQL query/mutation      │ /graphql                │
└──────────────┘                                        └───────────┬────────────┘
                                                                      ▼
                                                ┌──────────────────────────────────┐
                                                │ 200 + { data } / { errors }        │
                                                │ + headers X-RateLimit-*            │
                                                └──────────────────────────────────┘

  ✗ NO existe ruta MCP: sin servidor Linear MCP, sin .mcp.json — ver references/02-mcp-tools.md
```

Este repositorio opera Linear **exclusivamente por la API GraphQL directa** con un **token por
carril**, nunca por el servidor MCP de Linear.

1. El token vive en un fichero de entorno (gitignored) como `LINEAR_API_KEY` — nunca en el repo, nunca
   tecleado en la línea de comandos (quedaría en el historial de shell). Se busca por este orden:
   (a) `LINEAR_API_KEY` ya exportada; (b) si `TA_OPERATION_ENV` está definida y no vacía, el fichero al
   que apunta y SOLO ese (así reciben la clave las sesiones de rol de una instalación: vive en el
   `.env.local` del rol, no en el clon); (c) si no, `.env.local` en la raíz del repo. Si (b) apunta a un
   fichero que falta o que no trae `LINEAR_API_KEY=`, es un error con la RUTA y la variable: no se cae en
   silencio a la raíz del repo. Sin ninguna fuente tampoco hay llamada: jamás una clave vacía hacia un 401 mudo.
2. Vía preferida: el cliente `scripts/linear-client.ts` (resuelve la clave con el mismo orden,
   la carga sin ejecutar el archivo ni exponerla en argv/logs, y centraliza la
   validación). Todas las llamadas van al endpoint `https://api.linear.app/graphql`.
3. Verificación rápida por `curl` **sin exponer el token en argv** (sería visible en
   `/proc/pid/cmdline`): se pasa por un archivo `--config` 0600 (misma postura que `scripts/cr-review.sh`,
   regla 18), y **falla ante error HTTP y ante `errors` de GraphQL**. Para otra consulta o mutación
   (p. ej. `issueUpdate`, ver `references/03-graphql-cheatsheet.md`) se cambia solo el cuerpo de `-d`:

   ```bash
   REPO_ROOT="$(git rev-parse --show-toplevel)"
   if [ -z "${LINEAR_API_KEY:-}" ]; then
     if [ -n "${TA_OPERATION_ENV:-}" ]; then ENV_FILE="$TA_OPERATION_ENV"; ENV_DE="la variable TA_OPERATION_ENV"
     else ENV_FILE="$REPO_ROOT/.env.local"; ENV_DE="la raíz del repo"; fi
     [ -f "$ENV_FILE" ] || { echo "FALTA el fichero de LINEAR_API_KEY: $ENV_FILE (lo indica $ENV_DE) — parar y avisar al lead" >&2; return 1 2>/dev/null || exit 1; }
     LINEAR_API_KEY=$(grep -E '^LINEAR_API_KEY=.+' "$ENV_FILE" | head -1 | cut -d= -f2- || true)
     [ -n "$LINEAR_API_KEY" ] || { echo "FALTA LINEAR_API_KEY en $ENV_FILE (lo indica $ENV_DE) — parar y avisar al lead" >&2; return 1 2>/dev/null || exit 1; }
   fi
   cfg=$(mktemp); chmod 600 "$cfg"; trap 'rm -f "$cfg"' EXIT
   printf 'header = "Authorization: %s"\n' "$LINEAR_API_KEY" > "$cfg"   # printf builtin → el token NO entra en argv
   resp=$(curl -sS --fail-with-body --config "$cfg" -H "Content-Type: application/json" \
     -d '{"query":"{ viewer { id name } }"}' https://api.linear.app/graphql) \
     || { echo "error HTTP: $resp" >&2; return 1 2>/dev/null || exit 1; }
   printf '%s' "$resp" | grep -q '"errors"' && { echo "GraphQL errors: $resp" >&2; return 1 2>/dev/null || exit 1; }
   printf '%s\n' "$resp"
   ```

Si `LINEAR_API_KEY` falta o no responde, PARAR y avisar al lead — no fabricar issues sin
trazabilidad. No añadir `.mcp.json` ni `claude mcp add`.

## Reference Files — cuándo cargar qué referencia

Carga referencias bajo demanda según la tarea:

| Si el usuario pide... | Lee primero... |
|---|---|
| Crear/actualizar/buscar issues, labels, relaciones, plantillas | `references/03-graphql-cheatsheet.md` |
| Operación batch grande / paginación | `references/03-graphql-cheatsheet.md` + `scripts/batch-issues.ts` |
| Entender cómo se relacionan teams/projects/initiatives/estados | `references/01-data-model.md` |
| Configurar webhooks o integración de eventos | `references/05-webhooks.md` |
| Construir/conectar un agente IA propio, Coding Sessions, Loops, MCP | `references/06-agents-sdk.md` |
| Justificar una decisión de organización | `references/07-linear-method.md` |
| Está fallando algo de rate limit o de complejidad | `references/04-rate-limits.md` |

Para workflows recurrentes (planning, retro, triage), `workflows/` tiene playbooks paso a paso.

## Critical Gotchas — errores comunes que debo evitar

1. **Crear issues sin dedupe previo** — siempre busca primero y lee `attachments { nodes { url } }`: un agente no «ve» capturas sin fetch explícito.
2. **Usar `first: <huge>`** — el máximo es **250** (`first: 251` → HTTP 400 `INVALID_INPUT`, «first must not be greater than 250», verificado 2026-09-05); default 50 en TODA connection anidada.
3. **Creer que `labelIds` añade** — `labelIds` REEMPLAZA el array. Para añadir/quitar sin pisar los demás usa `issueAddLabel`/`issueRemoveLabel` o `addedLabelIds`/`removedLabelIds` de `IssueUpdateInput` (evitan la carrera del read-then-write). Todos existen vivos (verificado 2026-09-05).
4. **Reintentar un `INPUT_ERROR`** — complejidad > 10.000 puntos (HTTP 400, `extensions.code: INPUT_ERROR`) es determinista: rediseña la query (introspección por trozos, menos anidamiento). Solo `RATELIMITED`, respuestas vacías/no-JSON y 5xx se reintentan.
5. **Fiarse del status HTTP** — Linear devuelve 200 con `errors[]` en mutaciones fallidas; comprueba `errors` antes de leer `data`. Y una respuesta vacía o no-JSON transitoria (vivida en `issueCreate`) se reintenta con backoff, deduplicando por título antes de repetir una mutación no idempotente.
6. **Iterar N `issueUpdate` cuando hay batch** — `issueBatchUpdate(ids: [UUID!]!, input)` admite ≤50; `issueBatchCreate` exige el wrapper `{ issues: [...] }` (tipar la variable como `[IssueCreateInput!]!` devuelve `{issues: []}` SIN error).
7. **Modificar issue dentro de los primeros 3 minutos** — esos cambios no aparecen en activity feed.
8. **Asignar agente como assignee primario** — el assignee primario debe ser humano, el agente va como delegate.
9. **Cerrar issues sin que el PR esté merged** — rompe la trazabilidad GitHub ↔ Linear. Y al revés: el sync de GitHub puede REVERTIR Done→In Progress si detecta actividad de PR sin magic word (`fixes/closes/resolves`).
10. **Crear Projects sin initiative parent / issues sin `projectId`** — todo project vive en una initiative; toda issue lleva project afín (fail-closed: si no hay, preguntar).
11. **Olvidar el label de vertical** — toda issue debe tener al menos un `vertical/*`; los labels que existen POR TEAM (`kind:test`, `vertical/fabrica`, `vertical/land-es`, `actor:needs-review`) se resuelven al UUID del team de la issue (`duplicate_sites`), nunca a uno arbitrario.
12. **Hacer comments largos cuando una sub-issue es lo correcto** — si el "comment" describe trabajo, conviértelo en sub-issue; cierra cada issue por completo (estado + comentario) antes de pasar a la siguiente.
13. **Tratar `Duplicate` como `canceled`** — tiene `type: duplicate` (7.º tipo); los filtros de estados terminales deben incluirlo. El campo `type` es un String, no un enum del schema.
14. **Filtrar deprecaciones solo por `isDeprecated`** — `issueSearch` está deprecada solo en su `description` (`[DEPRECATED] … use searchIssues`); grepea también las descriptions. `projectArchive` sí está marcada: usa `projectDelete`.
15. **Plantillas nativas** — `issueCreate` admite `templateId` + `description` a la vez (la description manda); `templateCreate.teamId` exige UUID aunque la introspección diga «identifier or key»; el round-trip de `templateData` es semántico, no textual (`talent-issue-craft` §3.6).
16. **Relaciones con tres tipos** — `IssueRelationType` tiene cuatro: `blocks | duplicate | related | similar`.
17. **Pasar el token con `curl -H "Authorization: $KEY"`** — la shell lo expande y queda en `ps`/argv: usa `--config` 0600. Y no dupliques `Content-Type` si tu curlrc ya lo trae («POST body missing»).
18. **Ramas con `TAL-` en mayúsculas** — usa el `gitBranchName` de la API; el validador de rama rechaza mayúsculas.
19. **Webhooks con recursos que no existen** — `Team` no es recurso suscribible; `IssueSLA` usa `set/highRisk/breached`; `OAuthApp` solo dispara `revoked`; el payload de `AgentSessionEvent` no lleva wrapper `data` y `guidance` es un array; rota el secret con `webhookRotateSecret`, no recreando el webhook.
20. **Bloquear un upgrade del SDK «porque es major»** — los majors semanales saltan por cualquier `breaking` del schema aunque sea en namespaces que no usas (`AiConversation*`); el único breaking reciente que afecta a CRUD es 90.0.0 (`*Filter.id` de Initiative/Project → `EntityIdentifierIDComparator { eq, in, neq }`). `cycleCreate` quedó deprecada («not supported») en 93.0.0.
21. **`fileUpload` cambió de Query a Mutation** (TAL-1938) y rechaza `iconUrl` SVG — `upload-attachment.ts` ya está alineado; `attachmentCreate` deja un enlace LATERAL, para ver una imagen inline embebe `![nombre](assetUrl)` en el comentario.
22. **Confiar en `DeliveryDeduper` de `verify-webhook.ts` para deploys multi-instancia** — es dedup en memoria (single-instance); en Railway con réplicas usa el patrón `processed_at` con lock de fila (ver Cross-Skill Integration → nextjs-web).
23. **Llamar `DeliveryDeduper.checkAndMark()` ANTES de procesar el evento** — marca como visto en el check, no tras éxito; si el procesamiento falla, el reintento legítimo de Linear se rechaza como duplicado y el evento se pierde.
24. **Comentarios con deixis ambigua** — todos los agentes publican bajo la misma cuenta; «ya está hecho localmente» sin sujeto ni sha ha parado coordinadores. Nombra el artefacto, el sha y quién.

## Troubleshooting (cuando algo YA falló)

| Síntoma | Qué mirar | Acción |
|---|---|---|
| 401 / «Authentication required» | Header `Authorization` sin `Bearer` para API key; key ausente (ni exportada, ni en el fichero de `TA_OPERATION_ENV`, ni en `.env.local`); key restringida por team | Verificar con `{ viewer { id } }`; una key restringida degrada con mensaje claro, nunca como «no existe» |
| HTTP 400 `RATELIMITED` | `X-RateLimit-Requests-Remaining`/`Complexity-Remaining`; `*-Reset` en epoch **ms** | Esperar hasta el reset; la cuota es por usuario (todas sus keys la comparten) |
| HTTP 400 `INPUT_ERROR` «Maximum allowed complexity: 10000» | Anidamiento y `first` de la query | NO reintentar: trocear (p. ej. `__type(name:)` por tipo), bajar `first` |
| HTTP 400 `INVALID_INPUT` / `GRAPHQL_VALIDATION_FAILED` | `first` > 250; campo o argumento inexistente (p. ej. `organization { initiatives }`) | Corregir la query contra el schema vivo; `initiatives(first:N)` va en la raíz |
| 200 con `errors[]` | `extensions.code` y `userPresentableMessage` | Tratar como fallo; nunca leer `data` a medias |
| Respuesta vacía / HTML / no-JSON | Transitorio del edge | Reintentar con backoff (máx 3); dedupe antes de repetir una mutación |
| Datos que «faltan» | `includeArchived: false` por defecto; labels por team vs workspace; issue en otro team | Consultar con `includeArchived: true` o el UUID del team correcto |
| Lento / paginación interminable | `orderBy: createdAt` por defecto | `orderBy: updatedAt` para sincronizaciones incrementales; cursores `endCursor` |

## Fuera de alcance / límites conocidos

- **Coding Sessions, Loops y el Linear Agent nativo**: se documentan como contexto (`references/06-agents-sdk.md`); adoptarlos compite con los canales y el Orquestador de la fábrica y es una decisión de arquitectura (CLAUDE.md regla 7).
- **OAuth `actor=app` y agentes propios**: fuera del flujo token-only; la capa sigue en Developer Preview y con un 503 reproducible reportado por integradores (2025-2026).
- **MCP**: no se usa (INV-LS-001); `references/02-mcp-tools.md` es solo un puntero.
- **Customer Needs**: cobertura parcial (creación y prioridad 0/1), sin flujo de gestión completo.
- **No documentado por Linear**: orden de entrega de webhooks, tamaño máximo de payload, legibilidad del `secret` tras crearlo. Se declara, no se inventa.
- **Cycles y reportes semanales**: workflows/prompts de uso libre; la fábrica de Talent Engine no los ejercita (cycles desactivados).

## Cross-Skill Integration

### nextjs-web

`nextjs-web` no tiene convención propia de Linear/branch-naming — cubre Server Actions, App
Router y componentes de forma genérica. La relación real con este skill es de dos vías:

**(a) Branch/PR ↔ issue**: la rama de un PR que implementa una feature sigue la convención de este
skill (`feat/tal-{n}-{slug}` u otro prefijo válido de CLAUDE.md regla 10) y el body del PR debe
incluir `closes TAL-N` para que la automation de cierre lo detecte (ver `coderabbit-talent` abajo).

**(b) Webhooks de Linear en un Route Handler de Next.js** — este skill expone la verificación
(`references/05-webhooks.md`, `scripts/verify-webhook.ts`); el receptor HTTP es el punto de
integración real:

```typescript
// EJEMPLO ILUSTRATIVO (no copia-pega) — esqueleto FAIL-CLOSED, mismo contrato que el resto de
// webhooks del repo. app/api/webhooks/linear/route.ts
// La verificación real vive en .claude/skills/linear-skill/scripts/verify-webhook.ts; NINGÚN
// archivo de src/ importa de .claude/ — para producción, PORTA esa lógica a
// src/lib/linear/verify-webhook.ts y ajusta el import.
import { NextResponse, type NextRequest } from "next/server";
// import { verifyLinearWebhook } from "@/lib/linear/verify-webhook"; // tras portar

export const dynamic = "force-dynamic"; // raw body + crypto ⇒ sin optimización estática
export const runtime = "nodejs";

export async function POST(request: NextRequest) {
  // 1) Header de firma presente (check barato) ANTES de leer el body.
  const signature = request.headers.get("linear-signature");
  if (!signature) return new NextResponse("missing signature", { status: 400 });
  // 2) Config ausente → 5xx, NUNCA 4xx (un 401 por fallo NUESTRO hace que Linear deje de reintentar).
  const secret = process.env.LINEAR_WEBHOOK_SECRET;
  if (!secret) return new NextResponse("config error", { status: 500 });
  // 3) BODY CON COTA durante el streaming — OBLIGATORIO: `request.text()` lee sin límite y
  //    Content-Length puede mentir. Usa el reader-con-cap del repo
  //    (src/app/api/webhooks/stripe/route.ts: MAX_BODY_BYTES + readBodyWithLimit → 413).
  // const rawBody = await readBodyWithLimit(request, MAX_BODY_BYTES);
  // const headers = Object.fromEntries(request.headers.entries());
  // 4) Linear-Delivery OBLIGATORIO si vas a deduplicar (sin él no hay reintento detectable → 400).
  // 5) Verificación real (HMAC-SHA256 timing-safe + ventana de `webhookTimestamp` del body):
  //    inválida → 401. Sin deliveryDeduper aquí: el dedupe va serializado con la reserva del paso 6.
  // const result = verifyLinearWebhook(rawBody, headers, secret);
  // if (!result.valid) return NextResponse.json({ error: result.reason }, { status: 401 });
  // 6) IDEMPOTENCIA DURABLE: reserva (insert unique gateway+event_id=deliveryId) → procesa →
  //    processed_at con lock de fila (patrón: src/app/api/webhooks/stripe/route.ts). El
  //    `DeliveryDeduper` en memoria NO sirve con réplicas ni sobrevive restarts.
  // 7) Solo cuando 3-6 completan con éxito ⇒ 200. Este ESQUELETO lanza a propósito: una copia sin
  //    completar 3-6 NUNCA debe responder 200 (aceptaría bodies sin cota o webhooks falsificados).
  throw new Error("webhook skeleton incompleto: implementa 5 (verify) y 6 (idempotencia durable) antes de responder 200");
}
```

### coderabbit-talent

El veredicto de CodeRabbit **no es vinculante para el merge salvo hallazgos bloqueantes** —
`coderabbit-talent/SKILL.md` documenta la división de responsabilidad: el canal entrega PR draft +
HANDOFF sin correr CodeRabbit; el **gate de merge** y el **magic word `closes TAL-N`** (verificado
por `verify-handoff.sh`) son responsabilidad de **`talent-merger`**. Si delegas una issue a un agente
cuyo PR será mergeado por el Mergeador, el body del PR debe incluir `closes TAL-N` explícito (no
editarlo al mergear — el squash puede pisar el `closes` si se toca el título/body).

### talent-issue-craft (qué escribir) · talent-orchestrator · talent-merger · talent-channel-operation

- **`talent-issue-craft`** aporta el QUÉ (14 combinaciones tipo×variante, marcador `issue-craft:v1`, gate `audit-issue`) y es dueño del contrato de las 9 plantillas nativas `issue-craft: <tipo>` (`templateCreate`/`templateDelete`, `templateId` en `issueCreate`; ver gotcha 15). Este skill aporta el CÓMO llamar a la API.
- **`talent-orchestrator`**: las órdenes de trabajo llevan un bloque JSON machine-readable en el body (`schema_version`, `issue_ids`, `precedence`, `bundles`, `dod`, `idempotency_key`); un encargo = 1 rama = N `closes TAL-x`; los PRs duplicados o rebotados se cierran como `superseded` con traza; `Blocked` se reutiliza como «Needs Input».
- **`talent-merger`**: excepción de cierre — `refs TAL-N` + label `apply-pendiente` cuando el `closes` produciría un «Done falso» (migración diferida); el Mergeador aplica migraciones agent-managed tras el merge (regla 24).
- **`talent-channel-operation`**: los comentarios de una issue son un canal de control: `HOLD id=X` / `RELEASE id=X` de un `user.id` autorizado y `SIN-AUDIT rev=<hash>` gobiernan el despacho (`scripts/lib.sh`).

### Otros skills del checklist Gold Standard — N/A

`convex-skill` (este repo no usa Convex), `supabase-skill` (la única persistencia de `linear-skill` es
la API de Linear) y `talent-docs-skill` (este skill no produce ADRs/runbooks) no tienen punto de
contacto real con la gestión de issues; se documenta en vez de fabricar una integración ficticia.

## Cuando algo no esté claro

Si te falta contexto crítico (a qué initiative o project asignar, qué prioridad poner, qué labels usar), **pregunta al humano** en lugar de adivinar. Una pregunta clarificadora cuesta 10 segundos; un issue mal clasificado cuesta el doble corregirlo después.

## Paquete de fábrica

Este skill es miembro del **paquete de skills de fábrica** (13): coderabbit-talent · linear-skill · talent-ceo · talent-channel-operation · talent-channels · talent-context · talent-docs-skill · talent-issue-craft · talent-medidor · talent-merger · talent-orchestrator · talent-pm · talent-sentry-guard. El paquete viaja JUNTO y
**motor-primero**: canónico en el repo motor `talent-factory` (`skills/`), propagado como núcleo
a los repos de producto con `scripts/paquete/sync-package.sh` (overlays por repo intactos)
y validado con `scripts/paquete/validate-package.sh` + `<skill>/invariants.tsv`.
Manifiesto: `scripts/paquete/package.manifest` · doctrina y ratchet (D6): `scripts/paquete/PAQUETE.md`.
