#!/usr/bin/env bash
# install-launchers.sh — Genera v/vk + v<XY>/v<XY>k en ~HOST/.local/bin desde assets/*.tmpl.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$HERE/../assets"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

LEFT="${LEFT_CMD:-claude-root}"; RIGHT="${RIGHT_CMD:-codex-root}"
BIN="$HOST_HOME/.local/bin"
mkdir -p "$BIN"

render() { # tmpl dest
  sed -e "s/__PREFIX__/$PREFIX/g" -e "s/__CUSER__/$CUSER/g" \
      -e "s/__SESSION__/$TMUX_SESSION/g" -e "s#__REPO_DIR__#$REPO_DIR#g" \
      -e "s#__MODELOS_LIB__#$HERE/../../talent-channel-operation/scripts/lib-modelos.sh#g" \
      -e "s/__LEFT__/$LEFT/g" -e "s/__RIGHT__/$RIGHT/g" "$1" > "$2"
  chmod +x "$2"
}
render "$ASSETS/launcher-v.tmpl"  "$BIN/v"
render "$ASSETS/launcher-vk.tmpl" "$BIN/vk"

# wrappers por canal existente
for y in $(seq 1 "${COUNT:-0}"); do
  xy="$MACHINE_NUM$y"
  rm -f "$BIN/v-$xy" "$BIN/v-${xy}k"   # limpiar wrappers legacy con guion (naming viejo)
  printf '#!/usr/bin/env bash\nexec "%s/v" %s "$@"\n'  "$BIN" "$xy" > "$BIN/v$xy";  chmod +x "$BIN/v$xy"
  printf '#!/usr/bin/env bash\nexec "%s/vk" %s "$@"\n' "$BIN" "$xy" > "$BIN/v${xy}k"; chmod +x "$BIN/v${xy}k"
done
chown -R "$HOST_USER:" "$BIN"

# Persistir la misma selección que se incorpora a la plantilla; sudo puede limpiar el entorno.
[[ $TMUX_SESSION =~ ^[A-Za-z0-9_.-]+$ ]] || tc_die 'sesión inválida'
mkdir -p "$SECRET_DIR"
chown "$HOST_USER:" "$SECRET_DIR"
[ ! -L "$SECRET_DIR/panel.conf" ] || tc_die 'configuración de panel enlazada'
panel_tmp="$(mktemp "$SECRET_DIR/.panel.XXXXXX")"
trap 'rm -f "$panel_tmp"' EXIT
printf '%s:.0\n' "$TMUX_SESSION" > "$panel_tmp"
chown "$HOST_USER:" "$panel_tmp"
chmod 600 "$panel_tmp"
mv "$panel_tmp" "$SECRET_DIR/panel.conf"

tc_say "Lanzadores instalados en $BIN"
# `|| true`: con COUNT=0 el glob v[0-9]* no matchea, ls sale ≠0 y set -e mataría el script
# antes del aviso de PATH y la confirmación final (primer setup sin canales aún).
ls "$BIN"/v "$BIN"/vk "$BIN"/v[0-9]* 2>/dev/null || true
case ":$PATH:" in *":$BIN:"*) : ;; *) tc_info "Añade $BIN al PATH si no está.";; esac
echo "✅ launchers: v <XY> / vk <XY> + v<XY>/v<XY>k (Claude=$LEFT, Codex=$RIGHT)."
