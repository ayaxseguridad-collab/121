#!/usr/bin/env bash
# Pruebas conductuales del registro y sus consumidores, sin proveedor real.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/../scripts"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export TCO_MODELOS_REGISTRO="$T/modelos.conf"
export TCO_MODEL_PICKER_ALIASES=''
mkdir "$T/bin"
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = --version ]; then echo '2.1.289 (Claude Code)'; exit 0; fi
while [ $# -gt 0 ]; do if [ "$1" = --model ]; then family="$2"; shift; fi; shift; done
if [ "${BAD_SECOND:-}" ] && [ "$family" = sonnet ]; then BAD=$BAD_SECOND; fi
case "${BAD:-}" in
  error-success|success-error|two-success|list)
    success=$(printf '{"is_error":false,"subtype":"success","result":"OK","modelUsage":{"claude-%s-5-5":{}}}' "$family")
    error='{"is_error":true,"subtype":"error_during_execution","result":"quota"}'
    case "$BAD" in
      error-success) printf '%s\n%s\n' "$error" "$success" ;;
      success-error) printf '%s\n%s\n' "$success" "$error" ;;
      two-success) printf '%s\n%s\n' "$success" "$success" ;;
      list) printf '[%s]\n' "$success" ;;
    esac ;;
  no-output) : ;;
  text) echo 'respuesta textual' ;;
  missing) echo '{"is_error":false,"subtype":"success","result":"OK"}' ;;
  multiple) echo '{"is_error":false,"subtype":"success","result":"OK","modelUsage":{"claude-opus-5-5":{},"claude-sonnet-5-5":{}}}' ;;
  grammar) echo '{"is_error":false,"subtype":"success","result":"OK","modelUsage":{"otro":{}}}' ;;
  family) echo '{"is_error":false,"subtype":"success","result":"OK","modelUsage":{"claude-sonnet-5-5":{}}}' ;;
  error) echo '{"is_error":true,"subtype":"success","result":"OK","modelUsage":{"claude-opus-5-5":{}}}' ;;
  subtype) echo '{"is_error":false,"subtype":"error_during_execution","result":"OK","modelUsage":{"claude-opus-5-5":{}}}' ;;
  empty) echo '{"is_error":false,"subtype":"success","result":"","modelUsage":{"claude-opus-5-5":{}}}' ;;
  *) if [ "$family" = opus ]; then version="${OPUS_NEXT:-${NEXT:-5-5}}"; else version="${NEXT:-5-5}"; fi
     printf '{"is_error":false,"subtype":"success","result":"Ready when you are. What would you like to work on?","modelUsage":{"claude-%s-%s":{}}}\n' "$family" "$version" ;;
esac
EOF
chmod +x "$T/bin/claude"
export PATH="$T/bin:$PATH"
bash "$S/resolver-modelos.sh"
# shellcheck source=/dev/null
. "$S/lib.sh"
[ "$(tco_model_for_phase plan)" = claude-opus-5-5 ]
[ "$(tco_model_for_phase coding)" = claude-sonnet-5-5 ]
[ "$(tco_modelo_read ceo)" = claude-opus-5-5 ]
[ "$(tco_modelo_read merge)" = claude-sonnet-5-5 ]
[ "$(stat -c %a "$TCO_MODELOS_REGISTRO")" = 600 ]
cp "$TCO_MODELOS_REGISTRO" "$T/original"
# Captura del modal real del CLI 2.1.289; se conserva solo el diálogo, sin transcript.
tco_modelos_read
MODAL="$HERE/fixtures/model-picker-modal.txt"
[ "$(tco_model_picker_pick "$TCO_SONNET_VIGENTE" < "$MODAL")" = 2 ]
[ "$(tco_model_picker_pick "$TCO_OPUS_VIGENTE" < "$MODAL")" = 4 ]
tco_model_is "$(tco_modelo_picker_alias "$TCO_SONNET_VIGENTE")" < "$MODAL"
if sed '/3\. Fable/i\    6. Sonnet ✔ Sonnet 5.5' "$MODAL" | tco_model_picker_pick "$TCO_SONNET_VIGENTE"; then exit 1; fi
if sed '/3\. Fable/i\    6. Sonnet Sonnet 5' "$MODAL" | tco_model_active "$TCO_SONNET_VIGENTE"; then exit 1; fi
if sed '/2\. Sonnet/d' "$MODAL" | tco_model_picker_pick "$TCO_SONNET_VIGENTE"; then exit 1; fi
if sed 's/Sonnet 5.5/Sonnet 5/' "$MODAL" | tco_model_picker_pick "$TCO_SONNET_VIGENTE"; then exit 1; fi
if sed 's/Sonnet 5.5/Sonnet 5 · tareas 5/' "$MODAL" | tco_model_active "$TCO_SONNET_VIGENTE"; then exit 1; fi
grep -q '^SONNET_PICKER_ALIAS=' "$TCO_MODELOS_REGISTRO"
printf 'PASS selector: familia Sonnet fila 2, Opus fila 4, duplicado, ausente y versión anterior cerrados\n'
for BAD in missing multiple grammar family error subtype empty error-success success-error two-success list no-output text; do
  export BAD
  if bash "$S/resolver-modelos.sh"; then echo "FAIL respuesta inválida $BAD"; exit 1; fi
  cmp "$T/original" "$TCO_MODELOS_REGISTRO"
  printf 'PASS respuesta inválida conservada %s\n' "$BAD"
