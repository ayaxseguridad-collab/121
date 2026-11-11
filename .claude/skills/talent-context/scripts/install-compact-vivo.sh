#!/usr/bin/env bash
# Aplicador único del compact vivo: fusión sin pisar hooks ni claves ajenas.
# Uso: install-compact-vivo.sh --puesto ROL [--settings RUTA] [--ventana N] [--pct N]
#      [--datos-sensibles si|no] [--check]
# rc: 0 conforme/aplicado; 1 uso/entorno; 2 diferencias (--check); 4 versión;
#     5 datos sensibles (solo env); 6 guarda de ventana. --check nunca escribe.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../hooks/compact-vivo.sh"
err() { printf 'compact-vivo: %s\n' "$*" >&2; }
PUESTO=''; SETTINGS="${HOME:-}/.claude/settings.json"; VENTANA=''; PCT=60; SENSIBLES=no; MODE=apply
while [ $# -gt 0 ]; do
  case "$1" in
    --puesto|--settings|--ventana|--pct|--datos-sensibles)
      [ $# -ge 2 ] && [ -n "$2" ] || { err "$1 requiere valor"; exit 1; }
      case "$1" in
        --puesto) PUESTO="$2" ;; --settings) SETTINGS="$2" ;; --ventana) VENTANA="$2" ;;
        --pct) PCT="$2" ;; --datos-sensibles) SENSIBLES="$2" ;;
      esac; shift 2 ;;
    --check) MODE=check; shift ;;
    -h|--help) sed -n '2,6s/^# //p' "$0"; exit 0 ;;
    *) err "flag desconocido: $1"; exit 1 ;;
  esac
done
[ -n "$PUESTO" ] || { err 'falta --puesto'; exit 1; }
case "$SENSIBLES" in si|no) ;; *) err 'datos-sensibles debe ser si o no'; exit 1 ;; esac
if [ -z "$VENTANA" ]; then case "$PUESTO" in ceo|pm) VENTANA=300000 ;; *) VENTANA=200000 ;; esac; fi
fallo_entorno() {
  err "$1"
  if [ "$MODE" = check ]; then
    local lista=ausente sesiones=0 gb=0
    local incluir="${COMPACT_VIVO_INCLUIR:-${XDG_CONFIG_HOME:-$HOME/.config}/talent-context/compact-vivo.incluir}"
    local guarda="${COMPACT_VIVO_GUARDA_B:-${XDG_CONFIG_HOME:-$HOME/.config}/talent-context/compact-vivo.guarda-b}"
    if [ -e "$incluir" ]; then
      if [ -r "$incluir" ]; then lista=ok; sesiones="$(grep -E '^[A-Za-z0-9_-]+$' "$incluir" | sort -u | wc -l | tr -d ' ')"; else lista=ilegible; fi
    fi
    [ ! -s "$guarda" ] || gb=1
    printf 'hooks=\nventana=ausente\npct=ausente\nlista_blanca=%s\nsesiones_inscritas=%s\nguarda_b=%s\nESTADO=diferencias\n' "$lista" "$sesiones" "$gb"
    exit 2
  fi
  exit 1
}

