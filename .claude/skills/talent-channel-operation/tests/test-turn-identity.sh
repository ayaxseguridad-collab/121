#!/usr/bin/env bash
# Identidad causal, destino tras espera y significado de opciones; solo en el arnés.
# shellcheck disable=SC2329,SC2034
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$HERE/../scripts"
export TF_LINEAR_TEAM_KEY=ABC TCO_REPO_DIR=Repo-Neutro TCO_REPO_SLUG=org-neutra/Repo-Neutro TCO_REPO_STACK=ninguno
export TCO_ANEXO_FILE=references/anexo-neutro.md TCO_HOST_ENV_REL=Repo-Neutro/.env.local
export TCO_LINEAR_INPROGRESS_STATE=00000000-0000-4000-8000-000000000007 TCO_LINEAR_INREVIEW_STATE=00000000-0000-4000-8000-000000000008
# shellcheck source=/dev/null
. "$SC/00-config.sh"
# shellcheck source=/dev/null
. "$SC/lib.sh"
export TCO_MODELOS_REGISTRO="$HERE/fixtures/modelos-cli-current.conf"
MODEL_OPUS="$(tco_modelo_read plan)" || exit 1
MODEL_SONNET="$(tco_modelo_read coding)" || exit 1
REAL_SEND="$(declare -f _tco_send_text_submit)"
REAL_IDENTITY="$(declare -f tco_turn_identity)"
REAL_WAIT_IDLE="$(declare -f tco_wait_idle)"
REAL_STABLE_CAPTURE="$(declare -f tco_stable_idle_capture)"
TMP_TEST="$(mktemp -d)"; trap 'rm -rf "$TMP_TEST"' EXIT
PASS=0 FAIL=0
TOTAL_ESPERADO=213
ok() {
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'PASS %s\n' "$1";
  else FAIL=$((FAIL+1)); printf 'FAIL %s: [%s] esperado [%s]\n' "$1" "$2" "$3"; fi
}
sleep() { :; }
_tco_carril_session() { printf '%s idle 1' "$(cat "$TMP_TEST/session")"; }
_tco_carril_response_records() { cat "$TMP_TEST/records"; }
tco_pane_busy() { return 1; }
tco_cap_pane() { cat "$TMP_TEST/screen"; }
tco_stable_idle_capture() { cat "$TMP_TEST/screen"; }
fixture="$HERE/fixtures/reposo/p37-dev-cola.txt"
reset_records() {
  printf session-current > "$TMP_TEST/session"
  jq -nc '{type:"user",sessionId:"session-current",uuid:"human-current",message:{content:"encargo actual"}}' > "$TMP_TEST/records"
  jq -nc --arg text "$text" '{type:"assistant",sessionId:"session-current",uuid:"answer-current",parentUuid:"human-current",message:{content:$text}}' >> "$TMP_TEST/records"
  printf '❯ encargo actual\n%s\n' "$text" > "$TMP_TEST/screen"
}
for state in stop-audit pr merge; do
  case "$state" in stop-audit) text="$(cat "$fixture")";; pr) text='https://github.com/org-neutra/repo/pull/12';; merge) text='pull request merged';; esac
  for variant in valid foreign branch broken forward cycle corrupt corrupt-empty corrupt-content duplicate missing-session missing-uuid new-turn; do
    reset_records
    case "$variant" in
      foreign) sed -i 's/session-current/session-other/g' "$TMP_TEST/records";;
      branch) sed -i 's/"parentUuid":"human-current"/"parentUuid":"human-previous"/' "$TMP_TEST/records";;
      broken) sed -i 's/"parentUuid":"human-current"/"parentUuid":"missing-parent"/' "$TMP_TEST/records";;
      forward) sed -i 's/"parentUuid":"human-current"/"parentUuid":"tool-later"/' "$TMP_TEST/records"; printf '%s\n' '{"type":"progress","sessionId":"session-current","uuid":"tool-later","parentUuid":"human-current"}' >> "$TMP_TEST/records";;
      cycle) sed -i 's/"parentUuid":"human-current"/"parentUuid":"answer-current"/' "$TMP_TEST/records";;
      corrupt) printf 'registro roto\n' >> "$TMP_TEST/records";;
      corrupt-empty) printf '{}\n' >> "$TMP_TEST/records";;
      corrupt-content) sed -i 's/"content":/"contenido":/' "$TMP_TEST/records";;
      duplicate) cat "$TMP_TEST/records" > "$TMP_TEST/duplicate"; cat "$TMP_TEST/duplicate" >> "$TMP_TEST/records";;
      missing-session) sed -i 's/"sessionId":"session-current",//' "$TMP_TEST/records";;
      missing-uuid) sed -i 's/"uuid":"human-current",//' "$TMP_TEST/records";;
      new-turn) jq -nc '{type:"user",sessionId:"session-current",uuid:"human-new",message:{content:"nuevo encargo"}}' >> "$TMP_TEST/records";;
    esac
    rc=0
    if [ "$state" = stop-audit ]; then
      tco_current_stop_audit 01 v:.0 > "$TMP_TEST/out" 2>/dev/null || rc=$?
    else
      tco_wait_state 01 v:.0 "$text" 0 1 1 "$state" > "$TMP_TEST/out" 2>/dev/null || rc=$?
    fi
    if [ "$variant" = valid ]; then expected=0; else expected=1; fi
    ok "$state $variant no acredita otra identidad" "$rc" "$expected"
    if [ "$variant" != valid ]; then ok "$state $variant sin informe" "$(grep -cF "$text" "$TMP_TEST/out" || true)" 0; fi
  done
