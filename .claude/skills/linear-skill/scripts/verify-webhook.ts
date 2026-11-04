#!/usr/bin/env npx tsx
/**
 * verify-webhook.ts — Verificación de webhooks de Linear
 *
 * Provee un middleware Express, un handler framework-agnóstico (usado por el ejemplo Next.js
 * App Router de references/05-webhooks.md) y una función standalone para verificar la firma
 * HMAC-SHA256 de webhooks de Linear, con anti-replay y deduplicación por delivery ID.
 *
 * Sin CircuitBreaker: este módulo no hace ninguna llamada saliente a la API de Linear —
 * verificación HMAC pura y local. El CircuitBreaker vive en linear-client.ts y protege
 * automáticamente cualquier código downstream (p.ej. un handler de webhook) que use
 * LinearMinClient para reaccionar al evento ya verificado.
 *
 * Uso (Express):
 *   import { linearWebhookMiddleware } from "./verify-webhook";
 *
 *   app.post(
 *     "/linear-webhook",
 *     express.raw({ type: "application/json" }),
 *     linearWebhookMiddleware(process.env.LINEAR_WEBHOOK_SECRET!),
 *     (req, res) => {
 *       const payload = (req as any).linearPayload;
 *       // procesar...
 *       res.status(200).end();
 *     }
 *   );
 *
 * Uso standalone:
 *   import { verifyLinearWebhook } from "./verify-webhook";
 *   const result = verifyLinearWebhook(rawBody, headers, secret);
 *
 * CLI (100% local, sin red, sin LINEAR_API_KEY; el secret se lee de LINEAR_WEBHOOK_SECRET o de
 * --secret-file <path>, NUNCA de un flag --secret en argv):
 *   LINEAR_WEBHOOK_SECRET=x npx tsx verify-webhook.ts --action generate-signature --payload ./fixture.json
 *   LINEAR_WEBHOOK_SECRET=x npx tsx verify-webhook.ts --action verify --payload ./fixture.json --signature <hex>
 *   npx tsx verify-webhook.ts --help
 */

import * as crypto from "crypto";
import * as fs from "fs";

export interface LinearWebhookPayload {
  action: "create" | "update" | "remove";
  type: string;
  data: any;
  updatedFrom?: any;
  webhookTimestamp: number;
  webhookId: string;
  organizationId: string;
}

export interface VerifyOptions {
  /** Timestamp tolerance in seconds. Default 60. */
  toleranceSeconds?: number;
  /** Optional dedupe set for delivery IDs. Pass to prevent replay. */
  deliveryDeduper?: DeliveryDeduper;
}

/**
 * Verifica firma HMAC-SHA256 con timing-safe comparison.
 * Devuelve true si la firma es válida.
 */
export function verifyLinearSignature(
  rawBody: Buffer | string,
  signatureHeader: string,
  secret: string
): boolean {
  if (!signatureHeader || typeof signatureHeader !== "string") {
    return false;
  }

  const computed = crypto
    .createHmac("sha256", secret)
    .update(rawBody)
    .digest("hex");

  // timing-safe — previene timing attacks
  const computedBuf = Buffer.from(computed);
  const providedBuf = Buffer.from(signatureHeader);

  if (computedBuf.length !== providedBuf.length) {
    return false;
  }

  return crypto.timingSafeEqual(computedBuf, providedBuf);
}

/**
 * Valida que el timestamp del webhook sea reciente.
 */
export function isFreshTimestamp(
  webhookTimestampMs: number,
  toleranceSeconds: number = 60
): boolean {
  if (typeof webhookTimestampMs !== "number" || !isFinite(webhookTimestampMs)) {
    return false;
  }
  const nowMs = Date.now();
  const ageMs = Math.abs(nowMs - webhookTimestampMs);
  return ageMs < toleranceSeconds * 1000;
}

