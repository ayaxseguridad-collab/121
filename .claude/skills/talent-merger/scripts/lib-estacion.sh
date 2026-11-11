#!/usr/bin/env bash
# lib-estacion.sh — Funciones comunes de las herramientas de la estación del Mergeador (talent-merger).
#
# Se "source-ea" (`. lib-estacion.sh`): NO ejecuta nada ni cambia set -e/-u/-f del llamante.
#
# Parámetros de la estación: argumento > variable de entorno > atributo de la fila `estacion` del
# perfil de instancia (solo si hay TF_ESTACION, con el id de esa fila). NO hay valores por defecto de
# casa: un parámetro sin valor se rechaza con rc 2 nombrando la variable (est_exige).
#
# Atributos de la fila `estacion` que leen las herramientas: repo (owner/repo), clon (clon propio de la
# estación, nunca el clon con el que se corren las suites) y congelamiento (fichero de ventanas).
#
# Funciones: est_ayuda · est_arriba · est_motor · est_perfil_attr · est_param · est_exige · est_slug_ok ·
# est_sha40_ok · est_sha_ok · est_git_min · est_sellador · est_sellar · est_tmp_crear · est_tmp_limpiar.

EST_AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# est_ayuda <fichero> — imprime el bloque de comentarios de la cabecera (sin la primera línea).
est_ayuda() {
  local l n=0
  while IFS= read -r l; do
    n=$((n + 1)); [ "$n" -gt 1 ] || continue
    case "$l" in '#'*) printf '%s\n' "${l#\#}" ;; *) break ;; esac
  done < "$1"
}

# est_arriba <ruta-relativa>... — primera ruta existente buscando HACIA ARRIBA desde esta librería
# (nunca contando `../..`: el mismo fichero viaja a árboles de profundidad distinta).
est_arriba() {
  local d="$EST_AQUI" rel
  while :; do
    for rel in "$@"; do
      if [ -e "$d/$rel" ]; then printf '%s\n' "$d/$rel"; return 0; fi
    done
    [ "$d" != / ] || return 1
    d="$(dirname "$d")"
  done
}

# est_motor — raíz del motor (la que contiene scripts/lib/insumos-por-gate.sh). TF_MOTOR_PIN la fija.
est_motor() {
  local p
  if [ -n "${TF_MOTOR_PIN-}" ]; then
    [ -r "$TF_MOTOR_PIN/scripts/lib/insumos-por-gate.sh" ] || return 1
    printf '%s\n' "$TF_MOTOR_PIN"; return 0
  fi
  p="$(est_arriba scripts/lib/insumos-por-gate.sh)" || return 1
  printf '%s\n' "${p%/scripts/lib/insumos-por-gate.sh}"
}

# est_perfil_attr <clave> — atributo de la fila `estacion` TF_ESTACION. El perfil se lee en un
# subshell: lib-perfil.sh fija `set -uo pipefail` y no debe contagiarse al llamante.
est_perfil_attr() {
  local clave="$1" lp
  [ -n "${TF_ESTACION-}" ] || return 1
  lp="$(est_arriba skills/talent-ceo/scripts/lib-perfil.sh .claude/skills/talent-ceo/scripts/lib-perfil.sh)" || return 1
  (
    # shellcheck source=/dev/null
    . "$lp" || exit 2
    fila="$(perfil_row1 estacion "$TF_ESTACION")" || exit 2
    perfil_attr "$(printf '%s\n' "$fila" | cut -f6)" "$clave"
  )
}

# est_param <valor-argumento> <NOMBRE_VARIABLE> <atributo-del-perfil|""> — imprime el valor resuelto.
# rc 1 si ninguna de las tres fuentes lo tiene.
est_param() {
  local arg="$1" var="$2" attr="$3" v
  if [ -n "$arg" ]; then printf '%s\n' "$arg"; return 0; fi
  v="${!var-}"
  if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
  if [ -n "$attr" ]; then
    v="$(est_perfil_attr "$attr" 2>/dev/null)" || v=''
    if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
  fi
  return 1
}

# est_exige <NOMBRE> <valor> — rc 2 nombrando el parámetro si el valor está vacío.
est_exige() {
  [ -n "${2-}" ] && return 0
  printf '%s: PRECOND: falta %s (argumento, variable de entorno o atributo de la fila estacion del perfil)\n' "${0##*/}" "$1" >&2
  return 2
}

est_slug_ok() { [[ "${1-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; }
est_sha40_ok() { [[ "${1-}" =~ ^[0-9a-f]{40}$ ]]; }
est_sha_ok() { [[ "${1-}" =~ ^[0-9a-fA-F]{7,40}$ ]]; }

# est_git_min — rc 0 si git >= 2.38 (`git merge-tree --write-tree`).
est_git_min() {
  local v major minor
  v="$(git --version 2>/dev/null)" || return 1
  v="${v#git version }"; major="${v%%.*}"; v="${v#*.}"; minor="${v%%.*}"
  case "$major$minor" in '' | *[!0-9]*) return 1 ;; esac
  [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge 38 ]; }
}

# est_sellador — imprime el sellador declarado: TF_SELLAR (ejecutable) o bus-sellar.sh del skill talent-ceo.
est_sellador() {
  if [ -n "${TF_SELLAR-}" ]; then
    [ -f "$TF_SELLAR" ] && [ -x "$TF_SELLAR" ] || return 1
    printf '%s\n' "$TF_SELLAR"; return 0
  fi
  est_arriba skills/talent-ceo/scripts/bus-sellar.sh .claude/skills/talent-ceo/scripts/bus-sellar.sh
}

# est_sellar <marcador> <fichero> — sella con el sellador declarado. rc = el del sellador (2 si no se resuelve).
est_sellar() {
  local s
  [ -n "${TA_ROL-}" ] || { printf '%s: PRECOND: falta TA_ROL (identidad del sellador)\n' "${0##*/}" >&2; return 2; }
  s="$(est_sellador)" || { printf '%s: PRECOND: sellador no resoluble (TF_SELLAR o bus-sellar.sh)\n' "${0##*/}" >&2; return 2; }
  if [ -n "${TF_SELLAR-}" ]; then "$s" --marcador "$1" --rol "$TA_ROL" --src "$2"; else bash "$s" --marcador "$1" --rol "$TA_ROL" --src "$2"; fi
}

# est_tmp_crear / est_tmp_limpiar — directorio temporal propio; solo se borra bajo el prefijo creado aquí.
EST_TMP=''
est_tmp_crear() { EST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/est-mergeador.XXXXXX")" || return 1; }
est_tmp_limpiar() {
  local d="${EST_TMP-}"
  [ -n "$d" ] || return 0
  case "$d" in "${TMPDIR:-/tmp}"/est-mergeador.*) rm -rf -- "$d" ;; esac
  EST_TMP=''
}
