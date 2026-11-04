# Linear — Rate limits y complejidad

`last_verified: 2026-09-05` (headers de respuesta reales + `https://linear.app/developers/rate-limiting`).

Lee este documento cuando estés haciendo operaciones batch (más de ~50 issues) o cuando una query GraphQL falle con `RATELIMITED`.

## Los tres tipos de límites

Linear aplica tres dimensiones de rate limiting:

| Tipo de auth | Requests/hora | Complexity points/hora |
|---|---|---|
| Personal API key | **2.500** (verificado en vivo: header `x-ratelimit-requests-limit: 2500` en cada respuesta; la prosa de los docs oficiales dice "5.000" en un sitio y "2.500" en tabla — **el runtime del API key confirma 2.500**, no confíes en la prosa) | **3.000.000** (header `x-ratelimit-complexity-limit: 3000000`) |
| OAuth (por user/app-user) | **5.000 base** (documentado) **+ incremento dinámico** para Actor Authorization (workspace OAuth con múltiples usuarios) — no verificable con Personal API key, cita de docs | **2.000.000 base** (documentado) + mismo incremento dinámico |
| No autenticadas | **600** (documentado, `developers.linear.app/rate-limiting`, `last_verified: 2026-07-20`) | **100.000** (documentado) |

**Los números de la tabla son el punto de partida, NO el contrato.** Linear los documenta de forma
inconsistente entre prosa y tabla (visto en vivo para API key: runtime = 2.500, prosa de docs = 5.000). La
**fuente de verdad en runtime son las cabeceras `X-RateLimit-*`** de la respuesta HTTP
(`X-RateLimit-Requests-Limit/Remaining/Reset`, `X-RateLimit-Complexity-*`): léelas y respétalas en vez
de asumir un tope fijo — sobre todo el de OAuth, que además de la base documentada puede escalar
dinámicamente.

**La cuota se agrupa por USUARIO autenticado, no por API key.** Varias Personal API keys del **mismo
usuario** comparten el mismo cupo (2.500 req/h · 3.000.000 complexity/h) — no suman límites
independientes. Repartir carga entre keys de un mismo usuario NO da más cuota; para más cuota, usuarios
distintos.

Para Talent Engine (token por carril sobre la API GraphQL), los límites efectivos son cómodos para uso interactivo. Solo los rozarás en batch grande o si tienes loops accidentales.

```text
┌────────────┐  costo estático  ┌──────────────────────────────┐
│ tu query    │─────────────────▶│ complexity calculada           │
└────────────┘                   │ (2 + N por connection, N×)     │
                                  └───────────────┬─────────────────┘
                                     ┌─────────────┴──────────────┐
                                     ▼                             ▼
                           ┌───────────────────┐        ┌─────────────────────────┐
                           │ dentro de budget/h  │        │ excede budget/h           │
                           │ → 200 + datos        │        │ → 400 RATELIMITED         │
                           └───────────────────┘        │    + Retry-After           │
                                                          └─────────────────────────┘
```

## Cómo funciona la complejidad

Fórmula publicada por Linear (**confirmada** como guard operativo real — ver mediciones en vivo abajo):
cada propiedad solicitada ≈ **0,1 punto**, cada objeto ≈ **1 punto**, y una **connection multiplica el coste
de sus hijos por el argumento de paginación** (`first`/`last`; **default 50 si se omite, máximo 250** —
`first: 251` o superior devuelve HTTP 400 con `extensions.code: "INVALID_INPUT"` y el mensaje literal
`"first must not be greater than 250"`, verificado en vivo 2026-09-05). Cap adicional: **máximo EXACTAMENTE
10.000 puntos por query individual** (documentado oficialmente, no una aproximación — confirmado en vivo
2026-09-05 al rechazar una introspección de 262.144 puntos con `"Complexity: 262144. Maximum allowed
complexity: 10000"`; rechazo inmediato aparte de la cuota horaria).

