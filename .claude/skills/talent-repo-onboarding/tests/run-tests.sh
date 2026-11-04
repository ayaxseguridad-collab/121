#!/usr/bin/env bash
# run-tests.sh — Corre los 46 casos sellados del skill talent-repo-onboarding (23 + 8 de TAL-8037: canon del paquete y clave Linear + 8 de TAL-8040: .gitignore + 7 de la issue 9011: lectura estable de A2/A2b en vivo, con un gh doble y reloj simulado).
#
# USO:
#   bash .claude/skills/talent-repo-onboarding/tests/run-tests.sh [CANON_DIR]
#
#   CANON_DIR  OVERRIDE git: repo canónico con el que se compara (default: NINGUNO — el canon sale del PROPIO
#              paquete de fábrica, sin git y sin checkout de casa; TAL-8037). Si el skill no vive en un árbol
#              de paquete, default histórico: 4 niveles por encima del script (repo TA raíz).
#
# EXIT:
#   0  Todos los casos pasaron.
#   1  Uno o más casos fallaron.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
export CANON_REF="${CANON_REF:-HEAD}"
SKILL_ROOT_T="$(cd "$SCRIPT_DIR/.." && pwd)"; PKG_ROOT_T="$(cd "$SKILL_ROOT_T/../.." && pwd)"
if [ -n "${1:-}" ]; then
  export CANON_MODE=git CANON_DIR="$1"                       # override explícito (checkout git del canon)
elif [ -f "$PKG_ROOT_T/githooks/pre-push" ] && [ -f "$PKG_ROOT_T/scripts/verify-handoff.sh" ]; then
  export CANON_MODE=paquete CANON_PKG_DIR="$PKG_ROOT_T"      # el canon sale del PROPIO paquete (TAL-8037)
else
  export CANON_MODE=git CANON_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"   # default histórico
fi

# Modo git: el repo canónico debe existir y tener git. Modo paquete: el árbol del paquete y el mapa deben estar completos.
if [ "$CANON_MODE" = git ] && ! git -C "$CANON_DIR" rev-parse HEAD >/dev/null 2>&1; then
  printf '[ERROR] CANON_DIR no es un repo git: %s\n' "$CANON_DIR" >&2
  exit 2
fi
printf '── canon: modo %s (%s)\n' "$CANON_MODE" "${CANON_PKG_DIR:-$CANON_DIR}"

# Verificar dependencias del runner
for dep in git jq sha256sum shasum; do
  if command -v "$dep" >/dev/null 2>&1; then break 2 2>/dev/null; fi
done
for dep in git jq; do
  command -v "$dep" >/dev/null 2>&1 || { printf '[ERROR] dep faltante: %s\n' "$dep" >&2; exit 2; }
done
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
  printf '[ERROR] dep faltante: sha256sum / shasum\n' >&2; exit 2
fi

