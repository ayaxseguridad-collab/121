# Rate limits, Fair Usage y presupuesto de reviews

`last_verified: 2026-09-22`

Verificado contra <https://www.coderabbit.ai/pricing> (JSON estructurado embebido, sin fecha de
publicación expuesta; re-verificado 2026-09-22 con `curl` + grep sobre el JSON embebido — precios y
tope de PR reviews/dev/h idénticos al snapshot del 2026-09-05), <https://docs.coderabbit.ai/faq>,
<https://docs.coderabbit.ai/management/rate-limits> (indexada 2026-09-01),
<https://docs.coderabbit.ai/management/review-usage-dashboard>,
<https://docs.coderabbit.ai/management/plans> (tabla vieja, ver §8 sobre su desfase),
<https://docs.coderabbit.ai/triage/index> (consultada 2026-09-22, requisitos de CodeRabbit Triage)
y comentarios reales «Run configuration» del bot en PR #2260/#2243 de este repo — consultados
2026-09-05 salvo donde se indica re-verificación 2026-09-22.

> **Rebranding de planes (2026-08-13, ligado al lanzamiento de CodeRabbit Security)**: CodeRabbit
> renombró **Pro → Essentials** y **Pro+ → Team**, y añadió un plan nuevo **Advanced** entre Team y
> Enterprise. Cita literal de la FAQ: *"Essentials is the new name for Pro, and Team is the new name
> for Pro Plus... Essentials retains the current Pro price... Team retains the current Pro Plus
> price."* Este documento preserva el nombre de fichero (`rate-limits.md`, contrato citado por
> `docs/runbooks/coderabbit-cli-pre-pr.md:398`) pero todo el vocabulario interno es el nuevo.

## Tabla de contenidos

