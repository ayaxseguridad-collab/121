# 04 — CodeRabbit: CLI y App desde la estación de merge

Posture v2 (ADR-0043): el Mergeador es el ÚNICO consumidor de ambos buckets. Los
presupuestos, el sentinel del CLI y el add-on de coste viven en el runbook canónico
`docs/runbooks/coderabbit-cli-pre-pr.md` — aquí va la mecánica operativa de la estación.

## Table of Contents

- [1. Los dos buckets y su programación](#1-los-dos-buckets-y-su-programación)
  - [Escalera de doble identidad (método canónico de autorización)](#escalera-de-doble-identidad-método-canónico-de-autorización)
- [2. CLI: corrida, trazabilidad y fallos](#2-cli-corrida-trazabilidad-y-fallos)
- [3. App: trigger por label+ready y APPROVED@head](#3-app-trigger-por-labelready-y-approvedhead)
- [4. PROC-M04 — App muda tras rebase](#4-proc-m04--app-muda-tras-rebase)
- [5. Labels por REST (verificado)](#5-labels-por-rest-verificado)
- [6. PROC-M05 — Spending cap: taxonomía](#6-proc-m05--spending-cap-taxonomía)
- [7. PROC-M07 — Rama con mayúsculas](#7-proc-m07--rama-con-mayúsculas)
- [8. PROC-M18 — Cola atascada por rate/Fair Usage](#8-proc-m18--cola-atascada-por-ratefair-usage)
- [9. PROC-M21 — App bloqueando con review stale (CLI-clean autoriza)](#9-proc-m21--app-bloqueando-con-review-stale-cli-clean-autoriza)

## 1. Los dos buckets y su programación

Cifras y mecánica de facturación: runbook canónico. Doctrina de programación de la estación:

- **CLI primero, siempre — y el CLI limpio AUTORIZA el merge** (ruling del lead
  2026-07-08, ADR-0043): **por PR**, con aprobación CLI no se gasta review del App; el App
  es fallback de ESE PR (solo si su CLI queda `deferred`).
- **Capacidad NOMINAL, no defensiva** (ruling del lead 2026-07-08): el plan Pro+ da
  **10 CLI/h + 10 App/h POR identidad**; con 2 identidades = **4 buckets ≈ 40 reviews/h**.
  El pacing degradado "~1 review/15 min" fue una adaptación al estado recalentado de UNA
  identidad — **prohibido canonizarlo como régimen**. La degradación adaptativa (percentil
  95 de Fair Usage) es **por identidad** → repartir volumen la evita por construcción.
- **Pipelining entre PRs permitido y deseable**: mientras el slot mergea el PR X, pre-correr
  el CLI de los PRs Y/Z de la cola es uso legítimo del bucket. El App tampoco se deja ocioso:
  si un PR está en fallback App (background), el CLI atiende otros PRs en paralelo. La
  invariante que NO se rompe: **UNA autoridad de review por PR a la vez** (nunca CLI+App
  sobre el MISMO PR); el paralelismo es SIEMPRE entre PRs distintos.
- **Protocolo de desempate (flip-flop) — supersede el "tope 1 re-run" de la v1.0**: el
  CR-CLI es **no-determinista** (mismo head puede dar 3 `major` en un run y 0 en el
  siguiente — verificado en #829). Ante `state = findings`, **re-correr ANTES de despachar
  refacto**: si el 2.º run sale limpio → 3.er run de desempate; **mayoría manda (≥2 de 3)**.
  Solo se despacha refacto si el finding **reaparece** (≥2/3). Un finding de un único run =
  ruido no reproducible → **waiver documentado** (head, nº de runs, superficie), NO se
  persigue ni cuenta como defecto del canal productor (findings-por-origen del Orquestador).
  **Rama de NO-convergencia** (addendum 2026-07-29, caso #1410): *N* corridas con conjuntos
  de findings **DISJUNTOS** y ningún finding que alcance ≥2/3 significan que **el gate no
  converge** — salida = **waiver documentado + merge**, NO una corrida adicional.
  **Anti-patrón: la 4ª corrida** — no desempata (produce un cuarto conjunto disjunto si el
  detector es no-determinista) y gasta bucket irrecuperable compartido por toda la fábrica. El waiver
  de no-convergencia declara: las 3 corridas citadas (run_id + findings) demostrando la
  disyunción, que ningún finding alcanzó ≥2/3, el invariante que protege código preexistente
  si aplica (p. ej. equivalencia byte-exacta), y que los defectos propios reproducibles del
  PR ya están corregidos (el waiver cubre el no-determinismo del detector, jamás un defecto
  real — espejo de la regla dura 9 del SKILL.md).
- **Findings ≠ rate-limit**: findings reproducibles del CLI van a refacto (ref 05), NUNCA al
  fallback App. La ruta B de fallback es exclusiva de `deferred`/error del CLI.

### Escalera de doble identidad (método canónico de autorización)

**Escalera CR de doble identidad v1.1** (ruling del lead 2026-07-08, TAL-2246) — el método
canónico de autorización de merge cuando el bucket de una identidad se degrada. Es una
**extensión operativa de ADR-0043** (no lo contradice): mantiene CLI-primero y App-fallback
**por PR**; la rotación reparte el volumen entre buckets independientes para que ninguna
identidad se recaliente. Identidades **por NOMBRE, jamás por valor** (las keys/tokens viven
en `.env.local`, se referencian por variable): **A = blackvamp** (arranca fría, prioridad
inicial) · **B = academia-ejemplo-root** (histórica, tiende a estar recalentada). El merge lo
ejecuta SIEMPRE la sesión `gh` vigente de la estación — la rotación es solo atribución de la
review, no del merge.

1. **Peldaño 1 — CLI identidad ACTIVA (ruta A, primaria)**: seleccionar identidad por
   rotación (sesgo a A hasta que B enfríe) → `cr-review.sh` con su key @head exacto.
   Salidas: `ok` → autorizado (merge, cero App) · `findings` (reproducibles ≥2/3) → el CLI
   funcionó: **NO se baja la escalera, NO se cambia de identidad, NO se va al App** — sale a
   refacto (ref 05) · `deferred` (rate-limit) → peldaño 2 (no consumió bucket).
2. **Peldaño 2 — App MISMA identidad (ruta B, fallback)**: label `cr-review` por REST (§5)
   → `gh pr ready` → **disparo EXPLÍCITO** `gh pr comment <pr> --body "@coderabbitai review"`
   con el `gh` de la identidad activa (el autor del comando consume SU allowance; el
   auto-trigger del flip a ready es flaky). Gate = review formal `APPROVED` **y**
   `commit_id == headRefOid` (§3).
3. **Peldaño 3 — CAMBIO DE USUARIO**: conmutar a la otra identidad y repetir desde el
   peldaño 1 (CLI-B → si `deferred` → App-B). Automático, sin permiso. Las reviews encoladas
   de la identidad anterior siguen vivas (la **1.ª autorización @head gana**); nunca dos
   reviews en paralelo sobre el MISMO PR.
4. **Peldaño 4 — PROC-M18**: los **4 buckets** sin ventana sostenida (~1 h) → escalar al
   lead con el estado de los cuatro. Único escenario que para la cola.

**Descenso por SEÑAL, no por reloj**: el App acusa recibo en ~1-2 min si está vivo
(reacción / "review in progress" / mensaje de rate-limit). **Sin acuse en ~2-3 min o
rate-limit explícito → cambio de usuario INMEDIATO** (peldaño 3); no esperar 30 min a un
bucket que ya dijo que no. Con acuse real, veredicto típico 5-15 min; a los ~15 min sin
veredicto → cambio de usuario igual. Descender temprano cuesta como mucho 1 review duplicada
(calderilla a 40/h) frente a una puerta parada.

**B10 — El CLI REFILLA en ~40-50 min (ventana rodante)** (TAL-2288, verificado en el
drenaje 2026-07-09): tras un rate-limit de CLI-A la escalera baja a App-A, pero **NO
quedarse en App-A por inercia**: re-testear CLI-A pasado ese tiempo. El test es barato y
seguro — un CLI aún rate-limited devuelve `deferred(cli-rate-limit)` **rápido y sin
gastar bucket**; si empieza a revisar, refilló → volver a la ruta A (0 consumo de App).
Aplica igual a CLI-B.

**Anti-patrones prohibidos**: (1) tratar `findings` como indisponibilidad y bajar la escalera
o ir al App; (2) canonizar el pacing degradado "1/15 min" como régimen (es señal por
identidad, no la física del plan); (3) espera pasiva con una identidad agotada (la escalera
SIEMPRE baja un peldaño); (4) cancelar una review App encolada; (5) dejar el label `cr-review`
al flipar ready en ruta A (dispara App inútil → quitar antes, §5); (6) `gh pr edit
--add-label` sin verificación REST (§5).

> **v1.2 en evaluación (aún NO canónica):** una variante que prueba **CLI-B antes que App-A**
> (usada con éxito en #839) está bajo evaluación; NO congelar esta doctrina como final hasta
> que el lead cierre la v1.2. El ADR-amendment de la posture CR de doble identidad queda como
> follow-up (issue a crear por el Orquestador); ADR-0043 permanece intacto (inmutable).

## 2. CLI: corrida, trazabilidad y fallos

```bash
bash scripts/cr-review.sh    # clon del canal del Mergeador; auth per-canal en ~/.coderabbit/auth.json
```

- **Trazabilidad del CLI-limpio** (evidencia del gate 1 del AND): el
  `.claude/.cr-review-result.json` de la corrida con `state == "ok"` y `head_sha` == head
  EXACTO del PR. Un "ok" de otro head no es evidencia (re-correr tras cada push).
- Fallos del CLI: `no-cli-auth` (re-verificar `coderabbit auth status`; la key la
  aprovisiona `talent-channels`, perfil Mergeador) · `cli-rate-limit` → ruta B (fallback) ·
  `review-incomplete`/`error` → señal práctica de throttle de esa identidad (errcount≥1 sin
  "rate limit") → tratar como `deferred`: balancear a la otra identidad, no re-martillear ·
  **`exit-124` (TIMEOUT) (p)**: `cr-review.sh` expiró (PRs >2k LOC); `exit 124` ≠ 0
  findings — re-lanzar con timeout mayor (`CR_TIMEOUT_SECONDS` ≥1200 s; piso típico 540 s);
  jamás adjudicar como limpio (ev #1108: 3.5k líneas muerto a 600 s).
- **Contrato del seat CR (h)**: el binario se verifica contra el artefacto golden + sha256
  (**NUNCA** `curl|sh` del vendor). `~/.coderabbit/auth.json` se escribe con la **receta
  canónica** (segura tanto para creación inicial como para sobreescritura — `umask 077` NO
  protege ficheros preexistentes; `printf ... > file && chmod 0600` tiene ventana de
  exposición; **NUNCA** `coderabbit auth login --api-key` — expone la key en argv/`ps`):
  ```bash
  mkdir -p -m 700 ~/.coderabbit
  TMP=$(mktemp ~/.coderabbit/.auth.XXXXXX)   # crea vacío; sin token aún
  chmod 0600 "$TMP"                           # restringir ANTES de escribir
  printf '{"token":"%s"}\n' "$KEY" > "$TMP"
  mv "$TMP" ~/.coderabbit/auth.json           # reemplaza atómicamente
  ```
  El escrow entrega la key pero el CLI no la lee del entorno. Mecánica de provisión →
  cross-ref `talent-channels` (sin duplicar aquí).
- **Mutex por HOST (h2)**: `auth.json` es único por HOME → runs concurrentes del CLI en el
  mismo host se clobbean (muerte silenciosa: log 0 B, sin sentinel de fallo). Protocolo:
  usar `flock /tmp/cr-host.lock` con la **misma receta canónica de arriba** (nunca
  redirección directa a `auth.json` dentro del flock):
  ```bash
  export KEY   # KEY debe estar exportada para que bash -c la herede
  flock /tmp/cr-host.lock bash -c '
    set -euo pipefail   # falla rápido si algo falla (mktemp, chmod, mv) o KEY no está
    mkdir -p -m 700 ~/.coderabbit
    TMP=$(mktemp ~/.coderabbit/.auth.XXXXXX)
    chmod 0600 "$TMP"
    printf '"'"'{"token":"%s"}\n'"'"' "$KEY" > "$TMP"
    mv "$TMP" ~/.coderabbit/auth.json
    bash scripts/cr-review.sh
  '
  ```
  Anunciar `# CR-RUN [host:<name>]` en el flock antes de correr; la otra estación en el
  mismo host espera el cierre (ev #1170×#1142). El crudo per-run
  `.cr-review-raw-<run_id>.jsonl` identifica la corrida aun con concurrencia (TAL-2816).
- **Findings persistidos (para leer el texto sin re-review)**: desde TAL-2245 (#830),
  `cr-review.sh` deja los findings accionables (title/line/prompt) en
  `.claude/.cr-review-findings.jsonl` → el Mergeador los lee y despacha el refacto **sin
  gastar un 2.º bucket**. Antes de #830 el JSONL crudo era un `mktemp` que se borraba (`trap
  rm EXIT`) y el result redactaba a solo severity+file → leer un finding obligaba a re-correr
  el CLI (doble consumo).
- **Ramas legacy (que predatan #830)**: usan su copia vieja del script → NO persisten el
  JSONL. Antes de correr CR sobre CUALQUIER rama, **overlay sin commitear** de la versión de
  main y limpiar después:

  ```bash
  git show origin/main:scripts/cr-review.sh > scripts/cr-review.sh
  bash scripts/cr-review.sh
  git checkout -- scripts/cr-review.sh          # deja el working tree limpio
  ```

  Barato, determinista, y los findings persisten con detalle sea cual sea la edad de la rama.

- **B8 — Findings TEXTLESS del CLI sobre código real → capturar el JSONL CRUDO primero;
  App SOLO si el raw tampoco trae texto** (TAL-2288; corregido en la ola v3). **ACTUALIZACIÓN
  TAL-2610**: el transform de `cr-review.sh` ya normaliza el texto del schema 0.6.5 — mapea
  `.codegenInstructions`/`.comment`/`.suggestions` a `title`/`description`/`prompt` y parsea
  `"around lines N - M"` a `lineStart`/`lineEnd` (filtro `scripts/lib/cr-finding-normalize.jq`),
  y **persiste el crudo per-run en `.claude/.cr-review-raw-<run_id>.jsonl`** (TAL-2816: un nombre por
  run/SHA, aislado bajo concurrencia — el `<run_id>` exacto se lee de `.cr-review-result.json`) de
  forma automática al entrar en findings. Además el gate es fail-closed por PARIDAD: un finding sin cuerpo textual real NO
  cuela como parseado (`normalized < blockers` → aborta). Por tanto el `.cr-review-findings.jsonl`
  ya trae el texto en el flujo normal y el crudo está a mano sin re-correr. La guía de abajo
  aplica para un **textless REAL** (el crudo tampoco trae texto) o ramas legacy que predatan el fix:
  el texto del finding **SÍ suele venir** en la salida cruda del CLI (`--agent` emite `suggestions`/
  `codegenInstructions` con el detalle). Ante un finding sin texto:
  **leer el crudo per-run** — derivar el `run_id` EXACTO de `.cr-review-result.json`
  (`rid=$(jq -r '.run_id' .claude/.cr-review-result.json)`; fallback: la última entrada de
  `.cr-review-history.jsonl`) y leer `.claude/.cr-review-raw-${rid}.jsonl` — NUNCA un glob
  `.cr-review-raw-*.jsonl` (ambiguo bajo concurrencia) — (o re-correr capturando el JSONL crudo si es legacy);
  **solo si el raw tampoco lo trae**, disparar UNA review del App (App-disambiguation —
  uso legítimo del bucket fuera del fallback: desambiguar, no re-aprobar). Un textless en
  CÓDIGO no es ruido descartable. Casos
  confirmados REALES y refactorizados: **#861** (fail-closed roto en el parse del ledger
  de `crosscheck-migration-slot.sh`: HTTP 200 con body inesperado → `ledger_v` vacío →
  falso GO de slot) y **#865** (`torre-relay.sh`: MSG sin guard multilínea → Enter
  prematuro en el composer). El waiver flip-flop (≥2/3) sigue aplicando solo a findings
  CON texto no reproducibles.

## 3. App: trigger por label+ready y APPROVED@head

Con `.coderabbit.yaml` en `auto_review.enabled: false` + `labels: ["cr-review"]` +
`drafts: false`, el App revisa cuando el PR está **no-draft Y etiquetado**:

1. **Label ANTES de ready** (§5) → `gh pr ready <pr>` → el App dispara UNA review.
2. Evidencia que aprueba: **el ÚLTIMO review del App con `commit.oid == head` exacto en
   estado APPROVED** — re-verificar justo antes del merge (el APPROVED puede voltearse:
   CR a veces publica un segundo review con findings minutos después).
3. Findings del App → mismo tratamiento que los del CLI: refacto (ref 05) → push →
   `auto_incremental_review: true` re-revisa el head nuevo.
4. Señales que NO aprueban (diagnóstico, jamás evidencia): checkrun SUCCESS · marcador en
   issue-comments · "Review skipped: no new commits".
5. **Re-trigger verificado post-force-push (j)**: `gh pr ready`+label **NO** disparan el App
   sobre el head nuevo tras un force-push — el trigger del flip a ready es flaky cuando el
   SHA anterior ya fue visto. Postear `@coderabbitai review` FRESCO y verificar
   **eyes-ack** (acuse ~1-2 min); sin ack en ~4 min → re-trigger (ev #1176/#1225).
6. **B9 — Patrón "APPROVED luego COMMENTED@head"** (TAL-2288, verificado 2026-07-09): tras
   la re-review de un fix, el App a veces postea un review **APPROVED** y DESPUÉS un
   **COMMENTED** (resumen) sobre el MISMO head. El gate queda satisfecho por
   **APPROVED@head + 0 findings actionable + 0 threads abiertos**; el COMMENTED final **NO
   bloquea** — no confundirlo con un rechazo ni con el flip del gotcha 4 del SKILL.md (el
   flip real es APPROVED→CHANGES_REQUESTED o un APPROVED de un head viejo).

## 4. PROC-M04 — App muda tras rebase

Tras un rebase el App deja el APPROVED anclado al head viejo y sobre el nuevo emite
señales que no son review ("No actionable comments" / "Review skipped" / solo check) — y
NO re-aprueba ni con `@coderabbitai review`. Camino verificado en producción (caso
538→541): **PR nuevo desde la misma rama**.

1. NO tocar la rama (head intacto).
2. `gh pr close <viejo>` → `gh pr create --base main --head <rama> --title "<mismo>"
   --body "<body limpio con los closes TAL-N — SIN mención al PR viejo>"` (una referencia
   "#538" hace que el App lo trate como continuación y vuelva a callar).
3. Re-pegar el comentario HANDOFF (mismo bloque, head vigente) + label por REST (§5) →
   el App lo trata como fresco y publica review real.
4. Re-correr `verify-handoff.sh <nuevo>` y los gates AND sobre el mismo head.

> **Deslinde PROC-M04 vs PROC-M21**: PROC-M04 = App **muda** (no re-aprueba) tras rebase —
> solución: PR nuevo desde la misma rama. PROC-M21 = App **bloqueando activamente** con
> `CHANGES_REQUESTED` sobre un commit desactualizado cuando el CLI-limpio ya autoriza —
> solución: dismiss trazado del review stale + resolver hilos (§9).

## 5. Labels por REST (verificado)

```bash
gh api -X POST "repos/<owner>/<repo>/issues/<N>/labels" -f "labels[]=cr-review"
gh api "repos/<owner>/<repo>/issues/<N>/labels" --jq '.[].name' | grep -qx "cr-review"
```

`gh pr edit --add-label` **FALLA SILENCIOSO** (deprecación Projects classic): rc 0 sin
label. Nunca usarlo para labels de gate.

## 6. PROC-M05 — Spending cap: taxonomía

| Mensaje del bot | ¿Revisó? | Lectura |
|---|---|---|
| "Review completed" + cap en el status | SÍ | La review existe; el status residual es ruido — no bloquea si el review real @head está |
| "Usage spending cap reached" sin review | NO | Falta la evidencia — el PR espera (o lead si urge) |

El cap se resetea por **CUOTA de facturación, no por minutos**; subirlo en el dashboard lo
libera al instante → si persiste ~1 h es una decisión de límite del **lead**, no de
espera. Evidencia pro-review-real: en el PR #761 el App cazó 2 Majors reales que un waiver
habría dejado pasar — cuando el fallback aplica (sin aprobación CLI), la review real del
App no se sustituye por impaciencia.

**CLI-phantom ≠ cap — enrutar por sensibilidad, JAMÁS saltarse el review**: el CLI-phantom (una
degradación de servicio **intermitente** que PERSISTE incluso tras rotar de cuenta) NO es un spending
cap y **no se cura re-corriendo en bucle**. Enrutado: PR **sensible** → App (su ruta obligatoria; la
clasificación de superficie NO relaja la exigencia de evidencia); PR **no-sensible** → esperar la
ventana del CLI o el fallback App. El merge exige SIEMPRE **CLI-limpio ∨ App APPROVED@head** en
cualquier superficie (reglas duras 3/4; «review skipped» / checkrun / status sin receipt **nunca**
aprueban). Un «accept-debt con red del gate» para no-sensibles sería un cambio de la **autoridad de
review** —nivel regla— **DIFERIDO a ratificación explícita del lead**, no se opera hoy. (La
recuperación de un App **mudo tras un rebase** es PROC-M04 §4 = **PR nuevo desde la misma rama**, no
un simple re-trigger.)

## 7. PROC-M07 — Rama con mayúsculas

`validar-flujo-pr` exige `^(feat|fix|refactor|docs|chore|hotfix)/[a-z0-9._-]+$`. Si un
draft llega con mayúsculas (debió atraparlo `verify-handoff.sh` en la 1ª estación):

1. Renombrar por API (GitHub retarga el PR abierto, mismo SHA, sin push):
   `gh api -X POST "repos/<o>/<r>/branches/<rama>/rename" -f new_name="<minusculas>"`
2. **NUNCA close/reopen tras el rename** (el reopen valida contra el nombre viejo y el PR
   queda CLOSED sin reapertura). Si ya quedó cerrado: PR nuevo desde la rama renombrada
   (mecánica PROC-M04).

## 8. PROC-M18 — Cola atascada por rate/Fair Usage

**PROC-M18 es el peldaño 4 de la escalera** (§1): solo se llega aquí con los **4 buckets**
(CLI-A, App-A, CLI-B, App-B) sin ventana sostenida. Antes hay que haber agotado el cambio de
usuario (peldaño 3). **Síntoma**: varios PRs esperando evidencia con las dos identidades
degradadas.

1. **No parar la estación**: el slot de merge sigue con PRs de ruta A ya evidenciados;
   la preparación (intake/rebase/slots/refacto) no consume buckets.
2. Re-triggers del App cadenciados (~10 min, UN canal por identidad) — nunca ráfagas
   paralelas sobre el mismo bucket.
3. Priorizar el bucket disponible para los PRs de mayor prioridad de cola (bugs primero).
4. Los 4 buckets sin ventana sostenida (~1 h) con cola creciendo → **lead** (decisión de
   límite/add-on, no de espera) + registrar el episodio (métrica del piloto: reviews
   consumidas/PR).

## 9. PROC-M21 — App bloqueando con review stale (CLI-clean autoriza)

**Síntoma**: el CLI corrió limpio sobre el head actual, pero el PR no puede mergear porque
el App publicó `CHANGES_REQUESTED` sobre un commit anterior (anterior al rebase) y no lo
actualizó. El CLI-limpio autoriza el merge (ruling ADR-0043) — la traba es el review stale.
Deslinde con PROC-M04: M04 = App muda (no re-aprueba); M21 = App bloqueando activamente.

1. Localizar el review que bloquea (filtrar por `commit_id` distinto del head actual: el
   `state=="CHANGES_REQUESTED"` solo no basta — un review vigente sobre el head actual
   también matchea y NO es stale):
   ```bash
   HEAD_SHA=$(gh api "repos/{o}/{r}/pulls/<pr>" --jq .head.sha)
   gh api "repos/{o}/{r}/pulls/<pr>/reviews" | jq --arg head "$HEAD_SHA" \
     '.[] | select(.state=="CHANGES_REQUESTED" and .commit_id != $head) | {id,commit_id,user:.user.login}'
   ```
   (`gh api --jq`/`-q` acepta un único string de filtro, no flags de jq como `--arg` — por
   eso se separa la llamada: `gh api` sin `--jq` para obtener el JSON crudo, pipeado a `jq`
   real con `--arg`.)
2. Dismiss trazado del review stale (el `commit_id` del review debe ser distinto del head
   actual — verificado en el paso 1). `message` es requerido por la API; `event` es
   **opcional** (único valor válido `DISMISS` si se manda) — incluirlo igual deja explícita
   la intención de la llamada, no porque su omisión rompa el endpoint:
   ```bash
   gh api -X PUT "repos/{o}/{r}/pulls/<pr>/reviews/<review_id>/dismissals" \
     -f message="Review sobre commit desactualizado; CLI limpio @head actual autoriza" \
     -f event=DISMISS
   ```
3. Resolver **solo** los hilos desactualizados del review stale (el dismiss **no** cierra
   los threads; NO resolver hilos activos del head actual). Paginar `reviewThreads`: un PR
   con más de 50 threads pierde el resto en silencio si se lee una sola página:
   ```bash
   # Obtener únicamente threads obsoletos (isOutdated=true: commit stale) y no resueltos,
   # paginando con pageInfo hasta agotar páginas (isOutdated es el campo nativo de GitHub:
   # true cuando el commit del hilo quedó desactualizado por el rebase — exactamente los
   # hilos del review dismisseado. No se tocan hilos con isOutdated=false).
   CURSOR=null
   while :; do
     RESP=$(gh api graphql -f query='
       query($cursor: String) { repository(owner:"{o}",name:"{r}") {
         pullRequest(number: <pr>) { reviewThreads(first: 50, after: $cursor) {
           pageInfo { hasNextPage endCursor }
           nodes { id isResolved isOutdated } } } } }' \
       -F cursor="$CURSOR")
     printf '%s' "$RESP" | jq '.data.repository.pullRequest.reviewThreads.nodes
           | map(select(.isResolved==false and .isOutdated==true)) | .[].id'
     HAS_NEXT=$(echo "$RESP" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')
     [ "$HAS_NEXT" = "true" ] || break
     CURSOR=$(echo "$RESP" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
   done
   # Resolver cada hilo seleccionado (repetir por threadId de la lista anterior)
   gh api graphql -f query='mutation {
     resolveReviewThread(input: {threadId: "<threadId>"}) { thread { isResolved } } }'
   ```
4. Push ATÓMICO si hay cambios pendientes (regla dura 15, 2026-07-28 — `scripts/check-push-audit.sh`
   DENIEGA opciones globales entre `git` y el verbo: `-C`, `--git-dir`, `--work-tree`, `-c`, y
   wrappers como `sudo`/`env`/`command` antes de `git` (incluida la forma
   `VAR=val git push`: el guard exige que el primer token sea literalmente `git`), clase
   sentinel-bypass, TAL-2288; el comando `git push` debe ser standalone puro y el ban de
   compuestos incluye TAMBIÉN el newline (`check-push-audit.sh` líneas 78-91) — así que
   `cd repo && git push`, `cd repo\ngit push` **y también** `cd repo` (llamada 1) →
   `pwd`/verificación (llamada 2) → `git push` (llamada 3) violan la MISMA propiedad: el hook
   valida el sentinel contra el HEAD leído **en el momento en que se ejecuta esa llamada
   concreta** (`check-push-audit.sh` líneas 28+110, `git rev-parse HEAD` sin `-C`, sobre SU
   PROPIO cwd de invocación) — eso ata el hook y el push REAL dentro de la MISMA llamada, pero
   **NO ata dos llamadas SEPARADAS entre sí**: una verificación "inmediatamente antes" en su
   propia invocación TODAVÍA no es atómica con el push que la sigue — el cwd puede
   resetearse en el hueco entre AMBAS llamadas exactamente igual que entre un `cd` lejano y el
   push (ver ref 07 §5). **Una comprobación previa separada NO basta, aunque sea la llamada
   inmediatamente anterior.**
   **Un campo `cwd`/`workdir` estructurado del tool call NO cierra por sí solo la ventana**
   (corrección 2026-07-31, ronda 3 de auditoría): fijar ahí la ruta absoluta y dejar
   `command` como `git push [refspec]` puro solo es seguro SI, ADEMÁS, el propio hook se
   ejecuta bajo ESE MISMO workdir resuelto — y eso NO está garantizado por defecto.
   `check-push-audit.sh` **no lee ningún campo `cwd`/`workdir`** de `tool_input` (solo
   `.tool_input.command`, línea ~32) y resuelve `git rev-parse HEAD`/`git branch
   --show-current` (líneas ~108-110) contra **su PROPIO cwd de invocación** — que es una
   propiedad del harness que invoca el hook, no del comando que gatea. **Evidencia contra
   la propia hipótesis** (`.claude/settings.json`): el hook de este repo se registra por
   **ruta RELATIVA** (`bash scripts/check-push-audit.sh`), lo que **NO DEMUESTRA** que su
   cwd de ejecución esté atado dinámicamente al workdir que un campo estructurado pudiera
   fijar para el comando gateado — exactamente el escenario de riesgo: el hook podría
   autorizar contra el repo A (su cwd fijo) mientras el push corre en el repo B (el workdir
   del campo estructurado), un sentinel-bypass por confusión de destino.
   **Precondición de verificación OBLIGATORIA antes de confiar en un campo `cwd`/`workdir`**:
   demostrar, con una prueba controlada en el harness concreto (workdir del campo apuntando
   a un repo DISTINTO del cwd ambiente del proceso que invoca hooks), que el hook valida
   sentinel/HEAD/branch contra ESE MISMO workdir resuelto — nunca asumirlo del texto de esta
   doctrina ni de la mera existencia del campo.
   **Sin esa prueba superada (y hoy, en este repo, la evidencia de arriba apunta a que NO se
   cumple): no existe una forma de un solo acto que sea a la vez segura y compatible con
   este guard.** Envolver `cd`+push en un script/wrapper (`bash push.sh`) evade la detección
   del hook por completo (el string invocado ni contiene `git`/`push` literal) y es
   EXACTAMENTE la clase sentinel-bypass que el guard existe para cerrar — PROHIBIDO como
   "solución". La corrección estructural real exige que **el guard mismo** lea el campo
   `cwd`/`workdir` (si el harness lo aporta) y resuelva sentinel/HEAD/branch ahí, en vez de
   depender de su propio cwd de invocación — cambio de `scripts/check-push-audit.sh`, **fuera
   de alcance de este doc-vivo** (que no toca `scripts/*.sh`): se declara como deuda/follow-up
   explícito. Hasta que exista esa verificación o ese fix, la estación trata TODO push
   automatizado sobre un repo no confirmado por el propio proceso del hook como **inseguro**
   y escala en vez de asumir que cd-luego-push, verificación-inmediata o un campo
   `cwd`/`workdir` sin prueba resuelven el problema. Los CUERPOS DE TEXTO que citen el verbo
   de push se mandan SIEMPRE por fichero, nunca inline en el comando: el guard matchea la
   cadena en TODO el comando, incluidos los payloads — redactar esta misma corrección con un
   heredoc de shell disparó el bloqueo en vivo (2026-07-28). → si el head cambia, re-gatear
   (ref 08 m1) (ev #1059).
