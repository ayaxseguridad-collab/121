#!/usr/bin/env -S npx tsx
/**
 * linear-client.ts — Cliente GraphQL minimal para Linear
 *
 * Uso:
 *   import { LinearMinClient } from "./linear-client";
 *   const client = new LinearMinClient({ apiKey: process.env.LINEAR_API_KEY! });
 *   const issues = await client.query(`{ viewer { id name } }`);
 *
 * Por qué este cliente y no @linear/sdk:
 * - Cero dependencias salvo node fetch (Node 18+)
 * - Control directo sobre headers de rate limit
 * - Fácil de auditar y modificar
 * - Útil para scripts simples y para entender qué pasa por debajo
 *
 * Para apps grandes, prefiere @linear/sdk (más completo, typed).
 *
 * CLI (cada acción imprime el estado del CircuitBreaker al final, ver "Toda acción imprime..."
 * en printHelp() — no existe "circuit-status" standalone, sería siempre un breaker recién creado):
 *   npx tsx linear-client.ts --action whoami
 *   npx tsx linear-client.ts --action list-teams
 *   npx tsx linear-client.ts --action list-issues --team TAL [--state-type started,unstarted]
 *   npx tsx linear-client.ts --action selftest   (offline, sin red ni LINEAR_API_KEY — ver abajo)
 *   npx tsx linear-client.ts --help
 *
 * Clasificación de fallos GraphQL/transporte (`classifyGraphQLFailure`, ver más abajo):
 * distingue qué fallos son transitorios (RATELIMITED, body vacío, body no-JSON — reintentables
 * con backoff) de los que son definitivos (INPUT_ERROR, INVALID_INPUT, GRAPHQL_VALIDATION_FAILED
 * — el caller tiene que corregir la query/input, reintentar no cambia nada). `--action selftest`
 * ejercita los 11 casos frontera de esa función 100% offline (sin red, sin LINEAR_API_KEY).
 */

import * as childProcess from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

// ====================================================================
// Tipos compartidos (usados también por batch-issues.ts / upload-attachment.ts)
// ====================================================================

export enum Priority {
  None = 0,
  Urgent = 1,
  High = 2,
  Medium = 3,
  Low = 4,
}

// Linear no expone esto como un enum GraphQL con nombre propio — WorkflowState.type es un
// String! documentado con estos 7 literales permitidos (verificado contra el schema oficial,
// packages/sdk/src/schema.graphql de linear/linear); este enum es la vista tipada local.
export enum WorkflowStateType {
  Triage = "triage",
  Backlog = "backlog",
  Unstarted = "unstarted",
  Started = "started",
  Completed = "completed",
  Canceled = "canceled", // spelling de Linear: una sola "l" — NO "cancelled"
  Duplicate = "duplicate",
}

export type IssueFilter = {
  team?: { id?: { eq: string }; key?: { eq: string } };
  state?: { type?: { eq?: WorkflowStateType; in?: WorkflowStateType[] }; id?: { eq: string } };
  priority?: { eq?: Priority; in?: Priority[] };
  assignee?: { id?: { eq: string }; null?: boolean };
  label?: { name?: { eq?: string; in?: string[] } };
  title?: { containsIgnoreCase?: string };
  createdAt?: { gte?: string };
  [key: string]: unknown; // Linear soporta and/or anidados arbitrarios — se deja abierto
};

interface LinearClientOptions {
  apiKey?: string;
  accessToken?: string;
  endpoint?: string;
  timeoutMs?: number;
  /** false desactiva el CircuitBreaker por completo (por defecto habilitado). */
  circuitBreaker?: CircuitBreakerOptions | false;
}

interface RateLimitInfo {
  requestsLimit: number;
  requestsRemaining: number;
  requestsReset: number;
  complexityLimit: number;
  complexityRemaining: number;
  complexityReset: number;
  lastComplexity: number;
}

// ====================================================================
// CircuitBreaker (3 estados) + retry genérico
//
// Clasificación de errores (importante para no reintentar mutations no-idempotentes):
// - El breaker SOLO cuenta como fallo los errores de TRANSPORTE (fetch lanza — red/timeout/abort
//   — o HTTP >=500). Una respuesta HTTP 200 con `errors[]` de GraphQL (validación, permisos,
//   RATELIMITED) es una respuesta DEFINITIVA del servidor — Linear procesó/rechazó la request, no
//   hay ambigüedad sobre si una mutation se aplicó — así que NO cuenta como fallo del breaker y
//   NO se reintenta automáticamente aquí (RATELIMITED tiene su propio retry explícito y seguro en
//   queryWithRetry(), ver abajo).
// - Un fallo de transporte (fetch lanzó, o el response nunca llegó) SÍ es ambiguo: no sabemos si
//   el servidor procesó la mutation antes de que la respuesta se perdiera. Por eso el breaker
//   protege con fail-fast (no reintenta la operación por sí solo) — evita seguir bombardeando un
//   backend caído, pero deja la decisión de reintentar una mutation al caller explícito.
// ====================================================================

export enum CircuitBreakerState {
  CLOSED = "closed",
  OPEN = "open",
  HALF_OPEN = "half_open",
}

export interface CircuitBreakerOptions {
  failureThreshold?: number;
  resetTimeoutMs?: number;
  halfOpenMax?: number;
}

export interface CircuitBreakerStats {
  state: CircuitBreakerState;
  failureCount: number;
  lastFailureAt: number | null;
}

export class CircuitBreakerOpenError extends Error {
  constructor() {
    super("CircuitBreaker: OPEN — fallos sostenidos recientes, fail-fast sin llamar a la red");
    this.name = "CircuitBreakerOpenError";
  }
}

export class CircuitBreaker {
  private state: CircuitBreakerState = CircuitBreakerState.CLOSED;
  private failureCount = 0;
  private lastFailureAt: number | null = null;
  private halfOpenSuccesses = 0;
  /** Probes HALF_OPEN admitidos y aún no resueltos — gate de ADMISIÓN, no solo de finalización. */
  private halfOpenInFlight = 0;
  /**
   * Incrementa cada vez que se ABRE una ventana HALF_OPEN nueva. Un probe admitido en la
   * generación N que resuelve DESPUÉS de que ya empezó la generación N+1 (p.ej. un timeout largo
   * mientras el circuito reabrió y volvió a pasar a half-open) es una señal STALE: sin esto, su
   * éxito tardío se contaría como éxito de la generación N+1 (cerrando el circuito con menos
   * probes reales de los que halfOpenMax exige) y su finally decrementaría el contador de
   * en-vuelo de la generación EQUIVOCADA.
   */
  private generation = 0;
  private readonly failureThreshold: number;
  private readonly resetTimeoutMs: number;
  private readonly halfOpenMax: number;

  constructor(options: CircuitBreakerOptions = {}) {
    this.failureThreshold = options.failureThreshold ?? 5;
    this.resetTimeoutMs = options.resetTimeoutMs ?? 30_000;
    this.halfOpenMax = options.halfOpenMax ?? 3;
  }