1. [Planes y precios](#1-planes-y-precios)
2. [Mecánica del límite](#2-mecánica-del-límite)
3. [Tabla de review events](#3-tabla-de-review-events)
4. [Fair Usage: throttling escalonado](#4-fair-usage-throttling-escalonado)
5. [El check «Review rate limited»](#5-el-check-review-rate-limited)
6. [Dashboard Review Usage](#6-dashboard-review-usage)
7. [Cómo consultar plan y cuota](#7-cómo-consultar-plan-y-cuota)
8. [Mapping org → plan de este repo](#8-mapping-org--plan-de-este-repo)
9. [CodeRabbit Security (Advanced+)](#9-coderabbit-security-advanced)
10. [Mitigaciones priorizadas](#10-mitigaciones-priorizadas)
11. [Anti-patrones con nombre propio](#11-anti-patrones-con-nombre-propio)
12. [Gotchas y referencias cruzadas](#12-gotchas-y-referencias-cruzadas)

## 1. Planes y precios

**Re-verificado 2026-09-22** contra el JSON embebido de <https://www.coderabbit.ai/pricing>
(`curl` + grep sobre `AnnualPrice`/`Price`/`Detail`, sin depender de parseo visual de la página):
precios, tope de PR reviews/dev/h, archivos/review, repos enlazados, MCP connections y custom
pre-merge checks **idénticos** al snapshot del 2026-09-05 — cero cambios de números en esta tabla.

| Plan | Precio (anual / mensual) | PR reviews/dev/h | CLI (histórico, ver nota) | Chat | Archivos/review | Repos enlazados | MCP | Custom pre-merge checks |
|---|---|---|---|---|---|---|---|---|
| **Essentials** (ex Pro) | $24/dev/mes · $30/dev/mes | **5\*** | 5 (inferido) | 50 | 150 | 1 | 5 | No incluido |
| **Team** (ex Pro+) | $48/dev/mes · $60/dev/mes | **8\*** (10 si grandfathered — ver §4) | 8 (inferido) | 75 | 300 | 5 | 10 | 10 |
| **Advanced** (nuevo, 2026-08-13) | $72/dev/mes · $90/dev/mes | **10\*** | 10 (inferido) | 100 (inferido, sin republicar) | 300 | 10 | 15 | 20 |
| **Enterprise** | contactar ventas | **12** (sin adaptativo — §4) | 12 (inferido) | — (no republicado) | 300 | 20 | 20 | 20 |

Fuente de cada columna (verificación original 2026-09-05, cifras re-confirmadas 2026-09-22):

- **PR reviews/dev/h**: fila con asterisco de la pricing page — *"PR reviews per developer per hour
  5\* 8\* 10\* 12"* (Essentials/Team/Advanced/Enterprise) + FAQ literal: *"Essentials includes 5 PR
  reviews per hour, Team includes 8, Advanced includes 10, and Enterprise includes 12."*
- **Chat**: 50 y 75 confirmados (FAQ + `hechos-vivos.md` del spike ABC-5465, 2026-09-05); **100 para
  Advanced es INFERIDO** (continuidad con el valor de Pro+ en la tabla vieja `management/plans`,
  que NO usa los nombres nuevos) — no está republicado bajo el nombre "Advanced" en ninguna fuente
  oficial verificada. Enterprise queda como "no republicado" por la misma razón.
- **CLI**: la pricing page de hoy **no** tiene una fila "CLI" separada de "PR reviews/dev/h". La
  tabla vieja (`docs.coderabbit.ai/management/plans`, no migrada a los nombres nuevos) sí tenía una
  columna CLI idéntica 1:1 a la de PR reviews/dev (Pro 5 / Pro+ 10 / Enterprise 12). Se marca como
  **inferido, sin confirmar bajo los nombres nuevos** — no asumir que es un hecho verificado.
- **Archivos/review**: *"Pro reviews are limited to 150 files, while Pro+ reviews are limited to 300
  files. The overall ceiling remains 300 files."* (changelog 2026-07-15) → Essentials 150 / Team+
  300. No hay anuncio posterior de cambio con el rebranding.
- **Repos enlazados** (Multi-repo analysis): *"Multi-repo analysis | 1 | 5 | 10 | 20"* (pricing).
- **MCP connections**: *"MCP connections | 5 | 10 | 15 | 20"* (pricing).
- **Custom pre-merge checks**: *"Custom pre-merge checks | Not included | 10 | 20 | 20"* (pricing).

El trial gratuito de 14 días hoy empieza en **Advanced** por defecto (antes "Pro+ trial"):
*"Your trial starts on the Advanced plan."* (subscription-management, 2026-09-05).

> **CodeRabbit Triage (nuevo, 15-sep-2026)** exige, simultáneamente: **GitHub Cloud** (GitHub
> Enterprise Server no soportado — *"Triage is available on GitHub Cloud. GitHub Enterprise Server
> is not supported."*), plan **Team o superior** (*"Triage is generally available on the Team plan
> and higher for GitHub Cloud organizations."*) y un **seat de Review activo** para poder abrirlo.
> Fuente: changelog oficial 15-sep-2026 + <https://docs.coderabbit.ai/triage/index> (verificado
> 2026-09-22). Este repo (`ejemplo`, Team, GitHub.com — §8) cumple los tres requisitos.

## 2. Mecánica del límite

- **Por developer, por organización.** La misma identidad GitHub tiene buckets independientes en
  cada org — Team en una org no se contamina con Essentials en otra.
- **Allowance refillable continua** — no hay reset en punto de hora: "reviews become available
  again over time instead of resetting all at once at the top of the hour". La tasa numérica de
  refill dentro de cada escalón sigue sin publicarse.
- **Qué consume 1 review**: cada PR review run (incluidos los incrementales automáticos tras un
  push, `@coderabbitai review` manual y `@coderabbitai full review`).
- **Qué NO consume review**: `@coderabbitai rate limit`, `pause`, `resume`, `ignore`,
  `configuration`, `help`, resolver threads vía GraphQL, un push bloqueado por rate limit (0 —
  nunca se factura ni se descuenta lo que no corrió).
- **Al agotar la cuota**: CR pausa nuevos reviews y postea/edita un comentario de aviso. El review
  bloqueado **NO se reintenta solo** — hay que re-disparar con `@coderabbitai review` tras la
  espera, o empujar un commit nuevo.

```text
push / @coderabbitai review
        │
        ▼
 ¿allowance > 0 para (developer, org)?
        │
   ┌────┴─────┐
   │ sí        │ no
   ▼           ▼
review corre   comentario "Rate limit exceeded" + check
(-1 del        "Review rate limited" (pasa por diseño, §5)
 bucket)       └─ el review NO se reintenta solo
```

## 3. Tabla de review events

Cada uno de estos eventos consume **1 review** del bucket del developer, incluso si agrupa varios
commits o no produce comentarios nuevos:

| Evento | Consume 1 review |
|---|---|
| Abrir el PR (con `auto_review.enabled: true`) | Sí |
| Push nuevo (agrupa N commits del mismo push) | Sí (1 por push, no por commit) |
| Editar un archivo en la web UI de GitHub | Sí (= commit + push = 1 evento) |
| Botón «Update branch» | Sí |
| Botón «Resolve conflicts» (o `@coderabbitai resolve merge conflict`) | Sí |
| Force-push / rebase | Sí |
| Reabrir el PR (reopen) | Sí |
| Marcar un draft como «Ready for review» | Sí |
| `@coderabbitai review` / `full review` manual | Sí |
| Push bloqueado por rate limit | **No** (0 — nunca corrió) |
| Review continuado con créditos del add-on usage-based | No consume allowance del plan (se factura aparte) |
| `@coderabbitai rate limit` / `pause` / `resume` / `ignore` / `configuration` / `help` | No |

**Relevante para el Mergeador** (`talent-merger`, que rebasea/reabre PRs como parte de la
renumeración de slots): cada rebase o reopen de un PR ya revisado gasta un review adicional del
mismo bucket, sin que sea evidente en el flujo — presupuestar esto en olas de fusión con muchos
encargos.

## 4. Fair Usage: throttling escalonado

Ventana rolling de 7 días; se activa al alcanzar el **percentil 95+** del uso reciente de la
organización. La escalera numérica **no cambió** respecto a la verificación anterior (2026-07-11);
lo que cambió son las **columnas a las que aplica cada fila**, porque Team ya no es el techo alto:

```text
Reviews acumuladas en 7 días  →  Reviews/hora disponibles
Essentials (base 5/h)            Team estándar / Advanced (base 8-10/h)
┌──────────┬─────────┐            ┌──────────┬─────────┐
│  0–29    │    5    │            │  0–29    │  8 / 10 │
│  30–39   │    4    │            │  30–39   │    8    │
│  40–49   │    3    │            │  40–49   │    6    │
│  50–59   │    2    │            │  50–59   │    5    │
│  60+     │    1    │            │  60–69   │    4    │
└──────────┴─────────┘            │  70–79   │    3    │
                                   │  80–89   │    2    │
                                   │  90+     │    1    │
                                   └──────────┴─────────┘
```

- **Team's standard refill rate is capped at 8 reviews per hour. Grandfathered Team organizations
  and Advanced organizations can receive up to 10.** (cita literal, `management/rate-limits`).
  Es decir: hoy hay DOS poblaciones bajo "Team" — la estándar (tope 8/h) y la grandfathered desde
  el antiguo Pro+ (ex Pro+, tope 10/h) — sin que el nombre del plan por sí solo diga cuál aplica.
- **Enterprise: sin límite adaptativo.** *"Enterprise developers do not have an adaptive limit."*
  — nunca entra en esta escalera, siempre 12/h fijo.
- El aviso al usuario sigue siendo el mismo comentario "Rate limit exceeded" — no hay mensaje
  distinto para el throttle de Fair Usage, solo cambian las esperas.
- **Mitigación real de este repo**: el gate CR-CLI local pre-push (ABC-1518,
  `docs/runbooks/coderabbit-cli-pre-pr.md`) resuelve buena parte de los comentarios ANTES de que el
  PR consuma una review del bucket del GitHub App — hace parcialmente obsoletas las mitigaciones
  manuales de §10, que siguen siendo plan B si el CLI no está disponible.

## 5. El check «Review rate limited»

> *"When a push is rate-limited, CodeRabbit posts a rate-limit comment on the pull request and a
> passing check titled 'Review rate limited' — the check passes by design so it never blocks
> merging on protected branches. The comment is the authoritative signal that no review ran. A
> previously approved PR keeps its approval."*

Tres consecuencias operativas:

1. El check de GitHub llamado **"Review rate limited" pasa SIEMPRE, por diseño** — nunca es un gate
   real. No confundirlo con `local-gates` (el gate propio del repo, regla 12 de CLAUDE.md).
2. En otras configuraciones (`review_progress`/`commit_status` sin coordinar — ver
   `references/yaml-reference.md` §3), el status `CodeRabbit` puede quedar en **`FAILURE`** por
   rate limit. Ese `FAILURE` **NO es un veredicto de review** — es infraestructura de cuota, no una
   señal de que el código tiene problemas. Un caso real documentado (HN/blog, 2026-07-14) muestra
   este `FAILURE` bloqueando un merge-gate fail-closed que lo trataba como veredicto — evitar ese
   error de diseño en cualquier gate propio.
3. Un PR **ya aprobado** conserva su aprobación aunque un push posterior quede rate-limited — el
   rate limit no revoca aprobaciones previas.

## 6. Dashboard Review Usage

Disponible desde Essentials en adelante (solo cloud), requiere permiso `metrics:read`. En
`Analytics → Review Usage` del dashboard de CodeRabbit muestra, por developer y por org: review
events, cuánto de eso fue bloqueado vs. continuado con créditos, el "adaptive limit" vigente y su
historial, y un "Review Log" que marca clusters de pushes a <5 min como candidatos a review
"superseded" (gastado sin producir feedback útil).

> **Limitación importante**: *"Reviews from the CLI and IDE extensions draw on separate allowances
> and do not appear here."* — el dashboard NO cubre consumo de CLI ni de extensiones de IDE, solo
> el bucket del GitHub App.

Publicado 2026-09-01. Coexiste con el dashboard de Billing (`app.coderabbit.ai/settings/
subscription`, rol Admin/Billing Admin) que sigue existiendo para plan y facturación.

## 7. Cómo consultar plan y cuota

- **`@coderabbitai rate limit`** (o `@coderabbitai reviews remaining?`) en cualquier PR — devuelve
  límite y refill timing **sin consumir review**. El walkthrough de cada review también muestra la
  cuota restante y cuándo rellena.
- **Dashboard Review Usage** (`Analytics → Review Usage`, §6) — mejor herramienta para diagnosticar
  consumo y throttling histórico; no cubre CLI/IDE.
- **Dashboard de Billing** (`app.coderabbit.ai/settings/subscription`) — plan y facturación.
- **NO existe API de subscription/plan/usage/rate-limit-quota.** El índice completo de
  `api-reference/*` (`docs.coderabbit.ai/llms.txt`, 2026-09-05) no tiene ningún endpoint así. Existe
  `GET /v1/metrics/reviews` (Metrics Data API) pero es **Enterprise-only** — responde `403 FORBIDDEN`
  con `"API access requires an Enterprise plan subscription"` para cualquier otro plan, y aunque se
  tuviera acceso, mide PRs *mergeados* (complejidad, tiempos, comentarios por severidad), no cuota
  de Fair Usage restante. Por eso el plan se resuelve con el mapping estático de `detect_plan.sh` +
  verificación viva con `@coderabbitai rate limit` antes de presupuestar una ola.
- **Metrics API: 503 + `Retry-After` mientras las métricas aisladas preparan (nuevo, 20-sep-2026).**
  Aplica a `GET /v1/metrics/mcp` (uso del servidor MCP) y a `GET /v1/metrics/review-comments`
  (metadata de findings por comentario de review — Enterprise-only, publicado 9-sep-2026, expone
  severidad/categoría/resolución por comentario en PRs mergeados, sin el texto del comentario). Si
  cualquiera de los dos responde `503`, leer la cabecera `Retry-After` y reintentar la MISMA
  petición tras esperar ese número de segundos — no reintentar antes ni cambiar la petición. Fuente:
  changelog oficial, entrada "Metrics API retries", 20-sep-2026 (consultado 2026-09-22). Ninguno de
  los dos endpoints devuelve cuota de Fair Usage restante — siguen siendo, como el resto de
  `api-reference/*`, endpoints de métricas/analítica, no de subscription/plan/usage-quota.
- Comandos `@coderabbitai` en ráfaga pueden perderse sin error — esperar a que termine uno antes de
  mandar el siguiente.

## 8. Mapping org → plan de este repo

| Organización GitHub | Plan | PR reviews/dev/h | Notas |
|---|---|---|---|
| `ejemplo` | **Team** (ex Pro+) | 8 estándar (10 si grandfathered) | Este repo (Example Project 2.0). Confirmado por comentarios «Run configuration: Plan: Team» del bot en PR #2260/#2243 (fundidos 2026-09-05) |

**Cuál de las dos cifras (8 u 10) aplica a `ejemplo` NO está confirmado en esta
verificación** — el comentario "Run configuration" cita el nombre del plan, no el tope de refill
exacto. Antes de presupuestar el consumo de una ola multi-canal, confirmar con
`@coderabbitai rate limit` (no consume cuota) o releer el dashboard Review Usage (§6). El mapping
completo de otras orgs de la casa (si difieren) vive en `scripts/detect_plan.sh` — mantenerlo
sincronizado con este documento si cambia una suscripción.

> Nota de fuente cruzada: `docs.coderabbit.ai/management/plans` (la página de referencia "vieja")
> seguía mostrando Free/OSS/Pro/Pro+/Enterprise sin fila Advanced al momento de esta verificación
> (2026-09-05) — es decir, **la propia documentación de CodeRabbit está a medio migrar** entre esa
> página y la pricing page (ya migrada). Se trata la pricing page como más autorizada por ser más
> reciente y tener columnas con asterisco explícitas; re-verificar `management/plans` en la próxima
> revisión del skill por si ya se actualizó.

## 9. CodeRabbit Security (Advanced+)

Lanzado 2026-08-13 (<https://www.coderabbit.ai/blog/introducing-coderabbit-security>). Workflow de
4 etapas (Map → Hunt → Verify → Fix) ejecutado por agentes en sandbox para encontrar
vulnerabilidades application-specific (IDOR, bypass de autorización, lógica de negocio, paths de
prompt-injection) más allá de SAST tradicional. *"Continuous security monitoring and security
reviews on pull requests are included with Advanced and Enterprise."*

Example Project opera en **Team**, por lo que **hoy no tiene acceso** a CodeRabbit Security. Se deja
documentado como feature-gate informativo para cuando el lead evalúe subir de plan — CLAUDE.md
regla 16 ya clasifica superficies sensibles (auth/RLS, pagos, migraciones SQL) que este producto
apunta a cubrir. Subir de plan es una decisión de producto/coste del lead (regla 7), no autónoma de
este skill.

## 10. Mitigaciones priorizadas

1. **Batching de pushes** — commitear local con frecuencia, empujar en lotes. Recomendado por el
   propio bot ("We recommend that you space out your commits").
2. **`reviews.auto_review.auto_pause_after_reviewed_commits`** (default 5) — pausa los
   incrementales tras N commits revisados desde la última pausa; `0` lo desactiva (y ese `0` hace
   que "every eligible push can trigger another review" — quema cuota). Ponerlo en `1`-`2` en ramas
   calientes. Tras la pausa, `@coderabbitai review` pide el siguiente; `resume` reactiva los
   automáticos (contador se resetea).
3. **`ignore_usernames: ["dependabot[bot]", "renovate[bot]"]`** — precedencia absoluta sobre los
   demás controles; los PRs de bots de dependencias se revisan por defecto si no se excluyen.
4. **Drafts + WIP**: `drafts: false` es default; `ignore_title_keywords: ["WIP", ...]` salta el
   review en silencio.
5. **Opt-in por label**: `auto_review.enabled: false` + `labels: ["review-ready"]` invierte el
   default. Sintaxis negativa: `"!do-not-review"`.
6. **Por PR**: `@coderabbitai pause`/`resume` o `@coderabbitai ignore` (en la DESCRIPCIÓN del PR).
   No consumen cuota.
7. **Add-on usage-based** (no en trial): $1.00 = 1 crédito, $0.25 por archivo revisado (4
   archivos/crédito). Resuelve el muro del límite de PLAN; **NO exime de Fair Usage** (el
   espaciado por identidad sigue aplicando).

## 11. Anti-patrones con nombre propio

La doc oficial nombra explícitamente cuatro anti-patrones que activan Fair Usage o desperdician
cuota:

- **Superseded reviews** — pushes a <5 minutos entre sí que "se superseden": la review anterior se
  descarta y la cuota gastada no produce feedback útil.
- **Reviewing work-in-progress branches** — ramas en desarrollo activo con auto-review habilitado
  sin `drafts: false` ni `ignore_title_keywords`.
- **One identity for every pull request** — una sola identidad de developer abriendo/empujando
  todos los PRs de una ola (el perfil típico de un sistema de canales con una sola cuenta GitHub).
  Umbrales exactos: **90+ reviews/7 días en Team** o **60+ en Essentials** hacen caer el refill a
  1/h para esa identidad — coincide con el escalón final de la tabla de §4.
- **Automatic reviews** ruidosos — `auto_incremental_review: true` sin `auto_pause_after_reviewed_
  commits` ajustado en ramas de alta cadencia de push.

## 12. Gotchas y referencias cruzadas

- `references/yaml-reference.md` §3-4 — `auto_review`, `review_progress`/`commit_status` y su
  interacción con el check de rate limit.
- `references/gate-cli-del-repo.md` — cómo el gate CR-CLI local evita gastar reviews del bucket del
  App antes de llegar al PR.
- `talent-merger/references/04-coderabbit-cli-y-app.md` — doctrina de estación: el CLI limpio
  autoriza el merge; el App queda como fallback (label `cr-review`) precisamente para no competir
  por el mismo bucket de PR reviews/h en cada encargo.
- `scripts/detect_plan.sh` — mapping org→plan operacional; debe mantenerse sincronizado con §8.
- Retirado de esta revisión: cualquier nota "pendiente de actualizar" o placeholder de Fair Usage
  sin publicar que citaba el runbook — la escalera completa ya está publicada (§4) y esa nota ya no
  aplica.
