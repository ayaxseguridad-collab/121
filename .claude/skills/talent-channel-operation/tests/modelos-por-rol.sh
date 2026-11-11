#!/usr/bin/env bash
# Contrato por rol: proveedores y transportes dobles, sin sesión real.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/../scripts"; PKG="$(cd "$S/../../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
trap 'printf "RESULTADO modelos-por-rol PASS=%s FAIL=1 TOTAL=19\n" "$pass"; exit 1' ERR
ok() { pass=$((pass+1)); printf 'PASS T%s %s\n' "$pass" "$1"; }
export TCO_MODELOS_REGISTRO="$T/modelos.conf" TCO_RUNS_DIR="$T/runs"
unset TCO_AUDIT_CLI TCO_AUDIT_MODEL_ARGS TCO_AUDIT_TOPOLOGY
# shellcheck source=/dev/null
. "$S/lib.sh"
opus="$(printf 'claude-%s-%s' opus 8.2)"; sonnet="$(printf 'claude-%s-%s' sonnet 8.2)"
sol="$(printf 'gpt-%s-%s' 9.10 sol)"; mando="$(printf 'claude-%s-%s' fable 8.1)"
registro() {
  printf 'OPUS_MODEL="%s"\nSONNET_MODEL="%s"\nRESOLVED_UTC="2026-10-11T00:00:00Z"\nCLI_VERSION="2.1.289"\n' "$opus" "$sonnet" > "$TCO_MODELOS_REGISTRO"
}
v2() {
  registro
  printf 'SOL_MODEL="%s"\nPLAN="claude:opus"\nCODE="claude:sonnet"\nCODE_SENSIBLE="claude:opus"\nAUDIT="codex:sol"\nAUDIT_EFFORT="medium"\n' "$sol" >> "$TCO_MODELOS_REGISTRO"
}
rechaza() {
  local rc=0
  "$@" > "$T/out" 2> "$T/err" || rc=$?
  [ "$rc" = 1 ] && [ ! -s "$T/out" ]
}
registro
for rol in ceo pm plan replan fallback code coding code_sensible audit coordinador merge salud; do
  expected="$sonnet"; case "$rol" in ceo|pm|plan|replan|fallback|code_sensible) expected="$opus" ;; esac
  [ "$(tco_modelo_read "$rol")" = "$expected" ]; [ "$(tco_modelo_proveedor "$rol")" = claude ]
done
ok 'cuatro claves y doce roles'
v2
for rol in plan code code_sensible audit; do
  expected="$opus"; case "$rol" in code) expected="$sonnet" ;; audit) expected="$sol" ;; esac
  [ "$(tco_modelo_read "$rol")" = "$expected" ]
done
ok 'registro v2'
sed -i 's/PLAN="claude:opus"/PLAN="codex:sol"/; s/CODE="claude:sonnet"/CODE="codex:sol"/; s/CODE_SENSIBLE="claude:opus"/CODE_SENSIBLE="codex:sol"/; s/AUDIT="codex:sol"/AUDIT="claude:opus"/' "$TCO_MODELOS_REGISTRO"
for rol in plan replan code coding fallback code_sensible; do
  [ "$(tco_modelo_read "$rol")" = "$sol" ]; [ "$(tco_modelo_proveedor "$rol")" = codex ]
done
[ "$(tco_modelo_read audit)" = "$opus" ]
for rol in coordinador merge salud; do [ "$(tco_modelo_read "$rol")" = "$sonnet" ]; done
ok 'inversión declarable'
for linea in 'DESCONOCIDA="x"' "OPUS_MODEL=\"$opus\"" 'CODE="codex:opus"' 'AUDIT="codex:sol"' "SOL_MODEL=\"$sol; id\"" 'AUDIT_EFFORT="max"' 'MANDO_MODEL="fable"'; do
  registro; printf '%s\n' "$linea" >> "$TCO_MODELOS_REGISTRO"; rechaza tco_modelo_read pm