done

# Cadena larga: cada padre se acredita una vez y debe existir antes del hijo.
text=respuesta; reset_records; head -1 "$TMP_TEST/records" > "$TMP_TEST/chain"
jq -nc 'range(0;3000) as $i | {type:"progress",sessionId:"session-current",uuid:("step-"+($i|tostring)),parentUuid:(if $i==0 then "human-current" else "step-"+(($i-1)|tostring) end)}' >> "$TMP_TEST/chain"
printf '%s\n' '{"type":"assistant","sessionId":"session-current","uuid":"answer-current","parentUuid":"step-2999","message":{"content":"respuesta"}}' >> "$TMP_TEST/chain"
cat "$TMP_TEST/chain" > "$TMP_TEST/records"
ok 'identidad de cadena larga íntegra' "$(tco_turn_identity 01 v:.0)" '["session-current","human-current","humano"]'
ok 'respuesta de cadena larga íntegra' "$(tco_current_response 01 v:.0)" respuesta

# Ancestros intermedios y corrupción de un bloque de contenido.
text=respuesta; reset_records
jq -nc '{type:"user",isMeta:true,sessionId:"session-current",uuid:"tool-current",parentUuid:"human-current",message:{content:[{type:"tool_result",tool_use_id:"tool-one",content:"ok"}]}}' > "$TMP_TEST/middle"
sed -i 's/"parentUuid":"human-current"/"parentUuid":"tool-current"/' "$TMP_TEST/records"
{ head -1 "$TMP_TEST/records"; cat "$TMP_TEST/middle"; tail -1 "$TMP_TEST/records"; } > "$TMP_TEST/chain"
cat "$TMP_TEST/chain" > "$TMP_TEST/records"
ok 'cadena íntegra con resultado de herramienta' "$(tco_current_response 01 v:.0)" respuesta
for ancestor_session in current other missing; do
  case "$ancestor_session" in current) middle='{"type":"progress","sessionId":"session-current","uuid":"tool-current","parentUuid":"human-current"}'; expected=0;;
    other) middle='{"type":"progress","sessionId":"session-other","uuid":"tool-current","parentUuid":"human-current"}'; expected=2;;
    missing) middle='{"type":"progress","uuid":"tool-current","parentUuid":"human-current"}'; expected=2;; esac
  { head -1 "$TMP_TEST/records"; printf '%s\n' "$middle"; tail -1 "$TMP_TEST/records"; } > "$TMP_TEST/chain"
  cat "$TMP_TEST/chain" > "$TMP_TEST/records"
  rc=0; tco_current_response 01 v:.0 > "$TMP_TEST/out" || rc=$?
  ok "ancestro intermedio sesión $ancestor_session" "$rc" "$expected"
done

# El respaldo requiere el inicio humano visible y disco inaccesible.
_tco_carril_response_records() { return 1; }
for visible in no yes; do
  if [ "$visible" = yes ]; then printf '❯ encargo actual\nrespuesta\n' > "$TMP_TEST/screen"; else printf 'respuesta antigua\n❯ \n' > "$TMP_TEST/screen"; fi
  rc=0; tco_current_response 01 v:.0 > "$TMP_TEST/out" || rc=$?
  if [ "$visible" = yes ]; then expected=0; else expected=1; fi
  ok "respaldo comienzo humano $visible" "$rc" "$expected"