  async execute<T>(fn: () => Promise<T>): Promise<T> {
    this.maybeTransitionToHalfOpen();

    if (this.state === CircuitBreakerState.OPEN) {
      throw new CircuitBreakerOpenError();
    }

    // Gate de ADMISIÓN en HALF_OPEN: como mucho halfOpenMax probes EN VUELO simultáneamente
    // (no solo halfOpenMax completados) — sin esto, N llamadas concurrentes pasan todas el check
    // de arriba a la vez y bombardean un backend que se está recuperando (thundering herd).
    //
    // admittedInHalfOpen + myGeneration se congelan AQUÍ (antes de llamar a fn) — un probe
    // admitido en HALF_OPEN puede resolver DESPUÉS de que otro probe hermano ya haya cerrado el
    // circuito (o incluso después de que el circuito haya vuelto a abrirse y a pasar a una
    // ventana half-open NUEVA); myGeneration es lo que distingue "hermano de esta misma ventana"
    // de "probe stale de una ventana anterior".
    const admittedInHalfOpen = this.state === CircuitBreakerState.HALF_OPEN;
    const myGeneration = this.generation;
    if (admittedInHalfOpen) {
      if (this.halfOpenInFlight >= this.halfOpenMax) {
        throw new CircuitBreakerOpenError();
      }
      this.halfOpenInFlight++;
    }

    try {
      const result = await fn();
      this.onSuccess(admittedInHalfOpen, myGeneration);
      return result;
    } catch (err) {
      this.onFailure(admittedInHalfOpen, myGeneration);
      throw err;
    } finally {
      // Guard de generación: si ya empezó una ventana half-open nueva, este probe stale NO debe
      // tocar el contador de en-vuelo de la generación actual (ese contador ya se reseteó a 0
      // para la generación nueva en maybeTransitionToHalfOpen()).
      if (admittedInHalfOpen && myGeneration === this.generation && this.halfOpenInFlight > 0) {
        this.halfOpenInFlight--;
      }
    }
  }

  getState(): CircuitBreakerState {
    return this.state;
  }

  getStats(): CircuitBreakerStats {
    return { state: this.state, failureCount: this.failureCount, lastFailureAt: this.lastFailureAt };
  }

  private maybeTransitionToHalfOpen(): void {
    if (
      this.state === CircuitBreakerState.OPEN &&
      this.lastFailureAt !== null &&
      Date.now() - this.lastFailureAt > this.resetTimeoutMs
    ) {
      this.state = CircuitBreakerState.HALF_OPEN;
      this.halfOpenSuccesses = 0;
      this.halfOpenInFlight = 0;
      this.generation++;
    }
  }

  private onSuccess(admittedInHalfOpen: boolean, myGeneration: number): void {
    // Solo cuenta si el circuito SIGUE en HALF_OPEN de la MISMA generación que nos admitió (no
    // si un fallo hermano ya lo reabrió mientras este probe estaba en vuelo, y no si ya empezó
    // una ventana half-open nueva — un éxito stale de la generación anterior no debe cerrar la
    // ventana actual con menos probes reales de los que halfOpenMax exige).
    if (admittedInHalfOpen && myGeneration === this.generation && this.state === CircuitBreakerState.HALF_OPEN) {
      this.halfOpenSuccesses++;
      if (this.halfOpenSuccesses >= this.halfOpenMax) {
        this.state = CircuitBreakerState.CLOSED;
        this.failureCount = 0;
      }
      return;
    }
    if (this.state === CircuitBreakerState.CLOSED) this.failureCount = 0;
  }

  private onFailure(admittedInHalfOpen: boolean, myGeneration: number): void {
    this.failureCount++;
    this.lastFailureAt = Date.now();
    // Un fallo de un probe admitido en la MISMA generación half-open reabre el circuito, incluso
    // si el estado actual ya cambió a CLOSED (un hermano cerró primero) — es señal real de
    // inestabilidad detectada en esa ventana de recuperación, no se descarta por llegar tarde.
    // Un fallo de CUALQUIER probe mientras el estado ACTUAL sigue siendo HALF_OPEN también
    // reabre, sea o no de la generación vigente (evidencia de inestabilidad ahora mismo).
    const isRelevantHalfOpenFailure =
      (admittedInHalfOpen && myGeneration === this.generation) ||
      this.state === CircuitBreakerState.HALF_OPEN;
    if (isRelevantHalfOpenFailure) {
      this.state = CircuitBreakerState.OPEN;
      this.halfOpenSuccesses = 0;
      return;
    }
    if (this.failureCount >= this.failureThreshold) {
      this.state = CircuitBreakerState.OPEN;
    }
  }
}

/**
 * Retry genérico con backoff exponencial para operaciones fuera de GraphQL (p.ej. el PUT a una
 * signed URL en upload-attachment.ts). SOLO usar sobre operaciones idempotentes — un PUT a una
 * signed URL lo es (re-subir los mismos bytes no duplica nada); una mutation GraphQL de creación
 * (issueCreate, commentCreate) NO lo es — no envolver esas con retryWithBackoff.
 */
export async function retryWithBackoff<T>(
  fn: () => Promise<T>,
  options: { maxRetries?: number; baseDelayMs?: number; isRetryable?: (err: unknown) => boolean } = {}
): Promise<T> {
  const maxRetries = options.maxRetries ?? 3;
  const baseDelayMs = options.baseDelayMs ?? 500;
  const isRetryable = options.isRetryable ?? (() => true);

  let lastError: unknown;
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try {
      return await fn();
    } catch (err) {
      lastError = err;
      if (!isRetryable(err) || attempt === maxRetries - 1) throw err;
      await sleep(baseDelayMs * Math.pow(2, attempt));
    }
  }
  throw lastError;
}

// ====================================================================
// Clasificación de fallos GraphQL/transporte
//
// Hechos medidos en vivo (2026-09-05, ver research/02-schema-vivo.md + síntesis del skill):
// - RATELIMITED: HTTP 400, reintentable; retryAfter viene en las cabeceras `retry-after`
//   (segundos) o `x-ratelimit-requests-reset`/`x-ratelimit-complexity-reset` (epoch MS).
// - INPUT_ERROR: HTTP 400, complejidad > 10.000 ("Complexity: 262144. Maximum allowed
//   complexity: 10000."), NO reintentable — el caller tiene que trocear la query.
// - INVALID_INPUT: HTTP 400, p.ej. "first must not be greater than 250.", NO reintentable.
// - GRAPHQL_VALIDATION_FAILED: NO reintentable — la query está mal formada.
// - Body vacío o no-JSON con HTTP 200/5xx: fallo transitorio del backend/proxy, SÍ reintentable.
//   OJO: «reintentable» es la CLASIFICACIÓN, no una autorización — estos fallos son AMBIGUOS (la
//   operación pudo aplicarse y perderse la respuesta), así que `queryWithRetry` solo los reintenta
//   con `idempotent: true` del caller (ver FALLOS_AMBIGUOS).
// - Cualquier otro código de error (o HTTP 200 sin errors[] reconocible): UNKNOWN, reintentable
//   SOLO si el status es transitorio por sí solo (ver isTransientStatus: >=500, o 429 desnudo de
//   un proxy/CDN delante de Linear sin extensions.code), nunca con otro status < 500 (rechazo
//   deliberado del servidor con forma desconocida — reintentar a ciegas es peligroso).
// - El backoff (retryAfterMs o exponencial) tiene un TECHO — ver MAX_RETRY_AFTER_MS — por encima
//   del cual no se duerme: se relanza el error de inmediato en vez de esperar lo que pida el
//   servidor sin límite.
// ====================================================================

export enum LinearErrorCode {
  RATELIMITED = "RATELIMITED",
  INPUT_ERROR = "INPUT_ERROR",
  INVALID_INPUT = "INVALID_INPUT",
  GRAPHQL_VALIDATION_FAILED = "GRAPHQL_VALIDATION_FAILED",
  EMPTY_BODY = "EMPTY_BODY",
  INVALID_JSON = "INVALID_JSON",
  UNKNOWN = "UNKNOWN",
}