**`INPUT_ERROR` (cap de complejidad) ≠ `RATELIMITED` (cuota horaria) — son códigos distintos.** Exceder los
10.000 puntos de una query devuelve `extensions.code: "INPUT_ERROR"`; agotar la cuota horaria devuelve
`extensions.code: "RATELIMITED"`. Un `withRetry()` que solo intercepte `RATELIMITED` (ver el ejemplo de más
abajo, ya corregido) **no** capturará ni distinguirá un `INPUT_ERROR` — reintentar una query que excede el
cap fijo fallará siempre igual (es un bug de diseño de query — rediseñar/trocear —, no un throttle
transitorio), agotando `maxRetries` sin motivo.

**La paginación SÍ multiplica en connections anidadas** — mediciones reales (`x-complexity` del header,
`last_verified: 2026-07-20`, re-confirmadas) sobre `viewer.createdIssues` (una connection anidada bajo
`viewer`, NO la raíz):

```graphql
{ viewer { createdIssues(first: 10)  { nodes { id } } } }   # x-complexity = 3
{ viewer { createdIssues(first: 50)  { nodes { id } } } }   # x-complexity = 11
{ viewer { assignedIssues(first: 25) { nodes { id } } } }   # x-complexity = 6
{ teams { nodes { issues(first: 10) { nodes { id } } } } }  # x-complexity = 150 (re-medido 2026-07-20; era 7 el 2026-07-17)
```

**⚠️ Esta medición concreta ha cambiado en 3 días** (7 → 150, mismo workspace, misma query exacta,
re-confirmado dos veces). A diferencia de las demás mediciones de esta sección (que se mantuvieron
estables al re-verificar), esta connection doblemente anidada bajo `teams` (sin `first` propio → default
50) parece más sensible a factores que no son solo la forma de la query — no confíes en un número fijo
para esta forma concreta, es el mejor ejemplo del punto de la siguiente sección ("mide, no estimes").

Con anidamiento más profundo el coste **escala multiplicativamente**, no linealmente — cadenas de
`first: 50` a 2-3 niveles pueden llegar a cientos o miles de puntos, acercándose al cap de ~10.000:

```graphql
{ viewer { createdIssues(first: 50) { nodes { comments(first: 50) { nodes { id } } } } } }
# x-complexity = 112  (2 niveles de first:50)

{ viewer { createdIssues(first: 50) { nodes { comments(first: 50) { nodes {
    user { assignedIssues(first: 50) { nodes { id } } } } } } } } }
# x-complexity = 701  (3 niveles de first:50 — el crecimiento NO es lineal)
```

**⚠️ La connection raíz `issues(first:...)` es una excepción plana**: `{ issues(first: 10) { nodes { id } } }`
y `{ issues(first: 50) { nodes { id } } }` cuestan **ambas 2** — no escalan con `first` como sí lo hacen las
connections anidadas de arriba. No generalices desde `issues` raíz: mide la superficie concreta que uses.

**Regla #1**: **siempre define `first` explícitamente** y pequeño. Sin `first`, Linear pagina 50 por defecto.

**Regla #2**: **evita anidamientos profundos**. Si necesitas comments de muchas issues, mejor hacer 2 queries separadas que una anidada — el coste de anidar escala multiplicativamente, no sumando.

**Regla #3**: **`includeArchived: false`** por defecto. Pedir archivados infla resultados sin valor.

**La única verdad del coste real de UNA query concreta es el header `x-complexity` de su propia respuesta.**
La fórmula de arriba es la guía para diseñar queries seguras; para saber el coste exacto de una query ya
construida, ejecútala (en una llamada de lectura que de todos modos necesitas) y lee el header.

```text
raíz issues(first:N)          → coste PLANO (=2, medido, N∈{10,50})     ← excepción, no la regla
viewer.createdIssues(first:N) → coste escala con N (3 @10, 11 @50)      ← connection anidada
  └─ .comments(first:50)      → 112  (2 niveles)                       ← multiplicativo
       └─ .user.assignedIssues(first:50) → 701  (3 niveles)            ← acercándose al cap ~10.000/query
```

## Headers de respuesta

Cada respuesta del API incluye headers de telemetría:

```text
X-RateLimit-Requests-Limit:        <límite total>
X-RateLimit-Requests-Remaining:    <quedan>
X-RateLimit-Requests-Reset:        <epoch UTC en MILISEGUNDOS en que se resetea>
X-Complexity:                      <coste de esta request>
X-RateLimit-Complexity-Limit:      <límite total complejidad>
X-RateLimit-Complexity-Remaining:  <quedan>
X-RateLimit-Complexity-Reset:      <epoch UTC en MILISEGUNDOS>
```

