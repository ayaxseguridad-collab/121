#!/usr/bin/env bash
# capture-pane-fixtures.sh — captura el pane de un canal como FIXTURE de calibración (TAL-8042).
# Escribe tests/fixtures/pane/<cli>_<version>/<estado>.txt (ver tests/fixtures/pane/README.md).
# Se NIEGA a escribir si la captura contiene un secreto, una cuenta (correo) o una ruta personal
# (`tco_fixture_secret_scan`; nunca imprime el valor). Se escanea antes y después de normalizar.
# Uso:
#   capture-pane-fixtures.sh [--force] <idle|busy|modal|redraw> <carril> [pane]
#   capture-pane-fixtures.sh [--force] --from-stdin --cli-version <cli:version> <estado>   (captura por stdin)
# rc: 0 escrito · 2 uso · 3 captura rechazada por secretos/cuentas · 4 destino ya existe (usa --force) · 1 otro fallo
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  FORCE=no; FROM_STDIN=no; CLI_VERSION=""
  while :; do case "${1:-}" in
    --force) FORCE=yes; shift ;;
    --from-stdin) FROM_STDIN=yes; shift ;;
    --cli-version) CLI_VERSION="${2:-}"; shift 2 || true ;;
    *) break ;;
  esac; done
  STATE="${1:-}"
  case "$STATE" in idle|busy|modal|redraw) ;; *) printf 'uso: %s [--force] <idle|busy|modal|redraw> <carril> [pane] | --from-stdin --cli-version <cli:version> <estado>\n' "${0##*/}" >&2; exit 2 ;; esac
  if [ "$FROM_STDIN" = yes ]; then
    [ -n "$CLI_VERSION" ] || { tco_err "--from-stdin exige --cli-version <cli:version>"; exit 2; }
    cap="$(cat)"
  else
    CARRIL="${2:?carril}"; PANE="${3:-$(tco_pane_audit)}"
    tco_valid_token "$CARRIL" || { tco_err "carril inválido: $CARRIL"; exit 2; }
    CLI_VERSION="$(_tco_pane_cli_version "$CARRIL" "$PANE")" \
      || { tco_err "no pude resolver cli:versión del pane $PANE de $CARRIL (¿hay un agente en marcha?)"; exit 1; }
    cap="$(tco_cap_pane "$CARRIL" "$PANE")" || { tco_err "captura del pane $PANE de $CARRIL fallida"; exit 1; }
  fi
  printf '%s' "$CLI_VERSION" | grep -qE '^[A-Za-z0-9_.-]+:[A-Za-z0-9_.+-]+$' \
    || { tco_err "cli:versión '$CLI_VERSION' no válida (esperaba <cli>:<version>)"; exit 2; }
  [ -n "$cap" ] || { tco_err "captura vacía — no se escribe un fixture vacío"; exit 1; }
  # Rechazar la entrada original: normalizar nunca debe ocultar una ruta personal.
  if ! printf '%s\n' "$cap" | tco_fixture_secret_scan; then
    tco_err "captura ORIGINAL RECHAZADA: contiene secretos/cuentas/rutas personales — NO se escribió ningún fichero"
    exit 3
  fi
  cap="$(printf '%s\n' "$cap" | sed -E 's#(/home|/Users)/[A-Za-z0-9._-]+#\1/USER#g')"
  if ! printf '%s\n' "$cap" | tco_fixture_secret_scan; then
    tco_err "captura RECHAZADA: contiene secretos/cuentas — NO se escribió ningún fichero"
    exit 3
  fi
  if [ "$STATE" = redraw ]; then
    cap="$(printf '%s\n' "$cap" | tco_redraw_fixture_from)" || exit 1
  fi
  printf '%s\n' "$cap" | tco_fixture_secret_scan \
    || { tco_err 'resultado RECHAZADO por el escáner — NO se escribió ningún fichero'; exit 3; }
  dir="${TCO_FIXTURE_DIR:-$HERE/../tests/fixtures/pane}/${CLI_VERSION%%:*}_${CLI_VERSION#*:}"
  out="$dir/$STATE.txt"
  if [ -e "$out" ] && [ "$FORCE" != yes ]; then
    tco_err "$out ya existe (usa --force para reemplazarlo)"; exit 4
  fi
  mkdir -p "$dir"
  printf '%s\n' "$cap" > "$out"
  tco_info "fixture escrito: $out"
  for st in idle busy modal redraw; do [ -s "$dir/$st.txt" ] || tco_info "falta: $st.txt (el par ${CLI_VERSION} NO puede entrar en TCO_PANE_CALIBRATED hasta tener los 4)"; done
fi
