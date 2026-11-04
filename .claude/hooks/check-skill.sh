#!/usr/bin/env bash
# Recordatorio de consultar el skill antes de editar un fichero.
set -euo pipefail
file="$(jq -er '.tool_input.file_path' )"
[ -n "$file" ] || exit 1
printf '%s\n' 'Consulte el skill del dominio y las reglas del producto antes de editar.'