/**
 * Fallos cuyo resultado en el servidor es AMBIGUO: la request pudo llegar a aplicarse y lo que se
 * perdió fue la RESPUESTA. Un body vacío, un body no-JSON o un 5xx no prueban que la mutation no
 * corriera. Reintentarlos duplica `issueCreate`/`commentCreate`, así que `queryWithRetry` solo los
 * reintenta cuando el caller DECLARA que la operación es idempotente (fail-closed: por defecto, no).
 * `RATELIMITED` NO está aquí: es un rechazo DEFINITIVO del servidor —no se aplicó nada— y por eso
 * se reintenta siempre.
 */
const FALLOS_AMBIGUOS: ReadonlySet<LinearErrorCode> = new Set([
  LinearErrorCode.EMPTY_BODY,
  LinearErrorCode.INVALID_JSON,
  LinearErrorCode.UNKNOWN,
]);


export interface ClassifiedGraphQLFailure {
  code: LinearErrorCode;
  retryable: boolean;
  message: string;
  retryAfterMs?: number;
}

/**
 * ¿El status HTTP, POR SÍ SOLO, indica un fallo transitorio? La regla era `status >= 500`, y su
 * FORMA era correcta: el conjunto estaba incompleto. Faltaba **429**, el único código que
 * significa literalmente «reinténtalo luego».
 *
 * Importa el caso del 429 que NO viene del GraphQL de Linear: un proxy o CDN delante de la API
 * devuelve 429 sin `extensions.code: "RATELIMITED"`, así que la clasificación caía en UNKNOWN y,
 * con la regla vieja, en `retryable: false` — fallo duro sobre un rate-limit puramente transitorio.
 */
function isTransientStatus(status: number): boolean {
  return status >= 500 || status === 429;
}

/**
 * TECHO del backoff. Un `retry-after` (o un `x-ratelimit-*-reset`) es un valor CONTROLADO POR EL
 * SERVIDOR: sin cota, un `retry-after: 86400` duerme el proceso 24 h y un reset mal calculado lo
 * cuelga indefinidamente. Un proceso dormido es indistinguible de uno colgado.
 *
 * El techo NO RECORTA: DECIDE. Por encima de él no se duerme —se relanza el error ya
 * clasificado— porque recortar sería seguir esperando por orden del servidor, solo que menos.
 * `resolveRetryAfterMs` devuelve a propósito el valor REAL, sin cota: si lo recortara ahí, la
 * comprobación de abajo no podría dispararse nunca y el techo sería una guarda vacía.
 *
 * El techo tampoco basta por sí solo: sin contador se reintentaría indefinidamente por debajo de
 * él. El contador es `maxRetries` — las dos piezas van juntas. Ortogonal al gate
 * `FALLOS_AMBIGUOS`/`idempotent` de arriba: ese decide SI se reintenta un fallo ambiguo; este
 * decide si CUALQUIER espera pedida por el servidor es razonable de dormir.
 */
export const MAX_RETRY_AFTER_MS = 60_000;

/**
 * Resuelve cuánto esperar antes de reintentar un RATELIMITED, en este orden de preferencia:
 * 1. cabecera `retry-after` (segundos) — la más específica, la manda Linear para ESTE rechazo.
 * 2. `x-ratelimit-requests-reset` / `x-ratelimit-complexity-reset` (epoch MS) — se toma el mayor
 *    de los dos presentes, porque hay que esperar a que AMBOS budgets se repongan.
 * 3. `extensions.retryAfter` del propio error GraphQL (segundos) — fallback legado si el caller
 *    no pasó cabeceras.
 */
function resolveRetryAfterMs(
  headers: Record<string, string> | undefined,
  extensions: Record<string, unknown> | undefined
): number | undefined {
  const legacyFallback = (): number | undefined => {
    const seconds = extensions?.retryAfter;
    return typeof seconds === "number" ? Math.max(0, seconds * 1000) : undefined;
  };

  if (!headers) return legacyFallback();

  const lower: Record<string, string> = {};
  for (const [k, v] of Object.entries(headers)) lower[k.toLowerCase()] = v;

  if (lower["retry-after"] !== undefined) {
    const seconds = parseFloat(lower["retry-after"]);
    if (!isNaN(seconds)) return Math.max(0, seconds * 1000);
  }

  const now = Date.now();
  const resetsMs = ["x-ratelimit-requests-reset", "x-ratelimit-complexity-reset"]
    .map((h) => lower[h])
    .filter((v): v is string => v !== undefined)
    .map((v) => parseInt(v, 10))
    .filter((n) => !isNaN(n));

  if (resetsMs.length > 0) return Math.max(0, Math.max(...resetsMs) - now);

  return legacyFallback();
}

/**
 * Clasifica un fallo GraphQL/transporte a partir del body CRUDO (sin parsear) y el status HTTP.
 * Función PURA — no toca red ni estado — para poder testearla offline (`--action selftest`).
 *
 * @param status - código HTTP de la respuesta.
 * @param rawBody - body de la respuesta SIN parsear (string; puede estar vacío o no ser JSON).
 * @param headers - cabeceras de la respuesta (claves en cualquier capitalización), opcional —
 *   solo se usa para calcular `retryAfterMs` de un RATELIMITED con más precisión.
 */
export function classifyGraphQLFailure(
  status: number,
  rawBody: string,
  headers?: Record<string, string>
): ClassifiedGraphQLFailure {
  const trimmed = (rawBody ?? "").trim();

  if (trimmed === "") {
    return {
      code: LinearErrorCode.EMPTY_BODY,
      retryable: true,
      message: `HTTP ${status} con body vacío — probable fallo transitorio del backend/proxy de Linear.`,
    };
  }

  let parsed: any;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return {
      code: LinearErrorCode.INVALID_JSON,
      retryable: true,
      message:
        `HTTP ${status} con body no-JSON (primeros 80 chars: "${trimmed.slice(0, 80)}") — ` +
        `probable fallo transitorio (proxy/WAF/página de error HTML).`,
    };
  }

  const gqlErrors: any[] = Array.isArray(parsed?.errors) ? parsed.errors : [];
  if (gqlErrors.length > 0) {
    const first = gqlErrors[0];
    const rawCode: string | undefined = first?.extensions?.code;
    const userMessage: string =
      first?.extensions?.userPresentableMessage || first?.message || "Linear GraphQL error";

    switch (rawCode) {
      case "RATELIMITED":
        return {
          code: LinearErrorCode.RATELIMITED,
          retryable: true,
          message: userMessage,
          retryAfterMs: resolveRetryAfterMs(headers, first?.extensions),
        };
      case "INPUT_ERROR":
        return { code: LinearErrorCode.INPUT_ERROR, retryable: false, message: userMessage };
      case "INVALID_INPUT":
        return { code: LinearErrorCode.INVALID_INPUT, retryable: false, message: userMessage };
      case "GRAPHQL_VALIDATION_FAILED":
        return { code: LinearErrorCode.GRAPHQL_VALIDATION_FAILED, retryable: false, message: userMessage };
      default:
        // Código desconocido: solo se asume transitorio si el status también lo sugiere (5xx o
        // 429 desnudo — ver isTransientStatus). Un HTTP 200 con errors[] de forma rara es un
        // rechazo definitivo del servidor. `retryAfterMs` se propaga igual que en RATELIMITED —
        // un 429 de un proxy/CDN (código desconocido, sin extensions.code: RATELIMITED) puede
        // traer la MISMA cabecera retry-after/x-ratelimit-*-reset; no propagarla degrada a
        // backoff exponencial ciego cuando el servidor ya dijo cuánto esperar.
        return {
          code: LinearErrorCode.UNKNOWN,
          retryable: isTransientStatus(status),
          message: userMessage,
          retryAfterMs: resolveRetryAfterMs(headers, first?.extensions),
        };
    }
  }

  // JSON válido, sin errors[] reconocible como array no vacío: no debería llegar aquí en el
  // camino feliz (query() ya habría devuelto json.data antes de clasificar), pero si un caller
  // externo invoca classifyGraphQLFailure directamente sobre una respuesta así, el status decide.
  // Sin gqlErrors no hay `extensions` de los que leer un `retryAfter` legado, pero las cabeceras
  // (retry-after / x-ratelimit-*-reset) siguen siendo válidas si vinieron — mismo motivo que arriba.
  return {
    code: LinearErrorCode.UNKNOWN,
    retryable: isTransientStatus(status),
    message: `HTTP ${status} sin errors[] reconocible.`,
    retryAfterMs: resolveRetryAfterMs(headers, undefined),
  };
}

