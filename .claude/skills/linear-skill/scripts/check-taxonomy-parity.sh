#!/usr/bin/env bash
# check-taxonomy-parity.sh — gate de paridad de la taxonomía de labels (TAL-3366).
#
# Contrato:
#   - examples/label-taxonomy.json  = AUTORIDAD interna de nombres/grupos del skill.
#   - examples/talent-engine-config.json (bloque labels + agents.labels_for_workflow_selection)
#     = PROYECCIÓN de UUIDs de esa autoridad, nunca una segunda taxonomía.
#   - examples/label-taxonomy.receipt.json = recibo sanitizado de la consulta viva
#     (issueLabels, paginación completa) contra el que se valida todo en modo por defecto.
#
# Modos:
#   sin flags              valida autoridad + proyección contra el RECIBO commiteado
#   --live                 además re-consulta la API (LINEAR_API_KEY) y exige recibo == vivo
#   --live --emit-receipt  re-consulta la API y REESCRIBE el recibo con ESCRITURA ATÓMICA
#                          (tmp en el mismo directorio + validación JSON + mv; el recibo
#                          anterior sobrevive INTACTO a cualquier fallo). Jamás redirigir la
#                          salida al archivo del recibo: no hace falta y truncaría el original.
#                          Después: revisar el diff en git y re-correr el gate sin flags.
#   --help                 esta ayuda
#
# Reglas fail-closed:
#   - nombre publicado que no existe en el recibo → FAIL (rc 1)
#   - familia del contrato (vertical/ · kind: · sev:) con paridad rota en cualquier
#     dirección recibo↔autoridad↔proyección → FAIL (rc 1)
#   - namespaces muertos (type/ · risk/ · area/ con barra) en la autoridad → FAIL (rc 1)
#   - nombre con multiplicidad >1 en el recibo proyectado con UUID único → FAIL (rc 1);
#     debe llevar id null + duplicate_sites exactos (no se escoge un UUID arbitrario)
#   - recibo/JSON malformado, deps ausentes, uso inválido, key ausente en --live → rc 2
#
# rc: 0 = paridad completa · 1 = verificación FALLÓ · 2 = no se pudo verificar

set -euo pipefail
export LC_ALL=C
trap 'echo "ERROR: fallo inesperado (línea $LINENO)" >&2; exit 2' ERR

SELF_ABS="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SELF_ABS")"
TAXONOMY="$SKILL_DIR/examples/label-taxonomy.json"
CONFIG="$SKILL_DIR/examples/talent-engine-config.json"
RECEIPT="$SKILL_DIR/examples/label-taxonomy.receipt.json"
GRAPHQL_URL="https://api.linear.app/graphql"

MODE="receipt"
EMIT=0
for arg in "$@"; do
  case "$arg" in
    --live) MODE="live" ;;
    --emit-receipt) EMIT=1 ;;
    --help|-h) sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "ERROR: flag desconocida: $arg (usa --live, --emit-receipt o --help)" >&2; exit 2 ;;
  esac
done
if [ "$EMIT" -eq 1 ] && [ "$MODE" != "live" ]; then
  echo "ERROR: --emit-receipt requiere --live (el recibo solo se reconstruye desde la API)" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "ERROR: falta jq" >&2; exit 2; }

# En modo --emit-receipt NO se exige recibo previo válido (es justo lo que se regenera;
# puede estar corrupto o ausente). La validación de entrada aplica a los modos de chequeo.
if [ "$EMIT" -eq 0 ]; then
  for f in "$TAXONOMY" "$CONFIG" "$RECEIPT"; do
    [ -f "$f" ] || { echo "ERROR: falta $f" >&2; exit 2; }
    jq -s -e 'length == 1 and (.[0] | type == "object")' "$f" >/dev/null 2>&1 || { echo "ERROR: JSON malformado: $f" >&2; exit 2; }
  done

  jq -e '.pagination.complete == true and (.labels | type == "array" and length > 0)
         and ([.labels[] | has("id") and has("name")] | all)' "$RECEIPT" >/dev/null 2>&1 \
    || { echo "ERROR: recibo inválido (pagination.complete/labels)" >&2; exit 2; }
