#!/usr/bin/env bash
# Compara o aplica la política; nunca relanza torres ni canales ocupados.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-modelos.sh
. "$HERE/lib-modelos.sh"
case "${1:-}" in --comprobar|--plan|--ejecutar) mode="$1" ;; *) echo 'uso: actualizar-modelos.sh --comprobar|--plan|--ejecutar' >&2; exit 2 ;; esac
[ $# -eq 1 ] || exit 2
dest="$(tco_modelos_path)"
tco_modelos_read
old_opus="$TCO_OPUS_VIGENTE"; old_sonnet="$TCO_SONNET_VIGENTE"; old_cli="$TCO_MODELOS_CLI"
[ ! -L "${dest%/*}/actualizar-modelos.lock" ] || exit 1
exec {lock}>"${dest%/*}/actualizar-modelos.lock"
flock -x "$lock"
work="$(mktemp -d "${dest%/*}/.comparar.XXXXXX")"
trap 'rm -rf "$work"' EXIT
TCO_MODELOS_REGISTRO="$work/modelos.conf" bash "$HERE/resolver-modelos.sh"
tco_modelos_read "$work/modelos.conf"
new_opus="$TCO_OPUS_VIGENTE"; new_sonnet="$TCO_SONNET_VIGENTE"
changed=0
[ "$old_opus|$old_sonnet" = "$new_opus|$new_sonnet" ] || changed=1
printf 'CLI instalado=%s registro=%s; la actualización del propio CLI es responsabilidad de su actualizador; no se instala ni se consulta un catálogo externo\n' "$TCO_MODELOS_CLI" "$old_cli"
printf 'CAMBIO=%s Opus=%s -> %s Sonnet=%s -> %s\n' "$changed" "$old_opus" "$new_opus" "$old_sonnet" "$new_sonnet"
if [ "$mode" = --comprobar ]; then [ "$changed" = 0 ] && exit 0; exit 3; fi
if [ "$mode" = --plan ]; then
  echo 'PLAN: actualizar registro y configuración; aplicar a canales confirmados ociosos; diferir ocupados; avisar torres por bus'
  exit 0
fi
# El registro es autoridad inmediata; cualquier aplicación parcial sale no-cero y se reintenta.
mv -f "$work/modelos.conf" "$dest"
# shellcheck source=00-config.sh
. "$HERE/00-config.sh"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
rc=0
for carril in $TCO_DEV_CARRILES $TCO_AUDIT_CARRILES; do
  [[ $carril =~ ^[0-9]+$ ]] || exit 1
  if ! tco_lock_acquire "dispatch-$carril"; then printf 'DIFERIDO %s despacho en curso\n' "$carril"; continue; fi
  if ! tco_carril_libre "$carril"; then printf 'DIFERIDO %s ocupado o sin prueba de reposo\n' "$carril"; tco_lock_release "dispatch-$carril"; continue; fi
  cont="$(tco_container "$carril")"
  if bash "$HERE/preparar-modelo-canal.sh" "$cont" "$TCO_CUSER" &&
     tco_ensure_model "$carril" "$(tco_pane_dev)" "$new_sonnet" &&
     { [ "$(tco_cli_exe "$TCO_AUDIT_CLI")" != claude ] ||
       tco_ensure_model "$carril" "$(tco_pane_audit)" "$new_sonnet"; }; then
    printf 'APLICADO %s\n' "$carril"
  else printf 'ERROR aplicación %s\n' "$carril" >&2; rc=1; fi
  tco_lock_release "dispatch-$carril"
done
# El aviso se reintenta también cuando el registro ya está actualizado.
marker="MODELOS-${new_opus//./_}-${new_sonnet//./_}"
bus_rc=0
bash "$HERE/../../talent-ceo/scripts/bus-sellar.sh" --marcador "$marker" --rol "${TA_ROL:?define TA_ROL del usuario}" --nota 'Modelos vigentes actualizados; las torres deben cambiar y acreditar el modelo en doctor' || bus_rc=$?
[ "$bus_rc" = 0 ] || [ "$bus_rc" = 3 ] || rc=1
exit "$rc"