/**
 * Deduper para delivery IDs. Usar para evitar procesar el mismo webhook
 * dos veces (Linear puede reintentar).
 *
 * LIMITACIONES conocidas (ver SKILL.md § Errores comunes para el detalle):
 * - Implementación in-memory con expiración — NO válida en multi-instancia (dos réplicas ven
 *   mapas distintos) ni sobrevive un restart. Para producción, reemplazar por un store durable
 *   (Postgres con `processed_at` + lock de fila, Redis, o equivalente).
 * - `checkAndMark()` marca como visto en el momento del CHECK, no tras procesar con éxito. Si
 *   el procesamiento downstream falla DESPUÉS de checkAndMark(), un reintento legítimo de Linear
 *   para el MISMO delivery se rechazará como "duplicado" aunque el evento nunca se haya
 *   procesado realmente — pérdida silenciosa del evento. Para un pipeline que necesita
 *   reintentar tras fallo de procesamiento, no uses checkAndMark() a ciegas: reserva primero,
 *   procesa, y solo entonces confirma — o usa el patrón `processed_at` referenciado arriba.
 */
export class DeliveryDeduper {
  private seen: Map<string, number> = new Map();
  private ttlMs: number;

  constructor(ttlMs: number = 24 * 60 * 60 * 1000) {
    this.ttlMs = ttlMs;
    // Cleanup periodic. Cast: con "dom" en lib (heredado del tsconfig raíz de Next.js) TS infiere
    // setInterval -> number en vez de NodeJS.Timeout; unref() solo existe en el tipo Node real.
    (setInterval(() => this.cleanup(), 60 * 60 * 1000) as unknown as NodeJS.Timeout).unref?.();
  }

  /** Returns true if seen before; false if first time. Marks as seen (ver limitación arriba). */
  checkAndMark(deliveryId: string): boolean {
    if (this.seen.has(deliveryId)) {
      return true;
    }
    this.seen.set(deliveryId, Date.now());
    return false;
  }

  private cleanup(): void {
    const cutoff = Date.now() - this.ttlMs;
    for (const [id, ts] of this.seen) {
      if (ts < cutoff) this.seen.delete(id);
    }
  }
}

/**
 * Verificación completa: firma + timestamp + dedupe.
 */
export function verifyLinearWebhook(
  rawBody: Buffer | string,
  headers: Record<string, string | string[] | undefined>,
  secret: string,
  options: VerifyOptions = {}
): {
  valid: boolean;
  reason?: string;
  payload?: LinearWebhookPayload;
} {
  const signature = pickHeader(headers, "linear-signature");
  if (!signature) {
    return { valid: false, reason: "missing Linear-Signature header" };
  }

  if (!verifyLinearSignature(rawBody, signature, secret)) {
    return { valid: false, reason: "invalid signature" };
  }

  let payload: LinearWebhookPayload;
  try {
    payload = JSON.parse(typeof rawBody === "string" ? rawBody : rawBody.toString());
  } catch (e) {
    return { valid: false, reason: "invalid JSON body" };
  }

  if (
    !isFreshTimestamp(
      payload.webhookTimestamp,
      options.toleranceSeconds ?? 60
    )
  ) {
    return { valid: false, reason: "stale timestamp" };
  }

  if (options.deliveryDeduper) {
    const deliveryId = pickHeader(headers, "linear-delivery");
    // Fail-closed: si se pidió dedupe pero no hay Linear-Delivery, rechazar en vez de aceptar
    // sin deduplicar en silencio (antes: sin header, el check se saltaba entero).
    if (!deliveryId) {
      return { valid: false, reason: "missing Linear-Delivery header (required for dedupe)" };
    }
    if (options.deliveryDeduper.checkAndMark(deliveryId)) {
      return { valid: false, reason: "duplicate delivery" };
    }
  }

  return { valid: true, payload };
}

function pickHeader(
  headers: Record<string, string | string[] | undefined>,
  name: string
): string | undefined {
  // Express normaliza headers a lowercase
  const lower = name.toLowerCase();
  for (const k of Object.keys(headers)) {
    if (k.toLowerCase() === lower) {
      const v = headers[k];
      return Array.isArray(v) ? v[0] : v;
    }
  }
  return undefined;
}

// ====================================================================
// Middleware Express
// ====================================================================

type ExpressLikeRequest = {
  headers: Record<string, string | string[] | undefined>;
  body: Buffer | string;
  [key: string]: any;
};

type ExpressLikeResponse = {
  status: (code: number) => any;
  end: (msg?: string) => any;
};

type NextFunction = (err?: Error) => void;

