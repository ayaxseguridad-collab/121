#!/usr/bin/env bash
# Bloques reales, transportes dobles y argumentos finales; sin sesiones ni credenciales.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/../scripts"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export REMOTE_HOME="$T/home" CLI_LOG="$T/argv" PROMPT_MARKER="$T/marca"
export TCO_MODELOS_REGISTRO="$T/modelos.conf"
mkdir -p "$REMOTE_HOME/.claude" "$REMOTE_HOME/.codex" "$T/bin"
printf 'OPUS_MODEL="claude-%s-%s"\nSONNET_MODEL="claude-%s-%s"\nRESOLVED_UTC="2026-10-04T00:00:00Z"\nCLI_VERSION="2.1.289"\n' opus 6.2 sonnet 6.2 > "$TCO_MODELOS_REGISTRO"
# shellcheck source=/dev/null
. "$S/../../talent-channel-operation/scripts/lib-modelos.sh"
pass=0; fail=0
check() { if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL '; printf '%q ' "$@"; echo; fi; }
incus() {
  shift 3
  local cmd="$5"; shift 5
  HOME="$REMOTE_HOME" bash -c "$cmd" "$@"
}
tc_kill_wait() {
  touch "$T/kill"
  if [ "${MUTAR_FASE:-0}" = 1 ]; then printf '{"phase":"invalida"}\n' > "$REMOTE_HOME/.claude/tf-phase-v:.0.json"; fi
}
tc_err() { printf '%s\n' "$*" >&2; }
REFRESH="$(sed -n '/^  if \[ "$RESTART" = yes \]; then/,/^  fi/p' "$S/refresh-claude-auth.sh")"
run_refresh() (
  RESTART=yes CUSER=operador fail=0
  for ch in ct-01; do eval "$REFRESH"; done
  [ "$fail" = 0 ]
)
cat > "$T/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  has-session) exit 1 ;;
  display-message) [ "${PANE_AUSENTE:-0}" != 1 ] ;;
  send-keys) bash -c "$4" ;;
esac
EOF
cat > "$T/bin/claude-root" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$CLI_LOG"
EOF
cat > "$T/bin/codex-root" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$CLI_LOG"
EOF
cat > "$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
[ "${!#}" != true ] || exit 0
HOME="$REMOTE_HOME" bash -c "${!#}"
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"
unset TC_CLAUDE_PHASE
for phase in plan replan fallback coding audit; do
  printf '{"phase":"%s"}\n' "$phase" > "$REMOTE_HOME/.claude/tf-phase-v:.0.json"
  rm -f "$T/kill" "$CLI_LOG"
  rc=0; run_refresh > "$T/out" 2>&1 || rc=$?
  family=sonnet; case "$phase" in plan|replan|fallback) family=opus ;; esac
  check test "$rc" = 0
  check test -f "$T/kill"
  printf '%s\0' --model "claude-$family-6.2" > "$T/expected"
  check cmp "$T/expected" "$CLI_LOG"
done
# Receta canónica del coordinador, literal tras materializar su ruta; sudo es un doble.
export T
export -f incus tc_kill_wait tc_err
mkdir -p "$T/canon/scripts"
{
  printf '#!/usr/bin/env bash\nset -uo pipefail\n. %q\n' "$S/../../talent-channel-operation/scripts/lib-modelos.sh"
  printf 'RESTART=yes CUSER=operador fail=0\nfor ch in "$1"; do\n%s\ndone\n[ "$fail" = 0 ]\n' "$REFRESH"
} > "$T/canon/scripts/refresh-claude-auth.sh"
sudo() { [ "${1%%=*}" != --preserve-env ] || shift; env -u TMUX_SESSION -u TC_CLAUDE_PANE -u SECRET_DIR "$@"; }
recipe="$(sed -n '/sudo .*refresh-claude-auth.sh "\$canal" --restart && rc=0 || rc=\$?/p' "$S/../../talent-channel-operation/references/11-modelo-effort-y-recycle.md")"
recipe="${recipe//<ruta-talent-channels>/$T/canon}"
canal=ct-01
printf '{"phase":"plan"}\n' > "$REMOTE_HOME/.claude/tf-phase-v:.0.json"
rm -f "$T/kill" "$CLI_LOG"
rc=99; eval "$recipe" > "$T/out" 2>&1
check test "$rc" = 0
printf '%s\0' --model "claude-opus-6.2" > "$T/expected"
check cmp "$T/expected" "$CLI_LOG"
printf '{"phase":"coding"}\n' > "$REMOTE_HOME/.claude/tf-phase-v:.0.json"
printf '{"phase":"plan"}\n' > "$REMOTE_HOME/.claude/tf-phase-otra:.0.json"
mkdir -p "$HOME/.config/talent-channels"
panel_config="$HOME/.config/talent-channels/panel.conf"
printf 'otra:.0\n' > "$panel_config"
export TMUX_SESSION=otra
rc=99; eval "$recipe" > "$T/out" 2>&1
check test "$rc" = 0
check cmp "$T/expected" "$CLI_LOG"
rm -f "$REMOTE_HOME/.claude/tf-phase-otra:.0.json" "$panel_config"
unset TMUX_SESSION
rm -f "$REMOTE_HOME/.claude/tf-phase-v:.0.json" "$REMOTE_HOME/.claude/settings.json" "$T/kill" "$CLI_LOG"
rc=99; eval "$recipe" > "$T/out" 2>&1
check test "$rc" != 0
check test ! -e "$T/kill"
check test ! -e "$CLI_LOG"
check grep -q TC_CLAUDE_PHASE "$T/out"
rm -f "$REMOTE_HOME/.claude/tf-phase-v:.0.json"
for family in opus sonnet; do
  printf '{"model":"claude-%s-6.2"}\n' "$family" > "$REMOTE_HOME/.claude/settings.json"
  check run_refresh
  printf '%s\0' --model "claude-$family-6.2" > "$T/expected"
  check cmp "$T/expected" "$CLI_LOG"
