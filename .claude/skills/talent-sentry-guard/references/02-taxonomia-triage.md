# 02 — Taxonomía de triage (S0-S4)

> Fuente: TAL-5157 §B3. Se ANCLA a las escalas que YA tiene el repo, no se
> inventa una tercera: `docs/runbooks/incident-response.md` usa **S0-S4**
> (severidad de incidente); `docs/runbooks/sentry-triage.md` usa P0-P3
> (priority de Linear). El Vigía usa **S0-S4 como severidad** y **P como
> consecuencia** (priority de la issue). Leer antes de clasificar CUALQUIER
> grupo.

## Tabla de clases

| Clase | Criterio observable | Acción del Vigía | Sale como |
|---|---|---|---|
| **S0/S1 money o auth** | dinero movido/perdido, checkout bloqueado a MÚLTIPLES compradores, auth caído, `userCount>0` en grupo terminal money-path | Sello `SENTRY-URGENTE-*` al instante + escalada al CEO en terminal + issue `fix\|sev1` (o `fix\|seguridad+sev1`) prioridad Urgent | Issue Urgent + hotfix; GO del lead si toca dinero de alumnos |
| **S2 regresión post-deploy** | grupo nuevo o que trepa cuya `firstSeen` cae dentro de la ventana del release vivo; correlación 1:1 con el sha del deploy | Issue `fix\|none` prioridad High + campo `causante_probable` = canal DUEÑO del PR (por `closes TAL-N` del PR que introdujo el sha) | Issue P1; el DESPACHO lo hace el Orquestador/coordinador, no el Vigía |
| **S3 crónico acotado** | conteo bajo, `userCount 0` estable, superficie no-money (p. ej. 4Y `/upgrade` 42501, cluster `/ranking`) | Entra al set **WATCH** con GATILLO explícito de re-escalada escrito; issue solo si el gatillo dispara | Backlog P2 o nada |
| **S4 ruido** | extensiones de navegador (M_ID, DarkReader, wallets), WebKit/red, deploy-window blips, fail-closed anón 42501 en rutas gated | Curación en `beforeSend`, NUNCA `ignoreErrors` (gotcha #3) → issue `chore\|none` con el filtro exacto | Chore P3 agrupado |
| **Duplicado** | fingerprint/shortId ya ligado a una issue Linear abierta | NO crea issue: comenta el delta (conteo/ventana/release) en la existente + tag `linear:TAL-N` en el grupo Sentry | Comentario, cero issue nueva |
| **Benigno adjudicado** | el CEO/lead adjudicó benigno con evidencia (p. ej. 8E, 93) | Entra a **KNOWN-BENIGN** con 3 triggers de re-escalada escritos; se rebaselina | Nada |

## Regla de oro: terminal vs transitorio (heredada de C3, sellada)

- Un grupo money-path **TERMINAL** (`gave_up`, `dead-letter`,
  `reconcile-fail`) **se escala SIEMPRE**.
- `sale_not_pending` es la EXCEPCIÓN dentro de terminal (T07 v4, revisor
  #2165, hallazgo [5] — resuelve el conflicto real entre esta regla y
  gotcha #7, que antes decían cosas opuestas sin remisión clara): **antes**
  de escalar, se **correlaciona con `sale_events`**. Si la correlación
  confirma que es el guard de idempotencia esperado (MP reenvía
  notificaciones, `sale_events` sin novedad real) → **NO se escala**, es
  ruido operativo normal. Si la correlación NO lo confirma (hay
  `sale_events` real sin conciliar, o la consulta de correlación falla) →
  se escala igual que el resto de terminal — el default ante duda o dato
  ausente es escalar, nunca silenciar. Ver gotcha #7.
- Una ruta **TRANSITORIA** que reintenta (8E `fail_rpc_error`) **NO se escala
  aunque churnee** — pero se vigila con umbral (+5, o +1 en los grupos con
  consulta abierta).

Un grupo terminal con `userCount>0` es S0/S1 por definición. Un transitorio,
por muy ruidoso que sea, no sube de WATCH salvo que cruce su umbral escrito.

## Correlación con el release (S2)

`firstSeen` del grupo dentro de la ventana del **release vivo** +
`transaction`/culprit que apunta a código tocado por el sha ⇒ S2. El release
vivo se lee en `05-fuentes-y-consultas.md` (`<SENTRY_RELEASE_PREFIX>@<sha8>`). Sin
correlación 1:1 con un sha, un grupo nuevo NO es "regresión" automática —
puede ser S3/S4; clasificar por superficie e impacto, no por novedad.

## Alertas de seguridad de GitHub → S0-S4

`scripts/github_seguridad.py` clasifica las alertas ABIERTAS con la misma escala; no hay una
tercera. La tabla es la **por defecto, conservadora (ante duda, la más alta)** y queda pendiente
de ratificar por el CEO antes del ensayo; se cambia en `NIVEL_POR_SEVERIDAD` del script.

| Superficie y condición | Nivel | Sello propuesto (lo sella el operador) | Issue |
|---|---|---|---|
| secret scanning, cualquier alerta abierta | S1 | `SENTRY-URGENTE-GH-SS-<n>` | `fix` / `seguridad` |
| Dependabot, code scanning o advisory `critical` | S1 | `SENTRY-URGENTE-GH-DEP-<n>` · `-GH-CS-<n>` · `-GH-ADV-<ghsa>` | `fix` / `seguridad` |
| `high` (code scanning sin nivel de seguridad: `error`) | S2 | `SENTRY-CONSULTA-<mismo sufijo>` | `fix` / `seguridad` |
| `medium` | S3 (WATCH con gatillo) | `SENTRY-CONSULTA-<mismo sufijo>` | `chore` / `none` |
| `low`, `note`, `warning` | S4 | ninguno: se cuenta, no se lista como novedad | `chore` / `none` agrupado (`<superficie>:S4`) |
| severidad ausente o fuera de la tabla | S1 | `SENTRY-URGENTE-<sufijo>` | `fix` / `seguridad` |

- Dependabot toma la severidad más alta entre la del advisory y la de la vulnerabilidad; code
  scanning usa `rule.security_severity_level` y, si es nulo, `rule.severity`; un advisory se
  considera abierto mientras su `state` no sea `closed` (`triage`, `draft` y `published` piden acción).
- **Sin familia de sellos nueva**: se reutilizan `SENTRY-URGENTE-<X>` y `SENTRY-CONSULTA-<X>` con
  `<X>` = `GH-DEP-<n>`, `GH-CS-<n>`, `GH-SS-<n>` o `GH-ADV-<ghsa>`.
- **NUEVOS**: alerta S1-S3 no vista antes. **ESCALA**: sube la severidad de una alerta ya vista
  (`S3` → `S1`) o crece el número de abiertas de la superficie. Una S4 se cuenta, no se lista.
- Una superficie declarada que el repo no tiene activada (403/404) es `SUPERFICIE-NO-VIGILADA`,
  nunca «0 alertas»; solo se vuelve válida quitándola de `GITHUB_SEC_SUPERFICIES`, y entonces se
  imprime como «no vigilada» en cada barrido.

## Qué NO hace el Vigía al clasificar

No decide el fix, no despacha al canal (eso es un campo, no una acción), no
cierra issues ni ignora grupos; resuelve solo con `resolver_ficha.py` y sus
tres pruebas verificadas en la misma corrida. Clasifica, sella y —cuando corresponde— crea la
issue despachable (ver `04-contrato-de-issue.md`).