# Casos sellados (nombre → exit esperado)
declare -A CASES=(
  ["archivo-vacio"]=1
  ["sentinel-alterado"]=1
  ["gitignore-dos-de-tres"]=1
  ["gitignore-sin-tf-manifest"]=1
  ["gitignore-sin-motor-go"]=1
  ["gitignore-sin-comodin-cr-review"]=1
  ["gitignore-sin-draft-handoff"]=1
  ["gitignore-tf-manifest-negado"]=1
  ["gitignore-comodin-con-negacion-ok"]=1
  ["gitignore-negacion-previa-a-la-regla"]=0
  ["handoff-schema-distinto"]=1
  ["protection-sin-conversation-resolution"]=1
  ["dependencia-transitiva-ausente"]=1
  ["pre-push-modo-100644"]=1
  ["manifiesto-fila-duplicada"]=2
  ["enforce-admins-true"]=1
  ["settings-json-ausente"]=1
  ["hook-sin-cablear"]=1
  ["hookspath-vacio"]=1
  ["perfil-ausente"]=1
  ["closes-eng-con-key-tal"]=1
  ["receipt-stale"]=3
  ["receipt-otro-repo"]=3
  ["receipt-actor-desconocido"]=3
  ["receipt-evidencia-opaca"]=3
  ["receipt-ttl-excesivo"]=3
  ["receipt-recurso-inexistente"]=3
  ["receipt-issued-at-futuro"]=3
  ["attest-de-otro-check"]=3
  ["receipt-no-parseable"]=2
  ["positivo-espejo-completo"]=0
  ["sin-clave-linear"]=2
  ["clave-casa-con-clave-instancia"]=1
  ["clave-desde-manifiesto"]=0
  ["canon-paquete-incompleto"]=2
  ["canon-paquete-hash-difiere"]=1
  ["canon-paquete-mapa-incompleto"]=2
  ["hooks-extremo-a-extremo"]=0
  ["clave-multilinea"]=2
  ["lectura-estable-carrera"]=0
  ["lectura-estable-malos-estables"]=1
  ["lectura-estable-alterna"]=1
  ["lectura-estable-plan-pro"]=3
  ["lectura-estable-error-gh"]=2
  ["lectura-estable-no-parseable"]=1
  ["lectura-estable-stubs"]=0
)

TOTAL=0
PASSED=0
FAILED=0
FAILED_NAMES=()

for caso in \
  archivo-vacio sentinel-alterado gitignore-dos-de-tres gitignore-sin-tf-manifest \
  gitignore-sin-motor-go gitignore-sin-comodin-cr-review gitignore-sin-draft-handoff \
  gitignore-tf-manifest-negado gitignore-comodin-con-negacion-ok \
  gitignore-negacion-previa-a-la-regla handoff-schema-distinto \
  protection-sin-conversation-resolution dependencia-transitiva-ausente \
  pre-push-modo-100644 manifiesto-fila-duplicada enforce-admins-true \
  settings-json-ausente hook-sin-cablear hookspath-vacio perfil-ausente \
  closes-eng-con-key-tal receipt-stale receipt-otro-repo \
  receipt-actor-desconocido receipt-evidencia-opaca receipt-ttl-excesivo \
  receipt-recurso-inexistente receipt-issued-at-futuro attest-de-otro-check \
  receipt-no-parseable positivo-espejo-completo \
  sin-clave-linear clave-casa-con-clave-instancia clave-desde-manifiesto \
  canon-paquete-incompleto canon-paquete-hash-difiere canon-paquete-mapa-incompleto \
  hooks-extremo-a-extremo clave-multilinea \
  lectura-estable-carrera lectura-estable-malos-estables lectura-estable-alterna \
  lectura-estable-plan-pro lectura-estable-error-gh lectura-estable-no-parseable lectura-estable-stubs; do

  TOTAL=$(( TOTAL + 1 ))
  fixture="$FIXTURES_DIR/${caso}.fixture.sh"

  if [ ! -f "$fixture" ]; then
    printf '[MISS] %s — fixture no encontrado\n' "$caso"
    FAILED=$(( FAILED + 1 ))
    FAILED_NAMES+=("$caso")
    continue
  fi

  expected="${CASES[$caso]}"
  result=0
  out="$(bash "$fixture" 2>&1)" || result=$?

  # El fixture imprime PASS o FAIL; su propio exit code es 0/1
  if printf '%s' "$out" | command grep -q '^PASS:'; then
    printf '[OK]   %-45s expected=%d\n' "$caso" "$expected"
    PASSED=$(( PASSED + 1 ))
  else
    printf '[FAIL] %-45s expected=%d — %s\n' "$caso" "$expected" "$out"
    FAILED=$(( FAILED + 1 ))
    FAILED_NAMES+=("$caso")
  fi
done

printf '\n── Resultados: %d/%d OK' "$PASSED" "$TOTAL"
if [ "${#FAILED_NAMES[@]}" -gt 0 ]; then
  printf ' · Fallidos: %s' "${FAILED_NAMES[*]}"
fi
printf '\n'

[ "$FAILED" -eq 0 ]
