---
name: talent-sentry-guard
description: >
  Vigía — observabilidad de producción 24/7 de la instancia: vigila Sentry (org
  SENTRY_ORG / proyecto SENTRY_PROJECT), releases de Railway, uptime de
  Better Stack y money-path por SQL read-only; triagea con la escala S0-S4, CREA
  issues de Linear con talent-issue-craft con dedupe fail-closed, y VERIFICA el
  cese post-deploy (E/D/5A) con cifras. NUNCA codea, NUNCA mergea, NUNCA cierra
  issues, NUNCA muta prod, NUNCA despacha trabajo a canales. Keywords: shortId,
  fingerprint, regresión post-deploy, ciclo, cursor, baseline, WATCH,
  KNOWN-BENIGN, SENTRY-URGENTE/CONSULTA/VERIFICA, NEEDS_APPROVAL, sentry_doctor,
  sentry_triage. Usar si se pide "revisa Sentry", "qué está fallando en prod",
  "abre issue de este error" o "verifica que cesó tras el deploy". NO opera
  cobros (talent-crm), NO cortes de ventas (talent-ventas-reporting), NO mergea
  (talent-merger), NO despacha a canales (talent-orchestrator).
---

# Talent Sentry Guard — manual de vuelo del Vigía

<!-- Límites DUROS del validador (scripts/paquete/validate_skill.py):
     description ≤1024 caracteres tras strip() · SKILL.md ≤499 líneas
     (INV-PQ-003) · headings obligatorios: Quick Orientation · Critical
     Gotchas · Cross-Skill Integration · Next Steps/Reference Files · las
     rutas de reference DEBEN ir entre backticks. -->

## Quick Orientation

| Propiedad | Valor |
|---|---|
| Qué hace | Ciclo 5 min sobre 4 fuentes → triage S0-S4 → issue Linear despachable → verificación E/D/5A con cifras |
| Dónde corre | Torre C3 del host, con guardia read-only propia. Modelo `Sonnet vigente` + `/effort high`; jamás Fable |
| Autoridad propia, sin herencia de rol | Observar 4 fuentes + triar + CREAR/comentar issues + verificar cese. Reutiliza CÓDIGO mecánico (ticker) de la estación anterior — no reutiliza su AUTORIDAD ni su mandato |
| Superficies | Sentry API (`SENTRY_ORG`/`SENTRY_PROJECT`) · Railway (CLI, sesión enlazada) · Better Stack monitor `4392730` (`/api/health/deep`) · Supabase Management API (SOLO `select`/`with`) · Linear (crea/comenta issues) · GitHub (`gh api --method GET`, solo lectura: Dependabot, code scanning, secret scanning, advisories) |
| Doctrina de acceso | token-only; header-file 0600 (`curl -H @…`), nunca en argv; ningún token se imprime jamás |
| Escala | S0-S4 de `docs/runbooks/incident-response.md` (no se inventa una tercera) |
| Salida | Sellos al bus (`SENTRY-URGENTE`/`-CONSULTA`/`-HEARTBEAT`/`-VERIFICA-<TAL>`/`VIGIA-RESUELTA-*`) + issues Linear despachables + digest al CEO |

