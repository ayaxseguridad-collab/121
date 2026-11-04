#!/usr/bin/env bash
# verify-handoff.sh — Verificación POST-push de una entrega draft (Fábrica v2, ADR-0043 / TAL-2193).
#
# El sentinel de draft-handoff.sh autoriza el PUSH, pero no garantiza la ENTREGA:
# este script verifica contra GitHub que el PR es realmente un draft con comentario
# HANDOFF válido. Lo corren: el canal al entregar, el coordinador al validar la entrega
# (regla 13 de talent-channel-operation) y el Mergeador en el intake.
#
# Contrato del HANDOFF (fuente canónica: docs/templates/handoff-pr-draft.md, schema_version 2;
# TAL-2825 — versionado monótono acumulativo, ver plantilla). El validador conoce un conjunto
# CERRADO de versiones: {1, 2}. Cualquier otra (incluida una v3 futura de TAL-2683, hasta que
# extienda este script) ⇒ fail-closed, nunca se aprueba a ciegas.
# Validación FAIL-CLOSED: cualquier incumplimiento ⇒ exit 1.
#   - PR en estado DRAFT.
#   - Comentario con bloque ```json cuyo objeto tiene schema_version (gana el último) Y
#     con TODAS las cabeceras canónicas de la plantilla en el MISMO comentario (## HANDOFF +
#     las secciones humanas: qué hace, decisiones, invariantes, superficies, migraciones,
#     archivos calientes, verificación, trampas). Un comentario JSON-only NO es entrega: el
#     Mergeador audita los refactors CONTRA los invariantes y trampas declarados.
#   - schema_version == 2: build OBLIGATORIO ("validado"|"omitido", fail-closed).
#     schema_version == 1: aceptado con aviso de deprecación (coexistencia HANDOFF en vuelo,
#     TAL-2820 → TAL-2825); build se ignora en v1. Otro valor ⇒ fail-closed.
#   - issues: no vacío, todos ^<TF_LINEAR_TEAM_KEY>-[0-9]+$ (clave del team de la instancia), y un closes/fixes/resolves TAL-N en el body por cada uno
#     (salvo closure_regime=data-op-sin-cierre: Refs TAL-N obligatorio y closes/fixes/resolves PROHIBIDO).
#   - head_sha: 40 hex e igual a headRefOid ACTUAL (HANDOFF stale tras un push nuevo NO valida).
#   - branch == headRefName y válida según scripts/github/validar-rama-pr.sh (la MISMA regex
#     que el required check validar-flujo-pr — fuente única, sin regex paralela).
#   - sensitive boolean y coherente con surfaces (allowlist exacto); migration_slots ^[0-9]{14}$
#     (no vacío ⇒ "migraciones" ∈ surfaces); destructive boolean (true ⇒ slots no vacío).
#
# Uso: bash scripts/verify-handoff.sh <numero-de-pr | rama>
# Test/offline: VH_GH_BIN=<mock> sustituye el binario gh (mismos subcomandos/flags).
set -euo pipefail

GH_BIN="${VH_GH_BIN:-gh}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || { echo "[verify-handoff] no estás en un repo git." >&2; exit 2; }
BRANCH_CHECK="$ROOT/scripts/github/validar-rama-pr.sh"
# Extractor ÚNICO del bloque HANDOFF (compartido con crosscheck-migration-slot.sh — sin regex paralela).
HANDOFF_LIB="$ROOT/scripts/lib/handoff.sh"
[ -f "$HANDOFF_LIB" ] || { echo "[verify-handoff] no encuentro $HANDOFF_LIB (fail-closed)." >&2; exit 2; }
# shellcheck source=scripts/lib/handoff.sh
. "$HANDOFF_LIB"
PR="${1:-}"
[ -n "$PR" ] || { echo "[verify-handoff] uso: bash scripts/verify-handoff.sh <pr|rama>" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "[verify-handoff] falta jq." >&2; exit 2; }
command -v "$GH_BIN" >/dev/null 2>&1 || { echo "[verify-handoff] falta gh (o VH_GH_BIN inválido)." >&2; exit 2; }

