#!/usr/bin/env bash
# merge-gate.sh — [B5] Gate de merge VERIFICABLE por gh API, atado al headSha auditado.
# "Sin bloqueantes" = AND de 3 señales (no se usa reviewDecision). Re-evalúa tras rebase [M2].
# Uso:  merge-gate.sh <pr_number> <audited_sha>   (sale 0 = PASS, 1 = FAIL; imprime motivo)
# NOTA: set -euo pipefail va dentro del guard de ejecución (abajo) para no contaminar el shell al source-ear (tests).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"
# shellcheck source=/dev/null
. "$HERE/verify-code-audit-go.sh"

# --- Decisor PURO (testeable; sin red) -------------------------------------
# args: rollup_bad blocking_findings unresolved_threads sha_ok(yes|no) human_ok(yes|no) reviews_present(yes|no) mergestate(CLEAN|...)
# Merge SIEMPRE humano: el gate verde NO mergea; exige OK humano trazable (approve-merge.sh). No existe modo auto.
tco_merge_decide() {
  # [CR] reviews defaultea a `no` (fail-closed, coherente con mergestate UNKNOWN): un caller
  # futuro que omita el 6º argumento NO debe poder aprobar el merge sin la review real de CR (M8).
  local rollup="$1" blockers="$2" threads="$3" shaok="$4" humanok="$5" reviews="${6:-no}" mergestate="${7:-UNKNOWN}"
  [ "$shaok" = yes ]                       || { echo "FAIL: headSha != SHA auditado (re-auditar)"; return 1; }
  # [Cond. 3] allowlist ESTRICTA: solo CLEAN sobre el headSha auditado permite merge. Cualquier otro
  # estado (BLOCKED/BEHIND/DIRTY/UNSTABLE/UNKNOWN/DRAFT/HAS_HOOKS) es fail/wait, sin interpretación.
  [ "$mergestate" = CLEAN ]                || { echo "FAIL: mergeStateStatus=$mergestate (solo CLEAN permite merge)"; return 1; }
  [ "$reviews" = yes ]                      || { echo "FAIL: revisión REAL de CodeRabbit ausente sobre el headSha (Review skipped / sin label cr-review / sin marcador de review ejecutada) [M8]"; return 1; }
  [ "${rollup:-1}" -eq 0 ] 2>/dev/null     || { echo "FAIL: checks no todos verdes ($rollup pending/failure/action_required)"; return 1; }
  # Política solo-bloqueantes: gatea por findings de SEVERIDAD bloqueante sin resolver (blockers).
  # 'threads' (todos los hilos de bots abiertos, incl. nitpicks/minor/P2/P3) es SOLO telemetría — no bloquea.
  [ "${blockers:-1}" -eq 0 ] 2>/dev/null   || { echo "FAIL: $blockers finding(s) bloqueante(s) de bots sin resolver"; return 1; }
  [ "$humanok" = yes ]                      || { echo "FAIL: falta OK humano explícito del lead (approve-merge.sh trazable por PR+SHA)"; return 1; }
  echo PASS; return 0
}

# --- Clasificadores PUROS (testeables con fixtures; sin red) ----------------
# [Cond. 4] Cuenta checks "malos" del rollup (stdin = JSON statusCheckRollup). El StatusContext
# (commit status legacy) null/PENDING/EXPECTED de CodeRabbit es benigno SOLO si EXISTE un CheckRun
# de CodeRabbit con conclusion=SUCCESS en ESTE rollup (mismo headSha): correlación por __typename +
# name + conclusión explícita; NUNCA "algún check pasó". Un StatusContext CR en FAILURE/ERROR bloquea.
# Imprime un entero. Fail-closed: vacío -> 1.
# [v5/B1] Compositor PURO de M8 (testeable sin red): SOLO DOS VÍAS producen yes — (a) review REAL
# de CR sobre el headSha (review_check+review_real), o (b) waiver explícito del lead atado a
# PR+headSha (waive-cr.sh). Las señales débiles (checkrun/comments/skip) NO SON NI SIQUIERA INPUTS
# de este compositor: por construcción no pueden aprobar. El label cr-review se exige en ambas vías.
# Imprime "yes review-real@head" | "yes waiver" | "no -". rc 0 = aprueba.
tco_m8_compose() { # cr_label review_check review_real waiver_present(yes|no)
  local label="${1:-no}" check="${2:-no}" real="${3:-no}" waiver="${4:-no}"
  if [ "$label" = yes ]; then
    if [ "$check" = yes ] && [ "$real" = yes ]; then echo "yes review-real@head"; return 0; fi
    if [ "$waiver" = yes ]; then echo "yes waiver"; return 0; fi
  fi
  echo "no -"; return 1
}