/**
 * Middleware Express que verifica el webhook y popula req.linearPayload.
 *
 * IMPORTANTE: Este middleware requiere que el body venga RAW (Buffer).
 * Configurar la ruta con `express.raw({ type: "application/json" })`
 * ANTES de este middleware.
 */
export function linearWebhookMiddleware(
  secret: string,
  options: VerifyOptions = {}
) {
  return (req: ExpressLikeRequest, res: ExpressLikeResponse, next: NextFunction) => {
    const result = verifyLinearWebhook(req.body, req.headers, secret, options);

    if (!result.valid) {
      console.warn("[linear-webhook] Rejected:", result.reason);
      return res.status(401).end(result.reason);
    }

    req.linearPayload = result.payload;
    next();
  };
}

// ====================================================================
// Ejemplo de servidor completo — ESQUELETO FAIL-CLOSED (no completo de verdad, ver abajo)
// ====================================================================
/*
import express from "express";
import { linearWebhookMiddleware } from "./verify-webhook";

const app = express();

// OJO: NO se pasa `deliveryDeduper` aquí. linearWebhookMiddleware() llama a
// verifyLinearWebhook() ANTES del handler — si el deduper marca el delivery en la
// verificación (checkAndMark) y el procesamiento falla después, el reintento de Linear con el
// MISMO Linear-Delivery se rechazaría como "duplicate delivery" en la propia verificación, sin
// llegar nunca al handler para reprocesarlo — justo el bug que este ejemplo debía evitar. El
// dedupe real va DENTRO del handler, contra un store durable con estado pendiente/procesado
// (reserva → procesa → marca procesado; ver src/app/api/webhooks/stripe/route.ts:120-201), no
// en la capa de verificación de firma.
app.post(
  "/linear-webhook",
  express.raw({ type: "application/json", limit: "5mb" }),
  linearWebhookMiddleware(process.env.LINEAR_WEBHOOK_SECRET!),
  async (req, res) => {
    const payload = (req as any).linearPayload;
    const eventType = req.header("Linear-Event");
    const deliveryId = req.header("Linear-Delivery");
    if (!deliveryId) return res.status(400).end("missing Linear-Delivery");

    // await REAL antes de responder — un fallo de procesamiento debe dar 5xx (Linear reintenta),
    // NUNCA 200 antes de saber si se procesó.
    try {
      await reserveAndProcess(deliveryId, eventType, payload);
      res.status(200).end();
    } catch (err) {
      console.error("Error processing Linear event:", err);
      res.status(500).end();
    }
  }
);

// FAIL-CLOSED a propósito: esta función NO reserva nada durable todavía (sin constraint UNIQUE
// en delivery_id, sin processed_at) — llamar directo a handleLinearEvent() aquí sería un
// placeholder que RESPONDE 200 sin la garantía que su propio nombre promete, dejando dos
// entregas concurrentes o un retry tras ACK perdido ejecutar los efectos downstream dos veces.
// Implementa la reserva real (p.ej. INSERT ... ON CONFLICT (delivery_id) DO NOTHING -> si no
// insertó, ya existe: comprobar processed_at; si NULL, reintento legítimo -> procesar bajo lock
// de fila; si ya tiene valor, no-op -> 200) ANTES de sustituir este throw por el dispatch real.
async function reserveAndProcess(deliveryId: string, eventType: string, payload: any): Promise<void> {
  throw new Error(
    `reserveAndProcess() incompleto: implementa la reserva durable (delivery_id=${deliveryId}, ` +
      `eventType=${eventType}) antes de despachar a handleLinearEvent(); ver payload en el llamador.`
  );
  // await handleLinearEvent(eventType, payload); // <- sustituir el throw por esto SOLO tras la reserva real
}

async function handleLinearEvent(eventType: string, payload: any) {
  switch (eventType) {
    case "Issue":
      await handleIssueEvent(payload);
      break;
    case "Comment":
      await handleCommentEvent(payload);
      break;
    case "AgentSessionEvent":
      await handleAgentSessionEvent(payload);
      break;
    default:
      console.log(`Unhandled event type: ${eventType}`);
  }
}

app.listen(3000, () => {
  console.log("Linear webhook server listening on :3000");
});
*/

// ====================================================================
// CLI (100% local — sin llamadas a la API de Linear, sin LINEAR_API_KEY)
// ====================================================================