done
unset BAD
for BAD_SECOND in error-success success-error two-success list no-output text; do
  export BAD_SECOND
  if bash "$S/resolver-modelos.sh"; then echo "FAIL segunda sonda inválida $BAD_SECOND"; exit 1; fi
  cmp "$T/original" "$TCO_MODELOS_REGISTRO"
  printf 'PASS segunda sonda inválida conservada %s\n' "$BAD_SECOND"
done
unset BAD_SECOND
for pair in '5-5-20260901|5.5' '5-5-beta|5.5' '5|5' '6-10|6.10'; do
  id="claude-sonnet-${pair%%|*}"; visible="${pair#*|}"
  [ "$(tco_modelo_version_visible "$id")" = "$visible" ]
  NEXT="${pair%%|*}" bash "$S/resolver-modelos.sh" >/dev/null
  [ "$(tco_modelo_read coding)" = "$id" ]
  [ "$(printf '2. Sonnet Sonnet %s\n' "$visible" | tco_model_picker_pick "$id")" = 2 ]
  printf '[Sonnet %s]\n' "$visible" | tco_model_is "$id"
done
cp "$TCO_MODELOS_REGISTRO" "$T/antes-rechazo"
for version in 20260901 beta; do
  if NEXT="$version" bash "$S/resolver-modelos.sh"; then echo 'FAIL versión sin componente corto'; exit 1; fi
  cmp "$T/antes-rechazo" "$TCO_MODELOS_REGISTRO"
done
for label in '[Sonnet 6 · contexto 2]' '[Sonnet 6.3]' '[Opus 6.2]' '[Sonnet · contexto 6.2]'; do
  if printf '%s\n' "$label" | tco_model_is claude-sonnet-6-2; then echo 'FAIL etiqueta discordante'; exit 1; fi
done
NEXT=5-5 bash "$S/resolver-modelos.sh" >/dev/null
cp "$TCO_MODELOS_REGISTRO" "$T/original"
printf 'PASS versión visible: cuatro formatos, rechazo atómico y etiquetas exactas\n'
for pair in 'claude-opus-5-5|Opus 5.5' 'claude-sonnet-5-5|Sonnet 5.5' 'claude-opus-6|Opus 6' 'claude-sonnet-6-1|Sonnet 6.1'; do
  re="$(tco_model_family_re "${pair%%|*}")"
  printf '1. %s ✔\n' "${pair#*|}" | tco_model_is "$re"
  printf '1. %s ✔\n' "${pair#*|}" | tco_model_active "${pair%%|*}"