fi

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

FAILS=0
CHECKS=0
fail() { FAILS=$((FAILS + 1)); echo "FAIL $1"; }
pass() { echo "PASS $1"; }
check() { CHECKS=$((CHECKS + 1)); }

# ── Modo --live: recibo == API viva (antes de todo lo demás) ──────────────────
if [ "$MODE" = "live" ]; then
  command -v curl >/dev/null 2>&1 || { echo "ERROR: falta curl para --live" >&2; exit 2; }
  if [ -z "${LINEAR_API_KEY:-}" ]; then
    ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    if [ -f "$ROOT/.env.local" ]; then
      # NI TUBERIA NI SUSTITUCION DESNUDA. Con `set -e` + `pipefail`, un `.env.local` que existe
      # pero NO trae la clave —el caso mas probable— mataba el script AQUI con rc 1, asi que su
      # propio diagnostico de dos lineas mas abajo no llegaba a ejecutarse nunca: el operador leia
      # «fallo inesperado (linea 88)» en vez de «--live requiere LINEAR_API_KEY». Y el `head -1`
      # cerraba la tuberia, con lo que `grep` podia morir por SIGPIPE y `pipefail` propagarlo.
      # Se lee el rc: 1 = no esta la clave (LEGITIMO, lo trata la guarda de abajo) · >=2 = no se
      # pudo LEER el fichero, que es NO MEDIDO y no «no hay clave».
      _env_hit=""; _rc_env=0
      _env_hit="$(grep -E '^LINEAR_API_KEY=.+' "$ROOT/.env.local")" || _rc_env=$?
      if [ "$_rc_env" -ge 2 ]; then
        echo "ERROR: no se pudo leer $ROOT/.env.local (rc $_rc_env) — NO MEDIDO, no «sin clave»" >&2
        exit 2
      fi
      if [ -n "$_env_hit" ]; then
        _env_hit="${_env_hit%%$'\n'*}"        # primera coincidencia, sin cerrar ninguna tuberia
        LINEAR_API_KEY="${_env_hit#*=}"
      fi
    fi
  fi
  [ -n "${LINEAR_API_KEY:-}" ] || { echo "ERROR: --live requiere LINEAR_API_KEY (env o .env.local)" >&2; exit 2; }
  CFG="$TMPD/curl.cfg"; : > "$CFG"; chmod 600 "$CFG"
  printf 'header = "Authorization: %s"\n' "$LINEAR_API_KEY" > "$CFG"
  cursor="null"
  PAGES=0
  : > "$TMPD/live.jsonl"
  while :; do
    PAGES=$((PAGES + 1))
    jq -n --argjson c "$cursor" \
      '{query:"query($after:String){ issueLabels(first:100, after:$after){ pageInfo{hasNextPage endCursor} nodes{ id name team{ key } } } }", variables:{after:$c}}' \
      > "$TMPD/q.json"
    if ! curl -sS --fail-with-body --connect-timeout 10 --max-time 60 --config "$CFG" \
        -H "Content-Type: application/json" \
        -d @"$TMPD/q.json" "$GRAPHQL_URL" > "$TMPD/resp.json"; then
      echo "ERROR: fallo HTTP consultando la API (timeout 10s conexión / 60s total)" >&2; exit 2
    fi
    if jq -e '.errors' "$TMPD/resp.json" >/dev/null 2>&1; then
      echo "ERROR: errores GraphQL en la consulta viva" >&2; exit 2
    fi
    jq -c '.data.issueLabels.nodes[] | {id, name, team: (.team.key // null)}' "$TMPD/resp.json" >> "$TMPD/live.jsonl"
    hn="$(jq -r '.data.issueLabels.pageInfo.hasNextPage' "$TMPD/resp.json")"
    if [ "$hn" = "true" ]; then
      cursor="$(jq '.data.issueLabels.pageInfo.endCursor' "$TMPD/resp.json")"
    else
      break
    fi
  done
  jq -s 'sort_by(.name, .team)' "$TMPD/live.jsonl" > "$TMPD/live.json"
  if [ "$EMIT" -eq 1 ]; then
    # Reescritura ATÓMICA del recibo: se construye en un tmp DEL MISMO directorio, se valida
    # el JSON resultante y solo entonces un mv lo pone en su sitio — cualquier fallo previo
    # deja el recibo anterior byte-intacto. Nada viaja por stdout hacia el archivo.
    echo "emit-receipt: $(jq 'length' "$TMPD/live.json") labels en $PAGES página(s)" >&2
    RECEIPT_TMP="$(mktemp "$(dirname "$RECEIPT")/.label-taxonomy.receipt.XXXXXX")"
    jq -n \
      --arg desc "Recibo sanitizado de la autoridad viva: respuesta completa de issueLabels del workspace Talent Engine. Sin credenciales. Es la evidencia contra la que scripts/check-taxonomy-parity.sh valida label-taxonomy.json y talent-engine-config.json. Regenerar: bash scripts/check-taxonomy-parity.sh --live --emit-receipt (escritura atómica sobre este archivo — jamás redirigir salida aquí); revisar el diff en git y re-correr el gate sin flags." \
      --arg date "$(date -I)" \
      --argjson pages "$PAGES" \
      --slurpfile labels "$TMPD/live.json" \
      '{"_description": $desc, generated_at: $date, workspace: "Talent Engine",
        query: "query($after:String){ issueLabels(first:100, after:$after){ pageInfo{hasNextPage endCursor} nodes{ id name team{ key } } } }",
        pagination: { pages: $pages, page_size: 100, complete: true },
        total: ($labels[0] | length), labels: $labels[0] }' > "$RECEIPT_TMP" \
      || { rm -f "$RECEIPT_TMP"; echo "ERROR: fallo construyendo el recibo nuevo (original intacto)" >&2; exit 2; }
    jq -e '.pagination.complete == true and (.labels | length) == .total and .total > 0' \
        "$RECEIPT_TMP" >/dev/null 2>&1 \
      || { rm -f "$RECEIPT_TMP"; echo "ERROR: el recibo nuevo no valida (original intacto)" >&2; exit 2; }
    mv -f "$RECEIPT_TMP" "$RECEIPT"
    echo "emit-receipt: recibo reescrito atómicamente en $RECEIPT — revisar el diff en git y re-correr el gate sin flags" >&2
    exit 0
  fi
  jq '[.labels[] | {id, name, team}] | sort_by(.name, .team)' "$RECEIPT" > "$TMPD/receipt-set.json"
  check
  if diff -u "$TMPD/receipt-set.json" "$TMPD/live.json" > "$TMPD/drift.diff" 2>&1; then
    pass "live: recibo == API viva ($(jq 'length' "$TMPD/live.json") labels)"
  else
    fail "live: DRIFT recibo vs API viva — regenerar el recibo conscientemente y re-validar:"
    cat "$TMPD/drift.diff"
  fi