done
# El mismo duplicado válido detecta la pérdida de la guarda, sin otro defecto.
registro; printf 'OPUS_MODEL="%s"\n' "$opus" >> "$TCO_MODELOS_REGISTRO"
cp "$S/lib-modelos.sh" "$T/duplicados.sh"
sed -i '/^    \[ -z .*vistos/ s/^.*; vistos/    vistos/' "$T/duplicados.sh"
oraculo_duplicado() (
  # shellcheck source=/dev/null
  . "$1"
  rechaza tco_modelo_read pm
)
rc=0; oraculo_duplicado "$T/duplicados.sh" || rc=$?
[ "$rc" = 1 ]; printf 'MUTACIÓN duplicados rojo rc=%s\n' "$rc"
oraculo_duplicado "$S/lib-modelos.sh"
printf 'MUTACIÓN duplicados revertida verde rc=0\n'
ok 'datos inválidos sin salida parcial'
v2; printf 'MANDO_MODEL="%s"\n' "$mando" >> "$TCO_MODELOS_REGISTRO"
for rol in ceo pm; do [ "$(tco_modelo_read "$rol")" = "$mando" ]; done
[ "$(tco_modelo_read coordinador)" = "$sonnet" ]
tco_modelo_require "$mando"; printf '[Fable 8.1]\n' | tco_modelo_etiqueta_is "$mando"
ok 'mando y etiqueta Fable'
mkdir -p "$T/bin" "$T/runs"
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || { echo 2.1.289; exit 0; }
family=''
while [ $# -gt 0 ]; do if [ "$1" = --model ]; then family="$2"; shift; fi; shift; done
printf '{"is_error":false,"subtype":"success","result":"OK","modelUsage":{"claude-%s-%s":{}}}\n' "$family" 8.2
EOF
cat > "$T/bin/codex" <<'EOF'
#!/usr/bin/env bash
[ "$*" = 'debug models --bundled' ] || exit 2
printf 'codex doble\n' >> "$CAT_LOG"
[ "${CAT_RC:-0}" = 0 ] || exit 1
cat "$CATALOGO"
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" CATALOGO="$T/catalogo.json" CAT_LOG="$T/catalogo.log"
catalogo() {
  printf '{"models":[' > "$CATALOGO"
  for ver in 9.2 9.10 8; do printf '{"slug":"gpt-%s-%s","visibility":"list"},' "$ver" sol >> "$CATALOGO"; done
  printf '{"slug":"gpt-%s-%s","visibility":"hidden"},{"slug":"otro","visibility":"list"}]}\n' 99 sol >> "$CATALOGO"
}
catalogo; registro
bash "$S/resolver-modelos.sh" --auditor codex > "$T/resuelto"
[ "$(bash "$S/modelos-roles.sh" --familia sol)" = "$sol" ]; [ "$(stat -c %a "$TCO_MODELOS_REGISTRO")" = 600 ]
grep -Fq " SOL=$sol" "$T/resuelto"; grep -qx 'AUDIT="codex:sol"' "$TCO_MODELOS_REGISTRO"
cat "$T/resuelto"; bash "$S/modelos-roles.sh" --tsv
ok 'catálogo numérico visible y registro privado'
sed -i 's/PLAN="claude:opus"/PLAN="codex:sol"/; s/AUDIT="codex:sol"/AUDIT="claude:opus"/' "$TCO_MODELOS_REGISTRO"
printf 'MANDO_MODEL="%s"\n' "$mando" >> "$TCO_MODELOS_REGISTRO"
printf '{"models":[{"slug":"gpt-%s-%s","visibility":"list"}]}\n' 10 sol > "$CATALOGO"
bash "$S/resolver-modelos.sh" > "$T/resuelto"
[ "$(bash "$S/modelos-roles.sh" --familia sol)" = "$(printf 'gpt-%s-%s' 10 sol)" ]
grep -qx 'AUDIT="claude:opus"' "$TCO_MODELOS_REGISTRO"; grep -Fqx "MANDO_MODEL=\"$mando\"" "$TCO_MODELOS_REGISTRO"
cat "$T/resuelto"; ok 'una resolución sube Sol y conserva inversión y mando'
mkdir "$T/ausente"
for herramienta in bash dirname install flock mktemp chmod grep head timeout jq date tr mv rm cat; do
  ln -s "$(command -v "$herramienta")" "$T/ausente/$herramienta"
done
ln -s "$T/bin/claude" "$T/ausente/claude"
for estado in ausente rc json vacio slug; do
  v2; cp "$TCO_MODELOS_REGISTRO" "$T/antes"; catalogo
  test_path="$PATH"
  case "$estado" in
    ausente) test_path="$T/ausente" ;;
    rc) export CAT_RC=1 ;;
    json) echo roto > "$CATALOGO" ;;
    vacio) echo '{"models":[]}' > "$CATALOGO" ;;
    slug) printf '{"models":[{"slug":"gpt-%s-%s; id","visibility":"list"}]}\n' 10 sol > "$CATALOGO" ;;
  esac
  rc=0; PATH="$test_path" bash "$S/resolver-modelos.sh" > "$T/out" 2> "$T/err" || rc=$?
  [ "$rc" = 1 ]; [ ! -s "$T/out" ]
  grep -q 'ERROR resolviendo sol' "$T/err"; cmp "$T/antes" "$TCO_MODELOS_REGISTRO"
  unset CAT_RC