done
rc=0
if printf '1. Opus 6.1 ✔\n' | tco_model_is "$(tco_model_family_re claude-opus-6)"; then echo 'FAIL selector acepta otra versión'; exit 1; fi
OPUS_NEXT=6 bash "$S/actualizar-modelos.sh" --comprobar || rc=$?
[ "$rc" = 3 ]
cmp "$T/original" "$TCO_MODELOS_REGISTRO"
rc=0
NEXT=6-1 bash "$S/actualizar-modelos.sh" --comprobar || rc=$?
[ "$rc" = 3 ]
cmp "$T/original" "$TCO_MODELOS_REGISTRO"
NEXT=6-1 bash "$S/actualizar-modelos.sh" --plan
cmp "$T/original" "$TCO_MODELOS_REGISTRO"
mv "$TCO_MODELOS_REGISTRO" "$T/guardado"
# Configuración sin registro: ni error ni valores inventados, incluso tras un registro válido.
export TCO_REPO_DIR=repo TCO_REPO_SLUG=org/repo TCO_REPO_STACK=ninguno
export TCO_ANEXO_FILE=references/anexo.md TCO_HOST_ENV_REL=repo/entorno.conf
export TCO_LINEAR_INPROGRESS_STATE=00000000-0000-4000-8000-000000000001
export TCO_LINEAR_INREVIEW_STATE=00000000-0000-4000-8000-000000000002
HOST_HOME="$T/hogar" SECRET_DIR="$T/escrow" bash -c '
  set -e
  . "$1/00-config.sh"
  [ -z "$TCO_PLAN_MODEL$TCO_FALLBACK_MODEL$TCO_DEV_MODEL$TCO_DEV_MODEL_ARGS$TCO_AUDIT_MODEL_ARGS" ]
' _ "$S" > "$T/out" 2> "$T/err"
[ ! -s "$T/err" ]
printf 'registro inválido\n' > "$TCO_MODELOS_REGISTRO"
HOST_HOME="$T/hogar" SECRET_DIR="$T/escrow" bash -c '
  set -e
  . "$1/00-config.sh"
  [ -z "$TCO_PLAN_MODEL$TCO_FALLBACK_MODEL$TCO_DEV_MODEL$TCO_DEV_MODEL_ARGS$TCO_AUDIT_MODEL_ARGS" ]
' _ "$S" > "$T/out" 2> "$T/err"
[ ! -s "$T/err" ]
rm "$TCO_MODELOS_REGISTRO"
for fn in 'tco_model_for_phase plan' 'tco_modelos_config' 'tco_current_model_dialog 01 v:.0' 'tco_set_model 01 v:.0 claude-sonnet-5-5' 'tco_ensure_model 01 v:.0 claude-sonnet-5-5' 'tco_verify_model_effect 01 v:.0 claude-sonnet-5-5 uuid'; do
  if $fn > "$T/out" 2> "$T/err"; then echo "FAIL consumidor sin registro: $fn"; exit 1; fi
  grep -q 'ERROR modelos:.*resolver-modelos.sh' "$T/err"
done
for script in preparar-modelo-canal pozos-install-token pozos-install-token-torre pozos-install-token-remote; do
  case "$script" in
    preparar-modelo-canal) args=("$S/$script.sh" ct-01 operador) ;;
    pozos-install-token-remote) args=("$S/../../talent-orchestrator/scripts/$script.sh" host.invalid ct-01 sesion "$T/token") ;;
    *) args=("$S/../../talent-orchestrator/scripts/$script.sh" 01 "$T/token") ;;
  esac
  if bash "${args[@]}" > "$T/out" 2> "$T/err"; then echo "FAIL lanzador sin registro: $script"; exit 1; fi
  grep -q 'ERROR modelos:.*resolver-modelos.sh' "$T/err"
