# 03 — Superficies sensibles (lista canónica)

**Fuente canónica** de la clasificación por riesgo del ADR-0043. La clasificación es
**OPERATIVA, no gate de review** (ruling del lead 2026-07-08: el CLI limpio autoriza el
merge en cualquier superficie): tocar una de estas superficies gobierna el cuidado extra
del Mergeador — verificación declaración-vs-diff, spot-check reforzado, prioridad de cola
— y el GO del lead en destructivas. Lista **viva**: la mantiene el Orquestador; cambios
van por PR a este archivo (+ el allowlist del template HANDOFF y
`scripts/verify-handoff.sh` en el mismo PR).

## Table of Contents

- [1. Regla fail-closed](#1-regla-fail-closed)
- [2. Lista canónica y tokens del allowlist](#2-lista-canónica-y-tokens-del-allowlist)
- [3. Path-patterns en Academia Ejemplo](#3-path-patterns-en-academia-ejemplo)
- [4. Verificar la declaración contra el diff](#4-verificar-la-declaración-contra-el-diff)
- [5. PROC-M17 — Destructiva no declarada](#5-proc-m17--destructiva-no-declarada)
- [6. Checklist de auditoría de superficie sensible (OTP/secretos)](#6-checklist-de-auditoría-de-superficie-sensible-otpsecretos)
- [7. Code-gate de money-path](#7-code-gate-de-money-path)

## 1. Regla fail-closed

**En duda, sensible.** La clasificación decide cuánto cuidado operativo recibe el PR (y
si una migración exige GO del lead); el coste de sobre-clasificar es atención extra del
Mergeador; el de infra-clasificar es un escape a producción en superficie de
dinero/seguridad. El desempate es siempre tratarlo como sensible.

## 2. Lista canónica y tokens del allowlist

Los tokens son los valores EXACTOS del campo `surfaces` del bloque machine-readable del
HANDOFF (contrato en `docs/templates/handoff-pr-draft.md`, validados por
`scripts/verify-handoff.sh`):

| Token | Superficie | Por qué es sensible |
|---|---|---|
| `commerce` | Commerce / pagos / webhooks de pago | Dinero real; idempotencia y firmas de webhook |
| `auth-rls` | Auth, RLS, políticas y grants | Un fallo expone datos de alumnos (regla 19 de CLAUDE.md) |
| `migraciones` | Migraciones SQL | DDL irreversible + ledger de prod; SIEMPRE sensible |
| `llm-costes` | Proveedores LLM / costes / caps de uso | Coste variable real + credenciales de proveedor |
| `seguridad` | Headers de seguridad, proxy, rate-limit | Superficie de ataque global de la plataforma |
| `credenciales` | Manejo de secrets / KMS / rotación | Compromiso de credenciales = incidente Sev1 |

## 3. Path-patterns en Academia Ejemplo

Mapa operativo token → paths (señal fuerte, no exhaustiva — aplica §1 ante paths nuevos):

| Token | Paths (glob) |
|---|---|
| `commerce` | `src/lib/commerce/**` · `src/app/commerce/**` · `src/app/api/webhooks/**` · `supabase/tests/*sale*` |
| `auth-rls` | `src/lib/supabase/{server,admin,middleware}.ts` · `src/app/auth/**` · `src/app/[locale]/login/**` · `src/app/[locale]/setup-password/**` · políticas/grants en cualquier `.sql` |
| `migraciones` | `supabase/migrations/**` |
| `llm-costes` | `src/lib/llm/**` · `src/lib/chatbot/**` · `src/app/api/chatbot*/**` · `supabase/functions/{embed_text,chunk_and_embed_transcript}/**` |
| `seguridad` | `src/proxy.ts` · `next.config.ts` (headers/CSP) · `src/lib/rate-limit.ts` · `.github/workflows/**` |
| `credenciales` | `src/lib/crypto/**` · `src/app/[locale]/(admin)/admin/settings/llm-keys/**` · `.env.example` (superficie cuando se **añaden o cambian VALORES**, o se introduce una variable **secreta**; una línea **comentada** que documenta una variable **no secreta** — p. ej. un id de deployment inyectado por el hosting — queda FUERA: no hay credencial, no hay superficie) · todo lo que toque `llm_provider_credentials` |

**Principio de la nota trazada** (regla dura 9, 2026-07-28): ante una entrada de esta tabla
**sin cualificador** cuya **sustancia**, medida contra el diff, es **inocua** → **nota de
clasificación TRAZADA en el PR** (divergencia detectada · resolución · sello que la
autoriza) y se sigue. **NUNCA bounce por etiqueta**: PROC-M17 es para entregas
**inválidas**, no para desacuerdos de tabla. **La duda razonable sigue siendo
fail-closed**: mientras no esté resuelta, el PR se trata operativamente como sensible
(cuidado reforzado y spot-checks), aunque no rebote. La tabla gobierna la DECLARACIÓN; el
juicio gobierna el CUIDADO — ninguno sustituye al otro: un `surfaces: []` correcto no
autoriza una revisión superficial, y una sustancia inocua no obliga a rebotar por una
etiqueta. Evidencia (2026-07-28): PR #1407 tocó `next.config.ts` (añade `deploymentId`,
fuera del cualificador «headers/CSP») y `.env.example` (línea comentada, var no secreta) →
resuelto como nota trazada, sin bounce. Contraste: PR #1409 tocó
`src/components/portal/markdown-renderer.tsx` y `messages/*.json` — ningún path de esta
tabla, `surfaces: []` es declaración correcta, pero es territorio XSS/DOMPurify → cuidado
reforzado por JUICIO, sin re-etiquetar.

## 4. Verificar la declaración contra el diff

El Mergeador **verifica, no confía** (regla dura 3 del SKILL.md):

```bash
gh pr diff <pr> --name-only          # paths reales del PR
# cruzar contra §3; discrepancia con el HANDOFF:
#   - declaró de MENOS (sensitive:false con paths de §3) → entrega inválida → PROC-M01
#   - declaró de MÁS → operar como sensible (fail-closed; no es rechazo)
```

## 5. PROC-M17 — Destructiva no declarada

**Síntoma**: el diff trae `DROP TABLE` / `DROP COLUMN` / `TRUNCATE` / `ALTER … TYPE`
irreversible / `DELETE` batch top-level y el HANDOFF declara `destructive: false` (o no
lista el slot).

1. **PARAR el PR** (no entra al slot de merge). La clasificación de destructivas es la del
   anexo de `talent-channel-operation` §4 (cuerpos de función y `REVOKE` no son
   destructivos; DDL de borrado y `TRUNCATE` sí).
2. Tratar como entrega inválida (PROC-M01): comentario de rechazo citando el statement +
   aviso al coordinador de la 1ª estación (el code-audit dejó pasar una destructiva sin
   declarar — es un hallazgo de SU gate).
3. Si el trabajo debe avanzar igualmente (decisión de cola): **GO explícito del lead
   ANTES** de cualquier paso (regla dura 7) — el GO cubre el merge Y el apply.
4. Registrar en el PR la resolución (rechazo o GO) — trazabilidad del piloto.

## 6. Checklist de auditoría de superficie sensible (OTP/secretos)

Checklist de **REFERENCIA** para auditar una superficie de manejo de secretos/OTP como la de #1043
(verificación de posesión telefónica). **No es una lista de invariantes universales**: son los puntos
que se verificaron en #1043; **aplicar el que corresponda al TIPO de secreto** (un OTP numérico
efímero no es lo mismo que una clave criptográfica ni que una credencial de proveedor), no exigirlos
todos a todo secreto.

- **El secreto no viaja al cliente** — nace y se consume server-side; no aparece en respuestas, props
  ni logs de red. (Un OTP puede vivir **hasheado** en DB con expiración; una credencial de proveedor
  va en la capa privada — según el tipo.)
- **Mutación por RPC `SECURITY DEFINER` con gate `auth.uid()` en user-context** cuando la mutación es
  sensible — cero `admin` client para esa mutación (contrato «Modelo de datos»). Aplica a mutaciones
  sensibles, no a toda lectura.
- **`search_path = ''` y objetos schema-qualified** dentro de cualquier RPC `SECURITY DEFINER` nuevo
  (anti-hijack de search_path).
- **Fail-closed + kill-switch `off` por defecto** en la feature que consume el secreto. La regla de
  **longitud ≥ 32 bytes aplica a material CRIPTOGRÁFICO** (clave/HMAC/token de firma), **NO a un OTP
  numérico** — el endurecimiento de un OTP es longitud de dígitos + expiración corta + single-use +
  rate-limit, no un umbral de 32 bytes.
- **Rate-limit AUTORITATIVO en la DB** (advisory locks) para el flujo de verificación, con speed-bumps
  espejo en Node como defensa en profundidad — relevante cuando el secreto es adivinable por fuerza
  bruta (OTP), no para todo secreto.
- **Almacenamiento según el tipo**: credenciales/claves de largo plazo → capa privada/Vault, **nunca**
  en `site_settings` ni config de tenant (regla 18 + invariante (d)); un OTP efímero → DB hasheado con
  expiración. Vault **no** es requisito de "cualquier secreto".
- **PII jamás en logs/Sentry** — ni el identificador, ni el secreto, ni el teléfono.
- **Error Crítico 8 en TODO `await` de Server Action** del flujo — los dos modos de fallo (contrato
  `{ok:false}` Y la excepción) cubiertos, con revert del optimista si aplica.

Complemento de veredicto (de #1039): **un fix que NO arregla su objetivo NO mergea con `closes`** —
verificar el arreglo con re-runs y **bounce con evidencia** si no cierra su issue. Y el
**baseline-accept** de un gate exige **único-fail + disyunción probada + causa a nivel de test**
(strict-mode/timeout), **nunca** `permission-denied`/RLS (eso es defecto real, no flake).

## 7. Code-gate de money-path

Origen: 3 rebotes reales evitables leyendo esta sección (TAL-5026 r3/r4, TAL-5056) y un pisado
en producción (TAL-5074 sobre TAL-5026 — ver ref 06 §2) que la ausencia de estos 5 gates
permitió. Aplica a todo PR clasificado `commerce` (ref 03 §2/§3) o que toque cualquier ruta de
cobro, comisión, saldo o reconciliación — el CLI/App de CodeRabbit audita el diff; estos 5
gates son la lista de verificación ADICIONAL del Mergeador antes del merge, específica de
money-path:

1. **Auditar la ruta ONLINE/runtime, no solo reconcile/backfill**: un fix que corrige el
   job de reconciliación nocturno pero deja el path síncrono (checkout, webhook) con el mismo
   defecto no cierra el money-path — verificar AMBAS rutas, no solo la que trae el diff.
2. **Robustez de casts sobre metadata legacy**: dinero/cantidades que llegan como string,
   `null`, o formato antiguo desde un gateway o migración previa — un cast que no maneja el
   caso legacy revienta en runtime sobre datos reales, no en el fixture del test.
3. **Rutas de ERROR TRANSITORIO reintentan, JAMÁS terminalizan — y el reintento en sí exige
   clave de idempotencia** (TAL-5170, CRITICAL de revisión externa — ACEPTADO: la clase exacta de
   bug del doble apply): un timeout de red o un 5xx del gateway de pago no puede marcar una
   venta/comisión como fallida definitiva — el estado terminal (failed, refunded) se reserva
   para respuestas explícitas del proveedor, nunca para errores de transporte. **Pero
   reintentar SIN una clave de idempotencia estable duplica el efecto** (cobro doble, comisión
   doble) exactamente como el incidente que motivó este gate: antes de reenviar, el reintento
   exige una clave de idempotencia estable del proveedor (`Idempotency-Key` o equivalente) o,
   si el proveedor no la soporta, reconciliación determinista por `merchant_id`/`request_id`
   consultando el ESTADO REMOTO del proveedor por ese identificador (endpoint de consulta o
   webhook ya recibido) — el registro LOCAL persistido por sí solo NO demuestra si el
   proveedor ejecutó el cobro o la comisión, solo que el intento anterior no confirmó a
   tiempo; reenviar basándose únicamente en "mi tabla no lo tiene marcado como pagado"
   conserva el mismo riesgo de doble cobro que este gate busca cerrar. **Sin esa clave o sin
   poder confirmar el estado remoto: NO reenviar a ciegas** — dejar el estado pendiente y
   escalar al lead, nunca asumir que un reintento ciego es más seguro que esperar.
4. **FK `ON DELETE` probado en migraciones money/audit**: toda migración nueva sobre tablas de
   `sales`, `sale_financials`, `commissions`, `refunds` o cualquier tabla de auditoría
   financiera declara explícitamente el comportamiento `ON DELETE` de sus FKs y lo prueba
   (pgTAP o equivalente) — un `ON DELETE CASCADE` no intencional en una tabla de auditoría
   borra evidencia financiera junto con el registro padre.
5. **Ante regresión de CONSTRAINT, `db-guards` COMPLETO es el gate — y ante fixture rojo, el
   A/B EMPÍRICO base-main-puro vs head es el árbitro, no el call-graph estático**: cuando un
   PR de money-path toca un constraint o trigger existente, no basta razonar sobre el código;
   correr `db-guards` completo y, si un fixture se pone rojo, comparar el comportamiento real
   corriendo el mismo fixture contra `main` puro (sin el PR) vs contra el head del PR — el
   resultado empírico decide si la regresión la introduce el PR o ya existía en `main`.