**Los `*-Reset` vienen en epoch UTC en MILISEGUNDOS** (`last_verified: 2026-09-05`, doc oficial —
`new Date(Number(header))` da la hora exacta; no confundir con epoch en segundos, que dejaría el reset
~1970 con un simple `Number(header) * 1000`).

Patrón recomendado: leer `X-Complexity-Remaining` y aplicar throttling proactivo si baja del 20% del límite.

**Mide `x-complexity`, no lo calcules a mano.** La fórmula de la sección anterior es una guía de diseño,
no un sustituto de medir: `x-complexity` es el ÚNICO dato exacto del coste real de una query concreta.
Medición en vivo de referencia (`last_verified: 2026-09-05`): `issues(first: 250) { nodes { id } }` en la
raíz (sin anidar) cuesta **`x-complexity: 2`** — confirma que la connection raíz de `issues` sigue siendo
la excepción plana documentada más abajo (no escala con `first`), a diferencia de las connections
anidadas bajo `viewer`/`teams`.

## Errores de rate limit

**HTTP 400** con cuerpo:

```json
{
  "errors": [{
    "message": "Rate limit exceeded for X",
    "extensions": {
      "code": "RATELIMITED",
      "type": "rate-limit",
      "retryAfter": 60
    }
  }]
}
```

`retryAfter` viene en segundos (documentado como segundos donde aparece). **Caveat (`last_verified:
2026-07-20`)**: no se pudo reconfirmar `retryAfter` en el texto actual de
`https://linear.app/developers/rate-limiting` — no es una garantía documentada oficialmente, puede que
solo aparezca en algunas respuestas de error. Por eso el helper de backoff de abajo trata `retryAfter`
como opcional y cae a exponential backoff si no viene.

### `RATELIMITED` no es el único código de error 400 — tabla completa

`last_verified: 2026-09-05`. Antes de decidir si reintentar, distingue `extensions.code`:

| `extensions.code` | Causa | ¿Reintentar? |
|---|---|---|
| `RATELIMITED` | Cuota horaria agotada (requests o complexity) | **Sí** — backoff con `X-RateLimit-*-Reset` (epoch UTC ms) o exponencial |
| `INPUT_ERROR` | Complejidad de ESA query > 10.000 puntos | **No** — bug de diseño de query (trocear/rediseñar), reintentar da el mismo error siempre |
| `INVALID_INPUT` | Argumento inválido (p. ej. `first` > 250) | **No** — corregir el argumento |
| `GRAPHQL_VALIDATION_FAILED` | Campo/tipo inexistente en el schema | **No** — corregir la query |
| (sin `errors[]`, HTTP 200) | Éxito | — |
| Respuesta vacía o no-JSON | Fallo transitorio de red/transporte | **Sí** — backoff; si la mutation no es idempotente, dedupe por título antes de reintentar |

Detalle completo (con ejemplos de body) en `references/03-graphql-cheatsheet.md#manejo-de-errores`.

## Estrategia de backoff

Para batch jobs — reintenta SIEMPRE `RATELIMITED`; los fallos AMBIGUOS sólo si quien llama declara
la operación idempotente; `INPUT_ERROR`/`INVALID_INPUT`/`GRAPHQL_VALIDATION_FAILED` NUNCA (ver tabla
arriba). La espera pedida por el servidor tiene un TECHO (`MAX_RETRY_AFTER_MS`): por encima, no se
duerme — se relanza el error, porque un `retry-after`/reset sin cota puede dormir el proceso horas.
**La implementación viva y sus casos están en `scripts/linear-client.ts`
(`queryWithRetry`, `FALLOS_AMBIGUOS`, `MAX_RETRY_AFTER_MS`) y su selftest offline; este ejemplo la
ilustra, no la sustituye.**