done
if tco_model_for_phase plan > "$T/out" 2> "$T/err"; then echo 'FAIL sin registro'; exit 1; fi
grep -q resolver-modelos.sh "$T/err"
mv "$T/guardado" "$TCO_MODELOS_REGISTRO"
chmod 000 "$TCO_MODELOS_REGISTRO"
if tco_model_for_phase coding > "$T/out" 2> "$T/err"; then echo 'FAIL registro ilegible'; exit 1; fi
grep -q resolver-modelos.sh "$T/err"
chmod 600 "$TCO_MODELOS_REGISTRO"
printf 'PASS carga perezosa: configuración vacía sin error y consumidores cerrados\n'
# Pérdida después de cargar: la función real del daemon no debe leer token ni invocar CLI.
eval "$(sed -n '/^probe(){/p' "$S/../../talent-orchestrator/scripts/pozos-rotador.sh")"
TOKENS_DIR="$T"; : > "$T/neutro.token"
claude() { echo 'CLI inesperado' > "$T/cli-invocado"; }
for estado in ausente invalido; do
  mv "$TCO_MODELOS_REGISTRO" "$T/guardado"
  [ "$estado" = ausente ] || printf 'inválido\n' > "$TCO_MODELOS_REGISTRO"
  if probe neutro > "$T/out" 2> "$T/err"; then echo 'FAIL sonda sin registro'; exit 1; fi
  [ ! -e "$T/cli-invocado" ]; grep -q resolver-modelos.sh "$T/err"
  for fn in 'tco_set_model 01 v:.0 claude-sonnet-5-5' 'tco_ensure_model 01 v:.0 claude-sonnet-5-5' 'tco_modelos_config'; do
    if $fn > "$T/out" 2> "$T/err"; then echo "FAIL consumidor tras pérdida: $fn"; exit 1; fi
    grep -q resolver-modelos.sh "$T/err"
  done
  for script in preparar-modelo-canal pozos-install-token pozos-install-token-torre pozos-install-token-remote; do
    case "$script" in
      preparar-modelo-canal) args=("$S/$script.sh" ct-01 operador) ;;
      pozos-install-token-remote) args=("$S/../../talent-orchestrator/scripts/$script.sh" example.invalid ct-01 sesion "$T/neutro.token") ;;
      *) args=("$S/../../talent-orchestrator/scripts/$script.sh" 01 "$T/neutro.token") ;;
    esac
    if bash "${args[@]}" > "$T/out" 2> "$T/err"; then echo "FAIL lanzador tras pérdida: $script"; exit 1; fi
    grep -q resolver-modelos.sh "$T/err"
  done
  rm -f "$TCO_MODELOS_REGISTRO"
  mv "$T/guardado" "$TCO_MODELOS_REGISTRO"
done
unset -f claude
# Registro retirado durante la instalación: el transporte de token no autoriza relanzar.
export LATE_LOG="$T/tardio.log" POZOS_REPO_DIR=repo
cat > "$T/bin/incus" <<'EOF'
#!/usr/bin/env bash
echo transporte-token >> "$LATE_LOG"
rm -f "$TCO_MODELOS_REGISTRO"
EOF
cat > "$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
echo transporte-token >> "$LATE_LOG"
rm -f "$TCO_MODELOS_REGISTRO"
EOF
chmod +x "$T/bin/incus" "$T/bin/ssh"
for script in pozos-install-token pozos-install-token-remote; do
  cp "$TCO_MODELOS_REGISTRO" "$T/guardado"
  : > "$LATE_LOG"
  case "$script" in
    pozos-install-token) args=(01 "$T/neutro.token") ;;
    *) args=(example.invalid ct-01 sesion "$T/neutro.token") ;;
  esac
  if bash "$S/../../talent-orchestrator/scripts/$script.sh" "${args[@]}" > "$T/out" 2> "$T/err"; then exit 1; fi
  grep -q resolver-modelos.sh "$T/err"
  [ "$(wc -l < "$LATE_LOG")" = 1 ]
  mv "$T/guardado" "$TCO_MODELOS_REGISTRO"
