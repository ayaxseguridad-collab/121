#!/usr/bin/env bash
# approve-merge.sh — [B5] Registra el OK HUMANO de merge de forma TRAZABLE por PR+SHA.
# Crea $SECRET_DIR/approvals/<pr>-<sha>.ok (con quién/cuándo). merge-gate.sh lo lee; ningún
# env global aprueba. Si el headSha del PR cambia (rebase), la aprobación vieja deja de valer.
# Uso: approve-merge.sh <pr> <sha>   |   approve-merge.sh --revoke <pr> <sha>
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"; . "$HERE/lib.sh"
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  REV=no; [ "${1:-}" = "--revoke" ] && { REV=yes; shift; }
  PR="${1:?uso: approve-merge.sh [--revoke] <pr> <sha>}"; SHA="${2:?sha}"
  # [CR] PR y SHA forman la ruta de aprobación ($SECRET_DIR/approvals/<pr>-<sha>.ok): validar
  # ANTES de usarlos — un '/' o '..' en los argumentos permitiría a --revoke borrar fuera del dir.
  [[ "$PR" =~ ^[0-9]+$ ]] || tco_die "pr inválido: $PR (número de PR)"
  [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || tco_die "sha inválido: $SHA (sha completo de 40 hex en minúsculas)"
  mkdir -p "$SECRET_DIR/approvals"
  f="$SECRET_DIR/approvals/$PR-$SHA.ok"
  # --revoke es una operación LOCAL (rm del approval): no necesita tokens — cargarlos antes
  # impediría limpiar aprobaciones stale cuando el env del host falta (tco_load_tokens falla).
  if [ "$REV" = yes ]; then rm -f "$f"; tco_info "aprobación revocada: PR #$PR @ $SHA"; exit 0; fi
  tco_load_tokens
  # confirmar que el SHA es el head ACTUAL del PR (apruebas exactamente lo auditado)
  head="$(gh pr view "$PR" --repo "$TCO_REPO_SLUG" --json headRefOid --jq '.headRefOid' 2>/dev/null || echo '')"
  [ "$head" = "$SHA" ] || tco_die "el head actual del PR #$PR es '$head', no '$SHA' — re-auditar y aprobar el SHA vigente."
  printf 'approved_by=%s at=%s pr=%s sha=%s\n' "${HOST_USER:-?}" "$(date -u +%FT%TZ)" "$PR" "$SHA" > "$f"
  chmod 600 "$f"
  tco_info "✅ OK de merge registrado: PR #$PR @ $SHA (trazable en $f)"
fi
