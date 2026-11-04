#!/usr/bin/env bash
# apply-renderer.sh — Renderer CLÁSICO de Claude Code + barra `ctx:` en el golden y en canales YA clonados (TAL-8038).
# Por qué: sin esto `claude` puede correr en pantalla alternada (fullscreen): el pane no tiene scrollback, el PLAN y el
# handoff dejan de ser capturables y, sin una statusLine, ningún pane emite `ctx: NN%` (compact-60 ciego).
# Tres capas, TODAS idempotentes y sin tocar credenciales ni matar sesiones:
#   1. settings.json (vía talent-context/scripts/install-statusline.sh, empujado al contenedor por tar/stdin):
#      `.tui="default"` + `.statusLine` (barra `[modelo] ctx: NN%`); versión mínima de Claude fail-closed.
#   2. ~/.bashrc: `export CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1` con guard PROPIO (el guard del alias claude-root no sirve).
#   3. ~/.tmux.conf: `set -g alternate-screen off` (+ `tmux set -g` best-effort en el servidor vivo del contenedor).
# Las sesiones `claude` YA abiertas conservan su renderer hasta el próximo relanzamiento (nada se mata aquí).
#
# Uso:  apply-renderer.sh [--only <contenedor>]... [--force]
#   (sin --only)  todos los canales reales de ESTA fábrica (tc_list_real_channels); --only acota (acepta también el golden).
#   --force       pisa una statusLine ajena (por defecto se conserva y el contenedor cuenta como FALLO: rc 3 del instalador).
# rc: 0 todo aplicado/ya aplicado · 1 algún contenedor falló (el resto se procesa igualmente) · 2 uso/entorno.
# También es SOURCEABLE: 02-golden.sh usa tc_renderer_settings / tc_renderer_shell sobre el golden.
# shellcheck shell=bash

# Raíz del skill talent-context (vecino de este skill: <skills>/talent-context). TC_RENDERER_CTX_ROOT lo sobreescribe (tests).
tc_renderer_ctx_root() {
  local here root
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root="${TC_RENDERER_CTX_ROOT:-$here/../../talent-context}"
  local f
  for f in scripts/install-statusline.sh scripts/lib.sh assets/statusline-ctx.sh assets/claude-min-version; do
    [ -r "$root/$f" ] || { printf 'ERROR: falta %s/%s (skill talent-context ausente — fail-closed)\n' "$root" "$f" >&2; return 1; }
  done
  printf '%s' "$(cd "$root" && pwd)"
}