fi

# ── Sets base ─────────────────────────────────────────────────────────────────
jq -r '.labels[].name' "$RECEIPT" | sort -u > "$TMPD/receipt-names.txt"
jq -r '.groups[].items[].name' "$TAXONOMY" | sort > "$TMPD/tax-names.txt"
sort -u "$TMPD/tax-names.txt" > "$TMPD/tax-names-u.txt"
check
if diff -q "$TMPD/tax-names.txt" "$TMPD/tax-names-u.txt" >/dev/null 2>&1; then
  pass "autoridad: sin nombres duplicados internos"
else
  fail "autoridad: nombres repetidos dentro de label-taxonomy.json"
fi

# 1) Todo nombre de la autoridad existe en el recibo
check
MISSING="$(comm -23 "$TMPD/tax-names-u.txt" "$TMPD/receipt-names.txt")"
if [ -z "$MISSING" ]; then
  pass "autoridad ⊆ recibo (todo nombre publicado existe en Linear)"
else
  fail "autoridad publica nombres INEXISTENTES en el recibo:"
  printf '%s\n' "$MISSING"
fi

# 2) Paridad bidireccional por familia del contrato (vertical/ · kind: · sev:)
for fam in "vertical/" "kind:" "sev:"; do
  check
  grep -F "$fam" "$TMPD/receipt-names.txt" > "$TMPD/fam-receipt.txt" || : > "$TMPD/fam-receipt.txt"
  grep -F "$fam" "$TMPD/tax-names-u.txt" > "$TMPD/fam-tax.txt" || : > "$TMPD/fam-tax.txt"
  if [ ! -s "$TMPD/fam-receipt.txt" ]; then
    fail "familia $fam: vacía en el recibo (¿consulta incompleta?)"
    continue
  fi
  if diff -q "$TMPD/fam-receipt.txt" "$TMPD/fam-tax.txt" >/dev/null 2>&1; then
    pass "familia $fam: paridad recibo == autoridad ($(wc -l < "$TMPD/fam-receipt.txt") nombres)"
  else
    fail "familia $fam: paridad rota recibo vs autoridad:"
    diff -u "$TMPD/fam-receipt.txt" "$TMPD/fam-tax.txt" || true
  fi