done
check tco_modelo_guardar_fase ct-01 operador v:.0 "claude-opus-6.2"
check test "$(tco_modelo_fase_canal ct-01 operador v:.0)" = plan
TC_CLAUDE_PHASE=coding
check test "$(tco_modelo_fase_canal ct-01 operador v:.0)" = coding
unset TC_CLAUDE_PHASE
for input in '{"phase":"plan\n"}' '{"phase":" plan"}' '{"phase":"plan "}' '{"phase":"PLAN"}' '{"phase":1}' '{"phase":null}' '{"phase":[]}' '{}' '{"phase":"otro"}' '{"phase":"plan"} {"phase":"coding"}' '[]' ''; do
  printf '%s' "$input" > "$REMOTE_HOME/.claude/tf-phase-v:.0.json"
  rm -f "$T/kill" "$CLI_LOG"
  rc=0; run_refresh > "$T/out" 2>&1 || rc=$?
  check test "$rc" != 0
  check test ! -e "$T/kill"
  check test ! -e "$CLI_LOG"
done
rm -f "$REMOTE_HOME/.claude/tf-phase-v:.0.json" "$REMOTE_HOME/.claude/settings.json"
rc=0; run_refresh > "$T/out" 2>&1 || rc=$?
check test "$rc" != 0
check test ! -e "$T/kill"
check grep -q TC_CLAUDE_PHASE "$T/out"

# El destino y el registro se acreditan antes de detener; se relee la autoridad al relanzar.
printf '{"phase":"plan"}\n' > "$REMOTE_HOME/.claude/tf-phase-v:.0.json"
rm -f "$T/kill" "$CLI_LOG"
export PANE_AUSENTE=1
rc=0; run_refresh > "$T/out" 2>&1 || rc=$?
check test "$rc" != 0
check test ! -e "$T/kill"
check test ! -e "$CLI_LOG"
unset PANE_AUSENTE
registro_guardado="$TCO_MODELOS_REGISTRO"
TCO_MODELOS_REGISTRO="$T/ausente"
rc=0; run_refresh > "$T/out" 2>&1 || rc=$?
check test "$rc" != 0
check test ! -e "$T/kill"
check test ! -e "$CLI_LOG"
TCO_MODELOS_REGISTRO="$registro_guardado"
export MUTAR_FASE=1
rc=0; run_refresh > "$T/out" 2>&1 || rc=$?
check test "$rc" != 0
check test -e "$T/kill"
check test ! -e "$CLI_LOG"
unset MUTAR_FASE

# El papel contiene sintaxis de shell y saltos finales. El CLI recibe un solo argumento exacto.
cat > "$REMOTE_HOME/.codex/role-prompt.txt" <<'EOF'
--papel 'simple' "doble" $VARIABLE
$(printf ejecutado > "$PROMPT_MARKER")
`printf ejecutado > "$PROMPT_MARKER"`
línea con dólar $ y acento

