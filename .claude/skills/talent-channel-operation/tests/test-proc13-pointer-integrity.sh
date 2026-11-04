#!/usr/bin/env bash
# test-proc13-pointer-integrity.sh — TAL-5643: guard offline y determinista de los tres
# punteros normativos que quedaron apuntando a PROC-13 tras su traslado a `talent-merger`
# como PROC-M13 (Fábrica v2, ADR-0043). Verifica ficheros REALES del repo (no fixtures/mocks
# — esto es integridad de prosa/documentación, no comportamiento de un sujeto ejecutable).
#
# Casos:
#   (1) scripts/preflight-issue.sh ya NO cita "anexo PROC-13 §5" (destino movido a
#       talent-merger, PROC-M13 "Paso 5") — y SÍ cita el destino real.
#   (2) scripts/preflight-issue.sh ya NO cita "anexo PROC-13 §2" — y SÍ cita "Paso 2".
#   (3) scripts/00-config.sh ya NO afirma que el post-merge de migraciones lo ejecuta el
#       COORDINADOR citando PROC-13 — el actor real es el MERGEADOR (Fábrica v2; el
#       CHANGELOG del propio traslado dice "cambia el actor, no la mecánica").
#   (4) el anexo adjudicado de talent-merger (`TCO_ANEXO_FILE`) reconcilia su lista de
#       referencias externas que preserva el nombre "Paso 2": preflight-issue.sh entra en
#       esa lista (antes solo citaba 06-migraciones-y-slots.md y 08-gates-locales.md).
#
# Uso: bash tests/test-proc13-pointer-integrity.sh   (exit 0 = todos los casos OK)
set -uo pipefail
export TF_PAQUETE_ESTADO=distribucion
if [ $# -gt 0 ]; then
  [ $# -eq 2 ] && [ "$1" = --estado ] || exit 2
  export TF_PAQUETE_ESTADO="$2"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$HERE/../scripts"
PREFLIGHT="$SC/preflight-issue.sh"
CONFIG="$SC/00-config.sh"
# El anexo del Mergeador es un OVERLAY por repo: se localiza RELATIVO al skill (vale en el árbol del
# paquete y en .claude/skills) — la distribución no lo trae. El estado se DECLARA (TF_PAQUETE_ESTADO=distribucion|
# instancia): esta suite fija distribución y admite --estado instancia para evaluar el anexo adjudicado.
MERGER_ANEXO=''
case "${TF_PAQUETE_ESTADO:-instancia}" in
  distribucion) EN_INSTANCIA=no ;;
  instancia)    EN_INSTANCIA=yes ;;
  *) echo "FAIL: TF_PAQUETE_ESTADO inválido (${TF_PAQUETE_ESTADO}): distribucion|instancia"; exit 2 ;;
