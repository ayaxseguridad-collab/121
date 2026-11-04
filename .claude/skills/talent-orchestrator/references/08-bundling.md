# 08 — Bundling: curar encargos (Fábrica v2)

## Table of Contents

- [Gate de despachabilidad pre-bundle](#gate-de-despachabilidad-pre-bundle)
- [Algoritmo de curado](#algoritmo-de-curado)
- [Adopción de drafts huérfanos](#adopción-de-drafts-huérfanos)
- [Prioridad de la cola del Mergeador](#prioridad-de-la-cola-del-mergeador)
- [Cross-declaration EXIGIDA en encargos cross-milestone](#cross-declaration-exigida-en-encargos-cross-milestone)
- [Colisión de recursos numerados entre canales concurrentes (incl. ADR)](#colisión-de-recursos-numerados-entre-canales-concurrentes-incl-adr)
- [Bounce-to-pool (entrada de vuelta) — Decisión 6](#bounce-to-pool-entrada-de-vuelta--decisión-6)
- [Señales de bundle mal curado (aprender del piloto)](#señales-de-bundle-mal-curado-aprender-del-piloto)
- [Deber de cierre: findings-por-origen (calidad aguas arriba)](#deber-de-cierre-findings-por-origen-calidad-aguas-arriba)
- [Rulings escalados consolidados (jurisprudencia de la fábrica)](#rulings-escalados-consolidados-jurisprudencia-de-la-fábrica)

```text
Encargo/bundle (Fábrica v2, ADR-0043) — unidad de despacho

  batch curado: [TAL-1, TAL-2, TAL-3, TAL-4, TAL-5]
        │ agrupar por afinidad + límites (cohesión, estimate≤5, mismo tier riesgo, paths disjuntos)
        ▼
  bundles: [[TAL-1,TAL-2], [TAL-3], [TAL-4,TAL-5]]
        │
        ▼
  cada sub-array = 1 rama (feat/tal-<cabeza>-<slug>) = 1 PR draft = 1 HANDOFF = N `closes TAL-x`
```

**(ADR-0043 / TAL-2193)** En Fábrica v2 la unidad de despacho deja de ser el issue suelto:
es el **encargo** — un *bundle* de 1..N issues cohesivos que viaja como **una rama = un PR
draft = un HANDOFF**. El Orquestador cura los bundles al componer el batch; el coordinador
(1ª estación) los opera con un plan-gate y un code-audit sobre el CONJUNTO
(`talent-channel-operation` regla 14); el Mergeador los funde y su merge cierra todos los
issues del encargo vía `closes TAL-N` múltiple.

Objetivo (pedido explícito del lead): **el máximo de issues que quepan en un PR** — más
issues por viaje amortizan plan-gate, code-audit, review y merge.

## Gate de despachabilidad pre-bundle

Antes de agrupar candidatas en encargos, cada candidata pasa por un **gate de calidad de issue**
usando el contrato público de `talent-issue-craft` (`audit-issue`, en main desde TAL-3088/3119). El
Orquestador NO puede despachar una candidata que no pase — va a la cola de optimización. El
(el perfil de issue-craft del repo objetivo, `docs/reference/issue-craft-perfil*.md`) ya declara
este gate en el contexto de curado de lotes; el umbral operativo viene de la sección de gate de
calidad de ESE perfil (citarlo, no hardcodearlo). Repo sin perfil ⇒ instruir crearlo desde
`talent-issue-craft/templates/perfil-de-repo.md`, nunca heredar el de otro repo.

**Snippet canónico — dos pasos con credencial distinta:**

```bash
# Paso 1: correr el auditor (token de LINEAR_API_KEY/env/.env.local; cero --config en el helper)
npx tsx .claude/skills/talent-issue-craft/scripts/issue_craft_helper.ts \
  --action audit-issue --issue TAL-N --min-score <umbral-del-perfil> 2>&1 \
  | tee /tmp/audit-TAL-N.txt; helper_rc=${PIPESTATUS[0]}

# Fail-closed en DOS RAMAS DISTINTAS — helper_rc!=0 NO es lo mismo que un gate-reject válido:
# el primero es un FALLO OPERATIVO (el auditor no llegó a emitir veredicto: red/auth/proceso
# roto), el segundo es el auditor funcionando y rechazando por score bajo/hard-failures.
# Tratarlos igual enmascara un problema de infraestructura como si fuera una issue de baja
# calidad (falso "no pasa" que en realidad es "no se pudo evaluar").
if [ "$helper_rc" -ne 0 ]; then
  echo "[ABORT gate] auditor helper no corrió (rc=$helper_rc) para TAL-N — fallo operativo, NO es un gate-reject; investigar antes de reintentar (no descartar la candidata, no hay reporte válido que publicar)" >&2
  exit 2  # señal operativa: fallo de infraestructura del gate
fi

# helper_rc=0: el auditor SÍ corrió. "eligible=true" sin "GATE-OPERATIVO-OK" = gate-reject
# VÁLIDO (score bajo o hard-failures) → aquí sí aplica descarte + reporte (command grep bypass
# del wrapper ugrep del harness; -qF: sin output, solo exit code).
if ! command grep -qF "verdict=GATE-OPERATIVO-OK" /tmp/audit-TAL-N.txt; then

  # Paso 2a: resolver TAL-N → UUID (CommentCreateInput.issueId es UUID, no el identificador)
  # Ambas llamadas vía curl --config <archivo 0600> (token en el config, jamás en -H/argv).
  # --connect-timeout/--max-time explícitos en TODAS las curl de este gate: sin ellos una
  # llamada colgada bloquea el batch entero indefinidamente (no hay otro watchdog aquí).
  ISSUE_UUID=$(curl -s --connect-timeout 5 --max-time 15 --config ~/.config/linear-token.conf \
    -H "Content-Type: application/json" \
    -d "{\"query\":\"query(\$id:String!){issue(id:\$id){id}}\",\"variables\":{\"id\":\"TAL-N\"}}" \
    https://api.linear.app/graphql | jq -r '.data.issue.id')
  # UUID inválido (incl. timeout: curl sin respuesta ⇒ jq no produce un UUID) = fallo del gate,
  # NO descarte silencioso — abortar batch con señal operativa
  if [ -z "$ISSUE_UUID" ] || [ "$ISSUE_UUID" = "null" ]; then
    echo "[ABORT gate] UUID resolution failed/timed out for TAL-N — cannot trace rejection; aborting batch" >&2
    exit 2  # señal operativa: fallo del gate, no descarte normal de candidata
  fi

  # Idempotencia: marcador determinista en el body del comentario. Si el PASO COMPLETO se
  # reintenta (el batch se relanza tras un fallo posterior, no solo el loop de 3 intentos de
  # abajo), esta comprobación evita publicar un segundo comentario de rechazo para la misma TAL-N.
  _marker="<!-- audit-gate:TAL-N -->"
  _existing=$(curl -s --connect-timeout 5 --max-time 15 --config ~/.config/linear-token.conf \
    -H "Content-Type: application/json" \
    -d "{\"query\":\"query(\$id:String!){issue(id:\$id){comments(first:50){nodes{body}}}}\",\"variables\":{\"id\":\"$ISSUE_UUID\"}}" \
    https://api.linear.app/graphql | jq -r --arg m "$_marker" '[.data.issue.comments.nodes[].body // "" | select(contains($m))] | length')
  if [ "${_existing:-0}" -gt 0 ] 2>/dev/null; then
    continue  # ya existe el comentario de rechazo para TAL-N; no duplicar, candidata ya descartada
  fi

  # Paso 2b: publicar el reporte como comentario en la issue de producto rechazada
  # (destino: la propia TAL-N que se auditó — siempre existe; NO la orden de Coordinación,
  # que aún puede no existir en el flujo pre-bundle). El body incluye el marcador de idempotencia.
  # Retry acotado (3 intentos): la candidata NO se descarta hasta confirmar trazabilidad durable.
  _gate_traced=false
  for _attempt in 1 2 3; do
    COMMENT_RESP=$(curl -s --connect-timeout 5 --max-time 15 --config ~/.config/linear-token.conf \
      -H "Content-Type: application/json" \
      -d "{\"query\":\"mutation(\$i:CommentCreateInput!){commentCreate(input:\$i){success}}\",
           \"variables\":{\"i\":{\"issueId\":\"$ISSUE_UUID\",
             \"body\":$(jq -Rs --arg m "$_marker" '. + "\n" + $m' < /tmp/audit-TAL-N.txt)}}}" \
      https://api.linear.app/graphql)
    if echo "$COMMENT_RESP" | command grep -qF '"success":true'; then
      _gate_traced=true; break
    fi
    echo "[WARN gate] commentCreate attempt $_attempt/3 failed for TAL-N/$ISSUE_UUID" >&2
    sleep 1
  done
  # Si tras 3 intentos no hay trazabilidad → abortar batch (no descarte silencioso)
  if [ "$_gate_traced" = "false" ]; then
    echo "[ABORT gate] commentCreate failed after 3 attempts for TAL-N/$ISSUE_UUID — aborting batch" >&2
    echo "$COMMENT_RESP" >&2
    exit 2  # señal operativa: fallo del gate
  fi

  continue  # trazabilidad confirmada (success:true); candidata descartada del batch
fi
# Gate pasó: la candidata entra al algoritmo de curado
```

**Decisión de gate:**

- **Pasa** (`verdict=GATE-OPERATIVO-OK` en la salida **y** `helper_rc=0`): la candidata entra al
  algoritmo de curado. `eligible=true` sin este veredicto no basta (score bajo o hard-failures).
- **Falla el auditor** (`helper_rc != 0`): el helper no llegó a emitir veredicto (fallo de
  red/auth/proceso). Esto **NO es un gate-reject** — es un fallo operativo. Abortar el batch
  (`exit 2`), NO descartar la candidata ni publicar reporte (no hay reporte válido), e investigar
  antes de reintentar. Confundir esto con un rechazo válido esconde un problema de infraestructura
  detrás de una supuesta baja calidad de la issue.
- **No pasa (gate-reject válido, `helper_rc=0` sin `GATE-OPERATIVO-OK`)**: sacar la candidata del
  batch → cola de optimización (reescritura con la plantilla del tipo de `talent-issue-craft`) o
  devolución al autor con el reporte. El reporte se adjunta como comentario en **la issue de
  producto TAL-N** (siempre existe), con marcador de idempotencia `<!-- audit-gate:TAL-N -->` para
  no duplicar en reintentos del paso completo. Si la orden de Coordinación ya existe (re-curado),
  comentar también ahí.

## Algoritmo de curado

Sobre las candidatas ya accionables/ordenadas del pipeline de selección (ref 05 — el
bundling es una capa ENCIMA, no lo sustituye):

1. **Agrupar** por afinidad: mismo subsistema/superficie probable de archivos (dominio del
   título/descripción, paths esperables), mismo tier de riesgo (sensible vs normal — lista
   canónica en `talent-merger/references/03-superficies-sensibles.md`), con/sin migración.
2. **Maximizar cada grupo** respetando TODOS los límites:
   - **Cohesión temática**: un encargo cuenta UNA historia; si el título del PR necesita
     "y además…" de otro dominio, son dos encargos.
   - **Carga combinada auditable**: si el plan-gate/code-audit no puede cubrir el conjunto
     con rigor, partir. Señal dura: **estimate combinado > 5 → partir** (coherente con la
     regla 21 del repo para issues individuales).
   - **Mismo tier de riesgo**: no mezclar sensible con normal (un issue sensible arrastra
     TODO el PR al cuidado operativo reforzado del Mergeador — spot-checks, posible GO del
     lead — y encarece el proceso del bundle entero).
   - **No mezclar migración + UI**, ni **dinero + cosmético**.
   - **Archivos DISJUNTOS entre encargos concurrentes** del batch — **dos casos distintos**
     (coherente con `references/05` §Solape): **(a) encargos frescos sin PR** → el solape se
     **estima** por paths/contratos esperables (mecanismo por defecto); **(b) encargos con
     PR/draft YA ABIERTO** → **medición real** `gh pr view <N> --json files | jq '[.files[].path]'`
     (solape ≥70% → consolidar; <70% → declarar por qué no solapan — evidencia #1111×#1187: 7/8
     archivos idénticos, un PR desperdiciado). Si dos grupos colisionan en paths, se serializan
     por `precedence` o se funden en uno (hereda la lección de los índices compartidos y los
     hot-files — `talent-merger` anexo §3).
   - **Superficies sensibles agrupadas**: juntar lo sensible del batch en el mínimo de
     encargos concentra el cuidado operativo reforzado del Mergeador en pocos PRs.
3. **Emitir** cada encargo en la orden: los issues del bundle van juntos en `issue_ids` y
   agrupados en el campo `bundles` (ref 04); un encargo = una rama única
   (`feat/tal-<cabeza>-<slug>`) + `closes` múltiple + HANDOFF único.

## Adopción de drafts huérfanos

Un **draft huérfano** es un PR draft completo (HANDOFF verificado) cuyo coordinador o canal ya no
existe o fue reciclado. En vez de descartar el trabajo, el Orquestador puede **adoptarlo** como
encargo de la cola del Mergeador:

1. **Prerequisito verificado en `origin/main` — gate DURO, no advisory**: `git fetch origin` y
   dos comprobaciones, ambas obligatorias antes de operar sobre el draft (nunca una sola):
   - **Ancestro válido**: `git merge-base --is-ancestor <draft-base> origin/main` (rc=0). Si
     falla (rc≠0) la base **diverge** de `origin/main` (historia reescrita/force-push ajeno) →
     **abortar la adopción por completo**, el draft no es confiable — no es un caso de "stale"
     normal, es un caso de rechazo.
   - **Distancia**: con ancestro válido, medir cuánto quedó atrás con
     `git rev-list --count <draft-base>..origin/main`. Umbral operativo **> 50 commits** (afinar
     por volumen real de la fábrica) → el draft está **desactualizado** y NO se adopta tal cual:
     se marca **pendiente-de-rebase** (el canal/Mergeador debe rebasear antes de que el
     Orquestador lo encole), nunca se opera directamente sobre un commit-base tan atrás del head
     actual.
2. **Si no hay draft huérfano adoptable**: buscar candidatos con
   `gh pr list --state open --draft --search "HANDOFF" --json number,title,headRefName` — el
   `--search` es solo un filtro de texto (puede dar falso positivo: título/body que menciona la
   palabra "HANDOFF" sin serlo). **Validar leyendo el HANDOFF real** con
   `bash scripts/verify-handoff.sh <pr>` (== 0) antes de considerar el PR adoptable — sin este
   paso, un candidato del `--search` puede NO ser genuinamente adoptable (HANDOFF ausente,
   incompleto o con el template roto).
3. **Adopción**: pasar el PR a la cola del Mergeador (añadirlo a la prioridad de cola, sección
   siguiente) con la traza de origen (TAL-N, coordinador original, PR#) en la orden.

Evidencia del patrón: TAL-2436 / PR#1066 (draft huérfano adoptado con éxito tras reciclar el canal
productor).

## Prioridad de la cola del Mergeador

El Orquestador también cura la PRIORIDAD con la que la 2ª estación consume drafts:

- **bugs > mes-objetivo > resto**.
- **Agrupar por hot-file**: PRs que tocan el mismo archivo caliente se procesan
  consecutivos (minimiza reconciles/rebases del Mergeador).
- La cola es del Orquestador; el Mergeador la respeta y solo altera el orden por razones
  de presupuesto CR (`talent-merger` ref 04 — p. ej. adelantar PRs con CLI-limpio si un
  fallback espera App).
- **Heads-up pre-emptivo (salida estándar de la curación)**: al curar, señalar de antemano al
  Mergeador los PRs que llegarán **destructivos** o con **colisión de slot** conocida, ANTES
  de que entren al slot de merge — así el Mergeador los marca para renumerar / parquear el GO
  del lead sin sorpresa (verificado en #834/TAL-1759). El heads-up es una salida normal de la
  curación, no una excepción.

## Cross-declaration EXIGIDA en encargos cross-milestone

Un batch puede cruzar varios milestones de un mismo proyecto (Fábrica v2). Cuando un encargo mezcla
issues de milestones distintos, o cuando una issue del encargo es cimiento de trabajo de OTRO
encargo/coordinador/flota, la orden **DEBE declarar el cruce explícitamente** (prosa + el bloque
JSON de `references/04`):

- **Qué depende de qué y por qué** (la evidencia: `blockedBy` de Linear o milestone/código — nunca
  memoria; ver `references/05` §Dependencias reales).
- **Qué queda FUERA del encargo**: el límite explícito de scope. Un encargo cross-milestone sin
  frontera declarada invita a que el canal arrastre trabajo de un milestone vecino sin gate. Escribir
  "este encargo NO toca X/Y (van en la ola N+1 / en el encargo del coord-Z)" es obligatorio.
- **Pre-flag editorial-GO**: si alguna issue del encargo produce **contenido de cara al alumno**
  (copys, anuncios, seeds editoriales, emails) que requiere revisión editorial del lead antes de
  publicar, marcarlo en la orden como **editorial-GO pendiente** — el canal entrega el draft, pero el
  Done editorial es un gate aparte del merge técnico (no lo cierra el Mergeador).

**Allowlist-a-lead — control OPERATIVO (NO gate automatizado)**: cuando un encargo toca una **superficie
sensible** cuya autorización es del lead (destructivas, credenciales, cambios de gobierno del repo — casa
con `talent-merger` §superficies sensibles), esa autorización es HOY un **control operativo**: el
Orquestador y el lead lo gestionan **fuera de banda** (heads-up pre-emptivo abajo), **NO** un gate
machine-readable que el Mergeador lea y rechace automáticamente. Coherente con CLAUDE.md regla 16
(superficies sensibles = cuidado operativo, no gate de App). La orden se emite y se despacha el trabajo
NO sensible; el paso sensible espera el GO explícito del lead, gestionado por las personas. **No se
documenta aquí un contrato de enforcement que no existe** (sería falsa seguridad: un flag que el
Mergeador de hoy no lee ni rechaza). El gate machine-readable completo (flag en la orden/HANDOFF +
rechazo fail-closed en `talent-merger` + test que pruebe el rechazo) es **follow-up TAL-2641**, diseñado
con las dos estaciones a la vez; cuando exista, el contrato se documenta aquí en el MISMO PR que lo hace
cumplir — no antes.

## Colisión de recursos numerados entre canales concurrentes (incl. ADR)

Con N canales en paralelo, cualquier recurso de **numeración secuencial global** —ADR
(`docs/decisions/NNNN`), slots de migración, constantes numeradas— puede COLISIONAR: dos canales
reservan el "siguiente número libre" a la vez y ambos crean `NNNN` (visto: doble `ADR-0056` el mismo
día). Reglas:

- **Verificar el siguiente número libre JUSTO ANTES de crear**, contra la fuente de verdad viva
  (`docs/decisions/README.md` para ADRs — cuya autoría/numeración es de `talent-docs-skill`; el ledger
  real de prod para migraciones), nunca contra la memoria del turno ni un `ls` cacheado.
- **Si colisiona en la entrega, la ruta depende del recurso**: las **migraciones** las renumera el
  **Mergeador** contra el ledger real (renumeración mecánica del slot, ya es su trabajo). Un **ADR**
  en colisión NO se resuelve reabriendo el canal productor —que ya DESAPARECIÓ tras entregar
  (Fábrica v2: el Mergeador nunca reabre diálogo)— ni lo reescribe el Mergeador (jamás re-desarrolla):
  renumerar un ADR + sus refs es cambio de contenido → se enruta por un **canal de REFACTOR auditado
  con nuevo HANDOFF**, o **bounce-to-pool** (Decisión 6) si además destapa decisión de scope.
- El Orquestador **no previene la race** (no hay lock global de numeración — misma naturaleza que la
  reserva cross-torre de `references/06`), pero SÍ **avisa** en la orden cuando un encargo va a crear
  un ADR o recurso numerado, para que el canal verifique el siguiente libre JUSTO antes de crear
  (única ventana barata: mientras el canal aún existe).

## Bounce-to-pool (entrada de vuelta) — Decisión 6

Cuando el Mergeador rebota un PR por **defecto de DISEÑO** (`talent-merger` PROC-M16), NO vuelve por
diálogo directo con el canal productor — **siempre por este pool**. Mecánica canónica (Decisión 6):

**ATÓMICO AL BUNDLE**: un encargo = un PR que cierra 1-N issues (bundle). El rebote es del PR como
UNIDAD, así que se procesa **TODO el bundle atómicamente** — los pasos 1-3 se aplican a **cada
`closes TAL-N` del PR parqueado**, no solo a "la issue que disparó el finding". Dejar issues hermanas
en curso mientras su PR está parqueado las descoordina (parecerían trabajo en vuelo sin PR y otro
coordinador podría re-pickearlas sueltas). Si el finding solo afecta a un subconjunto, la
partición/re-bundle se decide en la re-curación (abajo) — nunca dejando hermanas colgadas del PR muerto.

1. **TODAS las issues del bundle se mueven a `Backlog`** (salen del flujo activo del coordinador).
2. **A CADA una se le pone el label `bounced`** (marca inequívoca de que es re-entrada, no trabajo nuevo).
3. **Se comenta el porqué** en cada issue: el finding de diseño del Mergeador + el PR parqueado como
   contexto (link), para que la re-curación no repita el error.

**"Atómico al bundle" NO es una transacción de Linear** (Linear no ofrece mutación multi-issue
transaccional): son N mutaciones separadas. Un timeout a mitad dejaría parte en `Backlog` y parte
en `In Review` — exactamente el estado dividido que R2 impide. Por eso la mecánica es una
**secuencia REENTRANTE con reconciliación obligatoria**, no un disparo optimista:

- **(a) Inventario previo**: listar los `closes TAL-N` del PR parqueado (`gh pr view`) → el
  **conjunto esperado** completo; anotarlo en el comentario de bounce del PR como marcador de la
  operación (qué issues deben quedar `bounced` + `Backlog`).
- **(b) Mutación idempotente por issue — estado, label Y comentario, los TRES**:
  - **Label**: `bounced` se **AÑADE** al array existente (`issueUpdate` de Linear **reemplaza**
    el array — no hay "addLabel": leer los `labelIds` actuales y unir, nunca sobrescribir, o se
    pierden los `vertical/*` del issue; error común documentado en `linear-skill`).
  - **Estado**: mover a `Backlog`.
  - **Comentario con marcador idempotente POR OCURRENCIA**: el comentario de bounce lleva un
    marcador que **distingue este bounce de bounces anteriores del MISMO PR** — un PR puede
    pasar por re-fix y **volver a rebotar**, así que `PR-<n>` a secas colisiona (el chequeo
    vería el marcador viejo y omitiría el finding NUEVO, dejando contexto obsoleto). Usar
    `<!-- bounce:PR-<n>@<headRefOid-rebotado> -->` (o un `bounce_id` estable acuñado para esta
    operación) — constante SOLO durante los retries de ESTE bounce. Antes de postear, consultar
    los comentarios del issue por **GraphQL directo** (`comments(first: N) { nodes { body } }` —
    este repo NO usa MCP, no hay `list_comments`) y saltar solo si ya existe uno con **este**
    marcador. El comentario NO es un efecto secundario del label: es un tercer sub-paso con su
    propia comprobación de existencia.

  Repetir (b) entero sobre una issue ya procesada es no-op en los tres sub-pasos.
- **(c) Relectura completa del conjunto + retry ANTES de declarar el bundle re-encolado**:
  re-consultar las N issues y verificar los **TRES** invariantes por issue — `Backlog` **Y**
  label `bounced` **Y** comentario con el marcador **de ESTA ocurrencia**
  (`<!-- bounce:PR-<n>@<headRefOid-rebotado> -->`) presente. Cualquiera que falle **cualquiera**
  de los tres → re-aplicar (b) al completo. **NINGUNA issue del bundle
  es elegible para re-pick hasta que las N pasan los tres checks** — una issue `bounced` en
  `Backlog` pero SIN el comentario (fallo entre label y comment) NO cuenta como reconciliada (la
  re-curación perdería el finding/link al PR), igual que una con hermanas aún `In Review` (evita
  la partición espuria).

El Orquestador **re-pickea** las `bounced` del Backlog en su siguiente pasada de curación **solo
cuando el conjunto completo del bundle está reconciliado** (igual que cualquier candidata
accionable, pero con el finding como contexto de partición/re-bundle; posiblemente al mismo
coordinador con el PR parqueado). Un `bounced` es señal de calidad aguas
arriba: alimenta el desglose findings-por-origen de abajo.

**Decisión 8 — issue YA-satisfecha por otro PR: no fabricar makework, rebotar al pool** (Ev:
TAL-2763 tras #1000): cuando un canal arranca una issue y descubre que **otro PR ya mergeado la
satisface** (total o parcialmente) — el trabajo ya está en `main`, o su prerequisito real es otro
issue todavía abierto —, el canal **NO fabrica entregables de relleno** para justificar un PR. El
makework (un cambio cosmético, un test redundante, un refactor no pedido) contamina el bundle,
gasta review del Mergeador y esconde el estado real. Protocolo:

1. **Comentar el hallazgo en Linear** en la propia issue: qué PR ya la satisface (link) y qué
   parte, con la evidencia (el diff en `main`, no memoria).
2. **`blocked-by` al prerequisito REAL** si lo que falta depende de otro issue abierto — la
   relación de Linear refleja la dependencia verdadera, no una inventada para tener algo que hacer.
3. **Liberar el canal** de vuelta al pool (bounce-to-pool arriba): la issue vuelve a `Backlog` para
   re-curación con este contexto; el canal tira del siguiente encargo (cero ociosidad, `references/05`
   §Umbral de reciclaje).

El principio: descubrir que no hay trabajo real es un resultado VÁLIDO que se reporta y libera
capacidad — nunca una licencia para inventar entregables.

## Señales de bundle mal curado (aprender del piloto)

- El plan del encargo se aprueba pero el code-audit pide partirlo → la carga combinada no
  era auditable (bajar el umbral de ese subsistema).
- El Mergeador reporta colisiones de hot-files entre encargos del mismo batch → la
  disjunción de archivos se estimó mal (afinar el mapa path↔subsistema).
- Ratio bounce alto en bundles grandes → priorizar cohesión sobre tamaño.

## Deber de cierre: findings-por-origen (calidad aguas arriba)

Al cierre de cada piloto/batch, el Orquestador hace un **desglose de los findings CLI por
origen** (coordinador / tipo de encargo / subsistema). Si hay un **clúster sostenido** en un
eje, la respuesta es **ajustar la doctrina aguas arriba** (gate más duro en ese subsistema,
bundles más pequeños, mejor mapa path↔subsistema) en vez de escalar la estación de retrabajo
del Mergeador. Reglas de conteo:

- Un **flip-flop de CR waiveado** (finding no reproducible, `talent-merger` ref 04 §1) **NO es
  un finding real**: no cuenta como defecto del canal productor ni genera bounce ni entra en
  el clúster. Distinguir siempre "finding reproducible" de "ruido CR".
- Una ronda con **muchos NO-GO en el loop adversarial** (plan-gate/code-audit) es el loop
  **funcionando** (bugs/merges evitados), no disfunción — no se contabiliza como mala calidad
  del coordinador (ver `references/09-torre-de-control.md` §D2).
- **Barrido semanal `issue-craft-gap`**: el Orquestador barre las issues con el label
  `issue-craft-gap` (aplicado por `talent-issue-craft` cuando detecta un gap recurrente en la
  calidad de issues del repo). Propone iteración de plantillas: PR al skill genérico
  (`talent-issue-craft`) **solo si el gap es universal** (afecta a múltiples repos); PR al
  **perfil del repo objetivo** (`docs/reference/issue-craft-perfil*.md` de ESE repo) si el gap
  es específico de ese repositorio. El barrido es semanal — no por batch.

## Rulings escalados consolidados (jurisprudencia de la fábrica)

Tres rulings del lead ya resueltos que el Orquestador aplica sin re-escalar (casos nuevos que no
encajen, sí se escalan):

1. **Superseded-vs-residual** (Ev: PR #935 vs #925): cuando un PR duplica una issue YA mergeada
   (mismo `TAL-N` en main) y su rama va cientos de commits behind con borrado masivo en el
   shortstat → **NUNCA rebasar la rama brutalmente stale**: se cierra como **superseded**, y si
   queda valor residual (algo del PR que main no tiene), ese residual va como **PR fresco del
   autor sobre el main actual** — nota del Orquestador al canal/coordinador para producirlo. El
   fence operativo del Mergeador es PROC-M20 (`talent-merger`).

   **Caso extendido: rebotado-vs-abierto** — antes de re-autorizar o re-entregar un PR rebotado,
   comprobar si OTRO PR abierto toca el mismo artefacto: obtener el diff real de archivos del PR
   rebotado (`gh pr view <N> --json files`) y comparar contra los abiertos relevantes. Si el solape
   de archivos es mayoritario (≥70%) → el más completo/cercano a merge es el **canónico**; el
   rebotado se cierra como **superseded-con-traza** (nota de residual si aplica). Si NO solapan en
   archivos → el más cercano a merge avanza primero; el rebotado rebasa encima cuando ese merge
   aterrice en main. El texto existente (stale + masivo borrado) aplica sin cambio.
2. **Baseline-accept con evidencia dura + partición base-vs-head** (Ev: #899/#885, TAL-2652): ante
   un gate rojo por advisor/test, decidir por PROCEDENCIA — un test que el PR **AÑADE** no puede
   estar fallando "por la base": su fix vive DENTRO del PR (fixture from-scratch-safe); en cambio,
   un `REVOKE` a una RPC `_impl` callable-authenticated que **rompería prod** (42501 + pgTAP) es
   un falso positivo del advisor → **baseline-accept con evidencia dura** (el árbol de decisión
   REVOKE-vs-baseline vive en `talent-merger` PROC-M15/anexo §7).
3. **Fix-vs-park bajo PARO por seguridad**: con un hallazgo de seguridad durante un paro, el
   diagnóstico es **read-only por construcción** y la decisión fix-ahora-vs-park se toma por
   **tamaño del fix** (mínimo y acotado → proponer; sistémico → park) con **GO del lead** en
   ambos casos — el paro no se rompe unilateralmente.