export class LinearMinClient {
  private endpoint: string;
  private headers: Record<string, string>;
  private timeoutMs: number;
  private breaker: CircuitBreaker | null;
  public lastRateLimit: RateLimitInfo | null = null;

  constructor(opts: LinearClientOptions) {
    if (!opts.apiKey && !opts.accessToken) {
      throw new Error("LinearMinClient: provide apiKey or accessToken");
    }

    this.endpoint = opts.endpoint || "https://api.linear.app/graphql";
    this.timeoutMs = opts.timeoutMs ?? 30000;
    this.headers = {
      "Content-Type": "application/json",
    };

    if (opts.apiKey) {
      // Personal API keys NO usan "Bearer" — peculiaridad de Linear
      this.headers["Authorization"] = opts.apiKey;
    } else if (opts.accessToken) {
      this.headers["Authorization"] = `Bearer ${opts.accessToken}`;
    }

    this.breaker = opts.circuitBreaker === false ? null : new CircuitBreaker(opts.circuitBreaker || {});
  }

  /**
   * Ejecuta una query/mutation GraphQL.
   * Lanza `LinearGraphQLError` si la respuesta contiene errors[], si el body llegó vacío o si
   * no es JSON válido (proxy/WAF transitorio) — en los tres casos el error lleva `.classification`
   * (`classifyGraphQLFailure`) con `retryable` para que `queryWithRetry` decida si reintentar.
   */
  async query<T = any>(query: string, variables?: Record<string, any>): Promise<T> {
    const { rawBody, status, headers } = this.breaker
      ? await this.breaker.execute(() => this.transportCall(query, variables))
      : await this.transportCall(query, variables);

    let parsed: any;
    try {
      parsed = rawBody.trim() === "" ? undefined : JSON.parse(rawBody);
    } catch {
      parsed = undefined;
    }

    // ÉXITO = HTTP 2xx **Y** `data` presente. Todo lo demás LANZA, sin excepciones:
    // 400, 401, 403 y 429 NO son casos especiales — son instancias de «no es 2xx-con-data».
    // Antes esta rama aceptaba cualquier status por debajo de 500, así que un 401/403 cuyo body
    // no trajera `errors[]` —que es justo lo que devuelve Linear ante un token caducado— se
    // colaba como éxito y devolvía `undefined` al caller: un rechazo de autenticación se leía
    // como una consulta que no encontró nada. Fallo silencioso, sin excepción que lo delate.
    const isHttpOk = status >= 200 && status <= 299;
    const hasNoGraphQLErrors =
      !!parsed && (!parsed.errors || (Array.isArray(parsed.errors) && parsed.errors.length === 0));
    const hasData = !!parsed && parsed.data !== undefined && parsed.data !== null;

    if (isHttpOk && hasNoGraphQLErrors && hasData) {
      return parsed.data as T;
    }

    // Fallo a nivel de aplicación (body vacío, JSON inválido, o errors[] de GraphQL) —
    // classifyGraphQLFailure re-parsea el rawBody una única fuente de verdad para la
    // clasificación, así query()/queryWithRetry nunca divergen de --action selftest.
    const classification = classifyGraphQLFailure(status, rawBody, headers);
    const errors = Array.isArray(parsed?.errors) ? parsed.errors : [];
    throw new LinearGraphQLError(errors, status, classification);
  }

  /** Estado actual del CircuitBreaker (o null si está deshabilitado) — refleja ESTE cliente/sesión. */
  circuitStatus(): CircuitBreakerStats | null {
    return this.breaker ? this.breaker.getStats() : null;
  }

