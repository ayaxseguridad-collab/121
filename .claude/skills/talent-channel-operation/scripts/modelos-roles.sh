#!/usr/bin/env bash
# Interfaz de lectura del registro, compartida por doctor y emergencia.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-modelos.sh
. "$HERE/lib-modelos.sh"
case "$#:$*" in
  1:--tsv|2:--familia\ opus|2:--familia\ sonnet|2:--familia\ sol) ;;
  *) echo 'uso: modelos-roles.sh --tsv | --familia opus|sonnet|sol' >&2; exit 2 ;;
esac
tco_modelos_read || exit 1
if [ "$1" = --familia ]; then
  case "$2" in opus) model="$TCO_OPUS_VIGENTE" ;; sonnet) model="$TCO_SONNET_VIGENTE" ;; sol) model="$TCO_SOL_VIGENTE" ;; esac
  [ -n "$model" ] || exit 1
  printf '%s\n' "$model"; exit 0
fi
# Ley del lead (7-nov): el revisor es SIEMPRE Codex y de otro proveedor que plan y código. Un registro con otro auditor es un
# error (igual que la guarda de lib-modelos.sh): no se publica ninguna fila ni existe la auditoría degradada.
[ "${TCO_ROL_AUDIT%%:*}" = codex ] || { echo 'ERROR modelos: Codex es obligatorio como revisor; el registro declara otro auditor y se PARA y se escala' >&2; exit 1; }
for rol in "$TCO_ROL_PLAN" "$TCO_ROL_CODE" "$TCO_ROL_CODE_SENSIBLE"; do
  [ "${TCO_ROL_AUDIT%%:*}" != "${rol%%:*}" ] || { echo 'ERROR modelos: el auditor y el que desarrolla no pueden ser el mismo proveedor' >&2; exit 1; }
done
for rol in ceo pm plan replan fallback code coding code_sensible audit coordinador merge salud; do
  printf '%s\t%s\t%s\n' "$rol" "$(tco_modelo_proveedor "$rol")" "$(tco_modelo_read "$rol")"
done
printf '#auditoria\tindependiente\n'