# ── Allowlist de superficies: fuente única = manifiesto de la fábrica (TAL-2288, decisión 7) ──
# Resolución FAIL-CLOSED, sin allowlist embebida: env TF_MANIFEST (ruta absoluta) → copia
# local .claude/tf-manifest.conf (la empuja el despacho/provisioning al canal; gitignored).
# Sin manifiesto resoluble ⇒ exit 2: un gate sin fuente real de allowlist no puede dar verde.
# El manifiesto NO se ejecuta (sin `source`): es un fichero empujable al canal y este script
# corre también en la estación de merge — solo se EXTRAE la línea TF_SENSITIVE_SURFACES.
# Manifiesto presente pero clave ausente/vacía ⇒ fail-closed (exit 2), no degradación silenciosa.
manifest_path=""
manifest_origin=""
if [ -n "${TF_MANIFEST:-}" ]; then
  case "$TF_MANIFEST" in
    /*) ;;
    *) echo "[verify-handoff] TF_MANIFEST='$TF_MANIFEST' no es ruta absoluta (fail-closed)." >&2; exit 2 ;;
  esac
  manifest_path="$TF_MANIFEST"
  [ -f "$manifest_path" ] || { echo "[verify-handoff] TF_MANIFEST='$manifest_path' no existe (fail-closed)." >&2; exit 2; }
  manifest_origin="env TF_MANIFEST=$manifest_path"
elif [ -f "$ROOT/.claude/tf-manifest.conf" ]; then
  manifest_path="$ROOT/.claude/tf-manifest.conf"
  manifest_origin="copia local del canal ($manifest_path)"
else
  {
    echo "[verify-handoff] SIN manifiesto de fábrica: ni env TF_MANIFEST ni copia local $ROOT/.claude/tf-manifest.conf (fail-closed)."
    echo "[verify-handoff] Provisión requerida: el despacho empuja .claude/tf-manifest.conf al canal, o exporta TF_MANIFEST=/ruta/absoluta/al/manifiesto."
  } >&2
  exit 2
fi
surfaces_line="$(sed -n 's/^TF_SENSITIVE_SURFACES="\([^"]*\)".*$/\1/p' "$manifest_path" | tail -1)"
[ -n "$surfaces_line" ] || { echo "[verify-handoff] '$manifest_path' sin TF_SENSITIVE_SURFACES válido (fail-closed — el manifiesto es la fuente única del vocabulario de superficies)." >&2; exit 2; }
ALLOWLIST="$(printf '%s' "$surfaces_line" | jq -Rc 'split(" ") | map(select(length > 0))')"
# Vocabulario vacío tras normalizar (p. ej. solo espacios) ⇒ mismo fail-closed que clave ausente.
[ "$ALLOWLIST" != "[]" ] || { echo "[verify-handoff] '$manifest_path' con TF_SENSITIVE_SURFACES sin tokens (vocabulario vacío ⇒ fail-closed — el manifiesto es la fuente única del vocabulario de superficies)." >&2; exit 2; }
# ── Clave del team Linear de la INSTANCIA (TAL-8037): jamás un default de casa. Resolución FAIL-CLOSED: env
# TF_LINEAR_TEAM_KEY → línea TF_LINEAR_TEAM_KEY= del MISMO manifiesto (como DATO, sin source) → exit 2.
linear_key="${TF_LINEAR_TEAM_KEY:-}"
[ -n "$linear_key" ] || linear_key="$(sed -n -E 's/^TF_LINEAR_TEAM_KEY=("([^"]*)"|([^[:space:]"#]*)).*$/\2\3/p' "$manifest_path" | tail -1)"
[ -n "$linear_key" ] || { echo "[verify-handoff] SIN TF_LINEAR_TEAM_KEY: ni env ni línea TF_LINEAR_TEAM_KEY= en '$manifest_path' (fail-closed — la clave del team es de la instancia, jamás se asume)." >&2; exit 2; }
[[ $linear_key =~ ^[A-Z][A-Z0-9]{0,9}$ ]] || { echo "[verify-handoff] TF_LINEAR_TEAM_KEY inválida ('$linear_key'): se espera ^[A-Z][A-Z0-9]{0,9}$ (fail-closed)." >&2; exit 2; }
echo "[verify-handoff] manifiesto: $manifest_origin"
echo "[verify-handoff] allowlist de superficies: $ALLOWLIST"

errors=0
ok()   { echo "[verify-handoff]   OK  $1"; }
bad()  { echo "[verify-handoff] FAIL  $1" >&2; errors=$((errors + 1)); }

pr_json="$("$GH_BIN" pr view "$PR" --json number,isDraft,headRefOid,headRefName,body,comments 2>/dev/null)" \
  || { echo "[verify-handoff] no pude leer el PR '$PR' vía gh." >&2; exit 2; }

pr_number="$(jq -r '.number' <<<"$pr_json")"
is_draft="$(jq -r '.isDraft' <<<"$pr_json")"
head_oid="$(jq -r '.headRefOid' <<<"$pr_json")"
head_ref="$(jq -r '.headRefName' <<<"$pr_json")"
pr_body="$(jq -r '.body // ""' <<<"$pr_json")"

echo "[verify-handoff] PR #$pr_number · head $head_ref @ ${head_oid:0:12}"

# ── 1. Estado draft ─────────────────────────────────────────────────────────
if [ "$is_draft" = "true" ]; then ok "el PR está en DRAFT"; else bad "el PR NO está en draft (isDraft=$is_draft) — la entrega es PR DRAFT; ready lo marca el Mergeador"; fi

# ── 2. Localizar el HANDOFF (gana el último comentario con bloque válido) ──
# Recorre los comentarios en orden; de cada body extrae los fences ```json y se queda
# con el último objeto parseable que tenga schema_version — y conserva el COMENTARIO
# completo que lo contiene (las secciones humanas se validan sobre ese mismo comentario).
# Extracción vía lib/handoff.sh (fuente única); mantenemos los nombres locales downstream.
handoff_extract "$pr_json"
handoff="$HANDOFF_BLOCK"
handoff_comment="$HANDOFF_COMMENT"

if [ -z "$handoff" ]; then
  bad "ningún comentario del PR contiene un bloque \`\`\`json con schema_version (plantilla: docs/templates/handoff-pr-draft.md)"
  echo "[verify-handoff] RESULTADO: ENTREGA INVÁLIDA ($errors fallos)." >&2
  exit 1
fi
ok "bloque machine-readable encontrado"

# ── 2b. Secciones humanas del HANDOFF (mismo comentario que el bloque) ─────
# Un bloque JSON suelto NO es entrega: sin invariantes/decisiones/trampas el Mergeador no
# puede operar el PR. Cabeceras canónicas de la plantilla (Review process de la plantilla:
# cambiarlas allí exige actualizar esta lista en el MISMO PR).
if ! grep -q '^## HANDOFF' <<<"$handoff_comment"; then
  bad "el comentario del HANDOFF no empieza por '## HANDOFF …' (plantilla docs/templates/handoff-pr-draft.md)"
fi
missing_sections=""
while IFS= read -r section; do
  grep -qF "$section" <<<"$handoff_comment" || missing_sections="$missing_sections '$section'"
done <<'SECTIONS'
### Qué hace
### Decisiones y porqués
### Invariantes sellados por el code-audit
### Superficies tocadas y clasificación
### Migraciones
### Archivos calientes
### Verificación local ejecutada
### Qué NO tocar / trampas
### Bloque machine-readable
SECTIONS
if [ -n "$missing_sections" ]; then
  bad "faltan secciones canónicas en el comentario del HANDOFF (JSON-only no es entrega):$missing_sections"
else
  ok "las 9 secciones canónicas de la plantilla están presentes"
fi

# ── 3. Schema fail-closed (versionado monótono acumulativo, TAL-2825) ───────
# Conjunto de versiones CONOCIDO por este validador: {1, 2}. Cualquier otra ⇒ fail-closed.
sv="$(jq -r 'if (.schema_version | type) == "number" then (.schema_version | tostring) else "NaN" end' <<<"$handoff")"
case "$sv" in
  1)
    ok "schema_version == 1 (HANDOFF legacy en coexistencia — build no exigido)"
    echo "[verify-handoff] AVISO: schema_version 1 está DEPRECADO (TAL-2825) — re-emitir el bloque en schema_version 2 con \"build\" en el próximo push." >&2
    ;;
  2)
    ok "schema_version == 2"
    ;;
  *)
    bad "schema_version desconocido para este validador (conoce 1 y 2; valor: $(jq -c '.schema_version' <<<"$handoff"))"
    ;;
esac

# ── 3b. build (OBLIGATORIO bajo schema_version 2; TAL-2825) ────────────────
if [ "$sv" = "2" ]; then
  if jq -e '(.build | type == "string") and (.build == "validado" or .build == "omitido")' <<<"$handoff" >/dev/null 2>&1; then
    ok "build declarado: $(jq -r '.build' <<<"$handoff")"
  else
    bad "build inválido: en schema_version 2 es OBLIGATORIO y debe ser \"validado\" u \"omitido\" (valor: $(jq -c '.build // "<ausente>"' <<<"$handoff"))"
  fi
fi

if jq -e --arg k "$linear_key" '(.issues | type == "array" and length > 0) and all(.issues[]; type == "string" and test("^" + $k + "-[0-9]+$"))' <<<"$handoff" >/dev/null 2>&1; then
  ok "issues: $(jq -cr '.issues | join(", ")' <<<"$handoff")"
else
  bad "issues inválido: debe ser array NO vacío de \"${linear_key}-<n>\" (valor: $(jq -c '.issues' <<<"$handoff"))"
fi

decl_sha="$(jq -r '.head_sha // ""' <<<"$handoff")"
if printf '%s' "$decl_sha" | grep -Eq '^[0-9a-f]{40}$'; then
  if [ "$decl_sha" = "$head_oid" ]; then
    ok "head_sha declarado == headRefOid"
  else
    bad "HANDOFF stale: head_sha declarado ${decl_sha:0:12} != headRefOid ${head_oid:0:12} — re-emitir el bloque tras el último push"
  fi
else
  bad "head_sha inválido (40 hex requerido): '$decl_sha'"
fi

decl_branch="$(jq -r '.branch // ""' <<<"$handoff")"
if [ "$decl_branch" = "$head_ref" ]; then ok "branch declarada == headRefName"; else bad "branch declarada '$decl_branch' != headRefName '$head_ref'"; fi
# Fuente ÚNICA de la convención de rama: el mismo script que corre el required check
# validar-flujo-pr (nada de regex paralela que pueda divergir). Fail-closed si falta.
if [ ! -f "$BRANCH_CHECK" ]; then
  bad "no encuentro $BRANCH_CHECK — no puedo validar la rama (fail-closed)"
elif bash "$BRANCH_CHECK" "$head_ref" >/dev/null 2>&1; then
  ok "rama válida según validar-rama-pr.sh (misma regla que el required check)"
else
  bad "rama '$head_ref' RECHAZADA por validar-rama-pr.sh — fallará el required check validar-flujo-pr"
fi

jq -e '.sensitive | type == "boolean"' <<<"$handoff" >/dev/null 2>&1 \
  || bad "sensitive debe ser boolean (valor: $(jq -c '.sensitive' <<<"$handoff"))"
jq -e '.destructive | type == "boolean"' <<<"$handoff" >/dev/null 2>&1 \
  || bad "destructive debe ser boolean (valor: $(jq -c '.destructive' <<<"$handoff"))"

if jq -e --argjson allow "$ALLOWLIST" \
    '(.surfaces | type == "array") and all(.surfaces[]; . as $s | $allow | index($s) != null) and (.surfaces | length == (unique | length))' \
    <<<"$handoff" >/dev/null 2>&1; then
  ok "surfaces dentro del allowlist: $(jq -c '.surfaces' <<<"$handoff")"
else
  bad "surfaces inválido (array único, subconjunto de $ALLOWLIST): $(jq -c '.surfaces' <<<"$handoff")"
fi

if jq -e '(.sensitive == ((.surfaces // []) | length > 0))' <<<"$handoff" >/dev/null 2>&1; then
  ok "sensitive coherente con surfaces"
else
  bad "incoherencia: sensitive=$(jq -c '.sensitive' <<<"$handoff") con surfaces=$(jq -c '.surfaces' <<<"$handoff") (sensitive ⟺ surfaces no vacío)"
fi

if jq -e '(.migration_slots | type == "array") and all(.migration_slots[]; type == "string" and test("^[0-9]{14}$"))' <<<"$handoff" >/dev/null 2>&1; then
  ok "migration_slots con formato estable: $(jq -c '.migration_slots' <<<"$handoff")"
else
  bad "migration_slots inválido (array de strings ^[0-9]{14}\$): $(jq -c '.migration_slots' <<<"$handoff")"
fi
jq -e '((.migration_slots // []) | length == 0) or ((.surfaces // []) | index("migraciones") != null)' <<<"$handoff" >/dev/null 2>&1 \
  || bad "hay migration_slots pero \"migraciones\" ∉ surfaces (las migraciones son SIEMPRE superficie sensible)"
jq -e '(.destructive != true) or ((.migration_slots // []) | length > 0)' <<<"$handoff" >/dev/null 2>&1 \
  || bad "destructive=true sin migration_slots — incoherente"

# ── 3d. closure_regime (opcional; SOLO bajo schema_version 2) ────────────────
# Bajo v1: ignorado (igual que model_per_phase y build — coexistencia de v1 en vuelo,
# TAL-2820→TAL-2825). Un HANDOFF v1 con closure_regime no activa el nuevo régimen;
# §4 corre con la semántica v1 estándar (closes obligatorio, sin cambio).
# Bajo v2: si presente, debe ser EXACTAMENTE "data-op-sin-cierre" (fail-closed ante
# cualquier otro valor — no se acepta a ciegas un régimen futuro no implementado).
# Patrón: campo opcional aditivo dentro de v2 — su ausencia deja la validación idéntica
# a hoy; ningún HANDOFF v2 existente se invalida (sin bump, ver handoff-pr-draft.md).
data_op=false
if [ "$sv" = "2" ]; then
  if jq -e 'has("closure_regime")' <<<"$handoff" >/dev/null 2>&1; then
    if jq -e '.closure_regime == "data-op-sin-cierre"' <<<"$handoff" >/dev/null 2>&1; then
      ok "closure_regime == data-op-sin-cierre (Refs TAL-N requerido; closes/fixes/resolves PROHIBIDO en §4)"
      data_op=true
    else
      bad "closure_regime inválido: único valor soportado es \"data-op-sin-cierre\" (valor: $(jq -c '.closure_regime' <<<"$handoff"))"
    fi
  fi
fi

# ── 3e. category (opcional; SOLO bajo schema_version 2; TAL-3857) ────────────
# Señal NO-sensible del HANDOFF, DESACOPLADA del gate de superficies (dictamen del PM,
# TAL-3811 01-ago): marca los encargos ops/tooling no-product (gates del push, hooks de
# gobernanza, scripts de verificación) para el ruteo del Mergeador SIN contaminar
# TF_SENSITIVE_SURFACES — meter ops ahí o sobre-gatearía tooling rutinario o diluiría el
# significado de "sensible". `surfaces: []` sigue siendo lo CORRECTO para un encargo ops.
# Bajo v1: ignorado (coexistencia, igual que build/closure_regime). Bajo v2: si presente,
# EXACTAMENTE "ops" (fail-closed ante cualquier otro valor — mismo patrón de conjunto
# cerrado que closure_regime, extensible aditivamente sin bump). Campo opcional aditivo: su
# ausencia deja la validación idéntica a hoy; ningún HANDOFF v2 existente se invalida.
if [ "$sv" = "2" ]; then
  if jq -e 'has("category")' <<<"$handoff" >/dev/null 2>&1; then
    if jq -e '.category == "ops"' <<<"$handoff" >/dev/null 2>&1; then
      ok "category == ops (señal no-sensible, desacoplada del gate de superficies)"
    else
      bad "category inválido: único valor soportado es \"ops\" (valor: $(jq -c '.category' <<<"$handoff"))"
    fi
  fi
fi

# ── 4. cierre/referencia por issue del bloque ───────────────────────────────
# Default: closes/fixes/resolves TAL-N obligatorio (Linear cierra al merge).
# data-op-sin-cierre: el canal AUTOR NUNCA cierra — EXIGE Refs TAL-N y RECHAZA cualquier
# closes/fixes/resolves TAL-N para esa issue (ADDENDUM-1). El cierre automático en un data-op
# viola el invariante sellado; la coordinadora terminal cierra tras el --execute real.
# Nota: hay múltiples líneas con closes/fixes/resolves en este bloque §4 (mensajes + regex);
# todas están confinadas aquí — no hay enforcement de cierre en ningún otro punto del script.
while IFS= read -r issue; do
  [ -n "$issue" ] || continue
  has_close=false; has_ref=false
  printf '%s' "$pr_body" | grep -Eiq "\b(closes|fixes|resolves)[[:space:]]+#?${issue}\b" && has_close=true
  printf '%s' "$pr_body" | grep -Eiq "\brefs[[:space:]]+#?${issue}\b" && has_ref=true
  if [ "$data_op" = true ]; then
    if [ "$has_close" = true ]; then
      bad "INVARIANTE data-op-sin-cierre violado: el body CIERRA $issue (closes/fixes/resolves) — un data-op NUNCA cierra vía el canal autor; usa 'Refs $issue' y deja el cierre a la coordinadora terminal tras el --execute real"
    elif [ "$has_ref" = true ]; then
      ok "body referencia (Refs) $issue sin cerrar — coherente con data-op-sin-cierre"
    else
      bad "falta 'Refs $issue' en el body del PR (closure_regime=data-op-sin-cierre exige referencia SIN cierre)"
    fi
  else
    if [ "$has_close" = true ]; then
      ok "body contiene closes/fixes/resolves $issue"
    else
      bad "falta 'closes $issue' (o fixes/resolves) en el body del PR — sin él Linear no cierra la issue en el merge"
    fi
  fi
done < <(jq -r '(.issues // [])[]' <<<"$handoff" 2>/dev/null)

# ── Veredicto ───────────────────────────────────────────────────────────────
if [ "$errors" -eq 0 ]; then
  echo "[verify-handoff] RESULTADO: ENTREGA VÁLIDA ✓ (PR #$pr_number draft + HANDOFF completo @ ${head_oid:0:12})."
  exit 0
fi
echo "[verify-handoff] RESULTADO: ENTREGA INVÁLIDA ($errors fallos) — corregir y re-verificar." >&2
exit 1