interface CLIArgs {
  help: boolean;
  action?: "verify" | "generate-signature";
  payload?: string;
  signature?: string;
  /** Ruta a un archivo con el secret (recomendado, permisos 0600) — NUNCA en argv. */
  secretFile?: string;
  timestampTolerance?: number;
}

function printHelp(): void {
  console.log(`Uso: npx tsx verify-webhook.ts --action <verify|generate-signature> [opciones]

Acciones:
  generate-signature --payload <file> [--secret-file <path>]
      Imprime el HMAC-SHA256 hex del contenido de <file> (útil para fixtures de test).

  verify --payload <file> --signature <hex> [--secret-file <path>] [--timestamp-tolerance <s>]
      Verifica la firma (y el timestamp si el payload es JSON válido con webhookTimestamp).

Secret (NUNCA como flag — sería visible en \`ps\`/historial de shell, misma postura que
SKILL.md § Autenticación regla 18):
  Por defecto se lee de la env var LINEAR_WEBHOOK_SECRET.
  --secret-file <path>   alternativa: lee el secret de un archivo (recomendado permisos 0600).

Opciones:
  --help, -h    Muestra esta ayuda y sale (no toca disco fuera de --payload/--secret-file, sin red)

100% local — no requiere LINEAR_API_KEY ni acceso de red.`);
}

function parseArgs(argv: string[]): CLIArgs {
  const out: CLIArgs = { help: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const next = argv[i + 1];
    if (arg === "--help" || arg === "-h") out.help = true;
    else if (arg === "--action") { out.action = next as CLIArgs["action"]; i++; }
    else if (arg === "--payload") { out.payload = next; i++; }
    else if (arg === "--signature") { out.signature = next; i++; }
    else if (arg === "--secret-file") { out.secretFile = next; i++; }
    else if (arg === "--timestamp-tolerance") { out.timestampTolerance = parseInt(next, 10); i++; }
    else if (arg === "--secret") {
      throw new Error(
        "--secret no soportado (quedaría visible en `ps`/historial de shell) — usa la env var " +
          "LINEAR_WEBHOOK_SECRET o --secret-file <path 0600>"
      );
    }
  }
  return out;
}

/** Lee el secret de --secret-file si se dio, si no de LINEAR_WEBHOOK_SECRET. Nunca de argv. */
function resolveSecret(args: CLIArgs): string {
  if (args.secretFile) return fs.readFileSync(args.secretFile, "utf8").trim();
  const fromEnv = process.env.LINEAR_WEBHOOK_SECRET;
  if (!fromEnv) {
    throw new Error("Falta el secret: define LINEAR_WEBHOOK_SECRET o pasa --secret-file <path>");
  }
  return fromEnv;
}

function dispatch(args: CLIArgs): void {
  if (!args.payload) {
    throw new Error("--payload es requerido");
  }
  const secret = resolveSecret(args);
  const rawBody = fs.readFileSync(args.payload, "utf8");

  if (args.action === "generate-signature") {
    const sig = crypto.createHmac("sha256", secret).update(rawBody).digest("hex");
    console.log(sig);
    return;
  }

  if (args.action === "verify") {
    if (!args.signature) throw new Error("--signature es requerido para --action verify");
    const validSig = verifyLinearSignature(rawBody, args.signature, secret);
    if (!validSig) {
      console.log("INVALID — firma no coincide");
      process.exit(1);
    }
    try {
      const payload = JSON.parse(rawBody);
      const fresh = isFreshTimestamp(payload.webhookTimestamp, args.timestampTolerance ?? 60);
      console.log(fresh ? "VALID (firma + timestamp fresco)" : "VALID firma, pero timestamp STALE");
      process.exit(fresh ? 0 : 1);
    } catch {
      console.log("VALID (firma) — payload no es JSON, no se pudo validar timestamp");
    }
    return;
  }

  throw new Error(`action desconocida o ausente: "${args.action}" (usa verify | generate-signature)`);
}

if (require.main === module) {
  const args = parseArgs(process.argv.slice(2));
  if (args.help || !args.action) {
    printHelp();
    process.exit(0);
  }
  try {
    dispatch(args);
  } catch (err: any) {
    console.error("Error:", err.message ?? err);
    process.exit(1);
  }
}
