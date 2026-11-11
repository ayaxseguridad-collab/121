#!/usr/bin/env bash
# Resuelve ambos alias con la sesión acreditada del usuario; commit atómico del par.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-modelos.sh
. "$HERE/lib-modelos.sh"
# shellcheck source=lib-respuesta-cli.sh
. "$HERE/lib-respuesta-cli.sh"
auditor=''
if [ $# -eq 2 ] && [ "$1" = --auditor ] && [ "$2" = codex ]; then auditor=codex
elif [ $# -ne 0 ]; then echo 'uso: resolver-modelos.sh [--auditor codex]' >&2; exit 2; fi
dest="$(tco_modelos_path)"
case "$dest" in /*) : ;; *) tco_modelos_error; exit 1 ;; esac
dir="${dest%/*}"
[ ! -L "$dir" ] && [ ! -L "$dest" ] || { tco_modelos_error; exit 1; }
install -d -m 700 "$dir"
[ ! -L "$dir/modelos.lock" ] || exit 1
exec {lock}>"$dir/modelos.lock"
flock -x "$lock"
declare -A previo=()
sol_necesario="$auditor"
if [ -e "$dest" ]; then
  if tco_modelos_read "$dest"; then
    while IFS= read -r line || [ -n "$line" ]; do
      [[ $line =~ ^([A-Z_]+)=\"([^\"]+)\"$ ]] || exit 1
      k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
      case "$k" in PLAN|CODE|CODE_SENSIBLE|AUDIT|AUDIT_EFFORT|MANDO_MODEL) previo[$k]="$v" ;; esac
      [ "$v" != codex:sol ] || sol_necesario=codex
    done < "$dest"
  else echo 'AVISO: registro previo inválido; se regenera' >&2; fi
fi
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
sol=''
if [ "$sol_necesario" = codex ]; then
  catalogo="$(timeout 60 codex debug models --bundled 2>/dev/null)" || { echo 'ERROR resolviendo sol' >&2; exit 1; }
  sol="$(jq -s -er '
    if length != 1 then error("catálogo múltiple") else .[0] end |
    [.models[] | select(.visibility == "list") | .slug |
      select(type == "string" and test("^gpt-[0-9]+(\\.[0-9]+)*-sol$") and (contains("\n") | not) and (contains("\r") | not))] |
    sort_by(ltrimstr("gpt-") | rtrimstr("-sol") | split(".") | map(tonumber)) |
    last | select(type == "string")' <<< "$catalogo")" || { echo 'ERROR resolviendo sol' >&2; exit 1; }
  printf 'SOL_MODEL="%s"\n' "$sol" >> "$tmp"
  previo[PLAN]="${previo[PLAN]:-claude:opus}"; previo[CODE]="${previo[CODE]:-claude:sonnet}"
  previo[CODE_SENSIBLE]="${previo[CODE_SENSIBLE]:-claude:opus}"; previo[AUDIT]="${previo[AUDIT]:-codex:sol}"
  previo[AUDIT_EFFORT]="${previo[AUDIT_EFFORT]:-medium}"
fi
for k in PLAN CODE CODE_SENSIBLE AUDIT AUDIT_EFFORT MANDO_MODEL; do
  [ -z "${previo[$k]:-}" ] || printf '%s="%s"\n' "$k" "${previo[$k]}" >> "$tmp"
done
printf 'RESOLVED_UTC="%s"\nCLI_VERSION="%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$version" >> "$tmp"
tco_modelos_read "$tmp"
mv -f "$tmp" "$dest"
printf 'RESUELTO %s %s CLI=%s%s\n' "$TCO_OPUS_VIGENTE" "$TCO_SONNET_VIGENTE" "$version" "${sol:+ SOL=$sol}"