EOF
sed -e "s#__MODELOS_LIB__#$S/../../talent-channel-operation/scripts/lib-modelos.sh#g" \
  -e 's/__PREFIX__/ct-/g' -e 's/__CUSER__/operador/g' -e 's/__REPO_DIR__/repo/g' \
  -e 's/__SESSION__/v/g' -e 's/__LEFT__/claude-root/g' -e 's/__RIGHT__/codex-root/g' \
  "$HERE/../assets/launcher-v.tmpl" > "$T/v"
check bash "$T/v" 01
check test ! -e "$PROMPT_MARKER"
check python3 - "$CLI_LOG" "$REMOTE_HOME/.codex/role-prompt.txt" <<'PY'
import pathlib, sys
args = pathlib.Path(sys.argv[1]).read_bytes().split(b'\0')
assert args == [b'--', pathlib.Path(sys.argv[2]).read_bytes(), b''], args
PY

# La orden literal del verificador rechaza flujos tanto en settings como en onboarding.
export FIXTURE_HOME="$REMOTE_HOME"
incus() {
  shift 3
  local cmd="$1" arg args=(); shift
  for arg in "$@"; do args+=("${arg//\/home\/operador/$FIXTURE_HOME}"); done
  "$cmd" "${args[@]}"
}
export -f incus
chk() { shift; local cmd="$1"; shift; bash -c "$cmd" _ "$@"; }
VERIFY="$(sed -n '/^  chk .*claude baseline /p' "$S/verify.sh")"
ch=ct-01 CUSER=operador TCO_SONNET_VIGENTE="claude-sonnet-6.2"
for file in settings onboarding; do
  for kind in unico dos basura lista vacio; do
    printf '{"model":"%s"}\n' "$TCO_SONNET_VIGENTE" > "$REMOTE_HOME/.claude/settings.json"
    printf '{"hasCompletedOnboarding":true}\n' > "$REMOTE_HOME/.claude.json"
    target="$REMOTE_HOME/.claude/settings.json"; field='"model":"claude-sonnet-6.2"'
    [ "$file" != onboarding ] || { target="$REMOTE_HOME/.claude.json"; field='"hasCompletedOnboarding":true'; }
    case "$kind" in
      unico) printf '{%s}\n' "$field" ;;
      dos) printf '{}\n{%s}\n' "$field" ;;
      basura) printf '{%s}\nbasura\n' "$field" ;;
      lista) printf '[{%s}]\n' "$field" ;;
      vacio) : ;;
    esac > "$target"
    rc=0; eval "$VERIFY" > "$T/out" 2>&1 || rc=$?
    if [ "$kind" = unico ]; then check test "$rc" = 0; else check test "$rc" != 0; fi
  done
done
# Los aplicadores y el onboarding rechazan antes de sobrescribir el fichero.
incus() {
  shift 3
  local cmd="$5"; shift 5
  HOME="$REMOTE_HOME" bash -c "$cmd" "$@"
}
export -f incus
REPO_DIR="$T"
target_path() { printf '%s/%s' "$REPO_DIR" "$1"; }
_ok() { :; }; _fail() { :; }; mark_fail() { HAS_FAIL=1; }
eval "$(sed -n '/^verificar_equivalente()/,/^}/p' "$S/../../talent-repo-onboarding/scripts/verify-repo-parity.sh")"
for kind in dos basura lista vacio; do
  case "$kind" in
    dos) printf '{}\n{}\n' ;;
    basura) printf '{}\nbasura\n' ;;
    lista) printf '[]\n' ;;
    vacio) : ;;
  esac > "$REMOTE_HOME/.claude/settings.json"
  cp "$REMOTE_HOME/.claude/settings.json" "$T/antes"
  rc=0; bash "$S/../../talent-channel-operation/scripts/preparar-modelo-canal.sh" ct-01 operador > "$T/out" 2>&1 || rc=$?
  check test "$rc" != 0
  check cmp "$T/antes" "$REMOTE_HOME/.claude/settings.json"
  rc=0; bash "$S/../../talent-context/scripts/install-statusline.sh" --settings "$REMOTE_HOME/.claude/settings.json" > "$T/out" 2>&1 || rc=$?
  check test "$rc" = 1
  check cmp "$T/antes" "$REMOTE_HOME/.claude/settings.json"
  HAS_FAIL=0
  verificar_equivalente settings home/.claude/settings.json settings_hooks
  check test "$HAS_FAIL" = 1
done
printf 'RESULTADO fase papel JSON PASS=%s FAIL=%s TOTAL=111\n' "$pass" "$fail"
[ "$fail" = 0 ] && [ "$pass" = 111 ]