done
rm "$T/bin/incus" "$T/bin/ssh"
# Torre: copia del consumidor real; transporte y statusline dobles, sin procesos vivos.
mkdir -p "$T/torre/talent-orchestrator" "$T/torre/talent-channel-operation" "$T/torre/talent-context/scripts" "$T/escrow/env"
cp -R "$S/../../talent-orchestrator/scripts" "$T/torre/talent-orchestrator/scripts"
cp -R "$S" "$T/torre/talent-channel-operation/scripts"
printf 'exit 0\n' > "$T/torre/talent-context/scripts/install-statusline.sh"
printf '00000000-0000-4000-8000-000000000001\n' > "$T/escrow/env/torre.session"
cat > "$T/bin/tmux" <<'EOF'
#!/usr/bin/env bash
echo "$1" >> "$LATE_LOG"
case "$1" in has-session) rm -f "$TCO_MODELOS_REGISTRO" ;; esac
EOF
chmod +x "$T/bin/tmux"
cp "$TCO_MODELOS_REGISTRO" "$T/guardado"
: > "$LATE_LOG"
if SECRET_DIR="$T/escrow" bash "$T/torre/talent-orchestrator/scripts/pozos-install-token-torre.sh" torre "$T/neutro.token" > "$T/out" 2> "$T/err"; then exit 1; fi
grep -q resolver-modelos.sh "$T/err"
if grep -q send-keys "$LATE_LOG"; then echo 'FAIL torre relanzada tras perder registro'; exit 1; fi
mv "$T/guardado" "$TCO_MODELOS_REGISTRO"
rm "$T/bin/tmux"
# Otro proveedor conserva el valor exacto con registro válido y ausente.
TCO_AUDIT_CLI=codex
TCO_AUDIT_MODEL_ARGS='--model modelo-neutral --config esfuerzo=alto'
tco_modelos_config
[ "$TCO_AUDIT_MODEL_ARGS" = '--model modelo-neutral --config esfuerzo=alto' ]
mv "$TCO_MODELOS_REGISTRO" "$T/guardado"
if tco_modelos_config; then exit 1; fi
[ "$TCO_AUDIT_MODEL_ARGS" = '--model modelo-neutral --config esfuerzo=alto' ]
mv "$T/guardado" "$TCO_MODELOS_REGISTRO"
# La orden real de lanzamiento se evalúa con transporte doble, sin proveedor.
# shellcheck source=/dev/null
. "$S/00-config.sh"
TCO_DEV_CLI=claude TCO_DEV_FLAGS='' TCO_AUDIT_FLAGS='--sandbox' TCO_TMUX=v TCO_CUSER=operador
c=ct-01 rp=/tmp/repo CARRIL=01
tco_modelos_config
incus() { printf '%s\n' "$*" > "$T/lanzamiento"; }
# El lanzamiento ejecuta la ruta que acreditó la sonda en cada pane (id estable `%N`): se dan por acreditadas aquí.
# shellcheck disable=SC2034 # Los usa el bloque real de dispatch.sh que se evalúa abajo.
P_DEV=%0 P_AUD=%1
_TCO_ACREDITADO['%0']='claude|/fx/claude|1:2'; _TCO_LANZADOR['%0']=/fx/claude
_TCO_ACREDITADO['%1']='codex|/fx/codex|1:3'; _TCO_LANZADOR['%1']=/fx/codex
eval "$(sed -n '/^    tco_modelos_config/,/no pude iniciar los procesos de agente/p' "$S/dispatch.sh")"
grep -qF -- "/fx/codex'\\'' --sandbox --model modelo-neutral --config esfuerzo=alto" "$T/lanzamiento"
unset -f incus
printf 'PASS consumidores: daemon cerrado y auditor ajeno conservado en lanzamiento\n'
# Ley del lead del 7-nov: el revisor es siempre Codex; un auditor Claude PARA, con cualquier topología y con o sin argumentos previos.
# shellcheck source=/dev/null
. "$S/00-config.sh"
rc=0
TCO_AUDIT_CLI=claude TCO_AUDIT_TOPOLOGY=distinto tco_modelos_config > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" = 1 ]; [ ! -s "$T/out" ]
grep -q 'Codex es obligatorio como revisor' "$T/err"
[ "$TCO_AUDIT_MODEL_ARGS" = '--model modelo-neutral --config esfuerzo=alto' ]
rc=0
TCO_AUDIT_CLI=claude TCO_AUDIT_TOPOLOGY=mismo-adversarial tco_modelos_config > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" = 1 ]; [ ! -s "$T/out" ]
grep -q 'Codex es obligatorio como revisor' "$T/err"
[ "$TCO_AUDIT_MODEL_ARGS" = '--model modelo-neutral --config esfuerzo=alto' ]
# Con los argumentos vacíos tampoco se deriva ningún modelo de Claude para el auditor.
TCO_AUDIT_MODEL_ARGS=''
rc=0
TCO_AUDIT_CLI=claude TCO_AUDIT_TOPOLOGY=mismo-adversarial tco_modelos_config > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" = 1 ]; [ -z "$TCO_AUDIT_MODEL_ARGS" ]
printf 'PASS compatibilidad: un auditor Claude PARA con cualquier topología y no se deriva modelo para él\n'
tco_ensure_model() { printf '%s %s %s\n' "$1" "$2" "$3" > "$T/auditor"; return "${AUDIT_RC:-0}"; }
if TCO_AUDIT_CLI=claude tco_ensure_audit_model 01; then exit 1; fi
[ ! -e "$T/auditor" ]
if TCO_AUDIT_CLI=claude AUDIT_RC=2 tco_ensure_audit_model 01; then exit 1; fi
eval "$(sed -n '/^tco_audit_once()/,/^}/p' "$S/audit-gate.sh")"
incus() { printf 'transporte inesperado\n' > "$T/transporte"; return 1; }
if (TCO_AUDIT_CLI=claude AUDIT_RC=2 tco_audit_once 01 plan "$T/artefacto" sha "$T/veredicto") > "$T/out" 2> "$T/err"; then exit 1; fi
grep -q 'no se solicita veredicto' "$T/err"
[ ! -e "$T/transporte" ]
# [issue 10264, M-1] LISTA BLANCA: solo pasa un ejecutable cuyo basename es EXACTAMENTE codex o codex-root. Un nombre VÁLIDO por
# gramática que no es Codex (gemini, my-auditor…), una ruta con otro basename o un valor fuera de gramática PARAN: la función da
# rc 1 con el mensaje y la entrada REAL del gate (tco_audit_once, sin doble de tco_ensure_audit_model) muere SIN tocar el transporte.
for aud in gemini my-auditor codexx codex-evil codexfalso codex-otro /opt/x/codexfalso /opt/x/codex-root.sh codex-root.sh codexfalso-root codex-root-root 'env X=1 codex' ''; do
  if TCO_AUDIT_CLI="$aud" tco_ensure_audit_model 01 > "$T/out" 2> "$T/err"; then exit 1; fi
  grep -q 'Codex es obligatorio como revisor' "$T/err"
  [ ! -e "$T/auditor" ]
  rm -f "$T/transporte"
  if (TCO_AUDIT_CLI="$aud" tco_audit_once 01 plan "$T/artefacto" sha "$T/veredicto") > "$T/out" 2> "$T/err"; then exit 1; fi
  grep -q 'Codex es obligatorio como revisor' "$T/err"
  grep -q 'no se solicita veredicto' "$T/err"
  [ ! -e "$T/transporte" ]
