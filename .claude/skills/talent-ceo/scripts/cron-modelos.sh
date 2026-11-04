#!/usr/bin/env bash
# Emite la fila semanal de cada usuario del rol; no modifica crontab.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  --linea) [ $# -eq 1 ] || exit 2 ;;
  *) echo 'uso: cron-modelos.sh --linea (TA_ROL, TA_BUS y TA_PERFIL requeridos)' >&2; exit 2 ;;
esac
[[ ${TA_ROL:-} =~ ^[A-Za-z0-9_-]{1,32}$ ]] || exit 2
for value in "${TA_BUS:-}" "${TA_PERFIL:-}" "$HERE"; do
  case "$value" in /*) : ;; *) echo 'ERROR cron: rutas absolutas requeridas' >&2; exit 2 ;; esac
  case "$value" in *%*|*[[:cntrl:]]*) echo 'ERROR cron: carácter no permitido en ruta' >&2; exit 2 ;; esac
done
printf -v command '[ ! -f "$HOME/.claude_token.env" ] || . "$HOME/.claude_token.env"; exec bash %q --ejecutar' "$HERE/../../talent-channel-operation/scripts/actualizar-modelos.sh"
printf 'SHELL=/bin/bash\n17 3 * * 0 TA_ROL=%q TA_BUS=%q TA_PERFIL=%q bash -lc %q # modelos-rodantes\n' "$TA_ROL" "$TA_BUS" "$TA_PERFIL" "$command"