done
ok 'cinco fallos atómicos incluida mitad Claude'
registro; : > "$CAT_LOG"
bash "$S/resolver-modelos.sh" > /dev/null
[ "$(wc -l < "$TCO_MODELOS_REGISTRO")" = 6 ]; [ ! -s "$CAT_LOG" ]
ok 'sin flag no invoca Codex'
echo corrupto > "$TCO_MODELOS_REGISTRO"
bash "$S/resolver-modelos.sh" > /dev/null 2> "$T/err"
grep -q 'se regenera' "$T/err"; tco_modelos_read
ok 'recuperación de registro corrupto'
v2; TCO_AUDIT_CLI=codex; TCO_AUDIT_MODEL_ARGS=''
tco_modelos_config; [ "$TCO_AUDIT_MODEL_ARGS" = "--model $sol --config model_reasoning_effort=medium" ]
TCO_AUDIT_MODEL_ARGS='--model neutral --config esfuerzo=alto'; tco_modelos_config
[ "$TCO_AUDIT_MODEL_ARGS" = '--model neutral --config esfuerzo=alto' ]
registro; TCO_AUDIT_CLI=claude; TCO_AUDIT_MODEL_ARGS=''; TCO_AUDIT_TOPOLOGY=mismo-adversarial
rechaza tco_modelos_config; [ -z "$TCO_AUDIT_MODEL_ARGS" ]   # ley del lead del 7-nov: un auditor Claude ya no se admite
ok 'argumentos resueltos y explícitos'
v2; TCO_AUDIT_CLI=codex; TCO_AUDIT_TOPOLOGY=distinto; tco_modelos_config
registro; TCO_AUDIT_CLI=claude; rechaza tco_modelos_config
TCO_AUDIT_TOPOLOGY=mismo-adversarial; rechaza tco_modelos_config
TCO_AUDIT_CLI=codex; rechaza tco_modelos_config   # con Codex tampoco: la única topología es distinto
TCO_AUDIT_TOPOLOGY=distinto
v2; sed -i 's/PLAN="claude:opus"/PLAN="codex:sol"/' "$TCO_MODELOS_REGISTRO"; rechaza tco_modelos_config
v2; sed -i 's/AUDIT="codex:sol"/AUDIT="claude:opus"/' "$TCO_MODELOS_REGISTRO"; TCO_AUDIT_CLI=codex; rechaza tco_modelos_config
registro; TCO_AUDIT_TOPOLOGY=distinto; tco_modelos_config
# [issue 10264, H-1] LISTA BLANCA también en la guarda de proveedores y en la derivación del modelo del auditor: el ejecutable
# (primer token, sin ruta y sin UN solo `-root`) debe ser EXACTAMENTE `codex`. Con el registro v2 (AUDIT=codex:sol) un
# `codexx` o `codex-evil` pasaban la guarda por el glob `codex*` y recibían los argumentos de modelo de Codex (línea de derivación).
for cli in codex codex-root /x/codex /x/codex-root; do
  v2; TCO_AUDIT_CLI="$cli"; TCO_AUDIT_TOPOLOGY=distinto; TCO_AUDIT_MODEL_ARGS=''
  tco_modelos_config; [ "$TCO_AUDIT_MODEL_ARGS" = "--model $sol --config model_reasoning_effort=medium" ]
done
for cli in codexx codex-evil codex-root.sh codexfalso-root gemini codex-root-root; do
  v2; TCO_AUDIT_CLI="$cli"; TCO_AUDIT_TOPOLOGY=distinto; TCO_AUDIT_MODEL_ARGS=''
  rechaza tco_modelos_config; grep -q 'Codex es obligatorio como revisor' "$T/err"
  [ -z "$TCO_AUDIT_MODEL_ARGS" ]   # ni siquiera se deriva un modelo para un auditor que no es Codex
