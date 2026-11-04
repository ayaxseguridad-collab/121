#!/usr/bin/env bash
# Contexto de build EXACTO (cierre M3, ronda 5): exporta commit+patches a un
# directorio limpio via `git archive`. La imagen se construye SIEMPRE desde ese
# export, nunca desde el checkout de trabajo — por construccion, ni los
# untracked ni los IGNORADOS (p. ej. .hermit/, que .dockerignore no excluye y
# `git status --porcelain` ni siquiera muestra) pueden entrar al contexto.
# Este archivo lo comparten montar.sh y tests/probar-contexto-imagen.sh: el
# fixture prueba el MISMO mecanismo que produce la imagen real.

# exportar_contexto_exacto <repo_git> <commit> <dir_patches> <destino>
# El destino debe existir y estar vacio. Aplica los patches en orden lexico.
exportar_contexto_exacto() {
  local repo="$1" commit="$2" patches="$3" destino="$4"
  [ -d "$destino" ] || { echo "exportar_contexto_exacto: destino inexistente: $destino" >&2; return 1; }
  if [ -n "$(ls -A "$destino")" ]; then
    echo "exportar_contexto_exacto: el destino no esta vacio: $destino" >&2
    return 1
  fi
  if ! git -C "$repo" archive "$commit" | tar -x -C "$destino"; then
    echo "exportar_contexto_exacto: fallo git archive|tar de $commit desde $repo" >&2
    return 1
  fi
  local p
  for p in "$patches"/*.patch; do
    [ -e "$p" ] || continue
    # git apply funciona fuera de un repositorio, sobre el arbol exportado
    (cd "$destino" && git apply "$p") || {
      echo "exportar_contexto_exacto: fallo aplicando $(basename "$p") al export" >&2
      return 1
    }
  done
  return 0
}