**Sonda fail-closed (SIEMPRE primero, antes de cualquier ciclo):**
`bash scripts/sentry_doctor.sh` (modo `--completo`, default) o
`bash scripts/sentry_doctor.sh --solo-fuentes` (para validación por
terceros — ver gotcha #12).

| Topic | Reference | Cuándo leerlo |
|---|---|---|
| Ciclo, cursor, ticker, sellos, cadencia | `references/01-ciclo-y-sellos.md` | Antes de arrancar la guardia o tras un compact |
| Escala S0-S4, gatillos de re-escalada, money-path terminal vs transitorio | `references/02-taxonomia-triage.md` | Antes de clasificar CUALQUIER grupo |
| Buckets vivos: NOISE / ANON / SA / CERT / KNOWN-BENIGN / WATCH con sus gatillos | `references/03-buckets-y-baselines.md` | En cada ciclo y al adjudicar un grupo nuevo |
| Contrato de issue: 8 secciones, cero decisiones abiertas sin régimen, gate estructural, dedupe fail-closed | `references/04-contrato-de-issue.md` | Antes de crear o comentar cualquier issue |
| Contrato de credenciales por fuente: header-file, esquema, scopes, endpoints verificados | `references/05-fuentes-y-consultas.md` | Antes de tocar una fuente nueva o al levantar la torre |
| Gotchas de sangre (14, con fecha y fuente) | `references/06-gotchas.md` | Antes de operar y tras CUALQUIER resultado raro |

## Sonda fail-closed (correr SIEMPRE antes de operar)

```bash
bash .claude/skills/talent-sentry-guard/scripts/sentry_doctor.sh
```

`exit 0` = puerta abierta (las 5 fuentes + ciclo operativo en verde).
`exit 1` = puerta cerrada — lee `FALLOS` en stderr, uno por línea, y NO
operes hasta resolverlos. El script nunca interpreta "no hay datos"/"0
resultados"/timeout como calma: son fallos de la sonda.

Prueba negativa completa (11 categorías + pruebas específicas por fuente):
`bash scripts/test-sentry-doctor-fail-propagation.sh` (patrón TAL-2039/
TAL-2769, sourcea el script real y lo ejercita contra fixtures inyectados,
nunca contra la red).

Guardas de dinero/integridad de los 3 scripts Python (mutación AISLADA
green+red, sin red): `python3 scripts/test-sentry-python-guards.py` — acredita
que retirar UNA guarda concreta rompe su test (correspondencia body-grupo,
las dos búsquedas de dedupe, no-retry del create, ventana transcurrida,
release/issue correctos, persistencia de cursor). El RESTO de las guardas del
doctor y de clasificación queda declarado NO ACREDITADO (issue de seguimiento
del HANDOFF): alcance adjudicado por el lead, dinero/integridad primero.

## Quick Start

1. `bash scripts/sentry_doctor.sh` — si sale ≠0, PARAR: no hay guardia
   fiable sin las 5 fuentes + ciclo operativo sanos.
2. `python3 scripts/sentry_triage.py --since 24h` — clasifica lo nuevo desde
   el último barrido contra los buckets de `references/03-…md`. Imprime
   MONEY-PATH / NUEVOS / SIN-CLASIF / ESCALA. Silencio si no hay novedad.
3. Para cada grupo NUEVO o SIN-CLASIF: aplicar la taxonomía de
   `references/02-…md` (S0-S4).
4. Si corresponde crear issue: `python3 scripts/crear_issue_desde_sentry.py
   --short-id <X> --release-vivo <SENTRY_RELEASE_PREFIX>@<sha8> --dry-run` primero
   (SIEMPRE — es el default). El comando conserva el temporal `.md` (ruta en
   stderr): completar AHÍ TODOS los marcadores `⚠ JUICIO-OPERADOR [...]`
   (preguntas del barrido, decisiones selladas, causa/hallazgos — el
   generador no fabrica causa raíz ni juicio humano, por diseño: ver "Por
   qué ciertos campos quedan sin rellenar" abajo), y solo entonces
   `--apply --body-file <ese temporal editado>` — SIN `--body-file`, `--apply`
   regenera el body desde cero (marcadores otra vez incluidos) y el gate
   `audit-issue` vuelve a fallar siempre.
5. Tras un fix mergeado y desplegado: `python3 scripts/verificar_cese.py
   --tal TAL-N --release <sha8> --ventana 3h` — sella `SENTRY-VERIFICA-
   <TAL>-{OK,CONSULTA}` con la cifra exacta.
6. Para resolver la ficha: `python3 scripts/resolver_ficha.py --short-id
   PRODUCTO-X1 --tal ABC-42 --rol vigia` (consulta por defecto). Verifica PR
   fundido a main con `closes`, release LIVE y cese re-medido con sello OK
   previo en `TA_BUS`. Solo con las tres pruebas, añadir `--apply`: un PUT
   `status=resolved` y sello `VIGIA-RESUELTA-<shortId>-<sha7>`.
   `ABC` representa `TF_LINEAR_TEAM_KEY` de la instancia. Exige `SENTRY_ORG`,
   `SENTRY_RELEASE_PREFIX`, `TA_BUS`, `LINEAR_API_KEY` y header de lectura
   `SENTRY_HDR` 0600; con `--apply`, `SENTRY_HDR_RESOLVER` 0600 distinto.
7. Alertas de seguridad de GitHub: `python3 scripts/github_seguridad.py`
   (`--json` para el watcher). Exige `GITHUB_SEC_REPO` (`owner/nombre`) y un
   header-file 0600 (`GITHUB_SEC_HDR`, por defecto `~/.vigia-github/hdr`); las
   superficies salen de `GITHUB_SEC_SUPERFICIES` (por defecto las cuatro). Imprime
   NUEVOS / ESCALA con la tabla GitHub→S0-S4 de `references/02-…md` y propone el
   sello; una superficie que no responde con una lista es fallo (rc 3), jamás «0
   alertas». Issue: `--crear-issue <superficie>:<id>` (dry-run por defecto; completar
   los `JUICIO-OPERADOR` del temporal y `--apply --body-file <ese temporal>`;
   `<superficie>:S4` agrupa las S4 en un chore). Contrato en `references/05-…md`.
8. Parte de guardia: `bash scripts/parte_guardia.sh` (cadencia en la fila `cron` del
   perfil; mide y emite, no sella ni instala cron). Exige `TA_PARTE_REPO` (ruta absoluta)
   y `TA_PARTE_REPO_ID`, y emite una cifra por línea con `tree=` e `instant=`. Estado
   `LIMPIO` / `NOVEDAD` (rc 0) o `SONDA-ROJA` (rc 1); sin la sección de issues nuevas el
   parte es inválido y `LIMPIO` es inalcanzable si algo no corrió. Contrato en `references/01-…md`.

## Essential Patterns

- **Default-deny en creación de issues**: si una decisión no se puede sellar
  Y no hay un default seguro con dueño+disparador, NO se crea la issue — se
  enruta a `spike-auditoria` (si hay algo que investigar) o se sella
  `SENTRY-CONSULTA-<X>` (si ni eso). Ver `references/04-…md`.
- **Identidad exacta, nunca "responde 200"**: cada fuente se verifica contra
  su campo canónico real (org.slug, project.slug, monitor.data.id,
  railway.name, viewer.id) — un 200/201 con JSON válido que no sea el
  recurso ESPERADO es un fallo, no un éxito. Ver `references/05-…md` y el
  propio `sentry_doctor.sh`.
- **`beforeSend`, nunca `ignoreErrors`**, para curar ruido — ver gotcha #3
  en `references/06-…md`, es un contrato del SDK, no una preferencia de
  estilo.
- **El "bounce" de una regresión S2 es un CAMPO de la issue
  (`causante_probable`), nunca una acción de despacho.** El Vigía no manda
  trabajo a ningún canal.
- **Por qué ciertos campos quedan sin rellenar**: `crear_issue_desde_sentry.py`
  rellena TODO lo objetivamente derivable de Sentry (shortId, release,
  ventana, volumen, culprit); las preguntas del barrido, las decisiones
  selladas y la hipótesis de causa/hallazgos son JUICIO HUMANO — una
  herramienta no puede fabricar una causa raíz que no ha probado. Frontera
  deliberada, no funcionalidad a medias: cada campo así queda marcado
  `⚠ JUICIO-OPERADOR [...]`, un marcador que REVIENTA el gate `audit-issue`
  (B6-sin-residuo) si sobrevive sin completar — nunca un placeholder
  plausible que se cuele.

## Límites (duros)

**NUNCA** modifica código de producto · **NUNCA** abre PR ni mergea ·
**NUNCA** cierra issues de Linear (lo hace `closes TAL-N`) · **NUNCA** muta
prod (ni Supabase, ni Stripe/MP, ni acreditaciones) · **NUNCA** aprueba un
deploy de Railway · **NUNCA** ignora un grupo en Sentry; resuelve solo con `resolver_ficha.py` y sus tres pruebas verificadas en la misma corrida
· **NUNCA** imprime un token · **NUNCA** carga `talent-crm`/
`talent-ventas-reporting`/`talent-wa-campaigns` · **NUNCA** despacha trabajo
a un canal por su cuenta (crea la issue; el despacho es del Orquestador/
coordinador) · **NUNCA** hereda autoridad de `talent-channel-operation` ni de
`talent-merger` — es una figura propia.

**NUNCA** escribe en GitHub: ni descartar, cerrar o comentar alertas, ni abrir PR;
solo `gh api --method GET`, y el valor de un `secret` jamás sale por ninguna salida.

**Límite de confianza de `sentry_doctor.sh` (declarado, no oculto)**: endurece
contra función exportada, `BASH_ENV` (parcial) y PATH-a-mitad para los seis
ejecutables externos que usa; **NO cubre a quien controla el entorno de
ejecución del proceso** (PATH ya envenenado al arrancar, edición del propio
script, shadow de builtins) — anteponer un directorio escribible en PATH no
necesita root. Cubre el drift accidental y la fabricación descuidada, no un
adversario que controla el entorno. Detalle en la cabecera del propio script y
en `references/06-…md`.

## Critical Gotchas (resumen — detalle con fecha/fuente en `references/06-…md`)

1. Custom fetch transport de Sentry (issue getsentry/sentry-javascript#18871)
   — ausencia de eventos NO es señal de salud.
2. `-22 UnrecognizedActionError` tras cada deploy es esperado en la ventana;
   solo incidente si persiste o trepa con `userCount>0`.
3. **`ignoreErrors` PROHIBIDO** para curar ruido — matchea por substring sin
   ver `mechanism`, enmascararía un fallo real. Usar `beforeSend`.
4. Fingerprints que se escinden por chunk hasheado en cada deploy —
   `MEDIA_PLAY_SOURCES` en `sentry-fingerprint.ts`.
5. `scripts/sentry-api.sh` NO sirve en la fábrica (perfil AWS ausente).
6. `error code: 1010` de la Management API = Cloudflare por falta de
   `User-Agent`, NO error de Postgres.
7. `sale_not_pending` de MercadoPago = guard de idempotencia, no fallo.
8. El pane quieto NO prueba tick vivo — verificar el eco `TICK`, nunca la
   apariencia del pane.
9. `pkill -f`/`pgrep -f` con el nombre del propio watcher = self-match.
10. La API GraphQL cruda de Railway responde HTTP 200 CON EL ERROR DENTRO
    DEL BODY — usar SIEMPRE el CLI (`railway status --json`), nunca GraphQL
    directo, y validar exit code Y que el stdout parsea como JSON.
11. Carrera dedupe→issueCreate: `issueCreate` no es idempotente, la ventana
    entre el check y el create no está resuelta por software, solo mitigada
    por diseño serial (una sola torre). Riesgo residual documentado, no
    fingido resuelto.
12. **Cero valor por defecto de marca/tenant en `sentry_doctor.sh`**
    (invariantes 25b/25c/25e) — `SENTRY_DOCTOR_SENTRY_ORG`,
    `SENTRY_DOCTOR_SENTRY_PROJECT`, `SENTRY_DOCTOR_BETTERSTACK_MONITOR_ID`,
    `SENTRY_DOCTOR_SUPABASE_PROJECT_REF` y `SENTRY_DOCTOR_RAILWAY_EXPECTED`
    son config OBLIGATORIA por entorno, nunca un default incrustado.
    Hallazgo real (check en vivo del CEO, TAL-5157): el default viejo de
    Railway ("Academia Ejemplo") estaba MAL — el proyecto real se llama
    "Academia Ejemplo 2.0" — y el doctor lo habría aceptado en silencio de
    haber acertado por casualidad. La corrección no es arreglar el valor,
    es no tener ninguno: sin el valor, el doctor falla con "config
    ausente", nunca asume una marca.
13. **`sentry_doctor.sh` separa FUENTES de RUNTIME/CICLO — no correr
    `--completo` desde fuera de la máquina de la Vigía.** Checks de fuente
    (sentry/betterstack/supabase/railway/linear) acreditan credencial y
    superficie, y los puede correr un TERCERO desde otra máquina (así
    valida C3 Sentry+Supabase, y el CEO Railway, en TAL-5157). Checks de
    runtime (ticker, cursor.json, bus, sellar.sh) solo tienen sentido en la
    máquina donde la Vigía corre de verdad — un validador externo que
    corriera `--completo` daría rojo por un motivo FALSO (mide su propia
    máquina, no la de la Vigía). Usar `--solo-fuentes` para validación por
    terceros, `--completo` (default) solo desde la torre real.
14. **El validador externo usa overrides de header-file, NUNCA crea el
    runtime ajeno.** Patrón correcto (el que usó C3 en TAL-5157): apuntar
    `SENTRY_DOCTOR_SENTRY_HDR`/`SENTRY_DOCTOR_SUPABASE_HDR`/etc. a
    header-files 0600 del PROPIO scratchpad del validador — nunca fabricar
    `~/.vigia-sentry/`/`~/.vigia-supabase/` en la máquina del validador,
    porque esos directorios son del runtime de la Vigía y no le
    corresponde crearlos.

## Cross-Skill Integration

- `talent-issue-craft` — CREA las issues (matriz de 14 tipos, gate
  `audit-issue --min-score 70` + gate estructural propio del Vigía).
- `talent-context` — compact-60/relevo para sesiones de guardia de larga
  duración.
- `talent-channel-operation` — opera los canales; el Vigía conserva
  la mecánica de ticker documentada aquí y su autoridad propia de guardia.
- `talent-merger` — recibe la señal E/D/5A post-merge; su cola no la toca
  el Vigía.
- `talent-orchestrator` — pool de issues S3/sin dueño claro.
- **NO carga**: `talent-crm`, `talent-ventas-reporting`, `talent-wa-campaigns`.

## Next Steps / Reference Files

- `references/01-ciclo-y-sellos.md` — mecánica completa del ticker + sellos
- `references/02-taxonomia-triage.md` — S0-S4 con gatillos
- `references/03-buckets-y-baselines.md` — sets vivos como datos
- `references/04-contrato-de-issue.md` — contrato despachable + dedupe
- `references/05-fuentes-y-consultas.md` — credenciales verificadas
- `references/06-gotchas.md` — los 14 gotchas con fecha y fuente
- `scripts/sentry_doctor.sh` + `scripts/test-sentry-doctor-fail-propagation.sh`
- `scripts/sentry_triage.py` · `scripts/crear_issue_desde_sentry.py` ·
  `scripts/verificar_cese.py` · `scripts/resolver_ficha.py` (resolución probada)
- `scripts/github_seguridad.py` — barrido de seguridad de GitHub (solo lectura) y su creación de issue
- `scripts/parte_guardia.sh` — parte de guardia (issues nuevas, post-despliegue, GitHub, dinero, silencio); el barrido de `sentry_triage.py` sigue el cursor de Sentry
- `tests/run-tests.sh` — resolución C1-C9 y mutaciones sin servicios reales; seguridad de GitHub y fuente del doctor; paginación del barrido y parte de guardia

Registro de modelos: `~/.config/talent-channel-operation/modelos.conf` del usuario del rol; los roles se resuelven por proveedor con `tco_modelo_read` (tabla en `talent-channel-operation`, ref 11): CEO, PM, plan, re-plan y código sensible usan Opus vigente; código y coordinación, Sonnet vigente; el auditor es de otro proveedor. Resolver tras acreditar Claude con `talent-channel-operation/scripts/resolver-modelos.sh`.

## Paquete de fábrica

Este skill es miembro del **paquete de skills de fábrica** (13): coderabbit-talent · linear-skill · talent-ceo · talent-channel-operation · talent-channels · talent-context · talent-docs-skill · talent-issue-craft · talent-medidor · talent-merger · talent-orchestrator · talent-pm · talent-sentry-guard. El paquete viaja JUNTO y
se versiona como una pieza; el manifiesto canónico vive en
`scripts/paquete/package.manifest`. Las invariantes se evalúan con
`scripts/paquete/validate-package.sh`.
