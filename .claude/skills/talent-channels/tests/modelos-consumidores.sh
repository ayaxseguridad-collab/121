#!/usr/bin/env bash
# Funciones y bloques reales con dobles de transporte; sin credenciales ni red.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/../scripts"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export TCO_MODELOS_REGISTRO="$T/modelos.conf"
# shellcheck source=/dev/null
. "$S/auth-move-lib.sh"
pass=0; fail=0
check() { if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL '; printf '%q ' "$@"; echo; fi; }
registro() {
  rm -f "$TCO_MODELOS_REGISTRO" "$T/transporte"
  case "$STATE" in
    ausente) : ;;
    invalido) echo INVALIDO > "$TCO_MODELOS_REGISTRO" ;;
    *) printf 'OPUS_MODEL="claude-%s-%s"\nSONNET_MODEL="claude-%s-%s"\nRESOLVED_UTC="2026-10-04T00:00:00Z"\nCLI_VERSION="2.1.289"\n' opus 6.2 sonnet 6.2 > "$TCO_MODELOS_REGISTRO" ;;
  esac
}
retirar() { case "$STATE" in tardio) rm -f "$TCO_MODELOS_REGISTRO" ;; invalido-tardio) echo INVALIDO > "$TCO_MODELOS_REGISTRO" ;; esac; }
am_authorized_gate() { retirar; }
am_ep_exec_user() { printf '%s' "$2" > "$T/transporte"; }
for STATE in valido ausente invalido tardio invalido-tardio; do
  for ag in claude codex; do
    registro
    rc=0; am_health_oneshot channel:ct-01 "$ag" tx-neutral > "$T/out" 2>&1 || rc=$?
    if [ "$ag" = codex ]; then
      check bash -c '[ "$1" = 0 ] && grep -Fq "codex exec" "$2" && ! grep -q -- --model "$2"' _ "$rc" "$T/transporte"
    elif [ "$STATE" = valido ]; then
      check bash -c '[ "$1" = 0 ] && grep -Fq -- "--model '\''claude-sonnet-6.2'\''" "$2"' _ "$rc" "$T/transporte"
    else
      check bash -c '[ "$1" != 0 ] && [ ! -e "$2" ] && grep -q resolver-modelos.sh "$3"' _ "$rc" "$T/transporte" "$T/out"
    fi
  done
done

# Se ejecuta el bloque real dentro de su bucle; continue conserva su semántica.
REFRESH="$(sed -n '/^  if \[ "$RESTART" = yes \]; then/,/^  fi/p' "$S/refresh-claude-auth.sh")"
tc_kill_wait() { retirar; return 0; }
tc_err() { printf '%s\n' "$*" >&2; }
tc_info() { :; }
incus() {
  case "$*" in
    *display-message*) [ "${TRANSPORT_FAIL:-0}" = 0 ]; return $? ;;
    *tf-phase-*) return 1 ;;
  esac
  printf '%s' "$*" > "$T/transporte"; [ "${TRANSPORT_FAIL:-0}" = 0 ]
}
run_refresh() (
  RESTART=yes CUSER=operador fail=0
  for ch in ct-01; do eval "$REFRESH"; done
  [ "$fail" = 0 ]
)
for STATE in valido ausente invalido tardio invalido-tardio; do
  for TC_CLAUDE_PHASE in plan coding fallback audit; do
    registro
    rc=0; run_refresh > "$T/out" 2>&1 || rc=$?
    family=sonnet; case "$TC_CLAUDE_PHASE" in plan|fallback) family=opus ;; esac
    if [ "$STATE" = valido ]; then
      check bash -c '[ "$1" = 0 ] && grep -Fq -- "--model claude-$2-6.2" "$3"' _ "$rc" "$family" "$T/transporte"
    else
      check bash -c '[ "$1" != 0 ] && [ ! -e "$2" ] && grep -q resolver-modelos.sh "$3"' _ "$rc" "$T/transporte" "$T/out"
    fi
  done
done
STATE=ausente; registro; TC_CLAUDE_RELAUNCH='codex --model modelo-neutral'
rc=0; run_refresh > "$T/out" 2>&1 || rc=$?
check bash -c '[ "$1" = 0 ] && grep -Fq "codex --model modelo-neutral" "$2" && ! grep -q claude-sonnet "$2"' _ "$rc" "$T/transporte"
unset TC_CLAUDE_RELAUNCH
STATE=valido; registro; TC_CLAUDE_PHASE=desconocida
rc=0; run_refresh > "$T/out" 2>&1 || rc=$?
check bash -c '[ "$1" != 0 ] && [ ! -e "$2" ]' _ "$rc" "$T/transporte"
registro; unset TC_CLAUDE_PHASE
rc=0; run_refresh > "$T/out" 2>&1 || rc=$?
check bash -c '[ "$1" != 0 ] && [ ! -e "$2" ] && grep -q TC_CLAUDE_PHASE "$3"' _ "$rc" "$T/transporte" "$T/out"
registro; TC_CLAUDE_PHASE=coding; TRANSPORT_FAIL=1
rc=0; run_refresh > "$T/out" 2>&1 || rc=$?
check test "$rc" != 0
unset TRANSPORT_FAIL

