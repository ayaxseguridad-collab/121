#!/usr/bin/env bash
# Prepara panes sin despachar una issue ni reciclar sesiones existentes.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/dispatch.sh"

tco_preparar_sesion() {
  local carril="$1" modo="$2" c rp script update baseline pane capture
  case " $TCO_DEV_CARRILES " in *" $carril "*) ;; *) tco_die 'carril inválido para desarrollo' ;; esac
  # Este script también arranca agentes (los teclea con send-keys en la shell del pane): tco_require_agents exige que
  # TCO_DEV_CLI y TCO_AUDIT_CLI cumplan la gramática cerrada (un solo ejecutable; los flags van en TCO_*_FLAGS) antes de
  # tocar el canal, y el preflight de identidad la vuelve a exigir.
  tco_require_agents
  c="$(tco_container "$carril")"; rp="$(tco_repo_path)"
  if [ "$modo" = --plan ]; then
    printf 'Actualizar clon %s desde origin/main solo por fast-forward y sin cambios tracked; no resetear trabajo.\n' "$rp"
    printf 'En %s, usuario %s: aceptar confianza de carpeta %s y modo sin permisos (permite ejecutar órdenes sin confirmación); fusionar baseline privado antes de iniciar agentes.\n' "$c" "$TCO_CUSER" "$rp"
    printf 'Crear si falta sesión %s en %s, cwd %s; dev=%s auditor=%s; verificar identidad real. No despachar.\n' \
      "$TCO_TMUX" "$c" "$rp" "$TCO_DEV_CLI" "$TCO_AUDIT_CLI"
    return 0
  fi
  if [ "$modo" = --verificar ]; then
    tco_pane_identity_preflight "$carril" || return
    for pane in "$(tco_pane_dev)" "$(tco_pane_audit)"; do
      printf -v script 'tmux capture-pane -p -J -t %q' "$pane"
      capture=$(incus exec "$c" -- su - "$TCO_CUSER" -c "$script") || tco_die 'panel no verificable'
      [ -n "$capture" ] || tco_die 'panel vacío o no listo'
      if printf '%s\n' "$capture" | grep -qiE 'No, exit|Yes, I accept|trust this folder|trust the files'; then
        tco_die 'sesión parada en un diálogo'
      fi
    done
    return
  fi
  tco_lock_acquire "dispatch-$carril" || tco_die 'carril ocupado por otra operación'
  trap 'tco_lock_release "dispatch-$carril"' EXIT
  # F2 clonó antes del onboarding F4: traer su contrato antes de arrancar agentes.
  # shellcheck disable=SC2016 # Expansión en el contenedor.
  printf -v update 'git -C %q diff --quiet && git -C %q diff --cached --quiet && [ "$(git -C %q branch --show-current)" = main ] && git -C %q pull --ff-only origin main' "$rp" "$rp" "$rp" "$rp"
  incus exec "$c" -- su - "$TCO_CUSER" -c "$update" || tco_die 'clon no actualizable por fast-forward; conservar trabajo y revisar'
  printf -v baseline 'RP=%q; ' "$rp"
  # shellcheck disable=SC2016 # El cuerpo y los filtros jq se expanden en el contenedor.
  baseline+='set -e; umask 077; [ ! -L "$HOME/.claude.json" ] && [ ! -L "$HOME/.claude" ] && [ ! -L "$HOME/.claude/settings.json" ]; mkdir -p "$HOME/.claude"; [ -f "$HOME/.claude.json" ] || printf "{}\n" > "$HOME/.claude.json"; [ -f "$HOME/.claude/settings.json" ] || printf "{}\n" > "$HOME/.claude/settings.json"; tmp=$(mktemp "$HOME/.baseline.XXXXXX"); trap '\''rm -f "$tmp"'\'' EXIT; jq --arg rp "$RP" '\''.hasCompletedOnboarding = true | .projects[$rp].hasTrustDialogAccepted = true'\'' "$HOME/.claude.json" > "$tmp"; chmod 600 "$tmp"; mv "$tmp" "$HOME/.claude.json"; tmp=$(mktemp "$HOME/.baseline.XXXXXX"); jq '\''.skipDangerousModePermissionPrompt = true'\'' "$HOME/.claude/settings.json" > "$tmp"; chmod 600 "$tmp"; mv "$tmp" "$HOME/.claude/settings.json"'
  incus exec "$c" -- su - "$TCO_CUSER" -c "$baseline" || tco_die 'baseline Claude no preparado'
  # Construir argv remoto con quoting de Bash; no matar ni modificar panes existentes.
  printf -v script 'if ! tmux has-session -t %q 2>/dev/null; then tmux new-session -d -s %q -x 220 -y 50 -c %q && tmux split-window -h -t %q -c %q && tmux send-keys -t %q %q C-m && tmux send-keys -t %q %q C-m; fi' \
    "$TCO_TMUX" "$TCO_TMUX" "$rp" "$TCO_TMUX" "$rp" "$(tco_pane_dev)" \
    "$TCO_DEV_CLI $TCO_DEV_FLAGS ${TCO_DEV_MODEL_ARGS:-}" "$(tco_pane_audit)" \
    "$TCO_AUDIT_CLI $TCO_AUDIT_FLAGS ${TCO_AUDIT_MODEL_ARGS:-}"
  incus exec "$c" -- su - "$TCO_CUSER" -c "$script" || tco_die 'creación de panes fallida; conservar sesión y revisar'
  tco_pane_identity_preflight "$carril" || tco_die 'identidad de panes no acreditada'
  tco_lock_release "dispatch-$carril"
  trap - EXIT
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  [ "$#" -eq 2 ] || { echo 'uso preparar-sesiones.sh --plan|--ejecutar|--verificar CARRIL' >&2; exit 2; }
  case "$1" in --plan|--ejecutar|--verificar) ;; *) exit 2 ;; esac
  tco_preparar_sesion "$2" "$1"
fi
