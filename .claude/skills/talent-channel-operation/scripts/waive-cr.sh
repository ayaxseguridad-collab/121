#!/usr/bin/env bash
# waive-cr.sh — [v5/B1] Registra el WAIVER de la review de CodeRabbit (M8) de forma TRAZABLE por
# PR+headSha, tras el OK EXPLÍCITO del lead. Es la ÚNICA vía no-review que satisface M8 en
# merge-gate.sh: las señales débiles de CR (status check verde, comments, "Review skipped") son
# DIAGNÓSTICO y jamás aprueban por sí solas.
# Crea $SECRET_DIR/waivers/<pr>-<sha>.cr-waiver con evidencia LEGIBLE (quién/cuándo/PR/sha/motivo).
# Si el headSha del PR cambia (rebase/push), el waiver viejo deja de valer (atado al sha exacto).
# El gate imprime `M8=waived via=waiver motivo=…` — el waiver NUNCA colapsa a un `yes` silencioso.
# Uso: waive-cr.sh <pr> <sha> --reason "<motivo>"   |   waive-cr.sh --revoke <pr> <sha>
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"; . "$HERE/lib.sh"
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  REV=no; [ "${1:-}" = "--revoke" ] && { REV=yes; shift; }
  PR="${1:?uso: waive-cr.sh [--revoke] <pr> <sha> [--reason \"<motivo>\"]}"; SHA="${2:?sha}"; shift 2
  REASON=""
  while [ $# -gt 0 ]; do case "$1" in --reason) REASON="${2:?--reason exige un motivo}"; shift 2;; *) tco_die "argumento desconocido: $1";; esac; done
  # [CR] PR y SHA forman la ruta del waiver: validar ANTES de usarlos (mismo fail-closed que approve-merge).
  [[ "$PR" =~ ^[0-9]+$ ]] || tco_die "pr inválido: $PR (número de PR)"
  [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || tco_die "sha inválido: $SHA (sha completo de 40 hex en minúsculas)"
  mkdir -p "$SECRET_DIR/waivers"
  f="$SECRET_DIR/waivers/$PR-$SHA.cr-waiver"
  if [ "$REV" = yes ]; then rm -f "$f"; tco_info "waiver CR revocado: PR #$PR @ $SHA"; exit 0; fi
  # [B1] SIN motivo NO hay waiver: la trazabilidad del "por qué" es parte del artefacto, no opcional.
  [ -n "$REASON" ] || tco_die "falta --reason \"<motivo>\" — un waiver sin motivo registrado no es trazable (no se emite)"
  # [CR #790 Major] el motivo se persiste como `reason=<REASON>` (key=value): un \n o \r partiría el
  # artefacto en líneas falsas y haría el waiver ambiguo/no-trazable. Rechazar cualquier multilínea.
  case "$REASON" in *$'\n'*|*$'\r'*) tco_die "el motivo del waiver debe ser UNA sola línea (sin saltos de línea ni CR) — trazabilidad del artefacto key=value";; esac
  tco_load_tokens
  # confirmar que el SHA es el head ACTUAL del PR (el waiver cubre exactamente lo que se mergeará)
  head="$(gh pr view "$PR" --repo "$TCO_REPO_SLUG" --json headRefOid --jq '.headRefOid' 2>/dev/null || echo '')"
  [ "$head" = "$SHA" ] || tco_die "el head actual del PR #$PR es '$head', no '$SHA' — el waiver se emite sobre el sha vigente."
  printf 'waived_by=%s at=%s pr=%s sha=%s\nreason=%s\n' "${HOST_USER:-?}" "$(date -u +%FT%TZ)" "$PR" "$SHA" "$REASON" > "$f"
  chmod 600 "$f"
  tco_info "⚠️  WAIVER CR registrado: PR #$PR @ $SHA — motivo: $REASON (trazable en $f)"
  tco_info "El merge-gate lo reportará como M8=waived via=waiver (nunca como review real)."
fi