done
for aud in codex codex-root /opt/x/codex /x/codex-root; do
  TCO_AUDIT_CLI="$aud" tco_ensure_audit_model 01 > "$T/out" 2> "$T/err"
  [ ! -s "$T/err" ]
  [ ! -e "$T/auditor" ]
done
printf 'PASS lista blanca del auditor: gemini/my-auditor y los basename ajenos PARAN (función y entrada real del gate, sin transporte); codex y codex-root pasan\n'
# [issue 10264, H-1] La guarda de proveedores de lib-modelos.sh (la que corre dentro de tco_modelos_config) es la misma lista blanca:
# `codex` y `codex-root` (también con ruta) pasan; `codexx`, `codex-evil`, `codex-root.sh`, `codexfalso-root` y `gemini` PARAN con rc 1.
for aud in codexx codex-evil codex-root.sh codexfalso-root gemini; do
  rc=0; TCO_AUDIT_MODEL_ARGS=''
  TCO_AUDIT_CLI="$aud" TCO_AUDIT_TOPOLOGY=distinto tco_modelos_config > "$T/out" 2> "$T/err" || rc=$?
  [ "$rc" = 1 ]; [ ! -s "$T/out" ]
  grep -q 'Codex es obligatorio como revisor' "$T/err"
  [ -z "$TCO_AUDIT_MODEL_ARGS" ]
