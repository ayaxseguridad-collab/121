#!/usr/bin/env bash
# Aplica la línea base resuelta antes del primer arranque; no toca sesiones.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-modelos.sh
. "$HERE/lib-modelos.sh"
[ $# -eq 2 ] || { echo 'uso: preparar-modelo-canal.sh <contenedor> <usuario>' >&2; exit 2; }
[[ $1 =~ ^[A-Za-z0-9._-]+$ ]] && [[ $2 =~ ^[a-z_][a-z0-9_-]*$ ]] || exit 2
model="$(tco_modelo_read coding)" && [ -n "$model" ] || exit 1
incus exec "$1" -- su - "$2" -c '
  set -e
  mkdir -p "$HOME/.claude"
  [ ! -L "$HOME/.claude/settings.json" ] || exit 1
  tmp=$(mktemp "$HOME/.claude/.model.XXXXXX")
  trap '\''rm -f "$tmp"'\'' EXIT
  if [ -f "$HOME/.claude/settings.json" ]; then
    jq -s -e --arg m "$1" "if length == 1 and (.[0] | type == \"object\") then .[0] | .model = \$m else error(\"configuración JSON inválida\") end" "$HOME/.claude/settings.json" > "$tmp"
  else
    jq -n --arg m "$1" "{model: \$m}" > "$tmp"
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$HOME/.claude/settings.json"
  jq -s -e --arg m "$1" "length == 1 and (.[0] | type == \"object\" and .model == \$m)" "$HOME/.claude/settings.json" >/dev/null
' _ "$model"
tco_modelo_guardar_fase "$1" "$2" "${TCO_TMUX:-v}:.0" "$model"