```typescript
// Los codigos NO salen de `err instanceof TypeError`. Salen de la CLASIFICACION del transporte
// (`classifyGraphQLFailure` en `scripts/linear-client.ts`, que mira `response.text()`): un body
// vacio o no-JSON llega como respuesta HTTP EXITOSA y no lanza NADA, asi que clasificar por lo
// que lanza el cliente HTTP deja fuera justo los dos fallos transitorios mas frecuentes.
const NO_RETRY = new Set(["INPUT_ERROR", "INVALID_INPUT", "GRAPHQL_VALIDATION_FAILED"]);
// AMBIGUOS: la request pudo APLICARSE y perderse la RESPUESTA. Reintentarlos duplica
// `issueCreate`/`commentCreate`, asi que solo se reintentan si quien llama declara idempotencia
// (fail-closed: por defecto, no). `RATELIMITED` no esta aqui — es un rechazo DEFINITIVO del
// servidor, no se aplico nada, y por eso se reintenta siempre. Este conjunto es el mismo
// `FALLOS_AMBIGUOS` de `scripts/linear-client.ts`: si divergen, el ejemplo ensena otra cosa.
const AMBIGUOS = new Set(["EMPTY_BODY", "INVALID_JSON", "UNKNOWN"]);
// Mismo techo que `MAX_RETRY_AFTER_MS` de `scripts/linear-client.ts` — un retry-after/reset
// controlado por el servidor sin cota puede dormir el proceso horas; el techo lo relanza en vez.
const MAX_RETRY_AFTER_MS = 60_000;

async function withRetry<T>(
  fn: () => Promise<T>,
  // Desestructurado CON DEFECTOS POR CAMPO: con `options = { ... }` como valor por defecto del
  // parametro, pasar `{ idempotent: true }` dejaba `maxRetries` en `undefined`, el bucle no
  // corria NI UNA vez (`0 < undefined` es falso) y la llamada moria en "Max retries reached"
  // sin haber intentado nada. Un defecto por objeto entero solo aplica si se omite el objeto entero.
  options: { maxRetries?: number; baseDelayMs?: number; idempotent?: boolean } = {}
): Promise<T> {
  // `idempotent` por defecto FALSE: `issueCreate`, `commentCreate` o `issueBatchCreate` NO se
  // reintentan ante un fallo ambiguo salvo que quien llama pruebe que no quedo escritura.
  const { maxRetries = 5, baseDelayMs = 1000, idempotent = false } = options;

  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try {
      return await fn();
    } catch (err: any) {
      // `err.code` lo pone la clasificacion; `errors[0].extensions.code` es el codigo GraphQL
      // crudo cuando el error llega sin clasificar.
      const code: string | undefined = err?.code ?? err?.errors?.[0]?.extensions?.code;
      if (!code || NO_RETRY.has(code)) throw err; // sin codigo no se reintenta a ciegas

      const isRetryable = code === "RATELIMITED" || (AMBIGUOS.has(code) && idempotent === true);
      if (!isRetryable || attempt === maxRetries - 1) throw err;

      // `retryAfterMs` lo calcula la clasificacion a partir de `retry-after` (segundos) o de
      // `x-ratelimit-*-reset` (epoch ms); `retryAfter` en `extensions` es el fallback heredado.
      const retryAfterMs: number =
        err?.retryAfterMs ?? (err?.errors?.[0]?.extensions?.retryAfter ?? 0) * 1000;
      const delay = retryAfterMs > 0 ? retryAfterMs : baseDelayMs * Math.pow(2, attempt);

      // Techo: por encima de MAX_RETRY_AFTER_MS no se duerme — se relanza de inmediato. Un
      // retry-after/reset sin cota es un valor que CONTROLA el servidor; sin techo, un valor
      // grande (o mal calculado) cuelga el proceso indistinguiblemente de un hang real.
      if (delay > MAX_RETRY_AFTER_MS) {
        console.warn(`Espera pedida ${delay}ms > techo ${MAX_RETRY_AFTER_MS}ms — se relanza, no se duerme (code=${code})`);
        throw err;
      }

      console.warn(`Reintento en ${delay}ms (intento ${attempt + 1}, code=${code})`);
      await new Promise(r => setTimeout(r, delay));
    }
  }
  throw new Error("Max retries reached");
}
```

## Caching local recomendado

Estos datos cambian raramente. Cachéalos para evitar fetches innecesarios:

| Dato | TTL recomendado |
|---|---|
| Lista de teams | 1 hora |
| Lista de labels | 5 min |
| Workflow states del team | 5 min |
| Lista de users | 5 min |
| Initiative IDs | 1 hora |
| Project IDs (active) | 1 min |

Cache en memoria es suficiente para Claude Code (proceso corto). Para servicios persistentes, usar Redis con los TTLs anteriores.

## Buenas prácticas concretas

### Cuando hagas listing

```graphql
# ✗ Mal — pide demasiado por nodo
{ issues(first: 100) { nodes { ...everything... } } }

# ✓ Bien — solo lo necesario, y after-paginas si hace falta
{ issues(first: 50) { nodes { id identifier title state { name } } pageInfo { hasNextPage endCursor } } }
```

### Cuando hagas filtros

```graphql
# ✗ Mal — trae todo y filtra en cliente
{ issues(first: 1000) { nodes { ... } } }

# ✓ Bien — filtra server-side
{ issues(first: 50, filter: { ... }) { nodes { ... } } }
```

### Cuando actualices muchos issues

`last_verified: 2026-09-05`. Linear **SÍ tiene mutations batch**: `issueBatchUpdate(ids, input)` (hasta
50 ids por llamada) e `issueBatchCreate(input: { issues: [...] })` (hasta 50 issues por llamada) — ver
`references/03-graphql-cheatsheet.md#batch--issuebatchupdate--issuebatchcreate` para la forma exacta de
las mutations y el gotcha del wrapper (`IssueBatchCreateInput` es un objeto `{ issues: [...] }`, no un
array pelado — un typing incorrecto de la variable falla en SILENCIO con `{ issues: [] }` vacío, sin
error). Úsalas como vía PRINCIPAL para actualizar/crear en volumen; el throttle de abajo queda solo para
lo que no cabe en un batch de 50 (por ejemplo, inputs distintos por issue que no comparten un único
`IssueUpdateInput`) o para exceder varios lotes de 50 seguidos:

```typescript
// Vía principal: batch nativo, hasta 50 ids por llamada, MISMO input para todos.
// El cliente es el de este skill (`scripts/linear-client.ts`) y el método es
// `queryWithRetry` — el ÚNICO que existe en `LinearMinClient` para esto. Ya trae el
// reintento con backoff y techo (`MAX_RETRY_AFTER_MS`), así que NO se envuelve en
// `withRetry`: sería un reintento sobre otro.
// Un `rawRequest` colgado directamente del cliente NO existe: en `@linear/sdk` vive en
// `client.client` (`LinearGraphQLClient.rawRequest`) y en `LinearMinClient` no existe en absoluto
// — medido contra @linear/sdk 94.0.0, `client.client.rawRequest` es `undefined` y la llamada
// muere con `TypeError` antes de tocar la red.
import { LinearMinClient } from "../scripts/linear-client";
const client = new LinearMinClient({ apiKey: process.env.LINEAR_API_KEY! });

const CHUNK = 50;
for (let i = 0; i < issueIds.length; i += CHUNK) {
  const ids = issueIds.slice(i, i + CHUNK);
  await client.queryWithRetry(BATCH_UPDATE_MUTATION, { ids, input: updates });
}
```

```typescript
// Fallback: cuando cada issue necesita un input DISTINTO (no cabe en un solo issueBatchUpdate)
// o hay que superar varios lotes de 50 con throttle proactivo entre lotes.
// OJO: este bloque usa el SDK `@linear/sdk` (`client.updateIssue` es suyo), NO `LinearMinClient`.
// Se re-declara aquí a propósito: sin esta línea, el cliente en ámbito sería el importado en el
// bloque anterior y `updateIssue` no existe en él.
import { LinearClient } from "@linear/sdk";
const client = new LinearClient({ apiKey: process.env.LINEAR_API_KEY! });
const CONCURRENCY = 5;
const issues = [...];

for (let i = 0; i < issues.length; i += CONCURRENCY) {
  const batch = issues.slice(i, i + CONCURRENCY);
  await Promise.all(batch.map(issue =>
    withRetry(() => client.updateIssue(issue.id, updates))
  ));
  await new Promise(r => setTimeout(r, 200));
}
```

