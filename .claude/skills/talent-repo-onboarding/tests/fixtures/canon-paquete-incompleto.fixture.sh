#!/usr/bin/env bash
# CASO: exit 2 (ERROR) — el paquete de fábrica al que apunta TRO_CANON_PACKAGE_DIR no trae un fichero del mapa (TAL-8037)
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

# Paquete sintético construido desde el espejo (idéntico al canon) con el mapa canon-paquete.tsv...
PKG="$(mktemp -d)"; trap 'rm -rf "$PKG"; cleanup_espejo' EXIT
while IFS=$'\t' read -r prod rel; do
  case "$prod" in '#'*|'') continue ;; esac
  mkdir -p "$PKG/$(dirname "$rel")"; cp -- "$ESPEJO_DIR/$prod" "$PKG/$rel"
done < "$CANON_MAP_FILE"
# ...al que le falta UN artefacto del mapa
rm -f "$PKG/githooks/pre-push"
unset TRO_CANON_REPO_DIR TRO_CANON_REF
export TRO_CANON_PACKAGE_DIR="$PKG"
espejo_commit
run_check 2