# Capa 1 — settings.json: tui=default + statusLine. $1=contenedor [$2=--force]. Imprime ESTADO=… ; rc del instalador
# (0 ok · 1 entorno/JSON · 3 statusLine ajena conservada · 4 versión de Claude < mínima/ilegible).
tc_renderer_settings() {
  local c="$1" force="${2:-}" root flags=""
  [ -z "$force" ] || [ "$force" = --force ] || { printf 'ERROR: argumento inválido: %s\n' "$force" >&2; return 1; }
  [ -z "$force" ] || flags="--force"
  root="$(tc_renderer_ctx_root)" || return 1
  # El instalador viaja por tar/stdin a un dir temporal del propio usuario del carril: no deja ficheros ni usa `file push`.
  ( set -o pipefail
    tar -C "$root" -cf - scripts/install-statusline.sh scripts/lib.sh assets/statusline-ctx.sh assets/claude-min-version \
      | incus exec "$c" -- su - "$CUSER" -c 'd="$(mktemp -d)" || exit 1
          tar -xf - -C "$d" || { rm -rf "$d"; exit 1; }
          bash "$d/scripts/install-statusline.sh" '"$flags"'; rc=$?
          rm -rf "$d"; exit $rc' )
}

# Capas 2 y 3 — export en bashrc (guard propio) + alternate-screen off en tmux.conf. $1=contenedor. Imprime ESTADO=… .
tc_renderer_shell() {
  local c="$1"
  tc_cuser "$c" 'ch=0
    grep -qs "^export CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1" "$HOME/.bashrc" || {
      printf "\n# [TAL-8038] renderer clasico de Claude Code (sin pantalla alternada: el pane conserva scrollback)\nexport CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1\n" >> "$HOME/.bashrc" || exit 1; ch=1; }
    grep -qxs "set -g alternate-screen off" "$HOME/.tmux.conf" || {
      # fichero ajeno sin salto de línea final: añadirlo antes, o la línea nueva se pegaría a la última
      [ -s "$HOME/.tmux.conf" ] && [ -n "$(tail -c1 "$HOME/.tmux.conf")" ] && { printf "\n" >> "$HOME/.tmux.conf" || exit 1; }
      printf "set -g alternate-screen off\n" >> "$HOME/.tmux.conf" || exit 1; ch=1; }
    # servidor tmux ya vivo en el contenedor: aplicarlo en caliente (best-effort; sin servidor es un no-op). No mata nada.
    tmux set-option -g alternate-screen off >/dev/null 2>&1 || true
    if [ "$ch" = 1 ]; then echo ESTADO=cambios; else echo ESTADO=sin-cambios; fi'
}

# Aplica las tres capas a UN contenedor. Imprime una línea de resultado; rc 0 ok · 1 fallo.
tc_renderer_apply_one() {
  local c="$1" force="${2:-}" s_out s_rc sh_out sh_rc st_s st_sh
  s_out="$(tc_renderer_settings "$c" "$force")"; s_rc=$?
  case "$s_rc" in
    0) : ;;
    3) printf '  FAIL  %s: statusLine AJENA conservada (rc 3) — usa --force para pisarla o comprueba con install-statusline.sh --check-ctx\n' "$c" >&2; return 1 ;;
    4) printf '  FAIL  %s: Claude menor que la versión mínima o ilegible (rc 4) — actualiza claude (talent-channels ref 06 §Agentes al día)\n' "$c" >&2; return 1 ;;
    *) printf '  FAIL  %s: install-statusline.sh falló (rc %s)\n' "$c" "$s_rc" >&2; return 1 ;;
  esac
  sh_out="$(tc_renderer_shell "$c")"; sh_rc=$?
  [ "$sh_rc" -eq 0 ] || { printf '  FAIL  %s: no pude escribir bashrc/tmux.conf (rc %s)\n' "$c" "$sh_rc" >&2; return 1; }
  st_s="$(printf '%s\n' "$s_out" | grep -E '^ESTADO=' | tail -1)"; st_sh="$(printf '%s\n' "$sh_out" | grep -E '^ESTADO=' | tail -1)"
  if [ "$st_s" = "ESTADO=sin-cambios" ] && [ "$st_sh" = "ESTADO=sin-cambios" ]; then
    printf '  ok    %s: sin cambios (renderer clásico + barra ctx ya aplicados)\n' "$c"
  else
    printf '  ok    %s: aplicado (settings:%s · bashrc/tmux:%s) — las sesiones claude abiertas siguen con su renderer hasta relanzarlas\n' \
      "$c" "${st_s#ESTADO=}" "${st_sh#ESTADO=}"
  fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=/dev/null
  . "$HERE/00-config.sh"
  # shellcheck source=/dev/null
  . "$HERE/lib.sh"
  ONLY=(); FORCE=""
  while [ $# -gt 0 ]; do case "$1" in
    --only) [ $# -ge 2 ] && [ -n "$2" ] || tc_die "--only requiere un contenedor"
            printf '%s' "$2" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$' || tc_die "nombre de contenedor inválido: $2"
            ONLY+=("$2"); shift 2;;
    --force) FORCE="--force"; shift;;
    *) tc_die "flag desconocido para apply-renderer: $1";;
  esac; done
  tc_renderer_ctx_root >/dev/null || exit 2
  if [ "${#ONLY[@]}" -gt 0 ]; then targets=("${ONLY[@]}")
  else
    list="$(tc_list_real_channels)" || tc_die "no pude enumerar los canales de la fábrica (incus list / MACHINE_NUM) — fail-closed."
    # shellcheck disable=SC2206
    targets=($list)
    [ "${#targets[@]}" -gt 0 ] || tc_die "sin canales de la fábrica (${PREFIX}${MACHINE_NUM}·) que tocar."
  fi
  tc_say "RENDERER CLÁSICO + barra ctx: en ${#targets[@]} contenedor(es)"
  bad=0
  for c in "${targets[@]}"; do tc_renderer_apply_one "$c" "$FORCE" || bad=$((bad+1)); done
  echo
  if [ "$bad" -eq 0 ]; then tc_info "TODOS los contenedores OK"; exit 0; fi
  tc_info "$bad contenedor(es) con FALLO — arriba el motivo de cada uno (¿detenido? incus exec falla en un contenedor parado)."
  exit 1
fi
