# 05 — Fuentes, consultas y contrato de credenciales

> Fuente: TAL-5157 §B2 (las 4 fuentes con IDs reales) + el contrato del
> `sentry_doctor.sh` GO'd. Leer antes de tocar una fuente nueva o al levantar
> la torre. **Ningún token aparece nunca en argv, logs, sellos ni en el repo.**

## Doctrina de acceso (transversal)

- Credenciales por **header-file 0600** (`curl -H @<hdr>`), nunca en la línea
  de comando. El token JAMÁS se imprime, ni un fragmento.
- El doctor lee la **identidad del tenant por variable de entorno** (`SENTRY_
  DOCTOR_*`), sin ningún default de marca (gotcha #12 del SKILL, invariantes
  25b/c/e). Config ausente ⇒ PUERTA CERRADA con "config ausente", nunca asume
  una marca.
- El doctor construye la URL de cada fuente con un **literal de origen
  hardcodeado** (`https://sentry.io`, `https://api.supabase.com`, …) + la
  identidad declarada; NO acepta override de URL/host por entorno (cerró la
  clase de bypass de las rondas 1-6 de TAL-5157). El único inyectable es el
  cliente HTTP (`SENTRY_DOCTOR_HTTP_CLIENT`, solo para tests) y `main` ABORTA
  con exit 3 si detecta cualquier seam en producción. Ver la cabecera del
  propio `sentry_doctor.sh`.

## 1. Sentry issues API

- Org **`SENTRY_ORG`**, proyecto **`SENTRY_PROJECT`** (variables obligatorias del ciclo;
  el doctor exige `SENTRY_DOCTOR_SENTRY_ORG` y `SENTRY_DOCTOR_SENTRY_PROJECT` para la misma instancia).
