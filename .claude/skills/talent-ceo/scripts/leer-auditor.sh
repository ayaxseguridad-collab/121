#!/usr/bin/env bash
# Consulta de solo lectura: comparte la acreditación de ruta real del despacho.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../talent-channel-operation/scripts/lib.sh"
[ "$#" -eq 4 ] || exit 2
contenedor="$1"; pane="$2"; TCO_CUSER="$3"; cli="$4"
tco_valid_token "$contenedor" && tco_valid_token "$TCO_CUSER" || exit 2
# El perfil declara el contenedor; no se deriva de un prefijo de carriles.
tco_container() { printf '%s\n' "$contenedor"; }
_tco_pane_agent_exes diagnostico "$pane" "$cli"
