#!/usr/bin/env bash
# fake-incus.sh — shim de 'incus' para el arnés de auth-move (TAL-2294). NO es incus real:
# mapea los endpoints tipo contenedor a directorios locales bajo $AM_TEST_CROOT/<name>. Ejecuta
# los 'incus exec … bash -c CMD' / 'su - USER -c CMD' localmente (las rutas ya apuntan al sandbox
# porque am_ep_home usa AM_TEST_CROOT) y traduce 'incus file push/pull' a cp. Solo cubre las formas
# que auth-move-lib emite.
#
# ESCUDO HERMÉTICO (TAL-8042; origen TAL-5507): este shim ejecuta el payload SIN sandbox sobre el
# HOST real (las líneas `bash -c` de abajo) — rompe la premisa de aislamiento de PID que la
# quiescencia da por hecha para los endpoints channel/pool (en producción `incus exec` SÍ aísla). El
# 2026-10-03 la suite mató con `pgrep -u <usuario> … | kill -9` procesos reales de otras sesiones.
# Blindaje de ESTA capa (independiente del de la lib, "no confiar solo en uno"): dentro de todo
# payload `pgrep` y `kill` son funciones exportadas DEFAULT-DENY sobre una LISTA de PIDs creados por
# el propio test (`$AM_TEST_CROOT/.allowed-kill-pids`):
#   - `pgrep -u <usuario>` es la ÚNICA forma de enumeración admitida y devuelve solo la intersección
#     con la lista (nada registrado => nada visible => nada matable). rc 1 si la intersección es vacía.
#   - cualquier otra forma de pgrep se RECHAZA con rc 2 (nunca se delega al pgrep real: un rc 1 se
#     leería como "endpoint limpio" = quiescencia falsa; rc>1 es el contrato de ERROR de la lib).
#   - `kill` solo actúa sobre PIDs de la lista; con cualquier otro PID falla (rc 1) sin enviar nada.
#   - `AM_TEST_FORCE_PGREP_ERR` (seam explícito de test) fuerza rc 2 en pgrep: prueba al caller REAL.
set -uo pipefail
sub="${1:-}"; shift || true

# shellcheck disable=SC2016  # el shadow es TEXTO que se evalúa en el bash del payload, no aquí
_fake_incus_shadow='
_fi_allowed() {
  local f="${AM_TEST_CROOT:-}/.allowed-kill-pids" x
  [ -s "$f" ] || return 1
  while read -r x; do [ "$x" = "$1" ] && return 0; done < "$f"
  return 1
}
pgrep() {
  if [ -n "${AM_TEST_FORCE_PGREP_ERR:-}" ]; then
    echo "fake-incus pgrep-shadow: fallo forzado por seam de test (AM_TEST_FORCE_PGREP_ERR): pgrep $*" >&2
    return 2
  fi
  if [ "$#" -eq 2 ] && [ "$1" = "-u" ]; then
    local _real _rc _p _out=""
    _real="$(command pgrep -u "$2")"; _rc=$?
    [ "$_rc" -gt 1 ] && return "$_rc"
    for _p in $_real; do
      if _fi_allowed "$_p"; then _out="$_out$_p
"; fi
    done
    if [ -n "$_out" ]; then printf "%s" "$_out"; return 0; fi
    return 1
  fi
  echo "fake-incus pgrep-shadow: forma no reconocida, rechazada fail-closed (rc=2, no sin-matches): pgrep $*" >&2
  return 2
}
kill() {
  local _a _pids="" _sig=""
  for _a in "$@"; do
    case "$_a" in
      -9|-KILL|-SIGKILL|-0|-TERM|-15) _sig="$_a" ;;
      -*) echo "fake-incus kill-shadow: opcion no admitida ($_a)" >&2; return 1 ;;
      *) _pids="$_pids $_a" ;;
    esac
  done
  for _a in $_pids; do
    if ! _fi_allowed "$_a"; then
      echo "fake-incus kill-shadow: PID $_a NO creado por el test — rechazado (sin senal)" >&2
      return 1
    fi
  done
  [ -n "$_pids" ] || return 1
  # shellcheck disable=SC2086
  builtin kill ${_sig:+"$_sig"} $_pids
}
export -f _fi_allowed pgrep kill
'
# Ejecuta el payload con el shadow YA definido en el MISMO bash (concatenado por -c) y exportado
# (`export -f`) para que un `bash -c` anidado lo herede. "$@" reenvía los posicionales (forma
# `bash -c SCRIPT _ a b c` de tc_kill_wait).
_fake_incus_run_payload() { local script="$1"; shift; bash -c "$_fake_incus_shadow$script" "$@"; }

case "$sub" in
  info)
    [ -d "${AM_TEST_CROOT:?}/${1:?}" ] && exit 0 || exit 1 ;;
  exec)
    : "${1:?}"; shift
    [ "${1:-}" = "--" ] && shift
    case "${1:-}" in
      bash) shift; [ "${1:-}" = "-c" ] && { shift; _fake_incus_run_payload "$@"; exit $?; }; bash "$@"; exit $? ;;
      su)   shift; while [ $# -gt 0 ] && [ "$1" != "-c" ]; do shift; done
            [ "${1:-}" = "-c" ] && { shift; _fake_incus_run_payload "$@"; exit $?; }; exit 0 ;;
      test) shift; test "$@"; exit $? ;;
      id)   # id -u USER / id -g USER → uid/gid ficticios estables
            printf '1000\n'; exit 0 ;;
      mkdir|chmod|chown|rm|mv) "$@"; exit $? ;;
      *)    "$@"; exit $? ;;
    esac ;;
  file)
    action="${1:?}"; shift
    if [ "$action" = "push" ]; then
      src=""; dest=""; mode="600"
      while [ $# -gt 0 ]; do
        case "$1" in --mode) mode="$2"; shift 2 ;; --uid|--gid) shift 2 ;; *) if [ -z "$src" ]; then src="$1"; else dest="$1"; fi; shift ;; esac
      done
      # dest = "<name>/abs/path" → ruta real del sandbox = "/abs/path". Honra el --mode recibido y
      # PROPAGA los fallos de cada paso (un cp/chmod fallido NO debe reportarse como éxito, o el
      # arnés enmascararía fallos reales de transferencia).
      path="/${dest#*/}"
      mkdir -p "$(dirname "$path")" || { echo "fake-incus push: mkdir falló para $path" >&2; exit 1; }
      cp "$src" "$path" || { echo "fake-incus push: cp $src → $path falló" >&2; exit 1; }
      chmod "$mode" "$path" || { echo "fake-incus push: chmod $mode $path falló" >&2; exit 1; }
      exit 0
    elif [ "$action" = "pull" ]; then
      s="${1:?}"; d="${2:?}"; path="/${s#*/}"
      cp "$path" "$d" || { echo "fake-incus pull: cp $path → $d falló" >&2; exit 1; }
      exit 0
    fi
    echo "fake-incus: acción 'file $action' no soportada por el shim" >&2; exit 2 ;;
  *) echo "fake-incus: subcomando '$sub' no soportado por el shim" >&2; exit 2 ;;
esac