**Benchmark (COMUNIDAD, no verificado por Talent Engine)**: `issueBatchCreate` con N=50 en ~4,7 s vs
~45,9 s para 50 llamadas secuenciales (medianas de 3-5 corridas, workspace real) — fuente:
[PedroHenriqueFernandes, linear/linear#1087](https://github.com/linear/linear/issues/1087),
2026-08-17. Tratar como orden de magnitud, no como SLA garantizado por Linear.

**Pendiente de medir**: el coste en `x-complexity` de `issueBatchUpdate`/`issueBatchCreate` frente a N
mutations individuales no se ha medido en vivo contra el workspace de Talent Engine — antes de recomendar
el batch como sustituto universal del loop-con-throttle en un flujo de producción, ejecutar un caso
representativo y leer el header (ver "No hay un estimador estático fiable — mide, no estimes" más abajo).

### Cuando hagas polling

**No lo hagas**. Usa webhooks (`references/05-webhooks.md`).

Si DE VERDAD necesitas polling (caso raro):

- Mínimo 60s entre polls
- `updatedAt` filter para solo traer lo cambiado

### Cuando uses el token/API directamente

El API impone rate limits **por usuario autenticado** (no por API key: varias keys del mismo usuario comparten la cuota). Si empiezas a ver errores raros tras muchas llamadas seguidas:

1. Esperar 1 minuto
2. Reintentar
3. Si persiste, revisar las cabeceras `X-RateLimit-*` de la respuesta HTTP del API

## No hay un estimador estático fiable — mide, no estimes

`last_verified: 2026-07-17`. Este skill **no incluye** ninguna función `estimateComplexity()` ni helper que
"mida" complejidad ejecutando una query — y a propósito:

- **Una fórmula desde solo el texto de la query no puede ser cota superior fiable.** El coste real depende de
  **valores de variables** (medido: el MISMO documento con `first: $n` cuesta 13 con `n=10` y 301 con `n=250`
  — invisible para cualquier función que solo reciba la `query` como string), de **qué campos son
  connections** (un hecho del **schema**, no del texto), de **fragmentos** (`...FragmentName`), y de
  `first`/`last` por defecto (50) o ausentes. Una heurística simple (aditiva o incluso multiplicativa ingenua)
  puede subestimar por un factor grande frente al coste real medido arriba (11 → 112 → 701 en 3 niveles de
  anidamiento) — un guard que subestima es **peor que ningún guard**, porque da falsa confianza.
- **Un helper que EJECUTA la query para "medir" es un footgun**: recibiría cualquier documento GraphQL
  arbitrario, incluida una **mutation** — que se ejecutaría de verdad (escritura real) mientras aparenta ser
  una medición inocua, además de consumir cuota. No añadir ese helper.

**Qué hacer en su lugar**: `x-complexity` llega en el header de **cada respuesta** de la API. Léelo de una
llamada de **lectura** que de todos modos ya estás haciendo — no fabriques una request extra solo para medir.
Si estás diseñando una query nueva y quieres saber su coste antes de usarla en producción, ejecútala una vez
manualmente (con `curl` o el cliente) contra un caso representativo y lee el header; no hay atajo estático
más seguro que eso.

## Cuotas en perspectiva

Con **3.000.000 de puntos de complexity/hora** (API key) de presupuesto: los listados planos de la raíz
(`issues(first: 50)` mide **2** puntos, medido en vivo) son prácticamente gratis incluso en volumen; el
riesgo real está en **connections anidadas con paginación grande en 2+ niveles**, que escalan
multiplicativamente y pueden acercarse al **cap de 10.000 puntos por query individual (exacto, ver arriba)** (medido: 3 niveles
de `first: 50` anidados ya cuestan 701; con hojas más ricas puede llegar a varios miles). Regla operativa:
mantén `first` pequeño y evita anidar más de 1-2 niveles de connections; si necesitas datos de connections
profundas, prefiere 2+ queries separadas a una sola muy anidada.

## Si estás cerca del límite

1. Acumular operaciones en una cola (BullMQ, simple in-memory)
2. Procesar a velocidad constante (ej: 10 ops/segundo)
3. Si tienes control sobre el flujo, prefiere un job nocturno para batch grandes
