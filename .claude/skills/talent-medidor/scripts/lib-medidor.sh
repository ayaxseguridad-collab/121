#!/usr/bin/env bash
# lib-medidor.sh — puente del medidor con el PERFIL DE INSTANCIA (talent-medidor, F1).
#
# El perfil se lee SOLO con `lib-perfil.sh` de talent-ceo, cargado con `source`: este fichero no
# reimplementa el parser ni ninguna de sus reglas V1-V9. Un perfil ausente o inválido llega como
# rc 2 y el recolector deja `part_id`, `rol` y `pane_kind` en NO MEDIDO — nunca sirve filas de un
# perfil roto, aunque la fila pedida esté intacta (contrato de lib-perfil.sh).
#
# Uso:  lib-medidor.sh partes
#   Imprime una línea por parte del perfil que declare el atributo `cwd=`:
#     <id> TAB <rol> TAB <pane_kind> TAB <sha256 del cwd>
#   El cwd sale SOLO como sha256: el recolector cruza huella contra huella y nunca ve la ruta.
#   rc 0 con partes · rc 1 perfil válido sin ninguna parte con `cwd=` · rc 2 sin perfil o inválido.
#
# Precedencia del perfil: la de lib-perfil.sh (TA_PERFIL > $SECRET_DIR/perfil.tsv > motor).
set -uo pipefail

_MEDIDOR_AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MEDIDOR_LIB_PERFIL="$_MEDIDOR_AQUI/../../talent-ceo/scripts/lib-perfil.sh"

medidor_partes() {
  local ruta tipo filas rc fila id atrs cwd rol pane n=0
  [ -f "$_MEDIDOR_LIB_PERFIL" ] || { echo "medidor: lib-perfil.sh ausente" >&2; return 2; }
  # shellcheck source=SCRIPTDIR/../../talent-ceo/scripts/lib-perfil.sh
  . "$_MEDIDOR_LIB_PERFIL"
  ruta="$(perfil_path)" || return 2
  perfil_validate "$ruta" || return 2
  for tipo in $PERFIL_TIPOS_VALIDOS; do
    filas="$(perfil_rows "$tipo" "$ruta")"; rc=$?
    [ "$rc" -eq 2 ] && return 2
    [ "$rc" -eq 0 ] || continue
    while IFS= read -r fila; do
      [ -n "$fila" ] || continue
      id="$(printf '%s\n' "$fila" | cut -f2)"
      atrs="$(printf '%s\n' "$fila" | cut -f6)"
      cwd="$(perfil_attr "$atrs" cwd)" || continue
      [ -n "$cwd" ] || continue
      rol="$(perfil_attr "$atrs" rol)" || rol='NO MEDIDO'
      pane="$(perfil_attr "$atrs" pane_kind)" || pane='NO MEDIDO'
      printf '%s\t%s\t%s\t%s\n' "$id" "$rol" "$pane" "$(printf '%s' "$cwd" | sha256sum | cut -d' ' -f1)"
      n=$((n + 1))
    done <<< "$filas"
  done
  [ "$n" -gt 0 ] || return 1
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1-}" in
    partes) medidor_partes; exit $? ;;
    *) echo "uso: lib-medidor.sh partes" >&2; exit 2 ;;
  esac
fi