done
for aud in codex codex-root /x/codex /x/codex-root; do
  TCO_AUDIT_CLI="$aud" TCO_AUDIT_TOPOLOGY=distinto tco_modelos_config > "$T/out" 2> "$T/err"
done
TCO_AUDIT_MODEL_ARGS=''
printf 'PASS lista blanca de la guarda de proveedores: codexx/codex-evil/codex-root.sh/codexfalso-root/gemini PARAN; codex y codex-root (con y sin ruta) pasan\n'
unset -f incus
rm -f "$T/auditor"
TCO_AUDIT_CLI=codex tco_ensure_audit_model 01
[ ! -e "$T/auditor" ]
# Función real del doctor, aislada de sus acciones, con doble de transporte por usuario.
eval "$(sed -n '/^check_modelo_auditor()/,/^}/p' "$S/../../talent-ceo/scripts/doctor.sh")"
eval "$(sed -n '/^check_modelo_actor()/,/^}/p' "$S/../../talent-ceo/scripts/doctor.sh")"
eval "$(sed -n '/^check_modelo_desarrollo()/,/^}/p' "$S/../../talent-ceo/scripts/doctor.sh")"
SKILLS="$S/../.." CUSER=operador
como() {
  shift
  if [ "$1" = bash ]; then COMO_RC=0; COMO_OUT="$(bash "${@:2}")" || COMO_RC=$?
  else COMO_RC="${CAP_RC:-0}"; COMO_OUT="${CAP_MODELO:-[Sonnet 5.5]}"; fi
}
ok() { printf 'OK\n' > "$T/doctor"; }
falla() { printf 'FALLA\n' > "$T/doctor"; }
noverif() { printf 'NOVERIF\n' > "$T/doctor"; }
check_modelo_auditor 01 operador ct-01 v:.1
grep -qx OK "$T/doctor"
CAP_MODELO='[Sonnet 5]' check_modelo_auditor 01 operador ct-01 v:.1
grep -qx FALLA "$T/doctor"
for label in '[Sonnet 5 · contexto 5]' '[Sonnet 5.6]' '[Opus 5.5]' '[Sonnet sin versión]'; do
  CAP_MODELO="$label" check_modelo_auditor 01 operador ct-01 v:.1
  grep -qx FALLA "$T/doctor"
  CAP_MODELO="$label" check_modelo_auditor 01 operador ct-01 v:.0 coding
  grep -qx FALLA "$T/doctor"
  check_modelo_actor merge m1 operador "$label"
  grep -qx FALLA "$T/doctor"