done
_tco_carril_response_records() { cat "$TMP_TEST/records"; }

# Reanudación: el recibo UUID liga el nuevo humano a la sesión original.
tco_relay_file() {
  printf 'relevo\n' >> "$TMP_TEST/relays"
  printf human-relay > "$7"
  jq -nc '{type:"user",sessionId:"session-current",uuid:"human-relay",message:{content:"lee relevo"}}' > "$TMP_TEST/records"
  return 0
}
tco_wait_idle() {
  case "$variant" in
    foreign) printf session-other > "$TMP_TEST/session";;
    new-turn) jq -nc '{type:"user",sessionId:"session-current",uuid:"human-other",message:{content:"otro coordinador"}}' >> "$TMP_TEST/records";;
    corrupt) printf 'roto\n' >> "$TMP_TEST/records";;
  esac
}
tco_send_ready() { return 0; }
tco_delivery_baseline() { : > "$4"; }
tco_verify_delivered() { return 0; }
_tco_send_text_submit() {
  tco_require_turn "$1" "$2" "$_TCO_EXPECTED_TURN" || return 2
  printf 'tecla\n' >> "$TMP_TEST/keys"
}
for variant in valid foreign new-turn corrupt compact; do
  text=plan; reset_records; : > "$TMP_TEST/keys"
  if [ "$variant" = compact ]; then sed -i '1s/"type":"user"/"type":"user","isMeta":true,"isCompactSummary":true/' "$TMP_TEST/records"; fi
  rc=0; tco_relay_plan_go 01 v:.0 "$fixture" >/dev/null 2>&1 || rc=$?
  if [ "$variant" = valid ] || [ "$variant" = compact ]; then expected=0; keys=1; else expected=2; keys=0; fi
  ok "reanudación $variant rc" "$rc" "$expected"
  ok "reanudación $variant teclas" "$(wc -l < "$TMP_TEST/keys")" "$keys"
done
text=plan; reset_records; : > "$TMP_TEST/relays"
rc=0; TCO_PLAN_RESUME_WAIT_MAX=invalido tco_relay_plan_go 01 v:.0 "$fixture" >/dev/null 2>&1 || rc=$?
ok 'máximo de reanudación inválido al entrar' "$rc" 2
ok 'máximo inválido no releva informe' "$(wc -l < "$TMP_TEST/relays")" 0

# Reanudación explícita: cambio tras reposo y durante el eco, sin submit ajeno.
eval "$REAL_SEND"
tamper() {
  case "$variant" in
    foreign) printf session-other > "$TMP_TEST/session";;
    new-turn) jq -nc '{type:"user",sessionId:"session-current",uuid:"human-other",message:{content:"otro coordinador"}}' >> "$TMP_TEST/records";;
    corrupt) printf 'roto\n' >> "$TMP_TEST/records";;
  esac
}
tco_send_ready() { [ "$phase" != text ] || tamper; return 0; }
sleep() { [ "$phase" != submit ] || tamper; return 0; }
incus() {
  if [[ "${8:-}" == *' -l -- '* ]]; then
    printf 'texto\n' >> "$TMP_TEST/keys"; printf '%s' "${*: -1}" > "$TMP_TEST/typed"
  else printf 'submit\n' >> "$TMP_TEST/keys"; fi
}
tco_cap_pane_e() {
  sed "s/^❯.*/❯ $(cat "$TMP_TEST/typed")/" "$HERE/fixtures/pane/claude_2.1.289/idle.txt"
}
for phase in text submit; do
  for variant in valid foreign new-turn corrupt; do
    text=plan; reset_records; : > "$TMP_TEST/keys"; : > "$TMP_TEST/typed"
    rc=0; _tco_send_text_submit 01 v:.0 continuar C-m yes '["session-current","human-current","humano"]' >/dev/null 2>&1 || rc=$?
    if [ "$variant" = valid ]; then expected=0; submits=1; else expected=2; submits=0; fi
    if [ "$phase" = text ] && [ "$variant" != valid ]; then texts=0; else texts=1; fi
    ok "envío $phase $variant rc" "$rc" "$expected"
    ok "envío $phase $variant texto" "$(grep -c '^texto$' "$TMP_TEST/keys" || true)" "$texts"
    ok "envío $phase $variant submit" "$(grep -c '^submit$' "$TMP_TEST/keys" || true)" "$submits"
  done
done
sleep() { :; }