# Orden exacta del verificador; incus solo traduce el home a un fixture aislado.
export FIXTURE_HOME="$T/home"; mkdir -p "$FIXTURE_HOME/.claude"
printf '{"hasCompletedOnboarding":true}\n' > "$FIXTURE_HOME/.claude.json"
incus() {
  shift 3
  local cmd="$1" arg args=(); shift
  for arg in "$@"; do args+=("${arg//\/home\/operador/$FIXTURE_HOME}"); done
  "$cmd" "${args[@]}"
}
export -f incus
chk() { shift; local code="$1"; shift; bash -c "$code" _ "$@"; }
ch=ct-01 CUSER=operador TCO_SONNET_VIGENTE="claude-sonnet-6.2"
VERIFY="$(sed -n '/^  chk .*claude baseline /p' "$S/verify.sh")"
[ -n "$VERIFY" ] || exit 1
for actual in exacto guion letra roto ausente null numero array vacio sin-fichero; do
  case "$actual" in
    exacto) printf '{"model":"%s"}\n' "$TCO_SONNET_VIGENTE" ;;
    guion) printf '{"model":"claude-%s-%s"}\n' sonnet 6-2 ;;
    letra) printf '{"model":"claude-%s-%s"}\n' sonnet 6x2 ;;
    roto) printf '{"model":"%s"\n' "$TCO_SONNET_VIGENTE" ;;
    ausente) printf '{}\n' ;;
    null) printf '{"model":null}\n' ;;
    numero) printf '{"model":6.2}\n' ;;
    array) printf '[]\n' ;;
    vacio|sin-fichero) : ;;
  esac > "$FIXTURE_HOME/.claude/settings.json"
  [ "$actual" != sin-fichero ] || rm -f "$FIXTURE_HOME/.claude/settings.json"
  rc=0; eval "$VERIFY" > "$T/out" 2>&1 || rc=$?
  if [ "$actual" = exacto ]; then check test "$rc" = 0; else check test "$rc" != 0; fi
done

# Helper real del launcher: IDs completos por fase y auditor; proveedor ajeno intacto.
LAUNCHER="$(sed -n '/^launcher_model_args()/,/^}/p' "$HERE/../assets/launcher-v.tmpl" | sed "s#__MODELOS_LIB__#$S/../../talent-channel-operation/scripts/lib-modelos.sh#g")"
eval "$LAUNCHER"
STATE=valido; registro
for role in plan coding fallback audit; do
  family=sonnet; case "$role" in plan|fallback) family=opus ;; esac
  check test "$(launcher_model_args claude-root "$role")" = "claude-root --model claude-$family-6.2"
done
STATE=ausente; registro
check test "$(launcher_model_args 'codex --model neutral' coding)" = 'codex --model neutral'
rc=0; launcher_model_args claude-root coding > "$T/out" 2>&1 || rc=$?
check test "$rc" != 0
# Launcher generado ejecutado: captura solo el transporte final, nunca abre sesiones reales.
mkdir -p "$T/bin"
cat > "$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
if [ "${!#}" = true ]; then
  case "$STATE" in tardio) rm -f "$TCO_MODELOS_REGISTRO" ;; invalido-tardio) echo INVALIDO > "$TCO_MODELOS_REGISTRO" ;; esac
  exit 0
fi
printf '%s' "${!#}" > "$LAUNCH_LOG"
EOF
chmod +x "$T/bin/ssh"
export PATH="$T/bin:$PATH" LAUNCH_LOG="$T/transporte" STATE TC_CLAUDE_PHASE
for STATE in valido ausente invalido tardio invalido-tardio; do
  registro
  sed -e "s#__MODELOS_LIB__#$S/../../talent-channel-operation/scripts/lib-modelos.sh#g" -e 's/__PREFIX__/ct-/g' -e 's/__CUSER__/operador/g' -e 's/__REPO_DIR__/repo/g' -e 's/__SESSION__/v/g' -e 's/__LEFT__/claude-root/g' -e 's/__RIGHT__/codex-root/g' "$HERE/../assets/launcher-v.tmpl" > "$T/v"
  rc=0; bash "$T/v" 01 > "$T/out" 2>&1 || rc=$?
  if [ "$STATE" = valido ]; then
    check bash -c '[ "$1" = 0 ] && grep -Fq "claude-root\\ --model\\ claude-sonnet-6.2" "$2"' _ "$rc" "$T/transporte"
  else
    check bash -c '[ "$1" != 0 ] && [ ! -e "$2" ]' _ "$rc" "$T/transporte"
  fi
done
STATE=ausente; registro
sed "s/^LEFT_INPUT='claude-root'/LEFT_INPUT='codex-root'/" "$T/v" > "$T/v-ajeno"
rc=0; bash "$T/v-ajeno" 01 > "$T/out" 2>&1 || rc=$?
check bash -c '[ "$1" = 0 ] && grep -Fq "LEFT=codex-root;" "$2" && ! grep -q -- --model "$2"' _ "$rc" "$T/transporte"
printf 'RESULTADO consumidores PASS=%s FAIL=%s TOTAL=56\n' "$pass" "$fail"
[ "$fail" = 0 ] && [ "$pass" = 56 ]
