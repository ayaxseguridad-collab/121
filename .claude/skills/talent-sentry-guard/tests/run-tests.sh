#!/usr/bin/env bash
# Runner de la skill; las siguientes piezas añaden aquí su prueba concreta.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
python3 "$HERE/test-resolver-ficha.py"
python3 "$HERE/test-github-seguridad.py"; python3 "$HERE/test-secretos-github.py"; bash "$HERE/test-doctor-github.sh"
python3 "$HERE/test-triage-paginacion.py"; bash "$HERE/test-parte-guardia.sh"