  /** Llamada de transporte pura — SOLO lanza en fallo de red/timeout/HTTP >=500 (cuenta para el breaker). */
  private async transportCall(
    query: string,
    variables?: Record<string, any>
  ): Promise<{ rawBody: string; status: number; headers: Record<string, string> }> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.timeoutMs);

    let response: Response;
    try {
      response = await fetch(this.endpoint, {
        method: "POST",
        headers: this.headers,
        body: JSON.stringify({ query, variables }),
        signal: controller.signal,
      });
    } finally {
      clearTimeout(timeout);
    }

    this.captureRateLimit(response.headers);

    // Leer como texto SIEMPRE (nunca response.json() directo): un body vacío o no-JSON (proxy/WAF
    // transitorio) lanzaría un SyntaxError sin clasificar aquí — query() hace el parseo seguro y
    // clasifica con classifyGraphQLFailure si hace falta.
    const rawBody = await response.text();
    const headers: Record<string, string> = {};
    response.headers.forEach((value, key) => {
      headers[key.toLowerCase()] = value;
    });

    // Un 5xx se lanza DESDE AQUÍ (dentro de breaker.execute) para que el CircuitBreaker lo
    // cuente como fallo de infraestructura; lleva la clasificación (retryable) para que
    // queryWithRetry aplique el backoff. Los 4xx y los 200 con errors[] los clasifica query().
    if (response.status >= 500) {
      throw new LinearGraphQLError([], response.status, classifyGraphQLFailure(response.status, rawBody, headers));
    }

    return { rawBody, status: response.status, headers };
  }

  /**
   * Ejecuta query con retry automático SOLO para fallos clasificados como retryable
   * (`classifyGraphQLFailure` — RATELIMITED, EMPTY_BODY, INVALID_JSON, UNKNOWN con HTTP >=500).
   * Un fallo NO retryable (INPUT_ERROR, INVALID_INPUT, GRAPHQL_VALIDATION_FAILED, UNKNOWN con
   * HTTP <500) se relanza inmediatamente en el primer intento — reintentar no lo arregla y solo
   * quema cuota/tiempo.
   * Backoff: respeta `retryAfterMs` si la clasificación lo calculó (RATELIMITED con cabeceras),
   * si no exponencial.
   * Mutations, fail-closed: los fallos AMBIGUOS (`EMPTY_BODY`, `INVALID_JSON`, `UNKNOWN` con HTTP
   * >=500) NO se reintentan salvo que el caller pase `idempotent: true`. Un body vacío o un 5xx no
   * prueban que la mutation no se aplicara: pudo aplicarse y perderse la respuesta, y reintentar
   * duplicaría un `issueCreate` o un `commentCreate`. `RATELIMITED` sí se reintenta siempre — es un
   * rechazo DEFINITIVO del servidor, no llegó a aplicar nada.
   * Por defecto `idempotent` es `false`: la seguridad no depende de que el caller se acuerde.
   */
  async queryWithRetry<T = any>(
    query: string,
    variables?: Record<string, any>,
    options: { maxRetries?: number; baseDelayMs?: number; idempotent?: boolean } = {}
  ): Promise<T> {
    const maxRetries = options.maxRetries ?? 5;
    const baseDelayMs = options.baseDelayMs ?? 1000;
    const idempotent = options.idempotent ?? false;

    let lastError: any;

    for (let attempt = 0; attempt < maxRetries; attempt++) {
      try {
        return await this.query<T>(query, variables);
      } catch (err: any) {
        lastError = err;

        const classification: ClassifiedGraphQLFailure | undefined =
          err instanceof LinearGraphQLError ? err.classification : undefined;

        if (!classification?.retryable || attempt === maxRetries - 1) {
          throw err;
        }

        // Puerta fail-closed: un fallo ambiguo no se reintenta si el caller no declaró la
        // operación idempotente. Preferimos un error visible a una issue o un comentario duplicado.
        if (FALLOS_AMBIGUOS.has(classification.code) && !idempotent) {
          console.warn(
            `[linear-client] ${classification.code} es AMBIGUO (la operación pudo aplicarse): no se ` +
              `reintenta porque el caller no declaró idempotent:true. Verifica el estado antes de repetir.`
          );
          throw err;
        }

        // Espera al menos el backoff exponencial aunque las cabeceras de reset ya hayan vencido
        // (retryAfterMs=0) — evita martillear la API justo tras un RATELIMITED.
        const delayMs = Math.max(classification.retryAfterMs ?? 0, baseDelayMs * Math.pow(2, attempt));

        // Por ENCIMA del techo no se duerme: se relanza el error ya clasificado, de inmediato.
        // Recortar y dormir el techo sería seguir esperando por orden del servidor, solo que
        // menos; y un proceso dormido es indistinguible de uno colgado. El caller decide qué
        // hacer con un rate-limit que pide más de un minuto — este cliente no lo decide por él.
        // El contador (`maxRetries`) acota CUÁNTAS esperas; el techo acota si se espera siquiera.
        if (delayMs > MAX_RETRY_AFTER_MS) {
          console.warn(
            `[linear-client] ${classification.code}. Espera pedida ${delayMs}ms > techo ` +
              `${MAX_RETRY_AFTER_MS}ms — no se duerme; se relanza el error clasificado.`
          );
          throw err;
        }

        console.warn(
          `[linear-client] ${classification.code}. Retrying in ${delayMs}ms (attempt ${attempt + 1}/${maxRetries})`
        );

        await sleep(delayMs);
      }
    }

    throw lastError;
  }

  /**
   * Pagina automáticamente sobre cualquier connection.
   * El callback recibe cada página; debes pasar la query con $after $first.
   */
  async paginate<NodeType = any>(
    query: string,
    variables: Record<string, any>,
    extractConnection: (data: any) => {
      nodes: NodeType[];
      pageInfo: { hasNextPage: boolean; endCursor: string | null };
    },
    options: { batchSize?: number; maxPages?: number; onPage?: (nodes: NodeType[]) => void } = {}
  ): Promise<NodeType[]> {
    const batchSize = options.batchSize ?? 50;
    const maxPages = options.maxPages ?? 1000;
    const all: NodeType[] = [];
    let after: string | null = null;
    let pageNum = 0;

    while (true) {
      pageNum++;
      if (pageNum > maxPages) {
        throw new Error(`paginate: hit maxPages ${maxPages}`);
      }

      // Lectura pura: repetir una página no muta nada, así que sí se reintentan los ambiguos.
      const data = await this.queryWithRetry(
        query,
        { ...variables, first: batchSize, after },
        { idempotent: true }
      );

      const conn = extractConnection(data);
      all.push(...conn.nodes);

      if (options.onPage) options.onPage(conn.nodes);

      if (!conn.pageInfo.hasNextPage) break;
      after = conn.pageInfo.endCursor;

      // Throttle ligero entre páginas
      await sleep(100);
    }

    return all;
  }

  private captureRateLimit(headers: Headers): void {
    const get = (k: string) => {
      const v = headers.get(k);
      return v ? parseInt(v, 10) : 0;
    };

    this.lastRateLimit = {
      requestsLimit: get("X-RateLimit-Requests-Limit"),
      requestsRemaining: get("X-RateLimit-Requests-Remaining"),
      requestsReset: get("X-RateLimit-Requests-Reset"),
      complexityLimit: get("X-RateLimit-Complexity-Limit"),
      complexityRemaining: get("X-RateLimit-Complexity-Remaining"),
      complexityReset: get("X-RateLimit-Complexity-Reset"),
      lastComplexity: get("X-Complexity"),
    };
  }
}

export class LinearGraphQLError extends Error {
  public errors: any[];
  public statusCode: number;
  /** Clasificación (`classifyGraphQLFailure`) — código + retryable + mensaje + retryAfterMs. */
  public classification: ClassifiedGraphQLFailure;

  constructor(errors: any[], statusCode: number, classification?: ClassifiedGraphQLFailure) {
    // Si el caller no pasa la clasificación ya calculada (compat hacia atrás para código que
    // construye este error a mano), se recalcula re-serializando errors — mismo resultado que
    // classifyGraphQLFailure(statusCode, rawBody) habría dado sobre el body original.
    const computed = classification ?? classifyGraphQLFailure(statusCode, JSON.stringify({ errors }));
    const base = errors[0]?.extensions?.userPresentableMessage || errors[0]?.message || computed.message;
    super(`[${computed.code}] ${base}`);
    this.name = "LinearGraphQLError";
    this.errors = errors;
    this.statusCode = statusCode;
    this.classification = computed;
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Resultado de resolver la clave de Linear. Los mensajes de error solo nombran rutas y variables, nunca la clave. */
export type ApiKeyResolution = { ok: true; key: string } | { ok: false; message: string };

/** Lee LINEAR_API_KEY de un fichero de entorno sin ejecutarlo; undefined si falta o está vacía. */
function readApiKeyFromFile(file: string): string | undefined {
  const match = fs.readFileSync(file, "utf8").match(/^LINEAR_API_KEY=(.+)$/m);
  const key = match ? match[1].trim() : "";
  return key === "" ? undefined : key;
}

function isRegularFile(file: string): boolean {
  try {
    return fs.statSync(file).isFile();
  } catch {
    return false;
  }
}

/**
 * Resuelve la clave de Linear (mismo orden que el bash de SKILL.md § Autenticación):
 *   1. LINEAR_API_KEY ya exportada en el entorno;
 *   2. si TA_OPERATION_ENV está definida y no vacía, el fichero al que apunta y SOLO ese: si falta
 *      o no trae LINEAR_API_KEY= es un error claro, jamás una caída en silencio a la raíz del repo;
 *   3. si no, .env.local en la raíz del repo.
 * Sin ninguna fuente válida devuelve un error: nunca una clave vacía que acabe en un 401 mudo.
 * No ejecuta ningún fichero ni lo expone en logs. `repoRoot` permite probarlo sin git.
 */
export function resolveApiKey(env: NodeJS.ProcessEnv = process.env, repoRoot?: string): ApiKeyResolution {
  if (env.LINEAR_API_KEY) return { ok: true, key: env.LINEAR_API_KEY };

  const operationEnv = env.TA_OPERATION_ENV;
  if (operationEnv !== undefined && operationEnv !== "") {
    if (!isRegularFile(operationEnv)) {
      return {
        ok: false,
        message: `TA_OPERATION_ENV apunta a ${operationEnv}, que no existe o no es un fichero: ahí debe estar LINEAR_API_KEY=<clave>`,
      };
    }
    let key: string | undefined;
    try {
      key = readApiKeyFromFile(operationEnv);
    } catch {
      return { ok: false, message: `no se pudo leer ${operationEnv} (apuntado por TA_OPERATION_ENV)` };
    }
    if (!key) {
      return {
        ok: false,
        message: `${operationEnv} (apuntado por TA_OPERATION_ENV) no tiene LINEAR_API_KEY=<clave>`,
      };
    }
    return { ok: true, key };
  }

  let root = repoRoot;
  if (root === undefined) {
    try {
      root = childProcess
        .execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] })
        .trim();
    } catch {
      return {
        ok: false,
        message:
          "no hay LINEAR_API_KEY en el entorno, TA_OPERATION_ENV no está definida y el directorio actual no está en un repositorio git donde buscar .env.local",
      };
    }
  }
  const envPath = path.join(root, ".env.local");
  if (!isRegularFile(envPath)) {
    return {
      ok: false,
      message: `no hay LINEAR_API_KEY en el entorno, TA_OPERATION_ENV no está definida y no existe ${envPath}`,
    };
  }
  let key: string | undefined;
  try {
    key = readApiKeyFromFile(envPath);
  } catch {
    return { ok: false, message: `no se pudo leer ${envPath}` };
  }
  if (!key) {
    return {
      ok: false,
      message: `${envPath} no tiene LINEAR_API_KEY=<clave> (y LINEAR_API_KEY / TA_OPERATION_ENV no están definidas)`,
    };
  }
  return { ok: true, key };
}

