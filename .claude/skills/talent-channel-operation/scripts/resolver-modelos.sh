#!/usr/bin/env bash
# Resuelve ambos alias con la sesión acreditada del usuario; commit atómico del par.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-modelos.sh
. "$HERE/lib-modelos.sh"
# shellcheck source=lib-respuesta-cli.sh
. "$HERE/lib-respuesta-cli.sh"
[ $# -eq 0 ] || { echo 'uso: resolver-modelos.sh' >&2; exit 2; }
dest="$(tco_modelos_path)"
case "$dest" in /*) : ;; *) tco_modelos_error; exit 1 ;; esac
dir="${dest%/*}"
[ ! -L "$dir" ] && [ ! -L "$dest" ] || { tco_modelos_error; exit 1; }
install -d -m 700 "$dir"
[ ! -L "$dir/modelos.lock" ] || exit 1
exec {lock}>"$dir/modelos.lock"
flock -x "$lock"
tmp="$(mktemp "$dir/.modelos.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
chmod 600 "$tmp"
version="$(claude --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
for family in opus sonnet; do
  json="$(timeout 60 claude -p 'Responde solo: OK' --model "$family" --output-format json 2>/dev/null)" || { echo "ERROR resolviendo $family" >&2; exit 1; }
  cli_respuesta_exito <<< "$json" || { echo "ERROR respuesta de resolución $family" >&2; exit 1; }
  model="$(jq -er --arg family "$family" '
    .modelUsage | select(type == "object" and length == 1) | keys[0] |
    select(test("^claude-" + $family + "-[0-9]+([.-][a-z0-9]+)*$"))' <<< "$json")" || { echo "ERROR respuesta de resolución $family" >&2; exit 1; }
  alias_re="$(tco_modelo_picker_alias "$model")" || { echo "ERROR versión visible de $family" >&2; exit 1; }
  printf '%s_MODEL="%s"\n' "${family^^}" "$model" >> "$tmp"
  printf '%s_PICKER_ALIAS="%s"\n' "${family^^}" "$alias_re" >> "$tmp"
done
printf 'RESOLVED_UTC="%s"\nCLI_VERSION="%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$version" >> "$tmp"
tco_modelos_read "$tmp"
mv -f "$tmp" "$dest"
printf 'RESUELTO %s %s CLI=%s\n' "$TCO_OPUS_VIGENTE" "$TCO_SONNET_VIGENTE" "$version"