command -v jq >/dev/null 2>&1 || fallo_entorno 'falta jq'
case "$SETTINGS" in /*) ;; *) SETTINGS="$PWD/$SETTINGS" ;; esac
SETTINGS="$(realpath -ms -- "$SETTINGS")" || exit 1
DEST_DIR="$(dirname "$SETTINGS")"; DEST_SCRIPT="$DEST_DIR/compact-vivo.sh"
if [ -L "$SETTINGS" ]; then SETTINGS="$(readlink -f -- "$SETTINGS")" || exit 1; fi
SET_DIR="$(dirname "$SETTINGS")"; WANT_CMD="bash $(printf '%q' "$DEST_SCRIPT")"
INCLUIR="${COMPACT_VIVO_INCLUIR:-${XDG_CONFIG_HOME:-$HOME/.config}/talent-context/compact-vivo.incluir}"
GUARDA_B="${COMPACT_VIVO_GUARDA_B:-${XDG_CONFIG_HOME:-$HOME/.config}/talent-context/compact-vivo.guarda-b}"
CUR='{}'; EXISTS=0
if [ -e "$SETTINGS" ]; then
  EXISTS=1
  jq -se 'length == 1 and (.[0] | type == "object")' "$SETTINGS" >/dev/null 2>&1 || fallo_entorno 'settings no es un objeto JSON'
  CUR="$(jq -c . "$SETTINGS")" || exit 1
fi
# Una configuración mal formada no se sustituye ni se convierte en aviso.
printf '%s' "$CUR" | jq -e '
  ((.env // {}) | type == "object") and ((.hooks // {}) | type == "object") and
  ((.hooks // {}) | all(.[]; type == "array" and all(.[]; type == "object" and (.hooks | type == "array"))))
' >/dev/null || fallo_entorno 'env/hooks mal formados'
EVENTS='["UserPromptSubmit","PostToolUse","Stop","PostCompact","PreCompact","SessionStart"]'
check_version() {
  local min cur low salida rc
  min="$(grep -vE '^[[:space:]]*(#|$)' "$HERE/../assets/claude-min-version" | head -1 | tr -d '[:space:]')"
  [[ "$min" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { err 'mínima ilegible'; return 1; }
  salida="$(claude --version 2>/dev/null)"; rc=$?
  [ "$rc" = 0 ] || { err "Claude --version falló rc=$rc"; return 4; }
  cur="$(printf '%s' "$salida" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  [ -n "$cur" ] || { err "Claude ausente/ilegible; mínima $min"; return 4; }
  low="$(printf '%s\n%s\n' "$min" "$cur" | sort -V | head -1)"
  [ "$low" = "$min" ] || { err "Claude $cur < mínima $min"; return 4; }
}
# Respetar el límite mayor de entorno y settings: nunca acreditar un tope parcial.
limite() {
  local clave="$1" defecto="$2" a b
  a="${!clave:-$defecto}"
  b="$(printf '%s' "$CUR" | jq -r --arg k "$clave" --arg d "$defecto" '.env[$k] // $d')"
  [[ "$a" =~ ^[1-9][0-9]{0,8}$ && "$b" =~ ^[1-9][0-9]{0,8}$ ]] || { err "límite inválido $clave=$a/$b"; return 6; }
  if (( 10#$a > 10#$b )); then printf '%s' "$((10#$a))"; else printf '%s' "$((10#$b))"; fi
}
guarda_ventana() {
  local read_max mcp_max bash_max mayor minimo
  [[ "$VENTANA" =~ ^[1-9][0-9]{0,6}$ && "$PCT" =~ ^[0-9]{1,3}$ ]] || { err "ventana=$VENTANA pct=$PCT inválidos"; return 6; }
  VENTANA=$((10#$VENTANA)); PCT=$((10#$PCT))
  read_max="$(limite CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS 25000)" || return 6
  mcp_max="$(limite MAX_MCP_OUTPUT_TOKENS 25000)" || return 6
  bash_max="$(limite BASH_MAX_OUTPUT_LENGTH 30000)" || return 6
  mayor=$read_max; (( mcp_max <= mayor )) || mayor=$mcp_max
  (( (bash_max + 2) / 3 <= mayor )) || mayor=$(((bash_max + 2) / 3))
  minimo=$((3 * mayor))
  (( VENTANA >= 100000 && VENTANA <= 1000000 && PCT >= 1 && PCT <= 100 && VENTANA >= minimo )) || {
    err "ventana=$VENTANA (rango 100000-1000000), pct=$PCT (1-100); Read=$read_max MCP=$mcp_max Bash=$bash_max/3; mínimo 3 × $mayor = $minimo"; return 6;
  }
}
hooks_actuales() {
  # shellcheck disable=SC2016 # Variables de jq.
  printf '%s' "$CUR" | jq -r --arg c "$WANT_CMD" --argjson es "$EVENTS" '
    . as $s | $es | map(. as $e | select(any($s.hooks[$e][]?;
      ((.matcher // "") == "") and any(.hooks[]?; .type == "command" and .command == $c and .timeout == (if $e == "PostCompact" then 20 else 10 end))))) | join(",")'
}
if [ "$MODE" = check ]; then
  diffs=0; hooks="$(hooks_actuales)"; lista=ausente; sesiones=0; gb=0
  ventana_actual="$(printf '%s' "$CUR" | jq -r '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW // "ausente"')"
  pct_actual="$(printf '%s' "$CUR" | jq -r '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE // "ausente"')"
  if [ -e "$INCLUIR" ]; then
    if [ -r "$INCLUIR" ]; then
      lista=ok; sesiones="$(grep -E '^[A-Za-z0-9_-]+$' "$INCLUIR" | sort -u | wc -l | tr -d ' ')"
      [ "$(stat -c %a "$INCLUIR")" = 600 ] || diffs=1
    else lista=ilegible; fi
  fi
  [ ! -s "$GUARDA_B" ] || gb=1
  check_version || diffs=1
  guarda_ventana || diffs=1
  [ "$ventana_actual" = "$VENTANA" ] && [ "$pct_actual" = "$PCT" ] || diffs=1
  if [ "$SENSIBLES" = si ]; then
    [ -z "$hooks" ] || diffs=1
  else
    [ "$hooks" = 'UserPromptSubmit,PostToolUse,Stop,PostCompact,PreCompact,SessionStart' ] || diffs=1
    [ -f "$DEST_SCRIPT" ] && [ "$(stat -c %a "$DEST_SCRIPT" 2>/dev/null)" = 755 ] && cmp -s "$HOOK" "$DEST_SCRIPT" || diffs=1
    [ "$lista" = ok ] || diffs=1
  fi
  printf 'hooks=%s\nventana=%s\npct=%s\nlista_blanca=%s\nsesiones_inscritas=%s\nguarda_b=%s\n' "$hooks" "$ventana_actual" "$pct_actual" "$lista" "$sesiones" "$gb"
  if [ "$diffs" = 0 ]; then printf 'ESTADO=conforme\n'; exit 0; fi
  printf 'ESTADO=diferencias\n'; exit 2
fi
check_version || exit $?
guarda_ventana || exit $?
[ -r "$HOOK" ] || { err 'hook ausente'; exit 1; }
# shellcheck disable=SC2016 # Programa de fusión jq.
NEW="$(printf '%s' "$CUR" | jq -c --arg c "$WANT_CMD" --arg v "$VENTANA" --arg p "$PCT" --arg sensibles "$SENSIBLES" --argjson es "$EVENTS" '
  .env.CLAUDE_CODE_AUTO_COMPACT_WINDOW=$v | .env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=$p |
  if $sensibles == "si" then
    reduce $es[] as $e (. ; if .hooks[$e] then
      .hooks[$e] |= map(.hooks |= map(select(.command != $c))) | .hooks[$e] |= map(select(.hooks | length > 0)) else . end)
  else
    reduce $es[] as $e (. ;
      if any(.hooks[$e][]?; ((.matcher // "") == "") and any(.hooks[]?; .type == "command" and .command == $c and .timeout == (if $e == "PostCompact" then 20 else 10 end))) then .
      else .hooks[$e] = ((.hooks[$e] // []) + [{hooks:[{type:"command",command:$c,timeout:(if $e == "PostCompact" then 20 else 10 end)}]}]) end)
  end')" || { err 'fallo al fusionar'; exit 1; }
changed=0
if [ "$SENSIBLES" = no ]; then
  [ ! -L "$DEST_SCRIPT" ] && [ ! -L "$INCLUIR" ] || { err 'hook/lista enlazado'; exit 1; }
  if ! cmp -s "$HOOK" "$DEST_SCRIPT" || [ "$(stat -c %a "$DEST_SCRIPT" 2>/dev/null)" != 755 ]; then
    mkdir -p "$DEST_DIR" || exit 1
    tmp_s="$(mktemp "$DEST_DIR/.compact-vivo.XXXXXX")" || exit 1
    # shellcheck disable=SC2015 # Todo fallo de copia, chmod o rename aborta.
    cp "$HOOK" "$tmp_s" && chmod 0755 "$tmp_s" && mv -f "$tmp_s" "$DEST_SCRIPT" || { rm -f "$tmp_s"; exit 1; }
    changed=1
  fi
  if [ ! -e "$INCLUIR" ]; then
    mkdir -p "$(dirname "$INCLUIR")" || exit 1
    (umask 077; : > "$INCLUIR") || exit 1; changed=1
  fi
  if [ "$(stat -c %a "$INCLUIR")" != 600 ]; then chmod 600 "$INCLUIR" || exit 1; changed=1; fi
fi
if [ "$NEW" != "$CUR" ]; then
  mkdir -p "$SET_DIR" || exit 1
  if [ "$EXISTS" = 1 ]; then
    bak="$SETTINGS.bak-$(date -u +%Y%m%dT%H%M%SZ)"
    [ -e "$bak" ] || cp -p "$SETTINGS" "$bak" || exit 1
  fi
  tmp="$(mktemp "$SET_DIR/.settings.XXXXXX")" || exit 1
  if printf '%s' "$NEW" | jq . > "$tmp"; then
    if [ "$EXISTS" = 1 ]; then chmod --reference="$SETTINGS" "$tmp" || { rm -f "$tmp"; exit 1; }; else chmod 600 "$tmp"; fi
    mv -f "$tmp" "$SETTINGS" || { rm -f "$tmp"; exit 1; }
  else rm -f "$tmp"; exit 1; fi
  changed=1
fi
if [ "$SENSIBLES" = si ]; then err 'datos_sensibles=si: banco requiere redacción de importes probada + GO del lead; solo env aplicado'; exit 5; fi
if [ "$changed" = 1 ]; then printf 'ESTADO=cambios\n'; else printf 'ESTADO=sin-cambios\n'; fi