/** Como resolveApiKey, pero lanza un Error con el mensaje claro si no hay clave. Lo reutilizan los demás scripts del skill. */
export function loadApiKey(env: NodeJS.ProcessEnv = process.env, repoRoot?: string): string {
  const resolved = resolveApiKey(env, repoRoot);
  if (!resolved.ok) throw new Error(resolved.message);
  return resolved.key;
}

// ====================================================================
// Helpers de uso común
// ====================================================================

export const ME_QUERY = `
  query Me {
    viewer { id name email displayName }
  }
`;

export const TEAMS_QUERY = `
  query Teams {
    teams(first: 20) {
      nodes { id name key cyclesEnabled cycleDuration }
    }
  }
`;

export const ISSUE_BY_ID_QUERY = `
  query Issue($id: String!) {
    issue(id: $id) {
      id identifier title description priority estimate
      state { name type }
      assignee { displayName email }
      project { name }
      cycle { number }
      labels { nodes { id name } }
      url branchName
    }
  }
`;

export const ISSUES_PAGE_QUERY = `
  query IssuesPage($filter: IssueFilter, $first: Int, $after: String) {
    issues(filter: $filter, first: $first, after: $after, orderBy: updatedAt) {
      nodes {
        id identifier title priority estimate
        state { name type }
        assignee { displayName }
        labels { nodes { name } }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
`;

// ====================================================================
// CLI
// ====================================================================

interface CliArgs {
  action?: string;
  team?: string;
  stateType?: string[];
  help: boolean;
}

function parseArgs(argv: string[]): CliArgs {
  const args: CliArgs = { help: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const next = argv[i + 1];
    if (arg === "--selftest") {
      args.action = "selftest";
      continue;
    }
    if (arg === "--help" || arg === "-h") {
      args.help = true;
    } else if (arg === "--action") {
      args.action = next;
      i++;
    } else if (arg === "--team") {
      args.team = next;
      i++;
    } else if (arg === "--state-type") {
      args.stateType = next.split(",");
      i++;
    }
  }
  return args;
}

function printHelp(): void {
  console.log(`Uso: npx tsx linear-client.ts --action <whoami|list-teams|list-issues|selftest> [opciones]

Acciones:
  whoami                        Muestra el usuario autenticado (viewer)
  list-teams                    Lista los teams del workspace
  list-issues --team <KEY>      Lista issues activas del team (unstarted+started)
    [--state-type a,b,c]        Filtra por WorkflowStateType (default: unstarted,started)
  selftest                      Corre 21 casos offline (11 de classifyGraphQLFailure (RATELIMITED,
                                 INPUT_ERROR, INVALID_INPUT, GRAPHQL_VALIDATION_FAILED, body
                                 vacío, body no-JSON, HTTP 200 con código desconocido, HTTP 502
                                 con body vacío, HTTP 429 desnudo, y las 2 rutas UNKNOWN que
                                 propagan retryAfterMs), 2 de la puerta de idempotencia y 1 del
                                 techo MAX_RETRY_AFTER_MS de queryWithRetry, más 7 de la
                                 resolución de la clave (LINEAR_API_KEY > TA_OPERATION_ENV >
                                 .env.local de la raíz del repo), y sale 0/1.
                                 No toca red ni LINEAR_API_KEY.

Clave de Linear (whoami, list-teams, list-issues), por este orden:
  1. LINEAR_API_KEY exportada;
  2. si TA_OPERATION_ENV está definida y no vacía, el fichero al que apunta y SOLO ese
     (si falta o no trae LINEAR_API_KEY= es un error con la ruta, no se mira la raíz);
  3. .env.local en la raíz del repo.
Sin ninguna fuente válida sale con error claro, sin llamada de red.

Toda acción imprime al final el estado del CircuitBreaker DE ESA MISMA sesión/cliente
(no existe "circuit-status" standalone: un proceso CLI de un solo shot siempre arrancaría
con un breaker recién creado — closed, 0 fallos — así que un comando aislado no sería un
diagnóstico real; el estado solo es significativo tras al menos una llamada en el mismo
proceso). selftest es la única excepción: no llama a dispatch(), así que no imprime breaker.

Opciones globales:
  --help, -h                    Muestra esta ayuda y sale (no toca red ni LINEAR_API_KEY)`);
}

/**
 * Ejercita classifyGraphQLFailure con los 11 casos frontera del brief TAL-5432 (incluido el 429
 * desnudo y las 2 rutas UNKNOWN que propagan retryAfterMs), la puerta de idempotencia de
 * queryWithRetry (2 casos), su techo MAX_RETRY_AFTER_MS (1 caso) y la resolución de la clave de
 * Linear (7 casos, con ficheros sintéticos y claves falsas), 100% offline.
 * Imprime PASS/FAIL por caso y el resumen `SELFTEST: PASS=n FAIL=m`. No toca red ni LINEAR_API_KEY.
 */