done

# 3) Namespaces muertos prohibidos en la autoridad
check
DEAD="$(grep -E '^(type/|risk/)|(^|[^a-z])area/' "$TMPD/tax-names-u.txt")" || DEAD=""
if [ -z "$DEAD" ]; then
  pass "autoridad: sin namespaces muertos (type/ · risk/ · area/ con barra)"
else
  fail "autoridad publica namespaces muertos:"
  printf '%s\n' "$DEAD"
fi

# 4) Proyección (config.labels): cada entry contra recibo + autoridad
jq -c '.labels | to_entries[] | select(.key != "_comment") | .value[]' "$CONFIG" > "$TMPD/proj.jsonl"
[ -s "$TMPD/proj.jsonl" ] || { echo "ERROR: config sin bloque labels proyectable" >&2; exit 2; }
while IFS= read -r entry; do
  name="$(jq -r '.name' <<< "$entry")"
  pid="$(jq -r '.id // "null"' <<< "$entry")"
  check
  if ! grep -Fxq "$name" "$TMPD/tax-names-u.txt"; then
    fail "proyección: '$name' no está en la autoridad (segunda taxonomía prohibida)"
    continue
  fi
  jq --arg n "$name" '[.labels[] | select(.name == $n)]' "$RECEIPT" > "$TMPD/sites.json"
  count="$(jq 'length' "$TMPD/sites.json")"
  if [ "$count" -eq 0 ]; then
    fail "proyección: '$name' sin label vivo en el recibo"
  elif [ "$count" -eq 1 ]; then
    rid="$(jq -r '.[0].id' "$TMPD/sites.json")"
    if [ "$pid" = "$rid" ]; then
      pass "proyección: '$name' → UUID correcto"
    else
      fail "proyección: '$name' con id '$pid' ≠ recibo '$rid'"
    fi
  else
    want_sites="$(jq -c '[.[] | {key: (.team // "WORKSPACE"), value: .id}] | from_entries | to_entries | sort_by(.key)' "$TMPD/sites.json")"
    have_sites="$(jq -c '(.duplicate_sites // {}) | to_entries | sort_by(.key)' <<< "$entry")"
    if [ "$pid" = "null" ] && [ "$want_sites" = "$have_sites" ]; then
      pass "proyección: '$name' duplicado (${count}) → id null + sites exactos (fail-closed)"
    else
      fail "proyección: '$name' tiene multiplicidad $count — exige id null + duplicate_sites exactos (tiene id='$pid', sites=$have_sites, esperado=$want_sites)"
    fi
  fi
