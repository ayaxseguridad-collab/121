# 06 — Gotchas de sangre (con fecha y fuente)

> Fuente: TAL-5157 §B8 (gotchas 1-9, guardias de C3 ago-sep 2026) + las 5
> (10-14) selladas construyendo `sentry_doctor.sh` en TAL-5157 (rondas de
> auditoría adversarial, 2026-09-02). Leer antes de operar y tras CUALQUIER
> resultado raro. El SKILL.md lleva el resumen; aquí el detalle.

## 1. Custom fetch transport de Sentry — la ausencia de eventos NO es salud

`src/sentry.server.config.ts` lleva un transporte fetch propio como workaround
del issue **getsentry/sentry-javascript#18871**; retirada trazada en TAL-417.
Un cambio de SDK que lo rompa se manifiesta como **caída de ingesta
server-side**, no como error. Por eso «0 eventos» puede ser ingesta muerta, no
calma — cruzar con Better Stack `/api/health/deep` y con la tasa esperada.

## 2. `-22 UnrecognizedActionError` tras cada deploy — esperado en la ventana

Cliente con **chunk viejo** invocando una Server Action que ya no existe en el
build nuevo. Esperado en la ventana de deploy; solo es incidente si persiste
pasada la ventana o trepa con `userCount>0`. Fix en curso: TAL-5127/#2109
(reload/tracking). Bucket `SA` (ver `03-…`).

## 3. NUNCA `ignoreErrors` para curar ruido — contrato del SDK

`ignoreErrors` matchea por **substring** (`isMatchingPattern` →
`value.includes(pattern)`) y **no ve el `mechanism`**, así que enmascararía un
fallo real que comparta subcadena. La curación va en **`beforeSend` con
igualdad EXACTA del mensaje Y del mechanism** (patrón de
`src/instrumentation-client.ts` y bloques M/N/7 de `sentry.server.config.ts`).
Aplica al ruido `M_ID` de extensión de navegador de TAL-5119. **Prohibido por
contrato, no por estilo.**

## 4. Fingerprints que se escinden por deploy

Frames in-app con chunk hasheado rompen el agrupamiento en cada build. La regla
vive en `src/lib/sentry-fingerprint.ts` (`mediaPlayFingerprint()`); toda fuente
nueva de `safePlay()` debe añadirse a `MEDIA_PLAY_SOURCES` o el grupo vuelve a
escindirse. Al citar frames en una issue, usar rutas `src/…`, no chunks
hasheados (campo 5 del contrato, `04-…`).

## 5. `scripts/sentry-api.sh` NO sirve en la fábrica

Saca el token de AWS Secrets con el perfil adjudicado de la instancia, **ausente en el
host**. Vía buena = header-file 0600 del escrow (ver `05-…`). No intentar
`sentry-api.sh list/show/resolve/ignore` desde la torre.

## 6. `error code: 1010` (HTTP 400) de la Management API = Cloudflare, no Postgres

Bloqueo Cloudflare por petición **sin `User-Agent`**, NO error de Postgres, y
puede llegar **tras un commit exitoso**. Verificar con un SELECT antes de
reintentar. Toda petición a la Management API lleva `User-Agent` explícito.

## 7. `sale_not_pending` de MercadoPago = idempotencia, no fallo

Suele ser el **guard anti-doble-cobro** (MP reenvía notificaciones), no un
fallo. Y **MP pendings en masa = abandonos del comprador** (0 `sale_events`),
no webhook caído. No escalar sin cruzar con `sale_events`.

## 8. El pane quieto NO prueba tick vivo

El despertador one-shot murió en silencio dos veces la primera noche (50 min y
3h24m). Ticker = **bucle infinito** con eco `TICK <ISO>` a un log + monitor
externo de staleness de la mtime. Verificar el eco, nunca la apariencia del
pane. `sentry_doctor.sh` mide la mtime del log (`check_tick`). Ver `01-…`.

## 9. `pkill -f`/`pgrep -f` con el nombre del propio watcher = self-match → exit 144

El pgrep aparece en su propia búsqueda. Matar por **PID exacto** o por un needle
fragmentado que no esté en la línea de comando del pgrep. Ver `01-…`.

---

## 10. La API GraphQL cruda de Railway responde HTTP 200 con el error EN EL BODY

Fuente: TAL-5157 (verificado en vivo, 2026-09-02). `{"errors":[…],"data":null}`
con HTTP 200. Usar SIEMPRE el CLI (`railway status --json`), nunca GraphQL
directo, y validar exit code **Y** que el stdout parsea como JSON (el CLI emite
texto plano, no JSON, cuando falla).

## 11. Carrera dedupe→issueCreate — riesgo residual, no fingido resuelto

Fuente: TAL-5157. `issueCreate` no es idempotente; la ventana entre el check de
dedupe y el create no está resuelta por software, solo **mitigada por diseño
serial** (una sola torre). Documentado como riesgo residual, no como cerrado.

## 12. Cero valor por defecto de marca/tenant en `sentry_doctor.sh`

Fuente: TAL-5157 (hallazgo en vivo del CEO, 2026-09-02). El default viejo de
Railway ("Academia Ejemplo") estaba MAL — el proyecto real es "Academia Ejemplo
2.0" — y el doctor lo habría aceptado en silencio de acertar por casualidad. La
corrección no es arreglar el valor: es **no tener ninguno** (invariantes
25b/c/e). Sin config, el doctor falla con "config ausente", nunca asume marca.
Vars: `SENTRY_DOCTOR_SENTRY_ORG`/`_SENTRY_PROJECT`/`_BETTERSTACK_MONITOR_ID`/
`_SUPABASE_PROJECT_REF`/`_RAILWAY_EXPECTED`.

## 13. `sentry_doctor.sh` separa FUENTES de RUNTIME/CICLO

Fuente: TAL-5157 (validación de C3). Checks de FUENTE (sentry/betterstack/
supabase/railway/linear) acreditan credencial y superficie — los corre un
TERCERO desde otra máquina. Checks de RUNTIME (ticker, cursor.json, bus,
sellar.sh) solo tienen sentido en la máquina de la Vigía. `--solo-fuentes`
para validación por terceros; `--completo` (default) solo desde la torre real.
Un validador externo que corra `--completo` da rojo por un motivo FALSO.

## 14. El validador externo usa overrides de header-file, NUNCA crea el runtime ajeno

Fuente: TAL-5157 (patrón de C3). Apuntar `SENTRY_DOCTOR_*_HDR` a header-files
0600 del PROPIO scratchpad del validador — nunca fabricar `~/.vigia-sentry/`/
`~/.vigia-supabase/` en la máquina del validador (son del runtime de la Vigía).

---

## Límite de confianza del doctor (declarado, no oculto)

`sentry_doctor.sh` endurece contra función exportada, `BASH_ENV` (parcial) y
PATH-a-mitad para los seis ejecutables externos que usa; **NO** cubre a quien
controla el entorno de ejecución del proceso (PATH ya envenenado al arrancar,
edición del propio script, shadow de builtins) — anteponer un directorio
escribible en PATH no necesita root. La garantía cubre el drift accidental y la
fabricación descuidada, no un adversario que controla el entorno. Detalle en la
cabecera de `scripts/sentry_doctor.sh`.