async function runSelftest(): Promise<number> {
  let pass = 0;
  let failCount = 0;

  const caso = (nombre: string, fn: () => void) => {
    try {
      fn();
      pass++;
      console.log(`PASS ${nombre}`);
    } catch (e) {
      failCount++;
      console.error(`FAIL ${nombre}: ${e instanceof Error ? e.message : e}`);
    }
  };
  const assert = (cond: boolean, msg: string) => {
    if (!cond) throw new Error(msg);
  };

  const casoAsync = async (nombre: string, fn: () => Promise<void>) => {
    try {
      await fn();
      pass++;
      console.log(`PASS ${nombre}`);
    } catch (e) {
      failCount++;
      console.error(`FAIL ${nombre}: ${e instanceof Error ? e.message : e}`);
    }
  };

  caso("RATELIMITED → retryable, retryAfterMs desde cabecera retry-after: 7", () => {
    const body = JSON.stringify({
      errors: [{ message: "Too many requests", extensions: { code: "RATELIMITED" } }],
    });
    const r = classifyGraphQLFailure(400, body, { "retry-after": "7" });
    assert(r.code === LinearErrorCode.RATELIMITED, `code=${r.code}`);
    assert(r.retryable === true, "debe ser retryable");
    assert(r.retryAfterMs === 7000, `retryAfterMs=${r.retryAfterMs} (esperado 7000)`);
  });

  caso("INPUT_ERROR (complejidad 262144 > 10000) → NO retryable", () => {
    const body = JSON.stringify({
      errors: [
        {
          message: "The query is too complex. Complexity: 262144. Maximum allowed complexity: 10000.",
          extensions: { code: "INPUT_ERROR" },
        },
      ],
    });
    const r = classifyGraphQLFailure(400, body);
    assert(r.code === LinearErrorCode.INPUT_ERROR, `code=${r.code}`);
    assert(r.retryable === false, "NO debe reintentarse");
  });

  caso("INVALID_INPUT (first > 250) → NO retryable", () => {
    const body = JSON.stringify({
      errors: [{ message: "first must not be greater than 250.", extensions: { code: "INVALID_INPUT" } }],
    });
    const r = classifyGraphQLFailure(400, body);
    assert(r.code === LinearErrorCode.INVALID_INPUT, `code=${r.code}`);
    assert(r.retryable === false, "NO debe reintentarse");
  });

  caso("GRAPHQL_VALIDATION_FAILED → NO retryable", () => {
    const body = JSON.stringify({
      errors: [{ message: "Cannot query field X", extensions: { code: "GRAPHQL_VALIDATION_FAILED" } }],
    });
    const r = classifyGraphQLFailure(400, body);
    assert(r.code === LinearErrorCode.GRAPHQL_VALIDATION_FAILED, `code=${r.code}`);
    assert(r.retryable === false, "NO debe reintentarse");
  });

  caso("body vacío → EMPTY_BODY retryable", () => {
    const r = classifyGraphQLFailure(200, "");
    assert(r.code === LinearErrorCode.EMPTY_BODY, `code=${r.code}`);
    assert(r.retryable === true, "debe ser retryable");
  });

  caso("body <html> (no-JSON) → INVALID_JSON retryable", () => {
    const r = classifyGraphQLFailure(200, "<html>");
    assert(r.code === LinearErrorCode.INVALID_JSON, `code=${r.code}`);
    assert(r.retryable === true, "debe ser retryable");
  });

  caso("HTTP 200 con errors[] de código desconocido → UNKNOWN NO retryable", () => {
    const body = JSON.stringify({ errors: [{ message: "algo raro", extensions: { code: "SOME_NEW_CODE" } }] });
    const r = classifyGraphQLFailure(200, body);
    assert(r.code === LinearErrorCode.UNKNOWN, `code=${r.code}`);
    assert(r.retryable === false, "HTTP 200 no debe reintentarse por defecto");
  });

  caso("HTTP 502 con body vacío → retryable (transitorio)", () => {
    const r = classifyGraphQLFailure(502, "");
    assert(r.code === LinearErrorCode.EMPTY_BODY, `code=${r.code}`);
    assert(r.retryable === true, "debe ser retryable");
  });

  caso("HTTP 429 desnudo (proxy/CDN, sin extensions.code RATELIMITED) → UNKNOWN retryable", () => {
    // JSON válido sin errors[] reconocible — el caso de un proxy que devuelve 429 sin pasar por
    // el GraphQL de Linear (así que no lleva extensions.code: "RATELIMITED"). Antes de
    // isTransientStatus, solo `status >= 500` era transitorio y este 429 caía en NO retryable.
    const r = classifyGraphQLFailure(429, JSON.stringify({ data: null }));
    assert(r.code === LinearErrorCode.UNKNOWN, `code=${r.code}`);
    assert(r.retryable === true, "un 429 desnudo debe tratarse como transitorio");
  });

  caso("HTTP 429 desnudo con cabecera retry-after → UNKNOWN retryable CONSERVA retryAfterMs", () => {
    // Bug real (CR-CLI, bounce sobre #2408): las DOS ramas UNKNOWN (esta — sin errors[] — y la
    // default del switch de abajo) clasificaban el 429 como retryable pero NO propagaban
    // retryAfterMs, así que queryWithRetry ignoraba la cabecera real del servidor y caía a
    // backoff exponencial ciego. Un proxy/CDN puede mandar retry-after en un 429 SIN pasar por
    // el GraphQL de Linear (sin errors[] en absoluto).
    const r = classifyGraphQLFailure(429, JSON.stringify({ data: null }), { "retry-after": "12" });
    assert(r.code === LinearErrorCode.UNKNOWN, `code=${r.code}`);
    assert(r.retryable === true, "debe ser retryable");
    assert(r.retryAfterMs === 12000, `retryAfterMs=${r.retryAfterMs} (esperado 12000)`);
  });

  caso("HTTP 429 con errors[] de código desconocido + retry-after → UNKNOWN retryable CONSERVA retryAfterMs", () => {
    // Misma regresión que el caso anterior, pero por la rama `default` del switch (SÍ hay
    // errors[], con un extensions.code que no es ninguno de los 4 reconocidos).
    const body = JSON.stringify({
      errors: [{ message: "rate limited by edge", extensions: { code: "EDGE_THROTTLED" } }],
    });
    const r = classifyGraphQLFailure(429, body, { "retry-after": "5" });
    assert(r.code === LinearErrorCode.UNKNOWN, `code=${r.code}`);
    assert(r.retryable === true, "debe ser retryable");
    assert(r.retryAfterMs === 5000, `retryAfterMs=${r.retryAfterMs} (esperado 5000)`);
  });

  // ── Puerta de idempotencia de queryWithRetry ────────────────────────────────────────────────
  // Prueba la REGLA, no una instancia: un fallo AMBIGUO no se reintenta sin permiso del caller.
  // Sin estos dos casos, el arreglo se puede deshacer sin que nada se ponga rojo.
  const clienteConFalloAmbiguo = () => {
    const c = new LinearMinClient({ apiKey: "selftest-offline" });
    let intentos = 0;
    (c as any).query = async () => {
      intentos++;
      throw new LinearGraphQLError([], 502, {
        code: LinearErrorCode.EMPTY_BODY,
        retryable: true,
        message: "body vacío (selftest)",
      });
    };
    return { c, intentos: () => intentos };
  };

  await casoAsync("fallo AMBIGUO sin idempotent → NO se reintenta (1 solo intento)", async () => {
    const { c, intentos } = clienteConFalloAmbiguo();
    let lanzo = false;
    try {
      await c.queryWithRetry("query { viewer { id } }", undefined, { maxRetries: 4, baseDelayMs: 1 });
    } catch {
      lanzo = true;
    }
    assert(lanzo, "debía propagar el error");
    assert(intentos() === 1, `intentos=${intentos()} (esperado 1: sin idempotent no se reintenta)`);
  });

  await casoAsync("fallo AMBIGUO con idempotent:true → sí se reintenta hasta maxRetries", async () => {
    const { c, intentos } = clienteConFalloAmbiguo();
    let lanzo = false;
    try {
      await c.queryWithRetry("query { viewer { id } }", undefined, {
        maxRetries: 3,
        baseDelayMs: 1,
        idempotent: true,
      });
    } catch {
      lanzo = true;
    }
    assert(lanzo, "debía propagar el error tras agotar reintentos");
    assert(intentos() === 3, `intentos=${intentos()} (esperado 3 = maxRetries)`);
  });

  // ── Techo del backoff (MAX_RETRY_AFTER_MS) ──────────────────────────────────────────────────
  // Prueba la REGLA: un retryAfterMs por encima del techo NO se duerme — se relanza de
  // inmediato. Sin este caso, el techo se puede borrar (volviendo a dormir lo que sea) sin que
  // nada se ponga rojo, y el selftest seguiría en 0/1 mientras un proceso real se cuelga horas.
  await casoAsync("RATELIMITED con retryAfterMs > MAX_RETRY_AFTER_MS → NO se duerme, 1 solo intento", async () => {
    const c = new LinearMinClient({ apiKey: "selftest-offline" });
    let intentos = 0;
    (c as any).query = async () => {
      intentos++;
      throw new LinearGraphQLError([], 400, {
        code: LinearErrorCode.RATELIMITED,
        retryable: true,
        message: "rate limited (selftest, retryAfterMs sobre el techo)",
        retryAfterMs: MAX_RETRY_AFTER_MS + 1_000,
      });
    };
    const inicio = Date.now();
    let lanzo = false;
    try {
      await c.queryWithRetry("query { viewer { id } }", undefined, { maxRetries: 4, baseDelayMs: 1 });
    } catch {
      lanzo = true;
    }
    const elapsedMs = Date.now() - inicio;
    assert(lanzo, "debía propagar el error");
    assert(intentos === 1, `intentos=${intentos} (esperado 1: por encima del techo no se reintenta)`);
    assert(elapsedMs < 1_000, `elapsedMs=${elapsedMs} — no debía dormir el retryAfterMs pedido`);
  });

  // ── Resolución de la clave de Linear (LINEAR_API_KEY > TA_OPERATION_ENV > raíz del repo) ─────
  // Ficheros sintéticos en un directorio temporal y claves FALSAS: ninguna llamada de red, ningún
  // .env.local real. Cada negativo comprueba además que el mensaje no contiene ninguna clave.
  const claveTmp = fs.mkdtempSync(path.join(os.tmpdir(), "linear-clave-"));
  try {
    const claveRepo = "clave-falsa-repo";
    const claveOperacion = "clave-falsa-operacion";
    const claveEntorno = "clave-falsa-entorno";
    const raiz = path.join(claveTmp, "raiz");
    fs.mkdirSync(raiz);
    fs.writeFileSync(path.join(raiz, ".env.local"), `LINEAR_API_KEY=${claveRepo}\n`);
    const fichOperacion = path.join(claveTmp, "operacion.env");
    fs.writeFileSync(fichOperacion, `OTRA=1\nLINEAR_API_KEY=${claveOperacion}\n`);
    const fichSinClave = path.join(claveTmp, "sin-clave.env");
    fs.writeFileSync(fichSinClave, "OTRA=1\nLINEAR_API_KEY=\n");
    const fichAusente = path.join(claveTmp, "ausente.env");
    const raizVacia = path.join(claveTmp, "raiz-vacia");
    fs.mkdirSync(raizVacia);
    const claves = [claveRepo, claveOperacion, claveEntorno];
    const sinClaves = (mensaje: string) => {
      for (const c of claves) assert(!mensaje.includes(c), "el mensaje contiene una clave");
    };

    caso("clave: TA_OPERATION_ENV gana al .env.local de la raíz del repo", () => {
      const r = resolveApiKey({ TA_OPERATION_ENV: fichOperacion }, raiz);
      assert(r.ok && r.key === claveOperacion, `resolución=${JSON.stringify(r.ok)}`);
    });

    caso("clave: sin TA_OPERATION_ENV toma el .env.local de la raíz del repo", () => {
      const r = resolveApiKey({}, raiz);
      assert(r.ok && r.key === claveRepo, `resolución=${JSON.stringify(r.ok)}`);
    });

    caso("clave: LINEAR_API_KEY exportada gana, aun con TA_OPERATION_ENV roto", () => {
      const r = resolveApiKey({ LINEAR_API_KEY: claveEntorno, TA_OPERATION_ENV: fichAusente }, raiz);
      assert(r.ok && r.key === claveEntorno, `resolución=${JSON.stringify(r.ok)}`);
    });

    caso("clave: TA_OPERATION_ENV a un fichero que falta → error con la ruta y la variable, sin caer a la raíz", () => {
      const r = resolveApiKey({ TA_OPERATION_ENV: fichAusente }, raiz);
      assert(!r.ok, "debía ser un error (la raíz tiene clave y no debe usarse)");
      if (!r.ok) {
        assert(r.message.includes(fichAusente), "falta la ruta en el mensaje");
        assert(r.message.includes("TA_OPERATION_ENV"), "falta la variable en el mensaje");
        sinClaves(r.message);
      }
    });

    caso("clave: el fichero de TA_OPERATION_ENV no tiene LINEAR_API_KEY= → error con la ruta y la variable", () => {
      const r = resolveApiKey({ TA_OPERATION_ENV: fichSinClave }, raiz);
      assert(!r.ok, "debía ser un error (clave vacía no es clave)");
      if (!r.ok) {
        assert(r.message.includes(fichSinClave), "falta la ruta en el mensaje");
        assert(r.message.includes("TA_OPERATION_ENV"), "falta la variable en el mensaje");
        sinClaves(r.message);
      }
    });

    caso("clave: ninguna fuente → error claro, nunca una clave vacía", () => {
      const r = resolveApiKey({}, raizVacia);
      assert(!r.ok, "debía ser un error");
      if (!r.ok) {
        assert(r.message.includes(path.join(raizVacia, ".env.local")), "falta la ruta en el mensaje");
        assert(r.message.includes("LINEAR_API_KEY"), "falta la variable en el mensaje");
        sinClaves(r.message);
      }
    });

    caso("clave: TA_OPERATION_ENV vacía se trata como no definida (cae a la raíz del repo)", () => {
      const r = resolveApiKey({ TA_OPERATION_ENV: "" }, raiz);
      assert(r.ok && r.key === claveRepo, `resolución=${JSON.stringify(r.ok)}`);
    });
  } finally {
    fs.rmSync(claveTmp, { recursive: true, force: true });
  }

  console.log(`SELFTEST: PASS=${pass} FAIL=${failCount}`);
  return failCount;
}