# [issue 9011] Compositor de M8 con TERCERA vía, SOLO con revisor=code-audit (⚠ NO recomendable: sin capa externa de revisión).
# Con cualquier otro revisor (coderabbit, vacío, ajeno) es EXACTAMENTE tco_m8_compose: el GO de code-audit ni se mira.
# Orden: review real de CR > GO de code-audit verificado (tco_code_audit_go_verify) > waiver. El waiver sigue siendo una
# excepción trazada: jamás se nombra como code-audit, y el GO no exige la etiqueta cr-review (no hay App).
# Imprime "yes review-real@head" | "yes code-audit" | "yes waiver" | "no -". rc 0 = aprueba.
tco_m8_compose_rev() { # revisor cr_label review_check review_real waiver_present(yes|no) code_audit_ok(yes|no)
  local revisor="${1:-coderabbit}" label="${2:-no}" check="${3:-no}" real="${4:-no}" waiver="${5:-no}" audit="${6:-no}" out
  if out="$(tco_m8_compose "$label" "$check" "$real" no)"; then echo "$out"; return 0; fi
  if [ "$revisor" = code-audit ] && [ "$audit" = yes ]; then echo "yes code-audit"; return 0; fi
  if out="$(tco_m8_compose "$label" "$check" "$real" "$waiver")"; then echo "$out"; return 0; fi
  echo "no -"; return 1
}

