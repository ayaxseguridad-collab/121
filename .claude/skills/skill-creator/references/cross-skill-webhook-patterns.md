# Cross-Skill Webhook Patterns — Fail-Closed Gating Reference

Esqueletos ilustrativos del contrato de gating falla-cerrado para webhooks entrantes, referenciados
desde la sección `## Cross-Skill Integration` de `../SKILL.md` (`nextjs-web` y `supabase-skill`).

## Table of Contents

1. [Contrato de gating falla-cerrado](#1-contrato-de-gating-falla-cerrado)
2. [Next.js App Router — Webhook Route](#2-nextjs-app-router--webhook-route)
3. [Supabase Edge Function — Webhook](#3-supabase-edge-function--webhook)
4. [Gotchas & Cross-References](#4-gotchas--cross-references)

---

## 1. Contrato de gating falla-cerrado

Todo webhook entrante de un proveedor externo (Stripe, PayPal, MercadoPago, NOWPayments, Hotmart,
etc.) sigue el MISMO invariante estructural, aunque cada gateway firme con un esquema y contrato
criptográfico distintos (no existe un verificador universal — ver §4 para los punteros a las
implementaciones reales). El invariante:

```text
┌──────────────────────────────────────────────────────────────────────────┐
│                    CONTRATO DE GATING FALLA-CERRADO                      │
├──────────────────────────────────────────────────────────────────────────┤
│  1. Header de firma ausente?          ──── SÍ ───▶  400                  │
│  2. Config/secret ausente?            ──── SÍ ───▶  5xx (NUNCA 4xx —     │
│     (fallo NUESTRO, no del caller)                  fuerza reintento)    │
│  3. RAW BODY con cota (streaming)      ──── excede ─▶ 413                │
│     (NO Content-Length: falsificable)                                    │
│  4. Verificación provider-específica   ──── inválida ▶ 401               │
│     (mecanismo y contrato del gateway) ──── transitoria/config ▶ 5xx     │
│  5. Idempotencia (reserva→procesa→      ──── falla ───▶ 5xx (fuerza      │
│     marca processed_at, SERIALIZADA)                    re-entrega)     │
│  6. Solo si 4 y 5 completan OK          ────────────▶ 200                │
└──────────────────────────────────────────────────────────────────────────┘
```

**Por qué "falla-cerrado" y no runnable**: los dos esqueletos de §2 y §3 son **ILUSTRATIVOS** — no
copy-paste. Documentan la ESTRUCTURA del gating (dónde va cada check y en qué orden) con punteros a
las implementaciones REALES del repo, pero **lanzan una excepción antes de responder 200** en vez de
implementar los pasos 3–5. Esto es intencional: un ejemplo "completo" que responde 200
incondicionalmente enseñaría a aceptar webhooks falsificados. Quien copie este esqueleto debe
completar los pasos 3–5 contra la implementación real de su proveedor antes de sustituir el `throw`
por el `return 200`. **Nunca** se debe "arreglar" el esqueleto rellenando esos pasos con lógica
inventada solo para que el código sea ejecutable — eso es exactamente el error que el falla-cerrado
previene.

Error handling de este tema: cada rama de rechazo (400/413/401/5xx) está codificada en los pasos 1-5
de los esqueletos de abajo, con el motivo explícito de por qué es 4xx vs 5xx (ver comentarios inline).

---

## 2. Next.js App Router — Webhook Route

```typescript
// EJEMPLO ILUSTRATIVO (no copia-pega). Enseña la ESTRUCTURA de gating; cada "→ ver…"
// apunta a la implementación REAL del repo (la fuente de verdad). NO hay verificador
// universal: cada gateway firma con un esquema y un CONTRATO distintos.
// app/api/webhooks/{{service}}/route.ts
import { NextResponse, type NextRequest } from 'next/server';

export const dynamic = 'force-dynamic';  // raw body + node:crypto ⇒ sin optimización estática
export const runtime = 'nodejs';         // requerido por el streaming del body y node:crypto

export async function POST(req: NextRequest) {
  // 1) Header de firma presente (check barato) ANTES del body.
  const signature = req.headers.get('x-{{service}}-signature');
  if (!signature) return new NextResponse('missing signature', { status: 400 });

  // 2) Config ausente → 5xx, NUNCA 4xx (un 401 por un fallo NUESTRO haría que el vendor
  //    deje de reintentar y el evento se perdería).
  const secret = process.env.{{ENV_VAR}};
  if (!secret) return new NextResponse('config error', { status: 500 });

  // 3) RAW BODY con cota DURANTE el streaming — NO Content-Length (es falsificable; un
  //    body sin cota es DoS de memoria/CPU). Reader que aborta al superar el cap:
  //    → src/app/api/webhooks/stripe/route.ts:33-61  (MAX_BODY_BYTES + readBodyWithLimit)
  //    Si excede → 413.

  // 4) VERIFICAR según el ESQUEMA DE TU PROVEEDOR — lo dicta el gateway; NO hay regla
  //    cripto universal (mecanismo Y contrato varían). Remite a su verificador REAL:
  //    → nowpayments-ipn-verify.ts:54  HMAC-SHA512 hex + timingSafeEqual sobre JSON
  //                                     sorted-key (NO el raw body); (body,sig,secret)=>boolean
  //    → mercadopago-ipn-verify.ts:52  header COMPUESTO 'ts=...,v1=...' de un manifest;
  //                                     compara solo v1; (dataId,xSig,xReqId,secret)=>boolean
  //    → paypal-client.ts:303          verificación REMOTA (5 headers, sin HMAC local);
  //                                     ASÍNCRONO ⇒ 'valid'|'invalid'|'transient'|'error'
  //    → Stripe  stripeClient.webhooks.constructEvent(rawBody,signature,secret)  LANZA
  //    Estado (estructura, no cripto): inválida → 401; transitoria (red/DB) o config → 5xx
  //    (fuerza re-entrega); válida → continúa. No fuerces await sobre un contrato síncrono.

  // 5) IDEMPOTENCIA canónica: RESERVA (insert unique (gateway,event_id)) → PROCESA →
  //    marca processed_at. Si el insert choca 23505 pero processed_at es NULL, un intento
  //    previo cayó ⇒ REPROCESA, pero SERIALIZADO (SELECT … FOR UPDATE sobre la fila de
  //    reserva, o lease con owner-token+expiración) para que dos entregas concurrentes no
  //    reprocesen el MISMO evento a la vez (efectos no-idempotentes duplicados); si el
  //    proceso falla, deja processed_at NULL y responde 5xx para forzar re-entrega. El
  //    23505-solo PIERDE eventos si handle lanza. OJO: processed_at NO cubre un crash ENTRE
  //    el efecto externo no-idempotente (cobro, email) y su persistencia → ese efecto necesita
  //    su propia clave de idempotencia / outbox transaccional (marcar en la MISMA tx que el efecto).
  //    → src/app/api/webhooks/stripe/route.ts:120-201 implementa la RESERVA→PROCESA→marca y la
  //    detección 23505, pero AÚN NO la serialización (FOR UPDATE / lease) descrita arriba — es un
  //    gap conocido, replicado igual en paypal/mercadopago/nowpayments/hotmart, trackeado en
  //    TAL-2992. No lo copies como ejemplo de este invariante ya cumplido.

  // 6) Solo cuando 4 y 5 completan con éxito ⇒ 200 (nunca antes). Este ejemplo es un
  //    ESQUELETO: los pasos 3–5 están descritos como comentarios con punteros a la impl
  //    real, NO implementados aquí. FALLA-CERRADO a propósito — así una copia sin completar
  //    3–5 NUNCA responde 200 (aceptaría webhooks falsificados / confirmaría eventos sin
  //    procesar). Sustituye este throw por el `return 200` SOLO cuando 3–5 estén implementados.
  throw new Error('webhook skeleton incompleto: implementa los pasos 3–5 (body-cap, verify, idempotencia) antes de responder 200');
  // return NextResponse.json({ received: true });  // ← tras completar 3–5
}
```

For payment/commerce skills, also show the Server Action pattern for creating resources.

---

## 3. Supabase Edge Function — Webhook

```typescript
// EJEMPLO ILUSTRATIVO (no copia-pega). Mismo contrato de gating que el ejemplo nextjs-web;
// cada "→ ver…" apunta a la impl REAL del repo. Pinea specifiers jsr: EXACTOS (cada deploy
// resuelve imports "fresh"; un rango flotante cambiaría el código desplegado).
// supabase/functions/{{service}}-webhook/index.ts
import { createClient } from 'jsr:@supabase/supabase-js@2.110.4';

Deno.serve(async (req: Request) => {
  // 1) Header presente → 400 si falta.
  const signature = req.headers.get('x-{{service}}-signature');
  if (!signature) return new Response('missing signature', { status: 400 });

  // 2) Config ausente → 5xx, NUNCA 4xx (el vendor debe reintentar).
  const secret = Deno.env.get('{{ENV_VAR}}');
  if (!secret) return new Response('config error', { status: 500 });

  // 3) RAW BODY con cota leyendo el ReadableStream (req.body.getReader()); NO confíes en
  //    Content-Length. Mismo reader-con-cap (Web Streams, portable a Deno):
  //    → src/app/api/webhooks/stripe/route.ts:33-61. Si excede → 413.

  // 4) VERIFICAR según el esquema de tu proveedor (lo dicta el gateway; NO hay regla
  //    cripto universal). Fuentes de verdad y contratos: ver los 4 punteros del paso 4 del
  //    ejemplo nextjs-web. Para los esquemas que comparan un HMAC-hex localmente (estilo
  //    NOWPayments), el helper Deno de comparación en tiempo constante es timingSafeEqual
  //    de jsr:@std/crypto@1.1.0/timing-safe-equal → _shared/edge-helpers.ts:18. Estado:
  //    inválida → 401; transitoria/config → 5xx; válida → continúa.

  // 5) IDEMPOTENCIA canónica processed_at (reserva → procesa → marca; reprocesa si NULL
  //    pero SERIALIZADO bajo lock de fila / lease para no reprocesar concurrente; fallo →
  //    5xx) — NO el 23505-solo. La reserva→procesa→marca y la detección 23505 SÍ están en
  //    src/app/api/webhooks/stripe/route.ts:120-201; la serialización NO — gap conocido
  //    trackeado en TAL-2992 (no lo copies como ejemplo de invariante ya cumplido).
  //    Cliente service-role (ruta server-only, sin sesión de usuario ⇒ uso legítimo):
  //    createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!).
  //    OJO: service_role BYPASSA RLS — la protección REAL es que la key quede EXCLUSIVAMENTE
  //    server-side (nunca al cliente) + privilegios/esquema acotados. La RLS de la tabla de
  //    dedup es defensa-en-profundidad para clientes NO service_role (anon/authenticated), no
  //    un control sobre estas operaciones.

  // 6) Solo cuando 4 y 5 completan con éxito ⇒ 200. ESQUELETO: 3–5 son comentarios con
  //    punteros a la impl real, NO implementados. FALLA-CERRADO — una copia sin completar
  //    3–5 nunca responde 200. Sustituye el throw por el `return` SOLO tras implementar 3–5.
  throw new Error('webhook skeleton incompleto: implementa los pasos 3–5 antes de responder 200');
  // return new Response(JSON.stringify({ ok: true }), {   // ← tras completar 3–5
  //   headers: { 'Content-Type': 'application/json' },
  // });
});
```

---

## 4. Gotchas & Cross-References

**Common mistakes in this area:**

1. **Convertir el esqueleto en código inseguro para que "corra"** → Rellenar los pasos 3–5 con lógica
   inventada (p. ej. `return NextResponse.json({ received: true })` sin verificar firma) solo para
   evitar el `throw` acepta webhooks falsificados. El `throw` es la protección, no un placeholder a
   eliminar sin más.
2. **Usar un único verificador "genérico" para todos los proveedores** → No existe un esquema
   criptográfico universal. Cada gateway firma distinto (HMAC-SHA512 hex, header compuesto
   `ts=...,v1=...`, verificación remota asíncrona, o una llamada de SDK que lanza). Ver los 4 punteros
   del paso 4 en §2.
3. **Confiar en `Content-Length` para acotar el body** → Es falsificable; el cap real debe aplicarse
   DURANTE el streaming del `ReadableStream`.
4. **Responder 401/4xx cuando falta la config del secret** → Un 401/4xx por un fallo NUESTRO
   (config ausente) hace que el vendor deje de reintentar y el evento se pierde. Config ausente
   siempre es 5xx.
5. **Idempotencia con `INSERT ... ON CONFLICT DO NOTHING` a secas** → Pierde eventos si el handler
   lanza después del insert. Usar reserva→procesa→marca `processed_at`, serializado con lock de fila
   o lease, y re-procesar si `processed_at` sigue NULL tras un choque `23505`.

**Related reference files:**

- Contrato completo de frontmatter y estructura del reference → `reference-file-template.md`
- Punto de entrada del meta-skill y resumen del invariante → `../SKILL.md` § Cross-Skill Integration