async function dispatch(args: CliArgs): Promise<void> {
  let apiKey: string;
  try {
    apiKey = loadApiKey();
  } catch (err) {
    console.error(
      `Sin clave de Linear: ${(err as Error).message}. ` +
        "Define LINEAR_API_KEY, TA_OPERATION_ENV (fichero con LINEAR_API_KEY=) o .env.local en la raíz del repo.",
    );
    process.exit(1);
  }

  const client = new LinearMinClient({ apiKey });

  switch (args.action) {
    case "whoami": {
      const me = await client.query(ME_QUERY);
      console.log("Logged in as:", me.viewer.email);
      break;
    }
    case "list-teams": {
      const teams = await client.query(TEAMS_QUERY);
      console.log("Teams:", teams.teams.nodes.map((t: any) => `${t.name} (${t.key})`));
      break;
    }
    case "list-issues": {
      if (!args.team) {
        console.error("--team <KEY> es requerido para list-issues");
        process.exit(1);
      }
      const teams = await client.query(TEAMS_QUERY);
      const team = teams.teams.nodes.find((t: any) => t.key === args.team);
      if (!team) {
        console.error(`Team ${args.team} no encontrado`);
        process.exit(1);
      }
      const stateType = args.stateType ?? [WorkflowStateType.Unstarted, WorkflowStateType.Started];
      const allIssues = await client.paginate(
        ISSUES_PAGE_QUERY,
        { filter: { team: { id: { eq: team.id } }, state: { type: { in: stateType } } } },
        (data) => data.issues,
        { onPage: (nodes) => console.log(`Got page of ${nodes.length} issues`) }
      );
      console.log(`Total active issues in ${args.team}: ${allIssues.length}`);
      console.log("Rate limit:", client.lastRateLimit);
      break;
    }
    default:
      printHelp();
      process.exit(args.action ? 1 : 0);
  }

  // Trailer: estado del breaker AL FINAL de esta sesión — solo significativo aquí, nunca como
  // comando standalone (ver nota en printHelp).
  console.log("Circuit breaker:", client.circuitStatus());
}

if (require.main === module) {
  const args = parseArgs(process.argv.slice(2));
  if (args.help || !args.action) {
    printHelp();
    process.exit(0);
  }
  // selftest es 100% offline (sin red, sin LINEAR_API_KEY) — se resuelve ANTES de dispatch()
  // para no pasar por loadApiKey()/LinearMinClient en absoluto.
  if (args.action === "selftest") {
    runSelftest()
      .then((failCount) => process.exit(failCount === 0 ? 0 : 1))
      .catch((err) => {
        console.error("Error:", err);
        process.exit(1);
      });
  } else {
    dispatch(args).catch((err) => {
      console.error("Error:", err);
      process.exit(1);
    });
  }
}