esac
SKIPS=0
if [ "$EN_INSTANCIA" = yes ]; then
  # shellcheck source=/dev/null
  . "$HERE/../../skill-creator/scripts/lib-package.sh"
  pkg_parse_identity_conf "$SC/repo-identity.conf" || exit 2
  case "$PKGID_TCO_REPO_STACK" in
    supabase) : ;;
    ninguno|convex) EN_INSTANCIA=no; STACK_NO_APLICA="$PKGID_TCO_REPO_STACK" ;;
    *) echo "FAIL: TCO_REPO_STACK fuera del enum supabase|convex|ninguno ($PKGID_TCO_REPO_STACK)"; exit 2 ;;
  esac
  if [ "$EN_INSTANCIA" = yes ]; then
  case "$PKGID_TCO_ANEXO_FILE" in references/anexo-*.md) : ;; *) exit 2 ;; esac
  printf '%s' "$PKGID_TCO_ANEXO_FILE" | grep -Eq '(^|/)\.\.?(/|$)' && { echo 'FAIL: anexo adjudicado con componente ./..'; exit 2; }
  MERGER_ANEXO="$HERE/../../talent-merger/$PKGID_TCO_ANEXO_FILE"
  [ ! -L "$MERGER_ANEXO" ] || { echo 'FAIL: anexo adjudicado symlink'; exit 2; }
  MERGER_REAL="$(realpath -e -- "$HERE/../../talent-merger")" || exit 2
  ANEXO_REAL="$(realpath -e -- "$MERGER_ANEXO")" || exit 2
  case "$ANEXO_REAL" in "$MERGER_REAL"/*) : ;; *) echo 'FAIL: anexo fuera del skill'; exit 2 ;; esac
  fi
fi

for f in "$PREFLIGHT" "$CONFIG"; do
  [ -f "$f" ] || { echo "FAIL: no encuentro $f"; exit 2; }
done
[ "$EN_INSTANCIA" = yes ] && { [ -f "$MERGER_ANEXO" ] || { echo "FAIL: instancia sin $MERGER_ANEXO"; exit 2; }; }

fails=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1" >&2; fails=$((fails + 1)); }

echo "== TAL-5643: integridad de los punteros PROC-13 → PROC-M13 =="

# ── Caso (1): preflight-issue.sh, cita de "Paso 5" ──────────────────────────────────────
if grep -qE 'anexo PROC-13 §5' "$PREFLIGHT"; then
  fail "(1) $PREFLIGHT sigue citando el puntero muerto 'anexo PROC-13 §5'"
elif grep -qE 'PROC-M13.*Paso 5' "$PREFLIGHT"; then
  pass "(1) $PREFLIGHT cita el destino real (talent-merger, PROC-M13 \"Paso 5\"), sin el puntero muerto"
else
  fail "(1) $PREFLIGHT ya no cita el puntero muerto pero tampoco cita el destino real esperado — revisar redacción"
fi

# ── Caso (2): preflight-issue.sh, cita de "Paso 2" ──────────────────────────────────────
if grep -qE 'anexo PROC-13 §2' "$PREFLIGHT"; then
  fail "(2) $PREFLIGHT sigue citando el puntero muerto 'anexo PROC-13 §2'"
elif grep -qE 'PROC-M13.*Paso 2' "$PREFLIGHT"; then
  pass "(2) $PREFLIGHT cita el destino real (talent-merger, PROC-M13 \"Paso 2\"), sin el puntero muerto"
else
  fail "(2) $PREFLIGHT ya no cita el puntero muerto pero tampoco cita el destino real esperado — revisar redacción"
fi

# ── Caso (3), el que importa — EL ACTOR: 00-config.sh no debe atribuir el post-merge de
# migraciones al COORDINADOR citando PROC-13. Este es el caso "rojo por delante": HOY
# (antes del fix) este caso debe FALLAR — si no falla contra el árbol sin arreglar, el
# arnés está mudo y no acredita nada. ──────────────────────────────────────────────────
if grep -qE 'COORDINADOR \(regla 24 / PROC-13' "$CONFIG"; then
  fail "(3) $CONFIG sigue atribuyendo el post-merge de migraciones al COORDINADOR citando PROC-13 (actor equivocado, contradice el CHANGELOG del traslado: 'cambia el actor, no la mecánica')"
elif grep -qE 'MERGEADOR' "$CONFIG"; then
  pass "(3) $CONFIG atribuye el post-merge de migraciones al MERGEADOR (actor correcto, Fábrica v2)"
else
  fail "(3) $CONFIG ya no cita al COORDINADOR pero tampoco al MERGEADOR — revisar redacción"
fi

# ── Caso (4): reconciliación de la lista de referencias del anexo de talent-merger ──────
# La lista existe HOY (línea ~116-117) citando 06-migraciones-y-slots.md y
# 08-gates-locales.md como los consumidores externos de la etiqueta "Paso 2". Debe INCLUIR
# también a preflight-issue.sh (de talent-channel-operation) tras esta pieza.
if [ -n "${STACK_NO_APLICA:-}" ]; then
  echo "  SKIP (4): PROC-M13 no aplica al stack $STACK_NO_APLICA"; SKIPS=$((SKIPS + 1))
elif [ "$EN_INSTANCIA" = no ]; then
  echo "  SKIP-OVERLAY  (4) distribución (TF_PAQUETE_ESTADO=distribucion): sin anexo del Mergeador (overlay por repo) — caso no evaluable aquí"; SKIPS=$((SKIPS + 1))
elif grep -qE 'preflight-issue\.sh' "$MERGER_ANEXO"; then
  pass "(4) $MERGER_ANEXO reconcilia su lista de referencias externas de \"Paso 2\": incluye preflight-issue.sh"
else
  fail "(4) $MERGER_ANEXO NO incluye preflight-issue.sh en su lista de referencias externas que preserva \"Paso 2\" — lista sin reconciliar (afirma preservar lo que no preserva)"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "[test-proc13-pointer-integrity] TODOS los casos evaluados OK (SKIP-OVERLAY declarados: $SKIPS)"
  exit 0
fi
echo "[test-proc13-pointer-integrity] $fails caso(s) FALLARON" >&2
exit 1
