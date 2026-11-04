#!/usr/bin/env bash
# CASO: exit 2 (ERROR) — una fila IDENTICO del manifiesto no está cubierta por el mapa canon-paquete.tsv (fail-closed) (TAL-8037)
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

PKG="$(mktemp -d)"; MF="$(mktemp)"; trap 'rm -rf "$PKG" "$MF"; cleanup_espejo' EXIT
while IFS=$'\t' read -r prod rel; do
  case "$prod" in '#'*|'') continue ;; esac
  mkdir -p "$PKG/$(dirname "$rel")"; cp -- "$ESPEJO_DIR/$prod" "$PKG/$rel"
done < "$CANON_MAP_FILE"
cat "$SKILL_ROOT/assets/parity-manifest.tsv" > "$MF"
printf 'artefacto-nuevo\tIDENTICO\tscripts/no-mapeado.sh\t100755\thash|tipo|modo|exec\n' >> "$MF"
unset TRO_CANON_REPO_DIR TRO_CANON_REF
export TRO_CANON_PACKAGE_DIR="$PKG" TRO_MANIFEST="$MF"
espejo_commit
run_check 2