done
registro; TCO_AUDIT_TOPOLOGY=distinto; TCO_AUDIT_MODEL_ARGS=''
# Quitar la guarda hace roja la misma exigencia de independencia; al reponerla pasa.
cp "$S/lib-modelos.sh" "$T/guarda.sh"
sed -i '/^  tco_modelos_guarda_proveedores$/c\  :' "$T/guarda.sh"
if bash -c '. "$1"; TCO_AUDIT_CLI=claude; TCO_AUDIT_TOPOLOGY=distinto; if tco_modelos_config; then exit 1; fi' _ "$T/guarda.sh"; then exit 1; fi
printf 'MUTACIÓN guarda rojo rc=1\n'
cp "$S/lib-modelos.sh" "$T/guarda.sh"
bash -c '. "$1"; TCO_AUDIT_CLI=claude; TCO_AUDIT_TOPOLOGY=distinto; if tco_modelos_config; then exit 1; fi' _ "$T/guarda.sh" 2>/dev/null
printf 'MUTACIÓN guarda revertida verde rc=0\n'
ok 'guardas independencia, inversión y binario'
unset TCO_AUDIT_CLI
v2
for fase in plan fallback code_sensible; do [ "$(tco_model_for_phase "$fase")" = "$opus" ]; done
[ "$(tco_model_for_phase coding 01)" = "$sonnet" ]
printf 'CLASE_SENSIBLE=dinero\nTS=neutro\n' > "$T/runs/clase-01.env"
[ "$(tco_model_for_phase coding 01)" = "$opus" ]
printf 'CLASE_SENSIBLE=no\n' > "$T/runs/clase-01.env"; [ "$(tco_model_for_phase coding 01)" = "$sonnet" ]
printf 'CLASE_SENSIBLE=otra\n' > "$T/runs/clase-01.env"
rechaza tco_model_for_phase coding 01; rechaza tco_model_for_phase desconocida
ok 'fases y clase sensible'
# Despacho real copiado con dobles; se detiene después de escribir clase, antes de crear sesión.
mkdir -p "$T/dispatch/scripts"; cp "$S/dispatch.sh" "$T/dispatch/scripts/"
cp -R "$S/../assets" "$T/dispatch/assets"
printf 'exit 0\n' > "$T/dispatch/scripts/preflight-issue.sh"
printf 'TF_GATE_IDS="syntax"\nTF_GATE_CMD_syntax="bash -n script.sh"\nTF_SENSITIVE_SURFACES="privacidad"\n' > "$T/manifiesto"
cat > "$T/dispatch/scripts/00-config.sh" <<'EOF'
TCO_DEV_CARRILES=01; TCO_REPO_DIR=repo; TCO_REPO_STACK=ninguno
TCO_CUSER=operador; TCO_CUSER_UID=1000; TCO_BOOTSTRAP_GITHOOKS=no; TCO_TMUX=v
TCO_TF_MANIFEST="$FIXTURE_MANIFEST"
EOF
cat > "$T/dispatch/scripts/lib.sh" <<'EOF'
tco_info() { printf '%s\n' "$*"; }; tco_say() { :; }; tco_err() { echo "$*" >&2; }
tco_die() { tco_err "$*"; exit 1; }; tco_container() { echo ct-01; }; tco_repo_path() { echo /tmp/repo; }
tco_lock_acquire() { :; }; tco_lock_release() { :; }; tco_stop_audit_header() { echo AUDITOR; }
tco_should_force_reset() { return 1; }; tco_cli_exe() { echo codex; }; tco_require_agents() { :; }
tco_wait_config() { :; }; tco_load_tokens() { :; }; tco_carril_libre() { :; }; tco_recycle_carril() { :; }
tco_tfm_exclude_ensure() { :; }; tco_tfm_post_dispatch_check() { :; }
incus() { case "$*" in *rev-parse*) echo sha-neutro ;; *kill-session*) exit 17 ;; esac; }
sleep() { [ ! -f "$TCO_RUNS_DIR/clase-01.env" ] || exit 17; }
EOF
export FIXTURE_MANIFEST="$T/manifiesto" TCO_SMOKE_MODE=yes
rm "$T/runs/clase-01.env"
bash "$T/dispatch/scripts/dispatch.sh" --dry-run --sensible=dinero 01 ABC-1 > "$T/dry"
grep -q 'CLASE: sensible=dinero' "$T/dry"; [ ! -e "$T/runs/clase-01.env" ]
rc=0; bash "$T/dispatch/scripts/dispatch.sh" --dry-run --sensible=otra 01 ABC-1 > "$T/out" 2>&1 || rc=$?
[ "$rc" = 1 ]; grep -q 'clase sensible inválida' "$T/out"
rc=0; bash "$T/dispatch/scripts/dispatch.sh" --no-linear --sensible=dinero 01 ABC-1 > "$T/real" 2>&1 || rc=$?
[ "$rc" = 17 ]; [ "$(stat -c %a "$T/runs/clase-01.env")" = 600 ]
grep -qx CLASE_SENSIBLE=dinero "$T/runs/clase-01.env"
ok 'despacho real hasta clase, dry-run y valor inválido'
eval "$(sed -n '/^launcher_model_args()/,/^}/p' "$PKG/skills/talent-channels/assets/launcher-v.tmpl" | sed "s#__MODELOS_LIB__#$S/lib-modelos.sh#g")"
[ "$(launcher_model_args codex-root audit)" = "codex-root --model $sol --config model_reasoning_effort=medium" ]
for cmd in 'codex --model neutral' 'codex -m neutral' 'codex --config esfuerzo=alto'; do [ "$(launcher_model_args "$cmd" audit)" = "$cmd" ]; done
[ "$(launcher_model_args claude-root coding)" = "claude-root --model $sonnet" ]
mv "$TCO_MODELOS_REGISTRO" "$T/guardado"; [ "$(launcher_model_args codex audit)" = codex ]; mv "$T/guardado" "$TCO_MODELOS_REGISTRO"
ok 'lanzador Codex y Claude'
bash "$S/modelos-roles.sh" --tsv > "$T/roles"
[ "$(wc -l < "$T/roles")" = 13 ]; grep -qx $'#auditoria\tindependiente' "$T/roles"
[ "$(bash "$S/modelos-roles.sh" --familia sol)" = "$sol" ]
# Ley del lead (7-nov): sin auditor Codex (registro de cuatro claves: auditor Claude por defecto) el lector PARA y no publica nada.
registro; rechaza bash "$S/modelos-roles.sh" --tsv; grep -q 'Codex es obligatorio como revisor' "$T/err"
echo invalido > "$TCO_MODELOS_REGISTRO"; rechaza bash "$S/modelos-roles.sh" --tsv
ok 'interfaz TSV y familias'
config="$PKG/skills/talent-channels/assets/codex-config.toml"
if grep -qE '^model[[:space:]]*=' "$config"; then exit 1; fi
for clave in model_reasoning_effort trust_level check_for_update_on_startup; do grep -q "^$clave" "$config"; done
ok 'golden sin ID fijo'
[ "$(grep -rl 'Registro de ''modelos:' "$PKG/skills" | wc -l)" = 17 ]
if grep -rq 'CEO y plan/fallback usan Opus vigente, ''los demás roles y salud Sonnet vigente.' "$PKG/skills"; then exit 1; fi
ok 'diecisiete pies actualizados'
for item in talent-pm talent-orchestrator; do
  id=INV-PM-001; [ "$item" != talent-orchestrator ] || id=INV-OR-006
  IFS=$'\t' read -r _ archivo modo patron _ < <(grep "^$id" "$PKG/skills/$item/invariants.tsv")
  [ "$modo" = MUST ]; grep -qE "$patron" "$PKG/skills/$item/$archivo"
done
# Mutación del reparto PM en una copia: el defecto original falla y se revierte.
cp "$S/lib-modelos.sh" "$T/lib-modelos.sh"; v2
sed -i 's/ceo|pm)/ceo)/g' "$T/lib-modelos.sh"
if bash -c '. "$1"; tco_modelo_read pm' _ "$T/lib-modelos.sh" > "$T/out" 2> "$T/err"; then exit 1; fi
grep -q 'rol desconocido' "$T/err"; printf 'MUTACIÓN PM rojo rc=1\n'
cp "$S/lib-modelos.sh" "$T/lib-modelos.sh"
[ "$(bash -c '. "$1"; tco_modelo_read pm' _ "$T/lib-modelos.sh")" = "$opus" ]
printf 'MUTACIÓN PM revertida verde rc=0\n'; ok 'anclas doctrinales y mutación PM'
printf 'RESULTADO modelos-por-rol PASS=%s FAIL=0 TOTAL=19\n' "$pass"
[ "$pass" = 19 ]