# El primer envío conserva la ausencia humana comprobada; un error no es vacío.
for initial in empty absent unreadable corrupt; do
  text=plan; reset_records; : > "$TMP_TEST/records"; : > "$TMP_TEST/keys"; : > "$TMP_TEST/typed"
  printf '❯ \n' > "$TMP_TEST/screen"
  case "$initial" in
    empty) _tco_carril_response_records() { cat "$TMP_TEST/records"; }; expected=0; keys=2;;
    absent) _tco_carril_response_records() { return 3; }; expected=0; keys=2;;
    unreadable) _tco_carril_response_records() { return 1; }; expected=2; keys=0;;
    corrupt) _tco_carril_response_records() { printf '{}\n'; }; expected=2; keys=0;;
  esac
  variant=valid; phase=text; rc=0
  identity="$(tco_turn_identity 01 v:.0)" || rc=$?
  ok "arranque $initial identidad" "$rc" "$expected"
  rc=0; _tco_send_text_submit 01 v:.0 continuar >/dev/null 2>&1 || rc=$?
  ok "arranque $initial envío ordinario" "$rc" 0
  ok "arranque $initial teclas" "$(wc -l < "$TMP_TEST/keys")" 2
  if [ "$expected" = 0 ]; then
    rc=0; tco_current_response 01 v:.0 > "$TMP_TEST/out" || rc=$?
    ok "arranque $initial no acredita respuesta" "$([ "$rc" -ne 0 ] && printf rechazado)" rechazado
    ok "arranque $initial sin texto acreditado" "$(wc -c < "$TMP_TEST/out")" 0
  fi
done
_tco_carril_response_records() { cat "$TMP_TEST/records"; }
text=plan; reset_records; : > "$TMP_TEST/records"; : > "$TMP_TEST/relays"
rc=0; tco_relay_plan_go 01 v:.0 "$fixture" >/dev/null 2>&1 || rc=$?
ok 'sesión sin humano no autoriza reanudación' "$rc" 2
ok 'sesión sin humano no recibe informe de reanudación' "$(wc -l < "$TMP_TEST/relays")" 0

# Escape conserva su contrato de reposo sin identidad de turno.
tco_wait_idle() { tamper; return 0; }
for variant in valid foreign new-turn corrupt; do
  text=plan; reset_records; : > "$TMP_TEST/keys"
  rc=0; tco_abort_dev_dispatch 01 v:.0 prueba >/dev/null 2>&1 || rc=$?
  expected=0
  ok "interrupción $variant resultado causal" "$rc" "$expected"
  ok "interrupción $variant sin segundo Escape" "$(wc -l < "$TMP_TEST/keys")" 1
done
eval "$REAL_WAIT_IDLE"

# Configuración inválida se rechaza antes de sondear; fallo sleep se propaga.
tco_cap_pane() { printf 'sondeo\n' >> "$TMP_TEST/probes"; printf pantalla; }
for spec in 'invalido 3' '-1 3' '0 invalido' '0 0' '0 -1'; do
  read -r interval count <<< "$spec"; : > "$TMP_TEST/probes"
  rc=0; tco_wait_state 01 v:.0 AUSENTE "$interval" "$count" >/dev/null 2>&1 || rc=$?
  ok "espera $spec inválida" "$rc" 2
  ok "espera $spec sin sondeo" "$(wc -l < "$TMP_TEST/probes")" 0
done
sleep() { return 1; }
rc=0; tco_wait_state 01 v:.0 AUSENTE 0 4 3 >/dev/null 2>&1 || rc=$?
ok 'sleep fallido no declara reposo' "$rc" 2
sleep() { :; }
text=plan; reset_records; : > "$TMP_TEST/probes"
tco_pane_busy() { printf 'sondeo\n' >> "$TMP_TEST/probes"; return 1; }
rc=0; tco_pane_idle_stable 01 v:.0 3 invalido >/dev/null 2>&1 || rc=$?
ok 'reposo intervalo inválido' "$rc" 2
ok 'reposo inválido sin sondeo' "$(wc -l < "$TMP_TEST/probes")" 0
eval "$REAL_STABLE_CAPTURE"
rc=0; TCO_STABLE_GAP=invalido tco_stable_idle_capture 01 v:.0 >/dev/null 2>&1 || rc=$?
ok 'captura estable intervalo inválido' "$rc" 2
ok 'captura inválida sin sondeo' "$(wc -l < "$TMP_TEST/probes")" 0
sleep() { return 1; }
rc=0; tco_wait_idle 01 v:.0 3 >/dev/null 2>&1 || rc=$?
ok 'espera de reposo propaga sleep interno fallido' "$rc" 2
ok 'sleep interno fallido no repite sondeo' "$(wc -l < "$TMP_TEST/probes")" 1
rc=0; TCO_GO_RETRY_GAP=invalido tco_queue_dev_file_cycles 01 v:.0 "$fixture" >/dev/null 2>&1 || rc=$?
ok 'ciclos de cola intervalo inválido' "$rc" 2
rc=0; TCO_NUDGE_WAIT=invalido tco_nudge_until 01 v:.0 continuar 2 1 -- false >/dev/null 2>&1 || rc=$?
ok 'nudge intervalo inválido' "$rc" 2
sleep() { :; }

