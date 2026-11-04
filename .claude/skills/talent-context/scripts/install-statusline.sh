#!/usr/bin/env bash
# install-statusline.sh — APLICADOR ÚNICO del renderer clásico + la barra `ctx:` de Claude Code (talent-context, TAL-8038).
#
# Qué hace (idempotente): copia assets/statusline-ctx.sh a <dir de settings>/statusline-ctx.sh (0755) y fusiona con jq en
# settings.json `.tui="default"` (renderer clásico: sin pantalla alternada, el pane conserva scrollback y se puede capturar)
# y `.statusLine={type:"command",command:"bash <ruta>"}` (la barra que emite `ctx: NN%`). El resto de claves queda intacto;
# antes de escribir un settings existente deja `settings.json.bak-<UTC>`. Sin cambios → no escribe nada ni crea .bak.
#
# Uso: install-statusline.sh [--settings <ruta>] [--force] [--check | --check-version | --check-ctx]
#   (sin modo)       aplica. Primero exige la versión mínima de Claude (assets/claude-min-version, sin override).
#   --settings RUTA  settings.json a tocar (por defecto $HOME/.claude/settings.json); el script de la barra va a su lado.
#   --force          pisa una `statusLine` ajena (sin --force NO se pisa: se aplica `.tui` y se sale con rc 3).
#   --check          SOLO LECTURA: ¿está todo aplicado? (versión, .tui, .statusLine, script de la barra).
#   --check-version  solo comprueba `claude --version` >= mínima.
#   --check-ctx      ejecuta la `statusLine.command` EXISTENTE con un JSON de muestra y exige que su salida pase por
#                    `tc_ctx_pct` (¿esa barra, aunque sea ajena, emite `ctx: NN%` legible?).
# rc: 0 ok · 1 uso/entorno (sin jq, JSON inválido, mínima ilegible; nada escrito) · 2 --check/--check-ctx con diferencia ·
#     3 statusLine ajena sin --force · 4 versión de Claude menor que la mínima o ilegible.
# stdout: en modo aplicar/--check, una línea final `ESTADO=cambios|sin-cambios|diferencias`. El resto va a stderr.
# Solo requiere `jq` (y `claude` en el PATH para la versión). No usa red.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$HERE/../assets"
# shellcheck source=/dev/null
[ -r "$HERE/lib.sh" ] && . "$HERE/lib.sh"
say()  { printf '── %s\n' "$*" >&2; }
info() { printf '   %s\n' "$*" >&2; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }

SETTINGS=""; FORCE=0; MODE=apply
while [ $# -gt 0 ]; do
  case "$1" in
    --settings) [ $# -ge 2 ] && [ -n "$2" ] || { err "--settings requiere una ruta"; exit 1; }; SETTINGS="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --check|--check-version|--check-ctx)
      [ "$MODE" = apply ] || { err "los modos --check/--check-version/--check-ctx son excluyentes"; exit 1; }
      MODE="${1#--}"; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}" >&2; exit 0 ;;
    *) err "flag desconocido: $1"; exit 1 ;;
  esac
done
if [ -z "$SETTINGS" ]; then
  [ -n "${HOME:-}" ] || { err "HOME no definido y sin --settings"; exit 1; }
  SETTINGS="$HOME/.claude/settings.json"