done < "$TMPD/proj.jsonl"

# 5) Proyección completa: ningún nombre de la autoridad falta en config
jq -r '.labels | to_entries[] | select(.key != "_comment") | .value[].name' "$CONFIG" | sort -u > "$TMPD/proj-names.txt"
check
UNPROJECTED="$(comm -23 "$TMPD/tax-names-u.txt" "$TMPD/proj-names.txt")"
if [ -z "$UNPROJECTED" ]; then
  pass "proyección completa: config cubre todos los nombres de la autoridad"
else
  fail "proyección incompleta: nombres de la autoridad ausentes en config:"
  printf '%s\n' "$UNPROJECTED"
fi

# 5b) Paridad POR GRUPO autoridad↔proyección (un nombre movido de grupo no debe pasar)
jq -r '.groups | keys[]' "$TAXONOMY" | sort > "$TMPD/tax-groups.txt"
jq -r '.labels | to_entries[] | select(.key != "_comment") | .key' "$CONFIG" | sort > "$TMPD/proj-groups.txt"
check
if diff -q "$TMPD/tax-groups.txt" "$TMPD/proj-groups.txt" >/dev/null 2>&1; then
  pass "grupos: mismo set de grupos en autoridad y proyección"
else
  fail "grupos: sets distintos autoridad vs proyección:"
  diff -u "$TMPD/tax-groups.txt" "$TMPD/proj-groups.txt" || true
fi
while IFS= read -r grp; do
  check
  jq -r --arg g "$grp" '.groups[$g].items[].name' "$TAXONOMY" | sort > "$TMPD/g-tax.txt"
  jq -r --arg g "$grp" '.labels[$g] // [] | .[].name' "$CONFIG" | sort > "$TMPD/g-proj.txt"
  if diff -q "$TMPD/g-tax.txt" "$TMPD/g-proj.txt" >/dev/null 2>&1; then
    pass "grupo '$grp': mismos nombres en autoridad y proyección ($(wc -l < "$TMPD/g-tax.txt"))"
  else
    fail "grupo '$grp': nombres distintos autoridad vs proyección:"
    diff -u "$TMPD/g-tax.txt" "$TMPD/g-proj.txt" || true
  fi
done < "$TMPD/tax-groups.txt"

# 6) Sin placeholders en el bloque labels
check
if jq -e '[.labels | to_entries[] | select(.key != "_comment") | .value[] | .id // ""] | any(test("fill-in"))' "$CONFIG" >/dev/null 2>&1; then
  fail "proyección: quedan placeholders <fill-in> en el bloque labels"
else
  pass "proyección: sin placeholders en el bloque labels"
fi

# 7) Labels de selección de agentes existen en el recibo
check
AGENT_BAD=0
while IFS= read -r lbl; do
  if ! grep -Fxq "$lbl" "$TMPD/receipt-names.txt"; then
    fail "agents: label de selección '$lbl' no existe en el recibo"
    AGENT_BAD=1
  fi
done < <(jq -r '.agents | to_entries[] | select(.key != "_comment") | .value.labels_for_workflow_selection // [] | .[]' "$CONFIG")
[ "$AGENT_BAD" -eq 0 ] && pass "agents: labels de selección vivos en el recibo"

# ── Veredicto ─────────────────────────────────────────────────────────────────
[ "$CHECKS" -gt 0 ] || { echo "ERROR: cero checks evaluados" >&2; exit 2; }
echo "== check-taxonomy-parity · modo=$MODE · checks=$CHECKS · fails=$FAILS =="
if [ "$FAILS" -eq 0 ]; then
  echo "VEREDICTO: PASS (rc=0)"
  exit 0
fi
echo "VEREDICTO: FAIL (rc=1)"
exit 1
