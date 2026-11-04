#!/usr/bin/env bash
# Generación y lectura reales de la selección; identidad y transportes aislados.
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL '; printf '%q ' "$@"; echo; fi; }
export HOST_USER="$(id -un)" HOST_HOME="$T/host" SECRET_DIR="$T/config"
export TC_NO_AUTOLOAD=1 TMUX_SESSION=otra PREFIX=ct- CUSER=operador REPO_DIR=repo MACHINE_NUM=0 COUNT=0
mkdir -p "$HOST_HOME"
# Doble de privilegios: lo creado por el administrador pertenece a root hasta chown.
# chmod 0600 impide la lectura real del dueño si se omite el cambio de propietario.
export PANEL_OWNER="$T/owner" OWNER_UID="$(id -u)" HOST_GROUP=inicio
chown() {
  [ "${FALLAR_CHOWN:-}" != bin ] || return 1
  [ "$1" != -R ] || shift
  # El grupo de inicio existe; el grupo homónimo del usuario no existe.
  case "$1" in "$HOST_USER:"|"$HOST_USER:$HOST_GROUP") : ;; *) return 1 ;; esac
  case "${!#}" in
    */.panel.*)
      [ "${FALLAR_CHOWN:-}" != panel ] || return 1
      printf '%s\n' "$OWNER_UID" > "$PANEL_OWNER" ;;
  esac
}
chmod() {
  if [ "${ADMIN_PANEL:-0}" = 1 ] && [[ ${!#} = */.panel.* ]] && [ "$(cat "$PANEL_OWNER")" = 0 ]; then
    command chmod 000 "${!#}"
  else command chmod "$@"
  fi
}
stat() {
  if [[ ${!#} = */panel.conf ]] && [ "$(cat "$PANEL_OWNER")" = 0 ]; then
    case "$2" in %u) echo 0; return ;; '%U:%G') echo root:root; return ;; esac
  fi
  command stat "$@"
}
export -f chown chmod stat
rc=0; chown "$HOST_USER:$HOST_USER" "$HOST_HOME" || rc=$?
check test "$rc" != 0
# shellcheck source=/dev/null
. "$S/00-config.sh"
tc_resolve_host_identity() { HOST_USER="$(id -un)"; HOST_HOME="$T/host"; }
# shellcheck source=/dev/null
. "$S/../../talent-channel-operation/scripts/lib-modelos.sh"
for session in v otra; do
  printf '0\n' > "$PANEL_OWNER"
  check env ADMIN_PANEL=1 TMUX_SESSION="$session" bash "$S/install-launchers.sh"
  check grep -q "$session" "$HOST_HOME/.local/bin/v"
  check test "$(stat -c %a "$SECRET_DIR/panel.conf")" = 600
  check test "$(stat -c %u "$SECRET_DIR/panel.conf")" = "$OWNER_UID"
  check env -u TMUX_SESSION -u TC_CLAUDE_PANE bash -c '. "$1"; [ "$(tco_modelo_panel_instancia)" = "$2:.0" ]' _ "$S/../../talent-channel-operation/scripts/lib-modelos.sh" "$session"
  unset TMUX_SESSION
  check tc_load_config
  check test "${TMUX_SESSION:-}" = "$session"
done
unset TMUX_SESSION
# Propietario incorrecto, modo ilegible, contenido inválido y enlace: ambos lectores
# deben fallar con ruta, propietario encontrado y orden de reparación, aun con override.
diagnostico() {
  local reader="$1" rc=0
  "$reader" > "$T/out" 2>&1 || rc=$?
  [ "$rc" != 0 ] && grep -Fq "$SECRET_DIR/panel.conf" "$T/out" &&
    grep -Fq "propietario=$(stat -c '%U:%G' "$SECRET_DIR/panel.conf")" "$T/out" &&
    grep -q 'sudo chown .*sudo chmod 600 .*install-launchers.sh' "$T/out"
}
printf '0\n' > "$PANEL_OWNER"
check diagnostico tco_modelo_panel_instancia
check diagnostico tc_load_config
TMUX_SESSION=otra TC_CLAUDE_PANE=otra:.0
check diagnostico tco_modelo_panel_instancia
check diagnostico tc_load_config
unset TMUX_SESSION TC_CLAUDE_PANE
printf '%s\n' "$OWNER_UID" > "$PANEL_OWNER"
command chmod 000 "$SECRET_DIR/panel.conf"
check diagnostico tco_modelo_panel_instancia
check diagnostico tc_load_config
command chmod 600 "$SECRET_DIR/panel.conf"
for contenido in '' 'otra:.0' $'otra:.0\nextra\n' $'otra:.0\n\n'; do
  printf '%s' "$contenido" > "$SECRET_DIR/panel.conf"
  check diagnostico tco_modelo_panel_instancia
  check diagnostico tc_load_config
done
rm -f "$SECRET_DIR/panel.conf"
ln -s "$T/inexistente" "$SECRET_DIR/panel.conf"
check diagnostico tco_modelo_panel_instancia
check diagnostico tc_load_config
rm -f "$SECRET_DIR/panel.conf"
# Ausencia mantiene v; fallo de chown nunca publica la selección nueva.
check test "$(tco_modelo_panel_instancia)" = v:.0
check tc_load_config
check test "$TMUX_SESSION" = v
printf 'v:.0\n' > "$SECRET_DIR/panel.conf"
for destino in bin panel; do
  rc=0; env ADMIN_PANEL=1 FALLAR_CHOWN="$destino" TMUX_SESSION=otra bash "$S/install-launchers.sh" > "$T/out" 2>&1 || rc=$?
  check test "$rc" != 0
  check grep -qx 'v:.0' "$SECRET_DIR/panel.conf"
  check test -z "$(find "$SECRET_DIR" -name '.panel.*' -print)"
done
printf 'RESULTADO panel durable: PASS=%s FAIL=%s TOTAL=40\n' "$pass" "$fail"
[ "$fail" = 0 ] && [ "$pass" = 40 ]