fi
# Ruta ABSOLUTA siempre (el comando de la statusLine se ejecuta desde cualquier cwd): un --settings relativo se resuelve aquí.
case "$SETTINGS" in /*) ;; *) SETTINGS="$PWD/$SETTINGS" ;; esac
SETTINGS="$(realpath -ms -- "$SETTINGS")" || { err "no pude resolver la ruta de --settings"; exit 1; }
# La barra va junto al settings LÓGICO (~/.claude); si settings.json es un enlace simbólico (dotfiles) se escribe en su DESTINO
# (el enlace se conserva, nunca se sustituye por un fichero regular) y la copia previa queda junto a ese destino.
DEST_DIR="$(dirname "$SETTINGS")"; DEST_SCRIPT="$DEST_DIR/statusline-ctx.sh"
if [ -L "$SETTINGS" ]; then
  SETTINGS="$(readlink -f -- "$SETTINGS")" || { err "no pude resolver el enlace simbólico de settings.json"; exit 1; }
fi
SET_DIR="$(dirname "$SETTINGS")"
WANT_CMD="bash $(printf '%q' "$DEST_SCRIPT")"
SAMPLE='{"model":{"display_name":"Opus"},"context_window":{"used_percentage":42}}'

# --- versión mínima (fail-closed: mínima ilegible → rc 1; claude ausente/ilegible/menor → rc 4) -------------------------
check_version() {
  local minf="$ASSETS/claude-min-version" min cur low
  min="$(grep -vE '^[[:space:]]*(#|$)' "$minf" 2>/dev/null | head -1 | tr -d '[:space:]')"
  printf '%s' "$min" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || { err "versión mínima ilegible en $minf"; return 1; }
  cur="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  [ -n "$cur" ] || { err "no pude leer 'claude --version' (¿claude no está en el PATH?) — mínima exigida: $min"; return 4; }
  low="$(printf '%s\n%s\n' "$min" "$cur" | sort -V | head -1)"
  [ "$low" = "$min" ] || { err "Claude $cur < mínima $min (el renderer/barra no están garantizados): actualiza claude"; return 4; }
  info "claude $cur >= mínima $min"; return 0
}

if [ "$MODE" = check-version ]; then check_version; exit $?; fi
command -v jq >/dev/null 2>&1 || { err "jq no está instalado (único requisito)"; exit 1; }

# settings actual: ausente = {} ; presente debe ser un objeto JSON válido (si no, rc 1 y nada escrito)
EXISTS=0; CUR='{}'
if [ -e "$SETTINGS" ]; then
  EXISTS=1
  jq -s -e 'length == 1 and (.[0] | type == "object")' "$SETTINGS" >/dev/null 2>&1 || { err "$SETTINGS no es un objeto JSON válido — no toco nada"; exit 1; }
  CUR="$(jq -c . "$SETTINGS")"
fi

if [ "$MODE" = check-ctx ]; then
  type tc_ctx_pct >/dev/null 2>&1 || { err "falta lib.sh (tc_ctx_pct) junto al script"; exit 1; }
  cmd="$(printf '%s' "$CUR" | jq -r '.statusLine.command // empty' 2>/dev/null)"
  [ -n "$cmd" ] || { err "sin statusLine.command en $SETTINGS"; exit 2; }
  out="$(printf '%s' "$SAMPLE" | timeout 10 bash -c "$cmd" 2>/dev/null)"
  if pct="$(printf '%s\n' "$out" | tc_ctx_pct)"; then info "la barra existente emite ctx: ${pct}% con el JSON de muestra"; exit 0; fi
  err "la statusLine existente NO emite un 'ctx: NN%' legible con el JSON de muestra (salida: '$(printf '%s' "$out" | head -c 120)')"
  exit 2
fi

# estado de la statusLine: ninguna / propia (nuestro comando exacto) / ajena
SL_STATE="$(printf '%s' "$CUR" | jq -r --arg c "$WANT_CMD" '
  if (.statusLine // null) == null then "none"
  elif (.statusLine | type) == "object" and .statusLine.type == "command" and .statusLine.command == $c then "own"
  else "foreign" end')"
TUI_OK="$(printf '%s' "$CUR" | jq -r '.tui == "default"')"
SCRIPT_OK=1
if [ ! -f "$DEST_SCRIPT" ] || [ ! -x "$DEST_SCRIPT" ] || ! cmp -s "$ASSETS/statusline-ctx.sh" "$DEST_SCRIPT"; then SCRIPT_OK=0; fi

if [ "$MODE" = check ]; then
  check_version || exit $?
  diffs=0
  [ "$TUI_OK" = true ] || { info "DIFERENCIA: .tui != \"default\""; diffs=1; }
  case "$SL_STATE" in
    none) info "DIFERENCIA: sin statusLine"; diffs=1 ;;
    own)  [ "$SCRIPT_OK" = 1 ] || { info "DIFERENCIA: $DEST_SCRIPT ausente, no ejecutable o distinto del asset"; diffs=1; } ;;
  esac
  if [ "$diffs" = 1 ]; then printf 'ESTADO=diferencias\n'; exit 2; fi
  if [ "$SL_STATE" = foreign ] && [ "$FORCE" != 1 ]; then
    info "statusLine AJENA (no es la del paquete); usa --check-ctx para ver si emite ctx:"; printf 'ESTADO=diferencias\n'; exit 3
  fi
  [ "$SL_STATE" = foreign ] && { info "DIFERENCIA: statusLine ajena (con --force se pisaría)"; printf 'ESTADO=diferencias\n'; exit 2; }
  printf 'ESTADO=sin-cambios\n'; exit 0
fi

# ---- aplicar ---------------------------------------------------------------------------------------------------------
check_version || exit $?
WRITE_SL=1; RC=0
if [ "$SL_STATE" = foreign ] && [ "$FORCE" != 1 ]; then WRITE_SL=0; RC=3; fi
NEW="$(printf '%s' "$CUR" | jq -c --arg c "$WANT_CMD" --argjson sl "$WRITE_SL" '
  .tui = "default" | if $sl == 1 then .statusLine = {type: "command", command: $c} else . end')" \
  || { err "jq falló al fusionar $SETTINGS — nada escrito"; exit 1; }

changed=0
if [ "$WRITE_SL" = 1 ] && [ "$SCRIPT_OK" = 0 ]; then
  mkdir -p "$DEST_DIR" || { err "no pude crear $DEST_DIR"; exit 1; }
  tmp_s="$(mktemp "$DEST_DIR/.statusline-ctx.XXXXXX")" || { err "no pude crear temporal en $DEST_DIR"; exit 1; }
  cp "$ASSETS/statusline-ctx.sh" "$tmp_s" && chmod 0755 "$tmp_s" && mv -f "$tmp_s" "$DEST_SCRIPT" \
    || { rm -f "$tmp_s"; err "no pude instalar $DEST_SCRIPT"; exit 1; }
  info "instalado $DEST_SCRIPT"; changed=1
fi
if [ "$NEW" != "$CUR" ]; then
  mkdir -p "$SET_DIR" || { err "no pude crear $SET_DIR"; exit 1; }
  if [ "$EXISTS" = 1 ]; then
    bak="$SETTINGS.bak-$(date -u +%Y%m%dT%H%M%SZ)"
    [ -e "$bak" ] || cp -p "$SETTINGS" "$bak" || { err "no pude crear la copia $bak — nada escrito"; exit 1; }
    info "copia previa: $bak"
  fi
  tmp="$(mktemp "$SET_DIR/.settings.XXXXXX")" || { err "no pude crear temporal en $SET_DIR"; exit 1; }
  if printf '%s' "$NEW" | jq . > "$tmp"; then
    if [ "$EXISTS" = 1 ]; then chmod --reference="$SETTINGS" "$tmp" 2>/dev/null || chmod 600 "$tmp"; else chmod 600 "$tmp"; fi
    mv -f "$tmp" "$SETTINGS" || { rm -f "$tmp"; err "no pude escribir $SETTINGS"; exit 1; }
  else rm -f "$tmp"; err "no pude serializar el settings nuevo"; exit 1; fi
  if [ "$WRITE_SL" = 1 ]; then info "actualizado $SETTINGS (.tui=default + statusLine)"; else info "actualizado $SETTINGS (.tui=default)"; fi
  changed=1
fi
[ "$WRITE_SL" = 0 ] && info "statusLine AJENA conservada (rc 3): usa --force para pisarla o --check-ctx para comprobar que emite ctx:"
if [ "$changed" = 1 ]; then printf 'ESTADO=cambios\n'; else printf 'ESTADO=sin-cambios\n'; fi
exit "$RC"