- Ciclo (`sentry_triage.py`, PROJECT-scoped — NO el endpoint de organización,
  que puede mezclar grupos de otra superficie si la org tiene más de un
  proyecto Sentry, NO-GO #MAYOR-1 TAL-5157 r11):
  `GET /projects/<SENTRY_ORG>/<SENTRY_PROJECT>/issues/?query=is:unresolved&sort=date&statsPeriod=24h`,
  seguido de un 2º pase con `sort=freq`. `SENTRY_PROJECT` (env, sin default de
  marca) fija el slug del proyecto.
- Identidad exacta (el doctor la exige, no basta un 200):
  `GET /organizations/<SENTRY_ORG>/` → `slug == SENTRY_ORG`;
  `GET /projects/<SENTRY_ORG>/<SENTRY_PROJECT>/` → `slug == SENTRY_PROJECT`;
  issues **project-scoped**, shape SIEMPRE lista.
- Auth por header-file 0600. Regla de alerta existente en Sentry:
  `17042308` («Errors > 10/min in production»).
- Scopes del token: `org:read` + `project:read` + `event:read`.

## 2. Releases / deploys de Railway

- Release Sentry = `<SENTRY_RELEASE_PREFIX>@<sha-8>` (`src/lib/sentry-release.ts`,
  resuelto UNA vez en build time por `next.config.ts`; `SENTRY_RELEASE_PREFIX`
  es obligatorio por instancia y falla antes de consultar la red si falta).
- Correlación de deploy: **`railway status --json`** →
  `latestDeployment.{status,id}`. El doctor valida `.name` == el proyecto
  esperado (`SENTRY_DOCTOR_RAILWAY_EXPECTED`, obligatorio por instancia y sin default).
- **`NEEDS_APPROVAL` es un estado real y frecuente** que retiene el fix; el
  CEO lo destraba con `railway-approve.sh`. El Vigía lo **REPORTA, no lo
  aprueba** (límite duro B9).
- NUNCA la API GraphQL cruda: responde HTTP 200 con el error dentro del body
  (gotcha #10 del SKILL). Siempre el CLI, y validar exit code **Y** que el
  stdout parsea como JSON.

## 3. Better Stack Uptime

- Monitor **`4392730`** apuntando a **`/api/health/deep`** (ADR-0014
  amendment TAL-2505).
- El shallow `/api/health` es gate de deploy de Railway y **NO prueba
  Supabase**: **nunca** usarlo como señal de salud.
- API JSON:API (`{"data":{"id":…}}`); el doctor exige `data.id` == el monitor
  esperado. Token team-scoped.

## 4. Money-path SQL read-only (Supabase Management API)

- **`POST https://api.supabase.com/v1/projects/<SUPABASE_PROJECT_REF>/database/query`**
  (la ref viene de `SENTRY_DOCTOR_SUPABASE_PROJECT_REF`, nunca literal — hallazgo
  del texto CR-CLI corrida 3, medido: la ref del tenant estaba hardcodeada en
  este doc, invariante tenant-ready 25b), SOLO `select`/`with`.
- **Toda petición con `User-Agent` explícito** (gotcha #6 del SKILL:
  `error code: 1010` HTTP 400 = bloqueo Cloudflare por falta de User-Agent,
  NO error de Postgres — puede llegar tras un commit exitoso).
- Éxito = **HTTP 201** (no 200), body lista de filas-objeto (medido en vivo
  por C3 en TAL-5157: `select 1 as ok` → `201` + `[{"ok":1}]`).
- La ref del proyecto se valida con formato estricto `^[a-z0-9]{20}$` antes de
  construir la URL (corta traversal `ref/../otra`, bloqueante r7 de TAL-5157).
- Proxies ya rodados por C3: ventas stuck, `failed_1h`, sobre-crédito
  (`credited>total`), mismo importe completado 2+ veces por el mismo comprador.

## Linear (5ª superficie, de escritura — ver `04-contrato-de-issue.md`)

- `POST https://api.linear.app/graphql`, API key personal **sin** `Bearer`.
- El doctor pinga `viewer{id}` (string) como acreditación mínima.

## 7. GitHub — alertas de seguridad (6.ª fuente, SOLO lectura)

- Cliente: `gh api --method GET --paginate` (base declarada: gh 2.45.0; `--paginate` sin `--slurp`, la
  salida son una o varias listas JSON). Ninguna llamada de escritura: ni `--method` distinto de GET, ni
  `-f`/`-F`/`--input`; el Vigía no descarta, cierra ni comenta alertas.
- Repo por entorno, sin default de marca: `GITHUB_SEC_REPO` (`owner/nombre`); `GITHUB_SEC_SUPERFICIES`
  (lista separada por comas; por defecto las cuatro). El doctor lee `SENTRY_DOCTOR_GITHUB_REPO`.
- Endpoints (`/repos/{owner}/{repo}/…`, `per_page` ≤ 100, consultados el 2026-10-11):

| Superficie | Endpoint | Permiso del token |
|---|---|---|
| `dependabot` | `dependabot/alerts?state=open` | `security_events` |
| `code-scanning` | `code-scanning/alerts?state=open` | `security_events` |
| `secret-scanning` | `secret-scanning/alerts?state=open&hide_secret=true` | `repo` o `security_events` |
| `advisories` | `security-advisories` | `repo` o `repository_advisories:read` |

- Token por **header-file 0600** de una línea `Authorization: Bearer <token>`
  (`GITHUB_SEC_HDR` / `SENTRY_DOCTOR_GITHUB_HDR`, por defecto `~/.vigia-github/hdr`). Al subproceso
  `gh` llega por el entorno (`GH_TOKEN`), nunca por argv. Emisión, tipo y alcance del token: decisión
  diferida del CEO; sin header-file, fail-closed.
- El valor de un `secret` de GitHub jamás sale por ninguna salida: la petición lleva `hide_secret=true`,
  el campo se descarta al leer y cualquier aparición se enmascara en stdout, stderr, cuerpo de issue y log.
  El enmascarado se aplica a la SALIDA (cualquier longitud, también 1-3 caracteres), nunca a los datos con
  los que se cuenta o se decide: `state`, identidad y severidad se leen de los valores originales, y solo
  las representaciones salientes (título, URL, detalle, body, payload de `issueCreate`) pasan por `exponer`.
  Los secretos de TODAS las superficies declaradas se registran antes de construir o emitir nada, también
  en `--crear-issue`. El JSON conserva sus cinco claves y su vocabulario cerrado (nunca se enmascara el
  documento serializado). Si un secreto coincide con el identificador de una alerta abierta, el barrido
  aborta (rc 3) sin informe ni cursor. Todo lo que imprimen los helpers importados (errores de Linear
  incluidos) pasa por el mismo enmascarado. Lo vigila `tests/test-secretos-github.py`.
- Fallos de la fuente (rc 3, sin informe parcial ni cursor): 403/404 → `SUPERFICIE-NO-VIGILADA`;
  401, red caída, respuesta que no es una lista o paginación sin fin (tope de 20 páginas) →
  `FUENTE-FALLIDA`. Jamás se lee como «0 alertas».
- Cursor propio: `~/.vigia-github/cursor.json` (`GITHUB_SEC_CURSOR`), escritura atómica.
- Doctor: `check_github` acredita `full_name` del repo y que cada superficie declarada responde 200 con una
  lista (`https://api.github.com` literal, sin override de URL). Es una fuente **OPCIONAL**: sin
  `SENTRY_DOCTOR_GITHUB_REPO` el doctor no falla y muestra `github: no vigilada` (la ausencia se ve; una
  actualización del paquete no tumba un Vigía ya montado). Con la variable definida rige fail-closed: el
  header-file debe existir, ser 0600 y de una línea, y el repo y las superficies deben responder; si no,
  rc ≠ 0 con el motivo («config parcial …»). Retirar la sonda de `SONDAS_MANIFEST_FUENTES` sigue siendo un
  desvío del manifiesto y un seam sigue dando exit 3.
- Salida `--json` (esquema fijado, lo consume el parte de guardia): `superficies`, `nuevos`, `escala`,
  `no_vigiladas`, `total_abiertas`.

## Sonda antes de tocar nada

`bash scripts/sentry_doctor.sh` (o `--solo-fuentes` para validación por un
tercero desde otra máquina; `--completo` —default— solo desde la torre real,
ver gotchas #13/#14 del SKILL). PUERTA CERRADA ⇒ no se opera ninguna fuente.