done
CAP_MODELO='[Sonnet 5 · contexto 5]' check_modelo_desarrollo 01 operador ct-01 v:.0
grep -qx FALLA "$T/doctor"
CAP_MODELO='[Sonnet 5.5]' check_modelo_desarrollo 01 operador ct-01 v:.0
grep -qx OK "$T/doctor"
CAP_RC=1 check_modelo_auditor 01 operador ct-01 v:.1
grep -qx NOVERIF "$T/doctor"
mv "$TCO_MODELOS_REGISTRO" "$T/guardado"
check_modelo_auditor 01 operador ct-01 v:.1
grep -qx NOVERIF "$T/doctor"
mv "$T/guardado" "$TCO_MODELOS_REGISTRO"
# Restaurar helpers reales antes de probar la aplicación.
# shellcheck source=/dev/null
. "$S/lib.sh"
printf 'PASS auditor: lanzamiento Sonnet vigente, comprobación/cambio cerrado y doctor con modelo anterior\n'
printf 'PASS modelos rodantes: resolución, negativos atómicos, roles, etiquetas futuras y comprobación/plan sin cambios\n'
# Aplicación completa con una copia de los consumidores y dobles de transporte.
mkdir -p "$T/copia/talent-channel-operation" "$T/copia/talent-ceo/scripts" "$T/canales/ct-01" "$T/canales/ct-02"
cp -R "$S" "$T/copia/talent-channel-operation/scripts"
CS="$T/copia/talent-channel-operation/scripts"
cat >> "$CS/lib.sh" <<'EOF'
tco_carril_libre() { [ "$1" = 01 ]; }
tco_ensure_model() { printf 'PANEL %s %s %s\n' "$1" "$3" "$2" >> "$TEST_LOG"; }
EOF
cat > "$T/copia/talent-ceo/scripts/bus-sellar.sh" <<'EOF'
#!/usr/bin/env bash
printf 'BUS %s\n' "$*" >> "$TEST_LOG"
EOF
cat > "$T/bin/incus" <<'EOF'
#!/usr/bin/env bash
printf 'INCUS %s\n' "$2" >> "$TEST_LOG"
HOME="$TEST_CANALES/$2" bash -c "${8}" "${@:9}"
EOF
chmod +x "$T/bin/incus"
export TEST_LOG="$T/aplicar.log" TEST_CANALES="$T/canales"
export TCO_LOCK_DIR="$T/locks" TCO_RUNS_DIR="$T/runs"
export SECRET_DIR="$T/escrow" HOST_HOME="$T/hogar" TCO_PREFIX=ct- TCO_CUSER=operador
export TCO_DEV_CARRILES='01 02' TCO_AUDIT_CARRILES='' TA_ROL=coordinador
export TCO_REPO_DIR=repo TCO_REPO_SLUG=org/repo TCO_REPO_STACK=ninguno
export TCO_ANEXO_FILE=references/anexo.md TCO_HOST_ENV_REL=repo/.env.local
export TCO_LINEAR_INPROGRESS_STATE=00000000-0000-4000-8000-000000000001
export TCO_LINEAR_INREVIEW_STATE=00000000-0000-4000-8000-000000000002
unset TCO_SUPABASE_REF
# Los defaults vacíos se rellenan: el auditor se fija ocupado para esta prueba.
printf 'TCO_AUDIT_CARRILES=""\nTCO_AUDIT_CLI="codex"\n' > "$T/agents.tmp"
mkdir -p "$SECRET_DIR"
cp "$T/agents.tmp" "$SECRET_DIR/agents.conf"
NEXT=6-1 bash "$CS/actualizar-modelos.sh" --ejecutar > "$T/aplicacion.out"
cat "$T/aplicacion.out"
grep -q '^APLICADO 01' "$T/aplicacion.out"
grep -q '^DIFERIDO 02' "$T/aplicacion.out"
grep -q 'PANEL 01 claude-sonnet-6-1' "$TEST_LOG"
if grep -q 'PANEL 01 claude-sonnet-6-1 .*:.1' "$TEST_LOG"; then echo 'FAIL el panel de auditoría (Codex) no recibe modelo de Claude'; exit 1; fi
grep -q 'BUS .*MODELOS-claude-opus-6-1-claude-sonnet-6-1' "$TEST_LOG"
if grep -q 'INCUS ct-02' "$TEST_LOG"; then echo 'FAIL transporte al canal ocupado'; exit 1; fi
jq -e '.model == "claude-sonnet-6-1"' "$T/canales/ct-01/.claude/settings.json"
[ ! -e "$T/canales/ct-02/.claude/settings.json" ]
[ "$(tco_model_for_phase plan)" = claude-opus-6-1 ]
[ "$(tco_model_for_phase coding)" = claude-sonnet-6-1 ]
# Un candidato inválido tampoco altera el registro durante actualizar.
cp "$TCO_MODELOS_REGISTRO" "$T/antes-mal"
if BAD=grammar bash "$CS/actualizar-modelos.sh" --ejecutar; then exit 1; fi
cmp "$T/antes-mal" "$TCO_MODELOS_REGISTRO"
printf 'PASS aplicación: registro, configuración, canal ocioso, ocupado diferido y aviso bus\n'
bash "$HERE/modelos-por-rol.sh"
