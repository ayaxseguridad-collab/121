#!/usr/bin/env bash
# CASO: exit 1 (FAIL) — el repo auditado difiere en bytes del canon del PAQUETE (un IDENTICO alterado en el paquete) (TAL-8037)
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

PKG="$(mktemp -d)"; trap 'rm -rf "$PKG"; cleanup_espejo' EXIT
while IFS=$'\t' read -r prod rel; do
  case "$prod" in '#'*|'') continue ;; esac
  mkdir -p "$PKG/$(dirname "$rel")"; cp -- "$ESPEJO_DIR/$prod" "$PKG/$rel"
done < "$CANON_MAP_FILE"
printf '# alterado en el paquete\n' >> "$PKG/scripts/audit-go.sh"     # el espejo (destino) ya NO coincide con el canon
unset TRO_CANON_REPO_DIR TRO_CANON_REF
export TRO_CANON_PACKAGE_DIR="$PKG"
espejo_commit
run_check 1