# El transporte numerado conserva cero teclas ante filas invertidas o duplicadas.
incus() { printf 'tecla\n' >> "$TMP_TEST/keys"; }
for kind in confirm-model confirm-effort trust; do
  for variant in inverted duplicate wrong valid; do
    text=plan; reset_records
    case "$kind" in confirm-model) title='Change model?'; expected_model="$MODEL_OPUS";; confirm-effort) title='Change effort level?'; expected_model=high;; trust) title='Do you trust this folder?'; expected_model='';; esac
    case "$kind" in trust) yes='Yes, I trust this folder';; confirm-model) yes="Yes, switch to Opus $(tco_modelo_version_visible "$MODEL_OPUS")";; confirm-effort) yes='Yes, switch to High';; esac
    case "$variant" in inverted) first=No; second="$yes";; duplicate) first="$yes"; second="$yes";; wrong) first='Otra opción'; second=No;; valid) first="$yes"; second=No;; esac
    tco_cap_pane() { printf '──────────────────\n%s\n❯ 1. %s\n  2. %s\nEnter to confirm · Esc to cancel\n' "$title" "$first" "$second"; }
    : > "$TMP_TEST/keys"; rc=0
    tco_cap_pane | tco_dialog_meaning_from "$kind" 1 "$expected_model" || rc=$?
    if [ "$variant" = valid ]; then expected=0; else expected=1; fi
    ok "opción $kind $variant significado" "$rc" "$expected"
    if [ "$variant" != valid ]; then
      rc=0
      if [ "$kind" = trust ]; then tco_send_dialog_choice 01 v:.0 trust 1 yes >/dev/null 2>&1 || rc=$?;
      else tco_send_dialog_choice 01 v:.0 confirm 1 yes "$expected_model" >/dev/null 2>&1 || rc=$?; fi
      ok "opción $kind $variant sin teclas" "$rc:$(wc -l < "$TMP_TEST/keys")" 2:0
    fi
  done
done
# Compactación y laterales: el tipo registrado describe el comienzo real.
_tco_carril_response_records() { cat "$TMP_TEST/records"; }
_tco_carril_session() { printf 'session-current idle 1'; }
tco_stable_idle_capture() { cat "$TMP_TEST/screen"; }
for form in summary summary-meta new-human two-summaries side; do
  text=respuesta; reset_records
  case "$form" in
    summary|summary-meta|two-summaries|new-human)
      meta=false; [ "$form" != summary-meta ] || meta=true
      jq -nc --argjson meta "$meta" '{type:"user",sessionId:"session-current",uuid:"summary-one",isCompactSummary:true,isMeta:$meta,parentUuid:"history",message:{content:"Resumen"}}' > "$TMP_TEST/records"
      root=summary-one; kind=compactacion
      if [ "$form" = two-summaries ]; then
        jq -nc '{type:"user",sessionId:"session-current",uuid:"summary-two",isCompactSummary:true,isMeta:true,parentUuid:"summary-one",message:{content:"Segundo resumen"}}' >> "$TMP_TEST/records"
        root=summary-two
      elif [ "$form" = new-human ]; then
        jq -nc '{type:"user",sessionId:"session-current",uuid:"human-new",parentUuid:"summary-one",message:{content:"Nuevo encargo"}}' >> "$TMP_TEST/records"
        root=human-new; kind=humano
      fi
      jq -nc --arg root "$root" '{type:"assistant",sessionId:"session-current",uuid:"answer-new",parentUuid:$root,message:{content:"respuesta"}}' >> "$TMP_TEST/records";;
    side)
      printf '%s\n' '{"type":"user","isSidechain":true,"uuid":"human-current","sessionId":"foreign","message":"malformado"}' '{"type":"assistant","isSidechain":true,"uuid":"side-answer","parentUuid":"missing"}' >> "$TMP_TEST/records"
      root=human-current; kind=humano;;
  esac
  ok "comienzo $form tipo y sesión" "$(tco_turn_identity 01 v:.0)" "[\"session-current\",\"$root\",\"$kind\"]"
  ok "comienzo $form respuesta acreditada" "$(tco_current_response 01 v:.0)" respuesta
  tuple="$(tco_turn_identity 01 v:.0)"
  rc=0; tco_require_turn 01 v:.0 "$tuple" || rc=$?
  ok "comienzo $form reanudación conserva tipo" "$rc" 0