# [v5/B1 — DIAGNÓSTICO, no aprobatorio] Nº de CheckRun de CodeRabbit con conclusion=SUCCESS en el
# rollup del head. La identidad de la GitHub App NO es verificable de forma fiable desde el rollup
# (un job de Actions llamado "coderabbit" sería forjable — se excluye por detailsUrl de Actions,
# pero eso no es prueba de identidad): esta señal SOLO informa el diagnóstico M8=WAIVER_REQUIRED;
# JAMÁS produce reviews=yes. Fail-closed: vacío/null → 0.
tco_cr_checkrun_ok() { # stdin = statusCheckRollup JSON -> imprime entero
  local j; j="$(cat)"; { [ -n "$j" ] && [ "$j" != "null" ]; } || { echo 0; return; }
  printf '%s' "$j" | jq '[.[]?|select((.__typename//"")=="CheckRun")
    |select(((.name//"")|ascii_downcase)|test("coderabbit"))
    |select((.conclusion//"")=="SUCCESS")
    |select(((.detailsUrl//"")|test("github\\.com/.+/(actions|runs)/"))|not)]|length' 2>/dev/null || echo 0
}

tco_rollup_bad() {
  local j crok; j="$(cat)"; { [ -n "$j" ] && [ "$j" != "null" ]; } || { echo 1; return; }   # [CR] 'null' (rollup ausente) = fail-closed
  # [CR #790 Major] REUTILIZA tco_cr_checkrun_ok (con su exclusión detailsUrl de Actions): sin ese
  # anti-spoof, un job de GitHub Actions FORJADO llamado "coderabbit" con conclusion=SUCCESS inflaría
  # crok y enmascararía el StatusContext coderabbit PENDING/EXPECTED real (línea de abajo, $crok>0),
  # dejando pasar un review realmente pendiente. Mismo cómputo que el diagnóstico, misma identidad.
  crok="$(printf '%s' "$j" | tco_cr_checkrun_ok)" || true
  # [v5 — dogfood #547] DEDUPE de CheckRuns por nombre quedándose con el run MÁS RECIENTE
  # (startedAt): un re-trigger del workflow deja el run viejo CANCELLED en el rollup para
  # siempre, `gh pr checks` muestra solo el vigente, y contar el obsoleto daba FAIL con el CI
  # realmente verde (falso negativo heredado de v4). Los StatusContext no se tocan (GitHub ya
  # entrega solo el último estado por context).
  # [NO-GO lead] FAIL-CLOSED del dedupe: un run NO COMPLETADO (sin conclusion — QUEUED/PENDING,
  # que además puede venir SIN startedAt) BLOQUEA aunque comparta nombre con un run viejo verde
  # — el grupo resuelve al run pendiente, nunca al verde obsoleto. Y sin startedAt, el run se
  # ordena como el MÁS NUEVO ("9999"), no como el más viejo ("").
  printf '%s' "$j" | jq --argjson crok "${crok:-0}" '
    ( ([ .[]? | select((.__typename//"")=="CheckRun") ] | group_by(.name//"")
       | map( if any(.[]; (.conclusion//"")=="")
              then ([ .[] | select((.conclusion//"")=="") ] | last)
              else (sort_by(.startedAt//"9999") | last) end ))
      + [ .[]? | select((.__typename//"")!="CheckRun") ] )
    | [ .[]
      | { tn:(.__typename//""), nm:((.name//.context//"")|ascii_downcase), c:(.conclusion // .state // "PENDING") }
      | select(.c != "SUCCESS" and .c != "NEUTRAL" and .c != "SKIPPED")
      | select( ( $crok>0 and .tn=="StatusContext" and (.nm|test("coderabbit")) and (.c=="PENDING" or .c=="EXPECTED") ) | not )
    ] | length' 2>/dev/null || echo 1
}

# [B4] ¿revisión obligatoria PRESENTE en el rollup? CodeRabbit es el único reviewer (ADR-0043).
# stdin = JSON statusCheckRollup. Imprime yes|no. Fail-closed: vacío -> no.
tco_reviews_present() {
  local j has_cr; j="$(cat)"; { [ -n "$j" ] && [ "$j" != "null" ]; } || { echo no; return; }   # [CR] 'null' = fail-closed
  has_cr="$(printf '%s' "$j" | jq '[.[]?|(.name//.context//"")|ascii_downcase|select(test("coderabbit"))]|length' 2>/dev/null || echo 0)"
  [ "${has_cr:-0}" -gt 0 ] 2>/dev/null && echo yes || echo no
}

# [v5/C17 — puro] Estado del ÚLTIMO review con veredicto (APPROVED|CHANGES_REQUESTED) de CR
# sobre el headSha. Vacío = sin review con estado (solo COMMENTED/skip). Fail-closed: vacío.
# [CR #547 Major] Robusto a MULTI-PÁGINA: `gh api --paginate --jq` emite UN array POR PÁGINA
# (arrays concatenados) — `-s` los slurpea y `add` los aplana; sin esto, un CHANGES_REQUESTED
# en la página 2 se perdía (caía al fallback de markers) en PRs con muchas reviews.
tco_cr_last_state() { # headSha (stdin = reviews JSON, 1..N arrays) -> APPROVED|CHANGES_REQUESTED|""
  local sha="$1" j; j="$(cat)"; { [ -n "$j" ] && [ -n "$sha" ]; } || return 0
  printf '%s' "$j" | jq -rs --arg sha "$sha" 'add // [] | [.[]?|select(((.login//.user.login)//"")|ascii_downcase|(.=="coderabbitai[bot]" or .=="coderabbitai"))|select(((.commit_id//.commit)//"")==$sha)|(.state//"")|select(.=="APPROVED" or .=="CHANGES_REQUESTED")]|last // ""' 2>/dev/null
}

# [M8 + bug3] ¿CodeRabbit ejecutó una review REAL (no 'Review skipped') SOBRE el headSha auditado? Sin la
# etiqueta cr-review, CR responde "Review skipped — Auto reviews are limited by label configuration" con
# status VERDE pero SIN review; tco_reviews_present (presencia del check) lo daba por bueno. Aquí exigimos
# un marcador de review ejecutada ("Actionable comments posted: N" / "No actionable comments" /
# walkthrough/summary) en una review de CR cuyo commit_id == headSha (no una histórica). Fail-closed.
tco_cr_review_real() { # headSha   (stdin = JSON array de REVIEWS [{login,commit_id,state,body},...])
  # [bug3] Solo cuentan reviews de CR cuyo commit_id == headSha auditado: una review HISTÓRICA de un commit
  # anterior NO vale (el head actual debe estar revisado por CR App, no uno viejo). Usar el REST de reviews
  # (.../pulls/N/reviews), que trae commit_id; los comentarios sueltos del PR no atan al sha.
  local sha="$1" j bodies laststate
  j="$(cat)"; [ -n "$j" ] && [ -n "$sha" ] || { echo no; return; }
  # [v5 — dogfood PR #547 + C17] El STATE explícito del ÚLTIMO review de CR sobre ESTE sha manda,
  # y GANA sobre los markers del body:
  #   APPROVED           → review real aprobatoria (aunque el body venga VACÍO — caso re-review).
  #   CHANGES_REQUESTED  → NO cuenta como aprobatoria [C17]: la última palabra de CR pidió
  #                        cambios; resolver hilos a mano no la convierte en aprobación. El
  #                        camino es re-review hasta APPROVED o waiver del lead (waive-cr.sh).
  # Los markers del body quedan como fallback SOLO para reviews COMMENTED (walkthrough);
  # "Review skipped" sigue sin contar.
  laststate="$(printf '%s' "$j" | tco_cr_last_state "$sha")" || true
  case "$laststate" in
    APPROVED)          echo yes; return;;
    CHANGES_REQUESTED) echo no;  return;;
  esac
  # [seguridad] login EXACTO del bot (no substring "coderabbit" — un "not-coderabbit" pasaría).
  # [CR #547 Major] -s + add: tolera los arrays-por-página del --paginate (ver tco_cr_last_state)
  bodies="$(printf '%s' "$j" | jq -rs --arg sha "$sha" 'add // [] | [.[]?|select(((.login//.user.login)//"")|ascii_downcase|(.=="coderabbitai[bot]" or .=="coderabbitai"))|select(((.commit_id//.commit)//"")==$sha)|(.body//"")]|join("\n")' 2>/dev/null || echo '')"
  [ -n "$bodies" ] || { echo no; return; }   # sin review de CR sobre ESTE headSha → no
  # [CR] una review REAL sobre el head GANA aunque exista un "skip" HISTÓRICO en el MISMO SHA: comprobar
  # primero los marcadores de review ejecutada; solo si NO hay ninguno y sí hay un skip → no presente.
  printf '%s' "$bodies" | grep -qiE 'actionable comments posted|no actionable comments|walkthrough|summary by coderabbit' && { echo yes; return; }
  printf '%s' "$bodies" | grep -qiE 'review skipped' && { echo no; return; }   # solo skip, sin review real → no (fail-closed)
  echo no
}

# [v5/B1 — DIAGNÓSTICO] ancla temporal del último push: el startedAt más TEMPRANO de los CheckRuns
# del rollup del head (el CI arranca justo tras el push y el dev NO lo controla; el committer-date
# sí es forjable con backdate). Vacío = señal (b) inutilizable (fail-closed en el consumidor).
tco_rollup_first_started() { # stdin = rollup JSON -> ISO8601 | vacío
  local j; j="$(cat)"; { [ -n "$j" ] && [ "$j" != "null" ]; } || return 0
  printf '%s' "$j" | jq -r '[.[]?|select((.__typename//"")=="CheckRun")|(.startedAt//empty)]|sort|first // empty' 2>/dev/null
}

# [v5/B1 — DIAGNÓSTICO] ¿hay marcador de review de CR en ISSUE-COMMENTS posteriores al push?
# (tras rebase CR a veces responde "No actionable comments" como comment, no como review-object).
# Login EXACTO del bot (anti-spoof) + created > ts (ISO8601 lexicográfico, ambos de la API).
# NUNCA produce reviews=yes: alimenta el diagnóstico. Fail-closed: sin ts/JSON → no.
tco_cr_comment_marker() { # min_iso_ts  (stdin = [{login,created,body}], 1..N arrays) -> yes|no
  local ts="$1" j; j="$(cat)"
  { [ -n "$ts" ] && [ -n "$j" ] && [ "$j" != "null" ]; } || { echo no; return; }
  printf '%s' "$j" | jq -rs --arg ts "$ts" 'add // [] |
    [ .[]? | select(((.login//"")|ascii_downcase)|(.=="coderabbitai[bot]" or .=="coderabbitai"))
           | select((.created//"") > $ts)
           | select((.body//"")|test("actionable comments posted|no actionable comments|walkthrough|summary by coderabbit";"i")) ]
    | if length>0 then "yes" else "no" end' 2>/dev/null || echo no
}

# [v5/B1 — DIAGNÓSTICO] ¿CR emitió "Review skipped: no new commits to review" SOBRE el headSha?
# Ocurre tras un rebase mecánico (CR considera ya revisado el contenido). NUNCA aprueba por sí
# solo: informa el diagnóstico WAIVER_REQUIRED (el camino soportado es PR nuevo o waiver del lead).
tco_cr_skip_nonew() { # headSha (stdin = reviews JSON, 1..N arrays) -> yes|no
  local sha="$1" j; j="$(cat)"; { [ -n "$j" ] && [ -n "$sha" ]; } || { echo no; return; }
  printf '%s' "$j" | jq -rs --arg sha "$sha" 'add // [] |
    [ .[]? | select(((.login//.user.login)//"")|ascii_downcase|(.=="coderabbitai[bot]" or .=="coderabbitai"))
           | select(((.commit_id//.commit)//"")==$sha)
           | select((.body//"")|test("review skipped";"i"))
           | select((.body//"")|test("no new commits";"i")) ]
    | if length>0 then "yes" else "no" end' 2>/dev/null || echo no
}

# ---------------------------------------------------------------------------
# [v5/B9] tco_deliverable_unchanged <audited_sha> <head_sha> — ¿el ENTREGABLE del PR es
# byte-idéntico entre el sha auditado y el head actual (rebase MECÁNICO)?
# entregable(sha) := diff(merge-base(origin/main, sha), sha) — la contribución NETA del PR,
# invariante al rebase. SIN parámetro de paths (condición del lead): el conjunto de archivos se
# deriva SIEMPRE del diff completo — imposible omitir un archivo cambiado. Única exclusión:
# TCO_SHAOK_EXEMPT_PATHS (índices compartidos), cuyo diff se REPORTA en la traza (diffstat visible
# al lead), nunca se oculta. Fail-closed deliberado: PR que SOLO toca el índice → NO-EQUIV (se
# re-audita; sin fast-path); set de archivos distinto → NO-EQUIV con lista; sha inalcanzable →
# NO-EQUIV. Alimenta shaok (con traza SHAOK-EQUIV); NO alimenta M8. Kill-switch: TCO_SHAOK_EQUIV=no.
# ---------------------------------------------------------------------------
tco_deliverable_unchanged() { # audited_sha head_sha -> 0 idéntico (traza SHAOK-EQUIV) | 1 no (motivo)
  local a="$1" h="$2" root="${TCO_HOST_REPO_ROOT:-}" mb1 mb2 f1 f2 s ex
  local -a exempt=() files=()
  printf '%s' "$a" | grep -qE '^[0-9a-f]{40}$' || { echo "NO-EQUIV: audited_sha inválido"; return 1; }
  printf '%s' "$h" | grep -qE '^[0-9a-f]{40}$' || { echo "NO-EQUIV: head_sha inválido"; return 1; }
  [ -n "$root" ] || root="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$root" ] || { echo "NO-EQUIV: sin repo git del host (define TCO_HOST_REPO_ROOT)"; return 1; }
  git -C "$root" fetch origin main --quiet 2>/dev/null || { echo "NO-EQUIV: fetch origin main falló"; return 1; }
  # el sha pre-rebase puede no estar local: fetch por sha (GitHub lo sirve un tiempo tras el rebase)
  for s in "$a" "$h"; do
    git -C "$root" cat-file -e "$s^{commit}" 2>/dev/null || git -C "$root" fetch origin "$s" --quiet 2>/dev/null || true
    git -C "$root" cat-file -e "$s^{commit}" 2>/dev/null || { echo "NO-EQUIV: sha inalcanzable: $s (re-auditar)"; return 1; }
  done
  for ex in ${TCO_SHAOK_EXEMPT_PATHS:-}; do exempt+=(":(exclude)$ex"); done
  mb1="$(git -C "$root" merge-base origin/main "$a" 2>/dev/null)" || { echo "NO-EQUIV: sin merge-base ($a)"; return 1; }
  mb2="$(git -C "$root" merge-base origin/main "$h" 2>/dev/null)" || { echo "NO-EQUIV: sin merge-base ($h)"; return 1; }
  # [CR #790 Major] expansión set-u-safe: con TCO_SHAOK_EXEMPT_PATHS vacío (default en TA) el array
  # exempt queda vacío y "${exempt[@]}" lanza "unbound variable" bajo set -u en Bash 3.2/4.3.
  # ${arr[@]+"${arr[@]}"} expande a nada si el array está vacío/unset — seguro en todo bash.
  f1="$(git -C "$root" diff --name-only "$mb1" "$a" -- . ${exempt[@]+"${exempt[@]}"} | LC_ALL=C sort)"
  f2="$(git -C "$root" diff --name-only "$mb2" "$h" -- . ${exempt[@]+"${exempt[@]}"} | LC_ALL=C sort)"
  [ -n "$f2" ] || { echo "NO-EQUIV: head sin entregable propio fuera de los paths exentos (re-auditar sobre el head)"; return 1; }
  if [ "$f1" != "$f2" ]; then
    echo "NO-EQUIV: el CONJUNTO de archivos del entregable cambió entre shas (re-auditar):"
    printf '%s\n%s\n' "$f1" "$f2" | LC_ALL=C sort | uniq -u | sed 's/^/  /'
    return 1
  fi
  # [CR #547] while-read en vez de mapfile (Bash 3.2 compat — macOS /bin/bash)
  while IFS= read -r _f; do [ -n "$_f" ] && files+=("$_f"); done <<< "$f2"
  git -C "$root" diff --quiet "$a" "$h" -- ${files[@]+"${files[@]}"} \
    || { echo "NO-EQUIV: contenido del entregable DIFIERE entre $a y $h (rebase con cambios reales — re-auditar)"; return 1; }
  echo "SHAOK-EQUIV: entregable byte-idéntico audited=$a head=$h (${#files[@]} archivo(s))"
  if [ -n "${TCO_SHAOK_EXEMPT_PATHS:-}" ]; then
    echo "SHAOK-EQUIV: paths exentos ($TCO_SHAOK_EXEMPT_PATHS) — diff entre shas (visible al lead):"
    # shellcheck disable=SC2086
    git -C "$root" diff --stat "$a" "$h" -- ${TCO_SHAOK_EXEMPT_PATHS} 2>/dev/null | sed 's/^/  /'
  fi
  return 0
}

# (b)+(c) Cuenta threads de CodeRabbit SIN resolver y el subconjunto BLOQUEANTE por severidad.
# stdin = páginas GraphQL concatenadas (--paginate). Imprime "threads blockers". Fail-closed: "1 1".
# POSTURA DELIBERADA (no relajar): la regex incluye '⚠️'/'Potential issue' ADEMÁS de las
# severidades explícitas. Es fail-closed a propósito (calibrado en el repo origen): un minor
# contado como blocker solo fuerza una mirada humana; el error inverso (un blocker real sin
# badge de severidad que pasa de largo) es el que rompe producción. No estrechar sin decisión
# del lead.
tco_threads_blockers() {
  local j t b; j="$(cat)"; { [ -n "$j" ] && [ "$j" != "null" ]; } || { echo "1 1"; return; }   # [CR] 'null' = fail-closed
  t="$(printf '%s' "$j" | jq -s '[.[].data.repository.pullRequest.reviewThreads.nodes[]?|select((.comments.nodes[0].author.login//"")|ascii_downcase|(.=="coderabbitai[bot]" or .=="coderabbitai"))|select(.isResolved==false)]|length' 2>/dev/null || echo 1)"
  b="$(printf '%s' "$j" | jq -s '[.[].data.repository.pullRequest.reviewThreads.nodes[]?|select((.comments.nodes[0].author.login//"")|ascii_downcase|(.=="coderabbitai[bot]" or .=="coderabbitai"))|select(.isResolved==false)|select(.comments.nodes[0].body|test("🔴|🟠|\\bCritical\\b|\\bMajor\\b|Potential issue|Security|🛡️|⚠️|\\bP0\\b|\\bP1\\b"))]|length' 2>/dev/null || echo 1)"
  echo "${t:-1} ${b:-1}"
}

# --- Recolección de hechos por gh API (runtime) ----------------------------
# [TAL-8037] Verificación del estado Linear del issue del PR (extraída de tco_gather_and_gate para poder probarla): rc 1 =
# la clave del team no resuelve (FAIL fail-closed, nombrando la variable); rc 0 en cualquier otro caso (el estado Linear es
# trazabilidad: sus fallos solo se reportan).
tco_mg_linear_issue_check() { # pr repo
  local pr="$1" repo="$2"
  local pr_issue cur_state
  # [TAL-8037] La clave del team Linear es de la INSTANCIA (TF_LINEAR_TEAM_KEY: env o manifiesto TCO_TF_MANIFEST):
  # sin ella no se sabe qué magic word buscar — el gate FALLA cerrado nombrando la variable, no asume ninguna clave.
  tco_linear_team_key >/dev/null || { echo "FAIL: TF_LINEAR_TEAM_KEY sin resolver — no puedo extraer el issue del PR para verificar su estado Linear (fail-closed)"; return 1; }
  # [CR] las 9 variantes que GitHub reconoce + normalizado a MAYUSCULAS: ver tco_pr_issue_from_body (lib.sh).
  pr_issue="$(gh pr view "$pr" --repo "$repo" --json body --jq '.body' 2>/dev/null | tco_pr_issue_from_body || true)"
  if [ -n "$pr_issue" ]; then
    cur_state="$(tco_linear_issue_state "$pr_issue" | awk '{print $1}' || true)"
    if [ "$cur_state" = "$TCO_LINEAR_INREVIEW_STATE" ]; then
      tco_info "$pr_issue en In Review (Linear) — OK"
    elif tco_linear_set_state "$pr_issue" "$TCO_LINEAR_INREVIEW_STATE"; then
      tco_info "$pr_issue NO estaba In Review — AUTO-REMEDIADO por el gate"
    else
      tco_err "$pr_issue: no pude verificar/poner In Review en Linear (no bloquea el gate de codigo; revisar a mano)"
    fi
  else
    tco_err "PR #$pr sin magic word 'closes/fixes/resolves <CLAVE>-N' en el body — sin issue que trazar (revisar: el auto-close de Done depende de esto)"
  fi
  return 0
}

tco_gather_and_gate() { # pr audited_sha
  local pr="$1" audited="$2" repo="$TCO_REPO_SLUG"
  # [CR] mismo fail-closed que approve-merge.sh: pr/sha validados ANTES de entrar en rutas
  # (approvals/<pr>-<sha>.ok) y en la URL REST (un '/' o '..' desviaria endpoint/ruta).
  printf '%s' "$pr" | grep -qE '^[0-9]+$' || { echo "FAIL: pr invalido: $pr"; return 1; }
  printf '%s' "$audited" | grep -qE '^[0-9a-f]{40}$' || { echo "FAIL: sha invalido: $audited (40 hex)"; return 1; }
  local head rollup_bad threads blockers shaok humanok reviews rollup_json mergestate meta tj
  local review_check cr_reviews review_real labels_json cr_label
  # headRefOid + mergeStateStatus en una sola consulta (ambos del estado ACTUAL del PR/headSha).
  meta="$(gh pr view "$pr" --repo "$repo" --json headRefOid,mergeStateStatus 2>/dev/null || echo '{}')"
  head="$(printf '%s' "$meta" | jq -r '.headRefOid // ""' 2>/dev/null)"
  mergestate="$(printf '%s' "$meta" | jq -r '.mergeStateStatus // "UNKNOWN"' 2>/dev/null)"; [ -n "$mergestate" ] || mergestate=UNKNOWN
  # [v5/B9] shaok: exacto, o EQUIVALENTE si el entregable es byte-idéntico tras un rebase mecánico
  # (tco_deliverable_unchanged, SIEMPRE con traza SHAOK-EQUIV/NO-EQUIV visible). Kill-switch TCO_SHAOK_EQUIV=no.
  local shaok_via="exacto" equiv_trace=""
  if [ -n "$head" ] && [ "$head" = "$audited" ]; then
    shaok=yes
  elif [ -n "$head" ] && [ "${TCO_SHAOK_EQUIV:-yes}" = yes ] && equiv_trace="$(tco_deliverable_unchanged "$audited" "$head")"; then
    shaok=yes; shaok_via="equivalente"
    printf '%s\n' "$equiv_trace" | sed 's/^/   /'
  else
    shaok=no
    [ -n "$equiv_trace" ] && printf '%s\n' "$equiv_trace" | sed 's/^/   /'
  fi
  tco_info "shaok=$shaok via=$shaok_via (audited=${audited:0:12} head=${head:0:12})"
  # [B5] OK humano = aprobación TRAZABLE por PR+SHA (archivo creado por approve-merge.sh), NO un env
  # global. [v5] Atada al HEAD que efectivamente se mergea: con shaok equivalente, el lead aprueba el
  # head nuevo (approve-merge.sh ya valida que el sha aprobado sea el head vigente del PR).
  [ -n "$head" ] && [ -f "$SECRET_DIR/approvals/$pr-$head.ok" ] && humanok=yes || humanok=no
  # rollup del headSha (una sola consulta) → clasificadores puros
  rollup_json="$(gh pr view "$pr" --repo "$repo" --json statusCheckRollup --jq '.statusCheckRollup' 2>/dev/null || echo '')"
  rollup_bad="$(printf '%s' "$rollup_json" | tco_rollup_bad)" || true
  # [M8] 'revisión presente' = check de CR en el rollup Y review REAL en los comentarios (no 'Review
  # skipped') Y etiqueta cr-review en el PR. Un status verde sin review (skip) ya NO pasa el gate.
  review_check="$(printf '%s' "$rollup_json" | tco_reviews_present)" || true
  # [bug3] reviews ATADAS al commit (el REST .../pulls/N/reviews trae commit_id) → la review REAL debe ser
  # sobre el headSha auditado ($head), no una histórica de un commit anterior.
  # [CR] --paginate: sin él solo llega la PRIMERA página (30 reviews) y la review de CR sobre el
  # headSha actual puede quedar fuera en PRs con muchas reviews → bloqueo de merges válidos.
  # [CR #547 Major] APLANADO EN EL ORIGEN: --paginate --jq emite un array POR PÁGINA; jq -s 'add'
  # los funde en UN solo array (los helpers además toleran multi-array por si un caller lo omite).
  cr_reviews="$(gh api --paginate "repos/$repo/pulls/$pr/reviews" --jq '[.[]?|{login:(.user.login//""), commit_id:(.commit_id//""), state:(.state//""), body:(.body//"")}]' 2>/dev/null | jq -s 'add // []' 2>/dev/null || echo '[]')"
  review_real="$(printf '%s' "$cr_reviews" | tco_cr_review_real "$head")" || true
  labels_json="$(gh pr view "$pr" --repo "$repo" --json labels --jq '[.labels[].name]' 2>/dev/null || echo '[]')"
  cr_label="$(printf '%s' "$labels_json" | jq -r 'if any(.[]?; .=="cr-review") then "yes" else "no" end' 2>/dev/null || echo no)"
  # [v5/B1] M8 — SOLO DOS VÍAS APRUEBAN (condición del lead): (a) review REAL de CR con
  # commit_id == headSha, o (b) WAIVER explícito y trazable del lead atado a PR+headSha
  # (waive-cr.sh). Las señales débiles (status check SUCCESS, comments post-push, "Review
  # skipped: no new commits") son DIAGNÓSTICO: se imprimen como M8=WAIVER_REQUIRED y JAMÁS
  # producen reviews=yes. El label cr-review se exige en AMBAS vías (backstop del App).
  local review_via waiver_present=no m8_out waiver_f="$SECRET_DIR/waivers/$pr-$head.cr-waiver"
  [ -n "$head" ] && [ -f "$waiver_f" ] && waiver_present=yes
  # [issue 9011] Revisor: SOLO el literal code-audit abre la tercera vía (GO verificado contra el head); cualquier otro valor
  # —vacío, coderabbit, un typo— es coderabbit y no consulta ni el GO (fail-closed). Con coderabbit nada de esto se ejecuta.
  local revisor="${TCO_REVISOR:-coderabbit}" code_audit_ok=no ca_out=''
  [ "$revisor" = code-audit ] || revisor=coderabbit
  if [ "$revisor" = code-audit ]; then
    if ca_out="$(tco_code_audit_go_comments "$pr" "$repo" | tco_code_audit_go_verify "$head" "$(date -u +%s)" \
          "${TCO_CODE_AUDIT_TTL:-172800}" "${TCO_CODE_AUDIT_RUN_ID:-}" "$(tco_code_audit_go_authors)")"; then
      code_audit_ok=yes
    fi
  fi
  if m8_out="$(tco_m8_compose_rev "$revisor" "$cr_label" "$review_check" "$review_real" "$waiver_present" "$code_audit_ok")"; then reviews=yes; else reviews=no; fi
  review_via="${m8_out#* }"
  if [ "$review_via" = waiver ]; then
    # [v5/M2] la traza del waiver SOBREVIVE en el output final: nunca un `yes` silencioso.
    tco_info "M8=waived via=waiver $(grep -E '^(waived_by|at|reason)=' "$waiver_f" 2>/dev/null | tr '\n' ' ')(PR #$pr @ ${head:0:12})"
  fi
  if [ "$review_via" = code-audit ]; then
    tco_info "M8=yes via=code-audit run_id=${ca_out#yes } (PR #$pr @ ${head:0:12}) — revisor sin capa externa, NO recomendable"
  fi
  if [ "$reviews" = no ] && [ "$revisor" = code-audit ]; then
    tco_info "M8 code-audit: sin GO verificado sobre ${head:0:12} (${ca_out:-no sin-datos}). Camino: auditoría de código GO sobre el head + verify-code-audit-go.sh --archivar; el waiver sigue siendo una excepción trazada del lead (waive-cr.sh $pr $head --reason \"...\")"
  elif [ "$reviews" = no ]; then
    # [C17] Si el ÚLTIMO review de CR sobre el head pidió cambios, el diagnóstico es explícito:
    # NO es señal débil — es un rechazo vigente. Caminos: re-review hasta APPROVED o waiver.
    local cr_last; cr_last="$(printf '%s' "$cr_reviews" | tco_cr_last_state "$head")"
    if [ "$cr_last" = CHANGES_REQUESTED ]; then
      tco_info "M8=CHANGES_REQUESTED — el último review de CR sobre ${head:0:12} PIDIÓ CAMBIOS (C17); resolver hilos a mano no lo convierte en aprobación. Caminos: corregir + '@coderabbitai review' hasta APPROVED, o waiver del lead: waive-cr.sh $pr $head --reason \"...\""
    fi
    # Diagnóstico de señales débiles (solo lecturas; ninguna aprueba) → guía de caminos soportados.
    local crok_n push_ts comments_json comment_marker skip_r skip_c
    crok_n="$(printf '%s' "$rollup_json" | tco_cr_checkrun_ok)" || true
    push_ts="$(printf '%s' "$rollup_json" | tco_rollup_first_started)" || true
    comments_json="$(gh api --paginate "repos/$repo/issues/$pr/comments" \
      --jq '[.[]?|{login:(.user.login//""), created:(.created_at//""), body:(.body//"")}]' 2>/dev/null | jq -s 'add // []' 2>/dev/null || echo '[]')"
    comment_marker="$(printf '%s' "$comments_json" | tco_cr_comment_marker "$push_ts")" || true
    skip_r="$(printf '%s' "$cr_reviews" | tco_cr_skip_nonew "$head")" || true
    skip_c="$(printf '%s' "$comments_json" | jq -r --arg ts "${push_ts:-9999}" \
      '[.[]?|select(((.login//"")|ascii_downcase)|(.=="coderabbitai[bot]" or .=="coderabbitai"))|select((.created//"") > $ts)|select((.body//"")|test("review skipped";"i"))|select((.body//"")|test("no new commits";"i"))]|if length>0 then "yes" else "no" end' 2>/dev/null || echo no)"
    tco_info "M8 diagnóstico: real@head=$review_real label=$cr_label checkrun-success=$crok_n comment-post-push=$comment_marker skip-no-new=[review:$skip_r comment:$skip_c]"
    if [ "${crok_n:-0}" -gt 0 ] 2>/dev/null || [ "$comment_marker" = yes ] || [ "$skip_r" = yes ] || [ "$skip_c" = yes ]; then
      tco_info "M8=WAIVER_REQUIRED — hay señales débiles de CR pero NINGUNA aprueba (B1). Caminos soportados: (a) PR nuevo desde la misma rama con body limpio [PROC-04] para que CR revise fresco; (b) waiver del lead: waive-cr.sh $pr $head --reason \"...\""
    fi
  fi
  tco_info "M8: reviews=$reviews via=$review_via label=$cr_label"
  # (b)+(c) de UNA sola query de review threads (estado real; no /pulls/comments, que persisten tras resolver).
  # --paginate + $endCursor: cubre PRs con >100 review threads (gh inyecta el cursor y concatena páginas).
  tj="$(gh api graphql --paginate -F o="${repo%%/*}" -F r="${repo##*/}" -F p="$pr" \
    -f query='query($o:String!,$r:String!,$p:Int!,$endCursor:String){repository(owner:$o,name:$r){pullRequest(number:$p){reviewThreads(first:100,after:$endCursor){pageInfo{hasNextPage endCursor} nodes{isResolved comments(first:1){nodes{author{login} body}}}}}}}' 2>/dev/null || echo '')"
  read -r threads blockers < <(printf '%s' "$tj" | tco_threads_blockers)
  # [CR] Anti-carrera: rollup/labels/reviews/threads se consultaron en llamadas separadas; si un
  # push entró en esa ventana, las señales podrían mezclar DOS heads distintos. Releer headRefOid
  # justo antes de decidir y fallar si cambió (el gate se re-corre entero sobre el head nuevo).
  local head2
  head2="$(gh pr view "$pr" --repo "$repo" --json headRefOid --jq '.headRefOid' 2>/dev/null || echo '')"
  if [ -z "$head2" ] || [ "$head2" != "$head" ]; then
    echo "FAIL: headRefOid cambió durante la evaluación del gate ($head -> ${head2:-?}) — re-correr merge-gate sobre el head nuevo"
    return 1
  fi
  # [TAL-1615] El issue del PR (magic word del body) debe estar In Review al evaluar el merge.
  # AUTO-REMEDIA (lo pone In Review si no lo esta) en vez de bloquear: el estado Linear es
  # trazabilidad, no calidad de codigo — pero queda GARANTIZADO, no en fe del dev.
  # [v5/B3] En smoke (--no-linear + TCO_SMOKE_MODE=yes) este bloque se SALTA: probar el gate
  # contra PRs históricos no debe mutar estados reales de Linear.
  if [ "${TCO_MG_NO_LINEAR:-no}" = yes ]; then
    tco_info "SMOKE (--no-linear): salto la verificación/auto-remediación de estado Linear del issue"
  else
    tco_mg_linear_issue_check "$pr" "$repo" || return 1
  fi
  # [v5/B2] El gate NO mergea: en PASS imprime el comando canónico. --match-head-commit ata el
  # merge al head exacto evaluado (si el head cambia entre gate y merge, GitHub lo rechaza —
  # cierra la carrera).
  # El modo auto-merge de gh está PROHIBIDO en la doctrina (rompe la garantía de merge humano exact-head).
  local decision drc=0
  decision="$(tco_merge_decide "$rollup_bad" "$blockers" "$threads" "$shaok" "$humanok" "$reviews" "$mergestate")" || drc=$?
  if [ "$drc" -eq 0 ]; then
    tco_info "go-merge canónico:"
    tco_info "  gh pr merge $pr --repo \"$repo\" --squash --delete-branch --match-head-commit $head"
    [ "$review_via" = waiver ] && tco_info "RECORDATORIO M2: este PASS lleva M8=waived via=waiver (evidencia en $waiver_f) — no es una review real de CR"
  fi
  printf '%s\n' "$decision"
  return "$drc"
}

# Ejecución directa (no cuando se source-ea para tests)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  TCO_MG_NO_LINEAR=no
  if [ "${1:-}" = --no-linear ]; then
    # [v5/B3+M1] Flag RESERVADO a smoke tests (guard operativo del lead): sin TCO_SMOKE_MODE=yes
    # el gate MUERE — jamás usarlo para saltarse la trazabilidad Linear en trabajo real.
    [ "${TCO_SMOKE_MODE:-}" = yes ] || tco_die "--no-linear es SOLO para smoke tests: requiere TCO_SMOKE_MODE=yes en el entorno (guard M1)"
    TCO_MG_NO_LINEAR=yes; shift
  fi
  [ $# -ge 2 ] || tco_die "uso: merge-gate.sh [--no-linear] <pr_number> <audited_sha>  (OK humano = approve-merge.sh; waiver M8 = waive-cr.sh; --no-linear solo smoke)"
  tco_load_tokens
  tco_gather_and_gate "$1" "$2"
fi
