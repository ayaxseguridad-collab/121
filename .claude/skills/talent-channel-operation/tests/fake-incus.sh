#!/usr/bin/env bash
# fake-incus.sh — shim de 'incus' para el arnés de talent-channel-operation (TAL-2295). NO es incus
# real: registra la SECUENCIA + ARGS de cada llamada (para asertar orden/contenido) e inyecta fallos
# por patrón. Cubre SOLO las formas que emiten los helpers del skill:
#   incus exec <name> -- su - <user> -c "<cmd>" [_ arg1 arg2 ...]
#   incus file pull <src> <dest>
#   incus file push <src> <dest> [--uid U --gid G --mode M]
#
# Variables del arnés:
#   TCO_FI_LOG      archivo donde se APENDIZA una línea normalizada por llamada.
#   TCO_FI_FAIL     ERE; si matchea la línea normalizada (subcmd + cmd remoto + posicionales) → exit RC.
#   TCO_FI_FAIL_RC  rc del fallo inyectado (default 1).
#   TCO_FI_CAP      texto que se imprime cuando el cmd remoto contiene 'capture-pane' (captura simulada).
#   TCO_FI_EXEC     =yes (TAL-8040): además de registrar, EJECUTA de verdad el cmd remoto con `bash -c` (propaga
#                   su rc) y `file push` COPIA el fichero al destino (sin el prefijo `<contenedor>`, chmod --mode).
#                   Sirve para correr el bloque real de dispatch.sh sobre un clon git temporal, sin flota Incus.
set -uo pipefail
LOG="${TCO_FI_LOG:-/dev/null}"
FAIL="${TCO_FI_FAIL:-}"
FRC="${TCO_FI_FAIL_RC:-1}"

emit() { printf '%s\n' "$1" >> "$LOG"; }
maybe_fail() { # línea-normalizada
  [ -n "$FAIL" ] || return 0
  printf '%s' "$1" | grep -qE -- "$FAIL" && exit "$FRC"
  return 0
}

sub="${1:-}"; shift || true
case "$sub" in
  exec)
    name="${1:?}"; shift
    [ "${1:-}" = "--" ] && shift
    # esperado: su - <user> -c "<cmd>" [_ pos...]  |  bash -c "<cmd>"
    cmd=""; posrest=""
    case "${1:-}" in
      su)   shift; while [ $# -gt 0 ] && [ "$1" != "-c" ]; do shift; done
            [ "${1:-}" = "-c" ] && { shift; cmd="${1:-}"; shift || true; posrest="$*"; } ;;
      bash) shift; [ "${1:-}" = "-c" ] && { shift; cmd="${1:-}"; shift || true; posrest="$*"; } ;;
      *)    cmd="$*" ;;
    esac
    line="exec $name: $cmd${posrest:+ | POS: $posrest}"
    emit "$line"
    maybe_fail "$line"
    # [TAL-8040] modo EXEC: ejecución real del cmd remoto (el rc del comando es el rc de `incus exec`).
    if [ "${TCO_FI_EXEC:-}" = yes ]; then
      # shellcheck disable=SC2086
      bash -c "$cmd" $posrest; exit $?
    fi
    # captura simulada: si el cmd remoto pide capture-pane, devolver TCO_FI_CAP.
    case "$cmd" in *capture-pane*) printf '%s\n' "${TCO_FI_CAP:-}";; esac
    exit 0 ;;
  file)
    action="${1:?}"; shift
    src=""; dest=""; fmode=""
    while [ $# -gt 0 ]; do
      case "$1" in --mode) fmode="${2:-}"; shift 2 ;; --uid|--gid) shift 2 ;; *) if [ -z "$src" ]; then src="$1"; else dest="$1"; fi; shift ;; esac
    done
    line="file $action $src $dest"
    emit "$line"
    maybe_fail "$line"
    # [TAL-8040] modo EXEC: push = copia real; el destino llega como `<contenedor>/ruta` -> `/ruta`.
    if [ "${TCO_FI_EXEC:-}" = yes ] && [ "$action" = push ]; then
      cp "$src" "/${dest#*/}" || exit 1
      [ -z "$fmode" ] || chmod "$fmode" "/${dest#*/}"
    fi
    exit 0 ;;
  *) emit "UNHANDLED $sub $*"; exit 0 ;;
esac