done
# Un CLI sin disco solo acredita el comienzo visible.
_tco_carril_session() { return 1; }
for visible in yes no; do
  if [ "$visible" = yes ]; then printf '❯ encargo\nrespuesta\n' > "$TMP_TEST/screen"; else printf 'respuesta antigua\n❯ \n' > "$TMP_TEST/screen"; fi
  rc=0; tco_turn_identity 01 v:.0 > "$TMP_TEST/out" || rc=$?
  if [ "$visible" = yes ]; then expected=0; else expected=2; fi
  ok "sin disco comienzo visible $visible identidad" "$rc" "$expected"
  rc=0; tco_current_response 01 v:.0 > "$TMP_TEST/out" || rc=$?
  if [ "$visible" = yes ]; then expected=0; else expected=1; fi
  ok "sin disco comienzo visible $visible respuesta" "$rc" "$expected"
done
# Reanudación sin superficie de sesión: relevo confirmado y comienzo visible nuevo.
tco_relay_file() { printf '❯ lee relevo\nrespuesta\n' > "$TMP_TEST/screen"; : > "$7"; }
tco_delivery_baseline() { : > "$4"; }
tco_verify_delivered() { return 0; }
tco_send_ready() { return 0; }
_tco_send_text_submit() {
  tco_require_turn "$1" "$2" "$6" || return 2
  printf 'tecla\n' >> "$TMP_TEST/keys"
}
tco_wait_idle() {
  [ "$variant" != changed ] || printf '❯ otro encargo\nrespuesta\n' > "$TMP_TEST/screen"
  return 0
}
for variant in valid changed absent; do
  : > "$TMP_TEST/keys"
  if [ "$variant" = absent ]; then printf 'respuesta antigua\n❯ \n' > "$TMP_TEST/screen"; else printf '❯ encargo\nplan\n' > "$TMP_TEST/screen"; fi
  rc=0; tco_relay_plan_go 01 v:.0 "$fixture" >/dev/null 2>&1 || rc=$?
  if [ "$variant" = valid ]; then expected=0; keys=1; else expected=2; keys=0; fi
  ok "reanudación sin disco $variant rc" "$rc" "$expected"
  ok "reanudación sin disco $variant teclas" "$(wc -l < "$TMP_TEST/keys")" "$keys"
done
# El envío ordinario no consulta identidad ni con una guarda dinámica heredada.
eval "$REAL_SEND"
tco_turn_identity() { printf 'consulta\n' >> "$TMP_TEST/probes"; return 2; }
incus() {
  if [[ "${8:-}" == *' -l -- '* ]]; then printf '%s' "${*: -1}" > "$TMP_TEST/typed"; fi
  printf 'tecla\n' >> "$TMP_TEST/keys"
}
tco_cap_pane_e() { sed "s/^❯.*/❯ $(cat "$TMP_TEST/typed")/" "$HERE/fixtures/pane/claude_2.1.289/idle.txt"; }
: > "$TMP_TEST/probes"; : > "$TMP_TEST/keys"
rc=0; _TCO_EXPECTED_TURN=obsoleto _tco_send_text_submit 01 v:.0 continuar >/dev/null 2>&1 || rc=$?
ok 'envío ordinario sin superficie conserva teclas' "$rc:$(wc -l < "$TMP_TEST/keys")" 0:2
ok 'envío ordinario no calcula identidad' "$(wc -l < "$TMP_TEST/probes")" 0
# Crecimiento permanente: cuerpo real, tres medianas y umbral al duplicar.
export TCO_COST_BODY="$REAL_IDENTITY"
rc=0; python3 "$HERE/turn-cost.py" "$TMP_TEST" || rc=$?
ok 'crecimiento lineal de identidad en turnos largos' "$rc" 0
printf 'RESULTADO identidad: PASS=%s FAIL=%s TOTAL=%s\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$((PASS+FAIL))" -eq "$TOTAL_ESPERADO" ] && [ "$FAIL" -eq 0 ]
